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
    @State private var selectedPlatform: HostInstallationPlatform = .mac

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) {
                Picker(L10n.text("ui.computer_platform"), selection: $selectedPlatform) {
                    ForEach(HostInstallationPlatform.allCases) { platform in
                        Text(platform.title).tag(platform)
                    }
                }
                .pickerStyle(.segmented)
                .tint(tokens.accent)
                .accessibilityIdentifier("settings.hostInstaller.platform")

                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedPlatform.installTitle)
                        .font(themeStore.uiFont(.body, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)

                    Text(selectedPlatform.installationDetail)
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.hostInstaller.installationDetail")

                Link(destination: selectedPlatform.releaseURL) {
                    HStack(spacing: 12) {
                        // 品牌资源保持官方黑白原色，不跟随 App 的主题色染色。
                        Image("GitHubInvertocat")
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
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
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.view_releases_on_github"))
                .accessibilityHint(L10n.text("ui.github_release_accessibility_hint"))
                .accessibilityIdentifier("settings.hostInstaller.githubRelease")

                ShareLink(item: selectedPlatform.installerURL) {
                    ConnectionActionLabel(
                        title: selectedPlatform.shareTitle,
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
        }
        .accessibilityIdentifier("settings.hostInstaller.disclosure")
        .listRowBackground(tokens.elevatedSurface)
    }
}

/// 满宽操作按钮的图标不应把标题挤离整条按钮的中心线。
/// 两侧使用等宽占位，让标题始终相对按钮全局居中，并给大字体留出对称的换行空间。
struct ConnectionActionLabel: View {
    @ScaledMetric(relativeTo: .body) private var accessorySlotWidth = 28.0

    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: systemImage)
                .frame(width: accessorySlotWidth, alignment: .leading)
                .accessibilityHidden(true)

            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            Color.clear
                .frame(width: accessorySlotWidth)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// 普通连接入口使用固定图标列，让标题与说明共享同一条起始边。
struct ConnectionRowLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var themeStore: ThemeStore
    @ScaledMetric(relativeTo: .body) private var titlePointSize = 17.0
    @ScaledMetric(relativeTo: .subheadline) private var valuePointSize = 15.0

    let title: String
    var value: String? = nil
    let systemImage: String
    var valueTint: Color? = nil

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: SettingsLayoutMetrics.symbolPointSize, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tokens.secondaryText)
                .frame(width: SettingsLayoutMetrics.iconSlot, height: SettingsLayoutMetrics.iconSlot)
                .accessibilityHidden(true)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    titleText(tokens: tokens)
                    valueText(tokens: tokens)
                }
            } else {
                titleText(tokens: tokens)
                if value != nil {
                    Spacer(minLength: 12)
                    valueText(tokens: tokens)
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: dynamicTypeSize.isAccessibilitySize
                ? SettingsLayoutMetrics.accessibilityRowHeight
                : SettingsLayoutMetrics.standardRowHeight,
            alignment: .leading
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func titleText(tokens: ThemeTokens) -> some View {
        Text(title)
            .font(themeStore.uiFont(size: titlePointSize))
            .foregroundStyle(tokens.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    @ViewBuilder
    private func valueText(tokens: ThemeTokens) -> some View {
        if let value {
            Text(value)
                .font(themeStore.uiFont(size: valuePointSize))
                .foregroundStyle(valueTint ?? tokens.secondaryText)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
