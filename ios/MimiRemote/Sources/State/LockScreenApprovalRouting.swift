import CryptoKit
import Foundation

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

    static func messageSessionTag(threadID: String) -> String {
        let value = "mimi-tag:session:" + threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02X", $0) }.joined().prefix(16).description
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
		appStore: AppStore,
        sessionStore: SessionStore,
        recoverRouteFromBackground: Bool = true
	) async throws -> (profileID: String, client: AgentAPIClient) {
		guard let profileID = localProfileID(
			for: notification,
			profiles: appStore.connectionProfiles
		) else {
			throw LockScreenApprovalRoutingError.sourceProfileUnavailable
		}
        if appStore.connectionProfiles.first(where: { $0.id == profileID })?.connectionRoute.usesTailcat == true {
            // 同一设备身份不能同时启动两套 Tailcat 引擎。用户点击通知时复用
            // 现有主机切换与恢复流程，不另建会抢占 DERP 连接的临时代理。
            if appStore.activeConnectionProfileID != profileID {
                _ = try await sessionStore.switchConnectionProfile(id: profileID)
            } else if recoverRouteFromBackground {
                guard let controller = sessionStore.tailcatExperimentController,
                      await controller.recoverRouteFromForeground(
                        appStore: appStore, refreshPathDiagnosticAfterPreparation: false
                      ) else {
                    throw LockScreenApprovalRoutingError.sourceCredentialUnavailable
                }
            }
        }
        return (profileID, try await client(profileID: profileID, appStore: appStore))
	}

    static func detailsErrorMessage(_ error: Error) -> String {
        if let apiError = error as? AgentAPIError,
           LockScreenApprovalStore.isDefinitive(apiError) {
            return LockScreenApprovalStore.message(forServerError: apiError)
        }
        if case LockScreenApprovalRoutingError.sourceProfileUnavailable = error {
            return L10n.text("ui.the_session_corresponding_to_the_notification_is_temporarily")
        }
        return L10n.text("ui.push_approval_result_unknown")
    }

    static func client(profileID: String, appStore: AppStore) async throws -> AgentAPIClient {
        let descriptor = try await appStore.hostProbeDescriptor(profileID: profileID)
        guard let profile = appStore.connectionProfiles.first(where: { $0.id == profileID }) else {
            throw LockScreenApprovalRoutingError.sourceProfileUnavailable
        }
        let endpoint: String
        if profile.connectionRoute.usesTailcat {
            // 自动续期、关闭旧绑定等后台维护不能擅自切换当前 Mac。非当前
            // Tailcat 档案须先由用户切回该 Mac；不能悄悄走档案中的直连地址。
            guard appStore.activeConnectionProfileID == profileID else {
                throw LockScreenApprovalRoutingError.sourceProfileUnavailable
            }
            guard appStore.isTailcatExperimentModeEnabled, appStore.tailcatExperimentEndpoint != nil else {
                throw LockScreenApprovalRoutingError.sourceCredentialUnavailable
            }
            endpoint = appStore.connectionEndpoint
        } else {
            guard let configured = descriptor.endpoints.first, !configured.isEmpty else {
                throw LockScreenApprovalRoutingError.sourceCredentialUnavailable
            }
            endpoint = configured
        }
        return AgentAPIClient(endpoint: endpoint, token: descriptor.token)
    }
}
