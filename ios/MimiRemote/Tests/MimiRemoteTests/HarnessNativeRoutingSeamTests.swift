import XCTest
@testable import MimiRemote

/// H01 接缝验收。
///
/// 目标不是验证原生协议本身（H02 起才实现），而是证明三件事：
/// 1. 原生通道可以并列接入，且 DeepSeek 分发不再依赖 Codex actor；
/// 2. 未注入原生客户端时（开发期默认）行为完全不变；
/// 3. 单个 runtime 失败不拖垮其他 runtime，且骨架只显式失败、不伪装空成功。
@MainActor
final class HarnessNativeRoutingSeamTests: XCTestCase {

    // MARK: - 硬绑定解除

    func testInjectedNativeClientDoesNotInstantiateDeepSeekCodexActor() {
        let bundle = makeBundle(harness: FakeHarnessSessionClient())
        XCTAssertNil(bundle.deepseek, "原生通道激活后不得再构造 deepseek Codex actor")
        XCTAssertNotNil(bundle.nativeClient(for: "deepseek"))
        XCTAssertNil(bundle.nativeClient(for: "codex"), "原生通道只承接 deepseek")
        XCTAssertNil(bundle.nativeClient(for: "claude"), "原生通道只承接 deepseek")
    }

    func testRuntimeLookupForNativeProviderIsExplicitlyRejected() {
        let bundle = makeBundle(harness: FakeHarnessSessionClient())
        XCTAssertThrowsError(try bundle.runtime(for: "deepseek")) { error in
            XCTAssertEqual(
                error as? HarnessNativeUnavailableError,
                .routedNatively(runtimeProvider: "deepseek"),
                "原生通道激活后 runtime(for:) 不得回退到 Codex actor"
            )
        }
    }

    func testDefaultBundleKeepsLegacyPathUnchanged() throws {
        let bundle = makeBundle()
        XCTAssertNil(bundle.harness, "开发期默认不注入原生客户端")
        XCTAssertNotNil(bundle.deepseek, "未注入时 deepseek 仍走既有 app-server 路径")
        XCTAssertNil(bundle.nativeClient(for: "deepseek"))
        XCTAssertNoThrow(try bundle.runtime(for: "deepseek"))
    }

    func testCodexAndClaudeStillResolveToCodexActorsWhenNativeInjected() throws {
        let bundle = makeBundle(harness: FakeHarnessSessionClient())
        XCTAssertTrue(try bundle.runtime(for: "codex") === bundle.codex)
        XCTAssertTrue(try bundle.runtime(for: "claude") === bundle.claude)
    }

    func testUnknownRuntimeIsStillRejectedWhenNativeInjected() {
        let bundle = makeBundle(harness: FakeHarnessSessionClient())
        XCTAssertThrowsError(try bundle.runtime(for: "not-a-runtime"))
    }

    // MARK: - 分发不触碰 Codex 通道

