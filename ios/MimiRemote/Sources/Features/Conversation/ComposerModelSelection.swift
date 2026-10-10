import Foundation
import SwiftUI

// 模型目录过滤、默认值选择和会话 runtime 锁定集中在这里，避免 ComposerView
// 同时承担视图布局与模型策略。成员保持 module-internal，供 ComposerView 跨文件扩展协作。
extension ComposerView {
    func preparedTurnOptionsForSubmit() -> CodexAppServerTurnOptions {
        var options = developerModeEnabled
            ? composerState.turnOptions
            : composerState.turnOptions.sanitizedForStandardComposer()
        options.modelSelectionPolicy = developerModeEnabled ? .allowUnlisted : .catalogOnly
        if developerModeEnabled,
           let effort = options.reasoningEffort,
           !supportsReasoningEffort(effort, modelID: options.model ?? effectiveModelID) {
            // 提交边界再兜底，避免目录刷新与发送之间的竞态把非法组合发给 runtime。
            options.reasoningEffort = nil
        } else if !developerModeEnabled {
            normalizeModelControlsForStandardComposer(&options)
        }
        normalizeCatalogCapabilitiesForSubmit(
            &options,
            allowsUnlistedCodexTier: developerModeEnabled
        )
        // 普通发送也显式退出 Plan Mode，不能依赖 nil/absent。
        options.collaborationMode = composerState.isPlanModeSelected ? .plan : .default
        return options
    }

    func synchronizeAuthoritativeCollaborationMode() {
        guard activeComposerDraftScope == currentComposerDraftScope,
              case .session(let sessionID) = activeComposerDraftScope,
              RuntimeFeatureSupport.supportsPlanningAndGoals(for: composerRuntimeProvider),
              let authoritativeMode = sessionStore.activeCollaborationMode(for: sessionID),
              let mode = ComposerCollaborationModeSync.resolvedSendMode(
                  authoritativeMode: authoritativeMode,
                  currentMode: composerState.sendMode,
                  userChoiceRevision: sendModeChoiceRevision,
                  baselineRevision: collaborationModeSyncBaselineRevision
              )
        else {
            return
        }
        guard sessionStore.composerSendModeCache.shouldApplyAuthoritativeMode(
            authoritativeMode,
            for: activeComposerDraftScope
        ) else { return }
        // 被动同步只更新当前 Composer 与本地重建缓存；不会触发 runtime settings 写入。
        composerState.setSendMode(mode)
        persistComposerSendMode(mode, for: activeComposerDraftScope)
    }

    var currentAuthoritativeCollaborationMode: CodexAppServerTurnOptions.CollaborationMode? {
        guard case .session(let sessionID) = currentComposerDraftScope else { return nil }
        return sessionStore.activeCollaborationMode(for: sessionID)
    }

    func suppressCachedAuthoritativeCollaborationMode(for scope: ComposerDraftScopeKey) {
        guard case .session(let sessionID) = scope else { return }
        sessionStore.composerSendModeCache.suppressAuthoritativeMode(
            sessionStore.activeCollaborationMode(for: sessionID),
            for: scope
        )
    }

