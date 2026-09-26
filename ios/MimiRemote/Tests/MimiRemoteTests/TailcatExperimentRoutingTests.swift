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
    case unhealthy
}

private actor TailcatExperimentRuntimeStub: TailcatExperimentRuntimeProtocol {
    private var startResults: [Result<String, TailcatRuntimeStubError>]
    private var starts = 0
    private let blockedStartCall: Int?
    private var blockedStartContinuation: CheckedContinuation<Void, Never>?
    private var blockedStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeEndpoint: String?
    private var activeAddress: String?
    private var preparedEndpoint: String?
    private var preparedPreviousAddress: String?
    private var healthy = true
    private var activeEngineCount = 0
    private var maximumActiveEngineCount = 0
    private var blocksCurrentEndpoint = false
    private var currentEndpointContinuation: CheckedContinuation<Void, Never>?
    private var currentEndpointWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocksHasPrepared = false
    private var hasPreparedContinuation: CheckedContinuation<Void, Never>?
    private var hasPreparedWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        startResults: [Result<String, TailcatRuntimeStubError>],
        blockedStartCall: Int? = nil
    ) {
        self.startResults = startResults
        self.blockedStartCall = blockedStartCall
    }

    func start(address: String, privateKey: String) async throws -> String {
        closeActiveEngine()
        let endpoint = try await nextEndpoint()
        installActiveEngine(endpoint: endpoint, address: address)
        return endpoint
    }

    func prepare(address: String, privateKey: String) async throws -> String {
        if let preparedEndpoint {
            _ = try await discardPrepared(endpoint: preparedEndpoint)
        }
        let previousAddress = activeAddress
        closeActiveEngine()
        do {
            let endpoint = try await nextEndpoint()
            installActiveEngine(endpoint: endpoint, address: address)
            preparedEndpoint = endpoint
            preparedPreviousAddress = previousAddress
            return endpoint
        } catch {
            if let previousAddress {
                let restoredEndpoint = try await nextEndpoint()
                installActiveEngine(endpoint: restoredEndpoint, address: previousAddress)
            }
            throw error
        }
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
        guard preparedEndpoint == endpoint, activeEndpoint == endpoint else {
            throw TailcatRuntimeStubError.startFailed
        }
        preparedEndpoint = nil
        preparedPreviousAddress = nil
    }

    func discardPrepared(endpoint: String) async throws -> String? {
        guard preparedEndpoint == endpoint else { return activeEndpoint }
        let previousAddress = preparedPreviousAddress
        preparedEndpoint = nil
        preparedPreviousAddress = nil
        closeActiveEngine()
        guard let previousAddress else { return nil }
        let restoredEndpoint = try await nextEndpoint()
        installActiveEngine(endpoint: restoredEndpoint, address: previousAddress)
        return restoredEndpoint
    }

    func hasPrepared(endpoint: String) async -> Bool {
        let result = preparedEndpoint == endpoint && activeEndpoint == endpoint
        if blocksHasPrepared {
            await withCheckedContinuation { continuation in
                hasPreparedContinuation = continuation
                hasPreparedWaiters.forEach { $0.resume() }
                hasPreparedWaiters = []
            }
        }
        return result
    }

    func discoPing() throws -> TailcatDiscoPingPayload {
        guard healthy else { throw TailcatRuntimeStubError.unhealthy }
        return TailcatDiscoPingPayload(path: "direct", latencyMillis: 1, derpRegionCode: nil)
    }

    func stop() throws {
        closeActiveEngine()
        preparedEndpoint = nil
        preparedPreviousAddress = nil
    }

    func stop(ifCurrentEndpoint endpoint: String) throws {
        if activeEndpoint == endpoint {
            closeActiveEngine()
            preparedEndpoint = nil
            preparedPreviousAddress = nil
        }
    }

    func startCallCount() -> Int {
        starts
    }

    func currentEndpoint() async -> String? {
        if blocksCurrentEndpoint {
            await withCheckedContinuation { continuation in
                currentEndpointContinuation = continuation
                currentEndpointWaiters.forEach { $0.resume() }
                currentEndpointWaiters = []
            }
        }
        return activeEndpoint
    }

    func hasPreparedEndpoint(_ endpoint: String) -> Bool {
        preparedEndpoint == endpoint
    }

    func setHealthy(_ healthy: Bool) {
        self.healthy = healthy
    }

    func maximumConcurrentEngineCount() -> Int {
        maximumActiveEngineCount
    }

    func blockNextCurrentEndpoint() {
        blocksCurrentEndpoint = true
    }

    func waitForBlockedCurrentEndpoint() async {
        guard currentEndpointContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            guard currentEndpointContinuation == nil else {
                continuation.resume()
                return
            }
            currentEndpointWaiters.append(continuation)
        }
    }

    func releaseBlockedCurrentEndpoint() {
        blocksCurrentEndpoint = false
        currentEndpointContinuation?.resume()
        currentEndpointContinuation = nil
    }

    func blockNextHasPrepared() {
        blocksHasPrepared = true
    }

    func waitForBlockedHasPrepared() async {
        guard hasPreparedContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            guard hasPreparedContinuation == nil else {
                continuation.resume()
                return
            }
            hasPreparedWaiters.append(continuation)
        }
    }

    func releaseBlockedHasPrepared() {
        blocksHasPrepared = false
        hasPreparedContinuation?.resume()
        hasPreparedContinuation = nil
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

    private func installActiveEngine(endpoint: String, address: String) {
        activeEndpoint = endpoint
        activeAddress = address
        activeEngineCount += 1
        maximumActiveEngineCount = max(maximumActiveEngineCount, activeEngineCount)
    }

    private func closeActiveEngine() {
        guard activeEndpoint != nil else { return }
        activeEndpoint = nil
        activeAddress = nil
        activeEngineCount -= 1
    }
}

