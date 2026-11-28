import SwiftUI
import UIKit

struct ModelReasoningGridSelection: Equatable {
    let modelID: String
    let effort: CodexAppServerReasoningEffort?
}

enum ModelReasoningGridKind: Equatable {
    case codex
    case claude
    case antigravity
    case deepSeek
}

enum ModelReasoningGridMetrics {
    static let contentPadding: CGFloat = 12
    static let headerHeight: CGFloat = 44
    static let sectionSpacing: CGFloat = 8
    static let effortHeaderHeight: CGFloat = 56
    static let modelRowHeight: CGFloat = 52
    static let modelLabelWidth: CGFloat = 112
    static let gridSpacing: CGFloat = 8
    static let fastModeHitTarget: CGFloat = 44
    static let fastModeVisualDiameter: CGFloat = 36
    static let selectionLensDiameter: CGFloat = 26
    static let selectionLensHaloDiameter: CGFloat = 38
    /// 选中带内联档位标签（如 Luna `max`）的格子时，选中圆点收紧并上移，彻底避开底部标签文字。
    static let inlineLabelSelectionLensDiameter: CGFloat = 14
    static let inlineLabelSelectionLensHaloDiameter: CGFloat = 20
    static let inlineLabelSelectionLensTopInset: CGFloat = 8
    static let inlineLabelSelectedBottomPadding: CGFloat = 6
    static let inlineLabelEstimatedHeight: CGFloat = 14
    static let dragCancellationMargin: CGFloat = 12
    /// 与手机底部展开态输入卡保持一致的连续圆角半径。
    static let panelCornerRadius: CGFloat = 26
    /// 与 iPad 宽档输入卡保持一致的连续圆角半径。
    static let regularPopoverCornerRadius: CGFloat = 20

    static func standardContentHeight(modelRowCount: Int) -> CGFloat {
        let visibleRowCount = max(modelRowCount, 0)
        return contentPadding * 2
            + effortHeaderHeight
            + CGFloat(visibleRowCount) * modelRowHeight
    }
}

/// 模型切换面板的展示容器形态：
/// - iPhone 标准字号竖屏与常规宽档保持悬浮 Popover（无全屏压暗遮罩，与输入框和「+」面板视觉统一）；
/// - 横屏、辅助功能大字号与 iPad 分屏窄档退化为 Sheet。
enum ModelReasoningGridPresentationContainer: Equatable {
    case compactSheet
    case compactPopover
    case regularPopover

    static func resolve(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        usesFloatingGlass: Bool = false,
        isAccessibilitySize: Bool = false
    ) -> Self {
        if verticalSizeClass == .compact {
            return .compactSheet
        }
        if horizontalSizeClass == .compact {
            if usesFloatingGlass && !isAccessibilitySize {
                return .compactPopover
            }
            return .compactSheet
        }
        return .regularPopover
    }

    var isSheet: Bool {
        self == .compactSheet
    }
}

/// 模型切换面板的表面呈现模式。
enum ModelReasoningGridSurfaceMode: Equatable {
    /// 独立嵌入或既有快照基线使用的实色底板（`tokens.surface`）。
    case standaloneOpaque
    /// 展示态：按实际输入卡形态（悬浮玻璃或实色输入卡）与容器形态（Popover 或 Sheet）选择表面与承载路径。
    case presentation(
        container: ModelReasoningGridPresentationContainer,
        usesFloatingGlass: Bool
    )

    /// 紧凑玻璃 Popover 简写。
    static var presentationChrome: Self {
        .presentation(container: .compactPopover, usesFloatingGlass: true)
    }
}

/// 生产渲染直接消费的表面材质结果，与 `ComposerCardResolvedSurface` 一一对应。
enum ModelReasoningGridSurfaceStyle: Equatable {
    /// 独立嵌入默认实色（`tokens.surface`）。
    case standaloneSurface
    /// 与输入卡一致的实色底板（浅色 `tokens.inputBackground`，深色 `tokens.elevatedSurface`）。
    case solidComposerCard
    /// iOS 26+ 玻璃模式下与悬浮输入卡一致的单层原生 Liquid Glass。
    case liquidGlass
    /// iOS 26 以下玻璃模式下与悬浮输入卡一致的 `.ultraThinMaterial`。
    case ultraThinMaterial

    var composerCardSurface: ComposerCardResolvedSurface {
        switch self {
        case .liquidGlass:
            return .liquidGlass
        case .ultraThinMaterial:
            return .ultraThinMaterial
        case .solidComposerCard, .standaloneSurface:
            return .solidCard
        }
    }
}

/// 共享背景的实际承载者：避免在 iOS 26 原生 Liquid Glass 容器上叠加双层玻璃，
/// 同时确保实色 Popover 与箭头底色严丝合缝。
enum ModelReasoningGridBackgroundOwner: Equatable {
    /// 独立嵌入，由内容层铺 `tokens.surface`。
    case standaloneContent
    /// 紧凑 Sheet 或单层原生玻璃 Popover 由 presentation 容器承载，内容层透明。
    case sheetPresentationBackground
    /// 实色 Popover 由内容根背景绘制共享表面，并同步 `.presentationBackground` 对齐箭头底色。
    case popoverContentSurface
}

/// 生产路径直接消费的完整表面策略。
struct ModelReasoningGridSurfacePolicy: Equatable {
    let surfaceStyle: ModelReasoningGridSurfaceStyle
    let backgroundOwner: ModelReasoningGridBackgroundOwner
    let usesFloatingGlass: Bool
    let usesTranslucentInnerChrome: Bool
    let cornerRadius: CGFloat
    let borderWidth: CGFloat
}

/// 模型切换面板与底部输入框共用的表面策略决策，生产视图与测试消费同一套解析结果。
enum ModelReasoningGridPresentationChrome {
    static func resolvePolicy(
        surfaceMode: ModelReasoningGridSurfaceMode,
        interfaceStyle: ThemeInterfaceStyle = .glass,
        reduceTransparency: Bool,
        increasedContrast: Bool = false,
        supportsLiquidGlass: Bool = WorkbenchGlassChromeStyle.supportsSystemLiquidGlass
    ) -> ModelReasoningGridSurfacePolicy {
        let borderWidth = Self.borderWidth(increasedContrast: increasedContrast)
        switch surfaceMode {
        case .standaloneOpaque:
            return ModelReasoningGridSurfacePolicy(
                surfaceStyle: .standaloneSurface,
                backgroundOwner: .standaloneContent,
                usesFloatingGlass: false,
                usesTranslucentInnerChrome: false,
                cornerRadius: ModelReasoningGridMetrics.regularPopoverCornerRadius,
                borderWidth: borderWidth
            )
        case let .presentation(container, usesFloatingGlass):
            let resolvedCardSurface = ComposerCardResolvedSurface.resolve(
                usesFloatingGlass: usesFloatingGlass,
                interfaceStyle: interfaceStyle,
                reduceTransparency: reduceTransparency,
                increasedContrast: increasedContrast,
                supportsLiquidGlass: supportsLiquidGlass
            )
            let surfaceStyle: ModelReasoningGridSurfaceStyle = switch resolvedCardSurface {
            case .liquidGlass: .liquidGlass
            case .ultraThinMaterial: .ultraThinMaterial
            case .solidCard: .solidComposerCard
            }
            let usesActiveGlass = resolvedCardSurface != .solidCard
            let backgroundOwner: ModelReasoningGridBackgroundOwner =
                (container == .compactSheet || usesActiveGlass)
                ? .sheetPresentationBackground
                : .popoverContentSurface
            let cornerRadius = (container == .regularPopover)
                ? ModelReasoningGridMetrics.regularPopoverCornerRadius
                : ModelReasoningGridMetrics.panelCornerRadius
            return ModelReasoningGridSurfacePolicy(
                surfaceStyle: surfaceStyle,
                backgroundOwner: backgroundOwner,
                usesFloatingGlass: usesFloatingGlass,
                usesTranslucentInnerChrome: usesActiveGlass,
                cornerRadius: cornerRadius,
                borderWidth: borderWidth
            )
        }
    }

    static func solidFillColor(
        tokens: ThemeTokens,
        colorScheme: ColorScheme
    ) -> Color {
        ComposerPopupPresentationSurface.solidFillColor(
            tokens: tokens,
            colorScheme: colorScheme
        )
    }

    static func solidBorderColor(
        tokens: ThemeTokens,
        colorScheme: ColorScheme,
        increasedContrast: Bool
    ) -> Color {
        ComposerPopupPresentationSurface.solidBorderColor(
            tokens: tokens,
            colorScheme: colorScheme,
            increasedContrast: increasedContrast
        )
    }

