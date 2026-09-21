import XCTest
@testable import MimiRemote

/// H01 接缝验收。
///
/// 目标不是验证原生协议本身（H02 起才实现），而是证明三件事：
/// 1. 原生通道可以并列接入，且 DeepSeek 分发不再依赖 Codex actor；
/// 2. 正式构建始终装配原生客户端，但是否启用仍由宿主 channel 决定；
/// 3. 单个 runtime 失败不拖垮其他 runtime，且骨架只显式失败、不伪装空成功。
@MainActor
final class HarnessNativeRoutingSeamTests: XCTestCase {

#if DEBUG
    func testFormalNativeHarnessFactoryDoesNotRequireTestLaunchArgument() {
        let appStore = makeIsolatedAppStore()
        let bundle = AppServerRuntimeBundle(
            endpoint: "http://127.0.0.1:8787", token: "fixture",
            harnessFactory: appStore.nativeHarnessFactory
        )
        XCTAssertTrue(bundle.harness is HarnessSessionAPIClient)
        XCTAssertNotNil(
            bundle.nativeClient(for: "deepseek"),
            "正式入口必须在没有 --test-native-harness 时装配原生客户端"
        )
    }

    func testSameHostReusesOneNativeHarnessClient() {
        let appStore = makeIsolatedAppStore()
        let first = appStore.runtimeBundle(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture"
        )
        let second = appStore.runtimeBundle(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture"
        )

        XCTAssertTrue(first === second)
        XCTAssertTrue(first.harness === second.harness)
    }

    /// 正式 factory 注入后 native 独占 deepseek，不能同时保留旧 Codex actor 作为
    /// 写失败后的自动回退。
    func testLiveFactoryBuildsNativeClientWithoutDeepSeekFallback() {
        let bundle = AppServerRuntimeBundle(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            harnessFactory: HarnessSessionAPIClient.liveFactory
        )

        XCTAssertTrue(bundle.harness is HarnessSessionAPIClient)
        XCTAssertThrowsError(
            try bundle.runtime(for: "deepseek"),
            "原生写路径启用后不得保留旧 deepseek 写回退"
        ) { error in
            XCTAssertEqual(error as? HarnessNativeUnavailableError, .routedNatively(runtimeProvider: "deepseek"))
        }
    }
#endif

    // MARK: - 硬绑定解除

