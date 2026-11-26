import CryptoKit
import Darwin
import Foundation

/// 经严格校验的本机回环 TCP 端点（保留精确 IP 地址与地址族，覆盖 IPv4 `127.0.0.0/8` 与 IPv6 `::1`）。
struct LoopbackEndpoint: Equatable, Hashable, Sendable {
    let host: String
    let port: UInt16
    let family: Int32

    var hostHeaderValue: String {
        family == AF_INET6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// 规范化 IP 文本：压缩 IPv6（如 `0:0:0:0:0:0:0:1` -> `::1`），并将 IPv4-mapped 回环 `::ffff:127.x.y.z` 归一化为 `127.x.y.z`。
    static func normalizeIPAddress(_ rawHost: String) -> String {
        let trimmed = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !trimmed.isEmpty else { return "" }
        let withoutZone = trimmed.split(separator: "%", maxSplits: 1).first.map(String.init) ?? trimmed

        var addr4 = in_addr()
        if withoutZone.withCString({ Darwin.inet_pton(AF_INET, $0, &addr4) }) == 1 {
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if Darwin.inet_ntop(AF_INET, &addr4, &buf, socklen_t(buf.count)) != nil {
                return String(cString: buf)
            }
        }

        var addr6 = in6_addr()
        if withoutZone.withCString({ Darwin.inet_pton(AF_INET6, $0, &addr6) }) == 1 {
            let bytes = withUnsafeBytes(of: &addr6) { Array($0) }
            if bytes.count == 16,
               bytes[0..<10].allSatisfy({ $0 == 0 }),
               bytes[10] == 0xFF, bytes[11] == 0xFF,
               bytes[12] == 127 {
                return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
            }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if Darwin.inet_ntop(AF_INET6, &addr6, &buf, socklen_t(buf.count)) != nil {
                return String(cString: buf).lowercased()
            }
        }

        return trimmed.lowercased()
    }

    static func isLoopbackIPv4(_ rawHost: String) -> Bool {
        let trimmed = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var addr4 = in_addr()
        guard trimmed.withCString({ Darwin.inet_pton(AF_INET, $0, &addr4) }) == 1 else {
            return false
        }
        return (UInt32(bigEndian: addr4.s_addr) >> 24) == 127
    }

    static func isLoopbackHost(_ rawHost: String) -> Bool {
        let normalized = normalizeIPAddress(rawHost)
        return normalized == "::1" || isLoopbackIPv4(normalized)
    }

    /// 解析严格回环主机地址（仅接受 IPv4 `127.0.0.0/8`、IPv6 `::1` 或 `::ffff:127.0.0.0/8`）。
    static func parse(host rawHost: String, port: UInt16) -> LoopbackEndpoint? {
        guard port > 0 else { return nil }
        let normalized = normalizeIPAddress(rawHost)
        if normalized == "::1" {
            return LoopbackEndpoint(host: "::1", port: port, family: AF_INET6)
        }
        if isLoopbackIPv4(normalized) {
            return LoopbackEndpoint(host: normalized, port: port, family: AF_INET)
        }
        return nil
    }

    /// 将监听绑定地址（含 `127.0.0.0/8`、`::1`、`0.0.0.0`、`::`、`*`、`localhost`）结合协议族（`IPv4`/`IPv6`）映射为精确可拨号回环端点。
    static func fromBindAddress(host rawHost: String, port: UInt16, protocolType: String? = nil) -> LoopbackEndpoint? {
        guard port > 0 else { return nil }
        let cleaned = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        let isIPv6 = protocolType?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "IPV6"
        switch cleaned {
        case "0.0.0.0":
            return LoopbackEndpoint(host: "127.0.0.1", port: port, family: AF_INET)
        case "::", "0:0:0:0:0:0:0:0":
            return LoopbackEndpoint(host: "::1", port: port, family: AF_INET6)
        case "*", "":
            return isIPv6
                ? LoopbackEndpoint(host: "::1", port: port, family: AF_INET6)
                : LoopbackEndpoint(host: "127.0.0.1", port: port, family: AF_INET)
        case "localhost":
            return isIPv6
                ? LoopbackEndpoint(host: "::1", port: port, family: AF_INET6)
                : LoopbackEndpoint(host: "127.0.0.1", port: port, family: AF_INET)
        default:
            return parse(host: cleaned, port: port)
        }
    }
}

/// 经内核对端 PID 核验后建立的一次性只读探针连接句柄；关闭后立即释放 TCP 描述符。
final class PeerVerifiedCodexProbeChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close()
    }

    func close() {
        let toClose = lock.withLock { () -> Int32 in
            let current = fd
            fd = -1
            return current
        }
        if toClose >= 0 {
            _ = Darwin.shutdown(toClose, SHUT_RDWR)
            Darwin.close(toClose)
        }
    }
}

