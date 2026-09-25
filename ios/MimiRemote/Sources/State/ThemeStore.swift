import SwiftUI

private extension Color {
    /// 默认主题浅色的墨色 #2E2C2A，取自 Notion iOS 浅色截图的正文。
    /// 只用于阅读与中性表面；操作和小面积强调沿用产品原有的紫色。
    static let notionLightInk = Color(
        red: 46.0 / 255.0,
        green: 44.0 / 255.0,
        blue: 42.0 / 255.0
    )

    /// 产品原有浅色主色，集中给操作、色卡与少量状态强调使用。
    static let mimiPrimary = Color(
        red: 74.0 / 255.0,
        green: 20.0 / 255.0,
        blue: 74.0 / 255.0
    )

    /// 默认主题浅色的页面底 #FAF8F6，取自 Notion iOS 浅色截图。
    static let notionLightCanvas = Color(
        red: 250.0 / 255.0,
        green: 248.0 / 255.0,
        blue: 246.0 / 255.0
    )
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return L10n.text("ui.system")
        case .light:
            return L10n.text("ui.light_color")
        case .dark:
            return L10n.text("ui.dark")
        }
    }

    var subtitle: String {
        switch self {
        case .system:
            return L10n.text("ui.follow_the_current_device_appearance")
        case .light:
            return L10n.text("ui.bright_reading_interface")
        case .dark:
            return L10n.text("ui.low_glare_work_surface")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum ThemeResolvedScheme: String {
    case light
    case dark
}

private struct ThemeSystemColorSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    var themeSystemColorScheme: ColorScheme? {
        get { self[ThemeSystemColorSchemeKey.self] }
        set { self[ThemeSystemColorSchemeKey.self] = newValue }
    }
}

enum ThemePreset: String, CaseIterable, Identifiable {
    case codex
    case github
    case xcode
    case gruvbox
    case meadow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return L10n.text("ui.default")
        case .github:
            return "GitHub"
        case .xcode:
            return "Xcode"
        case .gruvbox:
            return "Gruvbox"
        case .meadow:
            return L10n.text("ui.meadow")
        }
    }

    var subtitle: String {
        switch self {
        case .codex:
            return L10n.text("ui.notion_style_neutral_grays_without_accent_color")
        case .github:
            return L10n.text("ui.code_review_color_matching_close_to_github_primer")
        case .xcode:
            return L10n.text("ui.close_to_xcode_s_native_editing_area_and")
        case .gruvbox:
            return L10n.text("ui.warm_colors_and_low_contrast_suitable_for_night")
        case .meadow:
            return L10n.text("ui.neutral_ground_with_a_sage_green_accent")
        }
    }

    var swatchForeground: Color {
        switch self {
        case .codex:
            return .mimiPrimary
        case .github:
            return Color(red: 0.03, green: 0.41, blue: 0.85)
        case .xcode:
            // Xcode Default (Dark) 的 keyword 粉色配合编辑器底色，比通用系统蓝更容易识别这个预设。
            return Color(red: 0.988394, green: 0.37355, blue: 0.638329)
        case .gruvbox:
            return Color(red: 0.84, green: 0.55, blue: 0.22)
        case .meadow:
            // 鼠尾草绿压在薄荷底上约 6.1:1。整套配色的绿都集中在这两个值上，
            // 主题列表里的色卡就用它们本身，不另找一组更跳的颜色代言。
            return Color(red: 43.0 / 255.0, green: 97.0 / 255.0, blue: 64.0 / 255.0)
        }
    }

    var swatchBackground: Color {
        switch self {
        case .codex:
            return .notionLightCanvas
        case .github:
            return Color(red: 0.96, green: 0.97, blue: 0.98)
        case .xcode:
            return Color(red: 0.120543, green: 0.122844, blue: 0.141312)
        case .gruvbox:
            return Color(red: 0.20, green: 0.19, blue: 0.16)
        case .meadow:
            return Color(red: 226.0 / 255.0, green: 237.0 / 255.0, blue: 230.0 / 255.0)
        }
    }
}

enum ThemeUIFontPreset: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return L10n.text("ui.system")
        case .rounded:
            return L10n.text("ui.round_body")
        case .serif:
            return L10n.text("ui.serif")
        }
    }

    var design: Font.Design {
        switch self {
        case .system:
            return .default
        case .rounded:
            return .rounded
        case .serif:
            return .serif
        }
    }
}

enum ThemeCodeFontPreset: String, CaseIterable, Identifiable {
    case systemMono
    case menlo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemMono:
            return "SF Mono"
        case .menlo:
            return "Menlo"
        }
    }

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        switch self {
        case .systemMono:
            return .system(size: size, weight: weight, design: .monospaced)
        case .menlo:
            // Menlo 是 iOS/macOS 常见内置等宽字体，和 SF Mono 形成真正的字体族差异。
            return .custom("Menlo-Regular", size: size).weight(weight)
        }
    }
}

struct ThemeTokens {
    let preset: ThemePreset
    let resolvedScheme: ThemeResolvedScheme
    let background: Color
    let surface: Color
    let elevatedSurface: Color
    let userBubble: Color
    let assistantBubble: Color
    let systemBubble: Color
    let codeBlock: Color
    let codeText: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let warning: Color
    let success: Color
    let goalActive: Color
    let voiceRecording: Color
    let voiceWaveformGradient: [Color]
    let border: Color
    let selectionFill: Color
}

extension ThemeTokens {
    /// Notion 的导航列表与页面同底，深浅色都不另起一档侧栏色。
    var sidebarBackground: Color {
        background
    }

    /// 侧栏是结构分区，不是内容卡片。深色下若比工作区底色亮一整级，
    /// 整屏就会出现两块明显不同的深色，是“看着乱”的最大来源；
    /// 宽屏浮层侧栏四周直接透出同色画布，只比背景高一点点保住浮层边缘，
    /// 层级交给留白、字重和分组间距表达。
    var sidebarSurfaceBackground: Color {
        guard preset == .codex, resolvedScheme == .dark else {
            return contentPanelBackground
        }
        return Color(red: 35.0 / 255.0, green: 35.0 / 255.0, blue: 35.0 / 255.0)
    }

    /// 悬停取 Notion 未选中胶囊那一档，明显弱于选中填充；默认深色里那一档是 surface。
    var sidebarHoverFill: Color {
        guard preset == .codex, resolvedScheme == .dark else { return elevatedSurface }
        return surface
    }

    var inputBackground: Color {
        guard preset == .codex else {
            return elevatedSurface
        }
        switch resolvedScheme {
        case .light:
            // 纯白输入卡压在 Notion 的 #FAF8F6 页面上浮起一档，与 Notion 底部输入条一致。
            return .white
        case .dark:
            return elevatedSurface
        }
    }

