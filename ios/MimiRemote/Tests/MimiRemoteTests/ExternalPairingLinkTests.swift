import XCTest
@testable import MimiRemote

/// 系统相机扫码等外部配对链接由 App 层配对。还没有任何电脑时，首次配对页不读全局
/// `lastError`，只能靠 `pairingLinkAttempt` 看到进度和失败原因（#728）。
@MainActor
final class ExternalPairingLinkTests: XCTestCase {
    private static let expiredTicketLink = URL(
        string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787"
            + "&issued_at=2020-01-01T00%3A00%3A00Z&expires_at=2020-01-01T00%3A10%3A00Z&pair_sig=test-signature"
    )!
    private static let tokenLink = URL(
        string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=test-token"
    )!

    func testFirstConnectionFailurePublishesReasonForFirstConnectionPage() async throws {
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in })

        await store.openPairingLink(Self.expiredTicketLink)

        let expected = PairingLinkError.expired.localizedDescription
        XCTAssertEqual(store.pairingLinkAttempt, .failed(expected), "首次配对页要拿到原始原因，再按本页规则友好化")
        XCTAssertEqual(appStore.lastError, expected, "全局错误照旧记录，已有电脑的页面还在读它")
    }

    func testFirstConnectionReportsConnectingUntilPreparationFails() async throws {
        let gate = RouteProbeGate()
        let (store, _) = makeStores(routeProbe: { _, _, _ in try await gate.wait() })

        let opening = Task { await store.openPairingLink(Self.tokenLink) }
        try await waitUntil { gate.isWaiting }
        XCTAssertEqual(store.pairingLinkAttempt, .connecting, "验证进行中，首次配对页要能禁用按钮并显示正在连接")

        gate.fail(URLError(.cannotConnectToHost))
        await opening.value

        guard case .failed = store.pairingLinkAttempt else {
            return XCTFail("验证失败后必须交出失败原因，而不是停在连接中：\(store.pairingLinkAttempt)")
        }
    }

    func testFirstConnectionSuccessReturnsToIdle() async throws {
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in })

        await store.openPairingLink(Self.tokenLink)

        XCTAssertEqual(store.pairingLinkAttempt, .idle)
        XCTAssertEqual(appStore.connectionProfiles.count, 1)
    }

    func testConfiguredAppLeavesFirstConnectionPageStateUntouched() async throws {
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in })
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.30:8787",
            token: "existing-token"
        ))

        await store.openPairingLink(Self.expiredTicketLink)

        XCTAssertEqual(store.pairingLinkAttempt, .idle, "已有电脑时由设备页显示全局错误，首次配对页的状态不能残留")
        XCTAssertEqual(appStore.lastError, PairingLinkError.expired.localizedDescription)
    }

    /// 忘记当前电脑后只剩其它电脑时，设备页没有当前电脑卡片显示全局错误，
    /// 外部链接配对失败只能经 `pairingLinkAttempt` 交给页面，否则用户看不到任何反馈（#959）。
    func testFailureWithoutCurrentComputerIsPublishedEvenWhenOtherComputersAreSaved() async throws {
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in })
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.30:8787",
            token: "other-token"
        ))
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.31:8787",
            token: "current-token",
            profileTarget: .newProfile(id: UUID().uuidString, displayName: "Current")
        ))
        try await store.clearCurrentConnectionProfile()
        XCTAssertNil(appStore.activeConnectionProfile)
        XCTAssertFalse(appStore.connectionProfiles.isEmpty)

        await store.openPairingLink(Self.expiredTicketLink)

        XCTAssertEqual(store.pairingLinkAttempt, .failed(PairingLinkError.expired.localizedDescription))
        XCTAssertEqual(store.lastPairingLinkRoute, .tailscale)
    }

    func testFailedLANPairingLinkRecordsLANRouteAndClearsAfterSuccess() async throws {
        let lanLink = URL(
            string: "mimiremote://pair?endpoint=http%3A%2F%2F192.168.1.20%3A8787&token=test-token"
        )!
        var shouldFail = true
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in
            if shouldFail {
                throw URLError(.cannotConnectToHost)
            }
        })

        await store.openPairingLink(lanLink)
        XCTAssertEqual(store.lastPairingLinkRoute, .lan)
        XCTAssertEqual(
            ConnectionFailureGuidance.friendlyMessage(
                from: try XCTUnwrap(appStore.lastError),
                route: store.lastPairingLinkRoute
            ),
            L10n.text("ui.connection_failure_guidance_lan")
        )

        shouldFail = false
        await store.openPairingLink(lanLink)
        XCTAssertNil(store.lastPairingLinkRoute)
    }

    func testBackgroundPairingLinkWaitsForForegroundResumeBeforeApplying() async throws {
        var probeCallCount = 0
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in
            probeCallCount += 1
        })
        store.suspendForBackground()
        XCTAssertTrue(store.isAppInBackground)

        let opening = Task {
            await store.openPairingLink(Self.tokenLink, foregroundWaitTimeoutNanoseconds: 2_000_000_000)
        }
        try await waitUntil { store.pairingLinkAttempt == .connecting }
        XCTAssertEqual(probeCallCount, 0, "前台恢复落地前不应提前触发会被后台门禁取消的连接变更")

        await store.resumeFromForeground()
        await opening.value

        XCTAssertEqual(probeCallCount, 1)
        XCTAssertEqual(store.pairingLinkAttempt, .idle)
        XCTAssertTrue(appStore.isConfigured)
        XCTAssertEqual(appStore.connectionProfiles.count, 1)
    }

    func testLANPairingGuidanceMentionsMimiRelayWhenEntitlementIsActive() {
        let error = URLError(.cannotConnectToHost)
        let withMimi = ConnectionFailureGuidance.message(
            for: error,
            route: .lan,
            hasActiveMimiEntitlement: true
        )
        let withoutMimi = ConnectionFailureGuidance.message(
            for: error,
            route: .lan,
            hasActiveMimiEntitlement: false
        )

        XCTAssertEqual(withMimi, L10n.text("ui.connection_failure_guidance_lan_with_mimi"))
        XCTAssertEqual(withoutMimi, L10n.text("ui.connection_failure_guidance_lan"))
        XCTAssertNotEqual(withMimi, withoutMimi)
    }

    func testShortSchemeLANPairingURLResolvesToLANRoute() {
        let shortLAN = URL(string: "mimi://pair?endpoint=http%3A%2F%2F192.168.1.20%3A8787&token=t")!
        let standardLAN = URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F192.168.1.20%3A8787&token=t")!

        XCTAssertEqual(ConnectionProfileRoute.fromPairingURL(shortLAN), .lan)
        XCTAssertEqual(ConnectionProfileRoute.fromPairingURL(standardLAN), .lan)
    }

    func testClaimPairingRetriesTransientTransportErrorAndStopsOnAuthError() async throws {
        var attempts = 0
        var sleepDelays: [UInt64] = []
        let expected = PairingClaimResponse(
            endpoint: "http://192.168.1.20:8787",
            token: "claimed-token",
            tailscaleDNSName: nil,
            tailscaleDeviceName: nil,
            tailcatAddress: nil
        )
        let claimed = try await AppStore.claimPairingWithRetry(
            maxAttempts: 3,
            retryDelaysNanoseconds: [10, 20],
            sleep: { sleepDelays.append($0) },
            operation: {
                attempts += 1
                if attempts == 1 {
                    throw URLError(.cannotConnectToHost)
                }
                return expected
            }
        )
        XCTAssertEqual(claimed, expected)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(sleepDelays, [10])

        var authAttempts = 0
        do {
            _ = try await AppStore.claimPairingWithRetry(
                maxAttempts: 3,
                retryDelaysNanoseconds: [10, 20],
                sleep: { _ in XCTFail("鉴权/过期等业务错误不应重试") },
                operation: { () async throws -> PairingClaimResponse in
                    authAttempts += 1
                    throw PairingLinkError.expired
                }
            )
            XCTFail("应立即抛出 PairingLinkError.expired")
        } catch let error as PairingLinkError {
            XCTAssertEqual(error, .expired)
            XCTAssertEqual(authAttempts, 1)
        }
    }

    func testClaimPairing401TicketErrorsPreserveSavedConnectedProfileAndSurfaceTypedGuidance() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalPairingClaimStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (store, appStore) = makeStores(routeProbe: { _, _, _ in }, agentAPISession: session)
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.30:8787",
            token: "existing-token"
        ))
        appStore.markLiveConnectionEstablished()
        let savedProfileID = try XCTUnwrap(appStore.activeConnectionProfileID)
        XCTAssertTrue(appStore.connectionStatus.isConnected)

        let liveTicketURL = try XCTUnwrap(URL(
            string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.99%3A8787"
                + "&issued_at=2026-07-23T10%3A00%3A00Z&expires_at=4102444800&pair_sig=test-sig"
        ))

        // v1 HTTP 401 pair_ticket_expired must NOT delete profile, invalidate credentials, or drop connected status.
        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 401,
            contentType: "application/vnd.mimi.onboarding.v1+json",
            vary: "Accept",
            body: #"{"ok":false,"error":{"code":"pair_ticket_expired","step":"network_any","message":"expired","fix":{"kind":"retry"}}}"#
        )
        await store.openPairingLink(liveTicketURL)

        XCTAssertEqual(appStore.connectionProfiles.map(\.id), [savedProfileID])
        XCTAssertEqual(appStore.activeConnectionProfileID, savedProfileID)
        XCTAssertEqual(appStore.token, "existing-token")
        XCTAssertTrue(appStore.isConfigured)
        XCTAssertTrue(appStore.connectionStatus.isConnected)
        XCTAssertNil(appStore.connectionTermination)
        XCTAssertFalse(appStore.requiresRePairing)
        XCTAssertEqual(store.lastPairingOnboardingError?.code, "pair_ticket_expired")
        let expiredError = try XCTUnwrap(appStore.lastError)
        XCTAssertEqual(expiredError, L10n.text("ui.pairing_onboarding_pair_ticket_expired"))
        XCTAssertEqual(
            ConnectionFailureGuidance.friendlyMessage(from: expiredError, route: store.lastPairingLinkRoute),
            expiredError
        )
        XCTAssertFalse(expiredError.contains("{"))
        XCTAssertFalse(expiredError.contains("10 分钟"))

        // v1 HTTP 401 pair_clock_skew preserves saved profile and gives text Date & Time guidance (no App-Prefs:).
        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 401,
            contentType: "application/vnd.mimi.onboarding.v1+json",
            vary: "Accept",
            body: #"{"ok":false,"error":{"code":"pair_clock_skew","step":"network_any","message":"skew","fix":{"kind":"open_settings","target":"date_time"}}}"#
        )
        await store.openPairingLink(liveTicketURL)

        XCTAssertEqual(appStore.connectionProfiles.map(\.id), [savedProfileID])
        XCTAssertTrue(appStore.connectionStatus.isConnected)
        XCTAssertNil(appStore.connectionTermination)
        XCTAssertEqual(store.lastPairingOnboardingError?.code, "pair_clock_skew")
        let clockError = try XCTUnwrap(appStore.lastError)
        XCTAssertEqual(clockError, PairingErrorMapper.dateTimeInstructions)
        XCTAssertFalse(clockError.contains("App-Prefs:"))
        XCTAssertEqual(
            ConnectionFailureGuidance.friendlyMessage(from: clockError, route: store.lastPairingLinkRoute),
            clockError
        )

        // Legacy host 401 on /api/pair/claim still preserves saved profile and avoids credentialsInvalid.
        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 401,
            contentType: "application/json",
            vary: nil,
            body: #"{"error":"配对二维码已过期"}"#
        )
        await store.openPairingLink(liveTicketURL)

        XCTAssertEqual(appStore.connectionProfiles.map(\.id), [savedProfileID])
        XCTAssertTrue(appStore.connectionStatus.isConnected)
        XCTAssertNil(appStore.connectionTermination)
        XCTAssertEqual(store.lastPairingOnboardingError?.isLegacyFallback, true)
        XCTAssertEqual(appStore.lastError, L10n.text("ui.pairing_onboarding_pair_ticket_expired"))
    }

    func testLocalAutoPairingSurfacesLegacyLoopbackDenial() async throws {
        let suite = "ExternalPairingLinkTests.LocalClaim." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalPairingClaimStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 403, contentType: "application/json", vary: nil,
            body: #"{"error":"本机自动配对仅允许 Mimi Mac 客户端通过 loopback 发起"}"#
        )
        let store = AppStore(
            defaults: defaults, tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: true, localAgentProbe: { _, _ in },
            localAgentPairingClaim: { endpoint, timeout in
                try await AgentAPIClient(endpoint: endpoint, token: "", session: session)
                    .claimLocalPairing(timeout: timeout).token
            }
        )
        let connected = await store.preflightConnection()
        XCTAssertFalse(connected)
        XCTAssertEqual(store.connectionStatus, .failed(L10n.text("ui.pairing_onboarding_pair_local_forbidden")))
        XCTAssertTrue(store.connectionProfiles.isEmpty)
    }

    func testFirstConnectionDeepLinkPropagates409And503TypedOnboardingErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalPairingClaimStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (store, _) = makeStores(routeProbe: { _, _, _ in }, agentAPISession: session)
        let liveTicketURL = try XCTUnwrap(URL(
            string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.99%3A8787"
                + "&issued_at=2026-07-23T10%3A00%3A00Z&expires_at=4102444800&pair_sig=test-sig"
        ))

        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 409,
            contentType: "application/vnd.mimi.onboarding.v1+json",
            vary: "Accept",
            body: #"{"ok":false,"error":{"code":"workspace_confirmation_required","step":"workspace_root","message":"confirm","fix":{"kind":"choose_path","target":"workspace_root"}}}"#
        )
        await store.openPairingLink(liveTicketURL)
        XCTAssertEqual(store.lastPairingOnboardingError?.code, "workspace_confirmation_required")
        XCTAssertEqual(store.pairingLinkAttempt, .failed(L10n.text("ui.pairing_onboarding_desktop_workspace_guidance")))

        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 503,
            contentType: "application/vnd.mimi.onboarding.v1+json",
            vary: "Accept",
            body: #"{"ok":false,"error":{"code":"no_enabled_assistant","step":"assistant_any","message":"none","fix":{"kind":"open_url","url":"https://github.com/gaixianggeng/mimi-remote/blob/main/docs/quickstart.md"}}}"#
        )
        await store.openPairingLink(liveTicketURL)
        XCTAssertEqual(store.lastPairingOnboardingError?.code, "no_enabled_assistant")
        XCTAssertEqual(store.lastPairingOnboardingError?.action, .openURL(.guide))
        XCTAssertEqual(store.pairingLinkAttempt, .failed(L10n.text("ui.pairing_onboarding_no_enabled_assistant")))
    }

    private func makeStores(
        routeProbe: @escaping ConnectionRouteProbe,
        agentAPISession: URLSession = .shared
    ) -> (SessionStore, AppStore) {
        let suiteName = "ExternalPairingLinkTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建隔离测试 UserDefaults suite: \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: routeProbe,
            agentAPISession: agentAPISession
        )
        let client = MockSessionStoreClient(projects: [], sessions: [], messagesResult: [])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )
        return (store, appStore)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                return XCTFail("等待条件超时")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// 让路由探测停住直到测试放行；放行为失败后，后续候选地址的探测也立即失败，避免挂住。
@MainActor
private final class RouteProbeGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private(set) var isWaiting = false

    func wait() async throws {
        if let failure {
            throw failure
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func fail(_ error: Error) {
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private final class ExternalPairingClaimStubURLProtocol: URLProtocol {
    private struct StubResponse {
        let statusCode: Int
        let contentType: String
        let vary: String?
        let body: String
    }

    private static let lock = NSLock()
    private static var response = StubResponse(statusCode: 500, contentType: "application/json", vary: nil, body: "{}")

    static func configure(statusCode: Int, contentType: String, vary: String?, body: String) {
        lock.withLock {
            response = StubResponse(statusCode: statusCode, contentType: contentType, vary: vary, body: body)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.lock.withLock { Self.response }
        var headers = ["Content-Type": stub.contentType]
        if let vary = stub.vary {
            headers["Vary"] = vary
        }
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
