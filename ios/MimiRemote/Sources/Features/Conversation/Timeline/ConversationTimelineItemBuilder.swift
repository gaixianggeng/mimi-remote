import Foundation

struct ConversationTimelineItemBuilder {
    static func items(from messages: [ConversationMessage]) -> [ConversationTimelineItem] {
        let turnLifecycles = effectiveTurnLifecycles(in: messages)
        let explicitlyInProgressTurnIDs = Set(messages.compactMap { message -> TurnID? in
            guard message.turnLifecycle == .inProgress,
                  let turnID = nonEmptyTurnID(message.turnID) else {
                return nil
            }
            return turnID
        })
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
                turnLifecycle: turnLifecycle,
                keepsRunningWhileTurnIsActive: keepsRunningWhileTurnIsActive
            ))
        }

        // 第二遍只做跨 provider 的视觉归拢：第一遍产生的内层 activity/process group
        // 原样作为 entry 保存，避免 Codex/Claude 在 SwiftUI 里出现分叉逻辑。
        return workGroupItems(
            from: activityProjectedItems,
            turnLifecycles: turnLifecycles,
            explicitlyInProgressTurnIDs: explicitlyInProgressTurnIDs
        )
    }

    private struct PendingWorkGroup {
        let turnID: TurnID
        let anchorMessageID: UUID
        var entries: [ConversationWorkGroupEntry]
        var containsRealActivity: Bool
    }

    private static func workGroupItems(
        from items: [ConversationTimelineItem],
        turnLifecycles: [TurnID: ConversationTurnLifecycle],
        explicitlyInProgressTurnIDs: Set<TurnID>
    ) -> [ConversationTimelineItem] {
        var result: [ConversationTimelineItem] = []
        var pending: PendingWorkGroup?

        func flush(
            terminalBoundary: ConversationMessage? = nil,
            isRunningTail: Bool = false
        ) {
            guard let group = pending else {
                return
            }
            defer { pending = nil }

            // commentary-only 仍是正常正文。只有观察到真实工具/命令/文件过程，
            // 才把这一段升级成外层“已工作”分组。
            guard group.containsRealActivity else {
                result.append(contentsOf: group.entries.compactMap { entry in
                    guard case .commentary(let message) = entry else {
                        return nil
                    }
                    return .message(message)
                })
                return
            }

            let status = workGroupStatus(
                turnID: group.turnID,
                entries: group.entries,
                turnLifecycle: turnLifecycles[group.turnID] ?? .unknown,
                terminalBoundary: terminalBoundary,
                isRunningTail: isRunningTail,
                hasExplicitInProgressLifecycle: explicitlyInProgressTurnIDs.contains(group.turnID)
            )
            let startedAt = reliableStartedAt(in: group.entries)
            let endedAt = reliableEndedAt(
                in: group.entries,
                turnID: group.turnID,
                status: status,
                terminalBoundary: terminalBoundary
            )
            result.append(.workGroup(ConversationWorkGroup(
                id: "work:\(group.turnID):\(group.anchorMessageID.uuidString)",
                turnID: group.turnID,
                entries: group.entries,
                status: status,
                startedAt: startedAt,
                endedAt: endedAt
            )))
        }

        for item in items {
            if let candidate = workGroupCandidate(for: item) {
                if let current = pending, current.turnID != candidate.turnID {
                    flush()
                }
                if pending == nil {
                    pending = PendingWorkGroup(
                        turnID: candidate.turnID,
                        anchorMessageID: candidate.entry.stableAnchorMessageID,
                        entries: [],
                        containsRealActivity: false
                    )
                }
                if var current = pending {
                    current.entries.append(candidate.entry)
                    current.containsRealActivity = current.containsRealActivity
                        || candidate.entry.containsRealActivity
                    pending = current
                }
                continue
            }

            let boundary = boundaryMessage(for: item)
            flush(terminalBoundary: boundary)
            result.append(item)
        }
        flush(isRunningTail: true)
        return result
    }

    private static func workGroupCandidate(
        for item: ConversationTimelineItem
    ) -> (turnID: TurnID, entry: ConversationWorkGroupEntry)? {
        switch item {
        case .message(let message):
            guard message.role == .assistant,
                  message.kind == .commentary,
                  let turnID = nonEmptyTurnID(message.turnID) else {
                return nil
            }
            return (turnID, .commentary(message))
        case .activity(let message):
            guard let turnID = nonEmptyTurnID(message.turnID) else {
                return nil
            }
            return (turnID, .activity(message))
        case .activityBatch(let group):
            guard let turnID = sharedTurnID(in: group.messages) else {
                return nil
            }
            return (turnID, .activityBatch(group))
        case .processGroup(let group):
            guard let turnID = nonEmptyTurnID(group.turnID) else {
                return nil
            }
            return (turnID, .processGroup(group))
        case .workGroup:
            return nil
        }
    }

    private static func boundaryMessage(for item: ConversationTimelineItem) -> ConversationMessage? {
        guard case .message(let message) = item else {
            return nil
        }
        return message
    }

    private static func nonEmptyTurnID(_ turnID: TurnID?) -> TurnID? {
        guard let turnID, !turnID.isEmpty else {
            return nil
        }
        return turnID
    }

    private static func workGroupStatus(
        turnID: TurnID,
        entries: [ConversationWorkGroupEntry],
        turnLifecycle: ConversationTurnLifecycle,
        terminalBoundary: ConversationMessage?,
        isRunningTail: Bool,
        hasExplicitInProgressLifecycle: Bool
    ) -> ConversationActivityGroupStatus {
        let matchingTerminalBoundary = terminalBoundary.flatMap {
            isTerminalBoundary($0, for: turnID) ? $0 : nil
        }
        // turn 终态是唯一能把整组判为失败/中断的信号；子命令失败只留在内层弱提示。
        if turnLifecycle == .failed || matchingTerminalBoundary?.sendStatus == .failed {
            return .failed
        }
        if turnLifecycle == .interrupted {
            return .interrupted
        }
        if turnLifecycle == .completed {
            return .completed
        }
        if let matchingTerminalBoundary {
            if matchingTerminalBoundary.kind == .error {
                return .failed
            }
            if matchingTerminalBoundary.role == .assistant && matchingTerminalBoundary.kind == .message {
                // 新 runtime 的 final 会先开始 streaming，稍后才发送 completed lifecycle。
                // 此时保持运行和展开，避免用户正在看的工作流在首个答案 delta 到达时突然折叠。
                if turnLifecycle == .inProgress, hasExplicitInProgressLifecycle {
                    return .running
                }
                // 旧 runtime 可能没有 lifecycle；只有这类输入才由 final 可靠兜底收口。
                return .completed
            }
        }
        guard isRunningTail else {
            return .completed
        }
        if turnLifecycle == .inProgress {
            return .running
        }
        let messages = entries.flatMap(\.messagesForTiming)
        if messages.contains(where: { $0.activityPayload?.isInProgress == true }) {
            return .running
        }
        // 兼容旧 gateway：没有 payload 的尾部过程项只能以所在位置判断仍在运行。
        if messages.contains(where: {
            $0.role == .system
                && $0.activityPayload == nil
                && ($0.kind == .commandSummary || $0.kind == .fileChangeSummary)
        }) {
            return .running
        }
        return .completed
    }

    private static func reliableStartedAt(in entries: [ConversationWorkGroupEntry]) -> Date? {
        // source order 才是 canonical timeline 的语义顺序。首条 commentary 若使用
        // fallback 时间，继续找后面的首个可靠活动，不能把整组 duration 一并丢掉。
        for entry in entries {
            if let firstReliableMessage = entry.messagesForTiming.first(where: { !$0.isTimestampFallback }) {
                return firstReliableMessage.createdAt
            }
        }
        return nil
    }

    private static func reliableEndedAt(
        in entries: [ConversationWorkGroupEntry],
        turnID: TurnID,
        status: ConversationActivityGroupStatus,
        terminalBoundary: ConversationMessage?
    ) -> Date? {
        guard status != .running else {
            return nil
        }
        if let terminalBoundary,
           isTerminalBoundary(terminalBoundary, for: turnID),
           !terminalBoundary.isTimestampFallback {
            return terminalBoundary.updatedAt ?? terminalBoundary.createdAt
        }
        // 普通 user/plan/跨 turn 消息只是分组边界，不属于本段工作时长。
        // 从组内按 source order 反向找到最后一个可靠时间即可。
        for entry in entries.reversed() {
            if let lastReliableMessage = entry.messagesForTiming.reversed().first(where: {
                !$0.isTimestampFallback
            }) {
                return lastReliableMessage.updatedAt ?? lastReliableMessage.createdAt
            }
        }
        return nil
    }

    private static func isTerminalBoundary(
        _ message: ConversationMessage,
        for turnID: TurnID
    ) -> Bool {
        guard message.turnID == turnID else {
            return false
        }
        if message.kind == .error {
            return true
        }
        return message.role == .assistant && message.kind == .message
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
        turnLifecycle: ConversationTurnLifecycle,
        keepsRunningWhileTurnIsActive: Bool
    ) -> [ConversationTimelineItem] {
        var result: [ConversationTimelineItem] = []
        var commandMessages: [ConversationMessage] = []

        func flushCommands(hasFollowingActivity: Bool) {
            guard !commandMessages.isEmpty else {
                return
            }
            result.append(.activityBatch(activityBatch(
                from: commandMessages,
                turnLifecycle: turnLifecycle,
                keepsRunningWhileTurnIsActive: keepsRunningWhileTurnIsActive && !hasFollowingActivity
            )))
            commandMessages.removeAll(keepingCapacity: true)
        }

        for element in ConversationProcessGrouper.elements(
            from: messages,
            turnLifecycle: turnLifecycle,
            keepsRunningWhileTurnIsActive: keepsRunningWhileTurnIsActive
        ) {
            switch element {
            case .group(let group):
                flushCommands(hasFollowingActivity: true)
                result.append(.processGroup(group))
            case .activity(let message):
                if message.activityPayload?.category == .runCommand ||
                    (message.activityPayload == nil && message.kind == .commandSummary) {
                    commandMessages.append(message)
                } else {
                    flushCommands(hasFollowingActivity: true)
                    result.append(.activity(message))
                }
            }
        }
        flushCommands(hasFollowingActivity: false)
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
