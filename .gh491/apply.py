from pathlib import Path
import re

root = Path('macos/MimiRemoteMac/Sources')
def edit(path, old, new, count=1):
    p = Path(path); s = p.read_text()
    assert s.count(old) == count, f'{path}: expected {count} matches: {old[:90]!r}, got {s.count(old)}'
    p.write_text(s.replace(old, new))
def between(path, start, end, replacement):
    p = Path(path); s = p.read_text(); a = s.index(start); b = s.index(end, a)
    p.write_text(s[:a] + replacement + s[b:])

p = root/'Domain/AgentModels.swift'
edit(p, '    let stale: Bool?\n', '    let stale: Bool?\n    let modules: ModuleConfiguration?\n')
edit(p, '        case stale\n', '        case stale\n        case modules\n')
edit(p, '        stale: Bool? = nil\n', '        stale: Bool? = nil,\n        modules: ModuleConfiguration? = nil\n')
edit(p, '        self.stale = stale\n', '        self.stale = stale\n        self.modules = modules\n')
edit(p, '    let runtimeStatus: AgentRuntimeStatusSnapshot?\n', '    let runtimeStatus: AgentRuntimeStatusSnapshot?\n    let moduleConfiguration: ModuleConfiguration?\n    let connectionStatus: [ConnectionModuleStatus]?\n')
edit(p, '        case runtimeStatus = "runtime_status"\n', '        case runtimeStatus = "runtime_status"\n        case moduleConfiguration = "module_configuration"\n        case connectionStatus = "connection_status"\n')
edit(p, '        runtimeStatus: AgentRuntimeStatusSnapshot? = nil\n', '        runtimeStatus: AgentRuntimeStatusSnapshot? = nil,\n        moduleConfiguration: ModuleConfiguration? = nil,\n        connectionStatus: [ConnectionModuleStatus]? = nil\n')
edit(p, '        self.runtimeStatus = runtimeStatus\n', '        self.runtimeStatus = runtimeStatus\n        self.moduleConfiguration = moduleConfiguration\n        self.connectionStatus = connectionStatus\n')
edit(p, '        pairExpires = try container.decodeIfPresent(String.self, forKey: .pairExpires)\n', '''        pairExpires = try container.decodeIfPresent(String.self, forKey: .pairExpires)
        moduleConfiguration = try? container.decodeIfPresent(ModuleConfiguration.self, forKey: .moduleConfiguration)
        connectionStatus = try? container.decodeIfPresent([ConnectionModuleStatus].self, forKey: .connectionStatus)
''')
p.write_text(p.read_text() + Path('.gh491/models.swift').read_text())

p = root/'Infrastructure/AgentCommandClient.swift'
edit(p, '    var version: @Sendable () async throws -> String\n', '''    var configureModule: @Sendable (HostModule, Bool?, ModulePreferences?, String?) async throws -> ModuleChange = { _, _, _, _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持独立模块管理，请更新后重试。")
    }
    var version: @Sendable () async throws -> String
''')
edit(p, '            version: {\n', '''            configureModule: { module, enabled, restore, revision in
                let binary = try requireEmbeddedBinary()
                var arguments = ["module", "--module=\\(module.rawValue)", "--json"]
                if let enabled { arguments.append("--enabled=\\(enabled)") }
                if let restore {
                    let data = try JSONEncoder().encode(restore)
                    guard let json = String(data: data, encoding: .utf8) else {
                        throw AgentClientError.invalidResponse("无法编码模块恢复设置。")
                    }
                    arguments.append("--restore=\\(json)")
                }
                if let revision { arguments.append("--if-revision=\\(revision)") }
                return try decode(ModuleChange.self, from: try await execute(
                    binary: binary, arguments: arguments, timeout: .seconds(25)
                ))
            },
            version: {
''')
# The legacy automatic Claude check has a longer server-side transaction budget.
edit(p, '                    timeout: .seconds(10)\n', '                    timeout: .seconds(55)\n')

p = root/'State/HostStore.swift'
edit(p, '    var lastError: String?\n', '    var lastError: String?\n    private(set) var modulePending: HostModule?\n    private(set) var moduleUndo: ModuleUndo?\n')
between(p, '    private func prepareAutomaticNetworkBeforeServiceStart()', '    func runDoctor(fix: Bool)', '''    private func prepareAutomaticNetworkBeforeServiceStart() async throws {
        // Network intent is changed only by an explicit module action. In
        // particular, a failed pairing probe must never silently enable LAN.
    }

    private func resolvedPairing(for requestedNetwork: PairingNetwork?) async throws -> PairingInfo {
        if let reason = pairingBlockReason { throw AgentClientError.commandFailed(reason) }
        let requested = requestedNetwork ?? .automatic
        let network = requested == .automatic ? availablePairingNetworks.first : requested
        guard let network, availablePairingNetworks.contains(network) else {
            throw AgentClientError.commandFailed("此连接方式尚未启用或当前不可用，请在设置中检查。")
        }
        let result = try await agent.pair(network)
        guard result.network == network else {
            throw AgentClientError.invalidResponse("配对网络与所选通道不一致。")
        }
        return result
    }

''')
edit(p, '        pairingRefreshGeneration &+= 1\n        let refreshGeneration = pairingRefreshGeneration', '        pairing = nil\n        pairingRefreshGeneration &+= 1\n        let refreshGeneration = pairingRefreshGeneration')
# Legacy protocol remains supported by the old internal API; the new controls
# always use the unified CAS writer. This also preserves older injected clients.
edit(p, '    func setClaudeEnabled(_ enabled: Bool) async {\n', '''    func setClaudeEnabled(_ enabled: Bool) async {
        if status?.moduleConfiguration != nil {
            await setModuleEnabled(.claude, enabled: enabled)
            return
        }
''')
edit(p, '        isBusy = true\n        isUpdatingTailcat = true', '        invalidateModulePairing()\n        isBusy = true\n        isUpdatingTailcat = true', count=3)
edit(p, '        guard !isAwaitingServiceStart else { return }', '        guard !isAwaitingServiceStart, !isBusy else { return }')
edit(p, '              previousStatus.endpoint == current.endpoint,', '              previousStatus.moduleConfiguration == current.moduleConfiguration,\n              previousStatus.endpoint == current.endpoint,')
edit(p, '            stale: true\n', '            stale: true,\n            modules: previousSnapshot.modules\n')
edit(p, '            runtimeStatus: staleSnapshot\n', '            runtimeStatus: staleSnapshot,\n            moduleConfiguration: current.moduleConfiguration,\n            connectionStatus: current.connectionStatus ?? previousStatus.connectionStatus\n')
p.write_text(p.read_text() + Path('.gh491/host.swift').read_text())

