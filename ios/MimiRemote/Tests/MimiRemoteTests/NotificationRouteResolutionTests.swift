import XCTest
@testable import MimiRemote

/// 通知 → 会话解析（gh-417）：本地标签匹配、项目归属、直读优先与列表兜底、意图取代规则。
@MainActor
final class NotificationRouteResolutionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NotificationRouteDiagnostics.reset()
    }

    // MARK: - 本地标签匹配

    func testLocalMessageTagResolvesUniqueSession() throws {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))
        let project = makeProject(id: "proj_local_tag")
        let target = makeSession(id: "thread-local-target", projectID: project.id, title: "目标", status: "history", source: "codex")
        let other = makeSession(id: "thread-local-other", projectID: project.id, title: "其它", status: "history", source: "codex")
        store.sessions = [target, other]

        let notification = try messageNotification(threadID: target.id)
        XCTAssertEqual(store.localNotificationSession(matching: notification)?.id, target.id)
        XCTAssertEqual(NotificationRouteDiagnostics.entries().last?.stage, NotificationRouteDiagnostics.Stage.localResolve)
        XCTAssertEqual(NotificationRouteDiagnostics.entries().last?.outcome, "hit")
        XCTAssertEqual(NotificationRouteDiagnostics.entries().last?.reason, "matches=1")
    }

    func testLocalMessageTagAmbiguousAcrossResumeIDReturnsNil() throws {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))
        let project = makeProject(id: "proj_local_ambiguous")
        let byID = makeSession(id: "thread-shared", projectID: project.id, title: "A", status: "history", source: "codex")
        // 另一会话以 resume id 引用同一线程：两者都命中，不猜，交给网络定位。
        let byResume = makeSession(
            id: "thread-forked",
            projectID: project.id,
            title: "B",
            status: "history",
            source: "codex",
            resumeID: "thread-shared"
        )
        store.sessions = [byID, byResume]

        XCTAssertNil(store.localNotificationSession(matching: try messageNotification(threadID: "thread-shared")))
        XCTAssertEqual(NotificationRouteDiagnostics.entries().last?.outcome, "miss")
        XCTAssertEqual(NotificationRouteDiagnostics.entries().last?.reason, "matches=2")
    }

    func testLocalMessageTagSkipsLocalDraft() throws {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))
        let project = makeProject(id: "proj_local_draft")
        let draft = makeSession(id: "thread-draft", projectID: project.id, title: "草稿", status: "draft", source: "local")
        XCTAssertTrue(draft.isLocalDraft)
        store.sessions = [draft]

        XCTAssertNil(store.localNotificationSession(matching: try messageNotification(threadID: draft.id)))
    }

    func testLocalTagRejectsRuntimeMismatch() throws {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))
        let project = makeProject(id: "proj_local_runtime")
        let claude = makeSession(
            id: "thread-claude",
            projectID: project.id,
            title: "Claude",
            status: "history",
            source: "claude",
            runtimeProvider: "claude"
        )
        store.sessions = [claude]

        XCTAssertNil(store.localNotificationSession(matching: try messageNotification(threadID: claude.id, runtime: "codex")))
        XCTAssertEqual(store.localNotificationSession(matching: try messageNotification(threadID: claude.id, runtime: "claude"))?.id, claude.id)
    }

    func testLocalApprovalTagRestrictsToActiveSessions() throws {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))
        let project = makeProject(id: "proj_local_approval")
        let (runningID, historyID) = collidingApprovalThreadIDs()
        let running = makeSession(id: runningID, projectID: project.id, title: "运行中", status: "running", source: "codex")
        let stale = makeSession(id: historyID, projectID: project.id, title: "旧历史", status: "history", source: "codex")
        store.sessions = [running, stale]
        let tag = String(LockScreenApprovalRouting.messageSessionTag(threadID: runningID).prefix(4))

        // 4 位标签碰撞：只在运行中 / 待处理集合里匹配，旧历史不参与。
        XCTAssertEqual(store.localNotificationSession(matching: try approvalNotification(sessionTag: tag))?.id, runningID)

        // 16 位消息标签不受状态限制，旧历史照样能唯一命中。
        XCTAssertEqual(store.localNotificationSession(matching: try messageNotification(threadID: historyID))?.id, historyID)

        // 两个都在运行中就不唯一。
        var alsoRunning = stale
        alsoRunning.status = "running"
        store.sessions = [running, alsoRunning]
        XCTAssertNil(store.localNotificationSession(matching: try approvalNotification(sessionTag: tag)))
    }

    // MARK: - 项目归属

    func testNotificationProjectIDPrecedence() {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))
        let root = makeProject(id: "proj_root")
        let rootDirectory = AgentWorkspace(
            id: "ws_root",
            name: root.name,
            path: root.path,
            rootProjectID: root.id,
            rootProjectName: root.name,
            rootProjectPath: root.path
        )
        let worktree = AgentWorkspace(
            id: "ws_feature",
            name: "feature",
            path: "/tmp/proj_root-worktrees/feature",
            rootProjectID: root.id,
            rootProjectName: root.name,
            rootProjectPath: root.path
        )
        let subdirectory = AgentWorkspace(
            id: "ws_sub",
            name: "app",
            path: "/tmp/proj_root/packages/app",
            rootProjectID: root.id,
            rootProjectName: root.name,
            rootProjectPath: root.path
        )
        store.projects = [root]
        store.recentWorkspaces = [rootDirectory, worktree, subdirectory]
        store.sessions = [makeSession(id: "thread-known", projectID: "ws_sub", title: "已知", status: "history", source: "codex")]

        // 1. 本地已知会话的归属优先于一切定位信息。
        XCTAssertEqual(
            store.notificationProjectID(threadID: "thread-known", cwd: "/elsewhere", scopeID: worktree.id, projectID: root.id),
            "ws_sub"
        )
        // 2. scope id 恰好是本地工作区。
        XCTAssertEqual(
            store.notificationProjectID(threadID: "thread-new", cwd: subdirectory.path + "/src", scopeID: worktree.id, projectID: root.id),
            worktree.id
        )
        // 3. cwd 落在本地工作区路径内，取最深者。
        XCTAssertEqual(
            store.notificationProjectID(threadID: "thread-new", cwd: subdirectory.path + "/src", scopeID: "scope_unknown", projectID: root.id),
            subdirectory.id
        )
        // 4. cwd 未知时用根项目 id 找到指向根目录的 ws_ 工作区，而不是 worktree。
        XCTAssertEqual(
            store.notificationProjectID(threadID: "thread-new", cwd: nil, scopeID: nil, projectID: root.id),
            rootDirectory.id
        )
        // cwd 已知却不在任何同根工作区内：不猜 worktree，原样返回根项目 id。
        XCTAssertEqual(
            store.notificationProjectID(threadID: "thread-new", cwd: "/tmp/somewhere-else", scopeID: nil, projectID: root.id),
            root.id
        )
        // 5. 什么都不认识时原样返回；空值返回 nil。
        XCTAssertEqual(
            store.notificationProjectID(threadID: "thread-new", cwd: nil, scopeID: nil, projectID: "proj_unknown"),
            "proj_unknown"
        )
        XCTAssertNil(store.notificationProjectID(threadID: "thread-new", cwd: nil, scopeID: nil, projectID: " "))
        XCTAssertEqual(
            NotificationRouteDiagnostics.entries().compactMap(\.reason),
            [
                "rule1_known_session",
                "rule2_scope_id",
                "rule3_cwd_path",
                "rule4_root_project",
                "rule5_project_id",
                "rule5_project_id",
                "no_attribution",
            ]
        )
    }

    // MARK: - 打开流程

    func testDirectReadOpensTargetBeyondFirstPage() async {
        let project = makeProject(id: "proj_direct_read")
        let fillers = (0..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(id: "filler_\(index)", projectID: project.id, title: "首屏 \(index)", status: "history", source: "codex")
        }
        let target = makeSession(id: "thread-beyond-first-page", projectID: project.id, title: "第二页目标", status: "history", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [project.id: SessionsPage(sessions: fillers, nextCursor: "page-2", hasMore: true)],
            sessionResponses: [target.id: SessionResponse(session: target)]
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = makeStore(client: client, appStore: appStore)
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.sidebarProjects = [project]
        let route = SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: project.id,
            sessionID: target.id,
            runtimeProvider: "codex"
        )

        let outcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(store.selectedSessionID, target.id)
        XCTAssertEqual(store.sessionsByID[target.id]?.projectID, project.id)
        XCTAssertEqual(client.requestedSessionIDs.first, target.id)
        XCTAssertTrue(client.requestedProjectIDs.isEmpty, "thread/read 命中后不再请求首屏列表")
        XCTAssertTrue(client.requestedWorkspaceIDs.isEmpty)
    }

    func testReadFailureFallsBackToRuntimeAwareListAndTriesClaudeOnce() async {
        let project = makeProject(id: "proj_read_fallback")
        let filler = makeSession(id: "codex_filler", projectID: project.id, title: "Codex", status: "history", source: "codex")
        let target = makeSession(
            id: "thread-claude-target",
            projectID: project.id,
            title: "Claude 目标",
            status: "history",
            source: "claude",
            runtimeProvider: "claude"
        )
        let client = NotificationRuntimeListClient(
            projects: [project],
            pagesByRuntime: [
                "codex": SessionsPage(sessions: [filler]),
                "claude": SessionsPage(sessions: [target]),
            ],
            readError: AgentAPIError.server(status: 403, message: "thread not authorized")
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = makeStore(client: client, appStore: appStore)
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.sidebarProjects = [project]
        let route = SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: project.id,
            sessionID: target.id
        )

        let outcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(store.selectedSessionID, target.id)
        XCTAssertEqual(client.requestedSessionIDs, [target.id])
        XCTAssertEqual(client.requestedRuntimes, ["codex", "claude"], "runtime 未知：Codex 未命中后只再试一次 Claude")
        XCTAssertEqual(store.sessionsByID[target.id]?.runtimeProvider, "claude")
        XCTAssertNil(store.connectionTermination, "网关的线程授权失败不能被当成访问码失效")
    }

    func testKnownRuntimeRouteOnlyListsThatRuntimeAndRemembersRoute() async {
        let project = makeProject(id: "proj_known_runtime")
        let target = makeSession(
            id: "thread-claude-known",
            projectID: project.id,
            title: "Claude 已知",
            status: "history",
            source: "claude",
            runtimeProvider: "claude"
        )
        let client = NotificationRuntimeListClient(
            projects: [project],
            pagesByRuntime: ["claude": SessionsPage(sessions: [target])],
            readError: MockError.unimplemented
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = makeStore(client: client, appStore: appStore)
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.sidebarProjects = [project]
        let route = SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: project.id,
            sessionID: target.id,
            runtimeProvider: "claude"
        )

        let outcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(client.rememberedRoutes[target.id], "claude", "直读前必须先登记通知给出的 runtime")
        XCTAssertEqual(client.requestedRuntimes, ["claude"])
    }

    func testRawDirOutsideWorkspaceReresolvesInsteadOfMislabeling() async {
        let root = makeProject(id: "proj_reresolve_root")
        let worktree = AgentWorkspace(
            id: "ws_reresolve_feature",
            name: "feature",
            path: "/tmp/proj_reresolve_root-worktrees/feature",
            rootProjectID: root.id,
            rootProjectName: root.name,
            rootProjectPath: root.path
        )
        // agentd 按根项目归属，但线程真实 cwd 在 worktree 里。
        let raw = AgentSession(
            id: "thread-in-worktree",
            projectID: root.id,
            project: root.name,
            dir: worktree.path,
            title: "worktree 里的线程",
            status: "history",
            source: "codex",
            resumeID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let client = MockSessionStoreClient(
            projects: [root],
            sessions: [],
            sessionResponses: [raw.id: SessionResponse(session: raw)]
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = makeStore(client: client, appStore: appStore)
        store.projects = [root]
        store.recentWorkspaces = [AgentWorkspace(project: root), worktree]
        store.sidebarProjects = [root]
        let route = SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: root.id,
            sessionID: raw.id,
            runtimeProvider: "codex"
        )

        let outcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(store.sessionsByID[raw.id]?.projectID, worktree.id, "原始 dir 指向 worktree，必须按目录重新归属")
        XCTAssertEqual(store.sessionsByID[raw.id]?.dir, worktree.path)
        XCTAssertEqual(store.selectedProjectID, worktree.id)
        XCTAssertTrue(
            NotificationRouteDiagnostics.entries().contains { $0.reason == "read_dir_outside_workspace" },
            "重新归属必须留下诊断"
        )
    }

    func testProjectMismatchToleratedForLocallyKnownSession() async {
        let root = makeProject(id: "proj_mismatch_root")
        let canonical = AgentWorkspace(
            id: "ws_mismatch_root",
            name: root.name,
            path: root.path,
            rootProjectID: root.id,
            rootProjectName: root.name,
            rootProjectPath: root.path
        )
        // iOS 用 ws_ 工作区 id 标注，agentd 路由携带根项目 id。
        let target = makeSession(id: "thread-mismatch", projectID: canonical.id, title: "同一线程", status: "history", source: "codex")
        let client = MockSessionStoreClient(projects: [root], sessions: [])
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = makeStore(client: client, appStore: appStore)
        store.projects = [root]
        store.recentWorkspaces = [canonical]
        store.sessions = [target]
        let route = SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: root.id,
            sessionID: target.id
        )

        let outcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(store.selectedSessionID, target.id)
        XCTAssertEqual(store.selectedProjectID, canonical.id)
        XCTAssertTrue(client.requestedSessionIDs.isEmpty, "本地已知会话不需要任何网络刷新")
        XCTAssertTrue(client.requestedProjectIDs.isEmpty)
        XCTAssertTrue(NotificationRouteDiagnostics.entries().contains { $0.reason == "project_mismatch_tolerated" })
        XCTAssertEqual(NotificationRouteDiagnostics.entries().last?.stage, NotificationRouteDiagnostics.Stage.sessionOpen)
        XCTAssertEqual(NotificationRouteDiagnostics.entries().last?.outcome, "opened")
    }

    func testCodexRunningNotificationBypassesUnchangedHistoryCacheAndReconcilesCompletedTurn() async throws {
        try await assertRunningNotificationBypassesHistoryCache(runtimeProvider: "codex")
    }

    func testClaudeRunningNotificationBypassesUnchangedHistoryCacheAndReconcilesCompletedTurn() async throws {
        try await assertRunningNotificationBypassesHistoryCache(runtimeProvider: "claude")
    }

    func testNotificationReconcilesCompletedTurnWithoutVisibleMessages() async throws {
        let project = makeProject(id: "proj_notification_empty_completed_turn")
        let session = makeSession(
            id: "thread-notification-empty-completed-turn",
            projectID: project.id,
            title: "无可见消息的完成轮次",
            status: "running",
            source: "codex",
            runtimeProvider: "codex",
            activeTurnID: "turn-empty-completed"
        )
        let client = NotificationHistorySequenceClient(
            project: project,
            session: session,
            historyResults: [
                .success(notificationHistoryPage(turns: [("turn-empty-completed", .inProgress)])),
                .success(notificationHistoryPage(
                    turns: [("turn-empty-completed", .completed)],
                    visibleTurnIDs: []
                )),
            ]
        )
        let store = makeStore(client: client)
        prepareNotificationHistoryStore(store, project: project, session: session)
        let didLoadCachedHistory = await store.loadHistory(for: session)
        XCTAssertTrue(didLoadCachedHistory)

        let outcome = await store.openSessionFromNotification(notificationRoute(for: session, store: store))

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(client.historyRequestCount, 2)
        XCTAssertNil(store.selectedSession?.activeTurnID)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)
    }

    func testNotificationDoesNotCompleteWhenLaterEmptyTurnIsNotTerminal() async throws {
        for laterLifecycle in [ConversationTurnLifecycle.inProgress, .unknown] {
            let suffix = laterLifecycle.rawValue
            let project = makeProject(id: "proj_notification_empty_later_\(suffix)")
            let session = makeSession(
                id: "thread-notification-empty-later-\(suffix)",
                projectID: project.id,
                title: "后续无可见消息轮次",
                status: "running",
                source: "codex",
                runtimeProvider: "codex",
                activeTurnID: "turn-previous"
            )
            let client = NotificationHistorySequenceClient(
                project: project,
                session: session,
                historyResults: [
                    .success(notificationHistoryPage(turns: [("turn-previous", .inProgress)])),
                    .success(notificationHistoryPage(
                        turns: [
                            ("turn-previous", .completed),
                            ("turn-empty-later", laterLifecycle),
                        ],
                        visibleTurnIDs: ["turn-previous"]
                    )),
                ]
            )
            let store = makeStore(client: client)
            prepareNotificationHistoryStore(store, project: project, session: session)
            let didLoadCachedHistory = await store.loadHistory(for: session)
            XCTAssertTrue(didLoadCachedHistory)

            let outcome = await store.openSessionFromNotification(notificationRoute(for: session, store: store))

            XCTAssertEqual(outcome, .opened)
            XCTAssertEqual(client.historyRequestCount, 2)
            XCTAssertEqual(
                store.selectedSession?.activeTurnID,
                "turn-previous",
                "后续 \(laterLifecycle.rawValue) 空轮次存在时不能释放旧 activeTurnID"
            )
            XCTAssertEqual(store.selectedSession?.status, SessionStatus.running.rawValue)
        }
    }

    func testNotificationTerminalHistoryDoesNotClearNewerActiveTurn() async throws {
        let project = makeProject(id: "proj_notification_newer_turn")
        let session = makeSession(
            id: "thread-notification-newer-turn",
            projectID: project.id,
            title: "新一轮仍在运行",
            status: "running",
            source: "codex",
            runtimeProvider: "codex",
            activeTurnID: "turn-new"
        )
        let client = NotificationHistorySequenceClient(
            project: project,
            session: session,
            historyResults: [
                .success(notificationHistoryPage(turns: [("turn-new", .inProgress)])),
                .success(notificationHistoryPage(turns: [
                    ("turn-old", .completed),
                    ("turn-new", .inProgress),
                ])),
            ]
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        prepareNotificationHistoryStore(store, project: project, session: session)
        let didSelect = await store.selectSession(session)
        XCTAssertTrue(didSelect)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let didQueue = await store.sendTurn(CodexAppServerTurnPayload(prompt: "等待新一轮完成"))
        XCTAssertTrue(didQueue)
        XCTAssertEqual(store.selectedQueuedTurns.first?.expectedTurnID, "turn-new")
        XCTAssertTrue(socket.sentTurns.isEmpty)

        let outcome = await store.openSessionFromNotification(notificationRoute(for: session, store: store))

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(client.historyRequestCount, 2)
        XCTAssertEqual(store.selectedSession?.activeTurnID, "turn-new")
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.running.rawValue)
        XCTAssertEqual(store.selectedQueuedTurns.first?.expectedTurnID, "turn-new")
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .waiting)
        XCTAssertTrue(socket.sentTurns.isEmpty, "旧完成不能越过新 active turn 的队列约束")
    }

    func testNotificationHistoryFailureKeepsRunningStateAndNextOpenRetriesAuthoritativeRead() async throws {
        let project = makeProject(id: "proj_notification_history_retry")
        let session = makeSession(
            id: "thread-notification-history-retry",
            projectID: project.id,
            title: "失败后重试",
            status: "running",
            source: "codex",
            runtimeProvider: "codex",
            activeTurnID: "turn-retry"
        )
        let client = NotificationHistorySequenceClient(
            project: project,
            session: session,
            historyResults: [
                .success(notificationHistoryPage(turns: [("turn-retry", .inProgress)])),
                .failure(AgentAPIError.server(status: 503, message: "temporarily unavailable")),
                .success(notificationHistoryPage(turns: [("turn-retry", .completed)])),
            ]
        )
        let store = makeStore(client: client)
        prepareNotificationHistoryStore(store, project: project, session: session)
        let didLoadCachedHistory = await store.loadHistory(for: session)
        XCTAssertTrue(didLoadCachedHistory)

        let route = notificationRoute(for: session, store: store)
        let failedRefreshOutcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(failedRefreshOutcome, .opened)
        XCTAssertEqual(client.historyRequestCount, 2)
        XCTAssertEqual(store.selectedSession?.activeTurnID, "turn-retry", "网络失败不能伪造完成")
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.running.rawValue)

        let retryOutcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(retryOutcome, .opened)
        XCTAssertEqual(client.historyRequestCount, 3, "同一已选会话再次从通知打开也必须补查")
        XCTAssertNil(store.selectedSession?.activeTurnID)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)
    }

    func testNotificationReplacesOlderBypassHistoryJobAndIgnoresItsLateSnapshot() async throws {
        let project = makeProject(id: "proj_notification_replaces_history_job")
        let session = makeSession(
            id: "thread-notification-replaces-history-job",
            projectID: project.id,
            title: "通知换代历史请求",
            status: "running",
            source: "codex",
            runtimeProvider: "codex",
            activeTurnID: "turn-current"
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [session])
        )
        let store = makeStore(client: client)
        prepareNotificationHistoryStore(store, project: project, session: session)

        let olderHistoryTask = Task {
            await store.loadHistory(
                for: session,
                quiet: true,
                force: true,
                reason: .manualFull
            )
        }
        await client.waitForHistoryRequestCount(1)

        let notificationTask = Task {
            await store.openSessionFromNotification(notificationRoute(for: session, store: store))
        }
        await client.waitForHistoryRequestCount(2)
        client.resolveHistoryRequest(
            at: 1,
            with: notificationHistoryPage(turns: [("turn-current", .completed)])
        )

        let outcome = await notificationTask.value
        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(client.requestedMessageLimits.count, 2)
        XCTAssertNil(store.selectedSession?.activeTurnID)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)

        client.resolveHistoryRequest(
            at: 0,
            with: notificationHistoryPage(turns: [("turn-current", .inProgress)])
        )
        _ = await olderHistoryTask.value
        XCTAssertNil(store.selectedSession?.activeTurnID, "被通知换代的旧快照迟到后不能复活当前轮次")
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)
    }

    func testAutomaticGenerationBumpDuringRefreshDoesNotSupersede() async {
        let project = makeProject(id: "proj_auto_bump")
        let target = makeSession(id: "thread-auto-bump", projectID: project.id, title: "目标", status: "history", source: "codex")
        let client = BlockingNotificationReadClient(projects: [project], response: SessionResponse(session: target))
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = makeStore(client: client, appStore: appStore)
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.sidebarProjects = [project]
        let route = SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: project.id,
            sessionID: target.id,
            runtimeProvider: "codex"
        )

        let notificationTask = Task { await store.openSessionFromNotification(route) }
        await client.waitForBlockedRead()
        // 没有任何用户提交，只是代次被自动推进（工作区去重、身份重映射等都会这样）。
        store.reserveSelectionIntent()
        client.releaseBlockedRead()
        let outcome = await notificationTask.value

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(store.selectedSessionID, target.id)
        XCTAssertEqual(store.lastSelectionCommit?.reason, .notification)
        XCTAssertEqual(client.listCallCount, 0, "直读命中不再请求列表")
    }

    func testUserSelectionDuringRefreshSupersedesNotification() async {
        let project = makeProject(id: "proj_user_supersedes")
        let target = makeSession(id: "thread-user-target", projectID: project.id, title: "通知目标", status: "history", source: "codex")
        let selected = makeSession(id: "thread-user-selected", projectID: project.id, title: "用户打开", status: "history", source: "codex")
        let client = BlockingNotificationReadClient(projects: [project], response: SessionResponse(session: target))
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = makeStore(client: client, appStore: appStore)
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.sidebarProjects = [project]
        store.sessions = [selected]
        let route = SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: project.id,
            sessionID: target.id,
            runtimeProvider: "codex"
        )

        let notificationTask = Task { await store.openSessionFromNotification(route, ifCurrent: store.currentSelectionLease()) }
        await client.waitForBlockedRead()
        await store.selectSession(selected, reason: .userOpen)
        client.releaseBlockedRead()
        let outcome = await notificationTask.value

        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(store.selectedSessionID, selected.id)
        XCTAssertTrue(store.sessions.contains { $0.id == target.id }, "通知目标仍应合并进索引")
        XCTAssertEqual(NotificationRouteDiagnostics.entries().last?.outcome, "superseded")
    }

    func testStaleLeaseWithoutUserCommitIsReReservedNotSuperseded() async {
        let project = makeProject(id: "proj_stale_lease")
        let target = makeSession(id: "thread-stale-lease", projectID: project.id, title: "目标", status: "history", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [])
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = makeStore(client: client, appStore: appStore)
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.sessions = [target]
        let route = SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: project.id,
            sessionID: target.id
        )
        // 调用方先预留了意图，随后代次被自动推进但没有用户提交。
        let reserved = store.reserveSelectionIntent()
        store.reserveSelectionIntent()
        XCTAssertFalse(store.isSelectionLeaseCurrent(reserved))
        XCTAssertFalse(store.notificationIntentSuperseded(since: reserved, target: target.id))

        let outcome = await store.openSessionFromNotification(route, ifCurrent: reserved)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(store.selectedSessionID, target.id)
        XCTAssertTrue(store.notificationIntentSuperseded(since: reserved, target: "thread-someone-else"))
        XCTAssertFalse(store.notificationIntentSuperseded(since: reserved, target: target.id), "同一目标的通知提交不算取代")
    }

    func testMissingTargetReportsUnavailableInsteadOfSilence() async {
        let project = makeProject(id: "proj_missing_target")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [project.id: SessionsPage(sessions: [])]
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = makeStore(client: client, appStore: appStore)
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        let route = SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: project.id,
            sessionID: "thread-nowhere",
            runtimeProvider: "codex"
        )

        let outcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(outcome, .unavailable(message: L10n.text("ui.the_session_corresponding_to_the_notification_is_temporarily")))
        XCTAssertNil(store.selectedSessionID)
        XCTAssertEqual(client.requestedSessionIDs, ["thread-nowhere"])
        XCTAssertEqual(client.requestedProjectIDs, [project.id], "runtime 已知时只查一趟列表")
        XCTAssertEqual(NotificationRouteDiagnostics.entries().last?.outcome, "unavailable")
        XCTAssertEqual(NotificationRouteDiagnostics.entries().last?.reason, "target_missing")
    }

    func testNewestNotificationWinsWhenOlderReadReturnsFirst() async {
        await assertNewestNotificationWins(olderReturnsFirst: true)
    }

    func testNewestNotificationWinsWhenNewerReadReturnsFirst() async {
        await assertNewestNotificationWins(olderReturnsFirst: false)
    }

    private func assertNewestNotificationWins(olderReturnsFirst: Bool) async {
        let project = makeProject(id: "notification-order")
        let a = makeSession(id: "notice-a", projectID: project.id, title: "A", status: "history", source: "codex")
        let b = makeSession(id: "notice-b", projectID: project.id, title: "B", status: "history", source: "codex")
        let client = OrderedNotificationReadClient(project: project, targets: [a, b])
        let store = makeStore(client: client)
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        let adapter = SessionNotificationResponseAdapter()
        adapter.approvalInbox.navigationOwnership = store.notificationNavigation
        func enqueue(_ session: AgentSession) -> (SessionNotificationRoute, UUID) {
            let route = SessionNotificationRoute.current(profileID: store.appStore.notificationRoutingProfileID,
                projectID: project.id, sessionID: session.id, runtimeProvider: "codex")
            adapter.receive(userInfo: route.userInfo)
            return (route, adapter.pendingRouteIntent!)
        }
        let (routeA, intentA) = enqueue(a)
        let taskA = Task { await store.openSessionFromNotification(routeA, navigationIntent: intentA) }
        await client.waitForRead(a.id)
        let (routeB, intentB) = enqueue(b)
        let taskB = Task { await store.openSessionFromNotification(routeB, navigationIntent: intentB) }
        await client.waitForRead(b.id)
        if olderReturnsFirst {
            client.release(a.id)
            let outcome = await taskA.value
            XCTAssertEqual(outcome, .superseded)
            XCTAssertNil(store.selectedSessionID, "B 已入队后，A 即使先返回也不能提交")
            client.release(b.id)
        } else {
            client.release(b.id)
            _ = await taskB.value
            client.release(a.id)
        }
        let outcomeA = await taskA.value
        let outcomeB = await taskB.value
        XCTAssertEqual(outcomeA, .superseded)
        XCTAssertEqual(outcomeB, .opened)
        XCTAssertEqual(store.selectedSessionID, b.id)
    }

    func testInboxIntentExistsBeforeGateAndUserNavigationRevokesIt() async throws {
        let project = makeProject(id: "notification-gate")
        let target = makeSession(id: "notice-gate", projectID: project.id, title: "A", status: "history", source: "codex")
        for event in [WorkbenchNavigationEvent.open(.sessions, source: nil), .compactTabChanged(.devices)] {
            let store = makeStore(client: MockSessionStoreClient(projects: [project], sessions: []))
            store.sessions = [target]
            store.recentWorkspaces = [AgentWorkspace(project: project)]
            let inbox = LockScreenApprovalInbox()
            inbox.navigationOwnership = store.notificationNavigation
            inbox.receive(userInfo: payload(overrides: [:]), actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier")
            let delivery = try XCTUnwrap(inbox.pending)
            XCTAssertTrue(store.notificationNavigation.isCurrent(delivery.navigationIntent))
            // 闸门还未放行。视觉导航在同步事务中就撤销通知，不依赖延迟的选择副作用。
            store.notificationNavigation.observe(event, origin: .user)
            let route = SessionNotificationRoute.current(profileID: store.appStore.notificationRoutingProfileID,
                projectID: project.id, sessionID: target.id)
            let outcome = await store.openSessionFromNotification(route, navigationIntent: delivery.navigationIntent)
            XCTAssertEqual(outcome, .superseded)
            XCTAssertNil(store.selectedSessionID)
        }
    }

    /// iPad 旋转或分屏会让 Shell 程序化重放当前 Tab / selection；等待闸门的通知不能因此被丢弃。
    func testLayoutSynchronizationDoesNotRevokePendingNotification() async throws {
        let project = makeProject(id: "notification-layout")
        let target = makeSession(id: "notice-layout", projectID: project.id, title: "A", status: "history", source: "codex")
        let events: [WorkbenchNavigationEvent] = [
            .compactTabChanged(.me),
            .compactTabChanged(.devices),
            .open(.me, source: nil)
        ]
        let store = makeStore(client: MockSessionStoreClient(projects: [project], sessions: []))
        store.sessions = [target]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        let inbox = LockScreenApprovalInbox()
        inbox.navigationOwnership = store.notificationNavigation
        inbox.receive(userInfo: payload(overrides: [:]), actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier")
        let delivery = try XCTUnwrap(inbox.pending)
        for event in events {
            store.notificationNavigation.observe(event, origin: .layoutSynchronization)
            XCTAssertTrue(
                store.notificationNavigation.isCurrent(delivery.navigationIntent),
                "布局同步重放 \(event) 不能撤销尚未打开的通知"
            )
        }
        let route = SessionNotificationRoute.current(profileID: store.appStore.notificationRoutingProfileID,
            projectID: project.id, sessionID: target.id)
        let outcome = await store.openSessionFromNotification(route, navigationIntent: delivery.navigationIntent)
        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(store.selectedSessionID, target.id)
    }

    func testReturnDuringAutomaticRestorationCannotBeOverwrittenByNotification() async {
        let project = makeProject(id: "notification-return")
        let target = makeSession(id: "notice-return", projectID: project.id, title: "A", status: "history", source: "codex")
        let store = makeStore(client: MockSessionStoreClient(projects: [project], sessions: []))
        store.sessions = [target]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        let intent = store.notificationNavigation.accept()
        _ = store.commitSelection(projectID: project.id, sessionID: nil, reason: .restoration)
        XCTAssertTrue(store.notificationNavigation.isCurrent(intent), "自身暖恢复不会丢通知")
        store.returnToSessionList()
        // 模拟后续 bootstrap 自动推进租约，不能复活已撤销的点击。
        store.reserveSelectionIntent()
        let route = SessionNotificationRoute.current(profileID: store.appStore.notificationRoutingProfileID,
            projectID: project.id, sessionID: target.id)
        let outcome = await store.openSessionFromNotification(route, navigationIntent: intent)
        XCTAssertEqual(outcome, .superseded)
        XCTAssertNil(store.selectedSessionID)
    }

    func testSameDeliveryCanOnlyCommitSelectionOnce() async {
        let project = makeProject(id: "notification-once")
        let target = makeSession(id: "notice-once", projectID: project.id, title: "A", status: "history", source: "codex")
        let store = makeStore(client: MockSessionStoreClient(projects: [project], sessions: []))
        store.sessions = [target]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        let intent = store.notificationNavigation.accept()
        let route = SessionNotificationRoute.current(profileID: store.appStore.notificationRoutingProfileID,
            projectID: project.id, sessionID: target.id)
        let first = await store.openSessionFromNotification(route, navigationIntent: intent)
        let committedSequence = store.lastSelectionCommit?.sequence
        let second = await store.openSessionFromNotification(route, navigationIntent: intent)
        XCTAssertEqual(first, .opened)
        XCTAssertEqual(second, .superseded)
        XCTAssertEqual(store.lastSelectionCommit?.sequence, committedSequence)
    }

    func testCommittedHistorySurvivesParentCancellationAndDuplicateDelivery() async {
        await assertHistoryCancellation(leaveSession: false)
    }

    func testLeavingDuringCommittedHistoryDoesNotReconnectOldSession() async {
        await assertHistoryCancellation(leaveSession: true)
    }

    private func assertHistoryCancellation(leaveSession: Bool) async {
        let project = makeProject(id: "notification-history")
        let target = makeSession(id: "notice-history", projectID: project.id, title: "A", status: "history", source: "codex")
        let client = OrderedNotificationReadClient(project: project, targets: [target])
        client.blockHistory = true
        let store = makeStore(client: client)
        store.sessions = [target]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        let intent = store.notificationNavigation.accept()
        let route = SessionNotificationRoute.current(profileID: store.appStore.notificationRoutingProfileID,
            projectID: project.id, sessionID: target.id)
        let task = Task { await store.openSessionFromNotification(route, navigationIntent: intent) }
        await client.waitForHistory()
        let commit = store.lastSelectionCommit?.sequence
        task.cancel()
        let duplicate = await store.openSessionFromNotification(route, navigationIntent: intent)
        XCTAssertEqual(duplicate, .superseded)
        XCTAssertEqual(store.lastSelectionCommit?.sequence, commit)
        if leaveSession { store.returnToSessionList() }
        client.releaseHistory()
        let outcome = await task.value
        if leaveSession {
            XCTAssertEqual(outcome, .superseded)
            XCTAssertNil(store.selectedSessionID)
            XCTAssertNil(store.connectedSessionID)
        } else {
            XCTAssertEqual(outcome, .opened)
            XCTAssertTrue(store.conversationStore.hasLoadedHistory(sessionID: target.id))
            XCTAssertEqual(store.selectedSessionID, target.id)
        }
    }

    // MARK: - Runtime 路由登记

    func testRoutingClientRememberRuntimeRouteNeverDowngradesClaude() {
        let bundle = AppServerRuntimeBundle(endpoint: "http://127.0.0.1:8787", token: "token")
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: bundle)
        bundle.routes.remember("claude", for: "thread-claude")

        client.rememberRuntimeRoute(nil, forSessionID: "thread-claude")
        XCTAssertEqual(client.rememberedRuntimeRoute(forSessionID: "thread-claude"), "claude")
        client.rememberRuntimeRoute("", forSessionID: "thread-claude")
        XCTAssertEqual(client.rememberedRuntimeRoute(forSessionID: "thread-claude"), "claude")
        client.rememberRuntimeRoute("mystery-runtime", forSessionID: "thread-claude")
        XCTAssertEqual(client.rememberedRuntimeRoute(forSessionID: "thread-claude"), "claude")

        client.rememberRuntimeRoute("anthropic", forSessionID: "thread-new")
        XCTAssertEqual(client.rememberedRuntimeRoute(forSessionID: "thread-new"), "claude")
        XCTAssertNil(client.rememberedRuntimeRoute(forSessionID: "thread-unknown"))

        // 调用方明确断言 codex 才覆盖。
        client.rememberRuntimeRoute("codex", forSessionID: "thread-claude")
        XCTAssertEqual(client.rememberedRuntimeRoute(forSessionID: "thread-claude"), "codex")
    }

    // MARK: - Helpers

    private func makeStore(client: any SessionStoreAPIClient, appStore: AppStore? = nil) -> SessionStore {
        SessionStore(
            appStore: appStore ?? makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
    }

    private func assertRunningNotificationBypassesHistoryCache(runtimeProvider: String) async throws {
        let project = makeProject(id: "proj_notification_\(runtimeProvider)_terminal")
        let session = makeSession(
            id: "thread-notification-\(runtimeProvider)-terminal",
            projectID: project.id,
            title: "\(runtimeProvider) 完成通知",
            status: "running",
            source: runtimeProvider,
            runtimeProvider: runtimeProvider,
            activeTurnID: "turn-active"
        )
        let client = NotificationHistorySequenceClient(
            project: project,
            session: session,
            historyResults: [
                .success(notificationHistoryPage(turns: [("turn-active", .inProgress)])),
                .success(notificationHistoryPage(turns: [("turn-active", .completed)])),
            ]
        )
        let store = makeStore(client: client)
        prepareNotificationHistoryStore(store, project: project, session: session)

        let didLoadInitialHistory = await store.loadHistory(for: session)
        let didReuseInitialHistory = await store.loadHistory(for: session)
        XCTAssertTrue(didLoadInitialHistory)
        XCTAssertTrue(didReuseInitialHistory)
        XCTAssertEqual(client.historyRequestCount, 1, "相同签名的普通历史加载应复用缓存")

        let outcome = await store.openSessionFromNotification(notificationRoute(for: session, store: store))

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(client.historyRequestCount, 2, "通知打开必须越过相同签名及近期首屏缓存")
        XCTAssertNil(store.selectedSession?.activeTurnID)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)
        XCTAssertTrue(store.canSendInSelectedSession, "终态对账后应允许继续输入")
    }

    private func prepareNotificationHistoryStore(
        _ store: SessionStore,
        project: AgentProject,
        session: AgentSession
    ) {
        store.appStore.token = "test-token"
        store.projects = [project]
        store.sidebarProjects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.sessions = [session]
        store.takeOverSession(session)
    }

    private func notificationRoute(for session: AgentSession, store: SessionStore) -> SessionNotificationRoute {
        SessionNotificationRoute.current(
            profileID: store.appStore.notificationRoutingProfileID,
            projectID: session.projectID,
            sessionID: session.id,
            runtimeProvider: session.runtimeProvider ?? session.source
        )
    }

    private func notificationHistoryPage(
        turns: [(TurnID, ConversationTurnLifecycle)],
        visibleTurnIDs: Set<TurnID>? = nil
    ) -> HistoryMessagesPage {
        let visibleTurns = visibleTurnIDs.map { allowed in
            turns.filter { allowed.contains($0.0) }
        } ?? turns
        return HistoryMessagesPage(
            messages: visibleTurns.enumerated().flatMap { index, turn in
                let timestamp = TimeInterval(index * 2)
                return [
                    CodexHistoryMessage(
                        id: "history-user-\(turn.0)",
                        role: "user",
                        content: "第 \(index + 1) 轮",
                        createdAt: Date(timeIntervalSince1970: timestamp + 1),
                        turnID: turn.0,
                        itemID: "history-user-item-\(turn.0)",
                        turnLifecycle: turn.1
                    ),
                    CodexHistoryMessage(
                        id: "history-assistant-\(turn.0)",
                        role: "assistant",
                        content: turn.1.isTerminal ? "已完成" : "处理中",
                        createdAt: Date(timeIntervalSince1970: timestamp + 2),
                        turnID: turn.0,
                        itemID: "history-assistant-item-\(turn.0)",
                        turnLifecycle: turn.1
                    ),
                ]
            },
            turnStates: turns.map { HistoryTurnState(id: $0.0, lifecycle: $0.1) }
        )
    }

    private func payload(overrides: [String: Any]) -> [AnyHashable: Any] {
        var mimi: [String: Any] = [
            "version": 1,
            "event": "approval.pending",
            "action_id": "act-notification-resolution",
            "device_id": "dev-abc123",
            "profile_id": "0123456789abcdef",
            "runtime": "codex",
            "approval_kind": "command",
            "host_tag": "A1C3",
            "session_tag": "7D92",
            "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)),
        ]
        for (key, value) in overrides {
            mimi[key] = value
        }
        return ["mimi": mimi]
    }

    private func messageNotification(threadID: String, runtime: String = "codex") throws -> LockScreenApprovalNotification {
        try XCTUnwrap(LockScreenApprovalNotification(userInfo: payload(overrides: [
            "event": "turn.completed",
            "approval_kind": "",
            "runtime": runtime,
            "session_tag": LockScreenApprovalRouting.messageSessionTag(threadID: threadID),
        ])))
    }

    private func approvalNotification(sessionTag: String, runtime: String = "codex") throws -> LockScreenApprovalNotification {
        try XCTUnwrap(LockScreenApprovalNotification(userInfo: payload(overrides: [
            "runtime": runtime,
            "session_tag": sessionTag,
        ])))
    }

    /// 找两个 4 位审批标签相同的线程 id。SHA256 确定，生日碰撞在几百次内必然出现。
    private func collidingApprovalThreadIDs() -> (String, String) {
        var seen: [String: String] = [:]
        for index in 0..<200_000 {
            let threadID = "collide-\(index)"
            let tag = String(LockScreenApprovalRouting.messageSessionTag(threadID: threadID).prefix(4))
            if let previous = seen[tag] {
                return (previous, threadID)
            }
            seen[tag] = threadID
        }
        XCTFail("4 位标签空间只有 65536，必然存在碰撞")
        return ("collide-a", "collide-b")
    }
}

