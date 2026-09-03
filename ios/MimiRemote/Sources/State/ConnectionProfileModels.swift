import Foundation

/// 服务端运行平台的稳定客户端分类。
///
/// agentd 返回 Go 的 `runtime.GOOS`；这里先归一化再持久化，避免 UI 直接依赖服务端字符串，
/// 同时让旧服务端、未来新平台和异常值都安全退回通用电脑图标。
enum HostPlatform: String, Codable, Equatable {
    case apple
    case windows
    case linux
    case unknown

    init(serverValue: String?) {
        let normalized = serverValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "apple", "darwin", "mac", "macos", "osx":
            self = .apple
        case "windows", "win32", "win64":
            self = .windows
        case "linux":
            self = .linux
        default:
            self = .unknown
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(serverValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String? {
        switch self {
        case .apple:
            return "macOS"
        case .windows:
            return "Windows"
        case .linux:
            return "Linux"
        case .unknown:
            return nil
        }
    }

    var iconKind: HostPlatformIconKind {
        switch self {
        case .apple:
            return .apple
        case .windows:
            return .windows11
        case .linux:
            return .linuxTux
        case .unknown:
            return .genericComputer
        }
    }
}

enum HostPlatformIconKind: Equatable {
    case apple
    case windows11
    case linuxTux
    case genericComputer
}

enum ConnectionProfileRoute: String, Codable, Equatable {
    case configured
    case tailcat
}

/// 一台已保存电脑的本地连接档案。
///
/// `id` 是客户端数据隔离命名空间；`installationID` 是 agentd 返回的稳定安装身份；
/// `endpoint` 只是可变路由，不能作为跨电脑数据主键。
struct ConnectionProfile: Codable, Identifiable, Equatable {
    let id: String
    var displayName: String
    var endpoint: String
    var tailscaleDNSName: String?
    var tailscaleDeviceName: String?
    var isDisplayNameCustomized: Bool
    var lastSuccessfulAt: Date?
    var installationID: String?
    var hostPlatform: HostPlatform
    var connectionRoute: ConnectionProfileRoute
    var revision: UInt64

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case endpoint
        case tailscaleDNSName
        case tailscaleDeviceName
        case isDisplayNameCustomized
        case lastSuccessfulAt
        case installationID
        case hostPlatform
        case connectionRoute
        case revision
    }

    init(
        id: String,
        displayName: String,
        endpoint: String,
        tailscaleDNSName: String? = nil,
        tailscaleDeviceName: String? = nil,
        isDisplayNameCustomized: Bool? = nil,
        lastSuccessfulAt: Date?,
        installationID: String? = nil,
        hostPlatform: HostPlatform = .unknown,
        connectionRoute: ConnectionProfileRoute = .configured,
        revision: UInt64 = 0
    ) {
        self.id = id
        let acceptsTailscaleMetadata = Self.isTailscaleIPEndpoint(endpoint)
        let normalizedDNSName = acceptsTailscaleMetadata
            ? Self.normalizedTailscaleDNSName(tailscaleDNSName)
            : nil
        let normalizedDeviceName = acceptsTailscaleMetadata
            ? Self.normalizedTailscaleDeviceName(
                tailscaleDeviceName,
                dnsName: normalizedDNSName
            )
            : nil
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let inferredCustomization = !trimmedDisplayName.isEmpty &&
            trimmedDisplayName != Self.fallbackDisplayName(endpoint: endpoint)
        self.isDisplayNameCustomized = isDisplayNameCustomized ?? inferredCustomization
        self.displayName = self.isDisplayNameCustomized
            ? trimmedDisplayName
            : (normalizedDeviceName ?? Self.fallbackDisplayName(endpoint: endpoint))
        self.endpoint = endpoint
        self.tailscaleDNSName = normalizedDNSName
        self.tailscaleDeviceName = normalizedDeviceName
        self.lastSuccessfulAt = lastSuccessfulAt
        self.installationID = installationID
        self.hostPlatform = hostPlatform
        self.connectionRoute = connectionRoute
        self.revision = revision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let decodedDisplayName = try container.decode(String.self, forKey: .displayName)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        // LAN 档案即使从新版 agentd 的 /api/version 看到名称，也不启用 Tailscale
        // 路由；只有保留了 Tailscale IP 回退地址的档案才接受 MagicDNS 元数据。
        tailscaleDNSName = Self.isTailscaleIPEndpoint(endpoint)
            ? Self.normalizedTailscaleDNSName(
                try container.decodeIfPresent(String.self, forKey: .tailscaleDNSName)
            )
            : nil
        tailscaleDeviceName = Self.isTailscaleIPEndpoint(endpoint)
            ? Self.normalizedTailscaleDeviceName(
                try container.decodeIfPresent(String.self, forKey: .tailscaleDeviceName),
                dnsName: tailscaleDNSName
            )
            : nil
        let trimmedDisplayName = decodedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        isDisplayNameCustomized = try container.decodeIfPresent(
            Bool.self,
            forKey: .isDisplayNameCustomized
        ) ?? (
            !trimmedDisplayName.isEmpty &&
                trimmedDisplayName != Self.fallbackDisplayName(endpoint: endpoint)
        )
        displayName = isDisplayNameCustomized
            ? trimmedDisplayName
            : (tailscaleDeviceName ?? Self.fallbackDisplayName(endpoint: endpoint))
        lastSuccessfulAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulAt)
        installationID = try container.decodeIfPresent(String.self, forKey: .installationID)
        hostPlatform = try container.decodeIfPresent(HostPlatform.self, forKey: .hostPlatform) ?? .unknown
        connectionRoute = try container.decodeIfPresent(ConnectionProfileRoute.self, forKey: .connectionRoute) ?? .configured
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
    }

