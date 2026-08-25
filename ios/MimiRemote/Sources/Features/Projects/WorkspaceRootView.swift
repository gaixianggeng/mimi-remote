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

    /// 这批会话的**基线分支**：出现次数最多、且唯一的那一个。
    ///
    /// 分支标签的价值全在"这条和别的不一样"。按整个列表开关（只要出现过两种分支就
    /// 给每行都挂标签）会让占绝大多数的那个分支重复几十遍——13 行里 11 行写着
    /// `main`，只因为列表最底下有一条 worktree 分支。那 11 个标签一个字节的区分度
    /// 都没有，却每个都占着位置。
    ///
    /// 众数不唯一时返回 nil：此时没有哪个分支称得上"默认"，全部照常显示。
    /// 只有一个分支时它就是基线，于是单行列表不会挂一个无从对比的标签。
    static func baselineBranch(among branches: [String?]) -> String? {
        let normalized = branches.compactMap(normalizedBranch)
        guard !normalized.isEmpty else { return nil }

        var counts: [String: Int] = [:]
        for branch in normalized {
            counts[branch, default: 0] += 1
        }
        guard let maxCount = counts.values.max() else { return nil }

        let leaders = counts.filter { $0.value == maxCount }.map(\.key)
        guard leaders.count == 1 else { return nil }
        return leaders[0]
    }

    /// 分支只在偏离基线时才画。基线由调用方算一次传进来，避免每行重算一遍词频。
    static func branchToDisplay(_ branch: String?, baseline: String?) -> String? {
        guard let value = normalizedBranch(branch) else { return nil }
        guard value != baseline else { return nil }
        return value
    }

    static func branchToDisplay(_ branch: String?, among branches: [String?]) -> String? {
        branchToDisplay(branch, baseline: baselineBranch(among: branches))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workbenchHasBottomTabBar) private var hasBottomTabBar
    @StateObject private var appearanceStore: WorkspaceAppearanceStore
    @StateObject private var pagerTransitionState = WorkspacePagerTransitionState()

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
    @State private var workspaceStripViewportWidth: CGFloat = 0
    /// 整条胶囊行的容器宽。与 `workspaceStripViewportWidth` 不同，它不受行内控件增减影响，
    /// 因此可以安全地用来决定要不要把 Runtime 筛选器并进这一行。
    @State private var workspaceStripContainerWidth: CGFloat = 0
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
            pagerTransitionState.update(pagePosition: nil)
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
                selectWorkspace(id: workspaceID)
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
        // 与侧栏 gutter、会话画布同底，宽屏下三块相邻面不出现同亮度色差。
        .background(tokens.workbenchCanvasBackground.ignoresSafeArea())
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

    /// 设备入口是否占用胶囊行的横向预算。宽屏由顶栏或侧栏承载它，这一行就整条留给工作区。
    private var showsHostSwitcherInStrip: Bool {
        !usesTabletTopBarHostSwitcher && manageConnections != nil
    }

    /// 宽度够时 Runtime 筛选器并入胶囊行，内容头部整条消失；不够时退回列表上方独立一行。
    /// 判定统一由 `WorkspaceStripLayout` 处理，保证底部 Tab 栏始终保留行内新建入口。
    private var usesInlineRuntimePicker: Bool {
        WorkspaceStripLayout.usesInlineRuntimePicker(
            viewportWidth: workspaceStripContainerWidth,
            showsHostSwitcherInStrip: showsHostSwitcherInStrip,
            hasBottomTabBar: hasBottomTabBar
        )
    }

    @ViewBuilder
    private func navigationContent(tokens: ThemeTokens) -> some View {
        if usesTabletTopBarHostSwitcher, let manageConnections {
            // 会话页把设备切换器放在顶栏左侧；工作区也复用同一位置，避免切换 Tab 时垂直跳动。
            workspaceBrowser(tokens: tokens)
                .accessibilityIdentifier("workspace.browser")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .topBarLeading) {
                            HostSwitcherMenu(
                                presentation: .toolbar,
                                manageConnections: manageConnections
                            )
                            .workbenchToolbarChromeCircle(tokens: tokens)
                        }
                        // 按钮自带磨砂圆；关掉系统共享玻璃，否则两层背景叠在一起。
                        .sharedBackgroundVisibility(.hidden)
                        // 与会话页保持相同的顶栏分组间距，避免设备入口和其他 leading 控件粘连。
                        ToolbarSpacer(.fixed, placement: .topBarLeading)
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            HostSwitcherMenu(
                                presentation: .toolbar,
                                manageConnections: manageConnections
                            )
                            .workbenchToolbarChromeCircle(tokens: tokens)
                        }
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

    /// 「打开目录」不再是钉在行尾的工具栏圆钮，而是胶囊行末尾的虚线胶囊：
    /// 与项目胶囊同高同形，待在它所添加的那个列表里面，读作「在这一排后面再加一个」。
    /// 它仍然是个加号，但形状、材质和所处层次都与右下角浮起的新建会话按钮不同，
    /// 因此两个加号不会互相冒充——一个添工作区，一个建会话。
    private func addWorkspaceChip(tokens: ThemeTokens) -> some View {
        Button {
            isPresentingOpenWorkspace = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .frame(
                    width: WorkspaceStripLayout.addChipVisualSize,
                    height: WorkspaceStripLayout.addChipVisualSize
                )
                .background {
                    Capsule()
                        .strokeBorder(
                            tokens.border,
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                }
                // 视觉比项目胶囊小一圈——它是次级动作，不该和工作区身份等重；
                // 但外层仍撑满 44pt 行高，命中区不跟着缩。
                .frame(
                    width: WorkspaceStripLayout.chipHeight,
                    height: WorkspaceStripLayout.chipHeight
                )
                .contentShape(Capsule())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
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
            .background(tokens.workbenchCanvasBackground.ignoresSafeArea())
        }
    }

    /// 每个工作区一页，横向分页切换。用 ScrollView 的分页行为而不是 TabView：
    /// `scrollPosition(id:)` 是连续绑定，胶囊行能跟着滑动过程走；TabView 的 selection
    /// 要等落定才更新，滑到一半上方胶囊不动、松手才跳，正好丢掉跟手感。
    /// 分页物理特性（跟手、速度投射、可中断反向）由系统提供，不自己写 DragGesture。
    private func projectPager(tokens: ThemeTokens) -> some View {
        // scrollTransition 闭包是 Sendable；先冻结成值类型快照，避免直接跨隔离域读取 Environment。
        let allowsSpatialMotion = !reduceMotion
        let projectCount = sessionStore.sidebarProjects.count

        return ScrollView(.horizontal, showsIndicators: false) {
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
                            .scaleEffect(!allowsSpatialMotion || phase.isIdentity ? 1 : 0.97)
                            .opacity(!allowsSpatialMotion || phase.isIdentity ? 1 : 0.72)
                    }
                    .id(project.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        // 直接绑定唯一的选择来源：点胶囊会滚动分页，滑动分页会回写胶囊选中态。
        .scrollPosition(id: $selectedWorkspaceID, anchor: .center)
        .onScrollGeometryChange(for: CGFloat?.self) { geometry in
            WorkspacePagerTransition.pagePosition(
                contentOffsetX: geometry.contentOffset.x,
                leadingInset: geometry.contentInsets.leading,
                viewportWidth: geometry.containerSize.width,
                pageCount: projectCount
            )
        } action: { _, pagePosition in
            pagerTransitionState.update(pagePosition: pagePosition)
        }
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
        .background(tokens.workbenchCanvasBackground.ignoresSafeArea())
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
        .background(tokens.workbenchCanvasBackground.ignoresSafeArea())
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
                        tokens: tokens,
                        restingNameDisclosure: WorkspaceStripLayout.restingNameDisclosure(
                            viewportWidth: workspaceStripViewportWidth,
                            projectCount: sessionStore.sidebarProjects.count
                        )
                    )
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    guard width > 0, workspaceStripViewportWidth != width else { return }
                    workspaceStripViewportWidth = width
                }
                .onChange(of: selectedWorkspaceID) { previousID, selectedID in
                    guard let selectedID else { return }
                    // 首次恢复选择直接定位，避免页面刚出现就自行滑动；后续切换与正文分页
                    // 共用同一个临界阻尼 token，快速反向点击会从当前画面连续改向。
                    withAnimation(previousID == nil ? nil : workspaceSelectionAnimation) {
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

            // 宽屏把 Runtime 筛选器收进这一行，整条内容头部因此可以整体消失。
            // 分隔线和间距是刻意的：让这一行读成「左导航／右工具」的工具条，
            // 而不是一排并列的同级选择器——项目、添加目录和 Runtime 筛选并不同级。
            if usesInlineRuntimePicker {
                Divider()
                    .frame(height: 22)
                    .padding(.horizontal, 4)

                WorkspaceRuntimePicker(
                    selection: $selectedSessionRuntime,
                    claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel
                )
            }
        }
        .padding(.horizontal, WorkspaceStripLayout.horizontalPadding)
        .frame(height: WorkspaceStripLayout.stripHeight)
        // 只观测已经排好的整行宽度，不参与布局协商；插不插筛选器都读到同一个值。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard width > 0, workspaceStripContainerWidth != width else { return }
            workspaceStripContainerWidth = width
        }
        .accessibilityLabel(L10n.text("ui.workspace_list"))
    }

    /// 所有项目始终保留同一份 View 身份；名称不插入/移除，而是按分页进度裁切宽度，
    /// 这样反向横滑可以直接沿当前画面恢复，不会重建 HStack 或跳回逻辑选中态。
    private func projectChips(
        tokens: ThemeTokens,
        restingNameDisclosure: CGFloat
    ) -> some View {
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
        let selectedIndex = sessionStore.sidebarProjects.firstIndex { $0.id == selectedWorkspaceID }

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
                        isSelected: index == 0,
                        projectIndex: index,
                        distanceFromSelection: index,
                        restingNameDisclosure: restingNameDisclosure,
                        pagerTransitionState: pagerTransitionState,
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
                    let projectIndex = projectIDs.firstIndex(of: project.id) ?? 0
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
                        projectIndex: projectIndex,
                        distanceFromSelection: selectedIndex.map { abs($0 - projectIndex) } ?? 0,
                        restingNameDisclosure: restingNameDisclosure,
                        pagerTransitionState: pagerTransitionState,
                        allowsCustomization: true,
                        tokens: tokens
                    ) {
                        // 工作区页面只更新本地浏览选择，避免切换胶囊时意外改变当前会话上下文。
                        selectWorkspace(project)
                    } onOpenGitChanges: {
                        gitInspectionTarget = WorkspaceGitInspectionTarget(project: project)
                    } onConfirmRemove: {
                        removeWorkspace(project)
                    }
                    .id(project.id)
                }

                // 「添加工作区」跟着胶囊一起横滚，而不是钉在行尾：
                // 它必须待在它所添加的那个列表里面，「在这一排后面再加一个」才成立。
                addWorkspaceChip(tokens: tokens)
            }
        }
        .padding(.vertical, 8)
    }

    /// 项目切换属于高频状态变化，使用无回弹、可重定向的统一 spring。
    /// Reduce Motion 下禁用空间动画，保留明确的静态选中态。
    private var workspaceSelectionAnimation: Animation? {
        let motion = MimiMotion.stateTransition.resolve(reduceMotion: reduceMotion)
        return motion.allowsSpatialMotion ? motion.animation : nil
    }
    private func selectWorkspace(_ project: AgentProject) {
        selectWorkspace(id: project.id)
    }
    private func selectWorkspace(id: String) {
        guard selectedWorkspaceID != id else { return }
        withAnimation(workspaceSelectionAnimation) {
            selectedWorkspaceID = id
        }
    }
    /// 目录恢复和数据同步不代表用户发起了导航；禁止隐式动画，避免首次进入工作区自行滑动。
    private func restoreWorkspaceSelection(_ id: String?) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedWorkspaceID = id
        }
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
            // 胶囊行已经承载筛选器时，详情页不再自己画一条筛选行。
            showsInlineRuntimePicker: usesInlineRuntimePicker,
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
            restoreWorkspaceSelection(nil)
            return
        }
        if let selectedWorkspaceID,
           projects.contains(where: { $0.id == selectedWorkspaceID }) {
            return
        }
        if let selectedWorkspaceID {
            let retainedID = sessionStore.retainedWorkspaceID(for: selectedWorkspaceID)
            if projects.contains(where: { $0.id == retainedID }) {
                restoreWorkspaceSelection(retainedID)
                return
            }
        }
        restoreWorkspaceSelection(sessionStore.selectedProjectID.flatMap { selectedID in
            projects.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? projects.first?.id)
    }

    private func removeWorkspace(_ project: AgentProject) {
        // 当前浏览选择可以被移出；目录列表变化后，现有同步逻辑会选择剩余目录。
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
    let projectIndex: Int
    /// 距选中项的档数。只用来做透明度和图标微缩的衰减，不改变行高——
    /// 行高一旦随选中位置起伏，横向滚动时整条控件带会上下抖动。
    let distanceFromSelection: Int
    /// 宽屏信息密度底值。名称可半展开，但选中材质仍只读取分页进度。
    let restingNameDisclosure: CGFloat
    @ObservedObject var pagerTransitionState: WorkspacePagerTransitionState
    let allowsCustomization: Bool
    let tokens: ThemeTokens
    let action: () -> Void
    let onOpenGitChanges: () -> Void
    let onConfirmRemove: () -> Void

    @State private var isPresentingIconPicker = false
    @State private var isPresentingRemoveConfirmation = false
    @State private var measuredNameWidth: CGFloat = 0

    var body: some View {
        let progress = selectionProgress
        let restingNameWidth = min(
            measuredNameWidth,
            WorkspaceStripLayout.restingNameWidth
        ) * restingNameDisclosure
        let nameWidth = restingNameWidth + (measuredNameWidth - restingNameWidth) * progress
        let restingNameOpacity = min(1, restingNameDisclosure * 1.6)
        let nameOpacity = restingNameOpacity + (1 - restingNameOpacity) * progress
        let distanceOpacityFloor = 0.42 + 0.26 * Double(restingNameDisclosure)

        Button(action: action) {
            HStack(spacing: 0) {
                iconTile

                Text(project.name)
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(
                        tokens.secondaryText.mix(
                            with: tokens.primaryText,
                            by: Double(progress)
                        )
                    )
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 8)
                    .frame(width: nameWidth, alignment: .leading)
                    .clipped()
                    .opacity(Double(nameOpacity))
                    .background {
                        // 非选中项首帧的可见文字宽度可能为 0；若直接测裁切后的 Text，
                        // 宽屏底值永远没有机会展开。背景副本固定按完整内容测量，但不参与布局。
                        Text(project.name)
                            .font(themeStore.uiFont(.subheadline, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.leading, 8)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.width
                            } action: { width in
                                guard width > 0, measuredNameWidth != width else { return }
                                measuredNameWidth = width
                            }
                    }
            }
            .padding(.horizontal, 8 + 4 * progress)
            .frame(height: WorkspaceStripLayout.chipHeight)
            // 中性提亮和名称宽度读取同一份 0...1 进度，旧项目退场与新项目进入同帧发生。
            .background {
                WorkbenchChromeMaterial(
                    shape: Capsule(),
                    tokens: tokens,
                    tintLevel: Double(progress)
                )
            }
            // 波形衰减：越远离选中项越淡。只动透明度，不动行高——
            // 行高一旦随选中位置起伏，横向滚动时整条控件带会上下抖。
            .opacity(max(distanceOpacityFloor, 1 - Double(visualDistance) * 0.16))
            .contentShape(Capsule())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
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
    /// Reduce Motion 下只在分页落定后静态切换；正常模式完全读取系统滚动的呈现位置。
    private var selectionProgress: CGFloat {
        guard !reduceMotion, let pagePosition = pagerTransitionState.pagePosition else {
            return isSelected ? 1 : 0
        }
        return WorkspacePagerTransition.selectionProgress(
            projectIndex: projectIndex,
            pagePosition: pagePosition
        )
    }
    private var visualDistance: CGFloat {
        guard !reduceMotion, let pagePosition = pagerTransitionState.pagePosition else {
            return CGFloat(distanceFromSelection)
        }
        return abs(CGFloat(projectIndex) - pagePosition)
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

        Button(role: .destructive) {
            isPresentingRemoveConfirmation = true
        } label: {
            Label(L10n.text("ui.remove_directory"), systemImage: "xmark.circle")
        }
        .accessibilityIdentifier("workspace.remove.request.\(project.id)")
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
