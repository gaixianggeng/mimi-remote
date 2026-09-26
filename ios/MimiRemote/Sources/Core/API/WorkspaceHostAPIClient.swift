import Foundation

/// 主机资源由 agentd REST 提供；工作区浏览不应创建任一 Agent 会话 Runtime。
protocol WorkspaceHostAPIClient {
    func projects() async throws -> [AgentProject]
    func resolveWorkspace(path: String) async throws -> AgentWorkspace
    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse
    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse
    func listWorktrees() async throws -> [WorktreeListItem]
    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse
    func pruneMissingWorktrees() async throws -> WorktreePruneResponse
    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse
    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse
    func listDirectories(path: String) async throws -> DirectoryListResponse
    func readFile(path: String) async throws -> FileReadResponse
    func readHistoryMedia(id: String) async throws -> FileReadResponse
    func readHistoryOutput(id: String) async throws -> FileReadResponse
    func commandActions(path: String) async throws -> [AgentCommandAction]
    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse
}

extension AgentAPIClient: WorkspaceHostAPIClient {}

/// 仅兼容显式注入的旧测试客户端；生产入口直接使用 AgentAPIClient。
struct SessionClientWorkspaceHostAdapter: WorkspaceHostAPIClient {
    let client: any SessionStoreAPIClient

    func projects() async throws -> [AgentProject] { try await client.projects() }
    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        try await client.resolveWorkspace(path: path)
    }
    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        try await client.createWorktree(path: path, name: name, base: base, branch: branch)
    }
    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse {
        try await client.worktreeBranches(path: path)
    }
    func listWorktrees() async throws -> [WorktreeListItem] { try await client.listWorktrees() }
    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse {
        try await client.deleteWorktree(path: path, force: force)
    }
    func pruneMissingWorktrees() async throws -> WorktreePruneResponse { try await client.pruneMissingWorktrees() }
    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse { try await client.previewWorktreeCleanup() }
    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse {
        try await client.executeWorktreeCleanup(paths: paths, planID: planID)
    }
    func listDirectories(path: String) async throws -> DirectoryListResponse {
        try await client.listDirectories(path: path)
    }
    func readFile(path: String) async throws -> FileReadResponse { try await client.readFile(path: path) }
    func readHistoryMedia(id: String) async throws -> FileReadResponse { try await client.readHistoryMedia(id: id) }
    func readHistoryOutput(id: String) async throws -> FileReadResponse { try await client.readHistoryOutput(id: id) }
    func commandActions(path: String) async throws -> [AgentCommandAction] {
        try await client.commandActions(path: path)
    }
    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        try await client.runCommandAction(path: path, id: id, confirmed: confirmed)
    }
}