    /// 会话画布。默认主题浅色曾在这里单独换成纸白，以避开暖白页面被材质重复染黄；
    /// 改成 Notion 的中性浅底后页面本身不再偏黄，画布与全局底色合一。
    var conversationCanvasBackground: Color {
        background
    }

    /// 宽屏工作台的基底。侧栏浮层外围的 gutter、会话/工作区主列表与会话画布在同一屏上
    /// 彼此相邻，必须共用同一张底色；层级改由浮层卡片表达。
    var workbenchCanvasBackground: Color {
        conversationCanvasBackground
    }

    /// 会话阅读层的文字。默认主题浅色曾单独换成 #101010 以对齐 Claude 的正文；
    /// 改成 Notion 配色后阅读层与列表共用同一套墨色。
    var conversationPrimaryText: Color {
        primaryText
    }

    var conversationSecondaryText: Color {
        secondaryText
    }

    var conversationTertiaryText: Color {
        tertiaryText
    }

    /// 四个 Tab 共用的卡片底：设置分组卡，以及会话、工作区里的重点小模块。
    /// 浅色是压在 #FAF8F6 画布上的白卡，深色是比画布亮一档的 surface。
    var moduleCardBackground: Color {
        surface
    }

    /// 列表与侧栏条目的标题色。
    ///
    /// Notion 深色侧栏的条目标题不是白色，而是 #B9B8B6 上下的浅灰，只有选中那一行
    /// 才提亮到接近白；导航列表因此显得安静，正文区仍保持高亮。默认深色照这个做法，
    /// 非选中条目用这一档，选中条目由调用方换回 primaryText。浅色与其它主题等于正文色。
    var listTitleText: Color {
        guard preset == .codex, resolvedScheme == .dark else { return primaryText }
        return Color(red: 190.0 / 255.0, green: 189.0 / 255.0, blue: 187.0 / 255.0)
    }

    /// 使用量图表与未读提示共用主题紫色：浅色用原主色，深色收成灰紫。
    /// 图表只在活动格使用这档颜色，避免把整张卡片染成状态提示。
    var tokenActivityAccent: Color {
        guard preset == .codex else { return accent }
        switch resolvedScheme {
        case .light:
            return .mimiPrimary
        case .dark:
            // 深色单独压低彩度，避免暗色列表出现亮色跳点。
            return Color(red: 119.0 / 255.0, green: 113.0 / 255.0, blue: 127.0 / 255.0)
        }
    }

    /// 未读是“有新结果”，不是“执行成功”；与用量图表共用一档小面积主题色。
    var sessionUnreadAccent: Color { tokenActivityAccent }

    /// 浅色卡片里的月份和重置时间很小，取更深一档暖灰，保留可读性。
    var tokenActivityAxisText: Color {
        guard preset == .codex, resolvedScheme == .light else { return tertiaryText }
        return Color(red: 106.0 / 255.0, green: 105.0 / 255.0, blue: 102.0 / 255.0)
    }

    /// Composer 内部的低频控件使用独立的中性表面色。它比页面底色更冷、比输入卡更实，
    /// 因此在半透明材质上仍能形成清楚分组，又不会叠第二层 Material 造成浑浊。
    var composerControlSurface: Color {
        guard preset == .codex else {
            return surface
        }
        switch resolvedScheme {
        case .light:
            // Notion 浅色未选中胶囊 #F0EEED。
            return elevatedSurface
        case .dark:
            // Notion 悬浮按钮 #3D3D3D，比输入卡高一档。
            return Color(red: 61.0 / 255.0, green: 61.0 / 255.0, blue: 61.0 / 255.0)
        }
    }

    /// 禁用发送仍保留主行动的位置和轮廓，但用低对比中性面明确表达“尚不可发送”。
    /// 这比把按钮清空成普通工具键更稳定，也避免底栏出现六个同权重入口。
    ///
    /// 曾经用的是低饱和暖粉。工具键还带着键帽底色时它只是“另一块浅色”；
    /// 键帽全部去掉之后，输入卡里唯一的色块就是它，一枚和页面上任何东西都不同族的
    /// 杏粉圆——空草稿又恰恰是进入会话的默认状态。这里改回中性灰阶：
    /// 它比输入卡白面暗一档因而形状清楚，又不引入第二个色相。
    var composerInactiveActionSurface: Color {
        guard preset == .codex else {
            return accent.opacity(0.20)
        }
        switch resolvedScheme {
        case .light:
            // Notion 浅色选中胶囊 #ECEAE8，比输入卡白面暗一档。
            return selectionFill
        case .dark:
            return composerControlSurface
        }
    }

    /// 禁用发送时的图标墨色。浅色下不能继续沿用启用态的白字：白色压在
    /// composerInactiveActionSurface 上只有约 1.3:1，箭头会整个消失在色块里，
    /// 而空草稿正是进入会话的默认状态。这里改用与禁用底同族的中性深灰，
    /// 既保持 4.5:1 以上的可辨识度，又明显弱于启用态的实心墨色。
    var composerInactiveActionForeground: Color {
        guard preset == .codex else {
            // 其它主题的禁用底是 20% 强调色，前景交给该外观自己的高对比墨色，
            // 避免逐个主题重新校准一套近似紫。Gruvbox 这类高明度暖底会把墨色
            // 迅速冲淡，所以留到 0.8 才降级，而不是常见的半透明。
            return primaryText.opacity(0.80)
        }
        switch resolvedScheme {
        case .light:
            // 与中性禁用底同族的深灰，压在 236/234/232 上约 5:1，
            // 明显可读又远弱于启用态的白压墨色（约 14:1）。
            return Color(
                red: 99.0 / 255.0,
                green: 98.0 / 255.0,
                blue: 95.0 / 255.0
            )
        case .dark:
            return Color.white.opacity(0.62)
        }
    }

    var planCardBackground: Color {
        guard preset == .codex else {
            return elevatedSurface
        }
        switch resolvedScheme {
        case .light:
            return .white
        case .dark:
            return surface
        }
    }

    var planCardBorder: Color {
        guard preset == .codex else {
            return border
        }
        switch resolvedScheme {
        case .light, .dark:
            return border
        }
    }

    /// 默认深色主操作是浅灰配黑字，浅色恢复产品紫色配白字。
    /// 主操作与小面积强调共用 accent，同时满足“当填充”和“当前景”两种用法。
    var primaryAction: Color {
        accent
    }