    /// DNS 路由优先，扫码得到的 IP Endpoint 永远保留为回退地址。
    /// 两者都只是路由候选，不能参与 Profile 身份或数据分区。
    var connectionCandidates: [String] {
        Self.connectionCandidates(endpoint: endpoint, tailscaleDNSName: tailscaleDNSName)
    }

    static func connectionCandidates(endpoint: String, tailscaleDNSName: String?) -> [String] {
        var values: [String] = []
        if let tailscaleDNSName,
           let preferred = Self.endpoint(endpoint, replacingHostWith: tailscaleDNSName) {
            values.append(preferred)
        }
        values.append(endpoint)
        var seen = Set<String>()
        return values.filter {
            seen.insert(AgentAPIClient.normalizedEndpoint($0)).inserted
        }
    }

    var preferredEndpoint: String {
        connectionCandidates.first ?? endpoint
    }

    static func endpoint(_ fallbackEndpoint: String, replacingHostWith dnsName: String?) -> String? {
        guard let dnsName = normalizedTailscaleDNSName(dnsName),
              var components = URLComponents(string: fallbackEndpoint) else {
            return nil
        }
        components.host = dnsName
        guard let candidate = components.url?.absoluteString else {
            return nil
        }
        return try? EndpointTransportPolicy.validatedEndpoint(candidate)
    }

    static func normalizedTailscaleDNSName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard value.count <= 253, value.hasSuffix(".ts.net") else {
            return nil
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, labels.allSatisfy({ label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else {
                return false
            }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else {
            return nil
        }
        return value
    }

    static func normalizedTailscaleDeviceName(_ raw: String?, dnsName: String?) -> String? {
        let derived = dnsName?.split(separator: ".", maxSplits: 1).first.map(String.init)
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, value.count <= 63,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return derived
        }
        return value
    }

    static func isTailscaleIPEndpoint(_ endpoint: String) -> Bool {
        guard let host = URLComponents(string: endpoint)?.host?
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        else {
            return false
        }
        if host.hasPrefix("fd7a:115c:a1e0:") {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            .compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ 0...255 ~= $0 }) else {
            return false
        }
        return octets[0] == 100 && 64...127 ~= octets[1]
    }

    static func fallbackDisplayName(endpoint: String) -> String {
        guard let host = URLComponents(string: endpoint)?.host,
              !host.isEmpty else {
            return L10n.text("ui.my_mac")
        }
        if host == "127.0.0.1" || host == "::1" || host == "localhost" {
            return L10n.text("ui.this_mac")
        }
        return host
    }
}

struct ConnectionProfileSettingsItem: Identifiable, Equatable {
    let profile: ConnectionProfile
    let isCurrent: Bool

    var id: String { profile.id }
    var canSwitch: Bool { !isCurrent }
    var canDelete: Bool { !isCurrent }
}

struct ConnectionProfileSettingsModel: Equatable {
    let current: ConnectionProfileSettingsItem?
    let others: [ConnectionProfileSettingsItem]
    let savedCount: Int

