import Foundation

/// 原生 Harness 传输层（H04）。
///
/// 两条通道，形状与 H03 注册的 agentd 路由一一对应：
/// - `POST /api/harness/rpc` —— Connection RPC 只读中继（list / search / page / modelCatalog）；
/// - `WS /api/harness/ws`    —— remote.mux 流中继（$events / session/follow / session/control）。
///
/// 边界（H04 卡片的硬约束）：
/// - 只连 agentd 给定的这两条原生路径，携带既有手机凭据；
/// - **不**读取、**不**存储 Harness 的 token 与 Cookie——握手换 Cookie 是 agentd 的事，
///   移动端连 Harness 的地址都不知道，所以这里连 Cookie 存储都显式关掉；
/// - 业务数据只解到 `HarnessWireTypes` 的 DTO，**不经过** Codex JSON-RPC DTO。
///
/// 这里只做传输。连接代次、在途请求、有限缓冲、心跳在 `HarnessSessionRuntime`。

// MARK: - 路径

/// agentd 上的原生 Harness 通道路径。
///
/// 与 `internal/httpapi/router.go` 的两条 `mux.Handle` 逐字对应。写成常量而不是散落
/// 在调用点，是为了让"移动端只走这两条路径"这件事可以被一条断言检查。
enum HarnessTransportPath {
    static let rpc = "/api/harness/rpc"
    static let stream = "/api/harness/ws"
}

// MARK: - 错误分类

/// 传输层失败分类。
///
/// 分类存在的唯一理由是**决定要不要重连**。把"上游给了业务结论"和"链路断了"合并成
/// 一个错误，调用方就只能一律重连：对后者有意义，对前者只是把同一个业务失败重放一遍。
/// 因此每个 case 都必须能回答 `shouldReconnect`，而不是靠调用方猜。
enum HarnessTransportError: Error, Equatable {
    /// 401/403：手机凭据失效。换凭据后重连有意义。
    case unauthorized(status: Int)
    /// 中继本地策略拒绝（越权、参数非法、方法不开放）。重连不会改变结论。
    case rejected(status: Int, message: String)
    /// 502/503 或其它非 200：上游不可用。可重连。
    case server(status: Int, message: String)
    /// 响应结构不合约（缺 result、type 不对、ok=true 却没有 value）。协议缺陷，重连无用。
    case malformedResponse(String)
    /// HTTP 200 + `result.ok == false`：上游给出的**业务**结论。重连无用。
    case business(HarnessRemoteError)
    /// 响应里的 rpcId 与任何在途请求都不符：无法归属。当成成功会张冠李戴，
    /// 当成失败会掩盖真正在途的那条请求。两者都不做，如实记录。
    case unattributedResponse(rpcId: String)
    /// 本地没有可用连接。
    case notConnected
    /// 对端已关闭。
    case closed
    /// 读超时或心跳失败（含半开链路）。
    case timedOut
    /// 载体层错误帧。上游已经给出结论，重连无用。
    case carrier(HarnessRemoteError)
    /// 认不出的安全交互（既非审批也非追问）。移动端无法构造合法应答，必须显式拒绝。
    case unsupportedInteraction(String)
    /// 调用方取消。不是故障。
    case cancelled

    /// 重连是否能改变结果。
    ///
    /// 只有"链路层"的失败才返回 true。业务失败、策略拒绝、协议缺陷重连多少次都是同一个
    /// 结论——这正是"不同错误分类不能都变成 reconnect"的落点。
    var shouldReconnect: Bool {
        switch self {
        case .unauthorized, .server, .notConnected, .closed, .timedOut:
            return true
        case .rejected, .malformedResponse, .business, .unattributedResponse,
             .carrier, .unsupportedInteraction, .cancelled:
            return false
        }
    }

    /// 诊断用的一行描述。带码值，便于把日志与分类对上。
    var diagnosticSummary: String {
        switch self {
        case .unauthorized(let status):
            return "unauthorized(\(status))"
        case .rejected(let status, let message):
            return "rejected(\(status)):\(message)"
        case .server(let status, let message):
            return "server(\(status)):\(message)"
        case .malformedResponse(let detail):
            return "malformed-response:\(detail)"
        case .business(let error):
            return "business:\(error.diagnosticCode)"
        case .unattributedResponse(let rpcId):
            return "unattributed-response:\(rpcId)"
        case .notConnected:
            return "not-connected"
        case .closed:
            return "closed"
        case .timedOut:
            return "timed-out"
        case .carrier(let error):
            return "carrier:\(error.diagnosticCode)"
        case .unsupportedInteraction(let event):
            return "unsupported-interaction:\(event)"
        case .cancelled:
            return "cancelled"
        }
    }
}

