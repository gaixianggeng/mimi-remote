import SwiftUI
import UIKit

struct ModelReasoningGridSelection: Equatable {
    let modelID: String
    let effort: CodexAppServerReasoningEffort?
}

enum ModelReasoningGridKind: Equatable {
    case codex
    case claude
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

    static func standardContentHeight(modelRowCount: Int) -> CGFloat {
        let visibleRowCount = max(modelRowCount, 0)
        return contentPadding * 2
            + effortHeaderHeight
            + CGFloat(visibleRowCount) * modelRowHeight
    }
}

struct ModelReasoningGridLayout: Equatable {
    let kind: ModelReasoningGridKind
    let models: [CodexAppServerModelOption]
    let efforts: [CodexAppServerReasoningEffort]
    let showsFastMode: Bool

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
        let fallbackOptions = normalizedRuntime == "claude"
            ? CodexAppServerModelOption.builtInClaudeFallback
            : CodexAppServerModelOption.builtInFallback
        let candidates = runtimeOptions.isEmpty ? fallbackOptions : runtimeOptions

        if normalizedRuntime == "claude" {
            // Bridge 可能返回稳定 alias `opus`，也可能返回带版本的 canonical id。
            // 以产品名 Opus 5 匹配，避免服务端把其他模型标成默认后改变新会话体验。
            if let opus = candidates.first(where: { option in
                let model = option.model.lowercased()
                let title = option.title.lowercased()
                return model == "opus" ||
                    model.contains("opus-5") ||
                    title.contains("opus 5")
            }) {
                return opus
            }
        } else if let sol = candidates.first(where: {
            $0.model.caseInsensitiveCompare("gpt-5.6-sol") == .orderedSame
        }) {
            return sol
        }

        // 账号尚未获得目标模型时不能发送目录外 ID；退回该 runtime 的可用默认项。
        return candidates.first(where: \.isDefault) ?? candidates.first
    }

    static func preferredDefaultEffort(
        runtimeProvider: String?,
        option: CodexAppServerModelOption?,
        layout: ModelReasoningGridLayout
    ) -> CodexAppServerReasoningEffort? {
        let normalizedRuntime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        let preferred: CodexAppServerReasoningEffort = normalizedRuntime == "claude" ? .high : .xhigh
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
        let runtime = runtimeProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let kind: ModelReasoningGridKind = runtime == "claude" ? .claude : .codex
        let fallbackOptions = kind == .claude
            ? CodexAppServerModelOption.builtInClaudeFallback
            : CodexAppServerModelOption.builtInFallback
        let source = visible.isEmpty ? fallbackOptions : visible

        // 模型顺序完全沿用 model/list；能力策略只负责决定横向四列，不重排模型。
        return ModelReasoningGridLayout(
            kind: kind,
            models: Array(source.prefix(maximumModelCount)),
            efforts: standardEfforts(for: kind),
            showsFastMode: kind == .codex
        )
    }

    static func standardEfforts(
        for kind: ModelReasoningGridKind
    ) -> [CodexAppServerReasoningEffort] {
        kind == .claude ? claudeStandardEfforts : codexStandardEfforts
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
        return "\(shortTitle(for: option, kind: layout.kind)) · \(effortTitle(effort))"
    }

    static func compactTriggerTitle(
        for modelID: String,
        layout: ModelReasoningGridLayout
    ) -> String? {
        guard let option = layout.model(matching: modelID) else { return nil }
        let title = shortTitle(for: option, kind: layout.kind)
        guard layout.kind == .claude, title.hasPrefix("Claude ") else {
            return title
        }
        // 底部工具层已经由当前会话 runtime 提供上下文，省略重复的 Provider 前缀，
        // 让常见 Claude 模型在 iPhone 窄宽度下仍能完整显示为「Opus 5」。
        return String(title.dropFirst("Claude ".count))
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

    static func supports(
        _ effort: CodexAppServerReasoningEffort,
        option: CodexAppServerModelOption,
        kind: ModelReasoningGridKind? = nil
    ) -> Bool {
        let isClaude = kind == .claude || option.runtimeProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "claude"
        if isClaude {
            // Claude 的空数组明确表示该模型不支持原生 reasoning effort。
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
            return CodexAppServerReasoningEffort.allCases
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

        if CodexAppServerSessionRuntime.normalizedRuntimeProvider(turnOptions.runtimeProvider) == "claude" {
            turnOptions.serviceTier = nil
        }
    }

    static func serviceTierForFastMode(_ isEnabled: Bool) -> String? {
        isEnabled ? "priority" : nil
    }

    static func normalizedStandardServiceTier(
        _ serviceTier: String?,
        runtimeProvider: String?
    ) -> String? {
        guard CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider) != "claude",
              serviceTier == "priority"
        else {
            return nil
        }
        return "priority"
    }
}

