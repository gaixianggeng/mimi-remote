import SwiftUI

/// 两个连接入口共用页面外壳，避免标题、内容宽度和滚动留白各自演进。
struct ConnectionSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @Environment(\.workbenchBottomChromeClearance) private var bottomChromeClearance
    @Environment(\.workbenchHasCompactTabBar) private var hasCompactTabBar
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    // 重命名 sheet 与扫码 Cover 同样必须由当前显示的连接页持有：紧凑布局把这一页
    // push 进导航栈后，设置根层已经不在被呈现的层级里，挂在那里的 presenter 不会呈现。
    // 这里是整页而不是 Form.Section，Section 刷新不会销毁它（MIM-63）。
    @State private var profileRenamePresentation = ConnectionProfileRenamePresentationState()

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            InitialConnectionSettingsSections(
                qrScannerPresentation: qrScannerPresentation,
                onRequestProfileRename: { profileRenamePresentation.present($0) }
            )
        }
        .themedSettingsForm(tokens: tokens)
        // 普通操作和展开箭头保持中性；扫码按钮单独使用主操作色。
        .tint(tokens.secondaryText)
        .listSectionSpacing(SettingsLayoutMetrics.sectionSpacing)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .settingsCanvasBackground(tokens: tokens)
        .contentMargins(
            .bottom,
            hasCompactTabBar ? bottomChromeClearance : WorkbenchPageLayout.regularPadding,
            for: .scrollContent
        )
        .navigationTitle(L10n.text("ui.mac_connection"))
        .navigationBarTitleDisplayMode(.inline)
        // 扫码 Cover 必须挂在当前真正显示的连接页上。挂在 SettingsView 根层时，
        // 紧凑布局把连接页 push 进导航栈后，根层已不在被呈现的层级里，点击扫码不会有任何反应。
        // 这一层是整页而不是 Form.Section，权限弹窗引起的 Section 重建不会销毁它。
        .fullScreenCover(
            item: qrScannerPresentation.presentationBinding(for: .connectionSettings),
            onDismiss: qrScannerPresentation.didDismiss
        ) { intent in
            QRCodeScannerSheet(
                onDismiss: qrScannerPresentation.dismiss,
                onChooseManualConnection: {
                    qrScannerPresentation.chooseManualConnection(for: intent)
                },
                onCode: { rawValue in
                    await qrScannerPresentation.submit(rawValue, intent: intent)
                }
            )
        }
        .sheet(
            item: profileRenameRouteBinding,
            onDismiss: { profileRenamePresentation.dismiss() }
        ) { route in
            ConnectionProfileRenameSheet(route: route) { displayName in
                try appStore.renameConnectionProfile(id: route.profileID, displayName: displayName)
            }
        }
    }

    private var profileRenameRouteBinding: Binding<ConnectionProfileRenameRoute?> {
        Binding(
            get: { profileRenamePresentation.route },
            set: { route in
                // item-driven sheet 关闭时由 SwiftUI 写回 nil；新目标只允许经 present(_:) 进入。
                if route == nil {
                    profileRenamePresentation.dismiss()
                }
            }
        )
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
