import Foundation

// 历史状态只用于恢复消息，不合成实时完成事件或完成反馈。
extension CodexAppServerSessionRuntime {
    func historyMessages(
        from thread: [String: CodexAppServerJSONValue],
        sessionID: SessionID,
        snapshotReadAt: Date
    ) -> [CodexHistoryMessage] {
        let turns = thread["turns"]?.arrayValue?.compactMap(\.objectValue) ?? []
        return historyMessages(
            fromTurns: turns,
            sessionID: sessionID,
            threadCreatedAt: firstDate(in: thread, keys: ["createdAt", "created_at"]),
            threadUpdatedAt: firstDate(in: thread, keys: ["updatedAt", "updated_at"]),
            threadIsActive: isActiveHistoryThread(thread),
            snapshotReadAt: snapshotReadAt
        )
    }

    func historyMessages(
        fromTurns turns: [[String: CodexAppServerJSONValue]],
        sessionID: SessionID,
        threadCreatedAt: Date? = nil,
        threadUpdatedAt: Date? = nil,
        threadIsActive: Bool = false,
        timelineOrdinalsAreCanonical: Bool = true,
        snapshotReadAt: Date
    ) -> [CodexHistoryMessage] {
        var messages: [CodexHistoryMessage] = []
        messages.reserveCapacity(turns.reduce(0) { count, turn in
            count + (turn["items"]?.arrayValue?.count ?? 0)
        })
        var lastResolvedAt = threadUpdatedAt ?? threadCreatedAt

        for (turnIndex, turn) in turns.enumerated() {
            let turnID = turn["id"]?.stringValue
            let startedAt = firstDate(in: turn, keys: ["startedAt", "started_at", "createdAt", "created_at", "timestamp"])
            let completedAt = firstDate(in: turn, keys: ["completedAt", "completed_at", "updatedAt", "updated_at", "finishedAt", "finished_at"])
            let turnIsInProgress = isInProgressHistoryTurn(
                turn,
                isLastTurn: turnIndex == turns.index(before: turns.endIndex),
                threadIsActive: threadIsActive,
                completedAt: completedAt
            )
            let turnLifecycle = historyTurnLifecycle(
                turn,
                isInProgress: turnIsInProgress,
                completedAt: completedAt
            )
            let items = turn["items"]?.arrayValue?.compactMap(\.objectValue) ?? []
            var hasVisibleUserMessageInTurn = false
            for (itemIndex, item) in items.enumerated() {
                // summary 只保留展示摘要，其数组下标不是 Item 在完整 rollout 中的位置。
                // 完整 Item 分页到达前不能用这个占位序号约束时间线。
                let timelineOrdinal = timelineOrdinalsAreCanonical
                    ? historyTimelineOrdinal(turnIndex: turnIndex, itemIndex: itemIndex)
                    : nil
                guard var message = historyMessage(
                    from: item,
                    sessionID: sessionID,
                    turnID: turnID,
                    timelineOrdinal: timelineOrdinal,
                    isInjectedUserMessage: hasVisibleUserMessageInTurn,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    estimatedAt: estimatedHistoryItemDate(startedAt: startedAt, completedAt: completedAt, itemIndex: itemIndex, itemCount: items.count),
                    turnIsInProgress: turnIsInProgress,
                    snapshotReadAt: snapshotReadAt
                ) else {
                    continue
                }
                message = message.withTurnLifecycle(turnLifecycle)
                if message.role == "user" {
                    hasVisibleUserMessageInTurn = true
                }
                if message.createdAt == nil {
                    // 历史消息缺少 item/turn 级时间时不能兜底成当前加载时间；用上游 thread
                    // 时间或前一条已解析时间维持稳定排序，同时显式标记为估算。
                    let fallback = lastResolvedAt ?? threadUpdatedAt ?? threadCreatedAt ?? Self.stableHistoryFallbackDate(index: messages.count)
                    message = message.withTimestampFallback(createdAt: fallback)
                }
                if let resolvedAt = message.updatedAt ?? message.createdAt {
                    lastResolvedAt = resolvedAt
                }
                messages.append(message)
            }
            if turnLifecycle == .failed, let turnID,
               let error = appServerTurnErrorPayload(from: turn) {
                let authenticationFailure = ClaudeAuthenticationRecovery.matches(error)
                // 失败可能只留下用户 Item；错误卡片必须从 Turn 恢复，不能依赖最终答复存在。
                // 每回合序号占一百万个位置，错误使用末尾预留位置，排在分页补齐的真实 Item 后。
                messages.append(CodexHistoryMessage(
                    id: "runtime-error:\(turnID)",
                    role: "system",
                    kind: .error,
                    content: authenticationFailure
                        ? ClaudeAuthenticationRecovery.recoveryMessage
                        : L10n.format("ui.run_error_value", error.message),
                    activityPayload: authenticationFailure ? ClaudeAuthenticationRecovery.activityPayload : nil,
                    createdAt: completedAt ?? lastResolvedAt ?? startedAt ?? Self.stableHistoryFallbackDate(index: messages.count),
                    updatedAt: completedAt,
                    turnID: turnID,
                    timelineOrdinal: timelineOrdinalsAreCanonical
                        ? historyTimelineOrdinal(turnIndex: turnIndex, itemIndex: 999_999)
                        : nil,
                    turnLifecycle: .failed,
                    isTimestampFallback: completedAt == nil
                ))
            }
        }
        return messages
    }

