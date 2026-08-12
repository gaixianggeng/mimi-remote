import SwiftUI

enum AppDestination: Hashable {
    case sessions
    case workspaces
    case me
    case session(SessionID)
    case subagent(parentID: SessionID, childID: SessionID)
}

/// SwiftUI 的 TabView / NavigationStack 会在自身更新事务里规范化 selection 和 path。
/// 紧凑导航先同步提交控件直接绑定的视觉状态，再按控件合并外部副作用；这样既不让
/// Tab/返回手势落后一帧，也能继续丢弃恢复、网络选择等已经过期的写入。
@MainActor
final class WorkbenchNavigationBindingScheduler {
    enum Lane: Hashable {
        case splitSelection
        case compactTab
        case compactSessionsPath
        case compactWorkspacesPath
    }

    private var revisions: [Lane: UInt] = [:]

    func schedule(
        on lane: Lane,
        action: @escaping @MainActor () -> Void
    ) {
        let revision = revisions[lane, default: 0] &+ 1
        revisions[lane] = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revisions[lane] == revision else {
                return
            }
            self.revisions[lane] = nil
            action()
        }
    }

    /// Binding setter 里的视觉状态属于系统当前交互事务，必须立即提交；只有可能发布到
    /// 其他 Store/Binding 的副作用才延后。返回值把本次视觉快照带到延后阶段做过期检查。
    @discardableResult
    func commit<Value>(
        on lane: Lane,
        visualUpdate: () -> Value,
        deferredSideEffect: @escaping @MainActor (Value) -> Void
    ) -> Value {
        let value = visualUpdate()
        schedule(on: lane) {
            deferredSideEffect(value)
        }
        return value
    }
}

enum CompactWorkbenchTab: Hashable {
    case sessions
    case workspaces
    case me

    var title: String {
        switch self {
        case .sessions: return L10n.text("ui.session")
        case .workspaces: return L10n.text("ui.workspace")
        case .me: return L10n.text("ui.me")
        }
    }

    var systemImage: String {
        navigationIcon.normalSystemName
    }

    var navigationIcon: WorkbenchNavigationIcon {
        switch self {
        case .sessions: return .sessions
        case .workspaces: return .workspaces
        case .me: return .me
        }
    }
}

enum WorkbenchNavigationEffect: Equatable {
    case returnToSessionList
    case selectSession(SessionID)
}

/// 先在副本中计算导航状态和副作用，再一起提交给 SwiftUI。
struct WorkbenchNavigationCommit {
    let state: WorkbenchNavigationState
    let effect: WorkbenchNavigationEffect?
}

enum WorkbenchNavigationEvent: Equatable {
    case open(AppDestination, source: WorkbenchRootPage?)
    case synchronize(WorkbenchRestorationRoute)
    case selectionCommitted(SessionSelectionCommit)
    case compactPathChanged(tab: CompactWorkbenchTab, path: [AppDestination])
    case compactTabChanged(CompactWorkbenchTab)
    case sessionSelectionFinished(SessionID)
}

/// 工作台导航的纯状态机。所有入口先在副本上归并，再一次性写回 SwiftUI，避免多个
/// `onChange` 在同一帧互相改写 selection、route 和 NavigationStack path。
struct WorkbenchNavigationState: Equatable {
    private(set) var route: WorkbenchRestorationRoute
    private(set) var selection: AppDestination?
    private(set) var compactSessionPath: [AppDestination]
    private(set) var compactWorkspacePath: [AppDestination]
    private(set) var compactSelectedTab: CompactWorkbenchTab
    private(set) var pendingSessionSelectionID: SessionID?

    init(route: WorkbenchRestorationRoute = .sessions) {
        self.route = route
        selection = Self.destination(for: route)
        compactSessionPath = []
        compactWorkspacePath = []
        pendingSessionSelectionID = nil

        switch route {
        case .sessions:
            compactSelectedTab = .sessions
        case .workspaces:
            compactSelectedTab = .workspaces
        case .session(let id, let source):
            let destination = AppDestination.session(id)
            switch source {
            case .sessions:
                compactSelectedTab = .sessions
                compactSessionPath = [destination]
            case .workspaces:
                compactSelectedTab = .workspaces
                compactWorkspacePath = [destination]
            }
        }
    }

    /// selectedSessionID 可能在“我的”或列表页继续保留，不能据此判断会话是否真的可见。
    func visibleSessionID(usesCompactNavigation: Bool) -> SessionID? {
        if usesCompactNavigation, compactSelectedTab == .me {
            return nil
        }
        if usesCompactNavigation {
            let path = compactSelectedTab == .workspaces ? compactWorkspacePath : compactSessionPath
            if case .subagent(_, let childID) = path.last {
                return childID
            }
        }
        guard case .session(let sessionID) = selection else {
            return nil
        }
        return sessionID
    }

    /// 宽屏详情不是一次 push，系统不会自动提供返回工作区的按钮；紧凑布局由外层
    /// `NavigationStack` 管理 path，保留系统返回即可，避免顶栏出现两个返回控件。
    func showsWorkspaceBackButton(usesCompactNavigation: Bool) -> Bool {
        guard !usesCompactNavigation, route.detailSessionID != nil else {
            return false
        }
        return route.rootPage == .workspaces
    }

