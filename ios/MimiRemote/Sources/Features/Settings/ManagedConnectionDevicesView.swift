import SwiftUI

/// 设备页是中转服务的唯一入口，三种选择在这里并列。
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
                ForEach(RelayServiceChoice.allCases) { choice in
                    if choice != .mimi || ManagedConnectionSubscriptionView.isEntryVisible {
                        NavigationLink {
                            if choice == .mimi {
                                ManagedConnectionSubscriptionView(qrScannerPresentation: qrScannerPresentation)
                            } else {
                                FreeRelaySetupView(choice: choice, qrScannerPresentation: qrScannerPresentation)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(choice.title)
                                    Text(L10n.text("ui.relay_choice_" + choice.rawValue + "_detail"))
                                        .font(.footnote).foregroundStyle(tokens.secondaryText)
                                }
                                Spacer()
                                if currentChoice == choice {
                                    Image(systemName: "checkmark").foregroundStyle(tokens.accent)
                                        .accessibilityLabel(L10n.text("ui.relay_current_choice"))
                                }
                            }
                            .settingsRow(.descriptive)
                        }
                        .accessibilityIdentifier("settings.relay." + choice.rawValue)
                    }
                }
            } footer: {
                Text(L10n.text("ui.relay_choice_footer")).settingsSectionFooterStyle()
            }
            .settingsGroupRowStyle()

            if let profile = appStore.activeConnectionProfile {
                Section {
                    LabeledContent(L10n.text("ui.connection_status"), value: appStore.connectionStatus.title)
                    if let notice = sessionStore.mimiRelayNotice {
                        Text(notice).fixedSize(horizontal: false, vertical: true)
                    }
                    if profile.connectionRoute.isManaged,
                       Self.showsManagedRecoveryActions(
                        tailcatState: tailcatController.state,
                        connectionFailed: !appStore.connectionStatus.isConnected
                       ) {
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

    private var currentChoice: RelayServiceChoice? {
        guard let profile = appStore.activeConnectionProfile else { return nil }
        if profile.connectionRoute.isManaged { return .mimi }
        guard profile.connectionRoute == .customTailcat else { return nil }
        let choice = tailcatController.relayServiceChoice(profileID: profile.id)
        return choice == .mimi ? nil : choice
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

/// 自建中转会更换电脑的配对地址。先在电脑保存，再扫码，避免远程改地址切断当前请求。
private struct FreeRelaySetupView: View {
    let choice: RelayServiceChoice
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isConnecting = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        Form {
            Section {
                Text(L10n.text(choice == .custom ? "ui.relay_custom_setup" : "ui.relay_default_setup"))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    qrScannerPresentation.request(
                        appStore.activeConnectionProfileID.map { .repairCurrentProfile(expectedProfileID: $0) }
                            ?? .initialConnection,
                        from: .managedConnection
                    )
                } label: {
                    Label(L10n.text("ui.relay_scan_computer"), systemImage: "qrcode.viewfinder")
                }
                .disabled(isConnecting)
                .accessibilityIdentifier("settings.relay.scan")
            }
            .settingsGroupRowStyle()
        }
        .themedSettingsForm(tokens: tokens)
        .settingsDetailPage(tokens: tokens)
        .navigationTitle(choice.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            qrScannerPresentation.configure(
                onSubmit: submit,
                onChooseManualConnection: { _ in qrScannerPresentation.dismiss() },
                onDismiss: {}
            )
        }
        .navigationDestination(isPresented: qrScannerPresentation.managedConnectionBinding(for: .managedConnection)) {
            ManagedConnectionSubscriptionView(qrScannerPresentation: qrScannerPresentation)
        }
        .fullScreenCover(
            item: qrScannerPresentation.presentationBinding(for: .managedConnection),
            onDismiss: qrScannerPresentation.didDismiss
        ) { intent in
            QRCodeScannerSheet(
                onDismiss: qrScannerPresentation.dismiss,
                onChooseManualConnection: { qrScannerPresentation.dismiss() },
                onOpenManagedConnection: nil,
                onCode: { await submit($0, intent: intent) }
            )
        }
    }

    private func submit(_ raw: String, intent: ConnectionQRCodeScanIntent) async -> QRCodeScannerSubmissionResult {
        guard !isConnecting, intent.isValid(activeProfileID: appStore.activeConnectionProfileID),
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .rejected(L10n.text("ui.the_current_mac_has_changed_please_try_again"))
        }
        // 扫错了另一种中转时保持现有连接，不能把未应用的选项标为成功。
        guard RelayServiceChoice.fromPairingURL(url) == choice else {
            return .rejected(L10n.text("ui.relay_scan_matching_choice"))
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            _ = try await sessionStore.applyPairingURL(url)
            Task { @MainActor in _ = await sessionStore.refreshAfterConnectionCommit(maxWait: 10) }
            return .accepted(L10n.text("ui.this_mac_is_connected"))
        } catch {
            return .rejected(ManagedConnectionDevicesView.pairingErrorMessage(error))
        }
    }
}