    func historyMessage(
        from item: [String: CodexAppServerJSONValue],
        sessionID: SessionID,
        turnID: TurnID?,
        timelineOrdinal: Int64?,
        isInjectedUserMessage: Bool,
        startedAt: Date?,
        completedAt: Date?,
        estimatedAt: Date?,
        turnIsInProgress: Bool,
        snapshotReadAt: Date
    ) -> CodexHistoryMessage? {
        let type = item["type"]?.stringValue
        let itemID = item["id"]?.stringValue ?? UUID().uuidString
        let messageID = appServerHistoryMessageID(turnID: turnID, itemID: itemID)
        let itemCreatedAt = firstDate(in: item, keys: ["createdAt", "created_at", "startedAt", "started_at", "timestamp"])
        let itemCompletedAt = firstDate(in: item, keys: ["completedAt", "completed_at", "updatedAt", "updated_at", "finishedAt", "finished_at", "timestamp"])
        let processCreatedAt = itemCreatedAt ?? estimatedAt ?? startedAt ?? itemCompletedAt ?? completedAt
        // running thread/read 快照常缺 item 级 completedAt，但内容已是最新输出；
        // 用读取时间写 updatedAt，让观察模式显示最近活动，同时不改 createdAt 的排序语义。
        let liveSnapshotUpdatedAt = turnIsInProgress && itemCompletedAt == nil && !isTerminalHistoryStatus(item["status"]) ? snapshotReadAt : nil
        let processTimestampIsFallback = itemCreatedAt == nil && itemCompletedAt == nil && estimatedAt != nil
        switch type {
        case "userMessage":
            let inputs = MimiFileContextCodec.collapsingExpandedInputs(userMessageInputs(from: item))
            let text = userMessageText(from: inputs).trimmingCharacters(in: .whitespacesAndNewlines)
            let hasRichInput = containsRichInput(inputs)
            guard !text.isEmpty || hasRichInput else {
                return nil
            }
            let isTextOnly = inputs.allSatisfy { if case .text = $0 { true } else { false } }
            if isTextOnly, let reply = CodexAsyncQuestionReply(text: text) {
                // 异步提问的答复与实时事件使用同一映射：只认纯文本输入，保留 Item 身份和序号，只换类型与正文。
                return CodexHistoryMessage(
                    id: messageID,
                    role: "user",
                    kind: .questionReply,
                    content: reply.displayText,
                    createdAt: itemCreatedAt ?? estimatedAt ?? startedAt ?? itemCompletedAt ?? completedAt,
                    clientMessageID: item["clientId"]?.stringValue,
                    turnID: turnID,
                    itemID: itemID,
                    timelineOrdinal: timelineOrdinal,
                    isTimestampFallback: itemCreatedAt == nil && itemCompletedAt == nil && estimatedAt != nil
                )
            }
            // 自动环境文本可以为空，但不能因此丢弃同一消息中的图片或文件。
            let hasAttachmentOnlyRequest = hasRichInput
                && ConversationUserMessagePresentation.displayContent(from: text).isEmpty
            guard text.isEmpty || hasAttachmentOnlyRequest || isVisibleUserHistoryMessage(text) else {
                return nil
            }
            let turnPayload = hasRichInput ? CodexAppServerTurnPayload(input: inputs) : nil
            let content = text.isEmpty ? (turnPayload?.previewText ?? "") : text
            guard !content.isEmpty else {
                return nil
            }
            let createdAt = itemCreatedAt ?? estimatedAt ?? startedAt ?? itemCompletedAt ?? completedAt
            return CodexHistoryMessage(
                id: messageID,
                role: "user",
                content: content,
                turnPayload: turnPayload,
                createdAt: createdAt,
                clientMessageID: item["clientId"]?.stringValue,
                turnID: turnID,
                itemID: itemID,
                timelineOrdinal: timelineOrdinal,
                userDelivery: isInjectedUserMessage ? .injected : nil,
                isTimestampFallback: itemCreatedAt == nil && itemCompletedAt == nil && estimatedAt != nil
            )
        case "imageGeneration", "imageView":
            guard let content = ConversationImageItemProjection.markdownContent(from: item) else {
                return nil
            }
            let completed = itemCompletedAt ?? completedAt
            return CodexHistoryMessage(
                id: messageID,
                role: "assistant",
                content: content,
                createdAt: completed ?? itemCreatedAt ?? estimatedAt ?? startedAt,
                updatedAt: completed ?? liveSnapshotUpdatedAt,
                turnID: turnID,
                itemID: itemID,
                timelineOrdinal: timelineOrdinal,
                isTimestampFallback: completed == nil && itemCreatedAt == nil && estimatedAt != nil
            )
        case "agentMessage":
            let rawText = item["text"]?.stringValue ?? ""
            let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let isStreaming = liveSnapshotUpdatedAt != nil
            // 进行中的快照是后续 delta 的正文前缀，末尾空白也属于正文，不能提前裁掉。
            let text = isStreaming ? rawText : trimmedText
            guard !trimmedText.isEmpty else {
                return nil
            }
            if item["phase"]?.stringValue == "commentary" {
                // commentary 是面向用户的阶段性正文，不是内部 reasoning。
                return CodexHistoryMessage(id: messageID, role: "assistant", kind: .commentary, content: text, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, sendStatus: isStreaming ? .sending : .confirmed, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
            }
            let completed = itemCompletedAt ?? completedAt
            return CodexHistoryMessage(id: messageID, role: "assistant", content: text, createdAt: completed ?? itemCreatedAt ?? estimatedAt ?? startedAt, updatedAt: completed ?? liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, sendStatus: isStreaming ? .sending : .confirmed, timelineOrdinal: timelineOrdinal, isTimestampFallback: completed == nil && itemCreatedAt == nil && estimatedAt != nil)
        case "plan":
            guard let payload = ConversationActivityPayload(item: item) else {
                return nil
            }
            let content = payload.detailText(from: item)
            guard !content.isEmpty else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "system", kind: payload.messageKind, content: content, activityPayload: payload, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
        case "reasoning":
            guard let payload = ConversationActivityPayload(item: item) else {
                return nil
            }
            let content = payload.detailText(from: item)
            guard !content.isEmpty else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "system", kind: payload.messageKind, content: content, activityPayload: payload, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
        case "commandExecution":
            guard let payload = ConversationActivityPayload(item: item) else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "system", kind: payload.messageKind, content: payload.detailText(from: item), activityPayload: payload, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
        case "fileChange":
            guard let payload = ConversationActivityPayload(item: item) else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "system", kind: payload.messageKind, content: payload.detailText(from: item), activityPayload: payload, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch":
            guard let payload = ConversationActivityPayload(item: item) else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "system", kind: payload.messageKind, content: payload.detailText(from: item), activityPayload: payload, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
        default:
            return nil
        }
    }

    /// Item 分页补齐只投影当前页，不能把此前页面重新积存在 JSON 数组里。
    /// itemOffset 让缺时间戳的后续页仍获得稳定且递增的时间线序号。
    func historyMessages(
        fromItems items: [[String: CodexAppServerJSONValue]],
        continuation: HistoryTurnItemsContinuation,
        sessionID: SessionID,
        snapshotReadAt: Date
    ) -> [CodexHistoryMessage] {
        let turn = continuation.turn
        let startedAt = firstDate(in: turn, keys: ["startedAt", "started_at", "createdAt", "created_at", "timestamp"])
        let completedAt = firstDate(in: turn, keys: ["completedAt", "completed_at", "updatedAt", "updated_at", "finishedAt", "finished_at"])
        let turnIsInProgress = isInProgressHistoryTurn(
            turn,
            isLastTurn: continuation.isLatestTurn,
            threadIsActive: continuation.threadIsActive,
            completedAt: completedAt
        )
        let turnLifecycle = historyTurnLifecycle(
            turn,
            isInProgress: turnIsInProgress,
            completedAt: completedAt
        )
        var hasVisibleUserMessage = continuation.hasVisibleUserMessageBefore
        var messages: [CodexHistoryMessage] = []
        messages.reserveCapacity(items.count)
        for (pageIndex, item) in items.enumerated() {
            let absoluteItemIndex = continuation.itemOffset + pageIndex
            let estimatedAt = startedAt.map {
                $0.addingTimeInterval(Double(absoluteItemIndex) * 0.001)
            } ?? completedAt
            guard var message = historyMessage(
                from: item,
                sessionID: sessionID,
                turnID: continuation.turnID,
                timelineOrdinal: historyTimelineOrdinal(
                    turnIndex: continuation.turnIndex,
                    itemIndex: absoluteItemIndex
                ),
                isInjectedUserMessage: hasVisibleUserMessage,
                startedAt: startedAt,
                completedAt: completedAt,
                estimatedAt: estimatedAt,
                turnIsInProgress: turnIsInProgress,
                snapshotReadAt: snapshotReadAt
            ) else {
                continue
            }
            message = message.withTurnLifecycle(turnLifecycle)
            if message.createdAt == nil {
                // Item 异步分页时不再持有完整 Thread。显式沿用首屏读取到的 Thread 时间，
                // 避免无 item/turn 时间戳的消息退化成 nil 或每次加载都变化的当前时间。
                let fallback = continuation.timestampFallback
                    ?? Self.stableHistoryFallbackDate(index: absoluteItemIndex)
                message = message.withTimestampFallback(createdAt: fallback)
            }
            if message.role == "user" {
                hasVisibleUserMessage = true
            }
            messages.append(message)
        }
        return messages
    }

    func historyTimelineOrdinal(turnIndex: Int, itemIndex: Int) -> Int64 {
        Int64(turnIndex) * 1_000_000 + Int64(itemIndex)
    }

    func isActiveHistoryThread(_ thread: [String: CodexAppServerJSONValue]) -> Bool {
        isActiveHistoryStatus(thread["status"])
    }

    func isInProgressHistoryTurn(
        _ turn: [String: CodexAppServerJSONValue],
        isLastTurn: Bool,
        threadIsActive: Bool,
        completedAt: Date?
    ) -> Bool {
        if isActiveHistoryStatus(turn["status"]) {
            return true
        }
        guard completedAt == nil, !isTerminalHistoryStatus(turn["status"]) else {
            return false
        }
        // thread/read 的 running turn 可能只在 thread.status 标 active，turn 自己不带 status；
        // 只有最后一个未完成 turn 继承线程活跃态，避免老 turn 的缺失时间被误标成当前读取时间。
        return threadIsActive && isLastTurn
    }

    func isActiveHistoryStatus(_ value: CodexAppServerJSONValue?) -> Bool {
        let raw = value?.stringValue
            ?? value?.objectValue?["type"]?.stringValue
            ?? value?.objectValue?["status"]?.stringValue
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active", "running", "inprogress", "in_progress", "waiting_for_approval", "waiting_for_input":
            return true
        default:
            return false
        }
    }

