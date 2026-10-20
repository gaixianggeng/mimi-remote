import XCTest
@testable import MimiRemote

@MainActor
final class WorkspaceGitSummaryTests: XCTestCase {
    func testGitStatusDecodesOmittedFalseFileFlagsFromDeployedAgent() throws {
        let json = """
        {
          "path": "/tmp/repo",
          "is_repository": true,
          "branch": "main",
          "head": "780d0b3",
          "upstream": "origin/main",
          "files": [
            {
              "path": "README.md",
              "code": " M",
              "unstaged": true
            }
          ]
        }
        """

        let status = try AgentAPIClient.decoder.decode(GitStatusResponse.self, from: Data(json.utf8))

        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.files.count, 1)
        XCTAssertFalse(status.files[0].staged)
        XCTAssertTrue(status.files[0].unstaged)
        XCTAssertFalse(status.files[0].untracked)
    }

    func testSummaryCacheUsesTTLAndCanBeForced() async {
        let project = makeProject(id: "workspace-summary")
        let status = GitStatusResponse(
            path: project.path,
            isRepository: true,
            branch: "main",
            head: "abc123",
            ahead: 1,
            behind: 0,
            upstream: "origin/main",
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
            sessions: [],
            gitStatusResults: [project.path: .success(status)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        let initialDate = Date(timeIntervalSince1970: 100)

        await store.refreshWorkspaceGitSummary(path: project.path, now: initialDate)
        await store.refreshWorkspaceGitSummary(path: project.path, now: initialDate.addingTimeInterval(30))
        XCTAssertEqual(client.requestedGitStatusPaths, [project.path])
        XCTAssertEqual(store.workspaceGitSummaryByPath[project.path]?.ahead, 1)

        await store.refreshWorkspaceGitSummary(
            path: project.path,
            force: true,
            now: initialDate.addingTimeInterval(31)
        )
        XCTAssertEqual(client.requestedGitStatusPaths, [project.path, project.path])
    }

    func testFullGitRefreshProjectsOnlyLightweightFieldsIntoCardCache() {
        let path = "/tmp/workspace-summary"
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )
        store.workspaceGitSummaryByPath[path] = GitStatusResponse(
            path: path,
            isRepository: true,
            branch: "main",
            head: "old",
            ahead: 0,
            behind: 0,
            upstream: "origin/main",
            statusText: nil,
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: nil,
            files: [],
            truncated: false,
            truncatedNote: nil
        )
        let fullStatus = GitStatusResponse(
            path: path,
            isRepository: true,
            branch: "main",
            head: "new",
            statusText: " M README.md",
            diffStat: "README.md | 1 +",
            unstagedDiff: "+change",
            stagedDiff: nil,
            files: [
                GitFileStatus(
                    path: "README.md",
                    code: " M",
                    staged: false,
                    unstaged: true,
                    untracked: false
                )
            ],
            truncated: false,
            truncatedNote: nil
        )

        store.cacheWorkspaceGitSummary(fullStatus, path: path)

        let cached = store.workspaceGitSummaryByPath[path]
        XCTAssertEqual(cached?.head, "new")
        XCTAssertEqual(cached?.upstream, "origin/main")
        XCTAssertEqual(cached?.files.map(\.path), ["README.md"])
        XCTAssertNil(cached?.statusText)
        XCTAssertNil(cached?.unstagedDiff)
    }

    func testTurnCompletionGitRefreshDebouncesByWorkspacePath() async throws {
        let project = makeProject(id: "workspace-turn-refresh")
        let session = makeSession(
            id: "thread-turn-refresh",
            projectID: project.id,
            title: "Git refresh",
            status: "history",
            source: "codex"
        )
        let refreshedStatus = GitStatusResponse(
            path: project.path,
            isRepository: true,
            branch: "main",
            head: "new-head",
            ahead: 0,
            behind: 0,
            upstream: "origin/main",
            statusText: "",
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
            gitStatusResults: [project.path: .success(refreshedStatus)]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]
        store.gitRefreshDelayNanoseconds = 0
        store.gitStatusByPath[project.path] = GitStatusResponse(
            path: project.path,
            isRepository: true,
            branch: "main",
            head: "old-head",
            statusText: "",
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: nil,
            files: [],
            truncated: false,
            truncatedNote: nil
        )

        store.scheduleGitRefreshAfterTurnCompletion(
            sessionID: session.id,
            hostScope: appStore.activeHostScope
        )
        let supersededRefresh = try XCTUnwrap(store.gitRefreshTasksByPath[project.path])
        store.scheduleGitRefreshAfterTurnCompletion(
            sessionID: session.id,
            hostScope: appStore.activeHostScope
        )
        let latestRefresh = try XCTUnwrap(store.gitRefreshTasksByPath[project.path])

        // mock 在主 actor 外先记录请求、再返回结果，只等请求出现会读到写回前的旧状态。
        // 等两个刷新任务都结束：被取消的那次不会再发请求，最新那次已把结果写回。
        await supersededRefresh.value
        await latestRefresh.value

        XCTAssertEqual(client.requestedGitStatusPaths, [project.path])
        XCTAssertEqual(store.gitStatusByPath[project.path]?.head, "new-head")
    }
}
