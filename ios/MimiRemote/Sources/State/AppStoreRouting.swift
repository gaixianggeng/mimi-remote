import CryptoKit
import Foundation

extension AppStore {
    func runtimeIdentity(endpoint: String, token: String) -> String {
        "\(endpoint)\n\(token)"
    }

    /// 每个宿主只由 `runtimeBundle` 创建一份原生客户端。
    ///
    /// Debug 与正式构建使用同一实现。用户启用状态来自 Mac 模块写入的 agentd 配置，
    /// 能力来自 config channel，健康状态再由原生 RPC 探测。
    var nativeHarnessFactory: HarnessSessionClientFactory {
        HarnessSessionAPIClient.liveFactory
    }

    /// 当前宿主使用的原生 Harness 客户端；未注入原生通道时为 `nil`。
    ///
    /// 供 Store 接上宿主级 `$events` 的出口——那条通道不属于任何会话页面
    /// （契约 D5：别的会话的审批可能在用户从未打开它时到达）。
    ///
    /// 必须走 `runtimeBundle` 取**同一个** bundle：另建一个会得到第二条 runtime
    /// （连接、代次、pending 表都各一份），于是"宿主级订阅"其实订在另一条连接上。
    func nativeHarnessClientForActiveHost() -> HarnessSessionClient? {
        guard let endpoint = try? Self.validatedEndpoint(connectionEndpoint) else { return nil }
        return runtimeBundle(endpoint: endpoint, token: token).harness
    }

