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
        let viewObservation = PullRefreshViewObservation()
        let host = UIHostingController(rootView: PullRefreshObservedView(
            appStore: appStore, sessionStore: store, workspacePath: workspacePath,
            observation: viewObservation, content: view
        ))
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

        let sessionGate = PullRefreshRequestGate()
        let manualCatalogGate = PullRefreshRequestGate()
        defer {
            sessionGate.release()
            manualCatalogGate.release()
        }
        let manualProject = AgentProject(id: project.id, name: "manual-catalog", path: project.path)
        client.holdNextSessionPage(with: sessionGate)
        client.holdNextProjects(with: manualCatalogGate, returning: [manualProject])
        // 让摘要过期，确保“不请求 Git”确实来自下拉语义，而不是碰巧命中 TTL。
        store.workspaceGitSummaryUpdatedAtByPath[workspacePath] = .distantPast
        // Store 的发布会更新 refreshable 环境。必须先等视图提交，避免刚发出的
        // UIKit action 被尚未提交的旧视图更新取消，连会话请求都未开始就退出。
        try await waitForRefreshUI("SwiftUI 未提交过期的 Git 摘要状态") {
            viewObservation.gitSummaryUpdatedAt == .distantPast
        }
        client.publish(SessionsPage(sessions: [refreshedSession, initialSession]))
        let refreshControl = try XCTUnwrap(findRefreshControl(in: host.view))
        try triggerPullRefresh(refreshControl)

        try await waitForRefreshUI(
            "下拉未开始会话请求：sessions=\(client.sessionPageCallCount)/\(sessionRequestCountBeforePull)"
                + " projects=\(client.projectsCallCount)/\(projectRequestCountBeforePull)"
                + " refreshing=\(refreshControl.isRefreshing)"
                + " sameControl=\(findRefreshControl(in: host.view) === refreshControl)"
                + " window=\(refreshControl.window != nil)"
                + " targets=\(refreshControl.allTargets.count)"
                + " events=\(refreshControl.allControlEvents.rawValue)"
        ) {
            sessionGate.hasStarted
        }
        // 会话合并由 Store 侧用例覆盖；这里确认 UI 发起请求并等待它结束。
        XCTAssertGreaterThan(client.sessionPageCallCount, sessionRequestCountBeforePull, "下拉应发出会话请求")
        XCTAssertTrue(refreshControl.isRefreshing, "会话请求尚未返回时，下拉指示器不能结束")
        sessionGate.release()
        try await waitForRefreshUI(
            "下拉指示器未结束：sessionPageCallCount=\(client.sessionPageCallCount)"
                + " projectsCallCount=\(client.projectsCallCount)"
        ) {
            sessionGate.hasCompleted
                && store.sessionListFirstPageInFlightByKey.isEmpty
                && !refreshControl.isRefreshing
        }
        // 目录同步是下拉的附属工作，退到指示器之后仍然要跑；Git 摘要则一次都不能发。
        try await waitForRefreshUI(
            "下拉未触发后台目录同步：projectsCallCount=\(client.projectsCallCount)"
        ) {
            manualCatalogGate.hasStarted
        }
        XCTAssertGreaterThan(client.projectsCallCount, projectRequestCountBeforePull)
        XCTAssertFalse(refreshControl.isRefreshing, "后台目录请求不能延长下拉指示器")
        manualCatalogGate.release()
        try await waitForRefreshUI("后台目录响应未提交") {
            manualCatalogGate.hasCompleted && store.projects == [manualProject]
        }
        XCTAssertEqual(
            gitProbe.requestCount,
            gitRequestCountBeforePull,
            "下拉不得请求工作区 Git 摘要：每个仓库都要在 Mac 上启动一组 git 子进程"
        )

        let foregroundCatalogGate = PullRefreshRequestGate()
        defer { foregroundCatalogGate.release() }
        let foregroundProject = AgentProject(id: project.id, name: "foreground-catalog", path: project.path)
        client.holdNextProjects(with: foregroundCatalogGate, returning: [foregroundProject])
        appStore.suspendCredentialsForBackground()
        XCTAssertTrue(appStore.isCredentialMemorySuspended)
        try await waitForRefreshUI("SwiftUI 未观察到后台凭据挂起") {
            viewObservation.isSuspended == true
        }
        XCTAssertFalse(foregroundCatalogGate.hasStarted, "凭据挂起期间不应刷新目录")
        try await appStore.restoreCredentialsForForeground()
        try await waitForRefreshUI("恢复前台未触发目录同步") {
            foregroundCatalogGate.hasStarted
        }
        // 紧邻响应放行设置时间，前面的 UI 调度耗时不能把这一轮的 TTL 耗尽。
        store.workspaceGitSummaryUpdatedAtByPath[workspacePath] = Date()
        foregroundCatalogGate.release()
        try await waitForRefreshUI("恢复前台目录响应未提交") {
            foregroundCatalogGate.hasCompleted && store.projects == [foregroundProject]
                && viewObservation.isSuspended == false
        }
        XCTAssertEqual(
            gitProbe.requestCount,
            gitRequestCountBeforePull,
            "恢复前台的普通 catalog task 应命中 Git TTL"
        )

        let expiredCatalogGate = PullRefreshRequestGate()
        defer { expiredCatalogGate.release() }
        client.holdNextProjects(with: expiredCatalogGate, returning: [project])
        store.workspaceGitSummaryUpdatedAtByPath[workspacePath] = .distantPast
        appStore.suspendCredentialsForBackground()
        try await waitForRefreshUI("SwiftUI 未观察到第二次凭据挂起") {
            viewObservation.isSuspended == true
        }
        try await appStore.restoreCredentialsForForeground()
        try await waitForRefreshUI("TTL 过期后的前台恢复未请求目录") {
            expiredCatalogGate.hasStarted
        }
        expiredCatalogGate.release()
        try await waitForRefreshUI("TTL 过期后的前台恢复未更新 Git 摘要") {
            expiredCatalogGate.hasCompleted && store.projects == [project]
                && gitProbe.requestCount > gitRequestCountBeforePull
                && store.refreshingWorkspaceGitSummaryPaths.isEmpty
                && store.workspaceGitSummaryUpdatedAtByPath[workspacePath] != .distantPast
        }
        XCTAssertEqual(gitProbe.requestCount, gitRequestCountBeforePull + 1)
    }

}