    @discardableResult
    mutating func reduce(
        _ event: WorkbenchNavigationEvent,
        usesCompactNavigation: Bool,
        selectedSessionID: SessionID?
    ) -> WorkbenchNavigationEffect? {
        switch event {
        case .open(let destination, let requestedSource):
            return open(
                destination,
                requestedSource: requestedSource,
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: selectedSessionID
            )

        case .synchronize(let restoredRoute):
            let preservesMe = isShowingMe(usesCompactNavigation: usesCompactNavigation)
            let preservedPendingSessionID = restoredRoute.detailSessionID == pendingSessionSelectionID
                ? pendingSessionSelectionID
                : nil
            route = restoredRoute
            selection = Self.destination(for: restoredRoute)
            pendingSessionSelectionID = preservedPendingSessionID
            guard usesCompactNavigation else {
                if preservesMe {
                    selection = .me
                }
                return nil
            }
            restoreCompactPath(for: restoredRoute)
            if preservesMe {
                compactSelectedTab = .me
                selection = .me
            }
            return nil

        case .selectionCommitted(let commit):
            let preservesMe = isShowingMe(usesCompactNavigation: usesCompactNavigation)
            pendingSessionSelectionID = nil
            switch commit.reason {
            case .invalidation:
                guard route.detailSessionID != nil else { return nil }
                applyRoot(route.rootPage, usesCompactNavigation: usesCompactNavigation)
                restoreMeIfNeeded(
                    preservesMe,
                    usesCompactNavigation: usesCompactNavigation
                )

            case .identityReplacement(let previousID):
                guard route.detailSessionID == previousID,
                      let sessionID = commit.sessionID else { return nil }
                applySession(
                    sessionID,
                    source: route.rootPage,
                    usesCompactNavigation: usesCompactNavigation,
                    replacesCompactPath: true
                )
                restoreMeIfNeeded(
                    preservesMe,
                    usesCompactNavigation: usesCompactNavigation
                )

            case .restoration:
                // Root 只允许仍与启动快照一致的恢复提交；这里再约束一次，
                // 防止恢复结果把用户后来进入的列表或其他详情重新覆盖。
                guard let sessionID = commit.sessionID,
                      route.detailSessionID == sessionID else { return nil }
                applySession(
                    sessionID,
                    source: route.rootPage,
                    usesCompactNavigation: usesCompactNavigation,
                    replacesCompactPath: true
                )
                restoreMeIfNeeded(
                    preservesMe,
                    usesCompactNavigation: usesCompactNavigation
                )

            case .notification:
                guard let sessionID = commit.sessionID else { return nil }
                applySession(
                    sessionID,
                    source: .sessions,
                    usesCompactNavigation: usesCompactNavigation,
                    replacesCompactPath: false
                )

            case .userOpen:
                guard let sessionID = commit.sessionID else { return nil }
                let source = route.detailSessionID == sessionID
                    ? route.rootPage
                    : (usesCompactNavigation ? activeRootPage : route.rootPage)
                applySession(
                    sessionID,
                    source: source,
                    usesCompactNavigation: usesCompactNavigation,
                    replacesCompactPath: false
                )
            }
            return nil

        case .compactPathChanged(let tab, let path):
            guard tab != .me else { return nil }
            compactSelectedTab = tab
            switch tab {
            case .sessions:
                compactSessionPath = path
            case .workspaces:
                compactWorkspacePath = path
            case .me:
                break
            }

            let destination = path.last ?? Self.rootDestination(for: tab)
            selection = destination
            switch destination {
            case .sessions:
                route = .sessions
                pendingSessionSelectionID = nil
            case .workspaces:
                route = .workspaces
                pendingSessionSelectionID = nil
            case .me:
                break
            case .session(let sessionID):
                route = .session(id: sessionID, source: Self.rootPage(for: tab))
            case .subagent(let parentID, _):
                selection = .session(parentID)
                route = .session(id: parentID, source: Self.rootPage(for: tab))
            }
            return effectForUserNavigation(to: destination, selectedSessionID: selectedSessionID)

        case .compactTabChanged(let tab):
            compactSelectedTab = tab
            guard tab != .me else {
                // “我的”是全局入口，切入时保留当前会话/工作区路由和两个 Tab 的历史栈。
                selection = .me
                return nil
            }
            let path = tab == .sessions ? compactSessionPath : compactWorkspacePath
            let destination = path.last ?? Self.rootDestination(for: tab)
            selection = destination
            switch destination {
            case .sessions:
                route = .sessions
                pendingSessionSelectionID = nil
            case .workspaces:
                route = .workspaces
                pendingSessionSelectionID = nil
            case .me:
                break
            case .session(let sessionID):
                route = .session(id: sessionID, source: Self.rootPage(for: tab))
            case .subagent(let parentID, _):
                selection = .session(parentID)
                route = .session(id: parentID, source: Self.rootPage(for: tab))
            }
            return effectForUserNavigation(to: destination, selectedSessionID: selectedSessionID)

        case .sessionSelectionFinished(let sessionID):
            if pendingSessionSelectionID == sessionID {
                pendingSessionSelectionID = nil
            }
            return nil
        }
    }

    /// “我的”是覆盖在工作台路由之上的全局页面。后台恢复、失效或会话 ID 替换
    /// 可以更新隐藏路由，但不能在没有用户导航意图时把当前页面抢走。
    private mutating func restoreMeIfNeeded(
        _ shouldRestore: Bool,
        usesCompactNavigation: Bool
    ) {
        guard shouldRestore else { return }
        selection = .me
        if usesCompactNavigation {
            compactSelectedTab = .me
        }
    }

    private mutating func open(
        _ destination: AppDestination,
        requestedSource: WorkbenchRootPage?,
        usesCompactNavigation: Bool,
        selectedSessionID: SessionID?
    ) -> WorkbenchNavigationEffect? {
        switch destination {
        case .sessions:
            applyRoot(.sessions, usesCompactNavigation: usesCompactNavigation)
        case .workspaces:
            applyRoot(.workspaces, usesCompactNavigation: usesCompactNavigation)
        case .me:
            selection = .me
            if usesCompactNavigation {
                compactSelectedTab = .me
            }
            return nil
        case .session(let sessionID):
            applySession(
                sessionID,
                source: requestedSource ?? (usesCompactNavigation ? activeRootPage : route.rootPage),
                usesCompactNavigation: usesCompactNavigation,
                replacesCompactPath: false
            )
        case .subagent(let parentID, let childID):
            applySubagent(
                parentID: parentID,
                childID: childID,
                source: requestedSource ?? (usesCompactNavigation ? activeRootPage : route.rootPage),
                usesCompactNavigation: usesCompactNavigation
            )
        }
        return effectForUserNavigation(to: destination, selectedSessionID: selectedSessionID)
    }

    private mutating func applyRoot(
        _ page: WorkbenchRootPage,
        usesCompactNavigation: Bool
    ) {
        pendingSessionSelectionID = nil
        switch page {
        case .sessions:
            route = .sessions
            selection = .sessions
            guard usesCompactNavigation else { return }
            compactSelectedTab = .sessions
            compactSessionPath = []
        case .workspaces:
            route = .workspaces
            selection = .workspaces
            guard usesCompactNavigation else { return }
            compactSelectedTab = .workspaces
            compactWorkspacePath = []
        }
    }

