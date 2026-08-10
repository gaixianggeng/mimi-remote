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
            errorMessage: sessionStore.errorMessage
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
                ConversationTimelineView(
                    layout: layout,
                    // 固定提示条出现时先保留普通安全区布局，避免 List 的顶部 underlap
                    // 穿到提示条后方。范围只限正常透明度的 iPhone；iPad 与 Reduce
                    // Transparency 继续保留原安全区几何和实色导航层。
                    allowsTopUnderlap: UIDevice.current.userInterfaceIdiom == .phone
                        && !reduceTransparency
                        && model.errorMessage == nil
                        && model.historySavingsNotice == nil
                        && model.quotaNotice == nil
                )
            }
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
                    ComposerView(
                        availableWidth: composerWidth,
                        initialGoalStatusExpanded: initialGoalStatusExpanded
                    )
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
            Image(systemName: "gauge.with.dots.needle.33percent")
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
        ZStack(alignment: .top) {
            if reduceTransparency || UIDevice.current.userInterfaceIdiom != .phone {
                // 辅助功能和 iPad 继续使用确定性实色，避免降低既有可读性。
                tokens.conversationCanvasBackground
            } else {
                // iPhone 只给材质层一个柔和 tint，不再用整块实色截断正文；字形打散
                // 由 Composer 自身的 regularMaterial 完成，避免两层 Material 相互叠加。
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

            // 上沿渐隐避免最后一行在卡片边界处被硬切；透明模式下保持更轻的过渡。
            LinearGradient(
                colors: [
                    .clear,
                    tokens.conversationCanvasBackground.opacity(reduceTransparency ? 1 : 0.32)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 28)
            .offset(y: -28)
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
