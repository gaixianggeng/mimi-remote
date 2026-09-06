import Foundation

struct HealthResponse: Codable {
    let ok: Bool
    let version: String
}

enum ProtocolCompatibilityError: LocalizedError, Equatable {
    case invalidServerMetadata(protocolRevision: Int, minimumClientRevision: Int)
    case serverTooOld(serverRevision: Int, minimumServerRevision: Int)
    case clientTooOld(clientRevision: Int, minimumClientRevision: Int, serverRevision: Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerMetadata(let protocolRevision, let minimumClientRevision):
            return L10n.format(
                "ui.agentd_protocol_metadata_invalid_values",
                protocolRevision,
                minimumClientRevision
            )
        case .serverTooOld(let serverRevision, let minimumServerRevision):
            return L10n.format(
                "ui.agentd_protocol_server_too_old_values",
                serverRevision,
                minimumServerRevision
            )
        case .clientTooOld(let clientRevision, let minimumClientRevision, let serverRevision):
            return L10n.format(
                "ui.agentd_protocol_client_too_old_values",
                serverRevision,
                minimumClientRevision,
                clientRevision
            )
        }
    }
}

struct VersionResponse: Codable {
    let name: String
    let version: String
    let installationID: String?
    let tailscaleDNSName: String?
    let tailscaleDeviceName: String?
    let protocolRevision: Int
    let minimumClientProtocolRevision: Int
    let platform: String?
    let capabilities: [String]
    let capabilityStatuses: [AgentCapabilityStatus]

    init(
        name: String,
        version: String,
        installationID: String? = nil,
        tailscaleDNSName: String? = nil,
        tailscaleDeviceName: String? = nil,
        protocolRevision: Int = MimiProtocolContract.currentRevision,
        minimumClientProtocolRevision: Int = MimiProtocolContract.minimumSupportedClientRevision,
        platform: String? = nil,
        capabilities: [String] = [],
        capabilityStatuses: [AgentCapabilityStatus] = []
    ) {
        self.name = name
        self.version = version
        self.installationID = installationID
        self.tailscaleDNSName = ConnectionProfile.normalizedTailscaleDNSName(tailscaleDNSName)
        self.tailscaleDeviceName = ConnectionProfile.normalizedTailscaleDeviceName(
            tailscaleDeviceName,
            dnsName: self.tailscaleDNSName
        )
        self.protocolRevision = protocolRevision
        self.minimumClientProtocolRevision = minimumClientProtocolRevision
        self.platform = platform
        self.capabilities = capabilities
        self.capabilityStatuses = capabilityStatuses
    }

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case installationID = "installation_id"
        case tailscaleDNSName = "tailscale_dns_name"
        case tailscaleDeviceName = "tailscale_device_name"
        case protocolRevision = "protocol_revision"
        case minimumClientProtocolRevision = "minimum_client_protocol_revision"
        case platform
        case capabilities
        case capabilityStatuses = "capability_statuses"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.version = try container.decode(String.self, forKey: .version)
        self.installationID = try container.decodeIfPresent(String.self, forKey: .installationID)
        self.tailscaleDNSName = ConnectionProfile.normalizedTailscaleDNSName(
            try container.decodeIfPresent(String.self, forKey: .tailscaleDNSName)
        )
        self.tailscaleDeviceName = ConnectionProfile.normalizedTailscaleDeviceName(
            try container.decodeIfPresent(String.self, forKey: .tailscaleDeviceName),
            dnsName: self.tailscaleDNSName
        )
        // revision 1 的旧 agentd 没有版本化字段。按明确记录的上一版窗口解码，
        // 再由 requireCompatible() 判断；不能因纯加法字段缺失让整条连接直接解析失败。
        self.protocolRevision = try container.decodeIfPresent(Int.self, forKey: .protocolRevision)
            ?? MimiProtocolContract.legacyServerRevision
        self.minimumClientProtocolRevision = try container.decodeIfPresent(
            Int.self,
            forKey: .minimumClientProtocolRevision
        ) ?? MimiProtocolContract.minimumSupportedClientRevision
        // 平台字段是纯加法能力；旧服务端缺失时由 HostPlatform 安全降级为通用电脑。
        self.platform = try container.decodeIfPresent(String.self, forKey: .platform)
        // 旧 agentd 没有 capabilities。解码为空集合后由具体功能入口安全隐藏或给出升级提示。
        self.capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        // 状态说明是纯加法字段。未知 state 和未知 capability 保留为字符串，
        // 由当前功能入口 fail-closed 判断，不能让整个版本响应解码失败。
        self.capabilityStatuses = try container.decodeIfPresent(
            [AgentCapabilityStatus].self,
            forKey: .capabilityStatuses
        ) ?? []
    }

    func requireCompatible() throws {
        guard protocolRevision > 0,
              minimumClientProtocolRevision > 0,
              minimumClientProtocolRevision <= protocolRevision else {
            throw ProtocolCompatibilityError.invalidServerMetadata(
                protocolRevision: protocolRevision,
                minimumClientRevision: minimumClientProtocolRevision
            )
        }
        guard protocolRevision >= MimiProtocolContract.minimumSupportedServerRevision else {
            throw ProtocolCompatibilityError.serverTooOld(
                serverRevision: protocolRevision,
                minimumServerRevision: MimiProtocolContract.minimumSupportedServerRevision
            )
        }
        guard minimumClientProtocolRevision <= MimiProtocolContract.currentRevision else {
            throw ProtocolCompatibilityError.clientTooOld(
                clientRevision: MimiProtocolContract.currentRevision,
                minimumClientRevision: minimumClientProtocolRevision,
                serverRevision: protocolRevision
            )
        }
    }

    var capabilityNegotiation: HostCapabilityNegotiation {
        HostCapabilityNegotiation(
            wasNegotiated: true,
            declared: Set(capabilities),
            statuses: capabilityStatuses
        )
    }
}

struct AgentCapabilityStatus: Codable, Equatable, Sendable {
    let name: String
    let state: String
    let reason: String

