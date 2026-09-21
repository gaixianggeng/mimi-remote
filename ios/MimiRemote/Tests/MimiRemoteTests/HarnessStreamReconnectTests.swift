import Foundation
import XCTest
@testable import MimiRemote

/// 真实传输的重连验收。
///
/// ## 为什么这一组必须用真实 WebSocket
///
/// `FakeHarnessStreamTransport` 自己会建立"连接"，因此它**看不见**
/// `URLSessionHarnessStreamTransport` 把 `closed` 设成终态之后 `connect()` 直接返回的缺陷：
/// fake 的 `connectCount` 照样增加，runtime 照样把自己标成已连接，只有真实 socket
/// 没有建起来，随后 send/receive 全部 `notConnected`。
///
/// 所以这里对着一个本机 listener 跑完整链路：连接 → 收到帧 → 服务端断流 →
/// 再次连接 → 收到新帧。
@MainActor
final class HarnessStreamReconnectTests: XCTestCase {

    /// 一次真实断开之后，同一个 transport 必须能重新连上并收到新帧。
    ///
    /// 这是"断线自动恢复在真实链路能不能走通"的最小证据。分类改对了只让代码**决定**
    /// 重试；能不能真的连起来取决于 transport 是否可重建。
    func testRealTransportReconnectsAfterCloseAndReceivesNewFrames() async throws {
        let server = try LocalWebSocketServer()
        defer { server.stop() }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)"))

        let transport = URLSessionHarnessStreamTransport(
            baseURL: baseURL,
            token: "fixture",
            pingTimeout: 2
        )
        defer { Task { await transport.close() } }

        // 1. 首连必须是全新的。
        XCTAssertFalse(
            server.acceptedConnectionCount > 0,
            "前置条件：还没连过"
        )

        // 2. 第一代连接：连上、服务端推一帧、客户端读到它。
        try await transport.connect()
        try await waitFor { server.acceptedConnectionCount == 1 }
        server.send(#"{"type":"item","streamId":"s1","value":{"type":"ready"}}"#)

        let first = try await receiveFrame(from: transport)
        XCTAssertEqual(first?.streamId, "s1", "第一代连接必须真的收到帧")

        // 3. 断流：当前实现把它当作一代连接的结束。
        await transport.close()

        // 4. 第二代连接：同一个 transport 必须能重建。
        //    这正是原先坏掉的地方——`closed` 是终态，connect() 直接返回，
        //    runtime 却继续把自己标成已连接。
        try await transport.connect()
        try await waitFor { server.acceptedConnectionCount == 2 }
        XCTAssertEqual(
            server.acceptedConnectionCount, 2,
            "close 之后必须能重新建连，而不是被当成永久退役"
        )

        // 5. 新连接上必须真的能收到新帧。
        server.send(#"{"type":"item","streamId":"s2","value":{"type":"ready"}}"#)
        let second = try await receiveFrame(from: transport)
        XCTAssertEqual(second?.streamId, "s2", "重连后必须能收到新帧，而不是 notConnected")
    }

    /// 重连之后仍然能发帧。
    func testRealTransportCanSendAfterReconnect() async throws {
        let server = try LocalWebSocketServer()
        defer { server.stop() }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)"))

        let transport = URLSessionHarnessStreamTransport(
            baseURL: baseURL,
            token: "fixture",
            pingTimeout: 2
        )
        defer { Task { await transport.close() } }

        try await transport.connect()
        try await waitFor { server.receivedTexts.isEmpty == false || server.acceptedConnectionCount == 1 }
        try await transport.send(.open(streamID: "s1", endpoint: HarnessWireEndpoint.events, args: nil))
        try await waitFor { server.receivedTexts.count == 1 }

        await transport.close()
        try await transport.connect()
        try await waitFor { server.acceptedConnectionCount == 2 }
        try await transport.send(.open(streamID: "s2", endpoint: HarnessWireEndpoint.events, args: nil))

        try await waitFor { server.receivedTexts.count == 2 }
        XCTAssertEqual(server.receivedTexts.count, 2, "重连后必须能继续发帧")
        XCTAssertTrue(
            server.receivedTexts.last?.contains("\"s2\"") == true,
            "第二帧必须发在新连接上"
        )
    }

