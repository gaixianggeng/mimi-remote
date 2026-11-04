import SwiftUI

/// 当前电脑的连接事实与恢复动作。服务资格及所有设备的名额在服务管理页。
struct ManagedConnectionDevicesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var entitlementStore: ManagedConnectionEntitlementStore
    @EnvironmentObject private var tailcatController: TailcatExperimentController
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var localError: String?
    @State private var isConnectingMac = false
    @State private var showsHostUpdateLink = false
    @State private var isChangingRoute = false
    @State private var managedRouteError: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            if let profile = appStore.activeConnectionProfile {
                Section {
                    LabeledContent(L10n.text("ui.connection_status"), value: appStore.connectionStatus.title)
                    LabeledContent(L10n.text("ui.connection_method"), value: tailcatController.isEnabled
                        ? L10n.text("ui.relay_builtin") : (appStore.savedFallbackConnectionRoute?.title ?? profile.connectionRoute.title))
                    if profile.connectionRoute == .customTailcat {
                        Text(L10n.text(sessionStore.isActivatingMimiRelay ? "ui.relay_activating" : "ui.relay_free_status"))
                    }
                }
                .settingsGroupRowStyle()
            }
            // 订阅过期后线路状态与临时改用已保存线路仍然有用，所以只看当前档案是否走托管。
            if appStore.activeConnectionProfile?.connectionRoute.isManaged == true {
                managedRouteSection
            }
            if let notice = sessionStore.mimiRelayNotice {
                Section { Text(notice).fixedSize(horizontal: false, vertical: true) }
                    .settingsGroupRowStyle()
            }
            switch entitlementStore.status {
            case .entitled:
                connectionSection
            case .loading, .resolving, .failed:
                // 冷启动刷新或查询失败时还不知道是否订阅，不能把已订阅用户当成未订阅。
                entitlementCheckSection
            case .available, .pending, .expired, .revoked:
                subscribeSection
            }
        }
        .themedSettingsForm(tokens: tokens)
        .settingsDetailPage(tokens: tokens)
        .navigationTitle(L10n.text("ui.managed_route_and_devices_title"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(tokens.accent)
        .onAppear(perform: configureManagedScanner)
        // 扫码请求由本页发起，它是栈顶页面，Cover 必须挂在这里才会真正呈现。
        // 扫码失败页点了「开通托管连接」后从这里推出开通页，不依赖所在的是哪条导航栈。
        .navigationDestination(isPresented: qrScannerPresentation.managedConnectionBinding(for: .managedConnection)) {
            ManagedConnectionSubscriptionView(qrScannerPresentation: qrScannerPresentation)
        }
        .fullScreenCover(
            item: qrScannerPresentation.presentationBinding(for: .managedConnection),
            onDismiss: qrScannerPresentation.didDismiss
        ) { intent in
            QRCodeScannerSheet(
                onDismiss: qrScannerPresentation.dismiss,
                onChooseManualConnection: {
                    qrScannerPresentation.chooseManualConnection(for: intent)
                },
                onOpenManagedConnection: ManagedConnectionSubscriptionView.isEntryVisible
                    ? { qrScannerPresentation.openManagedConnection() }
                    : nil,
                onCode: { rawValue in
                    await qrScannerPresentation.submit(rawValue, intent: intent)
                }
            )
        }
        .refreshable {
            await entitlementStore.refreshEntitlement()
            sessionStore.reconcileMimiRelay(entitlementStore, retry: true)
        }
        .accessibilityIdentifier("settings.managedConnectionDevices.detail")
    }

    private var isEntitled: Bool {
        guard case .entitled = entitlementStore.status else { return false }
        return true
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }

    private var entitlementCheckSection: some View {
        Section {
            if case .failed(let message) = entitlementStore.status {
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(tokens.warning)
                    Button(L10n.text("ui.retry")) {
                        Task { await entitlementStore.load() }
                    }
                    .disabled(entitlementStore.isBusy)
                    .accessibilityIdentifier("settings.managedConnectionDevices.retry")
                }
                .settingsRow(.descriptive)
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.text("ui.managed_subscription_checking"))
                }
                .settingsRow(.descriptive)
                .accessibilityElement(children: .combine)
            }
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.managed_subscription_title"), showsDivider: false)
        }
        .settingsGroupRowStyle()
    }

    /// 确认未订阅（或已过期、撤销、待批准）时不出现空的设备列表，只说明用途并跳到「我的」里的订阅页。
    private var subscribeSection: some View {
        Section {
            Text(L10n.text("ui.managed_devices_subscribe_notice"))
                .font(themeStore.uiFont(.body))
                .foregroundStyle(tokens.secondaryText)
                .settingsRow(.descriptive)

            NavigationLink(value: SettingsDestination.managedConnection) {
                SettingsValueLabel(
                    title: L10n.text("ui.managed_devices_subscribe_action"),
                    systemImage: "network"
                )
            }
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.managedConnectionDevices.subscribe")
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.managed_subscription_title"), showsDivider: false)
        }
        .settingsGroupRowStyle()
    }

    /// 这一屏只回答一件事：下一步该做什么。不同状态只给能走通的那条路（#949）。
    enum ConnectStep: Equatable {
        /// 手机正连着这台电脑，点一下就能接入。
        case oneTap
        /// 现在连不上这台电脑，要回到同一个 Wi-Fi。
        case backToSameNetwork
        /// 只能在电脑上操作后扫码：用的是自建 Tailcat，或还没有连过电脑。
        case fromComputer
        case connected
        /// 已接入但现在连不上，由线路状态分组给出恢复办法。
        case reconnecting
    }

    static func connectStep(route: ConnectionProfileRoute?, connected: Bool) -> ConnectStep {
        switch route {
        case .lan, .tailscale, .https:
            return connected ? .oneTap : .backToSameNetwork
        case .customTailcat:
            return connected ? .oneTap : .reconnecting
        case nil:
            return .fromComputer
        case .managedTailcat:
            return connected ? .connected : .reconnecting
        }
    }

    private var connectStep: ConnectStep {
        let connected: Bool
        if case .connected = appStore.connectionStatus {
            connected = true
        } else {
            connected = false
        }
        return Self.connectStep(route: appStore.activeConnectionProfile?.connectionRoute, connected: connected)
    }

    private var connectionSection: some View {
        Section {
            switch connectStep {
            case .oneTap:
                Button {
                    sessionStore.activateMimiRelay()
                } label: {
                    Label(L10n.text(appStore.activeConnectionProfile?.connectionRoute == .customTailcat
                        ? "ui.relay_enable_current" : "ui.managed_devices_upgrade_current"), systemImage: "arrow.up.circle")
                        .settingsRow()
                }
                .disabled(isUpgradingCurrentComputer || isConnectingMac || entitlementStore.isBusy)
                .accessibilityIdentifier("settings.managedConnectionDevices.upgradeCurrent")

                if isUpgradingCurrentComputer {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.text("ui.managed_devices_upgrading"))
                    }
                    .accessibilityElement(children: .combine)
                }
            case .backToSameNetwork:
                connectGuidanceRow("ui.managed_devices_back_to_network", systemImage: "wifi")
                    .accessibilityIdentifier("settings.managedConnectionDevices.backToNetwork")
            case .fromComputer:
                connectGuidanceRow("ui.managed_devices_from_computer", systemImage: "laptopcomputer")
                    .accessibilityIdentifier("settings.managedConnectionDevices.fromComputer")
            case .connected:
                Label {
                    Text(L10n.text("ui.managed_devices_connected_hint"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tokens.success)
                }
                .settingsRow(.descriptive)
                .accessibilityIdentifier("settings.managedConnectionDevices.connectedHint")
            case .reconnecting:
                EmptyView()
            }

            // 扫码不依赖当前线路：旧连接回不去、或换了一台电脑时，这是唯一走得通的路。
            Button {
                localError = nil
                showsHostUpdateLink = false
                qrScannerPresentation.request(
                    appStore.activeConnectionProfile == nil
                        ? .initialConnection
                        : .addConnectionProfile,
                    from: .managedConnection
                )
            } label: {
                Label(
                    L10n.text(
                        connectStep == .oneTap || connectStep == .connected
                            ? "ui.managed_devices_connect_another"
                            : "ui.managed_devices_connect_mac"
                    ),
                    systemImage: "qrcode.viewfinder"
                )
                .settingsRow()
            }
            .disabled(isUpgradingCurrentComputer || isConnectingMac || entitlementStore.isBusy)
            .accessibilityIdentifier("settings.managedSubscription.connectMac")

            // 一键接入已经显示进度；扫码接入才需要这里的独立提示。
            if isConnectingMac && !isUpgradingCurrentComputer {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.text("ui.managed_devices_connecting"))
                }
                .accessibilityElement(children: .combine)
            }

            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(tokens.warning)
                if showsHostUpdateLink {
                    Link(destination: AppExternalLinks.macRelease) {
                        Label(L10n.text("ui.managed_devices_download_host"), systemImage: "arrow.down.circle")
                            .settingsRow()
                    }
                    .accessibilityIdentifier("settings.managedConnectionDevices.downloadHost")
                }
            }
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.managed_devices_connection"))
        } footer: {
            Text(L10n.text("ui.relay_connection_scope"))
                .settingsSectionFooterStyle()
        }
        .settingsGroupRowStyle()
    }

    private func connectGuidanceRow(_ key: String, systemImage: String) -> some View {
        Label {
            Text(L10n.text(key))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tokens.settingsIconTint)
        }
        // 引导文字常有三行，上下留白才不会贴着卡片边和分隔线。
        .padding(.vertical, 8)
        .settingsRow(.descriptive)
    }

    /// 已连上的电脑可以一键接入托管连接（#897）：手机已持有这台电脑的 agentd Token，
    /// 由它请求电脑发起托管配对不扩大权限。只在当前线路不是 Tailcat 时提供——电脑进入
    /// 托管模式会重建 Tailcat 身份，经自建 Tailcat 发起会切断这条请求自己。
    private var canUpgradeCurrentComputer: Bool {
        let connected: Bool
        if case .connected = appStore.connectionStatus {
            connected = true
        } else {
            connected = false
        }
        return Self.canUpgradeCurrentComputer(
            route: appStore.activeConnectionProfile?.connectionRoute,
            connected: connected
        )
    }

    static func canUpgradeCurrentComputer(route: ConnectionProfileRoute?, connected: Bool) -> Bool {
        guard connected, let route else { return false }
        switch route {
        case .lan, .tailscale, .https, .customTailcat:
            return true
        case .managedTailcat:
            return false
        }
    }

    private var isUpgradingCurrentComputer: Bool { sessionStore.isActivatingMimiRelay }

    /// 发起一键接入（含确认后重发）时的订阅判断：界面状态是已订阅，或凭证刷新途中
    /// 手里的权益仍在有效期内。检查中的瞬态不能把已订阅用户挡在外面。
    static func hasEntitlementForUpgrade(
        status: ManagedConnectionEntitlementStore.Status,
        grant: ManagedConnectionEntitlementGrant?,
        now: Date
    ) -> Bool {
        if case .entitled = status { return true }
        guard let grant else { return false }
        return grant.entitlement.expiresAt > now
    }

    static func pairingErrorMessage(_ error: Error) -> String {
        // 系统的「网络连接已中断」无法告诉用户下一步，两种接入入口统一给出恢复办法。
        if error is URLError {
            return L10n.text("ui.managed_devices_pairing_network_error")
        }
        return error.localizedDescription
    }

    private var managedRouteSection: some View {
        Section {
            Label(managedRouteStatusText, systemImage: managedRouteStatusImage)
                .foregroundStyle(managedRouteStatusColor)

            if let diagnostic = tailcatController.lastDiagnostic {
                Label(diagnostic.summary, systemImage: "point.3.connected.trianglepath.dotted")
                if let requestSummary = diagnostic.requestSummary {
                    Label(requestSummary, systemImage: "stopwatch")
                }
            }

            if showsManagedRecoveryActions {
                Button {
                    performRouteChange { await sessionStore.useSavedConnectionRouteOnce(.customTailcat) }
                } label: {
                    Label(L10n.text("ui.relay_use_free"), systemImage: "arrow.triangle.branch")
                        .frame(minHeight: 44)
                }
                .disabled(isChangingRoute || appStore.requiresRePairing ||
                          !tailcatController.hasFreeRoute(profileID: appStore.activeConnectionProfileID ?? ""))
                Button {
                    performRouteChange { await sessionStore.retryManagedConnection() }
                } label: {
                    Label(L10n.text("ui.managed_connection_retry"), systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }
                .disabled(isChangingRoute || sessionStore.isActivatingMimiRelay || appStore.requiresRePairing)
                .accessibilityIdentifier("settings.managedConnection.retry")

                Button {
                    performRouteChange { await sessionStore.useSavedConnectionRouteOnce(.tailscale) }
                } label: {
                    Label(L10n.text("ui.managed_connection_use_tailscale_once"), systemImage: "network")
                        .frame(minHeight: 44)
                }
                .disabled(isChangingRoute || !appStore.canUseSavedFallback(.tailscale))
                .accessibilityIdentifier("settings.managedConnection.useTailscaleOnce")

                Button {
                    performRouteChange { await sessionStore.useSavedConnectionRouteOnce(.lan) }
                } label: {
                    Label(L10n.text("ui.managed_connection_use_lan_once"), systemImage: "wifi.router")
                        .frame(minHeight: 44)
                }
                .disabled(isChangingRoute || !appStore.canUseSavedFallback(.lan))
                .accessibilityIdentifier("settings.managedConnection.useLANOnce")
            }

            if isChangingRoute {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.text("ui.connecting"))
                }
                .accessibilityElement(children: .combine)
            }

            if let managedRouteError {
                Label(managedRouteError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(tokens.warning)
            }
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.managed_connection_route_status"))
        } footer: {
            Group {
                if showsManagedRecoveryActions {
                    Text(L10n.text("ui.managed_connection_fallback_notice"))
                }
            }
            .settingsSectionFooterStyle()
        }
        .settingsGroupRowStyle()
    }

    private var showsManagedRecoveryActions: Bool {
        let connectionFailed: Bool
        if case .failed = appStore.connectionStatus {
            connectionFailed = true
        } else {
            connectionFailed = false
        }
        return Self.showsManagedRecoveryActions(
            tailcatState: tailcatController.state,
            connectionFailed: connectionFailed
        )
    }

    static func showsManagedRecoveryActions(
        tailcatState: TailcatExperimentState,
        connectionFailed: Bool
    ) -> Bool {
        switch tailcatState {
        case .usingTemporaryRoute, .failed, .unavailable, .needsAddress:
            return true
        case .disabled, .starting, .connected:
            return connectionFailed
        }
    }

    private var managedRouteStatusText: String {
        switch tailcatController.state {
        case .disabled, .needsAddress:
            return L10n.text("ui.managed_route_needs_connect")
        case .starting:
            return L10n.text("ui.connecting")
        case .connected:
            return appStore.connectionStatus.isConnected
                ? L10n.text("ui.relay_enabled") : L10n.text("ui.connecting")
        case .usingTemporaryRoute(let route):
            return L10n.format("ui.managed_connection_using_temporary_route", route.title)
        case .failed(let message):
            return L10n.format("ui.tailcat_connection_failed_value", message)
        case .unavailable:
            return L10n.text("ui.tailcat_framework_unavailable")
        }
    }

    private var managedRouteStatusImage: String {
        switch tailcatController.state {
        case .connected:
            return "checkmark.circle.fill"
        case .usingTemporaryRoute:
            return "arrow.triangle.branch"
        case .failed, .unavailable:
            return "exclamationmark.triangle.fill"
        case .starting:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .disabled, .needsAddress:
            return "circle.dashed"
        }
    }

    private var managedRouteStatusColor: Color {
        switch tailcatController.state {
        case .connected:
            return .green
        case .failed, .unavailable:
            return .orange
        case .disabled, .needsAddress, .starting, .usingTemporaryRoute:
            return .secondary
        }
    }

    private func performRouteChange(_ operation: @escaping @MainActor () async -> Bool) {
        guard !isChangingRoute else { return }
        isChangingRoute = true
        managedRouteError = nil
        Task { @MainActor in
            let succeeded = await operation()
            if !succeeded {
                managedRouteError = appStore.lastError ?? L10n.text("ui.managed_devices_network_error")
            }
            isChangingRoute = false
        }
    }

    private func configureManagedScanner() {
        qrScannerPresentation.configure(
            onSubmit: { rawValue, intent in
                await applyManagedPairing(rawValue, intent: intent)
            },
            onChooseManualConnection: { _ in
                localError = L10n.text("ui.managed_devices_qr_required")
            },
            onDismiss: {}
        )
    }

    private func applyManagedPairing(
        _ rawValue: String,
        intent: ConnectionQRCodeScanIntent
    ) async -> QRCodeScannerSubmissionResult {
        isConnectingMac = true
        defer { isConnectingMac = false }
        do {
            let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard intent.isValid(activeProfileID: appStore.activeConnectionProfileID),
                  let url = URL(string: raw) else { throw PairingLinkError.unsupportedURL }
            let wasConfigured = appStore.isConfigured
            if appStore.activeConnectionProfile == nil {
                _ = try await sessionStore.applyPairingURL(url)
            } else {
                _ = try await sessionStore.addConnectionProfile(
                    pairingURL: url,
                    displayName: ""
                )
            }
            localError = nil
            Task { @MainActor in
                _ = await sessionStore.refreshAfterConnectionCommit(
                    maxWait: wasConfigured ? 10 : 45
                )
            }
            return .accepted(
                intent.addsConnectionProfile
                    ? L10n.text("ui.added_and_switched_to_this_mac")
                    : L10n.text("ui.this_mac_is_connected")
            )
        } catch is CancellationError {
            return .rejected(L10n.text("ui.the_code_scan_has_been_cancelled_please_scan"))
        } catch ManagedConnectionDeviceStoreError.subscriptionRequired,
                TailcatPairingError.managedConnectionRequired {
            let message = TailcatPairingError.managedConnectionRequired.localizedDescription
            localError = message
            return .requiresManagedConnection(message)
        } catch {
            let message = Self.pairingErrorMessage(error)
            localError = message
            return .rejected(message)
        }
    }
}