/// 依次返回缓存快照、权威快照或网络错误，验证通知打开不会复用旧历史。
private final class NotificationHistorySequenceClient: SessionStoreAPIClient {
    private let project: AgentProject
    private let sessionResult: AgentSession
    private let lock = NSLock()
    private var historyResults: [Result<HistoryMessagesPage, Error>]
    private var historyRequestCountStorage = 0

    var historyRequestCount: Int {
        lock.withLock { historyRequestCountStorage }
    }

    init(
        project: AgentProject,
        session: AgentSession,
        historyResults: [Result<HistoryMessagesPage, Error>]
    ) {
        self.project = project
        self.sessionResult = session
        self.historyResults = historyResults
    }

    func projects() async throws -> [AgentProject] {
        [project]
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        [sessionResult]
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        SessionResponse(session: sessionResult)
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        try nextHistoryResult().get().messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        try nextHistoryResult().get()
    }

    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage {
        try nextHistoryResult().get()
    }

    private func nextHistoryResult() -> Result<HistoryMessagesPage, Error> {
        lock.withLock {
            historyRequestCountStorage += 1
            guard !historyResults.isEmpty else {
                return .failure(MockError.unimplemented)
            }
            return historyResults.removeFirst()
        }
    }
}

/// 直读固定失败、列表按 runtime 分头返回，用于验证 runtime 感知的兜底顺序。
private final class NotificationRuntimeListClient: SessionStoreAPIClient {
    private let projectsResult: [AgentProject]
    private let pagesByRuntime: [String: SessionsPage]
    private let readError: Error
    private let lock = NSLock()
    private var requestedRuntimesStorage: [String] = []
    private var requestedSessionIDsStorage: [String] = []
    private var rememberedRoutesStorage: [String: String] = [:]