    init(name: String, state: String, reason: String) {
        self.name = name
        self.state = state
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case state
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        state = try container.decode(String.self, forKey: .state)
        // reason 是诊断增强字段。旧服务缺失时保持可解码，再由协商状态决定是否 fail-closed。
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

struct VoiceTranscriptionRequest: Encodable {
    let filename: String
    let contentType: String
    let audioBase64: String
    let language: String?

    enum CodingKeys: String, CodingKey {
        case filename
        case contentType = "content_type"
        case audioBase64 = "audio_base64"
        case language
    }
}

struct VoiceTranscriptionResponse: Decodable, Hashable {
    let text: String
    let model: String
}

struct CodexAppServerConfigResponse: Codable {
    let gatewayWSURL: String
    let runtime: CodexAppServerRuntimeMetadata
    let channels: [CodexAppServerChannelMetadata]
    let projects: [AgentProject]
    let policy: CodexAppServerPolicyMetadata

    enum CodingKeys: String, CodingKey {
        case gatewayWSURL = "gateway_ws_url"
        case runtime
        case channels
        case projects
        case policy
    }

    init(
        gatewayWSURL: String,
        runtime: CodexAppServerRuntimeMetadata,
        channels: [CodexAppServerChannelMetadata] = [],
        projects: [AgentProject],
        policy: CodexAppServerPolicyMetadata
    ) {
        self.gatewayWSURL = gatewayWSURL
        self.runtime = runtime
        self.channels = channels
        self.projects = projects
        self.policy = policy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.gatewayWSURL = try container.decode(String.self, forKey: .gatewayWSURL)
        self.runtime = try container.decode(CodexAppServerRuntimeMetadata.self, forKey: .runtime)
        self.channels = try container.decodeIfPresent([CodexAppServerChannelMetadata].self, forKey: .channels) ?? []
        self.projects = try container.decode([AgentProject].self, forKey: .projects)
        self.policy = try container.decode(CodexAppServerPolicyMetadata.self, forKey: .policy)
    }
}

struct CodexAppServerChannelMetadata: Codable, Hashable, Identifiable {
    let id: String
    let runtimeID: String?
    let title: String
    let provider: String
    let type: String
    let protocolName: String?
    let gatewayWSURL: String
    let gatewayAvailable: Bool
    let managed: Bool
    let experimental: Bool?
    let lifecycle: String?
    let bridge: CodexAppServerChannelBridgeMetadata?
    let methods: [String]?
    let capabilities: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case id
        case runtimeID = "runtime_id"
        case title
        case provider
        case type
        case protocolName = "protocol"
        case gatewayWSURL = "gateway_ws_url"
        case gatewayAvailable = "gateway_available"
        case managed
        case experimental
        case lifecycle
        case bridge
        case methods
        case capabilities
    }
}

struct CodexAppServerChannelBridgeMetadata: Codable, Hashable {
    let name: String?
    let version: String?
    let path: String?
    let status: String?
    let healthy: Bool?
    let lastProbeError: String?

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case path
        case status
        case healthy
        case lastProbeError = "last_probe_error"
    }
}

struct CodexAppServerRuntimeMetadata: Codable, Hashable {
    let type: String
    let transport: String
    let managed: Bool
    let gatewayAvailable: Bool
    let upstreamConfigured: Bool
    let running: Bool
    let initialized: Bool
    let pendingRequests: Int

    enum CodingKeys: String, CodingKey {
        case type
        case transport
        case managed
        case gatewayAvailable = "gateway_available"
        case upstreamConfigured = "upstream_configured"
        case running
        case initialized
        case pendingRequests = "pending_requests"
    }
}

struct CodexAppServerPolicyMetadata: Codable, Hashable {
    let allowedMethods: [String]
    let projectsSource: String

    enum CodingKeys: String, CodingKey {
        case allowedMethods = "allowed_methods"
        case projectsSource = "projects_source"
    }
}

struct RelayDiagnosticsResponse: Decodable, Equatable {
    let generatedAt: Date
    let appServerGateway: RelayGatewayStats
    let hints: [String]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case appServerGateway = "app_server_gateway"
        case hints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        appServerGateway = try container.decode(RelayGatewayStats.self, forKey: .appServerGateway)
        // Go 端空 slice 在部分路径会编码成 null；诊断提示为空时按无提示处理，不影响连接证据解码。
        hints = try container.decodeIfPresent([String].self, forKey: .hints) ?? []
    }
}

struct TailscaleNetworkPathResponse: Decodable, Equatable {
    enum Kind: String, Equatable {
        case direct
        case peerRelay = "peer_relay"
        case derp
        case notTailscale = "not_tailscale"
        case unknown
        case unavailable
    }

    let kind: Kind
    let observedAt: Date
    let relayRegion: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case observedAt = "observed_at"
        case relayRegion = "relay_region"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        // 后端未来增加新链路类型时，旧 App 应降级为“无法判断”，不能让整份测速报告解码失败。
        kind = Kind(rawValue: rawKind) ?? .unknown
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        relayRegion = try container.decodeIfPresent(String.self, forKey: .relayRegion)
    }
}

struct RelayGatewayStats: Decodable, Equatable {
    let totalConnections: Int
    let activeConnections: Int
    let failedUpstreamDials: Int
    let upstreamDialMillisMax: Int
    let clientToUpstream: RelayGatewayDirectionStats
    let upstreamToClient: RelayGatewayDirectionStats
    let rpc: RelayGatewayRPCStats
    let recentConnections: [RelayGatewayConnectionStats]
    let activeConnectionDetail: [RelayGatewayConnectionStats]
    let recentRPC: [RelayGatewayRPCSample]

