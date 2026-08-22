import SwiftUI
import QuickLook

struct ProjectSidebarView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isPresentingOpenWorkspace = false
    @State private var isPresentingWorktreeManager = false
    @State private var worktreeManagerRootProjectID = ""
    @State private var worktreeCreateProject: AgentProject?
    var showsSessions = true
    var onProjectSelected: (() -> Void)?
    var onCollapseSidebar: (() -> Void)?
    var onOpenWorkspaceTab: (() -> Void)?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let selectedProjectID = sessionStore.selectedProjectID
        let selectedSessionID = sessionStore.selectedSessionID
        let themeRenderKey = SidebarThemeRenderKey(themeVersion: themeStore.themeVersion, colorScheme: colorScheme)
        let projects = showsSessions ? sessionStore.filteredSessionSidebarProjects : sessionStore.filteredSidebarProjects
        let usesCustomHeader = horizontalSizeClass == .regular || onCollapseSidebar != nil

        Group {
            if usesCustomHeader {
                VStack(spacing: 0) {
                    sidebarHeader(tokens: tokens, projects: projects)
                        .frame(height: regularHeaderHeight)
                    sidebarList(
                        tokens: tokens,
                        selectedProjectID: selectedProjectID,
                        selectedSessionID: selectedSessionID,
                        themeRenderKey: themeRenderKey,
                        projects: projects,
                        showsInlineHeader: false
                    )
                }
            } else {
                sidebarList(
                    tokens: tokens,
                    selectedProjectID: selectedProjectID,
                    selectedSessionID: selectedSessionID,
                    themeRenderKey: themeRenderKey,
                    projects: projects,
                    showsInlineHeader: true
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tokens.sidebarBackground)
        .tint(tokens.accent)
        .overlay(alignment: .trailing) {
            if horizontalSizeClass == .regular {
                Rectangle()
                    .fill(tokens.border.opacity(0.72))
                    .frame(width: 1)
            }
        }
        .sidebarSystemSearchable(
            isEnabled: !usesCustomHeader,
            text: $sessionStore.sessionSearchQuery,
            placement: searchPlacement,
            prompt: Text(showsSessions ? L10n.text("ui.search_session") : L10n.text("ui.search_workspace"))
        )
        .sheet(isPresented: $isPresentingOpenWorkspace) {
            OpenWorkspaceSheet()
        }
        .sheet(isPresented: $isPresentingWorktreeManager) {
            WorktreeManagerSheet(rootProjectID: worktreeManagerRootProjectID)
        }
        .sheet(item: $worktreeCreateProject) { project in
            CreateWorktreeSheet(project: project)
        }
    }

    private func sidebarList(
        tokens: ThemeTokens,
        selectedProjectID: String?,
        selectedSessionID: SessionID?,
        themeRenderKey: SidebarThemeRenderKey,
        projects: [AgentProject],
        showsInlineHeader: Bool
    ) -> some View {
        List {
            Section {
                if shouldShowSidebarEmptyRow(projects: projects) {
                    sidebarEmptyContent()
                        .padding(.top, showsInlineHeader ? 10 : 12)
                        .padding(.bottom, 8)
                        .sidebarListRow()
                }

                ForEach(projects) { project in
                    let snapshot = sessionStore.sessionListSnapshot(forProjectID: project.id)

                    ProjectRow(
                        project: project,
                        isActiveProject: project.id == selectedProjectID,
                        isSelected: project.id == selectedProjectID && (!showsSessions || selectedSessionID == nil),
                        isExpanded: snapshot.isExpanded,
                        isLoading: snapshot.isLoadingMore,
                        isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                        showsDisclosure: showsSessions,
                        showsSessionActions: showsSessions,
                        claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel,
                        themeRenderKey: themeRenderKey,
                        onToggle: {
                            Task {
                                if showsSessions {
                                    await sessionStore.toggleProjectExpansion(project)
                                } else {
                                    await sessionStore.selectProject(project)
                                    onProjectSelected?()
                                }
                            }
                        },
                        onNewSession: {
                            Task { await sessionStore.startNewSession(in: project) }
                        },
                        onNewClaudeSession: {
                            Task { await sessionStore.startNewSession(in: project, runtimeProvider: "claude") }
                        },
                        onCreateWorktree: {
                            worktreeCreateProject = project
                        },
                        onManageWorktrees: {
                            worktreeManagerRootProjectID = sessionStore.rootProjectID(forProjectID: project.id)
                            isPresentingWorktreeManager = true
                        },
                        onRetry: {
                            Task { await sessionStore.retryWorkspace(project) }
                        },
                        onForget: {
                            sessionStore.forgetWorkspace(project)
                        }
                    )
                    .equatable()
                    .sidebarListRow()

                    if showsSessions && snapshot.isExpanded {
                        ProjectSessionRows(
                            snapshot: snapshot,
                            selectedSessionID: selectedSessionID,
                            isLoading: sessionStore.isLoading,
                            themeRenderKey: themeRenderKey
                        )
                    }
                }

                // 远端搜索是跨项目分页，只放一个全局入口；0 项目/0 可见命中时也能继续翻页。
                if showsSessions && sessionStore.isSessionSearchActive && sessionStore.sessionSearchHasMore {
                    sidebarSearchLoadMoreRow(tokens: tokens)
                }
            } header: {
                if showsInlineHeader {
                    sidebarCompactHeaderContent(tokens: tokens, projects: projects)
                }
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, showsInlineHeader ? 6 : 0, for: .scrollContent)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(tokens.sidebarBackground)
    }

    private func sidebarSearchLoadMoreRow(tokens: ThemeTokens) -> some View {
        Button {
            Task { await sessionStore.loadMoreSessionSearchResults() }
        } label: {
            HStack(spacing: 7) {
                if sessionStore.isLoadingMoreSessionSearchResults {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.tertiaryText)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                }
                Text(sessionStore.isLoadingMoreSessionSearchResults ? L10n.text("ui.searching_continues") : L10n.text("ui.continue_searching"))
                    .lineLimit(1)
            }
            .font(themeStore.uiFont(size: 12, weight: .medium))
            .foregroundStyle(tokens.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 30)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sessionStore.isLoadingMoreSessionSearchResults)
        .accessibilityIdentifier("sidebar.sessions.search.loadMore")
        .sidebarListRow()
    }

    private func shouldShowSidebarEmptyRow(projects: [AgentProject]) -> Bool {
        guard projects.isEmpty, !sessionStore.isLoading else {
            return false
        }
        return true
    }

    @ViewBuilder
    private func sidebarEmptyContent() -> some View {
        if showsSessions && sessionStore.isSessionSearchActive && sessionStore.isSearchingRemoteSessionResults {
            SidebarSearchLoadingMessage()
        } else if sessionStore.isSessionSearchActive {
            SidebarEmptyMessage(
                title: showsSessions ? L10n.text("ui.no_matching_session") : L10n.text("ui.no_matching_workspace"),
                detail: L10n.text("ui.try_changing_the_keywords")
            )
        } else if showsSessions {
            SidebarEmptyMessage(
                title: L10n.text("ui.no_session_workspace_yet"),
                detail: L10n.text("ui.the_session_page_only_displays_workspaces_that_have"),
                actionTitle: onOpenWorkspaceTab == nil ? nil : L10n.text("ui.go_to_work_area"),
                actionSystemImage: onOpenWorkspaceTab == nil ? nil : "folder.badge.plus",
                action: onOpenWorkspaceTab
            )
        } else {
            SidebarEmptyMessage(
                title: L10n.text("ui.no_workspace_open"),
                detail: L10n.text("ui.after_selecting_an_authorized_working_directory_the_most"),
                actionTitle: L10n.text("ui.open_path"),
                actionSystemImage: "folder.badge.plus"
            ) {
                isPresentingOpenWorkspace = true
            }
        }
    }

    private var regularHeaderHeight: CGFloat {
        showsSessions ? 112 : 104
    }

    private func sidebarHeader(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        regularSidebarHeaderContent(tokens: tokens, projects: projects)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(tokens.sidebarBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tokens.border.opacity(0.42))
                    .frame(height: 1)
            }
    }

    private func regularSidebarHeaderContent(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(showsSessions ? L10n.text("ui.session") : L10n.text("ui.workspace"))
                        .font(themeStore.uiFont(size: 13, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                    Text(sidebarHeaderSubtitle(projects: projects))
                        .font(themeStore.uiFont(size: 11))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if shouldShowSidebarHeaderActions(projects: projects) {
                    sidebarHeaderActionGroup(tokens: tokens, projects: projects)
                }
            }

            HStack(spacing: 8) {
                sidebarSearchField(tokens: tokens)
                if showsSessions {
                    sidebarNewSessionMenu(tokens: tokens, projects: projects)
                }
            }
        }
    }

    private func sidebarCompactHeaderContent(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        HStack(spacing: 8) {
            Text(showsSessions ? L10n.text("ui.session") : L10n.text("ui.workspace"))
                .font(themeStore.uiFont(size: 12, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
            Spacer()
            if shouldShowSidebarHeaderActions(projects: projects) {
                sidebarHeaderActionGroup(tokens: tokens, projects: projects)
            }
        }
    }

    private func sidebarHeaderActionGroup(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        HStack(spacing: 2) {
            if showsSessions, let onCollapseSidebar {
                sidebarHeaderButton(tokens: tokens, systemImage: "sidebar.left", accessibilityLabel: L10n.text("ui.collapse_conversation_list")) {
                    onCollapseSidebar()
                }
            }
            sidebarHeaderRefresh(tokens: tokens, projects: projects)
            if !showsSessions {
                sidebarHeaderButton(tokens: tokens, systemImage: "folder.badge.plus", accessibilityLabel: L10n.text("ui.open_path")) {
                    isPresentingOpenWorkspace = true
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(tokens.elevatedSurface.opacity(0.58), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tokens.border.opacity(0.5), lineWidth: 1)
        }
    }

    private func sidebarSearchField(tokens: ThemeTokens) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(themeStore.uiFont(size: 12, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
            TextField(showsSessions ? L10n.text("ui.search_session") : L10n.text("ui.search_workspace"), text: $sessionStore.sessionSearchQuery)
                .font(themeStore.uiFont(size: 13))
                .foregroundStyle(tokens.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1)
            if sessionStore.isSessionSearchActive {
                Button {
                    sessionStore.sessionSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.tertiaryText)
                .accessibilityLabel(L10n.text("ui.clear_search"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(tokens.surface.opacity(0.74), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border.opacity(0.52), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func sidebarNewSessionMenu(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        if let project = primarySessionProject(projects: projects) {
            Menu {
                Button {
                    Task { await sessionStore.startNewSession(in: project) }
                } label: {
                    Label(L10n.text("ui.create_a_new_codex_session"), systemImage: "plus.circle")
                }
                if sessionStore.hasClaudeRuntimeChannel {
                    Button {
                        Task { await sessionStore.startNewSession(in: project, runtimeProvider: "claude") }
                    } label: {
                        Label(L10n.text("ui.create_a_new_claude_code_session"), systemImage: "sparkles")
                    }
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label(L10n.text("ui.new_session"), systemImage: "plus")
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                    Image(systemName: "plus")
                        .frame(width: 34, height: 34)
                        .accessibilityLabel(L10n.text("ui.new_session"))
                }
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .background(tokens.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(tokens.accent.opacity(0.26), lineWidth: 1)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("ui.new_session_3da224c4"))
        }
    }

    private func primarySessionProject(projects: [AgentProject]) -> AgentProject? {
        if let selectedProject = sessionStore.selectedProject,
           projects.contains(where: { $0.id == selectedProject.id }) {
            return selectedProject
        }
        return projects.first
    }

    private func sidebarHeaderSubtitle(projects: [AgentProject]) -> String {
        if sessionStore.isSessionSearchActive {
            return projects.isEmpty ? L10n.text("ui.no_matching_results") : L10n.plural("ui.matching_results_count", count: projects.count)
        }
        if showsSessions {
            let configuredCount = sessionStore.sessionWorkspaceSelectionCount
            if projects.count > configuredCount, sessionStore.selectedSessionID != nil {
                return configuredCount == 0 ? L10n.text("ui.the_current_session_is_temporarily_reserved") : L10n.plural("ui.favorites_plus_current_session_count", count: configuredCount)
            }
            return projects.isEmpty ? L10n.text("ui.show_only_workspaces_that_are_part_of_a") : L10n.plural("ui.workspaces_displayed_count", count: projects.count)
        }
        return projects.isEmpty ? L10n.text("ui.directory_not_yet_opened") : L10n.plural("ui.workspaces_count", count: projects.count)
    }

    private func shouldShowSidebarHeaderActions(projects: [AgentProject]) -> Bool {
        if showsSessions, onCollapseSidebar != nil {
            return true
        }
        if sessionStore.isLoading || shouldShowSidebarRefresh(projects: projects) {
            return true
        }
        return !showsSessions
    }

    @ViewBuilder
    private func sidebarHeaderRefresh(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        if sessionStore.isLoading {
            ProgressView()
                .controlSize(.small)
                .tint(tokens.secondaryText)
                .frame(width: 32, height: 32)
                .accessibilityLabel(L10n.text("ui.refreshing_21eaf737"))
        } else if shouldShowSidebarRefresh(projects: projects) {
            sidebarHeaderButton(tokens: tokens, systemImage: "arrow.clockwise", accessibilityLabel: L10n.text("ui.refresh")) {
                Task { await sessionStore.refreshAll(autoAttach: false) }
            }
        }
    }

    private func shouldShowSidebarRefresh(projects: [AgentProject]) -> Bool {
        !projects.isEmpty || sessionStore.isSessionSearchActive || sessionStore.errorMessage != nil
    }

    private func sidebarHeaderButton(
        tokens: ThemeTokens,
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .accessibilityLabel(accessibilityLabel)
    }

    private var searchPlacement: SearchFieldPlacement {
        // iPhone 没有真正的 sidebar 搜索区，放到导航栏抽屉里才是系统原生的窄屏入口。
        horizontalSizeClass == .compact ? .navigationBarDrawer(displayMode: .automatic) : .automatic
    }
}

private extension View {
    @ViewBuilder
    func sidebarSystemSearchable(
        isEnabled: Bool,
        text: Binding<String>,
        placement: SearchFieldPlacement,
        prompt: Text
    ) -> some View {
        if isEnabled {
            searchable(text: text, placement: placement, prompt: prompt)
        } else {
            // 宽屏侧栏已经有可见的内联搜索框；这里不再叠加系统 searchable，
            // 避免出现两个搜索入口或隐藏搜索状态互相抢焦点。
            self
        }
    }
}

private struct SidebarThemeRenderKey: Equatable {
    let themeVersion: Int
    let colorScheme: ColorScheme
}

private struct SidebarSearchLoadingMessage: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(tokens.tertiaryText)
            Text(L10n.text("ui.searching_historical_conversations"))
                .font(themeStore.uiFont(size: 12, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("sidebar.sessions.search.initialLoading")
    }
}

private struct SidebarEmptyMessage: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let detail: String
    var actionTitle: String?
    var actionSystemImage: String?
    var action: (() -> Void)?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(themeStore.uiFont(size: 12))
                .foregroundStyle(tokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) {
                    if let actionSystemImage {
                        Label(actionTitle, systemImage: actionSystemImage)
                    } else {
                        Text(actionTitle)
                    }
                }
                .font(themeStore.uiFont(size: 12, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(tokens.accent.opacity(0.1), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(tokens.accent.opacity(0.24), lineWidth: 1)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.elevatedSurface.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border.opacity(0.48), lineWidth: 1)
        }
    }
}

struct OpenWorkspaceSheet: View {
    private static let compactPresentationDetent: PresentationDetent = .fraction(0.82)
    /// 图标底板宽 + 与名称的间距。分隔线按同一常量内缩，让线头正好落在名称基线上。
    private static let rowTextInset: CGFloat = 42

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @FocusState private var isManualPathFocused: Bool
    @State private var path = ""
    @State private var isOpening = false
    @State private var localError: String?
    @State private var presentationDetent = OpenWorkspaceSheet.compactPresentationDetent
    /// 手动输入是备用通道，默认折叠成一行，首屏完整留给目录列表。
    @State private var isManualPathExpanded = false

    @State private var browsePath: String?
    /// 首次不带 path 的浏览落在服务端默认浏览根上，正好是授权边界的下沿。
    /// 记住它，路径条才能只把边界内的层级画成可点。
    @State private var browseRootPath: String?
    @State private var browseParentPath: String?
    @State private var browseEntries: [DirectoryEntry] = []
    @State private var browseTruncated = false
    @State private var isBrowsing = false
    @State private var browseError: String?
    @State private var previewURL: URL?
    @State private var previewError: String?
    @State private var previewingPath: String?
    // 快速连点目录时让最后一次请求胜出，避免慢响应把列表回写成旧目录。
    @State private var browseRequestID = 0
    var onOpened: (String) -> Void = { _ in }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            directoryBrowser
                .navigationTitle(L10n.text("ui.open_workspace"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .cancellationAction) {
                            cancelButton(tokens: tokens)
                        }
                        // 取消是安静文本，不该再套一层系统共享玻璃底板：
                        // 一屏只留「打开」一处实心控件，主次才立得住。
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .cancellationAction) {
                            cancelButton(tokens: tokens)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        WorkspaceOpenCurrentDirectoryToolbarButton(
                            isOpening: isOpening,
                            isDisabled: browsePath == nil || isOpening || isBrowsing,
                            action: openCurrentBrowsePath
                        )
                    }
                }
                .task {
                    // 默认进入服务端浏览根（第一个 scan root），失败时仍可手动输入路径。
                    await browse(to: "")
                }
                .onChange(of: path) { _, _ in
                    localError = nil
                }
                .onChange(of: isManualPathFocused) { _, isFocused in
                    // 键盘会显著压缩目录与说明区；用系统 large detent 给输入留出空间，
                    // 关闭键盘后不强制回落，保留用户对 Sheet 高度的控制。
                    if isFocused {
                        presentationDetent = .large
                    }
                }
                .quickLookPreview($previewURL)
        }
        .tint(tokens.primaryAction)
        // 目录浏览、路径条与说明文字共用一张画布，行本身不再另铺白底：
        // 一屏只有一层底色时，20 多行的节奏才由行距和分隔线决定，而不是由色块堆叠决定。
        .presentationBackground(tokens.sidebarBackground)
        // 默认只占可用高度的约八成，保留背景上下文；仍允许按系统手势上拉到全屏。
        .presentationDetents(
            [OpenWorkspaceSheet.compactPresentationDetent, .large],
            selection: $presentationDetent
        )
        .presentationDragIndicator(.visible)
    }

    private func cancelButton(tokens: ThemeTokens) -> some View {
        Button(L10n.text("ui.cancel"), role: .cancel) {
            dismiss()
        }
        .buttonStyle(.plain)
        .font(themeStore.uiFont(size: 15))
        .foregroundStyle(tokens.secondaryText)
        .frame(minWidth: 44, minHeight: 44)
        // 打开请求完成前禁止关闭弹窗，避免后台任务在取消后仍切换当前工作区。
        .disabled(isOpening)
        .accessibilityIdentifier("workspace.open.cancel")
    }

    @ViewBuilder
    private var directoryBrowser: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        let list = List {
            if let localError {
                browseNotice(localError, title: L10n.text("ui.open_failed"))
            }

            childDirectoriesSection
            manualPathSection
        }
        // 目录浏览是首要任务。平铺列表去掉 Form 的大面积分组卡片，
        // 只用原生行距和分隔线表达层级，同时保留系统滚动与键盘行为。
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        // 静止时首行与路径条留一道窄缝；滚动后内容仍从路径条底下穿过。
        .contentMargins(.top, 6, for: .scrollContent)
        .background(tokens.sidebarBackground)
        // 路径条属于浮在内容之上的控制层，不随目录列表滚走：深目录里「我在哪」
        // 必须始终可读，同时列表从它底下穿过，边界交给 scroll edge 表达而不是分割线。
        .safeAreaInset(edge: .top, spacing: 0) {
            pathBar
        }

        if #available(iOS 26.0, *) {
            // 行接近路径条时先被系统渐进虚化，再进入材质后方；两段虚化连起来，
            // 才不会出现「清晰的行忽然贴到层级文字背后」。
            list.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            list
        }
    }

    @ViewBuilder
    private var pathBar: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        WorkspaceCurrentDirectoryCard(
            path: browsePath ?? "",
            rootPath: browseRootPath,
            parentPath: browseParentPath,
            isBrowsing: isBrowsing,
            isOpening: isOpening,
            onNavigate: { target in
                Task { await browse(to: target) }
            }
        )
        .background {
            WorkspaceBrowsePathBarSurface(tokens: tokens)
                .ignoresSafeArea(edges: .horizontal)
        }
    }

    private func openCurrentBrowsePath() {
        guard let browsePath else { return }
        Task { await open(path: browsePath) }
    }

    @ViewBuilder
    private var childDirectoriesSection: some View {
        Section {
            if isBrowsing && browseEntries.isEmpty {
                // 只有首次进入才让位给加载态；目录之间切换时保留上一屏内容，
                // 避免每点一层就闪一次空列表。
                browseStatusBlock {
                    ProgressView()
                        .controlSize(.regular)
                    statusCaption(L10n.text("ui.loading_catalog"))
                }
            } else if let browseError {
                browseNotice(browseError) {
                    Task { await browse(to: browsePath ?? "") }
                }
            } else if browseEntries.isEmpty {
                browseStatusBlock {
                    statusGlyph("folder")
                    statusCaption(L10n.text("ui.no_subdirectories_to_enter_or_files_to_preview"))
                }
            } else {
                entryRows
            }
        } footer: {
            // 原来这里有一个「内容」标题。路径条已经说明当前层级，标题不携带新信息，
            // 只是在首屏再占一行；边界改由路径条的磨砂层表达。
            browseFooter
        }
        // 路径条已经用磨砂层划分控制区，第一项上方再画线只会形成重复边界；
        // 尾部说明与手动输入之间同理，靠留白分区就够。
        .listSectionSeparator(.hidden)
    }

    @ViewBuilder
    private var entryRows: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ForEach(browseEntries) { entry in
            let isReachable = entry.canBrowse || entry.isPreviewable

            Button {
                if entry.isDir {
                    Task { await browse(to: entry.path) }
                } else {
                    Task { await preview(entry) }
                }
            } label: {
                WorkspaceBrowseEntryRow(
                    entry: entry,
                    isPreviewing: previewingPath == entry.path,
                    isReachable: isReachable
                )
            }
            .buttonStyle(WorkspaceBrowseRowButtonStyle(tokens: tokens, reduceMotion: reduceMotion))
            .disabled(isOpening || isBrowsing || previewingPath != nil || !isReachable)
            // 切目录时旧内容整体退到背景，等新一屏落位再回到前台；
            // 位置不跳，只有明暗变化，读者的视线不会被重排打断。
            .opacity(isBrowsing ? 0.35 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isBrowsing)
            .listRowBackground(Color.clear)
            // List 默认还会在内容外增加上下 inset；归零后行高完全由行内容决定。
            // 横向沿用原生 16pt 边距。
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparatorTint(tokens.border.opacity(0.55))
            // 分隔线从名称起笔，图标列留空：一列图标底板因此连成视觉上的一条竖轴。
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading] + OpenWorkspaceSheet.rowTextInset
            }
        }

        if let previewError {
            browseNotice(previewError)
        }
    }

    @ViewBuilder
    private var browseFooter: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Text(
            browseTruncated
                ? L10n.text("ui.the_directory_is_too_large_only_the_front")
                : L10n.text("ui.hidden_directories_library_and_common_cache_directories_will")
        )
        .font(themeStore.uiFont(size: 12))
        .foregroundStyle(tokens.tertiaryText)
        .padding(.top, 14)
        .padding(.bottom, 4)
        // 说明文字属于同一张画布；不铺自己的白底，否则列表尾部会多出一条色带。
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var manualPathSection: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Section {
            DisclosureGroup(isExpanded: $isManualPathExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("/Users/me/finance", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isManualPathFocused)
                        .submitLabel(.go)
                        .onSubmit {
                            guard canOpenTypedPath else { return }
                            Task { await open(path: path) }
                        }
                        // 路径是等宽内容：斜杠与层级在等宽字下才对得齐，也更容易核对粘贴结果。
                        .font(themeStore.codeFont(size: 13))
                        .foregroundStyle(tokens.primaryText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 42)
                        .background(
                            tokens.inputBackground,
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(tokens.border.opacity(0.6), lineWidth: 1)
                        }

                    Button {
                        Task { await open(path: path) }
                    } label: {
                        Text(isOpening ? L10n.text("ui.opening") : L10n.text("ui.open_the_input_path"))
                            .font(themeStore.uiFont(size: 14, weight: .semibold))
                            .foregroundStyle(canOpenTypedPath ? tokens.primaryAction : tokens.tertiaryText)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(
                                canOpenTypedPath ? tokens.accentSoft : tokens.accentSoft.opacity(0.5),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().strokeBorder(tokens.border.opacity(0.55), lineWidth: 1)
                            }
                            .contentShape(Capsule())
                    }
                    // 备用通道用淡底按钮：与工具栏那颗实心「打开」区分主次，
                    // 也不会在没输入时把系统灰底板压在这张暖色画布上。
                    .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                    .disabled(!canOpenTypedPath)

                    Text(L10n.text("ui.you_can_directly_paste_the_absolute_path_in"))
                        .font(themeStore.uiFont(size: 12))
                        .foregroundStyle(tokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
                .padding(.bottom, 6)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "keyboard")
                        .font(themeStore.uiFont(size: 13, weight: .medium))
                        .foregroundStyle(tokens.tertiaryText)
                        .frame(width: 20)
                    Text(L10n.text("ui.enter_path_manually"))
                        .font(themeStore.uiFont(size: 14, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                }
                .frame(minHeight: 44)
            }
            .tint(tokens.secondaryText)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)
        }
        .listSectionSeparator(.hidden)
    }

    /// 错误不再另起一节标题，而是收成一张与行同宽的提示卡：
    /// 出错时视线仍留在列表位置上，恢复后卡片消失，不会留下一个空标题。
    @ViewBuilder
    private func browseNotice(
        _ message: String,
        title: String? = nil,
        retry: (() -> Void)? = nil
    ) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(tokens.warning)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title)
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.warning)
                }
                Text(message)
                    .font(themeStore.uiFont(size: 13))
                    .foregroundStyle(tokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button(action: retry) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(themeStore.uiFont(size: 12, weight: .semibold))
                            Text(L10n.text("ui.try_again"))
                                .font(themeStore.uiFont(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(tokens.accent)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tokens.warning.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func browseStatusBlock(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func statusGlyph(_ systemImage: String) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Image(systemName: systemImage)
            .font(themeStore.uiFont(size: 26, weight: .light))
            .foregroundStyle(tokens.tertiaryText.opacity(0.7))
    }

    private func statusCaption(_ text: String) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Text(text)
            .font(themeStore.uiFont(size: 13))
            .foregroundStyle(tokens.tertiaryText)
            .multilineTextAlignment(.center)
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canOpenTypedPath: Bool {
        !isOpening && !trimmedPath.isEmpty
    }

    private func browse(to target: String) async {
        browseRequestID += 1
        let requestID = browseRequestID
        isBrowsing = true
        browseError = nil
        do {
            let response = try await sessionStore.listDirectories(path: target)
            guard requestID == browseRequestID else {
                return
            }
            guard !Task.isCancelled else {
                isBrowsing = false
                return
            }
            browsePath = response.path
            if target.isEmpty, browseRootPath == nil {
                browseRootPath = response.path
            }
            browseParentPath = response.parentPath
            browseEntries = response.entries
            browseTruncated = response.truncated ?? false
            previewError = nil
            isBrowsing = false
        } catch {
            guard requestID == browseRequestID else {
                return
            }
            isBrowsing = false
            guard !isCancellationError(error) else {
                return
            }
            browseError = userFacingBrowseError(error)
        }
    }

    private func userFacingBrowseError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return L10n.text("ui.the_current_agentd_version_does_not_support_directory")
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return L10n.text("ui.the_directory_is_not_within_authorization_scope_or")
        }
        return error.localizedDescription
    }

    private func preview(_ entry: DirectoryEntry) async {
        guard entry.isPreviewable else {
            return
        }
        let targetPath = entry.path
        previewingPath = targetPath
        previewError = nil
        defer {
            if previewingPath == targetPath {
                previewingPath = nil
            }
        }
        do {
            previewURL = try await sessionStore.previewFile(path: targetPath)
        } catch {
            guard !isCancellationError(error) else {
                return
            }
            previewError = userFacingPreviewError(error)
        }
    }

    private func userFacingPreviewError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return L10n.text("ui.the_current_agentd_version_does_not_support_file")
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return L10n.text("ui.the_file_is_not_within_authorization_or_is")
        }
        if case AgentAPIError.server(let status, _) = error, status == 413 {
            return L10n.text("ui.the_file_is_too_large_and_preview_is")
        }
        return error.localizedDescription
    }

    private func open(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            localError = L10n.text("ui.please_enter_the_directory_path_in_the_development")
            return
        }
        isOpening = true
        localError = nil
        defer { isOpening = false }
        switch await sessionStore.openWorkspaceOutcome(path: targetPath) {
        case .opened(let workspaceID):
            onOpened(workspaceID)
            dismiss()
        case .cancelled:
            // 关闭 Sheet、切主机或后台凭据挂起都属于生命周期取消；保留输入供用户恢复后重试。
            return
        case .failed(let message):
            localError = userFacingOpenWorkspaceError(message, path: targetPath)
        }
    }

    private func userFacingOpenWorkspaceError(_ message: String?, path: String) -> String {
        let fallback = L10n.format("ui.unable_to_open_value", path)
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        let lowercased = message.lowercased()
        if lowercased.contains("allowlist") ||
            message.contains("允许范围") ||
            message.contains("HTTP 403") {
            return L10n.format("ui.value_is_not_yet_within_the_authorized_scope", path)
        }
        return message
    }
}

