import Foundation
import SwiftUI
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

/// 锁屏审批提醒的客户端协调器。
///
/// 这是一个**默认关闭的实验功能**：关闭状态下不请求通知授权、不注册 Device
/// Token、不向 Provider 发送任何请求。首次开启必须先看到明确的数据披露并同意，
/// 同意是绑定到具体收件主机的——中转地址变了，同意就要重新给一次。
@MainActor
final class LockScreenApprovalStore: ObservableObject {
    enum Status: Equatable {
        /// 用户没开，或者关掉了。
        case off
        /// 这台 agentd 没有配置推送服务，功能不可用。
        case unavailableOnHost
        /// 用户开了，但系统通知权限被拒；不能谎称锁屏提醒已生效。
        case notificationsDenied
        /// 正在注册或刷新 Ticket。
        case registering
        case active(expiresAt: Date)
        case failed(message: String)
    }

    private enum BindingError: LocalizedError {
        case previousClientUnavailable
        case previousProviderUnavailable

        var errorDescription: String? {
            L10n.text("ui.push_approval_result_unknown")
        }
    }

	private enum Key {
        static let enabled = "lockScreenApproval.enabled"
        static let deviceID = "lockScreenApproval.deviceID"
        static let installation = "lockScreenApproval.installation"
        static let consentedHost = "lockScreenApproval.consentedHost"
		static let ticketExpiresAt = "lockScreenApproval.ticketExpiresAt"
		static let registeredProfileID = "lockScreenApproval.registeredProfileID"
		static let registeredProviderURL = "lockScreenApproval.registeredProviderURL"
		static let deviceTokenFingerprint = "lockScreenApproval.deviceTokenFingerprint"
    }

	private struct HostSupport {
		let enabled: Bool
		let providerBaseURL: String?
		let providerHost: String?
		let providerIsOfficial: Bool
	}