    static func borderWidth(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? 1.25 : 0.75
    }

    static func presentationDetents(
        layout: ModelReasoningGridLayout,
        isAccessibilitySize: Bool
    ) -> Set<PresentationDetent> {
        if isAccessibilitySize {
            return [.large]
        }
        return [.height(layout.standardContentHeight)]
    }
}

/// 模型切换面板各文本与内层控件的对比度校准色板。
/// 深色强调小字使用 `tokens.accentText`，浅色在 `elevatedSurface` 上对比度不足的主题
///（Xcode 浅色、Gruvbox 浅色）提供同色相加深档，保证实色回退与全主题下小字均 ≥ 4.5:1。
struct ModelReasoningGridPalette {
    let panelBackground: Color
    let controlFill: Color
    let controlBorder: Color
    let controlBorderWidth: CGFloat
    let gridFill: Color
    let gridBorder: Color
    let gridBorderWidth: CGFloat
    let gridLine: Color
    let selectedCellFill: Color
    let primaryForeground: Color
    let rowLabelForeground: Color
    let accentForeground: Color
    let inlineEffortForeground: Color
    let disabledInlineEffortForeground: Color
    let dotForeground: Color
    let disabledDotForeground: Color
    let selectedDotForeground: Color
    let accessibleMenuFill: Color
    let accessibleEffortFill: Color
    let accessibleRowBorder: Color?
    let accessibleRowBorderWidth: CGFloat

    static func accentSmallTextColor(tokens: ThemeTokens) -> Color {
        if tokens.resolvedScheme == .dark {
            return tokens.accentText
        }
        switch tokens.preset {
        case .xcode:
            // Xcode 系统蓝 #007AFF 压在浅灰 elevatedSurface 上仅 3.41:1，
            // 同色相压暗到 #0057CC，保证面板/胶囊/选中格均 ≥ 5.5:1。
            return Color(red: 0.00, green: 0.34, blue: 0.80)
        case .gruvbox:
            // Gruvbox 暖琥珀压在暖灰 elevatedSurface 上仅 3.21:1，
            // 同色相压暗到 #80400A，保证面板/胶囊/选中格均 ≥ 5.5:1。
            return Color(red: 0.50, green: 0.25, blue: 0.04)
        case .codex, .github, .meadow:
            return tokens.accentText
        }
    }

    static func resolve(
        tokens: ThemeTokens,
        colorScheme: ColorScheme,
        policy: ModelReasoningGridSurfacePolicy,
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> Self {
        let accentForeground = accentSmallTextColor(tokens: tokens)
        if policy.usesTranslucentInnerChrome {
            let pillFill = ComposerEmbeddedPillPalette.fill(
                tokens: tokens,
                reduceTransparency: false,
                increasedContrast: false
            )
            let pillBorder = ComposerEmbeddedPillPalette.border(
                tokens: tokens,
                reduceTransparency: false,
                increasedContrast: false
            )
            let panelBackground = ModelReasoningGridPresentationChrome.solidFillColor(
                tokens: tokens,
                colorScheme: colorScheme
            )
            // 九宫格大面板面积远大于输入卡顶部小药丸，改用更轻透的微弱层次，
            // 避免在单层 Liquid Glass 上蒙出一整块灰白雾板而破坏与输入框的通透一致性。
            let gridFill = (colorScheme == .light ? Color.black : Color.white)
                .opacity(colorScheme == .light ? 0.025 : 0.035)
            return Self(
                panelBackground: panelBackground,
                controlFill: pillFill,
                controlBorder: pillBorder,
                controlBorderWidth: 0.75,
                gridFill: gridFill,
                gridBorder: pillBorder,
                gridBorderWidth: 0.75,
                gridLine: (colorScheme == .light ? Color.black : Color.white)
                    .opacity(colorScheme == .light ? 0.08 : 0.12),
                selectedCellFill: tokens.accent.opacity(colorScheme == .light ? 0.10 : 0.12),
                primaryForeground: tokens.primaryText,
                rowLabelForeground: tokens.primaryText.opacity(colorScheme == .light ? 0.78 : 0.80),
                accentForeground: accentForeground,
                inlineEffortForeground: tokens.primaryText.opacity(0.78),
                disabledInlineEffortForeground: tokens.primaryText.opacity(0.26),
                dotForeground: (colorScheme == .light ? Color.black : Color.white)
                    .opacity(colorScheme == .light ? 0.34 : 0.42),
                disabledDotForeground: (colorScheme == .light ? Color.black : Color.white).opacity(0.14),
                selectedDotForeground: tokens.accent.opacity(0.36),
                accessibleMenuFill: pillFill,
                accessibleEffortFill: pillFill,
                accessibleRowBorder: pillBorder,
                accessibleRowBorderWidth: 0.75
            )
        }

        if policy.surfaceStyle == .standaloneSurface {
            let border = increasedContrast
                ? ModelReasoningGridPresentationChrome.solidBorderColor(
                    tokens: tokens,
                    colorScheme: colorScheme,
                    increasedContrast: true
                )
                : tokens.border.opacity(0.58)
            let gridBorder = increasedContrast
                ? border
                : tokens.border.opacity(0.72)
            return Self(
                panelBackground: tokens.surface,
                controlFill: tokens.elevatedSurface.opacity(0.72),
                controlBorder: border,
                controlBorderWidth: increasedContrast ? 1.0 : 0.75,
                gridFill: tokens.elevatedSurface.opacity(reduceTransparency ? 1 : 0.56),
                gridBorder: gridBorder,
                gridBorderWidth: increasedContrast ? 1.0 : 0.75,
                gridLine: tokens.border.opacity(0.46),
                selectedCellFill: tokens.accent.opacity(0.055),
                primaryForeground: tokens.primaryText,
                rowLabelForeground: increasedContrast ? tokens.primaryText : tokens.secondaryText,
                accentForeground: accentForeground,
                inlineEffortForeground: increasedContrast
                    ? tokens.primaryText
                    : tokens.tertiaryText.opacity(0.72),
                disabledInlineEffortForeground: tokens.tertiaryText.opacity(0.24),
                dotForeground: tokens.tertiaryText.opacity(0.34),
                disabledDotForeground: tokens.tertiaryText.opacity(0.12),
                selectedDotForeground: tokens.accent.opacity(0.3),
                accessibleMenuFill: tokens.elevatedSurface,
                accessibleEffortFill: tokens.elevatedSurface.opacity(0.72),
                accessibleRowBorder: increasedContrast ? border : nil,
                accessibleRowBorderWidth: increasedContrast ? 1.0 : 0.75
            )
        }

        // `.solidComposerCard`：常规 iPad Popover、iPad 分屏 Sheet、经典模式或辅助功能实色回退。
        // 面板底与输入卡一致（浅色 `inputBackground`，深色 `elevatedSurface`）；
        // 当面板已落到 `elevatedSurface` 时，内层网格与胶囊切回 `tokens.surface` 建立清晰层级并提高对比度。
        let panelBackground = ModelReasoningGridPresentationChrome.solidFillColor(
            tokens: tokens,
            colorScheme: colorScheme
        )
        let innerControlFill: Color = (tokens.preset == .codex && colorScheme == .light)
            ? tokens.elevatedSurface
            : tokens.surface
        let controlBorder = increasedContrast
            ? ModelReasoningGridPresentationChrome.solidBorderColor(
                tokens: tokens,
                colorScheme: colorScheme,
                increasedContrast: true
            )
            : tokens.border.opacity(colorScheme == .light ? 0.75 : 0.72)
        let strokeWidth: CGFloat = increasedContrast ? 1.0 : 0.75
        let readableSecondary = increasedContrast
            ? tokens.primaryText
            : tokens.primaryText.opacity(0.78)
        return Self(
            panelBackground: panelBackground,
            controlFill: innerControlFill,
            controlBorder: controlBorder,
            controlBorderWidth: strokeWidth,
            gridFill: innerControlFill,
            gridBorder: controlBorder,
            gridBorderWidth: strokeWidth,
            gridLine: tokens.border.opacity(increasedContrast ? 0.78 : 0.54),
            selectedCellFill: tokens.accent.opacity(0.08),
            primaryForeground: tokens.primaryText,
            rowLabelForeground: readableSecondary,
            accentForeground: accentForeground,
            inlineEffortForeground: readableSecondary,
            disabledInlineEffortForeground: tokens.primaryText.opacity(0.30),
            dotForeground: tokens.primaryText.opacity(increasedContrast ? 0.56 : 0.36),
            disabledDotForeground: tokens.primaryText.opacity(0.16),
            selectedDotForeground: tokens.accent.opacity(0.36),
            accessibleMenuFill: innerControlFill,
            accessibleEffortFill: innerControlFill,
            accessibleRowBorder: controlBorder,
            accessibleRowBorderWidth: strokeWidth
        )
    }
}

/// 模型切换面板的展示层背景：复用输入框同源的 `ComposerCardSurfaceModifier` 与实色底板策略。
struct ModelReasoningGridPresentationBackground: View {
    let policy: ModelReasoningGridSurfacePolicy
    let tokens: ThemeTokens
    let colorScheme: ColorScheme
    let reduceTransparency: Bool
    let increasedContrast: Bool
    var usesPopoverSurfaceChrome: Bool = false

