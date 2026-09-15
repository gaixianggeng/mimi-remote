import Foundation

struct ConversationTimelineChangeReasons: OptionSet, Equatable {
    let rawValue: UInt8

    static let live = Self(rawValue: 1 << 0)
    static let historyPrepend = Self(rawValue: 1 << 1)
    static let historyEnrichment = Self(rawValue: 1 << 2)
    static let historyReplacement = Self(rawValue: 1 << 3)
    static let localSubmission = Self(rawValue: 1 << 4)

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

struct ConversationTimelineSnapshot {
    let scope: ScopedSessionID?
    let rows: [ConversationTimelineItem]
    let rowIDs: [String]
    let tail: ConversationTimelineTailDescriptor?
    let changes: ConversationTimelineChangeReasons
    let revision: Int

    static let empty = ConversationTimelineSnapshot(
        scope: nil,
        rows: [],
        rowIDs: [],
        tail: nil,
        changes: [],
        revision: 0
    )

}

final class ConversationTimelineItemCache {
    private var keys: [ConversationTimelineCacheKey] = []
    private var cachedSnapshot = ConversationTimelineSnapshot.empty
    private var deliveredVersions = ConversationTimelineSourceVersions()
    private var presentationRevision = 0

    func snapshot(
        from source: ConversationTimelineSourceSnapshot,
        suspendingUpdates: Bool = false
    ) -> ConversationTimelineSnapshot {
        let scopeChanged = cachedSnapshot.scope != source.scope
        // 用户正在拖动/减速时保留同一份展示快照。Store 的各类来源版本继续累积，
        // 解冻后再以最后一次已展示版本为基准合并原因，因此 history + live 不会丢失。
        if suspendingUpdates, !scopeChanged, !cachedSnapshot.rows.isEmpty {
            return cachedSnapshot
        }

        let nextKeys = source.messages.map { ConversationTimelineCacheKey(message: $0) }
        let sourceChanged = source.versions != deliveredVersions
        guard scopeChanged || sourceChanged || nextKeys != keys else {
            return cachedSnapshot
        }

        let previousKeys = keys
        let rowsChanged = scopeChanged || nextKeys != previousKeys
        // 来源原因可能变化，但可渲染字段没有变化（例如折叠命令的隐藏输出进度）。
        // 此时仍发布新 revision/reasons，但复用原投影，避免无意义地重建整条时间线。
        let nextRows = rowsChanged
            ? ConversationTimelineItemBuilder.items(from: source.messages)
            : cachedSnapshot.rows
        let nextRowIDs = rowsChanged ? nextRows.map(\.id) : cachedSnapshot.rowIDs
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
        deliveredVersions = source.versions
        presentationRevision = scopeChanged ? 1 : presentationRevision + 1
        cachedSnapshot = ConversationTimelineSnapshot(
            scope: source.scope,
            rows: nextRows,
            rowIDs: nextRowIDs,
            tail: tail,
            changes: reasons.isEmpty && nextKeys != previousKeys ? .live : reasons,
            revision: presentationRevision
        )
        return cachedSnapshot
    }

    /// 纯 builder/cache 测试入口。业务 UI 应使用带 Store 来源版本的重载。
    func snapshot(
        from messages: [ConversationMessage],
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
