import XCTest
@testable import MimiRemote

actor TailcatRouteRecorder {
    private(set) var endpoints: [String] = []

    func record(_ endpoint: String) {
        endpoints.append(endpoint)
    }
}

private enum TailcatRuntimeStubError: Error {
    case startFailed
}

private actor TailcatExperimentRuntimeStub: TailcatExperimentRuntimeProtocol {
    private var startResults: [Result<String, TailcatRuntimeStubError>]
    private var starts = 0
    private let blockedStartCall: Int?
    private var blockedStartContinuation: CheckedContinuation<Void, Never>?
    private var blockedStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        startResults: [Result<String, TailcatRuntimeStubError>],
        blockedStartCall: Int? = nil
    ) {
        self.startResults = startResults
        self.blockedStartCall = blockedStartCall
    }

    func start(address: String, privateKey: String) async throws -> String {
        starts += 1
        if let blockedStartCall, starts == blockedStartCall {
            await withCheckedContinuation { continuation in
                blockedStartContinuation = continuation
                blockedStartWaiters.forEach { $0.resume() }
                blockedStartWaiters = []
            }
        }
        guard !startResults.isEmpty else {
            throw TailcatRuntimeStubError.startFailed
        }
        return try startResults.removeFirst().get()
    }

    func discoPing() throws -> TailcatDiscoPingPayload {
        TailcatDiscoPingPayload(path: "direct", latencyMillis: 1, derpRegionCode: nil)
    }

    func stop() throws {}

    func stop(ifCurrentEndpoint endpoint: String) throws {}

    func startCallCount() -> Int {
        starts
    }

    func waitForBlockedStart() async {
        guard blockedStartContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            guard blockedStartContinuation == nil else {
                continuation.resume()
                return
            }
            blockedStartWaiters.append(continuation)
        }
    }

    func releaseBlockedStart() {
        blockedStartContinuation?.resume()
        blockedStartContinuation = nil
    }
}

@MainActor
final class TailcatExperimentRoutingTests: XCTestCase {
    func testConnectedPrepareRouteDoesNotRestartProxy() async throws {
        let fixture = try makeControllerFixture(startResults: [
            .success("http://127.0.0.1:49152"),
            .success("http://127.0.0.1:49153")
        ])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.controller.setAddress("tailcat:test-address")
        let enabled = await fixture.controller.setEnabled(true, appStore: fixture.store)
        let preparedAgain = await fixture.controller.prepareRoute(appStore: fixture.store)
        let startCallCount = await fixture.runtime.startCallCount()

        XCTAssertTrue(enabled)
        XCTAssertTrue(preparedAgain)
        XCTAssertEqual(startCallCount, 1)
        XCTAssertEqual(fixture.store.tailcatExperimentEndpoint, "http://127.0.0.1:49152")
    }

    func testForegroundRecoveryRestartsProxyAndPublishesNewEndpoint() async throws {
        let fixture = try makeControllerFixture(startResults: [
            .success("http://127.0.0.1:49152"),
            .success("http://127.0.0.1:49153")
        ])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.controller.setAddress("tailcat:test-address")
        let enabled = await fixture.controller.setEnabled(true, appStore: fixture.store)
        let recovered = await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)
        let startCallCount = await fixture.runtime.startCallCount()