    /// 主按钮默认白字，维持一致、清晰的操作语义。
    ///
    /// 青草深色是例外：它的主操作是鼠尾草绿 #6FAF86，白字只有 2.6:1，连图形控件的
    /// 3:1 都不到（新建会话的悬浮按钮就是这一处）。而且压暗按钮救不回来——白字要到
    /// 4.5:1 得把亮度压到 0.18，那时主操作自身压深色底只剩 4.1:1，又破了另一条门槛。
    /// 所以改前景而不是改填充：黑字压它有 8.2:1，与冲突卡的
    /// `writerConflictPrimaryActionForeground` 同一处置。
    ///
    /// 默认深色的主操作是浅灰 #D3D3D3，与 Notion AI 圆钮一样配纯黑图标（14:1）。
    var primaryActionForeground: Color {
        switch (preset, resolvedScheme) {
        case (.codex, .dark), (.meadow, .dark):
            return .black
        default:
            return .white
        }
    }

    /// 悬浮主按钮的投影。彩色主操作用同色投影做一点光晕；默认深色的主操作是浅灰，
    /// 同色投影会变成一圈发白的光，改用普通的黑色投影。
    var primaryActionShadow: Color {
        switch (preset, resolvedScheme) {
        case (.codex, .dark):
            return Color.black.opacity(0.40)
        case (_, .dark):
            return primaryAction.opacity(0.34)
        case (_, .light):
            return primaryAction.opacity(0.28)
        }
    }

    /// Writer 冲突卡必须在所有主题中保持可读。部分主题的次级文字和原始 warning
    /// 是为大面积背景校准的，放到 elevatedSurface 上会低于文字对比度要求。
    /// 这里提供卡片局部语义色，避免为了一个状态卡改动全局主题。
    var writerConflictBodyText: Color {
        switch (preset, resolvedScheme) {
        case (.codex, .light), (.github, .dark), (.xcode, .dark):
            return primaryText
        default:
            return secondaryText
        }
    }

    var writerConflictWarningIcon: Color {
        switch (preset, resolvedScheme) {
        case (.xcode, .light):
            return Color(red: 0.68, green: 0.47, blue: 0.03)
        case (.gruvbox, .light):
            return Color(red: 0.72, green: 0.35, blue: 0.00)
        default:
            return warning
        }
    }

    var writerConflictErrorText: Color {
        switch (preset, resolvedScheme) {
        case (.codex, .light):
            return Color(red: 0.62, green: 0.34, blue: 0.00)
        case (.xcode, .light):
            return Color(red: 0.53, green: 0.36, blue: 0.00)
        case (.gruvbox, .light):
            return Color(red: 0.55, green: 0.26, blue: 0.00)
        case (.gruvbox, .dark):
            return Color(red: 1.00, green: 0.59, blue: 0.28)
        default:
            return warning
        }
    }

    /// 各主题的主色明度不同，固定白字会在亮蓝和亮橙按钮上失去可读性。
    /// 只为本卡片选择经过校准的黑白前景，不改变其它主操作。
    var writerConflictPrimaryActionForeground: Color {
        switch (preset, resolvedScheme) {
        case (.codex, .light), (.github, .light), (.gruvbox, .light), (.meadow, .light):
            return .white
        case (.codex, .dark), (.github, .dark), (.xcode, _), (.gruvbox, .dark), (.meadow, .dark):
            // 青草深色的主操作是鼠尾草绿，白字只有约 3.6:1，黑字约 5.8:1；
            // 默认深色的主操作是浅灰，同样只能配黑字。
            return .black
        }
    }

    var accentSoft: Color {
        guard preset == .codex else { return accent.opacity(0.12) }
        return selectionFill
    }

    /// 会话侧滑动作使用独立语义色，而不是在视图里硬编码系统橙/蓝。
    /// 这些颜色都以白色图标和文案为前景，并分别为浅色、深色外观校准对比度。
    /// 默认主题的置顶/取消置顶动作使用两档中性灰，白字都在 4.5:1 以上。
    var sessionPinActionTint: Color {
        switch (preset, resolvedScheme) {
        case (.codex, .light):
            return Color(red: 70.0 / 255.0, green: 69.0 / 255.0, blue: 66.0 / 255.0)
        case (_, .light):
            return Color(red: 74.0 / 255.0, green: 20.0 / 255.0, blue: 74.0 / 255.0)
        case (.codex, .dark):
            return Color(red: 90.0 / 255.0, green: 90.0 / 255.0, blue: 88.0 / 255.0)
        case (_, .dark):
            return Color(red: 112.0 / 255.0, green: 61.0 / 255.0, blue: 116.0 / 255.0)
        }
    }

    var sessionUnpinActionTint: Color {
        switch (preset, resolvedScheme) {
        case (.codex, .light):
            return Color(red: 112.0 / 255.0, green: 111.0 / 255.0, blue: 108.0 / 255.0)
        case (_, .light):
            return Color(red: 91.0 / 255.0, green: 84.0 / 255.0, blue: 95.0 / 255.0)
        case (.codex, .dark):
            return Color(red: 61.0 / 255.0, green: 61.0 / 255.0, blue: 61.0 / 255.0)
        case (_, .dark):
            return Color(red: 67.0 / 255.0, green: 61.0 / 255.0, blue: 70.0 / 255.0)
        }
    }

    var sessionMarkUnreadActionTint: Color {
        switch resolvedScheme {
        case .light:
            return Color(red: 32.0 / 255.0, green: 95.0 / 255.0, blue: 169.0 / 255.0)
        case .dark:
            return Color(red: 36.0 / 255.0, green: 84.0 / 255.0, blue: 139.0 / 255.0)
        }
    }

    var sessionMarkReadActionTint: Color {
        switch resolvedScheme {
        case .light:
            return Color(red: 40.0 / 255.0, green: 108.0 / 255.0, blue: 76.0 / 255.0)
        case .dark:
            return Color(red: 35.0 / 255.0, green: 89.0 / 255.0, blue: 63.0 / 255.0)
        }
    }

    /// 内容卡片不再借用输入框/浮层的提亮层级；非默认深色原本就使用 surface。
    var contentPanelBackground: Color {
        surface
    }

    /// 选中反馈复用同一低饱和填充，不再为工作区额外引入一档深梅紫。
    var workspaceCardSelectionFill: Color {
        selectionFill
    }

    /// 会话搜索框的底。紧凑布局走系统 `.searchable`，只能靠 appearance proxy 铺底色。
    /// 曾用 selectionFill：在青草这类带色相的预设里它就是一块明显的强调色，
    /// 搜索框成了页面上唯一被主题色染过的输入位。这里改成与主题无关的中性阴影——
    /// 纯黑 / 纯白按极低透明度压在页面底上，浅色比底暗一档、深色比底亮一档，
    /// 所有预设一致，不再跟着主题色走。
    var searchFieldBackground: Color {
        switch resolvedScheme {
        case .light:
            return Color.black.opacity(0.05)
        case .dark:
            return Color.white.opacity(0.08)
        }
    }

