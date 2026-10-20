import XCTest
@testable import MimiRemote

final class ContextWindowUsageTests: XCTestCase {
    // MARK: - 剩余比例口径（与 Codex CLI 的 context left 一致）

    func testRemainingPercentSubtractsBaselineFromBothSides() {
        let window = 272_000
        XCTAssertEqual(ContextWindowUsage(usedTokens: 12_000, contextWindow: window).remainingPercent, 100, "首轮只占基线时显示满")
        XCTAssertEqual(ContextWindowUsage(usedTokens: 5_000, contextWindow: window).remainingPercent, 100, "低于基线不出现负占用")
        XCTAssertEqual(ContextWindowUsage(usedTokens: 142_000, contextWindow: window).remainingPercent, 50)
        XCTAssertEqual(ContextWindowUsage(usedTokens: 233_000, contextWindow: window).remainingPercent, 15)
        XCTAssertEqual(ContextWindowUsage(usedTokens: 400_000, contextWindow: window).remainingPercent, 0, "超出窗口按 0% 处理")
    }

    func testWindowNotLargerThanBaselineReportsZero() {
        XCTAssertEqual(ContextWindowUsage(usedTokens: 100, contextWindow: 12_000).remainingPercent, 0)
    }

    func testLowThresholdIsInclusive() {
        let window = 272_000
        XCTAssertTrue(ContextWindowUsage(usedTokens: 233_000, contextWindow: window).isLow)
        XCTAssertFalse(ContextWindowUsage(usedTokens: 230_000, contextWindow: window).isLow)
    }

    // MARK: - 从协议样本构造

    func testSampleUsesLastResponseNotCumulativeTotal() throws {
        let usage = try XCTUnwrap(ContextWindowUsage(sample: sample(
            total: 900_000,
            last: breakdown(input: 120_000, output: 2_000, total: 122_000),
            window: 272_000
        )))
        XCTAssertEqual(usage.usedTokens, 122_000, "total 是整段会话的累计消耗，不能当作当前占用")
        XCTAssertEqual(usage.contextWindow, 272_000)
    }

    func testSampleFallsBackToInputPlusOutputWhenLastTotalMissing() throws {
        let usage = try XCTUnwrap(ContextWindowUsage(sample: sample(
            total: 10,
            last: breakdown(input: 40_000, output: 1_000, total: nil),
            window: 200_000
        )))
        XCTAssertEqual(usage.usedTokens, 41_000)
    }

    func testSampleWithoutWindowOrLastIsHidden() {
        XCTAssertNil(ContextWindowUsage(sample: sample(total: 10, last: breakdown(input: 1, output: 1, total: 2), window: nil)), "窗口未知时不显示成 0%")
        XCTAssertNil(ContextWindowUsage(sample: sample(total: 10, last: breakdown(input: 1, output: 1, total: 2), window: 0)))
        XCTAssertNil(ContextWindowUsage(sample: sample(total: 10, last: nil, window: 200_000)), "旧协议缺 last 时不拿 total 估算")
    }