    /// 连接未建立时 send/receive 必须显式失败，不能假装成功。
    func testSendBeforeConnectFailsExplicitly() async throws {
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:9"))
        let transport = URLSessionHarnessStreamTransport(baseURL: baseURL, token: "fixture")

        do {
            try await transport.send(.open(streamID: "s1", endpoint: HarnessWireEndpoint.events, args: nil))
            XCTFail("未连接时发送必须抛错")
        } catch {
            XCTAssertEqual(error as? HarnessTransportError, .notConnected)
        }
    }

    // MARK: - 支撑

    private func receiveFrame(
        from transport: URLSessionHarnessStreamTransport,
        timeout: TimeInterval = 5
    ) async throws -> HarnessCarrierFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = try await transport.receive() { return frame }
        }
        throw HarnessTransportError.timedOut
    }

    private func waitFor(
        _ condition: @MainActor () -> Bool,
        iterations: Int = 200
    ) async throws {
        for _ in 0..<iterations {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw HarnessTransportError.timedOut
    }
}

// MARK: - 读取基线的建立与取消

/// 冷打开会话时历史读取需要"本次 follow 的 snapshot 游标"。
///
/// Store 的顺序是"先读历史、再连事件"，所以基线必须由**读取方主动建立**。
/// 只被动等待会形成互相等待：历史等连接、连接等历史返回——用户看到的是
/// 一个永远转圈的长会话。
@MainActor
final class HarnessSnapshotBaselineTests: XCTestCase {

    /// 基线入口必须在没有任何页面连接时**自己**建立观察并返回。
    ///
    /// 这一条在旧实现上会一直挂起：它只登记等待者，而建立连接要等历史先返回。
    func testBaselineIsEstablishedWithoutAnyPreexistingConnection() async throws {
        let stream = FakeHarnessStreamTransport()
        let api = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            rpc: FakeHarnessRPCTransport(),
            stream: stream
        )

        // 全程没有任何页面调用 connect(sessionID:)。
        let cursorTask = Task { await api.awaitSnapshotBaseline(
            for: "h00-session-0001",
            timeout: .seconds(5)
        ) }

