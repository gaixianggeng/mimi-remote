import SwiftUI

struct ManagedConnectionSubscriptionView: View {
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
        .refreshable {
            await entitlementStore.refreshEntitlement()
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
                .foregroundStyle(.orange)
            case .revoked:
                Label(
                    L10n.text("ui.managed_subscription_revoked"),
                    systemImage: "xmark.shield.fill"
                )
                .foregroundStyle(.red)
            case .entitled(let entitlement):
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        entitlementStatusText(entitlement.status),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    Text(
                        L10n.format(
                            "ui.managed_subscription_valid_until",
                            entitlement.expiresAt.formatted(date: .abbreviated, time: .omitted)
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
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
                        : .addConnectionProfile
                )
            } label: {
                Label(L10n.text("ui.managed_devices_connect_mac"), systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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
                    .foregroundStyle(.orange)
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
                    .foregroundStyle(.orange)
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
        if case .usingTemporaryRoute = tailcatController.state { return true }
        if case .failed = tailcatController.state { return true }
        if case .failed = appStore.connectionStatus { return true }
        return false
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
                    .foregroundStyle(.secondary)
            } else {
                ForEach(deviceStore.devices) { device in
                    deviceRow(device)
                }
            }

            if let message = deviceStore.errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
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
                    .font(.subheadline)
                Text(L10n.format("ui.managed_devices_usage", count, limit))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private func deviceRow(_ device: ManagedConnectionDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.deviceType == .mac ? "laptopcomputer" : "iphone")
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.deviceType == .mac
                        ? L10n.text("ui.managed_devices_mac")
                        : L10n.text("ui.managed_devices_mobile"))
                    if device.id == deviceStore.currentDeviceID {
                        Text(L10n.text("ui.managed_devices_this_device"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(
                    L10n.format(
                        "ui.managed_devices_added_detail",
                        device.createdAt.formatted(date: .abbreviated, time: .shortened),
                        String(device.id.suffix(4)).uppercased()
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entitlementStore.products) { product in
                    Button {
                        Task { await entitlementStore.purchase(productID: product.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(product.displayName)
                                    .font(.headline)
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
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 44)
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
                Task { await entitlementStore.restorePurchases() }
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
