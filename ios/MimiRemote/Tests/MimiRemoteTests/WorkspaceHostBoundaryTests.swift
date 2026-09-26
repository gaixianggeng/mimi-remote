import XCTest
@testable import MimiRemote

@MainActor
final class WorkspaceHostBoundaryTests: XCTestCase {
    private let root = AgentProject(id: "root", name: "Root", path: "/tmp/root")

    func testWorkspaceBootstrapCatalogAndWorktreeListDoNotCreateSessionRuntime() async throws {
        let host = WorkspaceHostProbe(projects: [root])
        var sessionClientCreations = 0
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: {
                sessionClientCreations += 1
                throw AgentAPIError.invalidResponse
            },
            workspaceHostClientFactory: { host }
        )

        try await store.refreshWorkspaceCatalog()
        await store.refreshManagedWorktrees()
        await store.refreshAll()

        XCTAssertEqual(sessionClientCreations, 0)
        XCTAssertEqual(host.projectRequests, 2)
        XCTAssertEqual(host.worktreeListRequests, 1)
        XCTAssertEqual(store.projects, [root])
    }

    func testOldHostWorktreeCreateCannotWriteNewHostWorkspaceState() async throws {
        let appStore = makeIsolatedAppStore()
        let gate = WorkspaceCreateResponseGate()
        let host = WorkspaceHostProbe(projects: [root])
        host.createHandler = { await gate.waitForResponse() }
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { throw AgentAPIError.invalidResponse },
            workspaceHostClientFactory: { host }
        )

        let task = Task { await store.createWorktreeAndOpen(project: root) }
        await gate.waitForRequest()
        let oldScope = appStore.activeHostScope
        try await switchHost(appStore)
        XCTAssertNotEqual(appStore.activeHostScope, oldScope)
        store.clearConnectionData()
        gate.finish(worktreeResponse())

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertNil(store.workspacesByID["old-worktree"])
        XCTAssertTrue(store.managedWorktrees.isEmpty)
    }

    func testOldHostWorktreeListCannotReplaceCurrentDataOrLoading() async throws {
        let appStore = makeIsolatedAppStore()
        let host = WorkspaceHostProbe(projects: [root])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { throw AgentAPIError.invalidResponse },
            workspaceHostClientFactory: { host }
        )
        host.listHandler = {
            try await self.switchHost(appStore)
            store.clearConnectionData()
            store.worktreeErrorMessage = "new-host-error"
            store.isRefreshingWorktrees = true
            let response = self.worktreeResponse()
            return [WorktreeListItem(workspace: response.workspace, worktree: response.worktree)]
        }

        await store.refreshManagedWorktrees()

        XCTAssertTrue(store.managedWorktrees.isEmpty)
        XCTAssertEqual(store.worktreeErrorMessage, "new-host-error")
        XCTAssertTrue(store.isRefreshingWorktrees)
    }

    func testOldHostCatalogFailureBecomesCancellation() async throws {
        let appStore = makeIsolatedAppStore()
        let host = WorkspaceHostProbe(projects: [root])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { throw AgentAPIError.invalidResponse },
            workspaceHostClientFactory: { host }
        )
        host.projectHandler = {
            try await self.switchHost(appStore)
            throw URLError(.timedOut)
        }

        do {
            try await store.refreshWorkspaceCatalog()
            XCTFail("旧主机请求必须取消")
        } catch is CancellationError {
            XCTAssertTrue(store.projects.isEmpty)
        }
    }

    func testHandoffHistorySuccessAfterHostSwitchCannotWriteNewHostConversation() async throws {
        try await assertOldHostHandoffCannotWriteNewHost(historyError: nil)
    }

    func testHandoffHistoryCancellationAfterHostSwitchCannotWriteNewHostConversation() async throws {
        try await assertOldHostHandoffCannotWriteNewHost(historyError: CancellationError())
    }

    func testCancelledHandoffCannotAppendCompletionAfterHistoryReturns() async {
        let fixture = handoffFixture()
        let task = Task { await fixture.store.handoffSessionToWorktree(fixture.source) }
        await fixture.history.waitForHistoryRequestCount(1)

        task.cancel()
        fixture.history.resolveHistoryRequest(at: 0, with: HistoryMessagesPage(messages: []))

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertTrue(fixture.store.conversationStore.messages(for: fixture.forked.id).isEmpty)
    }

    func testHandoffHistoryCompletionAppendsToForkedConversation() async {
        await assertHandoffAppendsCompletion(navigateAway: false)
    }

    func testHandoffHistoryCompletionAfterSameHostNavigationKeepsForkedConversation() async {
        await assertHandoffAppendsCompletion(navigateAway: true)
    }

    private func assertOldHostHandoffCannotWriteNewHost(historyError: Error?) async throws {
        let fixture = handoffFixture()
        let task = Task { await fixture.store.handoffSessionToWorktree(fixture.source) }
        await fixture.history.waitForHistoryRequestCount(1)
        let oldScope = fixture.store.appStore.activeHostScope

        // 使用真实提交入口切换 ConversationStore namespace，并取消旧历史 job。
        _ = try await fixture.store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "host-b", displayName: "Host B"),
            installationID: "installation-b"
        ))
        XCTAssertNotEqual(fixture.store.appStore.activeHostScope, oldScope)
        fixture.store.conversationStore.appendSystem("new-host-message", sessionID: fixture.forked.id)

        if let historyError {
            fixture.history.failHistoryRequest(at: 0, with: historyError)
        } else {
            fixture.history.resolveHistoryRequest(at: 0, with: HistoryMessagesPage(messages: []))
        }

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(
            fixture.store.conversationStore.messages(for: fixture.forked.id).map(\.content),
            ["new-host-message"]
        )
    }

    private func assertHandoffAppendsCompletion(navigateAway: Bool) async {
        let fixture = handoffFixture()
        let task = Task { await fixture.store.handoffSessionToWorktree(fixture.source) }
        await fixture.history.waitForHistoryRequestCount(1)

        if navigateAway {
            _ = fixture.store.commitSelection(
                projectID: root.id,
                sessionID: fixture.source.id,
                reason: .userOpen
            )
        }
        fixture.history.resolveHistoryRequest(at: 0, with: HistoryMessagesPage(messages: []))

        let result = await task.value
        XCTAssertTrue(result)
        XCTAssertEqual(
            fixture.store.selectedSessionID,
            navigateAway ? fixture.source.id : fixture.forked.id
        )
        XCTAssertEqual(
            fixture.store.conversationStore.messages(for: fixture.forked.id).map(\.content),
            [L10n.text("ui.this_worktree_has_been_forked_from_the_source")]
        )
        XCTAssertTrue(fixture.store.conversationStore.messages(for: fixture.source.id).isEmpty)
    }

    private func handoffFixture() -> (
        store: SessionStore, source: AgentSession, forked: AgentSession, history: OrderedHistoryPageClient
    ) {
        let response = worktreeResponse()
        let source = AgentSession(
            id: "source-thread", projectID: root.id, project: root.name, dir: root.path,
            title: "Source", status: "history", source: "codex", resumeID: "source-thread",
            createdAt: nil, updatedAt: nil
        )
        let forked = AgentSession(
            id: "forked-thread", projectID: response.workspace.id,
            project: response.workspace.name, dir: response.workspace.path,
            title: "Forked", status: "history", source: "codex", resumeID: "forked-thread",
            createdAt: nil, updatedAt: nil
        )
        let history = OrderedHistoryPageClient(projects: [root], page: SessionsPage(sessions: []))
        let client = HandoffHistoryClient(forked: forked, history: history)
        let host = WorkspaceHostProbe(projects: [root])
        host.createHandler = { response }
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            workspaceHostClientFactory: { host }
        )
        store.projects = [root]
        store.sessions = [source]
        return (store, source, forked, history)
    }

    private func switchHost(_ appStore: AppStore) async throws {
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "host-b", displayName: "Host B"),
            installationID: "installation-b"
        ))
    }

    private func worktreeResponse() -> WorktreeCreateResponse {
        let workspace = AgentWorkspace(id: "old-worktree", name: "Old", path: "/tmp/root/old")
        let descriptor = WorktreeDescriptor(
            path: workspace.path, repositoryPath: root.path, base: "main", branch: "old",
            gitState: "clean", dirty: false, ahead: 0, behind: 0, upstream: nil,
            rootProjectID: root.id, rootProjectName: root.name, rootProjectPath: root.path
        )
        return WorktreeCreateResponse(workspace: workspace, worktree: descriptor)
    }
}

