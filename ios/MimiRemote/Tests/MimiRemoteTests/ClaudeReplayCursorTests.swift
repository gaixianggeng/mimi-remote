import XCTest
@testable import MimiRemote

/// Claude 常驻会话的重连游标（#873）：长回合进行中也要随已投影的条目推进 `last_seen`，
/// 否则每次重开都把整轮重放一遍，其中已答复的补充信息请求会再弹出、随即收起。
final class ClaudeReplayCursorTests: XCTestCase {
    private let endpoint = "http://127.0.0.1:8787"
    private let threadID = "thread-replay-cursor"
    private let turnID = "turn-replay-cursor"

    func testClaudeItemCompletionIsAReplayBoundaryButStreamingDeltasAreNot() async throws {
        let (runtime, defaults, suiteName) = try makeClaudeRuntime()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await runtime.handle(CodexAppServerNotification(method: "item/agentMessage/delta", params: .object([
            "threadId": .string(threadID), "turnId": .string(turnID), "itemId": .string("msg-1"),
            "delta": .string("正在")
        ]), replaySequence: 11))
        await runtime.handle(CodexAppServerNotification(method: "item/completed", params: .object([
            "threadId": .string(threadID), "turnId": .string(turnID),
            "item": .object(["type": .string("agentMessage"), "id": .string("msg-1"), "text": .string("正在处理")])
        ]), replaySequence: 12))

        let events = await runtime.bufferedEvents(sessionID: threadID, replayPolicy: .all)
        let deltaBoundaries = events.compactMap { event -> UInt64?? in
            guard case .assistantDelta(_, let metadata) = event else { return nil }
            return .some(metadata.replayBoundarySequence)
        }
        XCTAssertFalse(deltaBoundaries.isEmpty, "流式增量应照常投影")
        XCTAssertTrue(deltaBoundaries.allSatisfy { $0 == nil }, "流式增量不能提交游标，否则冷启动只拿到消息后半段")

        let completion = try XCTUnwrap(events.compactMap { event -> AgentEventMetadata? in
            guard case .messageCompleted(_, let metadata) = event else { return nil }
            return metadata
        }.last)
        XCTAssertEqual(completion.replayBoundarySequence, 12, "完成的条目已写进历史，可以作为重连起点")
        XCTAssertEqual(completion.replayCursorEpoch, 0)
    }

    func testAppliedItemBoundaryMakesReconnectResumeAfterThatItem() async throws {
        let (runtime, defaults, suiteName) = try makeClaudeRuntime()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gatewaySession = "\(CodexAppServerSessionRuntime.gatewaySessionKey(defaults: defaults))-claude"

        // 回合仍在进行：只有回合边界会提交时，这里的游标会一直停在回合开始之前。
        await runtime.acknowledgeAppliedReplayBoundary(12, epoch: 0)
        XCTAssertEqual(
            CodexAppServerSessionRuntime.gatewayLastSeenSequence(
                endpoint: endpoint, gatewaySession: gatewaySession, runtimeProvider: "claude", defaults: defaults
            ),
            12
        )
        let url = try CodexAppServerSessionRuntime.gatewayURL(
            endpoint: endpoint, sessionID: "", runtimeProvider: "claude", defaults: defaults
        )
        let lastSeen = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "last_seen" }?.value
        XCTAssertEqual(lastSeen, "12", "重连应从已投影的条目之后补发，而不是整轮重放")
    }

    func testCodexItemCompletionDoesNotCarryAReplayBoundary() async throws {
        let runtime = CodexAppServerSessionRuntime(endpoint: endpoint, token: "test-token", runtimeProvider: "codex")
        await runtime.handle(CodexAppServerNotification(method: "item/completed", params: .object([
            "threadId": .string(threadID), "turnId": .string(turnID),
            "item": .object(["type": .string("agentMessage"), "id": .string("msg-1"), "text": .string("完成")])
        ])))
        let events = await runtime.bufferedEvents(sessionID: threadID, replayPolicy: .all)
        let completion = try XCTUnwrap(events.compactMap { event -> AgentEventMetadata? in
            guard case .messageCompleted(_, let metadata) = event else { return nil }
            return metadata
        }.last)
        XCTAssertNil(completion.replayBoundarySequence, "Codex 没有 bridge 序号，不参与 Claude 游标")
    }

    private func makeClaudeRuntime() throws -> (CodexAppServerSessionRuntime, UserDefaults, String) {
        let suiteName = "ClaudeReplayCursorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let runtime = CodexAppServerSessionRuntime(
            endpoint: endpoint,
            token: "test-token",
            runtimeProvider: "claude",
            gatewayDefaults: defaults
        )
        return (runtime, defaults, suiteName)
    }
}