    enum CodingKeys: String, CodingKey {
        case totalConnections = "total_connections"
        case activeConnections = "active_connections"
        case failedUpstreamDials = "failed_upstream_dials"
        case upstreamDialMillisMax = "upstream_dial_ms_max"
        case clientToUpstream = "client_to_upstream"
        case upstreamToClient = "upstream_to_client"
        case rpc
        case recentConnections = "recent_connections"
        case activeConnectionDetail = "active_connections_detail"
        case recentRPC = "recent_rpc"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalConnections = try container.decode(Int.self, forKey: .totalConnections)
        activeConnections = try container.decode(Int.self, forKey: .activeConnections)
        failedUpstreamDials = try container.decode(Int.self, forKey: .failedUpstreamDials)
        upstreamDialMillisMax = try container.decode(Int.self, forKey: .upstreamDialMillisMax)
        clientToUpstream = try container.decode(RelayGatewayDirectionStats.self, forKey: .clientToUpstream)
        upstreamToClient = try container.decode(RelayGatewayDirectionStats.self, forKey: .upstreamToClient)
        rpc = try container.decode(RelayGatewayRPCStats.self, forKey: .rpc)
        // relay 监控里 nil slice 会以 null 返回；移动端展示时统一当空列表处理。
        recentConnections = try container.decodeIfPresent([RelayGatewayConnectionStats].self, forKey: .recentConnections) ?? []
        activeConnectionDetail = try container.decodeIfPresent([RelayGatewayConnectionStats].self, forKey: .activeConnectionDetail) ?? []
        recentRPC = try container.decodeIfPresent([RelayGatewayRPCSample].self, forKey: .recentRPC) ?? []
    }
}

struct RelayGatewayDirectionStats: Decodable, Equatable {
    let frames: Int
    let bytes: Int
    let writeMillisMax: Int
    let lastWriteMillis: Int
    let lastFrameBytes: Int

    enum CodingKeys: String, CodingKey {
        case frames
        case bytes
        case writeMillisMax = "write_ms_max"
        case lastWriteMillis = "last_write_ms"
        case lastFrameBytes = "last_frame_bytes"
    }
}

struct RelayGatewayRPCStats: Decodable, Equatable {
    let responses: Int
    let latencyMillisMax: Int
    let outstandingRequests: Int
    let outstandingMillisMax: Int

    enum CodingKeys: String, CodingKey {
        case responses
        case latencyMillisMax = "latency_ms_max"
        case outstandingRequests = "outstanding_requests"
        case outstandingMillisMax = "outstanding_ms_max"
    }
}

struct RelayGatewayConnectionStats: Decodable, Equatable, Identifiable {
    let id: String
    let startedAt: Date
    let endedAt: Date?
    let durationMillis: Int
    let upstreamDialMillis: Int
    let closeReason: String?
    let clientToUpstream: RelayGatewayDirectionStats
    let upstreamToClient: RelayGatewayDirectionStats
    let rpc: RelayGatewayRPCStats
    let recentRPC: [RelayGatewayRPCSample]
    let lastClientMethod: String?
    let lastUpstreamMethod: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMillis = "duration_ms"
        case upstreamDialMillis = "upstream_dial_ms"
        case closeReason = "close_reason"
        case clientToUpstream = "client_to_upstream"
        case upstreamToClient = "upstream_to_client"
        case rpc
        case recentRPC = "recent_rpc"
        case lastClientMethod = "last_client_method"
        case lastUpstreamMethod = "last_upstream_method"
    }

    init(
        id: String,
        startedAt: Date,
        endedAt: Date?,
        durationMillis: Int,
        upstreamDialMillis: Int,
        closeReason: String?,
        clientToUpstream: RelayGatewayDirectionStats,
        upstreamToClient: RelayGatewayDirectionStats,
        rpc: RelayGatewayRPCStats,
        recentRPC: [RelayGatewayRPCSample],
        lastClientMethod: String?,
        lastUpstreamMethod: String?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMillis = durationMillis
        self.upstreamDialMillis = upstreamDialMillis
        self.closeReason = closeReason
        self.clientToUpstream = clientToUpstream
        self.upstreamToClient = upstreamToClient
        self.rpc = rpc
        self.recentRPC = recentRPC
        self.lastClientMethod = lastClientMethod
        self.lastUpstreamMethod = lastUpstreamMethod
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        self.durationMillis = try container.decode(Int.self, forKey: .durationMillis)
        self.upstreamDialMillis = try container.decode(Int.self, forKey: .upstreamDialMillis)
        self.closeReason = try container.decodeIfPresent(String.self, forKey: .closeReason)
        self.clientToUpstream = try container.decode(RelayGatewayDirectionStats.self, forKey: .clientToUpstream)
        self.upstreamToClient = try container.decode(RelayGatewayDirectionStats.self, forKey: .upstreamToClient)
        self.rpc = try container.decode(RelayGatewayRPCStats.self, forKey: .rpc)
        self.recentRPC = try container.decodeIfPresent([RelayGatewayRPCSample].self, forKey: .recentRPC) ?? []
        self.lastClientMethod = try container.decodeIfPresent(String.self, forKey: .lastClientMethod)
        self.lastUpstreamMethod = try container.decodeIfPresent(String.self, forKey: .lastUpstreamMethod)
    }
}

struct RelayGatewayRPCSample: Decodable, Equatable, Identifiable {
    let completedAt: Date
    let method: String
    let latencyMillis: Int
    let requestBytes: Int
    let responseBytes: Int
    let outstanding: Bool?
    let outstandingForMillis: Int?

    var id: String {
        "\(completedAt.timeIntervalSince1970)-\(method)-\(latencyMillis)"
    }

    enum CodingKeys: String, CodingKey {
        case completedAt = "completed_at"
        case method
        case latencyMillis = "latency_ms"
        case requestBytes = "request_bytes"
        case responseBytes = "response_bytes"
        case outstanding
        case outstandingForMillis = "outstanding_for_ms"
    }
}

struct CapabilityListRequest: Encodable {
    let path: String?
}

struct CapabilityListResponse: Codable, Hashable {
    let path: String?
    let skills: [SkillCapability]
    let mcpServers: [MCPCapability]
    let plugins: [CodexPluginCapability]

    enum CodingKeys: String, CodingKey {
        case path
        case skills
        case mcpServers = "mcp_servers"
        case plugins
    }

