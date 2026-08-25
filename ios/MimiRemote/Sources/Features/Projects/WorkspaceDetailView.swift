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
                // 空态是这段列表的替身，不是另一个模块；列表已经不套卡，它也不该套。
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if recentSessions.isEmpty {
                ContentUnavailableView(L10n.text("ui.no_sessions_yet"), systemImage: "bubble.left.and.bubble.right", description: Text(L10n.text("ui.after_a_new_session_is_created_in_this")))
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                groupedSessionSections(
                    populatedGroups: populatedGroups,
                    grouped: grouped,
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
        tokens: ThemeTokens
    ) -> some View {
        let branchValues = recentSessions.map(\.gitBranchName)
        // 给唯一的一个分组加标题是纯噪声：窄屏由筛选行充当它的标题，宽屏由胶囊行承担身份。
        // 出现「需要处理 / 正在运行」等多个分段时，标题才真正在区分内容。
        let showsSectionHeaders = populatedGroups.count > 1

        VStack(alignment: .leading, spacing: WorkspaceSessionRowMetrics.sectionBoundarySpacing) {
            ForEach(populatedGroups, id: \.self) { group in
                let sessions = grouped[group] ?? []
                VStack(alignment: .leading, spacing: WorkspaceSessionRowMetrics.sectionHeaderBottomSpacing) {
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
                        tokens: tokens
                    )
                }

                staleBoundaryHeader(tokens: tokens)

                sessionRowsStack(
                    sessions: staleSessions,
                    branchValues: branchValues,
                    showsLoadMore: showsLoadMore,
                    tokens: tokens
                )
            }
        } else {
            sessionRowsStack(
                sessions: sessions,
                branchValues: branchValues,
                showsLoadMore: showsLoadMore,
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
                // 与会话 tab 同一枚样式：没有卡片托着之后，按压反馈是这一行唯一
                // 还在证明"它是可点的"的东西。
                .buttonStyle(SessionIndexRowButtonStyle(pressedFill: tokens.selectionFill))
                .hoverEffect(.highlight)
                .sessionRowActions(session)
                .accessibilityIdentifier("workspace.session.\(session.id)")
            }

            // 加载入口只跟在最后一段的末尾；12 小时边界存在时自然落在旧会话那一段底部。
            if showsLoadMore, canLoadMoreSessions || isLoadingMoreSessions {
                Divider()
                    .overlay(tokens.border.opacity(0.62))

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

    /// 与 `sectionHeader` 同一档字号与墨色；差别只在它不带计数。
    /// 上方留白比行距大一档，这段留白就是分组边界本身，不需要再画线。
    private func staleBoundaryHeader(tokens: ThemeTokens) -> some View {
        Text(L10n.text("ui.twelve_hours_ago"))
            .font(themeStore.uiFont(.footnote, weight: .semibold))
            .foregroundStyle(tokens.secondaryText)
            .padding(.horizontal, WorkspaceSessionRowMetrics.horizontalPadding)
            .padding(.top, WorkspaceSessionRowMetrics.sectionBoundarySpacing)
            .padding(.bottom, WorkspaceSessionRowMetrics.sectionHeaderBottomSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isHeader)
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

        // 第二行只画标题之外的信息。preview 与 title 同源，重复时这里返回空串。
        let preview = SessionListPresentation.distinctPreviewDisplayText(for: session)
        let branch = WorkspaceSessionBranchPresentation.branchToDisplay(
            session.gitBranchName,
            among: branchValues
        )
        // 两条元信息都没有时不保留第二行的位置，否则标题下方是一段解释不了的空白。
        let hasSecondaryLine = branch != nil || !preview.isEmpty
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

                if hasSecondaryLine {
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
                            }
                            // 分支是 worktree 前缀，先按需要拿走它的理想宽度（上限 150pt），
                            // 剩下的全部让给摘要。
                            //
                            // 之前摘要的 layoutPriority 高于这里，SwiftUI 会先满足摘要，
                            // 再把分支压到零宽——渲染出来就是一枚孤零零的「…」，
                            // 既不表达分支也不表达截断，是列表里最刺眼的一处噪声。
                            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 220 : 150, alignment: .leading)
                            .layoutPriority(1)
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
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, WorkspaceSessionRowMetrics.horizontalPadding)
        .padding(.vertical, WorkspaceSessionRowMetrics.verticalPadding)
        .frame(
            minHeight: hasSecondaryLine
                ? WorkspaceSessionRowMetrics.minHeight
                : WorkspaceSessionRowMetrics.singleLineMinHeight,
            alignment: .top
        )
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
