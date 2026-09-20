import Foundation

struct ConversationTimelineChangeReasons: OptionSet, Equatable {
    let rawValue: UInt8

    static let live = Self(rawValue: 1 << 0)
    static let historyPrepend = Self(rawValue: 1 << 1)
    static let historyEnrichment = Self(rawValue: 1 << 2)
    static let historyReplacement = Self(rawValue: 1 << 3)
    static let localSubmission = Self(rawValue: 1 << 4)
    static let presentation = Self(rawValue: 1 << 5)

    var containsHistoryChange: Bool {
        !intersection([.historyPrepend, .historyEnrichment, .historyReplacement]).isEmpty
    }
}

struct ConversationTimelineSourceVersions: Equatable {
    var lifetime: UInt64 = 0
    var revision: UInt64 = 0
    var live: UInt64 = 0
    var historyPrepend: UInt64 = 0
    var historyEnrichment: UInt64 = 0
    var historyReplacement: UInt64 = 0
    var localSubmission: UInt64 = 0

    mutating func record(_ reasons: ConversationTimelineChangeReasons, revision: UInt64) {
        self.revision = revision
        if reasons.contains(.live) { live = revision }
        if reasons.contains(.historyPrepend) { historyPrepend = revision }
        if reasons.contains(.historyEnrichment) { historyEnrichment = revision }
        if reasons.contains(.historyReplacement) { historyReplacement = revision }
        if reasons.contains(.localSubmission) { localSubmission = revision }
    }

    func changes(since previous: Self) -> ConversationTimelineChangeReasons {
        var reasons: ConversationTimelineChangeReasons = []
        if live > previous.live { reasons.insert(.live) }
        if historyPrepend > previous.historyPrepend { reasons.insert(.historyPrepend) }
        if historyEnrichment > previous.historyEnrichment { reasons.insert(.historyEnrichment) }
        if historyReplacement > previous.historyReplacement { reasons.insert(.historyReplacement) }
        if localSubmission > previous.localSubmission { reasons.insert(.localSubmission) }
        return reasons
    }
}

struct ConversationTimelineSourceSnapshot {
    let scope: ScopedSessionID
    let messages: [ConversationMessage]
    let versions: ConversationTimelineSourceVersions

    var revision: UInt64 { versions.revision }
}

struct ConversationTimelineTailDescriptor: Equatable {
    let rowID: String?
    let messageID: UUID
    let clientMessageID: ClientMessageID?
    let renderFingerprint: ConversationMessageRenderFingerprint
    let role: ConversationMessage.Role
    let kind: MessageKind
    let sendStatus: MessageSendStatus
}

enum ConversationTimelineProjectionMode: Equatable {
    case reused
    case tail
    case full
}

struct ConversationTimelineSnapshot {
    let scope: ScopedSessionID?
    let rows: [ConversationTimelineItem]
    let rowIDs: [String]
    let tail: ConversationTimelineTailDescriptor?
    let changes: ConversationTimelineChangeReasons
    let projectionMode: ConversationTimelineProjectionMode
    let projectedMessageCount: Int
    let revision: Int

    init(
        scope: ScopedSessionID?,
        rows: [ConversationTimelineItem],
        rowIDs: [String],
        tail: ConversationTimelineTailDescriptor?,
        changes: ConversationTimelineChangeReasons,
        projectionMode: ConversationTimelineProjectionMode = .full,
        projectedMessageCount: Int = 0,
        revision: Int
    ) {
        self.scope = scope
        self.rows = rows
        self.rowIDs = rowIDs
        self.tail = tail
        self.changes = changes
        self.projectionMode = projectionMode
        self.projectedMessageCount = projectedMessageCount
        self.revision = revision
    }

    static let empty = ConversationTimelineSnapshot(
        scope: nil,
        rows: [],
        rowIDs: [],
        tail: nil,
        changes: [],
        projectionMode: .reused,
        projectedMessageCount: 0,
        revision: 0
    )

}

private struct ConversationTimelineProjection {
    let rows: [ConversationTimelineItem]
    let mode: ConversationTimelineProjectionMode
    let projectedMessageCount: Int
}

final class ConversationTimelineItemCache {
    private var keys: [ConversationTimelineCacheKey] = []
    private var cachedSnapshot = ConversationTimelineSnapshot.empty
    private var cachedProvider: ConversationTimelineProvider?
    private var cachedShowsDetailedTranscript = false
    private var cachedExpandedProcessMessageIDs: Set<UUID> = []
    private var cachedCollapsedProcessMessageIDs: Set<UUID> = []
    private var cachedActiveTurn: ConversationTimelineActiveTurn?
    private var deliveredVersions = ConversationTimelineSourceVersions()
    private var presentationRevision = 0

