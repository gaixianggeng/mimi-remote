import Foundation

extension ConversationStore {
    func projectedHistoryMessages(_ history: [CodexHistoryMessage], sessionID: String) -> [ConversationMessage] {
        let scopedSessionID = scopedSessionID(for: sessionID)
        let keys = history.map { historyProjectionKey(for: $0) }
        let fallbackCreatedAts = deterministicHistoryCreatedAtFallbacks(for: history)
        // Litter 的 ConversationScreenModel 会缓存“hydrated -> UI item”的投影结果；
        // 这里也把历史 JSON 消息到本地 ConversationMessage 的转换缓存住。这样手动刷新、
        // 前后台恢复拿到同一页历史时，不会因为缺少稳定 id 的历史项而反复生成新 UUID。
        if let cached = historyProjectionCacheBySessionID[scopedSessionID],
           cached.keys == keys {
            return cached.messages
        }

        let converted: [ConversationMessage]
        if let cached = historyProjectionCacheBySessionID[scopedSessionID],
           cached.keys.count == cached.messages.count {
            converted = incrementallyProjectedHistoryMessages(
                history,
                keys: keys,
                fallbackCreatedAts: fallbackCreatedAts,
                cached: cached,
                sessionID: sessionID
            )
        } else {
            var unstableReuseBuckets = unstableHistoryReuseBuckets(sessionID: sessionID)
            converted = history.indices.map { index in
                projectHistoryMessage(
                    history[index],
                    sessionID: sessionID,
                    fallbackCreatedAt: fallbackCreatedAts[index],
                    unstableReuseBuckets: &unstableReuseBuckets
                )
            }
        }
        historyProjectionCacheBySessionID[scopedSessionID] = HistoryProjectionCache(keys: keys, messages: converted)
        return converted
    }

    private func incrementallyProjectedHistoryMessages(
        _ history: [CodexHistoryMessage],
        keys: [HistoryProjectionKey],
        fallbackCreatedAts: [Date],
        cached: HistoryProjectionCache,
        sessionID: String
    ) -> [ConversationMessage] {
        let prefixCount = commonPrefixCount(lhs: cached.keys, rhs: keys)
        let suffixCount = commonSuffixCount(lhs: cached.keys, rhs: keys, excludingPrefix: prefixCount)
        let changedUpperBound = history.count - suffixCount

        var converted: [ConversationMessage] = []
        converted.reserveCapacity(history.count)

        if prefixCount > 0 {
            converted.append(contentsOf: cached.messages.prefix(prefixCount))
        }

        let suffixMessages = suffixCount > 0 ? cached.messages.suffix(suffixCount) : []
        // 增量投影只需要知道 prefix/suffix 这些已复用消息的 UUID；逐条插入 Set，
        // 避免 map + 数组拼接在长历史分页时额外复制一遍消息 id。
        var preservedIDs = Set<UUID>()
        preservedIDs.reserveCapacity(prefixCount + suffixCount)
        for message in converted {
            preservedIDs.insert(message.id)
        }
        for message in suffixMessages {
            preservedIDs.insert(message.id)
        }
        var unstableReuseBuckets = unstableHistoryReuseBuckets(sessionID: sessionID, excludingIDs: preservedIDs)

        if prefixCount < changedUpperBound {
            for index in prefixCount..<changedUpperBound {
                converted.append(projectHistoryMessage(
                    history[index],
                    sessionID: sessionID,
                    fallbackCreatedAt: fallbackCreatedAts[index],
                    unstableReuseBuckets: &unstableReuseBuckets
                ))
            }
        }

        converted.append(contentsOf: suffixMessages)
        return converted
    }

    private func projectHistoryMessage(
        _ item: CodexHistoryMessage,
        sessionID: String,
        fallbackCreatedAt: Date,
        unstableReuseBuckets: inout [UnstableHistoryReuseKey: UnstableHistoryReuseBucket]
    ) -> ConversationMessage {
        let stableID = historyStableID(for: item)
        let role = messageRole(item.role)
        let createdAt = item.createdAt ?? fallbackCreatedAt
        let isTimestampFallback = item.isTimestampFallback || item.createdAt == nil
        let sendStatus = item.sendStatus ?? .confirmed
        let id: UUID
        if let stableID,
           let reusedID = messageUUIDByStableMessageID[stableCacheKey(stableID: stableID, sessionID: sessionID)] {
            id = reusedID
        } else if stableID == nil,
                  let reused = popUnstableHistoryMessage(
                      role: role,
                      kind: item.kind,
                      content: item.content,
                      createdAt: createdAt,
                      updatedAt: item.updatedAt,
                      sendStatus: sendStatus,
                      revision: item.revision,
                      turnPayload: item.turnPayload,
                      activityPayload: item.activityPayload,
                      timelineOrdinal: item.timelineOrdinal,
                      turnLifecycle: item.turnLifecycle,
                      userDelivery: item.userDelivery,
                      isTimestampFallback: isTimestampFallback,
                      buckets: &unstableReuseBuckets
                  ) {
            id = reused.id
        } else {
            id = UUID()
        }
        return ConversationMessage(
            id: id,
            stableID: stableID,
            clientMessageID: item.clientMessageID,
            turnID: item.turnID,
            itemID: item.itemID,
            role: role,
            kind: item.kind,
            content: item.content,
            createdAt: createdAt,
            updatedAt: item.updatedAt,
            sendStatus: sendStatus,
            revision: item.revision,
            turnPayload: item.turnPayload,
            activityPayload: item.activityPayload,
            timelineOrdinal: item.timelineOrdinal,
            turnLifecycle: item.turnLifecycle,
            userDelivery: item.userDelivery,
            isTimestampFallback: isTimestampFallback
        )
    }

