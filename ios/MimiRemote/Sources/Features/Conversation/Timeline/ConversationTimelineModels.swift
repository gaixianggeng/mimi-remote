import Foundation

enum ConversationTimelineProvider: String, Equatable {
    case codex
    case claude
    case deepseek

    init(runtimeProvider: String?) {
        switch CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider) {
        case Self.claude.rawValue:
            self = .claude
        case Self.deepseek.rawValue:
            self = .deepseek
        default:
            self = .codex
        }
    }
}

enum ConversationTimelineItem: Identifiable, Equatable {
    case message(ConversationMessage)
    case activity(ConversationMessage)
    case processGroup(ConversationProcessGroup)
    case processMessage(ConversationMessage)
    case fileChanges(ConversationFileChanges)

    var id: String {
        switch self {
        case .message(let message):
            return "message:\(message.id.uuidString)"
        case .activity(let message):
            return Self.activityID(for: message)
        case .processGroup(let group):
            return group.id
        case .processMessage(let message):
            return "message:\(message.id.uuidString)"
        case .fileChanges(let changes):
            return changes.id
        }
    }

    var isProcessStep: Bool {
        switch self {
        case .processMessage, .activity: true
        default: false
        }
    }

    static func activityID(for message: ConversationMessage) -> String {
        "activity:\(message.id.uuidString)"
    }

    /// 视口锚点使用原始消息 ID，不依赖会随分组重建而变化的派生行 ID。
    var anchorMessageIDs: [UUID] {
        switch self {
        case .message(let message), .activity(let message), .processMessage(let message):
            return [message.id]
        case .processGroup(let group):
            return group.isExpanded ? [] : group.messages.map(\.id)
        case .fileChanges:
            return []
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

/// 过程只保存原始消息的展示投影；展开后仍输出独立 List 行，避免长过程变成一个巨型 cell。
struct ConversationProcessGroup: Identifiable, Equatable {
    let messages: [ConversationMessage]
    let lifecycle: ConversationTurnLifecycle
    let isExpanded: Bool

    var id: String { "process:\(messages[0].id.uuidString)" }
    var turnID: TurnID? { messages.first?.turnID }
    var failedCount: Int { messages.count { $0.activityPayload?.isFailure == true } }
    var fileMessageIDs: [UUID] {
        messages.filter { $0.kind == .fileChangeSummary || $0.activityPayload?.category == .editFile }.map(\.id)
    }
    var title: String {
        switch lifecycle {
        case .failed: L10n.text("ui.process_failed")
        case .interrupted: L10n.text("ui.process_interrupted")
        case .inProgress: L10n.text("ui.view_process")
        case .completed, .unknown: L10n.text("ui.view_process")
        }
    }
}

struct ConversationFileChanges: Identifiable, Equatable {
    let messageIDs: [UUID]
    var id: String { "file-changes:\(messageIDs[0].uuidString)" }
    var firstActivityID: String { "activity:\(messageIDs[0].uuidString)" }
}

/// 非 nil 表示会话仍在执行（包括等审批/输入）；旧运行时可以没有 turnID。
struct ConversationTimelineActiveTurn: Equatable {
    let id: TurnID?
}

struct ConversationTranscriptPresentation: Equatable {
    private(set) var enabledScope: ScopedSessionID?

    func isEnabled(for scope: ScopedSessionID?) -> Bool {
        scope != nil && enabledScope == scope
    }

    mutating func setEnabled(_ enabled: Bool, for scope: ScopedSessionID?) {
        enabledScope = enabled ? scope : nil
    }

    mutating func reset() { enabledScope = nil }
}
