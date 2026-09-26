import Foundation

/// agentd 主机级 Git 能力。没有 session、runtime、消息或审批方法。
protocol WorkspaceGitAPIClient {
    func gitStatus(path: String) async throws -> GitStatusResponse
    func gitStatusSummary(path: String) async throws -> GitStatusResponse
    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse
    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse
    func gitCommit(path: String, message: String) async throws -> GitStatusResponse
    func gitPush(path: String, remote: String?) async throws -> GitPushResponse
    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse
    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse
    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse
    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse
    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse
}

extension AgentAPIClient: WorkspaceGitAPIClient {
    func gitStatus(path: String) async throws -> GitStatusResponse {
        try await gitStatus(path: path, summaryOnly: false)
    }

    func gitStatusSummary(path: String) async throws -> GitStatusResponse {
        try await gitStatus(path: path, summaryOnly: true)
    }
}

/// 仅为显式注入的旧 SessionStoreAPIClient 保留测试/嵌入式兼容；生产组合根使用 AgentAPIClient。
/// 不做失败回退，不重新向工厂取客户端，复合 Git 操作始终使用同一个冻结目标。
struct SessionClientWorkspaceGitAdapter: WorkspaceGitAPIClient {
    let client: any SessionStoreAPIClient

    func gitStatus(path: String) async throws -> GitStatusResponse {
        try await client.gitStatus(path: path)
    }

    func gitStatusSummary(path: String) async throws -> GitStatusResponse {
        try await client.gitStatusSummary(path: path)
    }

    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse {
        try await client.gitAction(path: path, action: action, files: files)
    }

    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse {
        try await client.gitPatchAction(path: path, action: action, patch: patch)
    }

    func gitCommit(path: String, message: String) async throws -> GitStatusResponse {
        try await client.gitCommit(path: path, message: message)
    }

    func gitPush(path: String, remote: String?) async throws -> GitPushResponse {
        try await client.gitPush(path: path, remote: remote)
    }

    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse {
        try await client.gitQuickPublish(path: path, message: message, remote: remote, confirmed: confirmed)
    }

    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse {
        try await client.gitTestFlightStatus(path: path)
    }

    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse {
        try await client.gitTestFlightRun(path: path, whatToTest: whatToTest, confirmed: confirmed)
    }

    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse {
        try await client.gitCreatePullRequest(path: path, title: title, body: body, draft: draft)
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        try await client.gitPullRequestStatus(path: path)
    }
}
