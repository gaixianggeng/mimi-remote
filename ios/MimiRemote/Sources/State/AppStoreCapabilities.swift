import Foundation

extension AppStore {
    func capabilityDecision(for capability: String) -> HostCapabilityDecision {
        let decision = activeHostState.capabilityNegotiation.decision(for: capability)
        CapabilityNegotiationLog.record(capability: capability, decision: decision)
        return decision
    }

    func refreshCapabilityNegotiationForCurrentHost(
        capability: String
    ) async -> HostCapabilityDecision {
        capabilityNegotiationGeneration &+= 1
        let refreshGeneration = capabilityNegotiationGeneration
        let capturedState = activeHostState
        let capturedEndpoint = AgentAPIClient.normalizedEndpoint(connectionEndpoint)
        let capturedToken = token
        let capturedFingerprint = connectionCredentialFingerprint(capturedToken)

        do {
            let version = try await AgentAPIClient(
                endpoint: capturedEndpoint,
                token: capturedToken
            ).version()
            try version.requireCompatible()
            if let profile = activeConnectionProfile {
                try Self.validateInstallationIdentity(
                    actual: version.installationID,
                    expected: profile.installationID,
                    profileName: profile.displayName
                )
            }
            guard refreshGeneration == capabilityNegotiationGeneration,
                  capturedState.scope == activeHostState.scope,
                  capturedEndpoint == AgentAPIClient.normalizedEndpoint(connectionEndpoint),
                  capturedFingerprint == connectionCredentialFingerprint(token) else {
                CapabilityNegotiationLog.record(capability: capability, decision: .negotiationFailed)
                return .negotiationFailed
            }
            // Mac 端切换 Agent 会重载 daemon；同 endpoint/token 的 Bundle 仍需重新读取渠道配置。
            _ = try? await activeRuntimeBundle?.refreshConfiguration()
            guard refreshGeneration == capabilityNegotiationGeneration,
                  capturedState.scope == activeHostState.scope,
                  capturedEndpoint == AgentAPIClient.normalizedEndpoint(connectionEndpoint),
                  capturedFingerprint == connectionCredentialFingerprint(token) else {
                CapabilityNegotiationLog.record(capability: capability, decision: .negotiationFailed)
                return .negotiationFailed
            }
            replaceCapabilityNegotiation(
                version.capabilityNegotiation,
                preserving: capturedState
            )
            return capabilityDecision(for: capability)
        } catch {
            // 网络、兼容窗口或安装身份校验失败时只撤销 capability 授权，
            // 不清理当前 Host 的凭据、草稿或基础会话连接。
            if refreshGeneration == capabilityNegotiationGeneration,
               capturedState.scope == activeHostState.scope,
               capturedEndpoint == AgentAPIClient.normalizedEndpoint(connectionEndpoint),
               capturedFingerprint == connectionCredentialFingerprint(token) {
                replaceCapabilityNegotiation(.notNegotiated, preserving: capturedState)
            }
            CapabilityNegotiationLog.record(capability: capability, decision: .negotiationFailed)
            return .negotiationFailed
        }
    }

    func capabilityLease(for capability: String) -> HostCapabilityLease? {
        guard capabilityDecision(for: capability) == .enabled else {
            return nil
        }
        return HostCapabilityLease(capability: capability, hostScope: activeHostState.scope)
    }

    func isCurrentCapabilityLease(_ lease: HostCapabilityLease) -> Bool {
        guard lease.hostScope == activeHostState.scope else {
            CapabilityNegotiationLog.record(capability: lease.capability, decision: .negotiationFailed)
            return false
        }
        return capabilityDecision(for: lease.capability) == .enabled
    }
}
