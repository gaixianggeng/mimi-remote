import XCTest
@testable import MimiRemote

@MainActor
final class DeepSeekSessionRuntimeTests: XCTestCase {
    func testAliasesRouteToDeepSeekAndUnknownProviderFailsClosed() throws {
        for alias in [
            "deepseek", "deepseek_harness", "deepseek-harness",
            "deepseek_harness_service", "deepseek-harness-service", "dsh"
        ] {
            XCTAssertEqual(CodexAppServerSessionRuntime.normalizedRuntimeProvider(alias), "deepseek")
        }

        let codex = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "token")
        let claude = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "token", runtimeProvider: "claude"
        )
        let deepseek = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "token", runtimeProvider: "deepseek"
        )
        let bundle = AppServerRuntimeBundle(
            codexRuntime: codex,
            claudeRuntime: claude,
            deepseekRuntime: deepseek
        )

        bundle.routes.remember(runtimeProvider: nil, source: "appServer", for: "legacy")
        XCTAssertEqual(bundle.routes.runtimeProvider(for: "legacy"), "codex")
        bundle.routes.remember(runtimeProvider: "dsh", source: nil, for: "harness")
        XCTAssertTrue(try bundle.runtime(forSessionID: "harness") === deepseek)

        bundle.routes.remember("future-runtime", for: "unknown")
        XCTAssertThrowsError(try bundle.runtime(forSessionID: "unknown"))
    }

    func testModelCatalogReturnsDeepSeekWhenCodexModelListFails() async throws {
        let project = AgentProject(id: "proj_models", name: "Models", path: "/tmp/deepseek-models")
        let config = makeDeepSeekConfig(project: project)
        let codexTransport = FakeCodexAppServerTransport()
        let deepseekTransport = FakeCodexAppServerTransport()
        let codex = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "token",
            transportFactory: { codexTransport },
            configProvider: { config }
        )
        let claude = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "token",
            runtimeProvider: "claude",
            transportFactory: { FakeCodexAppServerTransport() },
            configProvider: { config }
        )
        let deepseek = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "token",
            runtimeProvider: "deepseek",
            transportFactory: { deepseekTransport },
            configProvider: { config }
        )
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: AppServerRuntimeBundle(
            codexRuntime: codex,
            claudeRuntime: claude,
            deepseekRuntime: deepseek
        ))

        let task = Task { try await client.modelOptions() }
        let codexInitialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: codexInitialize.id, result: #"{"userAgent":"fake-codex"}"#)
        let codexModels = try await waitForFakeAppServerRequest(codexTransport, method: "model/list")
        transportErrorResponse(codexTransport, id: codexModels.id, code: -32000, message: "Codex unavailable")

        let deepseekInitialize = try await waitForFakeAppServerRequest(deepseekTransport, method: "initialize")
        transportResponse(deepseekTransport, id: deepseekInitialize.id, result: #"{"userAgent":"fake-deepseek"}"#)
        let deepseekModels = try await waitForFakeAppServerRequest(deepseekTransport, method: "model/list")
        transportResponse(
            deepseekTransport,
            id: deepseekModels.id,
            result: #"{"models":[{"id":"deepseek-chat","provider":"provider-a","isDefault":true}]}"#
        )

        let options = try await task.value
        XCTAssertEqual(options.map(\.model), ["deepseek-chat"])
        XCTAssertEqual(options.first?.runtimeProvider, "deepseek")
        XCTAssertEqual(options.first?.provider, "provider-a")
    }

    func testCreateKeepsDeepSeekProviderOnThreadStart() async throws {
        let project = AgentProject(id: "proj_create", name: "Create", path: "/tmp/deepseek-create")
        let transport = FakeCodexAppServerTransport()
        let runtime = makeDeepSeekRuntime(project: project, transportFactory: { transport })
        let options = CodexAppServerTurnOptions(
            runtimeProvider: "deepseek",
            model: "deepseek-chat",
            modelProvider: "provider-b"
        )

        let task = Task {
            try await runtime.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                turnOptions: options,
                resumeID: ""
            ))
        }
        try await completeInitialize(transport)
        let threadStart = try await waitForFakeAppServerRequest(transport, method: "thread/start")
        let params = try XCTUnwrap(threadStart.params?.objectValue)
        XCTAssertNil(params["model"])
        XCTAssertEqual(params["modelProvider"]?.stringValue, "provider-b")
        transportResponse(
            transport,
            id: threadStart.id,
            result: #"{"thread":{"id":"thr_create","sessionId":"thr_create","preview":"","ephemeral":false,"modelProvider":"provider-b","createdAt":1780490200,"updatedAt":1780490201,"status":{"type":"idle"},"path":null,"cwd":"/tmp/deepseek-create","cliVersion":"0.0.0","source":"deepseek","threadSource":"user","name":"DeepSeek","turns":[]}}"#
        )

        let response = try await task.value
        XCTAssertEqual(response.session.id, "thr_create")
        XCTAssertEqual(response.session.runtimeProvider, "deepseek")
    }

    func testResumeUsesReadThenTurnStartWithoutThreadResume() async throws {
        let project = AgentProject(id: "proj_resume", name: "Resume", path: "/tmp/deepseek-resume")
        let transport = FakeCodexAppServerTransport()
        let runtime = makeDeepSeekRuntime(project: project, transportFactory: { transport })
        let options = CodexAppServerTurnOptions(
            runtimeProvider: "deepseek",
            model: "deepseek-chat",
            modelProvider: "provider-a"
        )

        let task = Task {
            try await runtime.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "继续",
                turnOptions: options,
                resumeID: "thr_resume",
                clientMessageID: "client-resume"
            ))
        }
        try await completeInitialize(transport)
        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        transportResponse(
            transport,
            id: read.id,
            result: #"{"thread":{"id":"thr_resume","sessionId":"thr_resume","preview":"继续","ephemeral":false,"modelProvider":"provider-a","createdAt":1780490200,"updatedAt":1780490201,"status":{"type":"idle"},"path":null,"cwd":"/tmp/deepseek-resume","cliVersion":"0.0.0","source":"deepseek","threadSource":"user","name":"DeepSeek Resume","turns":[]}}"#
        )
        let turnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start")
        XCTAssertEqual(turnStart.params?["modelProvider"]?.stringValue, "provider-a")
        transportResponse(
            transport,
            id: turnStart.id,
            result: #"{"turn":{"id":"turn_resume","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null}}"#
        )
        _ = try await task.value

        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        XCTAssertFalse(requests.contains { $0.method == "thread/resume" })
        XCTAssertEqual(requests.filter { $0.method == "thread/read" }.count, 1)
        XCTAssertEqual(requests.filter { $0.method == "turn/start" }.count, 1)
    }

    func testReconnectSubscribesWithoutResumeAndForwardsApprovalAndQuestion() async throws {
        let project = AgentProject(id: "proj_reconnect", name: "Reconnect", path: "/tmp/deepseek-reconnect")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = makeDeepSeekRuntime(project: project, transportFactory: { pool.make() })

        let createTask = Task {
            try await runtime.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                turnOptions: .init(runtimeProvider: "deepseek", modelProvider: "provider-a"),
                resumeID: ""
            ))
        }
        let first = try await waitForFakeAppServerTransport(in: pool, index: 0)
        try await completeInitialize(first)
        let start = try await waitForFakeAppServerRequest(first, method: "thread/start")
        transportResponse(
            first,
            id: start.id,
            result: #"{"thread":{"id":"thr_reconnect","sessionId":"thr_reconnect","preview":"","ephemeral":false,"modelProvider":"provider-a","createdAt":1780490200,"updatedAt":1780490201,"status":{"type":"idle"},"path":null,"cwd":"/tmp/deepseek-reconnect","cliVersion":"0.0.0","source":"deepseek","threadSource":"user","name":"DeepSeek Reconnect","turns":[]}}"#
        )
        _ = try await createTask.value

        first.failReceive()
        try await waitForRuntimeConnectionToBecomeUnavailable(runtime)

        let dummyCodex = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "token")
        let dummyClaude = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "token", runtimeProvider: "claude"
        )
        let bundle = AppServerRuntimeBundle(
            codexRuntime: dummyCodex,
            claudeRuntime: dummyClaude,
            deepseekRuntime: runtime
        )
        bundle.routes.remember("deepseek", for: "thr_reconnect")
        let socket = MultiRuntimeSessionWebSocketClient(bundle: bundle)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_reconnect")
        defer { socket.disconnect() }

        let second = try await waitForFakeAppServerTransport(in: pool, index: 1)
        try await completeInitialize(second)
        let turnsList = try await waitForFakeAppServerRequest(second, method: "thread/turns/list")
        transportResponse(second, id: turnsList.id, result: #"{"data":[],"nextCursor":null}"#)
        try await waitUntil { statuses.contains(.connected) }

        let reconnectRequests = await second.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(reconnectRequests.filter { $0.method == "thread/turns/list" }.count, 1)
        XCTAssertFalse(reconnectRequests.contains { $0.method == "thread/resume" })

        second.enqueue(#"{"method":"turn/started","params":{"threadId":"thr_reconnect","turn":{"id":"turn_live"}}}"#)
        try await waitUntil {
            events.contains { if case .turnStarted = $0 { return true }; return false }
        }
        second.enqueue(#"{"id":91,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_reconnect","turnId":"turn_live","itemId":"cmd_live","command":"go test ./..."}}"#)
        try await waitUntil {
            events.contains { if case .approvalRequest(let request, _) = $0 { return request.id == "cmd_live" }; return false }
        }
        XCTAssertTrue(socket.sendApprovalDecision(approvalID: "cmd_live", decision: "accept", message: nil))
        let approval = try await waitForFakeAppServerResponse(second, id: .int(91))
        XCTAssertEqual(approval.result?["decision"]?.stringValue, "accept")

        second.enqueue(#"{"id":92,"method":"item/tool/requestUserInput","params":{"threadId":"thr_reconnect","turnId":"turn_live","itemId":"question_live","questions":[{"id":"scope","header":"范围","question":"处理哪里？","isOther":true,"isSecret":false,"options":[{"label":"客户端","description":"处理 iPad"}]}]}}"#)
        try await waitUntil {
            events.contains { if case .userInputRequest(let request, _) = $0 { return request.id == "question_live" }; return false }
        }
        XCTAssertTrue(socket.sendUserInputResponse(requestID: "question_live", answers: ["scope": ["客户端"]]))
        let answer = try await waitForFakeAppServerResponse(second, id: .int(92))
        XCTAssertEqual(
            answer.result?["answers"]?.objectValue?["scope"]?.objectValue?["answers"]?.arrayValue?.first?.stringValue,
            "客户端"
        )
    }

    private func makeDeepSeekRuntime(
        project: AgentProject,
        transportFactory: @escaping () -> CodexAppServerTransport
    ) -> CodexAppServerSessionRuntime {
        let config = makeDeepSeekConfig(project: project)
        return CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "token",
            runtimeProvider: "deepseek",
            transportFactory: transportFactory,
            configProvider: { config }
        )
    }

    private func completeInitialize(_ transport: FakeCodexAppServerTransport) async throws {
        let request = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: request.id, result: #"{"userAgent":"fake-deepseek"}"#)
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for DeepSeek runtime state", file: file, line: line)
    }
}

private func makeDeepSeekConfig(project: AgentProject) -> CodexAppServerConfigResponse {
    let methods = [
        "initialize", "initialized", "thread/list", "thread/search", "thread/start", "thread/read",
        "thread/turns/list", "thread/items/list", "turn/start", "turn/interrupt", "model/list"
    ]
    let channel = CodexAppServerChannelMetadata(
        id: "deepseek",
        runtimeID: "deepseek",
        title: "DeepSeek Harness",
        provider: "deepseek",
        type: "deepseek_harness_service",
        protocolName: "app_server_jsonrpc_stdio_v1",
        gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws?runtime=deepseek",
        gatewayAvailable: true,
        managed: false,
        experimental: true,
        lifecycle: "per_connection",
        bridge: nil,
        methods: methods,
        capabilities: ["history": true, "streaming": true]
    )
    return makeDirectAppServerConfig(project: project, allowedMethods: methods, channels: [channel])
}
