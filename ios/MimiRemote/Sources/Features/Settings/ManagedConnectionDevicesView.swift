import SwiftUI

/// 中转服务页是一张状态页：先说这台电脑现在怎么连、用的是哪个中转，再告诉用户在哪里切换。
/// 默认和自建中转只能在电脑上改，不在这里摆成看起来能选的选项；手机能做的只有 Mimi 相关的操作。
/// 进入这一页或点开 Mimi 都不会改变线路。
struct ManagedConnectionDevicesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var entitlementStore: ManagedConnectionEntitlementStore
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
                if currentRoute != nil {
                    ConnectionRowLabel(
                        title: L10n.text("ui.connection_status"), value: appStore.connectionStatus.title,
                        systemImage: "link"
                    )
                    .settingsStandardListRow()
                    ConnectionRowLabel(
                        title: L10n.text("ui.relay_current_service"), value: currentRelayTitle,
                        systemImage: "network"
                    )
                    .settingsStandardListRow()
                    .accessibilityIdentifier("settings.relay.currentService")
                }
            } header: {
                SettingsGroupHeader(title: L10n.text("ui.current_connection"), showsDivider: false)
            } footer: {
                Text(scopeNote).settingsSectionFooterStyle()
            }
            .settingsGroupRowStyle()

            if showsMimiSection {
                Section {
                    mimiRow(tokens: tokens)
                    if canSwitchToFree {
                        switchToFreeRow(tokens: tokens)
                    }
                    if let notice = visibleNotice {
                        // 问题写在受影响的选项下面，不另起一张没有标题的卡片。
                        Label(notice, systemImage: "exclamationmark.circle")
                            .foregroundStyle(tokens.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 12)
                            .settingsRow()
                            .accessibilityIdentifier("settings.relay.notice")
                    }
                    if showsRecoveryActions {
                        Button(L10n.text("ui.managed_connection_retry")) {
                            changeRoute { await sessionStore.retryManagedConnection() }
                        }
                        .disabled(isChangingRoute || appStore.requiresRePairing)
                        .settingsRow()
                    }
                } header: {
                    SettingsGroupHeader(title: L10n.text("ui.relay_section_choose"))
                } footer: {
                    if computerSelectedMimiButNotActivated {
                        Text(L10n.text("ui.relay_computer_selected_mimi")).settingsSectionFooterStyle()
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
        .sensoryFeedback(.success, trigger: isMimiEnabled) { _, enabled in enabled }
        .task {
            sessionStore.syncComputerRelayChoice(force: true)
            // 启动时只刷新已有权益。这一页要显示开通状态，还没查过就在这里补一次。
            guard ManagedConnectionSubscriptionView.isEntryVisible,
                  case .loading = entitlementStore.status else { return }
            await entitlementStore.load()
        }
        .accessibilityIdentifier("settings.managedConnectionDevices.detail")
    }

    @ViewBuilder
    private func switchToFreeRow(tokens: ThemeTokens) -> some View {
        if sessionStore.isSwitchingToFreeRelay {
            HStack(spacing: SettingsLayoutMetrics.trailingAccessorySpacing) {
                ConnectionRowLabel(
                    title: L10n.text("ui.relay_switch_to_free"), value: L10n.text("ui.relay_switching"),
                    systemImage: "arrow.uturn.backward"
                )
                ProgressView().controlSize(.small)
            }
            .settingsStandardListRow()
            .accessibilityElement(children: .combine)
        } else {
            Button {
                Task { await sessionStore.switchToFreeRelay() }
            } label: {
                ConnectionRowLabel(
                    title: L10n.text("ui.relay_switch_to_free"), value: L10n.text("ui.relay_tap_to_switch"),
                    systemImage: "arrow.uturn.backward", titleTint: tokens.accent
                )
            }
            .buttonStyle(.plain)
            .disabled(sessionStore.isActivatingMimiRelay || appStore.requiresRePairing)
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.relay.switchToFree")
        }
    }

    @ViewBuilder
    private func mimiRow(tokens: ThemeTokens) -> some View {
        let state = mimiRowState
        switch state {
        case .readyToEnable:
            // 已开通时选择即生效：就地启用，不再多进一页。
            Button(action: enableMimiRelay) {
                mimiRowLabel(state, tokens: tokens)
            }
            .buttonStyle(.plain)
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.relay.mimi")
        case .activating:
            HStack(spacing: SettingsLayoutMetrics.trailingAccessorySpacing) {
                mimiRowLabel(state, tokens: tokens)
                ProgressView().controlSize(.small)
            }
            .settingsStandardListRow()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.relay.mimi")
        case .enabled, .temporarilyFree, .entitledWaitingForConnection, .notActivated:
            // 必须走路径导航：Mimi 页里还有路径导航的链接，闭包推入的页面会盖住它们推入的新页面。
            NavigationLink(value: SettingsDestination.managedConnection) {
                mimiRowLabel(state, tokens: tokens)
            }
            .settingsStandardListRow()
            .accessibilityAddTraits(state == .enabled ? .isSelected : [])
            .accessibilityIdentifier("settings.relay.mimi")
        }
    }

    private func mimiRowLabel(_ state: MimiRowState, tokens: ThemeTokens) -> some View {
        ConnectionRowLabel(
            title: RelayServiceChoice.mimi.title,
            value: state.title,
            systemImage: state == .enabled ? "checkmark.circle.fill" : "network.badge.shield.half.filled",
            titleTint: state == .readyToEnable ? tokens.accent : nil,
            iconTint: state == .enabled ? tokens.accent : nil
        )
    }

    private func enableMimiRelay() {
        guard let id = appStore.activeConnectionProfileID else { return }
        tailcatController.selectRelayService(.mimi, profileID: id)
        sessionStore.reconcileMimiRelay(entitlementStore, retry: true)
    }

    /// Mimi 这一行的状态。开通资格、这台电脑是否启用、实际线路是三回事，这里分开表达。
    enum MimiRowState: Equatable {
        case enabled
        /// 这台电脑选的是 Mimi，但现在临时走免费线路。
        case temporarilyFree
        case activating
        /// 已开通且连着这台电脑，点一下就能启用。
        case readyToEnable
        /// 已开通，但现在没有可以启用的连接。
        case entitledWaitingForConnection
        case notActivated

        var title: String {
            switch self {
            case .enabled: L10n.text("ui.relay_mimi_enabled")
            case .temporarilyFree: L10n.text("ui.relay_mimi_fallback")
            case .activating: L10n.text("ui.relay_mimi_activating")
            case .readyToEnable: L10n.text("ui.relay_mimi_tap_to_enable")
            case .entitledWaitingForConnection: L10n.text("ui.relay_mimi_entitled")
            case .notActivated: L10n.text("ui.relay_mimi_get_started")
            }
        }
    }

    static func mimiRowState(
        profileRoute: ConnectionProfileRoute?, currentRoute: ConnectionProfileRoute?,
        connected: Bool, entitled: Bool, activating: Bool
    ) -> MimiRowState {
        if profileRoute?.isManaged == true {
            return currentRoute?.isManaged == true ? .enabled : .temporarilyFree
        }
        if activating { return .activating }
        guard entitled else { return .notActivated }
        return connected && currentRoute?.usesTailcat == true ? .readyToEnable : .entitledWaitingForConnection
    }

    /// 启用中和已启用由 Mimi 行本身表达，不再重复一句同样的话；只留下需要用户知道的问题。
    static func visibleRelayNotice(_ notice: String?, isActivating: Bool) -> String? {
        guard !isActivating, let notice,
              notice != L10n.text("ui.relay_enabled"),
              notice != L10n.text("ui.relay_activating") else { return nil }
        return notice
    }

    /// 这台手机现在实际用的中转，设备页和中转页显示同一句话。
    /// 电脑选了 Mimi 但手机还没用上时，实际走的是免费线路，不能写成 Mimi。
    static func currentRelayTitle(
        route: ConnectionProfileRoute?, savedChoice: RelayServiceChoice?, freeChoice: RelayServiceChoice?
    ) -> String {
        guard let route else { return L10n.text("ui.not_connected") }
        guard route.usesTailcat else { return L10n.text("ui.relay_not_needed") }
        return currentChoice(route: route, savedChoice: savedChoice, freeChoice: freeChoice)?.title
            ?? L10n.text("ui.relay_free_status")
    }

    /// 手机能改回的只有这台电脑已授权的免费线路。
    static func canSwitchToFree(profileRoute: ConnectionProfileRoute?, hasFreeRoute: Bool) -> Bool {
        profileRoute?.isManaged == true && hasFreeRoute
    }

    /// 电脑已选 Mimi，这台手机还没开通：要说明为什么「当前中转」和电脑上看到的不一样。
    static func computerSelectedMimiButNotActivated(
        computerChoice: RelayServiceChoice?, route: ConnectionProfileRoute?, entitled: Bool
    ) -> Bool {
        computerChoice == .mimi && route?.usesTailcat == true && route?.isManaged == false && !entitled
    }

    private var profileID: String { appStore.activeConnectionProfileID ?? "" }

    private var currentRelayTitle: String {
        Self.currentRelayTitle(
            route: currentRoute,
            savedChoice: tailcatController.relayServiceChoice(profileID: profileID),
            freeChoice: tailcatController.lastFreeRelayChoice(profileID: profileID)
        )
    }

    private var canSwitchToFree: Bool {
        Self.canSwitchToFree(
            profileRoute: appStore.activeConnectionProfile?.connectionRoute,
            hasFreeRoute: tailcatController.hasFreeRoute(profileID: profileID)
        )
    }

    private var isEntitled: Bool {
        Self.hasEntitlementForUpgrade(status: entitlementStore.status, grant: entitlementStore.currentGrant, now: Date())
    }

    private var computerSelectedMimiButNotActivated: Bool {
        Self.computerSelectedMimiButNotActivated(
            computerChoice: tailcatController.computerRelayChoice(profileID: profileID),
            route: currentRoute,
            entitled: isEntitled
        )
    }

    private var isMimiEnabled: Bool { mimiRowState == .enabled }

    private var mimiRowState: MimiRowState {
        Self.mimiRowState(
            profileRoute: appStore.activeConnectionProfile?.connectionRoute,
            currentRoute: currentRoute,
            connected: appStore.connectionStatus.isConnected,
            entitled: isEntitled,
            activating: sessionStore.isActivatingMimiRelay
        )
    }

    private var visibleNotice: String? {
        Self.visibleRelayNotice(sessionStore.mimiRelayNotice, isActivating: sessionStore.isActivatingMimiRelay)
    }

    /// 没有电脑时也要能走到开通：先拿到邀请码、再连电脑是合法顺序，这一页不能是死路。
    private var showsMimiSection: Bool {
        guard ManagedConnectionSubscriptionView.isEntryVisible else { return false }
        return currentRoute?.usesTailcat ?? true
    }

    private var scopeNote: String {
        guard let currentRoute else { return L10n.text("ui.relay_no_computer_detail") }
        return L10n.text(currentRoute.usesTailcat ? "ui.relay_change_on_computer" : "ui.relay_tailcat_scope")
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
        let id = appStore.activeConnectionProfileID ?? ""
        return Self.currentChoice(
            route: currentRoute,
            savedChoice: tailcatController.relayServiceChoice(profileID: id),
            freeChoice: tailcatController.lastFreeRelayChoice(profileID: id)
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
        return route.usesTailcat ? L10n.text("ui.relay_builtin_tailcat") : route.title
    }

    /// 选择 Mimi 不等于开通成功：启用完成前实际还在走免费线路，所以显示那一条。
    /// 电脑告知的免费线路优先；旧版电脑配旧二维码时没有信息，不猜测是默认还是自建。
    static func currentChoice(
        route: ConnectionProfileRoute?, savedChoice: RelayServiceChoice?, freeChoice: RelayServiceChoice? = nil
    ) -> RelayServiceChoice? {
        guard let route, route.usesTailcat else { return nil }
        if route.isManaged { return .mimi }
        return freeChoice ?? (savedChoice == .mimi ? nil : savedChoice)
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
