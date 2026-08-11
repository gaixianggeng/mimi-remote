import SwiftUI

enum SessionIndexRowDensity: Equatable {
    case compact
    case table
    case rail

    var minimumHeight: CGFloat {
        switch self {
        case .compact: 44
        case .table: 60
        case .rail: 34
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: 12
        case .table: 14
        case .rail: 10
        }
    }

    var titleFontSize: CGFloat {
        switch self {
        case .compact: 14
        case .table: 15
        case .rail: 13
        }
    }

    var metadataFontSize: CGFloat {
        switch self {
        case .compact: 10
        case .table: 11.5
        case .rail: 9
        }
    }

    var statusFontSize: CGFloat {
        switch self {
        case .table:
            // iPad 表格行的状态位于标题下方，降低 1pt，明确它是二级信息。
            return 10.5
        case .compact, .rail:
            return metadataFontSize
        }
    }

    var runtimeIconSize: CGFloat {
        switch self {
        case .compact: 9
        case .table: 10
        case .rail: 8
        }
    }

    var statusIconSize: CGFloat {
        switch self {
        case .compact, .table: 9
        case .rail: 8
        }
    }

    /// 宽屏优先表格密度；辅助功能字号必须回退两行布局，避免固定列截断状态和时间。
    static func resolved(
        prefersTable: Bool,
        dynamicTypeSize: DynamicTypeSize
    ) -> SessionIndexRowDensity {
        prefersTable && !dynamicTypeSize.isAccessibilitySize ? .table : .compact
    }
}

struct SessionRuntimePresentation: Equatable {
    enum Kind: Equatable {
        case codex
        case claude
    }

    let kind: Kind

    init(session: AgentSession) {
        self.init(runtimeProvider: session.runtimeProvider, source: session.source)
    }

    init(runtimeProvider: String?, source: String) {
        let provider = runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = provider?.isEmpty == false ? provider : source
        kind = CodexAppServerSessionRuntime.normalizedRuntimeProvider(rawValue) == "claude"
            ? .claude
            : .codex
    }

    var title: String {
        switch kind {
        case .codex:
            return L10n.text("ui.runtime_default")
        case .claude:
            return L10n.text("ui.runtime_optional")
        }
    }

    var brandAssetName: String {
        switch kind {
        case .codex:
            return "ChatGPT"
        case .claude:
            return "Claude"
        }
    }
}

/// 未读只是一条历史结果的轻量提示，不承担进行状态，也不参与点击命中区域。
/// 视觉点隐藏给 VoiceOver，完整语义由会话行的 accessibilityValue 提供。
struct SessionUnreadIndicator: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Circle()
            .fill(tokens.primaryAction)
            .frame(width: 7, height: 7)
            .overlay {
                Circle()
                    .stroke(tokens.background.opacity(0.72), lineWidth: 0.75)
            }
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// 会话列表里的运行时标识使用中性胶囊承载品牌图标和名称。
/// 它需要比普通元数据更容易扫读，但不能抢过会话标题和需要处理的状态。
struct SessionRuntimeBadge: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let presentation: SessionRuntimePresentation
    var compact = false

    init(session: AgentSession, compact: Bool = false) {
        presentation = SessionRuntimePresentation(session: session)
        self.compact = compact
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let iconSize: CGFloat = compact ? 10 : 12

        HStack(spacing: compact ? 3 : 4) {
            Image(presentation.brandAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)

            Text(presentation.title)
                .lineLimit(1)
        }
        .font(themeStore.uiFont(size: compact ? 9 : 10, weight: .medium))
        .foregroundStyle(tokens.secondaryText)
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, compact ? 1.5 : 2)
        .background(tokens.elevatedSurface.opacity(0.76), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tokens.border.opacity(0.54), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 置顶属于用户主动设置的稳定状态，用品牌紫实底与白色钉子提升扫读辨识度。
/// 组件统一服务规划 Tab、工作区最近规划和侧栏，避免三个入口各自使用不同强调方式。
struct SessionPinnedBadge: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var compact = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        // 色块只承担置顶强调，不应比同一列表中的运行时图标更抢眼。
        let side: CGFloat = compact ? 14 : 17
        let cornerRadius: CGFloat = compact ? 4 : 5

        Image(systemName: "pin.fill")
            .font(themeStore.uiFont(size: compact ? 7 : 8, weight: .bold))
            .foregroundStyle(tokens.primaryActionForeground)
            .frame(width: side, height: side)
            .background(
                tokens.primaryAction,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(tokens.primaryActionForeground.opacity(0.18), lineWidth: 0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("ui.pinned"))
            .fixedSize()
    }
}

/// 使用 Codex 与 Claude Code 桌面端都采用的经典三节点分支拓扑。
/// 自绘可以避免 SF Symbol 的三角轮廓，同时维持小尺寸下的圆角描边与清晰度。
struct SessionBranchIcon: View {
    let size: CGFloat

    var body: some View {
        SessionBranchGlyph()
            .stroke(
                style: StrokeStyle(
                    lineWidth: max(0.75, size * 0.08125),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: size, height: size)
            .fixedSize()
    }
}

private struct SessionBranchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2
        )
        let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
            CGPoint(x: origin.x + side * x, y: origin.y + side * y)
        }
        let nodeRadius = side * 0.11875
        let upperNode = point(0.296875, 0.234375)
        let lowerNode = point(0.296875, 0.765625)
        let branchNode = point(0.75, 0.65625)

        var path = Path()
        for center in [upperNode, lowerNode, branchNode] {
            path.addEllipse(
                in: CGRect(
                    x: center.x - nodeRadius,
                    y: center.y - nodeRadius,
                    width: nodeRadius * 2,
                    height: nodeRadius * 2
                )
            )
        }

        path.move(to: point(0.296875, 0.353125))
        path.addLine(to: point(0.296875, 0.646875))
        path.move(to: point(0.296875, 0.40625))
        path.addCurve(
            to: point(0.63125, 0.65625),
            control1: point(0.296875, 0.5875),
            control2: point(0.44375, 0.65625)
        )
        return path
    }
}