    private mutating func applySession(
        _ sessionID: SessionID,
        source: WorkbenchRootPage,
        usesCompactNavigation: Bool,
        replacesCompactPath: Bool
    ) {
        let destination = AppDestination.session(sessionID)
        route = .session(id: sessionID, source: source)
        selection = destination
        guard usesCompactNavigation else { return }

        switch source {
        case .sessions:
            compactSelectedTab = .sessions
            compactSessionPath = replacesCompactPath
                ? [destination]
                : Self.sessionPath(afterOpening: destination, currentPath: compactSessionPath)
        case .workspaces:
            compactSelectedTab = .workspaces
            compactWorkspacePath = replacesCompactPath
                ? [destination]
                : Self.sessionPath(afterOpening: destination, currentPath: compactWorkspacePath)
        }
    }

    private mutating func restoreCompactPath(for restoredRoute: WorkbenchRestorationRoute) {
        switch restoredRoute {
        case .sessions:
            compactSelectedTab = .sessions
            compactSessionPath = []
        case .workspaces:
            compactSelectedTab = .workspaces
            compactWorkspacePath = []
        case .session(let sessionID, let source):
            applySession(
                sessionID,
                source: source,
                usesCompactNavigation: true,
                replacesCompactPath: true
            )
        }
    }

    private mutating func applySubagent(
        parentID: SessionID,
        childID: SessionID,
        source: WorkbenchRootPage,
        usesCompactNavigation: Bool
    ) {
        let parentDestination = AppDestination.session(parentID)
        let childDestination = AppDestination.subagent(parentID: parentID, childID: childID)
        route = .session(id: parentID, source: source)
        selection = parentDestination
        guard usesCompactNavigation else { return }

        let path = [parentDestination, childDestination]
        switch source {
        case .sessions:
            compactSelectedTab = .sessions
            compactSessionPath = path
        case .workspaces:
            compactSelectedTab = .workspaces
            compactWorkspacePath = path
        }
    }

    private mutating func effectForUserNavigation(
        to destination: AppDestination,
        selectedSessionID: SessionID?
    ) -> WorkbenchNavigationEffect? {
        switch destination {
        case .sessions, .workspaces:
            // 返回列表本身就是显式用户意图；即使当前 ID 已为空也要推进选择代次，
            // 让仍在等待的恢复、通知和创建任务立即失效。
            return .returnToSessionList
        case .me:
            return nil
        case .session(let sessionID):
            guard selectedSessionID != sessionID,
                  pendingSessionSelectionID != sessionID else { return nil }
            // selectSession 包含网络恢复，可能跨帧；记录在途 ID，阻止同一个 UI 事件链重复启动。
            pendingSessionSelectionID = sessionID
            return .selectSession(sessionID)
        case .subagent(let parentID, _):
            guard selectedSessionID != parentID,
                  pendingSessionSelectionID != parentID else { return nil }
            pendingSessionSelectionID = parentID
            return .selectSession(parentID)
        }
    }

    private var activeRootPage: WorkbenchRootPage {
        switch compactSelectedTab {
        case .sessions:
            return .sessions
        case .workspaces:
            return .workspaces
        case .me:
            return route.rootPage
        }
    }

    private func isShowingMe(usesCompactNavigation: Bool) -> Bool {
        usesCompactNavigation ? compactSelectedTab == .me : selection == .me
    }

    private static func destination(for route: WorkbenchRestorationRoute) -> AppDestination {
        switch route {
        case .sessions:
            return .sessions
        case .workspaces:
            return .workspaces
        case .session(let id, _):
            return .session(id)
        }
    }

    private static func rootDestination(for tab: CompactWorkbenchTab) -> AppDestination {
        tab == .workspaces ? .workspaces : .sessions
    }

    private static func rootPage(for tab: CompactWorkbenchTab) -> WorkbenchRootPage {
        tab == .workspaces ? .workspaces : .sessions
    }

    private static func sessionPath(
        afterOpening destination: AppDestination,
        currentPath: [AppDestination]
    ) -> [AppDestination] {
        guard currentPath.last != destination else { return currentPath }

        var updatedPath = currentPath
        if let currentDestination = updatedPath.last,
           Self.isSessionDetailDestination(currentDestination) {
            // local:* 占位切到真实 ID 时替换当前详情，不能再 push 一层。
            updatedPath[updatedPath.index(before: updatedPath.endIndex)] = destination
        } else {
            updatedPath.append(destination)
        }
        return updatedPath
    }

    private static func isSessionDetailDestination(_ destination: AppDestination) -> Bool {
        switch destination {
        case .session, .subagent:
            return true
        case .sessions, .workspaces, .me:
            return false
        }
    }
}

// 工作台通用导航外观与布局组件集中在此，保持各页面结构稳定。
extension View {
    func themedWorkbenchNavigationChrome(tokens: ThemeTokens, colorScheme: ColorScheme) -> some View {
        // 会话工作台嵌在 NavigationSplitView 里，系统导航栏默认会透出平台背景。
        // 这里统一让导航栏和状态栏区域吃主题色，避免 iPad 横屏顶部出现黑色断层。
        //
        // 但底色只在滚动到边缘时才该出现：强制 `.visible` 会钉死一条不透明实色条和一道发丝线，
        // 同时把顶栏按钮压成贴在实色上的图标。这里改为把主题色交给 scroll edge effect，
        // 让系统自己决定何时显形。
        toolbarBackground(tokens.background, for: .navigationBar)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
    }

    /// iOS 26 的 Tab Bar 已经是自带玻璃的浮动胶囊，本身就会模糊身后的内容。此时再强制一层
    /// 可见的 toolbar 背景，等于把旧版整条实心栏重新画回浮动栏后方：顶层列表底部会出现一条
    /// 横贯全宽的明度断层，详情页隐藏 Tab Bar 后它还会继续留在 Composer 后方。
    /// 26 起交给系统绘制，页面背景一路连续到安全区底部；
    /// iOS 18–25 的 Tab Bar 本来就是整条栏，仍用更厚的材质遮住其后的列表文字。
    @ViewBuilder
    func compactTabBarChrome(tokens: ThemeTokens, reduceTransparency: Bool) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            toolbarBackground(
                reduceTransparency
                    ? AnyShapeStyle(tokens.elevatedSurface)
                    : AnyShapeStyle(.ultraThickMaterial),
                for: .tabBar
            )
            .toolbarBackground(.visible, for: .tabBar)
        }
    }
}

