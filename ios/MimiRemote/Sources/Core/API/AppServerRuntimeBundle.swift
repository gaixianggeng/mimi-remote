import Foundation

/// 会话属于哪个 Runtime 与连接、端点和 Token 无关。AppStore 按连接档案各持有一份，
/// 跨 bundle 重建（回后台清凭据、Tailcat 换端口、切路由）沿用；只用锁保护，可跨 actor 读。
final class AppServerRuntimeRouteStore: @unchecked Sendable {
    private var lock = NSLock()
    private var runtimeBySessionID: [SessionID: String] = [:]

    /// 同一档案换用候选 bundle 时，把旧表已知的路由带进新表（只补缺）。
    func rememberMissing(from other: AppServerRuntimeRouteStore) {
        guard other !== self else { return }
        other.lock.lock()
        let known = other.runtimeBySessionID
        other.lock.unlock()
        lock.lock()
        defer { lock.unlock() }
        for (sessionID, runtime) in known where runtimeBySessionID[sessionID] == nil {
            runtimeBySessionID[sessionID] = runtime
        }
    }

    func removeAll() {
        lock.lock()
        runtimeBySessionID.removeAll()
        lock.unlock()
    }

    /// 用本地已知会话（列表缓存、恢复快照）补齐缺失的路由（#784）。网络学到的路由优先，
    /// 这里不覆盖；provider 与 source 都认不出 Runtime 时跳过，不替未知会话写成 Codex。
    func rememberMissing(_ sessions: [AgentSession]) {
        let knownRuntimes = RuntimeFeatureSupport.knownRuntimeProviderSet
        lock.lock()
        defer { lock.unlock() }
        for session in sessions where runtimeBySessionID[session.id] == nil {
            if let explicit = session.runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
               !explicit.isEmpty {
                runtimeBySessionID[session.id] = CodexAppServerSessionRuntime.normalizedRuntimeProvider(explicit)
                continue
            }
            let source = session.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceRuntime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(source)
            if !source.isEmpty, knownRuntimes.contains(sourceRuntime) {
                runtimeBySessionID[session.id] = sourceRuntime
            }
        }
    }

    func remember(_ session: AgentSession) {
        remember(runtimeProvider: session.runtimeProvider, source: session.source, for: session.id)
    }

    func remember(_ sessions: [AgentSession]) {
        for session in sessions {
            remember(session)
        }
    }

    func remember(_ runtimeProvider: String?, for sessionID: SessionID) {
        let runtime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        lock.lock()
        runtimeBySessionID[sessionID] = runtime.isEmpty ? "codex" : runtime
        lock.unlock()
    }

    func remember(runtimeProvider: String?, source: String?, for sessionID: SessionID) {
        if let explicit = runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            // 显式 provider 即使未知也要保留，让后续请求安全失败，不能误投到 Codex。
            remember(explicit, for: sessionID)
            return
        }
        let sourceRuntime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(source)
        let knownRuntimes = RuntimeFeatureSupport.knownRuntimeProviderSet
        remember(knownRuntimes.contains(sourceRuntime) ? sourceRuntime : "codex", for: sessionID)
    }

    func runtimeProvider(for sessionID: SessionID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return runtimeBySessionID[sessionID]
    }

    func remove(sessionID: SessionID) {
        lock.lock()
        runtimeBySessionID.removeValue(forKey: sessionID)
        lock.unlock()
    }
}

final class AppServerRuntimeBundle {
    /// 原生通道承接的 runtime ID。沿用既有 `deepseek`，不新建 `deepseek-native`，
    /// 以免切断既有路由、收藏与通知身份。
    static let nativeRuntimeProvider = "deepseek"
    static let nativeHarnessProtocol = "harness_native_v1"

    private let appServerRuntimeOrder: [String]
    private let appServerRuntimes: [String: CodexAppServerSessionRuntime]

    var codex: CodexAppServerSessionRuntime {
        appServerRuntimes["codex"]!
    }

    var claude: CodexAppServerSessionRuntime {
        appServerRuntimes["claude"]!
    }