    var userBubbleForeground: Color {
        conversationPrimaryText
    }

    /// 默认主题的链接继续加下划线区分，不只靠颜色。
    var underlinesLinks: Bool {
        preset == .codex
    }

    /// 用户消息的时间文字。发送中整条消息还会叠 0.72 透明度：默认深色若继续用
    /// Notion 的次级灰，叠完压画布只剩约 4.3:1。发送中改用主文字色，叠完恰好落回
    /// 次级灰附近的亮度，发送完成切回次级灰时看不出跳变。
    func userMessageTimestampForeground(isSending: Bool) -> Color {
        guard preset == .codex, resolvedScheme == .dark else {
            return userBubbleForeground.opacity(0.64)
        }
        return isSending ? primaryText : secondaryText
    }

    func tint(for tone: AgentSessionStatusTone) -> Color {
        switch tone {
        case .active:
            // 运行态文字/图标跟随主操作色；默认深色是浅灰，浅色是产品紫色。
            return primaryAction
        case .warning:
            return warning
        case .danger:
            return .red
        case .complete:
            return accent
        case .neutral:
            return secondaryText
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published var mode: ThemeMode {
        didSet { persistVisualState() }
    }

    @Published var preset: ThemePreset {
        didSet { persistVisualState() }
    }

    @Published var uiFontPreset: ThemeUIFontPreset {
        didSet { persistVisualState() }
    }

    @Published var codeFontPreset: ThemeCodeFontPreset {
        didSet { persistVisualState() }
    }

    @Published var fontScale: Double {
        didSet {
            let clamped = Self.clampedFontScale(fontScale)
            guard clamped == fontScale else {
                fontScale = clamped
                return
            }
            guard !isApplyingDeviceDefaultFontScale else {
                return
            }
            persistVisualState()
        }
    }

    @Published private(set) var themeVersion: Int

    private let defaults: UserDefaults
    private var hasStoredFontScale: Bool
    private var deviceDefaultFontScale = ThemeStore.defaultFontScale
    private var isApplyingDeviceDefaultFontScale = false

    private enum Keys {
        static let mode = "appearance.theme.mode"
        static let preset = "appearance.theme.preset"
        static let uiFont = "appearance.theme.uiFont"
        static let codeFont = "appearance.theme.codeFont"
        static let fontScale = "appearance.theme.fontScale"
        static let themeVersion = "appearance.theme.version"
    }

    static let fontScaleStorageKey = Keys.fontScale
    static let minimumFontScale = 0.85
    static let maximumFontScale = 1.35
    static let defaultFontScale = 1.0
    static let compactIPadDefaultFontScale = 1.10
    static let compactIPadMaximumShortEdge: CGFloat = 768

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedMode = defaults.string(forKey: Keys.mode).flatMap(ThemeMode.init(rawValue:)) ?? .system
        let savedPreset = defaults.string(forKey: Keys.preset).flatMap(ThemePreset.init(rawValue:)) ?? .codex
        let savedUIFont = defaults.string(forKey: Keys.uiFont).flatMap(ThemeUIFontPreset.init(rawValue:)) ?? .system
        let savedCodeFont = defaults.string(forKey: Keys.codeFont).flatMap(ThemeCodeFontPreset.init(rawValue:)) ?? .systemMono
        let savedFontScale = defaults.object(forKey: Keys.fontScale).flatMap { $0 as? Double }

        self.mode = savedMode
        self.preset = savedPreset
        self.uiFontPreset = savedUIFont
        self.codeFontPreset = savedCodeFont
        self.fontScale = Self.clampedFontScale(savedFontScale ?? Self.defaultFontScale)
        self.themeVersion = defaults.integer(forKey: Keys.themeVersion)
        self.hasStoredFontScale = savedFontScale != nil
    }

    var preferredColorScheme: ColorScheme? {
        mode.preferredColorScheme
    }

    func resolvedColorScheme(for systemColorScheme: ColorScheme) -> ColorScheme {
        // 系统模式不能直接依赖已打开 sheet 里的 colorScheme；它可能还停留在上一次手动浅/深色。
        switch resolvedScheme(for: systemColorScheme) {
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func setFontScale(_ value: Double) {
        fontScale = Self.clampedFontScale(value)
    }

    /// 设备默认只影响从未保存过字号的用户；窗口分屏不会改变物理屏幕，因此不会让字号来回跳变。
    func applyDeviceDefaultFontScale(isPad: Bool, screenSize: CGSize) {
        let resolvedDefault = Self.defaultFontScale(isPad: isPad, screenSize: screenSize)
        deviceDefaultFontScale = resolvedDefault
        guard !hasStoredFontScale, fontScale != resolvedDefault else {
            return
        }

        isApplyingDeviceDefaultFontScale = true
        fontScale = resolvedDefault
        isApplyingDeviceDefaultFontScale = false
        // 消息行使用 themeVersion 做等价判断；默认字号变化也必须推进内存版本才能立即重绘。
        themeVersion += 1
    }

    func reset() {
        mode = .system
        preset = .codex
        uiFontPreset = .system
        codeFontPreset = .systemMono
        // “恢复默认”回到当前设备默认，而不是把紧凑 iPad 强制压回 100%。
        hasStoredFontScale = false
        defaults.removeObject(forKey: Keys.fontScale)
        isApplyingDeviceDefaultFontScale = true
        fontScale = deviceDefaultFontScale
        isApplyingDeviceDefaultFontScale = false
        themeVersion += 1
        defaults.set(themeVersion, forKey: Keys.themeVersion)
    }

    func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
        baseSize * CGFloat(fontScale)
    }

    func uiFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaledFontSize(size), weight: weight, design: uiFontPreset.design)
    }

    func uiFont(_ textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        uiFont(size: Self.baseSize(for: textStyle), weight: weight)
    }

