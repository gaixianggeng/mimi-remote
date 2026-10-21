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
            (true, .disablePending, "ui.live_activity_disable_pending"),
            (false, .disablePending, "ui.live_activity_disable_pending"),
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

    /// 撤销队列：失败的部分留着重试；主机已经不在时注销视为完成，过期票据直接丢弃。
    func testRevocationKeepsOnlyRetryableWork() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var record = LiveActivityTicketRecord(profileID: "mac", providerURL: "https://p", hostTag: "6AF3")
        record.start = .init(ticket: "s", expiresAt: now.addingTimeInterval(86_400), tokenFingerprint: "fp")
        record.updates["A"] = .init(ticket: "u", expiresAt: now.addingTimeInterval(3_600), tokenFingerprint: "fa")
        record.updates["B"] = .init(ticket: "old", expiresAt: now.addingTimeInterval(-1), tokenFingerprint: "fb")
        var backlog = LiveActivityRevocationBacklog()
        backlog.append(record)
        backlog.append(record)
        XCTAssertEqual(backlog.tickets.map(\.ticket), ["s", "old", "u"], "同一张票据只排一次")
        backlog.unregisterProfileID = "mac"

        var revoked: [String] = []
        let allOK = await LiveActivityTicketRevocation.run(
            backlog: backlog, now: now, unregister: { _ in }, revoke: { revoked.append($0.ticket) }
        )
        XCTAssertNil(allOK)
        XCTAssertEqual(revoked, ["s", "u"], "过期票据不再撤销")

        let offline = await LiveActivityTicketRevocation.run(
            backlog: backlog, now: now, unregister: { _ in throw URLError(.notConnectedToInternet) }, revoke: { _ in }
        )
        XCTAssertEqual(offline?.unregisterProfileID, "mac", "暂时联系不上才保留注销")
        XCTAssertEqual(offline?.tickets, [], "推送服务撤销照常完成")

        let hostGone = await LiveActivityTicketRevocation.run(
            backlog: backlog, now: now, unregister: { _ in throw LiveActivityRevocationError.hostGone }, revoke: { _ in }
        )
        XCTAssertNil(hostGone, "主机已经不在时注销视为完成，不能永远卡在关闭未完成")

        let providerDown = await LiveActivityTicketRevocation.run(
            backlog: backlog, now: now, unregister: { _ in },
            revoke: { if $0.ticket == "s" { throw PushProviderError.rejected(status: 503) } }
        )
        XCTAssertEqual(providerDown?.tickets.map(\.ticket), ["s"], "只保留没撤销成功的票据")
        XCTAssertNil(providerDown?.unregisterProfileID)
    }

    /// 关闭时一律不留；换绑后只留当前那台 Mac 的活动；还不知道该归哪台时不误删。
    func testHostFilter() {
        XCTAssertFalse(LiveActivityHostFilter.keeps(hostTag: "6AF3", expectedHostTag: "6AF3", isEnabled: false))
        XCTAssertTrue(LiveActivityHostFilter.keeps(hostTag: "6AF3", expectedHostTag: "6af3", isEnabled: true))
        XCTAssertFalse(LiveActivityHostFilter.keeps(hostTag: "1B2C", expectedHostTag: "6AF3", isEnabled: true))
        XCTAssertTrue(LiveActivityHostFilter.keeps(hostTag: "1B2C", expectedHostTag: nil, isEnabled: true))
    }

    func testHostGoneClassification() {
        XCTAssertTrue(LiveActivityTicketRevocation.isHostGone(LiveActivityRevocationError.hostGone))
        for status in [400, 401, 403, 404, 409] {
            XCTAssertTrue(LiveActivityTicketRevocation.isHostGone(AgentAPIError.server(status: status, message: "")), "\(status)")
        }
        for status in [408, 429, 500, 502, 503] {
            XCTAssertFalse(LiveActivityTicketRevocation.isHostGone(AgentAPIError.server(status: status, message: "")), "\(status)")
        }
        XCTAssertFalse(LiveActivityTicketRevocation.isHostGone(URLError(.timedOut)))
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

/// 关闭后撤销没完成时不能卡住：删掉档案或重新开启都要能走出「关闭尚未完成」。
@MainActor
final class LiveActivityCoordinatorRevocationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// 协调器只弱引用锁屏审批 Store（App 里由 StateObject 持有），测试必须自己留住它。
    private var lockScreenStore: LockScreenApprovalStore?

    override func setUp() {
        super.setUp()
        suiteName = "LiveActivityCoordinatorRevocationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        RevocationStubURLProtocol.reset()
    }

    override func tearDown() {
        lockScreenStore = nil
        defaults.removePersistentDomain(forName: suiteName)
        RevocationStubURLProtocol.reset()
        super.tearDown()
    }

    private func boundLockScreenStore(profileID: String) throws -> LockScreenApprovalStore {
        let keychain = TestKeychainOperations()
        let identityStore = PushInstallationIdentityStore(keychain: keychain)
        try identityStore.save(PushInstallationIdentity(deviceID: "dev-test", installationID: "ins-test"))
        defaults.set(true, forKey: "lockScreenApproval.enabled")
        defaults.set(profileID, forKey: "lockScreenApproval.registeredProfileID")
        defaults.set("https://push.example/mimi-push", forKey: "lockScreenApproval.registeredProviderURL")
        return LockScreenApprovalStore(
            defaults: defaults, ticketStore: PushTicketStore(keychain: keychain), identityStore: identityStore
        )
    }

    private func seededTicketStore(profileID: String) -> LiveActivityTicketStore {
        let store = LiveActivityTicketStore(keychain: TestKeychainOperations())
        var record = LiveActivityTicketRecord(
            profileID: profileID, providerURL: "https://push.example/mimi-push", hostTag: "6AF3"
        )
        record.start = .init(ticket: "s", expiresAt: Date().addingTimeInterval(86_400), tokenFingerprint: "fp")
        record.updates["A"] = .init(ticket: "u", expiresAt: Date().addingTimeInterval(3_600), tokenFingerprint: "fa")
        store.save(record)
        return store
    }

    private func makeCoordinator(
        ticketStore: LiveActivityTicketStore,
        lockScreenStore: LockScreenApprovalStore,
        profileExists: @escaping (String) -> Bool
    ) -> LiveActivityCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RevocationStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let coordinator = LiveActivityCoordinator(
            defaults: defaults,
            ticketStore: ticketStore,
            environment: .sandbox,
            providerClientFactory: { PushProviderClient(baseURL: $0, session: session) }
        )
        self.lockScreenStore = lockScreenStore
        coordinator.attach(lockScreenStore: lockScreenStore)
        XCTAssertEqual(lockScreenStore.deviceID, "dev-test")
        // 那台 Mac 离线：agentd 注销只会超时。
        coordinator.makeClient = { _ in throw URLError(.notConnectedToInternet) }
        coordinator.profileExists = profileExists
        coordinator.installationIDForProfile = { _ in "install-test" }
        return coordinator
    }

    /// 复现：Mac 离线时关闭实时活动，再删掉那台 Mac 的档案，之后必须能重新开启。
    func testDeletedProfileDoesNotLeaveDisablePendingForever() async throws {
        let tickets = seededTicketStore(profileID: "mac-a")
        var profiles: Set<String> = ["mac-a"]
        let coordinator = makeCoordinator(
            ticketStore: tickets,
            lockScreenStore: try boundLockScreenStore(profileID: "mac-a"),
            profileExists: { profiles.contains($0) }
        )
        RevocationStubURLProtocol.status = 503

        coordinator.setToggle(false)
        await coordinator.waitForPendingOperations()
        XCTAssertEqual(coordinator.availability, .disablePending)
        XCTAssertNil(tickets.load(), "当前记录立即清掉，待撤销的票据移进队列")
        XCTAssertEqual(tickets.loadBacklog()?.unregisterProfileID, "mac-a", "Mac 只是离线：注销留着重试")
        XCTAssertEqual(tickets.loadBacklog()?.tickets.count, 2)

        profiles.remove("mac-a")
        RevocationStubURLProtocol.status = 200
        coordinator.notificationBindingDidChange()
        await coordinator.waitForPendingOperations()
        XCTAssertNil(tickets.loadBacklog(), "档案删掉后注销视为完成，推送服务撤销成功即清空")
        XCTAssertEqual(coordinator.availability, .off)
        XCTAssertEqual(Set(RevocationStubURLProtocol.revokedTickets()), ["s", "u"])

        coordinator.setToggle(true)
        await coordinator.waitForPendingOperations()
        XCTAssertNotEqual(coordinator.availability, .disablePending)
        XCTAssertNotEqual(coordinator.availability, .off)
    }

    /// 推送服务还没恢复时重新开启：不能被旧票据挡住，也不能再去注销（会删掉新登记的票据）。
    func testReenableIsNotBlockedByUnrevokedTickets() async throws {
        let tickets = seededTicketStore(profileID: "mac-a")
        let coordinator = makeCoordinator(
            ticketStore: tickets,
            lockScreenStore: try boundLockScreenStore(profileID: "mac-a"),
            profileExists: { _ in true }
        )
        RevocationStubURLProtocol.status = 503

        coordinator.setToggle(false)
        await coordinator.waitForPendingOperations()
        XCTAssertEqual(coordinator.availability, .disablePending)

        coordinator.setToggle(true)
        await coordinator.waitForPendingOperations()
        XCTAssertNotEqual(coordinator.availability, .disablePending)
        XCTAssertNil(tickets.loadBacklog()?.unregisterProfileID, "重新开启后放弃对旧绑定的注销")
        XCTAssertEqual(tickets.loadBacklog()?.tickets.count, 2, "没撤销成功的票据继续留着重试")

        RevocationStubURLProtocol.status = 200
        coordinator.notificationBindingDidChange()
        await coordinator.waitForPendingOperations()
        XCTAssertNil(tickets.loadBacklog())
    }

    /// 关闭开关后进程在清理排队前就被结束：下次启动必须补做清理，撤销仍有效的票据。
    func testLaunchWithToggleOffResumesTeardown() async throws {
        let tickets = seededTicketStore(profileID: "mac-a")
        LiveActivityPreferences.setToggle(false, in: defaults)
        RevocationStubURLProtocol.status = 200
        let coordinator = makeCoordinator(
            ticketStore: tickets,
            lockScreenStore: try boundLockScreenStore(profileID: "mac-a"),
            profileExists: { _ in true }
        )
        await coordinator.waitForPendingOperations()
        XCTAssertNil(tickets.load(), "启动时补做清理，不能留下仍有效的记录")
        XCTAssertEqual(Set(RevocationStubURLProtocol.revokedTickets()), ["s", "u"])
        XCTAssertEqual(tickets.loadBacklog()?.tickets ?? [], [])
        XCTAssertEqual(tickets.loadBacklog()?.unregisterProfileID, "mac-a", "Mac 离线：注销留着在关闭期间重试")
        XCTAssertEqual(coordinator.availability, .disablePending)
    }

    /// 关闭消息通知后进程在清理前被结束：实时活动开关仍开着，启动时也要补做清理；
    /// 这时不注销 agentd（消息提醒的设备注销会一并删掉），只向推送服务撤销。
    func testLaunchWithNotificationsOffResumesTeardown() async throws {
        let tickets = seededTicketStore(profileID: "mac-a")
        defaults.set(false, forKey: MessageNotificationPreferences.key)
        RevocationStubURLProtocol.status = 200
        let coordinator = makeCoordinator(
            ticketStore: tickets,
            lockScreenStore: try boundLockScreenStore(profileID: "mac-a"),
            profileExists: { _ in true }
        )
        await coordinator.waitForPendingOperations()
        XCTAssertTrue(coordinator.isToggleOn)
        XCTAssertNil(tickets.load())
        XCTAssertEqual(Set(RevocationStubURLProtocol.revokedTickets()), ["s", "u"])
        XCTAssertNil(tickets.loadBacklog(), "不排 agentd 注销，撤销成功即清空")
        XCTAssertEqual(coordinator.availability, .requiresNotifications)
    }

    /// 当前用着另一台 Mac 时删掉绑定的那台：实时活动仍开着，也要清理它的记录并撤销票据。
    func testDeletingBoundProfileTearsDownWhileEnabled() async throws {
        let tickets = seededTicketStore(profileID: "mac-a")
        var profiles: Set<String> = ["mac-a", "mac-b"]
        RevocationStubURLProtocol.status = 200
        let coordinator = makeCoordinator(
            ticketStore: tickets,
            lockScreenStore: try boundLockScreenStore(profileID: "mac-a"),
            profileExists: { profiles.contains($0) }
        )
        coordinator.notificationBindingDidChange()
        await coordinator.waitForPendingOperations()
        XCTAssertNotNil(tickets.load(), "档案还在时保留记录")
        XCTAssertEqual(RevocationStubURLProtocol.revokedTickets(), [])

        profiles.remove("mac-a")
        coordinator.notificationBindingDidChange()
        await coordinator.waitForPendingOperations()
        XCTAssertNil(tickets.load())
        XCTAssertEqual(Set(RevocationStubURLProtocol.revokedTickets()), ["s", "u"])
        XCTAssertNil(tickets.loadBacklog())
        XCTAssertNotEqual(coordinator.availability, .ready)
    }

    /// 删掉绑定的那台 Mac 后进程在对账前被结束：两个开关都开着，启动时也要清理它的票据。
    func testLaunchWithDeletedProfileResumesTeardown() async throws {
        let tickets = seededTicketStore(profileID: "mac-gone")
        RevocationStubURLProtocol.status = 200
        let coordinator = makeCoordinator(
            ticketStore: tickets,
            lockScreenStore: try boundLockScreenStore(profileID: "mac-gone"),
            profileExists: { $0 != "mac-gone" }
        )
        await coordinator.waitForPendingOperations()
        XCTAssertTrue(coordinator.isToggleOn)
        XCTAssertNil(tickets.load())
        XCTAssertEqual(Set(RevocationStubURLProtocol.revokedTickets()), ["s", "u"])
        XCTAssertNil(tickets.loadBacklog())
    }

    /// 没有设备身份或档案已删时，注销永远不会成功，一次就算完成。
    func testUnregisterWithoutHostCompletesImmediately() async throws {
        let tickets = seededTicketStore(profileID: "mac-gone")
        let coordinator = makeCoordinator(
            ticketStore: tickets,
            lockScreenStore: try boundLockScreenStore(profileID: "mac-gone"),
            profileExists: { _ in false }
        )
        RevocationStubURLProtocol.status = 200
        coordinator.setToggle(false)
        await coordinator.waitForPendingOperations()
        XCTAssertNil(tickets.loadBacklog())
        XCTAssertEqual(coordinator.availability, .off)
    }
}

