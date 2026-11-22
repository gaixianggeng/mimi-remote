import SwiftUI
import UIKit

/// iPhone 会话详情页悬浮胶囊顶栏的度量与开关策略。
enum PhoneSessionFloatingCapsuleMetrics {
    /// 胶囊最小高度（同时容纳 44pt 按钮热区与两行紧凑标题）。
    static let minimumHeight: CGFloat = 48
    /// 胶囊最小宽度，避免极短标题时左右按钮贴得过近。
    static let minimumWidth: CGFloat = 200
    /// 胶囊固定最大宽度（iPhone 上权衡 280–320pt 区间取 304pt）。
    /// - 402pt 标准 iPhone（如 iPhone 17）两侧各留 49pt，悬浮纵深感明显；
    /// - 375pt 小屏（如 iPhone SE / 13 mini）两侧各留 35.5pt，不贴边；
    /// - 扣除内部 2pt×2 外边距、两枚 44pt 按钮及 6pt×2 间距后，标题+图标区最多 200pt，
    ///   长标题干净尾部截断、绝不撑破胶囊。
    static let maximumWidth: CGFloat = 304
    /// 胶囊与屏幕左右边缘的最小安全留白（用于极窄容器兜底）。
    static let horizontalScreenMargin: CGFloat = 16
    /// 胶囊顶部距安全区（状态栏 / 动态岛下沿）的呼吸间距。
    static let topPadding: CGFloat = 4
    /// 胶囊底部与列表首条消息之间的呼吸间距。
    static let bottomPadding: CGFloat = 8
    /// 胶囊内边距：2pt + 44pt/2 = 24pt = 48pt/2，让按钮与胶囊圆弧几何同心。
    static let horizontalContentPadding: CGFloat = 2
    static let verticalContentPadding: CGFloat = 2
    /// 胶囊内左右按钮触控命中区（满足 HIG 44pt）。
    static let buttonHitSize: CGFloat = 44
    /// 胶囊内左按钮、中间标题区、右按钮之间的水平间距。
    static let itemSpacing: CGFloat = 6
    /// 图标与文字之间的间距。
    static let iconTitleSpacing: CGFloat = 7
    /// 工作区图标尺寸（与原有顶栏保持一致）。
    static let workspaceIconSize: CGFloat = 22

    /// 仅对 iPhone 紧凑导航启用悬浮胶囊顶栏；iPad（窄窗、竖屏、横屏）保持原有系统导航栏不变。
    static func isEnabled(layout: WorkbenchLayout) -> Bool {
        layout.usesPhoneIntegratedBottomChrome
    }

    /// 计算当前容器宽度下胶囊允许的最大宽度，严格不超过 `maximumWidth`。
    static func resolvedMaxWidth(containerWidth: CGFloat) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else {
            return maximumWidth
        }
        let available = max(0, containerWidth - horizontalScreenMargin * 2)
        return min(maximumWidth, available)
    }

    /// 胶囊内标题+图标区可用的最大宽度，约束长标题截断而不挤压左右按钮。
    static func titleRegionMaxWidth(capsuleMaxWidth: CGFloat) -> CGFloat {
        let reserved = horizontalContentPadding * 2
            + buttonHitSize * 2
            + itemSpacing * 2
        return max(60, capsuleMaxWidth - reserved)
    }

    /// 胶囊内标题+图标区的最小宽度，确保短标题时胶囊维持稳定最小宽度且按钮紧贴两端。
    static func titleRegionMinWidth(capsuleMaxWidth: CGFloat) -> CGFloat {
        let reserved = horizontalContentPadding * 2
            + buttonHitSize * 2
            + itemSpacing * 2
        let targetMin = max(0, minimumWidth - reserved)
        return min(targetMin, titleRegionMaxWidth(capsuleMaxWidth: capsuleMaxWidth))
    }

    /// 胶囊圆角始终等于高度一半。
    static func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        height / 2
    }
}

/// 顶栏标题、副标题与工作区图标的展示数据，供 iPad 原生导航栏与 iPhone 悬浮胶囊共用。
struct SessionNavigationTitleDisplayData {
    let title: String
    let subtitle: String
    let showsStatus: Bool
    let subtitleColor: Color
    let subtitleFont: Font
    let accessibilityValue: String
    let workspaceIcon: WorkspaceProjectIconContent?
}

