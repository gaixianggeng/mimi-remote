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
    @ScaledMetric(relativeTo: .caption) private var compactActionFontSize: CGFloat = 12
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
                .padding(.top, 16)
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
            // 浮起按钮会压住列表最后几行。用系统原生的柔化滚动边缘让内容在撞上它之前淡掉，
            // 而不是给按钮加一块底板——会话页用的也是同一个 helper。
            .workbenchSoftBottomScrollEdge()
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
        // 分组只算一次：筛选行要用它决定计数该不该出现，列表要用它渲染分段。
        let grouped = Dictionary(grouping: recentSessions) { session in
            WorkspaceSessionGroup.of(session, status: session.displayStatus(foregroundActivity: nil))
        }
        let populatedGroups = WorkspaceSessionGroup.orderedPopulatedGroups(from: Set(grouped.keys))

        return VStack(alignment: .leading, spacing: 8) {
            if !showsInlineRuntimePicker {
                // 只有一个分组时筛选行就是那一段的标题，计数收在行尾；
                // 有多个分组时每段各自带计数，头部再放一个总数只会重复。
                recentSessionsHeader(
                    showsCount: populatedGroups.count <= 1,
                    countGroup: populatedGroups.count == 1 ? populatedGroups[0] : nil,
                    rowDensity: rowDensity,
                    tokens: tokens
                )
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
        let branchValues = recentSessions.map(\.gitBranchName)
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
                        branchValues: branchValues,
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
        // 计数推到行尾，跟系统列表（「最近通话  12」）一致；贴在标题后面会读成标题的一部分。
        //
        // 分区标题是给内容分段的路标，不是页面标题。用正文墨色的 15pt 半粗时它和
        // 会话标题同重，一屏里就出现两级都在喊的文字；计数更只是补充说明。
        // 两者一起降到 13pt 次级/三级灰，扫读时先看到的仍然是会话本身。
        HStack(spacing: 8) {
            Text(group.title)
                .font(themeStore.uiFont(.footnote, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)

            Spacer(minLength: 8)

            Text("\(count)")
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(tokens.tertiaryText)
                .monospacedDigit()
        }
        // 小节标题对齐前导状态列的左缘。这一列有了灰环兜底之后每行都有内容，
        // 才有资格当基准线；没有兜底时对齐它，整段完成态会话会让标题悬在空白左边。
        .padding(.horizontal, rowDensity.horizontalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sessionCountAccessibilityLabel(for: group, count: count))
    }

    @ViewBuilder
    private func sessionGroupBody(
        _ group: WorkspaceSessionGroup,
        sessions: [AgentSession],
        branchValues: [String?],
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

        if let firstStaleIndex {
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
                        branchValues: branchValues,
                        showsLoadMore: false,
                        rowDensity: rowDensity,
                        tokens: tokens
                    )
                }

                staleBoundaryHeader(rowDensity: rowDensity, tokens: tokens)

                sessionRowsStack(
                    sessions: staleSessions,
                    branchValues: branchValues,
                    showsLoadMore: showsLoadMore,
                    rowDensity: rowDensity,
                    tokens: tokens
                )
            }
        } else {
            sessionRowsStack(
                sessions: sessions,
                branchValues: branchValues,
                showsLoadMore: showsLoadMore,
                rowDensity: rowDensity,
                tokens: tokens
            )
        }
    }

    /// 会话行直接落在工作台画布上，不再套一张白卡。
    ///
    /// 卡片本身没有错，错的是**混用**：会话 tab 已经是扁平行，同一条会话在工作区里
    /// 换一套外壳，用户学到的规则就作废了。而且这一页真正需要卡片的是 Git 摘要、
    /// worktree 这些异类模块——会话列表也占一张卡时，白面就不再表达任何层级。
    /// 分组改由小节标题和留白承担，与会话 tab 完全同构。
    private func sessionRowsStack(
        sessions: [AgentSession],
        branchValues: [String?],
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
                    // 工作区只负责提供会话数据和点击行为；行内信息层级由会话页组件统一维护。
                    SessionIndexRow(
                        session: session,
                        foregroundActivity: foregroundActivity,
                        isSelected: session.id == sessionStore.selectedSessionID,
                        isPinned: sessionStore.isSessionPinned(session.id),
                        isArchived: sessionStore.isSessionArchived(session.id),
                        reminder: sessionStore.sessionReminder(for: session.id),
                        isObserving: sessionStore.isSessionObserving(session),
                        isExternalReadOnly: sessionStore.isExternalReadOnlySession(session),
                        isUnread: isUnread,
                        density: rowDensity,
                        branch: SessionListPresentation.branchToDisplay(
                            session.gitBranchName,
                            among: branchValues
                        ),
                        // 这一页的项目是恒定的；没有区分价值的分支时用目录末段区分 worktree。
                        identityFallback: .directory,
                        // 无状态的行画一枚灰环兜底，让前导列每行都有内容——
                        // 小节标题以这一列为基准线，列不能是稀疏的。
                        showsIdleStateGlyph: true,
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
                        showsNeutralHistoryStatus: false
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
    private func recentSessionsHeader(
        showsCount: Bool,
        countGroup: WorkspaceSessionGroup?,
        rowDensity: SessionIndexRowDensity,
        tokens: ThemeTokens
    ) -> some View {
        HStack(spacing: 12) {
            WorkspaceRuntimeMenuPicker(
                selection: $selectedRuntime,
                claudeChannelAvailable: claudeChannelAvailable
            )

            Spacer(minLength: 8)

            if showsCount {
                Text("\(recentSessions.count)")
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.tertiaryText)
                    .monospacedDigit()
                    .padding(
                        .trailing,
                        hasBottomTabBar ? 4 : rowDensity.horizontalPadding
                    )
                    .accessibilityLabel(
                        countGroup.map {
                            sessionCountAccessibilityLabel(for: $0, count: recentSessions.count)
                        } ?? L10n.plural("ui.sessions_count", count: recentSessions.count)
                    )
            }

            // 底部被浮动 Tab 栏占住时，新建按钮回到这一行的右端。
            // 这行本来就被菜单的 44pt 命中区撑满，多放一颗按钮不增加任何高度。
            // 灰色计数和实色圆钮的视觉重量差得远，不会读成同一个东西。
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
        let diameter = isFloating
            ? WorkspaceSessionFabMetrics.diameter
            : WorkspaceSessionFabMetrics.inlineDiameter

        return Button {
            // thread 创建时就绑定 runtime；这里必须把当前选择一路传到 SessionStore。
            onStartSession(selectedRuntime)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: isFloating ? 24 : 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.primaryActionForeground)
                .frame(width: diameter, height: diameter)
                .background(tokens.primaryAction, in: Circle())
                .frame(
                    minWidth: WorkbenchChromeIconMetrics.minimumHitTarget,
                    minHeight: WorkbenchChromeIconMetrics.minimumHitTarget
                )
                .contentShape(Circle())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .shadow(
            color: isFloating
                ? tokens.primaryAction.opacity(colorScheme == .dark ? 0.34 : 0.28)
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
            .font(themeStore.uiFont(.footnote, weight: .semibold))
            .foregroundStyle(tokens.secondaryText)
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
                HStack {
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
                .padding(.horizontal, rowDensity.horizontalPadding)
                .frame(minHeight: rowDensity.minimumHeight)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.loading_recent_conversations"))
    }

}