private final class TailcatProxyFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<String, TailcatRuntimeStubError>]
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var addresses: [String] = []

    init(results: [Result<String, TailcatRuntimeStubError>]) {
        self.results = results
    }

    func make(address: String, privateKey: String, remotePort: Int) throws -> any TailcatProxyProtocol {
        lock.lock()
        defer { lock.unlock() }
        addresses.append(address)
        guard !results.isEmpty else { throw TailcatRuntimeStubError.startFailed }
        let endpoint = try results.removeFirst().get()
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        return TailcatProxyStub(endpoint: endpoint) { [weak self] in
            self?.recordClose()
        }
    }

    func snapshot() -> (maximumActiveCount: Int, addresses: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (maximumActiveCount, addresses)
    }

    private func recordClose() {
        lock.lock()
        activeCount -= 1
        lock.unlock()
    }
}

private final class TailcatProxyStub: TailcatProxyProtocol, @unchecked Sendable {
    let localEndpoint: String
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var closed = false

    init(endpoint: String, onClose: @escaping @Sendable () -> Void) {
        localEndpoint = endpoint
        self.onClose = onClose
    }

    func discoPing(timeoutSeconds: Int) throws -> String {
        "{\"path\":\"direct\",\"latency_millis\":1}"
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        onClose()
    }
}

@MainActor
private final class ManagedPairingAuthorizerStub: ManagedConnectionPairingAuthorizing {
    private(set) var requests: [(macInstallationID: String, macKey: String, pairingMacKey: String, mobileKey: String)] = []
    private(set) var completions: [ManagedConnectionPairingAuthorization] = []