@MainActor
private final class PullRefreshViewObservation {
    var isSuspended: Bool?
    var gitSummaryUpdatedAt: Date?
}

@MainActor
private struct PullRefreshObservedView<Content: View>: View {
    @ObservedObject var appStore: AppStore
    @ObservedObject var sessionStore: SessionStore
    let workspacePath: String
    let observation: PullRefreshViewObservation
    let content: Content

    var body: some View {
        let suspended = appStore.isCredentialMemorySuspended
        let gitSummaryUpdatedAt = sessionStore.workspaceGitSummaryUpdatedAtByPath[workspacePath]
        content.task(id: suspended) {
            // 等视图树提交这一状态后才恢复，避免 true → false 被同一次更新合并。
            observation.isSuspended = suspended
        }
        .task(id: gitSummaryUpdatedAt) {
            observation.gitSummaryUpdatedAt = gitSummaryUpdatedAt
        }
    }
}

private final class PullRefreshRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var completed = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    var hasStarted: Bool { lock.withLock { started } }
    var hasCompleted: Bool { lock.withLock { completed } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyReleased = lock.withLock {
                started = true
                guard !released else { return true }
                self.continuation = continuation
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
    }

    func complete() { lock.withLock { completed = true } }

    func release() {
        let pending = lock.withLock {
            released = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume()
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
    private var projectsResult: [AgentProject]
    private let gitProbe: PullRefreshGitProbe
    private let gitSummary: GitStatusResponse
    private let lock = NSLock()
    private var projectsCallCountStorage = 0
    private var sessionPageCallCountStorage = 0
    private var nextSessionGate: PullRefreshRequestGate?
    private var nextProjectsGate: PullRefreshRequestGate?
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

    func holdNextSessionPage(with gate: PullRefreshRequestGate) {
        lock.withLock { nextSessionGate = gate }
    }

    func holdNextProjects(with gate: PullRefreshRequestGate, returning projects: [AgentProject]) {
        lock.withLock {
            nextProjectsGate = gate
            projectsResult = projects
        }
    }

    func projects() async throws -> [AgentProject] {
        let (gate, result) = lock.withLock {
            projectsCallCountStorage += 1
            let gate = nextProjectsGate
            nextProjectsGate = nil
            return (gate, projectsResult)
        }
        await gate?.wait()
        gate?.complete()
        return result
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await sessionsPage(projectID: projectID, cursor: cursor, limit: limit).sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        let (gate, result) = lock.withLock {
            sessionPageCallCountStorage += 1
            let gate = nextSessionGate
            nextSessionGate = nil
            return (gate, currentPageStorage)
        }
        await gate?.wait()
        gate?.complete()
        return result
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
    _ = try XCTUnwrap(refreshControl.superview as? UIScrollView)
    // 程序化刷新只需开始指示器并发送已注册事件，不伪造缺少真实手势的滚动状态。
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