/// 路径条的材质层。
///
/// 路径条上是一行密排的小字，正下方又是不停滚动的目录名，材质透出来的残影会直接落在
/// 层级文字后面。这里**不再靠换一档更厚的材质**去压（那会让路径条成为一屏里唯一一块
/// 更浓的玻璃），改为在同一档磨砂上加厚画布色 tint：滚动时仍看得见内容在后面移动，
/// 但只剩一层化开的色块。Reduce Transparency 下退成等价实色。
private struct WorkspaceBrowsePathBarSurface: View {
    let tokens: ThemeTokens

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Rectangle().fill(tokens.sidebarBackground)
            } else {
                Rectangle().fill(WorkbenchMaterial.surface)
                Rectangle().fill(tokens.sidebarBackground.opacity(0.62))
            }
        }
    }
}

/// 行按下的那一刻整行浮起一层浅底，抬指即落回：反馈跟着手指走，
/// 而不是等请求回来才有变化。
private struct WorkspaceBrowseRowButtonStyle: ButtonStyle {
    let tokens: ThemeTokens
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tokens.sidebarHoverFill)
                    .opacity(configuration.isPressed ? 1 : 0)
                    // 高亮比文字块略宽一点，读起来才是「整行被按下」而不是「文字被选中」。
                    .padding(.horizontal, -8)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 目录行：图标底板、名称、动作提示三段固定节奏。
