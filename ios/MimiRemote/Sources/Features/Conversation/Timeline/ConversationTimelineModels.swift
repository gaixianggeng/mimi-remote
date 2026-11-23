import Foundation

enum ConversationTimelineProvider: String, Equatable {
    case codex
    case claude
    case agy
    case deepseek

    init(runtimeProvider: String?) {
        switch CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider) {
        case Self.claude.rawValue:
            self = .claude
        case Self.agy.rawValue:
            self = .agy
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

    var isActivityStep: Bool {
        if case .activity = self { true } else { false }
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
    let failedCount: Int

    init(messages: [ConversationMessage], lifecycle: ConversationTurnLifecycle, isExpanded: Bool) {
        self.messages = messages
        self.lifecycle = lifecycle
        self.isExpanded = isExpanded
        // 消息集合在快照内不可变。只在投影时统计一次，避免行相等性比较和
        // 标题绘制反复扫描已折叠的大量工具消息。
        failedCount = messages.count { $0.activityPayload?.isFailure == true }
    }

    var id: String { "process:\(messages[0].id.uuidString)" }
    var turnID: TurnID? { messages.first?.turnID }
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

/// 时间分隔文案所依赖的日历、时区、语言与 12/24 小时制上下文；只在自然日翻转或格式偏好变化时失效。
struct ConversationTimestampFormatContext: Equatable {
    let dayStart: Date
    let calendarIdentifier: Calendar.Identifier
    let timeZoneIdentifier: String
    let timeZoneSecondsFromGMT: Int
    let localeIdentifier: String
    let hourCycle: Locale.HourCycle
    let localizedTimeFormat: String

    init(
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.dayStart = calendar.startOfDay(for: now)
        self.calendarIdentifier = calendar.identifier
        self.timeZoneIdentifier = calendar.timeZone.identifier
        self.timeZoneSecondsFromGMT = calendar.timeZone.secondsFromGMT(for: now)
        self.localeIdentifier = locale.identifier
        self.hourCycle = locale.hourCycle
        self.localizedTimeFormat = ConversationTimestampSeparatorPolicy.resolvedTimeFormat(for: locale)
    }
}

/// 在跨自然日或对话间隔较长时生成极简居中时间分隔文案，不改动消息分组和快照行结构。
enum ConversationTimestampSeparatorPolicy {
    static let minimumGap: TimeInterval = 10 * 60

    static func separatorLabels(
        for items: [ConversationTimelineItem],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [String: String] {
        var labels: [String: String] = [:]
        var previousMessage: ConversationMessage?
        for item in items {
            guard case .message(let message) = item,
                  message.kind == .message,
                  !message.isTimestampFallback else {
                continue
            }
            if let previous = previousMessage,
               shouldSeparate(from: previous.createdAt, to: message.createdAt, calendar: calendar) {
                labels[item.id] = format(message.createdAt, now: now, calendar: calendar, locale: locale)
            }
            previousMessage = message
        }
        return labels
    }

    static func shouldSeparate(
        from previous: Date,
        to current: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        if !calendar.isDate(previous, inSameDayAs: current) {
            return true
        }
        return current.timeIntervalSince(previous) >= minimumGap
    }

    static func format(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let timeFormat = resolvedTimeFormat(for: locale)
        let timeText = formatterCache.string(
            from: date,
            calendar: calendar,
            locale: locale,
            dateFormat: timeFormat
        )

        if calendar.isDate(date, inSameDayAs: now) {
            return "\(L10n.text("ui.today")) \(timeText)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "\(L10n.text("ui.yesterday")) \(timeText)"
        }

        let dateTemplate = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "MMMd"
            : "yMMMd"
        let dateFormat = DateFormatter.dateFormat(fromTemplate: dateTemplate, options: 0, locale: locale) ?? dateTemplate
        let dateText = formatterCache.string(
            from: date,
            calendar: calendar,
            locale: locale,
            dateFormat: dateFormat
        )
        return "\(dateText) \(timeText)"
    }

    /// 按系统/Locale 的 12/24 小时制偏好解析本地化时分格式（`jm` 模板遵循系统 24 小时开关与 Locale `hours` 标记）。
    static func resolvedTimeFormat(for locale: Locale) -> String {
        DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: locale) ?? "HH:mm"
    }

    /// 当应用内显式固定界面语言（如 `zh-Hans` / `en`）时，保留界面语言的同时继承系统 12/24 小时制偏好。
    static func effectiveLocale(
        appLocale: Locale,
        systemLocale: Locale = .autoupdatingCurrent
    ) -> Locale {
        if appLocale.identifier.contains("hours=") {
            return appLocale
        }
        var components = Locale.Components(locale: appLocale)
        components.hourCycle = systemLocale.hourCycle
        return Locale(components: components)
    }

    /// 供单元测试验证格式化器复用，不暴露可变 `DateFormatter` 实例。
    static var cachedFormatterCountForTesting: Int {
        formatterCache.cachedCount
    }

    /// `DateFormatter` 是可变引用类型；缓存查找与格式化共用同一把锁，保证并发安全并避免重复创建。
    private static let formatterCache = FormatterCache()

    private struct FormatterKey: Hashable {
        let calendarIdentifier: String
        let calendarLocaleIdentifier: String
        let localeIdentifier: String
        let hourCycle: Locale.HourCycle
        let timeZoneIdentifier: String
        let timeZoneSecondsFromGMT: Int
        let dateFormat: String
    }

    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [FormatterKey: DateFormatter] = [:]

        var cachedCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return formatters.count
        }

        func string(
            from date: Date,
            calendar: Calendar,
            locale: Locale,
            dateFormat: String
        ) -> String {
            let timeZone = calendar.timeZone
            let key = FormatterKey(
                calendarIdentifier: String(describing: calendar.identifier),
                calendarLocaleIdentifier: calendar.locale?.identifier ?? "",
                localeIdentifier: locale.identifier,
                hourCycle: locale.hourCycle,
                timeZoneIdentifier: timeZone.identifier,
                timeZoneSecondsFromGMT: timeZone.secondsFromGMT(for: date),
                dateFormat: dateFormat
            )
            lock.lock()
            defer { lock.unlock() }

            let formatter: DateFormatter
            if let cached = formatters[key] {
                formatter = cached
            } else {
                // 控制上限防止测试或异常时区组合无限扩张缓存。
                if formatters.count >= 64 {
                    formatters.removeAll(keepingCapacity: true)
                }
                let configured = DateFormatter()
                configured.calendar = calendar
                configured.timeZone = timeZone
                configured.locale = locale
                configured.dateFormat = dateFormat
                formatters[key] = configured
                formatter = configured
            }
            return formatter.string(from: date)
        }
    }
}
