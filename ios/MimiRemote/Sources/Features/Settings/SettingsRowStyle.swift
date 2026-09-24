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

    /// 分组脚注。左右边距显式给定、与分组标题同一条边线：系统脚注比标题多缩进约 4pt，
    /// 分组之间有细线后这点错位很显眼（#563）。只用于 Section 的 footer。
    func settingsSectionFooterStyle() -> some View {
        modifier(PageSectionCaptionModifier(weight: .regular))
            .listRowInsets(
                EdgeInsets(
                    top: SettingsLayoutMetrics.groupFooterTopSpacing,
                    leading: SettingsLayoutMetrics.rowHorizontalInset,
                    bottom: 0,
                    trailing: SettingsLayoutMetrics.rowHorizontalInset
                )
            )
    }

    /// 行内说明文字：字号与颜色同分组脚注，不带脚注的边距。
    func settingsCaptionStyle() -> some View {
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

/// 设置页的分组标题：分组之间用一条细线划分功能区，取代过去的卡片（#563）。
///
/// 平铺之后只剩留白区分分组，单行的分组（消息通知、优先使用）没有标题，
/// 看起来像是游离在两组之间；一条与内容同宽的细线把「这里换了一件事」说清楚。
/// 页面第一组不画线；单行的分组可以只有线、没有标题；第一组既无线也无标题时只留顶部间距，
/// 否则系统会按无标题分组的默认上边距空出一大截，各页起点高低不一。
///
/// 分组之间的留白全部由这里给出，所在页面要把分组间距和 `defaultMinListHeaderHeight`
/// 都设为 0（见 `dividedSettingsList()`）：系统分组标题至少约 28pt 高、内容垂直居中，
/// 只有一条线的标题会被上下各垫十几点，带文字的标题却几乎不垫，两种分界就不一样宽。
struct SettingsGroupHeader<Accessory: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var themeStore: ThemeStore

    private let title: String?
    private let showsDivider: Bool
    private let accessory: Accessory

    init(
        title: String? = nil,
        showsDivider: Bool = true,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.showsDivider = showsDivider
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider {
                Rectangle()
                    .fill(themeStore.tokens(for: colorScheme).border)
                    .frame(maxWidth: .infinity)
                    .frame(height: 1 / max(displayScale, 1))
                    .padding(.top, SettingsLayoutMetrics.groupDividerSpacing)
                    .padding(
                        .bottom,
                        title == nil
                            ? SettingsLayoutMetrics.groupDividerSpacing
                            : SettingsLayoutMetrics.groupDividerTitleSpacing
                    )
                    .accessibilityHidden(true)
            }
            if let title {
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .settingsSectionHeaderStyle()
                        .accessibilityAddTraits(.isHeader)
                    accessory
                }
                .padding(.top, showsDivider ? 0 : SettingsLayoutMetrics.groupTitleTopInset)
            } else if !showsDivider {
                Color.clear
                    .frame(height: SettingsLayoutMetrics.groupTitleTopInset)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 显式给出左右边距：系统给分组标题的边距会随分组内容浮动几点，
        // 细线就会和上一条线不一样长。与行内容同一条左右边线。
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

extension SettingsGroupHeader where Accessory == EmptyView {
    init(title: String? = nil, showsDivider: Bool = true) {
        self.init(title: title, showsDivider: showsDivider) { EmptyView() }
    }
}

extension View {
    /// 用细线分组的页面（设备、我的）：分组间距与系统标题最小高度都归零，
    /// 分组之间的距离只由 `SettingsGroupHeader` 决定。必须挂在离 Form 最近的位置，
    /// 外层的 listSectionSpacing 会被内层覆盖。
    func dividedSettingsList() -> some View {
        listSectionSpacing(0)
            .environment(\.defaultMinListHeaderHeight, 0)
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

/// 设置页的展开行（安装指引、手动连接、命令行安装）。
///
/// 系统样式在列表里的展开箭头由 UIKit 绘制：纯黑、比导航箭头粗一号，
/// tint、前景色和主题都改不动它，和同页的导航箭头放在一起像两套控件（#563）。
/// 这里换成与导航箭头、线路刷新标记同色同宽的箭头，展开时转向下方。
/// 自定义样式下展开内容与标题同在一行，不再被系统当成子行多缩进一级。
struct SettingsDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsDisclosureGroupBody(configuration: configuration)
    }
}

private struct SettingsDisclosureGroupBody: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let configuration: DisclosureGroupStyleConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .default) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: SettingsLayoutMetrics.trailingAccessorySpacing) {
                    configuration.label

                    SettingsTrailingAccessory(
                        systemImage: "chevron.right",
                        rotation: .degrees(configuration.isExpanded ? 90 : 0)
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                configuration.isExpanded ? L10n.text("ui.expanded") : L10n.text("ui.collected")
            )

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

/// 行尾标记（线路刷新、展开箭头、外链、Token 刷新）与系统导航箭头长得一样：同宽、同字重、同色。
///
/// 系统导航箭头不跟主题，固定是 tertiaryLabel；主题的三级文字色在浅色下更深、深色下更亮，
/// 两种标记并排时一深一浅，读起来像两套控件（#563）。系统箭头也跟正文一起随辅助功能字号放大，
/// 这里按正文缩放；刷新中换成同宽的 spinner，标记列不跳动。
struct SettingsTrailingAccessory: View {
    let systemImage: String
    var rotation: Angle = .zero
    var isBusy = false
    /// 行尾标记通常只是装饰，行本身已经说清楚动作；单独成钮时（Token 刷新）要留给旁白。
    var isDecorative = true

    @ScaledMetric(relativeTo: .body)
    private var pointSize: CGFloat = SettingsLayoutMetrics.trailingAccessoryPointSize
    @ScaledMetric(relativeTo: .body)
    private var width: CGFloat = SettingsLayoutMetrics.trailingAccessoryWidth

    var body: some View {
        Group {
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: pointSize, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .rotationEffect(rotation)
            }
        }
        .frame(width: width)
        .accessibilityHidden(isDecorative)
    }
}
