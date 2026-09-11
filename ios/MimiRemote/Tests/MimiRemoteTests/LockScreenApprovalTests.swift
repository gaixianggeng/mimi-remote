import Security
import Combine
import UserNotifications
import XCTest
@testable import MimiRemote

final class LockScreenApprovalTests: XCTestCase {
    private func payload(overrides: [String: Any] = [:]) -> [AnyHashable: Any] {
        var mimi: [String: Any] = [
            "version": 1,
            "event": "approval.pending",
            "action_id": "act-0123456789abcdef",
            "device_id": "dev-abc123",
            "profile_id": "0123456789abcdef",
            "runtime": "codex",
            "approval_kind": "command",
            "host_tag": "A1C3",
            "session_tag": "7D92",
            "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)),
        ]
        for (key, value) in overrides {
            if case Optional<Any>.none = value {
                mimi.removeValue(forKey: key)
            } else {
                mimi[key] = value
            }
        }
        return ["mimi": mimi]
    }

    func testMessageNotificationsOnlyOpenDetails() throws {
        for event in ["turn.completed", "turn.failed", "turn.interrupted"] {
            let userInfo = payload(overrides: ["event": event, "approval_kind": ""])
            let notification = try XCTUnwrap(LockScreenApprovalNotification(userInfo: userInfo))
            XCTAssertTrue(notification.event.isMessage)
            XCTAssertFalse(notification.kind.isActionableFromLockScreen)
            let delivery = try XCTUnwrap(LockScreenApprovalDelivery(
                userInfo: userInfo, actionIdentifier: LockScreenApprovalCategory.allowActionID
            ))
            XCTAssertNil(delivery.decision)
            XCTAssertNil(LockScreenApprovalNotification(userInfo: payload(overrides: ["event": event])))
        }
        XCTAssertNil(LockScreenApprovalNotification(userInfo: payload(overrides: ["approval_kind": "message"])))
    }

    @MainActor
    func testVisibleMessageIsQuietOnlyForMatchingMacAndTask() {
        XCTAssertEqual(LockScreenApprovalRouting.messageSessionTag(threadID: "thread-1"), "9E61BAD1E6C4DDAF")
        let adapter = SessionNotificationResponseAdapter()
        let scene = UUID()
        let route = SessionNotificationRoute.current(profileID: "local-profile", projectID: "project", sessionID: "thread-1")
        adapter.setVisibleSessionRoute(route, for: scene, installationID: "installation-1")
        let userInfo = payload(overrides: [
            "event": "turn.completed", "approval_kind": "",
            "profile_id": LockScreenApprovalRouting.profileTag(installationID: "installation-1"),
            "session_tag": LockScreenApprovalRouting.messageSessionTag(threadID: "thread-1"),
        ])
        XCTAssertEqual(adapter.presentationOptions(forNotificationIdentifier: "remote-id", userInfo: userInfo), [])
        let otherTask = payload(overrides: [
            "event": "turn.completed", "approval_kind": "",
            "profile_id": LockScreenApprovalRouting.profileTag(installationID: "installation-1"),
            "session_tag": LockScreenApprovalRouting.messageSessionTag(threadID: "thread-2"),
        ])
        XCTAssertEqual(adapter.presentationOptions(forNotificationIdentifier: "remote-id", userInfo: otherTask), [.banner, .sound])
        adapter.setVisibleSessionRoute(route, for: scene, installationID: "other-mac")
        XCTAssertEqual(adapter.presentationOptions(forNotificationIdentifier: "remote-id", userInfo: userInfo), [.banner, .sound])
        adapter.setVisibleSessionRoute(nil, for: scene)
        XCTAssertEqual(adapter.presentationOptions(forNotificationIdentifier: "remote-id", userInfo: userInfo), [.banner, .sound])
    }

    func testDecodesWellFormedApproval() throws {
        let notification = try XCTUnwrap(LockScreenApprovalNotification(userInfo: payload()))
        XCTAssertEqual(notification.event, .pending)
        XCTAssertEqual(notification.runtime, .codex)
        XCTAssertEqual(notification.kind, .command)
        XCTAssertEqual(notification.hostTag, "A1C3")
        XCTAssertEqual(notification.actionID, "act-0123456789abcdef")
        XCTAssertFalse(notification.isExpired())
    }

    /// Payload 会经过 Apple 与中转服务。任何自由文本都不应该能进入 App 的
    /// 请求路径或界面，所以解码必须是白名单而不是尽力而为。
    func testRejectsTamperedOrFreeTextPayloads() {
        let cases: [String: [String: Any]] = [
            "未知 runtime": ["runtime": "gemini"],
            "未知审批类型": ["approval_kind": "rm -rf /"],
            "主机名冒充短标签": ["host_tag": "landy-macbook"],
            "会话标题冒充短标签": ["session_tag": "修复登录"],
            "小写十六进制不是合法标签": ["host_tag": "a1c3"],
            "动作 id 含路径分隔符": ["action_id": "../../etc/passwd"],
            "动作 id 超长": ["action_id": String(repeating: "a", count: 128)],
            "版本不匹配": ["version": 2],
            "过期时间不是 RFC3339": ["expires_at": "tomorrow"],
        ]
        for (name, overrides) in cases {
            XCTAssertNil(
                LockScreenApprovalNotification(userInfo: payload(overrides: overrides)),
                "应拒绝：\(name)"
            )
        }
        XCTAssertNil(LockScreenApprovalNotification(userInfo: [:]), "缺少 payload 时必须拒绝")
        XCTAssertNil(
            LockScreenApprovalNotification(userInfo: ["mimi": ["version": 1]]),
            "字段不全时必须拒绝"
        )
    }

    /// 只有响应形状无歧义的两类可以在锁屏直接放行。
    func testOnlyCommandAndPatchAreActionableFromLockScreen() {
        XCTAssertTrue(LockScreenApprovalNotification.Kind.command.isActionableFromLockScreen)
        XCTAssertTrue(LockScreenApprovalNotification.Kind.patch.isActionableFromLockScreen)
        XCTAssertFalse(LockScreenApprovalNotification.Kind.permission.isActionableFromLockScreen)
        XCTAssertFalse(LockScreenApprovalNotification.Kind.userInput.isActionableFromLockScreen)
        XCTAssertFalse(LockScreenApprovalNotification.Kind.elicitation.isActionableFromLockScreen)
    }