    init(
        path: String?,
        skills: [SkillCapability],
        mcpServers: [MCPCapability],
        plugins: [CodexPluginCapability] = []
    ) {
        self.path = path
        self.skills = skills
        self.mcpServers = mcpServers
        self.plugins = plugins
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        skills = try container.decodeIfPresent([SkillCapability].self, forKey: .skills) ?? []
        mcpServers = try container.decodeIfPresent([MCPCapability].self, forKey: .mcpServers) ?? []
        // 旧版 agentd 没有 plugins 字段；解码为空数组即可平滑兼容，不能让整个能力页失效。
        plugins = try container.decodeIfPresent([CodexPluginCapability].self, forKey: .plugins) ?? []
    }
}

struct CodexPluginCapability: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let marketplace: String
    let enabled: Bool
    let installed: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case marketplace
        case enabled
        case installed
    }

    init(
        id: String,
        name: String,
        description: String? = nil,
        marketplace: String = "",
        enabled: Bool = true,
        installed: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.marketplace = marketplace
        self.enabled = enabled
        self.installed = installed
    }

    var presentationName: String {
        name
    }

    static func parseAppServerInstalledResult(_ result: CodexAppServerJSONValue?) -> [CodexPluginCapability] {
        guard let marketplaces = result?.objectValue?["marketplaces"]?.arrayValue else {
            return []
        }
        var seenIDs: Set<String> = []
        return marketplaces.flatMap { marketplaceValue -> [CodexPluginCapability] in
            guard let marketplace = marketplaceValue.objectValue else { return [] }
            let marketplaceName = marketplace["interface"]?.objectValue?["displayName"]?.stringValue
                ?? marketplace["name"]?.stringValue
                ?? ""
            return marketplace["plugins"]?.arrayValue?.compactMap { pluginValue in
                guard let object = pluginValue.objectValue,
                      let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty,
                      !seenIDs.contains(id),
                      let fallbackName = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !fallbackName.isEmpty
                else {
                    return nil
                }
                let interface = object["interface"]?.objectValue
                let displayName = interface?["displayName"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
                    ?? fallbackName
                seenIDs.insert(id)
                return CodexPluginCapability(
                    id: id,
                    name: displayName,
                    description: interface?["shortDescription"]?.stringValue
                        ?? interface?["longDescription"]?.stringValue,
                    marketplace: marketplaceName,
                    enabled: object["enabled"]?.boolValue ?? true,
                    installed: object["installed"]?.boolValue ?? false
                )
            } ?? []
        }
        .filter(\.installed)
        .sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled {
                return lhs.enabled && !rhs.enabled
            }
            return lhs.presentationName.localizedStandardCompare(rhs.presentationName) == .orderedAscending
        }
    }
}

struct SkillCapability: Codable, Hashable, Identifiable {
    let name: String
    let description: String?
    let scope: String
    let path: String
    let enabled: Bool
    let displayName: String?
    let shortDescription: String?
    let iconSmall: String?
    let iconLarge: String?
    let brandColor: String?

    init(
        name: String,
        description: String?,
        scope: String,
        path: String,
        enabled: Bool,
        displayName: String? = nil,
        shortDescription: String? = nil,
        iconSmall: String? = nil,
        iconLarge: String? = nil,
        brandColor: String? = nil
    ) {
        self.name = name
        self.description = description
        self.scope = scope
        self.path = path
        self.enabled = enabled
        self.displayName = displayName
        self.shortDescription = shortDescription
        self.iconSmall = iconSmall
        self.iconLarge = iconLarge
        self.brandColor = brandColor
    }

    var id: String { path }

    var presentationName: String {
        displayName?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty ?? name
    }

    var presentationDescription: String? {
        shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
            ?? description?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
    }

    static func parseAppServerListResult(_ result: CodexAppServerJSONValue?, cwd: String) -> [SkillCapability] {
        guard let entries = result?.objectValue?["data"]?.arrayValue else {
            return []
        }
        let normalizedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingEntries = entries.filter { entry in
            guard let entryCWD = entry.objectValue?["cwd"]?.stringValue else {
                return false
            }
            // cwd 属于远端宿主；只比较清理空白后的原始字符串，不能让 iOS 改写 Windows 路径。
            return entryCWD.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCWD
        }
        let sourceEntries = matchingEntries.isEmpty ? entries : matchingEntries
        var seenPaths: Set<String> = []
        return sourceEntries
            .flatMap { $0.objectValue?["skills"]?.arrayValue ?? [] }
            .compactMap { value in
                guard let object = value.objectValue,
                      let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty,
                      let path = object["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty,
                      !seenPaths.contains(path)
                else {
                    return nil
                }
                seenPaths.insert(path)
                let interface = object["interface"]?.objectValue
                return SkillCapability(
                    name: name,
                    description: object["description"]?.stringValue,
                    scope: object["scope"]?.stringValue ?? "repo",
                    path: path,
                    enabled: object["enabled"]?.boolValue ?? true,
                    displayName: interface?["displayName"]?.stringValue,
                    shortDescription: interface?["shortDescription"]?.stringValue
                        ?? object["shortDescription"]?.stringValue,
                    iconSmall: interface?["iconSmall"]?.stringValue,
                    iconLarge: interface?["iconLarge"]?.stringValue,
                    brandColor: interface?["brandColor"]?.stringValue
                )
            }
            .sorted { lhs, rhs in
                lhs.presentationName.localizedStandardCompare(rhs.presentationName) == .orderedAscending
            }
    }
}

struct MCPCapability: Codable, Hashable, Identifiable {
    let name: String
    let scope: String
    let configPath: String
    let transport: String?
    let command: String?
    let url: String?
    let enabled: Bool
    let plugin: String?
    let status: String?
    let statusNote: String?

    var id: String {
        "\(configPath)#\(plugin ?? "")#\(name)"
    }

    enum CodingKeys: String, CodingKey {
        case name
        case scope
        case configPath = "config_path"
        case transport
        case command
        case url
        case enabled
        case plugin
        case status
        case statusNote = "status_note"
    }

