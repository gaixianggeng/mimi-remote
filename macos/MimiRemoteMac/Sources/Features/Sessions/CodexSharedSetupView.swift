import AppKit
import SwiftUI

/// 让 Codex 桌面版接入 Mimi 的共用服务（#991, #376）。三步实时检测；第 2 步支持零终端一键配置本机 SSH，第 3 步直达 Codex SSH 设置页。
struct CodexSharedSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: CodexSharedSetupCoordinator
    @State private var showingManualCommand = false
    @State private var showingRemoveConfirm = false
    @State private var copied = false

    init(coordinator: CodexSharedSetupCoordinator = .shared) {
        self.coordinator = coordinator
    }

    static func stepAccessibilityLabel(number: Int, title: String, state: CodexSharedSetupStatus.Step) -> String {
        "第 \(number) 步：\(title)，\(state.accessibilityStatusText)"
    }

    var body: some View {
        let status = coordinator.status
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("让 Codex 桌面版和手机同时使用")
                    .font(.title3.weight(.semibold))
                Text("接好后，在 Codex 桌面版通过本机共享连接打开项目，手机和电脑就能实时共用同一条会话，不再互锁。只需设置一次。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status.allDone {
                Label("已经接好。现在在 Codex 桌面版和手机可以同时使用同一条会话。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("codexSetup.done")
            }

            if let actionError = coordinator.actionError, !actionError.isEmpty {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("codexSetup.error")
            }

            if let desktopFeedback = coordinator.desktopOpenFeedback, !desktopFeedback.isEmpty {
                Label(
                    desktopFeedback,
                    systemImage: coordinator.desktopOpenFeedbackIsError ? "exclamationmark.triangle.fill" : "info.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(coordinator.desktopOpenFeedbackIsError ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("codexSetup.desktopFeedback")
            }

            step(1, title: "打开「远程登录」", state: status.remoteLogin) {
                Text("点击打开「系统设置 → 通用 → 共享」，打开「远程登录」开关即可。")
                Button("打开共享设置") { NSWorkspace.shared.open(CodexSharedSetupChecks.sharingSettingsURL) }
                    .buttonStyle(.borderedProminent)
            }

            step(2, title: "一键配置本机 SSH", state: status.passwordlessLogin) {
                Text("在独立目录 `~/.ssh/mimi/` 生成仅限本机回环（127.0.0.1）使用的专用钥匙、主机配置与独立信任文件，并只在 `~/.ssh/config` 顶部加入一行 Include 与在 `authorized_keys` 追加一行受限公钥。不修改你原有的其他 SSH 配置，无需打开终端。")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                HStack(spacing: 10) {
                    Button {
                        Task { await coordinator.runOneClickSSHSetup() }
                    } label: {
                        if coordinator.isConfiguringSSH {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在配置并验证…")
                            }
                        } else {
                            Text("一键配置本机 SSH")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.isMutating || status.remoteLogin != .done)
                    .accessibilityIdentifier("codexSetup.oneClickSSHButton")

                    if status.remoteLogin != .done {
                        Text("请先完成第 1 步")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DisclosureGroup("手动终端命令（高级）", isExpanded: $showingManualCommand) {
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView(.horizontal) {
                            Text(CodexSharedSetupChecks.keySetupCommand)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize()
                                .padding(8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                        Button(copied ? "已复制" : "复制命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(CodexSharedSetupChecks.keySetupCommand, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            step(3, title: "在 Codex 桌面版连接本机", state: status.desktopConnected) {
                if status.managedAliasReady {
                    Text("点下方按钮打开 Codex 桌面版的 SSH 设置页，按「添加 → 选择 \(CodexLocalSSHConfigurator.hostAlias) → 保存并连接 → 选择项目」完成接入。")
                    Text("如果桌面版没有直接跳到 SSH 页，可手动进入「设置 → 连接 → SSH」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if status.legacyLoopbackReady {
                        Text("如需，也可改用已验证可用的 127.0.0.1 主机名。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if status.legacyLoopbackReady {
                    Text("已检测到本机 127.0.0.1 免密登录可用。点下方按钮打开 Codex 桌面版连接设置，在「设置 → 连接 → SSH」按「添加 → 输入 127.0.0.1 → 保存并连接 → 选择项目」完成接入。")
                } else {
                    Text("完成第 2 步后，点下方按钮打开 Codex 桌面版 SSH 设置页，按「添加 → 选择 \(CodexLocalSSHConfigurator.hostAlias) → 保存并连接 → 选择项目」完成接入（也可手动进入「设置 → 连接 → SSH」）。")
                }
                if status.desktopNotRunning {
                    Text("Codex 桌面版当前未运行；点击下方按钮会直接启动它，连上项目后回到这里会自动更新状态。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(status.managedAliasReady ? "打开 Codex SSH 设置" : "打开 Codex 连接设置") {
                    Task { await coordinator.openCodexSSHSettings() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(status.passwordlessLogin != .done || coordinator.isMutating)
                .accessibilityIdentifier("codexSetup.openCodexConnectionsButton")
            }

            Divider()

            HStack {
                if coordinator.isChecking {
                    ProgressView().controlSize(.small)
                    Text("正在检查…").foregroundStyle(.secondary)
                } else if status.localSSHManaged {
                    Button("移除本机 SSH 配置", role: .destructive) {
                        showingRemoveConfirm = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(coordinator.isMutating)
                    .accessibilityIdentifier("codexSetup.removeSSHButton")
                }
                Spacer()
                Button("重新检查") { Task { await coordinator.refresh(clearErrorWhenAllDone: true) } }
                    .disabled(coordinator.isChecking || coordinator.isMutating)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task {
            if !coordinator.isMutating {
                await coordinator.refresh(clearErrorWhenAllDone: coordinator.actionError == nil)
            }
        }
        // 用户从系统设置、终端或桌面版切回来时自动复查。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !coordinator.isMutating else { return }
            Task { await coordinator.refresh(clearErrorWhenAllDone: coordinator.actionError == nil) }
        }
        .confirmationDialog(
            "移除由 Mimi 创建的本机 SSH 配置？",
            isPresented: $showingRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("移除配置", role: .destructive) {
                Task { await coordinator.runRemoveSSHSetup() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除 `~/.ssh/mimi/` 中经归属核验的专用密钥、独立配置与主机信任文件，撤销对应的本机回环受限授权行，并只删除 `~/.ssh/config` 顶部的 Mimi Include 行，不会影响你的其他 SSH 配置。")
        }
    }

    private func step<Content: View>(
        _ number: Int,
        title: String,
        state: CodexSharedSetupStatus.Step,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch state {
                case .checking:
                    ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .todo:
                    Image(systemName: "\(number).circle").foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            // 做完的步骤只留标题，页面只展开还要做的事。
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(state == .done ? .secondary : .primary)
                    .accessibilityLabel(Self.stepAccessibilityLabel(number: number, title: title, state: state))
                    .accessibilityAddTraits(.isHeader)
                if state != .done {
                    content()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codexSetup.step\(number)")
    }
}
