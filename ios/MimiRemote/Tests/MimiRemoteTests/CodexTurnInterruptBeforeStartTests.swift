import XCTest
@testable import MimiRemote

/// #808：Codex 在 turn/start 响应之后、turn/started 之前收到 turn/interrupt 会回
/// `no active turn to interrupt`，回合随后照常执行。这段窗口里的停止必须等回合真正开始后重发，
/// 不能被当成目标已结束而在本地合成「已停止」。
@MainActor
final class CodexTurnInterruptBeforeStartTests: XCTestCase {
    func testInterruptBeforeTurnStartedIsResentAfterTurnStarts() async throws {
        let fixture = try await makeFixture()
        try await startTurnWithoutStartedNotification(fixture)

        let task = Task {
            try await fixture.runtime.interruptActiveTurnRecoveringStaleTarget(
                sessionID: fixture.session.id, expectedTurnID: Self.turnID
            )
        }
        let early = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        let afterEarly = await fixture.transport.sentMessages().count
        transportErrorResponse(fixture.transport, id: early.id, code: -32600, message: "no active turn to interrupt")
        try await assertRuntimeKeepsTurnRunning(fixture, for: 300_000_000)

        fixture.transport.enqueue(Self.turnStartedNotification(sessionID: fixture.session.id))
        let resent = try await waitForFakeAppServerRequest(
            fixture.transport, method: "turn/interrupt", after: afterEarly
        )
        XCTAssertEqual(resent.params?["turnId"]?.stringValue, Self.turnID)
        transportResponse(fixture.transport, id: resent.id, result: "{}")
        try await task.value

        let active = await fixture.runtime.contextsBySessionID[fixture.session.id]?.activeTurnID
        XCTAssertEqual(active, Self.turnID, "停止请求被接受后，仍以上游的 turn/completed 收尾")
        let emittedCompletion = await didEmitTurnCompleted(fixture)
        XCTAssertFalse(emittedCompletion, "不能在上游确认前合成终态")
    }

    func testInterruptWhilePreviousTurnStillActiveIsResentAfterTurnStarts() async throws {
        let fixture = try await makeFixture()
        try await startTurnWithoutStartedNotification(fixture)

        let task = Task {
            try await fixture.runtime.interruptActiveTurnRecoveringStaleTarget(
                sessionID: fixture.session.id, expectedTurnID: Self.turnID
            )
        }
        let early = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        let afterEarly = await fixture.transport.sentMessages().count
        // 实测：上一轮刚被停下、还占着 active turn 时，上游这样拒绝新一轮的停止。
        transportErrorResponse(
            fixture.transport, id: early.id, code: -32600,
            message: "expected active turn id \(Self.turnID) but found turn_previous"
        )
        try await assertRuntimeKeepsTurnRunning(fixture, for: 200_000_000)

        fixture.transport.enqueue(Self.turnStartedNotification(sessionID: fixture.session.id))
        let resent = try await waitForFakeAppServerRequest(
            fixture.transport, method: "turn/interrupt", after: afterEarly
        )
        transportResponse(fixture.transport, id: resent.id, result: "{}")
        try await task.value
    }

    func testTurnFinishingDuringWaitIsNotReportedAsInterrupted() async throws {
        let fixture = try await makeFixture()
        try await startTurnWithoutStartedNotification(fixture)

        let task = Task {
            try await fixture.runtime.interruptActiveTurnRecoveringStaleTarget(
                sessionID: fixture.session.id, expectedTurnID: Self.turnID
            )
        }
        let early = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        let afterEarly = await fixture.transport.sentMessages().count
        transportErrorResponse(fixture.transport, id: early.id, code: -32600, message: "no active turn to interrupt")
        try await assertRuntimeKeepsTurnRunning(fixture, for: 200_000_000)

        fixture.transport.enqueue(Self.turnStartedNotification(sessionID: fixture.session.id))
        fixture.transport.enqueue(
            #"{"method":"turn/completed","params":{"threadId":"\#(fixture.session.id)","turn":{"id":"\#(Self.turnID)","status":"completed"}}}"#
        )
        // 回合在等待期间自行结束时可能还会重发一次；重发若收到 no active turn，
        // 也只能沿用上游给出的真实终态。
        if let resent = try? await waitForOptionalRequest(fixture, method: "turn/interrupt", after: afterEarly) {
            transportErrorResponse(fixture.transport, id: resent.id, code: -32600, message: "no active turn to interrupt")
        }
        _ = try? await task.value

        let lifecycles = await completedLifecycles(fixture)
        XCTAssertFalse(lifecycles.contains(.interrupted), "回合自然完成，不能显示为已停止：\(lifecycles)")
        XCTAssertTrue(lifecycles.contains(.completed))
    }