    init(
        name: String,
        scope: String,
        configPath: String,
        transport: String?,
        command: String?,
        url: String?,
        enabled: Bool,
        plugin: String?,
        status: String? = nil,
        statusNote: String? = nil
    ) {
        self.name = name
        self.scope = scope
        self.configPath = configPath
        self.transport = transport
        self.command = command
        self.url = url
        self.enabled = enabled
        self.plugin = plugin
        self.status = status
        self.statusNote = statusNote
    }
}

struct ProjectsResponse: Codable {
    let projects: [AgentProject]
}

struct WorkspaceResolveRequest: Encodable {
    let path: String
}

struct WorkspaceResolveResponse: Codable {
    let workspace: AgentWorkspace
}

struct WorktreeCreateRequest: Encodable {
    let path: String
    let name: String?
    let base: String?
    let branch: String?
}

struct WorktreeBranchListRequest: Encodable {
    let path: String
}

struct WorktreeBranchListResponse: Codable, Hashable {
    let path: String
    let defaultBase: String?
    let currentBranch: String?
    let branches: [WorktreeBranchItem]

    enum CodingKeys: String, CodingKey {
        case path
        case defaultBase = "default_base"
        case currentBranch = "current_branch"
        case branches
    }
}

struct WorktreeBranchItem: Codable, Hashable, Identifiable {
    let name: String
    let kind: String
    let isCurrent: Bool
    let isDefault: Bool

    var id: String { "\(kind):\(name)" }

    enum CodingKeys: String, CodingKey {
        case name
        case kind
        case isCurrent = "is_current"
        case isDefault = "is_default"
    }

    init(name: String, kind: String, isCurrent: Bool = false, isDefault: Bool = false) {
        self.name = name
        self.kind = kind
        self.isCurrent = isCurrent
        self.isDefault = isDefault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(String.self, forKey: .kind)
        isCurrent = try container.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

struct WorktreeListResponse: Codable {
    let worktrees: [WorktreeListItem]
}

struct WorktreeListItem: Codable, Hashable, Identifiable {
    let workspace: AgentWorkspace
    let worktree: WorktreeDescriptor

    var id: String { workspace.id }
}

struct WorktreeDeleteRequest: Encodable {
    let path: String
    let force: Bool
}

struct WorktreeDeleteResponse: Codable {
    let deletedPath: String
    let worktrees: [WorktreeListItem]
    let workspace: AgentWorkspace?
    let worktree: WorktreeDescriptor?
    let registryCleanupError: String?

    init(
        deletedPath: String,
        worktrees: [WorktreeListItem],
        workspace: AgentWorkspace?,
        worktree: WorktreeDescriptor?,
        registryCleanupError: String? = nil
    ) {
        self.deletedPath = deletedPath
        self.worktrees = worktrees
        self.workspace = workspace
        self.worktree = worktree
        self.registryCleanupError = registryCleanupError
    }

    enum CodingKeys: String, CodingKey {
        case deletedPath = "deleted_path"
        case worktrees
        case workspace
        case worktree
        case registryCleanupError = "registry_cleanup_error"
    }
}

struct WorktreePruneResponse: Codable {
    let prunedPaths: [String]
    let worktrees: [WorktreeListItem]
    let failedPaths: [String: String]?

    init(
        prunedPaths: [String],
        worktrees: [WorktreeListItem],
        failedPaths: [String: String]? = nil
    ) {
        self.prunedPaths = prunedPaths
        self.worktrees = worktrees
        self.failedPaths = failedPaths
    }

    enum CodingKeys: String, CodingKey {
        case prunedPaths = "pruned_paths"
        case worktrees
        case failedPaths = "failed_paths"
    }
}

struct WorktreeCleanupRequest: Encodable, Equatable {
    let dryRun: Bool?
    let confirm: Bool?
    let paths: [String]?
    let planID: String?

    // dry_run 缺省即为 true，预览请求保持空对象，避免客户端复制服务端策略默认值。
    static let preview = WorktreeCleanupRequest(dryRun: nil, confirm: nil, paths: nil, planID: nil)

    static func confirmed(paths: [String], planID: String) -> WorktreeCleanupRequest {
        WorktreeCleanupRequest(dryRun: false, confirm: true, paths: paths, planID: planID)
    }

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case confirm
        case paths
        case planID = "plan_id"
    }
}

struct WorktreeCleanupPolicy: Codable, Equatable {
    let autoDelete: Bool
    let candidateAfterDays: Int
    let keepLatestPerProject: Int

    enum CodingKeys: String, CodingKey {
        case autoDelete = "auto_delete"
        case candidateAfterDays = "candidate_after_days"
        case keepLatestPerProject = "keep_latest_per_project"
    }
}

struct WorktreeCleanupBlocker: Codable, Equatable, Hashable, Identifiable, RawRepresentable {
    let rawValue: String

    var id: String { rawValue }
    var code: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var message: String {
        switch rawValue {
        case "metadata_incomplete":
            return L10n.text("ui.management_metadata_is_incomplete")
        case "outside_managed_root":
            return L10n.text("ui.not_within_the_checkout_directory_hosted_by_agentd")
        case "checkout_missing":
            return L10n.text("ui.checkout_no_longer_exists_please_use_clear_lost")
        case "repository_mismatch":
            return L10n.text("ui.checkout_does_not_match_the_registered_git_repository")
        case "recent":
            return L10n.text("ui.still_used_in_the_last_30_days")
        case "keep_latest":
            return L10n.text("ui.belongs_to_the_most_recently_reserved_worktree_for")
        case "git_dirty":
            return L10n.text("ui.contains_uncommitted_changes")
        case "git_state_unknown":
            return L10n.text("ui.unable_to_confirm_git_status_is_clean")
        case "session_running":
            return L10n.text("ui.there_are_still_sessions_running")
        case "root_project_missing":
            return L10n.text("ui.the_root_project_is_no_longer_in_the")
        case "last_used_unpersisted":
            return L10n.text("ui.recent_usage_time_has_not_been_reliably_saved")
        default:
            // 新版 agentd 增加 blocker 时保持 fail-closed，并把稳定 code 留给排障。
            return L10n.text("ui.agentd_returned_a_new_protection_reason")
        }
    }
}

struct WorktreeCleanupItem: Codable, Equatable, Identifiable {
    let workspace: AgentWorkspace
    let worktree: WorktreeDescriptor
    let createdAt: Date?
    let lastUsedAt: Date?
    let eligible: Bool
    let blockers: [WorktreeCleanupBlocker]

