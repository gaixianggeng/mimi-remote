import Foundation

enum ConversationMessageDeliveryReconciler {
    static func hasTerminalTurnAfterLatestUser(
        _ messages: [ConversationMessage],
        turnLifecycles: [TurnID: ConversationTurnLifecycle]
    ) -> Bool {
        guard let latestUser = messages.last(where: { $0.role == .user && $0.kind == .message }) else {
            return false
        }

        // 历史 rebase 可能暂时同时保留本地 user 与权威 user。权威副本已取得 turnID 时，
        // 用相同 clientMessageID 补齐本地副本的范围，不能退回依赖数组相对顺序。
        let resolvedTurnID = latestUser.turnID.flatMap { $0.isEmpty ? nil : $0 }
            ?? latestUser.clientMessageID.flatMap { clientMessageID in
                messages.last(where: {
                    $0.role == .user
                        && $0.clientMessageID == clientMessageID
                        && $0.turnID?.isEmpty == false
                })?.turnID
            }
        if let resolvedTurnID {
            if latestUser.turnLifecycle?.isTerminal == true
                || turnLifecycles[resolvedTurnID]?.isTerminal == true {
                return true
            }
            return messages.contains {
                $0.turnID == resolvedTurnID && $0.turnLifecycle?.isTerminal == true
            }
        }

        var sawTerminalAssistant = false
        for message in messages.reversed() where message.kind == .message {
            if message.role == .assistant {
                sawTerminalAssistant = sawTerminalAssistant || message.turnLifecycle?.isTerminal == true
            } else if message.role == .user {
                return message.turnLifecycle?.isTerminal == true || sawTerminalAssistant
            }
        }
        return false
    }

    static func markSendingUncertain(
        _ messages: [ConversationMessage],
        now: Date = Date()
    ) -> [ConversationMessage]? {
        var updated = messages
        var changed = false
        for index in updated.indices where updated[index].role == .user
            && updated[index].sendStatus == .sending
            && updated[index].userDelivery != .queued {
            updated[index].sendStatus = .uncertain
            updated[index].updatedAt = now
            changed = true
        }
        return changed ? updated : nil
    }

    static func reconcileGuided(
        _ messages: [ConversationMessage],
        authoritativeHistory: [CodexHistoryMessage],
        historyIsComplete: Bool,
        turnLifecycles: [TurnID: ConversationTurnLifecycle],
        now: Date = Date()
    ) -> [ConversationMessage]? {
        let confirmedPairs = Set(authoritativeHistory.compactMap { message -> String? in
            guard message.role == "user",
                  let clientMessageID = message.clientMessageID,
                  let turnID = message.turnID,
                  !turnID.isEmpty else { return nil }
            return pairKey(clientMessageID: clientMessageID, turnID: turnID)
        })
        var updated = messages
        var changed = false
        for index in updated.indices where updated[index].role == .user
            && updated[index].userDelivery == .guided
            && updated[index].sendStatus == .uncertain {
            guard let clientMessageID = updated[index].clientMessageID,
                  let turnID = updated[index].turnID,
                  !turnID.isEmpty else { continue }
            if confirmedPairs.contains(pairKey(clientMessageID: clientMessageID, turnID: turnID)) {
                updated[index].sendStatus = .confirmed
                updated[index].updatedAt = now
                changed = true
            } else if historyIsComplete, turnLifecycles[turnID]?.isTerminal == true {
                updated[index].sendStatus = .failed
                updated[index].updatedAt = now
                changed = true
            }
        }
        return changed ? updated : nil
    }

    private static func pairKey(clientMessageID: ClientMessageID, turnID: TurnID) -> String {
        "\(clientMessageID)\u{1f}\(turnID)"
    }
}
