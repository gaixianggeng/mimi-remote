import SwiftUI

/// 锁屏审批提醒的设置入口。
///
/// 这是默认关闭的实验功能。首次开启必须先看到明确的数据披露：什么会离开这台
/// 设备、什么不会、由谁接收、保留多久。没有同意就不注册任何东西。
struct LockScreenApprovalSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var store: LockScreenApprovalStore

    @State private var isBusy = false
    @State private var showsConsent = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                Toggle(isOn: toggleBinding) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("ui.push_lock_screen_approval"))
                            .font(themeStore.uiFont(.body))
                            .foregroundStyle(tokens.primaryText)
                        Text(statusDescription)
                            .font(themeStore.uiFont(.footnote))
                            .foregroundStyle(statusIsProblem ? tokens.warning : tokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(isBusy || !store.hostSupportsPush)
                .accessibilityIdentifier("settings.lockScreenApproval.toggle")
            } header: {
                Text(L10n.text("ui.experimental_features"))
                    .textCase(nil)
            } footer: {
                Text(L10n.text("ui.push_lock_screen_approval_summary"))
            }

            if !store.hostSupportsPush {
                Section {
                    Label {
                        Text(L10n.text("ui.push_host_not_configured"))
                            .font(themeStore.uiFont(.subheadline))
                            .foregroundStyle(tokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(tokens.accent)
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("settings.lockScreenApproval.hostNotice")
                }
            }

            Section {
                ForEach(LockScreenApprovalDisclosure.leavesDeviceKeys, id: \.self) { key in
                    disclosureRow(key: key, symbol: "arrow.up.forward", tint: tokens.accent, tokens: tokens)
                }
            } header: {
                Text(L10n.text("ui.push_disclosure_leaves_device"))
                    .textCase(nil)
            } footer: {
                Text(receiverDescription)
            }

            Section {
                ForEach(LockScreenApprovalDisclosure.staysOnDeviceKeys, id: \.self) { key in
                    disclosureRow(key: key, symbol: "lock", tint: tokens.secondaryText, tokens: tokens)
                }
            } header: {
                Text(L10n.text("ui.push_disclosure_stays_local"))
                    .textCase(nil)
            } footer: {
                Text(L10n.text("ui.push_disclosure_actionable_kinds"))
            }
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle(L10n.text("ui.push_lock_screen_approval"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.lockScreenApproval.detail")
		.task {
			guard let client = try? appStore.client() else { return }
			await store.refreshHostSupport(client: client)
			if let profileID = store.registeredProfileID ?? appStore.activeConnectionProfileID,
			   let refreshClient = profileID == appStore.activeConnectionProfileID
				? client
				: try? await LockScreenApprovalRouting.client(profileID: profileID, appStore: appStore) {
				await store.refreshTicketIfNeeded(client: refreshClient, profileID: profileID)
			}
        }
        .sheet(isPresented: $showsConsent) {
            LockScreenApprovalConsentSheet(
                providerHost: store.providerHost ?? "",
                isOfficialService: store.providerIsOfficial,
                onAgree: {
                    showsConsent = false
                    store.recordConsent()
                    Task { await enable() }
                },
                onCancel: { showsConsent = false }
            )
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { store.isEnabled },
            set: { desired in
                guard !isBusy else { return }
                if desired {
                    // 没同意过当前收件主机就先弹披露；同意本身就是开启动作的一部分。
                    if store.hasConsented {
                        Task { await enable() }
                    } else {
                        showsConsent = true
                    }
                } else {
                    Task { await disable() }
                }
            }
        )
    }

    private func enable() async {
        isBusy = true
        defer { isBusy = false }
		guard let client = try? appStore.client(),
			  let profileID = appStore.activeConnectionProfileID else { return }
		await store.enable(client: client, profileID: profileID)
    }

	private func disable() async {
		isBusy = true
		defer { isBusy = false }
		let client: AgentAPIClient?
		if let profileID = store.registeredProfileID,
		   profileID != appStore.activeConnectionProfileID {
			client = try? await LockScreenApprovalRouting.client(profileID: profileID, appStore: appStore)
		} else {
			client = try? appStore.client()
		}
		await store.disable(client: client)
	}

    private var statusIsProblem: Bool {
        switch store.status {
        case .notificationsDenied, .failed, .unavailableOnHost:
            return true
        case .off, .registering, .active:
            return false
        }
    }

    private var statusDescription: String {
        switch store.status {
        case .off:
            return L10n.text("ui.push_status_off")
        case .unavailableOnHost:
            return L10n.text("ui.push_status_unavailable_on_host")
        case .notificationsDenied:
            return L10n.text("ui.push_status_notifications_denied")
        case .registering:
            return L10n.text("ui.push_status_registering")
        case .active(let expiresAt):
            return L10n.format("ui.push_status_active_until_value", Self.expiryFormatter.string(from: expiresAt))
        case .failed(let message):
            return message
        }
    }

    private var receiverDescription: String {
        guard let host = store.providerHost, !host.isEmpty else {
            return L10n.text("ui.push_receiver_unknown")
        }
        return store.providerIsOfficial
            ? L10n.format("ui.push_receiver_official_value", host)
            : L10n.format("ui.push_receiver_custom_value", host)
    }

    private func disclosureRow(key: String, symbol: String, tint: Color, tokens: ThemeTokens) -> some View {
        Label {
            Text(L10n.text(key))
                .font(themeStore.uiFont(.subheadline))
                .foregroundStyle(tokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
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
                        .textCase(nil)
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
                        .textCase(nil)
                } footer: {
                    Text(L10n.text("ui.push_consent_retention"))
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