extension ConnectionStatus {
    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

struct WorkbenchLayout: Equatable {
    struct ColumnWidth: Equatable {
        let min: CGFloat
        let ideal: CGFloat
        let max: CGFloat
    }

    let projectColumn: ColumnWidth
    let inspectorColumn: ColumnWidth
    let titleMaxWidth: CGFloat
    let usesCompactNavigation: Bool
    let prefersDetailOnly: Bool
    let usesAttachedInspector: Bool
    let usesFloatingSidebarSurface: Bool
    let prefersSessionTableDensity: Bool
    let isPhone: Bool

    var usesSheetInspectorNavigation: Bool {
        !usesCompactNavigation && !usesAttachedInspector
    }

    var usesCompactPhoneNavigationTypography: Bool {
        usesCompactNavigation && isPhone
    }

    init(
        containerWidth: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass?,
        isPad: Bool,
        isPhone: Bool = false
    ) {
        self.isPhone = isPhone
        let usesCompactMetrics = horizontalSizeClass == .compact || containerWidth < 760
        // 768pt 的旧款 iPad mini 竖屏仍是 regular size class，但双栏会自动退成 detail-only。
        // 这类宽度也必须使用真正的 push 导航，否则系统不会提供返回按钮和左缘返回手势。
        let needsCompactNavigation = horizontalSizeClass == .compact
            || containerWidth < WorkbenchSidebarSurfaceMetrics.minimumContainerWidth
        let isTightPadWidth = containerWidth < 980

        if usesCompactMetrics {
            projectColumn = ColumnWidth(min: 220, ideal: 260, max: 300)
            // 手机端维护动作已经收进单一菜单，标题可以获得接近 Claude 的两行阅读宽度。
            titleMaxWidth = max(160, min(230, containerWidth - 160))
        } else if isTightPadWidth {
            projectColumn = ColumnWidth(min: 240, ideal: 280, max: 320)
            titleMaxWidth = 240
        } else {
            projectColumn = ColumnWidth(min: 280, ideal: 330, max: 380)
            titleMaxWidth = 340
        }

        inspectorColumn = containerWidth < 1280
            ? ColumnWidth(min: 280, ideal: 300, max: 320)
            : ColumnWidth(min: 300, ideal: 340, max: 380)

        // 三栏只在真正宽的横向空间里附着；窄窗口改用 sheet，保住会话阅读/输入区域。
        usesAttachedInspector = horizontalSizeClass != .compact && containerWidth >= 1180
        usesCompactNavigation = needsCompactNavigation
        prefersDetailOnly = needsCompactNavigation
        // 只在 iPad 的真实双栏宽度启用浮动表面。设备类型与实际容器宽度共同判定，
        // 避免 iPhone 横屏、Stage Manager 紧凑窗口和 Mac Catalyst 被外观误伤。
        usesFloatingSidebarSurface = isPad
            && horizontalSizeClass == .regular
            && containerWidth >= WorkbenchSidebarSurfaceMetrics.minimumContainerWidth
        // 会话行只按可用宽度选密度，不按设备类型：iPhone 竖屏与 iPad 竖屏读的是同一批对象，
        // 没有理由把项目锚点在手机上缩成 12pt。只有 Slide Over 这类真正窄的窗口才回退 compact。
        prefersSessionTableDensity = containerWidth >= 360
    }
}

enum WorkbenchSidebarSurfaceMetrics {
    static let minimumContainerWidth: CGFloat = 860
    // 与原 NavigationSplitView 的 ideal width 保持一致，避免切换为浮层后顶部信息再次拥挤。
    static let overlayWidth: CGFloat = 300
    static let outerInset: CGFloat = 12
    static let cornerRadius: CGFloat = 18
    // 展开态只从列表末端预留的窄条接管横向拖动；关闭态只捕获屏幕最左侧窄边缘。
    static let openDragStripWidth: CGFloat = 22
    static let openDragStripVerticalInset: CGFloat = 72
    static let closedEdgeDragWidth: CGFloat = 22
    static let closedEdgeDragVerticalInset: CGFloat = 72
}

/// iPad 工作台的图标型操作统一使用同一套光学尺寸；系统工具栏或 ButtonStyle 负责材质与按压反馈。
enum WorkbenchChromeIconMetrics {
    static let symbolSize: CGFloat = 15
    static let symbolFrame: CGFloat = 18
    static let minimumHitTarget: CGFloat = 44
}

struct WorkbenchChromeIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: WorkbenchChromeIconMetrics.symbolSize, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .frame(
                width: WorkbenchChromeIconMetrics.symbolFrame,
                height: WorkbenchChromeIconMetrics.symbolFrame
            )
    }
}

/// 顶栏按钮与工作区项目胶囊共用的扁平磨砂：只有模糊和一层薄色，没有 Liquid Glass
/// 的高光边缘与折射。同一套材质覆盖所有 chrome，避免一屏出现两种玻璃浓度。
/// Reduce Transparency 下退成等价实色，尺寸和圆角都不变。
struct WorkbenchChromeMaterial<ChromeShape: Shape>: View {
    let shape: ChromeShape
    let tokens: ThemeTokens
    /// 0 是普通磨砂，1 是完整选中提亮；中间值服务手势驱动的连续状态过渡。
    var tintLevel: Double = 0

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(tokens.elevatedSurface)
            } else {
                shape.fill(.regularMaterial)
            }

            if tintLevel > 0 {
                // 选中态用中性提亮而不是主题紫填充：这一屏已经有 Codex 和 Claude
                // 两个无法控制的品牌色，再加一块大面积主题色就是三种颜色互相抢。
                // tintLevel 让亮度与横滑进度 1:1 对应，不需要额外的主题色相。
                shape.fill(
                    tokens.primaryText.opacity(
                        (reduceTransparency ? 0.14 : 0.10) * min(max(tintLevel, 0), 1)
                    )
                )
            }
        }
    }
}

