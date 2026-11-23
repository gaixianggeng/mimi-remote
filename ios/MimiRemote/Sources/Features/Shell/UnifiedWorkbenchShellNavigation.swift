import SwiftUI
import UIKit

/// iPhone 会话详情页三件式悬浮玻璃顶栏的度量与开关策略。
/// 视觉结构为三块独立悬浮玻璃件：左侧圆形返回按钮、中间水平居中单行标题胶囊（工作区图标 + 标题）、
/// 右侧圆形更多菜单按钮；三者高度一致、垂直居中对齐、视觉完全分离。
enum PhoneSessionFloatingCapsuleMetrics {
    /// 三件统一标准高度（44pt，满足 HIG 触控目标且与左右圆形按钮直径一致）。
    static let itemHeight: CGFloat = 44
    /// 左右独立圆形玻璃按钮直径。
    static let buttonSize: CGFloat = itemHeight
    /// 中间标题胶囊最小高度（与左右按钮等高；大字体下向上自适应而不裁切）。
    static let minimumHeight: CGFloat = itemHeight
    /// 中间标题胶囊固定最大宽度上限；较窄屏幕上按 `min(304, 可用宽度)` 兜底。
    static let maximumWidth: CGFloat = 304
    /// 左右圆形按钮贴屏幕左右边缘的边距。
    static let horizontalScreenMargin: CGFloat = 16
    /// 中间胶囊与左右圆形按钮之间的最小水平间距（至少 8pt，确保三者永不重叠或粘连）。
    static let interItemSpacing: CGFloat = 8
    /// 顶栏距顶部安全区（状态栏 / 动态岛下沿）的呼吸间距。
    static let topPadding: CGFloat = 4
    /// 顶栏底部与列表首条消息之间的呼吸间距。
    static let bottomPadding: CGFloat = 8
    /// 中间胶囊水平内边距（有工作区图标时左侧略紧以匹配圆弧视觉重心，右侧给文字/省略号留足余量）。
    static let centerCapsuleLeadingPaddingWithIcon: CGFloat = 12
    static let centerCapsuleTrailingPaddingWithIcon: CGFloat = 16
    static let centerCapsuleHorizontalPaddingTextOnly: CGFloat = 16
    static let centerCapsuleVerticalPadding: CGFloat = 8
    /// 工作区图标与标题文字之间的水平间距。
    static let iconTitleSpacing: CGFloat = 8
    /// 中间胶囊内工作区图标尺寸。
    static let workspaceIconSize: CGFloat = 24

    /// 仅对 iPhone 紧凑导航启用悬浮玻璃顶栏；iPad（窄窗、竖屏、横屏）保持原有系统导航栏不变。
    static func isEnabled(layout: WorkbenchLayout) -> Bool {
        layout.usesPhoneIntegratedBottomChrome
    }

    /// 计算当前容器宽度下中间胶囊可用的最大空间（扣除左右屏边距、左右按钮及最小间距）。
    static func availableCenterWidth(containerWidth: CGFloat) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else {
            return maximumWidth
        }
        let reserved = (horizontalScreenMargin + buttonSize + interItemSpacing) * 2
        return max(0, containerWidth - reserved)
    }

    /// 计算当前容器宽度下中间胶囊允许的最大宽度，按 `min(304, 可用宽度)` 兜底。
    static func resolvedMaxWidth(containerWidth: CGFloat) -> CGFloat {
        min(maximumWidth, availableCenterWidth(containerWidth: containerWidth))
    }

    /// 胶囊圆角始终等于高度一半。
    static func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        height / 2
    }
}

/// 供布局回归测试读取的三件式悬浮顶栏真实渲染几何（顶栏容器局部坐标系）。
struct PhoneSessionFloatingHeaderLayoutSnapshot: Equatable {
    var containerWidth: CGFloat = 0
    var backButtonFrame: CGRect = .zero
    var centerCapsuleFrame: CGRect = .zero
    var moreButtonFrame: CGRect = .zero

    var isComplete: Bool {
        containerWidth > 0
            && backButtonFrame.width > 0
            && centerCapsuleFrame.width > 0
            && moreButtonFrame.width > 0
    }
}

/// 顶栏标题、副标题与工作区图标的展示数据，供 iPad 原生导航栏与 iPhone 悬浮顶栏共用。
struct SessionNavigationTitleDisplayData {
    let title: String
    let subtitle: String
    let showsStatus: Bool
    let subtitleColor: Color
    let subtitleFont: Font
    let accessibilityValue: String
    let workspaceIcon: WorkspaceProjectIconContent?
}

