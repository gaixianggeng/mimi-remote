import AppKit
import Foundation
import Observation

enum MacSettingsSection: String, Equatable, Hashable, Sendable {
    case assistants
    case connections
    case fileAccess
}

enum DiagnosticsFocus: Equatable, Hashable, Sendable {
    case overview
    case hostRecovery
}

@MainActor
@Observable
final class HostStore {
    var lifecycle: HostLifecycleState = .loading
    var owner: ServiceOwner = .none
    var status: AgentStatus?
    var doctor: AgentDoctorResults?
    var pairing: PairingInfo?
    var pairingNetwork: PairingNetwork = .tailscale
    private(set) var recentLogs: [String] = []
    private(set) var diagnosticsStatus: AgentDiagnosticsStatus?
    private(set) var diagnosticsStatusError: String?
    private(set) var diagnosticsLogError: String?
    private(set) var isLoadingDiagnostics = false
    private(set) var isUpdatingDiagnostics = false
    private(set) var isExportingDiagnostics = false
    private(set) var appliedFixes: [String] = []
    private var isPerformingAction = false
    var isBusy: Bool {
        get { isPerformingAction || codexRuntimeUpdate.isUpdating }
        set { isPerformingAction = newValue }
    }
    let codexRuntimeUpdate: CodexRuntimeUpdateStore
    private(set) var isStoppingForQuit = false
    private(set) var isRefreshingStatus = false
    private(set) var homebrewLoaded = false
    private(set) var launchesAtLogin = false
    var claudeConfiguration: ClaudeConfigurationResult?
    var claudeTurnHintsConfiguration: ClaudeTurnHintsConfigurationResult?
    var isUpdatingClaude = false
    var claudeError: String?
    var agyConfiguration: AgyConfigurationResult?
    var isUpdatingAgy = false
    var agyError: String?
    var deepSeekConfiguration: DeepSeekConfigurationResult?
    var isUpdatingDeepSeek = false
    var deepSeekError: String?
    var tailcatStatus: TailcatStatus?
    var isUpdatingTailcat = false
    var tailcatError: String?
    var tailcatNotice: String?
    var isUpdatingLAN = false
    var lanError: String?
    var codexError: String?
    private(set) var codexSessionRepairNotice: String?
    var networkError: String?
    var networkErrorModule: HostModuleID?
    var updatingModule: HostModuleID?
    private(set) var photosAccess: PhotosAccessState = .notDetermined
    /// 启动阶段的补充说明，例如覆盖安装后正在重新登记后台服务。只在
    /// `.starting` 期间有值，进入其它生命周期状态时清空。
    private(set) var startingDetail: String?
    /// 非阻断的主应用登录项提示；与阻断性错误 `lastError` 拆分，避免挡住配对出码。
    var loginItemWarning: String?
    var lastError: String?
    /// 向导未完成期间保持为 true，防止 setup/启动失败提前切出向导把用户困在概览页。
    private(set) var isOnboardingInProgress = false
    /// 跨窗口受控路由落点：`open_settings(assistants)`、`open_settings(managed_connection)`、
    /// `open_settings(host_recovery)` 及菜单栏通道快捷入口。
    var requestedSettingsSection: MacSettingsSection?
    var requestedDiagnosticsFocus: DiagnosticsFocus?
    var preferredPairingTransport: OnboardingTransport?
    /// 仅在正明确验证宿主支持 BE-3+ 保身份 `doctor --fix` 时才为 `"identity_preserving_doctor_fix"`。
    var verifiedOnboardingCapability: String? { agent.verifiedOnboardingCapability() }
    @ObservationIgnored var pairingRefreshGeneration = 0
    @ObservationIgnored var tailcatStatusRequestSequence: UInt64 = 0
    /// 启动等待期间的 status 轮询只用来判断是否就绪。未就绪的结果不能把生命周期
    /// 写成 degraded/stopped，否则菜单栏会在"正在启动"阶段先闪出"服务需要处理"，
    /// 让用户误以为启动已经失败。真正的失败由等待结束后的 fail() 给出。
    @ObservationIgnored var isAwaitingServiceStart = false

    var canRestoreHomebrew: Bool {
        owner == .macApp && homebrew.installedAgentBinary() != nil
    }

    var claudeEnabled: Bool {
        status?.moduleStatus?.claudeEnabled ?? claudeConfiguration?.enabled ?? claudeRuntime?.enabled ?? false
    }

    var agyEnabled: Bool {
        status?.moduleStatus?.agyEnabled ?? agyConfiguration?.enabled ?? runtime(for: .agy)?.enabled ?? false
    }

    var lanEnabled: Bool {
        if let modules = status?.moduleStatus { return modules.lanEnabled }
        guard status?.moduleStatusState != .unavailable else { return false }
        return status?.networkStatus?.allowLAN ?? false
    }

