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
    @Binding var selectedRuntime: WorkspaceSessionRuntimeChoice
    let codexChannelAvailable: Bool
    let claudeChannelAvailable: Bool
    let currentDate: () -> Date
    let onRefreshSessions: () -> Void
    let onLoadMoreSessions: () async -> Void
    let onStartSession: (WorkspaceSessionRuntimeChoice) -> Void
    let onOpenSession: (AgentSession) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

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
                // 三个顶层页面消费同一个浮动栏 clearance；宽屏无 Tab Bar 时只保留常规页面留白。
                // 只有按钮真的浮在内容之上时才追加让位高度；回到行内就不需要了。
                .padding(
                    .bottom,
                    (hasCompactTabBar
                        ? bottomChromeClearance
                        : WorkbenchPageLayout.regularPadding)
                        + (hasBottomTabBar ? 0 : WorkspaceSessionFabMetrics.contentBottomAllowance)
                )
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
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

    private func recentSessionsSection(
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens
    ) -> some View {
        // 分组只算一次，列表按状态渲染分段。
        let grouped = Dictionary(grouping: recentSessions) { session in
            WorkspaceSessionGroup.of(session, status: session.displayStatus(foregroundActivity: nil))
        }
        let populatedGroups = WorkspaceSessionGroup.orderedPopulatedGroups(from: Set(grouped.keys))

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

            if sessionLoadState.isLoading, !hasInitialSessionContent {
                // 首屏窗口还没凑满：稳定显示骨架屏，避免切换时先渲染欠填的半截列表再逐批变多。
                recentSessionPlaceholders(rowDensity: rowDensity, tokens: tokens)
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
                    populatedGroups: populatedGroups,
                    grouped: grouped,
                    rowDensity: rowDensity,
                    tokens: tokens
                )
            }
        }
    }

    /// 需要处理 / 正在运行 / 最近会话三段保留标题与计数；12 小时边界再把「最近会话」
    /// 拆成前后两小节。分段全部由小节标题和留白表达，没有卡片参与。
    /// 分段本身取代了原来那条“运行中 · 刚刚活跃”摘要——它只描述第一条，却读起来像在描述整个列表。
    @ViewBuilder
    private func groupedSessionSections(
        populatedGroups: [WorkspaceSessionGroup],
        grouped: [WorkspaceSessionGroup: [AgentSession]],
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens
    ) -> some View {
        // 给唯一的一个分组加标题是纯噪声：窄屏由筛选行充当它的标题，宽屏由胶囊行承担身份。
        // 出现「需要处理 / 正在运行」等多个分段时，标题才真正在区分内容。
        let showsSectionHeaders = populatedGroups.count > 1

        VStack(alignment: .leading, spacing: WorkspaceSessionRowMetrics.sectionBoundarySpacing) {
            ForEach(populatedGroups, id: \.self) { group in
                let sessions = grouped[group] ?? []
                VStack(alignment: .leading, spacing: WorkspaceSessionRowMetrics.sectionHeaderBottomSpacing) {
                    if showsSectionHeaders {
                        sectionHeader(
                            group,
                            count: sessions.count,
                            rowDensity: rowDensity,
                            tokens: tokens
                        )
                    }
                    sessionGroupBody(
                        group,
                        sessions: sessions,
                        showsLoadMore: group == populatedGroups.last,
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
        sessions: [AgentSession],
        showsLoadMore: Bool,
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens
    ) -> some View {
        let firstStaleIndex = group == .recent
            ? WorkspaceSessionAgeBoundary.firstStaleIndex(
                in: sessions,
                excludingSessionIDs: sessionStore.pinnedSessionIDs,
                now: currentDate()
            )
            : nil

        // 分界线的意义是「上面是新的、下面是旧的」。最新一条就已超过 12 小时时上半边是空的，
        // 它会退化成悬在列表顶部的标题，被读成整段列表的名字；此时不再分界。
        if let firstStaleIndex,
           WorkspaceSessionAgeBoundary.showsBoundary(firstStaleIndex: firstStaleIndex) {
            let currentSessions = Array(sessions.prefix(firstStaleIndex))
            let staleSessions = Array(sessions.dropFirst(firstStaleIndex))

            // 12 小时是和「正在运行 / 最近会话」同级的信息分组边界，因此就用同一种小节标题。
            //
            // 它曾经是悬在两张卡片之间的一枚挖空标签——那个形态完全是卡片布局逼出来的：
            // 有了卡，时间标签既不能切进白面，又没有别的地方可去，只好悬空并伪装底色
            // （伪装色还错了一版）。列表扁平之后这些问题一起消失，标签回到它本来的身份。
            VStack(alignment: .leading, spacing: 0) {
                if !currentSessions.isEmpty {
                    sessionRowsStack(
                        sessions: currentSessions,
                        showsLoadMore: false,
                        rowDensity: rowDensity,
                        tokens: tokens
                    )
                }

                staleBoundaryHeader(rowDensity: rowDensity, tokens: tokens)

                sessionRowsStack(
                    sessions: staleSessions,
                    showsLoadMore: showsLoadMore,
                    rowDensity: rowDensity,
                    tokens: tokens
                )
            }
        } else {
            sessionRowsStack(
                sessions: sessions,
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
        sessions: [AgentSession],
        showsLoadMore: Bool,
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens
    ) -> some View {
        // 行与行之间不再画分隔线，只靠留白分开——逐行横线会把列表读成一张表格。
        // 线只保留在分组边界（小节标题上方的留白）和"显示更多"入口之前。
        VStack(spacing: 0) {
            ForEach(sessions, id: \.id) { session in
                let foregroundActivity = sessionStore.foregroundActivity(for: session.id)
                let isUnread = unreadHistorySessionIDs.contains(session.id)

                Button {
                    onOpenSession(session)
                } label: {
                    // 与会话 tab 同一种单行（#563）：标题 + 时间，宽屏 iPad 多一行摘要；需要处理或
                    // 仍在运行时，状态文字占据时间的位置。顶部已按 Codex / Claude 筛选，每行来源
                    // 相同，不再重复画来源标记，标题直接与分组标题对齐。
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
                        leadingSlot: .none,
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
                    SessionIndexRow.accessibilityValue(
                        status: session.displayStatus(foregroundActivity: foregroundActivity),
                        sessionStatus: session.status,
                        isUnread: isUnread,
                        showsNeutralHistoryStatus: false,
                        identity: SessionListPresentation.normalizedBranch(session.gitBranchName).map {
                            "\(L10n.text("ui.branch")) \($0)"
                        } ?? SessionIndexRow.identityFallbackAccessibilityLabel(for: session, fallback: .directory)
                    )
                )
                .sessionRowActions(session)
                .accessibilityIdentifier("workspace.session.\(session.id)")
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
                selection: $selectedRuntime,
                claudeChannelAvailable: claudeChannelAvailable,
                codexChannelAvailable: codexChannelAvailable
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

    /// 浮在列表右下角。
    ///
    /// 曾经在角上挂过一枚 runtime 品牌标记，用来补偿筛选器和这个按钮分处页面两端。
    /// 实机上它读成贴在纯色圆上的一块杂物，代价大于收益，已移除；
    /// 「会建哪种会话」改由顶部筛选器单独承担，VoiceOver 仍从 `accessibilityValue` 拿到。
    private func newSessionButton(tokens: ThemeTokens) -> some View {
        // 浮起时可以画得实体一些；回到筛选行里必须收进 44pt 行高，也不该再投影——
        // 行内元素投影会读成一枚悬在纸面上的贴纸。
        let isFloating = !hasBottomTabBar
        let diameter = WorkspaceSessionFabMetrics.diameter

        return Button {
            // thread 创建时就绑定 runtime；这里必须把当前选择一路传到 SessionStore。
            onStartSession(selectedRuntime)
        } label: {
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
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .disabled(!selectedRuntime.isAvailable(
            codexChannelAvailable: codexChannelAvailable,
            claudeChannelAvailable: claudeChannelAvailable
        ))
        .shadow(
            color: isFloating
                ? tokens.primaryActionShadow
                : .clear,
            radius: isFloating ? 12 : 0,
            y: isFloating ? 5 : 0
        )
        .accessibilityLabel(L10n.text("ui.new_session_3da224c4"))
        .accessibilityValue(selectedRuntime.title)
        .accessibilityIdentifier("workspace.sessions.newSession")
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

}