private final class RevocationStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var currentStatus = 200
    private static var revoked: [String] = []

    static var status: Int {
        get { lock.withLock { currentStatus } }
        set { lock.withLock { currentStatus = newValue } }
    }

    static func reset() {
        lock.withLock {
            currentStatus = 200
            revoked.removeAll()
        }
    }

    static func revokedTickets() -> [String] {
        lock.withLock { revoked }
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
        let status = Self.status
        if status == 200,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ticket = body["ticket"] as? String {
            Self.lock.withLock { Self.revoked.append(ticket) }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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

    /// 冷启动时会话列表为空：链接先等着，会话加载后再打开；超过一分钟只打开 App。
    func testPendingLinkWaitsForSessions() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = LiveActivityPendingLink(
            link: MimiTurnActivityLink(hostTag: "6AF3", sessionTag: "9E61BAD1E6C4DDAF"), createdAt: created
        )
        let profiles = [profile("mac-a", installationID: "install-test")]
        let sessions = [makeSession(id: "thread-1", projectID: "repo", title: "Fix", status: "running", source: "codex")]
        XCTAssertEqual(
            pending.resolve(now: created, profiles: profiles, activeProfileID: "mac-a", sessions: []), .wait
        )
        guard case .route(let route) = pending.resolve(
            now: created.addingTimeInterval(5), profiles: profiles, activeProfileID: "mac-a", sessions: sessions
        ) else {
            return XCTFail("会话加载后应打开它")
        }
        XCTAssertEqual(route.sessionID, "thread-1")
        XCTAssertEqual(
            pending.resolve(
                now: created.addingTimeInterval(LiveActivityPendingLink.lifetime + 1),
                profiles: profiles, activeProfileID: "mac-a", sessions: sessions
            ),
            .drop
        )
    }

    /// 点按时当前在另一台 Mac：立即放弃，之后切到那台 Mac 也不补跳；档案还没就绪时才等（#851 评审）。
    func testPendingLinkDropsWhenActiveProfileIsAnotherMac() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = LiveActivityPendingLink(
            link: MimiTurnActivityLink(hostTag: "6AF3", sessionTag: "9E61BAD1E6C4DDAF"), createdAt: created
        )
        let profiles = [profile("mac-a", installationID: "install-test"), profile("mac-b", installationID: "install-b")]
        let sessions = [makeSession(id: "thread-1", projectID: "repo", title: "Fix", status: "running", source: "codex")]

        XCTAssertEqual(
            pending.resolve(now: created, profiles: profiles, activeProfileID: "mac-b", sessions: sessions),
            .drop,
            "当前是另一台 Mac 时只打开 App，不能留着等"
        )
        XCTAssertEqual(
            pending.resolve(now: created, profiles: profiles, activeProfileID: nil, sessions: []),
            .wait,
            "冷启动还没有当前档案时先等"
        )
        XCTAssertEqual(
            pending.resolve(
                now: created,
                profiles: [profile("mac-a", installationID: nil)],
                activeProfileID: "mac-a",
                sessions: []
            ),
            .wait,
            "还不知道安装身份时判断不了是不是那台 Mac，先等"
        )
        XCTAssertNil(
            LiveActivityLinkRouting.activeHostMatches(
                link: pending.link, profiles: profiles, activeProfileID: "mac-unknown"
            ),
            "当前档案不在列表里时判断不了"
        )
        XCTAssertEqual(
            LiveActivityLinkRouting.activeHostMatches(link: pending.link, profiles: profiles, activeProfileID: "mac-a"),
            true
        )
    }

    /// 启动时同一台 Mac 有多个活动：保留已登记更新票据的那个，都没登记时保留最新的。
    func testStartupDuplicatesKeepRegisteredOrNewest() {
        let activities = [
            (id: "a1", hostTag: "6AF3"), (id: "b1", hostTag: "1B2C"), (id: "a2", hostTag: "6af3"), (id: "a3", hostTag: "6AF3"),
        ]
        XCTAssertEqual(LiveActivityHostFilter.duplicatesToEnd(activities, registeredIDs: ["a2"]), ["a1", "a3"])
        XCTAssertEqual(LiveActivityHostFilter.duplicatesToEnd(activities, registeredIDs: []), ["a1", "a2"])
        XCTAssertEqual(LiveActivityHostFilter.duplicatesToEnd([(id: "b1", hostTag: "1B2C")], registeredIDs: []), [])
    }

    /// 新一轮到来时，同一台 Mac 上一轮已结束、还留在锁屏上的卡和还在跑的旧活动都立即收起；
    /// 别的 Mac 的不动，没有当前活动时已结束的卡照常按 dismissal 保留。
    func testNewActivitySupersedesOthersOnSameHost() {
        let others = [(id: "a1", hostTag: "6AF3"), (id: "b1", hostTag: "1B2C"), (id: "a2", hostTag: "6af3")]
        XCTAssertEqual(
            LiveActivityHostFilter.supersededToEnd(others, current: [(id: "a3", hostTag: "6AF3")]), ["a1", "a2"]
        )
        XCTAssertEqual(
            LiveActivityHostFilter.supersededToEnd(
                others, current: [(id: "a3", hostTag: "6AF3"), (id: "b2", hostTag: "1B2C")]
            ),
            ["a1", "a2", "b1"]
        )
        XCTAssertEqual(LiveActivityHostFilter.supersededToEnd(others, current: []), [], "没有当前活动时不收起")
        XCTAssertEqual(
            LiveActivityHostFilter.supersededToEnd([(id: "a1", hostTag: "6AF3")], current: [(id: "a1", hostTag: "6AF3")]),
            [],
            "当前活动自己不收起"
        )
    }

    /// 冷启动时系统把新活动排在已结束的旧活动前面（2026-10-20 M5 实测）：不能按列出顺序判断先后。
    func testStartupDismissesEndedCardsRegardlessOfListOrder() {
        let ended = [(id: "old", hostTag: "6AF3")]
        XCTAssertEqual(LiveActivityHostFilter.supersededToEnd(ended, current: [(id: "new", hostTag: "6AF3")]), ["old"])
        XCTAssertEqual(
            LiveActivityHostFilter.supersededToEnd(ended, current: [(id: "other", hostTag: "1B2C")]),
            [],
            "另一台 Mac 的新活动不收起这台的已结束卡"
        )
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

    /// agentd 丢了票据而本机记录还新：按状态接口强制补登记；旧版 agentd 不回报时不判断。
    func testRegistrationRepairFollowsAgentdStatus() throws {
        func device(_ json: String) throws -> PushDeviceSummary {
            try JSONDecoder().decode(PushDeviceSummary.self, from: Data(json.utf8))
        }
        var record = LiveActivityTicketRecord(profileID: "mac", providerURL: "https://p", hostTag: "6AF3")
        record.start = .init(ticket: "s", expiresAt: .distantFuture, tokenFingerprint: "fp")
        record.updates["A"] = .init(ticket: "u", expiresAt: .distantFuture, tokenFingerprint: "fa")

        let lost = LiveActivityRegistrationRepair(
            device: try device(#"{"device_id":"d","live_activity_start":false,"live_activity_update":false}"#),
            record: record
        )
        XCTAssertTrue(lost.start)
        XCTAssertTrue(lost.update)

        let present = LiveActivityRegistrationRepair(
            device: try device(#"{"device_id":"d","live_activity_start":true,"live_activity_update":true}"#),
            record: record
        )
        XCTAssertEqual(present, LiveActivityRegistrationRepair())

        let oldAgentd = LiveActivityRegistrationRepair(device: try device(#"{"device_id":"d"}"#), record: record)
        XCTAssertEqual(oldAgentd, LiveActivityRegistrationRepair())

        let nothingLocal = LiveActivityRegistrationRepair(
            device: try device(#"{"device_id":"d","live_activity_start":false,"live_activity_update":false}"#),
            record: LiveActivityTicketRecord(profileID: "mac", providerURL: "https://p", hostTag: "6AF3")
        )
        XCTAssertEqual(nothingLocal, LiveActivityRegistrationRepair(), "本机没登记过就不算丢失")
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

/// 远程拉起后 App 在后台被唤醒交付更新 Token：不能因为还没取过 agentd 状态就跳过，
/// 登记要包在后台执行时间里，失败的回到前台补登记（#830）。
@MainActor
final class LiveActivityBackgroundRegistrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var lockScreenStore: LockScreenApprovalStore?
    private var background: BackgroundExecutionRecorder!
    private let hostTag = NotificationSessionTag.hostTag(installationID: "install-test")

    override func setUp() {
        super.setUp()
        suiteName = "LiveActivityBackgroundRegistrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        background = BackgroundExecutionRecorder()
        RegistrationStubURLProtocol.reset()
    }

    override func tearDown() {
        lockScreenStore = nil
        defaults.removePersistentDomain(forName: suiteName)
        RegistrationStubURLProtocol.reset()
        super.tearDown()
    }

    private var stubSession: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistrationStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private var agentdClient: AgentAPIClient {
        AgentAPIClient(endpoint: "http://100.64.0.10:8787", token: "token-a", session: stubSession)
    }

    private func makeCoordinator(
        tickets: LiveActivityTicketStore,
        makeClient: @escaping (String) async throws -> AgentAPIClient
    ) throws -> LiveActivityCoordinator {
        let background = background!
        let (coordinator, store) = try makeBoundLiveActivityCoordinator(
            defaults: defaults,
            tickets: tickets,
            session: stubSession,
            system: LiveActivitySystemHooks(
                activitiesEnabled: { true },
                isActivityAlive: { _ in true },
                beginBackgroundExecution: { background.begin(name: $0) }
            )
        )
        lockScreenStore = store
        coordinator.makeClient = makeClient
        return coordinator
    }

    private func diagnostics(since start: Date) -> [NotificationRouteDiagnostics.Entry] {
        NotificationRouteDiagnostics.entries().filter {
            $0.stage == NotificationRouteDiagnostics.Stage.liveActivity && $0.at >= start
        }
    }

    /// 冷启动唤醒：还没前台同步过（不知道 agentd 能力），更新 Token 也要登记到 agentd，
    /// 而且换票据与登记都发生在后台执行时间内。
    func testUpdateTokenRegistersBeforeHostStatusIsKnown() async throws {
        let start = Date()
        let tickets = LiveActivityTicketStore(keychain: TestKeychainOperations())
        let client = agentdClient
        let coordinator = try makeCoordinator(tickets: tickets) { _ in client }
        await coordinator.waitForPendingOperations()

        coordinator.didReceiveUpdateToken("ab12", activityID: "A", hostTag: hostTag)
        coordinator.didReceiveUpdateToken("ab12", activityID: "A", hostTag: hostTag)
        await coordinator.waitForPendingOperations()

        let registrations = RegistrationStubURLProtocol.requests(path: "/api/push/live-activities")
        XCTAssertEqual(registrations.count, 1, "同一个 Token 只登记一次")
        let body = try XCTUnwrap(registrations.first?.body)
        XCTAssertEqual(body["kind"] as? String, "update")
        XCTAssertEqual(body["activity_id"] as? String, "A")
        XCTAssertEqual(body["device_id"] as? String, "dev-test")
        XCTAssertEqual(RegistrationStubURLProtocol.requests(path: "/v1/ticket").count, 1)
        XCTAssertNotNil(tickets.load()?.updates["A"])
        XCTAssertTrue(
            RegistrationStubURLProtocol.allRequests().allSatisfy { $0.openBackgroundExecutions > 0 },
            "换票据与登记都要在后台执行时间内完成"
        )
        XCTAssertEqual(background.openCount, 0, "做完就结束后台执行申请")
        XCTAssertGreaterThan(background.beginCount, 0)
        XCTAssertTrue(diagnostics(since: start).contains { $0.outcome == "update_registered" })
    }

    /// 后台登记失败（例如连不上 Mac）：回到前台同步时补登记，agentd 状态接口还会顺带确认能力。
    func testFailedBackgroundRegistrationIsRepairedOnForeground() async throws {
        let start = Date()
        let tickets = LiveActivityTicketStore(keychain: TestKeychainOperations())
        let client = agentdClient
        var macReachable = false
        let coordinator = try makeCoordinator(tickets: tickets) { _ in
            guard macReachable else { throw URLError(.notConnectedToInternet) }
            return client
        }
        coordinator.didReceiveUpdateToken("ab12", activityID: "A", hostTag: hostTag)
        await coordinator.waitForPendingOperations()
        XCTAssertNil(tickets.load()?.updates["A"])
        XCTAssertEqual(RegistrationStubURLProtocol.requests(path: "/v1/ticket/revoke").count, 1, "没登记上的新票据立即撤销")
        XCTAssertTrue(diagnostics(since: start).contains { $0.outcome == "update_failed" })

        macReachable = true
        coordinator.synchronize(client: client, profileID: "mac-a")
        await coordinator.waitForPendingOperations()
        XCTAssertEqual(RegistrationStubURLProtocol.requests(path: "/api/push/live-activities").count, 1)
        XCTAssertNotNil(tickets.load()?.updates["A"])
        XCTAssertEqual(background.openCount, 0)
    }

    /// 失败要标明卡在哪一步并带耗时：手机连不上推送服务和连不上 Mac 是两个排查方向（#830 真机走查）。
    func testRegistrationFailureNamesTheStep() async throws {
        let start = Date()
        let tickets = LiveActivityTicketStore(keychain: TestKeychainOperations())
        let coordinator = try makeCoordinator(tickets: tickets) { _ in throw URLError(.notConnectedToInternet) }
        await coordinator.waitForPendingOperations()

        RegistrationStubURLProtocol.failTicketIssue = true
        coordinator.didReceiveUpdateToken("ab12", activityID: "A", hostTag: hostTag)
        await coordinator.waitForPendingOperations()
        RegistrationStubURLProtocol.failTicketIssue = false
        coordinator.didReceiveUpdateToken("cd34", activityID: "A", hostTag: hostTag)
        await coordinator.waitForPendingOperations()

        let failures = diagnostics(since: start).filter { $0.outcome == "update_failed" }
        XCTAssertEqual(failures.map(\.reason), ["provider:NSURLErrorDomain#-1005", "agentd:NSURLErrorDomain#-1009"])
        XCTAssertTrue(failures.allSatisfy { $0.elapsedMilliseconds != nil }, "失败带耗时，超时与连接被断能直接区分")
        XCTAssertEqual(
            RegistrationStubURLProtocol.requests(path: "/v1/ticket/revoke").count, 1,
            "只有换到票据、登记到 agentd 失败的那次需要撤销"
        )
        XCTAssertNil(tickets.load()?.updates["A"])
    }

    /// agentd 报告丢了更新票据、强制补登记又因连不上推送服务失败：本机记录里的旧条目不能继续挡住
    /// 本机兜底，否则这张卡再也没人收口（#881 评审）。旧票据转入撤销队列。
    func testFailedForcedRepairHandsTheCardToLocalFallback() async throws {
        let start = Date()
        let tickets = LiveActivityTicketStore(keychain: TestKeychainOperations())
        tickets.save(LiveActivityTicketRecord(
            profileID: "mac-a",
            providerURL: "https://push.example/mimi-push",
            hostTag: hostTag,
            updates: ["A": .init(
                ticket: "mpt1.1.old",
                expiresAt: Date().addingTimeInterval(2 * 60 * 60),
                tokenFingerprint: connectionCredentialFingerprint("ab12")
            )]
        ))
        let card = LiveActivitySnapshot(
            id: "A",
            hostTag: hostTag,
            state: MimiTurnActivityState(
                status: .running,
                runningCount: 1,
                needsYouCount: 0,
                startedAt: Int64(Date().addingTimeInterval(-60).timeIntervalSince1970),
                focusSessionTag: NotificationSessionTag.messageTag(threadID: "thread-1")
            )
        )
        var applied: [String] = []
        let background = background!
        let (coordinator, store) = try makeBoundLiveActivityCoordinator(
            defaults: defaults,
            tickets: tickets,
            session: stubSession,
            system: LiveActivitySystemHooks(
                activitiesEnabled: { true },
                isActivityAlive: { _ in true },
                beginBackgroundExecution: { background.begin(name: $0) },
                aliveActivities: { [card] },
                applyLocalFallback: { id, _ in applied.append(id) }
            )
        )
        lockScreenStore = store
        let client = agentdClient
        coordinator.makeClient = { _ in client }
        await coordinator.waitForPendingOperations()
        let running = [makeSession(id: "thread-1", projectID: "repo", title: "Fix", status: "running", source: "codex")]
        let idle = [makeSession(id: "thread-1", projectID: "repo", title: "Fix", status: "idle", source: "codex")]

        RegistrationStubURLProtocol.failTicketIssue = true
        coordinator.didReceiveUpdateToken("ab12", activityID: "A", hostTag: hostTag)
        await coordinator.waitForPendingOperations()
        coordinator.sessionsDidChange(running, activeProfileID: "mac-a", isAppActive: true)
        coordinator.sessionsDidChange(idle, activeProfileID: "mac-a", isAppActive: true)
        XCTAssertTrue(applied.isEmpty, "本机记录说已登记时交给 agentd")

        // 状态接口（替身）回报这台设备没有更新票据：强制补登记，换票据这一步失败。
        coordinator.synchronize(client: client, profileID: "mac-a")
        await coordinator.waitForPendingOperations()
        XCTAssertNil(tickets.load()?.updates["A"])
        XCTAssertEqual(tickets.loadBacklog()?.tickets.map(\.ticket), ["mpt1.1.old"])
        XCTAssertTrue(diagnostics(since: start).contains { $0.outcome == "update_discarded" })

        coordinator.sessionsDidChange(idle, activeProfileID: "mac-a", isAppActive: true)
        XCTAssertEqual(applied, ["A"], "摘掉旧条目后由本机兜底收口")
    }

    func testFailureReasonNamesStepAndStatus() {
        XCTAssertEqual(
            LiveActivityCoordinator.reason(
                LiveActivityRegistrationFailure(step: .provider, underlying: PushProviderError.rejected(status: 403))
            ),
            "provider:http_403"
        )
        XCTAssertEqual(
            LiveActivityCoordinator.reason(
                LiveActivityRegistrationFailure(step: .agentd, underlying: AgentAPIError.server(status: 404, message: "gone"))
            ),
            "agentd:http_404"
        )
        XCTAssertEqual(
            LiveActivityCoordinator.reason(LiveActivityRegistrationFailure(step: .provider, underlying: URLError(.timedOut))),
            "provider:NSURLErrorDomain#-1001"
        )
    }

    /// agentd 明确回报不支持时仍然不登记：放宽的只是「还不知道」。
    func testUpdateTokenSkipsHostReportedUnsupported() async throws {
        let start = Date()
        RegistrationStubURLProtocol.liveActivitySupported = false
        let tickets = LiveActivityTicketStore(keychain: TestKeychainOperations())
        let client = agentdClient
        let coordinator = try makeCoordinator(tickets: tickets) { _ in client }
        coordinator.synchronize(client: client, profileID: "mac-a")
        await coordinator.waitForPendingOperations()
        XCTAssertEqual(coordinator.availability, .unavailableOnHost)

        coordinator.didReceiveUpdateToken("ab12", activityID: "A", hostTag: hostTag)
        await coordinator.waitForPendingOperations()
        XCTAssertTrue(RegistrationStubURLProtocol.requests(path: "/v1/ticket").isEmpty)
        XCTAssertTrue(RegistrationStubURLProtocol.requests(path: "/api/push/live-activities").isEmpty)
        XCTAssertTrue(diagnostics(since: start).contains {
            $0.outcome == "update_skipped" && $0.reason == "host_unsupported"
        })
    }
}

/// 记录后台执行时间申请；请求发出时据此判断是否处在申请期内。
private final class BackgroundExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var open = 0
    private var begun = 0

    var openCount: Int { lock.withLock { open } }
    var beginCount: Int { lock.withLock { begun } }

    func begin(name: String) -> @MainActor () -> Void {
        lock.withLock {
            open += 1
            begun += 1
        }
        RegistrationStubURLProtocol.openBackgroundExecutions = { [weak self] in self?.openCount ?? 0 }
        var ended = false
        return { [weak self] in
            guard !ended else { return }
            ended = true
            self?.lock.withLock { self?.open -= 1 }
        }
    }
}

/// 推送服务与 agentd 的最小替身：换票据、撤销、状态接口与活动票据登记。
private final class RegistrationStubURLProtocol: URLProtocol {
    struct Recorded {
        let path: String
        let body: [String: Any]?
        let openBackgroundExecutions: Int
    }

    private static let lock = NSLock()
    private static var recorded: [Recorded] = []
    private static var supported = true
    private static var failTicket = false
    private static var openExecutions: (() -> Int)?

    static var liveActivitySupported: Bool {
        get { lock.withLock { supported } }
        set { lock.withLock { supported = newValue } }
    }

    static var openBackgroundExecutions: (() -> Int)? {
        get { lock.withLock { openExecutions } }
        set { lock.withLock { openExecutions = newValue } }
    }

    /// 模拟手机连不上推送服务：换票据的请求中途断开。
    static var failTicketIssue: Bool {
        get { lock.withLock { failTicket } }
        set { lock.withLock { failTicket = newValue } }
    }

    static func reset() {
        lock.withLock {
            recorded.removeAll()
            supported = true
            failTicket = false
            openExecutions = nil
        }
    }

    static func allRequests() -> [Recorded] {
        lock.withLock { recorded }
    }

    static func requests(path: String) -> [Recorded] {
        allRequests().filter { $0.path == path }
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
        // 推送服务的基址带路径前缀，按接口路径归一。
        let path = (request.url?.path ?? "").replacingOccurrences(of: "/mimi-push", with: "")
        let open = Self.openBackgroundExecutions?() ?? 0
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ticketCount = Self.lock.withLock { () -> Int in
            Self.recorded.append(Recorded(path: path, body: body, openBackgroundExecutions: open))
            return Self.recorded.filter { $0.path == "/v1/ticket" }.count
        }
        if path == "/v1/ticket", Self.failTicketIssue {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response: String
        switch path {
        case "/v1/ticket":
            response = #"{"ticket":"mpt1.1.t\#(ticketCount)","expires_at":"2030-01-01T00:00:00Z"}"#
        case "/api/push/status":
            let supported = Self.liveActivitySupported
            response = #"{"enabled":true,"provider_configured":true,"live_activity":\#(supported),"host_tag":"","devices":[{"device_id":"dev-test","live_activity_start":true,"live_activity_update":false}]}"#
        case "/api/push/live-activities":
            response = #"{"device_id":"dev-test","kind":"update","expires_at":"2030-01-01T00:00:00Z"}"#
        default:
            response = "{}"
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 已绑定到 mac-a 的协调器：消息提醒已登记、设备身份齐全。登记与本机兜底的用例共用。
/// 协调器只弱引用锁屏审批 Store，调用方要持有返回的 Store。
@MainActor
private func makeBoundLiveActivityCoordinator(
    defaults: UserDefaults,
    tickets: LiveActivityTicketStore,
    session: URLSession,
    system: LiveActivitySystemHooks
) throws -> (LiveActivityCoordinator, LockScreenApprovalStore) {
    let keychain = TestKeychainOperations()
    let identityStore = PushInstallationIdentityStore(keychain: keychain)
    try identityStore.save(PushInstallationIdentity(deviceID: "dev-test", installationID: "ins-test"))
    defaults.set(true, forKey: "lockScreenApproval.enabled")
    defaults.set("mac-a", forKey: "lockScreenApproval.registeredProfileID")
    defaults.set("https://push.example/mimi-push", forKey: "lockScreenApproval.registeredProviderURL")
    let store = LockScreenApprovalStore(
        defaults: defaults, ticketStore: PushTicketStore(keychain: keychain), identityStore: identityStore
    )
    let coordinator = LiveActivityCoordinator(
        defaults: defaults,
        ticketStore: tickets,
        environment: .sandbox,
        providerClientFactory: { PushProviderClient(baseURL: $0, session: session) },
        system: system
    )
    coordinator.attach(lockScreenStore: store)
    coordinator.profileExists = { $0 == "mac-a" }
    coordinator.installationIDForProfile = { _ in "install-test" }
    return (coordinator, store)
}

/// 更新票据没登记上的活动 agentd 改不动：App 在前台按本机会话状态同步或收口（#830 真机走查）。
final class LiveActivityLocalFallbackTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(
        _ status: MimiTurnActivityStatus = .running,
        focus: String = "thread-1",
        running: Int = 1,
        needsYou: Int = 0
    ) -> MimiTurnActivityState {
        MimiTurnActivityState(
            status: status,
            runningCount: running,
            needsYouCount: needsYou,
            startedAt: Int64(start.timeIntervalSince1970),
            focusSessionTag: NotificationSessionTag.messageTag(threadID: focus)
        )
    }

    private func session(_ id: String, _ status: String, updatedAt: Date, resumeID: String? = nil) -> AgentSession {
        makeSession(id: id, projectID: "repo", title: id, status: status, source: "codex", resumeID: resumeID, updatedAt: updatedAt)
    }

    private func observed(_ sessions: [AgentSession], at date: Date) -> LiveActivitySessionObservations {
        var observations = LiveActivitySessionObservations()
        observations.record(sessions: sessions, now: date)
        return observations
    }

    /// 这张卡拉起后在前台看到过焦点会话进行中，现在它停了：收成「已完成」并结束，计时起点与标签不变。
    func testEndsAfterFocusSessionWasSeenRunningThisRound() {
        let observations = observed([session("thread-1", "running", updatedAt: start)], at: start.addingTimeInterval(5))
        let action = LiveActivityLocalFallback.decide(
            current: card(),
            sessions: [session("thread-1", "idle", updatedAt: start.addingTimeInterval(-600))],
            observations: observations,
            now: start.addingTimeInterval(30)
        )
        XCTAssertEqual(action, .end(card(.completed, running: 0)))
    }

    func testFailedRoundEndsAsFailed() {
        let action = LiveActivityLocalFallback.decide(
            current: card(),
            sessions: [session("thread-1", "failed", updatedAt: start.addingTimeInterval(30))],
            observations: LiveActivitySessionObservations(),
            now: start.addingTimeInterval(40)
        )
        XCTAssertEqual(action, .end(card(.failed, running: 0)))
    }

    /// 卡是 App 挂起时远程拉起的，本机从没看到它进行中：服务端时间晚于拉起时间也算这一轮的结束。
    func testEndsWhenServerTimeIsAfterTheCardStarted() {
        let action = LiveActivityLocalFallback.decide(
            current: card(),
            sessions: [session("thread-1", "idle", updatedAt: start.addingTimeInterval(30))],
            observations: LiveActivitySessionObservations(),
            now: start.addingTimeInterval(40)
        )
        XCTAssertEqual(action, .end(card(.completed, running: 0)))
    }

    /// 列表可能还是挂起前的缓存：上一轮的「已结束」不能拿来收掉这一轮的卡。
    func testKeepsCardWhenTheListMayBeAStaleCache() {
        let stale = [session("thread-1", "idle", updatedAt: start.addingTimeInterval(-60))]
        XCTAssertEqual(
            LiveActivityLocalFallback.decide(
                current: card(), sessions: stale, observations: LiveActivitySessionObservations(), now: start
            ),
            .keep
        )
        let seenBeforeThisRound = observed([session("thread-1", "running", updatedAt: start)], at: start.addingTimeInterval(-120))
        XCTAssertEqual(
            LiveActivityLocalFallback.decide(current: card(), sessions: stale, observations: seenBeforeThisRound, now: start),
            .keep,
            "上一轮看到的进行中不算"
        )
    }

    func testKeepsCardWhenTheFocusSessionIsUnknown() {
        let observations = observed([session("thread-1", "running", updatedAt: start)], at: start.addingTimeInterval(5))
        XCTAssertEqual(
            LiveActivityLocalFallback.decide(current: card(), sessions: [], observations: observations, now: start),
            .keep,
            "会话列表还没加载时不猜"
        )
        XCTAssertEqual(
            LiveActivityLocalFallback.decide(
                current: card(),
                sessions: [session("thread-9", "idle", updatedAt: start.addingTimeInterval(30))],
                observations: observations,
                now: start
            ),
            .keep
        )
    }

    /// 还有会话在跑时按本机汇总同步，计时仍从卡片拉起时算；与卡片一致时不动。
    func testMirrorsTheLocalSummaryKeepingTheStartTime() {
        let sessions = [
            session("thread-1", "waiting_for_approval", updatedAt: start.addingTimeInterval(20)),
            session("thread-2", "running", updatedAt: start.addingTimeInterval(10)),
        ]
        let action = LiveActivityLocalFallback.decide(
            current: card(), sessions: sessions, observations: LiveActivitySessionObservations(), now: start.addingTimeInterval(60)
        )
        XCTAssertEqual(action, .update(card(.needsYou, running: 1, needsYou: 1)))
        XCTAssertEqual(
            LiveActivityLocalFallback.decide(
                current: card(.needsYou, running: 1, needsYou: 1),
                sessions: sessions,
                observations: LiveActivitySessionObservations(),
                now: start.addingTimeInterval(61)
            ),
            .keep
        )
    }

    /// 卡上的标签可能是 resumeID 对应的远端线程：焦点还是同一个会话时沿用它，不来回改写。
    func testResumedSessionKeepsTheCardTag() {
        let current = card(focus: "thread-2")
        XCTAssertEqual(
            LiveActivityLocalFallback.decide(
                current: current,
                sessions: [session("local-2", "running", updatedAt: start, resumeID: "thread-2")],
                observations: LiveActivitySessionObservations(),
                now: start.addingTimeInterval(5)
            ),
            .keep
        )
        let observations = observed(
            [session("local-2", "running", updatedAt: start, resumeID: "thread-2")], at: start.addingTimeInterval(5)
        )
        XCTAssertEqual(
            LiveActivityLocalFallback.decide(
                current: current,
                sessions: [session("local-2", "idle", updatedAt: start.addingTimeInterval(-60), resumeID: "thread-2")],
                observations: observations,
                now: start.addingTimeInterval(30)
            ),
            .end(card(.completed, focus: "thread-2", running: 0))
        )
    }

    /// 已经是终态却没结束（agentd 的 end 送不到）：不论本机列表如何都按原样结束。
    func testTerminalCardEndsAsIs() {
        let finished = card(.completed, running: 0)
        XCTAssertEqual(
            LiveActivityLocalFallback.decide(
                current: finished, sessions: [], observations: LiveActivitySessionObservations(), now: start
            ),
            .end(finished)
        )
        XCTAssertEqual(
            LiveActivityLocalFallback.decide(
                current: finished,
                sessions: [session("thread-2", "running", updatedAt: start.addingTimeInterval(60))],
                observations: LiveActivitySessionObservations(),
                now: start.addingTimeInterval(90)
            ),
            .end(finished),
            "又有会话开始时也不把上一轮的终态卡改回进行中：计时与焦点都属于上一轮"
        )
    }

    func testObservationsExpireAndIgnoreTagCase() {
        let tag = NotificationSessionTag.messageTag(threadID: "thread-1")
        var observations = observed([session("thread-1", "running", updatedAt: start)], at: start)
        XCTAssertEqual(observations.lastActive(tag: tag.lowercased()), start)
        observations.record(sessions: [session("thread-1", "idle", updatedAt: start)], now: start.addingTimeInterval(60))
        XCTAssertEqual(observations.lastActive(tag: tag), start, "停下来不抹掉最后一次看到进行中的时间")
        observations.record(sessions: [], now: start.addingTimeInterval(LiveActivitySessionObservations.retention + 1))
        XCTAssertNil(observations.lastActive(tag: tag))
    }
}

/// 协调器把本机兜底落到「没登记更新票据、属于绑定 Mac 的活动」上，只在前台、当前档案就是那台 Mac 时。
@MainActor
final class LiveActivityLocalFallbackCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var lockScreenStore: LockScreenApprovalStore?
    private var alive: [LiveActivitySnapshot] = []
    private var applied: [(id: String, action: LiveActivityLocalFallback)] = []
    private let hostTag = NotificationSessionTag.hostTag(installationID: "install-test")

    override func setUp() {
        super.setUp()
        suiteName = "LiveActivityLocalFallbackCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        alive = []
        applied = []
    }

    override func tearDown() {
        lockScreenStore = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCoordinator(tickets: LiveActivityTicketStore) async throws -> LiveActivityCoordinator {
        let (coordinator, store) = try makeBoundLiveActivityCoordinator(
            defaults: defaults,
            tickets: tickets,
            session: URLSession(configuration: .ephemeral),
            system: LiveActivitySystemHooks(
                activitiesEnabled: { true },
                isActivityAlive: { _ in true },
                beginBackgroundExecution: { _ in {} },
                aliveActivities: { [weak self] in self?.alive ?? [] },
                applyLocalFallback: { [weak self] id, action in self?.applied.append((id: id, action: action)) }
            )
        )
        lockScreenStore = store
        await coordinator.waitForPendingOperations()
        return coordinator
    }

    private func runningCard(id: String = "A", hostTag: String? = nil) -> LiveActivitySnapshot {
        LiveActivitySnapshot(
            id: id,
            hostTag: hostTag ?? self.hostTag,
            state: MimiTurnActivityState(
                status: .running,
                runningCount: 1,
                needsYouCount: 0,
                startedAt: Int64(Date().addingTimeInterval(-60).timeIntervalSince1970),
                focusSessionTag: NotificationSessionTag.messageTag(threadID: "thread-1")
            )
        )
    }

    private func sessions(_ status: String) -> [AgentSession] {
        [makeSession(id: "thread-1", projectID: "repo", title: "Fix", status: status, source: "codex")]
    }

    func testSettlesAnUnregisteredCardOnceWhenTheRoundEnds() async throws {
        let start = Date()
        let coordinator = try await makeCoordinator(tickets: LiveActivityTicketStore(keychain: TestKeychainOperations()))
        alive = [runningCard()]

        coordinator.sessionsDidChange(sessions("running"), activeProfileID: "mac-a", isAppActive: true)
        XCTAssertTrue(applied.isEmpty, "卡片与本机看到的一致时不动")

        coordinator.sessionsDidChange(sessions("idle"), activeProfileID: "mac-a", isAppActive: true)
        XCTAssertEqual(applied.map(\.id), ["A"])
        guard case .end(let state)? = applied.first?.action else {
            return XCTFail("回合结束后应收成终态并结束")
        }
        XCTAssertEqual(state.status, .completed)
        XCTAssertEqual(state.runningCount, 0)

        coordinator.sessionsDidChange(sessions("idle"), activeProfileID: "mac-a", isAppActive: true)
        XCTAssertEqual(applied.count, 1, "系统还没把它标成 ended 时不重复收口")
        XCTAssertTrue(NotificationRouteDiagnostics.entries().contains {
            $0.at >= start && $0.stage == NotificationRouteDiagnostics.Stage.liveActivity
                && $0.outcome == "local_settled" && $0.reason == "completed"
        })
    }

    /// 进行中的变化同步到卡上；系统还没把新内容读回来时，同样的变化不重复写。
    func testMirrorsEachChangeOnce() async throws {
        let coordinator = try await makeCoordinator(tickets: LiveActivityTicketStore(keychain: TestKeychainOperations()))
        let card = runningCard()
        alive = [card]

        coordinator.sessionsDidChange(sessions("waiting_for_approval"), activeProfileID: "mac-a", isAppActive: true)
        coordinator.sessionsDidChange(sessions("waiting_for_approval"), activeProfileID: "mac-a", isAppActive: true)
        XCTAssertEqual(applied.count, 1)
        guard case .update(let state)? = applied.first?.action else {
            return XCTFail("待你处理应同步到卡上")
        }
        XCTAssertEqual(state.status, .needsYou)
        XCTAssertEqual(state.startedAt, card.state.startedAt, "计时仍从卡片拉起时算")
    }

    /// 更新票据已登记的活动由 agentd 推送驱动，本机不碰。
    func testLeavesRegisteredCardsToAgentd() async throws {
        let tickets = LiveActivityTicketStore(keychain: TestKeychainOperations())
        tickets.save(LiveActivityTicketRecord(
            profileID: "mac-a",
            providerURL: "https://push.example/mimi-push",
            hostTag: hostTag,
            updates: ["A": .init(ticket: "mpt1.1.t", expiresAt: Date().addingTimeInterval(3600), tokenFingerprint: "f")]
        ))
        let coordinator = try await makeCoordinator(tickets: tickets)
        alive = [runningCard()]

        coordinator.sessionsDidChange(sessions("running"), activeProfileID: "mac-a", isAppActive: true)
        coordinator.sessionsDidChange(sessions("idle"), activeProfileID: "mac-a", isAppActive: true)
        XCTAssertTrue(applied.isEmpty)
    }

    func testOnlyActsInTheForegroundOnTheBoundMac() async throws {
        let coordinator = try await makeCoordinator(tickets: LiveActivityTicketStore(keychain: TestKeychainOperations()))
        alive = [runningCard()]
        coordinator.sessionsDidChange(sessions("running"), activeProfileID: "mac-a", isAppActive: true)

        coordinator.sessionsDidChange(sessions("idle"), activeProfileID: "mac-a", isAppActive: false)
        XCTAssertTrue(applied.isEmpty, "后台被唤醒时列表可能是旧的，不动")
        coordinator.sessionsDidChange(sessions("idle"), activeProfileID: "mac-b", isAppActive: true)
        XCTAssertTrue(applied.isEmpty, "当前是另一台 Mac 时，本机列表不代表这张卡")

        alive = [runningCard(id: "B", hostTag: "1B2C")]
        coordinator.sessionsDidChange(sessions("idle"), activeProfileID: "mac-a", isAppActive: true)
        XCTAssertTrue(applied.isEmpty, "别的 Mac 的活动不动")

        alive = [runningCard()]
        coordinator.sessionsDidChange(sessions("idle"), activeProfileID: "mac-a", isAppActive: true)
        XCTAssertEqual(applied.map(\.id), ["A"])
    }
}
