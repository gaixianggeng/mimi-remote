import Foundation

enum ConversationTimelineProvider: String, Equatable {
    case codex
    case claude

    init(runtimeProvider: String?) {
        let normalized = runtimeProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = normalized == Self.claude.rawValue ? .claude : .codex
    }
}

enum ConversationTimelineItem: Identifiable, Equatable {
    case message(ConversationMessage)
    case activity(ConversationMessage)
    case activityBatch(ConversationActivityBatch)

    var id: String {
        switch self {
        case .message(let message):
            return "message:\(message.id.uuidString)"
        case .activity(let message):
            return Self.activityID(for: message)
        case .activityBatch(let group):
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
        }
    }

    var stableAnchorMessageID: UUID? {
        anchorMessageIDs.first
    }
}

enum ConversationTimelineDurationText {
    static func format(_ duration: TimeInterval) -> String {
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
