import XCTest
@testable import MimiRemote

// #791：目标任务（thread/goal/*）按通道声明的能力使用。Claude 通道没有声明时，
// 打开会话不能发 thread/goal/get，输入框与检查器也不能提供目标入口；Codex 行为不变。

private let threadGoalMethods = ["thread/goal/get", "thread/goal/set", "thread/goal/clear"]

private func threadGoalChannel(
    runtime: String,
    provider: String,
    methods: [String]?,
    goals: Bool?
) -> CodexAppServerChannelMetadata {
    CodexAppServerChannelMetadata(
        id: runtime,
        runtimeID: runtime,
        title: runtime,
        provider: provider,
        type: runtime == "claude" ? "claude_code_bridge" : "codex_app_server",
        protocolName: "app_server_jsonrpc_ws",
        gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws?runtime=\(runtime)",
        gatewayAvailable: true,
        managed: false,
        experimental: nil,
        lifecycle: nil,
        bridge: nil,
        methods: methods,
        capabilities: goals.map { ["history": true, "goals": $0] }
    )
}

/// 与 agentd 的 Claude 白名单一致：能 resume，但没有任何 thread/goal/* 方法，且 goals=false。
private func undeclaredGoalClaudeChannel() -> CodexAppServerChannelMetadata {
    threadGoalChannel(
        runtime: "claude",
        provider: "anthropic",
        methods: [
            "initialize", "initialized", "thread/list", "thread/start", "thread/resume",
            "thread/read", "thread/turns/list", "turn/start", "turn/steer", "turn/interrupt"
        ],
        goals: false
    )
}

private struct ThreadGoalRuntimeFixture {
    let runtime: CodexAppServerSessionRuntime
    let transport: FakeCodexAppServerTransport
    let project: AgentProject
    let threadID: SessionID
    let threadJSON: String
}

/// 先经 thread/list 建立会话上下文，再由各用例调用 connectForEvents。
private func makeThreadGoalRuntimeFixture(
    runtimeProvider: String,
    suffix: String,
    channels: [CodexAppServerChannelMetadata]
) async throws -> ThreadGoalRuntimeFixture {
    let project = AgentProject(id: "proj_goal_\(suffix)", name: "Goal Capability", path: "/tmp/goal-\(suffix)")
    let threadID = "thr_goal_\(suffix)"
    let threadJSON = appServerThreadJSON(id: threadID, cwd: project.path, source: "appServer", updatedAt: 1_781_000_000)
    let transport = FakeCodexAppServerTransport()
    let runtime = CodexAppServerSessionRuntime(
        endpoint: "http://127.0.0.1:8787",
        token: "test-token",
        runtimeProvider: runtimeProvider,
        transportFactory: { transport },
        configProvider: {
            makeDirectAppServerConfig(
                project: project,
                allowedMethods: ["initialize", "initialized", "thread/list", "thread/resume"] + threadGoalMethods,
                // 本机共享 runtime 打开空闲 Codex 历史时也会 resume，两个通道走同一条连接路径。
                transport: "local",
                channels: channels
            )
        }
    )
    let pageTask = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
    let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
    transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-runtime","platformFamily":"macos"}"#)
    let list = try await waitForFakeAppServerRequest(transport, method: "thread/list")
    transportResponse(transport, id: list.id, result: appServerThreadListResult([threadJSON], nextCursor: nil))
    _ = try await pageTask.value
    return ThreadGoalRuntimeFixture(
        runtime: runtime,
        transport: transport,
        project: project,
        threadID: threadID,
        threadJSON: threadJSON
    )
}

private func connectAnsweringResume(_ fixture: ThreadGoalRuntimeFixture) async throws {
    let connectTask = Task { try await fixture.runtime.connectForEvents(sessionID: fixture.threadID) }
    let resume = try await waitForFakeAppServerRequest(fixture.transport, method: "thread/resume")
    transportResponse(
        fixture.transport,
        id: resume.id,
        result: #"{"thread":\#(fixture.threadJSON),"cwd":"\#(fixture.project.path)"}"#
    )
    try await connectTask.value
}

private func sentThreadGoalMethods(_ transport: FakeCodexAppServerTransport) async -> [String] {
    await transport.sentMessages()
        .compactMap { try? decodeAppServerRequest($0).method }
        .filter { $0.hasPrefix("thread/goal/") }
}