/// iPhone 会话详情页三件式悬浮玻璃顶栏：
/// 左侧独立圆形返回按钮、中间独立居中标题胶囊（仅含工作区图标 + 单行截断标题）、右侧独立圆形更多菜单按钮。
/// 三者高度一致、垂直居中对齐，按系统版本自动采用 iOS 26 Liquid Glass、旧版 `.ultraThinMaterial` 或减少透明度实色。
struct PhoneSessionFloatingCapsuleHeader<MoreMenuContent: View>: View {
    private static var coordinateSpaceName: String { "phoneSessionFloatingHeader" }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let data: SessionNavigationTitleDisplayData
    let tokens: ThemeTokens
    let availableWidth: CGFloat
    let isMenuDisabled: Bool
    let onBack: () -> Void
    let onMeasuredLayout: ((PhoneSessionFloatingHeaderLayoutSnapshot) -> Void)?
    private let moreMenuContent: MoreMenuContent

    @State private var measuredSnapshot = PhoneSessionFloatingHeaderLayoutSnapshot()

    init(
        data: SessionNavigationTitleDisplayData,
        tokens: ThemeTokens,
        availableWidth: CGFloat,
        isMenuDisabled: Bool,
        onBack: @escaping () -> Void,
        onMeasuredLayout: ((PhoneSessionFloatingHeaderLayoutSnapshot) -> Void)? = nil,
        @ViewBuilder moreMenuContent: () -> MoreMenuContent
    ) {
        self.data = data
        self.tokens = tokens
        self.availableWidth = availableWidth
        self.isMenuDisabled = isMenuDisabled
        self.onBack = onBack
        self.onMeasuredLayout = onMeasuredLayout
        self.moreMenuContent = moreMenuContent()
    }

    private var centerCapsuleMaxWidth: CGFloat {
        PhoneSessionFloatingCapsuleMetrics.resolvedMaxWidth(containerWidth: availableWidth)
    }