    var id: String { worktree.path }

    enum CodingKeys: String, CodingKey {
        case workspace
        case worktree
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case eligible
        case blockers
    }
}

struct WorktreeCleanupResponse: Decodable, Equatable {
    let dryRun: Bool
    let planID: String?
    let policy: WorktreeCleanupPolicy
    let generatedAt: Date
    let worktrees: [WorktreeCleanupItem]
    let candidatePaths: [String]
    let deletedPaths: [String]
    let failedPath: String?
    let error: String?

    var hasPartialFailure: Bool {
        failedPath?.isEmpty == false || error?.isEmpty == false
    }

    var partialFailureMessage: String? {
        guard hasPartialFailure else {
            return nil
        }
        let target = failedPath.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("ui.unknown_path")
        let detail = error.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("ui.agentd_did_not_return_detailed_reasons")
        return L10n.format(
            "ui.worktree_cleanup_partial_failure",
            L10n.plural("ui.worktrees_deleted_count", count: deletedPaths.count),
            target,
            detail
        )
    }

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case planID = "plan_id"
        case policy
        case generatedAt = "generated_at"
        case worktrees
        case candidatePaths = "candidate_paths"
        case deletedPaths = "deleted_paths"
        case failedPath = "failed_path"
        case error
    }
}

struct WorktreeCreateResponse: Codable {
    let workspace: AgentWorkspace
    let worktree: WorktreeDescriptor
}

struct WorktreeDescriptor: Codable, Hashable {
    let path: String
    let repositoryPath: String
    let base: String
    let branch: String?
    let gitState: String
    let dirty: Bool
    let ahead: Int
    let behind: Int
    let upstream: String?
    let rootProjectID: String
    let rootProjectName: String
    let rootProjectPath: String

    enum CodingKeys: String, CodingKey {
        case path
        case repositoryPath = "repository_path"
        case base
        case branch
        case gitState = "git_state"
        case dirty
        case ahead
        case behind
        case upstream
        case rootProjectID = "root_project_id"
        case rootProjectName = "root_project_name"
        case rootProjectPath = "root_project_path"
    }

    init(
        path: String,
        repositoryPath: String,
        base: String,
        branch: String?,
        gitState: String = "unknown",
        dirty: Bool = false,
        ahead: Int = 0,
        behind: Int = 0,
        upstream: String? = nil,
        rootProjectID: String,
        rootProjectName: String,
        rootProjectPath: String
    ) {
        self.path = path
        self.repositoryPath = repositoryPath
        self.base = base
        self.branch = branch
        self.gitState = gitState
        self.dirty = dirty
        self.ahead = ahead
        self.behind = behind
        self.upstream = upstream
        self.rootProjectID = rootProjectID
        self.rootProjectName = rootProjectName
        self.rootProjectPath = rootProjectPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        repositoryPath = try container.decode(String.self, forKey: .repositoryPath)
        base = try container.decode(String.self, forKey: .base)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        dirty = try container.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
        // 旧 agentd 没有 git_state，不能把缺失字段和 dirty=false 当成“已证明干净”。
        gitState = try container.decodeIfPresent(String.self, forKey: .gitState)
            ?? (dirty ? "dirty" : "unknown")
        ahead = try container.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        behind = try container.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        rootProjectID = try container.decode(String.self, forKey: .rootProjectID)
        rootProjectName = try container.decode(String.self, forKey: .rootProjectName)
        rootProjectPath = try container.decode(String.self, forKey: .rootProjectPath)
    }
}

struct DirectoryListRequest: Encodable {
    let path: String
}

struct DirectoryEntry: Codable, Hashable, Identifiable {
    let name: String
    let path: String
    let isDir: Bool
    let canOpen: Bool
    let canBrowse: Bool
    let canPreview: Bool

    var id: String { path }
    var isPreviewable: Bool { canPreview }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case isDir = "is_dir"
        case canOpen = "can_open"
        case canBrowse = "can_browse"
        case canPreview = "can_preview"
    }

    init(name: String, path: String, isDir: Bool, canOpen: Bool, canBrowse: Bool, canPreview: Bool = false) {
        self.name = name
        self.path = path
        self.isDir = isDir
        self.canOpen = canOpen
        self.canBrowse = canBrowse
        self.canPreview = canPreview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        isDir = try container.decode(Bool.self, forKey: .isDir)
        canOpen = try container.decode(Bool.self, forKey: .canOpen)
        canBrowse = try container.decode(Bool.self, forKey: .canBrowse)
        canPreview = try container.decodeIfPresent(Bool.self, forKey: .canPreview) ?? false
    }
}

struct DirectoryListResponse: Codable, Hashable {
    let path: String
    let parentPath: String?
    let entries: [DirectoryEntry]
    let truncated: Bool?

    enum CodingKeys: String, CodingKey {
        case path
        case parentPath = "parent_path"
        case entries
        case truncated
    }
}

struct FileReadRequest: Encodable {
    let path: String
}

struct FileReadResponse: Codable, Hashable {
    let path: String
    let name: String
    let contentType: String
    let size: Int64
    let contentBase64: String

    enum CodingKeys: String, CodingKey {
        case path
        case name
        case contentType = "content_type"
        case size
        case contentBase64 = "content_base64"
    }
}

struct CommandActionListRequest: Encodable {
    let path: String
}

struct CommandActionRunRequest: Encodable {
    let path: String
    let id: String
    let confirmed: Bool
}

struct PairingClaimRequest: Encodable, Equatable {
    let endpoint: String
    let issuedAt: String
    let expiresAt: String
    let pairSignature: String
    let tailcatClientKey: String?
    let managedPairingSessionID: String?
    let managedPairingGrant: String?