    /// 除主通道 `codex` 外的所有次级运行时（含常驻适配器通道与原生通道占位）。
    var secondaryRuntimeEntries: [(provider: String, runtime: CodexAppServerSessionRuntime?)] {
        var entries: [(provider: String, runtime: CodexAppServerSessionRuntime?)] = appServerRuntimeOrder
            .filter { $0 != "codex" }
            .compactMap { id in
                appServerRuntimes[id].map { (provider: id, runtime: $0) }
            }
        for nativeID in RuntimeFeatureSupport.nativeRuntimeProviders {
            entries.append((provider: nativeID, runtime: nil))
        }
        return entries
    }

    /// 原生 Harness 接缝。正式 App 总是注入；测试可留空，此时 `deepseek` 显式失败，
    /// 不会回退到任何 actor。
    let harness: HarnessSessionClient?
    /// 默认每个 bundle 一份；App 内由 AppStore 传入跨 bundle 沿用的那份（#784）。
    let routes: AppServerRuntimeRouteStore

    init(
        endpoint: String,
        token: String,
        harnessFactory: HarnessSessionClientFactory? = nil,
        routes: AppServerRuntimeRouteStore = AppServerRuntimeRouteStore()
    ) {
        let providers = RuntimeFeatureSupport.appServerRuntimeProviders
        var built: [String: CodexAppServerSessionRuntime] = [:]
        for provider in providers {
            built[provider] = CodexAppServerSessionRuntime(
                endpoint: endpoint,
                token: token,
                runtimeProvider: provider
            )
        }
        appServerRuntimeOrder = providers
        appServerRuntimes = built
        harness = harnessFactory?(endpoint, token)
        self.routes = routes
        installThreadRuntimeOwnerLookup()
    }

    init(
        endpoint: String,
        token: String,
        requestTimeout: TimeInterval = 20,
        preparedConfig: CodexAppServerConfigResponse,
        harnessFactory: HarnessSessionClientFactory? = nil,
        configProvider suppliedConfigProvider: (() async throws -> CodexAppServerConfigResponse)? = nil,
        routes: AppServerRuntimeRouteStore = AppServerRuntimeRouteStore(),
        transportFactory: (() -> CodexAppServerTransport)? = nil
    ) {
        let configProvider = suppliedConfigProvider ?? { preparedConfig }
        let transportFactory = transportFactory ?? { URLSessionCodexAppServerTransport() }
        let providers = RuntimeFeatureSupport.appServerRuntimeProviders
        var built: [String: CodexAppServerSessionRuntime] = [:]
        for provider in providers {
            built[provider] = CodexAppServerSessionRuntime(
                endpoint: endpoint,
                token: token,
                runtimeProvider: provider,
                transportFactory: transportFactory,
                requestTimeout: requestTimeout,
                initialConfig: preparedConfig,
                configProvider: configProvider
            )
        }
        appServerRuntimeOrder = providers
        appServerRuntimes = built
        harness = harnessFactory?(endpoint, token)
        self.routes = routes
        installThreadRuntimeOwnerLookup()
    }

    init(
        codexRuntime: CodexAppServerSessionRuntime,
        claudeRuntime: CodexAppServerSessionRuntime,
        additionalRuntimes: [String: CodexAppServerSessionRuntime] = [:],
        harness: HarnessSessionClient? = nil,
        routes: AppServerRuntimeRouteStore = AppServerRuntimeRouteStore()
    ) {
        var built: [String: CodexAppServerSessionRuntime] = [
            "codex": codexRuntime,
            "claude": claudeRuntime
        ]
        var order = ["codex", "claude"]
        for (rawKey, runtime) in additionalRuntimes {
            let key = CodexAppServerSessionRuntime.normalizedRuntimeProvider(rawKey)
            guard !key.isEmpty else { continue }
            built[key] = runtime
            if !order.contains(key) {
                order.append(key)
            }
        }
        appServerRuntimeOrder = order
        appServerRuntimes = built
        self.harness = harness
        self.routes = routes
        installThreadRuntimeOwnerLookup()
    }