    var body: some View {
        headerRowContainer
            .padding(.horizontal, PhoneSessionFloatingCapsuleMetrics.horizontalScreenMargin)
            .padding(.top, PhoneSessionFloatingCapsuleMetrics.topPadding)
            .padding(.bottom, PhoneSessionFloatingCapsuleMetrics.bottomPadding)
            .coordinateSpace(name: Self.coordinateSpaceName)
            .background {
                if onMeasuredLayout != nil {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { updateMeasuredContainerWidth(proxy.size.width) }
                            .onChange(of: proxy.size.width) { _, newWidth in
                                updateMeasuredContainerWidth(newWidth)
                            }
                    }
                }
            }
            // 隐藏系统导航栏后，登记悬浮顶栏下沿作为应用内顶部提示的保护边界，防止提示条压住顶栏。
            .inAppNoticeProtectedRegion()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sessionDetail.floatingCapsuleHeader")
    }

    @ViewBuilder
    private var headerRowContainer: some View {
        if !reduceTransparency, #available(iOS 26.0, *) {
            // spacing: 0 让三件共享同一组 Liquid Glass 渲染通道，同时严格保持三块分离形状不粘连。
            GlassEffectContainer(spacing: 0) {
                headerRow
            }
        } else {
            headerRow
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 0) {
            backButton
                .background { frameReporter { updateMeasuredBackFrame($0) } }

            Spacer(minLength: PhoneSessionFloatingCapsuleMetrics.interItemSpacing)

            centerTitleCapsule
                .background { frameReporter { updateMeasuredCenterFrame($0) } }
                .frame(maxWidth: centerCapsuleMaxWidth, alignment: .center)
                .layoutPriority(0)

            Spacer(minLength: PhoneSessionFloatingCapsuleMetrics.interItemSpacing)

            moreMenuButton
                .background { frameReporter { updateMeasuredMoreFrame($0) } }
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            WorkbenchChromeIcon(systemName: "chevron.backward")
                .foregroundStyle(tokens.primaryText.opacity(0.92))
                .frame(
                    width: PhoneSessionFloatingCapsuleMetrics.buttonSize,
                    height: PhoneSessionFloatingCapsuleMetrics.buttonSize
                )
                .contentShape(Circle())
                .modifier(
                    PhoneFloatingGlassChromeModifier(
                        shape: Circle(),
                        tokens: tokens,
                        colorScheme: colorScheme,
                        reduceTransparency: reduceTransparency,
                        interactive: true
                    )
                )
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .fixedSize()
        .layoutPriority(1)
        .accessibilityLabel(L10n.text("ui.return_to_previous_level"))
        .accessibilityIdentifier("sessionDetail.back")
    }

    private var centerTitleCapsule: some View {
        let hasIcon = data.workspaceIcon != nil
        let leadingPadding = hasIcon
            ? PhoneSessionFloatingCapsuleMetrics.centerCapsuleLeadingPaddingWithIcon
            : PhoneSessionFloatingCapsuleMetrics.centerCapsuleHorizontalPaddingTextOnly
        let trailingPadding = hasIcon
            ? PhoneSessionFloatingCapsuleMetrics.centerCapsuleTrailingPaddingWithIcon
            : PhoneSessionFloatingCapsuleMetrics.centerCapsuleHorizontalPaddingTextOnly

        return HStack(spacing: PhoneSessionFloatingCapsuleMetrics.iconTitleSpacing) {
            if let workspaceIcon = data.workspaceIcon {
                WorkspaceProjectIconTile(
                    content: workspaceIcon,
                    size: PhoneSessionFloatingCapsuleMetrics.workspaceIconSize,
                    tokens: tokens
                )
                .fixedSize()
            }

            Text(data.title)
                .font(.headline)
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .padding(.vertical, PhoneSessionFloatingCapsuleMetrics.centerCapsuleVerticalPadding)
        .frame(minHeight: PhoneSessionFloatingCapsuleMetrics.minimumHeight)
        .clipShape(Capsule())
        .modifier(
            PhoneFloatingGlassChromeModifier(
                shape: Capsule(),
                tokens: tokens,
                colorScheme: colorScheme,
                reduceTransparency: reduceTransparency,
                interactive: false
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(data.title)
        .accessibilityValue(data.accessibilityValue)
        .accessibilityIdentifier("sessionDetail.title")
    }

    private var moreMenuButton: some View {
        Menu {
            moreMenuContent
        } label: {
            WorkbenchChromeIcon(systemName: "ellipsis")
                .foregroundStyle(tokens.primaryText.opacity(0.92))
                .frame(
                    width: PhoneSessionFloatingCapsuleMetrics.buttonSize,
                    height: PhoneSessionFloatingCapsuleMetrics.buttonSize
                )
                .contentShape(Circle())
                .modifier(
                    PhoneFloatingGlassChromeModifier(
                        shape: Circle(),
                        tokens: tokens,
                        colorScheme: colorScheme,
                        reduceTransparency: reduceTransparency,
                        interactive: true
                    )
                )
        }
        .menuOrder(.fixed)
        .disabled(isMenuDisabled)
        .fixedSize()
        .layoutPriority(1)
        .accessibilityLabel(L10n.text("ui.options"))
        .accessibilityIdentifier("sessionDetail.more")
    }

    @ViewBuilder
    private func frameReporter(_ report: @escaping (CGRect) -> Void) -> some View {
        if onMeasuredLayout != nil {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(Self.coordinateSpaceName))
                Color.clear
                    .onAppear { report(frame) }
                    .onChange(of: frame) { _, newFrame in
                        report(newFrame)
                    }
            }
        }
    }

    private func updateMeasuredContainerWidth(_ width: CGFloat) {
        guard measuredSnapshot.containerWidth != width else { return }
        measuredSnapshot.containerWidth = width
        emitMeasuredLayoutIfReady()
    }

    private func updateMeasuredBackFrame(_ frame: CGRect) {
        guard measuredSnapshot.backButtonFrame != frame else { return }
        measuredSnapshot.backButtonFrame = frame
        emitMeasuredLayoutIfReady()
    }

    private func updateMeasuredCenterFrame(_ frame: CGRect) {
        guard measuredSnapshot.centerCapsuleFrame != frame else { return }
        measuredSnapshot.centerCapsuleFrame = frame
        emitMeasuredLayoutIfReady()
    }

    private func updateMeasuredMoreFrame(_ frame: CGRect) {
        guard measuredSnapshot.moreButtonFrame != frame else { return }
        measuredSnapshot.moreButtonFrame = frame
        emitMeasuredLayoutIfReady()
    }

    private func emitMeasuredLayoutIfReady() {
        guard let onMeasuredLayout, measuredSnapshot.isComplete else { return }
        onMeasuredLayout(measuredSnapshot)
    }
}

