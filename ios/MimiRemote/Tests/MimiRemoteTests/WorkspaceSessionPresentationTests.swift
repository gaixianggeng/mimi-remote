import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testWorkspaceRunningCountBadgeShowsAggregateWithoutGrowingUnbounded() {
        XCTAssertNil(WorkspaceRunningCountBadge.displayText(for: 0))
        XCTAssertNil(WorkspaceRunningCountBadge.displayText(for: -1))
        XCTAssertEqual(WorkspaceRunningCountBadge.displayText(for: 1), "1")
        XCTAssertEqual(WorkspaceRunningCountBadge.displayText(for: 9), "9")
        XCTAssertEqual(WorkspaceRunningCountBadge.displayText(for: 10), "9+")
    }

    func testWorkspaceNeighborPrefetchWaitsForEachRuntimeSpecificFirstPage() {
        XCTAssertTrue(
            WorkspaceSessionPresentation.needsFirstPagePrefetch(cachedPageState: nil),
            "当前 Runtime 没有页状态时必须预取，不能被工作区全局加载状态跳过"
        )

        var loadedPage = WorkspaceRuntimeSessionPageState()
        loadedPage.replace(
            with: SessionsPage(sessions: [], nextCursor: nil, hasMore: false),
            canonicalSessionIDsBeforeLoad: []
        )
        XCTAssertFalse(
            WorkspaceSessionPresentation.needsFirstPagePrefetch(cachedPageState: loadedPage),
            "同一个 Runtime 已完成首屏后不应重复预取"
        )
    }

    func testAuthoritativeFirstPageStartsSmallThenAdaptiveFillShrinksToFloor() async throws {
        // 首包保持小窗口；确认欠填后再按已观察密度估算，并在接近凑满时收敛到最小批量。
        let project = makeProject(id: "workspace_oversample_shrink")
        let firstPageRoots = (0..<18).map { index in
            makeSession(
                id: "root_\(index)",
                projectID: project.id,
                title: "根会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: firstPageRoots, nextCursor: "p2", hasMore: true),
            cursorPages: [
                "p2": SessionsPage(
                    sessions: [makeSession(
                        id: "root_18",
                        projectID: project.id,
                        title: "根会话 18",
                        status: "history",
                        source: "codex",
                        updatedAt: Date(timeIntervalSince1970: 82)
                    )],
                    nextCursor: "p3",
                    hasMore: true
                ),
                "p3": SessionsPage(sessions: [makeSession(
                    id: "root_19",
                    projectID: project.id,
                    title: "根会话 19",
                    status: "history",
                    source: "codex",
                    updatedAt: Date(timeIntervalSince1970: 81)
                )])
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)

        XCTAssertEqual(store.sessions(forProjectID: project.id).count, SessionStore.initialSessionPageLimit)
        XCTAssertEqual(client.requestedSessionCursors, [nil, "p2", "p3"])
        // 首包 20；第一页 18/18 都是 root，后续估算 2、1，均提到最小批量 5。
        XCTAssertEqual(client.requestedSessionLimits, [20, 5, 5])
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
    }

    func testAdaptiveFillBuffersOversampledRootsBehindTwentyRowPresentationWindow() async throws {
        let project = makeProject(id: "workspace_adaptive_root_buffer")
        let firstRoot = makeSession(
            id: "root_0",
            projectID: project.id,
            title: "根会话 0",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let children = (0..<19).map { index in
            makeSubagentSession(
                id: "buffer_child_\(index)",
                projectID: project.id,
                parentThreadID: firstRoot.id,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(99 - index))
            )
        }
        let prefetchedRoots = (1...50).map { index in
            makeSession(
                id: "root_\(index)",
                projectID: project.id,
                title: "根会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(80 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(
                sessions: [firstRoot] + children,
                nextCursor: "prefetched-roots",
                hasMore: true
            ),
            cursorPages: [
                "prefetched-roots": SessionsPage(sessions: prefetchedRoots)
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)

        let loadedRoots = store.sessions(forProjectID: project.id)
        let visibleRoots = WorkspaceSessionPresentation.visibleSessions(
            loadedRoots,
            limit: SessionStore.initialSessionPageLimit
        )
        XCTAssertEqual(client.requestedSessionLimits, [20, 50])
        XCTAssertEqual(SessionStore.maximumSessionPresentationFillRawPageLimit, 50)
        XCTAssertEqual(loadedRoots.count, 51, "超采样得到的额外 root 应保留为本地预取缓冲")
        XCTAssertEqual(visibleRoots.map(\.id), (0..<20).map { "root_\($0)" })
        XCTAssertTrue(WorkspaceSessionPresentation.canLoadMore(
            loadedCount: loadedRoots.count,
            visibleLimit: SessionStore.initialSessionPageLimit,
            remoteHasMore: false
        ))

        let nextVisibleLimit = WorkspaceSessionPresentation.nextVisibleLimit(
            current: SessionStore.initialSessionPageLimit,
            pageSize: SessionStore.expandedSessionPageLimit
        )
        XCTAssertFalse(WorkspaceSessionPresentation.shouldRequestRemotePage(
            loadedCount: loadedRoots.count,
            targetVisibleLimit: nextVisibleLimit,
            remoteHasMore: true
        ), "本地缓冲足够展示下一页时不能再次请求网络")
        XCTAssertEqual(WorkspaceSessionPresentation.committedVisibleLimit(
            current: SessionStore.initialSessionPageLimit,
            target: nextVisibleLimit,
            loadedCount: loadedRoots.count
        ), nextVisibleLimit)
        XCTAssertEqual(WorkspaceSessionPresentation.committedVisibleLimit(
            current: SessionStore.initialSessionPageLimit,
            target: nextVisibleLimit,
            loadedCount: SessionStore.initialSessionPageLimit
        ), SessionStore.initialSessionPageLimit, "请求失败时不能提交空的展示额度")
    }

    func testFastIndexedFirstPageKeepsRequestedPageSizeWithoutAdaptiveOversampling() async throws {
        let project = makeProject(id: "workspace_fast_indexed_small_page")
        let root = makeSession(
            id: "fast_root",
            projectID: project.id,
            title: "快速索引根会话",
            status: "history",
            source: "codex"
        )
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(
                sessions: [root] + (0..<19).map { index in
                    makeSubagentSession(
                        id: "fast_child_\(index)",
                        projectID: project.id,
                        parentThreadID: root.id
                    )
                },
                nextCursor: "fast-older",
                hasMore: true
            )
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))

        _ = try await store.sessionListFirstPage(
            workspace: workspace,
            limit: SessionStore.initialSessionPageLimit,
            reuseRecent: false,
            consistency: .fastIndexed,
            source: .selectedProject
        )

        XCTAssertEqual(client.requestedSessionLimits, [20])
        XCTAssertEqual(client.requestedSessionCursors, [nil])
    }

    func testManualWorkspaceRefreshRestartsFromFirstCursor() async throws {
        let project = makeProject(id: "workspace_manual_restart")
        let staleChild = makeSubagentSession(
            id: "stale_child",
            projectID: project.id,
            parentThreadID: "stale_parent"
        )
        let refreshed = makeSession(
            id: "refreshed_root",
            projectID: project.id,
            title: "刷新后的首屏",
            status: "history",
            source: "codex"
        )
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [refreshed])
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))
        store.recordWorkspaceSessionFirstPageCompletion(
            workspace: workspace,
            page: SessionsPage(
                sessions: [staleChild],
                nextCursor: "stale-continuation",
                hasMore: true
            ),
            consistency: .authoritative
        )

        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertEqual(client.requestedSessionCursors, [nil])
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [refreshed.id])
    }

    func testManualSessionLibraryRefreshRestartsDirectoryPageFromFirstCursor() async throws {
        let project = makeProject(id: "library_manual_restart")
        let workspace = AgentWorkspace(project: project)
        let refreshed = makeSession(
            id: "library_refreshed_root",
            projectID: project.id,
            title: "会话库刷新后的首屏",
            status: "history",
            source: "codex"
        )
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [refreshed])
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.recentWorkspaces = [workspace]
        store.recordWorkspaceSessionFirstPageCompletion(
            workspace: workspace,
            page: SessionsPage(
                sessions: [makeSubagentSession(
                    id: "library_stale_child",
                    projectID: project.id,
                    parentThreadID: "library_stale_parent"
                )],
                nextCursor: "library-stale-continuation",
                hasMore: true
            ),
            consistency: .authoritative
        )

        await store.refreshSessionLibraryIndex(authoritative: true)

        XCTAssertEqual(client.requestedSessionCursors, [nil])
        XCTAssertTrue(store.sessionLibrarySessions.contains { $0.id == refreshed.id })
    }

    func testWorkspacePageDropsLocallyArchivedCacheWhileKeepingProtectedRows() {
        let project = makeProject(id: "workspace_archive_cache")
        let archived = makeSession(
            id: "archived_cached",
            projectID: project.id,
            title: "普通归档会话",
            status: "history",
            source: "codex"
        )
        let selected = makeSession(
            id: "selected_archived_cached",
            projectID: project.id,
            title: "当前选中会话",
            status: "history",
            source: "codex"
        )
        let running = makeSession(
            id: "running_archived_cached",
            projectID: project.id,
            title: "仍在运行的会话",
            status: "running",
            source: "codex"
        )
        let allSessions = [archived, selected, running]
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: allSessions) }
        )
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.sessions = allSessions
        store.selectedSessionID = selected.id
        allSessions.forEach(store.toggleSessionArchived)
        var pageState = WorkspaceRuntimeSessionPageState()
        pageState.replace(
            with: SessionsPage(sessions: allSessions),
            canonicalSessionIDsBeforeLoad: Set(allSessions.map(\.id))
        )

        let canonical = store.directoryScopedSessions(
            workspaceID: project.id,
            runtimeProvider: "codex"
        )
        let visible = pageState.reconciledSessions(with: canonical)

        XCTAssertEqual(Set(visible.map(\.id)), Set([selected.id, running.id]))

        // 回滚或取消归档恢复 canonical 可见性后，原页应立即恢复该行，无需再请求列表。
        store.toggleSessionArchived(archived)
        let restored = pageState.reconciledSessions(with: store.directoryScopedSessions(
            workspaceID: project.id,
            runtimeProvider: "codex"
        ))
        XCTAssertEqual(Set(restored.map(\.id)), Set(allSessions.map(\.id)))
    }

    func testManualRestartStopsContinuationAfterCurrentNetworkPage() async throws {
        let project = makeProject(id: "workspace_stop_old_continuation")
        let roots = (0..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(
                id: "fresh_root_\(index)",
                projectID: project.id,
                title: "新首屏 \(index)",
                status: "history",
                source: "codex"
            )
        }
        let gate = WorkspaceSessionPageGate()
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: roots)
        )
        client.sessionPageHandler = { cursor in
            if cursor == "old-continuation" {
                return try await gate.response()
            }
            return SessionsPage(sessions: roots)
        }
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))
        store.recordWorkspaceSessionFirstPageCompletion(
            workspace: workspace,
            page: SessionsPage(
                sessions: [makeSubagentSession(
                    id: "old_child",
                    projectID: project.id,
                    parentThreadID: "old_parent"
                )],
                nextCursor: "old-continuation",
                hasMore: true
            ),
            consistency: .authoritative
        )

        let continuation = Task { @MainActor in
            try await store.refreshWorkspaceSessions(
                projectID: project.id,
                restartFromFirst: false
            )
        }
        await gate.waitUntilRequested()
        let traversal = try XCTUnwrap(store.sessionListFirstPageInFlightByKey.values.first?.traversalControl)
        let manual = Task { @MainActor in
            try await store.refreshWorkspaceSessions(projectID: project.id)
        }
        // 等手动刷新接管旧链后再放回当前页，避免测试结果依赖两个 actor 的调度先后。
        for _ in 0..<200 where traversal.shouldContinue {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(traversal.shouldContinue)
        await gate.resolve(SessionsPage(
            sessions: [makeSubagentSession(
                id: "old_child_returned",
                projectID: project.id,
                parentThreadID: "old_parent"
            )],
            nextCursor: "must-not-be-requested",
            hasMore: true
        ))

        _ = try? await continuation.value
        try await manual.value

        XCTAssertEqual(client.requestedSessionCursors, ["old-continuation", nil])
        XCTAssertEqual(Set(store.sessions(forProjectID: project.id).map(\.id)), Set(roots.map(\.id)))
    }

    func testConcurrentManualRestartsShareFirstPageAndLineage() async throws {
        let project = makeProject(id: "workspace_concurrent_manual_restart")
        let refreshed = makeSession(
            id: "shared_manual_result",
            projectID: project.id,
            title: "共享刷新结果",
            status: "history",
            source: "codex"
        )
        let gate = WorkspaceSessionPageGate()
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [refreshed])
        )
        client.sessionPageHandler = { _ in try await gate.response() }
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let first = Task { @MainActor in
            try await store.refreshWorkspaceSessions(projectID: project.id)
        }
        await gate.waitUntilRequested()
        let second = Task { @MainActor in
            try await store.refreshWorkspaceSessions(projectID: project.id)
        }
        for _ in 0..<200 where (store.sessionFirstPageWaiterCountByProjectID[project.id] ?? 0) < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.sessionFirstPageWaiterCountByProjectID[project.id], 2)
        XCTAssertEqual(client.requestedSessionCursors, [nil])
        await gate.resolve(SessionsPage(sessions: [refreshed]))
        try await first.value
        try await second.value

        XCTAssertEqual(client.requestedSessionCursors, [nil])
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [refreshed.id])
    }

    func testRestartedFirstPageRejectsOldLineageEvenWhenCursorMatches() async throws {
        let project = makeProject(id: "workspace_restart_lineage")
        let fresh = makeSession(
            id: "lineage_root",
            projectID: project.id,
            title: "新结果",
            status: "history",
            source: "codex"
        )
        let stale = makeSession(
            id: fresh.id,
            projectID: project.id,
            title: "旧结果",
            status: "history",
            source: "codex"
        )
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [fresh])
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))
        let oldLineage = store.currentSessionListRequestLineage(
            workspace: workspace,
            hostScope: store.appStore.activeHostScope
        )
        let freshResult = try await store.sessionListFirstPage(
            workspace: workspace,
            limit: SessionStore.initialSessionPageLimit,
            reuseRecent: false,
            consistency: .authoritative,
            source: .workspaceForeground,
            restartFromFirst: true
        )
        XCTAssertTrue(store.applyWorkspaceSessionFirstPage(
            workspace: workspace,
            page: freshResult.page,
            consistency: .authoritative,
            requestedCursor: freshResult.requestedCursor,
            restartsFromFirst: true,
            requestLineage: freshResult.requestLineage
        ))

        for consistency in [SessionListConsistency.authoritative, .fastIndexed] {
            XCTAssertFalse(store.applyWorkspaceSessionFirstPage(
                workspace: workspace,
                page: SessionsPage(sessions: [stale]),
                consistency: consistency,
                requestedCursor: nil,
                requestLineage: oldLineage
            ))
            store.mergeSessionLibraryPages(
                [(workspace, SessionsPage(sessions: [stale]), nil, oldLineage)],
                generation: store.appStore.connectionGeneration,
                consistency: consistency
            )
            XCTAssertEqual(store.sessionsByID[fresh.id]?.title, fresh.title)
        }
    }
}

private actor WorkspaceSessionPageGate {
    private var resolvedPage: SessionsPage?
    private var continuation: CheckedContinuation<SessionsPage, Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var didRequest = false

    func response() async throws -> SessionsPage {
        // 多发请求时让测试通过请求计数失败，不能因为没有第二次 resolve 而挂住整个测试包。
        if let resolvedPage { return resolvedPage }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            didRequest = true
            let waiters = requestWaiters
            requestWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRequested() async {
        if didRequest { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func resolve(_ page: SessionsPage) {
        resolvedPage = page
        continuation?.resume(returning: page)
        continuation = nil
    }
}
