import CryptoKit
import Foundation

extension AppStore {
    func setActiveConnectionProfileRoute(_ route: ConnectionProfileRoute) throws {
        guard let profileID = activeConnectionProfileID,
              let index = connectionProfiles.firstIndex(where: { $0.id == profileID }),
              connectionProfiles[index].connectionRoute != route else {
            return
        }
        var nextProfiles = connectionProfiles
        nextProfiles[index].connectionRoute = route
        nextProfiles[index].revision &+= 1
        if profileID != ephemeralLocalProfileID {
            persistProfiles(try JSONEncoder().encode(nextProfiles))
        }
        replaceConnectionProfiles(nextProfiles)
    }

    func prepareConnectionProfileSwitch(id: String) async throws -> PreparedConnectionSettings {
        guard let profile = connectionProfiles.first(where: { $0.id == id }) else {
            throw ConnectionProfileError.notFound
        }
        let profileToken = try await credentialVault.token(for: id)
        guard !profileToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionProfileError.missingToken
        }
        return try await prepareConnectionSettings(
            endpoint: profile.endpoint,
            token: profileToken,
            profileTarget: .existingProfile(id: id),
            tailscaleDNSName: profile.tailscaleDNSName,
            tailscaleDeviceName: profile.tailscaleDeviceName
        )
    }

    /// 先通过 Tailcat 的本机代理完成完整连接验证，同时继续把 Mac 的规范地址写入档案。
    /// 这样关闭实验开关后，现有 Tailscale 地址可以直接恢复，不会被 loopback 地址覆盖。
    func prepareRoutedConnectionSettings(
        endpoint: String,
        activeEndpoint: String,
        tailcatAddress: String,
        token: String,
        profileTarget: PreparedConnectionProfileTarget
    ) async throws -> PreparedConnectionSettings {
        let canonicalEndpoint = try Self.validatedEndpoint(endpoint)
        let routed = try await prepareConnectionSettings(
            endpoint: activeEndpoint,
            token: token,
            profileTarget: profileTarget
        )
        return PreparedConnectionSettings(
            endpoint: canonicalEndpoint,
            activeEndpoint: routed.activeEndpoint,
            route: .tailcat(address: tailcatAddress),
            token: routed.token,
            profileTarget: routed.profileTarget,
            validatedAt: routed.validatedAt,
            installationID: routed.installationID,
            tailscaleDNSName: routed.tailscaleDNSName,
            tailscaleDeviceName: routed.tailscaleDeviceName,
            hostPlatform: routed.hostPlatform,
            hostContext: routed.hostContext,
            capabilityNegotiation: routed.capabilityNegotiation
        )
    }

    func prepareConnectionProfileSwitch(
        id: String,
        activeEndpoint: String,
        tailcatAddress: String
    ) async throws -> PreparedConnectionSettings {
        guard let profile = connectionProfiles.first(where: { $0.id == id }) else {
            throw ConnectionProfileError.notFound
        }
        let profileToken = try await credentialVault.token(for: id)
        guard !profileToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionProfileError.missingToken
        }
        return try await prepareRoutedConnectionSettings(
            endpoint: profile.endpoint,
            activeEndpoint: activeEndpoint,
            tailcatAddress: tailcatAddress,
            token: profileToken,
            profileTarget: .existingProfile(id: id)
        )
    }

    var activeConnectionProfile: ConnectionProfile? {
        guard let activeConnectionProfileID else { return nil }
        return connectionProfiles.first { $0.id == activeConnectionProfileID }
    }

    /// `endpoint` 始终保留档案里的规范地址；真实请求可临时改走同机或 Tailcat 路由。
    var connectionEndpoint: String {
        if isTailcatExperimentModeEnabled {
            // 代理未就绪时锁到不可用的 loopback，任何调用都只能本机失败，不能泄漏到 Tailscale。
            return tailcatExperimentEndpoint ?? "http://127.0.0.1:1"
        }
        return activeRouteEndpoint ?? activeConnectionProfile?.preferredEndpoint ?? endpoint
    }

    var isUsingLocalConnection: Bool {
        activeConnectionRoute == .local
    }

    /// 通知路由优先使用持久化 profile ID；legacy/debug 单连接才退回规范 endpoint 的 SHA-256。
    var notificationRoutingProfileID: String {
        if let activeConnectionProfileID,
           !activeConnectionProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return activeConnectionProfileID
        }
        let normalizedEndpoint = AgentAPIClient.normalizedEndpoint(endpoint)
        let digest = SHA256.hash(data: Data(normalizedEndpoint.utf8))
        return "endpoint-sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    var connectionProfileSettingsModel: ConnectionProfileSettingsModel {
        ConnectionProfileSettingsModel(
            profiles: connectionProfiles,
            activeProfileID: activeConnectionProfileID
        )
    }

    var activeHostScope: HostScope {
        activeHostState.scope
    }

    /// 认证请求只能在前台凭据完整恢复后创建。后台缩略图虽然仍保留工作台，
    /// 但不能让任何旧任务拿空 Token 创建 REST 或 WebSocket Runtime。
    var authenticatedCredentialFingerprint: String? {
        guard !isCredentialMemorySuspended, isConfigured else {
            return nil
        }
        return connectionCredentialFingerprint(token)
    }

    func acceptsCredentialInvalidation(_ error: Error) -> Bool {
        guard isCredentialInvalidatingError(error),
              let currentFingerprint = authenticatedCredentialFingerprint else {
            return false
        }
        guard let rejectedFingerprint = credentialFingerprintRejectedByError(error) else {
            // 兼容测试替身和旧的进程内错误；生产 REST/WS 传输都会携带指纹。
            return true
        }
        return rejectedFingerprint == currentFingerprint
    }

    func isCurrentCredentialFingerprint(_ fingerprint: String?) -> Bool {
        guard let currentFingerprint = authenticatedCredentialFingerprint else {
            return false
        }
        // nil 仅兼容不携带传输上下文的测试 WebSocket。
        return fingerprint == nil || fingerprint == currentFingerprint
    }
}
