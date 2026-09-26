import XCTest
@testable import MimiRemote

@MainActor
final class SessionObservationLeaseTests: XCTestCase {
    func testReplacedNativeClientCannotPublishEventsStatusesOrRoutes() {
        let (bundle, socket, first, second) = routingFixture()
        var events: [AgentEvent] = []
        var statuses: [WebSocketStatus] = []
        socket.onEvent = { events.append($0) }
        socket.onStatus = { statuses.append($0) }
        socket.connect(sessionID: "first")
        socket.connect(sessionID: "second")
        events.removeAll()
        statuses.removeAll()

        first.emitEvent(.session(session(id: "second", runtime: "claude")))
        first.emitStatus(.failed("old observation"))

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(bundle.routes.runtimeProvider(for: "second"), "deepseek")
        XCTAssertEqual(first.disconnectCallCount, 1)

        second.emitEvent(.session(session(id: "second", runtime: "deepseek")))
        second.emitStatus(.connected)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(statuses, [.connected])
        socket.disconnect()
    }

    func testDisconnectInvalidatesQueuedCallbacks() {
        let (bundle, socket, first, _) = routingFixture()
        var events: [AgentEvent] = []
        var statuses: [WebSocketStatus] = []
        socket.onEvent = { events.append($0) }
        socket.onStatus = { statuses.append($0) }
        socket.connect(sessionID: "first")
        socket.disconnect()
        first.emitEvent(.session(session(id: "first", runtime: "claude")))
        first.emitStatus(.connected)

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(statuses, [.connecting, .disconnected])
        XCTAssertEqual(bundle.routes.runtimeProvider(for: "first"), "deepseek")
    }

    func testFailedRuntimeSelectionInvalidatesPreviousObservation() {
        let (bundle, socket, first, _) = routingFixture()
        bundle.routes.remember("unsupported", for: "unsupported-session")
        var events: [AgentEvent] = []
        var statuses: [WebSocketStatus] = []
        socket.onEvent = { events.append($0) }
        socket.onStatus = { statuses.append($0) }
        socket.connect(sessionID: "first")
        socket.connect(sessionID: "unsupported-session")
        let failureCount = statuses.count
        first.emitEvent(.session(session(id: "first", runtime: "claude")))
        first.emitStatus(.connected)

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(statuses.count, failureCount)
        guard case .failed? = statuses.last else { return XCTFail("未知 Runtime 必须显式失败") }
        XCTAssertEqual(bundle.routes.runtimeProvider(for: "first"), "deepseek")
    }

    func testReplacementDuringSnapshotStopsOldProjectionAndClosesOnlyOldFollow() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let client = makeClient(runtime: runtime)
        var contents: [String] = []
        var statuses: [WebSocketStatus] = []
        var replaced = false
        client.onStatus = { statuses.append($0) }
        client.onEvent = { event in
            guard case .messageCompleted(let message, _) = event else { return }
            contents.append(message.content)
            if !replaced {
                replaced = true
                client.connect(sessionID: "second")
                statuses.removeAll()
            }
        }

        client.connect(sessionID: "first")
        let firstID = try await waitForFollow(sessionID: "first", stream: stream)
        stream.push(carrier(firstID, snapshot(records: [userRecord(seq: 1), userRecord(seq: 2)])))
        let secondID = try await waitForFollow(sessionID: "second", stream: stream)
        try await waitUntil { !(await runtime.openStreamIDs()).contains(firstID) }

        XCTAssertEqual(contents, ["message-1"], "切页后不能继续发布旧 snapshot 的下一条记录")
        XCTAssertFalse(statuses.contains(.connected), "新 follow 尚无 snapshot，旧观察不能报告 connected")
        let remaining = await runtime.openStreamIDs()
        XCTAssertEqual(remaining, [secondID], "旧任务只能释放自己创建的 follow")
        XCTAssertEqual(stream.closeCount, 0, "页面观察不能退役宿主共享连接")