    func testSameApprovalCollapsesOntoOneNotification() throws {
        let first = try XCTUnwrap(LockScreenApprovalNotification(userInfo: payload()))
        let second = try XCTUnwrap(LockScreenApprovalNotification(userInfo: payload()))
        XCTAssertEqual(first.approvalIdentifier, second.approvalIdentifier)
        let other = try XCTUnwrap(
            LockScreenApprovalNotification(userInfo: payload(overrides: ["action_id": "act-other"]))
        )
        XCTAssertNotEqual(first.approvalIdentifier, other.approvalIdentifier)
    }

	@MainActor
	func testProfileTagMatchesAgentdRoutingTag() {
		XCTAssertEqual(
			LockScreenApprovalRouting.profileTag(installationID: "installation-1"),
			"358829f722fb8e21"
		)
	}

    /// 两个动作都必须要求系统身份验证：仅凭锁屏访问既不能放行命令，
    /// 也不该能中断别人正在跑的任务。
    func testBothActionsRequireDeviceAuthentication() throws {
        let category = LockScreenApprovalCategory.makeCategory()
        XCTAssertEqual(category.identifier, LockScreenApprovalCategory.identifier)
        XCTAssertEqual(category.actions.count, 3, "可操作审批保留允许、拒绝和查看详情")
        for action in category.actions.filter({ $0.identifier != LockScreenApprovalCategory.detailsActionID }) {
            XCTAssertTrue(
                action.options.contains(.authenticationRequired),
                "\(action.identifier) 必须要求解锁"
            )
        }
        let deny = try XCTUnwrap(category.actions.first { $0.identifier == LockScreenApprovalCategory.denyActionID })
        XCTAssertTrue(deny.options.contains(.destructive))
        let details = try XCTUnwrap(
            category.actions.first { $0.identifier == LockScreenApprovalCategory.detailsActionID }
        )
        XCTAssertTrue(details.options.contains(.foreground))

        let detailsCategory = LockScreenApprovalCategory.makeDetailsCategory()
        XCTAssertEqual(detailsCategory.identifier, LockScreenApprovalCategory.detailsIdentifier)
        XCTAssertEqual(detailsCategory.actions.map(\.identifier), [LockScreenApprovalCategory.detailsActionID])
    }

    func testDecisionMapping() {
        XCTAssertEqual(
            LockScreenApprovalCategory.decision(forActionIdentifier: LockScreenApprovalCategory.allowActionID),
            .allow
        )
        XCTAssertEqual(
            LockScreenApprovalCategory.decision(forActionIdentifier: LockScreenApprovalCategory.denyActionID),
            .deny
        )
        XCTAssertNil(LockScreenApprovalCategory.decision(forActionIdentifier: UNNotificationDefaultActionIdentifier))
    }

    @MainActor
    func testInboxRoutesActionsAndDefaultTap() throws {
        let inbox = LockScreenApprovalInbox()

        XCTAssertTrue(inbox.receive(
            userInfo: payload(),
            actionIdentifier: LockScreenApprovalCategory.allowActionID
        ))
        XCTAssertEqual(inbox.pending?.decision, .allow)
        XCTAssertEqual(inbox.pending?.requestIdentifier, nil)

        XCTAssertTrue(inbox.receive(
            userInfo: payload(),
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ))
        XCTAssertNil(inbox.pending?.decision, "点击通知本身是查看详情，不是决策")

        // 「已处理」是静默更新，只用于清理旧通知。
        XCTAssertTrue(inbox.receive(
            userInfo: payload(overrides: ["event": "approval.resolved"]),
            actionIdentifier: LockScreenApprovalCategory.allowActionID
        ))
        XCTAssertEqual(inbox.pending?.notification.event, .resolved)
        XCTAssertNil(inbox.pending?.decision)

        XCTAssertTrue(inbox.receive(
            userInfo: payload(),
            actionIdentifier: LockScreenApprovalCategory.allowActionID,
            requestIdentifier: "system-request-42"
        ))
        XCTAssertEqual(inbox.pending?.requestIdentifier, "system-request-42")

        XCTAssertTrue(inbox.receive(
            userInfo: payload(overrides: ["approval_kind": "permission"]),
            actionIdentifier: LockScreenApprovalCategory.allowActionID,
            requestIdentifier: "system-request-43"
        ))
        XCTAssertNil(inbox.pending?.decision, "不可锁屏处理的类型不能被伪造动作放行")

        // 会话通知的 payload 不该被误认成审批。
        XCTAssertFalse(inbox.receive(
            userInfo: SessionNotificationRoute.current(
                profileID: "profile",
                projectID: "project",
                sessionID: "session"
            ).userInfo,
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ))
    }

