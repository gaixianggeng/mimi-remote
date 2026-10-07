import Foundation
import CryptoKit
import Network
import XCTest
@testable import MimiRemote

/// 一个最小的本机 WebSocket 服务，用于**真实传输**的验收。
///
/// ## 为什么必须有它
///
/// 用 fake transport 验证"重连"只能看到 `connectCount` 增加——那正好掩盖了
/// `URLSessionHarnessStreamTransport` 曾经把 `closed` 设成终态、之后 `connect()`
/// 直接返回的问题：fake 自己会建连接，真实实现不会。要抓到这类缺陷，必须让真实
/// `URLSessionWebSocketTask` 对着一个真服务走完 连接 → 断开 → 再连接 → 收到新帧。
///
/// 因此这里用 Network.framework 起一个本机 listener，按 RFC 6455 完成握手，
/// 并允许在连接之间保持存活（服务不随连接关闭而停止）。
final class LocalWebSocketServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "h498.local-ws")
    private let lock = NSLock()

    /// 每次被接受连接时递增。用于断言"确实又连了一次"。
    private var _acceptedConnectionCount = 0
    /// 每条已接受的连接上收到的客户端文本帧。
    private var _receivedTexts: [String] = []
    /// 当前活连接，用于服务端主动断开以模拟链路故障。
    private var connections: [NWConnection] = []

    var acceptedConnectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _acceptedConnectionCount
    }

    var receivedTexts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _receivedTexts
    }

    /// 实际绑定的端口。做成计算属性：`init` 里要在 `newConnectionHandler` 中捕获 self，
    /// 任何尚未初始化的存储属性都会让整个 `self` 在初始化完成前不可用。
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        let queue = self.queue
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            throw NSError(
                domain: "LocalWebSocketServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "listener 未能在 5 秒内就绪"]
            )
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let live = connections
        connections = []
        lock.unlock()
        live.forEach { $0.cancel() }
    }

    /// 服务端主动切断当前所有连接，模拟上游物理断流。
    func dropConnections() {
        lock.lock()
        let live = connections
        connections = []
        lock.unlock()
        live.forEach { $0.cancel() }
    }

    /// 向当前所有连接推送一帧文本。
    func send(_ text: String) {
        let payload = Self.textFrame(text)
        lock.lock()
        let live = connections
        lock.unlock()
        live.forEach { $0.send(content: payload, completion: .idempotent) }
    }

    // MARK: - 握手与帧

    private func accept(_ connection: NWConnection) {
        lock.lock()
        _acceptedConnectionCount += 1
        connections.append(connection)
        lock.unlock()

        connection.start(queue: queue)
        readHandshake(connection)
    }

    /// 读 HTTP 升级请求并回一个 101，随后开始读帧。
    private func readHandshake(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { return }
            let request = String(decoding: data, as: UTF8.self)
            guard request.contains("Upgrade: websocket") || request.lowercased().contains("upgrade: websocket") else {
                return
            }
            let response = [
                "HTTP/1.1 101 Switching Protocols",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Accept: \(Self.acceptKey(from: request))",
                "", "",
            ].joined(separator: "\r\n")
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { [weak self] _ in
                    self?.readFrames(connection)
                }
            )
        }
    }

    /// 解析客户端文本帧，记录 payload。
    ///
    /// 只支持 URLSessionWebSocketTask 实际会发的形状：客户端必须掩码、小载荷长度。
    private func readFrames(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, let text = Self.parseMaskedTextFrame(data) {
                self.lock.lock()
                self._receivedTexts.append(text)
                self.lock.unlock()
            }
            if isComplete || error != nil { return }
            self.readFrames(connection)
        }
    }

    /// 从握手请求里取 Sec-WebSocket-Key，算出符合 RFC 6455 的 Accept。
    ///
    /// **必须真算**：`URLSessionWebSocketTask` 会校验这个头，回错就升级失败
    /// （表现为 "服务器发出错误的响应"）。Accept = base64(SHA1(key + magic))。
    private static func acceptKey(from request: String) -> String {
        for line in request.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-key" else {
                continue
            }
            let key = parts[1].trimmingCharacters(in: .whitespaces)
            return WebSocketAccept.compute(for: key)
        }
        return WebSocketAccept.compute(for: "dGhlIHNhbXBsZSBub25jZQ==")
    }

    /// 构造一个服务端文本帧（不掩码，符合服务端规则）。
    private static func textFrame(_ text: String) -> Data {
        let payload = Data(text.utf8)
        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    /// 解析一个客户端掩码文本帧。
    private static func parseMaskedTextFrame(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        let opcode = bytes[0] & 0x0F
        // 1 = text, 8 = close, 9 = ping, 10 = pong；只关心文本。
        guard opcode == 0x01 else { return nil }
        let masked = (bytes[1] & 0x80) != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = 0
            for index in 2..<10 { length = (length << 8) | Int(bytes[index]) }
            offset = 10
        }
        var maskKey: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }
        guard bytes.count >= offset + length else { return nil }
        var payload = Array(bytes[offset..<(offset + length)])
        if masked {
            for index in payload.indices {
                payload[index] ^= maskKey[index % 4]
            }
        }
        return String(decoding: payload, as: UTF8.self)
    }
}

/// 按 RFC 6455 计算 `Sec-WebSocket-Accept`。
///
/// 真实 `URLSessionWebSocketTask` 会校验这个值：算错时升级失败，报的是
/// "服务器发出错误的响应"，很难看出根因。因此它值一个独立且可断言的类型。
enum WebSocketAccept {
    static let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func compute(for key: String) -> String {
        // SHA-1 在这里只用于握手摘要，不是安全用途；CryptoKit 明确把它归到 Insecure。
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }
}
