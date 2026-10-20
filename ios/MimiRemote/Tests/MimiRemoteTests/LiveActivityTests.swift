import XCTest
@testable import MimiRemote

/// content-state 必须能解码推送服务生成的 APNs `content-state`（#830）。
final class MimiTurnActivityStateTests: XCTestCase {
    func testDecodesProviderContentState() throws {
        // 与 internal/pushprovider 的 liveActivityContentStatePayload 同形：startedAt 是 Unix 秒整数。
        let json = #"{"status":"needsYou","runningCount":2,"needsYouCount":1,"startedAt":1700000000,"focusSessionTag":"9E61BAD1E6C4DDAF"}"#
        let state = try JSONDecoder().decode(MimiTurnActivityState.self, from: Data(json.utf8))
        XCTAssertEqual(state.status, .needsYou)
        XCTAssertEqual(state.runningCount, 2)
        XCTAssertEqual(state.needsYouCount, 1)
        XCTAssertEqual(state.startDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(state.focusSessionTag, "9E61BAD1E6C4DDAF")
        XCTAssertTrue(state.isMultiSession)
    }

    func testEncodesTheKeysTheSystemDecodes() throws {
        let state = MimiTurnActivityState(
            status: .running, runningCount: 1, needsYouCount: 0, startedAt: 42, focusSessionTag: "ABCD"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["status", "runningCount", "needsYouCount", "startedAt", "focusSessionTag"])
        XCTAssertEqual(object["status"] as? String, "running")
        XCTAssertEqual(object["startedAt"] as? Int, 42)
        XCTAssertEqual(try JSONDecoder().decode(MimiTurnActivityState.self, from: JSONEncoder().encode(state)), state)
    }

    func testEveryProviderStatusDecodes() throws {
        for (raw, expected) in [
            ("running", MimiTurnActivityStatus.running),
            ("needsYou", .needsYou),
            ("completed", .completed),
            ("failed", .failed),
        ] {
            let json = #"{"status":"\#(raw)","runningCount":0,"needsYouCount":0,"startedAt":1,"focusSessionTag":"A"}"#
            XCTAssertEqual(try JSONDecoder().decode(MimiTurnActivityState.self, from: Data(json.utf8)).status, expected)
        }
    }

    /// 解码失败会让系统丢掉整条更新；未知状态按运行中显示。
    func testUnknownStatusFallsBackToRunning() throws {
        let json = #"{"status":"paused","runningCount":1,"needsYouCount":0,"startedAt":1,"focusSessionTag":"A"}"#
        XCTAssertEqual(try JSONDecoder().decode(MimiTurnActivityState.self, from: Data(json.utf8)).status, .running)
    }

    /// 与 agentd 的 HostTag / 消息 session_tag 算法一致（internal/pushbridge/tags.go）。
    func testTagsMatchAgentd() {
        XCTAssertEqual(NotificationSessionTag.hostTag(installationID: "install-test"), "6AF3")
        XCTAssertEqual(NotificationSessionTag.hostTag(installationID: " install-test\n"), "6AF3")
        XCTAssertEqual(NotificationSessionTag.messageTag(threadID: "thread-1"), "9E61BAD1E6C4DDAF")
    }
}

/// 标题只从本机缓存补全；查不到或有歧义时退回通用文案。
final class MimiTurnActivityPresentationTests: XCTestCase {
    private let localize: MimiTurnActivityPresentation.Localize = { key in
        [
            "live_activity.title.generic": "GENERIC",
            "live_activity.status.running": "RUNNING",
            "live_activity.status.needs_you": "NEEDS_YOU",
            "live_activity.status.completed": "COMPLETED",
            "live_activity.status.failed": "FAILED",
            "live_activity.summary_value": "%1$@ running / %2$@ waiting",
        ][key] ?? key
    }

    private func entry(_ title: String, project: String = "repo", host: String = "Studio") -> NotificationTitleCache.Entry {
        NotificationTitleCache.Entry(title: title, project: project, runtime: "claude", hostName: host, updatedAt: Date())
    }

    private func state(
        _ status: MimiTurnActivityStatus = .running,
        running: Int = 1,
        needsYou: Int = 0,
        tag: String = "9E61BAD1E6C4DDAF"
    ) -> MimiTurnActivityState {
        MimiTurnActivityState(
            status: status, runningCount: running, needsYouCount: needsYou, startedAt: 1_700_000_000, focusSessionTag: tag
        )
    }