    func testInjectedNativeClientDoesNotInstantiateDeepSeekCodexActor() {
        let bundle = makeBundle(harness: FakeHarnessSessionClient())
        XCTAssertThrowsError(
            try bundle.runtime(for: "deepseek"),
            "原生通道激活后不得再构造 deepseek Codex actor"
        ) { error in
            XCTAssertEqual(error as? HarnessNativeUnavailableError, .routedNatively(runtimeProvider: "deepseek"))
        }
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

    /// deepseek 的 app-server 翻译层已删除：即使没有注入原生客户端，也没有可回退的 actor，
    /// `runtime(for:)` 必须显式抛 `routedNatively`，绝不能静默落到 Codex actor 假装 native。
    func testDefaultBundleWithoutNativeClientStillRejectsDeepSeekActorLookup() throws {
        let bundle = makeBundle()
        XCTAssertNil(bundle.harness, "默认不注入原生客户端")
        XCTAssertNil(bundle.nativeClient(for: "deepseek"))
        XCTAssertThrowsError(try bundle.runtime(for: "deepseek")) { error in
            XCTAssertEqual(
                error as? HarnessNativeUnavailableError,
                .routedNatively(runtimeProvider: "deepseek"),
                "旧 app-server 桥接路径已删除，deepseek 必须显式失败而不是回退到 actor"
            )
        }
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

    func testHarnessOnlyConnectionProbeUsesNativeHealthWithoutAppServerFallback() async throws {
        let harness = FakeHarnessSessionClient()
        let appServer = HarnessProbeForbiddenTransport()
        let config = makeDirectAppServerConfig(
            project: makeProject(id: "harness-only"),
            gatewayAvailable: false,
            channels: [makeNativeChannel(enabled: true)]
        )

        try await AppStore.validateAvailableGateway(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            timeout: 1,
            config: config,
            transportFactory: { appServer },
            harnessFactory: { _, _ in harness }
        )

        XCTAssertEqual(harness.channelAvailableCallCount, 1)
        let successProbeAppServerConnects = await appServer.connectCallCount()
        XCTAssertEqual(successProbeAppServerConnects, 0, "Harness-only 探测不得打开 app-server")
    }

    func testNativeHealthFailureDoesNotRetryThroughAppServer() async throws {
        let harness = FakeHarnessSessionClient()
        harness.channelAvailableResult = .failure(HarnessTransportError.closed)
        let appServer = HarnessProbeForbiddenTransport()
        let config = makeDirectAppServerConfig(
            project: makeProject(id: "harness-offline"),
            gatewayAvailable: false,
            channels: [makeNativeChannel(enabled: true)]
        )

        do {
            try await AppStore.validateAvailableGateway(
                endpoint: "http://127.0.0.1:8787",
                token: "fixture",
                timeout: 1,
                config: config,
                transportFactory: { appServer },
                harnessFactory: { _, _ in harness }
            )
            XCTFail("原生健康探测失败必须显式失败")
        } catch {
            XCTAssertEqual(error as? HarnessTransportError, .closed)
        }
        XCTAssertEqual(harness.channelAvailableCallCount, 1)
        let failedProbeAppServerConnects = await appServer.connectCallCount()
        XCTAssertEqual(failedProbeAppServerConnects, 0, "失败后不得改投旧 app-server")
    }

    // MARK: - 分发不触碰 Codex 通道

    func testSessionListForNativeProviderNeverTouchesCodexTransport() async throws {
        let fake = FakeHarnessSessionClient()
        fake.sessionsPageResult = .success(SessionsPage(sessions: [
            makeSession(id: "native-a", runtime: "deepseek")
        ]))
        let codexTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
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
        XCTAssertTrue(codexSent.isEmpty, "DeepSeek 分发不得触碰 Codex 通道")
    }

    func testNativeCreateSelectsModelAndQueuesPromptWithoutCodexFallback() async throws {
        let fake = FakeHarnessSessionClient()
        let codexTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            harness: fake
        ))
        let response = try await client.createSession(CreateSessionRequest(
            projectID: "seam",
            projectPath: "/tmp/seam",
            projectName: "Seam",
            prompt: "hello harness",
            turnOptions: CodexAppServerTurnOptions(
                runtimeProvider: "deepseek",
                model: "model-a",
                modelProvider: "provider-a",
                reasoningEffort: .high
            ),
            resumeID: "",
            clientMessageID: "request-create"
        ))

        XCTAssertEqual(fake.createdCWDs, ["/tmp/seam"])
        XCTAssertEqual(fake.selectedModels, [
            .init(sessionID: "created-fixture", provider: "provider-a", model: "model-a", effort: "high")
        ])
        XCTAssertEqual(response.session.id, "created-fixture")
        XCTAssertEqual(response.session.runtimeProvider, "deepseek")
        XCTAssertEqual(response.requiresQueuedInitialInput, true)
        let codexSent = await codexTransport.sentMessages()
        XCTAssertTrue(codexSent.isEmpty)
    }

