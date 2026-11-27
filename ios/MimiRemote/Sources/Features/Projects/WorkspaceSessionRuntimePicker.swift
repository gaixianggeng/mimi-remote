import SwiftUI

/// 工作区会话只浏览一个 Runtime；这里集中维护上游 provider、品牌资源和可用性映射。
enum WorkspaceSessionRuntimeChoice: String, CaseIterable, Identifiable {
    case codex
    case claude
    case agy
    case deepseek

    static let preferenceKey = "workspace.preferredRuntime"
    static let enabledRuntimesPreferenceKey = "workspace.enabledRuntimes"
    static let defaultEnabledRuntimesRawValue = allCases.map(\.rawValue).joined(separator: ",")

    static func stored(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .codex
    }

    /// 解析用户在模型设置中勾选启用的模型列表，始终保持 `allCases` 的稳定顺序，
    /// 且至少保留一个启用项（全空或异常值时回退到默认全开，避免工作区无模型可用）。
    static func enabledRuntimes(from rawValue: String?) -> [Self] {
        guard let rawValue else { return allCases }
        let tokens = Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let resolved = allCases.filter { tokens.contains($0.rawValue) }
        return resolved.isEmpty ? allCases : resolved
    }

    static func enabledRuntimeSet(from rawValue: String?) -> Set<Self> {
        Set(enabledRuntimes(from: rawValue))
    }

    static func encodeEnabledRuntimes(_ choices: some Sequence<Self>) -> String {
        let set = Set(choices)
        let ordered = allCases.filter { set.contains($0) }
        let normalized = ordered.isEmpty ? [Self.codex] : ordered
        return normalized.map(\.rawValue).joined(separator: ",")
    }

    static func isEnabled(_ choice: Self, in rawValue: String?) -> Bool {
        enabledRuntimeSet(from: rawValue).contains(choice)
    }

    /// 结合「已启用模型」解析当前优先使用的模型；若原先的优先项已被关闭，则自动落到第一个已启用项。
    static func resolvedPreferred(
        preferredRawValue: String?,
        enabledRawValue: String?
    ) -> Self {
        let enabled = enabledRuntimes(from: enabledRawValue)
        let preferred = stored(preferredRawValue)
        if enabled.contains(preferred) {
            return preferred
        }
        return enabled.first ?? .codex
    }

    /// 切换某个模型的启用开关，返回归一化后的 `(enabledRawValue, preferredRawValue)`。
    /// 若用户尝试关闭唯一剩余的已启用模型，则保持原状不变。
    static func updatingEnabledState(
        for choice: Self,
        isEnabled: Bool,
        enabledRawValue: String?,
        preferredRawValue: String?
    ) -> (enabledRawValue: String, preferredRawValue: String) {
        var current = enabledRuntimeSet(from: enabledRawValue)
        if isEnabled {
            current.insert(choice)
        } else if current.count > 1 {
            current.remove(choice)
        }
        let nextEnabledRaw = encodeEnabledRuntimes(current)
        let nextPreferred = resolvedPreferred(
            preferredRawValue: preferredRawValue,
            enabledRawValue: nextEnabledRaw
        )
        return (nextEnabledRaw, nextPreferred.rawValue)
    }

    var id: String { rawValue }

    var runtimeProvider: String { rawValue }

    var listTitle: String {
        switch self {
        case .codex:
            return L10n.text("ui.runtime_default")
        case .claude:
            return L10n.text("ui.runtime_claude_short")
        case .agy:
            return "Antigravity"
        case .deepseek:
            return "DeepSeek"
        }
    }

    var title: String {
        switch self {
        case .codex:
            return L10n.text("ui.create_a_new_codex_session")
        case .claude:
            return L10n.text("ui.create_a_new_claude_code_session")
        case .agy:
            return L10n.text("ui.create_a_new_antigravity_session")
        case .deepseek:
            return "Create a new DeepSeek Harness session"
        }
    }

