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
        /// 绑定还在另一台电脑上，而那台电脑联系不上（档案已删、已重装、离线或
        /// Token 被拒）。旧绑定原样保留；UI 据此提供“直接换绑到这台电脑”的出口。
        case previousHostUnavailable
    }

    private enum BindingError: LocalizedError {
        case previousClientUnavailable
        case previousProviderUnavailable
		case providerChanged
		/// 旧 agentd 的注销请求失败。无论是 401、404 还是网络错误，对用户来说都是
		/// “旧电脑联系不上”；具体原因不影响下一步（Provider 撤销后换绑）。
		case previousHostUnreachable
		/// 换绑或关闭时 Provider 没能撤销旧 Ticket；旧绑定必须原样保留。
		case previousBindingRevokeFailed

        var errorDescription: String? {
			switch self {
			case .providerChanged:
				return L10n.text("ui.push_consent_required")
			case .previousClientUnavailable, .previousHostUnreachable:
                return L10n.text("ui.push_previous_host_unavailable")
			case .previousBindingRevokeFailed:
				return L10n.text("ui.push_previous_binding_revoke_failed")
            case .previousProviderUnavailable:
				return L10n.text("ui.push_approval_result_unknown")
			}
        }
    }

	/// 测试需要替换 Provider 与系统通知授权：前者用 URLProtocol 桩，后者不能真的弹
	/// 系统对话框。生产路径保持默认值。
	typealias ProviderClientFactory = (String) -> PushProviderClient
	typealias NotificationAuthorizationRequest = () async throws -> Bool

	private enum Key {
        static let enabled = "lockScreenApproval.enabled"
        static let deviceID = "lockScreenApproval.deviceID"
        static let installation = "lockScreenApproval.installation"
        static let consentedHost = "lockScreenApproval.consentedHost"
		static let consentedProviderURL = "lockScreenApproval.consentedProviderURL"
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

	private struct IdentityResolution {
		let identity: PushInstallationIdentity
		let resetCopiedBinding: Bool
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
	/// 关闭提醒时同步删除 App Group 里的会话标题缓存（gh-418）；功能关掉后
	/// 设备上不该留着一份没有用途的标题副本。测试可注入替身。
	private let clearNotificationTitleCache: () -> Void
	private let providerClientFactory: ProviderClientFactory
	private let requestAuthorization: NotificationAuthorizationRequest
	private let identity: PushInstallationIdentity?
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
		identityStore: PushInstallationIdentityStore = PushInstallationIdentityStore(),
        environment: PushEnvironment = .current(),
		clearNotificationTitleCache: @escaping () -> Void = { NotificationTitleCache.clear() },
		providerClientFactory: @escaping ProviderClientFactory = { PushProviderClient(baseURL: $0) },
		requestAuthorization: NotificationAuthorizationRequest? = nil
    ) {
        self.defaults = defaults
        self.center = center
        self.ticketStore = ticketStore
        self.environment = environment
		self.clearNotificationTitleCache = clearNotificationTitleCache
		self.providerClientFactory = providerClientFactory
		self.requestAuthorization = requestAuthorization ?? {
			try await center.requestAuthorization(options: [.alert, .sound, .badge])
		}
		do {
			let resolution = try Self.resolveIdentity(
				defaults: defaults,
				ticketStore: ticketStore,
				identityStore: identityStore
			)
			identity = resolution.identity
			if resolution.resetCopiedBinding {
				Self.resetCopiedBinding(in: defaults)
			}
			defaults.removeObject(forKey: Key.deviceID)
			defaults.removeObject(forKey: Key.installation)
			if ticketStore.load() != nil {
				Self.migrateLegacyConsentForCurrentBinding(in: defaults)
			}
		} catch {
			// Keychain 读取失败时保持旧状态，且绝不生成临时身份去覆盖远端注册。
			identity = nil
			status = .failed(message: L10n.text("ui.push_approval_result_unknown"))
		}
        if identity != nil,
		   isEnabled,
		   let expiry = defaults.object(forKey: Key.ticketExpiresAt) as? Date,
		   expiry > Date() {
            status = .active(expiresAt: expiry)
        }
    }

    var isEnabled: Bool { defaults.bool(forKey: Key.enabled) }

    func isEnabled(for profileID: String?) -> Bool {
        guard isEnabled, let profileID else { return false }
		guard registeredProfileID == profileID else { return false }
		guard hostSupport(for: profileID) != nil else { return true }
		return registeredProviderMatchesCurrentProvider(for: profileID)
    }

	/// 同意绑定规范化后的完整 Provider URL。即使 host 相同，端口或路径改变也要重来。
	func hasConsented(for profileID: String?) -> Bool {
		guard let providerURL = hostSupport(for: profileID)?.providerBaseURL else { return false }
		return defaults.string(forKey: Key.consentedProviderURL) == providerURL
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

	var deviceID: String { identity?.deviceID ?? "" }
	var installationID: String { identity?.installationID ?? "" }
	var registeredProfileID: String? { defaults.string(forKey: Key.registeredProfileID) }
	var registeredProviderURL: String? {
		Self.normalizedProviderURL(defaults.string(forKey: Key.registeredProviderURL))
	}

    // MARK: - 状态刷新

    /// 读取这台 agentd 是否开启并配置了推送服务。这一步不发送任何设备信息。
	func refreshHostSupport(client: AgentAPIClient, profileID: String) async {
		do {
			let response = try await client.pushStatus()
			let advertisedProviderURL = response.providerURL?.isEmpty == false
				? response.providerURL
				: PushProviderClient.defaultBaseURL
			let providerBaseURL = Self.normalizedProviderURL(advertisedProviderURL)
			let providerHost = providerBaseURL.flatMap { URL(string: $0)?.host }
			let support = HostSupport(
				enabled: response.enabled && response.providerConfigured && providerBaseURL != nil,
				providerBaseURL: providerBaseURL,
				providerHost: providerHost,
				providerIsOfficial: providerBaseURL == Self.normalizedProviderURL(
					PushProviderClient.defaultBaseURL
				)
			)
			hostSupportByProfileID[profileID] = support
			if !support.enabled, !isEnabled || registeredProfileID == profileID {
				status = .unavailableOnHost
			} else if isEnabled,
					  registeredProfileID == profileID,
					  !registeredProviderMatchesCurrentProvider(for: profileID) {
				// 保留旧绑定以便显式换绑时回滚；这里只把开关呈现为需要重新同意。
				status = .failed(message: L10n.text("ui.push_consent_required"))
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

	/// 记录用户对当前完整 Provider URL 的同意。没有这一步不会注册任何东西。
	func recordConsent(for profileID: String?) {
		guard let providerURL = hostSupport(for: profileID)?.providerBaseURL else { return }
		defaults.set(providerURL, forKey: Key.consentedProviderURL)
		defaults.removeObject(forKey: Key.consentedHost)
	}

	/// `takeOverPreviousBinding` 只在旧绑定属于另一台电脑且那台电脑联系不上时使用：
	/// 跳过旧 agentd 的注销，以 Provider 撤销旧 Ticket 为准，再为当前电脑重新注册。
	/// 必须由用户在设置页显式确认后才传 true。
	func enable(
		client: AgentAPIClient,
		profileID: String,
		providerURL: String? = nil,
		previousClient: AgentAPIClient? = nil,
		previousClientProfileID: String? = nil,
		takeOverPreviousBinding: Bool = false
	) async {
		await withBindingOperation {
			await performEnableUntilCurrentDeviceToken(
				client: client,
				profileID: profileID,
				providerURL: providerURL,
				previousClient: previousClient,
				previousClientProfileID: previousClientProfileID,
				takeOverPreviousBinding: takeOverPreviousBinding
			)
		}
	}

	private func performEnableUntilCurrentDeviceToken(
		client: AgentAPIClient,
		profileID: String,
		providerURL: String?,
		previousClient: AgentAPIClient?,
		previousClientProfileID: String?,
		takeOverPreviousBinding: Bool = false
	) async {
		await performEnable(
			client: client,
			profileID: profileID,
			providerURL: providerURL,
			previousClient: previousClient,
			previousClientProfileID: previousClientProfileID,
			takeOverPreviousBinding: takeOverPreviousBinding
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
		previousClientProfileID: String?,
		takeOverPreviousBinding: Bool = false
	) async {
		guard let identity else {
			status = .failed(message: L10n.text("ui.push_approval_result_unknown"))
			return
		}
		let wasEnabled = isEnabled
		let previousProfileID = registeredProfileID
		let previousTicket = ticketStore.load()
		let previousProviderURL = registeredProviderURL
		let previousExpiry = defaults.object(forKey: Key.ticketExpiresAt) as? Date
		let needsProfileSwitch = previousProfileID != nil && previousProfileID != profileID
		let support = hostSupportByProfileID[profileID]
		guard support?.enabled == true,
			  let currentProviderURL = support?.providerBaseURL else {
			status = .unavailableOnHost
			return
		}
		guard let baseURL = Self.normalizedProviderURL(providerURL ?? currentProviderURL),
			  baseURL == currentProviderURL else {
			status = .failed(message: L10n.text("ui.push_consent_required"))
			return
		}
		let needsProviderSwitch = previousProviderURL != nil && previousProviderURL != baseURL
		let needsBindingSwitch = needsProfileSwitch || needsProviderSwitch
		let provider = providerClientFactory(baseURL)
		guard defaults.string(forKey: Key.consentedProviderURL) == baseURL else {
			status = .failed(message: L10n.text("ui.push_consent_required"))
			return
		}
		if needsBindingSwitch {
			guard let previousTicket,
			      previousExpiry != nil,
			      let previousProviderURL else {
				status = .failed(message: BindingError.previousProviderUnavailable.localizedDescription)
				return
			}
			if takeOverPreviousBinding {
				// 旧电脑联系不上时不再要求它先注销：真正决定投递的是 Provider 手里的
				// Ticket，撤销成功即旧绑定失效，旧 agentd 收到 410 后会自行清理设备。
				// 撤销必须成功；失败就原样保留旧绑定，绝不制造两边都注册的窗口。
				status = .registering
				do {
					try await providerClientFactory(previousProviderURL).revokeTicket(previousTicket)
				} catch {
					status = .failed(message: BindingError.previousBindingRevokeFailed.localizedDescription)
					return
				}
				clearStoredBinding()
				// 旧绑定已经不存在，剩下的就是一次干净的首次开启；中途失败留下的也是关闭态。
				await performEnable(
					client: client,
					profileID: profileID,
					providerURL: providerURL,
					previousClient: nil,
					previousClientProfileID: nil
				)
				return
			}
			if needsProfileSwitch,
			   previousClient == nil || previousClientProfileID != previousProfileID {
				// 旧档案已删、Tailcat 档案非当前或缺少凭据：没有网络请求可发。
				status = .previousHostUnavailable
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
			guard providerIsAuthorized(baseURL, for: profileID) else {
				defaults.set(wasEnabled, forKey: Key.enabled)
				status = .failed(message: L10n.text("ui.push_consent_required"))
				return
			}
			let ticket = try await provider.issueTicket(
				deviceToken: token,
				installation: identity.installationID,
				environment: environment
			)
			issuedTicket = ticket.value
			guard providerIsAuthorized(baseURL, for: profileID) else {
				throw BindingError.providerChanged
			}

			if needsProfileSwitch {
				guard let previousClient else {
					throw BindingError.previousClientUnavailable
				}
				// 同一安装只允许一个绑定。先撤销旧 agentd 注册，再提交新 Profile。
				previousUnregistrationAttempted = true
				do {
					try await previousClient.unregisterPushDevice(deviceID: identity.deviceID)
				} catch {
					// 401、404、超时或断网在这里都是同一个结论：旧电脑联系不上。
					// 具体错误不改变下一步，用户可以在确认后走 Provider 撤销换绑。
					throw BindingError.previousHostUnreachable
				}
			}

			try ticketStore.save(ticket.value)
			persistedNewTicket = true
			newRegistrationAttempted = true
			_ = try await client.registerPushDevice(
				deviceID: identity.deviceID,
				ticket: ticket.value,
				expiresAt: ticket.expiresAt,
				platform: Self.currentPlatform
			)
			guard providerIsAuthorized(baseURL, for: profileID) else {
				throw BindingError.providerChanged
			}

			if needsBindingSwitch,
			   let previousTicket,
			   let previousProviderURL {
				// 新注册确认后再撤销旧 Ticket；撤销失败会进入下方回滚，避免静默双活。
				try await providerClientFactory(previousProviderURL).revokeTicket(previousTicket)
			}

			defaults.set(true, forKey: Key.enabled)
			defaults.set(ticket.expiresAt, forKey: Key.ticketExpiresAt)
			defaults.set(profileID, forKey: Key.registeredProfileID)
			defaults.set(baseURL, forKey: Key.registeredProviderURL)
			defaults.set(Self.deviceTokenFingerprint(token), forKey: Key.deviceTokenFingerprint)
			status = providerIsAuthorized(baseURL, for: profileID)
				? .active(expiresAt: ticket.expiresAt)
				: .failed(message: L10n.text("ui.push_consent_required"))
			if !needsBindingSwitch,
			   let previousTicket,
			   previousTicket != ticket.value {
				try? await providerClientFactory(previousProviderURL ?? baseURL)
					.revokeTicket(previousTicket)
			}
		} catch {
			// 远端响应丢失时也按“可能已经成功”处理，尽力撤销新绑定并恢复旧绑定。
			if newRegistrationAttempted, needsProfileSwitch || previousTicket == nil {
				try? await client.unregisterPushDevice(deviceID: identity.deviceID)
			}
			if newRegistrationAttempted,
			   !needsProfileSwitch,
			   let previousTicket,
			   let previousExpiry {
				_ = try? await client.registerPushDevice(
					deviceID: identity.deviceID,
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
					deviceID: identity.deviceID,
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
			switch error as? BindingError {
			case .previousClientUnavailable?, .previousHostUnreachable?:
				// 旧绑定原样保留；由 UI 提供“直接换绑到这台电脑”的出口。
				status = .previousHostUnavailable
			default:
				status = .failed(message: error.localizedDescription)
			}
		}
	}

	/// 把本地绑定彻底清成关闭态：Ticket、注册记录和 Token 指纹都不保留。
	/// 只在 Provider 已经撤销旧 Ticket 之后调用。
	private func clearStoredBinding() {
		try? ticketStore.delete()
		defaults.set(false, forKey: Key.enabled)
		for key in [Key.ticketExpiresAt, Key.registeredProfileID, Key.registeredProviderURL, Key.deviceTokenFingerprint] {
			defaults.removeObject(forKey: key)
		}
	}

	/// 关闭等价于撤销：删除本地 Ticket、让 agentd 忘记这台设备、请求 Provider
	/// 把 Ticket ID 加入撤销表，并注销远程通知。
	func disable(
		client: AgentAPIClient?,
		profileID: String?,
		previousHostUnavailable: Bool = false
	) async {
		await withBindingOperation {
			await performDisable(
				client: client,
				profileID: profileID,
				previousHostUnavailable: previousHostUnavailable
			)
		}
	}

	private func performDisable(
		client: AgentAPIClient?,
		profileID: String?,
		previousHostUnavailable: Bool
	) async {
		guard let identity else {
			status = .failed(message: L10n.text("ui.push_approval_result_unknown"))
			return
		}
		guard let profileID, registeredProfileID == profileID else {
			// client 在入队前按 Profile 构造；等待期间绑定可能已切换，旧 client
			// 不能注销当前绑定或清理它的本地状态。
			status = .failed(message: L10n.text("ui.push_approval_result_unknown"))
			return
		}
		guard client != nil || previousHostUnavailable else {
			// 没有来源 client 时不能确认 agentd 已注销；保留全部绑定状态，
			// 让用户恢复连接后重试，而不是只清理本地痕迹。
			status = .failed(message: L10n.text("ui.push_approval_result_unknown"))
			return
		}
		let ticket = ticketStore.load()
		let registeredProviderURL = self.registeredProviderURL
		if ticket != nil && registeredProviderURL == nil {
			status = .failed(message: L10n.text("ui.push_approval_result_unknown"))
			return
		}
		do {
			if let client {
				try await client.unregisterPushDevice(deviceID: identity.deviceID)
			}
			// 旧电脑联系不上时（client 为 nil），Provider 撤销就是关闭的全部保证：
			// 撤销失败必须保留绑定，只清本地痕迹会让 Provider 继续持有一张有效 Ticket。
			if let ticket, let registeredProviderURL {
				do {
					try await providerClientFactory(registeredProviderURL).revokeTicket(ticket)
				} catch where client == nil {
					throw BindingError.previousBindingRevokeFailed
				}
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
		// 关闭后不会再有推送命中缓存；标题副本随功能一起清掉。
		clearNotificationTitleCache()
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
			guard registeredProviderMatchesCurrentProvider(for: profileID),
			      hasConsented(for: profileID) else {
				status = .failed(message: L10n.text("ui.push_consent_required"))
				return
			}
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
			      registeredProviderMatchesCurrentProvider(for: profileID),
			      hasConsented(for: profileID),
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
        // 系统也可能把可见消息交给远程通知回调；只有已处理事件才能撤下通知。
        guard notification.event == .resolved else { return }
		await removeNotification(for: notification)
    }

    /// agentd 对审批句柄给出的终态；定位接口 200 且落在这些状态时，卡片已经不可操作。
    static let terminalApprovalStates: Set<String> = ["approved", "rejected", "expired", "revoked"]

    /// 对账时是否撤下一张已投递的通知。
    ///
    /// 回复通知只在 410（记录已超过保留时间）时撤下：404 可能只是 Mac 上的 agentd
    /// 较旧或重启后丢了定位记录，任务本身还在会话列表里，用户仍能从列表打开。
    /// 审批通知沿用“agentd 明确说结束”的规则，并把新版定位接口返回的终态一并算进去。
    static func shouldRemoveDeliveredNotification(
        _ notification: LockScreenApprovalNotification,
        afterLocate result: Result<PushActionRouteResponse, Error>
    ) -> Bool {
        switch result {
        case .success(let response):
            guard !notification.event.isMessage,
                  response.kind == "approval",
                  let state = response.state else {
                return false
            }
            return terminalApprovalStates.contains(state)
        case .failure(let error):
            guard let apiError = error as? AgentAPIError,
                  case .server(let status, _) = apiError else {
                // 网络失败、服务暂不可用或响应格式异常都保留通知，等待下一次对账。
                return false
            }
            if notification.event.isMessage {
                return status == 410
            }
            return isDefinitive(apiError)
        }
    }

    /// 前台恢复后的权威对账：过期的审批卡片一律清掉，不留下点了没反应的通知。
	func reconcileDeliveredNotifications(
		client: AgentAPIClient? = nil,
        sourceProfileTag: String? = nil,
		now: Date = Date()
	) async {
        let delivered = await center.deliveredNotifications()
        var identifiers: [String] = []
        var candidates = 0
        var expired = 0
        var removedByServer = 0
        var kept = 0
        var otherMac = 0
        for item in delivered {
            guard let payload = LockScreenApprovalNotification(
                userInfo: item.request.content.userInfo
            ) else {
                continue
            }
            candidates += 1
            if payload.isExpired(at: now) {
                identifiers.append(item.request.identifier)
                expired += 1
                continue
            }
            guard let client, let sourceProfileTag else { continue }
            // 其他 Mac 的通知不能拿当前 Mac 的“找不到”结果来删除。
            guard payload.profileID == sourceProfileTag else {
                otherMac += 1
                continue
            }
            let locate: Result<PushActionRouteResponse, Error>
            do {
                locate = .success(try await client.pushActionRoute(
                    actionID: payload.actionID,
                    deviceID: payload.deviceID
                ))
            } catch {
                locate = .failure(error)
            }
            if Self.shouldRemoveDeliveredNotification(payload, afterLocate: locate) {
                identifiers.append(item.request.identifier)
                removedByServer += 1
            } else {
                kept += 1
            }
        }
        if candidates > 0 {
            // 只记计数：对账涉及多条通知，不写任何单条标识。
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.reconcile,
                outcome: identifiers.isEmpty ? "kept_all" : "removed",
                reason: "expired=\(expired) server=\(removedByServer) kept=\(kept) other_mac=\(otherMac)"
                    + (client == nil ? " offline" : "")
            )
        }
		guard !identifiers.isEmpty else { return }
		center.removeDeliveredNotifications(withIdentifiers: identifiers)
	}

    // MARK: - 内部

    private func requestNotificationAuthorization() async throws -> Bool {
        try await requestAuthorization()
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

	private func registeredProviderMatchesCurrentProvider(for profileID: String) -> Bool {
		guard let support = hostSupport(for: profileID),
		      support.enabled,
		      let currentProviderURL = support.providerBaseURL,
		      let registeredProviderURL else {
			return false
		}
		return registeredProviderURL == currentProviderURL
	}

	private func providerIsAuthorized(_ providerURL: String, for profileID: String) -> Bool {
		hostSupport(for: profileID)?.enabled == true
			&& hostSupport(for: profileID)?.providerBaseURL == providerURL
			&& defaults.string(forKey: Key.consentedProviderURL) == providerURL
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

	private static func resolveIdentity(
		defaults: UserDefaults,
		ticketStore: PushTicketStore,
		identityStore: PushInstallationIdentityStore
	) throws -> IdentityResolution {
		if let stored = try identityStore.load() {
			return IdentityResolution(identity: stored, resetCopiedBinding: false)
		}
		let localTicket = try ticketStore.loadRequired()
		let hasBinding = hasStoredBinding(in: defaults)
		if localTicket != nil,
		   hasBinding,
		   let legacy = PushInstallationIdentity.validated(
			deviceID: defaults.string(forKey: Key.deviceID),
			installationID: defaults.string(forKey: Key.installation)
		   ) {
			// ThisDeviceOnly Ticket 证明这是原设备上的版本升级，旧身份可以一次性迁入。
			try identityStore.save(legacy)
			return IdentityResolution(identity: legacy, resetCopiedBinding: false)
		}
		if localTicket != nil {
			// 卸载后 Keychain 可能留下 Ticket，但 UserDefaults 已清空；身份损坏也会形成
			// 同样的不可验证组合。删除的只是本地孤儿，绝不用复制来的 ID 操作远端。
			try ticketStore.delete()
		}
		let fresh = PushInstallationIdentity.make()
		try identityStore.save(fresh)
		return IdentityResolution(
			identity: fresh,
			resetCopiedBinding: hasBinding
		)
	}

	private static func hasStoredBinding(in defaults: UserDefaults) -> Bool {
		defaults.bool(forKey: Key.enabled)
			|| defaults.object(forKey: Key.ticketExpiresAt) != nil
			|| defaults.string(forKey: Key.registeredProfileID) != nil
			|| defaults.string(forKey: Key.registeredProviderURL) != nil
			|| defaults.string(forKey: Key.deviceTokenFingerprint) != nil
	}

	private static func resetCopiedBinding(in defaults: UserDefaults) {
		// 没有本机 Ticket 说明这是恢复副本或已丢失的绑定。只清本地副本，绝不拿
		// 复制来的 deviceID 去注销或覆盖原设备。
		defaults.set(false, forKey: Key.enabled)
		for key in [
			Key.ticketExpiresAt,
			Key.registeredProfileID,
			Key.registeredProviderURL,
			Key.deviceTokenFingerprint,
			Key.consentedHost,
			Key.consentedProviderURL,
		] {
			defaults.removeObject(forKey: key)
		}
	}

	private static func migrateLegacyConsentForCurrentBinding(in defaults: UserDefaults) {
		defer { defaults.removeObject(forKey: Key.consentedHost) }
		guard defaults.string(forKey: Key.consentedProviderURL) == nil,
		      let legacyHost = defaults.string(forKey: Key.consentedHost)?.lowercased(),
		      let registeredProviderURL = normalizedProviderURL(
				defaults.string(forKey: Key.registeredProviderURL)
		      ),
		      URL(string: registeredProviderURL)?.host?.lowercased() == legacyHost else {
			return
		}
		// 旧同意只升级为这台设备已经在用的确切 URL，绝不扩展到同 host 的新路径。
		defaults.set(registeredProviderURL, forKey: Key.consentedProviderURL)
	}

	static func normalizedProviderURL(_ rawValue: String?) -> String? {
		guard let rawValue else { return nil }
		let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty,
		      var components = URLComponents(string: trimmed),
		      components.scheme?.lowercased() == "https",
		      let host = components.host?.lowercased(),
		      !host.isEmpty,
		      components.user == nil,
		      components.password == nil,
		      components.query == nil,
		      components.fragment == nil else {
			return nil
		}
		components.scheme = "https"
		components.host = host
		if components.port == 443 {
			components.port = nil
		}
		var path = components.percentEncodedPath
		while path.count > 1, path.hasSuffix("/") {
			path.removeLast()
		}
		if path == "/" {
			path = ""
		}
		components.percentEncodedPath = path
		return components.url?.standardized.absoluteString
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
