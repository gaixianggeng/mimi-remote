import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class WorkspacePullRefreshTests: XCTestCase {
    func testPullRefreshEndsWhileGitSummaryIsStillPending() async throws {
        let appStore = makeIsolatedAppStore()
        appStore.endpoint = "http://workspace-refresh.test:8787"
        let project = AgentProject(id: "pull-refresh", name: "pull-refresh", path: "/workspace/pull-refresh")
        let workspace = AgentWorkspace(
            id: project.id, name: project.name, path: project.path,
            rootProjectID: project.id, rootProjectName: project.name,
            rootProjectPath: project.path, lastOpenedAt: Date()
        )
        let session = AgentSession(
            id: "refreshed-session", projectID: project.id, project: project.name,
            dir: project.path, title: "会话已更新", status: "history",
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
        let client = MockSessionStoreClient(
            projects: [project], sessions: [session],
            workspaceSessions: [workspace.id: [session]],
            gitStatusHandler: { _ in
                let isManualRefresh = await gitGate.wait()
                return isManualRefresh ? gitSummary : initialGitSummary
            }
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
            return store.sessionsByID[session.id] != nil
                && store.workspaceGitSummaryByPath[workspacePath]?.branch == "initial"
                && store.sessionListFirstPageInFlightByKey.isEmpty
                && findRefreshControl(in: host.view) != nil
        }
        gitGate.isArmed = true
        let initialRequestCount = client.requestedWorkspaceIDs.count
        let refreshControl = try XCTUnwrap(findRefreshControl(in: host.view))
        let scrollView = try XCTUnwrap(refreshControl.superview as? UIScrollView)
        // 触发生产 .refreshable 注册的 UIKit action，验证真实刷新指示器的结束时机。
        scrollView.setContentOffset(
            CGPoint(x: 0, y: -scrollView.adjustedContentInset.top - 120), animated: false
        )
        refreshControl.beginRefreshing()
        refreshControl.sendActions(for: .valueChanged)

        try await waitForRefreshUI { gitGate.isWaiting }
        XCTAssertGreaterThan(client.requestedWorkspaceIDs.count, initialRequestCount)
        XCTAssertEqual(store.sessionsByID[session.id]?.title, "会话已更新")
        try await waitForRefreshUI { !refreshControl.isRefreshing }
        XCTAssertTrue(gitGate.isWaiting, "Git 尚未返回时，下拉指示器就应结束")
        XCTAssertEqual(store.workspaceGitSummaryByPath[workspacePath]?.branch, "initial")

        gitGate.release()
        try await waitForRefreshUI { store.workspaceGitSummaryByPath[workspacePath]?.branch == "updated" }
    }

    func testManualCatalogRefreshDoesNotForceAnotherHost() {
        let originalHost = HostScope(profileID: "a", installationID: "mac-a", generation: 1)
        let otherHost = HostScope(profileID: "b", installationID: "mac-b", generation: 2)
        let request = WorkspaceCatalogRefreshRequest(hostScope: originalHost)
        let originalScope = WorkspaceCatalogRefreshScope(
            hostScope: originalHost, credentialsSuspended: false, manualRequest: request
        )
        let changedScope = WorkspaceCatalogRefreshScope(
            hostScope: otherHost, credentialsSuspended: false, manualRequest: request
        )
        XCTAssertTrue(originalScope.forceGitSummary)
        XCTAssertFalse(changedScope.forceGitSummary)
        XCTAssertNotEqual(originalScope, changedScope, "切换主机必须让 SwiftUI 取消旧目录任务")
    }
}

@MainActor
private final class PullRefreshGitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isArmed = false
    var isWaiting: Bool { continuation != nil }

    func wait() async -> Bool {
        guard isArmed else { return false }
        await withCheckedContinuation { continuation = $0 }
        return true
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
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