enum SessionLibraryStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case needsAttention
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.text("ui.all_status")
        case .active: return L10n.text("ui.running")
        case .needsAttention: return L10n.text("ui.need_to_be_processed")
        case .history: return L10n.text("ui.history")
        }
    }

    func includes(_ session: AgentSession) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return session.isRunning
        case .needsAttention:
            return session.status == SessionStatus.waitingForApproval.rawValue ||
                session.status == SessionStatus.waitingForInput.rawValue ||
                session.pendingApproval != nil ||
                session.pendingUserInput != nil ||
                session.status == SessionStatus.failed.rawValue
        case .history:
            return !session.isRunning
        }
    }
}

/// 会话生命周期是列表的第一层信息。保持输入顺序，只负责把仍在进行的任务和历史记录分开。
struct SessionListPartition: Equatable {
    let active: [AgentSession]
    let pinned: [AgentSession]
    let history: [AgentSession]

    init(active: [AgentSession], pinned: [AgentSession] = [], history: [AgentSession]) {
        self.active = active
        self.pinned = pinned
        self.history = history
    }

    init(sessions: [AgentSession]) {
        active = sessions.filter(\.isRunning)
        pinned = []
        history = sessions.filter { !$0.isRunning }
    }
}

/// 会话页空态必须依赖“已打开工作区”与连接状态，不能用会话数量反推目录是否存在。
/// 这里集中定义优先级，避免加载或错误被首次使用引导覆盖。
enum SessionListPresentationState: Equatable {
    case content
    case loading
    case searching
    case needsWorkspace
    case noSessions
    case noMatches
    case networkUnavailable
    case runtimeUnavailable(String)
    case loadFailed(String)

    static func resolve(
        hasVisibleSessions: Bool,
        hasOpenedWorkspace: Bool,
        isLoading: Bool,
        isSearching: Bool,
        isFiltering: Bool,
        isNetworkUnavailable: Bool,
        errorMessage: String?,
        connectionStatus: ConnectionStatus
    ) -> Self {
        guard !hasVisibleSessions else { return .content }

        if case .failed(let message) = connectionStatus {
            return .runtimeUnavailable(message)
        }
        if isNetworkUnavailable {
            return .networkUnavailable
        }
        if let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return .loadFailed(message)
        }
        if isLoading {
            return .loading
        }
        switch connectionStatus {
        case .idle, .testing:
            return .loading
        case .connected, .failed:
            break
        }
        if isSearching {
            return .searching
        }
        if isFiltering {
            return .noMatches
        }
        if !hasOpenedWorkspace {
            return .needsWorkspace
        }
        return .noSessions
    }
}

