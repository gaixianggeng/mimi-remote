import Foundation
import XCTest
@testable import MimiRemote

final class WorkspaceMergedSessionEngineTests: XCTestCase {
    private let hostScope = HostScope(profileID: "host-a", installationID: "inst-a", generation: 1)

    private func makeSession(
        id: String,
        runtimeProvider: String,
        updatedAtMs: Int64,
        parentThreadID: String? = nil,
        isSubagent: Bool? = nil
    ) -> AgentSession {
        let date = Date(timeIntervalSince1970: Double(updatedAtMs) / 1000.0)
        return AgentSession(
            id: id,
            projectID: "ws-1",
            project: "demo",
            dir: "/Users/dev/demo",
            title: "\(runtimeProvider)-\(id)",
            status: SessionStatus.completed.rawValue,
            source: runtimeProvider,
            runtimeProvider: runtimeProvider,
            resumeID: id,
            createdAt: date,
            updatedAt: date,
            recencyAt: date,
            parentThreadID: parentThreadID,
            isSubagent: isSubagent
        )
    }

    private func makePage(
        runtime: String,
        items: [(id: String, epochMs: Int64, parentThreadID: String?, isSubagent: Bool?)],
        nextCursor: String? = nil,
        hasMore: Bool = false,
        listMeta: SessionListMeta? = nil,
        overrideEvidence: [SessionID: RawSortEvidence] = [:]
    ) -> SessionsPage {
        var sessions: [AgentSession] = []
        var evidence: [SessionID: RawSortEvidence] = [:]
        for item in items {
            let session = makeSession(
                id: item.id,
                runtimeProvider: runtime,
                updatedAtMs: item.epochMs,
                parentThreadID: item.parentThreadID,
                isSubagent: item.isSubagent
            )
            sessions.append(session)
            evidence[item.id] = overrideEvidence[item.id] ?? .epochMs(item.epochMs)
        }
        return SessionsPage(
            sessions: sessions,
            nextCursor: nextCursor,
            hasMore: hasMore,
            listMeta: listMeta,
            rawSortEvidenceBySessionID: evidence
        )
    }

    // MARK: - C1: Mixed Timestamp Units & Tie-Break Determinism

    func testWireTimestampUnitNormalizationAndTieBreakOrder() {
        // Legacy Rust Claude emits milliseconds; Claude SDK & Codex emit seconds; DeepSeek emits ms.
        let rustClaudeWire: [String: CodexAppServerJSONValue] = [
            "id": .string("c-rust"),
            "cliVersion": .string("alleycat-claude-bridge/0.1.0"),
            "updatedAt": .int(1_700_000_002_500)
        ]
        let sdkClaudeWire: [String: CodexAppServerJSONValue] = [
            "id": .string("c-sdk"),
            "cliVersion": .string("claude-agent-sdk/1.0"),
            "updatedAt": .int(1_700_000_002)
        ]
        let codexWire: [String: CodexAppServerJSONValue] = [
            "id": .string("x-1"),
            "updatedAt": .int(1_700_000_002)
        ]
        let deepSeekWire: [String: CodexAppServerJSONValue] = [
            "id": .string("d-1"),
            "updatedAt": .int(1_700_000_002_000)
        ]

        XCTAssertEqual(
            RawSortEvidence.fromWireThread(rustClaudeWire, runtimeProvider: "claude"),
            .epochMs(1_700_000_002_500)
        )
        XCTAssertEqual(
            RawSortEvidence.fromWireThread(sdkClaudeWire, runtimeProvider: "claude"),
            .epochMs(1_700_000_002_000)
        )
        XCTAssertEqual(
            RawSortEvidence.fromWireThread(codexWire, runtimeProvider: "codex"),
            .epochMs(1_700_000_002_000)
        )
        XCTAssertEqual(
            RawSortEvidence.fromWireThread(deepSeekWire, runtimeProvider: "deepseek"),
            .epochMs(1_700_000_002_000)
        )

        var engine = WorkspaceMergedSessionEngine(
            hostScope: hostScope,
            enabledRuntimes: [.codex, .claude, .agy, .deepseek]
        )
        let tiedMs: Int64 = 1_700_000_002_000
        engine.ingestPage(runtime: .deepseek, page: makePage(runtime: "deepseek", items: [("d1", tiedMs, nil, nil)]), isRefresh: true)
        engine.ingestPage(runtime: .agy, page: makePage(runtime: "agy", items: [("a1", tiedMs, nil, nil)], listMeta: SessionListMeta(complete: true)), isRefresh: true)
        engine.ingestPage(runtime: .claude, page: makePage(runtime: "claude", items: [("c1", tiedMs, nil, nil)]), isRefresh: true)
        engine.ingestPage(runtime: .codex, page: makePage(runtime: "codex", items: [("x1", tiedMs, nil, nil)]), isRefresh: true)

        let projection = engine.projection(targetVisibleCount: 20)
        XCTAssertEqual(projection.completeness, .completeExhausted)
        XCTAssertEqual(
            projection.visibleSessions.map(\.id),
            ["x1", "c1", "a1", "d1"],
            "Tied timestamps must deterministically sort by codex < claude < agy < deepseek"
        )
    }