    init(
        endpoint: String,
        issuedAt: String,
        expiresAt: String,
        pairSignature: String,
        tailcatClientKey: String? = nil,
        managedPairingSessionID: String? = nil,
        managedPairingGrant: String? = nil
    ) {
        self.endpoint = endpoint
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.pairSignature = pairSignature
        self.tailcatClientKey = tailcatClientKey
        self.managedPairingSessionID = managedPairingSessionID
        self.managedPairingGrant = managedPairingGrant
    }

    enum CodingKeys: String, CodingKey {
        case endpoint
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case pairSignature = "pair_sig"
        case tailcatClientKey = "tailcat_client_key"
        case managedPairingSessionID = "managed_pairing_session_id"
        case managedPairingGrant = "managed_pairing_grant"
    }
}

struct PairingClaimResponse: Decodable, Equatable {
    let endpoint: String
    let token: String
    let tailscaleDNSName: String?
    let tailscaleDeviceName: String?
    let tailcatAddress: String?

    enum CodingKeys: String, CodingKey {
        case endpoint
        case token
        case tailscaleDNSName = "tailscale_dns_name"
        case tailscaleDeviceName = "tailscale_device_name"
        case tailcatAddress = "tailcat_address"
    }
}

struct CommandActionListResponse: Codable, Hashable {
    let path: String
    let actions: [AgentCommandAction]
}

struct AgentCommandAction: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let command: String
    let args: [String]
    let workingDir: String
    let timeoutSeconds: Int
    let requiresConfirmation: Bool

    var displayCommand: String {
        ([command] + args).joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case args
        case workingDir = "working_dir"
        case timeoutSeconds = "timeout_seconds"
        case requiresConfirmation = "requires_confirmation"
    }

    init(id: String, name: String, command: String, args: [String] = [], workingDir: String, timeoutSeconds: Int, requiresConfirmation: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.workingDir = workingDir
        self.timeoutSeconds = timeoutSeconds
        self.requiresConfirmation = requiresConfirmation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        workingDir = try container.decode(String.self, forKey: .workingDir)
        timeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
        requiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? false
    }
}

struct CommandActionRunResponse: Codable, Hashable {
    let id: String
    let name: String
    let path: String
    let workingDir: String
    let command: String
    let args: [String]
    let success: Bool
    let exitCode: Int
    let output: String?
    let truncated: Bool?
    let timedOut: Bool?
    let durationMS: Int64

    var displayCommand: String {
        ([command] + args).joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case workingDir = "working_dir"
        case command
        case args
        case success
        case exitCode = "exit_code"
        case output
        case truncated
        case timedOut = "timed_out"
        case durationMS = "duration_ms"
    }

    init(
        id: String,
        name: String,
        path: String,
        workingDir: String,
        command: String,
        args: [String] = [],
        success: Bool,
        exitCode: Int,
        output: String?,
        truncated: Bool?,
        timedOut: Bool?,
        durationMS: Int64
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.workingDir = workingDir
        self.command = command
        self.args = args
        self.success = success
        self.exitCode = exitCode
        self.output = output
        self.truncated = truncated
        self.timedOut = timedOut
        self.durationMS = durationMS
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        workingDir = try container.decode(String.self, forKey: .workingDir)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        success = try container.decode(Bool.self, forKey: .success)
        exitCode = try container.decode(Int.self, forKey: .exitCode)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated)
        timedOut = try container.decodeIfPresent(Bool.self, forKey: .timedOut)
        durationMS = try container.decode(Int64.self, forKey: .durationMS)
    }
}

struct GitStatusRequest: Encodable {
    let path: String
    let summaryOnly: Bool

    init(path: String, summaryOnly: Bool = false) {
        self.path = path
        self.summaryOnly = summaryOnly
    }

    enum CodingKeys: String, CodingKey {
        case path
        case summaryOnly = "summary_only"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        // 旧版完整状态请求继续只发送 path；只有卡片摘要才显式增加新字段。
        if summaryOnly {
            try container.encode(true, forKey: .summaryOnly)
        }
    }
}

enum GitActionKind: String, Codable, Hashable {
    case stage
    case unstage
    case revert
    case stagePatch = "stage_patch"
    case unstagePatch = "unstage_patch"
    case revertPatch = "revert_patch"
}

struct GitActionRequest: Encodable {
    let path: String
    let action: GitActionKind
    let files: [String]
    let patch: String?

    init(path: String, action: GitActionKind, files: [String] = [], patch: String? = nil) {
        self.path = path
        self.action = action
        self.files = files
        self.patch = patch
    }
}

struct GitCommitRequest: Encodable {
    let path: String
    let message: String
}

struct GitPushRequest: Encodable {
    let path: String
    let remote: String?
}

struct GitQuickPublishRequest: Encodable {
    let path: String
    let message: String
    let remote: String?
    let confirmed: Bool
}

struct GitTestFlightStatusRequest: Encodable {
    let path: String
}

struct GitTestFlightRunRequest: Encodable {
    let path: String
    let whatToTest: String
    let confirmed: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case whatToTest = "what_to_test"
        case confirmed
    }
}

struct GitPullRequestRequest: Encodable {
    let path: String
    let title: String
    let body: String
    let draft: Bool
}

struct GitPullRequestStatusRequest: Encodable {
    let path: String
}

struct GitPushResponse: Codable, Hashable {
    let path: String
    let remote: String
    let branch: String
    let output: String?
    let status: GitStatusResponse
}

struct GitQuickPublishResponse: Codable, Hashable {
    let path: String
    let remote: String
    let branch: String
    let message: String
    let committed: Bool
    let output: String?
    let status: GitStatusResponse
}

struct GitTestFlightCapability: Codable, Hashable {
    let isIOSProject: Bool
    let available: Bool
    let reason: String
    let projectID: String?
    let command: String?

    enum CodingKeys: String, CodingKey {
        case isIOSProject = "is_ios_project"
        case available
        case reason
        case projectID = "project_id"
        case command
    }
}

