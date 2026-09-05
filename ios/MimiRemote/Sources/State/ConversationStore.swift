import Foundation

enum ConversationHistoryTimelineMutationKind: Equatable {
    case prepend
    case enrichment
}

struct ConversationHistoryTimelineMutation: Equatable {
    let generation: UInt64
    let kind: ConversationHistoryTimelineMutationKind
    let includesLiveChange: Bool

    init(
        generation: UInt64,
        kind: ConversationHistoryTimelineMutationKind,
        includesLiveChange: Bool = false
    ) {
        self.generation = generation
        self.kind = kind
        self.includesLiveChange = includesLiveChange
    }
}

@MainActor
final class ConversationStore: ObservableObject {
    @Published private var activeProfileID = ""
    // 读取放开到模块内，写入仍限本文件：投递对账扩展只读快照，改写一律走
    // replaceMessagesWithoutEquivalenceCheck，避免绕过索引重建。
    @Published private(set) var messagesByScopedSessionID: [ScopedSessionID: [ConversationMessage]] = [:]

    private var loadedHistorySessionIDs: Set<ScopedSessionID> = []
    private var lastSeenSeqBySessionID: [ScopedSessionID: EventSequence] = [:]
    private var revisionByStableMessageID: [StableMessageCacheKey: ModelRevision] = [:]
    private var messageUUIDByStableMessageID: [StableMessageCacheKey: UUID] = [:]
    private var messageIndexByStableIDBySessionID: [ScopedSessionID: [MessageID: Int]] = [:]
    private var messageIndexByClientMessageIDBySessionID: [ScopedSessionID: [ClientMessageID: Int]] = [:]
    private var messageIndexByUUIDBySessionID: [ScopedSessionID: [UUID: Int]] = [:]
    private var historyProjectionCacheBySessionID: [ScopedSessionID: HistoryProjectionCache] = [:]
    private var pendingAssistantDeltasBySessionID: [ScopedSessionID: PendingAssistantDelta] = [:]
    private var assistantDeltaFlushTasks: [ScopedSessionID: Task<Void, Never>] = [:]
    private(set) var turnLifecycleBySessionID: [ScopedSessionID: [TurnID: ConversationTurnLifecycle]] = [:]
    private var historyTimelineMutationBySessionID: [ScopedSessionID: ConversationHistoryTimelineMutation] = [:]
    private var historyTimelineMutationGeneration: UInt64 = 0
    private var sessionAccessTickBySessionID: [ScopedSessionID: UInt64] = [:]
    private var retainedByteCountBySessionID: [ScopedSessionID: Int] = [:]
    private var totalRetainedByteCount = 0
    private var sessionAccessCounter: UInt64 = 0
    private let timelineReducer = ConversationTimelineReducer()

#if DEBUG
    private(set) var historyMergeInvocationCountForTesting = 0
    private(set) var retainedByteFullRecalculationCountForTesting = 0
    /// 测试用：是否还有未落地的流式 delta 合并缓冲（跨所有 Profile）。
    /// 定向测试靠它等待 80ms flush 真正执行，而不是用固定 sleep 猜定时器落地顺序。
    var hasPendingAssistantDeltasForTesting: Bool {
        !pendingAssistantDeltasBySessionID.isEmpty
    }
#endif

    private let assistantDeltaFlushDelay: UInt64 = 80_000_000
    static let retainedSessionLimit = 32
    static let retainedSessionByteLimit = 64 * 1_024 * 1_024

    private struct PendingAssistantDelta {
        let stableID: MessageID
        let uuid: UUID
        let clientMessageID: ClientMessageID?
        let turnID: TurnID?
        let itemID: AgentItemID?
        var kind: MessageKind
        let createdAt: Date?
        var updatedAt: Date?
        var text: String
        var revision: ModelRevision?
    }

    private struct HistoryProjectionCache {
        let keys: [HistoryProjectionKey]
        let messages: [ConversationMessage]
    }

    private struct HistoryProjectionKey: Hashable {
        let stableID: MessageID?
        let wireID: MessageID?
        let role: String
        let kind: MessageKind
        let content: String
        let turnPayload: CodexAppServerTurnPayload?
        let createdAt: Date?
        let updatedAt: Date?
        let clientMessageID: ClientMessageID?
        let turnID: TurnID?
        let itemID: AgentItemID?
        let seq: EventSequence?
        let revision: ModelRevision?
        let sendStatus: MessageSendStatus?
        let activityPayload: ConversationActivityPayload?
        let timelineOrdinal: Int64?
        let turnLifecycle: ConversationTurnLifecycle?
        let userDelivery: UserMessageDelivery?
        let isTimestampFallback: Bool
    }

    private struct StableMessageCacheKey: Hashable {
        let scopedSessionID: ScopedSessionID
        let stableID: MessageID
    }

    private struct UnstableHistoryReuseKey: Hashable {
        let role: ConversationMessage.Role
        let kind: MessageKind
        let content: String
        let createdAt: Date
        let updatedAt: Date?
        let sendStatus: MessageSendStatus
        let revision: ModelRevision?
        let turnPayload: CodexAppServerTurnPayload?
        let activityPayload: ConversationActivityPayload?
        let timelineOrdinal: Int64?
        let turnLifecycle: ConversationTurnLifecycle?
        let userDelivery: UserMessageDelivery?
        let isTimestampFallback: Bool
    }

    private struct UnstableHistoryReuseBucket {
        let messages: [ConversationMessage]
        var nextIndex = 0

        var isExhausted: Bool {
            nextIndex >= messages.count
        }

        mutating func pop() -> ConversationMessage? {
            guard !isExhausted else {
                return nil
            }
            let message = messages[nextIndex]
            nextIndex += 1
            return message
        }
    }

    private static let undatedHistoryFallbackDate = Date(timeIntervalSince1970: 0)

    /// 兼容现有定向测试与只读诊断；业务热路径应继续通过 messages(for:) 读取当前 Profile。
    var messagesBySessionID: [String: [ConversationMessage]] {
        var activeMessages: [String: [ConversationMessage]] = [:]
        for (key, messages) in messagesByScopedSessionID where key.profileID == activeProfileID {
            activeMessages[key.sessionID] = messages
        }
        return activeMessages
    }

    /// 激活 Profile 只切换命名空间，不复制缓存；LRU 与字节预算仍由所有 scoped session 共同竞争。
    func activate(profileID: String) {
        guard activeProfileID != profileID else {
            return
        }
        activeProfileID = profileID
    }

    /// 删除连接档案时立即释放该 Profile 的正文、索引、流式缓冲和 LRU 记账。
    /// 这里不改变 activeProfileID；SessionStore 已禁止删除当前档案。
    func remove(profileID: String) {
        var scopedSessionIDs = Set(messagesByScopedSessionID.keys.filter { $0.profileID == profileID })
        scopedSessionIDs.formUnion(loadedHistorySessionIDs.filter { $0.profileID == profileID })
        scopedSessionIDs.formUnion(lastSeenSeqBySessionID.keys.filter { $0.profileID == profileID })
        scopedSessionIDs.formUnion(pendingAssistantDeltasBySessionID.keys.filter { $0.profileID == profileID })
        scopedSessionIDs.formUnion(assistantDeltaFlushTasks.keys.filter { $0.profileID == profileID })
        scopedSessionIDs.formUnion(turnLifecycleBySessionID.keys.filter { $0.profileID == profileID })
        scopedSessionIDs.formUnion(sessionAccessTickBySessionID.keys.filter { $0.profileID == profileID })
        scopedSessionIDs.formUnion(retainedByteCountBySessionID.keys.filter { $0.profileID == profileID })

        for scopedSessionID in scopedSessionIDs {
            clearConversationSessionState(
                scopedSessionID: scopedSessionID,
                messages: messagesByScopedSessionID[scopedSessionID] ?? []
            )
        }
        let filteredMessages = messagesByScopedSessionID.filter { $0.key.profileID != profileID }
        if filteredMessages.count != messagesByScopedSessionID.count {
            messagesByScopedSessionID = filteredMessages
        }
    }

