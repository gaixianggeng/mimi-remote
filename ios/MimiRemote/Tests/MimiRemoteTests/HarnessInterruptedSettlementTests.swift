import Foundation
import XCTest
@testable import MimiRemote

/// #809：用户停止 DeepSeek 回复后，两种上游落盘形态都必须认成「已中断」。
///
/// 夹具 `stream/assistant-stream-cancel.json` 同时登记三种取消回放：
/// - 0.1.5：结算为 `assistant/attempt`，没有持久消息；
/// - 0.2.x：结算为 `assistant/message`，持久记录带 `interrupted: true`，正文是已输出的前缀；
/// - 0.2.x 无可见输出：仍落 `assistant/attempt`。
///
/// 判定只看字段，不看版本号。每个回放都按「持久记录先到 / end 帧先到」两种顺序跑，
/// 再走一次历史页重开，确认中断标记不丢、也不重复。
@MainActor
final class HarnessInterruptedSettlementTests: XCTestCase {
    private let sessionID: SessionID = "h09-cancel-session"

    // MARK: - 实时与历史回放

    func testLiveCancelReplaysAreInterruptedInBothArrivalOrders() async throws {
        for replay in try cancelReplays() {
            for durableFirst in [true, false] {
                try await assertLiveReplay(replay, durableFirst: durableFirst)
            }
        }
    }

    /// 0.2.x 的半截正文是持久消息，重开会话时必须仍带中断标记，且与实时那条是同一条。
    func testHistoryReopenKeepsOneInterruptionMarkerForCommittedPrefix() async throws {
        let replay = try XCTUnwrap(
            try cancelReplays().first { $0.label == "cancel.interrupted-message" }
        )
        for durableFirst in [true, false] {
            let run = try await runLive(replay, durableFirst: durableFirst)
            let history = try await loadHistory(replay, api: run.api, stream: run.stream)
            run.conversation.setHistory(history.messages, sessionID: sessionID)

            let messages = run.conversation.messages(for: sessionID)
            let assistant = messages.filter { $0.role == .assistant }
            XCTAssertEqual(
                assistant.map(\.content), [replay.visiblePrefix],
                "历史重开后保留已输出的前缀，与 Codex/Claude 一致（durableFirst=\(durableFirst)）"
            )
            XCTAssertEqual(
                warningRows(in: messages).count, 1,
                "历史重开后中断标记仍在，且与实时那条收敛为一条（durableFirst=\(durableFirst)）"
            )
            let assistantIndex = try XCTUnwrap(messages.firstIndex { $0.role == .assistant })
            let markerIndex = try XCTUnwrap(messages.firstIndex { $0.role == .system && $0.kind == .warning })
            XCTAssertGreaterThan(markerIndex, assistantIndex, "中断标记跟在被中断的回复后面")
            run.client.disconnect()
            await run.api.shutdownForHostSwitch()
        }
    }

    /// 历史投影与实时投影对同一条被中断的持久消息给出同一个标记身份。
    func testLiveAndHistoryProjectionShareInterruptionMarkerIdentity() throws {
        let replay = try XCTUnwrap(
            try cancelReplays().first { $0.label == "cancel.interrupted-message" }
        )
        let settlement = try XCTUnwrap(replay.durable.first)
        let live = HarnessPresentationProjector.project(durableEvent: settlement, sessionID: sessionID)
        let liveMarkers = live.compactMap { event -> AgentMessage? in
            guard case .messageCompleted(let message, _) = event,
                  message.role == .system, message.kind == .warning else { return nil }
            return message
        }
        let history = HarnessHistoryProjection.messages(from: [settlement], sessionID: sessionID)
        let historyMarkers = history.filter { $0.role == "system" && $0.kind == .warning }

        XCTAssertEqual(liveMarkers.count, 1, "被中断的持久消息必须带中断标记")
        XCTAssertEqual(historyMarkers.map(\.id), liveMarkers.map(\.id), "历史与实时的标记身份必须一致")
        XCTAssertEqual(
            history.filter { $0.role == "assistant" }.map(\.content), [replay.visiblePrefix],
            "半截正文保留为助手消息"
        )
    }

    // MARK: - 正常结算对照