// MARK: - 会话构造

/// 原生通道专用的 URLSession 构造。
///
/// 显式关掉 Cookie：agentd 的 REST 与 WS 都只认 `Authorization: Bearer`，而 Harness
/// 自己的凭据是 hostname+port 绑定的 Cookie。默认的 `.ephemeral` 仍会读写
/// `HTTPCookieStorage.shared`，一旦将来有代码把 Harness 地址混进来，Cookie 就可能被
/// 存到共享存储里。这里把入口关掉，让"不读取或存储 Harness token/Cookie"成为配置事实，
/// 而不是一句注释。
enum HarnessTransportSession {
    static func make(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration)
    }
}

// MARK: - Connection RPC

/// 一次只读 RPC 调用。
struct HarnessRPCRequest: Encodable {
    let rpcId: String
    let method: String
    /// 原生形参对象。`session/list` 用 `{"_request":{}}`，`session/search`/`page` 用
    /// `{"request":{...}}`，`session/modelCatalog` 无参数。中继按方法严格校验，未知键直接拒绝。
    let args: HarnessJSONValue?
    /// 授权提示。中继用它决定能看见哪些会话；它**不进**上游 args。
    let cwd: String?
}

/// 只读 RPC 传输。
///
/// 协议化是为了让运行时能被注入 fake：所有"被拒的调用没有触达网络"的断言都只能靠一个
/// 可观测的替身完成。
protocol HarnessRPCTransport: AnyObject {
    func call(_ request: HarnessRPCRequest) async throws -> HarnessJSONValue
}

/// 走 agentd `POST /api/harness/rpc` 的实现。
final class URLSessionHarnessRPCTransport: HarnessRPCTransport {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let path: String
    private let timeout: TimeInterval

    init(
        baseURL: URL,
        token: String,
        session: URLSession = HarnessTransportSession.make(),
        path: String = HarnessTransportPath.rpc,
        timeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.path = path
        self.timeout = timeout
    }

    func call(_ request: HarnessRPCRequest) async throws -> HarnessJSONValue {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        MimiProtocolContract.applyClientHeaders(to: &urlRequest)
        do {
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            throw HarnessTransportError.malformedResponse("Could not encode request arguments: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let urlError as URLError {
            throw Self.mapped(urlError)
        } catch {
            throw HarnessTransportError.server(status: 0, message: "\(error)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Self.mappedStatus(status, data: data)
        }
        return try Self.decodeSuccess(data: data, expectedRPCID: request.rpcId)
    }

    /// 传输层失败映射。
    ///
    /// 只把真正"重连可能有用"的 URLError 归到可重连分类，其余收敛成 `.server` 以免把
    /// 本地编码错误伪装成链路故障。
    static func mapped(_ error: URLError) -> HarnessTransportError {
        switch error.code {
        case .timedOut:
            return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed:
            return .notConnected
        case .cancelled:
            return .cancelled
        default:
            return .server(status: 0, message: error.localizedDescription)
        }
    }

    /// 非 200 状态码映射。
    ///
    /// 中继的本地拒绝用状态码下发（不是 `result.ok=false`），所以 4xx 里既有"凭据失效"
    /// 也有"策略拒绝"：前者换凭据可恢复，后者换多少次都是同一个结论。
    static func mappedStatus(_ status: Int, data: Data) -> HarnessTransportError {
        let message = Self.errorMessage(from: data)
        switch status {
        case 401, 403:
            // 403 在中继里既是"凭据无效"也是"origin 不允许/方法不开放"。文案由中继给出，
            // 这里按状态码归类为凭据问题——重连是唯一可能改变结果的本地动作。
            return .unauthorized(status: status)
        case 400, 404, 405, 413, 415:
            return .rejected(status: status, message: message)
        case 502, 503:
            return .server(status: status, message: message)
        default:
            return .server(status: status, message: message)
        }
    }

    /// 取出中继 `writeError` 下发的 `{"error": "..."}` 文案。
    ///
    /// 解不出就返回空串：诊断文案缺失不是错误分类的依据，不能因为文案解不出就改判分类。
    static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["error"] as? String
        else {
            return ""
        }
        return message
    }

    /// 解一次 200 响应。
    ///
    /// 判定顺序是契约的一部分：先看外壳 type，再看 `result.ok`，最后才取 value。HTTP 200
    /// 只说明"中继答复了"，业务成败在 `result.ok` 里。
    static func decodeSuccess(data: Data, expectedRPCID: String) throws -> HarnessJSONValue {
        let response: HarnessServerResponse
        do {
            response = try JSONDecoder().decode(HarnessServerResponse.self, from: data)
        } catch {
            throw HarnessTransportError.malformedResponse("Response is not a valid JSON envelope: \(error)")
        }
        if let type = response.type, type != "server-response" {
            throw HarnessTransportError.malformedResponse("Response type is not server-response: \(type)")
        }
        if let rpcId = response.rpcId, !rpcId.isEmpty, rpcId != expectedRPCID {
            throw HarnessTransportError.unattributedResponse(rpcId: rpcId)
        }
        guard let result = response.result else {
            throw HarnessTransportError.malformedResponse("Response is missing result")
        }
        guard result.ok else {
            throw HarnessTransportError.business(result.error ?? HarnessRemoteError(
                code: "harness/unknown",
                message: nil,
                details: nil
            ))
        }
        guard let value = result.value else {
            throw HarnessTransportError.malformedResponse("result.ok=true without value")
        }
        return value
    }
}

// MARK: - remote.mux 流

/// 移动端发往 agentd 的流帧。
///
/// `open`/`cancel` 与 Harness 自己的 remote.mux 同形（见 `stream/mux-carrier.json`）；
/// `respond` 是中继的扩展，承载 `$events/result` 的语义。刻意**不**带 clientId：
/// 应答要用哪个 clientId 由中继自己持有。
enum HarnessClientFrame: Equatable {
    case open(streamID: String, endpoint: String, args: HarnessJSONValue?)
    case cancel(streamID: String)
    case respond(eventID: String, outcome: HarnessOutcome)

