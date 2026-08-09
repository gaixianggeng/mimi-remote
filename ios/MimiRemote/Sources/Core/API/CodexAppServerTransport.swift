import Foundation

enum TurnSendOutcome: Equatable {
    case accepted(turnID: TurnID?)
    case guidanceAccepted
    case acceptedTerminal(turnID: TurnID?)
    case acceptedSuperseded(
        turnID: TurnID?,
        activeTurnID: TurnID
    )
    case acceptedThreadClosed(turnID: TurnID?)
    case activeTurnConflict(activeTurnID: TurnID, message: String)
    case rejected(message: String)
    case uncertain(message: String)
}

protocol SessionWebSocketClient: AnyObject {
    var onEvent: (@MainActor (AgentEvent) -> Void)? { get set }
    var onStatus: ((WebSocketStatus) -> Void)? { get set }
    var onSendAccepted: ((ClientMessageID?) -> Void)? { get set }
    var onSendFailure: ((ClientMessageID?, String) -> Void)? { get set }
    var onTurnSendOutcome: ((ClientMessageID?, TurnSendOutcome) -> Void)? { get set }
    var onApprovalDecisionFailure: ((String, String) -> Void)? { get set }
    var onUserInputResponseFailure: ((String, String) -> Void)? { get set }
    var onControlFailure: ((String) -> Void)? { get set }

    func connect(sessionID: SessionID)
    func connect(sessionID: SessionID, replayBufferedEvents: Bool)
    func disconnect()
    func sendInput(_ text: String, clientMessageID: ClientMessageID?) -> Bool
    func sendTurn(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) -> Bool
    func sendGuidance(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?, expectedTurnID: TurnID) -> Bool
    func sendCtrlC(expectedTurnID: TurnID) -> Bool
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool
    func sendUserInputResponse(requestID: String, answers: [String: [String]]) -> Bool
    func acknowledgeAppliedEvent(_ event: AgentEvent)
}

extension SessionWebSocketClient {
    func connect(sessionID: SessionID, replayBufferedEvents: Bool) {
        connect(sessionID: sessionID)
    }

    func acknowledgeAppliedEvent(_ event: AgentEvent) {}
}

enum WebSocketMessageLimits {
    static let maximumInboundMessageBytes = 64 * 1024 * 1024

    static func apply(to task: URLSessionWebSocketTask, maximumMessageSize: Int = maximumInboundMessageBytes) {
        task.maximumMessageSize = max(1, maximumMessageSize)
    }
}

protocol CodexAppServerTransport: AnyObject {
    func connect(url: URL, token: String) async throws
    func send(_ text: String) async throws
    func receive() async throws -> String?
    func close() async
}

final class URLSessionCodexAppServerTransport: CodexAppServerTransport {
    private let session: URLSession
    private let maximumMessageSize: Int
    private var task: URLSessionWebSocketTask?
    private var credentialFingerprint: String?

    init(
        session: URLSession = .shared,
        maximumMessageSize: Int = WebSocketMessageLimits.maximumInboundMessageBytes
    ) {
        self.session = session
        self.maximumMessageSize = max(1, maximumMessageSize)
    }

    func connect(url: URL, token: String) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        MimiProtocolContract.applyClientHeaders(to: &request)
        credentialFingerprint = connectionCredentialFingerprint(token)
        let nextTask = session.webSocketTask(with: request)
        WebSocketMessageLimits.apply(to: nextTask, maximumMessageSize: maximumMessageSize)
        task = nextTask
        nextTask.resume()
    }

    func send(_ text: String) async throws {
        guard let task else {
            throw CodexAppServerConnectionError.disconnected
        }
        do {
            try await task.send(.string(text))
        } catch {
            throw Self.mappedTaskError(
                error,
                response: task.response,
                credentialFingerprint: credentialFingerprint
            )
        }
    }

    func receive() async throws -> String? {
        guard let task else {
            throw CodexAppServerConnectionError.disconnected
        }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw Self.mappedTaskError(
                error,
                response: task.response,
                credentialFingerprint: credentialFingerprint
            )
        }
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8)
        @unknown default:
            return nil
        }
    }

    func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        credentialFingerprint = nil
    }

    static func mappedTaskError(
        _ error: Error,
        response: URLResponse?,
        credentialFingerprint: String? = nil
    ) -> Error {
        // URLSessionWebSocketTask.resume() 不等待 HTTP Upgrade 完成；401/403 通常在首个
        // send/receive 才抛出。此时必须读取握手响应并保留类型，不能只上传输层字符串。
        if let status = (response as? HTTPURLResponse)?.statusCode,
           status == 401 || status == 403 {
            return AgentAPIError.credentialsInvalid(
                status: status,
                credentialFingerprint: credentialFingerprint
            )
        }
        if let http = response as? HTTPURLResponse,
           http.statusCode == 426 {
            let serverRevision = http.value(
                forHTTPHeaderField: MimiProtocolContract.serverRevisionHeader
            ) ?? "unknown"
            let minimumClientRevision = http.value(
                forHTTPHeaderField: MimiProtocolContract.minimumClientRevisionHeader
            ) ?? "unknown"
            return AgentAPIError.server(
                status: http.statusCode,
                message: L10n.format(
                    "ui.agentd_websocket_protocol_incompatible_values",
                    serverRevision,
                    minimumClientRevision,
                    MimiProtocolContract.currentRevision
                )
            )
        }
        return error
    }
}