    /// 对照：正常结算的 `assistant/message`（无 interrupted）与 `turn/end completed`
    /// 不得出现中断标记，也不得标成中断。
    func testCompletedRunHasNoInterruptionMarker() throws {
        let events = try durableEvents()
        XCTAssertTrue(events.contains { $0.type == HarnessWireEventType.assistantMessage }, "前置条件")
        XCTAssertTrue(events.contains { $0.type == HarnessWireEventType.turnEnd }, "前置条件")

        for event in events {
            for projected in HarnessPresentationProjector.project(durableEvent: event, sessionID: sessionID) {
                switch projected {
                case .messageCompleted(let message, _):
                    XCTAssertNotEqual(message.kind, .warning, "正常结算不得出现中断标记：\(event.type ?? "nil")")
                case .turnCompleted(let metadata):
                    XCTAssertNotEqual(metadata.turnLifecycle, .interrupted, "正常完成的轮次不得标成中断")
                case .warning:
                    XCTFail("正常结算不得出现中断提示")
                default:
                    break
                }
            }
        }
        let history = HarnessHistoryProjection.messages(from: events, sessionID: sessionID)
        XCTAssertTrue(history.allSatisfy { $0.kind != .warning }, "历史投影同样不得出现中断标记")
    }

    // MARK: - 回放驱动

    private struct CancelReplay {
        let label: String
        let frames: [HarnessAssistantStreamFrame]
        let durable: [HarnessDurableEvent]
        let durableValues: [HarnessJSONValue]
        let settlementCommitsMessage: Bool
        let visiblePrefix: String
    }

    private struct LiveRun {
        let api: HarnessSessionAPIClient
        let stream: FakeHarnessStreamTransport
        let client: HarnessSessionWebSocketClient
        let conversation: ConversationStore
        let events: [AgentEvent]
    }

    private func assertLiveReplay(_ replay: CancelReplay, durableFirst: Bool) async throws {
        let run = try await runLive(replay, durableFirst: durableFirst)
        let context = "\(replay.label) durableFirst=\(durableFirst)"

        let lifecycles = run.events.compactMap { event -> ConversationTurnLifecycle?? in
            guard case .turnCompleted(let metadata) = event else { return nil }
            return metadata.turnLifecycle
        }
        XCTAssertEqual(lifecycles, [.interrupted], "turn/end aborted 必须收口为中断（\(context)）")

        let completedAssistant = run.events.contains { event in
            guard case .messageCompleted(let message, _) = event else { return false }
            return message.role == .assistant
        }
        XCTAssertEqual(
            completedAssistant, replay.settlementCommitsMessage,
            "只有持久消息存在时才定稿助手正文（\(context)）"
        )

        let messages = run.conversation.messages(for: sessionID)
        let expectedAssistant = replay.visiblePrefix.isEmpty ? [] : [replay.visiblePrefix]
        XCTAssertEqual(
            messages.filter { $0.role == .assistant }.map(\.content), expectedAssistant,
            "已输出的前缀保留为一条回复（\(context)）"
        )
        XCTAssertEqual(
            warningRows(in: messages).count, replay.visiblePrefix.isEmpty ? 0 : 1,
            "展示过正文的取消必须恰好出现一次中断提示（\(context)）"
        )
        run.client.disconnect()
        await run.api.shutdownForHostSwitch()
    }

    private func runLive(_ replay: CancelReplay, durableFirst: Bool) async throws -> LiveRun {
        let rpc = FakeHarnessRPCTransport()
        let pageRecords = replay.durableValues.map { value -> HarnessJSONValue in
            .object(["type": .string("event"), "event": value])
        }
        rpc.handler = { request in
            guard request.method == HarnessWireMethod.sessionPage else {
                return .failure(.rejected(status: 400, message: "unexpected \(request.method)"))
            }
            return .success(.object(["hasMore": .bool(false), "records": .array(pageRecords)]))
        }
        let stream = FakeHarnessStreamTransport()
        let api = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787", token: "fixture", rpc: rpc, stream: stream
        )
        let client = try XCTUnwrap(
            api.makeEventClient(sessionID: sessionID) as? HarnessSessionWebSocketClient
        )
        var events: [AgentEvent] = []
        client.onEvent = { events.append($0) }
        client.connect(sessionID: sessionID)
        let follow = try await waitForOpenStream(endpoint: HarnessWireEndpoint.sessionFollow, stream: stream)
        stream.push(carrierValue(streamID: follow, value: snapshotValue(cursor: 13)))
        await waitFor { client.journal?.hasOpenedSnapshot == true }
        XCTAssertEqual(client.journal?.hasOpenedSnapshot, true, "前置条件：follow 基线已建立")

        let settlement = try XCTUnwrap(replay.durable.first)
        let turnEnd = try XCTUnwrap(replay.durable.last)
        for frame in replay.frames where frame.type != HarnessWireAssistantFrame.end {
            XCTAssertNil(client.apply(assistantStream: frame), "\(replay.label) 帧必须连续")
        }
        if durableFirst { _ = client.apply(durableEvent: settlement) }
        let end = try XCTUnwrap(replay.frames.last)
        XCTAssertNil(client.apply(assistantStream: end))
        client.settleActiveAttempt()
        if !durableFirst { _ = client.apply(durableEvent: settlement) }
        _ = client.apply(durableEvent: turnEnd)

