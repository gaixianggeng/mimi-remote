import Foundation

/// 电脑端会话窗口列出的两类会话（#991）。
enum SessionRuntime: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    var brandMark: RuntimeBrandMark {
        switch self {
        case .codex: .openAI
        case .claude: .claude
        }
    }
}

/// 会话窗口里的一行。字段只取列表展示与后续交接需要的部分，不保存会话内容。
struct DesktopSession: Identifiable, Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case idle
        case running
        case waitingForApproval
        case waitingForInput
        case failed
    }

    /// 电脑上另一个进程正占着这条会话。手机端的「电脑上已打开」用的是同一组信号。
    enum Holder: Equatable, Sendable {
        /// Codex 的写入锁在共享服务以外的进程手里，通常是 Codex 桌面版的「This Mac」。
        case otherCodexProcess
        case claudeDesktop
        case claudeTerminal
        case otherClaudeProcess
    }

    let threadID: String
    let runtime: SessionRuntime
    let title: String
    let projectName: String
    let cwd: String
    let updatedAt: Date?
    let activity: Activity
    let holder: Holder?

    /// 两个 runtime 的会话 ID 各自生成，合并列表时要带上 runtime 才唯一。
    var id: String { runtime.rawValue + ":" + threadID }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return title.localizedStandardContains(trimmed)
            || projectName.localizedStandardContains(trimmed)
    }
}

/// 把网关 `thread/list` 的结果翻译成会话行。规则与手机端一致：
/// 标题取 name，没有就取预览第一行；子任务不单独列出；项目名以网关裁剪时附带的为准。
enum DesktopSessionParser {
    struct Page: Equatable, Sendable {
        let sessions: [DesktopSession]
        let nextCursor: String?
    }

    static let untitled = "未命名会话"

    static func page(from result: [String: Any], runtime: SessionRuntime) -> Page {
        let items = result["data"] as? [[String: Any]] ?? []
        let cursor = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Page(sessions: items.compactMap { session(from: $0, runtime: runtime) }, nextCursor: cursor)
    }

    static func session(from thread: [String: Any], runtime: SessionRuntime) -> DesktopSession? {
        guard let id = nonEmpty(thread["id"] as? String), !isSubagent(thread) else { return nil }
        let cwd = nonEmpty(thread["cwd"] as? String) ?? ""
        let annotation = thread["mimiRemote"] as? [String: Any]
        let projectName = nonEmpty(annotation?["projectName"] as? String)
            ?? nonEmpty(URL(fileURLWithPath: cwd).lastPathComponent)
            ?? ""
        return DesktopSession(
            threadID: id,
            runtime: runtime,
            title: title(from: thread),
            projectName: projectName,
            cwd: cwd,
            updatedAt: date(from: thread["updatedAt"]),
            activity: activity(from: thread["status"]),
            holder: holder(from: thread, runtime: runtime)
        )
    }

