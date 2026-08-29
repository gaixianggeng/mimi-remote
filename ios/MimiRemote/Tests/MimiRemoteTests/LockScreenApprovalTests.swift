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
                XCTAssertTrue(value.contains("%@"), "\(key) 必须保留匿名标签占位符")
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
		defaults.set("profile-current", forKey: "lockScreenApproval.registeredProfileID")
		defaults.set(Date().addingTimeInterval(3600), forKey: "lockScreenApproval.ticketExpiresAt")

		NoLockScreenApprovalRequestURLProtocol.reset()
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [NoLockScreenApprovalRequestURLProtocol.self]
		let client = AgentAPIClient(
			endpoint: "https://agentd.example",
			token: "test-token",
			session: URLSession(configuration: configuration)
		)
		let store = LockScreenApprovalStore(
			defaults: defaults,
			ticketStore: PushTicketStore(keychain: TestKeychainOperations())
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
		let store = LockScreenApprovalStore(
			defaults: defaults,
			ticketStore: PushTicketStore(keychain: TestKeychainOperations())
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
		let providerHost = sourceHost == "profile-a.example"
			? "provider-a.example"
			: "provider-b.example"
		let body = """
		{"enabled":true,"provider_configured":true,"provider_url":"https://\(providerHost)/mimi-push"}
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
