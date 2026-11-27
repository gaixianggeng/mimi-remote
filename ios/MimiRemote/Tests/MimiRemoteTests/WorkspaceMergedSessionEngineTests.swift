import Foundation
import XCTest
@testable import MimiRemote

final class WorkspaceMergedSessionEngineTests: XCTestCase {
    private let hostScope = HostScope(profileID: "host-a", installationID: "inst-a", generation: 1)

    private func makeSession(
        id: String,
        projectID: String = "ws-1",
        runtimeProvider: String,
        updatedAtMs: Int64,
        parentThreadID: String? = nil,
        isSubagent: Bool? = nil
    ) -> AgentSession {
        let date = Date(timeIntervalSince1970: Double(updatedAtMs) / 1000.0)
        return AgentSession(
            id: id,
            projectID: projectID,
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

        // Legacy unverified stream with hasMore == true must NOT be auto-pumped once visible target is met.
        var noStormEngine = WorkspaceMergedSessionEngine(
            hostScope: hostScope,
            enabledRuntimes: [.codex, .agy]
        )
        noStormEngine.ingestPage(
            runtime: .codex,
            page: makePage(runtime: "codex", items: [("x1", 1_700_000_020_000, nil, nil)], hasMore: false),
            isRefresh: true
        )
        let agyPage1: [(id: String, epochMs: Int64, parentThreadID: String?, isSubagent: Bool?)] =
            (1...20).map { i in
                ("a-\(i)", 1_700_000_000_000 + Int64((21 - i) * 100), nil, nil)
            }
        noStormEngine.ingestPage(
            runtime: .agy,
            page: makePage(runtime: "agy", items: agyPage1, nextCursor: "agy-p2", hasMore: true, listMeta: nil),
            isRefresh: true
        )
        XCTAssertFalse(
            noStormEngine.needsMorePages(targetVisibleCount: 20),
            "Once Page 1 already satisfies target visible count, unverified Agy must not trigger follow-up RPC storms"
        )
        XCTAssertNil(noStormEngine.nextRuntimeToFetch(onlyHealthyForStrict: true))

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

    // MARK: - Review Regression Coverage (#5.1 / #5.2 / #5.4 / #5.5 / #5.6 / #5.7)

    func testWireISO8601TimestampParsingAndUnitIsolation() {
        let fractionalISO = "2023-11-14T22:13:22.500Z"
        let wholeSecondISO = "2023-11-14T22:13:22Z"

        let deepSeekWire: [String: CodexAppServerJSONValue] = [
            "id": .string("d-iso"),
            "updatedAt": .string(fractionalISO)
        ]
        let legacyClaudeWire: [String: CodexAppServerJSONValue] = [
            "id": .string("c-iso"),
            "cliVersion": .string("alleycat-claude-bridge/0.1.0"),
            "updatedAt": .string(wholeSecondISO)
        ]
        let codexWire: [String: CodexAppServerJSONValue] = [
            "id": .string("x-iso"),
            "updatedAt": .string(fractionalISO)
        ]

        XCTAssertEqual(
            RawSortEvidence.fromWireThread(deepSeekWire, runtimeProvider: "deepseek"),
            .epochMs(1_700_000_002_500)
        )
        XCTAssertEqual(
            RawSortEvidence.fromWireThread(legacyClaudeWire, runtimeProvider: "claude"),
            .epochMs(1_700_000_002_000)
        )
        XCTAssertEqual(
            RawSortEvidence.fromWireThread(codexWire, runtimeProvider: "codex"),
            .epochMs(1_700_000_002_500)
        )
    }

    func testLoadingStreamNeverEmitsCompleteExhaustedAndNormalizesCleanly() {
        var engine = WorkspaceMergedSessionEngine(
            hostScope: hostScope,
            enabledRuntimes: [.codex, .claude]
        )
        engine.ingestPage(
            runtime: .codex,
            page: makePage(runtime: "codex", items: [("x1", 1_700_000_010_000, nil, nil)], hasMore: false),
            isRefresh: true
        )
        engine.markLoading(.claude)

        let loadingProjection = engine.projection(targetVisibleCount: 20)
        XCTAssertEqual(loadingProjection.completeness, .partial)
        XCTAssertTrue(loadingProjection.canLoadMore)

        engine.normalizeLoadingStreams()
        XCTAssertEqual(engine.streams[.claude]?.status, .idle)

        engine.ingestPage(
            runtime: .claude,
            page: makePage(
                runtime: "claude",
                items: [("c1", 1_700_000_009_000, nil, nil)],
                nextCursor: "c-p2",
                hasMore: true
            ),
            isRefresh: true
        )
        engine.markLoading(.claude)
        let loadMoreProjection = engine.projection(targetVisibleCount: 40)
        XCTAssertEqual(loadMoreProjection.completeness, .partial)
        XCTAssertTrue(loadMoreProjection.canLoadMore)

        engine.normalizeLoadingStreams()
        XCTAssertEqual(engine.streams[.claude]?.status, .ready)
    }

    @MainActor
    func testReconcileAvailableRuntimeProvidersRevivesHostDisabledWithoutWipingLoaded() async {
        let project = AgentProject(id: "ws-reconcile", name: "demo", path: "/Users/dev/demo")
        let codexSession = makeSession(id: "x1", runtimeProvider: "codex", updatedAtMs: 1_700_000_010_000)
        let claudeSession = makeSession(id: "c1", runtimeProvider: "claude", updatedAtMs: 1_700_000_009_000)
        let client = MergedCoordinatorTestClient(projects: [project]) { runtime, _ in
            switch runtime {
            case "codex":
                return .success(SessionsPage(
                    sessions: [codexSession],
                    nextCursor: nil,
                    hasMore: false,
                    rawSortEvidenceBySessionID: ["x1": .epochMs(1_700_000_010_000)]
                ))
            case "claude":
                return .success(SessionsPage(
                    sessions: [claudeSession],
                    nextCursor: nil,
                    hasMore: false,
                    rawSortEvidenceBySessionID: ["c1": .epochMs(1_700_000_009_000)]
                ))
            default:
                return .success(SessionsPage(sessions: [], nextCursor: nil, hasMore: false))
            }
        }
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.availableRuntimeProviders = ["codex"]

        let coordinator = WorkspaceMergedSessionCoordinator()
        let key = WorkspaceMergedPresentationKey(
            hostScope: appStore.activeHostScope,
            workspaceID: project.id,
            workspacePath: project.path,
            enabledRuntimes: [.codex, .claude]
        )

        await coordinator.refresh(project: project, key: key, sessionStore: store)
        XCTAssertEqual(client.callCount(for: "codex"), 1)
        XCTAssertEqual(client.callCount(for: "claude"), 0)

        // Probe finishes and adds Claude: reconcile must revive Claude without wiping or refetching Codex.
        store.availableRuntimeProviders = ["codex", "claude"]
        await coordinator.reconcileAvailableRuntimeProviders(project: project, key: key, sessionStore: store)

        XCTAssertEqual(client.callCount(for: "codex"), 1)
        XCTAssertEqual(client.callCount(for: "claude"), 1)
        let projection = coordinator.projection(for: key, sessionStore: store)
        XCTAssertEqual(projection.visibleSessions.map(\.id), ["x1", "c1"])
        XCTAssertEqual(projection.completeness, .completeExhausted)
        XCTAssertEqual(coordinator.loadState(for: key), .loaded)
    }

    @MainActor
    func testRateLimitAndCancellationBlockRuntimeInPumpWithoutStormOrFalseFailure() async {
        let project = AgentProject(id: "ws-throttle", name: "demo", path: "/Users/dev/demo")
        let codexSession = makeSession(id: "x1", runtimeProvider: "codex", updatedAtMs: 1_700_000_010_000)
        let claudeSession = makeSession(id: "c1", runtimeProvider: "claude", updatedAtMs: 1_700_000_009_000)
        var page2Error: Error = sessionListPolicyError(retryAfterMs: 15_000)
        let client = MergedCoordinatorTestClient(projects: [project]) { runtime, cursor in
            if runtime == "codex" {
                return .success(SessionsPage(
                    sessions: [codexSession],
                    nextCursor: nil,
                    hasMore: false,
                    rawSortEvidenceBySessionID: ["x1": .epochMs(1_700_000_010_000)]
                ))
            }
            if cursor == nil {
                return .success(SessionsPage(
                    sessions: [claudeSession],
                    nextCursor: "c-p2",
                    hasMore: true,
                    rawSortEvidenceBySessionID: ["c1": .epochMs(1_700_000_009_000)]
                ))
            }
            return .failure(page2Error)
        }
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.availableRuntimeProviders = ["codex", "claude"]

        let coordinator = WorkspaceMergedSessionCoordinator()
        let key = WorkspaceMergedPresentationKey(
            hostScope: appStore.activeHostScope,
            workspaceID: project.id,
            workspacePath: project.path,
            enabledRuntimes: [.codex, .claude]
        )

        // Initial refresh fetches page 1 for codex & claude, then page 2 for claude hits -32080 (>2s):
        // must stop after 1 page-2 attempt (total 2 calls for claude), never tight-loop 12x or emit failure banner.
        await coordinator.refresh(project: project, key: key, sessionStore: store)
        XCTAssertEqual(client.callCount(for: "claude"), 2)
        let afterRateLimit = coordinator.projection(for: key, sessionStore: store)
        XCTAssertEqual(afterRateLimit.visibleSessions.map(\.id), ["x1", "c1"])
        XCTAssertNil(afterRateLimit.partialNotice)
        XCTAssertEqual(coordinator.loadState(for: key), .loaded)

        // Next loadMore hits per-runtime CancellationError on page 2: must stop after 1 attempt and stay loaded.
        page2Error = CancellationError()
        await coordinator.loadMore(project: project, key: key, sessionStore: store)
        XCTAssertEqual(client.callCount(for: "claude"), 3)
        let afterCancel = coordinator.projection(for: key, sessionStore: store)
        XCTAssertEqual(afterCancel.visibleSessions.map(\.id), ["x1", "c1"])
        XCTAssertNil(afterCancel.partialNotice)
        XCTAssertEqual(coordinator.loadState(for: key), .loaded)
    }

    @MainActor
    func testNewlyCreatedAndArchivedCanonicalKeyIsolationAndRunningProtection() async throws {
        let project = AgentProject(id: "ws-canonical", name: "demo", path: "/Users/dev/demo")
        let codexCreated = makeSession(
            id: "shared-id",
            projectID: project.id,
            runtimeProvider: "codex",
            updatedAtMs: 1_700_000_010_000
        )
        let claudeSameID = makeSession(
            id: "shared-id",
            projectID: project.id,
            runtimeProvider: "claude",
            updatedAtMs: 1_700_000_009_000
        )
        let codexLoaded = makeSession(
            id: "loaded-only",
            projectID: project.id,
            runtimeProvider: "codex",
            updatedAtMs: 1_700_000_008_000
        )
        let client = MergedCoordinatorTestClient(projects: [project]) { runtime, _ in
            if runtime == "codex" {
                return .success(SessionsPage(
                    sessions: [codexLoaded],
                    nextCursor: nil,
                    hasMore: false,
                    rawSortEvidenceBySessionID: ["loaded-only": .epochMs(1_700_000_008_000)]
                ))
            }
            return .success(SessionsPage(sessions: [], nextCursor: nil, hasMore: false))
        }
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.availableRuntimeProviders = ["codex", "claude"]
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))
        store.sessions = [codexCreated, claudeSameID]
        store.recordWorkspaceCreatedSession(codexCreated, in: workspace, runtimeProvider: "codex")

        let coordinator = WorkspaceMergedSessionCoordinator()
        let key = WorkspaceMergedPresentationKey(
            hostScope: appStore.activeHostScope,
            workspaceID: project.id,
            workspacePath: project.path,
            enabledRuntimes: [.codex, .claude]
        )

        await coordinator.refresh(project: project, key: key, sessionStore: store)
        let createdProjection = coordinator.projection(for: key, sessionStore: store)
        XCTAssertEqual(
            createdProjection.visibleSessions.map { "\($0.runtimeProvider ?? ""):\($0.id)" },
            ["codex:shared-id", "codex:loaded-only"],
            "Newly created codex session must not promote same-ID claude session"
        )

        // Archive loaded-only while absent from store.sessions -> must still be hidden via engine rawEntries.
        store.sessions = []
        store.archivedSessionIDs = ["loaded-only"]
        XCTAssertFalse(
            coordinator.projection(for: key, sessionStore: store).visibleSessions.contains { $0.id == "loaded-only" }
        )

        // Selected protection matches isListableSession.
        store.selectedSessionID = "loaded-only"
        XCTAssertTrue(
            coordinator.projection(for: key, sessionStore: store).visibleSessions.contains { $0.id == "loaded-only" }
        )

        // Running protection matches isListableSession.
        store.selectedSessionID = nil
        var runningCodex = codexLoaded
        runningCodex.status = SessionStatus.running.rawValue
        store.sessions = [runningCodex]
        XCTAssertTrue(
            coordinator.projection(for: key, sessionStore: store).visibleSessions.contains { $0.id == "loaded-only" }
        )
    }

