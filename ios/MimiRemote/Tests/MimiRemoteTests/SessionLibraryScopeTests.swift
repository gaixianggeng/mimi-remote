import XCTest
import SwiftUI
@testable import MimiRemote

@MainActor
final class SessionLibraryScopeTests: XCTestCase {
    func testAllScopeIncludesGlobalWorktreesWithoutDirectoryConfirmation() {
        let project = makeProject(id: "cli-scope")
        let workspace = AgentWorkspace(project: project)
        let root = session("root", project: project, dir: project.path)
        let worktree = session("worktree", project: project, dir: "/test/worktrees/feature")
        let store = makeStore(workspace: workspace, sessions: [root, worktree])
        store.recordWorkspaceDirectorySessionPage([root], in: workspace, runtimeProvider: "codex", replacing: true)

        XCTAssertEqual(Set(store.sessionLibrarySessions(workspaceID: "all").map(\.id)), [root.id, worktree.id])
        XCTAssertEqual(store.sessionLibrarySessions(workspaceID: workspace.id).map(\.id), [root.id])
        XCTAssertEqual(store.directoryScopedSessions(workspaceID: workspace.id, runtimeProvider: "codex").map(\.id), [root.id])
        let visibleWorktree = store.sessionLibrarySessions(workspaceID: "all").first { $0.id == worktree.id }
        XCTAssertEqual(visibleWorktree?.projectID, project.id)
        XCTAssertEqual(visibleWorktree?.dir, worktree.dir, "全部会话只能改变显示范围，不能把执行目录改成主目录")
    }

    func testGlobalSessionRemainsInAllScopeWithoutOpenedWorkspace() {
        let project = makeProject(id: "cli-unopened")
        let worktree = session("unopened-worktree", project: project, dir: "/test/worktrees/unopened")
        let store = makeStore(workspace: AgentWorkspace(project: project), sessions: [worktree])
        store.recentWorkspaces = []

        XCTAssertEqual(store.sessionLibrarySessions(workspaceID: "all").map(\.id), [worktree.id])
        XCTAssertTrue(store.sessionLibrarySessions(workspaceID: project.id).isEmpty)
        XCTAssertEqual(store.sessionsByID[worktree.id]?.dir, worktree.dir)
    }

    func testAllScopeKeepsSearchAndHiddenSessionRules() {
        let project = makeProject(id: "cli-search")
        let worktree = session("searchable-worktree", project: project, dir: "/test/worktrees/searchable")
        let hidden = session("hidden-worktree", project: project, dir: "/test/worktrees/hidden")
        let store = makeStore(workspace: AgentWorkspace(project: project), sessions: [worktree, hidden])
        store.archivedSessionIDs.insert(hidden.id)
        store.sessionSearchQuery = "searchable"

        XCTAssertEqual(store.sessionLibrarySessions(workspaceID: "all").map(\.id), [worktree.id])
        XCTAssertTrue(store.sessionLibrarySessions(workspaceID: project.id).isEmpty)
        store.sessionSearchQuery = ""
        XCTAssertEqual(store.sessionLibrarySessions(workspaceID: "all").map(\.id), [worktree.id])
    }

    func testViewAllRequestIsConsumedBeforeListIsRecreated() async throws {
        let project = makeProject(id: "cli-request")
        let appStore = makeIsolatedAppStore()
        let store = makeStore(workspace: AgentWorkspace(project: project), sessions: [], appStore: appStore)
        let suite = "SessionLibraryScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let themeStore = ThemeStore(defaults: defaults)
        let appearanceStore = WorkspaceAppearanceStore(defaults: defaults)
        var requestID: UUID? = UUID()
        var consumptionCount = 0
        let request = Binding<UUID?>(get: { requestID }, set: {
            consumptionCount += 1
            requestID = $0
        })
        func list() -> some View {
            NavigationStack {
                SessionListView(allSessionsRequestID: request)
            }
            .environmentObject(appStore)
            .environmentObject(store)
            .environmentObject(themeStore)
            .environmentObject(appearanceStore)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        store.sessionSearchQuery = "old filter"
        window.rootViewController = UIHostingController(rootView: list())
        window.makeKeyAndVisible()
        for _ in 0..<100 where requestID != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(requestID, "查看全部的导航请求必须一次性消费")
        XCTAssertEqual(store.sessionSearchQuery, "")

        // 模拟宽屏从详情返回：先卸载旧页面，再重新挂载，避免窗口转场重叠。
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(100))
        store.sessionSearchQuery = "keep this search"
        window.rootViewController = UIHostingController(rootView: list())
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(consumptionCount, 1, "重建不能重复消费已完成的请求")
        XCTAssertEqual(store.sessionSearchQuery, "keep this search")
    }

    private func makeStore(workspace: AgentWorkspace, sessions: [AgentSession], appStore: AppStore? = nil) -> SessionStore {
        let store = SessionStore(
            appStore: appStore ?? makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        store.recentWorkspaces = [workspace]
        store.sessions = sessions
        store.controlledGlobalSessionIDs = Set(sessions.map(\.id))
        return store
    }

    private func session(_ id: String, project: AgentProject, dir: String) -> AgentSession {
        AgentSession(
            id: id, projectID: project.id, project: project.name, dir: dir, title: id,
            status: "history", source: "codex", resumeID: id,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2)
        )
    }
}
