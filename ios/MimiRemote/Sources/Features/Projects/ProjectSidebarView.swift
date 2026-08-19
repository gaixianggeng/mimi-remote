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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var path = ""
    @State private var isOpening = false
    @State private var localError: String?

    @State private var browsePath: String?
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
            Form {
                currentDirectorySection
                childDirectoriesSection

                if let localError {
                    Section {
                        Text(localError)
                            .font(themeStore.uiFont(size: 13))
                            .foregroundStyle(.red)
                    } header: {
                        Text(L10n.text("ui.open_failed"))
                    }
                }

                Section {
                    TextField("/Users/me/finance", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await open(path: path) }
                    } label: {
                        Label(isOpening ? L10n.text("ui.opening") : L10n.text("ui.open_the_input_path"), systemImage: "folder.badge.plus")
                    }
                    .disabled(!canOpenTypedPath)
                } header: {
                    Text(L10n.text("ui.enter_path_manually"))
                } footer: {
                    Text(L10n.text("ui.you_can_directly_paste_the_absolute_path_in"))
                }
            }
            .navigationTitle(L10n.text("ui.open_workspace"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel"), role: .cancel) {
                        dismiss()
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("workspace.open.cancel")
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
            .quickLookPreview($previewURL)
        }
        .tint(tokens.primaryAction)
    }

    @ViewBuilder
    private var currentDirectorySection: some View {
        Section {
            WorkspaceCurrentDirectoryCard(
                directoryName: currentDirectoryName,
                path: browsePath ?? L10n.text("ui.locating_be47409b"),
                parentPath: browseParentPath,
                isBrowsing: isBrowsing,
                isOpening: isOpening,
                onNavigateToParent: { parentPath in
                    Task { await browse(to: parentPath) }
                }
            )
        } header: {
            Text(L10n.text("ui.current_location"))
        }
    }

    private func openCurrentBrowsePath() {
        guard let browsePath else { return }
        Task { await open(path: browsePath) }
    }

    @ViewBuilder
    private var childDirectoriesSection: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Section {
            if isBrowsing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("ui.loading_catalog"))
                        .foregroundStyle(.secondary)
                }
            } else if let browseError {
                Text(browseError)
                    .font(themeStore.uiFont(size: 13))
                    .foregroundStyle(.red)
                Button {
                    Task { await browse(to: browsePath ?? "") }
                } label: {
                    Label(L10n.text("ui.try_again"), systemImage: "arrow.clockwise")
                }
            } else if browseEntries.isEmpty {
                Text(L10n.text("ui.no_subdirectories_to_enter_or_files_to_preview"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(browseEntries) { entry in
                    Button {
                        if entry.isDir {
                            Task { await browse(to: entry.path) }
                        } else {
                            Task { await preview(entry) }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.isDir ? "folder" : "doc.text")
                                .font(themeStore.uiFont(size: 18, weight: .regular))
                                .foregroundStyle(tokens.accent)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(themeStore.uiFont(size: 15, weight: .medium))
                                    .foregroundStyle(tokens.primaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if previewingPath == entry.path {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: entry.isDir ? "chevron.right" : "eye")
                                    .font(themeStore.uiFont(size: 12, weight: .semibold))
                                    .foregroundStyle(tokens.tertiaryText)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpening || isBrowsing || previewingPath != nil || (!entry.canBrowse && !entry.isPreviewable))
                }

                if let previewError {
                    Text(previewError)
                        .font(themeStore.uiFont(size: 13))
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text(L10n.text("ui.content"))
        } footer: {
            if browseTruncated {
                Text(L10n.text("ui.the_directory_is_too_large_only_the_front"))
            } else {
                Text(L10n.text("ui.hidden_directories_library_and_common_cache_directories_will"))
            }
        }
    }

    private var currentDirectoryName: String {
        guard let browsePath, !browsePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.text("ui.locating")
        }
        let parts = browsePath.split(separator: "/").map(String.init)
        return parts.last ?? browsePath
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

struct WorkspaceCurrentDirectoryCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let directoryName: String
    let path: String
    let parentPath: String?
    let isBrowsing: Bool
    let isOpening: Bool
    let onNavigateToParent: (String) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            if let parentPath {
                Button {
                    onNavigateToParent(parentPath)
                } label: {
                    Label {
                        Text(L10n.text("ui.previous_level"))
                    } icon: {
                        Image(systemName: "arrow.up")
                            .accessibilityHidden(true)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isBrowsing || isOpening)
                .accessibilityLabel(L10n.text("ui.previous_level"))
                .accessibilityHint(L10n.text("ui.return_to_previous_level"))
                .accessibilityIdentifier("workspace.open.parent")
            }

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(themeStore.uiFont(size: 20, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .frame(width: 38, height: 38)
                    .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)

                Text(directoryName)
                    .font(themeStore.uiFont(size: 16, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(path)
                .font(themeStore.uiFont(size: 12))
                .foregroundStyle(tokens.secondaryText)
                // 路径是当前目录的识别信息，允许自然换行，避免长路径被截断后无法确认位置。
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
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
