import Foundation

/// 发送结果对账：把"结果未知"的用户消息与权威历史核对，避免误报失败诱导重复执行。
/// 与 ConversationStore 主体拆开，保持单文件在 scripts/check-source-size.sh 的上限内。
extension ConversationStore {
    func markSendingUserMessagesUncertain(sessionID: String) {
        guard let current = messagesByScopedSessionID[scopedSessionID(for: sessionID)],
              let updated = ConversationMessageDeliveryReconciler.markSendingUncertain(current)
        else { return }
        replaceMessagesWithoutEquivalenceCheck(updated, sessionID: sessionID, rebuildIndexes: false)
    }

    func reconcileUncertainGuidedMessages(
        sessionID: String,
        authoritativeHistory: [CodexHistoryMessage],
        historyIsComplete: Bool
    ) {
        let scoped = scopedSessionID(for: sessionID)
        guard let current = messagesByScopedSessionID[scoped],
              let updated = ConversationMessageDeliveryReconciler.reconcileGuided(
                  current,
                  authoritativeHistory: authoritativeHistory,
                  historyIsComplete: historyIsComplete,
                  turnLifecycles: turnLifecycleBySessionID[scoped] ?? [:]
              )
        else { return }
        replaceMessagesWithoutEquivalenceCheck(updated, sessionID: sessionID, rebuildIndexes: false)
    }
}
