import Combine
import XCTest
@testable import MimiRemote

@MainActor
final class WorkspaceGitStoreTests: XCTestCase {
    private let path = "/tmp/mimi-git-test"

    func testExplicitGitClientDoesNotCreateSessionClient() async {
        let probe = WorkspaceGitClientProbe(status: status("host-result"))
        var sessionClientCreations = 0
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: {
                sessionClientCreations += 1
                throw AgentAPIError.invalidResponse
            },
            workspaceGitClientFactory: { probe }
        )

        await store.refreshGitStatus(path: path)

        XCTAssertEqual(sessionClientCreations, 0)
        XCTAssertEqual(probe.statusPaths, [path])
        XCTAssertEqual(store.gitStatusByPath[path]?.head, "host-result")
        XCTAssertEqual(store.workspaceGitStore.gitStatusByPath[path]?.head, "host-result")
    }

    func testFacadeSharesStorageAndForwardsObservation() {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { throw AgentAPIError.invalidResponse }
        )
        var changes = 0
        let observation = store.objectWillChange.sink { _ in changes += 1 }

        store.workspaceGitStore.gitStatusByPath[path] = status("one-owner")
        XCTAssertEqual(store.gitStatusByPath[path]?.head, "one-owner")
        store.gitStatusByPath.removeAll()
        XCTAssertTrue(store.workspaceGitStore.gitStatusByPath.isEmpty)
        XCTAssertGreaterThanOrEqual(changes, 2)
        withExtendedLifetime(observation) {}
    }

    func testOldHostSuccessCannotReplaceNewHostStateOrClearLoading() async {
        var scope = hostScope("a", generation: 1)
        let probe = WorkspaceGitClientProbe(status: status("old"))
        let store = WorkspaceGitStore(currentHostScope: { scope }, clientFactory: { probe })
        probe.statusHandler = { [self] _ in
            // 模拟请求已发出之后主机切换，B 已经发布自己的状态。
            scope = hostScope("b", generation: 2)
            store.gitStatusByPath[path] = status("new")
            store.isRefreshingGitStatus = true
            return status("old")
        }

        await store.refreshGitStatus(path: path)

        XCTAssertEqual(store.gitStatusByPath[path]?.head, "new")
        XCTAssertTrue(store.isRefreshingGitStatus)
        XCTAssertNil(store.workspaceGitSummaryByPath[path])
    }

    func testOldHostFailureCannotReplaceNewHostError() async {
        var scope = hostScope("a", generation: 1)
        let probe = WorkspaceGitClientProbe(status: status("old"))
        let store = WorkspaceGitStore(currentHostScope: { scope }, clientFactory: { probe })
        probe.statusHandler = { [self] _ in
            scope = hostScope("b", generation: 2)
            store.gitStatusErrorByPath[path] = "new-host-error"
            throw URLError(.timedOut)
        }

        await store.refreshGitStatus(path: path)

        XCTAssertEqual(store.gitStatusErrorByPath[path], "new-host-error")
    }

    func testQuickPublishFailureRefreshReusesCapturedClient() async {
        let probe = WorkspaceGitClientProbe(status: status("after-failure"))
        var creations = 0
        let store = WorkspaceGitStore(
            currentHostScope: { self.hostScope("a", generation: 1) },
            clientFactory: { creations += 1; return probe }
        )

        let succeeded = await store.quickPublishGitChanges(path: path, message: "test", remote: nil)

        XCTAssertEqual(creations, 1, "复合操作的恢复读取不得重新选择主机客户端")
        XCTAssertEqual(probe.quickPublishPaths, [path])
        XCTAssertEqual(probe.statusPaths, [path])
        XCTAssertEqual(store.gitStatusByPath[path]?.head, "after-failure")
        XCTAssertFalse(succeeded)
        XCTAssertFalse(store.isQuickPublishingGitChanges)
    }

    func testBlankPathDoesNotCreateClient() async {
        var creations = 0
        let store = WorkspaceGitStore(
            currentHostScope: { self.hostScope("a", generation: 1) },
            clientFactory: { creations += 1; throw AgentAPIError.invalidResponse }
        )

        await store.refreshGitStatus(path: " \n ")
        await store.refreshWorkspaceGitSummary(path: " ")

        XCTAssertEqual(creations, 0)
        XCTAssertTrue(store.gitStatusByPath.isEmpty)
    }

    func testSummaryTTLAndLightweightProjectionRemainIndependentOfSessions() async {
        let probe = WorkspaceGitClientProbe(status: status("cached"))
        let store = WorkspaceGitStore(
            currentHostScope: { self.hostScope("a", generation: 1) },
            clientFactory: { probe }
        )
        let now = Date(timeIntervalSince1970: 100)
        await store.refreshWorkspaceGitSummary(path: path, now: now)
        await store.refreshWorkspaceGitSummary(path: path, now: now.addingTimeInterval(30))
        XCTAssertEqual(probe.summaryPaths, [path])
        await store.refreshWorkspaceGitSummary(path: path, force: true, now: now.addingTimeInterval(31))
        XCTAssertEqual(probe.summaryPaths, [path, path])

        store.cacheWorkspaceGitSummary(status("full"), path: path, now: now)
        XCTAssertNil(store.workspaceGitSummaryByPath[path]?.unstagedDiff)
        XCTAssertEqual(store.workspaceGitSummaryByPath[path]?.head, "full")
    }

    func testCancelledSummaryTaskDoesNotStartGitRequest() async {
        let probe = WorkspaceGitClientProbe(status: status("cancelled"))
        var creations = 0
        let store = WorkspaceGitStore(
            currentHostScope: { self.hostScope("a", generation: 1) },
            clientFactory: { creations += 1; return probe }
        )
        let request = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await store.refreshWorkspaceGitSummary(path: path)
        }
        await request.value

        XCTAssertEqual(creations, 0, "已取消的摘要任务不得创建客户端")
        XCTAssertTrue(probe.summaryPaths.isEmpty, "已取消的摘要任务不得启动 Git 请求")
        XCTAssertNil(store.workspaceGitSummaryByPath[path])
        XCTAssertTrue(store.refreshingWorkspaceGitSummaryPaths.isEmpty)
    }

    private func hostScope(_ id: String, generation: UInt64) -> HostScope {
        HostScope(profileID: id, installationID: "test-\(id)", generation: generation)
    }

    private func status(_ head: String) -> GitStatusResponse {
        GitStatusResponse(
            path: path, isRepository: true, branch: "main", head: head,
            ahead: 0, behind: 0, upstream: "origin/main",
            statusText: " M README.md", diffStat: "README.md | 1 +",
            unstagedDiff: "+change", stagedDiff: nil, files: [],
            truncated: false, truncatedNote: nil
        )
    }

    // MARK: - #508 失败文案

    func testGitStatusFailureShowsReadableCopyInsteadOfRawTransportError() async {
        let probe = WorkspaceGitClientProbe(status: status("unused"))
        let store = WorkspaceGitStore(currentHostScope: { self.hostScope("a", generation: 1) }, clientFactory: { probe })
        probe.statusHandler = { _ in throw URLError(.cannotConnectToHost) }

        await store.refreshGitStatus(path: path)

        XCTAssertEqual(store.gitStatusErrorByPath[path], L10n.text("ui.error_host_unreachable"))
    }

    func testHostOperationMessageKeepsGitReasonButDropsProtocolNoise() {
        XCTAssertEqual(
            UserFacingError.hostOperationMessage(for: AgentAPIError.server(status: 409, message: "nothing to commit, working tree clean")),
            L10n.text("ui.git_nothing_to_commit")
        )
        XCTAssertEqual(
            UserFacingError.hostOperationMessage(for: AgentAPIError.server(status: 500, message: "app-server error -32603: internal")),
            L10n.text("ui.error_host_error")
        )
        XCTAssertEqual(
            UserFacingError.hostOperationMessage(for: AgentAPIError.server(status: 409, message: "push rejected for https://example.invalid/repo.git")),
            L10n.text("ui.error_rejected"),
            "没有「落后于远端」的明确信号时不能说先拉取，也不显示远端地址"
        )
        XCTAssertEqual(
            UserFacingError.hostOperationMessage(for: AgentAPIError.server(status: 401, message: "unauthorized")),
            ConnectionTerminationStatus.credentialsInvalid.message
        )
        XCTAssertEqual(UserFacingError.hostOperationMessage(for: URLError(.timedOut)), L10n.text("ui.error_timed_out"))
    }

    func testHostOperationMessageMapsCommonGitFailuresWithoutPathsOrRemotes() {
        func message(_ status: Int, _ output: String) -> String {
            UserFacingError.hostOperationMessage(for: AgentAPIError.server(status: status, message: output))
        }
        XCTAssertEqual(
            message(409, "error: failed to push some refs to 'git@github.com:owner/repo.git'\nhint: Updates were rejected because the remote contains work"),
            L10n.text("ui.git_push_rejected_pull_first")
        )
        XCTAssertEqual(message(409, "fatal: '/srv/worktrees/feature' already exists"), L10n.text("ui.git_already_exists"))
        XCTAssertEqual(
            message(409, "fatal: 'feature' contains modified or untracked files, use --force to delete it"),
            L10n.text("ui.git_local_changes_block")
        )
        XCTAssertEqual(
            message(409, "CONFLICT (content): Merge conflict in Sources/Account/Login.swift"),
            L10n.text("ui.git_merge_conflict")
        )
        for output in [message(409, "fatal: '/srv/worktrees/feature' already exists"), message(409, "error: failed to push some refs to 'git@github.com:owner/repo.git'")] {
            XCTAssertFalse(output.contains("/srv"), output)
            XCTAssertFalse(output.contains("github.com"), output)
        }
    }

    func testPushFailuresAreToldApartByWhatGitSaid() {
        func message(_ output: String) -> String {
            UserFacingError.hostOperationMessage(for: AgentAPIError.server(status: 409, message: output))
        }
        XCTAssertEqual(
            message(" ! [remote rejected] main -> main (protected branch hook declined)\nerror: failed to push some refs"),
            L10n.text("ui.git_push_remote_rejected")
        )
        XCTAssertEqual(
            message(" ! [rejected] v1.0 -> v1.0 (already exists)\nhint: Updates were rejected because the tag already exists in the remote."),
            L10n.text("ui.git_tag_already_exists")
        )
        XCTAssertEqual(
            message(" ! [rejected] main -> main (fetch first)\nhint: Updates were rejected because the remote contains work"),
            L10n.text("ui.git_push_rejected_pull_first")
        )
        XCTAssertNotEqual(message("error: remote origin already exists."), L10n.text("ui.git_already_exists"))
        XCTAssertEqual(message("fatal: 'feature-stage' already exists"), L10n.text("ui.git_already_exists"))
        XCTAssertEqual(message("fatal: 'release-tag' already exists"), L10n.text("ui.git_already_exists"))
        XCTAssertEqual(message("fatal: tag 'v1.0' already exists"), L10n.text("ui.git_tag_already_exists"))
        XCTAssertEqual(
            message(" ! [rejected] refs/tags/v2 -> refs/tags/v2 (already exists)"),
            L10n.text("ui.git_tag_already_exists")
        )

        XCTAssertFalse(UserFacingError.containsSensitiveDetail("Run codex login on the host machine"))
        XCTAssertTrue(UserFacingError.containsSensitiveDetail("Connection to mac-mini closed by remote host."))
        XCTAssertTrue(UserFacingError.containsSensitiveDetail("fatal: mac-mini:projects/repo does not appear to be a git repository"))
        XCTAssertTrue(UserFacingError.containsSensitiveDetail("Authentication failed for user alice"))
    }

    func testTagPushWithoutAdviceStillExplainsTheConflict() {
        let output = "To /srv/repos/remote.git\n ! [rejected]        v1.0 -> v1.0 (already exists)\nerror: failed to push some refs to '/srv/repos/remote.git'"
        XCTAssertEqual(
            UserFacingError.hostOperationMessage(for: AgentAPIError.server(status: 409, message: output)),
            L10n.text("ui.git_tag_already_exists")
        )
        XCTAssertNil(UserFacingError.gitOperationMessage(for: "fatal: remote origin already exists"))
    }

    func testBranchInUseByAnotherWorktreeExplainsHowToReleaseIt() {
        for phrase in ["already checked out", "already used by worktree"] {
            let output = "Preparing worktree (checking out 'main')\nfatal: 'main' is \(phrase) at '/srv/worktrees/private-project'"
            let message = UserFacingError.hostOperationMessage(for: AgentAPIError.server(status: 409, message: output))
            XCTAssertEqual(message, L10n.text("ui.git_branch_in_use"))
            XCTAssertFalse(message.contains("/srv"))
            XCTAssertFalse(message.contains("private-project"))
        }
    }

    func testHostOperationMessageUsesTheSameGateAsComputerReasons() {
        func message(_ status: Int, _ output: String) -> String {
            UserFacingError.hostOperationMessage(for: AgentAPIError.server(status: status, message: output))
        }
        // 4xx 单行可读原因照常显示。
        XCTAssertEqual(message(400, "branch name is invalid"), "branch name is invalid")
        // 5xx、HTML 错误页、多行 stderr 都只给分类文案。
        XCTAssertEqual(message(500, "branch is protected"), L10n.text("ui.error_host_error"))
        XCTAssertEqual(
            message(502, "<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>"),
            L10n.text("ui.error_host_error")
        )
        XCTAssertEqual(message(400, "fatal: bad revision\nhint: try again"), L10n.text("ui.error_rejected"))
        // 账号、仓库名、无后缀主机名不上主界面。
        XCTAssertEqual(
            message(403, "ERROR: Permission to owner/repo.git denied to someone."),
            L10n.text("ui.error_permission_denied")
        )
        XCTAssertEqual(
            message(400, "ssh: connect to host mac-mini port 22: Connection refused"),
            L10n.text("ui.error_rejected")
        )
        XCTAssertEqual(message(400, "git.corp.example.co refused the connection"), L10n.text("ui.error_rejected"))
    }

    func testExistingPullRequestIsNotReportedAsBranchCollision() async {
        let probe = WorkspaceGitClientProbe(status: status("unused"))
        let store = WorkspaceGitStore(currentHostScope: { self.hostScope("a", generation: 1) }, clientFactory: { probe })
        let existingURL = "https://github.com/owner/repo/pull/7"
        probe.createPullRequestHandler = { _ in
            throw AgentAPIError.server(
                status: 502,
                message: "a pull request for branch \"feature\" into branch \"main\" already exists:\n\(existingURL)"
            )
        }
        probe.pullRequestStatusHandler = { path in
            GitPullRequestStatusResponse(path: path, branch: "feature", exists: true, title: "Existing", url: existingURL, isDraft: false)
        }

        await store.createPullRequest(path: path, title: "New")

        XCTAssertEqual(store.gitActionErrorByPath[path], L10n.text("ui.git_pull_request_already_exists"))
        XCTAssertEqual(store.pullRequestURLByPath[path], existingURL, "面板应改为显示已有的 PR")
        XCTAssertNotEqual(
            UserFacingError.hostOperationMessage(for: AgentAPIError.server(status: 409, message: "label \"bug\" already exists")),
            L10n.text("ui.git_already_exists"),
            "其他工具的 already exists 不能说成同名分支或 Worktree"
        )
        XCTAssertEqual(
            UserFacingError.gitOperationMessage(for: "fatal: a branch named 'feature' already exists"),
            L10n.text("ui.git_already_exists")
        )
    }

    func testWorktreeCleanupConflictRequiresAFreshPlan() {
        XCTAssertTrue(WorktreeCleanupResponse.requiresFreshPlan(AgentAPIError.server(status: 409, message: "清理计划不存在或已过期，请重新 dry-run")))
        XCTAssertFalse(WorktreeCleanupResponse.requiresFreshPlan(AgentAPIError.server(status: 500, message: "boom")))
        XCTAssertFalse(WorktreeCleanupResponse.requiresFreshPlan(URLError(.timedOut)))
    }

    func testWorkspaceSessionLoadFailureUsesReadableCopy() {
        XCTAssertEqual(
            workspaceSessionLoadFailureDisposition(AgentAPIError.server(status: 503, message: "upstream unavailable")),
            .failed(L10n.text("ui.error_host_error"))
        )
        XCTAssertEqual(workspaceSessionLoadFailureDisposition(CancellationError()), .cancelled)
    }
}

