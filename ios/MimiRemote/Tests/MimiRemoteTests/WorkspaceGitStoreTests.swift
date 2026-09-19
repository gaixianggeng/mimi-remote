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
}

/// 不实现任何会话 API；不支持的测试调用明确抛错，不用空成功掩盖错误路由。
private final class WorkspaceGitClientProbe: WorkspaceGitAPIClient {
    let status: GitStatusResponse
    var statusPaths: [String] = []
    var summaryPaths: [String] = []
    var quickPublishPaths: [String] = []
    var statusHandler: (@MainActor (String) async throws -> GitStatusResponse)?

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
        throw AgentAPIError.invalidResponse
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        throw AgentAPIError.invalidResponse
    }
}