    @MainActor
    func testApprovalInboxPublishesChangesToNotificationPageObserver() throws {
        let adapter = SessionNotificationResponseAdapter()
        var pageRefreshes = 0
        let observation = adapter.objectWillChange.sink { _ in pageRefreshes += 1 }
        XCTAssertTrue(adapter.approvalInbox.receive(
            userInfo: payload(overrides: ["approval_kind": "permission"]),
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ))
        let delivery = try XCTUnwrap(adapter.approvalInbox.pending)
        XCTAssertNil(delivery.decision, "点击权限通知本身只打开会话，不提交权限决策")
        XCTAssertEqual(pageRefreshes, 1, "没有其他页面变化时，通知仍须触发 RootView 路由任务")
        adapter.approvalInbox.consume(delivery)
        XCTAssertEqual(pageRefreshes, 2)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testInboxConsumeClearsOnlyMatchingDelivery() throws {
        let inbox = LockScreenApprovalInbox()
        inbox.receive(userInfo: payload(), actionIdentifier: LockScreenApprovalCategory.allowActionID)
        let delivery = try XCTUnwrap(inbox.pending)
        inbox.consume(delivery)
        XCTAssertNil(inbox.pending)

        inbox.receive(userInfo: payload(), actionIdentifier: LockScreenApprovalCategory.denyActionID)
        inbox.consume(delivery)
        XCTAssertNotNil(inbox.pending, "过期的消费不能清掉新入队的动作")
    }

    @MainActor
    func testInboxKeepsTaskIdentityUntilAsynchronousRoutingFinishes() async throws {
        let inbox = LockScreenApprovalInbox()
        inbox.receive(userInfo: payload(), actionIdentifier: LockScreenApprovalCategory.allowActionID)
        let delivery = try XCTUnwrap(inbox.pending)
        await inbox.processPending { current in
            XCTAssertEqual(current, delivery)
            XCTAssertEqual(inbox.pending, delivery)
            await Task.yield()
            XCTAssertEqual(inbox.pending, delivery, "网络等待期间不能改变 SwiftUI task id")
            return .handled
        }
        XCTAssertNil(inbox.pending)
    }

    @MainActor
    func testInboxCancelledRoutingPreservesPendingNotification() async throws {
        let inbox = LockScreenApprovalInbox()
        inbox.receive(userInfo: payload(), actionIdentifier: UNNotificationDefaultActionIdentifier)
        let delivery = try XCTUnwrap(inbox.pending)
        let task = Task { @MainActor in
            await inbox.processPending { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                await Task.yield()
                return .handled
            }
        }
        await task.value
        XCTAssertEqual(inbox.pending, delivery, "切回后台后仍须保留通知，供下次恢复继续打开")
    }

    @MainActor
    func testInboxRoutingCompletionKeepsNewerNotification() async throws {
        let inbox = LockScreenApprovalInbox()
        inbox.receive(userInfo: payload(), actionIdentifier: LockScreenApprovalCategory.allowActionID)
        await inbox.processPending { _ in
            await Task.yield()
            inbox.receive(userInfo: payload(), actionIdentifier: LockScreenApprovalCategory.denyActionID)
            return .handled
        }
        XCTAssertEqual(inbox.pending?.decision, .deny)
    }

    /// 结果必须如实展示。把冲突或超时显示成成功，比不显示更危险。
    @MainActor
    func testDecisionMessagesDistinguishOutcomes() {
        func message(outcome: String?, decision: String? = nil) -> String {
            LockScreenApprovalStore.message(for: PushDecisionResponse(
                outcome: outcome,
                state: nil,
                decision: decision,
                runtime: "codex",
                reason: nil
            ))
        }
        XCTAssertEqual(message(outcome: "proceed", decision: "allow"), L10n.text("ui.push_approval_allowed"))
        XCTAssertEqual(message(outcome: "proceed", decision: "deny"), L10n.text("ui.push_approval_denied"))
        XCTAssertEqual(message(outcome: "idempotent"), L10n.text("ui.push_approval_already_handled"))
        XCTAssertEqual(message(outcome: "conflict"), L10n.text("ui.push_approval_conflict"))
        XCTAssertEqual(message(outcome: "gone"), L10n.text("ui.push_approval_expired"))
        XCTAssertEqual(message(outcome: "forbidden"), L10n.text("ui.push_approval_device_not_allowed"))
        XCTAssertEqual(message(outcome: nil), L10n.text("ui.push_approval_result_unknown"))
    }

    /// sandbox 与 production 的 Device Token 不通用，选错不会报错、只会静默失败。
    /// 因此环境判定以描述文件为准，读不到才退回构建配置。
    func testPushEnvironmentPrefersProvisioningProfile() throws {
        let profile = try XCTUnwrap(Self.makeProvisioningProfile(apsEnvironment: "production"))
        XCTAssertEqual(
            PushEnvironment.current(provisioningProfile: profile, isDebugBuild: true),
            .production,
            "描述文件声明 production 时不能因为是 Debug 构建就用 sandbox"
        )
        let development = try XCTUnwrap(Self.makeProvisioningProfile(apsEnvironment: "development"))
        XCTAssertEqual(
            PushEnvironment.current(provisioningProfile: development, isDebugBuild: false),
            .sandbox
        )
        XCTAssertEqual(PushEnvironment.current(provisioningProfile: nil, isDebugBuild: true), .sandbox)
        XCTAssertEqual(PushEnvironment.current(provisioningProfile: nil, isDebugBuild: false), .production)
        XCTAssertEqual(
            PushEnvironment.current(provisioningProfile: Data("not a profile".utf8), isDebugBuild: false),
            .production
        )
    }

    /// 披露清单是用户唯一能看到的数据边界说明，所有条目都必须真的有文案。
    func testDisclosureKeysAreLocalized() {
        let keys = LockScreenApprovalDisclosure.leavesDeviceKeys
            + LockScreenApprovalDisclosure.staysOnDeviceKeys
        for key in keys {
            XCTAssertNotEqual(L10n.text(key, language: .simplifiedChinese), key, "缺少中文文案：\(key)")
            XCTAssertNotEqual(L10n.text(key, language: .english), key, "缺少英文文案：\(key)")
        }
    }

    /// Provider 的可见提醒只发本地化 key。App 里少一条，锁屏上就会出现裸 key。
    func testPushNotificationLocalizationKeysExist() {
        let keys = [
            "push.message.title.codex",
            "push.message.title.claude",
            "push.message.body.completed",
            "push.message.body.failed",
            "push.message.body.interrupted",
            "push.approval.title.codex",
            "push.approval.title.claude",
            "push.approval.body.command",
            "push.approval.body.patch",
            "push.approval.body.permission",
            "push.approval.body.user_input",
            "push.approval.body.elicitation",
        ]
        for key in keys {
            for language in [AppLanguage.simplifiedChinese, .english] {
                let value = L10n.text(key, language: language)
                XCTAssertNotEqual(value, key, "缺少文案：\(key) (\(language.rawValue))")
                if key.hasPrefix("push.approval.") {
                    XCTAssertTrue(value.contains("%@"), "\(key) 必须保留匿名标签占位符")
                } else {
                    XCTAssertFalse(value.contains("%@"), "回复通知没有正文或标签参数")
                }
            }
        }
    }

    /// 通知扩展命中标题缓存后改用 `.titled` 正文（gh-418）。这些 key 只在设备上由
    /// 扩展查表渲染，没有任何参数：标题已经标识会话，不再拼「· 会话 7D92」。
    func testTitledPushNotificationLocalizationKeysExist() {
        let keys = [
            "push.message.body.completed.titled",
            "push.message.body.failed.titled",
            "push.message.body.interrupted.titled",
            "push.approval.body.command.titled",
            "push.approval.body.patch.titled",
            "push.approval.body.permission.titled",
            "push.approval.body.user_input.titled",
            "push.approval.body.elicitation.titled",
        ]
        for key in keys {
            for language in [AppLanguage.simplifiedChinese, .english] {
                let value = L10n.text(key, language: language)
                XCTAssertNotEqual(value, key, "缺少文案：\(key) (\(language.rawValue))")
                XCTAssertFalse(value.contains("%@"), "\(key) 由扩展直接查表渲染，不能带占位符")
                XCTAssertFalse(value.isEmpty)
            }
        }
    }

	/// disable 入队前构造的 client 只能操作当时绑定的 Profile。等待期间绑定切换后，
	/// 旧操作必须在发出网络请求前失败，并保留当前绑定。
	@MainActor
	func testDisableRejectsClientForStaleProfile() async throws {
		let suiteName = "LockScreenApprovalTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		defaults.set(true, forKey: "lockScreenApproval.enabled")
		defaults.set("dev-legacy-current", forKey: "lockScreenApproval.deviceID")
		defaults.set("ins-legacy-current", forKey: "lockScreenApproval.installation")
		defaults.set("profile-current", forKey: "lockScreenApproval.registeredProfileID")
		defaults.set("https://provider-current.example/mimi-push", forKey: "lockScreenApproval.registeredProviderURL")
		defaults.set(Date().addingTimeInterval(3600), forKey: "lockScreenApproval.ticketExpiresAt")

		NoLockScreenApprovalRequestURLProtocol.reset()
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [NoLockScreenApprovalRequestURLProtocol.self]
		let client = AgentAPIClient(
			endpoint: "https://agentd.example",
			token: "test-token",
			session: URLSession(configuration: configuration)
		)
		let keychain = TestKeychainOperations()
		keychain.setData(Data("ticket-current".utf8), account: "push-ticket")
		let store = LockScreenApprovalStore(
			defaults: defaults,
			ticketStore: PushTicketStore(keychain: keychain),
			identityStore: PushInstallationIdentityStore(keychain: keychain)
		)

		await store.disable(client: client, profileID: "profile-stale")

		XCTAssertEqual(NoLockScreenApprovalRequestURLProtocol.requestCount, 0)
		XCTAssertTrue(store.isEnabled)
		XCTAssertEqual(store.registeredProfileID, "profile-current")
		guard case .failed = store.status else {
			return XCTFail("旧 Profile 的 disable 应 fail closed")
		}
	}

	/// 两个 Profile 的 push/status 可以并发返回，Provider 身份必须按 Profile 保存，
	/// 不能让最后完成的响应覆盖另一条连接的收件主机。
	@MainActor
	func testHostSupportIsScopedToProfile() async throws {
		let suiteName = "LockScreenApprovalTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [ProfilePushStatusURLProtocol.self]
		let session = URLSession(configuration: configuration)
		let keychain = TestKeychainOperations()
		let store = LockScreenApprovalStore(
			defaults: defaults,
			ticketStore: PushTicketStore(keychain: keychain),
			identityStore: PushInstallationIdentityStore(keychain: keychain)
		)
		let clientA = AgentAPIClient(endpoint: "https://profile-a.example", token: "a", session: session)
		let clientB = AgentAPIClient(endpoint: "https://profile-b.example", token: "b", session: session)

		async let refreshA: Void = store.refreshHostSupport(client: clientA, profileID: "profile-a")
		async let refreshB: Void = store.refreshHostSupport(client: clientB, profileID: "profile-b")
		_ = await (refreshA, refreshB)

		XCTAssertEqual(store.providerHost(for: "profile-a"), "provider-a.example")
		XCTAssertEqual(store.providerHost(for: "profile-b"), "provider-b.example")
		XCTAssertTrue(store.hostSupportsPush(for: "profile-a"))
		XCTAssertTrue(store.hostSupportsPush(for: "profile-b"))
	}

    @MainActor
    func testProviderPathChangeRequiresFreshConsentAndDoesNotRefreshTicket() async throws {
        let suite = "LockScreenApprovalTests.ProviderChange.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ProfilePushStatusURLProtocol.reset()
        defer { ProfilePushStatusURLProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProfilePushStatusURLProtocol.self]
        let client = AgentAPIClient(endpoint: "https://profile-a.example", token: "a", session: URLSession(configuration: config))
        let keychain = TestKeychainOperations()
        let identityStore = PushInstallationIdentityStore(keychain: keychain)
        try identityStore.save(.make())
        let tickets = PushTicketStore(keychain: keychain)
        try tickets.save("existing-ticket")
        defaults.set(true, forKey: "lockScreenApproval.enabled")
        defaults.set("profile-a", forKey: "lockScreenApproval.registeredProfileID")
        defaults.set("https://provider-a.example/mimi-push", forKey: "lockScreenApproval.registeredProviderURL")
        defaults.set(Date().addingTimeInterval(86400), forKey: "lockScreenApproval.ticketExpiresAt")
        let store = LockScreenApprovalStore(defaults: defaults, ticketStore: tickets, identityStore: identityStore)
        await store.refreshHostSupport(client: client, profileID: "profile-a")
        store.recordConsent(for: "profile-a")
        XCTAssertTrue(store.hasConsented(for: "profile-a"))
        ProfilePushStatusURLProtocol.setProvider("https://provider-a.example/new-provider", for: "profile-a.example")
        await store.refreshHostSupport(client: client, profileID: "profile-a")
        XCTAssertFalse(store.hasConsented(for: "profile-a"))
        await store.refreshTicketIfNeeded(client: client, profileID: "profile-a")
        XCTAssertEqual(try tickets.loadRequired(), "existing-ticket")
        XCTAssertEqual(ProfilePushStatusURLProtocol.recordedRequestPaths, ["/api/push/status", "/api/push/status"])
        guard case .failed = store.status else { return XCTFail("Provider 变更后应等待重新同意") }
    }

    private static func makeProvisioningProfile(apsEnvironment: String) -> Data? {
        let plist: [String: Any] = ["Entitlements": ["aps-environment": apsEnvironment]]
        guard let encoded = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else {
            return nil
        }
        // 真实描述文件是 CMS 信封，plist 夹在中间。构造同样的形状来验证定位逻辑。
        var envelope = Data("SIGNATURE-PREFIX".utf8)
        envelope.append(encoded)
        envelope.append(Data("SIGNATURE-SUFFIX".utf8))
        return envelope
    }
}

private final class NoLockScreenApprovalRequestURLProtocol: URLProtocol {
	private static let lock = NSLock()
	private static var requestCountStorage = 0

