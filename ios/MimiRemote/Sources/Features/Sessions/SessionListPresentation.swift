import Foundation

/// 历史会话列表使用的日期桶。`displayOrder` 是稳定的扁平日期列表顺序，调用方不需要依赖枚举声明顺序。
enum SessionHistoryDateBucket: CaseIterable, Equatable, Hashable, Sendable {
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case earlier

    /// 日期列表按“近到远”展示；空桶由分组 helper 过滤掉。
    static let displayOrder: [SessionHistoryDateBucket] = [
        .today,
        .yesterday,
        .thisWeek,
        .thisMonth,
        .earlier,
    ]

    static var allCases: [SessionHistoryDateBucket] { displayOrder }
}

/// 一个非空日期分组。会话顺序由输入决定，不在这里按时间二次排序。
struct SessionHistoryDateGroup: Equatable, Hashable, Identifiable {
    let bucket: SessionHistoryDateBucket
    let sessions: [AgentSession]

    var id: SessionHistoryDateBucket { bucket }
}

/// 侧边栏五类会话的稳定身份；rawValue 是跨刷新保持不变的 section id。
enum SessionSidebarSectionKind: String, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case needYou = "need_you"
    case running
    case justCompleted = "just_completed"
    case pinned
    case recent

    static let displayOrder: [SessionSidebarSectionKind] = [
        .needYou,
        .running,
        .justCompleted,
        .pinned,
        .recent,
    ]

    static var allCases: [SessionSidebarSectionKind] { displayOrder }

    var id: String { rawValue }
}

/// 侧边栏一组纯展示数据。helper 统一按活动时间排序，再做稳定去重和优先级归类。
struct SessionSidebarSection: Equatable, Hashable, Identifiable {
    let kind: SessionSidebarSectionKind
    let sessions: [AgentSession]
    /// 保留统一的扩展入口；当前侧边栏分组不会隐藏溢出会话。
    let overflowCount: Int

    init(
        kind: SessionSidebarSectionKind,
        sessions: [AgentSession],
        overflowCount: Int = 0
    ) {
        self.kind = kind
        self.sessions = sessions
        self.overflowCount = max(0, overflowCount)
    }

    var id: String { kind.id }

    /// 兼容调用方更短的命名，同时保留 overflowCount 的明确含义。
    var overflow: Int { overflowCount }
}

/// 会话列表需要的纯展示计算，避免 SwiftUI View 同时承担日期和字符串规则。
enum SessionListPresentation {
    static let sidebarJustCompletedWindow: TimeInterval = 2 * 60 * 60

    /// 按历史时间将会话放入固定日期桶；空桶不返回，桶内保持输入顺序。
    static func historyGroups(
        _ sessions: [AgentSession],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SessionHistoryDateGroup] {
        var sessionsByBucket: [SessionHistoryDateBucket: [AgentSession]] = [:]

        for session in sessions {
            let bucket = dateBucket(for: session, now: now, calendar: calendar)
            sessionsByBucket[bucket, default: []].append(session)
        }

        // 遍历固定顺序而不是字典顺序，确保扁平日期列表不会随进程或哈希种子变化。
        return SessionHistoryDateBucket.displayOrder.compactMap { bucket in
            guard let sessions = sessionsByBucket[bucket], !sessions.isEmpty else { return nil }
            return SessionHistoryDateGroup(bucket: bucket, sessions: sessions)
        }
    }

    /// 具名参数入口，便于 View 将“历史会话”语义与其他会话数组区分开。
    static func historyDateGroups(
        sessions: [AgentSession],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SessionHistoryDateGroup] {
        historyGroups(sessions, now: now, calendar: calendar)
    }

