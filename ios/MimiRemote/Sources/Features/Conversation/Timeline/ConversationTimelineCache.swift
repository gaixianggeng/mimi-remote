import Foundation

struct ConversationTimelineSnapshot {
    let items: [ConversationTimelineItem]
    let itemIDs: [String]
    let tailItemID: String?
    var revision = 0

    static let empty = ConversationTimelineSnapshot(items: [], itemIDs: [], tailItemID: nil)
}

final class ConversationTimelineItemCache {
    private var keys: [ConversationTimelineCacheKey] = []
    private var cachedSnapshot = ConversationTimelineSnapshot.empty
    private var scope: ScopedSessionID?

    func snapshot(
        from messages: [ConversationMessage],
        suspendingUpdates: Bool = false,
        scope nextScope: ScopedSessionID? = nil,
        willUpdate: () -> Void = {}
    ) -> ConversationTimelineSnapshot {
        if scope != nextScope {
            removeAll()
            scope = nextScope
        }
        // 用户正在拖动/减速时保留同一份 List 快照。流式输出仍进入 Store，
        // 但不在每个 delta 上重建整条长时间线；滚动结束后一次性追上最新状态。
        if suspendingUpdates, !cachedSnapshot.items.isEmpty {
            return cachedSnapshot
        }

        let nextKeys = messages.map { ConversationTimelineCacheKey(message: $0) }
        guard nextKeys != keys else {
            return cachedSnapshot
        }
        // 先捕获旧列表的阅读位置，再发布新投影；Store 的 mutation 回调可能早于解除冻结。
        if !cachedSnapshot.items.isEmpty {
            willUpdate()
        }
        let nextItems = ConversationTimelineItemBuilder.items(from: messages)
        keys = nextKeys
        cachedSnapshot = ConversationTimelineSnapshot(
            items: nextItems,
            itemIDs: nextItems.map(\.id),
            tailItemID: nextItems.last?.id,
            revision: cachedSnapshot.revision + 1
        )
        return cachedSnapshot
    }

    private func removeAll() {
        keys.removeAll()
        cachedSnapshot = .empty
    }

    var tailItemID: String? {
        cachedSnapshot.tailItemID
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
        // Builder 信任 canonical timeline 的输入顺序；ordinal 本身不在这里排序，
        // 但 reducer 修正序位时它是消息投影的一部分，补齐可避免缓存保留过期快照。
        self.timelineOrdinal = message.timelineOrdinal
        self.isTimestampFallback = message.isTimestampFallback
    }
}