    func testTitleLookup() {
        let profileA = "8fce1e1296c1575c"
        let profileB = "0123456789abcdef"
        let cases: [(name: String, cache: NotificationTitleCache, title: String, hasTitle: Bool, subtitle: String?)] = [
            ("cache hit", NotificationTitleCache(profileCount: 1, entries: [
                NotificationSessionTag.cacheKey(profileTag: profileA, sessionTag: "9E61BAD1E6C4DDAF"): entry("Fix login"),
            ]), "Fix login", true, "repo"),
            ("cache miss", NotificationTitleCache(profileCount: 1, entries: [
                NotificationSessionTag.cacheKey(profileTag: profileA, sessionTag: "6F84B51598A477A0"): entry("Other"),
            ]), "GENERIC", false, nil),
            ("empty cache", .empty, "GENERIC", false, nil),
            ("ambiguous across profiles", NotificationTitleCache(profileCount: 2, entries: [
                NotificationSessionTag.cacheKey(profileTag: profileA, sessionTag: "9E61BAD1E6C4DDAF"): entry("One"),
                NotificationSessionTag.cacheKey(profileTag: profileB, sessionTag: "9E61BAD1E6C4DDAF"): entry("Two"),
            ]), "GENERIC", false, nil),
            ("host name only with several profiles", NotificationTitleCache(profileCount: 2, entries: [
                NotificationSessionTag.cacheKey(profileTag: profileA, sessionTag: "9E61BAD1E6C4DDAF"): entry("Fix login"),
            ]), "Fix login", true, "repo · Studio"),
        ]
        for testCase in cases {
            let presentation = MimiTurnActivityPresentation.make(
                hostTag: "6AF3", state: state(), cache: testCase.cache, localize: localize
            )
            XCTAssertEqual(presentation.title, testCase.title, testCase.name)
            XCTAssertEqual(presentation.hasSessionTitle, testCase.hasTitle, testCase.name)
            XCTAssertEqual(presentation.subtitle, testCase.subtitle, testCase.name)
        }
    }

    /// 4 位审批标签或格式错误的标签不能凭前缀命中某条会话。
    func testShortOrMalformedTagsNeverMatch() {
        let cache = NotificationTitleCache(profileCount: 1, entries: [
            NotificationSessionTag.cacheKey(profileTag: "8fce1e1296c1575c", sessionTag: "9E61BAD1E6C4DDAF"): entry("Fix login"),
        ])
        for tag in ["9E61", "", "9e61bad1e6c4ddaf0", "6AF3"] {
            XCTAssertNil(cache.entry(liveActivitySessionTag: tag), tag)
        }
        XCTAssertEqual(cache.entry(liveActivitySessionTag: "9e61bad1e6c4ddaf")?.title, "Fix login")
    }

    func testStatusAndSummary() {
        let cases: [(MimiTurnActivityState, String, String?, Bool)] = [
            (state(.running), "RUNNING", nil, true),
            (state(.needsYou, running: 0, needsYou: 1), "NEEDS_YOU", nil, true),
            (state(.needsYou, running: 2, needsYou: 1), "NEEDS_YOU", "2 running / 1 waiting", true),
            (state(.running, running: 3), "RUNNING", "3 running / 0 waiting", true),
            (state(.completed, running: 0), "COMPLETED", nil, false),
            (state(.failed, running: 0), "FAILED", nil, false),
            (state(.running, running: 150, needsYou: 120), "RUNNING", "99 running / 99 waiting", true),
        ]
        for (index, testCase) in cases.enumerated() {
            let presentation = MimiTurnActivityPresentation.make(
                hostTag: "6AF3", state: testCase.0, cache: .empty, localize: localize
            )
            XCTAssertEqual(presentation.statusText, testCase.1, "case \(index)")
            XCTAssertEqual(presentation.summaryText, testCase.2, "case \(index)")
            XCTAssertEqual(presentation.showsTimer, testCase.3, "case \(index)")
        }
    }

    func testDeepLinkRoundTrip() throws {
        let presentation = MimiTurnActivityPresentation.make(
            hostTag: "6af3", state: state(), cache: .empty, localize: localize
        )
        let url = try XCTUnwrap(presentation.deepLink)
        XCTAssertEqual(url.absoluteString, "mimi://live-activity?host=6AF3&session=9E61BAD1E6C4DDAF")
        XCTAssertEqual(MimiTurnActivityLink(url: url), MimiTurnActivityLink(hostTag: "6AF3", sessionTag: "9E61BAD1E6C4DDAF"))
    }

