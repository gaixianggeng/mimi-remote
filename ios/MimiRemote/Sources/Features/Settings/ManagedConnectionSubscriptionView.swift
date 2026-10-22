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
    @EnvironmentObject private var entitlementStore: ManagedConnectionEntitlementStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var restoreResult: ManagedConnectionEntitlementStore.RestoreResult?
    @State private var isManagingSubscription = false

    /// 「我的」里的订阅页：只管买与订阅。线路、接入电脑与设备名额在「设备」里的
    /// 托管线路与设备页（#891），这里只放一行跳转，不复制那边的控件。
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
                subscribedActionsSection
            }
            productsSection
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

            manageSubscriptionButton
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
            SettingsGroupHeader(title: L10n.text("ui.subscription_information"))
        }
        .settingsGroupRowStyle()
    }
}
