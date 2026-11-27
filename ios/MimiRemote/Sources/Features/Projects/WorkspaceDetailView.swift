import SwiftUI

enum WorkspaceSessionLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        self == .loading
    }
}

struct WorkspaceDetailView<StatusLine: View>: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.workbenchBottomChromeClearance) private var bottomChromeClearance
    @Environment(\.workbenchHasCompactTabBar) private var hasCompactTabBar
    @Environment(\.workbenchHasBottomTabBar) private var hasBottomTabBar
    @AppStorage(WorkspaceSessionRuntimeChoice.enabledRuntimesPreferenceKey)
    private var enabledRuntimesRawValue = WorkspaceSessionRuntimeChoice.defaultEnabledRuntimesRawValue
    @ScaledMetric(relativeTo: .footnote) private var compactActionFontSize: CGFloat = 13
    @State private var isLoadingMoreSessions = false

    let statusLine: StatusLine
    let showsStatusLine: Bool
    /// 宽屏下 Runtime 筛选器由胶囊行承载，这里整条内容头部都不画。
    let showsInlineRuntimePicker: Bool
    let recentSessions: [AgentSession]
    let unreadHistorySessionIDs: Set<SessionID>
    let sessionLoadState: WorkspaceSessionLoadState
    let hasInitialSessionContent: Bool
    let canLoadMoreSessions: Bool
    @Binding var browseScope: WorkspaceSessionBrowseScope
    var preferredRuntime: WorkspaceSessionRuntimeChoice = .codex
    let availableRuntimeProviders: Set<String>
    var runtimeDiagnostic: RuntimeChannelDiagnostic? = nil
    var mergedCompleteness: WorkspaceMergedCompleteness? = nil
    var mergedPartialNotice: WorkspaceMergedPartialNotice? = nil
    var hasAttemptedLoad: Bool = false
    let onRetryUnavailable: (WorkspaceSessionRuntimeChoice) async -> Bool
    let currentDate: () -> Date
    let onRefreshSessions: () -> Void
    let onLoadMoreSessions: () async -> Void
    let onStartSession: (WorkspaceSessionRuntimeChoice) -> Void
    let onOpenSession: (AgentSession) -> Void
    var bottomContentMargin: CGFloat? = nil

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let resolvedBottomContentMargin = WorkspaceBottomContentMarginPolicy.resolvedMargin(
            explicitMargin: bottomContentMargin,
            hasCompactTabBar: hasCompactTabBar,
            hasBottomTabBar: hasBottomTabBar,
            environmentClearance: bottomChromeClearance,
            includesFloatingActionButtonAllowance: true
        )

        GeometryReader { geometry in
            // 与会话页使用同一条可用宽度规则；工作区不能再按页面身份选择另一套行密度。
            // 阈值由 SessionIndexRowDensity 单独持有，不在这里内联字面量：
            // 两处各写一个数字时，改了一处另一处会静默保持旧行为。
            let rowDensity = SessionIndexRowDensity.resolved(
                availableWidth: geometry.size.width,
                dynamicTypeSize: dynamicTypeSize
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    recentSessionsSection(rowDensity: rowDensity, tokens: tokens)
                }
                .padding(
                    .horizontal,
                    hasCompactTabBar
                        ? WorkbenchPageLayout.compactPadding
                        : WorkbenchPageLayout.regularPadding
                )
                // 手机顶部项目条与 Runtime 筛选器属于同一组，少留一档空白。
                // 宽屏没有第二条筛选行，仍保留原来的内容起始留白。
                .padding(.top, hasCompactTabBar ? 8 : 16)
                .frame(maxWidth: WorkspaceStripLayout.maxContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // 与会话页、设置页共用同一套 scrollContent 底部留白规则（#1108）：
            // iPhone 底部 Tab 栏按 bottomContentMargin 预留；宽屏与 iPadOS 26 顶部 Tab 仅在浮起 FAB 时让位。
            .contentMargins(.bottom, resolvedBottomContentMargin, for: .scrollContent)
            .scrollIndicators(.hidden)
            .background(tokens.workbenchCanvasBackground.ignoresSafeArea())
            // 底部浮起的按钮和 Tab 栏自己就是玻璃，只该虚化各自盖住的那一块；
            // 全宽的柔化边缘反而会在它们两侧糊出一条雾带。会话页用的也是同一个 helper。
            .workbenchClearBottomScrollEdge()
            // 叠在 ScrollView 之外，否则会跟着内容一起滚走。
            // 新建会话是本页最高频的动作，右上角在竖屏是最难够的位置；下沉到拇指区。
            // 底部已经站着一条浮动 Tab 栏时不再浮第二层——那会在同一个角上叠两层浮动材质。
            // 这种布局下新建按钮回到筛选行右端（见 `recentSessionsHeader`），一点高度都不多花。
            //
            // 只给两条边留同样的 20pt。浮动 Tab 栏的避让已经由容器的 safe area 给过一次，
            // 这里再叠 `bottomChromeClearance` 会重复计算，把按钮顶到半空
            // （实测 iPhone 上多抬了 84pt）。那个常量是给滚动内容做 inset 的，不是浮层的位移量。
            .overlay(alignment: .bottomTrailing) {
                if !hasBottomTabBar {
                    newSessionButton(tokens: tokens)
                        .padding(WorkspaceSessionFabMetrics.edgeInset)
                }
            }
        }
    }

    /// 失败会话在「待你处理」里只留 12 小时；页面一直开着时，在最早到期的那一刻重算一次分组，
    /// 不做每分钟刷新（#546 评审）。
    private func recentSessionsSection(
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens
    ) -> some View {
        let refreshDates = SessionAttentionPolicy.nextExpiry(in: recentSessions)
            .map { [$0.addingTimeInterval(1)] } ?? []
        return TimelineView(.explicit(refreshDates)) { _ in
            recentSessionsSectionContent(rowDensity: rowDensity, tokens: tokens, now: Date())
        }
    }

    private func recentSessionsSectionContent(
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens,
        now: Date
    ) -> some View {
        // 分组只算一次，列表按状态渲染分段。派生家族先在整份列表上分好，再随领头成员落段，
        // 运行中的子会话因此和已完成的父会话留在同一段里。
        let grouped = Dictionary(grouping: recentSessions) { session in
            WorkspaceSessionGroup.of(session, now: now)
        }
        let sections = SessionHierarchy.sectionedFamilies(
            WorkspaceSessionGroup.orderedPopulatedGroups(from: Set(grouped.keys))
                .map { (key: $0, sessions: grouped[$0] ?? []) }
        )

        return VStack(alignment: .leading, spacing: 8) {
            if !showsInlineRuntimePicker {
                recentSessionsHeader(tokens: tokens)
            }

            // 工作区状态紧贴第一条会话行，与列表共用左右内边距：
            // 它是这个列表的说明文字，夹在筛选行上方会重新读成悬空的元数据。
            if showsStatusLine {
                statusLine
                    .padding(.bottom, 2)
            }

            if browseScope.isAll, let mergedPartialNotice, !mergedPartialNotice.isEmpty, !recentSessions.isEmpty {
                mergedPartialNoticeBanner(mergedPartialNotice, tokens: tokens)
            } else if !browseScope.isAll, let runtimeDiagnostic, !recentSessions.isEmpty {
                runtimeDiagnosticBanner(runtimeDiagnostic, tokens: tokens)
            }

            if sessionLoadState.isLoading, !hasInitialSessionContent {
                // 首屏窗口还没凑满：稳定显示骨架屏，避免切换时先渲染欠填的半截列表再逐批变多。
                recentSessionPlaceholders(rowDensity: rowDensity, tokens: tokens)
            } else if browseScope.isAll, recentSessions.isEmpty, mergedCompleteness == .allUnavailable {
                ContentUnavailableView {
                    Label(
                        L10n.text("ui.workspace_merged_all_unavailable_title"),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(L10n.text("ui.workspace_merged_all_unavailable_message"))
                } actions: {
                    Button(L10n.text("ui.reload"), action: onRefreshSessions)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .accessibilityIdentifier("workspace.mergedAllUnavailable")
            } else if browseScope.isAll, recentSessions.isEmpty, mergedCompleteness == .cachedPreview {
                if hasAttemptedLoad {
                    ContentUnavailableView {
                        Label(
                            L10n.text("ui.unable_to_load_session"),
                            systemImage: "arrow.clockwise"
                        )
                    } actions: {
                        Button(L10n.text("ui.reload"), action: onRefreshSessions)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .accessibilityIdentifier("workspace.mergedCachedPreviewRetry")
                } else {
                    recentSessionPlaceholders(rowDensity: rowDensity, tokens: tokens)
                }
            } else if browseScope.isAll,
                      recentSessions.isEmpty,
                      mergedCompleteness != .completeExhausted,
                      let mergedPartialNotice,
                      !mergedPartialNotice.isEmpty {
                // M10 空态铁律：存在真实不可用或降级通道时绝不误显「暂无会话」，展示明确诊断与重试入口。
                ContentUnavailableView {
                    Label(
                        L10n.text("ui.workspace_merged_partial_empty_title"),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(mergedPartialNotice.localizedMessage)
                } actions: {
                    Button(L10n.text("ui.reload"), action: onRefreshSessions)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .accessibilityIdentifier("workspace.mergedPartialEmpty")
            } else if !browseScope.isAll, recentSessions.isEmpty, let runtimeDiagnostic {
                ContentUnavailableView {
                    Label(runtimeDiagnostic.localizedTitle, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(runtimeDiagnostic.localizedMessage)
                } actions: {
                    Button(L10n.text("ui.reload"), action: onRefreshSessions)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .accessibilityIdentifier("workspace.runtimeDiagnostic")
            } else if recentSessions.isEmpty, case .failed(let message) = sessionLoadState {
                ContentUnavailableView {
                    Label(L10n.text("ui.unable_to_load_session"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(L10n.text("ui.reload"), action: onRefreshSessions)
                }
                // 空态是这段列表的替身，不是另一个模块；列表已经不套卡，它也不该套。
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if recentSessions.isEmpty {
                ContentUnavailableView(L10n.text("ui.no_sessions_yet"), systemImage: "bubble.left.and.bubble.right", description: Text(L10n.text("ui.after_a_new_session_is_created_in_this")))
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                groupedSessionSections(
                    sections: sections,
                    rowDensity: rowDensity,
                    tokens: tokens,
                    now: now
                )
            }
        }
    }

    /// 需要处理 / 正在运行 / 最近会话三段保留标题与计数；12 小时边界再把「最近会话」
    /// 拆成前后两小节。分段全部由小节标题和留白表达，没有卡片参与。
    /// 分段本身取代了原来那条“运行中 · 刚刚活跃”摘要——它只描述第一条，却读起来像在描述整个列表。
    @ViewBuilder
    private func groupedSessionSections(
        sections: [SessionFamilySection<WorkspaceSessionGroup>],
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens,
        now: Date
    ) -> some View {
        // 给唯一的一个分组加标题是纯噪声：窄屏由筛选行充当它的标题，宽屏由胶囊行承担身份。
        // 出现「需要处理 / 正在运行」等多个分段时，标题才真正在区分内容。
        let showsSectionHeaders = sections.count > 1
        let identityFallback = SessionListPresentation.workspaceIdentityFallback(among: recentSessions)

        VStack(alignment: .leading, spacing: WorkspaceSessionRowMetrics.sectionBoundarySpacing) {
            ForEach(sections) { section in
                let group = section.key
                VStack(alignment: .leading, spacing: WorkspaceSessionRowMetrics.sectionHeaderBottomSpacing) {
                    if showsSectionHeaders {
                        // 计数只数这个状态本身的会话；随家族一起带进来的父子不改变它的含义。
                        sectionHeader(
                            group,
                            count: section.families.flatMap(\.members)
                                .filter { WorkspaceSessionGroup.of($0, now: now) == group }.count,
                            rowDensity: rowDensity,
                            tokens: tokens
                        )
                    }
                    sessionGroupBody(
                        group,
                        families: section.families,
                        identityFallback: identityFallback,
                        showsLoadMore: group == sections.last?.key,
                        rowDensity: rowDensity,
                        tokens: tokens
                    )
                }
            }
        }
    }

    private func sectionHeader(
        _ group: WorkspaceSessionGroup,
        count: Int,
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens
    ) -> some View {
        // 分区标题与会话 tab、设置页同一套排版（#563）。计数只是当前已展开窗口的数量，
        // 行尾一排数字会把列表读成仪表盘；数量改由 VoiceOver 朗读。
        Text(group.title)
            .pageSectionHeaderStyle()
            .frame(maxWidth: .infinity, alignment: .leading)
            // 小节标题对齐前导图标左缘。
            .padding(.horizontal, rowDensity.horizontalPadding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sessionCountAccessibilityLabel(for: group, count: count))
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func sessionGroupBody(
        _ group: WorkspaceSessionGroup,
        families: [SessionFamily],
        identityFallback: SessionIndexRowIdentityFallback,
        showsLoadMore: Bool,
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens
    ) -> some View {
        // 按家族里最近活动的成员判断 12 小时边界，父子不会被拆到边界两侧。
        let firstStaleIndex = group == .recent
            ? WorkspaceSessionAgeBoundary.firstStaleIndex(
                in: families.map(\.leader),
                excludingSessionIDs: sessionStore.pinnedSessionIDs,
                now: currentDate()
            )
            : nil

        // 分界线的意义是「上面是新的、下面是旧的」。最新一条就已超过 12 小时时上半边是空的，
        // 它会退化成悬在列表顶部的标题，被读成整段列表的名字；此时不再分界。
        if let firstStaleIndex,
           WorkspaceSessionAgeBoundary.showsBoundary(firstStaleIndex: firstStaleIndex) {
            let currentFamilies = Array(families.prefix(firstStaleIndex))
            let staleFamilies = Array(families.dropFirst(firstStaleIndex))

            // 12 小时是和「正在运行 / 最近会话」同级的信息分组边界，因此就用同一种小节标题。
            //
            // 它曾经是悬在两张卡片之间的一枚挖空标签——那个形态完全是卡片布局逼出来的：
            // 有了卡，时间标签既不能切进白面，又没有别的地方可去，只好悬空并伪装底色
            // （伪装色还错了一版）。列表扁平之后这些问题一起消失，标签回到它本来的身份。
            VStack(alignment: .leading, spacing: 0) {
                if !currentFamilies.isEmpty {
                    sessionRowsStack(
                        families: currentFamilies,
                        identityFallback: identityFallback,
                        showsLoadMore: false,
                        rowDensity: rowDensity,
                        tokens: tokens
                    )
                }

                staleBoundaryHeader(rowDensity: rowDensity, tokens: tokens)

                sessionRowsStack(
                    families: staleFamilies,
                    identityFallback: identityFallback,
                    showsLoadMore: showsLoadMore,
                    rowDensity: rowDensity,
                    tokens: tokens
                )
            }
        } else {
            sessionRowsStack(
                families: families,
                identityFallback: identityFallback,
                showsLoadMore: showsLoadMore,
                rowDensity: rowDensity,
                tokens: tokens
            )
        }
    }

    /// 会话行直接落在工作台画布上，不再套一张白卡。
    ///
    /// 工作区身份已在胶囊行出现，会话总览只留标题、状态和一条次要信息。
    /// 分组由小节标题和留白承担，不用卡片或逐行分隔线争夺注意力。
    private func sessionRowsStack(
        families: [SessionFamily],
        identityFallback: SessionIndexRowIdentityFallback,
        showsLoadMore: Bool,
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens
    ) -> some View {
        let hierarchyGuideX = browseScope.isAll
            ? rowDensity.horizontalPadding + rowDensity.stateGutterWidth / 2
            : rowDensity.horizontalPadding + 4
        let hierarchyContentInset = browseScope.isAll
            ? rowDensity.horizontalPadding + SessionIndexRowDensity.runtimeIconInset
            : rowDensity.horizontalPadding

        // 行与行之间不再画分隔线，只靠留白分开——逐行横线会把列表读成一张表格。
        // 线只保留在分组边界（小节标题上方的留白）和"显示更多"入口之前。
        return VStack(spacing: 0) {
            SessionHierarchyForEach(families: families, expansion: sessionStore.sessionHierarchyExpansion) { row, _ in
                let session = row.session
                let foregroundActivity = sessionStore.foregroundActivity(for: session.id)
                let isUnread = unreadHistorySessionIDs.contains(session.id)

                Button {
                    onOpenSession(session)
                } label: {
                    // 与会话 tab 同一种单行（#563）：标题 + 时间，宽屏 iPad 多一行摘要；需要处理或
                    // 仍在运行时，状态文字占据时间的位置。单运行时筛选时每行来源相同不重复画来源图标；
                    // 「全部」汇总视图下左侧恢复运行时品牌标记，明确每条会话归属。
                    SessionIndexRow(
                        session: session,
                        foregroundActivity: foregroundActivity,
                        isSelected: session.id == sessionStore.selectedSessionID,
                        isPinned: sessionStore.isSessionPinned(session.id),
                        isArchived: sessionStore.isSessionArchived(session.id),
                        reminder: sessionStore.sessionReminder(for: session.id),
                        isObserving: sessionStore.isSessionObserving(session),
                        isUnread: isUnread,
                        density: rowDensity,
                        identityFallback: identityFallback,
                        leadingSlot: browseScope.isAll ? .runtimeIcon : .none,
                        showsSessionPreview: UIDevice.current.userInterfaceIdiom == .pad && rowDensity == .table,
                        currentDate: currentDate,
                        calendar: calendar,
                        locale: locale,
                        timeZone: timeZone
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(SessionIndexRowButtonStyle(pressedFill: tokens.selectionFill))
                .hoverEffect(.highlight)
                .accessibilityElement(children: .combine)
                .accessibilityValue(
                    sessionAccessibilityValue(
                        for: session,
                        foregroundActivity: foregroundActivity,
                        isUnread: isUnread,
                        identityFallback: identityFallback
                    )
                )
                .sessionRowActions(session)
                .accessibilityIdentifier("workspace.session.\(session.id)")
                .sessionHierarchyRow(
                    row,
                    expansion: sessionStore.sessionHierarchyExpansion,
                    guideX: hierarchyGuideX,
                    contentInset: hierarchyContentInset
                )
            }

            // 加载入口只跟在最后一段的末尾；12 小时边界存在时自然落在旧会话那一段底部。
            if showsLoadMore, canLoadMoreSessions || isLoadingMoreSessions {
                Divider()
                    .overlay(tokens.border.opacity(0.62))
                    .padding(.horizontal, rowDensity.horizontalPadding)

                loadMoreButton(tokens: tokens)
            }
        }
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

    /// 筛选器固定在列表左侧，紧接它所过滤的结果，与会话行共用同一条左边线。
    /// 页面已经通过筛选器说明 Runtime，卡片不再重复渲染品牌或 Runtime 文案。
    ///
    /// 新建按钮下沉右下之后这一行只剩筛选器，不再有两个元素争抢宽度，`ViewThatFits` 也就不需要了。
    /// 窄屏把 Runtime 降级成菜单：分段控件是这一屏第二颗灰胶囊，而多数人一天只用一个 Runtime。
    private func recentSessionsHeader(tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            WorkspaceRuntimePopoverPicker(
                browseScope: $browseScope,
                availableRuntimeProviders: availableRuntimeProviders,
                onRetryUnavailable: onRetryUnavailable
            )

            Spacer(minLength: 8)

            // 底部被浮动 Tab 栏占住时，新建按钮回到这一行的右端。
            // 这行本来就被菜单的 44pt 命中区撑满，多放一颗按钮不增加任何高度。
            // 计数只是当前已展开窗口的数量，省去它避免把筛选行读成仪表盘。
            if hasBottomTabBar {
                newSessionButton(tokens: tokens)
            }
        }
    }

    private func sessionAccessibilityValue(
        for session: AgentSession,
        foregroundActivity: SessionForegroundActivity?,
        isUnread: Bool,
        identityFallback: SessionIndexRowIdentityFallback
    ) -> String {
        let identity: String? = SessionListPresentation.normalizedBranch(session.gitBranchName).map {
            "\(L10n.text("ui.branch")) \($0)"
        } ?? SessionIndexRow.identityFallbackAccessibilityLabel(for: session, fallback: identityFallback)
        return SessionIndexRow.accessibilityValue(
            status: session.displayStatus(foregroundActivity: foregroundActivity),
            sessionStatus: session.status,
            isUnread: isUnread,
            showsNeutralHistoryStatus: false,
            runtime: browseScope.isAll ? SessionRuntimePresentation(session: session).title : nil,
            identity: identity
        )
    }

    private func sessionCountAccessibilityLabel(
        for group: WorkspaceSessionGroup,
        count: Int
    ) -> String {
        L10n.format(
            "ui.counts_joined",
            group.title,
            L10n.plural("ui.sessions_count", count: count)
        )
    }

    private var orderedAvailableCreationRuntimes: [WorkspaceSessionRuntimeChoice] {
        guard mergedCompleteness != .allUnavailable else { return [] }
        let enabledSet = WorkspaceSessionRuntimeChoice.enabledRuntimeSet(from: enabledRuntimesRawValue)
        let available = WorkspaceSessionRuntimeChoice.available(
            runtimeProviders: availableRuntimeProviders,
            enabledRuntimes: enabledSet
        )
        guard available.contains(preferredRuntime) else { return available }
        return [preferredRuntime] + available.filter { $0 != preferredRuntime }
    }

    @ViewBuilder
    private func newSessionButtonVisual(isFloating: Bool, diameter: CGFloat, tokens: ThemeTokens) -> some View {
        if isFloating {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.primaryActionForeground)
                .frame(width: diameter, height: diameter)
                .background(tokens.primaryAction, in: Circle())
                .frame(
                    minWidth: WorkbenchChromeIconMetrics.minimumHitTarget,
                    minHeight: WorkbenchChromeIconMetrics.minimumHitTarget
                )
                .contentShape(Circle())
        } else {
            // 手机上与会话 tab 顶栏的新建按钮同一种写法：磨砂圆 + 正文色加号（#563）。
            // 过去这里是一颗紫色实心圆，同一个动作在两页长成两样。
            WorkbenchChromeIcon(systemName: "plus")
                .foregroundStyle(tokens.primaryText)
                .workbenchChromeCircle(tokens: tokens)
        }
    }

    /// 浮在列表右下角（或窄屏行内右端）：
    /// - 单运行时模式：一键直建当前所选运行时会话；
    /// - 「全部」模式（M9）：仅 1 个可用运行时直接创建；多个可用运行时弹出菜单让用户选择（优先项置顶）。
    @ViewBuilder
    private func newSessionButton(tokens: ThemeTokens) -> some View {
        let isFloating = !hasBottomTabBar
        let diameter = WorkspaceSessionFabMetrics.diameter
        let enabledSet = WorkspaceSessionRuntimeChoice.enabledRuntimeSet(from: enabledRuntimesRawValue)

        switch browseScope {
        case let .single(selectedRuntime):
            Button {
                onStartSession(selectedRuntime)
            } label: {
                newSessionButtonVisual(isFloating: isFloating, diameter: diameter, tokens: tokens)
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .disabled(
                (runtimeDiagnostic != nil && availableRuntimeProviders.isEmpty)
                    || !selectedRuntime.isAvailable(
                        in: availableRuntimeProviders,
                        enabledRuntimes: enabledSet
                    )
            )
            .shadow(
                color: isFloating ? tokens.primaryActionShadow : .clear,
                radius: isFloating ? 12 : 0,
                y: isFloating ? 5 : 0
            )
            .accessibilityLabel(L10n.text("ui.new_session_3da224c4"))
            .accessibilityValue(selectedRuntime.title)
            .accessibilityIdentifier("workspace.sessions.newSession")

        case .all:
            let choices = orderedAvailableCreationRuntimes
            if choices.count == 1, let singleChoice = choices.first {
                Button {
                    onStartSession(singleChoice)
                } label: {
                    newSessionButtonVisual(isFloating: isFloating, diameter: diameter, tokens: tokens)
                }
                .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                .shadow(
                    color: isFloating ? tokens.primaryActionShadow : .clear,
                    radius: isFloating ? 12 : 0,
                    y: isFloating ? 5 : 0
                )
                .accessibilityLabel(L10n.text("ui.new_session_3da224c4"))
                .accessibilityValue(singleChoice.title)
                .accessibilityIdentifier("workspace.sessions.newSession")
            } else if choices.count > 1 {
                Menu {
                    ForEach(choices) { choice in
                        Button {
                            onStartSession(choice)
                        } label: {
                            Label(choice.listTitle, systemImage: choice.actionSystemImage)
                        }
                        .accessibilityIdentifier("workspace.sessions.newSession.\(choice.rawValue)")
                    }
                } label: {
                    newSessionButtonVisual(isFloating: isFloating, diameter: diameter, tokens: tokens)
                }
                .buttonStyle(.plain)
                .shadow(
                    color: isFloating ? tokens.primaryActionShadow : .clear,
                    radius: isFloating ? 12 : 0,
                    y: isFloating ? 5 : 0
                )
                .accessibilityLabel(L10n.text("ui.new_session_3da224c4"))
                .accessibilityValue(L10n.text("ui.workspace_runtime_all"))
                .accessibilityIdentifier("workspace.sessions.newSession")
            } else {
                Button {} label: {
                    newSessionButtonVisual(isFloating: isFloating, diameter: diameter, tokens: tokens)
                }
                .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                .disabled(true)
                .shadow(
                    color: isFloating ? tokens.primaryActionShadow : .clear,
                    radius: isFloating ? 12 : 0,
                    y: isFloating ? 5 : 0
                )
                .accessibilityLabel(L10n.text("ui.new_session_3da224c4"))
                .accessibilityIdentifier("workspace.sessions.newSession")
            }
        }
    }

    /// 与 `sectionHeader` 同一档字号与墨色；差别只在它不带计数。
    /// 上方留白比行距大一档，这段留白就是分组边界本身，不需要再画线。
    private func staleBoundaryHeader(
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens
    ) -> some View {
        Text(L10n.text("ui.twelve_hours_ago"))
            .pageSectionHeaderStyle()
            .padding(.horizontal, rowDensity.horizontalPadding)
            .padding(.top, WorkspaceSessionRowMetrics.sectionBoundarySpacing)
            .padding(.bottom, WorkspaceSessionRowMetrics.sectionHeaderBottomSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(L10n.text("ui.twelve_hours_ago"))
    }

    private func recentSessionPlaceholders(
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                // 与单行会话行同形：一条标题占位，右端一小段时间占位。
                HStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tokens.elevatedSurface)
                        .frame(width: 210, height: 12)
                    Spacer(minLength: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tokens.elevatedSurface)
                        .frame(width: 36, height: 9)
                }
                .padding(.horizontal, rowDensity.horizontalPadding)
                .frame(minHeight: SessionIndexRow.libraryRowMinimumHeight)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.loading_recent_conversations"))
    }

    private func mergedPartialNoticeBanner(
        _ notice: WorkspaceMergedPartialNotice,
        tokens: ThemeTokens
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(themeStore.uiFont(.footnote, weight: .semibold))
                .foregroundStyle(tokens.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.localizedTitle)
                    .font(themeStore.uiFont(.footnote, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(notice.localizedMessage)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L10n.text("ui.reload"), action: onRefreshSessions)
                .font(themeStore.uiFont(.caption, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.warning.opacity(0.35), lineWidth: 1)
        }
        .accessibilityIdentifier("workspace.mergedPartialNoticeBanner")
    }

    private func runtimeDiagnosticBanner(
        _ diagnostic: RuntimeChannelDiagnostic,
        tokens: ThemeTokens
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(themeStore.uiFont(.footnote, weight: .semibold))
                .foregroundStyle(tokens.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.localizedTitle)
                    .font(themeStore.uiFont(.footnote, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(diagnostic.localizedMessage)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L10n.text("ui.reload"), action: onRefreshSessions)
                .font(themeStore.uiFont(.caption, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.warning.opacity(0.35), lineWidth: 1)
        }
        .accessibilityIdentifier("workspace.runtimeDiagnosticBanner")
    }
}

/// 胶囊收缩后，工作区不可用状态仍集中在这一行，保留导航恢复线索。
/// 根工作区的 Git 摘要不在这里展示：它描述的是 project.path，不能代表各会话 worktree。
struct WorkspaceUnavailableStatusLine: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let isUnavailable: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        Group {
            if isUnavailable {
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
}

/// 工作区「全部」汇总详情页：独立订阅 `WorkspaceMergedSessionCoordinator` 与 `SessionStore`，
/// 避免 `WorkspaceRootView` 在分页滚动时直接计算合并投影。
struct WorkspaceMergedDetailPageView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @ObservedObject var mergedCoordinator: WorkspaceMergedSessionCoordinator
    @State private var didObserveLoading = false

    let project: AgentProject
    let mergedKey: WorkspaceMergedPresentationKey
    let showsStatusLine: Bool
    let showsInlineRuntimePicker: Bool
    @Binding var browseScope: WorkspaceSessionBrowseScope
    let preferredRuntime: WorkspaceSessionRuntimeChoice
    let currentDate: () -> Date
    let onStartSession: (AgentProject, WorkspaceSessionRuntimeChoice) -> Void
    let onOpenSession: (AgentSession) -> Void
    let bottomContentMargin: CGFloat?

    var body: some View {
        let projection = mergedCoordinator.projection(for: mergedKey, sessionStore: sessionStore)
        let loadState = mergedCoordinator.loadState(for: mergedKey)
        WorkspaceDetailView(
            statusLine: WorkspaceUnavailableStatusLine(isUnavailable: showsStatusLine),
            showsStatusLine: showsStatusLine,
            showsInlineRuntimePicker: showsInlineRuntimePicker,
            recentSessions: projection.visibleSessions,
            unreadHistorySessionIDs: sessionStore.unreadHistorySessionIDs,
            sessionLoadState: loadState,
            hasInitialSessionContent: projection.hasInitialContent,
            canLoadMoreSessions: projection.canLoadMore,
            browseScope: $browseScope,
            preferredRuntime: preferredRuntime,
            availableRuntimeProviders: sessionStore.availableRuntimeProviders,
            mergedCompleteness: projection.completeness,
            mergedPartialNotice: projection.partialNotice,
            hasAttemptedLoad: didObserveLoading,
            onRetryUnavailable: { choice in
                await sessionStore.retryRuntimeAvailability(choice.runtimeProvider)
            },
            currentDate: currentDate,
            onRefreshSessions: {
                Task {
                    await mergedCoordinator.refresh(
                        project: project,
                        key: mergedKey,
                        sessionStore: sessionStore,
                        restartFromFirst: true
                    )
                }
            },
            onLoadMoreSessions: {
                await mergedCoordinator.loadMore(
                    project: project,
                    key: mergedKey,
                    sessionStore: sessionStore
                )
            },
            onStartSession: { runtimeChoice in
                onStartSession(project, runtimeChoice)
            },
            onOpenSession: onOpenSession,
            bottomContentMargin: bottomContentMargin
        )
        .onAppear {
            if loadState.isLoading {
                didObserveLoading = true
            }
        }
        .onChange(of: loadState) { _, newState in
            if newState.isLoading {
                didObserveLoading = true
            }
        }
        .onChange(of: mergedKey) { _, newKey in
            didObserveLoading = mergedCoordinator.loadState(for: newKey).isLoading
        }
    }
}