    @Published private(set) var status: Status = .off
	@Published private var hostSupportByProfileID: [String: HostSupport] = [:]
    /// 最近一次锁屏决策的结果。UI 必须如实展示冲突、过期与未知，
    /// 把超时显示成成功比不显示更危险。
    @Published private(set) var lastDecisionMessage: String?

    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter
    private let ticketStore: PushTicketStore
    private let environment: PushEnvironment
	private var deviceTokenContinuations: [CheckedContinuation<String, Error>] = []
	private var cachedDeviceToken: String?
	// MainActor 会在 await 期间重入。注册、Profile 切换和关闭必须经过同一条队列，
	// 避免旧 enable 在 disable 完成后又把远端和本地状态写回 enabled。
	private var bindingOperationInFlight = false
	private var bindingOperationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        defaults: UserDefaults = .standard,
        center: UNUserNotificationCenter = .current(),
        ticketStore: PushTicketStore = PushTicketStore(),
        environment: PushEnvironment = .current()
    ) {
        self.defaults = defaults
        self.center = center
        self.ticketStore = ticketStore
        self.environment = environment
        if isEnabled, let expiry = defaults.object(forKey: Key.ticketExpiresAt) as? Date, expiry > Date() {
            status = .active(expiresAt: expiry)
        }
    }

    var isEnabled: Bool { defaults.bool(forKey: Key.enabled) }

    func isEnabled(for profileID: String?) -> Bool {
        guard isEnabled, let profileID else { return false }
        return registeredProfileID == profileID
    }

    /// 同意是给具体主机的。中转地址变化后必须重新征得同意，不能沿用旧的。
	func hasConsented(for profileID: String?) -> Bool {
		guard let host = providerHost(for: profileID), !host.isEmpty else { return false }
		return defaults.string(forKey: Key.consentedHost) == host
	}

	func hostSupportsPush(for profileID: String?) -> Bool {
		hostSupport(for: profileID)?.enabled == true
	}

	func providerHost(for profileID: String?) -> String? {
		hostSupport(for: profileID)?.providerHost
	}

	func providerIsOfficial(for profileID: String?) -> Bool {
		hostSupport(for: profileID)?.providerIsOfficial == true
	}

    var deviceID: String { stableIdentifier(forKey: Key.deviceID, prefix: "dev") }
	var installationID: String { stableIdentifier(forKey: Key.installation, prefix: "ins") }
	var registeredProfileID: String? { defaults.string(forKey: Key.registeredProfileID) }
	var registeredProviderURL: String? { defaults.string(forKey: Key.registeredProviderURL) }

    // MARK: - 状态刷新

    /// 读取这台 agentd 是否开启并配置了推送服务。这一步不发送任何设备信息。
	func refreshHostSupport(client: AgentAPIClient, profileID: String) async {
		do {
			let response = try await client.pushStatus()
			let providerBaseURL = response.providerURL?.isEmpty == false
				? response.providerURL
				: PushProviderClient.defaultBaseURL
			let provider = PushProviderClient(baseURL: providerBaseURL ?? "")
			let support = HostSupport(
				enabled: response.enabled && response.providerConfigured,
				providerBaseURL: providerBaseURL,
				providerHost: provider.host,
				providerIsOfficial: provider.isOfficialService
			)
			hostSupportByProfileID[profileID] = support
			if !support.enabled, !isEnabled || registeredProfileID == profileID {
				status = .unavailableOnHost
			} else if !isEnabled {
				status = .off
			} else if registeredProfileID == profileID,
			          let expiry = defaults.object(forKey: Key.ticketExpiresAt) as? Date,
			          expiry > Date() {
				status = .active(expiresAt: expiry)
			}
		} catch {
			hostSupportByProfileID[profileID] = HostSupport(
				enabled: false,
				providerBaseURL: nil,
				providerHost: nil,
				providerIsOfficial: false
			)
			if !isEnabled || registeredProfileID == profileID {
				status = .unavailableOnHost
			}
		}
	}

    // MARK: - 开关

    /// 记录用户对当前收件主机的同意。没有这一步不会注册任何东西。
	func recordConsent(for profileID: String?) {
		guard let host = providerHost(for: profileID) else { return }
		defaults.set(host, forKey: Key.consentedHost)
	}

	func enable(
		client: AgentAPIClient,
		profileID: String,
		providerURL: String? = nil,
		previousClient: AgentAPIClient? = nil,
		previousClientProfileID: String? = nil
	) async {
		await withBindingOperation {
			await performEnableUntilCurrentDeviceToken(
				client: client,
				profileID: profileID,
				providerURL: providerURL,
				previousClient: previousClient,
				previousClientProfileID: previousClientProfileID
			)
		}
	}

	private func performEnableUntilCurrentDeviceToken(
		client: AgentAPIClient,
		profileID: String,
		providerURL: String?,
		previousClient: AgentAPIClient?,
		previousClientProfileID: String?
	) async {
		await performEnable(
			client: client,
			profileID: profileID,
			providerURL: providerURL,
			previousClient: previousClient,
			previousClientProfileID: previousClientProfileID
		)
		// APNs 可能在上一次注册已经读取 cachedDeviceToken 后回调新 Token。
		// 每次成功后重新比较，直到远端绑定与当前缓存一致。
		while isEnabled, registeredProfileID == profileID {
			guard case .active = status,
			      let token = cachedDeviceToken,
			      defaults.string(forKey: Key.deviceTokenFingerprint) != Self.deviceTokenFingerprint(token)
			else {
				return
			}
			await performEnable(
				client: client,
				profileID: profileID,
				providerURL: registeredProviderURL,
				previousClient: nil,
				previousClientProfileID: nil
			)
		}
	}

	private func performEnable(
		client: AgentAPIClient,
		profileID: String,
		providerURL: String?,
		previousClient: AgentAPIClient?,
		previousClientProfileID: String?
	) async {
		let wasEnabled = isEnabled
		let previousProfileID = registeredProfileID
		let previousTicket = ticketStore.load()
		let previousProviderURL = defaults.string(forKey: Key.registeredProviderURL)
		let previousExpiry = defaults.object(forKey: Key.ticketExpiresAt) as? Date
		let needsProfileSwitch = previousProfileID != nil && previousProfileID != profileID
		let support = hostSupportByProfileID[profileID]
		guard let baseURL = providerURL ?? support?.providerBaseURL,
			  support?.enabled == true || providerURL != nil else {
			status = .unavailableOnHost
			return
		}
		let provider = PushProviderClient(baseURL: baseURL)
		guard defaults.string(forKey: Key.consentedHost) == provider.host else {
			status = .failed(message: L10n.text("ui.push_consent_required"))
			return
		}
		if needsProfileSwitch {
			guard previousClient != nil,
			      previousClientProfileID == previousProfileID,
			      previousTicket != nil,
			      previousExpiry != nil else {
				status = .failed(message: BindingError.previousClientUnavailable.localizedDescription)
				return
			}
			if previousProviderURL == nil {
				status = .failed(message: BindingError.previousProviderUnavailable.localizedDescription)
				return
			}
		}
		status = .registering
		var issuedTicket: String?
		var persistedNewTicket = false
		var previousUnregistrationAttempted = false
		var newRegistrationAttempted = false
		do {
			let granted = try await requestNotificationAuthorization()
			guard granted else {
				// 权限被拒时也要如实说明：不能一边关着权限一边宣称锁屏提醒已生效。
				defaults.set(wasEnabled, forKey: Key.enabled)
				status = .notificationsDenied
				return
			}
			registerNotificationInfrastructure()
			let token = try await obtainDeviceToken()
			let ticket = try await provider.issueTicket(
				deviceToken: token,
				installation: installationID,
				environment: environment
			)
			issuedTicket = ticket.value

			if needsProfileSwitch {
				guard let previousClient else {
					throw BindingError.previousClientUnavailable
				}
				// 同一安装只允许一个绑定。先撤销旧 agentd 注册，再提交新 Profile。
				previousUnregistrationAttempted = true
				try await previousClient.unregisterPushDevice(deviceID: deviceID)
			}

			try ticketStore.save(ticket.value)
			persistedNewTicket = true
			newRegistrationAttempted = true
			_ = try await client.registerPushDevice(
				deviceID: deviceID,
				ticket: ticket.value,
				expiresAt: ticket.expiresAt,
				platform: Self.currentPlatform
			)

			if needsProfileSwitch,
			   let previousTicket,
			   let previousProviderURL {
				try await PushProviderClient(baseURL: previousProviderURL).revokeTicket(previousTicket)
			}

			defaults.set(true, forKey: Key.enabled)
			defaults.set(ticket.expiresAt, forKey: Key.ticketExpiresAt)
			defaults.set(profileID, forKey: Key.registeredProfileID)
			defaults.set(baseURL, forKey: Key.registeredProviderURL)
			defaults.set(Self.deviceTokenFingerprint(token), forKey: Key.deviceTokenFingerprint)
			status = .active(expiresAt: ticket.expiresAt)
			if !needsProfileSwitch,
			   let previousTicket,
			   previousTicket != ticket.value {
				try? await PushProviderClient(baseURL: previousProviderURL ?? baseURL)
					.revokeTicket(previousTicket)
			}
		} catch {
			// 远端响应丢失时也按“可能已经成功”处理，尽力撤销新绑定并恢复旧绑定。
			if newRegistrationAttempted, needsProfileSwitch || previousTicket == nil {
				try? await client.unregisterPushDevice(deviceID: deviceID)
			}
			if newRegistrationAttempted,
			   !needsProfileSwitch,
			   let previousTicket,
			   let previousExpiry {
				_ = try? await client.registerPushDevice(
					deviceID: deviceID,
					ticket: previousTicket,
					expiresAt: previousExpiry,
					platform: Self.currentPlatform
				)
			}
			if previousUnregistrationAttempted,
			   let previousTicket,
			   let previousExpiry,
			   let previousClient {
				_ = try? await previousClient.registerPushDevice(
					deviceID: deviceID,
					ticket: previousTicket,
					expiresAt: previousExpiry,
					platform: Self.currentPlatform
				)
			}
			if persistedNewTicket {
				if let previousTicket {
					try? ticketStore.save(previousTicket)
				} else {
					try? ticketStore.delete()
				}
			}
			if let issuedTicket {
				try? await provider.revokeTicket(issuedTicket)
			}
			defaults.set(wasEnabled, forKey: Key.enabled)
			status = .failed(message: error.localizedDescription)
		}
	}

	/// 关闭等价于撤销：删除本地 Ticket、让 agentd 忘记这台设备、请求 Provider
	/// 把 Ticket ID 加入撤销表，并注销远程通知。
	func disable(client: AgentAPIClient?, profileID: String?) async {
		await withBindingOperation {
			await performDisable(client: client, profileID: profileID)
		}
	}

	private func performDisable(client: AgentAPIClient?, profileID: String?) async {
		guard let profileID, registeredProfileID == profileID else {
			// client 在入队前按 Profile 构造；等待期间绑定可能已切换，旧 client
			// 不能注销当前绑定或清理它的本地状态。
			status = .failed(message: L10n.text("ui.push_approval_result_unknown"))
			return
		}
		guard let client else {
			// 没有来源 client 时不能确认 agentd 已注销；保留全部绑定状态，
			// 让用户恢复连接后重试，而不是只清理本地痕迹。
			status = .failed(message: L10n.text("ui.push_approval_result_unknown"))
			return
		}
		let ticket = ticketStore.load()
		let registeredProviderURL = defaults.string(forKey: Key.registeredProviderURL)
		if ticket != nil && registeredProviderURL == nil {
			status = .failed(message: L10n.text("ui.push_approval_result_unknown"))
			return
		}
		do {
			try await client.unregisterPushDevice(deviceID: deviceID)
			if let ticket, let registeredProviderURL {
				try await PushProviderClient(baseURL: registeredProviderURL).revokeTicket(ticket)
			}
			try ticketStore.delete()
		} catch {
			status = .failed(message: error.localizedDescription)
			return
		}
		defaults.set(false, forKey: Key.enabled)
		for key in [Key.ticketExpiresAt, Key.registeredProfileID, Key.registeredProviderURL, Key.deviceTokenFingerprint] {
			defaults.removeObject(forKey: key)
		}
		status = .off
		#if canImport(UIKit)
		UIApplication.shared.unregisterForRemoteNotifications()
		#endif
		await removeAllApprovalNotifications()
	}

	/// Ticket 剩余不足一周时在前台刷新，而不是等它过期后悄悄失去提醒能力。
	func refreshTicketIfNeeded(client: AgentAPIClient, profileID: String) async {
		guard isEnabled, registeredProfileID == profileID else { return }
		await withBindingOperation {
			// 等待队列期间用户可能已经关闭功能或切换绑定，执行前必须重新确认。
			guard isEnabled, registeredProfileID == profileID else { return }
			let canRefreshRegisteredHost = registeredProviderURL != nil
			guard hostSupportsPush(for: profileID) || canRefreshRegisteredHost else { return }
			if case .failed = status {
				// 失败状态必须保持可重试，即使旧 Ticket 仍有较长的剩余时间。
			} else if let expiry = defaults.object(forKey: Key.ticketExpiresAt) as? Date,
			          expiry.timeIntervalSinceNow >= 7 * 24 * 60 * 60 {
				return
			}
			await performEnableUntilCurrentDeviceToken(
				client: client,
				profileID: profileID,
				providerURL: registeredProviderURL,
				previousClient: nil,
				previousClientProfileID: nil
			)
		}
	}

	/// APNs 在注册过程中回调新 Token 时先排队。当前注册完成后再次比较 fingerprint，
	/// 只有旧 Token 确实被持久化时才补发一次注册。
	func refreshRegistrationAfterDeviceTokenChange(
		client: AgentAPIClient,
		profileID: String
	) async {
		await withBindingOperation {
			guard isEnabled,
			      registeredProfileID == profileID,
			      let token = cachedDeviceToken,
			      defaults.string(forKey: Key.deviceTokenFingerprint) != Self.deviceTokenFingerprint(token)
			else {
				return
			}
			await performEnableUntilCurrentDeviceToken(
				client: client,
				profileID: profileID,
				providerURL: registeredProviderURL,
				previousClient: nil,
				previousClientProfileID: nil
			)
		}
	}

    // MARK: - Device Token

	@discardableResult
	func handleDeviceToken(_ token: Data) -> Bool {
		let hex = token.map { String(format: "%02x", $0) }.joined()
		let fingerprint = Self.deviceTokenFingerprint(hex)
		let shouldRefresh = isEnabled &&
			defaults.string(forKey: Key.deviceTokenFingerprint) != fingerprint
		cachedDeviceToken = hex
        let waiting = deviceTokenContinuations
        deviceTokenContinuations = []
		for continuation in waiting {
			continuation.resume(returning: hex)
		}
		return shouldRefresh
	}

	func handleDeviceTokenFailure(_ error: Error) {
        let waiting = deviceTokenContinuations
        deviceTokenContinuations = []
		for continuation in waiting {
			continuation.resume(throwing: error)
		}
		if isEnabled {
			status = .failed(message: error.localizedDescription)
		}
    }

    // MARK: - 锁屏决策

    /// 提交锁屏上的允许/拒绝。结果未知时如实说未知，不猜测成功。
	func submitDecision(
        _ decision: LockScreenApprovalDecision,
		for notification: LockScreenApprovalNotification,
		client: AgentAPIClient,
		notificationRequestIdentifier: String? = nil
	) async {
		guard notification.kind.isActionableFromLockScreen else {
			lastDecisionMessage = L10n.text("ui.push_approval_open_app_to_handle")
			return
		}
		guard !notification.isExpired() else {
			lastDecisionMessage = L10n.text("ui.push_approval_expired")
			await removeNotification(
				for: notification,
				requestIdentifier: notificationRequestIdentifier
			)
			return
        }
        do {
            let response = try await client.submitPushDecision(
                actionID: notification.actionID,
                deviceID: notification.deviceID,
                decision: decision
			)
			lastDecisionMessage = Self.message(for: response)
			if response.outcome != "busy" {
				await removeNotification(
					for: notification,
					requestIdentifier: notificationRequestIdentifier
				)
			}
        } catch let error as AgentAPIError {
            // agentd 用 HTTP 状态码表达确定结论。把 404/409/410 一并说成「未知」
            // 是在撒谎：它明明已经告诉我们这条请求被谁、以什么方式处理掉了。
			lastDecisionMessage = Self.message(forServerError: error)
			if Self.isDefinitive(error) {
				await removeNotification(
					for: notification,
					requestIdentifier: notificationRequestIdentifier
				)
            }
        } catch {
            // 真正联系不上时才说未知，而且不自动重试「允许」。
            lastDecisionMessage = L10n.text("ui.push_approval_result_unknown")
		}
	}

	func markDecisionUnknown() {
		lastDecisionMessage = L10n.text("ui.push_approval_result_unknown")
	}

	func markRegistrationFailed() {
		status = .failed(message: L10n.text("ui.push_approval_result_unknown"))
	}

    /// 只有 agentd 明确回答过的状态才算确定；确定之后那张通知不再可操作，应当撤下。
    static func isDefinitive(_ error: AgentAPIError) -> Bool {
        guard case .server(let status, _) = error else { return false }
        return [403, 404, 409, 410].contains(status)
    }

    static func message(forServerError error: AgentAPIError) -> String {
        guard case .server(let status, _) = error else {
            return L10n.text("ui.push_approval_result_unknown")
        }
        switch status {
        case 404, 410:
            // 句柄不存在或已作废：过期、已被前台处理、或 agentd 重启后 fail closed。
            return L10n.text("ui.push_approval_expired")
        case 409:
            return L10n.text("ui.push_approval_conflict")
        case 403:
            return L10n.text("ui.push_approval_device_not_allowed")
        case 202:
            return L10n.text("ui.push_approval_in_progress")
        default:
            // 502 是 agentd 够到了但 runtime 没够到——那才是真正的未知。
            return L10n.text("ui.push_approval_result_unknown")
        }
    }

	/// 收到「已处理」静默推送后清掉对应卡片；前台恢复时再整体对账一次。
	func handleResolved(_ notification: LockScreenApprovalNotification) async {
		await removeNotification(for: notification)
    }

    /// 前台恢复后的权威对账：过期的审批卡片一律清掉，不留下点了没反应的通知。
	func reconcileDeliveredNotifications(
		client: AgentAPIClient? = nil,
		now: Date = Date()
	) async {
        let delivered = await center.deliveredNotifications()
		let stale = delivered.compactMap { item -> String? in
			guard let payload = LockScreenApprovalNotification(
				userInfo: item.request.content.userInfo
			) else {
				return nil
			}
			return payload.isExpired(at: now) ? item.request.identifier : nil
		}
		var identifiers = stale
		if let client {
			for item in delivered where !identifiers.contains(item.request.identifier) {
				guard let payload = LockScreenApprovalNotification(
					userInfo: item.request.content.userInfo
				) else {
					continue
				}
				do {
					_ = try await client.pushActionRoute(
						actionID: payload.actionID,
						deviceID: payload.deviceID
					)
				} catch let error as AgentAPIError where Self.isDefinitive(error) {
					// agentd 已明确说明句柄结束或设备无权查看，才可以撤下通知。
					identifiers.append(item.request.identifier)
				} catch {
					// 网络失败、服务暂不可用或响应格式异常都保留通知，等待下一次对账。
				}
			}
		}
		guard !identifiers.isEmpty else { return }
		center.removeDeliveredNotifications(withIdentifiers: identifiers)
	}

    // MARK: - 内部

    private func requestNotificationAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func obtainDeviceToken() async throws -> String {
        if let cachedDeviceToken {
            return cachedDeviceToken
        }
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            deviceTokenContinuations.append(continuation)
        }
    }

	func registerNotificationInfrastructure() {
		LockScreenApprovalCategory.register(on: center)
		#if canImport(UIKit)
		UIApplication.shared.registerForRemoteNotifications()
		#endif
	}

	private func removeNotification(
		for notification: LockScreenApprovalNotification,
		requestIdentifier: String? = nil
	) async {
		if let requestIdentifier, !requestIdentifier.isEmpty {
			center.removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
			return
		}
		let identifiers = (await center.deliveredNotifications()).compactMap { item -> String? in
			guard let payload = LockScreenApprovalNotification(
				userInfo: item.request.content.userInfo
			), payload.identifiesSameApproval(as: notification) else {
				return nil
			}
			return item.request.identifier
		}
		guard !identifiers.isEmpty else { return }
		center.removeDeliveredNotifications(withIdentifiers: identifiers)
	}

	private func removeAllApprovalNotifications() async {
		let delivered = await center.deliveredNotifications()
		let identifiers = delivered.compactMap { item -> String? in
			guard LockScreenApprovalNotification(userInfo: item.request.content.userInfo) != nil else {
				return nil
			}
			return item.request.identifier
		}
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

	private func withBindingOperation(_ operation: () async -> Void) async {
		await acquireBindingOperation()
		defer { releaseBindingOperation() }
		guard !Task.isCancelled else { return }
		await operation()
	}

	private func hostSupport(for profileID: String?) -> HostSupport? {
		guard let profileID else { return nil }
		return hostSupportByProfileID[profileID]
	}

	private func acquireBindingOperation() async {
		if !bindingOperationInFlight {
			bindingOperationInFlight = true
			return
		}
		await withCheckedContinuation { continuation in
			bindingOperationWaiters.append(continuation)
		}
	}

	private func releaseBindingOperation() {
		guard !bindingOperationWaiters.isEmpty else {
			bindingOperationInFlight = false
			return
		}
		bindingOperationWaiters.removeFirst().resume()
	}

	private func stableIdentifier(forKey key: String, prefix: String) -> String {
        if let stored = defaults.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let minted = prefix + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(minted, forKey: key)
		return minted
	}

	private static func deviceTokenFingerprint(_ token: String) -> String {
		connectionCredentialFingerprint(token)
	}

    static var currentPlatform: String {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #else
        return "ios"
        #endif
    }

    static func message(for response: PushDecisionResponse) -> String {
        switch response.outcome {
        case "proceed":
            return response.decision == LockScreenApprovalDecision.allow.rawValue
                ? L10n.text("ui.push_approval_allowed")
                : L10n.text("ui.push_approval_denied")
        case "idempotent":
            return L10n.text("ui.push_approval_already_handled")
        case "conflict":
            return L10n.text("ui.push_approval_conflict")
        case "gone":
            return L10n.text("ui.push_approval_expired")
        case "forbidden":
            return L10n.text("ui.push_approval_device_not_allowed")
        case "busy":
            return L10n.text("ui.push_approval_in_progress")
        default:
            return L10n.text("ui.push_approval_result_unknown")
        }
    }
}
