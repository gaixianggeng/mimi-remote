import XCTest
@testable import MimiRemote

/// #790：回前台时当前会话的恢复历史不再排在工作区列表刷新之后。列表只请求首选 Runtime
/// （Codex），它慢或失败时，Claude 会话的历史仍要按自身耗时落地；线程状态校准则仍排在
/// 列表落地之后，晚到的列表快照不能盖掉状态点读。
@MainActor
final class ForegroundRecoveryHistoryOrderingTests: XCTestCase {
    func testRecoveryHistoryLandsWhileCodexListIsStillPending() async {
        let fixture = makeFixture(status: SessionStatus.idle.rawValue)
        let client = fixture.client
        let store = fixture.store
        await enterBackgroundWithSelectedSession(fixture)
        client.historyPage = recoveredHistoryPage()
        client.listBehavior = .blocked
        let completedListsBeforeResume = client.completedListCount

        let resumeTask = Task { await store.resumeFromForeground() }
        await waitUntil("工作区列表进入阻塞") { client.blockedListCount == 1 }
        await waitUntil("恢复历史在列表返回前落地") { self.hasRecoveredAnswer(store, fixture.session.id) }

        XCTAssertEqual(client.historyRequestCount, 2, "选中时一次，回前台恢复一次")
        XCTAssertEqual(client.completedListCount, completedListsBeforeResume, "此时列表仍未返回")
        XCTAssertEqual(client.listRuntimeProviders.last, "codex", "列表只请求首选 Runtime，与 Claude 历史无关")

        client.releaseBlockedLists(with: fixture.listPage)
        await resumeTask.value

        XCTAssertEqual(store.connectedSessionID, fixture.session.id)
        XCTAssertEqual(
            fixture.socket.replayBufferedEventsByConnect.last,
            false,
            "完整历史已对账，重连只做状态回放"
        )
    }

    func testRecoveryHistoryLandsWhileCodexListKeepsFailing() async {
        let gate = SessionListSleepGate()
        let fixture = makeFixture(status: SessionStatus.idle.rawValue, sessionListSleep: { _ in await gate.wait() })
        let client = fixture.client
        let store = fixture.store
        await enterBackgroundWithSelectedSession(fixture)
        client.historyPage = recoveredHistoryPage()
        client.listBehavior = .failing

        let resumeTask = Task { await store.resumeFromForeground() }
        await waitUntil("列表失败后进入退避") { gate.waiterCount == 1 }
        await waitUntil("列表失败期间恢复历史照常落地") { self.hasRecoveredAnswer(store, fixture.session.id) }
        XCTAssertEqual(client.historyRequestCount, 2)
        XCTAssertGreaterThanOrEqual(client.listFailureCount, 1)
        let connectCountBeforeListRecovers = fixture.socket.connectedSessionIDs.count

        client.listBehavior = .immediate
        gate.releaseAll()
        await resumeTask.value

        XCTAssertEqual(fixture.socket.connectedSessionIDs.count, connectCountBeforeListRecovers + 1)
        XCTAssertEqual(store.connectedSessionID, fixture.session.id)
        XCTAssertEqual(fixture.socket.replayBufferedEventsByConnect.last, false)
    }

    /// 列表请求早于状态点读发出。若让点读先落地，晚到的 running 快照会把会话拉回执行中；
    /// 这里的点读状态是 idle（不是 completed），没有本地终态保护兜底，只能靠先后顺序。
    func testStateReadAppliesAfterLateStaleListSnapshot() async {
        let fixture = makeFixture(status: SessionStatus.running.rawValue)
        let client = fixture.client
        let store = fixture.store
        await enterBackgroundWithSelectedSession(fixture)
        var idle = fixture.session
        idle.status = SessionStatus.idle.rawValue
        client.pointReadSession = idle
        client.historyPage = recoveredHistoryPage()
        client.listBehavior = .blocked
        let pointReadsBeforeResume = client.pointReadCount

        let resumeTask = Task { await store.resumeFromForeground() }
        await waitUntil("工作区列表进入阻塞") { client.blockedListCount == 1 }
        await waitUntil("恢复历史先落地") { self.hasRecoveredAnswer(store, fixture.session.id) }
        XCTAssertEqual(client.pointReadCount, pointReadsBeforeResume, "状态点读要等列表落地后再发")

        // 列表快照仍是离开前的 running。
        client.releaseBlockedLists(with: fixture.listPage)
        await resumeTask.value

        XCTAssertEqual(client.pointReadCount, pointReadsBeforeResume + 1)
        XCTAssertEqual(store.sessionsByID[fixture.session.id]?.status, SessionStatus.idle.rawValue)
        XCTAssertEqual(store.sessionsByID[fixture.session.id]?.isRunning, false)
    }

