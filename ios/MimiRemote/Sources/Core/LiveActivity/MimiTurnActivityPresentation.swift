import Foundation

/// Live Activity 的显示模型（#830）。推送只带状态枚举、计数、开始时间与匿名短标签，
/// 标题、项目与主机名都在这里从 App Group 的通知标题缓存（gh-418）按短标签在本机补全；
/// 查不到时显示通用文案，绝不猜测。
///
/// 这个文件同时编译进 Widget 扩展，只允许依赖 Foundation。
struct MimiTurnActivityPresentation: Equatable {
    /// 本地化入口由调用方提供：App 走 `L10n`，Widget 扩展直接查自己包里的表。
    typealias Localize = (String) -> String

    let title: String
    /// false 表示标题缓存里没有这条会话，`title` 是通用文案。
    let hasSessionTitle: Bool
    /// 项目名；多台 Mac 时附上主机名。没有缓存时为 nil。
    let subtitle: String?
    /// "codex" / "claude" / "deepseek"；没有缓存时为 nil。
    let runtime: String?
    let status: MimiTurnActivityStatus
    let statusText: String
    /// 多会话时的汇总，例如「进行中 2 · 待你处理 1」；单会话为 nil。
    let summaryText: String?
    let startDate: Date
    let deepLink: URL?

    /// 只有运行中与待你处理显示计时；终态没有结束时间，不显示还在走的时长。
    var showsTimer: Bool { status.isActive }

    static func make(
        hostTag: String,
        state: MimiTurnActivityState,
        cache: NotificationTitleCache,
        localize: Localize
    ) -> MimiTurnActivityPresentation {
        let entry = cache.entry(liveActivitySessionTag: state.focusSessionTag)
        let title = entry?.title.isEmpty == false ? entry?.title : nil
        var subtitleParts: [String] = []
        if let project = entry?.project, !project.isEmpty {
            subtitleParts.append(project)
        }
        if cache.showsHostName, let hostName = entry?.hostName, !hostName.isEmpty {
            subtitleParts.append(hostName)
        }
        let summary: String? = state.isMultiSession
            ? String(
                format: localize("live_activity.summary_value"),
                locale: .autoupdatingCurrent,
                String(min(state.runningCount, 99)),
                String(min(state.needsYouCount, 99))
            )
            : nil
        return MimiTurnActivityPresentation(
            title: title ?? localize("live_activity.title.generic"),
            hasSessionTitle: title != nil,
            subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "),
            runtime: entry?.runtime.isEmpty == false ? entry?.runtime : nil,
            status: state.status,
            statusText: localize(statusKey(state.status)),
            summaryText: summary,
            startDate: state.startDate,
            deepLink: MimiTurnActivityLink(hostTag: hostTag, sessionTag: state.focusSessionTag).url
        )
    }

    static func statusKey(_ status: MimiTurnActivityStatus) -> String {
        switch status {
        case .running: return "live_activity.status.running"
        case .needsYou: return "live_activity.status.needs_you"
        case .completed: return "live_activity.status.completed"
        case .failed: return "live_activity.status.failed"
        }
    }
}

extension NotificationTitleCache {
    /// Live Activity 只带 16 位会话标签，不带档案摘要：跨档案按后缀找，恰好命中一条才返回。
    /// 有歧义时保留通用文案，不能把别的会话标题贴到锁屏上。
    func entry(liveActivitySessionTag sessionTag: String) -> Entry? {
        let normalized = sessionTag.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count == 16 else { return nil }
        let suffix = ":" + normalized
        var match: Entry?
        for (key, value) in entries where key.hasSuffix(suffix) {
            if match != nil { return nil }
            match = value
        }
        return match
    }
}

/// 点按 Live Activity 打开 App 的链接。只带两个匿名标签，App 在本机把它们映射回
/// 连接档案与会话；映射不到时只打开 App。
struct MimiTurnActivityLink: Equatable {
    static let scheme = "mimi"
    static let host = "live-activity"

    let hostTag: String
    let sessionTag: String

    init(hostTag: String, sessionTag: String) {
        self.hostTag = hostTag.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.sessionTag = sessionTag.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        let hostTag = items.first { $0.name == "host" }?.value ?? ""
        let sessionTag = items.first { $0.name == "session" }?.value ?? ""
        guard Self.isTag(hostTag, maxLength: 16), Self.isTag(sessionTag, maxLength: 16) else { return nil }
        self.init(hostTag: hostTag, sessionTag: sessionTag)
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "host", value: hostTag),
            URLQueryItem(name: "session", value: sessionTag),
        ]
        return components.url
    }

    private static func isTag(_ value: String, maxLength: Int) -> Bool {
        !value.isEmpty && value.count <= maxLength && value.allSatisfy { $0.isHexDigit }
    }
}
