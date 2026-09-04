import Foundation

@MainActor
final class AppStore: ObservableObject {
    static let connectionProfileDisplayNameLimit = 48

    private enum AutomaticSettingsConnectionTestState {
        case pending
        case running
        case completed
    }

    @Published var endpoint: String
    @Published private(set) var connectionProfiles: [ConnectionProfile]
    @Published private(set) var activeConnectionProfileID: String?
    @Published private(set) var connectionGeneration = 0
    @Published private(set) var activeHostState: ActiveHostState
    @Published private(set) var isCredentialMemorySuspended = false
    @Published var token: String
    @Published var connectionStatus: ConnectionStatus = .idle
    @Published private(set) var connectionTermination: ConnectionTerminationStatus?
    @Published var lastError: String?
    @Published var lastConnectionTestDurationMillis: Int?
    @Published var lastConnectionTestReport: ConnectionTestReport?
    @Published var recentConnectionTestReports: [ConnectionTestReport] = []
    @Published private(set) var localAgentDetected = false
    @Published private(set) var activeConnectionRoute: ActiveConnectionRoute = .configured

    private let endpointKey = "agentd.endpoint"
    private static let profilesKey = "agentd.connectionProfiles.v2"
    private static let legacyProfilesKey = "agentd.connectionProfiles.v1"
    private static let activeProfileIDKey = "agentd.activeConnectionProfileID.v1"
    private let retiredFallbackEndpointKey = "agentd.fallbackEndpoint"
    private let retiredConnectionModeKey = "agentd.connectionMode"
    private let defaultEndpoint = "http://127.0.0.1:8787"
    private let localAgentEndpoint = "http://127.0.0.1:8787"
    private let maxConnectionTestReportHistory = 20
    private let defaults: UserDefaults
    private let tokenStore: TokenStore
    let credentialVault: HostCredentialVault
    private let routeProbeTimeout: TimeInterval
    private let prefersLocalConnection: Bool
    private let allowsEphemeralLocalCredentialFallback: Bool
    private let localAgentProbe: LocalAgentProbe
    private let localAgentPairingClaim: LocalAgentPairingClaim
    private let routeProbe: ConnectionRouteProbe
    private let routeVersionProbe: ConnectionRouteVersionProbe?
    private let usesDefaultRouteProbe: Bool
    var ephemeralLocalProfileID: String?
    private var isConnectionPreflightRunning = false
    private var automaticSettingsConnectionTestState: AutomaticSettingsConnectionTestState = .pending
    private var localAgentProbeTask: Task<Bool, Never>?
    var activeRouteEndpoint: String?
    var isTailcatExperimentModeEnabled = false
    var tailcatExperimentEndpoint: String?
    private var activeRuntimeBundle: AppServerRuntimeBundle?
    private var activeRuntimeIdentity: String?
    private var credentialSuspensionTask: Task<Void, Never>?
    private var credentialLifecycleGeneration: UInt64 = 0
    // 仅由 AppStoreCapabilities extension 使用，用 generation 拒绝迟到的协商响应。
    var capabilityNegotiationGeneration: UInt64 = 0
#if DEBUG
    @Published private var debugWorkbenchBypassEnabled = false
    let debugLaunchConfiguration = DebugLaunchConfiguration.current()
#endif

    init(
        defaults: UserDefaults = .standard,
        tokenStore: TokenStore = TokenStore(),
        routeProbeTimeout: TimeInterval = 5,
        prefersLocalConnection: Bool? = nil,
        localAgentProbe: LocalAgentProbe? = nil,
        localAgentPairingClaim: LocalAgentPairingClaim? = nil,
        routeProbe: ConnectionRouteProbe? = nil,
        routeVersionProbe: ConnectionRouteVersionProbe? = nil,
        allowsEphemeralLocalCredentialFallback: Bool? = nil
    ) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        credentialVault = HostCredentialVault(tokenStore: tokenStore)
        self.routeProbeTimeout = routeProbeTimeout
        self.prefersLocalConnection =
            prefersLocalConnection ?? HostConnectionEndpointPolicy.prefersLocalConnectionByDefault
        self.allowsEphemeralLocalCredentialFallback =
            allowsEphemeralLocalCredentialFallback ??
                HostConnectionEndpointPolicy.allowsDevelopmentEphemeralCredentialFallback
        self.localAgentProbe = localAgentProbe ?? Self.defaultLocalAgentProbe
        self.localAgentPairingClaim = localAgentPairingClaim ?? Self.defaultLocalAgentPairingClaim
        self.routeProbe = routeProbe ?? Self.defaultConnectionRouteProbe
        usesDefaultRouteProbe = routeProbe == nil
        self.routeVersionProbe = routeProbe == nil
            ? (routeVersionProbe ?? Self.defaultConnectionRouteVersionProbe)
            : routeVersionProbe

        var initialProfiles = Self.loadConnectionProfiles(from: defaults)
        if defaults.data(forKey: Self.profilesKey) == nil,
           !initialProfiles.isEmpty,
           let migratedProfiles = try? JSONEncoder().encode(initialProfiles) {
            defaults.set(migratedProfiles, forKey: Self.profilesKey)
        }
        var initialActiveProfileID = defaults.string(forKey: Self.activeProfileIDKey)
        var initialEndpoint = defaults.string(forKey: endpointKey) ?? defaultEndpoint
        var initialToken = ""