	static var requestCount: Int {
		lock.lock()
		defer { lock.unlock() }
		return requestCountStorage
	}

	static func reset() {
		lock.lock()
		requestCountStorage = 0
		lock.unlock()
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		Self.lock.lock()
		Self.requestCountStorage += 1
		Self.lock.unlock()
		client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
	}

	override func stopLoading() {}
}

private final class ProfilePushStatusURLProtocol: URLProtocol {
	private static let lock = NSLock()
	private static var providerOverrides: [String: String] = [:]
	private static var requestPaths: [String] = []

	static func setProviderURL(_ providerURL: String?, for sourceHost: String) {
		lock.lock()
		defer { lock.unlock() }
		providerOverrides[sourceHost] = providerURL
	}

	static func reset() {
		lock.lock()
		providerOverrides.removeAll()
		requestPaths.removeAll()
		lock.unlock()
	}

	static func setProvider(_ url: String, for host: String) {
		lock.lock()
		providerOverrides[host] = url
		lock.unlock()
	}

	static var recordedRequestPaths: [String] {
		lock.lock()
		defer { lock.unlock() }
		return requestPaths
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let url = request.url,
		      let sourceHost = url.host,
		      let response = HTTPURLResponse(
				url: url,
				statusCode: 200,
				httpVersion: "HTTP/1.1",
				headerFields: ["Content-Type": "application/json"]
		      ) else {
			client?.urlProtocol(self, didFailWithError: URLError(.badURL))
			return
		}
		Self.lock.lock()
		Self.requestPaths.append(url.path)
		let providerOverride = Self.providerOverrides[sourceHost]
		Self.lock.unlock()
		let providerHost = sourceHost == "profile-a.example" ? "provider-a.example" : "provider-b.example"
		let providerURL = providerOverride ?? "https://\(providerHost)/mimi-push"
		let body = """
		{"enabled":true,"provider_configured":true,"provider_url":"\(providerURL)"}
		"""
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: Data(body.utf8))
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

extension LockScreenApprovalTests {
    /// agentd 用 HTTP 状态码表达确定结论。把它们一并说成「未知」是在撒谎——
    /// 设计上明确要求 UI 能表达「已被其他设备处理」「已过期」这些状态。
    @MainActor
    func testServerStatusesAreNotCollapsedIntoUnknown() {
        func message(_ status: Int) -> String {
            LockScreenApprovalStore.message(forServerError: .server(status: status, message: ""))
        }
        XCTAssertEqual(message(404), L10n.text("ui.push_approval_expired"))
        XCTAssertEqual(message(410), L10n.text("ui.push_approval_expired"))
        XCTAssertEqual(message(409), L10n.text("ui.push_approval_conflict"))
        XCTAssertEqual(message(403), L10n.text("ui.push_approval_device_not_allowed"))
        // 502 是 agentd 够到了但 runtime 没够到，那才是真正的未知。
        XCTAssertEqual(message(502), L10n.text("ui.push_approval_result_unknown"))
        XCTAssertEqual(
            LockScreenApprovalStore.message(forServerError: .invalidResponse),
            L10n.text("ui.push_approval_result_unknown")
        )
    }