    var unavailableModelControl: some View {
        Menu {
            Section {
                Button(action: {}) {
                    Label(L10n.text("ui.model"), systemImage: "cpu")
                }
                .disabled(true)

                Text(ComposerTurnSettingsPolicy.unavailableMenuNotice)
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
        .accessibilityValue(ComposerTurnSettingsPolicy.unavailableMenuNotice)
        .accessibilityIdentifier("composer.model.unavailable")
        .help(ComposerTurnSettingsPolicy.unavailableMenuNotice)
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
                    isFastModeSelected: hasAcceleratedServiceTierSelected
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
                selectedServiceTier: composerState.turnOptions.serviceTier,
                onSelectModel: { option, effort in
                    selectModel(option, effort: effort)
                },
                onSelectDefaultModel: { option, effort in
                    selectDefaultModel(option, effort: effort)
                },
                onServiceTierChange: { serviceTier in
                    composerState.updateTurnOptions {
                        $0.serviceTier = serviceTier
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

    var selectedModelOption: CodexAppServerModelOption? {
        modelOption(matching: effectiveModelID)
    }

    var effectiveServiceTier: CodexAppServerModelServiceTier? {
        ModelReasoningGridCatalog.effectiveServiceTier(
            selectedServiceTier: composerState.turnOptions.serviceTier,
            option: selectedModelOption,
            kind: modelReasoningGridLayout.kind
        )
    }

    var hasAcceleratedServiceTierSelected: Bool {
        ModelReasoningGridCatalog.isAcceleratedServiceTier(effectiveServiceTier)
    }

    func modelShortcutAccessibilityValue(for title: String) -> String {
        effectiveServiceTier.map { "\(title) · \($0.name)" } ?? title
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
            modelID: option?.model ?? "gpt-6-astra",
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
        return scoped
    }

    var isUsingBuiltInModelFallback: Bool {
        sessionStore.appServerModelOptions.isEmpty
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
        composerState.updateTurnOptions { ComposerModelSelectionCompatibility.apply(to: &$0) }
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return
        }
        let runtimeChanged =
            normalizedRuntimeProvider(composerState.turnOptions.runtimeProvider) != runtimeProvider
        let explicitModelID = composerState.turnOptions.model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appServerNilIfEmpty
        let unsupportedModel = !developerModeEnabled
            && !isUsingBuiltInModelFallback
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
        let selectedOption = modelOption(matching: effectiveModelID)
        let normalizedServiceTier = ModelReasoningGridCatalog.normalizedServiceTier(
            composerState.turnOptions.serviceTier,
            option: selectedOption,
            kind: modelReasoningGridLayout.kind,
            allowsUnlistedCodexTier: developerModeEnabled
        )
        let unsupportedServiceTier = composerState.turnOptions.serviceTier != normalizedServiceTier
        let unsupportedPersonality = selectedOption?.supportsPersonality == false
            && composerState.turnOptions.personality != nil

        guard runtimeChanged || unsupportedModel || unsupportedEffort
            || unsupportedServiceTier || unsupportedPersonality
        else {
            return
        }
        composerState.updateTurnOptions { options in
            if runtimeChanged || unsupportedModel {
                // 切换 runtime 或目录刷新淘汰旧模型时，使用设置里的对应默认值；
                // 没有自定义设置时使用目录默认项，目录不可用才使用内置稳定 alias。
                applyPreferredDefaultModel(runtimeProvider: runtimeProvider, to: &options)
            } else if unsupportedEffort {
                options.reasoningEffort = normalizedEffort
            }
            let resultingOption = modelOption(matching: ModelReasoningGridCatalog.effectiveModelID(
                selectedModelID: options.model,
                options: modelOptionsForMenu
            ))
            options.serviceTier = ModelReasoningGridCatalog.normalizedServiceTier(
                options.serviceTier,
                option: resultingOption,
                kind: modelReasoningGridLayout.kind,
                allowsUnlistedCodexTier: developerModeEnabled
            )
            if resultingOption?.supportsPersonality == false {
                options.personality = nil
            }
        }
    }

    func applyPreferredDefaultModel(
        runtimeProvider: String,
        to options: inout CodexAppServerTurnOptions
    ) {
        // 默认模型统一从本机设置读取；没有保存配置时使用当前目录默认项。
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
        ComposerModelSelectionCompatibility.apply(to: &options)
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
        options.serviceTier = ModelReasoningGridCatalog.normalizedServiceTier(
            options.serviceTier,
            option: option,
            kind: modelReasoningGridLayout.kind
        )
        if option?.supportsPersonality == false {
            options.personality = nil
        }
    }

    func normalizeCatalogCapabilitiesForSubmit(
        _ options: inout CodexAppServerTurnOptions,
        allowsUnlistedCodexTier: Bool = false
    ) {
        let modelID = ModelReasoningGridCatalog.effectiveModelID(
            selectedModelID: options.model,
            options: modelOptionsForMenu
        )
        if modelReasoningGridLayout.kind != .codex {
            options.serviceTier = nil
        }
        guard let option = modelOption(matching: modelID) else {
            // 开发者模式允许目录外 API key 模型；Codex 没有能力证据时保留显式参数。
            return
        }
        options.serviceTier = ModelReasoningGridCatalog.normalizedServiceTier(
            options.serviceTier,
            option: option,
            kind: modelReasoningGridLayout.kind,
            runtimeProvider: options.runtimeProvider,
            allowsUnlistedCodexTier: allowsUnlistedCodexTier
        )
        if option.supportsPersonality == false {
            options.personality = nil
        }
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
