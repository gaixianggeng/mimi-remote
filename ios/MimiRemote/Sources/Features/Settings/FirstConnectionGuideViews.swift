import SwiftUI

/// 首次连接引导的步骤标题（#554）。一台电脑都没有时，连接页按「准备 → 打开二维码 → 扫码」
/// 三步排列：扫码排在第一位时，用户会去扫一个此刻电脑上还不存在的码。
/// 字号、颜色和左右边线与 `SettingsGroupHeader` 一致，只在标题前多一枚步骤序号；
/// 第一步上方可以带一句整页说明，说明这个 App 是做什么的。
struct FirstConnectionStepHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let step: Int
    let title: String
    var intro: String? = nil

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 0) {
            if let intro {
                Text(intro)
                    .settingsDetailFont()
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, SettingsLayoutMetrics.groupCardSpacing - SettingsLayoutMetrics.groupTitleBottomSpacing)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // 内层前景色优先，序号用主操作色，字号沿用分组标题样式。
                Image(systemName: "\(step).circle.fill")
                    .foregroundStyle(tokens.primaryAction)
                    .settingsSectionHeaderStyle()
                Text(title)
                    .settingsSectionHeaderStyle()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.format("ui.first_connection_step_accessibility", step, title))
            .accessibilityAddTraits(.isHeader)
        }
        .padding(
            .top,
            intro == nil && step > 1
                ? SettingsLayoutMetrics.groupTitleSeparation
                : SettingsLayoutMetrics.groupTitleTopInset
        )
        .padding(.bottom, SettingsLayoutMetrics.groupTitleBottomSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 与 SettingsGroupHeader 同一条左右边线，标题和卡内图标列对齐。
        .listRowInsets(
            EdgeInsets(
                top: 0,
                leading: SettingsLayoutMetrics.rowHorizontalInset,
                bottom: 0,
                trailing: SettingsLayoutMetrics.rowHorizontalInset
            )
        )
    }
}

/// 卡片内的外链行：图标、标题与外链标记的写法和安装说明里的 GitHub 行一致，
/// 外链标记与相邻行的展开、导航箭头同列。
struct SettingsExternalLinkRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let title: String
    let systemImage: String
    let destination: URL
    var accessibilityHint: String? = nil

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: SettingsLayoutMetrics.trailingAccessorySpacing) {
                SettingsValueLabel(title: title, systemImage: systemImage)
                SettingsTrailingAccessory(systemImage: "arrow.up.right")
            }
            .settingsRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint ?? "")
    }
}
