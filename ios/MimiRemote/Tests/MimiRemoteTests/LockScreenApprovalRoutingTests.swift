import XCTest
@testable import MimiRemote

@MainActor
final class LockScreenApprovalRoutingTests: XCTestCase {
    func testExpiredDetailsDoNotClaimMacIsUnreachable() {
        XCTAssertEqual(
            LockScreenApprovalRouting.detailsErrorMessage(AgentAPIError.server(status: 410, message: "gone")),
            L10n.text("ui.push_approval_expired")
        )
        XCTAssertEqual(
            LockScreenApprovalRouting.detailsErrorMessage(AgentAPIError.server(status: 403, message: "forbidden")),
            L10n.text("ui.push_approval_device_not_allowed")
        )
        XCTAssertEqual(
            LockScreenApprovalRouting.detailsErrorMessage(URLError(.notConnectedToInternet)),
            L10n.text("ui.push_approval_result_unknown")
        )
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
}