    func testInterruptAfterTurnStartedKeepsStaleTargetConvergence() async throws {
        let fixture = try await makeFixture()
        try await startTurnWithoutStartedNotification(fixture)
        fixture.transport.enqueue(Self.turnStartedNotification(sessionID: fixture.session.id))
        try await waitForRuntimeStartedSignal(fixture)

        let task = Task {
            try await fixture.runtime.interruptActiveTurnRecoveringStaleTarget(
                sessionID: fixture.session.id, expectedTurnID: Self.turnID
            )
        }
        let interrupt = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        transportErrorResponse(fixture.transport, id: interrupt.id, code: -32600, message: "no active turn to interrupt")
        try await task.value

        // 已经确认开始过的回合再回 no active turn，说明它已结束；沿用 gh-509 的收敛。
        let active = await fixture.runtime.contextsBySessionID[fixture.session.id]?.activeTurnID
        XCTAssertNil(active)
        let lifecycles = await completedLifecycles(fixture)
        XCTAssertEqual(lifecycles, [.interrupted])
    }

    func testStopSessionBeforeTurnStartedIsResentAfterTurnStarts() async throws {
        let fixture = try await makeFixture()
        try await startTurnWithoutStartedNotification(fixture)
        let client = CodexAppServerSessionAPIClient(runtime: fixture.runtime)

        let task = Task { try await client.stopSession(id: fixture.session.id) }
        let early = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        let afterEarly = await fixture.transport.sentMessages().count
        transportErrorResponse(fixture.transport, id: early.id, code: -32600, message: "no active turn to interrupt")
        try await assertRuntimeKeepsTurnRunning(fixture, for: 200_000_000)

        fixture.transport.enqueue(Self.turnStartedNotification(sessionID: fixture.session.id))
        let resent = try await waitForFakeAppServerRequest(
            fixture.transport, method: "turn/interrupt", after: afterEarly
        )
        transportResponse(fixture.transport, id: resent.id, result: "{}")
        try await task.value
        let status = await fixture.runtime.contextsBySessionID[fixture.session.id]?.session.status
        XCTAssertEqual(status, "closed")
    }