        // 基线入口应当自己把 follow 建起来，我们按真实顺序推 opening snapshot。
        let followID = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.sessionFollow,
            stream: stream
        )
        stream.push(carrierValue(
            streamID: followID,
            value: snapshotValue(sessionID: "h00-session-0001", cursor: 42)
        ))

        let baseline = await cursorTask.value
        XCTAssertEqual(baseline?.cursor, 42, "基线入口必须主动建立观察并返回本次 snapshot 的游标")
        await api.shutdownForHostSwitch()
    }

    /// 首屏刷新必须等待新的 opening snapshot，不能复用上一次页面留下的 cursor。
    func testAuthoritativeRefreshWaitsForNewSnapshotContext() async throws {
        let stream = FakeHarnessStreamTransport()
        let api = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787", token: "fixture",
            rpc: FakeHarnessRPCTransport(), stream: stream
        )
        let sessionID = "h00-session-refresh"

        let firstTask = Task { await api.awaitSnapshotBaseline(for: sessionID) }
        let firstFollow = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.sessionFollow, stream: stream
        )
        stream.push(carrierValue(
            streamID: firstFollow,
            value: snapshotValue(sessionID: sessionID, cursor: 10)
        ))
        let first = await firstTask.value

        let frameIndex = stream.sentFrames.count
        let refreshTask = Task { await api.awaitSnapshotBaseline(for: sessionID) }
        let refreshFollow = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.sessionFollow, stream: stream, after: frameIndex
        )
        stream.push(carrierValue(
            streamID: refreshFollow,
            value: snapshotValue(sessionID: sessionID, cursor: 20)
        ))
        let refreshed = await refreshTask.value

        XCTAssertEqual(first?.cursor, 10)
        XCTAssertEqual(refreshed?.cursor, 20)
        XCTAssertTrue((refreshed?.contextID ?? 0) > (first?.contextID ?? 0))
        await api.shutdownForHostSwitch()
    }

    /// 两个页面的局部 generation 都会从 1 开始；全局上下文必须按观察开始顺序判断。
    func testLateSnapshotFromOlderPageCannotReplaceNewerBaseline() async throws {
        let stream = FakeHarnessStreamTransport()
        let api = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787", token: "fixture",
            rpc: FakeHarnessRPCTransport(), stream: stream
        )
        let sessionID = "h00-session-pages"
        let older = try XCTUnwrap(
            api.makeEventClient(sessionID: sessionID) as? HarnessSessionWebSocketClient
        )
        older.connect(sessionID: sessionID)
        let olderFollow = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.sessionFollow, stream: stream
        )

        let frameIndex = stream.sentFrames.count
        let newer = try XCTUnwrap(
            api.makeEventClient(sessionID: sessionID) as? HarnessSessionWebSocketClient
        )
        newer.connect(sessionID: sessionID)
        let newerFollow = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.sessionFollow, stream: stream, after: frameIndex
        )
        stream.push(carrierValue(
            streamID: newerFollow,
            value: snapshotValue(sessionID: sessionID, cursor: 90)
        ))
        try await waitFor { newer.journal?.snapshotCursor == 90 }

        stream.push(carrierValue(
            streamID: olderFollow,
            value: snapshotValue(sessionID: sessionID, cursor: 10)
        ))
        try await waitFor { older.journal?.snapshotCursor == 10 }
        let baseline = await api.awaitSnapshotBaseline(
            for: sessionID, requiringNewSnapshot: false, timeout: .seconds(1)
        )

        XCTAssertEqual(baseline?.cursor, 90, "迟到的旧页面不得回滚权威读取边界")
        older.disconnect()
        newer.disconnect()
        await api.shutdownForHostSwitch()
    }

    /// 分页继续使用首屏上下文；刷新产生新上下文后，旧页游标必须显式作废。
    func testPaginationReusesContextAndRejectsCursorAfterRefresh() async throws {
        let rpc = FakeHarnessRPCTransport()
        let pageValue = historyPageValue(seq: 8, hasMore: true)
        rpc.handler = { request in
            guard request.method == HarnessWireMethod.sessionPage else {
                return .failure(.rejected(status: 400, message: "unexpected method"))
            }
            return .success(pageValue)
        }
        let stream = FakeHarnessStreamTransport()
        let api = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787", token: "fixture", rpc: rpc, stream: stream
        )
        let sessionID = "h00-session-pagination"

        let firstTask = Task {
            try await api.messagesPage(sessionID: sessionID, before: nil, limit: 20, loadMode: .full)
        }
        let firstFollow = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.sessionFollow, stream: stream
        )
        stream.push(carrierValue(
            streamID: firstFollow,
            value: snapshotValue(sessionID: sessionID, cursor: 20)
        ))
        let firstPage = try await firstTask.value
        let oldCursor = try XCTUnwrap(firstPage.previousCursor)
        let followCount = stream.sentFrames.filter {
            if case .open(_, let endpoint, _) = $0,
               endpoint == HarnessWireEndpoint.sessionFollow { return true }
            return false
        }.count

        _ = try await api.messagesPage(
            sessionID: sessionID, before: oldCursor, limit: 20, loadMode: .full
        )
        XCTAssertEqual(stream.sentFrames.filter {
            if case .open(_, let endpoint, _) = $0,
               endpoint == HarnessWireEndpoint.sessionFollow { return true }
            return false
        }.count, followCount, "同一快照补页不得另开权威刷新")

        let frameIndex = stream.sentFrames.count
        let refreshTask = Task {
            try await api.messagesPage(sessionID: sessionID, before: nil, limit: 20, loadMode: .full)
        }
        let refreshFollow = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.sessionFollow, stream: stream, after: frameIndex
        )
        stream.push(carrierValue(
            streamID: refreshFollow,
            value: snapshotValue(sessionID: sessionID, cursor: 30)
        ))
        _ = try await refreshTask.value

        do {
            _ = try await api.messagesPage(
                sessionID: sessionID, before: oldCursor, limit: 20, loadMode: .full
            )
            XCTFail("刷新后的旧游标必须被拒绝")
        } catch let error as HarnessTransportError {
            guard case .continuityLost = error else {
                return XCTFail("应为 continuityLost，实际 \(error)")
            }
        }
        await api.shutdownForHostSwitch()
    }

    /// 拿不到基线时必须在超时后**真的返回** nil，不能挂起调用方。
    ///
    /// 旧的实现把续体清理写在任务组外，而任务组退出前要等全部子任务——
    /// 超时子任务返回后仍会等挂起的续体，清理永远到不了，调用方被无限挂起。
    func testBaselineTimeoutActuallyReturns() async throws {
        // 上游从不推 snapshot：基线永远不会就绪。
        let stream = FakeHarnessStreamTransport()
        let api = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            rpc: FakeHarnessRPCTransport(),
            stream: stream
        )

        let started = Date()
        let cursor = await api.awaitSnapshotBaseline(for: "never", timeout: .milliseconds(300))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(cursor, "拿不到基线必须返回 nil，让调用方显式处理")
        XCTAssertLessThan(elapsed, 3, "超时必须真的退出，而不是一直挂起")
        await api.shutdownForHostSwitch()
    }

    /// 取消等待必须立刻退出，不占用调用方。
    func testBaselineWaitIsCancellable() async throws {
        let stream = FakeHarnessStreamTransport()
        let api = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            rpc: FakeHarnessRPCTransport(),
            stream: stream
        )

        let task = Task { await api.awaitSnapshotBaseline(for: "never", timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let started = Date()
        _ = await task.value
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 3,
            "取消后必须立即返回"
        )
        for _ in 0..<100 where !stream.sentFrames.contains(where: { frame in
                if case .cancel = frame { return true }
                return false
            }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            stream.sentFrames.contains { frame in
                if case .cancel = frame { return true }
                return false
            },
            "历史预热取消必须主动退订 follow，不能泄漏全局会话名额"
        )
        await api.shutdownForHostSwitch()
    }

    /// 快速切页会连续取消历史预热；每一条 follow 都必须各自主动退订一次。
    func testRapidHistoryWarmupsCancelEveryFollow() async throws {
        let stream = FakeHarnessStreamTransport()
        let api = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787", token: "fixture",
            rpc: FakeHarnessRPCTransport(), stream: stream
        )
        var opened: [String] = []

        for index in 0..<3 {
            let frameIndex = stream.sentFrames.count
            let task = Task {
                await api.awaitSnapshotBaseline(
                    for: "h00-rapid-\(index)", timeout: .seconds(30)
                )
            }
            let followID = try await waitForOpenStream(
                endpoint: HarnessWireEndpoint.sessionFollow,
                stream: stream,
                after: frameIndex
            )
            opened.append(followID)
            task.cancel()
            _ = await task.value
            try await waitFor {
                stream.sentFrames.contains {
                    if case .cancel(let streamID) = $0 { return streamID == followID }
                    return false
                }
            }
        }

        let cancelled = stream.sentFrames.compactMap { frame -> String? in
            if case .cancel(let streamID) = frame { return streamID }
            return nil
        }
        XCTAssertEqual(Set(cancelled).intersection(opened).count, opened.count)
        XCTAssertEqual(opened.count, 3, "前置条件：确实快速预热了三个不同页面")
        await api.shutdownForHostSwitch()
    }

    // MARK: - 支撑

    private func waitForOpenStream(
        endpoint: String,
        stream: FakeHarnessStreamTransport,
        after frameIndex: Int = 0
    ) async throws -> String {
        for _ in 0..<200 {
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

    private func waitFor(
        _ condition: @MainActor () -> Bool,
        iterations: Int = 200
    ) async throws {
        for _ in 0..<iterations {
            if condition() { return }
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

    private func historyPageValue(seq: Int, hasMore: Bool) -> HarnessJSONValue {
        .object([
            "hasMore": .bool(hasMore),
            "records": .array([.object([
                "type": .string("event"),
                "event": .object([
                    "type": .string(HarnessWireEventType.assistantMessage),
                    "seq": .number(Double(seq)),
                    "data": .object([
                        "message": .object([
                            "id": .string("message-\(seq)"),
                            "role": .string("assistant"),
                            "content": .array([.object([
                                "type": .string("text"), "text": .string("history"),
                            ])]),
                        ]),
                    ]),
                ]),
            ])]),
        ])
    }
}
