import Foundation

struct ConversationTimelineItemBuilder {
    static func items(
        from messages: [ConversationMessage],
        provider: ConversationTimelineProvider = .codex,
        showsDetailedTranscript: Bool = false
    ) -> [ConversationTimelineItem] {
        let turnLifecycles = effectiveTurnLifecycles(in: messages)
        let continuationIndexes = continuationIndexes(in: messages)
        var activityProjectedItems: [ConversationTimelineItem] = []
        var index = messages.startIndex

        while index < messages.endIndex {
            let message = messages[index]
            guard isActivityMessage(message) else {
                activityProjectedItems.append(.message(message))
                index = messages.index(after: index)
                continue
            }

            var activityMessages: [ConversationMessage] = []
            while index < messages.endIndex,
                  isActivityMessage(messages[index]),
                  belongsToSameActivitySequence(message, messages[index]) {
                activityMessages.append(messages[index])
                index = messages.index(after: index)
            }
            let turnLifecycle = message.turnID.flatMap { turnLifecycles[$0] }
                ?? fallbackTurnLifecycle(for: activityMessages, nextIndex: index, messages: messages)
            let keepsRunningWhileTurnIsActive = isLatestActivitySequence(
                for: message,
                nextIndex: index,
                continuationIndexes: continuationIndexes
            )
            // 时间线只折叠相邻过程项，不跨 commentary、plan 或 final 搬运内容。
            // 输入顺序由上游 canonical timeline 决定，视图投影不能再次改写语义顺序。
            activityProjectedItems.append(contentsOf: activityItems(
                from: activityMessages,
                provider: provider,
                showsDetailedTranscript: showsDetailedTranscript,
                turnLifecycle: turnLifecycle,
                keepsRunningWhileTurnIsActive: keepsRunningWhileTurnIsActive
            ))
        }

        return activityProjectedItems
    }

    private static func isActivityMessage(_ message: ConversationMessage) -> Bool {
        guard message.role == .system else {
            return false
        }
        switch message.kind {
        case .reasoningSummary, .commandSummary, .fileChangeSummary:
            return true
        case .approval, .userInput:
            return isResolvedInteractionMessage(message)
        case .commentary, .plan, .warning, .error, .message:
            return false
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
        case .message, .commentary, .plan, .reasoningSummary, .commandSummary, .fileChangeSummary, .warning, .error:
            return false
        }
    }

    private static func belongsToSameActivitySequence(
        _ first: ConversationMessage,
        _ candidate: ConversationMessage
    ) -> Bool {
        first.turnID == candidate.turnID
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
        guard sharedTurnID(in: processMessages) == nil,
              let next = messages[safe: nextIndex],
              next.role == .assistant else {
            return .unknown
        }
        if next.sendStatus == .failed {
            return .failed
        }
        return isCompletedAssistantMessage(next) ? .completed : .unknown
    }

    private struct ContinuationIndexes {
        let lastActivityIndex: Int?
        let lastIndexByTurnID: [TurnID: Int]
    }

    private static func continuationIndexes(in messages: [ConversationMessage]) -> ContinuationIndexes {
        var lastActivityIndex: Int?
        var lastIndexByTurnID: [TurnID: Int] = [:]

        for index in messages.indices {
            let message = messages[index]
            let isActivity = isActivityMessage(message)
            if isActivity {
                lastActivityIndex = index
            }
            guard let turnID = message.turnID, !turnID.isEmpty else {
                continue
            }
            // 与旧的向后扫描保持同一语义，但只在构建前线性计算一次。
            if isActivity || message.kind != .message || message.role != .assistant {
                lastIndexByTurnID[turnID] = index
            }
        }
        return ContinuationIndexes(
            lastActivityIndex: lastActivityIndex,
            lastIndexByTurnID: lastIndexByTurnID
        )
    }

    private static func isLatestActivitySequence(
        for firstMessage: ConversationMessage,
        nextIndex: [ConversationMessage].Index,
        continuationIndexes: ContinuationIndexes
    ) -> Bool {
        guard let turnID = firstMessage.turnID else {
            return continuationIndexes.lastActivityIndex.map { $0 < nextIndex } ?? true
        }
        // commentary/plan/交互卡已经开始展示下一阶段时，上一批命令必须收口；
        // final 的显式 inProgress 仍可能只是尚未完成的流式正文，保持原有兼容语义。
        return continuationIndexes.lastIndexByTurnID[turnID].map { $0 < nextIndex } ?? true
    }

    private static func sharedTurnID(in messages: [ConversationMessage]) -> TurnID? {
        let turnIDs = Set(messages.compactMap(\.turnID))
        guard turnIDs.count == 1, let turnID = turnIDs.first, !turnID.isEmpty else {
            return nil
        }
        return turnID
    }

    private static func activityItems(
        from messages: [ConversationMessage],
        provider: ConversationTimelineProvider,
        showsDetailedTranscript: Bool,
        turnLifecycle: ConversationTurnLifecycle,
        keepsRunningWhileTurnIsActive: Bool
    ) -> [ConversationTimelineItem] {
        guard provider == .codex, !showsDetailedTranscript else {
            // Claude Code 默认逐条呈现工具与 thinking。当前协议没有稳定的重复调用
            // 聚合边界，因此不能仅凭标题相同猜测并吞掉独立状态。
            return messages.map(ConversationTimelineItem.activity)
        }

        var result: [ConversationTimelineItem] = []
        var explorationMessages: [ConversationMessage] = []

        func flushExploration(hasFollowingActivity: Bool) {
            guard !explorationMessages.isEmpty else {
                return
            }
            if explorationMessages.count == 1, let message = explorationMessages.first {
                result.append(.activity(message))
            } else {
                result.append(.activityBatch(activityBatch(
                    from: explorationMessages,
                    turnLifecycle: turnLifecycle,
                    keepsRunningWhileTurnIsActive: keepsRunningWhileTurnIsActive && !hasFollowingActivity
                )))
            }
            explorationMessages.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if message.activityPayload?.commandPresentationKind == .exploration {
                explorationMessages.append(message)
            } else {
                flushExploration(hasFollowingActivity: true)
                // 普通命令、文件改动、工具调用与每段 reasoning 都保留独立入口。
                result.append(.activity(message))
            }
        }
        flushExploration(hasFollowingActivity: false)
        return result
    }

    private static func activityBatch(
        from messages: [ConversationMessage],
        turnLifecycle: ConversationTurnLifecycle,
        keepsRunningWhileTurnIsActive: Bool
    ) -> ConversationActivityBatch {
        let firstID = messages.first?.id.uuidString ?? UUID().uuidString
        let kind: ConversationCommandPresentationKind = messages.allSatisfy {
            $0.activityPayload?.commandPresentationKind == .exploration
        } ? .exploration : .execution
        return ConversationActivityBatch(
            id: "activity-batch:\(firstID)",
            messages: messages,
            kind: kind,
            status: .resolve(
                turnLifecycle: turnLifecycle,
                activities: messages,
                keepsRunningWhileTurnIsActive: keepsRunningWhileTurnIsActive
            )
        )
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
