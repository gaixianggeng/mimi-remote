import Foundation

/// 原生 Harness 客户端接缝（H01）。
///
/// 只覆盖路由 facade 会委托给 Harness 的**受支持**操作。主机级 projects / worktree / git /
/// 文件 / 语音等服务继续走既有 agentd 客户端路径，不进这个协议——刻意保持窄，不造万能协议。
///
/// 开发期默认不注入（`AppServerRuntimeBundle.harness == nil`）：`deepseek` 仍走既有
/// app-server 桥接路径，Codex / Claude / DeepSeek 现状行为完全不变。注入后 `deepseek`
/// 由原生路径承担，`runtime(for:)` 不再回退到 Codex actor 假装 native。
/// 一次成功创建的结果。
///
/// `agentPreset` 是可选：只有 Harness 装配了 agent 名册时才返回（实测 0.1.5-rc.2 返回
/// `"standard"`）。客户端不得假设它存在。
struct HarnessCreatedSession: Equatable {
    let sessionID: String
    let agentPreset: String?
}

protocol HarnessSessionClient: AnyObject {
    /// 该 runtime 的事件客户端。事件包装器面向既有 `SessionWebSocketClient` 协议，
    /// 因此不再要求所有实现都是 `CodexAppServerSessionWebSocketClient`。
    func makeEventClient(sessionID: SessionID) -> any SessionWebSocketClient

    /// 原生通道是否可用。不可用时必须抛错或返回 false，**不得**用空成功冒充。
    func channelAvailable() async throws -> Bool

    func sessionsPage(
        projectID: String?,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse

    func modelOptions() async throws -> [CodexAppServerModelOption]

    // MARK: - H07 写路径
    //
    // 写方法与只读方法在**协议层**就分开列：读能力缺失时可以不实现，
    // 而写能力缺失必须是显式拒绝（见 HarnessNativeUnavailableError）。

    /// 创建会话。`cwd` 既是授权提示也是创建目标。
    func createSession(cwd: String, sessionID: String?) async throws -> HarnessCreatedSession

    /// 选择模型。provider/model 取值由模型目录决定。
    func selectModel(
        sessionID: String,
        provider: String,
        model: String,
        reasoningEffort: String?
    ) async throws

    /// 提交一次用户输入。`requestID` 是提交与 durable 记录的对账键，必须稳定。
    func submitPrompt(
        sessionID: String,
        requestID: String,
        text: String,
        mode: String,
        clientTimeZone: String?
    ) async throws

    /// 停止当前轮次（session 级，不是原子 turn 级条件取消）。
    func cancelSession(sessionID: String) async throws
}

/// 原生客户端工厂接缝。
///
/// 生产默认不提供（`nil`），等价于沿用既有 app-server 路径；测试与后续任务通过它注入
/// 原生实现或 fake。返回 `nil` 表示该 endpoint 不提供原生通道。
typealias HarnessSessionClientFactory = (_ endpoint: String, _ token: String) -> HarnessSessionClient?

/// 原生路径的显式失败。
///
/// 这些错误**不允许**被空列表、空成功或旧网关兜底掩盖：原生操作要么给出真实结果，
/// 要么显式失败，让上层把 runtime 标成 unavailable 并继续其他 runtime。
enum HarnessNativeUnavailableError: Error, LocalizedError, Equatable {
    /// 该 runtime 已由原生客户端承担，不能再用 Codex actor 假装 native。
    case routedNatively(runtimeProvider: String)
    /// 原生客户端尚未实现该操作（H01 骨架阶段的主要返回）。
    case notImplemented(operation: String)
    /// Harness 不支持该操作，必须显式拒绝而不是降级成普通请求。
    case unsupported(operation: String)

    var errorDescription: String? {
        switch self {
        case .routedNatively(let runtimeProvider):
            return L10n.format("harness.native_routed_no_fallback", runtimeProvider)
        case .notImplemented(let operation):
            return L10n.format("harness.native_not_implemented", operation)
        case .unsupported(let operation):
            return L10n.format("harness.native_unsupported", operation)
        }
    }
}

/// 原生 Harness 只读客户端（H02 传输 + H05 目录）。
///
/// 只做**只读**的 Connection RPC：`session/list`、`session/search`、`session/modelCatalog`。
/// 写路径（create / prompt / cancel / selectModel）与历史读取（`session/page`）属于后续任务，
/// 在这里一律显式 `notImplemented`，不返回空成功。
///
/// 授权提示 `cwd` 走请求体（与 `internal/httpapi/harness_native_policy.go` 的
/// `harnessNativeCWDScopedMethods` 一致）：只有 `session/list` 与 `session/search` 接受它，
/// 它**不进**上游 Harness 的 args。
final class HarnessSessionAPIClient: HarnessSessionClient {
    /// 原生通道承接的 runtime id。沿用既有 runtime 身份，不新建 `deepseek-native`。
    static let runtimeProvider = "deepseek"

    let endpoint: String
    let token: String
    private let rpc: HarnessRPCTransport
    /// 提交编排缓存。每建一个事件客户端都新建控制器会让"上一次提交尚未确认"
    /// 这条判断失效——状态机必须跨事件客户端存活。
    private var cachedSubmissionController: HarnessSubmissionController?

