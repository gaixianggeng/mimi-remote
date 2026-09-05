import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testManualWorkspaceRefreshRestartsAtHeadAndRestoresArchivedSession() async throws {
        let project = makeProject(id: "manual_refresh_head")
        let restored = makeSession(id: "restored_head", projectID: project.id, title: "最新会话", status: "history", source: "codex")
        let client = WorkspaceRuntimeContinuationClient(projects: [project], page: SessionsPage(sessions: [restored]))
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            sessionListPreferenceStore: makeSessionListPreferenceStore(), clientFactory: { client }
        )
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.archivedSessionIDs.insert(restored.id)
        let workspace = try XCTUnwrap(store.workspacesByID[project.id])
        store.workspaceSessionFirstPageCompletionByKey[store.workspaceSessionFirstPageKey(for: workspace)] = WorkspaceSessionFirstPageCompletion(
            consistency: .authoritative, isPresentationWindowComplete: false,
            continuationCursor: "old-continuation", scannedSessionIDs: [], completedAt: Date()
        )

        let page = try await store.workspaceRuntimeSessionsPage(
            projectID: project.id, runtimeProvider: "codex", cursor: nil, limit: 20, refreshFromStart: true
        )

        let cursors = await client.requestedCursors()
        XCTAssertEqual(cursors.count, 1)
        XCTAssertNil(cursors.first!)
        XCTAssertEqual(page.sessions.map(\.id), [restored.id])
        XCTAssertFalse(store.isSessionArchived(restored.id))
    }

    func testManualWorkspaceRefreshDoesNotReturnPreGestureRequest() async throws {
        let project = makeProject(id: "manual_refresh_existing")
        let old = makeSession(id: "before_gesture", projectID: project.id, title: "旧会话", status: "history", source: "codex")
        let newest = makeSession(id: "after_gesture", projectID: project.id, title: "新会话", status: "history", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [], workspaceSessions: [project.id: [newest]])
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(), clientFactory: { client })
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        let workspace = try XCTUnwrap(store.workspacesByID[project.id])
        let scope = appStore.activeHostScope
        let key = SessionListFirstPageRequestKey(
            profileID: scope.profileID, connectionGeneration: Int(truncatingIfNeeded: scope.generation),
            workspaceID: workspace.id, workspacePath: workspace.path, limit: 20, consistency: .authoritative, cursor: nil
        )
        var pending: CheckedContinuation<SessionsPage, Error>?
        let previous = Task<SessionsPage, Error> { try await withCheckedThrowingContinuation { pending = $0 } }
        while pending == nil { await Task.yield() }
        store.sessionListFirstPageInFlightByKey[key] = SessionListFirstPageInFlight(id: UUID(), task: previous)
        var started = false
        let refresh = Task { @MainActor in
            started = true
            return try await store.workspaceRuntimeSessionsPage(
                projectID: project.id, runtimeProvider: "codex", cursor: nil, limit: 20, refreshFromStart: true
            )
        }
        while !started { await Task.yield() }
        XCTAssertTrue(client.requestedWorkspaceIDs.isEmpty, "旧 RPC 收尾前不能并发发送同目录请求")
        pending?.resume(returning: SessionsPage(sessions: [old]))
        pending = nil
        let page = try await refresh.value
        XCTAssertEqual(client.requestedWorkspaceIDs, [workspace.id])
        XCTAssertEqual(page.sessions.map(\.id), [newest.id])
        XCTAssertTrue(store.sessionListFirstPageInFlightByKey.isEmpty)
    }

    func testLiveWorkspaceRuntimeCodexFirstAndSecondPageTiming() async throws {
        let configURL = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ).appendingPathComponent("mimi-live-workspace-session.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("未提供 Simulator 私有 live 配置")
        }

        let configData = try Data(contentsOf: configURL)
        // 凭据只为这一次明确执行的 live selector 服务，读取后立即删除磁盘副本。
        try? FileManager.default.removeItem(at: configURL)
        let config = try JSONDecoder().decode(LiveWorkspaceSessionConfig.self, from: configData)
        XCTAssertFalse(config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(config.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(config.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let suiteName = "WorkspaceRuntimeLive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(config.endpoint, forKey: "agentd.endpoint")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false
        )
        appStore.token = config.token
        let client = try appStore.makeSessionStoreAPIClient()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        let clock = ContinuousClock()

        let resolveStartedAt = clock.now
        let workspace = try await client.resolveWorkspace(path: config.workspacePath)
        let resolveDuration = resolveStartedAt.duration(to: clock.now)
        store.projects = [workspace.project]
        store.recentWorkspaces = [workspace]

        let firstStartedAt = clock.now
        let firstPage = try await store.workspaceRuntimeSessionsPage(
            projectID: workspace.id,
            runtimeProvider: "codex",
            cursor: nil,
            limit: SessionStore.initialSessionPageLimit
        )
        let firstDuration = firstStartedAt.duration(to: clock.now)

        let secondStartedAt = clock.now
        let secondPage = try await store.workspaceRuntimeSessionsPage(
            projectID: workspace.id,
            runtimeProvider: "codex",
            cursor: nil,
            limit: SessionStore.initialSessionPageLimit
        )
        let secondDuration = secondStartedAt.duration(to: clock.now)

        print(
            "LIVE_WORKSPACE_SESSION " +
                "route=\(config.routeLabel) " +
                "resolve_ms=\(resolveDuration.milliseconds) " +
                "first_ms=\(firstDuration.milliseconds) " +
                "first_count=\(firstPage.sessions.count) " +
                "first_has_more=\(firstPage.hasMore) " +
                "second_ms=\(secondDuration.milliseconds) " +
                "second_count=\(secondPage.sessions.count) " +
                "second_has_more=\(secondPage.hasMore)"
        )
    }

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

private struct LiveWorkspaceSessionConfig: Decodable {
    let endpoint: String
    let token: String
    let workspacePath: String

    var routeLabel: String {
        guard let host = URL(string: endpoint)?.host?.lowercased() else {
            return "invalid"
        }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return "loopback"
        }
        if host.hasSuffix(".ts.net") || host.hasPrefix("100.") {
            return "tailscale"
        }
        return "other"
    }
}

private extension Duration {
    var milliseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000 + Int64(parts.attoseconds / 1_000_000_000_000_000)
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
