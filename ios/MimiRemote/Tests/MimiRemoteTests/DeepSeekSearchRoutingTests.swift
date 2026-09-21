import XCTest
@testable import MimiRemote

/// deepseek 的 app-server 搜索路由已随 Go 侧翻译层删除；这里只保留仍成立的产品面契约：
/// 搜索结果里的 unavailable provider 要变成用户可见提示，并在新查询/重置时收敛。
@MainActor
final class DeepSeekSearchRoutingTests: XCTestCase {
    func testPartialSearchNoticeSurvivesContinuationAndClearsForNewQuery() {
        let client = MockSessionStoreClient(projects: [], sessions: [])
        let store = SessionStore(appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(),
                                 logStore: LogStore(), clientFactory: { client })
        store.applyRemoteSessionSearchPage(
            .init(results: [], nextCursor: "more", unavailableRuntimeProviders: ["deepseek"]),
            replacing: true, requestedCursor: nil
        )
        XCTAssertTrue(store.remoteSessionSearchNotice?.contains("DeepSeek") == true)
        store.applyRemoteSessionSearchPage(.init(results: []), replacing: false, requestedCursor: "more")
        XCTAssertNotNil(store.remoteSessionSearchNotice)
        store.resetRemoteSessionSearchState()
        XCTAssertNil(store.remoteSessionSearchNotice)
    }
}
