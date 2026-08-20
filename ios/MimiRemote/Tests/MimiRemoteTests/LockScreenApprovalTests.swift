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
        XCTAssertEqual(first.notificationIdentifier, second.notificationIdentifier)
        let other = try XCTUnwrap(
            LockScreenApprovalNotification(userInfo: payload(overrides: ["action_id": "act-other"]))
        )
        XCTAssertNotEqual(first.notificationIdentifier, other.notificationIdentifier)
    }

    /// 两个动作都必须要求系统身份验证：仅凭锁屏访问既不能放行命令，
    /// 也不该能中断别人正在跑的任务。
    func testBothActionsRequireDeviceAuthentication() throws {
        let category = LockScreenApprovalCategory.makeCategory()
        XCTAssertEqual(category.identifier, LockScreenApprovalCategory.identifier)
        XCTAssertEqual(category.actions.count, 2, "锁屏最多展示两个自定义动作，查看详情用点击通知完成")
        for action in category.actions {
            XCTAssertTrue(
                action.options.contains(.authenticationRequired),
                "\(action.identifier) 必须要求解锁"
            )
        }
        let deny = try XCTUnwrap(category.actions.first { $0.identifier == LockScreenApprovalCategory.denyActionID })
        XCTAssertTrue(deny.options.contains(.destructive))
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

    /// Provider 只发本地化 key。App 里少一条，锁屏上就会出现裸 key。
    func testPushNotificationLocalizationKeysExist() {
        let keys = [
            "push.approval.title.codex",
            "push.approval.title.claude",
            "push.approval.body.command",
            "push.approval.body.patch",
            "push.approval.body.permission",
            "push.approval.body.user_input",
            "push.approval.body.elicitation",
            "push.approval.resolved.title",
        ]
        for key in keys {
            for language in [AppLanguage.simplifiedChinese, .english] {
                let value = L10n.text(key, language: language)
                XCTAssertNotEqual(value, key, "缺少文案：\(key) (\(language.rawValue))")
                XCTAssertTrue(value.contains("%@"), "\(key) 必须保留匿名标签占位符")
            }
        }
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
        XCTAssertFalse(LockScreenApprovalStore.isDefinitive(.invalidResponse))
    }
}
