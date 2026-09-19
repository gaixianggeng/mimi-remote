import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class WorkspacePullRefreshTests: XCTestCase {
    /// 下拉只服务会话列表：指示器只等会话请求，目录同步退到后台，
    /// 全程不请求任何工作区 Git 摘要。
    ///
    /// 只驱动一次真实下拉。通过合成 valueChanged 在同一个 UIRefreshControl 上连拉两次时，
    /// SwiftUI 是否重新执行 .refreshable 并不确定，会让用例偶发空跑；
    /// 首屏 single-flight 的复用语义已由 WorkspaceSessionSingleFlightTests 在 Store 层覆盖。
    func testPullRefreshPublishesSessionsWithoutRequestingWorkspaceGitSummaries() async throws {
        let appStore = makeIsolatedAppStore()
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://workspace-refresh.local:8787",
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
        let refreshedSession = AgentSession(
            id: "refreshed-session", projectID: project.id, project: project.name,
            dir: project.path, title: "下拉后出现", status: "history",
            source: "codex", runtimeProvider: "codex", resumeID: nil, createdAt: Date(), updatedAt: Date()
        )
        let gitProbe = PullRefreshGitProbe()
        let gitSummary = try JSONDecoder().decode(
            GitStatusResponse.self,
            from: Data("{\"path\":\"/workspace/pull-refresh\",\"is_repository\":true,\"branch\":\"initial\",\"files\":[]}".utf8)
        )
        let client = PullRefreshClient(
            projects: [project],
            initialPage: SessionsPage(sessions: [initialSession]),
            gitProbe: gitProbe,
            gitSummary: gitSummary
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

        // 首屏稳定：会话已提交，目录 Git 摘要已按 TTL 落一次，刷新控件已挂上。
        try await waitForRefreshUI(
            "首屏未稳定：sessions=\(store.sessionsByID.keys.sorted())"
                + " branch=\(store.workspaceGitSummaryByPath[workspacePath]?.branch ?? "nil")"
                + " inFlight=\(store.sessionListFirstPageInFlightByKey.count)"
                + " refreshControl=\(findRefreshControl(in: host.view) != nil)"
        ) {
            host.view.layoutIfNeeded()
            return store.sessionsByID[initialSession.id] != nil
                && store.sessionsByID[refreshedSession.id] == nil
                && store.workspaceGitSummaryByPath[workspacePath]?.branch == "initial"
                && store.sessionListFirstPageInFlightByKey.isEmpty
                && findRefreshControl(in: host.view) != nil
        }
        let sessionRequestCountBeforePull = client.sessionPageCallCount
        let gitRequestCountBeforePull = gitProbe.requestCount
        let projectRequestCountBeforePull = client.projectsCallCount
        XCTAssertGreaterThan(gitRequestCountBeforePull, 0, "首屏应至少取过一次 Git 摘要，后面的断言才有意义")

        let refreshControl = try XCTUnwrap(findRefreshControl(in: host.view))
        client.publish(SessionsPage(sessions: [refreshedSession, initialSession]))
        try triggerPullRefresh(refreshControl)

        try await waitForRefreshUI(
            "下拉指示器未结束：sessionPageCallCount=\(client.sessionPageCallCount)"
                + " projectsCallCount=\(client.projectsCallCount)"
        ) {
            !refreshControl.isRefreshing
        }
        XCTAssertGreaterThan(client.sessionPageCallCount, sessionRequestCountBeforePull, "下拉应发出会话请求")
        // 请求成功不等于刷新成功；同时检查 canonical Store 和实际列表使用的目录成员。
        try await waitForRefreshUI("刷新响应未提交：sessions=\(store.sessionsByID.keys.sorted())") {
            store.sessionsByID[refreshedSession.id] != nil
                && store.directoryScopedSessions(workspaceID: project.id, runtimeProvider: "codex")
                    .contains { $0.id == refreshedSession.id }
        }

        // 目录同步是下拉的附属工作，退到指示器之后仍然要跑；Git 摘要则一次都不能发。
        try await waitForRefreshUI(
            "下拉未触发后台目录同步：projectsCallCount=\(client.projectsCallCount)"
        ) {
            client.projectsCallCount > projectRequestCountBeforePull
        }
        XCTAssertEqual(
            gitProbe.requestCount,
            gitRequestCountBeforePull,
            "下拉不得请求工作区 Git 摘要：每个仓库都要在 Mac 上启动一组 git 子进程"
        )

        let projectRequestCountBeforeRestore = client.projectsCallCount
        appStore.suspendCredentialsForBackground()
        XCTAssertTrue(appStore.isCredentialMemorySuspended)
        try await appStore.restoreCredentialsForForeground()
        try await waitForRefreshUI("恢复前台未触发目录同步") {
            client.projectsCallCount > projectRequestCountBeforeRestore
        }
        XCTAssertEqual(
            gitProbe.requestCount,
            gitRequestCountBeforePull,
            "恢复前台的普通 catalog task 应命中 Git TTL"
        )
    }

}

/// Git 摘要在这个用例里只需要计数：下拉路径一次都不该碰它。
private final class PullRefreshGitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var requestCount: Int { lock.withLock { storage } }

    func record() {
        lock.withLock { storage += 1 }
    }
}