        XCTAssertTrue(enabled)
        XCTAssertTrue(recovered)
        XCTAssertEqual(startCallCount, 2)
        XCTAssertEqual(fixture.store.tailcatExperimentEndpoint, "http://127.0.0.1:49153")
        XCTAssertEqual(fixture.controller.state, .connected(endpoint: "http://127.0.0.1:49153"))
    }

    func testCancelledForegroundRecoveryCanRetryAfterInactivePhase() async throws {
        let fixture = try makeControllerFixture(
            startResults: [
                .success("http://127.0.0.1:49152"),
                .success("http://127.0.0.1:49153"),
                .success("http://127.0.0.1:49154")
            ],
            blockedStartCall: 2
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.controller.setAddress("tailcat:test-address")
        let enabled = await fixture.controller.setEnabled(true, appStore: fixture.store)
        XCTAssertTrue(enabled)

        let interruptedRecovery = Task {
            await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)
        }
        await fixture.runtime.waitForBlockedStart()
        interruptedRecovery.cancel()
        await fixture.runtime.releaseBlockedStart()

        let interruptedResult = await interruptedRecovery.value
        XCTAssertFalse(interruptedResult)
        XCTAssertNil(fixture.store.tailcatExperimentEndpoint)

        let recovered = await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)
        let startCallCount = await fixture.runtime.startCallCount()

        XCTAssertTrue(recovered)
        XCTAssertEqual(startCallCount, 3)
        XCTAssertEqual(fixture.store.tailcatExperimentEndpoint, "http://127.0.0.1:49154")
    }

    func testForegroundRecoveryFailureKeepsTailcatFailClosed() async throws {
        let fixture = try makeControllerFixture(startResults: [
            .success("http://127.0.0.1:49152"),
            .failure(.startFailed)
        ])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.endpoint = "http://100.64.0.10:8787"
        fixture.store.token = "existing-agentd-token"

        fixture.controller.setAddress("tailcat:test-address")
        let enabled = await fixture.controller.setEnabled(true, appStore: fixture.store)
        let recovered = await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)

        XCTAssertTrue(enabled)
        XCTAssertFalse(recovered)
        XCTAssertNil(fixture.store.tailcatExperimentEndpoint)
        XCTAssertEqual(fixture.store.connectionEndpoint, "http://127.0.0.1:1")
        XCTAssertEqual(fixture.store.endpoint, "http://100.64.0.10:8787")
        XCTAssertEqual(fixture.store.activeConnectionRoute, .tailcat)
        guard case .failed = fixture.controller.state else {
            return XCTFail("恢复失败后应显示 Tailcat 错误状态")
        }
    }

    func testForegroundRecoveryDoesNothingWhenExperimentIsDisabled() async throws {
        let fixture = try makeControllerFixture(startResults: [
            .success("http://127.0.0.1:49152")
        ])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let recovered = await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)
        let startCallCount = await fixture.runtime.startCallCount()

        XCTAssertTrue(recovered)
        XCTAssertEqual(startCallCount, 0)
        XCTAssertEqual(fixture.controller.state, .disabled)
        XCTAssertEqual(fixture.store.activeConnectionRoute, .configured)
    }

    func testExperimentFailureUsesOnlyTailcatAndPreservesConfiguredConnection() async throws {
        let suiteName = "TailcatExperimentRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuredEndpoint = "http://100.64.0.10:8787"
        let tailcatEndpoint = "http://127.0.0.1:49152"
        let token = "existing-agentd-token"
        let recorder = TailcatRouteRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
                throw URLError(.cannotConnectToHost)
            }
        )
        store.endpoint = configuredEndpoint
        store.token = token

        store.setTailcatExperimentModeEnabled(true)
        store.setTailcatExperimentEndpoint(tailcatEndpoint)
        let connected = await store.preflightConnection(force: true)
        let probedEndpoints = await recorder.endpoints

        XCTAssertFalse(connected)
        XCTAssertEqual(probedEndpoints, [tailcatEndpoint])
        XCTAssertEqual(store.endpoint, configuredEndpoint)
        XCTAssertEqual(store.token, token)
        XCTAssertEqual(store.connectionEndpoint, tailcatEndpoint)
        XCTAssertEqual(store.activeConnectionRoute, .tailcat)

        store.setTailcatExperimentModeEnabled(false)
        XCTAssertEqual(store.connectionEndpoint, configuredEndpoint)
        XCTAssertEqual(store.activeConnectionRoute, .configured)
    }

    func testEnabledExperimentWithoutProxyDoesNotProbeConfiguredEndpoint() async throws {
        let suiteName = "TailcatExperimentRoutingTests.FailClosed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recorder = TailcatRouteRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
            }
        )
        store.endpoint = "http://100.64.0.10:8787"
        store.token = "existing-agentd-token"

        store.setTailcatExperimentModeEnabled(true)
        let connected = await store.preflightConnection(force: true)
        let probedEndpoints = await recorder.endpoints

        XCTAssertFalse(connected)
        XCTAssertEqual(probedEndpoints, [])
        XCTAssertEqual(store.connectionEndpoint, "http://127.0.0.1:1")
        XCTAssertEqual(store.activeConnectionRoute, .tailcat)
        XCTAssertEqual(store.endpoint, "http://100.64.0.10:8787")
        XCTAssertEqual(store.token, "existing-agentd-token")
    }

    func testDirectConnectionCommitDoesNotReusePreviousTailcatRoute() async throws {
        let suiteName = "TailcatExperimentRoutingTests.DirectCommit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = TestKeychainOperations()
        let tokenStore = TokenStore(keychain: keychain)
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil,
            connectionRoute: .tailcat
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        try tokenStore.save("token-a", profileID: profile.id)
        try tokenStore.saveTailcatAddress("tailcat:mac-a", profileID: profile.id)
        let store = AppStore(
            defaults: defaults,
            tokenStore: tokenStore,
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )
        let runtime = TailcatExperimentRuntimeStub(startResults: [.success("http://127.0.0.1:49152")])
        let controller = TailcatExperimentController(
            appStore: store,
            defaults: defaults,
            tokenStore: tokenStore,
            runtime: runtime,
            bridge: .init(
                isAvailable: true,
                generatePrivateKey: { "private-key" },
                publicKey: { _ in "nodekey:public-key" }
            )
        )
        let initialRouteReady = await controller.prepareRoute(appStore: store)
        XCTAssertTrue(initialRouteReady)

        let prepared = try await store.prepareConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b"
        )
        _ = try await store.commitConnectionSettings(prepared)
        await controller.commitPreparedRouteIfNeeded(prepared, appStore: store)

        XCTAssertEqual(store.connectionEndpoint, "http://100.64.0.20:8787")
        XCTAssertEqual(store.activeConnectionRoute, .configured)
        XCTAssertEqual(store.activeConnectionProfile?.connectionRoute, .configured)
        XCTAssertFalse(controller.isEnabled)
    }

    func testSwitchingTailcatProfilesLoadsEachProfilesOwnAddress() async throws {
        let suiteName = "TailcatExperimentRoutingTests.ProfileSwitch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(
                id: "mac-a", displayName: "Mac A", endpoint: "http://100.64.0.10:8787",
                lastSuccessfulAt: nil, connectionRoute: .tailcat
            ),
            ConnectionProfile(
                id: "mac-b", displayName: "Mac B", endpoint: "http://100.64.0.20:8787",
                lastSuccessfulAt: nil, connectionRoute: .tailcat
            ),
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v2")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        let tokenStore = TokenStore(keychain: TestKeychainOperations())
        try tokenStore.save("token-a", profileID: "mac-a")
        try tokenStore.save("token-b", profileID: "mac-b")
        try tokenStore.saveTailcatAddress("tailcat:mac-a", profileID: "mac-a")
        try tokenStore.saveTailcatAddress("tailcat:mac-b", profileID: "mac-b")
        let store = AppStore(
            defaults: defaults,
            tokenStore: tokenStore,
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )
        let runtime = TailcatExperimentRuntimeStub(startResults: [
            .success("http://127.0.0.1:49152"),
            .success("http://127.0.0.1:49153"),
            .success("http://127.0.0.1:49154"),
        ])
        let controller = TailcatExperimentController(
            appStore: store,
            defaults: defaults,
            tokenStore: tokenStore,
            runtime: runtime,
            bridge: .init(
                isAvailable: true,
                generatePrivateKey: { "private-key" },
                publicKey: { _ in "nodekey:public-key" }
            )
        )
        let initialRouteReady = await controller.prepareRoute(appStore: store)
        XCTAssertTrue(initialRouteReady)

        let preparedB = try await controller.prepareConnectionProfileSwitch(id: "mac-b", appStore: store)
        _ = try await store.commitConnectionSettings(preparedB)
        await controller.commitPreparedRouteIfNeeded(preparedB, appStore: store)
        XCTAssertEqual(controller.address, "tailcat:mac-b")
        XCTAssertEqual(store.connectionEndpoint, "http://127.0.0.1:49153")

        let preparedA = try await controller.prepareConnectionProfileSwitch(id: "mac-a", appStore: store)
        _ = try await store.commitConnectionSettings(preparedA)
        await controller.commitPreparedRouteIfNeeded(preparedA, appStore: store)
        XCTAssertEqual(controller.address, "tailcat:mac-a")
        XCTAssertEqual(store.connectionEndpoint, "http://127.0.0.1:49154")
        XCTAssertEqual(try tokenStore.loadTailcatAddress(profileID: "mac-b"), "tailcat:mac-b")
    }

    func testLegacyGlobalAddressMigratesToActiveProfile() throws {
        let suiteName = "TailcatExperimentRoutingTests.LegacyMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a", displayName: "Mac A", endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(true, forKey: TailcatExperimentController.enabledKey)
        let tokenStore = TokenStore(keychain: TestKeychainOperations())
        try tokenStore.save("token-a", profileID: profile.id)
        try tokenStore.saveTailcatExperimentAddress("tailcat:legacy")
        let store = AppStore(defaults: defaults, tokenStore: tokenStore, prefersLocalConnection: false)

        let controller = TailcatExperimentController(
            appStore: store,
            defaults: defaults,
            tokenStore: tokenStore,
            runtime: TailcatExperimentRuntimeStub(startResults: []),
            bridge: .init(
                isAvailable: true,
                generatePrivateKey: { "private-key" },
                publicKey: { _ in "nodekey:public-key" }
            )
        )

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.address, "tailcat:legacy")
        XCTAssertEqual(store.activeConnectionProfile?.connectionRoute, .tailcat)
        XCTAssertEqual(try tokenStore.loadTailcatAddress(profileID: profile.id), "tailcat:legacy")
        XCTAssertEqual(try tokenStore.loadTailcatExperimentAddress(), "")
    }

    private func makeControllerFixture(
        startResults: [Result<String, TailcatRuntimeStubError>],
        blockedStartCall: Int? = nil
    ) throws -> (
        controller: TailcatExperimentController,
        runtime: TailcatExperimentRuntimeStub,
        store: AppStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "TailcatExperimentRoutingTests.Controller.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let runtime = TailcatExperimentRuntimeStub(
            startResults: startResults,
            blockedStartCall: blockedStartCall
        )
        let bridge = TailcatExperimentBridgeAdapter(
            isAvailable: true,
            generatePrivateKey: { "private-key" },
            publicKey: { _ in "nodekey:public-key" }
        )
        let keychain = TestKeychainOperations()
        let tokenStore = TokenStore(keychain: keychain)
        let store = AppStore(
            defaults: defaults,
            tokenStore: tokenStore,
            prefersLocalConnection: false
        )
        let controller = TailcatExperimentController(
            appStore: store,
            defaults: defaults,
            tokenStore: tokenStore,
            runtime: runtime,
            bridge: bridge
        )
        return (controller, runtime, store, defaults, suiteName)
    }
}