    func testSessionListForNativeProviderNeverTouchesCodexTransport() async throws {
        let fake = FakeHarnessSessionClient()
        fake.sessionsPageResult = .success(SessionsPage(sessions: [
            makeSession(id: "native-a", runtime: "deepseek")
        ]))
        let codexTransport = FakeCodexAppServerTransport()
        let deepseekTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            deepseekTransport: deepseekTransport,
            harness: fake
        ))

        let page = try await client.sessionsPage(
            projectID: nil,
            runtimeProvider: "deepseek",
            cursor: nil,
            limit: nil,
            consistency: .fastIndexed
        )

        XCTAssertEqual(page.sessions.map(\.id), ["native-a"])
        XCTAssertEqual(fake.sessionsPageCallCount, 1)
        let codexSent = await codexTransport.sentMessages()
        let deepseekSent = await deepseekTransport.sentMessages()
        XCTAssertTrue(codexSent.isEmpty, "DeepSeek 分发不得触碰 Codex 通道")
        XCTAssertTrue(deepseekSent.isEmpty, "DeepSeek 分发不得再走 deepseek 的 Codex 通道")
    }

    // MARK: - 单 runtime 失败隔离

    func testCodexSearchFailureStillReturnsNativeResults() async throws {
        let fake = FakeHarnessSessionClient()
        fake.searchResult = .success(ThreadSearchPage(results: [
            ThreadSearchResult(session: makeSession(id: "native-hit", runtime: "deepseek"), snippet: "native")
        ]))
        let codexTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            harness: fake
        ))

        let task = Task { try await client.searchSessions(query: "q", cursor: nil, limit: 50) }
        try await initialize(codexTransport)
        let codexSearch = try await waitForFakeAppServerRequest(codexTransport, method: "thread/search")
        transportErrorResponse(codexTransport, id: codexSearch.id, code: -32000, message: "Codex unavailable")

        let page = try await task.value
        XCTAssertEqual(page.sessions.map(\.id), ["native-hit"])
        XCTAssertEqual(page.unavailableRuntimeProviders, ["codex"])
        XCTAssertEqual(fake.searchCallCount, 1)
    }

    func testNativeSearchFailureKeepsCodexResults() async throws {
        let fake = FakeHarnessSessionClient()
        fake.searchResult = .failure(HarnessNativeUnavailableError.notImplemented(operation: "session/search"))
        let codexTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            harness: fake
        ))

        let task = Task { try await client.searchSessions(query: "q", cursor: nil, limit: 50) }
        try await initialize(codexTransport)
        let codexSearch = try await waitForFakeAppServerRequest(codexTransport, method: "thread/search")
        transportResponse(codexTransport, id: codexSearch.id, result: #"{"data":[{"thread":{"id":"codex-hit","cwd":"/tmp/seam"},"snippet":"codex"}],"nextCursor":null}"#)

        let page = try await task.value
        XCTAssertEqual(page.sessions.map(\.id), ["codex-hit"], "原生失败不能拖垮 Codex 搜索")
        XCTAssertEqual(page.unavailableRuntimeProviders, ["deepseek"])
    }

    func testAllRuntimesFailingWithNativeDoesNotReportSuccessfulEmptySearch() async throws {
        let fake = FakeHarnessSessionClient()
        fake.searchResult = .failure(HarnessNativeUnavailableError.notImplemented(operation: "session/search"))
        let codexTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            harness: fake
        ))

        let task = Task { try await client.searchSessions(query: "q", cursor: nil, limit: 50) }
        try await initialize(codexTransport)
        let codexSearch = try await waitForFakeAppServerRequest(codexTransport, method: "thread/search")
        transportErrorResponse(codexTransport, id: codexSearch.id, code: -32000, message: "Codex unavailable")

        do {
            _ = try await task.value
            XCTFail("全部搜索失败必须保留错误，不能伪装成零命中")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testNativeModelCatalogFailureKeepsCodexOptions() async throws {
        let fake = FakeHarnessSessionClient()
        fake.modelOptionsResult = .failure(HarnessNativeUnavailableError.notImplemented(operation: "session/modelCatalog"))
        let codexTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            harness: fake
        ))

        let task = Task { try await client.modelOptions() }
        try await initialize(codexTransport)
        let codexModelList = try await waitForFakeAppServerRequest(codexTransport, method: "model/list")
        transportResponse(codexTransport, id: codexModelList.id,
                          result: #"{"models":[{"id":"gpt-live","title":"GPT Live","provider":"openai","isDefault":true}]}"#)

        let options = try await task.value
        XCTAssertEqual(options.map(\.model), ["gpt-live"], "原生模型目录失败不能拖垮 Codex 主路径")
    }

    func testNativeModelCatalogSurvivesCodexFailure() async throws {
        let fake = FakeHarnessSessionClient()
        fake.modelOptionsResult = .success([
            CodexAppServerModelOption(id: "harness-model", provider: "provider-a", runtimeProvider: "deepseek")
        ])
        let codexTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            harness: fake
        ))

        let task = Task { try await client.modelOptions() }
        try await initialize(codexTransport)
        let codexModelList = try await waitForFakeAppServerRequest(codexTransport, method: "model/list")
        transportErrorResponse(codexTransport, id: codexModelList.id, code: -32000, message: "Codex unavailable")

        let options = try await task.value
        XCTAssertEqual(options.map(\.model), ["harness-model"],
                       "Codex 上游不可用时仍应能进入已配置的 native 通道准备流程")
        XCTAssertEqual(options.first?.runtimeProvider, "deepseek")
    }

    // MARK: - 原生通道准备流程不依赖 Codex 上游

    func testNativeChannelAvailabilityNeverConsultsCodexUpstream() async throws {
        let fake = FakeHarnessSessionClient()
        fake.channelAvailableResult = .success(true)
        let codexTransport = FakeCodexAppServerTransport()
        let deepseekTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            deepseekTransport: deepseekTransport,
            harness: fake
        ))

        let available = try await client.runtimeChannelAvailable(runtimeProvider: "deepseek")

        XCTAssertTrue(available)
        XCTAssertEqual(fake.channelAvailableCallCount, 1, "原生通道可用性必须问原生客户端")
        let codexSent = await codexTransport.sentMessages()
        let deepseekSent = await deepseekTransport.sentMessages()
        XCTAssertTrue(codexSent.isEmpty, "原生通道准备流程不得依赖 Codex 上游可用性")
        XCTAssertTrue(deepseekSent.isEmpty, "原生通道准备流程不得再走 deepseek 的 Codex 通道")
    }

    func testNativeChannelAvailabilityFailureDoesNotFallBackToCodex() async throws {
        let fake = FakeHarnessSessionClient()
        fake.channelAvailableResult = .failure(
            HarnessNativeUnavailableError.notImplemented(operation: "channelAvailable")
        )
        let codexTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            harness: fake
        ))

        do {
            _ = try await client.runtimeChannelAvailable(runtimeProvider: "deepseek")
            XCTFail("原生通道不可用时必须显式失败，不得静默回落 Codex 通道")
        } catch {
            XCTAssertEqual(
                error as? HarnessNativeUnavailableError,
                .notImplemented(operation: "channelAvailable")
            )
        }
        let codexSent = await codexTransport.sentMessages()
        XCTAssertTrue(codexSent.isEmpty, "回落 Codex 会掩盖原生通道尚未就绪")
    }

    // MARK: - 事件客户端与骨架

    func testNativeEventClientRejectsGuidanceInsteadOfSendingAsPrompt() {
        let bundle = makeBundle(harness: FakeHarnessSessionClient())
        bundle.routes.remember("deepseek", for: "native-session")
        let wrapper = MultiRuntimeSessionWebSocketClient(bundle: bundle)

        var status: WebSocketStatus?
        var failureMessage: String?
        wrapper.onStatus = { status = $0 }
        wrapper.onSendFailure = { _, message in failureMessage = message }

        wrapper.connect(sessionID: "native-session")

        let accepted = wrapper.sendGuidance(
            CodexAppServerTurnPayload(prompt: "hi"),
            clientMessageID: "cmid-1",
            expectedTurnID: "turn-1"
        )
        XCTAssertFalse(accepted, "Harness 不支持 guidance，必须显式拒绝")
        XCTAssertEqual(failureMessage, HarnessNativeUnavailableError.unsupported(operation: "guidance").localizedDescription)
        if case .failed = status {} else {
            XCTFail("原生骨架尚未实现事件流，连接必须显式报 failed 而不是假装已连上")
        }
    }

    func testSkeletonReturnsExplicitNotImplementedInsteadOfEmptySuccess() async {
        let skeleton = HarnessSessionAPIClient(endpoint: "http://127.0.0.1:8787", token: "fixture")

        do {
            _ = try await skeleton.sessionsPage(projectID: nil, cursor: nil, limit: nil, consistency: .fastIndexed)
            XCTFail("骨架不得返回空成功来冒充「没有会话」")
        } catch {
            XCTAssertEqual(error as? HarnessNativeUnavailableError, .notImplemented(operation: "session/list"))
        }

        do {
            _ = try await skeleton.modelOptions()
            XCTFail("骨架不得返回空模型列表")
        } catch {
            XCTAssertEqual(error as? HarnessNativeUnavailableError, .notImplemented(operation: "session/modelCatalog"))
        }

        do {
            _ = try await skeleton.channelAvailable()
            XCTFail("骨架不得声称通道可用")
        } catch {
            XCTAssertEqual(error as? HarnessNativeUnavailableError, .notImplemented(operation: "channelAvailable"))
        }
    }

    // MARK: - 支撑

    private func initialize(_ transport: FakeCodexAppServerTransport) async throws {
        let request = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: request.id, result: #"{"userAgent":"fixture"}"#)
    }

    private func makeSession(id: String, runtime: String) -> AgentSession {
        AgentSession(
            id: id,
            projectID: "seam",
            project: "Seam",
            dir: "/tmp/seam",
            title: id,
            status: "history",
            source: runtime,
            resumeID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }

    private func makeBundle(
        codexTransport: FakeCodexAppServerTransport = FakeCodexAppServerTransport(),
        deepseekTransport: FakeCodexAppServerTransport = FakeCodexAppServerTransport(),
        harness: HarnessSessionClient? = nil
    ) -> AppServerRuntimeBundle {
        let project = AgentProject(id: "seam", name: "Seam", path: "/tmp/seam")
        let methods = ["initialize", "initialized", "model/list", "thread/search"]
        let config = makeDirectAppServerConfig(project: project, allowedMethods: methods, channels: [
            CodexAppServerChannelMetadata(
                id: "deepseek", runtimeID: "deepseek", title: "DeepSeek Harness", provider: "deepseek",
                type: "deepseek_harness_service", protocolName: "app_server_jsonrpc_stdio_v1",
                gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws?runtime=deepseek",
                gatewayAvailable: true, managed: false, experimental: true, lifecycle: "per_connection",
                bridge: nil, methods: methods, capabilities: ["history": true, "streaming": true]
            )
        ])
        func runtime(_ provider: String, _ transport: FakeCodexAppServerTransport) -> CodexAppServerSessionRuntime {
            CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "fixture",
                runtimeProvider: provider,
                transportFactory: { transport },
                configProvider: { config }
            )
        }
        return AppServerRuntimeBundle(
            codexRuntime: runtime("codex", codexTransport),
            claudeRuntime: runtime("claude", FakeCodexAppServerTransport()),
            deepseekRuntime: runtime("deepseek", deepseekTransport),
            harness: harness
        )
    }
}