@MainActor
final class ThreadGoalCapabilityTests: XCTestCase {
    func testThreadGoalSupportFollowsChannelDeclaration() {
        let project = AgentProject(id: "proj_goal_policy", name: "Goal Policy", path: "/tmp/goal-policy")
        func config(_ channels: [CodexAppServerChannelMetadata]) -> CodexAppServerConfigResponse {
            makeDirectAppServerConfig(project: project, allowedMethods: threadGoalMethods, channels: channels)
        }
        let codexWithGoals = threadGoalChannel(runtime: "codex", provider: "openai", methods: threadGoalMethods, goals: true)

        // 真实 agentd：Codex 声明 goals 与方法，Claude 都没有（#371 要求如实声明 false）。
        let current = config([codexWithGoals, undeclaredGoalClaudeChannel()])
        XCTAssertTrue(CodexAppServerSessionRuntime.supportsThreadGoals(runtimeProvider: "codex", in: current))
        XCTAssertFalse(CodexAppServerSessionRuntime.supportsThreadGoals(runtimeProvider: "claude", in: current))
        XCTAssertFalse(CodexAppServerSessionRuntime.supportsThreadGoals(runtimeProvider: "deepseek", in: current))

        // Claude 方法表缺 goal 时，顶层 Codex 方法表不能替它作数。
        XCTAssertFalse(CodexAppServerSessionRuntime.supportsThreadGoals(
            runtimeProvider: "claude",
            in: config([makeClaudeChannelMetadata()])
        ))
        // 方法齐全但显式声明 goals=false，以声明为准。
        XCTAssertFalse(CodexAppServerSessionRuntime.supportsThreadGoals(
            runtimeProvider: "claude",
            in: config([threadGoalChannel(runtime: "claude", provider: "anthropic", methods: threadGoalMethods, goals: false)])
        ))
        // 将来 Claude 通道声明支持后自动恢复，不需要改 iOS。
        XCTAssertTrue(CodexAppServerSessionRuntime.supportsThreadGoals(
            runtimeProvider: "claude",
            in: config([threadGoalChannel(runtime: "claude", provider: "anthropic", methods: threadGoalMethods, goals: true)])
        ))
        // 方法只声明了一部分，整个目标功能都不可用。
        XCTAssertFalse(CodexAppServerSessionRuntime.supportsThreadGoals(
            runtimeProvider: "codex",
            in: config([threadGoalChannel(runtime: "codex", provider: "openai", methods: ["thread/goal/get"], goals: nil)])
        ))
        // 旧 agentd 没有 channel 元数据或 methods：Codex 保持原行为，其他 Runtime 不支持。
        XCTAssertTrue(CodexAppServerSessionRuntime.supportsThreadGoals(runtimeProvider: "codex", in: config([])))
        XCTAssertTrue(CodexAppServerSessionRuntime.supportsThreadGoals(
            runtimeProvider: "codex",
            in: config([makeCodexChannelMetadata()])
        ))
        XCTAssertFalse(CodexAppServerSessionRuntime.supportsThreadGoals(runtimeProvider: "claude", in: config([])))
    }

    func testClaudeConnectSkipsUndeclaredThreadGoalRequests() async throws {
        let fixture = try await makeThreadGoalRuntimeFixture(
            runtimeProvider: "claude",
            suffix: "claude_connect",
            channels: [undeclaredGoalClaudeChannel()]
        )
        try await connectAnsweringResume(fixture)
        // 修复前 connect 返回后会在后台任务里补发 thread/goal/get；留出足够调度时间再断言。
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterConnect = await sentThreadGoalMethods(fixture.transport)
        XCTAssertEqual(afterConnect, [], "Claude 通道未声明目标能力，打开会话不能发 thread/goal/get")

        // 排队目标、旧草稿等残留路径也只能在本地失败，不能把请求打到网关。
        do {
            _ = try await fixture.runtime.threadGoal(threadID: fixture.threadID)
            XCTFail("未声明目标能力时 thread/goal/get 必须在本地拒绝")
        } catch CodexAppServerSessionRuntimeError.threadGoalsUnavailable {}
        do {
            _ = try await fixture.runtime.setThreadGoal(threadID: fixture.threadID, objective: "不应发出", status: .active)
            XCTFail("未声明目标能力时 thread/goal/set 必须在本地拒绝")
        } catch CodexAppServerSessionRuntimeError.threadGoalsUnavailable {}
        do {
            try await fixture.runtime.clearThreadGoal(threadID: fixture.threadID)
            XCTFail("未声明目标能力时 thread/goal/clear 必须在本地拒绝")
        } catch CodexAppServerSessionRuntimeError.threadGoalsUnavailable {}
        let afterDirectCalls = await sentThreadGoalMethods(fixture.transport)
        XCTAssertEqual(afterDirectCalls, [])
        await fixture.runtime.shutdownForHostSwitch()
    }

