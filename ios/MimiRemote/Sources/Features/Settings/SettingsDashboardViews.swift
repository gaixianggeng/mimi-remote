import SwiftUI

struct InitialPairingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    let onRequestProfileRename: (ConnectionProfile) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            InitialConnectionSettingsSections(
                qrScannerPresentation: qrScannerPresentation,
                onRequestProfileRename: onRequestProfileRename
            )
        }
        .themedSettingsForm(tokens: tokens)
        // 连接是短表单而不是数据表；宽窗口里限制行长，按钮和输入框不会被拉成整屏。
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .settingsCanvasBackground(tokens: tokens)
    }
}
private struct SettingsDashboardSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let title: String
    let footer: String
    let content: Content

    init(title: String, footer: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .padding(.horizontal, 2)

            VStack(spacing: 0) {
                content
            }
            .background(tokens.elevatedSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tokens.border, lineWidth: 1)
            }

            Text(footer)
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(tokens.secondaryText)
                .padding(.horizontal, 2)
        }
    }
}

private struct SettingsDashboardNavigationRow<Destination: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let systemImage: String
    let title: String
    let value: String
    let showsSeparator: Bool
    let destination: Destination

    init(
        systemImage: String,
        title: String,
        value: String,
        showsSeparator: Bool = true,
        @ViewBuilder destination: () -> Destination
    ) {
        self.systemImage = systemImage
        self.title = title
        self.value = value
        self.showsSeparator = showsSeparator
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SettingsDashboardRowContent(
                systemImage: systemImage,
                title: title,
                value: value,
                showsSeparator: showsSeparator,
                trailing: Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsDashboardToggleRow: View {
    @Binding var isOn: Bool
    let systemImage: String
    let title: String
    let value: String
    let showsSeparator: Bool

    init(
        systemImage: String,
        title: String,
        value: String,
        isOn: Binding<Bool>,
        showsSeparator: Bool = true
    ) {
        self.systemImage = systemImage
        self.title = title
        self.value = value
        self.showsSeparator = showsSeparator
        self._isOn = isOn
    }

    var body: some View {
        SettingsDashboardRowContent(
            systemImage: systemImage,
            title: title,
            value: value,
            showsSeparator: showsSeparator,
            trailing: Toggle("", isOn: $isOn)
                .labelsHidden()
        )
    }
}

private struct SettingsDashboardRowContent<Trailing: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let systemImage: String
    let title: String
    let value: String
    let showsSeparator: Bool
    let trailing: Trailing

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tokens.accent.opacity(0.12))
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tokens.accent)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                Text(value)
                    .font(themeStore.uiFont(.footnote, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 10)

            trailing
                .foregroundStyle(tokens.tertiaryText)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle()
                    .fill(tokens.border.opacity(0.72))
                    .frame(height: 1)
                    .padding(.leading, 70)
            }
        }
    }
}
