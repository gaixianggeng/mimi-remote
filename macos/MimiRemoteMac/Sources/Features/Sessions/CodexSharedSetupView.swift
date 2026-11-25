import AppKit
import SwiftUI

/// 让 Codex 桌面版接入 Mimi 的共用服务（#991, #376）。三步实时检测；第 2 步支持零终端一键配置本机 SSH，第 3 步直达 Codex 连接页。
struct CodexSharedSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sessions.codexDesktopSharedSeen") private var sharedSeen = false
    @State private var status = CodexSharedSetupStatus()
    @State private var isChecking = false
    @State private var isConfiguringSSH = false
    @State private var isRemovingSSH = false
    @State private var actionError: String?
    @State private var showingManualCommand = false
    @State private var showingRemoveConfirm = false
    @State private var copied = false

    /// 检测与配置入口；测试里可注入假实现。
    var checker: @MainActor () async -> CodexSharedSetupStatus = { await CodexSharedSetupChecks.check() }
    var configureSSH: @Sendable () async throws -> Void = { try await CodexLocalSSHConfigurator().configure() }
    var removeSSH: @Sendable () throws -> Void = { try CodexLocalSSHConfigurator().remove() }

    var body: some View {
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

            if let actionError, !actionError.isEmpty {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("codexSetup.error")
            }

            step(1, title: "打开「远程登录」", state: status.remoteLogin) {
                Text("点击打开「系统设置 → 通用 → 共享」，打开「远程登录」开关即可。")
                Button("打开共享设置") { NSWorkspace.shared.open(CodexSharedSetupChecks.sharingSettingsURL) }
                    .buttonStyle(.borderedProminent)
            }

            step(2, title: "一键配置本机 SSH", state: status.passwordlessLogin) {
                Text("在 `~/.ssh` 生成一把仅限本机回环（127.0.0.1）使用的专用钥匙，并自动写入 `\(CodexLocalSSHConfigurator.hostAlias)` 主机项。不修改你原有的其他密钥，无需打开终端。")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                HStack(spacing: 10) {
                    Button {
                        Task { await runOneClickSSHSetup() }
                    } label: {
                        if isConfiguringSSH {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在配置并验证…")
                            }
                        } else {
                            Text("一键配置本机 SSH")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConfiguringSSH || isRemovingSSH || status.remoteLogin != .done)
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
                if status.localSSHManaged {
                    Text("点下方按钮直达 Codex 桌面版的「连接」设置页。列表中会自动出现「\(CodexLocalSSHConfigurator.hostAlias)」，点一下连接即可（无需手动填 IP）。")
                    Text("若列表暂未刷出「\(CodexLocalSSHConfigurator.hostAlias)」，重启一次 Codex 桌面版后就会出现；或者也可以手动添加主机名 127.0.0.1。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Codex 桌面版 → 设置 → 连接，添加主机名 127.0.0.1（或连接已自动发现的「\(CodexLocalSSHConfigurator.hostAlias)」），保存后等它连上。")
                }
                if status.desktopNotRunning {
                    Text("Codex 桌面版没有在运行，打开后会自动重新检查。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("打开 Codex 连接设置") {
                    Task { await CodexDesktopLink.openConnectionsSettings() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(status.passwordlessLogin != .done && status.remoteLogin != .done)
                .accessibilityIdentifier("codexSetup.openCodexConnectionsButton")
            }

            Divider()

            HStack {
                if isChecking {
                    ProgressView().controlSize(.small)
                    Text("正在检查…").foregroundStyle(.secondary)
                } else if status.localSSHManaged {
                    Button("移除本机 SSH 配置", role: .destructive) {
                        showingRemoveConfirm = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(isConfiguringSSH || isRemovingSSH)
                    .accessibilityIdentifier("codexSetup.removeSSHButton")
                }
                Spacer()
                Button("重新检查") { Task { await check() } }
                    .disabled(isChecking || isConfiguringSSH || isRemovingSSH)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task { await check() }
        // 用户从系统设置、终端或桌面版切回来时自动复查。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await check() }
        }
        .confirmationDialog(
            "移除由 Mimi 创建的本机 SSH 配置？",
            isPresented: $showingRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("移除配置", role: .destructive) {
                Task { await runRemoveSSHSetup() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除 Mimi 专用密钥、对应的本机回环授权行，以及 ~/.ssh/config 中的 \(CodexLocalSSHConfigurator.hostAlias) 托管块，不会影响你的其他 SSH 配置。")
        }
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        status = await checker()
        if status.allDone {
            sharedSeen = true
            actionError = nil
        }
    }

    private func runOneClickSSHSetup() async {
        guard !isConfiguringSSH else { return }
        isConfiguringSSH = true
        actionError = nil
        defer { isConfiguringSSH = false }
        do {
            try await configureSSH()
            await check()
        } catch {
            actionError = error.localizedDescription
            await check()
        }
    }

    private func runRemoveSSHSetup() async {
        guard !isRemovingSSH else { return }
        isRemovingSSH = true
        actionError = nil
        defer { isRemovingSSH = false }
        do {
            try removeSSH()
            sharedSeen = false
            await check()
        } catch {
            actionError = error.localizedDescription
            await check()
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
            // 做完的步骤只留标题，页面只展开还要做的事。
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(state == .done ? .secondary : .primary)
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
