import UserNotifications
import XCTest
@testable import MimiRemote

/// #510：App 在前台时，回复类通知改为 App 内轻提示；审批、定时提醒与无法确认类别的通知
/// 保持系统横幅；目标会话可见时什么都不出。
@MainActor
final class ForegroundNotificationPresentationTests: XCTestCase {
    private let installationID = "installation-1"
    private let route = SessionNotificationRoute.current(
        profileID: "mac-a",
        projectID: "project-a",
        sessionID: "thread-1"
    )
    private let otherRoute = SessionNotificationRoute.current(
        profileID: "mac-a",
        projectID: "project-b",
        sessionID: "thread-2"
    )

    override func setUp() {
        super.setUp()
        // 偏好读取 standard；每个用例按“已开启”起步，结束时恢复原值。
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: MessageNotificationPreferences.key)
        defaults.set(true, forKey: MessageNotificationPreferences.key)
        addTeardownBlock {
            if let previous {
                defaults.set(previous, forKey: MessageNotificationPreferences.key)
            } else {
                defaults.removeObject(forKey: MessageNotificationPreferences.key)
            }
        }
    }

    // MARK: - 通知类别 × 前台状态

    private enum ForegroundState: CaseIterable {
        /// App 在前台但没有能显示轻提示的窗口（未进入工作台，或 Scene 处于 inactive）。
        case noHost
        /// 工作台在前台，目标会话不可见。
        case targetHidden
        /// 目标会话正显示在另一个窗口里。
        case targetVisibleInOtherScene
        /// 用户关闭了消息通知。
        case messagesDisabled
    }

    private struct Sample {
        let name: String
        let identifier: String
        let userInfo: [AnyHashable: Any]
        let expected: [ForegroundState: ForegroundNotificationPresentation]
    }

    func testPresentationMatrixAcrossCategoriesAndForegroundStates() {
        let messageTarget = ForegroundSessionNotice.Target.message(
            profileTag: LockScreenApprovalRouting.profileTag(installationID: installationID),
            sessionTag: LockScreenApprovalRouting.messageSessionTag(threadID: route.sessionID)
        )
        var samples: [Sample] = []
        for (event, tone) in [
            ("turn.completed", ForegroundSessionNotice.Tone.completed),
            ("turn.failed", .failed),
            ("turn.interrupted", .interrupted),
        ] {
            samples.append(Sample(
                name: "远程 \(event)",
                identifier: "remote-\(event)",
                userInfo: remotePayload(event: event),
                expected: [
                    .noHost: .system,
                    .targetHidden: .inApp(tone, messageTarget),
                    .targetVisibleInOtherScene: .quiet,
                    .messagesDisabled: .quiet,
                ]
            ))
        }
        samples.append(Sample(
            name: "远程审批",
            identifier: "remote-approval",
            userInfo: remotePayload(event: "approval.pending", kind: "command"),
            expected: [
                .noHost: .system,
                .targetHidden: .system,
                .targetVisibleInOtherScene: .system,
                .messagesDisabled: .quiet,
            ]
        ))
        for (kind, tone) in [
            (SessionRuntimeNotification.Kind.completed, ForegroundSessionNotice.Tone.completed),
            (.failed, .failed),
            (.interrupted, .interrupted),
        ] {
            samples.append(Sample(
                name: "本地运行态 \(kind.rawValue)",
                identifier: runtimeID("\(kind.rawValue):thread-1:turn-1"),
                userInfo: runtimeNotification(kind: kind).notificationUserInfo(route: route),
                expected: [
                    .noHost: .system,
                    .targetHidden: .inApp(tone, .route(route)),
                    .targetVisibleInOtherScene: .quiet,
                    .messagesDisabled: .quiet,
                ]
            ))
        }
        samples.append(Sample(
            name: "本地运行态审批",
            identifier: runtimeID("approval:thread-1:request-1"),
            userInfo: runtimeNotification(kind: .approval).notificationUserInfo(route: route),
            expected: [
                .noHost: .system,
                .targetHidden: .system,
                .targetVisibleInOtherScene: .quiet,
                .messagesDisabled: .quiet,
            ]
        ))
        samples.append(Sample(
            name: "旧版无类别键的运行态通知",
            identifier: runtimeID("completed:thread-1:turn-1"),
            userInfo: route.userInfo,
            expected: [
                .noHost: .system,
                .targetHidden: .system,
                .targetVisibleInOtherScene: .quiet,
                .messagesDisabled: .quiet,
            ]
        ))
        samples.append(Sample(
            name: "用户自设的定时提醒",
            identifier: UserNotificationSessionReminderScheduler.notificationID(
                profileID: route.profileID,
                sessionID: route.sessionID
            ),
            userInfo: route.userInfo,
            expected: [
                .noHost: .system,
                .targetHidden: .system,
                .targetVisibleInOtherScene: .system,
                .messagesDisabled: .system,
            ]
        ))
        samples.append(Sample(
            name: "路由畸形的运行态通知",
            identifier: runtimeID("completed:thread-1:turn-1"),
            userInfo: ["mimi.route.sessionID": route.sessionID, SessionRuntimeNotification.Kind.notificationUserInfoKey: "completed"],
            expected: [
                .noHost: .system,
                .targetHidden: .system,
                .targetVisibleInOtherScene: .system,
                .messagesDisabled: .quiet,
            ]
        ))

        for state in ForegroundState.allCases {
            let adapter = makeAdapter(for: state)
            for sample in samples {
                XCTAssertEqual(
                    adapter.foregroundPresentation(
                        forNotificationIdentifier: sample.identifier,
                        userInfo: sample.userInfo
                    ),
                    sample.expected[state],
                    "\(sample.name) 在 \(state) 下的前台呈现不符合预期"
                )
            }
        }
    }

    func testPresentationOptionsNeverRingForInAppAndKeepSystemBannerForApprovals() {
        XCTAssertEqual(ForegroundNotificationPresentation.quiet.options, [])
        // 轻提示不弹横幅、不响铃，但留在通知中心，连续收到时被替换掉的那条不会丢。
        XCTAssertEqual(ForegroundNotificationPresentation.inApp(.completed, .route(route)).options, [.list])
        XCTAssertEqual(ForegroundNotificationPresentation.system.options, [.banner, .sound])
        // App 不使用角标，三态都不能顺手把 badge 带出来。
        for presentation in [
            ForegroundNotificationPresentation.quiet,
            .system,
            .inApp(.failed, .route(route)),
        ] {
            XCTAssertFalse(presentation.options.contains(.badge))
        }
        XCTAssertFalse(ForegroundNotificationPresentation.inApp(.failed, .route(route)).options.contains(.banner))
        XCTAssertFalse(ForegroundNotificationPresentation.inApp(.failed, .route(route)).options.contains(.sound))
    }

    func testTargetVisibleInSameSceneOrOnAnotherMacFollowsVisibleTags() {
        let adapter = SessionNotificationResponseAdapter()
        let scene = UUID()
        adapter.setInAppNoticeHostAvailable(true, for: scene)
        adapter.setVisibleSessionRoute(route, for: scene, installationID: installationID)
        XCTAssertEqual(
            adapter.foregroundPresentation(forNotificationIdentifier: "remote", userInfo: remotePayload(event: "turn.completed")),
            .quiet,
            "同一窗口正在看目标会话时什么都不出"
        )
        // 另一台 Mac 的同名会话不能被当成“正在看”。
        adapter.setVisibleSessionRoute(route, for: scene, installationID: "other-mac")
        guard case .inApp = adapter.foregroundPresentation(
            forNotificationIdentifier: "remote",
            userInfo: remotePayload(event: "turn.completed")
        ) else {
            return XCTFail("其他 Mac 的同名会话可见时，仍应给出轻提示")
        }
    }

    func testModalOverWorkbenchFallsBackToSystemBanner() {
        let adapter = SessionNotificationResponseAdapter()
        let scene = UUID()
        var modalPresented = true
        adapter.setInAppNoticeHostAvailable(true, for: scene) { !modalPresented }
        let reply = remotePayload(event: "turn.completed")
        XCTAssertEqual(
            adapter.foregroundPresentation(forNotificationIdentifier: "remote", userInfo: reply),
            .system,
            "工作台被 sheet 等模态页面盖住时轻提示看不到，交回系统横幅"
        )
        modalPresented = false
        guard case .inApp = adapter.foregroundPresentation(forNotificationIdentifier: "remote", userInfo: reply) else {
            return XCTFail("模态页面关闭后恢复 App 内轻提示")
        }
        // 多窗口：任一前台窗口能显示即可。
        modalPresented = true
        adapter.setInAppNoticeHostAvailable(true, for: UUID())
        guard case .inApp = adapter.foregroundPresentation(forNotificationIdentifier: "remote", userInfo: reply) else {
            return XCTFail("另一个前台窗口没有被遮挡时仍应给出轻提示")
        }
    }

    func testNoticeMapsOntoSharedInAppToast() {
        var opened = false
        let cases: [(ForegroundSessionNotice.Tone, InAppToast.Style, String?)] = [
            (.completed, .success, nil),
            (.failed, .failure, nil),
            (.interrupted, .info, "stop.circle.fill"),
        ]
        for (tone, style, systemImage) in cases {
            let notice = ForegroundSessionNotice(
                requestIdentifier: "id", tone: tone, target: .route(route),
                title: "Thread", body: "Replied", userInfo: route.userInfo
            )
            let toast = InAppToast(notice: notice) { opened = true }
            XCTAssertEqual(toast.id, AnyHashable(notice.id), "收起回调要能按 id 找回对应提示")
            XCTAssertEqual(toast.style, style)
            XCTAssertEqual(toast.systemImage, systemImage)
            XCTAssertEqual(toast.title, "Thread")
            XCTAssertEqual(toast.subtitle, "Replied")
            XCTAssertNil(toast.action, "回复提醒只有点按正文这一个动作")
            XCTAssertEqual(toast.duration, InAppToast.foregroundNoticeDuration)
            toast.tapAction?()
        }
        XCTAssertTrue(opened, "点按正文必须交回通知路由")
        let untitled = InAppToast(notice: ForegroundSessionNotice(
            requestIdentifier: "id", tone: .completed, target: .route(route),
            title: "Only title", body: "", userInfo: [:]
        )) {}
        XCTAssertNil(untitled.subtitle)
    }

    // MARK: - 轻提示的生命周期

    func testInAppPresentationPublishesNoticeWithReadableLines() throws {
        let adapter = makeAdapter(for: .targetHidden)
        let options = adapter.presentInForeground(
            identifier: "remote-completed",
            title: "Refactor parser",
            subtitle: "Codex · mimi",
            body: "Replied",
            userInfo: remotePayload(event: "turn.completed")
        )
        XCTAssertEqual(options, [.list], "前台回复类通知不能弹横幅或响铃，只留在通知中心")
        let notice = try XCTUnwrap(adapter.foregroundNotice)
        XCTAssertEqual(notice.title, "Refactor parser")
        XCTAssertEqual(notice.body, "Replied")
        XCTAssertEqual(notice.tone, .completed)
        XCTAssertEqual(notice.requestIdentifier, "remote-completed")

        let fallback = ForegroundSessionNotice(
            requestIdentifier: "id", tone: .failed, target: .route(route),
            title: "  ", subtitle: "Codex", body: "", userInfo: [:]
        )
        XCTAssertEqual(fallback.title, "Codex", "标题为空时顺延到副标题")
        XCTAssertEqual(fallback.body, "")
    }

    func testSystemAndQuietPresentationsDoNotPublishNotice() {
        let adapter = makeAdapter(for: .targetHidden)
        XCTAssertEqual(
            adapter.presentInForeground(
                identifier: "remote-approval", title: "Approve", subtitle: "", body: "Run",
                userInfo: remotePayload(event: "approval.pending", kind: "command")
            ),
            [.banner, .sound]
        )
        XCTAssertNil(adapter.foregroundNotice, "审批仍走系统横幅，不能再叠一条轻提示")

        let visible = makeAdapter(for: .targetVisibleInOtherScene)
        XCTAssertEqual(
            visible.presentInForeground(
                identifier: "remote-completed", title: "Done", subtitle: "", body: "",
                userInfo: remotePayload(event: "turn.completed")
            ),
            []
        )
        XCTAssertNil(visible.foregroundNotice, "目标会话可见时连轻提示也不出")
    }

    func testLaterNoticeReplacesEarlierAndStaleDismissIsIgnored() throws {
        let adapter = makeAdapter(for: .targetHidden)
        _ = adapter.presentInForeground(
            identifier: runtimeID("completed:thread-1:turn-1"), title: "First", subtitle: "", body: "",
            userInfo: runtimeNotification(kind: .completed).notificationUserInfo(route: route)
        )
        let first = try XCTUnwrap(adapter.foregroundNotice)
        _ = adapter.presentInForeground(
            identifier: runtimeID("failed:thread-1:turn-2"), title: "Second", subtitle: "", body: "",
            userInfo: runtimeNotification(kind: .failed).notificationUserInfo(route: route)
        )
        let second = try XCTUnwrap(adapter.foregroundNotice)
        XCTAssertNotEqual(first.id, second.id)
        adapter.dismissForegroundNotice(first.id)
        XCTAssertEqual(adapter.foregroundNotice?.id, second.id, "旧提示的计时结束不能收起新提示")
        adapter.dismissForegroundNotice(second.id)
        XCTAssertNil(adapter.foregroundNotice)
    }

    func testNoticeClearsWhenTargetBecomesVisibleOrNoHostRemains() {
        let adapter = SessionNotificationResponseAdapter()
        let scene = UUID()
        let otherScene = UUID()
        adapter.setInAppNoticeHostAvailable(true, for: scene)
        adapter.setInAppNoticeHostAvailable(true, for: otherScene)

        _ = adapter.presentInForeground(
            identifier: runtimeID("completed:thread-1:turn-1"), title: "Completed", subtitle: "", body: "Thread",
            userInfo: runtimeNotification(kind: .completed).notificationUserInfo(route: route)
        )
        XCTAssertNotNil(adapter.foregroundNotice)
        adapter.setVisibleSessionRoute(otherRoute, for: otherScene)
        XCTAssertNotNil(adapter.foregroundNotice, "打开别的会话不影响当前提示")
        adapter.setVisibleSessionRoute(route, for: scene)
        XCTAssertNil(adapter.foregroundNotice, "用户已经打开目标会话，提示自动收起")

        adapter.setVisibleSessionRoute(nil, for: scene)
        _ = adapter.presentInForeground(
            identifier: runtimeID("completed:thread-1:turn-2"), title: "Completed", subtitle: "", body: "Thread",
            userInfo: runtimeNotification(kind: .completed).notificationUserInfo(route: route)
        )
        XCTAssertNotNil(adapter.foregroundNotice)
        adapter.setInAppNoticeHostAvailable(false, for: scene)
        XCTAssertNotNil(adapter.foregroundNotice, "另一个前台窗口仍可显示")
        adapter.setInAppNoticeHostAvailable(false, for: otherScene)
        XCTAssertNil(adapter.foregroundNotice, "所有窗口都离开前台后不残留旧提示")
    }

    func testOnlyMostRecentlyActiveUnobstructedSceneShowsNotice() throws {
        let adapter = SessionNotificationResponseAdapter()
        let first = UUID()
        let second = UUID()
        var secondObstructed = false
        adapter.setInAppNoticeHostAvailable(true, for: first)
        adapter.setInAppNoticeHostAvailable(true, for: second) { !secondObstructed }
        let reply = runtimeNotification(kind: .completed).notificationUserInfo(route: route)

        _ = adapter.presentInForeground(
            identifier: runtimeID("completed:thread-1:turn-1"), title: "Done", subtitle: "", body: "",
            userInfo: reply
        )
        XCTAssertEqual(try XCTUnwrap(adapter.foregroundNotice).hostSceneID, second, "多窗口只交给最近激活的窗口，避免重复播报")

        secondObstructed = true
        _ = adapter.presentInForeground(
            identifier: runtimeID("completed:thread-1:turn-2"), title: "Done", subtitle: "", body: "",
            userInfo: reply
        )
        XCTAssertEqual(try XCTUnwrap(adapter.foregroundNotice).hostSceneID, first, "最近的窗口被模态页面挡住时换另一个前台窗口")

        // 重新激活会把窗口排到最前。
        secondObstructed = false
        adapter.setInAppNoticeHostAvailable(false, for: first)
        XCTAssertNil(adapter.foregroundNotice, "负责显示的窗口离开前台时收起，通知已留在通知中心")
        adapter.setInAppNoticeHostAvailable(true, for: first)
        _ = adapter.presentInForeground(
            identifier: runtimeID("completed:thread-1:turn-3"), title: "Done", subtitle: "", body: "",
            userInfo: reply
        )
        XCTAssertEqual(try XCTUnwrap(adapter.foregroundNotice).hostSceneID, first)
        adapter.setInAppNoticeHostAvailable(false, for: second)
        XCTAssertNotNil(adapter.foregroundNotice, "不负责显示的窗口离开前台不影响当前提示")
    }

    func testListedRepliesAreRemovedWhenOpenedFromNoticeOrSessionBecomesVisible() async throws {
        let adapter = makeAdapter(for: .targetHidden)
        var removed: [[String]] = []
        adapter.removeDeliveredNotifications = { removed.append($0) }
        let scene = UUID()
        let thirdRoute = SessionNotificationRoute.current(profileID: "mac-a", projectID: "project-c", sessionID: "thread-3")

        // 同一会话两条回复、另一会话一条回复，外加不进通知中心记录的审批与定时提醒。
        _ = adapter.presentInForeground(
            identifier: runtimeID("completed:thread-1:turn-1"), title: "Done", subtitle: "", body: "",
            userInfo: runtimeNotification(kind: .completed).notificationUserInfo(route: route)
        )
        _ = adapter.presentInForeground(
            identifier: "remote-thread-1", title: "Failed", subtitle: "", body: "",
            userInfo: remotePayload(event: "turn.failed")
        )
        _ = adapter.presentInForeground(
            identifier: runtimeID("completed:thread-3:turn-1"), title: "Done", subtitle: "", body: "",
            userInfo: runtimeNotification(kind: .completed).notificationUserInfo(route: thirdRoute)
        )
        let thirdNotice = try XCTUnwrap(adapter.foregroundNotice)
        _ = adapter.presentInForeground(
            identifier: runtimeID("approval:thread-1:request-1"), title: "Approve", subtitle: "", body: "",
            userInfo: runtimeNotification(kind: .approval).notificationUserInfo(route: route)
        )
        _ = adapter.presentInForeground(
            identifier: UserNotificationSessionReminderScheduler.notificationID(profileID: route.profileID, sessionID: route.sessionID),
            title: "Reminder", subtitle: "", body: "", userInfo: route.userInfo
        )
        XCTAssertTrue(removed.isEmpty)

        // 点按轻提示：只清这一会话的回复提醒。
        await adapter.openForegroundNotice(thirdNotice)
        XCTAssertEqual(removed, [[runtimeID("completed:thread-3:turn-1")]])

        // 自己打开会话：本地路由与远程标签两种回复提醒都清掉，审批与定时提醒不动。
        adapter.setVisibleSessionRoute(route, for: scene, installationID: installationID)
        XCTAssertEqual(removed.count, 3, "本地路由与远程标签各清一次")
        XCTAssertEqual(Set(removed.flatMap { $0 }), [
            runtimeID("completed:thread-3:turn-1"),
            runtimeID("completed:thread-1:turn-1"),
            "remote-thread-1",
        ])
        XCTAssertFalse(removed.flatMap { $0 }.contains(runtimeID("approval:thread-1:request-1")))

        // 已清过的不重复清。
        adapter.setVisibleSessionRoute(nil, for: scene)
        adapter.setVisibleSessionRoute(route, for: scene, installationID: installationID)
        XCTAssertEqual(removed.count, 3)
    }

    // MARK: - 点按复用通知点击入口

    func testOpeningLocalNoticeReusesPendingRouteEntry() async throws {
        let adapter = makeAdapter(for: .targetHidden)
        _ = adapter.presentInForeground(
            identifier: runtimeID("completed:thread-1:turn-1"), title: "Completed", subtitle: "", body: "Thread",
            userInfo: runtimeNotification(kind: .completed).notificationUserInfo(route: route)
        )
        let notice = try XCTUnwrap(adapter.foregroundNotice)
        await adapter.openForegroundNotice(notice)
        XCTAssertNil(adapter.foregroundNotice)
        XCTAssertEqual(adapter.pendingRoute, route, "与点系统横幅一样进入 pendingRoute")
        XCTAssertNotNil(adapter.pendingRouteIntent)
        XCTAssertNil(adapter.approvalInbox.pending)
    }

    func testOpeningRemoteNoticeReusesApprovalInboxEntry() async throws {
        let adapter = makeAdapter(for: .targetHidden)
        _ = adapter.presentInForeground(
            identifier: "remote-failed", title: "Task", subtitle: "", body: "Failed",
            userInfo: remotePayload(event: "turn.failed")
        )
        let notice = try XCTUnwrap(adapter.foregroundNotice)
        await adapter.openForegroundNotice(notice)
        XCTAssertNil(adapter.foregroundNotice)
        let delivery = try XCTUnwrap(adapter.approvalInbox.pending, "与点系统横幅一样进入通知收件箱")
        XCTAssertNil(delivery.decision, "轻提示点按只代表“查看详情”，不能提交任何决策")
        XCTAssertEqual(delivery.notification.event, .failed)
        XCTAssertEqual(delivery.requestIdentifier, "remote-failed")
        XCTAssertNil(adapter.pendingRoute)
    }

    // MARK: - 运行态通知携带类别

    func testRuntimeNotificationKindRoundTripsThroughUserInfo() {
        for kind in [SessionRuntimeNotification.Kind.approval, .completed, .failed, .interrupted] {
            let userInfo = runtimeNotification(kind: kind).notificationUserInfo(route: route)
            XCTAssertEqual(SessionRuntimeNotification.Kind(notificationUserInfo: userInfo), kind)
            XCTAssertEqual(SessionNotificationRoute(userInfo: userInfo), route, "类别键不能破坏原有路由解码")
        }
        XCTAssertNil(SessionRuntimeNotification.Kind(notificationUserInfo: route.userInfo))
        XCTAssertNil(SessionRuntimeNotification.Kind(notificationUserInfo: [
            SessionRuntimeNotification.Kind.notificationUserInfoKey: "unknown",
        ]))
    }

    func testInterruptedTurnProducesInterruptedRuntimeNotification() throws {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        let metadata = AgentEventMetadata(
            seq: 1, sessionID: "thread-1", turnID: "turn-1", itemID: nil, messageID: nil,
            clientMessageID: nil, revision: nil, createdAt: nil
        )
        let interrupted = try XCTUnwrap(store.runtimeNotification(
            for: .turnCompleted(metadata.withTurnLifecycle(.interrupted)),
            fallbackSessionID: "thread-1"
        ))
        XCTAssertEqual(interrupted.kind, .interrupted)
        XCTAssertEqual(interrupted.id, "stopped:thread-1:turn-1", "通知 ID 保持不变，已投递去重不受影响")
        let completed = try XCTUnwrap(store.runtimeNotification(
            for: .turnCompleted(metadata.withTurnLifecycle(.completed)),
            fallbackSessionID: "thread-1"
        ))
        XCTAssertEqual(completed.kind, .completed)
    }

    // MARK: - Helpers

    private func makeAdapter(for state: ForegroundState) -> SessionNotificationResponseAdapter {
        let adapter = SessionNotificationResponseAdapter()
        let scene = UUID()
        let otherScene = UUID()
        UserDefaults.standard.set(state != .messagesDisabled, forKey: MessageNotificationPreferences.key)
        switch state {
        case .noHost:
            break
        case .targetHidden:
            adapter.setInAppNoticeHostAvailable(true, for: scene)
            adapter.setVisibleSessionRoute(otherRoute, for: scene, installationID: installationID)
        case .targetVisibleInOtherScene:
            adapter.setInAppNoticeHostAvailable(true, for: scene)
            adapter.setVisibleSessionRoute(otherRoute, for: scene, installationID: installationID)
            adapter.setVisibleSessionRoute(route, for: otherScene, installationID: installationID)
        case .messagesDisabled:
            adapter.setInAppNoticeHostAvailable(true, for: scene)
        }
        return adapter
    }

    private func runtimeID(_ id: String) -> String {
        UserNotificationSessionReminderScheduler.runtimeNotificationID(profileID: route.profileID, id: id)
    }

    private func runtimeNotification(kind: SessionRuntimeNotification.Kind) -> SessionRuntimeNotification {
        SessionRuntimeNotification(id: "event", sessionID: route.sessionID, title: "Title", body: "Body", kind: kind)
    }

    private func remotePayload(event: String, kind: String = "") -> [AnyHashable: Any] {
        [
            "mimi": [
                "version": 1,
                "event": event,
                "action_id": "act-0123456789abcdef",
                "device_id": "dev-abc123",
                "profile_id": LockScreenApprovalRouting.profileTag(installationID: installationID),
                "runtime": "codex",
                "approval_kind": kind,
                "host_tag": "A1C3",
                "session_tag": LockScreenApprovalRouting.messageSessionTag(threadID: route.sessionID),
                "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)),
            ] as [String: Any],
        ]
    }
}
