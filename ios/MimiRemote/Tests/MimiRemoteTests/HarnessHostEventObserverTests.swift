import Foundation
import XCTest
@testable import MimiRemote

/// #499 宿主级 `$events`（H09）：接受、归属与页面无关性。
///
/// 这一组回答审查提出的两件事，都用**真实 runtime + 真实 store**，不是直接调客户端类：
///
/// 1. **不打开会话也要能收到并回答审批。** 全程没有任何会话页面参与：
///    没有 follow 订阅、没有页面客户端，瀑布照样登记进宿主级 store。
/// 2. **切会话不得反复拆共享连接。** `$events` 归宿主，页面释放只退订自己的 follow。
///
/// 这是审查明确要求"至少一组用真实传输、而不是只让 fake 的 receive() 返回 nil"的落点。
@MainActor
final class HarnessHostEventObserverTests: XCTestCase {

    private let sessionA = "session-a-current"
    private let sessionB = "session-b-unopened"

    // MARK: - 1. 宿主级接收

    /// 未打开会话的审批必须登记并产出 UI 事件。
    ///
    /// 归属只能来自瀑布自己的 `agentId`（契约 §2.8：Harness 的 agent 注册表 id 等于
    /// 会话 id）。若拿"当前打开的是哪个会话"兜底，B 的审批会落到 A 上，用户对着错的
    /// 会话做决定。
    func testUnopenedSessionApprovalIsDeliveredAndAttributedByAgentID() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let store = HarnessInteractionStore()
        let observer = HarnessHostEventObserver(
            runtime: runtime,
            interactionStore: store,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )
        var events: [AgentEvent] = []
        observer.onEvent = { events.append($0) }