struct GitTestFlightJob: Codable, Hashable {
    let id: String
    let state: String
    let output: String?
    let truncated: Bool?
    let exitCode: Int?
    let startedAt: String
    let finishedAt: String?

    var isRunning: Bool { state == "running" }
    var succeeded: Bool { state == "succeeded" }

    enum CodingKeys: String, CodingKey {
        case id
        case state
        case output
        case truncated
        case exitCode = "exit_code"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

struct GitTestFlightStatusResponse: Codable, Hashable {
    let path: String
    let capability: GitTestFlightCapability
    let job: GitTestFlightJob?
}

struct GitPullRequestResponse: Codable, Hashable {
    let path: String
    let branch: String
    let url: String?
    let output: String?
}

struct GitPullRequestStatusResponse: Codable, Hashable {
    let path: String
    let branch: String
    let exists: Bool
    let number: Int?
    let title: String?
    let state: String?
    let url: String?
    let isDraft: Bool
    let reviewDecision: String?
    let mergeStateStatus: String?
    let headRefName: String?
    let baseRefName: String?

    enum CodingKeys: String, CodingKey {
        case path
        case branch
        case exists
        case number
        case title
        case state
        case url
        case isDraft = "is_draft"
        case reviewDecision = "review_decision"
        case mergeStateStatus = "merge_state_status"
        case headRefName = "head_ref_name"
        case baseRefName = "base_ref_name"
    }

    init(
        path: String,
        branch: String,
        exists: Bool,
        number: Int? = nil,
        title: String? = nil,
        state: String? = nil,
        url: String? = nil,
        isDraft: Bool = false,
        reviewDecision: String? = nil,
        mergeStateStatus: String? = nil,
        headRefName: String? = nil,
        baseRefName: String? = nil
    ) {
        self.path = path
        self.branch = branch
        self.exists = exists
        self.number = number
        self.title = title
        self.state = state
        self.url = url
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.mergeStateStatus = mergeStateStatus
        self.headRefName = headRefName
        self.baseRefName = baseRefName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        branch = try container.decode(String.self, forKey: .branch)
        exists = try container.decode(Bool.self, forKey: .exists)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        reviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision)
        mergeStateStatus = try container.decodeIfPresent(String.self, forKey: .mergeStateStatus)
        headRefName = try container.decodeIfPresent(String.self, forKey: .headRefName)
        baseRefName = try container.decodeIfPresent(String.self, forKey: .baseRefName)
    }
}

struct GitFileStatus: Codable, Hashable, Identifiable {
    let path: String
    let code: String
    let staged: Bool
    let unstaged: Bool
    let untracked: Bool

    var id: String { path }

    var displayCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "--" : code
    }

    enum CodingKeys: String, CodingKey {
        case path
        case code
        case staged
        case unstaged
        case untracked
    }

    init(path: String, code: String, staged: Bool, unstaged: Bool, untracked: Bool) {
        self.path = path
        self.code = code
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.code = try container.decode(String.self, forKey: .code)
        // Go 的 omitempty 会省略 false；缺失字段按 false 处理，兼容已经部署的 agentd。
        self.staged = try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false
        self.unstaged = try container.decodeIfPresent(Bool.self, forKey: .unstaged) ?? false
        self.untracked = try container.decodeIfPresent(Bool.self, forKey: .untracked) ?? false
    }
}

struct GitStatusResponse: Codable, Hashable {
    let path: String
    let isRepository: Bool
    let branch: String?
    let head: String?
    let ahead: Int?
    let behind: Int?
    let upstream: String?
    let statusText: String?
    let diffStat: String?
    let unstagedDiff: String?
    let stagedDiff: String?
    let files: [GitFileStatus]
    let truncated: Bool?
    let truncatedNote: String?

    var hasChanges: Bool {
        !files.isEmpty || [statusText, diffStat, unstagedDiff, stagedDiff].contains { value in
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    enum CodingKeys: String, CodingKey {
        case path
        case isRepository = "is_repository"
        case branch
        case head
        case ahead
        case behind
        case upstream
        case statusText = "status_text"
        case diffStat = "diff_stat"
        case unstagedDiff = "unstaged_diff"
        case stagedDiff = "staged_diff"
        case files
        case truncated
        case truncatedNote = "truncated_note"
    }

    init(
        path: String,
        isRepository: Bool,
        branch: String?,
        head: String?,
        ahead: Int? = nil,
        behind: Int? = nil,
        upstream: String? = nil,
        statusText: String?,
        diffStat: String?,
        unstagedDiff: String?,
        stagedDiff: String?,
        files: [GitFileStatus] = [],
        truncated: Bool?,
        truncatedNote: String?
    ) {
        self.path = path
        self.isRepository = isRepository
        self.branch = branch
        self.head = head
        self.ahead = ahead
        self.behind = behind
        self.upstream = upstream
        self.statusText = statusText
        self.diffStat = diffStat
        self.unstagedDiff = unstagedDiff
        self.stagedDiff = stagedDiff
        self.files = files
        self.truncated = truncated
        self.truncatedNote = truncatedNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.isRepository = try container.decode(Bool.self, forKey: .isRepository)
        self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
        self.head = try container.decodeIfPresent(String.self, forKey: .head)
        self.ahead = try container.decodeIfPresent(Int.self, forKey: .ahead)
        self.behind = try container.decodeIfPresent(Int.self, forKey: .behind)
        self.upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        self.statusText = try container.decodeIfPresent(String.self, forKey: .statusText)
        self.diffStat = try container.decodeIfPresent(String.self, forKey: .diffStat)
        self.unstagedDiff = try container.decodeIfPresent(String.self, forKey: .unstagedDiff)
        self.stagedDiff = try container.decodeIfPresent(String.self, forKey: .stagedDiff)
        self.files = try container.decodeIfPresent([GitFileStatus].self, forKey: .files) ?? []
        self.truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated)
        self.truncatedNote = try container.decodeIfPresent(String.self, forKey: .truncatedNote)
    }
}
