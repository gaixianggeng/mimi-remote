import XCTest
@testable import MimiRemote

/// 同一工作区里 Codex 与 Claude 的首屏各自刷新，互相不能把对方的会话从 canonical Store 删掉（#721）。
/// 工作区页按 Runtime 缓存的分页结果只渲染 Store 里仍存在的成员，Store 一旦误删，
/// 列表就会只剩选中的那条或直接显示「还没有会话」，直到下拉刷新重新取回。
@MainActor
final class WorkspaceCrossRuntimeMembershipTests: XCTestCase {
    func testCodexFirstPageKeepsClaudeSessionsOfSameWorkspace() async throws {
        let project = makeProject(id: "gh-721-codex-replace")
        let codex = makeRuntimeSession("gh-721-codex", project: project, runtime: "codex", updatedAt: 40)
        let claude = (1...3).map { index in
            makeRuntimeSession("gh-721-claude-\(index)", project: project, runtime: "claude", updatedAt: index * 10)
        }
        let store = makeStore(project: project, workspaceSessions: [codex] + claude)

        _ = try await store.workspaceRuntimeSessionsPage(
            projectID: project.id, runtimeProvider: "claude", cursor: nil, limit: 20
        )
        XCTAssertEqual(claudeIDs(in: store, project: project), Set(claude.map(\.id)))

        // 用户点进其中一条 Claude 会话；随后选中项目的静默刷新按主 Runtime（Codex）拉首屏。
        store.selectedSessionID = claude[1].id
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))
        store.applyWorkspaceSessionFirstPage(
            workspace: workspace,
            page: SessionsPage(sessions: [codex]),
            runtimeProvider: "codex",
            consistency: .authoritative
        )

        XCTAssertEqual(
            claudeIDs(in: store, project: project),
            Set(claude.map(\.id)),
            "Codex 首屏只能替换 Codex 会话，不能把同工作区的 Claude 会话删到只剩选中的那条"
        )
        // 没有选中任何会话时（例如冷启动的首轮刷新），Claude 列表也不能被清空。
        store.selectedSessionID = nil
        store.applyWorkspaceSessionFirstPage(
            workspace: workspace,
            page: SessionsPage(sessions: [codex]),
            runtimeProvider: "codex",
            consistency: .authoritative,
            restartsFromFirst: true
        )
        XCTAssertEqual(claudeIDs(in: store, project: project), Set(claude.map(\.id)))
    }

    func testClaudeFirstPageReplacesOnlyStaleClaudeSessions() async throws {
        let project = makeProject(id: "gh-721-claude-replace")
        let codex = makeRuntimeSession("gh-721-codex-kept", project: project, runtime: "codex", updatedAt: 40)
        let staleClaude = makeRuntimeSession("gh-721-claude-stale", project: project, runtime: "claude", updatedAt: 10)
        let freshClaude = makeRuntimeSession("gh-721-claude-fresh", project: project, runtime: "claude", updatedAt: 30)
        let store = makeStore(project: project, workspaceSessions: [codex, staleClaude, freshClaude])

        _ = try await store.workspaceRuntimeSessionsPage(
            projectID: project.id, runtimeProvider: "codex", cursor: nil, limit: 20
        )
        _ = try await store.workspaceRuntimeSessionsPage(
            projectID: project.id, runtimeProvider: "claude", cursor: nil, limit: 20
        )
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))
        store.applyWorkspaceSessionFirstPage(
            workspace: workspace,
            page: SessionsPage(sessions: [freshClaude]),
            runtimeProvider: "claude",
            consistency: .authoritative
        )

        XCTAssertEqual(claudeIDs(in: store, project: project), [freshClaude.id], "同 Runtime 的权威首屏仍要删掉已消失的旧会话")
        XCTAssertEqual(
            store.directoryScopedSessions(workspaceID: project.id, runtimeProvider: "codex").map(\.id),
            [codex.id],
            "Claude 首屏不能删掉同工作区的 Codex 会话"
        )
    }

    func testCodexFirstPagesDoNotSettleRunningClaudeMissCounter() async throws {
        let project = makeProject(id: "gh-721-running-miss")
        let codex = makeRuntimeSession("gh-721-codex-poll", project: project, runtime: "codex", updatedAt: 40)
        let runningClaude = makeSession(
            id: "gh-721-claude-running", projectID: project.id, title: "运行中的 Claude", status: "running",
            source: "claude", runtimeProvider: "claude", updatedAt: Date(timeIntervalSince1970: 30)
        )
        let store = makeStore(project: project, workspaceSessions: [codex, runningClaude])
        _ = try await store.workspaceRuntimeSessionsPage(
            projectID: project.id, runtimeProvider: "claude", cursor: nil, limit: 20
        )
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))

        // Claude 自己的首屏短暂漏掉它一次，宽限计数从 1 开始。
        store.recordRunningSessionsMissingFromFreshPage(freshIDs: [], projectID: project.id, runtimeProvider: "claude")
        XCTAssertEqual(store.missingRunningSessionStateByID[runningClaude.id]?.consecutiveRefreshMisses, 1)

        // 多轮 Codex 轮询既不能继续累加，也不能把这次缺失当成已恢复清零。
        for _ in 0..<4 {
            store.applyWorkspaceSessionFirstPage(
                workspace: workspace,
                page: SessionsPage(sessions: [codex]),
                runtimeProvider: "codex",
                consistency: .authoritative,
                restartsFromFirst: true
            )
        }
        XCTAssertEqual(
            store.missingRunningSessionStateByID[runningClaude.id]?.consecutiveRefreshMisses,
            1,
            "缺失宽限只能由 Claude 自己的首屏结算"
        )
        XCTAssertTrue(claudeIDs(in: store, project: project).contains(runningClaude.id))
    }

    private func makeRuntimeSession(
        _ id: String,
        project: AgentProject,
        runtime: String,
        updatedAt: Int
    ) -> AgentSession {
        makeSession(
            id: id, projectID: project.id, title: id, status: "history",
            source: runtime, runtimeProvider: runtime,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
        )
    }

    private func makeStore(project: AgentProject, workspaceSessions: [AgentSession]) -> SessionStore {
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: workspaceSessions,
            workspaceSessions: [project.id: workspaceSessions]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        return store
    }

    private func claudeIDs(in store: SessionStore, project: AgentProject) -> Set<SessionID> {
        Set(store.directoryScopedSessions(workspaceID: project.id, runtimeProvider: "claude").map(\.id))
    }
}
