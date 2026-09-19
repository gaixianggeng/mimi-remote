import AppKit
import SwiftUI

private enum MenuBarLayout {
    static let contentInset: CGFloat = 12
    // 底部操作已经有完整的 40pt 点击区域；收紧窗口底边留白，避免最后一行显得虚高。
    static let bottomInset: CGFloat = 6
    // 状态信息、运行时和操作区共用同一列网格，避免不同区块的图标与文字左右漂移。
    static let sectionInset: CGFloat = 3
    static let symbolColumnWidth: CGFloat = 16
    static let symbolTextSpacing: CGFloat = 8
    static let textColumnLeading = sectionInset + symbolColumnWidth + symbolTextSpacing
    // 同组操作使用固定高度，避免分隔线、悬停底色或文案状态造成视觉节奏跳动。
    static let actionRowHeight: CGFloat = 40
    static let actionDividerOpacity: Double = 0.28
}

struct MenuBarContentView: View {
    let store: HostStore
    let updates: AppUpdateStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var showsDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuStatusHeader(lifecycle: store.lifecycle, startingDetail: store.startingDetail,
                             isRefreshing: store.isBusy || store.isRefreshingStatus) {
                Task { await store.refreshModules() }
            }
            AppUpdateNotice(updates: updates)
            Divider()
            ModuleGroupView(store: store, agents: true)
            Divider()
            ModuleGroupView(store: store, agents: false)
            if let error = store.lastError { MenuStatusMessage(message: error) }
            if let undo = store.moduleUndo {
                HStack {
                    Text("已关闭 \(undo.module.title)").font(.caption)
                    Spacer()
                    Button("撤销") { Task { await store.undoModuleChange() } }
                        .disabled(!store.canManageModules)
                }
            }
            if store.lifecycle == .notConfigured || store.lifecycle == .migrationRequired {
                Button("完成设置与服务接管…") { present(.dashboard) }
                    .buttonStyle(.borderedProminent)
            } else if store.status?.serviceOK != true {
                Button("修复并启动服务") { Task { await store.repairAndStartService() } }
                    .disabled(store.isBusy)
            }
            Button { present(.pairing) } label: {
                Label("配对设备…", systemImage: "qrcode").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.pairingBlockReason != nil)
            .help(store.pairingBlockReason ?? "选择可用连接方式配对")
            if let reason = store.pairingBlockReason, !store.isBusy {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("诊断", isExpanded: $showsDiagnostics) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.lifecycle.detail ?? "查看服务检查和修复建议。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let results = store.doctor {
                        ForEach(Array(results.checks.filter { !$0.ok }.prefix(3))) { check in
                            Text(check.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Button("运行检查") { Task { await store.runDoctor(fix: false) } }
                            .disabled(store.isBusy)
                        Button("日志与完整诊断…") { present(.diagnostics) }
                    }
                }.padding(.top, 8)
            }
            Divider()
            HStack {
                Button("设置…") { openSettings(); activate() }
                Spacer()
                Menu("更多") {
                    Button("打开主窗口…") { present(.dashboard) }
                    Button(updates.isChecking ? "正在检查更新…" : "检查更新…") {
                        Task { await updates.check(manual: true) }
                    }.disabled(updates.isChecking)
                    Button("重新启动 Mimi 服务") { Task { await store.restartService() } }
                        .disabled(store.isBusy || store.owner != .macApp)
                    Divider()
                    Button("退出并停止服务…", role: .destructive) { confirmQuit() }
                        .disabled(store.isBusy)
                }.menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(MenuBarWindowPositionGuard())
        .task {
            await store.refreshIfNeeded()
            if !store.isBusy { await store.refreshTailcatStatus() }
        }
    }

    private func present(_ window: AppWindow) {
        openWindow(id: window.rawValue)
        activate()
    }
    private func activate() {
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
    private func confirmQuit() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "退出并停止 Mimi Remote Mac？"
            alert.informativeText = "这会中断移动设备的连接，并停止 Mimi 管理的服务。无法可靠判断当前任务是否仍在运行，请先确认任务状态。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "退出并停止")
            alert.addButton(withTitle: "取消")
            alert.buttons.first?.hasDestructiveAction = true
            NSApplication.shared.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { store.requestStopServiceAndQuit() }
        }
    }
}