    // MARK: - C3: Agy Degraded & Missing listMeta Stay Preview-Only, M10 Empty State Iron Rule

    func testAgyDegradedAndUnverifiedHealthPreventFalseCompleteOrEmpty() {
        var engine = WorkspaceMergedSessionEngine(
            hostScope: hostScope,
            enabledRuntimes: [.codex, .agy]
        )

        // Codex exhausted with 0 sessions; Agy returned degraded (complete: false) with 0 sessions.
        engine.ingestPage(runtime: .codex, page: makePage(runtime: "codex", items: [], hasMore: false), isRefresh: true)
        engine.ingestPage(
            runtime: .agy,
            page: makePage(
                runtime: "agy",
                items: [],
                hasMore: false,
                listMeta: SessionListMeta(complete: false, degradedReason: "sidecar_timeout")
            ),
            isRefresh: true
        )

        let degradedProjection = engine.projection(targetVisibleCount: 20)
        XCTAssertEqual(degradedProjection.completeness, .partial)
        XCTAssertNotNil(degradedProjection.partialNotice)
        XCTAssertEqual(degradedProjection.partialNotice?.degradedRuntimes, [.agy])

        // Missing listMeta on Agy must be classified as unverifiedHealth (not trusted completeExhausted),
        // without nagging legacy-server users with a permanent "partial results" banner.
        var unverifiedEngine = WorkspaceMergedSessionEngine(
            hostScope: hostScope,
            enabledRuntimes: [.agy]
        )
        unverifiedEngine.ingestPage(
            runtime: .agy,
            page: makePage(runtime: "agy", items: [("a1", 1_700_000_005_000, nil, nil)], hasMore: false, listMeta: nil),
            isRefresh: true
        )
        let unverifiedProjection = unverifiedEngine.projection(targetVisibleCount: 20)
        XCTAssertEqual(unverifiedProjection.completeness, .partial)
        XCTAssertEqual(unverifiedProjection.strictCommittedCount, 0)
        XCTAssertEqual(unverifiedProjection.visibleSessions.map(\.id), ["a1"])
        XCTAssertNil(unverifiedProjection.partialNotice)

        // Host-disabled runtimes (e.g., Claude turned off on Mac) must be excluded cleanly without banner.
        var hostDisabledEngine = WorkspaceMergedSessionEngine(
            hostScope: hostScope,
            enabledRuntimes: [.codex, .claude, .agy]
        )
        hostDisabledEngine.resetForRefresh(availableRuntimeProviders: ["codex", "agy"])
        hostDisabledEngine.ingestPage(
            runtime: .codex,
            page: makePage(runtime: "codex", items: [("x1", 1_700_000_006_000, nil, nil)], hasMore: false),
            isRefresh: true
        )
        hostDisabledEngine.ingestPage(
            runtime: .agy,
            page: makePage(
                runtime: "agy",
                items: [("a1", 1_700_000_005_000, nil, nil)],
                hasMore: false,
                listMeta: SessionListMeta(complete: true)
            ),
            isRefresh: true
        )
        let hostDisabledProjection = hostDisabledEngine.projection(targetVisibleCount: 20)
        XCTAssertEqual(hostDisabledProjection.completeness, .completeExhausted)
        XCTAssertNil(hostDisabledProjection.partialNotice)
        XCTAssertEqual(hostDisabledProjection.visibleSessions.map(\.id), ["x1", "a1"])

        // All unavailable must produce .allUnavailable (never .completeExhausted).
        var unavailableEngine = WorkspaceMergedSessionEngine(
            hostScope: hostScope,
            enabledRuntimes: [.codex, .claude]
        )
        unavailableEngine.markUnavailable(.codex, reason: "offline")
        unavailableEngine.markUnavailable(.claude, reason: "offline")
        let unavailableProjection = unavailableEngine.projection(targetVisibleCount: 20)
        XCTAssertEqual(unavailableProjection.completeness, .allUnavailable)
    }