///
/// 图标保持次级色重（accent 只属于工具栏那颗「打开」），但用一层中性底板托住，
/// 让长列表在快速滚动时有一条稳定的竖轴，而不是一列孤零零的灰线条。
private struct WorkspaceBrowseEntryRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let entry: DirectoryEntry
    let isPreviewing: Bool
    /// 服务端已经说明这一项不能进入也不能预览时，整行降成静态信息，不再暗示可点。
    let isReachable: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 12) {
            icon(tokens: tokens)
            Text(entry.name)
                .font(themeStore.uiFont(size: 15, weight: .medium))
                .foregroundStyle(isReachable ? tokens.primaryText : tokens.tertiaryText)
                // 目录名是唯一的辨识依据，长名折行而不是从中间截断。
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            accessory(tokens: tokens)
        }
        .padding(.vertical, 9)
        // 视觉收紧，命中区仍保持系统最小尺寸。
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private func icon(tokens: ThemeTokens) -> some View {
        Image(systemName: entry.isDir ? "folder.fill" : "doc.text.fill")
            .font(themeStore.uiFont(size: 13, weight: .medium))
            .foregroundStyle(entry.isDir ? tokens.secondaryText : tokens.tertiaryText)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tokens.accentSoft)
            )
            .opacity(isReachable ? 1 : 0.5)
    }

    @ViewBuilder
    private func accessory(tokens: ThemeTokens) -> some View {
        if isPreviewing {
            ProgressView()
                .controlSize(.small)
        } else if !isReachable {
            EmptyView()
        } else {
            Image(systemName: entry.isDir ? "chevron.right" : "eye")
                .font(themeStore.uiFont(size: 12, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText.opacity(0.6))
        }
    }
}