    func testRejectsForeignOrMalformedLinks() {
        for raw in [
            "mimi://pair?host=6AF3&session=9E61BAD1E6C4DDAF",
            "https://live-activity?host=6AF3&session=9E61BAD1E6C4DDAF",
            "mimi://live-activity?host=6AF3",
            "mimi://live-activity?host=../x&session=9E61BAD1E6C4DDAF",
            "mimi://live-activity?host=6AF3&session=title%20text",
        ] {
            XCTAssertNil(URL(string: raw).flatMap(MimiTurnActivityLink.init(url:)), raw)
        }
    }
}

/// 开关默认开启、跟随消息通知总开关；票据只在 Token 与绑定都没变时复用。
final class LiveActivityPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LiveActivityPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testToggleDefaultsOnAndFollowsMessageNotifications() {
        let cases: [(toggle: Bool?, notifications: Bool?, toggleOn: Bool, effective: Bool)] = [
            (nil, nil, true, true),
            (nil, false, true, false),
            (false, true, false, false),
            (true, false, true, false),
            (true, true, true, true),
        ]
        for (index, testCase) in cases.enumerated() {
            defaults.removeObject(forKey: LiveActivityPreferences.key)
            defaults.removeObject(forKey: MessageNotificationPreferences.key)
            defaults.removeObject(forKey: MessageNotificationPreferences.legacyKey)
            if let toggle = testCase.toggle { LiveActivityPreferences.setToggle(toggle, in: defaults) }
            if let notifications = testCase.notifications {
                defaults.set(notifications, forKey: MessageNotificationPreferences.key)
            }
            XCTAssertEqual(LiveActivityPreferences.isToggleOn(in: defaults), testCase.toggleOn, "case \(index)")
            XCTAssertEqual(LiveActivityPreferences.isEffective(in: defaults), testCase.effective, "case \(index)")
        }
    }

    func testSettingsCopy() {
        typealias Availability = LiveActivityCoordinator.Availability
        let cases: [(Bool, Availability, String)] = [
            (false, .ready, "ui.live_activity_requires_notifications"),
            (true, .off, "ui.live_activity_status_off"),
            (true, .requiresNotifications, "ui.live_activity_requires_notifications"),
            (true, .systemDisabled, "ui.live_activity_system_disabled"),
            (true, .unavailableOnHost, "ui.live_activity_unavailable_on_host"),
            (true, .failed, "ui.live_activity_status_failed"),
            (true, .pending, "ui.live_activity_status_on"),
            (true, .ready, "ui.live_activity_status_on"),
        ]
        for testCase in cases {
            let key = LiveActivitySettingsCopy.statusKey(notificationsEnabled: testCase.0, availability: testCase.1)
            XCTAssertEqual(key, testCase.2)
            XCTAssertNotEqual(L10n.text(key), key, "缺少文案 \(key)")
        }
    }

    func testTicketRecordReuseRules() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var record = LiveActivityTicketRecord(profileID: "mac", providerURL: "https://p", hostTag: "6AF3")
        XCTAssertFalse(record.startIsCurrent(tokenFingerprint: "fp", now: now))
        record.start = .init(ticket: "s", expiresAt: now.addingTimeInterval(8 * 86_400), tokenFingerprint: "fp")
        XCTAssertTrue(record.startIsCurrent(tokenFingerprint: "fp", now: now))
        XCTAssertFalse(record.startIsCurrent(tokenFingerprint: "new", now: now), "Token 变化必须重新登记")
        XCTAssertFalse(record.startIsCurrent(tokenFingerprint: "fp", now: now.addingTimeInterval(2 * 86_400)), "不足一周要续期")

        record.updates["A"] = .init(ticket: "u1", expiresAt: now.addingTimeInterval(2 * 3600), tokenFingerprint: "fa")
        record.updates["B"] = .init(ticket: "u2", expiresAt: now.addingTimeInterval(-1), tokenFingerprint: "fb")
        XCTAssertTrue(record.updateIsCurrent(activityID: "A", tokenFingerprint: "fa", now: now))
        XCTAssertFalse(record.updateIsCurrent(activityID: "A", tokenFingerprint: "fa", now: now.addingTimeInterval(1.5 * 3600)))
        record.pruneExpiredUpdates(now: now)
        XCTAssertEqual(Set(record.updates.keys), ["A"])
        XCTAssertEqual(record.allTickets, ["s", "u1"])

