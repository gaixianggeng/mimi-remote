import StoreKit
import SwiftUI

struct ManagedConnectionSubscriptionView: View {
    static let entryInfoPlistKey = "MimiManagedConnectionEntry"
    static let debugEntryLaunchArgument = "--debug-enable-managed-connection"

    static var isEntryVisible: Bool {
#if DEBUG
        let allowsDebugLaunchArgument = true
#else
        let allowsDebugLaunchArgument = false
#endif
        return isEntryVisible(
            infoPlistValue: Bundle.main.object(forInfoDictionaryKey: entryInfoPlistKey),
            launchArguments: ProcessInfo.processInfo.arguments,
            allowsDebugLaunchArgument: allowsDebugLaunchArgument
        )
    }

    /// 托管连接尚未在 App Store 开放（#887）。只有发布脚本显式写入 Info.plist 的内部
    /// TestFlight 构建，或带启动参数的 Debug 构建才显示入口。不按运行时 Sandbox
    /// 环境判断：审核设备同样处于 Sandbox，那样会把未开放的付费页露给审核。
    static func isEntryVisible(
        infoPlistValue: Any?,
        launchArguments: [String],
        allowsDebugLaunchArgument: Bool
    ) -> Bool {
        if (infoPlistValue as? String) == "YES" {
            return true
        }
        return allowsDebugLaunchArgument && launchArguments.contains(debugEntryLaunchArgument)
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var entitlementStore: ManagedConnectionEntitlementStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var appStore: AppStore
    @State private var restoreResult: ManagedConnectionEntitlementStore.RestoreResult?
    @State private var isManagingSubscription = false
    @State private var redemptionCode = ""
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation

    /// 内测阶段只用兑换码开通。TestFlight 购买不收费，又会显示价格和扣款说明，所以先收起购买入口；
    /// 正式开放时改回 true（#949）。
    static let showsPurchaseOptions = false

    /// 服务资格和名额集中在这里；当前电脑的实际连接仍由设备页展示。
    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            if case .available = entitlementStore.status {
                // 还没订阅时先讲清用途，状态行只会显示「未订阅」，没有信息量。
                benefitsSection
            } else {
                statusSection
            }
            if isEntitled {
                if appStore.activeConnectionProfile == nil {
                    Section { Text(L10n.text("ui.managed_redemption_first_connection")) }
                        .settingsGroupRowStyle()
                } else if let route = appStore.activeConnectionProfile?.connectionRoute,
                          route != .customTailcat, !route.isManaged {
                    Section {
                        Text(L10n.text("ui.relay_preserve_connection"))
                        Button(L10n.text("ui.managed_devices_upgrade_current")) { sessionStore.activateMimiRelay() }
                            .disabled(!appStore.connectionStatus.isConnected || sessionStore.isActivatingMimiRelay)
                    }
                    .settingsGroupRowStyle()
                }
                if let notice = sessionStore.mimiRelayNotice {
                    Section { Text(notice).fixedSize(horizontal: false, vertical: true) }
                        .settingsGroupRowStyle()
                }
                if appStore.activeConnectionProfile != nil { subscribedActionsSection }
                ManagedConnectionDeviceListSection()
            }
            if !isEntitled {
                redemptionSection
            }
            if Self.showsPurchaseOptions, !entitlementStore.isRedemptionEntitlement {
                productsSection
            }
            privacySection
            subscriptionInformationSection
        }
        .themedSettingsForm(tokens: tokens)
        .settingsDetailPage(tokens: tokens)
        .navigationTitle(L10n.text("ui.managed_subscription_title"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(tokens.accent)
        .task {
            if entitlementStore.products.isEmpty {
                await entitlementStore.load()
            }
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

    /// 「我的」首页这一行右侧的短状态。还在检查时不显示，避免一闪而过的占位文字。
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
        guard case .entitled = entitlementStore.status else { return false }
        return true
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
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
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        entitlement.productID == ManagedConnectionProductID.betaRedemption
                            ? L10n.text("ui.managed_redemption_active")
                            : entitlementStatusText(entitlement.status),
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

    private var benefitsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("ui.managed_plan_headline"))
                    .font(themeStore.uiFont(.headline))
                    .foregroundStyle(tokens.primaryText)
                Text(L10n.text("ui.managed_plan_subtitle"))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .settingsRow(.descriptive)
            .accessibilityElement(children: .combine)

            ForEach(Self.benefits, id: \.text) { benefit in
                Label {
                    Text(benefit.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: benefit.systemImage)
                        .foregroundStyle(tokens.settingsIconTint)
                }
                .settingsRow(.descriptive)
            }
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.managed_plan_benefits"), showsDivider: false)
        }
        .settingsGroupRowStyle()
        .accessibilityIdentifier("settings.managedSubscription.benefits")
    }