    var requestedRuntimes: [String] { lock.withLock { requestedRuntimesStorage } }
    var requestedSessionIDs: [String] { lock.withLock { requestedSessionIDsStorage } }
    var rememberedRoutes: [String: String] { lock.withLock { rememberedRoutesStorage } }

    init(projects: [AgentProject], pagesByRuntime: [String: SessionsPage], readError: Error) {
        self.projectsResult = projects
        self.pagesByRuntime = pagesByRuntime
        self.readError = readError
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        pagesByRuntime["codex"]?.sessions ?? []
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        runtimeProvider: String,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        lock.withLock { requestedRuntimesStorage.append(runtimeProvider) }
        guard let page = pagesByRuntime[runtimeProvider] else {
            throw MockError.unimplemented
        }
        return page
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        lock.withLock { requestedSessionIDsStorage.append(id) }
        throw readError
    }

    func rememberRuntimeRoute(_ runtimeProvider: String?, forSessionID sessionID: SessionID) {
        guard let runtimeProvider else { return }
        lock.withLock { rememberedRoutesStorage[sessionID] = runtimeProvider }
    }

    func rememberedRuntimeRoute(forSessionID sessionID: SessionID) -> String? {
        lock.withLock { rememberedRoutesStorage[sessionID] }
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

/// thread/read 挂起直到测试放行，用于在直读期间注入用户操作或自动代次推进。
private final class BlockingNotificationReadClient: SessionStoreAPIClient {
    private let projectsResult: [AgentProject]
    private let response: SessionResponse
    private var blockedReadContinuations: [CheckedContinuation<SessionResponse, Error>] = []
    private var blockedReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedReadCount = 0
    private(set) var listCallCount = 0

    init(projects: [AgentProject], response: SessionResponse) {
        self.projectsResult = projects
        self.response = response
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        listCallCount += 1
        return []
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        try await withCheckedThrowingContinuation { continuation in
            blockedReadContinuations.append(continuation)
            blockedReadCount += 1
            blockedReadWaiters.forEach { $0.resume() }
            blockedReadWaiters = []
        }
    }

    func waitForBlockedRead() async {
        guard blockedReadCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            guard blockedReadCount == 0 else {
                continuation.resume()
                return
            }
            blockedReadWaiters.append(continuation)
        }
    }

    func releaseBlockedRead() {
        blockedReadContinuations.forEach { $0.resume(returning: response) }
        blockedReadContinuations = []
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

/// 每个目标的首次查询独立挂起，后续历史查询直接返回，精确控制 A/B 完成顺序。
@MainActor
private final class OrderedNotificationReadClient: SessionStoreAPIClient {
    let project: AgentProject
    let targets: [String: AgentSession]
    var reads: [String: CheckedContinuation<SessionResponse, Error>] = [:]
    var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    var started: Set<String> = []
    var blockHistory = false
    private var historyStarted = false
    private var historyWaiter: CheckedContinuation<Void, Never>?
    private var historyContinuation: CheckedContinuation<Void, Never>?

    init(project: AgentProject, targets: [AgentSession]) {
        self.project = project
        self.targets = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
    }
    func projects() async throws -> [AgentProject] { [project] }
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] { [] }
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        guard let target = targets[id] else { throw MockError.unimplemented }
        if started.contains(id) { return SessionResponse(session: target) }
        started.insert(id)
        return try await withCheckedThrowingContinuation { continuation in
            reads[id] = continuation
            waiters.removeValue(forKey: id)?.resume()
        }
    }
    func waitForRead(_ id: String) async {
        if started.contains(id) { return }
        await withCheckedContinuation { waiters[id] = $0 }
    }
    func release(_ id: String) {
        reads.removeValue(forKey: id)?.resume(returning: SessionResponse(session: targets[id]!))
    }
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        if blockHistory {
            await withCheckedContinuation { continuation in
                historyContinuation = continuation
                historyStarted = true
                historyWaiter?.resume()
                historyWaiter = nil
            }
        }
        try Task.checkCancellation()
        return []
    }
    func waitForHistory() async {
        if historyStarted { return }
        await withCheckedContinuation { historyWaiter = $0 }
    }
    func releaseHistory() {
        blockHistory = false
        historyContinuation?.resume()
        historyContinuation = nil
    }
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse { throw MockError.unimplemented }
    func stopSession(id: String) async throws { throw MockError.unimplemented }
}
