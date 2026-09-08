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

private enum ExperimentInputField: Hashable {
    case derpMapURL
}

/// 实验功能只承载可独立启停、失败时不影响主连接的通道。
struct ExperimentsView: View {
    let store: HostStore

    @Environment(\.openWindow) private var openWindow
    @State private var confirmsTailcatReset = false
    @State private var confirmsRelayChange = false
    @State private var relayMode: TailcatRelayMode = .tailcatDefault
    @State private var customDERPMapURL = ""
    @FocusState private var focusedInputField: ExperimentInputField?

    var body: some View {
        Form {
            Section("Claude") {
                Toggle("启用 Claude 实验通道", isOn: Binding(
                    get: { store.claudeEnabled },
                    set: { enabled in
                        Task { await store.setClaudeEnabled(enabled) }
                    }
                ))
                .disabled(!store.canChangeClaude)

                LabeledContent("运行状态") {
                    HStack(spacing: 6) {
                        if store.isUpdatingClaude {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(store.isUpdatingClaude ? "正在更新" : store.claudeStatusTitle)
                    }
                }

                Text(store.claudeStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("需要本机安装并登录 Claude Code。启用或关闭时会安全地重新加载 agentd；Codex 主通道不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tailcat") {
                Toggle("启用 Tailcat 实验通道", isOn: Binding(
                    get: { store.tailcatEnabled },
                    set: { enabled in
                        Task { await store.setTailcatEnabled(enabled) }
                    }
                ))
                .disabled(!store.canChangeTailcat)

                LabeledContent("运行状态") {
                    HStack(spacing: 6) {
                        if store.isUpdatingTailcat {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(store.tailcatStatusTitle)
                    }
                }

                Text(store.tailcatStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

                HStack {
                    Button("生成配对二维码") {
                        Task {
                            await store.refreshPairing(network: .tailcat)
                            if store.pairingNetwork == .tailcat {
                                openWindow(id: AppWindow.pairing.rawValue)
                            }
                        }
                    }
                    .disabled(!store.tailcatEnabled || store.isUpdatingTailcat)

                    Spacer()

                    Button("重置 Tailcat…", role: .destructive) {
                        confirmsTailcatReset = true
                    }
                    .disabled(!store.tailcatEnabled || store.isUpdatingTailcat)
                }

                Text("重置会更换主机身份并取消所有 Tailcat 配对。Tailscale、局域网和当前 agentd 会话不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 520, height: 720)
        .background(ExperimentWindowActivationGuard())
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
            "重置 Tailcat 实验？",
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

/// LSUIElement 创建 SwiftUI Window 时不一定自动成为 key window；在内容真正挂载后再激活。
private struct ExperimentWindowActivationGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ExperimentWindowProbeView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ExperimentWindowProbeView: NSView {
    private weak var activatedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, activatedWindow !== window else { return }
        activatedWindow = window

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

#if DEBUG
    #Preview("实验功能") {
        ExperimentsView(store: .preview(.ready))
    }
#endif
