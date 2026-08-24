import Foundation
import SwiftUI

struct WorkspaceSessionPresentationKey: Hashable {
    let hostScope: HostScope
    let workspaceID: String
    let workspacePath: String
    let runtimeProvider: String
}

struct WorkspaceRuntimeSessionPageState: Equatable {
    var sessions: [AgentSession] = []
    var nextCursor: String?
    var hasMore = false
    var hasLoadedFirstPage = false
    private var canonicalSessionIDsBeforeFirstPage: Set<SessionID> = []

    mutating func replace(
        with page: SessionsPage,
        canonicalSessionIDsBeforeLoad: Set<SessionID>
    ) {
        sessions = Self.mergedSessions([], page.sessions)
        nextCursor = page.nextCursor
        hasMore = page.hasMore
        hasLoadedFirstPage = true
        canonicalSessionIDsBeforeFirstPage = canonicalSessionIDsBeforeLoad
    }

    mutating func append(_ page: SessionsPage) {
        sessions = Self.mergedSessions(sessions, page.sessions)
        nextCursor = page.nextCursor
        hasMore = page.hasMore
        hasLoadedFirstPage = true
    }

    func reconciledSessions(with canonicalSessions: [AgentSession]) -> [AgentSession] {
        let canonicalByID = Dictionary(uniqueKeysWithValues: canonicalSessions.map { ($0.id, $0) })
        let cachedSessionIDs = Set(sessions.map(\.id))
        let refreshedPageMembers = sessions.map { canonicalByID[$0.id] ?? $0 }
        let newlyObserved = canonicalSessions.filter { session in
            !canonicalSessionIDsBeforeFirstPage.contains(session.id)
                && !cachedSessionIDs.contains(session.id)
        }
        // cursor 与既有分页成员仍由 page state 持有；渲染时只用 canonical Store 刷新字段，
        // 并补入首屏请求之后新观察到的会话，避免 WebSocket 更新被页面副本遮住。
        return Self.mergedSessions(refreshedPageMembers, newlyObserved)
    }

    private static func mergedSessions(
        _ existing: [AgentSession],
        _ incoming: [AgentSession]
    ) -> [AgentSession] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        // 分页边界允许重复 ID；新页字段更新优先，最终只在当前 Runtime 内按时间排序。
        incoming.forEach { byID[$0.id] = $0 }
        return SessionIndexStore.sortedSessions(Array(byID.values))
    }
}

enum WorkspaceSessionPresentation {
    static func needsFirstPagePrefetch(
        cachedPageState: WorkspaceRuntimeSessionPageState?
    ) -> Bool {
        // 调用方先用完整 presentation key 取页；nil 代表这个 Runtime 从未完成首屏。
        cachedPageState?.hasLoadedFirstPage != true
    }

    static func visibleSessions(_ sessions: [AgentSession], limit: Int) -> [AgentSession] {
        Array(sessions.prefix(max(1, limit)))
    }

    static func canLoadMore(
        loadedCount: Int,
        visibleLimit: Int,
        remoteHasMore: Bool
    ) -> Bool {
        loadedCount > visibleLimit || remoteHasMore
    }

    static func nextVisibleLimit(current: Int, pageSize: Int) -> Int {
        max(1, current) + max(1, pageSize)
    }

    static func shouldRequestRemotePage(
        loadedCount: Int,
        targetVisibleLimit: Int,
        remoteHasMore: Bool
    ) -> Bool {
        remoteHasMore && loadedCount < targetVisibleLimit
    }

    static func committedVisibleLimit(current: Int, target: Int, loadedCount: Int) -> Int {
        // 请求失败或远端短页时只提交真实可见数量，避免每次重试都把窗口额度空涨 20。
        max(max(1, current), min(max(1, target), max(0, loadedCount)))
    }
}

