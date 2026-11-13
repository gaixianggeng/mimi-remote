import XCTest
import Combine
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testFailedLibraryRefreshDoesNotStartThrottleWindow() async {
        let workspace = AgentWorkspace(project: makeProject(id: "failed-library"))
        let client = MockSessionStoreClient(
            projects: [workspace.project], sessions: [],
            workspaceSessionsError: [workspace.id: MockError.unimplemented],
            controlledGlobalSessionsByRuntimeHandler: { _, _, _ in throw MockError.unimplemented }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { client }
        )
        store.recentWorkspaces = [workspace]

        await store.refreshSessionLibraryIndex()

        XCTAssertNil(store.lastSessionLibraryIndexRefreshAt)
        let initialRequests = client.requestedControlledGlobalRuntimes.count
        await store.refreshSessionLibraryIndexIfStale()
        XCTAssertEqual(client.requestedControlledGlobalRuntimes.count, initialRequests * 2)
    }

    func testSuccessfulLibraryRefreshStartsThrottleWindow() async {
        let workspace = AgentWorkspace(project: makeProject(id: "successful-library"))
        let client = MockSessionStoreClient(
            projects: [workspace.project], sessions: [],
            controlledGlobalSessionsByRuntimeHandler: { _, _, _ in throw MockError.unimplemented }
        )
        var now = Date(timeIntervalSince1970: 100)
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { client }, sessionListNow: { now }
        )
        store.recentWorkspaces = [workspace]

        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(store.lastSessionLibraryIndexRefreshAt, now)
        let requests = client.requestedWorkspaceIDs
        let globalRequests = client.requestedControlledGlobalRuntimes
        now = now.addingTimeInterval(29)
        await store.refreshSessionLibraryIndexIfStale()
        XCTAssertEqual(client.requestedWorkspaceIDs, requests)
        XCTAssertEqual(client.requestedControlledGlobalRuntimes, globalRequests)
    }

    func testRefreshAllKicksSessionLibraryIndexAfterHostResponds() async {
        let workspace = AgentWorkspace(project: makeProject(id: "host-responded"))
        let client = MockSessionStoreClient(projects: [workspace.project], sessions: [])
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        // 没有选中工作区的提前返回也必须触发补查。
        await store.refreshAll()
        for _ in 0..<100 where client.requestedWorkspaceIDs.isEmpty { await Task.yield() }
        if let job = store.sessionLibraryIndexRefreshJob { await job.task.value }

        XCTAssertEqual(client.requestedWorkspaceIDs, [workspace.id])
    }

    func testEveryWorkspaceDirectoryLoadsBeforeGlobalDiscovery() async {
        let workspaces = ["one", "two", "three"].map { AgentWorkspace(project: makeProject(id: $0)) }
        let expectedIDs = [workspaces[1], workspaces[0], workspaces[2]].flatMap { [$0.id, $0.id] }
        var client: MockSessionStoreClient!
        client = MockSessionStoreClient(
            projects: workspaces.map(\.project), sessions: [],
            runtimeChannelAvailability: ["codex": true, "claude": true],
            controlledGlobalSessionsByRuntimeHandler: { _, _, _ in
                XCTAssertEqual(client.requestedWorkspaceIDs, expectedIDs,
                               "全部目录首屏必须早于任一全局发现请求")
                XCTAssertEqual(client.requestedWorkspaceRuntimes, ["claude", "codex", "codex", "claude", "codex", "claude"])
                return SessionsPage(sessions: [])
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { client }
        )
        store.recentWorkspaces = workspaces
        store.sessionLibraryPriorityScope = store.workspaceDirectoryScopeKey(for: workspaces[1], runtimeProvider: "claude")

        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(client.requestedWorkspaceIDs, expectedIDs, "顺序前移不能增加目录请求")
        XCTAssertEqual(client.requestedControlledGlobalRuntimes, RuntimeFeatureSupport.runtimeProviders)
    }

    func testDirectoryResultFromNonPriorityWorkspaceSurvivesGlobalPruning() async {
        let priority = AgentWorkspace(project: makeProject(id: "pruning-priority"))
        let other = AgentWorkspace(project: makeProject(id: "pruning-other"))
        let fresh = makeSession(id: "other-fresh", projectID: other.id, title: "仍存在", status: "history", source: "claude")
        let deleted = makeSession(id: "other-deleted", projectID: other.id, title: "已删除", status: "history", source: "claude")
        let client = MockSessionStoreClient(
            projects: [priority.project, other.project], sessions: [],
            workspacePages: [other.id: SessionsPage(sessions: [fresh])],
            runtimeChannelAvailability: ["codex": true, "claude": true],
            controlledGlobalSessionsHandler: { _, _ in SessionsPage(sessions: []) }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { client }
        )
        store.recentWorkspaces = [priority, other]
        store.sessions = [fresh, deleted]
        store.controlledGlobalSessionIDs = [fresh.id, deleted.id]
        store.sessionLibraryPriorityScope = store.workspaceDirectoryScopeKey(for: priority, runtimeProvider: "codex")

        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(store.openedWorkspaceSessionLibrarySessions.map(\.id), [fresh.id])
        XCTAssertFalse(store.sessions.contains { $0.id == deleted.id })
        XCTAssertTrue(store.controlledGlobalSessionIDs.isEmpty)
        XCTAssertEqual(client.requestedWorkspaceIDs, [priority.id, priority.id, other.id, other.id])
    }

    func testBrowsedWorkspaceAndRuntimeLoadBeforeGlobalDiscoveryWithoutExtraRequests() async {
        let first = AgentWorkspace(project: makeProject(id: "priority-first"))
        let browsed = AgentWorkspace(project: makeProject(id: "priority-browsed"))
        var client: MockSessionStoreClient!
        client = MockSessionStoreClient(
            projects: [first.project, browsed.project], sessions: [],
            runtimeChannelAvailability: ["codex": true, "claude": true],
            controlledGlobalSessionsByRuntimeHandler: { _, _, _ in
                XCTAssertEqual(client.requestedWorkspaceIDs, [browsed.id, browsed.id, first.id, first.id],
                               "先确认当前浏览工作区的归属，不能等全局扫描结束")
                XCTAssertEqual(client.requestedWorkspaceRuntimes.first, "claude",
                               "当前渠道不能排在其他渠道之后")
                return SessionsPage(sessions: [])
            }
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [first, browsed], endpoint: appStore.endpoint),
            clientFactory: { client }
        )
        store.reloadRecentWorkspaces()
        store.recentWorkspaces = [first, browsed]
        store.selectedProjectID = first.id
        store.sessionLibraryPriorityScope = store.workspaceDirectoryScopeKey(for: browsed, runtimeProvider: "claude")

        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(client.requestedWorkspaceIDs, [browsed.id, browsed.id, first.id, first.id])
        XCTAssertEqual(client.requestedWorkspaceRuntimes, ["claude", "codex", "codex", "claude"])
        XCTAssertEqual(client.requestedControlledGlobalRuntimes.count, RuntimeFeatureSupport.runtimeProviders.count)
    }

    func testPrioritizedDirectoryResultSurvivesGlobalPruningButDeletedRowsDoNot() async {
        let project = makeProject(id: "priority-retained")
        let workspace = AgentWorkspace(project: project)
        let fresh = makeSession(id: "priority-fresh", projectID: project.id, title: "仍在目录中的会话", status: "history", source: "codex")
        let deleted = makeSession(id: "priority-deleted", projectID: project.id, title: "已删除会话", status: "history", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project], sessions: [], workspacePages: [workspace.id: SessionsPage(sessions: [fresh])],
            controlledGlobalSessionsHandler: { _, _ in SessionsPage(sessions: []) }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { client }
        )
        store.recentWorkspaces = [workspace]
        store.sessions = [fresh, deleted]
        store.controlledGlobalSessionIDs = [fresh.id, deleted.id]
        store.sessionLibraryPriorityScope = store.workspaceDirectoryScopeKey(for: workspace, runtimeProvider: "codex")

        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(store.directoryScopedSessions(workspaceID: workspace.id, runtimeProvider: "codex").map(\.id), [fresh.id],
                       "提前查询的精确目录仍应可见；全局撤权仍应清理已删除行")
        XCTAssertTrue(store.controlledGlobalSessionIDs.isEmpty, "精确目录不能伪装成全局发现证据")
        XCTAssertEqual(client.requestedWorkspaceIDs, [workspace.id], "不能靠重复查询恢复刚拿到的目录内容")
    }

    func testSelectedWorkspaceCachedCodexDoesNotSuppressBrowsedClaude() async {
        let project = makeProject(id: "priority-missing-runtime")
        let workspace = AgentWorkspace(project: project)
        var client: MockSessionStoreClient!
        client = MockSessionStoreClient(
            projects: [project], sessions: [],
            runtimeChannelAvailability: ["codex": true, "claude": true],
            controlledGlobalSessionsByRuntimeHandler: { _, _, _ in
                XCTAssertEqual(client.requestedWorkspaceRuntimes, ["claude"], "已有 Codex 不能挡住缺失的 Claude")
                return SessionsPage(sessions: [])
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { client }
        )
        store.recentWorkspaces = [workspace]
        store.selectedProjectID = workspace.id
        store.sessions = [makeSession(id: "cached-codex", projectID: project.id, title: "已有会话", status: "history", source: "codex")]
        store.sessionLibraryPriorityScope = store.workspaceDirectoryScopeKey(for: workspace, runtimeProvider: "claude")

        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(client.requestedWorkspaceRuntimes, ["claude"], "只补缺失渠道，不重复请求已有 Codex")
    }

    func testGlobalLibraryPublishesAllRuntimeFirstPagesBeforeBackfill() async {
        let project = makeProject(id: "startup")
        let runtimes = RuntimeFeatureSupport.runtimeProviders
        let firstPageIDs = Set(runtimes.map { "\($0)-0" })
        var calls: [String] = []
        var store: SessionStore!
        let client = MockSessionStoreClient(
            projects: [project], sessions: [],
            controlledGlobalSessionsByRuntimeHandler: { runtime, cursor, _ in
                let pageIndex = Int(cursor ?? "0")!
                calls.append("\(runtime)-\(pageIndex)")
                if pageIndex > 0 {
                    XCTAssertTrue(firstPageIDs.isSubset(of: Set(store.sessions.map(\.id))),
                                  "后续页开始前，所有渠道的首屏都必须已经可见")
                    XCTAssertTrue(firstPageIDs.isSubset(of: store.controlledGlobalSessionIDs))
                }
                // 固定每页延迟供本机重复度量；验收依赖请求/发布边界，不依赖机器快慢。
                try await Task.sleep(nanoseconds: 20_000_000)
                let session = makeSession(
                    id: "\(runtime)-\(pageIndex)", projectID: project.id,
                    title: runtime, status: "history", source: runtime
                )
                return SessionsPage(sessions: [session], nextCursor: "\(pageIndex + 1)", hasMore: true)
            }
        )
        store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(),
            logStore: LogStore(), clientFactory: { client }
        )
        var snapshots: [Set<SessionID>] = []
        var requestsAtFirstPublish: Int?
        let start = ProcessInfo.processInfo.systemUptime
        var firstVisibleAt: TimeInterval?
        let observation = store.$sessions.dropFirst().sink { sessions in
            guard !sessions.isEmpty else { return }
            snapshots.append(Set(sessions.map(\.id)))
            if firstVisibleAt == nil {
                firstVisibleAt = ProcessInfo.processInfo.systemUptime - start
                requestsAtFirstPublish = calls.count
            }
        }

        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(Array(calls.prefix(runtimes.count)), runtimes.map { "\($0)-0" })
        XCTAssertEqual(requestsAtFirstPublish, runtimes.count)
        XCTAssertEqual(calls.count, runtimes.count * 4, "每个渠道仍最多四页")
        XCTAssertEqual(snapshots.first, firstPageIDs)
        XCTAssertEqual(snapshots.count, 2, "首屏与补全各发布一次，不能每页都重算列表")
        XCTAssertEqual(store.sessions.count, runtimes.count * 4)
        print("Session library fixture: first visible=\(firstVisibleAt ?? -1)s, total=\(ProcessInfo.processInfo.systemUptime - start)s, requests before first visible=\(requestsAtFirstPublish ?? -1)")
        withExtendedLifetime(observation) {}
    }

    func testGlobalLibraryFirstPageFailureDoesNotBlockOtherRuntimeFirstPages() async {
        let project = makeProject(id: "startup_partial")
        var store: SessionStore!
        var requests: [String] = []
        let client = MockSessionStoreClient(
            projects: [project], sessions: [],
            controlledGlobalSessionsByRuntimeHandler: { runtime, cursor, _ in
                requests.append(runtime)
                if runtime == "codex" { throw MockError.unimplemented }
                if cursor != nil {
                    XCTAssertEqual(Set(store.sessions.map(\.source)), ["claude", "deepseek"])
                    return SessionsPage(sessions: [])
                }
                return SessionsPage(sessions: [makeSession(
                    id: "\(runtime)-first", projectID: project.id,
                    title: runtime, status: "history", source: runtime
                )], nextCursor: "more", hasMore: true)
            }
        )
        store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(),
            logStore: LogStore(), clientFactory: { client }
        )

        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(requests, ["codex", "claude", "deepseek", "claude", "deepseek"])
        XCTAssertEqual(Set(store.sessions.map(\.source)), ["claude", "deepseek"])
    }
}