/// 目录选择器的位置指示改用面包屑路径条，而不是「上一级按钮 + 目录名 + 全路径」三段卡片。
///
/// 层级本身就是位置信息：轨迹可读出「我在哪」，省掉目录名与全路径的重复表达，
/// 也把只能单步回退的「上一级」升级为可直接跳到授权范围内的任意祖先层级。
/// 压缩后的首屏归还给真正的主任务——挑选目录。
struct WorkspaceCurrentDirectoryCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var themeStore: ThemeStore

    let path: String
    /// 服务端默认浏览根。它之上的层级会被 allowlist 直接拒绝，
    /// 所以那些段不能画成可点的面包屑，否则每次点击都换来一条 403。
    let rootPath: String?
    let parentPath: String?
    let isBrowsing: Bool
    let isOpening: Bool
    let onNavigate: (String) -> Void

    /// 每段的 id 用累积路径而非下标：路径前缀天然唯一，
    /// 目录切换时 SwiftUI 能按层级而不是位置对齐 diff。
    private struct PathCrumb: Identifiable {
        let name: String
        let path: String

        var id: String { path }
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let crumbs = visibleCrumbs

        let prefix = crumbs.first.flatMap(elidedPrefix(before:))

        return HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if crumbs.isEmpty {
                        placeholderCrumb
                    } else {
                        if let prefix {
                            // 授权边界之上的层级不可进入，但绝对路径仍是确认位置的依据，
                            // 所以按原文保留成不可点的前缀，而不是压成一个省略号。
                            // 分隔符照常延续：这仍是一条连续路径，可点与否交给字色区分。
                            // 文件系统根只是首段的那一道斜杠，紧贴下一段，不单独占一格。
                            elidedPrefixLabel(prefix)
                            if prefix != "/" {
                                separator
                            }
                        }
                        ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                            if index > 0 {
                                separator
                            }
                            crumbButton(
                                crumb,
                                isCurrent: index == crumbs.count - 1,
                                isLeading: index == 0 && (prefix == nil || prefix == "/")
                            )
                        }
                    }
                }
                .frame(minHeight: 44)
            }
            // 短路径贴左展示，深路径也从绝对路径起点开始；后半段留给用户向右滑动查看。
            .defaultScrollAnchor(.leading, for: .alignment)
            .defaultScrollAnchor(.leading, for: .initialOffset)

            if isBrowsing {
                // 进度留在路径条上，列表因此不必清空重画：位置指示本来就是这次跳转的主语。
                ProgressView()
                    .controlSize(.small)
                    .tint(tokens.tertiaryText)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isBrowsing)
    }

    @ViewBuilder
    private func crumbButton(_ crumb: PathCrumb, isCurrent: Bool, isLeading: Bool) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if isCurrent {
            // 当前层级不是可点目标，用唯一一处 accent 承担「你在这里」，
            // 让列表行把 accent 让给真正的主动作（打开）。
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(themeStore.uiFont(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(crumb.name)
                    .font(themeStore.uiFont(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tokens.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tokens.accentSoft, in: Capsule())
            .overlay {
                Capsule().strokeBorder(tokens.accent.opacity(0.16), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(crumb.name)
            .accessibilityValue(L10n.text("ui.current_location"))
        } else {
            // 能画成按钮的层级都已被 visibleCrumbs 过滤为服务端确实允许进入的，
            // 所以这里不存在“点了才发现不能点”的控件。
            let isParent = crumb.path == parentPath

            Button {
                onNavigate(crumb.path)
            } label: {
                Text(crumb.name)
                    .font(themeStore.uiFont(size: 14, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    // 首段与列表的 16pt 内容边距对齐，之后各段留出 6pt 呼吸。
                    .padding(.leading, isLeading ? 0 : 6)
                    .padding(.trailing, 6)
                    // 视觉保持紧凑，命中区仍撑满路径条高度。
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .disabled(isBrowsing || isOpening)
            .accessibilityLabel(crumb.name)
            // 只有直接父级适用「返回上一级」；更高层级不给出会误导的提示。
            .accessibilityHint(isParent ? L10n.text("ui.return_to_previous_level") : "")
            // 直接父级沿用既有标识，其余层级按累积路径区分，避免同一轨迹里出现重复标识。
            .accessibilityIdentifier(
                isParent ? "workspace.open.parent" : "workspace.open.crumb.\(crumb.path)"
            )
        }
    }

    private var separator: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Image(systemName: "chevron.compact.right")
            .font(themeStore.uiFont(size: 12, weight: .semibold))
            .foregroundStyle(tokens.tertiaryText.opacity(0.6))
            .accessibilityHidden(true)
    }

    private var placeholderCrumb: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Text(L10n.text("ui.locating_be47409b"))
            .font(themeStore.uiFont(size: 14))
            .foregroundStyle(tokens.tertiaryText)
            .frame(minHeight: 44)
    }

    private func elidedPrefixLabel(_ prefix: String) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Text(prefix)
            .font(themeStore.uiFont(size: 14))
            .foregroundStyle(tokens.tertiaryText)
            .lineLimit(1)
            .padding(.trailing, prefix == "/" ? 0 : 6)
            // 不可点，但作为静态文本保留给 VoiceOver，补充授权边界以上的路径信息。
    }

    /// 首个可见层级之上被裁掉的那段绝对路径，没有则返回 nil。
    /// 文件系统根返回 "/"：路径条要始终读得出这是一条绝对路径。
    private func elidedPrefix(before crumb: PathCrumb) -> String? {
        guard crumb.path != "/" else { return nil }
        let prefix = (crumb.path as NSString).deletingLastPathComponent
        return prefix.isEmpty ? nil : prefix
    }

    /// 只保留授权边界之内的层级。
    ///
    /// 边界下沿取「默认浏览根」与服务端明确给出的 `parentPath` 中较浅的一个：
    /// 前者由首次浏览学到，后者已由服务端确认可进入（可能略高于浏览根）。
    /// 两者都不在轨迹里时说明已到边界顶，只显示当前层级。
    private var visibleCrumbs: [PathCrumb] {
        let crumbs = pathCrumbs
        guard !crumbs.isEmpty else { return [] }

        let boundaries = Set([rootPath, parentPath].compactMap { $0 })
        guard let floor = crumbs.first(where: { boundaries.contains($0.path) }) else {
            return [crumbs[crumbs.count - 1]]
        }
        return Array(crumbs.drop(while: { $0.path != floor.path }))
    }

    private var pathCrumbs: [PathCrumb] {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty || path == "/" else { return [] }

        // 先构造完整轨迹（含文件系统根），再由 visibleCrumbs 按授权边界裁掉上层。
        var crumbs: [PathCrumb] = path.hasPrefix("/") ? [PathCrumb(name: "/", path: "/")] : []
        var accumulated = ""
        for component in components {
            accumulated += "/" + component
            crumbs.append(PathCrumb(name: component, path: accumulated))
        }
        return crumbs
    }
}

struct WorkspaceOpenCurrentDirectoryToolbarButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let isOpening: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Button(action: action) {
            if isOpening {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.primaryActionForeground)
                    Text(L10n.text("ui.opening"))
                }
            } else {
                Text(L10n.text("ui.open"))
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(tokens.primaryAction)
        .foregroundStyle(tokens.primaryActionForeground)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(isDisabled)
        .accessibilityLabel(isOpening ? L10n.text("ui.opening_workspace") : L10n.text("ui.open"))
        .accessibilityIdentifier("workspace.open.current")
    }
}

private struct ProjectSessionRows: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: ProjectSessionListSnapshot
    let selectedSessionID: SessionID?
    let isLoading: Bool
    let themeRenderKey: SidebarThemeRenderKey

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if snapshot.isEmpty && !isLoading {
            Text(L10n.text("ui.no_historical_conversations_yet"))
                .font(themeStore.uiFont(size: 12))
                .foregroundStyle(tokens.tertiaryText)
                .padding(.leading, 30)
                .padding(.vertical, 4)
                .sidebarListRow()
        }

        ForEach(snapshot.visibleSessions) { session in
            let isPinned = sessionStore.isSessionPinned(session.id)
            let isArchived = sessionStore.isSessionArchived(session.id)
            let reminder = sessionStore.sessionReminder(for: session.id)
            let foregroundActivity = sessionStore.foregroundActivity(for: session.id)
            SessionRow(
                session: session,
                foregroundActivity: foregroundActivity,
                isSelected: session.id == selectedSessionID,
                isPinned: isPinned,
                isArchived: isArchived,
                reminder: reminder,
                isObserving: sessionStore.isSessionObserving(session),
                isUnread: sessionStore.isHistorySessionUnread(session),
                searchSnippet: sessionStore.sessionSearchSnippet(for: session.id),
                themeRenderKey: themeRenderKey
            )
                .equatable()
                // List 行内的 Button 会被 UICollectionView 的 delaysContentTouches 拖慢高亮，
                // 改用 contentShape + onTapGesture，让点击在抬手时立即响应。
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await sessionStore.selectSession(session) }
                }
                .sessionRowActions(session)
                .padding(.leading, 30)
                .sidebarListRow()
        }

    }
}

