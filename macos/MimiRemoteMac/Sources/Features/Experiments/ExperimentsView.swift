import SwiftUI

/// Claude 与 Codex Desktop 的唯一控制面板。
///
/// 菜单栏和通用设置只负责导航到这里；开关仍由 HostStore 执行，避免在多个界面
/// 复制绑定或把菜单首层的点击误解为直接修改配置。
struct ExperimentsView: View {
    let store: HostStore
    @State private var confirmsCodexRestart = false
    @State private var disablesCodexFromToggle = false

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
                        if enabled {
                            Task { await store.setCodexDesktopEnabled(true) }
                        } else {
                            // 关闭会终止 Desktop 并停止旧共享 daemon，必须先取得
                            // 明确确认；取消时不写偏好，也不产生待处理半状态。
                            disablesCodexFromToggle = true
                            confirmsCodexRestart = true
                        }
                    }
                ))
                .disabled(!store.canChangeCodexDesktop)

                Text(ExperimentPresentation.codexToggleDescription(
                    isEnabled: store.codexDesktopEnabled,
                    isPending: store.codexDesktopStatus.state == .pendingRestart
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

                if store.canRestartCodexDesktop {
                    Button("应用设置并完全重启 Codex Desktop") {
                        disablesCodexFromToggle = false
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
        .alert(
            disablesCodexFromToggle || !store.codexDesktopEnabled
                ? "切换到独立 Codex 服务？"
                : "启用 Codex 共享服务？",
            isPresented: $confirmsCodexRestart
        ) {
            Button("取消", role: .cancel) {
                disablesCodexFromToggle = false
            }
            Button(
                disablesCodexFromToggle || !store.codexDesktopEnabled
                    ? "切换并重启"
                    : "启用并重启"
            ) {
                let shouldDisable = disablesCodexFromToggle
                disablesCodexFromToggle = false
                Task {
                    if shouldDisable {
                        await store.setCodexDesktopEnabled(false)
                    } else {
                        await store.restartCodexDesktop()
                    }
                }
            }
        } message: {
            if disablesCodexFromToggle || !store.codexDesktopEnabled {
                Text("请先保存任务。Codex Desktop 会正常退出；Mimi 会停止旧共享服务，确认会话已释放后再启动独立服务，然后重新打开 Desktop。")
            } else {
                Text("请先保存任务。Codex Desktop 会正常退出；Mimi 会迁移并验证共享服务，然后重新打开 Desktop。该操作会短暂中断手机、SSH 或 CLI 连接。")
            }
        }
    }
}

#if DEBUG
    #Preview("实验功能") {
        ExperimentsView(store: .preview(.ready))
    }
#endif
