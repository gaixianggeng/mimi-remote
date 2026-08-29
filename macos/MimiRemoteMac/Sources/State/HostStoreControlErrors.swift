import Foundation

enum ServiceLifecycleError: LocalizedError {
    case invalidConfiguration(String)
    case unregisterTimedOut
    case stopTimedOut
    case requiresApproval
    case agentRegistrationFailed(String)
    case automaticRepairFailed(initial: String, recovery: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            detail
        case .unregisterTimedOut:
            "服务停止超时，未继续启动；请稍后重试。"
        case .stopTimedOut:
            "旧服务仍占用当前 Endpoint，未继续启动新版本；请稍后重试。"
        case .requiresApproval:
            "请先在系统设置的登录项中允许 Mimi Remote Mac。"
        case .agentRegistrationFailed(let detail):
            "系统没有找到原服务记录，自动重新登记失败：\(detail)。请运行诊断并重试。"
        case .automaticRepairFailed(let initial, let recovery):
            "服务首次启动失败（\(initial)），自动重新登记仍未恢复（\(recovery)）。请运行诊断。"
        }
    }
}

enum ClaudeRuntimeControlError: LocalizedError {
    case signedOut
    case unavailable
    case disabled
    case timedOut(enabled: Bool)

    var errorDescription: String? {
        switch self {
        case .signedOut:
            "Claude Code 尚未登录。"
        case .unavailable:
            "Claude Runtime 未能连接。"
        case .disabled:
            "服务重载后 Claude 仍处于关闭状态。"
        case .timedOut(let enabled):
            enabled ? "等待 Claude Runtime 连接超时。" : "等待 Claude Runtime 停止超时。"
        }
    }
}
