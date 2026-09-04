import Foundation
import os

enum PairingLinkError: LocalizedError, Equatable {
    case unsupportedURL
    case missingEndpoint
    case missingToken
    case expired
    case missingTailcatAddress

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return L10n.text("ui.invalid_connection_link")
        case .missingEndpoint:
            return L10n.text("ui.the_link_is_missing_an_address")
        case .missingToken:
            return L10n.text("ui.the_connection_link_is_missing_the_access_code")
        case .expired:
            return L10n.text("ui.the_pairing_qr_code_has_expired")
        case .missingTailcatAddress:
            return L10n.text("ui.tailcat_pairing_address_missing")
        }
    }
}

struct PairingCredentials: Equatable {
    let endpoint: String
    let token: String
    let tailscaleDNSName: String?
    let tailscaleDeviceName: String?

    init(
        endpoint: String,
        token: String,
        tailscaleDNSName: String? = nil,
        tailscaleDeviceName: String? = nil
    ) {
        self.endpoint = endpoint
        self.token = token
        self.tailscaleDNSName = ConnectionProfile.isTailscaleIPEndpoint(endpoint)
            ? ConnectionProfile.normalizedTailscaleDNSName(tailscaleDNSName)
            : nil
        self.tailscaleDeviceName = ConnectionProfile.isTailscaleIPEndpoint(endpoint)
            ? ConnectionProfile.normalizedTailscaleDeviceName(
                tailscaleDeviceName,
                dnsName: self.tailscaleDNSName
            )
            : nil
    }
}

struct PairingTicket: Equatable {
    let endpoint: String
    let issuedAt: String
    let expiresAt: String
    let pairSignature: String

    var claimRequest: PairingClaimRequest {
        PairingClaimRequest(
            endpoint: endpoint,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            pairSignature: pairSignature
        )
    }

    func claimRequest(tailcatClientKey: String) -> PairingClaimRequest {
        PairingClaimRequest(
            endpoint: endpoint,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            pairSignature: pairSignature,
            tailcatClientKey: tailcatClientKey
        )
    }

    func managedClaimRequest(
        tailcatClientKey: String,
        pairingSessionID: String,
        managedPairingGrant: String
    ) -> PairingClaimRequest {
        PairingClaimRequest(
            endpoint: endpoint,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            pairSignature: pairSignature,
            tailcatClientKey: tailcatClientKey,
            managedPairingSessionID: pairingSessionID,
            managedPairingGrant: managedPairingGrant
        )
    }
}

struct TailcatPairingLink: Equatable {
    let ticket: PairingTicket
    let pairAddress: String
    let managedMacInstallationID: String?
    let managedMacTailcatPublicKey: String?

