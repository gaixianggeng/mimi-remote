import XCTest
import Combine
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testGlobalLibraryPublishesAllRuntimeFirstPagesBeforeBackfill() async {
        let project = makeProject(id: "startup")
        let runtimes = RuntimeFeatureSupport.runtimeProviders
        let firstPageIDs = Set(runtimes.map { "\($0)-0" })
        var calls: [String] = []
        var store: SessionStore!
        let client = MockSessionStoreClient(
            projects: [project], sessions: [],
            controlledGlobalSessionsByRuntimeHandler: { runtime, cursor, _ in
                let pageIndex = Int(cursor ?? "0")!
                calls.append("\(runtime)-\(pageIndex)")
                if pageIndex > 0 {
                    XCTAssertTrue(firstPageIDs.isSubset(of: Set(store.sessions.map(\.id))),
                                  "后续页开始前，所有渠道的首屏都必须已经可见")
                    XCTAssertTrue(firstPageIDs.isSubset(of: store.controlledGlobalSessionIDs))
                }
                // 固定每页延迟供本机重复度量；验收依赖请求/发布边界，不依赖机器快慢。
                try await Task.sleep(nanoseconds: 20_000_000)
                let session = makeSession(
                    id: "\(runtime)-\(pageIndex)", projectID: project.id,
                    title: runtime, status: "history", source: runtime
                )
                return SessionsPage(sessions: [session], nextCursor: "\(pageIndex + 1)", hasMore: true)
            }
        )
        store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(),
            logStore: LogStore(), clientFactory: { client }
        )
        var snapshots: [Set<SessionID>] = []
        var requestsAtFirstPublish: Int?
        let start = ProcessInfo.processInfo.systemUptime
        var firstVisibleAt: TimeInterval?
        let observation = store.$sessions.dropFirst().sink { sessions in
            guard !sessions.isEmpty else { return }
            snapshots.append(Set(sessions.map(\.id)))
            if firstVisibleAt == nil {
                firstVisibleAt = ProcessInfo.processInfo.systemUptime - start
                requestsAtFirstPublish = calls.count
            }
        }

        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(Array(calls.prefix(runtimes.count)), runtimes.map { "\($0)-0" })
        XCTAssertEqual(requestsAtFirstPublish, runtimes.count)
        XCTAssertEqual(calls.count, runtimes.count * 4, "每个渠道仍最多四页")
        XCTAssertEqual(snapshots.first, firstPageIDs)
        XCTAssertEqual(snapshots.count, 2, "首屏与补全各发布一次，不能每页都重算列表")
        XCTAssertEqual(store.sessions.count, runtimes.count * 4)
        print("Session library fixture: first visible=\(firstVisibleAt ?? -1)s, total=\(ProcessInfo.processInfo.systemUptime - start)s, requests before first visible=\(requestsAtFirstPublish ?? -1)")
        withExtendedLifetime(observation) {}
    }

    func testGlobalLibraryFirstPageFailureDoesNotBlockOtherRuntimeFirstPages() async {
        let project = makeProject(id: "startup_partial")
        var store: SessionStore!
        var requests: [String] = []
        let client = MockSessionStoreClient(
            projects: [project], sessions: [],
            controlledGlobalSessionsByRuntimeHandler: { runtime, cursor, _ in
                requests.append(runtime)
                if runtime == "codex" { throw MockError.unimplemented }
                if cursor != nil {
                    XCTAssertEqual(Set(store.sessions.map(\.source)), ["claude", "deepseek"])
                    return SessionsPage(sessions: [])
                }
                return SessionsPage(sessions: [makeSession(
                    id: "\(runtime)-first", projectID: project.id,
                    title: runtime, status: "history", source: runtime
                )], nextCursor: "more", hasMore: true)
            }
        )
        store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(),
            logStore: LogStore(), clientFactory: { client }
        )

        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(requests, ["codex", "claude", "deepseek", "claude", "deepseek"])
        XCTAssertEqual(Set(store.sessions.map(\.source)), ["claude", "deepseek"])
    }
}
