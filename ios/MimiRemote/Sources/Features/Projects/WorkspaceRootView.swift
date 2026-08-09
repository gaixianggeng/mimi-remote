import SwiftUI

/// MeeGo / Harmattan 图标底板不是规则圆角矩形，也不是完全对称的超椭圆。
/// 归一化 Bézier 控制点让上下边略平、左右边轻微收腰，并保留四角细微不同的饱满度。
struct WorkspaceIconMeeGoShape: Shape {
    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x,
                y: rect.minY + rect.height * y
            )
        }

        var path = Path()
        path.move(to: point(0.27, 0.045))
        path.addCurve(
            to: point(0.75, 0.035),
            control1: point(0.41, 0.018),
            control2: point(0.61, 0.015)
        )
        path.addCurve(
            to: point(0.955, 0.26),
            control1: point(0.88, 0.045),
            control2: point(0.945, 0.14)
        )
        path.addCurve(
            to: point(0.95, 0.72),
            control1: point(0.985, 0.40),
            control2: point(0.98, 0.59)
        )
        path.addCurve(
            to: point(0.71, 0.955),
            control1: point(0.93, 0.85),
            control2: point(0.84, 0.945)
        )
        path.addCurve(
            to: point(0.26, 0.96),
            control1: point(0.57, 0.985),
            control2: point(0.40, 0.985)
        )
        path.addCurve(
            to: point(0.045, 0.70),
            control1: point(0.14, 0.945),
            control2: point(0.055, 0.84)
        )
        path.addCurve(
            to: point(0.055, 0.25),
            control1: point(0.018, 0.57),
            control2: point(0.025, 0.39)
        )
        path.addCurve(
            to: point(0.27, 0.045),
            control1: point(0.065, 0.13),
            control2: point(0.15, 0.055)
        )
        path.closeSubpath()
        return path
    }
}

/// 项目图标的唯一视觉实现。工作区胶囊、会话项目锚点和侧栏都复用它，
/// 仅通过尺寸形成层级，不再各自维护底色、轮廓和 Emoji 比例。
struct WorkspaceProjectIconTile: View {
    @Environment(\.colorScheme) private var colorScheme

    let content: WorkspaceProjectIconContent
    let size: CGFloat
    let tokens: ThemeTokens

    var body: some View {
        Group {
            switch content {
            case let .character(character):
                Image(character.assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(WorkspaceIconMeeGoShape())
            case let .emoji(emoji):
                Text(emoji)
                    .font(.system(size: size * 0.58))
                    .frame(width: size, height: size)
                    .background(
                        emojiTint(emoji).opacity(colorScheme == .dark ? 0.30 : 0.18),
                        in: WorkspaceIconMeeGoShape()
                    )
            }
        }
        .overlay {
            WorkspaceIconMeeGoShape()
                .stroke(
                    tokens.border.opacity(colorScheme == .dark ? 0.72 : 0.42),
                    lineWidth: size >= 20 ? 0.75 : 0.5
                )
        }
        .accessibilityHidden(true)
    }

    private func emojiTint(_ emoji: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.91, green: 0.63, blue: 0.48),
            Color(red: 0.47, green: 0.67, blue: 0.78),
            Color(red: 0.76, green: 0.64, blue: 0.42),
            Color(red: 0.88, green: 0.72, blue: 0.34),
            Color(red: 0.64, green: 0.70, blue: 0.48),
            Color(red: 0.72, green: 0.53, blue: 0.72),
        ]
        return palette[WorkspaceAppearanceStore.tintIndex(for: emoji, count: palette.count)]
    }
}

enum WorkspaceStripLayout {
    static let horizontalPadding: CGFloat = 24
    /// 44pt 同时是 Apple 的最小命中尺寸和整条控件带的高度：选中项展开成带名称的胶囊，
    /// 其余收缩成头像圆，因此一行就能放下全部工作区，不再需要 138pt 的卡片。
    static let chipHeight: CGFloat = 44
    static let chipSpacing: CGFloat = 8
    /// 胶囊行 + 上下呼吸；工作区身份和状态改由下方状态行承担。
    /// 顶部只收紧上下留白，保留 44pt 胶囊命中区。
    static let stripHeight: CGFloat = 56
    /// 头像在展开与收缩两种形态下保持同一光学尺寸，切换时只有胶囊在变宽。
    static let chipIconSize: CGFloat = 28
    /// 胶囊行、状态行与详情内容共用同一个最大宽度，宽屏下三者左右边界一致。
    static let maxContentWidth: CGFloat = 920

    static func minimumContentWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - horizontalPadding * 2)
    }

    /// 粗略估算一行胶囊的总宽度，用来挑展开档位。
    /// 只需要够准到"多展开一个会不会挤"，估偏了也不会让胶囊够不到——
    /// 外层始终是可横向滚动的，这是它和 ViewThatFits 判定的关键区别。
    static func estimatedRowWidth(names: [String], expandedNames: Set<String>) -> CGFloat {
        guard !names.isEmpty else { return 0 }
        let widths = names.map { name -> CGFloat in
            guard expandedNames.contains(name) else { return chipHeight }
            // 图标 + 间距 + 文字 + 左右内边距。CJK 按一个字 ~14pt、其余 ~7.5pt 估。
            let textWidth = name.reduce(CGFloat.zero) { partial, character in
                partial + (character.isASCII ? 7.5 : 14)
            }
            return chipIconSize + 8 + textWidth + 24
        }
        return widths.reduce(0, +) + chipSpacing * CGFloat(names.count - 1)
    }

    /// 把有限的“展开名称”名额以选中项为中心向两侧发放。
    /// 名额为偶数时优先给右侧，符合从左到右的阅读顺序。
    static func centeredNameWindow(
        projectIDs: [String],
        limit: Int,
        aroundIndex selected: Int?
    ) -> Set<String> {
        guard limit > 0, !projectIDs.isEmpty else { return [] }
        guard limit < projectIDs.count else { return Set(projectIDs) }

        let center = selected.map { min(max($0, 0), projectIDs.count - 1) } ?? 0
        var lower = center
        var upper = center
        var chosen = [center]

        while chosen.count < limit {
            let canGoUpper = upper + 1 < projectIDs.count
            let canGoLower = lower - 1 >= 0
            guard canGoUpper || canGoLower else { break }

            if canGoUpper, chosen.count.isMultiple(of: 2) == false || !canGoLower {
                upper += 1
                chosen.append(upper)
            } else if canGoLower {
                lower -= 1
                chosen.append(lower)
            }
        }

        return Set(chosen.map { projectIDs[$0] })
    }
}

enum WorkspaceSessionAgeBoundary {
    static let staleInterval: TimeInterval = 12 * 60 * 60

    static func firstStaleIndex(
        in sessions: [AgentSession],
        excludingSessionIDs: Set<SessionID> = [],
        now: Date = Date()
    ) -> Int? {
        // 工作区会话已经按 SessionIndexStore.orderingDate 倒序排列；
        // 置顶会话可以跨越时间分组，因此排除后再寻找普通会话的 12 小时边界。
        sessions.firstIndex { session in
            !excludingSessionIDs.contains(session.id) &&
            now.timeIntervalSince(SessionIndexStore.orderingDate(for: session)) > staleInterval
        }
    }
}

/// 会话页只在分支真正能帮助区分 worktree 时逐行展示它。
///
/// 同一页只有一个非空分支时，重复的分支元数据会挤压标题和预览；
/// 出现多个分支时才保留每行的分支名，让它承担 worktree 区分作用。
enum WorkspaceSessionBranchPresentation {
    static func normalizedBranch(_ branch: String?) -> String? {
        let value = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func shouldShowBranches(_ branches: [String?]) -> Bool {
        Set(branches.compactMap(normalizedBranch)).count > 1
    }

    static func branchToDisplay(_ branch: String?, among branches: [String?]) -> String? {
        guard shouldShowBranches(branches) else { return nil }
        return normalizedBranch(branch)
    }
}

/// View 层只记录“哪次调用仍有资格回写”，真实请求复用继续由 SessionStore single-flight 决定。
struct WorkspaceSessionLoadInvocationTokens {
    private var latestByKey: [WorkspaceSessionPresentationKey: UUID] = [:]

    @discardableResult
    mutating func begin(for key: WorkspaceSessionPresentationKey) -> UUID {
        let invocationID = UUID()
        latestByKey[key] = invocationID
        return invocationID
    }

    func isCurrent(_ invocationID: UUID, for key: WorkspaceSessionPresentationKey) -> Bool {
        latestByKey[key] == invocationID
    }