/// 复用可控历史响应，只为 handoff 提供列表和 fork；其他写操作仍明确失败。
private final class HandoffHistoryClient: SessionStoreAPIClient {
    let forked: AgentSession
    let history: OrderedHistoryPageClient

    init(forked: AgentSession, history: OrderedHistoryPageClient) {
        self.forked = forked
        self.history = history
    }

    func projects() async throws -> [AgentProject] { try await history.projects() }
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await history.sessions(projectID: projectID, cursor: cursor, limit: limit)
    }
    func forkSession(
        threadID: String,
        workspace: AgentWorkspace,
        reason: AgentSessionForkReason,
        lastTurnID: TurnID?
    ) async throws -> AgentSession {
        forked
    }
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw AgentAPIError.invalidResponse
    }
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw AgentAPIError.invalidResponse
    }
    func stopSession(id: String) async throws { throw AgentAPIError.invalidResponse }
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        try await history.messages(sessionID: sessionID, before: before, limit: limit)
    }
    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        try await history.messagesPage(sessionID: sessionID, before: before, limit: limit)
    }
}

@MainActor
private final class WorkspaceCreateResponseGate {
    private var request: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<WorktreeCreateResponse, Never>?

    func waitForRequest() async {
        if response != nil { return }
        await withCheckedContinuation { request = $0 }
    }