struct ModelReasoningGridPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let options: [CodexAppServerModelOption]
    let layout: ModelReasoningGridLayout
    let selection: ModelReasoningGridSelection
    let selectedModelID: String?
    let isRefreshing: Bool
    let isFastMode: Bool
    let onSelectModel: (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void
    let onSelectDefaultModel: (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void
    let onFastModeChange: (Bool) -> Void
    let onRefresh: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: ModelReasoningGridMetrics.sectionSpacing) {
                if dynamicTypeSize.isAccessibilitySize {
                    pickerHeader(isInGridCorner: false)

                    ModelReasoningAccessiblePicker(
                        layout: layout,
                        selection: selection,
                        onSelectModel: onSelectModel
                    )
                } else {
                    ModelReasoningStandardGrid(
                        layout: layout,
                        selection: selection,
                        onSelect: { option, effort in
                            onSelectModel(option, effort)
                        },
                        cornerContent: pickerHeader(isInGridCorner: true)
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
        .background(tokens.surface)
        .accessibilityIdentifier("composer.modelPicker")
    }

    private var visibleOptions: [CodexAppServerModelOption] {
        options.filter { !$0.hidden }
    }

    private func pickerHeader(isInGridCorner: Bool) -> some View {
        ModelReasoningPickerHeader(
            options: visibleOptions,
            layout: layout,
            selection: selection,
            selectedModelID: selectedModelID,
            isRefreshing: isRefreshing,
            isFastMode: isFastMode,
            isInGridCorner: isInGridCorner,
            onSelectModel: onSelectModel,
            onSelectDefaultModel: onSelectDefaultModel,
            onFastModeChange: onFastModeChange,
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
    let isFastMode: Bool
    let isInGridCorner: Bool
    let onSelectModel: (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void
    let onSelectDefaultModel: (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void
    let onFastModeChange: (Bool) -> Void
    let onRefresh: () -> Void

    var body: some View {
        Group {
            if isInGridCorner {
                // 标准网格把低频控制收进横纵轴交汇处，减少独立工具条造成的留白。
                HStack(spacing: 4) {
                    allModelsMenu(isCompact: true)
                    if layout.showsFastMode {
                        fastModeToggle()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                HStack(spacing: 8) {
                    allModelsMenu(isCompact: false)
                    if layout.showsFastMode {
                        Spacer(minLength: 8)
                        fastModeToggle()
                    }
                }
            }
        }
        .frame(minHeight: ModelReasoningGridMetrics.headerHeight)
    }

    private func allModelsMenu(isCompact: Bool) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return Menu {
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
            .foregroundStyle(tokens.accent)
            .padding(.horizontal, isCompact ? 0 : 10)
            .frame(width: isCompact ? (layout.showsFastMode ? 64 : 96) : nil)
            .frame(minHeight: 44)
            .background(tokens.elevatedSurface.opacity(0.72), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tokens.border.opacity(0.58), lineWidth: 0.75)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.text("ui.all_models"))
    }

    private func fastModeToggle() -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let fastImage = isFastMode ? "bolt.fill" : "bolt"
        return Toggle(isOn: fastModeBinding) {
            ZStack {
                Circle()
                    .fill(isFastMode ? tokens.accent : tokens.elevatedSurface.opacity(0.72))

                Image(systemName: fastImage)
                    .font(themeStore.uiFont(size: 14, weight: .semibold))
                    .foregroundStyle(isFastMode ? Color.white : tokens.accent)
            }
            .frame(
                width: ModelReasoningGridMetrics.fastModeVisualDiameter,
                height: ModelReasoningGridMetrics.fastModeVisualDiameter
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        isFastMode ? tokens.accent.opacity(0.88) : tokens.border.opacity(0.58),
                        lineWidth: 0.75
                    )
            }
            // 可见控制面收敛为 36pt 圆形，但外层仍保留完整 44pt 触控区域。
            .frame(
                width: ModelReasoningGridMetrics.fastModeHitTarget,
                height: ModelReasoningGridMetrics.fastModeHitTarget
            )
            .contentShape(Rectangle())
        }
        .toggleStyle(.button)
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.text("ui.quick_mode"))
        .accessibilityValue(isFastMode ? L10n.text("ui.already_turned_on") : L10n.text("ui.closed"))
        .accessibilityHint(L10n.text("ui.after_turning_it_on_the_priority_service_speed"))
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
                            ModelReasoningGridCatalog.effortTitle(effort),
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

    private var fastModeBinding: Binding<Bool> {
        Binding(
            get: { isFastMode },
            set: { newValue in
                guard newValue != isFastMode else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                onFastModeChange(newValue)
            }
        )
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let layout: ModelReasoningGridLayout
    let selection: ModelReasoningGridSelection
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
                    Text(ModelReasoningGridCatalog.effortTitle(effort))
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(
                            activeSelection.effort == selectedColumnEffort
                                ? tokens.accent
                                : tokens.primaryText
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
                    .foregroundStyle(activeSelection.modelID == option.model ? tokens.accent : tokens.secondaryText)
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
                    .fill(tokens.elevatedSurface.opacity(reduceTransparency ? 1 : 0.56))

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

                if let lensPosition = dragPoint ?? center(for: activeSelection, size: size) {
                    selectionLens(tokens: tokens)
                        .position(lensPosition)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tokens.border.opacity(0.72), lineWidth: 0.75)
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
                        .fill(tokens.accent.opacity(0.055))
                        .padding(4)
                }
                if let inlineEffortLabel {
                    Text(inlineEffortLabel)
                        .font(themeStore.uiFont(.caption2, weight: selected ? .bold : .semibold))
                        .foregroundStyle(
                            selected
                                ? tokens.accent
                                : tokens.tertiaryText.opacity(isAvailable ? 0.72 : 0.24)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    Circle()
                        .fill(
                            selected
                                ? tokens.accent.opacity(0.3)
                                : tokens.tertiaryText.opacity(isAvailable ? 0.34 : 0.12)
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
        .stroke(tokens.border.opacity(0.46), lineWidth: 0.75)
    }

    private func selectionLens(tokens: ThemeTokens) -> some View {
        ZStack {
            Circle()
                .fill(tokens.accent.opacity(0.13))
                .frame(width: 38, height: 38)
                .blur(radius: 4)
            Circle()
                .fill(tokens.accent.gradient)
                .frame(width: 26, height: 26)
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.58), lineWidth: 1)
                }
                .shadow(color: tokens.accent.opacity(0.28), radius: 5, y: 2)
            Circle()
                .fill(Color.white.opacity(0.48))
                .frame(width: 4, height: 4)
                .offset(x: -5, y: -5)
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
        guard !layout.models.isEmpty,
              !layout.efforts.isEmpty,
              size.width > 0,
              size.height > 0
        else {
            return nil
        }
        guard point.x >= -dragCancellationMargin,
              point.x <= size.width + dragCancellationMargin,
              point.y >= -dragCancellationMargin,
              point.y <= size.height + dragCancellationMargin
        else {
            return nil
        }

        let x = min(max(point.x, 0), size.width - 0.001)
        let y = min(max(point.y, 0), size.height - 0.001)
        let column = min(
            layout.effortColumnCount - 1,
            max(0, Int(x / (size.width / CGFloat(layout.effortColumnCount))))
        )
        let row = min(
            layout.modelRowCount - 1,
            max(0, Int(y / (size.height / CGFloat(layout.modelRowCount))))
        )
        guard let candidate = layout.selection(modelRow: row, effortColumn: column),
              let effort = candidate.effort
        else {
            return nil
        }
        let option = layout.models[row]
        guard ModelReasoningGridCatalog.isStandardEffortAvailable(
            effort,
            option: option,
            layout: layout
        ) else {
            return nil
        }
        return candidate
    }

    private func center(
        for selection: ModelReasoningGridSelection,
        size: CGSize
    ) -> CGPoint? {
        guard let effort = selection.effort,
              let row = layout.models.firstIndex(where: { $0.model == selection.modelID }),
              let column = layout.effortColumn(for: effort, option: layout.models[row]),
              ModelReasoningGridCatalog.isStandardEffortAvailable(
                  effort,
                  option: layout.models[row],
                  layout: layout
              )
        else {
            return nil
        }
        return CGPoint(
            x: (CGFloat(column) + 0.5) * size.width / CGFloat(layout.effortColumnCount),
            y: (CGFloat(row) + 0.5) * size.height / CGFloat(layout.modelRowCount)
        )
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let layout: ModelReasoningGridLayout
    let selection: ModelReasoningGridSelection
    let onSelectModel: (CodexAppServerModelOption, CodexAppServerReasoningEffort?) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
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
                .foregroundStyle(tokens.primaryText)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        Text(ModelReasoningGridCatalog.effortTitle(effort))
                        Spacer()
                        if isAvailable && selection.effort == effort {
                            Image(systemName: "checkmark")
                                .foregroundStyle(tokens.accent)
                        }
                    }
                    .font(themeStore.uiFont(.body, weight: .medium))
                    .foregroundStyle(isAvailable ? tokens.primaryText : tokens.tertiaryText)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(tokens.elevatedSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                .disabled(!isAvailable)
                .accessibilityLabel(
                    "\(activeOption.map { ModelReasoningGridCatalog.shortTitle(for: $0, kind: layout.kind) } ?? ""), "
                        + ModelReasoningGridCatalog.effortTitle(effort)
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
