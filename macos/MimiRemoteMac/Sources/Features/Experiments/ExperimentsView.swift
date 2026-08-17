import SwiftUI

/// Claude 与 Codex Desktop 的唯一控制面板。
///
/// 菜单栏和通用设置只负责导航到这里；开关仍由 HostStore 执行，避免在多个界面
/// 复制绑定或把菜单首层的点击误解为直接修改配置。
struct ExperimentsView: View {
    let store: HostStore
    @State private var confirmsCodexRestart = false

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
                Toggle("共享 Codex Desktop 会话（实验）", isOn: Binding(
                    get: { store.codexDesktopEnabled },
                    set: { enabled in
                        Task { await store.setCodexDesktopEnabled(enabled) }
                    }
                ))
                .disabled(!store.canChangeCodexDesktop)

                Text(ExperimentPresentation.codexToggleDescription(isEnabled: store.codexDesktopEnabled))
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

                if store.canRestartCodexDesktop {
                    Button("应用设置并完全重启 Codex Desktop") {
                        confirmsCodexRestart = true
                    }
                    .disabled(store.isCodexDesktopBusy)
                }
            }

            Section("边界") {
                Text("正在运行的 Desktop turn 仍只读，不会因为打开或保存实验设置而放宽保护。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 500, height: 680)
        .alert("应用 Codex 共享设置？", isPresented: $confirmsCodexRestart) {
            Button("取消", role: .cancel) {}
            Button("确认应用") {
                Task { await store.restartCodexDesktop() }
            }
        } message: {
            Text("请先保存任务。应用时会正常退出 Codex Desktop，再迁移共享 daemon 并验证结果；如果 Desktop 已退出，只迁移 daemon，不会擅自打开 App。该操作会短暂中断当前连接到 daemon 的手机、SSH 或 CLI。")
        }
    }
}

#if DEBUG
    #Preview("实验功能") {
        ExperimentsView(store: .preview(.ready))
    }
#endif
