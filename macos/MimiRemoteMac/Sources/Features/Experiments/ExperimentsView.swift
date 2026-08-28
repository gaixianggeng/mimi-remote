import SwiftUI

/// Claude 与 Codex Desktop 同步的唯一控制面板。
struct ExperimentsView: View {
    let store: HostStore
    @State private var confirmsLegacyCleanup = false

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

            Section("Codex Desktop") {
                Toggle("同步 Codex Desktop 会话（实验）", isOn: Binding(
                    get: { store.codexDesktopEnabled },
                    set: { enabled in
                        Task { await store.setCodexDesktopEnabled(enabled) }
                    }
                ))
                .disabled(!store.canChangeCodexDesktop)

                Text(ExperimentPresentation.codexToggleDescription(
                    isEnabled: store.codexDesktopEnabled
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("运行状态") {
                    HStack(spacing: 6) {
                        if store.isCodexDesktopBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(store.codexDesktopStatusTitle)
                    }
                }

                Text(store.codexDesktopStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let version = store.codexDesktopStatus.desktopVersion {
                    LabeledContent("Desktop 版本", value: version)
                }
                if let build = store.codexDesktopStatus.desktopBuild {
                    LabeledContent("Desktop build", value: build)
                }

                if store.codexDesktopStatus.state == .legacyCleanupRequired {
                    Button("清理旧共享配置…") {
                        confirmsLegacyCleanup = true
                    }
                    .disabled(store.isCodexDesktopBusy)
                }
            }

            Section("边界") {
                Text("同步使用已验证的 Desktop IPC。当前支持 Codex Desktop 26.820.60940 (7119) 和 26.825.31414 (7287)；普通开关只重载 agentd，不会退出或重开 Desktop。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 500, height: 680)
        .alert("清理旧共享配置？", isPresented: $confirmsLegacyCleanup) {
            Button("取消", role: .cancel) {}
            Button("确认清理", role: .destructive) {
                Task { await store.cleanupLegacyCodexDesktopSync() }
            }
        } message: {
            Text("请先完全退出 Codex Desktop。此次操作只删除 Mimi 旧共享模式的遗留配置，完成后再打开 Desktop；普通启停不会执行此操作。")
        }
    }
}

#if DEBUG
    #Preview("实验功能") {
        ExperimentsView(store: .preview(.ready))
    }
#endif
