import SwiftUI

/// 紧凑导航的页面组装独立于侧栏与会话状态处理。
extension UnifiedWorkbenchShell {
    func compactLayout(
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

        return compactNavigationRoot(
            layout: layout,
            tokens: tokens,
            bottomContentMargin: bottomChromeClearance,
            hasBottomTabBar: hasBottomTabBar
        )
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

    @ViewBuilder
    func compactNavigationRoot(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        bottomContentMargin: CGFloat,
        hasBottomTabBar: Bool
    ) -> some View {
        let usesIndependentStacks = WorkbenchPageLayout.usesIndependentCompactNavigationStacks(
            hasBottomTabBar: hasBottomTabBar
        )
        if usesIndependentStacks || navigationState.compactSelectedTab.isGlobalSettings {
            // 设置页已有独立的类型化路径。顶部 Tab 选中设置时不再套工作台栈，
            // 避免两个 NavigationStack 同时管理标题、安全区和返回转场。
            compactTabs(
                layout: layout,
                tokens: tokens,
                bottomContentMargin: bottomContentMargin,
                usesIndependentStacks: usesIndependentStacks
            )
        } else {
            // 顶部 Tab 的详情必须位于 TabView 之外。这样 push/pop 只切换一个导航容器，
            // 系统不会在同一转场里再独立改变顶部 Tab 的安全区和导航标题位置。
            NavigationStack(
                path: compactPathBinding(
                    for: navigationState.compactSelectedTab,
                    layout: layout
                )
            ) {
                compactTabs(
                    layout: layout,
                    tokens: tokens,
                    bottomContentMargin: bottomContentMargin,
                    usesIndependentStacks: false
                )
                .navigationDestination(for: AppDestination.self) { destination in
                    compactDestination(
                        destination,
                        layout: layout,
                        tokens: tokens,
                        shouldHideTabBar: false
                    )
                }
            }
        }
    }

    func compactTabs(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        bottomContentMargin: CGFloat,
        usesIndependentStacks: Bool
    ) -> some View {
        TabView(selection: compactTabBinding(layout: layout)) {
            compactTabRoot(
                for: .sessions,
                usesIndependentStack: usesIndependentStacks,
                layout: layout,
                tokens: tokens
            ) {
                sessionList(layout: layout, bottomContentMargin: bottomContentMargin)
            }
            .tabItem { compactTabItem(.sessions) }
            .tag(CompactWorkbenchTab.sessions)

            compactTabRoot(
                for: .workspaces,
                usesIndependentStack: usesIndependentStacks,
                layout: layout,
                tokens: tokens
            ) {
                workspaces(layout: layout)
            }
            .tabItem { compactTabItem(.workspaces) }
            .tag(CompactWorkbenchTab.workspaces)

            settingsPage(tab: .devices, layout: layout)
            .tabItem { compactTabItem(.devices) }
            .tag(CompactWorkbenchTab.devices)

            settingsPage(tab: .me, layout: layout)
            .tabItem { compactTabItem(.me) }
            .tag(CompactWorkbenchTab.me)
        }
    }

    /// 四个入口共用一处组装：图标是放大后的 24pt 模板图，标题保留，
    /// 命中区域和选中反馈仍由系统 Tab 提供。
    func compactTabItem(_ tab: CompactWorkbenchTab) -> some View {
        Label { Text(tab.title) } icon: { tab.navigationIcon.navigationImage() }
            .accessibilityIdentifier(tab.accessibilityIdentifier)
    }

    @ViewBuilder
    func compactTabRoot<Content: View>(
        for tab: CompactWorkbenchTab,
        usesIndependentStack: Bool,
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if usesIndependentStack {
            NavigationStack(path: compactPathBinding(for: tab, layout: layout)) {
                content()
                    .navigationDestination(for: AppDestination.self) { destination in
                        compactDestination(
                            destination,
                            layout: layout,
                            tokens: tokens,
                            shouldHideTabBar: true
                        )
                    }
            }
        } else {
            content()
        }
    }

    /// TabView 上的自由浮层。命中区域保持 44pt，但磨砂圆按顶栏那档画成 40pt——
    /// 它和导航栏里的「···」「+」在同一条视线上，直径不一致会立刻被看出来。
    func compactTabletHostSwitcher(
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

    func dismissSessionSearchKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

}
