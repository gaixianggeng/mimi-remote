import XCTest
@testable import MimiRemote

@MainActor
final class LockScreenApprovalRoutingTests: XCTestCase {
    func testTailcatApprovalUsesSourceMacWithoutSwitchingActiveProfile() async throws {
        let (store, tokens, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = ApprovalRoutingRuntime()
        let client = try await LockScreenApprovalRouting.client(
            profileID: "mac-b", appStore: store, tokenStore: tokens, runtime: runtime
        )
        XCTAssertEqual(client.endpoint, "http://127.0.0.1:49152")
        XCTAssertEqual(client.token, "token-b")
        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        let address = await runtime.startedAddress
        XCTAssertEqual(address, "tailcat:mac-b")
    }

    func testTailcatFailureDoesNotReturnDirectClient() async throws {
        let (store, tokens, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            _ = try await LockScreenApprovalRouting.client(
                profileID: "mac-b", appStore: store, tokenStore: tokens,
                runtime: ApprovalRoutingRuntime(fails: true)
            )
            XCTFail("Tailcat 不可达时不能绕过用户选定线路")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
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

private actor ApprovalRoutingRuntime: TailcatExperimentRuntimeProtocol {
    private let fails: Bool
    private(set) var startedAddress: String?
    init(fails: Bool = false) { self.fails = fails }
    func start(address: String, privateKey: String) async throws -> String {
        startedAddress = address
        if fails { throw URLError(.cannotConnectToHost) }
        return "http://127.0.0.1:49152"
    }
    func prepare(address: String, privateKey: String) async throws -> String {
        try await start(address: address, privateKey: privateKey)
    }
    func activatePrepared(endpoint: String) {}
    func discardPrepared(endpoint: String) {}
    func hasPrepared(endpoint: String) -> Bool { false }
    func discoPing() throws -> TailcatDiscoPingPayload { throw URLError(.unsupportedURL) }
    func stop() {}
    func stop(ifCurrentEndpoint endpoint: String) {}
}