    @MainActor
    static func parse(_ url: URL) throws -> TailcatPairingLink? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let transport = components?.queryItems?.first(where: { $0.name == "transport" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard transport == "tailcat" else { return nil }
        guard let ticket = try AppStore.pairingTicket(from: url) else {
            throw PairingLinkError.unsupportedURL
        }
        let pairAddress = components?.queryItems?
            .first(where: { $0.name == "tailcat_pair_address" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pairAddress.isEmpty else {
            throw PairingLinkError.missingTailcatAddress
        }
        let managedMacInstallationID = components?.queryItems?
            .first(where: { $0.name == "managed_mac_installation_id" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let managedMacTailcatPublicKey = components?.queryItems?
            .first(where: { $0.name == "managed_mac_tailcat_public_key" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasManagedInstallationID = !(managedMacInstallationID ?? "").isEmpty
        let hasManagedPublicKey = !(managedMacTailcatPublicKey ?? "").isEmpty
        guard hasManagedInstallationID == hasManagedPublicKey else {
            throw PairingLinkError.unsupportedURL
        }
        return TailcatPairingLink(
            ticket: ticket,
            pairAddress: pairAddress,
            managedMacInstallationID: hasManagedInstallationID ? managedMacInstallationID : nil,
            managedMacTailcatPublicKey: hasManagedPublicKey ? managedMacTailcatPublicKey : nil
        )
    }
}

struct ConnectionTestStageTiming: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case health
        case version
        case appServerConfig
        case appServerGateway

        var title: String {
            switch self {
            case .health:
                return L10n.text("ui.basic_connectivity")
            case .version:
                return L10n.text("ui.authentication_version")
            case .appServerConfig:
                return L10n.text("ui.gateway_configuration")
            case .appServerGateway:
                return L10n.text("ui.app_server_handshake")
            }
        }

        var detail: String {
            switch self {
            case .health:
                return L10n.text("ui.ipad_to_agentd_healthz")
            case .version:
                return L10n.text("ui.access_api_version_with_token")
            case .appServerConfig:
                return L10n.text("ui.read_mac_side_gateway_configuration")
            case .appServerGateway:
                return "WebSocket + JSON-RPC initialize"
            }
        }
    }

    enum Status: Equatable {
        case succeeded
        case failed(String)

        var isFailed: Bool {
            if case .failed = self {
                return true
            }
            return false
        }
    }

    let kind: Kind
    let durationMillis: Int
    let status: Status

    var id: String {
        kind.rawValue
    }
}

enum ConnectionTestRoute: String, CaseIterable, Codable, Equatable {
    case tailscale
    case tailcat
}

struct ConnectionTestReport: Equatable {
    let route: ConnectionTestRoute
    let startedAt: Date
    let totalMillis: Int
    let stages: [ConnectionTestStageTiming]
    let tailscaleNetworkPath: TailscaleNetworkPathResponse?
    let gatewayDiagnostics: ConnectionTestGatewayDiagnostics?
    let gatewayDiagnosticsError: String?

    init(
        route: ConnectionTestRoute = .tailscale,
        startedAt: Date,
        totalMillis: Int,
        stages: [ConnectionTestStageTiming],
        tailscaleNetworkPath: TailscaleNetworkPathResponse? = nil,
        gatewayDiagnostics: ConnectionTestGatewayDiagnostics? = nil,
        gatewayDiagnosticsError: String? = nil
    ) {
        self.route = route
        self.startedAt = startedAt
        self.totalMillis = totalMillis
        self.stages = stages
        self.tailscaleNetworkPath = tailscaleNetworkPath
        self.gatewayDiagnostics = gatewayDiagnostics
        self.gatewayDiagnosticsError = gatewayDiagnosticsError
    }

    var slowestStage: ConnectionTestStageTiming? {
        stages.max { lhs, rhs in
            lhs.durationMillis < rhs.durationMillis
        }
    }

    var failedStage: ConnectionTestStageTiming? {
        stages.first { $0.status.isFailed }
    }
}

struct ConnectionTestGatewayDiagnostics: Equatable {
    let capturedAt: Date
    let totalConnectionsDelta: Int
    let failedUpstreamDialsDelta: Int
    let activeConnections: Int
    let upstreamDialMillisMax: Int
    let writeBackMillisMax: Int
    let writeToUpstreamMillisMax: Int
    let rpcLatencyMillisMax: Int
    let rpcOutstandingRequests: Int
    let rpcOutstandingMillisMax: Int
    let relatedConnection: RelayGatewayConnectionStats?
    let latestRPC: RelayGatewayRPCSample?
    let hints: [String]

    static func make(
        baseline: RelayDiagnosticsResponse?,
        snapshot: RelayDiagnosticsResponse,
        gatewayStartedAt: Date
    ) -> ConnectionTestGatewayDiagnostics {
        let gateway = snapshot.appServerGateway
        let relatedConnection = Self.relatedGatewayConnection(
            in: gateway,
            gatewayStartedAt: gatewayStartedAt
        )
        return ConnectionTestGatewayDiagnostics(
            capturedAt: snapshot.generatedAt,
            totalConnectionsDelta: max(0, gateway.totalConnections - (baseline?.appServerGateway.totalConnections ?? gateway.totalConnections)),
            failedUpstreamDialsDelta: max(0, gateway.failedUpstreamDials - (baseline?.appServerGateway.failedUpstreamDials ?? gateway.failedUpstreamDials)),
            activeConnections: gateway.activeConnections,
            upstreamDialMillisMax: gateway.upstreamDialMillisMax,
            writeBackMillisMax: gateway.upstreamToClient.writeMillisMax,
            writeToUpstreamMillisMax: gateway.clientToUpstream.writeMillisMax,
            rpcLatencyMillisMax: gateway.rpc.latencyMillisMax,
            rpcOutstandingRequests: gateway.rpc.outstandingRequests,
            rpcOutstandingMillisMax: gateway.rpc.outstandingMillisMax,
            relatedConnection: relatedConnection,
            latestRPC: relatedConnection?.recentRPC.last ?? gateway.recentRPC.last,
            hints: snapshot.hints
        )
    }

    private static func relatedGatewayConnection(
        in gateway: RelayGatewayStats,
        gatewayStartedAt: Date
    ) -> RelayGatewayConnectionStats? {
        // iPad 和 Mac 时钟正常同步时，优先选本次测试窗口内创建的 gateway 连接；若两端时钟偏差，
        // 退回最近 active/recent 连接，保证现场仍能看到 Mac 侧的最新证据。
        let threshold = gatewayStartedAt.addingTimeInterval(-2)
        let candidates = gateway.activeConnectionDetail + gateway.recentConnections
        if let current = candidates
            .filter({ $0.startedAt >= threshold })
            .max(by: { $0.startedAt < $1.startedAt }) {
            return current
        }
        return gateway.activeConnectionDetail.max(by: { $0.startedAt < $1.startedAt })
            ?? gateway.recentConnections.max(by: { $0.startedAt < $1.startedAt })
    }
}

struct ConnectionTestStageStability: Identifiable, Equatable {
    let kind: ConnectionTestStageTiming.Kind
    let sampleCount: Int
    let failureCount: Int
    let minMillis: Int
    let maxMillis: Int
    let averageMillis: Int

    var id: String {
        kind.rawValue
    }

    var spreadMillis: Int {
        max(0, maxMillis - minMillis)
    }
}

typealias ConnectionRouteProbe = (_ endpoint: String, _ token: String, _ timeout: TimeInterval) async throws -> Void
typealias ConnectionRouteVersionProbe = (_ endpoint: String, _ token: String, _ timeout: TimeInterval) async throws -> VersionResponse
typealias LocalAgentProbe = (_ endpoint: String, _ timeout: TimeInterval) async throws -> Void
typealias LocalAgentPairingClaim = (_ endpoint: String, _ timeout: TimeInterval) async throws -> String

extension AppStore {
    static func defaultConnectionRouteVersionProbe(
        endpoint: String,
        token: String,
        timeout: TimeInterval
    ) async throws -> VersionResponse {
        try await AgentAPIClient(endpoint: endpoint, token: token).version(timeout: min(timeout, 2))
    }

    func validateConnectionCandidateIdentityAndRefreshHostMetadata(
        from routeEndpoint: String,
        profileID: String,
        expectedRevision: UInt64,
        expectedInstallationID: String?,
        profileName: String,
        token: String,
        timeout: TimeInterval,
        versionProbe: ConnectionRouteVersionProbe?
    ) async throws {
        let expectedID = expectedInstallationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let expectedID, !expectedID.isEmpty, let versionProbe else { return }
        let version = try await versionProbe(routeEndpoint, token, timeout)
        let actualID = version.installationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let actualID, !actualID.isEmpty else {
            throw ConnectionProfileError.installationIdentityRequired
        }
        guard actualID == expectedID else {
            throw ConnectionProfileError.installationIdentityMismatch(profileName: profileName)
        }
        _ = refreshConnectionProfileHostMetadata(
            profileID: profileID,
            expectedRevision: expectedRevision,
            version: version
        )
    }
}

enum ActiveConnectionRoute: Equatable {
    case configured
    case local
    case tailcat

    var statusTitle: String {
        switch self {
        case .configured:
            return "Tailscale"
        case .local:
            return L10n.text("ui.direct_connection_to_this_machine")
        case .tailcat:
            return L10n.text("ui.tailcat_experiment")
        }
    }
}

struct PreparedHostLease: Equatable {
    let endpoint: String
    let installationID: String
    let profileTarget: PreparedConnectionProfileTarget
    let profileRevision: UInt64?
    let tokenFingerprint: String
}

enum HostCredentialWriteReceipt: Sendable {
    case unchanged
    case inserted
    case replaced(previousToken: String)
}

enum HostConnectionEndpointPolicy {
    static var prefersLocalConnectionByDefault: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        false
#endif
    }

    /// Catalyst 未签名开发包维持既有 loopback 降级；Simulator 仅在 Debug 构建启用，
    /// 确保 TestFlight / App Store 包始终要求可用的系统 Keychain。
    static var allowsDevelopmentEphemeralCredentialFallback: Bool {
#if targetEnvironment(macCatalyst)
        true
#elseif DEBUG && targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    static func isEligibleEphemeralCredentialEndpoint(_ endpoint: String) -> Bool {
        if isLoopbackEndpoint(endpoint) {
            return true
        }
#if DEBUG && targetEnvironment(simulator)
        // Simulator 无法直接访问宿主机 loopback；只放行传输策略已经确认的私网 HTTP，
        // 公网 HTTPS 即使 Keychain 缺 entitlement 也必须失败，避免扩大凭据驻留范围。
        return EndpointTransportPolicy.assess(endpoint).status == .allowedPrivateHTTP
#else
        return false
#endif
    }

    static func isLoopbackEndpoint(_ endpoint: String) -> Bool {
        guard let host = URLComponents(string: endpoint)?.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

/// Keychain 访问串行化到独立 actor。主线程只提交/接收短字符串，不直接参与非当前主机探活的读取。
actor HostCredentialVault {
    private let tokenStore: TokenStore
    private var memoryTokens: [String: String] = [:]

    init(tokenStore: TokenStore) {
        self.tokenStore = tokenStore
    }

    func token(for profileID: String) throws -> String {
        if let cached = memoryTokens[profileID] {
            return cached
        }
        let token = try tokenStore.load(profileID: profileID)
        memoryTokens[profileID] = token
        return token
    }

    /// Keychain 写入与内存缓存必须由同一个 actor 串行提交，避免切换成功后
    /// 一个迟到的 remember/remove Task 把另一台 Mac 的凭据缓存覆盖掉。
    func save(
        _ token: String,
        for profileID: String,
        forcePersistence: Bool = false
    ) throws -> HostCredentialWriteReceipt {
        if !forcePersistence, memoryTokens[profileID] == token {
            // 快速切换读取过目标 Profile 的 Token；未变化时无需再次触发 Keychain I/O。
            return .unchanged
        }
        let previousToken: String
        if !forcePersistence, let cached = memoryTokens[profileID] {
            previousToken = cached
        } else {
            // 临时开发档案转为持久连接时必须重新读取 Keychain，
            // 不能把仅存在于内存的 Token 误判为已经持久化。
            previousToken = try tokenStore.load(profileID: profileID)
        }
        if previousToken == token {
            memoryTokens[profileID] = token
            return .unchanged
        }
        try tokenStore.save(token, profileID: profileID)
        memoryTokens[profileID] = token
        return previousToken.isEmpty ? .inserted : .replaced(previousToken: previousToken)
    }

    /// 未签入 provisioning profile 的 Catalyst / Simulator Debug 包可能无法访问 Keychain。
    /// 受限本地验收连接只保留进程内凭据，重启后必须重新向 agentd 领取。
    func rememberInMemory(_ token: String, for profileID: String) -> HostCredentialWriteReceipt {
        guard let previousToken = memoryTokens.updateValue(token, forKey: profileID) else {
            return .inserted
        }
        return previousToken == token ? .unchanged : .replaced(previousToken: previousToken)
    }

    func rollbackMemory(_ receipt: HostCredentialWriteReceipt, profileID: String) {
        switch receipt {
        case .unchanged:
            return
        case .inserted:
            memoryTokens.removeValue(forKey: profileID)
        case .replaced(let previousToken):
            memoryTokens[profileID] = previousToken
        }
    }

    func forgetMemory(profileID: String) {
        memoryTokens.removeValue(forKey: profileID)
    }

    func rollback(_ receipt: HostCredentialWriteReceipt, profileID: String) throws {
        switch receipt {
        case .unchanged:
            return
        case .inserted:
            try tokenStore.delete(profileID: profileID, allowMissing: true)
            memoryTokens.removeValue(forKey: profileID)
        case .replaced(let previousToken):
            try tokenStore.save(previousToken, profileID: profileID)
            memoryTokens[profileID] = previousToken
        }
    }

    func delete(profileID: String, allowMissing: Bool = true) throws {
        try tokenStore.delete(profileID: profileID, allowMissing: allowMissing)
        memoryTokens.removeValue(forKey: profileID)
    }

    func deleteLegacy(allowMissing: Bool = true) throws {
        try tokenStore.delete(allowMissing: allowMissing)
    }

    func clearMemory() {
        memoryTokens.removeAll(keepingCapacity: false)
    }
}

@MainActor
final class PreparedHostContext {
    let lease: PreparedHostLease
    let expiresAt: Date

    private var runtimeBundle: AppServerRuntimeBundle?
    private var expirationTask: Task<Void, Never>?

    init(
        lease: PreparedHostLease,
        runtimeBundle: AppServerRuntimeBundle,
        expiresAt: Date
    ) {
        self.lease = lease
        self.runtimeBundle = runtimeBundle
        self.expiresAt = expiresAt
        // Task 强持有 context 到 deadline；即使调用方直接丢弃 PreparedConnectionSettings，
        // 候选 Runtime 也会在 8 秒内显式 shutdown，而不是只依赖 deinit。
        expirationTask = Task { [self] in
            let delay = max(0, expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await discard()
        }
    }

    deinit {
        expirationTask?.cancel()
    }

    var isConsumed: Bool {
        runtimeBundle == nil
    }

    func validatedRuntimeBundle(
        matching expectedLease: PreparedHostLease,
        now: Date = Date()
    ) throws -> AppServerRuntimeBundle {
        guard now <= expiresAt else {
            throw ConnectionProfileError.preparedContextExpired
        }
        guard lease == expectedLease else {
            throw ConnectionProfileError.preparedContextMismatch
        }
        guard let runtimeBundle else {
            throw ConnectionProfileError.preparedContextConsumed
        }
        return runtimeBundle
    }

    func markConsumed() {
        expirationTask?.cancel()
        expirationTask = nil
        runtimeBundle = nil
    }

    func discard() async {
        guard let runtimeBundle else {
            return
        }
        expirationTask?.cancel()
        expirationTask = nil
        self.runtimeBundle = nil
        await runtimeBundle.shutdownForHostSwitch()
    }
}

struct HostProbeDescriptor {
    let profileID: String
    let profileRevision: UInt64
    let endpoints: [String]
    let token: String
    let expectedInstallationID: String?

    var endpoint: String {
        endpoints.first ?? ""
    }
}

enum HostSwitchSignpost {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gaixianggeng.mimi",
        category: "HostSwitch"
    )

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    static func begin(_ name: StaticString) {
        os_signpost(.begin, log: log, name: name)
    }

    static func end(_ name: StaticString) {
        os_signpost(.end, log: log, name: name)
    }
}