extension View {
    /// 顶栏图标按钮统一成 44pt 磨砂圆。调用方仍需在 ToolbarItem 上加
    /// `.sharedBackgroundVisibility(.hidden)`，否则 iPadOS/iOS 26 自动附加的玻璃底板
    /// 会叠在这层磨砂下面，形成两层背景。
    func workbenchChromeCircle(tokens: ThemeTokens) -> some View {
        frame(
            width: WorkbenchChromeIconMetrics.minimumHitTarget,
            height: WorkbenchChromeIconMetrics.minimumHitTarget
        )
        .background { WorkbenchChromeMaterial(shape: Circle(), tokens: tokens) }
        .contentShape(Circle())
    }

    /// 会话滚动边缘统一使用柔和渐隐：顶部正文进入导航控制层、底部正文经过 Composer
    /// 后方时都由系统提供渐进式虚化，不会像 `hard` 那样切出横贯全宽的边界线。
    /// iOS 26 之前没有该效果，保持原样。
    @ViewBuilder
    func workbenchSoftConversationScrollEdges(allowsTopUnderlap: Bool) -> some View {
        if #available(iOS 26.0, *) {
            if allowsTopUnderlap {
                // List 本来就绘制到导航栏后方，安全区只决定“静止时第一行落在哪里”。
                // 这里不能再 ignoresSafeArea(.top)：那会把顶部内边距整个抹掉，静止状态的
                // 首行内容直接顶进导航控制层，加载态的 ProgressView 会和标题副标题叠字。
                // 需要的虚化由 scrollEdgeEffectStyle 在内容真正上滚重叠时提供。
                scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            } else {
                scrollEdgeEffectStyle(.soft, for: .bottom)
            }
        } else {
            self
        }
    }

    /// 非会话列表只需要底部浮动 Chrome 的柔和过渡；保留独立入口，避免普通列表
    /// 因会话页的 top underlap 策略改变自身安全区布局。
    @ViewBuilder
    func workbenchSoftBottomScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self
        }
    }
}

/// 把 iPad 浮动侧栏的纯视觉层级集中在 Chrome 层，业务 Shell 只负责提供内容和路由。
struct WorkbenchSidebarContainer<
    Content: View,
    FloatingHeader: View,
    ToolbarHeader: View
>: View {
    let tokens: ThemeTokens
    let usesFloatingSurface: Bool
    private let content: Content
    private let floatingHeader: FloatingHeader
    private let toolbarHeader: ToolbarHeader

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        tokens: ThemeTokens,
        usesFloatingSurface: Bool,
        @ViewBuilder content: () -> Content,
        @ViewBuilder floatingHeader: () -> FloatingHeader,
        @ViewBuilder toolbarHeader: () -> ToolbarHeader
    ) {
        self.tokens = tokens
        self.usesFloatingSurface = usesFloatingSurface
        self.content = content()
        self.floatingHeader = floatingHeader()
        self.toolbarHeader = toolbarHeader()
    }

    @ViewBuilder
    var body: some View {
        if usesFloatingSurface {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    floatingHeader
                }
                .background(floatingSurfaceBackground)
                .clipShape(sidebarShape)
                .overlay {
                    // 普通对比度依靠内容表面与工作区底色表达层级，避免描边或模糊阴影制造第三层颜色。
                    // Increased Contrast 仍保留明确边界，不能只依赖轻微色差。
                    if colorSchemeContrast == .increased {
                        sidebarShape.stroke(tokens.border, lineWidth: 1)
                    }
                }
                .padding(WorkbenchSidebarSurfaceMetrics.outerInset)
                // 浮层外围保持透明，直接透出同一块工作区背景；不能再绘制独立 sidebar column 底板。
                .toolbar(.hidden, for: .navigationBar)
        } else {
            content
                .background(tokens.sidebarBackground.ignoresSafeArea())
                .toolbar {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .topBarLeading) {
                            toolbarHeader
                        }
                        // 品牌标题不是独立按钮；隐藏 iPadOS 26 自动添加的共享玻璃底板。
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        // iOS 18–25 没有系统共享玻璃底板，保留普通 ToolbarItem 即可。
                        ToolbarItem(placement: .topBarLeading) {
                            toolbarHeader
                        }
                    }
                }
        }
    }

    private var sidebarShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: WorkbenchSidebarSurfaceMetrics.cornerRadius,
            style: .continuous
        )
    }

    private var floatingSurfaceBackground: some View {
        // 大型导航面与普通项目卡复用同一实色；动态玻璃只保留给局部按钮。
        Rectangle()
            .fill(tokens.sidebarSurfaceBackground)
    }
}

/// 真正浮层没有 NavigationSplitView 自动提供的“显示边栏”按钮，这里用系统玻璃与 SF Symbol 补回入口。
struct WorkbenchFloatingSidebarRevealButton: View {
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        WorkbenchFloatingSidebarToggleButton(tokens: tokens, action: action)
            .accessibilityLabel(L10n.text("ui.show_sidebar"))
            .accessibilityIdentifier("sidebar.show")
    }
}

/// 浮动表面隐藏系统侧栏导航栏后，补回同等可达的 44pt 收起入口。
struct WorkbenchFloatingSidebarHeader<Brand: View>: View {
    let tokens: ThemeTokens
    let onCollapse: () -> Void
    private let brand: Brand

    init(
        tokens: ThemeTokens,
        onCollapse: @escaping () -> Void,
        @ViewBuilder brand: () -> Brand
    ) {
        self.tokens = tokens
        self.onCollapse = onCollapse
        self.brand = brand()
    }