typealias TCPPeerPIDVerifier = @Sendable (
    _ expectedPID: Int32,
    _ localEndpoint: LoopbackEndpoint,
    _ remoteEndpoint: LoopbackEndpoint
) async -> Bool

/// 一个 runtime 的会话列表。`hasMore` 表示还有更早的页没有取。
struct DesktopSessionListing: Equatable, Sendable {
    let sessions: [DesktopSession]
    let hasMore: Bool
}

protocol DesktopSessionSource: Sendable {
    func listSessions(runtime: SessionRuntime, port: Int, pageBudget: Int) async throws -> DesktopSessionListing
}

enum LocalGatewayError: LocalizedError, Equatable {
    case claimRejected(String)
    case connectionFailed(String)
    case runtimeUnavailable(String)
    /// 单个请求被拒绝；`reason` 来自适配器的结构化错误（例如 `turn_active`）。
    case requestRejected(code: Int?, reason: String?, message: String)
    case invalidResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .claimRejected(let message): message
        case .connectionFailed(let message): message
        case .runtimeUnavailable(let message): message
        case .requestRejected(let code, let reason, let message):
            Self.friendlyMessage(code: code, reason: reason) ?? message
        case .invalidResponse: "服务返回了无法识别的内容。"
        case .timedOut: "服务没有及时响应。"
        }
    }

    /// 适配器与网关的拒绝原因换成用户能照着做的说法；认不出的保留原文。
    static func friendlyMessage(code: Int?, reason: String?) -> String? {
        switch reason {
        case "turn_active": return "这一轮还在运行，结束后再打开。"
        case "held_elsewhere": return "这条会话正在终端里使用。请在终端里继续，或先退出终端里的 Claude。"
        case "not_installed": return "这台电脑上没有安装 Claude 桌面版。"
        case "outdated": return "Claude 桌面版版本过旧，请更新后再试。"
        case "open_failed": return "没能打开 Claude 桌面版。"
        case "unsupported_platform": return "只有 Mac 支持在 Claude 桌面版打开。"
        default: break
        }
        // 网关对未放行的方法回 -32080，说明本机服务比 App 旧。
        if code == -32080 { return "本机的 Mimi 服务还不支持这个操作，请重新启动 Mimi Remote Mac 后再试。" }
        return nil
    }
}

/// 电脑端 App 作为本机客户端接入 agentd 的会话通道（#991）。
///
/// 凭据用现有的本机自动配对取得（只接受 loopback），列表用与手机相同的受控全局发现请求，
/// 路径、项目归属与只读裁剪全部由网关完成，电脑端不另做一套授权。连接不带 `session` 参数，
/// 网关按一次性连接处理，不会挤掉手机正在使用的具名连接；取完列表立即关闭。
struct LocalGatewayClient: DesktopSessionSource {
    static let defaultPort = 8787
    static let pageSize = 50

    var session: URLSession = .shared
    var requestTimeout: TimeInterval = 20

    /// 状态里的 endpoint 可能是局域网或 Tailscale 地址；本机一律改连 127.0.0.1 的同一端口。
    static func port(fromEndpoint endpoint: String) -> Int? {
        guard let components = URLComponents(string: endpoint), components.host != nil else { return nil }
        return components.port ?? defaultPort
    }

    /// 与手机端的受控全局发现一致：显式包含 subAgent 来源才能发现独立派发的任务，
    /// 子任务本身由解析时过滤。
    static func threadListParams(cursor: String?) -> [String: Any] {
        var params: [String: Any] = [
            "limit": pageSize,
            "sortKey": "updated_at",
            "sortDirection": "desc",
            "sourceKinds": ["cli", "vscode", "appServer", "subAgent"],
            "archived": false,
            "useStateDbOnly": false,
        ]
        if let cursor { params["cursor"] = cursor }
        return params
    }