enum CodexAppServerConnectionError: LocalizedError, CredentialInvalidatingError {
    case disconnected
    case notInitialized
    case duplicateRequestID(CodexAppServerRequestID)
    case timeout(method: String, id: CodexAppServerRequestID)
    case appServer(CodexAppServerError)
    case decoding(Error)
    case transport(Error)

    var invalidatesCredentials: Bool {
        if case .transport(let error) = self {
            return isCredentialInvalidatingError(error)
        }
        return false
    }

    var rejectedCredentialFingerprint: String? {
        if case .transport(let error) = self {
            return credentialFingerprintRejectedByError(error)
        }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return L10n.text("ui.app_server_websocket_not_connected")
        case .notInitialized:
            return L10n.text("ui.app_server_has_not_yet_completed_initialize_initialized")
        case .duplicateRequestID(let id):
            return L10n.format("ui.duplicate_json_rpc_request_id_value", id)
        case .timeout(let method, let id):
            return L10n.format("ui.app_server_request_timeout_value_value", method, id)
        case .appServer(let error):
            return error.localizedDescription
        case .decoding(let error):
            return L10n.format("ui.app_server_message_parsing_failed_value", error.localizedDescription)
        case .transport(let error):
            return L10n.format("ui.app_server_websocket_transfer_failed_value", error.localizedDescription)
        }
    }
}

private struct PendingCodexAppServerResponse {
    let method: String
    let continuation: CheckedContinuation<CodexAppServerJSONValue?, Error>
    let timeoutTask: Task<Void, Never>
}

/// JSON-RPC 请求 id 的全进程分配器：每条连接都从上一条连接用完的地方继续，
/// 绝不从 1 重来。
///
/// Claude 常驻 bridge 的回放环里可能还留着上一条连接未被消费的响应帧。id 一旦
/// 被复用，那条陈旧响应就会兑现新连接里编号相同的请求——而 `model/list` 与
/// `thread/list` 的结果都是 `{data, nextCursor}`，模型目录会被原样投影成最近
/// 会话列表（MIM-120）。响应帧里没有 method，客户端事后无从分辨，只能靠 id 不
/// 复用来根除。
///
/// 起点按进程随机：App 重启后 bridge 那边仍是同一个常驻会话，固定起点同样会撞。
private enum CodexAppServerRequestIDAllocator {
    private static let lock = NSLock()
    // 上界留足余量，保证 id 始终落在 JSON number 的精确整数区间内。
    nonisolated(unsafe) private static var next: Int64 = .random(in: 1...(1 << 40))

    static func allocate() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let id = next
        next &+= 1
        return id
    }
}