struct ModuleGroupView: View {
    let store: HostStore
    let agents: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(agents ? "AI Agent" : "连接方式")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(HostModule.allCases.filter { $0.isAgent == agents }) { module in
                ModuleRowView(store: store, module: module)
            }
            if agents {
                HStack(spacing: 8) {
                    Image(systemName: "ellipsis.circle").frame(width: 18)
                    Text("DeepSeek")
                    Spacer()
                    Text("暂不支持").font(.caption)
                }.foregroundStyle(.tertiary)
                    .accessibilityLabel("DeepSeek，暂不支持，没有可用开关")
            }
        }
    }
}

private struct ModuleRowView: View {
    let store: HostStore
    let module: HostModule
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 8) {
            Button { showsDetails = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: module.symbol).frame(width: 18)
                        .foregroundStyle(store.moduleAvailable(module) ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(module.title).font(.callout.weight(.medium))
                            if module == .tailcat {
                                Text("实验").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                        Text(store.moduleStateTitle(module)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if module.isAgent && store.moduleEnabled(module) {
                        ModuleQuotaRings(runtime: store.moduleRuntime(module),
                                         stale: store.status?.runtimeStatus?.isExpired() != false || !store.modulesApplied)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .popover(isPresented: $showsDetails) { ModuleDetailsView(store: store, module: module) }
                .help("查看 \(module.title) 详情")
            if store.modulePending == module {
                ProgressView().controlSize(.small).frame(width: 34)
            } else {
                Toggle(module.title, isOn: Binding(
                    get: { store.moduleEnabled(module) },
                    set: { requestChange($0) }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(!store.canManageModules)
                .accessibilityLabel("在 Mimi 中启用 \(module.title)")
            }
        }.frame(minHeight: 38)
    }

    private func requestChange(_ enabled: Bool) {
        let losesLastPath = !module.isAgent && !enabled
            && !HostModule.allCases.contains { !$0.isAgent && $0 != module && store.moduleAvailable($0) }
        let requiresConfirmation = (!enabled && module.isAgent) || losesLastPath || (module == .lan && enabled)
        guard requiresConfirmation else {
            Task { await store.setModuleEnabled(module, enabled: enabled) }
            return
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "\(enabled ? "启用" : "关闭") \(module.title)？"
            if enabled {
                alert.informativeText = "这会允许同一局域网的设备访问 Mimi。所有远程请求仍需鉴权；不会关闭防火墙。"
            } else if losesLastPath {
                alert.informativeText = "这是最后一个已知可用连接方式。关闭后移动设备可能全部断开，必须在这台 Mac 上重新开启。"
            } else {
                alert.informativeText = "无法可靠判断运行中的任务。关闭会断开该 Agent 的 Mimi 会话；应用配置也会短暂重载 Mimi 服务。不会退出 Codex Desktop。"
            }
            alert.alertStyle = .warning
            alert.addButton(withTitle: enabled ? "启用" : "关闭")
            alert.addButton(withTitle: "取消")
            NSApplication.shared.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await store.setModuleEnabled(module, enabled: enabled) }
            }
        }
    }
}

private struct ModuleQuotaRings: View {
    let runtime: AgentRuntimeStatus?
    let stale: Bool
    var body: some View {
        HStack(spacing: 5) {
            if let windows = runtime?.rateLimits?.windows, !windows.isEmpty {
                ForEach(Array(windows.prefix(2).enumerated()), id: \.offset) { _, window in
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                        if let fraction = window.remainingFraction {
                            Circle().trim(from: 0, to: fraction)
                                .stroke(stale ? Color.secondary : Color.accentColor,
                                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        } else {
                            Text("—").font(.system(size: 8))
                        }
                    }.frame(width: 18, height: 18)
                        .help("\(window.durationLabel)：\(window.remainingPercentText.map { "剩余 " + $0 } ?? "额度未知")\(stale ? "（状态已过期）" : "")")
                        .accessibilityLabel("\(window.durationLabel)，剩余 \(window.remainingPercentText ?? "未知")\(stale ? "，状态已过期" : "")")
                }
                if stale { Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary) }
            } else {
                Text(runtime?.authMode == "api_key" ? "API" : "额度未知")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct ModuleDetailsView: View {
    let store: HostStore
    let module: HostModule
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(module.title, systemImage: module.symbol).font(.headline)
                Spacer()
                Text(store.moduleStateTitle(module)).font(.caption).foregroundStyle(.secondary)
            }
            Text(store.moduleDetail(module)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let runtime = store.moduleRuntime(module), module.isAgent, store.moduleEnabled(module) {
                if let version = runtime.version { LabeledContent("版本", value: version) }
                if let plan = runtime.effectivePlanType { LabeledContent("套餐", value: plan) }
                if let auth = runtime.authMode { LabeledContent("认证", value: auth) }
                if store.status?.runtimeStatus?.isExpired() == true || !store.modulesApplied {
                    Label("以下为上次观测值，状态已过期", systemImage: "clock")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let limits = runtime.rateLimits, !limits.windows.isEmpty {
                    ForEach(Array(limits.windows.enumerated()), id: \.offset) { _, window in
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(window.durationLabel, value: window.remainingPercentText.map { "剩余 " + $0 } ?? "未知")
                            if let fraction = window.remainingFraction { ProgressView(value: fraction) }
                            if let date = window.resetDate {
                                Text("重置于 \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if limits.availability != "available" {
                        Text("额度可能不完整，仅显示已观测窗口。").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(runtime.authMode == "api_key" ? "API Key 模式没有订阅额度窗口。" : "额度暂不可获取，不代表剩余为零。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let connection = store.status?.connectionStatus?.first(where: { $0.id == module.rawValue }),
               let endpoint = connection.endpoint {
                Text(endpoint).font(.caption.monospaced()).textSelection(.enabled)
            }
            Button("刷新状态") { Task { await store.refreshModules() } }.disabled(store.isBusy)
        }.padding(18).frame(width: 310)
    }
}

private struct MenuStatusHeader: View {
    let lifecycle: HostLifecycleState
    var startingDetail: String? = nil
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))

                if lifecycle == .loading || lifecycle == .starting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(statusColor)
                } else {
                    Image(systemName: lifecycle.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button(action: refresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(MenuIconButtonStyle())
            .disabled(isRefreshing)
            .help("刷新服务状态")
            .accessibilityLabel("刷新服务状态")
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch lifecycle {
        case .loading: "正在检查 Mac 服务"
        case .notConfigured: "完成 Mac 端设置"
        case .migrationRequired: "Homebrew 服务正在运行"
        case .starting: "正在启动 Mimi Remote"
        case .ready: "Mimi Remote 已就绪"
        case .degraded: "服务需要处理"
        case .stopped: "服务已停止"
        case .failed: "服务启动失败"
        }
    }

    private var subtitle: String {
        switch lifecycle {
        case .loading: "正在读取服务和连接状态。"
        case .notConfigured: "选择代码目录后即可配对移动设备。"
        case .migrationRequired: "可安全迁移，现有配置和配对都会保留。"
        case .starting: startingDetail ?? "移动设备连接会在服务就绪后自动恢复。"
        case .ready: "Mac 端服务运行正常。"
        case .degraded(let message), .failed(let message): message
        case .stopped: "打开 App 或重新登录后可以再次启动。"
        }
    }

    private var statusColor: Color {
        switch lifecycle {
        case .ready: .mimiPrimary
        case .loading, .starting: .blue
        case .notConfigured, .migrationRequired, .degraded: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

private struct MenuConnectionSummary: View {
    let status: AgentStatus
    let owner: ServiceOwner

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MenuMetadataRow(systemImage: "network") {
                Text(status.endpoint)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            MenuMetadataRow(systemImage: "shippingbox") {
                Text("App \(appVersionLabel) · agentd \(runningAgentVersion)")
                    .font(.caption2)
                    .foregroundStyle(status.hasAgentVersionMismatch ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            MenuMetadataRow(systemImage: ownerSymbol) {
                Text("\(ownerTitle) · \(status.projects) 个项目")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ownerColor)
            }
        }
        .padding(.horizontal, MenuBarLayout.sectionInset)
        .accessibilityElement(children: .contain)
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let version, !version.isEmpty else { return "版本未知" }
        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    private var runningAgentVersion: String {
        status.serverVersion ?? status.version
    }

    private var ownerTitle: String {
        switch owner {
        case .none: "未托管"
        case .macApp: "App 托管"
        case .homebrew: "Homebrew"
        }
    }

    private var ownerColor: Color {
        switch owner {
        case .none: .secondary
        case .macApp: .mimiPrimary
        case .homebrew: .orange
        }
    }

    private var ownerSymbol: String {
        switch owner {
        case .none: "questionmark.circle"
        case .macApp: "app.fill"
        case .homebrew: "shippingbox.fill"
        }
    }
}

private struct MenuMetadataRow<Content: View>: View {
    let systemImage: String
    @ViewBuilder let content: Content

    init(systemImage: String, @ViewBuilder content: () -> Content) {
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        HStack(spacing: MenuBarLayout.symbolTextSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: MenuBarLayout.symbolColumnWidth)
            content
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MenuRuntimeSummary: View {
    let snapshot: AgentRuntimeStatusSnapshot?
    let serviceAvailable: Bool
    let owner: ServiceOwner
    let lifecycle: HostLifecycleState

    var body: some View {
        let codex = runtime(id: "codex")
        let claude = runtime(id: "claude")
        let usageSlots = MenuRuntimePresentation.usageSlots(codex: codex, claude: claude)

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Text("AI 运行时")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)

                Spacer(minLength: 4)

                if snapshot?.refreshing == true {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("正在刷新运行时状态")
                }

                if let snapshotStatusText {
                    Text(snapshotStatusText)
                        .font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuBarLayout.sectionInset)

            if !usageSlots.isEmpty {
                MenuRuntimeUsageOverview(slots: usageSlots)
                    // 先展示额度总览，再展示各运行时详情，扫描顺序与信息层级一致。
                    .padding(.horizontal, MenuBarLayout.sectionInset)
            }

            MenuRuntimeRow(
                runtime: codex,
                fallbackTitle: "Codex",
                systemImage: "chevron.left.forwardslash.chevron.right",
                serviceAvailable: serviceAvailable,
                isRefreshing: snapshot?.refreshing == true,
                isStale: isStale,
                missingDetail: missingDetail
            )

            MenuRuntimeRow(
                runtime: claude,
                fallbackTitle: "Claude",
                systemImage: "sparkles",
                serviceAvailable: serviceAvailable,
                isRefreshing: snapshot?.refreshing == true,
                isStale: isStale,
                missingDetail: missingDetail
            )
        }
    }

    private func runtime(id: String) -> AgentRuntimeStatus? {
        snapshot?.runtimes.first { $0.id == id }
    }

    private var isStale: Bool {
        guard serviceAvailable, lifecycleAllowsFreshStatus else { return true }
        return snapshot?.isExpired() == true
    }

    private var lifecycleAllowsFreshStatus: Bool {
        switch lifecycle {
        case .ready, .migrationRequired:
            return true
        default:
            return false
        }
    }

    private var missingDetail: String {
        if owner == .homebrew {
            return "升级或迁移到新版 Mac App 后可显示运行时状态。"
        }
        if !serviceAvailable {
            return "Mac 服务不可用。"
        }
        return "运行时状态暂不可获取，请刷新或运行诊断。"
    }

    private var snapshotStatusText: String? {
        if snapshot?.refreshing == true {
            return snapshot?.checkedDate == nil ? "正在首次获取" : "后台刷新"
        }
        if isStale, snapshot != nil {
            return "状态可能已过期"
        }
        if let checkedDate = snapshot?.checkedDate {
            return "更新于 \(checkedDate.formatted(date: .omitted, time: .shortened))"
        }
        if owner == .homebrew {
            return "需要升级"
        }
        return nil
    }
}

private struct MenuRuntimeRow: View {
    let runtime: AgentRuntimeStatus?
    let fallbackTitle: String
    let systemImage: String
    let serviceAvailable: Bool
    let isRefreshing: Bool
    let isStale: Bool
    let missingDetail: String

    var body: some View {
        HStack(alignment: .top, spacing: MenuBarLayout.symbolTextSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: MenuBarLayout.symbolColumnWidth, height: 19)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(runtime?.title ?? fallbackTitle)
                        .font(.callout.weight(.semibold))

                    Spacer(minLength: 4)

                    Circle()
                        .fill(stateColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)

                    Text(stateTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(stateTextColor)

                    if let accountLabel {
                        Text("· \(accountLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if MenuRuntimePresentation.versionText(for: runtime) != nil ||
                    runtime?.startedDate != nil
                {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let versionText = MenuRuntimePresentation.versionText(for: runtime) {
                                Text(versionText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 2)

                            if let uptime = MenuRuntimePresentation.uptimeText(
                                for: runtime,
                                at: context.date
                            ) {
                                Label(uptime, systemImage: "clock")
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }

                if let quotaNoticeText {
                    Text(quotaNoticeText)
                        .font(.caption2.weight(quotaIsExhausted ? .semibold : .regular))
                        .foregroundStyle(quotaIsExhausted ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let creditSummary {
                    Text(creditSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !hasUsageData, quotaNoticeText == nil, creditSummary == nil {
                    Text(detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, MenuBarLayout.sectionInset)
        .accessibilityElement(children: .contain)
    }

    private var hasUsageData: Bool {
        guard let limits = runtime?.rateLimits else { return false }
        return limits.windows.contains {
            $0.usedPercent != nil || $0.resetsAt != nil || $0.windowDurationMins != nil
        }
    }

    private var stateTitle: String {
        if runtime?.state == .disabled { return "未启用" }
        // stale-while-revalidate：有旧快照时继续展示最后已知连接状态，
        // 刷新进度由分区标题承接，不把两行都降级成“过期”。
        if isStale, !isRefreshing { return "状态已过期" }
        if isRefreshing, runtime?.reason == "refresh_in_progress" {
            return "正在刷新"
        }
        guard let runtime else {
            return serviceAvailable ? "状态未知" : "不可用"
        }
        switch runtime.state {
        case .connected: return "已连接"
        case .available: return "运行时可用"
        case .signedOut: return "未登录"
        case .disabled: return "未启用"
        case .unavailable: return "不可用"
        }
    }

    private var accountLabel: String? {
        if runtime?.authMode == "api_key" {
            return "API Key"
        }
        if let plan = runtime?.effectivePlanType {
            return formattedAccountValue(plan)
        }
        guard let authMode = runtime?.authMode else { return nil }
        switch authMode {
        case "api_key": return "API Key"
        case "chatgpt": return "ChatGPT"
        case "oauth": return "OAuth"
        case "bedrock": return "Bedrock"
        default: return formattedAccountValue(authMode)
        }
    }

    private var detailText: String {
        MenuRuntimePresentation.detailText(
            for: runtime,
            missingDetail: missingDetail
        )
    }

    private var stateColor: Color {
        if runtime?.state == .disabled { return .secondary }
        if isStale, !isRefreshing { return .orange }
        if isRefreshing, runtime?.reason == "refresh_in_progress" {
            return .secondary
        }
        guard let runtime else {
            return serviceAvailable ? .secondary : .red
        }
        switch runtime.state {
        case .connected: return Color.mimiPrimary
        case .available: return Color.blue
        case .signedOut: return Color.orange
        case .disabled: return Color.secondary
        case .unavailable: return Color.red
        }
    }

    private var stateTextColor: Color {
        if isStale, !isRefreshing { return Color.orange.opacity(0.8) }
        guard let runtime else { return .secondary }
        switch runtime.state {
        case .signedOut: return Color.orange.opacity(0.8)
        case .unavailable: return Color.red.opacity(0.8)
        case .connected, .available, .disabled: return .secondary
        }
    }

    private var quotaIsExhausted: Bool {
        runtime?.rateLimits?.isExhausted == true
    }

    private var quotaNoticeText: String? {
        guard let limits = runtime?.rateLimits else { return nil }
        if limits.isExhausted {
            return "额度已耗尽，等待窗口重置。"
        }
        switch limits.availability?.lowercased() {
        case "partial":
            return "仅显示已观测到的额度窗口。"
        case "unavailable":
            return "额度暂不可获取。"
        default:
            return nil
        }
    }

    private var creditSummary: String? {
        guard runtime?.authMode != "api_key", let limits = runtime?.rateLimits else {
            return nil
        }
        if limits.creditsUnlimited == true {
            return "Credits 无限"
        }
        if let balance = limits.creditBalance?.trimmingCharacters(in: .whitespacesAndNewlines),
           !balance.isEmpty
        {
            return "Credits 余额 \(balance)"
        }
        if limits.hasCredits == false {
            return "Credits 未启用"
        }
        if limits.hasCredits == true {
            return "Credits 可用"
        }
        return nil
    }

    private func formattedAccountValue(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return raw }
        switch value.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        default: return value
        }
    }
}

private struct MenuRuntimeUsageOverview: View {
    let slots: [MenuRuntimeUsageSlot]

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            MenuRuntimeUsageRingsGraphic(slots: slots)
                .fixedSize()

            MenuRuntimeUsageInfoRows(slots: slots)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}

/// 三层同心圆依次表示 Codex 长窗口、Claude 长窗口、Claude 短窗口。
/// 菜单栏降低强调色强度，避免小面积高饱和颜色在浅色材质上过度刺眼。
private struct MenuRuntimeUsageRingsGraphic: View {
    let slots: [MenuRuntimeUsageSlot]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let diameter: CGFloat = 74
    private let lineWidth: CGFloat = 5
    private let ringStep: CGFloat = 20

    var body: some View {
        let ringCount = min(slots.count, 3)

        ZStack(alignment: .center) {
            ForEach(0..<ringCount, id: \.self) { index in
                let ringDiameter = diameter - CGFloat(index) * ringStep
                let item = slots[index].item

                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)

                    if let progress = item?.window.remainingFraction {
                        Circle()
                            .trim(from: 0, to: item?.isExhausted == true ? 0 : progress)
                            .stroke(
                                itemTint(item),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(
                                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1),
                                value: progress
                            )
                    }
                }
                .frame(width: ringDiameter, height: ringDiameter)
            }
        }
        .frame(width: diameter, height: diameter, alignment: .center)
        .accessibilityHidden(true)
    }

    private func itemTint(_ item: MenuRuntimeUsageItem?) -> Color {
        guard let item else { return .secondary }
        if item.isExhausted { return Color.red.opacity(0.82) }
        switch item.tintRole {
        case .codexLong: return Color.pink.opacity(0.78)
        case .claudeLong: return Color.cyan.opacity(0.72)
        case .claudeShort: return Color.mimiPrimary.opacity(0.82)
        }
    }
}

private struct MenuRuntimeUsageInfoRows: View {
    let slots: [MenuRuntimeUsageSlot]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 7) {
            ForEach(slots) { slot in
                MenuRuntimeUsageInfoRow(slot: slot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuRuntimeUsageInfoRow: View {
    let slot: MenuRuntimeUsageSlot

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                Text("\(slot.providerName) · \(slot.windowLabel)")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .gridColumnAlignment(.leading)

            Text(valueText)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .gridColumnAlignment(.trailing)

            Text(resetDetail)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slot.providerName) \(slot.windowLabel)额度")
        .accessibilityValue(valueText)
    }

    private var hasUsageValue: Bool {
        slot.item?.window.remainingPercentText != nil || slot.item?.isExhausted == true
    }

    private var valueText: String {
        if slot.item?.isExhausted == true { return "已耗尽" }
        return slot.item?.window.remainingPercentText.map { "剩余 \($0)" } ?? "等待额度"
    }

    private var resetDetail: String {
        guard let resetDate = slot.item?.window.resetDate else { return "" }
        return resetText(resetDate)
    }

    private var valueColor: Color {
        if slot.item?.isExhausted == true {
            return Color.red.opacity(0.8)
        }
        return hasUsageValue ? Color.primary.opacity(0.72) : .secondary
    }

    private var tint: Color {
        if slot.item?.isExhausted == true { return Color.red.opacity(0.82) }
        switch slot.tintRole {
        case .codexLong: return Color.pink.opacity(0.78)
        case .claudeLong: return Color.cyan.opacity(0.72)
        case .claudeShort: return Color.mimiPrimary.opacity(0.82)
        }
    }

    private func resetText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDateInToday(date) ? "Hm" : "MdHm"
        )
        return formatter.string(from: date)
    }
}

private struct MenuStatusMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityLabel("注意：\(message)")
    }
}

private struct MenuActionRow: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    var role: ButtonRole?
    var showsDisclosure = true
    var isWorking = false
    var trailingText: String?
    var accessibilityLabel: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: MenuBarLayout.symbolTextSpacing) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(symbolColor)
                    .frame(width: MenuBarLayout.symbolColumnWidth)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(labelColor)
                Spacer(minLength: 0)
                if let trailingText {
                    Text(trailingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, MenuBarLayout.sectionInset)
            .frame(
                maxWidth: .infinity,
                minHeight: MenuBarLayout.actionRowHeight,
                maxHeight: MenuBarLayout.actionRowHeight,
                alignment: .leading
            )
            .background(
                hoverBackgroundColor,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(accessibilityLabel ?? title)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var labelColor: Color {
        // 危险语义由电源图标与确认弹窗承接，文字保持普通层级，避免整行高饱和。
        .primary
    }

    private var symbolColor: Color {
        // 保留危险操作语义，但减少高饱和红色在菜单底部形成“主按钮”的错觉。
        role == .destructive ? Color(nsColor: .systemRed).opacity(0.62) : .secondary
    }

    private var hoverBackgroundColor: Color {
        guard isHovered else { return .clear }
        if role == .destructive {
            return Color(nsColor: .systemRed).opacity(0.03)
        }
        return Color.primary.opacity(0.055)
    }
}

private struct MenuPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}

private struct MenuIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(7)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.055), in: Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}

enum MenuBarWindowPlacement {
    static func correctedOriginY(
        windowFrame: CGRect,
        screenFrame: CGRect,
        menuBarHeight: CGFloat
    ) -> CGFloat {
        let highestAllowedOrigin = screenFrame.maxY - max(0, menuBarHeight) - windowFrame.height
        return min(windowFrame.minY, highestAllowedOrigin)
    }
}

private struct MenuBarWindowPositionGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MenuBarWindowProbeView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MenuBarWindowProbeView)?.scheduleAdjustment()
    }
}

private final class MenuBarWindowProbeView: NSView {
    private var adjustmentScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleAdjustment()
    }

    override func layout() {
        super.layout()
        scheduleAdjustment()
    }

    func scheduleAdjustment() {
        guard !adjustmentScheduled else { return }
        adjustmentScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.adjustmentScheduled = false
            self.keepWindowBelowMenuBar()
        }
    }

    private func keepWindowBelowMenuBar() {
        guard let window, let screen = window.screen else { return }

        let currentFrame = window.frame
        let correctedY = MenuBarWindowPlacement.correctedOriginY(
            windowFrame: currentFrame,
            screenFrame: screen.frame,
            menuBarHeight: inferredMenuBarHeight(for: screen)
        )
        guard correctedY < currentFrame.minY - 0.5 else { return }

        // 全屏空间会把隐藏状态栏的锚点放到屏幕顶端；只修正垂直越界，保留系统计算的水平锚点。
        var correctedFrame = currentFrame
        correctedFrame.origin.y = correctedY
        window.setFrame(correctedFrame, display: true, animate: false)
    }

    private func inferredMenuBarHeight(for screen: NSScreen) -> CGFloat {
        let targetInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let visibleMenuBarInset = NSScreen.screens
            .map { max(0, $0.frame.maxY - $0.visibleFrame.maxY) }
            .max() ?? 0

        return max(NSStatusBar.system.thickness, max(targetInset, visibleMenuBarInset))
    }
}

#if DEBUG
    #Preview("菜单栏 · 等待迁移") {
        MenuBarContentView(store: .preview(.migrationRequired), updates: AppUpdateStore())
    }

    #Preview("菜单栏 · 服务可用") {
        MenuBarContentView(store: .preview(.ready), updates: AppUpdateStore())
    }
#endif
