import Foundation
import XCTest
@testable import MimiRemote

/// #861：DeepSeek 回合以 `turn/end.reason.kind == "error"` 结束时，必须与 Codex/Claude 一样按失败收口。
///
/// 实测原因取自契约夹具 `stream/durable-events.json` 的 `turnEndReasonsObserved` 与
/// `stream/assistant-stream.json` 的 `endOutcomeEvidence`；只在源码里出现的原因
/// （max-tokens、blocked、interrupted、forked）按源码语义构造。
@MainActor
final class HarnessTurnFailureSettlementTests: XCTestCase {
    private let sessionID: SessionID = "h61-failure-session"

    // MARK: - 原因映射

    func testObservedTurnEndReasonsSettleLikeCodexAndClaude() throws {
        let reasons = try observedTurnEndReasons()
        XCTAssertEqual(
            Set(reasons.compactMap { $0["kind"]?.stringValue }), ["completed", "aborted", "error"],
            "夹具出现新的实测原因时，先在 HarnessTurnEndReason 里给出明确收口"
        )
        for reason in reasons {
            let kind = try XCTUnwrap(reason["kind"]?.stringValue)
            let metadata = try turnCompletedMetadata(turnEnd(seq: 20, turn: 2, reason: reason))
            switch kind {
            case "completed":
                XCTAssertNil(metadata.turnLifecycle, "正常完成沿用 reducer 的完成路径")
                XCTAssertNil(metadata.turnError)
            case "aborted":
                XCTAssertEqual(metadata.turnLifecycle, .interrupted, "取消仍是中断（#809）")
                XCTAssertNil(metadata.turnError)
            default:
                XCTAssertEqual(metadata.turnLifecycle, .failed, "出错结束不能再按已完成收口")
                let error = try XCTUnwrap(metadata.turnError, "失败必须带可展示的原因")
                XCTAssertEqual(error.code, "UNKNOWN", "code 原样保留")
                XCTAssertEqual(error.message, reason["error"]?["message"]?.stringValue)
            }
        }
    }

    /// 实测的工具回合出错只留下 code：失败卡片退回机器码，不能是空的。
    func testErrorWithoutMessageFallsBackToCode() throws {
        let table = try XCTUnwrap(
            try harnessFixtureJSON("stream/assistant-stream.json")["endOutcomeEvidence"] as? [String: Any]
        )["table"] as? [[String: Any]]
        let row = try XCTUnwrap(table?.first { ($0["run"] as? String) == "工具回合 error" })
        let reason = try jsonValue(try XCTUnwrap(row["turnEnd"]))
        let metadata = try turnCompletedMetadata(turnEnd(seq: 17, turn: 1, reason: reason))

        XCTAssertEqual(metadata.turnLifecycle, .failed)
        XCTAssertEqual(metadata.turnError?.message, "UNKNOWN")
        XCTAssertEqual(metadata.turnError?.code, "UNKNOWN")
    }

    func testSourceOnlyReasonsSettleBySourceSemantics() throws {
        let failed: [(String, String, String)] = [
            ("max-tokens", "MAX_TOKENS", L10n.text("harness.turn_failed_max_tokens")),
            ("blocked", "BLOCKED", L10n.text("harness.turn_failed_blocked")),
            ("future-kind", "future-kind", L10n.format("harness.turn_failed_unknown", "future-kind")),
        ]
        for (kind, code, message) in failed {
            let metadata = try turnCompletedMetadata(turnEnd(seq: 30, turn: 4, reason: .object(["kind": .string(kind)])))
            XCTAssertEqual(metadata.turnLifecycle, .failed, "\(kind) 没有正常跑完，按失败收口")
            XCTAssertEqual(metadata.turnError?.code, code)
            XCTAssertEqual(metadata.turnError?.message, message)
        }
        for kind in ["interrupted", "forked"] {
            let metadata = try turnCompletedMetadata(turnEnd(seq: 30, turn: 4, reason: .object(["kind": .string(kind)])))
            XCTAssertEqual(metadata.turnLifecycle, .interrupted, "\(kind) 是补写的收尾，按中断而不是失败")
            XCTAssertNil(metadata.turnError)
        }
        let legacy = HarnessDurableEvent(
            type: HarnessWireEventType.turnEnd, seq: 30, time: nil, data: .object(["turn": .number(4)])
        )
        XCTAssertNil(try turnCompletedMetadata(legacy).turnLifecycle, "缺少 reason 的旧记录按完成处理")
    }

