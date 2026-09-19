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