/// 泛型视图不能持有静态存储属性，而每行重建 DateFormatter 又很贵；
/// 这两个格式化器与具体视图无关，提到文件级共享一份。
/// 工作区最近会话行的几何。左槽不再放运行时品牌图标：这一屏已经被项目胶囊和
/// Codex/Claude 筛选器各锁定一次，逐行重复的图标是常量，只会和标题抢横向空间。
/// 槽位改成状态导轨，正常会话用圆点，等待/错误使用异常图标。
enum WorkspaceSessionRowMetrics {
    static let horizontalPadding: CGFloat = 14
    static let railWidth: CGFloat = 16
    static let railSpacing: CGFloat = 10
    /// 两行信息保持紧密关联，但用更充足的行间距和上下留白降低长列表压迫感。
    static let contentSpacing: CGFloat = 5
    static let verticalPadding: CGFloat = 12
    /// 标准动态字体下约 68pt；大字体仍由文本自然撑开，不能靠固定高度压缩内容。
    static let minHeight: CGFloat = 68
    static let separatorInset: CGFloat = horizontalPadding + railWidth + railSpacing
}

/// 新建会话按钮浮在列表右下角。它不再与筛选器并排，因此可以画得比原来的 36pt 更实体；
/// 54pt 同时把命中区带到 44pt 之上，不需要再叠一层透明 frame。
enum WorkspaceSessionFabMetrics {
    static let diameter: CGFloat = 54
    /// 回到筛选行里的形态。必须收进 44pt 行高，因此比浮起态小一圈；
    /// 命中区仍由外层 44pt frame 保证。
    static let inlineDiameter: CGFloat = 36
    /// 距屏幕右下两条边的留白，两个方向取同一个值，按钮才落在视觉上的角上。
    static let edgeInset: CGFloat = 20
    /// 列表底部要额外让出的高度，保证最后一行能滚到浮起按钮**之上**被读到，
    /// 而不是永远压在按钮底下。柔化边缘只负责让它淡出，让不让得开是另一回事。
    static var contentBottomAllowance: CGFloat { diameter + edgeInset * 2 }
}

/// 会话按「现在要不要你」分三段。三段共用标题与留白节奏，状态差异由
/// 卡片内的状态导轨和文案表达，避免把分组背景误读成会话状态。
enum WorkspaceSessionGroup: String, CaseIterable {
    case needsAttention
    case running
    case recent

    var title: String {
        switch self {
        case .needsAttention:
            return L10n.text("ui.workspace_group_needs_attention")
        case .running:
            return L10n.text("ui.workspace_group_running")
        case .recent:
            return L10n.text("ui.workspace_group_recent")
        }
    }

    static func of(_ session: AgentSession, status: AgentSessionDisplayStatus) -> WorkspaceSessionGroup {
        // 失败和等待用户都属于「需要处理」，即使会话仍标记为运行中。
        if status.tone == .danger || status.tone == .warning {
            return .needsAttention
        }
        return session.isRunning ? .running : .recent
    }

    static func orderedPopulatedGroups(from groups: Set<Self>) -> [Self] {
        allCases.filter(groups.contains)
    }
}

/// 会话行左槽只表达执行状态，未读改由右端紫点承担，避免同一颗圆点既像状态又像项目色。
enum WorkspaceSessionRailState {
    case failed
    case waiting
    case running

    static func resolve(
        status: AgentSessionDisplayStatus,
        isRunning: Bool
    ) -> WorkspaceSessionRailState? {
        switch status.tone {
        case .danger:
            return .failed
        case .warning:
            return .waiting
        case .active, .complete, .neutral:
            // 普通历史会话不点圆点：空槽本身表示「不需要你」。
            return isRunning ? .running : nil
        }
    }

    func color(tokens: ThemeTokens) -> Color {
        switch self {
        case .failed:
            return .red
        case .waiting:
            return tokens.warning
        case .running:
            return tokens.success
        }
    }
}

/// 分组面板只承担内容归组，不编码会话状态。这样长列表保留一块安静的阅读表面，
/// 状态差异仍由行内导轨和文案表达，不会重新变成一排排漂浮卡片。
struct WorkspaceSessionGroupPanel: ViewModifier {
    let tokens: ThemeTokens

    func body(content: Content) -> some View {
        content
            .workbenchSurface(tokens: tokens, role: .groupedPanel)
    }
}

enum WorkspaceSessionRowFormatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter
    }()

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()
}