    private var claudeRuntime: AgentRuntimeStatus? {
        status?.runtimeStatus?.runtimes.first { $0.id.caseInsensitiveCompare("claude") == .orderedSame }
    }

    private var codexRuntime: AgentRuntimeStatus? {
        status?.runtimeStatus?.runtimes.first { $0.id.caseInsensitiveCompare("codex") == .orderedSame }
    }

    let agent: AgentCommandClient
    private let services: ServiceManagementClient
    private let configCheck: AgentdConfigCheckClient
    private let homebrew: HomebrewServiceClient
    private let health: HealthClient
    private let logs: AgentLogClient
    private let systemPrivacySettings: SystemPrivacySettingsClient
    private let terminateApplication: @MainActor () -> Void
    private var didBootstrap = false
    private var monitorTask: Task<Void, Never>?
    private var runtimeStatusFollowUpTask: Task<Void, Never>?
    private var stopServiceAndQuitTask: Task<Void, Never>?
    private var lastStatusRefreshAt: Date?
    private var lastReadinessCommandSuccessAt: Date?
    private var readinessFailureStartedAt: Date?
    // 每次开始 agent.status() 都先分配单调序号，只允许最新请求落地。
    var statusRequestSequence: UInt64 = 0

    init(
        agent: AgentCommandClient,
        services: ServiceManagementClient,
        configCheck: AgentdConfigCheckClient = .disabled,
        homebrew: HomebrewServiceClient,
        health: HealthClient,
        logs: AgentLogClient,
        systemPrivacySettings: SystemPrivacySettingsClient = .noop,
        terminateApplication: @escaping @MainActor () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        self.agent = agent
        self.codexRuntimeUpdate = CodexRuntimeUpdateStore(agent: agent)
        self.services = services
        self.configCheck = configCheck
        self.homebrew = homebrew
        self.health = health
        self.logs = logs
        self.systemPrivacySettings = systemPrivacySettings
        self.terminateApplication = terminateApplication
    }

    static func live() -> HostStore {
        HostStore(
            agent: .live(),
            services: .live(),
            configCheck: .live(),
            homebrew: .live(),
            health: .live,
            logs: .live,
            systemPrivacySettings: .live
        )
    }

    /// 同步判断是否已完成首次设置；App 启动时据此决定是否直接弹出设置窗口（#554）。
    func hasConfiguration() -> Bool { agent.configExists() }

    var agentRegistrationState: ServiceRegistrationState { services.agentStatus() }
    var mainAppRegistrationState: ServiceRegistrationState { services.mainAppStatus() }
    var currentPhotosAccessState: PhotosAccessState { systemPrivacySettings.photosAccessState() }

    func openFilesAndFoldersSettings() {
        systemPrivacySettings.openFilesAndFoldersSettings()
    }

    func openLocalNetworkSettings() {
        systemPrivacySettings.openLocalNetworkSettings()
    }

    func openPhotosPrivacySettings() {
        systemPrivacySettings.openPhotosPrivacySettings()
    }

    func openDateTimeSettings() {
        systemPrivacySettings.openDateTimeSettings()
    }

    @ObservationIgnored private var wizard: OnboardingStore?

    func onboardingWizard() -> OnboardingStore {
        if let wizard { return wizard }
        let wizard = OnboardingStore(dependencies: .live(hostStore: self))
        self.wizard = wizard
        return wizard
    }

    func beginOnboarding() {
        isOnboardingInProgress = true
        lifecycle = .notConfigured
        pairingRefreshGeneration &+= 1
        pairing = nil
    }

    func finishOnboarding(owner resolvedOwner: ServiceOwner) async {
        isOnboardingInProgress = false
        wizard = nil
        lastError = nil
        switch resolvedOwner {
        case .homebrew:
            homebrewLoaded = true
            owner = .homebrew
            lifecycle = .migrationRequired
            await refreshHomebrewStatus()
        case .macApp:
            owner = .macApp
            if status?.serviceOK == true {
                lifecycle = .ready
            } else if services.agentStatus() == .requiresApproval {
                lifecycle = .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。")
            } else {
                await refreshMacAgentStatus()
            }
        case .none:
            owner = .none
            if agent.configExists() {
                await refresh()
            } else {
                lifecycle = .notConfigured
            }
        }
    }

    enum OnboardingServiceStartOutcome: Equatable, Sendable {
        case ready
        case requiresApproval
        case homebrewHealthy
    }