/// 不实现任何会话 API；不支持的测试调用明确抛错，不用空成功掩盖错误路由。
private final class WorkspaceGitClientProbe: WorkspaceGitAPIClient {
    let status: GitStatusResponse
    var statusPaths: [String] = []
    var summaryPaths: [String] = []
    var quickPublishPaths: [String] = []
    var statusHandler: (@MainActor (String) async throws -> GitStatusResponse)?
    var createPullRequestHandler: (@MainActor (String) async throws -> GitPullRequestResponse)?
    var pullRequestStatusHandler: (@MainActor (String) async throws -> GitPullRequestStatusResponse)?

    init(status: GitStatusResponse) { self.status = status }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        statusPaths.append(path)
        if let statusHandler { return try await statusHandler(path) }
        return status
    }

    func gitStatusSummary(path: String) async throws -> GitStatusResponse {
        summaryPaths.append(path)
        return status
    }

    func gitPush(path: String, remote: String?) async throws -> GitPushResponse {
        throw AgentAPIError.server(status: 409, message: "test-push-rejected")
    }

    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse {
        throw AgentAPIError.invalidResponse
    }

    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse {
        throw AgentAPIError.invalidResponse
    }

    func gitCommit(path: String, message: String) async throws -> GitStatusResponse {
        throw AgentAPIError.invalidResponse
    }

    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse {
        quickPublishPaths.append(path)
        throw AgentAPIError.server(status: 409, message: "test-quick-publish-rejected")
    }

    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse {
        throw AgentAPIError.invalidResponse
    }

    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse {
        throw AgentAPIError.invalidResponse
    }

    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse {
        if let createPullRequestHandler { return try await createPullRequestHandler(path) }
        throw AgentAPIError.invalidResponse
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        if let pullRequestStatusHandler { return try await pullRequestStatusHandler(path) }
        throw AgentAPIError.invalidResponse
    }
}
