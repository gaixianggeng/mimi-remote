import Foundation

/// 受控重启可能需要等待 Codex daemon 排空运行中的任务。阶段状态只用于解释
/// 当前等待原因，不改变 HostStore 的单事务顺序或任何进程停止策略。
enum CodexDesktopTransitionPhase: Equatable, Sendable {
    case preparingRestart
    case closingDesktop
    case preparingSharedService
    case waitingForRunningTasks
    case startingIndependentService

    var title: String {
        switch self {
        case .preparingRestart:
            "正在准备重启"
        case .closingDesktop:
            "正在退出 Codex Desktop"
        case .preparingSharedService:
            "正在准备共享服务"
        case .waitingForRunningTasks:
            "正在结束运行中的任务"
        case .startingIndependentService:
            "正在启动独立服务"
        }
    }

    var detail: String {
        switch self {
        case .preparingRestart:
            "正在检查 Codex Desktop 和服务状态。"
        case .closingDesktop:
            "正在等待 Codex Desktop 正常退出。"
        case .preparingSharedService:
            "正在迁移并验证 Codex 共享服务。"
        case .waitingForRunningTasks:
            "正在等待运行中的 Codex 任务安全结束。任务较长时，此步骤会相应延长。"
        case .startingIndependentService:
            "共享服务已停止。正在重新加载并确认 Mimi 独立服务。"
        }
    }
}
