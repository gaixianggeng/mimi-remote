import SwiftUI

struct MacSettingsView: View {
    let store: HostStore
    @State private var confirmsRestore = false
    @State private var confirmsCodexRestart = false

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录 Mac 时启动菜单栏和服务", isOn: Binding(
                    get: { store.launchesAtLogin },
                    set: { enabled in
                        Task { await store.setLaunchAtLogin(enabled) }
                    }
                ))
                Button("打开系统登录项设置…") {
                    store.openLoginItemsSettings()
                }
            }

            Section("服务") {
                LabeledContent("当前状态", value: store.lifecycle.title)
                LabeledContent("运行方式", value: ownerTitle)
                if let status = store.status {
                    LabeledContent("Endpoint", value: status.endpoint)
                    LabeledContent("agentd 版本", value: status.version)
                }
                if store.canRestoreHomebrew {
                    Button("停止 App 服务并恢复 Homebrew…", role: .destructive) {
                        confirmsRestore = true
                    }
                }
            }

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

            Section("Codex Desktop") {
                Toggle("共享本地 app-server 会话", isOn: Binding(
                    get: { store.codexDesktopEnabled },
                    set: { enabled in
                        Task { await store.setCodexDesktopEnabled(enabled) }
                    }
                ))
                .disabled(!store.canChangeCodexDesktop)

                LabeledContent("运行状态") {
                    HStack(spacing: 6) {
                        if store.isCodexDesktopBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(store.isCodexDesktopBusy ? "正在更新" : store.codexDesktopStatusTitle)
                    }
                }

                Text(store.codexDesktopStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("重启并应用设置") {
                    confirmsCodexRestart = true
                }
                .disabled(!store.canRestartCodexDesktop)

                Text("Mimi Remote 与 Codex Desktop 共享同一会话服务。仅 Desktop 没有进行中的任务时手机可继续；正在运行的任务仍只读。当前进程需要完全重启后才会应用设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("隐私") {
                Text("Mimi Remote Mac 不上传日志、代码、Token 或使用数据。长期 Token 只保存在 agentd 的私有配置中，App 只处理短期配对票据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 500, height: 640)
        .alert("恢复 Homebrew 服务？", isPresented: $confirmsRestore) {
            Button("取消", role: .cancel) {}
            Button("停止 App 服务并恢复", role: .destructive) {
                Task { await store.restoreHomebrew() }
            }
        } message: {
            Text("切换期间移动设备会短暂断开；Homebrew 启动失败时会自动恢复 App 服务。")
        }
        .alert("重启 Codex Desktop 并应用设置？", isPresented: $confirmsCodexRestart) {
            Button("取消", role: .cancel) {}
            Button("重启并应用") {
                Task { await store.restartCodexDesktop() }
            }
        } message: {
            Text("Mimi Remote 会先请求 Codex Desktop 正常退出，等待进程完全结束后再启动同一个 App。请先保存进行中的工作；不会强制终止，也不会并存启动第二个实例。")
        }
    }

    private var ownerTitle: String {
        switch store.owner {
        case .none: "未运行"
        case .macApp: "Mimi Remote Mac"
        case .homebrew: "Homebrew"
        }
    }
}