    func testNativeStopUsesHarnessWithoutCodexFallback() async throws {
        let fake = FakeHarnessSessionClient()
        let codexTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            harness: fake
        ))
        client.rememberRuntimeRoute("deepseek", forSessionID: "native-stop")

        try await client.stopSession(id: "native-stop")

        XCTAssertEqual(fake.cancelledSessionIDs, ["native-stop"])
        let codexSent = await codexTransport.sentMessages()
        XCTAssertTrue(codexSent.isEmpty)
    }

    func testHostSwitchShutsDownSharedHarnessRuntime() async {
        let fake = FakeHarnessSessionClient()
        let bundle = makeBundle(harness: fake)

        await bundle.shutdownForHostSwitch()

        XCTAssertEqual(fake.shutdownCallCount, 1, "主机切换必须终止原生 reader，不能遗留上一主机的连接")
    }

    func testNativeSessionListRejectsNonemptyProjectIDWithoutGlobalFallback() async {
        let rpc = FailingHarnessRPCTransport(error: HarnessTransportError.timedOut)
        let client = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            rpc: rpc
        )

        do {
            _ = try await client.sessionsPage(
                projectID: "project-must-not-be-dropped",
                cursor: nil,
                limit: nil,
                consistency: .fastIndexed
            )
            XCTFail("非空 projectID 不得静默退化成全局查询")
        } catch {
            XCTAssertEqual(
                error as? HarnessNativeUnavailableError,
                .unsupported(operation: "session/list(projectID)")
            )
        }
        XCTAssertEqual(rpc.callCount, 0, "拒绝必须发生在调用上游之前")
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
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            harness: fake
        ))

        let available = try await client.runtimeChannelAvailable(runtimeProvider: "deepseek")

        XCTAssertTrue(available)
        XCTAssertEqual(fake.channelAvailableCallCount, 1, "原生通道可用性必须问原生客户端")
        let codexSent = await codexTransport.sentMessages()
        XCTAssertTrue(codexSent.isEmpty, "原生通道准备流程不得依赖 Codex 上游可用性")
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

    func testHarnessOnlyHostPreparesWithoutCodexOrClaude() async throws {
        let fake = FakeHarnessSessionClient()
        let codexTransport = FakeCodexAppServerTransport()
        let bundle = makeBundle(
            codexTransport: codexTransport,
            harness: fake,
            includeCodexChannel: false
        )

        try await bundle.prepareForHostActivation()

        let codexSent = await codexTransport.sentMessages()
        XCTAssertTrue(
            codexSent.isEmpty,
            "仅启用 Harness 时准备宿主不得初始化已关闭的 Codex/Claude"
        )
        XCTAssertEqual(fake.channelAvailableCallCount, 0, "准备阶段只判配置能力，不混入健康探测")
    }

    func testNativeChannelSeparatesUserEnableCapabilityAndHealth() async throws {
        let disabledFake = FakeHarnessSessionClient()
        let disabledClient = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            harness: disabledFake,
            nativeChannel: makeNativeChannel(enabled: false)
        ))
        let disabledAvailable = try await disabledClient.runtimeChannelAvailable(runtimeProvider: "deepseek")
        XCTAssertFalse(disabledAvailable)
        XCTAssertEqual(disabledFake.channelAvailableCallCount, 0, "用户关闭时不应探测 Harness 健康")

        let unsupportedFake = FakeHarnessSessionClient()
        let unsupportedClient = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            harness: unsupportedFake,
            nativeChannel: makeNativeChannel(
                enabled: true,
                type: "deepseek_harness_service",
                protocolName: "app_server_jsonrpc_stdio_v1"
            )
        ))
        do {
            _ = try await unsupportedClient.runtimeChannelAvailable(runtimeProvider: "deepseek")
            XCTFail("不支持的 agentd 协议必须明确要求升级")
        } catch {
            XCTAssertEqual(error as? HarnessNativeUnavailableError, .agentdUpgradeRequired)
        }
        XCTAssertEqual(unsupportedFake.channelAvailableCallCount, 0, "能力不兼容时不应触达 Harness")

        let offlineFake = FakeHarnessSessionClient()
        offlineFake.channelAvailableResult = .success(false)
        let offlineClient = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            harness: offlineFake,
            nativeChannel: makeNativeChannel(enabled: true)
        ))
        let offlineAvailable = try await offlineClient.runtimeChannelAvailable(runtimeProvider: "deepseek")
        XCTAssertFalse(offlineAvailable)
        XCTAssertEqual(offlineFake.channelAvailableCallCount, 1, "能力兼容后健康状态由真实原生探测决定")
    }

    // MARK: - 事件客户端与骨架

    /// 原生事件客户端必须显式拒绝 guidance，且**不得**把它当成 prompt 发出去。
    ///
    /// H08 之前这一层是纯骨架（连接即 failed、所有发送 notImplemented）。H08 之后
    /// 它有了真实实现，因此两处断言随之迁移到新语义：
    /// - guidance 仍被拒，但文案来自原生实现（Harness 从不支持它，不是"还没实现"）；
    /// - `sendGuidance` 返回 false 且**不产生任何 prompt**——这是真正要守住的：
    ///   把它当 prompt 发会让一次"引导"变成一条新的用户消息。
    ///
    /// 风险意图保持不变：这一层绝不能假装成功，也不能为未知操作编造一个替代动作。
    @MainActor
    func testNativeEventClientRejectsGuidanceInsteadOfSendingAsPrompt() async {
        let sink = GuidanceProbeSink()
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: "native-session",
            submission: HarnessSubmissionController(
                sendPrompt: { sessionID, requestID, text in
                    await sink.record(sessionID: sessionID, requestID: requestID, text: text)
                },
                sendCancel: { _ in }
            )
        )

        var failureMessage: String?
        client.onSendFailure = { _, message in failureMessage = message }

        let accepted = client.sendGuidance(
            CodexAppServerTurnPayload(prompt: "hi"),
            clientMessageID: "cmid-1",
            expectedTurnID: "turn-1"
        )

        XCTAssertFalse(accepted, "Harness 不支持 guidance，必须显式拒绝")
        XCTAssertNotNil(failureMessage, "必须回传可读的失败文案")
        let recorded = await sink.count
        XCTAssertEqual(recorded, 0, "guidance 不得被当成 prompt 发出去")
    }

    // 原生骨架的旧断言（H01 时代）已迁移，去向记录在这里：
    // 原文断言"连接必须显式报 failed"，理由是"骨架尚未实现事件流"。H08 实现事件流后
    // 这条不再成立——但它的**风险意图**（不得假装已连上）由
    // `HarnessEventClientTests.testConnectWithoutSnapshotSourceReportsFailure`
    // 在真实语义下继续覆盖：没有基线来源时连接必须 failed，且不得出现 .connected。

    /// 上游失败时不得伪装成"空成功"，也不得回落到旧网关。
    ///
    /// H01 时这条断言的是「骨架返回 `notImplemented`」。H05 把只读三件套换成了真实 RPC，
    /// `notImplemented` 不再是这些方法的行为，原断言随之失效——**但它的风险意图仍然成立**：
    /// 一次上游失败不能被翻译成"Harness 没有会话 / 没有模型"。
    ///
    /// 所以这里把断言迁移到新语义上，而不是删掉这条风险测试：
    /// 让传输层抛出真实的链路失败，方法必须**抛出**，且不得退化成空列表。
    /// 唯一的例外是 `channelAvailable`——它按设计把失败如实转成 throw，同样不允许返回 false。
    func testNativeClientPropagatesUpstreamFailureInsteadOfEmptySuccess() async throws {
        let failure = HarnessTransportError.server(status: 503, message: "上游不可用")
        let client = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            rpc: FailingHarnessRPCTransport(error: failure)
        )

        // 每条都要求"抛错"，而不是"返回空"。返回空列表会让上层显示
        // "没有会话/没有模型"——那是一个业务结论，而这里根本没拿到业务结论。
        do {
            let page = try await client.sessionsPage(
                projectID: nil, cursor: nil, limit: nil, consistency: .fastIndexed
            )
            XCTFail("上游失败不得返回空成功来冒充「没有会话」：\(page.sessions.count) 条")
        } catch {
            XCTAssertEqual(error as? HarnessTransportError, failure)
        }

        do {
            let options = try await client.modelOptions()
            XCTFail("上游失败不得返回空模型列表：\(options.count) 个")
        } catch {
            XCTAssertEqual(error as? HarnessTransportError, failure)
        }

        do {
            let available = try await client.channelAvailable()
            XCTFail("探测失败不得声称通道可用：\(available)")
        } catch {
            XCTAssertEqual(error as? HarnessTransportError, failure)
        }
    }

    /// 仍未开放的操作必须显式拒绝，不能返回空成功。
    ///
    /// `session(snapshot)` 原生路径没有等价入口（会话元数据走目录，消息走 follow 与
    /// `session/page`）。历史分页**已经**接通，因此这里换成了真正未开放的那一条，
    /// 免得用一条已经实现的调用去证明"尚未开放"。
    func testOperationsOutsideCurrentScopeStayExplicitlyUnimplemented() async {
        let client = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            rpc: FailingHarnessRPCTransport(error: HarnessTransportError.server(status: 503, message: "上游不可用"))
        )

        do {
            _ = try await client.session(id: "session-a", afterSeq: nil)
            XCTFail("会话快照读取在原生路径没有等价入口，不得返回空会话冒充成功")
        } catch {
            XCTAssertEqual(
                error as? HarnessNativeUnavailableError,
                .unsupported(operation: "session(snapshot)")
            )
        }
    }

    /// 历史分页在原生会话上必须走 `session/page`，不能落到 Codex actor。
    ///
    /// 落过去会 `routedNatively` 抛错，用户完全看不到历史；而返回空页更糟——
    /// 它把"读不了"伪装成"没有历史"。
    func testNativeSessionHistoryRoutesToHarnessInsteadOfCodexActor() async throws {
        let fake = FakeHarnessSessionClient()
        fake.messagesPageResult = .failure(HarnessTransportError.notConnected)
        let codexTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: makeBundle(
            codexTransport: codexTransport,
            harness: fake
        ))
        // 会话被登记为原生承接，历史入口才会走 `nativeClient` 分支。
        client.rememberRuntimeRoute("deepseek", forSessionID: "native-history")

        do {
            _ = try await client.messagesPage(sessionID: "native-history", before: nil, limit: nil)
            XCTFail("原生失败必须如实抛出，不得返回空历史")
        } catch {
            // 错误来自原生通道（未连接）而不是 Codex actor 的 routedNatively。
            XCTAssertNotEqual(
                error as? HarnessNativeUnavailableError,
                .routedNatively(runtimeProvider: "deepseek"),
                "历史入口必须真正走原生通道，而不是被 routedNatively 拒绝"
            )
        }
        XCTAssertEqual(fake.messagesPageCallCount, 1, "必须调用原生历史读取")
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
        harness: HarnessSessionClient? = nil,
        nativeChannel: CodexAppServerChannelMetadata? = nil,
        includeCodexChannel: Bool = true
    ) -> AppServerRuntimeBundle {
        let project = AgentProject(id: "seam", name: "Seam", path: "/tmp/seam")
        let methods = ["initialize", "initialized", "model/list", "thread/search"]
        var channels = [nativeChannel ?? makeNativeChannel(enabled: true)]
        if includeCodexChannel {
            channels.insert(makeCodexChannel(methods: methods), at: 0)
        }
        let config = makeDirectAppServerConfig(
            project: project,
            allowedMethods: methods,
            channels: channels
        )
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
            harness: harness
        )
    }

    private func makeCodexChannel(methods: [String]) -> CodexAppServerChannelMetadata {
        CodexAppServerChannelMetadata(
            id: "codex", runtimeID: "codex", title: "Codex", provider: "openai",
            type: "codex_app_server", protocolName: "app_server_jsonrpc_ws", enabled: true,
            gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws",
            gatewayAvailable: true, managed: false, experimental: false, lifecycle: "shared_ssh",
            bridge: nil, methods: methods, capabilities: ["history": true, "streaming": true]
        )
    }

    private func makeNativeChannel(
        enabled: Bool,
        type: String = "harness_native",
        protocolName: String = AppServerRuntimeBundle.nativeHarnessProtocol
    ) -> CodexAppServerChannelMetadata {
        CodexAppServerChannelMetadata(
            id: "deepseek", runtimeID: "deepseek", title: "DeepSeek Harness", provider: "deepseek",
            type: type, protocolName: protocolName, enabled: enabled,
            gatewayWSURL: "ws://127.0.0.1:7777/api/harness/ws",
            gatewayAvailable: true, managed: false, experimental: false, lifecycle: "shared_native_client",
            bridge: nil,
            methods: ["session/list", "session/follow", "session/page", "session/prompt"],
            capabilities: ["history": true, "streaming": true, "approval": true]
        )
    }
}