    init(profiles: [ConnectionProfile], activeProfileID: String?) {
        let items = profiles
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastSuccessfulAt ?? .distantPast
                let rhsDate = rhs.lastSuccessfulAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .map { ConnectionProfileSettingsItem(profile: $0, isCurrent: $0.id == activeProfileID) }
        current = items.first(where: \.isCurrent)
        others = items.filter { !$0.isCurrent }
        // 设置概览展示所有已保存设备；当前仍只有一个激活连接。
        savedCount = items.count
    }
}

/// 在自己的另一台设备上复用电脑连接时使用的短期导入链接。
///
/// 格式沿用宿主端已经提供的 `mimiremote://` 协议；区别仅在于已保存档案
/// 持有长期访问码，因此使用 `connect` 路由并通过 `expires_at` 限制 App 的导入窗口。
struct ConnectionTransferLink: Equatable {
    static let validityInterval: TimeInterval = 10 * 60

    let url: URL
    let expiresAt: Date

    init(
        endpoint: String,
        token: String,
        issuedAt: Date = Date(),
        validityInterval: TimeInterval = Self.validityInterval
    ) throws {
        let normalizedEndpoint = try EndpointTransportPolicy.validatedEndpoint(endpoint)
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            throw ConnectionProfileError.missingToken
        }

        let expiresAt = issuedAt.addingTimeInterval(validityInterval)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var components = URLComponents()
        components.scheme = "mimiremote"
        components.host = "connect"
        // 与 agentd 的 url.Values.Encode 输出保持相同字段和稳定顺序，方便跨端排查。
        components.queryItems = [
            URLQueryItem(name: "endpoint", value: normalizedEndpoint),
            URLQueryItem(name: "expires_at", value: formatter.string(from: expiresAt)),
            URLQueryItem(name: "issued_at", value: formatter.string(from: issuedAt)),
            URLQueryItem(name: "token", value: normalizedToken)
        ]
        guard let url = components.url else {
            throw PairingLinkError.unsupportedURL
        }

        self.url = url
        self.expiresAt = expiresAt
    }
}

/// 删除连接凭据前展示的纯值确认模型。
/// 这里只保存目标和文案，不持有删除闭包，确保第一次点击按钮只会进入确认态。
struct ConnectionCredentialRemovalConfirmation: Identifiable, Equatable {
    enum Target: Equatable {
        case current(profileID: String?)
        case savedProfile(profileID: String)
    }

    let target: Target
    let displayName: String?

    static func forgettingCurrent(_ profile: ConnectionProfile?) -> Self {
        Self(
            target: .current(profileID: profile?.id),
            displayName: profile?.displayName
        )
    }

    static func deletingSavedProfile(_ profile: ConnectionProfile) -> Self {
        Self(
            target: .savedProfile(profileID: profile.id),
            displayName: profile.displayName
        )
    }

    var id: String {
        switch target {
        case .current(let profileID):
            return "forget-current:\(profileID ?? "legacy")"
        case .savedProfile(let profileID):
            return "delete-profile:\(profileID)"
        }
    }

    var title: String {
        switch target {
        case .current:
            return L10n.text("ui.forgot_your_current_mac")
        case .savedProfile:
            return L10n.format("ui.delete_value_c193903e", displayName ?? L10n.text("ui.this_mac"))
        }
    }

    var message: String {
        switch target {
        case .current:
            let targetName = displayName.map { "“\($0)”" } ?? L10n.text("ui.current_mac")
            return L10n.format("ui.this_will_delete_value_s_access_code_from", targetName)
        case .savedProfile:
            let targetName = displayName ?? L10n.text("ui.this_mac")
            return L10n.format("ui.this_will_delete_value_s_connection_profile_and", targetName)
        }
    }

    var confirmButtonTitle: String {
        switch target {
        case .current:
            return L10n.text("ui.forget_this_mac")
        case .savedProfile:
            return L10n.text("ui.delete_connection_file")
        }
    }
}

