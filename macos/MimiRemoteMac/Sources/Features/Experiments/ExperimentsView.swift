import SwiftUI

/// 实验功能只承载可独立启停、失败时不影响主连接的通道。
struct ExperimentsView: View {
    let store: HostStore

    @Environment(\.openWindow) private var openWindow
    @State private var confirmsTailcatReset = false

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
        .frame(width: 500, height: 620)
        .task {
            await store.refreshTailcatStatus()
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
    }
}

#if DEBUG
    #Preview("实验功能") {
        ExperimentsView(store: .preview(.ready))
    }
#endif
