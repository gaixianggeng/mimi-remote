import Foundation

/// 会话「现在在做什么、由谁在做」的唯一分类（#683）。
///
/// 列表行字形、侧栏分区、工作区分组和状态文字此前各自从 `status` 字符串、`activeTurnID`、
/// `pendingApproval` 推导，同一会话在三个表面能读出三种状态。这里把判定收成一处：先看要不要
/// 人介入，再看在不在跑、谁在跑，最后才是空闲。「未读」「刚完成」「置顶」不是活动状态，
/// 它们是空闲态上的附加标记，由 Store 的已读水位与本地观察时间维护，列表只在空闲行上画它们。
enum SessionActivityState: Equatable, Hashable {
    enum Attention: Equatable, Hashable {
        case approval
        case userInput
    }

    /// 谁在驱动这一轮。
    enum Driver: Equatable, Hashable {
        /// Mimi 的运行时（本机或另一台 Mimi 设备发起）。`hasActiveTurn` 表示本端已拿到进行中的 turn。
        case mimi(hasActiveTurn: Bool)
        /// 电脑上的 Claude Code / Claude 桌面端正在处理；Mimi 只能旁观，等它空闲后才能接管。
        case computer(ClaudeSessionOwner)
    }

    /// 本地草稿：还没发出第一条消息。
    case draft
    /// 等待用户审批或补充输入；无论谁在跑都排在最前。
    case needsYou(Attention)
    /// 这一轮还在进行。
    case running(Driver)
    /// 上一轮以失败结束。
    case failed
    /// 没有在跑：历史、完成、已结束、空闲在这里是同一类，细分只影响文案。
    case idle

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var needsYou: Bool {
        if case .needsYou = self { return true }
        return false
    }

    var isRunningOnComputer: Bool {
        if case .running(.computer) = self { return true }
        return false
    }

    /// 需要人立刻回来看的状态：等待处理与失败。工作区把它们归入同一组。
    var needsAttention: Bool {
        switch self {
        case .needsYou, .failed:
            return true
        case .draft, .running, .idle:
            return false
        }
    }
}

extension AgentSession {
    /// 顺序即优先级：草稿 → 待处理 → 电脑端在跑 → 本端进行中的 turn → 运行态 → 失败 → 空闲。
    /// 电脑端持有方正在执行时不可能同时有本端的 activeTurnID，但仍放在前面：它决定了状态文字说"在哪跑"。
    var activityState: SessionActivityState {
        if isLocalDraft {
            return .draft
        }
        if status == SessionStatus.waitingForApproval.rawValue || pendingApproval != nil {
            return .needsYou(.approval)
        }
        if status == SessionStatus.waitingForInput.rawValue || pendingUserInput != nil {
            return .needsYou(.userInput)
        }
        if isRunningOnComputer, let owner = claudeOwner {
            return .running(.computer(owner))
        }
        if activeTurnID != nil {
            return .running(.mimi(hasActiveTurn: true))
        }
        if status == SessionStatus.running.rawValue {
            return .running(.mimi(hasActiveTurn: false))
        }
        if status == SessionStatus.failed.rawValue {
            return .failed
        }
        return .idle
    }
}
