import XCTest
import Security
import UserNotifications
@testable import MimiRemote

@MainActor
final class MessageNotificationTests: XCTestCase {
    func testPreferenceMigrationKeepsExplicitChoicesAndRunsOnce() throws {
        for legacy in [nil, true, false] as [Bool?] {
            let suite = "MessageNotificationTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if let legacy { defaults.set(legacy, forKey: MessageNotificationPreferences.legacyKey) }
            XCTAssertEqual(MessageNotificationPreferences.migrate(in: defaults), legacy ?? true)
            defaults.set(false, forKey: MessageNotificationPreferences.key)
            defaults.set(true, forKey: MessageNotificationPreferences.legacyKey)
            XCTAssertFalse(MessageNotificationPreferences.migrate(in: defaults))
        }
    }

    func testOfficialServiceRegistersAutomaticallyAndRepeatedSyncDoesNotRegisterAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.store.notificationsEnabled)
        XCTAssertFalse(fixture.store.isEnabled)
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertTrue(fixture.store.hasConsented(for: "computer-a"))
        XCTAssertNil(fixture.defaults.string(forKey: "lockScreenApproval.consentedProviderURL"))
        XCTAssertTrue(fixture.store.isEnabled)
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertEqual(NotificationFlowURLProtocol.count("POST /mimi-push/v1/ticket"), 1)
        XCTAssertEqual(NotificationFlowURLProtocol.count("POST /api/push/devices"), 1)
    }

    func testColdStartTokenChangeRegistersAfterHostSupportLoads() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")

        let restarted = LockScreenApprovalStore(
            defaults: fixture.defaults, ticketStore: fixture.tickets,
            identityStore: PushInstallationIdentityStore(keychain: fixture.keychain),
            clearNotificationTitleCache: {},
            providerClientFactory: { PushProviderClient(baseURL: $0, session: fixture.session) },
            requestAuthorization: { true }
        )
        XCTAssertTrue(restarted.handleDeviceToken(Data([0x56, 0x78])))
        await restarted.refreshRegistrationAfterDeviceTokenChange(
            client: fixture.client, profileID: "computer-a"
        )
        XCTAssertEqual(NotificationFlowURLProtocol.count("POST /api/push/devices"), 1)

        await restarted.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertEqual(NotificationFlowURLProtocol.count("POST /api/push/devices"), 2)
    }

    func testDeniedPermissionKeepsPreferenceAndResumesWhenAllowed() async throws {
        var granted = false
        let fixture = try Fixture(requestAuthorization: { granted })
        defer { fixture.close() }
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertEqual(fixture.store.status, .notificationsDenied)
        XCTAssertTrue(fixture.store.notificationsEnabled)
        XCTAssertEqual(NotificationFlowURLProtocol.count("POST /mimi-push/v1/ticket"), 0)
        granted = true
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertTrue(fixture.store.isEnabled)
    }

    func testCloseWhilePermissionIsPendingCannotRegisterAfterAuthorizationReturns() async throws {
        let started = expectation(description: "authorization started")
        var resume: CheckedContinuation<Bool, Never>?
        let fixture = try Fixture(requestAuthorization: {
            await withCheckedContinuation { continuation in
                resume = continuation
                started.fulfill()
            }
        })
        defer { fixture.close() }
        let registration = Task { await fixture.store.synchronize(client: fixture.client, profileID: "computer-a") }
        await fulfillment(of: [started], timeout: 2)
        fixture.store.setNotificationsEnabled(false)
        let shutdown = Task { await fixture.store.disable(client: fixture.client, profileID: "computer-a") }
        resume?.resume(returning: true)
        await registration.value
        await shutdown.value
        XCTAssertFalse(fixture.store.notificationsEnabled)
        XCTAssertEqual(fixture.store.status, .off)
        XCTAssertEqual(NotificationFlowURLProtocol.count("POST /api/push/devices"), 0)
    }

    func testFailedRevocationKeepsRetryBindingAndReopeningRebuildsRegistration() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        NotificationFlowURLProtocol.fail("POST /mimi-push/v1/ticket/revoke")
        await fixture.store.disable(client: fixture.client, profileID: "computer-a")
        XCTAssertFalse(fixture.store.notificationsEnabled)
        XCTAssertTrue(fixture.store.hasPendingDisable)
        XCTAssertNotNil(fixture.tickets.load())
        XCTAssertEqual(fixture.store.notificationStatusDescription, L10n.text("ui.push_disable_incomplete"))
        NotificationFlowURLProtocol.clearFailures()
        fixture.store.setNotificationsEnabled(true)
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertEqual(NotificationFlowURLProtocol.count("POST /api/push/devices"), 2)
        XCTAssertTrue(fixture.store.isEnabled)
    }

    func testUncertainFirstRegistrationRetainsCredentialUntilShutdownSucceeds() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        NotificationFlowURLProtocol.fail("POST /api/push/devices")
        NotificationFlowURLProtocol.fail("DELETE /api/push/devices")
        NotificationFlowURLProtocol.fail("POST /mimi-push/v1/ticket/revoke")
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        await fixture.store.disable(client: fixture.client, profileID: "computer-a")
        XCTAssertTrue(fixture.store.hasPendingDisable)
        XCTAssertNotNil(fixture.tickets.load())
        XCTAssertEqual(fixture.store.registeredProfileID, "computer-a")
        NotificationFlowURLProtocol.clearFailures()
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertEqual(fixture.store.status, .off)
        XCTAssertNil(fixture.tickets.load())
        XCTAssertNil(fixture.store.registeredProfileID)
        XCTAssertFalse(fixture.store.notificationsEnabled)
    }

    func testLockedKeychainDoesNotReportSuccessfulRemoteShutdown() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        fixture.keychain.forcedCopyStatus = errSecInteractionNotAllowed
        await fixture.store.disable(client: fixture.client, profileID: "computer-a")
        XCTAssertTrue(fixture.store.hasPendingDisable)
        XCTAssertEqual(NotificationFlowURLProtocol.count("DELETE /api/push/devices"), 0)
        fixture.keychain.forcedCopyStatus = nil
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertFalse(fixture.store.hasPendingDisable)
        XCTAssertEqual(fixture.store.status, .off)
    }

    func testProviderOnlyShutdownFailureAlsoForcesRegistrationWhenReenabled() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        NotificationFlowURLProtocol.fail("POST /mimi-push/v1/ticket/revoke")
        await fixture.store.disable(client: nil, profileID: "computer-a", previousHostUnavailable: true)
        XCTAssertTrue(fixture.store.hasPendingDisable)
        NotificationFlowURLProtocol.clearFailures()
        fixture.store.setNotificationsEnabled(true)
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertEqual(NotificationFlowURLProtocol.count("POST /api/push/devices"), 2)
    }

    func testAutomaticSyncDoesNotMoveExistingComputerBinding() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        let previousCount = NotificationFlowURLProtocol.requests.count
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-b")
        XCTAssertEqual(fixture.store.registeredProfileID, "computer-a")
        XCTAssertEqual(NotificationFlowURLProtocol.requests.count, previousCount)
    }

    func testCustomServiceNeedsExactAddressConsent() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        NotificationFlowURLProtocol.setProvider("https://custom.example/mimi-push")
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertFalse(fixture.store.hasConsented(for: "computer-a"))
        XCTAssertEqual(NotificationFlowURLProtocol.count("POST /api/push/devices"), 0)
        fixture.store.recordConsent(for: "computer-a")
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertTrue(fixture.store.isEnabled)
        NotificationFlowURLProtocol.setProvider("https://custom.example/another-path")
        await fixture.store.synchronize(client: fixture.client, profileID: "computer-a")
        XCTAssertFalse(fixture.store.hasConsented(for: "computer-a"))
        XCTAssertEqual(NotificationFlowURLProtocol.count("POST /api/push/devices"), 1)
    }

    func testBackgroundAuthorizationCheckNeverRequestsPermission() async throws {
        let probe = NotificationPermissionProbe(status: .notDetermined)
        let controller = NotificationAuthorizationController(
            readStatus: { await probe.status }, request: { await probe.request() }
        )
        let allowed = try await controller.authorize(requestIfNeeded: false)
        let calls = await probe.calls
        XCTAssertFalse(allowed)
        XCTAssertEqual(calls, 0)
    }

    func testRuntimeNotificationsHonorSwitchButManualRemindersRemainIndependent() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.store.setNotificationsEnabled(false)
        let probe = NotificationPermissionProbe(status: .denied)
        let authorization = NotificationAuthorizationController(
            readStatus: { await probe.readStatus() }, request: { await probe.request() }
        )
        let scheduler = UserNotificationSessionReminderScheduler(defaults: fixture.defaults, authorization: authorization)
        let route = SessionNotificationRoute.current(profileID: "computer-a", projectID: "project", sessionID: "task")
        try await scheduler.notify(
            SessionRuntimeNotification(id: "event", sessionID: "task", title: "Task", body: "Done", kind: .completed),
            route: route
        )
        let runtimeReads = await probe.reads
        XCTAssertEqual(runtimeReads, 0, "关闭后连系统权限都不需要查询，更不能安排自动通知")
        let result = try await scheduler.schedule(
            SessionReminder(sessionID: "task", title: "Task", fireAt: Date().addingTimeInterval(60), createdAt: Date()),
            route: route
        )
        let reminderReads = await probe.reads
        XCTAssertEqual(reminderReads, 1, "手动提醒仍走自己的系统授权路径")
        XCTAssertEqual(result, .permissionDenied)
    }

    func testDeniedSystemPermissionIsNotRequestedAgain() async throws {
        let probe = NotificationPermissionProbe(status: .denied)
        let controller = NotificationAuthorizationController(
            readStatus: { await probe.status }, request: { await probe.request() }
        )
        let first = try await controller.authorize(requestIfNeeded: true)
        let second = try await controller.authorize(requestIfNeeded: true)
        let calls = await probe.calls
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(calls, 0)
    }

    func testConcurrentPermissionRequestsShareOneSystemPrompt() async throws {
        let started = expectation(description: "system prompt")
        let probe = NotificationPermissionProbe(status: .notDetermined)
        let controller = NotificationAuthorizationController(
            readStatus: { await probe.status },
            request: {
                await probe.requestWithPause(started: started)
            }
        )
        let first = Task { try await controller.authorize(requestIfNeeded: true) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { try await controller.authorize(requestIfNeeded: true) }
        await Task.yield()
        await probe.finish()
        let a = try await first.value
        let b = try await second.value
        let calls = await probe.calls
        XCTAssertTrue(a && b)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    private struct Fixture {
        let defaults: UserDefaults
        let suite: String
        let store: LockScreenApprovalStore
        let tickets: PushTicketStore
        let client: AgentAPIClient
        let session: URLSession
        let keychain: TestKeychainOperations

        init(requestAuthorization: @escaping () async throws -> Bool = { true }) throws {
            suite = "MessageNotificationTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            NotificationFlowURLProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NotificationFlowURLProtocol.self]
            session = URLSession(configuration: configuration)
            keychain = TestKeychainOperations()
            tickets = PushTicketStore(keychain: keychain)
            let transport = session
            store = LockScreenApprovalStore(
                defaults: defaults, ticketStore: tickets,
                identityStore: PushInstallationIdentityStore(keychain: keychain),
                clearNotificationTitleCache: {},
                providerClientFactory: { PushProviderClient(baseURL: $0, session: transport) },
                requestAuthorization: requestAuthorization
            )
            store.handleDeviceToken(Data([0x12, 0x34]))
            client = AgentAPIClient(endpoint: "https://computer.example", token: "test", session: session)
        }

        func close() {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
            NotificationFlowURLProtocol.reset()
        }
    }
}

private actor NotificationPermissionProbe {
    var status: UNAuthorizationStatus
    var calls = 0
    var reads = 0
    var continuation: CheckedContinuation<Bool, Never>?
    init(status: UNAuthorizationStatus) { self.status = status }
    func readStatus() -> UNAuthorizationStatus { reads += 1; return status }
    func request() -> Bool { calls += 1; return true }
    func requestWithPause(started: XCTestExpectation) async -> Bool {
        calls += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func finish() {
        status = .authorized
        continuation?.resume(returning: true)
        continuation = nil
    }
}

private final class NotificationFlowURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var log: [String] = []
    private static var failures = Set<String>()
    private static var provider = PushProviderClient.defaultBaseURL
    static var requests: [String] { lock.withLock { log } }
    static func count(_ request: String) -> Int { requests.filter { $0 == request }.count }
    static func fail(_ request: String) { _ = lock.withLock { failures.insert(request) } }
    static func clearFailures() { lock.withLock { failures.removeAll() } }
    static func setProvider(_ value: String) { lock.withLock { provider = value } }
    static func reset() {
        lock.withLock { log = []; failures = []; provider = PushProviderClient.defaultBaseURL }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        let (failed, provider) = Self.lock.withLock {
            Self.log.append(key)
            return (Self.failures.contains(key), Self.provider)
        }
        let body: String
        switch key {
        case "GET /api/push/status":
            body = #"{"enabled":true,"provider_configured":true,"provider_url":"\#(provider)"}"#
        case "POST /api/push/devices":
            body = #"{"device_id":"dev","expires_at":"2099-01-01T00:00:00Z","needs_refresh":false}"#
        case "DELETE /api/push/devices":
            body = #"{"removed":true}"#
        case let value where value.hasSuffix("/v1/ticket"):
            body = #"{"ticket":"test-ticket","expires_at":"2099-01-01T00:00:00Z"}"#
        default:
            body = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: failed ? 503 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((failed ? #"{"error":"unavailable"}"# : body).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
