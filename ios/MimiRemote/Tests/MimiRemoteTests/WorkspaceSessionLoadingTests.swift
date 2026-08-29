import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testWorkspaceCatalogCoordinatorRollsCurrentCancellationBackWithoutLeavingLoading() {
        var coordinator = WorkspaceCatalogLoadCoordinator()

        let emptyInvocation = coordinator.begin()
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertTrue(coordinator.complete(emptyInvocation, result: .cancelled, hasCachedProjects: false))
        XCTAssertEqual(coordinator.state, .idle)

        let cachedInvocation = coordinator.begin()
        XCTAssertTrue(coordinator.complete(cachedInvocation, result: .cancelled, hasCachedProjects: true))
        XCTAssertEqual(coordinator.state, .loaded)
    }

    func testWorkspaceCatalogCoordinatorRejectsOldFailureAndCancellationAfterNewInvocation() {
        var coordinator = WorkspaceCatalogLoadCoordinator()
        let first = coordinator.begin()
        let latest = coordinator.begin()

        XCTAssertFalse(coordinator.complete(first, result: .cancelled, hasCachedProjects: false))
        XCTAssertEqual(coordinator.state, .loading, "旧取消不能替最新 invocation 回退状态")
        XCTAssertTrue(coordinator.complete(latest, result: .loaded, hasCachedProjects: true))
        XCTAssertFalse(coordinator.complete(first, result: .failed("旧请求失败"), hasCachedProjects: false))
        XCTAssertEqual(coordinator.state, .loaded, "旧失败不能覆盖最新成功")
    }

    func testWorkspaceCatalogRefreshScopeTracksCredentialSuspensionWithoutChangingHost() {
        let hostScope = makeIsolatedAppStore().activeHostScope

        XCTAssertNotEqual(
            WorkspaceCatalogRefreshScope(hostScope: hostScope, credentialsSuspended: false),
            WorkspaceCatalogRefreshScope(hostScope: hostScope, credentialsSuspended: true)
        )
    }

    func testWorkspaceSessionRefreshScopeTracksHostGenerationAndRuntimeSelection() {
        let firstHostScope = HostScope(
            profileID: "profile-a",
            installationID: "installation-a",
            generation: 1
        )
        let reconnectedHostScope = HostScope(
            profileID: "profile-a",
            installationID: "installation-a",
            generation: 2
        )

        let codexKey = WorkspaceSessionPresentationKey(
            hostScope: firstHostScope,
            workspaceID: "workspace-a",
            workspacePath: "/tmp/workspace-a",
            runtimeProvider: "codex"
        )
        let reconnectedCodexKey = WorkspaceSessionPresentationKey(
            hostScope: reconnectedHostScope,
            workspaceID: "workspace-a",
            workspacePath: "/tmp/workspace-a",
            runtimeProvider: "codex"
        )
        let claudeKey = WorkspaceSessionPresentationKey(
            hostScope: firstHostScope,
            workspaceID: "workspace-a",
            workspacePath: "/tmp/workspace-a",
            runtimeProvider: "claude"
        )

        XCTAssertNotEqual(
            WorkspaceSessionRefreshScope(presentationKey: codexKey, needsInitialLoad: true),
            WorkspaceSessionRefreshScope(presentationKey: reconnectedCodexKey, needsInitialLoad: true),
            "同一 workspace 在连接代次变化后必须重新触发精确首屏"
        )
        XCTAssertNotEqual(
            WorkspaceSessionRefreshScope(presentationKey: codexKey, needsInitialLoad: true),
            WorkspaceSessionRefreshScope(presentationKey: claudeKey, needsInitialLoad: true),
            "切换 Runtime 必须读取自己的首屏缓存"
        )
    }

    func testWorkspaceRuntimeSessionPageStateKeepsCursorAndRowsInsideOneRuntimeCache() {
        let projectID = "workspace-runtime-cache"
        let first = makeSession(
            id: "codex-first",
            projectID: projectID,
            title: "第一页",
            status: "history",
            source: "codex",
            runtimeProvider: "codex",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let older = makeSession(
            id: "codex-older",
            projectID: projectID,
            title: "第二页",
            status: "history",
            source: "codex",
            runtimeProvider: "codex",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        var state = WorkspaceRuntimeSessionPageState()

        state.replace(
            with: SessionsPage(sessions: [first], nextCursor: "codex-next", hasMore: true),
            canonicalSessionIDsBeforeLoad: [first.id]
        )
        state.append(SessionsPage(sessions: [older, first], nextCursor: nil, hasMore: false))

        XCTAssertEqual(state.sessions.map(\.id), ["codex-first", "codex-older"])
        XCTAssertNil(state.nextCursor)
        XCTAssertFalse(state.hasMore)
        XCTAssertTrue(state.hasLoadedFirstPage)
    }

    func testWorkspaceRuntimeSessionPageReconcilesCanonicalUpdatesAndNewSessions() {
        let projectID = "workspace-runtime-live-updates"
        let cached = makeSession(
            id: "cached-session",
            projectID: projectID,
            title: "旧标题",
            status: "running",
            source: "codex",
            runtimeProvider: "codex",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let preexistingOutsidePage = makeSession(
            id: "older-session",
            projectID: projectID,
            title: "已有旧会话",
            status: "history",
            source: "codex",
            runtimeProvider: "codex",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        var state = WorkspaceRuntimeSessionPageState()
        state.replace(
            with: SessionsPage(sessions: [cached], nextCursor: "older", hasMore: true),
            canonicalSessionIDsBeforeLoad: [cached.id, preexistingOutsidePage.id]
        )

        let refreshedCached = makeSession(
            id: cached.id,
            projectID: projectID,
            title: "WebSocket 新标题",
            status: "history",
            source: "codex",
            runtimeProvider: "codex",
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let newlyObserved = makeSession(
            id: "new-session",
            projectID: projectID,
            title: "刚创建的会话",
            status: "running",
            source: "codex",
            runtimeProvider: "codex",
            updatedAt: Date(timeIntervalSince1970: 40)
        )

        let presented = state.reconciledSessions(
            with: [preexistingOutsidePage, refreshedCached, newlyObserved]
        )

        XCTAssertEqual(presented.map(\.id), [newlyObserved.id, cached.id])
        XCTAssertEqual(presented.last?.title, "WebSocket 新标题")
        XCTAssertEqual(presented.last?.status, "history")
        XCTAssertEqual(state.nextCursor, "older", "canonical 对账不能破坏 Runtime 独立 cursor")
        XCTAssertTrue(state.hasMore)
    }

    func testWorkspaceRuntimePageReturnsOnlyTheSelectedRuntime() async throws {
        let project = makeProject(id: "workspace-runtime-filter")
        let codexSession = makeSession(
            id: "workspace-codex",
            projectID: project.id,
            title: "Codex 会话",
            status: "history",
            source: "codex",
            runtimeProvider: "codex"
        )
        let claudeSession = makeSession(
            id: "workspace-claude",
            projectID: project.id,
            title: "Claude 会话",
            status: "history",
            source: "claude",
            runtimeProvider: "claude"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [codexSession, claudeSession],
            workspaceSessions: [project.id: [codexSession, claudeSession]]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let codexPage = try await store.workspaceRuntimeSessionsPage(
            projectID: project.id,
            runtimeProvider: "codex",
            cursor: nil,
            limit: 20
        )
        let claudePage = try await store.workspaceRuntimeSessionsPage(
            projectID: project.id,
            runtimeProvider: "claude",
            cursor: nil,
            limit: 20
        )

        XCTAssertEqual(codexPage.sessions.map(\.id), [codexSession.id])
        XCTAssertEqual(claudePage.sessions.map(\.id), [claudeSession.id])
    }

    func testSparseWorkspaceCacheStillLoadsOneAuthoritativeFirstPage() async throws {
        for sparseCount in [1, 4] {
            let project = makeProject(id: "workspace_sparse_\(sparseCount)")
            let completePage = (0..<20).map { index in
                makeSession(
                    id: "thread_sparse_\(sparseCount)_\(index)",
                    projectID: project.id,
                    title: "会话 \(index)",
                    status: "history",
                    source: index.isMultiple(of: 2) ? "codex" : "claude",
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
                )
            }
            let client = MutableSessionPageClient(
                projects: [project],
                page: SessionsPage(sessions: completePage, nextCursor: "older", hasMore: true)
            )
            let store = SessionStore(
                appStore: makeIsolatedAppStore(),
                conversationStore: ConversationStore(),
                logStore: LogStore(),
                clientFactory: { client }
            )
            store.projects = [project]
            store.sessions = Array(completePage.prefix(sparseCount))

            XCTAssertEqual(store.sessions(forProjectID: project.id).count, sparseCount, "稀疏缓存必须先保持可见")
            XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))

            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)

            XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), completePage.map(\.id))
            XCTAssertEqual(client.requestedSessionListConsistencies, [.authoritative])
            XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
            XCTAssertFalse(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
            XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "older")
        }
    }

    func testAuthoritativeWorkspaceFirstPageFillsTopLevelWindowAcrossChildDensePages() async throws {
        let project = makeProject(id: "workspace_child_dense_first_page")
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
                id: "child_\(index)",
                projectID: project.id,
                parentThreadID: firstRoot.id,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(99 - index))
            )
        }
        let remainingRoots = (1..<20).map { index in
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
                nextCursor: "after-child-dense-page",
                hasMore: true
            ),
            cursorPages: [
                "after-child-dense-page": SessionsPage(sessions: remainingRoots)
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

        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), (0..<20).map { "root_\($0)" })
        XCTAssertTrue(children.allSatisfy { store.sessionsByID[$0.id]?.isSubagentThread == true })
        XCTAssertEqual(client.requestedSessionCursors, [nil, "after-child-dense-page"])
        // 首包保持 20；观察到 1/20 的 root 密度后，补页估算会封顶到 Gateway 允许的 50。
        XCTAssertEqual(client.requestedSessionLimits, [20, 50])
        XCTAssertTrue(client.requestedSessionLimits.compactMap { $0 }.allSatisfy { $0 <= 50 })
        XCTAssertEqual(client.requestedSessionListConsistencies, [.authoritative, .authoritative])
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertFalse(store.canLoadMoreSessions(projectID: project.id))
    }

    func testAuthoritativeFillRestoresStickySubagentOwnershipBeforeCountingRoots() async throws {
        let project = makeProject(id: "workspace_sticky_child_ownership")
        let knownChildren = (0..<20).map { index in
            makeSubagentSession(
                id: "sticky_child_\(index)",
                projectID: project.id,
                parentThreadID: "sticky_parent"
            )
        }
        let sparseRows = knownChildren.map { child in
            makeSession(
                id: child.id,
                projectID: project.id,
                title: "稀疏列表行",
                status: "history",
                source: "codex"
            )
        }
        let roots = (0..<20).map { index in
            makeSession(
                id: "sticky_root_\(index)",
                projectID: project.id,
                title: "根会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: sparseRows, nextCursor: "after-sparse-children", hasMore: true),
            cursorPages: ["after-sparse-children": SessionsPage(sessions: roots)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.sessions = knownChildren

        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)

        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), roots.map(\.id))
        XCTAssertTrue(knownChildren.allSatisfy { store.sessionsByID[$0.id]?.isSubagentThread == true })
        XCTAssertEqual(client.requestedSessionCursors, [nil, "after-sparse-children"])
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
    }

    func testAuthoritativePresentationFillStopsAtRequestBudgetWithoutRecordingCompletion() async throws {
        let project = makeProject(id: "workspace_presentation_budget")
        let cachedRoot = makeSession(
            id: "presentation_budget_cached_root",
            projectID: project.id,
            title: "缓存根会话",
            status: "history",
            source: "codex"
        )
        var cursorPages: [String: SessionsPage] = [:]
        for index in 1..<SessionStore.maximumSessionPresentationFillPageCount {
            cursorPages["budget-\(index)"] = SessionsPage(
                sessions: [makeSubagentSession(
                    id: "budget_child_\(index)",
                    projectID: project.id,
                    parentThreadID: cachedRoot.id
                )],
                nextCursor: "budget-\(index + 1)",
                hasMore: true
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(
                sessions: [makeSubagentSession(
                    id: "budget_child_0",
                    projectID: project.id,
                    parentThreadID: cachedRoot.id
                )],
                nextCursor: "budget-1",
                hasMore: true
            ),
            cursorPages: cursorPages
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.sessions = [cachedRoot]
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))
        store.recordWorkspaceSessionFirstPageCompletion(
            workspace: workspace,
            page: SessionsPage(sessions: [cachedRoot]),
            consistency: .authoritative
        )
        XCTAssertFalse(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))

        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertEqual(client.requestedSessionCursors.count, SessionStore.maximumSessionPresentationFillPageCount)
        XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [cachedRoot.id])
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "budget-12")
        XCTAssertEqual(
            store.workspaceSessionFirstPageCompletionByKey[
                store.workspaceSessionFirstPageKey(for: workspace)
            ]?.continuationCursor,
            "budget-12"
        )
        XCTAssertNotNil(store.sessionsByID["budget_child_11"], "已扫描 child 仍须进入 canonical Store")

        client.page = SessionsPage(
            sessions: [cachedRoot],
            nextCursor: "stale-first-page-cursor",
            hasMore: true
        )
        await store.refreshSessions(
            forProjectID: project.id,
            showLoading: false,
            reuseRecent: false,
            consistency: .fastIndexed
        )
        XCTAssertEqual(
            store.sessionPageCursorByProjectID[project.id],
            "budget-12",
            "后续弱首屏不能把 budget partial 已推进的安全 continuation 倒退"
        )

        let completedRoots = [cachedRoot] + (1..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(
                id: "presentation_budget_completed_root_\(index)",
                projectID: project.id,
                title: "补齐根会话 \(index)",
                status: "history",
                source: "codex"
            )
        }
        client.page = SessionsPage(
            sessions: completedRoots,
            nextCursor: "fresh-authoritative-cursor",
            hasMore: true
        )
        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertEqual(client.requestedSessionCursors.last, "budget-12", "权威重试必须续跑已保存游标")
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "fresh-authoritative-cursor")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)

        client.page = SessionsPage(
            sessions: [cachedRoot],
            nextCursor: "stale-after-completion",
            hasMore: true
        )
        await store.refreshSessions(
            forProjectID: project.id,
            showLoading: false,
            reuseRecent: false,
            consistency: .fastIndexed
        )
        XCTAssertEqual(
            store.sessionPageCursorByProjectID[project.id],
            "fresh-authoritative-cursor",
            "完整 authoritative 可以纠正 partial cursor，随后弱首屏仍不能把它降级"
        )
    }

    func testAuthoritativeFillUsesLaterDuplicateOwnershipBeforeCompletingWindow() async throws {
        let project = makeProject(id: "workspace_duplicate_ownership")
        let duplicateRootShell = makeSession(
            id: "duplicate_child",
            projectID: project.id,
            title: "稀疏 root 壳",
            status: "history",
            source: "codex"
        )
        let duplicateChild = makeSubagentSession(
            id: duplicateRootShell.id,
            projectID: project.id,
            parentThreadID: "duplicate_parent"
        )
        let roots = (0..<20).map { index in
            makeSession(
                id: "duplicate_root_\(index)",
                projectID: project.id,
                title: "根会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(
                sessions: [duplicateRootShell],
                nextCursor: "duplicate-next",
                hasMore: true
            ),
            cursorPages: [
                "duplicate-next": SessionsPage(sessions: [duplicateChild] + roots)
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

        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), roots.map(\.id))
        XCTAssertTrue(store.sessionsByID[duplicateChild.id]?.isSubagentThread == true)
        XCTAssertEqual(client.requestedSessionCursors, [nil, "duplicate-next"])
        XCTAssertFalse(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
    }

    func testAuthoritativeFillRejectsHasMoreWithoutCursor() async {
        let project = makeProject(id: "workspace_missing_cursor")
        let cachedRoot = makeSession(
            id: "missing_cursor_cached",
            projectID: project.id,
            title: "缓存会话",
            status: "history",
            source: "codex"
        )
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [cachedRoot], nextCursor: nil, hasMore: true)
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.sessions = [cachedRoot]

        await XCTAssertThrowsErrorAsync(
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        ) { error in
            XCTAssertTrue(error is AgentAPIError)
        }

        XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [cachedRoot.id])
    }

    func testLoadMoreSkipsChildOnlyPagesUntilTopLevelSessionsArrive() async throws {
        let project = makeProject(id: "workspace_child_dense_load_more")
        let firstPageRoots = (0..<20).map { index in
            makeSession(
                id: "initial_root_\(index)",
                projectID: project.id,
                title: "首屏根会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let hiddenChildren = (0..<19).map { index in
            makeSubagentSession(
                id: "load_more_child_\(index)",
                projectID: project.id,
                parentThreadID: firstPageRoots[0].id,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(79 - index))
            )
        }
        let olderRoots = (0..<2).map { index in
            makeSession(
                id: "older_root_\(index)",
                projectID: project.id,
                title: "更早根会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(40 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: firstPageRoots, nextCursor: "children-only", hasMore: true),
            cursorPages: [
                "children-only": SessionsPage(
                    // 跨页重复的既有根会话不能占用“新增 20 条”的额度。
                    sessions: [firstPageRoots[0]] + hiddenChildren,
                    nextCursor: "older-roots",
                    hasMore: true
                ),
                "older-roots": SessionsPage(sessions: olderRoots)
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

        await store.loadMoreSessions(projectID: project.id)

        XCTAssertEqual(store.sessions(forProjectID: project.id).count, 22)
        XCTAssertTrue(olderRoots.allSatisfy { store.sessionsByID[$0.id] != nil })
        XCTAssertTrue(hiddenChildren.allSatisfy { store.sessionsByID[$0.id]?.isSubagentThread == true })
        XCTAssertEqual(client.requestedSessionCursors, [nil, "children-only", "older-roots"])
        // fastIndexed 不做超采样；即使 load-more 首包全是 child，也始终按剩余展示窗口请求 20。
        XCTAssertEqual(client.requestedSessionLimits, [20, 20, 20])
        XCTAssertTrue(client.requestedSessionLimits.compactMap { $0 }.allSatisfy { $0 <= 50 })
        XCTAssertFalse(store.canLoadMoreSessions(projectID: project.id))
    }

    func testLoadMoreCannotDowngradeAuthoritativeFieldsAndAbsorbsLateChildOwnership() async throws {
        let project = makeProject(id: "workspace_load_more_quality")
        let authoritativeRoots = (0..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(
                id: "quality_root_\(index)",
                projectID: project.id,
                title: "权威根会话 \(index)",
                status: index == 0 ? "running" : "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let staleBoundary = makeSession(
            id: authoritativeRoots[0].id,
            projectID: project.id,
            title: "过期边界标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let lateChild = makeSubagentSession(
            id: authoritativeRoots[1].id,
            projectID: project.id,
            parentThreadID: authoritativeRoots[0].id
        )
        let olderRoot = makeSession(
            id: "quality_older_root",
            projectID: project.id,
            title: "新增旧根会话",
            status: "history",
            source: "codex"
        )
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(
                sessions: authoritativeRoots,
                nextCursor: "quality-load-more",
                hasMore: true
            ),
            cursorPages: [
                "quality-load-more": SessionsPage(
                    sessions: [staleBoundary, lateChild, olderRoot]
                )
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

        await store.loadMoreSessions(projectID: project.id)

        XCTAssertEqual(store.sessionsByID[authoritativeRoots[0].id]?.title, authoritativeRoots[0].title)
        XCTAssertEqual(store.sessionsByID[authoritativeRoots[0].id]?.status, authoritativeRoots[0].status)
        XCTAssertTrue(store.sessionsByID[authoritativeRoots[1].id]?.isSubagentThread == true)
        XCTAssertFalse(store.sessions(forProjectID: project.id).contains { $0.id == authoritativeRoots[1].id })
        XCTAssertEqual(store.sessionsByID[olderRoot.id]?.title, olderRoot.title)
        XCTAssertFalse(store.canLoadMoreSessions(projectID: project.id))
    }

    func testLoadMoreBudgetLateChildInvalidatesCompletedWindowWithoutRegressingDeepCursor() async throws {
        let project = makeProject(id: "workspace_load_more_late_child_budget")
        let authoritativeRoots = (0..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(
                id: "load_more_budget_root_\(index)",
                projectID: project.id,
                title: "权威根会话 \(index)",
                status: index == 1 ? "running" : "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(200 - index))
            )
        }
        let lateChild = makeSubagentSession(
            id: authoritativeRoots[1].id,
            projectID: project.id,
            parentThreadID: authoritativeRoots[0].id,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        var cursorPages: [String: SessionsPage] = [:]
        for index in 0..<SessionStore.maximumSessionPresentationFillPageCount {
            cursorPages["late-\(index)"] = SessionsPage(
                sessions: [lateChild],
                nextCursor: "late-\(index + 1)",
                hasMore: true
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(
                sessions: authoritativeRoots,
                nextCursor: "late-0",
                hasMore: true
            ),
            cursorPages: cursorPages
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))
        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        XCTAssertFalse(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))

        await store.loadMoreSessions(projectID: project.id)

        let protectedSession = try XCTUnwrap(store.sessionsByID[authoritativeRoots[1].id])
        XCTAssertEqual(protectedSession.title, authoritativeRoots[1].title)
        XCTAssertEqual(protectedSession.status, authoritativeRoots[1].status)
        XCTAssertEqual(protectedSession.updatedAt, authoritativeRoots[1].updatedAt)
        XCTAssertTrue(protectedSession.isSubagentThread)
        XCTAssertEqual(store.sessions(forProjectID: project.id).count, 19)
        let key = store.workspaceSessionFirstPageKey(for: workspace)
        let partialCompletion = try XCTUnwrap(store.workspaceSessionFirstPageCompletionByKey[key])
        XCTAssertEqual(partialCompletion.consistency, .authoritative)
        XCTAssertFalse(partialCompletion.isPresentationWindowComplete)
        XCTAssertNil(store.workspaceSessionFirstPageConsistency(projectID: project.id))
        XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "late-12")
        XCTAssertTrue(store.canLoadMoreSessions(projectID: project.id))
        XCTAssertEqual(
            client.requestedSessionCursors,
            [nil] + (0..<SessionStore.maximumSessionPresentationFillPageCount).map { "late-\($0)" }
        )

        let supplementalRoot = makeSession(
            id: "load_more_budget_supplemental",
            projectID: project.id,
            title: "权威补齐根会话",
            status: "history",
            source: "codex"
        )
        client.page = SessionsPage(
            sessions: authoritativeRoots.enumerated().compactMap { index, session in
                index == 1 ? nil : session
            } + [supplementalRoot],
            nextCursor: "authoritative-refilled",
            hasMore: true
        )

        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)

        XCTAssertEqual(store.sessions(forProjectID: project.id).count, SessionStore.initialSessionPageLimit)
        XCTAssertFalse(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertEqual(
            store.sessionPageCursorByProjectID[project.id],
            "authoritative-refilled",
            "权威补齐沿当前 deep chain 续跑时，显示更多 cursor 也应推进到新边界"
        )
        XCTAssertTrue(store.canLoadMoreSessions(projectID: project.id))
    }

    func testSupersededLoadMoreStopsBeforeFollowingAnotherCursor() async throws {
        let project = makeProject(id: "workspace_superseded_load_more")
        let roots = (0..<20).map { index in
            makeSession(
                id: "superseded_root_\(index)",
                projectID: project.id,
                title: "首屏根会话 \(index)",
                status: "history",
                source: "codex"
            )
        }
        let childPage = SessionsPage(
            sessions: [makeSubagentSession(
                id: "superseded_child",
                projectID: project.id,
                parentThreadID: roots[0].id
            )],
            nextCursor: "must-not-request",
            hasMore: true
        )
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: roots, nextCursor: "load-more", hasMore: true),
            cursorPages: [
                "load-more": childPage,
                "must-not-request": SessionsPage(sessions: [makeSession(
                    id: "must_not_arrive",
                    projectID: project.id,
                    title: "不应请求",
                    status: "history",
                    source: "codex"
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

        var supersedingToken: Int?
        client.onSessionPageRequest = { cursor in
            guard cursor == "load-more", supersedingToken == nil else { return }
            supersedingToken = store.beginSessionFirstPageRequest(
                projectID: project.id,
                consistency: .authoritative
            )
        }
        await store.loadMoreSessions(projectID: project.id)
        if let supersedingToken {
            store.finishSessionFirstPageRequest(projectID: project.id, token: supersedingToken)
        }

        XCTAssertEqual(client.requestedSessionCursors, [nil, "load-more"])
        XCTAssertNil(store.sessionsByID["superseded_child"])
        XCTAssertNil(store.sessionsByID["must_not_arrive"])
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "load-more")
    }

    func testAuthoritativePresentationFillRejectsRepeatedCursorWithoutCompletion() async throws {
        let project = makeProject(id: "workspace_repeated_cursor")
        let firstRoot = makeSession(
            id: "repeated_cursor_root",
            projectID: project.id,
            title: "根会话",
            status: "history",
            source: "codex"
        )
        let child = makeSubagentSession(
            id: "repeated_cursor_child",
            projectID: project.id,
            parentThreadID: firstRoot.id
        )
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [firstRoot], nextCursor: "stuck", hasMore: true),
            cursorPages: [
                "stuck": SessionsPage(sessions: [child], nextCursor: "stuck", hasMore: true)
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        do {
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
            XCTFail("不前进的 cursor 不能被记录为 authoritative 完成")
        } catch {
            XCTAssertTrue(error is AgentAPIError)
        }

        XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
        XCTAssertTrue(store.sessions(forProjectID: project.id).isEmpty)
        XCTAssertEqual(client.requestedSessionCursors, [nil, "stuck"])
    }

    func testFastIndexedFirstPageCannotShrinkCompletedAuthoritativeWindowOrCursor() async throws {
        let project = makeProject(id: "workspace_authoritative_priority")
        let completePage = (0..<20).map { index in
            makeSession(
                id: "thread_authoritative_\(index)",
                projectID: project.id,
                title: "精确会话 \(index)",
                status: index == 0 ? "running" : "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: completePage, nextCursor: "authoritative-older", hasMore: true)
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        let staleExisting = makeSession(
            id: completePage[0].id,
            projectID: project.id,
            title: "过期稀疏标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let supplementalSession = makeSession(
            id: "thread_fast_supplemental",
            projectID: project.id,
            title: "弱页补充会话",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        client.page = SessionsPage(
            sessions: [staleExisting, supplementalSession],
            nextCursor: "sparse-older",
            hasMore: true
        )

        await store.refreshSessions(
            forProjectID: project.id,
            showLoading: false,
            reuseRecent: false,
            consistency: .fastIndexed,
            activatesProject: false
        )

        XCTAssertEqual(
            Set(store.sessions(forProjectID: project.id).map(\.id)),
            Set(completePage.map(\.id) + [supplementalSession.id])
        )
        XCTAssertEqual(store.sessionsByID[completePage[0].id]?.title, completePage[0].title)
        XCTAssertEqual(store.sessionsByID[completePage[0].id]?.status, completePage[0].status)
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "authoritative-older")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertEqual(client.requestedSessionListConsistencies, [.authoritative, .fastIndexed])
    }

    func testAuthoritativeFirstPageWaitsOutCooldownInsteadOfPromotingFastCache() async throws {
        let project = makeProject(id: "workspace_authoritative_cooldown")
        let sparse = makeSession(
            id: "thread_authoritative_cooldown_sparse",
            projectID: project.id,
            title: "稀疏缓存",
            status: "history",
            source: "codex"
        )
        let completePage = (0..<20).map { index in
            makeSession(
                id: "thread_authoritative_cooldown_\(index)",
                projectID: project.id,
                title: "精确会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [sparse], nextCursor: "sparse-cursor", hasMore: true)
        )
        var now = Date(timeIntervalSince1970: 1_780_000_000)
        var requestedSleeps: [UInt64] = []
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionListNow: { now },
            sessionListSleep: { nanoseconds in
                requestedSleeps.append(nanoseconds)
                now = now.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
            }
        )
        store.projects = [project]

        await store.refreshSessions(
            forProjectID: project.id,
            showLoading: false,
            reuseRecent: false,
            consistency: .fastIndexed,
            activatesProject: false
        )
        let workspace = try XCTUnwrap(store.workspacesByID[project.id])
        store.sessionListCooldownUntilByBudgetKey[store.sessionListBudgetKey(for: workspace)] = now.addingTimeInterval(15)
        client.page = SessionsPage(
            sessions: completePage,
            nextCursor: "authoritative-cursor",
            hasMore: true
        )

        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)

        XCTAssertEqual(requestedSleeps, [15_000_000_000])
        XCTAssertEqual(client.requestedSessionListConsistencies, [.fastIndexed, .authoritative])
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), completePage.map(\.id))
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "authoritative-cursor")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
    }

    func testForgottenWorkspaceRejectsLateAuthoritativeLibraryCompletion() throws {
        let project = makeProject(id: "workspace_forgotten_late_page")
        let workspace = AgentWorkspace(project: project)
        let lateSession = makeSession(
            id: "thread_forgotten_late_page",
            projectID: project.id,
            title: "迟到会话",
            status: "history",
            source: "codex"
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        store.recentWorkspaces = [workspace]

        store.forgetWorkspace(project)
        store.mergeSessionLibraryPages(
            [(workspace: workspace, page: SessionsPage(sessions: [lateSession]), requestedCursor: nil)],
            generation: store.appStore.connectionGeneration,
            consistency: .authoritative
        )

        XCTAssertTrue(store.sessions.isEmpty, "移除后的迟到响应不能复活会话")
        XCTAssertTrue(store.workspaceSessionFirstPageCompletionByKey.isEmpty)
        store.recentWorkspaces = [workspace]
        XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
    }

    func testLateFastLibraryPageOnlyAddsMissingSessionsAfterAuthoritativeCompletion() throws {
        let project = makeProject(id: "workspace_late_fast_library")
        let workspace = AgentWorkspace(project: project)
        let authoritativeSession = makeSession(
            id: "thread_library_shared",
            projectID: project.id,
            title: "权威标题",
            status: "running",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let staleExisting = makeSession(
            id: authoritativeSession.id,
            projectID: project.id,
            title: "过期索引标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let supplementalSession = makeSession(
            id: "thread_library_supplemental",
            projectID: project.id,
            title: "补充会话",
            status: "history",
            source: "codex"
        )
        let authoritativeWindow = [authoritativeSession] + (1..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(
                id: "thread_library_authoritative_\(index)",
                projectID: project.id,
                title: "权威会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        store.recentWorkspaces = [workspace]
        store.applyWorkspaceSessionFirstPage(
            workspace: workspace,
            page: SessionsPage(
                sessions: authoritativeWindow,
                nextCursor: "authoritative-library-cursor",
                hasMore: true
            ),
            consistency: .authoritative
        )

        store.mergeSessionLibraryPages(
            [(
                workspace: workspace,
                page: SessionsPage(
                    sessions: [staleExisting, supplementalSession],
                    nextCursor: "stale-library-cursor",
                    hasMore: true
                ),
                requestedCursor: nil
            )],
            generation: store.appStore.connectionGeneration,
            consistency: .fastIndexed
        )

        XCTAssertEqual(store.sessionsByID[authoritativeSession.id]?.title, authoritativeSession.title)
        XCTAssertEqual(store.sessionsByID[authoritativeSession.id]?.status, authoritativeSession.status)
        XCTAssertNotNil(store.sessionsByID[supplementalSession.id])
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "authoritative-library-cursor")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
    }

    func testLateFastLibraryPageCannotDowngradePartialAuthoritativeData() throws {
        let project = makeProject(id: "workspace_late_fast_partial_library")
        let workspace = AgentWorkspace(project: project)
        let authoritativeSession = makeSession(
            id: "thread_partial_library_shared",
            projectID: project.id,
            title: "部分权威标题",
            status: "running",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let staleExisting = makeSession(
            id: authoritativeSession.id,
            projectID: project.id,
            title: "过期部分索引标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let supplementalSession = makeSession(
            id: "thread_partial_library_supplemental",
            projectID: project.id,
            title: "部分补充会话",
            status: "history",
            source: "codex"
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        store.recentWorkspaces = [workspace]
        store.applyWorkspaceSessionFirstPage(
            workspace: workspace,
            page: SessionsPage(
                sessions: [authoritativeSession],
                nextCursor: "partial-authoritative-library-cursor",
                hasMore: true
            ),
            consistency: .authoritative
        )

        store.mergeSessionLibraryPages(
            [(
                workspace: workspace,
                page: SessionsPage(
                    sessions: [staleExisting, supplementalSession],
                    nextCursor: "partial-stale-library-cursor",
                    hasMore: true
                ),
                requestedCursor: nil
            )],
            generation: store.appStore.connectionGeneration,
            consistency: .fastIndexed
        )

        XCTAssertEqual(store.sessionsByID[authoritativeSession.id]?.title, authoritativeSession.title)
        XCTAssertEqual(store.sessionsByID[authoritativeSession.id]?.status, authoritativeSession.status)
        XCTAssertNotNil(store.sessionsByID[supplementalSession.id])
        XCTAssertEqual(
            store.sessionPageCursorByProjectID[project.id],
            "partial-authoritative-library-cursor"
        )
        XCTAssertNil(store.workspaceSessionFirstPageConsistency(projectID: project.id))
        XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
    }

    func testNewAuthoritativeLibraryPageCanReplacePreviousAuthoritativeFields() throws {
        let project = makeProject(id: "workspace_new_authoritative_library")
        let workspace = AgentWorkspace(project: project)
        let oldAuthoritative = makeSession(
            id: "thread_new_authoritative_library_shared",
            projectID: project.id,
            title: "旧权威标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newAuthoritative = makeSession(
            id: oldAuthoritative.id,
            projectID: project.id,
            title: "新权威标题",
            status: "running",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let initialWindow = [oldAuthoritative] + (1..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(
                id: "thread_old_authoritative_library_\(index)",
                projectID: project.id,
                title: "旧权威会话 \(index)",
                status: "history",
                source: "codex"
            )
        }
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        store.recentWorkspaces = [workspace]
        store.applyWorkspaceSessionFirstPage(
            workspace: workspace,
            page: SessionsPage(
                sessions: initialWindow,
                nextCursor: "old-authoritative-library-cursor",
                hasMore: true
            ),
            consistency: .authoritative
        )

        store.mergeSessionLibraryPages(
            [(
                workspace: workspace,
                page: SessionsPage(sessions: [newAuthoritative]),
                requestedCursor: nil
            )],
            generation: store.appStore.connectionGeneration,
            consistency: .authoritative
        )

        XCTAssertEqual(store.sessionsByID[oldAuthoritative.id]?.title, newAuthoritative.title)
        XCTAssertEqual(store.sessionsByID[oldAuthoritative.id]?.status, newAuthoritative.status)
        XCTAssertEqual(store.sessionsByID[oldAuthoritative.id]?.updatedAt, newAuthoritative.updatedAt)
        XCTAssertNil(store.sessionPageCursorByProjectID[project.id])
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
    }

    func testRestoreFastPagePreservesPartialAuthoritativeFieldsAndAbsorbsThreadIdentity() async throws {
        let project = makeProject(id: "workspace_restore_quality")
        let workspace = AgentWorkspace(project: project)
        let authoritativeShared = makeSession(
            id: "restore_quality_shared",
            projectID: project.id,
            title: "恢复权威标题",
            status: "running",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let authoritativeRootBecomingChild = makeSession(
            id: "restore_quality_late_child",
            projectID: project.id,
            title: "权威线程身份候选",
            status: "history",
            source: "codex"
        )
        let staleShared = makeSession(
            id: authoritativeShared.id,
            projectID: project.id,
            title: "恢复过期标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let lateChild = makeSubagentSession(
            id: authoritativeRootBecomingChild.id,
            projectID: project.id,
            parentThreadID: authoritativeShared.id
        )
        let supplemental = makeSession(
            id: "restore_quality_supplemental",
            projectID: project.id,
            title: "恢复补充会话",
            status: "history",
            source: "codex"
        )
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(
                sessions: [staleShared, lateChild, supplemental],
                nextCursor: "restore-stale-cursor",
                hasMore: true
            )
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.recentWorkspaces = [workspace]
        store.applyWorkspaceSessionFirstPage(
            workspace: workspace,
            page: SessionsPage(
                sessions: [authoritativeShared, authoritativeRootBecomingChild],
                nextCursor: "restore-authoritative-cursor",
                hasMore: true
            ),
            consistency: .authoritative
        )
        let snapshot = SessionRestoreSnapshot(endpoint: appStore.endpoint, session: authoritativeShared)

        let restored = await store.resolveSessionForRestore(snapshot)

        XCTAssertEqual(restored?.title, authoritativeShared.title)
        XCTAssertEqual(store.sessionsByID[authoritativeShared.id]?.status, authoritativeShared.status)
        XCTAssertTrue(store.sessionsByID[authoritativeRootBecomingChild.id]?.isSubagentThread == true)
        XCTAssertFalse(
            store.sessions(forProjectID: project.id).contains { $0.id == authoritativeRootBecomingChild.id }
        )
        XCTAssertEqual(store.sessionsByID[supplemental.id]?.title, supplemental.title)
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "restore-authoritative-cursor")
        XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
    }

    func testRestoreLateChildrenInvalidateCompletedWindowAndAuthoritativeRefillsIt() async throws {
        let project = makeProject(id: "workspace_restore_late_children_refill")
        let workspace = AgentWorkspace(project: project)
        let authoritativeRoots = (0..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(
                id: "restore_refill_root_\(index)",
                projectID: project.id,
                title: "权威根会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(200 - index))
            )
        }
        let lateChildren = (1...3).map { index in
            makeSubagentSession(
                id: authoritativeRoots[index].id,
                projectID: project.id,
                parentThreadID: authoritativeRoots[0].id,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(300 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(
                sessions: [authoritativeRoots[0]] + lateChildren,
                nextCursor: "restore-fast-next",
                hasMore: true
            )
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.recentWorkspaces = [workspace]
        store.applyWorkspaceSessionFirstPage(
            workspace: workspace,
            page: SessionsPage(
                sessions: authoritativeRoots,
                nextCursor: "restore-authoritative-old",
                hasMore: true
            ),
            consistency: .authoritative
        )
        XCTAssertFalse(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))

        let snapshot = SessionRestoreSnapshot(endpoint: appStore.endpoint, session: authoritativeRoots[0])
        _ = await store.resolveSessionForRestore(snapshot)

        XCTAssertEqual(store.sessions(forProjectID: project.id).count, 17)
        XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "restore-authoritative-old")

        let supplementalRoots = (20..<23).map { index in
            makeSession(
                id: "restore_refill_root_\(index)",
                projectID: project.id,
                title: "补齐根会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let survivingRoots = authoritativeRoots.enumerated().compactMap { index, session in
            (1...3).contains(index) ? nil : session
        }
        client.page = SessionsPage(
            sessions: survivingRoots + supplementalRoots,
            nextCursor: "restore-authoritative-refilled",
            hasMore: true
        )

        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)

        XCTAssertEqual(store.sessions(forProjectID: project.id).count, SessionStore.initialSessionPageLimit)
        XCTAssertFalse(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "restore-authoritative-refilled")
        XCTAssertEqual(client.requestedSessionListConsistencies, [.fastIndexed, .authoritative])
    }

    func testRestoreFailureCannotReviveWorkspaceForgottenWhileFirstPageIsInFlight() async {
        let project = makeProject(id: "workspace_restore_forgotten_in_flight")
        let workspace = AgentWorkspace(project: project)
        let snapshotSession = makeSession(
            id: "thread_restore_forgotten_in_flight",
            projectID: project.id,
            title: "旧恢复快照",
            status: "history",
            source: "codex"
        )
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: []),
            blockOnCall: 1,
            blockedError: CancellationError()
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.recentWorkspaces = [workspace]
        let snapshot = SessionRestoreSnapshot(endpoint: appStore.endpoint, session: snapshotSession)

        let restore = Task { @MainActor in
            await store.resolveSessionForRestore(snapshot)
        }
        await client.waitForBlockedSessionListRefresh()
        store.forgetWorkspace(project)
        client.releaseBlockedSessionListRefresh()
        let resolved = await restore.value

        XCTAssertNil(resolved)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.sessionPageCursorByProjectID.isEmpty)
        XCTAssertTrue(store.workspaceSessionFirstPageCompletionByKey.isEmpty)
        XCTAssertTrue(store.recentWorkspaces.isEmpty)
    }

    func testConcurrentWorkspaceFirstPageWaitersShareNetworkAndBothObserveCompletion() async throws {
        let project = makeProject(id: "workspace_concurrent_authoritative")
        let completePage = (0..<20).map { index in
            makeSession(
                id: "thread_concurrent_authoritative_\(index)",
                projectID: project.id,
                title: "并发会话 \(index)",
                status: "history",
                source: "codex"
            )
        }
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: completePage),
            blockOnCall: 1
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.sessions = [completePage[0]]

        let first = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }
        await client.waitForBlockedSessionListRefresh()
        let second = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.sessionsPageCallCount, 1)
        client.releaseBlockedSessionListRefresh()
        try await first.value
        try await second.value

        XCTAssertEqual(store.sessions(forProjectID: project.id).count, completePage.count)
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertTrue(store.sessionFirstPageLoadingConsistencyByProjectID.isEmpty)
        XCTAssertTrue(store.sessionFirstPageWaiterCountByProjectID.isEmpty)
    }

    func testFastIndexedWaiterJoiningAuthoritativeRequestCannotDowngradeCompletion() async throws {
        let project = makeProject(id: "workspace_authoritative_then_fast")
        let completePage = (0..<20).map { index in
            makeSession(
                id: "thread_authoritative_then_fast_\(index)",
                projectID: project.id,
                title: "会话 \(index)",
                status: index == 0 ? "running" : "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(
                sessions: completePage,
                nextCursor: "authoritative-older",
                hasMore: true
            ),
            blockOnCall: 1
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let authoritative = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }
        await client.waitForBlockedSessionListRefresh()
        let fastIndexed = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                reuseRecent: false,
                consistency: .fastIndexed,
                activatesProject: false
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.sessionsPageCallCount, 1)
        client.releaseBlockedSessionListRefresh()
        try await authoritative.value
        await fastIndexed.value

        XCTAssertEqual(client.requestedSessionListConsistencies, [.authoritative])
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), completePage.map(\.id))
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "authoritative-older")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
    }

    func testFastIndexedWaitsForAuthoritativeContinuationThenRequestsOwnNilFirstPage() async throws {
        let project = makeProject(id: "workspace_authoritative_continuation_then_fast")
        let completePage = (0..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(
                id: "thread_authoritative_continuation_then_fast_\(index)",
                projectID: project.id,
                title: "会话 \(index)",
                status: "history",
                source: "codex"
            )
        }
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: completePage),
            blockOnCall: 1
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.sessions = [completePage[0]]
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))
        store.recordWorkspaceSessionFirstPageCompletion(
            workspace: workspace,
            page: SessionsPage(
                sessions: [completePage[0]],
                nextCursor: "authoritative-resume-cursor",
                hasMore: true
            ),
            consistency: .authoritative
        )

        let authoritative = Task { @MainActor in
            try await store.refreshWorkspaceSessions(projectID: project.id)
        }
        await client.waitForBlockedSessionListRefresh()
        let fastIndexed = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                reuseRecent: false,
                consistency: .fastIndexed,
                activatesProject: false
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.sessionsPageCallCount, 1, "权威 continuation 未结束前不能并发启动 nil 首屏")
        XCTAssertEqual(client.requestedSessionCursors, ["authoritative-resume-cursor"])

        client.releaseBlockedSessionListRefresh()
        try await authoritative.value
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.sessionsPageCallCount, 2)
        XCTAssertEqual(client.requestedSessionCursors, ["authoritative-resume-cursor", nil])
        client.releaseBlockedSessionListRefresh()
        await fastIndexed.value

        XCTAssertEqual(client.requestedSessionListConsistencies, [.authoritative, .fastIndexed])
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertTrue(store.sessionListFirstPageInFlightByKey.isEmpty)
    }

    func testAuthoritativeWaitsForInFlightFastIndexedThenPerformsExactlyOnePreciseRequest() async throws {
        let project = makeProject(id: "workspace_fast_then_authoritative")
        let sparsePage = SessionsPage(
            sessions: [
                makeSession(
                    // 与权威页首行使用同一 ID，确保无论谁先提交，断言都聚焦字段优先级而非补行时序。
                    id: "thread_precise_0",
                    projectID: project.id,
                    title: "稀疏缓存",
                    status: "history",
                    source: "codex",
                    updatedAt: Date(timeIntervalSince1970: 10)
                )
            ],
            nextCursor: "fast-cursor",
            hasMore: true
        )
        let authoritativeSessions = (0..<20).map { index in
            makeSession(
                id: "thread_precise_\(index)",
                projectID: project.id,
                title: "精确会话 \(index)",
                status: index == 0 ? "running" : "history",
                source: index.isMultiple(of: 2) ? "codex" : "claude",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let authoritativePage = SessionsPage(
            sessions: authoritativeSessions,
            nextCursor: "authoritative-cursor",
            hasMore: true
        )
        let client = FastThenAuthoritativeSessionListClient(
            projects: [project],
            fastOutcome: .page(sparsePage),
            authoritativePage: authoritativePage
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let fastIndexed = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                reuseRecent: false,
                consistency: .fastIndexed,
                activatesProject: false
            )
        }
        await client.waitForBlockedFastRequest()
        let authoritative = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }
        try await waitForAuthoritativeFirstPageWaiter(in: store, projectID: project.id)

        var clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 1, "fastIndexed 未结束前不能并发启动 authoritative")
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessionFirstPageLoadingConsistencyByProjectID[project.id], .authoritative)
        XCTAssertEqual(store.sessionFirstPageWaiterCountByProjectID[project.id], 2)

        await client.releaseFastRequest()
        // 故意先等 authoritative：fast owner 此时可能尚未恢复清理 key，正是生产竞态的关键顺序。
        try await awaitFastThenAuthoritativeTask(authoritative)
        await fastIndexed.value

        clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 2)
        XCTAssertEqual(clientSnapshot.requestedSessionListConsistencies, [.fastIndexed, .authoritative])
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), authoritativeSessions.map(\.id))
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "authoritative-cursor")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertTrue(store.sessionFirstPageLoadingConsistencyByProjectID.isEmpty)
        XCTAssertTrue(store.sessionFirstPageWaiterCountByProjectID.isEmpty)
    }

    func testAuthoritativeStillRunsAfterInFlightFastIndexedFails() async throws {
        let project = makeProject(id: "workspace_failed_fast_then_authoritative")
        let authoritativeSession = makeSession(
            id: "thread_after_failed_fast",
            projectID: project.id,
            title: "精确恢复",
            status: "history",
            source: "codex"
        )
        let client = FastThenAuthoritativeSessionListClient(
            projects: [project],
            fastOutcome: .failure,
            // 本用例只验证失败后的调度升级；分页补齐由 child-dense 专项用例覆盖。
            authoritativePage: SessionsPage(sessions: [authoritativeSession])
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let fastIndexed = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                reportErrorOnFailure: false,
                reuseRecent: false,
                consistency: .fastIndexed,
                activatesProject: false
            )
        }
        await client.waitForBlockedFastRequest()
        let authoritative = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }

        try await waitForAuthoritativeFirstPageWaiter(in: store, projectID: project.id)
        var clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 1, "fastIndexed 失败前 authoritative 必须仍复用同一条 in-flight")
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessionFirstPageLoadingConsistencyByProjectID[project.id], .authoritative)
        XCTAssertEqual(store.sessionFirstPageWaiterCountByProjectID[project.id], 2)

        await client.releaseFastRequest()
        try await awaitFastThenAuthoritativeTask(authoritative)
        await fastIndexed.value

        clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 2)
        XCTAssertEqual(clientSnapshot.requestedSessionListConsistencies, [.fastIndexed, .authoritative])
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [authoritativeSession.id])
        XCTAssertNil(store.sessionPageCursorByProjectID[project.id])
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertTrue(store.sessionFirstPageLoadingConsistencyByProjectID.isEmpty)
        XCTAssertTrue(store.sessionFirstPageWaiterCountByProjectID.isEmpty)
    }

    func testAuthoritativeStillRunsAfterInFlightFastIndexedIsCancelled() async throws {
        let project = makeProject(id: "workspace_cancelled_fast_then_authoritative")
        let authoritativeSession = makeSession(
            id: "thread_after_cancelled_fast",
            projectID: project.id,
            title: "取消后精确恢复",
            status: "history",
            source: "codex"
        )
        let client = FastThenAuthoritativeSessionListClient(
            projects: [project],
            fastOutcome: .cancellation,
            authoritativePage: SessionsPage(sessions: [authoritativeSession])
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let fastIndexed = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                reportErrorOnFailure: false,
                reuseRecent: false,
                consistency: .fastIndexed,
                activatesProject: false
            )
        }
        await client.waitForBlockedFastRequest()
        let authoritative = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }

        try await waitForAuthoritativeFirstPageWaiter(in: store, projectID: project.id)
        var clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 1, "fastIndexed 取消前 authoritative 必须仍复用同一条 in-flight")
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessionFirstPageLoadingConsistencyByProjectID[project.id], .authoritative)
        XCTAssertEqual(store.sessionFirstPageWaiterCountByProjectID[project.id], 2)

        await client.releaseFastRequest()
        try await awaitFastThenAuthoritativeTask(authoritative)
        await fastIndexed.value

        clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 2)
        XCTAssertEqual(clientSnapshot.requestedSessionListConsistencies, [.fastIndexed, .authoritative])
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [authoritativeSession.id])
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertTrue(store.sessionFirstPageLoadingConsistencyByProjectID.isEmpty)
        XCTAssertTrue(store.sessionFirstPageWaiterCountByProjectID.isEmpty)
    }

    func testWorkspaceIdentityRemapStopsAuthoritativeUpgradeAfterFastRequest() async throws {
        let project = makeProject(id: "workspace_identity_remap_upgrade")
        let remappedProject = AgentProject(
            id: project.id,
            name: project.name,
            path: "/tmp/workspace_identity_remap_upgrade_moved"
        )
        let client = FastThenAuthoritativeSessionListClient(
            projects: [project],
            fastOutcome: .page(SessionsPage(sessions: [])),
            authoritativePage: SessionsPage(sessions: [])
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let fastIndexed = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                reuseRecent: false,
                consistency: .fastIndexed,
                activatesProject: false
            )
        }
        await client.waitForBlockedFastRequest()
        let authoritative = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }
        try await waitForAuthoritativeFirstPageWaiter(in: store, projectID: project.id)

        store.recentWorkspaces = [AgentWorkspace(project: remappedProject)]
        await client.releaseFastRequest()
        do {
            try await awaitFastThenAuthoritativeTask(authoritative)
            XCTFail("工作区同 ID 换路径后，旧 waiter 不能继续启动 authoritative 请求")
        } catch is CancellationError {
            // 预期：identity guard 取消旧升级。
        }
        await fastIndexed.value

        let clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 1)
        XCTAssertEqual(clientSnapshot.requestedSessionListConsistencies, [.fastIndexed])
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
    }

    func testCancelledWorkspaceCatalogRequestCannotCommitLateProjects() async {
        let staleProject = makeProject(id: "stale-catalog-project")
        let gate = WorkspaceProjectsGate()
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            projectsHandler: { await gate.projects() }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let refresh = Task { @MainActor in
            try await store.refreshWorkspaceCatalog()
        }
        await gate.waitUntilStarted()
        refresh.cancel()
        await gate.succeed(with: [staleProject])

        do {
            try await refresh.value
            XCTFail("已取消的 catalog 调用应拒绝提交")
        } catch {
            XCTAssertTrue(isCancellationError(error))
        }
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.sidebarProjects.isEmpty)
    }

    func testWorkspaceCancellationClassifierDoesNotHideRealNetworkFailures() {
        XCTAssertTrue(isCancellationError(CancellationError()))
        XCTAssertTrue(isCancellationError(URLError(.cancelled)))
        XCTAssertFalse(isCancellationError(URLError(.timedOut)))
        XCTAssertFalse(isCancellationError(URLError(.notConnectedToInternet)))
        XCTAssertFalse(isCancellationError(AgentAPIError.server(status: 500, message: "server failed")))
    }

    func testWorkspaceSessionLoadFailureDispositionUsesFallbackOnlyForExplicitCancellation() {
        XCTAssertEqual(
            workspaceSessionLoadFailureDisposition(URLError(.cancelled)),
            .cancelled
        )

        let timeout = URLError(.timedOut)
        XCTAssertEqual(
            workspaceSessionLoadFailureDisposition(timeout),
            .failed(timeout.localizedDescription),
            "超时仍必须进入可重试的真实失败态"
        )
    }

    func testOpenWorkspaceCancellationReturnsNeutralOutcomeWithoutPublishingError() async {
        let path = "/Users/me/cancelled-workspace"
        for error in [CancellationError(), URLError(.cancelled)] as [Error] {
            let client = MockSessionStoreClient(
                projects: [],
                sessions: [],
                resolveResults: [path: .failure(error)]
            )
            let store = SessionStore(
                appStore: makeIsolatedAppStore(),
                conversationStore: ConversationStore(),
                logStore: LogStore(),
                clientFactory: { client }
            )

            let outcome = await store.openWorkspaceOutcome(path: path)
            XCTAssertEqual(outcome, .cancelled)
            XCTAssertNil(store.errorMessage)
            XCTAssertTrue(store.sidebarProjects.isEmpty)
        }
    }

    func testOpenWorkspaceRealFailureRemainsUserVisible() async {
        let path = "/Users/me/forbidden-workspace"
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            resolveResults: [path: .failure(AgentAPIError.server(status: 403, message: "forbidden"))]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        guard case .failed(let message) = await store.openWorkspaceOutcome(path: path) else {
            return XCTFail("403 必须保持为可展示失败")
        }
        XCTAssertTrue(message.contains("403"))
        XCTAssertEqual(store.errorMessage, message)
    }

    func testWorkspaceLoadCancellationSkipsAvailabilityProbeAndGlobalErrorMutation() async {
        let workspace = AgentWorkspace(project: makeProject(id: "workspace-cancelled-load"))
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            resolveResults: [workspace.path: .success(workspace)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.handleWorkspaceLoadFailure(workspace: workspace, error: CancellationError())

        XCTAssertTrue(client.requestedResolvePaths.isEmpty, "取消不应再发 availability probe")
        XCTAssertNil(store.errorMessage)
    }

    func testOpenWorkspaceLosingSelectionIntentBeforeResolveReturnsCannotPersistStaleWorkspace() async {
        let project = makeProject(id: "workspace-stale-open")
        let workspace = AgentWorkspace(project: project)
        let gate = WorkspaceResolveGate()
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            resolveWorkspaceHandler: { _ in try await gate.resolve() }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let opening = Task { @MainActor in
            await store.openWorkspaceOutcome(path: workspace.path)
        }
        await gate.waitUntilStarted()
        store.setSelectedProjectID("newer-selection")
        await gate.succeed(with: workspace)

        let outcome = await opening.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(store.sidebarProjects.isEmpty, "失去 ownership 的 resolve 结果不能写入最近工作区")
        XCTAssertEqual(store.selectedProjectID, "newer-selection")
    }

    func testWorkspaceSessionLoadInvocationTokensKeepOnlyLatestABAReturnEligible() {
        var tokens = WorkspaceSessionLoadInvocationTokens()
        let hostScope = makeIsolatedAppStore().activeHostScope
        let keyA = WorkspaceSessionPresentationKey(
            hostScope: hostScope,
            workspaceID: "workspace-a",
            workspacePath: "/tmp/workspace-a",
            runtimeProvider: "codex"
        )
        let keyB = WorkspaceSessionPresentationKey(
            hostScope: hostScope,
            workspaceID: "workspace-b",
            workspacePath: "/tmp/workspace-b",
            runtimeProvider: "claude"
        )
        let firstA = tokens.begin(for: keyA)
        let firstB = tokens.begin(for: keyB)
        let latestA = tokens.begin(for: keyA)

        XCTAssertFalse(
            tokens.isCurrent(firstA, for: keyA),
            "A → B → A 后，旧 A waiter 的取消或失败不能再回写"
        )
        XCTAssertTrue(tokens.isCurrent(firstB, for: keyB), "其他工作区和 Runtime 的 invocation 必须彼此隔离")
        XCTAssertTrue(tokens.isCurrent(latestA, for: keyA))

        tokens.remove { $0.workspaceID == "workspace-a" }
        XCTAssertFalse(tokens.isCurrent(latestA, for: keyA))
        XCTAssertTrue(tokens.isCurrent(firstB, for: keyB))
    }

    func testCancelledWorkspaceSessionWaiterRejoinsSingleFlightAndAppliesResult() async throws {
        let project = makeProject(id: "proj_workspace_cancelled_waiter")
        let session = makeSession(
            id: "thread_workspace_cancelled_waiter",
            projectID: project.id,
            title: "切回后可见",
            status: "history",
            source: "codex"
        )
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: [session]),
            blockOnCall: 1
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let firstA = Task { @MainActor in
            try await store.refreshWorkspaceSessions(projectID: project.id)
        }
        await client.waitForBlockedSessionListRefresh()
        firstA.cancel()

        let latestA = Task { @MainActor in
            try await store.refreshWorkspaceSessions(projectID: project.id)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            client.sessionsPageCallCount,
            1,
            "取消旧 waiter 后重新加入同一工作区，仍只能产生一次底层 thread/list"
        )

        client.releaseBlockedSessionListRefresh()
        _ = await firstA.result
        try await latestA.value

        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [session.id])
    }

}

