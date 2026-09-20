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