    func registerOrStartServiceForOnboarding(onRegistered: @MainActor () -> Void = {}) async throws -> OnboardingServiceStartOutcome {
        let brewLoaded = await homebrew.isLoaded()
        try Task.checkCancellation()
        if brewLoaded || owner == .homebrew {
            owner = .homebrew
            guard let binary = homebrew.installedAgentBinary() else { throw HomebrewServiceError.brewMissing }
            if !brewLoaded {
                try await homebrew.start()
                homebrewLoaded = true
                onRegistered()
                try await waitForHomebrewReady(binary: binary)
                return .homebrewHealthy
            }
            homebrewLoaded = true
            onRegistered()
            let current = try await agent.statusAt(binary)
            guard current.serviceOK else {
                throw AgentClientError.commandFailed("Homebrew 后台服务尚未就绪。")
            }
            status = current
            doctor = current.doctor
            return .homebrewHealthy
        }
        try validateMacAgentConfiguration()
        await enableLoginLaunchBestEffort()
        switch services.agentStatus() {
        case .requiresApproval:
            owner = .none
            return .requiresApproval
        case .enabled:
            owner = .macApp
            if services.isAgentRegistrationCurrent(),
               let current = try? await fetchAndApplyLatestStatus(),
               current.serviceOK,
               !current.hasAgentVersionMismatch {
                return .ready
            }
            do {
                try Task.checkCancellation()
                try await unregisterMacAgentAndWait(endpoint: status?.endpoint)
                try await registerMacAgentAndWaitForReady(onRegistered: onRegistered)
                return .ready
            } catch {
                if services.agentStatus() == .requiresApproval {
                    owner = .none
                    return .requiresApproval
                }
                throw error
            }
        case .notRegistered, .notFound:
            owner = .macApp
            do {
                try await registerMacAgentAndWaitForReady(onRegistered: onRegistered)
                return .ready
            } catch {
                if services.agentStatus() == .requiresApproval {
                    owner = .none
                    return .requiresApproval
                }
                owner = .none
                throw error
            }
        }
    }

    func restartServiceForOnboarding() async throws {
        let brewLoaded = await homebrew.isLoaded()
        if brewLoaded || owner == .homebrew {
            owner = .homebrew
            guard let binary = homebrew.installedAgentBinary() else { throw HomebrewServiceError.brewMissing }
            if brewLoaded {
                try await homebrew.stop()
                homebrewLoaded = false
            }
            try await homebrew.start()
            homebrewLoaded = true
            try await waitForHomebrewReady(binary: binary)
        } else {
            try await reloadMacAgentForConfigurationChange()
        }
    }

    func takeOverHomebrewForOnboarding() async throws {
        guard let oldAgent = homebrew.installedAgentBinary() else {
            throw HomebrewServiceError.commandFailed("找不到 Homebrew 安装的 agentd，无法安全接管。")
        }
        try validateMacAgentConfiguration()
        do {
            try await homebrew.stop()
            homebrewLoaded = false
            owner = .macApp
            try await registerMacAgentAndWaitForReady()
        } catch {
            try? await services.unregisterAgent()
            if (try? await homebrew.start()) != nil {
                try? await waitForHomebrewReady(binary: oldAgent)
                homebrewLoaded = true
                owner = .homebrew
            } else {
                owner = .none
            }
            throw error
        }
    }

    func enableAssistantForOnboarding(_ runtimeID: String) async throws {
        let needsReload: Bool
        switch runtimeID.lowercased() {
        case "codex":
            let result = try await agent.configureCodex("enabled")
            needsReload = result.restartRequired
        case "claude":
            let result = try await agent.configureClaude(.enabled, nil)
            claudeConfiguration = result
            needsReload = result.restartRequired
        case "agy":
            let result = try await agent.configureAgy(.enabled, nil)
            agyConfiguration = result
            needsReload = result.restartRequired
        default:
            return
        }
        if needsReload {
            try await restartServiceForOnboarding()
        }
    }

    func enableTransportForOnboarding(_ transport: OnboardingTransport) async throws {
        switch transport {
        case .tailscale:
            let result = try await agent.configureNetwork(.tailscale, true)
            if result.restartRequired {
                try await restartServiceForOnboarding()
            }
        case .lan:
            let result = try await agent.configureNetwork(.localNetwork, true)
            if result.restartRequired {
                try await restartServiceForOnboarding()
            }
        case .tailcat:
            tailcatStatus = try await agent.setTailcatEnabled(true)
            if tailcatStatus?.restartRequired == true {
                try await restartServiceForOnboarding()
            }
        }
    }

