import SwiftUI

enum HostInstallationPlatform: String, CaseIterable, Identifiable {
    case mac
    case windows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mac:
            "Mac"
        case .windows:
            "Windows"
        }
    }

    var installTitle: String {
        switch self {
        case .mac:
            L10n.text("ui.install_mimi_remote_mac")
        case .windows:
            L10n.text("ui.install_mimi_remote_windows")
        }
    }

    var installationDetail: String {
        switch self {
        case .mac:
            L10n.text("ui.mac_installer_requirements_and_instructions")
        case .windows:
            L10n.text("ui.windows_installer_requirements_and_instructions")
        }
    }

    var shareTitle: String {
        switch self {
        case .mac:
            L10n.text("ui.send_download_link_to_mac")
        case .windows:
            L10n.text("ui.send_download_link_to_windows")
        }
    }

    var installerURL: URL {
        switch self {
        case .mac:
            AppExternalLinks.macInstaller
        case .windows:
            AppExternalLinks.windowsRelease
        }
    }

    var releaseURL: URL {
        switch self {
        case .mac:
            AppExternalLinks.macRelease
        case .windows:
            AppExternalLinks.windowsRelease
        }
    }
}

/// 安装说明放在添加电脑模块中，两处连接页面保持相同的展开方式。
/// 平台选择只改变远端安装入口；配对和凭据处理继续复用同一条安全链路。
struct HostInstallationSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @StateObject private var transientPreferences: SettingsTransientPreferences

    init(transientPreferences: SettingsTransientPreferences? = nil) {
        _transientPreferences = StateObject(
            wrappedValue: transientPreferences ?? SettingsTransientPreferences()
        )
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        DisclosureGroup(isExpanded: $transientPreferences.isHostInstallationExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                Picker(
                    L10n.text("ui.computer_platform"),
                    selection: $transientPreferences.hostInstallationPlatform
                ) {
                    ForEach(HostInstallationPlatform.allCases) { platform in
                        Text(platform.title).tag(platform)
                    }
                }
                .pickerStyle(.segmented)
                .tint(tokens.accent)
                .accessibilityIdentifier("settings.hostInstaller.platform")

                VStack(alignment: .leading, spacing: 6) {
                    Text(transientPreferences.hostInstallationPlatform.installTitle)
                        .font(themeStore.uiFont(.body, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)

                    Text(transientPreferences.hostInstallationPlatform.installationDetail)
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.hostInstaller.installationDetail")

                Link(destination: transientPreferences.hostInstallationPlatform.releaseURL) {
                    HStack(spacing: 12) {
                        // 品牌资源保持官方黑白原色，不跟随 App 的主题色染色。
                        Image("GitHubInvertocat")
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: SettingsLayoutMetrics.iconSlot, height: SettingsLayoutMetrics.iconSlot)
                            .accessibilityHidden(true)

                        Text(L10n.text("ui.view_releases_on_github"))
                            .font(themeStore.uiFont(.body))
                            .foregroundStyle(tokens.primaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        Image(systemName: "arrow.up.right")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .settingsRow()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.view_releases_on_github"))
                .accessibilityHint(L10n.text("ui.github_release_accessibility_hint"))
                .accessibilityIdentifier("settings.hostInstaller.githubRelease")

                ShareLink(item: transientPreferences.hostInstallationPlatform.installerURL) {
                    ConnectionActionLabel(
                        title: transientPreferences.hostInstallationPlatform.shareTitle,
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.bordered)
                .tint(tokens.secondaryText)
                .controlSize(.large)
                .accessibilityIdentifier("settings.hostInstaller.share")
                Text(L10n.text("ui.select_code_directory_then_computer_shows_qr"))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
        } label: {
            ConnectionRowLabel(title: L10n.text("ui.first_time_installation"), systemImage: "arrow.down.app")
                .accessibilityIdentifier("settings.hostInstaller.disclosure")
        }
        .settingsRow()
        .listRowBackground(tokens.elevatedSurface)
    }
}

/// 图标与文字作为一个整体居中，避免宽窗口中两者分散到按钮两端。
struct ConnectionActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)

            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// 按容器宽度分配主辅操作，窄屏优先保证粘贴的触控区域，并让换行后的两个按钮等高。
struct ConnectionPrimaryActionsLayout: Layout {
    let layoutDirection: LayoutDirection
    private let spacing: CGFloat = 8

    private func widths(in width: CGFloat, minimumPasteWidth: CGFloat) -> (scan: CGFloat, paste: CGFloat) {
        let paste = max(minimumPasteWidth, (width - spacing) * 0.12)
        return (width - spacing - paste, paste)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealWidth = subviews.reduce(spacing) { $0 + $1.sizeThatFits(.unspecified).width }
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        // 大字体下系统按钮可能比 44pt 更宽，按实际最小宽度留位，避免背景越过卡片内边距。
        let minimumPasteWidth = max(44, subviews[1].sizeThatFits(.unspecified).width)
        let width = max(44 + spacing + minimumPasteWidth, proposedWidth ?? idealWidth)
        let sizes = widths(in: width, minimumPasteWidth: minimumPasteWidth)
        let scanHeight = subviews[0].sizeThatFits(.init(width: sizes.scan, height: nil)).height
        let pasteHeight = subviews[1].sizeThatFits(.init(width: sizes.paste, height: nil)).height
        return CGSize(width: width, height: max(44, scanHeight, pasteHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let minimumPasteWidth = max(44, subviews[1].sizeThatFits(.unspecified).width)
        let sizes = widths(in: bounds.width, minimumPasteWidth: minimumPasteWidth)
        let isRightToLeft = layoutDirection == .rightToLeft
        subviews[0].place(
            at: CGPoint(x: isRightToLeft ? bounds.maxX - sizes.scan : bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: .init(width: sizes.scan, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: isRightToLeft ? bounds.minX : bounds.maxX - sizes.paste, y: bounds.minY),
            anchor: .topLeading,
            proposal: .init(width: sizes.paste, height: bounds.height)
        )
    }
}

/// 普通连接入口使用固定图标列，让标题与说明共享同一条起始边。
struct ConnectionRowLabel: View {
    let title: String
    var value: String? = nil
    let systemImage: String
    var valueTint: Color? = nil

    var body: some View {
        SettingsValueLabel(
            title: title,
            value: value,
            systemImage: systemImage,
            valueTint: valueTint
        )
    }
}
