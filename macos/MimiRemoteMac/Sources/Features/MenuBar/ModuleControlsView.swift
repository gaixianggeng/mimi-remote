import AppKit
import SwiftUI

/// 菜单栏与设置共享同一套模块状态和启停动作；菜单栏首屏不再依赖二级设置入口。
struct ModuleControlsGroup: View {
    let store: HostStore
    let group: HostModuleGroup
    @State private var expanded: Set<HostModuleID> = []
    @State private var undoModule: HostModuleID?
    @State private var pendingEnabled: [HostModuleID: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(group.title)
                Spacer()
                Text("\(enabledCount) 个\(group == .agents ? "已启用" : "已开启")")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)
            .padding(.bottom, 3)

            ForEach(group.modules) { module in
                Divider()
                    .opacity(0.28)
                    .padding(.leading, 34)

                ModuleControlRow(
                    store: store,
                    module: module,
                    isExpanded: expanded.contains(module),
                    pendingEnabled: pendingEnabled[module],
                    toggleDetails: { toggleDetails(module) },
                    requestChange: { requestChange(module, enabled: $0) }
                )

                if expanded.contains(module) {
                    ModuleDetailView(store: store, module: module)
                        .padding(.leading, 34)
                        .padding(.trailing, 6)
                        .padding(.bottom, 8)
                }
            }

            if group == .agents {
                Divider()
                    .opacity(0.28)
                    .padding(.leading, 34)

                HStack(spacing: 10) {
                    RuntimeBrandMarkIcon(
                        mark: .deepSeek,
                        size: MenuBarLayout.brandMarkSize,
                        isMuted: true
                    )
                    .frame(width: 24)
                    Text("DeepSeek")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Text("未接入")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)
                .frame(
                    minHeight: MenuBarLayout.rowHeight,
                    maxHeight: MenuBarLayout.rowHeight
                )

                Text("开关立即生效。切换 AI 编程助手会重新加载服务，进行中的移动会话可能中断。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 3)
                    .padding(.top, 3)

                if !store.codexEnabled && !store.claudeEnabled {
                    Text("全部助手已关闭，移动端暂不可使用。")
                        .font(.caption)
                        .padding(.horizontal, 3)
                        .padding(.top, 5)
                }

                if store.owner == .homebrew {
                    Text("请先接管为 App 服务，再管理模块。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 3)
                        .padding(.top, 5)
                }
            } else if store.availablePairingNetworks.isEmpty {
                Text("暂无可用连接方式，配对不可用。")
                    .font(.caption)
                    .padding(.horizontal, 3)
                    .padding(.top, 5)
            }

            if let undoModule, !store.moduleEnabled(undoModule) {
                HStack {
                    Text("已关闭 \(undoModule.title)").font(.caption)
                    Spacer()
                    Button("撤销关闭") { requestChange(undoModule, enabled: true) }
                        .disabled(!store.canChangeModule(undoModule))
                }
                .padding(.horizontal, 3)
                .padding(.top, 6)
            }
        }
    }

    private var enabledCount: Int {
        group.modules.filter { pendingEnabled[$0] ?? store.moduleEnabled($0) }.count
    }

    private func toggleDetails(_ module: HostModuleID) {
        if !expanded.insert(module).inserted {
            expanded.remove(module)
        }
    }

    private func requestChange(_ module: HostModuleID, enabled: Bool) {
        guard store.canChangeModule(module), store.moduleEnabled(module) != enabled else { return }
        guard shouldConfirmLastConnectionChange(module, enabled: enabled) else {
            applyChange(module, enabled: enabled)
            return
        }

        // 只有关闭最后一种连接方式才阻断确认；其它开关立即执行并提供撤销。
        DispatchQueue.main.async {
            guard store.canChangeModule(module) else { return }
            let alert = NSAlert()
            alert.messageText = "关闭最后一种连接方式？"
            alert.informativeText = ModuleChangePresentation.impact(module, enabled: enabled)
            alert.alertStyle = .warning
            alert.addButton(withTitle: "关闭")
            alert.addButton(withTitle: "取消")
            alert.buttons.first?.hasDestructiveAction = true
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            applyChange(module, enabled: enabled)
        }
    }

    private func shouldConfirmLastConnectionChange(_ module: HostModuleID, enabled: Bool) -> Bool {
        guard !enabled, module.network != nil else { return false }
        return HostModuleGroup.connections.modules.filter { store.moduleEnabled($0) }.count == 1
    }

    private func applyChange(_ module: HostModuleID, enabled: Bool) {
        undoModule = nil
        pendingEnabled[module] = enabled
        Task {
            await store.setModule(module, enabled: enabled)
            pendingEnabled[module] = nil
            if !enabled, !store.moduleEnabled(module), store.moduleError(module) == nil {
                undoModule = module
            }
        }
    }
}

private struct ModuleControlRow: View {
    let store: HostStore
    let module: HostModuleID
    let isExpanded: Bool
    let pendingEnabled: Bool?
    let toggleDetails: () -> Void
    let requestChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleDetails) {
                HStack(spacing: 10) {
                    ModuleRowIcon(module: module)
                        .frame(width: 24)
                    Text(module.title)
                        .font(.callout.weight(.medium))
                    if module == .tailcat {
                        Text("实验")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)

            ModuleStateLabel(
                title: stateTitle,
                color: stateColor,
                isWorking: isWorking
            )

            Toggle(module.title, isOn: Binding(
                get: { pendingEnabled ?? store.moduleEnabled(module) },
                set: requestChange
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color.mimiControlAccent)
            .disabled(!store.canChangeModule(module))
            .accessibilityLabel("启用 \(module.title)")
            .accessibilityHint("当前状态：\(stateTitle)")

            Button(action: toggleDetails) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(module.title) 详情")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")
        }
        .padding(.horizontal, 3)
        .frame(
            minHeight: MenuBarLayout.rowHeight,
            maxHeight: MenuBarLayout.rowHeight
        )
    }

    private var isWorking: Bool {
        pendingEnabled != nil || store.updatingModule == module ||
            (module == .claude && store.isUpdatingClaude) ||
            (module == .tailcat && store.isUpdatingTailcat)
    }

    private var stateTitle: String {
        if let pendingEnabled {
            return pendingEnabled ? "正在启用…" : "正在关闭…"
        }
        return store.moduleStateTitle(module)
    }

    private var stateColor: Color {
        let title = stateTitle
        if store.moduleError(module) != nil { return .red }
        if isWorking { return .blue }
        if !store.moduleEnabled(module) { return .secondary }
        if title.contains("需要") || title.contains("暂不") { return .orange }
        if title == "可用" || title.contains("地址可用") || title == "已连接" { return .mimiSuccess }
        return .secondary
    }
}

/// AI 编程助手用各自的品牌标记，其余模块沿用系统符号；两种图标共用同一列宽。
private struct ModuleRowIcon: View {
    let module: HostModuleID

    var body: some View {
        if let mark = module.brandMark {
            RuntimeBrandMarkIcon(mark: mark, size: MenuBarLayout.brandMarkSize)
        } else {
            Image(systemName: module.symbol)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ModuleStateLabel: View {
    let title: String
    let color: Color
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 5) {
            if isWorking {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("状态：\(title)")
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
