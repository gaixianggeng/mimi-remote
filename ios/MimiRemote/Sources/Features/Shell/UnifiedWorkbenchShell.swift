import SwiftUI

/// iPad 和 iPhone 共用同一套路由；宽屏使用侧栏，窄屏使用真正的 push 导航。
/// 不能只依赖 NavigationSplitView 自动折叠：折叠后的详情列没有返回栈，也就没有系统左缘返回手势。
struct UnifiedWorkbenchShell: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var workspaceAppearanceStore: WorkspaceAppearanceStore
    @EnvironmentObject private var notificationResponseAdapter: SessionNotificationResponseAdapter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var presentationNamespace

    @Binding var showingInspector: Bool
    @Binding var restorationRoute: WorkbenchRestorationRoute
    @State private var navigationState = WorkbenchNavigationState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @SceneStorage("workbench.floatingSidebarVisible") private var storedFloatingSidebarVisible = true
    @State private var floatingSidebarPresentation = FloatingSidebarPresentationState()
    @State private var floatingSidebarRenderedProgress = FloatingSidebarRenderedProgressTracker(
        initialValue: FloatingSidebarVisibility.open.progress
    )
    @State private var didRestoreFloatingSidebarVisibility = false
    @State private var sheetPresentationState = WorkbenchSheetPresentationState()
    @State private var inspectorPresentationState = InspectorPresentationState()
    @State private var sessionActionPresentation: SessionActionPresentation?
    @State private var notificationVisibilitySceneID = UUID()
    @State private var navigationBindingScheduler = WorkbenchNavigationBindingScheduler()
    @StateObject private var sidebarHighlightCoordinator = SessionSidebarHighlightCoordinator()
    @State private var didApplyDebugLaunchRoute = false
    @State private var selectedRelatedSubagent: SessionContextSubagent?
    @State private var relatedSubagentParentID: SessionID?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        GeometryReader { proxy in
            let interfaceIdiom = UIDevice.current.userInterfaceIdiom
            let layout = WorkbenchLayout(
                containerWidth: proxy.size.width,
                horizontalSizeClass: horizontalSizeClass,
                isPad: interfaceIdiom == .pad,
                isPhone: interfaceIdiom == .phone
            )

            Group {
                if layout.usesCompactNavigation {
                    compactLayout(
                        layout: layout,
                        tokens: tokens,
                        bottomSafeAreaInset: proxy.safeAreaInsets.bottom
                    )
                } else if layout.usesFloatingSidebarSurface {
                    floatingLayout(
                        layout: layout,
                        tokens: tokens,
                        bottomSafeAreaInset: proxy.safeAreaInsets.bottom
                    )
                } else {
                    splitLayout(
                        layout: layout,
                        tokens: tokens,
                        bottomSafeAreaInset: proxy.safeAreaInsets.bottom
                    )
                }
            }
            .sheet(
                item: sheetPresentationBinding,
                onDismiss: dismissSheet
            ) { presentation in
                switch presentation.destination {
                case .newSession:
                    newSessionSheet(
                        presentation: presentation,
                        layout: layout
                    )
                case .settings:
                    SettingsView(isInitialSetup: false)
                }
            }
            .onAppear {
                restoreFloatingSidebarVisibilityIfNeeded()
                synchronizeNavigation(for: layout)
                applyDebugLaunchRouteIfNeeded(layout: layout)
                synchronizeSidebarLifecycle()
            }
            .onChange(of: sidebarLifecycleObservations) { _, _ in
                synchronizeSidebarLifecycle()
            }
            .onChange(of: appStore.activeHostScope.profileID) { _, _ in
                synchronizeSidebarLifecycle()
            }
            .onChange(of: layout.usesCompactNavigation) { _, usesCompactNavigation in
                handleLayoutModeChange(
                    usesCompactNavigation: usesCompactNavigation,
                    layout: layout
                )
            }
            .onChange(of: layout.usesAttachedInspector) { _, _ in
                handleRelatedPresentationChange(layout: layout)
            }
            .onChange(of: layout.usesFloatingSidebarSurface) { _, usesFloatingSidebarSurface in
                handleFloatingSidebarLayoutModeChange(
                    usesFloatingSidebarSurface: usesFloatingSidebarSurface
                )
            }
            .onChange(of: sessionStore.lastSelectionCommit) { _, commit in
                guard let commit else { return }
                handleSelectionCommit(commit, layout: layout)
            }
            .onChange(of: restorationRoute) { _, route in
                guard navigationState.route != route else { return }
                applyNavigation(.synchronize(route), layout: layout)
            }
            .onAppear {
                updateVisibleSessionNotificationRoute(
                    visibleSessionNotificationRoute(layout: layout)
                )
            }
            .onChange(of: visibleSessionNotificationRoute(layout: layout)) { _, route in
                updateVisibleSessionNotificationRoute(route)
            }
            .onDisappear {
                updateVisibleSessionNotificationRoute(nil)
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            if appStore.requiresRePairing {
                credentialsInvalidBanner(tokens: tokens)
            } else if sessionStore.isNetworkUnavailable {
                networkUnavailableBanner(tokens: tokens)
            }
        }
    }

    private var sheetPresentationBinding: Binding<WorkbenchSheetPresentation?> {
        Binding(
            get: { sheetPresentationState.presentation },
            set: { sheetPresentationState.replace(with: $0) }
        )
    }

    private func presentSheet(
        _ destination: WorkbenchSheetDestination,
        source: NewSessionPresentationSource? = nil
    ) {
        sheetPresentationState.present(
            destination,
            source: source,
            reduceMotion: reduceMotion
        )
    }

    private func dismissSheet() {
        // 关闭后必须清空来源，下一次键盘、恢复或程序化展示才能安全走 fallback。
        sheetPresentationState.dismiss()
    }

    @ViewBuilder
    private func newSessionSheet(
        presentation: WorkbenchSheetPresentation,
        layout: WorkbenchLayout
    ) -> some View {
        let sheet = NewSessionSheet(
            onCreated: { sessionID in
                open(.session(sessionID), layout: layout)
            },
            onOpenWorkspaces: {
                open(.workspaces, layout: layout)
            }
        )

        switch presentation.transition {
        case .systemSheet:
            sheet
        case .zoom(let sourceID):
            sheet.navigationTransition(
                .zoom(sourceID: sourceID, in: presentationNamespace)
            )
        }
    }

    private func visibleSessionNotificationRoute(
        layout: WorkbenchLayout
    ) -> SessionNotificationRoute? {
        guard scenePhase == .active,
              sheetPresentationState.presentation == nil,
              !(showingInspector && !layout.usesAttachedInspector),
              let visibleSessionID = navigationState.visibleSessionID(
                  usesCompactNavigation: layout.usesCompactNavigation
              ),
              let session = sessionStore.sessionsByID[visibleSessionID]
        else {
            return nil
        }
        return SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: session.projectID,
            sessionID: session.id
        )
    }

    private func updateVisibleSessionNotificationRoute(_ route: SessionNotificationRoute?) {
        notificationResponseAdapter.setVisibleSessionRoute(
            route,
            for: notificationVisibilitySceneID
        )
    }

    private func compactLayout(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
        let isIOS26OrLater: Bool
        if #available(iOS 26.0, *) {
            isIOS26OrLater = true
        } else {
            isIOS26OrLater = false
        }
        let hasBottomTabBar = WorkbenchPageLayout.hasBottomTabBar(
            isPhone: layout.isPhone,
            isHorizontallyCompact: horizontalSizeClass == .compact,
            isIOS26OrLater: isIOS26OrLater
        )
        // iPadOS 18 起 regular-width iPad 已把 Tab 栏放在顶部；18–25 只有 compact-width
        // iPad 仍回到底部，26 起两种 iPad 宽度都在顶部。iPhone 始终保留底部 Tab 栏。
        // 仍按底部 Tab 栏预留 118pt，会在列表底部留下一整块空气，
        // 也会把右下角浮起的新建按钮顶离屏幕边缘、看起来既不贴边又压住内容。
        let bottomChromeClearance = hasBottomTabBar
            ? WorkbenchPageLayout.compactBottomChromeClearance(
                bottomSafeAreaInset: bottomSafeAreaInset
            )
            : max(bottomSafeAreaInset, WorkbenchPageLayout.regularPadding)
        // 搜索激活时系统会收起 Tab 胶囊和顶栏按钮，把搜索框铺满整条导航栏。
        // 这枚设备入口是 TabView 上的浮层、不归导航栏管，不一起收起就会被搜索框压住。
        let showsTabletHostSwitcher = !layout.isPhone
            && !sessionStore.isSessionSearchPresented
            && (
                navigationState.compactSelectedTab == .sessions
                    ? navigationState.compactSessionPath.isEmpty
                    : navigationState.compactSelectedTab == .workspaces
                        && navigationState.compactWorkspacePath.isEmpty
            )

        return TabView(selection: compactTabBinding(layout: layout)) {
            NavigationStack(path: compactPathBinding(for: .sessions, layout: layout)) {
                sessionList(
                    layout: layout,
                    bottomContentMargin: bottomChromeClearance
                )
                    .navigationDestination(for: AppDestination.self) { destination in
                        compactDestination(destination, layout: layout, tokens: tokens)
                    }
            }
            .tabItem {
                Label(CompactWorkbenchTab.sessions.title, systemImage: CompactWorkbenchTab.sessions.systemImage)
                    .accessibilityIdentifier("compactTab.sessions")
            }
            .tag(CompactWorkbenchTab.sessions)

            NavigationStack(path: compactPathBinding(for: .workspaces, layout: layout)) {
                workspaces(layout: layout)
                    .navigationDestination(for: AppDestination.self) { destination in
                        compactDestination(destination, layout: layout, tokens: tokens)
                    }
            }
            .tabItem {
                Label(CompactWorkbenchTab.workspaces.title, systemImage: CompactWorkbenchTab.workspaces.systemImage)
                    .accessibilityIdentifier("compactTab.workspaces")
            }
            .tag(CompactWorkbenchTab.workspaces)

            NavigationStack {
                SettingsView(
                    isInitialSetup: false,
                    showsDoneButton: false,
                    embedsNavigationStack: false
                )
            }
            .tabItem {
                Label(CompactWorkbenchTab.me.title, systemImage: CompactWorkbenchTab.me.systemImage)
                    .accessibilityIdentifier("compactTab.me")
            }
            .tag(CompactWorkbenchTab.me)
        }
        .overlay(alignment: .topLeading) {
            if showsTabletHostSwitcher {
                compactTabletHostSwitcher(layout: layout, tokens: tokens)
                    .padding(.leading, 10)
                    // 与 Tab 胶囊、顶栏「···」「+」共用同一条中心线（实测 y≈53.5pt）。
                    // TabView overlay 的原点比那条线高，这里补回来；数值随
                    // workbenchToolbarChromeCircle 的 40pt 直径一起标定。
                    .offset(y: WorkbenchChromeIconMetrics.compactHostSwitcherCenterOffset)
            }
        }
        // 原生 Tab 保留系统交互；材质按系统版本交给 Chrome 层，页面只负责保持背景连续。
        .compactTabBarChrome(tokens: tokens, reduceTransparency: reduceTransparency)
        .environment(\.workbenchBottomChromeClearance, bottomChromeClearance)
        .environment(\.workbenchHasCompactTabBar, true)
        // 页面按系统 Tab 栏的实际位置决定右下角能不能放浮起按钮。
        .environment(\.workbenchHasBottomTabBar, hasBottomTabBar)
        .themedWorkbenchNavigationChrome(
            tokens: tokens,
            colorScheme: themeStore.resolvedColorScheme(for: colorScheme)
        )
    }

    /// TabView 上的自由浮层。命中区域保持 44pt，但磨砂圆按顶栏那档画成 40pt——
    /// 它和导航栏里的「···」「+」在同一条视线上，直径不一致会立刻被看出来。
    private func compactTabletHostSwitcher(
        layout: WorkbenchLayout,
        tokens: ThemeTokens
    ) -> some View {
        HostSwitcherMenu(
            presentation: .toolbar,
            manageConnections: { openConnectionSettings(layout: layout) }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                // 设备入口移到 Shell 后仍需保持会话页原有的收键盘行为。
                dismissSessionSearchKeyboard()
            }
        )
        .frame(
            width: WorkbenchChromeIconMetrics.minimumHitTarget,
            height: WorkbenchChromeIconMetrics.minimumHitTarget
        )
        .contentShape(Circle())
        .workbenchToolbarChromeCircle(tokens: tokens)
    }

    private func dismissSessionSearchKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func splitLayout(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar(tokens: tokens, layout: layout, bottomSafeAreaInset: bottomSafeAreaInset)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
        } detail: {
            detail(layout: layout, tokens: tokens)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func floatingLayout(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
        let sidebarWidth = WorkbenchSidebarSurfaceMetrics.overlayWidth
        let renderTargetProgress = didRestoreFloatingSidebarVisibility
            ? floatingSidebarPresentation.renderTargetProgress
            : (storedFloatingSidebarVisible ? 1 : 0)
        let keepsOpenSurfaceInteractive = didRestoreFloatingSidebarVisibility
            ? floatingSidebarPresentation.keepsOpenSurfaceInteractive
            : storedFloatingSidebarVisible
        let showsClosedControls = didRestoreFloatingSidebarVisibility
            ? floatingSidebarPresentation.isIdleClosed
            : !storedFloatingSidebarVisible
        let keepsClosedEdgeInteractive = didRestoreFloatingSidebarVisibility
            ? floatingSidebarPresentation.keepsClosedEdgeInteractive
            : !storedFloatingSidebarVisible
        let reservesWorkspaceBackButton = navigationState.showsWorkspaceBackButton(
            usesCompactNavigation: layout.usesCompactNavigation
        )

        return FloatingSidebarAnimatedScene(sidebarWidth: sidebarWidth) {
            // detail 与 sidebar 从同一个 animatableData 排版，避免目标状态与屏幕位置分裂。
            detail(layout: layout, tokens: tokens)
        } sidebar: {
            sidebar(
                tokens: tokens,
                layout: layout,
                bottomSafeAreaInset: bottomSafeAreaInset
            )
            .disabled(!keepsOpenSurfaceInteractive)
            .accessibilityHidden(!keepsOpenSurfaceInteractive)
            .overlay(alignment: .trailing) {
                if keepsOpenSurfaceInteractive {
                    // recognizer 真正只安装在空白拖动带；row 与按钮不进入命中树。
                    Rectangle()
                        // Color.clear 在部分 SwiftUI 层级会被省略，极低 alpha 保留真实命中表面且不可见。
                        .fill(Color.primary.opacity(0.001))
                        .frame(width: WorkbenchSidebarSurfaceMetrics.openDragStripWidth)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .allowsHitTesting(true)
                        .simultaneousGesture(floatingSidebarDragGesture())
                        .accessibilityHidden(true)
                        // padding 必须位于 gesture 外层，确保顶部/底部与浮层外边距不进入命中区。
                        .padding(
                            .vertical,
                            WorkbenchSidebarSurfaceMetrics.openDragStripVerticalInset
                        )
                        .padding(.trailing, WorkbenchSidebarSurfaceMetrics.outerInset)
                }
            }
        }
        .modifier(
            FloatingSidebarProgressModifier(
                progress: renderTargetProgress,
                tracker: floatingSidebarRenderedProgress
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // gutter、主列表与会话画布共用宽屏基底，任何两块相邻面之间都不留同亮度色差。
        .background(tokens.workbenchCanvasBackground.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            if showsClosedControls {
                WorkbenchFloatingSidebarRevealButton(tokens: tokens) {
                    toggleFloatingSidebarVisibility()
                }
                .padding(.leading, WorkbenchSidebarSurfaceMetrics.outerInset)
                // 工作区会话详情已有 leading 返回按钮；侧栏关闭时把恢复入口放到导航栏下方。
                // 只横向移动仍会落在 NavigationBar 的命中表面内，视觉分开但按钮不可点击。
                .padding(
                    .top,
                    6 + (reservesWorkspaceBackButton
                        ? WorkbenchChromeIconMetrics.minimumHitTarget + 12
                        : 0)
                )
                .accessibilitySortPriority(10)
            }
        }
        .overlay(alignment: .topLeading) {
            if keepsClosedEdgeInteractive {
                GeometryReader { proxy in
                    let hitFrame = FloatingSidebarGestureHitRegion.closedEdgeFrame(
                        containerSize: proxy.size,
                        edgeWidth: WorkbenchSidebarSurfaceMetrics.closedEdgeDragWidth,
                        verticalInset: WorkbenchSidebarSurfaceMetrics.closedEdgeDragVerticalInset
                    )

                    if !hitFrame.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            // 用真实布局占出顶部保护区，不依赖 offset 的命中变换语义。
                            Spacer()
                                .frame(height: hitFrame.minY)
                                .allowsHitTesting(false)
                            Rectangle()
                                .fill(Color.primary.opacity(0.001))
                                // 只让 Rectangle 命中；GeometryReader 与上下 Spacer 都没有 recognizer。
                                .frame(width: hitFrame.width, height: hitFrame.height)
                                .contentShape(Rectangle())
                                .allowsHitTesting(true)
                                .simultaneousGesture(floatingSidebarDragGesture())
                                .accessibilityHidden(true)
                            Spacer(minLength: 0)
                                .allowsHitTesting(false)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private func toggleFloatingSidebarVisibility() {
        let currentVisibility: FloatingSidebarVisibility
        if didRestoreFloatingSidebarVisibility {
            currentVisibility = floatingSidebarPresentation.committedVisibility
        } else {
            currentVisibility = storedFloatingSidebarVisible ? .open : .closed
        }
        settleFloatingSidebar(
            to: currentVisibility.toggled,
            progressVelocity: 0
        )
    }

    private func floatingSidebarDragGesture() -> some Gesture {
        DragGesture(
            minimumDistance: FloatingSidebarGestureArbitration.minimumDistance,
            // 拖动带会跟随侧栏移动；全局坐标避免局部原点位移污染 translation 与投影。
            coordinateSpace: .global
        )
        .onChanged { value in
            let axis = floatingSidebarPresentation.resolveGestureAxis(
                translation: value.translation
            )
            guard axis == .horizontal else { return }

            if !floatingSidebarPresentation.isInteracting {
                // 顺序不可改变：先读取真实 animatableData，再 fencing 旧动画并进入 interaction。
                let renderedProgress = floatingSidebarRenderedProgress.value
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    floatingSidebarPresentation.beginInteraction(
                        renderedProgress: renderedProgress,
                        consumedHysteresisTranslation: FloatingSidebarGestureArbitration
                            .consumedHysteresisTranslation(for: value.translation.width)
                    )
                }
                MimiHaptics.prepare(.snap)
            }

            var transaction = Transaction()
            transaction.animation = nil
            _ = withTransaction(transaction) {
                floatingSidebarPresentation.updateInteraction(
                    translation: value.translation.width,
                    sidebarWidth: WorkbenchSidebarSurfaceMetrics.overlayWidth
                )
            }
        }
        .onEnded { value in
            guard floatingSidebarPresentation.gestureAxis == .horizontal,
                  let decision = floatingSidebarPresentation.releaseDecision(
                      translation: value.translation.width,
                      predictedEndTranslation: value.predictedEndTranslation.width,
                      velocity: value.velocity.width,
                      sidebarWidth: WorkbenchSidebarSurfaceMetrics.overlayWidth
                  ) else {
                floatingSidebarPresentation.resetGesture()
                return
            }

            settleFloatingSidebar(
                to: decision.target,
                progressVelocity: decision.progressVelocity
            )
        }
    }

    private func settleFloatingSidebar(
        to target: FloatingSidebarVisibility,
        progressVelocity: CGFloat
    ) {
        // 必须先读取屏幕当前插值，再递增 revision/进入 settling；否则会用目标值归一化速度。
        let currentPresentationProgress = floatingSidebarRenderedProgress.value
        let springInitialVelocity = reduceMotion
            ? 0
            : FloatingSidebarProjection.springInitialVelocity(
                progressVelocity: progressVelocity,
                currentPresentationProgress: currentPresentationProgress,
                targetProgress: target.progress
            )
        let settling = floatingSidebarPresentation.prepareSettling(
            target: target,
            springInitialVelocity: springInitialVelocity
        )
        storedFloatingSidebarVisible = target == .open

        withAnimation(
            MimiMotion.gestureSettling.animation(
                reduceMotion: reduceMotion,
                initialVelocity: settling.springInitialVelocity
            ),
            completionCriteria: .logicallyComplete
        ) {
            floatingSidebarPresentation.startSettling(settling)
        } completion: {
            guard floatingSidebarPresentation.completeSettling(
                revision: settling.revision
            ) else {
                return
            }
            floatingSidebarRenderedProgress.record(settling.target.progress)
            MimiHaptics.fire(.snap)
        }
    }

    private func restoreFloatingSidebarVisibilityIfNeeded() {
        guard !didRestoreFloatingSidebarVisibility else { return }
        didRestoreFloatingSidebarVisibility = true
        let visibility: FloatingSidebarVisibility = storedFloatingSidebarVisible
            ? .open
            : .closed
        floatingSidebarPresentation.restore(visibility)
        floatingSidebarRenderedProgress.record(visibility.progress)
    }

    private func handleFloatingSidebarLayoutModeChange(
        usesFloatingSidebarSurface: Bool
    ) {
        guard didRestoreFloatingSidebarVisibility,
              !usesFloatingSidebarSurface else {
            return
        }

        // 离开浮动布局时取消在途动画但保留 committed 语义；返回宽布局从同一状态恢复。
        let visibility = floatingSidebarPresentation.committedVisibility
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            floatingSidebarPresentation.restore(visibility)
        }
        floatingSidebarRenderedProgress.record(visibility.progress)
    }

    private func openConnectionSettings(layout: WorkbenchLayout) {
        open(.me, layout: layout)
    }

    private func credentialsInvalidBanner(tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tokens.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("ui.access_code_has_expired"))
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(L10n.text("ui.automatic_retries_stopped_existing_sessions_remain_please_rescan"))
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
            }

            Spacer(minLength: 8)

            Button(L10n.text("ui.re_pair")) {
                presentSheet(.settings)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("connection.repairPairing")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tokens.elevatedSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)
        }
    }

    private func networkUnavailableBanner(tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tokens.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("ui.network_is_unavailable"))
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(L10n.text("ui.synchronization_and_reconnection_have_been_paused_it_will"))
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tokens.elevatedSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)
        }
        .accessibilityIdentifier("connection.networkUnavailable")
    }

    private func sidebar(
        tokens: ThemeTokens,
        layout: WorkbenchLayout,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
        WorkbenchSidebarContainer(
            tokens: tokens,
            usesFloatingSurface: layout.usesFloatingSidebarSurface
        ) {
            sidebarContent(
                tokens: tokens,
                layout: layout,
                bottomSafeAreaInset: layout.usesFloatingSidebarSurface
                    ? 0
                    : bottomSafeAreaInset
            )
        } floatingHeader: {
            WorkbenchFloatingSidebarHeader(
                tokens: tokens,
                onCollapse: {
                    if layout.usesFloatingSidebarSurface {
                        toggleFloatingSidebarVisibility()
                    } else {
                        columnVisibility = .detailOnly
                    }
                }
            ) {
                sidebarBrandHeader(
                    tokens: tokens,
                    layout: layout,
                    constrainedWidth: nil,
                    usesFloatingChrome: true
                )
            }
        } toolbarHeader: {
            sidebarBrandHeader(tokens: tokens, layout: layout)
        }
        .task {
            await sessionStore.refreshSessionLibraryIndex()
        }
    }

    private func sidebarContent(tokens: ThemeTokens, layout: WorkbenchLayout, bottomSafeAreaInset: CGFloat) -> some View {
        WorkbenchSidebarContentLayout(
            usesFloatingSurface: layout.usesFloatingSidebarSurface
        ) {
            if layout.usesFloatingSidebarSurface {
                // 浮动侧栏已经有 12pt 外围安全间距；移除 SidebarListStyle 额外添加的
                // scroll content leading margin，让导航、分组头和监视行整列一起左移。
                sidebarList(tokens: tokens, layout: layout)
                    .contentMargins(.leading, 0, for: .scrollContent)
            } else {
                // 覆盖式 / 系统侧栏继续使用平台默认边距，避免贴到设备安全区。
                sidebarList(tokens: tokens, layout: layout)
            }
        } footer: {
            sidebarFooter(
                tokens: tokens,
                layout: layout,
                bottomSafeAreaInset: bottomSafeAreaInset
            )
        }
        // NavigationSplitView 在 iPad 竖屏以 overlay 展开侧栏时不会保证内容采用整列理想高度，
        // 根容器必须主动填满列高，Footer 才能稳定锚定到底部安全区。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sidebarList(tokens: ThemeTokens, layout: WorkbenchLayout) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            sidebarListContent(tokens: tokens, layout: layout, now: context.date)
        }
    }

    private func sidebarListContent(tokens: ThemeTokens, layout: WorkbenchLayout, now: Date) -> some View {
        let sections = sidebarMonitorSections(now: now)

        return List(selection: selectionBinding(layout: layout)) {
            Section {
                sidebarDestinationRow(
                    destination: .sessions,
                    title: L10n.text("ui.session"),
                    icon: .sessions,
                    tokens: tokens,
                    layout: layout
                )
                sidebarDestinationRow(
                    destination: .workspaces,
                    title: L10n.text("ui.workspace"),
                    icon: .workspaces,
                    tokens: tokens,
                    layout: layout
                )
            }

            ForEach(sections) { section in
                Section {
                    // index 只判断相邻项目，行身份仍用 session.id，避免刷新时重建已选中行。
                    ForEach(Array(section.sessions.enumerated()), id: \.element.id) { index, session in
                        sidebarSessionLink(
                            session,
                            kind: section.kind,
                            startsProjectGroup: SessionListPresentation.startsSidebarProjectGroup(
                                for: session,
                                previousSession: index > 0 ? section.sessions[index - 1] : nil,
                                in: section.kind
                            ),
                            layout: layout
                        )
                    }

                    if section.overflowCount > 0 {
                        Button {
                            open(.sessions, layout: layout)
                        } label: {
                            Text(L10n.format("ui.more_sessions_count", section.overflowCount))
                                .font(themeStore.uiFont(size: 11, weight: .medium))
                                .foregroundStyle(tokens.secondaryText)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(.init(top: 0, leading: 36, bottom: 0, trailing: 10))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("\(sidebarSectionTitle(section.kind)) \(section.sessions.count + section.overflowCount)")
                        .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contentMargins(
            .trailing,
            layout.usesFloatingSidebarSurface
                ? WorkbenchSidebarSurfaceMetrics.openDragStripWidth
                : 0,
            for: .scrollContent
        )
        .environment(\.defaultMinListRowHeight, 34)
        // 覆盖式侧栏可能只按 List 的理想内容高度提案；显式占用剩余空间后列表自行滚动。
        .frame(maxHeight: .infinity)
    }

    private func sidebarBrandHeader(
        tokens: ThemeTokens,
        layout: WorkbenchLayout,
        constrainedWidth: CGFloat? = 190,
        usesFloatingChrome: Bool = false
    ) -> some View {
        HStack(spacing: usesFloatingChrome ? 6 : 8) {
            AIUsageRingsControl(
                codexDisplay: sessionStore.accountCodexUsageWindowsDisplay,
                claudeDisplay: sessionStore.accountClaudeUsageWindowsDisplay,
                includesClaude: sessionStore.hasClaudeRuntimeChannel,
                usesCondensedVisual: usesFloatingChrome,
                onRefresh: {
                    await sessionStore.refreshCodexUsage()
                    if sessionStore.hasClaudeRuntimeChannel {
                        await sessionStore.refreshClaudeUsage()
                    }
                }
            )
            .fixedSize()

            HostSwitcherMenu(
                presentation: .sidebar,
                usesCondensedSidebarMetrics: usesFloatingChrome,
                manageConnections: {
                    open(.me, layout: layout)
                }
            )
            .layoutPriority(1)
        }
        .frame(width: constrainedWidth, alignment: .leading)
    }

    @ViewBuilder
    private func sidebarSessionLink(
        _ session: AgentSession,
        kind: SessionSidebarSectionKind,
        startsProjectGroup: Bool,
        layout: WorkbenchLayout
    ) -> some View {
        Group {
            if layout.usesFloatingSidebarSurface {
                Button {
                    openSession(session, source: .sessions, layout: layout)
                } label: {
                    sidebarSessionRow(
                        session,
                        kind: kind,
                        startsProjectGroup: startsProjectGroup
                    )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(
                    navigationState.selection == .session(session.id)
                        ? .isSelected
                        : []
                )
            } else {
                NavigationLink(value: AppDestination.session(session.id)) {
                    sidebarSessionRow(
                        session,
                        kind: kind,
                        startsProjectGroup: startsProjectGroup
                    )
                }
            }
        }
        .sessionRowActions(session)
        .sessionRowSwipeActions(session)
        .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func sidebarSessionRow(
        _ session: AgentSession,
        kind: SessionSidebarSectionKind,
        startsProjectGroup: Bool
    ) -> some View {
        SessionSidebarMonitorRow(
            session: session,
            kind: kind,
            isSelected: navigationState.selection == .session(session.id),
            isRecentlyCompleted: sidebarHighlightCoordinator.highlightedSessionID == session.id,
            completionObservedAt: sessionStore.historyCompletionObservedAtBySessionID[session.id],
            // 运行组头承担状态和项目身份；后续同项目行隐藏标记，Row 固定占位保持标题对齐。
            showsStateMarker: kind != .running || startsProjectGroup,
            projectIcon: startsProjectGroup
                ? sidebarProjectIcons[session.projectID]
                    ?? workspaceAppearanceStore.projectIconContent(
                        profileID: appStore.activeHostScope.profileID,
                        projectID: session.projectID
                    )
                : nil,
            runtimeActivitySnapshot: sessionStore.runtimeActivitySnapshot(for: session.id)
        )
    }

    private func sidebarMonitorSections(now: Date) -> [SessionSidebarSection] {
        let chronologicallySortedSessions = sessionStore.sortedAllSessions.isEmpty
            ? SessionStore.sortedSessions(sessionStore.sessionLibrarySessions)
            : sessionStore.sortedAllSessions
        return SessionListPresentation.sidebarSections(
            sessions: chronologicallySortedSessions,
            pinnedIDs: sessionStore.pinnedSessionIDs,
            completionObservedAtByID: sessionStore.historyCompletionObservedAtBySessionID,
            now: now
        )
    }

    private var sidebarProjectIcons: [String: WorkspaceProjectIconContent] {
        workspaceAppearanceStore.projectIconContents(
            profileID: appStore.activeHostScope.profileID,
            projectIDs: sessionStore.sidebarProjects.map(\.id)
        )
    }

    private var sidebarLifecycleObservations: [SessionLifecycleObservation] {
        sessionStore.sessions.map { session in
            SessionLifecycleObservation(
                session: session,
                foregroundActivity: sessionStore.foregroundActivity(for: session.id)
            )
        }
    }

    private func synchronizeSidebarLifecycle() {
        sidebarHighlightCoordinator.observe(
            profileID: appStore.activeHostScope.profileID,
            observations: sidebarLifecycleObservations
        )
    }

    private func sidebarSectionTitle(_ kind: SessionSidebarSectionKind) -> String {
        switch kind {
        case .needYou:
            return L10n.text("ui.needs_you")
        case .running:
            return L10n.text("ui.in_progress")
        case .justCompleted:
            return L10n.text("ui.just_completed")
        case .pinned:
            return L10n.text("ui.pinned")
        case .recent:
            return L10n.text("ui.recently")
        }
    }

    private func sidebarFooter(
        tokens: ThemeTokens,
        layout: WorkbenchLayout,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
        WorkbenchSidebarFooter(
            tokens: tokens,
            usesFloatingSurface: layout.usesFloatingSidebarSurface,
            bottomSafeAreaInset: bottomSafeAreaInset,
            isMeSelected: navigationState.selection == .me,
            onOpenSettings: {
                // “我的”是一级入口，但不覆盖后台保留的会话/工作区恢复路由。
                open(.me, layout: layout)
            },
            onNewSession: {
                // 只有宽 iPad 浮动侧栏是已确认的稳定来源；其余布局 fail closed。
                presentSheet(
                    .newSession,
                    source: layout.usesFloatingSidebarSurface ? .sidebarNewSession : nil
                )
            },
            newSessionPresentationNamespace: layout.usesFloatingSidebarSurface
                ? presentationNamespace
                : nil
        )
    }

    private func sidebarDestinationRow(
        destination: AppDestination,
        title: String,
        icon: WorkbenchNavigationIcon,
        tokens: ThemeTokens,
        layout: WorkbenchLayout
    ) -> some View {
        let isSelected = navigationState.selection == destination

        return WorkbenchSidebarDestinationButton(
            title: title,
            icon: icon,
            isSelected: isSelected,
            tokens: tokens,
            action: { open(destination, layout: layout) }
        )
    }

    @ViewBuilder
    private func compactDestination(
        _ destination: AppDestination,
        layout: WorkbenchLayout,
        tokens: ThemeTokens
    ) -> some View {
        switch destination {
        case .sessions:
            sessionList(layout: layout)
        case .workspaces:
            workspaces(layout: layout)
        case .me:
            SettingsView(
                isInitialSetup: false,
                showsDoneButton: false,
                embedsNavigationStack: false
            )
        case .session:
            sessionDetail(layout: layout, tokens: tokens)
        case .subagent(let parentID, let childID):
            if let relation = selectedRelatedSubagent,
               relation.id == childID,
               relatedSubagentParentID == parentID {
                RelatedSessionConversationView(
                    relation: relation,
                    parentSessionID: parentID,
                    showsCloseButton: false,
                    onClose: {}
                )
            } else {
                ContentUnavailableView(
                    L10n.text("ui.sub_agent"),
                    systemImage: "person.2.slash",
                    description: Text(L10n.text("ui.sub_agent_unavailable"))
                )
            }
        }
    }

    @ViewBuilder
    private func detail(layout: WorkbenchLayout, tokens: ThemeTokens) -> some View {
        switch navigationState.selection ?? .sessions {
        case .sessions:
            NavigationStack {
                sessionList(layout: layout)
            }
        case .workspaces:
            workspaces(layout: layout)
        case .me:
            NavigationStack {
                SettingsView(
                    isInitialSetup: false,
                    showsDoneButton: false,
                    embedsNavigationStack: false
                )
            }
        case .session, .subagent:
            if layout.usesFloatingSidebarSurface {
                // 浮层路径不再由 NavigationSplitView 提供 detail 导航上下文，父会话与子会话路由都显式使用原生导航栈。
                NavigationStack {
                    sessionDetail(layout: layout, tokens: tokens)
                }
            } else {
                sessionDetail(layout: layout, tokens: tokens)
            }
        }
    }

    private func sessionList(
        layout: WorkbenchLayout,
        bottomContentMargin: CGFloat? = nil
    ) -> some View {
        let manageConnections: (() -> Void)? = layout.usesCompactNavigation && layout.isPhone
            ? { openConnectionSettings(layout: layout) }
            : nil

        return SessionListView(
            onNewSession: { source in
                presentSheet(.newSession, source: source)
            },
            onSelectSession: { session in
                openSession(session, source: .sessions, layout: layout)
            },
            onOpenWorkspaces: {
                // 首次使用空态与侧栏共用同一路由，紧凑布局切 Tab，宽屏切换详情列。
                open(.workspaces, layout: layout)
            },
            manageConnections: manageConnections,
            prefersTableDensity: layout.prefersSessionTableDensity,
            usesCompactNavigation: layout.usesCompactNavigation,
            bottomContentMargin: bottomContentMargin
                ?? (layout.usesCompactNavigation
                    ? WorkbenchPageLayout.defaultCompactBottomChromeClearance
                    : 16),
            newSessionPresentationNamespace: presentationNamespace
        )
    }

    private func workspaces(layout: WorkbenchLayout) -> some View {
        let manageConnections: (() -> Void)?
        if layout.usesCompactNavigation && layout.isPhone {
            manageConnections = {
                openConnectionSettings(layout: layout)
            }
        } else {
            manageConnections = nil
        }

        return WorkspaceRootView(
            onStartSession: { project, runtimeChoice in
                Task {
                    await sessionStore.startNewSession(in: project, runtimeProvider: runtimeChoice.runtimeProvider)
                }
            },
            onOpenSession: { session in
                // 选择会话和切换路由由同一个入口发起，避免 selectedSessionID 的回调再次 open。
                openSession(session, source: .workspaces, layout: layout)
            },
            manageConnections: manageConnections,
            // 紧凑布局的 destination 必须复用外层绑定 path 的 NavigationStack。
            embedsNavigationStack: WorkspaceRootView.shouldEmbedNavigationStack(
                usesCompactNavigation: layout.usesCompactNavigation
            ),
            appearanceStore: workspaceAppearanceStore
        )
    }

    private func sessionDetail(layout: WorkbenchLayout, tokens: ThemeTokens) -> some View {
        let detailSessionID = navigationState.route.detailSessionID
        let canPresentSessionDetail = navigationState.canPresentSessionDetail(
            selectedSessionID: sessionStore.selectedSessionID
        )
        let detailSession = detailSessionID.flatMap { sessionStore.sessionsByID[$0] }
        let detailTitle = detailSession?.title
            ?? (canPresentSessionDetail ? sessionStore.selectedSession?.title : nil)
            ?? L10n.text("ui.session")

        return Group {
            if canPresentSessionDetail {
                WorkspaceView {
                    open(.workspaces, layout: layout)
                }
            } else {
                // 导航已经指向目标会话、SessionStore 还未提交选择时，只保留稳定底板。
                // 这段窗口通常不足一帧，但不能让上一个会话的正文或空态借机出现。
                tokens.conversationCanvasBackground
                    .accessibilityHidden(true)
            }
        }
        .navigationTitle(detailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if navigationState.showsWorkspaceBackButton(
                usesCompactNavigation: layout.usesCompactNavigation
            ) {
                ToolbarItem(placement: .navigation) {
                    Button {
                        open(.workspaces, layout: layout)
                    } label: {
                        Label(L10n.text("ui.workspace"), systemImage: "chevron.backward")
                    }
                    // 宽屏需要显式动作，紧凑布局由外层 NavigationStack 提供系统返回。
                    // 保留原生 toolbar 样式，同时显式扩展交互形状，避免只按图标可见区域命中。
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.interaction, Rectangle())
                    .accessibilityLabel(L10n.text("ui.workspace"))
                    .accessibilityHint(L10n.text("ui.return_to_previous_level"))
                    .accessibilityIdentifier("sessionDetail.workspaceBack")
                }
            }
            if canPresentSessionDetail {
                ToolbarItem(placement: .principal) {
                    Group {
                        if sessionStore.selectedRuntimeActivitySnapshot != nil {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                sessionDetailNavigationTitle(
                                    layout: layout,
                                    tokens: tokens,
                                    now: context.date
                                )
                            }
                        } else {
                            sessionDetailNavigationTitle(
                                layout: layout,
                                tokens: tokens,
                                now: Date()
                            )
                        }
                    }
                }
                if layout.usesCompactNavigation {
                    workbenchChromeToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if let session = sessionStore.selectedSession {
                                SessionActionMenuContent(
                                    session: session,
                                    presentation: $sessionActionPresentation
                                )
                                Divider()
                            }

                            Button {
                                Task { await sessionStore.refreshCurrentContext() }
                            } label: {
                                Label(L10n.text("ui.refresh_current_session"), systemImage: "arrow.clockwise")
                            }
                            .disabled(sessionStore.isRefreshingSelectedSession || sessionStore.isLoading)

                            Button {
                                toggleInspector(layout: layout)
                            } label: {
                                Label(
                                    showingInspector ? L10n.text("ui.hide_details") : L10n.text("ui.show_details"),
                                    systemImage: "sidebar.right"
                                )
                            }
                        } label: {
                            WorkbenchChromeIcon(systemName: "ellipsis")
                                .foregroundStyle(tokens.primaryText.opacity(0.72))
                                .workbenchToolbarChromeCircle(tokens: tokens)
                        }
                        .accessibilityLabel(L10n.text("ui.options"))
                    }
                } else {
                    if let session = sessionStore.selectedSession {
                        workbenchChromeToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                SessionActionMenuContent(
                                    session: session,
                                    presentation: $sessionActionPresentation
                                )
                            } label: {
                                WorkbenchChromeIcon(systemName: "ellipsis")
                                    .foregroundStyle(tokens.secondaryText)
                                    .workbenchToolbarChromeCircle(tokens: tokens)
                            }
                            .accessibilityLabel(L10n.text("ui.options"))
                        }
                        if #available(iOS 26.0, *) {
                            ToolbarSpacer(.fixed, placement: .topBarTrailing)
                        }
                    }

                    workbenchChromeToolbarItem(placement: .topBarTrailing) {
                        workbenchToolbarIconButton(
                            systemImage: "arrow.clockwise",
                            accessibilityLabel: L10n.text("ui.refresh_current_session"),
                            tokens: tokens,
                            isDisabled: sessionStore.isRefreshingSelectedSession || sessionStore.isLoading
                        ) {
                            Task { await sessionStore.refreshCurrentContext() }
                        }
                    }
                    // 顶栏按钮各自独立，用固定间隔把磨砂圆之间的距离钉死，不靠系统按内容估算。
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    inspectorToolbarItem(layout: layout, tokens: tokens)
                }
            } else {
                ToolbarItem(placement: .principal) {
                    Text(detailTitle)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                }
            }
        }
        .background(tokens.conversationCanvasBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .tabBar)
        .modifier(
            SessionNavigationMaterialModifier(
                usesCompactNavigation: layout.usesCompactNavigation,
                tokens: tokens,
                colorScheme: themeStore.resolvedColorScheme(for: colorScheme),
                reduceTransparency: reduceTransparency
            )
        )
        .sessionActionSheets(presentation: $sessionActionPresentation)
        .environment(
            \.openSubagentSession,
            OpenSubagentSessionAction { subagent in
                openRelatedSubagent(subagent, layout: layout)
            }
        )
        .sessionInspectorPresentation(
            isPresented: $showingInspector,
            layout: layout,
            transitionContext: inspectorPresentationState.context,
            presentationNamespace: presentationNamespace,
            relatedSubagent: $selectedRelatedSubagent,
            parentSessionID: $relatedSubagentParentID,
            onOpenSubagent: { subagent in
                openRelatedSubagent(subagent, layout: layout)
            },
            onCloseRelatedSubagent: {
                closeRelatedSubagent(keepInspectorVisible: true)
            },
            onRequestDismiss: {
                // 只有用户明确结束当前 Inspector 时才清理子 Agent 导航。
                // 布局迁移也会关闭 Sheet，但必须保留关系以迁移到 compact/attached host。
                closeRelatedSubagent(keepInspectorVisible: false)
            },
            onDismiss: {
                // Sheet 的返回动画完成后再清来源，保证 zoom 能回到原按钮。
                inspectorPresentationState.dismiss()
            }
        )
    }

    private func selectionBinding(layout: WorkbenchLayout) -> Binding<AppDestination?> {
        Binding(
            get: { navigationState.selection },
            set: { destination in
                // List 可能在数据刷新时短暂写 nil；忽略这一过渡值，避免无意关闭详情。
                guard let destination else { return }
                let expectedSelection = navigationState.selection
                guard destination != expectedSelection else { return }
                navigationBindingScheduler.schedule(on: .splitSelection) {
                    // 外部恢复或会话选择若已推进导航，丢弃旧的 List 规范化回写。
                    guard navigationState.selection == expectedSelection else { return }
                    let source: WorkbenchRootPage? = if case .session = destination { .sessions } else { nil }
                    applyNavigation(.open(destination, source: source), layout: layout)
                }
            }
        )
    }

    private func compactPathBinding(
        for tab: CompactWorkbenchTab,
        layout: WorkbenchLayout
    ) -> Binding<[AppDestination]> {
        Binding(
            get: {
                compactPath(for: tab)
            },
            set: { path in
                let expectedPath = compactPath(for: tab)
                guard path != expectedPath else { return }
                if case .subagent = expectedPath.last,
                   !path.contains(where: {
                       if case .subagent = $0 { return true }
                       return false
                   }) {
                    closeRelatedSubagent(keepInspectorVisible: false)
                }
                let lane: WorkbenchNavigationBindingScheduler.Lane = tab == .workspaces
                    ? .compactWorkspacesPath
                    : .compactSessionsPath
                applyInteractiveNavigation(
                    .compactPathChanged(tab: tab, path: path),
                    lane: lane,
                    layout: layout
                )
            }
        )
    }

    private func compactTabBinding(layout: WorkbenchLayout) -> Binding<CompactWorkbenchTab> {
        Binding(
            get: { navigationState.compactSelectedTab },
            set: { tab in
                let expectedTab = navigationState.compactSelectedTab
                guard tab != expectedTab else { return }
                applyInteractiveNavigation(
                    .compactTabChanged(tab),
                    lane: .compactTab,
                    layout: layout
                )
            }
        )
    }

    private func compactPath(for tab: CompactWorkbenchTab) -> [AppDestination] {
        tab == .workspaces
            ? navigationState.compactWorkspacePath
            : navigationState.compactSessionPath
    }

    private func open(
        _ destination: AppDestination,
        source: WorkbenchRootPage? = nil,
        layout: WorkbenchLayout
    ) {
        if case .subagent = destination {
            // 由 openRelatedSubagent 先保存展示元数据。
        } else if selectedRelatedSubagent != nil {
            closeRelatedSubagent(keepInspectorVisible: false)
        }
        applyNavigation(.open(destination, source: source), layout: layout)
    }

    private func openSession(
        _ session: AgentSession,
        source: WorkbenchRootPage,
        layout: WorkbenchLayout
    ) {
        applyNavigation(
            .open(.session(session.id), source: source),
            layout: layout,
            preferredSession: session
        )
    }

    private func synchronizeNavigation(for layout: WorkbenchLayout) {
        applyNavigation(.synchronize(restorationRoute), layout: layout)
    }

    private func applyDebugLaunchRouteIfNeeded(layout: WorkbenchLayout) {
#if DEBUG
        guard !didApplyDebugLaunchRoute else { return }
        let arguments = ProcessInfo.processInfo.arguments
        // App Store 截图需要在 Simulator 与真机上得到完全相同的页面状态。
        // 这些入口只存在于 Debug 构建，不改变正常启动、恢复或 Release 路由。
        if arguments.contains("--debug-open-conversation") {
            didApplyDebugLaunchRoute = true
            open(.session("debug-session-layout"), source: .sessions, layout: layout)
        } else if arguments.contains("--debug-open-sessions") {
            didApplyDebugLaunchRoute = true
            open(.sessions, layout: layout)
        } else if arguments.contains("--debug-open-workspaces") {
            didApplyDebugLaunchRoute = true
            open(.workspaces, layout: layout)
        } else if arguments.contains("--debug-open-settings")
            || arguments.contains("--debug-open-mac-connection") {
            didApplyDebugLaunchRoute = true
            presentSheet(.settings)
        }
#endif
    }

    private func handleLayoutModeChange(
        usesCompactNavigation: Bool,
        layout: WorkbenchLayout
    ) {
        inspectorPresentationState.layoutHostDidChange(
            to: inspectorPresentationHost(for: layout)
        )
        if usesCompactNavigation {
            if let relation = selectedRelatedSubagent,
               let parentID = relatedSubagentParentID {
                showingInspector = false
                applyNavigation(
                    .open(
                        .subagent(parentID: parentID, childID: relation.id),
                        source: navigationState.route.rootPage
                    ),
                    layout: layout
                )
                return
            }
            if navigationState.selection == .me {
                applyNavigation(.compactTabChanged(.me), layout: layout)
            } else {
                synchronizeNavigation(for: layout)
            }
            return
        }

        if selectedRelatedSubagent != nil {
            prepareInspectorPresentation(layout: layout)
            showingInspector = true
        }

        if navigationState.compactSelectedTab == .me {
            open(.me, layout: layout)
        } else {
            synchronizeNavigation(for: layout)
        }
    }

    private func handleRelatedPresentationChange(layout: WorkbenchLayout) {
        inspectorPresentationState.layoutHostDidChange(
            to: inspectorPresentationHost(for: layout)
        )
        guard selectedRelatedSubagent != nil, !layout.usesCompactNavigation else { return }
        prepareInspectorPresentation(layout: layout)
        showingInspector = true
    }

    private func toggleInspector(
        layout: WorkbenchLayout,
        source: InspectorPresentationSource? = nil
    ) {
        if showingInspector {
            closeRelatedSubagent(keepInspectorVisible: false)
            showingInspector = false
            if layout.usesAttachedInspector {
                // Attached host 没有 Sheet onDismiss，且从未使用 zoom，可同步结束动画上下文。
                inspectorPresentationState.dismiss()
            }
        } else {
            // SwiftUI 可能在 Bool 写入的同一事务创建 Sheet；来源必须先锁定。
            prepareInspectorPresentation(layout: layout, source: source)
            showingInspector = true
        }
    }

    private func openRelatedSubagent(
        _ relation: SessionContextSubagent,
        layout: WorkbenchLayout
    ) {
        guard !relation.id.isEmpty, let parentID = sessionStore.selectedSessionID else { return }
        selectedRelatedSubagent = relation
        relatedSubagentParentID = parentID

        if layout.usesCompactNavigation {
            showingInspector = false
            DispatchQueue.main.async {
                open(
                    .subagent(parentID: parentID, childID: relation.id),
                    source: navigationState.route.rootPage,
                    layout: layout
                )
            }
        } else {
            // 宽屏替换附着检查器；中等宽度复用当前系统 sheet 并在其中 push，
            // 两种形态都保留父会话上下文。
            prepareInspectorPresentation(layout: layout)
            showingInspector = true
        }
    }

    private func closeRelatedSubagent(keepInspectorVisible: Bool) {
        if let childID = selectedRelatedSubagent?.id {
            sessionStore.stopRelatedSessionObservation(sessionID: childID)
        }
        selectedRelatedSubagent = nil
        relatedSubagentParentID = nil
        if keepInspectorVisible {
            showingInspector = true
        }
    }

    private func inspectorPresentationHost(
        for layout: WorkbenchLayout
    ) -> InspectorPresentationHost {
        if layout.usesCompactNavigation {
            return .compactSheet
        }
        return layout.usesAttachedInspector ? .attached : .mediumSheet
    }

    private func prepareInspectorPresentation(
        layout: WorkbenchLayout,
        source: InspectorPresentationSource? = nil
    ) {
        inspectorPresentationState.present(
            on: inspectorPresentationHost(for: layout),
            source: source,
            hasNamespace: true,
            reduceMotion: reduceMotion
        )
    }

    private func handleSelectionCommit(
        _ commit: SessionSelectionCommit,
        layout: WorkbenchLayout
    ) {
        applyNavigation(.selectionCommitted(commit), layout: layout)
    }

    private func applyNavigation(
        _ event: WorkbenchNavigationEvent,
        layout: WorkbenchLayout,
        preferredSession: AgentSession? = nil
    ) {
        let commit = makeNavigationCommit(event, layout: layout)
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
    private func applyInteractiveNavigation(
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
        layout: WorkbenchLayout
    ) -> WorkbenchNavigationCommit {
        var nextState = navigationState
        let effect = nextState.reduce(
            event,
            usesCompactNavigation: layout.usesCompactNavigation,
            selectedSessionID: sessionStore.selectedSessionID
        )
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

        switch commit.effect {
        case .returnToSessionList:
            sessionStore.returnToSessionList()
        case .selectSession(let sessionID):
            let session = preferredSession?.id == sessionID
                ? preferredSession
                : sessionStore.sessionLibrarySessions.first(where: { $0.id == sessionID })
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
    private func inspectorToolbarItem(
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
    private func workbenchToolbarIconButton(
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
        .foregroundStyle(isActive ? tokens.primaryAction : tokens.secondaryText)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func sessionDetailNavigationTitle(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        now: Date
    ) -> some View {
        let showsStatus = selectedSessionShowsNavigationStatus
        return VStack(spacing: 1) {
            // 标题只保留一行当前任务；普通状态收进固定副标题槽，
            // 避免 running / idle 切换时把整条时间线向下推。
            Text(sessionStore.selectedSession?.title ?? L10n.text("ui.session"))
                .font(.headline)
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 5) {
                if showsStatus {
                    Circle()
                        .fill(sessionTitleSubtitleColor(tokens: tokens, now: now))
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
                Text(sessionTitleSubtitle(now: now))
                    .font(sessionDetailNavigationSubtitleFont(layout: layout))
                    .foregroundStyle(sessionTitleSubtitleColor(tokens: tokens, now: now))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: layout.titleMaxWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sessionStore.selectedSession?.title ?? L10n.text("ui.session"))
        .accessibilityValue(sessionTitleAccessibilityValue(now: now))
        .accessibilityIdentifier("sessionDetail.title")
    }

    private func sessionDetailNavigationSubtitleFont(layout: WorkbenchLayout) -> Font {
        if layout.usesCompactPhoneNavigationTypography {
            // iPhone 与对话消息“发送 / 完成时间”复用同一 caption2 排版规格。
            return themeStore.uiFont(.caption2, weight: .medium)
        }
        // 紧凑 iPad 继续使用原有 subheadline；宽屏布局继续使用 caption2。
        return layout.usesCompactNavigation
            ? .subheadline.weight(.regular)
            : .caption2.weight(.medium)
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
            return tokens.primaryAction
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

    private var connectionSubtitle: String {
        if appStore.requiresRePairing {
            return L10n.text("ui.need_to_re_pair")
        }
        if sessionStore.isNetworkUnavailable {
            return L10n.text("ui.the_network_is_unavailable_waiting_for_automatic_reconnection")
        }
        return sessionStore.webSocketStatus == .connected ? L10n.text("ui.mac_is_connected") : L10n.text("ui.remote_development_workbench")
    }

    private func connectionTone(tokens: ThemeTokens) -> Color {
        if sessionStore.isNetworkUnavailable, !appStore.requiresRePairing {
            return tokens.warning
        }
        switch sessionStore.webSocketStatus {
        case .connected: return tokens.success
        case .connecting: return tokens.warning
        case .failed: return .red
        case .terminated: return .red
        case .disconnected: return tokens.tertiaryText
        }
    }
}

/// 会话详情导航层的材质策略。紧凑与宽屏只在降级路径上不同，iOS 26 的正常透明度
/// 路径共用同一条渐变底衬 + soft scroll edge 语义，让 iPhone、iPad 竖屏和 iPad 横屏
/// 得到同等的顶部分离。
private struct SessionNavigationMaterialModifier: ViewModifier {
    let usesCompactNavigation: Bool
    let tokens: ThemeTokens
    let colorScheme: ColorScheme
    let reduceTransparency: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            // 关闭透明度后不做任何采样：紧凑用输入层实色，宽屏继续贴合阅读画布。
            content
                .toolbarBackground(
                    usesCompactNavigation ? tokens.inputBackground : tokens.conversationCanvasBackground,
                    for: .navigationBar
                )
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                .toolbarColorScheme(colorScheme, for: .navigationBar)
        } else if #available(iOS 26.0, *) {
            content
                // 导航栏底板必须保持隐藏。只要给 navigationBar 设了可见 background，系统就不再
                // 对顶部滚动边缘做渐进模糊：`.thinMaterial` / `.ultraThinMaterial` 会在下沿切出
                // 一条横贯全宽的灰带，即使换成画布色渐变，后方正文也只是被压淡而依然逐字清晰——
                // 「挡住但还看得见」正是最难看的一档。真正的虚化只能来自 soft scroll edge，
                // 所以这里让出底板，额外的压暗由 ConversationView 顶部那层渐隐叠加提供。
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbarColorScheme(colorScheme, for: .navigationBar)
        } else if usesCompactNavigation {
            content
                // 旧系统没有 scroll edge blur，继续用一层完整 Material 保证可读性。
                .toolbarBackground(WorkbenchMaterial.surface, for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                .toolbarColorScheme(colorScheme, for: .navigationBar)
        } else {
            // 会话详情的宽屏导航边缘与正文共用同一画布，避免滚动到边缘时
            // 全局工作台暖底重新显形，把纸白阅读层切成两种色温。
            content
                .toolbarBackground(tokens.conversationCanvasBackground, for: .navigationBar)
                .toolbarColorScheme(colorScheme, for: .navigationBar)
        }
    }
}