        if let activeProfileID = initialActiveProfileID,
           let activeProfile = initialProfiles.first(where: { $0.id == activeProfileID }),
           let profileToken = try? tokenStore.load(profileID: activeProfileID),
           !profileToken.isEmpty {
            initialEndpoint = activeProfile.endpoint
            initialToken = profileToken
        } else if initialProfiles.isEmpty {
            // 稳定 V2 冷启动只读 active profile account；只有确实没有 Profile 时才读一次 legacy，
            // 避免保存 5 台 Mac 后把 Keychain 读取次数带进首屏关键路径。
            initialToken = tokenStore.load()
            if initialToken.isEmpty {
                initialActiveProfileID = nil
            } else {
                // 旧版本只有一个 endpoint + `agentd-token`。先把 Token 写入新的独立 account，
                // 成功后才发布档案元数据；任一步失败都继续使用旧内存态和旧 Keychain 项。
                let normalizedEndpoint = (try? Self.validatedEndpoint(initialEndpoint)) ?? defaultEndpoint
                let migratedProfile = ConnectionProfile(
                    id: UUID().uuidString,
                    displayName: Self.defaultProfileDisplayName(endpoint: normalizedEndpoint),
                    endpoint: normalizedEndpoint,
                    lastSuccessfulAt: nil
                )
                do {
                    let encodedProfiles = try JSONEncoder().encode([migratedProfile])
                    try tokenStore.save(initialToken, profileID: migratedProfile.id)
                    defaults.set(encodedProfiles, forKey: Self.profilesKey)
                    defaults.set(encodedProfiles, forKey: Self.legacyProfilesKey)
                    defaults.set(migratedProfile.id, forKey: Self.activeProfileIDKey)
                    initialProfiles = [migratedProfile]
                    initialActiveProfileID = migratedProfile.id
                    // 新档案已完整可恢复后再清理 legacy；删除失败只会留下冗余 Keychain 项，
                    // 不会让当前连接或新档案失效。
                    try? tokenStore.delete(allowMissing: true)
                } catch {
                    initialProfiles = []
                    initialActiveProfileID = nil
                }
            }
        } else {
            // 已存在档案时，即使 legacy item 因旧迁移清理失败而残留，也绝不能重新迁移并覆盖档案列表。
            // 当前档案 Token 不可读时先退出 active 状态，让用户显式重试或重新配对。
            initialActiveProfileID = nil
        }
#if DEBUG
        // Debug 启动参数只影响本次内存态，避免把本地调试 token 写进 Keychain 或带进 Release 流程。
        if let debugEndpoint = debugLaunchConfiguration.endpoint,
           let normalizedEndpoint = try? Self.validatedEndpoint(debugEndpoint) {
            initialEndpoint = normalizedEndpoint
        }
        if let debugToken = debugLaunchConfiguration.token {
            initialToken = debugToken
        }
        if debugLaunchConfiguration.endpoint != nil || debugLaunchConfiguration.token != nil {
            initialActiveProfileID = nil
        }
        if let previewPlatform = debugLaunchConfiguration.hostPlatformPreview {
            let previewProfile = ConnectionProfile(
                id: "debug-platform-preview",
                displayName: L10n.format(
                    "ui.host_platform_preview_name",
                    previewPlatform.displayName ?? L10n.text("ui.unknown")
                ),
                endpoint: "http://127.0.0.1:8787",
                lastSuccessfulAt: Date(),
                installationID: "debug-platform-preview",
                hostPlatform: previewPlatform
            )
            initialProfiles = [
                previewProfile,
                ConnectionProfile(
                    id: "debug-platform-companion",
                    displayName: L10n.text("ui.another_host"),
                    endpoint: "http://127.0.0.1:8788",
                    lastSuccessfulAt: nil,
                    installationID: "debug-platform-companion",
                    hostPlatform: .unknown
                )
            ]
            initialActiveProfileID = previewProfile.id
            initialEndpoint = previewProfile.endpoint
            initialToken = ""
        }
        debugLaunchConfiguration.applyStoreScreenshotFixture(profiles: &initialProfiles, activeProfileID: &initialActiveProfileID, endpoint: &initialEndpoint, token: &initialToken)
#endif
        initialEndpoint = (try? Self.validatedEndpoint(initialEndpoint)) ?? defaultEndpoint
        self.endpoint = initialEndpoint
        self.token = initialToken
        connectionProfiles = initialProfiles
        activeConnectionProfileID = initialActiveProfileID
        let initialProfile = initialProfiles.first { $0.id == initialActiveProfileID }
        let initialProfileID = initialProfile?.id ?? initialActiveProfileID ?? "legacy"
        activeHostState = ActiveHostState(
            scope: HostScope(
                profileID: initialProfileID,
                installationID: initialProfile?.installationID ?? Self.unboundInstallationID(profileID: initialProfileID),
                generation: 0
            ),
            endpoint: initialEndpoint,
            displayName: initialProfile?.displayName ?? Self.defaultProfileDisplayName(endpoint: initialEndpoint),
            committedAt: Date(),
            capabilityNegotiation: .notNegotiated
        )
#if DEBUG
        debugWorkbenchBypassEnabled = debugLaunchConfiguration.opensWorkbenchWithoutPairing
        _ = debugLaunchConfiguration.applyStoreScreenshotConnectionState(status: &connectionStatus, lastError: &lastError)
#endif
        // 当前客户端只保留一个 Tailscale 地址；网络直连、Peer Relay 与 DERP 切换统一交给 Tailscale。
        // 启动即清理旧公网备用地址，避免升级后继续保留已下线入口或敏感公网配置。
        defaults.removeObject(forKey: retiredFallbackEndpointKey)
        defaults.removeObject(forKey: retiredConnectionModeKey)
    }

    var isConfigured: Bool {
        let hasCredentials = !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasCredentials else { return false }
#if DEBUG
        if debugLaunchConfiguration.endpoint != nil || debugLaunchConfiguration.token != nil {
            return true
        }
#endif
        // 迁移失败且尚无档案时继续允许旧单连接工作；一旦已经有档案，只有成功读取
        // 当前档案专属 Token 才能进入工作台，不能把残留 legacy Token 当成 active 凭据。
        return connectionProfiles.isEmpty || activeConnectionProfile != nil
    }

    /// 模式开关与代理端点分开保存。代理启动失败时仍保持 Tailcat-only，禁止隐式回退。
    func setTailcatExperimentModeEnabled(_ enabled: Bool) {
        guard enabled != isTailcatExperimentModeEnabled else { return }
        isTailcatExperimentModeEnabled = enabled
        connectionGeneration &+= 1
        resetDirectRuntime()
        if enabled {
            activeRouteEndpoint = tailcatExperimentEndpoint
            activeConnectionRoute = .tailcat
        } else {
            tailcatExperimentEndpoint = nil
            activeRouteEndpoint = nil
            activeConnectionRoute = .configured
        }
    }

    /// Tailcat 只覆盖本进程的网络路由，不修改当前连接档案及其 Tailscale 地址。
    func setTailcatExperimentEndpoint(_ nextEndpoint: String?) {
        let normalized = nextEndpoint.map(AgentAPIClient.normalizedEndpoint)
        guard normalized != tailcatExperimentEndpoint else { return }
        tailcatExperimentEndpoint = normalized
        connectionGeneration &+= 1
        resetDirectRuntime()
        if let normalized {
            activeRouteEndpoint = normalized
            activeConnectionRoute = .tailcat
        } else {
            activeRouteEndpoint = nil
            activeConnectionRoute = isTailcatExperimentModeEnabled ? .tailcat : .configured
        }
    }

    /// 只为主机选择器生成探活描述；Token 读取在独立 actor 中执行。
    /// await 返回后再次核对 revision，避免设置页编辑期间把旧凭据发向新地址。
    func hostProbeDescriptor(profileID: String) async throws -> HostProbeDescriptor {
        guard let profile = connectionProfiles.first(where: { $0.id == profileID }) else {
            throw ConnectionProfileError.notFound
        }
        let capturedRevision = profile.revision
        let token = try await credentialVault.token(for: profileID)
        guard let current = connectionProfiles.first(where: { $0.id == profileID }),
              current.revision == capturedRevision,
              current.endpoint == profile.endpoint else {
            throw CancellationError()
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionProfileError.missingToken
        }
        return HostProbeDescriptor(
            profileID: profile.id,
            profileRevision: profile.revision,
            endpoints: profile.connectionCandidates,
            token: token,
            expectedInstallationID: profile.installationID
        )
    }

    /// 只在用户明确点击复制时读取目标 Profile 的 Keychain 凭据。
    /// await 返回后重新核对 revision，避免并发编辑时把旧 Token 与新地址拼成错误链接。
    func connectionTransferLink(
        profileID: String,
        issuedAt: Date = Date()
    ) async throws -> ConnectionTransferLink {
        guard let profile = connectionProfiles.first(where: { $0.id == profileID }) else {
            throw ConnectionProfileError.notFound
        }
        let capturedRevision = profile.revision
        let profileToken = try await credentialVault.token(for: profileID)
        guard let current = connectionProfiles.first(where: { $0.id == profileID }),
              current.revision == capturedRevision,
              current.endpoint == profile.endpoint else {
            throw CancellationError()
        }
        return try ConnectionTransferLink(
            endpoint: profile.endpoint,
            token: profileToken,
            issuedAt: issuedAt
        )
    }

    /// 进入后台时同时清空 Vault、公开内存 Token 与复用 Runtime。
    /// Profile 元数据仍在，回前台只恢复当前 Profile，不会触碰其它 Mac。
    func suspendCredentialsForBackground() {
#if DEBUG
        guard !debugLaunchConfiguration.seedsStoreScreenshotUI else { return }
#endif
        if activeConnectionProfileID == ephemeralLocalProfileID {
            // 开发包没有可恢复的 Keychain 项；后台保留本进程短期凭据，
            // 进程退出后自然清空，下一次启动必须重新向 agentd 领取。
            return
        }
        credentialLifecycleGeneration &+= 1
        // 先标记“临时挂起”再清空 Token，让根视图继续保留当前会话；
        // 否则 SwiftUI 会把短暂的空 Token 误判成从未配对并切到初始设置页。
        isCredentialMemorySuspended = true
        let runtimeBundle = activeRuntimeBundle
        activeRuntimeBundle = nil
        activeRuntimeIdentity = nil
        token = ""
        let vault = credentialVault
        credentialSuspensionTask = Task {
            await vault.clearMemory()
            await runtimeBundle?.shutdownForHostSwitch()
        }
    }

    /// SessionStore 恢复任何 REST/WS 之前先取回当前 Profile Token，避免后台清理后
    /// 使用空凭据触发一次无意义的 401 或创建半初始化 Runtime。
    func restoreCredentialsForForeground() async throws {
#if DEBUG
        if debugLaunchConfiguration.restoreStoreScreenshotCredentials(token: &token, isCredentialMemorySuspended: &isCredentialMemorySuspended, connectionStatus: &connectionStatus, lastError: &lastError) { return }
#endif
        let lifecycleGeneration = credentialLifecycleGeneration
        let suspensionTask = credentialSuspensionTask
        await suspensionTask?.value
        guard credentialLifecycleGeneration == lifecycleGeneration else {
            throw CancellationError()
        }
        credentialSuspensionTask = nil
        guard let profileID = activeConnectionProfileID,
              connectionProfiles.contains(where: { $0.id == profileID }) else {
            isCredentialMemorySuspended = false
            return
        }
        do {
            let restoredToken = try await credentialVault.token(for: profileID)
            guard !restoredToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConnectionProfileError.missingToken
            }
            // await 期间若再次进入后台或切换连接，旧 Token 不得重新出现在内存中。
            guard credentialLifecycleGeneration == lifecycleGeneration,
                  activeConnectionProfileID == profileID else {
                throw CancellationError()
            }
            token = restoredToken
            isCredentialMemorySuspended = false
        } catch {
            // 真正的凭据读取失败仍应退出工作台；新的后台代次则继续保留挂起状态。
            if credentialLifecycleGeneration == lifecycleGeneration {
                isCredentialMemorySuspended = false
            }
            throw error
        }
    }

    var requiresRePairing: Bool {
        connectionTermination == .credentialsInvalid
    }

    func markCredentialsInvalid() {
        let termination = ConnectionTerminationStatus.credentialsInvalid
        connectionTermination = termination
        connectionStatus = .failed(termination.message)
        lastError = termination.message
    }

    var canEnterWorkbench: Bool {
        if isConfigured {
            return true
        }
        // 后台主动清空的只是敏感内存，不代表配对关系失效。保留根工作台可让
        // App 切换器继续显示离开前的会话，同时不把 Token 留在内存或继续联网。
        if isCredentialMemorySuspended,
           activeConnectionProfile != nil,
           !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
#if DEBUG
        return debugWorkbenchBypassEnabled
#else
        return false
#endif
    }

#if DEBUG
    func enterDebugWorkbenchWithoutPairing() {
        debugWorkbenchBypassEnabled = true
    }

    var shouldSeedDebugWorkbenchUI: Bool {
        debugLaunchConfiguration.seedsWorkbenchUI
    }

    var shouldSeedDebugQueuedTurnsUI: Bool {
        debugLaunchConfiguration.seedsQueuedTurnsUI
    }

    var shouldSeedDebugMCPApprovalUI: Bool {
        debugLaunchConfiguration.seedsMCPApprovalUI
    }

    var shouldSeedDebugHistoryUnreadUI: Bool {
        debugLaunchConfiguration.seedsHistoryUnreadUI
    }
    // TODO(工作区行样式评审): A/B/C 定稿后连同 DebugLaunchConfiguration 里的两个字段一起删除。
    var shouldSeedDebugDenseWorkspaceUI: Bool { debugLaunchConfiguration.seedsDenseWorkspaceUI }
