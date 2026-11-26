import SwiftUI

/// 未连接任何电脑时，工作台各入口共享的真实空态语义。
enum UnpairedHostEmptyStateContext: String {
    case sessions
    case workspaces
    case sidebar

    var accessibilityIdentifier: String {
        "unpairedHostEmptyState.\(rawValue)"
    }

    var connectActionAccessibilityIdentifier: String {
        "unpairedHostEmptyState.\(rawValue).connectComputer"
    }

    var descriptionKey: String {
        switch self {
        case .sessions:
            return "ui.no_host_sessions_description"
        case .workspaces:
            return "ui.no_host_workspaces_description"
        case .sidebar:
            return "ui.no_host_sidebar_description"
        }
    }

    var symbolName: String {
        switch self {
        case .sessions:
            return "desktopcomputer"
        case .workspaces:
            return "folder.badge.gearshape"
        case .sidebar:
            return "desktopcomputer"
        }
    }
}

/// 本地无已配对主机且无待恢复凭据时，在会话页、工作区页与侧栏展示的统一空态。
///
/// 设计约束：
/// - 复用既有 `ui.connect_computer` 入口语义，引导回连接/设备页而不触发任何后台网络请求。
/// - 所有可交互控件保证不小于 44×44 pt 命中区并显式声明 `.contentShape(Rectangle())`。
/// - 文本与按钮通过 `@ScaledMetric` 响应动态字号，在 AX2/AX3 下完整换行与滚动，不做单行截断。
struct UnpairedHostEmptyStateView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ScaledMetric(relativeTo: .title3) private var titleFontSize: CGFloat = 20
    @ScaledMetric(relativeTo: .callout) private var bodyFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var compactTitleFontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var footnoteFontSize: CGFloat = 13

    let context: UnpairedHostEmptyStateContext
    var bottomContentMargin: CGFloat = 0
    var onConnectComputer: (() -> Void)?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if context == .sidebar {
                sidebarCard(tokens: tokens)
            } else {
                fullPageLayout(tokens: tokens)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(context.accessibilityIdentifier)
    }

    private func fullPageLayout(tokens: ThemeTokens) -> some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                fullPageContent(tokens: tokens)
                Spacer(minLength: 24)
            }
            .padding(.bottom, bottomContentMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView {
                fullPageContent(tokens: tokens)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .padding(.bottom, max(24, bottomContentMargin))
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.workbenchCanvasBackground.ignoresSafeArea())
    }

    private func fullPageContent(tokens: ThemeTokens) -> some View {
        VStack(spacing: 18) {
            Image(systemName: context.symbolName)
                .font(themeStore.uiFont(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.accentText)
                .frame(width: 64, height: 64)
                .background(
                    tokens.accentText.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(L10n.text("ui.no_host_connected_title"))
                    .font(themeStore.uiFont(size: titleFontSize, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text(L10n.text(context.descriptionKey))
                    .font(themeStore.uiFont(size: bodyFontSize))
                    .foregroundStyle(tokens.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let onConnectComputer {
                connectButton(
                    tokens: tokens,
                    fillsWidth: dynamicTypeSize.isAccessibilitySize,
                    usesCompactShape: dynamicTypeSize.isAccessibilitySize,
                    action: onConnectComputer
                )
            }

            Text(L10n.text("ui.no_host_connect_hint"))
                .font(themeStore.uiFont(size: footnoteFontSize))
                .foregroundStyle(tokens.tertiaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 540 : 440)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private func sidebarCard(tokens: ThemeTokens) -> some View {
        let iconBadge = Image(systemName: context.symbolName)
            .font(themeStore.uiFont(size: 16, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tokens.accentText)
            .frame(width: 34, height: 34)
            .background(
                tokens.accentText.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityHidden(true)

        let textColumn = VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("ui.no_host_connected_title"))
                .font(themeStore.uiFont(size: compactTitleFontSize, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.text(context.descriptionKey))
                .font(themeStore.uiFont(size: footnoteFontSize))
                .foregroundStyle(tokens.secondaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }

        return VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    iconBadge
                    textColumn
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    iconBadge
                    textColumn
                }
            }

            if let onConnectComputer {
                connectButton(
                    tokens: tokens,
                    fillsWidth: true,
                    usesCompactShape: true,
                    action: onConnectComputer
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tokens.elevatedSurface.opacity(colorScheme == .dark ? 0.78 : 0.94),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tokens.border.opacity(0.65), lineWidth: 1)
        }
    }

    private func connectButton(
        tokens: ThemeTokens,
        fillsWidth: Bool,
        usesCompactShape: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: usesCompactShape ? 14 : 24,
            style: .continuous
        )
        let actionFontSize = context == .sidebar ? compactTitleFontSize : bodyFontSize

        return Button(action: action) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .accessibilityHidden(true)
                    Text(L10n.text("ui.connect_computer"))
                        .fixedSize(horizontal: true, vertical: true)
                }

                VStack(spacing: 4) {
                    Image(systemName: "qrcode.viewfinder")
                        .accessibilityHidden(true)
                    Text(L10n.text("ui.connect_computer"))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(themeStore.uiFont(size: actionFontSize, weight: .semibold))
            .foregroundStyle(tokens.primaryActionForeground)
            .padding(.horizontal, context == .sidebar ? 14 : 20)
            .padding(.vertical, 12)
            .frame(minWidth: 44, minHeight: 44)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background(tokens.primaryAction, in: shape)
            .contentShape(Rectangle())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityIdentifier(context.connectActionAccessibilityIdentifier)
    }
}