    /// 确定结论之后那张通知不再可操作，必须撤下；未知则保留，让用户能重试。
    @MainActor
    func testOnlyDefinitiveOutcomesClearTheNotification() {
        for status in [403, 404, 409, 410] {
            XCTAssertTrue(
                LockScreenApprovalStore.isDefinitive(.server(status: status, message: "")),
                "\(status) 应视为确定结论"
            )
        }
        XCTAssertFalse(LockScreenApprovalStore.isDefinitive(.server(status: 502, message: "")))
        XCTAssertFalse(LockScreenApprovalStore.isDefinitive(.server(status: 202, message: "busy")))
        XCTAssertFalse(LockScreenApprovalStore.isDefinitive(.invalidResponse))
    }
}

// MARK: - #417 通知路由：收件箱结论、定位响应解码与对账判定

extension LockScreenApprovalTests {
    @MainActor
    func testInboxKeepsPendingWhenHandlerAsksToRetryLater() async throws {
        let inbox = LockScreenApprovalInbox()
        inbox.receive(userInfo: payload(), actionIdentifier: UNNotificationDefaultActionIdentifier)
        let delivery = try XCTUnwrap(inbox.pending)
        await inbox.processPending { _ in .retryLater }
        XCTAssertEqual(inbox.pending, delivery, "恢复失败时通知必须留在收件箱，等下一次前台重试")

        await inbox.processPending { _ in .handled }
        XCTAssertNil(inbox.pending, "只有 handled 才消费")
    }

    /// 合成的 CancellationError（凭据代次变化、切换主机）不等于任务被取消：
    /// 任务仍在跑就要如实报错并消费；真取消才静默保留。
    @MainActor
    func testSyntheticCancellationIsHandledWhileRealCancellationRetriesLater() async throws {
        let inbox = LockScreenApprovalInbox()
        inbox.receive(userInfo: payload(), actionIdentifier: UNNotificationDefaultActionIdentifier)
        let delivery = try XCTUnwrap(inbox.pending)
        let notification = delivery.notification

        var reportedMessage: String?
        await inbox.processPending { _ in
            do {
                throw CancellationError()
            } catch {
                guard !Task.isCancelled else { return .retryLater }
                reportedMessage = LockScreenApprovalRouting.detailsErrorMessage(error, for: notification)
                return .handled
            }
        }
        XCTAssertNil(inbox.pending, "合成取消时任务没被取消，应当报错并消费")
        XCTAssertEqual(reportedMessage, L10n.text("ui.push_route_connection_not_restored"))

        inbox.receive(userInfo: payload(), actionIdentifier: UNNotificationDefaultActionIdentifier)
        let second = try XCTUnwrap(inbox.pending)
        var secondMessage: String?
        let task = Task { @MainActor in
            await inbox.processPending { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    throw CancellationError()
                } catch {
                    guard !Task.isCancelled else { return .retryLater }
                    secondMessage = LockScreenApprovalRouting.detailsErrorMessage(error, for: notification)
                    return .handled
                }
            }
        }
        await task.value
        XCTAssertEqual(inbox.pending, second, "真取消保留通知")
        XCTAssertNil(secondMessage, "真取消不弹提示")
    }