p = root/'Features/MenuBar/MenuBarContentView.swift'
between(p, 'struct MenuBarContentView: View {', 'private struct MenuStatusHeader: View {', Path('.gh491/menu.swift').read_text())
edit(p, 'case .ready: "Mimi Remote 已连接"', 'case .ready: "Mimi Remote 已就绪"')
p = root/'Features/Settings/MacSettingsView.swift'
between(p, 'import SwiftUI', '/// “文件访问”分组', Path('.gh491/settings.swift').read_text())
p = root/'App/MimiRemoteMacApp.swift'
between(p, '        Window("实验功能",', '        Settings {', '')

p = root/'Features/Pairing/PairingView.swift'
edit(p, '    @Environment(\\.accessibilityReduceMotion) private var reduceMotion\n', '    @Environment(\\.accessibilityReduceMotion) private var reduceMotion\n    @Environment(\\.openSettings) private var openSettings\n', count=2)
edit(p, '            if let pairing = store.pairing {', '''            if let reason = store.pairingBlockReason {
                VStack(spacing: 16) {
                    Image(systemName: "qrcode").font(.largeTitle).foregroundStyle(.secondary)
                    Text("暂不可配对").font(.headline)
                    Text(reason).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    HStack {
                        Button("打开设置…") { openSettings() }
                        Button("刷新状态") { Task { await store.refreshModules() } }.disabled(store.isBusy)
                    }
                }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pairing = store.pairing,
                      store.availablePairingNetworks.contains(pairing.network) {''')
edit(p, '        .task {\n            if store.pairing == nil {', '        .task {\n            await store.refreshModules()\n            if store.pairing == nil, store.pairingBlockReason == nil {')
edit(p, '                    isRefreshing: isRefreshing\n                )', '                    isRefreshing: isRefreshing,\n                    availableNetworks: store.availablePairingNetworks\n                )')
edit(p, '    private func copyPairingLink(_ value: String) {\n', '    private func copyPairingLink(_ value: String) {\n        guard store.pairingBlockReason == nil, store.pairing?.pairURL == value else { return }\n')
edit(p, '    let isRefreshing: Bool\n\n    var body: some View {\n        VStack(spacing: 8)', '    let isRefreshing: Bool\n    let availableNetworks: [PairingNetwork]\n\n    var body: some View {\n        VStack(spacing: 8)')
between(p, '                Text("Tailscale")\n                    .tag', '            }\n            .pickerStyle(.segmented)', '''                ForEach(availableNetworks) { network in
                    Text(network == .tailscale ? "Tailscale" : network == .tailcat ? "Tailcat 实验" : "局域网")
                        .tag(network)
                }
''')
edit(p, '"设备需在同一局域网 · 首次启用会重启服务"', '"设备需在同一局域网 · 配对不会修改开关"')
# Selection can outlive a disabled channel; choose a remaining channel without
# enabling one, but do not run a command while a module transaction is pending.
edit(p, '        let targetNetwork = network ?? selectedNetwork', '        let targetNetwork = network ?? (store.availablePairingNetworks.contains(selectedNetwork) ? selectedNetwork : .automatic)')

# A diagnostics probe of a connection does not require an enabled AI provider.
p = Path('internal/setup/modules.go')
edit(p, 'endpoint, _, err := pairingEndpoint(ctx, cfg, network, defaultPairingNetworkLookups())', '''probeConfig := cfg
            probeEnabled := true
            probeConfig.Codex.Enabled = &probeEnabled
            endpoint, _, err := pairingEndpoint(ctx, probeConfig, network, defaultPairingNetworkLookups())''')
# An environment override must not silently reverse the explicit UI intent.
edit(p, '\tresult.Configuration = cfg.Modules()\n', '''    if restore == nil && module == "claude" && cfg.Claude.Enabled != enabled {
        return result, fmt.Errorf("AGENTD_CLAUDE_ENABLED 覆盖了模块设置，请先移除该环境变量")
    }
    result.Configuration = cfg.Modules()
''')

for path in root.rglob('*.swift'):
    count = len(path.read_text().splitlines())
    if count > 1900: print(f'SOURCE_SIZE {path}: {count}', flush=True)
    assert count <= 2000, f'source size limit: {path}: {count}'
print('Applied Mac module management UI and state integration', flush=True)
