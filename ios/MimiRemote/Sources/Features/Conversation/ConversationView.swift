import SwiftUI
import UIKit

struct ConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // 紧凑导航的 Shell 根部统一注入该值，push 出来的会话详情同样继承；宽屏侧栏布局为 false。
    @Environment(\.workbenchHasCompactTabBar) private var usesCompactNavigation
    @Environment(\.workbenchUsesFloatingCapsuleHeader) private var usesFloatingCapsuleHeader
    @Environment(\.phoneConversationKeyboardVisible) private var phoneKeyboardVisible
    @Environment(\.phoneConversationDetailIsActive) private var isPhoneDetailActive
    // 不同 iPadOS 侧栏形态下，detail 的 size 提案和 leading safe area 组合并不一致：
    // 有的版本给整窗宽度并把侧栏记在 safe area，有的已经缩小 size 却仍报告 inset，
    // 纯提案算术会把横屏详情列的宽度重复扣除侧栏而误入紧凑分支。
    // 内容真实排版宽度才是唯一可信来源，提案算术只用于测量到达前的首帧。
    @State private var measuredContentWidth: CGFloat?
    @State private var measuredTopStatusHeight: CGFloat = 0
    @State private var showingWriterConflictSharedGuide = false
    @State private var writerConflictSharedGuideOriginLease: HostSessionLease?
    private let initialGoalStatusExpanded: Bool

    init(initialGoalStatusExpanded: Bool = false) {
        self.initialGoalStatusExpanded = initialGoalStatusExpanded
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let model = ConversationScreenModel(
            selectedSession: sessionStore.selectedSession,
            selectedProject: sessionStore.selectedProject,
            foregroundActivity: sessionStore.selectedForegroundActivity,
            runtimeActivitySnapshot: sessionStore.selectedRuntimeActivitySnapshot,
            historySavingsNotice: sessionStore.selectedHistorySavingsNotice,
            quotaNotice: sessionStore.selectedQuotaNotice,
            webSocketStatus: sessionStore.webSocketStatus,
            // writer 冲突在输入区提供唯一恢复入口；顶部不再重复一条泛化错误。
            // 预热窗口只压住连接探测的失败：那一轮还会自动重试，冷启动直接恢复到会话页时
            // 不该先弹一条随后自己消失的错误条。用户主动发送、审批、重试的失败走同一个
            // errorMessage 通道，必须照常展示，否则点了发送却什么都不显示。
            errorMessage: sessionStore.selectedSessionHasActiveWriterConflict
                || (sessionStore.isEstablishingConnection
                    && sessionStore.errorMessageOrigin == .connectionProbe)
                ? nil
                : sessionStore.errorMessage,
            errorPresentation: sessionStore.errorPresentation
        )

        GeometryReader { proxy in
            let layout = measuredContentWidth.map { width in
                ConversationLayout(
                    containerWidth: width,
                    horizontalSizeClass: horizontalSizeClass
                )
            } ?? ConversationLayout(
                containerWidth: proxy.size.width,
                horizontalSizeClass: horizontalSizeClass,
                safeAreaInsets: proxy.safeAreaInsets
            )
            let composerWidth = min(layout.composerAvailableWidth, layout.composerMaxWidth)
            let hasTopStatusStrip = model.errorPresentation != nil
                || model.historySavingsNotice != nil
                || model.quotaNotice != nil
            // 将详情容器扣除顶部状态条后的实测可用高度传给输入区，由输入区再扣除自身实测高度计算审批卡限高。
            let phoneAvailableDetailHeight: CGFloat? = phoneKeyboardVisible == nil
                ? nil
                : max(0, proxy.size.height - (hasTopStatusStrip ? measuredTopStatusHeight : 0))

            VStack(spacing: 0) {
                topStatusStrip(model: model, layout: layout)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        if abs(measuredTopStatusHeight - height) > 0.5 {
                            measuredTopStatusHeight = height
                        }
                    }
                    // 状态提示只占用自己的布局高度，不能改变导航栏与时间线的材质模式；
                    // List 扩展进顶部安全区后也始终让提示保持在正文之上。
                    .zIndex(1)
                ConversationTimelineView(
                    layout: layout,
                    // 顶部 underlap 只由辅助功能偏好决定；WebSocket 错误、额度提示等
                    // 瞬态业务状态不得切换 List 的 safe-area 几何，否则材质会消失并跳动。
                    allowsTopUnderlap: Self.shouldAllowTopUnderlap(
                        reduceTransparency: reduceTransparency
                    ),
                    // 系统 soft edge 太弱，正文滚到标题后方仍能逐字辨读，紧凑导航再叠一层加深。
                    // 宽屏侧栏布局不叠：详情列顶部被提亮后会比相邻侧栏亮一档，界线压在分栏缝上。
                    // iPhone 悬浮胶囊顶栏也不叠全宽雾带：由居中玻璃胶囊直接折射后方滚过的内容，
                    // 两侧保持清澈以突出悬浮感。
                    deepensTopScrollEdge: usesCompactNavigation && !usesFloatingCapsuleHeader
                )
            }
            // 测量层必须先占满 NavigationStack 实际分配的详情列，再把结果回写给
            // ConversationLayout。若跟随 List / Composer 的 intrinsic width 收缩，
            // 固定宽度的 Composer 会把下一帧继续锁在最小 240pt，形成宽度反馈环。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { width in
                guard width > 0, measuredContentWidth != width else {
                    return
                }
                measuredContentWidth = width
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    Group {
                        if sessionStore.selectedSessionShowsWriterConflictCard {
                            WriterConflictCard(
                                sourceIsRunning: sessionStore.selectedSession?.isRunning == true,
                                availability: sessionStore.selectedWriterConflictForkAvailability,
                                errorMessage: sessionStore.selectedWriterConflictForkErrorMessage,
                                isDuplicating: sessionStore.isDuplicatingSelectedWriterConflictSession,
                                isRetrying: sessionStore.isRetryingSelectedWriterConflict,
                                onFork: {
                                    Task { await sessionStore.duplicateSelectedWriterConflictSession() }
                                },
                                onRecheck: {
                                    Task {
                                        await sessionStore.prepareSelectedWriterConflictForkAvailability(
                                            force: true
                                        )
                                    }
                                },
                                onRetry: {
                                    Task { await sessionStore.retrySelectedSessionWriterAccess() }
                                },
                                onOpenSharedGuide: {
                                    writerConflictSharedGuideOriginLease = sessionStore.selectedWriterConflictLease
                                    showingWriterConflictSharedGuide = true
                                }
                            )
                            .task(id: sessionStore.selectedWriterConflictForkPreparationID) {
                                await sessionStore.prepareSelectedWriterConflictForkAvailability()
                            }
                        } else {
                            ComposerView(
                                availableWidth: composerWidth,
                                initialGoalStatusExpanded: initialGoalStatusExpanded
                            )
                            .environment(\.phoneConversationAvailableHeight, phoneAvailableDetailHeight)
                        }
                    }
                        // 确定宽度阻止固定尺寸的工具按钮反向撑大输入卡和上方目标栏。
                        .frame(width: composerWidth)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, layout.composerHorizontalInset)
                .padding(.top, layout.composerTopPadding)
                .padding(.bottom, phoneKeyboardVisible.map { $0 ? 6 : 8 } ?? layout.composerBottomPadding)
                .background {
                    composerReadabilityBackdrop(tokens: tokens)
                }
                .inAppNoticeComposerAnchor(isActive: phoneKeyboardVisible != nil && isPhoneDetailActive)
            }
            .background(tokens.conversationCanvasBackground.ignoresSafeArea())
            .task(id: isPhoneDetailActive ? sessionStore.selectedSession?.id : nil) {
                guard isPhoneDetailActive else { return }
                await sessionStore.warmSelectedClaudeAuthentication()
            }
            .sheet(
                isPresented: $showingWriterConflictSharedGuide,
                onDismiss: { writerConflictSharedGuideOriginLease = nil }
            ) {
                WriterConflictSharedGuideSheet(
                    sourceIsRunning: sessionStore.selectedSession?.isRunning == true,
                    availability: sessionStore.selectedWriterConflictForkAvailability,
                    status: sessionStore.writerConflictSharedGuideStatus(
                        originLease: writerConflictSharedGuideOriginLease
                    )
                )
            }
        }
    }

    /// 顶部滚动边缘是设备无关的材质语义：iPhone、iPad 竖屏和 iPad 横屏共用同一条
    /// 规则，只有 Reduce Transparency 会退回实色。按 idiom 分叉会让 iPad 横屏永远
    /// 拿不到顶部过渡，正文直接贴着标题滚过去。
    static func shouldAllowTopUnderlap(reduceTransparency: Bool) -> Bool {
        !reduceTransparency
    }

    /// 半透明底衬只有在系统自带 soft scroll edge 时才成立：它最深也只有 10–12%，
    /// 真正把正文虚化掉的是滚动边缘效果。紧凑宽度的 composerBottomPadding 是 0，
    /// 底衬又要一路盖到 home indicator，没有 soft edge 的 iOS 18–25 会让正文
    /// 以近乎全对比度从输入卡下沿滚过去，所以旧系统必须退回实色。
    static func usesTranslucentComposerBackdrop(
        isPhone: Bool,
        reduceTransparency: Bool,
        hasSoftScrollEdge: Bool
    ) -> Bool {
        isPhone && !reduceTransparency && hasSoftScrollEdge
    }

    static var systemProvidesSoftScrollEdge: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    @ViewBuilder
    private func topStatusStrip(model: ConversationScreenModel, layout: ConversationLayout) -> some View {
        if model.errorPresentation != nil
            || model.historySavingsNotice != nil
            || model.quotaNotice != nil {
            statusStripContainer(model: model)
                // 卡片里有「加载完整内容」「重新连接」等按钮，一次性提示落在它下方（#738）。
                .inAppNoticeProtectedRegion()
                .padding(.horizontal, layout.horizontalInset)
                .padding(.top, 10)
                .padding(.bottom, 6)
        }
    }

    private func statusStripContainer(model: ConversationScreenModel) -> some View {
        VStack(spacing: 8) {
            if let notice = model.historySavingsNotice {
                historySavingsBanner(notice)
            }
            if let notice = model.quotaNotice {
                quotaLimitBanner(notice)
            }
            if let presentation = model.errorPresentation {
                // 原先的红色「错误：…」胶囊会把 HTTP / WebSocket 原文直接铺出来，也没有关闭或重试入口。
                ErrorPresentationBanner(
                    presentation: presentation,
                    isReconnecting: sessionStore.isRefreshingSelectedSession,
                    onReconnect: {
                        Task { await sessionStore.retryAfterErrorPresentation() }
                    },
                    onDismiss: { sessionStore.dismissErrorMessage() }
                )
            }
        }
    }

    // 缩略历史、额度、错误三张卡片与轻提示同一套版式（`InlineNoticeCard`，#738），
    // 但留在内容流里常驻：它们表示当前状态或等用户操作，不会自己消失。
    private func historySavingsBanner(_ notice: HistorySavingsNotice) -> some View {
        let tone: InlineNoticeTone
        let systemImage: String?
        switch notice.kind {
        case .loadingFull, .loadingSummary:
            tone = .progress
            systemImage = nil
        case .fullFailed, .summaryFailed:
            tone = .failure
            systemImage = nil
        case .summaryLoaded:
            tone = .neutral
            systemImage = "doc.text.magnifyingglass"
        }
        let canDismiss = notice.kind == .summaryLoaded || notice.kind == .summaryFailed
        return InlineNoticeCard(
            tone: tone,
            systemImage: systemImage,
            title: notice.message,
            // 进行中由图标的进度指示表达，不再放一枚禁用的「加载中」按钮。
            hasActions: notice.kind != .loadingSummary,
            onClose: canDismiss ? { sessionStore.dismissSelectedHistorySavingsNotice() } : nil,
            closeAccessibilityIdentifier: "conversation.historyNotice.close"
        ) {
            historySavingsBannerActions(notice)
        }
        .accessibilityIdentifier("conversation.historyNotice")
    }

    private func quotaLimitBanner(_ notice: CodexQuotaNotice) -> some View {
        InlineNoticeCard(
            tone: .warning,
            systemImage: "speedometer",
            title: notice.title,
            subtitle: notice.message,
            onClose: notice.canDismiss ? { sessionStore.dismissErrorMessage() } : nil,
            closeAccessibilityIdentifier: "conversation.quotaNotice.close"
        ) {
            Button {
                Task {
                    await sessionStore.refreshSelectedUsage()
                }
            } label: {
                Label(L10n.text("ui.refresh_status"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(themeStore.tokens(for: colorScheme).primaryActionForeground)
            .controlSize(.small)
            .disabled(sessionStore.isRefreshingSelectedSession || sessionStore.isLoading)
        }
        .accessibilityIdentifier("conversation.quotaNotice")
    }

    @ViewBuilder
    private func historySavingsBannerActions(_ notice: HistorySavingsNotice) -> some View {
        switch notice.kind {
        case .loadingFull:
            Button {
                Task {
                    await sessionStore.loadSummaryHistoryForSelectedSession()
                }
            } label: {
                Label(L10n.text("ui.view_abbreviated_version_only"), systemImage: "text.justify")
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(themeStore.tokens(for: colorScheme).primaryActionForeground)
            .controlSize(.small)
            .disabled(sessionStore.isRefreshingSelectedSession)

        case .fullFailed:
            Button {
                Task {
                    await sessionStore.loadFullHistoryForSelectedSession()
                }
            } label: {
                Label(L10n.text("ui.retry_full_history"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(themeStore.tokens(for: colorScheme).primaryActionForeground)
            .controlSize(.small)
            .disabled(sessionStore.isRefreshingSelectedSession)

            Button {
                Task {
                    await sessionStore.loadSummaryHistoryForSelectedSession()
                }
            } label: {
                Label(L10n.text("ui.view_abbreviated_version_only"), systemImage: "text.justify")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(sessionStore.isRefreshingSelectedSession)

        case .loadingSummary:
            EmptyView()

        case .summaryLoaded:
            Button {
                Task {
                    await sessionStore.loadFullHistoryForSelectedSession()
                }
            } label: {
                Label(L10n.text("ui.load_full_history"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(themeStore.tokens(for: colorScheme).primaryActionForeground)
            .controlSize(.small)
            .disabled(sessionStore.isRefreshingSelectedSession)

        case .summaryFailed:
            Button {
                Task {
                    await sessionStore.loadSummaryHistoryForSelectedSession()
                }
            } label: {
                Label(L10n.text("ui.try_again_abbreviated_version"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(themeStore.tokens(for: colorScheme).primaryActionForeground)
            .controlSize(.small)
            .disabled(sessionStore.isRefreshingSelectedSession)
        }
    }

    private func composerReadabilityBackdrop(tokens: ThemeTokens) -> some View {
        let usesTranslucentBackdrop = Self.usesTranslucentComposerBackdrop(
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            reduceTransparency: reduceTransparency,
            hasSoftScrollEdge: Self.systemProvidesSoftScrollEdge
        )
        return Group {
            if !usesTranslucentBackdrop {
                // 辅助功能、iPad，以及没有 soft scroll edge 的旧系统都使用确定性实色。
                tokens.conversationCanvasBackground
            } else {
                // 只保留一条连续衰减。此前在 inset 上沿额外拼接 28pt 渐变，交界处会从
                // 32% 背景色突然跳回透明，在深色代码块上形成一条明显的亮带。
                // 字形虚化继续交给 Composer 自身的 Material，避免叠加第二层采样。
                LinearGradient(
                    colors: [
                        .clear,
                        tokens.conversationCanvasBackground.opacity(0.04),
                        tokens.conversationCanvasBackground.opacity(colorScheme == .light ? 0.10 : 0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea(edges: phoneKeyboardVisible == nil ? .bottom : [])
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
