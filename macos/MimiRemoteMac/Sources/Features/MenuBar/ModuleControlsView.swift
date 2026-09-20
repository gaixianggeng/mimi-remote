import AppKit
import SwiftUI

/// Menu and Settings share one set of actions and the same HostStore snapshots.
struct ModuleControlsGroup: View {
    let store: HostStore
    let group: HostModuleGroup
    @State private var expanded: Set<HostModuleID> = []
    @State private var undoModule: HostModuleID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(group.modules) { module in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button {
                            if !expanded.insert(module).inserted { expanded.remove(module) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: module.symbol).frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(module.title).font(.callout.weight(.medium))
                                    Text(store.moduleStateTitle(module))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: expanded.contains(module) ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(module.title)，\(store.moduleStateTitle(module))，详情")
                        .accessibilityValue(expanded.contains(module) ? "已展开" : "已折叠")
                        Toggle(module.title, isOn: Binding(
                            get: { store.moduleEnabled(module) },
                            set: { enabled in requestChange(module, enabled: enabled) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!store.canChangeModules)
                        .accessibilityLabel("启用 \(module.title)")
                        .accessibilityHint("开关表示启用意图；可用状态显示在名称下方")
                    }
                    if expanded.contains(module) {
                        ModuleDetailView(store: store, module: module)
                            .padding(.leading, 28)
                    }
                }
                .padding(.vertical, 3)
            }
            if group == .agents {
                Text("DeepSeek 尚未接入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !store.codexEnabled && !store.claudeEnabled {
                    Text("全部助手已关闭，移动端暂不可使用。")
                        .font(.caption)
                }
            } else {
                Text("三种连接方式可同时开启，仅控制 Mimi；不会关闭系统 Tailscale。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.availablePairingNetworks.isEmpty {
                    Text("暂无可用连接方式，配对不可用。")
                        .font(.caption)
                }
            }
            if let undoModule, !store.moduleEnabled(undoModule) {
                HStack {
                    Text("已关闭 \(undoModule.title)").font(.caption)
                    Spacer()
                    Button("撤销关闭") { requestChange(undoModule, enabled: true) }
                        .disabled(!store.canChangeModules)
                }
            }
            if store.owner == .homebrew {
                Text("请先接管为 App 服务，再管理模块。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func requestChange(_ module: HostModuleID, enabled: Bool) {
        guard store.canChangeModules, store.moduleEnabled(module) != enabled else { return }
        // Application-level confirmation survives the transient MenuBarExtra window.
        DispatchQueue.main.async {
            guard store.canChangeModules else { return }
            let alert = NSAlert()
            alert.messageText = "\(enabled ? "启用" : "关闭") \(module.title)？"
            alert.informativeText = ModuleChangePresentation.impact(module, enabled: enabled)
            alert.alertStyle = .warning
            alert.addButton(withTitle: enabled ? "启用" : "关闭")
            alert.addButton(withTitle: "取消")
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            undoModule = nil
            Task {
                await store.setModule(module, enabled: enabled)
                if !enabled, !store.moduleEnabled(module), store.moduleError(module) == nil {
                    undoModule = module
                }
            }
        }
    }
}

private struct ModuleDetailView: View {
    let store: HostStore
    let module: HostModuleID
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.moduleError(module) {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if module.isAgent {
                agentDetail
            } else {
                connectionDetail
            }
            HStack {
                Button("刷新状态") {
                    Task {
                        await store.refresh()
                        if module == .tailcat { await store.refreshTailcatStatus() }
                    }
                }
                Button("诊断…") { openWindow(id: AppWindow.diagnostics.rawValue) }
            }
            .controlSize(.small)
            .disabled(store.isBusy)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var agentDetail: some View {
        if let runtime = store.runtime(for: module) {
            if let version = runtime.version { Text(version).font(.caption).textSelection(.enabled) }
            if let plan = runtime.effectivePlanType { Text(plan).font(.caption).foregroundStyle(.secondary) }
            if runtime.enabled, store.status?.runtimeStatus?.isExpired() == false,
               runtime.state == .available || runtime.state == .connected,
               let windows = runtime.rateLimits?.windows, !windows.isEmpty {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 8) {
                        if let fraction = window.remainingFraction {
                            ZStack {
                                Circle().stroke(.secondary.opacity(0.2), lineWidth: 3)
                                Circle().trim(from: 0, to: fraction)
                                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        }
                        Text("\(window.durationLabel) · \(window.remainingPercentText.map { "剩余 \($0)" } ?? "额度未知")")
                            .font(.caption.monospacedDigit())
                        if let reset = window.resetDate {
                            Text(reset, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                .help("额度重置时间")
                        }
                    }
                }
            } else {
                Text("额度未知或尚未刷新").font(.caption).foregroundStyle(.secondary)
            }
        }
        Text(module == .codex
             ? "使用 Mac 上的 Codex。关闭只阻止 Mimi 使用该助手，不退出 Codex Desktop。"
             : "使用本机 Claude Code 与 bridge；请在 Mac 上完成安装和登录。")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("复制登录命令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(module == .codex ? "codex login" : "claude", forType: .string)
            }
            Button("打开终端") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var connectionDetail: some View {
        Text(ModuleChangePresentation.boundary(module))
            .font(.caption).foregroundStyle(.secondary)
        if module == .tailcat {
            Text(store.tailcatStatusDetail).font(.caption)
            Button("中继与配对管理…") { openSettings() }
                .controlSize(.small)
        }
        if module == .tailscale {
            Text("请在 Tailscale 应用中完成安装、登录和连接。本机有地址不代表手机已连通。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let network = module.network, store.canPair, store.availablePairingNetworks.contains(network) {
            Button("通过 \(module.title) 配对…") {
                Task {
                    await store.refreshPairing(network: network)
                    if store.pairing?.network == network { openWindow(id: AppWindow.pairing.rawValue) }
                }
            }
            .disabled(store.isBusy)
            .controlSize(.small)
        }
    }
}