    // MARK: - C4-core: Same-ID Cross-Runtime Isolation (Engine + SessionHierarchy)

    func testSameSessionIDAcrossCodexAndClaudeNeverCollides() {
        var engine = WorkspaceMergedSessionEngine(
            hostScope: hostScope,
            enabledRuntimes: [.codex, .claude]
        )
        engine.ingestPage(
            runtime: .codex,
            page: makePage(runtime: "codex", items: [("shared-id", 1_700_000_010_000, nil, nil)], hasMore: false),
            isRefresh: true
        )
        engine.ingestPage(
            runtime: .claude,
            page: makePage(runtime: "claude", items: [("shared-id", 1_700_000_009_000, nil, nil)], hasMore: false),
            isRefresh: true
        )

        let projection = engine.projection(targetVisibleCount: 20)
        XCTAssertEqual(projection.visibleSessions.count, 2)
        XCTAssertEqual(projection.visibleSessions.map(\.runtimeProvider), ["codex", "claude"])

        let families = SessionHierarchy.families(projection.visibleSessions)
        XCTAssertEqual(families.count, 2)
        XCTAssertEqual(Set(families.map(\.renderID)).count, 2)
        let rows = SessionHierarchy.rows(families, collapsedRootIDs: [])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.renderID)).count, 2)
    }

    // MARK: - C5: Codex recencyAt: null -> .opaqueServerOrder

    func testCodexExplicitNullRecencyProducesOpaqueServerOrder() {
        let wire: [String: CodexAppServerJSONValue] = [
            "id": .string("codex-opaque"),
            "recencyAt": .null
        ]
        XCTAssertEqual(
            RawSortEvidence.fromWireThread(wire, runtimeProvider: "codex"),
            .opaqueServerOrder
        )

        var engine = WorkspaceMergedSessionEngine(hostScope: hostScope, enabledRuntimes: [.codex])
        engine.ingestPage(
            runtime: .codex,
            page: makePage(
                runtime: "codex",
                items: [("codex-opaque", 1_700_000_000_000, nil, nil)],
                hasMore: false,
                overrideEvidence: ["codex-opaque": .opaqueServerOrder]
            ),
            isRefresh: true
        )
        let projection = engine.projection(targetVisibleCount: 20)
        XCTAssertEqual(projection.visibleSessions.map(\.id), ["codex-opaque"])
        XCTAssertEqual(projection.strictCommittedCount, 0)
    }

    // MARK: - C6a / C6b: Known Ownership Merge & Late-Page Subagent Back-Propagation (20 -> 19 -> 20)

    func testLatePageSubagentBackPropagationWithdrawsCompleteAndRefills() {
        var engine = WorkspaceMergedSessionEngine(hostScope: hostScope, enabledRuntimes: [.codex])

        // Page 1 returns 20 seemingly root sessions (ts: 20_000 down to 1_000), hasMore: true.
        let page1Items: [(id: String, epochMs: Int64, parentThreadID: String?, isSubagent: Bool?)] =
            (1...20).map { i in
                let id = "s-\(i)"
                let ts = Int64((21 - i) * 1000) + 1_700_000_000_000
                return (id, ts, nil, nil)
            }
        engine.ingestPage(
            runtime: .codex,
            page: makePage(runtime: "codex", items: page1Items, nextCursor: "c2", hasMore: true),
            isRefresh: true
        )
        XCTAssertEqual(engine.projection(targetVisibleCount: 20).completeness, .complete)
        XCTAssertEqual(engine.projection(targetVisibleCount: 20).visibleSessions.count, 20)

        // Page 2 retroactively tags s-5 as a subagent (e.g., via parentThreadID) without adding another root yet.
        engine.ingestPage(
            runtime: .codex,
            page: makePage(
                runtime: "codex",
                items: [("s-5", 1_700_000_016_000, "s-1", true)],
                nextCursor: "c3",
                hasMore: true
            ),
            isRefresh: false
        )
        let afterBackprop = engine.projection(targetVisibleCount: 20)
        XCTAssertEqual(afterBackprop.visibleSessions.count, 19, "s-5 must be filtered out retroactively")
        XCTAssertFalse(afterBackprop.visibleSessions.contains(where: { $0.id == "s-5" }))
        XCTAssertTrue(engine.needsMorePages(targetVisibleCount: 20), "Must request another page to refill 19 -> 20")

        // Page 3 supplies root s-21 -> refilled to 20.
        engine.ingestPage(
            runtime: .codex,
            page: makePage(
                runtime: "codex",
                items: [("s-21", 1_700_000_000_500, nil, nil)],
                nextCursor: nil,
                hasMore: false
            ),
            isRefresh: false
        )
        let refilled = engine.projection(targetVisibleCount: 20)
        XCTAssertEqual(refilled.visibleSessions.count, 20)
        XCTAssertEqual(refilled.completeness, .completeExhausted)
    }

    // MARK: - C7: Atomic Budget Concurrency & Exhausted Stream Zero Follow-Up RPCs

    func testRPCBudgetLedgerAtomicConcurrencyAndExhaustedStreamSkipsRPC() {
        let ledger = SessionListRPCBudgetLedger(maxPerRuntimeRPCs: 12, maxTotalRPCs: 16, maxConcurrentRPCs: 2)

        // Consume 15 of 16 total RPCs cleanly.
        for i in 0..<15 {
            let provider = i % 2 == 0 ? "codex" : "claude"
            XCTAssertEqual(ledger.reserve(runtimeProvider: provider), .reserved)
            ledger.finish(runtimeProvider: provider)
        }

        // At 15/16, two ready streams attempting reserve concurrently must admit at most 1.
        let r1 = ledger.reserve(runtimeProvider: "codex")
        let r2 = ledger.reserve(runtimeProvider: "claude")
        XCTAssertEqual(r1, .reserved)
        XCTAssertEqual(r2, .totalBudgetExhausted)

        // Exhausted DeepSeek stream must never be selected for follow-up RPCs.
        var engine = WorkspaceMergedSessionEngine(hostScope: hostScope, enabledRuntimes: [.codex, .deepseek])
        engine.ingestPage(
            runtime: .deepseek,
            page: makePage(runtime: "deepseek", items: [("d1", 1_700_000_005_000, nil, nil)], hasMore: false),
            isRefresh: true
        )
        engine.ingestPage(
            runtime: .codex,
            page: makePage(runtime: "codex", items: [("x1", 1_700_000_004_000, nil, nil)], nextCursor: "c2", hasMore: true),
            isRefresh: true
        )
        XCTAssertEqual(engine.nextRuntimeToFetch(), .codex)
        XCTAssertNil(engine.nextRuntimeToFetch(excluding: [.codex]))
    }

    // MARK: - C8: Controlled Global pageDisposition Contract (P1-3d)

    func testControlledGlobalPageDispositionContract() {
        XCTAssertEqual(
            SessionListMeta.resolvedDisposition(from: nil, isControlledGlobal: true),
            .unverifiedGlobalDisposition
        )
        XCTAssertEqual(
            SessionListMeta.resolvedDisposition(
                from: SessionListMeta(rawPageDisposition: "same_page_retry", retryReason: "git_ownership_pending"),
                isControlledGlobal: true
            ),
            .samePageRetry(reason: "git_ownership_pending")
        )
        XCTAssertEqual(
            SessionListMeta.resolvedDisposition(
                from: SessionListMeta(rawPageDisposition: "advance"),
                isControlledGlobal: true
            ),
            .advance
        )

        var engine = WorkspaceMergedSessionEngine(hostScope: hostScope, enabledRuntimes: [.codex])
        engine.ingestPage(
            runtime: .codex,
            page: makePage(
                runtime: "codex",
                items: [("x1", 1_700_000_005_000, nil, nil)],
                hasMore: false,
                listMeta: nil
            ),
            isControlledGlobal: true,
            isRefresh: true
        )
        let stream = engine.streams[.codex]
        XCTAssertEqual(stream?.integrity, .unverifiedGlobalDisposition)
        XCTAssertNil(stream?.verifiedTailBoundMs, "Unverified global page must not advance watermark")
        XCTAssertEqual(engine.projection(targetVisibleCount: 20).completeness, .partial)
    }

    // MARK: - M8: BrowseScope Resolution Rules

    func testBrowseScopeResolutionRespectsEnabledCountAndDefaultToggle() {
        var state = WorkspaceRuntimeSelectionState()

        // Single enabled runtime must never expose .all even if defaultShowAllRuntimes is true.
        XCTAssertEqual(
            state.resolvedBrowseScope(
                preferredRuntime: .codex,
                defaultShowAllRuntimes: true,
                availableRuntimeProviders: ["codex"],
                enabledRuntimes: [.codex]
            ),
            .single(.codex)
        )

        // Multiple enabled runtimes respect defaultShowAllRuntimes toggle when no manual override is set.
        XCTAssertEqual(
            state.resolvedBrowseScope(
                preferredRuntime: .claude,
                defaultShowAllRuntimes: true,
                availableRuntimeProviders: ["codex", "claude"],
                enabledRuntimes: [.codex, .claude]
            ),
            .all
        )
        XCTAssertEqual(
            state.resolvedBrowseScope(
                preferredRuntime: .claude,
                defaultShowAllRuntimes: false,
                availableRuntimeProviders: ["codex", "claude"],
                enabledRuntimes: [.codex, .claude]
            ),
            .single(.claude)
        )

        // Manual override to .all wins until reset, and still collapses to .single if reduced to 1 enabled runtime.
        state.setBrowseScope(.all)
        XCTAssertEqual(
            state.resolvedBrowseScope(
                preferredRuntime: .claude,
                defaultShowAllRuntimes: false,
                availableRuntimeProviders: ["codex", "claude"],
                enabledRuntimes: [.codex, .claude]
            ),
            .all
        )
        XCTAssertEqual(
            state.resolvedBrowseScope(
                preferredRuntime: .claude,
                defaultShowAllRuntimes: false,
                availableRuntimeProviders: ["codex", "claude"],
                enabledRuntimes: [.claude]
            ),
            .single(.claude)
        )
    }
}