#endif

    func client() throws -> AgentAPIClient {
        guard authenticatedCredentialFingerprint != nil else {
            throw CancellationError()
        }
        let endpoint = try Self.validatedEndpoint(connectionEndpoint)
        return AgentAPIClient(endpoint: endpoint, token: token)
    }

    func makeSessionStoreAPIClient() throws -> any SessionStoreAPIClient {
        guard authenticatedCredentialFingerprint != nil else {
            throw CancellationError()
        }
        let endpoint = try Self.validatedEndpoint(connectionEndpoint)
        return CodexAppServerRuntimeRoutingSessionAPIClient(bundle: runtimeBundle(endpoint: endpoint, token: token))
    }

    func makeSessionWebSocketClient() -> any SessionWebSocketClient {
        MultiRuntimeSessionWebSocketClient(bundle: runtimeBundle(
            endpoint: AgentAPIClient.normalizedEndpoint(connectionEndpoint),
            token: token
        ))
    }

    func makeSessionWebSocketClient(for session: AgentSession) -> any SessionWebSocketClient {
        let bundle = runtimeBundle(
            endpoint: AgentAPIClient.normalizedEndpoint(connectionEndpoint),
            token: token
        )
        bundle.routes.remember(session)
        return MultiRuntimeSessionWebSocketClient(bundle: bundle)
    }

    func replaceCapabilityNegotiation(_ negotiation: HostCapabilityNegotiation, preserving state: ActiveHostState) { activeHostState = state.replacingCapabilityNegotiation(with: negotiation) }

    func prepareConnectionSettings(
        endpoint: String,
        token: String,
        profileTarget: PreparedConnectionProfileTarget = .currentOrNew(displayName: nil),
        tailscaleDNSName: String? = nil,
        tailscaleDeviceName: String? = nil
    ) async throws -> PreparedConnectionSettings {
        let normalizedEndpoint = try Self.validatedEndpoint(endpoint)
        let normalizedDNSName = ConnectionProfile.normalizedTailscaleDNSName(tailscaleDNSName)
        let normalizedDeviceName = ConnectionProfile.normalizedTailscaleDeviceName(
            tailscaleDeviceName,
            dnsName: normalizedDNSName
        )
        let candidates = ConnectionProfile.connectionCandidates(
            endpoint: normalizedEndpoint,
            tailscaleDNSName: normalizedDNSName
        )
        var finalError: Error?
        for candidate in candidates {
            do {
                if usesDefaultRouteProbe {
                    return try await prepareFastHostContext(
                        activeEndpoint: candidate,
                        fallbackEndpoint: normalizedEndpoint,
                        token: token,
                        profileTarget: profileTarget,
                        tailscaleDNSName: normalizedDNSName,
                        tailscaleDeviceName: normalizedDeviceName
                    )
                }

                // 测试和兼容注入仍保留原 routeProbe seam，但候选顺序与生产路径一致。
                try await routeProbe(candidate, token, routeProbeTimeout)
                return PreparedConnectionSettings(
                    endpoint: normalizedEndpoint,
                    activeEndpoint: candidate,
                    token: token,
                    profileTarget: profileTarget,
                    tailscaleDNSName: normalizedDNSName,
                    tailscaleDeviceName: normalizedDeviceName
                )
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw error
                }
                finalError = error
            }
        }
        throw finalError ?? URLError(.cannotConnectToHost)
    }

    func prepareNewConnectionProfile(
        endpoint: String,
        token: String,
        displayName: String
    ) async throws -> PreparedConnectionSettings {
        try await prepareConnectionSettings(
            endpoint: endpoint,
            token: token,
            profileTarget: .newProfile(
                id: UUID().uuidString,
                displayName: Self.normalizedProfileDisplayName(displayName, endpoint: endpoint)
            )
        )
    }

    func preparePairingURL(
        _ url: URL,
        profileTarget: PreparedConnectionProfileTarget = .currentOrNew(displayName: nil)
    ) async throws -> PreparedConnectionSettings {
        if let ticket = try Self.pairingTicket(from: url) {
            let credentials = try await claimPairing(ticket)
            return try await prepareConnectionSettings(
                endpoint: credentials.endpoint,
                token: credentials.token,
                profileTarget: profileTarget,
                tailscaleDNSName: credentials.tailscaleDNSName,
                tailscaleDeviceName: credentials.tailscaleDeviceName
            )
        }
        let credentials = try Self.pairingCredentials(from: url)
        return try await prepareConnectionSettings(
            endpoint: credentials.endpoint,
            token: credentials.token,
            profileTarget: profileTarget,
            tailscaleDNSName: credentials.tailscaleDNSName,
            tailscaleDeviceName: credentials.tailscaleDeviceName
        )
    }

    func prepareNewPairingURL(_ url: URL, displayName: String) async throws -> PreparedConnectionSettings {
        // 新档案目标必须在兑换二维码前就确定，并贯穿身份校验、Runtime 预热和提交。
        // 如果先按 currentOrNew 准备、最后再改成 newProfile，第二台电脑会被误判为
        // 当前档案更换了安装身份，且 PreparedHostLease 仍会保留错误目标。
        return try await preparePairingURL(
            url,
            profileTarget: .newProfile(
                id: UUID().uuidString,
                displayName: displayName
            )
        )
    }

    @discardableResult
    func commitConnectionSettings(_ prepared: PreparedConnectionSettings) async throws -> Bool {
        let normalizedEndpoint = try Self.validatedEndpoint(prepared.endpoint)
        let normalizedActiveEndpoint = try Self.validatedEndpoint(prepared.activeEndpoint)
        let installationID = Self.normalizedInstallationID(prepared.installationID)
        let preparedLease = installationID.map {
            PreparedHostLease(
                endpoint: normalizedActiveEndpoint,
                installationID: $0,
                profileTarget: prepared.profileTarget,
                profileRevision: profileRevision(for: prepared.profileTarget),
                tokenFingerprint: Self.tokenFingerprint(prepared.token)
            )
        }
        let candidateRuntime: AppServerRuntimeBundle?
        if let hostContext = prepared.hostContext {
            guard let preparedLease else {
                throw ConnectionProfileError.preparedContextMismatch
            }
            candidateRuntime = try hostContext.validatedRuntimeBundle(matching: preparedLease)
        } else {
            candidateRuntime = nil
        }
        let targetProfile: ConnectionProfile
        switch prepared.profileTarget {
        case .currentOrNew(let displayName):
            if let activeConnectionProfileID,
               let current = connectionProfiles.first(where: { $0.id == activeConnectionProfileID }) {
                try Self.validateInstallationIdentity(
                    actual: installationID,
                    expected: current.installationID,
                    profileName: current.displayName
                )
                try rejectDuplicateInstallation(
                    installationID,
                    excludingProfileID: current.id
                )
                let metadata = Self.resolvedTailscaleMetadata(prepared: prepared, existing: current)
                let display = Self.resolvedProfileDisplay(
                    existing: current,
                    requested: displayName,
                    endpoint: normalizedEndpoint,
                    tailscaleDeviceName: metadata.deviceName
                )
                targetProfile = ConnectionProfile(
                    id: current.id,
                    displayName: display.name,
                    endpoint: normalizedEndpoint,
                    tailscaleDNSName: metadata.dnsName,
                    tailscaleDeviceName: metadata.deviceName,
                    isDisplayNameCustomized: display.customized,
                    lastSuccessfulAt: prepared.validatedAt,
                    installationID: installationID ?? current.installationID,
                    hostPlatform: resolvedHostPlatform(prepared.hostPlatform, fallback: current.hostPlatform),
                    connectionRoute: prepared.route.profileRoute,
                    revision: current.revision &+ 1
                )
            } else {
                try rejectDuplicateInstallation(installationID, excludingProfileID: nil)
                let display = Self.resolvedProfileDisplay(
                    existing: nil,
                    requested: displayName,
                    endpoint: normalizedEndpoint,
                    tailscaleDeviceName: prepared.tailscaleDeviceName
                )
                targetProfile = ConnectionProfile(
                    id: UUID().uuidString,
                    displayName: display.name,
                    endpoint: normalizedEndpoint,
                    tailscaleDNSName: prepared.tailscaleDNSName,
                    tailscaleDeviceName: prepared.tailscaleDeviceName,
                    isDisplayNameCustomized: display.customized,
                    lastSuccessfulAt: prepared.validatedAt,
                    installationID: installationID,
                    hostPlatform: prepared.hostPlatform,
                    connectionRoute: prepared.route.profileRoute
                )
            }
        case .newProfile(let id, let displayName):
            try rejectDuplicateInstallation(installationID, excludingProfileID: id)
            let display = Self.resolvedProfileDisplay(
                existing: nil,
                requested: displayName,
                endpoint: normalizedEndpoint,
                tailscaleDeviceName: prepared.tailscaleDeviceName
            )
            targetProfile = ConnectionProfile(
                id: id,
                displayName: display.name,
                endpoint: normalizedEndpoint,
                tailscaleDNSName: prepared.tailscaleDNSName,
                tailscaleDeviceName: prepared.tailscaleDeviceName,
                isDisplayNameCustomized: display.customized,
                lastSuccessfulAt: prepared.validatedAt,
                installationID: installationID,
                hostPlatform: prepared.hostPlatform,
                connectionRoute: prepared.route.profileRoute
            )
        case .existingProfile(let id):
            guard let existing = connectionProfiles.first(where: { $0.id == id }) else {
                throw ConnectionProfileError.notFound
            }
            try Self.validateInstallationIdentity(
                actual: installationID,
                expected: existing.installationID,
                profileName: existing.displayName
            )
            try rejectDuplicateInstallation(
                installationID,
                excludingProfileID: existing.id
            )
            let metadata = Self.resolvedTailscaleMetadata(prepared: prepared, existing: existing)
            let display = Self.resolvedProfileDisplay(
                existing: existing,
                requested: nil,
                endpoint: normalizedEndpoint,
                tailscaleDeviceName: metadata.deviceName
            )
            targetProfile = ConnectionProfile(
                id: existing.id,
                displayName: display.name,
                endpoint: normalizedEndpoint,
                tailscaleDNSName: metadata.dnsName,
                tailscaleDeviceName: metadata.deviceName,
                isDisplayNameCustomized: display.customized,
                lastSuccessfulAt: prepared.validatedAt,
                installationID: installationID ?? existing.installationID,
                hostPlatform: resolvedHostPlatform(prepared.hostPlatform, fallback: existing.hostPlatform),
                connectionRoute: prepared.route.profileRoute,
                revision: existing.revision &+ 1
            )
        }

        // 临时开发档案从未持久化凭据；切到其它档案时必须在同一次提交中淘汰，
        // 否则稍后切回会把“只有内存 Token”的档案误写成可恢复的持久档案。
        let previousEphemeralProfileID = ephemeralLocalProfileID
        var nextProfiles = connectionProfiles.filter {
            $0.id != targetProfile.id && $0.id != previousEphemeralProfileID
        }
        nextProfiles.append(targetProfile)
        let encodedProfiles = try JSONEncoder().encode(nextProfiles)
        let didChange = normalizedEndpoint != endpoint ||
            prepared.token != token ||
            targetProfile.id != activeConnectionProfileID ||
            targetProfile.installationID != activeConnectionProfile?.installationID ||
            targetProfile.tailscaleDNSName != activeConnectionProfile?.tailscaleDNSName ||
            targetProfile.tailscaleDeviceName != activeConnectionProfile?.tailscaleDeviceName ||
            targetProfile.displayName != activeConnectionProfile?.displayName ||
            targetProfile.hostPlatform != activeConnectionProfile?.hostPlatform ||
            targetProfile.connectionRoute != activeConnectionProfile?.connectionRoute

        // Token 优先按档案经 Vault actor 写入 Keychain；MainActor 不执行安全框架 I/O。
        // 未签入 provisioning profile 的开发包只在受限私网 + -34018 时使用进程内凭据。
        let credentialLifecycle = credentialLifecycleGeneration
        let credentialReceipt: HostCredentialWriteReceipt
        let usesEphemeralLocalCredential: Bool
        let isContinuingEphemeralCredential =
            previousEphemeralProfileID == targetProfile.id &&
            HostConnectionEndpointPolicy.isEligibleEphemeralCredentialEndpoint(normalizedEndpoint)
        if isContinuingEphemeralCredential {
            credentialReceipt = await credentialVault.rememberInMemory(prepared.token, for: targetProfile.id)
            usesEphemeralLocalCredential = true
        } else {
            do {
                credentialReceipt = try await credentialVault.save(
                    prepared.token,
                    for: targetProfile.id,
                    forcePersistence: previousEphemeralProfileID == targetProfile.id
                )
                usesEphemeralLocalCredential = false
            } catch {
                let canUseEphemeralLocalCredential =
                    allowsEphemeralLocalCredentialFallback &&
                    HostConnectionEndpointPolicy.isEligibleEphemeralCredentialEndpoint(normalizedEndpoint) &&
                    (error as? TokenStoreError)?.isMissingEntitlement == true
                guard canUseEphemeralLocalCredential else {
                    throw error
                }
                // Catalyst 仅允许同机 loopback；Debug Simulator 允许用于本地验收的私网 HTTP。
                // Token 不进入 UserDefaults，进程退出即失效；Release / TestFlight 不启用此降级。
                credentialReceipt = await credentialVault.rememberInMemory(
                    prepared.token,
                    for: targetProfile.id
                )
                usesEphemeralLocalCredential = true
            }
        }
        guard credentialLifecycle == credentialLifecycleGeneration, !Task.isCancelled else {
            // App 在 Keychain await 期间进入后台时，候选提交必须回滚，A 的元数据和 Runtime 不变。
            if usesEphemeralLocalCredential {
                await credentialVault.rollbackMemory(credentialReceipt, profileID: targetProfile.id)
            } else {
                try? await credentialVault.rollback(credentialReceipt, profileID: targetProfile.id)
            }
            throw CancellationError()
        }
        if usesEphemeralLocalCredential {
            ephemeralLocalProfileID = targetProfile.id
        } else {
            ephemeralLocalProfileID = nil
            persistProfiles(encodedProfiles)
            defaults.set(targetProfile.id, forKey: Self.activeProfileIDKey)
            defaults.set(normalizedEndpoint, forKey: endpointKey)
            defaults.removeObject(forKey: retiredFallbackEndpointKey)
            defaults.removeObject(forKey: retiredConnectionModeKey)
        }

        let previousRuntimeBundle = activeRuntimeBundle
        endpoint = normalizedEndpoint
        token = prepared.token
        connectionProfiles = nextProfiles
        activeConnectionProfileID = targetProfile.id
        if let previousEphemeralProfileID,
           previousEphemeralProfileID != targetProfile.id {
            // 旧临时档案没有 Keychain 项，只清理进程内 Token，避免 entitlement 错误扩大失败面。
            await credentialVault.forgetMemory(profileID: previousEphemeralProfileID)
        }
        connectionTermination = nil
        // 每次提交都开启新的连接代次。即使地址没变，旧异步结果也必须失效。
        connectionGeneration += 1
        if case .tailcat = prepared.route {
            isTailcatExperimentModeEnabled = true
            tailcatExperimentEndpoint = normalizedActiveEndpoint
            activeRouteEndpoint = normalizedActiveEndpoint
            activeConnectionRoute = .tailcat
        } else {
            isTailcatExperimentModeEnabled = false
            tailcatExperimentEndpoint = nil
            activeRouteEndpoint = normalizedActiveEndpoint
            activeConnectionRoute = .configured
        }
        if let candidateRuntime {
            prepared.hostContext?.markConsumed()
            activeRuntimeIdentity = runtimeIdentity(endpoint: normalizedActiveEndpoint, token: prepared.token)
            activeRuntimeBundle = candidateRuntime
        } else {
            activeRuntimeIdentity = nil
            activeRuntimeBundle = nil
        }
        activeHostState = ActiveHostState(
            scope: HostScope(
                profileID: targetProfile.id,
                installationID: targetProfile.installationID ?? Self.unboundInstallationID(profileID: targetProfile.id),
                generation: UInt64(connectionGeneration)
            ),
            endpoint: normalizedEndpoint,
            displayName: targetProfile.displayName,
            committedAt: prepared.validatedAt,
            capabilityNegotiation: prepared.capabilityNegotiation
        )
        lastError = nil
        HostSwitchSignpost.event("host_commit")

        if let previousRuntimeBundle,
           candidateRuntime.map({ previousRuntimeBundle === $0 }) != true {
            Task {
                await previousRuntimeBundle.shutdownForHostSwitch()
            }
        }
        return didChange
    }

    func validatePairingURL(_ url: URL) async throws -> PairingCredentials {
        if let ticket = try Self.pairingTicket(from: url) {
            let credentials = try await claimPairing(ticket)
            let normalized = try await validateConnection(endpoint: credentials.endpoint, token: credentials.token)
            return PairingCredentials(
                endpoint: normalized,
                token: credentials.token,
                tailscaleDNSName: credentials.tailscaleDNSName,
                tailscaleDeviceName: credentials.tailscaleDeviceName
            )
        }
        let credentials = try Self.pairingCredentials(from: url)
        // 手动调用时只测试外侧 agentd 连接；首次扫码路径会直接保存，减少一次确认。
        let normalized = try await validateConnection(endpoint: credentials.endpoint, token: credentials.token)
        return PairingCredentials(endpoint: normalized, token: credentials.token)
    }

    func clearPairing() async throws {
        // 持久化凭据必须先完成 Keychain 删除；临时开发凭据只需清理进程内缓存。
        // 否则系统暂时禁止 Keychain 访问时，下一次启动会变成“旧 Token + 默认 Endpoint”的半提交状态。
        let nextProfiles: [ConnectionProfile]
        if let activeConnectionProfileID {
            nextProfiles = connectionProfiles.filter { $0.id != activeConnectionProfileID }
        } else {
            nextProfiles = connectionProfiles
        }
        let encodedProfiles = try JSONEncoder().encode(nextProfiles)
        let removedProfileID = activeConnectionProfileID
        if let removedProfileID {
            if removedProfileID == ephemeralLocalProfileID {
                await credentialVault.forgetMemory(profileID: removedProfileID)
            } else {
                try await credentialVault.delete(profileID: removedProfileID)
            }
        } else {
            try await credentialVault.deleteLegacy()
        }
        persistProfiles(encodedProfiles)
        defaults.removeObject(forKey: Self.activeProfileIDKey)
        defaults.removeObject(forKey: endpointKey)
        defaults.removeObject(forKey: retiredFallbackEndpointKey)
        defaults.removeObject(forKey: retiredConnectionModeKey)
        resetConnectionRoute()
        endpoint = defaultEndpoint
        connectionProfiles = nextProfiles
        activeConnectionProfileID = nil
        ephemeralLocalProfileID = nil
        connectionGeneration += 1
        token = ""
        let legacyProfileID = "legacy"
        activeHostState = ActiveHostState(
            scope: HostScope(
                profileID: legacyProfileID,
                installationID: Self.unboundInstallationID(profileID: legacyProfileID),
                generation: UInt64(connectionGeneration)
            ),
            endpoint: defaultEndpoint,
            displayName: Self.defaultProfileDisplayName(endpoint: defaultEndpoint),
            committedAt: Date(),
            capabilityNegotiation: .notNegotiated
        )
        connectionTermination = nil
        connectionStatus = .idle
        lastError = nil
        lastConnectionTestDurationMillis = nil
        lastConnectionTestReport = nil
        recentConnectionTestReports = []
    }

    func deleteConnectionProfile(id: String) async throws {
        guard id != activeConnectionProfileID else {
            throw ConnectionProfileError.cannotDeleteCurrent
        }
        guard connectionProfiles.contains(where: { $0.id == id }) else {
            throw ConnectionProfileError.notFound
        }
        let nextProfiles = connectionProfiles.filter { $0.id != id }
        let encodedProfiles = try JSONEncoder().encode(nextProfiles)
        // 删除也以 Keychain 为提交点；系统暂时不可访问时保留整条档案，方便用户稍后重试。
        try await credentialVault.delete(profileID: id)
        persistProfiles(encodedProfiles)
        connectionProfiles = nextProfiles
    }

    /// 只修改非敏感显示名称，不进入连接切换事务，也不读取或写入 Keychain。
    /// 临时开发档案保持进程内；其它档案先完成编码再发布，避免出现半提交名称。
    @discardableResult
    func renameConnectionProfile(id: String, displayName rawDisplayName: String) throws -> Bool {
        guard let profileIndex = connectionProfiles.firstIndex(where: { $0.id == id }) else {
            throw ConnectionProfileError.notFound
        }
        let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            throw ConnectionProfileError.invalidDisplayName
        }
        guard displayName.count <= Self.connectionProfileDisplayNameLimit else {
            throw ConnectionProfileError.displayNameTooLong(maximum: Self.connectionProfileDisplayNameLimit)
        }
        guard displayName != connectionProfiles[profileIndex].displayName ||
                !connectionProfiles[profileIndex].isDisplayNameCustomized else {
            return false
        }

        var nextProfiles = connectionProfiles
        nextProfiles[profileIndex].displayName = displayName
        nextProfiles[profileIndex].isDisplayNameCustomized = true
        nextProfiles[profileIndex].revision &+= 1
        if id != ephemeralLocalProfileID {
            let encodedProfiles = try JSONEncoder().encode(nextProfiles)
            persistProfiles(encodedProfiles)
        }
        connectionProfiles = nextProfiles
        if id == activeConnectionProfileID {
            activeHostState = ActiveHostState(
                scope: activeHostState.scope,
                endpoint: activeHostState.endpoint,
                displayName: displayName,
                committedAt: activeHostState.committedAt,
                capabilityNegotiation: activeHostState.capabilityNegotiation
            )
        }
        return true
    }

    /// 主机探活可在不切换连接的情况下补齐平台元数据。
    ///
    /// 平台不参与凭据或路由身份，因此不递增 revision；但仍核对探测开始时的 revision，
    /// 防止旧请求在用户编辑连接地址后覆盖新档案。
    func rememberHostPlatform(
        _ hostPlatform: HostPlatform,
        profileID: String,
        expectedRevision: UInt64
    ) {
        guard hostPlatform != .unknown,
              let profileIndex = connectionProfiles.firstIndex(where: {
                  $0.id == profileID && $0.revision == expectedRevision
              }),
              connectionProfiles[profileIndex].hostPlatform != hostPlatform else {
            return
        }

        var nextProfiles = connectionProfiles
        nextProfiles[profileIndex].hostPlatform = hostPlatform
        if profileID != ephemeralLocalProfileID {
            guard let encodedProfiles = try? JSONEncoder().encode(nextProfiles) else {
                return
            }
            persistProfiles(encodedProfiles)
        }
        connectionProfiles = nextProfiles
    }
    @discardableResult
    func validateConnection(
        endpoint: String,
        token: String,
        route: ConnectionTestRoute = .tailscale,
        affectsConnectionStatus: Bool = true
    ) async throws -> String {
        let startedAt = Date()
        var stages: [ConnectionTestStageTiming] = []
        var gatewayDiagnosticsBaseline: RelayDiagnosticsResponse?
        var gatewayDiagnostics: ConnectionTestGatewayDiagnostics?
        var gatewayDiagnosticsError: String?
        var tailscaleNetworkPath: TailscaleNetworkPathResponse?
        if affectsConnectionStatus {
            connectionStatus = .testing
            lastError = nil
        }
        lastConnectionTestDurationMillis = nil
        lastConnectionTestReport = nil

        func appendStage(_ kind: ConnectionTestStageTiming.Kind, since stageStartedAt: Date, status: ConnectionTestStageTiming.Status) {
            stages.append(ConnectionTestStageTiming(
                kind: kind,
                durationMillis: Self.elapsedMilliseconds(since: stageStartedAt),
                status: status
            ))
        }

        func publishReport() {
            // 诊断快照是为了定位瓶颈，不属于真实业务链路；总耗时只汇总上面几个测试阶段。
            let totalMillis = stages.reduce(0) { $0 + $1.durationMillis }
            let report = ConnectionTestReport(
                route: route,
                startedAt: startedAt,
                totalMillis: totalMillis,
                stages: stages,
                tailscaleNetworkPath: tailscaleNetworkPath,
                gatewayDiagnostics: gatewayDiagnostics,
                gatewayDiagnosticsError: gatewayDiagnosticsError
            )
            lastConnectionTestDurationMillis = totalMillis
            lastConnectionTestReport = report
            rememberConnectionTestReport(report)
        }

        func captureGatewayDiagnostics(client: AgentAPIClient, gatewayStartedAt: Date) async {
            do {
                let snapshot = try await client.relayDiagnostics()
                gatewayDiagnostics = ConnectionTestGatewayDiagnostics.make(
                    baseline: gatewayDiagnosticsBaseline,
                    snapshot: snapshot,
                    gatewayStartedAt: gatewayStartedAt
                )
                gatewayDiagnosticsError = nil
            } catch {
                gatewayDiagnostics = nil
                gatewayDiagnosticsError = error.localizedDescription
            }
        }

        func captureTailscaleNetworkPath(client: AgentAPIClient) async {
            // Tailscale 路径是可选现场证据。旧 agentd、局域网或 CLI 不可用时不能影响主链路测速。
            tailscaleNetworkPath = try? await client.tailscaleNetworkPath()
        }

        let normalized = try Self.validatedEndpoint(endpoint)
        let client = AgentAPIClient(endpoint: normalized, token: token)

        let healthStartedAt = Date()
        do {
            _ = try await client.health()
            appendStage(.health, since: healthStartedAt, status: .succeeded)
        } catch {
            appendStage(.health, since: healthStartedAt, status: .failed(error.localizedDescription))
            publishReport()
            throw error
        }

        let versionStartedAt = Date()
        let version: VersionResponse
        do {
            version = try await client.version()
            appendStage(.version, since: versionStartedAt, status: .succeeded)
        } catch {
            appendStage(.version, since: versionStartedAt, status: .failed(error.localizedDescription))
            publishReport()
            throw error
        }

        let configStartedAt = Date()
        let config: CodexAppServerConfigResponse
        do {
            config = try await client.appServerConfig()
            appendStage(.appServerConfig, since: configStartedAt, status: .succeeded)
        } catch {
            appendStage(.appServerConfig, since: configStartedAt, status: .failed(error.localizedDescription))
            publishReport()
            throw error
        }

        gatewayDiagnosticsBaseline = try? await client.relayDiagnostics()

        let gatewayStartedAt = Date()
        do {
            let runtime = CodexAppServerSessionRuntime(endpoint: normalized, token: token, configProvider: { config })
            try await runtime.validateDirectGateway()
            appendStage(.appServerGateway, since: gatewayStartedAt, status: .succeeded)
        } catch {
            appendStage(.appServerGateway, since: gatewayStartedAt, status: .failed(error.localizedDescription))
            await captureGatewayDiagnostics(client: client, gatewayStartedAt: gatewayStartedAt)
            if route == .tailscale {
                await captureTailscaleNetworkPath(client: client)
            }
            publishReport()
            throw error
        }

        await captureGatewayDiagnostics(client: client, gatewayStartedAt: gatewayStartedAt)
        if route == .tailscale {
            await captureTailscaleNetworkPath(client: client)
        }
        publishReport()
        if affectsConnectionStatus {
            connectionStatus = .connected(version.version)
        }
        return normalized
    }

    var connectionTestStageStabilities: [ConnectionTestStageStability] {
        Self.connectionTestStageStabilities(reports: recentConnectionTestReports)
    }

    var mostUnstableConnectionTestStage: ConnectionTestStageStability? {
        connectionTestStageStabilities.max { lhs, rhs in
            if lhs.failureCount != rhs.failureCount {
                return lhs.failureCount < rhs.failureCount
            }
            if lhs.spreadMillis != rhs.spreadMillis {
                return lhs.spreadMillis < rhs.spreadMillis
            }
            return lhs.maxMillis < rhs.maxMillis
        }
    }

    private func rememberConnectionTestReport(_ report: ConnectionTestReport) {
        recentConnectionTestReports.append(report)
        let overflow = recentConnectionTestReports.count - maxConnectionTestReportHistory
        if overflow > 0 {
            recentConnectionTestReports.removeFirst(overflow)
        }
    }

    /// 每次 App 生命周期内只在第一次进入正式设置页时自动测速一次。
    ///
    /// 冷启动的 RootView 可能仍在执行轻量 preflight；这里先等待它结束，再决定是否需要完整测速，
    /// 避免两个探测同时改写连接状态。用户手动点击“重新测速”不经过此门闩，后续仍可随时执行。
    @discardableResult
    func testConnectionOnFirstSettingsAppearanceIfNeeded() async -> Bool {
#if DEBUG
        if debugLaunchConfiguration.applyStoreScreenshotConnectionState(status: &connectionStatus, lastError: &lastError) { return false }
#endif
        guard case .pending = automaticSettingsConnectionTestState else {
            return false
        }
        automaticSettingsConnectionTestState = .running
        var shouldRetryAfterCancellation = false
        defer {
            automaticSettingsConnectionTestState = shouldRetryAfterCancellation ? .pending : .completed
        }

        guard isConfigured, !requiresRePairing else {
            return false
        }

        do {
            while case .testing = connectionStatus {
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            // 页面快速关闭导致任务取消时不消耗本次机会，下次真正进入设置仍会自动测速。
            shouldRetryAfterCancellation = true
            return false
        }

        guard !Task.isCancelled else {
            shouldRetryAfterCancellation = true
            return false
        }
        guard lastConnectionTestReport == nil else {
            return false
        }

        await testConnection(
            endpoint: connectionEndpoint,
            token: token,
            route: isTailcatExperimentModeEnabled ? .tailcat : .tailscale
        )
        if Task.isCancelled {
            shouldRetryAfterCancellation = true
        }
        return true
    }

    /// 用已保存的连接信息做轻量真实链路探测，让设置页不必等用户手动点“测试连接”才显示状态。
    @discardableResult
    func preflightConnection(force: Bool = false) async -> Bool {
#if DEBUG
        if debugLaunchConfiguration.applyStoreScreenshotConnectionState(status: &connectionStatus, lastError: &lastError) { return true }
#endif
        let usesTailcatExperiment = isTailcatExperimentModeEnabled
        if usesTailcatExperiment, tailcatExperimentEndpoint == nil {
            let error = URLError(.notConnectedToInternet)
            connectionStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            return false
        }
        let localAvailable = usesTailcatExperiment ? false : await detectLocalAgent(force: force)
        if !force, case .connected = connectionStatus {
            return true
        }
        // RootView 和设置页可能同时触发；只保留一次探测，避免重复建立 WebSocket。
        guard !isConnectionPreflightRunning else {
            return false
        }
        isConnectionPreflightRunning = true
        defer { isConnectionPreflightRunning = false }

        guard isConfigured else {
            guard localAvailable else {
                connectionStatus = .idle
                return false
            }
            connectionStatus = .testing
            lastError = nil
            do {
                try await connectToLocalAgentWithAutomaticPairing()
                return true
            } catch {
                if Task.isCancelled || error is CancellationError {
                    connectionStatus = .idle
                    return false
                }
                let message = L10n.text("ui.the_native_assistant_was_detected_but_the_automatic")
                connectionStatus = .failed(message)
                lastError = message
                return false
            }
        }

        connectionStatus = .testing
        lastError = nil

        let normalizedEndpoint: String
        do {
            // 常规路由仍从档案的规范地址展开 DNS/IP 候选；只有 Tailcat 覆盖该入口。
            normalizedEndpoint = try Self.validatedEndpoint(tailcatExperimentEndpoint ?? endpoint)
        } catch {
            connectionStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            return false
        }

        var candidates: [(endpoint: String, route: ActiveConnectionRoute, timeout: TimeInterval)] = []
        if !usesTailcatExperiment, localAvailable,
           AgentAPIClient.normalizedEndpoint(normalizedEndpoint) != AgentAPIClient.normalizedEndpoint(localAgentEndpoint) {
            candidates.append((
                endpoint: localAgentEndpoint,
                route: .local,
                timeout: min(routeProbeTimeout, 1.5)
            ))
        }
        let configuredEndpoints: [String]
        if !usesTailcatExperiment, let profile = activeConnectionProfile,
           AgentAPIClient.normalizedEndpoint(profile.endpoint) ==
            AgentAPIClient.normalizedEndpoint(normalizedEndpoint) {
            configuredEndpoints = profile.connectionCandidates
        } else {
            configuredEndpoints = [normalizedEndpoint]
        }
        for configuredEndpoint in configuredEndpoints {
            let route: ActiveConnectionRoute = usesTailcatExperiment
                ? .tailcat
                : (HostConnectionEndpointPolicy.isLoopbackEndpoint(configuredEndpoint) ? .local : .configured)
            candidates.append((endpoint: configuredEndpoint, route: route, timeout: routeProbeTimeout))
        }

        var configuredRouteError: Error?
        for candidate in candidates {
            do {
                try await routeProbe(candidate.endpoint, token, candidate.timeout)
                if candidate.route == .configured || candidate.route == .tailcat,
                   let profile = activeConnectionProfile {
                    try await validateConnectionCandidateIdentityAndRefreshHostMetadata(
                        from: candidate.endpoint,
                        profileID: profile.id,
                        expectedRevision: profile.revision,
                        expectedInstallationID: profile.installationID,
                        profileName: profile.displayName,
                        token: token,
                        timeout: routeProbeTimeout,
                        versionProbe: routeVersionProbe
                    )
                }
                // 身份校验必须先于发布 active route；否则 DNSName 被复用时会短暂连接到错误主机。
                activateConnectionRoute(candidate.route, endpoint: candidate.endpoint)
                connectionTermination = nil
                connectionStatus = .connected(candidate.route.statusTitle)
                lastError = nil
                return true
            } catch {
                if Task.isCancelled || error is CancellationError {
                    connectionStatus = .idle
                    return false
                }
                // loopback 可能运行着另一个用户配置；本机 Token 不匹配时继续尝试档案地址，
                // 不能提前把仍有效的 Tailscale 凭据标记为失效。
                if candidate.route == .configured ||
                    AgentAPIClient.normalizedEndpoint(candidate.endpoint) ==
                    AgentAPIClient.normalizedEndpoint(normalizedEndpoint) {
                    configuredRouteError = error
                }
            }
        }

        if !usesTailcatExperiment, localAvailable {
            do {
                try await connectToLocalAgentWithAutomaticPairing()
                return true
            } catch {
                if Task.isCancelled || error is CancellationError {
                    connectionStatus = .idle
                    return false
                }
                // 兼容尚未实现同机配对接口的旧 agentd；保留已配置路由的真实错误，
                // 让用户仍可扫码修复，而不是把 404 之类的升级细节当作凭据终态。
            }
        }

        if !usesTailcatExperiment {
            resetConnectionRoute()
        }
        let finalError = configuredRouteError ?? URLError(.cannotConnectToHost)
        if !usesTailcatExperiment, acceptsCredentialInvalidation(finalError) {
            markCredentialsInvalid()
            return false
        }
        connectionStatus = .failed(finalError.localizedDescription)
        lastError = finalError.localizedDescription
        return false
    }

    /// Catalyst 只探测固定 loopback 健康端点，不扫描局域网，也不读取服务端配置文件。
    /// 这一步不携带 Token；后续必须用已保存或同机自动领取的凭据完成真实 WebSocket 验证。
    @discardableResult
    func detectLocalAgent(force: Bool = false) async -> Bool {
        guard prefersLocalConnection else {
            localAgentDetected = false
            return false
        }
        if !force, localAgentDetected {
            return true
        }
        if let localAgentProbeTask {
            return await localAgentProbeTask.value
        }
        let probe = localAgentProbe
        let endpoint = localAgentEndpoint
        let timeout = min(routeProbeTimeout, 1)
        let probeTask = Task { @MainActor in
            do {
                try await probe(endpoint, timeout)
                return true
            } catch {
                return false
            }
        }
        localAgentProbeTask = probeTask
        let detected = await probeTask.value
        localAgentProbeTask = nil
        // 探测任务由 AppStore 共享；即使某个触发它的 View 已消失，也发布这次有界结果，
        // 避免仍在等待的根启动任务拿到 true，而设置页状态仍停留在未检测。
        localAgentDetected = detected
        return detected
    }

    static func connectionTestStageStabilities(reports: [ConnectionTestReport]) -> [ConnectionTestStageStability] {
        ConnectionTestStageTiming.Kind.allCases.compactMap { kind in
            let stages = reports.compactMap { report in
                report.stages.first { $0.kind == kind }
            }
            guard !stages.isEmpty else {
                return nil
            }
            let durations = stages.map(\.durationMillis)
            let total = durations.reduce(0, +)
            let failures = stages.filter { stage in
                stage.status.isFailed
            }.count
            return ConnectionTestStageStability(
                kind: kind,
                sampleCount: stages.count,
                failureCount: failures,
                minMillis: durations.min() ?? 0,
                maxMillis: durations.max() ?? 0,
                averageMillis: Int((Double(total) / Double(stages.count)).rounded())
            )
        }
    }

    static func connectionTestDurationText(milliseconds: Int) -> String {
        let milliseconds = max(0, milliseconds)
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }
        if milliseconds < 10_000 {
            let seconds = Double(milliseconds) / 1_000
            let formatter = NumberFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            let value = formatter.string(from: NSNumber(value: seconds)) ?? String(seconds)
            return L10n.format("ui.seconds_decimal", value)
        }
        return L10n.plural("ui.seconds_count", count: Int((Double(milliseconds) / 1_000).rounded()))
    }

    private static func elapsedMilliseconds(since startDate: Date) -> Int {
        let elapsed = Date().timeIntervalSince(startDate)
        return max(0, Int((elapsed * 1_000).rounded()))
    }

    private func claimPairing(_ ticket: PairingTicket) async throws -> PairingCredentials {
        let response = try await AgentAPIClient(endpoint: ticket.endpoint, token: "").claimPairing(ticket.claimRequest)
        return PairingCredentials(
            endpoint: try Self.validatedEndpoint(response.endpoint.isEmpty ? ticket.endpoint : response.endpoint),
            token: response.token,
            tailscaleDNSName: response.tailscaleDNSName,
            tailscaleDeviceName: response.tailscaleDeviceName
        )
    }

    static func pairingCredentials(from url: URL) throws -> PairingCredentials {
        if try pairingTicket(from: url) != nil {
            throw PairingLinkError.missingToken
        }
        let route = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let allowedSchemes = ["mimiremote", "mimi"]
        // 兼容早期 agentd 二进制输出的 mimi:// 短链接；新版仍以 mimiremote:// 为主。
        guard allowedSchemes.contains(url.scheme?.lowercased() ?? ""),
              route == "pair" || route == "connect"
        else {
            throw PairingLinkError.unsupportedURL
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let endpoint = components?.queryItems?.first(where: { $0.name == "endpoint" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = components?.queryItems?.first(where: { $0.name == "token" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !endpoint.isEmpty else {
            throw PairingLinkError.missingEndpoint
        }
        guard !token.isEmpty else {
            throw PairingLinkError.missingToken
        }
        let expiresAt = components?.queryItems?.first(where: { $0.name == "expires_at" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !expiresAt.isEmpty {
            guard let expiryDate = pairingDate(from: expiresAt) else {
                throw PairingLinkError.unsupportedURL
            }
            if expiryDate <= Date() {
                throw PairingLinkError.expired
            }
        }
        return PairingCredentials(endpoint: try validatedEndpoint(endpoint), token: token)
    }

    static func pairingTicket(from url: URL) throws -> PairingTicket? {
        let route = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let allowedSchemes = ["mimiremote", "mimi"]
        guard allowedSchemes.contains(url.scheme?.lowercased() ?? ""),
              route == "pair" || route == "connect"
        else {
            throw PairingLinkError.unsupportedURL
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pairSignature = components?.queryItems?.first(where: { $0.name == "pair_sig" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pairSignature.isEmpty else {
            return nil
        }
        let endpoint = components?.queryItems?.first(where: { $0.name == "endpoint" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let issuedAt = components?.queryItems?.first(where: { $0.name == "issued_at" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expiresAt = components?.queryItems?.first(where: { $0.name == "expires_at" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !endpoint.isEmpty else {
            throw PairingLinkError.missingEndpoint
        }
        guard !issuedAt.isEmpty, !expiresAt.isEmpty else {
            throw PairingLinkError.unsupportedURL
        }
        guard let expiryDate = pairingDate(from: expiresAt) else {
            throw PairingLinkError.unsupportedURL
        }
        if expiryDate <= Date() {
            throw PairingLinkError.expired
        }
        return PairingTicket(
            endpoint: try validatedEndpoint(endpoint),
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            pairSignature: pairSignature
        )
    }

    private static func pairingDate(from raw: String) -> Date? {
        if let seconds = TimeInterval(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        // agentd 为保证同一秒刷新出的短期票据仍可区分，会输出 RFC3339Nano 小数秒。
        // 先解析新版格式，再回退到旧版无小数秒格式，保持已发布二维码兼容。
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: raw) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    static func validatedEndpoint(_ raw: String) throws -> String {
        try EndpointTransportPolicy.validatedEndpoint(raw)
    }

    private static func loadConnectionProfiles(from defaults: UserDefaults) -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: profilesKey) ?? defaults.data(forKey: legacyProfilesKey),
              let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data)
        else {
            return []
        }
        var seenIDs = Set<String>()
        return decoded.compactMap { profile in
            let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  seenIDs.insert(id).inserted,
                  let normalizedEndpoint = try? validatedEndpoint(profile.endpoint)
            else {
                return nil
            }
            return ConnectionProfile(
                id: id,
                displayName: normalizedProfileDisplayName(profile.displayName, endpoint: normalizedEndpoint),
                endpoint: normalizedEndpoint,
                tailscaleDNSName: profile.tailscaleDNSName,
                tailscaleDeviceName: profile.tailscaleDeviceName,
                isDisplayNameCustomized: profile.isDisplayNameCustomized,
                lastSuccessfulAt: profile.lastSuccessfulAt,
                installationID: normalizedInstallationID(profile.installationID),
                hostPlatform: profile.hostPlatform,
                connectionRoute: profile.connectionRoute,
                revision: profile.revision
            )
        }
    }

    func persistProfiles(_ encodedProfiles: Data) {
        // V1 镜像保留一个兼容周期，确保旧版本回滚后仍可读取连接档案；Token 仍只在 Keychain。
        defaults.set(encodedProfiles, forKey: Self.profilesKey)
        defaults.set(encodedProfiles, forKey: Self.legacyProfilesKey)
    }

    func replaceConnectionProfiles(_ profiles: [ConnectionProfile]) {
        connectionProfiles = profiles
    }

    private static func normalizedProfileDisplayName(_ raw: String, endpoint: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultProfileDisplayName(endpoint: endpoint) : trimmed
    }

    private static func defaultProfileDisplayName(endpoint: String) -> String {
        ConnectionProfile.fallbackDisplayName(endpoint: endpoint)
    }

    private static func resolvedTailscaleMetadata(
        prepared: PreparedConnectionSettings,
        existing: ConnectionProfile
    ) -> (dnsName: String?, deviceName: String?) {
        let dnsName = prepared.tailscaleDNSName ?? existing.tailscaleDNSName
        let deviceName = ConnectionProfile.normalizedTailscaleDeviceName(
            prepared.tailscaleDeviceName ?? existing.tailscaleDeviceName,
            dnsName: dnsName
        )
        return (dnsName, deviceName)
    }

    private static func resolvedProfileDisplay(
        existing: ConnectionProfile?,
        requested: String?,
        endpoint: String,
        tailscaleDeviceName: String?
    ) -> (name: String, customized: Bool) {
        if let existing, existing.isDisplayNameCustomized {
            return (existing.displayName, true)
        }
        let fallback = defaultProfileDisplayName(endpoint: endpoint)
        let normalizedRequested = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedRequested.isEmpty, normalizedRequested != fallback {
            return (normalizedRequested, true)
        }
        return (tailscaleDeviceName ?? fallback, false)
    }

    private func prepareFastHostContext(
        activeEndpoint: String,
        fallbackEndpoint: String,
        token: String,
        profileTarget: PreparedConnectionProfileTarget,
        tailscaleDNSName: String?,
        tailscaleDeviceName: String?
    ) async throws -> PreparedConnectionSettings {
        let deadline = Date().addingTimeInterval(8)
        let client = AgentAPIClient(endpoint: activeEndpoint, token: token)
        HostSwitchSignpost.begin("switch_prepare")
        defer { HostSwitchSignpost.end("switch_prepare") }

        async let versionResponse: VersionResponse = Self.retryingIdempotentTransportRequest(
            deadline: deadline
        ) { timeout in
            try await client.version(timeout: timeout)
        }
        async let configResponse: CodexAppServerConfigResponse = Self.retryingIdempotentTransportRequest(
            deadline: deadline
        ) { timeout in
            try await client.appServerConfig(timeout: timeout)
        }

        let (version, config) = try await (versionResponse, configResponse)
        try Task.checkCancellation()
        try version.requireCompatible()
        guard let installationID = Self.normalizedInstallationID(version.installationID) else {
            throw ConnectionProfileError.installationIdentityRequired
        }
        try validateCandidateInstallationIdentity(installationID, target: profileTarget)

        var gatewayAttempt = 0
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.25 else {
                throw URLError(.timedOut)
            }
            let bundle = AppServerRuntimeBundle(
                endpoint: activeEndpoint,
                token: token,
                // 不给 initialize 人为增加最小超时，保证整个快速链路不会突破 8 秒总 deadline。
                requestTimeout: remaining,
                preparedConfig: config
            )
            do {
                try await bundle.prepareForHostActivation()
                try Task.checkCancellation()
                guard deadline.timeIntervalSinceNow > 0 else {
                    throw URLError(.timedOut)
                }

                HostSwitchSignpost.event("gateway_initialized")
                let refreshedDNSName = version.tailscaleDNSName ?? tailscaleDNSName
                let refreshedDeviceName = version.tailscaleDeviceName ?? tailscaleDeviceName
                return PreparedConnectionSettings(
                    endpoint: fallbackEndpoint,
                    activeEndpoint: activeEndpoint,
                    token: token,
                    profileTarget: profileTarget,
                    installationID: installationID,
                    tailscaleDNSName: refreshedDNSName,
                    tailscaleDeviceName: refreshedDeviceName,
                    hostPlatform: HostPlatform(serverValue: version.platform),
                    hostContext: PreparedHostContext(
                        lease: PreparedHostLease(
                            endpoint: activeEndpoint,
                            installationID: installationID,
                            profileTarget: profileTarget,
                            profileRevision: profileRevision(for: profileTarget),
                            tokenFingerprint: Self.tokenFingerprint(token)
                        ),
                        runtimeBundle: bundle,
                        expiresAt: deadline
                    ),
                    capabilityNegotiation: version.capabilityNegotiation
                )
            } catch {
                // 每次失败都先完整退役 candidate；重试时始终只有一条候选业务 WS。
                await bundle.shutdownForHostSwitch()
                guard gatewayAttempt == 0,
                      Self.isRetryableGatewayInitializationError(error),
                      deadline.timeIntervalSinceNow > 0.25 else {
                    throw error
                }
                gatewayAttempt += 1
            }
        }
    }

    private func validateCandidateInstallationIdentity(
        _ installationID: String,
        target: PreparedConnectionProfileTarget
    ) throws {
        switch target {
        case .existingProfile(let id):
            guard let profile = connectionProfiles.first(where: { $0.id == id }) else {
                throw ConnectionProfileError.notFound
            }
            try Self.validateInstallationIdentity(
                actual: installationID,
                expected: profile.installationID,
                profileName: profile.displayName
            )
            try rejectDuplicateInstallation(
                installationID,
                excludingProfileID: profile.id
            )
        case .newProfile(let id, _):
            try rejectDuplicateInstallation(installationID, excludingProfileID: id)
        case .currentOrNew:
            if let activeConnectionProfile {
                try Self.validateInstallationIdentity(
                    actual: installationID,
                    expected: activeConnectionProfile.installationID,
                    profileName: activeConnectionProfile.displayName
                )
                try rejectDuplicateInstallation(
                    installationID,
                    excludingProfileID: activeConnectionProfile.id
                )
            } else {
                try rejectDuplicateInstallation(installationID, excludingProfileID: nil)
            }
        }
    }

    private static func retryingIdempotentTransportRequest<T>(
        deadline: Date,
        operation: @escaping (_ timeout: TimeInterval) async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw URLError(.timedOut)
            }
            do {
                return try await operation(min(4, remaining))
            } catch {
                guard attempt == 0,
                      isRetryableTransportError(error),
                      deadline.timeIntervalSinceNow > 0.25 else {
                    throw error
                }
                attempt += 1
            }
        }
    }

    private static func isRetryableTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func isRetryableGatewayInitializationError(_ error: Error) -> Bool {
        if isCredentialInvalidatingError(error) {
            return false
        }
        if isRetryableTransportError(error) {
            return true
        }
        guard let connectionError = error as? CodexAppServerConnectionError else {
            return false
        }
        switch connectionError {
        case .disconnected, .notInitialized, .timeout, .transport, .outcomeUnknown, .decoding:
            return true
        case .duplicateRequestID, .appServer:
            return false
        }
    }

    private func profileRevision(for target: PreparedConnectionProfileTarget) -> UInt64? {
        switch target {
        case .existingProfile(let id), .newProfile(let id, _):
            return connectionProfiles.first(where: { $0.id == id })?.revision
        case .currentOrNew:
            return activeConnectionProfile?.revision
        }
    }

    private static func tokenFingerprint(_ token: String) -> String {
        connectionCredentialFingerprint(token)
    }

    private func rejectDuplicateInstallation(
        _ installationID: String?,
        excludingProfileID: String?
    ) throws {
        guard let installationID,
              let duplicate = connectionProfiles.first(where: {
                  $0.id != excludingProfileID && Self.normalizedInstallationID($0.installationID) == installationID
              }) else {
            return
        }
        throw ConnectionProfileError.duplicateInstallation(profileName: duplicate.displayName)
    }

    static func validateInstallationIdentity(
        actual: String?,
        expected: String?,
        profileName: String
    ) throws {
        guard let expected = normalizedInstallationID(expected) else {
            return
        }
        guard normalizedInstallationID(actual) == expected else {
            throw ConnectionProfileError.installationIdentityMismatch(profileName: profileName)
        }
    }

    private static func normalizedInstallationID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func resolvedHostPlatform(
        _ candidate: HostPlatform,
        fallback: HostPlatform
    ) -> HostPlatform {
        candidate == .unknown ? fallback : candidate
    }

    private static func unboundInstallationID(profileID: String) -> String {
        "unbound:\(profileID)"
    }

    private static func defaultConnectionRouteProbe(
        endpoint: String,
        token: String,
        timeout: TimeInterval
    ) async throws {
        let client = AgentAPIClient(endpoint: endpoint, token: token)
        let config = try await client.appServerConfig(timeout: timeout)
        let runtime = CodexAppServerSessionRuntime(
            endpoint: endpoint,
            token: token,
            requestTimeout: timeout,
            configProvider: { config }
        )
        // 同时验证控制面和 WebSocket，避免 /healthz 可用但真实 Codex 通道不可用时误选该地址。
        try await runtime.validateDirectGateway()
    }

    /// 探测结果只有在 Profile revision 与 installation_id 都未变化时才能刷新可变名称。
    /// DNSName 只改变下一次路由候选，不会合并档案，也不会改写稳定身份。
    @discardableResult
    func refreshConnectionProfileHostMetadata(
        profileID: String,
        expectedRevision: UInt64,
        version: VersionResponse
    ) -> ConnectionProfile? {
        guard let index = connectionProfiles.firstIndex(where: { $0.id == profileID }),
              connectionProfiles[index].revision == expectedRevision,
              ConnectionProfile.isTailscaleIPEndpoint(connectionProfiles[index].endpoint),
              let expectedInstallationID = Self.normalizedInstallationID(
                  connectionProfiles[index].installationID
              ),
              Self.normalizedInstallationID(version.installationID) == expectedInstallationID,
              let dnsName = version.tailscaleDNSName else {
            return nil
        }
        let deviceName = ConnectionProfile.normalizedTailscaleDeviceName(
            version.tailscaleDeviceName,
            dnsName: dnsName
        )
        var updated = connectionProfiles[index]
        let nextDisplayName = updated.isDisplayNameCustomized
            ? updated.displayName
            : (deviceName ?? Self.defaultProfileDisplayName(endpoint: updated.endpoint))
        guard updated.tailscaleDNSName != dnsName ||
                updated.tailscaleDeviceName != deviceName ||
                updated.displayName != nextDisplayName else {
            return updated
        }
        updated.tailscaleDNSName = dnsName
        updated.tailscaleDeviceName = deviceName
        updated.displayName = nextDisplayName
        updated.revision &+= 1

        var nextProfiles = connectionProfiles
        nextProfiles[index] = updated
        if profileID != ephemeralLocalProfileID {
            guard let encoded = try? JSONEncoder().encode(nextProfiles) else {
                return nil
            }
            persistProfiles(encoded)
        }
        connectionProfiles = nextProfiles
        if profileID == activeConnectionProfileID {
            activeHostState = ActiveHostState(
                scope: activeHostState.scope,
                endpoint: activeHostState.endpoint,
                displayName: updated.displayName,
                committedAt: activeHostState.committedAt,
                capabilityNegotiation: activeHostState.capabilityNegotiation
            )
        }
        return updated
    }

    private static func defaultLocalAgentProbe(endpoint: String, timeout: TimeInterval) async throws {
        _ = try await AgentAPIClient(endpoint: endpoint, token: "").health(timeout: timeout)
    }

    private static func defaultLocalAgentPairingClaim(endpoint: String, timeout: TimeInterval) async throws -> String {
        let response = try await AgentAPIClient(endpoint: endpoint, token: "").claimLocalPairing(timeout: timeout)
        let claimedToken = response.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claimedToken.isEmpty else {
            throw PairingLinkError.missingToken
        }
        return claimedToken
    }

    private func connectToLocalAgentWithAutomaticPairing() async throws {
        let timeout = min(routeProbeTimeout, 2)
        let rawClaimedToken = try await localAgentPairingClaim(localAgentEndpoint, timeout)
        let claimedToken = rawClaimedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claimedToken.isEmpty else {
            throw PairingLinkError.missingToken
        }
        // 不信任免鉴权响应中的 endpoint；网络目标始终锁定已探测成功的固定 loopback。
        // 同样走快速候选链路，确保首次本机配对也绑定 installation_id 并复用已初始化 gateway。
        let prepared = try await prepareConnectionSettings(
            endpoint: localAgentEndpoint,
            token: claimedToken,
            profileTarget: .currentOrNew(
                displayName: activeConnectionProfile == nil ? L10n.text("ui.this_mac") : nil
            )
        )
        _ = try await commitConnectionSettings(prepared)
        activateConnectionRoute(.local, endpoint: localAgentEndpoint)
        connectionTermination = nil
        connectionStatus = .connected(ActiveConnectionRoute.local.statusTitle)
        lastError = nil
    }

    private func activateConnectionRoute(_ route: ActiveConnectionRoute, endpoint: String) {
        let normalized = AgentAPIClient.normalizedEndpoint(endpoint)
        if AgentAPIClient.normalizedEndpoint(connectionEndpoint) != normalized {
            resetDirectRuntime()
        }
        activeRouteEndpoint = normalized
        activeConnectionRoute = route
    }

    private func resetConnectionRoute() {
        activeRouteEndpoint = isTailcatExperimentModeEnabled ? tailcatExperimentEndpoint : nil
        activeConnectionRoute = isTailcatExperimentModeEnabled ? .tailcat : .configured
        resetDirectRuntime()
    }

    private func runtimeBundle(endpoint: String, token: String) -> AppServerRuntimeBundle {
        let identity = runtimeIdentity(endpoint: endpoint, token: token)
        if activeRuntimeIdentity == identity, let bundle = activeRuntimeBundle {
            return bundle
        }
        let bundle = AppServerRuntimeBundle(endpoint: endpoint, token: token)
        activeRuntimeIdentity = identity
        activeRuntimeBundle = bundle
        return bundle
    }

    private func runtimeIdentity(endpoint: String, token: String) -> String {
        "\(endpoint)\n\(token)"
    }

    private func resetDirectRuntime() {
        let retiredRuntime = activeRuntimeBundle
        activeRuntimeIdentity = nil
        activeRuntimeBundle = nil
        if let retiredRuntime {
            Task {
                await retiredRuntime.shutdownForHostSwitch()
            }
        }
    }
}
