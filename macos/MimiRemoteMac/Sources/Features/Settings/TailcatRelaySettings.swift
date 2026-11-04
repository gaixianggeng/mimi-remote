import AppKit
import Foundation
import SwiftUI

private enum TailcatRelayMode: String, CaseIterable, Identifiable {
    case tailcatDefault
    case custom
    case mimi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tailcatDefault: "默认 Tailcat 自带"
        case .custom: "使用自己的"
        case .mimi: "Mimi 中转"
        }
    }
}

/// 三种中转共用一个入口；内部连接模式由配置动作处理，不要求用户先切换模式。
struct TailcatRelaySettings: View {
    let store: HostStore
    var onApplied: (() -> Void)? = nil

    @Environment(\.openWindow) private var openWindow
    @State private var confirmsTailcatReset = false
    @State private var confirmsRelayChange = false
    @State private var isApplyingRelay = false
    @State private var relayMode: TailcatRelayMode = .tailcatDefault
    @State private var customDERPMapURL = ""
    @FocusState private var focusesRelayURL: Bool

    var body: some View {
        Section("中转服务") {
            Picker("中转服务", selection: $relayMode) {
                ForEach(TailcatRelayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(store.isBusy || isApplyingRelay)

            switch relayMode {
            case .tailcatDefault:
                Text("免费使用 Tailcat 自带中转，无需配置。Mimi 全部功能均可使用。")
                    .font(.caption).foregroundStyle(.secondary)
            case .custom:
                TextField("DERP Map HTTPS 地址", text: $customDERPMapURL)
                    .textFieldStyle(.roundedBorder)
                    .environment(\.layoutDirection, .leftToRight)
                    .focused($focusesRelayURL)
                Text("填写你自己部署的中转配置地址。更换后，手机需要重新扫码。")
                    .font(.caption).foregroundStyle(.secondary)
                if let relayValidationMessage {
                    Text(relayValidationMessage).font(.caption).foregroundStyle(.red)
                }
            case .mimi:
                Text("用手机扫描接下来的二维码，通过邀请码或订阅开通，自动完成配置。已开通的手机可直接连接。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            LabeledContent("当前中转", value: currentRelayMode.title)
            HStack {
                Button(relayMode == .mimi ? "继续并扫码开通" : "使用此中转") {
                    if needsReconnectionConfirmation {
                        confirmsRelayChange = true
                    } else {
                        Task { await applySelection() }
                    }
                }
                .disabled(!store.canChangeTailcat || isApplyingRelay || relayValidationMessage != nil)
                if store.isUpdatingTailcat { ProgressView().controlSize(.small) }
            }
            if let error = store.tailcatError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let notice = store.tailcatNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("配对与恢复") {
            Button("生成配对二维码") { Task { await showPairing() } }
                .disabled(!store.canPair || !store.availablePairingNetworks.contains(.tailcat) || store.isBusy)
            Button("重置内置连接…", role: .destructive) { confirmsTailcatReset = true }
                .disabled(!store.canChangeTailcat || !store.tailcatEnabled)
        }
        .task {
            await store.refreshTailcatStatus()
            relayMode = currentRelayMode
            if !store.tailcatIsManaged { customDERPMapURL = store.tailcatDERPMapURL }
        }
        .onChange(of: relayMode) { _, mode in
            focusesRelayURL = mode == .custom
        }
        .confirmationDialog("更换中转服务？", isPresented: $confirmsRelayChange, titleVisibility: .visible) {
            Button("更换并重新配对") { Task { await applySelection() } }
        } message: {
            Text("本机的内置连接会短暂重连，使用该线路的手机可能需要重新扫码。Tailscale 和局域网连接不受影响。")
        }
        .confirmationDialog("重置内置连接？", isPresented: $confirmsTailcatReset, titleVisibility: .visible) {
            Button("重置内置连接", role: .destructive) { Task { await store.resetTailcat() } }
        } message: {
            Text("所有通过内置连接配对的设备需要重新扫码。Tailscale 和局域网连接不受影响。")
        }
    }

    private var currentRelayMode: TailcatRelayMode {
        if store.tailcatIsManaged { return .mimi }
        return store.tailcatDERPMapURL.isEmpty ? .tailcatDefault : .custom
    }

    private var selectedDERPMapURL: String {
        relayMode == .tailcatDefault ? "" : customDERPMapURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var needsReconnectionConfirmation: Bool {
        store.tailcatEnabled && relayMode != .mimi &&
            (store.tailcatIsManaged || selectedDERPMapURL != store.tailcatDERPMapURL)
    }

    private var relayValidationMessage: String? {
        guard relayMode == .custom else { return nil }
        let value = selectedDERPMapURL
        guard !value.isEmpty else { return "请输入完整的 DERP Map HTTPS 地址。" }
        // 官方地址要求开通授权，不能作为自建地址保存后才发现错误并断开现有配置。
        if value == "https://api.code89757.com/v1/relay/tailcat-derp-map.json" {
            return "使用 Mimi 中转时，请直接选择“Mimi 中转”。"
        }
        guard value.count <= 2048,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.fragment == nil
        else { return "请输入不含账号、密码或片段的完整 HTTPS 地址。" }
        return nil
    }

    private func applySelection() async {
        guard !isApplyingRelay else { return }
        isApplyingRelay = true
        defer { isApplyingRelay = false }
        let selectedMode = relayMode
        let selectedURL = selectedDERPMapURL
        if selectedMode == .mimi {
            await store.setTailcatManagedMode(true)
            guard store.tailcatError == nil, store.tailcatIsManaged else { return }
            if !store.tailcatEnabled { await store.setTailcatEnabled(true) }
        } else {
            // 先退出 Mimi 的配置，再保存用户选择；每一步都依据 agentd 回读，失败即停止。
            if store.tailcatIsManaged {
                await store.setTailcatManagedMode(false)
                guard store.tailcatError == nil, !store.tailcatIsManaged else { return }
            }
            await store.configureTailcatDERPMap(selectedURL)
        }
        guard store.tailcatError == nil else { return }
        if !store.tailcatEnabled { await store.setTailcatEnabled(true) }
        guard store.tailcatError == nil else { return }
        if store.tailcatEnabled { await showPairing() }
        if store.lastError == nil { onApplied?() }
    }

    private func showPairing() async {
        await store.refreshPairing(network: .tailcat)
        if store.pairingNetwork == .tailcat, store.pairing != nil {
            openWindow(id: AppWindow.pairing.rawValue)
        }
    }
}