    static func title(from thread: [String: Any]) -> String {
        if let name = nonEmpty(thread["name"] as? String) { return name }
        let firstLine = (thread["preview"] as? String)?
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)
        return nonEmpty(firstLine) ?? untitled
    }

    /// 只认结构上的父会话或明确的 subAgent 来源；普通 fork 来源不算子任务。
    static func isSubagent(_ thread: [String: Any]) -> Bool {
        if nonEmpty(thread["parentThreadId"] as? String) != nil { return true }
        if (thread["threadSource"] as? String)?.lowercased().hasPrefix("subagent") == true { return true }
        if (thread["source"] as? String)?.lowercased().hasPrefix("subagent") == true { return true }
        if let source = thread["source"] as? [String: Any] {
            return source.keys.contains { $0.lowercased() == "subagent" }
        }
        return false
    }

    static func activity(from value: Any?) -> DesktopSession.Activity {
        let type: String
        var flags: [String] = []
        if let text = value as? String {
            type = text
        } else if let object = value as? [String: Any] {
            type = object["type"] as? String ?? ""
            flags = object["activeFlags"] as? [String] ?? []
        } else {
            return .idle
        }
        switch type {
        case "active":
            if flags.contains("waitingOnApproval") { return .waitingForApproval }
            if flags.contains("waitingOnUserInput") { return .waitingForInput }
            return .running
        case "systemError":
            return .failed
        default:
            return .idle
        }
    }

    static func holder(from thread: [String: Any], runtime: SessionRuntime) -> DesktopSession.Holder? {
        switch runtime {
        case .codex:
            return (thread["writerHeldElsewhere"] as? Bool) == true ? .otherCodexProcess : nil
        case .claude:
            guard let owner = thread["claudeOwner"] as? [String: Any] else { return nil }
            // 配了第三方模型网关的桌面版登记为 claude-desktop-3p（#991 复测），按前缀认。
            let entrypoint = owner["entrypoint"] as? String ?? ""
            if entrypoint.hasPrefix("claude-desktop") { return .claudeDesktop }
            return entrypoint == "cli" ? .claudeTerminal : .otherClaudeProcess
        }
    }

    /// 历史上出现过秒和毫秒两种数字形态，按数量级区分。
    static func date(from value: Any?) -> Date? {
        let number: Double?
        switch value {
        case let value as NSNumber: number = value.doubleValue
        case let value as String: number = Double(value)
        default: number = nil
        }
        guard let number, number.isFinite, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// 按最后活动时间分组：今天、昨天、最近 7 天、更早。没有时间的排在最后。
enum DesktopSessionGrouping {
    struct Section: Identifiable, Equatable {
        let title: String
        let sessions: [DesktopSession]
        var id: String { title }
    }

    static func sections(
        _ sessions: [DesktopSession],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Section] {
        let sorted = sessions.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let titles = ["今天", "昨天", "最近 7 天", "更早"]
        var buckets: [String: [DesktopSession]] = [:]
        for session in sorted {
            let title: String
            switch session.updatedAt {
            case let date? where date >= startOfToday: title = titles[0]
            case let date? where date >= startOfYesterday: title = titles[1]
            case let date? where date >= startOfWeek: title = titles[2]
            default: title = titles[3]
            }
            buckets[title, default: []].append(session)
        }
        return titles.compactMap { title in
            buckets[title].map { Section(title: title, sessions: $0) }
        }
    }
}

/// 每条会话能做的交接操作（#991）。规则集中在这里，界面只负责展示。
enum DesktopSessionActions {
    enum Primary: Equatable {
        case openInClaudeDesktop
        /// 桌面版已经开着这条会话，只把窗口切过去。
        case bringClaudeDesktopForward
        /// 回合还在跑：桌面版接手会让 Mimi 让出进程，正在跑的回合会被打断。
        case waitForTurn
    }

    static func primary(for session: DesktopSession) -> Primary? {
        guard session.runtime == .claude else { return nil }
        switch session.holder {
        case .claudeDesktop: return .bringClaudeDesktopForward
        case .claudeTerminal, .otherClaudeProcess: return nil
        case .otherCodexProcess, nil: break
        }
        return session.activity == .idle || session.activity == .failed ? .openInClaudeDesktop : .waitForTurn
    }

    /// 不能在终端继续的原因；nil 表示可以。
    static func terminalUnavailableReason(for session: DesktopSession) -> String? {
        guard !session.cwd.isEmpty else { return "读不到这条会话的工作目录。" }
        switch session.runtime {
        case .codex:
            // 终端接的是共用服务；锁在别的 Codex 进程手里时接不上。
            return session.holder == .otherCodexProcess ? "电脑上的 Codex 正在使用这条会话。" : nil
        case .claude:
            switch session.holder {
            case .claudeDesktop: return "Claude 桌面版正在使用这条会话。"
            case .claudeTerminal: return "这条会话已经在终端里打开。"
            case .otherClaudeProcess: return "电脑上另一个 Claude 正在使用这条会话。"
            case .otherCodexProcess, nil: break
            }
            // Claude 没有多写入方保护：Mimi 发现终端接手会让出进程，正在跑的回合会被打断。
            return session.activity == .idle || session.activity == .failed ? nil : "这一轮结束后才能在终端继续。"
        }
    }
}