    /// 公开日期判定入口；显式传入 now 和 Calendar，按 Calendar 的本地时区处理跨午夜和周/月边界。
    static func dateBucket(
        for session: AgentSession,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> SessionHistoryDateBucket {
        dateBucket(for: session.recencyAt ?? session.updatedAt ?? session.createdAt, now: now, calendar: calendar)
    }

    /// 无会话模型时的日期判定入口；缺失日期按 earlier 保留，避免历史结果被丢弃。
    static func dateBucket(
        for date: Date?,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> SessionHistoryDateBucket {
        guard let date else { return .earlier }

        // Calendar 的时区决定“本地日”；先判今天和昨天，防止“同一周/同一月”吞掉更具体的分组。
        if calendar.isDate(date, inSameDayAs: now) {
            return .today
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }

        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return .thisWeek
        }

        if calendar.isDate(date, equalTo: now, toGranularity: .month) {
            return .thisMonth
        }

        return .earlier
    }

    /// 将标题转成列表中的单行文本；只生成副本，不修改 AgentSession.title。
    static func displayTitle(_ title: String) -> String {
        let normalizedLineEndings = title.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // 行首 Markdown 标记需要在压平换行前处理，否则第二行会失去“行首”语义。
        let strippedLinePrefixes = normalizedLineEndings
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripLeadingMarkdown(from: String($0)) }
            .joined(separator: " ")

        // 列表仅展示标题文本：成对粗体/下划线标记和反引号不应出现在卡片标题中。
        let withoutInlineMarks = strippedLinePrefixes
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")

        // `isWhitespace` 同时覆盖空格、Tab 和不同换行形式，统一成一个可扫读的间隔。
        return withoutInlineMarks
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 直接从会话读取标题，便于列表调用方避免接触原始字段。
    static func displayTitle(for session: AgentSession) -> String {
        displayTitle(session.title)
    }

    /// SessionListView 的命名入口；保留 displayTitle 作为更通用的字符串 helper。
    static func titleDisplayText(for session: AgentSession) -> String {
        displayTitle(for: session)
    }

    /// 预览沿用标题的单行 Markdown 清洗规则；只返回副本，不修改 session.preview。
    static func previewDisplayText(for session: AgentSession) -> String {
        displayTitle(session.preview ?? "")
    }

    /// 无会话模型时的预览清洗入口，nil 与空字符串都稳定回退为空文本。
    static func previewDisplayText(_ preview: String?) -> String {
        displayTitle(preview ?? "")
    }

    /// 优先展示 dir 的末段；dir 为空时回退 project。路径无法拆出末段时返回原选择值。
    static func directoryTail(for session: AgentSession) -> String {
        let normalizedDir = session.dir.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProject = session.project.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = normalizedDir.isEmpty ? normalizedProject : normalizedDir
        let withoutTrailingSlashes = preferred.replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )

        guard !withoutTrailingSlashes.isEmpty,
              let lastComponent = withoutTrailingSlashes
                .split(separator: "/", omittingEmptySubsequences: true)
                .last,
              !lastComponent.isEmpty else {
            // 例如 "/" 或空字符串没有可提取的 component，原值是稳定且可解释的 fallback。
            return preferred
        }

        return String(lastComponent)
    }

    /// SessionListView 的命名入口；不改变原始 dir/project 字段。
    static func directoryDisplayText(for session: AgentSession) -> String {
        directoryTail(for: session)
    }

    /// 仅在运行中和刚完成分区合并相邻的同项目头像：第一行保留项目标识，
    /// 后续行只保留对齐占位。缺少项目 ID 时不合并，避免把不同的未知项目误当成一组。
    static func shouldShowProjectIcon(
        for session: AgentSession,
        previousSession: AgentSession?,
        in kind: SessionSidebarSectionKind
    ) -> Bool {
        guard kind == .running || kind == .justCompleted,
              let previousSession,
              !session.projectID.isEmpty else {
            return true
        }

        return session.projectID != previousSession.projectID
    }