        XCTAssertTrue(record.matches(profileID: "mac", providerURL: "https://p", hostTag: "6AF3"))
        XCTAssertFalse(record.matches(profileID: "other", providerURL: "https://p", hostTag: "6AF3"), "换绑后旧票据作废")
        XCTAssertFalse(record.matches(profileID: "mac", providerURL: "https://q", hostTag: "6AF3"), "换推送服务后旧票据作废")
    }

    func testTicketStoreRoundTripsThroughKeychain() {
        let store = LiveActivityTicketStore(keychain: TestKeychainOperations())
        XCTAssertNil(store.load())
        var record = LiveActivityTicketRecord(profileID: "mac", providerURL: "https://p", hostTag: "6AF3")
        record.start = .init(ticket: "s", expiresAt: Date(timeIntervalSince1970: 1_900_000_000), tokenFingerprint: "fp")
        store.save(record)
        XCTAssertEqual(store.load(), record)
        record.updates["A"] = .init(ticket: "u", expiresAt: Date(timeIntervalSince1970: 1_900_000_000), tokenFingerprint: "fa")
        store.save(record)
        XCTAssertEqual(store.load(), record)
        store.delete()
        XCTAssertNil(store.load())
    }
}

/// 点按 Live Activity 只在当前档案就是那台 Mac 时映射到会话；前台本机拉起的初始状态。
final class LiveActivityRoutingTests: XCTestCase {
    private func profile(_ id: String, installationID: String?) -> ConnectionProfile {
        ConnectionProfile(
            id: id,
            displayName: id,
            endpoint: "http://127.0.0.1:8787",
            lastSuccessfulAt: nil,
            installationID: installationID,
            connectionRoute: .lan
        )
    }

    func testLinkRouting() {
        let sessions = [
            makeSession(id: "thread-1", projectID: "repo", title: "Fix", status: "running", source: "codex", runtimeProvider: "claude"),
            makeSession(id: "local-2", projectID: "repo", title: "Resumed", status: "idle", source: "codex", resumeID: "thread-2"),
        ]
        let profiles = [profile("mac-a", installationID: "install-test"), profile("mac-b", installationID: "install-b")]
        let link = MimiTurnActivityLink(hostTag: "6AF3", sessionTag: "9E61BAD1E6C4DDAF")

        let route = LiveActivityLinkRouting.route(for: link, profiles: profiles, activeProfileID: "mac-a", sessions: sessions)
        XCTAssertEqual(route?.profileID, "mac-a")
        XCTAssertEqual(route?.sessionID, "thread-1")
        XCTAssertEqual(route?.projectID, "repo")
        XCTAssertEqual(route?.runtimeProvider, "claude")

        let resumed = LiveActivityLinkRouting.route(
            for: MimiTurnActivityLink(hostTag: "6AF3", sessionTag: "6F84B51598A477A0"),
            profiles: profiles, activeProfileID: "mac-a", sessions: sessions
        )
        XCTAssertEqual(resumed?.sessionID, "local-2", "resumeID 对应的标签也要能找回会话")

        XCTAssertNil(
            LiveActivityLinkRouting.route(for: link, profiles: profiles, activeProfileID: "mac-b", sessions: sessions),
            "另一台 Mac 的活动不能映射到当前 Mac 的会话"
        )
        XCTAssertNil(
            LiveActivityLinkRouting.route(
                for: MimiTurnActivityLink(hostTag: "6AF3", sessionTag: "0000000000000000"),
                profiles: profiles, activeProfileID: "mac-a", sessions: sessions
            ),
            "找不到会话时只打开 App"
        )
        XCTAssertNil(LiveActivityLinkRouting.route(for: link, profiles: profiles, activeProfileID: nil, sessions: sessions))
    }

    func testLocalStateSeedsFromSessions() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(LiveActivityLocalState.make(sessions: [
            makeSession(id: "idle", projectID: "repo", title: "Done", status: "idle", source: "codex"),
        ], now: now))