enum ConnectionProfileError: LocalizedError, Equatable {
    case notFound
    case missingToken
    case installationIdentityRequired
    case installationIdentityMismatch(profileName: String)
    case duplicateInstallation(profileName: String)
    case preparedContextExpired
    case preparedContextConsumed
    case preparedContextMismatch
    case cannotDeleteCurrent
    case operationInProgress
    case invalidDisplayName
    case displayNameTooLong(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return L10n.text("ui.the_connection_file_cannot_be_found_for_this")
        case .missingToken:
            return L10n.text("ui.the_access_code_for_this_mac_does_not")
        case .installationIdentityRequired:
            return L10n.text("ui.agentd_version_too_old_for_multi_mac")
        case .installationIdentityMismatch(let profileName):
            return L10n.format("ui.mac_installation_identity_mismatch", profileName)
        case .duplicateInstallation(let profileName):
            return L10n.format("ui.mac_already_saved_as_value", profileName)
        case .preparedContextExpired:
            return L10n.text("ui.prepared_connection_expired")
        case .preparedContextConsumed:
            return L10n.text("ui.prepared_connection_consumed")
        case .preparedContextMismatch:
            return L10n.text("ui.prepared_connection_mismatch")
        case .cannotDeleteCurrent:
            return L10n.text("ui.please_switch_to_another_mac_before_deleting_this")
        case .operationInProgress:
            return L10n.text("ui.another_mac_connection_operation_is_still_in_progress")
        case .invalidDisplayName:
            return L10n.text("ui.mac_name_cannot_be_empty")
        case .displayNameTooLong(let maximum):
            return L10n.format("ui.mac_name_can_be_up_to_value_characters", maximum)
        }
    }
}

enum PreparedConnectionProfileTarget: Equatable {
    case currentOrNew(displayName: String?)
    case newProfile(id: String, displayName: String)
    case existingProfile(id: String)
}

enum PreparedConnectionRoute: Equatable {
    case configured
    case tailcat(address: String)

    var profileRoute: ConnectionProfileRoute {
        switch self {
        case .configured: return .configured
        case .tailcat: return .tailcat
        }
    }
}

/// 已完成目标电脑验证、等待事务提交的值对象。
struct PreparedConnectionSettings: Equatable {
    /// 扫码或手动配置的可恢复地址；配对时通常是 Tailscale IP。
    let endpoint: String
    /// 本次已完成 REST/WebSocket 验证的真实路由，提交后供所有请求复用。
    let activeEndpoint: String
    let route: PreparedConnectionRoute
    let token: String
    let profileTarget: PreparedConnectionProfileTarget
    let validatedAt: Date
    let installationID: String?
    let tailscaleDNSName: String?
    let tailscaleDeviceName: String?
    let hostPlatform: HostPlatform
    let hostContext: PreparedHostContext?
    let capabilityNegotiation: HostCapabilityNegotiation

    init(
        endpoint: String,
        activeEndpoint: String? = nil,
        route: PreparedConnectionRoute = .configured,
        token: String,
        profileTarget: PreparedConnectionProfileTarget = .currentOrNew(displayName: nil),
        validatedAt: Date = Date(),
        installationID: String? = nil,
        tailscaleDNSName: String? = nil,
        tailscaleDeviceName: String? = nil,
        hostPlatform: HostPlatform = .unknown,
        hostContext: PreparedHostContext? = nil,
        capabilityNegotiation: HostCapabilityNegotiation = .notNegotiated
    ) {
        self.endpoint = endpoint
        self.activeEndpoint = activeEndpoint ?? endpoint
        self.route = route
        self.token = token
        self.profileTarget = profileTarget
        self.validatedAt = validatedAt
        self.installationID = installationID
        self.tailscaleDNSName = ConnectionProfile.isTailscaleIPEndpoint(endpoint)
            ? ConnectionProfile.normalizedTailscaleDNSName(tailscaleDNSName)
            : nil
        self.tailscaleDeviceName = ConnectionProfile.isTailscaleIPEndpoint(endpoint)
            ? ConnectionProfile.normalizedTailscaleDeviceName(
                tailscaleDeviceName,
                dnsName: self.tailscaleDNSName
            )
            : nil
        self.hostPlatform = hostPlatform
        self.hostContext = hostContext
        self.capabilityNegotiation = capabilityNegotiation
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.endpoint == rhs.endpoint &&
            lhs.activeEndpoint == rhs.activeEndpoint &&
            lhs.route == rhs.route &&
            lhs.token == rhs.token &&
            lhs.profileTarget == rhs.profileTarget &&
            lhs.validatedAt == rhs.validatedAt &&
            lhs.installationID == rhs.installationID &&
            lhs.tailscaleDNSName == rhs.tailscaleDNSName &&
            lhs.tailscaleDeviceName == rhs.tailscaleDeviceName &&
            lhs.hostPlatform == rhs.hostPlatform &&
            lhs.hostContext === rhs.hostContext &&
            lhs.capabilityNegotiation == rhs.capabilityNegotiation
    }
}
