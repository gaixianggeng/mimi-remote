import StoreKit
import SwiftUI

struct ManagedConnectionSubscriptionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var entitlementStore: ManagedConnectionEntitlementStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var tailcatController: TailcatExperimentController
    @State private var restoreResult: ManagedConnectionEntitlementStore.RestoreResult?
    @State private var isManagingSubscription = false
    @State private var redemptionCode = ""
    @State private var isScanningConnection = false
    /// 用户在这一页发起了开通。只有这时结果才算选择 Mimi；冷启动查到已有权益不改线路。
    @State private var requestedActivation = false
    /// 发起扫码时定下用途。开通成功后 isEntitled 立刻变化，扫码页的文案不能跟着跳。
    @State private var scanPurpose: QRCodeScannerPurpose = .pairing
    /// 明文只在出示页打开期间留在这里，关闭即清空。
    @State private var transferCode: ManagedConnectionTransferCode?
    @State private var isVerifyingTransfer = false
    /// 出示邀请码失败的原因；nil 表示没有失败。
    @State private var transferFailureKey: String?
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    var deviceOwnerAuthenticator: any DeviceOwnerAuthenticating = SystemDeviceOwnerAuthenticator()

    /// 页面先展示订阅或兑换入口，服务介绍与隐私说明放在后面。
    /// 打开这一页不改变线路；完成开通或点「启用」才算选择了 Mimi。
    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            if !showsIntro {
                statusSection
            }
            if isEntitled {
                if appStore.activeConnectionProfile == nil {
                    Section {
                        Text(L10n.text("ui.managed_redemption_first_connection"))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 12)
                            .settingsRow()
                        scanComputerButton
                    } header: {
                        SettingsGroupHeader(title: L10n.text("ui.relay_this_computer"))
                    }
                    .settingsGroupRowStyle()
                } else {
                    thisComputerSection
                }
                if !entitlementStore.isRedemptionEntitlement {
                    Section { manageSubscriptionButton } header: { SettingsGroupHeader() }
                        .settingsGroupRowStyle()
                }
                if entitlementStore.hasTransferableRedemption {
                    addDeviceSection
                }
                ManagedConnectionDeviceListSection()
                if entitlementStore.isRedemptionEntitlement {
                    productsSection
                    redemptionSection
                }
            } else if !isChecking {
                productsSection
                redemptionSection
                serviceSection
            }
            moreInformationSection
        }
        .themedSettingsForm(tokens: tokens)
        .settingsDetailPage(tokens: tokens)
        .navigationTitle(L10n.text("ui.managed_subscription_title"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(tokens.accent)
        .sensoryFeedback(.success, trigger: isEntitled) { _, entitled in entitled }
        .task {
            if entitlementStore.products.isEmpty {
                await entitlementStore.load()
            }
            sessionStore.reconcileMimiRelay(entitlementStore, retry: true)
        }
        .onChange(of: entitlementStore.currentGrant?.entitlement.id) { _, id in
            if id != nil, requestedActivation { selectMimiForCurrentComputer() }
            sessionStore.reconcileMimiRelay(entitlementStore, retry: true)
        }
        .onChange(of: appStore.connectionStatus.isConnected) { _, connected in
            if connected { sessionStore.reconcileMimiRelay(entitlementStore) }
        }
        .fullScreenCover(
            item: qrScannerPresentation.presentationBinding(for: .relaySubscription),
            onDismiss: qrScannerPresentation.didDismiss
        ) { intent in
            QRCodeScannerSheet(
                onDismiss: qrScannerPresentation.dismiss,
                onChooseManualConnection: { qrScannerPresentation.dismiss() },
                onOpenManagedConnection: nil,
                purpose: scanPurpose,
                onCode: { await handleScannedCode($0, intent: intent) }
            )
        }
        .sheet(item: $transferCode) { item in
            ManagedConnectionTransferSheet(code: item.code) { transferCode = nil }
        }
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
#if !targetEnvironment(macCatalyst)
        .manageSubscriptionsSheet(isPresented: $isManagingSubscription)
#endif
        .refreshable {
            await entitlementStore.load()
        }
        .accessibilityIdentifier("settings.managedSubscription.detail")
    }

    private var scanComputerButton: some View {
        Button {
            requestScan(.pairing)
        } label: {
            Label(L10n.text("ui.relay_scan_computer"), systemImage: "qrcode.viewfinder")
        }
        .disabled(isScanningConnection || sessionStore.isActivatingMimiRelay)
        .accessibilityIdentifier("settings.relay.mimi.scan")
    }

    private func requestScan(_ purpose: QRCodeScannerPurpose) {
        scanPurpose = purpose
        qrScannerPresentation.request(
            appStore.activeConnectionProfileID.map { .repairCurrentProfile(expectedProfileID: $0) }
                ?? .initialConnection,
            from: .relaySubscription
        )
    }

    private func handleScannedCode(
        _ raw: String,
        intent: ConnectionQRCodeScanIntent
    ) async -> QRCodeScannerSubmissionResult {
        if scanPurpose == .redemption {
            return await redeemScannedCode(raw)
        }
        return await connectComputer(raw, intent: intent)
    }

    /// 扫到另一台设备出示的邀请码：和手动输入一样算选择了 Mimi，已连接电脑时直接启用，不用再扫电脑。
    private func redeemScannedCode(_ raw: String) async -> QRCodeScannerSubmissionResult {
        guard let code = ManagedRedemptionCode.extract(from: raw) else {
            return .rejected(L10n.text("ui.managed_transfer_not_a_code"))
        }
        requestedActivation = true
        await entitlementStore.redeem(code: code)
        let result = entitlementStore.redemptionScanResult
        if case .activated = result {
            selectMimiForCurrentComputer()
            sessionStore.reconcileMimiRelay(entitlementStore, retry: true)
        }
        return result
    }

    private var addDeviceSection: some View {
        Section {
            Button(action: beginTransfer) {
                SettingsValueLabel(
                    title: L10n.text("ui.managed_transfer_add_device"),
                    systemImage: "qrcode",
                    titleTint: tokens.accent
                )
            }
            .buttonStyle(.plain)
            .disabled(isVerifyingTransfer)
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.managedSubscription.addDevice")
        } header: {
            SettingsGroupHeader()
        } footer: {
            if let transferFailureKey {
                Text(L10n.text(transferFailureKey))
                    .foregroundStyle(tokens.warning)
                    .settingsSectionFooterStyle()
            }
        }
        .settingsGroupRowStyle()
    }

    private func beginTransfer() {
        guard !isVerifyingTransfer else { return }
        isVerifyingTransfer = true
        transferFailureKey = nil
        Task {
            defer { isVerifyingTransfer = false }
            let outcome = await ManagedConnectionTransferGate.requestCode(
                entitlementStore.transferableRedemptionCode,
                authenticator: deviceOwnerAuthenticator,
                reason: L10n.text("ui.managed_transfer_auth_reason")
            )
            switch outcome {
            case .reveal(let code):
                transferCode = ManagedConnectionTransferCode(code: code)
            case .cancelled:
                break
            case .failed:
                transferFailureKey = "ui.managed_transfer_auth_failed"
            case .codeUnavailable:
                transferFailureKey = "ui.managed_transfer_code_unavailable"
            }
        }
    }

    private func connectComputer(_ raw: String, intent: ConnectionQRCodeScanIntent) async -> QRCodeScannerSubmissionResult {
        guard !isScanningConnection, intent.isValid(activeProfileID: appStore.activeConnectionProfileID),
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .rejected(L10n.text("ui.the_current_mac_has_changed_please_try_again"))
        }
        isScanningConnection = true
        defer { isScanningConnection = false }
        do {
            _ = try await sessionStore.applyPairingURL(url)
            // 手机已明确选了 Mimi；扫描旧电脑的普通二维码也继续同一个开通流程。
            if let id = appStore.activeConnectionProfileID {
                tailcatController.selectRelayService(.mimi, profileID: id)
            }
            sessionStore.reconcileMimiRelay(entitlementStore, retry: true)
            return .accepted(L10n.text("ui.this_mac_is_connected"))
        } catch {
            return .rejected(ManagedConnectionDevicesView.pairingErrorMessage(error))
        }
    }

    /// 中转服务的短状态。还在检查时不显示，避免一闪而过的占位文字。
    static func statusSummary(_ status: ManagedConnectionEntitlementStore.Status) -> String? {
        switch status {
        case .loading, .resolving, .failed:
            return nil
        case .available:
            return L10n.text("ui.managed_subscription_not_active")
        case .pending:
            return L10n.text("ui.managed_subscription_short_pending")
        case .expired:
            return L10n.text("ui.managed_subscription_short_expired")
        case .revoked:
            return L10n.text("ui.managed_subscription_short_revoked")
        case .entitled(let entitlement):
            switch entitlement.status {
            case .trial:
                return L10n.text("ui.managed_subscription_short_trial")
            case .grace:
                return L10n.text("ui.managed_subscription_short_grace")
            case .active:
                return L10n.text("ui.managed_subscription_short_active")
            case .expired:
                return L10n.text("ui.managed_subscription_short_expired")
            case .revoked:
                return L10n.text("ui.managed_subscription_short_revoked")
            }
        }
    }

    /// 年付排在前面：远程连接是长期需求，年付是推荐方案。
    static func displayOrder(_ products: [ManagedConnectionProduct]) -> [ManagedConnectionProduct] {
        products.sorted { lhs, rhs in
            (lhs.id == ManagedConnectionProductID.annual ? 0 : 1)
                < (rhs.id == ManagedConnectionProductID.annual ? 0 : 1)
        }
    }

    private var isEntitled: Bool {
        guard case .entitled = displayStatus else { return false }
        return true
    }

    private var isChecking: Bool {
        switch displayStatus {
        case .loading, .resolving: true
        default: false
        }
    }

    private var displayStatus: ManagedConnectionEntitlementStore.Status {
        Self.displayStatus(entitlementStore.status, grant: entitlementStore.currentGrant, now: Date())
    }

    /// 刷新时 Store 会短暂回到检查中。已有有效权益的人不该每次进页都看到邀请码输入框闪一下。
    static func displayStatus(
        _ status: ManagedConnectionEntitlementStore.Status,
        grant: ManagedConnectionEntitlementGrant?,
        now: Date
    ) -> ManagedConnectionEntitlementStore.Status {
        switch status {
        case .loading, .resolving:
            if let grant, grant.entitlement.expiresAt > now { return .entitled(grant.entitlement) }
            return status
        default:
            return status
        }
    }

    /// 在这一页完成开通就是选择了 Mimi；Tailscale、局域网只保留资格，不改线路。
    private func selectMimiForCurrentComputer() {
        guard let profile = appStore.activeConnectionProfile, profile.connectionRoute.usesTailcat else { return }
        tailcatController.selectRelayService(.mimi, profileID: profile.id)
    }

    private var canSwitchToFree: Bool {
        guard let profile = appStore.activeConnectionProfile else { return false }
        return profile.connectionRoute.isManaged && tailcatController.hasFreeRoute(profileID: profile.id)
    }

    private var currentRouteUsesTailcat: Bool {
        appStore.activeConnectionProfile?.connectionRoute.usesTailcat == true
    }

    private var visibleNotice: String? {
        ManagedConnectionDevicesView.visibleRelayNotice(
            sessionStore.mimiRelayNotice, isActivating: sessionStore.isActivatingMimiRelay
        )
    }

    /// 资格属于账号，启用属于电脑：这里只回答「这台电脑用上了吗」，并给出唯一的下一步。
    private var thisComputerSection: some View {
        Section {
            if appStore.activeConnectionProfile?.connectionRoute.isManaged == true {
                ConnectionRowLabel(
                    title: L10n.text("ui.relay_enabled_short"),
                    systemImage: "checkmark.circle.fill",
                    iconTint: tokens.accent
                )
                .settingsStandardListRow()
                if canSwitchToFree {
                    Button {
                        Task { await sessionStore.switchToFreeRelay() }
                    } label: {
                        ConnectionRowLabel(
                            title: L10n.text(sessionStore.isSwitchingToFreeRelay
                                ? "ui.relay_switching" : "ui.relay_switch_to_free"),
                            systemImage: "arrow.uturn.backward",
                            titleTint: tokens.accent
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(sessionStore.isSwitchingToFreeRelay || appStore.requiresRePairing)
                    .settingsStandardListRow()
                    .accessibilityIdentifier("settings.relay.mimi.switchToFree")
                }
            } else if sessionStore.isActivatingMimiRelay {
                HStack(spacing: SettingsLayoutMetrics.iconSpacing) {
                    ProgressView()
                        .frame(width: SettingsLayoutMetrics.iconSlot)
                    Text(L10n.text("ui.relay_activating"))
                }
                .settingsRow()
                .accessibilityElement(children: .combine)
            } else if !currentRouteUsesTailcat {
                explanationRow(L10n.text("ui.relay_preserve_connection"))
            } else if !appStore.connectionStatus.isConnected {
                explanationRow(L10n.text("ui.relay_reconnect_to_configure"))
            } else {
                Button {
                    selectMimiForCurrentComputer()
                    sessionStore.reconcileMimiRelay(entitlementStore, retry: true)
                } label: {
                    ConnectionRowLabel(
                        title: L10n.text("ui.relay_enable_current"),
                        systemImage: "network.badge.shield.half.filled",
                        titleTint: tokens.accent
                    )
                }
                .buttonStyle(.plain)
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.relay.mimi.enable")
            }
            if let notice = visibleNotice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
                    .settingsRow()
            }
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.relay_this_computer"))
        } footer: {
            if appStore.activeConnectionProfile?.connectionRoute.isManaged == true {
                Text(L10n.text(canSwitchToFree ? "ui.relay_switch_keeps_service" : "ui.relay_leave_on_computer"))
                    .settingsSectionFooterStyle()
            }
        }
        .settingsGroupRowStyle()
    }

    private func explanationRow(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 12)
            .settingsRow()
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            switch displayStatus {
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
                    L10n.text(
                        entitlementStore.hasSavedRedemptionCode
                            ? "ui.managed_redemption_expired_status"
                            : "ui.managed_subscription_expired"
                    ),
                    systemImage: "calendar.badge.exclamationmark"
                )
                .foregroundStyle(tokens.warning)
            case .revoked:
                Label(
                    L10n.text(
                        entitlementStore.hasSavedRedemptionCode
                            ? "ui.managed_redemption_revoked_status"
                            : "ui.managed_subscription_revoked"
                    ),
                    systemImage: "xmark.shield.fill"
                )
                .foregroundStyle(tokens.warning)
            case .entitled(let entitlement):
                ConnectionRowLabel(
                    title: entitlement.productID == ManagedConnectionProductID.betaRedemption
                        ? L10n.text("ui.managed_redemption_active")
                        : entitlementStatusText(entitlement.status),
                    value: L10n.format(
                        "ui.managed_subscription_valid_until",
                        entitlement.expiresAt.formatted(date: .abbreviated, time: .omitted)
                    ),
                    systemImage: "checkmark.circle.fill",
                    titleTint: tokens.success,
                    iconTint: tokens.success
                )
                .settingsStandardListRow()
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
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.managed_subscription_status"), showsDivider: false)
        }
        .settingsGroupRowStyle()
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

    private var showsIntro: Bool {
        if case .available = displayStatus { return true }
        return false
    }

    /// 一句话讲清这是什么，放在第一张卡片的标题上方：开通入口要在第一屏，不用先滑过介绍。
    @ViewBuilder
    private func sectionHeader(title: String, isFirst: Bool) -> some View {
        if isFirst, showsIntro {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text("ui.managed_plan_subtitle"))
                    .settingsDetailFont()
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, SettingsLayoutMetrics.groupCardSpacing - SettingsLayoutMetrics.groupTitleBottomSpacing)
                    .accessibilityIdentifier("settings.managedSubscription.intro")
                Text(title)
                    .settingsSectionHeaderStyle()
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.top, SettingsLayoutMetrics.groupTitleTopInset)
            .padding(.bottom, SettingsLayoutMetrics.groupTitleBottomSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(
                top: 0, leading: SettingsLayoutMetrics.rowHorizontalInset,
                bottom: 0, trailing: SettingsLayoutMetrics.rowHorizontalInset
            ))
        } else {
            SettingsGroupHeader(title: title)
        }
    }

    /// 大字号下单行标题会折行，上下要留白，否则文字贴到分隔线上。
    private var wrappedRowPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 10 : 0
    }

    private var serviceSection: some View {
        Section {
            ForEach(Self.benefits, id: \.text) { benefit in
                ConnectionRowLabel(title: benefit.text, systemImage: benefit.systemImage)
                    .padding(.vertical, wrappedRowPadding)
                    .settingsStandardListRow()
            }
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.managed_plan_benefits"))
        }
        .settingsGroupRowStyle()
        .accessibilityIdentifier("settings.managedSubscription.benefits")
    }

    private static var benefits: [(text: String, systemImage: String)] {
        [
            (L10n.text("ui.managed_plan_benefit_private"), "lock"),
            (L10n.text("ui.managed_plan_benefit_devices"), "laptopcomputer.and.iphone")
        ]
    }

    @ViewBuilder
    private var manageSubscriptionButton: some View {
#if targetEnvironment(macCatalyst)
        Link(destination: AppExternalLinks.manageSubscriptions) {
            SettingsValueLabel(
                title: L10n.text("ui.managed_plan_manage_subscription"),
                systemImage: "creditcard"
            )
        }
        .settingsStandardListRow()
        .accessibilityIdentifier("settings.managedSubscription.manage")
#else
        Button {
            isManagingSubscription = true
        } label: {
            SettingsValueLabel(
                title: L10n.text("ui.managed_plan_manage_subscription"),
                systemImage: "creditcard"
            )
        }
        .settingsStandardListRow()
        .accessibilityIdentifier("settings.managedSubscription.manage")
#endif
    }

    /// TestFlight 内测用。整页只在带入口的构建显示，App Store 构建看不到（#887、#949）。
    private var redemptionSection: some View {
        Section {
            HStack(spacing: 12) {
                TextField(L10n.text("ui.managed_redemption_placeholder"), text: $redemptionCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(submitRedemption)
                    .accessibilityIdentifier("settings.managedSubscription.redemptionCode")
                // 系统粘贴按钮不会弹「允许粘贴」；整段聊天消息也能认出里面的码。
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in applyPastedRedemption(strings) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .disabled(entitlementStore.isBusy)
                .accessibilityIdentifier("settings.managedSubscription.pasteCode")
            }
            .settingsRow()

            Button(action: submitRedemption) {
                ConnectionActionLabel(
                    title: L10n.text("ui.managed_redemption_submit"),
                    systemImage: "ticket",
                    isBusy: entitlementStore.isBusy,
                    busyTint: tokens.primaryActionForeground
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(tokens.primaryAction)
            // 主操作的文字色是配深底的，禁用态底色变浅后要换成次级文字，否则看不清。
            .foregroundStyle(canSubmitRedemption ? tokens.primaryActionForeground : tokens.secondaryText)
            .controlSize(.large)
            .disabled(canSubmitRedemption == false)
            .padding(.vertical, 12)
            .listRowSeparator(.hidden)
            .settingsRow()
            .accessibilityIdentifier("settings.managedSubscription.redeem")

            // 这台设备手上没有码、另一台设备已开通时走这里（#989）。
            Button {
                requestScan(.redemption)
            } label: {
                SettingsValueLabel(
                    title: L10n.text("ui.managed_transfer_scan_row"),
                    systemImage: "qrcode.viewfinder",
                    titleTint: tokens.accent
                )
                .padding(.vertical, wrappedRowPadding)
            }
            .buttonStyle(.plain)
            .disabled(entitlementStore.isBusy)
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.managedSubscription.scanCode")

            if CommunityContact.bundled != nil {
                NavigationLink(value: SettingsDestination.community) {
                    SettingsValueLabel(
                        title: L10n.text("ui.managed_redemption_get_code"),
                        systemImage: "person.2"
                    )
                    .padding(.vertical, wrappedRowPadding)
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.managedSubscription.getCode")
            }
        } header: {
            sectionHeader(title: L10n.text("ui.managed_redemption_title"), isFirst: false)
        } footer: {
            if let message = entitlementStore.redemptionErrorMessage {
                Text(message)
                    .foregroundStyle(tokens.warning)
                    .settingsSectionFooterStyle()
            } else {
                Text(L10n.text("ui.managed_redemption_hint"))
                    .settingsSectionFooterStyle()
            }
        }
        .settingsGroupRowStyle()
    }

    private var canSubmitRedemption: Bool {
        !entitlementStore.isBusy
            && !redemptionCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitRedemption() {
        guard canSubmitRedemption else { return }
        requestedActivation = true
        Task {
            await entitlementStore.redeem(code: redemptionCode)
            if isEntitled {
                redemptionCode = ""
                selectMimiForCurrentComputer()
                sessionStore.reconcileMimiRelay(entitlementStore, retry: true)
            }
        }
    }

    private func applyPastedRedemption(_ strings: [String]) {
        guard let code = strings.lazy.compactMap(ManagedRedemptionCode.extract(from:)).first else {
            entitlementStore.setRedemptionError(L10n.text("ui.managed_redemption_paste_empty"))
            return
        }
        redemptionCode = code
        submitRedemption()
    }

    fileprivate static var privacyPoints: [(text: String, systemImage: String)] {
        [
            (L10n.text("ui.managed_privacy_content"), "lock"),
            (L10n.text("ui.managed_privacy_relay"), "arrow.left.arrow.right"),
            (L10n.text("ui.managed_privacy_stored"), "person.crop.circle.badge.xmark"),
            (L10n.text("ui.managed_privacy_location"), "mappin.and.ellipse"),
            (L10n.text("ui.managed_privacy_leave"), "hand.raised")
        ]
    }

    @ViewBuilder
    private var productsSection: some View {
        Section {
            if let reason = entitlementStore.productsUnavailableReason, !entitlementStore.isBusy {
                Text(L10n.text(Self.productsUnavailableKey(reason)))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
                    .settingsRow()
                    .accessibilityIdentifier("settings.managedSubscription.productsUnavailable")
            } else {
                ForEach(Self.displayOrder(entitlementStore.products)) { product in
                    Button {
                        requestedActivation = true
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
            sectionHeader(title: L10n.text("ui.managed_subscription_plans"), isFirst: true)
        } footer: {
            // 拉不到商品时正文已经说明了原因，续费说明和服务器位置都不适用。
            if entitlementStore.productsUnavailableReason == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("ui.managed_subscription_region_notice"))
                        .accessibilityIdentifier("settings.managedSubscription.regionNotice")
                    Text(L10n.text("ui.managed_subscription_renews_automatically"))
                }
                .settingsSectionFooterStyle()
            }
        }
        .settingsGroupRowStyle()
    }

    /// 只在中国大陆 App Store 销售（#1006）：其他地区拉不到商品时说清原因和免费替代，
    /// 不能显示成「暂时不可用」让人以为出了故障。
    static func productsUnavailableKey(
        _ reason: ManagedConnectionEntitlementStore.ProductsUnavailableReason
    ) -> String {
        switch reason {
        case .temporarilyUnavailable: "ui.managed_subscription_product_unavailable"
        case .notSoldInStorefront: "ui.managed_subscription_region_unavailable"
        }
    }

    private var moreInformationSection: some View {
        Section {
            Button(L10n.text("ui.restore_purchases")) {
                Task { restoreResult = await entitlementStore.restorePurchases() }
            }
            .settingsRow()
            .disabled(entitlementStore.isBusy)
            .accessibilityIdentifier("settings.managedSubscription.restore")
            NavigationLink {
                ManagedConnectionPrivacyView()
            } label: {
                ConnectionRowLabel(title: L10n.text("ui.managed_privacy_title"), systemImage: "lock.shield")
            }
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.managedSubscription.privacy")
            SettingsExternalLinkRow(
                title: L10n.text("ui.terms_of_use"), systemImage: "doc.text",
                destination: AppExternalLinks.termsOfUse
            )
            .settingsStandardListRow()
            SettingsExternalLinkRow(
                title: L10n.text("ui.privacy_policy"), systemImage: "hand.raised",
                destination: AppExternalLinks.privacyPolicy
            )
            .settingsStandardListRow()
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.subscription_information"))
        }
        .settingsGroupRowStyle()
    }
}

/// 用大白话说清三件事：内容谁能看、服务器知道什么、我们存什么。必须和隐私政策一致。
/// 内容重要但不是每次都要读，所以放到下一层；开通页只留一个入口。
private struct ManagedConnectionPrivacyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        Form {
            Section {
                ForEach(ManagedConnectionSubscriptionView.privacyPoints, id: \.text) { point in
                    HStack(spacing: SettingsLayoutMetrics.iconSpacing) {
                        Image(systemName: point.systemImage)
                            .font(.system(size: SettingsLayoutMetrics.symbolPointSize, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(tokens.settingsIconTint)
                            .frame(width: SettingsLayoutMetrics.iconSlot)
                            .accessibilityHidden(true)
                        Text(point.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // 多行正文要有上下留白，否则文字会贴到分隔线上。
                    .padding(.vertical, 12)
                    .settingsRow()
                    .alignmentGuide(.listRowSeparatorLeading) { _ in
                        SettingsLayoutMetrics.iconSlot + SettingsLayoutMetrics.iconSpacing
                    }
                }
            } header: {
                SettingsGroupHeader(showsDivider: false)
            }
            .settingsGroupRowStyle()
        }
        .themedSettingsForm(tokens: tokens)
        .settingsDetailPage(tokens: tokens)
        .navigationTitle(L10n.text("ui.managed_privacy_title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.managedSubscription.privacy.detail")
    }
}