/// iPhone 会话详情页居中悬浮胶囊顶栏。
/// 把返回按钮、工作区图标、会话标题/副标题与右侧更多菜单收进同一枚居中玻璃胶囊，
/// 悬于消息列表之上，并按系统版本自动采用 iOS 26 Liquid Glass 或旧版 `.ultraThinMaterial`。
struct PhoneSessionFloatingCapsuleHeader<MoreMenuContent: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let data: SessionNavigationTitleDisplayData
    let tokens: ThemeTokens
    let availableWidth: CGFloat
    let isMenuDisabled: Bool
    let onBack: () -> Void
    private let moreMenuContent: MoreMenuContent

    init(
        data: SessionNavigationTitleDisplayData,
        tokens: ThemeTokens,
        availableWidth: CGFloat,
        isMenuDisabled: Bool,
        onBack: @escaping () -> Void,
        @ViewBuilder moreMenuContent: () -> MoreMenuContent
    ) {
        self.data = data
        self.tokens = tokens
        self.availableWidth = availableWidth
        self.isMenuDisabled = isMenuDisabled
        self.onBack = onBack
        self.moreMenuContent = moreMenuContent()
    }

    private var capsuleMaxWidth: CGFloat {
        PhoneSessionFloatingCapsuleMetrics.resolvedMaxWidth(containerWidth: availableWidth)
    }

    private var titleRegionMaxWidth: CGFloat {
        PhoneSessionFloatingCapsuleMetrics.titleRegionMaxWidth(capsuleMaxWidth: capsuleMaxWidth)
    }

    private var titleRegionMinWidth: CGFloat {
        PhoneSessionFloatingCapsuleMetrics.titleRegionMinWidth(capsuleMaxWidth: capsuleMaxWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            capsuleChrome
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PhoneSessionFloatingCapsuleMetrics.horizontalScreenMargin)
        .padding(.top, PhoneSessionFloatingCapsuleMetrics.topPadding)
        .padding(.bottom, PhoneSessionFloatingCapsuleMetrics.bottomPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessionDetail.floatingCapsuleHeader")
    }

    @ViewBuilder
    private var capsuleChrome: some View {
        if reduceTransparency {
            capsuleContent
                .background(tokens.elevatedSurface, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            colorScheme == .light
                                ? Color.black.opacity(0.14)
                                : Color.white.opacity(0.22),
                            lineWidth: 0.75
                        )
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .light ? 0.10 : 0.30),
                    radius: 8,
                    x: 0,
                    y: 3
                )
        } else if #available(iOS 26.0, *) {
            GlassEffectContainer {
                capsuleContent
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
        } else {
            capsuleContent
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            colorScheme == .light
                                ? Color.black.opacity(0.08)
                                : Color.white.opacity(0.16),
                            lineWidth: 0.75
                        )
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .light ? 0.08 : 0.28),
                    radius: 10,
                    x: 0,
                    y: 4
                )
        }
    }

    private var capsuleContent: some View {
        HStack(spacing: PhoneSessionFloatingCapsuleMetrics.itemSpacing) {
            Button(action: onBack) {
                WorkbenchChromeIcon(systemName: "chevron.backward")
                    .foregroundStyle(tokens.primaryText.opacity(0.86))
                    .frame(
                        width: PhoneSessionFloatingCapsuleMetrics.buttonHitSize,
                        height: PhoneSessionFloatingCapsuleMetrics.buttonHitSize
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .fixedSize()
            .layoutPriority(1)
            .accessibilityLabel(L10n.text("ui.return_to_previous_level"))
            .accessibilityIdentifier("sessionDetail.back")

            titleCluster
                .frame(
                    minWidth: titleRegionMinWidth,
                    maxWidth: titleRegionMaxWidth,
                    alignment: .center
                )
                .layoutPriority(0)

            Menu {
                moreMenuContent
            } label: {
                WorkbenchChromeIcon(systemName: "ellipsis")
                    .foregroundStyle(tokens.primaryText.opacity(0.80))
                    .frame(
                        width: PhoneSessionFloatingCapsuleMetrics.buttonHitSize,
                        height: PhoneSessionFloatingCapsuleMetrics.buttonHitSize
                    )
                    .contentShape(Circle())
            }
            .menuOrder(.fixed)
            .disabled(isMenuDisabled)
            .fixedSize()
            .layoutPriority(1)
            .accessibilityLabel(L10n.text("ui.options"))
            .accessibilityIdentifier("sessionDetail.more")
        }
        .padding(.horizontal, PhoneSessionFloatingCapsuleMetrics.horizontalContentPadding)
        .padding(.vertical, PhoneSessionFloatingCapsuleMetrics.verticalContentPadding)
        .frame(minHeight: PhoneSessionFloatingCapsuleMetrics.minimumHeight)
        .frame(maxWidth: capsuleMaxWidth)
        .clipShape(Capsule())
    }

    private var titleCluster: some View {
        let textAlignment: HorizontalAlignment = data.workspaceIcon == nil ? .center : .leading
        let titleStack = VStack(alignment: textAlignment, spacing: 1) {
            Text(data.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 4) {
                if data.showsStatus {
                    Circle()
                        .fill(data.subtitleColor)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
                Text(data.subtitle)
                    .font(data.subtitleFont)
                    .monospacedDigit()
                    .foregroundStyle(data.subtitleColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .multilineTextAlignment(data.workspaceIcon == nil ? .center : .leading)

        return Group {
            if let workspaceIcon = data.workspaceIcon {
                HStack(spacing: PhoneSessionFloatingCapsuleMetrics.iconTitleSpacing) {
                    WorkspaceProjectIconTile(
                        content: workspaceIcon,
                        size: PhoneSessionFloatingCapsuleMetrics.workspaceIconSize,
                        tokens: tokens
                    )
                    .fixedSize()
                    titleStack
                }
            } else {
                titleStack
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(data.title)
        .accessibilityValue(data.accessibilityValue)
        .accessibilityIdentifier("sessionDetail.title")
    }
}

/// 隐藏系统导航栏后，确保 `NavigationStack` 底层 `UINavigationController` 仍保持左缘右滑返回手势可用。
struct NavigationInteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.attachIfPossible()
    }

    static func dismantleUIViewController(_ uiViewController: Controller, coordinator: ()) {
        uiViewController.restoreIfNeeded()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var observedNavigationController: UINavigationController?
        private weak var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var didOverrideDelegate = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attachIfPossible()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restoreIfNeeded()
        }

        func attachIfPossible() {
            guard let nav = navigationController,
                  let gesture = nav.interactivePopGestureRecognizer else {
                return
            }
            if observedNavigationController !== nav {
                restoreIfNeeded()
                observedNavigationController = nav
                previousDelegate = gesture.delegate
                didOverrideDelegate = true
            }
            gesture.delegate = self
            gesture.isEnabled = nav.viewControllers.count > 1
        }

        func restoreIfNeeded() {
            guard didOverrideDelegate,
                  let nav = observedNavigationController,
                  let gesture = nav.interactivePopGestureRecognizer else {
                return
            }
            if gesture.delegate === self {
                gesture.delegate = previousDelegate
            }
            didOverrideDelegate = false
            observedNavigationController = nil
            previousDelegate = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav = observedNavigationController else { return false }
            return nav.viewControllers.count > 1
        }
    }
}

extension UnifiedWorkbenchShell {
    /// 外接键盘快捷键（#828）：⌘O / ⌘F 跳转，⌘1～9 侧栏前 9 条，⌘N 新建，⌘. 停止，⌘[ / ⌘] 前后会话。
    func keyboardCommandActions(layout: WorkbenchLayout) -> WorkbenchCommandActions {
        let sidebarShortcuts = sidebarMonitorSections(now: Date())
            .flatMap(\.sessions)
            .prefix(9)
            .map { WorkbenchCommandActions.SidebarShortcut(id: $0.id, title: $0.title) }
        let visibleID = navigationState.visibleSessionID(usesCompactNavigation: layout.usesCompactNavigation)
        let canStop = sessionStore.selectedSession.map { session in
            session.id == visibleID && session.isRunning && session.activeTurnID != nil
                && sessionStore.canControlSession(session)
        } ?? false
        let stopCurrentReply: (() -> Void)? = canStop ? { sessionStore.interruptSelectedTurn() } : nil
        return WorkbenchCommandActions(
            sidebarShortcuts: Array(sidebarShortcuts),
            openJumpPanel: { isSessionJumpPanelPresented = true },
            openSession: { open(.session($0), source: .sessions, layout: layout) },
            newSession: { presentSheet(.newSession) },
            stopCurrentReply: stopCurrentReply,
            goBack: sessionHistory.canGoBack ? { stepSessionHistory(back: true, layout: layout) } : nil,
            goForward: sessionHistory.canGoForward ? { stepSessionHistory(back: false, layout: layout) } : nil
        )
    }

    private func stepSessionHistory(back: Bool, layout: WorkbenchLayout) {
        var history = sessionHistory
        // 已归档的会话仍留在 sessions 里，只是从列表投影中隐藏；前后切换要一起跳过。
        let isAvailable: (SessionID) -> Bool = { id in
            !sessionStore.archivedSessionIDs.contains(id) && sessionStore.sessions.contains { $0.id == id }
        }
        let target = back ? history.goBack(isAvailable: isAvailable) : history.goForward(isAvailable: isAvailable)
        sessionHistory = history
        if let target {
            open(.session(target), source: .sessions, layout: layout)
        }
    }

    func applyNavigation(
        _ event: WorkbenchNavigationEvent,
        layout: WorkbenchLayout,
        preferredSession: AgentSession? = nil,
        origin: WorkbenchNavigationOrigin = .user
    ) {
        let commit = makeNavigationCommit(event, layout: layout, origin: origin)
        commitVisualNavigation(commit)
        commitNavigationSideEffects(
            commit,
            layout: layout,
            preferredSession: preferredSession
        )
    }

    /// TabView / NavigationStack 的 selection/path 必须在 Binding setter 所在事务内更新，
    /// 否则系统高亮或返回手势会先走一帧，内容下一轮才跳到目标页。外部副作用继续延后，
    /// 并以完整导航快照校验，避免快速连点或恢复事件执行已经过期的网络操作。
    func applyInteractiveNavigation(
        _ event: WorkbenchNavigationEvent,
        lane: WorkbenchNavigationBindingScheduler.Lane,
        layout: WorkbenchLayout
    ) {
        navigationBindingScheduler.commit(
            on: lane,
            visualUpdate: {
                let commit = makeNavigationCommit(event, layout: layout)
                commitVisualNavigation(commit)
                return commit
            },
            deferredSideEffect: { commit in
                guard navigationState == commit.state else { return }
                commitNavigationSideEffects(commit, layout: layout)
            }
        )
    }

    private func makeNavigationCommit(
        _ event: WorkbenchNavigationEvent,
        layout: WorkbenchLayout,
        origin: WorkbenchNavigationOrigin = .user
    ) -> WorkbenchNavigationCommit {
        var nextState = navigationState
        let effect = nextState.reduce(
            event,
            usesCompactNavigation: layout.usesCompactNavigation,
            selectedSessionID: sessionStore.selectedSessionID,
            usesPhoneIntegratedBottomChrome: layout.usesPhoneIntegratedBottomChrome
        )
        // 忽略 SwiftUI 对相同 path/tab 的回写；真实交互在视觉事务内撤销旧通知。
        if nextState != navigationState || effect != nil {
            sessionStore.notificationNavigation.observe(event, origin: origin)
        }
        return WorkbenchNavigationCommit(state: nextState, effect: effect)
    }

    private func commitVisualNavigation(_ commit: WorkbenchNavigationCommit) {
        // 一个事件只提交一个本地导航状态，避免 NavigationStack 在同一帧接收多次 path 写入。
        if commit.state != navigationState {
            navigationState = commit.state
        }
    }

    private func commitNavigationSideEffects(
        _ commit: WorkbenchNavigationCommit,
        layout: WorkbenchLayout,
        preferredSession: AgentSession? = nil
    ) {
        if restorationRoute != commit.state.route {
            restorationRoute = commit.state.route
        }
        if layout.usesPhoneIntegratedBottomChrome {
            let tabRawValue = commit.state.compactSelectedTab.rawValue
            if storedCompactSelectedTabRawValue != tabRawValue {
                storedCompactSelectedTabRawValue = tabRawValue
            }
        }

        switch commit.effect {
        case .returnToSessionList:
            sessionStore.returnToSessionList()
        case .selectSession(let sessionID):
            let session = preferredSession?.id == sessionID
                ? preferredSession
                : sessionStore.openedWorkspaceSessionLibrarySessions.first(where: { $0.id == sessionID })
            guard let session else {
                applyNavigation(.sessionSelectionFinished(sessionID), layout: layout)
                return
            }
            Task {
                await sessionStore.selectSession(session)
                applyNavigation(.sessionSelectionFinished(sessionID), layout: layout)
            }
        case nil:
            break
        }
    }

    @ToolbarContentBuilder
    func inspectorToolbarItem(
        layout: WorkbenchLayout,
        tokens: ThemeTokens
    ) -> some ToolbarContent {
        if layout.usesSheetInspectorNavigation, #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) {
                inspectorToolbarButton(
                    layout: layout,
                    tokens: tokens,
                    source: .sessionToolbarInspector
                )
            }
            // 只有中等宽度的独立按钮是稳定锚点；attached Inspector 不参与 Sheet zoom。
            .matchedTransitionSource(
                id: InspectorPresentationSource
                    .sessionToolbarInspector
                    .transitionSourceID,
                in: presentationNamespace
            )
            // 按钮自带磨砂圆，系统共享玻璃必须关掉，否则是两层背景。
            .sharedBackgroundVisibility(.hidden)
        } else {
            // iOS 18–25 仍可打开 Inspector，只取消依赖新 Toolbar API 的 zoom 来源。
            workbenchChromeToolbarItem(placement: .topBarTrailing) {
                inspectorToolbarButton(
                    layout: layout,
                    tokens: tokens,
                    source: nil
                )
            }
        }
    }

    private func inspectorToolbarButton(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        source: InspectorPresentationSource?
    ) -> some View {
        workbenchToolbarIconButton(
            systemImage: "sidebar.right",
            accessibilityLabel: showingInspector
                ? L10n.text("ui.hide_details")
                : L10n.text("ui.show_details"),
            tokens: tokens,
            isActive: showingInspector
        ) {
            toggleInspector(layout: layout, source: source)
        }
        .accessibilityIdentifier("sessionDetail.inspector")
    }

    /// 顶栏图标按钮的统一形态：44pt 扁平磨砂圆，和工作区胶囊、侧栏控件同一档材质。
    /// 调用方必须把它放进 `workbenchChromeToolbarItem`（或自行 `sharedBackgroundVisibility(.hidden)`），
    /// 否则 iOS 26 的系统玻璃底板会叠在这层磨砂下面。
    func workbenchToolbarIconButton(
        systemImage: String,
        accessibilityLabel: String,
        tokens: ThemeTokens,
        isActive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // 磨砂圆只作为背景，不参与布局；外层 ToolbarItem 负责关掉
            // iOS 26 自动附加的系统玻璃底板。
            WorkbenchChromeIcon(systemName: systemImage)
                .workbenchToolbarChromeCircle(tokens: tokens)
        }
        .foregroundStyle(isActive ? tokens.tint(for: .active) : tokens.secondaryText)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    func sessionNavigationTitleDisplayData(
        session: AgentSession?,
        usesSelectedSessionState: Bool,
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        now: Date
    ) -> SessionNavigationTitleDisplayData {
        let showsStatus = usesSelectedSessionState && selectedSessionShowsNavigationStatus
        let subtitle = usesSelectedSessionState
            ? sessionTitleSubtitle(now: now)
            : SessionNavigationTitlePresentation.pendingSubtitle(session: session)
        let subtitleColor = usesSelectedSessionState
            ? sessionTitleSubtitleColor(tokens: tokens, now: now)
            : tokens.secondaryText
        let workspaceIcon: WorkspaceProjectIconContent? = {
            guard SessionNavigationTitlePresentation.showsWorkspaceIcon(
                layout: layout,
                projectID: session?.projectID
            ),
            let projectID = session?.projectID.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }
            return workspaceAppearanceStore.projectIconContent(
                profileID: appStore.activeHostScope.profileID,
                projectID: projectID
            )
        }()
        return SessionNavigationTitleDisplayData(
            title: session?.title ?? L10n.text("ui.session"),
            subtitle: subtitle,
            showsStatus: showsStatus,
            subtitleColor: subtitleColor,
            subtitleFont: SessionNavigationTitlePresentation.subtitleFont(
                layout: layout,
                themeStore: themeStore
            ),
            accessibilityValue: usesSelectedSessionState ? sessionTitleAccessibilityValue(now: now) : subtitle,
            workspaceIcon: workspaceIcon
        )
    }

    func sessionDetailNavigationTitle(
        session: AgentSession?,
        usesSelectedSessionState: Bool,
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        now: Date
    ) -> some View {
        let data = sessionNavigationTitleDisplayData(
            session: session,
            usesSelectedSessionState: usesSelectedSessionState,
            layout: layout,
            tokens: tokens,
            now: now
        )
        let textAlignment: HorizontalAlignment = data.workspaceIcon == nil ? .center : .leading
        let titleStack = VStack(alignment: textAlignment, spacing: 1) {
            // 标题只保留一行当前任务；普通状态收进固定副标题槽，
            // 避免 running / idle 切换时把整条时间线向下推。
            Text(data.title)
                .font(.headline)
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 5) {
                if data.showsStatus {
                    Circle()
                        .fill(data.subtitleColor)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
                Text(data.subtitle)
                    .font(data.subtitleFont)
                    .foregroundStyle(data.subtitleColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .multilineTextAlignment(data.workspaceIcon == nil ? .center : .leading)

        return Group {
            if let workspaceIcon = data.workspaceIcon {
                HStack(spacing: 7) {
                    WorkspaceProjectIconTile(content: workspaceIcon, size: 22, tokens: tokens)
                    titleStack
                }
                .frame(maxWidth: layout.titleMaxWidth)
            } else {
                titleStack
                    .frame(width: layout.titleMaxWidth)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(data.title)
        .accessibilityValue(data.accessibilityValue)
        .accessibilityIdentifier("sessionDetail.title")
    }

    private func sessionTitleSubtitle(now: Date) -> String {
        guard let session = sessionStore.selectedSession else {
            return L10n.text("ui.session")
        }

        if selectedSessionShowsNavigationStatus {
            let status = session.displayStatus(foregroundActivity: sessionStore.selectedForegroundActivity)
            if let snapshot = sessionStore.selectedRuntimeActivitySnapshot {
                let elapsed = RuntimeActivityDisplay.compactClockDuration(
                    now.timeIntervalSince(snapshot.turnStartedAt)
                )
                return "\(status.title) · \(elapsed)"
            }
            return status.title
        }

        let project = session.project.trimmingCharacters(in: .whitespacesAndNewlines)
        return project.isEmpty ? session.displayStatus(foregroundActivity: sessionStore.selectedForegroundActivity).title : project
    }

    private func sessionTitleAccessibilityValue(now: Date) -> String {
        guard let session = sessionStore.selectedSession else {
            return L10n.text("ui.session")
        }
        guard selectedSessionShowsNavigationStatus else {
            return sessionTitleSubtitle(now: now)
        }

        let status = session.displayStatus(foregroundActivity: sessionStore.selectedForegroundActivity)
        if let runtimeDisplay = RuntimeActivityDisplay.make(
            snapshot: sessionStore.selectedRuntimeActivitySnapshot,
            webSocketStatus: sessionStore.webSocketStatus,
            now: now
        ) {
            // 视觉副标题只留状态和时长；连接诊断仍完整提供给 VoiceOver。
            return "\(status.title) · \(runtimeDisplay.detailText)"
        }
        return status.title
    }

    private var selectedSessionShowsNavigationStatus: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return session.isRunning ||
            sessionStore.selectedForegroundActivity != nil ||
            session.pendingApproval != nil ||
            session.status == SessionStatus.failed.rawValue ||
            session.status == SessionStatus.waitingForInput.rawValue ||
            session.status == SessionStatus.waitingForApproval.rawValue
    }

    private func sessionTitleSubtitleColor(tokens: ThemeTokens, now: Date) -> Color {
        guard selectedSessionShowsNavigationStatus else {
            return tokens.tertiaryText
        }
        if let runtimeDisplay = RuntimeActivityDisplay.make(
            snapshot: sessionStore.selectedRuntimeActivitySnapshot,
            webSocketStatus: sessionStore.webSocketStatus,
            now: now
        ) {
            return tokens.tint(for: runtimeDisplay.tone)
        }
        return selectedSessionStatusColor(tokens: tokens)
    }

    private func selectedSessionStatusColor(tokens: ThemeTokens) -> Color {
        guard let session = sessionStore.selectedSession else {
            return tokens.tertiaryText
        }
        switch session.displayStatus(foregroundActivity: sessionStore.selectedForegroundActivity).tone {
        case .active:
            return tokens.tint(for: .active)
        case .warning:
            return tokens.warning
        case .danger:
            return .red
        case .complete:
            return tokens.success
        case .neutral:
            return tokens.tertiaryText
        }
    }

}