    func messages(for sessionID: String?) -> [ConversationMessage] {
        guard let sessionID else {
            return []
        }
        return messagesByScopedSessionID[scopedSessionID(for: sessionID)] ?? []
    }

    func hasLoadedHistory(sessionID: String) -> Bool {
        loadedHistorySessionIDs.contains(scopedSessionID(for: sessionID))
    }

    func historyTimelineMutation(for sessionID: String?) -> ConversationHistoryTimelineMutation? {
        guard let sessionID else {
            return nil
        }
        return historyTimelineMutationBySessionID[scopedSessionID(for: sessionID)]
    }

    func hasLocallyUnreconciledUserDelivery(sessionID: String) -> Bool {
        // 与时间线“等待回复”判定保持同一边界：只检查最后一个普通 assistant 气泡之后的
        // 用户发送态。切换目录丢掉 completion 时，这能触发一次权威历史对账；已完整展示
        // assistant 的历史会话不会因此反复绕过缓存。
        for message in messages(for: sessionID).reversed() {
            if message.role == .assistant, message.kind == .message {
                return false
            }
            guard message.role == .user, message.kind == .message else {
                continue
            }
            switch message.sendStatus {
            case .sending, .uncertain, .sent, .failed:
                return true
            case .local, .confirmed:
                return false
            }
        }
        return false
    }

    func hasTerminalTurnAfterLatestUserMessage(sessionID: String) -> Bool {
        // authoritative reopen 只有在历史明确带回终态 turn 后才能清理“等待回复”。
        // 空首屏会保留本地消息；本地 waiting/partial assistant 都没有终态 lifecycle，
        // 因而不会被误当成已经对账完成。
        let scopedSessionID = scopedSessionID(for: sessionID)
        return ConversationMessageDeliveryReconciler.hasTerminalTurnAfterLatestUser(
            messages(for: sessionID),
            turnLifecycles: turnLifecycleBySessionID[scopedSessionID] ?? [:]
        )
    }

    func lastSeenSeq(for sessionID: String?) -> EventSequence? {
        guard let sessionID else {
            return nil
        }
        return lastSeenSeqBySessionID[scopedSessionID(for: sessionID)]
    }

