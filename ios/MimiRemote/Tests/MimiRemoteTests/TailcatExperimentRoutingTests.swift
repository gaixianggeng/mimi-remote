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
        let controller = TailcatExperimentController(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            runtime: runtime,
            bridge: bridge
        )
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false
        )
        return (controller, runtime, store, defaults, suiteName)
    }
}
