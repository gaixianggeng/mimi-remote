import SwiftUI

struct ManagedConnectionSubscriptionView: View {
    static var isEntryVisible: Bool {
        // 托管连接尚未开放；仅本地 Debug 显式开启入口，不改变已有连接功能。
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--debug-enable-managed-connection")
#else
        false
#endif
    }

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
    @State private var restoreResult: ManagedConnectionEntitlementStore.RestoreResult?
    @State private var isConnectingMac = false
    @State private var isChangingRoute = false
    @State private var managedRouteError: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            statusSection
            if appStore.activeConnectionProfile?.connectionRoute.isManaged == true {
                managedRouteSection
            }
            if isEntitled {
                connectionSection
                devicesSection
            }
            productsSection
            subscriptionInformationSection
        }
        .listSectionSpacing(SettingsLayoutMetrics.sectionSpacing)
        .scrollContentBackground(.hidden)
        .settingsDetailPage()
        .settingsCanvasBackground(tokens: tokens)
        .navigationTitle(L10n.text("ui.managed_subscription_title"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(tokens.accent)
        .task {
            if entitlementStore.products.isEmpty {
                await entitlementStore.load()
            }
        }
        .task(id: entitlementStore.currentGrant?.entitlement.id) {
            guard isEntitled else { return }
            await deviceStore.refreshDevices()
        }
        .onAppear(perform: configureManagedScanner)
        .alert(
            L10n.text("ui.restore_purchases"),
            isPresented: Binding(
                get: { restoreResult != nil },
                set: { if !$0 { restoreResult = nil } }
            ),
            presenting: restoreResult
        ) { _ in
            Button(L10n.text("ui.got_it"), role: .cancel) {}
        } message: { result in
            Text(L10n.text(
                result == .restored
                    ? "ui.managed_subscription_restored"
                    : "ui.managed_subscription_restore_empty"
            ))
        }
        // 托管页请求扫码时它自己是栈顶页面，Cover 必须挂在这里才会真正呈现。
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
            await entitlementStore.load()
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
        .accessibilityIdentifier("settings.managedSubscription.detail")
    }

    private var isEntitled: Bool {
        guard case .entitled = entitlementStore.status else { return false }
        return true
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }

    @ViewBuilder
    private var statusSection: some View {
        Section(L10n.text("ui.managed_subscription_status")) {
            switch entitlementStore.status {
            case .loading, .resolving:
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.text("ui.managed_subscription_checking"))
                }
                .accessibilityElement(children: .combine)
            case .available:
                Label(
                    L10n.text("ui.managed_subscription_not_active"),
                    systemImage: "network"
                )
            case .pending:
                Label(
                    L10n.text("ui.managed_subscription_pending"),
                    systemImage: "clock"
                )
            case .expired:
                Label(
                    L10n.text("ui.managed_subscription_expired"),
                    systemImage: "calendar.badge.exclamationmark"
                )
                .foregroundStyle(tokens.warning)
            case .revoked:
                Label(
                    L10n.text("ui.managed_subscription_revoked"),
                    systemImage: "xmark.shield.fill"
                )
                .foregroundStyle(tokens.warning)
            case .entitled(let entitlement):
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        entitlementStatusText(entitlement.status),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(tokens.success)
                    Text(
                        L10n.format(
                            "ui.managed_subscription_valid_until",
                            entitlement.expiresAt.formatted(date: .abbreviated, time: .omitted)
                        )
                    )
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(tokens.warning)
                    Button(L10n.text("ui.retry")) {
                        Task { await entitlementStore.load() }
                    }
                    .disabled(entitlementStore.isBusy)
                }
            }
        }
    }

    private func entitlementStatusText(_ status: ManagedConnectionEntitlement.Status) -> String {
        switch status {
        case .trial:
            return L10n.text("ui.managed_subscription_trial_active")
        case .grace:
            return L10n.text("ui.managed_subscription_grace")
        case .active:
            return L10n.text("ui.managed_subscription_active")
        case .expired:
            return L10n.text("ui.managed_subscription_expired")
        case .revoked:
            return L10n.text("ui.managed_subscription_revoked")
        }
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
            Text(L10n.text("ui.managed_devices_connection"))
        } footer: {
            Text(L10n.text("ui.managed_devices_rescan_notice"))
        }
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
            Text(L10n.text("ui.managed_connection_route_status"))
        } footer: {
            if showsManagedRecoveryActions {
                Text(L10n.text("ui.managed_connection_fallback_notice"))
            }
        }
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
            Text(L10n.text("ui.managed_devices_title"))
        } footer: {
            Text(L10n.text("ui.managed_devices_privacy_notice"))
        }
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
        HStack(spacing: 12) {
            Image(systemName: device.deviceType == .mac ? "laptopcomputer" : "iphone")
                .font(.system(size: SettingsLayoutMetrics.symbolPointSize, weight: .regular))
                .frame(width: SettingsLayoutMetrics.iconSlot)
                .foregroundStyle(tokens.secondaryText)
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

    @ViewBuilder
    private var productsSection: some View {
        Section {
            if entitlementStore.products.isEmpty, !entitlementStore.isBusy {
                Text(L10n.text("ui.managed_subscription_product_unavailable"))
                    .foregroundStyle(tokens.secondaryText)
            } else {
                ForEach(entitlementStore.products) { product in
                    Button {
                        Task { await entitlementStore.purchase(productID: product.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(product.displayName)
                                    .font(themeStore.uiFont(.headline))
                                Spacer(minLength: 12)
                                Text(
                                    L10n.format(
                                        "ui.managed_subscription_price_period",
                                        product.displayPrice,
                                        product.displayPeriod
                                    )
                                )
                                .multilineTextAlignment(.trailing)
                            }
                            if product.isEligibleForTrial, let trialPeriod = product.displayTrialPeriod {
                                Text(L10n.format("ui.managed_subscription_trial_offer", trialPeriod))
                                    .font(themeStore.uiFont(.footnote))
                                    .foregroundStyle(tokens.secondaryText)
                            }
                        }
                        .settingsRow(.descriptive)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(entitlementStore.isBusy)
                    .accessibilityIdentifier("settings.managedSubscription.product.\(product.id)")
                }
            }
        } header: {
            Text(L10n.text("ui.managed_subscription_plans"))
        } footer: {
            Text(L10n.text("ui.managed_subscription_renews_automatically"))
        }
    }

    private var subscriptionInformationSection: some View {
        Section {
            Button(L10n.text("ui.restore_purchases")) {
                Task { restoreResult = await entitlementStore.restorePurchases() }
            }
            .frame(minHeight: 44)
            .disabled(entitlementStore.isBusy)
            .accessibilityIdentifier("settings.managedSubscription.restore")

            Link(destination: AppExternalLinks.termsOfUse) {
                Label(L10n.text("ui.terms_of_use"), systemImage: "doc.text")
            }
            .frame(minHeight: 44)

            Link(destination: AppExternalLinks.privacyPolicy) {
                Label(L10n.text("ui.privacy_policy"), systemImage: "hand.raised")
            }
            .frame(minHeight: 44)
        } header: {
            Text(L10n.text("ui.subscription_information"))
        }
    }
}
