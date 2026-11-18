import Foundation
import SwiftUI

enum DefaultModelDisplay {
    static func inheritedTitle(
        for runtime: DefaultModelRuntime,
        allOptions: [CodexAppServerModelOption],
        isRefreshing: Bool
    ) -> String {
        // 默认项继续跟随解析策略，固定模型项则保存 ID；同名时也必须能区分。
        L10n.format("ui.default_model_inherited_name", title(
            for: runtime, allOptions: allOptions, isRefreshing: isRefreshing
        ))
    }

    static func title(
        for runtime: DefaultModelRuntime,
        allOptions: [CodexAppServerModelOption],
        isRefreshing: Bool
    ) -> String {
        let candidates = DefaultModelPreferences.options(for: runtime.rawValue, allOptions: allOptions)
        let option = ModelReasoningGridCatalog.preferredDefaultOption(
            runtimeProvider: runtime.rawValue,
            options: candidates
        )
        // 展示复用发送策略，但不写入偏好或把空选项改成显式选择。
        // Claude 离线兜底只有稳定别名，不能把它当成已解析的实际版本。
        if let option, !isUnresolvedClaudeAlias(option, runtime: runtime) {
            return option.menuTitle
        }
        return L10n.text(isRefreshing ? "ui.default_model_loading" : "ui.default_model_unconfirmed")
    }

    private static func isUnresolvedClaudeAlias(
        _ option: CodexAppServerModelOption,
        runtime: DefaultModelRuntime
    ) -> Bool {
        guard runtime == .claude else { return false }
        let title = option.title.lowercased()
        if option.model == "default", title == "default" { return true }
        return CodexAppServerModelOption.builtInClaudeFallback.contains {
            $0.model == option.model && (title == $0.title.lowercased() || title == $0.model)
        }
    }
}