    func listSessions(runtime: SessionRuntime, port: Int, pageBudget: Int) async throws -> DesktopSessionListing {
        let channel = try await connect(runtime: runtime, port: port)
        defer { channel.close() }

        var sessions: [DesktopSession] = []
        var seen = Set<String>()
        var cursor: String?
        var pages = 0
        repeat {
            let result = try await channel.call("thread/list", params: Self.threadListParams(cursor: cursor))
            let page = DesktopSessionParser.page(from: result, runtime: runtime)
            for session in page.sessions where seen.insert(session.id).inserted {
                sessions.append(session)
            }
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < max(1, pageBudget)
        return DesktopSessionListing(sessions: sessions, hasMore: cursor != nil)
    }

    /// 默认对端 PID 核验：在写入任何凭据字节前，通过内核 `lsof` 确认 `expectedPID` 自身持有该条已建立 TCP 四元组。
    static func defaultVerifyTCPPeerPID(
        expectedPID: Int32,
        localEndpoint: LoopbackEndpoint,
        remoteEndpoint: LoopbackEndpoint
    ) async -> Bool {
        guard expectedPID > 1 else { return false }
        let res = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-p", String(expectedPID), "-iTCP", "-sTCP:ESTABLISHED", "-F", "pn"],
            timeout: .seconds(5),
            outputLimit: 1_048_576
        )
        guard let res, res.status == 0 else { return false }
        let connsByPID = CodexDesktopLink.parseEstablishedTCPConnections(lsofOutput: res.stdoutText)
        guard let conns = connsByPID[expectedPID] else { return false }
        let expectedLocalPort = String(remoteEndpoint.port)
        let expectedRemotePort = String(localEndpoint.port)
        return conns.contains { conn in
            conn.localHost == remoteEndpoint.host &&
                conn.localPort == expectedLocalPort &&
                conn.remoteHost == localEndpoint.host &&
                conn.remotePort == expectedRemotePort
        }
    }