private actor HarnessProbeForbiddenTransportState {
    var connects = 0

    func recordConnect() {
        connects += 1
    }
}

private final class HarnessProbeForbiddenTransport: CodexAppServerTransport {
    private let state = HarnessProbeForbiddenTransportState()

    func connect(url: URL, token: String) async throws {
        await state.recordConnect()
        throw CodexAppServerSessionRuntimeError.gatewayUnavailable
    }

    func send(_ text: String) async throws {}
    func receive() async throws -> String? { nil }
    func close() async {}
    func connectCallCount() async -> Int { await state.connects }
}

/// 总是失败的 RPC 传输替身。
///
/// 用来把"上游失败"与"没有数据"这两件事分开：如果被测方法把失败吞成空列表，
/// 断言就会看到"成功但为空"，这正是要挡住的那类静默降级。
final class FailingHarnessRPCTransport: HarnessRPCTransport {
    private let error: Error
    private(set) var callCount = 0

    init(error: Error) {
        self.error = error
    }

    func call(_ request: HarnessRPCRequest) async throws -> HarnessJSONValue {
        callCount += 1
        throw error
    }
}

/// 记录"有没有被当成 prompt 发出去"的替身。
///
/// guidance 被拒的正确证据不是"返回 false"（那可能是空实现），而是**一次 prompt 都没发生**。
@MainActor
private final class GuidanceProbeSink {
    private(set) var count = 0

