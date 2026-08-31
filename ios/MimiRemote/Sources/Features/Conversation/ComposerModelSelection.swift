import Foundation
import SwiftUI

// 模型目录过滤、默认值选择和会话 runtime 锁定集中在这里，避免 ComposerView
// 同时承担视图布局与模型策略。成员保持 module-internal，供 ComposerView 跨文件扩展协作。
extension ComposerView {
    var sharedThreadModelControl: some View {
        Menu {
            Section {
                Button(action: {}) {
                    Label(L10n.text("ui.model"), systemImage: "cpu")
                }
                .disabled(true)

                Text(ComposerTurnSettingsPolicy.sharedThreadSettingsMenuNotice)
            }
        } label: {
            composerToolbarControlLabel(
                title: nil,
                systemImage: "cpu",
                trailingSystemImage: "lock.fill",
                accessibilityLabel: L10n.text("ui.model")
            )
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.text("ui.model"))
        .accessibilityValue(ComposerTurnSettingsPolicy.sharedThreadSettingsMenuNotice)
        .accessibilityIdentifier("composer.model.sharedThreadManaged")
        .help(ComposerTurnSettingsPolicy.sharedThreadSettingsMenuNotice)
    }

    @ViewBuilder
    var modelPickerControl: some View {
        modelPickerControl(showsTitle: true, usesCompactTitle: false)
    }

    @ViewBuilder
    func modelPickerControl(showsTitle: Bool, usesCompactTitle: Bool = false) -> some View {
        let visibleTitle = usesCompactTitle ? compactModelPickerTitle : modelPickerTriggerTitle
        Button {
            showsModelGridPicker.toggle()
        } label: {
            composerToolbarControlLabel(
                // iPhone 用短标签外显模型与推理档位；完整名称仍通过 accessibilityValue 提供。
                title: showsTitle ? visibleTitle : nil,
                systemImage: usesCompactTitle ? nil : "cpu",
                trailingSystemImage: ConversationLayout.compactComposerShowsFastModeIndicator(
                    usesCompactMetrics: usesCompactComposerMetrics,
                    isFastModeSelected: isFastModeSelected
                ) ? "bolt.fill" : nil,
                titleMaxWidth: usesCompactTitle
                    ? ConversationLayout.compactComposerModelTitleMaxWidth(availableWidth: availableWidth)
                    : (usesCompactComposerMetrics ? 82 : 150),
                usesCondensedTitle: usesCompactTitle,
                accessibilityLabel: L10n.text("ui.switch_model_and_inference_strength")
            )
            .contentTransition(.opacity)
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.text("ui.switch_model_and_inference_strength"))
        .accessibilityValue(modelShortcutAccessibilityValue(for: modelPickerTriggerTitle))
        .accessibilityHint(L10n.text("ui.select_the_model_to_use_in_the_next"))
        .accessibilityIdentifier("composer.model")
        .popover(isPresented: $showsModelGridPicker, arrowEdge: .bottom) {
            ModelReasoningGridPicker(
                options: modelOptionsForMenu,
                layout: modelReasoningGridLayout,
                selection: selectedModelGridSelection,
                selectedModelID: composerState.turnOptions.model,
                isRefreshing: sessionStore.isRefreshingAppServerModels,
                isFastMode: isFastModeSelected,
                onSelectModel: { option, effort in
                    selectModel(option, effort: effort)
                },
                onSelectDefaultModel: { option, effort in
                    selectDefaultModel(option, effort: effort)
                },
                onFastModeChange: { isEnabled in
                    composerState.updateTurnOptions {
                        $0.serviceTier = ModelReasoningGridCatalog.serviceTierForFastMode(isEnabled)
                    }
                },
                onRefresh: {
                    Task { await sessionStore.refreshAppServerModelOptions(force: true) }
                }
            )
            .environmentObject(themeStore)
            .presentationCompactAdaptation(horizontal: .sheet, vertical: .sheet)
            // compact popover 转成 sheet 后，iOS 26 不会稳定采用 fitted 内容高度。
            // 标准字号只保留与实际模型行数一致的 detent；辅助功能字号则使用
            // large detent，并继续由 Picker 内部滚动，避免放大文字被裁切。
            .presentationDetents(modelPickerPresentationDetents)
            .presentationDragIndicator(.visible)
            .presentationBackground(themeStore.tokens(for: colorScheme).surface)
        }
    }

    var modelPickerPresentationDetents: Set<PresentationDetent> {
        if dynamicTypeSize.isAccessibilitySize {
            return [.large]
        }
        return [.height(modelReasoningGridLayout.standardContentHeight)]
    }

    var effectiveModelID: String? {
        ModelReasoningGridCatalog.effectiveModelID(
            selectedModelID: composerState.turnOptions.model,
            options: modelOptionsForMenu
        )
    }