    @MainActor
    func testSamePageRetryAndWorstIntegrityPreservedInPresentationFill() async throws {
        let project = AgentProject(id: "ws-fill", name: "demo", path: "/Users/dev/demo")
        let agy1 = makeSession(id: "a1", projectID: project.id, runtimeProvider: "agy", updatedAtMs: 1_700_000_010_000)
        let agy2 = makeSession(id: "a2", projectID: project.id, runtimeProvider: "agy", updatedAtMs: 1_700_000_009_000)
        let client = MergedCoordinatorTestClient(projects: [project]) { _, cursor in
            if cursor == nil {
                return .success(SessionsPage(
                    sessions: [agy1],
                    nextCursor: "c2",
                    hasMore: true,
                    listMeta: nil
                ))
            }
            return .success(SessionsPage(
                sessions: [agy2],
                nextCursor: "c2",
                hasMore: true,
                listMeta: SessionListMeta(
                    complete: true,
                    rawPageDisposition: "same_page_retry",
                    retryReason: "git_ownership_pending"
                )
            ))
        }
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))

        let filled = try await store.sessionListPageFillingPresentationWindow(
            client: client,
            workspace: workspace,
            runtimeProvider: "agy",
            cursor: nil,
            limit: 10,
            consistency: .authoritative,
            source: .workspaceForeground,
            expectedHostScope: appStore.activeHostScope
        )
        XCTAssertEqual(filled.sessions.map(\.id), ["a1", "a2"])
        XCTAssertEqual(filled.nextCursor, "c2")
        XCTAssertTrue(filled.hasMore)
        XCTAssertEqual(
            SessionListMeta.resolvedDisposition(from: filled.listMeta, isControlledGlobal: false),
            .samePageRetry(reason: "git_ownership_pending")
        )
        XCTAssertEqual(
            SessionListMeta.resolvedIntegrity(from: filled.listMeta, runtimeProvider: "agy", isControlledGlobal: false),
            .unverifiedHealth,
            "Earlier sub-page missing listMeta on agy must not be upgraded to trusted by later sub-page"
        )
    }

    @MainActor
    func testLiveProjectionHidesSessionNewlyMarkedAsSubagentInStore() async throws {
        let project = AgentProject(id: "ws-child-live", name: "demo", path: "/Users/dev/demo")
        let rootSession = makeSession(
            id: "s-becomes-child",
            projectID: project.id,
            runtimeProvider: "codex",
            updatedAtMs: 1_700_000_010_000
        )
        let siblingRoot = makeSession(
            id: "s-stays-root",
            projectID: project.id,
            runtimeProvider: "codex",
            updatedAtMs: 1_700_000_009_000
        )
        let client = MergedCoordinatorTestClient(projects: [project]) { _, _ in
            .success(SessionsPage(
                sessions: [rootSession, siblingRoot],
                nextCursor: nil,
                hasMore: false,
                rawSortEvidenceBySessionID: [
                    "s-becomes-child": .epochMs(1_700_000_010_000),
                    "s-stays-root": .epochMs(1_700_000_009_000)
                ]
            ))
        }
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.availableRuntimeProviders = ["codex"]

        let coordinator = WorkspaceMergedSessionCoordinator()
        let key = WorkspaceMergedPresentationKey(
            hostScope: appStore.activeHostScope,
            workspaceID: project.id,
            workspacePath: project.path,
            enabledRuntimes: [.codex]
        )

        await coordinator.refresh(project: project, key: key, sessionStore: store)
        XCTAssertEqual(
            coordinator.projection(for: key, sessionStore: store).visibleSessions.map(\.id),
            ["s-becomes-child", "s-stays-root"]
        )

        // Store later learns s-becomes-child is a subagent; even though directoryScopedSessionsUnsorted
        // filters it out via isListableSession, live projection must hide it immediately.
        let markedChild = makeSession(
            id: "s-becomes-child",
            projectID: project.id,
            runtimeProvider: "codex",
            updatedAtMs: 1_700_000_010_000,
            parentThreadID: "s-stays-root",
            isSubagent: true
        )
        store.sessions = [markedChild, siblingRoot]

        XCTAssertEqual(
            coordinator.projection(for: key, sessionStore: store).visibleSessions.map(\.id),
            ["s-stays-root"]
        )
    }

    @MainActor
    func testCodexMergedFirstPageHonorsSinglePageBudgetLimit() async throws {
        let project = AgentProject(id: "ws-codex-budget", name: "demo", path: "/Users/dev/demo")
        var pageIndex = 0
        let client = MergedCoordinatorTestClient(projects: [project]) { _, cursor in
            pageIndex += 1
            let child = self.makeSession(
                id: "child-\(pageIndex)",
                projectID: project.id,
                runtimeProvider: "codex",
                updatedAtMs: 1_700_000_010_000 - Int64(pageIndex * 100),
                parentThreadID: "root-parent",
                isSubagent: true
            )
            return .success(SessionsPage(
                sessions: [child],
                nextCursor: "cursor-\(pageIndex)",
                hasMore: true,
                rawSortEvidenceBySessionID: [child.id: .epochMs(1_700_000_010_000 - Int64(pageIndex * 100))]
            ))
        }
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.availableRuntimeProviders = ["codex"]

        // Single-page call for Codex with fillsPresentationWindow: false must make exactly 1 server RPC
        // even when page 1 contains only subagents and hasMore == true.
        let singlePage = try await store.workspaceRuntimeSessionsPage(
            projectID: project.id,
            runtimeProvider: "codex",
            cursor: nil,
            limit: 20,
            fillsPresentationWindow: false,
            preservesWireOrder: true
        )
        XCTAssertEqual(client.callCount(for: "codex"), 1)
        XCTAssertEqual(singlePage.nextCursor, "cursor-1")
        XCTAssertTrue(singlePage.hasMore)

        // Full coordinator refresh must stay bounded by SessionListRPCBudgetLedger maxPerRuntimeRPCs (12),
        // never multiplying 12 waves x 12 internal fill pages.
        let coordinator = WorkspaceMergedSessionCoordinator()
        let key = WorkspaceMergedPresentationKey(
            hostScope: appStore.activeHostScope,
            workspaceID: project.id,
            workspacePath: project.path,
            enabledRuntimes: [.codex]
        )
        await coordinator.refresh(project: project, key: key, sessionStore: store, restartFromFirst: true)
        XCTAssertEqual(client.callCount(for: "codex"), 13, "1 standalone single-page call + at most 12 budgeted coordinator RPCs")
    }
}

private final class MergedCoordinatorTestClient: SessionStoreAPIClient {
    private let projectsResult: [AgentProject]
    private let pageHandler: (String, String?) -> Result<SessionsPage, Error>
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    init(
        projects: [AgentProject],
        pageHandler: @escaping (String, String?) -> Result<SessionsPage, Error>
    ) {
        self.projectsResult = projects
        self.pageHandler = pageHandler
    }

    func callCount(for runtimeProvider: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[runtimeProvider, default: 0]
    }

    func projects() async throws -> [AgentProject] { projectsResult }
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] { [] }
    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        SessionsPage(sessions: [])
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        runtimeProvider: String,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        lock.lock()
        counts[runtimeProvider, default: 0] += 1
        lock.unlock()
        return try pageHandler(runtimeProvider, cursor).get()
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] { [] }
}