    /// 列表带回更新的签名时，刷新流程会为选中会话补拉历史；恢复 job 仍在途就加入它，
    /// 不再另发一次完整历史。
    func testListWithNewerSnapshotJoinsInFlightRecoveryHistory() async {
        let fixture = makeFixture(status: SessionStatus.idle.rawValue)
        let client = fixture.client
        let store = fixture.store
        await enterBackgroundWithSelectedSession(fixture)
        var advanced = fixture.session
        advanced.updatedAt = Date(timeIntervalSince1970: 40)
        client.listPage = SessionsPage(sessions: [advanced])
        client.historyPage = recoveredHistoryPage()
        client.blocksHistory = true
        let completedListsBeforeResume = client.completedListCount

        let resumeTask = Task { await store.resumeFromForeground() }
        await waitUntil("恢复历史已发出") { client.blockedHistoryCount == 1 }
        // 客户端返回列表不等于 Store 已应用。恢复 job 是 quiet 的，只有刷新流程应用列表后
        // 为选中会话补拉并加入它时才会升级为前台反馈；等这一步，再放行历史。
        await waitUntil("列表已落地并加入在途恢复历史") {
            store.historyLoadJobsBySessionID[fixture.session.id]?.requiresForegroundReporting == true
        }
        XCTAssertGreaterThan(client.completedListCount, completedListsBeforeResume)
        XCTAssertEqual(store.sessionsByID[fixture.session.id]?.updatedAt, advanced.updatedAt)
        client.releaseBlockedHistory()
        await resumeTask.value

        XCTAssertTrue(hasRecoveredAnswer(store, fixture.session.id))
        XCTAssertEqual(client.historyRequestCount, 2, "选中时一次，恢复一次；列表补拉加入在途 job")
        XCTAssertEqual(fixture.socket.replayBufferedEventsByConnect.last, false)
    }

    /// 评审 #815：列表刷新期间又回后台时，并行发出的恢复历史要随前台恢复一起撤掉，
    /// 迟到的响应不能在后台落地页面。
    func testBackgroundDuringListRefreshCancelsParallelRecoveryHistory() async {
        let fixture = makeFixture(status: SessionStatus.idle.rawValue)
        let client = fixture.client
        let store = fixture.store
        await enterBackgroundWithSelectedSession(fixture)
        client.historyPage = recoveredHistoryPage()
        client.blocksHistory = true
        client.listBehavior = .blocked
        let connectsBeforeResume = fixture.socket.connectedSessionIDs.count

        let resumeTask = Task { await store.resumeFromForeground() }
        await waitUntil("工作区列表进入阻塞") { client.blockedListCount == 1 }
        await waitUntil("恢复历史已发出") { client.blockedHistoryCount == 1 }
        // 与 RootView 回后台一致：先取消前台恢复任务，再挂起 Store。
        resumeTask.cancel()
        store.suspendForBackground()
        client.releaseBlockedLists(with: fixture.listPage)
        await resumeTask.value

        XCTAssertNil(store.historyLoadJobsBySessionID[fixture.session.id], "提前退出时撤掉本代恢复历史")
        client.releaseBlockedHistory()
        await waitUntil("迟到的历史响应已返回") {
            store.historyFirstPageCacheByKey.keys.contains { $0.sessionID == fixture.session.id }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(hasRecoveredAnswer(store, fixture.session.id), "后台不落地迟到的恢复历史")
        XCTAssertTrue(store.isAppInBackground)
        XCTAssertNil(store.connectedSessionID)
        XCTAssertEqual(fixture.socket.connectedSessionIDs.count, connectsBeforeResume)
    }

    // MARK: - Fixture

    private struct Fixture {
        let session: AgentSession
        let listPage: SessionsPage
        let client: ForegroundRecoveryOrderingClient
        let socket: MockWebSocketClient
        let store: SessionStore
    }

    private func makeFixture(
        status: String,
        sessionListSleep: @escaping (UInt64) async -> Void = { _ in }
    ) -> Fixture {
        let project = makeProject(id: "proj_gh790_foreground")
        let session = makeSession(
            id: "claude_gh790_selected",
            projectID: project.id,
            title: "Claude 会话",
            status: status,
            source: "claude",
            runtimeProvider: "claude"
        )
        let listPage = SessionsPage(sessions: [session])
        let client = ForegroundRecoveryOrderingClient(projects: [project], listPage: listPage)
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let socket = MockWebSocketClient()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { socket },
            sessionListSleep: sessionListSleep
        )
        store.selectedProjectID = project.id
        return Fixture(session: session, listPage: listPage, client: client, socket: socket, store: store)
    }

