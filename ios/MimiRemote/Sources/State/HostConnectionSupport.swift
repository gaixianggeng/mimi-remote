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

    /// 解析链接携带的真实到期时间，避免客户端硬编码固定有效期。
    var expiresAtDate: Date? {
        Self.parseTimestamp(expiresAt)
    }

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiry = expiresAtDate else { return true }
        return expiry <= now
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let seconds = TimeInterval(trimmed) {
            return Date(timeIntervalSince1970: seconds)
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: trimmed) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

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

/// 与电脑二维码共用的中转选择。它只表达用户意图，不替代订阅授权。
enum RelayServiceChoice: String, CaseIterable, Identifiable {
    case tailcatDefault = "default"
    case custom
    case mimi

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tailcatDefault: L10n.text("ui.relay_choice_default")
        case .custom: L10n.text("ui.relay_choice_custom")
        case .mimi: L10n.text("ui.relay_choice_mimi")
        }
    }

    var detail: String {
        switch self {
        case .tailcatDefault: L10n.text("ui.relay_choice_default_detail")
        case .custom: L10n.text("ui.relay_choice_custom_detail")
        case .mimi: L10n.text("ui.relay_choice_mimi_detail")
        }
    }

    static func fromPairingURL(_ url: URL) -> RelayServiceChoice? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "transport" })?.value == "tailcat" else { return nil }
        return items.first(where: { $0.name == "relay_service" })?.value.flatMap(Self.init(rawValue:))
    }
}

/// 电脑上选择的中转，以及这台电脑的免费线路是哪一条。
struct ComputerRelayChoice: Equatable {
    let relay: RelayServiceChoice
    let free: RelayServiceChoice?
}

struct TailcatPairingLink: Equatable {
    let ticket: PairingTicket
    let pairAddress: String
    let managedMacInstallationID: String?
    let managedMacTailcatPublicKey: String?
    let managedPairTailcatPublicKey: String?
    /// 托管二维码附带的免费配对节点。没开通的设备走它，旧版电脑的二维码没有这个字段。
    let freePairAddress: String?

