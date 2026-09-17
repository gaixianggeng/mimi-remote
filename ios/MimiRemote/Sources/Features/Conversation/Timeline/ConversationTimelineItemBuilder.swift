import Foundation

struct ConversationTimelineItemBuilder {
    static func items(
        from messages: [ConversationMessage],
        provider: ConversationTimelineProvider = .codex,
        showsDetailedTranscript: Bool = false,
        expandedProcessMessageIDs: Set<UUID> = [],
        collapsedProcessMessageIDs: Set<UUID> = [],
        activeTurn: ConversationTimelineActiveTurn? = nil
    ) -> [ConversationTimelineItem] {
        let lifecycles = effectiveTurnLifecycles(in: messages)
        let latestUserIndex = messages.lastIndex { $0.role == .user } ?? messages.startIndex
        let completedTurnIDs = Set(messages.filter { $0.turnLifecycle == .completed }.compactMap(\.turnID))
        var result: [ConversationTimelineItem] = []
        var pendingFileIDs: [UUID] = []
        var pendingFileTurnID: TurnID?
        var index = messages.startIndex

        func flushFileChanges() {
            guard !pendingFileIDs.isEmpty else { return }
            result.append(.fileChanges(ConversationFileChanges(messageIDs: pendingFileIDs)))
            pendingFileIDs.removeAll()
        }

        while index < messages.endIndex {
            let message = messages[index]
            // 缺失 turnID 也不能把文件入口接到下一段已知轮次之后。
            if message.role == .user || message.turnID != pendingFileTurnID {
                flushFileChanges()
            }
            guard isProcessMessage(message) else {
                result.append(.message(message))
                if message.role == .assistant, message.kind == .message, !pendingFileIDs.isEmpty {
                    flushFileChanges()
                }
                index += 1
                continue
            }

            let processStartIndex = index
            var children: [ConversationMessage] = []
            while index < messages.endIndex, isProcessMessage(messages[index]),
                  messages[index].turnID == message.turnID {
                children.append(messages[index])
                index += 1
            }
            let lifecycle = message.turnID.flatMap { lifecycles[$0] }
                ?? fallbackTurnLifecycle(for: children, nextIndex: index, messages: messages)
            // 用原始消息记录手动展开意图：历史前插改变首项和派生组 ID 时，原有展开仍有效。
            // 自动展开只属于当前轮，不写入手动意图；收到完成状态后自然恢复折叠。
            // final 文本可能先于 turn 完成到达，不能仅因答复已确认而提前收起。
            let automaticallyExpanded = activeTurn.map { turn in
                processStartIndex >= latestUserIndex
                    && (turn.id == nil || message.turnID == turn.id)
                    && !completedTurnIDs.contains(message.turnID ?? "")
                    && !children.contains { $0.turnLifecycle == .completed }
                    && lifecycle != .failed && lifecycle != .interrupted
            } ?? false
            let expanded = showsDetailedTranscript
                || children.contains { expandedProcessMessageIDs.contains($0.id) }
                || (automaticallyExpanded && !children.contains { collapsedProcessMessageIDs.contains($0.id) })
            let group = ConversationProcessGroup(messages: children, lifecycle: lifecycle, isExpanded: expanded)
            result.append(.processGroup(group))
            if expanded {
                result.append(contentsOf: children.map { isActivityMessage($0) ? .activity($0) : .processMessage($0) })
            }
            pendingFileTurnID = message.turnID
            pendingFileIDs.append(contentsOf: group.fileMessageIDs)
        }
        // 失败、中断或没有最终答复时，文件结果仍有入口，不依赖模型一定给出 final。
        flushFileChanges()
        return result
    }

    private static func isProcessMessage(_ message: ConversationMessage) -> Bool {
        guard message.role != .user else { return false }
        switch message.kind {
        case .commentary, .plan, .reasoningSummary, .commandSummary, .fileChangeSummary:
            return true
        case .approval, .userInput:
            return isResolvedInteractionMessage(message)
        case .message, .warning, .error:
            // 普通答复和未知消息绝不根据位置猜成过程；异常与待处理交互始终在主视图可见。
            return false
        }
    }

