import XCTest
@testable import MimiRemote

@MainActor
final class HostStatusStoreTests: XCTestCase {
    override func tearDown() {
        HostStatusURLProtocol.reset()
        super.tearDown()
    }

    func testSingleProfileUsesKnownPlatformIconAndRefreshesUnknownPlatform() {
        let knownProfile = ConnectionProfile(
            id: "known",
            displayName: "Mac",
            endpoint: "http://127.0.0.1:8787",
            lastSuccessfulAt: nil,
            hostPlatform: .apple
        )
        let windowsProfile = ConnectionProfile(
            id: "windows",
            displayName: "Windows PC",
            endpoint: "http://127.0.0.1:8787",
            lastSuccessfulAt: nil,
            hostPlatform: .windows
        )
        let unknownProfile = ConnectionProfile(
            id: "unknown",
            displayName: "Computer",
            endpoint: "http://127.0.0.1:8787",
            lastSuccessfulAt: nil
        )

        XCTAssertEqual(HostSwitcherMenu.iconKind(for: knownProfile), .apple)
        XCTAssertEqual(HostSwitcherMenu.iconKind(for: windowsProfile), .windows11)
        XCTAssertFalse(HostSwitcherMenu.needsPlatformRefresh([knownProfile]))
        XCTAssertEqual(HostSwitcherMenu.iconKind(for: unknownProfile), .genericComputer)
        XCTAssertTrue(HostSwitcherMenu.needsPlatformRefresh([unknownProfile]))
    }

    func testToolbarConnectionBadgeHidesHealthyStateAndUsesExplicitExceptions() {
        XCTAssertEqual(
            HostToolbarConnectionBadge.resolve(
                isSwitching: false,
                isNetworkUnavailable: false,
                connectionStatus: .connected("ok")
            ),
            .hidden
        )
        XCTAssertEqual(
            HostToolbarConnectionBadge.resolve(
                isSwitching: false,
                isNetworkUnavailable: false,
                connectionStatus: .testing
            ),
            .progress
        )
        XCTAssertEqual(
            HostToolbarConnectionBadge.resolve(
                isSwitching: false,
                isNetworkUnavailable: true,
                connectionStatus: .connected("cached")
            ),
            .offline
        )
        XCTAssertEqual(
            HostToolbarConnectionBadge.resolve(
                isSwitching: false,
                isNetworkUnavailable: false,
                connectionStatus: .failed("timeout")
            ),
            .failed
        )
        XCTAssertEqual(
            HostToolbarConnectionBadge.resolve(
                isSwitching: false,
                isNetworkUnavailable: false,
                connectionStatus: .idle
            ),
            .unknown
        )
        XCTAssertEqual(
            HostToolbarConnectionBadge.resolve(
                isSwitching: true,
                isNetworkUnavailable: true,
                connectionStatus: .failed("old failure")
            ),
            .progress,
            "主动切换期间沿用即时进度反馈，结束后再显示最终异常状态"
        )
    }

    func testToolbarConnectionBadgeDefersProgressToThePageThatAlreadyShowsIt() {
        XCTAssertEqual(
            HostToolbarConnectionBadge.resolve(
                isSwitching: true,
                isNetworkUnavailable: false,
                connectionStatus: .idle,
                pageShowsConnectionProgress: true
            ),
            .hidden,
            "正文的连接过渡已经在表达进行中，顶栏不再叠第二枚转圈"
        )
        XCTAssertEqual(
            HostToolbarConnectionBadge.resolve(
                isSwitching: false,
                isNetworkUnavailable: false,
                connectionStatus: .testing,
                pageShowsConnectionProgress: true
            ),
            .hidden
        )
        // 结论型状态不属于"正在进行"，正文那一处不表达它们，徽标必须继续出现。
        XCTAssertEqual(
            HostToolbarConnectionBadge.resolve(
                isSwitching: false,
                isNetworkUnavailable: true,
                connectionStatus: .connected("cached"),
                pageShowsConnectionProgress: true
            ),
            .offline
        )
        XCTAssertEqual(
            HostToolbarConnectionBadge.resolve(
                isSwitching: false,
                isNetworkUnavailable: false,
                connectionStatus: .failed("timeout"),
                pageShowsConnectionProgress: true
            ),
            .failed
        )
    }

    func testLoadingOrbitArcRevolvesAndBreathesWithinBounds() {
        let origin = LoadingOrbit.arc(time: 0, animates: true)
        XCTAssertEqual(origin.start, 0, accuracy: 0.0001, "零时刻从正上方起步")

        let quarterTurn = LoadingOrbit.arc(time: LoadingOrbit.revolutionDuration / 4, animates: true)
        XCTAssertEqual(quarterTurn.start, 0.25, accuracy: 0.0001, "匀速转动：四分之一周期走四分之一圈")

        let fullTurn = LoadingOrbit.arc(time: LoadingOrbit.revolutionDuration, animates: true)
        XCTAssertEqual(fullTurn.start, 0, accuracy: 0.0001, "转满一圈回到起点，不跳帧")

        // 弧长在区间内伸缩，且确实会变：不会退化成一个点，也不会长成整圈。
        let samples = stride(from: 0.0, to: LoadingOrbit.breathDuration, by: 0.05).map {
            LoadingOrbit.arc(time: 1_000_000 + $0, animates: true)
        }
        for arc in samples {
            XCTAssertTrue((0..<1).contains(arc.start))
            XCTAssertTrue((LoadingOrbit.minArcLength...LoadingOrbit.maxArcLength).contains(arc.length))
        }
        let lengths = samples.map(\.length)
        XCTAssertEqual(lengths.min() ?? 0, LoadingOrbit.minArcLength, accuracy: 0.01)
        XCTAssertEqual(lengths.max() ?? 0, LoadingOrbit.maxArcLength, accuracy: 0.01)
    }

