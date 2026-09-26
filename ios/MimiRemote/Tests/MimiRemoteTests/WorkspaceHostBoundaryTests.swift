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