private final class PullRefreshClient: SessionStoreAPIClient {
    private let projectsResult: [AgentProject]
    private let gitProbe: PullRefreshGitProbe
    private let gitSummary: GitStatusResponse
    private let lock = NSLock()
    private var projectsCallCountStorage = 0
    private var sessionPageCallCountStorage = 0
    // 首屏期间 Store 会经由 bootstrap、fastIndexed 和 authoritative 等多条路径请求会话，
    // 次数并不确定。按调用序号发页会让“哪一页被谁消费”取决于时序，用例必然飘；
    // 这里改由测试显式切换当前页，任意次数的请求都得到同一份确定结果。
    private var currentPageStorage: SessionsPage

    var projectsCallCount: Int {
        lock.withLock { projectsCallCountStorage }
    }

    var sessionPageCallCount: Int {
        lock.withLock { sessionPageCallCountStorage }
    }

    init(
        projects: [AgentProject],
        initialPage: SessionsPage,
        gitProbe: PullRefreshGitProbe,
        gitSummary: GitStatusResponse
    ) {
        projectsResult = projects
        currentPageStorage = initialPage
        self.gitProbe = gitProbe
        self.gitSummary = gitSummary
    }

    /// 切换到下拉之后应当返回的结果。切换之后的每一次请求都返回它。
    func publish(_ page: SessionsPage) {
        lock.withLock { currentPageStorage = page }
    }

    func projects() async throws -> [AgentProject] {
        lock.withLock { projectsCallCountStorage += 1 }
        return projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await sessionsPage(projectID: projectID, cursor: cursor, limit: limit).sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        lock.withLock {
            sessionPageCallCountStorage += 1
            return currentPageStorage
        }
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
        gitProbe.record()
        return gitSummary
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
    // 上一次下拉留下的偏移必须先归位。否则第二次 setContentOffset 不产生任何变化，
    // 连续下拉在同一个 UIRefreshControl 上就不是两次独立手势。
    scrollView.setContentOffset(
        CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false
    )
    // 触发生产 .refreshable 注册的 UIKit action，验证真实刷新指示器的结束时机。
    scrollView.setContentOffset(
        CGPoint(x: 0, y: -scrollView.adjustedContentInset.top - 120), animated: false
    )
    refreshControl.beginRefreshing()
    refreshControl.sendActions(for: .valueChanged)
}

@MainActor
private func waitForRefreshUI(
    _ context: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    // 这个用例要等 SwiftUI 完成整页布局、挂上 UIRefreshControl，再跑完目录、Git 和
    // 会话几轮任务。CI 与满负载本机的调度会停摆到秒级，5 秒上限会把负载当成回归。
    // 轮询在条件满足时立即返回，放宽上限只影响真正失败时的等待时间。
    let deadline = Date().addingTimeInterval(20)
    while !condition() {
        guard Date() < deadline else {
            let detail = context()
            XCTFail(
                detail.isEmpty
                    ? "刷新界面未在 20 秒内达到预期状态"
                    : "刷新界面未在 20 秒内达到预期状态：\(detail)",
                file: file,
                line: line
            )
            throw URLError(.timedOut)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