    /// 普通输入的提交模式。实测取值域只有 queue|steer，普通发送用 queue。
    static let defaultPromptMode = "queue"

    init(endpoint: String, token: String, rpc: HarnessRPCTransport? = nil) {
        self.endpoint = endpoint
        self.token = token
        if let rpc {
            self.rpc = rpc
        } else if let baseURL = URL(string: endpoint) {
            self.rpc = URLSessionHarnessRPCTransport(baseURL: baseURL, token: token)
        } else {
            // 地址不可解析时保留一个必然失败的传输，让失败发生在调用点而不是 init 抛错，
            // 调用方因此总能拿到一个显式错误而不是构造期的崩溃路径。
            self.rpc = UnreachableHarnessRPCTransport(endpoint: endpoint)
        }
    }

    /// 事件客户端。写路径复用本客户端持有的提交编排，不另建一条网络路径。
    ///
    /// `fetchSnapshot` 暂不注入：opening snapshot 必须经由中继的 `session/follow`
    /// 流载体获取（实测直接 POST /api/session/follow 会被判 signature-invalid）。
    /// 流生命周期与恢复编排属于 H10，届时在此接上，现在保持 nil——
    /// 让"基线未建立"成为显式失败，而不是假装连上。
    @MainActor
    func makeEventClient(sessionID: SessionID) -> any SessionWebSocketClient {
        HarnessSessionWebSocketClient(
            endpoint: endpoint,
            token: token,
            sessionID: sessionID,
            submission: submissionController()
        )
    }

    /// 提交编排。同一个 client 实例复用同一个控制器：写路径的状态机不该每建一个
    /// 事件客户端就重置一次，否则"上一次提交尚未确认"这条判断会失效。
    @MainActor
    private func submissionController() -> HarnessSubmissionController {
        if let existing = cachedSubmissionController { return existing }
        let created = HarnessSubmissionController(
            sendPrompt: { [weak self] sessionID, requestID, text in
                guard let self else { throw HarnessTransportError.notConnected }
                try await self.submitPrompt(
                    sessionID: sessionID, requestID: requestID, text: text,
                    mode: Self.defaultPromptMode, clientTimeZone: TimeZone.current.identifier
                )
            },
            sendCancel: { [weak self] sessionID in
                guard let self else { throw HarnessTransportError.notConnected }
                try await self.cancelSession(sessionID: sessionID)
            }
        )
        cachedSubmissionController = created
        return created
    }

    /// 通道可用性探测。
    ///
    /// 用 `session/modelCatalog` 而不是 `session/list`：它零参数、只读、不触发任何模型调用，
    /// 却同样要走完整条鉴权与上游链路，因此足以区分"通道通了"和"通道没通"。
    /// 失败必须抛错——返回 false 会与"探测本身没跑"混成同一件事。
    func channelAvailable() async throws -> Bool {
        _ = try await rpc.call(HarnessRPCRequest(
            rpcId: Self.makeRPCID(),
            method: HarnessWireMethod.sessionModelCatalog,
            args: .object([:]),
            cwd: nil
        ))
        return true
    }

    /// Harness 没有 Codex 的 project 维度；非空 projectID 不能被静默丢弃。
    func sessionsPage(
        projectID: String?,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        guard projectID?.trimmedNonEmpty == nil else {
            throw HarnessNativeUnavailableError.unsupported(operation: "session/list(projectID)")
        }
        return try await listSessions(cwd: nil, workspace: nil)
    }