private enum FastThenAuthoritativeTestError: Error {
    case fastIndexedFailed
    case timedOut
}

func makeSubagentSession(
    id: String,
    projectID: String,
    parentThreadID: String,
    updatedAt: Date = Date(timeIntervalSince1970: 2)
) -> AgentSession {
    AgentSession(
        id: id,
        projectID: projectID,
        project: projectID,
        dir: "/tmp/\(projectID)",
        title: "子 Agent \(id)",
        status: "history",
        source: "codex",
        resumeID: nil,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: updatedAt,
        parentThreadID: parentThreadID,
        isSubagent: true,
        canAcceptDirectInput: false
    )
}

private enum FastRequestOutcome {
    case page(SessionsPage)
    case failure
    case cancellation
}

private struct FastThenAuthoritativeClientSnapshot {
    let sessionsPageCallCount: Int
    let requestedSessionListConsistencies: [SessionListConsistency]
    let maximumConcurrentRequestCount: Int
}

/// mock 的请求计数和 continuation 全部由 actor 隔离，避免测试读写本身制造数据竞争。
private actor FastThenAuthoritativeClientState {
    let projectsResult: [AgentProject]
    let fastOutcome: FastRequestOutcome
    let authoritativePage: SessionsPage

    private var sessionsPageCallCount = 0
    private var requestedSessionListConsistencies: [SessionListConsistency] = []
    private var activeRequestCount = 0
    private var maximumConcurrentRequestCount = 0
    private var fastContinuation: CheckedContinuation<SessionsPage, Error>?
    private var fastRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        projects: [AgentProject],
        fastOutcome: FastRequestOutcome,
        authoritativePage: SessionsPage
    ) {
        self.projectsResult = projects
        self.fastOutcome = fastOutcome
        self.authoritativePage = authoritativePage
    }

    func projects() -> [AgentProject] {
        projectsResult
    }

    func sessionsPage(consistency: SessionListConsistency) async throws -> SessionsPage {
        sessionsPageCallCount += 1
        requestedSessionListConsistencies.append(consistency)
        activeRequestCount += 1
        maximumConcurrentRequestCount = max(maximumConcurrentRequestCount, activeRequestCount)
        defer { activeRequestCount -= 1 }

        if consistency == .fastIndexed {
            return try await withCheckedThrowingContinuation { continuation in
                fastContinuation = continuation
                let waiters = fastRequestWaiters
                fastRequestWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return authoritativePage
    }

    func waitForBlockedFastRequest() async {
        guard fastContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            guard fastContinuation == nil else {
                continuation.resume()
                return
            }
            fastRequestWaiters.append(continuation)
        }
    }

    func releaseFastRequest() {
        guard let continuation = fastContinuation else { return }
        fastContinuation = nil
        switch fastOutcome {
        case .page(let page):
            continuation.resume(returning: page)
        case .failure:
            continuation.resume(throwing: FastThenAuthoritativeTestError.fastIndexedFailed)
        case .cancellation:
            continuation.resume(throwing: CancellationError())
        }
    }

    func snapshot() -> FastThenAuthoritativeClientSnapshot {
        FastThenAuthoritativeClientSnapshot(
            sessionsPageCallCount: sessionsPageCallCount,
            requestedSessionListConsistencies: requestedSessionListConsistencies,
            maximumConcurrentRequestCount: maximumConcurrentRequestCount
        )
    }
}

