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

    /// 引导在 RPC 前降级为 turn/start（#639）：这条消息不会进入原先绑定的旧 turn。
    /// 解除旧 turn 与引导标记，让新回合的 ACK 和 userMessage 回显按普通发送对账；
    /// 否则 client ID 相同但 turn 不同，回显会被当成另一条消息追加。
    @discardableResult
    func releaseGuidanceForTurnStart(clientMessageID: ClientMessageID, sessionID: String) -> Bool {
        guard var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)],
              let index = list.lastIndex(where: {
                  $0.role == .user
                      && $0.clientMessageID == clientMessageID
                      && $0.userDelivery == .guided
                      && $0.sendStatus != .confirmed
              })
        else { return false }
        list[index].turnID = nil
        list[index].turnLifecycle = nil
        list[index].userDelivery = nil
        list[index].updatedAt = Date()
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
        return true
    }
}