    private static func isActivityMessage(_ message: ConversationMessage) -> Bool {
        switch message.kind {
        case .reasoningSummary, .commandSummary, .fileChangeSummary: true
        default: message.activityPayload != nil
        }
    }

    private static func isResolvedInteractionMessage(_ message: ConversationMessage) -> Bool {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch message.kind {
        case .approval:
            return content.hasPrefix(L10n.text("ui.approval_approved")) || content.hasPrefix(L10n.text("ui.approved")) ||
                content.hasPrefix(L10n.text("ui.approval_rejected")) || content.hasPrefix(L10n.text("ui.rejected"))
        case .userInput:
            return content.hasPrefix(L10n.text("ui.additional_information_has_been_submitted")) || content.hasPrefix(L10n.text("ui.boot_input_submitted")) ||
                content.hasPrefix(L10n.text("ui.additional_information_skipped")) || content.hasPrefix(L10n.text("ui.boot_input_skipped"))
        default: return false
        }
    }

    private static func isCompletedAssistantMessage(_ message: ConversationMessage) -> Bool {
        guard message.role == .assistant && message.kind == .message else {
            return false
        }
        return message.sendStatus == .confirmed || message.sendStatus == .sent
    }

    private static func effectiveTurnLifecycles(
        in messages: [ConversationMessage]
    ) -> [TurnID: ConversationTurnLifecycle] {
        struct LifecycleFacts {
            var hasFailed = false
            var hasInterrupted = false
            var hasCompleted = false
            var hasInProgress = false
            var hasCompletedAssistant = false
            var onlyUnknownOrMissingLifecycle = true
        }

        var factsByTurnID: [TurnID: LifecycleFacts] = [:]
        for message in messages {
            guard let turnID = message.turnID, !turnID.isEmpty else {
                continue
            }
            var facts = factsByTurnID[turnID] ?? LifecycleFacts()
            facts.hasFailed = facts.hasFailed
                || message.turnLifecycle == .failed
                || (message.role == .assistant && message.sendStatus == .failed)
            facts.hasInterrupted = facts.hasInterrupted || message.turnLifecycle == .interrupted
            facts.hasCompleted = facts.hasCompleted || message.turnLifecycle == .completed
            facts.hasInProgress = facts.hasInProgress
                || message.turnLifecycle == .inProgress
                || message.activityPayload?.isInProgress == true
            facts.hasCompletedAssistant = facts.hasCompletedAssistant || isCompletedAssistantMessage(message)
            if let lifecycle = message.turnLifecycle, lifecycle != .unknown {
                facts.onlyUnknownOrMissingLifecycle = false
            }
            factsByTurnID[turnID] = facts
        }

        var result: [TurnID: ConversationTurnLifecycle] = [:]
        for (turnID, facts) in factsByTurnID {
            if facts.hasFailed {
                result[turnID] = .failed
                continue
            }
            if facts.hasInterrupted {
                result[turnID] = .interrupted
                continue
            }
            if facts.hasCompleted {
                result[turnID] = .completed
                continue
            }
            // 旧 gateway 没有可靠 lifecycle 时才回退到 final；显式 inProgress 不能被提前收口。
            if facts.onlyUnknownOrMissingLifecycle, facts.hasCompletedAssistant {
                result[turnID] = .completed
                continue
            }
            result[turnID] = facts.hasInProgress ? .inProgress : .unknown
        }
        return result
    }

    private static func fallbackTurnLifecycle(
        for processMessages: [ConversationMessage],
        nextIndex: [ConversationMessage].Index,
        messages: [ConversationMessage]
    ) -> ConversationTurnLifecycle {
        guard processMessages.first?.turnID == nil,
              let next = messages[safe: nextIndex],
              next.role == .assistant else {
            return .unknown
        }
        if next.sendStatus == .failed {
            return .failed
        }
        return isCompletedAssistantMessage(next) ? .completed : .unknown
    }

}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