    var body: some View {
        HStack(spacing: 4) {
            brand
                .frame(maxWidth: .infinity, alignment: .leading)

            // 收起与展开共用同一个系统玻璃按钮，保证触摸、指针和按压反馈完全一致。
            WorkbenchFloatingSidebarToggleButton(tokens: tokens, action: onCollapse)
                .accessibilityLabel(L10n.text("ui.collapse_conversation_list"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// 结构切换只保留一层系统按钮玻璃；Reduce Transparency 使用等尺寸实色回退。
private struct WorkbenchFloatingSidebarToggleButton: View {
    let tokens: ThemeTokens
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            button
                .buttonStyle(.plain)
                // 把原生交互玻璃直接作用在确定的 44pt 标签上，避免系统 ButtonStyle
                // 根据紧凑图标再次缩小或放大圆面；按压和指针反馈仍由 Liquid Glass 提供。
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            button
                .buttonStyle(.plain)
                .background {
                    if reduceTransparency {
                        Circle().fill(tokens.elevatedSurface)
                    } else {
                        // iOS 18–25 使用稳定的系统材质，不模拟 Liquid Glass 的折射与高光。
                        Circle().fill(.regularMaterial)
                    }
                }
                .overlay {
                    Circle()
                        .stroke(tokens.border, lineWidth: 1)
                }
        }
    }

    private var button: some View {
        Button(action: action) {
            WorkbenchChromeIcon(systemName: "sidebar.left")
                .frame(
                    width: WorkbenchChromeIconMetrics.minimumHitTarget,
                    height: WorkbenchChromeIconMetrics.minimumHitTarget
                )
                .contentShape(Circle())
        }
        .foregroundStyle(tokens.primaryText)
        // 与触控、指针和 VoiceOver 共用同一个 action，不新增第二套 visibility 状态。
        .keyboardShortcut("s", modifiers: [.control, .command])
    }
}

extension View {
    /// 主操作在 iOS 26+ 使用原生突出玻璃；旧系统回退到系统强调按钮，
    /// 只降低材质表现，不改变按钮的 action、禁用态、键盘快捷键或无障碍语义。
    @ViewBuilder
    func workbenchProminentActionStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    func sessionInspectorPresentation(
        isPresented: Binding<Bool>,
        layout: WorkbenchLayout,
        transitionContext: InspectorPresentationContext?,
        presentationNamespace: Namespace.ID,
        relatedSubagent: Binding<SessionContextSubagent?>,
        parentSessionID: Binding<SessionID?>,
        onOpenSubagent: @escaping (SessionContextSubagent) -> Void,
        onCloseRelatedSubagent: @escaping () -> Void,
        onRequestDismiss: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(
            SessionInspectorPresentation(
                isPresented: isPresented,
                layout: layout,
                transitionContext: transitionContext,
                presentationNamespace: presentationNamespace,
                relatedSubagent: relatedSubagent,
                parentSessionID: parentSessionID,
                onOpenSubagent: onOpenSubagent,
                onCloseRelatedSubagent: onCloseRelatedSubagent,
                onRequestDismiss: onRequestDismiss,
                onDismiss: onDismiss
            )
        )
    }
}

struct SessionInspectorPresentation: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var isPresented: Bool
    let layout: WorkbenchLayout
    let transitionContext: InspectorPresentationContext?
    let presentationNamespace: Namespace.ID
    @Binding var relatedSubagent: SessionContextSubagent?
    @Binding var parentSessionID: SessionID?
    let onOpenSubagent: (SessionContextSubagent) -> Void
    let onCloseRelatedSubagent: () -> Void
    let onRequestDismiss: () -> Void
    let onDismiss: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if layout.usesAttachedInspector {
            content.inspector(isPresented: $isPresented) {
                Group {
                    if let relatedSubagent, let parentSessionID {
                        RelatedSessionConversationView(
                            relation: relatedSubagent,
                            parentSessionID: parentSessionID,
                            showsCloseButton: true,
                            onClose: onCloseRelatedSubagent
                        )
                    } else {
                        SessionInspectorView()
                    }
                }
                .inspectorColumnWidth(
                    min: layout.inspectorColumn.min,
                    ideal: layout.inspectorColumn.ideal,
                    max: layout.inspectorColumn.max
                )
                .environment(
                    \.openSubagentSession,
                    OpenSubagentSessionAction(handler: onOpenSubagent)
                )
            }
        } else {
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                transitionedInspectorSheet
            }
        }
    }

    @ViewBuilder
    private var transitionedInspectorSheet: some View {
        // Context 在打开前锁定；展示期间不重新读取布局或 Reduce Motion 来切换 View 结构。
        switch transitionContext?.transition ?? .systemSheet {
        case .systemSheet:
            inspectorSheet
        case .zoom(let sourceID):
            inspectorSheet.navigationTransition(
                .zoom(sourceID: sourceID, in: presentationNamespace)
            )
        }
    }