    func testProjectorCarriesModelContextWindow() {
        var projector = CodexAppServerEventProjector()
        let notification = CodexAppServerNotification(method: "thread/tokenUsage/updated", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"),
            "tokenUsage": .object([
                "total": .object(["inputTokens": .int(100), "outputTokens": .int(50), "totalTokens": .int(150)]),
                "last": .object(["inputTokens": .int(60), "outputTokens": .int(20), "totalTokens": .int(80)]),
                "modelContextWindow": .int(272_000)
            ])
        ]))
        guard case .sessionContext(let context, _) = projector.project(notification) else {
            return XCTFail("expected token context")
        }
        XCTAssertEqual(context.tokenUsage?.modelContextWindow, 272_000)
    }

    // MARK: - SessionStore 记录、展示与提示

    @MainActor
    func testStoreShowsUsageOnlyForCodexSessions() {
        let store = makeStore()
        let codex = session(id: "codex-1", runtimeProvider: "codex")
        let claude = session(id: "claude-1", runtimeProvider: "claude")
        let lowSample = sample(total: 1, last: breakdown(input: 1, output: 1, total: 250_000), window: 272_000)
        store.recordContextWindowUsage(lowSample, sessionID: codex.id)
        store.recordContextWindowUsage(lowSample, sessionID: claude.id)

        XCTAssertEqual(store.contextWindowUsage(for: codex)?.usedTokens, 250_000)
        XCTAssertNil(store.contextWindowUsage(for: claude), "Claude 的 last 是整回合聚合值，不展示")
    }

    @MainActor
    func testDismissedNoticeRearmsAfterUsageRecoversAboveThreshold() {
        let store = makeStore()
        let id: SessionID = "codex-1"
        store.recordContextWindowUsage(sample(total: 1, last: breakdown(input: 1, output: 1, total: 250_000), window: 272_000), sessionID: id)
        XCTAssertEqual(store.contextWindowUsageBySessionID[id]?.isLow, true)

        store.dismissContextWindowNotice(sessionID: id)
        store.recordContextWindowUsage(sample(total: 2, last: breakdown(input: 1, output: 1, total: 255_000), window: 272_000), sessionID: id)
        XCTAssertTrue(store.dismissedContextWindowNoticeSessionIDs.contains(id), "仍低于阈值时保持关闭，不反复弹出")

        store.recordContextWindowUsage(sample(total: 3, last: breakdown(input: 1, output: 1, total: 40_000), window: 272_000), sessionID: id)
        XCTAssertFalse(store.dismissedContextWindowNoticeSessionIDs.contains(id), "压缩回阈值以上后重新启用提示")
    }

    @MainActor
    func testSampleWithoutWindowKeepsPreviousUsage() {
        let store = makeStore()
        let id: SessionID = "codex-1"
        store.recordContextWindowUsage(sample(total: 1, last: breakdown(input: 1, output: 1, total: 100_000), window: 272_000), sessionID: id)
        store.recordContextWindowUsage(sample(total: 2, last: breakdown(input: 1, output: 1, total: 120_000), window: nil), sessionID: id)
        XCTAssertEqual(store.contextWindowUsageBySessionID[id]?.usedTokens, 100_000)
    }

    @MainActor
    func testPruningDropsUsageAndDismissalForEvictedSessions() {
        let store = makeStore()
        let sample = sample(total: 1, last: breakdown(input: 1, output: 1, total: 250_000), window: 272_000)
        store.recordContextWindowUsage(sample, sessionID: "kept")
        store.recordContextWindowUsage(sample, sessionID: "evicted")
        store.dismissContextWindowNotice(sessionID: "kept")
        store.dismissContextWindowNotice(sessionID: "evicted")

        store.pruneContextWindowState(validSessionIDs: ["kept"])

        XCTAssertEqual(Set(store.contextWindowUsageBySessionID.keys), ["kept"])
        XCTAssertEqual(store.dismissedContextWindowNoticeSessionIDs, ["kept"])
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore() -> SessionStore {
        SessionStore(appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore())
    }

    private func session(id: SessionID, runtimeProvider: String) -> AgentSession {
        AgentSession(
            id: id,
            projectID: "project-1",
            project: "Project",
            dir: "/workspace",
            title: "Context",
            status: "idle",
            source: runtimeProvider,
            runtimeProvider: runtimeProvider,
            resumeID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }

    private func breakdown(input: Int?, output: Int?, total: Int?) -> AppServerTokenUsageSample.Breakdown {
        AppServerTokenUsageSample.Breakdown(inputTokens: input, outputTokens: output, totalTokens: total)
    }

    private func sample(
        total: Int,
        last: AppServerTokenUsageSample.Breakdown?,
        window: Int?
    ) -> AppServerTokenUsageSample {
        AppServerTokenUsageSample(
            total: breakdown(input: nil, output: nil, total: total),
            last: last,
            modelContextWindow: window
        )
    }
}