    private func enterBackgroundWithSelectedSession(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await fixture.store.refreshAll(autoAttach: false)
        if fixture.session.isRunning {
            // 别的客户端在跑的会话只能旁观、不建连接；本机接管后才是回前台要重连的会话。
            fixture.store.takeOverSession(fixture.session)
        }
        await fixture.store.selectSession(fixture.session)
        XCTAssertEqual(fixture.client.historyRequestCount, 1, file: file, line: line)
        XCTAssertEqual(fixture.store.connectedSessionID, fixture.session.id, file: file, line: line)
        fixture.store.suspendForBackground()
    }

    private func recoveredHistoryPage() -> HistoryMessagesPage {
        HistoryMessagesPage(messages: [
            CodexHistoryMessage(
                id: "rollout:recovered",
                role: "assistant",
                content: "后台期间完成的回答",
                createdAt: Date(timeIntervalSince1970: 30)
            )
        ])
    }

    private func hasRecoveredAnswer(_ store: SessionStore, _ sessionID: SessionID) -> Bool {
        store.conversationStore.messages(for: sessionID).contains { $0.content == "后台期间完成的回答" }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待超时：\(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// 列表可立即返回、挂起或失败，历史可立即返回或挂起；记录请求次数，观察回前台时的先后。
@MainActor
private final class ForegroundRecoveryOrderingClient: SessionStoreAPIClient {
    enum ListBehavior {
        case immediate
        case blocked
        case failing
    }

    let projectsResult: [AgentProject]
    var listPage: SessionsPage
    var listBehavior: ListBehavior = .immediate
    var historyPage = HistoryMessagesPage(messages: [
        CodexHistoryMessage(id: "rollout:initial", role: "assistant", content: "离开前的回答", createdAt: Date(timeIntervalSince1970: 10))
    ])
    var blocksHistory = false
    var pointReadSession: AgentSession?
    private(set) var completedListCount = 0
    private(set) var listFailureCount = 0
    private(set) var listRuntimeProviders: [String] = []
    private(set) var historyRequestCount = 0
    private(set) var pointReadCount = 0
    private var blockedLists: [CheckedContinuation<SessionsPage, Error>] = []
    private var blockedHistory: [CheckedContinuation<Void, Never>] = []

    var blockedListCount: Int { blockedLists.count }
    var blockedHistoryCount: Int { blockedHistory.count }

    init(projects: [AgentProject], listPage: SessionsPage) {
        self.projectsResult = projects
        self.listPage = listPage
    }

    func releaseBlockedLists(with page: SessionsPage) {
        let continuations = blockedLists
        blockedLists = []
        completedListCount += continuations.count
        continuations.forEach { $0.resume(returning: page) }
    }

    func releaseBlockedHistory() {
        blocksHistory = false
        let continuations = blockedHistory
        blockedHistory = []
        continuations.forEach { $0.resume() }
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        listPage.sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        listPage
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        runtimeProvider: String,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        listRuntimeProviders.append(runtimeProvider)
        switch listBehavior {
        case .immediate:
            completedListCount += 1
            return listPage
        case .failing:
            listFailureCount += 1
            throw AgentAPIError.server(status: 503, message: "thread/list unavailable")
        case .blocked:
            return try await withCheckedThrowingContinuation { blockedLists.append($0) }
        }
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        pointReadCount += 1
        guard let pointReadSession, pointReadSession.id == id else {
            throw MockError.unimplemented
        }
        return SessionResponse(session: pointReadSession)
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit).messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        historyRequestCount += 1
        if blocksHistory {
            await withCheckedContinuation { blockedHistory.append($0) }
        }
        return historyPage
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }
}

/// 让列表失败后的退避停住，测试决定何时进入下一轮。
@MainActor
private final class SessionListSleepGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { waiters.count }

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