        let running = try XCTUnwrap(LiveActivityLocalState.make(sessions: [
            makeSession(id: "old", projectID: "repo", title: "A", status: "running", source: "codex",
                        updatedAt: Date(timeIntervalSince1970: 10)),
            makeSession(id: "thread-1", projectID: "repo", title: "B", status: "running", source: "codex",
                        updatedAt: Date(timeIntervalSince1970: 20)),
            makeSession(id: "idle", projectID: "repo", title: "C", status: "idle", source: "codex"),
        ], now: now))
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(running.runningCount, 2)
        XCTAssertEqual(running.needsYouCount, 0)
        XCTAssertEqual(running.focusSessionTag, NotificationSessionTag.messageTag(threadID: "thread-1"))
        XCTAssertEqual(running.startedAt, 1_800_000_000)

        let waiting = try XCTUnwrap(LiveActivityLocalState.make(sessions: [
            makeSession(id: "thread-1", projectID: "repo", title: "B", status: "running", source: "codex",
                        updatedAt: Date(timeIntervalSince1970: 30)),
            makeSession(id: "thread-2", projectID: "repo", title: "A", status: "waiting_for_approval", source: "codex",
                        updatedAt: Date(timeIntervalSince1970: 10)),
        ], now: now))
        XCTAssertEqual(waiting.status, .needsYou)
        XCTAssertEqual(waiting.runningCount, 1)
        XCTAssertEqual(waiting.needsYouCount, 1)
        XCTAssertEqual(waiting.focusSessionTag, NotificationSessionTag.messageTag(threadID: "thread-2"), "待你处理优先成为焦点")
    }
}

/// 新字段不能破坏旧服务：通知 Ticket 请求不带 kind（旧推送服务拒绝未知字段），
/// 旧版 agentd 的状态响应缺少活动字段时照常解码。
final class LiveActivityCompatibilityTests: XCTestCase {
    override func tearDown() {
        TicketRecordingURLProtocol.reset()
        super.tearDown()
    }

    func testTicketRequestCarriesKindOnlyForLiveActivityTokens() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TicketRecordingURLProtocol.self]
        let client = PushProviderClient(baseURL: "https://push.example/mimi-push", session: URLSession(configuration: configuration))
        let cases: [(PushProviderClient.TicketKind, String?)] = [
            (.notification, nil),
            (.activityStart, "activity_start"),
            (.activityUpdate, "activity_update"),
        ]
        for (kind, expected) in cases {
            let ticket = try await client.issueTicket(
                deviceToken: "ab12", installation: "ins-1", environment: .sandbox, kind: kind
            )
            XCTAssertEqual(ticket.value, "mpt1.1.ticket")
            let body = try XCTUnwrap(TicketRecordingURLProtocol.lastBody())
            XCTAssertEqual(body["kind"] as? String, expected, "\(kind)")
            XCTAssertEqual(body.keys.contains("kind"), expected != nil, "通知 Ticket 请求不能出现 kind 键")
            XCTAssertEqual(body["device_token"] as? String, "ab12")
        }
    }

    func testPushStatusDecodesWithAndWithoutLiveActivityFields() throws {
        let old = #"{"enabled":true,"provider_configured":true,"devices":[{"device_id":"dev-1"}]}"#
        let decodedOld = try JSONDecoder().decode(PushStatusResponse.self, from: Data(old.utf8))
        XCTAssertNil(decodedOld.liveActivity)
        XCTAssertNil(decodedOld.hostTag)
        XCTAssertNil(decodedOld.devices?.first?.liveActivityStart)

        let new = #"{"enabled":true,"provider_configured":true,"live_activity":true,"host_tag":"6AF3","devices":[{"device_id":"dev-1","live_activity_start":true,"live_activity_update":false}]}"#
        let decodedNew = try JSONDecoder().decode(PushStatusResponse.self, from: Data(new.utf8))
        XCTAssertEqual(decodedNew.liveActivity, true)
        XCTAssertEqual(decodedNew.hostTag, "6AF3")
        XCTAssertEqual(decodedNew.devices?.first?.liveActivityStart, true)
        XCTAssertEqual(decodedNew.devices?.first?.liveActivityUpdate, false)
    }
}

private final class TicketRecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var bodies: [Data] = []

    static func reset() {
        lock.withLock { bodies.removeAll() }
    }

    static func lastBody() -> [String: Any]? {
        let data = lock.withLock { bodies.last }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        Self.lock.withLock { Self.bodies.append(data) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ticket":"mpt1.1.ticket","expires_at":"2030-01-01T00:00:00Z"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