    private var inspectorSheet: some View {
        NavigationStack {
            SessionInspectorView()
                .environment(
                    \.openSubagentSession,
                    OpenSubagentSessionAction(handler: onOpenSubagent)
                )
                .navigationDestination(
                    isPresented: Binding(
                        get: {
                            layout.usesSheetInspectorNavigation
                                && relatedSubagent != nil
                                && parentSessionID != nil
                        },
                        set: { presented in
                            if !presented, layout.usesSheetInspectorNavigation {
                                onCloseRelatedSubagent()
                            }
                        }
                    )
                ) {
                    if let relatedSubagent, let parentSessionID {
                        RelatedSessionConversationView(
                            relation: relatedSubagent,
                            parentSessionID: parentSessionID,
                            showsCloseButton: false,
                            onClose: {}
                        )
                    }
                }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("ui.complete")) {
                    onRequestDismiss()
                    isPresented = false
                }
            }
        }
        .interactiveDismissDisabled(
            layout.usesSheetInspectorNavigation && relatedSubagent != nil
        )
        .presentationDetents(horizontalSizeClass == .compact ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// 子 Agent 始终保留父会话为主选择，并使用独立订阅读取真实 Thread。
/// iPad 将它放入附着检查器列；iPhone 由外层 NavigationStack 原生 push。
struct RelatedSessionConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let relation: SessionContextSubagent
    let parentSessionID: SessionID
    let showsCloseButton: Bool
    let onClose: () -> Void

    @State private var isLoading = true
    @State private var didFailToLoad = false
    @State private var measuredContentWidth: CGFloat?

    private var childSession: AgentSession? {
        sessionStore.sessionsByID[relation.id]
    }

    private var title: String {
        let nickname = relation.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nickname, !nickname.isEmpty {
            return nickname
        }
        let childTitle = childSession?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let childTitle, !childTitle.isEmpty {
            return childTitle
        }
        return relation.displayName
    }

    private var isReadOnly: Bool {
        childSession?.allowsDirectInput != true || relation.canAcceptDirectInput != true
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        GeometryReader { proxy in
            let width = measuredContentWidth ?? proxy.size.width
            let layout = ConversationLayout(
                containerWidth: width,
                horizontalSizeClass: horizontalSizeClass,
                safeAreaInsets: proxy.safeAreaInsets
            )

            VStack(spacing: 0) {
                relatedHeader(tokens: tokens)
                Divider()
                    .overlay(tokens.border.opacity(0.72))

                ZStack {
                    ConversationTimelineView(layout: layout, sessionID: relation.id)

                    if isLoading {
                        ProgressView(L10n.text("ui.loading"))
                            .controlSize(.regular)
                    } else if didFailToLoad && childSession == nil {
                        ContentUnavailableView(
                            L10n.text("ui.sub_agent"),
                            systemImage: "exclamationmark.triangle",
                            description: Text(L10n.text("ui.sub_agent_unavailable"))
                        )
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { newWidth in
                guard newWidth > 0, measuredContentWidth != newWidth else { return }
                measuredContentWidth = newWidth
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                relatedFooter(tokens: tokens)
            }
            .background(tokens.background.ignoresSafeArea())
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .accessibilityIdentifier("subagent.conversation.\(relation.id)")
        .task(id: relation.id) {
            isLoading = true
            didFailToLoad = false
            let loaded = await sessionStore.prepareRelatedSession(
                relation,
                parentSessionID: parentSessionID
            )
            guard !Task.isCancelled else { return }
            didFailToLoad = loaded == nil
            isLoading = false
        }
        .onDisappear {
            sessionStore.stopRelatedSessionObservation(sessionID: relation.id)
        }
    }

    private func relatedHeader(tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: statusSymbolName)
                        .foregroundStyle(statusColor(tokens: tokens))
                    Text(title)
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let role = relation.role, !role.isEmpty {
                        Text(role)
                    }
                    Text(childSession?.displayStatusText ?? statusText)
                    if isReadOnly {
                        Label(L10n.text("ui.read_only"), systemImage: "lock.fill")
                    }
                }
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(2)

                Text(L10n.text("ui.sub_agent_managed_by_parent"))
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(tokens.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(L10n.text("ui.close"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, showsCloseButton ? 4 : 14)
        .padding(.vertical, 10)
    }

    private func relatedFooter(tokens: ThemeTokens) -> some View {
        Label(
            isReadOnly
                ? L10n.text("ui.sub_agent_managed_read_only")
                : L10n.text("ui.sub_agent_managed_by_parent"),
            systemImage: isReadOnly ? "lock.fill" : "person.2.fill"
        )
        .font(themeStore.uiFont(.caption, weight: .medium))
        .foregroundStyle(tokens.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(tokens.border.opacity(0.72))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var normalizedStatus: String {
        (childSession?.status ?? relation.status ?? "").lowercased()
    }

    private var statusText: String {
        switch normalizedStatus {
        case "active", "running", "inprogress", "in_progress", "started":
            return L10n.text("ui.running")
        case "completed", "complete", "success", "succeeded":
            return L10n.text("ui.complete")
        case "systemerror", "failed":
            return L10n.text("ui.abnormal")
        default:
            return L10n.text("ui.history")
        }
    }

    private var statusSymbolName: String {
        switch normalizedStatus {
        case "active", "running", "inprogress", "in_progress", "started":
            return "circle.fill"
        case "completed", "complete", "success", "succeeded":
            return "checkmark.circle.fill"
        case "systemerror", "failed":
            return "exclamationmark.triangle.fill"
        default:
            return "circle"
        }
    }

    private func statusColor(tokens: ThemeTokens) -> Color {
        switch normalizedStatus {
        case "active", "running", "inprogress", "in_progress", "started":
            return tokens.primaryAction
        case "completed", "complete", "success", "succeeded":
            return .green
        case "systemerror", "failed":
            return .red
        default:
            return tokens.tertiaryText
        }
    }
}

struct WorkbenchPageHeader: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let title: String
    let subtitle: String
    let tokens: ThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(themeStore.uiFont(.title2, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(subtitle)
                .font(themeStore.uiFont(.callout))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum WorkbenchPageLayout {
    static let maxContentWidth: CGFloat = 820
    static let regularPadding: CGFloat = 24
    static let compactPadding: CGFloat = 20
    static let contentPanelPadding: CGFloat = 16
    static let groupedPanelPadding: CGFloat = 14
    static let controlPadding: CGFloat = 10
    static let contentPanelCornerRadius: CGFloat = 22
    static let groupedPanelCornerRadius: CGFloat = 16
    static let controlCornerRadius: CGFloat = 12

    // iOS 26 的浮动 Tab Bar 没有公开可读取的实时高度。这里统一维护其视觉高度，
    // 再叠加设备 safe area 与 20pt 呼吸区，避免三个顶层页面各自猜一套底部留白。
    static let compactTabBarVisualHeight: CGFloat = 64
    static let compactTabBarBreathingRoom: CGFloat = 20
    static let compactTabBarMinimumSafeArea: CGFloat = 20
    static let defaultCompactBottomSafeAreaInset: CGFloat = 34
    static var defaultCompactBottomChromeClearance: CGFloat {
        compactBottomChromeClearance(
            bottomSafeAreaInset: defaultCompactBottomSafeAreaInset
        )
    }
    // 兼容不在紧凑 Tab 容器中的旧页面；顶层三页会使用实时 safe area 计算值。
    static var compactBottomPadding: CGFloat {
        defaultCompactBottomChromeClearance
    }

    static func compactBottomChromeClearance(bottomSafeAreaInset: CGFloat) -> CGFloat {
        compactTabBarVisualHeight
            + max(compactTabBarMinimumSafeArea, bottomSafeAreaInset)
            + compactTabBarBreathingRoom
    }
}

private struct WorkbenchBottomChromeClearanceKey: EnvironmentKey {
    static let defaultValue = WorkbenchPageLayout.defaultCompactBottomChromeClearance
}

private struct WorkbenchHasCompactTabBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var workbenchBottomChromeClearance: CGFloat {
        get { self[WorkbenchBottomChromeClearanceKey.self] }
        set { self[WorkbenchBottomChromeClearanceKey.self] = newValue }
    }

    var workbenchHasCompactTabBar: Bool {
        get { self[WorkbenchHasCompactTabBarKey.self] }
        set { self[WorkbenchHasCompactTabBarKey.self] = newValue }
    }
}

enum WorkbenchSurfaceRole {
    case contentPanel
    case groupedPanel
    case control

    var cornerRadius: CGFloat {
        switch self {
        case .contentPanel:
            WorkbenchPageLayout.contentPanelCornerRadius
        case .groupedPanel:
            WorkbenchPageLayout.groupedPanelCornerRadius
        case .control:
            WorkbenchPageLayout.controlCornerRadius
        }
    }
}

private struct WorkbenchSurfaceModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let tokens: ThemeTokens
    let role: WorkbenchSurfaceRole

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous)

        content
            .background(background, in: shape)
            .overlay {
                shape.stroke(
                    tokens.border.opacity(colorSchemeContrast == .increased ? 1 : 0.72),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                )
            }
    }

    private var background: Color {
        switch role {
        case .contentPanel, .groupedPanel:
            tokens.contentPanelBackground
        case .control:
            tokens.surface.opacity(0.72)
        }
    }
}

extension View {
    func workbenchSurface(tokens: ThemeTokens, role: WorkbenchSurfaceRole) -> some View {
        modifier(WorkbenchSurfaceModifier(tokens: tokens, role: role))
    }
}

struct StatusPill: View {
    enum Kind {
        case success
        case warning
        case neutral
    }

    let text: String
    let kind: Kind
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Text(text)
            .font(themeStore.uiFont(size: 12, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background(tokens: tokens))
            .foregroundStyle(foreground(tokens: tokens))
            .clipShape(Capsule())
    }

    private func background(tokens: ThemeTokens) -> Color {
        switch kind {
        case .success:
            return tokens.success.opacity(0.16)
        case .warning:
            return tokens.warning.opacity(0.18)
        case .neutral:
            return tokens.elevatedSurface
        }
    }

    private func foreground(tokens: ThemeTokens) -> Color {
        switch kind {
        case .success:
            return tokens.success
        case .warning:
            return tokens.warning
        case .neutral:
            return tokens.secondaryText
        }
    }
}

/// 设置页和工作台侧栏共用的额度窗口模型。集中选择规则后，两个入口不会因为
/// 服务端 primary / secondary 槽位变化而展示不同的三个圆环。
struct CombinedUsageItem: Identifiable {
    let runtimeProvider: String
    let providerName: String
    let window: CodexUsageWindowDisplay
    let tint: Color

    var id: String {
        "\(runtimeProvider):\(window.id)"
    }

    static func make(
        codexDisplay: CodexUsageWindowsDisplay,
        claudeDisplay: CodexUsageWindowsDisplay,
        includesClaude: Bool,
        // 三环由外到内依次是 Codex 长窗口、Claude 长窗口、Claude 短窗口。
        // 外环使用青色、中环使用粉色；设置页与左上角入口复用这里，避免图例和圆环错位。
        codexTint: Color = .cyan,
        claudeLongTint: Color = .pink,
        claudeShortTint: Color
    ) -> [CombinedUsageItem] {
        var items: [CombinedUsageItem] = []

        if let codexWindow = preferredLongWindow(in: codexDisplay) {
            items.append(
                CombinedUsageItem(
                    runtimeProvider: "codex",
                    providerName: providerName(for: codexDisplay, fallback: "Codex"),
                    window: codexWindow,
                    tint: codexTint
                )
            )
        }

        if includesClaude, let claudeLongWindow = preferredLongWindow(in: claudeDisplay) {
            items.append(
                CombinedUsageItem(
                    runtimeProvider: "claude",
                    providerName: providerName(for: claudeDisplay, fallback: "Claude"),
                    window: claudeLongWindow,
                    tint: claudeLongTint
                )
            )

            if let claudeShortWindow = preferredShortWindow(
                in: claudeDisplay,
                excluding: claudeLongWindow
            ) {
                items.append(
                    CombinedUsageItem(
                        runtimeProvider: "claude",
                        providerName: providerName(for: claudeDisplay, fallback: "Claude"),
                        window: claudeShortWindow,
                        tint: claudeShortTint
                    )
                )
            }
        }

        return Array(items.prefix(3))
    }

    private static func preferredLongWindow(
        in display: CodexUsageWindowsDisplay
    ) -> CodexUsageWindowDisplay? {
        let dayScaleWindows = display.windows.filter(\.isDayScaleWindow)
        return dayScaleWindows.max(by: durationAscending)
            ?? display.windows.max(by: durationAscending)
    }

    private static func preferredShortWindow(
        in display: CodexUsageWindowsDisplay,
        excluding longWindow: CodexUsageWindowDisplay
    ) -> CodexUsageWindowDisplay? {
        display.windows
            .filter { $0.id != longWindow.id }
            .min(by: durationAscending)
    }

    private static func durationAscending(
        _ lhs: CodexUsageWindowDisplay,
        _ rhs: CodexUsageWindowDisplay
    ) -> Bool {
        (lhs.durationMinutes ?? -1) < (rhs.durationMinutes ?? -1)
    }

    /// 已知产品名统一品牌大小写；协议原值仍保留在 runtimeProvider 中。
    private static func providerName(
        for display: CodexUsageWindowsDisplay,
        fallback: String
    ) -> String {
        switch display.displayName.lowercased() {
        case "codex":
            return "Codex"
        case "claude":
            return "Claude"
        default:
            return display.displayName.isEmpty ? fallback : display.displayName
        }
    }
}

/// 同一套三环图形通过尺寸参数同时服务设置卡片和侧栏紧凑入口。
struct CombinedUsageRingsGraphic: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let items: [CombinedUsageItem]
    let expectedRingCount: Int
    let diameter: CGFloat
    let lineWidth: CGFloat
    var ringSpacing: CGFloat = 8

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let ringCount = min(max(expectedRingCount, items.count), 3)
        let ringStep = (lineWidth + ringSpacing) * 2

        ZStack {
            ForEach(0..<ringCount, id: \.self) { index in
                let ringDiameter = diameter - CGFloat(index) * ringStep

                ZStack {
                    Circle()
                        .stroke(tokens.tertiaryText.opacity(0.18), lineWidth: lineWidth)

                    if index < items.count,
                       let progress = items[index].window.remainingProgress {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                items[index].tint,
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(
                                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1),
                                value: progress
                            )
                    }
                }
                .frame(width: ringDiameter, height: ringDiameter)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}