    func connectDeepSeekForOnboarding(startupURL: String?) async throws {
        let result = try await agent.configureDeepSeek(.connect, startupURL)
        deepSeekConfiguration = result
        if result.restartRequired {
            try await restartServiceForOnboarding()
        }
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
            let reloadDeepSeekConfiguration = await reconcileDeepSeekConfigurationAtLaunch()
            await startMacAgentIfNeeded(reloadConfiguration: reloadClaudeConfiguration || reloadDeepSeekConfiguration)
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
            lifecycle = .notConfigured
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try validateMacAgentConfiguration()
            let nextPairing = try await agent.setup(workspaceRoot)
            if nextPairing.hasTicket {
                pairing = nextPairing
                pairingNetwork = nextPairing.network
            } else {
                pairing = nil
            }
            _ = await reconcileClaudeConfigurationAtLaunch()
            await enableLoginLaunchBestEffort()
            owner = .macApp
            lifecycle = .starting
            try await registerMacAgentAndWaitForReady()
        } catch {
            // 向导未完成前保持 .notConfigured，绝不切入 .failed 把用户困在概览页。
            owner = .none
            lifecycle = .notConfigured
            startingDetail = nil
            lastError = error.localizedDescription
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
            // 永久交还 Homebrew 前，先确认私有 Codex backend 空闲并注销独立前门。
            // 失败时走现有回滚，不能留下仍指向将被移走 App 的 LaunchAgent。
            try await agent.uninstallCodexFrontDoor()
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
        guard !isBusy, !isRefreshingStatus, !isOnboardingInProgress else { return }
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
        guard canPair else {
            pairing = nil
            lastError = pairingUnavailableReason(for: network ?? .automatic)
            return
        }
        pairingRefreshGeneration &+= 1
        let refreshGeneration = pairingRefreshGeneration
        lastError = nil
        pairing = nil
        do {
            let nextPairing = try await resolvedPairing(for: network)
            // 较早的请求不能覆盖用户刚选择的网络和二维码。
            guard refreshGeneration == pairingRefreshGeneration else { return }
            pairing = nextPairing
            pairingNetwork = nextPairing.network
            lastError = nil
        } catch {
            guard refreshGeneration == pairingRefreshGeneration else { return }
            lastError = error.localizedDescription
        }
    }

    private func prepareAutomaticNetworkBeforeServiceStart() async throws {
        // 启动服务不得因为 Tailscale/配对探测失败而静默扩大到局域网监听。
        // 网络能力由用户显式开关；失败保留原配置并交给状态/配对界面处理。
        // 服务启动不依赖是否有可用的外部配对地址。
    }

    private func resolvedPairing(for requestedNetwork: PairingNetwork?) async throws -> PairingInfo {
        var selection = requestedNetwork ?? .automatic
        if status?.moduleStatus != nil || status?.moduleStatusState == .unavailable {
            if selection == .automatic { selection = availablePairingNetworks.first ?? .automatic }
            guard canPair, availablePairingNetworks.contains(selection) else {
                throw AgentClientError.commandFailed(pairingUnavailableReason(for: selection))
            }
        }
        switch selection {
        case .automatic:
            // 自动模式只在当前已启用的连接方式中选择；不能为了生成二维码
            // 隐式打开 LAN，因为那会扩大 agentd 的网络暴露面。
            return try await agent.pair(.automatic)
        case .tailscale:
            return try await agent.pair(.tailscale)
        case .localNetwork:
            return try await localNetworkPairing()
        case .tailcat:
            return try await agent.pair(.tailcat)
        }
    }

    private func localNetworkPairing() async throws -> PairingInfo {
        guard lanEnabled else {
            throw AgentClientError.commandFailed("局域网已关闭，请先在连接方式中明确启用。")
        }
        return try await issueVerifiedPairing(for: .localNetwork)
    }

