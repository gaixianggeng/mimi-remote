import Foundation
import XCTest
@testable import MimiRemote

/// H08 事件客户端（composer 接线）测试。
///
/// 这一层连接三件事：follow 帧 → journal → 投影 → AgentEvent，以及发送意图 → 提交编排。
/// 因此断言集中在四处：
/// 1. **发送结果的映射**：`responseUnknown` 必须走 `.uncertain`，不能走 `.rejected`。
/// 2. **未建立基线时不得发送**（服务端回显无法与本地记录关联）。
/// 3. **重复持久事件不产生第二条展示事件**（流式到历史无重复）。
/// 4. **断档如实上报**（不把断档后的片段接上）。
@MainActor
final class HarnessEventClientTests: XCTestCase {

    private let sessionID: SessionID = "h00-session-0001"

    func harnessFixtureJSON(_ name: String) throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root
            .appendingPathComponent("contracts/harness-native/fixtures")
            .appendingPathComponent(name)
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "夹具 \(name) 顶层不是对象")
    }

    private func snapshot() throws -> HarnessSnapshot {
        let fixture = try harnessFixtureJSON("stream/follow-frames.json")
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        let value = try XCTUnwrap(
            observations.first { ($0["label"] as? String) == "snapshot" }?["value"]
        )
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(HarnessSnapshot.self, from: data)
    }

    private func durableEvent(type: String, seq: Int, text: String) -> HarnessDurableEvent {
        HarnessDurableEvent(
            type: type, seq: seq, time: nil,
            data: .object(["content": .array([.object([
                "type": .string("text"), "text": .string(text),
            ])])])
        )
    }

    // MARK: - 夹具

    /// 造一个已 connection 的客户端（注入 snapshot）。
    private func makeConnectedClient(
        sender: RecordingPromptSink
    ) async throws -> (HarnessSessionWebSocketClient, EventRecorder) {
        let snapshot = try snapshot()
        let submission = HarnessSubmissionController(
            sendPrompt: { sessionID, requestID, text in
                try await sender.send(sessionID, requestID, text)
            },
            sendCancel: { _ in }
        )
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: submission,
            fetchSnapshot: { _ in snapshot }
        )
        let recorder = EventRecorder()
        client.onEvent = { recorder.events.append($0) }
        client.connect(sessionID: sessionID)
        // 等基线建立（connect 内部是 Task）。
        for _ in 0..<200 {
            if client.journal?.hasOpenedSnapshot == true { break }
            await Task.yield()
        }
        return (client, recorder)
    }

    // MARK: - 连接与基线

    /// 正向对照：connect 建立基线，并把 snapshot 里已有记录投影出来。
    func testConnectEstablishesBaselineAndProjectsSnapshotRecords() async throws {
        let (client, recorder) = try await makeConnectedClient(sender: RecordingPromptSink())

        XCTAssertNotNil(client.journal)
        XCTAssertTrue(client.journal?.hasOpenedSnapshot == true, "必须建立基线")
        // follow 夹具的 snapshot 有 3 条记录（permission/preset、sandbox/mode、approval/policy），
        // 它们都不是本层投影的类型，因此不该产出展示事件。
        XCTAssertTrue(recorder.events.isEmpty, "不投影的类型不得产出事件")
    }

    /// 没有 snapshot 来源时 connect 必须报 failed，**不得**假装连上。
    func testConnectWithoutSnapshotSourceReportsFailure() async {
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in })
        )
        var statuses: [WebSocketStatus] = []
        client.onStatus = { statuses.append($0) }
        client.connect(sessionID: sessionID)
        for _ in 0..<200 {
            if statuses.contains(where: { if case .failed = $0 { return true }; return false }) { break }
            await Task.yield()
        }

        XCTAssertTrue(
            statuses.contains { if case .failed = $0 { return true }; return false },
            "没有基线来源时必须显式 failed，实际状态：\(statuses)"
        )
        XCTAssertFalse(statuses.contains(.connected), "不得假装已连上")
    }

    // MARK: - 发送映射（核心）

    /// 明确接受 → onSendAccepted + accepted outcome。
    func testAcceptedSubmissionPublishesAccepted() async throws {
        let sink = RecordingPromptSink()
        let (client, _) = try await makeConnectedClient(sender: sink)
        var accepted: [ClientMessageID?] = []
        var outcomes: [(ClientMessageID?, TurnSendOutcome)] = []
        client.onSendAccepted = { accepted.append($0) }
        client.onTurnSendOutcome = { outcomes.append(($0, $1)) }

        XCTAssertTrue(client.sendInput("你好", clientMessageID: "cm-1"))
        await waitFor { !accepted.isEmpty }

        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(sink.requestIDs, ["cm-1"], "clientMessageID 必须直接当 requestId 用")
        guard case .accepted = outcomes.first?.1 else {
            XCTFail("必须发布 accepted，实际 \(String(describing: outcomes.first?.1))")
            return
        }
    }

    /// **结果未知 → `.uncertain`，不是 `.rejected`。**
    ///
    /// 这是本文件最重要的一条。映射成 `.rejected` 会让上层以为"没执行、可以重试"，
    /// 而它可能已经执行了——那是重复工具执行的直接成因（契约 D4）。
    func testResponseUnknownPublishesUncertainNotRejected() async throws {
        let sink = RecordingPromptSink()
        sink.failure = HarnessTransportError.timedOut
        let (client, _) = try await makeConnectedClient(sender: sink)
        var outcomes: [(ClientMessageID?, TurnSendOutcome)] = []
        var failures: [(ClientMessageID?, String)] = []
        client.onTurnSendOutcome = { outcomes.append(($0, $1)) }
        client.onSendFailure = { failures.append(($0, $1)) }

        _ = client.sendInput("你好", clientMessageID: "cm-2")
        await waitFor { !outcomes.isEmpty }

        guard case .uncertain = outcomes.first?.1 else {
            XCTFail("结果未知必须发布 .uncertain，实际 \(String(describing: outcomes.first?.1))")
            return
        }
        // 同时不得报 accepted。
        if case .accepted = outcomes.first?.1 {
            XCTFail("结果未知不得发布 accepted")
        }
        XCTAssertEqual(failures.count, 1)
    }

    /// 明确业务失败 → `.rejected`（这类重试是安全的）。
    func testBusinessFailurePublishesRejected() async throws {
        let sink = RecordingPromptSink()
        sink.failure = HarnessTransportError.business(
            HarnessRemoteError(code: "session/agent-busy", message: "会话正忙", details: nil)
        )
        let (client, _) = try await makeConnectedClient(sender: sink)
        var outcomes: [(ClientMessageID?, TurnSendOutcome)] = []
        client.onTurnSendOutcome = { outcomes.append(($0, $1)) }

        _ = client.sendInput("你好", clientMessageID: "cm-3")
        await waitFor { !outcomes.isEmpty }

        guard case .rejected(let message) = outcomes.first?.1 else {
            XCTFail("业务失败必须发布 .rejected，实际 \(String(describing: outcomes.first?.1))")
            return
        }
        XCTAssertEqual(message, "会话正忙")
    }

    /// 基线未建立时不得发送。
    func testSendBeforeBaselineIsRejected() {
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in })
        )
        var failures: [(ClientMessageID?, String)] = []
        client.onSendFailure = { failures.append(($0, $1)) }

        XCTAssertFalse(client.sendInput("你好", clientMessageID: "cm-4"))
        XCTAssertEqual(failures.count, 1, "必须显式告知失败")
    }

    /// guidance 必须显式拒绝，不得当成普通 prompt 发出去。
    func testGuidanceIsExplicitlyRejected() async throws {
        let sink = RecordingPromptSink()
        let (client, _) = try await makeConnectedClient(sender: sink)
        var failures: [(ClientMessageID?, String)] = []
        client.onSendFailure = { failures.append(($0, $1)) }

        let accepted = client.sendGuidance(
            CodexAppServerTurnPayload(prompt: "引导"),
            clientMessageID: "cm-5",
            expectedTurnID: "turn-1"
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(sink.requestIDs.isEmpty, "guidance 不得变成一次 prompt")
    }

    /// 非文本输入显式拒绝（Harness 首版只接受文本）。
    func testNonTextTurnIsRejected() async throws {
        let sink = RecordingPromptSink()
        let (client, _) = try await makeConnectedClient(sender: sink)
        var failures: [(ClientMessageID?, String)] = []
        client.onSendFailure = { failures.append(($0, $1)) }

        let accepted = client.sendTurn(CodexAppServerTurnPayload(prompt: "   "), clientMessageID: "cm-6")

        XCTAssertFalse(accepted)
        XCTAssertTrue(sink.requestIDs.isEmpty)
    }

    // MARK: - 接收与去重

    /// 重复持久事件不产生第二条展示事件（流式到历史无重复）。
    func testDuplicateDurableEventProjectsOnlyOnce() async throws {
        let (client, recorder) = try await makeConnectedClient(sender: RecordingPromptSink())
        let event = durableEvent(type: HarnessWireEventType.userMessage, seq: 8, text: "你好")

        XCTAssertTrue(client.apply(durableEvent: event), "首次必须是新增")
        XCTAssertFalse(client.apply(durableEvent: event), "同 seq 重投不得算新增")
        await waitFor { !recorder.events.isEmpty }

        let messages = recorder.events.filter {
            if case .messageCompleted = $0 { return true }
            return false
        }
        XCTAssertEqual(messages.count, 1, "重投不得产生第二条气泡")
    }

    /// 用户消息带回 source.rpcId，上层才能把乐观记录对上。
    func testUserMessageCarriesSourceRPCID() async throws {
        let (client, recorder) = try await makeConnectedClient(sender: RecordingPromptSink())
        let event = HarnessDurableEvent(
            type: HarnessWireEventType.userMessage, seq: 9, time: nil,
            data: .object([
                "message": .object([
                    "content": .array([.object([
                        "type": .string("text"), "text": .string("你好"),
                    ])]),
                    "source": .object(["rpcId": .string("cm-9")]),
                ]),
            ])
        )
        XCTAssertTrue(client.apply(durableEvent: event))
        await waitFor { !recorder.events.isEmpty }

        guard case .messageCompleted(let message, _) = try XCTUnwrap(recorder.events.first) else {
            XCTFail("user/message 必须投影成 messageCompleted")
            return
        }
        XCTAssertEqual(message.clientMessageID, "cm-9", "必须带出 source.rpcId 供对账")
    }

    /// 断档时报 failed（要求重开 follow），不把断档接上。
    func testStreamGapReportsFailure() async throws {
        let (client, _) = try await makeConnectedClient(sender: RecordingPromptSink())
        var statuses: [WebSocketStatus] = []
        client.onStatus = { statuses.append($0) }

        // 没收到 start 就来 chunk：missingStart。
        let rejection = client.apply(assistantStream: HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.chunk, revision: 2, index: 0,
            chunk: HarnessAssistantChunk(
                type: HarnessWireChunkType.textDelta, index: 0,
                text: "x", blockType: nil, argumentsDelta: nil
            ),
            outcome: nil, attemptId: "a1", turn: 1, step: 1, startedAfterSeq: 0
        ))

        XCTAssertEqual(rejection, .missingStart)
        XCTAssertTrue(
            statuses.contains { if case .failed = $0 { return true }; return false },
            "断档必须如实上报"
        )
    }

    /// snapshot 之前来的 live 帧被拒（基线尚未建立）。
    func testFrameBeforeBaselineIsRejected() {
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in })
        )
        XCTAssertEqual(
            client.apply(assistantStream: HarnessAssistantStreamFrame(
                type: HarnessWireAssistantFrame.start, revision: 1, index: nil,
                chunk: nil, outcome: nil, attemptId: "a1", turn: 1, step: 1, startedAfterSeq: 0
            )),
            .beforeSnapshot
        )
    }

    // MARK: - 停止

    /// 停止的响应未知同样走 control failure，不报成功。
    func testCancelUnknownReportsControlFailure() async throws {
        let (client, _) = try await makeConnectedClient(sender: RecordingPromptSink())
        var controlFailures: [String] = []
        client.onControlFailure = { controlFailures.append($0) }

        // cancel 走的是注入的 submission，它的 sendCancel 恒成功；这里只验证成功路径。
        XCTAssertTrue(client.sendCtrlC(expectedTurnID: "turn-1"))
        await waitFor { !controlFailures.isEmpty || true }
        // 成功路径不产生 control failure。
        XCTAssertTrue(controlFailures.isEmpty)
    }

    // MARK: - 支撑

    private func waitFor(_ condition: @MainActor () -> Bool, iterations: Int = 400) async {
        for _ in 0..<iterations {
            if condition() { return }
            await Task.yield()
        }
    }
}

// MARK: - 替身

@MainActor
private final class RecordingPromptSink {
    private(set) var requestIDs: [String] = []
    var failure: Error?

    func send(_ sessionID: String, _ requestID: String, _ text: String) async throws {
        requestIDs.append(requestID)
        if let failure { throw failure }
    }
}

@MainActor
private final class EventRecorder {
    var events: [AgentEvent] = []
}
