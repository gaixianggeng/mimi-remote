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
    private(set) var isStoppingForQuit = false
    private(set) var isRefreshingStatus = false
    private(set) var homebrewLoaded = false
    private(set) var launchesAtLogin = false
    private(set) var claudeConfiguration: ClaudeConfigurationResult?
    private(set) var isUpdatingClaude = false
    private(set) var claudeError: String?
    private(set) var codexDesktopStatus = CodexDesktopStatus()
    private(set) var isUpdatingCodexDesktop = false
    private(set) var codexDesktopError: String?
    private(set) var photoLibraryAuthorization: PhotoLibraryAuthorization
    var lastError: String?

    var canRestoreHomebrew: Bool {
        owner == .macApp && homebrew.installedAgentBinary() != nil
    }

    var claudeEnabled: Bool {
        claudeConfiguration?.enabled ?? claudeRuntime?.enabled ?? false
    }

    var canChangeClaude: Bool {
        owner == .macApp && !isBusy && lifecycle != .loading && lifecycle != .starting
    }

    var codexDesktopEnabled: Bool {
        codexDesktopStatus.enabled
    }

    var isCodexDesktopBusy: Bool {
        isUpdatingCodexDesktop
    }

    var canChangeCodexDesktop: Bool {
        owner == .macApp
            && !isBusy
            && !isUpdatingCodexDesktop
            && lifecycle != .loading
            && lifecycle != .starting
    }

    var canRestartCodexDesktop: Bool {
        codexDesktopStatus.appInstalled
            && (codexDesktopStatus.appRunning
                || codexDaemonMigrationRequired
                || codexDisableNeedsFinalization
                || codexDesktopStatus.environment.pendingEnabled != nil)
            && owner == .macApp
            && !isBusy
            && !isUpdatingCodexDesktop
            && codexDesktopStatus.state == .pendingRestart
    }

    var codexDesktopStatusTitle: String {
        ExperimentPresentation.codexStatusTitle(for: codexDesktopStatus.state)
    }

    var codexDesktopStatusDetail: String {
        // 具体错误仍保留在 Store 供诊断和重试使用；展示层仅在待处理/失败边界附上
        // 脱敏后的诊断摘要，避免把底层协议错误（例如裸 -32600）直接暴露给用户。
        ExperimentPresentation.codexStatusDetail(
            for: codexDesktopStatus.state,
            error: codexDesktopError
        )
    }

    var experimentMenuStatusText: String? {
        ExperimentPresentation.menuStatusText(
            owner: owner,
            codexState: codexDesktopStatus.state
        )
    }

    var experimentMenuAccessibilityLabel: String {
        ExperimentPresentation.menuAccessibilityLabel(
            owner: owner,
            codexState: codexDesktopStatus.state
        )
    }

    var claudeStatusTitle: String {
        guard owner != .homebrew else { return "等待接管 App 服务" }
        guard let runtime = claudeRuntime else {
            return claudeEnabled ? "正在检查" : "已关闭"
        }
        switch runtime.state {
        case .connected: return "已连接"
        case .available: return "可用"
        case .signedOut: return "需要登录"
        case .disabled: return "已关闭"
        case .unavailable: return "暂不可用"
        }
    }

    var claudeStatusDetail: String {
        if owner == .homebrew {
            return "先完成 App 服务接管，再由 Mimi Remote Mac 管理 Claude 实验通道。"
        }
        if let claudeError {
            return claudeError
        }
        if let runtime = claudeRuntime, runtime.enabled {
            switch runtime.state {
            case .connected, .available:
                return "Claude Code 与 resident bridge 已就绪。"
            case .signedOut:
                return "已检测到 Claude Code，但尚未登录。请先在 Claude Code 中完成登录。"
            case .unavailable:
                return "Claude Runtime 暂不可用；请检查登录状态或打开诊断查看详情。"
            case .disabled:
                break
            }
        }
        return claudeConfiguration?.message
            ?? "启动时会检测 Claude Code；可用且已登录时自动启用，检测不到时保持关闭。"
    }

    private var claudeRuntime: AgentRuntimeStatus? {
        status?.runtimeStatus?.runtimes.first { $0.id.caseInsensitiveCompare("claude") == .orderedSame }
    }

    private var codexRuntime: AgentRuntimeStatus? {
        status?.runtimeStatus?.runtimes.first { $0.id.caseInsensitiveCompare("codex") == .orderedSame }
    }

    private var codexDaemonMigrationRequired: Bool {
        codexRuntime?.daemonRestartRequired == true && !codexDaemonMigrationCommittedLocally
    }

    /// 旧版半回滚或本次关闭事务中断时，只要目标仍是 disabled、后端仍共享，
    /// 或 launchd 里仍有 Mimi 专属 marker，就必须保留显式恢复入口。
    private var codexDisableNeedsFinalization: Bool {
        codexDesktopStatus.environment.pendingEnabled == false
            || (!codexDesktopEnabled
                && (codexBackendIsShared || codexDesktopStatus.environment.sessionEpoch != nil))
    }

    private let agent: AgentCommandClient
    private let services: ServiceManagementClient
    private let homebrew: HomebrewServiceClient
    private let health: HealthClient
    private let logs: AgentLogClient
    private let codexDesktop: CodexDesktopIntegrationClient
    private let photoLibraryAccess: PhotoLibraryAccessClient
    private let terminateApplication: @MainActor () -> Void
    private var didBootstrap = false
    private var didPreparePhotoLibraryAccess = false
    private var monitorTask: Task<Void, Never>?
    private var runtimeStatusFollowUpTask: Task<Void, Never>?
    private var stopServiceAndQuitTask: Task<Void, Never>?
    private var lastStatusRefreshAt: Date?
    // 每次开始 agent.status() 都先分配单调序号。只允许最新请求落地，避免
    // 迁移前已发出的 marker=true 在提交后的 fresh false 之后迟到并覆盖 UI。
    private var statusRequestSequence: UInt64 = 0
    // Go runtime 命令成功返回就是迁移提交点。其后的 status/inspect 可能仍读到
    // 瞬时旧值或失败，不能反向把已清 marker 的操作显示成失败或再次执行。
    private var codexDaemonMigrationCommittedLocally = false

    init(
        agent: AgentCommandClient,
        services: ServiceManagementClient,
        homebrew: HomebrewServiceClient,
        health: HealthClient,
        logs: AgentLogClient,
        codexDesktop: CodexDesktopIntegrationClient = .noop,
        photoLibraryAccess: PhotoLibraryAccessClient = .noop,
        terminateApplication: @escaping @MainActor () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        self.agent = agent
        self.services = services
        self.homebrew = homebrew
        self.health = health
        self.logs = logs
        self.codexDesktop = codexDesktop
        self.photoLibraryAccess = photoLibraryAccess
        photoLibraryAuthorization = photoLibraryAccess.authorizationStatus()
        self.terminateApplication = terminateApplication
    }

    static func live() -> HostStore {
        HostStore(
            agent: .live(),
            services: .live,
            homebrew: .live(),
            health: .live,
            logs: .live,
            codexDesktop: .live(),
            photoLibraryAccess: .live
        )
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        lifecycle = .loading
        await bootstrapCodexDesktop()
        homebrewLoaded = await homebrew.isLoaded()
        launchesAtLogin = services.mainAppStatus() == .enabled

        guard agent.configExists() else {
            lifecycle = .notConfigured
            startMonitoring()
            return
        }

        if homebrewLoaded {
            await enableLoginLaunchBestEffort()
            owner = .homebrew
            lifecycle = .migrationRequired
            await refreshHomebrewStatus()
        } else {
            do {
                try validateMacAgentConfiguration()
            } catch {
                owner = .none
                fail(error)
                startMonitoring()
                return
            }
            await enableLoginLaunchBestEffort()
            let reloadClaudeConfiguration = await reconcileClaudeConfigurationAtLaunch()
            await startMacAgentIfNeeded(reloadConfiguration: reloadClaudeConfiguration)
            await reconcileCodexDesktopAtLaunch()
        }
        if owner == .macApp, runtimeStatusNeedsFollowUp {
            // App 启动时就把服务端占位快照追到可展示结果，用户第一次展开
            // 菜单时通常直接命中 Store，而不是从那一刻才开始 Provider 探测。
            scheduleRuntimeStatusFollowUp()
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
            try validateMacAgentConfiguration()
            let nextPairing = try await agent.setup(workspaceRoot)
            pairing = nextPairing
            pairingNetwork = nextPairing.network
            _ = await reconcileClaudeConfigurationAtLaunch()
            await enableLoginLaunchBestEffort()
            owner = .macApp
            try await registerMacAgentAndWaitForReady()
            await reconcileCodexDesktopAtLaunch()
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
        do {
            // 在停止健康的 Homebrew 服务之前完成包资源与签名预检；无效测试包
            // 必须原地失败，不能让用户从可用服务跌入不可恢复状态。
            try validateMacAgentConfiguration()
        } catch {
            lastError = error.localizedDescription
            lifecycle = .migrationRequired
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
            owner = .macApp
            _ = await reconcileClaudeConfigurationAtLaunch()
            try await registerMacAgentAndWaitForReady()
            await reconcileCodexDesktopAtLaunch()
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
            try await unregisterMacAgentAndWait(endpoint: status?.endpoint)
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
        guard !isBusy, !isRefreshingStatus else { return }
        isRefreshingStatus = true
        defer { isRefreshingStatus = false }
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
        await refreshCodexDesktopStatus()
        if owner == .macApp, runtimeStatusNeedsFollowUp {
            scheduleRuntimeStatusFollowUp()
        }
    }

    /// MenuBarExtra 每次展开都会重建内容视图。短时间重复打开直接复用 Store
    /// 中的状态，避免为同一份服务状态反复启动 agentd 子进程。
    func refreshIfNeeded() async {
        guard lifecycle != .loading, lifecycle != .starting else { return }
        if let lastStatusRefreshAt,
           Date().timeIntervalSince(lastStatusRefreshAt) < 30,
           owner != .macApp || status?.runtimeStatus != nil
        {
            if owner == .macApp, runtimeStatusNeedsFollowUp {
                scheduleRuntimeStatusFollowUp()
            }
            return
        }
        await refresh()
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
        var restartMacAgent = false
        var restartHomebrewAgent = false
        do {
            let result = try await agent.doctor(fix)
            doctor = result.results
            appliedFixes = result.fixes
            restartMacAgent = fix && result.restartRequired == true && owner == .macApp
            restartHomebrewAgent = fix && result.restartRequired == true && owner == .homebrew
            switch owner {
            case .macApp:
                if !restartMacAgent {
                    await refreshMacAgentStatus()
                }
            case .homebrew:
                if !restartHomebrewAgent {
                    await refreshHomebrewStatus()
                }
            case .none:
                if !result.results.ok {
                    lifecycle = .degraded(firstBlockingIssue(in: result.results))
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        isBusy = false
        if restartMacAgent {
            // Doctor 改写 codex.bin、token 路径或整份配置后，resident agentd
            // 仍持有旧快照。正常注销/注册一次，让 shared owner 以新身份在锁内
            // 重建；不会停止当前 Codex daemon，也不会退出 Desktop。
            await restartService()
        } else if restartHomebrewAgent {
            await restartHomebrewAfterDoctorRepair()
        }
    }

    private func restartHomebrewAfterDoctorRepair() async {
        guard !isBusy, owner == .homebrew else { return }
        guard let binary = homebrew.installedAgentBinary() else {
            fail(HomebrewServiceError.commandFailed("Doctor 已提交配置，但找不到 Homebrew agentd，无法重载。"))
            return
        }
        isBusy = true
        lifecycle = .starting
        lastError = nil
        defer { isBusy = false }
        do {
            try await homebrew.stop()
            homebrewLoaded = false
            try await homebrew.start()
            try await waitForHomebrewReady(binary: binary)
            homebrewLoaded = true
            owner = .homebrew
            lifecycle = .migrationRequired
        } catch {
            fail(error)
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

    func openPhotosPrivacySettings() {
        photoLibraryAccess.openPhotosPrivacySettings()
    }

    func openFullDiskAccessSettings() {
        photoLibraryAccess.openFullDiskAccessSettings()
    }

    func setCodexDesktopEnabled(_ enabled: Bool) async {
        guard !isUpdatingCodexDesktop else { return }
        guard owner == .macApp, !isBusy else {
            codexDesktopError = "请先启动并接管 Mimi Remote Mac 服务，再修改 Codex Desktop 共享设置。"
            return
        }
        isBusy = true
        isUpdatingCodexDesktop = true
        codexDesktopError = nil
        defer {
            isUpdatingCodexDesktop = false
            isBusy = false
        }

        do {
            if enabled {
                await preparePhotoLibraryAccessForCodexDesktopSharing()
                // 先让 agentd 确保官方 app-server/local daemon 已就绪，再写入
                // Desktop 的 launchd 环境；backend 失败时绝不能留下无效 env。
                let sharing = try await configureCodexSharingAndReloadIfNeeded(true)
                let snapshot: CodexDesktopEnvironmentSnapshot
                do {
                    let runtimeCodexHome = try await waitForCodexRuntimeShared(true)
                    guard sharing.codexHome == nil || sharing.codexHome == runtimeCodexHome else {
                        throw AgentClientError.commandFailed("agentd 返回的 CODEX_HOME 前后不一致，已停止配置。")
                    }
                    snapshot = try await codexDesktop.setEnabled(
                        enabled,
                        runtimeCodexHome
                    )
                } catch {
                    // backend 是先切换的一端。只有本次命令真正改过配置时才回滚，
                    // 既有 Unix 用户的显式配置不能因 Desktop 环境冲突被擅自关闭。
                    if sharing.changed {
                        do {
                            _ = try await configureCodexSharingAndReloadIfNeeded(false)
                            _ = try await waitForCodexRuntimeShared(false)
                        } catch let rollbackError {
                            throw AgentClientError.commandFailed(
                                "配置 Codex Desktop 环境失败：\(error.localizedDescription)；agentd 自动恢复也失败：\(rollbackError.localizedDescription)"
                            )
                        }
                    }
                    throw error
                }
                applyCodexDesktopSnapshot(snapshot)
                return
            }
            // 设置页已经取得用户确认。禁用事务严格执行“退出旧 Desktop → 停止并
            // 验证共享 daemon → 提交 WS → 恢复 launchd 环境 → 按原状态重开”。
            // 任一步失败都不会在旧 Desktop 存活时提交独立 backend。
            let hadPendingDisable = codexDesktopStatus.environment.pendingEnabled == false
            var didCommitDisable = false
            let snapshot = try await codexDesktop.restartAndSetEnabled(
                false,
                codexHome: nil,
                afterTermination: {
                    _ = try await self.disableCodexSharingAfterDesktopExitAndReloadIfNeeded(
                        forceReload: hadPendingDisable
                    )
                    didCommitDisable = true
                    self.recordCommittedCodexMigration()
                }
            )
            applyCodexDesktopSnapshot(snapshot)
            if didCommitDisable {
                await refreshAfterCommittedCodexMigration()
            }
        } catch {
            codexDesktopError = error.localizedDescription
            await preserveCodexDesktopErrorState()
        }
    }

    /// 这是唯一会触碰 Codex Desktop 进程的入口，设置页必须先显示确认 alert。
    /// 失败时保留 pending restart，让用户可以按错误提示保存任务后重试。
    func restartCodexDesktop() async {
        guard !isUpdatingCodexDesktop else { return }
        guard owner == .macApp, !isBusy else {
            codexDesktopError = "请先等待 Mimi Remote Mac 服务操作完成，再重启 Codex Desktop。"
            return
        }
        guard codexDesktopStatus.appInstalled else {
            codexDesktopError = "未检测到 Codex Desktop。"
            return
        }
        guard codexDesktopStatus.appRunning
            || codexDaemonMigrationRequired
            || codexDisableNeedsFinalization
            || codexDesktopStatus.environment.pendingEnabled != nil
        else {
            codexDesktopError = "Codex Desktop 当前未运行，也没有待迁移的共享 daemon。"
            return
        }

        isBusy = true
        isUpdatingCodexDesktop = true
        codexDesktopError = nil
        defer {
            isUpdatingCodexDesktop = false
            isBusy = false
        }
        var didCommitDaemonMigration = false
        let hadPendingDisable = codexDesktopStatus.environment.pendingEnabled == false
        do {
            // 先读取一次真实状态，避免只凭设置页缓存决定是否需要 terminate。
            // 即便这里看到 running，live runtime 仍会在实际执行时再取快照，
            // 覆盖用户在两次读取之间自行退出 Desktop 的竞态。
            let currentDesktop = try await codexDesktop.inspect()
            if !currentDesktop.appRunning,
               currentDesktop.pendingEnabled == nil,
               codexDaemonMigrationRequired || codexDisableNeedsFinalization
            {
                // Desktop 本来已退出时只提交待处理的 backend 切换，不擅自打开
                // App。禁用路径会在提交 WS 前确认旧 listener 与 loaded job 消失。
                if codexDesktopEnabled {
                    try await agent.restartCodexSharing()
                } else {
                    // 旧版半回滚可能只留下 launchd 环境而 Desktop 已经退出。
                    // 先清理旧 daemon 并提交 WS，再恢复环境；中途失败时 Desktop
                    // 保持关闭，不能让它按独立环境重新连到仍共享的 backend。
                    _ = try await disableCodexSharingAfterDesktopExitAndReloadIfNeeded(
                        forceReload: hadPendingDisable
                    )
                    let disabledEnvironment = try await codexDesktop.setEnabled(false, nil)
                    applyCodexDesktopSnapshot(disabledEnvironment)
                }
                didCommitDaemonMigration = true
                recordCommittedCodexMigration()
                await refreshAfterCommittedCodexMigration()
                return
            }
            let snapshot = try await codexDesktop.restartAndApply(afterTermination: {
                // 用户确认后，backend 迁移严格位于旧 Desktop 退出与新实例打开
                // 之间。禁用只有在旧 Unix listener 和 loaded job 均消失后才提交 WS。
                let targetEnabled = self.codexDesktopStatus.environment.pendingEnabled
                    ?? self.codexDesktopEnabled
                if targetEnabled {
                    if self.codexDaemonMigrationRequired {
                        try await self.agent.restartCodexSharing()
                        didCommitDaemonMigration = true
                        self.recordCommittedCodexMigration()
                    }
                } else {
                    _ = try await self.disableCodexSharingAfterDesktopExitAndReloadIfNeeded(
                        forceReload: hadPendingDisable
                    )
                    didCommitDaemonMigration = true
                    self.recordCommittedCodexMigration()
                }
            })
            applyCodexDesktopSnapshot(snapshot)
            if didCommitDaemonMigration {
                await refreshAfterCommittedCodexMigration()
            }
        } catch {
            codexDesktopError = error.localizedDescription
            // 不强制终止也不再并发启动第二个实例；terminate/open 超时或拒绝
            // 时，当前进程仍在运行，状态必须继续显示 pending restart。
            await preserveCodexDesktopErrorState(forcePending: true)
        }
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

    func setClaudeEnabled(_ enabled: Bool) async {
        guard !isBusy, owner == .macApp else {
            claudeError = "请先启动并接管 Mimi Remote Mac 服务。"
            return
        }
        isBusy = true
        isUpdatingClaude = true
        claudeError = nil
        defer {
            isUpdatingClaude = false
            isBusy = false
        }

        do {
            let preference: ClaudeActivationPreference = enabled ? .enabled : .disabled
            let result = try await agent.configureClaude(preference, nil)
            claudeConfiguration = result
            guard !enabled || result.enabled else {
                claudeError = result.message
                return
            }
            if result.restartRequired {
                do {
                    try await reloadMacAgentForConfigurationChange()
                    try await waitForClaudeRuntime(enabled: result.enabled)
                } catch {
                    let updateError = error
                    let rolledBack = await rollbackClaudeConfiguration(result)
                    let rollbackDetail = rolledBack
                        ? "已恢复修改前的 Claude 设置。"
                        : "自动恢复也失败，请打开诊断后重试。"
                    claudeError = "更新 Claude 设置失败：\(updateError.localizedDescription) \(rollbackDetail)"
                }
            } else {
                await refreshMacAgentStatus()
            }
        } catch {
            claudeError = error.localizedDescription
        }
    }

    func restartService() async {
        guard !isBusy, owner == .macApp else { return }
        isBusy = true
        lifecycle = .starting
        lastError = nil
        defer { isBusy = false }
        do {
            try validateMacAgentConfiguration()
            try await unregisterMacAgentAndWait(endpoint: status?.endpoint)
            try await registerMacAgentAndWaitForReady()
        } catch {
            fail(error)
        }
    }

    /// failed/stopped 状态下的显式恢复入口。只执行一次启动闭环，失败后保留诊断信息，
    /// 不在后台无限重试，也不改变现有 Token 和配对关系。
    func repairAndStartService() async {
        guard !isBusy else { return }
        if owner == .macApp {
            await restartService()
            return
        }

        isBusy = true
        lifecycle = .starting
        lastError = nil
        defer { isBusy = false }

        guard agent.configExists() else {
            lifecycle = .notConfigured
            return
        }
        if await homebrew.isLoaded() {
            homebrewLoaded = true
            owner = .homebrew
            lifecycle = .migrationRequired
            await refreshHomebrewStatus()
            return
        }
        if services.agentStatus() == .requiresApproval {
            owner = .none
            lifecycle = .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。")
            services.openLoginItemsSettings()
            return
        }
        await enableLoginLaunchBestEffort()
        await startMacAgentIfNeeded()
    }

    /// 菜单栏弹窗关闭后对应 View 可能立即销毁，因此停止任务必须由长生命周期的 Store 持有。
    /// 这个同步入口还会立即更新 UI，让用户明确知道点击已经生效。
    func requestStopServiceAndQuit() {
        guard !isBusy, stopServiceAndQuitTask == nil else { return }
        isBusy = true
        isStoppingForQuit = true
        lastError = nil
        stopServiceAndQuitTask = Task { [weak self] in
            await self?.performStopServiceAndQuit()
        }
    }

    /// 用户明确选择退出时才停止服务；停止失败则保留 App，避免制造错误的“已经断开”认知。
    private func performStopServiceAndQuit() async {
        do {
            switch owner {
            case .macApp:
                // App 退出前确认 LaunchAgent 已注销且 HTTP listener 已关闭；
                // agentd 的 shutdown 会在这段时间同步回收 resident Claude bridge。
                try await unregisterMacAgentAndWait(endpoint: status?.endpoint)
            case .homebrew:
                try await homebrew.stop()
            case .none:
                break
            }
            owner = .none
            lifecycle = .stopped
            terminateApplication()
        } catch {
            isBusy = false
            isStoppingForQuit = false
            stopServiceAndQuitTask = nil
            fail(error)
        }
    }

    private func startMacAgentIfNeeded(reloadConfiguration: Bool = false) async {
        do {
            // `.enabled` 也可能只是遗留的 BTM 记录；先验证当前包的签名身份，
            // 避免 ad-hoc 二进制进入 unregister/register 和 launchd 重试循环。
            try validateMacAgentConfiguration()
        } catch {
            owner = .none
            fail(error)
            return
        }

        switch services.agentStatus() {
        case .enabled:
            owner = .macApp
            if reloadConfiguration {
                do {
                    try await reloadMacAgentForConfigurationChange()
                } catch {
                    fail(error)
                }
                return
            }

            if !services.isAgentRegistrationCurrent() {
                // Apple 要求 LaunchAgent 的 plist 或可执行文件更新后重新注册。
                // 先于状态命令处理，才能修复旧签名约束在进程启动前直接 SIGKILL 的升级。
                lifecycle = .starting
                do {
                    try await unregisterMacAgentAndWait(endpoint: status?.endpoint)
                    try await registerMacAgentAndWaitForReady(allowAutomaticRepair: false)
                } catch {
                    fail(error)
                }
                return
            }

            let current: AgentStatus
            do {
                guard let latest = try await fetchAndApplyLatestStatus() else { return }
                current = latest
            } catch is CancellationError {
                return
            } catch {
                // 已登记却无法执行 status，常见原因是覆盖安装后仍复用旧的 Launch Constraint。
                // 自动执行一次完整换代，成功后即停止；失败则交给用户诊断，不循环重启。
                await repairEnabledMacAgent(after: error)
                return
            }
            if !current.processOK {
                // status 命令本身可以成功，但它可能明确报告 resident agentd 未运行。
                // 首次打开必须把这种状态当作启动失败，自动做一次有界换代，而不是
                // 落到 stopped 后要求用户点击“修复并启动服务”。
                let detail = current.processError ?? current.serviceError ?? "agentd 进程未启动。"
                await repairEnabledMacAgent(after: AgentClientError.commandFailed(detail))
            } else if current.hasAgentVersionMismatch {
                // 覆盖安装不会自动替换 launchd 已映射的旧二进制。只在 App
                // 启动阶段发现明确版本漂移时做一次受控换代，避免长期半更新。
                lifecycle = .starting
                do {
                    try await unregisterMacAgentAndWait(endpoint: current.endpoint)
                    try await registerMacAgentAndWaitForReady(allowAutomaticRepair: false)
                } catch {
                    fail(error)
                }
            } else {
                // fetchAndApplyLatestStatus 已经落地最新状态。
            }
        case .notRegistered:
            await registerAvailableMacAgent(recoveringMissingRecord: false)
        case .requiresApproval:
            owner = .none
            lifecycle = .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。")
        case .notFound:
            // `.notFound` 是 ServiceManagement 的泛化状态，不代表包内 plist 缺失。
            // 资源完整时主动登记一次，正好覆盖 BTM 丢记录和首次安装两种现场。
            await registerAvailableMacAgent(recoveringMissingRecord: true)
        }
    }

    private func registerAvailableMacAgent(recoveringMissingRecord: Bool) async {
        if let configurationError = services.agentConfigurationError() {
            owner = .none
            lifecycle = .failed(configurationError)
            lastError = configurationError
            return
        }

        lifecycle = .starting
        do {
            try await prepareAutomaticNetworkBeforeServiceStart()
            owner = .macApp
            try await registerMacAgentAndWaitForReady()
        } catch {
            switch services.agentStatus() {
            case .requiresApproval:
                owner = .none
                lifecycle = .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。")
            case .enabled:
                owner = .macApp
                fail(error)
            case .notRegistered, .notFound:
                owner = .none
                if recoveringMissingRecord {
                    fail(ServiceLifecycleError.agentRegistrationFailed(error.localizedDescription))
                } else {
                    fail(error)
                }
            }
        }
    }

    private func repairEnabledMacAgent(after initialError: Error) async {
        lifecycle = .starting
        do {
            try await unregisterMacAgentAndWait(endpoint: status?.endpoint)
            try await registerMacAgentAndWaitForReady(allowAutomaticRepair: false)
        } catch {
            fail(ServiceLifecycleError.automaticRepairFailed(
                initial: initialError.localizedDescription,
                recovery: error.localizedDescription
            ))
        }
    }

    /// 启动检测只在 Mac App owner 上执行；auto 会尊重配置中已经记录的显式开关。
    private func reconcileClaudeConfigurationAtLaunch() async -> Bool {
        do {
            let result = try await agent.configureClaude(.automatic, nil)
            claudeConfiguration = result
            claudeError = result.available || result.preference == .disabled
                ? nil
                : result.message
            return result.restartRequired
        } catch {
            // Claude 是实验通道；预检失败不能破坏 Codex 主服务启动。
            claudeError = "Claude 自动检测失败：\(error.localizedDescription)"
            return false
        }
    }

    private func bootstrapCodexDesktop() async {
        do {
            let snapshot = try await codexDesktop.bootstrap()
            applyCodexDesktopSnapshot(snapshot)
        } catch {
            codexDesktopError = error.localizedDescription
            await preserveCodexDesktopErrorState()
        }
    }

    /// 启动时不会替用户开启共享，也不会终止 Desktop。只有 UserDefaults 已记录
    /// 用户曾显式启用、且 agentd 已确认同一个 Unix backend 时，才恢复当前登录
    /// 会话中会丢失的 launchd 环境；这样注销/登录后无需再次手动关开 Toggle。
    private func reconcileCodexDesktopAtLaunch() async {
        do {
            var inspected = try await codexDesktop.inspect()
            if inspected.hasLocalPreference, inspected.enabled {
                var runtimeCodexHome = codexBackendIsShared
                    ? codexRuntime?.codexHome
                    : nil
                let environmentNeedsRestore = inspected.environmentValue != "1"
                    || inspected.codexHome == nil

                if environmentNeedsRestore,
                   runtimeCodexHome == nil,
                   shouldWaitForCodexSharedRuntimeAtLaunch
                {
                    // 登录后 launchd 会清空 setenv 写入的三项环境，而 agentd 的
                    // runtime snapshot 可能比 HTTP readiness 晚几秒返回。用户已经
                    // 显式启用共享时必须在这里有界等待，否则这次启动会永久跳过
                    // 恢复，随后 Desktop 又会抢先拉起独立 stdio app-server。
                    runtimeCodexHome = try await waitForCodexRuntimeShared(true)
                }

                if let runtimeCodexHome,
                   inspected.environmentValue != "1"
                    || inspected.codexHome != runtimeCodexHome
                {
                    inspected = try await codexDesktop.setEnabled(true, runtimeCodexHome)
                }
            }
            codexDesktopError = nil
            applyCodexDesktopSnapshot(inspected)
        } catch {
            codexDesktopError = error.localizedDescription
            await preserveCodexDesktopErrorState()
        }
    }

    /// nil 表示 agentd 尚未返回 Codex runtime；shared=true 但未 ready 也需要继续等。
    /// 明确的 websocket/non-shared runtime 则立即停止，不能为了恢复 Desktop 环境
    /// 擅自改变用户已经选择的后端配置。
    private var shouldWaitForCodexSharedRuntimeAtLaunch: Bool {
        guard let runtime = codexRuntime else { return true }
        return runtime.shared == true
    }

    private func configureCodexSharingAndReloadIfNeeded(
        _ enabled: Bool,
        allowUnregistered: Bool = false
    ) async throws -> CodexSharingConfigurationResult {
        let result = try await agent.configureCodexSharing(enabled)
        guard result.enabled == enabled else {
            throw AgentClientError.commandFailed(
                result.message.isEmpty
                    ? (enabled ? "agentd 未能启用 Codex Desktop 共享。" : "agentd 未能关闭 Codex Desktop 共享。")
                    : result.message
            )
        }
        guard result.restartRequired else { return result }

        if allowUnregistered, services.agentStatus() != .enabled {
            // 新 setup 尚未登记 LaunchAgent；后续首次 register 会直接使用新配置。
            return result
        }
        do {
            try await reloadMacAgentForConfigurationChange()
        } catch {
            let reloadError = error
            // CLI 已经原子提交配置，但服务重载可能在 unregister/register 中途失败。
            // 只有本次命令真正改过配置时才反向写回并再重载；外部既有配置不接管。
            guard result.changed else { throw reloadError }
            do {
                let rollback = try await agent.configureCodexSharing(!enabled)
                if rollback.restartRequired {
                    try await reloadMacAgentForConfigurationChange()
                }
            } catch let rollbackError {
                throw AgentClientError.commandFailed(
                    "重载 Codex 共享配置失败：\(reloadError.localizedDescription)；自动恢复配置也失败：\(rollbackError.localizedDescription)"
                )
            }
            throw reloadError
        }
        return result
    }

    /// 只在 Codex Desktop 已由受控流程正常退出后调用。Go 端会再次检查 Desktop
    /// 状态，并在提交 WS 配置前验证旧 Unix listener、PID 与 loaded job 均已消失。
    /// 配置一旦安全提交，服务重载失败也不反向启动共享 daemon，避免重新制造双后端。
    private func disableCodexSharingAfterDesktopExitAndReloadIfNeeded(
        forceReload: Bool = false
    ) async throws
        -> CodexSharingConfigurationResult
    {
        let result = try await agent.disableCodexSharingAfterDesktopExit()
        guard !result.enabled else {
            throw AgentClientError.commandFailed(
                result.message.isEmpty
                    ? "agentd 未能关闭 Codex Desktop 共享。"
                    : result.message
            )
        }
        if result.restartRequired || forceReload {
            try await reloadMacAgentForConfigurationChange()
        }
        // 外部管理的 Unix backend 不属于 Mimi，显式关闭只恢复 Desktop 环境，
        // 不等待它变成 WS，也不停止外部进程。
        if result.transport?.caseInsensitiveCompare("unix") != .orderedSame {
            _ = try await waitForCodexRuntimeShared(false)
        }
        return result
    }

    private func waitForCodexRuntimeShared(_ expected: Bool) async throws -> String? {
        var lastRuntime: AgentRuntimeStatus?
        for attempt in 0..<12 {
            try Task.checkCancellation()
            if let current = try? await fetchAndApplyLatestStatus() {
                lastRuntime = current.runtimeStatus?.runtimes.first(where: {
                    $0.id.caseInsensitiveCompare("codex") == .orderedSame
                })
                if let runtime = lastRuntime {
                    let isShared = runtime.shared == true
                        && runtime.transport?.caseInsensitiveCompare("unix") == .orderedSame
                    if expected {
                        let runtimeReady = isShared
                            && (runtime.state == .connected || runtime.state == .available)
                            && runtime.codexHome?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        if runtimeReady {
                            return runtime.codexHome
                        }
                    } else if !isShared {
                        return nil
                    }
                }
            }
            if attempt < 11 {
                try await Task.sleep(for: .seconds(1))
            }
        }
        let detail = expected
            ? "agentd 尚未确认 Codex Desktop 的 Unix 共享已就绪（需要 connected/available 与 CODEX_HOME）。"
            : "agentd 关闭 Codex Desktop 共享后仍未返回确认。"
        throw AgentClientError.commandFailed(detail)
    }

    private func reloadMacAgentForConfigurationChange() async throws {
        try validateMacAgentConfiguration()
        lifecycle = .starting
        let endpoint: String?
        if let currentEndpoint = status?.endpoint {
            endpoint = currentEndpoint
        } else {
            endpoint = (try? await agent.status())?.endpoint
        }
        switch services.agentStatus() {
        case .enabled:
            try await unregisterMacAgentAndWait(endpoint: endpoint)
        case .notRegistered, .notFound:
            // main 已把 `.notFound` 视为 BTM 记录缺失等可恢复状态；配置重载时
            // 直接重新登记，让统一注册流程负责资源校验和自动修复。
            break
        case .requiresApproval:
            throw ServiceLifecycleError.requiresApproval
        }
        owner = .macApp
        try await registerMacAgentAndWaitForReady()
    }

    private func waitForClaudeRuntime(enabled: Bool) async throws {
        for attempt in 0..<12 {
            try Task.checkCancellation()
            if let current = try? await fetchAndApplyLatestStatus() {
                if let runtime = current.runtimeStatus?.runtimes.first(where: {
                    $0.id.caseInsensitiveCompare("claude") == .orderedSame
                }) {
                    if !enabled, !runtime.enabled || runtime.state == .disabled {
                        return
                    }
                    if enabled {
                        switch runtime.state {
                        case .connected, .available:
                            return
                        case .signedOut:
                            throw ClaudeRuntimeControlError.signedOut
                        case .unavailable where runtime.reason != "refresh_in_progress":
                            throw ClaudeRuntimeControlError.unavailable
                        case .disabled:
                            throw ClaudeRuntimeControlError.disabled
                        case .unavailable:
                            break
                        }
                    }
                }
            }
            if attempt < 11 {
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw ClaudeRuntimeControlError.timedOut(enabled: enabled)
    }

    private func rollbackClaudeConfiguration(_ changed: ClaudeConfigurationResult) async -> Bool {
        do {
            let restored = try await agent.configureClaude(
                changed.previousPreference,
                changed.previousEnabled
            )
            claudeConfiguration = restored
            try await reloadMacAgentForConfigurationChange()
            try await waitForClaudeRuntime(enabled: restored.enabled)
            return true
        } catch {
            return false
        }
    }

    private func waitForMacAgentReady() async throws {
        var lastStatus: AgentStatus?
        for _ in 0..<15 {
            try Task.checkCancellation()
            if let current = try? await fetchAndApplyLatestStatus() {
                lastStatus = current
                if current.serviceOK { return }
            }
            try await Task.sleep(for: .seconds(1))
        }
        let detail = lastStatus?.serviceError ?? "服务在 15 秒内没有通过就绪检查。"
        throw AgentClientError.commandFailed(detail)
    }

    private func registerMacAgentAndWaitForReady(
        allowAutomaticRepair: Bool = true
    ) async throws {
        try validateMacAgentConfiguration()
        if codexDesktopStatus.environment.hasLocalPreference,
           codexDesktopStatus.environment.enabled
        {
            await preparePhotoLibraryAccessForCodexDesktopSharing()
        }
        do {
            try services.registerAgent()
            try await waitForMacAgentReady()
            // 只有新登记的进程真正通过就绪检查后才记账；失败时下次启动仍会重试迁移。
            services.markAgentRegistrationCurrent()
        } catch {
            guard allowAutomaticRepair, services.agentStatus() == .enabled else {
                throw error
            }

            let initialError = error
            do {
                // register 已落入 enabled 但进程未就绪时，完整换代一次以刷新 BTM
                // 的 Launch Constraint；递归调用关闭修复开关，保证最多只重试一次。
                try await unregisterMacAgentAndWait(endpoint: status?.endpoint)
                try await registerMacAgentAndWaitForReady(allowAutomaticRepair: false)
            } catch {
                throw ServiceLifecycleError.automaticRepairFailed(
                    initial: initialError.localizedDescription,
                    recovery: error.localizedDescription
                )
            }
        }
    }

    /// 照片授权由可见 App 请求，避免后台 agentd 启动时静默触发 TCC 弹窗。
    /// 用户拒绝时仍允许 Codex Desktop 共享继续启用，并保留设置页的手动修复入口。
    private func preparePhotoLibraryAccessForCodexDesktopSharing() async {
        guard !didPreparePhotoLibraryAccess else { return }
        didPreparePhotoLibraryAccess = true

        let current = photoLibraryAccess.authorizationStatus()
        photoLibraryAuthorization = current
        guard current == .notDetermined else { return }
        photoLibraryAuthorization = await photoLibraryAccess.requestAuthorization()
    }

    private func waitForMacAgentUnregistered() async throws {
        for attempt in 0..<40 {
            try Task.checkCancellation()
            switch services.agentStatus() {
            case .notRegistered, .notFound:
                return
            case .enabled:
                break
            case .requiresApproval:
                throw ServiceLifecycleError.requiresApproval
            }

            if attempt < 39 {
                try await Task.sleep(for: .milliseconds(125))
            }
        }
        throw ServiceLifecycleError.unregisterTimedOut
    }

    private func unregisterMacAgentAndWait(endpoint: String?) async throws {
        try await services.unregisterAgent()
        do {
            // SMAppService.unregister() 返回时，launchd 的注册状态仍可能短暂保持 enabled。
            // 先等状态落到未注册，再确认旧 listener 消失，防止新注册误连到旧进程。
            try await waitForMacAgentUnregistered()
        } catch let error as ServiceLifecycleError {
            guard case .unregisterTimedOut = error else { throw error }

            // macOS 27 的 BTM 在覆盖安装后偶尔会留下半注销的 job：第一次
            // unregister 已返回，但状态一直停在 enabled。再做一次有界注销可
            // 清掉这个残留；只有确认状态进入未注册后，调用方才允许重新注册。
            try Task.checkCancellation()
            try await services.unregisterAgent()
            try await waitForMacAgentUnregistered()
        }
        if let endpoint {
            try await waitForMacAgentStopped(endpoint: endpoint)
        }
    }

    private func waitForMacAgentStopped(endpoint: String) async throws {
        for attempt in 0..<30 {
            try Task.checkCancellation()
            if !(await health.check(endpoint)) {
                return
            }
            if attempt < 29 {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw ServiceLifecycleError.stopTimedOut
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
                _ = try await fetchAndApplyLatestStatus()
            } catch is CancellationError {
                return
            } catch {
                fail(error)
            }
        case .requiresApproval:
            lifecycle = .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。")
        case .notRegistered:
            lifecycle = .stopped
        case .notFound:
            owner = .none
            await startMacAgentIfNeeded()
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
            lastStatusRefreshAt = Date()
            if !current.serviceOK {
                lifecycle = .degraded(current.serviceError ?? "Homebrew 服务尚未就绪。")
            } else {
                lifecycle = .migrationRequired
            }
        } catch is CancellationError {
            return
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
            owner = .macApp
            try await registerMacAgentAndWaitForReady()
            homebrewLoaded = false
            lastError = "恢复 Homebrew 失败，已继续使用 App 服务：\(cause.localizedDescription)"
        } catch {
            owner = .none
            lifecycle = .failed("恢复 Homebrew 失败，App 服务自动恢复也失败：\(error.localizedDescription)")
            lastError = cause.localizedDescription
        }
    }

    private func apply(_ current: AgentStatus) {
        // 本地提交标记只遮蔽命令成功前留在内存里的旧 pending 快照。下一份
        // 真正携带 daemonRestartRequired 的服务端状态无论 true/false 都是新事实：
        // false 确认提交，true 则表示服务端又检测到新的 unmanaged owner。
        if codexDaemonMigrationCommittedLocally,
           let runtime = current.runtimeStatus?.runtimes.first(where: {
               $0.id.caseInsensitiveCompare("codex") == .orderedSame
           }),
           runtime.daemonRestartRequired != nil {
            codexDaemonMigrationCommittedLocally = false
        }
        let resolved = preservingRuntimeSnapshotIfNeeded(in: current)
        status = resolved
        doctor = resolved.doctor
        lastStatusRefreshAt = Date()
        refreshCodexDesktopPresentation()
        if resolved.serviceOK {
            lifecycle = .ready
        } else if resolved.processOK {
            lifecycle = .degraded(
                resolved.serviceError ?? firstBlockingIssue(in: resolved.doctor)
            )
        } else {
            lifecycle = .stopped
        }
    }

    private func nextStatusRequestSequence() -> UInt64 {
        statusRequestSequence &+= 1
        return statusRequestSequence
    }

    private func invalidateInFlightStatusRequests() {
        statusRequestSequence &+= 1
    }

    private func recordCommittedCodexMigration() {
        codexDaemonMigrationCommittedLocally = true
        // Go 命令返回就是提交点。必须在重新打开 Desktop 的 await 之前立刻
        // 作废迁移前请求，不能等 application.open 完成后再处理迟到旧状态。
        invalidateInFlightStatusRequests()
    }

    @discardableResult
    private func applyStatusResponse(_ current: AgentStatus, sequence: UInt64) -> Bool {
        guard sequence == statusRequestSequence else { return false }
        apply(current)
        return true
    }

    private func fetchAndApplyLatestStatus() async throws -> AgentStatus? {
        let sequence = nextStatusRequestSequence()
        let current = try await agent.status()
        return applyStatusResponse(current, sequence: sequence) ? current : nil
    }

    private func refreshAfterCommittedCodexMigration() async {
        // 这些读取只刷新展示，不是第二个提交门。任一瞬时失败都保留 Go 已提交
        // 的成功事实，Desktop 重开顺序也不受 12 秒轮询影响。
        // recordCommittedCodexMigration 已在 Go 成功的同一同步段作废旧请求；
        // 这里再发出新的权威刷新，失败也不反向改变提交事实。
        _ = try? await fetchAndApplyLatestStatus()
        if let snapshot = try? await codexDesktop.inspect() {
            applyCodexDesktopSnapshot(snapshot)
        } else {
            refreshCodexDesktopPresentation()
        }
    }

    private func applyCodexDesktopSnapshot(
        _ snapshot: CodexDesktopEnvironmentSnapshot,
        forcePending: Bool = false
    ) {
        let state = codexDesktopState(
            for: snapshot,
            forcePending: forcePending
        )
        codexDesktopStatus = CodexDesktopStatus(
            environment: snapshot,
            state: state,
            error: codexDesktopError
        )
    }

    private func refreshCodexDesktopPresentation() {
        applyCodexDesktopSnapshot(codexDesktopStatus.environment)
    }

    private func refreshCodexDesktopStatus() async {
        do {
            let snapshot = try await codexDesktop.inspect()
            codexDesktopError = nil
            applyCodexDesktopSnapshot(snapshot)
        } catch is CancellationError {
            return
        } catch {
            // 显式刷新必须暴露读取失败，不能继续把旧的进程/环境快照显示成实时状态。
            codexDesktopError = error.localizedDescription
            applyCodexDesktopSnapshot(codexDesktopStatus.environment)
        }
    }

    private func codexDesktopState(
        for snapshot: CodexDesktopEnvironmentSnapshot,
        forcePending: Bool = false
    ) -> CodexDesktopStatusState {
        if let codexDesktopError {
            if codexDesktopError.contains("外部") || codexDesktopError.contains("已被其他程序") {
                return .externalConflict
            }
            if (forcePending || snapshot.pendingEnabled != nil),
               snapshot.appRunning
                   || codexDaemonMigrationRequired
                   || codexDisableNeedsFinalization
                   || snapshot.pendingEnabled != nil
            {
                return .pendingRestart
            }
            return .failed
        }
        if snapshot.appInstalled == false {
            return .notInstalled
        }
        if snapshot.pendingEnabled != nil {
            return .pendingRestart
        }
        if snapshot.enabled, codexDaemonMigrationRequired {
            return .pendingRestart
        }
        if snapshot.restartRequired, snapshot.appRunning {
            return .pendingRestart
        }
        if !snapshot.enabled {
            // 共享 backend 尚未完成关闭，或旧版半回滚留下 Mimi 专属 marker 时，
            // 必须继续提供“应用设置”入口。只有确认流程完成后才能显示已关闭。
            if codexBackendIsShared || snapshot.sessionEpoch != nil {
                return .pendingRestart
            }
            if snapshot.environmentValue == "1" {
                return .externalConflict
            }
            return .disabled
        }
        if snapshot.environmentValue != nil, snapshot.environmentValue != "1" {
            return .externalConflict
        }
        if snapshot.enabled,
           snapshot.writtenValue == "1",
           !snapshot.ownsEnvironment
        {
            // 旧登录会话的官方值即使与当前外部值相同，也没有匹配的 Mimi
            // ownership epoch；显示冲突，避免用户以为禁用时可以安全删除它。
            return .externalConflict
        }
        if snapshot.enabled,
           snapshot.writtenCodexHome != nil,
           !snapshot.ownsCodexHome
        {
            return .externalConflict
        }
        if snapshot.environmentValue != "1" || snapshot.codexHome == nil {
            return .backendNotShared
        }
        if !codexBackendIsShared {
            return .backendNotShared
        }
        if snapshot.codexHome != codexRuntime?.codexHome {
            return .externalConflict
        }
        return .ready
    }

    private var codexBackendIsShared: Bool {
        guard let runtime = codexRuntime else { return false }
        // transport/shared 是后端明确声明的互操作契约；旧 JSON 缺字段时不能
        // 根据 title/id 猜测已共享，避免 UI 给出错误的“已就绪”。
        return runtime.shared == true
            && runtime.transport?.caseInsensitiveCompare("unix") == .orderedSame
            && (runtime.state == .connected || runtime.state == .available)
            && runtime.codexHome?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func preserveCodexDesktopErrorState(forcePending: Bool = false) async {
        if let snapshot = try? await codexDesktop.inspect() {
            applyCodexDesktopSnapshot(snapshot, forcePending: forcePending)
        } else {
            let current = codexDesktopStatus
            let shouldKeepPending = forcePending
                || current.environment.pendingEnabled != nil
            let state: CodexDesktopStatusState = shouldKeepPending
                && (current.appRunning
                    || codexDaemonMigrationRequired
                    || codexDisableNeedsFinalization
                    || current.environment.pendingEnabled != nil)
                ? .pendingRestart
                : .failed
            codexDesktopStatus = CodexDesktopStatus(
                environment: current.environment,
                state: state,
                error: codexDesktopError
            )
        }
    }

    private func preservingRuntimeSnapshotIfNeeded(in current: AgentStatus) -> AgentStatus {
        guard current.runtimeStatus == nil,
              current.serviceOK,
              let previousStatus = status,
              previousStatus.endpoint == current.endpoint,
              previousStatus.serverVersion == current.serverVersion,
              let previousSnapshot = previousStatus.runtimeStatus
        else {
            return current
        }
        // status CLI 会并行读取 readyz 与 runtime endpoint。后者偶发超时时，
        // 核心服务状态仍然有效；保留并显式标旧上次快照，避免运行时整块闪空。
        let staleSnapshot = AgentRuntimeStatusSnapshot(
            checkedAt: previousSnapshot.checkedAt,
            runtimes: previousSnapshot.runtimes,
            refreshing: previousSnapshot.refreshing,
            stale: true
        )
        return AgentStatus(
            processOK: current.processOK,
            serviceOK: current.serviceOK,
            processError: current.processError,
            serviceError: current.serviceError,
            version: current.version,
            serverVersion: current.serverVersion,
            endpoint: current.endpoint,
            configPath: current.configPath,
            projects: current.projects,
            doctorOK: current.doctorOK,
            doctor: current.doctor,
            pairExpires: current.pairExpires,
            runtimeStatus: staleSnapshot
        )
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

    private func scheduleRuntimeStatusFollowUp() {
        guard runtimeStatusFollowUpTask == nil else { return }
        runtimeStatusFollowUpTask = Task { [weak self] in
            guard let self else { return }
            defer { runtimeStatusFollowUpTask = nil }
            // Provider 冷启动可能涉及 bridge 启动、OAuth 刷新和网络查询。
            // 菜单先展示缓存/refreshing，再在后台有界轮询，不能重新阻塞 readiness。
            // 首次 unavailable/额度刷新还会在服务端 15 秒失败 TTL 后重试一次；
            // 16 轮足够覆盖两次 9 秒 provider 预算，同时避免永久轮询。
            var didRetryUnavailable = false
            for _ in 0..<16 {
                let delay: Duration
                if isRefreshingStatus {
                    delay = .seconds(2)
                } else if let nextDelay = Self.runtimeStatusFollowUpDelay(
                    snapshot: status?.runtimeStatus,
                    didRetryUnavailable: didRetryUnavailable
                ) {
                    delay = nextDelay
                } else {
                    return
                }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, owner == .macApp, !isBusy else { return }
                guard !isRefreshingStatus else { continue }

                guard Self.runtimeStatusFollowUpDelay(
                    snapshot: status?.runtimeStatus,
                    didRetryUnavailable: didRetryUnavailable
                ) != nil else {
                    return
                }
                if status?.runtimeStatus?.refreshing != true,
                   status?.runtimeStatus?.hasRetryableFailure == true
                {
                    didRetryUnavailable = true
                }
                isRefreshingStatus = true
                await refreshMacAgentStatus()
                isRefreshingStatus = false
            }
        }
    }

    private var runtimeStatusNeedsFollowUp: Bool {
        status?.runtimeStatus?.refreshing == true
            || status?.runtimeStatus?.hasRetryableFailure == true
    }

    nonisolated static func runtimeStatusFollowUpDelay(
        snapshot: AgentRuntimeStatusSnapshot?,
        didRetryUnavailable: Bool
    ) -> Duration? {
        if snapshot?.refreshing == true {
            return .seconds(2)
        }
        if !didRetryUnavailable, snapshot?.hasRetryableFailure == true {
            return .seconds(15)
        }
        return nil
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        lifecycle = .failed(error.localizedDescription)
    }

    private func validateMacAgentConfiguration() throws {
        if let configurationError = services.agentConfigurationError() {
            throw ServiceLifecycleError.invalidConfiguration(configurationError)
        }
    }

#if DEBUG
    static func preview(_ lifecycle: HostLifecycleState) -> HostStore {
        let check = AgentCheck(name: "codex", ok: true, level: "", message: "Codex CLI 可执行", fix: nil)
        let doctor = AgentDoctorResults(ok: true, version: "0.1.0", listen: "mimi-demo.local:8787", checks: [check])
        let status = AgentStatus(
            processOK: true,
            serviceOK: true,
            processError: nil,
            serviceError: nil,
            version: "0.1.0+mac.240",
            serverVersion: "0.1.0+mac.240",
            endpoint: "http://mimi-demo.local:8787",
            configPath: "~/Library/Application Support/mimi-remote/config.json",
            projects: 12,
            doctorOK: true,
            doctor: doctor,
            pairExpires: nil,
            runtimeStatus: AgentRuntimeStatusSnapshot(
                checkedAt: ISO8601DateFormatter().string(from: Date()),
                runtimes: [
                    AgentRuntimeStatus(
                        id: "codex",
                        title: "Codex",
                        enabled: true,
                        state: .connected,
                        version: "0.146.0-alpha.3.1",
                        startedAt: ISO8601DateFormatter().string(
                            from: Date().addingTimeInterval(-49 * 60 * 60)
                        ),
                        authMode: "chatgpt",
                        planType: "plus",
                        reason: nil,
                        rateLimits: AgentRuntimeRateLimits(
                            limitID: "codex",
                            limitName: "Codex",
                            planType: "plus",
                            reachedType: nil,
                            availability: "available",
                            unavailableReason: nil,
                            primary: AgentRuntimeRateLimitWindow(
                                usedPercent: 62,
                                windowDurationMins: 300,
                                resetsAt: Int64(Date().addingTimeInterval(80 * 60).timeIntervalSince1970)
                            ),
                            secondary: AgentRuntimeRateLimitWindow(
                                usedPercent: 31,
                                windowDurationMins: 10_080,
                                resetsAt: Int64(Date().addingTimeInterval(4 * 24 * 60 * 60).timeIntervalSince1970)
                            ),
                            hasCredits: true,
                            creditsUnlimited: false,
                            creditBalance: "12.34"
                        )
                    ),
                    AgentRuntimeStatus(
                        id: "claude",
                        title: "Claude",
                        enabled: true,
                        state: .connected,
                        version: "0.2.6",
                        startedAt: ISO8601DateFormatter().string(
                            from: Date().addingTimeInterval(-7.5 * 60 * 60)
                        ),
                        authMode: "oauth",
                        planType: "pro",
                        reason: nil,
                        rateLimits: AgentRuntimeRateLimits(
                            limitID: "claude",
                            limitName: "Claude",
                            planType: "pro",
                            reachedType: nil,
                            availability: "available",
                            unavailableReason: nil,
                            primary: AgentRuntimeRateLimitWindow(
                                usedPercent: 24,
                                windowDurationMins: 300,
                                resetsAt: Int64(Date().addingTimeInterval(3 * 60 * 60).timeIntervalSince1970)
                            ),
                            secondary: AgentRuntimeRateLimitWindow(
                                usedPercent: 48,
                                windowDurationMins: 10_080,
                                resetsAt: Int64(Date().addingTimeInterval(5 * 24 * 60 * 60).timeIntervalSince1970)
                            ),
                            hasCredits: nil,
                            creditsUnlimited: nil,
                            creditBalance: nil
                        )
                    ),
                ]
            )
        )
        let agent = AgentCommandClient(
            configExists: { lifecycle != .notConfigured },
            setup: { _ in PairingInfo(endpoint: status.endpoint, pairURL: "mimiremote://pair?pair_sig=preview", expiresAt: "10 分钟后", warnings: []) },
            status: { status },
            statusAt: { _ in status },
            doctor: { _ in DoctorFixResults(fixes: [], results: doctor) },
            configureClaude: { preference, restoreEnabled in
                let enabled = restoreEnabled ?? (preference != .disabled)
                return ClaudeConfigurationResult(
                    enabled: enabled,
                    available: enabled,
                    preference: preference,
                    previousEnabled: true,
                    previousPreference: .enabled,
                    changed: false,
                    restartRequired: false,
                    reason: enabled ? "ready" : "disabled_by_user",
                    message: enabled
                        ? "已检测到 Claude Code 和兼容的 Claude bridge。"
                        : "Claude 实验通道已关闭。"
                )
            },
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
            agentStatus: { .enabled },
            agentConfigurationError: { nil },
            isAgentRegistrationCurrent: { true },
            markAgentRegistrationCurrent: {},
            registerAgent: {},
            unregisterAgent: {},
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
    case invalidConfiguration(String)
    case unregisterTimedOut
    case stopTimedOut
    case requiresApproval
    case agentRegistrationFailed(String)
    case automaticRepairFailed(initial: String, recovery: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            detail
        case .unregisterTimedOut:
            "服务停止超时，未继续启动；请稍后重试。"
        case .stopTimedOut:
            "旧服务仍占用当前 Endpoint，未继续启动新版本；请稍后重试。"
        case .requiresApproval:
            "请先在系统设置的登录项中允许 Mimi Remote Mac。"
        case .agentRegistrationFailed(let detail):
            "系统没有找到原服务记录，自动重新登记失败：\(detail)。请运行诊断并重试。"
        case .automaticRepairFailed(let initial, let recovery):
            "服务首次启动失败（\(initial)），自动重新登记仍未恢复（\(recovery)）。请运行诊断。"
        }
    }
}

private enum ClaudeRuntimeControlError: LocalizedError {
    case signedOut
    case unavailable
    case disabled
    case timedOut(enabled: Bool)

    var errorDescription: String? {
        switch self {
        case .signedOut:
            "Claude Code 尚未登录。"
        case .unavailable:
            "Claude Runtime 未能连接。"
        case .disabled:
            "服务重载后 Claude 仍处于关闭状态。"
        case .timedOut(let enabled):
            enabled ? "等待 Claude Runtime 连接超时。" : "等待 Claude Runtime 停止超时。"
        }
    }
}