    func testErrorMessageIsRedactedButCodeKept() throws {
        let raw = [
            "load failed: /Users/someone/.dsh/routes.json",
            "upstream said: bad request",
            "Authorization: Basic dXNlcjpwYXNz",
            "proxy-authorization: Digest username=\"u\", response=\"6629fae4\"",
            "headers: {\"authorization\":\"Bearer abc.def\"}",
            "api_key=sk-0123456789abcdef password: hunter2; max_tokens: 8192",
        ].joined(separator: "\n")
        let reason: HarnessJSONValue = .object([
            "kind": .string("error"),
            "error": .object(["message": .string(raw), "code": .string("MISSING_CREDENTIAL")]),
        ])
        let error = try XCTUnwrap(try turnCompletedMetadata(turnEnd(seq: 5, turn: 1, reason: reason)).turnError)

        XCTAssertEqual(error.code, "MISSING_CREDENTIAL")
        for secret in ["someone", "dXNlcjpwYXNz", "6629fae4", "abc.def", "sk-0123456789abcdef", "hunter2"] {
            XCTAssertFalse(error.message.contains(secret), "展示文案不得带出 \(secret)")
        }
        XCTAssertTrue(error.message.contains("~/.dsh/routes.json"), "路径保留可读部分")
        XCTAssertTrue(error.message.contains("upstream said: bad request"), "认证头之外的行原样保留")
        XCTAssertTrue(error.message.contains("max_tokens: 8192"), "普通参数不能被误抹")

        let long = HarnessTurnEndReason.sanitizedMessage(String(repeating: "x", count: 2_000))
        XCTAssertEqual(long.count, 501, "过长的错误链截断并标出省略")
    }

    // MARK: - 实时收口、提醒与历史

    func testErrorTurnFailsSessionWithReasonAndFailedNotification() async throws {
        let metadata = try turnCompletedMetadata(missingCredentialTurnEnd())
        let output = await EventReducer().reduce(
            .turnCompleted(metadata), fallbackSessionID: sessionID, outputIdleClearDelay: 0
        )

        XCTAssertEqual(output.statusUpdates.map { $0.1 }, [SessionStatus.failed.rawValue])
        let failure = try XCTUnwrap(liveFailureMessage(in: output), "时间线必须出现失败原因")
        XCTAssertEqual(failure.kind, .error)
        XCTAssertEqual(failure.content, L10n.format("ui.run_error_value", "No credential configured for this route."))

        let store = makeSessionStore()
        let notification = try XCTUnwrap(store.runtimeNotification(
            for: .turnCompleted(metadata), fallbackSessionID: sessionID
        ))
        XCTAssertEqual(notification.kind, .failed)
        XCTAssertEqual(notification.title, L10n.text("ui.session_failed"), "前台提醒不能再是「会话已完成」")
    }

    func testHistoryReopenKeepsOneFailureCardWithLiveIdentity() async throws {
        let turnEnd = try missingCredentialTurnEnd()
        let metadata = try turnCompletedMetadata(turnEnd)
        let output = await EventReducer().reduce(
            .turnCompleted(metadata), fallbackSessionID: sessionID, outputIdleClearDelay: 0
        )
        let live = try XCTUnwrap(liveFailureMessage(in: output))
        let history = HarnessHistoryProjection.messages(from: [turnEnd], sessionID: sessionID)

        XCTAssertEqual(history.map(\.id), [live.id], "历史卡片与实时卡片同一身份")
        XCTAssertEqual(history.map(\.content), [live.content])

        let conversation = ConversationStore()
        conversation.markCurrentAssistantCompleted(metadata: metadata, fallbackSessionID: sessionID, errorMessage: live)
        conversation.setHistory(history, sessionID: sessionID)
        let errors = conversation.messages(for: sessionID).filter { $0.kind == .error }
        XCTAssertEqual(errors.map(\.content), [live.content], "重开会话后失败原因仍在，且不重复")
    }

    func testCompletedAndAbortedTurnsLeaveNoFailureCardInHistory() throws {
        let events = [
            try turnEnd(seq: 3, turn: 1, reason: .object(["kind": .string("completed")])),
            try turnEnd(seq: 6, turn: 2, reason: .object([
                "kind": .string("aborted"), "reason": .object(["kind": .string("user")]),
            ])),
        ]
        XCTAssertTrue(HarnessHistoryProjection.messages(from: events, sessionID: sessionID).isEmpty)
    }