    var body: some View {
        let resolvedSurface = policy.surfaceStyle.composerCardSurface
        let shape = RoundedRectangle(cornerRadius: policy.cornerRadius, style: .continuous)
        if usesPopoverSurfaceChrome && resolvedSurface == .solidCard {
            shape.fill(ModelReasoningGridPresentationChrome.solidFillColor(tokens: tokens, colorScheme: colorScheme))
        } else {
            let borderColor: Color = usesPopoverSurfaceChrome
                ? .clear
                : ModelReasoningGridPresentationChrome.solidBorderColor(
                    tokens: tokens,
                    colorScheme: colorScheme,
                    increasedContrast: increasedContrast
                )
            Color.clear.modifier(
                ComposerCardSurfaceModifier(
                    shape: shape,
                    tokens: tokens,
                    colorScheme: colorScheme,
                    reduceTransparency: reduceTransparency,
                    increasedContrast: increasedContrast,
                    usesFloatingGlass: policy.usesFloatingGlass,
                    voiceAccentBorderColor: nil,
                    solidBorderColor: borderColor,
                    borderWidth: usesPopoverSurfaceChrome ? 0 : policy.borderWidth,
                    explicitResolvedSurface: resolvedSurface
                )
            )
        }
    }
}

struct ModelReasoningGridLayout: Equatable {
    let kind: ModelReasoningGridKind
    let models: [CodexAppServerModelOption]
    let efforts: [CodexAppServerReasoningEffort]
    let showsServiceTierControl: Bool

    var modelRowCount: Int {
        models.count
    }

    var effortColumnCount: Int {
        efforts.count
    }

    var standardContentHeight: CGFloat {
        ModelReasoningGridMetrics.standardContentHeight(modelRowCount: modelRowCount)
    }

    /// 返回某个模型在标准网格各列实际对应的推理档位。
    /// Codex 的模型能力并不完全一致：Sol/Terra 的第四列是 Ultra，Luna
    /// 的同一位置应落到它真实支持的 Max，列数保持不变以维持网格布局。
    func efforts(for option: CodexAppServerModelOption?) -> [CodexAppServerReasoningEffort] {
        guard let option else { return efforts }
        return ModelReasoningGridCatalog.standardEfforts(
            for: option,
            columns: efforts,
            kind: kind
        )
    }

    func effort(for option: CodexAppServerModelOption, column: Int) -> CodexAppServerReasoningEffort? {
        let modelEfforts = efforts(for: option)
        guard modelEfforts.indices.contains(column) else { return nil }
        return modelEfforts[column]
    }

    func effortColumn(
        for effort: CodexAppServerReasoningEffort,
        option: CodexAppServerModelOption
    ) -> Int? {
        efforts(for: option).firstIndex(of: effort)
    }

    /// 标准表头保持统一；当某个模型用不同协议档位复用该列时，
    /// 只在对应格子内显示真实协议值，避免把整列表头改成模型专属文案。
    func inlineEffortLabel(
        for option: CodexAppServerModelOption,
        column: Int
    ) -> String? {
        guard efforts.indices.contains(column),
              let mappedEffort = effort(for: option, column: column),
              mappedEffort != efforts[column]
        else {
            return nil
        }
        return mappedEffort.rawValue
    }

    func model(matching modelID: String?) -> CodexAppServerModelOption? {
        guard let modelID else { return nil }
        return models.first { $0.model.caseInsensitiveCompare(modelID) == .orderedSame }
    }

    func contains(modelID: String?) -> Bool {
        model(matching: modelID) != nil
    }

    func selection(
        modelRow: Int,
        effortColumn: Int
    ) -> ModelReasoningGridSelection? {
        guard models.indices.contains(modelRow),
              efforts.indices.contains(effortColumn)
        else {
            return nil
        }
        guard let effort = effort(for: models[modelRow], column: effortColumn) else {
            return nil
        }
        return ModelReasoningGridSelection(
            modelID: models[modelRow].model,
            effort: effort
        )
    }

    /// 选中圆点（及外环光晕）的几何位置：普通格居中 26pt；带内联档位标签（如 Luna `max`）的格子
    /// 收紧至 14pt 并上移到格顶，与格底标签彻底错开，避免不透明圆点遮挡内联文字。
    func selectionLensGeometry(
        for selection: ModelReasoningGridSelection,
        size: CGSize
    ) -> ModelReasoningGridLensGeometry? {
        guard let effort = selection.effort,
              effortColumnCount > 0,
              modelRowCount > 0,
              size.width > 0,
              size.height > 0,
              let row = models.firstIndex(where: { $0.model == selection.modelID }),
              let column = effortColumn(for: effort, option: models[row]),
              ModelReasoningGridCatalog.isStandardEffortAvailable(
                  effort,
                  option: models[row],
                  layout: self
              )
        else {
            return nil
        }
        let cellWidth = size.width / CGFloat(effortColumnCount)
        let cellHeight = size.height / CGFloat(modelRowCount)
        let cellMinX = CGFloat(column) * cellWidth
        let cellMinY = CGFloat(row) * cellHeight
        let avoidsInlineLabel = inlineEffortLabel(for: models[row], column: column) != nil
        let lensDiameter = avoidsInlineLabel
            ? ModelReasoningGridMetrics.inlineLabelSelectionLensDiameter
            : ModelReasoningGridMetrics.selectionLensDiameter
        let haloDiameter = avoidsInlineLabel
            ? ModelReasoningGridMetrics.inlineLabelSelectionLensHaloDiameter
            : ModelReasoningGridMetrics.selectionLensHaloDiameter
        let centerY = avoidsInlineLabel
            ? cellMinY + ModelReasoningGridMetrics.inlineLabelSelectionLensTopInset + lensDiameter / 2
            : cellMinY + cellHeight / 2
        return ModelReasoningGridLensGeometry(
            center: CGPoint(x: cellMinX + cellWidth / 2, y: centerY),
            lensDiameter: lensDiameter,
            haloDiameter: haloDiameter,
            avoidsInlineLabel: avoidsInlineLabel
        )
    }

    /// 带内联档位标签的格子中文字占据区域，供生产布局校验与无遮挡测试复用。
    func inlineEffortLabelFrame(
        for selection: ModelReasoningGridSelection,
        isSelected: Bool,
        size: CGSize
    ) -> CGRect? {
        guard let effort = selection.effort,
              effortColumnCount > 0,
              modelRowCount > 0,
              size.width > 0,
              size.height > 0,
              let row = models.firstIndex(where: { $0.model == selection.modelID }),
              let column = effortColumn(for: effort, option: models[row]),
              inlineEffortLabel(for: models[row], column: column) != nil
        else {
            return nil
        }
        let cellWidth = size.width / CGFloat(effortColumnCount)
        let cellHeight = size.height / CGFloat(modelRowCount)
        let cellMinX = CGFloat(column) * cellWidth
        let cellMinY = CGFloat(row) * cellHeight
        let labelHeight = ModelReasoningGridMetrics.inlineLabelEstimatedHeight
        let labelMinY = isSelected
            ? cellMinY + cellHeight - ModelReasoningGridMetrics.inlineLabelSelectedBottomPadding - labelHeight
            : cellMinY + (cellHeight - labelHeight) / 2
        return CGRect(
            x: cellMinX + 4,
            y: labelMinY,
            width: max(cellWidth - 8, 1),
            height: labelHeight
        )
    }

