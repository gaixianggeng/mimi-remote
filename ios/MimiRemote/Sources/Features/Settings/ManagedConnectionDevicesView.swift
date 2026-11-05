import SwiftUI

/// 中转服务页回答两件事：这台电脑现在怎么连的；如果走内置连接，用哪个中转。
/// 三个中转是同一个问题的三个答案，所以并排放在一张卡片里，当前项用对勾标出。
/// 进入这一页或点开 Mimi 都不会改变线路，只有点「启用」和完成开通才算选择。
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
                }
            } header: {
                SettingsGroupHeader(title: L10n.text("ui.current_connection"), showsDivider: false)
            } footer: {
                if let scopeNote {
                    Text(scopeNote).settingsSectionFooterStyle()
                }
            }
            .settingsGroupRowStyle()

            if showsRelayChoices {
                Section {
                    if currentRoute != nil {
                        choiceRow(.tailcatDefault, tokens: tokens)
                        choiceRow(.custom, tokens: tokens)
                    }
                    if ManagedConnectionSubscriptionView.isEntryVisible {
                        mimiRow(tokens: tokens)
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
                    if showsRecoveryActions, let profile = appStore.activeConnectionProfile {
                        Button(L10n.text("ui.managed_connection_retry")) {
                            changeRoute { await sessionStore.retryManagedConnection() }
                        }
                        .disabled(isChangingRoute || appStore.requiresRePairing)
                        .settingsRow()
                        Button(L10n.text("ui.relay_use_free")) {
                            changeRoute { await sessionStore.useSavedConnectionRouteOnce(.customTailcat) }
                        }
                        .disabled(isChangingRoute || appStore.requiresRePairing ||
                                  !tailcatController.hasFreeRoute(profileID: profile.id))
                        .settingsRow()
                    }
                } header: {
                    SettingsGroupHeader(title: L10n.text("ui.relay_section_choose"))
                } footer: {
                    Text(L10n.text("ui.relay_change_on_computer")).settingsSectionFooterStyle()
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
            // 启动时只刷新已有权益。这一行要显示开通状态，还没查过就在这里补一次。
            guard ManagedConnectionSubscriptionView.isEntryVisible,
                  case .loading = entitlementStore.status else { return }
            await entitlementStore.load()
        }
        .accessibilityIdentifier("settings.managedConnectionDevices.detail")
    }

    private func choiceRow(_ choice: RelayServiceChoice, tokens: ThemeTokens) -> some View {
        let selected = currentChoice == choice
        return ConnectionRowLabel(
            title: choice.title,
            value: selected ? choice.detail : L10n.text("ui.relay_set_on_computer"),
            systemImage: selected ? "checkmark.circle.fill" : choice.systemImage,
            iconTint: selected ? tokens.accent : nil
        )
        .settingsStandardListRow()
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.relay.\(choice.rawValue)")
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
            NavigationLink {
                ManagedConnectionSubscriptionView(qrScannerPresentation: qrScannerPresentation)
            } label: {
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
            systemImage: state == .enabled ? "checkmark.circle.fill" : RelayServiceChoice.mimi.systemImage,
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

    /// 设备页「中转服务」行的值。Tailscale、局域网不经过中转；已选 Mimi 但还没开通时如实说。
    static func relayRowValue(
        route: ConnectionProfileRoute?, savedChoice: RelayServiceChoice?, freeChoice: RelayServiceChoice?
    ) -> String {
        guard let route else { return L10n.text("ui.not_connected") }
        guard route.usesTailcat else { return L10n.text("ui.relay_not_needed") }
        if let choice = currentChoice(route: route, savedChoice: savedChoice, freeChoice: freeChoice) {
            return choice.title
        }
        return L10n.text(savedChoice == .mimi ? "ui.relay_mimi_not_activated" : "ui.relay_configured_on_computer")
    }

    private var isMimiEnabled: Bool { mimiRowState == .enabled }

    private var mimiRowState: MimiRowState {
        Self.mimiRowState(
            profileRoute: appStore.activeConnectionProfile?.connectionRoute,
            currentRoute: currentRoute,
            connected: appStore.connectionStatus.isConnected,
            entitled: Self.hasEntitlementForUpgrade(
                status: entitlementStore.status, grant: entitlementStore.currentGrant, now: Date()
            ),
            activating: sessionStore.isActivatingMimiRelay
        )
    }

    private var visibleNotice: String? {
        Self.visibleRelayNotice(sessionStore.mimiRelayNotice, isActivating: sessionStore.isActivatingMimiRelay)
    }

    /// 没有电脑时也要能走到开通：先拿到邀请码、再连电脑是合法顺序，这一页不能是死路。
    private var showsRelayChoices: Bool {
        guard let currentRoute else { return ManagedConnectionSubscriptionView.isEntryVisible }
        return currentRoute.usesTailcat
    }

    private var scopeNote: String? {
        guard let currentRoute else { return L10n.text("ui.relay_no_computer_detail") }
        return currentRoute.usesTailcat ? nil : L10n.text("ui.relay_tailcat_scope")
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

    /// 选择 Mimi 不等于开通成功：启用完成前实际还在走原来的免费线路，所以显示那一项。
    /// 旧二维码没带中转信息时不猜测默认/自有配置。
    static func currentChoice(
        route: ConnectionProfileRoute?, savedChoice: RelayServiceChoice?, freeChoice: RelayServiceChoice? = nil
    ) -> RelayServiceChoice? {
        guard let route, route.usesTailcat else { return nil }
        if route.isManaged { return .mimi }
        return savedChoice == .mimi ? freeChoice : savedChoice
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
