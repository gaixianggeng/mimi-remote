import Foundation

/// 会话上下文剩余比例：记录、展示条件与低余量提示的关闭状态。
extension SessionStore {
    func recordContextWindowUsage(_ sample: AppServerTokenUsageSample, sessionID: SessionID) {
        guard let usage = ContextWindowUsage(sample: sample) else {
            return
        }
        if contextWindowUsageBySessionID[sessionID] != usage {
            contextWindowUsageBySessionID[sessionID] = usage
        }
        // 回到阈值以上（通常是压缩之后）重新启用提示，下次跌破时还会出现一次。
        if !usage.isLow, dismissedContextWindowNoticeSessionIDs.contains(sessionID) {
            dismissedContextWindowNoticeSessionIDs.remove(sessionID)
        }
    }

    /// 只对 Codex 会话展示。Claude 适配器上报的 `last` 是整回合的聚合用量，
    /// 一回合里多次调用工具时会被放大，不能当作当前上下文占用。
    func contextWindowUsage(for session: AgentSession) -> ContextWindowUsage? {
        guard !session.isLocalDraft,
              Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == "codex" else {
            return nil
        }
        return contextWindowUsageBySessionID[session.id]
    }

    var selectedContextWindowUsage: ContextWindowUsage? {
        guard let session = selectedSession else {
            return nil
        }
        return contextWindowUsage(for: session)
    }

    var showsSelectedContextWindowNotice: Bool {
        guard let session = selectedSession,
              let usage = contextWindowUsage(for: session) else {
            return false
        }
        return usage.isLow && !dismissedContextWindowNoticeSessionIDs.contains(session.id)
    }

    func dismissContextWindowNotice(sessionID: SessionID) {
        dismissedContextWindowNoticeSessionIDs.insert(sessionID)
    }

    /// 从上下文圆环或低余量提示发起压缩。压缩已开始就收起提示，
    /// 等下一次用量事件回到阈值以上再重新启用。
    func compactContextFromContextWindowControl(_ session: AgentSession) async {
        if await compactSessionContext(session) {
            dismissContextWindowNotice(sessionID: session.id)
        }
    }
}