    func authorizeManagedPairing(
        macInstallationID: String,
        macTailcatPublicKey: String,
        pairingMacTailcatPublicKey: String,
        mobileTailcatPublicKey: String
    ) async throws -> ManagedConnectionPairingAuthorization {
        requests.append((macInstallationID, macTailcatPublicKey, pairingMacTailcatPublicKey, mobileTailcatPublicKey))
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
    func testRuntimeProfileReplacementNeverOverlapsNativeEngines() async throws {
        let recorder = TailcatProxyFactoryRecorder(results: [
            .success("http://127.0.0.1:49152"),
            .success("http://127.0.0.1:49153"),
            .success("http://127.0.0.1:49154"),
        ])
        let runtime = TailcatExperimentRuntime(proxyFactory: recorder.make)

        _ = try await runtime.start(address: "tailcat:mac-a", privateKey: "private-key")
        let candidate = try await runtime.prepare(address: "tailcat:mac-b", privateKey: "private-key")
        let restored = try await runtime.discardPrepared(endpoint: candidate)
        let snapshot = recorder.snapshot()

        XCTAssertEqual(restored, "http://127.0.0.1:49154")
        XCTAssertEqual(snapshot.maximumActiveCount, 1)
        XCTAssertEqual(snapshot.addresses, ["tailcat:mac-a", "tailcat:mac-b", "tailcat:mac-a"])
    }

    func testRuntimeFailedCandidateStartRestoresPreviousRouteWithoutOverlap() async throws {
        let recorder = TailcatProxyFactoryRecorder(results: [
            .success("http://127.0.0.1:49152"),
            .failure(.startFailed),
            .success("http://127.0.0.1:49154"),
        ])
        let runtime = TailcatExperimentRuntime(proxyFactory: recorder.make)
        _ = try await runtime.start(address: "tailcat:mac-a", privateKey: "private-key")

        do {
            _ = try await runtime.prepare(address: "tailcat:mac-b", privateKey: "private-key")
            XCTFail("候选启动失败必须向调用方返回错误")
        } catch {
            XCTAssertTrue(error is TailcatRuntimeStubError)
        }
        let restored = await runtime.currentEndpoint()
        let snapshot = recorder.snapshot()

        XCTAssertEqual(restored, "http://127.0.0.1:49154")
        XCTAssertEqual(snapshot.maximumActiveCount, 1)
        XCTAssertEqual(snapshot.addresses, ["tailcat:mac-a", "tailcat:mac-b", "tailcat:mac-a"])
    }

    func testConnectionMethodSummaryReflectsRouteStateInsteadOfEnabledFlag() {
        XCTAssertEqual(TailcatExperimentState.unavailable.connectionMethodSummary,
                       L10n.text("ui.tailcat_framework_unavailable"))
        XCTAssertEqual(TailcatExperimentState.needsAddress.connectionMethodSummary,
                       L10n.text("ui.tailcat_needs_address"))
        XCTAssertEqual(TailcatExperimentState.starting.connectionMethodSummary,
                       L10n.text("ui.connecting"))
        XCTAssertEqual(TailcatExperimentState.failed(message: "offline").connectionMethodSummary,
                       L10n.text("ui.connection_failed"))
        XCTAssertEqual(TailcatExperimentState.usingTemporaryRoute(.lan).connectionMethodSummary,
                       L10n.format("ui.managed_connection_using_temporary_route", ConnectionProfileRoute.lan.title))
        XCTAssertEqual(TailcatExperimentState.connected(endpoint: "http://127.0.0.1:8787").connectionMethodSummary,
                       L10n.text("ui.connected"))
        XCTAssertEqual(TailcatExperimentState.disabled.connectionMethodSummary,
                       L10n.text("ui.deactivated"))
    }

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

    func testManagedPairingRequiresCurrentManagedQRCodeBeforeStartingRuntime() async throws {
        let authorizer = ManagedPairingAuthorizerStub()
        let fixture = try makeControllerFixture(
            startResults: [.failure(.startFailed)],
            managedPairingAuthorizer: authorizer
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let url = try XCTUnwrap(URL(string: Self.legacyManagedTailcatPairingURL))

        do {
            try await fixture.controller.preparePairingURL(
                url,
                appStore: fixture.store,
                profileTarget: .currentOrNew(displayName: nil),
                requiresManagedAuthorization: true
            )
            XCTFail("旧版托管二维码缺少临时配对公钥时必须停止")
        } catch {
            XCTAssertEqual(error as? ManagedConnectionDeviceStoreError, .managedQRCodeRequired)
        }

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
        XCTAssertEqual(authorizer.requests.first?.pairingMacKey, "nodekey:pair-public")
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

    func testCancelledPairingPreparationDiscardsPairEndpointAndRestoresRoute() async throws {
        let fixture = try makeControllerFixture(
            startResults: [
                .success("http://127.0.0.1:49152"),
                .success("http://127.0.0.1:49153"),
                .success("http://127.0.0.1:49154"),
            ],
            blockedStartCall: 2
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.controller.setAddress("tailcat:current")
        let enabled = await fixture.controller.setEnabled(true, appStore: fixture.store)
        XCTAssertTrue(enabled)
        let url = try XCTUnwrap(URL(string: Self.freeTailcatPairingURL))
        let pairingTask = Task {
            try await fixture.controller.preparePairingURL(
                url,
                appStore: fixture.store,
                profileTarget: .currentOrNew(displayName: nil)
            )
        }
        await fixture.runtime.waitForBlockedStart()

        pairingTask.cancel()
        await fixture.runtime.releaseBlockedStart()
        await XCTAssertThrowsErrorAsync(try await pairingTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let activeEndpoint = await fixture.runtime.currentEndpoint()
        let pairEndpointRemains = await fixture.runtime.hasPreparedEndpoint("http://127.0.0.1:49153")
        XCTAssertEqual(activeEndpoint, "http://127.0.0.1:49154")
        XCTAssertFalse(pairEndpointRemains)
        XCTAssertEqual(fixture.store.tailcatExperimentEndpoint, "http://127.0.0.1:49154")
        XCTAssertEqual(fixture.controller.state, .connected(endpoint: "http://127.0.0.1:49154"))
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

    func testForegroundRecoveryKeepsHealthyProxyAndEndpoint() async throws {
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
        XCTAssertEqual(startCallCount, 1)
        XCTAssertEqual(fixture.store.tailcatExperimentEndpoint, "http://127.0.0.1:49152")
        XCTAssertEqual(fixture.controller.state, .connected(endpoint: "http://127.0.0.1:49152"))
    }

    func testForegroundRecoveryRestartsUnhealthyProxyOnce() async throws {
        let fixture = try makeControllerFixture(startResults: [
            .success("http://127.0.0.1:49152"),
            .success("http://127.0.0.1:49153")
        ])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.controller.setAddress("tailcat:test-address")
        let enabled = await fixture.controller.setEnabled(true, appStore: fixture.store)
        XCTAssertTrue(enabled)
        await fixture.runtime.setHealthy(false)

        let recovered = await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)
        let startCallCount = await fixture.runtime.startCallCount()

        XCTAssertTrue(recovered)
        XCTAssertEqual(startCallCount, 2)
        XCTAssertEqual(fixture.store.tailcatExperimentEndpoint, "http://127.0.0.1:49153")
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
        await fixture.runtime.setHealthy(false)

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

    func testStaleForegroundRecoveryCannotPublishAfterAddressGenerationChanges() async throws {
        let fixture = try makeControllerFixture(
            startResults: [
                .success("http://127.0.0.1:49152"),
                .success("http://127.0.0.1:49153"),
                .success("http://127.0.0.1:49154"),
            ],
            blockedStartCall: 2
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.controller.setAddress("tailcat:old-address")
        let enabled = await fixture.controller.setEnabled(true, appStore: fixture.store)
        XCTAssertTrue(enabled)
        await fixture.runtime.setHealthy(false)
        let staleRecovery = Task {
            await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)
        }
        await fixture.runtime.waitForBlockedStart()

        fixture.controller.setAddress("tailcat:new-address")
        await fixture.runtime.releaseBlockedStart()
        let staleResult = await staleRecovery.value
        XCTAssertFalse(staleResult)
        XCTAssertEqual(fixture.controller.state, .starting)
        XCTAssertNil(fixture.store.tailcatExperimentEndpoint)

        let currentReady = await fixture.controller.prepareRoute(appStore: fixture.store)
        XCTAssertTrue(currentReady)
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
        await fixture.runtime.setHealthy(false)
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

        await XCTAssertThrowsErrorAsync(
            try await controller.prepareConnectionProfileSwitch(id: "mac-b", appStore: store)
        )

        let activeEndpoint = await runtime.currentEndpoint()
        let candidateRemains = await runtime.hasPreparedEndpoint("http://127.0.0.1:49153")
        let maximumEngineCount = await runtime.maximumConcurrentEngineCount()
        XCTAssertEqual(activeEndpoint, "http://127.0.0.1:49154")
        XCTAssertFalse(candidateRemains)
        XCTAssertEqual(maximumEngineCount, 1)
        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(store.connectionEndpoint, "http://127.0.0.1:49154")
    }

    func testProfileRollbackDoesNotPublishEndpointAfterGenerationChangesDuringRestore() async throws {
        let suiteName = "TailcatExperimentRoutingTests.StaleProfileRollback.\(UUID().uuidString)"
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
        let initialReady = await controller.prepareRoute(appStore: store)
        XCTAssertTrue(initialReady)
        await runtime.blockNextCurrentEndpoint()
        let staleSwitch = Task {
            try await controller.prepareConnectionProfileSwitch(id: "mac-b", appStore: store)
        }
        await runtime.waitForBlockedCurrentEndpoint()

        controller.setAddress("tailcat:newer-operation")
        await runtime.releaseBlockedCurrentEndpoint()
        await XCTAssertThrowsErrorAsync(try await staleSwitch.value)

        XCTAssertEqual(controller.address, "tailcat:newer-operation")
        XCTAssertEqual(controller.state, .starting)
        XCTAssertNil(store.tailcatExperimentEndpoint)
        XCTAssertEqual(store.connectionEndpoint, "http://127.0.0.1:1")
        let runtimeEndpoint = await runtime.currentEndpoint()
        XCTAssertEqual(runtimeEndpoint, "http://127.0.0.1:49154")
    }

    func testStaleStageCannotWriteAddressAfterNewPendingRouteTakesOver() async throws {
        let suiteName = "TailcatExperimentRoutingTests.StaleStage.\(UUID().uuidString)"
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
            .success("http://127.0.0.1:49155"),
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
        let initialReady = await controller.prepareRoute(appStore: store)
        XCTAssertTrue(initialReady)
        let stalePrepared = try await controller.prepareConnectionProfileSwitch(id: "mac-b", appStore: store)
        await runtime.blockNextHasPrepared()
        let staleStage = Task {
            try await controller.stagePreparedRouteIfNeeded(stalePrepared, appStore: store)
        }
        await runtime.waitForBlockedHasPrepared()

        let currentPrepared = try await controller.prepareConnectionProfileSwitch(id: "mac-a", appStore: store)
        try tokenStore.saveTailcatAddress("tailcat:newer-mac-b", profileID: "mac-b")
        await runtime.releaseBlockedHasPrepared()
        await XCTAssertThrowsErrorAsync(try await staleStage.value) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(try tokenStore.loadTailcatAddress(profileID: "mac-b"), "tailcat:newer-mac-b")
        let currentCandidateRemains = await runtime.hasPrepared(endpoint: currentPrepared.activeEndpoint)
        XCTAssertTrue(currentCandidateRemains)
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
        let prepared = try await controller.prepareConnectionProfileSwitch(id: "mac-b", appStore: store)
        keychain.forcedUpdateStatus = errSecInteractionNotAllowed

        await XCTAssertThrowsErrorAsync(
            try await controller.stagePreparedRouteIfNeeded(prepared, appStore: store)
        )

        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        let activeEndpoint = await runtime.currentEndpoint()
        XCTAssertEqual(activeEndpoint, "http://127.0.0.1:49154")
        XCTAssertEqual(store.connectionEndpoint, "http://127.0.0.1:49154")
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

    private static let legacyManagedTailcatPairingURL = freeTailcatPairingURL
        + "&managed_mac_installation_id=20000000-0000-4000-8000-000000000001"
        + "&managed_mac_tailcat_public_key=nodekey%3Amac-public"

    private static let managedTailcatPairingURL = legacyManagedTailcatPairingURL
        + "&managed_pair_tailcat_public_key=nodekey%3Apair-public"
}
