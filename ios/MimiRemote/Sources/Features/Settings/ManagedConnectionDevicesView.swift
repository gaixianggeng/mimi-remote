import SwiftUI

/// 已配对电脑先展示实际连接；只有 Tailcat 需要在这里管理中转服务。
struct ManagedConnectionDevicesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var tailcatController: TailcatExperimentController
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    @State private var isChangingRoute = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        Form {
            Section {
                ConnectionRowLabel(
                    title: L10n.text("ui.connection_method"), value: connectionMethodTitle,
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.relay.connectionMethod")
                ConnectionRowLabel(
                    title: L10n.text("ui.connection_status"), value: appStore.connectionStatus.title,
                    systemImage: "link"
                )
                .settingsStandardListRow()
            } header: {
                Text(L10n.text("ui.current_connection")).settingsSectionHeaderStyle()
            } footer: {
                Text(L10n.text("ui.relay_tailcat_scope")).settingsSectionFooterStyle()
            }
            .settingsGroupRowStyle()

            if currentRoute?.usesTailcat == true {
                Section {
                    ConnectionRowLabel(
                        title: L10n.text("ui.relay_configuration"),
                        value: currentChoice?.title ?? L10n.text("ui.relay_configured_on_computer"),
                        systemImage: "network"
                    )
                    .settingsStandardListRow()
                    .accessibilityIdentifier("settings.relay.currentService")
                    if ManagedConnectionSubscriptionView.isEntryVisible {
                        NavigationLink {
                            ManagedConnectionSubscriptionView(qrScannerPresentation: qrScannerPresentation)
                        } label: {
                            ConnectionRowLabel(
                                title: L10n.text(currentRoute?.isManaged == true
                                    ? "ui.relay_manage_mimi" : "ui.relay_use_mimi"),
                                systemImage: "network.badge.shield.half.filled"
                            )
                        }
                        .settingsStandardListRow()
                        .accessibilityIdentifier("settings.relay.mimi")
                    }
                } footer: {
                    Text(L10n.text("ui.relay_change_on_computer")).settingsSectionFooterStyle()
                }
                .settingsGroupRowStyle()
            }

            if let profile = appStore.activeConnectionProfile,
               sessionStore.mimiRelayNotice != nil || showsRecoveryActions {
                Section {
                    if let notice = sessionStore.mimiRelayNotice {
                        Text(notice).fixedSize(horizontal: false, vertical: true)
                    }
                    if showsRecoveryActions {
                        Button(L10n.text("ui.managed_connection_retry")) {
                            changeRoute { await sessionStore.retryManagedConnection() }
                        }
                        .disabled(isChangingRoute || appStore.requiresRePairing)
                        Button(L10n.text("ui.relay_use_free")) {
                            changeRoute { await sessionStore.useSavedConnectionRouteOnce(.customTailcat) }
                        }
                        .disabled(isChangingRoute || appStore.requiresRePairing ||
                                  !tailcatController.hasFreeRoute(profileID: profile.id))
                    }
                }
                .settingsGroupRowStyle()
            }
        }
        .themedSettingsForm(tokens: tokens)
        .settingsDetailPage(tokens: tokens)
        .navigationTitle(L10n.text("ui.relay_service_title"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(tokens.accent)
        .accessibilityIdentifier("settings.managedConnectionDevices.detail")
    }

    private var showsRecoveryActions: Bool {
        appStore.activeConnectionProfile?.connectionRoute.isManaged == true && Self.showsManagedRecoveryActions(
            tailcatState: tailcatController.state, connectionFailed: !appStore.connectionStatus.isConnected
        )
    }

    private var currentRoute: ConnectionProfileRoute? {
        Self.currentRoute(
            profileRoute: appStore.activeConnectionProfile?.connectionRoute,
            tailcatEnabled: tailcatController.isEnabled, tailcatState: tailcatController.state,
            fallbackRoute: appStore.savedFallbackConnectionRoute
        )
    }

    private var connectionMethodTitle: String {
        Self.connectionMethodTitle(route: currentRoute)
    }

    private var currentChoice: RelayServiceChoice? {
        Self.currentChoice(
            route: currentRoute,
            savedChoice: tailcatController.relayServiceChoice(profileID: appStore.activeConnectionProfileID ?? "")
        )
    }

    static func currentRoute(
        profileRoute: ConnectionProfileRoute?, tailcatEnabled: Bool,
        tailcatState: TailcatExperimentState, fallbackRoute: ConnectionProfileRoute?
    ) -> ConnectionProfileRoute? {
        guard let profileRoute else { return nil }
        // 临时回退没有改写档案，状态页必须以实际线路为准，不能继续显示 Mimi 正在使用。
        if case .usingTemporaryRoute(let route) = tailcatState { return route }
        if tailcatEnabled { return profileRoute.usesTailcat ? profileRoute : .customTailcat }
        return fallbackRoute ?? profileRoute
    }

    static func connectionMethodTitle(route: ConnectionProfileRoute?) -> String {
        guard let route else { return L10n.text("ui.not_connected") }
        return route.usesTailcat ? "Tailcat" : route.title
    }

    static func currentChoice(route: ConnectionProfileRoute?, savedChoice: RelayServiceChoice?) -> RelayServiceChoice? {
        guard let route, route.usesTailcat else { return nil }
        if route.isManaged { return .mimi }
        // 选择 Mimi 不等于开通成功；旧二维码没带中转信息时也不猜测默认/自有配置。
        return savedChoice == .mimi ? nil : savedChoice
    }

    private func changeRoute(_ operation: @escaping @MainActor () async -> Bool) {
        isChangingRoute = true
        Task { @MainActor in
            defer { isChangingRoute = false }
            _ = await operation()
        }
    }

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

    static func canUpgradeCurrentComputer(route: ConnectionProfileRoute?, connected: Bool) -> Bool {
        guard connected, let route else { return false }
        switch route {
        case .lan, .tailscale, .https, .customTailcat:
            return true
        case .managedTailcat:
            return false
        }
    }

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

}
