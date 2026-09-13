import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum InitialConnectionErrorClassifier {
    static func isCredentialRejection(_ raw: String) -> Bool {
        let lowercased = raw.lowercased()
        if lowercased.contains("unauthorized") {
            return true
        }
        // 401 必须是独立状态码；Keychain 的 -34018 等 OSStatus 不能被子串误判为鉴权失败。
        return raw.range(
            of: #"(^|\D)401(\D|$)"#,
            options: .regularExpression
        ) != nil
    }
}

enum ConnectionQRCodeScanIntent: Equatable, Identifiable {
    case initialConnection
    case addConnectionProfile
    case repairCurrentProfile(expectedProfileID: String)

    var id: String {
        switch self {
        case .initialConnection:
            return "initialConnection"
        case .addConnectionProfile:
            return "addConnectionProfile"
        case .repairCurrentProfile(let expectedProfileID):
            return "repairCurrentProfile:\(expectedProfileID)"
        }
    }

    var addsConnectionProfile: Bool {
        self == .addConnectionProfile
    }

    func isValid(activeProfileID: String?) -> Bool {
        switch self {
        case .initialConnection:
            return activeProfileID == nil
        case .addConnectionProfile:
            return true
        case .repairCurrentProfile(let expectedProfileID):
            return activeProfileID == expectedProfileID
        }
    }
}

/// 扫码 Cover 必须由当前真正显示的页面呈现；这个标识用来把同一个 presentation
/// 对象绑定到唯一一个还在被呈现层级里的宿主，避免多个 Cover 同时抢呈现。
enum ConnectionQRCodeScannerHost: String {
    case connectionSettings
    case addComputer
    case managedConnection
}

@MainActor
final class ConnectionQRCodeScannerPresentation: ObservableObject {
    typealias SubmissionHandler = (
        _ rawValue: String,
        _ intent: ConnectionQRCodeScanIntent
    ) async -> QRCodeScannerSubmissionResult

    @Published var intent: ConnectionQRCodeScanIntent?
    @Published private(set) var isRequestingCameraAuthorization = false
    @Published private(set) var host: ConnectionQRCodeScannerHost = .connectionSettings

    private var submissionHandler: SubmissionHandler?
    private var manualConnectionHandler: ((ConnectionQRCodeScanIntent) -> Void)?
    private var dismissalHandler: (() -> Void)?

    func configure(
        onSubmit: @escaping SubmissionHandler,
        onChooseManualConnection: @escaping (ConnectionQRCodeScanIntent) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        submissionHandler = onSubmit
        manualConnectionHandler = onChooseManualConnection
        dismissalHandler = onDismiss
    }

    /// 只有 `host` 指向的宿主会真正呈现扫码页；其它页面拿到的绑定始终是 nil。
    func presentationBinding(
        for host: ConnectionQRCodeScannerHost
    ) -> Binding<ConnectionQRCodeScanIntent?> {
        Binding(
            get: { [weak self] in
                guard let self, self.host == host else {
                    return nil
                }
                return self.intent
            },
            set: { [weak self] newValue in
                guard let self, self.host == host else {
                    return
                }
                // Cover 关闭时 SwiftUI 写回 nil；新的呈现只允许经 request(_:from:) 进入。
                if newValue == nil {
                    self.intent = nil
                }
            }
        )
    }

    func request(
        _ requestedIntent: ConnectionQRCodeScanIntent,
        from host: ConnectionQRCodeScannerHost
    ) {
        guard !isRequestingCameraAuthorization else {
            return
        }

        self.host = host

        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            intent = requestedIntent
            return
        }

        // 这里必须由 SettingsView 持有的引用对象承接回调。系统权限弹窗期间 Form
        // 可能重建 Section；若回调只写 Section 自己的 @State，结果会落到已经失效的
        // 视图实例上，首次扫码便不会继续展示 Sheet。
        isRequestingCameraAuthorization = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            // 权限回调会早于系统弹窗的 dismiss 动画结束。若同一帧设置 sheet item，
            // UIKit 会拒绝新的 presenter，但绑定已经变成非 nil，SwiftUI 之后也不会
            // 再尝试。留出一个很短的系统过渡窗口，再提交唯一一次呈现状态。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                guard let self else {
                    return
                }
                self.isRequestingCameraAuthorization = false
                if self.intent == nil {
                    self.intent = requestedIntent
                }
            }
        }
    }

    func dismiss() {
        intent = nil
    }

    func chooseManualConnection(for intent: ConnectionQRCodeScanIntent) {
        manualConnectionHandler?(intent)
    }

    func submit(
        _ rawValue: String,
        intent: ConnectionQRCodeScanIntent
    ) async -> QRCodeScannerSubmissionResult {
        guard let submissionHandler else {
            return .rejected(L10n.text("ui.the_connection_was_not_completed_please_confirm_that"))
        }
        return await submissionHandler(rawValue, intent)
    }

    func didDismiss() {
        dismissalHandler?()
    }
}

/// 设备链路拆成两页：设备首页负责日常管理，添加电脑是独立的一次性流程。
/// 两页共用同一份连接草稿和回调，避免安装引导、连接配置和日常管理各自演进出一套状态。
enum ConnectionSettingsSectionsMode: Equatable {
    case deviceHome
    case addComputer
}