    /// 电脑只在托管模式下才写入这三个字段（agentd `tailcat pair`）。带齐了就先走托管授权：
    /// 中继开启准入后，未登记的身份连不上托管的临时配对节点，直接去连只会等到超时。
    var isManagedPairing: Bool {
        managedMacInstallationID != nil && managedMacTailcatPublicKey != nil && managedPairTailcatPublicKey != nil
    }

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
        let managedPairTailcatPublicKey = components?.queryItems?
            .first(where: { $0.name == "managed_pair_tailcat_public_key" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasManagedInstallationID = !(managedMacInstallationID ?? "").isEmpty
        let hasManagedPublicKey = !(managedMacTailcatPublicKey ?? "").isEmpty
        let hasManagedPairPublicKey = !(managedPairTailcatPublicKey ?? "").isEmpty
        guard hasManagedInstallationID == hasManagedPublicKey,
              !hasManagedPairPublicKey || hasManagedInstallationID else {
            throw PairingLinkError.unsupportedURL
        }
        let freePairAddress = components?.queryItems?
            .first(where: { $0.name == "tailcat_free_pair_address" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TailcatPairingLink(
            ticket: ticket,
            pairAddress: pairAddress,
            managedMacInstallationID: hasManagedInstallationID ? managedMacInstallationID : nil,
            managedMacTailcatPublicKey: hasManagedPublicKey ? managedMacTailcatPublicKey : nil,
            managedPairTailcatPublicKey: hasManagedPairPublicKey ? managedPairTailcatPublicKey : nil,
            freePairAddress: (freePairAddress ?? "").isEmpty ? nil : freePairAddress
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
    static func normalizedInstallationID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    static func unboundInstallationID(profileID: String) -> String {
        "unbound:\(profileID)"
    }

    static func defaultConnectionRouteVersionProbe(
        endpoint: String,
        token: String,
        timeout: TimeInterval,
        session: URLSession = .shared
    ) async throws -> VersionResponse {
        try await AgentAPIClient(endpoint: endpoint, token: token, session: session)
            .version(timeout: min(timeout, 2))
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

/// 探测开始前的展示状态；探测被取消时原样放回，不把「没做完」写成「未连接」。
/// revision 与 hostScope 用来确认取消时状态仍归这次探测所有：期间 WebSocket 连上、别的探测
/// 下了结论或切换了电脑，都不能被这份旧快照覆盖。
struct ConnectionProbeSnapshot: Equatable {
    let status: ConnectionStatus
    let lastError: String?
    let revision: UInt64
    let hostScope: HostScope
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

    static func begin(_ name: StaticString, metadata: String) {
        os_signpost(.begin, log: log, name: name, "%{public}@", metadata as NSString)
    }

    static func end(_ name: StaticString) {
        os_signpost(.end, log: log, name: name)
    }

    static func end(_ name: StaticString, metadata: String) {
        os_signpost(.end, log: log, name: name, "%{public}@", metadata as NSString)
    }
}

/// 按连接类型给出失败原因与下一步操作（#349）。
///
/// 底层 `URLError` 或网关握手失败只表达可达性事实；这里结合本次连接尝试或当前档案的
/// `ConnectionProfileRoute` 给出对应连接方式的排查提示，避免局域网或中转连接失败时
/// 误导用户去检查 Tailscale，同时在连接类型未知时给出条件式提示。
@MainActor
enum ConnectionFailureGuidance {
    private static let reachabilityURLErrorCodes: [URLError.Code] = [
        .timedOut,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .internationalRoamingOff,
        .callIsActive,
        .dataNotAllowed,
        .resourceUnavailable,
        .cannotLoadFromNetwork,
    ]

    static func reachabilityGuidance(
        for route: ConnectionProfileRoute?,
        tailcatExperimentEnabled: Bool = false,
        hasActiveMimiEntitlement: Bool = false
    ) -> String {
        switch route {
        case .lan:
            return hasActiveMimiEntitlement
                ? L10n.text("ui.connection_failure_guidance_lan_with_mimi")
                : L10n.text("ui.connection_failure_guidance_lan")
        case .tailscale:
            return L10n.text("ui.the_current_device_cannot_find_this_mac_at")
        case .managedTailcat:
            return L10n.text("ui.connection_failure_guidance_managed_tailcat")
        case .customTailcat:
            return L10n.text("ui.connection_failure_guidance_custom_tailcat")
        case .https:
            return L10n.text("ui.connection_failure_guidance_https")
        case nil:
            if tailcatExperimentEnabled {
                return L10n.text("ui.please_check_mac_assistant_and_network_connections")
            }
            return L10n.text("ui.connection_conditional_tailscale_guidance")
        }
    }

    static func savedCredentialsLoadFailureGuidance(
        for route: ConnectionProfileRoute?,
        tailcatExperimentEnabled: Bool = false
    ) -> String {
        switch route {
        case .lan:
            return L10n.text("ui.connection_credentials_saved_load_failed_lan")
        case .managedTailcat, .customTailcat:
            return L10n.text("ui.connection_credentials_saved_load_failed_tailcat")
        case .https:
            return L10n.text("ui.connection_credentials_saved_load_failed_https")
        case .tailscale:
            return L10n.text("ui.the_connection_credentials_have_been_saved_safely_but")
        case nil:
            if tailcatExperimentEnabled {
                return L10n.text("ui.connection_credentials_saved_load_failed_tailcat")
            }
            return L10n.text("ui.the_connection_credentials_have_been_saved_safely_but")
        }
    }

    static func isReachabilityFailure(_ error: Error) -> Bool {
        if isCancellationError(error) || isCredentialInvalidatingError(error) {
            return false
        }
        if let connectionError = error as? CodexAppServerConnectionError {
            switch connectionError {
            case .disconnected, .timeout:
                return true
            case .transport(let underlying):
                return isReachabilityFailure(underlying)
            default:
                return false
            }
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        return reachabilityURLErrorCodes.contains(URLError.Code(rawValue: nsError.code))
    }

    static func isReachabilityFailureMessage(_ raw: String) -> Bool {
        let reachabilityGuidanceKeys = [
            "ui.connection_failure_guidance_lan",
            "ui.connection_failure_guidance_lan_with_mimi",
            "ui.the_current_device_cannot_find_this_mac_at",
            "ui.connection_failure_guidance_managed_tailcat",
            "ui.connection_failure_guidance_custom_tailcat",
            "ui.connection_failure_guidance_https",
            "ui.connection_conditional_tailscale_guidance",
            "ui.please_check_mac_assistant_and_network_connections",
        ]
        if reachabilityGuidanceKeys.contains(where: { raw == L10n.text($0) }) {
            return true
        }
        if reachabilityURLErrorCodes.contains(where: {
            let localized = URLError($0).localizedDescription
            return !localized.isEmpty && (raw == localized || raw.contains(localized))
        }) {
            return true
        }
        let lowercased = raw.lowercased()
        let englishMarkers = [
            "timed out",
            "cannot connect",
            "could not connect",
            "could not be found",
            "cannot find host",
            "dns lookup",
            "network connection was lost",
            "appears to be offline",
            "not connected to the internet",
            "no route to host",
            "connection refused",
            "network is unreachable",
        ]
        if englishMarkers.contains(where: lowercased.contains) {
            return true
        }
        return raw.contains("无法连接") || raw.contains("超时")
    }

    static func isSavedCredentialsLoadFailureMessage(_ raw: String) -> Bool {
        let keys = [
            "ui.the_connection_credentials_have_been_saved_safely_but",
            "ui.connection_credentials_saved_load_failed_lan",
            "ui.connection_credentials_saved_load_failed_tailcat",
            "ui.connection_credentials_saved_load_failed_https",
        ]
        return keys.contains(where: { raw == L10n.text($0) }) || raw.contains("连接凭据已安全保存")
    }

    static func message(
        for error: Error,
        route: ConnectionProfileRoute?,
        repairPlatform: HostPlatform? = nil,
        tailcatExperimentEnabled: Bool = false,
        hasActiveMimiEntitlement: Bool = false
    ) -> String {
        if let pairingError = error as? PairingOnboardingAPIError {
            if pairingError.code == "pair_ticket_expired", let repairPlatform {
                return repairPlatform.pairingQRCodeExpiredGuidance
            }
            return pairingError.userFacingMessage
        }
        if (error as? PairingLinkError) == .expired {
            return (repairPlatform ?? .unknown).pairingQRCodeExpiredGuidance
        }
        if error is PairingLinkError ||
            error is TailcatPairingError ||
            error is ConnectionProfileError ||
            error is ManagedConnectionDeviceStoreError ||
            error is ManagedConnectionDeviceAPIError {
            return error.localizedDescription
        }
        if isCredentialInvalidatingError(error) {
            return L10n.text("ui.this_device_has_not_been_verified_by_mac")
        }
        if isReachabilityFailure(error) {
            return reachabilityGuidance(
                for: route,
                tailcatExperimentEnabled: tailcatExperimentEnabled,
                hasActiveMimiEntitlement: hasActiveMimiEntitlement
            )
        }
        return friendlyMessage(
            from: error.localizedDescription,
            route: route,
            activeTermination: nil,
            tailcatExperimentEnabled: tailcatExperimentEnabled,
            hasActiveMimiEntitlement: hasActiveMimiEntitlement
        )
    }

    static func friendlyMessage(
        from raw: String,
        route: ConnectionProfileRoute?,
        activeTermination: ConnectionTerminationStatus? = nil,
        tailcatExperimentEnabled: Bool = false,
        hasActiveMimiEntitlement: Bool = false
    ) -> String {
        if let activeTermination {
            return activeTermination.message
        }
        if isSavedCredentialsLoadFailureMessage(raw) {
            return savedCredentialsLoadFailureGuidance(
                for: route,
                tailcatExperimentEnabled: tailcatExperimentEnabled
            )
        }
        if isPreservedUserFacingMessage(raw) {
            return raw
        }
        let lowercased = raw.lowercased()
        if lowercased.contains("expired") || raw.contains("过期") {
            return HostPlatform.unknown.pairingQRCodeExpiredGuidance
        }
        if InitialConnectionErrorClassifier.isCredentialRejection(raw) {
            return L10n.text("ui.this_device_has_not_been_verified_by_mac")
        }
        if isReachabilityFailureMessage(raw) {
            return reachabilityGuidance(
                for: route,
                tailcatExperimentEnabled: tailcatExperimentEnabled,
                hasActiveMimiEntitlement: hasActiveMimiEntitlement
            )
        }
        if raw.contains("连接链接缺少访问码") {
            return L10n.text("ui.the_connection_link_is_missing_the_access_code")
        }
        if raw.contains("连接链接缺少地址") {
            return L10n.text("ui.the_link_is_missing_an_address")
        }
        if raw.contains("连接地址格式无效") {
            return L10n.text("ui.the_connection_address_format_is_invalid")
        }
        if raw.contains("连接地址") || raw.contains("连接链接") {
            return L10n.text("ui.invalid_connection_link")
        }
        return L10n.text("ui.the_connection_was_not_completed_please_confirm_that")
    }

    private static func isPreservedUserFacingMessage(_ raw: String) -> Bool {
        if PairingErrorMapper.isUserFacingMessage(raw) ||
            HostPlatform.isPairingQRCodeExpiredGuidance(raw) ||
            TailcatPairingError.isUserFacingMessage(raw) ||
            ConnectionProfileError.isUserFacingMessage(raw) {
            return true
        }
        let localizedKeys = [
            "ui.clipboard_does_not_contain_connection_info",
            "ui.invalid_connection_link",
            "ui.the_connection_link_is_missing_the_access_code",
            "ui.the_link_is_missing_an_address",
            "ui.the_connection_address_format_is_invalid",
            "ui.the_connection_address_is_invalid_please_enter_the",
            "ui.tailcat_pairing_address_missing",
            "ui.the_current_mac_has_changed_please_try_again",
            "ui.the_native_assistant_was_detected_but_the_automatic",
            "ui.the_code_scan_has_been_cancelled_please_scan",
            "ui.this_device_has_not_been_verified_by_mac",
        ]
        return localizedKeys.contains(where: { raw == L10n.text($0) }) || raw.contains("Endpoint")
    }
}
