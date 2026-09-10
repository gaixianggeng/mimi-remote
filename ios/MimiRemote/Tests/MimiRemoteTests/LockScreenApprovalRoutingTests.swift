import XCTest
@testable import MimiRemote

@MainActor
final class LockScreenApprovalRoutingTests: XCTestCase {
    func testExpiredDetailsDoNotClaimMacIsUnreachable() throws {
        let approval = try approvalNotification()
        XCTAssertEqual(
            LockScreenApprovalRouting.detailsErrorMessage(AgentAPIError.server(status: 410, message: "gone"), for: approval),
            L10n.text("ui.push_approval_expired")
        )
        XCTAssertEqual(
            LockScreenApprovalRouting.detailsErrorMessage(AgentAPIError.server(status: 403, message: "forbidden"), for: approval),
            L10n.text("ui.push_approval_device_not_allowed")
        )
        XCTAssertEqual(
            LockScreenApprovalRouting.detailsErrorMessage(URLError(.notConnectedToInternet), for: approval),
            L10n.text("ui.push_approval_result_unknown")
        )
    }

    /// 回复通知的 404/410 只是“定位记录没了”，任务本身还在列表里；
    /// 不能沿用审批的“这条请求已过期或已被处理”。
    func testMessageNotificationsUseLocateWordingInsteadOfApprovalWording() throws {
        let message = try messageNotification()
        let approval = try approvalNotification()
        for status in [404, 410] {
            XCTAssertNotEqual(
                LockScreenApprovalRouting.detailsErrorMessage(AgentAPIError.server(status: status, message: ""), for: message),
                LockScreenApprovalRouting.detailsErrorMessage(AgentAPIError.server(status: status, message: ""), for: approval),
                "\(status) 的回复通知与审批通知文案必须不同"
            )
        }
        XCTAssertEqual(
            LockScreenApprovalRouting.detailsErrorMessage(AgentAPIError.server(status: 404, message: ""), for: message),
            L10n.text("ui.push_message_route_missing")
        )
        XCTAssertEqual(
            LockScreenApprovalRouting.detailsErrorMessage(AgentAPIError.server(status: 410, message: ""), for: message),
            L10n.text("ui.push_message_route_expired")
        )
        XCTAssertEqual(
            LockScreenApprovalRouting.detailsErrorMessage(AgentAPIError.server(status: 404, message: ""), for: approval),
            L10n.text("ui.push_approval_expired")
        )
        XCTAssertEqual(
            LockScreenApprovalRouting.detailsErrorMessage(AgentAPIError.server(status: 410, message: ""), for: approval),
            L10n.text("ui.push_approval_expired")
        )
        XCTAssertEqual(
            LockScreenApprovalRouting.detailsErrorMessage(URLError(.notConnectedToInternet), for: message),
            L10n.text("ui.the_session_corresponding_to_the_notification_cannot_be"),
            "回复通知的网络失败不该说成决策“结果未知”"
        )
        for language in [AppLanguage.simplifiedChinese, .english] {
            for key in ["ui.push_message_route_missing", "ui.push_message_route_expired", "ui.push_route_connection_not_restored"] {
                XCTAssertNotEqual(L10n.text(key, language: language), key, "缺少文案：\(key) (\(language.rawValue))")
            }
        }
    }

    /// 连接没恢复时用户什么都没提交，不能显示决策链路的“结果未知”。
    func testUnrestoredConnectionDoesNotClaimDecisionOutcomeIsUnknown() throws {
        for notification in [try approvalNotification(), try messageNotification()] {
            XCTAssertEqual(
                LockScreenApprovalRouting.detailsErrorMessage(
                    LockScreenApprovalRoutingError.sourceCredentialUnavailable, for: notification
                ),
                L10n.text("ui.push_route_connection_not_restored")
            )
            XCTAssertEqual(
                LockScreenApprovalRouting.detailsErrorMessage(CancellationError(), for: notification),
                L10n.text("ui.push_route_connection_not_restored"),
                "合成的 CancellationError 同样是连接尚未恢复"
            )
            XCTAssertEqual(
                LockScreenApprovalRouting.detailsErrorMessage(
                    LockScreenApprovalRoutingError.sourceProfileUnavailable, for: notification
                ),
                L10n.text("ui.the_session_corresponding_to_the_notification_is_temporarily")
            )
        }
    }

