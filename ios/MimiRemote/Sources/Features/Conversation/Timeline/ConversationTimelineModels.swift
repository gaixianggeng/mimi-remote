import Foundation

enum ConversationTimelineItem: Identifiable, Equatable {
    case message(ConversationMessage)
    case activity(ConversationMessage)
    case activityBatch(ConversationActivityBatch)
    case processGroup(ConversationProcessGroup)
    case workGroup(ConversationWorkGroup)

    var id: String {
        switch self {
        case .message(let message):
            return "message:\(message.id.uuidString)"
        case .activity(let message):
            return Self.activityID(for: message)
        case .activityBatch(let group):
            return group.id
        case .processGroup(let group):
            return group.id
        case .workGroup(let group):
            return group.id
        }
    }

    static func activityID(for message: ConversationMessage) -> String {
        "activity:\(message.id.uuidString)"
    }

    /// 视口锚点使用原始消息 ID，不依赖会随分组重建而变化的派生行 ID。
    var anchorMessageIDs: [UUID] {
        switch self {
        case .message(let message), .activity(let message):
            return [message.id]
        case .activityBatch(let group):
            return group.messages.map(\.id)
        case .processGroup(let group):
            return [group.header.id] + group.activities.map(\.id)
        case .workGroup(let group):
            return group.entries.flatMap(\.anchorMessageIDs)
        }
    }

    var stableAnchorMessageID: UUID? {
        anchorMessageIDs.first
    }
}

/// 外层工作流只保存第一遍时间线投影的结果，不重新解释 provider 协议。
/// 这样 Codex 和 Claude 都走同一条 UI 链路，同时保留 commentary 与过程项的原始顺序。
enum ConversationWorkGroupEntry: Identifiable, Equatable {
    case commentary(ConversationMessage)
    case activity(ConversationMessage)
    case activityBatch(ConversationActivityBatch)
    case processGroup(ConversationProcessGroup)

    var id: String {
        switch self {
        case .commentary(let message):
            return "work-commentary:\(message.id.uuidString)"
        case .activity(let message):
            return ConversationTimelineItem.activityID(for: message)
        case .activityBatch(let group):
            return group.id
        case .processGroup(let group):
            return group.id
        }
    }

    var containsRealActivity: Bool {
        switch self {
        case .commentary:
            return false
        case .activity, .activityBatch, .processGroup:
            return true
        }
    }

    /// identity 与最新 reasoning 标题解耦。process group 的第一条真实活动不会随 delta 或标题更新。
    var stableAnchorMessageID: UUID {
        switch self {
        case .commentary(let message), .activity(let message):
            return message.id
        case .activityBatch(let group):
            // Builder 只会创建非空 batch；零 UUID 只是防御性保底，绝不生成随机 identity。
            return group.messages.first?.id ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        case .processGroup(let group):
            return group.activities.first?.id ?? group.header.id
        }
    }

    var anchorMessageIDs: [UUID] {
        switch self {
        case .commentary(let message), .activity(let message):
            return [message.id]
        case .activityBatch(let group):
            return group.messages.map(\.id)
        case .processGroup(let group):
            return [group.header.id] + group.activities.map(\.id)
        }
    }

    var messagesForTiming: [ConversationMessage] {
        switch self {
        case .commentary(let message), .activity(let message):
            return [message]
        case .activityBatch(let group):
            return group.messages
        case .processGroup(let group):
            return [group.header] + group.activities
        }
    }

    var activityCount: Int {
        switch self {
        case .commentary:
            return 0
        case .activity:
            return 1
        case .activityBatch(let group):
            return group.messages.count
        case .processGroup(let group):
            return group.activities.count
        }
    }
}

struct ConversationWorkGroup: Identifiable, Equatable {
    let id: String
    let turnID: TurnID
    let entries: [ConversationWorkGroupEntry]
    let status: ConversationActivityGroupStatus
    let startedAt: Date?
    let endedAt: Date?

    var activityCount: Int {
        entries.reduce(0) { $0 + $1.activityCount }
    }

    var stableAnchorMessageID: UUID? {
        entries.first?.stableAnchorMessageID
    }

    var defaultIsExpanded: Bool {
        switch status {
        case .running, .interrupted, .failed:
            return true
        case .completed:
            return false
        }
    }