    private static var benefits: [(text: String, systemImage: String)] {
        [
            (L10n.text("ui.managed_plan_benefit_no_setup"), "checkmark.circle"),
            (L10n.text("ui.managed_plan_benefit_relay"), "point.3.connected.trianglepath.dotted"),
            (L10n.text("ui.managed_plan_benefit_private"), "lock"),
            (L10n.text("ui.managed_plan_benefit_devices"), "laptopcomputer.and.iphone")
        ]
    }

    private var subscribedActionsSection: some View {
        Section {
            NavigationLink(value: SettingsDestination.managedConnectionDevices) {
                SettingsValueLabel(
                    title: L10n.text("ui.managed_route_and_devices_title"),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.managedSubscription.devices")

            if !entitlementStore.isRedemptionEntitlement {
                manageSubscriptionButton
            }
        } header: {
            // 统一表单把默认组间距设为零，无标题的操作卡片也要显式保留留白。
            SettingsGroupHeader()
        }
        .settingsGroupRowStyle()
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
            TextField(L10n.text("ui.managed_redemption_placeholder"), text: $redemptionCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(submitRedemption)
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings.managedSubscription.redemptionCode")

            HStack(spacing: 12) {
                Button(L10n.text("ui.managed_redemption_submit"), action: submitRedemption)
                    .disabled(canSubmitRedemption == false)
                    .accessibilityIdentifier("settings.managedSubscription.redeem")
                Spacer(minLength: 12)
                // 系统粘贴按钮不会弹「允许粘贴」；整段聊天消息也能认出里面的码。
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in applyPastedRedemption(strings) }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .disabled(entitlementStore.isBusy)
                .accessibilityIdentifier("settings.managedSubscription.pasteCode")
            }
            .frame(minHeight: 44)
            .buttonStyle(.borderless)

            if CommunityContact.bundled != nil {
                NavigationLink(value: SettingsDestination.community) {
                    SettingsValueLabel(
                        title: L10n.text("ui.managed_redemption_get_code"),
                        systemImage: "person.2"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.managedSubscription.getCode")
            }
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.managed_redemption_title"))
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
        Task {
            await entitlementStore.redeem(code: redemptionCode)
            if isEntitled {
                redemptionCode = ""
                sessionStore.reconcileMimiRelay(entitlementStore, retry: true)
                if appStore.activeConnectionProfile == nil { dismiss() }
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

    /// 用大白话说清三件事：内容谁能看、服务器知道什么、我们存什么。必须和隐私政策一致。
    private var privacySection: some View {
        Section {
            ForEach(Self.privacyPoints, id: \.text) { point in
                Label {
                    Text(point.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: point.systemImage)
                        .foregroundStyle(tokens.settingsIconTint)
                }
                .settingsRow(.descriptive)
            }
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.managed_privacy_title"))
        }
        .settingsGroupRowStyle()
        .accessibilityIdentifier("settings.managedSubscription.privacy")
    }

    private static var privacyPoints: [(text: String, systemImage: String)] {
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
            if entitlementStore.products.isEmpty, !entitlementStore.isBusy {
                Text(L10n.text("ui.managed_subscription_product_unavailable"))
                    .foregroundStyle(tokens.secondaryText)
            } else {
                ForEach(Self.displayOrder(entitlementStore.products)) { product in
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
            SettingsGroupHeader(title: L10n.text("ui.managed_subscription_plans"))
        } footer: {
            Text(L10n.text("ui.managed_subscription_renews_automatically"))
                .settingsSectionFooterStyle()
        }
        .settingsGroupRowStyle()
    }

    private var subscriptionInformationSection: some View {
        Section {
            if Self.showsPurchaseOptions {
                Button(L10n.text("ui.restore_purchases")) {
                    Task { restoreResult = await entitlementStore.restorePurchases() }
                }
                .frame(minHeight: 44)
                .disabled(entitlementStore.isBusy)
                .accessibilityIdentifier("settings.managedSubscription.restore")
            }

            Link(destination: AppExternalLinks.termsOfUse) {
                Label(L10n.text("ui.terms_of_use"), systemImage: "doc.text")
            }
            .frame(minHeight: 44)

            Link(destination: AppExternalLinks.privacyPolicy) {
                Label(L10n.text("ui.privacy_policy"), systemImage: "hand.raised")
            }
            .frame(minHeight: 44)
        } header: {
            SettingsGroupHeader(title: L10n.text("ui.subscription_information"))
        }
        .settingsGroupRowStyle()
    }
}