    func codeFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let scaled = scaledFontSize(size)
        return codeFontPreset.font(size: scaled, weight: weight)
    }

    func codeFont(_ textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        codeFont(size: Self.baseSize(for: textStyle), weight: weight)
    }

    func tokens(for systemColorScheme: ColorScheme) -> ThemeTokens {
        // 主题只产出视觉 token，不读写消息或 session 数据，保证外观切换不影响会话状态。
        let scheme = resolvedScheme(for: systemColorScheme)
        switch (preset, scheme) {
        case (.codex, .light):
            return codexLightTokens
        case (.codex, .dark):
            return codexDarkTokens
        case (.github, .light):
            return githubLightTokens
        case (.github, .dark):
            return githubDarkTokens
        case (.xcode, .light):
            return xcodeLightTokens
        case (.xcode, .dark):
            return xcodeDarkTokens
        case (.gruvbox, .light):
            return gruvboxLightTokens
        case (.gruvbox, .dark):
            return gruvboxDarkTokens
        case (.meadow, .light):
            return meadowLightTokens
        case (.meadow, .dark):
            return meadowDarkTokens
        }
    }

    static func clampedFontScale(_ value: Double) -> Double {
        min(max(value, minimumFontScale), maximumFontScale)
    }

    static func defaultFontScale(isPad: Bool, screenSize: CGSize) -> Double {
        guard isPad else {
            return defaultFontScale
        }
        let shortEdge = min(screenSize.width, screenSize.height)
        guard shortEdge > 0, shortEdge <= compactIPadMaximumShortEdge else {
            return defaultFontScale
        }
        return compactIPadDefaultFontScale
    }

    private static func baseSize(for textStyle: Font.TextStyle) -> CGFloat {
        switch textStyle {
        case .largeTitle:
            return 34
        case .title:
            return 28
        case .title2:
            return 22
        case .title3:
            return 20
        case .headline:
            return 17
        case .subheadline:
            return 15
        case .callout:
            return 16
        case .caption:
            return 12
        case .caption2:
            return 11
        case .footnote:
            return 13
        default:
            return 17
        }
    }

    private func resolvedScheme(for systemColorScheme: ColorScheme) -> ThemeResolvedScheme {
        switch mode {
        case .system:
            return systemColorScheme == .dark ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var codexLightTokens: ThemeTokens {
        // 取自 Notion iOS 浅色截图：页面 #FAF8F6、未选中胶囊 #F0EEED、选中胶囊 #ECEAE8、
        // 正文 #2E2C2A，次级文字与图标是 Notion 的暖灰 #787774 / #9B9A97。
        // 浅色主操作恢复产品紫色配白字；正文仍保持 Notion 式中性墨色。
        // 代码块也照 Notion 用浅底深字，不再在浅色页面里嵌一块深色分区。
        ThemeTokens(
            preset: .codex,
            resolvedScheme: .light,
            background: .notionLightCanvas,
            surface: .white,
            elevatedSurface: Color(red: 240.0 / 255.0, green: 238.0 / 255.0, blue: 237.0 / 255.0),
            userBubble: Color(red: 240.0 / 255.0, green: 238.0 / 255.0, blue: 237.0 / 255.0),
            assistantBubble: .white,
            systemBubble: Color(red: 240.0 / 255.0, green: 238.0 / 255.0, blue: 237.0 / 255.0),
            codeBlock: Color(red: 240.0 / 255.0, green: 238.0 / 255.0, blue: 237.0 / 255.0),
            codeText: .notionLightInk,
            primaryText: .notionLightInk,
            secondaryText: Color(red: 120.0 / 255.0, green: 119.0 / 255.0, blue: 116.0 / 255.0),
            tertiaryText: Color(red: 155.0 / 255.0, green: 154.0 / 255.0, blue: 151.0 / 255.0),
            accent: .mimiPrimary,
            warning: Color(red: 0.663, green: 0.376, blue: 0.000),
            success: Color(red: 0.184, green: 0.490, blue: 0.353),
            goalActive: .mimiPrimary,
            voiceRecording: .mimiPrimary,
            voiceWaveformGradient: [
                .mimiPrimary,
                Color(red: 0.478, green: 0.259, blue: 0.467),
                Color(red: 0.690, green: 0.525, blue: 0.678)
            ],
            border: Color(red: 232.0 / 255.0, green: 230.0 / 255.0, blue: 227.0 / 255.0),
            selectionFill: Color(red: 236.0 / 255.0, green: 234.0 / 255.0, blue: 232.0 / 255.0)
        )
    }

    private var codexDarkTokens: ThemeTokens {
        // 取自 Notion iOS 深色截图的逐像素色值：页面 #1F1F1F、未选中胶囊 #2B2B29、
        // 选中胶囊 #373735、标题 #EFEFED、次级文字 #ABAAA6、AI 圆钮 #D3D3D3。
        // 大面积操作保持中性，文字和胶囊带 Notion 原有的极轻暖灰；小面积状态留给灰紫。
        //
        // 三处按对比度门槛偏离了截图：
        // - 输入框/浮层取 #323232（Notion 的圆形按钮底），不取 #3D3D3D 的悬浮输入条，
        //   否则三级文字在上面到不了 4.5:1；#3D3D3D 留给输入框里的控件。
        // - Notion 只有两级文字，它的 #868686 只用在图标上；三级文字取 #A1A09D，
        //   是在选中胶囊上仍有 4.5:1 的最暗值。
        // - 代码块取 Notion 桌面页面底 #191919，比画布暗一档，与正文分区。
        ThemeTokens(
            preset: .codex,
            resolvedScheme: .dark,
            background: Color(red: 31.0 / 255.0, green: 31.0 / 255.0, blue: 31.0 / 255.0),
            surface: Color(red: 43.0 / 255.0, green: 43.0 / 255.0, blue: 41.0 / 255.0),
            elevatedSurface: Color(red: 50.0 / 255.0, green: 50.0 / 255.0, blue: 50.0 / 255.0),
            userBubble: Color(red: 50.0 / 255.0, green: 50.0 / 255.0, blue: 50.0 / 255.0),
            assistantBubble: Color(red: 43.0 / 255.0, green: 43.0 / 255.0, blue: 41.0 / 255.0),
            systemBubble: Color(red: 43.0 / 255.0, green: 43.0 / 255.0, blue: 41.0 / 255.0),
            codeBlock: Color(red: 25.0 / 255.0, green: 25.0 / 255.0, blue: 25.0 / 255.0),
            codeText: Color(red: 239.0 / 255.0, green: 239.0 / 255.0, blue: 237.0 / 255.0),
            primaryText: Color(red: 239.0 / 255.0, green: 239.0 / 255.0, blue: 237.0 / 255.0),
            secondaryText: Color(red: 171.0 / 255.0, green: 170.0 / 255.0, blue: 166.0 / 255.0),
            tertiaryText: Color(red: 161.0 / 255.0, green: 160.0 / 255.0, blue: 157.0 / 255.0),
            accent: Color(red: 211.0 / 255.0, green: 211.0 / 255.0, blue: 211.0 / 255.0),
            warning: Color(red: 0.941, green: 0.710, blue: 0.384),
            success: Color(red: 0.396, green: 0.773, blue: 0.557),
            goalActive: Color(red: 211.0 / 255.0, green: 211.0 / 255.0, blue: 211.0 / 255.0),
            voiceRecording: Color(red: 211.0 / 255.0, green: 211.0 / 255.0, blue: 211.0 / 255.0),
            voiceWaveformGradient: [
                Color(red: 239.0 / 255.0, green: 239.0 / 255.0, blue: 237.0 / 255.0),
                Color(red: 211.0 / 255.0, green: 211.0 / 255.0, blue: 211.0 / 255.0),
                Color(red: 171.0 / 255.0, green: 170.0 / 255.0, blue: 166.0 / 255.0)
            ],
            border: Color(red: 55.0 / 255.0, green: 55.0 / 255.0, blue: 53.0 / 255.0),
            selectionFill: Color(red: 55.0 / 255.0, green: 55.0 / 255.0, blue: 53.0 / 255.0)
        )
    }

    private var githubLightTokens: ThemeTokens {
        ThemeTokens(
            preset: .github,
            resolvedScheme: .light,
            background: Color(red: 1.00, green: 1.00, blue: 1.00),
            surface: Color(red: 1.00, green: 1.00, blue: 1.00),
            elevatedSurface: Color(red: 0.96, green: 0.97, blue: 0.98),
            userBubble: Color(red: 0.03, green: 0.41, blue: 0.85).opacity(0.13),
            assistantBubble: Color(red: 1.00, green: 1.00, blue: 1.00),
            systemBubble: Color(red: 0.96, green: 0.97, blue: 0.98),
            codeBlock: Color(red: 0.96, green: 0.97, blue: 0.98),
            codeText: Color(red: 0.13, green: 0.16, blue: 0.20),
            primaryText: Color(red: 0.12, green: 0.14, blue: 0.16),
            secondaryText: Color(red: 0.35, green: 0.39, blue: 0.43),
            tertiaryText: Color(red: 0.43, green: 0.48, blue: 0.53),
            accent: Color(red: 0.03, green: 0.41, blue: 0.85),
            warning: Color(red: 0.60, green: 0.40, blue: 0.00),
            success: Color(red: 0.10, green: 0.50, blue: 0.22),
            goalActive: Color(red: 0.03, green: 0.41, blue: 0.85),
            voiceRecording: Color(red: 0.10, green: 0.48, blue: 0.78),
            voiceWaveformGradient: [
                Color(red: 0.32, green: 0.68, blue: 0.96),
                Color(red: 0.03, green: 0.41, blue: 0.85),
                Color(red: 0.02, green: 0.30, blue: 0.64)
            ],
            border: Color(red: 0.82, green: 0.84, blue: 0.87),
            selectionFill: Color(red: 0.03, green: 0.41, blue: 0.85).opacity(0.12)
        )
    }

    private var githubDarkTokens: ThemeTokens {
        ThemeTokens(
            preset: .github,
            resolvedScheme: .dark,
            background: Color(red: 0.05, green: 0.07, blue: 0.09),
            surface: Color(red: 0.09, green: 0.11, blue: 0.15),
            elevatedSurface: Color(red: 0.13, green: 0.16, blue: 0.20),
            userBubble: Color(red: 0.18, green: 0.51, blue: 0.97).opacity(0.28),
            assistantBubble: Color(red: 0.09, green: 0.11, blue: 0.15),
            systemBubble: Color(red: 0.13, green: 0.16, blue: 0.20),
            codeBlock: Color(red: 0.04, green: 0.06, blue: 0.08),
            codeText: Color(red: 0.90, green: 0.93, blue: 0.95),
            primaryText: Color(red: 0.90, green: 0.93, blue: 0.95),
            secondaryText: Color(red: 0.49, green: 0.52, blue: 0.56),
            tertiaryText: Color(red: 0.36, green: 0.39, blue: 0.44),
            accent: Color(red: 0.18, green: 0.51, blue: 0.97),
            warning: Color(red: 0.82, green: 0.60, blue: 0.13),
            success: Color(red: 0.25, green: 0.73, blue: 0.31),
            goalActive: Color(red: 0.42, green: 0.68, blue: 1.00),
            voiceRecording: Color(red: 0.36, green: 0.64, blue: 1.00),
            voiceWaveformGradient: [
                Color(red: 0.58, green: 0.80, blue: 1.00),
                Color(red: 0.18, green: 0.51, blue: 0.97),
                Color(red: 0.10, green: 0.36, blue: 0.76)
            ],
            border: Color(red: 0.19, green: 0.22, blue: 0.25),
            selectionFill: Color(red: 0.18, green: 0.51, blue: 0.97).opacity(0.18)
        )
    }

    private var xcodeLightTokens: ThemeTokens {
        // 直接对齐 Xcode Default (Light) 的编辑器、当前行、选区、注释和 markup 色；
        // UI 层只补一档中性导航器灰，避免整套主题退化成“灰底 + 系统蓝”。
        ThemeTokens(
            preset: .xcode,
            resolvedScheme: .light,
            background: Color(red: 0.96, green: 0.96, blue: 0.96),
            surface: Color(red: 1.00, green: 1.00, blue: 1.00),
            elevatedSurface: Color(red: 0.925, green: 0.929, blue: 0.937),
            userBubble: Color(red: 0.909804, green: 0.94902, blue: 1.00),
            assistantBubble: Color(red: 1.00, green: 1.00, blue: 1.00),
            systemBubble: Color(red: 0.96, green: 0.96, blue: 0.96),
            codeBlock: Color(red: 1.00, green: 1.00, blue: 1.00),
            codeText: Color.black.opacity(0.85),
            primaryText: Color.black.opacity(0.85),
            secondaryText: Color(red: 0.36526, green: 0.421879, blue: 0.475154),
            tertiaryText: Color(red: 0.50, green: 0.53, blue: 0.57),
            accent: Color(red: 0.00, green: 0.48, blue: 1.00),
            warning: Color(red: 0.937255, green: 0.717647, blue: 0.34902),
            success: Color(red: 0.152941, green: 0.494118, blue: 0.117647),
            goalActive: Color(red: 0.607592, green: 0.137526, blue: 0.576284),
            voiceRecording: Color(red: 0.0588235, green: 0.407843, blue: 0.627451),
            voiceWaveformGradient: [
                Color(red: 0.194184, green: 0.429349, blue: 0.454553),
                Color(red: 0.0588235, green: 0.407843, blue: 0.627451),
                Color(red: 0.607592, green: 0.137526, blue: 0.576284)
            ],
            border: Color(red: 0.8832, green: 0.8832, blue: 0.8832),
            selectionFill: Color(red: 0.909804, green: 0.94902, blue: 1.00)
        )
    }

    private var xcodeDarkTokens: ThemeTokens {
        // Xcode Default (Dark) 的编辑器背景并非纯黑，而是带极轻蓝相的 #1F1F24；
        // markup 面板、边框、选区和语法色继续使用同一套官方色值，建立真实的编辑器层级。
        ThemeTokens(
            preset: .xcode,
            resolvedScheme: .dark,
            background: Color(red: 0.120543, green: 0.122844, blue: 0.141312),
            surface: Color(red: 0.138526, green: 0.146864, blue: 0.169283),
            elevatedSurface: Color(red: 0.18856, green: 0.195, blue: 0.22444),
            userBubble: Color(red: 0.317647, green: 0.356862, blue: 0.439215),
            assistantBubble: Color(red: 0.138526, green: 0.146864, blue: 0.169283),
            systemBubble: Color(red: 0.18856, green: 0.195, blue: 0.22444),
            codeBlock: Color(red: 0.120543, green: 0.122844, blue: 0.141312),
            codeText: Color.white.opacity(0.85),
            primaryText: Color.white.opacity(0.94),
            secondaryText: Color(red: 0.423943, green: 0.474618, blue: 0.525183),
            tertiaryText: Color(red: 0.258298, green: 0.300954, blue: 0.355207),
            accent: Color(red: 0.330191, green: 0.511266, blue: 0.998589),
            warning: Color(red: 0.937255, green: 0.717647, blue: 0.34902),
            success: Color(red: 0.309804, green: 0.788235, blue: 0.254902),
            goalActive: Color(red: 0.988394, green: 0.37355, blue: 0.638329),
            voiceRecording: Color(red: 0.362946, green: 0.846428, blue: 0.998966),
            voiceWaveformGradient: [
                Color(red: 0.362946, green: 0.846428, blue: 0.998966),
                Color(red: 0.631373, green: 0.403922, blue: 0.901961),
                Color(red: 0.988394, green: 0.37355, blue: 0.638329)
            ],
            border: Color(red: 0.253475, green: 0.2594, blue: 0.286485),
            selectionFill: Color(red: 0.317647, green: 0.356862, blue: 0.439215)
        )
    }

    private var gruvboxLightTokens: ThemeTokens {
        ThemeTokens(
            preset: .gruvbox,
            resolvedScheme: .light,
            background: Color(red: 0.96, green: 0.91, blue: 0.82),
            surface: Color(red: 0.98, green: 0.94, blue: 0.85),
            elevatedSurface: Color(red: 0.90, green: 0.84, blue: 0.72),
            userBubble: Color(red: 0.69, green: 0.38, blue: 0.10).opacity(0.20),
            assistantBubble: Color(red: 0.98, green: 0.94, blue: 0.85),
            systemBubble: Color(red: 0.88, green: 0.81, blue: 0.68),
            codeBlock: Color(red: 0.20, green: 0.19, blue: 0.16),
            codeText: Color(red: 0.93, green: 0.86, blue: 0.68),
            primaryText: Color(red: 0.22, green: 0.18, blue: 0.13),
            secondaryText: Color(red: 0.42, green: 0.35, blue: 0.25),
            tertiaryText: Color(red: 0.58, green: 0.50, blue: 0.38),
            accent: Color(red: 0.69, green: 0.38, blue: 0.10),
            warning: Color(red: 0.80, green: 0.42, blue: 0.10),
            success: Color(red: 0.49, green: 0.53, blue: 0.17),
            goalActive: Color(red: 0.03, green: 0.40, blue: 0.47),
            voiceRecording: Color(red: 0.80, green: 0.42, blue: 0.10),
            voiceWaveformGradient: [
                Color(red: 0.86, green: 0.52, blue: 0.15),
                Color(red: 0.80, green: 0.42, blue: 0.10),
                Color(red: 0.59, green: 0.31, blue: 0.08)
            ],
            border: Color(red: 0.72, green: 0.64, blue: 0.50),
            selectionFill: Color(red: 0.69, green: 0.38, blue: 0.10).opacity(0.17)
        )
    }

    private var gruvboxDarkTokens: ThemeTokens {
        ThemeTokens(
            preset: .gruvbox,
            resolvedScheme: .dark,
            background: Color(red: 0.16, green: 0.15, blue: 0.13),
            surface: Color(red: 0.20, green: 0.19, blue: 0.16),
            elevatedSurface: Color(red: 0.27, green: 0.25, blue: 0.21),
            userBubble: Color(red: 0.84, green: 0.55, blue: 0.22).opacity(0.28),
            assistantBubble: Color(red: 0.20, green: 0.19, blue: 0.16),
            systemBubble: Color(red: 0.28, green: 0.26, blue: 0.22),
            codeBlock: Color(red: 0.11, green: 0.10, blue: 0.09),
            codeText: Color(red: 0.93, green: 0.86, blue: 0.68),
            primaryText: Color(red: 0.92, green: 0.86, blue: 0.70),
            secondaryText: Color(red: 0.74, green: 0.67, blue: 0.52),
            tertiaryText: Color(red: 0.58, green: 0.53, blue: 0.42),
            accent: Color(red: 0.84, green: 0.55, blue: 0.22),
            warning: Color(red: 0.98, green: 0.56, blue: 0.25),
            success: Color(red: 0.72, green: 0.73, blue: 0.36),
            goalActive: Color(red: 0.51, green: 0.65, blue: 0.60),
            voiceRecording: Color(red: 0.98, green: 0.56, blue: 0.25),
            voiceWaveformGradient: [
                Color(red: 0.98, green: 0.66, blue: 0.28),
                Color(red: 0.98, green: 0.56, blue: 0.25),
                Color(red: 0.75, green: 0.39, blue: 0.18)
            ],
            border: Color(red: 0.38, green: 0.35, blue: 0.29),
            selectionFill: Color(red: 0.84, green: 0.55, blue: 0.22).opacity(0.20)
        )
    }

    private var meadowLightTokens: ThemeTokens {
        // 绿只落在有意义的位置上，不铺在大块背景里。
        //
        // 上一版几乎每个 token 都带绿：底、浮层、系统气泡、描边，连正文和次级文字
        // 都是墨绿。绿因此不是点缀而是整个系统，满屏都在喊同一件事，真正需要被看见的
        // 主操作和状态反而没了重量。这一版把所有大面积的底色、浮层和文字收回中性，
        // 绿集中到五处：主操作、用户气泡、代码块、语义色、选中填充。
        //
        // 鼠尾草绿 #2B6140 压白字 7.3:1。它比上一版的森林墨绿浅一档、饱和度更低，
        // 按钮一眼能认出是绿色而不是近黑；也不再有 #0DB83B 那种高饱和跳色，
        // 整套只剩一个绿家族。
        ThemeTokens(
            preset: .meadow,
            resolvedScheme: .light,
            background: Color(red: 245.0 / 255.0, green: 245.0 / 255.0, blue: 243.0 / 255.0),
            surface: .white,
            elevatedSurface: Color(red: 239.0 / 255.0, green: 239.0 / 255.0, blue: 237.0 / 255.0),
            // 页面上唯一大面积的绿，薄荷底 #E2EDE6 压近黑正文 14.1:1。
            userBubble: Color(red: 226.0 / 255.0, green: 237.0 / 255.0, blue: 230.0 / 255.0),
            assistantBubble: .white,
            systemBubble: Color(red: 239.0 / 255.0, green: 239.0 / 255.0, blue: 237.0 / 255.0),
            // 代码块保留深绿分区的做法，与页面形成明确明暗反差。
            codeBlock: Color(red: 36.0 / 255.0, green: 64.0 / 255.0, blue: 47.0 / 255.0),
            codeText: Color(red: 242.0 / 255.0, green: 246.0 / 255.0, blue: 242.0 / 255.0),
            primaryText: Color(red: 27.0 / 255.0, green: 29.0 / 255.0, blue: 28.0 / 255.0),
            secondaryText: Color(red: 94.0 / 255.0, green: 97.0 / 255.0, blue: 95.0 / 255.0),
            tertiaryText: Color(red: 138.0 / 255.0, green: 141.0 / 255.0, blue: 139.0 / 255.0),
            accent: Color(red: 43.0 / 255.0, green: 97.0 / 255.0, blue: 64.0 / 255.0),
            // 琥珀压在 elevatedSurface 上要保住 4.5:1。
            warning: Color(red: 0.58, green: 0.35, blue: 0.00),
            success: Color(red: 47.0 / 255.0, green: 107.0 / 255.0, blue: 71.0 / 255.0),
            goalActive: Color(red: 61.0 / 255.0, green: 130.0 / 255.0, blue: 89.0 / 255.0),
            voiceRecording: Color(red: 53.0 / 255.0, green: 120.0 / 255.0, blue: 79.0 / 255.0),
            voiceWaveformGradient: [
                Color(red: 61.0 / 255.0, green: 130.0 / 255.0, blue: 89.0 / 255.0),
                Color(red: 53.0 / 255.0, green: 120.0 / 255.0, blue: 79.0 / 255.0),
                Color(red: 43.0 / 255.0, green: 97.0 / 255.0, blue: 64.0 / 255.0)
            ],
            border: Color(red: 228.0 / 255.0, green: 228.0 / 255.0, blue: 226.0 / 255.0),
            selectionFill: Color(red: 226.0 / 255.0, green: 237.0 / 255.0, blue: 230.0 / 255.0)
        )
    }

    private var meadowDarkTokens: ThemeTokens {
        // 与浅色同一条原则：底、面、浮层、描边和文字全部中性石墨，绿只留在
        // 主操作、用户气泡、语义色和选中填充上。上一版这些位置全是偏绿的中性灰，
        // 深色下叠起来整屏发绿，反而看不出哪里是强调。
        //
        // 主操作 #6FAF86 压底 7.1:1、压黑字 8.2:1，是浅色鼠尾草绿在深底上的对应档。
        ThemeTokens(
            preset: .meadow,
            resolvedScheme: .dark,
            background: Color(red: 21.0 / 255.0, green: 21.0 / 255.0, blue: 21.0 / 255.0),
            surface: Color(red: 31.0 / 255.0, green: 31.0 / 255.0, blue: 31.0 / 255.0),
            elevatedSurface: Color(red: 41.0 / 255.0, green: 41.0 / 255.0, blue: 41.0 / 255.0),
            userBubble: Color(red: 34.0 / 255.0, green: 64.0 / 255.0, blue: 47.0 / 255.0),
            assistantBubble: Color(red: 31.0 / 255.0, green: 31.0 / 255.0, blue: 31.0 / 255.0),
            systemBubble: Color(red: 41.0 / 255.0, green: 41.0 / 255.0, blue: 41.0 / 255.0),
            codeBlock: Color(red: 16.0 / 255.0, green: 16.0 / 255.0, blue: 16.0 / 255.0),
            codeText: Color(red: 232.0 / 255.0, green: 232.0 / 255.0, blue: 232.0 / 255.0),
            primaryText: Color(red: 233.0 / 255.0, green: 233.0 / 255.0, blue: 233.0 / 255.0),
            secondaryText: Color(red: 168.0 / 255.0, green: 168.0 / 255.0, blue: 168.0 / 255.0),
            tertiaryText: Color(red: 126.0 / 255.0, green: 126.0 / 255.0, blue: 126.0 / 255.0),
            accent: Color(red: 111.0 / 255.0, green: 175.0 / 255.0, blue: 134.0 / 255.0),
            warning: Color(red: 0.94, green: 0.71, blue: 0.38),
            success: Color(red: 111.0 / 255.0, green: 175.0 / 255.0, blue: 134.0 / 255.0),
            goalActive: Color(red: 168.0 / 255.0, green: 212.0 / 255.0, blue: 184.0 / 255.0),
            voiceRecording: Color(red: 107.0 / 255.0, green: 170.0 / 255.0, blue: 130.0 / 255.0),
            voiceWaveformGradient: [
                Color(red: 168.0 / 255.0, green: 212.0 / 255.0, blue: 184.0 / 255.0),
                Color(red: 107.0 / 255.0, green: 170.0 / 255.0, blue: 130.0 / 255.0),
                Color(red: 111.0 / 255.0, green: 175.0 / 255.0, blue: 134.0 / 255.0)
            ],
            border: Color(red: 51.0 / 255.0, green: 51.0 / 255.0, blue: 51.0 / 255.0),
            selectionFill: Color(red: 111.0 / 255.0, green: 175.0 / 255.0, blue: 134.0 / 255.0).opacity(0.20)
        )
    }

    private func persistVisualState() {
        defaults.set(mode.rawValue, forKey: Keys.mode)
        defaults.set(preset.rawValue, forKey: Keys.preset)
        defaults.set(uiFontPreset.rawValue, forKey: Keys.uiFont)
        defaults.set(codeFontPreset.rawValue, forKey: Keys.codeFont)
        defaults.set(fontScale, forKey: Keys.fontScale)
        hasStoredFontScale = true
        themeVersion += 1
        defaults.set(themeVersion, forKey: Keys.themeVersion)
    }
}