    func snapshot(
        from source: ConversationTimelineSourceSnapshot,
        provider: ConversationTimelineProvider = .codex,
        showsDetailedTranscript: Bool = false,
        expandedProcessMessageIDs: Set<UUID> = [],
        collapsedProcessMessageIDs: Set<UUID> = [],
        activeTurn: ConversationTimelineActiveTurn? = nil,
        suspendingUpdates: Bool = false
    ) -> ConversationTimelineSnapshot {
        let scopeChanged = cachedSnapshot.scope != source.scope
        // 滚动控制器在交互期间不捕获阅读锚点，所以这里必须冻结所有会改变行集或行高的投影。
        // 会话状态仍由 View 的 liveStatus 独立更新；交互结束后 isInteracting 变化会触发再次投影。
        // 在构造 key 之前返回，避免长会话即使冻结也扫描全部消息。
        if suspendingUpdates, !scopeChanged, !cachedSnapshot.rows.isEmpty {
            return cachedSnapshot
        }

        let nextKeys = source.messages.map { ConversationTimelineCacheKey(message: $0) }
        let activeTurnChanged = cachedActiveTurn != activeTurn
        let sourceChanged = source.versions != deliveredVersions
        let providerChanged = cachedProvider.map { $0 != provider } ?? false
        let detailModeChanged = cachedShowsDetailedTranscript != showsDetailedTranscript
        let expansionChanged = cachedExpandedProcessMessageIDs != expandedProcessMessageIDs
            || cachedCollapsedProcessMessageIDs != collapsedProcessMessageIDs
        guard scopeChanged || sourceChanged || providerChanged || detailModeChanged || expansionChanged || activeTurnChanged || nextKeys != keys else {
            return cachedSnapshot
        }

        let previousKeys = keys
        let rowsChanged = scopeChanged || providerChanged || detailModeChanged || expansionChanged || activeTurnChanged || nextKeys != previousKeys
        let reasons: ConversationTimelineChangeReasons
        if scopeChanged {
            reasons = source.versions.changes(since: .init())
        } else if deliveredVersions.lifetime != 0,
                  source.versions.lifetime != deliveredVersions.lifetime {
            // scope 清理后会开始新的生命周期。即使冻结期间已立即写入 live，
            // lifetime 仍能保留“旧列表已被替换”的事实，并与新原因叠加。
            reasons = source.versions.changes(since: deliveredVersions).union(.historyReplacement)
        } else {
            reasons = source.versions.changes(since: deliveredVersions)
        }
        // 常见流式更新只重投最后一个用户 turn。历史结构、展示模式和未知边界仍走完整
        // builder，保持分组、文件入口和锚点语义不变。
        let projection = rowsChanged
            ? projectedRows(
                messages: source.messages,
                nextKeys: nextKeys,
                previousKeys: previousKeys,
                reasons: reasons,
                provider: provider,
                showsDetailedTranscript: showsDetailedTranscript,
                expandedProcessMessageIDs: expandedProcessMessageIDs,
                collapsedProcessMessageIDs: collapsedProcessMessageIDs,
                activeTurn: activeTurn,
                scopeChanged: scopeChanged,
                providerChanged: providerChanged,
                detailModeChanged: detailModeChanged,
                expansionChanged: expansionChanged,
                activeTurnChanged: activeTurnChanged
            )
            : ConversationTimelineProjection(
                rows: cachedSnapshot.rows,
                mode: .reused,
                projectedMessageCount: 0
            )
        let nextRows = projection.rows
        let nextRowIDs = rowsChanged ? nextRows.map(\.id) : cachedSnapshot.rowIDs
        var presentationReasons = providerChanged ? reasons.union(.historyReplacement) : reasons
        if detailModeChanged || expansionChanged {
            presentationReasons.formUnion([.historyReplacement, .presentation])
        }
        if activeTurnChanged { presentationReasons.insert(.live) }
        if rowsChanged, !scopeChanged {
            let collapsedGroupIDs = Set(nextRows.compactMap { row -> String? in
                guard case .processGroup(let group) = row, !group.isExpanded else { return nil }
                return group.id
            })
            if cachedSnapshot.rows.contains(where: { row in
                guard case .processGroup(let group) = row else { return false }
                return group.isExpanded && collapsedGroupIDs.contains(group.id)
            }) {
                // 自动收起会移除过程子行：读历史时映射到同消息的过程标题，贴底时继续跟随结果。
                presentationReasons.insert(.historyReplacement)
            }
        }
        let lastMessage = source.messages.last
        let tail = lastMessage.map { message in
            ConversationTimelineTailDescriptor(
                rowID: nextRows.last?.id,
                messageID: message.id,
                clientMessageID: message.clientMessageID,
                renderFingerprint: message.renderFingerprint,
                role: message.role,
                kind: message.kind,
                sendStatus: message.sendStatus
            )
        }

        keys = nextKeys
        cachedProvider = provider
        cachedShowsDetailedTranscript = showsDetailedTranscript
        cachedExpandedProcessMessageIDs = expandedProcessMessageIDs
        cachedCollapsedProcessMessageIDs = collapsedProcessMessageIDs
        cachedActiveTurn = activeTurn
        deliveredVersions = source.versions
        presentationRevision = scopeChanged ? 1 : presentationRevision + 1
        cachedSnapshot = ConversationTimelineSnapshot(
            scope: source.scope,
            rows: nextRows,
            rowIDs: nextRowIDs,
            tail: tail,
            changes: presentationReasons.isEmpty && rowsChanged ? .live : presentationReasons,
            projectionMode: projection.mode,
            projectedMessageCount: projection.projectedMessageCount,
            revision: presentationRevision
        )
        return cachedSnapshot
    }