    /// wire 表示。`args` 为 nil 时不写 `payload`，中继把缺失当作零参数订阅。
    var wireValue: HarnessJSONValue {
        switch self {
        case .open(let streamID, let endpoint, let args):
            var frame: [String: HarnessJSONValue] = [
                "type": .string("open"),
                "streamId": .string(streamID),
                "endpoint": .string(endpoint),
            ]
            if let args {
                frame["payload"] = .object(["args": args])
            }
            return .object(frame)
        case .cancel(let streamID):
            return .object([
                "type": .string("cancel"),
                "streamId": .string(streamID),
            ])
        case .respond(let eventID, let outcome):
            return .object([
                "type": .string("respond"),
                "eventId": .string(eventID),
                "outcome": outcome.wireValue,
            ])
        }
    }

    func encoded() throws -> Data {
        do {
            return try JSONEncoder().encode(wireValue)
        } catch {
            throw HarnessTransportError.malformedResponse("Could not encode client frame: \(error)")
        }
    }
}

/// `session/follow` 的订阅目标。形状逐字取自 `stream/follow-frames.json` 的 `request`
/// 观测：`{"request":{"address":{...},"assistantStream":true,"maxMessages":200}}`。
///
/// `address` 嵌在 `request` 下面，**不是**顶层键。H03 的自审已经踩过一次：把 address
/// 当顶层键解，每个 follow 都会被拒，而"全都被拒"看起来和策略生效一模一样。
struct HarnessFollowTarget: Equatable {
    let sessionID: String
    let kind: String
    var assistantStream: Bool?
    var maxMessages: Int?

    init(sessionID: String, kind: String = "session", assistantStream: Bool? = nil, maxMessages: Int? = nil) {
        self.sessionID = sessionID
        self.kind = kind
        self.assistantStream = assistantStream
        self.maxMessages = maxMessages
    }

    /// 转成 `payload.args`。
    var argsValue: HarnessJSONValue {
        var request: [String: HarnessJSONValue] = [
            "address": .object([
                "kind": .string(kind),
                "sessionId": .string(sessionID),
            ]),
        ]
        if let assistantStream {
            request["assistantStream"] = .bool(assistantStream)
        }
        if let maxMessages {
            request["maxMessages"] = .number(Double(maxMessages))
        }
        return .object(["request": .object(request)])
    }
}

/// 流传输。
///
/// 单 reader 由调用方（运行时 actor）保证：协议本身不提供并发读，只提供"读下一帧"。
protocol HarnessStreamTransport: AnyObject {
    /// 建立连接。必须幂等：重复调用不得产生第二条连接。
    func connect() async throws
    /// 发送一帧。写入串行由调用方保证。
    func send(_ frame: HarnessClientFrame) async throws
    /// 读下一帧。返回 nil 表示对端正常结束。
    func receive() async throws -> HarnessCarrierFrame?
    /// 心跳。半开链路上 `receive` 会一直挂着不返回，只有主动探测才能发现。
    func ping() async throws
    /// 关闭。必须幂等：重复关闭不得抛错，也不得二次关闭已关闭的连接。
    func close() async
}

/// 走 agentd `WS /api/harness/ws` 的实现。
final class URLSessionHarnessStreamTransport: HarnessStreamTransport {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let path: String
    private let pingTimeout: TimeInterval