private struct ProjectRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    let project: AgentProject
    let isActiveProject: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let isUnavailable: Bool
    let showsDisclosure: Bool
    let showsSessionActions: Bool
    let claudeChannelAvailable: Bool
    let themeRenderKey: SidebarThemeRenderKey
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onNewClaudeSession: () -> Void
    let onCreateWorktree: () -> Void
    let onManageWorktrees: () -> Void
    let onRetry: () -> Void
    let onForget: () -> Void

    static func == (lhs: ProjectRow, rhs: ProjectRow) -> Bool {
        lhs.project == rhs.project
            && lhs.isActiveProject == rhs.isActiveProject
            && lhs.isSelected == rhs.isSelected
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isLoading == rhs.isLoading
            && lhs.isUnavailable == rhs.isUnavailable
            && lhs.showsDisclosure == rhs.showsDisclosure
            && lhs.showsSessionActions == rhs.showsSessionActions
            && lhs.claudeChannelAvailable == rhs.claudeChannelAvailable
            // 主题切换只通过轻量 key 打破行缓存，避免移除 .equatable() 导致长列表回退。
            && lhs.themeRenderKey == rhs.themeRenderKey
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 6) {
            // 整块左侧区域作为展开/收起的点击目标。用 onTapGesture 绕开 List 行内 Button
            // 在 UICollectionView 下的 delaysContentTouches 高亮延迟。
            HStack(spacing: 8) {
                Image(systemName: isUnavailable ? "exclamationmark.triangle.fill" : (isActiveProject || isExpanded ? "folder.fill" : "folder"))
                    .font(themeStore.uiFont(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 20)
                    .foregroundStyle(isUnavailable ? tokens.warning : (isActiveProject ? tokens.accent : tokens.tertiaryText))
                Text(project.name)
                    .font(themeStore.uiFont(size: 15, weight: isActiveProject ? .semibold : .medium))
                    .foregroundStyle(isUnavailable ? tokens.tertiaryText : (isActiveProject ? tokens.primaryText : tokens.secondaryText))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if isUnavailable {
                    Text(L10n.text("ui.not_available"))
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.warning)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.tertiaryText)
                } else if showsDisclosure {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.tertiaryText)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(themeStore.uiFont(size: 13, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            Menu {
                if showsSessionActions {
                    // 会话在创建瞬间就绑定 runtime，事后无法切换通道；菜单里保留显式通道选择。
                    Button(action: onNewSession) {
                        Label(L10n.text("ui.create_a_new_codex_session"), systemImage: "plus.circle")
                    }
                    .disabled(isUnavailable)
                    if claudeChannelAvailable {
                        Button(action: onNewClaudeSession) {
                            Label(L10n.text("ui.create_a_new_claude_code_session"), systemImage: "sparkles")
                        }
                        .disabled(isUnavailable)
                    }
                    Divider()
                }
                if isUnavailable {
                    Button(action: onRetry) {
                        Label(L10n.text("ui.try_again"), systemImage: "arrow.clockwise")
                    }
                }
                Button(action: onCreateWorktree) {
                    Label(L10n.text("ui.create_a_new_git_worktree"), systemImage: "square.stack.3d.up")
                }
                .disabled(isUnavailable)
                Button(action: onManageWorktrees) {
                    Label(L10n.text("ui.manage_git_worktree"), systemImage: "wrench.and.screwdriver")
                }
                Button(role: .destructive, action: onForget) {
                    Label(L10n.text("ui.remove_from_current_device"), systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(themeStore.uiFont(size: 14, weight: .semibold))
                    .foregroundStyle(tokens.tertiaryText.opacity(0.72))
                    .frame(width: 22, height: 26)
                    // 菜单点击区随行高扩展，不用负 padding，保证 hit-test 在布局边界内稳定生效。
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .accessibilityLabel(L10n.text("ui.project_operations"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background {
            SidebarSelectionBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                selectedTint: tokens.selectionFill,
                hoverTint: tokens.sidebarHoverFill,
                selectedAccent: tokens.accent
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? tokens.accent.opacity(0.34) : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
    }

}

private struct SessionRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    let session: AgentSession
    let foregroundActivity: SessionForegroundActivity?
    let isSelected: Bool
    let isPinned: Bool
    let isArchived: Bool
    let reminder: SessionReminder?
    let isObserving: Bool
    let isUnread: Bool
    let searchSnippet: String?
    let themeRenderKey: SidebarThemeRenderKey

    static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.session == rhs.session
            && lhs.foregroundActivity == rhs.foregroundActivity
            && lhs.isSelected == rhs.isSelected
            && lhs.isPinned == rhs.isPinned
            && lhs.isArchived == rhs.isArchived
            && lhs.reminder == rhs.reminder
            && lhs.isObserving == rhs.isObserving
            && lhs.isUnread == rhs.isUnread
            && lhs.searchSnippet == rhs.searchSnippet
            // 主题 key 让色彩/字体 token 变化能刷新，但仍避免流式状态更新重绘所有侧栏行。
            && lhs.themeRenderKey == rhs.themeRenderKey
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6, height: 6)
                if isPinned {
                    SessionPinnedBadge(compact: true)
                }
                if isArchived {
                    Image(systemName: "archivebox.fill")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.tertiaryText)
                        .accessibilityLabel(L10n.text("ui.archived"))
                }
                if reminder != nil {
                    Image(systemName: "bell.fill")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.warning.opacity(0.86))
                        .accessibilityLabel(L10n.text("ui.reminder_set"))
                }
                Text(session.title)
                    .font(themeStore.uiFont(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? tokens.primaryText : tokens.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                if isUnread {
                    SessionUnreadIndicator()
                }
                Spacer(minLength: 8)
                trailingMetadata
            }

            // 运行时是稳定的会话身份，始终显示；动态状态只在需要关注时追加。
            HStack(spacing: 5) {
                SessionRuntimeBadge(session: session, compact: true)
                if shouldShowStatusLine {
                    statusCapsule(statusSummary)
                }
                if isObserving {
                    observationCapsule
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)

            if let searchSnippet, !searchSnippet.isEmpty {
                Text(searchSnippet)
                    .font(themeStore.uiFont(size: 11, weight: .regular))
                    .foregroundStyle(tokens.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // 内容密度不变，命中区域单独扩到 44pt，避免侧栏紧凑模式牺牲触控可用性。
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background {
            SidebarSelectionBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                selectedTint: tokens.selectionFill,
                hoverTint: tokens.sidebarHoverFill,
                selectedAccent: tokens.accent
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? tokens.accent.opacity(0.32) : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isUnread ? L10n.text("ui.unread_result") : "")
    }

    @ViewBuilder
    private var trailingMetadata: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if !shouldShowStatusLine && shouldShowTrailingActivityIcon {
            if statusSummary.showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(tint(for: statusSummary.tone))
                    .frame(width: 16, height: 16, alignment: .center)
                    .accessibilityLabel(statusSummary.title)
            } else {
                Image(systemName: statusSummary.systemImage)
                    .font(themeStore.uiFont(size: 13, weight: .semibold))
                    .foregroundStyle(tint(for: statusSummary.tone))
                    .frame(width: 16, height: 16, alignment: .center)
                    .accessibilityLabel(statusSummary.title)
            }
        } else if let updatedAt = session.updatedAt {
            Text(Self.minuteTimeFormatter.string(from: updatedAt))
                .font(themeStore.uiFont(size: 12, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var statusSummary: AgentSessionDisplayStatus {
        return session.displayStatus(foregroundActivity: foregroundActivity)
    }

    private var statusDotColor: Color {
        tint(for: statusSummary.tone)
    }

    private var shouldShowStatusLine: Bool {
        session.isRunning
            || session.pendingApproval != nil
            || session.status == SessionStatus.waitingForInput.rawValue
            || session.status == SessionStatus.waitingForApproval.rawValue
            || session.status == SessionStatus.failed.rawValue
    }

    private var shouldShowTrailingActivityIcon: Bool {
        session.isRunning || foregroundActivity != nil || session.activeTurnID != nil
    }

    private func statusCapsule(_ status: AgentSessionDisplayStatus) -> some View {
        HStack(spacing: 3) {
            if status.showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(tint(for: status.tone))
            } else {
                Image(systemName: status.systemImage)
                    .font(themeStore.uiFont(size: 9, weight: .semibold))
            }
            Text(status.title)
                .lineLimit(1)
        }
        .font(themeStore.uiFont(size: 10, weight: .medium))
        .foregroundStyle(tint(for: status.tone))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusCapsuleBackground(for: status.tone), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.title)
    }

    private var observationCapsule: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Label(L10n.text("ui.just_observe"), systemImage: "eye")
            .labelStyle(.titleAndIcon)
            .font(themeStore.uiFont(size: 10, weight: .medium))
            .foregroundStyle(tokens.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tokens.elevatedSurface.opacity(0.72), in: Capsule())
    }

    private func tint(for tone: AgentSessionStatusTone) -> Color {
        let tokens = themeStore.tokens(for: colorScheme)
        // 侧栏只让运行、等待、失败等需要处理的状态使用强色；完成/历史态退到中性色。
        switch tone {
        case .active:
            return tokens.primaryAction
        case .warning:
            return tokens.warning
        case .danger:
            return .red
        case .complete:
            return tokens.tertiaryText
        case .neutral:
            return tokens.secondaryText
        }
    }

    private func statusCapsuleBackground(for tone: AgentSessionStatusTone) -> Color {
        switch tone {
        case .warning, .danger:
            return tint(for: tone).opacity(0.11)
        case .active:
            return tint(for: tone).opacity(0.09)
        case .complete, .neutral:
            return themeStore.tokens(for: colorScheme).elevatedSurface.opacity(0.72)
        }
    }

    // 左侧列表只展示到分钟，避免 relative 时间按秒触发刷新。
    private static let minuteTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter
    }()
}

private struct SidebarSelectionBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    let selectedTint: Color
    let hoverTint: Color
    let selectedAccent: Color

    var body: some View {
        if isSelected {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selectedTint)
                Capsule(style: .continuous)
                    .fill(selectedAccent)
                    .frame(width: 3)
                    .padding(.vertical, 7)
                    .padding(.leading, 1)
            }
        } else if isHovered {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hoverTint)
        }
    }
}