    func waitForResponse() async -> WorktreeCreateResponse {
        await withCheckedContinuation { continuation in
            response = continuation
            request?.resume()
            request = nil
        }
    }

    func finish(_ value: WorktreeCreateResponse) {
        response?.resume(returning: value)
        response = nil
    }
}

/// 未使用的主机能力显式失败，确保测试不会误把会话请求当作成功。
@MainActor
private final class WorkspaceHostProbe: WorkspaceHostAPIClient {
    let catalog: [AgentProject]
    var projectRequests = 0
    var projectHandler: (@MainActor () async throws -> [AgentProject])?
    var worktreeListRequests = 0
    var listHandler: (@MainActor () async throws -> [WorktreeListItem])?
    var createHandler: (@MainActor () async -> WorktreeCreateResponse)?

    init(projects: [AgentProject]) { catalog = projects }

    func projects() async throws -> [AgentProject] {
        projectRequests += 1
        if let projectHandler { return try await projectHandler() }
        return catalog
    }
    func listWorktrees() async throws -> [WorktreeListItem] {
        worktreeListRequests += 1
        if let listHandler { return try await listHandler() }
        return []
    }
    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        guard let createHandler else { throw AgentAPIError.invalidResponse }
        return await createHandler()
    }
    func resolveWorkspace(path: String) async throws -> AgentWorkspace { throw AgentAPIError.invalidResponse }
    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse { throw AgentAPIError.invalidResponse }
    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse { throw AgentAPIError.invalidResponse }
    func pruneMissingWorktrees() async throws -> WorktreePruneResponse { throw AgentAPIError.invalidResponse }
    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse { throw AgentAPIError.invalidResponse }
    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse { throw AgentAPIError.invalidResponse }
    func listDirectories(path: String) async throws -> DirectoryListResponse { throw AgentAPIError.invalidResponse }
    func readFile(path: String) async throws -> FileReadResponse { throw AgentAPIError.invalidResponse }
    func readHistoryMedia(id: String) async throws -> FileReadResponse { throw AgentAPIError.invalidResponse }
    func readHistoryOutput(id: String) async throws -> FileReadResponse { throw AgentAPIError.invalidResponse }
    func commandActions(path: String) async throws -> [AgentCommandAction] { throw AgentAPIError.invalidResponse }
    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse { throw AgentAPIError.invalidResponse }
}
