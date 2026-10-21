import SwiftUI

/// 「设备」里的托管线路与设备页：当前电脑走托管线路的状态、接入电脑、
/// 已登记的电脑与手机或平板。购买与订阅在「我的」里的订阅页（#891）。
struct ManagedConnectionDevicesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var entitlementStore: ManagedConnectionEntitlementStore
    @EnvironmentObject private var deviceStore: ManagedConnectionDeviceStore
    @EnvironmentObject private var tailcatController: TailcatExperimentController
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var pendingRemoval: ManagedConnectionDevice?
    @State private var localError: String?
    @State private var isConnectingMac = false
    @State private var isChangingRoute = false
    @State private var managedRouteError: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            // 订阅过期后线路状态与临时改用已保存线路仍然有用，所以只看当前档案是否走托管。
            if appStore.activeConnectionProfile?.connectionRoute.isManaged == true {
                managedRouteSection
            }
            if isEntitled {
                connectionSection
                devicesSection
            } else {
                subscribeSection
            }
        }
        .themedSettingsForm(tokens: tokens)
        .settingsDetailPage(tokens: tokens)
        .navigationTitle(L10n.text("ui.managed_route_and_devices_title"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(tokens.accent)
        .task(id: entitlementStore.currentGrant?.entitlement.id) {
            guard isEntitled else { return }
            await deviceStore.refreshDevices()
        }
        .onAppear(perform: configureManagedScanner)
        // 扫码请求由本页发起，它是栈顶页面，Cover 必须挂在这里才会真正呈现。
        .fullScreenCover(
            item: qrScannerPresentation.presentationBinding(for: .managedConnection),
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
        .refreshable {
            if isEntitled {
                await deviceStore.refreshDevices()
            }
        }
        .confirmationDialog(
            L10n.text("ui.managed_devices_remove_title"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("ui.managed_devices_remove_action"), role: .destructive) {
                guard let device = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await deviceStore.removeDevice(device) }
            }
            Button(L10n.text("ui.cancel"), role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(L10n.text("ui.managed_devices_remove_message"))
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

    /// 未订阅时不出现空的设备列表，只说明用途并跳到「我的」里的订阅页。
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

    private var connectionSection: some View {
        Section {
            Button {
                localError = nil
                qrScannerPresentation.request(
                    appStore.activeConnectionProfile == nil
                        ? .initialConnection
                        : .addConnectionProfile,
                    from: .managedConnection
                )
            } label: {
                Label(L10n.text("ui.managed_devices_connect_mac"), systemImage: "qrcode.viewfinder")
                    .settingsRow()
            }
            .disabled(isConnectingMac || entitlementStore.isBusy)
            .accessibilityIdentifier("settings.managedSubscription.connectMac")

            if isConnectingMac {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.text("ui.managed_devices_connecting"))
                }
                .accessibilityElement(children: .combine)
            }

            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(tokens.warning)
            }
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.managed_devices_connection"))
        } footer: {
            Text(L10n.text("ui.managed_devices_rescan_notice"))
                .settingsSectionFooterStyle()
        }
        .settingsGroupRowStyle()
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
                    performRouteChange { await sessionStore.retryManagedConnection() }
                } label: {
                    Label(L10n.text("ui.managed_connection_retry"), systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }
                .disabled(isChangingRoute)
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
            return L10n.text("ui.tailcat_needs_address")
        case .starting:
            return L10n.text("ui.connecting")
        case .connected:
            return L10n.text("ui.connected")
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

    private var devicesSection: some View {
        Section {
            HStack(spacing: 16) {
                deviceUsageLabel(
                    title: L10n.text("ui.managed_devices_mac"),
                    systemImage: "laptopcomputer",
                    count: deviceStore.macCount,
                    limit: ManagedConnectionDeviceStore.macLimit
                )
                Spacer(minLength: 8)
                deviceUsageLabel(
                    title: L10n.text("ui.managed_devices_mobile"),
                    systemImage: "iphone.and.arrow.forward",
                    count: deviceStore.mobileCount,
                    limit: ManagedConnectionDeviceStore.mobileLimit
                )
            }
            .accessibilityElement(children: .contain)

            if deviceStore.isRefreshing, deviceStore.devices.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.text("ui.managed_devices_loading"))
                }
                .accessibilityElement(children: .combine)
            } else if deviceStore.devices.isEmpty {
                Text(L10n.text("ui.managed_devices_empty"))
                    .foregroundStyle(tokens.secondaryText)
            } else {
                ForEach(deviceStore.devices) { device in
                    deviceRow(device)
                }
            }

            if let message = deviceStore.errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(tokens.warning)
                    Button(L10n.text("ui.retry")) {
                        Task { await deviceStore.refreshDevices() }
                    }
                    .disabled(deviceStore.isRefreshing)
                }
            }
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.managed_devices_title"))
        } footer: {
            Text(L10n.text("ui.managed_devices_privacy_notice"))
                .settingsSectionFooterStyle()
        }
        .settingsGroupRowStyle()
    }

    private func deviceUsageLabel(
        title: String,
        systemImage: String,
        count: Int,
        limit: Int
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(themeStore.uiFont(.subheadline))
                Text(L10n.format("ui.managed_devices_usage", count, limit))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private func deviceRow(_ device: ManagedConnectionDevice) -> some View {
        HStack(spacing: SettingsLayoutMetrics.iconSpacing) {
            Image(systemName: device.deviceType == .mac ? "laptopcomputer" : "iphone")
                .font(.system(size: SettingsLayoutMetrics.symbolPointSize, weight: .regular))
                .frame(width: SettingsLayoutMetrics.iconSlot)
                .foregroundStyle(tokens.settingsIconTint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.deviceType == .mac
                        ? L10n.text("ui.managed_devices_mac")
                        : L10n.text("ui.managed_devices_mobile"))
                    if device.id == deviceStore.currentDeviceID {
                        Text(L10n.text("ui.managed_devices_this_device"))
                            .font(.caption)
                            .foregroundStyle(tokens.secondaryText)
                    }
                }
                Text(
                    L10n.format(
                        "ui.managed_devices_added_detail",
                        device.createdAt.formatted(date: .abbreviated, time: .shortened),
                        String(device.id.suffix(4)).uppercased()
                    )
                )
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(tokens.secondaryText)
            }
            Spacer(minLength: 8)
            if deviceStore.removingDeviceID == device.id {
                ProgressView()
            } else {
                Button(role: .destructive) {
                    pendingRemoval = device
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.managed_devices_remove_action"))
            }
        }
        .settingsRow(.descriptive)
        .accessibilityElement(children: .contain)
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
            guard isEntitled else {
                throw ManagedConnectionDeviceStoreError.subscriptionRequired
            }
            let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw),
                  let link = try TailcatPairingLink.parse(url),
                  link.managedMacInstallationID != nil,
                  link.managedMacTailcatPublicKey != nil else {
                throw ManagedConnectionDeviceStoreError.managedQRCodeRequired
            }
            let wasConfigured = appStore.isConfigured
            if appStore.activeConnectionProfile == nil {
                _ = try await sessionStore.applyManagedPairingURL(url)
            } else {
                _ = try await sessionStore.addManagedConnectionProfile(
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
        } catch {
            let message = error.localizedDescription
            localError = message
            return .rejected(message)
        }
    }
}