    /// 本机快路径只允许同一台 Mac；其它 Mac 的通知即使本地缓存里有同名会话也要走定位。
    func testLocalRouteEligibilityRequiresSameMac() throws {
        let profiles = [
            ConnectionProfile(
                id: "mac-a", displayName: "mac-a", endpoint: "http://100.64.0.10:8787",
                lastSuccessfulAt: nil, installationID: "installation-a"
            ),
            ConnectionProfile(
                id: "mac-b", displayName: "mac-b", endpoint: "http://100.64.0.11:8787",
                lastSuccessfulAt: nil, installationID: "installation-b"
            ),
        ]
        let fromMacA = try messageNotification(
            profileID: LockScreenApprovalRouting.profileTag(installationID: "installation-a")
        )
        XCTAssertTrue(LockScreenApprovalRouting.isLocalRouteEligible(fromMacA, activeProfileID: "mac-a", profiles: profiles))
        XCTAssertFalse(LockScreenApprovalRouting.isLocalRouteEligible(fromMacA, activeProfileID: "mac-b", profiles: profiles))
        XCTAssertFalse(LockScreenApprovalRouting.isLocalRouteEligible(fromMacA, activeProfileID: nil, profiles: profiles))
        let unknownMac = try messageNotification(profileID: "0123456789abcdef")
        XCTAssertFalse(LockScreenApprovalRouting.isLocalRouteEligible(unknownMac, activeProfileID: "mac-a", profiles: profiles))
        XCTAssertEqual(LockScreenApprovalRouting.localProfileID(for: fromMacA, profiles: profiles), "mac-a")
    }

    func testTailcatApprovalReusesExistingRoute() async throws {
        let (store, _, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setTailcatExperimentModeEnabled(true)
        store.setTailcatExperimentEndpoint("http://127.0.0.1:49152")
        let client = try await LockScreenApprovalRouting.client(profileID: "mac-a", appStore: store)
        XCTAssertEqual(client.endpoint, "http://127.0.0.1:49152")
        XCTAssertEqual(client.token, "token-a")
        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
    }

    func testInactiveTailcatMaintenanceCannotFallBackToDirectAddress() async throws {
        let (store, _, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            _ = try await LockScreenApprovalRouting.client(profileID: "mac-b", appStore: store)
            XCTFail("非当前 Tailcat 档案不能绕过用户选定线路")
        } catch LockScreenApprovalRoutingError.sourceProfileUnavailable {
            XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        }
    }

    func testUnavailableTailcatRouteCannotReturnDirectClient() async throws {
        let (store, _, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setTailcatExperimentModeEnabled(true)
        store.setTailcatExperimentEndpoint(nil)
        do {
            _ = try await LockScreenApprovalRouting.client(profileID: "mac-a", appStore: store)
            XCTFail("Tailcat 未就绪时不能回退直连")
        } catch LockScreenApprovalRoutingError.sourceCredentialUnavailable {}
    }

    private func fixture() throws -> (AppStore, TokenStore, UserDefaults, String) {
        let suite = "LockScreenApprovalRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profiles = ["mac-a", "mac-b"].map {
            ConnectionProfile(
                id: $0, displayName: $0, endpoint: "http://100.64.0.10:8787",
                lastSuccessfulAt: nil, connectionRoute: .tailcat
            )
        }
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v2")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        let tokens = TokenStore(keychain: TestKeychainOperations())
        try tokens.save("token-a", profileID: "mac-a")
        try tokens.save("token-b", profileID: "mac-b")
        try tokens.saveTailcatAddress("tailcat:mac-a", profileID: "mac-a")
        try tokens.saveTailcatAddress("tailcat:mac-b", profileID: "mac-b")
        try tokens.saveTailcatExperimentPrivateKey("test-private-key")
        return (AppStore(defaults: defaults, tokenStore: tokens, prefersLocalConnection: false), tokens, defaults, suite)
    }

    private func approvalNotification() throws -> LockScreenApprovalNotification {
        try XCTUnwrap(LockScreenApprovalNotification(userInfo: notificationPayload(event: "approval.pending", kind: "command")))
    }

    private func messageNotification(profileID: String = "0123456789abcdef") throws -> LockScreenApprovalNotification {
        try XCTUnwrap(LockScreenApprovalNotification(
            userInfo: notificationPayload(event: "turn.completed", kind: "", profileID: profileID)
        ))
    }

    private func notificationPayload(
        event: String,
        kind: String,
        profileID: String = "0123456789abcdef"
    ) -> [AnyHashable: Any] {
        [
            "mimi": [
                "version": 1,
                "event": event,
                "action_id": "act-0123456789abcdef",
                "device_id": "dev-abc123",
                "profile_id": profileID,
                "runtime": "codex",
                "approval_kind": kind,
                "host_tag": "A1C3",
                "session_tag": "7D92",
                "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)),
            ] as [String: Any],
        ]
    }
}
