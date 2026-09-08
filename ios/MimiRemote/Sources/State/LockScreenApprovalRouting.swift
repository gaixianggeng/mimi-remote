import CryptoKit
import Foundation

/// 临时连接只服务于目标 Mac，释放时关闭；不切换用户正在查看的 Profile。
final class LockScreenApprovalTailcatRoute {
    let runtime: any TailcatExperimentRuntimeProtocol

    init(runtime: any TailcatExperimentRuntimeProtocol) { self.runtime = runtime }

    deinit {
        let runtime = runtime
        Task { try? await runtime.stop() }
    }
}

enum LockScreenApprovalRoutingError: Error {
	case sourceProfileUnavailable
	case sourceCredentialUnavailable
}

/// Provider 只给出 installation_id 的不可逆短摘要。这里从本机已保存 Profile
/// 重新计算摘要，既能选中正确 Mac，又不需要把 endpoint 或 Token 放进通知。
@MainActor
enum LockScreenApprovalRouting {
	static func profileTag(installationID: String) -> String {
		let value = "mimi-profile:" + installationID.trimmingCharacters(in: .whitespacesAndNewlines)
		return SHA256.hash(data: Data(value.utf8))
			.map { String(format: "%02x", $0) }
			.joined()
			.prefix(16)
			.lowercased()
	}

	static func localProfileID(
		for notification: LockScreenApprovalNotification,
		profiles: [ConnectionProfile]
	) -> String? {
		profiles.first { profile in
			guard let installationID = profile.installationID else { return false }
			return profileTag(installationID: installationID) == notification.profileID
		}?.id
	}

	static func sourceClient(
		for notification: LockScreenApprovalNotification,
		appStore: AppStore
	) async throws -> (profileID: String, client: AgentAPIClient) {
		guard let profileID = localProfileID(
			for: notification,
			profiles: appStore.connectionProfiles
		) else {
			throw LockScreenApprovalRoutingError.sourceProfileUnavailable
		}
		return (profileID, try await client(profileID: profileID, appStore: appStore))
	}

	static func client(
        profileID: String,
        appStore: AppStore,
        tokenStore: TokenStore = TokenStore(),
        runtime: any TailcatExperimentRuntimeProtocol = TailcatExperimentRuntime()
    ) async throws -> AgentAPIClient {
		let descriptor = try await appStore.hostProbeDescriptor(profileID: profileID)
		guard let endpoint = descriptor.endpoints.first,
			  !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw LockScreenApprovalRoutingError.sourceCredentialUnavailable
		}
		guard let profile = appStore.connectionProfiles.first(where: { $0.id == profileID }) else {
            throw LockScreenApprovalRoutingError.sourceProfileUnavailable
        }
        guard profile.connectionRoute.usesTailcat else {
            return AgentAPIClient(endpoint: endpoint, token: descriptor.token)
        }
        let address = try tokenStore.loadTailcatAddress(profileID: profileID)
        let privateKey = try tokenStore.loadTailcatExperimentPrivateKey()
        guard !address.isEmpty, !privateKey.isEmpty else {
            throw LockScreenApprovalRoutingError.sourceCredentialUnavailable
        }
        let route = LockScreenApprovalTailcatRoute(runtime: runtime)
        let routedEndpoint = try await runtime.start(address: address, privateKey: privateKey)
        // 异步建链期间档案可能被编辑或删除，不能把旧凭据提交给变化后的目标。
        guard appStore.connectionProfiles.first(where: { $0.id == profileID }) == profile else {
            throw CancellationError()
        }
        return AgentAPIClient(endpoint: routedEndpoint, token: descriptor.token, approvalRoute: route)
	}
}
