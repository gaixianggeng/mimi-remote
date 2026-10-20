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

    /// 仍在窗口内的失败会话里最早到期的时刻；页面一直开着时据此安排一次刷新，
    /// 让它准时从「待你处理」回到「最近」，而不必每分钟重算整份列表。
    static func nextExpiry(in sessions: [AgentSession], now: Date = Date()) -> Date? {
        sessions.compactMap { session -> Date? in
            guard session.activityState == .failed else { return nil }
            let expiry = SessionIndexStore.orderingDate(for: session).addingTimeInterval(failedAttentionWindow)
            return expiry > now ? expiry : nil
        }
        .min()
    }
}
