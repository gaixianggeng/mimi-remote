import Foundation

enum ServiceLifecycleError: LocalizedError {
    case invalidConfiguration(String)
    case unregisterTimedOut
    case stopTimedOut
    case requiresApproval
    case agentRegistrationFailed(String)
    case agentSpawnFailed(String)
    case configRequiresNewerVersion(String)
    case automaticRepairFailed(initial: String, recovery: String)

    /// 配置在当前安装包下不可用。这类失败换多少次登记都不会变，必须跳过换代，
    /// 否则只会把真实原因埋进「自动重新登记仍未恢复」里。
    var isConfigurationFailure: Bool {
        switch self {
        case .invalidConfiguration, .configRequiresNewerVersion: true
        default: false
        }
    }

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
        case .agentSpawnFailed(let detail):
            "macOS 无法启动后台服务（\(detail)）。如果刚刚覆盖安装过安装包，请升级到最新发布包后重试。"
        case .configRequiresNewerVersion(let detail):
            "当前安装包过旧，无法使用这份配置：\(detail)。请升级到最新发布包后重试。"
        case .automaticRepairFailed(let initial, let recovery):
            // 首次失败与换代后的失败常常是同一句，重复播报只会让用户以为有两处故障。
            initial == recovery
                ? "服务启动失败（\(initial)），自动重新登记后仍未恢复。请运行诊断。"
                : "服务启动失败（\(initial)），自动重新登记仍未恢复（\(recovery)）。请运行诊断。"
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
