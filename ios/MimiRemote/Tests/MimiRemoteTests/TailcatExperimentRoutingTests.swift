import XCTest
@testable import MimiRemote

actor TailcatRouteRecorder {
    private(set) var endpoints: [String] = []

    func record(_ endpoint: String) {
        endpoints.append(endpoint)
    }
}

private actor TailcatLocalProbeGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func probe() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    func waitForProbe() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish(_ result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private enum TailcatRuntimeStubError: Error, Equatable {
    case startFailed
    case unhealthy
    case closeFailed
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
    private let closeFailures: Set<Int>
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var addresses: [String] = []

    init(results: [Result<String, TailcatRuntimeStubError>], closeFailures: Set<Int> = []) {
        self.results = results
        self.closeFailures = closeFailures
    }

    func make(address: String, privateKey: String, remotePort: Int) throws -> any TailcatProxyProtocol {
        lock.lock()
        defer { lock.unlock() }
        addresses.append(address)
        guard !results.isEmpty else { throw TailcatRuntimeStubError.startFailed }
        let endpoint = try results.removeFirst().get()
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        return TailcatProxyStub(endpoint: endpoint, closeFails: closeFailures.contains(addresses.count)) { [weak self] in
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
    private let endpoint: String
    private let closeFails: Bool
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var closed = false

    init(endpoint: String, closeFails: Bool, onClose: @escaping @Sendable () -> Void) {
        self.endpoint = endpoint
        self.closeFails = closeFails
        self.onClose = onClose
    }

    var localEndpoint: String {
        lock.lock()
        defer { lock.unlock() }
        return closed ? "" : endpoint
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
        // 原生 Close 即使报错也已释放 forwarder，后续 endpoint 为空且 Close 幂等。
        if closeFails { throw TailcatRuntimeStubError.closeFailed }
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

/// 使用真实 URLSession 请求覆盖确认与 claim，等待响应由测试显式释放，不依赖 sleep。
private final class ManagedUpgradeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((ManagedUpgradeURLProtocol) -> Void)?
    private static var capturedRequests: [URLRequest] = []

    static func configure(_ handler: @escaping (ManagedUpgradeURLProtocol) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        capturedRequests = []
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["/api/pair/claim", "/api/tailcat/managed-pairing-link"].contains(request.url?.path ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        Self.lock.lock()
        Self.capturedRequests.append(captured)
        let handler = Self.handler
        Self.lock.unlock()
        handler?(self)
    }

    func respond(status: Int = 200, body: String) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class TailcatExperimentRoutingTests: XCTestCase {
    func testRuntimeFailedCloseInvalidatesRouteBeforeReplacement() async throws {
        let recorder = TailcatProxyFactoryRecorder(results: [
            .success("http://127.0.0.1:49152"),
            .success("http://127.0.0.1:49153"),
        ], closeFailures: [1])
        let runtime = TailcatExperimentRuntime(proxyFactory: recorder.make)
        _ = try await runtime.start(address: "tailcat:mac-a", privateKey: "private-key")

        await XCTAssertThrowsErrorAsync(
            try await runtime.prepare(address: "tailcat:mac-b", privateKey: "private-key")
        ) { error in
            XCTAssertEqual(error as? TailcatRuntimeStubError, .closeFailed)
        }
        let endpointAfterFailure = await runtime.currentEndpoint()
        XCTAssertNil(endpointAfterFailure)
        XCTAssertEqual(recorder.snapshot().addresses, ["tailcat:mac-a"])

        let endpoint = try await runtime.start(address: "tailcat:mac-b", privateKey: "private-key")
        XCTAssertEqual(endpoint, "http://127.0.0.1:49153")
        XCTAssertEqual(recorder.snapshot().maximumActiveCount, 1)
    }

    func testRuntimeFailedCandidateCloseClearsPendingRollback() async throws {
        for stopsInsteadOfDiscard in [false, true] {
            let recorder = TailcatProxyFactoryRecorder(results: [
                .success("http://127.0.0.1:49152"),
                .success("http://127.0.0.1:49153"),
                .success("http://127.0.0.1:49154"),
            ], closeFailures: [2])
            let runtime = TailcatExperimentRuntime(proxyFactory: recorder.make)
            _ = try await runtime.start(address: "tailcat:mac-a", privateKey: "private-key")
            let candidate = try await runtime.prepare(address: "tailcat:mac-b", privateKey: "private-key")

            do {
                if stopsInsteadOfDiscard {
                    try await runtime.stop()
                } else {
                    _ = try await runtime.discardPrepared(endpoint: candidate)
                }
                XCTFail("关闭错误必须继续传给调用方")
            } catch {
                XCTAssertEqual(error as? TailcatRuntimeStubError, .closeFailed)
            }
            let endpointAfterFailure = await runtime.currentEndpoint()
            let hasPrepared = await runtime.hasPrepared(endpoint: candidate)
            XCTAssertNil(endpointAfterFailure)
            XCTAssertFalse(hasPrepared)

            // 迟到的清理不能根据已经失效的候选记录重新启动旧线路。
            let lateDiscard = try await runtime.discardPrepared(endpoint: candidate)
            XCTAssertNil(lateDiscard)
            XCTAssertEqual(recorder.snapshot().addresses, ["tailcat:mac-a", "tailcat:mac-b"])
        }
    }

    func testProfileSwitchCloseFailureDoesNotPublishConnectedRoute() async throws {
        let suiteName = "TailcatExperimentRoutingTests.CloseFailure.\(UUID().uuidString)"
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
        for profile in profiles {
            try tokenStore.save("test-token", profileID: profile.id)
            try tokenStore.saveTailcatAddress("tailcat:\(profile.id)", profileID: profile.id)
        }
        let store = AppStore(
            defaults: defaults, tokenStore: tokenStore, prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )
        let recorder = TailcatProxyFactoryRecorder(results: [
            .success("http://127.0.0.1:49152"),
        ], closeFailures: [1])
        let runtime = TailcatExperimentRuntime(proxyFactory: recorder.make)
        let controller = TailcatExperimentController(
            appStore: store, defaults: defaults, tokenStore: tokenStore, runtime: runtime,
            bridge: .init(
                isAvailable: true,
                generatePrivateKey: { "private-key" },
                publicKey: { _ in "nodekey:public-key" }
            )
        )
        let initialReady = await controller.prepareRoute(appStore: store)
        XCTAssertTrue(initialReady)

        await XCTAssertThrowsErrorAsync(
            try await controller.prepareConnectionProfileSwitch(id: "mac-b", appStore: store)
        ) { error in
            XCTAssertEqual(error as? TailcatRuntimeStubError, .closeFailed)
        }

        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(store.connectionEndpoint, "http://127.0.0.1:1")
        XCTAssertTrue(store.isTailcatExperimentModeEnabled)
        XCTAssertEqual(controller.state, .starting)
        XCTAssertEqual(recorder.snapshot().addresses, ["tailcat:mac-a"])
    }

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
        XCTAssertTrue(ManagedConnectionDevicesView.showsManagedRecoveryActions(
            tailcatState: fixture.controller.state,
            connectionFailed: false
        ))

        let usedFallback = await fixture.controller.useSavedRouteOnce(.tailscale, appStore: fixture.store)

        XCTAssertTrue(usedFallback)
        XCTAssertEqual(fixture.controller.state, .usingTemporaryRoute(.tailscale))
        XCTAssertFalse(fixture.store.isTailcatExperimentModeEnabled)
        XCTAssertEqual(fixture.store.connectionEndpoint, "http://100.64.0.10:8787")
    }

    func testManagedConnectionLANHintOnlyForFailedUnsubscribedLANProfiles() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func shows(
            route: ConnectionProfileRoute? = .lan,
            failed: Bool = true,
            confirmedNotSubscribed: Bool = true,
            dismissedAgo: TimeInterval? = nil
        ) -> Bool {
            InitialConnectionSettingsSections.showsManagedConnectionLANHint(
                route: route,
                connectionFailed: failed,
                confirmedNotSubscribed: confirmedNotSubscribed,
                dismissedAt: dismissedAgo.map { now.addingTimeInterval(-$0) },
                now: now
            )
        }

        XCTAssertTrue(shows())
        // 只针对局域网档案：Tailscale、托管线路或尚无档案时不提示。
        XCTAssertFalse(shows(route: .tailscale))
        XCTAssertFalse(shows(route: .managedTailcat))
        XCTAssertFalse(shows(route: nil))
        XCTAssertFalse(shows(failed: false))
        // 已订阅或订阅状态还没核验完（检查中、失败、待批准）都不提示。
        XCTAssertFalse(shows(confirmedNotSubscribed: false))
        // 关闭后 7 天内不再出现，满 7 天再出现。
        let snooze = InitialConnectionSettingsSections.managedConnectionLANHintSnooze
        XCTAssertFalse(shows(dismissedAgo: snooze - 60))
        XCTAssertTrue(shows(dismissedAgo: snooze))
    }

    func testManagedConnectionEntryOnlyOpensForExplicitBuildFlagOrDebugArgument() {
        let argument = ManagedConnectionSubscriptionView.debugEntryLaunchArgument

        // App Store 提交构建：Info.plist 展开为空或 NO，Release 不读取调试参数。
        XCTAssertFalse(ManagedConnectionSubscriptionView.isEntryVisible(
            infoPlistValue: "",
            launchArguments: [argument],
            allowsDebugLaunchArgument: false
        ))
        XCTAssertFalse(ManagedConnectionSubscriptionView.isEntryVisible(
            infoPlistValue: "NO",
            launchArguments: [],
            allowsDebugLaunchArgument: true
        ))
        XCTAssertFalse(ManagedConnectionSubscriptionView.isEntryVisible(
            infoPlistValue: nil,
            launchArguments: [],
            allowsDebugLaunchArgument: false
        ))
        // 内部 TestFlight 构建显式写入 YES。
        XCTAssertTrue(ManagedConnectionSubscriptionView.isEntryVisible(
            infoPlistValue: "YES",
            launchArguments: [],
            allowsDebugLaunchArgument: false
        ))
        // Debug 启动参数保持原行为，供 UI 测试打开入口。
        XCTAssertTrue(ManagedConnectionSubscriptionView.isEntryVisible(
            infoPlistValue: "",
            launchArguments: [argument],
            allowsDebugLaunchArgument: true
        ))
    }

    func testOneTapManagedUpgradeOnlyOffersConnectedNonTailcatRoutes() {
        for route in [ConnectionProfileRoute.lan, .tailscale, .https] {
            XCTAssertTrue(ManagedConnectionDevicesView.canUpgradeCurrentComputer(route: route, connected: true))
            XCTAssertFalse(ManagedConnectionDevicesView.canUpgradeCurrentComputer(route: route, connected: false))
        }
        // 进入托管模式会重建 Tailcat 身份：经 Tailcat 发起会切断请求自己，已托管也无需再接入。
        XCTAssertFalse(ManagedConnectionDevicesView.canUpgradeCurrentComputer(route: .customTailcat, connected: true))
        XCTAssertFalse(ManagedConnectionDevicesView.canUpgradeCurrentComputer(route: .managedTailcat, connected: true))
        XCTAssertFalse(ManagedConnectionDevicesView.canUpgradeCurrentComputer(route: nil, connected: true))
    }

    func testOneTapUpgradeKeepsValidGrantDuringEntitlementRefresh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func grant(expiresIn interval: TimeInterval) -> ManagedConnectionEntitlementGrant {
            ManagedConnectionEntitlementGrant(
                entitlement: ManagedConnectionEntitlement(
                    id: "entitlement-id",
                    productID: ManagedConnectionProductID.annual,
                    status: .active,
                    expiresAt: now.addingTimeInterval(interval)
                ),
                token: "in-memory-token",
                tokenExpiresAt: now.addingTimeInterval(60)
            )
        }

        XCTAssertTrue(ManagedConnectionDevicesView.hasEntitlementForUpgrade(
            status: .entitled(grant(expiresIn: 3_600).entitlement), grant: nil, now: now
        ))
        // 凭证按计划刷新时状态短暂变成检查中，手里的权益仍有效就不能挡住。
        XCTAssertTrue(ManagedConnectionDevicesView.hasEntitlementForUpgrade(
            status: .resolving, grant: grant(expiresIn: 3_600), now: now
        ))
        XCTAssertFalse(ManagedConnectionDevicesView.hasEntitlementForUpgrade(
            status: .resolving, grant: grant(expiresIn: -1), now: now
        ))
        XCTAssertFalse(ManagedConnectionDevicesView.hasEntitlementForUpgrade(
            status: .available, grant: nil, now: now
        ))
    }

    func testManagedPairingLinkErrorsDecodeStableCodes() {
        func decode(_ status: Int, _ json: String) -> ManagedPairingLinkAPIError? {
            ManagedPairingLinkAPIError.decode(status: status, data: Data(json.utf8))
        }

        XCTAssertEqual(
            decode(409, #"{"code":"tailcat_self_hosted_clients_present","error":"x","paired_device_count":2}"#),
            .selfHostedClientsPresent(count: 2)
        )
        XCTAssertEqual(decode(409, #"{"code":"tailcat_operation_in_progress","error":"x"}"#), .busy)
        XCTAssertEqual(
            decode(503, #"{"code":"tailcat_pair_failed","error":"生成失败"}"#),
            .failed(code: "tailcat_pair_failed", message: "生成失败")
        )
        // 鉴权失败与没有 code 的旧响应交回通用处理，凭据失效逻辑不变。
        XCTAssertNil(decode(401, #"{"code":"unauthorized","error":"x"}"#))
        XCTAssertNil(decode(400, #"{"error":"invalid json"}"#))
        XCTAssertNil(decode(500, "not json"))
    }

    func testOneTapManagedUpgradePreservesSavedRoutesAndDNS() async throws {
        URLProtocol.registerClass(ManagedUpgradeURLProtocol.self)
        defer { URLProtocol.unregisterClass(ManagedUpgradeURLProtocol.self) }
        let routes: [(String, String?, ConnectionProfileRoute)] = [
            ("http://192.168.1.20:8787", nil, .lan),
            ("https://mac.example.com", nil, .https),
            ("http://100.64.0.10:8787", nil, .tailscale),
            ("http://100.64.0.10:8787", "studio.tailnet.ts.net", .tailscale),
        ]
        for (endpoint, dnsName, route) in routes {
            ManagedUpgradeURLProtocol.configure { request in
                request.respond(body: #"{"endpoint":"http://127.0.0.1:8787","token":"managed-token","tailcat_address":"tailcat:stable"}"#)
            }
            let authorizer = ManagedPairingAuthorizerStub()
            let fixture = try makeControllerFixture(
                startResults: [.success("http://127.0.0.1:49152"), .success("http://127.0.0.1:49153")],
                managedPairingAuthorizer: authorizer
            )
            defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
            try await seedUpgradeProfile(fixture.store, endpoint: endpoint, dnsName: dnsName)
            let original = try XCTUnwrap(fixture.store.activeConnectionProfile)
            let context = try ManagedConnectionUpgradeContext(appStore: fixture.store, client: fixture.store.client())
            let sessions = SessionStore(
                appStore: fixture.store, conversationStore: ConversationStore(), logStore: LogStore(),
                tailcatExperimentController: fixture.controller
            )
            let url = try XCTUnwrap(URL(string: Self.managedTailcatPairingURL))

            _ = try await sessions.applyManagedPairingURL(url, upgrading: context)

            XCTAssertEqual(fixture.store.activeConnectionProfileID, original.id)
            XCTAssertEqual(fixture.store.connectionProfiles.count, 1)
            XCTAssertEqual(fixture.store.activeConnectionProfile?.endpoint, endpoint)
            XCTAssertEqual(fixture.store.activeConnectionProfile?.tailscaleDNSName, dnsName)
            XCTAssertEqual(fixture.store.activeConnectionProfile?.connectionRoute, .managedTailcat)
            XCTAssertEqual(fixture.store.connectionEndpoint, "http://127.0.0.1:49153")
            XCTAssertEqual(fixture.store.savedFallbackConnectionRoute, route)
            XCTAssertEqual(authorizer.completions.count, 1)
            let claim = try XCTUnwrap(ManagedUpgradeURLProtocol.requests.first?.httpBody)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: claim) as? [String: Any])
            XCTAssertEqual(payload["endpoint"] as? String, "http://127.0.0.1:8787", "签名票据必须原样发送")

            let recovered = await fixture.controller.useSavedRouteOnce(route, appStore: fixture.store)
            XCTAssertTrue(recovered)
            XCTAssertEqual(fixture.store.connectionEndpoint, original.connectionCandidates.first)
            XCTAssertEqual(fixture.store.activeConnectionProfile?.connectionRoute, .managedTailcat)
        }
    }

    func testManagedScanWithoutUpgradeStillUsesTicketEndpoint() async throws {
        URLProtocol.registerClass(ManagedUpgradeURLProtocol.self)
        defer { URLProtocol.unregisterClass(ManagedUpgradeURLProtocol.self) }
        ManagedUpgradeURLProtocol.configure { request in
            request.respond(body: #"{"endpoint":"http://127.0.0.1:8787","token":"managed-token","tailcat_address":"tailcat:stable"}"#)
        }
        let fixture = try makeControllerFixture(
            startResults: [.success("http://127.0.0.1:49152"), .success("http://127.0.0.1:49153")],
            managedPairingAuthorizer: ManagedPairingAuthorizerStub()
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let sessions = SessionStore(
            appStore: fixture.store, conversationStore: ConversationStore(), logStore: LogStore(),
            tailcatExperimentController: fixture.controller
        )

        _ = try await sessions.applyManagedPairingURL(try XCTUnwrap(URL(string: Self.managedTailcatPairingURL)))

        XCTAssertEqual(fixture.store.activeConnectionProfile?.endpoint, "http://127.0.0.1:8787")
        XCTAssertEqual(fixture.store.activeConnectionProfile?.connectionRoute, .managedTailcat)
    }

    func testUpgradeConfirmationUsesOriginalClientAndStopsAfterSwitchingAwayAndBack() async throws {
        let fixture = try makeControllerFixture(startResults: [])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try await seedUpgradeProfile(fixture.store)
        let session = makeUpgradeHTTPSession()
        defer { session.invalidateAndCancel() }
        let client = AgentAPIClient(endpoint: fixture.store.connectionEndpoint, token: "token-a", session: session)
        let context = try ManagedConnectionUpgradeContext(appStore: fixture.store, client: client)
        ManagedUpgradeURLProtocol.configure { request in
            request.respond(status: 409, body: #"{"code":"tailcat_self_hosted_clients_present","paired_device_count":2}"#)
        }
        await XCTAssertThrowsErrorAsync(try await context.requestPairingLink(confirmResetSelfHosted: false, appStore: fixture.store)) {
            XCTAssertEqual($0 as? ManagedPairingLinkAPIError, .selfHostedClientsPresent(count: 2))
        }
        ManagedUpgradeURLProtocol.configure { request in
            request.respond(body: Self.upgradeLinkResponse)
        }
        _ = try await context.requestPairingLink(confirmResetSelfHosted: true, appStore: fixture.store)
        XCTAssertEqual(ManagedUpgradeURLProtocol.requests.count, 1)
        XCTAssertEqual(ManagedUpgradeURLProtocol.requests.first?.url?.host, "192.168.1.20")
        XCTAssertEqual(ManagedUpgradeURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-a")
        let body = try XCTUnwrap(ManagedUpgradeURLProtocol.requests.first?.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Bool])
        XCTAssertEqual(payload["confirm_reset_self_hosted"], true)

        try await seedUpgradeProfile(fixture.store, id: "mac-b", endpoint: "http://192.168.1.21:8787")
        await XCTAssertThrowsErrorAsync(try await context.requestPairingLink(confirmResetSelfHosted: true, appStore: fixture.store)) {
            XCTAssertTrue($0 is CancellationError)
        }
        try await seedUpgradeProfile(fixture.store)
        await XCTAssertThrowsErrorAsync(try await context.requestPairingLink(confirmResetSelfHosted: true, appStore: fixture.store)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(ManagedUpgradeURLProtocol.requests.count, 1, "过期确认不能发出第二次请求")
    }

    func testUpgradeIgnoresLateSuccessAndResetConfirmationAfterHostSwitch() async throws {
        for status in [200, 409] {
            let fixture = try makeControllerFixture(startResults: [])
            defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
            try await seedUpgradeProfile(fixture.store)
            let session = makeUpgradeHTTPSession()
            defer { session.invalidateAndCancel() }
            let context = try ManagedConnectionUpgradeContext(
                appStore: fixture.store,
                client: AgentAPIClient(endpoint: fixture.store.connectionEndpoint, token: "token-a", session: session)
            )
            let requestStarted = expectation(description: "upgrade request started")
            var pending: ManagedUpgradeURLProtocol?
            ManagedUpgradeURLProtocol.configure { request in
                pending = request
                requestStarted.fulfill()
            }
            let task = Task { try await context.requestPairingLink(confirmResetSelfHosted: false, appStore: fixture.store) }
            await fulfillment(of: [requestStarted], timeout: 2)
            try await seedUpgradeProfile(fixture.store, id: "mac-b", endpoint: "http://192.168.1.21:8787")
            pending?.respond(status: status, body: status == 200 ? Self.upgradeLinkResponse : #"{"code":"tailcat_self_hosted_clients_present","paired_device_count":2}"#)

            await XCTAssertThrowsErrorAsync(try await task.value) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(fixture.store.activeConnectionProfileID, "mac-b")
            XCTAssertEqual(fixture.store.activeConnectionProfile?.endpoint, "http://192.168.1.21:8787")
        }
    }

    func testCancelledUpgradeCannotRequestOrPublishConfirmation() async throws {
        let fixture = try makeControllerFixture(startResults: [])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try await seedUpgradeProfile(fixture.store)
        let context = try ManagedConnectionUpgradeContext(appStore: fixture.store, client: fixture.store.client())
        ManagedUpgradeURLProtocol.configure { _ in XCTFail("取消后不应发送请求") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await context.requestPairingLink(confirmResetSelfHosted: true, appStore: fixture.store)
        }
        await XCTAssertThrowsErrorAsync(try await task.value) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(ManagedUpgradeURLProtocol.requests.isEmpty)
    }

    func testUpgradeCancellationWhileWaitingDoesNotPublishNetworkErrorOrConfirmation() async throws {
        let fixture = try makeControllerFixture(startResults: [])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try await seedUpgradeProfile(fixture.store)
        let session = makeUpgradeHTTPSession()
        defer { session.invalidateAndCancel() }
        let context = try ManagedConnectionUpgradeContext(
            appStore: fixture.store,
            client: AgentAPIClient(endpoint: fixture.store.connectionEndpoint, token: "token-a", session: session)
        )
        let started = expectation(description: "request is waiting")
        ManagedUpgradeURLProtocol.configure { _ in started.fulfill() }
        let task = Task { try await context.requestPairingLink(confirmResetSelfHosted: false, appStore: fixture.store) }
        await fulfillment(of: [started], timeout: 2)

        task.cancel()

        await XCTAssertThrowsErrorAsync(try await task.value) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(fixture.store.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(fixture.store.activeConnectionProfile?.connectionRoute, .lan)
    }

    func testStaleUpgradeCannotStartManagedAuthorizationOrClaim() async throws {
        let authorizer = ManagedPairingAuthorizerStub()
        let fixture = try makeControllerFixture(startResults: [], managedPairingAuthorizer: authorizer)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try await seedUpgradeProfile(fixture.store)
        let context = try ManagedConnectionUpgradeContext(appStore: fixture.store, client: fixture.store.client())
        let sessions = SessionStore(
            appStore: fixture.store, conversationStore: ConversationStore(), logStore: LogStore(),
            tailcatExperimentController: fixture.controller
        )
        try await seedUpgradeProfile(fixture.store, id: "mac-b", endpoint: "http://192.168.1.21:8787")

        await XCTAssertThrowsErrorAsync(try await sessions.applyManagedPairingURL(
            try XCTUnwrap(URL(string: Self.managedTailcatPairingURL)), upgrading: context
        )) { XCTAssertTrue($0 is CancellationError) }

        XCTAssertTrue(authorizer.requests.isEmpty)
        let starts = await fixture.runtime.startCallCount()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(fixture.store.activeConnectionProfileID, "mac-b")
    }

    private func seedUpgradeProfile(
        _ store: AppStore,
        id: String = "mac-a",
        endpoint: String = "http://192.168.1.20:8787",
        dnsName: String? = nil
    ) async throws {
        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: endpoint, token: "token-a",
            profileTarget: store.connectionProfiles.contains(where: { $0.id == id })
                ? .existingProfile(id: id) : .newProfile(id: id, displayName: id),
            tailscaleDNSName: dnsName
        ))
    }

    private func makeUpgradeHTTPSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagedUpgradeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let upgradeLinkResponse =
        #"{"pair_url":"mimiremote://pair","pair_expires_at":"2100-01-01T00:00:00Z","mode":"managed"}"#

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
        XCTAssertTrue(ManagedConnectionDevicesView.showsManagedRecoveryActions(
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

    func testManagedRetryRebuildsClosedLocalPortOnFirstAttempt() async throws {
        let fixture = try makeControllerFixture(
            startResults: [
                .success("http://127.0.0.1:49152"),
                .success("http://127.0.0.1:49153")
            ],
            localEndpointProbe: { _ in false },
            managedProfile: true
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let prepared = await fixture.controller.prepareRoute(appStore: fixture.store)
        XCTAssertTrue(prepared)

        let recovered = await fixture.controller.retryManagedConnection(appStore: fixture.store)
        let starts = await fixture.runtime.startCallCount()

        XCTAssertTrue(recovered)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(fixture.store.connectionEndpoint, "http://127.0.0.1:49153")
        XCTAssertEqual(fixture.controller.state, .connected(endpoint: "http://127.0.0.1:49153"))
    }

    func testManagedRetryLeavesTemporaryRouteAndStartsTailcat() async throws {
        let fixture = try makeControllerFixture(
            startResults: [
                .success("http://127.0.0.1:49152"),
                .success("http://127.0.0.1:49153")
            ],
            managedProfile: true
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let prepared = await fixture.controller.prepareRoute(appStore: fixture.store)
        let usedFallback = await fixture.controller.useSavedRouteOnce(.tailscale, appStore: fixture.store)
        XCTAssertTrue(prepared)
        XCTAssertTrue(usedFallback)

        let recovered = await fixture.controller.retryManagedConnection(appStore: fixture.store)
        let starts = await fixture.runtime.startCallCount()

        XCTAssertTrue(recovered)
        XCTAssertEqual(starts, 2)
        XCTAssertTrue(fixture.store.isTailcatExperimentModeEnabled)
        XCTAssertEqual(fixture.store.connectionEndpoint, "http://127.0.0.1:49153")
        XCTAssertEqual(fixture.controller.state, .connected(endpoint: "http://127.0.0.1:49153"))
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
        let recorder = TailcatRouteRecorder()
        let fixture = try makeControllerFixture(
            startResults: [
                .success("http://127.0.0.1:49152"),
                .success("http://127.0.0.1:49153")
            ],
            localEndpointProbe: { endpoint in
                await recorder.record(endpoint)
                return true
            }
        )
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
        let probedEndpoints = await recorder.endpoints
        XCTAssertEqual(probedEndpoints, ["http://127.0.0.1:49152"])
    }

    func testForegroundRecoveryRebuildsClosedLocalPortDespiteHealthyDiscoPing() async throws {
        let fixture = try makeControllerFixture(
            startResults: [
                .success("http://127.0.0.1:49152"),
                .success("http://127.0.0.1:49153")
            ],
            localEndpointProbe: { _ in false }
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.controller.setAddress("tailcat:test-address")
        let enabled = await fixture.controller.setEnabled(true, appStore: fixture.store)
        XCTAssertTrue(enabled)
        // 现场故障的关键条件：引擎仍可探活，但 App 使用的本地端口已经失效。
        _ = try await fixture.runtime.discoPing()

        let recovered = await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)
        let starts = await fixture.runtime.startCallCount()

        XCTAssertTrue(recovered)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(fixture.store.connectionEndpoint, "http://127.0.0.1:49153")
        XCTAssertEqual(fixture.controller.state, .connected(endpoint: "http://127.0.0.1:49153"))
    }

    func testClosedLocalPortRecoveryFailureKeepsTailcatFailClosed() async throws {
        let fixture = try makeControllerFixture(
            startResults: [.success("http://127.0.0.1:49152"), .failure(.startFailed)],
            localEndpointProbe: { _ in false }
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.endpoint = "http://100.64.0.10:8787"
        fixture.controller.setAddress("tailcat:test-address")
        let enabled = await fixture.controller.setEnabled(true, appStore: fixture.store)
        XCTAssertTrue(enabled)

        let recovered = await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)

        XCTAssertFalse(recovered)
        XCTAssertNil(fixture.store.tailcatExperimentEndpoint)
        XCTAssertEqual(fixture.store.connectionEndpoint, "http://127.0.0.1:1")
        XCTAssertEqual(fixture.store.endpoint, "http://100.64.0.10:8787")
    }

    func testCancelledLocalProbeDoesNotRestartOrClearCurrentProxy() async throws {
        let gate = TailcatLocalProbeGate()
        let fixture = try makeControllerFixture(
            startResults: [.success("http://127.0.0.1:49152")],
            localEndpointProbe: { _ in await gate.probe() }
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.controller.setAddress("tailcat:test-address")
        let enabled = await fixture.controller.setEnabled(true, appStore: fixture.store)
        XCTAssertTrue(enabled)
        let recovery = Task {
            await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)
        }
        await gate.waitForProbe()
        recovery.cancel()
        await gate.finish(false)

        let recovered = await recovery.value
        let starts = await fixture.runtime.startCallCount()
        XCTAssertFalse(recovered)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(fixture.store.tailcatExperimentEndpoint, "http://127.0.0.1:49152")
    }

    func testLocalProbeResultCannotOverwriteChangedAddressGeneration() async throws {
        let gate = TailcatLocalProbeGate()
        let fixture = try makeControllerFixture(
            startResults: [
                .success("http://127.0.0.1:49152"),
                .success("http://127.0.0.1:49153")
            ],
            localEndpointProbe: { _ in await gate.probe() }
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.controller.setAddress("tailcat:old-address")
        let enabled = await fixture.controller.setEnabled(true, appStore: fixture.store)
        XCTAssertTrue(enabled)
        let staleRecovery = Task {
            await fixture.controller.recoverRouteFromForeground(appStore: fixture.store)
        }
        await gate.waitForProbe()
        fixture.controller.setAddress("tailcat:new-address")
        let prepared = await fixture.controller.prepareRoute(appStore: fixture.store)
        XCTAssertTrue(prepared)
        await gate.finish(false)

        let recovered = await staleRecovery.value
        let starts = await fixture.runtime.startCallCount()
        XCTAssertFalse(recovered)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(fixture.store.tailcatExperimentEndpoint, "http://127.0.0.1:49153")
        XCTAssertEqual(fixture.controller.state, .connected(endpoint: "http://127.0.0.1:49153"))
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
        localEndpointProbe: @escaping @Sendable (String) async -> Bool = { _ in true },
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
            localEndpointProbe: localEndpointProbe,
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
