import Foundation

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
    case invalidResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .claimRejected(let message): message
        case .connectionFailed(let message): message
        case .runtimeUnavailable(let message): message
        case .invalidResponse: "服务返回了无法识别的内容。"
        case .timedOut: "服务没有及时响应。"
        }
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
        let token = try await claimToken(port: port)
        guard let url = URL(string: "ws://127.0.0.1:\(port)/api/app-server/ws?runtime=\(runtime.rawValue)") else {
            throw LocalGatewayError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let channel = LocalJSONRPCChannel(task: task, timeout: requestTimeout)
        _ = try await channel.call("initialize", params: [
            "clientInfo": ["name": "mimi_remote", "title": "Mimi Remote Mac", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true, "requestAttestation": false],
        ])
        try await channel.notify("initialized", params: [:])

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
                if frameID == nil || frameID == id {
                    throw LocalGatewayError.runtimeUnavailable(Self.message(from: error))
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