    func testStoreKeepsRunningUntilResentInterruptCompletes() async throws {
        let fixture = try await makeFixture()
        // 发送已经拿到 ACK：Runtime 亲自发起了这一轮，Store 显示运行中并给出停止按钮。
        try await startTurnWithoutStartedNotification(fixture)
        var running = fixture.session
        running.status = "running"
        running.activeTurnID = Self.turnID
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [fixture.project], sessions: [running], messagesResult: []
        )
        let socket = CodexAppServerSessionWebSocketClient(runtime: fixture.runtime)
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { socket }
        )
        defer {
            store.disconnectWebSocket()
            store.sessionListReconciliationTasksByProjectID.values.forEach { $0.cancel() }
            store.sessionListReconciliationTasksByProjectID.removeAll()
        }
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        try await waitForWebSocketStatus(.connected, store: store)
        try await waitForSelectedActiveTurnID(Self.turnID, store: store)

        store.interruptSelectedTurn()
        let early = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        let afterEarly = await fixture.transport.sentMessages().count
        transportErrorResponse(fixture.transport, id: early.id, code: -32600, message: "no active turn to interrupt")
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 10_000_000)
            guard store.selectedSession?.activeTurnID == Self.turnID,
                  store.selectedSession?.isRunning == true else {
                XCTFail("上游回合仍在执行，App 不能显示为已停止：\(String(describing: store.selectedSession?.status))")
                break
            }
        }

        fixture.transport.enqueue(Self.turnStartedNotification(sessionID: fixture.session.id))
        let resent = try await waitForFakeAppServerRequest(
            fixture.transport, method: "turn/interrupt", after: afterEarly
        )
        transportResponse(fixture.transport, id: resent.id, result: "{}")
        fixture.transport.enqueue(
            #"{"method":"turn/completed","params":{"threadId":"\#(fixture.session.id)","turn":{"id":"\#(Self.turnID)","status":"interrupted"}}}"#
        )
        try await waitForSelectedActiveTurnID(nil, store: store)
        XCTAssertNil(store.errorMessage)
    }

    // MARK: - Fixture

    static let turnID = "turn_before_started"

    static func turnStartedNotification(sessionID: SessionID) -> String {
        #"{"method":"turn/started","params":{"threadId":"\#(sessionID)","turn":{"id":"\#(turnID)","status":"inProgress","items":[]}}}"#
    }

    func makeFixture(
        configure: ((inout CodexTurnInterruptBeforeStartFixtureOptions) -> Void)? = nil
    ) async throws -> CodexTurnInterruptBeforeStartFixture {
        var options = CodexTurnInterruptBeforeStartFixtureOptions()
        configure?(&options)
        let project = makeProject(id: "proj_interrupt_before_start")
        let session = makeSession(
            id: "sess_interrupt_before_start", projectID: project.id, title: "Interrupt before start",
            status: "idle", source: "codex"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = options.makeRuntime(project: project, transport: transport)
        addTeardownBlock { await runtime.shutdownForHostSwitch() }
        let warmup = Task { try await runtime.prepareForHostActivation() }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport, id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        try await warmup.value
        await runtime.rememberForkedSession(session)
        return CodexTurnInterruptBeforeStartFixture(
            project: project, session: session, runtime: runtime, transport: transport
        )
    }

    /// 只回 turn/start 的 ACK，不发 turn/started：复现上游约 0.3 s 的窗口。
    func startTurnWithoutStartedNotification(_ fixture: CodexTurnInterruptBeforeStartFixture) async throws {
        let start = Task {
            try await fixture.runtime.startTurn(
                sessionID: fixture.session.id,
                payload: CodexAppServerTurnPayload(prompt: "run sleep 60"),
                clientMessageID: "client_before_started"
            )
        }
        do {
            try await answerTurnStart(fixture)
        } catch {
            start.cancel()
            let sent = await fixture.transport.sentMessages()
                .compactMap { try? decodeAppServerRequest($0).method }
            let result = await start.result
            XCTFail("startTurn 未走到 turn/start：\(result)，已发送 \(sent)")
            throw error
        }
        let turnID = try await start.value
        XCTAssertEqual(turnID, Self.turnID)
    }

    func answerTurnStart(_ fixture: CodexTurnInterruptBeforeStartFixture) async throws {
        // rememberForkedSession 已把 thread 记为在当前连接上 resume 过，直接到 turn/start。
        let start = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/start")
        transportResponse(
            fixture.transport, id: start.id,
            result: #"{"turn":{"id":"\#(Self.turnID)","status":"inProgress","items":[]}}"#
        )
    }

    func assertRuntimeKeepsTurnRunning(
        _ fixture: CodexTurnInterruptBeforeStartFixture,
        for nanoseconds: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + nanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let active = await fixture.runtime.contextsBySessionID[fixture.session.id]?.activeTurnID
            XCTAssertEqual(active, Self.turnID, "no active turn 落在 turn/started 之前，不能收敛运行态", file: file, line: line)
            if active != Self.turnID { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func waitForRuntimeStartedSignal(_ fixture: CodexTurnInterruptBeforeStartFixture) async throws {
        for _ in 0..<200 {
            let events = await fixture.runtime.bufferedEventsBySessionID[fixture.session.id] ?? []
            if events.contains(where: { if case .turnStarted = $0 { return true } else { return false } }) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("turn/started 没有投影到 runtime")
    }

    func waitForOptionalRequest(
        _ fixture: CodexTurnInterruptBeforeStartFixture,
        method: String,
        after index: Int
    ) async throws -> CodexAppServerRequest? {
        for _ in 0..<50 {
            let messages = await fixture.transport.sentMessages()
            if index < messages.count,
               let request = messages[index...].compactMap({ try? decodeAppServerRequest($0) })
                .first(where: { $0.method == method }) {
                return request
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    func didEmitTurnCompleted(_ fixture: CodexTurnInterruptBeforeStartFixture) async -> Bool {
        !(await completedLifecycles(fixture)).isEmpty
    }

    func completedLifecycles(_ fixture: CodexTurnInterruptBeforeStartFixture) async -> [ConversationTurnLifecycle] {
        // 只读缓冲区，不消费：bufferedEvents(sessionID:) 会把事件取走。
        let events = await fixture.runtime.bufferedEventsBySessionID[fixture.session.id] ?? []
        return events.compactMap { event in
            guard case .turnCompleted(let metadata) = event else { return nil }
            return metadata.turnLifecycle ?? .completed
        }
    }
}

struct CodexTurnInterruptBeforeStartFixtureOptions {
    var makeRuntime: (AgentProject, FakeCodexAppServerTransport) -> CodexAppServerSessionRuntime = { project, transport in
        CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "test-token",
            transportFactory: { transport },
            turnInterruptRecoveryDelaysNanoseconds: [],
            configProvider: {
                makeDirectAppServerConfig(project: project, allowedMethods: CodexTurnInterruptBeforeStartFixtureOptions.allowedMethods)
            }
        )
    }

    static let allowedMethods = [
        "initialize", "initialized", "thread/resume", "turn/start", "turn/interrupt"
    ]

    func makeRuntime(project: AgentProject, transport: FakeCodexAppServerTransport) -> CodexAppServerSessionRuntime {
        makeRuntime(project, transport)
    }
}

struct CodexTurnInterruptBeforeStartFixture {
    let project: AgentProject
    let session: AgentSession
    let runtime: CodexAppServerSessionRuntime
    let transport: FakeCodexAppServerTransport
}