    var modelReasoningGridLayout: ModelReasoningGridLayout {
        ModelReasoningGridCatalog.layout(
            runtimeProvider: selectedSessionRuntimeProviderForModelMenu,
            options: modelOptionsForMenu
        )
    }

    var isFastModeSelected: Bool {
        modelReasoningGridLayout.showsFastMode && composerState.turnOptions.serviceTier == "priority"
    }

    func modelShortcutAccessibilityValue(for title: String) -> String {
        isFastModeSelected ? "\(title) · \(L10n.text("ui.fast"))" : title
    }

    var selectedModelGridSelection: ModelReasoningGridSelection {
        let layout = modelReasoningGridLayout
        let selectedOption = effectiveModelID.flatMap { modelID in
            modelOptionsForMenu.first { $0.model.caseInsensitiveCompare(modelID) == .orderedSame }
        }
        let option = selectedOption
            ?? layout.model(matching: effectiveModelID)
            ?? layout.models.first(where: \.isDefault)
            ?? layout.models.first
        let effort = ModelReasoningGridCatalog.normalizedVisibleEffort(
            option: option,
            current: composerState.turnOptions.reasoningEffort,
            layout: layout
        )
        return ModelReasoningGridSelection(
            modelID: option?.model ?? "gpt-5.6-sol",
            effort: effort
        )
    }

    var modelPickerTriggerTitle: String {
        guard let selectedModel = effectiveModelID,
              let selectedEffort = developerModeEnabled
                  ? composerState.turnOptions.reasoningEffort
                  : selectedModelGridSelection.effort,
              let title = ModelReasoningGridCatalog.triggerTitle(
                  for: selectedModel,
                  effort: selectedEffort,
                  layout: modelReasoningGridLayout
              )
        else {
            return selectedModelSummaryTitle
        }
        return title
    }

    var compactModelPickerTitle: String {
        guard let selectedModel = effectiveModelID,
              let selectedEffort = developerModeEnabled
                  ? composerState.turnOptions.reasoningEffort
                  : selectedModelGridSelection.effort,
              let title = ModelReasoningGridCatalog.compactTriggerTitle(
                  for: selectedModel,
                  effort: selectedEffort,
                  layout: modelReasoningGridLayout
              )
        else {
            return selectedModelSummaryTitle
        }
        return title
    }

    func selectModel(
        _ option: CodexAppServerModelOption,
        effort: CodexAppServerReasoningEffort?
    ) {
        composerState.updateTurnOptions { options in
            ModelReasoningGridCatalog.applySelection(
                option: option,
                effort: effort,
                preservesServerDefault: false,
                fallbackRuntimeProvider: payloadRuntimeProviderForSelectedSessionLock(),
                to: &options
            )
        }
    }

    func selectDefaultModel(
        _ option: CodexAppServerModelOption,
        effort: CodexAppServerReasoningEffort?
    ) {
        composerState.updateTurnOptions { options in
            // Default Model 只借用服务端默认模型的强度菜单，协议层继续提交 model = nil。
            ModelReasoningGridCatalog.applySelection(
                option: option,
                effort: effort,
                preservesServerDefault: true,
                fallbackRuntimeProvider: payloadRuntimeProviderForSelectedSessionLock(),
                to: &options
            )
        }
    }