    func historyTurnLifecycle(
        _ turn: [String: CodexAppServerJSONValue],
        isInProgress: Bool,
        completedAt: Date?
    ) -> ConversationTurnLifecycle {
        if isInProgress {
            return .inProgress
        }
        let raw = turn["status"]?.stringValue
            ?? turn["status"]?.objectValue?["type"]?.stringValue
            ?? turn["status"]?.objectValue?["status"]?.stringValue
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "succeeded", "success":
            return .completed
        case "failed", "failure", "systemerror", "system_error":
            return .failed
        case "interrupted", "cancelled", "canceled", "aborted":
            return .interrupted
        default:
            return completedAt == nil ? .unknown : .completed
        }
    }

    func estimatedHistoryItemDate(startedAt: Date?, completedAt: Date?, itemIndex: Int, itemCount: Int) -> Date? {
        guard let startedAt else {
            return completedAt
        }
        guard let completedAt, completedAt > startedAt, itemCount > 1 else {
            return startedAt.addingTimeInterval(Double(itemIndex) * 0.001)
        }
        let progress = Double(itemIndex) / Double(max(1, itemCount - 1))
        return startedAt.addingTimeInterval(completedAt.timeIntervalSince(startedAt) * progress)
    }

    func isVisibleUserHistoryMessage(_ text: String) -> Bool {
        isVisibleAppServerUserMessageText(text)
    }

    func appServerHistoryMessageID(turnID: TurnID?, itemID: AgentItemID) -> MessageID {
        guard let turnID, !turnID.isEmpty else {
            return itemID
        }
        return "appserver:\(turnID):\(itemID)"
    }

}