    func setActiveConnectionProfileRoute(_ route: ConnectionProfileRoute) throws {
        guard let profileID = activeConnectionProfileID,
              let index = connectionProfiles.firstIndex(where: { $0.id == profileID }),
              connectionProfiles[index].connectionRoute != route else {
            return
        }
        var nextProfiles = connectionProfiles
        nextProfiles[index].connectionRoute = route
        if !ConnectionProfile.acceptsHostDeviceName(endpoint: nextProfiles[index].endpoint, route: route) {
            nextProfiles[index].hostDeviceName = nil
            if !nextProfiles[index].isDisplayNameCustomized {
                nextProfiles[index].displayName = nextProfiles[index].tailscaleDeviceName
                    ?? ConnectionProfile.fallbackDisplayName(endpoint: nextProfiles[index].endpoint)
            }
        }
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
        managed: Bool = false,
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
            route: managed
                ? .managedTailcat(address: tailcatAddress)
                : .customTailcat(address: tailcatAddress),
            token: routed.token,
            profileTarget: routed.profileTarget,
            validatedAt: routed.validatedAt,
            installationID: routed.installationID,
            tailscaleDNSName: routed.tailscaleDNSName,
            tailscaleDeviceName: routed.tailscaleDeviceName,
            hostDeviceName: routed.hostDeviceName,
            hostPlatform: routed.hostPlatform,
            hostContext: routed.hostContext,
            capabilityNegotiation: routed.capabilityNegotiation
        )
    }

    func prepareConnectionProfileSwitch(
        id: String,
        activeEndpoint: String,
        tailcatAddress: String,
        managed: Bool
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
            managed: managed,
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

    var savedFallbackConnectionRoute: ConnectionProfileRoute? {
        guard let profile = activeConnectionProfile else { return nil }
        // Tailcat 二维码中的回环地址仅用于签名，不是另一条已配对的局域网线路。
        if profile.connectionRoute.usesTailcat {
            guard let host = URLComponents(string: profile.endpoint)?.host?.lowercased(),
                  host != "localhost", host != "::1", host != "[::1]", !host.hasPrefix("127.") else { return nil }
        }
        return .configuredValue(
            endpoint: profile.endpoint,
            tailscaleDNSName: profile.tailscaleDNSName
        )
    }

    func canUseSavedFallback(_ route: ConnectionProfileRoute) -> Bool {
        guard route == .tailscale || route == .lan || route == .https else { return false }
        return savedFallbackConnectionRoute == route
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

    /// 本地无档案时的旧版单主机凭据（例如升级迁移失败后仍保留在内存中的 endpoint + token）。
    var hasValidLegacySingleHostCredential: Bool {
        connectionProfiles.isEmpty &&
            !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否存在待恢复的 Keychain 路径（锁屏/瞬时 Keychain 不可读，或已保存档案在前后台切换期间短暂清空内存凭据）。
    var hasKeychainRecoveryPath: Bool {
        hasPendingKeychainRecovery || (isCredentialMemorySuspended && !connectionProfiles.isEmpty)
    }

    /// 显式“未连接电脑”谓词（禁止使用 `!isConfigured` 替代）。
    ///
    /// 仅在本地宿主状态已加载完成、已保存电脑档案为 0、且不存在 Keychain 恢复路径或有效旧版单主机凭据时为 `true`，
    /// 从而把真正的“无主机空态”与锁屏 Keychain 恢复、重连、前后台凭据挂起严格区分开。
    var hasNoConfiguredHost: Bool {
        guard hasLoadedLocalHostState else { return false }
#if DEBUG
        if shouldSeedDebugWorkbenchUI {
            return false
        }
#endif
        return connectionProfiles.isEmpty &&
            !hasKeychainRecoveryPath &&
            !hasValidLegacySingleHostCredential
    }

    struct InitialHostCredentialsResolution {
        let profiles: [ConnectionProfile]
        let activeProfileID: String?
        let endpoint: String
        let token: String
        let hasPendingKeychainRecovery: Bool
    }

    static func resolveInitialHostCredentials(
        defaults: UserDefaults,
        tokenStore: TokenStore,
        endpointKey: String,
        profilesKey: String,
        legacyProfilesKey: String,
        activeProfileIDKey: String,
        defaultEndpoint: String
    ) -> InitialHostCredentialsResolution {
        var initialProfiles = loadConnectionProfiles(from: defaults)
        if defaults.data(forKey: profilesKey) == nil,
           !initialProfiles.isEmpty,
           let migratedProfiles = try? JSONEncoder().encode(initialProfiles) {
            defaults.set(migratedProfiles, forKey: profilesKey)
        }
        var initialActiveProfileID = defaults.string(forKey: activeProfileIDKey)
        var initialEndpoint = defaults.string(forKey: endpointKey) ?? defaultEndpoint
        var initialToken = ""
        var hasPendingKeychainRecovery = false

        if let activeProfileID = initialActiveProfileID,
           let activeProfile = initialProfiles.first(where: { $0.id == activeProfileID }) {
            do {
                let profileToken = try tokenStore.load(profileID: activeProfileID)
                if !profileToken.isEmpty {
                    initialEndpoint = activeProfile.endpoint
                    initialToken = profileToken
                } else {
                    initialActiveProfileID = nil
                }
            } catch {
                if (error as? TokenStoreError)?.isMissingEntitlement != true {
                    hasPendingKeychainRecovery = true
                }
                initialActiveProfileID = nil
            }
        } else if initialProfiles.isEmpty {
            // 稳定 V2 冷启动只读 active profile account；只有确实没有 Profile 时才读一次 legacy，
            // 避免保存 5 台 Mac 后把 Keychain 读取次数带进首屏关键路径。
            do {
                let legacyToken = try tokenStore.loadLegacy()
                if legacyToken.isEmpty {
                    initialActiveProfileID = nil
                } else {
                    initialToken = legacyToken
                    // 旧版本只有一个 endpoint + `agentd-token`。先把 Token 写入新的独立 account，
                    // 成功后才发布档案元数据；任一步失败都继续使用旧内存态和旧 Keychain 项。
                    let normalizedEndpoint = (try? validatedEndpoint(initialEndpoint)) ?? defaultEndpoint
                    let migratedProfile = ConnectionProfile(
                        id: UUID().uuidString,
                        displayName: defaultProfileDisplayName(endpoint: normalizedEndpoint),
                        endpoint: normalizedEndpoint,
                        lastSuccessfulAt: nil
                    )
                    do {
                        let encodedProfiles = try JSONEncoder().encode([migratedProfile])
                        try tokenStore.save(initialToken, profileID: migratedProfile.id)
                        defaults.set(encodedProfiles, forKey: profilesKey)
                        defaults.set(encodedProfiles, forKey: legacyProfilesKey)
                        defaults.set(migratedProfile.id, forKey: activeProfileIDKey)
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
            } catch {
                if (error as? TokenStoreError)?.isMissingEntitlement != true {
                    hasPendingKeychainRecovery = true
                }
                initialActiveProfileID = nil
            }
        } else {
            // 已存在档案时，即使 legacy item 因旧迁移清理失败而残留，也绝不能重新迁移并覆盖档案列表。
            // 当前档案 Token 不可读时退回“未选中当前电脑”，保留所有已有档案待用户重新配对或切换。
            initialActiveProfileID = nil
        }

        return InitialHostCredentialsResolution(
            profiles: initialProfiles,
            activeProfileID: initialActiveProfileID,
            endpoint: initialEndpoint,
            token: initialToken,
            hasPendingKeychainRecovery: hasPendingKeychainRecovery
        )
    }
}
