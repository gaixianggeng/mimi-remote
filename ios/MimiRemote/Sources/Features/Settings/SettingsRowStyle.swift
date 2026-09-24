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

    /// 分组标题在四个一级页面（会话、工作区、设备、我的）、iPad 侧栏与整条设置链路
    /// 只有这一套排版。过去会话 11pt 半粗、工作区 13pt 半粗带计数、设置 13pt 中粗、
    /// 侧栏 13pt 三级灰各写一份，四个 Tab 并排时最先被读成「不是一个系统」（#563）。
    func pageSectionHeaderStyle() -> some View {
        modifier(PageSectionCaptionModifier(weight: .medium))
    }

    /// 设置链路沿用原名，与 `pageSectionHeaderStyle()` 是同一套排版。
    func settingsSectionHeaderStyle() -> some View {
        pageSectionHeaderStyle()
    }

    /// 设置分组的行直接落在页面底色上：不再装进圆角卡片，也不画行间分隔线（#563）。
    ///
    /// 会话、工作区的内容都铺在页面上、只靠分组标题和留白分段；设置页过去每组一张卡片，
    /// 四个 Tab 并排时读成两套系统。行背景只能挂在 Section 上（挂在 Form 外层不会下发到行），
    /// 所以每个设置分组都要显式接这一个修饰符，不能留系统默认的分组卡片色。
    func settingsGroupRowStyle() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func settingsSectionFooterStyle() -> some View {
        modifier(PageSectionCaptionModifier(weight: .regular))
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


/// 标题和脚注共用同一个字号与文字色，只靠字重区分主次。
/// 字号与行文字一样先跟随系统辅助功能字号，再交给 ThemeStore 叠应用内比例。
private struct PageSectionCaptionModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @ScaledMetric(relativeTo: .footnote) private var pointSize: CGFloat = 13

    let weight: Font.Weight

    func body(content: Content) -> some View {
        content
            .font(themeStore.uiFont(size: pointSize, weight: weight))
            .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            .textCase(nil)
    }
}
