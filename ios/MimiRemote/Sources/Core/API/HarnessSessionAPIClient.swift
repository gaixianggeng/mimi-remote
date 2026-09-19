import Foundation

/// 原生 Harness 客户端接缝（H01）。
///
/// 只覆盖路由 facade 会委托给 Harness 的**受支持**操作。主机级 projects / worktree / git /
/// 文件 / 语音等服务继续走既有 agentd 客户端路径，不进这个协议——刻意保持窄，不造万能协议。
///
/// 开发期默认不注入（`AppServerRuntimeBundle.harness == nil`）：`deepseek` 仍走既有
/// app-server 桥接路径，Codex / Claude / DeepSeek 现状行为完全不变。注入后 `deepseek`
/// 由原生路径承担，`runtime(for:)` 不再回退到 Codex actor 假装 native。
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
            return "\(runtimeProvider) 由 Harness 原生客户端承担，不能回退到 Codex 通道。"
        case .notImplemented(let operation):
            return "Harness 原生客户端尚未实现 \(operation)。"
        case .unsupported(let operation):
            return "Harness 不支持 \(operation)。"
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

    func makeEventClient(sessionID: SessionID) -> any SessionWebSocketClient {
        HarnessSessionWebSocketClient(endpoint: endpoint, token: token, sessionID: sessionID)
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

    /// 按 projectID 查询。Harness 没有 Codex 的 project 维度，等价于不带 cwd 的全局查询。
    func sessionsPage(
        projectID: String?,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        try await listSessions(cwd: nil, workspace: nil)
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
            throw HarnessTransportError.rejected(status: 400, message: "搜索关键词不能为空")
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
        throw HarnessTransportError.malformedResponse("原生通道地址不可解析：\(endpoint)")
    }
}