    private func deterministicHistoryCreatedAtFallbacks(for history: [CodexHistoryMessage]) -> [Date] {
        guard !history.isEmpty else {
            return []
        }
        var nextKnown = Array<Date?>(repeating: nil, count: history.count)
        var upcoming: Date?
        for index in stride(from: history.count - 1, through: 0, by: -1) {
            nextKnown[index] = upcoming
            if let createdAt = history[index].createdAt {
                upcoming = createdAt
            }
        }

        var fallbacks: [Date] = []
        fallbacks.reserveCapacity(history.count)
        var previousKnown: Date?
        for index in history.indices {
            if let createdAt = history[index].createdAt {
                fallbacks.append(createdAt)
                previousKnown = createdAt
            } else if let previousKnown {
                fallbacks.append(previousKnown.addingTimeInterval(0.001))
            } else if let next = nextKnown[index] {
                fallbacks.append(next.addingTimeInterval(-0.001))
            } else {
                // 历史缺时间时必须使用稳定值，不能用 Date()；否则旧消息会被投影成“刚刚加载”。
                fallbacks.append(Self.undatedHistoryFallbackDate)
            }
        }
        return fallbacks
    }

    private func commonPrefixCount(lhs: [HistoryProjectionKey], rhs: [HistoryProjectionKey]) -> Int {
        let maxCount = min(lhs.count, rhs.count)
        var index = 0
        while index < maxCount, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    private func commonSuffixCount(lhs: [HistoryProjectionKey], rhs: [HistoryProjectionKey], excludingPrefix prefixCount: Int) -> Int {
        let maxCount = min(lhs.count, rhs.count) - prefixCount
        guard maxCount > 0 else {
            return 0
        }
        var suffixCount = 0
        while suffixCount < maxCount {
            let lhsIndex = lhs.index(lhs.endIndex, offsetBy: -suffixCount - 1)
            let rhsIndex = rhs.index(rhs.endIndex, offsetBy: -suffixCount - 1)
            guard lhs[lhsIndex] == rhs[rhsIndex] else {
                break
            }
            suffixCount += 1
        }
        return suffixCount
    }

    private func unstableHistoryReuseBuckets(sessionID: String, excludingIDs: Set<UUID> = []) -> [UnstableHistoryReuseKey: UnstableHistoryReuseBucket] {
        var grouped: [UnstableHistoryReuseKey: [ConversationMessage]] = [:]
        for message in messagesByScopedSessionID[scopedSessionID(for: sessionID)] ?? [] {
            guard message.stableID == nil,
                  message.clientMessageID == nil,
                  message.turnID == nil,
                  message.itemID == nil,
                  message.sendStatus == .confirmed,
                  !excludingIDs.contains(message.id)
            else {
                continue
            }
            grouped[unstableHistoryReuseKey(for: message), default: []].append(message)
        }

        var buckets: [UnstableHistoryReuseKey: UnstableHistoryReuseBucket] = [:]
        buckets.reserveCapacity(grouped.count)
        for (key, messages) in grouped {
            buckets[key] = UnstableHistoryReuseBucket(messages: messages)
        }
        return buckets
    }

    private func unstableHistoryReuseKey(for message: ConversationMessage) -> UnstableHistoryReuseKey {
        UnstableHistoryReuseKey(
            role: message.role,
            kind: message.kind,
            content: message.content,
            createdAt: message.createdAt,
            updatedAt: message.updatedAt,
            sendStatus: message.sendStatus,
            revision: message.revision,
            turnPayload: message.turnPayload,
            activityPayload: message.activityPayload,
            timelineOrdinal: message.timelineOrdinal,
            turnLifecycle: message.turnLifecycle,
            userDelivery: message.userDelivery,
            isTimestampFallback: message.isTimestampFallback
        )
    }

    private func popUnstableHistoryMessage(
        role: ConversationMessage.Role,
        kind: MessageKind,
        content: String,
        createdAt: Date,
        updatedAt: Date?,
        sendStatus: MessageSendStatus,
        revision: ModelRevision?,
        turnPayload: CodexAppServerTurnPayload?,
        activityPayload: ConversationActivityPayload?,
        timelineOrdinal: Int64?,
        turnLifecycle: ConversationTurnLifecycle?,
        userDelivery: UserMessageDelivery?,
        isTimestampFallback: Bool,
        buckets: inout [UnstableHistoryReuseKey: UnstableHistoryReuseBucket]
    ) -> ConversationMessage? {
        let key = UnstableHistoryReuseKey(
            role: role,
            kind: kind,
            content: content,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sendStatus: sendStatus,
            revision: revision,
            turnPayload: turnPayload,
            activityPayload: activityPayload,
            timelineOrdinal: timelineOrdinal,
            turnLifecycle: turnLifecycle,
            userDelivery: userDelivery,
            isTimestampFallback: isTimestampFallback
        )
        guard var bucket = buckets[key] else {
            return nil
        }
        // 同一时间同一文本也可能重复出现，按出现顺序逐个复用。
        // 用游标代替 removeFirst，避免大批重复历史消息刷新时反复搬数组。
        guard let message = bucket.pop() else {
            buckets.removeValue(forKey: key)
            return nil
        }
        if bucket.isExhausted {
            buckets.removeValue(forKey: key)
        } else {
            buckets[key] = bucket
        }
        return message
    }

    private func historyProjectionKey(for item: CodexHistoryMessage) -> HistoryProjectionKey {
        let stableID = historyStableID(for: item)
        return HistoryProjectionKey(
            stableID: stableID,
            wireID: stableID == nil ? nil : item.id,
            role: item.role,
            kind: item.kind,
            content: item.content,
            turnPayload: item.turnPayload,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            clientMessageID: item.clientMessageID,
            turnID: item.turnID,
            itemID: item.itemID,
            seq: item.seq,
            revision: item.revision,
            sendStatus: item.sendStatus,
            activityPayload: item.activityPayload,
            timelineOrdinal: item.timelineOrdinal,
            turnLifecycle: item.turnLifecycle,
            userDelivery: item.userDelivery,
            isTimestampFallback: item.isTimestampFallback
        )
    }

    private func historyStableID(for item: CodexHistoryMessage) -> MessageID? {
        if let stableID = appServerStableMessageID(turnID: item.turnID, itemID: item.itemID) {
            return stableID
        }
        // 旧 Codex rollout 没有稳定 message id，Swift 解码会补一个随机 UUID；
        // 只有带结构化元数据时才把 id 当稳定键，避免破坏本地回显去重。
        if item.id.hasPrefix("rollout:") || item.clientMessageID != nil || item.turnID != nil || item.itemID != nil || item.seq != nil || item.revision != nil {
            return item.id
        }
        return nil
    }

    private func messageRole(_ raw: String) -> ConversationMessage.Role {
        switch raw {
        case "assistant":
            return .assistant
        case "system":
            return .system
        default:
            return .user
        }
    }

    private func appServerStableMessageID(turnID: TurnID?, itemID: AgentItemID?) -> MessageID? {
        guard let itemID, !itemID.isEmpty else {
            return nil
        }
        guard let turnID, !turnID.isEmpty else {
            return itemID
        }
        return "appserver:\(turnID):\(itemID)"
    }

    // thread/read 会把部分 item id 重排成整条线程的全局顺序号(item-N)，与流式 msg_… 对不上。
    // 仅靠 appserver:<turnId>:<itemId> 无法把直播副本和历史快照判为同一条，所以补一个
    // (turnId, 语义类型, 规范化文本) 的兜底键。这里只覆盖最终 assistant 和可折叠过程卡，
    // user 继续走 clientMessageId，approval/error/userInput 等交互状态不能按文本合并。
    func turnScopedTextMergeKey(for item: ConversationMessage) -> String? {
        guard let turnID = item.turnID, !turnID.isEmpty else {
            return nil
        }
        let semanticKind: String
        if item.role == .assistant {
            semanticKind = "assistant:\(item.kind.rawValue)"
        } else if item.role == .system, let processKind = processMessageMergeKind(for: item.kind) {
            semanticKind = processKind
        } else {
            return nil
        }
        let normalized = normalizedAssistantTextForDedup(item.content)
        guard !normalized.isEmpty else {
            return nil
        }
        return "turn:\(turnID):\(semanticKind):\(normalized)"
    }

    private func processMessageMergeKind(for kind: MessageKind) -> String? {
        switch kind {
        case .reasoningSummary, .plan, .commandSummary, .fileChangeSummary, .context:
            return kind.rawValue
        case .message, .commentary, .approval, .userInput, .questionReply, .warning, .error:
            return nil
        }
    }

    func scopedSessionID(for sessionID: SessionID) -> ScopedSessionID {
        ScopedSessionID(profileID: activeProfileID, sessionID: sessionID)
    }

}
