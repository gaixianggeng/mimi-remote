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

    @Published private(set) var status: Status = .off
    @Published private(set) var providerHost: String?
    @Published private(set) var providerIsOfficial = false
    @Published private(set) var hostSupportsPush = false
    /// 最近一次锁屏决策的结果。UI 必须如实展示冲突、过期与未知，
    /// 把超时显示成成功比不显示更危险。
    @Published private(set) var lastDecisionMessage: String?

    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter
    private let ticketStore: PushTicketStore
    private let environment: PushEnvironment
    private var providerBaseURL: String?
    private var deviceTokenContinuations: [CheckedContinuation<String, Error>] = []
    private var cachedDeviceToken: String?

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

    /// 同意是给具体主机的。中转地址变化后必须重新征得同意，不能沿用旧的。
    var hasConsented: Bool {
        guard let host = providerHost, !host.isEmpty else { return false }
        return defaults.string(forKey: Key.consentedHost) == host
    }

    var deviceID: String { stableIdentifier(forKey: Key.deviceID, prefix: "dev") }
	var installationID: String { stableIdentifier(forKey: Key.installation, prefix: "ins") }
	var registeredProfileID: String? { defaults.string(forKey: Key.registeredProfileID) }
	var registeredProviderURL: String? { defaults.string(forKey: Key.registeredProviderURL) }

    // MARK: - 状态刷新

    /// 读取这台 agentd 是否开启并配置了推送服务。这一步不发送任何设备信息。
    func refreshHostSupport(client: AgentAPIClient) async {
        do {
            let response = try await client.pushStatus()
            hostSupportsPush = response.enabled && response.providerConfigured
            providerBaseURL = response.providerURL?.isEmpty == false
                ? response.providerURL
                : PushProviderClient.defaultBaseURL
            let provider = PushProviderClient(baseURL: providerBaseURL ?? "")
            providerHost = provider.host
            providerIsOfficial = provider.isOfficialService
            if !hostSupportsPush {
                status = .unavailableOnHost
            } else if !isEnabled {
                status = .off
            }
        } catch {
            hostSupportsPush = false
            status = .unavailableOnHost
        }
    }

    // MARK: - 开关

    /// 记录用户对当前收件主机的同意。没有这一步不会注册任何东西。
    func recordConsent() {
        guard let host = providerHost else { return }
        defaults.set(host, forKey: Key.consentedHost)
    }

	func enable(client: AgentAPIClient, profileID: String, providerURL: String? = nil) async {
		let wasEnabled = isEnabled
		guard let baseURL = providerURL ?? providerBaseURL,
			  hostSupportsPush || providerURL != nil else {
            status = .unavailableOnHost
            return
        }
		let provider = PushProviderClient(baseURL: baseURL)
		guard defaults.string(forKey: Key.consentedHost) == provider.host else {
            status = .failed(message: L10n.text("ui.push_consent_required"))
            return
        }
        status = .registering
        do {
            let granted = try await requestNotificationAuthorization()
            guard granted else {
                // 权限被拒时也要如实说明：不能一边关着权限一边宣称锁屏提醒可用。
                defaults.set(false, forKey: Key.enabled)
                status = .notificationsDenied
                return
            }
            LockScreenApprovalCategory.register(on: center)
            let token = try await obtainDeviceToken()
			let ticket = try await provider.issueTicket(
				deviceToken: token,
				installation: installationID,
				environment: environment
			)
			let previousTicket = ticketStore.load()
			let previousProviderURL = defaults.string(forKey: Key.registeredProviderURL)
			try ticketStore.save(ticket.value)
			do {
				_ = try await client.registerPushDevice(
					deviceID: deviceID,
					ticket: ticket.value,
					expiresAt: ticket.expiresAt,
					platform: Self.currentPlatform
				)
			} catch {
				if let previousTicket {
					try? ticketStore.save(previousTicket)
				} else {
					try? ticketStore.delete()
				}
				try? await provider.revokeTicket(ticket.value)
				throw error
			}
			defaults.set(true, forKey: Key.enabled)
			defaults.set(ticket.expiresAt, forKey: Key.ticketExpiresAt)
			defaults.set(profileID, forKey: Key.registeredProfileID)
			defaults.set(baseURL, forKey: Key.registeredProviderURL)
			defaults.set(Self.deviceTokenFingerprint(token), forKey: Key.deviceTokenFingerprint)
			status = .active(expiresAt: ticket.expiresAt)
			if let previousTicket, previousTicket != ticket.value {
				try? await PushProviderClient(baseURL: previousProviderURL ?? baseURL)
					.revokeTicket(previousTicket)
			}
		} catch {
			defaults.set(wasEnabled, forKey: Key.enabled)
			status = .failed(message: error.localizedDescription)
        }
    }

    /// 关闭等价于撤销：删除本地 Ticket、让 agentd 忘记这台设备、请求 Provider
    /// 把 Ticket ID 加入撤销表，并注销远程通知。
	func disable(client: AgentAPIClient?) async {
		let ticket = ticketStore.load()
		let registeredProviderURL = defaults.string(forKey: Key.registeredProviderURL) ?? providerBaseURL
		do {
			if let client {
				try await client.unregisterPushDevice(deviceID: deviceID)
			}
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
		let canRefreshRegisteredHost = registeredProfileID == profileID && registeredProviderURL != nil
		guard isEnabled, hostSupportsPush || canRefreshRegisteredHost else { return }
        guard let expiry = defaults.object(forKey: Key.ticketExpiresAt) as? Date else { return }
        guard expiry.timeIntervalSinceNow < 7 * 24 * 60 * 60 else { return }
		await enable(
			client: client,
			profileID: profileID,
			providerURL: registeredProfileID == profileID ? registeredProviderURL : nil
		)
    }

    // MARK: - Device Token

	@discardableResult
	func handleDeviceToken(_ token: Data) -> Bool {
		let hex = token.map { String(format: "%02x", $0) }.joined()
		let fingerprint = Self.deviceTokenFingerprint(hex)
		let shouldRefresh = isEnabled && status != .registering &&
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
    }

    // MARK: - 锁屏决策

    /// 提交锁屏上的允许/拒绝。结果未知时如实说未知，不猜测成功。
	func submitDecision(
        _ decision: LockScreenApprovalDecision,
        for notification: LockScreenApprovalNotification,
        client: AgentAPIClient
    ) async {
		guard notification.kind.isActionableFromLockScreen else {
			lastDecisionMessage = L10n.text("ui.push_approval_open_app_to_handle")
			return
		}
		guard !notification.isExpired() else {
            lastDecisionMessage = L10n.text("ui.push_approval_expired")
            await removeNotification(identifier: notification.notificationIdentifier)
            return
        }
        do {
            let response = try await client.submitPushDecision(
                actionID: notification.actionID,
                deviceID: notification.deviceID,
                decision: decision
            )
            lastDecisionMessage = Self.message(for: response)
            await removeNotification(identifier: notification.notificationIdentifier)
        } catch let error as AgentAPIError {
            // agentd 用 HTTP 状态码表达确定结论。把 404/409/410 一并说成「未知」
            // 是在撒谎：它明明已经告诉我们这条请求被谁、以什么方式处理掉了。
            lastDecisionMessage = Self.message(forServerError: error)
            if Self.isDefinitive(error) {
                await removeNotification(identifier: notification.notificationIdentifier)
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
        await removeNotification(identifier: notification.notificationIdentifier)
    }

    /// 前台恢复后的权威对账：过期的审批卡片一律清掉，不留下点了没反应的通知。
    func reconcileDeliveredNotifications(now: Date = Date()) async {
        let delivered = await center.deliveredNotifications()
        let stale = delivered.compactMap { item -> String? in
            guard let payload = LockScreenApprovalNotification(
                userInfo: item.request.content.userInfo
            ) else {
                return nil
            }
            return payload.isExpired(at: now) ? payload.notificationIdentifier : nil
        }
        guard !stale.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: stale)
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

    private func removeNotification(identifier: String) async {
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func removeAllApprovalNotifications() async {
        let delivered = await center.deliveredNotifications()
        let identifiers = delivered.compactMap { item -> String? in
            LockScreenApprovalNotification(userInfo: item.request.content.userInfo)?.notificationIdentifier
        }
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
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