        observer.start()
        let eventsID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.ready),
        ])))
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.waterfall),
            "eventId": .string("approval-b"),
            "event": .string(HarnessWireWaterfallEvent.approvalRequest),
            "agentId": .string(sessionB),
            "request": .object([
                "toolName": .string("shell"),
                "callId": .string("call-b"),
            ]),
        ])))

        await waitFor { store.interaction(eventID: "approval-b") != nil }
        XCTAssertEqual(
            store.interaction(eventID: "approval-b")?.sessionID,
            sessionB,
            "归属必须用瀑布自己的 agentId，不是任何页面的当前会话"
        )
        await waitFor {
            events.contains {
                guard case .approvalRequest(let request, let metadata) = $0 else { return false }
                return request.id == "approval-b" && metadata.sessionID == self.sessionB
            }
        }
        XCTAssertTrue(events.contains {
            guard case .approvalRequest(_, let metadata) = $0 else { return false }
            return metadata.sessionID == sessionB
        }, "未打开会话的审批必须产出 UI 事件，否则用户永远看不到它")

        await observer.stop()
    }

    /// 宿主级订阅只开一条，重复 start 是幂等的。
    ///
    /// 中继规定一条移动连接只绑定一个 `$events` 生命周期（再开会被拒），
    /// 而且退订它会关闭整条连接。重复 start 若真去开第二条，就会把一条正在工作的
    /// 订阅换成一个必然失败的请求。
    func testStartIsIdempotentAndOpensExactlyOneEventsStream() async throws {
        let stream = FakeHarnessStreamTransport()
        let observer = HarnessHostEventObserver(
            runtime: makeRuntime(stream: stream),
            interactionStore: HarnessInteractionStore(),
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )

        observer.start()
        _ = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        observer.start()
        observer.start()
        try? await Task.sleep(for: .milliseconds(150))

        let opens = stream.sentFrames.filter {
            if case .open(_, let endpoint, _) = $0 { return endpoint == HarnessWireEndpoint.events }
            return false
        }
        XCTAssertEqual(opens.count, 1, "宿主级 $events 只允许一条")

        await observer.stop()
    }

    /// 宿主观察者**不**开 follow：它只订宿主通道。
    func testHostObserverDoesNotOpenSessionFollow() async throws {
        let stream = FakeHarnessStreamTransport()
        let observer = HarnessHostEventObserver(
            runtime: makeRuntime(stream: stream),
            interactionStore: HarnessInteractionStore(),
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )

        observer.start()
        _ = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        try? await Task.sleep(for: .milliseconds(150))

        let follows = stream.sentFrames.filter {
            if case .open(_, let endpoint, _) = $0 { return endpoint == HarnessWireEndpoint.sessionFollow }
            return false
        }
        XCTAssertTrue(follows.isEmpty, "会话观察是页面的职责，宿主不代劳")

        await observer.stop()
    }

    // MARK: - 2. 页面释放不影响宿主订阅

    /// 页面断开**只退订它自己的 follow**，不动宿主 `$events`。
    ///
    /// 这是"切会话不反复断共享连接"的核心：中继在 `$events` 退役时会关闭整条移动连接，
    /// 页面退订它等于每次换会话都重连一次，还会波及其它会话的订阅。
    func testPageDisconnectKeepsHostEventsStream() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let store = HarnessInteractionStore()
        let observer = HarnessHostEventObserver(
            runtime: runtime,
            interactionStore: store,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )
        observer.start()
        let eventsID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.ready),
        ])))

        // 一个会话页面接入同一 runtime，然后像切会话那样断开它。
        let page = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionA,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in }),
            runtime: runtime,
            interactionStore: store,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )
        page.connect(sessionID: sessionA)
        let followID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.sessionFollow, stream: stream)
        stream.push(carrierValue(
            streamID: followID,
            value: snapshotValue(sessionID: sessionA, cursor: 5)
        ))
        await waitFor { page.journal?.hasOpenedSnapshot == true }

        page.disconnect()
        await waitFor {
            stream.sentFrames.contains { frame in
                if case .cancel(let streamID) = frame { return streamID == followID }
                return false
            }
        }

        // 页面退订了 follow，但没有退订 $events，也没有关连接。
        let cancels = stream.sentFrames.compactMap { frame -> String? in
            if case .cancel(let streamID) = frame { return streamID }
            return nil
        }
        XCTAssertTrue(cancels.contains(followID), "页面断开必须退订自己的 follow")
        XCTAssertFalse(cancels.contains(eventsID), "页面断开不得退订宿主级 $events")
        XCTAssertFalse(stream.isClosed, "退订 follow 不得关闭共享连接")

        // 断开页面之后，宿主订阅仍然工作：未打开会话的审批照样到达。
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.waterfall),
            "eventId": .string("approval-after-page-close"),
            "event": .string(HarnessWireWaterfallEvent.approvalRequest),
            "agentId": .string(sessionB),
            "request": .object(["toolName": .string("shell")]),
        ])))
        await waitFor { store.interaction(eventID: "approval-after-page-close") != nil }
        XCTAssertNotNil(
            store.interaction(eventID: "approval-after-page-close"),
            "页面离开不是应答，也不是放弃授权请求（契约 D5）"
        )

        await observer.stop()
    }

    // MARK: - 3. 应答与撤卡

    /// 撤卡只认关联回执：写进 socket 不等于上游已接受。
    ///
    /// 中继在"上游接受/明确拒绝"时才回带 eventId 的帧。在此之前卡片必须停在
    /// 提交中——否则上游随后拒绝时，用户已经看到一个消失的卡片。
    func testRespondAckIsTheOnlyPathThatRemovesTheCard() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let store = HarnessInteractionStore()
        let observer = HarnessHostEventObserver(
            runtime: runtime,
            interactionStore: store,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )
        observer.start()
        let eventsID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.ready),
        ])))
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.waterfall),
            "eventId": .string("approval-ack"),
            "event": .string(HarnessWireWaterfallEvent.approvalRequest),
            "agentId": .string(sessionB),
            "request": .object(["toolName": .string("shell")]),
        ])))
        await waitFor { store.interaction(eventID: "approval-ack") != nil }

        // 认领并写出应答（等价于页面提交的那一步）。
        _ = store.claim(eventID: "approval-ack", generation: await runtime.connectionGeneration)
        XCTAssertNotNil(store.interaction(eventID: "approval-ack"), "提交中不得撤卡")

        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.responded),
            "eventId": .string("approval-ack"),
            "outcome": .string(HarnessRespondOutcome.accepted),
            "responded": .bool(true),
        ])))
        await waitFor { store.interaction(eventID: "approval-ack") == nil }
        XCTAssertNil(store.interaction(eventID: "approval-ack"), "收到明确接受回执后才撤卡")

        await observer.stop()
    }

    /// 上游明确拒绝：卡片回到待应答，并如实回传原因。
    func testRejectedResponseReopensCardAndReportsReason() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let store = HarnessInteractionStore()
        let observer = HarnessHostEventObserver(
            runtime: runtime,
            interactionStore: store,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )
        var rejections: [(String, String, String)] = []
        observer.onInteractionRejected = { sessionID, eventID, message in
            rejections.append((sessionID, eventID, message))
        }
        observer.start()
        let eventsID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.ready),
        ])))
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.waterfall),
            "eventId": .string("approval-rejected"),
            "event": .string(HarnessWireWaterfallEvent.approvalRequest),
            "agentId": .string(sessionB),
            "request": .object(["toolName": .string("shell")]),
        ])))
        await waitFor { store.interaction(eventID: "approval-rejected") != nil }

        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.responded),
            "eventId": .string("approval-rejected"),
            "outcome": .string(HarnessRespondOutcome.rejected),
            "responded": .bool(true),
            "error": .object([
                "code": .string("harness/rejected"),
                "message": .string("目标会话不在授权目录内"),
            ]),
        ])))

        await waitFor { !rejections.isEmpty }
        XCTAssertEqual(rejections.first?.0, sessionB, "拒绝也要按事件自己的会话归属")
        XCTAssertEqual(rejections.first?.2, "目标会话不在授权目录内", "拒绝原因必须如实回传")
        // 明确拒绝 = 没生效，允许用户重试。
        XCTAssertEqual(store.interaction(eventID: "approval-rejected")?.state, .pending)

        await observer.stop()
    }

    /// **结果未知绝不能当成"明确拒绝"。**
    ///
    /// 这是回执四态里最容易写错的一处：上游可能已经接受了这次应答、只是 HTTP 响应丢了。
    /// 把它判成可重试的拒绝，会让用户重新回答一次已经生效的审批——重复执行副作用。
    /// 因此它必须保持锁定，等对账或上游重投。
    func testUnknownOutcomeKeepsCardLockedInsteadOfReopening() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let store = HarnessInteractionStore()
        let observer = HarnessHostEventObserver(
            runtime: runtime,
            interactionStore: store,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )
        observer.start()
        let eventsID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.ready),
        ])))
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.waterfall),
            "eventId": .string("approval-unknown"),
            "event": .string(HarnessWireWaterfallEvent.approvalRequest),
            "agentId": .string(sessionB),
            "request": .object(["toolName": .string("shell")]),
        ])))
        await waitFor { store.interaction(eventID: "approval-unknown") != nil }
        // 先认领，模拟"已经提交出去"。
        _ = store.claim(eventID: "approval-unknown", generation: await runtime.connectionGeneration)

        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.responded),
            "eventId": .string("approval-unknown"),
            "outcome": .string(HarnessRespondOutcome.unknown),
            "responded": .bool(true),
            "error": .object([
                "code": .string("gateway/service-unavailable"),
                "message": .string("上游结果未知"),
            ]),
        ])))
        await waitFor {
            guard case .responseUnknown? = store.interaction(eventID: "approval-unknown")?.state else {
                return false
            }
            return true
        }

        guard case .responseUnknown = store.interaction(eventID: "approval-unknown")?.state else {
            XCTFail("结果未知必须保持锁定，实际 \(String(describing: store.interaction(eventID: "approval-unknown")?.state))")
            return
        }
        // 卡片还在，但不可再次应答——重发可能让一次审批被应用两次。
        XCTAssertNotNil(store.interaction(eventID: "approval-unknown"))

        await observer.stop()
    }

    /// 他端终结（`settled`）撤卡，但**不**声称本端回答获胜。
    func testSettledOutcomeRemovesCardWithoutClaimingLocalWin() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let store = HarnessInteractionStore()
        let observer = HarnessHostEventObserver(
            runtime: runtime,
            interactionStore: store,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )
        var events: [AgentEvent] = []
        observer.onEvent = { events.append($0) }
        observer.start()
        let eventsID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.ready),
        ])))
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.waterfall),
            "eventId": .string("approval-settled"),
            "event": .string(HarnessWireWaterfallEvent.approvalRequest),
            "agentId": .string(sessionB),
            "request": .object(["toolName": .string("shell")]),
        ])))
        await waitFor { store.interaction(eventID: "approval-settled") != nil }

        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.responded),
            "eventId": .string("approval-settled"),
            "outcome": .string(HarnessRespondOutcome.settled),
            "responded": .bool(true),
        ])))
        await waitFor { store.interaction(eventID: "approval-settled") == nil }

        XCTAssertNil(store.interaction(eventID: "approval-settled"), "已由他端终结的卡片必须撤下")
        XCTAssertTrue(events.contains {
            if case .approvalResolved = $0 { return true }
            return false
        }, "撤卡要通知 UI；但事件本身不表达'哪一端回答获胜'")

        await observer.stop()
    }

    // MARK: - 支撑

    private func makeRuntime(stream: FakeHarnessStreamTransport) -> HarnessSessionRuntime {
        HarnessSessionRuntime(
            configuration: HarnessSessionRuntime.Configuration(
                endpoint: "http://127.0.0.1:8787",
                token: "fixture",
                pingInterval: .seconds(30)
            ),
            transports: HarnessSessionRuntime.TransportPair(
                rpc: FakeHarnessRPCTransport(),
                stream: stream
            )
        )
    }

    private func waitForOpenStream(
        endpoint: String,
        stream: FakeHarnessStreamTransport,
        after frameIndex: Int = 0
    ) async throws -> String {
        for _ in 0..<400 {
            for frame in stream.sentFrames.dropFirst(frameIndex) {
                if case .open(let streamID, let openedEndpoint, _) = frame,
                   openedEndpoint == endpoint {
                    return streamID
                }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw HarnessTransportError.timedOut
    }

    private func carrierValue(streamID: String, value: HarnessJSONValue) -> HarnessCarrierFrame {
        HarnessCarrierFrame(
            type: HarnessWireCarrier.item,
            streamId: streamID,
            value: value,
            error: nil
        )
    }

    private func snapshotValue(sessionID: String, cursor: Int) -> HarnessJSONValue {
        .object([
            "type": .string(HarnessWireFrame.snapshot),
            "header": .object([
                "id": .string(sessionID),
                "cwd": .string("/h498/workspace"),
            ]),
            "cursor": .number(Double(cursor)),
            "records": .array([]),
            "hasMore": .bool(false),
        ])
    }

    private func waitFor(_ condition: @MainActor () -> Bool, iterations: Int = 400) async {
        for _ in 0..<iterations {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