    /// 按“需要你 → 运行中 → 刚完成 → 置顶 → 最近”建立扁平侧边栏列表。
    /// 先恢复纯活动时间顺序，避免 Store 的置顶投影改变各动态分区内部顺序；重复 ID 只保留第一次出现的会话。
    ///
    /// “刚完成”只读取 Store 观察到终态转换的本地时间，并限制时间窗口和条数。它与
    /// Mimi 本地未读水位无关：Codex Desktop 没有向当前协议回传已读回执，不能让
    /// 本地未读冒充跨 App 完成状态。超过条数上限的完成会话继续参与置顶/最近，不会被静默丢弃。
    static func sidebarSections(
        _ sessions: [AgentSession],
        pinnedIDs: Set<SessionID> = [],
        completionObservedAtByID: [SessionID: Date] = [:],
        now: Date = Date(),
        justCompletedWindow: TimeInterval = SessionListPresentation.sidebarJustCompletedWindow,
        justCompletedLimit: Int = 5,
        recentLimit: Int = 8
    ) -> [SessionSidebarSection] {
        var unclaimed = chronologicallySortedUniqueSessions(sessions)

        func consume(where predicate: (AgentSession) -> Bool) -> [AgentSession] {
            var consumed: [AgentSession] = []
            var remaining: [AgentSession] = []
            consumed.reserveCapacity(unclaimed.count)
            remaining.reserveCapacity(unclaimed.count)

            for session in unclaimed {
                if predicate(session) {
                    consumed.append(session)
                } else {
                    remaining.append(session)
                }
            }
            unclaimed = remaining
            return consumed
        }

        let needYou = consume { session in
            session.pendingApproval != nil
                || session.pendingUserInput != nil
        }
        // 本地草稿代表尚未发送首条消息的新会话，也应固定留在“进行中”，不能被 recent 上限截掉。
        let running = consume { $0.isRunning || $0.isLocalDraft }
        let completionCandidates = unclaimed.enumerated().compactMap { index, session -> (AgentSession, Date, Int)? in
            guard let completionDate = completionObservedAtByID[session.id] else { return nil }
            let age = now.timeIntervalSince(completionDate)
            guard age >= 0 && age <= max(0, justCompletedWindow) else { return nil }
            return (session, completionDate, index)
        }
        .sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.2 < rhs.2
            }
            return lhs.1 > rhs.1
        }
        let justCompleted = completionCandidates
            .prefix(max(0, justCompletedLimit))
            .map { $0.0 }
        let justCompletedIDs = Set(justCompleted.map(\.id))
        unclaimed.removeAll { justCompletedIDs.contains($0.id) }
        let pinned = consume { pinnedIDs.contains($0.id) }
        let recent = Array(unclaimed.prefix(max(0, recentLimit)))

        var sections: [SessionSidebarSection] = []
        sections.reserveCapacity(SessionSidebarSectionKind.displayOrder.count)
        appendSection(.needYou, sessions: needYou, to: &sections)
        appendSection(.running, sessions: running, to: &sections)
        appendSection(.justCompleted, sessions: justCompleted, to: &sections)
        appendSection(.pinned, sessions: pinned, to: &sections)

        // recent 不依赖其它分组存在；因此前组全空时仍会展示第一批最近会话。
        appendSection(.recent, sessions: recent, to: &sections)
        return sections
    }

    /// 具名参数入口，供 View 直接表达“侧边栏输入会话”。
    static func sidebarSections(
        sessions: [AgentSession],
        pinnedIDs: Set<SessionID> = [],
        completionObservedAtByID: [SessionID: Date] = [:],
        now: Date = Date(),
        justCompletedWindow: TimeInterval = SessionListPresentation.sidebarJustCompletedWindow,
        justCompletedLimit: Int = 5,
        recentLimit: Int = 8
    ) -> [SessionSidebarSection] {
        sidebarSections(
            sessions,
            pinnedIDs: pinnedIDs,
            completionObservedAtByID: completionObservedAtByID,
            now: now,
            justCompletedWindow: justCompletedWindow,
            justCompletedLimit: justCompletedLimit,
            recentLimit: recentLimit
        )
    }

    private static func stripLeadingMarkdown(from line: String) -> String {
        var result = line

        // 允许引用、标题、列表标记嵌套在一起；循环只处理行首，正文中的符号保持不变。
        while let range = result.range(
            of: #"^\s*(?:(?:#{1,6}\s*)|(?:>\s*)|(?:[-*+]\s+)|(?:\d+[.)]\s+))"#,
            options: .regularExpression
        ) {
            let stripped = String(result[range.upperBound...])
            guard stripped != result else { break }
            result = stripped
        }

        return result
    }

    private static func stableUniqueSessions(_ sessions: [AgentSession]) -> [AgentSession] {
        var seenIDs: Set<SessionID> = []
        var unique: [AgentSession] = []
        unique.reserveCapacity(sessions.count)

        for session in sessions where seenIDs.insert(session.id).inserted {
            unique.append(session)
        }
        return unique
    }

    /// 按活动时间倒序排列；时间完全相同时保留输入顺序，避免刷新时同秒会话无意义跳动。
    private static func chronologicallySortedUniqueSessions(_ sessions: [AgentSession]) -> [AgentSession] {
        let uniqueSessions = stableUniqueSessions(sessions)
        let inputOrderByID = Dictionary(
            uniqueKeysWithValues: uniqueSessions.enumerated().map { ($0.element.id, $0.offset) }
        )

        return uniqueSessions.sorted { lhs, rhs in
            let leftDate = lhs.recencyAt ?? lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let rightDate = rhs.recencyAt ?? rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            if leftDate == rightDate {
                return (inputOrderByID[lhs.id] ?? 0) < (inputOrderByID[rhs.id] ?? 0)
            }
            return leftDate > rightDate
        }
    }

    private static func appendSection(
        _ kind: SessionSidebarSectionKind,
        sessions: [AgentSession],
        overflowCount: Int = 0,
        to sections: inout [SessionSidebarSection]
    ) {
        guard !sessions.isEmpty else { return }
        sections.append(
            SessionSidebarSection(
                kind: kind,
                sessions: sessions,
                overflowCount: overflowCount
            )
        )
    }
}