    /// 冷开会话只恢复终态：出错的旧轮次恢复成失败，但不再弹「会话失败」。
    func testColdOpenRestoresFailedStatusWithoutNotification() async throws {
        let turnStart = HarnessDurableEvent(
            type: HarnessWireEventType.turnStart, seq: 8, time: nil, data: .object(["turn": .number(2)])
        )
        let opening = HarnessSnapshot(
            type: HarnessWireFrame.snapshot,
            header: HarnessSnapshotHeader(
                version: 3, id: sessionID, createdAt: nil, cwd: "/fixture", isSeeded: false, agentPreset: nil
            ),
            cursor: 9,
            records: [turnStart, try missingCredentialTurnEnd()].map { HarnessSnapshotRecord(type: "event", event: $0) },
            hasMore: false,
            projections: nil,
            assistantStream: HarnessAssistantStreamBaseline(revision: 0, activeAttempt: nil)
        )
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in }),
            fetchSnapshot: { _ in opening },
            reconcileDurableEvent: { _, _ in HarnessDurableReconciliation() },
            settleAssistantIdentity: { _, _, attemptMessageID in attemptMessageID },
            coveredDurableSequence: { _ in 9 },
            reportCoveredDurableSequence: { _, _ in }
        )
        var events: [AgentEvent] = []
        client.onEvent = { events.append($0) }
        client.connect(sessionID: sessionID, replayBufferedEvents: false)
        await waitFor { client.journal?.hasOpenedSnapshot == true }

        let restored = events.compactMap { event -> (String?, AgentEventMetadata)? in
            guard case .sessionStatus(let status, let metadata) = event else { return nil }
            return (status, metadata)
        }
        XCTAssertEqual(restored.map { $0.0 }, [SessionStatus.failed.rawValue], "出错的旧轮次不能恢复成已完成")
        XCTAssertFalse(events.contains { if case .turnCompleted = $0 { return true } else { return false } })

        let store = makeSessionStore()
        let status = try XCTUnwrap(restored.first)
        XCTAssertNil(
            store.runtimeNotification(for: .sessionStatus(status.0, status.1), fallbackSessionID: sessionID),
            "恢复旧结局不能重新弹提醒"
        )
        let plain = AgentEventMetadata(
            seq: nil, sessionID: sessionID, turnID: nil, itemID: nil, messageID: nil,
            clientMessageID: nil, revision: nil, createdAt: nil
        )
        XCTAssertNotNil(
            store.runtimeNotification(for: .sessionStatus("failed", plain), fallbackSessionID: sessionID),
            "实时上报的失败状态仍照常提醒"
        )
        client.disconnect()
    }

    // MARK: - 支撑

    private func missingCredentialTurnEnd() throws -> HarnessDurableEvent {
        try turnEnd(seq: 9, turn: 2, reason: .object([
            "kind": .string("error"),
            "error": .object([
                "message": .string("No credential configured for this route."),
                "code": .string("MISSING_CREDENTIAL"),
            ]),
        ]))
    }

    private func turnEnd(seq: Int, turn: Int, reason: HarnessJSONValue) throws -> HarnessDurableEvent {
        HarnessDurableEvent(
            type: HarnessWireEventType.turnEnd,
            seq: seq,
            time: nil,
            data: .object(["turn": .number(Double(turn)), "reason": reason])
        )
    }

    private func turnCompletedMetadata(_ event: HarnessDurableEvent) throws -> AgentEventMetadata {
        let projected = HarnessPresentationProjector.project(durableEvent: event, sessionID: sessionID)
        guard projected.count == 1, case .turnCompleted(let metadata) = projected[0] else {
            XCTFail("turn/end 必须恰好投影成一个 turnCompleted：\(projected)")
            throw HarnessTransportError.timedOut
        }
        return metadata
    }

    private func liveFailureMessage(in output: EventReducerOutput) -> AgentMessage? {
        for mutation in output.messageMutations {
            if case .markCurrentAssistantCompleted(_, _, let errorMessage) = mutation, let errorMessage {
                return errorMessage
            }
        }
        return nil
    }

    private func makeSessionStore() -> SessionStore {
        SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
    }

    private func observedTurnEndReasons() throws -> [HarnessJSONValue] {
        let observations = try XCTUnwrap(
            try harnessFixtureJSON("stream/durable-events.json")["observations"] as? [[String: Any]]
        )
        let value = try XCTUnwrap(observations.first { ($0["label"] as? String) == "turnEndReasonsObserved" }?["value"])
        guard case .array(let reasons) = try jsonValue(value) else {
            throw HarnessTransportError.timedOut
        }
        return reasons
    }

    private func jsonValue(_ object: Any) throws -> HarnessJSONValue {
        try JSONDecoder().decode(HarnessJSONValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func harnessFixtureJSON(_ name: String) throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("contracts/harness-native/fixtures").appendingPathComponent(name)
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "夹具 \(name) 顶层不是对象")
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