    func dragCandidate(
        at point: CGPoint,
        size: CGSize,
        cancellationMargin: CGFloat = ModelReasoningGridMetrics.dragCancellationMargin
    ) -> ModelReasoningGridSelection? {
        guard !models.isEmpty,
              !efforts.isEmpty,
              size.width > 0,
              size.height > 0,
              point.x >= -cancellationMargin,
              point.x <= size.width + cancellationMargin,
              point.y >= -cancellationMargin,
              point.y <= size.height + cancellationMargin
        else {
            return nil
        }

        let x = min(max(point.x, 0), size.width - 0.001)
        let y = min(max(point.y, 0), size.height - 0.001)
        let column = min(
            effortColumnCount - 1,
            max(0, Int(x / (size.width / CGFloat(effortColumnCount))))
        )
        let row = min(
            modelRowCount - 1,
            max(0, Int(y / (size.height / CGFloat(modelRowCount))))
        )
        guard let candidate = selection(modelRow: row, effortColumn: column),
              let effort = candidate.effort,
              ModelReasoningGridCatalog.isStandardEffortAvailable(
                  effort,
                  option: models[row],
                  layout: self
              )
        else {
            return nil
        }
        return candidate
    }
}

struct ModelReasoningGridLensGeometry: Equatable {
    let center: CGPoint
    let lensDiameter: CGFloat
    let haloDiameter: CGFloat
    let avoidsInlineLabel: Bool

    var lensFrame: CGRect {
        CGRect(
            x: center.x - lensDiameter / 2,
            y: center.y - lensDiameter / 2,
            width: lensDiameter,
            height: lensDiameter
        )
    }

    var haloFrame: CGRect {
        CGRect(
            x: center.x - haloDiameter / 2,
            y: center.y - haloDiameter / 2,
            width: haloDiameter,
            height: haloDiameter
        )
    }
}

enum ModelReasoningGridCatalog {
    static let maximumModelCount = 3
    static let codexStandardEfforts: [CodexAppServerReasoningEffort] = [
        .medium,
        .high,
        .xhigh,
        .ultra
    ]
    static let claudeStandardEfforts: [CodexAppServerReasoningEffort] = [
        .medium,
        .high,
        .xhigh,
        .max
    ]

    static func preferredDefaultOption(
        runtimeProvider: String?,
        options: [CodexAppServerModelOption]
    ) -> CodexAppServerModelOption? {
        let normalizedRuntime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        let runtimeOptions = options.filter {
            !$0.hidden &&
                CodexAppServerSessionRuntime.normalizedRuntimeProvider($0.runtimeProvider) == normalizedRuntime
        }
        let fallbackOptions: [CodexAppServerModelOption]
        switch normalizedRuntime {
        case "claude": fallbackOptions = CodexAppServerModelOption.builtInClaudeFallback
        case "agy", "deepseek": fallbackOptions = []
        default: fallbackOptions = CodexAppServerModelOption.builtInFallback
        }
        let candidates = runtimeOptions.isEmpty ? fallbackOptions : runtimeOptions

        if normalizedRuntime == "codex", let astra = candidates.first(where: {
            $0.model.caseInsensitiveCompare("gpt-6-astra") == .orderedSame
        }) {
            return astra
        }

        // Claude 的动态目录以运行时标记的默认项为准；目录不可用时
        // built-in fallback 会用稳定 alias 提供默认项。
        return candidates.first(where: \.isDefault) ?? candidates.first
    }

    static func preferredDefaultEffort(
        runtimeProvider: String?,
        option: CodexAppServerModelOption?,
        layout: ModelReasoningGridLayout
    ) -> CodexAppServerReasoningEffort? {
        let normalizedRuntime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        let preferred: CodexAppServerReasoningEffort? = switch normalizedRuntime {
        case "claude": .high
        case "agy": .medium
        case "deepseek": nil
        default: .medium
        }
        return normalizedVisibleEffort(
            option: option,
            current: preferred,
            layout: layout
        )
    }

    static func effectiveModelID(
        selectedModelID: String?,
        options: [CodexAppServerModelOption]
    ) -> String? {
        if let selectedModelID = selectedModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedModelID.isEmpty {
            return selectedModelID
        }

        // model == nil 表示沿用服务端默认模型；只在展示层解析真实模型，
        // 提交时仍保留 nil，避免把动态默认值固化进草稿。
        let visibleOptions = options.filter { !$0.hidden }
        return (visibleOptions.first(where: \.isDefault) ?? visibleOptions.first)?.model
    }

    static func layout(
        runtimeProvider: String?,
        options: [CodexAppServerModelOption]
    ) -> ModelReasoningGridLayout {
        let visible = options.filter { !$0.hidden }
        let runtime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        let kind: ModelReasoningGridKind
        let fallbackOptions: [CodexAppServerModelOption]
        switch runtime {
        case "claude":
            kind = .claude
            fallbackOptions = CodexAppServerModelOption.builtInClaudeFallback
        case "agy":
            kind = .antigravity
            fallbackOptions = []
        case "deepseek":
            kind = .deepSeek
            fallbackOptions = []
        default:
            kind = .codex
            fallbackOptions = CodexAppServerModelOption.builtInFallback
        }
        let source = visible.isEmpty ? fallbackOptions : visible
        let models = Array(source.prefix(maximumModelCount))

        // 模型顺序完全沿用 model/list；能力策略只负责决定横向四列，不重排模型。
        return ModelReasoningGridLayout(
            kind: kind,
            models: models,
            efforts: standardEfforts(for: kind, options: models),
            showsServiceTierControl: source.contains {
                !serviceTiers(for: $0, kind: kind).isEmpty
            }
        )
    }

    static func standardEfforts(
        for kind: ModelReasoningGridKind
    ) -> [CodexAppServerReasoningEffort] {
        switch kind {
        case .codex: codexStandardEfforts
        case .claude: claudeStandardEfforts
        case .antigravity, .deepSeek: []
        }
    }

    static func standardEfforts(
        for kind: ModelReasoningGridKind,
        options: [CodexAppServerModelOption]
    ) -> [CodexAppServerReasoningEffort] {
        guard kind == .deepSeek || kind == .antigravity else { return standardEfforts(for: kind) }
        let declared = Set(options.flatMap(\.supportedReasoningEfforts))
        return CodexAppServerReasoningEffort.allCases.filter { declared.contains($0.rawValue) }
    }

    static func standardEfforts(
        for option: CodexAppServerModelOption,
        columns: [CodexAppServerReasoningEffort],
        kind: ModelReasoningGridKind
    ) -> [CodexAppServerReasoningEffort] {
        guard kind == .codex,
              columns.contains(.ultra),
              supports(.max, option: option, kind: kind),
              !supports(.ultra, option: option, kind: kind)
        else {
            return columns
        }

        // Luna 没有 Ultra，但有 Max；替换同一列而不是扩展列数，避免破坏
        // 现有四列网格的触控区域和布局高度。
        return columns.map { $0 == .ultra ? .max : $0 }
    }

    static func triggerTitle(
        for modelID: String,
        effort: CodexAppServerReasoningEffort,
        layout: ModelReasoningGridLayout
    ) -> String? {
        guard let option = layout.model(matching: modelID) else { return nil }
        return "\(shortTitle(for: option, kind: layout.kind)) · \(effortTitle(effort, kind: layout.kind))"
    }

    static func compactTriggerTitle(
        for modelID: String,
        layout: ModelReasoningGridLayout
    ) -> String? {
        guard let option = layout.model(matching: modelID) else { return nil }
        let title = shortTitle(for: option, kind: layout.kind)
        if layout.kind == .claude, title.hasPrefix("Claude ") {
            // 底部工具层已经由当前会话 runtime 提供上下文，省略重复的 Provider 前缀，
            // 让常见 Claude 模型在 iPhone 窄宽度下仍能完整显示为「Opus 5」。
            return String(title.dropFirst("Claude ".count))
        }
        if layout.kind == .codex, title.lowercased().hasPrefix("gpt-") {
            // 部分服务端标题使用「GPT-5.6-Sol」，部分使用「GPT-5.6 Sol」。
            // compact 标签统一成面向人的空格写法，避免真机底栏残留内部模型 ID 风格。
            return String(title.dropFirst("GPT-".count))
                .replacingOccurrences(of: "-", with: " ")
        }
        return title
    }

    static func compactTriggerTitle(
        for modelID: String,
        effort: CodexAppServerReasoningEffort,
        layout: ModelReasoningGridLayout
    ) -> String? {
        guard let title = compactTriggerTitle(for: modelID, layout: layout) else { return nil }
        // Claude 的模型名已经足够区分；Codex 同名模型的推理档位会显著影响行为，
        // 因此在手机底栏用短标签同步展示，完整名称仍留在模型面板与 VoiceOver。
        guard layout.kind == .codex else { return title }
        return "\(title) \(compactEffortTitle(effort))"
    }