    func record(sessionID: String, requestID: String, text: String) async {
        count += 1
    }
}

/// 可控的原生客户端替身：用来证明分发路径、并制造单 runtime 失败。
@MainActor
final class FakeHarnessSessionClient: HarnessSessionClient {
    struct SelectedModel: Equatable {
        let sessionID: String
        let provider: String
        let model: String
        let effort: String?
    }

    var sessionsPageResult: Result<SessionsPage, Error> = .success(SessionsPage(sessions: []))
    var searchResult: Result<ThreadSearchPage, Error> = .success(ThreadSearchPage(results: []))
    var modelOptionsResult: Result<[CodexAppServerModelOption], Error> = .success([])
    var channelAvailableResult: Result<Bool, Error> = .success(true)

    private(set) var sessionsPageCallCount = 0
    private(set) var searchCallCount = 0
    private(set) var modelOptionsCallCount = 0
    private(set) var channelAvailableCallCount = 0
    private(set) var shutdownCallCount = 0

    func makeEventClient(sessionID: SessionID) -> any SessionWebSocketClient {
        HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787", token: "fixture", sessionID: sessionID,
            submission: HarnessSubmissionController(
                sendPrompt: { _, _, _ in }, sendCancel: { _ in }
            )
        )
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

    // MARK: - H07 写路径

