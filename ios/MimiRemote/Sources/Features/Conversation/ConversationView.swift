import SwiftUI
import UIKit

struct ConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // 不同 iPadOS 侧栏形态下，detail 的 size 提案和 leading safe area 组合并不一致：
    // 有的版本给整窗宽度并把侧栏记在 safe area，有的已经缩小 size 却仍报告 inset，
    // 纯提案算术会把横屏详情列的宽度重复扣除侧栏而误入紧凑分支。
    // 内容真实排版宽度才是唯一可信来源，提案算术只用于测量到达前的首帧。
    @State private var measuredContentWidth: CGFloat?
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
            errorMessage: sessionStore.selectedSessionHasActiveWriterConflict ? nil : sessionStore.errorMessage
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

            VStack(spacing: 0) {
                topStatusStrip(model: model, layout: layout)
                    // 状态提示只占用自己的布局高度，不能改变导航栏与时间线的材质模式；
                    // List 扩展进顶部安全区后也始终让提示保持在正文之上。
                    .zIndex(1)
                ConversationTimelineView(
                    layout: layout,
                    // 顶部 underlap 只由辅助功能偏好决定；WebSocket 错误、额度提示等
                    // 瞬态业务状态不得切换 List 的 safe-area 几何，否则材质会消失并跳动。
                    allowsTopUnderlap: Self.shouldAllowTopUnderlap(
                        reduceTransparency: reduceTransparency
                    )
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
                        if sessionStore.selectedSessionHasActiveWriterConflict {
                            WriterConflictCard(
                                sourceIsRunning: sessionStore.selectedSession?.isRunning == true,
                                availability: sessionStore.selectedWriterConflictForkAvailability,
                                errorMessage: sessionStore.selectedWriterConflictForkErrorMessage,
                                isDuplicating: sessionStore.isDuplicatingSelectedWriterConflictSession,
                                isRetrying: sessionStore.webSocketStatus == .connecting,
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
                                onRetry: sessionStore.retrySelectedSessionWriterAccess
                            )
                            .task(id: sessionStore.selectedWriterConflictForkPreparationID) {
                                await sessionStore.prepareSelectedWriterConflictForkAvailability()
                            }
                        } else {
                            ComposerView(
                                availableWidth: composerWidth,
                                initialGoalStatusExpanded: initialGoalStatusExpanded
                            )
                        }
                    }
                        // 确定宽度阻止固定尺寸的工具按钮反向撑大输入卡和上方目标栏。
                        .frame(width: composerWidth)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, layout.composerHorizontalInset)
                .padding(.top, layout.composerTopPadding)
                .padding(.bottom, layout.composerBottomPadding)
                .background {
                    composerReadabilityBackdrop(tokens: tokens)
                }
            }
            .background(tokens.conversationCanvasBackground.ignoresSafeArea())
            .task(id: sessionStore.selectedSession?.id) {
                await sessionStore.warmSelectedClaudeAuthentication()
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
        if model.errorMessage != nil || model.historySavingsNotice != nil || model.quotaNotice != nil {
            statusStripContainer(model: model)
                .padding(.horizontal, layout.horizontalInset)
                .padding(.top, 10)
                .padding(.bottom, 6)
        }
    }

    private func statusStripContainer(model: ConversationScreenModel) -> some View {
        let message = model.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 8) {
            if let notice = model.historySavingsNotice {
                historySavingsBanner(notice)
            }
            if let notice = model.quotaNotice {
                quotaLimitBanner(notice)
            }
            if let message, !message.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    errorChip(message)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func errorChip(_ message: String) -> some View {
        Label(L10n.format("ui.error_value", message), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .font(themeStore.uiFont(.caption, weight: .medium))
            .lineLimit(2)
            .minimumScaleFactor(0.86)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(statusChipBackground)
            .clipShape(Capsule())
    }

    private func historySavingsBanner(_ notice: HistorySavingsNotice) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                historySavingsBannerMessage(notice)
                Spacer(minLength: 0)
                historySavingsBannerActions(notice)
            }
            VStack(alignment: .leading, spacing: 8) {
                historySavingsBannerMessage(notice)
                historySavingsBannerActions(notice)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.elevatedSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tokens.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func historySavingsBannerMessage(_ notice: HistorySavingsNotice) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: notice.kind == .summaryLoaded ? "doc.text.magnifyingglass" : "gauge.with.dots.needle.33percent")
                .font(themeStore.uiFont(.body, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 22, height: 22)
            Text(notice.message)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func quotaLimitBanner(_ notice: CodexQuotaNotice) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                quotaLimitBannerMessage(notice)
                Spacer(minLength: 0)
                quotaLimitBannerActions(notice)
            }
            VStack(alignment: .leading, spacing: 8) {
                quotaLimitBannerMessage(notice)
                quotaLimitBannerActions(notice)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.warning.opacity(0.12))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tokens.warning.opacity(0.42), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func quotaLimitBannerMessage(_ notice: CodexQuotaNotice) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "speedometer")
                .font(themeStore.uiFont(.body, weight: .semibold))
                .foregroundStyle(tokens.warning)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(notice.message)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
            }
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func quotaLimitBannerActions(_ notice: CodexQuotaNotice) -> some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await sessionStore.refreshSelectedUsage()
                }
            } label: {
                Label(L10n.text("ui.refresh_status"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(sessionStore.isRefreshingSelectedSession || sessionStore.isLoading)

            if notice.canDismiss {
                Button {
                    sessionStore.dismissErrorMessage()
                } label: {
                    Label(L10n.text("ui.close"), systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func historySavingsBannerActions(_ notice: HistorySavingsNotice) -> some View {
        HStack(spacing: 8) {
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
                Button {} label: {
                    Label(L10n.text("ui.loading_3667cb10"), systemImage: "hourglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)

            case .summaryLoaded:
                Button {
                    Task {
                        await sessionStore.loadFullHistoryForSelectedSession()
                    }
                } label: {
                    Label(L10n.text("ui.load_full_history"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sessionStore.isRefreshingSelectedSession)

                Button {
                    sessionStore.dismissSelectedHistorySavingsNotice()
                } label: {
                    Label(L10n.text("ui.close"), systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .summaryFailed:
                Button {
                    Task {
                        await sessionStore.loadSummaryHistoryForSelectedSession()
                    }
                } label: {
                    Label(L10n.text("ui.try_again_abbreviated_version"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sessionStore.isRefreshingSelectedSession)

                Button {
                    sessionStore.dismissSelectedHistorySavingsNotice()
                } label: {
                    Label(L10n.text("ui.close"), systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var statusChipBackground: Color {
        themeStore.tokens(for: colorScheme).elevatedSurface
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
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
