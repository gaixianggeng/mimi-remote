import XCTest
@testable import MimiRemote

final class WorkbenchKeyboardNavigationTests: XCTestCase {
    // MARK: - ⌘[ / ⌘] 会话历史

    func testHistoryBacksAndForwardsLikeABrowser() {
        var history = WorkbenchSessionHistory()
        history.visit("a")
        history.visit("b")
        history.visit("c")
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        XCTAssertEqual(history.goBack(isAvailable: { _ in true }), "b")
        XCTAssertEqual(history.goBack(isAvailable: { _ in true }), "a")
        XCTAssertNil(history.goBack(isAvailable: { _ in true }), "历史起点再后退没有目标")
        XCTAssertEqual(history.current, "a")

        XCTAssertEqual(history.goForward(isAvailable: { _ in true }), "b")
        // 后退后打开的会话会被外壳重新 visit：当前已是它，不能清空前进栈。
        history.visit("b")
        XCTAssertEqual(history.goForward(isAvailable: { _ in true }), "c")
    }

    func testVisitingNewSessionClearsForwardStack() {
        var history = WorkbenchSessionHistory()
        history.visit("a")
        history.visit("b")
        _ = history.goBack(isAvailable: { _ in true })
        history.visit("d")
        XCTAssertFalse(history.canGoForward, "从中间打开新会话后，旧的前进路径作废")
        XCTAssertEqual(history.goBack(isAvailable: { _ in true }), "a")
    }

    func testHistorySkipsSessionsThatNoLongerExist() {
        var history = WorkbenchSessionHistory()
        history.visit("a")
        history.visit("archived")
        history.visit("c")
        XCTAssertEqual(history.goBack(isAvailable: { $0 != "archived" }), "a")
    }

    func testRevisitingKeepsSingleBackEntryAndRespectsLimit() {
        var history = WorkbenchSessionHistory()
        history.visit("a")
        history.visit("b")
        history.visit("a")
        XCTAssertEqual(history.backStack, ["b"], "同一会话在后退栈里只保留最近一次")

        var long = WorkbenchSessionHistory()
        for index in 0...(WorkbenchSessionHistory.limit + 5) {
            long.visit("s\(index)")
        }
        XCTAssertEqual(long.backStack.count, WorkbenchSessionHistory.limit)
    }

    func testIdentityReplacementRewritesHistory() {
        var history = WorkbenchSessionHistory()
        history.visit("draft-1")
        history.visit("b")
        history.replace("draft-1", with: "thread-1")
        XCTAssertEqual(history.goBack(isAvailable: { _ in true }), "thread-1")
    }

    // MARK: - ⌘O 跳转面板

    func testEmptyQueryFollowsSidebarSectionsAndSkipsEmptyOnes() {
        let needYou = session("n", title: "等待确认部署")
        let recent = session("r", title: "整理文档")
        let sections = [
            SessionSidebarSection(kind: .needYou, sessions: [needYou]),
            SessionSidebarSection(kind: .running, sessions: []),
            SessionSidebarSection(kind: .recent, sessions: [recent])
        ]
        let groups = SessionJumpPanelModel.groups(sections: sections, allSessions: [needYou, recent], query: "  ")
        XCTAssertEqual(groups.map(\.id), [SessionSidebarSectionKind.needYou.rawValue, SessionSidebarSectionKind.recent.rawValue])
        XCTAssertEqual(groups.map(\.title), [SessionSidebarSectionKind.needYou.localizedTitle, SessionSidebarSectionKind.recent.localizedTitle])
        XCTAssertEqual(SessionJumpPanelModel.flattened(groups).map(\.id), ["n", "r"])
    }

    func testQueryMatchesTitleProjectAndDirectoryAcrossAllSessions() {
        let sessions = [
            session("1", title: "修复登录", project: "mimi", dir: "/work/mimi"),
            session("2", title: "Release notes", project: "website", dir: "/work/site"),
            session("3", title: "清理缓存", project: "tools", dir: "/work/cat_name"),
            session("1", title: "修复登录", project: "mimi", dir: "/work/mimi")
        ]
        let byTitle = SessionJumpPanelModel.groups(sections: [], allSessions: sessions, query: "release")
        XCTAssertEqual(SessionJumpPanelModel.flattened(byTitle).map(\.id), ["2"], "标题匹配不区分大小写")
        let byProject = SessionJumpPanelModel.groups(sections: [], allSessions: sessions, query: "MIMI")
        XCTAssertEqual(SessionJumpPanelModel.flattened(byProject).map(\.id), ["1"], "重复的会话只出现一次")
        let byDirectory = SessionJumpPanelModel.groups(sections: [], allSessions: sessions, query: "cat_name")
        XCTAssertEqual(SessionJumpPanelModel.flattened(byDirectory).map(\.id), ["3"])
        XCTAssertTrue(SessionJumpPanelModel.groups(sections: [], allSessions: sessions, query: "不存在").isEmpty)
    }

    func testSearchResultsAreCapped() {
        let many = (0..<80).map { session("s\($0)", title: "任务 \($0)") }
        let groups = SessionJumpPanelModel.groups(sections: [], allSessions: many, query: "任务")
        XCTAssertEqual(SessionJumpPanelModel.flattened(groups).count, SessionJumpPanelModel.searchResultLimit)
    }

    // MARK: - Helpers

    private func session(
        _ id: SessionID,
        title: String,
        project: String = "project",
        dir: String = "/work/project"
    ) -> AgentSession {
        AgentSession(
            id: id,
            projectID: project,
            project: project,
            dir: dir,
            title: title,
            status: "idle",
            source: "codex",
            resumeID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }
}