/// 可控的原生客户端替身：用来证明分发路径、并制造单 runtime 失败。
final class FakeHarnessSessionClient: HarnessSessionClient {
    var sessionsPageResult: Result<SessionsPage, Error> = .success(SessionsPage(sessions: []))
    var searchResult: Result<ThreadSearchPage, Error> = .success(ThreadSearchPage(results: []))
    var modelOptionsResult: Result<[CodexAppServerModelOption], Error> = .success([])
    var channelAvailableResult: Result<Bool, Error> = .success(true)

    private(set) var sessionsPageCallCount = 0
    private(set) var searchCallCount = 0
    private(set) var modelOptionsCallCount = 0
    private(set) var channelAvailableCallCount = 0

    func makeEventClient(sessionID: SessionID) -> any SessionWebSocketClient {
        HarnessSessionWebSocketClient(endpoint: "http://127.0.0.1:8787", token: "fixture", sessionID: sessionID)
    }

    func channelAvailable() async throws -> Bool {
        channelAvailableCallCount += 1
        return try channelAvailableResult.get()
    }

    func sessionsPage(
        projectID: String?,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        sessionsPageCallCount += 1
        return try sessionsPageResult.get()
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        sessionsPageCallCount += 1
        return try sessionsPageResult.get()
    }

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage {
        sessionsPageCallCount += 1
        return try sessionsPageResult.get()
    }

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        searchCallCount += 1
        return try searchResult.get()
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw HarnessNativeUnavailableError.notImplemented(operation: "session/read")
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        modelOptionsCallCount += 1
        return try modelOptionsResult.get()
    }
}