    var brandMark: RuntimeBrandMark {
        switch self {
        case .codex:
            return .openAI
        case .claude:
            return .claude
        case .agy:
            return .antigravity
        case .deepseek:
            return .deepSeek
        }
    }

    var actionSystemImage: String {
        switch self {
        case .codex: "plus.circle"
        case .claude: "sparkles"
        case .agy: "wand.and.stars"
        case .deepseek: "terminal.fill"
        }
    }

    /// 弹窗形态每行留了副标题位；文案说明这个 Runtime 在本机意味着什么，
    /// 不可用时由调用方替换成主机未启用的解释。
    var listSubtitle: String {
        switch self {
        case .codex:
            return L10n.text("ui.runtime_subtitle_codex")
        case .claude:
            return L10n.text("ui.runtime_subtitle_claude")
        case .agy:
            return L10n.text("ui.runtime_subtitle_antigravity")
        case .deepseek:
            return "DeepSeek Harness"
        }
    }

    /// 该 runtime 现在是否可选。
    ///
    /// 先按用户在「模型设置」中打开的通道过滤；在已开启的模型里：
    /// 若主机一个通道都没报可用，则回退到首个已启用模型（优先 codex），避免选择器变成空列表。
    /// 主机已上报通道时，只返回已启用且实际可用的交集；空集合用于阻止新建不可用通道的会话。
    /// 工作区展示的兜底由 WorkspaceRuntimeSelectionState 保留，不向创建入口提供虚假的可用项。
    static func available(
        runtimeProviders: Set<String>,
        enabledRuntimes: Set<Self> = Set(allCases)
    ) -> [Self] {
        let enabledOrdered = allCases.filter { enabledRuntimes.contains($0) }
        let candidates = enabledOrdered.isEmpty ? allCases : enabledOrdered
        return candidates.filter {
            isAvailable($0, in: runtimeProviders, enabledCandidates: candidates)
        }
    }

    func isAvailable(
        in runtimeProviders: Set<String>,
        enabledRuntimes: Set<Self> = Set(allCases)
    ) -> Bool {
        let enabledOrdered = Self.allCases.filter { enabledRuntimes.contains($0) }
        let candidates = enabledOrdered.isEmpty ? Self.allCases : enabledOrdered
        guard candidates.contains(self) else { return false }
        return Self.isAvailable(self, in: runtimeProviders, enabledCandidates: candidates)
    }

    private static func isAvailable(
        _ choice: Self,
        in runtimeProviders: Set<String>,
        enabledCandidates: [Self]
    ) -> Bool {
        if runtimeProviders.isEmpty {
            return choice == (enabledCandidates.first ?? .codex)
        }
        return runtimeProviders.contains(choice.runtimeProvider)
    }

    /// 选择器出现时静默重探暂不可用的 Runtime：回前台换代窗口里没探成的通道，
    /// 不能一直挂着「点击重新检查」等用户手动点；真正关闭的通道重探后仍不可用（#777）。
    static func recheckUnavailable(
        in runtimeProviders: Set<String>,
        enabledRuntimes: Set<Self> = Set(allCases),
        using retry: (Self) async -> Bool
    ) async {
        let enabledOrdered = allCases.filter { enabledRuntimes.contains($0) }
        let candidates = enabledOrdered.isEmpty ? allCases : enabledOrdered
        for choice in candidates where !choice.isAvailable(in: runtimeProviders, enabledRuntimes: Set(candidates)) {
            guard !Task.isCancelled else { return }
            _ = await retry(choice)
        }
    }
}

