import SwiftUI

struct ManagedConnectionSubscriptionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var entitlementStore: ManagedConnectionEntitlementStore
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            statusSection
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
        .refreshable {
            await entitlementStore.refreshEntitlement()
        }
        .accessibilityIdentifier("settings.managedSubscription.detail")
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
