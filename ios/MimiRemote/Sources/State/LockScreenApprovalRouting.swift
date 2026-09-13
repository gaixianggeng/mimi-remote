import Foundation

enum LockScreenApprovalRoutingError: Error {
	case sourceProfileUnavailable
	case sourceCredentialUnavailable
}

/// Provider 只给出 installation_id 的不可逆短摘要。这里从本机已保存 Profile
/// 重新计算摘要，既能选中正确 Mac，又不需要把 endpoint 或 Token 放进通知。
/// 摘要算法收口在 `NotificationSessionTag`，与通知扩展共用同一实现。
@MainActor
enum LockScreenApprovalRouting {
	static func profileTag(installationID: String) -> String {
		NotificationSessionTag.profileTag(installationID: installationID)
	}

    static func messageSessionTag(threadID: String) -> String {
        NotificationSessionTag.messageTag(threadID: threadID)
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

    /// 本机快路径只允许同一台 Mac：通知里的档案摘要必须正好对应当前活动档案。
    /// 其它 Mac 的通知即使本地缓存里恰好有同名会话也不能直接打开，那是另一台机器的数据。
    static func isLocalRouteEligible(
        _ notification: LockScreenApprovalNotification,
        activeProfileID: String?,
        profiles: [ConnectionProfile]
    ) -> Bool {
        guard let activeProfileID,
              let localID = localProfileID(for: notification, profiles: profiles) else {
            return false
        }
        return localID == activeProfileID
    }

    /// 定位失败的文案要按通知类型区分：审批的 404/410 确实意味着“请求已结束”，
    /// 而回复通知的 404/410 只是“找不到定位记录”，任务本身还在会话列表里。
    /// 凭据或连接没恢复时也不能借用决策结果的“结果未知”文案——用户什么都没提交。
    static func detailsErrorMessage(
        _ error: Error,
        for notification: LockScreenApprovalNotification
    ) -> String {
        if let apiError = error as? AgentAPIError {
            if case .credentialsInvalid = apiError {
                return L10n.text("ui.the_current_connection_credentials_have_expired_please_re")
            }
            if notification.event.isMessage {
                return messageRouteErrorMessage(apiError)
            }
            if LockScreenApprovalStore.isDefinitive(apiError) {
                return LockScreenApprovalStore.message(forServerError: apiError)
            }
            return L10n.text("ui.push_approval_result_unknown")
        }
        switch error {
        case LockScreenApprovalRoutingError.sourceProfileUnavailable:
            return L10n.text("ui.the_session_corresponding_to_the_notification_is_temporarily")
        case LockScreenApprovalRoutingError.sourceCredentialUnavailable, is CancellationError:
            // 合成的 CancellationError 来自凭据代次或活动档案在等待期间发生变化，
            // 本质上也是“连接还没恢复到能用的状态”。
            return L10n.text("ui.push_route_connection_not_restored")
        default:
            break
        }
        if notification.event.isMessage {
            return L10n.text("ui.the_session_corresponding_to_the_notification_cannot_be")
        }
        return L10n.text("ui.push_approval_result_unknown")
    }

    private static func messageRouteErrorMessage(_ error: AgentAPIError) -> String {
        guard case .server(let status, _) = error else {
            return L10n.text("ui.the_session_corresponding_to_the_notification_cannot_be")
        }
        switch status {
        case 404:
            return L10n.text("ui.push_message_route_missing")
        case 410:
            return L10n.text("ui.push_message_route_expired")
        case 403:
            return L10n.text("ui.push_approval_device_not_allowed")
        default:
            return L10n.text("ui.the_session_corresponding_to_the_notification_is_temporarily")
        }
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
