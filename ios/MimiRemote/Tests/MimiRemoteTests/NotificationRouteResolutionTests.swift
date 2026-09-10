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
