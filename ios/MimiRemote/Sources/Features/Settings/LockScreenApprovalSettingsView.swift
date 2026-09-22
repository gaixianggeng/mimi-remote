import SwiftUI
import UIKit

/// 消息通知偏好与实际送达状态分开显示；自定义服务的信任确认只在需要时出现。
struct LockScreenApprovalSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var store: LockScreenApprovalStore
    @AppStorage("agentd.developerMode") private var developerModeEnabled = false
    @State private var isBusy = false
    @State private var showsConsent = false
    @State private var showsRebindConfirmation = false
    @State private var rebindAfterConsent = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        Form {
            Section {
                Toggle(isOn: toggleBinding) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("ui.push_receive_notifications"))
                            .font(themeStore.uiFont(.body))
                            .foregroundStyle(tokens.primaryText)
                        Text(store.notificationStatusDescription)
                            .font(themeStore.uiFont(.footnote))
                            .foregroundStyle(tokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(isBusy)
                .accessibilityIdentifier("settings.lockScreenApproval.toggle")

                if case .notificationsDenied = store.status, store.notificationsEnabled {
                    Button(L10n.text("ui.push_open_system_settings")) {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .accessibilityIdentifier("settings.lockScreenApproval.systemSettings")
                }
                if store.hasPendingDisable {
                    Button(L10n.text("ui.push_retry_disable")) {
                        Task { await disable() }
                    }
                    .disabled(isBusy)
                } else if store.notificationsEnabled,
                          store.hostSupportsPush(for: appStore.activeConnectionProfileID),
                          !store.hasConsented(for: appStore.activeConnectionProfileID),
                          store.registeredProfileID == nil || store.registeredProfileID == appStore.activeConnectionProfileID {
                    Button(L10n.text("ui.push_trust_custom_service")) { showsConsent = true }
                        .disabled(isBusy)
                } else if store.notificationsEnabled, case .failed = store.status {
                    Button(L10n.text("ui.retry")) { Task { await refresh() } }
                        .disabled(isBusy)
                }
            }

            if let profileID = store.registeredProfileID {
                Section {
                    LabeledContent(L10n.text("ui.push_notification_computer")) {
                        Text(appStore.connectionProfiles.first { $0.id == profileID }?.displayName
                             ?? L10n.text("ui.push_previous_computer"))
                    }
                    if profileID != appStore.activeConnectionProfileID {
                        Button(L10n.text("ui.push_rebind_to_this_computer")) {
                            showsRebindConfirmation = true
                        }
                        .disabled(isBusy || !store.hostSupportsPush(for: appStore.activeConnectionProfileID))
                        .accessibilityIdentifier("settings.lockScreenApproval.rebind")
                    }
                }
            }

            Section {
                NavigationLink(value: SettingsDestination.privacyPolicy) {
                    Label(L10n.text("ui.privacy_policy"), systemImage: "hand.raised")
                }
            }
            if developerModeEnabled {
                Section {
                    Button {
                        UIPasteboard.general.string = NotificationRouteDiagnostics.exportText()
                    } label: {
                        Label(L10n.text("ui.push_route_diagnostics_copy"), systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("settings.lockScreenApproval.copyRouteDiagnostics")
                }
            }
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle(L10n.text("ui.push_lock_screen_approval"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.lockScreenApproval.detail")
        .task {
            guard case .connected = appStore.connectionStatus else { return }
            await refresh()
        }
        .sheet(isPresented: $showsConsent) {
            LockScreenApprovalConsentSheet(
                providerHost: store.providerHost(for: appStore.activeConnectionProfileID) ?? "",
                isOfficialService: false,
                onAgree: {
                    store.recordConsent(for: appStore.activeConnectionProfileID)
                    showsConsent = false
                    let rebind = rebindAfterConsent
                    rebindAfterConsent = false
                    Task { await enable(rebind: rebind) }
                },
                onCancel: {
                    rebindAfterConsent = false
                    showsConsent = false
                }
            )
        }
        .alert(L10n.text("ui.push_rebind_confirm_title"), isPresented: $showsRebindConfirmation) {
            Button(L10n.text("ui.push_rebind_to_this_computer"), role: .destructive) {
                if store.hasConsented(for: appStore.activeConnectionProfileID) {
                    Task { await enable(rebind: true) }
                } else {
                    rebindAfterConsent = true
                    showsConsent = true
                }
            }
            Button(L10n.text("ui.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("ui.push_rebind_confirm_message"))
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(get: { store.notificationsEnabled }, set: { desired in
            store.setNotificationsEnabled(desired)
            if desired {
                Task { await refresh() }
            } else {
                Task { await disable() }
            }
        })
    }

    private func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard let activeID = appStore.activeConnectionProfileID,
              let activeClient = try? appStore.client() else { return }
        await store.refreshHostSupport(client: activeClient, profileID: activeID)
        let profileID = store.registeredProfileID ?? activeID
        do {
            let client = profileID == activeID ? activeClient
                : try await LockScreenApprovalRouting.client(profileID: profileID, appStore: appStore)
            await store.synchronize(client: client, profileID: profileID)
        } catch {
            if store.hasPendingDisable {
                await store.disable(client: nil, profileID: profileID, previousHostUnavailable: true)
            } else {
                store.markRegistrationFailed()
            }
        }
    }

    private func enable(rebind: Bool) async {
        isBusy = true
        defer { isBusy = false }
        guard let profileID = appStore.activeConnectionProfileID,
              let client = try? appStore.client() else { return }
        let previousID = store.registeredProfileID
        let previousClient: AgentAPIClient?
        if let previousID, previousID != profileID {
            previousClient = try? await LockScreenApprovalRouting.client(profileID: previousID, appStore: appStore)
        } else {
            previousClient = nil
        }
        // 只有明确换绑且旧电脑不可用时，才直接撤销旧服务凭据。
        let takeOver = rebind && (previousClient == nil || store.status == .previousHostUnavailable)
        await store.enable(
            client: client, profileID: profileID,
            previousClient: previousClient, previousClientProfileID: previousID,
            takeOverPreviousBinding: takeOver
        )
    }

    private func disable() async {
        isBusy = true
        defer { isBusy = false }
        let profileID = store.registeredProfileID ?? appStore.activeConnectionProfileID
        let client: AgentAPIClient?
        if let profileID, profileID != appStore.activeConnectionProfileID {
            client = try? await LockScreenApprovalRouting.client(profileID: profileID, appStore: appStore)
        } else {
            client = try? appStore.client()
        }
        await store.disable(client: client, profileID: profileID, previousHostUnavailable: client == nil)
    }
}

/// 披露清单单独抽出来，让设置页与测试引用同一份事实，避免两边描述漂移。
enum LockScreenApprovalDisclosure {
    static let leavesDeviceKeys = [
        "ui.push_disclosure_item_device_token",
        "ui.push_disclosure_item_tags",
        "ui.push_disclosure_item_kind",
        "ui.push_disclosure_item_expiry",
    ]

    static let staysOnDeviceKeys = [
        "ui.push_disclosure_item_no_prompt",
        "ui.push_disclosure_item_no_command",
        "ui.push_disclosure_item_no_files",
        "ui.push_disclosure_item_no_token",
    ]
}

struct LockScreenApprovalConsentSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let providerHost: String
    let isOfficialService: Bool
    let onAgree: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Form {
                Section {
                    Text(L10n.format("ui.push_consent_intro_value", providerHost))
                        .font(themeStore.uiFont(.subheadline))
                        .foregroundStyle(tokens.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                } footer: {
                    Text(isOfficialService
                        ? L10n.text("ui.push_consent_official_note")
                        : L10n.text("ui.push_consent_custom_note"))
                        .settingsSectionFooterStyle()
                }

                Section {
                    ForEach(LockScreenApprovalDisclosure.leavesDeviceKeys, id: \.self) { key in
                        Text(L10n.text(key))
                            .font(themeStore.uiFont(.subheadline))
                            .foregroundStyle(tokens.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text(L10n.text("ui.push_disclosure_leaves_device"))
                        .settingsSectionHeaderStyle()
                }

                Section {
                    ForEach(LockScreenApprovalDisclosure.staysOnDeviceKeys, id: \.self) { key in
                        Text(L10n.text(key))
                            .font(themeStore.uiFont(.subheadline))
                            .foregroundStyle(tokens.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text(L10n.text("ui.push_disclosure_stays_local"))
                        .settingsSectionHeaderStyle()
                } footer: {
                    Text(L10n.text("ui.push_consent_retention"))
                        .settingsSectionFooterStyle()
                }
            }
            .themedSettingsForm(tokens: tokens)
            .navigationTitle(L10n.text("ui.push_consent_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.push_consent_agree"), action: onAgree)
                        .accessibilityIdentifier("settings.lockScreenApproval.consent.agree")
                }
            }
        }
        .accessibilityIdentifier("settings.lockScreenApproval.consent")
    }
}