    /// 为只读共享后端核验建立经对端 PID 核验的一次性 Codex 网关通道：
    /// 1. 仅按已确认的地址与地址族（IPv4 `127.0.0.0/8` 或 IPv6 `::1`）建立裸 TCP 连接（零字节写出）；
    /// 2. 读取本端四元组并调用 `verifyPeerPID` 确认对端确实是 `expectedPID` 本身，不匹配立即断开且绝不发送 Bearer Token；
    /// 3. 核验通过后才发送 WebSocket Upgrade（携带 `Authorization: Bearer`）并完成 `initialize`/`initialized` 握手。
    func openPeerVerifiedCodexProbeChannel(
        endpoint: LoopbackEndpoint,
        expectedPID: Int32,
        bearerToken: String,
        peerVerificationTimeout: TimeInterval? = nil,
        verifyPeerPID: @escaping TCPPeerPIDVerifier = LocalGatewayClient.defaultVerifyTCPPeerPID
    ) async throws -> PeerVerifiedCodexProbeChannel {
        guard !bearerToken.isEmpty else {
            throw LocalGatewayError.claimRejected("缺少本机 Mimi 服务的鉴权 Token。")
        }
        guard LoopbackEndpoint.parse(host: endpoint.host, port: endpoint.port) == endpoint else {
            throw LocalGatewayError.connectionFailed("拒绝向非回环地址发起本机探针连接。")
        }

        let timeout = max(1.0, requestTimeout)
        let (fd, localEndpoint) = try await Task.detached(priority: .userInitiated) {
            try Self.connectLoopbackTCPSocket(endpoint: endpoint, timeout: timeout)
        }.value

        // macOS 上 connect() 可能早于服务端 accept() 完成，因此在同一已打开 fd 上按有界截止时间轮询核验对端 PID；
        // 核验未通过前绝不写出任何字节或 Bearer 凭据。
        let verifyBudget = max(0.05, peerVerificationTimeout ?? min(timeout, 2.0))
        let verifyDeadline = ContinuousClock.now + .milliseconds(Int(verifyBudget * 1000))
        var peerMatches = false
        while true {
            if await verifyPeerPID(expectedPID, localEndpoint, endpoint) {
                peerMatches = true
                break
            }
            if Self.isSocketDisconnectedOrErrored(fd: fd) || ContinuousClock.now >= verifyDeadline {
                break
            }
            try? await Task.sleep(for: .milliseconds(35))
        }
        guard peerMatches else {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            throw LocalGatewayError.connectionFailed("已建立的本机连接对端 PID 与目标 Mimi 服务不匹配，已拒绝发送凭据。")
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.performWebSocketCodexInitialize(
                    fd: fd,
                    endpoint: endpoint,
                    bearerToken: bearerToken,
                    timeout: timeout
                )
            }.value
            return PeerVerifiedCodexProbeChannel(fd: fd)
        } catch {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            throw error
        }
    }

    private static func isSocketDisconnectedOrErrored(fd: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLERR | POLLHUP), revents: 0)
        let rc = Darwin.poll(&pfd, 1, 0)
        guard rc > 0 else { return false }
        if (pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
            return true
        }
        if (pfd.revents & Int16(POLLIN)) != 0 {
            var peekByte: UInt8 = 0
            let peek = Darwin.recv(fd, &peekByte, 1, MSG_PEEK)
            if peek == 0 {
                return true
            }
        }
        return false
    }

    private static func connectLoopbackTCPSocket(
        endpoint: LoopbackEndpoint,
        timeout: TimeInterval
    ) throws -> (fd: Int32, localEndpoint: LoopbackEndpoint) {
        let fd = Darwin.socket(endpoint.family, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LocalGatewayError.connectionFailed("无法创建本机回环套接字。")
        }
        var closed = false
        func closeFD() {
            if !closed {
                closed = true
                Darwin.close(fd)
            }
        }
        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let connectRC: Int32
        if endpoint.family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = endpoint.port.bigEndian
            guard endpoint.host.withCString({ Darwin.inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
                closeFD()
                throw LocalGatewayError.connectionFailed("无效的 IPv4 回环地址。")
            }
            connectRC = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else if endpoint.family == AF_INET6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = endpoint.port.bigEndian
            guard endpoint.host.withCString({ Darwin.inet_pton(AF_INET6, $0, &addr.sin6_addr) }) == 1 else {
                closeFD()
                throw LocalGatewayError.connectionFailed("无效的 IPv6 回环地址。")
            }
            connectRC = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            closeFD()
            throw LocalGatewayError.connectionFailed("不支持的地址族。")
        }

        if connectRC != 0 {
            let err = errno
            guard err == EINPROGRESS else {
                closeFD()
                throw LocalGatewayError.connectionFailed("连不上本机的 Mimi 服务。")
            }
            let deadline = Date().addingTimeInterval(timeout)
            do {
                try waitSocketReady(fd: fd, events: Int16(POLLOUT), deadline: deadline)
            } catch {
                closeFD()
                throw error
            }
            var soError: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            guard Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen) == 0, soError == 0 else {
                closeFD()
                throw LocalGatewayError.connectionFailed("连不上本机的 Mimi 服务。")
            }
        }

        guard let localEndpoint = extractLocalLoopbackEndpoint(fd: fd, expectedFamily: endpoint.family) else {
            closeFD()
            throw LocalGatewayError.connectionFailed("无法核验本机连接端点。")
        }
        return (fd, localEndpoint)
    }

    private static func extractLocalLoopbackEndpoint(fd: Int32, expectedFamily: Int32) -> LoopbackEndpoint? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.getsockname(fd, sa, &len)
            }
        }
        guard rc == 0 else { return nil }
        if Int32(storage.ss_family) == AF_INET, expectedFamily == AF_INET {
            let addr = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            var inAddr = addr.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard Darwin.inet_ntop(AF_INET, &inAddr, &buf, socklen_t(buf.count)) != nil else { return nil }
            return LoopbackEndpoint.parse(host: String(cString: buf), port: UInt16(bigEndian: addr.sin_port))
        }
        if Int32(storage.ss_family) == AF_INET6, expectedFamily == AF_INET6 {
            let addr = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            }
            var in6Addr = addr.sin6_addr
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard Darwin.inet_ntop(AF_INET6, &in6Addr, &buf, socklen_t(buf.count)) != nil else { return nil }
            return LoopbackEndpoint.parse(host: String(cString: buf), port: UInt16(bigEndian: addr.sin6_port))
        }
        return nil
    }

    private static func waitSocketReady(fd: Int32, events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw LocalGatewayError.timedOut
            }
            let ms = max(1, Int32(min(remaining * 1000.0, Double(Int32.max))))
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let rc = Darwin.poll(&pfd, 1, ms)
            if rc > 0 {
                return
            }
            if rc == 0 {
                throw LocalGatewayError.timedOut
            }
            if errno == EINTR { continue }
            throw LocalGatewayError.connectionFailed("与 Mimi 服务的连接中断了。")
        }
    }

    private static func writeAllSocket(_ bytes: [UInt8], to fd: Int32, deadline: Date) throws {
        var offset = 0
        while offset < bytes.count {
            try waitSocketReady(fd: fd, events: Int16(POLLOUT), deadline: deadline)
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            } else {
                throw LocalGatewayError.connectionFailed("与 Mimi 服务的连接中断了。")
            }
        }
    }

    private static func readMoreSocket(from fd: Int32, into buffer: inout [UInt8], deadline: Date, maxBytes: Int = 262_144) throws {
        try waitSocketReady(fd: fd, events: Int16(POLLIN), deadline: deadline)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n > 0 {
                if buffer.count + n > maxBytes {
                    throw LocalGatewayError.invalidResponse
                }
                buffer.append(contentsOf: chunk.prefix(n))
                return
            } else if n == 0 {
                throw LocalGatewayError.connectionFailed("与 Mimi 服务的连接中断了。")
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                try waitSocketReady(fd: fd, events: Int16(POLLIN), deadline: deadline)
            } else {
                throw LocalGatewayError.connectionFailed("与 Mimi 服务的连接中断了。")
            }
        }
    }

    private static func encodeMaskedClientFrame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0x80 | (opcode & 0x0F)]
        let len = payload.count
        if len < 126 {
            frame.append(0x80 | UInt8(len))
        } else if len <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(len) >> UInt64(shift)) & 0xFF))
            }
        }
        let mask: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        for (i, byte) in payload.enumerated() {
            frame.append(byte ^ mask[i & 3])
        }
        return frame
    }

    private static func readNextWebSocketMessage(
        from fd: Int32,
        buffer: inout [UInt8],
        deadline: Date
    ) throws -> Data {
        var assembled = Data()
        var expectingContinuation = false
        while true {
            while buffer.count < 2 {
                try readMoreSocket(from: fd, into: &buffer, deadline: deadline)
            }
            let b0 = buffer[0]
            let b1 = buffer[1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var headerLen = 2
            var payloadLen = Int(b1 & 0x7F)
            if payloadLen == 126 {
                while buffer.count < 4 {
                    try readMoreSocket(from: fd, into: &buffer, deadline: deadline)
                }
                payloadLen = (Int(buffer[2]) << 8) | Int(buffer[3])
                headerLen = 4
            } else if payloadLen == 127 {
                while buffer.count < 10 {
                    try readMoreSocket(from: fd, into: &buffer, deadline: deadline)
                }
                var len64: UInt64 = 0
                for i in 2..<10 {
                    len64 = (len64 << 8) | UInt64(buffer[i])
                }
                guard len64 <= 262_144 else { throw LocalGatewayError.invalidResponse }
                payloadLen = Int(len64)
                headerLen = 10
            }
            let maskLen = masked ? 4 : 0
            let totalLen = headerLen + maskLen + payloadLen
            guard totalLen <= 262_144 else { throw LocalGatewayError.invalidResponse }
            while buffer.count < totalLen {
                try readMoreSocket(from: fd, into: &buffer, deadline: deadline)
            }
            var payload = Array(buffer[(headerLen + maskLen)..<totalLen])
            if masked {
                let mask = Array(buffer[headerLen..<(headerLen + 4)])
                for i in 0..<payload.count {
                    payload[i] ^= mask[i & 3]
                }
            }
            buffer.removeFirst(totalLen)

            switch opcode {
            case 0x8:
                throw LocalGatewayError.connectionFailed("与 Mimi 服务的连接中断了。")
            case 0x9:
                let pong = encodeMaskedClientFrame(opcode: 0xA, payload: payload)
                try writeAllSocket(pong, to: fd, deadline: deadline)
                continue
            case 0xA:
                continue
            case 0x1, 0x2:
                assembled = Data(payload)
                if fin { return assembled }
                expectingContinuation = true
            case 0x0:
                guard expectingContinuation else { throw LocalGatewayError.invalidResponse }
                assembled.append(contentsOf: payload)
                if fin { return assembled }
            default:
                throw LocalGatewayError.invalidResponse
            }
        }
    }

    private static func performWebSocketCodexInitialize(
        fd: Int32,
        endpoint: LoopbackEndpoint,
        bearerToken: String,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        let keyBytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let secKey = Data(keyBytes).base64EncodedString()
        let expectedAccept = Data(
            Insecure.SHA1.hash(data: Data((secKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        ).base64EncodedString()

        let requestText =
            "GET /api/app-server/ws?runtime=codex HTTP/1.1\r\n" +
            "Host: \(endpoint.hostHeaderValue)\r\n" +
            "Authorization: Bearer \(bearerToken)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(secKey)\r\n" +
            "Sec-WebSocket-Version: 13\r\n\r\n"
        try writeAllSocket(Array(requestText.utf8), to: fd, deadline: deadline)

        var buffer: [UInt8] = []
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        var headerEndIndex: Int?
        while headerEndIndex == nil {
            try readMoreSocket(from: fd, into: &buffer, deadline: deadline, maxBytes: 65_536)
            if buffer.count >= 4 {
                for i in 0...(buffer.count - 4) {
                    if buffer[i] == separator[0] && buffer[i + 1] == separator[1] &&
                        buffer[i + 2] == separator[2] && buffer[i + 3] == separator[3] {
                        headerEndIndex = i + 4
                        break
                    }
                }
            }
        }
        guard let endIdx = headerEndIndex else { throw LocalGatewayError.invalidResponse }
        let headerBytes = Array(buffer.prefix(endIdx))
        buffer.removeFirst(endIdx)

        let headerText = String(decoding: headerBytes, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        let statusParts = (lines.first ?? "").split(separator: " ")
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw LocalGatewayError.invalidResponse
        }
        if statusCode != 101 {
            switch statusCode {
            case 401: throw LocalGatewayError.connectionFailed("本机凭据已失效，请重新打开窗口。")
            case 429: throw LocalGatewayError.connectionFailed("连接数已满，请稍后再试。")
            case 503: throw LocalGatewayError.runtimeUnavailable("这个助手当前不可用。")
            default: throw LocalGatewayError.connectionFailed("与 Mimi 服务的连接中断了。")
            }
        }
        var acceptHeader: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if k == "sec-websocket-accept" {
                acceptHeader = v
            }
        }
        guard acceptHeader == expectedAccept else {
            throw LocalGatewayError.invalidResponse
        }

        let initReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "mimi_remote", "title": "Mimi Remote Mac", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true, "requestAttestation": false],
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initReq)
        try writeAllSocket(encodeMaskedClientFrame(opcode: 0x1, payload: Array(initData)), to: fd, deadline: deadline)

        while true {
            let msgData = try readNextWebSocketMessage(from: fd, buffer: &buffer, deadline: deadline)
            guard let frame = (try? JSONSerialization.jsonObject(with: msgData)) as? [String: Any] else {
                throw LocalGatewayError.invalidResponse
            }
            if let error = frame["error"] as? [String: Any] {
                let frameID = (frame["id"] as? NSNumber)?.intValue
                if frameID == nil {
                    throw LocalGatewayError.runtimeUnavailable(LocalJSONRPCChannel.message(from: error))
                }
                if frameID == 1 {
                    throw LocalGatewayError.requestRejected(
                        code: (error["code"] as? NSNumber)?.intValue,
                        reason: (error["data"] as? [String: Any])?["reason"] as? String,
                        message: LocalJSONRPCChannel.message(from: error)
                    )
                }
                continue
            }
            guard (frame["id"] as? NSNumber)?.intValue == 1 else { continue }
            guard frame["result"] is [String: Any] else { throw LocalGatewayError.invalidResponse }
            break
        }

        let initializedReq: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "initialized",
            "params": [String: Any](),
        ]
        let initializedData = try JSONSerialization.data(withJSONObject: initializedReq)
        try writeAllSocket(encodeMaskedClientFrame(opcode: 0x1, payload: Array(initializedData)), to: fd, deadline: deadline)
    }

    private func connect(runtime: SessionRuntime, port: Int) async throws -> LocalJSONRPCChannel {
        let token = try await claimToken(port: port)
        return try await connect(runtime: runtime, port: port, token: token)
    }

    private func connect(runtime: SessionRuntime, port: Int, token: String) async throws -> LocalJSONRPCChannel {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/api/app-server/ws?runtime=\(runtime.rawValue)") else {
            throw LocalGatewayError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout
        let task = session.webSocketTask(with: request)
        task.resume()
        let channel = LocalJSONRPCChannel(task: task, timeout: requestTimeout)
        do {
            _ = try await channel.call("initialize", params: [
                "clientInfo": ["name": "mimi_remote", "title": "Mimi Remote Mac", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true, "requestAttestation": false],
            ])
            try await channel.notify("initialized", params: [:])
        } catch {
            channel.close()
            throw error
        }
        return channel
    }

    func claimToken(port: Int) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/pair/local") else {
            throw LocalGatewayError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("1", forHTTPHeaderField: "X-Mimi-Local-Pairing")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LocalGatewayError.connectionFailed("连不上本机的 Mimi 服务。")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LocalGatewayError.claimRejected(
                (object?["error"] as? String) ?? "Mimi 服务拒绝了本机连接。"
            )
        }
        guard let token = object?["token"] as? String, !token.isEmpty else {
            throw LocalGatewayError.invalidResponse
        }
        return token
    }
}