/// 精确模拟冷启动顺序：第一条 fastIndexed 持续占用 transport，authoritative 只能在其结束后启动。
private final class FastThenAuthoritativeSessionListClient: SessionStoreAPIClient {
    private let state: FastThenAuthoritativeClientState

    init(
        projects: [AgentProject],
        fastOutcome: FastRequestOutcome,
        authoritativePage: SessionsPage
    ) {
        state = FastThenAuthoritativeClientState(
            projects: projects,
            fastOutcome: fastOutcome,
            authoritativePage: authoritativePage
        )
    }

    func projects() async throws -> [AgentProject] {
        await state.projects()
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        state.authoritativePage.sessions
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        try await state.sessionsPage(consistency: consistency)
    }

    func waitForBlockedFastRequest() async {
        await state.waitForBlockedFastRequest()
    }

    func releaseFastRequest() async {
        await state.releaseFastRequest()
    }

    func snapshot() async -> FastThenAuthoritativeClientSnapshot {
        await state.snapshot()
    }

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

/// 先等待 authoritative 才能覆盖“fast task 已结束、owner 尚未清 key”的真实调度窗口；超时会取消底层任务，避免测试永久挂住。
private func awaitFastThenAuthoritativeTask(
    _ task: Task<Void, Error>,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw FastThenAuthoritativeTestError.timedOut
        }
        do {
            _ = try await group.next()
            group.cancelAll()
        } catch {
            task.cancel()
            group.cancelAll()
            throw error
        }
    }
}

/// 不依赖固定 sleep；只有 authoritative 已登记为第二个 waiter 后才释放 fast 请求。
@MainActor
private func waitForAuthoritativeFirstPageWaiter(
    in store: SessionStore,
    projectID: String,
    attempts: Int = 100
) async throws {
    for _ in 0..<attempts {
        if store.sessionFirstPageLoadingConsistencyByProjectID[projectID] == .authoritative,
           store.sessionFirstPageWaiterCountByProjectID[projectID] == 2 {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw FastThenAuthoritativeTestError.timedOut
}

private actor WorkspaceResolveGate {
    private var continuation: CheckedContinuation<AgentWorkspace, Error>?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func resolve() async throws -> AgentWorkspace {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed(with workspace: AgentWorkspace) {
        continuation?.resume(returning: workspace)
        continuation = nil
    }
}

private actor WorkspaceProjectsGate {
    private var continuation: CheckedContinuation<[AgentProject], Never>?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func projects() async -> [AgentProject] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed(with projects: [AgentProject]) {
        continuation?.resume(returning: projects)
        continuation = nil
    }
}