    /// 重新授权翻列表前先问路由表：已知属于另一个 Runtime 的会话不会出现在本通道的列表里（#784）。
    private func installThreadRuntimeOwnerLookup() {
        let routes = routes
        let lookup: @Sendable (SessionID) -> String? = { routes.runtimeProvider(for: $0) }
        let runtimes = Array(appServerRuntimes.values)
        Task {
            for runtime in runtimes {
                await runtime.setThreadRuntimeOwnerLookup(lookup)
            }
        }
    }

    /// 列表级实时更新：所有 Runtime 对没有被页面订阅的会话收到权威快照时交给同一个观察者（#683）。
    func setSessionIndexObserver(_ observer: (@Sendable (AgentSession) -> Void)?) {
        let runtimes = Array(appServerRuntimes.values)
        Task {
            for runtime in runtimes {
                await runtime.setSessionIndexObserver(observer)
            }
        }
    }

    /// 该 provider 是否由原生客户端承接；不是则返回 `nil`。
    func nativeClient(for provider: String?) -> HarnessSessionClient? {
        guard let harness else { return nil }
        let normalized = CodexAppServerSessionRuntime.normalizedRuntimeProvider(provider)
        return normalized == Self.nativeRuntimeProvider ? harness : nil
    }

    func nativeClient(forSessionID sessionID: SessionID) -> HarnessSessionClient? {
        nativeClient(for: routes.runtimeProvider(for: sessionID))
    }

    func runtime(for provider: String?) throws -> CodexAppServerSessionRuntime {
        let normalized = CodexAppServerSessionRuntime.normalizedRuntimeProvider(provider)
        if normalized == Self.nativeRuntimeProvider {
            throw HarnessNativeUnavailableError.routedNatively(runtimeProvider: normalized)
        }
        guard let matched = appServerRuntimes[normalized] else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        return matched
    }

    func runtime(forSessionID sessionID: SessionID) throws -> CodexAppServerSessionRuntime {
        try runtime(for: routes.runtimeProvider(for: sessionID))
    }

    static func preferredAvailableRuntimeProvider(in config: CodexAppServerConfigResponse) -> String? {
        let codexChannel = config.channels.first {
            CodexAppServerSessionRuntime.normalizedRuntimeProvider($0.runtimeID ?? $0.id) == "codex" ||
                CodexAppServerSessionRuntime.normalizedRuntimeProvider($0.provider) == "codex"
        }
        if codexChannel?.gatewayAvailable == true
            || (config.channels.isEmpty && config.runtime.gatewayAvailable) {
            return "codex"
        }
        return config.channels.lazy
            .filter(\.gatewayAvailable)
            .map { CodexAppServerSessionRuntime.normalizedRuntimeProvider($0.runtimeID ?? $0.provider) }
            .first { !$0.isEmpty }
    }

    static func nativeHarnessChannel(
        in config: CodexAppServerConfigResponse
    ) -> CodexAppServerChannelMetadata? {
        config.channels.first {
            CodexAppServerSessionRuntime.normalizedRuntimeProvider($0.runtimeID ?? $0.id)
                == nativeRuntimeProvider
        }
    }

    static func nativeHarnessIsConfigured(
        in config: CodexAppServerConfigResponse
    ) throws -> Bool {
        guard let channel = nativeHarnessChannel(in: config),
              channel.enabled != false else { return false }
        guard channel.type == "harness_native",
              channel.protocolName == nativeHarnessProtocol else {
            throw HarnessNativeUnavailableError.agentdUpgradeRequired
        }
        return channel.gatewayAvailable
    }

    /// 多个 Runtime 共享同一份 channels 快照。记录安装快照时各自丢弃配置的次数，
    /// 任一 Runtime 后来丢过配置（断线、换代、daemon 重载）就说明这份快照不再可信。
    private struct ConfigGeneration: Equatable {
        var sequences: [String: UInt64]

        var isInitialZero: Bool {
            sequences.values.allSatisfy { $0 == 0 }
        }
    }

    private let configLock = NSLock()
    private var sharedConfig: CodexAppServerConfigResponse?
    private var installedGeneration: ConfigGeneration?
    private var configRefreshTask: Task<CodexAppServerConfigResponse, Error>?