/// 一条 WebSocket 上的最小 JSON-RPC 往返：按 id 等待响应，忽略期间的通知。
/// 每次调用独立计时，超时直接关闭连接让等待中的接收失败。
final class LocalJSONRPCChannel: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var nextID = 1
    private var didTimeOut = false

    init(task: URLSessionWebSocketTask, timeout: TimeInterval) {
        self.task = task
        self.timeout = timeout
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    func notify(_ method: String, params: [String: Any]) async throws {
        try await send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func call(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.timeout ?? 0))
            guard !Task.isCancelled else { return }
            self?.expire()
        }
        defer { timer.cancel() }
        try await send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            let frame = try await receiveFrame()
            if let error = frame["error"] as? [String: Any] {
                let frameID = (frame["id"] as? NSNumber)?.intValue
                // 网关在拒绝整条连接时用 id 为 null 的错误帧说明原因，例如 Claude 未启用。
                if frameID == nil {
                    throw LocalGatewayError.runtimeUnavailable(Self.message(from: error))
                }
                if frameID == id {
                    throw LocalGatewayError.requestRejected(
                        code: (error["code"] as? NSNumber)?.intValue,
                        reason: (error["data"] as? [String: Any])?["reason"] as? String,
                        message: Self.message(from: error)
                    )
                }
                continue
            }
            guard (frame["id"] as? NSNumber)?.intValue == id else { continue }
            guard let result = frame["result"] as? [String: Any] else { throw LocalGatewayError.invalidResponse }
            return result
        }
    }

    private func expire() {
        lock.withLock { didTimeOut = true }
        task.cancel(with: .goingAway, reason: nil)
    }

    private func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw LocalGatewayError.invalidResponse }
        do {
            try await task.send(.string(text))
        } catch {
            throw transportError(error)
        }
    }

    private func receiveFrame() async throws -> [String: Any] {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw transportError(error)
        }
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: throw LocalGatewayError.invalidResponse
        }
        guard let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LocalGatewayError.invalidResponse
        }
        return frame
    }

    private func transportError(_ error: Error) -> LocalGatewayError {
        if lock.withLock({ didTimeOut }) { return .timedOut }
        switch (task.response as? HTTPURLResponse)?.statusCode {
        case 401: return .connectionFailed("本机凭据已失效，请重新打开窗口。")
        case 429: return .connectionFailed("连接数已满，请稍后再试。")
        case 503: return .runtimeUnavailable("这个助手当前不可用。")
        default: return .connectionFailed("与 Mimi 服务的连接中断了。")
        }
    }

    /// 网关错误形如 `CLAUDE_DISABLED: Claude Code runtime 未启用`，展示时去掉前面的代码。
    static func message(from error: [String: Any]) -> String {
        let raw = (error["message"] as? String) ?? ""
        if let range = raw.range(of: ": "), raw[..<range.lowerBound].allSatisfy({ $0.isUppercase || $0 == "_" }) {
            return String(raw[range.upperBound...])
        }
        return raw.isEmpty ? "服务返回了错误。" : raw
    }
}