    func testCodexConnectStillFetchesDeclaredThreadGoal() async throws {
        let fixture = try await makeThreadGoalRuntimeFixture(
            runtimeProvider: "codex",
            suffix: "codex_connect",
            channels: [
                threadGoalChannel(
                    runtime: "codex",
                    provider: "openai",
                    methods: ["initialize", "initialized", "thread/list", "thread/resume"] + threadGoalMethods,
                    goals: true
                ),
                undeclaredGoalClaudeChannel()
            ]
        )
        let goalUpdated = expectation(description: "Codex 会话照常拿到目标")
        let events = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        let observer = Task {
            for await event in events {
                if case .goalUpdated(let goal, _) = event, goal.objective == "保持 Codex 目标" {
                    goalUpdated.fulfill()
                    return
                }
            }
        }
        defer { observer.cancel() }

        try await connectAnsweringResume(fixture)
        let goalGet = try await waitForFakeAppServerRequest(fixture.transport, method: "thread/goal/get")
        XCTAssertEqual(goalGet.params?.objectValue?["threadId"]?.stringValue, fixture.threadID)
        transportResponse(
            fixture.transport,
            id: goalGet.id,
            result: #"{"goal":{"threadId":"\#(fixture.threadID)","objective":"保持 Codex 目标","status":"active","tokenBudget":null,"tokensUsed":0,"timeUsedSeconds":0,"createdAt":1781000001,"updatedAt":1781000001}}"#
        )
        await fulfillment(of: [goalUpdated], timeout: 2)
        await fixture.runtime.shutdownForHostSwitch()
    }

    func testRoutingClientReportsThreadGoalSupportPerChannel() async throws {
        let project = AgentProject(id: "proj_goal_routing", name: "Goal Routing", path: "/tmp/goal-routing")
        let config = makeDirectAppServerConfig(
            project: project,
            allowedMethods: threadGoalMethods,
            channels: [
                threadGoalChannel(runtime: "codex", provider: "openai", methods: threadGoalMethods, goals: true),
                undeclaredGoalClaudeChannel()
            ]
        )
        func runtime(_ provider: String) -> CodexAppServerSessionRuntime {
            CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "test-token",
                runtimeProvider: provider,
                transportFactory: { FakeCodexAppServerTransport() },
                configProvider: { config }
            )
        }
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(
            codexRuntime: runtime("codex"),
            claudeRuntime: runtime("claude")
        )

        let codex = try await client.runtimeSupportsThreadGoals(runtimeProvider: "codex")
        let claude = try await client.runtimeSupportsThreadGoals(runtimeProvider: "claude")
        let deepseek = try await client.runtimeSupportsThreadGoals(runtimeProvider: "deepseek")
        XCTAssertTrue(codex)
        XCTAssertFalse(claude)
        XCTAssertFalse(deepseek)
    }

    func testStoreOffersGoalModeOnlyForDeclaringRuntimes() async {
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            runtimeChannelAvailability: ["codex": true, "claude": true]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        await store.refreshAppServerModelOptions()

        XCTAssertEqual(store.availableRuntimeProviders, ["codex", "claude"])
        XCTAssertEqual(store.threadGoalRuntimeProviders, ["codex"])
        XCTAssertTrue(store.supportsThreadGoals(runtimeProvider: "codex"))
        XCTAssertTrue(store.supportsThreadGoals(runtimeProvider: nil), "无 runtime 标记的旧会话按 Codex 处理")
        XCTAssertFalse(store.supportsThreadGoals(runtimeProvider: "claude"), "Claude 会话不提供目标任务")
        XCTAssertFalse(store.supportsThreadGoals(runtimeProvider: "deepseek"))
        // 规划模式不受目标能力影响。
        XCTAssertTrue(RuntimeFeatureSupport.supportsPlanning(for: "claude"))
        XCTAssertFalse(RuntimeFeatureSupport.supportsPlanning(for: "deepseek"))

        // 通道将来声明目标能力后，下一次刷新自动恢复入口。
        client.runtimeThreadGoalSupport["claude"] = true
        await store.refreshAppServerModelOptions()
        XCTAssertTrue(store.supportsThreadGoals(runtimeProvider: "claude"))
        XCTAssertFalse(
            RuntimeFeatureSupport.supportsGoals(for: "deepseek", declaredBy: ["deepseek"]),
            "Harness 不消费 goal 参数，即使声明也不开放"
        )

        // 与可用性同一口径（#777）：探测抛错只是这次没探成，沿用上一次的目标能力结论。
        client.runtimeThreadGoalSupport["claude"] = false
        client.runtimeChannelErrors = ["claude"]
        await store.refreshAppServerModelOptions()
        XCTAssertTrue(store.supportsThreadGoals(runtimeProvider: "claude"))
        // 明确探到不再声明时才撤下。
        client.runtimeChannelErrors = []
        await store.refreshAppServerModelOptions()
        XCTAssertFalse(store.supportsThreadGoals(runtimeProvider: "claude"))
    }
}
