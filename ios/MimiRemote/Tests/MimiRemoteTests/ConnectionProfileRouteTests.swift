import XCTest
@testable import MimiRemote

@MainActor
final class ConnectionProfileRouteTests: XCTestCase {
    func testLegacyTailcatMigratesToFreeCustomRoute() throws {
        let profile = try decodeLegacyProfile(
            endpoint: "http://100.64.0.10:8787",
            route: "tailcat"
        )
        XCTAssertEqual(profile.connectionRoute, .customTailcat)
    }

    func testLegacyConfiguredRouteUsesSavedEndpointWithoutChangingIt() throws {
        let tailscale = try decodeLegacyProfile(
            endpoint: "http://100.64.0.10:8787",
            route: "configured"
        )
        let lan = try decodeLegacyProfile(
            endpoint: "http://192.168.1.20:8787",
            route: "configured"
        )
        let https = try decodeLegacyProfile(
            endpoint: "https://mac.example.com",
            route: "configured"
        )

        XCTAssertEqual(tailscale.connectionRoute, .tailscale)
        XCTAssertEqual(lan.connectionRoute, .lan)
        XCTAssertEqual(https.connectionRoute, .https)
        XCTAssertEqual(tailscale.endpoint, "http://100.64.0.10:8787")
        XCTAssertEqual(lan.endpoint, "http://192.168.1.20:8787")
        XCTAssertEqual(https.endpoint, "https://mac.example.com")
    }

    func testManagedAndCustomPairingProduceDifferentPersistentTypes() async throws {
        let suiteName = "ConnectionProfileRouteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )

        let managed = try await store.prepareRoutedConnectionSettings(
            endpoint: "http://100.64.0.10:8787",
            activeEndpoint: "http://127.0.0.1:49152",
            tailcatAddress: "tailcat:managed",
            managed: true,
            token: "token",
            profileTarget: .newProfile(id: "managed", displayName: "Managed")
        )
        let custom = try await store.prepareRoutedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            activeEndpoint: "http://127.0.0.1:49153",
            tailcatAddress: "tailcat:custom",
            token: "token",
            profileTarget: .newProfile(id: "custom", displayName: "Custom")
        )

        XCTAssertEqual(managed.route.profileRoute, .managedTailcat)
        XCTAssertEqual(custom.route.profileRoute, .customTailcat)
    }

    func testTemporaryFallbackProbeDoesNotChangeManagedDefault() async throws {
        let suiteName = "ConnectionProfileRouteTests.Fallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = TokenStore(keychain: TestKeychainOperations())
        let profile = ConnectionProfile(
            id: "managed-mac",
            displayName: "Managed Mac",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil,
            installationID: "10000000-0000-4000-8000-000000000001",
            connectionRoute: .managedTailcat
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        try tokenStore.save("token", profileID: profile.id)
        let store = AppStore(
            defaults: defaults,
            tokenStore: tokenStore,
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )

        let connected = await store.preflightConnection(
            force: true,
            preferredProfileRoute: .tailscale
        )

        XCTAssertTrue(connected)
        XCTAssertEqual(store.activeConnectionProfile?.connectionRoute, .managedTailcat)
        XCTAssertEqual(store.savedFallbackConnectionRoute, .tailscale)
    }

    func testDefaultPreflightRetriesSavedRouteWithClaudeOnlyGateway() async throws {
        let suiteName = "ConnectionProfileRouteTests.ClaudeRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = TokenStore(keychain: TestKeychainOperations())
        let profile = ConnectionProfile(
            id: "claude-managed-mac",
            displayName: "Claude Managed Mac",
            endpoint: "http://100.64.0.10:8787",
            tailscaleDNSName: "claude-managed.tailnet.ts.net",
            lastSuccessfulAt: nil,
            installationID: "10000000-0000-4000-8000-000000000042",
            connectionRoute: .managedTailcat
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        try tokenStore.save("token", profileID: profile.id)
        let fixture = ClaudeOnlyProbeHTTPFixture(
            installationID: try XCTUnwrap(profile.installationID),
            failingConfigHosts: ["claude-managed.tailnet.ts.net"]
        )
        defer { fixture.invalidate() }
        let recorder = GatewayProbeURLRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: tokenStore,
            prefersLocalConnection: false,
            agentAPISession: fixture.session,
            gatewayProbeTransportFactory: { AutoInitializingGatewayProbeTransport(recorder: recorder) }
        )

        let connected = await store.preflightConnection(force: true, preferredProfileRoute: .tailscale)

        XCTAssertTrue(connected)
        XCTAssertEqual(fixture.configRequestHosts, ["claude-managed.tailnet.ts.net", "100.64.0.10"])
        let probeURLs = await recorder.snapshot()
        XCTAssertEqual(probeURLs.count, 1)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(probeURLs.first), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "runtime" })?.value, "claude")
        XCTAssertFalse(probeURLs.contains { $0.absoluteString.contains("runtime=codex") })
    }

    func testValidateConnectionUsesClaudeOnlyGateway() async throws {
        let suiteName = "ConnectionProfileRouteTests.Validate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = ClaudeOnlyProbeHTTPFixture(
            installationID: "10000000-0000-4000-8000-000000000043"
        )
        defer { fixture.invalidate() }
        let recorder = GatewayProbeURLRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            agentAPISession: fixture.session,
            gatewayProbeTransportFactory: { AutoInitializingGatewayProbeTransport(recorder: recorder) }
        )

        let endpoint = try await store.validateConnection(
            endpoint: "http://100.64.0.11:8787",
            token: "token",
            route: .tailscale
        )

        XCTAssertEqual(endpoint, "http://100.64.0.11:8787")
        let probeURLs = await recorder.snapshot()
        XCTAssertEqual(probeURLs.count, 1)
        XCTAssertTrue(try XCTUnwrap(probeURLs.first).absoluteString.contains("runtime=claude"))
        XCTAssertFalse(probeURLs.contains { $0.absoluteString.contains("runtime=codex") })
    }

    private func decodeLegacyProfile(endpoint: String, route: String) throws -> ConnectionProfile {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "legacy",
            "displayName": "Legacy Mac",
            "endpoint": endpoint,
            "connectionRoute": route,
            "revision": 0,
        ])
        return try JSONDecoder().decode(ConnectionProfile.self, from: data)
    }
}

private final class ClaudeOnlyProbeHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedConfigHosts: [String] = []
    private let installationID: String
    private let failingConfigHosts: Set<String>
    private let fixtureID: String
    let session: URLSession

    init(installationID: String, failingConfigHosts: Set<String> = []) {
        self.installationID = installationID
        self.failingConfigHosts = failingConfigHosts
        let configuration = URLSessionConfiguration.ephemeral
        fixtureID = UUID().uuidString
        configuration.protocolClasses = [ClaudeOnlyProbeURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Mimi-Probe-Fixture": fixtureID]
        session = URLSession(configuration: configuration)
        ClaudeOnlyProbeURLProtocol.register(fixtureID: fixtureID, fixture: self)
    }

    func invalidate() {
        ClaudeOnlyProbeURLProtocol.unregister(fixtureID: fixtureID)
        session.invalidateAndCancel()
    }

    var configRequestHosts: [String] {
        lock.withLock { requestedConfigHosts }
    }

    func response(for request: URLRequest) throws -> (Int, Data) {
        let url = try XCTUnwrap(request.url)
        let host = url.host ?? ""
        switch url.path {
        case "/healthz":
            return (200, try JSONEncoder().encode(HealthResponse(ok: true, version: "0.1.0")))
        case "/api/version":
            return (200, try JSONEncoder().encode(VersionResponse(
                name: "agentd",
                version: "0.1.0",
                installationID: installationID,
                platform: "macos"
            )))
        case "/api/app-server/config":
            lock.withLock { requestedConfigHosts.append(host) }
            guard !failingConfigHosts.contains(host) else {
                return (503, Data(#"{"error":"route unavailable"}"#.utf8))
            }
            let project = makeProject(id: "claude-only-probe")
            return (200, try JSONEncoder().encode(makeDirectAppServerConfig(
                project: project,
                gatewayAvailable: false,
                channels: [makeClaudeChannelMetadata()]
            )))
        default:
            return (404, Data(#"{"error":"not found"}"#.utf8))
        }
    }
}

private final class ClaudeOnlyProbeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: ClaudeOnlyProbeHTTPFixture] = [:]

    static func register(fixtureID: String, fixture: ClaudeOnlyProbeHTTPFixture) {
        lock.withLock { fixtures[fixtureID] = fixture }
    }

    static func unregister(fixtureID: String) {
        _ = lock.withLock { fixtures.removeValue(forKey: fixtureID) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let fixtureID = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Mimi-Probe-Fixture"))
            let fixture = try XCTUnwrap(Self.lock.withLock { Self.fixtures[fixtureID] })
            let (status, data) = try fixture.response(for: request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor GatewayProbeURLRecorder {
    private var urls: [URL] = []

    func record(_ url: URL) { urls.append(url) }
    func snapshot() -> [URL] { urls }
}

private final class AutoInitializingGatewayProbeTransport: CodexAppServerTransport {
    private let recorder: GatewayProbeURLRecorder
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var iterator: AsyncThrowingStream<String, Error>.Iterator

    init(recorder: GatewayProbeURLRecorder) {
        self.recorder = recorder
        var captured: AsyncThrowingStream<String, Error>.Continuation?
        let stream = AsyncThrowingStream<String, Error> { captured = $0 }
        continuation = captured!
        iterator = stream.makeAsyncIterator()
    }

    func connect(url: URL, token: String) async throws {
        await recorder.record(url)
    }

    func send(_ text: String) async throws {
        guard let request = try? decodeAppServerRequest(text), request.method == "initialize" else { return }
        continuation.yield(#"{"id":\#(try jsonFragment(for: request.id)),"result":{"userAgent":"fake-claude","platformFamily":"macos"}}"#)
    }

    func receive() async throws -> String? { try await iterator.next() }
    func close() async { continuation.finish() }
}
