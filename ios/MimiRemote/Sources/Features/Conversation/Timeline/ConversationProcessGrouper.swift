import Foundation

enum ConversationProcessElement: Equatable {
    case activity(ConversationMessage)
    case group(ConversationProcessGroup)
}

struct ConversationProcessGrouper {
    static func elements(
        from messages: [ConversationMessage],
        turnLifecycle: ConversationTurnLifecycle,
        keepsRunningWhileTurnIsActive: Bool
    ) -> [ConversationProcessElement] {
        var result: [ConversationProcessElement] = []
        var groupAnchor: ConversationMessage?
        var latestHeader: ConversationMessage?
        var pendingActivities: [ConversationMessage] = []

        func flushPendingGroup() {
            defer {
                groupAnchor = nil
                latestHeader = nil
                pendingActivities.removeAll(keepingCapacity: true)
            }

            guard !pendingActivities.isEmpty else {
                // reasoning 是内部阶段标题；没有真实活动时不占据主时间线。
                return
            }
            guard let header = latestHeader,
                  let anchor = groupAnchor,
                  let turnID = header.turnID else {
                result.append(contentsOf: pendingActivities.map(ConversationProcessElement.activity))
                return
            }
            result.append(.group(ConversationProcessGroup(
                // 标题会随最新 reasoning 更新，但 identity 锚定本批次首个 item，避免展开状态跳变。
                id: "process:\(anchor.id.uuidString)",
                turnID: turnID,
                header: header,
                activities: pendingActivities,
                // 子命令失败不代表整个 turn 失败；恢复中的失败只作为组内弱提示。
                status: .resolve(
                    turnLifecycle: turnLifecycle,
                    activities: pendingActivities,
                    keepsRunningWhileTurnIsActive: keepsRunningWhileTurnIsActive
                )
            )))
        }

        for message in messages {
            if let anchor = groupAnchor, anchor.turnID != message.turnID {
                flushPendingGroup()
            }
            if isProcessHeader(message) {
                groupAnchor = groupAnchor ?? message
                latestHeader = message
                continue
            }

            if isGroupableChild(message) {
                groupAnchor = groupAnchor ?? message
                pendingActivities.append(message)
                continue
            }

            flushPendingGroup()
            result.append(.activity(message))
        }
        flushPendingGroup()
        return result
    }

    private static func isProcessHeader(_ message: ConversationMessage) -> Bool {
        message.role == .system && message.activityPayload?.category == .thinking
    }

    private static func isGroupableChild(_ message: ConversationMessage) -> Bool {
        if message.kind == .approval || message.kind == .userInput {
            return isResolvedInteraction(message)
        }
        switch message.activityPayload?.category {
        case .runCommand, .editFile, .toolCall:
            return true
        case .thinking, .plan, .error, .none:
            return false
        }
    }

    private static func isResolvedInteraction(_ message: ConversationMessage) -> Bool {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch message.kind {
        case .approval:
            return content.hasPrefix(L10n.text("ui.approval_approved")) || content.hasPrefix(L10n.text("ui.approved")) ||
                content.hasPrefix(L10n.text("ui.approval_rejected")) || content.hasPrefix(L10n.text("ui.rejected"))
        case .userInput:
            return content.hasPrefix(L10n.text("ui.additional_information_has_been_submitted")) || content.hasPrefix(L10n.text("ui.boot_input_submitted")) ||
                content.hasPrefix(L10n.text("ui.additional_information_skipped")) || content.hasPrefix(L10n.text("ui.boot_input_skipped"))
        case .message, .commentary, .plan, .reasoningSummary, .commandSummary, .fileChangeSummary, .warning, .error:
            return false
        }
    }
}