// 首次连接流程按功能区拆出，主设置页只负责导航和页面编排。
struct InitialConnectionSettingsSections: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var tailcatController: TailcatExperimentController
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    @ScaledMetric(relativeTo: .body) private var profileTitlePointSize = 17.0
    @ScaledMetric(relativeTo: .subheadline) private var profileDetailPointSize = 15.0
    /// 当前电脑是整个 Tab 的内容主标题，比普通行大一档。
    @ScaledMetric(relativeTo: .title3) private var currentComputerTitlePointSize = 20.0

    @ObservedObject var draft: ConnectionSettingsDraft
    let transientPreferences: SettingsTransientPreferences
    let mode: ConnectionSettingsSectionsMode

    private var endpoint: String {
        get { draft.endpoint }
        nonmutating set { draft.endpoint = newValue }
    }
    private var token: String {
        get { draft.token }
        nonmutating set { draft.token = newValue }
    }
    private var pendingManualConnectionIntent: ConnectionQRCodeScanIntent? {
        get { draft.pendingManualConnectionIntent }
        nonmutating set { draft.pendingManualConnectionIntent = newValue }
    }
    private var isSavingConnection: Bool {
        get { draft.isSavingConnection }
        nonmutating set { draft.isSavingConnection = newValue }
    }
    private var isAddingConnectionProfile: Bool {
        get { draft.isAddingConnectionProfile }
        nonmutating set { draft.isAddingConnectionProfile = newValue }
    }
    private var profileDisplayName: String {
        get { draft.profileDisplayName }
        nonmutating set { draft.profileDisplayName = newValue }
    }
    private var profileOperationID: String? {
        get { draft.profileOperationID }
        nonmutating set { draft.profileOperationID = newValue }
    }
    private var pendingRemovalConfirmation: ConnectionCredentialRemovalConfirmation? {
        get { draft.pendingRemovalConfirmation }
        nonmutating set { draft.pendingRemovalConfirmation = newValue }
    }
    private var isShowingAdvancedManualConnection: Bool {
        get { draft.isShowingAdvancedManualConnection }
        nonmutating set { draft.isShowingAdvancedManualConnection = newValue }
    }
    private var localError: String? {
        get { draft.localError }
        nonmutating set { draft.localError = newValue }
    }
    private var copyingConnectionProfileID: String? {
        get { draft.copyingConnectionProfileID }
        nonmutating set { draft.copyingConnectionProfileID = newValue }
    }
    private var copiedConnectionProfileID: String? {
        get { draft.copiedConnectionProfileID }
        nonmutating set { draft.copiedConnectionProfileID = newValue }
    }
    private var copyConnectionTask: Task<Void, Never>? {
        get { draft.copyConnectionTask }
        nonmutating set { draft.copyConnectionTask = newValue }
    }
    private var copyFeedbackTask: Task<Void, Never>? {
        get { draft.copyFeedbackTask }
        nonmutating set { draft.copyFeedbackTask = newValue }
    }

    let onRequestProfileRename: (ConnectionProfile) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            switch mode {
            case .deviceHome:
                deviceHomeSections(tokens: tokens)
            case .addComputer:
                addComputerSection(tokens: tokens)
            }
        }
        .listRowBackground(tokens.settingsGroupBackground)
        .settingsStandardListRow()
        .alignmentGuide(.listRowSeparatorLeading) { _ in SettingsLayoutMetrics.iconSlot + 12 }
        // 连接地址/Token 是高频编辑状态，放在这个小子树里，避免每次删字都重绘整个设置页。
        .onAppear(perform: loadInitialConnectionIfNeeded)
        .onChange(of: appStore.activeConnectionProfileID) { _, _ in
            loadInitialConnectionIfNeeded()
        }
        .onChange(of: appStore.endpoint) { _, _ in
            loadInitialConnectionIfNeeded()
        }
        .onChange(of: appStore.token) { _, _ in
            loadInitialConnectionIfNeeded()
        }
        .onDisappear {
            copyConnectionTask?.cancel()
            copyFeedbackTask?.cancel()
        }
        .task {
            // 根启动任务负责自动配对和提交；这里与它复用同一个探测 Task，只更新设置页提示，
            // 避免两个连接事务争抢后导致 bootstrap 提前返回。
            _ = await appStore.detectLocalAgent()
        }
        .task(id: appStore.activeConnectionProfileID) {
            await autoRefreshRouteProbeIfNeeded()
        }
    }

    /// 切到这台电脑就该直接看到延迟，不必先点刷新；30 秒内已有结果就不重复打扰网络。
    private func autoRefreshRouteProbeIfNeeded() async {
        guard mode == .deviceHome, appStore.isConfigured else { return }
        let lastCheckedAt = tailcatController.isEnabled
            ? tailcatController.lastDiagnostic?.checkedAt
            : draft.fallbackRouteProbe?.checkedAt
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < 30 {
            return
        }
        await refreshRouteProbe()
    }

    /// 设备首页只回答三个问题：连的是哪台电脑、是否正常、走哪条线路。
    /// 一台都没存过时这一页就是添加流程本身，不让新用户先去找右上角的加号。
    @ViewBuilder
    private func deviceHomeSections(tokens: ThemeTokens) -> some View {
        let model = appStore.connectionProfileSettingsModel

        if let current = model.current {
            currentComputerSection(current, tokens: tokens)
            otherComputersSection(model.others, ownsPresentation: false)
            addComputerEntrySection(tokens: tokens)
        } else if !model.others.isEmpty {
            // 忘记当前电脑后仍会留下已保存的其它电脑；此时由这一组承接确认弹窗。
            otherComputersSection(model.others, ownsPresentation: true)
            addComputerEntrySection(tokens: tokens)
        } else {
            addComputerSection(tokens: tokens)

#if DEBUG
            // 调试入口只在还没有任何电脑时出现，不混在日常设备管理里。
            Section {
                Button {
                    appStore.enterDebugWorkbenchWithoutPairing()
                } label: {
                    ConnectionRowLabel(title: L10n.text("ui.debug_enter_the_workbench"), systemImage: "wrench.and.screwdriver")
                }
                .accessibilityIdentifier("settings.debugEnterWorkbench")
            }
#endif
        }
    }

    /// 当前电脑、连接状态和连接方式过去是三个分组，回答的却是同一个问题。
    /// 这里合成一张卡片：上半部分只做设备识别，下半部分是配置与诊断的直达入口。
    private func currentComputerSection(
        _ item: ConnectionProfileSettingsItem,
        tokens: ThemeTokens
    ) -> some View {
        connectionPresentationSection {
            currentComputerRow(item)

            if copiedConnectionProfileID == item.id {
                // 访问码提醒只在真正复制的那一刻出现，不再常驻设备首页。
                Text(L10n.text("ui.connection_info_copy_security_notice"))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .settingsRow(.descriptive)
                    .accessibilityIdentifier("settings.profile.copyNotice")
            }

            if let message = displayErrorMessage {
                Text(message)
                    .foregroundStyle(tokens.warning)
                    .font(themeStore.uiFont(size: 13))
                    .settingsRow(.descriptive)
                    .accessibilityIdentifier("settings.connection.error")
            }

            routeStatusRow(tokens: tokens)
            connectionMethodRows(tokens: tokens)

            NavigationLink(value: SettingsDestination.speedTest) {
                ConnectionRowLabel(
                    title: L10n.text("ui.connection_diagnostics"),
                    value: connectionDiagnosticsSummary,
                    systemImage: "stethoscope"
                )
            }
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.connectionSpeedTest")
        } header: {
            Text(L10n.text("ui.current_mac"))
                .settingsSectionHeaderStyle()
        } footer: {
            EmptyView()
        }
    }

    /// 线路行：切到这台电脑就能直接看到走哪条路、多少延迟，并原地刷新。
    private func routeStatusRow(tokens: ThemeTokens) -> some View {
        RouteStatusRow(
            value: routeProbeSummary,
            isFailed: routeProbeFailed,
            isBusy: draft.isProbingRoute,
            isEnabled: appStore.isConfigured
        ) {
            Task { await refreshRouteProbe() }
        }
    }

    private var routeProbeFailed: Bool {
        if tailcatController.isEnabled {
            return tailcatController.lastDiagnostic.map(ConnectionRouteFormatting.isFailure) ?? false
        }
        return draft.fallbackRouteProbe.map { !$0.succeeded } ?? false
    }

    private var routeProbeSummary: String {
        if tailcatController.isEnabled {
            guard let diagnostic = tailcatController.lastDiagnostic else {
                return L10n.text("ui.route_not_probed")
            }
            return ConnectionRouteFormatting.compactSummary(diagnostic)
        }
        guard let probe = draft.fallbackRouteProbe else {
            return L10n.text("ui.route_not_probed")
        }
        var parts: [String] = []
        if !probe.succeeded {
            parts.append(L10n.text("ui.route_probe_failed"))
        }
        if let pathText = ConnectionRouteFormatting.pathText(probe.pathKind, region: probe.relayRegion) {
            parts.append(pathText)
        }
        if let httpMillis = probe.httpMillis {
            parts.append(ConnectionRouteFormatting.httpText(httpMillis))
        }
        parts.append(ConnectionRouteFormatting.timeText(probe.checkedAt))
        return parts.joined(separator: " · ")
    }

    /// Tailcat 走 disco-ping + health 计时（controller 持久化历史）；
    /// 回退线路走 tailscaleNetworkPath + 同样的 health 计时，两边口径一致。
    private func refreshRouteProbe() async {
        guard !draft.isProbingRoute else { return }
        draft.isProbingRoute = true
        defer { draft.isProbingRoute = false }

        if tailcatController.isEnabled {
            _ = await tailcatController.refreshPathDiagnostic(appStore: appStore)
            return
        }
        guard appStore.isConfigured else { return }
        let startedAt = Date()
        var httpMillis: Int?
        var succeeded = false
        do {
            _ = try await appStore.client().health()
            httpMillis = max(0, Int((Date().timeIntervalSince(startedAt) * 1_000).rounded()))
            succeeded = true
        } catch is CancellationError {
            return
        } catch {
            succeeded = false
        }
        let path = try? await appStore.client().tailscaleNetworkPath()
        guard !Task.isCancelled else { return }
        draft.fallbackRouteProbe = FallbackRouteProbe(
            checkedAt: Date(),
            pathKind: path?.kind,
            relayRegion: path?.relayRegion,
            httpMillis: httpMillis,
            succeeded: succeeded
        )
    }

    /// 其它电脑只需要名称、系统和一个明确的「连接」动作，不重复整张状态卡。
    @ViewBuilder
    private func otherComputersSection(
        _ items: [ConnectionProfileSettingsItem],
        ownsPresentation: Bool
    ) -> some View {
        if !items.isEmpty {
            let header = Text("\(L10n.text("ui.other_computers")) · \(items.count)")
                .settingsSectionHeaderStyle()

            // 「只连一台、切换前先验证」解释的是切换行为，跟着切换所在的分组走。
            let footer = Text(L10n.text("ui.only_one_mac_is_connected_at_a_time"))
                .settingsSectionFooterStyle()

            if ownsPresentation {
                connectionPresentationSection {
                    ForEach(items) { otherComputerRow($0) }
                } header: {
                    header
                } footer: {
                    footer
                }
            } else {
                Section {
                    ForEach(items) { otherComputerRow($0) }
                } header: {
                    header
                } footer: {
                    footer
                }
            }
        }
    }

    private func currentComputerRow(_ item: ConnectionProfileSettingsItem) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return HStack(spacing: 12) {
            computerGlyph(item)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.profile.displayName)
                    .font(themeStore.uiFont(size: currentComputerTitlePointSize, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    // 分组标题已经说明这是当前电脑，这里不再重复「当前」徽章。
                    computerSubtitle(
                        item,
                        state: compactConnectionStatusTitle,
                        stateTint: statusColor
                    )
                    .font(themeStore.uiFont(size: profileDetailPointSize))

                    if isConnectionTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            profileMenu(item)
        }
        .padding(.vertical, 8)
        .frame(minHeight: SettingsLayoutMetrics.deviceRowHeight)
        .alignmentGuide(.listRowSeparatorLeading) { _ in SettingsLayoutMetrics.iconSlot + 12 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.profile.\(item.id)")
    }

    private func otherComputerRow(_ item: ConnectionProfileSettingsItem) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        // 大字号下动作换到下一行，保证名称仍有完整阅读宽度。
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))

        return layout {
            HStack(spacing: 12) {
                computerGlyph(item)

                VStack(alignment: .leading, spacing: 3) {
                    computerNameText(item, tokens: tokens)

                    // 没有实际检测过就只能说「已保存」；没连接不等于确认离线。
                    computerSubtitle(
                        item,
                        state: L10n.text("ui.computer_saved"),
                        stateTint: tokens.secondaryText
                    )
                    .font(themeStore.uiFont(size: profileDetailPointSize))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 0) {
                if profileOperationID == item.id {
                    // 先验证再切换：验证期间这台电脑还不是当前电脑。
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.text("ui.verifying_connection"))
                            .font(themeStore.uiFont(size: profileDetailPointSize))
                            .foregroundStyle(tokens.secondaryText)
                    }
                    .frame(minHeight: 44)
                } else {
                    Button(L10n.text("ui.connect")) {
                        Task { await switchConnectionProfile(id: item.id) }
                    }
                    .font(themeStore.uiFont(size: profileDetailPointSize, weight: .semibold))
                    .buttonStyle(.borderless)
                    .tint(tokens.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(isSavingConnection || profileOperationID != nil)
                    .accessibilityIdentifier("settings.profile.switch.\(item.id)")
                }

                profileMenu(item)
            }
            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? SettingsLayoutMetrics.iconSlot + 12 : 0)
        }
        .padding(.vertical, 10)
        .alignmentGuide(.listRowSeparatorLeading) { _ in SettingsLayoutMetrics.iconSlot + 12 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.profile.\(item.id)")
    }

    /// 系统状态文案带电脑名（「已连接 Mimi Mac 助手」）；卡片主行上一行就是电脑名，这里只留状态词。
    private var compactConnectionStatusTitle: String {
        if case .connected = appStore.connectionStatus {
            return L10n.text("ui.connected")
        }
        return appStore.connectionStatus.title
    }

    private func computerGlyph(_ item: ConnectionProfileSettingsItem) -> some View {
        // 保留平台轮廓帮助识别电脑；只统一颜色，避免丢失 Mac、Windows 和 Linux 的区别。
        HostPlatformGlyph(
            kind: item.profile.hostPlatform.iconKind,
            size: SettingsLayoutMetrics.symbolPointSize,
            monochrome: true
        )
        .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
        .frame(width: SettingsLayoutMetrics.iconSlot, height: SettingsLayoutMetrics.iconSlot)
        .accessibilityHidden(true)
    }

    private func computerNameText(
        _ item: ConnectionProfileSettingsItem,
        tokens: ThemeTokens
    ) -> some View {
        Text(item.profile.displayName)
            .font(themeStore.uiFont(size: profileTitlePointSize, weight: .semibold))
            .foregroundStyle(tokens.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 副标题只承担识别与状态，地址留给连接诊断页，不在日常页面展示截断的原始地址。
    private func computerSubtitle(
        _ item: ConnectionProfileSettingsItem,
        state: String,
        stateTint: Color
    ) -> Text {
        let tokens = themeStore.tokens(for: colorScheme)
        let stateText = Text(state).foregroundStyle(stateTint)
        guard let platformName = item.profile.hostPlatform.displayName else {
            return stateText
        }
        return Text("\(platformName) · ").foregroundStyle(tokens.secondaryText) + stateText
    }

    /// 重命名、查看连接信息和移除都属于低频管理动作，收进「更多」而不是摆在行里。
    private func profileMenu(_ item: ConnectionProfileSettingsItem) -> some View {
        Menu {
            // 图标按钮看不出复制的是地址还是含访问码的完整信息，这里用明确的操作名。
            Button {
                copyConnectionInfo(for: item.profile)
            } label: {
                Label(L10n.text("ui.copy_connection_info"), systemImage: "doc.on.doc")
            }
            .disabled(copyingConnectionProfileID != nil)
            .accessibilityHint(L10n.text("ui.connection_info_copy_security_notice"))
            .accessibilityIdentifier("settings.profile.copy.\(item.id)")

            Button(L10n.text("ui.rename")) {
                localError = nil
                onRequestProfileRename(item.profile)
            }
            .accessibilityIdentifier("settings.profile.rename.\(item.id)")

            if item.isCurrent {
                Button(L10n.text("ui.scan_the_qr_code_again_to_pair")) {
                    beginRepairingCurrentProfile()
                }
                .accessibilityIdentifier("settings.connection.repairQRCode")
                Divider()
                Button(L10n.text("ui.forget_this_mac"), role: .destructive) {
                    pendingRemovalConfirmation = .forgettingCurrent(item.profile)
                }
                .accessibilityIdentifier("settings.connection.forget")
            } else {
                Button(L10n.text("ui.delete"), role: .destructive) {
                    pendingRemovalConfirmation = .deletingSavedProfile(item.profile)
                }
                .accessibilityIdentifier("settings.profile.delete.\(item.id)")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: SettingsLayoutMetrics.symbolPointSize, weight: .regular))
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                .frame(width: 44, height: 44)
        }
        .disabled(isSavingConnection || profileOperationID != nil)
        .accessibilityLabel(L10n.format("ui.manage_value", item.profile.displayName))
    }

    /// 连接方式在配对那一刻就由链接决定了（想换局域网就得用局域网链接重新配对），
    /// 所以这里只展示当前方式，不提供切换；高级配置在行内导航的 Tailcat 页里。
    @ViewBuilder
    private func connectionMethodRows(tokens: ThemeTokens) -> some View {
        if ManagedConnectionSubscriptionView.isEntryVisible {
            NavigationLink(value: SettingsDestination.managedConnection) {
                ConnectionRowLabel(
                    title: L10n.text("ui.managed_subscription_title"),
                    value: appStore.activeConnectionProfile?.connectionRoute.isManaged == true
                        ? tailcatController.state.connectionMethodSummary
                        : L10n.text("ui.managed_connection_recommended_value"),
                    systemImage: "network"
                )
            }
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.connection.managedConnection")
        }

        if appStore.isConfigured && appStore.activeConnectionProfile?.connectionRoute.isManaged != true {
            NavigationLink(value: SettingsDestination.tailcat) {
                ConnectionRowLabel(
                    title: L10n.text("ui.connection_method"),
                    value: currentConnectionMethodTitle,
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.connection.tailcat")
        }
    }

    /// 展示生效中的方式：启用 Tailcat 时是档案上的 Tailcat 线路，关闭时回到已保存的直连线路。
    private var currentConnectionMethodTitle: String {
        tailcatController.isEnabled
            ? (appStore.activeConnectionProfile?.connectionRoute.title ?? "Tailcat")
            : (appStore.savedFallbackConnectionRoute?.title ?? "Tailscale")
    }

    /// 添加电脑回到第一层：位置靠下但完整可见，不藏在导航栏加号里。
    /// 扫码直接开相机（presenter 就挂在这一页）；安装说明、粘贴和手动地址在二层。
    private func addComputerEntrySection(tokens: ThemeTokens) -> some View {
        Section {
            // 扫码是唯一主按钮；粘贴是它旁边的次级图标按钮，两者同一行等高。
            ConnectionPrimaryActionsLayout(layoutDirection: layoutDirection) {
                Button(action: beginScanningHost) {
                    ConnectionActionLabel(
                        title: L10n.text("ui.scan_qr_code_on_computer"),
                        systemImage: "qrcode.viewfinder"
                    )
                    .frame(maxHeight: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(tokens.primaryAction)
                .controlSize(.large)
                .accessibilityIdentifier("settings.connection.scanQRCode")
                .foregroundStyle(tokens.primaryActionForeground)

                Button(action: pasteConnectionInfo) {
                    Image(systemName: "clipboard")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(tokens.secondaryText)
                .controlSize(.regular)
                .accessibilityLabel(L10n.text("ui.paste_connection_info"))
                .accessibilityHint(L10n.text("ui.paste_connection_info_hint"))
                .help(L10n.text("ui.paste_connection_info"))
                .accessibilityIdentifier("settings.connection.pasteConnectionInfo")
            }
            .disabled(isSavingConnection || qrScannerPresentation.isRequestingCameraAuthorization)
            // 不覆盖 buttonBorderShape：沿用系统给 bordered 按钮的默认外形，
            // 和连接诊断、手动连接里的按钮保持同一套圆角。
            .padding(.top, SettingsLayoutMetrics.rowHorizontalInset)
            .padding(.bottom, 8)
            .listRowSeparator(.hidden)

            NavigationLink(value: SettingsDestination.addComputer) {
                ConnectionRowLabel(
                    title: L10n.text("ui.other_add_methods"),
                    systemImage: "plus.app"
                )
            }
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.connection.otherAddMethods")
        } header: {
            Text(L10n.text("ui.add_mac"))
                .settingsSectionHeaderStyle()
        } footer: {
            Text(L10n.text("ui.add_computer_scan_hint"))
                .settingsSectionFooterStyle()
        }
    }

    /// 首页只说明上一次诊断的结论和时间，不让旧结果冒充当前在线状态。
    private var connectionDiagnosticsSummary: String {
        guard let report = appStore.lastConnectionTestReport else {
            return L10n.text("ui.diagnostics_have_not_been_run_yet")
        }
        let outcome = report.failedStage == nil
            ? L10n.text("ui.diagnostics_last_check_passed")
            : L10n.text("ui.diagnostics_last_check_failed")
        return "\(outcome) · \(ConnectionRouteFormatting.timeText(report.startedAt))"
    }

    /// 添加电脑是一次性流程：扫码是唯一主操作，安装指引与手动地址都排在它下面。
    private func addComputerSection(tokens: ThemeTokens) -> some View {
        connectionPresentationSection {
#if targetEnvironment(macCatalyst)
            if appStore.localAgentDetected {
                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        appStore.isUsingLocalConnection ? L10n.text("ui.directly_connected_through_local_assistant") : L10n.text("ui.assistant_has_been_detected_on_this_mac"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(themeStore.uiFont(.body, weight: .semibold))
                    .foregroundStyle(tokens.success)
                    if !appStore.isConfigured {
                        Text(localAgentPairingHint)
                            .font(themeStore.uiFont(.footnote))
                            .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                    }
                }
                .padding(.vertical, 2)
            }
#endif
            // 扫码是唯一主按钮；粘贴是它旁边的次级图标按钮，两者同一行等高。
            ConnectionPrimaryActionsLayout(layoutDirection: layoutDirection) {
                Button(action: beginScanningHost) {
                    ConnectionActionLabel(
                        title: L10n.text("ui.scan_qr_code_on_computer"),
                        systemImage: "qrcode.viewfinder"
                    )
                    .frame(maxHeight: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(tokens.primaryAction)
                .controlSize(.large)
                .accessibilityIdentifier("settings.connection.scanQRCode")
                .foregroundStyle(tokens.primaryActionForeground)

                Button(action: pasteConnectionInfo) {
                    Image(systemName: "clipboard")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(tokens.secondaryText)
                .controlSize(.regular)
                .accessibilityLabel(L10n.text("ui.paste_connection_info"))
                .accessibilityHint(L10n.text("ui.paste_connection_info_hint"))
                .help(L10n.text("ui.paste_connection_info"))
                .accessibilityIdentifier("settings.connection.pasteConnectionInfo")
            }
            .disabled(isSavingConnection || qrScannerPresentation.isRequestingCameraAuthorization)
            // 不覆盖 buttonBorderShape：沿用系统给 bordered 按钮的默认外形，
            // 和连接诊断、手动连接里的按钮保持同一套圆角。
            .padding(.top, SettingsLayoutMetrics.rowHorizontalInset)
            .padding(.bottom, 8)
            .listRowSeparator(.hidden)

            if appStore.connectionProfiles.isEmpty {
                // 新用户扫不到码通常是因为电脑端还没装，先把这一步说清楚。
                Text(L10n.text("ui.install_guide_hint"))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .settingsRow(.descriptive)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("settings.connection.installHint")
            }

            HostInstallationSetupView(transientPreferences: transientPreferences)
            manualConnectionRow(tokens: tokens)
        } header: {
            Text(L10n.text("ui.add_mac"))
                .settingsSectionHeaderStyle()
        } footer: {
            Text(connectionSectionFooter)
                .settingsSectionFooterStyle()
        }
    }

    /// 手动地址是恢复入口，默认折叠：保留完整能力，但不和扫码主路径竞争注意力。
    private func manualConnectionRow(tokens: ThemeTokens) -> some View {
        DisclosureGroup(isExpanded: manualConnectionExpandedBinding) {
            VStack(alignment: .leading, spacing: 12) {
                if isAddingConnectionProfile {
                    connectionFieldLabel(L10n.text("ui.display_name")) {
                        TextField(L10n.text("ui.example_studio_mac"), text: $draft.profileDisplayName)
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier("settings.profileDisplayName")
                    }
                }
                connectionFieldLabel(L10n.text("ui.connection_address")) {
                    StableEndpointTextField(placeholder: endpointPlaceholder, text: $draft.endpoint)
                        .frame(minHeight: 28)
                }
                connectionFieldLabel(L10n.text("ui.access_code")) {
                    SecureField(L10n.text("ui.enter_access_code"), text: $draft.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                EndpointTransportNotice(assessment: endpointTransportAssessment)
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 8) {
                        if isSavingConnection {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isSavingConnection ? L10n.text("ui.connecting") : manualSaveButtonTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(tokens.primaryAction)
                .disabled(!canSubmit)
            }
            .padding(.vertical, 6)
        } label: {
            ConnectionRowLabel(title: manualConnectionTitle, systemImage: "keyboard")
        }
        .accessibilityIdentifier("settings.connection.manual")
    }

    /// 业务回调和弹窗只挂到每条连接流程中的一个原生 Section，
    /// 避免系统权限弹窗期间因多个 presenter 同时存在而重复呈现。
    private func connectionPresentationSection<Content: View, Header: View, Footer: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        Section {
            content()
        } header: {
            header()
        } footer: {
            footer()
        }
        // 真正的相机 Cover 由 SettingsView 根层呈现，避免 Form.Section 重建后丢失 presenter。
        .onAppear(perform: configureQRCodeScannerPresentation)
        .confirmationDialog(
            activeRemovalConfirmation?.title ?? L10n.text("ui.confirm_to_delete_connection_credentials"),
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible,
            presenting: activeRemovalConfirmation
        ) { confirmation in
            Button(confirmation.confirmButtonTitle, role: .destructive) {
                Task {
                    await performCredentialRemoval(confirmation)
                }
            }
            .accessibilityIdentifier(removalConfirmationAccessibilityIdentifier(confirmation))

            Button(L10n.text("ui.cancel"), role: .cancel) {
                pendingRemovalConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    /// 删除与忘记只在设备首页发起。添加电脑页 push 上来后两页同时活着，
    /// 若两处都绑同一份状态，系统会同时收到两个呈现请求。
    private var activeRemovalConfirmation: ConnectionCredentialRemovalConfirmation? {
        mode == .deviceHome ? pendingRemovalConfirmation : nil
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { activeRemovalConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemovalConfirmation = nil
                }
            }
        )
    }

    private var manualConnectionExpandedBinding: Binding<Bool> {
        Binding(
            get: { isShowingAdvancedManualConnection },
            set: { isExpanded in
                if isExpanded, !isShowingAdvancedManualConnection {
                    if appStore.activeConnectionProfile != nil {
                        prepareAddingConnectionProfile()
                    } else {
                        isAddingConnectionProfile = false
                        endpoint = ""
                        token = ""
                        localError = nil
                    }
                }
                isShowingAdvancedManualConnection = isExpanded
            }
        )
    }

    private var connectionSectionFooter: String {
        if !appStore.isConfigured && !appStore.localAgentDetected {
            return L10n.text("ui.pairing_information_only_transmitted_between_your_devices")
        }
        return L10n.text("ui.add_computer_scan_hint")
    }

    private var localAgentPairingHint: String {
        switch appStore.connectionStatus {
        case .testing:
            return L10n.text("ui.automatically_claiming_local_credentials_and_verifying_codex_connection")
        case .failed:
            return L10n.text("ui.the_automatic_connection_is_not_completed_please_upgrade")
        case .idle, .connected:
            return L10n.text("ui.the_local_assistant_will_be_automatically_connected_older")
        }
    }

    private var endpointPlaceholder: String {
#if targetEnvironment(macCatalyst)
        L10n.text("ui.native_or_tailscale_address")
#else
        L10n.text("ui.tailscale_address")
#endif
    }

    private var manualConnectionTitle: String {
        guard appStore.activeConnectionProfile != nil else {
            return L10n.text("ui.manual_connection")
        }
        if !isShowingAdvancedManualConnection || isAddingConnectionProfile {
            return L10n.text("ui.add_mac_manually")
        }
        return L10n.text("ui.manually_update_your_current_mac")
    }

    private var manualSaveButtonTitle: String {
        if isAddingConnectionProfile {
            return L10n.text("ui.add_and_connect")
        }
        return appStore.isConfigured ? L10n.text("ui.update_connection") : L10n.text("ui.connect")
    }

    private func connectionFieldLabel<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            content()
        }
        .accessibilityElement(children: .contain)
    }

    private var canSubmit: Bool {
        !isSavingConnection &&
        !isConnectionTesting &&
        endpointTransportAssessment.isAllowed &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var endpointTransportAssessment: EndpointTransportAssessment {
        EndpointTransportPolicy.assess(endpoint)
    }

    private var isConnectionTesting: Bool {
        if case .testing = appStore.connectionStatus {
            return true
        }
        return false
    }

    private var connectionTestDurationText: String? {
        guard let milliseconds = appStore.lastConnectionTestDurationMillis else {
            return nil
        }
        return AppStore.connectionTestDurationText(milliseconds: milliseconds)
    }

    private func connectionStageSummaryRow(title: String, stage: ConnectionTestStageTiming, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(stage.kind.title) · \(AppStore.connectionTestDurationText(milliseconds: stage.durationMillis))")
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private func connectionStabilityRow(_ stability: ConnectionTestStageStability) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L10n.text("ui.recent_fluctuations"))
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(stability.kind.title)
                    .foregroundStyle(themeStore.tokens(for: colorScheme).warning)
                Text(connectionStabilityDetailText(stability))
                    .font(themeStore.uiFont(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private func connectionStabilityDetailText(_ stability: ConnectionTestStageStability) -> String {
        let spread = AppStore.connectionTestDurationText(milliseconds: stability.spreadMillis)
        let max = AppStore.connectionTestDurationText(milliseconds: stability.maxMillis)
        if stability.failureCount > 0 {
            return L10n.format(
                "ui.connection_test_stability_failure_summary",
                L10n.plural("ui.connection_test_samples_count", count: stability.sampleCount),
                L10n.plural("ui.connection_test_failures_count", count: stability.failureCount),
                max
            )
        }
        return L10n.format(
            "ui.connection_test_stability_summary",
            L10n.plural("ui.connection_test_samples_count", count: stability.sampleCount),
            spread,
            max
        )
    }

    private func connectionStageRow(_ stage: ConnectionTestStageTiming) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(stage.kind.title)
                    if case .failed = stage.status {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(.caption2, weight: .semibold))
                            .foregroundStyle(tokens.warning)
                    }
                }
                Text(stage.kind.detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(stageDurationText(stage))
                .font(themeStore.uiFont(.footnote, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(connectionStageColor(stage))
                .lineLimit(1)
        }
    }

    private func stageDurationText(_ stage: ConnectionTestStageTiming) -> String {
        let duration = AppStore.connectionTestDurationText(milliseconds: stage.durationMillis)
        switch stage.status {
        case .succeeded:
            return duration
        case .failed:
            return L10n.format("ui.failure_value", duration)
        }
    }

    private func connectionStageColor(_ stage: ConnectionTestStageTiming) -> Color {
        switch stage.status {
        case .succeeded:
            return .secondary
        case .failed:
            return themeStore.tokens(for: colorScheme).warning
        }
    }

    @ViewBuilder
    private func connectionGatewayDiagnosticsRows(_ diagnostics: ConnectionTestGatewayDiagnostics) -> some View {
        connectionGatewaySummaryRow(diagnostics)

        if diagnostics.failedUpstreamDialsDelta > 0 {
            connectionGatewayMetricRow(
                title: L10n.text("ui.upstream_dialup_failed"),
                detail: L10n.text("ui.this_test_failed_to_add_a_new_addition"),
                value: L10n.format(
                    "ui.connection_test_upstream_dial_failures",
                    L10n.plural("ui.upstream_dial_failures_count", count: diagnostics.failedUpstreamDialsDelta),
                    AppStore.connectionTestDurationText(milliseconds: diagnostics.upstreamDialMillisMax)
                ),
                color: .red
            )
        }

        if let connection = diagnostics.relatedConnection {
            connectionGatewayMetricRow(
                title: L10n.text("ui.mac_upstream_dialing"),
                detail: L10n.text("ui.agentd_to_local_app_server"),
                value: AppStore.connectionTestDurationText(milliseconds: connection.upstreamDialMillis),
                color: gatewayMetricColor(milliseconds: connection.upstreamDialMillis)
            )
        }

        if let rpc = diagnostics.latestRPC {
            connectionGatewayMetricRow(
                title: L10n.text("ui.recent_rpcs"),
                detail: rpc.method.isEmpty ? "app-server JSON-RPC" : rpc.method,
                value: AppStore.connectionTestDurationText(milliseconds: rpc.latencyMillis),
                color: gatewayMetricColor(milliseconds: rpc.latencyMillis)
            )
        }

        if diagnostics.rpcOutstandingRequests > 0 {
            connectionGatewayMetricRow(
                title: L10n.text("ui.waiting_for_upstream"),
                detail: L10n.text("ui.app_server_still_hasn_t_returned_a_response"),
                value: L10n.format("ui.value_value", diagnostics.rpcOutstandingRequests, AppStore.connectionTestDurationText(milliseconds: diagnostics.rpcOutstandingMillisMax)),
                color: themeStore.tokens(for: colorScheme).warning
            )
        }

        if diagnostics.writeBackMillisMax > 0 {
            connectionGatewayMetricRow(
                title: L10n.text("ui.write_back_to_ipad"),
                detail: L10n.text("ui.agentd_gateway_is_written_to_the_current_device"),
                value: AppStore.connectionTestDurationText(milliseconds: diagnostics.writeBackMillisMax),
                color: gatewayMetricColor(milliseconds: diagnostics.writeBackMillisMax)
            )
        }

        if let closeReason = diagnostics.relatedConnection?.closeReason,
           !closeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            connectionGatewayMetricRow(
                title: L10n.text("ui.recently_disconnected"),
                detail: closeReason,
                value: nil,
                color: .secondary
            )
        }

        if let hint = diagnostics.hints.first {
            Text(hint)
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
        }
    }

    private func connectionGatewaySummaryRow(_ diagnostics: ConnectionTestGatewayDiagnostics) -> some View {
        let summary = gatewayDiagnosticSummary(diagnostics)
        return HStack(alignment: .top, spacing: 12) {
            Text(L10n.text("ui.gateway_judgment"))
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(summary.title)
                    .foregroundStyle(summary.color)
                    .lineLimit(1)
                Text(summary.detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func connectionGatewayMetricRow(title: String, detail: String, value: String?, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .font(themeStore.uiFont(.footnote, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
    }

    private func connectionGatewayDiagnosticsErrorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L10n.text("ui.gateway_diagnostics"))
            Spacer(minLength: 12)
            Text(error)
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func gatewayMetricColor(milliseconds: Int) -> Color {
        if milliseconds >= 2_000 {
            return themeStore.tokens(for: colorScheme).warning
        }
        if milliseconds >= 500 {
            return themeStore.tokens(for: colorScheme).warning
        }
        return .secondary
    }

    private func gatewayDiagnosticSummary(_ diagnostics: ConnectionTestGatewayDiagnostics) -> GatewayDiagnosticSummary {
        let warning = themeStore.tokens(for: colorScheme).warning
        if diagnostics.failedUpstreamDialsDelta > 0 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.upstream_dialup_failed"),
                detail: L10n.text("ui.agentd_failed_to_connect_to_local_app_server"),
                color: .red
            )
        }
        if diagnostics.rpcOutstandingRequests > 0 && diagnostics.rpcOutstandingMillisMax >= 2_000 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.upstream_did_not_return"),
                detail: L10n.text("ui.the_request_has_been_sent_to_app_server"),
                color: warning
            )
        }
        if let rpc = diagnostics.latestRPC,
           rpc.latencyMillis >= 1_000 {
            let method = rpc.method.isEmpty ? "app-server JSON-RPC" : rpc.method
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.rpc_returns_slowly"),
                detail: L10n.format("ui.value_return_time_is_high", method),
                color: gatewayMetricColor(milliseconds: rpc.latencyMillis)
            )
        }
        if diagnostics.writeBackMillisMax >= 500 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.write_back_link_slow"),
                detail: L10n.text("ui.prioritize_checking_ipads_and_tailscale_networks"),
                color: gatewayMetricColor(milliseconds: diagnostics.writeBackMillisMax)
            )
        }
        if let connection = diagnostics.relatedConnection,
           connection.upstreamDialMillis >= 500 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.local_dialing_is_slow"),
                detail: L10n.text("ui.agentd_is_slow_to_establish_a_connection_to"),
                color: gatewayMetricColor(milliseconds: connection.upstreamDialMillis)
            )
        }
        if diagnostics.totalConnectionsDelta > 0 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.there_is_a_new_connection_this_time"),
                detail: L10n.text("ui.no_obvious_gateway_bottleneck_found"),
                color: .secondary
            )
        }
        return GatewayDiagnosticSummary(
            title: L10n.text("ui.no_new_samples"),
            detail: L10n.text("ui.continue_to_reproduce_the_slow_scene_and_look"),
            color: .secondary
        )
    }

    private var statusColor: Color {
        switch appStore.connectionStatus {
        case .connected:
            return themeStore.tokens(for: colorScheme).success
        case .failed:
            return themeStore.tokens(for: colorScheme).warning
        case .testing:
            return themeStore.tokens(for: colorScheme).warning
        case .idle:
            return .secondary
        }
    }

    private var displayErrorMessage: String? {
        guard let raw = appStore.lastError ?? localError else {
            return nil
        }
        return friendlyConnectionMessage(raw)
    }

    private func friendlyConnectionMessage(_ raw: String) -> String {
        if let termination = appStore.connectionTermination {
            return termination.message
        }
        let lowercased = raw.lowercased()
        if lowercased.contains("expired") || raw.contains("过期") {
            return L10n.text("ui.the_pairing_qr_code_has_expired_please_re")
        }
        if InitialConnectionErrorClassifier.isCredentialRejection(raw) {
            return L10n.text("ui.this_device_has_not_been_verified_by_mac")
        }
        if lowercased.contains("timed out") || lowercased.contains("cannot connect") || raw.contains("无法连接") {
            if appStore.isTailcatExperimentModeEnabled {
                return L10n.text("ui.please_check_mac_assistant_and_network_connections")
            }
            return L10n.text("ui.the_current_device_cannot_find_this_mac_at")
        }
        if raw == L10n.text("ui.the_connection_credentials_have_been_saved_safely_but") ||
            raw.contains("连接凭据已安全保存") {
            // Old builds persisted this message in Chinese. Always return the current locale's
            // copy so an English screen never echoes that legacy raw value.
            return L10n.text("ui.the_connection_credentials_have_been_saved_safely_but")
        }
        let localizedConnectionLinkKeys = [
            "ui.clipboard_does_not_contain_connection_info",
            "ui.invalid_connection_link",
            "ui.the_connection_link_is_missing_the_access_code",
            "ui.the_link_is_missing_an_address",
            "ui.the_connection_address_format_is_invalid",
            "ui.the_connection_address_is_invalid_please_enter_the"
        ]
        if localizedConnectionLinkKeys.contains(where: { raw == L10n.text($0) }) || raw.contains("Endpoint") {
            return raw
        }
        if raw.contains("连接链接缺少访问码") {
            return L10n.text("ui.the_connection_link_is_missing_the_access_code")
        }
        if raw.contains("连接链接缺少地址") {
            return L10n.text("ui.the_link_is_missing_an_address")
        }
        if raw.contains("连接地址格式无效") {
            return L10n.text("ui.the_connection_address_format_is_invalid")
        }
        if raw.contains("连接地址") || raw.contains("连接链接") {
            return L10n.text("ui.invalid_connection_link")
        }
        return L10n.text("ui.the_connection_was_not_completed_please_confirm_that")
    }

    private func loadInitialConnectionIfNeeded() {
        draft.reloadIfConnectionChanged(
            profileID: appStore.activeConnectionProfileID,
            endpoint: appStore.endpoint,
            token: appStore.token
        )
    }

    private func prepareAddingConnectionProfile() {
        isAddingConnectionProfile = true
        profileDisplayName = ""
        endpoint = ""
        token = ""
        localError = nil
    }

    private var scannerHost: ConnectionQRCodeScannerHost {
        mode == .addComputer ? .addComputer : .connectionSettings
    }

    private func beginScanningHost() {
        let intent: ConnectionQRCodeScanIntent = appStore.activeConnectionProfile == nil
            ? .initialConnection
            : .addConnectionProfile
        pendingManualConnectionIntent = nil
        qrScannerPresentation.request(intent, from: scannerHost)
    }

    private func pasteConnectionInfo() {
        guard let rawValue = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            localError = L10n.text("ui.clipboard_does_not_contain_connection_info")
            return
        }
        let intent: ConnectionQRCodeScanIntent = appStore.activeConnectionProfile == nil
            ? .initialConnection
            : .addConnectionProfile
        Task {
            _ = await applyScannedConnection(rawValue, intent: intent)
        }
    }

    private func copyConnectionInfo(for profile: ConnectionProfile) {
        copyConnectionTask?.cancel()
        copyingConnectionProfileID = profile.id
        copyConnectionTask = Task {
            defer {
                if copyingConnectionProfileID == profile.id {
                    copyingConnectionProfileID = nil
                }
            }
            do {
                let link = try await appStore.connectionTransferLink(profileID: profile.id)
                try Task.checkCancellation()
                // 不设置 localOnly，才能通过系统通用剪贴板交给用户自己的另一台设备。
                // 同时设置系统过期时间，减少长期访问码在剪贴板中停留的窗口。
                UIPasteboard.general.setItems(
                    [[UTType.plainText.identifier: link.url.absoluteString]],
                    options: [.expirationDate: link.expiresAt]
                )
                localError = nil
                copiedConnectionProfileID = profile.id
                copyFeedbackTask?.cancel()
                copyFeedbackTask = Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    guard !Task.isCancelled, copiedConnectionProfileID == profile.id else {
                        return
                    }
                    copiedConnectionProfileID = nil
                }
            } catch is CancellationError {
                return
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func configureQRCodeScannerPresentation() {
        qrScannerPresentation.configure(
            onSubmit: { rawValue, intent in
                await applyScannedConnection(rawValue, intent: intent)
            },
            onChooseManualConnection: { intent in
                pendingManualConnectionIntent = intent
            },
            onDismiss: finishQRCodeScannerPresentation
        )
    }

    private func beginRepairingCurrentProfile() {
        guard let activeProfileID = appStore.activeConnectionProfileID else {
            localError = L10n.text("ui.the_current_mac_has_changed_please_try_again")
            return
        }
        pendingManualConnectionIntent = nil
        qrScannerPresentation.request(
            .repairCurrentProfile(expectedProfileID: activeProfileID),
            from: scannerHost
        )
    }

    private func finishQRCodeScannerPresentation() {
        defer {
            pendingManualConnectionIntent = nil
        }
        guard let intent = pendingManualConnectionIntent else {
            isShowingAdvancedManualConnection = false
            return
        }
        guard intent.isValid(activeProfileID: appStore.activeConnectionProfileID) else {
            localError = L10n.text("ui.the_current_mac_has_changed_please_try_again")
            isShowingAdvancedManualConnection = false
            return
        }

        switch intent {
        case .initialConnection:
            isAddingConnectionProfile = false
            profileDisplayName = ""
            endpoint = ""
            token = ""
            localError = nil
        case .addConnectionProfile:
            prepareAddingConnectionProfile()
        case .repairCurrentProfile:
            isAddingConnectionProfile = false
            profileDisplayName = appStore.activeConnectionProfile?.displayName ?? ""
            endpoint = appStore.endpoint
            token = ""
            localError = nil
        }
        isShowingAdvancedManualConnection = true
    }

    private func switchConnectionProfile(id: String) async {
        profileOperationID = id
        defer { profileOperationID = nil }
        do {
            _ = try await sessionStore.switchConnectionProfile(id: id)
            endpoint = appStore.endpoint
            token = appStore.token
            isAddingConnectionProfile = false
            guard await refreshCommittedConnection(maxWait: 10) else {
                return
            }
        } catch is CancellationError {
            // App 退后台或任务被系统取消时不把仍可用的旧连接标成失败。
            localError = nil
        } catch {
            // prepare/commit 失败时 SessionStore 尚未退役旧连接，这里只展示错误。
            localError = error.localizedDescription
        }
    }

    private func deleteConnectionProfile(id: String) async {
        do {
            try await sessionStore.deleteConnectionProfile(id: id)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func performCredentialRemoval(_ confirmation: ConnectionCredentialRemovalConfirmation) async {
        pendingRemovalConfirmation = nil
        switch confirmation.target {
        case .current(let expectedProfileID):
            guard expectedProfileID == appStore.activeConnectionProfileID else {
                // 弹窗展示期间连接可能被 URL Scheme 或其它入口切换；不能误删后来成为当前的档案。
                localError = L10n.text("ui.the_current_mac_has_changed_please_try_again")
                return
            }
            await clearPairing()
        case .savedProfile(let profileID):
            await deleteConnectionProfile(id: profileID)
        }
    }

    private func removalConfirmationAccessibilityIdentifier(
        _ confirmation: ConnectionCredentialRemovalConfirmation
    ) -> String {
        switch confirmation.target {
        case .current:
            return "settings.connection.forget.confirm"
        case .savedProfile(let profileID):
            return "settings.profile.delete.confirm.\(profileID)"
        }
    }

    private func save() async {
        isSavingConnection = true
        defer { isSavingConnection = false }
        do {
            let wasConfigured = appStore.isConfigured
            if isAddingConnectionProfile {
                _ = try await sessionStore.addConnectionProfile(
                    endpoint: endpoint,
                    token: token,
                    displayName: profileDisplayName
                )
            } else {
                _ = try await sessionStore.applyConnectionSettings(
                    endpoint: endpoint,
                    token: token
                )
            }
            endpoint = appStore.endpoint
            token = appStore.token
            isAddingConnectionProfile = false
            guard await refreshCommittedConnection(maxWait: wasConfigured ? 10 : 45) else {
                return
            }
        } catch is CancellationError {
            localError = nil
        } catch {
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            localError = error.localizedDescription
        }
    }

    private func applyScannedConnection(
        _ rawValue: String,
        intent: ConnectionQRCodeScanIntent
    ) async -> QRCodeScannerSubmissionResult {
        isSavingConnection = true
        guard intent.isValid(activeProfileID: appStore.activeConnectionProfileID) else {
            isSavingConnection = false
            let message = L10n.text("ui.the_current_mac_has_changed_please_try_again")
            localError = message
            return .rejected(message)
        }
        do {
            let wasConfigured = appStore.isConfigured
            let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw) else {
                throw PairingLinkError.unsupportedURL
            }
            let wasAddingConnectionProfile = intent.addsConnectionProfile
            if wasAddingConnectionProfile {
                _ = try await sessionStore.addConnectionProfile(
                    pairingURL: url,
                    displayName: ""
                )
            } else {
                _ = try await sessionStore.applyPairingURL(url)
            }
            endpoint = appStore.endpoint
            token = appStore.token
            isAddingConnectionProfile = false
            // 二维码在这里已经完成真实连接验证并提交。首屏数据继续后台加载，
            // 不让扫码页额外卡住最多 45 秒，也不要求用户重复扫描配对码。
            Task { @MainActor in
                defer { isSavingConnection = false }
                _ = await refreshCommittedConnection(maxWait: wasConfigured ? 10 : 45)
            }
            return .accepted(
                wasAddingConnectionProfile
                    ? L10n.text("ui.added_and_switched_to_this_mac")
                    : L10n.text("ui.this_mac_is_connected")
            )
        } catch is CancellationError {
            isSavingConnection = false
            localError = nil
            return .rejected(L10n.text("ui.the_code_scan_has_been_cancelled_please_scan"))
        } catch {
            isSavingConnection = false
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            localError = error.localizedDescription
            return .rejected(error.localizedDescription)
        }
    }

    private func refreshCommittedConnection(maxWait: TimeInterval) async -> Bool {
        let didLoad = await sessionStore.refreshAfterConnectionCommit(maxWait: maxWait)
        if didLoad {
            localError = nil
        } else if Task.isCancelled {
            localError = nil
        } else {
            localError = appStore.lastError ?? sessionStore.errorMessage
        }
        return didLoad
    }

    private func clearPairing() async {
        do {
            try await sessionStore.clearCurrentConnectionProfile()
            endpoint = appStore.endpoint
            token = appStore.token
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
}

struct ConnectionDiagnosticsNetworkPathRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let networkPath: TailscaleNetworkPathResponse

    var body: some View {
        // iOS 26/27 的 Form 会把带自定义内容的 LabeledContent 拉伸到剩余整屏高度。
        // 改用固有高度布局，让网络路径与后续诊断行始终连续排列。
        Group {
            // 常规字号下保留短 DERP 摘要的紧凑单行；其余路径必须完整测量后再决定是否换行。
            if networkPath.kind == .derp, !dynamicTypeSize.isAccessibilitySize {
                compactDERPContent
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalContent
                    verticalContent
                }
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.connection.diagnostics.networkPath")
    }

    private var compactDERPContent: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L10n.text("ui.tailscale_network_path"))
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 12)

            networkPathLabel
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }

    private var horizontalContent: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L10n.text("ui.tailscale_network_path"))
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 12)

            networkPathLabel
                .font(.subheadline)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("ui.tailscale_network_path"))

            networkPathLabel
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var networkPathLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: networkPath.kind.settingsSystemImage)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(networkPath.localizedSummary)
        }
    }
}