    func retainSessionCache(sessionID: String) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        guard messagesByScopedSessionID[scopedSessionID] != nil else {
            return
        }
        touchConversationSession(scopedSessionID)
    }

    /// 本地空草稿被放弃时立即释放消息与索引，避免失败过的首发内容留在不可见缓存中。
    func reset(sessionID: String) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        let messages = messagesByScopedSessionID[scopedSessionID] ?? []
        clearConversationSessionState(scopedSessionID: scopedSessionID, messages: messages)
        guard messagesByScopedSessionID[scopedSessionID] != nil else {
            return
        }
        var next = messagesByScopedSessionID
        next.removeValue(forKey: scopedSessionID)
        messagesByScopedSessionID = next
    }

    func setHistory(
        _ history: [CodexHistoryMessage],
        sessionID: String,
        authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>] = [:],
        timelineMutationKind: ConversationHistoryTimelineMutationKind? = nil
    ) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        let includesLiveChange = flushPendingAssistantDelta(sessionID: sessionID)
        let converted = projectedHistoryMessages(history, sessionID: sessionID)
        for message in converted {
            if let stableID = message.stableID {
                let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
                messageUUIDByStableMessageID[key] = message.id
                if let revision = message.revision {
                    revisionByStableMessageID[key] = max(revisionByStableMessageID[key] ?? revision, revision)
                }
            }
        }
        if let current = messagesByScopedSessionID[scopedSessionID], areMessagesEquivalent(current, converted) {
            // 重复刷新同一页历史时，投影已经完全等价，直接标记已加载并刷新 LRU。
            // 这沿用 Litter 的 projection no-op 思路，跳过后续 merge/sort 和 @Published 检查。
            loadedHistorySessionIDs.insert(scopedSessionID)
            touchConversationSession(scopedSessionID)
            return
        }
        let merged = mergeHistory(
            converted,
            with: messagesByScopedSessionID[scopedSessionID] ?? [],
            sessionID: sessionID,
            authoritativeCompletedTurnItems: authoritativeCompletedTurnItems,
            snapshotOrdering: timelineMutationKind == .enrichment ? .incrementalFragments : .authoritative
        )
        recordTurnLifecycles(from: merged, sessionID: sessionID)
        if let current = messagesByScopedSessionID[scopedSessionID], areMessagesEquivalent(current, merged) {
            loadedHistorySessionIDs.insert(scopedSessionID)
            touchConversationSession(scopedSessionID)
            return
        }
        // 历史分页的来源必须在 @Published 消息写回前记录。时间线在同一轮渲染中
        // 才能识别这是历史补齐，而不是实时新消息，并阻止错误的尾部跟随。
        if let timelineMutationKind {
            historyTimelineMutationGeneration &+= 1
            historyTimelineMutationBySessionID[scopedSessionID] = ConversationHistoryTimelineMutation(
                generation: historyTimelineMutationGeneration,
                kind: timelineMutationKind,
                includesLiveChange: includesLiveChange
            )
        }
        setMessages(merged, sessionID: sessionID)
        loadedHistorySessionIDs.insert(scopedSessionID)
    }

    func replaceHistorySnapshot(
        _ history: [CodexHistoryMessage],
        sessionID: String,
        authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>] = [:]
    ) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        _ = flushPendingAssistantDelta(sessionID: sessionID)
        let converted = projectedHistoryMessages(history, sessionID: sessionID)
        for message in converted {
            if let stableID = message.stableID {
                let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
                messageUUIDByStableMessageID[key] = message.id
                if let revision = message.revision {
                    revisionByStableMessageID[key] = max(revisionByStableMessageID[key] ?? revision, revision)
                }
            }
        }

        if converted.isEmpty, messagesByScopedSessionID[scopedSessionID]?.isEmpty == false {
            // app-server 偶发返回空首屏时，不能清掉用户当前可见的历史和运行态消息；
            // 只标记本轮加载完成，分页游标由 SessionStore 根据 page metadata 继续维护。
            loadedHistorySessionIDs.insert(scopedSessionID)
            touchConversationSession(scopedSessionID)
            return
        }

        // 首屏是有上限的滑动窗口，缺席只表示滑出窗口，不能解释为服务端删除。
        // 这里始终合并；已完成 Turn 的权威 Item 集仍会清理确定失效的过程条目。
        let snapshot = mergeHistory(
            converted,
            with: messagesByScopedSessionID[scopedSessionID] ?? [],
            sessionID: sessionID,
            authoritativeCompletedTurnItems: authoritativeCompletedTurnItems
        )
        recordTurnLifecycles(from: snapshot, sessionID: sessionID)
        if let current = messagesByScopedSessionID[scopedSessionID], areMessagesEquivalent(current, snapshot) {
            loadedHistorySessionIDs.insert(scopedSessionID)
            touchConversationSession(scopedSessionID)
            return
        }
        // 首屏 full/summary 历史是当前会话的 canonical 快照。替换上一轮历史投影，
        // 但保留尚未进入 thread/read 的本地发送、审批、补充信息等运行态消息。
        setMessages(snapshot, sessionID: sessionID)
        loadedHistorySessionIDs.insert(scopedSessionID)
    }

    func appendUser(_ text: String, sessionID: String, createdAt: Date? = nil) {
        appendLocalUser(text, sessionID: sessionID, clientMessageID: nil, sendStatus: .sent, createdAt: createdAt)
    }

    func appendLocalUser(
        _ text: String,
        sessionID: String,
        clientMessageID: ClientMessageID?,
        sendStatus: MessageSendStatus = .sending,
        turnPayload: CodexAppServerTurnPayload? = nil,
        userDelivery: UserMessageDelivery? = nil,
        createdAt: Date? = nil
    ) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        if let clientMessageID,
           var list = messagesByScopedSessionID[scopedSessionID],
           let index = messageIndex(clientMessageID: clientMessageID, sessionID: sessionID) {
            let didChange = list[index].content != text ||
                list[index].sendStatus != sendStatus ||
                (turnPayload != nil && list[index].turnPayload != turnPayload)
            guard didChange else {
                return
            }
            list[index].content = text
            list[index].sendStatus = sendStatus
            list[index].turnPayload = turnPayload ?? list[index].turnPayload
            list[index].userDelivery = userDelivery ?? list[index].userDelivery
            list[index].updatedAt = Date()
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
            return
        }
        append(
            ConversationMessage(
                stableID: clientMessageID,
                clientMessageID: clientMessageID,
                role: .user,
                content: text,
                createdAt: createdAt ?? Date(),
                sendStatus: sendStatus,
                turnPayload: turnPayload,
                userDelivery: userDelivery
            ),
            sessionID: sessionID
        )
    }

    @discardableResult
    func updateSendStatus(clientMessageID: ClientMessageID, sessionID: String, status: MessageSendStatus) -> Bool {
        guard var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)],
              let index = messageIndex(clientMessageID: clientMessageID, sessionID: sessionID) else {
            return false
        }
        guard shouldTransitionSendStatus(from: list[index].sendStatus, to: status) else {
            return false
        }
        list[index].sendStatus = status
        list[index].updatedAt = Date()
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
        return true
    }

    func markSendingUserMessagesFailed(sessionID: String) {
        guard var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)] else {
            return
        }
        var changed = false
        for index in list.indices where list[index].role == .user && list[index].sendStatus == .sending {
            list[index].sendStatus = .failed
            list[index].updatedAt = Date()
            changed = true
        }
        guard changed else {
            return
        }
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
    }

    func compactTurnPayloadAfterSendAccepted(clientMessageID: ClientMessageID, sessionID: String) {
        guard var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)],
              let index = messageIndex(clientMessageID: clientMessageID, sessionID: sessionID),
              let payload = list[index].turnPayload else {
            return
        }
        let retained = payload.retainedAfterAcceptedSend()
        guard list[index].turnPayload != retained else {
            return
        }
        list[index].turnPayload = retained
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
    }

    /// turn/start 的 ACK 是本地用户消息与运行时 turn 的第一条权威关联。
    /// 只允许首次绑定或重复写入同一个 ID，避免迟到 ACK 把消息重新归到别的 turn。
    @discardableResult
    func bindTurnID(_ turnID: TurnID, clientMessageID: ClientMessageID, sessionID: String) -> Bool {
        let normalizedTurnID = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTurnID.isEmpty,
              var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)],
              let index = messageIndex(clientMessageID: clientMessageID, sessionID: sessionID),
              list[index].turnID == nil || list[index].turnID == normalizedTurnID else {
            return false
        }
        if list[index].turnID == normalizedTurnID {
            return true
        }
        list[index].turnID = normalizedTurnID
        list[index].turnLifecycle = turnLifecycleBySessionID[scopedSessionID(for: sessionID)]?[normalizedTurnID]
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
        return true
    }

    func appendSystem(
        _ text: String,
        sessionID: String,
        kind: MessageKind = .message,
        metadata: AgentEventMetadata? = nil,
        createdAt: Date? = nil
    ) {
        if kind == .approval, text.hasPrefix(L10n.text("ui.awaiting_approval")), upsertPendingApprovalMessage(text, sessionID: sessionID) {
            return
        }
        if kind == .userInput,
           isPendingUserInputText(text),
           upsertPendingUserInputMessage(text, sessionID: sessionID, metadata: metadata) {
            return
        }
        // runtime 过程消息需要保留 turnID/itemID，UI 才能在 turn 完成后准确折叠到“已处理”组里。
        append(ConversationMessage(
            turnID: metadata?.turnID,
            itemID: metadata?.itemID,
            role: .system,
            kind: kind,
            content: text,
            createdAt: metadata?.createdAt ?? createdAt ?? Date(),
            sendStatus: .confirmed,
            revision: metadata?.revision
        ), sessionID: sessionID)
    }

    func resolveApproval(_ approval: ApprovalSummary, accepted: Bool, sessionID: String) {
        let text = accepted ? L10n.format("ui.approval_approved_value", approval.title) : L10n.format("ui.approval_rejected_value", approval.title)
        guard var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)] else {
            appendSystem(text, sessionID: sessionID, kind: .approval)
            return
        }
        // 审批结果应该回写到原来的等待卡片上，避免时间线和详情里长期显示“等待审批”。
        if let index = list.lastIndex(where: { message in
            message.kind == .approval && message.content.contains(approval.title)
        }) {
            list[index].content = text
            list[index].updatedAt = Date()
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
            return
        }
        appendSystem(text, sessionID: sessionID, kind: .approval)
    }

    func resolveLatestPendingApproval(sessionID: String) {
        guard var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)],
              let index = list.lastIndex(where: { message in
                  message.kind == .approval && message.content.hasPrefix(L10n.text("ui.awaiting_approval"))
              }) else {
            return
        }
        // 远端审批、turn 完成或中断只告诉我们 request 已清理，不一定告诉最终按钮决策；
        // 用中性文案收口，避免时间线长期停在“等待审批”。
        let title = pendingApprovalTitle(from: list[index].content)
        list[index].content = title.isEmpty ? L10n.text("ui.approval_resolved") : L10n.format("ui.approval_resolved_value", title)
        list[index].updatedAt = Date()
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
    }

    func moveLocalEcho(clientMessageID: ClientMessageID, from sourceSessionID: String, to targetSessionID: String) {
        let scopedSourceSessionID = scopedSessionID(for: sourceSessionID)
        let scopedTargetSessionID = scopedSessionID(for: targetSessionID)
        guard sourceSessionID != targetSessionID,
              var source = messagesByScopedSessionID[scopedSourceSessionID],
              let sourceIndex = messageIndex(clientMessageID: clientMessageID, sessionID: sourceSessionID) else {
            return
        }

        // 新建会话时先挂在本地临时 session；服务端返回真实 session_id 后，
        // 只迁移同一个 client_message_id，避免用户气泡被复制两份。
        var message = source.remove(at: sourceIndex)
        message.sendStatus = .sent

        var target = messagesByScopedSessionID[scopedTargetSessionID] ?? []
        if let targetIndex = messageIndex(clientMessageID: clientMessageID, sessionID: targetSessionID) {
            target[targetIndex].content = message.content
            target[targetIndex].sendStatus = message.sendStatus
            target[targetIndex].turnPayload = target[targetIndex].turnPayload ?? message.turnPayload
            replaceMessagesWithoutEquivalenceCheck(target, sessionID: targetSessionID)
        } else {
            target.append(message)
            setMessages(target, sessionID: targetSessionID)
        }

        if source.isEmpty {
            clearConversationSessionState(scopedSessionID: scopedSourceSessionID, messages: source)
            var next = messagesByScopedSessionID
            next.removeValue(forKey: scopedSourceSessionID)
            messagesByScopedSessionID = next
        } else {
            setMessages(source, sessionID: sourceSessionID)
        }
    }

    private func upsertPendingApprovalMessage(_ text: String, sessionID: String) -> Bool {
        guard var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)] else {
            return false
        }
        let title = pendingApprovalTitle(from: text)
        if let index = list.lastIndex(where: { message in
            guard message.kind == .approval, message.content.hasPrefix(L10n.text("ui.awaiting_approval")) else {
                return false
            }
            return message.content == text || pendingApprovalTitle(from: message.content) == title
        }) {
            if list[index].content != text {
                list[index].content = text
                replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
            }
            return true
        }
        return false
    }

    private func pendingApprovalTitle(from text: String) -> String {
        let prefix = L10n.text("ui.awaiting_approval")
        guard text.hasPrefix(prefix) else {
            return text
        }
        var value = String(text.dropFirst(prefix.count))
        if let range = value.range(of: L10n.format("ui.risk_value", "")) {
            value = String(value[..<range.lowerBound])
        }
        return value
    }

    func resetLiveTranscript(sessionID: String) {
        flushPendingAssistantDelta(sessionID: sessionID)
    }

    func applyAssistantDelta(_ delta: AgentDelta, metadata: AgentEventMetadata, fallbackSessionID: String) {
        let sessionID = metadata.sessionID ?? fallbackSessionID
        guard shouldAccept(metadata: metadata, sessionID: sessionID) else {
            return
        }
        guard !delta.text.isEmpty else {
            return
        }
        let stableID = stableMessageID(prefix: "assistant", metadata: metadata, fallbackSessionID: sessionID)
        guard shouldApplyRevision(metadata.revision, stableID: stableID, sessionID: sessionID) else {
            return
        }
        let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
        let uuid = messageUUIDByStableMessageID[key] ?? UUID()
        messageUUIDByStableMessageID[key] = uuid
        applyAssistantDelta(
            text: delta.text,
            stableID: stableID,
            uuid: uuid,
            clientMessageID: metadata.clientMessageID,
            turnID: metadata.turnID,
            itemID: metadata.itemID,
            kind: delta.kind ?? .message,
            createdAt: metadata.createdAt,
            revision: metadata.revision,
            sessionID: sessionID
        )
    }

    private func applyAssistantDelta(
        text: String,
        stableID: MessageID,
        uuid: UUID,
        clientMessageID: ClientMessageID?,
        turnID: TurnID?,
        itemID: AgentItemID?,
        kind: MessageKind,
        createdAt: Date?,
        revision: ModelRevision?,
        sessionID: String
    ) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        let activityAt = createdAt ?? Date()
        if pendingAssistantDeltasBySessionID[scopedSessionID]?.stableID != stableID {
            flushPendingAssistantDelta(sessionID: sessionID)
        }

        let index = messageIndex(stableID: stableID, sessionID: sessionID) ?? messageIndex(uuid: uuid, sessionID: sessionID)
        guard index != nil else {
            appendAssistantMessage(
                text: text,
                stableID: stableID,
                uuid: uuid,
                clientMessageID: clientMessageID,
                turnID: turnID,
                itemID: itemID,
                kind: kind,
                createdAt: createdAt,
                revision: revision,
                sessionID: sessionID
            )
            return
        }
        if let index,
           messagesByScopedSessionID[scopedSessionID]?[index].sendStatus == .confirmed {
            // item/completed 是权威最终内容；它落地后迟到的 delta 不能再把气泡改回 streaming。
            return
        }

        // 第一段 delta 已经创建了可见气泡；后续文本先合并到 per-session buffer，
        // 以固定节奏批量发布，避免每个 token/分片都触发 SwiftUI 列表重绘。
        if var pending = pendingAssistantDeltasBySessionID[scopedSessionID] {
            pending.text += text
            pending.kind = kind
            pending.revision = revision ?? pending.revision
            pending.updatedAt = latestDate(pending.updatedAt, activityAt)
            pendingAssistantDeltasBySessionID[scopedSessionID] = pending
        } else {
            pendingAssistantDeltasBySessionID[scopedSessionID] = PendingAssistantDelta(
                stableID: stableID,
                uuid: uuid,
                clientMessageID: clientMessageID,
                turnID: turnID,
                itemID: itemID,
                kind: kind,
                createdAt: createdAt ?? activityAt,
                updatedAt: activityAt,
                text: text,
                revision: revision
            )
        }
        scheduleAssistantDeltaFlush(sessionID: sessionID)
    }

    func completeMessage(_ message: AgentMessage, metadata: AgentEventMetadata, fallbackSessionID: String) {
        let sessionID = firstNonEmpty(metadata.sessionID, message.sessionID, fallbackSessionID)
        let scopedSessionID = scopedSessionID(for: sessionID)
        guard shouldAccept(metadata: metadata, sessionID: sessionID) else {
            return
        }
        flushPendingAssistantDelta(sessionID: sessionID)
        let stableID = message.id
        guard shouldApplyCompletedRevision(max(metadata.revision ?? message.revision, message.revision), stableID: stableID, sessionID: sessionID) else {
            return
        }

        let role: ConversationMessage.Role
        let clientMessageID: ClientMessageID?
        switch message.role {
        case .user:
            role = .user
            clientMessageID = message.clientMessageID
        case .assistant:
            role = .assistant
            clientMessageID = nil
        default:
            role = .system
            clientMessageID = nil
        }
        let displayKind: MessageKind = message.role == .tool && message.kind == .message ? .commandSummary : message.kind

        var list = messagesByScopedSessionID[scopedSessionID] ?? []
        let matchingClientIndex = clientMessageID.flatMap { clientMessageID -> Int? in
            guard let index = messageIndex(clientMessageID: clientMessageID, sessionID: sessionID) else {
                return nil
            }
            let boundTurnID = list[index].turnID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let incomingTurnID = message.turnID?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard boundTurnID?.isEmpty != false || boundTurnID == incomingTurnID else {
                return nil
            }
            return index
        }
        let matchingStableIndex = messageIndex(stableID: stableID, sessionID: sessionID).flatMap { index -> Int? in
            guard clientMessageID != nil,
                  list[index].clientMessageID == clientMessageID,
                  let boundTurnID = list[index].turnID,
                  !boundTurnID.isEmpty else { return index }
            return message.turnID == boundTurnID ? index : nil
        }
        if let index = matchingStableIndex ?? matchingClientIndex {
            let previous = list[index]
            list[index].stableID = stableID
            // 服务端 user item 回显可能早于或晚于 turn/start ACK。两条链路都要把
            // 本地气泡升级成 turn-scoped 身份，认证失败等迟到终态才能精确找到原请求。
            if list[index].turnID == nil, let turnID = message.turnID {
                list[index].turnID = turnID
            }
            if list[index].itemID == nil, let itemID = message.itemID {
                list[index].itemID = itemID
            }
            list[index].role = role
            list[index].kind = displayKind
            list[index].content = message.content
            list[index].activityPayload = message.activityPayload ?? list[index].activityPayload
            list[index].sendStatus = message.sendStatus == .failed ? .failed : .confirmed
            list[index].revision = message.revision
            list[index].updatedAt = message.updatedAt ?? metadata.createdAt ?? Date()
            if let turnID = message.turnID {
                list[index].turnLifecycle = turnLifecycleBySessionID[scopedSessionID]?[turnID] ?? list[index].turnLifecycle
            }
            list[index].isTimestampFallback = message.isTimestampFallback
            list[index].userDelivery = nil
            if clientMessageID != nil, message.sendStatus != .failed {
                let retained = list[index].turnPayload?.retainedAfterAcceptedSend()
                if list[index].turnPayload != retained {
                    list[index].turnPayload = retained
                }
            }
            messageUUIDByStableMessageID[stableCacheKey(stableID: stableID, sessionID: sessionID)] = list[index].id
            removeMessageIndex(previous, at: index, sessionID: sessionID)
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
            indexMessage(list[index], at: index, sessionID: sessionID)
        } else {
            let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
            let uuid = messageUUIDByStableMessageID[key] ?? UUID()
            let completedMessage = ConversationMessage(
                id: uuid,
                stableID: stableID,
                clientMessageID: clientMessageID,
                turnID: message.turnID,
                itemID: message.itemID,
                role: role,
                kind: displayKind,
                content: message.content,
                createdAt: message.createdAt ?? Date(),
                updatedAt: message.updatedAt ?? metadata.createdAt,
                sendStatus: message.sendStatus,
                revision: message.revision,
                activityPayload: message.activityPayload,
                turnLifecycle: message.turnID.flatMap { turnLifecycleBySessionID[scopedSessionID]?[$0] },
                isTimestampFallback: message.isTimestampFallback
            )
            // 回放/迟到的 completed 事件带的是流式 item id；thread/read 把 item id 重排成 item-N 后，
            // 同一条内容可能已经以历史投影身份在列表里。找到孪生卡就把真实时间/终态回填给它，
            // 不再追加重复卡（与 mergeHistory 的 turn+文本去重语义保持一致）。
            if let twinIndex = historyProjectedTwinIndex(for: completedMessage, in: list) {
                var twin = list[twinIndex]
                if twin.isTimestampFallback, let liveCreatedAt = message.createdAt {
                    twin.createdAt = liveCreatedAt
                    twin.isTimestampFallback = false
                }
                twin.updatedAt = message.updatedAt ?? metadata.createdAt ?? twin.updatedAt
                twin.sendStatus = message.sendStatus == .failed ? MessageSendStatus.failed : MessageSendStatus.confirmed
                twin.revision = max(message.revision, twin.revision ?? message.revision)
                twin.activityPayload = twin.activityPayload ?? message.activityPayload
                if let turnID = message.turnID {
                    twin.turnLifecycle = turnLifecycleBySessionID[scopedSessionID]?[turnID] ?? twin.turnLifecycle
                }
                list[twinIndex] = twin
                messageUUIDByStableMessageID[key] = twin.id
                // 同一 Item 的 completed 只能更新首次出现的槽位；真实时间是展示信息，不能触发重排。
                replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
                // 流式 id 也指向孪生卡，后续同一事件的补发/查找直接原位命中。
                messageIndexByStableIDBySessionID[scopedSessionID, default: [:]][stableID] = twinIndex
                return
            }
            messageUUIDByStableMessageID[key] = completedMessage.id
            list.append(completedMessage)
            appendMessageWithIndex(completedMessage, list: list, sessionID: sessionID)
        }
    }

    private func historyProjectedTwinIndex(for message: ConversationMessage, in list: [ConversationMessage]) -> Int? {
        guard let key = turnScopedTextMergeKey(for: message) else {
            return nil
        }
        // 只认唯一历史投影孪生卡；同 turn 同文出现多次时宁可保留两条，也不能误删真实输出。
        let candidates = list.indices.filter { index in
            let candidate = list[index]
            guard candidate.timelineOrdinal != nil,
                  candidate.turnID == message.turnID,
                  candidate.id != message.id else {
                return false
            }
            return turnScopedTextMergeKey(for: candidate) == key
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    func markCurrentAssistantCompleted(metadata: AgentEventMetadata, fallbackSessionID: String) {
        let sessionID = metadata.sessionID ?? fallbackSessionID
        let scopedSessionID = scopedSessionID(for: sessionID)
        guard shouldAccept(metadata: metadata, sessionID: sessionID) else {
            return
        }
        flushPendingAssistantDelta(sessionID: sessionID)
        let stableID = stableMessageID(prefix: "assistant", metadata: metadata, fallbackSessionID: sessionID)
        guard var list = messagesByScopedSessionID[scopedSessionID],
              let index = messageIndex(stableID: stableID, sessionID: sessionID) else {
            return
        }
        list[index].sendStatus = .confirmed
        list[index].updatedAt = metadata.createdAt ?? Date()
        if let revision = metadata.revision {
            list[index].revision = revision
        }
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
    }

    func updateTurnLifecycle(
        _ lifecycle: ConversationTurnLifecycle,
        metadata: AgentEventMetadata,
        fallbackSessionID: SessionID
    ) {
        guard let turnID = metadata.turnID, !turnID.isEmpty else {
            return
        }
        let sessionID = metadata.sessionID ?? fallbackSessionID
        let scopedSessionID = scopedSessionID(for: sessionID)
        turnLifecycleBySessionID[scopedSessionID, default: [:]][turnID] = lifecycle
        guard var list = messagesByScopedSessionID[scopedSessionID] else {
            return
        }
        var changed = false
        for index in list.indices where list[index].turnID == turnID && list[index].turnLifecycle != lifecycle {
            list[index].turnLifecycle = lifecycle
            changed = true
        }
        if changed {
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
        }
    }

    func turnLifecycle(
        sessionID: SessionID,
        turnID: TurnID
    ) -> ConversationTurnLifecycle? {
        turnLifecycleBySessionID[scopedSessionID(for: sessionID)]?[turnID]
    }

    private func append(_ message: ConversationMessage, sessionID: String) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        var message = message
        if let turnID = message.turnID, message.turnLifecycle == nil {
            message.turnLifecycle = turnLifecycleBySessionID[scopedSessionID]?[turnID]
        }
        if message.role != .assistant {
            flushPendingAssistantDelta(sessionID: sessionID)
        }
        var list = messagesByScopedSessionID[scopedSessionID] ?? []
        list.append(message)
        appendMessageWithIndex(message, list: list, sessionID: sessionID)
    }

    private func shouldAccept(metadata: AgentEventMetadata, sessionID: String) -> Bool {
        let scopedSessionID = scopedSessionID(for: sessionID)
        guard let seq = metadata.seq else {
            return true
        }
        if let last = lastSeenSeqBySessionID[scopedSessionID], seq <= last {
            return false
        }
        lastSeenSeqBySessionID[scopedSessionID] = seq
        return true
    }

    private func shouldApplyRevision(_ revision: ModelRevision?, stableID: String, sessionID: String) -> Bool {
        guard let revision else {
            return true
        }
        let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
        if let last = revisionByStableMessageID[key], revision <= last {
            return false
        }
        revisionByStableMessageID[key] = revision
        return true
    }

    private func shouldApplyCompletedRevision(_ revision: ModelRevision?, stableID: String, sessionID: String) -> Bool {
        guard let revision else {
            return true
        }
        let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
        if let last = revisionByStableMessageID[key], revision < last {
            return false
        }
        revisionByStableMessageID[key] = revision
        return true
    }

    private func shouldTransitionSendStatus(from current: MessageSendStatus, to next: MessageSendStatus) -> Bool {
        guard current != next else {
            return false
        }
        switch current {
        case .confirmed:
            return false
        case .sent:
            // send accepted 已经表示服务端收到；后到的 failure/sending callback 不能让 UI 倒退。
            return next == .confirmed
        case .failed:
            return next == .sending
        case .uncertain:
            return next == .sent || next == .confirmed || next == .failed || next == .sending
        case .sending, .local:
            return true
        }
    }

    private func firstNonEmpty(_ values: String?...) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private func latestDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.some(let left), .some(let right)):
            return max(left, right)
        case (.some(let left), .none):
            return left
        case (.none, .some(let right)):
            return right
        case (.none, .none):
            return nil
        }
    }

    private func stableCacheKey(stableID: MessageID, sessionID: String) -> StableMessageCacheKey {
        StableMessageCacheKey(scopedSessionID: scopedSessionID(for: sessionID), stableID: stableID)
    }

    private func stableCacheKey(stableID: MessageID, scopedSessionID: ScopedSessionID) -> StableMessageCacheKey {
        StableMessageCacheKey(scopedSessionID: scopedSessionID, stableID: stableID)
    }

    private func stableMessageID(prefix: String, metadata: AgentEventMetadata, fallbackSessionID: String) -> String {
        if let messageID = metadata.messageID {
            return messageID
        }
        if let itemID = metadata.itemID {
            return itemID
        }
        if let turnID = metadata.turnID {
            return "\(prefix):\(fallbackSessionID):\(turnID)"
        }
        return "\(prefix):\(fallbackSessionID):live"
    }

    private func normalizedAssistantTextForDedup(_ text: String) -> String {
        AssistantTextNormalizer.normalizedAssistantTextForDedup(text)
    }

    private func appendAssistantMessage(
        text: String,
        stableID: MessageID,
        uuid: UUID,
        clientMessageID: ClientMessageID?,
        turnID: TurnID?,
        itemID: AgentItemID?,
        kind: MessageKind,
        createdAt: Date?,
        revision: ModelRevision?,
        sessionID: String
    ) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        var list = messagesByScopedSessionID[scopedSessionID] ?? []
        let message = ConversationMessage(
            id: uuid,
            stableID: stableID,
            clientMessageID: clientMessageID,
            turnID: turnID,
            itemID: itemID,
            role: .assistant,
            kind: kind,
            content: text,
            createdAt: createdAt ?? Date(),
            sendStatus: .sending,
            revision: revision,
            turnLifecycle: turnID.flatMap { turnLifecycleBySessionID[scopedSessionID]?[$0] }
        )
        list.append(message)
        appendMessageWithIndex(message, list: list, sessionID: sessionID)
    }

    private func scheduleAssistantDeltaFlush(sessionID: String) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        guard assistantDeltaFlushTasks[scopedSessionID] == nil else {
            return
        }
        let delay = assistantDeltaFlushDelay
        // 延迟 flush 捕获固定 Profile + Session；activate 后不能用新 Profile 重算缓存键。
        assistantDeltaFlushTasks[scopedSessionID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                _ = self?.flushPendingAssistantDelta(scopedSessionID: scopedSessionID)
            }
        }
    }

    @discardableResult
    private func flushPendingAssistantDelta(sessionID: String) -> Bool {
        flushPendingAssistantDelta(scopedSessionID: scopedSessionID(for: sessionID))
    }

    @discardableResult
    private func flushPendingAssistantDelta(scopedSessionID: ScopedSessionID) -> Bool {
        assistantDeltaFlushTasks[scopedSessionID]?.cancel()
        assistantDeltaFlushTasks[scopedSessionID] = nil
        guard let pending = pendingAssistantDeltasBySessionID.removeValue(forKey: scopedSessionID) else {
            return false
        }

        var list = messagesByScopedSessionID[scopedSessionID] ?? []
        if let index = messageIndex(stableID: pending.stableID, scopedSessionID: scopedSessionID)
            ?? messageIndex(uuid: pending.uuid, scopedSessionID: scopedSessionID) {
            let previousRetainedByteCount = estimatedRetainedByteCount(of: list[index])
            list[index].appendContent(pending.text)
            list[index].kind = pending.kind
            list[index].sendStatus = .sending
            list[index].revision = pending.revision ?? list[index].revision
            // 流式 delta 没有 completed 事件时，右下角时间也要表达“最近收到内容”的时间；
            // 只更新 updatedAt，保留 createdAt 作为消息开始时间和排序锚点。
            list[index].updatedAt = latestDate(list[index].updatedAt, pending.updatedAt)
            let retainedByteDelta = estimatedRetainedByteCount(of: list[index]) - previousRetainedByteCount
            replaceMessagesWithoutEquivalenceCheck(
                list,
                scopedSessionID: scopedSessionID,
                rebuildIndexes: false,
                retainedByteDelta: retainedByteDelta
            )
            return true
        }

        let message = ConversationMessage(
            id: pending.uuid,
            stableID: pending.stableID,
            clientMessageID: pending.clientMessageID,
            turnID: pending.turnID,
            itemID: pending.itemID,
            role: .assistant,
            kind: pending.kind,
            content: pending.text,
            createdAt: pending.createdAt ?? Date(),
            updatedAt: pending.updatedAt,
            sendStatus: .sending,
            revision: pending.revision,
            turnLifecycle: pending.turnID.flatMap { turnLifecycleBySessionID[scopedSessionID]?[$0] }
        )
        list.append(message)
        appendMessageWithIndex(message, list: list, scopedSessionID: scopedSessionID)
        return true
    }

    private func appendMessageWithIndex(_ message: ConversationMessage, list: [ConversationMessage], sessionID: String) {
        appendMessageWithIndex(message, list: list, scopedSessionID: scopedSessionID(for: sessionID))
    }

    private func appendMessageWithIndex(
        _ message: ConversationMessage,
        list: [ConversationMessage],
        scopedSessionID: ScopedSessionID
    ) {
        // 新消息只增加自身成本；不要为了更新缓存预算重新扫描整段会话和历史大附件。
        let retainedByteDelta = estimatedRetainedByteCount(of: message)
        // 实时事件通常直接追加。只有旧 Turn 的迟到 completed 需要插回所属 Turn；此处只决定新槽位，
        // 从不移动已有 Item。若上游给出可靠原始时间，可将它插到同 Turn 的估算历史项之前。
        if let turnID = message.turnID,
           let appendedIndex = list.indices.last,
           list[appendedIndex].id == message.id,
           let insertionIndex = liveInsertionIndex(for: message, in: list[..<appendedIndex], turnID: turnID) {
            var reordered = Array(list.dropLast())
            reordered.insert(message, at: insertionIndex)
            replaceMessagesWithoutEquivalenceCheck(
                reordered,
                scopedSessionID: scopedSessionID,
                rebuildIndexes: true,
                retainedByteDelta: retainedByteDelta
            )
            return
        }
        replaceMessagesWithoutEquivalenceCheck(
            list,
            scopedSessionID: scopedSessionID,
            rebuildIndexes: false,
            retainedByteDelta: retainedByteDelta
        )
        indexMessage(message, at: list.count - 1, scopedSessionID: scopedSessionID)
    }

    private func liveInsertionIndex(
        for message: ConversationMessage,
        in existing: ArraySlice<ConversationMessage>,
        turnID: TurnID
    ) -> Int? {
        let sameTurnIndices = existing.indices.filter { existing[$0].turnID == turnID }
        guard let lastSameTurnIndex = sameTurnIndices.last else {
            return nil
        }
        if !message.isTimestampFallback,
           let chronologicalIndex = sameTurnIndices.first(where: { index in
               existing[index].createdAt > message.createdAt
           }) {
            return chronologicalIndex
        }
        let insertionIndex = existing.index(after: lastSameTurnIndex)
        return insertionIndex < existing.endIndex ? insertionIndex : nil
    }

    @discardableResult
    private func setMessages(_ list: [ConversationMessage], sessionID: String, rebuildIndexes: Bool = true) -> Bool {
        setMessages(list, scopedSessionID: scopedSessionID(for: sessionID), rebuildIndexes: rebuildIndexes)
    }

    @discardableResult
    private func setMessages(
        _ list: [ConversationMessage],
        scopedSessionID: ScopedSessionID,
        rebuildIndexes: Bool = true
    ) -> Bool {
        let current = messagesByScopedSessionID[scopedSessionID]
        let messagesChanged = !areMessagesEquivalent(current, list)
        touchConversationSession(scopedSessionID)
        if messagesChanged || retainedByteCountBySessionID[scopedSessionID] == nil {
            updateRetainedByteCount(
                estimatedRetainedByteCount(of: list),
                scopedSessionID: scopedSessionID
            )
        }
        let evictedSessionIDs = trimConversationSessionCacheCandidates(protecting: scopedSessionID)
        guard messagesChanged || !evictedSessionIDs.isEmpty else {
            return false
        }

        var nextMessagesBySessionID = messagesByScopedSessionID
        nextMessagesBySessionID[scopedSessionID] = list
        for evictedSessionID in evictedSessionIDs {
            let evictedMessages = nextMessagesBySessionID.removeValue(forKey: evictedSessionID) ?? []
            clearConversationSessionState(scopedSessionID: evictedSessionID, messages: evictedMessages)
        }

        // 单次写回 @Published 字典，避免一次新增消息又逐个删除旧 session 造成多次 UI 发布。
        messagesByScopedSessionID = nextMessagesBySessionID
        if rebuildIndexes {
            rebuildMessageIndexes(for: scopedSessionID, messages: list)
        }
        return true
    }

    func replaceMessagesWithoutEquivalenceCheck(
        _ list: [ConversationMessage],
        sessionID: String,
        rebuildIndexes: Bool = true,
        retainedByteDelta: Int? = nil
    ) {
        replaceMessagesWithoutEquivalenceCheck(
            list,
            scopedSessionID: scopedSessionID(for: sessionID),
            rebuildIndexes: rebuildIndexes,
            retainedByteDelta: retainedByteDelta
        )
    }

    private func replaceMessagesWithoutEquivalenceCheck(
        _ list: [ConversationMessage],
        scopedSessionID: ScopedSessionID,
        rebuildIndexes: Bool = true,
        retainedByteDelta: Int? = nil
    ) {
        touchConversationSession(scopedSessionID)
        if let retainedByteDelta,
           retainedByteCountBySessionID[scopedSessionID] != nil || messagesByScopedSessionID[scopedSessionID] == nil {
            let current = retainedByteCountBySessionID[scopedSessionID] ?? 0
            updateRetainedByteCount(
                max(0, current + retainedByteDelta),
                scopedSessionID: scopedSessionID
            )
        } else {
            updateRetainedByteCount(
                estimatedRetainedByteCount(of: list),
                scopedSessionID: scopedSessionID
            )
        }
        let evictedSessionIDs = trimConversationSessionCacheCandidates(protecting: scopedSessionID)
        var nextMessagesBySessionID = messagesByScopedSessionID
        nextMessagesBySessionID[scopedSessionID] = list
        for evictedSessionID in evictedSessionIDs {
            let evictedMessages = nextMessagesBySessionID.removeValue(forKey: evictedSessionID) ?? []
            clearConversationSessionState(scopedSessionID: evictedSessionID, messages: evictedMessages)
        }
        messagesByScopedSessionID = nextMessagesBySessionID
        if rebuildIndexes {
            rebuildMessageIndexes(for: scopedSessionID, messages: list)
        }
    }

    private func areMessagesEquivalent(_ lhs: [ConversationMessage]?, _ rhs: [ConversationMessage]) -> Bool {
        guard let lhs else {
            return rhs.isEmpty
        }
        return areMessagesEquivalent(lhs, rhs)
    }

    private func areMessagesEquivalent(_ lhs: [ConversationMessage], _ rhs: [ConversationMessage]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        for index in lhs.indices {
            guard areMessagesEquivalent(lhs[index], rhs[index]) else {
                return false
            }
        }
        return true
    }

    private func areMessagesEquivalent(_ lhs: ConversationMessage, _ rhs: ConversationMessage) -> Bool {
        // Store 热路径只需要判断“渲染与索引语义是否等价”。用固定大小 content digest
        // 代替完整 content 比较，避免长历史/长流式回复重复刷新时反复扫描大字符串。
        lhs.id == rhs.id
            && lhs.stableID == rhs.stableID
            && lhs.clientMessageID == rhs.clientMessageID
            && lhs.turnID == rhs.turnID
            && lhs.itemID == rhs.itemID
            && lhs.role == rhs.role
            && lhs.kind == rhs.kind
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.sendStatus == rhs.sendStatus
            && lhs.revision == rhs.revision
            && lhs.activityPayload == rhs.activityPayload
            && lhs.timelineOrdinal == rhs.timelineOrdinal
            && lhs.turnLifecycle == rhs.turnLifecycle
            && lhs.userDelivery == rhs.userDelivery
            && lhs.isTimestampFallback == rhs.isTimestampFallback
            && lhs.contentDigest == rhs.contentDigest
            && lhs.contentByteCount == rhs.contentByteCount
    }

    private func touchConversationSession(_ scopedSessionID: ScopedSessionID) {
        // 流式回复会高频刷新当前 session。参考 Litter 的 render cache，用单调访问序号记录
        // LRU 热度，普通 touch 只做 O(1) 写字典；只有真正超过保留上限时才扫描找最旧项。
        sessionAccessCounter &+= 1
        sessionAccessTickBySessionID[scopedSessionID] = sessionAccessCounter
    }

    private func trimConversationSessionCacheCandidates(protecting protectedSessionID: ScopedSessionID) -> [ScopedSessionID] {
        var evicted: [ScopedSessionID] = []
        while sessionAccessTickBySessionID.count > 1,
              (sessionAccessTickBySessionID.count > Self.retainedSessionLimit
                  || totalRetainedByteCount > Self.retainedSessionByteLimit),
              let oldest = sessionAccessTickBySessionID
                .filter({ $0.key != protectedSessionID })
                .min(by: { $0.value < $1.value }) {
            sessionAccessTickBySessionID.removeValue(forKey: oldest.key)
            removeRetainedByteCount(scopedSessionID: oldest.key)
            evicted.append(oldest.key)
        }
        return evicted
    }

    private func clearConversationSessionState(scopedSessionID: ScopedSessionID, messages: [ConversationMessage]) {
        loadedHistorySessionIDs.remove(scopedSessionID)
        lastSeenSeqBySessionID.removeValue(forKey: scopedSessionID)
        messageIndexByStableIDBySessionID.removeValue(forKey: scopedSessionID)
        messageIndexByClientMessageIDBySessionID.removeValue(forKey: scopedSessionID)
        messageIndexByUUIDBySessionID.removeValue(forKey: scopedSessionID)
        historyProjectionCacheBySessionID.removeValue(forKey: scopedSessionID)
        historyTimelineMutationBySessionID.removeValue(forKey: scopedSessionID)
        pendingAssistantDeltasBySessionID.removeValue(forKey: scopedSessionID)
        assistantDeltaFlushTasks[scopedSessionID]?.cancel()
        assistantDeltaFlushTasks.removeValue(forKey: scopedSessionID)
        turnLifecycleBySessionID.removeValue(forKey: scopedSessionID)
        sessionAccessTickBySessionID.removeValue(forKey: scopedSessionID)
        removeRetainedByteCount(scopedSessionID: scopedSessionID)

        messageUUIDByStableMessageID = messageUUIDByStableMessageID.filter { $0.key.scopedSessionID != scopedSessionID }
        revisionByStableMessageID = revisionByStableMessageID.filter { $0.key.scopedSessionID != scopedSessionID }
    }

    private func estimatedRetainedByteCount(of messages: [ConversationMessage]) -> Int {
#if DEBUG
        retainedByteFullRecalculationCountForTesting += 1
#endif
        return messages.reduce(into: 0) { result, message in
            result += estimatedRetainedByteCount(of: message)
        }
    }

    private func estimatedRetainedByteCount(of message: ConversationMessage) -> Int {
        var result = message.contentByteCount + 256
        guard let payload = message.turnPayload else {
            return result
        }
        result += payload.input.reduce(into: 0) { payloadBytes, item in
            switch item {
            case .text(let text, let elements):
                payloadBytes += text.utf8.count + elements.count * 64
            case .image(let url, _):
                payloadBytes += url.utf8.count
            case .localImage(let path, _):
                payloadBytes += path.utf8.count
            case .uploadedFile(let file):
                payloadBytes += file.name.utf8.count + file.extractedText.utf8.count
                payloadBytes += file.pageImageDataURLs.reduce(0) { $0 + $1.utf8.count }
            case .skill(let name, let path), .mention(let name, let path):
                payloadBytes += name.utf8.count + path.utf8.count
            }
        }
        return result
    }

    private func updateRetainedByteCount(_ value: Int, scopedSessionID: ScopedSessionID) {
        let previous = retainedByteCountBySessionID[scopedSessionID] ?? 0
        let normalized = max(0, value)
        retainedByteCountBySessionID[scopedSessionID] = normalized
        totalRetainedByteCount = max(0, totalRetainedByteCount + normalized - previous)
    }

    private func removeRetainedByteCount(scopedSessionID: ScopedSessionID) {
        guard let removed = retainedByteCountBySessionID.removeValue(forKey: scopedSessionID) else {
            return
        }
        totalRetainedByteCount = max(0, totalRetainedByteCount - removed)
    }

    private func recordTurnLifecycles(from messages: [ConversationMessage], sessionID: SessionID) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        for message in messages {
            guard let turnID = message.turnID, let lifecycle = message.turnLifecycle else {
                continue
            }
            let existing = turnLifecycleBySessionID[scopedSessionID]?[turnID]
            if existing?.isTerminal == true {
                continue
            }
            turnLifecycleBySessionID[scopedSessionID, default: [:]][turnID] = lifecycle
        }
    }

    private func rebuildMessageIndexes(for sessionID: String, messages: [ConversationMessage]) {
        rebuildMessageIndexes(for: scopedSessionID(for: sessionID), messages: messages)
    }

    private func rebuildMessageIndexes(for scopedSessionID: ScopedSessionID, messages: [ConversationMessage]) {
        var stableIndexes: [MessageID: Int] = [:]
        var clientIndexes: [ClientMessageID: Int] = [:]
        var uuidIndexes: [UUID: Int] = [:]
        stableIndexes.reserveCapacity(messages.count)
        clientIndexes.reserveCapacity(messages.count)
        uuidIndexes.reserveCapacity(messages.count)

        for (index, message) in messages.enumerated() {
            uuidIndexes[message.id] = index
            if let stableID = message.stableID {
                stableIndexes[stableID] = index
            }
            // client_message_id 只用于用户本地回显确认；非 user runtime/assistant 消息带同名字段时不能覆盖用户行索引。
            if message.role == .user, let clientMessageID = message.clientMessageID {
                clientIndexes[clientMessageID] = index
            }
        }

        messageIndexByStableIDBySessionID[scopedSessionID] = stableIndexes
        messageIndexByClientMessageIDBySessionID[scopedSessionID] = clientIndexes
        messageIndexByUUIDBySessionID[scopedSessionID] = uuidIndexes
    }

    private func indexMessage(_ message: ConversationMessage, at index: Int, sessionID: String) {
        indexMessage(message, at: index, scopedSessionID: scopedSessionID(for: sessionID))
    }

    private func indexMessage(_ message: ConversationMessage, at index: Int, scopedSessionID: ScopedSessionID) {
        messageIndexByUUIDBySessionID[scopedSessionID, default: [:]][message.id] = index
        if let stableID = message.stableID {
            messageIndexByStableIDBySessionID[scopedSessionID, default: [:]][stableID] = index
        }
        // client_message_id 只索引 user 行，避免 runtime 过程事件误用同一个 client id 后影响 retry/status。
        if message.role == .user, let clientMessageID = message.clientMessageID {
            messageIndexByClientMessageIDBySessionID[scopedSessionID, default: [:]][clientMessageID] = index
        }
    }

    private func removeMessageIndex(_ message: ConversationMessage, at index: Int, sessionID: String) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        if messageIndexByUUIDBySessionID[scopedSessionID]?[message.id] == index {
            messageIndexByUUIDBySessionID[scopedSessionID]?[message.id] = nil
        }
        if let stableID = message.stableID,
           messageIndexByStableIDBySessionID[scopedSessionID]?[stableID] == index {
            messageIndexByStableIDBySessionID[scopedSessionID]?[stableID] = nil
        }
        // 原地确认本地 echo 时 stableID 会从临时 client id 变成服务端 id；
        // 只删除旧行自己的 client 索引，再由 indexMessage 写回更新后的 user 行索引。
        if message.role == .user,
           let clientMessageID = message.clientMessageID,
           messageIndexByClientMessageIDBySessionID[scopedSessionID]?[clientMessageID] == index {
            messageIndexByClientMessageIDBySessionID[scopedSessionID]?[clientMessageID] = nil
        }
    }

    private func messageIndex(stableID: MessageID, sessionID: String) -> Int? {
        messageIndex(stableID: stableID, scopedSessionID: scopedSessionID(for: sessionID))
    }

    private func messageIndex(stableID: MessageID, scopedSessionID: ScopedSessionID) -> Int? {
        if let direct = messageIndexByStableIDBySessionID[scopedSessionID]?[stableID] {
            return direct
        }
        guard let uuid = messageUUIDByStableMessageID[stableCacheKey(stableID: stableID, scopedSessionID: scopedSessionID)] else {
            return nil
        }
        return messageIndexByUUIDBySessionID[scopedSessionID]?[uuid]
    }

    private func messageIndex(clientMessageID: ClientMessageID, sessionID: String) -> Int? {
        messageIndexByClientMessageIDBySessionID[scopedSessionID(for: sessionID)]?[clientMessageID]
    }

    private func messageIndex(uuid: UUID, sessionID: String) -> Int? {
        messageIndex(uuid: uuid, scopedSessionID: scopedSessionID(for: sessionID))
    }

    private func messageIndex(uuid: UUID, scopedSessionID: ScopedSessionID) -> Int? {
        messageIndexByUUIDBySessionID[scopedSessionID]?[uuid]
    }

    private func mergeHistory(
        _ history: [ConversationMessage],
        with local: [ConversationMessage],
        sessionID: String,
        authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>] = [:],
        snapshotOrdering: ConversationTimelineReducer.SnapshotOrdering = .authoritative
    ) -> [ConversationMessage] {
#if DEBUG
        historyMergeInvocationCountForTesting += 1
#endif
        let result = timelineReducer.rebase(
            snapshot: history,
            current: local,
            authoritativeCompletedTurnItems: authoritativeCompletedTurnItems,
            snapshotOrdering: snapshotOrdering
        )
        for (stableID, uuid) in result.stableIDAliases {
            messageUUIDByStableMessageID[stableCacheKey(stableID: stableID, sessionID: sessionID)] = uuid
        }
#if DEBUG
        if result.ambiguousAliasCount > 0 || result.hadOrderingCycle {
            // 只记录计数，不输出消息正文或命令参数。
            print("[ConversationTimeline] ambiguousAliases=\(result.ambiguousAliasCount) orderingCycle=\(result.hadOrderingCycle)")
        }
#endif
        return result.messages
    }

    private func projectedHistoryMessages(_ history: [CodexHistoryMessage], sessionID: String) -> [ConversationMessage] {
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
    private func turnScopedTextMergeKey(for item: ConversationMessage) -> String? {
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
        case .reasoningSummary, .plan, .commandSummary, .fileChangeSummary:
            return kind.rawValue
        case .message, .commentary, .approval, .userInput, .warning, .error:
            return nil
        }
    }

    func scopedSessionID(for sessionID: SessionID) -> ScopedSessionID {
        ScopedSessionID(profileID: activeProfileID, sessionID: sessionID)
    }

}
