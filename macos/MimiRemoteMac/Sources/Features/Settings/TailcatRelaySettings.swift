import AppKit
import Foundation
import SwiftUI

private enum TailcatRelayMode: String, CaseIterable, Identifiable {
    case tailcatDefault
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tailcatDefault: "Tailcat 默认"
        case .custom: "自定义"
        }
    }
}

private enum RelayInputField: Hashable {
    case derpMapURL
}

/// Advanced Tailcat settings remain in Settings, not a separate experiment window.
struct TailcatRelaySettings: View {
    let store: HostStore

    @Environment(\.openWindow) private var openWindow
    @State private var confirmsTailcatReset = false
    @State private var confirmsRelayChange = false
    @State private var confirmsExitManaged = false
    @State private var relayMode: TailcatRelayMode = .tailcatDefault
    @State private var customDERPMapURL = ""
    @FocusState private var focusedInputField: RelayInputField?

    var body: some View {
        Group {
            managedConnectionSection

            Section("Tailcat 中继与配对") {
                Text(store.tailcatStatusDetail).font(.caption).foregroundStyle(.secondary)
                if store.tailcatIsManaged {
                    // 托管模式的中继由 Mimi 管理，agentd 会拒绝手动修改；这里不给入口。
                    LabeledContent("当前中继") {
                        Text("Mimi 中转")
                    }
                    Text("Mimi 中转由服务统一配置。如需自定义免费中继，请先停用本机 Mimi 中转。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    relayConfigurationRows
                }

                HStack {
                    Button("生成配对二维码") {
                        Task {
                            await store.refreshPairing(network: .tailcat)
                            if store.pairingNetwork == .tailcat {
                                openWindow(id: AppWindow.pairing.rawValue)
                            }
                        }
                    }
                    .disabled(!store.canPair || !store.availablePairingNetworks.contains(.tailcat) || store.isBusy)

                    Spacer()

                    Button("重置 Tailcat…", role: .destructive) {
                        confirmsTailcatReset = true
                    }
                    .disabled(!store.canChangeTailcat || !store.tailcatEnabled)
                }

                Text("重置会更换主机身份并取消所有 Tailcat 配对。Tailscale、局域网和当前 agentd 会话不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await store.refreshTailcatStatus()
            syncRelayConfiguration()
            focusDERPMapInputIfNeeded()
        }
        .onChange(of: relayMode) { _, _ in
            focusDERPMapInputIfNeeded()
        }
        .onChange(of: store.tailcatDERPMapURL) { _, _ in
            syncRelayConfiguration()
        }
        .confirmationDialog(
            "退出 Mimi 中转服务？",
            isPresented: $confirmsExitManaged,
            titleVisibility: .visible
        ) {
            Button("停用本机 Mimi 中转", role: .destructive) {
                Task { await store.setTailcatManagedMode(false) }
            }
        } message: {
            Text("停用会影响本机所有使用 Mimi 中转的设备。新版手机会尝试已保存的免费连接；没有备用线路的旧设备需要重新扫码。")
        }
        .confirmationDialog(
            "重置 Tailcat？",
            isPresented: $confirmsTailcatReset,
            titleVisibility: .visible
        ) {
            Button("重置 Tailcat", role: .destructive) {
                Task { await store.resetTailcat() }
            }
        } message: {
            Text("所有已配对设备需要重新扫码。这个操作不会关闭 Tailscale。")
        }
        .confirmationDialog(
            "应用新的 Tailcat 中继？",
            isPresented: $confirmsRelayChange,
            titleVisibility: .visible
        ) {
            Button(store.tailcatEnabled ? "应用并重新配对" : "保存中继配置") {
                Task { await store.configureTailcatDERPMap(selectedDERPMapURL) }
            }
        } message: {
            if store.tailcatEnabled {
                Text("Tailcat 会短暂重连，并取消现有 Tailcat 配对。失败时会恢复原中继。Tailscale 和局域网连接不受影响。")
            } else {
                Text("配置会在下次启用 Tailcat 时生效。Tailscale 和局域网连接不受影响。")
            }
        }
    }

    /// 服务资格在手机上管理；电脑只展示本机能力，并保留高级停用入口。
    private var managedConnectionSection: some View {
        Section("Mimi 中转服务") {
            LabeledContent("连接方式") {
                Text(store.tailcatIsManaged ? "Mimi 中转已启用 · 免费连接仍可用" : "免费线路")
            }

            Text(
                store.tailcatIsManaged
                    ? "本机已准备好 Mimi 中转。实际是否经过中转取决于网络，能够直连时优先直连。"
                    : "Mimi 全部功能免费。先用内置连接扫码；在手机「我的 → Mimi 中转服务」开通后，这台电脑会自动启用。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                if store.tailcatIsManaged {
                    Button("停用本机 Mimi 中转…", role: .destructive) {
                        confirmsExitManaged = true
                    }
                    .disabled(!store.canChangeTailcat)
                }

                Spacer()

                if store.isUpdatingTailcat {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var relayConfigurationRows: some View {
        Picker("中继节点", selection: $relayMode) {
            ForEach(TailcatRelayMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        if relayMode == .custom {
            VStack(alignment: .leading, spacing: 8) {
                Text("DERP Map HTTPS 地址")

                TextField(
                    "DERP Map HTTPS 地址",
                    text: $customDERPMapURL,
                    prompt: Text("粘贴完整的 HTTPS 地址")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .environment(\.layoutDirection, .leftToRight)
                .focused($focusedInputField, equals: .derpMapURL)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let relayValidationMessage {
                Text(relayValidationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        LabeledContent("当前中继") {
            Text(currentRelayTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(store.tailcatDERPMapURL)
        }

        HStack {
            Button("应用中继配置…") {
                confirmsRelayChange = true
            }
            .disabled(
                !store.canChangeTailcat ||
                    relayValidationMessage != nil ||
                    !relayConfigurationChanged
            )

            Spacer()
        }

        Text("DERP Map 是描述可用中继节点的配置地址。自定义地址必须使用 HTTPS。Tailcat 关闭时只保存地址，启用后才验证连通性。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var selectedDERPMapURL: String {
        relayMode == .tailcatDefault
            ? ""
            : customDERPMapURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var relayConfigurationChanged: Bool {
        selectedDERPMapURL != store.tailcatDERPMapURL
    }

    private var currentRelayTitle: String {
        store.tailcatDERPMapURL.isEmpty ? "Tailcat 默认" : store.tailcatDERPMapURL
    }

    private var relayValidationMessage: String? {
        guard relayMode == .custom else { return nil }
        let value = selectedDERPMapURL
        guard !value.isEmpty else { return "请输入完整的 DERP Map HTTPS 地址。" }
        guard value.count <= 2048,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else {
            return "请输入不含账号、密码或片段的完整 HTTPS 地址。"
        }
        return nil
    }

    private func syncRelayConfiguration() {
        let configuredURL = store.tailcatDERPMapURL
        relayMode = configuredURL.isEmpty ? .tailcatDefault : .custom
        if !configuredURL.isEmpty {
            customDERPMapURL = configuredURL
        }
    }

    private func focusDERPMapInputIfNeeded() {
        guard relayMode == .custom else {
            focusedInputField = nil
            return
        }
        // 菜单栏 App 的独立窗口出现后，再把键盘焦点交给输入框，避免焦点留在 MenuBarExtra。
        DispatchQueue.main.async {
            focusedInputField = .derpMapURL
        }
    }
}
