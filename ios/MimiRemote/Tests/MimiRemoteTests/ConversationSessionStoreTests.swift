import XCTest
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testTopLevelSessionProjectionsHideChildrenButKeepCanonicalRootsAndForks() {
        let project = makeProject(id: "proj_top_level_child_filter")
        let parent = makeSession(
            id: "thread-parent",
            projectID: project.id,
            title: "Parent root",
            status: "history",
            source: "codex"
        )
        var structuralChild = makeSession(
            id: "thread-child-structural",
            projectID: project.id,
            title: "Structural child",
            status: "history",
            source: "codex"
        )
        structuralChild.parentThreadID = parent.id
        structuralChild.canAcceptDirectInput = false
        var runningChild = makeSession(
            id: "thread-child-running",
            projectID: project.id,
            title: "Running child",
            status: "running",
            source: "codex"
        )
        runningChild.parentThreadID = parent.id
        runningChild.canAcceptDirectInput = false
        var sourceOnlyChild = makeSession(
            id: "thread-child-source-only",
            projectID: project.id,
            title: "Source-only child",
            status: "history",
            source: "codex"
        )
        sourceOnlyChild.isSubagent = true
        sourceOnlyChild.canAcceptDirectInput = false
        let ordinaryFork = makeSession(
            id: "thread-ordinary-fork",
            projectID: project.id,
            title: "Ordinary fork root",
            status: "running",
            source: "codex"
        )
        var protocolReadOnlyRoot = makeSession(
            id: "thread-external-read-only-root",
            projectID: project.id,
            title: "External read-only root",
            status: "history",
            source: "codex"
        )
        protocolReadOnlyRoot.canAcceptDirectInput = false

        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.sessions = [
            parent,
            structuralChild,
            runningChild,
            sourceOnlyChild,
            ordinaryFork,
            protocolReadOnlyRoot,
        ]

        let childIDs = Set([structuralChild.id, runningChild.id, sourceOnlyChild.id])
        let topLevelProjections = [
            store.sessionLibrarySessions,
            store.recentSessions,
            store.activeSessions,
            store.recentHistorySessions,
            store.filteredSessions,
            store.sessions(forProjectID: project.id),
            store.visibleSessions(forProjectID: project.id),
            store.sessionListSnapshot(forProjectID: project.id).visibleSessions,
        ]

        XCTAssertTrue(childIDs.isSubset(of: Set(store.sessionsByID.keys)), "child 必须留在 canonical store 供父子导航读取")
        for projection in topLevelProjections {
            XCTAssertTrue(childIDs.isDisjoint(with: Set(projection.map(\.id))))
        }
        XCTAssertTrue(store.activeSessions.contains { $0.id == ordinaryFork.id }, "普通 fork 仍是可独立打开的 root")
        XCTAssertTrue(store.sessionLibrarySessions.contains { $0.id == protocolReadOnlyRoot.id }, "只读能力不能被误当成 child 身份")
        XCTAssertTrue(store.sessions(forProjectID: project.id).contains { $0.id == parent.id })

        store.sessionSearchQuery = "remote child needle"
        var remoteChild = sourceOnlyChild
        remoteChild.title = "Remote child needle"
        store.remoteSessionSearchResults = [remoteChild]
        store.remoteSessionSearchSnippetByID[remoteChild.id] = "remote child needle"

        XCTAssertTrue(store.sessionLibrarySessions.isEmpty)
        XCTAssertTrue(store.filteredSessions.isEmpty)
        XCTAssertTrue(store.filteredSessionSidebarProjects.isEmpty)
        XCTAssertTrue(store.sessionListSnapshot(forProjectID: project.id).visibleSessions.isEmpty)

        var remoteRoot = makeSession(
            id: "thread-remote-read-only-root",
            projectID: project.id,
            title: "Remote child needle root",
            status: "history",
            source: "codex"
        )
        remoteRoot.canAcceptDirectInput = false
        store.remoteSessionSearchResults = [remoteChild, remoteRoot]
        store.remoteSessionSearchSnippetByID[remoteRoot.id] = "remote child needle"

        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [remoteRoot.id])
        XCTAssertEqual(store.filteredSessions.map(\.id), [remoteRoot.id])
        XCTAssertEqual(store.filteredSessionSidebarProjects.map(\.id), [project.id])
        XCTAssertEqual(store.sessionListSnapshot(forProjectID: project.id).visibleSessions.map(\.id), [remoteRoot.id])
    }

    func testRefreshWithoutRecentWorkspacesDoesNotLoadSessions() async {
        let project = makeProject(id: "proj_no_recent")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MockSessionStoreClient(projects: [project], sessions: [history])
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertTrue(store.sidebarProjects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(client.requestedProjectIDs.isEmpty)
    }

    func testSessionLibraryControlledGlobalDiscoveryPaginatesAndMergesExternalWorktrees() async {
        let project = makeProject(id: "proj_global")
        var first = makeSession(
            id: "child-global-a",
            projectID: project.id,
            title: "External A",
            status: "history",
            source: "codex",
            resumeID: "child-global-a"
        )
        first.parentThreadID = "parent-global"
        first.canAcceptDirectInput = false
        var second = makeSession(
            id: "child-global-b",
            projectID: project.id,
            title: "External B",
            status: "history",
            source: "codex",
            resumeID: "child-global-b"
        )
        second.parentThreadID = "parent-global"
        second.canAcceptDirectInput = false
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            controlledGlobalSessionsHandler: { cursor, limit in
                XCTAssertEqual(limit, 50)
                if cursor == nil {
                    return SessionsPage(
                        sessions: [first],
                        nextCursor: "mimi_next",
                        hasMore: true
                    )
                }
                XCTAssertEqual(cursor, "mimi_next")
                return SessionsPage(sessions: [second])
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshSessionLibraryIndex(authoritative: true)

        XCTAssertEqual(client.requestedControlledGlobalCursors.count, 2)
        XCTAssertNil(client.requestedControlledGlobalCursors[0])
        XCTAssertEqual(client.requestedControlledGlobalCursors[1], "mimi_next")
        XCTAssertEqual(Set(store.sessions.map(\.id)), ["child-global-a", "child-global-b"])
        XCTAssertTrue(store.sessions.allSatisfy { !$0.allowsDirectInput })
    }

    func testControlledGlobalDerivedReadOnlySessionsReceiveBoundedStableRecentHistoryVisibility() async {
        let project = makeProject(id: "proj_derived_visibility")
        var newestStructuralChild = makeSession(
            id: "derived-newest",
            projectID: project.id,
            title: "Newest structural child",
            status: "history",
            source: "codex",
            recencyAt: Date(timeIntervalSince1970: 300)
        )
        newestStructuralChild.parentThreadID = "parent-thread"
        newestStructuralChild.canAcceptDirectInput = false

        var secondDelegation = makeSession(
            id: "derived-second",
            projectID: project.id,
            title: "Second delegation",
            status: "history",
            source: "codex",
            preview: "\n  <codex_delegation>\nSecond",
            recencyAt: Date(timeIntervalSince1970: 299)
        )
        secondDelegation.canAcceptDirectInput = false

        let ordinaryHistory = (0..<11).map { index in
            makeSession(
                id: "ordinary-\(index)",
                projectID: project.id,
                title: "Ordinary \(index)",
                status: "history",
                source: "codex",
                recencyAt: Date(timeIntervalSince1970: TimeInterval(298 - index))
            )
        }

        var targetDelegation = makeSession(
            id: "019fb5fd-b2e1-77b0-9427-79723979c7ef",
            projectID: project.id,
            title: "完善 MIM-56 工具活动语义",
            status: "history",
            source: "codex",
            preview: "<codex_delegation>\nMIM-56",
            recencyAt: Date(timeIntervalSince1970: 287)
        )
        targetDelegation.canAcceptDirectInput = false

        var fourthDelegation = makeSession(
            id: "derived-fourth",
            projectID: project.id,
            title: "Older delegation",
            status: "history",
            source: "codex",
            preview: "<codex_delegation>\nOlder",
            recencyAt: Date(timeIntervalSince1970: 286)
        )
        fourthDelegation.canAcceptDirectInput = false

        var globalSessions = [
            newestStructuralChild,
            secondDelegation
        ] + ordinaryHistory + [
            targetDelegation,
            fourthDelegation
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            controlledGlobalSessionsHandler: { _, _ in
                SessionsPage(sessions: globalSessions)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshSessionLibraryIndex(authoritative: true)

        let initialVisibleIDs = store.recentHistorySessions.map(\.id)
        XCTAssertEqual(initialVisibleIDs.count, 10, "structural child 隐藏后，普通前 8 加最多 3 条 root 派生补充仍应保持有界")
        XCTAssertEqual(Set(initialVisibleIDs).count, initialVisibleIDs.count)
        XCTAssertFalse(initialVisibleIDs.contains(newestStructuralChild.id), "有 parentThreadID 的 child 不能占顶层补充名额")
        XCTAssertTrue(initialVisibleIDs.contains(targetDelegation.id), "无 parent/source-only 标记的只读 root 仍可进入默认侧栏")
        XCTAssertTrue(initialVisibleIDs.contains(fourthDelegation.id), "structural child 隐藏后第三条 root 补充应保持可见")
        XCTAssertTrue(
            store.visibleSessions(forProjectID: project.id).contains { $0.id == targetDelegation.id },
            "展开当前目录时也应在普通预览之外看到派生第 3 条"
        )
        XCTAssertTrue(
            store.sessionListSnapshot(forProjectID: project.id).visibleSessions.contains {
                $0.id == targetDelegation.id
            }
        )
        XCTAssertTrue(
            store.visibleSessions(forProjectID: project.id).contains { $0.id == fourthDelegation.id }
        )

        store.setSessionVisibleLimit(
            SessionStore.sessionPreviewLimit + SessionStore.sessionExpansionStep,
            forProjectID: project.id
        )
        XCTAssertTrue(
            store.visibleSessions(forProjectID: project.id).contains { $0.id == targetDelegation.id },
            "显示更多后派生补充行不能从当前目录消失"
        )

        // Agent 输出只会推进 updatedAt；recencyAt 不变时，可见 ID 与顺序都不能抖动。
        for index in globalSessions.indices {
            globalSessions[index].updatedAt = Date(timeIntervalSince1970: TimeInterval(10_000 + index))
        }
        await store.refreshSessionLibraryIndex(authoritative: true)
        XCTAssertEqual(store.recentHistorySessions.map(\.id), initialVisibleIDs)

        let restartedClient = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            controlledGlobalSessionsHandler: { _, _ in
                SessionsPage(sessions: globalSessions)
            }
        )
        let restartedStore = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { restartedClient }
        )
        await restartedStore.refreshSessionLibraryIndex(authoritative: true)
        XCTAssertEqual(
            restartedStore.recentHistorySessions.map(\.id),
            initialVisibleIDs,
            "重启后应由同一受控全局数据恢复，不依赖内存置顶时间"
        )

        store.sessionSearchQuery = "MIM-56"
        store.remoteSessionSearchResults = [targetDelegation]
        store.remoteSessionSearchSnippetByID[targetDelegation.id] = "MIM-56"
        globalSessions.removeAll {
            $0.id == targetDelegation.id || $0.id == newestStructuralChild.id
        }
        await store.refreshSessionLibraryIndex(authoritative: true)
        XCTAssertNil(store.sessionsByID[newestStructuralChild.id])
        XCTAssertNil(store.sessionsByID[targetDelegation.id])
        XCTAssertFalse(store.remoteSessionSearchResults.contains { $0.id == targetDelegation.id })
        XCTAssertNil(store.remoteSessionSearchSnippetByID[targetDelegation.id])
        XCTAssertFalse(store.sessionLibrarySessions.contains { $0.id == newestStructuralChild.id })
        XCTAssertFalse(store.sessionLibrarySessions.contains { $0.id == targetDelegation.id })
        XCTAssertFalse(
            store.recentHistorySessions.contains { $0.id == newestStructuralChild.id },
            "即使旧会话原本位于普通最近 8 条，授权撤销后也必须立即删除"
        )
        XCTAssertFalse(
            store.recentHistorySessions.contains { $0.id == targetDelegation.id },
            "完整全局遍历确认消失后，旧 Session 不得靠补充状态残留"
        )
    }

    func testDerivedRecentHistorySupplementFailsClosedForWritableArchivedAndNonCodexSessions() async {
        let project = makeProject(id: "proj_derived_boundaries")
        let ordinaryHistory = (0..<8).map { index in
            makeSession(
                id: "recent-\(index)",
                projectID: project.id,
                title: "Recent \(index)",
                status: "history",
                source: "codex",
                recencyAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }

        var structuralChild = makeSession(
            id: "structural-child",
            projectID: project.id,
            title: "Structural child",
            status: "history",
            source: "codex",
            recencyAt: Date(timeIntervalSince1970: 20)
        )
        structuralChild.parentThreadID = "parent-thread"
        structuralChild.canAcceptDirectInput = false

        var envelopeChild = makeSession(
            id: "envelope-child",
            projectID: project.id,
            title: "Envelope child",
            status: "history",
            source: "codex",
            preview: "<codex_delegation>\nRead-only",
            recencyAt: Date(timeIntervalSince1970: 19)
        )
        envelopeChild.canAcceptDirectInput = false

        let writableEnvelope = makeSession(
            id: "writable-envelope",
            projectID: project.id,
            title: "User text",
            status: "history",
            source: "codex",
            preview: "<codex_delegation>\nUser-controlled text",
            recencyAt: Date(timeIntervalSince1970: 18)
        )
        var claudeEnvelope = makeSession(
            id: "claude-envelope",
            projectID: project.id,
            title: "Claude",
            status: "history",
            source: "claude",
            preview: "<codex_delegation>\nNot Codex",
            recencyAt: Date(timeIntervalSince1970: 17)
        )
        claudeEnvelope.canAcceptDirectInput = false
        var runningChild = makeSession(
            id: "running-child",
            projectID: project.id,
            title: "Running child",
            status: "running",
            source: "codex",
            preview: "<codex_delegation>\nRunning",
            recencyAt: Date(timeIntervalSince1970: 16)
        )
        runningChild.canAcceptDirectInput = false

        let globalSessions = ordinaryHistory + [
            structuralChild,
            envelopeChild,
            writableEnvelope,
            claudeEnvelope,
            runningChild
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            controlledGlobalSessionsHandler: { _, _ in
                SessionsPage(sessions: globalSessions)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshSessionLibraryIndex(authoritative: true)

        XCTAssertFalse(store.recentHistorySessions.contains { $0.id == structuralChild.id })
        XCTAssertTrue(store.recentHistorySessions.contains { $0.id == envelopeChild.id })
        XCTAssertFalse(store.recentHistorySessions.contains { $0.id == writableEnvelope.id })
        XCTAssertFalse(store.recentHistorySessions.contains { $0.id == claudeEnvelope.id })
        XCTAssertFalse(store.recentHistorySessions.contains { $0.id == runningChild.id })
        XCTAssertTrue(store.activeSessions.contains { $0.id == runningChild.id })

        store.toggleSessionArchived(envelopeChild)
        XCTAssertFalse(store.recentHistorySessions.contains { $0.id == envelopeChild.id })
    }

    func testSessionLibraryFallsBackAfterControlledGlobalCapabilityRejection() async {
        let project = makeProject(id: "proj_fallback")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            controlledGlobalSessionsHandler: { _, _ in
                throw AgentAPIError.server(
                    status: 400,
                    message: "thread/list.cwd 必须来自已授权工作区"
                )
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshSessionLibraryIndex(authoritative: true)
        await store.refreshSessionLibraryIndex(authoritative: true)

        XCTAssertTrue(store.controlledGlobalDiscoveryUnavailable)
        XCTAssertEqual(
            client.requestedControlledGlobalCursors.count,
            1,
            "旧 agentd 的能力拒绝只探测一次，之后继续使用精确 workspace 列表"
        )
    }

    func testWorkspaceRefreshPreservesControlledGlobalWorktreeUntilCompleteTraversalRemovesIt() async throws {
        let project = makeProject(id: "proj_global_refresh")
        let workspaceSession = makeSession(
            id: "thread-workspace",
            projectID: project.id,
            title: "Workspace",
            status: "history",
            source: "codex"
        )
        let externalSession = AgentSession(
            id: "thread-external-worktree",
            projectID: project.id,
            project: project.name,
            dir: "/tmp/codex-worktrees/external",
            title: "External Worktree",
            status: "history",
            source: "codex",
            runtimeProvider: "codex",
            resumeID: "thread-external-worktree",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 3),
            canAcceptDirectInput: false
        )
        var globalSessions = [externalSession]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            workspaceSessions: [project.id: [workspaceSession]],
            controlledGlobalSessionsHandler: { _, _ in
                SessionsPage(sessions: globalSessions)
            }
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client }
        )
        store.reloadRecentWorkspaces()

        await store.refreshSessionLibraryIndex(authoritative: true)
        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertEqual(
            Set(store.sessions(forProjectID: project.id).map(\.id)),
            [workspaceSession.id, externalSession.id],
            "精确 cwd 刷新不得删除已通过受控全局发现授权的外部 Worktree"
        )
        XCTAssertFalse(store.sessionsByID[externalSession.id]?.allowsDirectInput ?? true)

        globalSessions = []
        await store.refreshSessionLibraryIndex(authoritative: true)
        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertEqual(
            store.sessions(forProjectID: project.id).map(\.id),
            [workspaceSession.id],
            "完整全局遍历确认消失后，下一次工作区刷新应清除旧外部会话"
        )
    }

    func testWorkspaceRefreshPreservesControlledGlobalWorktreeAndLoadedPaginationWindow() async throws {
        let project = makeProject(id: "proj_global_paginated_refresh")
        let recent = [
            makeSession(
                id: "thread-recent-a",
                projectID: project.id,
                title: "Recent A",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: 400)
            ),
            makeSession(
                id: "thread-recent-b",
                projectID: project.id,
                title: "Recent B",
                status: "history",
                source: "claude",
                updatedAt: Date(timeIntervalSince1970: 300)
            )
        ]
        let external = AgentSession(
            id: "thread-external-worktree",
            projectID: project.id,
            project: project.name,
            dir: "/tmp/codex-worktrees/external",
            title: "External Worktree",
            status: "history",
            source: "codex",
            runtimeProvider: "codex",
            resumeID: "thread-external-worktree",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 250),
            canAcceptDirectInput: false
        )
        let older = makeSession(
            id: "thread-older-page",
            projectID: project.id,
            title: "Older Page",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [
                project.id: SessionsPage(
                    sessions: recent,
                    nextCursor: "workspace-next",
                    hasMore: true
                )
            ],
            cursorPages: [
                "workspace-next": SessionsPage(sessions: [older])
            ],
            controlledGlobalSessionsHandler: { _, _ in
                SessionsPage(sessions: [external])
            }
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client }
        )
        store.reloadRecentWorkspaces()

        await store.refreshSessionLibraryIndex(authoritative: true)
        await store.loadMoreSessions(projectID: project.id)
        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertEqual(
            store.sessions(forProjectID: project.id).map(\.id),
            recent.map(\.id) + [external.id, older.id],
            "首屏刷新必须同时保留受控全局外部 Worktree 和用户已经加载的旧分页窗口"
        )
        XCTAssertFalse(store.canLoadMoreSessions(projectID: project.id))
        XCTAssertFalse(store.sessionsByID[external.id]?.allowsDirectInput ?? true)
    }

    func testProtocolReadOnlySessionRejectsPromptBeforeClientCall() async {
        let project = makeProject(id: "proj_read_only")
        var child = makeSession(
            id: "child-read-only",
            projectID: project.id,
            title: "Read Only Child",
            status: "history",
            source: "codex",
            resumeID: "child-read-only"
        )
        child.parentThreadID = "parent-thread"
        child.canAcceptDirectInput = false
        let client = MockSessionStoreClient(projects: [project], sessions: [])
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [child]
        store.selectedSessionID = child.id

        let sent = await store.sendPrompt("must not be sent")

        XCTAssertFalse(sent)
        XCTAssertTrue(client.createPayloads.isEmpty)
        XCTAssertEqual(store.controlState(for: child), .observing)
        XCTAssertFalse(store.canControlSession(child))
    }

    func testWorkspaceRecentMapsRootProjectSessionsToWorkspaceID() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = AgentWorkspace(
            id: "ws_child",
            name: "ios",
            path: "/tmp/\(rootProject.id)/ios",
            rootProjectID: rootProject.id,
            rootProjectName: rootProject.name,
            rootProjectPath: rootProject.path,
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let childSession = AgentSession(
            id: "codex_child",
            projectID: rootProject.id,
            project: rootProject.name,
            dir: workspace.path,
            title: "子目录会话",
            status: "history",
            source: "codex",
            resumeID: "child",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            projectPages: [
                rootProject.id: SessionsPage(sessions: [childSession])
            ]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(client.requestedProjectIDs, [rootProject.id])
        XCTAssertEqual(store.sidebarProjects.map(\.id), [workspace.id])
        XCTAssertEqual(store.sessions(forProjectID: workspace.id).map(\.id), [childSession.id])
        XCTAssertEqual(store.sessions.first?.projectID, workspace.id)
    }

    func testOpenWorkspaceStoresResolvedPathOutsideCandidateList() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = AgentWorkspace(
            id: "ws_deep_child",
            name: "ios",
            path: "\(rootProject.path)/apps/mobile/ios",
            rootProjectID: rootProject.id,
            rootProjectName: rootProject.name,
            rootProjectPath: rootProject.path
        )
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            projectPages: [
                rootProject.id: SessionsPage(sessions: [])
            ],
            resolveResults: [
                workspace.path: .success(workspace)
            ]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let opened = await store.openWorkspace(path: "  \(workspace.path)  ")

        XCTAssertTrue(opened)
        XCTAssertEqual(client.requestedResolvePaths, [workspace.path])
        XCTAssertEqual(client.requestedWorkspaceIDs, [workspace.id])
        XCTAssertEqual(client.requestedProjectIDs, [rootProject.id])
        XCTAssertEqual(store.selectedProjectID, workspace.id)
        XCTAssertEqual(store.sidebarProjects.map(\.id), [workspace.id])
        XCTAssertNil(store.errorMessage)
    }

    func testDirectoryListResponseDecodesAgentdPayload() throws {
        let json = """
        {
          "path": "/Users/me",
          "parent_path": null,
          "entries": [
            {"name": "finance", "path": "/Users/me/finance", "is_dir": true, "can_open": true, "can_browse": true}
          ]
        }
        """
        let response = try JSONDecoder().decode(DirectoryListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.path, "/Users/me")
        XCTAssertNil(response.parentPath)
        XCTAssertEqual(response.entries.map(\.name), ["finance"])
        XCTAssertEqual(response.entries.first?.path, "/Users/me/finance")
        XCTAssertEqual(response.entries.first?.canOpen, true)
        XCTAssertEqual(response.entries.first?.canBrowse, true)
        XCTAssertNil(response.truncated)
    }

    func testListDirectoriesUsesInjectedClientAndKeepsErrorsLocal() async throws {
        let rootProject = makeProject(id: "proj_root")
        let listing = DirectoryListResponse(
            path: rootProject.path,
            parentPath: nil,
            entries: [
                DirectoryEntry(name: "finance", path: "\(rootProject.path)/finance", isDir: true, canOpen: true, canBrowse: true)
            ],
            truncated: nil
        )
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            directoryListResults: [
                "": .success(listing),
                "/forbidden": .failure(AgentAPIError.server(status: 403, message: "路径不在允许范围内或不可访问"))
            ]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let response = try await store.listDirectories(path: "")
        XCTAssertEqual(response, listing)

        do {
            _ = try await store.listDirectories(path: "/forbidden")
            XCTFail("allowlist 外目录应抛错")
        } catch {
            // 浏览错误应抛给调用方内联展示，不污染全局 errorMessage。
        }
        XCTAssertEqual(client.requestedDirectoryPaths, ["", "/forbidden"])
        XCTAssertNil(store.errorMessage)
    }

    func testSessionStorePinsAndArchivesSessionsLocally() async {
        let project = makeProject(id: "proj_prefs")
        let older = makeSession(
            id: "session_older",
            projectID: project.id,
            title: "旧会话",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = makeSession(
            id: "session_newer",
            projectID: project.id,
            title: "新会话",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [
                project.id: SessionsPage(sessions: [older, newer])
            ],
            sessionArchiveResults: [
                older.id: .success(())
            ]
        )
        let appStore = makeIsolatedAppStore()
        let preferences = makeSessionListPreferenceStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [AgentWorkspace(project: project)], endpoint: appStore.endpoint),
            sessionListPreferenceStore: preferences,
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [newer.id, older.id])
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [newer.id, older.id])

        store.toggleSessionPinned(older)
        XCTAssertTrue(store.isSessionPinned(older.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [older.id, newer.id])
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [older.id, newer.id])
        XCTAssertEqual(
            preferences.load(profileID: appStore.notificationRoutingProfileID).pinnedSessionIDs,
            [older.id]
        )

        await store.toggleSessionArchivedRemote(older)
        XCTAssertFalse(store.isSessionPinned(older.id))
        XCTAssertTrue(store.isSessionArchived(older.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [newer.id])
        XCTAssertEqual(
            preferences.load(profileID: appStore.notificationRoutingProfileID).archivedSessionIDs,
            [older.id]
        )

        await store.toggleSessionArchivedRemote(older)
        XCTAssertFalse(store.isSessionArchived(older.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [newer.id, older.id])
        XCTAssertEqual(client.requestedSessionArchives, [
            RequestedSessionArchive(id: older.id, archived: true),
            RequestedSessionArchive(id: older.id, archived: false)
        ])
    }

    func testArchiveFailureRollsBackPinnedStateOrderingAndPreservesProjections() async throws {
        let project = makeProject(id: "proj_archive_rollback")
        let older = makeSession(
            id: "session_archive_failure",
            projectID: project.id,
            title: "归档失败会话",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = makeSession(
            id: "session_archive_newer",
            projectID: project.id,
            title: "较新会话",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let gate = SessionArchiveResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [older, newer],
            sessionArchiveHandler: { id, archived in
                try await gate.response(id: id, archived: archived)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [older, newer]
        store.toggleSessionPinned(older)
        store.setSessionListProjection(
            sessionID: older.id,
            preview: "本地待确认预览",
            source: .localUser,
            clientMessageID: "archive-projection"
        )

        let task = Task { await store.setSessionArchivedRemote(older, archived: true) }
        await gate.waitForRequestCount(1)

        XCTAssertTrue(store.isSessionArchiveMutationPending(older.id))
        XCTAssertTrue(store.isSessionArchived(older.id))
        XCTAssertFalse(store.isSessionPinned(older.id))
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [newer.id])
        XCTAssertNotNil(store.listProjectionBySessionID[older.id], "乐观归档不能提前释放预览投影")
        XCTAssertNotNil(store.recentActivityProjectionBySessionID[older.id], "乐观归档不能提前释放最近排序投影")

        await gate.fail(
            id: older.id,
            archived: true,
            error: AgentAPIError.server(status: 500, message: "archive rejected")
        )
        let didArchive = await task.value
        XCTAssertFalse(didArchive)

        XCTAssertFalse(store.isSessionArchiveMutationPending(older.id))
        XCTAssertFalse(store.isSessionArchived(older.id))
        XCTAssertTrue(store.isSessionPinned(older.id))
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [older.id, newer.id])
        XCTAssertNotNil(store.listProjectionBySessionID[older.id])
        XCTAssertNotNil(store.recentActivityProjectionBySessionID[older.id])
        XCTAssertNotNil(store.errorMessage)
    }

    func testUnarchiveFailureRollsBackToArchivedVisibility() async {
        let project = makeProject(id: "proj_unarchive_rollback")
        let session = makeSession(
            id: "session_unarchive_failure",
            projectID: project.id,
            title: "取消归档失败会话",
            status: "history",
            source: "codex"
        )
        let gate = SessionArchiveResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            sessionArchiveHandler: { id, archived in
                try await gate.response(id: id, archived: archived)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]
        store.toggleSessionArchived(session)
        XCTAssertTrue(store.sessionLibrarySessions.isEmpty)

        let task = Task { await store.setSessionArchivedRemote(session, archived: false) }
        await gate.waitForRequestCount(1)
        XCTAssertFalse(store.isSessionArchived(session.id))
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [session.id])

        await gate.fail(
            id: session.id,
            archived: false,
            error: AgentAPIError.server(status: 500, message: "unarchive rejected")
        )
        let didUnarchive = await task.value
        XCTAssertFalse(didUnarchive)

        XCTAssertTrue(store.isSessionArchived(session.id))
        XCTAssertTrue(store.sessionLibrarySessions.isEmpty)
        XCTAssertFalse(store.isSessionArchiveMutationPending(session.id))
        XCTAssertNotNil(store.errorMessage)
    }

    func testArchivePendingSuppressesDuplicateButAllowsDifferentSessionsConcurrently() async {
        let project = makeProject(id: "proj_archive_pending")
        let first = makeSession(
            id: "session_archive_first",
            projectID: project.id,
            title: "第一条",
            status: "history",
            source: "codex"
        )
        let second = makeSession(
            id: "session_archive_second",
            projectID: project.id,
            title: "第二条",
            status: "history",
            source: "codex"
        )
        let gate = SessionArchiveResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [first, second],
            sessionArchiveHandler: { id, archived in
                try await gate.response(id: id, archived: archived)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [first, second]
        store.setSessionListProjection(
            sessionID: first.id,
            preview: "成功后释放",
            source: .localUser,
            clientMessageID: "archive-success-projection"
        )

        let firstTask = Task { await store.setSessionArchivedRemote(first, archived: true) }
        await gate.waitForRequestCount(1)
        let duplicateResult = await store.setSessionArchivedRemote(first, archived: true)
        let secondTask = Task { await store.setSessionArchivedRemote(second, archived: true) }
        await gate.waitForRequestCount(2)

        XCTAssertFalse(duplicateResult)
        XCTAssertTrue(store.isSessionArchiveMutationPending(first.id))
        XCTAssertTrue(store.isSessionArchiveMutationPending(second.id))
        XCTAssertEqual(client.requestedSessionArchives.count, 2)

        await gate.resolve(id: first.id, archived: true)
        await gate.resolve(id: second.id, archived: true)
        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertFalse(store.isSessionArchiveMutationPending(first.id))
        XCTAssertFalse(store.isSessionArchiveMutationPending(second.id))
        XCTAssertNil(store.listProjectionBySessionID[first.id])
        XCTAssertNil(store.recentActivityProjectionBySessionID[first.id])
    }

    func testArchivePendingPreferenceSaveAndRestartKeepCommittedStateUntilSuccess() async throws {
        let project = makeProject(id: "proj_archive_persistence_boundary")
        let session = makeSession(
            id: "session_archive_persistence_boundary",
            projectID: project.id,
            title: "归档持久化边界",
            status: "history",
            source: "codex"
        )
        let gate = SessionArchiveResponseGate()
        let appStore = makeIsolatedAppStore()
        let preferences = makeSessionListPreferenceStore()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            sessionArchiveHandler: { id, archived in
                try await gate.response(id: id, archived: archived)
            }
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionListPreferenceStore: preferences,
            clientFactory: { client }
        )
        store.sessions = [session]
        store.toggleSessionPinned(session)

        let task = Task { await store.setSessionArchivedRemote(session, archived: true) }
        await gate.waitForRequestCount(1)
        XCTAssertTrue(store.isSessionArchived(session.id), "内存应立即显示乐观归档")
        XCTAssertFalse(store.isSessionPinned(session.id))

        // 模拟 pending 期间另一项偏好触发整份保存；磁盘仍必须保留远端已确认的 before。
        store.saveSessionListPreferences()
        let pendingPreferences = preferences.load(profileID: appStore.notificationRoutingProfileID)
        XCTAssertFalse(pendingPreferences.archivedSessionIDs.contains(session.id))
        XCTAssertTrue(pendingPreferences.pinnedSessionIDs.contains(session.id))

        let restartedStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionListPreferenceStore: preferences,
            clientFactory: { client }
        )
        restartedStore.reloadSessionListPreferences()
        XCTAssertFalse(restartedStore.isSessionArchived(session.id), "重启只能恢复远端已确认状态")
        XCTAssertTrue(restartedStore.isSessionPinned(session.id))

        await gate.resolve(id: session.id, archived: true)
        let didArchive = await task.value
        XCTAssertTrue(didArchive)
        let committedPreferences = preferences.load(profileID: appStore.notificationRoutingProfileID)
        XCTAssertTrue(committedPreferences.archivedSessionIDs.contains(session.id))
        XCTAssertFalse(committedPreferences.pinnedSessionIDs.contains(session.id))
    }

    func testConnectionClearKeepsArchivePendingAndStaleHostFailureRollsBackPersistedProfile() async throws {
        let project = makeProject(id: "proj_archive_switch")
        let session = makeSession(
            id: "session_archive_switch",
            projectID: project.id,
            title: "连接切换中的归档",
            status: "history",
            source: "codex"
        )
        let gate = SessionArchiveResponseGate()
        let appStore = makeIsolatedAppStore()
        let preferences = makeSessionListPreferenceStore()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            sessionArchiveHandler: { id, archived in
                try await gate.response(id: id, archived: archived)
            }
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionListPreferenceStore: preferences,
            clientFactory: { client }
        )
        store.sessions = [session]
        store.toggleSessionPinned(session)
        let oldHostScope = appStore.activeHostScope
        let oldProfileID = appStore.notificationRoutingProfileID
        let oldKey = ScopedSessionID(profileID: oldProfileID, sessionID: session.id)

        let task = Task { await store.setSessionArchivedRemote(session, archived: true) }
        await gate.waitForRequestCount(1)
        XCTAssertFalse(
            preferences.load(profileID: oldProfileID)
                .archivedSessionIDs.contains(session.id)
        )
        XCTAssertTrue(
            preferences.load(profileID: oldProfileID)
                .pinnedSessionIDs.contains(session.id),
            "远端确认前磁盘必须保留 committed before"
        )

        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "mac-b", displayName: "Mac B"),
            installationID: "installation-b"
        ))
        XCTAssertNotEqual(appStore.activeHostScope, oldHostScope)
        store.clearConnectionData()
        XCTAssertTrue(
            store.pendingSessionArchiveMutationKeys.contains(oldKey),
            "连接清理不能释放旧 Profile+Session 的远端事务锁"
        )
        XCTAssertEqual(client.requestedSessionArchives.count, 1)

        await gate.fail(
            id: session.id,
            archived: true,
            error: AgentAPIError.server(status: 500, message: "stale host failure")
        )
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertFalse(store.pendingSessionArchiveMutationKeys.contains(oldKey))
        let rolledBack = preferences.load(profileID: oldProfileID)
        XCTAssertFalse(rolledBack.archivedSessionIDs.contains(session.id))
        XCTAssertTrue(rolledBack.pinnedSessionIDs.contains(session.id))
        XCTAssertNil(store.errorMessage, "旧 Profile 的失败不能污染当前 Host UI")
    }

    func testStaleHostArchiveSuccessKeepsOldProfileCommitAndDoesNotPolluteCurrentProfile() async throws {
        let project = makeProject(id: "proj_archive_switch_success")
        let session = makeSession(
            id: "session_archive_switch_success",
            projectID: project.id,
            title: "切换连接后的归档成功",
            status: "history",
            source: "codex"
        )
        let gate = SessionArchiveResponseGate()
        let appStore = makeIsolatedAppStore()
        let preferences = makeSessionListPreferenceStore()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            sessionArchiveHandler: { id, archived in
                try await gate.response(id: id, archived: archived)
            }
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionListPreferenceStore: preferences,
            clientFactory: { client }
        )
        store.sessions = [session]
        let oldProfileID = appStore.notificationRoutingProfileID
        let oldKey = ScopedSessionID(profileID: oldProfileID, sessionID: session.id)

        let task = Task { await store.setSessionArchivedRemote(session, archived: true) }
        await gate.waitForRequestCount(1)

        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.21:8787",
            token: "token-c",
            profileTarget: .newProfile(id: "mac-c", displayName: "Mac C"),
            installationID: "installation-c"
        ))
        let currentProfileID = appStore.notificationRoutingProfileID
        store.clearConnectionData()
        XCTAssertTrue(store.pendingSessionArchiveMutationKeys.contains(oldKey))

        await gate.resolve(id: session.id, archived: true)
        let didApplyToCurrentHost = await task.value

        XCTAssertFalse(didApplyToCurrentHost, "旧 Host 成功不能被当成当前 Host 的 UI 提交")
        XCTAssertFalse(store.pendingSessionArchiveMutationKeys.contains(oldKey))
        XCTAssertTrue(
            preferences.load(profileID: oldProfileID).archivedSessionIDs.contains(session.id),
            "服务端成功后旧 Profile 的乐观归档应成为最终持久状态"
        )
        XCTAssertFalse(
            preferences.load(profileID: currentProfileID).archivedSessionIDs.contains(session.id),
            "旧 Host 成功不能污染当前 Profile"
        )
        XCTAssertNil(store.errorMessage)
    }

    func testArchiveOldTokenCannotClearNewPendingAndPendingArchiveBlocksPin() async {
        let project = makeProject(id: "proj_archive_token")
        let session = makeSession(
            id: "session_archive_token",
            projectID: project.id,
            title: "事务代次",
            status: "history",
            source: "codex"
        )
        let casSession = makeSession(
            id: "session_archive_cas",
            projectID: project.id,
            title: "CAS 回滚",
            status: "history",
            source: "codex"
        )
        let gate = SessionArchiveResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session, casSession],
            sessionArchiveHandler: { id, archived in
                try await gate.response(id: id, archived: archived)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session, casSession]

        let oldTask = Task { await store.setSessionArchivedRemote(session, archived: true) }
        await gate.waitForRequestCount(1)
        let key = ScopedSessionID(
            profileID: store.appStore.notificationRoutingProfileID,
            sessionID: session.id
        )
        guard let oldMutation = store.sessionArchiveMutationsByKey[key] else {
            XCTFail("应记录首个归档事务")
            return
        }
        let newerMutation = SessionArchiveMutation(
            token: oldMutation.token + 1,
            hostScope: oldMutation.hostScope,
            before: oldMutation.before,
            target: oldMutation.target
        )
        store.sessionArchiveMutationToken = newerMutation.token
        store.sessionArchiveMutationsByKey[key] = newerMutation

        await gate.resolve(id: session.id, archived: true)
        let oldResult = await oldTask.value
        XCTAssertFalse(oldResult, "被新 token 取代的旧结果不能再写状态")
        XCTAssertTrue(store.isSessionArchiveMutationPending(session.id), "旧 defer 不能清除新事务 pending")
        store.sessionArchiveMutationsByKey.removeValue(forKey: key)
        store.removePendingSessionArchiveMutationKey(key)

        let casTask = Task { await store.setSessionArchivedRemote(casSession, archived: true) }
        await gate.waitForRequestCount(2)
        store.toggleSessionPinned(casSession)
        XCTAssertFalse(store.isSessionPinned(casSession.id), "pending 期间不能用本地置顶覆盖远端归档事务")
        XCTAssertTrue(store.isSessionArchived(casSession.id))
        await gate.fail(
            id: casSession.id,
            archived: true,
            error: AgentAPIError.server(status: 500, message: "late archive failure")
        )
        let casResult = await casTask.value
        XCTAssertFalse(casResult)
        XCTAssertFalse(store.isSessionPinned(casSession.id))
        XCTAssertFalse(store.isSessionArchived(casSession.id))
    }

    func testArchivedSessionMustUnarchiveRemotelyBeforePinning() async {
        let project = makeProject(id: "proj_archive_before_pin")
        let session = makeSession(
            id: "session_archive_before_pin",
            projectID: project.id,
            title: "先取消归档再置顶",
            status: "history",
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            sessionArchiveResults: [session.id: .success(())]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]

        let didArchive = await store.setSessionArchivedRemote(session, archived: true)
        XCTAssertTrue(didArchive)
        store.toggleSessionPinned(session)
        XCTAssertTrue(store.isSessionArchived(session.id))
        XCTAssertFalse(store.isSessionPinned(session.id), "已归档时置顶必须保持为无操作")

        let didUnarchive = await store.setSessionArchivedRemote(session, archived: false)
        XCTAssertTrue(didUnarchive)
        store.toggleSessionPinned(session)
        XCTAssertFalse(store.isSessionArchived(session.id))
        XCTAssertTrue(store.isSessionPinned(session.id))
        XCTAssertEqual(client.requestedSessionArchives, [
            RequestedSessionArchive(id: session.id, archived: true),
            RequestedSessionArchive(id: session.id, archived: false)
        ])
    }

    func testSessionStoreSchedulesAndClearsLocalReminder() async throws {
        let project = makeProject(id: "proj_reminder")
        let session = makeSession(
            id: "session_reminder",
            projectID: project.id,
            title: "检查结果",
            status: "history",
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [
                project.id: SessionsPage(sessions: [session])
            ]
        )
        let appStore = makeIsolatedAppStore()
        let reminderStore = makeSessionReminderStore()
        let scheduler = FakeSessionReminderScheduler()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [AgentWorkspace(project: project)], endpoint: appStore.endpoint),
            sessionReminderStore: reminderStore,
            sessionReminderScheduler: scheduler,
            clientFactory: { client }
        )
        let now = Date(timeIntervalSince1970: 1_000)

        await store.refreshAll(autoAttach: false)
        await store.scheduleSessionReminder(session, after: 30 * 60, now: now)

        let reminder = try XCTUnwrap(store.sessionReminder(for: session.id))
        XCTAssertEqual(reminder.sessionID, session.id)
        XCTAssertEqual(reminder.title, session.title)
        XCTAssertEqual(reminder.fireAt, now.addingTimeInterval(30 * 60))
        XCTAssertEqual(scheduler.scheduled, [reminder])
        XCTAssertEqual(
            reminderStore.load(profileID: appStore.notificationRoutingProfileID)[session.id],
            reminder
        )

        store.clearSessionReminder(session)

        XCTAssertNil(store.sessionReminder(for: session.id))
        XCTAssertEqual(scheduler.canceledSessionIDs, [session.id])
        XCTAssertTrue(reminderStore.load(profileID: appStore.notificationRoutingProfileID).isEmpty)
    }

    func testSessionReminderPermissionDeniedKeepsLocalStateButPastRequestDoesNotPersist() async throws {
        let project = makeProject(id: "proj_reminder_permission")
        let session = makeSession(
            id: "session_reminder_permission",
            projectID: project.id,
            title: "检查权限结果",
            status: "history",
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        let reminderStore = makeSessionReminderStore()
        let scheduler = FakeSessionReminderScheduler(scheduleOutcome: .permissionDenied)
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionReminderStore: reminderStore,
            sessionReminderScheduler: scheduler,
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [session]) }
        )
        let now = Date()

        await store.scheduleSessionReminder(session, after: 30 * 60, now: now)

        let saved = try XCTUnwrap(store.sessionReminder(for: session.id))
        XCTAssertEqual(
            reminderStore.load(profileID: appStore.notificationRoutingProfileID)[session.id],
            saved
        )
        XCTAssertEqual(scheduler.scheduled, [saved])
        XCTAssertEqual(store.statusMessage, L10n.text("ui.the_in_app_reminder_has_been_saved_the"))
        XCTAssertNotEqual(store.statusMessage, L10n.format("ui.reminder_value_has_been_set", session.title))

        await store.scheduleSessionReminder(session, after: -1, now: now)

        XCTAssertNil(store.sessionReminder(for: session.id))
        XCTAssertTrue(reminderStore.load(profileID: appStore.notificationRoutingProfileID).isEmpty)
        XCTAssertEqual(scheduler.scheduled, [saved], "已过期请求不能再进入系统通知调度")
        XCTAssertEqual(scheduler.canceledSessionIDs, [session.id])
        XCTAssertEqual(store.statusMessage, L10n.format("ui.the_reminder_time_has_passed_and_the_reminder", session.title))
    }

    func testSessionReminderReloadAndForegroundPruneExpiredStateWithoutTimer() async throws {
        let suiteName = "ConversationDataFlowTests.ReminderPrune.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        let reminderStore = SessionReminderStore(defaults: defaults, key: "test.sessionReminders")
        var now = Date(timeIntervalSince1970: 1_000)
        let expiredAtReload = SessionReminder(
            sessionID: "reminder_expired_reload",
            title: "启动前已到期",
            fireAt: now.addingTimeInterval(-1),
            createdAt: now.addingTimeInterval(-100)
        )
        let expiresInBackground = SessionReminder(
            sessionID: "reminder_expires_background",
            title: "后台期间到期",
            fireAt: now.addingTimeInterval(60),
            createdAt: now
        )
        reminderStore.save(
            [
                expiredAtReload.sessionID: expiredAtReload,
                expiresInBackground.sessionID: expiresInBackground
            ],
            profileID: appStore.notificationRoutingProfileID
        )
        let scheduler = FakeSessionReminderScheduler()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionReminderStore: reminderStore,
            sessionReminderScheduler: scheduler,
            sessionReminderNow: { now },
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )

        XCTAssertNil(store.sessionReminder(for: expiredAtReload.sessionID))
        XCTAssertEqual(store.sessionReminder(for: expiresInBackground.sessionID), expiresInBackground)
        XCTAssertEqual(
            reminderStore.load(profileID: appStore.notificationRoutingProfileID),
            [expiresInBackground.sessionID: expiresInBackground]
        )
        XCTAssertEqual(scheduler.canceledSessionIDs, [expiredAtReload.sessionID])

        now = now.addingTimeInterval(120)
        await store.resumeFromForeground()

        XCTAssertNil(store.sessionReminder(for: expiresInBackground.sessionID))
        XCTAssertTrue(reminderStore.load(profileID: appStore.notificationRoutingProfileID).isEmpty)
        XCTAssertEqual(
            scheduler.canceledSessionIDs,
            [expiredAtReload.sessionID, expiresInBackground.sessionID]
        )
    }

    func testNotificationPayloadUsesActiveProfileAndCurrentMacRefreshSelectsSession() async throws {
        let suiteName = "ConversationDataFlowTests.NotificationCurrentProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-current",
            displayName: "当前 Mac",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("current-secret-token".utf8), account: "agentd-profile.\(profile.id)")
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let project = makeProject(id: "proj_notification_current")
        let session = makeSession(
            id: "session_notification_current",
            projectID: project.id,
            title: "通知打开目标",
            status: "history",
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [project.id: SessionsPage(sessions: [session])]
        )
        let scheduler = FakeSessionReminderScheduler()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionReminderScheduler: scheduler,
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )

        await store.scheduleSessionReminder(session, after: 600, now: Date(timeIntervalSince1970: 1_000))
        let route = try XCTUnwrap(scheduler.reminderRoutes.first)
        XCTAssertEqual(route.version, SessionNotificationRoute.currentVersion)
        XCTAssertEqual(route.profileID, profile.id)
        XCTAssertEqual(route.projectID, project.id)
        XCTAssertEqual(route.sessionID, session.id)
        XCTAssertEqual(SessionNotificationRoute(userInfo: route.userInfo), route)
        XCTAssertFalse(String(describing: route.userInfo).contains("current-secret-token"), "系统通知 payload 绝不能包含 Token")

        let outcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(client.requestedProjectIDs, [project.id], "暂未加载时只做一次当前工作区首屏刷新")
        XCTAssertEqual(appStore.activeConnectionProfileID, profile.id)
    }

    func testNotificationFastRefreshPreservesAuthorityAndInvalidatesWindowForLateChildren() async {
        let project = makeProject(id: "proj_notification_late_children")
        let workspace = AgentWorkspace(project: project)
        let authoritativeRoots = (0..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(
                id: "notification_authoritative_root_\(index)",
                projectID: project.id,
                title: "权威通知会话 \(index)",
                status: index == 0 ? "running" : "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(200 - index))
            )
        }
        let staleShared = makeSession(
            id: authoritativeRoots[0].id,
            projectID: project.id,
            title: "过期通知标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let lateChildren = (1...2).map { index in
            AgentSession(
                id: authoritativeRoots[index].id,
                projectID: project.id,
                project: project.id,
                dir: project.path,
                title: "通知补认子会话 \(index)",
                status: "history",
                source: "codex",
                resumeID: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(300 - index)),
                parentThreadID: authoritativeRoots[0].id,
                isSubagent: true,
                canAcceptDirectInput: false
            )
        }
        let notificationTarget = makeSession(
            id: "notification_missing_target",
            projectID: project.id,
            title: "通知补入目标",
            status: "history",
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [
                project.id: SessionsPage(
                    sessions: [staleShared] + lateChildren + [notificationTarget],
                    nextCursor: "notification-fast-stale",
                    hasMore: true
                )
            ]
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        store.projects = [project]
        store.recentWorkspaces = [workspace]
        store.sidebarProjects = [project]
        store.applyWorkspaceSessionFirstPage(
            workspace: workspace,
            page: SessionsPage(
                sessions: authoritativeRoots,
                nextCursor: "notification-authoritative-cursor",
                hasMore: true
            ),
            consistency: .authoritative
        )
        let route = SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: project.id,
            sessionID: notificationTarget.id
        )

        let outcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(store.selectedSessionID, notificationTarget.id)
        XCTAssertEqual(store.sessionsByID[authoritativeRoots[0].id]?.title, authoritativeRoots[0].title)
        XCTAssertEqual(store.sessionsByID[authoritativeRoots[0].id]?.status, authoritativeRoots[0].status)
        for child in lateChildren {
            XCTAssertTrue(store.sessionsByID[child.id]?.isSubagentThread == true)
            XCTAssertFalse(store.sessions(forProjectID: project.id).contains { $0.id == child.id })
        }
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "notification-authoritative-cursor")
        XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
        XCTAssertEqual(client.requestedProjectIDs, [project.id])
    }

    func testNotificationFromOtherMacOnlyPromptsForProfileSwitch() async throws {
        let suiteName = "ConversationDataFlowTests.NotificationOtherProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(id: "mac-a", displayName: "当前 Mac", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: nil),
            ConnectionProfile(id: "mac-b", displayName: "备用 Mac", endpoint: "http://100.64.0.20:8787", lastSuccessfulAt: nil)
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profiles[0].id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profiles[0].endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let client = MockSessionStoreClient(projects: [], sessions: [])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        let generationBeforeTap = appStore.connectionGeneration
        let route = SessionNotificationRoute.current(
            profileID: "mac-b",
            projectID: "proj_other_mac",
            sessionID: "session_other_mac"
        )

        let outcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(outcome, .requiresProfileSwitch(displayName: "备用 Mac"))
        XCTAssertEqual(appStore.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(appStore.connectionGeneration, generationBeforeTap)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertTrue(client.requestedProjectIDs.isEmpty, "错 Mac 通知不能向当前或目标 Mac 发任何会话请求")
        XCTAssertTrue(store.statusMessage?.contains("切换连接档案") == true)
    }

    func testNotificationLateRefreshDoesNotOverrideLaterUserSelection() async {
        let project = makeProject(id: "proj_notification_selection_lease")
        let target = makeSession(
            id: "thread_notification_target",
            projectID: project.id,
            title: "通知 A",
            status: "history",
            source: "codex"
        )
        let selected = makeSession(
            id: "thread_notification_selected",
            projectID: project.id,
            title: "用户 B",
            status: "history",
            source: "codex"
        )
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: [target]),
            blockOnCall: 1
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        store.projects = [project]
        store.recentWorkspaces = [AgentWorkspace(project: project)]
        store.sidebarProjects = [project]
        store.sessions = [selected]
        await store.selectSession(selected)
        let route = SessionNotificationRoute.current(
            profileID: appStore.notificationRoutingProfileID,
            projectID: project.id,
            sessionID: target.id
        )

        let notificationTask = Task { await store.openSessionFromNotification(route) }
        await client.waitForBlockedSessionListRefresh()
        await store.selectSession(selected)
        client.releaseBlockedSessionListRefresh()
        let outcome = await notificationTask.value

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(store.selectedSessionID, selected.id)
        XCTAssertEqual(store.connectedSessionID, selected.id)
        XCTAssertTrue(store.sessions.contains { $0.id == target.id }, "通知目标仍应合并进索引")
    }

    func testNotificationResponseAdapterKeepsColdStartPendingAndIgnoresMalformedPayload() throws {
        let adapter = SessionNotificationResponseAdapter()
        XCTAssertFalse(adapter.receive(userInfo: [
            "mimi.route.sessionID": "legacy-session"
        ]))
        XCTAssertFalse(adapter.receive(userInfo: [
            "mimi.route.version": 0,
            "mimi.route.profileID": "mac-a",
            "mimi.route.projectID": "proj-a",
            "mimi.route.sessionID": "session-a"
        ]))
        XCTAssertNil(adapter.pendingRoute, "旧版或畸形 payload 必须安全忽略")

        let route = SessionNotificationRoute.current(
            profileID: "mac-a",
            projectID: "proj-a",
            sessionID: "session-a"
        )
        XCTAssertTrue(adapter.receive(userInfo: route.userInfo))
        XCTAssertEqual(adapter.pendingRoute, route, "冷启动时消费者尚未建立也必须保留一次点击路由")

        adapter.consume(route)
        XCTAssertNil(adapter.pendingRoute)
        adapter.consume(route)
        XCTAssertNil(adapter.pendingRoute, "已消费路由不能重复触发")
    }

    func testNotificationPresentationSilencesOnlyVisibleRuntimeSessionAcrossScenes() {
        let adapter = SessionNotificationResponseAdapter()
        let currentRoute = SessionNotificationRoute.current(
            profileID: "mac-a",
            projectID: "proj-a",
            sessionID: "session-a"
        )
        let otherRoute = SessionNotificationRoute.current(
            profileID: "mac-a",
            projectID: "proj-b",
            sessionID: "session-b"
        )
        let currentSceneID = UUID()
        let otherSceneID = UUID()
        let runtimeIDs = [
            "approval:session-a:request-1",
            "user-input:session-a:request-2",
            "completed:session-a:turn-1",
            "failed:session-a:turn-2"
        ].map {
            UserNotificationSessionReminderScheduler.runtimeNotificationID(
                profileID: "mac-a",
                id: $0
            )
        }
        let runtimeID = runtimeIDs[0]
        let defaultOptions: UNNotificationPresentationOptions = [.banner, .sound]

        adapter.setVisibleSessionRoute(currentRoute, for: currentSceneID)
        adapter.setVisibleSessionRoute(otherRoute, for: otherSceneID)
        for identifier in runtimeIDs {
            XCTAssertEqual(
                adapter.presentationOptions(
                    forNotificationIdentifier: identifier,
                    userInfo: currentRoute.userInfo
                ),
                [],
                "审批、补充信息、完成和失败通知都应使用同一静默策略"
            )
        }
        XCTAssertEqual(
            adapter.presentationOptions(
                forNotificationIdentifier: runtimeID,
                userInfo: otherRoute.userInfo
            ),
            [],
            "不同 Scene 各自显示的会话都应参与静默判断"
        )

        adapter.setVisibleSessionRoute(nil, for: currentSceneID)
        XCTAssertEqual(
            adapter.presentationOptions(
                forNotificationIdentifier: runtimeID,
                userInfo: currentRoute.userInfo
            ),
            defaultOptions,
            "Scene 离开或销毁后不能残留旧可见状态"
        )
        XCTAssertEqual(
            adapter.presentationOptions(
                forNotificationIdentifier: UserNotificationSessionReminderScheduler.notificationID(
                    profileID: currentRoute.profileID,
                    sessionID: currentRoute.sessionID
                ),
                userInfo: otherRoute.userInfo
            ),
            defaultOptions,
            "定时提醒即使目标会话可见也保持系统展示"
        )
        XCTAssertEqual(
            adapter.presentationOptions(
                forNotificationIdentifier: runtimeID,
                userInfo: ["mimi.route.sessionID": currentRoute.sessionID]
            ),
            defaultOptions,
            "畸形或旧版路由必须默认继续提醒"
        )
    }

    func testPreviewFileWritesDecodedPayloadToTemporaryFile() async throws {
        let filePath = "/repo/report.pdf"
        let payload = Data("preview-payload".utf8)
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            fileReadResults: [
                filePath: .success(FileReadResponse(
                    path: filePath,
                    name: "../report.pdf",
                    contentType: "application/pdf",
                    size: Int64(payload.count),
                    contentBase64: payload.base64EncodedString()
                ))
            ]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let url = try await store.previewFile(path: filePath)
        XCTAssertEqual(client.requestedFileReadPaths, [filePath])
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-report.pdf"))
        XCTAssertNil(store.errorMessage)
    }

    func testPreviewHistoryMediaWritesDecodedPayloadToTemporaryFile() async throws {
        let mediaID = "media-123"
        let payload = Data("history-image-payload".utf8)
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            historyMediaResults: [
                mediaID: .success(FileReadResponse(
                    path: "agentd-history-media://\(mediaID)",
                    name: "history-image.png",
                    contentType: "image/png",
                    size: Int64(payload.count),
                    contentBase64: payload.base64EncodedString()
                ))
            ]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let url = try await store.previewHistoryMedia(id: mediaID)
        XCTAssertEqual(client.requestedHistoryMediaIDs, [mediaID])
        XCTAssertEqual(client.requestedFileReadPaths, [])
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-history-image.png"))
        XCTAssertNil(store.errorMessage)
    }

    func testPreviewHistoryOutputWritesDecodedPayloadToTemporaryFileOnDemand() async throws {
        let outputID = "output-123"
        let payload = Data("full command output\nline 2".utf8)
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            historyOutputResults: [
                outputID: .success(FileReadResponse(
                    path: "agentd-history-output://\(outputID)",
                    name: "history-output.txt",
                    contentType: "text/plain; charset=utf-8",
                    size: Int64(payload.count),
                    contentBase64: payload.base64EncodedString()
                ))
            ]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let url = try await store.previewHistoryOutput(id: outputID)

        XCTAssertEqual(client.requestedHistoryOutputIDs, [outputID])
        XCTAssertEqual(client.requestedHistoryMediaIDs, [])
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-history-output.txt"))
        XCTAssertNil(store.errorMessage)
    }

    func testWorkspaceLoadFailureMarksUnavailableWhenResolveRejects() async {
        // 避免 macOS 将 /tmp 规范化为 /private/tmp，夹具应验证业务状态而非本机路径别名。
        let rootProject = AgentProject(
            id: "proj_root",
            name: "proj_root",
            path: "/Users/mimi-tests/proj_root"
        )
        let workspace = makeChildWorkspace(id: "ws_gone", name: "gone", root: rootProject)
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            workspaceSessionsError: [workspace.id: AgentAPIError.server(status: 403, message: "cwd 必须来自 projects allowlist")],
            resolveResults: [workspace.path: .failure(AgentAPIError.server(status: 403, message: "路径不在允许范围内或不可访问"))]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)

        // 会话加载失败 + resolve 明确 4xx → 单独标记该工作区不可用，且不冒泡成全局错误。
        XCTAssertTrue(store.isWorkspaceUnavailable(workspace.id))
        XCTAssertEqual(client.requestedResolvePaths, [workspace.path])
        XCTAssertNil(store.errorMessage)
    }

    func testWorkspaceLoadFailureStaysTransientWhenResolveSucceeds() async {
        let rootProject = AgentProject(
            id: "proj_root",
            name: "proj_root",
            path: "/Users/mimi-tests/proj_root"
        )
        let workspace = makeChildWorkspace(id: "ws_flaky", name: "flaky", root: rootProject)
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            workspaceSessionsError: [workspace.id: AgentAPIError.server(status: 502, message: "连接 app-server gateway 上游失败")],
            resolveResults: [workspace.path: .success(workspace)]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)

        // resolve 仍成功 → 判定为瞬时故障：不标记不可用，仍按普通错误处理以便重试。
        XCTAssertFalse(store.isWorkspaceUnavailable(workspace.id))
        XCTAssertEqual(client.requestedResolvePaths, [workspace.path])
        XCTAssertNotNil(store.errorMessage)
    }

    func testForgetWorkspaceClearsUnavailableMark() async {
        let rootProject = AgentProject(
            id: "proj_root",
            name: "proj_root",
            path: "/Users/mimi-tests/proj_root"
        )
        let workspace = makeChildWorkspace(id: "ws_gone", name: "gone", root: rootProject)
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            workspaceSessionsError: [workspace.id: AgentAPIError.server(status: 403, message: "denied")],
            resolveResults: [workspace.path: .failure(AgentAPIError.server(status: 403, message: "denied"))]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)
        XCTAssertTrue(store.isWorkspaceUnavailable(workspace.id))

        store.forgetWorkspace(workspace.project)

        XCTAssertFalse(store.isWorkspaceUnavailable(workspace.id))
        XCTAssertTrue(store.sidebarProjects.isEmpty)
    }

    func testSessionStoreAutoAttachKeepsExplicitHistorySelection() async {
        let project = makeProject(id: "proj_1")
        let selectedHistory = makeSession(id: "codex_selected", projectID: project.id, title: "用户点选的历史", status: "history", source: "codex", resumeID: "selected")
        let latestRunning = makeSession(id: "sess_latest", projectID: project.id, title: "最新运行会话", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [latestRunning, selectedHistory])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        XCTAssertNil(store.selectedSessionID)
        await store.selectSession(selectedHistory)
        await store.refreshAll(autoAttach: true)

        XCTAssertEqual(client.requestedProjectIDs.compactMap { $0 }, [project.id])
        XCTAssertEqual(store.selectedSessionID, selectedHistory.id)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertTrue(conversationStore.hasLoadedHistory(sessionID: selectedHistory.id))
    }

    func testSessionStoreAutoAttachRefreshesRunningSessionWithoutSelectingIt() async throws {
        let project = makeProject(id: "proj_auto_attach")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史会话", status: "history", source: "codex", resumeID: "history")
        let running = makeSession(id: "sess_auto_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [history, running])
        var sockets: [MockWebSocketClient] = []
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project, lastOpenedAt: Date(timeIntervalSince1970: 10))],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: true)

        XCTAssertNil(store.selectedSessionID)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertFalse(store.isSelectedSessionObserving)
        XCTAssertTrue(sockets.isEmpty)
        XCTAssertEqual(store.webSocketStatus, .disconnected)
    }

    func testForegroundResumeKeepsSessionListVisibleWhenRunningSessionExists() async {
        let project = makeProject(id: "proj_foreground_list")
        let running = makeSession(
            id: "sess_foreground_list",
            projectID: project.id,
            title: "运行中",
            status: "running",
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: true)
        store.suspendForBackground()
        await store.resumeFromForeground()

        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertTrue(sockets.isEmpty)
        XCTAssertEqual(store.webSocketStatus, .disconnected)
    }

    func testBootstrapRestoresOnlyExplicitRunningSessionAndCreatesOneSocket() async {
        let project = makeProject(id: "proj_explicit_restore")
        let requested = makeSession(
            id: "sess_explicit_restore",
            projectID: project.id,
            title: "明确恢复的详情",
            status: "running",
            source: "codex"
        )
        let otherRunning = makeSession(
            id: "sess_other_running",
            projectID: project.id,
            title: "不能抢导航",
            status: "running",
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [otherRunning, requested],
            messagesResult: []
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        store.takeOverSession(requested)
        let snapshot = SessionRestoreSnapshot(endpoint: appStore.endpoint, session: requested)

        let didRestore = await store.bootstrap(restoring: snapshot)

        XCTAssertTrue(didRestore)
        XCTAssertEqual(store.selectedSessionID, requested.id)
        XCTAssertEqual(store.selectedProjectID, requested.projectID)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets.first?.connectedSessionIDs, [requested.id])
    }

    func testColdStartResolvedCandidateCannotCommitAfterUserSelectsAnotherSession() async throws {
        let project = makeProject(id: "proj_cold_restore_lease")
        let restored = makeSession(
            id: "thread_cold_restore_a",
            projectID: project.id,
            title: "恢复 A",
            status: "history",
            source: "codex"
        )
        let selected = makeSession(
            id: "thread_cold_restore_b",
            projectID: project.id,
            title: "用户 B",
            status: "history",
            source: "codex"
        )
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: [restored]),
            blockOnCall: 1
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        store.projects = [project]
        store.reloadRecentWorkspaces()
        store.sessions = [selected]
        let snapshot = SessionRestoreSnapshot(endpoint: appStore.endpoint, session: restored)
        let restoreLease = store.currentSelectionLease()

        let resolveTask = Task { await store.resolveSessionForRestore(snapshot) }
        await client.waitForBlockedSessionListRefresh()
        await store.selectSession(selected)
        client.releaseBlockedSessionListRefresh()
        let resolvedCandidate = await resolveTask.value
        let candidate = try XCTUnwrap(resolvedCandidate)
        let didRestore = await store.selectSession(
            candidate,
            reason: .restoration,
            ifCurrent: restoreLease
        )

        XCTAssertFalse(didRestore)
        XCTAssertEqual(store.selectedSessionID, selected.id)
        XCTAssertEqual(store.connectedSessionID, selected.id)
    }

    func testWorkbenchRestorationRouteRoundTripsLocalSessionIDAndSourcePage() throws {
        let route = WorkbenchRestorationRoute.session(
            id: "local:claude:thread:123",
            source: .workspaces
        )

        XCTAssertEqual(
            WorkbenchRestorationRoute(storageValue: route.storageValue),
            route
        )
    }

    func testWorkbenchNavigationBindingSchedulerCommitsVisualStateBeforeCoalescedSideEffects() async {
        let scheduler = WorkbenchNavigationBindingScheduler()
        let completed = expectation(description: "两个独立控件的最新副作用已提交")
        completed.expectedFulfillmentCount = 2
        var operations: [String] = []
        var selectedTab = "会话"

        scheduler.commit(
            on: .compactTab,
            visualUpdate: {
                selectedTab = "工作区"
                operations.append("视觉：工作区")
                return "过期 Tab 副作用"
            },
            deferredSideEffect: { operation in
                operations.append(operation)
                completed.fulfill()
            }
        )
        scheduler.commit(
            on: .compactTab,
            visualUpdate: {
                selectedTab = "我的"
                operations.append("视觉：我的")
                return "最新 Tab 副作用"
            },
            deferredSideEffect: { operation in
                operations.append(operation)
                completed.fulfill()
            }
        )
        scheduler.commit(
            on: .compactSessionsPath,
            visualUpdate: {
                operations.append("视觉：会话 Path")
                return "会话 Path 副作用"
            },
            deferredSideEffect: { operation in
                operations.append(operation)
                completed.fulfill()
            }
        )

        XCTAssertEqual(selectedTab, "我的")
        XCTAssertEqual(
            operations,
            ["视觉：工作区", "视觉：我的", "视觉：会话 Path"],
            "Binding setter 必须在当前交互事务内提交视觉状态"
        )
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(
            operations,
            [
                "视觉：工作区",
                "视觉：我的",
                "视觉：会话 Path",
                "最新 Tab 副作用",
                "会话 Path 副作用",
            ]
        )
    }

    func testWorkbenchVisibleSessionExcludesMeTabAndRootPages() {
        var state = WorkbenchNavigationState(
            route: .session(id: "session-visible", source: .sessions)
        )

        XCTAssertEqual(
            state.visibleSessionID(usesCompactNavigation: true),
            "session-visible"
        )
        _ = state.reduce(
            .compactTabChanged(.me),
            usesCompactNavigation: true,
            selectedSessionID: "session-visible"
        )
        XCTAssertNil(
            state.visibleSessionID(usesCompactNavigation: true),
            "“我的”Tab 会保留会话路由，但会话内容已经不可见"
        )

        _ = state.reduce(
            .compactTabChanged(.sessions),
            usesCompactNavigation: true,
            selectedSessionID: "session-visible"
        )
        XCTAssertEqual(
            state.visibleSessionID(usesCompactNavigation: true),
            "session-visible"
        )
        _ = state.reduce(
            .compactPathChanged(tab: .sessions, path: []),
            usesCompactNavigation: true,
            selectedSessionID: "session-visible"
        )
        XCTAssertNil(
            state.visibleSessionID(usesCompactNavigation: true),
            "返回会话列表后不应再把 selectedSessionID 当作可见详情"
        )
    }

    func testWorkbenchMePreservesCompactRouteAndNavigationStack() {
        var state = WorkbenchNavigationState(
            route: .session(id: "session-visible", source: .workspaces)
        )
        let preservedPath = state.compactWorkspacePath

        let openEffect = state.reduce(
            .compactTabChanged(.me),
            usesCompactNavigation: true,
            selectedSessionID: "session-visible"
        )

        XCTAssertNil(openEffect)
        XCTAssertEqual(state.compactSelectedTab, .me)
        XCTAssertEqual(state.selection, .me)
        XCTAssertEqual(
            state.route,
            .session(id: "session-visible", source: .workspaces)
        )
        XCTAssertEqual(state.compactWorkspacePath, preservedPath)

        let returnEffect = state.reduce(
            .compactTabChanged(.workspaces),
            usesCompactNavigation: true,
            selectedSessionID: "session-visible"
        )
        XCTAssertNil(returnEffect)
        XCTAssertEqual(state.selection, .session("session-visible"))
        XCTAssertEqual(state.compactWorkspacePath, preservedPath)
    }

    func testWorkbenchMeSurvivesRestorationFeedbackInBothLayouts() {
        for usesCompactNavigation in [true, false] {
            var state = WorkbenchNavigationState(route: .sessions)
            _ = state.reduce(
                .open(.me, source: nil),
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: nil
            )

            _ = state.reduce(
                .synchronize(.workspaces),
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: nil
            )

            XCTAssertEqual(state.selection, .me)
            XCTAssertEqual(state.route, .workspaces)
            if usesCompactNavigation {
                XCTAssertEqual(state.compactSelectedTab, .me)
            }
            XCTAssertNil(
                state.visibleSessionID(usesCompactNavigation: usesCompactNavigation)
            )
        }
    }

    func testWorkbenchMeSurvivesBackgroundSelectionCommits() {
        for usesCompactNavigation in [true, false] {
            var state = WorkbenchNavigationState(
                route: .session(id: "session-original", source: .workspaces)
            )
            _ = state.reduce(
                .open(.me, source: nil),
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: "session-original"
            )

            _ = state.reduce(
                .selectionCommitted(SessionSelectionCommit(
                    sequence: 1,
                    projectID: nil,
                    sessionID: "session-replacement",
                    reason: .identityReplacement(previousID: "session-original")
                )),
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: "session-replacement"
            )
            XCTAssertEqual(state.selection, .me)
            XCTAssertEqual(
                state.route,
                .session(id: "session-replacement", source: .workspaces)
            )

            _ = state.reduce(
                .selectionCommitted(SessionSelectionCommit(
                    sequence: 2,
                    projectID: nil,
                    sessionID: nil,
                    reason: .invalidation
                )),
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: nil
            )
            XCTAssertEqual(state.selection, .me)
            XCTAssertEqual(state.route, .workspaces)
            if usesCompactNavigation {
                XCTAssertEqual(state.compactSelectedTab, .me)
            }
        }
    }

    func testAccountTokenUsageMarksNilDailyHistoryUnavailableButKeepsLifetime() async {
        let snapshot = AccountTokenUsageSnapshot(
            summary: AccountTokenUsageSummary(lifetimeTokens: 50_160_000_000),
            dailyUsageBuckets: nil
        )
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            accountTokenUsageHandler: { snapshot }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAccountTokenUsage()

        XCTAssertEqual(store.accountTokenUsage, snapshot)
        XCTAssertEqual(
            store.accountTokenActivity,
            .unsupported,
            "summary 可用但日历史为 nil 时，点格图必须诚实显示不提供历史"
        )
        XCTAssertNil(
            store.accountTokenActivity.displayBuckets,
            "不提供历史时不能给出可画的空数据"
        )
    }

    func testAccountTokenUsageDistinguishesEmptyHistoryFromUnsupported() async {
        let snapshot = AccountTokenUsageSnapshot(
            summary: AccountTokenUsageSummary(lifetimeTokens: 12),
            dailyUsageBuckets: []
        )
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            accountTokenUsageHandler: { snapshot }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAccountTokenUsage()

        guard case .empty = store.accountTokenActivity else {
            return XCTFail("空数组代表接口可用但没有活动，不能与 unsupported 混为一谈")
        }
        XCTAssertEqual(store.accountTokenActivity.displayBuckets, [])
    }

    func testAccountTokenUsageFailureKeepsPreviousBucketsAndMarksThemStale() async {
        let buckets = [AccountTokenUsageDailyBucket(startDate: "2026-08-01", tokens: 42)]
        let outcomes: [AccountTokenUsageFetch] = [
            .snapshot(
                AccountTokenUsageSnapshot(
                    summary: AccountTokenUsageSummary(lifetimeTokens: 42),
                    dailyUsageBuckets: buckets
                )
            ),
            .failed
        ]
        let cursor = FetchOutcomeCursor(outcomes)
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            accountTokenUsageFetchHandler: { await cursor.next() }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAccountTokenUsage()
        XCTAssertEqual(store.accountTokenActivity.displayBuckets, buckets)
        XCTAssertFalse(store.accountTokenActivity.isShowingStaleData)

        await store.refreshAccountTokenUsage()

        XCTAssertEqual(
            store.accountTokenActivity.displayBuckets,
            buckets,
            "刷新失败不该丢掉已经拿到的历史"
        )
        XCTAssertTrue(
            store.accountTokenActivity.isShowingStaleData,
            "失败后仍在画旧网格时必须标记为过期，否则等于把旧数据当成当前值"
        )
    }

    func testAccountTokenActivityEntersLoadingOnlyWithoutDisplayableData() async {
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            accountTokenUsageFetchHandler: { .failed }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        XCTAssertEqual(store.accountTokenActivity, .idle)

        await store.refreshAccountTokenUsage()

        XCTAssertEqual(
            store.accountTokenActivity,
            .failed(previous: nil),
            "没有任何历史时失败必须是纯失败态，不能停留在加载中"
        )
        XCTAssertFalse(store.isRefreshingAccountTokenActivity)
    }

    func testAccountTokenUsageDropsLateResponseAfterHostSwitch() async throws {
        let suiteName = "ConversationSessionStoreTests.TokenUsageHostScope.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gate = AccountTokenUsageResponseGate()
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            accountTokenUsageHandler: {
                await gate.response()
            }
        )
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        let oldSnapshot = AccountTokenUsageSnapshot(
            summary: AccountTokenUsageSummary(lifetimeTokens: 1),
            dailyUsageBuckets: []
        )
        let currentSnapshot = AccountTokenUsageSnapshot(
            summary: AccountTokenUsageSummary(lifetimeTokens: 2),
            dailyUsageBuckets: []
        )

        let refreshTask = Task { @MainActor in
            await store.refreshAccountTokenUsage()
        }
        await gate.waitUntilStarted()

        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "mac-b", displayName: "Mac B"),
            installationID: "installation-b"
        ))
        let newScope = appStore.activeHostScope
        store.accountTokenUsage = currentSnapshot
        store.accountTokenUsageRefreshHostScope = newScope
        store.isRefreshingAccountTokenActivity = true

        await gate.resolve(oldSnapshot)
        await refreshTask.value

        XCTAssertEqual(store.accountTokenUsage, currentSnapshot)
        XCTAssertEqual(store.accountTokenUsageRefreshHostScope, newScope)
        XCTAssertTrue(
            store.isRefreshingAccountTokenActivity,
            "旧主机请求的 defer 不能清掉新主机正在进行的刷新"
        )
    }

    func testWorkbenchNavigationDeduplicatesRepeatedSessionOpen() {
        var state = WorkbenchNavigationState(route: .workspaces)
        let event = WorkbenchNavigationEvent.open(.session("session-1"), source: .workspaces)

        let firstEffect = state.reduce(
            event,
            usesCompactNavigation: true,
            selectedSessionID: nil
        )
        let stateAfterFirstOpen = state
        let routeAfterFirstOpen = state.route
        let routeFeedbackEffect = state.reduce(
            .synchronize(routeAfterFirstOpen),
            usesCompactNavigation: true,
            selectedSessionID: nil
        )
        let repeatedEffect = state.reduce(
            event,
            usesCompactNavigation: true,
            selectedSessionID: nil
        )

        XCTAssertEqual(firstEffect, .selectSession("session-1"))
        XCTAssertNil(routeFeedbackEffect)
        XCTAssertNil(repeatedEffect)
        XCTAssertEqual(state, stateAfterFirstOpen)
        XCTAssertEqual(state.route, .session(id: "session-1", source: .workspaces))
        XCTAssertEqual(state.compactWorkspacePath, [.session("session-1")])
    }

    func testWorkbenchSessionDetailWaitsForMatchingStoreSelection() {
        for source in [WorkbenchRootPage.sessions, .workspaces] {
            var state = WorkbenchNavigationState(route: source == .sessions ? .sessions : .workspaces)

            _ = state.reduce(
                .open(.session("session-target"), source: source),
                usesCompactNavigation: true,
                selectedSessionID: "session-previous"
            )

            XCTAssertFalse(
                state.canPresentSessionDetail(selectedSessionID: "session-previous"),
                "从 \(source) 进入详情后不得短暂展示上一个会话"
            )
            XCTAssertFalse(state.canPresentSessionDetail(selectedSessionID: nil))
            XCTAssertTrue(state.canPresentSessionDetail(selectedSessionID: "session-target"))
        }
    }

    func testWorkbenchNavigationPushesSubagentWhileKeepingParentSelected() {
        var state = WorkbenchNavigationState(
            route: .session(id: "parent-thread", source: .sessions)
        )

        let effect = state.reduce(
            .open(
                .subagent(parentID: "parent-thread", childID: "child-thread"),
                source: .sessions
            ),
            usesCompactNavigation: true,
            selectedSessionID: "parent-thread"
        )

        XCTAssertNil(effect)
        XCTAssertEqual(state.selection, .session("parent-thread"))
        XCTAssertEqual(
            state.route,
            .session(id: "parent-thread", source: .sessions)
        )
        XCTAssertEqual(
            state.compactSessionPath,
            [
                .session("parent-thread"),
                .subagent(parentID: "parent-thread", childID: "child-thread"),
            ]
        )
        XCTAssertEqual(
            state.visibleSessionID(usesCompactNavigation: true),
            "child-thread",
            "通知可见性必须以屏幕正在阅读的 child Thread 为准"
        )

        let popEffect = state.reduce(
            .compactPathChanged(
                tab: .sessions,
                path: [.session("parent-thread")]
            ),
            usesCompactNavigation: true,
            selectedSessionID: "parent-thread"
        )
        XCTAssertNil(popEffect)
        XCTAssertEqual(state.selection, .session("parent-thread"))
        XCTAssertEqual(
            state.visibleSessionID(usesCompactNavigation: true),
            "parent-thread"
        )
    }

    func testWorkbenchNavigationCreatedSessionCallbackDoesNotOpenTwice() {
        var state = WorkbenchNavigationState(route: .workspaces)

        let selectionEffect = state.reduce(
            .selectionCommitted(SessionSelectionCommit(
                sequence: 1,
                projectID: "workspace",
                sessionID: "local:new-session",
                reason: .userOpen
            )),
            usesCompactNavigation: true,
            selectedSessionID: "local:new-session"
        )
        let stateAfterSelection = state
        let callbackEffect = state.reduce(
            .open(.session("local:new-session"), source: nil),
            usesCompactNavigation: true,
            selectedSessionID: "local:new-session"
        )

        XCTAssertNil(selectionEffect)
        XCTAssertNil(callbackEffect)
        XCTAssertEqual(state, stateAfterSelection)
        XCTAssertEqual(state.compactWorkspacePath, [.session("local:new-session")])
    }

    func testWorkbenchNavigationSplitSelectionPreservesWorkspaceSource() {
        var state = WorkbenchNavigationState(route: .workspaces)

        let effect = state.reduce(
            .selectionCommitted(SessionSelectionCommit(
                sequence: 1,
                projectID: "workspace",
                sessionID: "workspace-session",
                reason: .userOpen
            )),
            usesCompactNavigation: false,
            selectedSessionID: "workspace-session"
        )

        XCTAssertNil(effect)
        XCTAssertEqual(
            state.route,
            .session(id: "workspace-session", source: .workspaces)
        )
        XCTAssertEqual(state.selection, .session("workspace-session"))
    }

    func testWorkbenchNavigationNotificationOpensSessionsDetail() {
        for usesCompactNavigation in [true, false] {
            var state = WorkbenchNavigationState(route: .workspaces)
            _ = state.reduce(
                .open(.me, source: nil),
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: nil
            )

            let effect = state.reduce(
                .selectionCommitted(SessionSelectionCommit(
                    sequence: 1,
                    projectID: "project",
                    sessionID: "notification-session",
                    reason: .notification
                )),
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: "notification-session"
            )

            XCTAssertNil(effect)
            XCTAssertEqual(
                state.route,
                .session(id: "notification-session", source: .sessions)
            )
            XCTAssertEqual(state.selection, .session("notification-session"))
            if usesCompactNavigation {
                XCTAssertEqual(state.compactSelectedTab, .sessions)
                XCTAssertEqual(state.compactSessionPath, [.session("notification-session")])
            }
        }
    }

    func testWorkbenchNavigationCompactWorkspacePopReturnsToWorkspace() {
        var state = WorkbenchNavigationState(
            route: .session(id: "session-workspace", source: .workspaces)
        )

        let effect = state.reduce(
            .compactPathChanged(tab: .workspaces, path: []),
            usesCompactNavigation: true,
            selectedSessionID: "session-workspace"
        )

        XCTAssertEqual(effect, .returnToSessionList)
        XCTAssertEqual(state.route, .workspaces)
        XCTAssertEqual(state.selection, .workspaces)
        XCTAssertEqual(state.compactSelectedTab, .workspaces)
        XCTAssertTrue(state.compactWorkspacePath.isEmpty)
    }

    func testWorkbenchNavigationWorkspaceBackButtonOnlyShowsForWideWorkspaceDetail() {
        let cases: [(WorkbenchRestorationRoute, Bool, Bool)] = [
            (.session(id: "workspace-session", source: .workspaces), false, true),
            (.session(id: "workspace-session", source: .workspaces), true, false),
            (.session(id: "sessions-session", source: .sessions), false, false),
            (.session(id: "sessions-session", source: .sessions), true, false),
            (.workspaces, false, false),
        ]

        for (route, usesCompactNavigation, expected) in cases {
            let state = WorkbenchNavigationState(route: route)
            XCTAssertEqual(
                state.showsWorkspaceBackButton(usesCompactNavigation: usesCompactNavigation),
                expected,
                "route=\(route), compact=\(usesCompactNavigation)"
            )
        }
    }

    func testWorkbenchNavigationWorkspaceEmptyStateActionOpensWorkspaceInBothLayouts() {
        for usesCompactNavigation in [true, false] {
            var state = WorkbenchNavigationState(route: .sessions)

            let effect = state.reduce(
                .open(.workspaces, source: nil),
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: nil
            )

            XCTAssertEqual(effect, .returnToSessionList)
            XCTAssertEqual(state.route, .workspaces)
            XCTAssertEqual(state.selection, .workspaces)
            if usesCompactNavigation {
                XCTAssertEqual(state.compactSelectedTab, .workspaces)
                XCTAssertTrue(state.compactWorkspacePath.isEmpty)
            }
        }
    }

    func testWorkbenchNavigationPreparesCompactWorkspaceBeforeLayoutTransition() {
        var state = WorkbenchNavigationState(route: .sessions)

        _ = state.reduce(
            .open(.workspaces, source: nil),
            usesCompactNavigation: false,
            selectedSessionID: nil
        )

        XCTAssertEqual(state.route, .workspaces)
        XCTAssertEqual(state.compactSelectedTab, .workspaces)
        XCTAssertTrue(state.compactWorkspacePath.isEmpty)
    }

    func testWorkbenchNavigationRestoresSessionIntoItsSourceStack() {
        var state = WorkbenchNavigationState()
        let route = WorkbenchRestorationRoute.session(
            id: "restored-session",
            source: .workspaces
        )

        let effect = state.reduce(
            .synchronize(route),
            usesCompactNavigation: true,
            selectedSessionID: "restored-session"
        )

        XCTAssertNil(effect)
        XCTAssertEqual(state.route, route)
        XCTAssertEqual(state.selection, .session("restored-session"))
        XCTAssertEqual(state.compactSelectedTab, .workspaces)
        XCTAssertEqual(state.compactWorkspacePath, [.session("restored-session")])
        XCTAssertTrue(state.compactSessionPath.isEmpty)
    }

    func testWorkbenchNavigationReplacesOptimisticSessionWithoutAddingStackLevel() {
        var state = WorkbenchNavigationState(route: .sessions)

        _ = state.reduce(
            .selectionCommitted(SessionSelectionCommit(
                sequence: 1,
                projectID: "project",
                sessionID: "local:optimistic",
                reason: .userOpen
            )),
            usesCompactNavigation: true,
            selectedSessionID: "local:optimistic"
        )
        _ = state.reduce(
            .selectionCommitted(SessionSelectionCommit(
                sequence: 2,
                projectID: "project",
                sessionID: "server-session",
                reason: .identityReplacement(previousID: "local:optimistic")
            )),
            usesCompactNavigation: true,
            selectedSessionID: "server-session"
        )

        XCTAssertEqual(state.route, .session(id: "server-session", source: .sessions))
        XCTAssertEqual(state.compactSessionPath, [.session("server-session")])
    }

    func testWorkbenchNavigationIgnoresRestorationCommitAfterUserChangedRoute() {
        var state = WorkbenchNavigationState(
            route: .session(id: "session-b", source: .sessions)
        )
        let commit = SessionSelectionCommit(
            sequence: 4,
            projectID: "project",
            sessionID: "session-a",
            reason: .restoration
        )

        let effect = state.reduce(
            .selectionCommitted(commit),
            usesCompactNavigation: true,
            selectedSessionID: "session-b"
        )

        XCTAssertNil(effect)
        XCTAssertEqual(state.route, .session(id: "session-b", source: .sessions))
        XCTAssertEqual(state.compactSessionPath, [.session("session-b")])
    }

    func testWorkbenchNavigationIdentityReplacementOnlyReplacesMatchingRoute() {
        var state = WorkbenchNavigationState(
            route: .session(id: "session-b", source: .workspaces)
        )
        let commit = SessionSelectionCommit(
            sequence: 5,
            projectID: "project",
            sessionID: "session-a-real",
            reason: .identityReplacement(previousID: "local:session-a")
        )

        _ = state.reduce(
            .selectionCommitted(commit),
            usesCompactNavigation: true,
            selectedSessionID: "session-b"
        )

        XCTAssertEqual(state.route, .session(id: "session-b", source: .workspaces))
        XCTAssertEqual(state.compactWorkspacePath, [.session("session-b")])
    }

    func testWorkbenchRestorationRouteRejectsMismatchedSessionSnapshot() throws {
        let session = makeSession(
            id: "session_snapshot",
            projectID: "project_snapshot",
            title: "恢复快照",
            status: "history",
            source: "codex",
            resumeID: "resume_snapshot"
        )
        let snapshot = SessionRestoreSnapshot(endpoint: "http://127.0.0.1:8787", session: session)
        let storage = try JSONEncoder().encode(snapshot).base64EncodedString()
        let route = WorkbenchRestorationRoute.session(id: "another_session", source: .sessions)

        XCTAssertNil(route.restoreSnapshot(from: storage, currentEndpoint: snapshot.endpoint))
    }

    func testWorkbenchRestorationRouteRejectsSnapshotFromDifferentEndpoint() throws {
        let session = makeSession(
            id: "session_endpoint",
            projectID: "project_endpoint",
            title: "旧 Mac 快照",
            status: "history",
            source: "codex",
            resumeID: "resume_endpoint"
        )
        let snapshot = SessionRestoreSnapshot(endpoint: "http://100.64.0.10:8787", session: session)
        let storage = try JSONEncoder().encode(snapshot).base64EncodedString()
        let route = WorkbenchRestorationRoute.session(id: session.id, source: .sessions)

        XCTAssertNil(route.restoreSnapshot(from: storage, currentEndpoint: "http://100.64.0.11:8787"))
    }

    func testWorkbenchRestorationRouteUsesProfileIdentityAfterEndpointChanges() throws {
        let session = makeSession(
            id: "session_profile",
            projectID: "project_profile",
            title: "同一 Mac 的恢复快照",
            status: "history",
            source: "codex",
            resumeID: "resume_profile"
        )
        let snapshot = SessionRestoreSnapshot(
            profileID: "mac-a",
            endpoint: "http://100.64.0.10:8787",
            session: session
        )
        let storage = try JSONEncoder().encode(snapshot).base64EncodedString()
        let route = WorkbenchRestorationRoute.session(id: session.id, source: .sessions)

        XCTAssertNotNil(
            route.restoreSnapshot(
                from: storage,
                currentProfileID: "mac-a",
                currentEndpoint: "http://100.64.0.99:8787"
            ),
            "V2 快照应跟随稳定 Profile，不能因同一 Mac 更换网络地址而丢失"
        )
        XCTAssertNil(
            route.restoreSnapshot(
                from: storage,
                currentProfileID: "mac-b",
                currentEndpoint: snapshot.endpoint
            ),
            "即使 endpoint 相同，不同 Profile 也不能恢复彼此的会话"
        )
    }

    func testSelectingRunningSessionRefreshesHistoryAndSuppressesBufferedMessageReplay() async throws {
        let project = makeProject(id: "proj_live_resume")
        let running = makeSession(id: "sess_live_resume", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let refreshedHistory = [
            CodexHistoryMessage(
                id: "live-user",
                role: "user",
                content: "开始长任务",
                createdAt: Date(timeIntervalSince1970: 10)
            ),
            CodexHistoryMessage(
                id: "live-assistant",
                role: "assistant",
                content: "离开期间已经完成的最新回答",
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 30),
                turnID: "turn-live",
                itemID: "assistant-live",
                sendStatus: .confirmed
            )
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            historyPages: [running.id: HistoryMessagesPage(messages: refreshedHistory)]
        )
        let conversationStore = ConversationStore()
        conversationStore.setHistory([
            CodexHistoryMessage(
                id: "stale-assistant",
                role: "assistant",
                content: "旧回答",
                createdAt: Date(timeIntervalSince1970: 1)
            )
        ], sessionID: running.id)
        var sockets: [MockWebSocketClient] = []
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.takeOverSession(running)
        await store.selectSession(running)

        XCTAssertEqual(client.requestedMessageSessionIDs, [running.id])
        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(try XCTUnwrap(sockets.first).replayBufferedEventsByConnect, [false])
        XCTAssertEqual(conversationStore.messages(for: running.id).suffix(refreshedHistory.count).map(\.content), refreshedHistory.map(\.content))
    }

    func testSessionStoreSendsUserInputAnswersThroughExistingSocket() async throws {
        let project = makeProject(id: "proj_user_input")
        let request = AgentUserInputRequest(
            id: "input-1",
            threadID: "sess_user_input",
            turnID: "turn-1",
            itemID: "input-1",
            questions: [
                AgentUserInputQuestion(
                    id: "scope",
                    header: "范围",
                    question: "先做哪一部分？",
                    isOther: true,
                    isSecret: false,
                    options: [AgentUserInputOption(label: "后端", description: "先落 API")]
                )
            ]
        )
        let running = AgentSession(
            id: request.threadID,
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "等待引导",
            status: "waiting_for_input",
            source: "codex",
            resumeID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            pendingUserInput: request
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        conversationStore.activate(profileID: appStore.activeHostScope.profileID)
        conversationStore.appendSystem("等待补充信息：\(request.title)", sessionID: running.id, kind: .userInput)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        for _ in 0..<50 where sockets.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let socket = try XCTUnwrap(sockets.first)
        XCTAssertEqual(sockets.count, 1)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.respondToUserInput(request, answers: ["scope": ["后端", "只做最小闭环"]])

        XCTAssertEqual(socket.sentUserInputResponses.count, 1)
        XCTAssertEqual(socket.sentUserInputResponses.first?.requestID, "input-1")
        XCTAssertEqual(socket.sentUserInputResponses.first?.answers["scope"], ["后端", "只做最小闭环"])
        XCTAssertTrue(store.isUserInputResponsePending(request))
        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertNil(store.selectedSession?.pendingUserInput)
        XCTAssertEqual(conversationStore.messages(for: running.id).last?.content, "补充信息已提交：范围")

        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertNil(store.selectedSession?.pendingUserInput)

        socket.onUserInputResponseFailure?("input-1", "request expired")
        try await waitForSelectedSessionStatus("waiting_for_input", store: store)

        XCTAssertEqual(store.selectedSession?.pendingUserInput, request)
        XCTAssertFalse(store.isUserInputResponsePending(request))
        XCTAssertEqual(conversationStore.messages(for: running.id).last?.content, "等待补充信息：范围")
    }

    func testSessionStoreReturnToListPublishesOnlyIntentWhenAlreadyCleared() {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        var publishCount = 0
        var cancellables: Set<AnyCancellable> = []

        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        // 已经处于列表时仍需发布一次 invalidation 来淘汰迟到任务，但不能重复发布 nil/disconnected。
        store.returnToSessionList()

        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(store.lastSelectionCommit?.reason, .invalidation)
    }

    func testSelectingAlreadySelectedHistoryPublishesOnlyNavigationIntentWhenHistoryLoaded() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let conversationStore = ConversationStore()
        conversationStore.setHistory([
            CodexHistoryMessage(id: "rollout:1", role: "assistant", content: "已加载", createdAt: Date(timeIntervalSince1970: 1))
        ], sessionID: history.id)
        var sockets: [MockWebSocketClient] = []
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [history]) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        store.selectedProjectID = project.id
        store.selectedSessionID = history.id
        await store.toggleProjectExpansion(project)
        // 历史会话的稳态现在包含事件订阅：先完整选择一次并让 socket 连上，
        // 再排空静默补拉任务，进入稳态后重复点选才是 no-op。
        await store.selectSession(history)
        sockets.last?.emitStatus(.connected)
        for _ in 0..<10 {
            await Task.yield()
        }
        var publishCount = 0
        var cancellables: Set<AnyCancellable> = []

        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        // 重复点当前历史行仍是新的用户意图，只发布 commit，不重复写入 project/session 或重建 socket。
        await store.selectSession(history)

        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(store.lastSelectionCommit?.reason, .userOpen)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.selectedSessionID, history.id)
        XCTAssertEqual(sockets.count, 1)
    }

    func testCompletionVersionIgnoresHydrationAndOrderingOnlyChanges() {
        let original = AgentSession(
            id: "session-version",
            projectID: "project-version",
            project: "project-version",
            dir: "/tmp/project-version",
            title: "完成版本",
            status: SessionStatus.history.rawValue,
            source: "codex",
            resumeID: "session-version",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 20),
            recencyAt: Date(timeIntervalSince1970: 18)
        )
        let refreshedMetadata = AgentSession(
            id: original.id,
            projectID: original.projectID,
            project: original.project,
            dir: original.dir,
            title: "刷新后标题",
            status: original.status,
            source: original.source,
            resumeID: original.resumeID,
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 99),
            recencyAt: original.recencyAt
        )
        let newCompletion = AgentSession(
            id: original.id,
            projectID: original.projectID,
            project: original.project,
            dir: original.dir,
            title: original.title,
            status: original.status,
            source: original.source,
            resumeID: original.resumeID,
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 30),
            recencyAt: Date(timeIntervalSince1970: 30)
        )

        let originalVersion = SessionCompletionVersion(session: original)
        XCTAssertTrue(
            originalVersion.representsSameCompletion(
                as: SessionCompletionVersion(session: refreshedMetadata)
            ),
            "recencyAt 未变化时，标题刷新和 updatedAt 元数据变化不能制造未读"
        )
        XCTAssertFalse(
            originalVersion.representsSameCompletion(
                as: SessionCompletionVersion(session: newCompletion)
            )
        )

        let sparse = AgentSession(
            id: original.id,
            projectID: original.projectID,
            project: original.project,
            dir: original.dir,
            title: original.title,
            status: original.status,
            source: original.source,
            resumeID: original.resumeID,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        XCTAssertTrue(
            SessionCompletionVersion(session: sparse).representsSameCompletion(
                as: originalVersion
            ),
            "轻量列表后续补齐 recencyAt 时，应通过双方共有的 updatedAt 识别为同一次完成"
        )
    }

    func testHistoryCompletionObservationPersistsAcrossReadAndRestart() async throws {
        let suiteName = "ConversationSessionStoreTests.HistoryCompletionObservation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let readStateStore = SessionHistoryReadStateStore(defaults: defaults)
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        let project = makeProject(id: "project-unread")
        let initialHistory = makeSession(
            id: "session-unread",
            projectID: project.id,
            title: "初始旧历史",
            status: SessionStatus.history.rawValue,
            source: "codex",
            resumeID: "session-unread",
            updatedAt: Date(timeIntervalSince1970: 10),
            recencyAt: Date(timeIntervalSince1970: 10)
        )
        let conversationStore = ConversationStore()
        conversationStore.setHistory([
            CodexHistoryMessage(
                id: "history-unread-message",
                role: "assistant",
                content: "已加载",
                createdAt: Date(timeIntervalSince1970: 10)
            )
        ], sessionID: initialHistory.id)
        let client = MockSessionStoreClient(projects: [project], sessions: [initialHistory])
        let initialObservationDate = Date(timeIntervalSince1970: 100)
        let firstCompletionObservationDate = Date(timeIntervalSince1970: 120)
        let secondCompletionObservationDate = Date(timeIntervalSince1970: 140)
        var sessionListNow = initialObservationDate
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            sessionHistoryReadStateStore: readStateStore,
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() },
            sessionListNow: { sessionListNow }
        )

        store.sessions = [initialHistory]
        XCTAssertFalse(store.isHistorySessionUnread(initialHistory), "升级后首次见到的旧历史应建立已读基线")
        XCTAssertNil(
            store.historyCompletionObservedAtBySessionID[initialHistory.id],
            "旧历史首次进入索引没有观察到运行态，不应伪装成刚完成"
        )

        let running = makeSession(
            id: initialHistory.id,
            projectID: project.id,
            title: "新一轮运行中",
            status: SessionStatus.running.rawValue,
            source: "codex",
            resumeID: initialHistory.resumeID,
            activeTurnID: "turn-1",
            updatedAt: Date(timeIntervalSince1970: 20),
            recencyAt: Date(timeIntervalSince1970: 20)
        )
        store.sessions = [running]
        XCTAssertFalse(store.isHistorySessionUnread(running), "进行中会话不能显示历史未读")
        XCTAssertTrue(store.historyCompletionObservedAtBySessionID.isEmpty)

        sessionListNow = firstCompletionObservationDate
        let firstCompletion = makeSession(
            id: initialHistory.id,
            projectID: project.id,
            title: "第一轮完成",
            status: SessionStatus.history.rawValue,
            source: "codex",
            resumeID: initialHistory.resumeID,
            updatedAt: Date(timeIntervalSince1970: 21),
            recencyAt: Date(timeIntervalSince1970: 21)
        )
        store.sessions = [firstCompletion]
        XCTAssertTrue(store.isHistorySessionUnread(firstCompletion))
        XCTAssertEqual(
            store.historyCompletionObservedAtBySessionID[firstCompletion.id],
            firstCompletionObservationDate,
            "running → terminal 才记录本地完成观察时间"
        )
        let sectionsBeforeOpening = SessionListPresentation.sidebarSections(
            sessions: [firstCompletion],
            completionObservedAtByID: store.historyCompletionObservedAtBySessionID,
            now: firstCompletionObservationDate.addingTimeInterval(1)
        )
        XCTAssertEqual(
            sectionsBeforeOpening.first { $0.kind == .justCompleted }?.sessions.map(\.id),
            [firstCompletion.id]
        )

        await store.selectSession(firstCompletion)
        XCTAssertFalse(store.isHistorySessionUnread(firstCompletion), "打开历史会话后应立即标记已读")
        XCTAssertEqual(
            store.historyCompletionObservedAtBySessionID[firstCompletion.id],
            firstCompletionObservationDate,
            "Mimi 标记已读不能清除完成观察时间"
        )
        let sectionsAfterOpening = SessionListPresentation.sidebarSections(
            sessions: [firstCompletion],
            completionObservedAtByID: store.historyCompletionObservedAtBySessionID,
            now: firstCompletionObservationDate.addingTimeInterval(1)
        )
        XCTAssertEqual(
            sectionsAfterOpening.first { $0.kind == .justCompleted }?.sessions.map(\.id),
            [firstCompletion.id],
            "点击只改变已读水位，刚完成行在时间窗内必须保留原分组，避免视觉跳动"
        )

        let persisted = readStateStore.load(
            profileID: appStore.notificationRoutingProfileID,
            legacyEndpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
        XCTAssertFalse(try XCTUnwrap(persisted[firstCompletion.id]).isUnread)
        XCTAssertEqual(
            try XCTUnwrap(persisted[firstCompletion.id]).completionObservedAt,
            firstCompletionObservationDate
        )

        let restartedStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionHistoryReadStateStore: readStateStore,
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() },
            sessionListNow: { sessionListNow }
        )
        restartedStore.sessions = [firstCompletion]
        XCTAssertFalse(
            restartedStore.isHistorySessionUnread(firstCompletion),
            "App 重启和列表重新加载后不能把已读状态回退"
        )
        XCTAssertEqual(
            restartedStore.historyCompletionObservedAtBySessionID[firstCompletion.id],
            firstCompletionObservationDate,
            "完成观察时间应随持久化读状态在重启后恢复"
        )

        restartedStore.returnToSessionList()
        // 离线期间直接发现了新 completion version，但没有观察到 running；这不是可靠的
        // 完成转换证据，不能写入或复用“刚完成”时间。
        let offlineCompletion = makeSession(
            id: firstCompletion.id,
            projectID: project.id,
            title: "离线期间完成",
            status: SessionStatus.history.rawValue,
            source: "codex",
            resumeID: firstCompletion.resumeID,
            updatedAt: Date(timeIntervalSince1970: 25),
            recencyAt: Date(timeIntervalSince1970: 25)
        )
        restartedStore.sessions = [offlineCompletion]
        XCTAssertNil(
            restartedStore.historyCompletionObservedAtBySessionID[offlineCompletion.id],
            "冷启动/离线只知道版本变化时不应标记为刚完成"
        )

        let secondRunning = makeSession(
            id: firstCompletion.id,
            projectID: project.id,
            title: "第二轮运行中",
            status: SessionStatus.running.rawValue,
            source: "codex",
            resumeID: firstCompletion.resumeID,
            activeTurnID: "turn-2",
            updatedAt: Date(timeIntervalSince1970: 30),
            recencyAt: Date(timeIntervalSince1970: 30)
        )
        restartedStore.sessions = [secondRunning]
        XCTAssertFalse(restartedStore.isHistorySessionUnread(secondRunning))
        XCTAssertTrue(restartedStore.historyCompletionObservedAtBySessionID.isEmpty)

        sessionListNow = secondCompletionObservationDate
        let secondCompletion = makeSession(
            id: firstCompletion.id,
            projectID: project.id,
            title: "第二轮完成",
            status: SessionStatus.history.rawValue,
            source: "codex",
            resumeID: firstCompletion.resumeID,
            updatedAt: Date(timeIntervalSince1970: 31),
            recencyAt: Date(timeIntervalSince1970: 31)
        )
        restartedStore.sessions = [secondCompletion]
        XCTAssertTrue(
            restartedStore.isHistorySessionUnread(secondCompletion),
            "同一会话产生新的完成结果后应重新进入未读"
        )
        XCTAssertEqual(
            restartedStore.historyCompletionObservedAtBySessionID[secondCompletion.id],
            secondCompletionObservationDate
        )

        restartedStore.sessions = [secondCompletion]
        XCTAssertTrue(
            restartedStore.isHistorySessionUnread(secondCompletion),
            "相同完成版本的重复刷新不能改变未读判定"
        )
        XCTAssertEqual(
            restartedStore.historyCompletionObservedAtBySessionID[secondCompletion.id],
            secondCompletionObservationDate,
            "相同完成版本重复快照不能刷新观察时间"
        )
    }

    func testBatchCompletionSharesObservationTimeAndKeepsStableOrder() throws {
        let suiteName = "ConversationSessionStoreTests.BatchCompletionObservation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let project = makeProject(id: "project-batch-completion")
        let running = (0..<7).map { index in
            makeSession(
                id: "batch-completion-\(index)",
                projectID: project.id,
                title: "批量完成 \(index)",
                status: SessionStatus.running.rawValue,
                source: "codex",
                resumeID: "batch-completion-\(index)",
                activeTurnID: "turn-batch-\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index)),
                recencyAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let completed = running.enumerated().map { index, session in
            let activityDate = Date(timeIntervalSince1970: TimeInterval(100 - index))
            return makeSession(
                id: session.id,
                projectID: project.id,
                title: session.title,
                status: SessionStatus.history.rawValue,
                source: "codex",
                resumeID: session.resumeID,
                updatedAt: activityDate,
                recencyAt: activityDate
            )
        }
        var clockTick: TimeInterval = 1_000
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionHistoryReadStateStore: SessionHistoryReadStateStore(defaults: defaults),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: completed) },
            sessionListNow: {
                defer { clockTick += 1 }
                return Date(timeIntervalSince1970: clockTick)
            }
        )

        store.sessions = running
        store.sessions = completed

        let observations = completed.compactMap {
            store.historyCompletionObservedAtBySessionID[$0.id]
        }
        XCTAssertEqual(observations.count, completed.count)
        XCTAssertEqual(Set(observations).count, 1, "同一份终态快照只能生成一个完成观察时间")

        let observationDate = try XCTUnwrap(observations.first)
        let sections = SessionListPresentation.sidebarSections(
            sessions: completed,
            completionObservedAtByID: store.historyCompletionObservedAtBySessionID,
            now: observationDate.addingTimeInterval(1)
        )
        XCTAssertEqual(
            sections.first { $0.kind == .justCompleted }?.sessions.map(\.id),
            Array(completed.prefix(5)).map(\.id),
            "批量完成时间相同时应保留原活动顺序，不能按循环中的取时顺序反转"
        )
    }

    func testMarkHistorySessionUnreadKeepsCompletionObservationPersisted() throws {
        let suiteName = "ConversationSessionStoreTests.MarkUnread.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let readStateStore = SessionHistoryReadStateStore(defaults: defaults)
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        let project = makeProject(id: "project-mark-unread")
        let session = makeSession(
            id: "session-mark-unread",
            projectID: project.id,
            title: "手动未读",
            status: SessionStatus.history.rawValue,
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 40),
            recencyAt: Date(timeIntervalSince1970: 40)
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [session])
        let completionObservedAt = Date(timeIntervalSince1970: 60)
        let nextCompletionObservedAt = Date(timeIntervalSince1970: 80)
        var sessionListNow = completionObservedAt
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionHistoryReadStateStore: readStateStore,
            clientFactory: { client },
            sessionListNow: { sessionListNow }
        )
        store.sessions = [session]
        XCTAssertFalse(store.isHistorySessionUnread(session))
        XCTAssertNil(store.historyCompletionObservedAtBySessionID[session.id])

        var running = session
        running.status = SessionStatus.running.rawValue
        running.activeTurnID = "turn-mark-unread"
        running.updatedAt = Date(timeIntervalSince1970: 50)
        running.recencyAt = Date(timeIntervalSince1970: 50)
        store.sessions = [running]
        XCTAssertTrue(store.historyCompletionObservedAtBySessionID.isEmpty)

        var completed = session
        completed.updatedAt = Date(timeIntervalSince1970: 51)
        completed.recencyAt = Date(timeIntervalSince1970: 51)
        store.sessions = [completed]
        XCTAssertEqual(store.historyCompletionObservedAtBySessionID[session.id], completionObservedAt)

        // 先确认自然完成已读，再回退为手动未读，才能验证两条水位彼此独立。
        store.markHistorySessionRead(session.id)
        XCTAssertFalse(store.isHistorySessionUnread(completed))
        store.markHistorySessionUnread(session.id)

        XCTAssertTrue(store.isHistorySessionUnread(completed))
        XCTAssertEqual(store.historyCompletionObservedAtBySessionID[session.id], completionObservedAt)
        XCTAssertNil(try XCTUnwrap(store.historyReadStateBySessionID[session.id]).readCompletion)
        let persisted = readStateStore.load(
            profileID: appStore.notificationRoutingProfileID,
            legacyEndpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
        XCTAssertTrue(try XCTUnwrap(persisted[session.id]).isUnread)
        XCTAssertEqual(
            try XCTUnwrap(persisted[session.id]).completionObservedAt,
            completionObservedAt
        )

        store.selectedSessionID = completed.id
        store.synchronizeHistoryReadStates()
        XCTAssertTrue(
            store.isHistorySessionUnread(completed),
            "当前选中会话的手动未读不能被普通快照同步覆盖"
        )
        XCTAssertEqual(store.historyCompletionObservedAtBySessionID[completed.id], completionObservedAt)

        // Published Set 只是派生结果；即使被清空，重新同步也必须从 completion 水位恢复。
        store.setUnreadHistorySessionIDs([])
        XCTAssertFalse(store.isHistorySessionUnread(completed))
        store.synchronizeHistoryReadStates()
        XCTAssertTrue(store.isHistorySessionUnread(completed))
        XCTAssertEqual(store.historyCompletionObservedAtBySessionID[completed.id], completionObservedAt)

        var nextRunning = completed
        nextRunning.status = SessionStatus.running.rawValue
        nextRunning.activeTurnID = "turn-next-completion"
        nextRunning.updatedAt = Date(timeIntervalSince1970: 70)
        nextRunning.recencyAt = Date(timeIntervalSince1970: 70)
        store.sessions = [nextRunning]
        XCTAssertTrue(store.historyCompletionObservedAtBySessionID.isEmpty)

        sessionListNow = nextCompletionObservedAt
        var nextCompletion = completed
        nextCompletion.updatedAt = Date(timeIntervalSince1970: 71)
        nextCompletion.recencyAt = Date(timeIntervalSince1970: 71)
        store.sessions = [nextCompletion]
        XCTAssertFalse(
            store.isHistorySessionUnread(nextCompletion),
            "当前可见的新完成结果应视为已读，不能继承上一完成版本的手动未读"
        )
        XCTAssertEqual(store.historyCompletionObservedAtBySessionID[nextCompletion.id], nextCompletionObservedAt)
        XCTAssertNil(
            try XCTUnwrap(store.historyReadStateBySessionID[session.id]).manualUnreadCompletion
        )
    }

    func testSelectingHistorySessionKeepsSelectionWhenMessages404() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_missing", projectID: project.id, title: "缺失 rollout", status: "history", source: "codex", resumeID: "missing")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            messagesError: AgentAPIError.server(status: 404, message: "读取 Codex 历史失败")
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        XCTAssertEqual(client.requestedMessageSessionIDs, [history.id])
        XCTAssertEqual(store.selectedSessionID, history.id)
        XCTAssertFalse(conversationStore.hasLoadedHistory(sessionID: history.id))
        XCTAssertTrue(store.statusMessage?.contains("HTTP 404") == true)
    }

    func testSelectingHistorySessionKeepsSelectionWhenNoRolloutFound() async {
        let project = makeProject(id: "proj_no_rollout")
        let history = makeSession(
            id: "codex_no_rollout",
            projectID: project.id,
            title: "缺失 rollout",
            status: "history",
            source: "codex",
            resumeID: "missing-rollout"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            messagesError: AgentAPIError.server(status: 404, message: "no rollout found")
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        XCTAssertEqual(client.requestedMessageSessionIDs, [history.id])
        XCTAssertEqual(store.selectedSessionID, history.id)
        XCTAssertFalse(conversationStore.hasLoadedHistory(sessionID: history.id))
        // 历史读取失败只影响历史面板，不应把会话选择清掉或伪装成仍在运行的 turn。
        XCTAssertTrue(store.statusMessage?.contains("no rollout found") == true)
        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testSendingPromptToCodexHistoryResumesAndKeepsLocalHiMessage() async throws {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: history)
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        await store.sendPrompt("hi")

        XCTAssertEqual(client.createPayloads.count, 1)
        XCTAssertEqual(client.createPayloads.first?.resumeID, history.resumeID)
        XCTAssertEqual(client.createPayloads.first?.prompt, "hi")
        let messages = conversationStore.messages(for: history.id)
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content == "历史问题" })
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.content == "历史回答" })
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content == "hi" && $0.sendStatus == .sent })
    }

    func testSessionStoreProjectSelectionRefreshesProjectHistoryWithoutSelectingLatest() async {
        let firstProject = makeProject(id: "proj_1")
        let freshHistory = makeSession(id: "codex_fresh", projectID: firstProject.id, title: "刷新后的历史", status: "history", source: "codex", resumeID: "fresh")
        let client = MockSessionStoreClient(
            projects: [firstProject],
            sessions: [],
            projectSessions: [firstProject.id: [freshHistory]]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.selectProject(firstProject)

        XCTAssertEqual(client.requestedProjectIDs, [firstProject.id])
        XCTAssertEqual(store.filteredSessions.map(\.id), [freshHistory.id])
        XCTAssertNil(store.selectedSessionID)
    }

    func testWorkspaceCatalogRefreshDoesNotChangeActiveSessionContext() async throws {
        let project = makeProject(id: "proj_catalog_refresh")
        let session = makeSession(
            id: "sess_catalog_refresh",
            projectID: project.id,
            title: "正在查看的会话",
            status: "history",
            source: "codex",
            resumeID: "catalog-refresh"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            messagesResult: []
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

        await store.refreshAll(autoAttach: false)
        await store.selectProject(project)
        await store.selectSession(session)
        let selectedProjectID = store.selectedProjectID
        let selectedSessionID = store.selectedSessionID
        let socketCount = sockets.count

        try await store.refreshWorkspaceCatalog()

        XCTAssertEqual(store.selectedProjectID, selectedProjectID)
        XCTAssertEqual(store.selectedSessionID, selectedSessionID)
        XCTAssertEqual(sockets.count, socketCount)
        XCTAssertEqual(store.sidebarProjects.map(\.id), [project.id])
    }

    func testWorkspaceSessionRefreshLoadsBrowsedWorkspaceWithoutChangingActiveSession() async throws {
        let activeProject = makeProject(id: "proj_active_session")
        let browsedProject = makeProject(id: "proj_browsed_workspace")
        let activeSession = makeSession(
            id: "sess_active_session",
            projectID: activeProject.id,
            title: "正在运行的会话",
            status: "running",
            source: "codex",
            resumeID: "active-session"
        )
        let browsedSession = makeSession(
            id: "sess_browsed_workspace",
            projectID: browsedProject.id,
            title: "首次进入即可看到的会话",
            status: "history",
            source: "codex",
            resumeID: "browsed-session"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let recentStore = makeRecentWorkspaceStore(
            workspaces: [],
            endpoint: appStore.endpoint
        )
        recentStore.save(
            [
                AgentWorkspace(project: activeProject, lastOpenedAt: Date(timeIntervalSince1970: 20)),
                AgentWorkspace(project: browsedProject, lastOpenedAt: Date(timeIntervalSince1970: 10))
            ],
            profileID: appStore.notificationRoutingProfileID
        )
        let client = MockSessionStoreClient(
            projects: [activeProject, browsedProject],
            sessions: [],
            workspaceSessions: [
                activeProject.id: [activeSession],
                browsedProject.id: [browsedSession]
            ],
            messagesResult: []
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: recentStore,
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.selectProject(activeProject)
        await store.selectSession(activeSession)
        store.takeOverSession(activeSession)
        XCTAssertEqual(sockets.count, 1)
        let socketCount = sockets.count
        let disconnectCallCount = sockets.first?.disconnectCallCount

        try await store.refreshWorkspaceSessions(projectID: browsedProject.id)

        XCTAssertEqual(store.sessions(forProjectID: browsedProject.id).map(\.id), [browsedSession.id])
        XCTAssertEqual(store.selectedProjectID, activeProject.id)
        XCTAssertEqual(store.selectedSessionID, activeSession.id)
        XCTAssertEqual(sockets.count, socketCount)
        XCTAssertEqual(sockets.first?.disconnectCallCount, disconnectCallCount)
        XCTAssertEqual(client.requestedWorkspaceIDs, [activeProject.id, browsedProject.id])
    }

    func testWorkspaceCatalogKeepsOnlyExplicitlyOpenedDirectories() async throws {
        let openedProject = makeProject(id: "opened-project")
        let legacyAutoProject = makeProject(id: "legacy-auto-project")
        let unopenedCandidate = makeProject(id: "unopened-candidate")
        let openedWorkspace = AgentWorkspace(
            project: openedProject,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        // 旧版目录刷新会把 projects() 候选项直接写入 recent，特征是没有明确打开时间。
        let legacyAutoWorkspace = AgentWorkspace(project: legacyAutoProject)
        let appStore = makeIsolatedAppStore()
        let recentStore = makeRecentWorkspaceStore(
            workspaces: [openedWorkspace, legacyAutoWorkspace],
            endpoint: appStore.endpoint
        )
        let client = MockSessionStoreClient(
            projects: [openedProject, legacyAutoProject, unopenedCandidate],
            sessions: []
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: recentStore,
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(Set(store.sidebarProjects.map(\.id)), [openedProject.id, legacyAutoProject.id])

        try await store.refreshWorkspaceCatalog()

        XCTAssertEqual(store.projects.map(\.id), [openedProject.id, legacyAutoProject.id, unopenedCandidate.id])
        XCTAssertEqual(store.sidebarProjects.map(\.id), [openedProject.id])
        XCTAssertEqual(
            recentStore.load(profileID: appStore.notificationRoutingProfileID).map(\.id),
            [openedProject.id]
        )
    }

    func testApprovalSummaryDecodesLegacyPayloadAndRequiresDetailsForApproval() throws {
        let legacyJSON = #"{"id":"approval-legacy","title":"运行命令","kind":"command","count":1}"#
        let legacy = try JSONDecoder().decode(ApprovalSummary.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(legacy.body)
        XCTAssertNil(legacy.risk)
        XCTAssertFalse(legacy.hasDecisionContext)

        let explicit = ApprovalSummary(
            id: "approval-explicit",
            title: "运行 go test ./...",
            body: "go test ./...",
            kind: "command",
            risk: "会执行测试命令",
            count: 1
        )
        XCTAssertTrue(explicit.hasDecisionContext)
    }

    func testEventReducerRetainsApprovalBodyAndRisk() async throws {
        let reducer = EventReducer()
        let output = await reducer.reduce(
            .approvalRequest(
                AgentApprovalRequest(
                    id: "approval-detail",
                    title: "运行 go test ./...",
                    body: "go test ./...",
                    kind: "command",
                    risk: "将在当前工作区执行"
                ),
                AgentEventMetadata(
                    seq: 1,
                    sessionID: "sess-approval-detail",
                    turnID: "turn-1",
                    itemID: "item-1",
                    messageID: nil,
                    clientMessageID: nil,
                    revision: nil,
                    createdAt: nil
                )
            ),
            fallbackSessionID: "fallback",
            outputIdleClearDelay: 0
        )

        let approval = try XCTUnwrap(output.pendingApprovalUpdates.first?.1)
        XCTAssertEqual(approval.body, "go test ./...")
        XCTAssertEqual(approval.risk, "将在当前工作区执行")
    }

    func testSessionStoreSearchFiltersLoadedSessionsAndProjects() async {
        let firstProject = makeProject(id: "proj_alpha")
        let secondProject = makeProject(id: "proj_beta")
        let metadataReview = makeSession(
            id: "codex_review",
            projectID: firstProject.id,
            title: "审核元数据修复",
            status: "history",
            source: "codex",
            resumeID: "review",
            preview: "替换 App Store 高风险描述",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let featureAudit = makeSession(
            id: "codex_feature_audit",
            projectID: secondProject.id,
            title: "功能对齐检查",
            status: "history",
            source: "codex",
            resumeID: "feature",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let client = MockSessionStoreClient(
            projects: [firstProject, secondProject],
            sessions: [],
            projectSessions: [
                firstProject.id: [metadataReview],
                secondProject.id: [featureAudit]
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.selectProject(firstProject)
        await store.selectProject(secondProject)

        store.selectedProjectID = firstProject.id
        store.sessionSearchQuery = "App Store"
        XCTAssertEqual(store.filteredSessions.map(\.id), [metadataReview.id])
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [metadataReview.id])
        XCTAssertEqual(store.filteredSidebarProjects.map(\.id), [firstProject.id])
        XCTAssertEqual(store.sessionListSnapshot(forProjectID: firstProject.id).visibleSessions.map(\.id), [metadataReview.id])

        store.sessionSearchQuery = "proj_beta"
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [featureAudit.id])
        XCTAssertEqual(store.filteredSidebarProjects.map(\.id), [secondProject.id])

        store.sessionSearchQuery = ""
        XCTAssertEqual(store.filteredSessions.map(\.id), [metadataReview.id])
        // 全局会话库和“最近”不受当前工作区筛选影响，并严格按最后活动时间排序。
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [featureAudit.id, metadataReview.id])
        XCTAssertEqual(store.recentSessions.map(\.id), [featureAudit.id, metadataReview.id])
        XCTAssertEqual(Set(store.filteredSidebarProjects.map(\.id)), Set([firstProject.id, secondProject.id]))
    }

    func testThreadSearchDebouncesLatestQueryAndKeepsLocalSessionsWhenCleared() async throws {
        let project = makeProject(id: "proj_thread_search_debounce")
        let local = makeSession(
            id: "local_thread_search",
            projectID: project.id,
            title: "本地已加载会话",
            status: "history",
            source: "codex"
        )
        let remote = makeSession(
            id: "remote_thread_search",
            projectID: project.id,
            title: "远端正文命中",
            status: "history",
            source: "codex",
            preview: "needle 位于更早的消息正文"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [local]],
            threadSearchHandler: { query, _, _ in
                ThreadSearchPage(results: [ThreadSearchResult(session: remote, snippet: "\(query) 位于更早的消息正文")])
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 50_000_000
        )
        await store.selectProject(project)
        store.selectedSessionID = local.id

        store.sessionSearchQuery = "旧关键词"
        try await Task.sleep(nanoseconds: 5_000_000)
        store.sessionSearchQuery = "needle"
        for _ in 0..<100 where client.requestedThreadSearchQueries.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(client.requestedThreadSearchQueries, ["needle"], "防抖窗口内只应发送最后一个查询")
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [remote.id])
        XCTAssertEqual(store.selectedSessionID, local.id, "搜索结果合并不能改写当前选择")

        store.sessionSearchQuery = ""
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(client.requestedThreadSearchQueries, ["needle"], "空查询不能发 thread/search")
        XCTAssertEqual(store.sessions.map(\.id), [local.id], "清空搜索不能删除已加载会话")
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)
        XCTAssertEqual(store.selectedSessionID, local.id)
    }

    func testThreadSearchIgnoresCanceledLateResponse() async throws {
        let project = makeProject(id: "proj_thread_search_stale")
        let first = makeSession(
            id: "remote_first_stale",
            projectID: project.id,
            title: "first",
            status: "history",
            source: "codex",
            preview: "first"
        )
        let second = makeSession(
            id: "remote_second_current",
            projectID: project.id,
            title: "second",
            status: "history",
            source: "codex",
            preview: "second"
        )
        let gate = ThreadSearchResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            threadSearchHandler: { query, _, _ in
                try await gate.search(query: query)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )

        store.sessionSearchQuery = "first"
        try await waitForThreadSearchQueries(gate, count: 1)
        store.sessionSearchQuery = "second"
        try await waitForThreadSearchQueries(gate, count: 2)

        gate.resolve(
            query: "second",
            page: ThreadSearchPage(results: [ThreadSearchResult(session: second, snippet: "second")])
        )
        for _ in 0..<100 where store.remoteSessionSearchResults.map(\.id) != [second.id] {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        gate.resolve(
            query: "first",
            page: ThreadSearchPage(results: [ThreadSearchResult(session: first, snippet: "first")])
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.remoteSessionSearchResults.map(\.id), [second.id])
        XCTAssertFalse(store.sessions.contains(where: { $0.id == first.id }), "已取消查询的迟到响应不能污染基础缓存")
    }

    func testThreadSearchUnavailableSilentlyFallsBackToLocalResults() async throws {
        let project = makeProject(id: "proj_thread_search_fallback")
        let local = makeSession(
            id: "local_thread_search_fallback",
            projectID: project.id,
            title: "旧服务也能本地搜索",
            status: "history",
            source: "codex",
            preview: "fallback needle"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [local]],
            threadSearchHandler: { _, _, _ in
                throw CodexAppServerSessionRuntimeError.threadSearchUnavailable
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )
        await store.selectProject(project)
        let statusBeforeSearch = store.statusMessage

        store.sessionSearchQuery = "fallback needle"
        for _ in 0..<100 where client.requestedThreadSearchQueries.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.filteredSessions.map(\.id), [local.id])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.statusMessage, statusBeforeSearch, "搜索失败不能改写全局状态提示")
        XCTAssertNil(store.connectionTermination)
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)
    }

    func testThreadSearchInitialLoadingCoversDebounceAndFinishesOnSuccessAndFailure() async throws {
        let project = makeProject(id: "proj_thread_search_initial_loading")
        let local = makeSession(
            id: "thread_search_initial_loading_local",
            projectID: project.id,
            title: "本地 local 命中",
            status: "history",
            source: "codex"
        )
        let remote = makeSession(
            id: "thread_search_initial_loading_remote",
            projectID: project.id,
            title: "远端正文命中",
            status: "history",
            source: "codex"
        )
        let gate = ThreadSearchResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [local]],
            threadSearchHandler: { query, cursor, _ in
                try await gate.search(query: query, cursor: cursor)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 50_000_000
        )
        await store.selectProject(project)
        let statusBeforeSearch = store.statusMessage

        store.sessionSearchQuery = "local"
        XCTAssertTrue(store.isSearchingRemoteSessionResults, "首屏 loading 必须从防抖阶段开始")
        XCTAssertTrue(gate.requests.isEmpty, "防抖未结束前不应提前发请求")
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [local.id], "已有本地命中不能被首屏 loading 覆盖")
        try await waitForThreadSearchQueries(gate, count: 1)
        XCTAssertTrue(store.isSearchingRemoteSessionResults)

        gate.resolve(
            query: "local",
            page: ThreadSearchPage(results: [ThreadSearchResult(session: remote, snippet: "local 正文命中")])
        )
        for _ in 0..<100 where store.isSearchingRemoteSessionResults {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.isSearchingRemoteSessionResults)
        XCTAssertEqual(Set(store.sessionLibrarySessions.map(\.id)), Set([local.id, remote.id]))

        store.sessionSearchQuery = "failure"
        XCTAssertTrue(store.isSearchingRemoteSessionResults)
        try await waitForThreadSearchQueries(gate, count: 2)
        gate.fail(query: "failure", error: URLError(.timedOut))
        for _ in 0..<100 where store.isSearchingRemoteSessionResults {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(store.isSearchingRemoteSessionResults)
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty, "首屏失败只静默回退本地过滤")
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.statusMessage, statusBeforeSearch)
        XCTAssertNil(store.connectionTermination)
    }

    func testThreadSearchInitialLoadingIgnoresOldQueryAndResetsAfterMacSwitch() async throws {
        let suiteName = "ConversationDataFlowTests.ThreadSearchInitialLoadingConnection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.10:8787", forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations(itemData: Data("old-token".utf8))
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let project = makeProject(id: "proj_thread_search_initial_loading_stale")
        let oldResult = makeSession(
            id: "thread_search_initial_loading_old",
            projectID: project.id,
            title: "旧查询结果",
            status: "history",
            source: "codex"
        )
        let currentResult = makeSession(
            id: "thread_search_initial_loading_current",
            projectID: project.id,
            title: "旧 Mac 结果",
            status: "history",
            source: "codex"
        )
        let gate = ThreadSearchResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            threadSearchHandler: { query, cursor, _ in
                try await gate.search(query: query, cursor: cursor)
            }
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )

        store.sessionSearchQuery = "old"
        try await waitForThreadSearchQueries(gate, count: 1)
        XCTAssertTrue(store.isSearchingRemoteSessionResults)

        store.sessionSearchQuery = "current"
        try await waitForThreadSearchQueries(gate, count: 2)
        XCTAssertTrue(store.isSearchingRemoteSessionResults)
        gate.resolve(
            query: "old",
            page: ThreadSearchPage(results: [ThreadSearchResult(session: oldResult, snippet: "不得落地")])
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.isSearchingRemoteSessionResults, "旧 query 的迟到 defer 不能清掉新 query 的 loading")
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)

        let oldConnectionGeneration = appStore.connectionGeneration
        let didCommit = try await store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "new-token"
        ))
        XCTAssertTrue(didCommit)
        XCTAssertGreaterThan(appStore.connectionGeneration, oldConnectionGeneration)
        XCTAssertEqual(store.sessionSearchQuery, "")
        XCTAssertFalse(store.isSearchingRemoteSessionResults)
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)

        gate.resolve(
            query: "current",
            page: ThreadSearchPage(results: [ThreadSearchResult(session: currentResult, snippet: "旧 Mac 不得回填")])
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(store.isSearchingRemoteSessionResults)
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty, "旧 Mac 的迟到响应不能恢复结果或 loading")
    }

    func testThreadSearchPaginationMergesByIDUpdatesSnippetAndStopsOnSameCursor() async throws {
        let project = makeProject(id: "proj_thread_search_page_merge")
        let canonical = makeSession(
            id: "thread_page_duplicate",
            projectID: project.id,
            title: "本地权威标题",
            status: "history",
            source: "codex",
            preview: "本地 preview 不能被搜索覆盖"
        )
        let remoteFirst = makeSession(
            id: canonical.id,
            projectID: project.id,
            title: "远端首屏标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        let remoteUpdated = makeSession(
            id: canonical.id,
            projectID: project.id,
            title: "远端分页更新标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 4)
        )
        let remoteSecond = makeSession(
            id: "thread_page_second",
            projectID: project.id,
            title: "分页新增",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [canonical]],
            threadSearchHandler: { _, cursor, _ in
                switch cursor {
                case nil:
                    return ThreadSearchPage(
                        results: [ThreadSearchResult(session: remoteFirst, snippet: "首屏 snippet")],
                        nextCursor: "cursor-1"
                    )
                case "cursor-1":
                    return ThreadSearchPage(
                        results: [
                            ThreadSearchResult(session: remoteUpdated, snippet: "分页更新 snippet"),
                            ThreadSearchResult(session: remoteSecond, snippet: "分页新增 snippet")
                        ],
                        nextCursor: "cursor-1"
                    )
                default:
                    throw MockError.unimplemented
                }
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )
        await store.selectProject(project)

        store.sessionSearchQuery = "needle"
        for _ in 0..<100 where store.sessionSearchNextCursor != "cursor-1" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await store.loadMoreSessionSearchResults()

        XCTAssertEqual(Set(store.remoteSessionSearchResults.map(\.id)), Set([canonical.id, remoteSecond.id]))
        XCTAssertEqual(store.remoteSessionSearchResults.first(where: { $0.id == canonical.id })?.title, remoteUpdated.title)
        XCTAssertEqual(store.sessionSearchSnippet(for: canonical.id), "分页更新 snippet")
        XCTAssertEqual(store.sessions.first(where: { $0.id == canonical.id })?.title, canonical.title)
        XCTAssertEqual(store.sessions.first(where: { $0.id == canonical.id })?.preview, canonical.preview)
        XCTAssertNil(store.sessionSearchNextCursor, "服务端返回本次请求 cursor 时必须终止，避免死循环")
        XCTAssertFalse(store.sessionSearchHasMore)

        await store.loadMoreSessionSearchResults()
        XCTAssertEqual(client.requestedThreadSearchCursors, [nil, "cursor-1"], "终止后再次点击不能继续发请求")
    }

    func testThreadSearchPaginationDeduplicatesClicksAndRetainsCursorForRetry() async throws {
        let project = makeProject(id: "proj_thread_search_page_retry")
        let first = makeSession(
            id: "thread_page_retry_first",
            projectID: project.id,
            title: "首屏结果",
            status: "history",
            source: "codex"
        )
        let second = makeSession(
            id: "thread_page_retry_second",
            projectID: project.id,
            title: "重试结果",
            status: "history",
            source: "codex"
        )
        let gate = ThreadSearchResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            threadSearchHandler: { query, cursor, _ in
                if cursor == nil {
                    return ThreadSearchPage(
                        results: [ThreadSearchResult(session: first, snippet: "首屏")],
                        nextCursor: "retry-cursor"
                    )
                }
                return try await gate.search(query: query, cursor: cursor)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )

        store.sessionSearchQuery = "retry"
        for _ in 0..<100 where store.sessionSearchNextCursor != "retry-cursor" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let statusBeforePage = store.statusMessage
        let firstPageTask = Task { @MainActor in
            await store.loadMoreSessionSearchResults()
        }
        try await waitForThreadSearchQueries(gate, count: 1)

        await store.loadMoreSessionSearchResults()
        XCTAssertEqual(gate.requests.count, 1, "分页在途时重复点击只能保留一个请求")
        XCTAssertTrue(store.isLoadingMoreSessionSearchResults)

        gate.fail(query: "retry", cursor: "retry-cursor", error: URLError(.timedOut))
        await firstPageTask.value
        XCTAssertEqual(store.remoteSessionSearchResults.map(\.id), [first.id])
        XCTAssertEqual(store.sessionSearchNextCursor, "retry-cursor")
        XCTAssertTrue(store.sessionSearchHasMore)
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.statusMessage, statusBeforePage)
        XCTAssertNil(store.connectionTermination)

        let retryTask = Task { @MainActor in
            await store.loadMoreSessionSearchResults()
        }
        try await waitForThreadSearchQueries(gate, count: 2)
        gate.resolve(
            query: "retry",
            cursor: "retry-cursor",
            page: ThreadSearchPage(
                results: [ThreadSearchResult(session: second, snippet: "重试成功")]
            )
        )
        await retryTask.value

        XCTAssertEqual(Set(store.remoteSessionSearchResults.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(gate.requests.count, 2, "失败后应允许使用同一 cursor 显式重试")
        XCTAssertFalse(store.sessionSearchHasMore)
    }

    func testThreadSearchPaginationDropsLatePagesAfterNewQueryAndConnectionChange() async throws {
        let suiteName = "ConversationDataFlowTests.ThreadSearchPaginationConnection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.10:8787", forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations(itemData: Data("old-token".utf8))
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let project = makeProject(id: "proj_thread_search_page_stale")
        let oldFirst = makeSession(
            id: "thread_page_old_first",
            projectID: project.id,
            title: "旧查询首屏",
            status: "history",
            source: "codex"
        )
        let oldLate = makeSession(
            id: "thread_page_old_late",
            projectID: project.id,
            title: "旧查询迟到页",
            status: "history",
            source: "codex"
        )
        let currentFirst = makeSession(
            id: "thread_page_current_first",
            projectID: project.id,
            title: "新查询首屏",
            status: "history",
            source: "codex"
        )
        let currentLate = makeSession(
            id: "thread_page_current_late",
            projectID: project.id,
            title: "旧 Mac 迟到页",
            status: "history",
            source: "codex"
        )
        let gate = ThreadSearchResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            threadSearchHandler: { query, cursor, _ in
                switch (query, cursor) {
                case ("old", nil):
                    return ThreadSearchPage(
                        results: [ThreadSearchResult(session: oldFirst, snippet: "旧首屏")],
                        nextCursor: "old-cursor"
                    )
                case ("current", nil):
                    return ThreadSearchPage(
                        results: [ThreadSearchResult(session: currentFirst, snippet: "新首屏")],
                        nextCursor: "current-cursor"
                    )
                default:
                    return try await gate.search(query: query, cursor: cursor)
                }
            }
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )

        store.sessionSearchQuery = "old"
        for _ in 0..<100 where store.sessionSearchNextCursor != "old-cursor" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let oldPageTask = Task { @MainActor in
            await store.loadMoreSessionSearchResults()
        }
        try await waitForThreadSearchQueries(gate, count: 1)

        store.sessionSearchQuery = "current"
        for _ in 0..<100 where store.sessionSearchNextCursor != "current-cursor" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        gate.resolve(
            query: "old",
            cursor: "old-cursor",
            page: ThreadSearchPage(
                results: [ThreadSearchResult(session: oldLate, snippet: "不得落地")],
                nextCursor: "old-next"
            )
        )
        await oldPageTask.value
        XCTAssertEqual(store.remoteSessionSearchResults.map(\.id), [currentFirst.id])
        XCTAssertEqual(store.sessionSearchNextCursor, "current-cursor")
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)

        let currentPageTask = Task { @MainActor in
            await store.loadMoreSessionSearchResults()
        }
        try await waitForThreadSearchQueries(gate, count: 2)
        let oldConnectionGeneration = appStore.connectionGeneration
        let didCommit = try await store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "new-token"
        ))
        XCTAssertTrue(didCommit)
        XCTAssertGreaterThan(appStore.connectionGeneration, oldConnectionGeneration)
        XCTAssertEqual(store.sessionSearchQuery, "", "切换 Mac 后不能保留旧 Mac 的搜索词")
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)
        XCTAssertNil(store.sessionSearchNextCursor)
        XCTAssertFalse(store.sessionSearchHasMore)
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)

        gate.resolve(
            query: "current",
            cursor: "current-cursor",
            page: ThreadSearchPage(
                results: [ThreadSearchResult(session: currentLate, snippet: "旧 Mac 不得回填")],
                nextCursor: "current-next"
            )
        )
        await currentPageTask.value
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)
        XCTAssertNil(store.sessionSearchNextCursor)
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)
    }

    func testSessionStoreRefreshesGitStatusForSelectedSessionPath() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git", projectID: project.id, title: "检查 Git", status: "history", source: "codex", resumeID: "git")
        let gitStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "abc123",
            statusText: " M README.md",
            diffStat: " README.md | 2 +-",
            unstagedDiff: "@@ -1 +1 @@\n-before\n+after",
            stagedDiff: nil,
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitStatusResults: [session.dir: .success(gitStatus)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedGitStatus()

        XCTAssertEqual(client.requestedGitStatusPaths, [session.dir])
        XCTAssertEqual(store.selectedGitStatus?.unstagedDiff, gitStatus.unstagedDiff)
        XCTAssertNil(store.selectedGitStatusErrorMessage)
    }

    func testLateGitStatusFromPreviousHostCannotOverwriteCurrentHostState() async throws {
        let suiteName = "ConversationSessionStoreTests.GitHostLease.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let path = "/shared/project"
        let oldStatus = GitStatusResponse(
            path: path,
            isRepository: true,
            branch: "mac-a",
            head: "aaa",
            statusText: " M OLD.md",
            diffStat: nil,
            unstagedDiff: "old",
            stagedDiff: nil,
            truncated: false,
            truncatedNote: nil
        )
        let currentStatus = GitStatusResponse(
            path: path,
            isRepository: true,
            branch: "mac-b",
            head: "bbb",
            statusText: nil,
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: nil,
            truncated: false,
            truncatedNote: nil
        )
        let gate = GitStatusResponseGate()
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            gitStatusHandler: { requestedPath in
                try await gate.response(for: requestedPath)
            }
        )
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        var clientFactoryCallCount = 0
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: {
                clientFactoryCallCount += 1
                return client
            }
        )
        let previousScope = appStore.activeHostScope

        let refreshTask = Task { @MainActor in
            await store.refreshGitStatus(path: path)
        }
        await gate.waitUntilStarted()
        XCTAssertEqual(clientFactoryCallCount, 1)

        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "mac-b", displayName: "Mac B"),
            installationID: "installation-b"
        ))
        XCTAssertNotEqual(appStore.activeHostScope, previousScope)
        // 模拟 B 已经发布自己的同路径状态；A 的迟到结果和 defer 都不能覆盖它。
        store.gitStatusByPath[path] = currentStatus
        store.isRefreshingGitStatus = true

        await gate.resolve(oldStatus)
        await refreshTask.value

        XCTAssertEqual(clientFactoryCallCount, 1, "await 后不得重新从全局工厂获取新主机 client")
        XCTAssertEqual(store.gitStatusByPath[path], currentStatus)
        XCTAssertTrue(store.isRefreshingGitStatus, "旧主机 defer 不能清掉新主机的 loading")
        XCTAssertNil(store.gitStatusErrorByPath[path])
    }

    func testSessionStorePerformsGitActionAndUpdatesCachedStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_action", projectID: project.id, title: "暂存 Git", status: "history", source: "codex", resumeID: "git-action")
        let updatedStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "abc123",
            statusText: "M  README.md",
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: "@@ -1 +1 @@\n-before\n+after",
            files: [
                GitFileStatus(path: "README.md", code: "M ", staged: true, unstaged: false, untracked: false)
            ],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitActionResults: [session.dir: .success(updatedStatus)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.performSelectedGitAction(.stage, files: ["README.md"])

        XCTAssertEqual(client.requestedGitActions, [
            RequestedGitAction(path: session.dir, action: .stage, files: ["README.md"])
        ])
        XCTAssertEqual(store.selectedGitStatus?.stagedDiff, updatedStatus.stagedDiff)
        XCTAssertEqual(store.selectedGitStatus?.files.first?.path, "README.md")
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStorePerformsGitPatchActionAndUpdatesCachedStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_patch_action", projectID: project.id, title: "暂存 hunk", status: "history", source: "codex", resumeID: "git-patch-action")
        let patch = "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-before\n+after\n"
        let updatedStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "abc123",
            statusText: "M  README.md",
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: patch,
            files: [
                GitFileStatus(path: "README.md", code: "M ", staged: true, unstaged: false, untracked: false)
            ],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPatchActionResults: [session.dir: .success(updatedStatus)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.performSelectedGitPatchAction(.stagePatch, patch: patch)

        XCTAssertEqual(client.requestedGitPatchActions, [
            RequestedGitPatchAction(path: session.dir, action: .stagePatch, patch: patch.trimmingCharacters(in: .whitespacesAndNewlines))
        ])
        XCTAssertEqual(store.selectedGitStatus?.stagedDiff, updatedStatus.stagedDiff)
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStoreCommitsGitChangesAndUpdatesCachedStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_commit", projectID: project.id, title: "提交 Git", status: "history", source: "codex", resumeID: "git-commit")
        let cleanStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "def456",
            statusText: nil,
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: nil,
            files: [],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitCommitResults: [session.dir: .success(cleanStatus)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.commitSelectedGitChanges(message: " update readme ")

        XCTAssertEqual(client.requestedGitCommits, [
            RequestedGitCommit(path: session.dir, message: "update readme")
        ])
        XCTAssertEqual(store.selectedGitStatus?.head, "def456")
        XCTAssertEqual(store.selectedGitStatus?.hasChanges, false)
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStorePushesGitBranchAndUpdatesStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_push", projectID: project.id, title: "Push Git", status: "history", source: "codex", resumeID: "git-push")
        let status = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "mimi/feature",
            head: "fed456",
            statusText: nil,
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: nil,
            files: [],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPushResults: [
                session.dir: .success(GitPushResponse(path: session.dir, remote: "origin", branch: "mimi/feature", output: "pushed", status: status))
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.pushSelectedGitBranch(remote: " origin ")

        XCTAssertEqual(client.requestedGitPushes, [
            RequestedGitPush(path: session.dir, remote: "origin")
        ])
        XCTAssertEqual(store.selectedGitStatus?.head, "fed456")
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStoreCreatesDraftPullRequestAndStoresURL() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_pr", projectID: project.id, title: "PR Git", status: "history", source: "codex", resumeID: "git-pr")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPullRequestResults: [
                session.dir: .success(GitPullRequestResponse(
                    path: session.dir,
                    branch: "mimi/feature",
                    url: "https://github.com/example/repo/pull/1",
                    output: "https://github.com/example/repo/pull/1"
                ))
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.createSelectedPullRequest(title: " Draft PR ", body: "Summary", draft: true)

        XCTAssertEqual(client.requestedGitPullRequests, [
            RequestedGitPullRequest(path: session.dir, title: "Draft PR", body: "Summary", draft: true)
        ])
        XCTAssertEqual(store.selectedPullRequestURL, "https://github.com/example/repo/pull/1")
        XCTAssertEqual(store.selectedPullRequestStatus?.branch, "mimi/feature")
        XCTAssertEqual(store.selectedPullRequestStatus?.title, "Draft PR")
        XCTAssertEqual(store.selectedPullRequestStatus?.isDraft, true)
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStoreRefreshesPullRequestStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_pr_status", projectID: project.id, title: "PR 状态", status: "history", source: "codex", resumeID: "git-pr-status")
        let status = GitPullRequestStatusResponse(
            path: session.dir,
            branch: "mimi/feature",
            exists: true,
            number: 42,
            title: "Review changes",
            state: "OPEN",
            url: "https://github.com/example/repo/pull/42",
            isDraft: false,
            reviewDecision: "REVIEW_REQUIRED",
            mergeStateStatus: "CLEAN",
            headRefName: "mimi/feature",
            baseRefName: "main"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPullRequestStatusResults: [session.dir: .success(status)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedPullRequestStatus()

        XCTAssertEqual(client.requestedGitPullRequestStatusPaths, [session.dir])
        XCTAssertEqual(store.selectedPullRequestStatus, status)
        XCTAssertEqual(store.selectedPullRequestURL, status.url)
        XCTAssertNil(store.selectedPullRequestStatusErrorMessage)
    }

    func testCommandActionDecodesConfirmationFlagWithSafeDefault() throws {
        let json = """
        {
          "path": "/Users/me/code/app",
          "actions": [
            {
              "id": "go-test",
              "name": "Go Test",
              "command": "go",
              "args": ["test", "./..."],
              "working_dir": "/Users/me/code/app",
              "timeout_seconds": 60
            },
            {
              "id": "clean-cache",
              "name": "Clean Cache",
              "command": "go",
              "args": ["clean", "-cache"],
              "working_dir": "/Users/me/code/app",
              "timeout_seconds": 30,
              "requires_confirmation": true
            }
          ]
        }
        """

        let response = try AgentAPIClient.decoder.decode(CommandActionListResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.actions.map(\.id), ["go-test", "clean-cache"])
        XCTAssertFalse(response.actions[0].requiresConfirmation)
        XCTAssertTrue(response.actions[1].requiresConfirmation)
    }

    func testSessionStoreLoadsAndRunsCommandActions() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_action", projectID: project.id, title: "运行动作", status: "history", source: "codex", resumeID: "action")
        let action = AgentCommandAction(
            id: "go-test",
            name: "Go Test",
            command: "go",
            args: ["test", "./..."],
            workingDir: session.dir,
            timeoutSeconds: 20,
            requiresConfirmation: true
        )
        let result = CommandActionRunResponse(
            id: action.id,
            name: action.name,
            path: session.dir,
            workingDir: session.dir,
            command: action.command,
            args: action.args,
            success: true,
            exitCode: 0,
            output: "ok",
            truncated: false,
            timedOut: false,
            durationMS: 42
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            commandActionResults: [session.dir: .success([action])],
            commandActionRunResults: ["\(session.dir)#\(action.id)": .success(result)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedCommandActions()
        await store.runSelectedCommandAction(action)

        XCTAssertEqual(client.requestedCommandActionPaths, [session.dir])
        XCTAssertEqual(client.requestedCommandActionRuns, [RequestedCommandActionRun(path: session.dir, id: action.id, confirmed: true)])
        XCTAssertEqual(store.selectedCommandActions, [action])
        XCTAssertEqual(store.selectedCommandActionResult, result)
        XCTAssertEqual(store.selectedCommandActionHistory, [result])
        XCTAssertNil(store.selectedCommandActionErrorMessage)
    }

    func testSessionStoreQueuesCommandActionsFIFO() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_action_queue", projectID: project.id, title: "动作队列", status: "history", source: "codex", resumeID: "action-queue")
        let firstAction = AgentCommandAction(
            id: "lint",
            name: "Lint",
            command: "npm",
            args: ["run", "lint"],
            workingDir: session.dir,
            timeoutSeconds: 30
        )
        let secondAction = AgentCommandAction(
            id: "test",
            name: "Test",
            command: "go",
            args: ["test", "./..."],
            workingDir: session.dir,
            timeoutSeconds: 60
        )
        let firstResult = CommandActionRunResponse(
            id: firstAction.id,
            name: firstAction.name,
            path: session.dir,
            workingDir: session.dir,
            command: firstAction.command,
            args: firstAction.args,
            success: true,
            exitCode: 0,
            output: "lint ok",
            truncated: false,
            timedOut: false,
            durationMS: 20
        )
        let secondResult = CommandActionRunResponse(
            id: secondAction.id,
            name: secondAction.name,
            path: session.dir,
            workingDir: session.dir,
            command: secondAction.command,
            args: secondAction.args,
            success: true,
            exitCode: 0,
            output: "test ok",
            truncated: false,
            timedOut: false,
            durationMS: 40
        )
        let client = DelayedCommandActionClient(
            projects: [project],
            sessions: [session],
            actionsByPath: [session.dir: [firstAction, secondAction]],
            runResults: [
                "\(session.dir)#\(firstAction.id)": .success(firstResult),
                "\(session.dir)#\(secondAction.id)": .success(secondResult)
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedCommandActions()

        let runningTask = Task { await store.runSelectedCommandAction(firstAction) }
        await client.waitForRunRequestCount(1)

        XCTAssertEqual(store.runningCommandActionPath, session.dir)
        XCTAssertEqual(store.runningCommandActionID, firstAction.id)
        XCTAssertEqual(store.selectedQueuedCommandActionIDs, [])

        await store.runSelectedCommandAction(secondAction)

        XCTAssertEqual(client.requestedCommandActionRuns, [RequestedCommandActionRun(path: session.dir, id: firstAction.id, confirmed: false)])
        XCTAssertEqual(store.selectedQueuedCommandActionIDs, [secondAction.id])

        client.resolveRun(at: 0)
        await client.waitForRunRequestCount(2)

        XCTAssertEqual(store.runningCommandActionPath, session.dir)
        XCTAssertEqual(store.runningCommandActionID, secondAction.id)
        XCTAssertEqual(store.selectedQueuedCommandActionIDs, [])

        client.resolveRun(at: 1)
        await runningTask.value

        XCTAssertNil(store.runningCommandActionPath)
        XCTAssertNil(store.runningCommandActionID)
        XCTAssertEqual(
            client.requestedCommandActionRuns,
            [
                RequestedCommandActionRun(path: session.dir, id: firstAction.id, confirmed: false),
                RequestedCommandActionRun(path: session.dir, id: secondAction.id, confirmed: false)
            ]
        )
        XCTAssertEqual(store.selectedCommandActionHistory, [secondResult, firstResult])
        XCTAssertNil(store.selectedCommandActionErrorMessage)
    }

    func testSessionStoreRefreshesCapabilitiesForSelectedPath() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_caps", projectID: project.id, title: "能力", status: "history", source: "codex", resumeID: "caps")
        let response = CapabilityListResponse(
            path: session.dir,
            skills: [
                SkillCapability(name: "review", description: "Review changes", scope: "repo", path: "\(session.dir)/.agents/skills/review/SKILL.md", enabled: true)
            ],
            mcpServers: [
                MCPCapability(name: "context7", scope: "user", configPath: "/Users/me/.codex/config.toml", transport: "stdio", command: "npx", url: nil, enabled: true, plugin: nil)
            ]
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            capabilityResults: [session.dir: .success(response)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshCapabilities()
        await store.refreshCapabilities(forceReload: true)

        XCTAssertEqual(client.requestedCapabilityPaths, [session.dir, session.dir])
        XCTAssertEqual(client.requestedCapabilityForceReloads, [false, true])
        XCTAssertEqual(store.capabilityList, response)
        XCTAssertNil(store.capabilityErrorMessage)
    }

    func testRememberWorkspaceMigratesLegacySelectionSessionsAndCustomAvatar() throws {
        let suiteName = "WorkspaceIdentityMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        let legacy = AgentWorkspace(
            id: "legacy-project-id",
            name: "chat-archive",
            path: "/Users/me/code/chat-archive-link",
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let canonical = AgentWorkspace(
            id: "ws_canonical",
            name: "chat-archive",
            path: "/Users/me/code/chat-archive",
            lastOpenedAt: Date(timeIntervalSince1970: 20)
        )
        let other = AgentWorkspace(
            id: "ws_other",
            name: "other",
            path: "/Users/me/code/other",
            lastOpenedAt: Date(timeIntervalSince1970: 5)
        )
        let recentStore = RecentWorkspaceStore(defaults: defaults)
        recentStore.save(
            [legacy, other],
            profileID: appStore.notificationRoutingProfileID
        )
        let appearanceStore = WorkspaceAppearanceStore(defaults: defaults)
        appearanceStore.setCustomCharacterID(
            "nezha",
            profileID: appStore.notificationRoutingProfileID,
            projectID: legacy.id
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: recentStore,
            workspaceAppearanceStore: appearanceStore,
            clientFactory: {
                MockSessionStoreClient(projects: [], sessions: [])
            }
        )
        store.reloadRecentWorkspaces()
        store.sessions = [
            AgentSession(
                id: "session-legacy",
                projectID: legacy.id,
                project: legacy.name,
                dir: legacy.path,
                title: "历史会话",
                status: "history",
                source: "codex",
                resumeID: "thread-legacy",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)
            )
        ]
        store.setSelectedProjectID(legacy.id)
        store.setSessionWorkspaceIDs([legacy.id])
        store.insertExpandedProjectID(legacy.id)

        let remembered = store.rememberWorkspace(
            canonical,
            equivalentPaths: [legacy.path]
        )

        XCTAssertEqual(remembered.id, canonical.id)
        XCTAssertEqual(store.recentWorkspaces.map(\.id), [canonical.id, other.id])
        XCTAssertEqual(store.sidebarProjects.map(\.id), [canonical.id, other.id])
        XCTAssertEqual(store.selectedProjectID, canonical.id)
        XCTAssertEqual(store.retainedWorkspaceID(for: legacy.id), canonical.id)
        XCTAssertEqual(store.sessions.map(\.projectID), [canonical.id])
        XCTAssertEqual(store.sessionWorkspaceIDs, Set([canonical.id]))
        XCTAssertEqual(store.expandedProjectIDs, Set([canonical.id]))
        XCTAssertEqual(
            appearanceStore.customCharacterID(
                profileID: appStore.notificationRoutingProfileID,
                projectID: canonical.id
            ),
            "nezha"
        )
        XCTAssertNil(
            appearanceStore.customCharacterID(
                profileID: appStore.notificationRoutingProfileID,
                projectID: legacy.id
            )
        )
    }

    func testColdLaunchWorkspaceMigrationPreservesPersistedWorkspaceFilter() throws {
        let suiteName = "ColdLaunchWorkspaceIdentityMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        let profileID = appStore.notificationRoutingProfileID
        let legacy = AgentWorkspace(
            id: "legacy-project-id",
            name: "chat-archive",
            path: "/Users/me/code/chat-archive/",
            lastOpenedAt: Date(timeIntervalSince1970: 20)
        )
        let canonical = AgentWorkspace(
            id: "ws_canonical",
            name: "chat-archive",
            path: "/Users/me/code/chat-archive",
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let other = AgentWorkspace(
            id: "ws_other",
            name: "other",
            path: "/Users/me/code/other",
            lastOpenedAt: Date(timeIntervalSince1970: 5)
        )
        var rawStorage = ProfileScopedStorage<[AgentWorkspace]>()
        rawStorage.byProfileID[profileID] = [legacy, canonical, other]
        defaults.set(
            try JSONEncoder().encode(rawStorage),
            forKey: "agentd.recentWorkspaces"
        )
        let preferenceStore = SessionListPreferenceStore(defaults: defaults)
        preferenceStore.save(
            SessionListPreferences(sessionWorkspaceIDs: [legacy.id]),
            profileID: profileID
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: RecentWorkspaceStore(defaults: defaults),
            sessionListPreferenceStore: preferenceStore,
            clientFactory: {
                MockSessionStoreClient(projects: [], sessions: [])
            }
        )

        XCTAssertEqual(store.sessionWorkspaceIDs, Set([legacy.id]))
        store.reloadRecentWorkspaces()

        XCTAssertEqual(store.recentWorkspaces.map(\.id), [canonical.id, other.id])
        XCTAssertEqual(store.sessionWorkspaceIDs, Set([canonical.id]))
        XCTAssertEqual(
            preferenceStore.load(profileID: profileID).sessionWorkspaceIDs,
            Set([canonical.id])
        )
    }

    func testOpeningSameResolvedDirectoryTwiceReusesWorkspaceAndSelection() async {
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let typedPath = "/Users/me/code/chat-archive"
        let workspace = AgentWorkspace(
            id: "ws_canonical",
            name: "chat-archive",
            path: typedPath,
            rootProjectID: "project-root",
            rootProjectName: "chat-archive",
            rootProjectPath: typedPath
        )
        let recentStore = makeRecentWorkspaceStore(
            workspaces: [],
            endpoint: appStore.endpoint
        )
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            workspaceSessions: [workspace.id: []],
            resolveResults: [typedPath: .success(workspace)]
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: recentStore,
            clientFactory: { client }
        )

        let firstOpenSucceeded = await store.openWorkspace(path: typedPath)
        XCTAssertTrue(firstOpenSucceeded)
        let firstOpenedAt = store.recentWorkspaces.first?.lastOpenedAt
        let secondOpenSucceeded = await store.openWorkspace(path: typedPath)
        XCTAssertTrue(secondOpenSucceeded)

        XCTAssertEqual(client.requestedResolvePaths, [typedPath, typedPath])
        XCTAssertEqual(store.recentWorkspaces.map(\.id), [workspace.id])
        XCTAssertEqual(store.selectedProjectID, workspace.id)
        XCTAssertNotNil(firstOpenedAt)
        XCTAssertGreaterThanOrEqual(
            store.recentWorkspaces.first?.lastOpenedAt ?? .distantPast,
            firstOpenedAt ?? .distantFuture
        )
    }

}

private actor GitStatusResponseGate {
    private var continuation: CheckedContinuation<GitStatusResponse, Error>?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func response(for path: String) async throws -> GitStatusResponse {
        _ = path
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resolve(_ response: GitStatusResponse) {
        continuation?.resume(returning: response)
        continuation = nil
    }
}

private struct SessionArchiveGateRequest: Hashable {
    let id: SessionID
    let archived: Bool
}

private actor SessionArchiveResponseGate {
    private var requests: [SessionArchiveGateRequest] = []
    private var continuations: [SessionArchiveGateRequest: [CheckedContinuation<Void, Error>]] = [:]
    private var requestCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func response(id: SessionID, archived: Bool) async throws {
        let request = SessionArchiveGateRequest(id: id, archived: archived)
        try await withCheckedThrowingContinuation { continuation in
            requests.append(request)
            continuations[request, default: []].append(continuation)
            let ready = requestCountWaiters.filter { requests.count >= $0.count }
            requestCountWaiters.removeAll { requests.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }
    }

    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append((count, continuation))
        }
    }

    func resolve(id: SessionID, archived: Bool) {
        takeContinuation(id: id, archived: archived)?.resume()
    }

    func fail(id: SessionID, archived: Bool, error: Error) {
        takeContinuation(id: id, archived: archived)?.resume(throwing: error)
    }

    private func takeContinuation(
        id: SessionID,
        archived: Bool
    ) -> CheckedContinuation<Void, Error>? {
        let request = SessionArchiveGateRequest(id: id, archived: archived)
        guard var pending = continuations[request], !pending.isEmpty else {
            return nil
        }
        let continuation = pending.removeFirst()
        if pending.isEmpty {
            continuations.removeValue(forKey: request)
        } else {
            continuations[request] = pending
        }
        return continuation
    }
}

/// 按顺序吐出预设的账号用量结果，用来构造“先成功、后失败”的刷新序列。
private actor FetchOutcomeCursor {
    private var outcomes: [AccountTokenUsageFetch]

    init(_ outcomes: [AccountTokenUsageFetch]) {
        self.outcomes = outcomes
    }

    func next() -> AccountTokenUsageFetch {
        outcomes.isEmpty ? .failed : outcomes.removeFirst()
    }
}

private actor AccountTokenUsageResponseGate {
    private var continuation: CheckedContinuation<AccountTokenUsageSnapshot?, Never>?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func response() async -> AccountTokenUsageSnapshot? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resolve(_ snapshot: AccountTokenUsageSnapshot?) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
