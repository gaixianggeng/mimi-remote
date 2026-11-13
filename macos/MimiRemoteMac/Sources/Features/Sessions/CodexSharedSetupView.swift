import AppKit
import SwiftUI

/// 让 Codex 桌面版接入 Mimi 的共用服务（#991）。三步各自实时检测，只说明和检测，不替用户改设置。
struct CodexSharedSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sessions.codexDesktopSharedSeen") private var sharedSeen = false
    @State private var status = CodexSharedSetupStatus()
    @State private var isChecking = false
    @State private var copied = false
    /// 检测入口；测试里换成固定结果。
    var checker: @MainActor () async -> CodexSharedSetupStatus = { await CodexSharedSetupChecks.check() }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("让 Codex 桌面版和手机同时使用")
                    .font(.title3.weight(.semibold))
                Text("接好后，在电脑上打开会话会直接接上，手机和电脑可以同时使用同一条会话。只需设置一次。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status.allDone {
                Label("已经接好。以后在 Codex 桌面版打开会话会直接接上。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("codexSetup.done")
            }

            step(1, title: "打开「远程登录」", state: status.remoteLogin) {
                Text("系统设置 → 通用 → 共享，打开「远程登录」。")
                Button("打开共享设置") { NSWorkspace.shared.open(CodexSharedSetupChecks.sharingSettingsURL) }
            }

            step(2, title: "允许本机免密登录", state: status.passwordlessLogin) {
                Text("在终端里运行下面的命令。它在本机生成一把登录钥匙，只允许你从本机登录自己的账户，不改其他设置。看到「完成」就好了。")
                // 命令不折行，折行后像多出来的命令；放不下时横向滚动。
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
            }

            step(3, title: "在 Codex 桌面版添加本机", state: status.desktopConnected) {
                Text("Codex 桌面版 → 设置 → 连接，在「来自这台 Mac 的 SSH 连接」旁点「添加」。主机名填 127.0.0.1，显示名称填「本机」，其余保持默认，保存后等它连上。")
                if status.desktopNotRunning {
                    Text("Codex 桌面版没有在运行，打开后会自动重新检查。")
                        .foregroundStyle(.secondary)
                }
                Button("打开 Codex 桌面版") { openCodexDesktop() }
            }

            Divider()

            HStack {
                if isChecking {
                    ProgressView().controlSize(.small)
                    Text("正在检查…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新检查") { Task { await check() } }
                    .disabled(isChecking)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
        .task { await check() }
        // 用户从系统设置、终端或桌面版切回来时自动复查。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await check() }
        }
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        status = await checker()
        if status.allDone { sharedSeen = true }
    }

    private func openCodexDesktop() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SessionOpenTarget.codexDesktopBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