/// 完整会话库只展示轻量索引；消息历史仍在用户选中会话后按需加载。
struct SessionListView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var workspaceAppearanceStore: WorkspaceAppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var lifecycleCoordinator = SessionListLifecycleCoordinator()
    @State private var selectedWorkspaceID = "all"
    @State private var selectedStatus: SessionLibraryStatusFilter = .all
    @State private var keyboardSelectionID: SessionID?
    @FocusState private var hasListKeyboardFocus: Bool

    var onNewSession: ((NewSessionPresentationSource?) -> Void)?
    var onSelectSession: ((AgentSession) -> Void)?
    var onOpenWorkspaces: (() -> Void)?
    var manageConnections: (() -> Void)?
    var prefersTableDensity = false
    var usesCompactNavigation = false
    var bottomContentMargin: CGFloat = 16
    var newSessionPresentationNamespace: Namespace.ID?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        // 同一轮 body 求值内复用同一份轻量索引投影，避免每个 Section 的条件和内容
        // 访问都重新触发全量 filter / merge / sort。生命周期输入仍由当前快照驱动。
        let visibleSessions = self.visibleSessions
        let sessionPartition = makeSessionPartition(visibleSessions: visibleSessions)
        let historyDateGroups = makeHistoryDateGroups(sessionPartition: sessionPartition)
        let lifecycleInput = makeLifecycleInput(visibleSessions: visibleSessions)
        let presentationState = makePresentationState(hasVisibleSessions: !visibleSessions.isEmpty)
        // 宽屏把搜索放进顶栏；紧凑导航和辅助功能字号使用 navigationBarDrawer
        // 的完整原生搜索框，避免 toolbar 最小化搜索挤走操作和反复展开转场。
        let showsToolbarSearchField = !usesCompactNavigation && !dynamicTypeSize.isAccessibilitySize

        List {
            if hasActiveFilters {
                activeFilterChip(tokens: tokens)
                    .listRowInsets(.init(top: 4, leading: 20, bottom: 8, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if presentationState == .content {
                if !sessionPartition.active.isEmpty {
                    sessionSection(
                        title: L10n.text("ui.in_progress"),
                        sessions: sessionPartition.active,
                        isActiveSection: true,
                        tokens: tokens
                    )
                }

                if !sessionPartition.pinned.isEmpty {
                    sessionSection(
                        title: L10n.text("ui.pinned"),
                        sessions: sessionPartition.pinned,
                        isActiveSection: false,
                        tokens: tokens
                    )
                }

                ForEach(historyDateGroups) { group in
                    sessionSection(
                        title: dateBucketTitle(group.bucket),
                        sessions: group.sessions,
                        isActiveSection: false,
                        tokens: tokens
                    )
                }
            } else {
                sessionListUnavailableContent(state: presentationState, tokens: tokens)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Gateway 过滤后当前页可能没有可见结果但仍给出 nextCursor，入口必须独立于空态展示。
            if sessionStore.isSessionSearchActive && sessionStore.sessionSearchHasMore {
                Button {
                    Task { await sessionStore.loadMoreSessionSearchResults() }
                } label: {
                    HStack(spacing: 8) {
                        if sessionStore.isLoadingMoreSessionSearchResults {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text(sessionStore.isLoadingMoreSessionSearchResults ? L10n.text("ui.searching_continues") : L10n.text("ui.continue_searching"))
                    }
                    .font(themeStore.uiFont(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.secondaryText)
                .disabled(sessionStore.isLoadingMoreSessionSearchResults)
                .accessibilityIdentifier("sessions.search.loadMore")
                .listRowInsets(.init(top: 4, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(12)
        // 最新设计把日期恢复成轻量粘性标题，正文保持完全扁平；行距与分隔线由行组件统一控制。
        .listRowSpacing(0)
        .scrollContentBackground(.hidden)
        .background(tokens.background.ignoresSafeArea())
        .workbenchSoftBottomScrollEdge()
        // 只清除原生搜索模式下 List 重复的自动留白；负边距会把首行推进
        // 粘性标题的裁切区域，因此必须让内容继续停留在系统安全边界内。
        .sessionListNativeSearchTopMargin(isEnabled: !showsToolbarSearchField)
        .contentMargins(.bottom, bottomContentMargin, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            TapGesture().onEnded {
                // 原生 navigationBarDrawer 和宽屏顶栏搜索都位于 List 外；列表内任意点击
                // 都可以安全结束第一响应者，同时不清空查询词或改变当前搜索结果。
                dismissSessionSearchKeyboard()
            }
        )
        .focusable()
        .focused($hasListKeyboardFocus)
        .onKeyPress(keys: [.upArrow, .downArrow, .return]) { keyPress in
            handleListKeyPress(keyPress)
        }
        .onScrollPhaseChange { _, newPhase in
            lifecycleCoordinator.setScrollPhase(
                newPhase,
                latestMembership: lifecycleInput.membership
            )
        }
        .animation(sessionRegroupAnimation, value: lifecycleCoordinator.membership)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sessionListNativeSearchable(
            isEnabled: !showsToolbarSearchField,
            text: $sessionStore.sessionSearchQuery,
            prompt: Text(L10n.text("ui.search_session")),
            tintColor: tokens.primaryText,
            toolbarSurface: tokens.background,
            colorScheme: colorScheme,
            onSubmit: dismissSessionSearchKeyboard
        )
        .toolbar {
            if showsToolbarSearchField {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) {
                        sessionSearchField(tokens: tokens)
                    }
                    // 自定义搜索框已经自带表面，隐藏系统共享玻璃，避免深色模式叠出白色底板。
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        sessionSearchField(tokens: tokens)
                    }
                }
            }
            if let manageConnections {
                ToolbarItem(placement: .topBarLeading) {
                    HostSwitcherMenu(
                        presentation: .toolbar,
                        manageConnections: manageConnections
                    )
                    .simultaneousGesture(
                        TapGesture().onEnded { dismissSessionSearchKeyboard() }
                    )
                }
                // iOS 26+ 用固定间隔拆分玻璃组；旧系统依靠普通工具栏布局即可。
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarLeading)
                }
            }
            // 筛选、刷新合入同一个菜单；加号保持独立，常驻圆形工具按钮固定为两个。
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu(tokens: tokens)
                    .simultaneousGesture(
                        TapGesture().onEnded { dismissSessionSearchKeyboard() }
                    )
            }
            newSessionToolbarItem(tokens: tokens)
        }
        .task {
            await sessionStore.refreshSessionLibraryIndex()
        }
        .onAppear {
            synchronizeLifecycle(lifecycleInput)
        }
        .onChange(of: lifecycleInput) { _, newInput in
            synchronizeLifecycle(newInput)
        }
    }

    private func sessionSearchField(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)

            TextField(L10n.text("ui.search_session"), text: $sessionStore.sessionSearchQuery)
                .font(themeStore.uiFont(size: 14))
                .foregroundStyle(tokens.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { dismissSessionSearchKeyboard() }
                .lineLimit(1)
                .accessibilityIdentifier("sessions.search")

            if sessionStore.isSessionSearchActive {
                Button {
                    sessionStore.sessionSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(themeStore.uiFont(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.tertiaryText)
                .accessibilityLabel(L10n.text("ui.clear_search"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .frame(minWidth: 260, idealWidth: 360, maxWidth: 420)
        .background(tokens.surface.opacity(0.74), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tokens.border.opacity(0.52), lineWidth: 1)
        }
    }

    @ToolbarContentBuilder
    private func newSessionToolbarItem(tokens: ThemeTokens) -> some ToolbarContent {
        if let newSessionPresentationNamespace, #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) {
                newSessionToolbarButton(
                    tokens: tokens,
                    source: .sessionsToolbar(hasNamespace: true)
                )
            }
            // ToolbarContent source 只包住加号，不能把刷新或筛选一起作为返回锚点。
            .matchedTransitionSource(
                id: NewSessionPresentationSource
                    .sessionsToolbarNewSession
                    .transitionSourceID,
                in: newSessionPresentationNamespace
            )
        } else {
            // iOS 18–25 保留新建入口，但不注册仅新系统支持的 Toolbar zoom 来源。
            ToolbarItem(placement: .topBarTrailing) {
                newSessionToolbarButton(
                    tokens: tokens,
                    source: .sessionsToolbar(hasNamespace: false)
                )
            }
        }
    }

    private func newSessionToolbarButton(
        tokens: ThemeTokens,
        source: NewSessionPresentationSource?
    ) -> some View {
        sessionListToolbarButton(
            systemImage: "plus",
            accessibilityLabel: L10n.text("ui.new_session_3da224c4"),
            tokens: tokens,
            isPrimary: true,
            action: {
                presentNewSession(source: source)
            }
        )
        .accessibilityIdentifier("sessions.newSession")
    }

    /// 使用系统工具栏按钮，让不同系统版本自行处理材质、按下反馈和命中区域。
    private func sessionListToolbarButton(
        systemImage: String,
        accessibilityLabel: String,
        tokens: ThemeTokens,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            WorkbenchChromeIcon(systemName: systemImage)
        }
        // 顶部导航保留品牌紫；工具栏仅靠明度区分主次，避免刷新与新建重复着色。
        .foregroundStyle(isPrimary ? tokens.primaryText : tokens.secondaryText)
        .tint(tokens.secondaryText)
        .accessibilityLabel(accessibilityLabel)
    }

    private var visibleSessions: [AgentSession] {
        sessionStore.sessionLibrarySessions.filter { session in
            (selectedWorkspaceID == "all" || session.projectID == selectedWorkspaceID) &&
                selectedStatus.includes(session)
        }
    }

    private func makeSessionPartition(visibleSessions: [AgentSession]) -> SessionListPartition {
        let membership = lifecycleCoordinator.hasObservedInput
            ? lifecycleCoordinator.membership
            : SessionListMembership(sessions: visibleSessions)
        var latestByID: [SessionID: AgentSession] = [:]
        for session in visibleSessions {
            latestByID[session.id] = session
        }
        let history = membership.historyIDs.compactMap { latestByID[$0] }
        let pinned = history.filter { sessionStore.isSessionPinned($0.id) }
        return SessionListPartition(
            active: membership.activeIDs.compactMap { latestByID[$0] },
            pinned: pinned,
            history: history.filter { !sessionStore.isSessionPinned($0.id) }
        )
    }

    private func makeHistoryDateGroups(
        sessionPartition: SessionListPartition
    ) -> [SessionHistoryDateGroup] {
        SessionListPresentation.historyDateGroups(
            sessions: sessionPartition.history,
            now: Date(),
            calendar: .autoupdatingCurrent
        )
    }

    private var rowDensity: SessionIndexRowDensity {
        SessionIndexRowDensity.resolved(
            prefersTable: prefersTableDensity,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    private func makeLifecycleInput(visibleSessions: [AgentSession]) -> SessionListLifecycleInput {
        SessionListLifecycleInput(
            membership: SessionListMembership(sessions: visibleSessions),
            // Haptic 不跟随搜索和筛选结果裁剪，否则切换筛选会把同一终态误当成新事件。
            feedbackObservations: sessionStore.sessions.map { session in
                SessionLifecycleObservation(
                    session: session,
                    foregroundActivity: sessionStore.foregroundActivity(for: session.id)
                )
            },
            context: SessionListLifecycleContext(
                profileID: appStore.activeHostScope.profileID,
                workspaceID: selectedWorkspaceID,
                statusFilterID: selectedStatus.id,
                searchQuery: sessionStore.sessionSearchQuery
            )
        )
    }

    private var sessionRegroupAnimation: Animation? {
        guard !reduceMotion, !lifecycleCoordinator.isUserScrolling else {
            return nil
        }
        return MimiMotion.stateTransition.animation(reduceMotion: false)
    }

    private func synchronizeLifecycle(_ input: SessionListLifecycleInput) {
        if let feedback = lifecycleCoordinator.observe(input) {
            MimiHaptics.fire(feedback)
        }
    }

    private func makePresentationState(hasVisibleSessions: Bool) -> SessionListPresentationState {
        SessionListPresentationState.resolve(
            hasVisibleSessions: hasVisibleSessions,
            // sidebarProjects 只包含 rememberWorkspace 记录的已打开目录，不包含后端候选项目。
            hasOpenedWorkspace: !sessionStore.sidebarProjects.isEmpty,
            isLoading: sessionStore.isLoading,
            isSearching: sessionStore.isSessionSearchActive && sessionStore.isSearchingRemoteSessionResults,
            isFiltering: sessionStore.isSessionSearchActive || selectedWorkspaceID != "all" || selectedStatus != .all,
            isNetworkUnavailable: sessionStore.isNetworkUnavailable,
            errorMessage: sessionStore.errorMessage,
            connectionStatus: appStore.connectionStatus
        )
    }

    @ViewBuilder
    private func sessionListUnavailableContent(
        state: SessionListPresentationState,
        tokens: ThemeTokens
    ) -> some View {
        switch state {
        case .content:
            EmptyView()
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(L10n.text("ui.loading_sessions"))
                    .font(themeStore.uiFont(size: 13, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
            }
            .padding(.vertical, 32)
            .accessibilityIdentifier("sessions.loading")
        case .searching:
            VStack(spacing: 10) {
                ProgressView()
                Text(L10n.text("ui.searching_historical_conversations"))
                    .font(themeStore.uiFont(size: 13, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
            }
            .padding(.vertical, 24)
            .accessibilityIdentifier("sessions.search.initialLoading")
        case .needsWorkspace:
            ContentUnavailableView {
                Label(L10n.text("ui.no_workspace_has_been_opened_yet"), systemImage: "folder.badge.plus")
            } description: {
                Text(L10n.text("ui.open_a_workspace_to_load_its_sessions"))
            } actions: {
                Button(L10n.text("ui.go_to_work_area")) {
                    onOpenWorkspaces?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(tokens.primaryAction)
                .accessibilityIdentifier("sessions.empty.openWorkspaces")
            }
            .accessibilityIdentifier("sessions.empty.needsWorkspace")
        case .noSessions:
            ContentUnavailableView {
                Label(L10n.text("ui.no_sessions_yet"), systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(L10n.text("ui.new_sessions_created_from_a_workspace_appear_here"))
            } actions: {
                Button(L10n.text("ui.new_session")) {
                    presentNewSession(source: nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(tokens.primaryAction)
            }
            .accessibilityIdentifier("sessions.empty.noSessions")
        case .noMatches:
            ContentUnavailableView {
                Label(L10n.text("ui.no_matching_session"), systemImage: "magnifyingglass")
            } description: {
                Text(L10n.text("ui.try_changing_keywords_or_filter_conditions"))
            }
            .accessibilityIdentifier("sessions.empty.noMatches")
        case .networkUnavailable:
            sessionFailureContent(
                title: L10n.text("ui.network_is_unavailable"),
                message: L10n.text("ui.the_network_is_unavailable_and_synchronization_has_been"),
                systemImage: "wifi.slash",
                tokens: tokens
            )
        case .runtimeUnavailable(let message):
            sessionFailureContent(
                title: L10n.text("ui.session_runtime_unavailable"),
                message: message,
                systemImage: "exclamationmark.triangle",
                tokens: tokens
            )
        case .loadFailed(let message):
            sessionFailureContent(
                title: L10n.text("ui.session_loading_failed"),
                message: message,
                systemImage: "exclamationmark.triangle",
                tokens: tokens
            )
        }
    }

    private func sessionFailureContent(
        title: String,
        message: String,
        systemImage: String,
        tokens: ThemeTokens
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button(L10n.text("ui.try_again"), action: retrySessionList)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(tokens.primaryAction)
                .accessibilityIdentifier("sessions.empty.retry")
        }
        .accessibilityIdentifier("sessions.empty.failure")
    }

    private func retrySessionList() {
        Task {
            await appStore.preflightConnection()
            await sessionStore.refreshSessionLibraryIndex(authoritative: true)
        }
    }

    @ViewBuilder
    private func sessionSection(
        title: String,
        sessions: [AgentSession],
        isActiveSection: Bool,
        tokens: ThemeTokens
    ) -> some View {
        Section {
            sessionRows(sessions, isActiveSection: isActiveSection, tokens: tokens)
        } header: {
            Text(title)
                .font(themeStore.uiFont(size: 11, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func sessionRows(
        _ sessions: [AgentSession],
        isActiveSection: Bool,
        tokens: ThemeTokens
    ) -> some View {
        let profileID = appStore.activeHostScope.profileID
        let projectIcons = workspaceAppearanceStore.projectIconContents(
            profileID: profileID,
            projectIDs: sessionStore.sidebarProjects.map(\.id)
        )

        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
            let previousProjectID = index > sessions.startIndex
                ? sessions[index - 1].projectID
                : nil
            let startsProjectRun = previousProjectID != session.projectID
            let projectIcon = projectIcons[session.projectID]
                ?? workspaceAppearanceStore.projectIconContent(
                    profileID: profileID,
                    projectID: session.projectID
                )

            Button {
                dismissSessionSearchKeyboard()
                keyboardSelectionID = nil
                select(session)
            } label: {
                SessionIndexRow(
                    session: session,
                    foregroundActivity: sessionStore.foregroundActivity(for: session.id),
                    isSelected: session.id == highlightedSessionID,
                    isPinned: sessionStore.isSessionPinned(session.id),
                    isArchived: sessionStore.isSessionArchived(session.id),
                    reminder: sessionStore.sessionReminder(for: session.id),
                    isObserving: sessionStore.isSessionObserving(session),
                    isExternalReadOnly: sessionStore.isExternalReadOnlySession(session),
                    isUnread: sessionStore.isHistorySessionUnread(session),
                    density: rowDensity,
                    searchSnippet: sessionStore.sessionSearchSnippet(for: session.id),
                    projectIcon: projectIcon,
                    showsProjectAnchor: startsProjectRun,
                    reservesProjectAnchor: rowDensity == .table,
                    drawsDivider: index != sessions.index(before: sessions.endIndex),
                    // 滚动冻结期间已结束的会话仍留在“进行中”原位，必须显式展示最新终态。
                    showsNeutralHistoryStatus: isActiveSection && !session.isRunning
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(SessionIndexRowButtonStyle(pressedFill: tokens.selectionFill))
            .hoverEffect(.highlight)
            .accessibilityElement(children: .combine)
            .accessibilityValue(
                sessionStore.isHistorySessionUnread(session)
                    ? L10n.text("ui.unread_result")
                    : ""
            )
            .accessibilityIdentifier("sessions.row.\(session.id)")
            .sessionRowActions(session)
            .sessionRowSwipeActions(session)
            .listRowInsets(
                .init(
                    top: 0,
                    leading: 20,
                    bottom: 0,
                    trailing: 20
                )
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private var highlightedSessionID: SessionID? {
        keyboardSelectionID ?? sessionStore.selectedSessionID
    }

    private var orderedVisibleSessions: [AgentSession] {
        // 键盘事件发生在 body 求值之外，按当前筛选快照重新计算一次即可；正文渲染仍复用
        // body 内的单份投影，避免每个 Section 重复过滤和排序。
        let partition = makeSessionPartition(visibleSessions: visibleSessions)
        let dateGroups = makeHistoryDateGroups(sessionPartition: partition)
        return partition.active + partition.pinned + dateGroups.flatMap(\.sessions)
    }

    private func handleListKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        switch keyPress.key {
        case .upArrow:
            moveKeyboardSelection(by: -1)
            return .handled
        case .downArrow:
            moveKeyboardSelection(by: 1)
            return .handled
        case .return:
            guard let session = keyboardSelectedSession ?? orderedVisibleSessions.first else {
                return .ignored
            }
            select(session)
            return .handled
        default:
            return .ignored
        }
    }

    private var keyboardSelectedSession: AgentSession? {
        guard let highlightedSessionID else { return nil }
        return orderedVisibleSessions.first { $0.id == highlightedSessionID }
    }

    private func moveKeyboardSelection(by offset: Int) {
        guard !orderedVisibleSessions.isEmpty else { return }
        let currentIndex = highlightedSessionID.flatMap { currentID in
            orderedVisibleSessions.firstIndex { $0.id == currentID }
        }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(max(currentIndex + offset, 0), orderedVisibleSessions.count - 1)
        } else {
            nextIndex = offset < 0 ? orderedVisibleSessions.count - 1 : 0
        }
        keyboardSelectionID = orderedVisibleSessions[nextIndex].id
    }

    private var hasActiveFilters: Bool {
        selectedWorkspaceID != "all" || selectedStatus != .all
    }

    private var activeFilterTitle: String {
        var parts: [String] = []
        if selectedWorkspaceID != "all",
           let project = sessionStore.sidebarProjects.first(where: { $0.id == selectedWorkspaceID }) {
            parts.append(project.name)
        }
        if selectedStatus != .all {
            parts.append(selectedStatus.title)
        }
        return parts.joined(separator: " · ")
    }

    private func activeFilterChip(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Text(activeFilterTitle)
                .font(themeStore.uiFont(size: 12, weight: .semibold))
                .lineLimit(1)

            Button {
                selectedWorkspaceID = "all"
                selectedStatus = .all
            } label: {
                Image(systemName: "xmark")
                    .font(themeStore.uiFont(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("ui.clear"))
        }
        .foregroundStyle(tokens.secondaryText)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(tokens.elevatedSurface, in: Capsule())
        .overlay {
            Capsule()
                .stroke(tokens.border.opacity(0.7), lineWidth: 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dateBucketTitle(_ bucket: SessionHistoryDateBucket) -> String {
        switch bucket {
        case .today: L10n.text("ui.today")
        case .yesterday: L10n.text("ui.yesterday")
        case .thisWeek: L10n.text("ui.this_week")
        case .thisMonth: L10n.text("ui.this_month")
        case .earlier: L10n.text("ui.earlier")
        }
    }

    private func filterMenu(tokens: ThemeTokens) -> some View {
        Menu {
            Button {
                Task { await sessionStore.refreshSessionLibraryIndex(authoritative: true) }
            } label: {
                Label(L10n.text("ui.refresh_session_library"), systemImage: "arrow.clockwise")
            }

            Section(L10n.text("ui.workspace")) {
                Button {
                    selectedWorkspaceID = "all"
                } label: {
                    Label(L10n.text("ui.all_workspaces"), systemImage: selectedWorkspaceID == "all" ? "checkmark" : "folder")
                }
                ForEach(sessionStore.sidebarProjects) { project in
                    Button {
                        selectedWorkspaceID = project.id
                    } label: {
                        Label(project.name, systemImage: selectedWorkspaceID == project.id ? "checkmark" : "folder")
                    }
                }
            }
            Section(L10n.text("ui.status")) {
                ForEach(SessionLibraryStatusFilter.allCases) { filter in
                    Button {
                        selectedStatus = filter
                    } label: {
                        Label(filter.title, systemImage: selectedStatus == filter ? "checkmark" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
        } label: {
            WorkbenchChromeIcon(systemName: "ellipsis")
                .foregroundStyle(tokens.secondaryText)
        }
        .accessibilityLabel(
            hasActiveFilters
                ? L10n.format("ui.value_value", L10n.text("ui.filter_sessions"), activeFilterTitle)
                : L10n.text("ui.filter_sessions")
        )
        .accessibilityIdentifier("sessions.filter")
    }

    private func presentNewSession(source: NewSessionPresentationSource?) {
        dismissSessionSearchKeyboard()
        if let onNewSession {
            onNewSession(source)
        } else {
            Task { await sessionStore.startNewSession() }
        }
    }

    private func select(_ session: AgentSession) {
        if let onSelectSession {
            onSelectSession(session)
        } else {
            Task { await sessionStore.selectSession(session) }
        }
    }

    private func dismissSessionSearchKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

private struct SessionIndexRowButtonStyle: ButtonStyle {
    let pressedFill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? pressedFill.opacity(0.72) : .clear)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct SessionIndexRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: AgentSession
    let foregroundActivity: SessionForegroundActivity?
    let isSelected: Bool
    let isPinned: Bool
    let isArchived: Bool
    let reminder: SessionReminder?
    let isObserving: Bool
    let isExternalReadOnly: Bool
    var isUnread = false
    let density: SessionIndexRowDensity
    var searchSnippet: String? = nil
    var projectIcon: WorkspaceProjectIconContent? = nil
    var showsProjectAnchor = false
    var reservesProjectAnchor = false
    var drawsDivider = false
    var drawsSelectionBackground = true
    var showsNeutralHistoryStatus = false

    static func metadataDirectoryText(for session: AgentSession) -> String {
        // 同一项目可能同时存在多个 worktree；优先展示真实工作目录，
        // 只有旧数据缺少 dir 时才回退项目名，避免列表行失去区分度。
        session.dir.isEmpty ? session.project : session.dir
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            switch density {
            case .compact:
                compactContent(tokens: tokens)
            case .table:
                tableContent(tokens: tokens)
            case .rail:
                railContent(tokens: tokens)
            }
        }
        .padding(.horizontal, density.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: density.minimumHeight, alignment: .leading)
        .background {
            if isSelected && drawsSelectionBackground {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tokens.selectionFill)
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(tokens.primaryAction)
                    .frame(width: 3)
                    .padding(.vertical, 7)
                    .padding(.leading, 2)
            }
        }
        .overlay(alignment: .bottom) {
            if drawsDivider {
                Rectangle()
                    .fill(tokens.border.opacity(0.46))
                    .frame(height: 0.5)
                    .padding(.leading, dividerLeadingInset)
            }
        }
        .frame(minHeight: density == .rail ? 34 : 44)
    }

    private func compactContent(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 7) {
                titleContent(tokens: tokens, compactPinnedBadge: true)
                Spacer(minLength: 8)
                stableStateIcons(tokens: tokens)
                animatedStatusLabel(tokens: tokens)
                if isUnread {
                    SessionUnreadIndicator()
                }
            }

            HStack(spacing: 6) {
                compactProjectAnchor(tokens: tokens)
                directoryText(tokens: tokens)
                Spacer(minLength: 8)
                timestamp(tokens: tokens)
            }

            if let searchSnippet, !searchSnippet.isEmpty {
                Text(searchSnippet)
                    .font(themeStore.uiFont(size: 11, weight: .regular))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
            }
        }
    }

    private func tableContent(tokens: ThemeTokens) -> some View {
        HStack(spacing: 10) {
            if reservesProjectAnchor {
                projectAnchor(tokens: tokens)
                    .frame(width: 30, height: 30)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    titleContent(tokens: tokens, compactPinnedBadge: true)

                    let preview = SessionListPresentation.previewDisplayText(for: session)
                    if !preview.isEmpty {
                        Text(preview)
                            .font(themeStore.uiFont(size: 13, weight: .regular))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Text(session.project)
                        .font(themeStore.uiFont(size: density.metadataFontSize, weight: .medium))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    stableStateIcons(tokens: tokens)
                    Spacer(minLength: 8)
                    animatedStatusLabel(tokens: tokens)
                    timestamp(tokens: tokens)
                    if isUnread {
                        SessionUnreadIndicator()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func projectAnchor(tokens: ThemeTokens) -> some View {
        if showsProjectAnchor, let projectIcon {
            WorkspaceProjectIconTile(content: projectIcon, size: 30, tokens: tokens)
        } else {
            Color.clear
        }
    }

    private func railContent(tokens: ThemeTokens) -> some View {
        HStack(spacing: 7) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(themeStore.uiFont(size: 8, weight: .bold))
                    .foregroundStyle(tokens.primaryAction)
                    .accessibilityHidden(true)
            }

            Text(visibleTitle)
                .font(themeStore.uiFont(size: density.titleFontSize, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 6)

            if shouldShowStatusLabel {
                Circle()
                    .fill(statusColor(tokens: tokens))
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(status.title)
            } else if isUnread {
                SessionUnreadIndicator()
            }
        }
    }

    @ViewBuilder
    private func titleContent(tokens: ThemeTokens, compactPinnedBadge: Bool) -> some View {
        if isPinned {
            SessionPinnedBadge(compact: compactPinnedBadge)
        }

        Text(visibleTitle)
            .font(themeStore.uiFont(size: density.titleFontSize, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(tokens.primaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
    }

    @ViewBuilder
    private func stableStateIcons(tokens: ThemeTokens) -> some View {
        if isArchived {
            Image(systemName: "archivebox.fill")
                .font(themeStore.uiFont(size: density.statusIconSize, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
                .accessibilityLabel(L10n.text("ui.archived"))
        }
        if reminder != nil {
            Image(systemName: "bell.fill")
                .font(themeStore.uiFont(size: density.statusIconSize, weight: .semibold))
                .foregroundStyle(tokens.warning)
                .accessibilityLabel(L10n.text("ui.reminder"))
        }
        if isObserving || isExternalReadOnly {
            Image(systemName: "eye")
                .font(themeStore.uiFont(size: density.statusIconSize, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
                .accessibilityLabel(L10n.text("ui.just_observe"))
        }
    }

    @ViewBuilder
    private func compactProjectAnchor(tokens: ThemeTokens) -> some View {
        if showsProjectAnchor, let projectIcon {
            WorkspaceProjectIconTile(
                content: projectIcon,
                size: 12,
                tokens: tokens
            )
        } else {
            // 紧凑布局没有 30pt 项目列；仅段首展示一次缩小锚点，后续行保留
            // 同宽空槽以维持目录文本对齐，不再把同一个项目图标逐行重复。
            Color.clear
                .frame(width: 12, height: 12)
        }
    }

    private func directoryText(tokens: ThemeTokens) -> some View {
        Text(SessionListPresentation.directoryDisplayText(for: session))
            .font(themeStore.uiFont(size: density.metadataFontSize, weight: .regular))
            .foregroundStyle(tokens.tertiaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel(
                L10n.format(
                    "ui.directory_value",
                    Self.metadataDirectoryText(for: session)
                )
            )
            .layoutPriority(1)
    }

    @ViewBuilder
    private func animatedStatusLabel(tokens: ThemeTokens) -> some View {
        ZStack(alignment: .trailing) {
            if shouldShowStatusLabel {
                statusLabel(tokens: tokens)
                    .id(status)
                    .transition(.opacity)
            }
        }
        .animation(
            MimiMotion.stateTransition.animation(reduceMotion: reduceMotion),
            value: status
        )
    }

    @ViewBuilder
    private func timestamp(tokens: ThemeTokens) -> some View {
        if !timestampText.isEmpty {
            Text(timestampText)
                .font(themeStore.uiFont(size: density.metadataFontSize, weight: .regular))
                .foregroundStyle(tokens.tertiaryText)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var visibleTitle: String {
        SessionListPresentation.titleDisplayText(for: session)
    }

    private var dividerLeadingInset: CGFloat {
        density.horizontalPadding + (density == .table && reservesProjectAnchor ? 40 : 0)
    }

    private var status: AgentSessionDisplayStatus {
        return session.displayStatus(foregroundActivity: foregroundActivity)
    }

    private var shouldShowStatusLabel: Bool {
        showsNeutralHistoryStatus ||
            !(session.status == SessionStatus.history.rawValue && status.tone == .neutral)
    }

    @ViewBuilder
    private func statusLabel(tokens: ThemeTokens) -> some View {
        HStack(spacing: 4) {
            if status.showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(statusColor(tokens: tokens))
            } else {
                Image(systemName: status.systemImage)
                    .font(themeStore.uiFont(size: density.statusIconSize, weight: .semibold))
            }
            Text(status.title)
                .lineLimit(1)
        }
        .font(themeStore.uiFont(size: density.statusFontSize, weight: .semibold))
        .foregroundStyle(statusColor(tokens: tokens))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.title)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func statusColor(tokens: ThemeTokens) -> Color {
        switch status.tone {
        case .active: return tokens.secondaryText
        case .warning: return tokens.warning
        case .danger: return .red
        case .complete, .neutral: return tokens.tertiaryText
        }
    }

    private var timestampText: String {
        guard let date = session.recencyAt ?? session.updatedAt ?? session.createdAt else { return "" }
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        if Calendar.current.isDateInYesterday(date) {
            return L10n.text("ui.yesterday")
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()
}

private enum SessionReviewScope: String, CaseIterable, Identifiable {
    case uncommittedChanges
    case baseBranch
    case commit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uncommittedChanges: return L10n.text("ui.changes_not_committed")
        case .baseBranch: return L10n.text("ui.relative_base_branch")
        case .commit: return L10n.text("ui.specify_submission")
        }
    }

    var systemImage: String {
        switch self {
        case .uncommittedChanges: return "pencil.and.list.clipboard"
        case .baseBranch: return "arrow.triangle.branch"
        case .commit: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

struct SessionReviewSheet: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let session: AgentSession
    @State private var scope: SessionReviewScope = .uncommittedChanges
    @State private var baseBranch = ""
    @State private var commitSHA = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Form {
                Section(L10n.text("ui.review_goals")) {
                    Picker(L10n.text("ui.target_type"), selection: $scope) {
                        ForEach(SessionReviewScope.allCases) { option in
                            Label(option.title, systemImage: option.systemImage)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }

                switch scope {
                case .uncommittedChanges:
                    Section {
                        Label(L10n.text("ui.review_all_uncommitted_changes_in_the_current_workspace"), systemImage: "info.circle")
                            .foregroundStyle(tokens.secondaryText)
                    }
                case .baseBranch:
                    Section {
                        TextField(L10n.text("ui.for_example_main"), text: $baseBranch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityIdentifier("sessions.review.baseBranch")
                    } header: {
                        Text(L10n.text("ui.base_branch"))
                    } footer: {
                        Text(normalizedBaseBranch.isEmpty ? L10n.text("ui.please_enter_a_non_empty_branch_name") : L10n.format("ui.the_current_branch_will_be_reviewed_for_differences", normalizedBaseBranch))
                            .foregroundStyle(normalizedBaseBranch.isEmpty ? tokens.warning : tokens.tertiaryText)
                    }
                case .commit:
                    Section {
                        TextField(L10n.text("ui.commit_sha"), text: $commitSHA)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityIdentifier("sessions.review.commit")
                    } header: {
                        Text(L10n.text("ui.submit"))
                    } footer: {
                        Text(normalizedCommitSHA.isEmpty ? L10n.text("ui.please_enter_a_non_empty_commit_sha") : L10n.format("ui.only_submission_value_will_be_reviewed", normalizedCommitSHA))
                            .foregroundStyle(normalizedCommitSHA.isEmpty ? tokens.warning : tokens.tertiaryText)
                    }
                }

                Section {
                    Label(L10n.text("ui.review_is_always_executed_within_the_current_session"), systemImage: "lock.shield")
                        .foregroundStyle(tokens.tertiaryText)
                }

                if let submissionError {
                    Section {
                        Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(tokens.warning)
                    }
                }
            }
            .font(themeStore.uiFont(.body))
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle(L10n.text("ui.start_code_review"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(L10n.text("ui.start"))
                        }
                    }
                    .disabled(isSubmitting || session.isRunning || normalizedTarget == nil)
                    .accessibilityIdentifier("sessions.review.submit")
                }
            }
        }
        .tint(tokens.primaryAction)
        .interactiveDismissDisabled(isSubmitting)
        .presentationDetents([.medium, .large])
    }

    private var normalizedBaseBranch: String {
        baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedCommitSHA: String {
        commitSHA.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedTarget: CodexAppServerReviewTarget? {
        switch scope {
        case .uncommittedChanges:
            return .uncommittedChanges
        case .baseBranch:
            guard !normalizedBaseBranch.isEmpty else { return nil }
            return .baseBranch(normalizedBaseBranch)
        case .commit:
            guard !normalizedCommitSHA.isEmpty else { return nil }
            return .commit(sha: normalizedCommitSHA)
        }
    }

    private func submit() {
        guard !isSubmitting, !session.isRunning, let target = normalizedTarget else { return }
        isSubmitting = true
        submissionError = nil
        Task {
            let didStart = await sessionStore.startReview(session, target: target)
            isSubmitting = false
            if didStart {
                dismiss()
            } else {
                submissionError = sessionStore.statusMessage ?? L10n.text("ui.review_failed_to_start_please_try_again_later")
            }
        }
    }
}

struct SessionRenameSheet: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss

    let session: AgentSession
    @State private var name: String
    @State private var isSaving = false

    init(session: AgentSession) {
        self.session = session
        _name = State(initialValue: session.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("ui.session_name")) {
                    TextField(L10n.text("ui.enter_name"), text: $name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit(save)
                }
            }
            .navigationTitle(L10n.text("ui.rename_session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? L10n.text("ui.saving_6644f061") : L10n.text("ui.save"), action: save)
                        .disabled(isSaving || normalizedName.isEmpty || normalizedName == session.title)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !isSaving, !normalizedName.isEmpty else { return }
        isSaving = true
        Task {
            let didRename = await sessionStore.renameSession(session, name: normalizedName)
            isSaving = false
            if didRename {
                dismiss()
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func sessionListNativeSearchTopMargin(isEnabled: Bool) -> some View {
        if isEnabled {
            contentMargins(.top, 0, for: .scrollContent)
        } else {
            self
        }
    }

    @ViewBuilder
    func sessionListNativeSearchable(
        isEnabled: Bool,
        text: Binding<String>,
        prompt: Text,
        tintColor: Color,
        toolbarSurface: Color,
        colorScheme: ColorScheme,
        onSubmit: @escaping () -> Void
    ) -> some View {
        if isEnabled {
            searchable(
                text: text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: prompt
            )
            // 紧凑布局保留完整的系统搜索框，不再缩成会触发展开转场的第三个工具按钮。
            .tint(tintColor)
            // 明确给系统搜索栏传递主题的前景/底色，避免快照宿主把浅色模式
            // 的放大镜和 prompt 渲染成白色；深色主题仍由系统自动反转。
            .toolbarBackground(toolbarSurface, for: .navigationBar)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
            .onSubmit(of: .search, onSubmit)
        } else {
            self
        }
    }
}