    private var task: URLSessionWebSocketTask?
    private var closed = false

    init(
        baseURL: URL,
        token: String,
        session: URLSession = HarnessTransportSession.make(),
        path: String = HarnessTransportPath.stream,
        pingTimeout: TimeInterval = 10
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.path = path
        self.pingTimeout = pingTimeout
    }

    func connect() async throws {
        guard task == nil, !closed else { return }
        let request = makeConnectRequest()
        let nextTask = session.webSocketTask(with: request)
        WebSocketMessageLimits.apply(to: nextTask)
        task = nextTask
        nextTask.resume()
    }

    /// 构造握手请求。
    ///
    /// 抽出来是为了让"只连 agentd 的原生路径、只带手机凭据、不带 Cookie"这三件事可以在
    /// 不起真实连接的情况下被断言——否则这条约束只能靠读代码确认。
    func makeConnectRequest() -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        MimiProtocolContract.applyClientHeaders(to: &request)
        return request
    }

    func send(_ frame: HarnessClientFrame) async throws {
        guard let task, !closed else {
            throw HarnessTransportError.notConnected
        }
        let data = try frame.encoded()
        guard let text = String(data: data, encoding: .utf8) else {
            throw HarnessTransportError.malformedResponse("Client frame is not valid UTF-8")
        }
        do {
            try await task.send(.string(text))
        } catch let urlError as URLError {
            throw URLSessionHarnessRPCTransport.mapped(urlError)
        } catch {
            throw HarnessTransportError.closed
        }
    }

    func receive() async throws -> HarnessCarrierFrame? {
        guard let task, !closed else {
            throw HarnessTransportError.notConnected
        }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch let urlError as URLError {
            throw URLSessionHarnessRPCTransport.mapped(urlError)
        } catch {
            throw HarnessTransportError.closed
        }
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            throw HarnessTransportError.malformedResponse("Unknown WebSocket message type")
        }
        do {
            return try JSONDecoder().decode(HarnessCarrierFrame.self, from: data)
        } catch {
            throw HarnessTransportError.malformedResponse("Carrier frame is not valid JSON: \(error)")
        }
    }

    /// 心跳探测。
    ///
    /// 半开链路的表现是 `sendPing` 的回调**永远不触发**——所以这里不能只等回调，必须同时
    /// 挂一个本地超时。两者谁先到谁决定结果，另一个变成空操作（`OneShotResumer` 保证只
    /// 恢复一次）。少了这个超时，探测本身就变成一个新的挂起点，等于没做探测。
    func ping() async throws {
        guard let task, !closed else {
            throw HarnessTransportError.notConnected
        }
        let resumer = OneShotResumer()
        let timeout = pingTimeout
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            resumer.finish(.failure(HarnessTransportError.timedOut))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // 先登记再发探测：sendPing 有可能同步回调，反过来就会丢掉那次恢复。
            resumer.park(continuation)
            task.sendPing { error in
                resumer.finish(error == nil ? .success(()) : .failure(HarnessTransportError.timedOut))
            }
        }
    }

    /// 关闭。幂等：`close()` 之后 `task` 置空，重复调用直接返回。
    func close() async {
        closed = true
        let current = task
        task = nil
        current?.cancel(with: .normalClosure, reason: nil)
    }
}

/// 只恢复一次的续体持有者。
///
/// `ping()` 有两条互相竞争的结果来源（pong 回调、本地超时）。用 `CheckedContinuation`
/// 直接比较会崩溃或泄漏，因此把"只恢复一次"这件事收敛到一个小对象里，两边都走它。
final class OneShotResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Void, Error>?

    /// 登记续体。若结果已先到，立即按已定结果恢复，不再挂起。
    func park(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: HarnessTransportError.timedOut)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let parked = continuation
        continuation = nil
        lock.unlock()
        parked?.resume(with: result)
    }
}