    func duration(at now: Date = Date()) -> TimeInterval? {
        guard let startedAt else {
            return nil
        }
        let end = status == .running ? now : endedAt
        guard let end else {
            return nil
        }
        // 跨设备时钟或回放数据可能倒序；展示层不能输出负时长。
        return max(0, end.timeIntervalSince(startedAt))
    }

    func title(at now: Date = Date()) -> String {
        guard let duration = duration(at: now) else {
            switch status {
            case .running:
                return L10n.text("ui.work_in_progress")
            case .completed:
                return L10n.text("ui.work_completed")
            case .interrupted:
                return L10n.text("ui.work_interrupted")
            case .failed:
                return L10n.text("ui.work_failed")
            }
        }
        let durationText = Self.durationText(duration)
        switch status {
        case .running:
            return L10n.format("ui.working_for_value", durationText)
        case .completed:
            return L10n.format("ui.worked_for_value", durationText)
        case .interrupted:
            return L10n.format("ui.work_interrupted_after_value", durationText)
        case .failed:
            return L10n.format("ui.work_failed_after_value", durationText)
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        if seconds >= 3_600 {
            return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
        }
        if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }
}

enum ConversationActivityGroupStatus: Equatable {
    case running
    case completed
    case interrupted
    case failed

    static func resolve(
        turnLifecycle: ConversationTurnLifecycle,
        activities: [ConversationMessage],
        keepsRunningWhileTurnIsActive: Bool
    ) -> ConversationActivityGroupStatus {
        switch turnLifecycle {
        case .failed:
            return .failed
        case .interrupted:
            return .interrupted
        case .completed:
            return .completed
        case .inProgress:
            if keepsRunningWhileTurnIsActive || activities.contains(where: { $0.activityPayload?.isInProgress == true }) {
                return .running
            }
            return .completed
        case .unknown:
            if activities.contains(where: { $0.activityPayload?.isInProgress == true }) {
                return .running
            }
            // 旧 gateway 的实时命令可能没有结构化 payload；仅在它仍是尾部活动时保留运行态。
            if keepsRunningWhileTurnIsActive,
               activities.contains(where: { $0.activityPayload == nil }) {
                return .running
            }
            return .completed
        }
    }
}

struct ConversationActivityBatch: Identifiable, Equatable {
    let id: String
    let messages: [ConversationMessage]
    let kind: ConversationCommandPresentationKind
    let status: ConversationActivityGroupStatus

    var title: String {
        switch status {
        case .running:
            return kind == .exploration
                ? L10n.plural("ui.items_being_explored_count", count: messages.count)
                : L10n.plural("ui.items_being_executed_count", count: messages.count)
        case .completed:
            return kind == .exploration
                ? L10n.plural("ui.items_explored_count", count: messages.count)
                : L10n.plural("ui.items_executed_count", count: messages.count)
        case .interrupted:
            return L10n.plural("ui.items_execution_interrupted_count", count: messages.count)
        case .failed:
            return L10n.plural("ui.items_execution_failed_count", count: messages.count)
        }
    }

    var latestDetail: String? {
        guard let title = messages.last?.activityPayload?.displayTitle else {
            return nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var failedCount: Int {
        messages.count(where: { $0.activityPayload?.isFailure == true })
    }

    var failureDetail: String? {
        guard failedCount > 0, status != .failed else {
            return nil
        }
        return L10n.plural("ui.items_unsuccessful_count", count: failedCount)
    }
}

struct ConversationProcessGroup: Identifiable, Equatable {
    let id: String
    let turnID: TurnID
    let header: ConversationMessage
    let activities: [ConversationMessage]
    let status: ConversationActivityGroupStatus

    var title: String {
        let source = header.activityPayload?.subtitle ?? header.content
        let plainText = ConversationActivityPayload.plainProgressText(source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plainText.isEmpty ? L10n.text("ui.processing_task") : plainText
    }

    var failedCount: Int {
        activities.count(where: { $0.activityPayload?.isFailure == true })
    }

    var failureDetail: String? {
        guard failedCount > 0, status != .failed else {
            return nil
        }
        return L10n.plural("ui.items_unsuccessful_count", count: failedCount)
    }
}
