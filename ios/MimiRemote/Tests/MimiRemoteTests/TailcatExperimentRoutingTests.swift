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
    private var activeEndpoint: String?
    private var preparedEndpoints: Set<String> = []

    init(
        startResults: [Result<String, TailcatRuntimeStubError>],
        blockedStartCall: Int? = nil
    ) {
        self.startResults = startResults
        self.blockedStartCall = blockedStartCall
    }

    func start(address: String, privateKey: String) async throws -> String {
        let endpoint = try await nextEndpoint()
        activeEndpoint = endpoint
        return endpoint
    }

    func prepare(address: String, privateKey: String) async throws -> String {
        let endpoint = try await nextEndpoint()
        preparedEndpoints.insert(endpoint)
        return endpoint
    }

    private func nextEndpoint() async throws -> String {
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

    func activatePrepared(endpoint: String) throws {
        guard preparedEndpoints.remove(endpoint) != nil else {
            throw TailcatRuntimeStubError.startFailed
        }
        activeEndpoint = endpoint
    }

    func discardPrepared(endpoint: String) throws {
        preparedEndpoints.remove(endpoint)
    }

    func hasPrepared(endpoint: String) -> Bool {
        preparedEndpoints.contains(endpoint)
    }

    func discoPing() throws -> TailcatDiscoPingPayload {
        TailcatDiscoPingPayload(path: "direct", latencyMillis: 1, derpRegionCode: nil)
    }

    func stop() throws {
        activeEndpoint = nil
        preparedEndpoints.removeAll()
    }

    func stop(ifCurrentEndpoint endpoint: String) throws {
        if activeEndpoint == endpoint {
            activeEndpoint = nil
        }
    }

    func startCallCount() -> Int {
        starts
    }

    func currentEndpoint() -> String? {
        activeEndpoint
    }

    func hasPreparedEndpoint(_ endpoint: String) -> Bool {
        preparedEndpoints.contains(endpoint)
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
private final class ManagedPairingAuthorizerStub: ManagedConnectionPairingAuthorizing {
    private(set) var requests: [(macInstallationID: String, macKey: String, mobileKey: String)] = []
    private(set) var completions: [ManagedConnectionPairingAuthorization] = []

    func authorizeManagedPairing(
        macInstallationID: String,
        macTailcatPublicKey: String,
        mobileTailcatPublicKey: String
    ) async throws -> ManagedConnectionPairingAuthorization {
        requests.append((macInstallationID, macTailcatPublicKey, mobileTailcatPublicKey))
        return ManagedConnectionPairingAuthorization(sessionID: "managed-session", grant: "managed-grant")
    }

    func didCompleteManagedPairing(_ authorization: ManagedConnectionPairingAuthorization) {
        completions.append(authorization)
    }
}

@MainActor
private final class ManagedConnectionEventReporterStub: ManagedConnectionEventReporting {
    private(set) var events: [ManagedConnectionEvent] = []
    var onReport: (() -> Void)?
    var blocksReports = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    func report(_ event: ManagedConnectionEvent) async {
        events.append(event)
        onReport?()
        if blocksReports {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
    }

    func releaseBlockedReport() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

@MainActor
final class TailcatExperimentRoutingTests: XCTestCase {
    func testUnavailableManagedRouteStaysFailClosedUntilManualFallback() async throws {
        let fixture = try makeControllerFixture(
            startResults: [],
            managedProfile: true,
            bridgeAvailable: false
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let prepared = await fixture.controller.prepareRoute(appStore: fixture.store)
        let startCallCount = await fixture.runtime.startCallCount()

        XCTAssertFalse(prepared)
        XCTAssertTrue(fixture.controller.isEnabled)
        XCTAssertEqual(fixture.controller.state, .unavailable)
        XCTAssertTrue(fixture.store.isTailcatExperimentModeEnabled)
        XCTAssertEqual(fixture.store.connectionEndpoint, "http://127.0.0.1:1")
        XCTAssertEqual(startCallCount, 0)
        XCTAssertTrue(ManagedConnectionSubscriptionView.showsManagedRecoveryActions(
            tailcatState: fixture.controller.state,
            connectionFailed: false
        ))

        let usedFallback = await fixture.controller.useSavedRouteOnce(.tailscale, appStore: fixture.store)

        XCTAssertTrue(usedFallback)
        XCTAssertEqual(fixture.controller.state, .usingTemporaryRoute(.tailscale))
        XCTAssertFalse(fixture.store.isTailcatExperimentModeEnabled)
        XCTAssertEqual(fixture.store.connectionEndpoint, "http://100.64.0.10:8787")
    }

    func testManagedRouteWithoutAddressStaysFailClosedAndOffersManualFallback() async throws {
        let fixture = try makeControllerFixture(
            startResults: [],
            managedProfile: true,
            managedAddress: nil
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let prepared = await fixture.controller.prepareRoute(appStore: fixture.store)

        XCTAssertFalse(prepared)
        XCTAssertTrue(fixture.controller.isEnabled)
        XCTAssertEqual(fixture.controller.state, .needsAddress)
        XCTAssertTrue(fixture.store.isTailcatExperimentModeEnabled)
        XCTAssertEqual(fixture.store.connectionEndpoint, "http://127.0.0.1:1")
        XCTAssertTrue(ManagedConnectionSubscriptionView.showsManagedRecoveryActions(
            tailcatState: fixture.controller.state,
            connectionFailed: false
        ))

        let usedFallback = await fixture.controller.useSavedRouteOnce(.tailscale, appStore: fixture.store)

        XCTAssertTrue(usedFallback)
        XCTAssertEqual(fixture.controller.state, .usingTemporaryRoute(.tailscale))
        XCTAssertFalse(fixture.store.isTailcatExperimentModeEnabled)
    }

    func testForegroundRecoveryPreservesTemporaryManagedFallback() async throws {
        let fixture = try makeControllerFixture(
            startResults: [.success("http://127.0.0.1:49152")],
            managedProfile: true
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let prepared = await fixture.controller.prepareRoute(appStore: fixture.store)
        let usedFallback = await fixture.controller.useSavedRouteOnce(.tailscale, appStore: fixture.store)
        let recovered = await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)
        let startCallCount = await fixture.runtime.startCallCount()

        XCTAssertTrue(prepared)
        XCTAssertTrue(usedFallback)
        XCTAssertTrue(recovered)
        XCTAssertEqual(startCallCount, 1)
        XCTAssertEqual(fixture.controller.state, .usingTemporaryRoute(.tailscale))
        XCTAssertFalse(fixture.store.isTailcatExperimentModeEnabled)
        XCTAssertEqual(fixture.store.activeConnectionProfile?.connectionRoute, .managedTailcat)
    }

    func testManagedFailureTelemetryDoesNotDelayFailureResult() async throws {
        let reporter = ManagedConnectionEventReporterStub()
        reporter.blocksReports = true
        let reportStarted = expectation(description: "telemetry started")
        reporter.onReport = { reportStarted.fulfill() }
        let routeFinished = expectation(description: "route failure returned")
        let fixture = try makeControllerFixture(
            startResults: [.failure(.startFailed)],
            managedProfile: true,
            managedConnectionEventReporter: reporter
        )
        defer {
            reporter.releaseBlockedReport()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }

        Task { @MainActor in
            let ready = await fixture.controller.prepareRoute(appStore: fixture.store)
            XCTAssertFalse(ready)
            routeFinished.fulfill()
        }

        await fulfillment(of: [routeFinished, reportStarted], timeout: 1)
        guard case .failed = fixture.controller.state else {
            return XCTFail("线路失败必须先于旁路遥测返回")
        }
    }

    func testConcurrentManagedPreparationEmitsOneConnectionEvent() async throws {
        let reporter = ManagedConnectionEventReporterStub()
        let reported = expectation(description: "one managed event")
        reporter.onReport = { reported.fulfill() }
        let fixture = try makeControllerFixture(
            startResults: [.success("http://127.0.0.1:49152")],
            blockedStartCall: 1,
            managedProfile: true,
            managedConnectionEventReporter: reporter
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let first = Task { await fixture.controller.prepareRoute(appStore: fixture.store) }
        await fixture.runtime.waitForBlockedStart()
        let second = Task { await fixture.controller.prepareRoute(appStore: fixture.store) }
        await Task.yield()
        await fixture.runtime.releaseBlockedStart()

        let firstResult = await first.value
        let secondResult = await second.value
        await fulfillment(of: [reported], timeout: 1)
        for _ in 0..<5 { await Task.yield() }
        let startCallCount = await fixture.runtime.startCallCount()
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(reporter.events.count, 1)
        XCTAssertEqual(startCallCount, 1)
    }

    func testManagedPairingRequiresManagedQRCodeBeforeStartingRuntime() async throws {
        let authorizer = ManagedPairingAuthorizerStub()
        let fixture = try makeControllerFixture(
            startResults: [.failure(.startFailed)],
            managedPairingAuthorizer: authorizer
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let url = try XCTUnwrap(URL(string: Self.freeTailcatPairingURL))

        await XCTAssertThrowsErrorAsync(
            try await fixture.controller.preparePairingURL(
                url,
                appStore: fixture.store,
                profileTarget: .currentOrNew(displayName: nil),
                requiresManagedAuthorization: true
            )
        )

        let startCallCount = await fixture.runtime.startCallCount()
        XCTAssertTrue(authorizer.requests.isEmpty)
        XCTAssertEqual(startCallCount, 0)
    }

    func testManagedPairingAuthorizesBeforePreparingTailcatRoute() async throws {
        let authorizer = ManagedPairingAuthorizerStub()
        let fixture = try makeControllerFixture(
            startResults: [.failure(.startFailed)],
            managedPairingAuthorizer: authorizer
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let url = try XCTUnwrap(URL(string: Self.managedTailcatPairingURL))

        await XCTAssertThrowsErrorAsync(
            try await fixture.controller.preparePairingURL(
                url,
                appStore: fixture.store,
                profileTarget: .currentOrNew(displayName: nil),
                requiresManagedAuthorization: true
            )
        )

        XCTAssertEqual(authorizer.requests.count, 1)
        XCTAssertEqual(authorizer.requests.first?.macInstallationID, "20000000-0000-4000-8000-000000000001")
        XCTAssertEqual(authorizer.requests.first?.macKey, "nodekey:mac-public")
        XCTAssertEqual(authorizer.requests.first?.mobileKey, "nodekey:public-key")
        let startCallCount = await fixture.runtime.startCallCount()
        XCTAssertEqual(startCallCount, 1)
        XCTAssertTrue(authorizer.completions.isEmpty)
    }

    func testFreeTailcatPairingDoesNotRequestManagedAuthorization() async throws {
        let authorizer = ManagedPairingAuthorizerStub()
        let fixture = try makeControllerFixture(
            startResults: [.failure(.startFailed)],
            managedPairingAuthorizer: authorizer
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let url = try XCTUnwrap(URL(string: Self.managedTailcatPairingURL))

        await XCTAssertThrowsErrorAsync(
            try await fixture.controller.preparePairingURL(
                url,
                appStore: fixture.store,
                profileTarget: .currentOrNew(displayName: nil)
            )
        )

        let startCallCount = await fixture.runtime.startCallCount()
        XCTAssertTrue(authorizer.requests.isEmpty)
        XCTAssertEqual(startCallCount, 1)
    }

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
        try tokenStore.saveTailcatExperimentAddress("tailcat:ambiguous-legacy")
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
        try await controller.stagePreparedRouteIfNeeded(preparedB, appStore: store)
        _ = try await store.commitConnectionSettings(preparedB)
        await controller.commitPreparedRouteIfNeeded(preparedB, appStore: store)
        XCTAssertEqual(controller.address, "tailcat:mac-b")
        XCTAssertEqual(store.connectionEndpoint, "http://127.0.0.1:49153")
        XCTAssertEqual(
            try tokenStore.loadTailcatExperimentAddress(),
            "tailcat:ambiguous-legacy"
        )

        let preparedA = try await controller.prepareConnectionProfileSwitch(id: "mac-a", appStore: store)
        try await controller.stagePreparedRouteIfNeeded(preparedA, appStore: store)
        _ = try await store.commitConnectionSettings(preparedA)
        await controller.commitPreparedRouteIfNeeded(preparedA, appStore: store)
        XCTAssertEqual(controller.address, "tailcat:mac-a")
        XCTAssertEqual(store.connectionEndpoint, "http://127.0.0.1:49154")
        XCTAssertEqual(try tokenStore.loadTailcatAddress(profileID: "mac-b"), "tailcat:mac-b")
    }

    func testFailedTailcatProfileValidationKeepsCurrentProxyActive() async throws {
        let suiteName = "TailcatExperimentRoutingTests.ProfileSwitchFailure.\(UUID().uuidString)"
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
            routeProbe: { endpoint, _, _ in
                if endpoint == "http://127.0.0.1:49153" {
                    throw URLError(.cannotConnectToHost)
                }
            }
        )
        let runtime = TailcatExperimentRuntimeStub(startResults: [
            .success("http://127.0.0.1:49152"),
            .success("http://127.0.0.1:49153"),
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

        await XCTAssertThrowsErrorAsync(
            try await controller.prepareConnectionProfileSwitch(id: "mac-b", appStore: store)
        )

        let activeEndpoint = await runtime.currentEndpoint()
        let candidateRemains = await runtime.hasPreparedEndpoint("http://127.0.0.1:49153")
        XCTAssertEqual(activeEndpoint, "http://127.0.0.1:49152")
        XCTAssertFalse(candidateRemains)
        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(store.connectionEndpoint, "http://127.0.0.1:49152")
    }

    func testTailcatAddressWriteFailurePreventsProfileCommit() async throws {
        let suiteName = "TailcatExperimentRoutingTests.AddressWriteFailure.\(UUID().uuidString)"
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
        let keychain = TestKeychainOperations()
        let tokenStore = TokenStore(keychain: keychain)
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
        let prepared = try await controller.prepareConnectionProfileSwitch(id: "mac-b", appStore: store)
        keychain.forcedUpdateStatus = errSecInteractionNotAllowed

        await XCTAssertThrowsErrorAsync(
            try await controller.stagePreparedRouteIfNeeded(prepared, appStore: store)
        )

        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        let activeEndpoint = await runtime.currentEndpoint()
        XCTAssertEqual(activeEndpoint, "http://127.0.0.1:49152")
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

    func testLegacyGlobalAddressRemainsWhenMultipleProfilesAreAmbiguous() throws {
        let suiteName = "TailcatExperimentRoutingTests.AmbiguousLegacyMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(
                id: "mac-a", displayName: "Mac A", endpoint: "http://100.64.0.10:8787",
                lastSuccessfulAt: nil
            ),
            ConnectionProfile(
                id: "mac-b", displayName: "Mac B", endpoint: "http://100.64.0.20:8787",
                lastSuccessfulAt: nil
            ),
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v2")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(true, forKey: TailcatExperimentController.enabledKey)
        let tokenStore = TokenStore(keychain: TestKeychainOperations())
        try tokenStore.save("token-a", profileID: "mac-a")
        try tokenStore.save("token-b", profileID: "mac-b")
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

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(try tokenStore.loadTailcatAddress(profileID: "mac-a"), "")
        XCTAssertEqual(try tokenStore.loadTailcatAddress(profileID: "mac-b"), "")
        XCTAssertEqual(try tokenStore.loadTailcatExperimentAddress(), "tailcat:legacy")
    }

    func testDeleteProfileRouteOnlyDeletesTargetProfilesAddress() throws {
        let suiteName = "TailcatExperimentRoutingTests.DeleteProfileRoute.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = TokenStore(keychain: TestKeychainOperations())
        try tokenStore.saveTailcatAddress("tailcat:mac-a", profileID: "mac-a")
        try tokenStore.saveTailcatAddress("tailcat:mac-b", profileID: "mac-b")
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

        try controller.deleteProfileRoute(profileID: "mac-a")

        XCTAssertEqual(try tokenStore.loadTailcatAddress(profileID: "mac-a"), "")
        XCTAssertEqual(try tokenStore.loadTailcatAddress(profileID: "mac-b"), "tailcat:mac-b")
    }

    private func makeControllerFixture(
        startResults: [Result<String, TailcatRuntimeStubError>],
        blockedStartCall: Int? = nil,
        managedPairingAuthorizer: (any ManagedConnectionPairingAuthorizing)? = nil,
        managedProfile: Bool = false,
        managedAddress: String? = "tailcat:managed-mac",
        bridgeAvailable: Bool = true,
        managedConnectionEventReporter: (any ManagedConnectionEventReporting)? = nil
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
            isAvailable: bridgeAvailable,
            generatePrivateKey: { "private-key" },
            publicKey: { _ in "nodekey:public-key" }
        )
        let keychain = TestKeychainOperations()
        let tokenStore = TokenStore(keychain: keychain)
        if managedProfile {
            let profile = ConnectionProfile(
                id: "managed-mac",
                displayName: "Managed Mac",
                endpoint: "http://100.64.0.10:8787",
                lastSuccessfulAt: nil,
                connectionRoute: .managedTailcat
            )
            defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
            defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
            try tokenStore.save("managed-token", profileID: profile.id)
            if let managedAddress {
                try tokenStore.saveTailcatAddress(managedAddress, profileID: profile.id)
            }
        }
        let store = AppStore(
            defaults: defaults,
            tokenStore: tokenStore,
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )
        let controller = TailcatExperimentController(
            appStore: store,
            defaults: defaults,
            tokenStore: tokenStore,
            runtime: runtime,
            bridge: bridge,
            managedPairingAuthorizer: managedPairingAuthorizer,
            managedConnectionEventReporter: managedConnectionEventReporter
        )
        return (controller, runtime, store, defaults, suiteName)
    }

    private static let freeTailcatPairingURL =
        "mimiremote://pair?endpoint=http%3A%2F%2F127.0.0.1%3A8787&issued_at=2026-09-01T00%3A00%3A00Z&expires_at=4102444800&pair_sig=abcdef&transport=tailcat&tailcat_pair_address=tc%3Atest-address"

    private static let managedTailcatPairingURL = freeTailcatPairingURL
        + "&managed_mac_installation_id=20000000-0000-4000-8000-000000000001"
        + "&managed_mac_tailcat_public_key=nodekey%3Amac-public"
}
