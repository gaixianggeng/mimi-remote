import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class HostStore {
    private(set) var lifecycle: HostLifecycleState = .loading
    private(set) var owner: ServiceOwner = .none
    private(set) var status: AgentStatus?
    private(set) var doctor: AgentDoctorResults?
    private(set) var pairing: PairingInfo?
    private(set) var pairingNetwork: PairingNetwork = .tailscale
    private(set) var recentLogs: [String] = []
    private(set) var appliedFixes: [String] = []
    private(set) var isBusy = false
    private(set) var homebrewLoaded = false
    private(set) var launchesAtLogin = false
    var lastError: String?

    var canRestoreHomebrew: Bool {
        owner == .macApp && homebrew.installedAgentBinary() != nil
    }

    private let agent: AgentCommandClient
    private let services: ServiceManagementClient
    private let homebrew: HomebrewServiceClient
    private let health: HealthClient
    private let logs: AgentLogClient
    private var didBootstrap = false
    private var monitorTask: Task<Void, Never>?

    init(
        agent: AgentCommandClient,
        services: ServiceManagementClient,
        homebrew: HomebrewServiceClient,
        health: HealthClient,
        logs: AgentLogClient
    ) {
        self.agent = agent
        self.services = services
        self.homebrew = homebrew
        self.health = health
        self.logs = logs
    }

    static func live() -> HostStore {
        HostStore(
            agent: .live(),
            services: .live,
            homebrew: .live(),
            health: .live,
            logs: .live
        )
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        lifecycle = .loading
        homebrewLoaded = await homebrew.isLoaded()
        launchesAtLogin = services.mainAppStatus() == .enabled

        guard agent.configExists() else {
            lifecycle = .notConfigured
            startMonitoring()
            return
        }

        await enableLoginLaunchBestEffort()
        if homebrewLoaded {
            owner = .homebrew
            lifecycle = .migrationRequired
            await refreshHomebrewStatus()
        } else {
            await startMacAgentIfNeeded()
        }
        startMonitoring()
    }

    func completeSetup(workspaceRoot: URL) async {
        guard !isBusy else { return }
        guard workspaceRoot.isFileURL,
              (try? workspaceRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else {
            lastError = "请选择一个存在的代码目录。"
            return
        }

        isBusy = true
        lifecycle = .starting
        lastError = nil
        defer { isBusy = false }
        do {
            let nextPairing = try await agent.setup(workspaceRoot)
            pairing = nextPairing
            pairingNetwork = nextPairing.network
            await enableLoginLaunchBestEffort()
            try services.registerAgent()
            owner = .macApp
            try await waitForMacAgentReady()
        } catch {
            fail(error)
        }
    }

    func takeOverHomebrew() async {
        guard !isBusy, homebrewLoaded else { return }
        guard let oldAgent = homebrew.installedAgentBinary() else {
            fail(HomebrewServiceError.commandFailed("找不到 Homebrew 安装的 agentd，无法安全接管。"))
            return
        }

        isBusy = true
        lifecycle = .starting
        lastError = nil
        defer { isBusy = false }

        do {
            let preflight = try await agent.doctor(false).results
            doctor = preflight
            guard preflight.ok else {
                lifecycle = .degraded(firstBlockingIssue(in: preflight))
                return
            }

            try await prepareAutomaticNetworkBeforeServiceStart()
            try await homebrew.stop()
            homebrewLoaded = false
            try services.registerAgent()
            owner = .macApp
            try await waitForMacAgentReady()
        } catch {
            let takeoverError = error
            await rollbackAfterFailedTakeover(oldAgent: oldAgent, cause: takeoverError)
            return
        }

        // 配对票据不是服务迁移的成功条件；刷新失败时保留已经可用的新服务。
        do {
            let nextPairing = try await resolvedPairing(for: nil)
            pairing = nextPairing
            pairingNetwork = nextPairing.network
        } catch {
            lastError = "服务接管成功，但刷新配对码失败：\(error.localizedDescription)"
        }
    }

    func restoreHomebrew() async {
        guard !isBusy else { return }
        guard let oldAgent = homebrew.installedAgentBinary() else {
            fail(HomebrewServiceError.brewMissing)
            return
        }
        isBusy = true
        lifecycle = .starting
        lastError = nil
        defer { isBusy = false }
        do {
            try await services.unregisterAgent()
            try await homebrew.start()
            try await waitForHomebrewReady(binary: oldAgent)
            homebrewLoaded = true
            owner = .homebrew
            lifecycle = .migrationRequired
        } catch {
            await rollbackAfterFailedHomebrewRestore(cause: error)
        }
    }

    func refresh() async {
        guard !isBusy else { return }
        switch owner {
        case .homebrew:
            await refreshHomebrewStatus()
        case .macApp:
            await refreshMacAgentStatus()
        case .none:
            if !agent.configExists() {
                lifecycle = .notConfigured
            } else if await homebrew.isLoaded() {
                homebrewLoaded = true
                owner = .homebrew
                lifecycle = .migrationRequired
                await refreshHomebrewStatus()
            } else {
                await startMacAgentIfNeeded()
            }
        }
    }

    func refreshPairing(network: PairingNetwork? = nil) async {
        guard !isBusy else { return }
        lastError = nil
        do {
            let nextPairing = try await resolvedPairing(for: network)
            pairing = nextPairing
            pairingNetwork = nextPairing.network
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func prepareAutomaticNetworkBeforeServiceStart() async throws {
        do {
            _ = try await agent.pair(.automatic)
        } catch {
            // 旧配置可能仍绑定已卸载的 Tailscale IP；启动新服务前先切到 LAN 通配监听。
            _ = try await agent.setLANAccess(true)
        }
    }

    private func resolvedPairing(for requestedNetwork: PairingNetwork?) async throws -> PairingInfo {
        switch requestedNetwork ?? .automatic {
        case .automatic:
            do {
                return try await agent.pair(.automatic)
            } catch {
                // 自动模式只有 Tailscale 不可用时才应降级；LAN 准备失败会返回更可操作的错误。
                return try await localNetworkPairing()
            }
        case .tailscale:
            return try await agent.pair(.tailscale)
        case .localNetwork:
            return try await localNetworkPairing()
        }
    }

    private func localNetworkPairing() async throws -> PairingInfo {
        guard owner == .macApp else {
            throw AgentClientError.commandFailed("请先将 Homebrew 服务迁移到 Mimi Remote Mac，再启用局域网访问。")
        }
        let configuration = try await agent.setLANAccess(true)
        var restartedForLAN = false
        if configuration.restartRequired {
            // LAN 是扩大监听范围；仅配置首次变化时重启，后续刷新二维码不再打断连接。
            await restartService()
            guard lifecycle == .ready else {
                throw AgentClientError.commandFailed(lastError ?? "启用局域网后服务重启失败。")
            }
            restartedForLAN = true
        }

        var nextPairing = try await agent.pair(.localNetwork)
        if !(await health.checkDirect(nextPairing.endpoint)) {
            // 配置可能已开启但当前进程尚未加载；直连校验失败时只补一次重启。
            if !restartedForLAN {
                await restartService()
                guard lifecycle == .ready else {
                    throw AgentClientError.commandFailed(lastError ?? "局域网服务重启失败。")
                }
                nextPairing = try await agent.pair(.localNetwork)
            }
            guard await health.checkDirect(nextPairing.endpoint) else {
                throw AgentClientError.commandFailed("局域网地址暂时不可访问，请检查 macOS 本地网络权限或防火墙设置。")
            }
        }
        return nextPairing
    }

    func runDoctor(fix: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            let result = try await agent.doctor(fix)
            doctor = result.results
            appliedFixes = result.fixes
            switch owner {
            case .macApp:
                await refreshMacAgentStatus()
            case .homebrew:
                await refreshHomebrewStatus()
            case .none:
                if !result.results.ok {
                    lifecycle = .degraded(firstBlockingIssue(in: result.results))
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadRecentLogs() async {
        do {
            recentLogs = try await logs.recentLines(200)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func revealLogFile() {
        logs.reveal()
    }

    func openLoginItemsSettings() {
        services.openLoginItemsSettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        do {
            if enabled {
                try services.registerMainApp()
            } else {
                try await services.unregisterMainApp()
            }
            launchesAtLogin = services.mainAppStatus() == .enabled
        } catch {
            lastError = error.localizedDescription
            launchesAtLogin = services.mainAppStatus() == .enabled
        }
    }

    func restartService() async {
        guard !isBusy, owner == .macApp else { return }
        isBusy = true
        lifecycle = .starting
        lastError = nil
        defer { isBusy = false }
        do {
            try await services.unregisterAgent()
            // SMAppService.unregister() 返回时，launchd 的注册状态仍可能短暂保持 enabled。
            // 必须等状态真正落到未注册后再注册，否则第一次重启可能只完成停止。
            try await waitForMacAgentUnregistered()
            try services.registerAgent()
            try await waitForMacAgentReady()
        } catch {
            fail(error)
        }
    }

    /// 用户明确选择退出时才停止服务；停止失败则保留 App，避免制造错误的“已经断开”认知。
    func stopServiceAndQuit() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        do {
            switch owner {
            case .macApp:
                try await services.unregisterAgent()
            case .homebrew:
                try await homebrew.stop()
            case .none:
                break
            }
            owner = .none
            lifecycle = .stopped
            NSApplication.shared.terminate(nil)
        } catch {
            isBusy = false
            fail(error)
        }
    }

    private func startMacAgentIfNeeded() async {
        switch services.agentStatus() {
        case .enabled:
            owner = .macApp
            await refreshMacAgentStatus()
        case .notRegistered:
            lifecycle = .starting
            do {
                try await prepareAutomaticNetworkBeforeServiceStart()
                try services.registerAgent()
                owner = .macApp
                try await waitForMacAgentReady()
            } catch {
                fail(error)
            }
        case .requiresApproval:
            owner = .none
            lifecycle = .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。")
        case .notFound:
            owner = .none
            lifecycle = .failed("App 内缺少 LaunchAgent 配置，请重新安装。")
        }
    }

    private func waitForMacAgentReady() async throws {
        var lastStatus: AgentStatus?
        for _ in 0..<15 {
            try Task.checkCancellation()
            if let current = try? await agent.status() {
                lastStatus = current
                apply(current)
                if current.serviceOK { return }
            }
            try await Task.sleep(for: .seconds(1))
        }
        let detail = lastStatus?.serviceError ?? "服务在 15 秒内没有通过就绪检查。"
        throw AgentClientError.commandFailed(detail)
    }

    private func waitForMacAgentUnregistered() async throws {
        for attempt in 0..<40 {
            try Task.checkCancellation()
            switch services.agentStatus() {
            case .notRegistered:
                return
            case .enabled:
                break
            case .requiresApproval:
                throw ServiceLifecycleError.requiresApproval
            case .notFound:
                throw ServiceLifecycleError.agentNotFound
            }

            if attempt < 39 {
                try await Task.sleep(for: .milliseconds(125))
            }
        }
        throw ServiceLifecycleError.unregisterTimedOut
    }

    private func waitForHomebrewReady(binary: URL) async throws {
        var lastStatus: AgentStatus?
        for _ in 0..<15 {
            try Task.checkCancellation()
            if let current = try? await agent.statusAt(binary) {
                lastStatus = current
                if current.serviceOK {
                    status = current
                    doctor = current.doctor
                    return
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw AgentClientError.commandFailed(
            lastStatus?.serviceError ?? "Homebrew 服务恢复后没有通过就绪检查。"
        )
    }

    private func refreshMacAgentStatus() async {
        switch services.agentStatus() {
        case .enabled:
            do {
                apply(try await agent.status())
            } catch {
                fail(error)
            }
        case .requiresApproval:
            lifecycle = .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。")
        case .notRegistered:
            lifecycle = .stopped
        case .notFound:
            lifecycle = .failed("App 内缺少 LaunchAgent 配置，请重新安装。")
        }
    }

    private func refreshHomebrewStatus() async {
        guard let binary = homebrew.installedAgentBinary() else {
            lifecycle = .failed("Homebrew 服务仍在运行，但找不到对应 agentd。")
            return
        }
        do {
            let current = try await agent.statusAt(binary)
            status = current
            doctor = current.doctor
            if !current.serviceOK {
                lifecycle = .degraded(current.serviceError ?? "Homebrew 服务尚未就绪。")
            } else {
                lifecycle = .migrationRequired
            }
        } catch {
            fail(error)
        }
    }

    private func rollbackAfterFailedTakeover(oldAgent: URL, cause: Error) async {
        try? await services.unregisterAgent()
        do {
            try await homebrew.start()
            try await waitForHomebrewReady(binary: oldAgent)
            homebrewLoaded = true
            owner = .homebrew
            lifecycle = .migrationRequired
            lastError = "接管失败，已恢复 Homebrew 服务：\(cause.localizedDescription)"
        } catch {
            owner = .none
            lifecycle = .failed("接管失败，Homebrew 自动恢复也失败：\(error.localizedDescription)")
            lastError = cause.localizedDescription
        }
    }

    private func rollbackAfterFailedHomebrewRestore(cause: Error) async {
        // Homebrew start 可能“命令失败但服务已部分加载”，先清理它，避免双服务抢占端口。
        if await homebrew.isLoaded() {
            try? await homebrew.stop()
        }
        do {
            try services.registerAgent()
            owner = .macApp
            try await waitForMacAgentReady()
            homebrewLoaded = false
            lastError = "恢复 Homebrew 失败，已继续使用 App 服务：\(cause.localizedDescription)"
        } catch {
            owner = .none
            lifecycle = .failed("恢复 Homebrew 失败，App 服务自动恢复也失败：\(error.localizedDescription)")
            lastError = cause.localizedDescription
        }
    }

    private func apply(_ current: AgentStatus) {
        status = current
        doctor = current.doctor
        if current.serviceOK {
            lifecycle = .ready
        } else if current.processOK {
            lifecycle = .degraded(current.serviceError ?? firstBlockingIssue(in: current.doctor))
        } else {
            lifecycle = .stopped
        }
    }

    private func firstBlockingIssue(in results: AgentDoctorResults) -> String {
        results.checks.first { !$0.ok && !$0.isWarning }?.message ?? "环境检查未通过。"
    }

    private func enableLoginLaunchBestEffort() async {
        guard services.mainAppStatus() != .enabled else {
            launchesAtLogin = true
            return
        }
        do {
            try services.registerMainApp()
            launchesAtLogin = services.mainAppStatus() == .enabled
        } catch {
            launchesAtLogin = false
            lastError = "服务可继续使用，但登录启动未启用：\(error.localizedDescription)"
        }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                tick += 1
                if let endpoint = self.status?.endpoint,
                   (self.lifecycle == .ready || self.lifecycle == .migrationRequired),
                   !(await self.health.check(endpoint))
                {
                    await self.refresh()
                } else if tick.isMultiple(of: 30) {
                    // 常驻监控每 10 秒只做 loopback healthz；完整 status 会执行带鉴权的
                    // upstream WebSocket readiness，降到 5 分钟一次，避免控制面持续干扰数据面。
                    await self.refresh()
                }
            }
        }
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        lifecycle = .failed(error.localizedDescription)
    }

#if DEBUG
    static func preview(_ lifecycle: HostLifecycleState) -> HostStore {
        let check = AgentCheck(name: "codex", ok: true, level: "", message: "Codex CLI 可执行", fix: nil)
        let doctor = AgentDoctorResults(ok: true, version: "0.1.0", listen: "100.64.0.8:8787", checks: [check])
        let status = AgentStatus(
            processOK: true,
            serviceOK: true,
            processError: nil,
            serviceError: nil,
            version: "0.1.0",
            endpoint: "http://100.64.0.8:8787",
            configPath: "~/Library/Application Support/mimi-remote/config.json",
            projects: 12,
            doctorOK: true,
            doctor: doctor,
            pairExpires: nil
        )
        let agent = AgentCommandClient(
            configExists: { lifecycle != .notConfigured },
            setup: { _ in PairingInfo(endpoint: status.endpoint, pairURL: "mimiremote://pair?pair_sig=preview", expiresAt: "10 分钟后", warnings: []) },
            status: { status },
            statusAt: { _ in status },
            doctor: { _ in DoctorFixResults(fixes: [], results: doctor) },
            setLANAccess: { enabled in
                NetworkConfigurationResult(
                    lanEnabled: enabled,
                    changed: false,
                    restartRequired: false
                )
            },
            pair: { network in
                let endpoint = network == .localNetwork ? "http://192.168.31.20:8787" : status.endpoint
                return PairingInfo(
                    endpoint: endpoint,
                    pairURL: "mimiremote://pair?pair_sig=preview-\(network.rawValue)",
                    expiresAt: "10 分钟后",
                    warnings: network == .localNetwork ? ["局域网配对仅适用于与这台 Mac 位于同一局域网的设备"] : []
                )
            },
            version: { status.version }
        )
        let services = ServiceManagementClient(
            agentStatus: { .enabled }, registerAgent: {}, unregisterAgent: {},
            mainAppStatus: { .enabled }, registerMainApp: {}, unregisterMainApp: {},
            openLoginItemsSettings: {}
        )
        let homebrew = HomebrewServiceClient(
            isLoaded: { lifecycle == .migrationRequired }, installedAgentBinary: { nil },
            start: {}, stop: {}
        )
        let store = HostStore(
            agent: agent,
            services: services,
            homebrew: homebrew,
            health: HealthClient(check: { _ in true }, checkDirect: { _ in true }),
            logs: AgentLogClient(recentLines: { _ in [] }, reveal: {}, fileURL: URL(filePath: "/tmp/agentd.log"))
        )
        store.lifecycle = lifecycle
        if lifecycle != .notConfigured {
            store.status = status
            store.doctor = doctor
            store.owner = lifecycle == .migrationRequired ? .homebrew : .macApp
        }
        return store
    }
#endif
}

private enum ServiceLifecycleError: LocalizedError {
    case unregisterTimedOut
    case requiresApproval
    case agentNotFound

    var errorDescription: String? {
        switch self {
        case .unregisterTimedOut:
            "服务停止超时，未继续启动；请稍后重试。"
        case .requiresApproval:
            "请先在系统设置的登录项中允许 Mimi Remote Mac。"
        case .agentNotFound:
            "App 内缺少 LaunchAgent 配置，请重新安装。"
        }
    }
}
