import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class WorkspacePullRefreshTests: XCTestCase {
    func testConsecutivePullRefreshesPublishNewSessionsAndSharePendingGitRefresh() async throws {
        let appStore = makeIsolatedAppStore()
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://workspace-refresh.test:8787",
            token: "pull-refresh-token"
        ))
        let project = AgentProject(id: "pull-refresh", name: "pull-refresh", path: "/workspace/pull-refresh")
        let workspace = AgentWorkspace(
            id: project.id, name: project.name, path: project.path,
            rootProjectID: project.id, rootProjectName: project.name,
            rootProjectPath: project.path, lastOpenedAt: Date()
        )
        let initialSession = AgentSession(
            id: "initial-session", projectID: project.id, project: project.name,
            dir: project.path, title: "刷新前会话", status: "history",
            source: "codex", runtimeProvider: "codex", resumeID: nil, createdAt: Date(), updatedAt: Date()
        )
        let firstRefreshedSession = AgentSession(
            id: "first-refreshed-session", projectID: project.id, project: project.name,
            dir: project.path, title: "第一次刷新出现", status: "history",
            source: "codex", runtimeProvider: "codex", resumeID: nil, createdAt: Date(), updatedAt: Date()
        )
        let secondRefreshedSession = AgentSession(
            id: "second-refreshed-session", projectID: project.id, project: project.name,
            dir: project.path, title: "第二次刷新出现", status: "history",
            source: "codex", runtimeProvider: "codex", resumeID: nil, createdAt: Date(), updatedAt: Date()
        )
        let gitGate = PullRefreshGitGate()
        defer { gitGate.release() }
        let gitSummary = try JSONDecoder().decode(
            GitStatusResponse.self,
            from: Data("{\"path\":\"/workspace/pull-refresh\",\"is_repository\":true,\"branch\":\"updated\",\"files\":[]}".utf8)
        )
        let initialGitSummary = try JSONDecoder().decode(
            GitStatusResponse.self,
            from: Data("{\"path\":\"/workspace/pull-refresh\",\"is_repository\":true,\"branch\":\"initial\",\"files\":[]}".utf8)
        )
        let client = PullRefreshClient(
            projects: [project],
            pages: [
                SessionsPage(sessions: [initialSession]),
                SessionsPage(sessions: [firstRefreshedSession, initialSession]),
                SessionsPage(sessions: [secondRefreshedSession, firstRefreshedSession, initialSession])
            ],
            gitGate: gitGate,
            initialGitSummary: initialGitSummary,
            refreshedGitSummary: gitSummary
        )
        let store = SessionStore(
            appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )
        store.reloadRecentWorkspaces()
        try await store.refreshWorkspaceCatalog()
        let workspacePath = try XCTUnwrap(store.sidebarProjects.first?.path)
        let themeSuite = "WorkspacePullRefreshTests.Theme.\(UUID().uuidString)"
        let themeDefaults = try XCTUnwrap(UserDefaults(suiteName: themeSuite))
        defer { themeDefaults.removePersistentDomain(forName: themeSuite) }
        let view = WorkspaceRootView(
            selectedSessionRuntime: .constant(.codex), onStartSession: { _, _ in },
            embedsNavigationStack: false, initialWorkspaceID: project.id
        )
        .environmentObject(appStore)
        .environmentObject(store)
        .environmentObject(ThemeStore(defaults: themeDefaults))
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 744, height: 1_133)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds

        try await waitForRefreshUI {
            host.view.layoutIfNeeded()
            return store.sessionsByID[initialSession.id] != nil
                && store.sessionsByID[firstRefreshedSession.id] == nil
                && store.workspaceGitSummaryByPath[workspacePath]?.branch == "initial"
                && store.sessionListFirstPageInFlightByKey.isEmpty
                && findRefreshControl(in: host.view) != nil
        }
        gitGate.isArmed = true
        let initialSessionRequestCount = client.sessionPageCallCount
        let initialGitRequestCount = gitGate.requestCount
        let refreshControl = try XCTUnwrap(findRefreshControl(in: host.view))
        try triggerPullRefresh(refreshControl)

        try await waitForRefreshUI { gitGate.isWaiting }
        XCTAssertGreaterThan(client.sessionPageCallCount, initialSessionRequestCount)
        XCTAssertEqual(store.sessionsByID[firstRefreshedSession.id]?.title, "第一次刷新出现")
        try await waitForRefreshUI { !refreshControl.isRefreshing }
        XCTAssertTrue(gitGate.isWaiting, "Git 尚未返回时，下拉指示器就应结束")
        XCTAssertEqual(store.workspaceGitSummaryByPath[workspacePath]?.branch, "initial")

        try triggerPullRefresh(refreshControl)
        try await waitForRefreshUI {
            store.sessionsByID[secondRefreshedSession.id] != nil && !refreshControl.isRefreshing
        }
        XCTAssertEqual(client.sessionPageCallCount, initialSessionRequestCount + 2, "每次下拉都应从头获取最新会话")
        XCTAssertEqual(gitGate.requestCount, initialGitRequestCount + 1, "Git 尚未完成时，第二次下拉应合并附属刷新")
        XCTAssertEqual(gitGate.waitingRequestCount, 1)

        gitGate.release()
        try await waitForRefreshUI { store.workspaceGitSummaryByPath[workspacePath]?.branch == "updated" }

        let manualGitRequestCount = gitGate.requestCount
        let projectRequestCountBeforeRestore = client.projectsCallCount
        appStore.suspendCredentialsForBackground()
        XCTAssertTrue(appStore.isCredentialMemorySuspended)
        try await appStore.restoreCredentialsForForeground()
        try await waitForRefreshUI { client.projectsCallCount > projectRequestCountBeforeRestore }
        XCTAssertEqual(
            gitGate.requestCount,
            manualGitRequestCount,
            "恢复前台的普通 catalog task 应命中 Git TTL，不得继承手动 force"
        )
    }

    func testOpenWorkspaceOutcomeCanDeferSessionLoadToWorkspacePage() async throws {
        let project = AgentProject(id: "deferred-open", name: "deferred-open", path: "/workspace/deferred-open")
        let workspace = AgentWorkspace(project: project)
        let client = MockSessionStoreClient(
            projects: [project], sessions: [],
            resolveResults: [workspace.path: .success(workspace)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { client }
        )

        let outcome = await store.openWorkspaceOutcome(path: workspace.path, loadsSessions: false)

        XCTAssertEqual(outcome, .opened(workspaceID: workspace.id))
        XCTAssertEqual(store.selectedProjectID, workspace.id)
        XCTAssertTrue(client.requestedWorkspaceIDs.isEmpty, "Sheet 打开后应由工作区页面统一加载会话")
    }
}