    mutating func remove(where shouldRemove: (WorkspaceSessionPresentationKey) -> Bool) {
        latestByKey = latestByKey.filter { !shouldRemove($0.key) }
    }
}

enum WorkspaceCatalogLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum WorkspaceCatalogLoadResult: Equatable {
    case loaded
    case cancelled
    case failed(String)
}

enum WorkspaceSessionLoadFailureDisposition: Equatable {
    case cancelled
    case failed(String)
}

/// Session 首屏和 catalog/open 使用同一套明确取消分类，避免 URL transport 取消落入用户错误态。
func workspaceSessionLoadFailureDisposition(_ error: Error) -> WorkspaceSessionLoadFailureDisposition {
    isCancellationError(error) ? .cancelled : .failed(error.localizedDescription)
}

struct WorkspaceCatalogRefreshScope: Equatable {
    let hostScope: HostScope
    let credentialsSuspended: Bool
}

struct WorkspaceSessionRefreshScope: Equatable {
    let presentationKey: WorkspaceSessionPresentationKey?
    let needsInitialLoad: Bool
}

/// Catalog 没有底层 single-flight；这里只隔离 View 调用的提交权，避免旧请求回写或把取消留成永久 loading。
struct WorkspaceCatalogLoadCoordinator {
    private(set) var state: WorkspaceCatalogLoadState = .idle
    private var currentInvocationID: UUID?

    @discardableResult
    mutating func begin() -> UUID {
        let invocationID = UUID()
        currentInvocationID = invocationID
        state = .loading
        return invocationID
    }

    func isCurrent(_ invocationID: UUID) -> Bool {
        currentInvocationID == invocationID
    }

    @discardableResult
    mutating func complete(
        _ invocationID: UUID,
        result: WorkspaceCatalogLoadResult,
        hasCachedProjects: Bool
    ) -> Bool {
        guard isCurrent(invocationID) else {
            return false
        }
        switch result {
        case .loaded:
            state = .loaded
        case .cancelled:
            state = hasCachedProjects ? .loaded : .idle
        case .failed(let message):
            state = .failed(message)
        }
        return true
    }
}

private struct WorkspaceGitInspectionTarget: Identifiable {
    let id: String
    let name: String
    let path: String

    init(project: AgentProject) {
        id = project.id
        name = project.name
        path = project.path
    }
}

/// 工作区只维护本地浏览选择。只有用户明确进入会话或新建会话时，才交给 SessionStore 改变活动上下文。
struct WorkspaceRootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var appearanceStore: WorkspaceAppearanceStore

    let onStartSession: (AgentProject, WorkspaceSessionRuntimeChoice) -> Void
    let onOpenSession: (AgentSession) -> Void
    let manageConnections: (() -> Void)?
    let embedsNavigationStack: Bool
    private let currentDate: () -> Date

    @State private var selectedWorkspaceID: String?
    @State private var selectedSessionRuntime: WorkspaceSessionRuntimeChoice = .codex
    @State private var catalogLoad = WorkspaceCatalogLoadCoordinator()
    @State private var runtimeSessionPagesByKey: [WorkspaceSessionPresentationKey: WorkspaceRuntimeSessionPageState] = [:]
    @State private var sessionLoadStates: [WorkspaceSessionPresentationKey: WorkspaceSessionLoadState] = [:]
    @State private var sessionLoadInvocationTokens = WorkspaceSessionLoadInvocationTokens()
    /// canonical Store 可以持有超采样得到的额外 root；这里仅记录每个工作区已经向用户展开多少条。
    /// key 带 HostScope、路径和 Runtime，避免跨 Mac、目录身份或引擎复用旧窗口。
    @State private var workspaceSessionVisibleLimitByKey: [WorkspaceSessionPresentationKey: Int] = [:]
    @State private var isPresentingOpenWorkspace = false
    @State private var gitInspectionTarget: WorkspaceGitInspectionTarget?
    /// 胶囊行的真实可用宽度，用来挑展开档位。0 表示尚未量到。
    @State private var measuredStripWidth: CGFloat = 0

    init(
        onStartSession: @escaping (AgentProject, WorkspaceSessionRuntimeChoice) -> Void,
        onOpenSession: @escaping (AgentSession) -> Void = { _ in },
        manageConnections: (() -> Void)? = nil,
        embedsNavigationStack: Bool = true,
        appearanceStore: WorkspaceAppearanceStore? = nil,
        initialWorkspaceID: String? = nil,
        currentDate: @escaping () -> Date = Date.init
    ) {
        self.onStartSession = onStartSession
        self.onOpenSession = onOpenSession
        self.manageConnections = manageConnections
        self.embedsNavigationStack = embedsNavigationStack
        self.currentDate = currentDate
        _appearanceStore = StateObject(wrappedValue: appearanceStore ?? WorkspaceAppearanceStore())
        // 正常入口仍由 synchronizeSelection 恢复选择；显式初值只服务于确定性的预览和视觉快照。
        _selectedWorkspaceID = State(initialValue: initialWorkspaceID)
    }