    private func currentConfigGeneration() async -> ConfigGeneration {
        var sequences: [String: UInt64] = [:]
        for provider in appServerRuntimeOrder {
            if let runtime = appServerRuntimes[provider] {
                sequences[provider] = await runtime.configInvalidationSequence
            }
        }
        return ConfigGeneration(sequences: sequences)
    }

    private func cachedConfigIfStillValid() async -> CodexAppServerConfigResponse? {
        let generation = await currentConfigGeneration()
        let snapshot = await codex.configSnapshot()
        return configLock.withLock {
            guard let installedGeneration else {
                guard generation.isInitialZero, let snapshot else {
                    return nil
                }
                self.installedGeneration = generation
                sharedConfig = snapshot
                return snapshot
            }
            guard installedGeneration == generation, let sharedConfig else { return nil }
            return sharedConfig
        }
    }

    func currentConfiguration() async throws -> CodexAppServerConfigResponse {
        if let cached = await cachedConfigIfStillValid() { return cached }
        return try await readConfiguration()
    }

    func refreshConfiguration() async throws {
        _ = try await readConfiguration()
    }

    func channelAvailable(runtimeProvider: String) async throws -> Bool {
        Self.channelAvailable(runtimeProvider: runtimeProvider, in: try await currentConfiguration())
    }

    func nativeHarnessConfigured() async throws -> Bool {
        try Self.nativeHarnessIsConfigured(in: try await currentConfiguration())
    }

    static func channelAvailable(
        runtimeProvider raw: String,
        in config: CodexAppServerConfigResponse
    ) -> Bool {
        let runtime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(raw)
        if runtime == "codex" {
            let channel = config.channels.first {
                CodexAppServerSessionRuntime.normalizedRuntimeProvider($0.runtimeID ?? $0.id) == "codex" ||
                    CodexAppServerSessionRuntime.normalizedRuntimeProvider($0.provider) == "codex"
            }
            return channel?.gatewayAvailable
                ?? (config.channels.isEmpty && config.runtime.gatewayAvailable)
        }
        return config.channels.contains { channel in
            (CodexAppServerSessionRuntime.normalizedRuntimeProvider(channel.runtimeID ?? channel.id) == runtime ||
                CodexAppServerSessionRuntime.normalizedRuntimeProvider(channel.provider) == runtime) &&
                channel.gatewayAvailable
        }
    }

    @discardableResult
    func readConfiguration() async throws -> CodexAppServerConfigResponse {
        if let inFlight = configLock.withLock({ configRefreshTask }) {
            return try await inFlight.value
        }
        let basis = await currentConfigGeneration()
        let task = Task { try await codex.ensureConfig(forceRefresh: true) }
        configLock.withLock { configRefreshTask = task }
        let refreshed: CodexAppServerConfigResponse
        do {
            refreshed = try await task.value
        } catch {
            configLock.withLock {
                if configRefreshTask == task { configRefreshTask = nil }
            }
            throw error
        }
        for (provider, runtime) in appServerRuntimes where provider != "codex" {
            await runtime.installConfigSnapshot(refreshed)
        }
        let settled = await currentConfigGeneration() == basis ? basis : nil
        configLock.withLock {
            installedGeneration = settled
            sharedConfig = refreshed
            if configRefreshTask == task { configRefreshTask = nil }
        }
        return refreshed
    }

    func prepareForHostActivation(handshakeTimeout: TimeInterval? = nil) async throws {
        let config = try await currentConfiguration()
        guard let preferred = Self.preferredAvailableRuntimeProvider(in: config) else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        if preferred == Self.nativeRuntimeProvider {
            guard harness != nil else {
                throw HarnessNativeUnavailableError.agentdUpgradeRequired
            }
            guard try Self.nativeHarnessIsConfigured(in: config) else {
                throw HarnessNativeUnavailableError.agentdUpgradeRequired
            }
            return
        }
        try await runtime(for: preferred).prepareForHostActivation(handshakeTimeout: handshakeTimeout)
    }

    func shutdownForHostSwitch() async {
        await harness?.shutdownForHostSwitch()
        for provider in appServerRuntimeOrder {
            if let runtime = appServerRuntimes[provider] {
                await runtime.shutdownForHostSwitch()
            }
        }
    }
}