    var createSessionResult: Result<HarnessCreatedSession, Error> =
        .success(HarnessCreatedSession(sessionID: "created-fixture", agentPreset: nil))
    var writeFailure: Error?
    private(set) var createSessionCallCount = 0
    private(set) var selectModelCallCount = 0
    private(set) var submitPromptCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var submittedRequestIDs: [String] = []
    private(set) var createdCWDs: [String] = []
    private(set) var selectedModels: [SelectedModel] = []
    private(set) var cancelledSessionIDs: [String] = []

    func createSession(cwd: String, sessionID: String?) async throws -> HarnessCreatedSession {
        createSessionCallCount += 1
        createdCWDs.append(cwd)
        if let writeFailure { throw writeFailure }
        return try createSessionResult.get()
    }

    func selectModel(
        sessionID: String,
        provider: String,
        model: String,
        reasoningEffort: String?
    ) async throws {
        selectModelCallCount += 1
        selectedModels.append(.init(
            sessionID: sessionID,
            provider: provider,
            model: model,
            effort: reasoningEffort
        ))
        if let writeFailure { throw writeFailure }
    }

    func submitPrompt(
        sessionID: String,
        requestID: String,
        text: String,
        mode: String,
        clientTimeZone: String?
    ) async throws {
        submitPromptCallCount += 1
        submittedRequestIDs.append(requestID)
        if let writeFailure { throw writeFailure }
    }

    func cancelSession(sessionID: String) async throws {
        cancelCallCount += 1
        cancelledSessionIDs.append(sessionID)
        if let writeFailure { throw writeFailure }
    }

    func shutdownForHostSwitch() async {
        shutdownCallCount += 1
    }

    // MARK: - 宿主级事件

    private(set) var startHostEventsCallCount = 0
    private(set) var stopHostEventsCallCount = 0
    private(set) var hostPendingInteractionsCount = 0
    private var hostEventsSink: (@MainActor (AgentEvent) -> Void)?

    // MARK: - 历史分页

    var messagesPageResult: Result<HistoryMessagesPage, Error> =
        .success(HistoryMessagesPage(messages: []))
    private(set) var messagesPageCallCount = 0

    @MainActor
    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage {
        messagesPageCallCount += 1
        return try messagesPageResult.get()
    }

    @MainActor
    func historyTurnItemsPage(
        sessionID: String,
        continuation: HistoryTurnItemsContinuation
    ) async throws -> HistoryTurnItemsPage {
        throw HarnessNativeUnavailableError.unsupported(operation: "historyTurnItemsPage")
    }

    @MainActor
    func latestTurnHistoryPage(sessionID: String) async throws -> HistoryMessagesPage? {
        nil
    }

    func setHostInteractionSinks(
        events: (@MainActor (AgentEvent) -> Void)?,
        changed: (@MainActor () -> Void)?,
        rejected: (@MainActor (String, String, String, String) -> Void)?
    ) {
        hostEventsSink = events
        hostRejectionSink = rejected
    }

    private var hostRejectionSink: (@MainActor (String, String, String, String) -> Void)?

    /// 造一次"应答未以接受收场"，验证装配方把**结论与原因**都接进了失败处理入口。
    func emitHostRejection(sessionID: String, eventID: String, outcome: String, message: String) {
        hostRejectionSink?(sessionID, eventID, outcome, message)
    }

    func startHostEvents() {
        startHostEventsCallCount += 1
    }

    func stopHostEvents() async {
        stopHostEventsCallCount += 1
    }

    func hostPendingInteractions() -> [HarnessInteractionStore.PendingInteraction] {
        hostPendingInteractionsCount += 1
        return []
    }

    /// 造一条宿主级事件，验证装配方真的把 sink 接上了。
    func emitHostEvent(_ event: AgentEvent) {
        hostEventsSink?(event)
    }
}