    func testLoadingOrbitStopsAtRestingArcUnderReduceMotion() {
        XCTAssertEqual(LoadingOrbit.arc(time: 0, animates: false), LoadingOrbit.restingArc)
        XCTAssertEqual(
            LoadingOrbit.arc(time: 12.3, animates: false),
            LoadingOrbit.restingArc,
            "减弱动态效果下弧与时间无关"
        )
        XCTAssertGreaterThan(LoadingOrbit.restingArc.length, 0, "静止时仍要看得出是一段弧")
    }

    func testLoadingOrbitRingIsThickAtEverySize() {
        for size in [LoadingOrbit.Size.large, .regular] {
            let diameter = size.diameter
            let lineWidth = LoadingOrbit.lineWidth(diameter: diameter)
            // 环身约占直径的 29%：这正是替换细水纹的理由（#624）。
            XCTAssertEqual(lineWidth / diameter, 0.29, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(lineWidth, 10, "面板尺寸也不能细成一根线")
        }
    }

    func testProbeRequestsOnlyInactiveProfileAndReusesSuccessTTL() async throws {
        let fixture = try makeFixture(
            inactiveExpectedInstallationID: "installation-b",
            returnedInstallationID: "installation-b"
        )

        fixture.statusStore.refreshIfNeeded(appStore: fixture.appStore, sessionStore: fixture.sessionStore)
        await fixture.statusStore.waitForRefreshForTesting()

        XCTAssertEqual(fixture.statusStore.status(for: fixture.inactiveProfile).state, .available)
        XCTAssertEqual(HostStatusURLProtocol.requestedHosts(), ["100.64.0.20"])
        XCTAssertEqual(HostStatusURLProtocol.requestedPaths(), ["/api/version"])
        XCTAssertEqual(
            fixture.appStore.connectionProfiles.first(where: { $0.id == fixture.inactiveProfile.id })?.hostPlatform,
            .windows
        )

        fixture.statusStore.refreshIfNeeded(appStore: fixture.appStore, sessionStore: fixture.sessionStore)
        await fixture.statusStore.waitForRefreshForTesting()
        XCTAssertEqual(HostStatusURLProtocol.requestedHosts(), ["100.64.0.20"])
    }

    func testIdentityMismatchBecomesTerminalForUnchangedProfile() async throws {
        let fixture = try makeFixture(
            inactiveExpectedInstallationID: "installation-b",
            returnedInstallationID: "unexpected-installation"
        )

        fixture.statusStore.refreshIfNeeded(appStore: fixture.appStore, sessionStore: fixture.sessionStore)
        await fixture.statusStore.waitForRefreshForTesting()
        let firstStatus = fixture.statusStore.status(for: fixture.inactiveProfile)

        XCTAssertEqual(firstStatus.state, .identityMismatch)
        XCTAssertEqual(firstStatus.nextEligibleAt, .distantFuture)

        fixture.statusStore.refreshIfNeeded(appStore: fixture.appStore, sessionStore: fixture.sessionStore)
        await fixture.statusStore.waitForRefreshForTesting()
        XCTAssertEqual(HostStatusURLProtocol.requestedHosts().count, 1)
    }

    func testProbeFallsBackFromDNSNameToIPAndSafelyRefreshesMetadata() async throws {
        let fixture = try makeFixture(
            inactiveExpectedInstallationID: "installation-b",
            returnedInstallationID: "installation-b",
            inactiveTailscaleDNSName: "old-mac.tailnet.ts.net",
            returnedTailscaleDNSName: "new-mac.tailnet.ts.net",
            failingHosts: ["old-mac.tailnet.ts.net"]
        )

        fixture.statusStore.refreshIfNeeded(appStore: fixture.appStore, sessionStore: fixture.sessionStore)
        await fixture.statusStore.waitForRefreshForTesting()

        let refreshed = try XCTUnwrap(
            fixture.appStore.connectionProfiles.first(where: { $0.id == fixture.inactiveProfile.id })
        )
        XCTAssertEqual(
            HostStatusURLProtocol.requestedHosts(),
            ["old-mac.tailnet.ts.net", "100.64.0.20"]
        )
        XCTAssertEqual(refreshed.tailscaleDNSName, "new-mac.tailnet.ts.net")
        XCTAssertEqual(refreshed.displayName, "Mac B", "用户自定义名称不能被 Tailscale 改名覆盖")
        XCTAssertEqual(fixture.statusStore.status(for: refreshed).state, .available)
    }

    func testProbeFallsBackToIPAfterDNSIdentityMismatch() async throws {
        let fixture = try makeFixture(
            inactiveExpectedInstallationID: "installation-b",
            returnedInstallationID: "installation-b",
            inactiveTailscaleDNSName: "old-mac.tailnet.ts.net",
            installationIDsByHost: [
                "old-mac.tailnet.ts.net": "unexpected-installation",
                "100.64.0.20": "installation-b",
            ]
        )

        fixture.statusStore.refreshIfNeeded(appStore: fixture.appStore, sessionStore: fixture.sessionStore)
        await fixture.statusStore.waitForRefreshForTesting()

        XCTAssertEqual(
            HostStatusURLProtocol.requestedHosts(),
            ["old-mac.tailnet.ts.net", "100.64.0.20"]
        )
        XCTAssertEqual(fixture.statusStore.status(for: fixture.inactiveProfile).state, .available)
    }

    func testProbeBackfillsPlatformForLegacyActiveProfile() async throws {
        let fixture = try makeFixture(
            inactiveExpectedInstallationID: "installation-b",
            returnedInstallationID: "installation-b",
            activeHostPlatform: .unknown
        )

        fixture.statusStore.refreshIfNeeded(appStore: fixture.appStore, sessionStore: fixture.sessionStore)
        await fixture.statusStore.waitForRefreshForTesting()

        XCTAssertTrue(HostStatusURLProtocol.requestedHosts().contains("100.64.0.10"))
        XCTAssertEqual(
            fixture.appStore.connectionProfiles.first(where: { $0.id == "mac-a" })?.hostPlatform,
            .windows
        )
    }

    private func makeFixture(
        inactiveExpectedInstallationID: String,
        returnedInstallationID: String,
        inactiveTailscaleDNSName: String? = nil,
        returnedTailscaleDNSName: String? = nil,
        failingHosts: Set<String> = [],
        installationIDsByHost: [String: String] = [:],
        activeHostPlatform: HostPlatform = .apple
    ) throws -> (
        appStore: AppStore,
        sessionStore: SessionStore,
        statusStore: HostStatusStore,
        inactiveProfile: ConnectionProfile
    ) {
        let suiteName = "HostStatusStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let active = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil,
            installationID: "installation-a",
            hostPlatform: activeHostPlatform
        )
        let inactive = ConnectionProfile(
            id: "mac-b",
            displayName: "Mac B",
            endpoint: "http://100.64.0.20:8787",
            tailscaleDNSName: inactiveTailscaleDNSName,
            tailscaleDeviceName: inactiveTailscaleDNSName == nil ? nil : "old-mac",
            lastSuccessfulAt: nil,
            installationID: inactiveExpectedInstallationID
        )
        defaults.set(try JSONEncoder().encode([active, inactive]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(active.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(active.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )

        HostStatusURLProtocol.installationID = returnedInstallationID
        HostStatusURLProtocol.tailscaleDNSName = returnedTailscaleDNSName
        HostStatusURLProtocol.tailscaleDeviceName = returnedTailscaleDNSName == nil ? nil : "new-mac"
        HostStatusURLProtocol.failingHosts = failingHosts
        HostStatusURLProtocol.installationIDsByHost = installationIDsByHost
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostStatusURLProtocol.self]
        let statusStore = HostStatusStore(
            session: URLSession(configuration: configuration),
            jitter: { 1 }
        )
        return (appStore, sessionStore, statusStore, inactive)
    }
}

private final class HostStatusURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var hosts: [String] = []
    private static var paths: [String] = []
    static var installationID = "installation-b"
    static var tailscaleDNSName: String?
    static var tailscaleDeviceName: String?
    static var failingHosts: Set<String> = []
    static var installationIDsByHost: [String: String] = [:]
    static var platform = "windows"

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.hosts.append(url.host ?? "")
        Self.paths.append(url.path)
        let host = url.host ?? ""
        let installationID = host == "100.64.0.10"
            ? "installation-a"
            : (Self.installationIDsByHost[host] ?? Self.installationID)
        let tailscaleDNSName = Self.tailscaleDNSName
        let tailscaleDeviceName = Self.tailscaleDeviceName
        let platform = Self.platform
        let shouldFail = Self.failingHosts.contains(url.host ?? "")
        Self.lock.unlock()

        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var payload: [String: Any] = [
            "name": "agentd",
            "version": "test",
            "installation_id": installationID,
            "platform": platform,
        ]
        if let tailscaleDNSName {
            payload["tailscale_dns_name"] = tailscaleDNSName
        }
        if let tailscaleDeviceName {
            payload["tailscale_device_name"] = tailscaleDeviceName
        }
        let body = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func requestedHosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    static func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    static func reset() {
        lock.lock()
        hosts = []
        paths = []
        installationID = "installation-b"
        tailscaleDNSName = nil
        tailscaleDeviceName = nil
        failingHosts = []
        installationIDsByHost = [:]
        platform = "windows"
        lock.unlock()
    }
}
