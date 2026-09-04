import SwiftUI

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
    /// 底部浮着 Tab 栏时新建留在顶栏，否则改用右下角浮起按钮。
    @Environment(\.workbenchHasBottomTabBar) private var hasBottomTabBar
    @StateObject private var lifecycleCoordinator = SessionListLifecycleCoordinator()
    @State private var selectedWorkspaceID = "all"
    @State private var selectedStatus: SessionLibraryStatusFilter = .all
    @State private var keyboardSelectionID: SessionID?
    /// 列表实际可用宽度。nil 表示还没测到，此时暂用 Shell 注入的页面身份作为种子。
    @State private var measuredContentWidth: CGFloat?
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
        // 与工作区共用同一条宽度判据；量到之后 rowDensity 就不再依赖页面身份。
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { newWidth in
            guard newWidth > 0 else { return }
            measuredContentWidth = newWidth
        }
        .listSectionSpacing(12)
        // 最新设计把日期恢复成轻量粘性标题，正文保持完全扁平；行距与分隔线由行组件统一控制。
        .listRowSpacing(0)
        .scrollContentBackground(.hidden)
        // 与侧栏 gutter、会话画布同底，宽屏下三块相邻面不出现同亮度色差。
        .background(tokens.workbenchCanvasBackground.ignoresSafeArea())
        .workbenchSoftBottomScrollEdge()
        // 只清除原生搜索模式下 List 重复的自动留白；负边距会把首行推进
        // 粘性标题的裁切区域，因此必须让内容继续停留在系统安全边界内。
        .sessionListNativeSearchTopMargin(isEnabled: !showsToolbarSearchField)
        // 只有按钮真的浮在内容之上时才多让一段，最后一条会话才能滚到按钮之上被读到。
        .contentMargins(
            .bottom,
            bottomContentMargin
                + (hasBottomTabBar ? 0 : WorkspaceSessionFabMetrics.contentBottomAllowance),
            for: .scrollContent
        )
        // 与工作区页同一枚按钮。两条边同样只留 20pt——浮动 Tab 栏的避让由容器 safe area 负责，
        // `bottomContentMargin` 是滚动内容的 inset，叠进浮层会重复计算。
        .overlay(alignment: .bottomTrailing) {
            if !hasBottomTabBar {
                newSessionFab(tokens: tokens)
                    .padding(WorkspaceSessionFabMetrics.edgeInset)
            }
        }
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
        .background { SessionSearchPresentationReporter() }
        .sessionListNativeSearchable(
            isEnabled: !showsToolbarSearchField,
            text: $sessionStore.sessionSearchQuery,
            prompt: Text(L10n.text("ui.search_session")),
            tintColor: tokens.primaryText,
            toolbarSurface: tokens.workbenchCanvasBackground,
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
                workbenchChromeToolbarItem(placement: .topBarLeading) {
                    HostSwitcherMenu(
                        presentation: .toolbar,
                        manageConnections: manageConnections
                    )
                    .workbenchToolbarChromeCircle(tokens: tokens)
                    .simultaneousGesture(
                        TapGesture().onEnded { dismissSessionSearchKeyboard() }
                    )
                }
                // 顶栏按钮各自独立，用固定间隔把磨砂圆之间的距离钉死。
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarLeading)
                }
            }
            // 筛选、刷新合入同一个菜单。
            workbenchChromeToolbarItem(placement: .topBarTrailing) {
                filterMenu(tokens: tokens)
                    .simultaneousGesture(
                        TapGesture().onEnded { dismissSessionSearchKeyboard() }
                    )
            }
            // 底部浮着 Tab 栏时新建留在顶栏——那个角上不该叠第二层浮动材质；
            // Tab 栏在顶部（iPadOS 26）时右下角是空的，改用浮起按钮。
            if hasBottomTabBar {
                newSessionToolbarItem(tokens: tokens)
            }
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
            // 按钮自带磨砂圆，系统共享玻璃必须关掉，否则是两层背景。
            .sharedBackgroundVisibility(.hidden)
        } else {
            // iOS 18–25 保留新建入口，但不注册仅新系统支持的 Toolbar zoom 来源。
            workbenchChromeToolbarItem(placement: .topBarTrailing) {
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

    /// Tab 栏在顶部时新建改成右下角浮起按钮，与工作区页同款同尺寸。
    /// zoom 过渡的锚点跟着一起走——`matchedTransitionSource` 本来就作用于普通 View，
    /// 不是 ToolbarContent 专属，返回时会缩回这颗按钮而不是原来的顶栏位置。
    @ViewBuilder
    private func newSessionFab(tokens: ThemeTokens) -> some View {
        if let newSessionPresentationNamespace, #available(iOS 26.0, *) {
            newSessionFabButton(
                tokens: tokens,
                source: .sessionsToolbar(hasNamespace: true)
            )
            .matchedTransitionSource(
                id: NewSessionPresentationSource
                    .sessionsToolbarNewSession
                    .transitionSourceID,
                in: newSessionPresentationNamespace
            )
        } else {
            // iOS 18–25 保留新建入口，但不注册仅新系统支持的 zoom 来源。
            newSessionFabButton(
                tokens: tokens,
                source: .sessionsToolbar(hasNamespace: false)
            )
        }
    }

    private func newSessionFabButton(
        tokens: ThemeTokens,
        source: NewSessionPresentationSource?
    ) -> some View {
        Button {
            dismissSessionSearchKeyboard()
            presentNewSession(source: source)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.primaryActionForeground)
                .frame(
                    width: WorkspaceSessionFabMetrics.diameter,
                    height: WorkspaceSessionFabMetrics.diameter
                )
                .background(tokens.primaryAction, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .shadow(
            color: tokens.primaryAction.opacity(colorScheme == .dark ? 0.34 : 0.28),
            radius: 12,
            y: 5
        )
        .accessibilityLabel(L10n.text("ui.new_session_3da224c4"))
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
            // 磨砂圆只作为背景，不参与布局；外层 ToolbarItem 负责关掉
            // iOS 26 的系统共享玻璃底板。
            WorkbenchChromeIcon(systemName: systemImage)
                .workbenchToolbarChromeCircle(tokens: tokens)
        }
        // 顶部导航保留品牌紫；工具栏仅靠明度区分主次，避免刷新与新建重复着色。
        .foregroundStyle(isPrimary ? tokens.primaryText : tokens.secondaryText)
        .tint(tokens.secondaryText)
        .accessibilityLabel(accessibilityLabel)
    }

    private var visibleSessions: [AgentSession] {
        sessionStore.openedWorkspaceSessionLibrarySessions.filter { session in
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

    /// 密度以实测宽度为准，与工作区使用同一条规则。
    ///
    /// `prefersTableDensity` 由 Shell 按页面身份注入，只作为首帧测量出来之前的种子值：
    /// 两个 tab 各用一套判据时，同一个窗口宽度可能得到两个不同的答案，Split View
    /// 拖动过程中会看到两页的行密度不一致。
    private var rowDensity: SessionIndexRowDensity {
        if let measuredContentWidth {
            return SessionIndexRowDensity.resolved(
                availableWidth: measuredContentWidth,
                dynamicTypeSize: dynamicTypeSize
            )
        }
        return SessionIndexRowDensity.resolved(
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
                // 与工作区同一条规则：小节标题对齐前导列的左缘。
                // 会话 tab 的前导列是项目图标，本来就每行都有，不需要兜底字形。
                .listRowInsets(
                    .init(
                        top: 0,
                        leading: 20 + rowDensity.horizontalPadding,
                        bottom: 0,
                        trailing: 20
                    )
                )
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
            let foregroundActivity = sessionStore.foregroundActivity(for: session.id)
            let isUnread = sessionStore.isHistorySessionUnread(session)
            let showsNeutralHistoryStatus = isActiveSection && !session.isRunning

            Button {
                dismissSessionSearchKeyboard()
                keyboardSelectionID = nil
                select(session)
            } label: {
                SessionIndexRow(
                    session: session,
                    foregroundActivity: foregroundActivity,
                    isSelected: session.id == highlightedSessionID,
                    isPinned: sessionStore.isSessionPinned(session.id),
                    isArchived: sessionStore.isSessionArchived(session.id),
                    reminder: sessionStore.sessionReminder(for: session.id),
                    isObserving: sessionStore.isSessionObserving(session),
                    isUnread: isUnread,
                    density: rowDensity,
                    searchSnippet: sessionStore.sessionSearchSnippet(for: session.id),
                    projectIcon: projectIcon,
                    // 会话 tab 是所有项目的汇集区：前导槽放项目图标，回答"这条属于哪个项目"。
                    leadingSlot: .projectIcon,
                    showsProjectAnchor: startsProjectRun,
                    // 滚动冻结期间已结束的会话仍留在“进行中”原位，必须显式展示最新终态。
                    showsNeutralHistoryStatus: showsNeutralHistoryStatus
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(SessionIndexRowButtonStyle(pressedFill: tokens.selectionFill))
            .hoverEffect(.highlight)
            .accessibilityElement(children: .combine)
            .accessibilityValue(
                SessionIndexRow.accessibilityValue(
                    status: session.displayStatus(foregroundActivity: foregroundActivity),
                    sessionStatus: session.status,
                    isUnread: isUnread,
                    showsNeutralHistoryStatus: showsNeutralHistoryStatus
                )
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
                .workbenchToolbarChromeCircle(tokens: tokens)
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


/// 把系统搜索框的激活态上报给 `SessionStore`，供 Shell 决定是否收起浮层设备入口。
///
/// 只读 `\.isSearching`，**不要**改用 `.searchable(isPresented:)` 的双向绑定：
/// 那样我们会反向驱动系统的搜索状态，反复激活/取消几次后会卡在已激活，
/// 表现为顶部 Tab 栏收起后不再还回来。
private struct SessionSearchPresentationReporter: View {
    @Environment(\.isSearching) private var isSearching
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear { sessionStore.isSessionSearchPresented = isSearching }
            .onDisappear { sessionStore.isSessionSearchPresented = false }
            .onChange(of: isSearching) { _, newValue in
                sessionStore.isSessionSearchPresented = newValue
            }
    }
}
