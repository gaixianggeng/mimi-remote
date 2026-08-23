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

    private func recentSessionsSection(tokens: ThemeTokens) -> some View {
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
                groupedSessionSections(
                    populatedGroups: populatedGroups,
                    grouped: grouped,
                    tokens: tokens
                )
            }
        }
    }

    /// 需要处理 / 正在运行 / 最近会话三段保留标题与计数；
    /// 每段使用一张整体卡片，12 小时边界再把“最近会话”拆成上下两张卡片。
    /// 分段本身取代了原来那条“运行中 · 刚刚活跃”摘要——它只描述第一条，却读起来像在描述整个列表。
    @ViewBuilder
    private func groupedSessionSections(
        populatedGroups: [WorkspaceSessionGroup],
        grouped: [WorkspaceSessionGroup: [AgentSession]],
        tokens: ThemeTokens
    ) -> some View {
        let branchValues = recentSessions.map(\.gitBranchName)
        // 给唯一的一个分组加标题是纯噪声：窄屏由筛选行充当它的标题，宽屏由胶囊行承担身份。
        // 出现「需要处理 / 正在运行」等多个分段时，标题才真正在区分内容。
        let showsSectionHeaders = populatedGroups.count > 1

        VStack(alignment: .leading, spacing: 18) {
            ForEach(populatedGroups, id: \.self) { group in
                let sessions = grouped[group] ?? []
                VStack(alignment: .leading, spacing: 8) {
                    if showsSectionHeaders {
                        sectionHeader(group, count: sessions.count, tokens: tokens)
                    }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sessionCountAccessibilityLabel(for: group, count: count))
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

    /// 筛选器固定在列表左侧，紧接它所过滤的结果，与会话行共用同一条左边线。
    /// 页面已经通过筛选器说明 Runtime，卡片不再重复渲染品牌或 Runtime 文案。
    ///
    /// 新建按钮下沉右下之后这一行只剩筛选器，不再有两个元素争抢宽度，`ViewThatFits` 也就不需要了。
    /// 窄屏把 Runtime 降级成菜单：分段控件是这一屏第二颗灰胶囊，而多数人一天只用一个 Runtime。
    private func recentSessionsHeader(
        showsCount: Bool,
        countGroup: WorkspaceSessionGroup?,
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
                    .font(themeStore.uiFont(.subheadline))
                    .foregroundStyle(tokens.tertiaryText)
                    .monospacedDigit()
                    .padding(
                        .trailing,
                        hasBottomTabBar ? 4 : WorkspaceSessionRowMetrics.horizontalPadding
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
        // 运行中的状态导轨是纯视觉提示并对辅助功能隐藏；把状态补进合并元素的 value，
        // VoiceOver 仍能在不增加第二个可聚焦元素的情况下读到「运行中」。
        let accessibilityValueParts = [
            session.isRunning && !showsStatus ? L10n.text("ui.running") : nil,
            unreadHistorySessionIDs.contains(session.id) ? L10n.text("ui.unread_result") : nil
        ].compactMap { $0 }

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
        .accessibilityValue(accessibilityValueParts.joined(separator: ", "))
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