    static func compactEffortTitle(_ effort: CodexAppServerReasoningEffort) -> String {
        switch effort {
        case .xhigh:
            return "XH"
        default:
            return effortTitle(effort)
        }
    }

    static func shortTitle(
        for option: CodexAppServerModelOption,
        kind _: ModelReasoningGridKind
    ) -> String {
        let title = option.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? option.model : title
    }

    static func effortTitle(_ effort: CodexAppServerReasoningEffort) -> String {
        // 产品档位固定使用英文名称，协议值仍保持原样，尤其不互换 Max 与 Ultra。
        switch effort {
        case .off:
            return "Off"
        case .none:
            return "None"
        case .minimal:
            return "Minimal"
        case .low:
            return "Light"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "Extra High"
        case .max:
            return "Max"
        case .ultra:
            return "Ultra"
        }
    }

    static func effortTitle(
        _ effort: CodexAppServerReasoningEffort,
        kind: ModelReasoningGridKind
    ) -> String {
        // Codex 沿用产品名 Light；Antigravity 与 DeepSeek 的原生档位名显示为 Low。
        (kind == .deepSeek || kind == .antigravity) && effort == .low ? "Low" : effortTitle(effort)
    }

    static func effortTitle(
        _ effort: CodexAppServerReasoningEffort,
        runtimeProvider: String?
    ) -> String {
        let normalized = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        return (normalized == "deepseek" || normalized == "agy")
            && effort == .low ? "Low" : effortTitle(effort)
    }

    static func supports(
        _ effort: CodexAppServerReasoningEffort,
        option: CodexAppServerModelOption,
        kind: ModelReasoningGridKind? = nil
    ) -> Bool {
        if effort == .off,
           !option.supportedReasoningEfforts.contains(effort.rawValue) {
            return false
        }
        let normalizedRuntime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(option.runtimeProvider)
        let requiresDeclaredEfforts = kind == .claude || kind == .deepSeek || kind == .antigravity
            || normalizedRuntime == "claude" || normalizedRuntime == "deepseek" || normalizedRuntime == "agy"
        if requiresDeclaredEfforts {
            // 非 Codex runtime 的空数组明确表示该模型不支持原生 reasoning effort。
            return option.supportedReasoningEfforts.contains(effort.rawValue)
        }
        // Codex 旧服务未返回元数据时，使用本地标准策略向后兼容。
        return option.supportedReasoningEfforts.isEmpty
            || option.supportedReasoningEfforts.contains(effort.rawValue)
    }

    static func allSupportedEfforts(
        for option: CodexAppServerModelOption?
    ) -> [CodexAppServerReasoningEffort] {
        guard let option else {
            return CodexAppServerReasoningEffort.allCases.filter { $0 != .off }
        }
        return CodexAppServerReasoningEffort.allCases.filter {
            supports($0, option: option)
        }
    }

    static func visibleEfforts(
        for option: CodexAppServerModelOption?,
        layout: ModelReasoningGridLayout
    ) -> [CodexAppServerReasoningEffort] {
        guard let option else { return [] }
        return layout.efforts(for: option).filter { supports($0, option: option, kind: layout.kind) }
    }

    static func isStandardEffortAvailable(
        _ effort: CodexAppServerReasoningEffort,
        option: CodexAppServerModelOption,
        layout: ModelReasoningGridLayout
    ) -> Bool {
        layout.efforts(for: option).contains(effort) && supports(effort, option: option, kind: layout.kind)
    }

    static func normalizedVisibleEffort(
        option: CodexAppServerModelOption?,
        current: CodexAppServerReasoningEffort?,
        layout: ModelReasoningGridLayout
    ) -> CodexAppServerReasoningEffort? {
        let visible = visibleEfforts(for: option, layout: layout)
        guard !visible.isEmpty else { return nil }

        if let current, visible.contains(current) {
            return current
        }
        if let defaultEffort = option?.defaultReasoningEffort
            .flatMap(CodexAppServerReasoningEffort.init(rawValue:)),
           visible.contains(defaultEffort) {
            return defaultEffort
        }
        if visible.contains(.medium) {
            return .medium
        }
        return visible.first
    }

    static func applySelection(
        option: CodexAppServerModelOption,
        effort: CodexAppServerReasoningEffort?,
        preservesServerDefault: Bool,
        fallbackRuntimeProvider: String?,
        to turnOptions: inout CodexAppServerTurnOptions
    ) {
        turnOptions.runtimeProvider = option.runtimeProvider ?? fallbackRuntimeProvider
        turnOptions.model = preservesServerDefault ? nil : option.model
        turnOptions.modelProvider = preservesServerDefault ? nil : option.provider
        turnOptions.reasoningEffort = effort
        turnOptions.serviceTier = normalizedServiceTier(
            turnOptions.serviceTier,
            option: option,
            kind: nil
        )
        if option.supportsPersonality == false {
            turnOptions.personality = nil
        }
    }

    static func serviceTiers(
        for option: CodexAppServerModelOption?,
        kind: ModelReasoningGridKind? = nil
    ) -> [CodexAppServerModelServiceTier] {
        guard let option else { return [] }
        let runtime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(option.runtimeProvider)
        guard kind == .codex || (kind == nil && runtime == "codex") else {
            // Claude bridge 偶尔会返回名为 standard 的目录值，但它不接受 Codex serviceTier。
            return []
        }
        if let declared = option.serviceTiers {
            return declared
        }
        // 0.155 之前的部分目录没有能力字段。仅在字段缺失时保留旧 Fast 行为；
        // 当前目录返回空数组时必须尊重它，不能按套餐或模型名称推测权限。
        return [CodexAppServerModelServiceTier(
            id: "priority",
            name: "Fast",
            description: "Priority processing"
        )]
    }

    static func normalizedServiceTier(
        _ serviceTier: String?,
        option: CodexAppServerModelOption?,
        kind: ModelReasoningGridKind? = nil,
        runtimeProvider: String? = nil,
        allowsUnlistedCodexTier: Bool = false
    ) -> String? {
        guard let serviceTier = serviceTier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appServerNilIfEmpty
        else { return nil }
        let runtime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(
            option?.runtimeProvider ?? runtimeProvider
        )
        guard kind == .codex || (kind == nil && runtime == "codex") else {
            return nil
        }
        // 开发者高级选项也服务于 API key 模型。协议允许自由字符串，因此只在
        // 明确的开发者边界保留目录外值；普通模型菜单继续严格服从账号目录。
        if allowsUnlistedCodexTier {
            return serviceTier
        }
        let tiers = serviceTiers(for: option, kind: kind)
        guard !tiers.isEmpty else { return nil }
        return tiers.contains { $0.id == serviceTier } ? serviceTier : nil
    }

    static func effectiveServiceTier(
        selectedServiceTier: String?,
        option: CodexAppServerModelOption?,
        kind: ModelReasoningGridKind? = nil
    ) -> CodexAppServerModelServiceTier? {
        guard let option else { return nil }
        let tiers = serviceTiers(for: option, kind: kind)
        guard let effectiveID = selectedServiceTier ?? option.defaultServiceTier else { return nil }
        return tiers.first { $0.id == effectiveID }
    }

    static func selectedOption(
        modelID: String?,
        options: [CodexAppServerModelOption]
    ) -> CodexAppServerModelOption? {
        guard let modelID = modelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appServerNilIfEmpty
        else { return options.first }
        return options.first { $0.model.caseInsensitiveCompare(modelID) == .orderedSame }
            ?? options.first
    }