    func testPushActionRouteResponseDecodesWithAndWithoutNewFields() throws {
        let legacy = """
        {"runtime":"codex","thread_id":"thread-1","project_id":"proj-1"}
        """
        let decodedLegacy = try AgentAPIClient.decoder.decode(PushActionRouteResponse.self, from: Data(legacy.utf8))
        XCTAssertEqual(decodedLegacy, PushActionRouteResponse(runtime: "codex", threadID: "thread-1", projectID: "proj-1"))
        XCTAssertNil(decodedLegacy.scopeID)
        XCTAssertNil(decodedLegacy.cwd)
        XCTAssertNil(decodedLegacy.kind)
        XCTAssertNil(decodedLegacy.state)
        XCTAssertNil(decodedLegacy.threadAuthorized)

        let full = """
        {"runtime":"claude","thread_id":"thread-2","project_id":"","scope_id":"ws_abc","cwd":"/Users/me/repo","kind":"approval","state":"approved","thread_authorized":true}
        """
        let decodedFull = try AgentAPIClient.decoder.decode(PushActionRouteResponse.self, from: Data(full.utf8))
        XCTAssertEqual(decodedFull.runtime, "claude")
        XCTAssertEqual(decodedFull.threadID, "thread-2")
        XCTAssertEqual(decodedFull.projectID, "")
        XCTAssertEqual(decodedFull.scopeID, "ws_abc")
        XCTAssertEqual(decodedFull.cwd, "/Users/me/repo")
        XCTAssertEqual(decodedFull.kind, "approval")
        XCTAssertEqual(decodedFull.state, "approved")
        XCTAssertEqual(decodedFull.threadAuthorized, true)
    }

    /// 对账不能再把回复通知的 404 当成“已处理”删掉：agentd 重启后记录丢失，任务本身还在。
    @MainActor
    func testReconcileRemovesMessageNotificationsOnlyWhenExpired() throws {
        let message = try XCTUnwrap(LockScreenApprovalNotification(
            userInfo: payload(overrides: ["event": "turn.completed", "approval_kind": ""])
        ))
        func remove(_ result: Result<PushActionRouteResponse, Error>) -> Bool {
            LockScreenApprovalStore.shouldRemoveDeliveredNotification(message, afterLocate: result)
        }
        XCTAssertFalse(remove(.failure(AgentAPIError.server(status: 404, message: ""))), "404 可能只是旧版 agentd 或记录丢失")
        XCTAssertTrue(remove(.failure(AgentAPIError.server(status: 410, message: ""))), "410 才是超过保留时间")
        XCTAssertFalse(remove(.failure(AgentAPIError.server(status: 403, message: ""))))
        XCTAssertFalse(remove(.failure(AgentAPIError.server(status: 409, message: ""))))
        XCTAssertFalse(remove(.failure(URLError(.notConnectedToInternet))))
        XCTAssertFalse(remove(.success(PushActionRouteResponse(runtime: "codex", threadID: "t", projectID: "p", kind: "message"))))
        XCTAssertFalse(remove(.success(PushActionRouteResponse(
            runtime: "codex", threadID: "t", projectID: "p", kind: "approval", state: "approved"
        ))), "回复通知不因为字段异常而被误删")
    }

    @MainActor
    func testReconcileRemovesApprovalsOnDefinitiveStatusesAndTerminalStates() throws {
        let approval = try XCTUnwrap(LockScreenApprovalNotification(userInfo: payload()))
        func remove(_ result: Result<PushActionRouteResponse, Error>) -> Bool {
            LockScreenApprovalStore.shouldRemoveDeliveredNotification(approval, afterLocate: result)
        }
        for status in [403, 404, 409, 410] {
            XCTAssertTrue(remove(.failure(AgentAPIError.server(status: status, message: ""))), "\(status) 应撤下审批通知")
        }
        XCTAssertFalse(remove(.failure(AgentAPIError.server(status: 502, message: ""))))
        XCTAssertFalse(remove(.failure(URLError(.timedOut))))
        for state in ["approved", "rejected", "expired", "revoked"] {
            XCTAssertTrue(remove(.success(PushActionRouteResponse(
                runtime: "codex", threadID: "t", projectID: "p", kind: "approval", state: state
            ))), "终态 \(state) 应撤下审批通知")
        }
        XCTAssertFalse(remove(.success(PushActionRouteResponse(
            runtime: "codex", threadID: "t", projectID: "p", kind: "approval", state: "pending"
        ))))
        XCTAssertFalse(remove(.success(PushActionRouteResponse(
            runtime: "codex", threadID: "t", projectID: "p", kind: "approval", state: "unknown"
        ))))
        XCTAssertFalse(remove(.success(PushActionRouteResponse(runtime: "codex", threadID: "t", projectID: "p"))), "旧版 agentd 的 200 没有状态，保留")
        XCTAssertFalse(remove(.success(PushActionRouteResponse(
            runtime: "codex", threadID: "t", projectID: "p", kind: "message", state: "approved"
        ))), "类型对不上时不删")
    }
}

// MARK: - 旧电脑联系不上时的换绑与关闭（gh-432）

extension LockScreenApprovalTests {
    private struct RebindFixture {
        let defaults: UserDefaults
        let suite: String
        let session: URLSession
        let store: LockScreenApprovalStore
        let tickets: PushTicketStore
        let newClient: AgentAPIClient
        let oldClient: AgentAPIClient

        func tearDown() {
            defaults.removePersistentDomain(forName: suite)
            RebindURLProtocol.reset()
        }
    }