    var modelOptionsForMenu: [CodexAppServerModelOption] {
        let source = sessionStore.appServerModelOptions.isEmpty
            ? CodexAppServerModelOption.builtInFallback
            : sessionStore.appServerModelOptions
        let options = source.filter { !$0.hidden }
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return options
        }
        let scoped = options.filter { option in
            normalizedRuntimeProvider(option.runtimeProvider) == runtimeProvider
        }
        if scoped.isEmpty, runtimeProvider == "claude" {
            return CodexAppServerModelOption.builtInClaudeFallback
        }
        if scoped.isEmpty, runtimeProvider == "codex" {
            return CodexAppServerModelOption.builtInFallback
        }
        return scoped.isEmpty ? options : scoped
    }

    var selectedModelSummaryTitle: String {
        guard let model = composerState.turnOptions.model?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else {
            return defaultModelSummaryTitle
        }
        if let option = modelOptionsForMenu.first(where: { item in
            item.model == model
                && item.runtimeProvider == composerState.turnOptions.runtimeProvider
                && (composerState.turnOptions.modelProvider == nil
                    || item.provider == composerState.turnOptions.modelProvider)
        }) {
            return developerModeEnabled ? option.menuTitle : option.title
        }
        if developerModeEnabled,
           let provider = composerState.turnOptions.modelProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return "\(model) · \(provider)"
        }
        return model
    }

    var defaultModelSummaryTitle: String {
        guard let option = modelOptionsForMenu.first(where: \.isDefault)
            ?? modelOptionsForMenu.first
        else {
            return L10n.text("ui.default_model")
        }
        return developerModeEnabled ? option.menuTitle : option.title
    }

    var selectedSessionRuntimeProviderForModelMenu: String? {
        guard let session = sessionStore.selectedSession else {
            return nil
        }
        // 新建页已经选择了 runtime；本地草稿的 nil 是 Codex 的协议简写，不表示
        // 可以再由模型菜单切换到 Claude。
        if session.source == "local", session.runtimeProvider == nil {
            return "codex"
        }
        return normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
    }

    func clampModelSelectionToSelectedSessionRuntime() {
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return
        }
        let runtimeChanged =
            normalizedRuntimeProvider(composerState.turnOptions.runtimeProvider) != runtimeProvider
        let explicitModelID = composerState.turnOptions.model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appServerNilIfEmpty
        let unsupportedModel = !developerModeEnabled
            && explicitModelID != nil
            && modelOption(matching: explicitModelID) == nil
        let normalizedEffort: CodexAppServerReasoningEffort?
        if developerModeEnabled {
            normalizedEffort = composerState.turnOptions.reasoningEffort.flatMap { effort in
                supportsReasoningEffort(effort, modelID: effectiveModelID) ? effort : nil
            }
        } else {
            let option = modelOption(matching: effectiveModelID)
            normalizedEffort = ModelReasoningGridCatalog.normalizedVisibleEffort(
                option: option,
                current: composerState.turnOptions.reasoningEffort,
                layout: modelReasoningGridLayout
            )
        }
        let unsupportedEffort = composerState.turnOptions.reasoningEffort != normalizedEffort
        let unsupportedServiceTier = runtimeProvider == "claude"
            && composerState.turnOptions.serviceTier?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        guard runtimeChanged || unsupportedModel || unsupportedEffort || unsupportedServiceTier else {
            return
        }
        composerState.updateTurnOptions { options in
            if runtimeChanged || unsupportedModel {
                // 切换 runtime 或目录刷新淘汰旧模型时，使用设置里的对应默认值；
                // 没有自定义设置时仍回到 Codex Sol/xhigh、Claude Opus/high。
                applyPreferredDefaultModel(runtimeProvider: runtimeProvider, to: &options)
            } else if unsupportedEffort {
                options.reasoningEffort = normalizedEffort
            }
            if runtimeProvider == "claude" {
                options.serviceTier = nil
            }
        }
    }

    func applyPreferredDefaultModel(
        runtimeProvider: String,
        to options: inout CodexAppServerTurnOptions
    ) {
        // 默认模型统一从本机设置读取；没有保存配置时仍沿用原来的 Sol/xhigh、Opus/high。
        DefaultModelPreferences.applyDefault(
            for: runtimeProvider,
            allOptions: modelOptionsForMenu,
            to: &options
        )
    }

    func supportsReasoningEffort(
        _ effort: CodexAppServerReasoningEffort,
        modelID: String?
    ) -> Bool {
        let option = modelOption(matching: modelID)
        guard let option else {
            // 未知/自定义模型继续走开发者模式原有能力，不能因本地目录不认识就擅自降级。
            return true
        }
        return ModelReasoningGridCatalog.supports(
            effort,
            option: option,
            kind: modelReasoningGridLayout.kind
        )
    }

    func normalizeModelControlsForStandardComposer(
        _ options: inout CodexAppServerTurnOptions
    ) {
        let modelID = ModelReasoningGridCatalog.effectiveModelID(
            selectedModelID: options.model,
            options: modelOptionsForMenu
        )
        let option = modelOption(matching: modelID)
        options.reasoningEffort = ModelReasoningGridCatalog.normalizedVisibleEffort(
            option: option,
            current: options.reasoningEffort,
            layout: modelReasoningGridLayout
        )
        // 普通模式只有 Fast 会写 priority；auto/flex 仅属于开发者高级选项。
        options.serviceTier = ModelReasoningGridCatalog.normalizedStandardServiceTier(
            options.serviceTier,
            runtimeProvider: options.runtimeProvider
        )
    }

    func modelOption(matching modelID: String?) -> CodexAppServerModelOption? {
        guard let modelID else { return nil }
        return modelOptionsForMenu.first {
            $0.model.caseInsensitiveCompare(modelID) == .orderedSame
        } ?? modelReasoningGridLayout.model(matching: modelID)
    }

    func payloadRuntimeProviderForSelectedSessionLock() -> String? {
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return nil
        }
        return runtimeProvider == "codex" ? nil : runtimeProvider
    }

    func normalizedRuntimeProvider(_ rawValue: String?) -> String {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(rawValue)
    }
}
