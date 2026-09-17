import XCTest
@testable import MimiRemote

@MainActor
final class DeepSeekSearchRoutingTests: XCTestCase {
    func testCodexFailureStillReturnsHarnessMatchesAndRoute() async throws {
        let (client, codex, deepseek) = makeClient()
        let task = Task { try await client.searchSessions(query: "test", cursor: nil, limit: 50) }
        try await initialize(codex)
        let codexSearch = try await waitForFakeAppServerRequest(codex, method: "thread/search")
        transportErrorResponse(codex, id: codexSearch.id, code: -32000, message: "Codex unavailable")
        try await initialize(deepseek)
        let harnessSearch = try await waitForFakeAppServerRequest(deepseek, method: "thread/search")
        transportResponse(deepseek, id: harnessSearch.id, result: #"{"data":[{"thread":{"id":"harness-hit","cwd":"/tmp/search"},"snippet":"Harness match"}],"nextCursor":null}"#)

        let page = try await task.value
        XCTAssertEqual(page.sessions.map(\.id), ["harness-hit"])
        XCTAssertEqual(page.sessions.first?.runtimeProvider, "deepseek")
        XCTAssertEqual(client.rememberedRuntimeRoute(forSessionID: "harness-hit"), "deepseek")
        XCTAssertEqual(page.unavailableRuntimeProviders, ["codex"])
        XCTAssertNil(page.nextCursor)
    }

    func testAllAvailableRuntimesFailDoesNotReportSuccessfulEmptySearch() async throws {
        let (client, codex, deepseek) = makeClient()
        let task = Task { try await client.searchSessions(query: "test", cursor: nil, limit: 50) }
        try await initialize(codex)
        let codexSearch = try await waitForFakeAppServerRequest(codex, method: "thread/search")
        transportErrorResponse(codex, id: codexSearch.id, code: -32000, message: "Codex unavailable")
        try await initialize(deepseek)
        let harnessSearch = try await waitForFakeAppServerRequest(deepseek, method: "thread/search")
        transportErrorResponse(deepseek, id: harnessSearch.id, code: -32000, message: "Harness unavailable")
        do {
            _ = try await task.value
            XCTFail("全部搜索失败必须保留错误，不能伪装为零命中")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testContinuationRemainsCodexOnly() async throws {
        let (client, codex, deepseek) = makeClient()
        let task = Task { try await client.searchSessions(query: "test", cursor: "codex-next", limit: 50) }
        try await initialize(codex)
        let search = try await waitForFakeAppServerRequest(codex, method: "thread/search")
        transportResponse(codex, id: search.id, result: #"{"data":[],"nextCursor":null}"#)
        _ = try await task.value
        let messages = await deepseek.sentMessages()
        XCTAssertTrue(messages.isEmpty)
    }

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

    private func makeClient() -> (
        CodexAppServerRuntimeRoutingSessionAPIClient, FakeCodexAppServerTransport, FakeCodexAppServerTransport
    ) {
        let project = AgentProject(id: "search", name: "Search", path: "/tmp/search")
        let methods = ["initialize", "initialized", "thread/search"]
        let config = makeDirectAppServerConfig(project: project, allowedMethods: methods, channels: [
            CodexAppServerChannelMetadata(
                id: "deepseek", runtimeID: "deepseek", title: "DeepSeek Harness", provider: "deepseek",
                type: "deepseek_harness_service", protocolName: "app_server_jsonrpc_stdio_v1",
                gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws?runtime=deepseek",
                gatewayAvailable: true, managed: false, experimental: true, lifecycle: "per_connection",
                bridge: nil, methods: methods, capabilities: ["history": true, "streaming": true]
            )
        ])
        let codexTransport = FakeCodexAppServerTransport()
        let deepseekTransport = FakeCodexAppServerTransport()
        func runtime(_ provider: String, _ transport: FakeCodexAppServerTransport) -> CodexAppServerSessionRuntime {
            CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "fixture",
                runtimeProvider: provider, transportFactory: { transport }, configProvider: { config })
        }
        let bundle = AppServerRuntimeBundle(
            codexRuntime: runtime("codex", codexTransport),
            claudeRuntime: runtime("claude", FakeCodexAppServerTransport()),
            deepseekRuntime: runtime("deepseek", deepseekTransport)
        )
        return (CodexAppServerRuntimeRoutingSessionAPIClient(bundle: bundle), codexTransport, deepseekTransport)
    }

    private func initialize(_ transport: FakeCodexAppServerTransport) async throws {
        let request = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: request.id, result: #"{"userAgent":"fixture"}"#)
    }
}
