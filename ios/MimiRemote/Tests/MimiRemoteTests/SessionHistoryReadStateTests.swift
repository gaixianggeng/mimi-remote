import XCTest
@testable import MimiRemote

/// #653：Mac 端从旧 Rust bridge 换成 SDK 适配器后，Claude 会话的 updatedAt 从文件 mtime
/// 纠正为最后一条真实对话时间（通常往回退）。时间回退不能制造未读；前移和真实续聊仍按原规则。
@MainActor
final class SessionHistoryReadStateTests: XCTestCase {
    private let projectID = "project-backdated"
    private let sessionID = "claude-backdated"
    private var defaults: UserDefaults!
    private var readStateStore: SessionHistoryReadStateStore!
    private var appStore: AppStore!

    override func setUp() {
        super.setUp()
        let suiteName = "SessionHistoryReadStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { [defaults] in
            defaults?.removePersistentDomain(forName: suiteName)
        }
        readStateStore = SessionHistoryReadStateStore(defaults: defaults)
        appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: TestKeychainOperations()))
    }

    /// 每次创建都从同一份 UserDefaults 重新加载水位，等价于升级后重启 App。
    private func makeStore() -> SessionStore {
        let project = makeProject(id: projectID)
        return SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionHistoryReadStateStore: readStateStore,
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: []) }
        )
    }

    /// Claude 列表行没有 recencyAt，revision 为 0，完成版本只靠 updatedAt 比较。
    private func claudeSession(updatedAt seconds: TimeInterval, status: SessionStatus = .history) -> AgentSession {
        makeSession(
            id: sessionID, projectID: projectID, title: "旧会话", status: status.rawValue,
            source: "claude", runtimeProvider: "claude", resumeID: sessionID,
            updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func persistedState() throws -> SessionHistoryReadState {
        let states = readStateStore.load(
            profileID: appStore.notificationRoutingProfileID,
            legacyEndpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
        return try XCTUnwrap(states[sessionID])
    }

    func testBackdatedActivityAfterUpgradeKeepsReadAndLaterContinuationStillMarksUnread() throws {
        // 旧 bridge：桌面端续期把 mtime 改成 2000，列表首次见到时建立已读基线。
        let legacyStore = makeStore()
        legacyStore.sessions = [claudeSession(updatedAt: 2_000)]
        XCTAssertFalse(legacyStore.isHistorySessionUnread(claudeSession(updatedAt: 2_000)))

        // 升级到 SDK 适配器并重启：时间纠正回最后一条真实对话 1000。
        let upgradedStore = makeStore()
        let corrected = claudeSession(updatedAt: 1_000)
        upgradedStore.sessions = [corrected]
        XCTAssertFalse(upgradedStore.isHistorySessionUnread(corrected), "时间往回纠正不能产生一次性未读")
        XCTAssertEqual(try persistedState().latestCompletion?.updatedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(upgradedStore.historyCompletionObservedAtBySessionID[sessionID], "纠正时间不是刚完成")

        // 只 touch 或追加元数据：适配器给出的时间不变，仍是已读。
        upgradedStore.sessions = [claudeSession(updatedAt: 1_000)]
        XCTAssertFalse(upgradedStore.isHistorySessionUnread(corrected))

        // 水位已换成纠正后的时间：之后的真实续聊即使仍早于旧 mtime，也要标未读。
        let continued = claudeSession(updatedAt: 1_500)
        upgradedStore.sessions = [continued]
        XCTAssertTrue(upgradedStore.isHistorySessionUnread(continued), "纠正后的时间前移代表新对话")
    }

    func testForwardActivityStillMarksUnread() {
        let store = makeStore()
        store.sessions = [claudeSession(updatedAt: 1_000)]
        XCTAssertFalse(store.isHistorySessionUnread(claudeSession(updatedAt: 1_000)))

        let forward = claudeSession(updatedAt: 1_200)
        store.sessions = [forward]
        XCTAssertTrue(store.isHistorySessionUnread(forward))
    }

    func testObservedCompletionWithEarlierTimeStillMarksUnread() {
        let store = makeStore()
        store.sessions = [claudeSession(updatedAt: 2_000)]

        // 观察到一轮真实运行；即使完成时间早于被污染的旧水位，也是新结果。
        store.sessions = [claudeSession(updatedAt: 2_000, status: .running)]
        let completed = claudeSession(updatedAt: 1_500)
        store.sessions = [completed]
        XCTAssertTrue(store.isHistorySessionUnread(completed))
        XCTAssertNotNil(store.historyCompletionObservedAtBySessionID[sessionID])
    }

    func testManualUnreadSurvivesBackdatedActivity() throws {
        let legacyStore = makeStore()
        legacyStore.sessions = [claudeSession(updatedAt: 2_000)]
        legacyStore.markHistorySessionUnread(sessionID)
        XCTAssertTrue(legacyStore.isHistorySessionUnread(claudeSession(updatedAt: 2_000)))

        let upgradedStore = makeStore()
        let corrected = claudeSession(updatedAt: 1_000)
        upgradedStore.sessions = [corrected]
        XCTAssertTrue(upgradedStore.isHistorySessionUnread(corrected), "手动标为未读不能被时间纠正清掉")
        let state = try persistedState()
        XCTAssertEqual(state.manualUnreadCompletion?.updatedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(state.readCompletion)

        // 选中会话的普通同步也不能覆盖手动未读；显式标为已读后恢复。
        upgradedStore.selectedSessionID = sessionID
        upgradedStore.synchronizeHistoryReadStates()
        XCTAssertTrue(upgradedStore.isHistorySessionUnread(corrected))
        upgradedStore.markHistorySessionRead(sessionID)
        XCTAssertFalse(upgradedStore.isHistorySessionUnread(corrected))
    }

    func testBackdatedActivityComparesWithReadWatermark() {
        // 旧 bridge 下已读停在 mtime 1000（最后一条真实对话是 900），桌面端续期又把 mtime 改成 2000，误标未读。
        let store = makeStore()
        store.sessions = [claudeSession(updatedAt: 1_000)]
        store.sessions = [claudeSession(updatedAt: 2_000)]
        XCTAssertTrue(store.isHistorySessionUnread(claudeSession(updatedAt: 2_000)))

        // 纠正回 900：不晚于已读水位，说明没有用户没看过的内容。
        let corrected = claudeSession(updatedAt: 900)
        store.sessions = [corrected]
        XCTAssertFalse(store.isHistorySessionUnread(corrected), "升级前被 mtime 污染出的未读应随纠正消失")

        // 已读水位停在 900 后有一轮真实对话 1500，随后 mtime 又被改成 2500；纠正回 1500 仍是未读。
        store.sessions = [claudeSession(updatedAt: 1_500)]
        store.sessions = [claudeSession(updatedAt: 2_500)]
        let stillNew = claudeSession(updatedAt: 1_500)
        store.sessions = [stillNew]
        XCTAssertTrue(store.isHistorySessionUnread(stillNew), "晚于已读水位的真实对话不能被纠正吞掉")
    }

    func testNoNewActivityFollowsCompletionSignalPriority() {
        func version(
            turnID: TurnID? = nil, updatedAt: TimeInterval, recencyAt: TimeInterval? = nil,
            revision: ModelRevision? = nil
        ) -> SessionCompletionVersion {
            let session = AgentSession(
                id: sessionID, projectID: projectID, project: projectID, dir: "/tmp", title: "t",
                status: SessionStatus.history.rawValue, source: "codex", resumeID: sessionID,
                createdAt: nil, updatedAt: Date(timeIntervalSince1970: updatedAt),
                recencyAt: recencyAt.map { Date(timeIntervalSince1970: $0) },
                revision: revision
            )
            return SessionCompletionVersion(session: session, completedTurnID: turnID)
        }

        XCTAssertTrue(version(updatedAt: 10).hasNoNewActivity(since: version(updatedAt: 20)))
        XCTAssertFalse(version(updatedAt: 30).hasNoNewActivity(since: version(updatedAt: 20)))
        XCTAssertFalse(
            version(turnID: "turn-new", updatedAt: 10).hasNoNewActivity(since: version(updatedAt: 20)),
            "观察到的新 turn 总是新结果"
        )
        XCTAssertTrue(
            version(updatedAt: 90, recencyAt: 10).hasNoNewActivity(since: version(updatedAt: 20, recencyAt: 20)),
            "共有 recencyAt 时只按 recencyAt 判断，updatedAt 前移不算新活动"
        )
        XCTAssertFalse(
            version(updatedAt: 10, recencyAt: 10, revision: 3)
                .hasNoNewActivity(since: version(updatedAt: 20, recencyAt: 20, revision: 2)),
            "序号推进说明有新内容"
        )
        XCTAssertFalse(
            version(updatedAt: 10, revision: 1).hasNoNewActivity(since: version(updatedAt: 20, revision: 2)),
            "共有序号且没有 recencyAt 时由序号决定，不按时间判断"
        )
    }
}