    static func shouldEmbedNavigationStack(usesCompactNavigation: Bool) -> Bool {
        // 紧凑布局的 destination 已经在根导航栈内；只有独立/宽屏入口需要自己建栈。
        !usesCompactNavigation
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let catalogRefreshScope = WorkspaceCatalogRefreshScope(
            hostScope: appStore.activeHostScope,
            credentialsSuspended: appStore.isCredentialMemorySuspended
        )
        let selectedSessionPresentationKey = selectedProject.map(workspaceSessionPresentationKey(for:))
        let sessionRefreshScope = WorkspaceSessionRefreshScope(
            presentationKey: selectedSessionPresentationKey,
            needsInitialLoad: selectedSessionPresentationKey.map {
                runtimeSessionPagesByKey[$0]?.hasLoadedFirstPage != true
            } ?? false
        )

        Group {
            if embedsNavigationStack {
                NavigationStack {
                    navigationContent(tokens: tokens)
                }
            } else {
                // iPhone 紧凑布局已由 UnifiedWorkbenchShell 持有绑定 path 的导航栈。
                // 这里再嵌套 NavigationStack 会让 SwiftUI 在首次打开工作区时同时重算两层导航状态。
                navigationContent(tokens: tokens)
            }
        }
        .task(id: catalogRefreshScope) {
            // 后台会主动清空内存凭据；恢复完成发布 false 后，完整 scope 会确定性触发一次新刷新。
            guard !catalogRefreshScope.credentialsSuspended else {
                return
            }
            migrateLegacyWorkspaceAppearance()
            synchronizeSelection()
            // 每次进入工作区都做轻量目录同步，同时执行旧版自动候选数据清理；
            // 该请求不改变当前会话和 WebSocket，上层选择保持稳定。
            await refreshCatalog()
            synchronizeSelection()
        }
        .onChange(of: appStore.connectionProfiles) { _, _ in
            // 这里只重试本地偏好迁移，不重新请求目录。删除或修改重复 endpoint 后，
            // 当前 Profile 一旦成为唯一匹配，就应立即恢复旧版自定义图标值。
            migrateLegacyWorkspaceAppearance()
        }
        .task {
            // 两个新建入口先稳定渲染；Claude 通道能力独立在后台刷新，不能让网络往返
            // 决定按钮何时才出现在布局里。
            await sessionStore.refreshAppServerModelOptions()
        }
        .task(id: sessionRefreshScope) {
            guard sessionRefreshScope.needsInitialLoad,
                  let presentationKey = sessionRefreshScope.presentationKey,
                  let project = sessionStore.sidebarProjects.first(where: {
                      $0.id == presentationKey.workspaceID && $0.path == presentationKey.workspacePath
                  })
            else { return }
            await refreshWorkspaceSessions(project: project, presentationKey: presentationKey)
        }
        .task(id: neighborPrefetchScope) {
            // 当前页优先：等它自己的 task 先占住 single-flight，再补相邻页。
            for project in neighborWorkspaceProjects {
                guard !Task.isCancelled else { return }
                let presentationKey = workspaceSessionPresentationKey(for: project)
                // 全局工作区可能已由会话库加载，但当前 Runtime 仍没有独立首屏；
                // 预取必须按 Host、路径和 Runtime 的完整 key 判断，不能复用全局完成状态。
                guard WorkspaceSessionPresentation.needsFirstPagePrefetch(
                    cachedPageState: runtimeSessionPagesByKey[presentationKey]
                ) else {
                    continue
                }
                await refreshWorkspaceSessions(
                    project: project,
                    presentationKey: presentationKey
                )
            }
        }
        .onChange(of: sessionStore.sidebarProjects.map(\.id)) { _, _ in
            synchronizeSelection()
        }
        .onChange(of: sessionStore.hasClaudeRuntimeChannel) { _, isAvailable in
            if !isAvailable, selectedSessionRuntime == .claude {
                selectedSessionRuntime = .codex
            }
        }
        .sheet(isPresented: $isPresentingOpenWorkspace) {
            OpenWorkspaceSheet { workspaceID in
                // 工作区页使用本地浏览选择；Sheet 成功打开目录后要显式切到新工作区，
                // 不能依赖全局 selectedProjectID，否则会破坏浏览选择与会话上下文的解耦。
                selectedWorkspaceID = workspaceID
            }
        }
        .sheet(item: $gitInspectionTarget) { target in
            NavigationStack {
                DiffPanelView(workspacePath: target.path)
                    .navigationTitle(target.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.text("ui.complete")) {
                                gitInspectionTarget = nil
                            }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        .background(tokens.background.ignoresSafeArea())
    }

    private func migrateLegacyWorkspaceAppearance() {
        appearanceStore.migrateLegacyValueIfNeeded(
            profileID: appStore.activeHostScope.profileID,
            endpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
    }

    /// iPad 紧凑导航需要把设备入口放进系统顶栏与会话页对齐；iPhone 保留原来的
    /// 工作区胶囊行布局，避免窄屏导航出现一条额外的顶栏占位。
    private var usesTabletTopBarHostSwitcher: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && manageConnections != nil
    }

    @ViewBuilder
    private func navigationContent(tokens: ThemeTokens) -> some View {
        if usesTabletTopBarHostSwitcher, let manageConnections {
            // 会话页把设备切换器放在顶栏左侧；工作区也复用同一位置，避免切换 Tab 时垂直跳动。
            workspaceBrowser(tokens: tokens)
                .accessibilityIdentifier("workspace.browser")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        HostSwitcherMenu(
                            presentation: .toolbar,
                            manageConnections: manageConnections
                        )
                    }
                    // 与会话页保持相同的顶栏分组间距，避免设备入口和其他 leading 控件粘连。
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarLeading)
                    }
                }
        } else {
            // 宽屏由侧栏承载设备入口，工作区内容列继续隐藏空导航栏，避免多出一条空白顶栏。
            workspaceBrowser(tokens: tokens)
                .accessibilityIdentifier("workspace.browser")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func openDirectoryButton(tokens: ThemeTokens) -> some View {
        Button {
            isPresentingOpenWorkspace = true
        } label: {
            WorkbenchChromeIcon(systemName: "folder.badge.plus")
                .workbenchChromeCircle(tokens: tokens)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .accessibilityLabel(L10n.text("ui.open_directory"))
        .accessibilityIdentifier("workspace.toolbar.openDirectory")
    }

    @ViewBuilder
    private func workspaceBrowser(tokens: ThemeTokens) -> some View {
        if sessionStore.sidebarProjects.isEmpty {
            if catalogLoad.state == .loading {
                workspaceLoadingState(tokens: tokens)
            } else {
                workspaceEmptyState(tokens: tokens)
            }
        } else {
            VStack(spacing: 0) {
                workspaceStrip(tokens: tokens)

                // 原来这里是一条硬分割线。控件带与内容之间的边界改由 scroll edge effect 表达，
                // 选中工作区的分支、Git 状态和活跃时间收进一行状态摘要。
                projectPager(tokens: tokens)
            }
            .background(tokens.background.ignoresSafeArea())
        }
    }

    /// 每个工作区一页，横向分页切换。用 ScrollView 的分页行为而不是 TabView：
    /// `scrollPosition(id:)` 是连续绑定，胶囊行能跟着滑动过程走；TabView 的 selection
    /// 要等落定才更新，滑到一半上方胶囊不动、松手才跳，正好丢掉跟手感。
    /// 分页物理特性（跟手、速度投射、可中断反向）由系统提供，不自己写 DragGesture。
    private func projectPager(tokens: ThemeTokens) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(sessionStore.sidebarProjects) { project in
                    // 状态行下沉进详情视图，与会话列表共用同一组内边距并紧贴列表：
                    // 它描述的是“这个列表属于哪个工作区”，悬在胶囊行下方会读成孤立的元数据。
                    workspaceDetail(
                        project: project,
                        showsStatusLine: sessionStore.isWorkspaceUnavailable(project.id)
                    ) {
                        workspaceStatusLine(project: project, tokens: tokens)
                    }
                    .refreshable {
                        await refreshWorkspaceContent(projectID: project.id)
                    }
                    .containerRelativeFrame(.horizontal)
                    // 离开视口中心的页面按进度缩小并变淡。scrollTransition 的相位跟着
                    // 手指走，所以缩放是 1:1 可中断的，而不是松手后再播一段固定动画。
                    .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                        content
                            .scaleEffect(phase.isIdentity ? 1 : 0.93)
                            .opacity(phase.isIdentity ? 1 : 0.55)
                    }
                    .id(project.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        // 直接绑定唯一的选择来源：点胶囊会滚动分页，滑动分页会回写胶囊选中态。
        .scrollPosition(id: $selectedWorkspaceID, anchor: .center)
        .scrollIndicators(.hidden)
    }

    private func workspaceLoadingState(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            workspaceStrip(tokens: tokens)

            Divider()
                .overlay(tokens.border.opacity(0.7))

            ProgressView(L10n.text("ui.loading_workspace"))
                .font(themeStore.uiFont(.callout, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .tint(tokens.primaryAction)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(tokens.background.ignoresSafeArea())
        .accessibilityIdentifier("workspace.loadingState")
    }

    private func workspaceEmptyState(tokens: ThemeTokens) -> some View {
        let isFailure: Bool
        if case .failed = catalogLoad.state {
            isFailure = true
        } else {
            isFailure = false
        }
        let tint = isFailure ? tokens.warning : tokens.primaryAction

        return VStack(spacing: 0) {
            Spacer(minLength: 40)

            VStack(spacing: 18) {
                Image(systemName: emptyWorkspaceSymbol)
                    .font(themeStore.uiFont(size: 28, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 64, height: 64)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: 7) {
                    Text(emptyWorkspaceTitle)
                        .font(themeStore.uiFont(.title3, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)

                    Text(emptyWorkspaceMessage)
                        .font(themeStore.uiFont(.callout))
                        .foregroundStyle(tokens.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }

                Button {
                    if isFailure {
                        Task { await refreshCatalog() }
                    } else {
                        isPresentingOpenWorkspace = true
                    }
                } label: {
                    Label(isFailure ? L10n.text("ui.reload") : L10n.text("ui.open_directory"), systemImage: isFailure ? "arrow.clockwise" : "folder.badge.plus")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(tokens.primaryAction)
                .accessibilityIdentifier("workspace.emptyAction")
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.emptyState")
    }

    private func workspaceStrip(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            if !usesTabletTopBarHostSwitcher, let manageConnections {
                // iPhone 保留原有工作区布局：设备入口与工作区文件夹胶囊共用这一行。
                HostSwitcherMenu(
                    presentation: .toolbar,
                    manageConnections: manageConnections
                )
                .workbenchChromeCircle(tokens: tokens)
            }

            ScrollViewReader { proxy in
                // 收缩成头像是一种压缩手法：只有横向真的放不下时才该发生，
                // 而且必须渐进——只有“全展开”和“只展开选中项”两档时，
                // 项目一多就会整体跌到最压缩那一档，宽屏上白白浪费空间。
                //
                // 这里不用 ViewThatFits：它只会渲染被选中的那一个候选，
                // 于是“放得下”的档位全都是不可滚动的 HStack，一旦估算与实际渲染有出入，
                // 超出屏幕的胶囊就永远够不到。改成自己按可用宽度挑档位，
                // 外层恒为 ScrollView，估偏了最多是多展开/少展开一个名字。
                // 不用 GeometryReader：它会贪婪占满、首帧报 0 宽度，在离屏渲染
                // （视觉快照）里和真机行为不一致。onGeometryChange 只观测已经排好的
                // 真实宽度，不参与布局协商。
                ScrollView(.horizontal, showsIndicators: false) {
                    projectChips(
                        expandedNameLimit: expandedNameLimit(forWidth: measuredStripWidth),
                        tokens: tokens
                    )
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    guard newWidth > 0, measuredStripWidth != newWidth else { return }
                    measuredStripWidth = newWidth
                }
                .onChange(of: selectedWorkspaceID) { _, selectedID in
                    guard let selectedID else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
                .onAppear {
                    guard let selectedWorkspaceID else { return }
                    // 恢复已有选择时主动定位胶囊，保证选中项不会留在横向列表的屏幕外。
                    DispatchQueue.main.async {
                        proxy.scrollTo(selectedWorkspaceID, anchor: .center)
                    }
                }
            }

            // “打开目录”与切换工作区是同一类操作，和胶囊行齐平；
            // 它固定在行尾，不参与胶囊的横向滚动。
            openDirectoryButton(tokens: tokens)
        }
        .padding(.horizontal, WorkspaceStripLayout.horizontalPadding)
        .frame(height: WorkspaceStripLayout.stripHeight)
        .accessibilityLabel(L10n.text("ui.workspace_list"))
    }

    /// 在给定宽度下能展开多少个名称。从最宽的档位往下退，取第一个装得下的。
    private func expandedNameLimit(forWidth width: CGFloat) -> Int {
        // 宽度尚未量到时按全展开渲染：胶囊行始终可横向滚动，
        // 首帧偏宽只是多展开几个名字，而塌成 0 会让整行只剩一个胶囊。
        guard width > 0 else { return .max }
        let projects = sessionStore.sidebarProjects
        guard !projects.isEmpty else { return 0 }

        let names = projects.map(\.name)
        let selectedIndex = projects.firstIndex { $0.id == selectedWorkspaceID }
        let ids = projects.map(\.id)

        for limit in [Int.max, 8, 6, 4, 3, 2, 1] {
            let expandedIDs = WorkspaceStripLayout.centeredNameWindow(
                projectIDs: ids,
                limit: limit,
                aroundIndex: selectedIndex
            )
            let expandedNames = Set(
                zip(ids, names).compactMap { expandedIDs.contains($0.0) ? $0.1 : nil }
            )
            let estimate = WorkspaceStripLayout.estimatedRowWidth(
                names: names,
                expandedNames: expandedNames
            )
            if estimate <= width {
                return limit
            }
        }
        return 0
    }

    /// 各档位共用同一份胶囊构造，只有展开名称的数量不同；
    /// 分支结构必须一致，否则 ViewThatFits 切换档位时会重建整行而不是平滑改宽。
    /// `expandedNameLimit` 为 0 表示只展开选中项。
    private func projectChips(expandedNameLimit: Int, tokens: ThemeTokens) -> some View {
        let profileID = appStore.activeHostScope.profileID
        let projectIDs = sessionStore.sidebarProjects.map(\.id)
        let iconStyle = appearanceStore.style(profileID: profileID)
        let characterAssignments = appearanceStore.characterAssignments(
            style: iconStyle,
            profileID: profileID,
            projectIDs: projectIDs
        )
        let emojiAssignments = appearanceStore.emojiAssignments(
            profileID: profileID,
            projectIDs: projectIDs
        )
        // 名额以选中项为中心向两侧分配。从最左边开始发会让选中项右侧的邻居先被收缩，
        // 视线跟着选择移动时出现断裂——这正是“滑到哪个才放大哪个”被破坏的原因。
        let selectedIndex = sessionStore.sidebarProjects.firstIndex { $0.id == selectedWorkspaceID }
        let expandedNameIDs = WorkspaceStripLayout.centeredNameWindow(
            projectIDs: projectIDs,
            limit: expandedNameLimit,
            aroundIndex: selectedIndex
        )

        // 胶囊数量等于本机工作区数量，且每个都很轻；用 HStack 而不是 LazyHStack，
        // 否则选中项展开时宽度动画会因为懒加载复用而跳变。
        return HStack(spacing: WorkspaceStripLayout.chipSpacing) {
            if catalogLoad.state == .loading && sessionStore.sidebarProjects.isEmpty {
                ForEach(0..<4, id: \.self) { index in
                    WorkspaceProjectChip(
                        project: AgentProject(id: "loading-\(index)", name: L10n.text("ui.loading_workspace"), path: "/Users/you/code/project"),
                        profileID: profileID,
                        appearanceStore: appearanceStore,
                        iconStyle: iconStyle,
                        displayedCharacter: appearanceStore.character(
                            style: iconStyle,
                            profileID: profileID,
                            projectID: "loading-\(index)"
                        ),
                        displayedEmoji: appearanceStore.emoji(
                            profileID: profileID,
                            projectID: "loading-\(index)"
                        ),
                        unavailableCharacterIDs: [],
                        unavailableEmoji: [],
                        gitSummary: nil,
                        hasRunningSession: false,
                        isUnavailable: false,
                        isSelected: false,
                        showsName: expandedNameLimit > 0,
                        distanceFromSelection: 0,
                        allowsCustomization: false,
                        tokens: tokens,
                        action: {},
                        onOpenGitChanges: {},
                        onConfirmRemove: {}
                    )
                    .redacted(reason: .placeholder)
                }
            } else {
                ForEach(sessionStore.sidebarProjects) { project in
                    let projectSessions = sessionStore.sessions(forProjectID: project.id)
                    let displayedCharacter = characterAssignments[project.id]
                        ?? appearanceStore.character(
                            style: iconStyle,
                            profileID: profileID,
                            projectID: project.id
                        )
                    let displayedEmoji = emojiAssignments[project.id]
                        ?? appearanceStore.emoji(profileID: profileID, projectID: project.id)
                    let unavailableCharacterIDs: Set<String> =
                        projectIDs.count
                            <= WorkspaceAppearanceStore.characters(for: iconStyle).count
                        ? Set(
                            characterAssignments.compactMap { otherProjectID, character in
                                otherProjectID == project.id ? nil : character.id
                            }
                        )
                        : []
                    let unavailableEmoji: Set<String> =
                        projectIDs.count <= WorkspaceAppearanceStore.builtInEmoji.count
                        ? Set(
                            emojiAssignments.compactMap { otherProjectID, emoji in
                                otherProjectID == project.id ? nil : emoji
                            }
                        )
                        : []
                    WorkspaceProjectChip(
                        project: project,
                        profileID: profileID,
                        appearanceStore: appearanceStore,
                        iconStyle: iconStyle,
                        displayedCharacter: displayedCharacter,
                        displayedEmoji: displayedEmoji,
                        unavailableCharacterIDs: unavailableCharacterIDs,
                        unavailableEmoji: unavailableEmoji,
                        gitSummary: sessionStore.workspaceGitSummaryByPath[project.path],
                        hasRunningSession: projectSessions.contains(where: \.isRunning),
                        isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                        isSelected: selectedWorkspaceID == project.id,
                        showsName: expandedNameIDs.contains(project.id) || selectedWorkspaceID == project.id,
                        distanceFromSelection: selectedIndex.map { abs(($0) - (projectIDs.firstIndex(of: project.id) ?? $0)) } ?? 0,
                        allowsCustomization: true,
                        tokens: tokens
                    ) {
                        // 工作区页面只更新本地浏览选择，避免切换胶囊时意外改变当前会话上下文。
                        selectedWorkspaceID = project.id
                    } onOpenGitChanges: {
                        gitInspectionTarget = WorkspaceGitInspectionTarget(project: project)
                    } onConfirmRemove: {
                        removeWorkspace(project)
                    }
                    .id(project.id)
                }
            }
        }
        // 这里不能加 maxWidth 约束：ViewThatFits 靠子视图的固有宽度判断放不放得下，
        // 一旦声明 .infinity，展开态会永远“合身”，窄屏上就退不回压缩态。
        .padding(.vertical, 8)
    }

    /// 胶囊收缩后，工作区不可用状态仍集中在这一行，保留导航恢复线索。
    /// 根工作区的 Git 摘要不在这里展示：它描述的是 project.path，不能代表各会话 worktree。
    private func workspaceStatusLine(project: AgentProject, tokens: ThemeTokens) -> some View {
        Group {
            if sessionStore.isWorkspaceUnavailable(project.id) {
                Label(L10n.text("ui.need_to_retry"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(tokens.warning)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(themeStore.uiFont(.caption))
        .foregroundStyle(tokens.secondaryText)
        // 状态行现在渲染在会话列表容器内部，那层已经有横向内边距了；
        // 这里再加一次会比筛选行和会话行多缩进一截。
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspace.statusLine")
    }

    private func workspaceDetail<StatusLine: View>(
        project: AgentProject,
        showsStatusLine: Bool,
        @ViewBuilder statusLine: () -> StatusLine
    ) -> some View {
        let presentationKey = workspaceSessionPresentationKey(for: project)
        let cachedPageState = runtimeSessionPagesByKey[presentationKey]
        // Store 已有首屏时先按当前 Runtime 投影，避免进入工作区或切换筛选后先退回骨架屏；
        // authoritative 请求仍会在后台刷新，并在返回后接管独立 cursor 与 hasMore。
        let storedRuntimeSessions = sessionStore.sessions(forProjectID: project.id).filter { session in
            sessionStore.isListableSession(session)
                && CodexAppServerSessionRuntime.normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
                    == presentationKey.runtimeProvider
        }
        let loadedSessions = cachedPageState?.reconciledSessions(with: storedRuntimeSessions) ?? storedRuntimeSessions
        let loadState = sessionLoadState(for: presentationKey)
        let visibleLimit = workspaceSessionVisibleLimit(for: presentationKey)
        return WorkspaceDetailView(
            statusLine: statusLine(),
            showsStatusLine: showsStatusLine,
            // Store 保留全部已取回 root 作为预取缓冲；工作区详情按 20 条窗口逐步展开，
            // 不能让一次超采样把首屏从 20 条直接放大到 50 条。
            recentSessions: WorkspaceSessionPresentation.visibleSessions(
                loadedSessions,
                limit: visibleLimit
            ),
            unreadHistorySessionIDs: sessionStore.unreadHistorySessionIDs,
            sessionLoadState: loadState,
            hasInitialSessionContent: cachedPageState?.hasLoadedFirstPage == true || !storedRuntimeSessions.isEmpty,
            canLoadMoreSessions: WorkspaceSessionPresentation.canLoadMore(
                loadedCount: loadedSessions.count,
                visibleLimit: visibleLimit,
                remoteHasMore: cachedPageState?.hasMore == true
            ),
            selectedRuntime: $selectedSessionRuntime,
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel,
            currentDate: currentDate,
            onRefreshSessions: {
                Task {
                    await refreshWorkspaceSessions(project: project, presentationKey: presentationKey)
                }
            },
            onLoadMoreSessions: {
                await loadMoreWorkspaceSessions(project: project, presentationKey: presentationKey)
            },
            onStartSession: { runtimeChoice in
                onStartSession(project, runtimeChoice)
            },
            onOpenSession: { session in
                onOpenSession(session)
            }
        )
    }

    private var selectedProject: AgentProject? {
        guard let selectedWorkspaceID else {
            return nil
        }
        return sessionStore.sidebarProjects.first { $0.id == selectedWorkspaceID }
    }

    private var emptyWorkspaceTitle: String {
        if case .failed = catalogLoad.state { return L10n.text("ui.unable_to_load_workspace") }
        return L10n.text("ui.no_workspace_yet")
    }

    private var emptyWorkspaceSymbol: String {
        if case .failed = catalogLoad.state { return "exclamationmark.triangle" }
        return "folder.badge.plus"
    }

    private var emptyWorkspaceMessage: String {
        if case .failed(let message) = catalogLoad.state { return message }
        return L10n.text("ui.once_the_directory_is_open_you_can_browse")
    }

    private func synchronizeSelection() {
        let projects = sessionStore.sidebarProjects
        guard !projects.isEmpty else {
            selectedWorkspaceID = nil
            return
        }
        if let selectedWorkspaceID,
           projects.contains(where: { $0.id == selectedWorkspaceID }) {
            return
        }
        if let selectedWorkspaceID {
            let retainedID = sessionStore.retainedWorkspaceID(for: selectedWorkspaceID)
            if projects.contains(where: { $0.id == retainedID }) {
                self.selectedWorkspaceID = retainedID
                return
            }
        }
        selectedWorkspaceID = sessionStore.selectedProjectID.flatMap { selectedID in
            projects.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? projects.first?.id
    }

    private func removeWorkspace(_ project: AgentProject) {
        guard selectedWorkspaceID != project.id else { return }
        runtimeSessionPagesByKey = runtimeSessionPagesByKey.filter { $0.key.workspaceID != project.id }
        sessionLoadStates = sessionLoadStates.filter { $0.key.workspaceID != project.id }
        sessionLoadInvocationTokens.remove { $0.workspaceID == project.id }
        workspaceSessionVisibleLimitByKey = workspaceSessionVisibleLimitByKey.filter {
            $0.key.workspaceID != project.id
        }
        sessionStore.forgetWorkspace(project)
    }

    /// LazyHStack 会预先构建左右相邻页；提前取回它们的首屏窗口，
    /// 否则滑动落地时才开始请求，会先看到骨架屏再跳成列表。
    /// 只取紧邻的前后各一页，且只取当前 Runtime——不做整库预热。
    private var neighborWorkspaceProjects: [AgentProject] {
        let projects = sessionStore.sidebarProjects
        guard let index = projects.firstIndex(where: { $0.id == selectedWorkspaceID }) else {
            return []
        }
        return [index - 1, index + 1]
            .filter { projects.indices.contains($0) }
            .map { projects[$0] }
    }

    private var neighborPrefetchScope: String {
        (
            [appStore.activeHostScope.profileID,
             selectedSessionRuntime.rawValue,
             selectedWorkspaceID ?? ""]
                + neighborWorkspaceProjects.map(\.id)
        ).joined(separator: "|")
    }

    private func workspaceSessionPresentationKey(for project: AgentProject) -> WorkspaceSessionPresentationKey {
        WorkspaceSessionPresentationKey(
            hostScope: appStore.activeHostScope,
            workspaceID: project.id,
            workspacePath: project.path,
            runtimeProvider: selectedSessionRuntime.runtimeProvider
        )
    }

    private func workspaceSessionVisibleLimit(for key: WorkspaceSessionPresentationKey) -> Int {
        max(
            SessionStore.initialSessionPageLimit,
            workspaceSessionVisibleLimitByKey[key] ?? SessionStore.initialSessionPageLimit
        )
    }

    private func loadMoreWorkspaceSessions(
        project: AgentProject,
        presentationKey: WorkspaceSessionPresentationKey
    ) async {
        let currentVisibleLimit = workspaceSessionVisibleLimit(for: presentationKey)
        let targetVisibleLimit = WorkspaceSessionPresentation.nextVisibleLimit(
            current: currentVisibleLimit,
            pageSize: SessionStore.expandedSessionPageLimit
        )
        var pageState = runtimeSessionPagesByKey[presentationKey] ?? WorkspaceRuntimeSessionPageState()
        let loadedCount = pageState.sessions.count
        if WorkspaceSessionPresentation.shouldRequestRemotePage(
            loadedCount: loadedCount,
            targetVisibleLimit: targetVisibleLimit,
            remoteHasMore: pageState.hasMore
        ) {
            do {
                let page = try await sessionStore.workspaceRuntimeSessionsPage(
                    projectID: project.id,
                    runtimeProvider: presentationKey.runtimeProvider,
                    cursor: pageState.nextCursor,
                    limit: SessionStore.expandedSessionPageLimit,
                    excludingListableSessionIDs: Set(pageState.sessions.map(\.id))
                )
                pageState.append(page)
                runtimeSessionPagesByKey[presentationKey] = pageState
                sessionLoadStates[presentationKey] = .loaded
            } catch {
                guard !isCancellationError(error) else { return }
                sessionLoadStates[presentationKey] = .failed(error.localizedDescription)
            }
        }

        guard appStore.activeHostScope == presentationKey.hostScope,
              let currentProject = sessionStore.sidebarProjects.first(where: { $0.id == project.id }),
              currentProject.path == presentationKey.workspacePath
        else {
            return
        }
        workspaceSessionVisibleLimitByKey[presentationKey] = WorkspaceSessionPresentation.committedVisibleLimit(
            current: currentVisibleLimit,
            target: targetVisibleLimit,
            loadedCount: runtimeSessionPagesByKey[presentationKey]?.sessions.count ?? pageState.sessions.count
        )
    }

    private func refreshCatalog(forceGitSummary: Bool = false) async {
        let invocationID = catalogLoad.begin()
        do {
            try await sessionStore.refreshWorkspaceCatalog()
            guard catalogLoad.isCurrent(invocationID) else {
                return
            }
            guard !Task.isCancelled else {
                catalogLoad.complete(
                    invocationID,
                    result: .cancelled,
                    hasCachedProjects: !sessionStore.sidebarProjects.isEmpty
                )
                return
            }
            catalogLoad.complete(
                invocationID,
                result: .loaded,
                hasCachedProjects: !sessionStore.sidebarProjects.isEmpty
            )
            await sessionStore.refreshWorkspaceGitSummaries(
                for: sessionStore.sidebarProjects,
                force: forceGitSummary
            )
        } catch {
            catalogLoad.complete(
                invocationID,
                result: isCancellationError(error) ? .cancelled : .failed(error.localizedDescription),
                hasCachedProjects: !sessionStore.sidebarProjects.isEmpty
            )
        }
    }

    private func refreshWorkspaceContent(projectID: String) async {
        await refreshCatalog(forceGitSummary: true)
        guard !Task.isCancelled,
              selectedWorkspaceID == projectID,
              let project = sessionStore.sidebarProjects.first(where: { $0.id == projectID })
        else {
            return
        }
        let presentationKey = workspaceSessionPresentationKey(for: project)
        await refreshWorkspaceSessions(project: project, presentationKey: presentationKey)
    }

    private func refreshWorkspaceSessions(
        project: AgentProject,
        presentationKey: WorkspaceSessionPresentationKey
    ) async {
        // 每个 Runtime 独立占有提交 token；切换筛选不会让旧请求覆盖当前 Runtime 的缓存。
        let invocationID = sessionLoadInvocationTokens.begin(for: presentationKey)
        let canonicalSessionIDsBeforeLoad = Set<SessionID>(
            sessionStore.sessions(forProjectID: project.id).compactMap { session in
                guard sessionStore.isListableSession(session),
                      CodexAppServerSessionRuntime.normalizedRuntimeProvider(
                          session.runtimeProvider ?? session.source
                      ) == presentationKey.runtimeProvider
                else {
                    return nil
                }
                return session.id
            }
        )
        sessionLoadStates[presentationKey] = .loading
        do {
            let page = try await sessionStore.workspaceRuntimeSessionsPage(
                projectID: project.id,
                runtimeProvider: presentationKey.runtimeProvider,
                cursor: nil,
                limit: SessionStore.initialSessionPageLimit
            )
            guard sessionLoadInvocationTokens.isCurrent(invocationID, for: presentationKey) else {
                return
            }
            guard !Task.isCancelled,
                  appStore.activeHostScope == presentationKey.hostScope,
                  sessionStore.sidebarProjects.contains(where: {
                      $0.id == project.id && $0.path == presentationKey.workspacePath
                  })
            else {
                sessionLoadStates[presentationKey] = fallbackSessionLoadState(for: presentationKey)
                return
            }
            var nextState = WorkspaceRuntimeSessionPageState()
            nextState.replace(
                with: page,
                canonicalSessionIDsBeforeLoad: canonicalSessionIDsBeforeLoad
            )
            runtimeSessionPagesByKey[presentationKey] = nextState
            workspaceSessionVisibleLimitByKey[presentationKey] = SessionStore.initialSessionPageLimit
            sessionLoadStates[presentationKey] = .loaded
        } catch {
            guard sessionLoadInvocationTokens.isCurrent(invocationID, for: presentationKey) else {
                return
            }
            switch workspaceSessionLoadFailureDisposition(error) {
            case .cancelled:
                sessionLoadStates[presentationKey] = fallbackSessionLoadState(for: presentationKey)
            case .failed(let message):
                sessionLoadStates[presentationKey] = .failed(message)
            }
        }
    }

    private func sessionLoadState(for key: WorkspaceSessionPresentationKey) -> WorkspaceSessionLoadState {
        sessionLoadStates[key] ?? fallbackSessionLoadState(for: key)
    }

    private func fallbackSessionLoadState(for key: WorkspaceSessionPresentationKey) -> WorkspaceSessionLoadState {
        runtimeSessionPagesByKey[key]?.hasLoadedFirstPage == true ? .loaded : .idle
    }

}

private enum WorkspaceSessionLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        self == .loading
    }
}

/// 44pt 的项目胶囊：选中项展开成带名称的胶囊，其余收缩成头像圆，整行只占一条控件带。
/// 原来 316×138pt 卡片上有三个可见操作，胶囊只留得下“选中”；Git 变更、换图标和移除目录
/// 都是低频操作，收进长按菜单。分支与 Git 状态改由页面的状态行承担。
private struct WorkspaceProjectChip: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: AgentProject
    let profileID: String
    @ObservedObject var appearanceStore: WorkspaceAppearanceStore
    let iconStyle: WorkspaceIconStyle
    let displayedCharacter: WorkspaceCharacterIcon
    let displayedEmoji: String
    let unavailableCharacterIDs: Set<String>
    let unavailableEmoji: Set<String>
    /// 胶囊本身不再展示 Git 摘要；这里只用来决定“Git 变更”菜单项是否可用。
    let gitSummary: GitStatusResponse?
    let hasRunningSession: Bool
    let isUnavailable: Bool
    let isSelected: Bool
    /// 展开名称与选中是两件事：宽度够时所有胶囊都展开，选中仍只由亮度和字重表达。
    let showsName: Bool
    /// 距选中项的档数。只用来做透明度和图标微缩的衰减，不改变行高——
    /// 行高一旦随选中位置起伏，横向滚动时整条控件带会上下抖动。
    let distanceFromSelection: Int
    let allowsCustomization: Bool
    let tokens: ThemeTokens
    let action: () -> Void
    let onOpenGitChanges: () -> Void
    let onConfirmRemove: () -> Void

    @State private var isPresentingIconPicker = false
    @State private var isPresentingRemoveConfirmation = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                iconTile

                if showsName {
                    Text(project.name)
                        .font(themeStore.uiFont(.subheadline, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? tokens.primaryText : tokens.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, showsName ? 12 : 8)
            .frame(height: WorkspaceStripLayout.chipHeight)
            // 选中与未选中共用同一块磨砂：差别只在中性提亮和是否展开名称，
            // 一行里不会出现两种材质浓度。
            .background {
                WorkbenchChromeMaterial(shape: Capsule(), tokens: tokens, isTinted: isSelected)
            }
            // 波形衰减：越远离选中项越淡。只动透明度，不动行高——
            // 行高一旦随选中位置起伏，横向滚动时整条控件带会上下抖。
            .opacity(showsName ? 1 : max(0.42, 1 - Double(distanceFromSelection) * 0.16))
            .contentShape(Capsule())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .animation(
            reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.34, dampingFraction: 0.86),
            value: showsName
        )
        .animation(
            reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.34, dampingFraction: 0.9),
            value: distanceFromSelection
        )
        .contextMenu { contextActions }
        .popover(isPresented: $isPresentingIconPicker, arrowEdge: .top) {
            iconPicker
        }
        // iPad 会把 confirmationDialog 适配成 popover；挂在胶囊本身，
        // 让系统在旋转和分栏宽度变化时按当前位置计算箭头，而不是使用整页根视图。
        .confirmationDialog(
            L10n.text("ui.remove_directory"),
            isPresented: $isPresentingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.format("ui.remove_directory_value", project.name), role: .destructive) {
                onConfirmRemove()
            }
            .accessibilityIdentifier("workspace.remove.confirm.\(project.id)")
            Button(L10n.text("ui.cancel"), role: .cancel) {
                isPresentingRemoveConfirmation = false
            }
        } message: {
            Text(L10n.text("ui.removing_a_directory_only_removes_it_from_the_workspace"))
        }
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("workspace.card.\(project.id)")
    }

    @ViewBuilder
    private var contextActions: some View {
        Button(action: onOpenGitChanges) {
            Label(L10n.text("ui.git_changes"), systemImage: "doc.text.magnifyingglass")
        }
        .disabled(gitSummary?.isRepository == false)
        .accessibilityIdentifier("workspace.card.git.\(project.id)")

        if allowsCustomization {
            Button {
                isPresentingIconPicker = true
            } label: {
                Label(
                    L10n.text("ui.workspace_icon"),
                    systemImage: iconStyle == .emoji ? "face.smiling" : "person.crop.square"
                )
            }
            .accessibilityIdentifier("workspace.card.icon.\(project.id)")
        }

        if !isSelected {
            Button(role: .destructive) {
                isPresentingRemoveConfirmation = true
            } label: {
                Label(L10n.text("ui.remove_directory"), systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("workspace.remove.request.\(project.id)")
        }
    }

    @ViewBuilder
    private var iconTile: some View {
        let size = WorkspaceStripLayout.chipIconSize
        WorkspaceProjectIconTile(
            content: iconStyle.usesCharacters
                ? .character(displayedCharacter)
                : .emoji(displayedEmoji),
            size: size,
            tokens: tokens
        )
        .overlay(alignment: .topTrailing) {
            runningIndicator
        }
        .opacity(isUnavailable ? 0.62 : 1)
    }

    @ViewBuilder
    private var runningIndicator: some View {
        if hasRunningSession {
            // 收缩态没有名称也没有状态行，这颗点是“这个工作区有会话在跑”的唯一信号，
            // 因此用语义绿而不是原卡片上的中性灰——它不与选中态的梅紫争焦点。
            Circle()
                .fill(tokens.success)
                .frame(width: 9, height: 9)
                .overlay {
                    Circle()
                        .stroke(tokens.background, lineWidth: 1.5)
                }
                .offset(x: 2, y: -2)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var iconPicker: some View {
        if iconStyle.usesCharacters {
            WorkspaceCharacterPicker(
                project: project,
                profileID: profileID,
                appearanceStore: appearanceStore,
                style: iconStyle,
                currentCharacterID: displayedCharacter.id,
                unavailableCharacterIDs: unavailableCharacterIDs,
                tokens: tokens
            )
        } else {
            WorkspaceEmojiPicker(
                project: project,
                profileID: profileID,
                appearanceStore: appearanceStore,
                currentEmoji: displayedEmoji,
                unavailableEmoji: unavailableEmoji,
                tokens: tokens
            )
        }
    }

    private var accessibilitySummary: String {
        let statusParts = [
            isUnavailable ? L10n.text("ui.need_to_retry") : nil,
            hasRunningSession ? L10n.text("ui.running") : nil
        ].compactMap { $0 }
        let status = statusParts.isEmpty
            ? L10n.text("ui.git_status_unknown")
            : statusParts.joined(separator: ", ")
        let selected = isSelected ? L10n.text("ui.selected_b4f8bea5") : ""
        return L10n.format(
            "ui.workspace_card_summary",
            project.name,
            project.path,
            status,
            selected
        )
    }
}

/// 泛型视图不能持有静态存储属性，而每行重建 DateFormatter 又很贵；
/// 这两个格式化器与具体视图无关，提到文件级共享一份。
/// 工作区最近会话行的几何。左槽不再放运行时品牌图标：这一屏已经被项目胶囊和
/// Codex/Claude 筛选器各锁定一次，逐行重复的图标是常量，只会和标题抢横向空间。
/// 槽位改成状态导轨，正常会话用圆点，等待/错误使用异常图标。
private enum WorkspaceSessionRowMetrics {
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
private enum WorkspaceSessionRailState {
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
private struct WorkspaceSessionGroupPanel: ViewModifier {
    let tokens: ThemeTokens

    func body(content: Content) -> some View {
        content
            .workbenchSurface(tokens: tokens, role: .groupedPanel)
    }
}

private enum WorkspaceSessionRowFormatters {
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

private struct WorkspaceDetailView<StatusLine: View>: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.workbenchBottomChromeClearance) private var bottomChromeClearance
    @Environment(\.workbenchHasCompactTabBar) private var hasCompactTabBar
    @ScaledMetric(relativeTo: .caption) private var compactActionFontSize: CGFloat = 12
    @State private var isLoadingMoreSessions = false

    let statusLine: StatusLine
    let showsStatusLine: Bool
    let recentSessions: [AgentSession]
    let unreadHistorySessionIDs: Set<SessionID>
    let sessionLoadState: WorkspaceSessionLoadState
    let hasInitialSessionContent: Bool
    let canLoadMoreSessions: Bool
    @Binding var selectedRuntime: WorkspaceSessionRuntimeChoice
    let claudeChannelAvailable: Bool
    let currentDate: () -> Date
    let onRefreshSessions: () -> Void
    let onLoadMoreSessions: () async -> Void
    let onStartSession: (WorkspaceSessionRuntimeChoice) -> Void
    let onOpenSession: (AgentSession) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                recentSessionsSection(tokens: tokens)
            }
            .padding(
                .horizontal,
                hasCompactTabBar
                    ? WorkbenchPageLayout.compactPadding
                    : WorkbenchPageLayout.regularPadding
            )
            .padding(.top, 16)
            // 三个顶层页面消费同一个浮动栏 clearance；宽屏无 Tab Bar 时只保留常规页面留白。
            .padding(
                .bottom,
                hasCompactTabBar
                    ? bottomChromeClearance
                    : WorkbenchPageLayout.regularPadding
            )
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
        .background(tokens.background.ignoresSafeArea())
    }

    private func recentSessionsSection(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            recentSessionsHeader(tokens: tokens)

            // 工作区状态紧贴第一条会话行，与列表共用左右内边距：
            // 它是这个列表的说明文字，夹在筛选行上方会重新读成悬空的元数据。
            if showsStatusLine {
                statusLine
                    .padding(.bottom, 2)
            }

            if sessionLoadState.isLoading, !hasInitialSessionContent {
                // 首屏窗口还没凑满：稳定显示骨架屏，避免切换时先渲染欠填的半截列表再逐批变多。
                recentSessionPlaceholders(tokens: tokens)
            } else if recentSessions.isEmpty, case .failed(let message) = sessionLoadState {
                ContentUnavailableView {
                    Label(L10n.text("ui.unable_to_load_session"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(L10n.text("ui.reload"), action: onRefreshSessions)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .workbenchSurface(tokens: tokens, role: .groupedPanel)
            } else if recentSessions.isEmpty {
                ContentUnavailableView(L10n.text("ui.no_sessions_yet"), systemImage: "bubble.left.and.bubble.right", description: Text(L10n.text("ui.after_a_new_session_is_created_in_this")))
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .workbenchSurface(tokens: tokens, role: .groupedPanel)
            } else {
                groupedSessionSections(tokens: tokens)
            }
        }
    }

    /// 需要处理 / 正在运行 / 最近会话三段保留标题与计数；
    /// 每段使用一张整体卡片，12 小时边界再把“最近会话”拆成上下两张卡片。
    /// 分段本身取代了原来那条“运行中 · 刚刚活跃”摘要——它只描述第一条，却读起来像在描述整个列表。
    @ViewBuilder
    private func groupedSessionSections(tokens: ThemeTokens) -> some View {
        let grouped = Dictionary(grouping: recentSessions) { session in
            WorkspaceSessionGroup.of(session, status: session.displayStatus(foregroundActivity: nil))
        }
        let branchValues = recentSessions.map(\.gitBranchName)
        let populatedGroups = WorkspaceSessionGroup.orderedPopulatedGroups(from: Set(grouped.keys))

        VStack(alignment: .leading, spacing: 18) {
            ForEach(populatedGroups, id: \.self) { group in
                let sessions = grouped[group] ?? []
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(group, count: sessions.count, tokens: tokens)
                    sessionGroupBody(
                        group,
                        sessions: sessions,
                        branchValues: branchValues,
                        showsLoadMore: group == populatedGroups.last,
                        tokens: tokens
                    )
                }
            }
        }
    }

    private func sectionHeader(
        _ group: WorkspaceSessionGroup,
        count: Int,
        tokens: ThemeTokens
    ) -> some View {
        // 计数推到行尾，跟系统列表（「最近通话  12」）一致；贴在标题后面会读成标题的一部分。
        HStack(spacing: 8) {
            Text(group.title)
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)

            Spacer(minLength: 8)

            Text("\(count)")
                .font(themeStore.uiFont(.subheadline))
                .foregroundStyle(tokens.tertiaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, WorkspaceSessionRowMetrics.horizontalPadding)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sessionGroupBody(
        _ group: WorkspaceSessionGroup,
        sessions: [AgentSession],
        branchValues: [String?],
        showsLoadMore: Bool,
        tokens: ThemeTokens
    ) -> some View {
        let firstStaleIndex = group == .recent
            ? WorkspaceSessionAgeBoundary.firstStaleIndex(
                in: sessions,
                excludingSessionIDs: sessionStore.pinnedSessionIDs,
                now: currentDate()
            )
            : nil

        if let firstStaleIndex {
            let currentSessions = Array(sessions.prefix(firstStaleIndex))
            let staleSessions = Array(sessions.dropFirst(firstStaleIndex))

            // 12 小时是信息分组边界，不是卡片内部的一条特殊 Divider。
            // 边界两侧各自形成完整面板，避免时间标签切进白色内容表面。
            VStack(alignment: .leading, spacing: 0) {
                if !currentSessions.isEmpty {
                    sessionGroupPanel(
                        sessions: currentSessions,
                        branchValues: branchValues,
                        showsLoadMore: false,
                        tokens: tokens
                    )
                }

                twelveHourBoundary(tokens: tokens)

                sessionGroupPanel(
                    sessions: staleSessions,
                    branchValues: branchValues,
                    showsLoadMore: showsLoadMore,
                    tokens: tokens
                )
            }
        } else {
            sessionGroupPanel(
                sessions: sessions,
                branchValues: branchValues,
                showsLoadMore: showsLoadMore,
                tokens: tokens
            )
        }
    }

    private func sessionGroupPanel(
        sessions: [AgentSession],
        branchValues: [String?],
        showsLoadMore: Bool,
        tokens: ThemeTokens
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                if index > 0 {
                    Divider()
                        .overlay(tokens.border.opacity(0.62))
                        .padding(.leading, WorkspaceSessionRowMetrics.separatorInset)
                }

                Button {
                    onOpenSession(session)
                } label: {
                    recentSessionRow(
                        session,
                        branchValues: branchValues,
                        tokens: tokens
                    )
                }
                .buttonStyle(.plain)
                .sessionRowActions(session)
                .accessibilityIdentifier("workspace.session.\(session.id)")
            }

            // 加载入口只跟随最后一张面板；12 小时边界存在时自然落在旧会话卡片底部。
            if showsLoadMore, canLoadMoreSessions || isLoadingMoreSessions {
                Divider()
                    .overlay(tokens.border.opacity(0.62))

                loadMoreButton(tokens: tokens)
            }
        }
        .modifier(WorkspaceSessionGroupPanel(tokens: tokens))
    }

    private func loadMoreButton(tokens: ThemeTokens) -> some View {
        Button {
            guard !isLoadingMoreSessions else { return }
            isLoadingMoreSessions = true
            Task {
                await onLoadMoreSessions()
                isLoadingMoreSessions = false
            }
        } label: {
            HStack(spacing: 7) {
                if isLoadingMoreSessions {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.down")
                        .font(themeStore.uiFont(size: compactActionFontSize, weight: .semibold))
                }
                Text(isLoadingMoreSessions ? L10n.text("ui.loading") : L10n.text("ui.show_more"))
            }
            .font(themeStore.uiFont(size: compactActionFontSize, weight: .semibold))
            .foregroundStyle(tokens.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoadingMoreSessions)
        .accessibilityLabel(
            isLoadingMoreSessions
                ? L10n.text("ui.loading")
                : L10n.text("ui.show_more")
        )
        .accessibilityIdentifier("workspace.sessions.loadMore")
    }

    /// 筛选器固定在列表左侧，紧接结果区域；新建会话保留在右侧并使用唯一文字操作。
    /// 页面已经通过筛选器说明 Runtime，卡片不再重复渲染品牌或 Runtime 文案。
    private func recentSessionsHeader(tokens: ThemeTokens) -> some View {
        ViewThatFits(in: .horizontal) {
            // 先尝试单行；按钮和筛选器都保留固有宽度，ViewThatFits 不会把文字压成半截。
            HStack(spacing: 12) {
                runtimePicker

                Spacer(minLength: 8)

                newSessionButton(tokens: tokens)
            }

            // 窄屏或大字体时自然改为两行，筛选器仍排在结果前，新建操作靠右。
            VStack(alignment: .leading, spacing: 8) {
                runtimePicker

                HStack {
                    Spacer(minLength: 0)
                    newSessionButton(tokens: tokens)
                }
            }
        }
    }

    private var runtimePicker: some View {
        WorkspaceRuntimePicker(
            selection: $selectedRuntime,
            claudeChannelAvailable: claudeChannelAvailable
        )
    }

    private func newSessionButton(tokens: ThemeTokens) -> some View {
        Button {
            // thread 创建时就绑定 runtime；这里必须把当前选择一路传到 SessionStore。
            onStartSession(selectedRuntime)
        } label: {
            Label(L10n.text("ui.new_session_3da224c4"), systemImage: "square.and.pencil")
                .font(themeStore.uiFont(.callout, weight: .semibold))
                .foregroundStyle(tokens.primaryActionForeground)
                .padding(.horizontal, 12)
                .frame(minHeight: WorkbenchChromeIconMetrics.minimumHitTarget)
                .background(tokens.primaryAction, in: Capsule())
                .contentShape(Capsule())
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.text("ui.new_session_3da224c4"))
        .accessibilityValue(selectedRuntime.title)
        .accessibilityIdentifier("workspace.sessions.newSession")
    }

    private func twelveHourBoundary(tokens: ThemeTokens) -> some View {
        ZStack {
            // 时间标签位于两张整体卡片之间，横线只帮助扫读，不穿过卡片表面。
            Rectangle()
                .fill(tokens.border.opacity(0.62))
                .frame(height: 0.5)

            Text(L10n.text("ui.twelve_hours_ago"))
                .font(themeStore.uiFont(.caption2, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
                .padding(.horizontal, 8)
                // 缺口与页面底色一致，确保标签明确悬在两张卡片之间。
                .background(tokens.background)
                .fixedSize()
        }
        .padding(.horizontal, WorkspaceSessionRowMetrics.horizontalPadding)
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.twelve_hours_ago"))
    }

    private func recentSessionPlaceholders(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: WorkspaceSessionRowMetrics.railSpacing) {
                    Color.clear
                        .frame(width: WorkspaceSessionRowMetrics.railWidth)

                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tokens.elevatedSurface)
                            .frame(width: 210, height: 12)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tokens.elevatedSurface)
                            .frame(width: 128, height: 9)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, WorkspaceSessionRowMetrics.horizontalPadding)
                .padding(.vertical, WorkspaceSessionRowMetrics.verticalPadding)
                .frame(minHeight: WorkspaceSessionRowMetrics.minHeight)

                if index < 2 {
                    Divider()
                        .overlay(tokens.border.opacity(0.62))
                        .padding(.leading, WorkspaceSessionRowMetrics.separatorInset)
                }
            }
        }
        .redacted(reason: .placeholder)
        .modifier(WorkspaceSessionGroupPanel(tokens: tokens))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.loading_recent_conversations"))
    }

    private func recentSessionRow(
        _ session: AgentSession,
        branchValues: [String?],
        tokens: ThemeTokens
    ) -> some View {
        let status = session.displayStatus(foregroundActivity: nil)
        let statusTone = recentSessionStatusColor(for: status.tone, tokens: tokens)
        let showsStatus = shouldShowRecentSessionStatus(status: status)

        let railState = WorkspaceSessionRailState.resolve(
            status: status,
            isRunning: session.isRunning
        )

        let preview = SessionListPresentation.previewDisplayText(for: session)
        let branch = WorkspaceSessionBranchPresentation.branchToDisplay(
            session.gitBranchName,
            among: branchValues
        )

        // 标准字体下保持两行：第一行是状态/标题/时间，第二行是分支前缀和最近消息。
        // 辅助功能大字体取消单行裁切，允许卡片自然增高，不通过缩小字体换取几何高度。
        return HStack(alignment: .top, spacing: WorkspaceSessionRowMetrics.railSpacing) {
            // 状态单独占一条窄列，使标题与摘要共享同一左边缘，连续扫读时不会横向跳动。
            sessionStateRail(railState, tokens: tokens)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: WorkspaceSessionRowMetrics.contentSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if sessionStore.isSessionPinned(session.id) {
                        SessionPinnedBadge(compact: true)
                    }

                    Text(session.title)
                        .font(themeStore.uiFont(.callout, weight: .medium))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .layoutPriority(1)

                    Spacer(minLength: 6)

                    if showsStatus {
                        Text(status.title)
                            .font(themeStore.uiFont(.caption2, weight: .semibold))
                            .foregroundStyle(statusTone)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(2)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(status.title)
                    } else {
                        Text(sessionTimeText(for: session))
                            .font(themeStore.uiFont(.caption2))
                            .foregroundStyle(tokens.tertiaryText)
                            .fixedSize()
                    }

                    if unreadHistorySessionIDs.contains(session.id) {
                        SessionUnreadIndicator()
                    } else {
                        // 占位保证未读状态变化不会令时间或状态在右缘跳动。
                        Color.clear.frame(width: 7, height: 7)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let branch {
                        HStack(spacing: 4) {
                            SessionBranchIcon(size: 10)
                                .foregroundStyle(tokens.tertiaryText)
                                .accessibilityHidden(true)

                            Text(branch)
                                .font(themeStore.uiFont(.caption2))
                                .foregroundStyle(tokens.tertiaryText)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                .truncationMode(.middle)
                                .layoutPriority(0)
                        }
                        // 分支只作为 worktree 前缀；宽度不足时先中间截断，把空间留给摘要。
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 220 : 150, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(L10n.text("ui.branch")) \(branch)")
                    }

                    if !preview.isEmpty {
                        Text(preview)
                            .font(themeStore.uiFont(.footnote))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, WorkspaceSessionRowMetrics.horizontalPadding)
        .padding(.vertical, WorkspaceSessionRowMetrics.verticalPadding)
        .frame(minHeight: WorkspaceSessionRowMetrics.minHeight, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            unreadHistorySessionIDs.contains(session.id)
                ? L10n.text("ui.unread_result")
                : ""
        )
    }

    /// 状态点脱离标题行独立成列，是为了让它落在固定的横坐标上。
    /// 一列圆点对齐在同一条竖轴上，扫一眼就知道哪几条在跑、哪几条卡住了。
    @ViewBuilder
    private func sessionStateRail(
        _ state: WorkspaceSessionRailState?,
        tokens: ThemeTokens
    ) -> some View {
        Group {
            if let state {
                switch state {
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(themeStore.uiFont(size: 13, weight: .semibold))
                        .foregroundStyle(WorkspaceSessionRailState.failed.color(tokens: tokens))
                case .waiting:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(WorkspaceSessionRailState.waiting.color(tokens: tokens))
                case .running:
                    Circle()
                        .fill(WorkspaceSessionRailState.running.color(tokens: tokens))
                        .frame(width: 7, height: 7)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: WorkspaceSessionRowMetrics.railWidth)
        .accessibilityHidden(true)
    }

    private func shouldShowRecentSessionStatus(status: AgentSessionDisplayStatus) -> Bool {
        // 正常运行由绿色状态点表达；只有等待、警告、错误才占用右侧文案空间。
        status.tone == .warning || status.tone == .danger
    }

    /// 状态文字的颜色跟左端圆点保持同一套语义：等待用户橙、失败红、运行中绿。
    private func recentSessionStatusColor(
        for tone: AgentSessionStatusTone,
        tokens: ThemeTokens
    ) -> Color {
        switch tone {
        case .warning:
            return tokens.warning
        case .danger:
            return .red
        case .active:
            return tokens.success
        case .complete, .neutral:
            return tokens.secondaryText
        }
    }

    private func sessionTimeText(for session: AgentSession) -> String {
        guard let date = session.recencyAt ?? session.updatedAt ?? session.createdAt else { return "" }
        if Calendar.current.isDate(date, inSameDayAs: currentDate()) {
            return WorkspaceSessionRowFormatters.time.string(from: date)
        }
        return WorkspaceSessionRowFormatters.date.string(from: date)
    }

}