/// 独立子视图保持 Runtime 选择的布局、命中区和辅助功能语义稳定。
struct WorkspaceRuntimePicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(WorkspaceSessionRuntimeChoice.enabledRuntimesPreferenceKey)
    private var enabledRuntimesRawValue = WorkspaceSessionRuntimeChoice.defaultEnabledRuntimesRawValue
    @Namespace private var selectionNamespace
    @State private var retryingRuntime: WorkspaceSessionRuntimeChoice?

    @Binding var browseScope: WorkspaceSessionBrowseScope
    let availableRuntimeProviders: Set<String>
    let onRetryUnavailable: (WorkspaceSessionRuntimeChoice) async -> Bool

    init(
        browseScope: Binding<WorkspaceSessionBrowseScope>,
        availableRuntimeProviders: Set<String>,
        onRetryUnavailable: @escaping (WorkspaceSessionRuntimeChoice) async -> Bool
    ) {
        _browseScope = browseScope
        self.availableRuntimeProviders = availableRuntimeProviders
        self.onRetryUnavailable = onRetryUnavailable
    }

    init(
        selection: Binding<WorkspaceSessionRuntimeChoice>,
        availableRuntimeProviders: Set<String>,
        onRetryUnavailable: @escaping (WorkspaceSessionRuntimeChoice) async -> Bool
    ) {
        _browseScope = Binding(
            get: { .single(selection.wrappedValue) },
            set: {
                if case let .single(choice) = $0 {
                    selection.wrappedValue = choice
                }
            }
        )
        self.availableRuntimeProviders = availableRuntimeProviders
        self.onRetryUnavailable = onRetryUnavailable
    }

    private var enabledChoices: [WorkspaceSessionRuntimeChoice] {
        WorkspaceSessionRuntimeChoice.enabledRuntimes(from: enabledRuntimesRawValue)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let choices = enabledChoices
        let enabledSet = Set(choices)

        Group {
            if choices.count == 1, let onlyChoice = choices.first {
                singleChoiceBadge(
                    choice: onlyChoice,
                    enabledSet: enabledSet,
                    tokens: tokens
                )
            } else {
                multiChoiceStrip(
                    choices: choices,
                    enabledSet: enabledSet,
                    tokens: tokens
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("ui.runtime_provider"))
        .accessibilityIdentifier("workspace.sessions.runtimePicker")
        .task(id: enabledRuntimesRawValue) {
            await WorkspaceSessionRuntimeChoice.recheckUnavailable(
                in: availableRuntimeProviders,
                enabledRuntimes: enabledSet,
                using: onRetryUnavailable
            )
        }
    }

    @ViewBuilder
    private func singleChoiceBadge(
        choice: WorkspaceSessionRuntimeChoice,
        enabledSet: Set<WorkspaceSessionRuntimeChoice>,
        tokens: ThemeTokens
    ) -> some View {
        let isAvailable = choice.isAvailable(
            in: availableRuntimeProviders,
            enabledRuntimes: enabledSet
        )
        let label = HStack(spacing: 6) {
            if retryingRuntime == choice {
                ProgressView().controlSize(.mini).frame(width: 14, height: 14)
            } else {
                RuntimeBrandMarkIcon(mark: choice.brandMark, size: 14)
            }

            Text(choice.listTitle)
                .font(themeStore.uiFont(.footnote, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(isAvailable ? tokens.secondaryText : tokens.tertiaryText)
        .opacity(isAvailable ? 0.9 : 0.56)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .frame(
            minWidth: WorkbenchChromeIconMetrics.minimumHitTarget,
            minHeight: WorkbenchChromeIconMetrics.minimumHitTarget
        )
        .contentShape(Rectangle())

        // 只开启一个模型时不再包双层分段胶囊外轨；可用时保持安静展示，暂不可用时允许单击重探。
        if isAvailable {
            label
                .accessibilityElement(children: .combine)
                .accessibilityLabel(choice.listTitle)
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("workspace.sessions.runtime.\(choice.rawValue)")
        } else {
            Button {
                guard retryingRuntime == nil else { return }
                retryingRuntime = choice
                Task {
                    let recovered = await onRetryUnavailable(choice)
                    if recovered { select(.single(choice)) }
                    retryingRuntime = nil
                }
            } label: {
                label
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .disabled(retryingRuntime != nil)
            .accessibilityLabel(choice.listTitle)
            .accessibilityHint(L10n.text("ui.runtime_retry_hint"))
            .accessibilityIdentifier("workspace.sessions.runtime.\(choice.rawValue)")
        }
    }

    private func multiChoiceStrip(
        choices: [WorkspaceSessionRuntimeChoice],
        enabledSet: Set<WorkspaceSessionRuntimeChoice>,
        tokens: ThemeTokens
    ) -> some View {
        let isAllSelected = browseScope.isAll

        return HStack(spacing: 0) {
            Button {
                select(.all)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 14, height: 14)

                    Text(L10n.text("ui.workspace_runtime_all"))
                        .font(themeStore.uiFont(.footnote, weight: isAllSelected ? .semibold : .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(isAllSelected ? tokens.accentText : tokens.secondaryText)
                .opacity(isAllSelected ? 1 : 0.78)
                .padding(.horizontal, 8)
                .frame(minHeight: 32)
                .background {
                    if isAllSelected {
                        selectionCapsule(tokens: tokens)
                    }
                }
                .frame(
                    minWidth: WorkbenchChromeIconMetrics.minimumHitTarget,
                    minHeight: WorkbenchChromeIconMetrics.minimumHitTarget
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .disabled(retryingRuntime != nil)
            .accessibilityLabel(L10n.text("ui.workspace_runtime_all"))
            .accessibilityAddTraits(isAllSelected ? .isSelected : [])
            .accessibilityHint(L10n.text("ui.show_all_runtime_sessions_hint"))
            .accessibilityIdentifier("workspace.sessions.runtime.all")

            ForEach(choices) { choice in
                let isSelected = browseScope == .single(choice)
                let isAvailable = choice.isAvailable(
                    in: availableRuntimeProviders,
                    enabledRuntimes: enabledSet
                )

                Button {
                    if isAvailable {
                        select(.single(choice))
                    } else {
                        guard retryingRuntime == nil else { return }
                        let previousScope = browseScope
                        retryingRuntime = choice
                        Task {
                            let recovered = await onRetryUnavailable(choice)
                            if recovered, browseScope == previousScope { select(.single(choice)) }
                            retryingRuntime = nil
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if retryingRuntime == choice {
                            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                        } else {
                            RuntimeBrandMarkIcon(mark: choice.brandMark, size: 14)
                        }

                        Text(choice.listTitle)
                            .font(themeStore.uiFont(.footnote, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    // 选中态使用品牌色文字和描边，不再与右侧“新建会话”争抢实色主操作层级。
                    .foregroundStyle(
                        isSelected
                            ? tokens.accentText
                            : (isAvailable ? tokens.secondaryText : tokens.tertiaryText)
                    )
                    .opacity(
                        isSelected
                            ? 1
                            : (isAvailable ? 0.78 : 0.52)
                    )
                    .padding(.horizontal, 8)
                    .frame(minHeight: 32)
                    .background {
                        if isSelected {
                            selectionCapsule(tokens: tokens)
                        }
                    }
                    // 视觉表面缩小，透明命中层仍至少 44pt，兼顾层级与实体机触控。
                    .frame(
                        minWidth: WorkbenchChromeIconMetrics.minimumHitTarget,
                        minHeight: WorkbenchChromeIconMetrics.minimumHitTarget
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                .disabled(retryingRuntime != nil)
                .accessibilityLabel(choice.listTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(
                    isAvailable
                        ? L10n.text("ui.show_runtime_sessions_hint")
                        : L10n.text("ui.runtime_retry_hint")
                )
                .accessibilityIdentifier("workspace.sessions.runtime.\(choice.rawValue)")
            }
        }
        .padding(.horizontal, 2)
        .background {
            // 与同排工作区项目胶囊共用同一套透明玻璃外轨，保持 36pt 视觉高度与 44pt 命中区。
            WorkbenchChromeMaterial(shape: Capsule(), tokens: tokens)
                .padding(.vertical, 4)
        }
    }

    private func selectionCapsule(tokens: ThemeTokens) -> some View {
        // 选中项只画一层中性玻璃提亮，与外轨透明玻璃胶囊配合，不叠加第二层玻璃或实色块。
        let shape = Capsule()
        return shape
            .fill(
                WorkbenchChromeMaterial<Capsule>.selectionTint(
                    tokens: tokens,
                    reduceTransparency: reduceTransparency || colorSchemeContrast == .increased
                )
            )
            .overlay {
                // 增强对比度仅补中性轮廓，不重新引入紫色边框。
                if colorSchemeContrast == .increased {
                    shape.stroke(tokens.border, lineWidth: 1)
                }
            }
            .matchedGeometryEffect(
                id: "workspace-runtime-selection",
                in: selectionNamespace
            )
    }

    private func select(_ scope: WorkspaceSessionBrowseScope) {
        if reduceMotion {
            browseScope = scope
        } else {
            // 选中内胶囊从当前显示位置继续运动，避免两个独立色块交叉闪烁。
            withAnimation(.spring(response: 0.28, dampingFraction: 1)) {
                browseScope = scope
            }
        }
    }
}

/// 窄屏弹窗形态：触发行仍是一处品牌标记加 chevron，但展开的是锚定气泡而不是系统菜单。
/// 相比 Menu，气泡能给每个 Runtime 留出品牌图标和不可用说明，选择这件事有了自己的表面；
/// iPhone 上显式要求 popover 适配，避免系统把它降级成盖住半屏的 sheet。
struct WorkspaceRuntimePopoverPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(WorkspaceSessionRuntimeChoice.enabledRuntimesPreferenceKey)
    private var enabledRuntimesRawValue = WorkspaceSessionRuntimeChoice.defaultEnabledRuntimesRawValue

    @Binding var browseScope: WorkspaceSessionBrowseScope
    let availableRuntimeProviders: Set<String>
    let onRetryUnavailable: (WorkspaceSessionRuntimeChoice) async -> Bool

    init(
        browseScope: Binding<WorkspaceSessionBrowseScope>,
        availableRuntimeProviders: Set<String>,
        onRetryUnavailable: @escaping (WorkspaceSessionRuntimeChoice) async -> Bool
    ) {
        _browseScope = browseScope
        self.availableRuntimeProviders = availableRuntimeProviders
        self.onRetryUnavailable = onRetryUnavailable
    }

    init(
        selection: Binding<WorkspaceSessionRuntimeChoice>,
        availableRuntimeProviders: Set<String>,
        onRetryUnavailable: @escaping (WorkspaceSessionRuntimeChoice) async -> Bool
    ) {
        _browseScope = Binding(
            get: { .single(selection.wrappedValue) },
            set: {
                if case let .single(choice) = $0 {
                    selection.wrappedValue = choice
                }
            }
        )
        self.availableRuntimeProviders = availableRuntimeProviders
        self.onRetryUnavailable = onRetryUnavailable
    }

    @State private var isPresented = false
    @State private var retryingRuntime: WorkspaceSessionRuntimeChoice?

    private var enabledChoices: [WorkspaceSessionRuntimeChoice] {
        WorkspaceSessionRuntimeChoice.enabledRuntimes(from: enabledRuntimesRawValue)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let choices = enabledChoices
        let enabledSet = Set(choices)

        Group {
            if choices.count == 1, let onlyChoice = choices.first {
                singleChoiceHeader(
                    choice: onlyChoice,
                    enabledSet: enabledSet,
                    tokens: tokens
                )
            } else {
                Button {
                    isPresented = true
                } label: {
                    HStack(spacing: 6) {
                        switch browseScope {
                        case .all:
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(tokens.primaryText)
                                .frame(width: 14, height: 14)
                        case let .single(choice):
                            RuntimeBrandMarkIcon(mark: choice.brandMark, size: 14)
                        }

                        Text(browseScope.listTitle)
                            .font(themeStore.uiFont(.footnote, weight: .medium))
                            .foregroundStyle(tokens.primaryText)
                            .lineLimit(1)

                        Image(systemName: "chevron.down")
                            .font(themeStore.uiFont(size: 10, weight: .semibold))
                            .foregroundStyle(tokens.tertiaryText)
                    }
                    // 与会话行同一个水平内边距：品牌标记与分组标题、会话标题落在同一条左边线上。
                    // 窄屏才显示这一行，因此取紧凑密度。
                    .padding(.horizontal, SessionIndexRowDensity.compact.horizontalPadding)
                    // 视觉高度保持在标题量级，透明命中层仍满足 44pt。
                    .frame(minHeight: WorkbenchChromeIconMetrics.minimumHitTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.runtime_provider"))
                .accessibilityValue(browseScope.listTitle)
                .accessibilityIdentifier("workspace.sessions.runtimePicker")
                .popover(isPresented: $isPresented, arrowEdge: .top) {
                    popoverContent(tokens: tokens, choices: choices, enabledSet: enabledSet)
                        .presentationCompactAdaptation(.popover)
                        .task {
                            await WorkspaceSessionRuntimeChoice.recheckUnavailable(
                                in: availableRuntimeProviders,
                                enabledRuntimes: enabledSet,
                                using: onRetryUnavailable
                            )
                        }
                }
            }
        }
        .onChange(of: choices.count) { _, count in
            if count <= 1, isPresented {
                isPresented = false
            }
        }
        .task(id: enabledRuntimesRawValue) {
            await WorkspaceSessionRuntimeChoice.recheckUnavailable(
                in: availableRuntimeProviders,
                enabledRuntimes: enabledSet,
                using: onRetryUnavailable
            )
        }
    }

    @ViewBuilder
    private func singleChoiceHeader(
        choice: WorkspaceSessionRuntimeChoice,
        enabledSet: Set<WorkspaceSessionRuntimeChoice>,
        tokens: ThemeTokens
    ) -> some View {
        let isAvailable = choice.isAvailable(
            in: availableRuntimeProviders,
            enabledRuntimes: enabledSet
        )

        // 用户只开启了 1 个模型时不再弹出单条目气泡：可用时作为静态标题对齐展示，
        // 暂不可用时直接行内点按重新检查。
        if isAvailable {
            HStack(spacing: 6) {
                RuntimeBrandMarkIcon(mark: choice.brandMark, size: 14)

                Text(choice.listTitle)
                    .font(themeStore.uiFont(.footnote, weight: .medium))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, SessionIndexRowDensity.compact.horizontalPadding)
            .frame(minHeight: WorkbenchChromeIconMetrics.minimumHitTarget, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.text("ui.runtime_provider"))
            .accessibilityValue(choice.listTitle)
            .accessibilityIdentifier("workspace.sessions.runtimePicker")
        } else {
            Button {
                guard retryingRuntime == nil else { return }
                retryingRuntime = choice
                Task {
                    let recovered = await onRetryUnavailable(choice)
                    if recovered {
                        browseScope = .single(choice)
                    }
                    retryingRuntime = nil
                }
            } label: {
                HStack(spacing: 6) {
                    if retryingRuntime == choice {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    } else {
                        RuntimeBrandMarkIcon(mark: choice.brandMark, size: 14)
                            .opacity(0.5)
                    }

                    Text(choice.listTitle)
                        .font(themeStore.uiFont(.footnote, weight: .medium))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)

                    Text(L10n.text("ui.runtime_retry_hint"))
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, SessionIndexRowDensity.compact.horizontalPadding)
                .frame(minHeight: WorkbenchChromeIconMetrics.minimumHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(retryingRuntime != nil)
            .accessibilityLabel(L10n.text("ui.runtime_provider"))
            .accessibilityValue(choice.listTitle)
            .accessibilityHint(L10n.text("ui.runtime_retry_hint"))
            .accessibilityIdentifier("workspace.sessions.runtimePicker")
        }
    }

    private func popoverContent(
        tokens: ThemeTokens,
        choices: [WorkspaceSessionRuntimeChoice],
        enabledSet: Set<WorkspaceSessionRuntimeChoice>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                browseScope = .all
                isPresented = false
            } label: {
                allRuntimesRow(tokens: tokens)
            }
            .buttonStyle(.plain)
            .disabled(retryingRuntime != nil)
            .accessibilityLabel(L10n.text("ui.workspace_runtime_all"))
            .accessibilityAddTraits(browseScope.isAll ? .isSelected : [])
            .accessibilityHint(L10n.text("ui.show_all_runtime_sessions_hint"))
            .accessibilityIdentifier("workspace.sessions.runtime.all")

            Divider()
                .padding(.leading, 42)

            // 只展示用户已开启的 Runtime；暂不可用的那个允许点击重探，
            // 不能让首次网络失败把筛选器锁死到 App 重启。
            ForEach(choices) { choice in
                let isAvailable = choice.isAvailable(
                    in: availableRuntimeProviders,
                    enabledRuntimes: enabledSet
                )
                let isSelected = browseScope == .single(choice)

                Button {
                    if isAvailable {
                        browseScope = .single(choice)
                        isPresented = false
                    } else {
                        guard retryingRuntime == nil else { return }
                        let previousScope = browseScope
                        retryingRuntime = choice
                        Task {
                            let recovered = await onRetryUnavailable(choice)
                            if recovered, browseScope == previousScope {
                                browseScope = .single(choice)
                                isPresented = false
                            }
                            retryingRuntime = nil
                        }
                    }
                } label: {
                    row(choice: choice, isSelected: isSelected, isAvailable: isAvailable, tokens: tokens)
                }
                .buttonStyle(.plain)
                .disabled(retryingRuntime != nil)
                .accessibilityLabel(choice.listTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(
                    isAvailable
                        ? L10n.text("ui.show_runtime_sessions_hint")
                        : L10n.text("ui.runtime_retry_hint")
                )
                .accessibilityIdentifier("workspace.sessions.runtime.\(choice.rawValue)")

                if choice != choices.last {
                    Divider()
                        .padding(.leading, 42)
                }
            }
        }
        .padding(.vertical, 4)
        // 副标题是两行里较长的那一处内容，宽度给到 260 才不会在中文文案上折行。
        .frame(minWidth: 260, alignment: .leading)
    }

    private func allRuntimesRow(tokens: ThemeTokens) -> some View {
        let isSelected = browseScope.isAll
        return HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSelected ? tokens.accentText : tokens.primaryText)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("ui.workspace_runtime_all"))
                    .font(themeStore.uiFont(.subheadline, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(tokens.primaryText)

                Text(L10n.text("ui.runtime_subtitle_all"))
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.tertiaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.accentText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private func row(
        choice: WorkspaceSessionRuntimeChoice,
        isSelected: Bool,
        isAvailable: Bool,
        tokens: ThemeTokens
    ) -> some View {
        HStack(spacing: 10) {
            if retryingRuntime == choice {
                ProgressView().controlSize(.small).frame(width: 20, height: 20)
            } else {
                RuntimeBrandMarkIcon(mark: choice.brandMark, size: 20)
                    // 此菜单中 DeepSeek 的横向墨迹偏宽，只在这里缩小，不影响其他尺寸的标记。
                    .scaleEffect(choice == .deepseek ? 0.86 : 1)
                    .opacity(isAvailable ? 1 : 0.4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(choice.listTitle)
                    .font(themeStore.uiFont(.subheadline, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isAvailable ? tokens.primaryText : tokens.tertiaryText)

                // 两行都带副标题，行高才是齐的；不可用时提示可点击重试。
                Text(
                    isAvailable
                        ? choice.listSubtitle
                        : L10n.text("ui.runtime_retry_hint")
                )
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.tertiaryText)
                .lineLimit(2)
            }

            Spacer(minLength: 12)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.accentText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        // 副标题让内容本身超过 44pt；固定 52pt 保证两行等高，勾选切换时不会抖。
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}