    private func projectedRows(
        messages: [ConversationMessage],
        nextKeys: [ConversationTimelineCacheKey],
        previousKeys: [ConversationTimelineCacheKey],
        reasons: ConversationTimelineChangeReasons,
        provider: ConversationTimelineProvider,
        showsDetailedTranscript: Bool,
        expandedProcessMessageIDs: Set<UUID>,
        collapsedProcessMessageIDs: Set<UUID>,
        activeTurn: ConversationTimelineActiveTurn?,
        scopeChanged: Bool,
        providerChanged: Bool,
        detailModeChanged: Bool,
        expansionChanged: Bool,
        activeTurnChanged: Bool
    ) -> ConversationTimelineProjection {
        let requiresFullProjection = scopeChanged
            || providerChanged
            || detailModeChanged
            || expansionChanged
            || reasons.containsHistoryChange
        if !requiresFullProjection,
           let projection = projectedTailRows(
               messages: messages,
               nextKeys: nextKeys,
               previousKeys: previousKeys,
               provider: provider,
               showsDetailedTranscript: showsDetailedTranscript,
               expandedProcessMessageIDs: expandedProcessMessageIDs,
               collapsedProcessMessageIDs: collapsedProcessMessageIDs,
               activeTurn: activeTurn,
               activeTurnChanged: activeTurnChanged
           ) {
            return projection
        }
        return ConversationTimelineProjection(
            rows: ConversationTimelineItemBuilder.items(
                from: messages,
                provider: provider,
                showsDetailedTranscript: showsDetailedTranscript,
                expandedProcessMessageIDs: expandedProcessMessageIDs,
                collapsedProcessMessageIDs: collapsedProcessMessageIDs,
                activeTurn: activeTurn
            ),
            mode: .full,
            projectedMessageCount: messages.count
        )
    }

    private func projectedTailRows(
        messages: [ConversationMessage],
        nextKeys: [ConversationTimelineCacheKey],
        previousKeys: [ConversationTimelineCacheKey],
        provider: ConversationTimelineProvider,
        showsDetailedTranscript: Bool,
        expandedProcessMessageIDs: Set<UUID>,
        collapsedProcessMessageIDs: Set<UUID>,
        activeTurn: ConversationTimelineActiveTurn?,
        activeTurnChanged: Bool
    ) -> ConversationTimelineProjection? {
        guard !messages.isEmpty else { return nil }
        let firstChangedIndex = Self.firstChangedIndex(nextKeys, previousKeys)
        guard firstChangedIndex != nil || activeTurnChanged else { return nil }
        let upperBound = min(firstChangedIndex ?? (messages.count - 1), messages.count - 1)
        guard let boundaryIndex = messages[...upperBound].lastIndex(where: { $0.role == .user }) else {
            return nil
        }
        let sharedPrefixCount = min(boundaryIndex, min(nextKeys.count, previousKeys.count))
        guard sharedPrefixCount == boundaryIndex,
              nextKeys[..<boundaryIndex].elementsEqual(previousKeys[..<boundaryIndex]) else {
            return nil
        }

        let prefixRows: [ConversationTimelineItem]
        if boundaryIndex == previousKeys.count {
            // 新用户消息刚追加到尾部，旧投影全部是稳定前缀。
            guard firstChangedIndex == boundaryIndex else { return nil }
            prefixRows = cachedSnapshot.rows
        } else {
            let boundaryRowID = "message:\(messages[boundaryIndex].id.uuidString)"
            guard let boundaryRowIndex = cachedSnapshot.rows.firstIndex(where: { $0.id == boundaryRowID }) else {
                return nil
            }
            prefixRows = Array(cachedSnapshot.rows[..<boundaryRowIndex])
        }

        let tailMessages = Array(messages[boundaryIndex...])
        let tailRows = ConversationTimelineItemBuilder.items(
            from: tailMessages,
            provider: provider,
            showsDetailedTranscript: showsDetailedTranscript,
            expandedProcessMessageIDs: expandedProcessMessageIDs,
            collapsedProcessMessageIDs: collapsedProcessMessageIDs,
            activeTurn: activeTurn
        )
        return ConversationTimelineProjection(
            rows: prefixRows + tailRows,
            mode: boundaryIndex == 0 ? .full : .tail,
            projectedMessageCount: tailMessages.count
        )
    }