struct DefaultModelSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @AppStorage(WorkspaceSessionRuntimeChoice.preferenceKey)
    private var preferredRuntimeRawValue = WorkspaceSessionRuntimeChoice.codex.rawValue
    @AppStorage(WorkspaceSessionRuntimeChoice.enabledRuntimesPreferenceKey)
    private var enabledRuntimesRawValue = WorkspaceSessionRuntimeChoice.defaultEnabledRuntimesRawValue
    /// 定向补拉不经过 Store 的聚合刷新标记，页面自己记加载中。
    @State private var isLoadingCatalog = false
    @State private var didLoadCatalog = false
    @State private var catalogLoadGeneration = 0

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let runtimes = displayedRuntimes
        let isRefreshing = isLoadingCatalog || sessionStore.isRefreshingAppServerModels

        Form {
            // 第一组：用户自主选择在工作区启用哪些模型通道，并设置默认优先使用的通道。
            Section {
                ForEach(WorkspaceSessionRuntimeChoice.allCases) { choice in
                    let isEnabled = isRuntimeEnabled(choice)
                    let isLastEnabled = isEnabled && enabledChoices.count <= 1

                    Toggle(
                        isOn: Binding(
                            get: { isRuntimeEnabled(choice) },
                            set: { updateRuntimeEnabled(choice, isEnabled: $0) }
                        )
                    ) {
                        HStack(spacing: SettingsLayoutMetrics.iconSpacing) {
                            RuntimeBrandMarkIcon(mark: choice.brandMark, size: 18)
                                .frame(
                                    width: SettingsLayoutMetrics.iconSlot,
                                    height: SettingsLayoutMetrics.iconSlot
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.choiceTitle)
                                    .settingsTitleFont()
                                    .foregroundStyle(tokens.primaryText)
                                Text(choice.listSubtitle)
                                    .settingsDetailFont()
                                    .foregroundStyle(tokens.secondaryText)
                            }
                        }
                    }
                    .disabled(isLastEnabled)
                    .settingsRow(.descriptive)
                    .accessibilityIdentifier("settings.defaultModels.enabled.\(choice.rawValue)")
                }

                if enabledChoices.count > 1 {
                    SettingsChoiceRow(
                        title: L10n.text("ui.preferred_runtime"),
                        systemImage: "terminal",
                        options: enabledChoices,
                        selection: preferredRuntimeBinding
                    )
                    .settingsRow()
                    .accessibilityIdentifier("settings.preferredRuntime")
                }
            } header: {
                SettingsGroupHeader(title: L10n.text("ui.preferred_runtime"), showsDivider: false)
            } footer: {
                Text(L10n.text("ui.enabled_runtimes_footer"))
                    .settingsSectionFooterStyle()
            }
            .settingsGroupRowStyle()

            // 第二组：仅针对已启用的模型展示默认型号与推理强度摘要，点击进入二级选项页配置。
            Section {
                ForEach(runtimes) { runtime in
                    DefaultModelRuntimeOverviewRow(
                        runtime: runtime,
                        allOptions: sessionStore.appServerModelOptions,
                        isRefreshing: isRefreshing,
                        isCatalogUnavailable: !isRefreshing && didLoadCatalog
                            && sessionStore.modelCatalogIsMissing(runtimeProvider: runtime.rawValue),
                        tokens: tokens,
                        onRefreshCatalog: {
                            await loadCatalog(force: true)
                        }
                    )
                }
            } header: {
                SettingsGroupHeader(title: L10n.text("ui.default_model"), showsDivider: true)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(runtimes) { runtime in
                        if !isRefreshing && didLoadCatalog
                            && sessionStore.modelCatalogIsMissing(runtimeProvider: runtime.rawValue) {
                            Text(L10n.format("ui.default_model_catalog_unavailable", runtime.settingsTitle))
                                .accessibilityIdentifier("settings.defaultModels.unavailable.\(runtime.rawValue)")
                        }
                    }
                    Text(L10n.text("ui.default_model_settings_description"))
                }
                .settingsSectionFooterStyle()
            }
            .settingsGroupRowStyle()
        }
        .themedSettingsForm(tokens: tokens)
        .settingsDetailPage(tokens: tokens)
        .navigationTitle(L10n.text("ui.default_model"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(tokens.accent)
        .toolbar {
            // 与输入框模型菜单里的「刷新模型列表」同一条强制刷新路径。
            ToolbarItem(placement: .topBarTrailing) {
                if isRefreshing {
                    ProgressView()
                } else {
                    Button {
                        Task { await loadCatalog(force: true) }
                    } label: {
                        Label(L10n.text("ui.refresh_model_list"), systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("settings.defaultModels.refresh")
                }
            }
        }
        .onAppear {
            normalizePreferredRuntimeIfNeeded()
            normalizeStoredEfforts()
        }
        .onChange(of: sessionStore.appServerModelOptions) { _, _ in
            normalizeStoredEfforts()
        }
        .task(id: catalogLoadKey) {
            // 进页总要跑一次（顺带复查 DeepSeek 等通道是否已开启）；之后只在换连接清空目录、
            // 有 Runtime 缺目录时补拉。补拉失败时缺口不变、key 不变，不会反复重试（#871）。
            guard !didLoadCatalog || !catalogLoadKey.missingRuntimes.isEmpty else { return }
            await loadCatalog(force: false)
        }
    }

    private var enabledChoices: [WorkspaceSessionRuntimeChoice] {
        WorkspaceSessionRuntimeChoice.enabledRuntimes(from: enabledRuntimesRawValue)
    }

    private func isRuntimeEnabled(_ choice: WorkspaceSessionRuntimeChoice) -> Bool {
        WorkspaceSessionRuntimeChoice.isEnabled(choice, in: enabledRuntimesRawValue)
    }

    private func updateRuntimeEnabled(_ choice: WorkspaceSessionRuntimeChoice, isEnabled: Bool) {
        let updated = WorkspaceSessionRuntimeChoice.updatingEnabledState(
            for: choice,
            isEnabled: isEnabled,
            enabledRawValue: enabledRuntimesRawValue,
            preferredRawValue: preferredRuntimeRawValue
        )
        enabledRuntimesRawValue = updated.enabledRawValue
        preferredRuntimeRawValue = updated.preferredRawValue
    }

    private func normalizePreferredRuntimeIfNeeded() {
        let resolved = WorkspaceSessionRuntimeChoice.resolvedPreferred(
            preferredRawValue: preferredRuntimeRawValue,
            enabledRawValue: enabledRuntimesRawValue
        )
        if preferredRuntimeRawValue != resolved.rawValue {
            preferredRuntimeRawValue = resolved.rawValue
        }
    }

    private var preferredRuntimeBinding: Binding<WorkspaceSessionRuntimeChoice> {
        Binding(
            get: {
                WorkspaceSessionRuntimeChoice.resolvedPreferred(
                    preferredRawValue: preferredRuntimeRawValue,
                    enabledRawValue: enabledRuntimesRawValue
                )
            },
            set: { preferredRuntimeRawValue = $0.rawValue }
        )
    }

    private var catalogLoadKey: DefaultModelCatalogLoadKey {
        DefaultModelCatalogLoadKey(
            hostScope: sessionStore.appStore.activeHostScope,
            missingRuntimes: displayedRuntimes.filter {
                sessionStore.modelCatalogIsMissing(runtimeProvider: $0.rawValue)
            }
        )
    }

    private func loadCatalog(force: Bool) async {
        catalogLoadGeneration &+= 1
        let generation = catalogLoadGeneration
        isLoadingCatalog = true
        didLoadCatalog = true
        await sessionStore.refreshPickerModelCatalog(
            runtimeProviders: displayedRuntimes.map(\.rawValue),
            force: force
        )
        // 被新一轮取代时由新一轮收尾，旧请求晚到不能提前撤掉加载态。
        guard catalogLoadGeneration == generation else { return }
        isLoadingCatalog = false
        normalizeStoredEfforts()
    }

    private func normalizeStoredEfforts() {
        for runtime in displayedRuntimes {
            normalizeStoredEffort(for: runtime)
        }
    }

    private var displayedRuntimes: [DefaultModelRuntime] {
        let enabledSet = Set(enabledChoices.map(\.rawValue))
        return DefaultModelRuntime.allCases.filter { enabledSet.contains($0.rawValue) }
    }

    private func normalizeStoredEffort(for runtime: DefaultModelRuntime) {
        // 模型目录为空时可能暂时只显示内置兜底；保留未知的历史模型与档位，
        // 等 model/list 返回 canonical id 后再恢复，避免网络短暂失败覆盖用户配置。
        let allOptions = sessionStore.appServerModelOptions
        let candidates = DefaultModelPreferences.options(
            for: runtime.rawValue,
            allOptions: allOptions
        )
        let storedID = DefaultModelPreferences.storedModelOptionID(for: runtime.rawValue)
        guard storedID == nil || candidates.contains(where: { $0.id == storedID }) else {
            return
        }
        guard let storedEffort = DefaultModelPreferences.storedReasoningEffort(for: runtime.rawValue),
              let option = DefaultModelPreferences.resolvedSelection(
                  for: runtime.rawValue,
                  allOptions: allOptions
              )?.option
        else {
            return
        }
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: runtime.rawValue,
            options: candidates
        )
        let visibleEfforts = ModelReasoningGridCatalog.visibleEfforts(for: option, layout: layout)
        if !visibleEfforts.contains(storedEffort) {
            UserDefaults.standard.removeObject(
                forKey: DefaultModelPreferences.reasoningEffortKey(for: runtime.rawValue)
            )
        }
    }
}

private struct DefaultModelCatalogLoadKey: Equatable {
    let hostScope: HostScope
    let missingRuntimes: [DefaultModelRuntime]
}

/// 一级模型行：外显该通道当前生效的默认模型名称与推理强度，点击推入二级页面选择具体模型与推理强度。
private struct DefaultModelRuntimeOverviewRow: View {
    let runtime: DefaultModelRuntime
    let allOptions: [CodexAppServerModelOption]
    let isRefreshing: Bool
    let isCatalogUnavailable: Bool
    let tokens: ThemeTokens
    let onRefreshCatalog: () async -> Void

    @AppStorage private var modelOptionID: String
    @AppStorage private var reasoningEffortRawValue: String

    init(
        runtime: DefaultModelRuntime,
        allOptions: [CodexAppServerModelOption],
        isRefreshing: Bool,
        isCatalogUnavailable: Bool,
        tokens: ThemeTokens,
        onRefreshCatalog: @escaping () async -> Void
    ) {
        self.runtime = runtime
        self.allOptions = allOptions
        self.isRefreshing = isRefreshing
        self.isCatalogUnavailable = isCatalogUnavailable
        self.tokens = tokens
        self.onRefreshCatalog = onRefreshCatalog
        _modelOptionID = AppStorage(
            wrappedValue: "",
            DefaultModelPreferences.modelOptionIDKey(for: runtime.rawValue)
        )
        _reasoningEffortRawValue = AppStorage(
            wrappedValue: "",
            DefaultModelPreferences.reasoningEffortKey(for: runtime.rawValue)
        )
    }

    var body: some View {
        NavigationLink {
            DefaultRuntimeModelDetailView(
                runtime: runtime,
                isRefreshing: isRefreshing,
                isCatalogUnavailable: isCatalogUnavailable,
                onRefreshCatalog: onRefreshCatalog
            )
        } label: {
            HStack(spacing: SettingsLayoutMetrics.iconSpacing) {
                RuntimeBrandMarkIcon(mark: runtime.brandMark, size: 18)
                    .frame(
                        width: SettingsLayoutMetrics.iconSlot,
                        height: SettingsLayoutMetrics.iconSlot
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(runtime.settingsTitle)
                        .settingsTitleFont()
                        .foregroundStyle(tokens.primaryText)

                    if let effortSummary = reasoningEffortSummary {
                        Text("\(L10n.text("ui.reasoning_effort")) · \(effortSummary)")
                            .settingsDetailFont()
                            .foregroundStyle(tokens.secondaryText)
                    }
                }

                Spacer(minLength: 8)

                Text(modelSummaryTitle)
                    .settingsDetailFont()
                    .foregroundStyle(tokens.secondaryText)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }
        .settingsRow(.descriptive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(runtime.settingsTitle)
        .accessibilityValue(modelSummaryTitle)
        .accessibilityIdentifier("settings.defaultModels.model.\(runtime.rawValue)")
    }

    private var modelOptions: [CodexAppServerModelOption] {
        DefaultModelPreferences.options(for: runtime.rawValue, allOptions: allOptions)
    }

    private var selectedModelOption: CodexAppServerModelOption? {
        if !modelOptionID.isEmpty,
           let storedOption = modelOptions.first(where: { $0.id == modelOptionID }) {
            return storedOption
        }
        return DefaultModelPreferences.resolvedSelection(
            for: runtime.rawValue,
            allOptions: allOptions
        )?.option
    }

    private var modelSummaryTitle: String {
        if !modelOptionID.isEmpty,
           let storedOption = modelOptions.first(where: { $0.id == modelOptionID }) {
            return storedOption.menuTitle
        }
        return DefaultModelDisplay.inheritedTitle(
            for: runtime,
            allOptions: allOptions,
            isRefreshing: isRefreshing
        )
    }

    private var availableEfforts: [CodexAppServerReasoningEffort] {
        guard let selectedModelOption else {
            return []
        }
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: runtime.rawValue,
            options: modelOptions
        )
        return ModelReasoningGridCatalog.visibleEfforts(for: selectedModelOption, layout: layout)
    }

    private var reasoningEffortSummary: String? {
        guard let selectedModelOption else { return nil }
        guard !availableEfforts.isEmpty else {
            return L10n.text("ui.no_reasoning_effort_available")
        }
        let resolvedEffort: CodexAppServerReasoningEffort
        if let stored = CodexAppServerReasoningEffort(rawValue: reasoningEffortRawValue),
           availableEfforts.contains(stored) {
            resolvedEffort = stored
        } else {
            let layout = ModelReasoningGridCatalog.layout(
                runtimeProvider: runtime.rawValue,
                options: modelOptions
            )
            resolvedEffort = ModelReasoningGridCatalog.preferredDefaultEffort(
                runtimeProvider: runtime.rawValue,
                option: selectedModelOption,
                layout: layout
            ) ?? availableEfforts.first ?? .medium
        }
        return ModelReasoningGridCatalog.effortTitle(
            resolvedEffort,
            runtimeProvider: runtime.rawValue
        )
    }
}

/// 二级模型与推理强度配置页：用户先选择该通道下的具体默认模型，下方推理强度随之联动切换。
private struct DefaultRuntimeModelDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    let runtime: DefaultModelRuntime
    let isRefreshing: Bool
    let isCatalogUnavailable: Bool
    let onRefreshCatalog: () async -> Void

    @AppStorage private var modelOptionID: String
    @AppStorage private var reasoningEffortRawValue: String

    init(
        runtime: DefaultModelRuntime,
        isRefreshing: Bool,
        isCatalogUnavailable: Bool,
        onRefreshCatalog: @escaping () async -> Void
    ) {
        self.runtime = runtime
        self.isRefreshing = isRefreshing
        self.isCatalogUnavailable = isCatalogUnavailable
        self.onRefreshCatalog = onRefreshCatalog
        _modelOptionID = AppStorage(
            wrappedValue: "",
            DefaultModelPreferences.modelOptionIDKey(for: runtime.rawValue)
        )
        _reasoningEffortRawValue = AppStorage(
            wrappedValue: "",
            DefaultModelPreferences.reasoningEffortKey(for: runtime.rawValue)
        )
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                modelOptionRow(
                    id: "",
                    title: DefaultModelDisplay.inheritedTitle(
                        for: runtime,
                        allOptions: allOptions,
                        isRefreshing: isRefreshing
                    ),
                    subtitle: nil,
                    tokens: tokens
                )
                .accessibilityIdentifier("settings.defaultModels.option.\(runtime.rawValue).default")

                ForEach(modelOptions) { option in
                    modelOptionRow(
                        id: option.id,
                        title: option.menuTitle,
                        subtitle: option.description,
                        tokens: tokens
                    )
                    .accessibilityIdentifier("settings.defaultModels.option.\(runtime.rawValue).\(option.id)")
                }
            } header: {
                SettingsGroupHeader(title: L10n.text("ui.model"), showsDivider: false)
            } footer: {
                if isCatalogUnavailable {
                    Text(L10n.format("ui.default_model_catalog_unavailable", runtime.settingsTitle))
                        .accessibilityIdentifier("settings.defaultModels.unavailable.\(runtime.rawValue)")
                        .settingsSectionFooterStyle()
                }
            }
            .settingsGroupRowStyle()

            if selectedModelOption != nil {
                Section {
                    if availableEfforts.isEmpty {
                        LabeledContent(L10n.text("ui.reasoning_effort")) {
                            Text(L10n.text("ui.no_reasoning_effort_available"))
                                .foregroundStyle(tokens.secondaryText)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityIdentifier(
                            "settings.defaultModels.reasoning.\(runtime.rawValue).unavailable"
                        )
                        .settingsRow(.descriptive)
                    } else {
                        SettingsChoiceRow(
                            title: L10n.text("ui.reasoning_effort"),
                            systemImage: "gauge.with.dots.needle.33percent",
                            options: availableEfforts,
                            selection: reasoningEffortChoiceBinding,
                            optionTitle: {
                                ModelReasoningGridCatalog.effortTitle($0, runtimeProvider: runtime.rawValue)
                            }
                        )
                        .settingsRow()
                        .accessibilityIdentifier("settings.defaultModels.reasoning.\(runtime.rawValue)")
                    }
                } header: {
                    SettingsGroupHeader(title: L10n.text("ui.reasoning_effort"), showsDivider: true)
                } footer: {
                    Text(L10n.text("ui.default_model_reasoning_dynamic_footer"))
                        .settingsSectionFooterStyle()
                }
                .settingsGroupRowStyle()
            }

            if hasCustomDefault {
                Section {
                    Button {
                        modelOptionID = ""
                        reasoningEffortRawValue = ""
                    } label: {
                        Label(
                            L10n.text("ui.reset_to_built_in_default"),
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                    .foregroundStyle(tokens.warning)
                    .settingsRow()
                    .accessibilityIdentifier("settings.defaultModels.reset.\(runtime.rawValue)")
                } header: {
                    SettingsGroupHeader(showsDivider: true)
                }
                .settingsGroupRowStyle()
            }
        }
        .themedSettingsForm(tokens: tokens)
        .settingsDetailPage(tokens: tokens)
        .navigationTitle(runtime.settingsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .tint(tokens.accent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isRefreshing {
                    ProgressView()
                } else {
                    Button {
                        Task { await onRefreshCatalog() }
                    } label: {
                        Label(L10n.text("ui.refresh_model_list"), systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private func modelOptionRow(
        id: String,
        title: String,
        subtitle: String?,
        tokens: ThemeTokens
    ) -> some View {
        let isSelected = modelSelectionBinding.wrappedValue == id
        return Button {
            modelSelectionBinding.wrappedValue = id
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .settingsTitleFont(weight: isSelected ? .semibold : .regular)
                        .foregroundStyle(tokens.primaryText)
                    if let subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(subtitle)
                            .settingsDetailFont()
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tokens.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsRow(.descriptive)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var allOptions: [CodexAppServerModelOption] {
        sessionStore.appServerModelOptions
    }

    private var hasCustomDefault: Bool {
        !modelOptionID.isEmpty || !reasoningEffortRawValue.isEmpty
    }

    private var modelOptions: [CodexAppServerModelOption] {
        DefaultModelPreferences.options(for: runtime.rawValue, allOptions: allOptions)
    }

    private func resolvedOption(for optionID: String) -> CodexAppServerModelOption? {
        if !optionID.isEmpty,
           let storedOption = modelOptions.first(where: { $0.id == optionID }) {
            return storedOption
        }
        return DefaultModelPreferences.resolvedSelection(
            for: runtime.rawValue,
            allOptions: allOptions
        )?.option
    }

    private var selectedModelOption: CodexAppServerModelOption? {
        resolvedOption(for: modelOptionID)
    }

    private func efforts(for optionID: String) -> [CodexAppServerReasoningEffort] {
        guard let option = resolvedOption(for: optionID) else {
            return []
        }
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: runtime.rawValue,
            options: modelOptions
        )
        return ModelReasoningGridCatalog.visibleEfforts(for: option, layout: layout)
    }

    private var availableEfforts: [CodexAppServerReasoningEffort] {
        efforts(for: modelOptionID)
    }

    private var modelSelectionBinding: Binding<String> {
        Binding(
            get: {
                guard !modelOptionID.isEmpty,
                      modelOptions.contains(where: { $0.id == modelOptionID })
                else {
                    return ""
                }
                return modelOptionID
            },
            set: { newValue in
                let nextEfforts = efforts(for: newValue)
                modelOptionID = newValue
                // 直接基于 newValue 计算目标模型的可见档位，避免 @AppStorage 值语义快照读取旧档位。
                if let storedEffort = CodexAppServerReasoningEffort(rawValue: reasoningEffortRawValue),
                   !nextEfforts.contains(storedEffort) {
                    reasoningEffortRawValue = ""
                }
            }
        )
    }

    private var reasoningEffortChoiceBinding: Binding<CodexAppServerReasoningEffort> {
        Binding(
            get: {
                CodexAppServerReasoningEffort(rawValue: reasoningEffortSelectionBinding.wrappedValue)
                    ?? availableEfforts.first
                    ?? .medium
            },
            set: { reasoningEffortSelectionBinding.wrappedValue = $0.rawValue }
        )
    }

    private var reasoningEffortSelectionBinding: Binding<String> {
        Binding(
            get: {
                if let storedEffort = CodexAppServerReasoningEffort(rawValue: reasoningEffortRawValue),
                   availableEfforts.contains(storedEffort) {
                    return storedEffort.rawValue
                }
                let layout = ModelReasoningGridCatalog.layout(
                    runtimeProvider: runtime.rawValue,
                    options: modelOptions
                )
                return ModelReasoningGridCatalog.preferredDefaultEffort(
                    runtimeProvider: runtime.rawValue,
                    option: selectedModelOption,
                    layout: layout
                )?.rawValue ?? availableEfforts.first?.rawValue ?? ""
            },
            set: { reasoningEffortRawValue = $0 }
        )
    }
}

private extension DefaultModelRuntime {
    var settingsTitle: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude Code"
        case .deepseek:
            return "DeepSeek Harness"
        }
    }

    var brandMark: RuntimeBrandMark {
        switch self {
        case .codex:
            return .openAI
        case .claude:
            return .claude
        case .deepseek:
            return .deepSeek
        }
    }
}
