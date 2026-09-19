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

/// H01 骨架：只提供显式 `notImplemented`，不返回空列表、空成功，也不调用旧网关兜底。
///
/// 真正的原生实现由后续任务补全。在补全之前，任何调用都必须显式失败，让上层能把
/// 该 runtime 标成不可用，而不是把「没实现」显示成「没有会话」。
final class HarnessSessionAPIClient: HarnessSessionClient {
    let endpoint: String
    let token: String

    init(endpoint: String, token: String) {
        self.endpoint = endpoint
        self.token = token
    }

    func makeEventClient(sessionID: SessionID) -> any SessionWebSocketClient {
        HarnessSessionWebSocketClient(endpoint: endpoint, token: token, sessionID: sessionID)
    }

    func channelAvailable() async throws -> Bool {
        throw HarnessNativeUnavailableError.notImplemented(operation: "channelAvailable")
    }

    func sessionsPage(
        projectID: String?,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        throw HarnessNativeUnavailableError.notImplemented(operation: "session/list")
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        throw HarnessNativeUnavailableError.notImplemented(operation: "session/list")
    }

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage {
        throw HarnessNativeUnavailableError.notImplemented(operation: "session/list")
    }

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        throw HarnessNativeUnavailableError.notImplemented(operation: "session/search")
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw HarnessNativeUnavailableError.notImplemented(operation: "session/read")
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        throw HarnessNativeUnavailableError.notImplemented(operation: "session/modelCatalog")
    }
}
