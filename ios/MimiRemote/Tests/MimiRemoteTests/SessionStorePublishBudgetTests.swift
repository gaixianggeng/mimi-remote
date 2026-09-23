import XCTest
import Combine
@testable import MimiRemote

/// gh-410：底部 Tab 切换卡顿的一部分来自对 SessionStore 的多余发布。每次发布都会让
/// 所有观察它的界面（包括没显示的 Tab）整体重算，所以这里约束发布次数，而不只是最终数据。
@MainActor
final class SessionStorePublishBudgetTests: XCTestCase {
    func testControlledGlobalDiscoveryMergesAllPagesInSinglePublish() async {
        let project = makeProject(id: "proj_publish_budget")
        let codexPages: [String: SessionsPage] = [
            "": SessionsPage(
                sessions: [makeBudgetSession("codex-a", projectID: project.id, source: "codex")],
                nextCursor: "codex-page-2",
                hasMore: true
            ),
            "codex-page-2": SessionsPage(
                sessions: [makeBudgetSession("codex-b", projectID: project.id, source: "codex")],
                nextCursor: "codex-page-3",
                hasMore: true
            ),
            "codex-page-3": SessionsPage(
                sessions: [makeBudgetSession("codex-c", projectID: project.id, source: "codex")]
            ),
        ]
        let claudePage = SessionsPage(
            sessions: [makeBudgetSession("claude-a", projectID: project.id, source: "claude")]
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            runtimeChannelAvailability: ["codex": true, "claude": true],
            controlledGlobalSessionsByRuntimeHandler: { runtimeProvider, cursor, _ in
                if runtimeProvider == "claude" {
                    return claudePage
                }
                return codexPages[cursor ?? ""] ?? SessionsPage(sessions: [])
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        var sessionsPublishCount = 0
        var cancellables: Set<AnyCancellable> = []
        store.$sessions
            .dropFirst()
            .sink { _ in sessionsPublishCount += 1 }
            .store(in: &cancellables)

        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(client.requestedControlledGlobalCursors, [nil, "codex-page-2", "codex-page-3"])
        XCTAssertEqual(
            Set(store.sessions.map(\.id)),
            ["codex-a", "codex-b", "codex-c", "claude-a"],
            "两条 runtime 的所有分页都要并入 canonical sessions"
        )
        XCTAssertEqual(
            sessionsPublishCount,
            1,
            "全局发现翻页期间不能逐页发布；每次发布都会让整个工作台重算一轮"
        )
    }

    func testSessionSearchPresentationIgnoresUnchangedValue() {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        var publishCount = 0
        var cancellables: Set<AnyCancellable> = []
        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        // 会话页每次出现/消失都会上报一次；值没变时不能让观察者重算。
        store.setSessionSearchPresented(false)
        XCTAssertEqual(publishCount, 0)

        store.setSessionSearchPresented(true)
        XCTAssertTrue(store.isSessionSearchPresented)
        XCTAssertEqual(publishCount, 1)

        store.setSessionSearchPresented(true)
        XCTAssertEqual(publishCount, 1)
    }

    private func makeBudgetSession(_ id: String, projectID: String, source: String) -> AgentSession {
        makeSession(
            id: id,
            projectID: projectID,
            title: id,
            status: "history",
            source: source,
            resumeID: id
        )
    }
}
