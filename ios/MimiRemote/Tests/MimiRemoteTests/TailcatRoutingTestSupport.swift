import XCTest
@testable import MimiRemote

actor TailcatRouteRecorder {
    private(set) var endpoints: [String] = []

    func record(_ endpoint: String) {
        endpoints.append(endpoint)
    }
}

actor TailcatLocalProbeGate {
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

enum TailcatRuntimeStubError: Error, Equatable {
    case startFailed
    case unhealthy
    case closeFailed
}

actor TailcatExperimentRuntimeStub: TailcatExperimentRuntimeProtocol {
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
    private var preparedAddressLog: [String] = []
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

    func preparedAddresses() -> [String] {
        preparedAddressLog
    }

    func prepare(address: String, privateKey: String) async throws -> String {
        preparedAddressLog.append(address)
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

final class TailcatProxyFactoryRecorder: @unchecked Sendable {
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

final class TailcatProxyStub: TailcatProxyProtocol, @unchecked Sendable {
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
final class ManagedPairingAuthorizerStub: ManagedConnectionPairingAuthorizing {
    private(set) var requests: [(macInstallationID: String, macKey: String, pairingMacKey: String, mobileKey: String)] = []
    private(set) var completions: [ManagedConnectionPairingAuthorization] = []
    var error: Error?

    func authorizeManagedPairing(
        macInstallationID: String,
        macTailcatPublicKey: String,
        pairingMacTailcatPublicKey: String,
        mobileTailcatPublicKey: String
    ) async throws -> ManagedConnectionPairingAuthorization {
        requests.append((macInstallationID, macTailcatPublicKey, pairingMacTailcatPublicKey, mobileTailcatPublicKey))
        if let error { throw error }
        return ManagedConnectionPairingAuthorization(sessionID: "managed-session", grant: "managed-grant")
    }

    func didCompleteManagedPairing(_ authorization: ManagedConnectionPairingAuthorization) {
        completions.append(authorization)
    }
}

@MainActor
final class ManagedConnectionEventReporterStub: ManagedConnectionEventReporting {
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
final class ManagedUpgradeURLProtocol: URLProtocol {
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
        (request.url?.path.hasPrefix("/api/tailcat/") == true) || request.url?.path == "/api/pair/claim"
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

/// 并发事件测试只需要健康探测结束，不依赖本机随机端口是否碰巧有服务。
final class TailcatUnavailableHealthURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

@MainActor
extension TailcatExperimentRoutingTests {
    func makeControllerFixture(
        startResults: [Result<String, TailcatRuntimeStubError>],
        blockedStartCall: Int? = nil,
        localEndpointProbe: @escaping @Sendable (String) async -> Bool = { _ in true },
        managedPairingAuthorizer: (any ManagedConnectionPairingAuthorizing)? = nil,
        managedProfile: Bool = false,
        managedAddress: String? = "tailcat:managed-mac",
        bridgeAvailable: Bool = true,
        managedConnectionEventReporter: (any ManagedConnectionEventReporting)? = nil,
        routeProbe: ConnectionRouteProbe? = nil,
        agentAPISession: URLSession = .shared
    ) throws -> (
        controller: TailcatExperimentController,
        runtime: TailcatExperimentRuntimeStub,
        store: AppStore,
        defaults: UserDefaults,
        suiteName: String,
        tokenStore: TokenStore
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
            routeProbe: routeProbe ?? { _, _, _ in },
            agentAPISession: agentAPISession
        )
        let controller = TailcatExperimentController(
            appStore: store,
            defaults: defaults,
            tokenStore: tokenStore,
            runtime: runtime,
            localEndpointProbe: localEndpointProbe,
            bridge: bridge,
            managedPairingAuthorizer: managedPairingAuthorizer,
            managedConnectionEventReporter: managedConnectionEventReporter,
            networkKind: { .cellular }
        )
        return (controller, runtime, store, defaults, suiteName, tokenStore)
    }

    static let freeTailcatPairingURL =
        "mimiremote://pair?endpoint=http%3A%2F%2F127.0.0.1%3A8787&issued_at=2026-09-01T00%3A00%3A00Z&expires_at=4102444800&pair_sig=abcdef&transport=tailcat&tailcat_pair_address=tc%3Atest-address"

    static let legacyManagedTailcatPairingURL = freeTailcatPairingURL
        + "&managed_mac_installation_id=20000000-0000-4000-8000-000000000001"
        + "&managed_mac_tailcat_public_key=nodekey%3Amac-public"

    static let managedTailcatPairingURL = legacyManagedTailcatPairingURL
        + "&managed_pair_tailcat_public_key=nodekey%3Apair-public"}