        let conversation = ConversationStore()
        for event in events {
            apply(event, to: conversation)
        }
        return LiveRun(api: api, stream: stream, client: client, conversation: conversation, events: events)
    }

    private func loadHistory(
        _ replay: CancelReplay,
        api: HarnessSessionAPIClient,
        stream: FakeHarnessStreamTransport
    ) async throws -> HistoryMessagesPage {
        let frameIndex = stream.sentFrames.count
        let task = Task {
            try await api.messagesPage(sessionID: sessionID, before: nil, limit: 50, loadMode: .full)
        }
        let follow = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.sessionFollow, stream: stream, after: frameIndex
        )
        let cursor = replay.durable.compactMap(\.seq).max() ?? 13
        stream.push(carrierValue(streamID: follow, value: snapshotValue(cursor: cursor)))
        return try await task.value
    }

    /// 与 `EventReducer` 对这三类事件的落点一致：增量、定稿、提示行。
    private func apply(_ event: AgentEvent, to store: ConversationStore) {
        switch event {
        case .assistantDelta(let delta, let metadata):
            store.applyAssistantDelta(delta, metadata: metadata, fallbackSessionID: sessionID)
        case .messageCompleted(let message, let metadata):
            store.completeMessage(message, metadata: metadata, fallbackSessionID: sessionID)
        case .warning(let payload, let metadata):
            store.appendSystem(payload.message, sessionID: sessionID, kind: .warning, metadata: metadata)
        default:
            break
        }
    }

    private func warningRows(in messages: [ConversationMessage]) -> [ConversationMessage] {
        messages.filter { $0.role == .system && $0.kind == .warning }
    }

    // MARK: - 夹具

    private func harnessFixtureJSON(_ name: String) throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root
            .appendingPathComponent("contracts/harness-native/fixtures")
            .appendingPathComponent(name)
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "夹具 \(name) 顶层不是对象")
    }

    private func cancelReplays() throws -> [CancelReplay] {
        let fixture = try harnessFixtureJSON("stream/assistant-stream-cancel.json")
        let replays = try XCTUnwrap(fixture["replays"] as? [[String: Any]])
        XCTAssertEqual(
            Set(replays.compactMap { $0["label"] as? String }),
            ["cancel.assistant-attempt", "cancel.interrupted-message", "cancel.no-visible-output"],
            "新旧两种取消形态都必须留在夹具里"
        )
        return try replays.map { replay in
            let label = try XCTUnwrap(replay["label"] as? String)
            let expected = try XCTUnwrap(replay["expected"] as? [String: Any])
            let framesData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(replay["frames"]))
            let durableData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(replay["durable"]))
            return CancelReplay(
                label: label,
                frames: try JSONDecoder().decode([HarnessAssistantStreamFrame].self, from: framesData),
                durable: try JSONDecoder().decode([HarnessDurableEvent].self, from: durableData),
                durableValues: try JSONDecoder().decode([HarnessJSONValue].self, from: durableData),
                settlementCommitsMessage: try XCTUnwrap(expected["settlementCommitsMessage"] as? Bool),
                visiblePrefix: try XCTUnwrap(expected["visiblePrefix"] as? String)
            )
        }
    }

    private func durableEvents() throws -> [HarnessDurableEvent] {
        let fixture = try harnessFixtureJSON("stream/durable-events.json")
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        let events = try XCTUnwrap(
            observations.first { ($0["label"] as? String) == "events" }?["value"] as? [Any]
        )
        let data = try JSONSerialization.data(withJSONObject: events)
        return try JSONDecoder().decode([HarnessDurableEvent].self, from: data)
    }

    // MARK: - 传输支撑

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitForOpenStream(
        endpoint: String,
        stream: FakeHarnessStreamTransport,
        after frameIndex: Int = 0
    ) async throws -> String {
        for _ in 0..<400 {
            for frame in stream.sentFrames.dropFirst(frameIndex) {
                if case .open(let streamID, let openedEndpoint, _) = frame, openedEndpoint == endpoint {
                    return streamID
                }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw HarnessTransportError.timedOut
    }

    private func carrierValue(streamID: String, value: HarnessJSONValue) -> HarnessCarrierFrame {
        HarnessCarrierFrame(type: HarnessWireCarrier.item, streamId: streamID, value: value, error: nil)
    }

    private func snapshotValue(cursor: Int) -> HarnessJSONValue {
        .object([
            "type": .string(HarnessWireFrame.snapshot),
            "header": .object([
                "version": .number(3),
                "id": .string(sessionID),
                "cwd": .string("/fixture"),
                "isSeeded": .bool(false),
            ]),
            "cursor": .number(Double(cursor)),
            "records": .array([]),
            "hasMore": .bool(false),
            "assistantStream": .object(["revision": .number(0)]),
        ])
    }
}