    /// 工作区目录查询：带 cwd 提示，由 agentd 用既有 canonical scope 逻辑裁剪。
    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        try await listSessions(cwd: workspace.path, workspace: workspace)
    }

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await listSessions(cwd: nil, workspace: nil)
    }

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 中继会拒空 query；本地先拒能给出可操作文案，也避免把空查询当成"零命中"。
            throw HarnessTransportError.rejected(status: 400, message: "Search query must not be empty")
        }
        let value = try await rpc.call(HarnessRPCRequest(
            rpcId: Self.makeRPCID(),
            method: HarnessWireMethod.sessionSearch,
            args: .object(["request": .object(["query": .string(trimmed)])]),
            cwd: nil
        ))
        return try HarnessSessionDirectoryDecoding.searchPage(
            from: value,
            runtimeProvider: Self.runtimeProvider,
            workspace: nil
        )
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        let value = try await rpc.call(HarnessRPCRequest(
            rpcId: Self.makeRPCID(),
            method: HarnessWireMethod.sessionModelCatalog,
            // 该方法描述符没有参数：必须传空对象，省略或带键都会被中继拒。
            args: .object([:]),
            cwd: nil
        ))
        return try HarnessSessionDirectoryDecoding.modelOptions(
            from: value,
            runtimeProvider: Self.runtimeProvider
        )
    }

    /// 历史读取属于后续任务（`session/page` 需要本次 follow 的 snapshot.cursor，
    /// 现在没有合法的 throughSeq 可传）。显式失败，不用空会话冒充。
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw HarnessNativeUnavailableError.notImplemented(operation: "session/page")
    }

    // MARK: - H07 写路径

    /// 创建会话。`cwd` 同时作为授权提示与创建目标——中继会校验后者落在前者授权的范围内。
    ///
    /// `sessionId` 可选：给出它是为了把本地乐观记录与服务端身份稳定关联。
    /// `agentPreset` 刻意不传：默认值由 Harness 决定（契约 D4）。
    func createSession(cwd: String, sessionID: String?) async throws -> HarnessCreatedSession {
        var request: [String: HarnessJSONValue] = ["cwd": .string(cwd)]
        if let sessionID = sessionID?.trimmedNonEmpty {
            request["sessionId"] = .string(sessionID)
        }
        let value = try await rpc.call(HarnessRPCRequest(
            rpcId: Self.makeRPCID(),
            method: HarnessWireMethod.sessionCreate,
            args: .object(["request": .object(request)]),
            cwd: cwd
        ))
        guard let created = value["sessionId"]?.stringValue?.trimmedNonEmpty else {
            // 建成功了却拿不到身份，后续没有任何操作能指向它。显式失败而不是返回空 id。
            throw HarnessTransportError.malformedResponse("session/create result is missing sessionId")
        }
        return HarnessCreatedSession(
            sessionID: created,
            agentPreset: value["agentPreset"]?.stringValue
        )
    }

    /// 选择模型。provider/model 取值由模型目录决定，这里不按名字推断。
    func selectModel(
        sessionID: String,
        provider: String,
        model: String,
        reasoningEffort: String?
    ) async throws {
        var request: [String: HarnessJSONValue] = [
            "sessionId": .string(sessionID),
            "provider": .string(provider),
            "model": .string(model),
        ]
        // 可选档位：只在确实给了非空值时才带上，避免把"没选档位"变成一个显式空档位。
        if let effort = reasoningEffort?.trimmedNonEmpty {
            request["reasoningEffort"] = .string(effort)
        }
        _ = try await rpc.call(HarnessRPCRequest(
            rpcId: Self.makeRPCID(),
            method: HarnessWireMethod.sessionSelectModel,
            args: .object(["request": .object(request)]),
            cwd: nil
        ))
    }

    /// 提交一次用户输入。
    ///
    /// `requestId` 由调用方生成并**保持不变**：它是这次提交与 durable
    /// `user/message.source.rpcId` 的对账键（契约 D4）。响应未知时不得换一个 id 重发——
    /// 那会让一次提交变成两次。
    func submitPrompt(
        sessionID: String,
        requestID: String,
        text: String,
        mode: String,
        clientTimeZone: String?
    ) async throws {
        var request: [String: HarnessJSONValue] = [
            "requestId": .string(requestID),
            "sessionId": .string(sessionID),
            "mode": .string(mode),
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(text),
            ])]),
        ]
        if let zone = clientTimeZone?.trimmedNonEmpty {
            request["clientTimeZone"] = .string(zone)
        }
        _ = try await rpc.call(HarnessRPCRequest(
            rpcId: Self.makeRPCID(),
            method: HarnessWireMethod.sessionPrompt,
            args: .object(["request": .object(request)]),
            cwd: nil
        ))
    }

    /// 停止当前轮次。
    ///
    /// 已读版本只有 session 级 cancel——它停的是这个会话正在跑的轮次，不是"某个指定轮次"。
    /// 契约要求如实记录这一点，不宣传成原子 turn 级条件取消。
    func cancelSession(sessionID: String) async throws {
        _ = try await rpc.call(HarnessRPCRequest(
            rpcId: Self.makeRPCID(),
            method: HarnessWireMethod.sessionCancel,
            args: .object(["request": .object(["sessionId": .string(sessionID)])]),
            cwd: nil
        ))
    }

    // MARK: 支撑

    private func listSessions(cwd: String?, workspace: AgentWorkspace?) async throws -> SessionsPage {
        let value = try await rpc.call(HarnessRPCRequest(
            rpcId: Self.makeRPCID(),
            method: HarnessWireMethod.sessionList,
            // 形参名带下划线；写成 "request" 会被 Harness 网关判为 gateway/arguments-invalid。
            // 上游 list 没有服务端分页，因此不传 cursor。
            args: .object(["_request": .object([:])]),
            cwd: cwd
        ))
        return try HarnessSessionDirectoryDecoding.sessionsPage(
            from: value,
            runtimeProvider: Self.runtimeProvider,
            workspace: workspace
        )
    }

    private static func makeRPCID() -> String {
        "mimi-\(UUID().uuidString)"
    }
}

/// endpoint 无法解析成 URL 时的占位传输：调用必然显式失败。
private final class UnreachableHarnessRPCTransport: HarnessRPCTransport {
    private let endpoint: String

    init(endpoint: String) {
        self.endpoint = endpoint
    }

    func call(_ request: HarnessRPCRequest) async throws -> HarnessJSONValue {
        throw HarnessTransportError.malformedResponse("Invalid native Harness endpoint: \(endpoint)")
    }
}
