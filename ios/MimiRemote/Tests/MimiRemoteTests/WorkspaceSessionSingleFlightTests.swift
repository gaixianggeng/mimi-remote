import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testWorkspaceRuntimeCodexFirstPageWaitsForHostBootstrapFastRequest() async throws {
        let project = makeProject(id: "workspace_runtime_fast_then_foreground")
        let workspace = AgentWorkspace(
            project: project,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        let sparseSession = makeSession(
            id: "thread_runtime_fast",
            projectID: project.id,
            title: "快速索引结果",
            status: "history",
            source: "codex",
            runtimeProvider: "codex"
        )
        let authoritativeSession = makeSession(
            id: "thread_runtime_authoritative",
            projectID: project.id,
            title: "切换设备后首次可见",
            status: "history",
            source: "codex",
            runtimeProvider: "codex"
        )
        let client = WorkspaceRuntimeFastThenAuthoritativeClient(
            projects: [project],
            fastPage: SessionsPage(sessions: [sparseSession]),
            authoritativePage: SessionsPage(sessions: [authoritativeSession])
        )
        let appStore = makeIsolatedAppStore()
        let suiteName = "WorkspaceRuntimeSingleFlight.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let recentWorkspaceStore = RecentWorkspaceStore(defaults: defaults)
        recentWorkspaceStore.save(
            [workspace],
            profileID: appStore.notificationRoutingProfileID
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: recentWorkspaceStore,
            clientFactory: { client }
        )

        let connectionRefresh = Task { @MainActor in
            await store.refreshAll(autoAttach: true)
        }
        await client.waitForBlockedFastRequest()
        var workspaceForegroundStarted = false
        let workspaceForeground = Task { @MainActor in
            workspaceForegroundStarted = true
            return try await store.workspaceRuntimeSessionsPage(
                projectID: project.id,
                runtimeProvider: "codex",
                cursor: nil,
                limit: SessionStore.initialSessionPageLimit
            )
        }
        while !workspaceForegroundStarted {
            await Task.yield()
        }

        var snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.callCount, 1, "fastIndexed 未结束前不能并发启动前台 thread/list")
        XCTAssertEqual(snapshot.maximumConcurrentRequestCount, 1)

        await client.releaseFastRequest()
        let page = try await workspaceForeground.value
        await connectionRefresh.value

        snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.callCount, 2)
        XCTAssertEqual(snapshot.consistencies, [.fastIndexed, .authoritative])
        XCTAssertEqual(snapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(page.sessions.map(\.id), [authoritativeSession.id])
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertTrue(store.sessionListFirstPageInFlightByKey.isEmpty)
    }

    func testWorkspaceRuntimeCodexFirstPageCommitsAuthoritativeContinuation() async throws {
        let project = makeProject(id: "workspace_runtime_continuation")
        let seed = makeSession(
            id: "thread_runtime_seed",
            projectID: project.id,
            title: "已扫描会话",
            status: "history",
            source: "codex",
            runtimeProvider: "codex"
        )
        let continued = makeSession(
            id: "thread_runtime_continued",
            projectID: project.id,
            title: "续页会话",
            status: "history",
            source: "codex",
            runtimeProvider: "codex"
        )
        let retainedClaude = makeSession(
            id: "thread_runtime_retained_claude",
            projectID: project.id,
            title: "已缓存 Claude 会话",
            status: "history",
            source: "claude",
            runtimeProvider: "claude"
        )
        let retainedOlderCodex = makeSession(
            id: "thread_runtime_retained_older_codex",
            projectID: project.id,
            title: "已加载旧分页",
            status: "history",
            source: "codex",
            runtimeProvider: "codex"
        )
        let client = WorkspaceRuntimeContinuationClient(
            projects: [project],
            page: SessionsPage(sessions: [continued])
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.sessions = [seed, retainedClaude, retainedOlderCodex]
        let workspace = try XCTUnwrap(store.workspacesByID[project.id])
        let completionKey = store.workspaceSessionFirstPageKey(for: workspace)
        store.workspaceSessionFirstPageCompletionByKey[completionKey] = WorkspaceSessionFirstPageCompletion(
            consistency: .authoritative,
            isPresentationWindowComplete: false,
            continuationCursor: "runtime-continuation",
            scannedSessionIDs: [seed.id],
            completedAt: Date(timeIntervalSince1970: 10)
        )

        let page = try await store.workspaceRuntimeSessionsPage(
            projectID: project.id,
            runtimeProvider: "codex",
            cursor: nil,
            limit: SessionStore.initialSessionPageLimit
        )

        let requestedCursors = await client.requestedCursors()
        XCTAssertEqual(requestedCursors, ["runtime-continuation"])
        XCTAssertEqual(Set(page.sessions.map(\.id)), Set([seed.id, continued.id]))
        XCTAssertEqual(
            Set(store.sessions.map(\.id)),
            Set([seed.id, continued.id, retainedClaude.id, retainedOlderCodex.id]),
            "Runtime 首屏提交 cursor 时不能删除其他 Runtime 或旧分页的 canonical sessions"
        )
        let completion = try XCTUnwrap(store.workspaceSessionFirstPageCompletionByKey[completionKey])
        XCTAssertEqual(completion.consistency, .authoritative)
        XCTAssertTrue(completion.isPresentationWindowComplete)
        XCTAssertNil(completion.continuationCursor)
        XCTAssertEqual(Set(completion.scannedSessionIDs), Set([seed.id, continued.id]))
    }
}