    func issueVerifiedPairing(for network: PairingNetwork) async throws -> PairingInfo {
        let nextPairing = try await agent.pair(network)
        if network == .localNetwork, !(await health.checkDirect(nextPairing.endpoint)) {
            throw AgentClientError.commandFailed("局域网地址不可访问，请检查本地网络权限、防火墙或重新启动 Mimi 服务。")
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
            // Doctor 改写配置后，resident agentd 仍持有旧快照；重新登记一次
            // 让服务加载新配置。这个动作不会退出或重新打开 Codex Desktop。
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

    func refreshDiagnostics() async {
        guard !isLoadingDiagnostics, !isUpdatingDiagnostics else { return }
        isLoadingDiagnostics = true
        diagnosticsStatusError = nil
        diagnosticsLogError = nil
        defer { isLoadingDiagnostics = false }

        async let statusCall = agent.diagnosticsStatus()
        async let logsCall = logs.recentLines(200)
        do {
            diagnosticsStatus = try await statusCall
        } catch is CancellationError {
            return
        } catch {
            // 服务状态无法读取时不展示过期快照，避免让用户误以为开关仍然有效。
            diagnosticsStatus = nil
            diagnosticsStatusError = error.localizedDescription
        }
        do {
            recentLogs = try await logsCall
        } catch is CancellationError {
            return
        } catch {
            diagnosticsLogError = error.localizedDescription
        }
    }

    func setDetailedDiagnostics(_ enabled: Bool) async {
        guard !isLoadingDiagnostics, !isUpdatingDiagnostics else { return }
        isUpdatingDiagnostics = true
        diagnosticsStatusError = nil
        defer { isUpdatingDiagnostics = false }
        do {
            diagnosticsStatus = try await agent.setDetailedDiagnostics(enabled)
        } catch is CancellationError {
            return
        } catch {
            diagnosticsStatusError = error.localizedDescription
        }
    }

    func clearDiagnostics() async {
        guard !isLoadingDiagnostics, !isUpdatingDiagnostics else { return }
        isUpdatingDiagnostics = true
        diagnosticsStatusError = nil
        diagnosticsLogError = nil
        defer { isUpdatingDiagnostics = false }
        do {
            diagnosticsStatus = try await agent.clearDiagnostics()
            recentLogs = []
        } catch is CancellationError {
            return
        } catch {
            diagnosticsLogError = error.localizedDescription
        }
    }

    func diagnosticExportLines() async -> [String]? {
        guard !isExportingDiagnostics else { return nil }
        isExportingDiagnostics = true
        diagnosticsLogError = nil
        defer { isExportingDiagnostics = false }
        do {
            return try await logs.exportLines()
        } catch is CancellationError {
            return nil
        } catch {
            diagnosticsLogError = error.localizedDescription
            return nil
        }
    }

    func openLoginItemsSettings() {
        services.openLoginItemsSettings()
    }

    func openFullDiskAccessSettings() {
        systemPrivacySettings.openFullDiskAccessSettings()
    }

    func refreshPhotosAccess() {
        photosAccess = systemPrivacySettings.photosAccessState()
    }

    /// 从系统设置返回时只做被动原生权限刷新，绝不触发服务启动。
    func refreshPermissionsOnReturn() {
        photosAccess = systemPrivacySettings.photosAccessState()
        launchesAtLogin = services.mainAppStatus() == .enabled
        if launchesAtLogin {
            loginItemWarning = nil
        }
    }

    /// 供已验证 BE-3+ 宿主的 `config_permissions_unsafe` 路径调用的保身份修复。
    func runSafeDoctorFixAndReload() async throws -> [String] {
        guard verifiedOnboardingCapability == OnboardingSchema.doctorFixCapability else {
            throw AgentClientError.commandFailed("请更新桌面端后重新检查配置权限。")
        }
        let result = try await agent.doctor(true)
        doctor = result.results
        appliedFixes = result.fixes
        if result.restartRequired == true {
            try await restartServiceForOnboarding()
        }
        return result.fixes
    }

    /// 首次请求弹出系统授权框；用户之前拒绝过时系统不会再弹，只能引导到隐私设置里手动开启。
    /// Homebrew 运行的 agentd 不继承 App 的照片授权，只能打开完全磁盘访问设置。
    func requestPhotosAccess() async {
        guard owner != .homebrew else {
            systemPrivacySettings.openFullDiskAccessSettings()
            return
        }
        let current = systemPrivacySettings.photosAccessState()
        switch current {
        case .notDetermined:
            photosAccess = await systemPrivacySettings.requestPhotosAccess()
        case .denied, .restricted:
            photosAccess = current
            systemPrivacySettings.openPhotosPrivacySettings()
        case .authorized, .limited:
            photosAccess = current
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
            loginItemWarning = launchesAtLogin ? nil : (enabled ? "服务可继续使用，但主应用登录时启动需要在“登录项”中允许。" : nil)
        } catch {
            loginItemWarning = "服务可继续使用，但登录启动设置未生效：\(error.localizedDescription)"
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
            try validateMacAgentConfiguration()
            try await unregisterMacAgentAndWait(endpoint: status?.endpoint)
            try await registerMacAgentAndWaitForReady()
        } catch {
            fail(error)
        }
    }

    /// 用户确认所有共享连接都已退出后，显式释放错误驻留在 Background
    /// session 的 Codex server，再由 Aqua LaunchAgent 创建新的 resident。
    func repairSharedCodexRuntime() async {
        guard !isBusy else { return }
        let originalServiceStatus = services.agentStatus()
        guard owner == .macApp, originalServiceStatus == .enabled else {
            lastError = "当前不是 App 托管服务，不能修复共享运行环境。"
            return
        }

        isBusy = true
        lifecycle = .starting
        lastError = nil
        codexSessionRepairNotice = nil
        defer { isBusy = false }

        do {
            try validateMacAgentConfiguration()
            try await unregisterMacAgentAndWait(endpoint: status?.endpoint)
            let result = try await agent.releaseCodexSession()
            try await registerMacAgentAndWaitForReady()
            let releaseMessage = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = releaseMessage.isEmpty
                ? (result.released
                    ? "共享运行环境已修复。"
                    : "共享运行环境无需释放。")
                : releaseMessage
            let separator = summary.hasSuffix("。") || summary.hasSuffix("！") || summary.hasSuffix("？")
                ? ""
                : "。"
            codexSessionRepairNotice = "\(summary)\(separator)Mimi Remote Mac 服务已重新启动。"
        } catch {
            await restoreMacAgentAfterCodexSessionRepairFailure(
                originalServiceStatus: originalServiceStatus,
                cause: error
            )
        }
    }

    private func restoreMacAgentAfterCodexSessionRepairFailure(
        originalServiceStatus: ServiceRegistrationState,
        cause: Error
    ) async {
        guard originalServiceStatus == .enabled else {
            fail(cause)
            return
        }
        do {
            owner = .macApp
            try await registerMacAgentAndWaitForReady()
            lastError = "修复共享运行环境失败，已恢复 Mimi Remote Mac 服务：\(cause.localizedDescription)"
        } catch {
            // launchd 已重新登记但 resident 因旧 Background server 拒绝而未就绪时，
            // 仍保留 App owner，让用户关闭其它连接后可以再次执行显式修复。
            owner = services.agentStatus() == .enabled ? .macApp : .none
            lifecycle = .failed("修复共享运行环境失败，Mimi Remote Mac 服务未能恢复就绪：\(error.localizedDescription)")
            lastError = "原始错误：\(cause.localizedDescription)；恢复错误：\(error.localizedDescription)"
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
                //
                // 这里必须保留一次自动换代：LaunchAgent 定义本身变化时（例如 BundleProgram 从裸
                // agentd 改为主 App supervisor），第一次登记会被 BTM 复用到带旧 Launch Constraint
                // 的记录上，launchd 立即报 Constraint Violation。BTM 随后生成新记录，但 launchd
                // 已提交的任务仍指向作废记录，只有再注销、再登记一次才会换到新记录。
                lifecycle = .starting
                do {
                    try await unregisterMacAgentAndWait(endpoint: status?.endpoint)
                    try await registerMacAgentAndWaitForReady(allowAutomaticRepair: true)
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
        // 同上：配置本身不可用时，换代不会改变结果，也不该把原因改写成登记问题。
        if let lifecycleError = initialError as? ServiceLifecycleError, lifecycleError.isConfigurationFailure {
            fail(lifecycleError)
            return
        }
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

    func reloadMacAgentForConfigurationChange(fastRestart: Bool = false) async throws {
        try validateMacAgentConfiguration()
        if !isOnboardingInProgress {
            lifecycle = .starting
        }
        let endpoint: String?
        if let currentEndpoint = status?.endpoint {
            endpoint = currentEndpoint
        } else {
            endpoint = (try? await agent.status())?.endpoint
        }
        switch services.agentStatus() {
        case .enabled:
            if fastRestart && services.isAgentRegistrationCurrent() {
                do {
                    try await services.restartAgent()
                    try await waitForMacAgentReady()
                    return
                } catch { /* 快速重启失败才回退完整登记换代。 */ }
            }
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

    private func waitForMacAgentReady() async throws {
        isAwaitingServiceStart = true
        defer { isAwaitingServiceStart = false }
        var lastStatus: AgentStatus?
        for _ in 0..<15 {
            try Task.checkCancellation()
            if let current = try? await fetchAndApplyLatestStatus() {
                lastStatus = current
                if current.serviceOK { return }
            }
            // 覆盖安装后 BTM 可能沿用旧 App 的 Launch Constraint，launchd 会每 3 秒
            // 重试却始终拉不起进程。等满整轮再修复会白白浪费近一分钟；一旦 launchd
            // 自己已经报告反复 spawn 失败，就立即交给上层做一次有界换代。
            if let launchFailure = await services.agentLaunchFailure() {
                throw await macAgentLaunchFailureError(launchFailure)
            }
            try await Task.sleep(for: .seconds(1))
        }
        let detail = lastStatus?.serviceError ?? "服务在有限等待内没有通过就绪检查。"
        throw AgentClientError.commandFailed(detail)
    }

    /// launchd 只报得出「反复 spawn 失败 + 退出码」，真正的原因在 agentd 自己的启动
    /// 检查里：直接问包内 agentd，就能区分「这份配置需要更新版本的安装包」和「登记
    /// 记录过期」。配置类问题重新登记多少次都不会变，必须换成真实报错或升级引导。
    private func macAgentLaunchFailureError(_ launchFailure: String) async -> ServiceLifecycleError {
        guard let check = await configCheck.check(), !check.ok else {
            return .agentSpawnFailed(launchFailure)
        }
        if check.requiresNewerVersion {
            return .configRequiresNewerVersion(check.message ?? launchFailure)
        }
        // 其它配置问题：把 agentd 的原始报错显示出来，用户才能看到「已被移除，
        // 请执行 agentd setup --force」这类真正可执行的下一步。
        guard let message = check.message, !message.isEmpty else {
            return .agentSpawnFailed(launchFailure)
        }
        return .invalidConfiguration(message)
    }

    private func registerMacAgentAndWaitForReady(
        allowAutomaticRepair: Bool = true,
        onRegistered: @MainActor () -> Void = {}
    ) async throws {
        try Task.checkCancellation()
        try validateMacAgentConfiguration()
        do {
            try services.registerAgent()
            if services.agentStatus() == .requiresApproval { throw ServiceLifecycleError.requiresApproval }
            onRegistered()
            try await waitForMacAgentReady()
            // 只有新登记的进程真正通过就绪检查后才记账；失败时下次启动仍会重试迁移。
            services.markAgentRegistrationCurrent()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // 配置在当前安装包下不可用：注销再登记只会重复同一个失败，直接报真实原因。
            if let lifecycleError = error as? ServiceLifecycleError, lifecycleError.isConfigurationFailure {
                throw lifecycleError
            }
            guard allowAutomaticRepair, services.agentStatus() == .enabled else {
                throw error
            }

            let initialError = error
            // 换代期间仍属于启动阶段：保持 starting 并给出说明，
            // 避免菜单栏在自动修复时显示"服务已停止"。
            if !isOnboardingInProgress {
                lifecycle = .starting
            }
            startingDetail = "覆盖安装后正在重新登记后台服务…"
            defer { startingDetail = nil }
            do {
                // register 已落入 enabled 但进程未就绪时，完整换代一次以刷新 BTM
                // 的 Launch Constraint；递归调用关闭修复开关，保证最多只重试一次。
                try await unregisterMacAgentAndWait(endpoint: status?.endpoint)
                try await registerMacAgentAndWaitForReady(allowAutomaticRepair: false, onRegistered: onRegistered)
            } catch {
                throw ServiceLifecycleError.automaticRepairFailed(
                    initial: initialError.localizedDescription,
                    recovery: error.localizedDescription
                )
            }
        }
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

    func refreshMacAgentStatus(preserveStateOnCommandFailure: Bool = false, now: Date = Date()) async {
        switch services.agentStatus() {
        case .enabled:
            do {
                _ = try await fetchAndApplyLatestStatus()
            } catch is CancellationError {
                return
            } catch {
                if preserveStateOnCommandFailure {
                    applyReadinessStalenessIfNeeded(now: now)
                } else {
                    fail(error)
                }
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
        let resolved = preservingTransientStatusSnapshotsIfNeeded(in: current)
        status = resolved
        doctor = resolved.doctor
        lastStatusRefreshAt = Date()
        lastReadinessCommandSuccessAt = Date()
        readinessFailureStartedAt = nil
        guard !isOnboardingInProgress else { return }
        if resolved.serviceOK {
            lifecycle = .ready
        } else if isAwaitingServiceStart {
            // 启动闭环还在等待就绪；保持"正在启动"，把 degraded/stopped 留给稳态监控。
            lifecycle = .starting
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

    @discardableResult
    private func applyStatusResponse(_ current: AgentStatus, sequence: UInt64) -> Bool {
        guard sequence == statusRequestSequence else { return false }
        apply(current)
        return true
    }

    func fetchAndApplyLatestStatus() async throws -> AgentStatus? {
        let sequence = nextStatusRequestSequence()
        let current = try await agent.status()
        return applyStatusResponse(current, sequence: sequence) ? current : nil
    }

    private func preservingModuleStatusIfNeeded(in current: AgentStatus) -> AgentStatus {
        guard current.moduleStatus == nil,
              current.moduleStatusState == .unavailable,
              current.serviceOK,
              let previousStatus = status,
              previousStatus.endpoint == current.endpoint,
              previousStatus.serverVersion == current.serverVersion,
              let previousModules = previousStatus.moduleStatus
        else {
            return current
        }
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
            runtimeStatus: current.runtimeStatus,
            networkStatus: current.networkStatus,
            moduleStatus: previousModules,
            moduleStatusState: .unavailable,
            workspaceConfirmed: current.workspaceConfirmed
        )
    }

    private func preservingTransientStatusSnapshotsIfNeeded(in current: AgentStatus) -> AgentStatus {
        preservingRuntimeSnapshotIfNeeded(in: preservingModuleStatusIfNeeded(in: current))
    }

    private func preservingRuntimeSnapshotIfNeeded(in current: AgentStatus) -> AgentStatus {
        guard current.runtimeStatus == nil,
              current.serviceOK,
              let previousStatus = status,
              previousStatus.endpoint == current.endpoint,
              previousStatus.serverVersion == current.serverVersion,
              previousStatus.moduleStatus == current.moduleStatus,
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
            runtimeStatus: staleSnapshot,
            networkStatus: current.networkStatus,
            moduleStatus: current.moduleStatus,
            moduleStatusState: current.moduleStatusState,
            workspaceConfirmed: current.workspaceConfirmed
        )
    }

    private func firstBlockingIssue(in results: AgentDoctorResults) -> String {
        results.checks.first { !$0.ok && !$0.isWarning }?.message ?? "环境检查未通过。"
    }

    private func enableLoginLaunchBestEffort() async {
        guard services.mainAppStatus() != .enabled else {
            launchesAtLogin = true
            loginItemWarning = nil
            return
        }
        do {
            try services.registerMainApp()
            let current = services.mainAppStatus()
            launchesAtLogin = current == .enabled
            if current == .enabled {
                loginItemWarning = nil
            } else if current == .requiresApproval {
                loginItemWarning = "服务可继续使用，但主应用登录时启动需要在“登录项”中允许。"
            }
        } catch {
            launchesAtLogin = false
            loginItemWarning = "服务可继续使用，但登录启动未启用：\(error.localizedDescription)"
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
                await self.performMonitoringTick(tick, now: Date())
            }
        }
    }

    /// 常驻监控始终以 healthz 作为进程探针；readiness 和完整 runtime 状态按不同频率读取。
    /// 保持该入口为 internal，测试可以直接推进 tick，无需真实等待五分钟。
    func performMonitoringTick(_ tick: Int, now: Date) async {
        // 启动闭环或向导未完成期间不让常驻监控改写生命周期或自动拉起服务。
        guard !isAwaitingServiceStart, !isOnboardingInProgress else { return }
        guard owner != .none, let endpoint = status?.endpoint else { return }
        guard await health.check(endpoint) else {
            await refresh()
            return
        }
        if owner == .homebrew {
            if tick.isMultiple(of: 30) {
                await refresh()
            }
            return
        }
        if tick.isMultiple(of: 30) {
            // 完整 status 已包含 readyz，本轮不再重复执行轻量 readiness。
            await refreshMacAgentStatus(preserveStateOnCommandFailure: true, now: now)
            // healthz 已在本轮确认进程存活；status 中的 process_ok 即使瞬时为 false，
            // 也不能把一个明确的 readiness 故障误报为进程停止。
            if let current = status, !current.serviceOK {
                lifecycle = .degraded(current.serviceError ?? "Codex 服务尚未就绪。")
            }
        } else if tick.isMultiple(of: 6) {
            await refreshReadinessStatus(now: now)
        } else {
            applyReadinessStalenessIfNeeded(now: now)
        }
    }

    private func refreshReadinessStatus(now: Date) async {
        // 轻量 readiness 与完整 status 写入同一份状态。二者必须共享请求序号，
        // 否则先发出的慢 readiness 会在较新的完整状态之后回写旧结果。
        let sequence = nextStatusRequestSequence()
        do {
            let current = try await agent.readiness()
            guard sequence == statusRequestSequence else { return }
            lastReadinessCommandSuccessAt = now
            readinessFailureStartedAt = nil
            let resolved = preservingTransientStatusSnapshotsIfNeeded(in: current)
            status = resolved
            doctor = resolved.doctor
            lastStatusRefreshAt = now
            lifecycle = current.serviceOK
                ? .ready
                : .degraded(current.serviceError ?? "Codex 服务尚未就绪。")
        } catch is CancellationError {
            return
        } catch {
            applyReadinessStalenessIfNeeded(now: now)
        }
    }

    func applyReadinessStalenessIfNeeded(now: Date) {
        if readinessFailureStartedAt == nil {
            readinessFailureStartedAt = now
        }
        guard let baseline = lastReadinessCommandSuccessAt ?? readinessFailureStartedAt,
              now.timeIntervalSince(baseline) >= 90 else { return }
        lifecycle = .degraded("进程存活，但 Codex 服务状态暂时无法确认")
    }

    func scheduleRuntimeStatusFollowUp() {
        guard runtimeStatusFollowUpTask == nil else { return }
        runtimeStatusFollowUpTask = Task { [weak self] in
            guard let self else { return }
            defer { runtimeStatusFollowUpTask = nil }
            // Provider 冷启动可能涉及 bridge 启动、OAuth 刷新和网络查询。
            // 菜单先展示缓存/refreshing，再在后台有界轮询，不能重新阻塞 readiness。
            // 首次 unavailable/额度刷新等 15 秒；凭据被拒等 30 秒轮换冷却后重试；
            // 16 轮足够覆盖两次 9 秒 provider 预算，同时避免永久轮询。
            var retryState = RuntimeStatusFollowUpState()
            for _ in 0..<16 {
                let delay: Duration
                if isRefreshingStatus {
                    delay = .seconds(2)
                } else if let nextDelay = retryState.delay(for: status?.runtimeStatus) {
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

                guard retryState.delay(for: status?.runtimeStatus) == delay else { continue }
                if status?.runtimeStatus?.refreshing != true,
                   status?.runtimeStatus?.hasRetryableFailure == true
                {
                    retryState.markRetry(for: status?.runtimeStatus)
                }
                isRefreshingStatus = true
                await refreshMacAgentStatus()
                isRefreshingStatus = false
            }
        }
    }

    var runtimeStatusNeedsFollowUp: Bool {
        status?.runtimeStatus?.refreshing == true
            || status?.runtimeStatus?.hasRetryableFailure == true
    }

    func fail(_ error: Error) {
        lastError = error.localizedDescription
        lifecycle = .failed(error.localizedDescription)
        startingDetail = nil
    }

    private func validateMacAgentConfiguration() throws {
        if let configurationError = services.agentConfigurationError() {
            throw ServiceLifecycleError.invalidConfiguration(configurationError)
        }
    }

}