    private static func firstChangedIndex(
        _ next: [ConversationTimelineCacheKey],
        _ previous: [ConversationTimelineCacheKey]
    ) -> Int? {
        let sharedCount = min(next.count, previous.count)
        for index in 0..<sharedCount where next[index] != previous[index] {
            return index
        }
        return next.count == previous.count ? nil : sharedCount
    }

    /// 纯 builder/cache 测试入口。业务 UI 应使用带 Store 来源版本的重载。
    func snapshot(
        from messages: [ConversationMessage],
        provider: ConversationTimelineProvider = .codex,
        showsDetailedTranscript: Bool = false,
        expandedProcessMessageIDs: Set<UUID> = [],
        collapsedProcessMessageIDs: Set<UUID> = [],
        activeTurn: ConversationTimelineActiveTurn? = nil,
        suspendingUpdates: Bool = false,
        scope: ScopedSessionID? = nil
    ) -> ConversationTimelineSnapshot {
        let resolvedScope = scope ?? ScopedSessionID(profileID: "", sessionID: "")
        return snapshot(
            from: ConversationTimelineSourceSnapshot(
                scope: resolvedScope,
                messages: messages,
                versions: .init()
            ),
            provider: provider,
            showsDetailedTranscript: showsDetailedTranscript,
            expandedProcessMessageIDs: expandedProcessMessageIDs,
            collapsedProcessMessageIDs: collapsedProcessMessageIDs,
            activeTurn: activeTurn,
            suspendingUpdates: suspendingUpdates
        )
    }
}

private struct ConversationTimelineCacheKey: Equatable {
    let id: UUID
    let stableID: MessageID?
    let clientMessageID: ClientMessageID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    let role: ConversationMessage.Role
    let kind: MessageKind
    let createdAt: Date
    let updatedAt: Date?
    let sendStatus: MessageSendStatus
    let revision: ModelRevision?
    let renderFingerprint: ConversationMessageRenderFingerprint
    let turnPayload: CodexAppServerTurnPayload?
    let activityPayload: ConversationActivityPayload?
    let timelineOrdinal: Int64?
    let turnLifecycle: ConversationTurnLifecycle?
    let userDelivery: UserMessageDelivery?
    let isTimestampFallback: Bool

    init(message: ConversationMessage) {
        self.id = message.id
        self.stableID = message.stableID
        self.clientMessageID = message.clientMessageID
        self.turnID = message.turnID
        self.itemID = message.itemID
        self.role = message.role
        self.kind = message.kind
        self.createdAt = message.createdAt
        self.updatedAt = message.updatedAt
        self.sendStatus = message.sendStatus
        self.revision = message.revision
        self.renderFingerprint = message.renderFingerprint
        self.turnPayload = message.turnPayload
        self.activityPayload = message.activityPayload
        // lifecycle 会直接改变外层组的运行/终态和默认展开状态，必须使缓存失效。
        self.turnLifecycle = message.turnLifecycle
        self.userDelivery = message.userDelivery
        // Builder 信任 canonical timeline 的输入顺序；ordinal 本身不在这里排序，
        // 但 reducer 修正序位时它是消息投影的一部分，补齐可避免缓存保留过期快照。
        self.timelineOrdinal = message.timelineOrdinal
        self.isTimestampFallback = message.isTimestampFallback
    }
}