private struct WorkspaceRuntimeClientSnapshot: Sendable {
    let callCount: Int
    let consistencies: [SessionListConsistency]
    let maximumConcurrentRequestCount: Int
}

private actor WorkspaceRuntimeFastThenAuthoritativeState {
    let projects: [AgentProject]
    let fastPage: SessionsPage
    let authoritativePage: SessionsPage
    var callCount = 0
    var consistencies: [SessionListConsistency] = []
    var concurrentRequestCount = 0
    var maximumConcurrentRequestCount = 0
    var fastContinuation: CheckedContinuation<SessionsPage, Never>?
    var fastWaiters: [CheckedContinuation<Void, Never>] = []

    init(projects: [AgentProject], fastPage: SessionsPage, authoritativePage: SessionsPage) {
        self.projects = projects
        self.fastPage = fastPage
        self.authoritativePage = authoritativePage
    }

    func availableProjects() -> [AgentProject] { projects }
    func authoritativeSessions() -> [AgentSession] { authoritativePage.sessions }

    func sessionsPage(consistency: SessionListConsistency) async -> SessionsPage {
        callCount += 1
        consistencies.append(consistency)
        concurrentRequestCount += 1
        maximumConcurrentRequestCount = max(maximumConcurrentRequestCount, concurrentRequestCount)
        defer { concurrentRequestCount -= 1 }
        guard consistency == .fastIndexed else {
            return authoritativePage
        }
        return await withCheckedContinuation { continuation in
            fastContinuation = continuation
            let waiters = fastWaiters
            fastWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitForBlockedFastRequest() async {
        guard fastContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            guard fastContinuation == nil else {
                continuation.resume()
                return
            }
            fastWaiters.append(continuation)
        }
    }

    func releaseFastRequest() {
        fastContinuation?.resume(returning: fastPage)
        fastContinuation = nil
    }

    func snapshot() -> WorkspaceRuntimeClientSnapshot {
        WorkspaceRuntimeClientSnapshot(
            callCount: callCount,
            consistencies: consistencies,
            maximumConcurrentRequestCount: maximumConcurrentRequestCount
        )
    }
}

private final class WorkspaceRuntimeFastThenAuthoritativeClient: SessionStoreAPIClient {
    private let state: WorkspaceRuntimeFastThenAuthoritativeState

    init(projects: [AgentProject], fastPage: SessionsPage, authoritativePage: SessionsPage) {
        state = WorkspaceRuntimeFastThenAuthoritativeState(
            projects: projects,
            fastPage: fastPage,
            authoritativePage: authoritativePage
        )
    }

    func projects() async throws -> [AgentProject] { await state.availableProjects() }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        await state.authoritativeSessions()
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        await state.sessionsPage(consistency: consistency)
    }

    func waitForBlockedFastRequest() async { await state.waitForBlockedFastRequest() }
    func releaseFastRequest() async { await state.releaseFastRequest() }
    func snapshot() async -> WorkspaceRuntimeClientSnapshot { await state.snapshot() }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }
}

private actor WorkspaceRuntimeContinuationState {
    let projects: [AgentProject]
    let page: SessionsPage
    var cursors: [String?] = []

    init(projects: [AgentProject], page: SessionsPage) {
        self.projects = projects
        self.page = page
    }

    func availableProjects() -> [AgentProject] { projects }
    func availableSessions() -> [AgentSession] { page.sessions }

    func sessionsPage(cursor: String?) -> SessionsPage {
        cursors.append(cursor)
        return page
    }
}

private final class WorkspaceRuntimeContinuationClient: SessionStoreAPIClient {
    private let state: WorkspaceRuntimeContinuationState

    init(projects: [AgentProject], page: SessionsPage) {
        state = WorkspaceRuntimeContinuationState(projects: projects, page: page)
    }

    func projects() async throws -> [AgentProject] { await state.availableProjects() }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        await state.availableSessions()
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        await state.sessionsPage(cursor: cursor)
    }

    func requestedCursors() async -> [String?] { await state.cursors }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }
}