actor CodexAppServerConnection {
    private let transport: CodexAppServerTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let requestTimeoutNanoseconds: UInt64
    private var pendingResponses: [CodexAppServerRequestID: PendingCodexAppServerResponse] = [:]
    private var receiveTask: Task<Void, Never>?
    private var isConnected = false
    private var isInitialized = false
    private var notificationContinuation: AsyncStream<CodexAppServerNotification>.Continuation?
    private var serverRequestContinuation: AsyncStream<CodexAppServerServerRequest>.Continuation?

    init(
        transport: CodexAppServerTransport = URLSessionCodexAppServerTransport(),
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = AgentAPIClient.decoder,
        requestTimeout: TimeInterval = 20
    ) {
        self.transport = transport
        self.encoder = encoder
        self.decoder = decoder
        self.requestTimeoutNanoseconds = UInt64(max(0.1, requestTimeout) * 1_000_000_000)
    }

    deinit {
        receiveTask?.cancel()
        notificationContinuation?.finish()
        serverRequestContinuation?.finish()
    }

    func notifications() -> AsyncStream<CodexAppServerNotification> {
        var continuation: AsyncStream<CodexAppServerNotification>.Continuation?
        // app-server 通知包含 delta、完成态和审批状态，任何一条被丢都会让 iPad 时间线和真实
        // thread 状态不一致；这里宁可让连接级队列短暂增大，也不静默丢旧事件。
        let stream = AsyncStream<CodexAppServerNotification>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        notificationContinuation = continuation
        return stream
    }

    func serverRequests() -> AsyncStream<CodexAppServerServerRequest> {
        var continuation: AsyncStream<CodexAppServerServerRequest>.Continuation?
        // 审批 request 必须逐条处理，丢掉旧 request 会导致 app-server 一直等待移动端响应。
        let stream = AsyncStream<CodexAppServerServerRequest>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        serverRequestContinuation = continuation
        return stream
    }

    func isReadyForRequests() -> Bool {
        guard let receiveTask else {
            return false
        }
        return isConnected && isInitialized && !receiveTask.isCancelled
    }

    func connect(url: URL, token: String) async throws {
        receiveTask?.cancel()
        receiveTask = nil
        isConnected = false
        isInitialized = false
        failAllPending(with: CodexAppServerConnectionError.disconnected)
        do {
            try await transport.connect(url: url, token: token)
            // connect() 是 actor 的可重入点：候选切换可能在这里先执行 disconnect()。
            // 必须在恢复后检查原任务取消态，避免已关闭的 candidate 又继续 initialize。
            try Task.checkCancellation()
        } catch {
            await transport.close()
            throw error
        }
        isConnected = true
        isInitialized = false
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        let initializeParams = CodexAppServerJSONValue.objectValue([
            "clientInfo": .object([
                "name": .string("mimi_remote"),
                "title": .string("Mimi Remote"),
                "version": .string("0.1.0")
            ]),
            // app-server 要求客户端声明能力；这里保持最小能力集，避免移动端误触实验外的鉴权路径。
            "capabilities": .object([
                "experimentalApi": .bool(true),
                "requestAttestation": .bool(false),
                // gateway 会在转发给 Codex 前剥离该私有字段。它只用于让新版
                // agentd 确认客户端能处理 auto-handoff 产生的 notLoaded。
                "mimiThreadHandoff": .bool(true)
            ])
        ])
        do {
            _ = try await sendRequestEnvelope(
                CodexAppServerRequest(id: nextRequestID(), method: "initialize", params: initializeParams),
                allowBeforeInitialized: true
            )
            try await sendNotification(CodexAppServerNotification(method: "initialized", params: .object([:])))
            isInitialized = true
        } catch {
            receiveTask?.cancel()
            receiveTask = nil
            markDisconnected(with: error)
            await transport.close()
            throw error
        }
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        isConnected = false
        isInitialized = false
        await transport.close()
        failAllPending(with: CodexAppServerConnectionError.disconnected)
        finishInboundStreams()
    }

    func send(_ request: CodexAppServerRequestSpec, timeout: TimeInterval? = nil) async throws -> CodexAppServerJSONValue? {
        guard isConnected else {
            throw CodexAppServerConnectionError.disconnected
        }
        guard isInitialized else {
            throw CodexAppServerConnectionError.notInitialized
        }
        return try await sendRequestEnvelope(
            request.request(id: nextRequestID()),
            allowBeforeInitialized: false,
            timeout: timeout
        )
    }

    func sendNotification(_ notification: CodexAppServerNotification) async throws {
        guard isConnected else {
            throw CodexAppServerConnectionError.disconnected
        }
        let data = try encoder.encode(notification)
        do {
            try await transport.send(String(decoding: data, as: UTF8.self))
        } catch {
            let wrapped = CodexAppServerConnectionError.transport(error)
            markDisconnected(with: wrapped)
            throw wrapped
        }
    }

    func respond(to request: CodexAppServerServerRequest, result: CodexAppServerJSONValue? = .object([:])) async throws {
        try await sendResponse(CodexAppServerResponse(id: request.id, result: result, error: nil))
    }

    func respond(to request: CodexAppServerServerRequest, error: CodexAppServerError) async throws {
        try await sendResponse(CodexAppServerResponse(id: request.id, result: nil, error: error))
    }

    func ingestTextForTesting(_ text: String) {
        handleInboundText(text)
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                guard let text = try await transport.receive() else {
                    guard !Task.isCancelled else {
                        return
                    }
                    markDisconnected(with: CodexAppServerConnectionError.disconnected)
                    return
                }
                handleInboundText(text)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                markDisconnected(with: CodexAppServerConnectionError.transport(error))
                return
            }
        }
    }

    private func sendRequestEnvelope(
        _ request: CodexAppServerRequest,
        allowBeforeInitialized: Bool,
        timeout: TimeInterval? = nil
    ) async throws -> CodexAppServerJSONValue? {
        guard isConnected else {
            throw CodexAppServerConnectionError.disconnected
        }
        guard allowBeforeInitialized || isInitialized else {
            throw CodexAppServerConnectionError.notInitialized
        }
        guard pendingResponses[request.id] == nil else {
            throw CodexAppServerConnectionError.duplicateRequestID(request.id)
        }

        let timeoutNanoseconds = timeout.map { UInt64(max(0.1, $0) * 1_000_000_000) } ?? requestTimeoutNanoseconds
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [timeoutNanoseconds] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self.timeoutRequest(id: request.id)
            }
            pendingResponses[request.id] = PendingCodexAppServerResponse(
                method: request.method,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            Task {
                do {
                    try await self.sendEncodedRequest(request)
                } catch {
                    let wrapped = CodexAppServerConnectionError.transport(error)
                    self.failPendingRequest(id: request.id, error: wrapped)
                    self.markDisconnected(with: wrapped)
                }
            }
        }
    }

    private func sendEncodedRequest(_ request: CodexAppServerRequest) async throws {
        let data = try encoder.encode(request)
        try await transport.send(String(decoding: data, as: UTF8.self))
    }

    private func sendResponse(_ response: CodexAppServerResponse) async throws {
        guard isConnected else {
            throw CodexAppServerConnectionError.disconnected
        }
        let data = try encoder.encode(response)
        do {
            try await transport.send(String(decoding: data, as: UTF8.self))
        } catch {
            let wrapped = CodexAppServerConnectionError.transport(error)
            markDisconnected(with: wrapped)
            throw wrapped
        }
    }

    private func handleInboundText(_ text: String) {
        do {
            let message = try decoder.decode(CodexAppServerMessage.self, from: Data(text.utf8))
            switch message {
            case .response(let response):
                resolve(response)
            case .notification(let notification):
                notificationContinuation?.yield(notification)
            case .serverRequest(let request):
                serverRequestContinuation?.yield(request)
            }
        } catch {
            // 单个坏帧不能拖垮整条 JSON-RPC 连接；真正丢失的响应会由对应请求的超时兜底。
            return
        }
    }

    private func resolve(_ response: CodexAppServerResponse) {
        guard let pending = pendingResponses.removeValue(forKey: response.id) else {
            return
        }
        pending.timeoutTask.cancel()
        if let error = response.error {
            pending.continuation.resume(throwing: CodexAppServerConnectionError.appServer(error))
        } else {
            pending.continuation.resume(returning: response.result)
        }
    }

    private func timeoutRequest(id: CodexAppServerRequestID) {
        guard let pending = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pending.continuation.resume(throwing: CodexAppServerConnectionError.timeout(method: pending.method, id: id))
    }

    private func failPendingRequest(id: CodexAppServerRequestID, error: Error) {
        guard let pending = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let pending = pendingResponses
        pendingResponses.removeAll(keepingCapacity: false)
        for item in pending.values {
            item.timeoutTask.cancel()
            item.continuation.resume(throwing: error)
        }
    }

    private func markDisconnected(with error: Error) {
        isConnected = false
        isInitialized = false
        failAllPending(with: error)
        finishInboundStreams()
    }

    private func finishInboundStreams() {
        notificationContinuation?.finish()
        notificationContinuation = nil
        serverRequestContinuation?.finish()
        serverRequestContinuation = nil
    }

    private func nextRequestID() -> CodexAppServerRequestID {
        .int(CodexAppServerRequestIDAllocator.allocate())
    }
}