@MainActor
private final class PullRefreshGitGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var isArmed = false
    private(set) var requestCount = 0
    var waitingRequestCount: Int { continuations.count }
    var isWaiting: Bool { !continuations.isEmpty }

    func status(initial: GitStatusResponse, refreshed: GitStatusResponse) async -> GitStatusResponse {
        requestCount += 1
        guard isArmed else { return initial }
        await withCheckedContinuation { continuations.append($0) }
        return refreshed
    }

    func release() {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
}

private final class PullRefreshClient: SessionStoreAPIClient {
    private let projectsResult: [AgentProject]
    private let pages: [SessionsPage]
    private let gitGate: PullRefreshGitGate
    private let initialGitSummary: GitStatusResponse
    private let refreshedGitSummary: GitStatusResponse
    private let lock = NSLock()
    private var projectsCallCountStorage = 0
    private var sessionPageCallCountStorage = 0

    var projectsCallCount: Int {
        lock.withLock { projectsCallCountStorage }
    }

    var sessionPageCallCount: Int {
        lock.withLock { sessionPageCallCountStorage }
    }

    init(
        projects: [AgentProject],
        pages: [SessionsPage],
        gitGate: PullRefreshGitGate,
        initialGitSummary: GitStatusResponse,
        refreshedGitSummary: GitStatusResponse
    ) {
        projectsResult = projects
        self.pages = pages
        self.gitGate = gitGate
        self.initialGitSummary = initialGitSummary
        self.refreshedGitSummary = refreshedGitSummary
    }

    func projects() async throws -> [AgentProject] {
        lock.withLock { projectsCallCountStorage += 1 }
        return projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await sessionsPage(projectID: projectID, cursor: cursor, limit: limit).sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        let index = lock.withLock {
            let index = min(sessionPageCallCountStorage, max(0, pages.count - 1))
            sessionPageCallCountStorage += 1
            return index
        }
        return pages.isEmpty ? SessionsPage(sessions: []) : pages[index]
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        await gitGate.status(initial: initialGitSummary, refreshed: refreshedGitSummary)
    }
}

@MainActor
private func findRefreshControl(in view: UIView) -> UIRefreshControl? {
    if let scroll = view as? UIScrollView, let control = scroll.refreshControl { return control }
    for child in view.subviews {
        if let control = findRefreshControl(in: child) { return control }
    }
    return nil
}

@MainActor
private func triggerPullRefresh(_ refreshControl: UIRefreshControl) throws {
    let scrollView = try XCTUnwrap(refreshControl.superview as? UIScrollView)
    // 触发生产 .refreshable 注册的 UIKit action，验证真实刷新指示器的结束时机。
    scrollView.setContentOffset(
        CGPoint(x: 0, y: -scrollView.adjustedContentInset.top - 120), animated: false
    )
    refreshControl.beginRefreshing()
    refreshControl.sendActions(for: .valueChanged)
}

@MainActor
private func waitForRefreshUI(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("刷新界面未在 5 秒内达到预期状态", file: file, line: line)
            throw URLError(.timedOut)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