/// 三件式悬浮顶栏统一玻璃材质：
/// iOS 26 采用原生 Liquid Glass；旧系统采用 `.ultraThinMaterial` + 细描边 + 轻阴影；
/// 开启减少透明度时退回实色表面以保持可读性。
private struct PhoneFloatingGlassChromeModifier<ChromeShape: InsettableShape>: ViewModifier {
    let shape: ChromeShape
    let tokens: ThemeTokens
    let colorScheme: ColorScheme
    let reduceTransparency: Bool
    let interactive: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(tokens.elevatedSurface, in: shape)
                .overlay {
                    shape
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
            content
                .glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: shape
                )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape
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
}

/// 隐藏系统导航栏后，确保 `NavigationStack` 底层 `UINavigationController` 仍保持系统原生交互式返回可用。
/// iOS 26 起系统同时使用 `interactivePopGestureRecognizer`（左缘）与
/// `interactiveContentPopGestureRecognizer`（内容区右滑）；当 `isNavigationBarHidden == true` 时，
/// UIKit 默认代理 `_UINavigationInteractiveTransition` 会通过 `_shouldInteractivePopGestureBeEnabled`
/// 拒绝这两条手势。这里仅在当前详情页位于栈顶时接管代理，保留系统原生转场动画、跟手进度与中途取消语义，
/// 并在离开栈顶或销毁时恢复系统原代理。
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
        private weak var previousEdgeDelegate: (any UIGestureRecognizerDelegate)?
        private weak var previousContentDelegate: (any UIGestureRecognizerDelegate)?
        private var didOverrideDelegates = false

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent == nil {
                restoreIfNeeded()
            } else {
                attachIfPossible()
            }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            attachIfPossible()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attachIfPossible()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            attachIfPossible()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // 交互式右滑返回一旦开始，UIKit 就会立即触发 viewWillDisappear；
            // 此时不能提前恢复代理，否则中途松手取消后可能失去接管。
            transitionCoordinator?.notifyWhenInteractionChanges { [weak self] context in
                guard let self, context.isCancelled else { return }
                self.attachIfPossible()
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            guard let nav = observedNavigationController else { return }
            let stackEntry = stackEntryViewController(in: nav)
            let isStillTopOfStack = stackEntry != nil && nav.topViewController === stackEntry
            if isMovingFromParent || navigationController == nil || !isStillTopOfStack {
                restoreIfNeeded()
            }
        }

        func attachIfPossible() {
            guard let nav = navigationController else {
                return
            }
            if let stackEntry = stackEntryViewController(in: nav),
               nav.topViewController !== stackEntry {
                return
            }

            if observedNavigationController !== nav {
                restoreIfNeeded()
                observedNavigationController = nav
                if let edgeGesture = nav.interactivePopGestureRecognizer,
                   !(edgeGesture.delegate is Controller) {
                    previousEdgeDelegate = edgeGesture.delegate
                }
                if #available(iOS 26.0, *),
                   let contentGesture = nav.interactiveContentPopGestureRecognizer,
                   !(contentGesture.delegate is Controller) {
                    previousContentDelegate = contentGesture.delegate
                }
                didOverrideDelegates = true
            }

            let canPop = nav.viewControllers.count > 1
            if let edgeGesture = nav.interactivePopGestureRecognizer {
                edgeGesture.delegate = self
                edgeGesture.isEnabled = canPop
            }
            if #available(iOS 26.0, *),
               let contentGesture = nav.interactiveContentPopGestureRecognizer {
                contentGesture.delegate = self
                contentGesture.isEnabled = canPop
            }
        }

        func restoreIfNeeded() {
            guard didOverrideDelegates,
                  let nav = observedNavigationController else {
                return
            }
            if let edgeGesture = nav.interactivePopGestureRecognizer,
               edgeGesture.delegate === self {
                edgeGesture.delegate = previousEdgeDelegate
            }
            if #available(iOS 26.0, *),
               let contentGesture = nav.interactiveContentPopGestureRecognizer,
               contentGesture.delegate === self {
                contentGesture.delegate = previousContentDelegate
            }
            didOverrideDelegates = false
            observedNavigationController = nil
            previousEdgeDelegate = nil
            previousContentDelegate = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav = observedNavigationController ?? navigationController,
                  nav.viewControllers.count > 1,
                  nav.transitionCoordinator == nil else {
                return false
            }
            if let stackEntry = stackEntryViewController(in: nav),
               nav.topViewController !== stackEntry {
                return false
            }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let translation = pan.translation(in: pan.view)
                let isRTL = nav.view.effectiveUserInterfaceLayoutDirection == .rightToLeft
                let isEdgeGesture = gestureRecognizer === nav.interactivePopGestureRecognizer
                return Self.shouldBeginInteractivePop(
                    translation: translation,
                    isRTL: isRTL,
                    isEdgeGesture: isEdgeGesture
                )
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let nav = observedNavigationController ?? navigationController,
                  nav.viewControllers.count > 1 else {
                return false
            }
            if gestureRecognizer === nav.interactivePopGestureRecognizer {
                return true
            }
            return Self.shouldContentPopReceiveTouch(on: touch.view, boundedBy: nav.view)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let nav = observedNavigationController ?? navigationController else {
                return false
            }
            // 左缘返回手势优先于列表滚动及其他平移手势，防止 List 抢占左缘右滑。
            if gestureRecognizer === nav.interactivePopGestureRecognizer,
               otherGestureRecognizer is UIPanGestureRecognizer {
                return true
            }
            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let nav = observedNavigationController ?? navigationController else {
                return false
            }
            if #available(iOS 26.0, *),
               gestureRecognizer === nav.interactiveContentPopGestureRecognizer {
                if otherGestureRecognizer === nav.interactivePopGestureRecognizer {
                    return true
                }
                if let scrollView = otherGestureRecognizer.view as? UIScrollView,
                   otherGestureRecognizer === scrollView.panGestureRecognizer {
                    let isRTL = nav.view.effectiveUserInterfaceLayoutDirection == .rightToLeft
                    return Self.shouldYieldToHorizontalScrollView(scrollView, isRTL: isRTL)
                }
            }
            return false
        }

        static func shouldBeginInteractivePop(
            translation: CGPoint,
            isRTL: Bool,
            isEdgeGesture: Bool
        ) -> Bool {
            let primaryDelta = isRTL ? -translation.x : translation.x
            guard primaryDelta >= 0 else { return false }
            if isEdgeGesture {
                return true
            }
            // 与 UIKit `_UINavigationInteractiveTransition.gestureRecognizerShouldBegin:` 保持一致：
            // 触发初期 translation 可能仍为 (0, 0)（由 `_UIParallaxTransitionPanGestureRecognizer`
            // 内部 hysteresis 与 `exceededYTranslation` 先行把关）；已有位移时要求水平分量不小于纵向，
            // 避免内容区手势劫持列表纵向滚动。
            return abs(translation.x) >= abs(translation.y)
        }

        static func shouldContentPopReceiveTouch(
            on touchedView: UIView?,
            boundedBy containerView: UIView?
        ) -> Bool {
            var current = touchedView
            while let view = current, view !== containerView {
                if view is UISlider || view is UISwitch {
                    return false
                }
                if let textField = view as? UITextField, textField.isFirstResponder {
                    return false
                }
                if let textView = view as? UITextView, textView.isEditable || textView.isSelectable {
                    return false
                }
                current = view.superview
            }
            return true
        }

        static func shouldYieldToHorizontalScrollView(
            _ scrollView: UIScrollView,
            isRTL: Bool
        ) -> Bool {
            guard scrollView.isScrollEnabled,
                  scrollView.contentSize.width > scrollView.bounds.width + 1 else {
                return false
            }
            if isRTL {
                let maxOffsetX = scrollView.contentSize.width
                    - scrollView.bounds.width
                    + scrollView.adjustedContentInset.right
                return scrollView.contentOffset.x < maxOffsetX - 1
            }
            let minOffsetX = -scrollView.adjustedContentInset.left
            return scrollView.contentOffset.x > minOffsetX + 1
        }

        private func stackEntryViewController(in nav: UINavigationController) -> UIViewController? {
            var current: UIViewController? = self
            while let candidate = current {
                if candidate.parent === nav {
                    return candidate
                }
                current = candidate.parent
            }
            return nil
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

    func phoneSessionDetailFloatingCapsuleHeader<MoreMenuContent: View>(
        session: AgentSession?,
        canPresentSessionDetail: Bool,
        isDetailActiveOnScreen: Bool,
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        onBack: @escaping () -> Void,
        @ViewBuilder moreMenuContent: @escaping () -> MoreMenuContent
    ) -> some View {
        // 中间胶囊仅展示工作区图标与单行标题，无需秒级定时刷新副标题；状态摘要仍保留在无障碍值中。
        PhoneSessionFloatingCapsuleHeader(
            data: sessionNavigationTitleDisplayData(
                session: session,
                usesSelectedSessionState: canPresentSessionDetail,
                layout: layout,
                tokens: tokens,
                now: Date()
            ),
            tokens: tokens,
            availableWidth: layout.containerWidth,
            isMenuDisabled: !canPresentSessionDetail,
            onBack: onBack,
            moreMenuContent: moreMenuContent
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
