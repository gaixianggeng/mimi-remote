import SwiftUI

/// 设置首页只使用这一套尺寸基线，避免 NavigationLink、Picker、Toggle 和自定义摘要
/// 各自决定行高与图标尺寸，导致真机滚动时出现不一致的视觉节奏。
enum SettingsLayoutMetrics {
    static let standardRowHeight: CGFloat = 52
    static let accessibilityRowHeight: CGFloat = 76
    static let rowHorizontalInset: CGFloat = 16
    static let iconSlot: CGFloat = 28
    static let symbolPointSize: CGFloat = 18
    static let sectionSpacing: CGFloat = 24
    static let statusModuleCornerRadius = WorkbenchPageLayout.contentPanelCornerRadius
}

enum TokenCountFormatter {
    static func string(_ value: Int64?, language: AppLanguage = .stored()) -> String {
        guard let value else { return "—" }
        let isChinese = language == .simplifiedChinese
            || (language == .system && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
        if isChinese {
            if value >= 100_000_000 {
                return compact(Double(value) / 100_000_000)
                    + L10n.text(
                        "ui.compact_number_hundred_million_suffix",
                        language: .simplifiedChinese
                    )
            }
            if value >= 10_000 {
                return compact(Double(value) / 10_000)
                    + L10n.text(
                        "ui.compact_number_ten_thousand_suffix",
                        language: .simplifiedChinese
                    )
            }
            return decimal(value, locale: Locale(identifier: "zh-Hans"))
        }
        if value >= 1_000_000_000 {
            return compact(Double(value) / 1_000_000_000) + "B"
        }
        if value >= 1_000_000 {
            return compact(Double(value) / 1_000_000) + "M"
        }
        if value >= 1_000 {
            return compact(Double(value) / 1_000) + "K"
        }
        return decimal(value, locale: Locale(identifier: "en"))
    }

    private static func compact(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded() == rounded
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    private static func decimal(_ value: Int64, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

private extension View {
    func settingsStandardListRow() -> some View {
        listRowInsets(
            EdgeInsets(
                top: 0,
                leading: SettingsLayoutMetrics.rowHorizontalInset,
                bottom: 0,
                trailing: SettingsLayoutMetrics.rowHorizontalInset
            )
        )
    }

}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.themeSystemColorScheme) private var themeSystemColorScheme
    @Environment(\.workbenchBottomChromeClearance) private var bottomChromeClearance
    @Environment(\.workbenchHasCompactTabBar) private var hasCompactTabBar
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    let isInitialSetup: Bool
    var showsDoneButton = true
    var embedsNavigationStack = true

    @AppStorage("agentd.developerMode") private var developerModeEnabled = false
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(VoiceInputProvider.storageKey) private var voiceInputProviderRawValue = VoiceInputProvider.codex.rawValue
    @AppStorage(ComposerPermissionMode.defaultStorageKey) private var defaultPermissionModeID = ComposerPermissionMode.defaultMode.rawValue
    @StateObject private var qrScannerPresentation = ConnectionQRCodeScannerPresentation()
    @State private var profileRenamePresentation = ConnectionProfileRenamePresentationState()
    @State private var didApplyDebugLaunchRoute = false
    @State private var showsConnectionManagement = false

    var body: some View {
        let systemColorScheme = themeSystemColorScheme ?? colorScheme
        let resolvedColorScheme = themeStore.resolvedColorScheme(for: systemColorScheme)
        let tokens = themeStore.tokens(for: systemColorScheme)

        Group {
            if embedsNavigationStack {
                NavigationStack {
                    settingsContent(tokens: tokens, resolvedColorScheme: resolvedColorScheme)
                }
            } else {
                settingsContent(tokens: tokens, resolvedColorScheme: resolvedColorScheme)
            }
        }
        // 扫码 Cover 固定挂在 SettingsView 根层。首次系统相机权限弹窗会触发 Form
        // 重建，但不会再销毁负责呈现相机的宿主。
        .fullScreenCover(
            item: $qrScannerPresentation.intent,
            onDismiss: qrScannerPresentation.didDismiss
        ) { intent in
            QRCodeScannerSheet(
                onDismiss: qrScannerPresentation.dismiss,
                onChooseManualConnection: {
                    qrScannerPresentation.chooseManualConnection(for: intent)
                },
                onCode: { rawValue in
                    await qrScannerPresentation.submit(rawValue, intent: intent)
                }
            )
        }
        // 重命名路由固定由设置根层持有，Form.Section 刷新不会销毁唯一的 sheet presenter。
        .sheet(
            item: profileRenameRouteBinding,
            onDismiss: { profileRenamePresentation.dismiss() }
        ) { route in
            ConnectionProfileRenameSheet(route: route) { displayName in
                try appStore.renameConnectionProfile(id: route.profileID, displayName: displayName)
            }
        }
        .onAppear(perform: applyDebugLaunchRouteIfNeeded)
    }

    @ViewBuilder
    private func settingsContent(tokens: ThemeTokens, resolvedColorScheme: ColorScheme) -> some View {
        Group {
            if isInitialSetup {
                InitialPairingView(
                    qrScannerPresentation: qrScannerPresentation,
                    onRequestProfileRename: { profileRenamePresentation.present($0) }
                )
            } else {
                settingsForm(tokens: tokens)
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity)
                    .background(tokens.background.ignoresSafeArea())
            }
        }
        // 首配流程需要标题说明「要做什么」；进到「我的」之后，Tab 标签已经写着「我的」，
        // 顶部再来一个同名大标题只是白占一屏高度。
        .navigationTitle(isInitialSetup ? L10n.text("ui.connect_your_mac") : "")
        .navigationBarTitleDisplayMode(isInitialSetup ? initialNavigationTitleDisplayMode : .inline)
        .navigationDestination(isPresented: $showsConnectionManagement) {
            ConnectionManagementView(
                qrScannerPresentation: qrScannerPresentation,
                onRequestProfileRename: { profileRenamePresentation.present($0) }
            )
        }
        .toolbar {
            if !isInitialSetup && showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.complete")) {
                        dismiss()
                    }
                    .accessibilityLabel(L10n.text("ui.close_settings"))
                    .accessibilityIdentifier("settings.close")
                }
            }
        }
        .tint(tokens.accent)
        // 设置页既可作为 sheet 自持 NavigationStack，也可嵌入紧凑 Tab 的 NavigationStack。
        .preferredColorScheme(resolvedColorScheme)
        .environment(\.colorScheme, resolvedColorScheme)
    }

    private var initialNavigationTitleDisplayMode: NavigationBarItem.TitleDisplayMode {
        // iPhone 的一级“我的”保留系统大标题；iPad detail 使用紧凑标题，避免与居中内容断裂。
        horizontalSizeClass == .compact ? .large : .inline
    }

    private func applyDebugLaunchRouteIfNeeded() {
#if DEBUG
        guard !didApplyDebugLaunchRoute else { return }
        didApplyDebugLaunchRoute = true

        // App Store 截图需要直接到达 Mac 连接页，避免依赖屏幕尺寸与滚动位置做自动点击。
        // 仅 Debug 构建读取该参数，Release 与普通设置导航保持不变。
        if ProcessInfo.processInfo.arguments.contains("--debug-open-mac-connection") {
            showsConnectionManagement = true
        }
#endif
    }

    private var profileRenameRouteBinding: Binding<ConnectionProfileRenameRoute?> {
        Binding(
            get: { profileRenamePresentation.route },
            set: { route in
                // item-driven sheet 关闭时由 SwiftUI 写回 nil；新目标只允许经 present(_:) 进入。
                if route == nil {
                    profileRenamePresentation.dismiss()
                }
            }
        )
    }

    private func settingsForm(tokens: ThemeTokens) -> some View {
        let codexUsage = sessionStore.accountCodexUsageWindowsDisplay
        let claudeUsage = sessionStore.accountClaudeUsageWindowsDisplay

        return Form {
            Section {
                AccountTokenUsageCard(
                    codexDisplay: codexUsage,
                    claudeDisplay: claudeUsage,
                    includesClaude: sessionStore.hasClaudeRuntimeChannel,
                    snapshot: sessionStore.accountTokenUsage,
                    activity: sessionStore.accountTokenActivity,
                    // 刷新按钮代表整卡刷新，配额或活动任一在飞都转；
                    // 活动面板的状态只看 activity 自己，不受配额刷新影响。
                    isRefreshing: sessionStore.isRefreshingAccountTokenActivity
                        || sessionStore.isRefreshingUsage(runtimeProvider: "codex")
                        || (
                            sessionStore.hasClaudeRuntimeChannel
                                && sessionStore.isRefreshingUsage(runtimeProvider: "claude")
                        ),
                    onRefresh: refreshAccountUsage
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("settings.tokenUsage")
            } header: {
                // 四个分组都带标题，页面语法才一致。顶部两块原先没有标题，
                // 读起来就是一坨没有标签的大块，底部却是分好组的列表。
                // 累计值和刷新按钮挂在这一行，卡片里就不必再留一层标题。
                HStack(alignment: .center, spacing: 8) {
                    sectionHeader(L10n.text("ui.token_usage"), tokens: tokens)

                    // 宽屏把累计值推到最右、和刷新按钮成组；窄屏这样会在标题和累计值之间
                    // 撑出一大片空，所以让它紧跟标题，Spacer 留到刷新按钮之前。
                    if horizontalSizeClass == .compact {
                        lifetimeTokenLabel(tokens: tokens)
                        Spacer(minLength: 8)
                    } else {
                        Spacer(minLength: 8)
                        lifetimeTokenLabel(tokens: tokens)
                    }

                    AccountUsageRefreshButton(
                        isRefreshing: sessionStore.isRefreshingAccountTokenActivity
                            || sessionStore.isRefreshingUsage(runtimeProvider: "codex")
                            || (
                                sessionStore.hasClaudeRuntimeChannel
                                    && sessionStore.isRefreshingUsage(runtimeProvider: "claude")
                            ),
                        onRefresh: refreshAccountUsage
                    )
                }
            }

            // Mac 连接紧随额度：断线时这张卡会自己变警示态，排在第二屏位置仍然一眼可见，
            // 不必为此把最常看的额度挤下去。
            Section {
                Button {
                    showsConnectionManagement = true
                } label: {
                    SettingsConnectionCard(
                        deviceName: currentMacDisplayName,
                        status: compactConnectionStatusText,
                        savedDeviceCount: appStore.connectionProfileSettingsModel.savedCount,
                        statusTint: connectionStatusTone(tokens: tokens),
                        warningText: connectionWarningText
                    )
                }
                // 用 Button 而不是 NavigationLink：卡片自己画了箭头，
                // NavigationLink 会再叠一个系统 disclosure，右侧就成了两个箭头。
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("settings.connectionManagement")
            } header: {
                sectionHeader(L10n.text("ui.mac_devices"), tokens: tokens)
            }

            Section {
                NavigationLink {
                    AppearanceView(profileID: appStore.activeHostScope.profileID)
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.personalization"),
                        value: themeStore.mode.title,
                        systemImage: "circle.lefthalf.filled",
                        symbolPointSize: 16
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.appearance")

                NavigationLink {
                    LanguageSettingsView(
                        appLanguageRawValue: $appLanguageRawValue,
                        voiceInputProviderRawValue: $voiceInputProviderRawValue
                    )
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.language"),
                        value: languageSettingsSummary,
                        systemImage: "globe"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.language")

                NavigationLink {
                    DefaultModelSettingsView()
                } label: {
                    // 两个 runtime 的模型 + 档位拼在一行会被截断成一串噪音，
                    // 详情页已经把它们平铺开了，这里只做入口。
                    SettingsValueLabel(
                        title: L10n.text("ui.default_model"),
                        systemImage: "cpu"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.defaultModels")

                // 四个模式各自有 detail，而且是安全相关的选择：值得整页逐条读完再选。
                SettingsChoiceRow(
                    title: L10n.text("ui.default_permissions"),
                    systemImage: "lock.shield",
                    options: ComposerPermissionMode.allCases,
                    selection: defaultPermissionModeSelection,
                    presentation: .page
                )
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.defaultPermissions")
            } header: {
                sectionHeader(L10n.text("ui.my_preferences"), tokens: tokens)
            }

            Section {
                NavigationLink {
                    ExperimentalFeaturesSettingsView()
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.experimental_features"),
                        value: L10n.text("ui.enable_on_mac"),
                        systemImage: "flask"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.experimentalFeatures")

                NavigationLink {
                    DiagnosticsAndSupportSettingsView(
                        showsHistoryDiagnostics: developerModeEnabled
                    )
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.diagnosis_and_support"),
                        systemImage: "stethoscope"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.diagnostics")

                NavigationLink {
                    AdvancedDevelopmentSettingsView(
                        developerModeEnabled: $developerModeEnabled
                    )
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.advanced_and_development"),
                        systemImage: "hammer"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.advancedDevelopment")

                NavigationLink {
                    AboutAndLegalSettingsView()
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.about_and_legal"),
                        systemImage: "info.circle"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.aboutLegal")
            } header: {
                sectionHeader(L10n.text("ui.more"), tokens: tokens)
            }
        }
        // 分组之间靠留白划分，行本身不再套在圆角白卡里。
        .listSectionSpacing(SettingsLayoutMetrics.sectionSpacing)
        .listRowBackground(Color.clear)
        .themedSettingsForm(tokens: tokens)
        // 紧凑 Tab 下允许内容经过玻璃栏，但最后一组必须能完整滚到栏上方。
        .contentMargins(
            .bottom,
            hasCompactTabBar ? bottomChromeClearance : WorkbenchPageLayout.regularPadding,
            for: .scrollContent
        )
        .task(id: appStore.activeHostScope) {
            // 设置页也作为失败后的自然重试入口；成功态会直接复用，不产生重复请求。
            guard !appStore.requiresRePairing else {
                return
            }
            let preflightSucceeded = await appStore.preflightConnection()
            let hasConnectedStatus: Bool
            if case .connected = appStore.connectionStatus {
                hasConnectedStatus = true
            } else {
                hasConnectedStatus = false
            }
            guard (preflightSucceeded || hasConnectedStatus), appStore.isConfigured else {
                return
            }
            // 完整连接测速可能持续数秒。账号概览与它并行刷新，Token 活动才能及时命中
            // agentd 的最近快照，不再长时间停留在“刷新后显示”的 idle 状态。
            async let connectionTest: Bool = appStore.testConnectionOnFirstSettingsAppearanceIfNeeded()
            async let accountOverview: Void = sessionStore.refreshSettingsAccountOverview()
            _ = await (connectionTest, accountOverview)
            let hasNotLoadedInitialData = sessionStore.projects.isEmpty
                && sessionStore.statusMessage == nil
            guard sessionStore.errorMessage != nil || hasNotLoadedInitialData else {
                return
            }
            // 45 秒首配超时后凭据已经安全落盘；用户打开设置即用健康连接做一次短恢复，
            // 不要求重新扫码，也不在已有首屏数据的正常连接上额外刷新。
            _ = await sessionStore.refreshAfterConnectionCommit(maxWait: 10)
        }
    }

    /// 累计值未知时整行不出现。渲染成 `累计 Token · —` 会被读成「累计是 0」。
    @ViewBuilder
    private func lifetimeTokenLabel(tokens: ThemeTokens) -> some View {
        if let lifetimeTokens = sessionStore.accountTokenUsage?.summary.lifetimeTokens {
            Text(
                L10n.format(
                    "ui.lifetime_token_value",
                    TokenCountFormatter.string(lifetimeTokens)
                )
            )
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(tokens.secondaryText)
            .lineLimit(1)
        }
    }

    /// 系统默认会把分组标题转成全大写并用最小字号，和页面其余部分不是一套排版。
    private func sectionHeader(_ title: String, tokens: ThemeTokens) -> some View {
        Text(title)
            .font(themeStore.uiFont(.footnote, weight: .medium))
            .foregroundStyle(tokens.secondaryText)
            .textCase(nil)
    }

    private func refreshAccountUsage() async {
        async let codexQuota: Void = sessionStore.refreshCodexUsage()
        async let tokenActivity: Void = sessionStore.refreshAccountTokenUsage(forceRefresh: true)
        if sessionStore.hasClaudeRuntimeChannel {
            await sessionStore.refreshClaudeUsage()
        }
        _ = await (codexQuota, tokenActivity)
    }

    private var compactConnectionStatusText: String {
        if let termination = appStore.connectionTermination {
            return termination.title
        }
        if sessionStore.isNetworkUnavailable {
            return L10n.text("ui.network_is_unavailable")
        }
        if case .connected = appStore.connectionStatus {
            return L10n.text("ui.connected")
        }
        return appStore.connectionStatus.title
    }

    private var connectionWarningText: String? {
        if let termination = appStore.connectionTermination {
            return termination.message
        }
        if sessionStore.isNetworkUnavailable {
            return L10n.text("ui.the_network_is_unavailable_and_synchronization_has_been")
        }
        return nil
    }

    private func connectionStatusTone(tokens: ThemeTokens) -> Color {
        if appStore.connectionTermination != nil || sessionStore.isNetworkUnavailable {
            return tokens.warning
        }
        switch appStore.connectionStatus {
        case .connected:
            return tokens.success
        case .testing:
            return tokens.accent
        case .failed:
            return tokens.warning
        case .idle:
            return tokens.secondaryText
        }
    }

    private var currentMacDisplayName: String {
        appStore.connectionProfileSettingsModel.current?.profile.displayName
            ?? L10n.text("ui.current_mac")
    }

    private var appLanguageSelection: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRawValue) ?? .system },
            set: { appLanguageRawValue = $0.rawValue }
        )
    }

    private var voiceInputProviderSelection: Binding<VoiceInputProvider> {
        Binding(
            get: {
                VoiceInputProvider.resolved(rawValue: voiceInputProviderRawValue)
            },
            set: { voiceInputProviderRawValue = $0.rawValue }
        )
    }

    private var languageSettingsSummary: String {
        L10n.format(
            "ui.language_settings_summary",
            appLanguageSelection.wrappedValue.displayName,
            voiceInputProviderSelection.wrappedValue.title
        )
    }

    private var defaultPermissionModeSelection: Binding<ComposerPermissionMode> {
        Binding(
            get: { ComposerPermissionMode.stored(defaultPermissionModeID) },
            set: { defaultPermissionModeID = $0.rawValue }
        )
    }
}

struct SettingsValueLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var themeStore: ThemeStore

    let title: String
    var value: String? = nil
    let systemImage: String
    var valueTint: Color? = nil
    var symbolPointSize: CGFloat = SettingsLayoutMetrics.symbolPointSize

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: symbolPointSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.secondaryText)
                .frame(
                    width: SettingsLayoutMetrics.iconSlot,
                    height: SettingsLayoutMetrics.iconSlot
                )
                .accessibilityHidden(true)

            if dynamicTypeSize.isAccessibilitySize, let value {
                VStack(alignment: .leading, spacing: 2) {
                    titleText(tokens: tokens)
                    valueText(value, tokens: tokens)
                }
            } else if let value {
                HStack(alignment: .center, spacing: 12) {
                    titleText(tokens: tokens)
                    Spacer(minLength: 12)
                    valueText(value, tokens: tokens)
                }
            } else {
                titleText(tokens: tokens)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: rowHeight,
            maxHeight: rowHeight,
            alignment: .leading
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func titleText(tokens: ThemeTokens) -> some View {
        Text(title)
            .font(themeStore.uiFont(.body))
            .foregroundStyle(tokens.primaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .layoutPriority(1)
    }

    private func valueText(_ value: String, tokens: ThemeTokens) -> some View {
        Text(value)
            .font(themeStore.uiFont(.subheadline))
            .monospacedDigit()
            .foregroundStyle(valueTint ?? tokens.secondaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .minimumScaleFactor(0.82)
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
    }

    private var rowHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize
            ? SettingsLayoutMetrics.accessibilityRowHeight
            : SettingsLayoutMetrics.standardRowHeight
    }
}

private struct ConnectionManagementView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    let onRequestProfileRename: (ConnectionProfile) -> Void

    var body: some View {
        Form {
            InitialConnectionSettingsSections(
                qrScannerPresentation: qrScannerPresentation,
                onRequestProfileRename: onRequestProfileRename
            )
        }
        .themedSettingsForm(tokens: themeStore.tokens(for: colorScheme))
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(themeStore.tokens(for: colorScheme).background.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.mac_connection"))
    }
}

private struct ConnectionSpeedTestView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(resultTone(tokens: tokens).opacity(0.14))
                        Image(systemName: resultSystemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(resultTone(tokens: tokens))
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(resultTitle)
                            .font(themeStore.uiFont(.headline, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                        Text(appStore.endpoint)
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    if let milliseconds = appStore.lastConnectionTestDurationMillis {
                        Text(AppStore.connectionTestDurationText(milliseconds: milliseconds))
                            .font(themeStore.uiFont(.callout, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(resultTone(tokens: tokens))
                            .lineLimit(1)
                    }
                }

                Button {
                    Task {
                        await appStore.testConnection(
                            endpoint: appStore.endpoint,
                            token: appStore.token
                        )
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "bolt.horizontal.circle")
                        }
                        Text(isTesting ? L10n.text("ui.testing_speed") : appStore.lastConnectionTestReport == nil ? L10n.text("ui.start_speed_test") : L10n.text("ui.retest_speed"))
                    }
                    .font(themeStore.uiFont(.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRunTest)
                .accessibilityIdentifier("settings.connectionSpeedTest.run")
            } header: {
                Text(L10n.text("ui.current_connection"))
            } footer: {
                Text(canRunTest || isTesting ? L10n.text("ui.check_iphone_ipad_to_mac_assistant_authentication_gateway") : L10n.text("ui.there_are_currently_no_connection_credentials_available_please"))
            }

            if let report = appStore.lastConnectionTestReport {
                Section(L10n.text("ui.speed_test_results")) {
                    connectionSpeedResultSummary(report: report, tokens: tokens)
                        // 把结果概览作为一个内容自适应的 Form 行，避免系统 LabeledContent
                        // 在部分 iOS 26/27 布局中把最后一行拉伸到整屏高度。
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }

                Section(L10n.text("ui.segmentation_takes_time")) {
                    ForEach(report.stages) { stage in
                        ConnectionSpeedTestStageRow(stage: stage)
                    }
                }

                if let diagnostics = report.gatewayDiagnostics {
                    Section(L10n.text("ui.gateway_observation")) {
                        if let connection = diagnostics.relatedConnection {
                            ConnectionSpeedMetricRow(
                                title: L10n.text("ui.mac_upstream_dialing"),
                                value: AppStore.connectionTestDurationText(milliseconds: connection.upstreamDialMillis)
                            )
                        }
                        if let rpc = diagnostics.latestRPC {
                            ConnectionSpeedMetricRow(
                                title: L10n.text("ui.recent_rpcs"),
                                value: AppStore.connectionTestDurationText(milliseconds: rpc.latencyMillis)
                            )
                        }
                        if diagnostics.writeBackMillisMax > 0 {
                            ConnectionSpeedMetricRow(
                                title: L10n.text("ui.write_back_to_device"),
                                value: AppStore.connectionTestDurationText(milliseconds: diagnostics.writeBackMillisMax)
                            )
                        }
                    }
                }
            }
        }
        .themedSettingsForm(tokens: tokens)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.connection_speed_test"))
        .tint(tokens.accent)
    }

    private func connectionSpeedResultSummary(
        report: ConnectionTestReport,
        tokens: ThemeTokens
    ) -> some View {
        VStack(spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        connectionSpeedTotalMetric(report: report, tokens: tokens)
                        Divider()
                            .overlay(tokens.border.opacity(0.72))
                        connectionSpeedBottleneckMetric(report: report, tokens: tokens)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        connectionSpeedTotalMetric(report: report, tokens: tokens)

                        Divider()
                            .overlay(tokens.border.opacity(0.72))
                            .frame(height: 68)

                        connectionSpeedBottleneckMetric(report: report, tokens: tokens)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)

            Divider()
                .overlay(tokens.border.opacity(0.72))

            connectionSpeedResultDetailRow(
                title: L10n.text("ui.test_time"),
                tokens: tokens
            ) {
                Text(report.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(tokens.secondaryText)
            }

            if let networkPath = report.tailscaleNetworkPath {
                Divider()
                    .overlay(tokens.border.opacity(0.72))
                    .padding(.leading, 16)

                connectionSpeedResultDetailRow(
                    title: L10n.text("ui.tailscale_network_path"),
                    tokens: tokens
                ) {
                    connectionSpeedNetworkPathBadge(
                        networkPath: networkPath,
                        tokens: tokens
                    )
                }
            }
        }
        .background(tokens.surface)
    }

    private func connectionSpeedTotalMetric(
        report: ConnectionTestReport,
        tokens: ThemeTokens
    ) -> some View {
        connectionSpeedHighlightMetric(
            title: L10n.text("ui.total_time_spent"),
            systemImage: "timer",
            value: AppStore.connectionTestDurationText(milliseconds: report.totalMillis),
            detail: nil,
            tone: resultTone(tokens: tokens),
            tokens: tokens
        )
    }

    @ViewBuilder
    private func connectionSpeedBottleneckMetric(
        report: ConnectionTestReport,
        tokens: ThemeTokens
    ) -> some View {
        if let failedStage = report.failedStage {
            connectionSpeedHighlightMetric(
                title: L10n.text("ui.failure_link"),
                systemImage: "exclamationmark.triangle.fill",
                value: failedStage.kind.title,
                detail: AppStore.connectionTestDurationText(milliseconds: failedStage.durationMillis),
                tone: tokens.warning,
                tokens: tokens
            )
        } else if let slowestStage = report.slowestStage {
            connectionSpeedHighlightMetric(
                title: L10n.text("ui.slowest_link"),
                systemImage: "gauge.with.dots.needle.67percent",
                value: AppStore.connectionTestDurationText(milliseconds: slowestStage.durationMillis),
                detail: slowestStage.kind.title,
                tone: tokens.warning,
                tokens: tokens
            )
        }
    }

    private func connectionSpeedHighlightMetric(
        title: String,
        systemImage: String,
        value: String,
        detail: String?,
        tone: Color,
        tokens: ThemeTokens
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)

            Text(value)
                .font(themeStore.uiFont(.title3, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)

            if let detail {
                Text(detail)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func connectionSpeedResultDetailRow<Value: View>(
        title: String,
        tokens: ThemeTokens,
        @ViewBuilder value: () -> Value
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 12)

                value()
                    .font(themeStore.uiFont(.callout))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: true, vertical: false)
            }

            // 窄屏或大字号时让右侧状态整体换到下一行，避免状态文字被挤成逐字换行。
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.primaryText)

                value()
                    .font(themeStore.uiFont(.callout))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func connectionSpeedNetworkPathBadge(
        networkPath: TailscaleNetworkPathResponse,
        tokens: ThemeTokens
    ) -> some View {
        let tone = tailscaleNetworkPathTone(networkPath.kind, tokens: tokens)

        return HStack(spacing: 6) {
            Image(systemName: networkPath.kind.settingsSystemImage)
                .font(.system(size: 13, weight: .semibold))

            Text(networkPath.localizedSummary)
                .font(themeStore.uiFont(.footnote, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tone.opacity(0.11), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tone.opacity(0.18), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var isTesting: Bool {
        if case .testing = appStore.connectionStatus {
            return true
        }
        return false
    }

    private var canRunTest: Bool {
        appStore.isConfigured
            && !isTesting
            && !appStore.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appStore.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resultTitle: String {
        if isTesting {
            return L10n.text("ui.testing_full_link")
        }
        if appStore.lastConnectionTestReport?.failedStage != nil {
            return L10n.text("ui.connection_test_failed")
        }
        if appStore.lastConnectionTestReport != nil {
            return L10n.text("ui.the_connection_link_is_normal")
        }
        return appStore.isConfigured ? L10n.text("ui.you_can_start_speed_measurement") : L10n.text("ui.not_connected_to_mac_yet")
    }

    private var resultSystemImage: String {
        if isTesting {
            return "timer"
        }
        if appStore.lastConnectionTestReport?.failedStage != nil {
            return "exclamationmark.triangle.fill"
        }
        if appStore.lastConnectionTestReport != nil {
            return "checkmark.circle.fill"
        }
        return "speedometer"
    }

    private func resultTone(tokens: ThemeTokens) -> Color {
        if isTesting {
            return tokens.accent
        }
        if appStore.lastConnectionTestReport?.failedStage != nil {
            return tokens.warning
        }
        return appStore.lastConnectionTestReport == nil ? tokens.secondaryText : tokens.success
    }

    private func tailscaleNetworkPathTone(
        _ kind: TailscaleNetworkPathResponse.Kind,
        tokens: ThemeTokens
    ) -> Color {
        switch kind {
        case .direct:
            return tokens.success
        case .peerRelay, .derp:
            return tokens.warning
        case .notTailscale, .unknown, .unavailable:
            return tokens.secondaryText
        }
    }
}

extension TailscaleNetworkPathResponse {
    var localizedSummary: String {
        switch kind {
        case .direct:
            return L10n.text("ui.tailscale_path_direct")
        case .peerRelay:
            return L10n.text("ui.tailscale_path_peer_relay")
        case .derp:
            let title = L10n.text("ui.tailscale_path_derp")
            guard let relayRegion,
                  !relayRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return title
            }
            return "\(title) · \(relayRegion.uppercased())"
        case .notTailscale:
            return L10n.text("ui.tailscale_path_not_tailscale")
        case .unknown:
            return L10n.text("ui.tailscale_path_unknown")
        case .unavailable:
            return L10n.text("ui.tailscale_path_unavailable")
        }
    }
}

extension TailscaleNetworkPathResponse.Kind {
    var settingsSystemImage: String {
        switch self {
        case .direct:
            return "bolt.horizontal.circle.fill"
        case .peerRelay:
            return "arrow.left.arrow.right.circle"
        case .derp:
            return "network"
        case .notTailscale:
            return "wifi"
        case .unknown, .unavailable:
            return "questionmark.circle"
        }
    }
}

private struct ConnectionSpeedTestStageRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let stage: ConnectionTestStageTiming

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: stage.status.isFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(stage.status.isFailed ? tokens.warning : tokens.success)

            VStack(alignment: .leading, spacing: 2) {
                Text(stage.kind.title)
                    .foregroundStyle(tokens.primaryText)
                Text(stage.kind.detail)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(AppStore.connectionTestDurationText(milliseconds: stage.durationMillis))
                .font(themeStore.uiFont(.callout, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(stage.status.isFailed ? tokens.warning : tokens.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("ui.connection_test_stage_accessibility", stage.kind.title, stage.status.isFailed ? L10n.text("ui.failed_status") : L10n.text("ui.success")))
        .accessibilityValue(AppStore.connectionTestDurationText(milliseconds: stage.durationMillis))
    }
}

private struct ConnectionSpeedMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
        }
    }
}

/// 视觉基线按状态逐个录制，因此对测试可见；页面之外没有其他调用方。
struct AccountTokenUsageCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var themeStore: ThemeStore

    let codexDisplay: CodexUsageWindowsDisplay
    let claudeDisplay: CodexUsageWindowsDisplay
    let includesClaude: Bool
    let snapshot: AccountTokenUsageSnapshot?
    let activity: AccountTokenActivityState
    let isRefreshing: Bool
    let onRefresh: () async -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ViewThatFits(in: .horizontal) {
            // 只有一个窗口时配额那栏只是一条进度条，撑不起 252pt 的左栏、下方会空出一片；
            // 这种情况无论屏幕多宽都用上下排。
            if !dynamicTypeSize.isAccessibilitySize, singleUsageItem == nil {
                wideLayout(tokens: tokens)
                    .frame(minWidth: 620)
            }
            stackedLayout(tokens: tokens)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            tokens.surface,
            in: RoundedRectangle(
                cornerRadius: SettingsLayoutMetrics.statusModuleCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: SettingsLayoutMetrics.statusModuleCornerRadius,
                style: .continuous
            )
            .stroke(tokens.border.opacity(0.48), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func wideLayout(tokens: ThemeTokens) -> some View {
        // 156pt 的最小高度会比左右内容多出一段空间；居中分配这段空间，
        // 避免所有内容贴近卡片上缘、只在底部留下明显空白。
        HStack(alignment: .center, spacing: 20) {
            quotaPanel(tokens: tokens, ringDiameter: 100)
                .frame(width: 252)

            Divider()
                .overlay(tokens.border.opacity(0.72))
                // 分隔线跟着较高的一侧拉长时，尾段会悬在另一侧内容之外。
                .frame(maxHeight: 132)

            // 右侧格子按左栏高度放大，不再固定 86pt 而在下方空出一块。
            activityPanel(tokens: tokens, gridHeight: 132)
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 156)
    }

    /// 窄屏不再左右各占一半。点格图本来就是横向的，宽度给足才成立；
    /// 配额那半也终于放得下环形图和完整图例，不用再挤成两列。
    private func stackedLayout(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            quotaPanel(tokens: tokens, ringDiameter: 84)
            // 上下排在 iPad 上也会用到（单窗口时强制走这条），宽屏要给点格图更大的高度，
            // 否则一条进度条上面很轻、下面 86pt 的网格撑不住整张卡。
            activityPanel(
                tokens: tokens,
                gridHeight: horizontalSizeClass == .compact
                    ? TokenActivityGridMetrics.totalHeight
                    : 150
            )
        }
    }

    /// 卡片内不再有「当前剩余」「Token 活动」两个小标题：外层分组已经叫「Token 使用量」，
    /// 中间那层是重复的层级；而且一边带 44pt 刷新按钮、一边只有文字，两行基线永远对不齐。
    /// 图形本身自解释，文字标签改由 accessibilityLabel 承担。
    private func quotaPanel(tokens: ThemeTokens, ringDiameter: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let onlyItem = singleUsageItem {
                singleWindowBar(item: onlyItem, tokens: tokens)
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    usageRings(tokens: tokens, diameter: 92)
                    usageLegend(tokens: tokens)
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    usageRings(tokens: tokens, diameter: ringDiameter)
                    usageLegend(tokens: tokens)
                }
            }
        }
        .accessibilityIdentifier("settings.tokenUsage.quota")
    }

    /// 只接了一个 runtime（例如没有 Claude 通道）时，三环退化成一条进度条。
    private var singleUsageItem: CombinedUsageItem? {
        let items = usageItems
        return items.count == 1 ? items[0] : nil
    }

    private func usageRings(tokens: ThemeTokens, diameter: CGFloat) -> some View {
        VStack(spacing: 6) {
            ZStack {
                CombinedUsageRingsGraphic(
                    items: usageItems,
                    expectedRingCount: 3,
                    diameter: diameter,
                    lineWidth: Self.ringLineWidth,
                    ringSpacing: Self.ringSpacing
                )

                // 三个百分比平权并列时，用户看不出哪个窗口先耗尽。环心只放最紧张的那个，
                // 明细仍由右侧图例给出。无障碍字号下环心装不下，改由图例独自承担。
                //
                // 环心不再重复写出窗口名：最短的那条弧本身就指明了是哪个窗口，
                // 再写一遍 provider · window 会让同一条信息在卡片上出现第三次。
                // 数字用正文色而不是该窗口的 tint——tint 是为环形轨道挑的，
                // 放到浅色底上做文字达不到需要的对比度。
                if !dynamicTypeSize.isAccessibilitySize, let tightestItem {
                    Text(tightestItem.window.remainingPercentText ?? "—")
                        .font(themeStore.uiFont(.footnote, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: Self.ringInnerHoleDiameter(for: diameter))
                }
            }
            .frame(width: diameter, height: diameter)
        }
        // 环形和环心数字是同一条信息，拆成两个元素读会让 VoiceOver 念出无意义的裸数字。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.current_remaining"))
        .accessibilityValue(ringsAccessibilityValue)
    }

    private static let ringLineWidth: CGFloat = 6
    // 环间距直接决定环心可用宽度：8pt 时 84 直径只剩 22pt，放不下「17%」会被截成「1...」。
    private static let ringSpacing: CGFloat = 6

    /// 三环由外到内每层缩小 (lineWidth + ringSpacing) * 2；环心可用宽度是最内环再去掉一个线宽。
    private static func ringInnerHoleDiameter(for diameter: CGFloat) -> CGFloat {
        let step = (ringLineWidth + ringSpacing) * 2
        return max(diameter - step * 2 - ringLineWidth, 24)
    }

    /// 剩余比例最低的窗口，也就是最先耗尽的那个。没有可用进度时不猜。
    private var tightestItem: CombinedUsageItem? {
        usageItems
            .filter { $0.window.remainingProgress != nil }
            .min { ($0.window.remainingProgress ?? 1) < ($1.window.remainingProgress ?? 1) }
    }

    private var ringsAccessibilityValue: String {
        let items = usageItems
        guard !items.isEmpty else {
            return L10n.text("ui.token_activity_waiting")
        }
        return items
            .map { "\($0.providerName) \($0.window.label) \($0.window.remainingPercentText ?? "—")" }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private func usageLegend(tokens: ThemeTokens) -> some View {
        let items = usageItems

        if items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(codexDisplay.creditText)
                if includesClaude {
                    Text(claudeDisplay.creditText)
                }
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(tokens.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // 一行还是两行必须整组一起决定。让每项各自 ViewThatFits 会出现
            // 「第一项一行、第二项两行、第三项又一行」的锯齿，看着就是乱换行。
            ViewThatFits(in: .horizontal) {
                if !dynamicTypeSize.isAccessibilitySize {
                    legendStack(items: items, tokens: tokens, usesSingleLine: true)
                }
                legendStack(items: items, tokens: tokens, usesSingleLine: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendStack(
        items: [CombinedUsageItem],
        tokens: ThemeTokens,
        usesSingleLine: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: usesSingleLine ? 7 : 10) {
            ForEach(items) { item in
                HStack(spacing: 7) {
                    Circle()
                        .fill(item.tint)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)

                    legendItemContent(
                        item: item,
                        tokens: tokens,
                        usesSingleLine: usesSingleLine
                    )
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// 窄列(iPhone 环形右侧只有约 240pt)放不下三段，就把重置时间落到第二行；
    /// iPad 的图例列宽得多，一行就能同时给出窗口、重置时间和剩余比例。
    /// 固定成两行会让 iPad 显得拥挤，固定成一行则会在 iPhone 上被压扁。
    @ViewBuilder
    private func legendItemContent(
        item: CombinedUsageItem,
        tokens: ThemeTokens,
        usesSingleLine: Bool
    ) -> some View {
        let name = Text("\(item.providerName) · \(item.window.label)")
            .font(themeStore.uiFont(.caption, weight: .medium))
            .foregroundStyle(tokens.primaryText)

        // 只有「还剩多少」而没有「什么时候回血」，用户没法判断要不要现在省着用。
        let reset = Text(item.window.resetText)
            .font(themeStore.uiFont(.caption2))
            .foregroundStyle(tokens.tertiaryText)

        let percent = Text(item.window.remainingPercentText ?? "—")
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(
                item.window.remainingProgress == nil ? tokens.secondaryText : item.tint
            )

        if usesSingleLine {
            HStack(spacing: 8) {
                name.lineLimit(1).fixedSize(horizontal: true, vertical: false)
                reset.lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                percent
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    name
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    percent
                }
                reset.lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    /// 只有一个窗口时三环里两条是空轨道，大半个圆是无意义的留白。
    /// 单窗口改用一条占满宽度的进度条，同样的信息密度换来更少的空白。
    private func singleWindowBar(item: CombinedUsageItem, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 窗口、重置时间和剩余比例挤在一行，配额区就只占两行；
            // 原先标题、进度条、重置各占一行，把整张卡压得头重脚轻。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(item.providerName) · \(item.window.label)")
                    .font(themeStore.uiFont(.subheadline, weight: .medium))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text(item.window.resetText)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.tertiaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(item.window.remainingPercentText ?? "—")
                    // 单窗口时这是卡片里唯一的数字，但不该大到压过下方点格图。
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tokens.primaryText)
            }

            GeometryReader { proxy in
                let progress = item.window.remainingProgress ?? 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(tokens.tertiaryText.opacity(0.18))

                    Capsule()
                        // 单窗口没有三环的颜色编码要对应，用主题强调色和下方点格图保持一套配色；
                        // item.tint 那套青/粉/紫只在多环并列、需要靠颜色区分窗口时才有意义。
                        .fill(tokens.accent)
                        .frame(width: max(proxy.size.width * progress, progress > 0 ? 6 : 0))
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1),
                            value: progress
                        )
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.current_remaining"))
        .accessibilityValue(ringsAccessibilityValue)
    }

    private func activityPanel(tokens: ThemeTokens, gridHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 主内容和占位文案都在同一个高度预算里测量；这样状态切换不会因某条
            // 本地化文案换行而改变卡片高度，同时不以固定高度裁掉 Dynamic Type 文本。
            activityBody(tokens: tokens, gridHeight: gridHeight)
            activityCaptionArea(tokens: tokens)
        }
        .accessibilityIdentifier("settings.tokenUsage.activity")
    }

    private func activityBody(tokens: ThemeTokens, gridHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            activityContent(tokens: tokens, gridHeight: gridHeight)

            // 占位态的最长本地化文案决定最小高度。隐藏测量视图仍参与布局，
            // 但完全从 VoiceOver 树移除；网格态也预留同样的空间，状态切换不会跳。
            ZStack {
                ForEach(
                    Array(activityPlaceholderCandidates.enumerated()),
                    id: \.offset
                ) { candidate in
                    HStack(spacing: 10) {
                        Color.clear
                            .frame(width: 18, height: 18)

                        Text(candidate.element)
                            .font(themeStore.uiFont(.caption))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .hidden()
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: gridHeight,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private func activityContent(tokens: ThemeTokens, gridHeight: CGFloat) -> some View {
        switch activity {
        case .loaded(let buckets, let asOf):
            activityGrid(
                buckets: buckets,
                endingAt: asOf,
                gridHeight: gridHeight
            )

        case .empty(let asOf):
            // 画成一整片未活动的格子，比一句话更能说明“接口是通的，只是还没有记录”。
            activityGrid(
                buckets: [],
                endingAt: asOf,
                gridHeight: gridHeight
            )

        case .failed(let previous):
            if let previous, !previous.buckets.isEmpty {
                activityGrid(
                    buckets: previous.buckets,
                    endingAt: previous.asOf,
                    gridHeight: gridHeight
                )
            } else {
                activityPlaceholder(tokens: tokens, gridHeight: gridHeight)
            }

        case .idle, .loading, .unsupported:
            activityPlaceholder(tokens: tokens, gridHeight: gridHeight)
        }
    }

    private func activityGrid(
        buckets: [AccountTokenUsageDailyBucket],
        endingAt: Date,
        gridHeight: CGFloat
    ) -> some View {
        TokenActivityDotGrid(
            buckets: buckets,
            endingAt: endingAt,
            height: gridHeight
        )
    }

    private func activityCaptionArea(tokens: ThemeTokens) -> some View {
        let caption = activityCaptionText

        return ZStack(alignment: .topLeading) {
            // 用真实 caption 字体测量全部候选本地化文案，取其中自然换行后的最大高度。
            // 不能用固定像素高度，否则放大文字或切换语言后会裁切。
            ForEach(
                Array(activityCaptionCandidates.enumerated()),
                id: \.offset
            ) { candidate in
                Text(candidate.element)
                    .font(themeStore.uiFont(.caption2))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .accessibilityHidden(true)
            }

            if let caption {
                Text(caption)
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(activityCaptionTint(tokens: tokens))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(activityCaptionIdentifier)
            } else {
                // loaded/loading/unsupported/failed(nil) 没有 caption，但必须保留相同布局空间；
                // 透明占位不能进入 VoiceOver，否则会多出一个空的可访问元素。
                Color.clear
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(caption == nil)
    }

    private var activityCaptionText: String? {
        switch activity {
        case .empty:
            return L10n.text("ui.token_activity_empty")
        case .failed(let previous):
            return previous?.buckets.isEmpty == false
                ? L10n.text("ui.token_activity_stale")
                : nil
        case .idle, .loading, .loaded, .unsupported:
            return nil
        }
    }

    private func activityCaptionTint(tokens: ThemeTokens) -> Color {
        if case .failed(let previous) = activity,
           previous?.buckets.isEmpty == false
        {
            return tokens.warning
        }
        return tokens.secondaryText
    }

    private var activityCaptionIdentifier: String {
        switch activity {
        case .empty:
            return "settings.tokenActivity.empty"
        case .failed:
            return "settings.tokenActivity.stale"
        case .idle, .loading, .loaded, .unsupported:
            return "settings.tokenActivity.caption"
        }
    }

    private var activityCaptionCandidates: [String] {
        [
            L10n.text("ui.token_activity_empty"),
            L10n.text("ui.token_activity_stale")
        ]
    }

    private var activityPlaceholderCandidates: [String] {
        [
            L10n.text("ui.loading_token_activity"),
            L10n.text("ui.token_activity_unavailable"),
            L10n.text("ui.token_activity_failed"),
            L10n.text("ui.token_activity_waiting")
        ]
    }

    /// 占位高度和真实点格图一致，状态之间切换时卡片不跳。
    private func activityPlaceholder(tokens: ThemeTokens, gridHeight: CGFloat) -> some View {
        HStack(spacing: 10) {
            if case .loading = activity {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: activityPlaceholderSymbol)
                    .foregroundStyle(
                        isActivityFailure ? tokens.warning : tokens.tertiaryText
                    )
            }
            Text(activityPlaceholderText)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: gridHeight,
            alignment: .center
        )
        .accessibilityIdentifier("settings.tokenActivity.unavailable")
    }

    private var isActivityFailure: Bool {
        if case .failed = activity { return true }
        return false
    }

    private var activityPlaceholderSymbol: String {
        isActivityFailure ? "exclamationmark.triangle" : "chart.dots.scatter"
    }

    private var activityPlaceholderText: String {
        switch activity {
        case .loading:
            return L10n.text("ui.loading_token_activity")
        case .unsupported:
            return L10n.text("ui.token_activity_unavailable")
        case .failed:
            return L10n.text("ui.token_activity_failed")
        case .idle, .empty, .loaded:
            // empty 与 loaded 都走点格图分支，不会落到占位。
            return L10n.text("ui.token_activity_waiting")
        }
    }

    /// 产品只需要 Codex 的长窗口，以及 Claude 的长、短两个窗口。
    /// 服务端的 primary/secondary 槽位并不稳定，因此按真实时长选择而不是写死槽位。
    private var usageItems: [CombinedUsageItem] {
        CombinedUsageItem.make(
            codexDisplay: codexDisplay,
            claudeDisplay: claudeDisplay,
            includesClaude: includesClaude,
            claudeShortTint: themeStore.tokens(for: colorScheme).accent
        )
    }
}

private struct AccountUsageRefreshButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let isRefreshing: Bool
    let onRefresh: () async -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Button {
            Task { await onRefresh() }
        } label: {
            Group {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 32, height: 32)
            .background(tokens.secondaryText.opacity(0.08), in: Circle())
            .overlay {
                Circle().stroke(tokens.border.opacity(0.72), lineWidth: 1)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .disabled(isRefreshing)
        .accessibilityLabel(
            isRefreshing
                ? L10n.format("ui.refreshing_value_usage", "Token")
                : L10n.format("ui.refresh_value_usage", "Token")
        )
        .accessibilityIdentifier("settings.tokenUsage.refresh")
    }
}

/// Mac 连接是全局、持续、且会失败的状态，过去却被当成普通设置项埋在
/// 「更多」组里，断线提示还挂在整组的 footer——显示在「关于与法律」下面，
/// 离设备行隔了三行，等于用户最需要看到它的时候最看不到。
/// 这里把它提到首屏与 Token 卡片同级：正常时安静，异常时卡片自己变警示态。
struct SettingsConnectionCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var themeStore: ThemeStore

    let deviceName: String
    let status: String
    let savedDeviceCount: Int
    let statusTint: Color
    let warningText: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let hasWarning = warningText != nil

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 20, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(hasWarning ? tokens.warning : tokens.secondaryText)
                    .frame(width: SettingsLayoutMetrics.iconSlot)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceName)
                        .font(themeStore.uiFont(.body))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusTint)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)

                        Text(detailText)
                            .font(themeStore.uiFont(.footnote))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                            .minimumScaleFactor(0.82)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.tertiaryText)
                    .accessibilityHidden(true)
            }

            // 断线提示回到它描述的那张卡片里，不再是三行之外的分组 footer。
            if let warningText {
                Text(warningText)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.connection.warning")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tokens.surface,
            in: RoundedRectangle(
                cornerRadius: SettingsLayoutMetrics.statusModuleCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: SettingsLayoutMetrics.statusModuleCornerRadius,
                style: .continuous
            )
            .stroke(
                hasWarning ? tokens.warning.opacity(0.55) : tokens.border.opacity(0.48),
                lineWidth: hasWarning ? 1 : 0.5
            )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        let saved = L10n.plural("ui.saved_macs_count", count: savedDeviceCount)
        return "\(status) · \(saved)"
    }
}

private struct DiagnosticsAndSupportSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let showsHistoryDiagnostics: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                NavigationLink {
                    ConnectionSpeedTestView()
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.connection_speed_test"),
                        systemImage: "gauge.with.dots.needle.67percent"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.connectionSpeedTest")

                NavigationLink {
                    DoctorView(showsHistoryDiagnostics: showsHistoryDiagnostics)
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.diagnosis_and_support"),
                        systemImage: "stethoscope"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.doctor")

                NavigationLink {
                    LegalDocumentView(document: .support)
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.support_and_contact"),
                        systemImage: "questionmark.circle"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.support")
            }
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle(L10n.text("ui.diagnosis_and_support"))
    }
}

private struct AdvancedDevelopmentSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @Binding var developerModeEnabled: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                NavigationLink {
                    CapabilitiesView()
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.competency_checklist"),
                        systemImage: "wand.and.stars"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.capabilities")

                Toggle(isOn: $developerModeEnabled) {
                    SettingsValueLabel(
                        title: L10n.text("ui.developer_mode"),
                        systemImage: "hammer"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.developerMode")
            } footer: {
                Text(
                    developerModeEnabled
                        ? L10n.text("ui.historical_diagnostics_may_display_the_local_machine_path")
                        : L10n.text("ui.turn_on_to_use_advanced_operating_options_and")
                )
            }
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle(L10n.text("ui.advanced_and_development"))
    }
}

private struct AboutAndLegalSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                NavigationLink {
                    LegalDocumentView(document: .privacyPolicy)
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.privacy_policy"),
                        systemImage: "hand.raised"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.privacyPolicy")

                NavigationLink {
                    LegalDocumentView(document: .termsOfUse)
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.terms_of_use"),
                        systemImage: "doc.text"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.termsOfUse")

                NavigationLink {
                    ThirdPartyNoticesView()
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.open_source_license"),
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.openSourceLicense")
            } footer: {
                Text(L10n.text("ui.legal_documents_are_included_in_the_app"))
            }
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle(L10n.text("ui.about_and_legal"))
    }
}

struct GatewayDiagnosticSummary {
    let title: String
    let detail: String
    let color: Color
}
