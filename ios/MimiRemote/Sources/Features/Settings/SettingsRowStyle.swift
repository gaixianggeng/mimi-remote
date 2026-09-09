import SwiftUI

/// 设置链路的行只约束最小高度；大字号和多行说明继续按内容自然增长。
enum SettingsRowKind {
    case standard
    case descriptive
}

extension View {
    func settingsTitleFont(weight: Font.Weight = .regular) -> some View {
        modifier(SettingsFontModifier(size: 17, style: .body, weight: weight))
    }

    func settingsDetailFont(weight: Font.Weight = .regular) -> some View {
        modifier(SettingsFontModifier(size: 15, style: .subheadline, weight: weight))
    }

    func settingsRow(_ kind: SettingsRowKind = .standard) -> some View {
        modifier(SettingsRowModifier(kind: kind))
    }

    func settingsDetailPage(width: CGFloat = 720) -> some View {
        modifier(SettingsDetailPageModifier(width: width))
    }

    func settingsScrollContent(width: CGFloat = 720) -> some View {
        frame(maxWidth: width, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, SettingsLayoutMetrics.rowHorizontalInset)
            .padding(.top, SettingsLayoutMetrics.rowHorizontalInset)
            .padding(.bottom, SettingsLayoutMetrics.sectionSpacing)
    }
}

/// ThemeStore 的显式字号只处理应用内字体比例；设置行另外跟随系统辅助功能字号。
private struct SettingsFontModifier: ViewModifier {
    @EnvironmentObject private var themeStore: ThemeStore
    @ScaledMetric private var pointSize: CGFloat
    let weight: Font.Weight

    init(size: CGFloat, style: Font.TextStyle, weight: Font.Weight) {
        _pointSize = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(themeStore.uiFont(size: pointSize, weight: weight))
    }
}

private struct SettingsDetailPageModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.workbenchBottomChromeClearance) private var bottomChromeClearance
    @Environment(\.workbenchHasCompactTabBar) private var hasCompactTabBar

    let width: CGFloat

    func body(content: Content) -> some View {
        content
            // Form 内未使用专用行 modifier 的系统控件也遵守同一基础节奏。
            .environment(
                \.defaultMinListRowHeight,
                dynamicTypeSize.isAccessibilitySize
                    ? SettingsLayoutMetrics.accessibilityRowHeight
                    : SettingsLayoutMetrics.standardRowHeight
            )
            .frame(maxWidth: width)
            .frame(maxWidth: .infinity)
            .contentMargins(
                .bottom,
                hasCompactTabBar ? max(bottomChromeClearance, SettingsLayoutMetrics.sectionSpacing) : SettingsLayoutMetrics.sectionSpacing,
                for: .scrollContent
            )
    }
}

private struct SettingsRowModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let kind: SettingsRowKind

    private var minimumHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return SettingsLayoutMetrics.accessibilityRowHeight
        }
        switch kind {
        case .standard:
            return SettingsLayoutMetrics.standardRowHeight
        case .descriptive:
            return SettingsLayoutMetrics.accessibilityRowHeight
        }
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
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
