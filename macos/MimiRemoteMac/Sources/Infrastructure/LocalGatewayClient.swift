import Foundation

/// 一个 runtime 的会话列表。`hasMore` 表示还有更早的页没有取。
struct DesktopSessionListing: Equatable, Sendable {
    let sessions: [DesktopSession]
    let hasMore: Bool
}

/// 在 Claude 桌面版打开的结果。`alreadyInDesktop` 表示桌面版本来就开着，只是切到前台。
struct ClaudeDesktopOpenResult: Equatable, Sendable {
    let alreadyInDesktop: Bool
}

protocol DesktopSessionSource: Sendable {
    func listSessions(runtime: SessionRuntime, port: Int, pageBudget: Int) async throws -> DesktopSessionListing
    func openInClaudeDesktop(threadID: String, cwd: String, port: Int) async throws -> ClaudeDesktopOpenResult
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

    static let authorizationPageLimit = 200

    /// 在会话目录里逐页列，直到见到目标会话。列表里「加载更早的会话」能翻到多深，这里就要能找多深；
    /// 上限只防服务端游标出错时死循环。
    static func authorizeThread(
        _ threadID: String,
        cwd: String,
        list: (_ params: [String: Any]) async throws -> [String: Any]
    ) async throws -> Bool {
        var cursor: String?
        var pages = 0
        repeat {
            var params = threadListParams(cursor: cursor)
            params["cwd"] = cwd
            params["sourceKinds"] = nil
            let result = try await list(params)
            let items = result["data"] as? [[String: Any]] ?? []
            if items.contains(where: { ($0["id"] as? String) == threadID }) { return true }
            cursor = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            pages += 1
        } while cursor != nil && pages < authorizationPageLimit
        return false
    }

    /// 先在会话所在目录列一次，让网关授权这条会话，再请求适配器打开桌面版。
    /// 网关只允许对本连接见过的会话执行操作，新连接必须先列出它。
    func openInClaudeDesktop(threadID: String, cwd: String, port: Int) async throws -> ClaudeDesktopOpenResult {
        let channel = try await connect(runtime: .claude, port: port)
        defer { channel.close() }
        let found = try await Self.authorizeThread(threadID, cwd: cwd) { params in
            try await channel.call("thread/list", params: params)
        }
        guard found else {
            throw LocalGatewayError.connectionFailed("找不到这条会话，刷新列表后再试。")
        }
        let result = try await channel.call("thread/desktop/open", params: ["threadId": threadID])
        return ClaudeDesktopOpenResult(alreadyInDesktop: result["alreadyInDesktop"] as? Bool ?? false)
    }

    private func connect(runtime: SessionRuntime, port: Int) async throws -> LocalJSONRPCChannel {
        let token = try await claimToken(port: port)
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