        stream.push(carrier(secondID, snapshot(records: [userRecord(seq: 3)])))
        try await waitUntil { statuses.contains(.connected) }
        XCTAssertEqual(contents, ["message-1", "message-3"])
        client.disconnect()
        await runtime.shutdown()
    }

    func testReplacementWhileDrainingLiveFramesRejectsOldSessionContent() async throws {
        let stream = FakeHarnessStreamTransport()
        let gate = FirstFollowOpenGate()
        let runtime = makeRuntime(stream: GatedFollowTransport(base: stream, gate: gate))
        let client = makeClient(runtime: runtime)
        var contents: [String] = []
        var replaced = false
        client.onEvent = { event in
            guard case .messageCompleted(let message, _) = event else { return }
            contents.append(message.content)
            if !replaced {
                replaced = true
                client.connect(sessionID: "second")
            }
        }

        client.connect(sessionID: "first")
        let firstID = try await waitForFollow(sessionID: "first", stream: stream)
        // 先把 snapshot 和两条 live 帧放进 runtime 邮箱，再放行 open，确定性覆盖内层排空循环。
        stream.push(carrier(firstID, snapshot(records: [])))
        stream.push(carrier(firstID, liveUserRecord(seq: 1)))
        stream.push(carrier(firstID, liveUserRecord(seq: 2)))
        do {
            try await waitUntil { await runtime.bufferedFrameCount(streamID: firstID) == 3 }
        } catch {
            await gate.release()
            client.disconnect()
            await runtime.shutdown()
            throw error
        }
        await gate.release()
        let secondID = try await waitForFollow(sessionID: "second", stream: stream)
        try await waitUntil { !(await runtime.openStreamIDs()).contains(firstID) }

        XCTAssertEqual(contents, ["message-1"], "旧流的下一条消息不能用新 session ID 发布")
        let remaining = await runtime.openStreamIDs()
        XCTAssertEqual(remaining, [secondID])
        XCTAssertEqual(stream.closeCount, 0)
        client.disconnect()
        await runtime.shutdown()
    }

    private func routingFixture() -> (
        AppServerRuntimeBundle, MultiRuntimeSessionWebSocketClient, MockWebSocketClient, MockWebSocketClient
    ) {
        let first = MockWebSocketClient()
        let second = MockWebSocketClient()
        let harness = FakeHarnessSessionClient()
        harness.eventClientFactory = { $0 == "first" ? first : second }
        let bundle = AppServerRuntimeBundle(
            endpoint: "http://127.0.0.1:8787", token: "fixture", harnessFactory: { _, _ in harness }
        )
        bundle.routes.remember("deepseek", for: "first")
        bundle.routes.remember("deepseek", for: "second")
        return (bundle, MultiRuntimeSessionWebSocketClient(bundle: bundle), first, second)
    }

    private func session(id: String, runtime: String) -> AgentSession {
        AgentSession(
            id: id, projectID: "fixture", project: "Fixture", dir: "/fixture",
            title: id, status: "history", source: runtime, resumeID: nil,
            createdAt: nil, updatedAt: nil
        )
    }

    private func makeRuntime(stream: any HarnessStreamTransport) -> HarnessSessionRuntime {
        HarnessSessionRuntime(
            configuration: .init(endpoint: "http://127.0.0.1:8787", token: "fixture"),
            transports: .init(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
    }

    private func makeClient(runtime: HarnessSessionRuntime) -> HarnessSessionWebSocketClient {
        HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787", token: "fixture", sessionID: "first",
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in }),
            runtime: runtime,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in await Task.yield() })
        )
    }

    private func waitForFollow(sessionID: String, stream: FakeHarnessStreamTransport) async throws -> String {
        var result: String?
        try await waitUntil {
            result = stream.sentFrames.compactMap { frame -> String? in
                guard case .open(let id, let endpoint, let args) = frame,
                      endpoint == HarnessWireEndpoint.sessionFollow,
                      args?["request"]?["address"]?["sessionId"]?.stringValue == sessionID else { return nil }
                return id
            }.last
            return result != nil
        }
        return try XCTUnwrap(result)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HarnessTransportError.timedOut
    }

    private func carrier(_ streamID: String, _ value: HarnessJSONValue) -> HarnessCarrierFrame {
        HarnessCarrierFrame(type: HarnessWireCarrier.item, streamId: streamID, value: value, error: nil)
    }

    private func snapshot(records: [HarnessJSONValue]) -> HarnessJSONValue {
        .object([
            "type": .string(HarnessWireFrame.snapshot),
            "header": .object([
                "version": .number(3), "id": .string("header-fixture"),
                "cwd": .string("/fixture"), "isSeeded": .bool(false),
            ]),
            "cursor": .number(Double(records.last?["seq"]?.intValue ?? 0)),
            "records": .array(records), "hasMore": .bool(false),
            "assistantStream": .object(["revision": .number(0)]),
        ])
    }

    private func userRecord(seq: Int) -> HarnessJSONValue {
        .object([
            "type": .string(HarnessWireEventType.userMessage), "seq": .number(Double(seq)),
            "data": .object([
                "content": .array([.object(["type": .string("text"), "text": .string("message-\(seq)")])]),
                "source": .object(["kind": .string("user"), "rpcId": .string("request-\(seq)")]),
            ]),
        ])
    }

    private func liveUserRecord(seq: Int) -> HarnessJSONValue {
        .object(["type": .string(HarnessWireFrame.durableEvent), "event": userRecord(seq: seq)])
    }
}

private actor FirstFollowOpenGate {
    private var intercepted = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitOnce() async {
        guard !intercepted else { return }
        intercepted = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class GatedFollowTransport: HarnessStreamTransport {
    let base: FakeHarnessStreamTransport
    let gate: FirstFollowOpenGate

    init(base: FakeHarnessStreamTransport, gate: FirstFollowOpenGate) {
        self.base = base
        self.gate = gate
    }

    func connect() async throws { try await base.connect() }
    func receive() async throws -> HarnessCarrierFrame? { try await base.receive() }
    func ping() async throws { try await base.ping() }
    func close() async { await base.close() }

    func send(_ frame: HarnessClientFrame) async throws {
        try await base.send(frame)
        if case .open(_, let endpoint, _) = frame, endpoint == HarnessWireEndpoint.sessionFollow {
            await gate.waitOnce()
        }
    }
}
