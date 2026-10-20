import Foundation

/// 「待你处理」的唯一判定（#546）：侧栏、会话页和工作区页都从这里取成员，
/// 避免同一个标题下数量和内容对不上。
///
/// - 等待审批、等待输入、电脑端等待确认：始终算「待你处理」。
/// - 失败：算「待你处理」，但只保留 12 小时（与工作区页的 12 小时分界一致），
///   之后回到「最近」，避免很久以前的失败长期占住值班表。
enum SessionAttentionPolicy {
    static let failedAttentionWindow: TimeInterval = WorkspaceSessionAgeBoundary.staleInterval

    static func needsAttention(_ session: AgentSession, now: Date = Date()) -> Bool {
        let state = session.activityState
        if state.needsYou {
            return true
        }
        guard state == .failed else {
            return false
        }
        let age = now.timeIntervalSince(SessionIndexStore.orderingDate(for: session))
        return age <= failedAttentionWindow
    }
}