    static func isAcceleratedServiceTier(_ tier: CodexAppServerModelServiceTier?) -> Bool {
        guard let tier else { return false }
        // standard/default/auto 是基线路由，不应显示为已开启加速。
        return !["standard", "default", "auto"].contains(tier.id.lowercased())
    }

}

struct ModelReasoningGridPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.themeInterfaceStyle) private var interfaceStyle

    let options: [CodexAppServerModelOption]
    let layout: ModelReasoningGridLayout
    let selection: ModelReasoningGridSelection
    let selectedModelID: String?
    let isRefreshing: Bool
    let selectedServiceTier: String?
    let surfaceMode: ModelReasoningGridSurfaceMode
    let onSelectModel: (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void
    let onSelectDefaultModel: (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void
    let onServiceTierChange: (String?) -> Void
    let onRefresh: () -> Void

    init(
        options: [CodexAppServerModelOption],
        layout: ModelReasoningGridLayout,
        selection: ModelReasoningGridSelection,
        selectedModelID: String?,
        isRefreshing: Bool,
        selectedServiceTier: String?,
        surfaceMode: ModelReasoningGridSurfaceMode = .standaloneOpaque,
        onSelectModel: @escaping (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void,
        onSelectDefaultModel: @escaping (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void,
        onServiceTierChange: @escaping (String?) -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.options = options
        self.layout = layout
        self.selection = selection
        self.selectedModelID = selectedModelID
        self.isRefreshing = isRefreshing
        self.selectedServiceTier = selectedServiceTier
        self.surfaceMode = surfaceMode
        self.onSelectModel = onSelectModel
        self.onSelectDefaultModel = onSelectDefaultModel
        self.onServiceTierChange = onServiceTierChange
        self.onRefresh = onRefresh
    }

    private var surfacePolicy: ModelReasoningGridSurfacePolicy {
        ModelReasoningGridPresentationChrome.resolvePolicy(
            surfaceMode: surfaceMode,
            interfaceStyle: interfaceStyle,
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let increasedContrast = colorSchemeContrast == .increased
        let policy = surfacePolicy
        let palette = ModelReasoningGridPalette.resolve(
            tokens: tokens,
            colorScheme: colorScheme,
            policy: policy,
            reduceTransparency: reduceTransparency,
            increasedContrast: increasedContrast
        )
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: ModelReasoningGridMetrics.sectionSpacing) {
                if dynamicTypeSize.isAccessibilitySize {
                    pickerHeader(isInGridCorner: false, palette: palette)

                    ModelReasoningAccessiblePicker(
                        layout: layout,
                        selection: selection,
                        palette: palette,
                        onSelectModel: onSelectModel
                    )
                } else {
                    ModelReasoningStandardGrid(
                        layout: layout,
                        selection: selection,
                        palette: palette,
                        onSelect: { option, effort in
                            onSelectModel(option, effort)
                        },
                        cornerContent: pickerHeader(isInGridCorner: true, palette: palette)
                    )
                }
            }
            .padding(ModelReasoningGridMetrics.contentPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(
            minWidth: 320,
            idealWidth: 400,
            maxWidth: horizontalSizeClass == .compact ? .infinity : 420
        )
        // 标准字号用实际模型行数决定内容高度，避免两行 Claude 仍占用三行 Codex 的空间。
        // 辅助功能字号不锁定高度，由外层 presentation 在可用空间内增长并保留滚动。
        .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : layout.standardContentHeight)
        .background {
            switch policy.backgroundOwner {
            case .standaloneContent:
                palette.panelBackground
            case .sheetPresentationBackground:
                Color.clear
            case .popoverContentSurface:
                ModelReasoningGridPresentationBackground(
                    policy: policy,
                    tokens: tokens,
                    colorScheme: colorScheme,
                    reduceTransparency: reduceTransparency,
                    increasedContrast: increasedContrast,
                    usesPopoverSurfaceChrome: true
                )
                .ignoresSafeArea()
            }
        }
        .accessibilityIdentifier("composer.modelPicker")
    }

    private var visibleOptions: [CodexAppServerModelOption] {
        options.filter { !$0.hidden }
    }

    private func pickerHeader(
        isInGridCorner: Bool,
        palette: ModelReasoningGridPalette
    ) -> some View {
        ModelReasoningPickerHeader(
            options: visibleOptions,
            layout: layout,
            selection: selection,
            selectedModelID: selectedModelID,
            isRefreshing: isRefreshing,
            selectedServiceTier: selectedServiceTier,
            isInGridCorner: isInGridCorner,
            palette: palette,
            onSelectModel: onSelectModel,
            onSelectDefaultModel: onSelectDefaultModel,
            onServiceTierChange: onServiceTierChange,
            onRefresh: onRefresh
        )
    }
}

private struct ModelReasoningPickerHeader: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let options: [CodexAppServerModelOption]
    let layout: ModelReasoningGridLayout
    let selection: ModelReasoningGridSelection
    let selectedModelID: String?
    let isRefreshing: Bool
    let selectedServiceTier: String?
    let isInGridCorner: Bool
    let palette: ModelReasoningGridPalette
    let onSelectModel: (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void
    let onSelectDefaultModel: (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void
    let onServiceTierChange: (String?) -> Void
    let onRefresh: () -> Void

    var body: some View {
        Group {
            if isInGridCorner {
                // 标准网格把低频控制收进横纵轴交汇处，减少独立工具条造成的留白。
                HStack(spacing: 4) {
                    allModelsMenu(isCompact: true)
                    if showsServiceTierControl {
                        serviceTierMenu()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                HStack(spacing: 8) {
                    allModelsMenu(isCompact: false)
                    if showsServiceTierControl {
                        Spacer(minLength: 8)
                        serviceTierMenu()
                    }
                }
            }
        }
        .frame(minHeight: ModelReasoningGridMetrics.headerHeight)
    }

    private func allModelsMenu(isCompact: Bool) -> some View {
        Menu {
            if let defaultOption {
                modelMenu(option: defaultOption, preservesServerDefault: true)
            }
            ForEach(options) { option in
                modelMenu(option: option, preservesServerDefault: false)
            }
            Divider()
            Button(action: onRefresh) {
                Label(
                    isRefreshing ? L10n.text("ui.refreshing") : L10n.text("ui.refresh_model_list"),
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(isRefreshing)
        } label: {
            Group {
                if isCompact {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 3) {
                            Text(L10n.text("ui.all_models"))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(themeStore.uiFont(size: 8, weight: .bold))
                        }
                        Image(systemName: "square.grid.2x2")
                    }
                } else {
                    HStack(spacing: 4) {
                        Text(L10n.text("ui.all_models"))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(themeStore.uiFont(size: 9, weight: .bold))
                    }
                }
            }
            .lineLimit(1)
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(palette.accentForeground)
            .padding(.horizontal, isCompact ? 0 : 10)
            .frame(width: isCompact ? (showsServiceTierControl ? 64 : 96) : nil)
            .frame(minHeight: 44)
            .background(palette.controlFill, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(palette.controlBorder, lineWidth: palette.controlBorderWidth)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.text("ui.all_models"))
    }

    private var activeOption: CodexAppServerModelOption? {
        // All Models 可以选中网格前三项之外的模型；速度能力必须从完整目录读取。
        ModelReasoningGridCatalog.selectedOption(
            modelID: selection.modelID,
            options: options
        )
    }

    private var serviceTiers: [CodexAppServerModelServiceTier] {
        ModelReasoningGridCatalog.serviceTiers(for: activeOption, kind: layout.kind)
    }

    private var showsServiceTierControl: Bool {
        !serviceTiers.isEmpty
    }

    private func serviceTierMenu() -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let effectiveTier = ModelReasoningGridCatalog.effectiveServiceTier(
            selectedServiceTier: selectedServiceTier,
            option: activeOption,
            kind: layout.kind
        )
        let isAccelerated = ModelReasoningGridCatalog.isAcceleratedServiceTier(effectiveTier)
        return Menu {
            Button {
                selectServiceTier(nil)
            } label: {
                Label(L10n.text("ui.default_option"), systemImage: selectedServiceTier == nil ? "checkmark" : "circle")
            }
            ForEach(serviceTiers) { tier in
                Button {
                    selectServiceTier(tier.id)
                } label: {
                    Label(
                        tier.name,
                        systemImage: selectedServiceTier == tier.id
                            ? "checkmark"
                            : (ModelReasoningGridCatalog.isAcceleratedServiceTier(tier) ? "bolt" : "circle")
                    )
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isAccelerated ? tokens.accent : palette.controlFill)

                Image(systemName: isAccelerated ? "bolt.fill" : "bolt")
                    .font(themeStore.uiFont(size: 14, weight: .semibold))
                    .foregroundStyle(
                        isAccelerated
                            ? tokens.primaryActionForeground
                            : palette.accentForeground
                    )
            }
            .frame(
                width: ModelReasoningGridMetrics.fastModeVisualDiameter,
                height: ModelReasoningGridMetrics.fastModeVisualDiameter
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        isAccelerated ? tokens.accent.opacity(0.88) : palette.controlBorder,
                        lineWidth: palette.controlBorderWidth
                    )
            }
            // 可见控制面收敛为 36pt 圆形，但外层仍保留完整 44pt 触控区域。
            .frame(
                width: ModelReasoningGridMetrics.fastModeHitTarget,
                height: ModelReasoningGridMetrics.fastModeHitTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.text("ui.service_tier"))
        .accessibilityValue(effectiveTier?.name ?? L10n.text("ui.default_option"))
    }

    @ViewBuilder
    private func modelMenu(
        option: CodexAppServerModelOption,
        preservesServerDefault: Bool
    ) -> some View {
        let efforts = ModelReasoningGridCatalog.visibleEfforts(for: option, layout: layout)
        if efforts.isEmpty {
            Button {
                select(option: option, effort: nil, preservesServerDefault: preservesServerDefault)
            } label: {
                Label(
                    preservesServerDefault ? L10n.text("ui.default_model") : option.menuTitle,
                    systemImage: isSelected(option: option, effort: nil, preservesServerDefault: preservesServerDefault)
                        ? "checkmark"
                        : "cpu"
                )
            }
        } else {
            Menu {
                ForEach(efforts) { effort in
                    Button {
                        select(option: option, effort: effort, preservesServerDefault: preservesServerDefault)
                    } label: {
                        Label(
                            ModelReasoningGridCatalog.effortTitle(effort, kind: layout.kind),
                            systemImage: isSelected(
                                option: option,
                                effort: effort,
                                preservesServerDefault: preservesServerDefault
                            ) ? "checkmark" : "brain.head.profile"
                        )
                    }
                }
            } label: {
                Label(
                    preservesServerDefault ? L10n.text("ui.default_model") : option.menuTitle,
                    systemImage: preservesServerDefault && selectedModelID == nil ? "checkmark" : "cpu"
                )
            }
        }
    }

    private var defaultOption: CodexAppServerModelOption? {
        options.first(where: \.isDefault) ?? options.first
    }

    private func selectServiceTier(_ tier: String?) {
        guard tier != selectedServiceTier else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        onServiceTierChange(tier)
    }

    private func select(
        option: CodexAppServerModelOption,
        effort: CodexAppServerReasoningEffort?,
        preservesServerDefault: Bool
    ) {
        if preservesServerDefault {
            onSelectDefaultModel(option, effort)
        } else {
            onSelectModel(option, effort)
        }
    }

    private func isSelected(
        option: CodexAppServerModelOption,
        effort: CodexAppServerReasoningEffort?,
        preservesServerDefault: Bool
    ) -> Bool {
        let modelMatches = preservesServerDefault
            ? selectedModelID == nil
            : selectedModelID?.caseInsensitiveCompare(option.model) == .orderedSame
        if effort == nil {
            return modelMatches && selection.modelID.caseInsensitiveCompare(option.model) == .orderedSame
        }
        return modelMatches && selection.effort == effort
    }
}

private struct ModelReasoningStandardGrid<CornerContent: View>: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let layout: ModelReasoningGridLayout
    let selection: ModelReasoningGridSelection
    let palette: ModelReasoningGridPalette
    let onSelect: (CodexAppServerModelOption, CodexAppServerReasoningEffort) -> Void
    let cornerContent: CornerContent

    @State private var dragPoint: CGPoint?
    @State private var previewSelection: ModelReasoningGridSelection?
    @State private var lastHapticSelection: ModelReasoningGridSelection?
    @State private var isDragging = false
    @State private var gestureRevision = 0

    private let dragCancellationMargin: CGFloat = 12

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            effortHeaders(tokens: tokens)
            HStack(spacing: ModelReasoningGridMetrics.gridSpacing) {
                modelLabels(tokens: tokens)
                grid(tokens: tokens)
            }
        }
        .onChange(of: selection) { _, _ in
            guard dragPoint == nil else { return }
            previewSelection = nil
        }
    }

    private func effortHeaders(tokens: ThemeTokens) -> some View {
        HStack(spacing: ModelReasoningGridMetrics.gridSpacing) {
            cornerContent
                .frame(
                    width: ModelReasoningGridMetrics.modelLabelWidth,
                    height: ModelReasoningGridMetrics.effortHeaderHeight
                )
            HStack(spacing: 0) {
                ForEach(Array(layout.efforts.indices), id: \.self) { column in
                    let effort = layout.efforts[column]
                    let selectedColumnEffort = layout.model(matching: activeSelection.modelID)
                        .flatMap { layout.effort(for: $0, column: column) }
                        ?? effort
                    Text(ModelReasoningGridCatalog.effortTitle(effort, kind: layout.kind))
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(
                            activeSelection.effort == selectedColumnEffort
                                ? palette.accentForeground
                                : palette.primaryForeground
                        )
                        .lineLimit(effort == .xhigh ? 2 : 1)
                        .minimumScaleFactor(0.8)
                        .allowsTightening(true)
                        .multilineTextAlignment(.center)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: ModelReasoningGridMetrics.effortHeaderHeight
                        )
                }
            }
        }
    }

    private func modelLabels(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            ForEach(layout.models) { option in
                Text(ModelReasoningGridCatalog.shortTitle(for: option, kind: layout.kind))
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(
                        activeSelection.modelID == option.model
                            ? palette.accentForeground
                            : palette.rowLabelForeground
                    )
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(width: ModelReasoningGridMetrics.modelLabelWidth, alignment: .trailing)
                    .frame(minHeight: ModelReasoningGridMetrics.modelRowHeight)
            }
        }
    }

    private func grid(tokens: ThemeTokens) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cellSize = CGSize(
                width: size.width / CGFloat(max(layout.effortColumnCount, 1)),
                height: size.height / CGFloat(max(layout.modelRowCount, 1))
            )

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette.gridFill)

                gridLines(size: size, tokens: tokens)

                // VoiceOver 与视觉顺序一致：先按模型从上到下，同一模型内按强度从左到右。
                VStack(spacing: 0) {
                    ForEach(layout.models) { option in
                        HStack(spacing: 0) {
                            ForEach(Array(layout.efforts.indices), id: \.self) { column in
                                let effort = layout.effort(for: option, column: column)
                                let inlineEffortLabel = layout.inlineEffortLabel(for: option, column: column)
                                gridCell(
                                    option: option,
                                    effort: effort,
                                    inlineEffortLabel: inlineEffortLabel,
                                    tokens: tokens
                                )
                                    .frame(width: cellSize.width, height: cellSize.height)
                            }
                        }
                    }
                }

                let settledLens = layout.selectionLensGeometry(for: activeSelection, size: size)
                if let lensPosition = dragPoint ?? settledLens?.center {
                    let avoidsInlineLabel = !isDragging && (settledLens?.avoidsInlineLabel == true)
                    selectionLens(tokens: tokens, avoidsInlineLabel: avoidsInlineLabel)
                        .position(lensPosition)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.gridBorder, lineWidth: palette.gridBorderWidth)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .simultaneousGesture(dragGesture(size: size))
        }
        .frame(height: CGFloat(layout.modelRowCount) * ModelReasoningGridMetrics.modelRowHeight)
    }

    private func gridCell(
        option: CodexAppServerModelOption,
        effort: CodexAppServerReasoningEffort?,
        inlineEffortLabel: String?,
        tokens: ThemeTokens
    ) -> some View {
        let isAvailable = effort.map {
            ModelReasoningGridCatalog.isStandardEffortAvailable(
                $0,
                option: option,
                layout: layout
            )
        } ?? false
        let candidate = ModelReasoningGridSelection(modelID: option.model, effort: effort)
        let selected = isAvailable && activeSelection == candidate

        return Button {
            commit(candidate, option: option)
        } label: {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(palette.selectedCellFill)
                        .padding(4)
                }
                if let inlineEffortLabel {
                    Text(inlineEffortLabel)
                        .font(themeStore.uiFont(.caption2, weight: selected ? .bold : .semibold))
                        .foregroundStyle(
                            selected
                                ? palette.accentForeground
                                : (isAvailable
                                    ? palette.inlineEffortForeground
                                    : palette.disabledInlineEffortForeground)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: selected ? .bottom : .center
                        )
                        .padding(
                            .bottom,
                            selected ? ModelReasoningGridMetrics.inlineLabelSelectedBottomPadding : 0
                        )
                } else {
                    Circle()
                        .fill(
                            selected
                                ? palette.selectedDotForeground
                                : (isAvailable ? palette.dotForeground : palette.disabledDotForeground)
                        )
                        .frame(width: selected ? 8 : 6, height: selected ? 8 : 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .disabled(!isAvailable)
        .hoverEffect(.highlight)
        .accessibilityLabel(
            "\(ModelReasoningGridCatalog.shortTitle(for: option, kind: layout.kind)), "
                + (effort.map(ModelReasoningGridCatalog.effortTitle) ?? "")
        )
        .accessibilityValue(
            isAvailable
                ? (selected ? L10n.text("ui.selected") : L10n.text("ui.not_selected"))
                : L10n.text("ui.not_available")
        )
        .accessibilityHint(isAvailable ? L10n.text("ui.select_the_model_to_use_in_the_next") : "")
    }

    private func gridLines(size: CGSize, tokens: ThemeTokens) -> some View {
        Path { path in
            if layout.effortColumnCount > 1 {
                for column in 1..<layout.effortColumnCount {
                    let x = size.width * CGFloat(column) / CGFloat(layout.effortColumnCount)
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
            }
            if layout.modelRowCount > 1 {
                for row in 1..<layout.modelRowCount {
                    let y = size.height * CGFloat(row) / CGFloat(layout.modelRowCount)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
        }
        .stroke(palette.gridLine, lineWidth: 0.75)
    }

    private func selectionLens(tokens: ThemeTokens, avoidsInlineLabel: Bool) -> some View {
        let lensDiameter = avoidsInlineLabel
            ? ModelReasoningGridMetrics.inlineLabelSelectionLensDiameter
            : ModelReasoningGridMetrics.selectionLensDiameter
        let haloDiameter = avoidsInlineLabel
            ? ModelReasoningGridMetrics.inlineLabelSelectionLensHaloDiameter
            : ModelReasoningGridMetrics.selectionLensHaloDiameter
        let highlightSize: CGFloat = avoidsInlineLabel ? 2.5 : 4
        let highlightOffset: CGFloat = avoidsInlineLabel ? -2.5 : -5
        let haloBlur: CGFloat = avoidsInlineLabel ? 2 : 4

        return ZStack {
            Circle()
                .fill(tokens.accent.opacity(0.13))
                .frame(width: haloDiameter, height: haloDiameter)
                .blur(radius: haloBlur)
            Circle()
                .fill(tokens.accent.gradient)
                .frame(width: lensDiameter, height: lensDiameter)
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.58), lineWidth: 1)
                }
                .shadow(color: tokens.accent.opacity(0.28), radius: avoidsInlineLabel ? 3 : 5, y: avoidsInlineLabel ? 1 : 2)
            Circle()
                .fill(Color.white.opacity(0.48))
                .frame(width: highlightSize, height: highlightSize)
                .offset(x: highlightOffset, y: highlightOffset)
        }
        .scaleEffect(!isDragging || reduceMotion ? 1 : 1.06)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 1),
            value: isDragging
        )
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    gestureRevision += 1
                }
                dragPoint = rubberBanded(value.location, size: size)
                guard let candidate = candidate(at: value.location, size: size) else {
                    previewSelection = nil
                    lastHapticSelection = nil
                    return
                }
                guard candidate != previewSelection else { return }
                previewSelection = candidate
                if candidate != lastHapticSelection {
                    UISelectionFeedbackGenerator().selectionChanged()
                    lastHapticSelection = candidate
                }
            }
            .onEnded { value in
                isDragging = false
                guard let candidate = candidate(at: value.location, size: size),
                      let option = layout.model(matching: candidate.modelID)
                else {
                    withAnimation(dragSettleAnimation) {
                        dragPoint = nil
                        previewSelection = nil
                    }
                    lastHapticSelection = nil
                    return
                }
                withAnimation(dragSettleAnimation) {
                    previewSelection = candidate
                    dragPoint = center(for: candidate, size: size)
                }
                guard let effort = candidate.effort else { return }
                onSelect(option, effort)
                let completedRevision = gestureRevision
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.13 : 0.32)) {
                    guard completedRevision == gestureRevision, !isDragging else { return }
                    dragPoint = nil
                    previewSelection = nil
                    lastHapticSelection = nil
                }
            }
    }

    private var activeSelection: ModelReasoningGridSelection {
        previewSelection ?? selection
    }

    private var tapSelectionAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.1)
            : .spring(response: 0.24, dampingFraction: 1)
    }

    private var dragSettleAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.3, dampingFraction: 1)
    }

    private func candidate(
        at point: CGPoint,
        size: CGSize
    ) -> ModelReasoningGridSelection? {
        layout.dragCandidate(
            at: point,
            size: size,
            cancellationMargin: dragCancellationMargin
        )
    }

    private func center(
        for selection: ModelReasoningGridSelection,
        size: CGSize
    ) -> CGPoint? {
        layout.selectionLensGeometry(for: selection, size: size)?.center
    }

    private func commit(
        _ candidate: ModelReasoningGridSelection,
        option: CodexAppServerModelOption
    ) {
        gestureRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(tapSelectionAnimation) {
            previewSelection = candidate
            dragPoint = nil
        }
        guard let effort = candidate.effort else { return }
        onSelect(option, effort)
        let completedRevision = gestureRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.11 : 0.24)) {
            guard completedRevision == gestureRevision, !isDragging else { return }
            previewSelection = nil
            lastHapticSelection = nil
        }
    }

    private func rubberBanded(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: rubberBanded(point.x, lower: 0, upper: size.width),
            y: rubberBanded(point.y, lower: 0, upper: size.height)
        )
    }

    private func rubberBanded(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        if value < lower {
            return lower - rubberDistance(lower - value)
        }
        if value > upper {
            return upper + rubberDistance(value - upper)
        }
        return value
    }

    private func rubberDistance(_ distance: CGFloat) -> CGFloat {
        18 * (1 - 1 / (distance / 70 + 1))
    }
}

private struct ModelReasoningAccessiblePicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let layout: ModelReasoningGridLayout
    let selection: ModelReasoningGridSelection
    let palette: ModelReasoningGridPalette
    let onSelectModel: (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void

    var body: some View {
        let rowShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(layout.models) { option in
                    Button {
                        onSelectModel(
                            option,
                            ModelReasoningGridCatalog.normalizedVisibleEffort(
                                option: option,
                                current: selection.effort,
                                layout: layout
                            )
                        )
                    } label: {
                        Label(
                            ModelReasoningGridCatalog.shortTitle(for: option, kind: layout.kind),
                            systemImage: option.model == activeOption?.model ? "checkmark" : "cpu"
                        )
                    }
                }
            } label: {
                HStack {
                    Text(activeOption.map {
                        ModelReasoningGridCatalog.shortTitle(for: $0, kind: layout.kind)
                    } ?? L10n.text("ui.model"))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(themeStore.uiFont(.body, weight: .semibold))
                .foregroundStyle(palette.primaryForeground)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(palette.accessibleMenuFill, in: rowShape)
                .overlay {
                    if let border = palette.accessibleRowBorder {
                        rowShape.strokeBorder(border, lineWidth: palette.accessibleRowBorderWidth)
                    }
                }
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))

            let efforts = ModelReasoningGridCatalog.visibleEfforts(for: activeOption, layout: layout)
            ForEach(efforts) { effort in
                let isAvailable = activeOption.map {
                    ModelReasoningGridCatalog.isStandardEffortAvailable(effort, option: $0, layout: layout)
                } ?? false
                Button {
                    guard let activeOption else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    onSelectModel(activeOption, effort)
                } label: {
                    HStack {
                        Text(ModelReasoningGridCatalog.effortTitle(effort, kind: layout.kind))
                        Spacer()
                        if isAvailable && selection.effort == effort {
                            Image(systemName: "checkmark")
                                .foregroundStyle(palette.accentForeground)
                        }
                    }
                    .font(themeStore.uiFont(.body, weight: .medium))
                    .foregroundStyle(isAvailable ? palette.primaryForeground : palette.disabledInlineEffortForeground)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(palette.accessibleEffortFill, in: rowShape)
                    .overlay {
                        if let border = palette.accessibleRowBorder {
                            rowShape.strokeBorder(border, lineWidth: palette.accessibleRowBorderWidth)
                        }
                    }
                }
                .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                .disabled(!isAvailable)
                .accessibilityLabel(
                    "\(activeOption.map { ModelReasoningGridCatalog.shortTitle(for: $0, kind: layout.kind) } ?? ""), "
                        + ModelReasoningGridCatalog.effortTitle(effort, kind: layout.kind)
                )
                .accessibilityValue(
                    isAvailable
                        ? (selection.effort == effort ? L10n.text("ui.selected") : L10n.text("ui.not_selected"))
                        : L10n.text("ui.not_available")
                )
            }
        }
    }

    private var activeOption: CodexAppServerModelOption? {
        layout.model(matching: selection.modelID) ?? layout.models.first
    }
}