    /// 绑定在 profile-old 上，当前电脑是 profile-new；两台电脑共用同一个 Provider。
    @MainActor
    private func makeRebindFixture(
        clearTitleCache: @escaping () -> Void = {}
    ) async throws -> RebindFixture {
        let suite = "LockScreenApprovalTests.Rebind.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        RebindURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RebindURLProtocol.self]
        let session = URLSession(configuration: config)
        let keychain = TestKeychainOperations()
        let identityStore = PushInstallationIdentityStore(keychain: keychain)
        try identityStore.save(.make())
        let tickets = PushTicketStore(keychain: keychain)
        try tickets.save("ticket-old")
        defaults.set(true, forKey: "lockScreenApproval.enabled")
        defaults.set("profile-old", forKey: "lockScreenApproval.registeredProfileID")
        defaults.set(RebindURLProtocol.providerURL, forKey: "lockScreenApproval.registeredProviderURL")
        defaults.set(Date().addingTimeInterval(86400), forKey: "lockScreenApproval.ticketExpiresAt")
        let store = LockScreenApprovalStore(
            defaults: defaults,
            ticketStore: tickets,
            identityStore: identityStore,
            clearNotificationTitleCache: clearTitleCache,
            providerClientFactory: { PushProviderClient(baseURL: $0, session: session) },
            requestAuthorization: { true }
        )
        let newClient = AgentAPIClient(endpoint: "https://profile-new.example", token: "new", session: session)
        let oldClient = AgentAPIClient(endpoint: "https://profile-old.example", token: "old", session: session)
        await store.refreshHostSupport(client: newClient, profileID: "profile-new")
        store.recordConsent(for: "profile-new")
        XCTAssertTrue(store.hasConsented(for: "profile-new"))
        store.handleDeviceToken(Data([0xAB, 0xCD, 0xEF]))
        RebindURLProtocol.clearRecordedRequests()
        return RebindFixture(
            defaults: defaults,
            suite: suite,
            session: session,
            store: store,
            tickets: tickets,
            newClient: newClient,
            oldClient: oldClient
        )
    }

    /// 旧档案已删或凭据缺失时构造不出旧 client：不发任何请求，旧绑定原样保留，
    /// 状态明确告诉 UI“旧电脑联系不上”，而不是要求用户回到一台不存在的电脑。
    @MainActor
    func testEnableWithoutPreviousClientReportsPreviousHostUnavailableWithoutRequests() async throws {
        let fixture = try await makeRebindFixture()
        defer { fixture.tearDown() }

        await fixture.store.enable(client: fixture.newClient, profileID: "profile-new")

        XCTAssertEqual(fixture.store.status, .previousHostUnavailable)
        XCTAssertEqual(RebindURLProtocol.recordedRequests, [])
        XCTAssertTrue(fixture.store.isEnabled)
        XCTAssertEqual(fixture.store.registeredProfileID, "profile-old")
        XCTAssertEqual(try fixture.tickets.loadRequired(), "ticket-old")
    }

    /// 旧 agentd 拒绝注销（重装后 Token 失效的典型表现）：撤销刚签发的新 Ticket、
    /// 保留旧绑定，并进入“旧电脑联系不上”状态，而不是把 401 原样丢给用户。
    @MainActor
    func testPreviousHostRejectingUnregisterRollsBackAndReportsPreviousHostUnavailable() async throws {
        let fixture = try await makeRebindFixture()
        defer { fixture.tearDown() }
        RebindURLProtocol.fail("DELETE profile-old.example /api/push/devices", status: 401)

        await fixture.store.enable(
            client: fixture.newClient,
            profileID: "profile-new",
            previousClient: fixture.oldClient,
            previousClientProfileID: "profile-old"
        )

        XCTAssertEqual(fixture.store.status, .previousHostUnavailable)
        XCTAssertTrue(fixture.store.isEnabled)
        XCTAssertEqual(fixture.store.registeredProfileID, "profile-old")
        XCTAssertEqual(try fixture.tickets.loadRequired(), "ticket-old")
        let requests = RebindURLProtocol.recordedRequests
        XCTAssertTrue(requests.contains("DELETE profile-old.example /api/push/devices"), "\(requests)")
        XCTAssertFalse(requests.contains("POST profile-new.example /api/push/devices"), "新电脑不应被注册：\(requests)")
        XCTAssertEqual(RebindURLProtocol.revokedTickets, ["ticket-new"], "只能撤销刚签发的新 Ticket")
    }

    /// 用户确认换绑：不再联系旧 agentd，先在 Provider 撤销旧 Ticket，再为当前电脑注册。
    @MainActor
    func testTakeoverRevokesOldTicketAtProviderThenRegistersCurrentComputer() async throws {
        let fixture = try await makeRebindFixture()
        defer { fixture.tearDown() }

        await fixture.store.enable(
            client: fixture.newClient,
            profileID: "profile-new",
            takeOverPreviousBinding: true
        )

        guard case .active = fixture.store.status else {
            return XCTFail("换绑后应处于 active，实际：\(fixture.store.status)")
        }
        XCTAssertTrue(fixture.store.isEnabled)
        XCTAssertEqual(fixture.store.registeredProfileID, "profile-new")
        XCTAssertEqual(fixture.store.registeredProviderURL, RebindURLProtocol.providerURL)
        XCTAssertEqual(try fixture.tickets.loadRequired(), "ticket-new")
        XCTAssertEqual(RebindURLProtocol.revokedTickets, ["ticket-old"])
        XCTAssertEqual(
            RebindURLProtocol.recordedRequests,
            [
                "POST provider.example /mimi-push/v1/ticket/revoke",
                "POST provider.example /mimi-push/v1/ticket",
                "POST profile-new.example /api/push/devices",
            ]
        )
    }

    /// Provider 撤销失败时必须原样保留旧绑定：不签发新 Ticket、不注册新电脑、不清本地。
    @MainActor
    func testTakeoverKeepsOldBindingWhenProviderRevokeFails() async throws {
        let fixture = try await makeRebindFixture()
        defer { fixture.tearDown() }
        RebindURLProtocol.fail("POST provider.example /mimi-push/v1/ticket/revoke", status: 503)

        await fixture.store.enable(
            client: fixture.newClient,
            profileID: "profile-new",
            takeOverPreviousBinding: true
        )

        XCTAssertEqual(
            fixture.store.status,
            .failed(message: L10n.text("ui.push_previous_binding_revoke_failed"))
        )
        XCTAssertTrue(fixture.store.isEnabled)
        XCTAssertEqual(fixture.store.registeredProfileID, "profile-old")
        XCTAssertEqual(try fixture.tickets.loadRequired(), "ticket-old")
        XCTAssertEqual(
            RebindURLProtocol.recordedRequests,
            ["POST provider.example /mimi-push/v1/ticket/revoke"]
        )
    }

