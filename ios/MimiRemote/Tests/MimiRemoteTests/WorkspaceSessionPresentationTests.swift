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

    func testWorkspaceSessionRailOnlyShowsStatesThatNeedAttention() {
        let active = AgentSessionDisplayStatus(
            title: "Running",
            systemImage: "circle.dotted",
            tone: .active,
            showsSpinner: true
        )
        let waiting = AgentSessionDisplayStatus(
            title: "Waiting",
            systemImage: "exclamationmark.triangle.fill",
            tone: .warning,
            showsSpinner: false
        )
        let failed = AgentSessionDisplayStatus(
            title: "Failed",
            systemImage: "exclamationmark.circle.fill",
            tone: .danger,
            showsSpinner: false
        )

        XCTAssertNil(WorkspaceSessionRailState.resolve(status: active))
        XCTAssertEqual(WorkspaceSessionRailState.resolve(status: waiting), .waiting)
        XCTAssertEqual(WorkspaceSessionRailState.resolve(status: failed), .failed)
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
}