    /// 旧 Ticket 已撤销、新电脑注册失败：结果就是关闭态，必须和正常关闭一样清掉
    /// 标题缓存与残留卡片，并撤销刚签发的新 Ticket，不留下半开的绑定。
    @MainActor
    func testTakeoverCleansUpOffStateWhenNewRegistrationFails() async throws {
        final class Counter { var value = 0 }
        let clears = Counter()
        let fixture = try await makeRebindFixture(clearTitleCache: { clears.value += 1 })
        defer { fixture.tearDown() }
        RebindURLProtocol.fail("POST profile-new.example /api/push/devices", status: 500)

        await fixture.store.enable(
            client: fixture.newClient,
            profileID: "profile-new",
            takeOverPreviousBinding: true
        )

        guard case .failed = fixture.store.status else {
            return XCTFail("新注册失败应给出失败状态，实际：\(fixture.store.status)")
        }
        XCTAssertFalse(fixture.store.isEnabled)
        XCTAssertNil(fixture.store.registeredProfileID)
        XCTAssertNil(fixture.tickets.load())
        XCTAssertEqual(clears.value, 1, "关闭态必须清掉通知标题缓存")
        XCTAssertEqual(RebindURLProtocol.revokedTickets, ["ticket-old", "ticket-new"])
    }

    /// 旧电脑联系不上时也能关闭：Provider 撤销成功后清掉本地绑定，不再要求旧 agentd 注销。
    @MainActor
    func testDisableWithoutPreviousHostRevokesAtProviderAndClearsBinding() async throws {
        let fixture = try await makeRebindFixture()
        defer { fixture.tearDown() }

        await fixture.store.disable(client: nil, profileID: "profile-old", previousHostUnavailable: true)

        XCTAssertEqual(fixture.store.status, .off)
        XCTAssertFalse(fixture.store.isEnabled)
        XCTAssertNil(fixture.store.registeredProfileID)
        XCTAssertNil(fixture.store.registeredProviderURL)
        XCTAssertNil(fixture.tickets.load())
        XCTAssertEqual(RebindURLProtocol.revokedTickets, ["ticket-old"])
        XCTAssertEqual(
            RebindURLProtocol.recordedRequests,
            ["POST provider.example /mimi-push/v1/ticket/revoke"]
        )
    }

    /// 没有旧 client 且没有明确标记“旧电脑联系不上”时仍然 fail closed，行为不变。
    @MainActor
    func testDisableWithoutClientStillFailsClosedUnlessPreviousHostFlagged() async throws {
        let fixture = try await makeRebindFixture()
        defer { fixture.tearDown() }
        RebindURLProtocol.fail("POST provider.example /mimi-push/v1/ticket/revoke", status: 503)

        await fixture.store.disable(client: nil, profileID: "profile-old")
        guard case .failed = fixture.store.status else {
            return XCTFail("未标记旧电脑不可达时不能只清本地痕迹")
        }
        XCTAssertEqual(RebindURLProtocol.recordedRequests, [])

        await fixture.store.disable(client: nil, profileID: "profile-old", previousHostUnavailable: true)
        XCTAssertEqual(
            fixture.store.status,
            .failed(message: L10n.text("ui.push_previous_binding_revoke_failed"))
        )
        XCTAssertTrue(fixture.store.isEnabled)
        XCTAssertEqual(fixture.store.registeredProfileID, "profile-old")
        XCTAssertEqual(try fixture.tickets.loadRequired(), "ticket-old")
    }

    func testRebindLocalizationKeysExist() {
        let keys = [
            "ui.push_previous_host_unavailable",
            "ui.push_rebind_to_this_computer",
            "ui.push_rebind_confirm_title",
            "ui.push_rebind_confirm_message",
            "ui.push_previous_binding_revoke_failed",
            "ui.push_turn_off_previous_binding",
        ]
        for key in keys {
            XCTAssertNotEqual(L10n.text(key, language: .simplifiedChinese), key, "缺少中文文案：\(key)")
            XCTAssertNotEqual(L10n.text(key, language: .english), key, "缺少英文文案：\(key)")
        }
    }
}

/// 同时扮演两台 agentd 和一个 Provider：按“方法 主机 路径”记录请求，并可让指定请求失败。
private final class RebindURLProtocol: URLProtocol {
    static let providerURL = "https://provider.example/mimi-push"

    private static let lock = NSLock()
    private static var requests: [String] = []
    private static var revoked: [String] = []
    private static var failures: [String: Int] = [:]

    static var recordedRequests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static var revokedTickets: [String] {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }

    static func fail(_ key: String, status: Int) {
        lock.lock()
        failures[key] = status
        lock.unlock()
    }

    static func clearRecordedRequests() {
        lock.lock()
        requests.removeAll()
        revoked.removeAll()
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        requests.removeAll()
        revoked.removeAll()
        failures.removeAll()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let key = "\(method) \(host) \(url.path)"
        let body = Self.readBody(of: request)
        Self.lock.lock()
        Self.requests.append(key)
        if url.path.hasSuffix("/v1/ticket/revoke"),
           let body,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let ticket = object["ticket"] as? String {
            Self.revoked.append(ticket)
        }
        let failure = Self.failures[key]
        Self.lock.unlock()

        let status = failure ?? 200
        let payload: String
        switch url.path {
        case let path where path.hasSuffix("/api/push/status"):
            payload = #"{"enabled":true,"provider_configured":true,"provider_url":"\#(Self.providerURL)"}"#
        case let path where path.hasSuffix("/api/push/devices") && method == "POST":
            payload = #"{"device_id":"dev","expires_at":"2099-01-01T00:00:00Z","needs_refresh":false}"#
        case let path where path.hasSuffix("/api/push/devices"):
            payload = #"{"removed":true}"#
        case let path where path.hasSuffix("/v1/ticket/revoke"):
            payload = "{}"
        case let path where path.hasSuffix("/v1/ticket"):
            payload = #"{"ticket":"ticket-new","expires_at":"2099-01-01T00:00:00Z"}"#
        default:
            payload = "{}"
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((status == 200 ? payload : #"{"error":"stubbed failure"}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
