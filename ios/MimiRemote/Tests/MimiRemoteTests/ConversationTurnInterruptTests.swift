import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testTurnInterruptUsesExpectedTurnWhenRuntimeCacheIsMissing() async throws {
        let project = AgentProject(
            id: "proj_interrupt_expected_turn",
            name: "Interrupt Expected Turn",
            path: "/tmp/interrupt-expected-turn"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            turnInterruptRecoveryDelaysNanoseconds: [],
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "turn/interrupt"]
                )
            }
        )

        let interruptTask = Task {
            try await runtime.interruptActiveTurn(
                sessionID: "thr_interrupt_expected_turn",
                expectedTurnID: "turn_from_composer"
            )
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let interruptRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/interrupt",
            after: 1
        )
        XCTAssertEqual(
            interruptRequest.params?.objectValue?["threadId"]?.stringValue,
            "thr_interrupt_expected_turn"
        )
        XCTAssertEqual(
            interruptRequest.params?.objectValue?["turnId"]?.stringValue,
            "turn_from_composer"
        )
        transportResponse(transport, id: interruptRequest.id, result: #"{}"#)

        try await interruptTask.value
    }
}

// MARK: - gh-509 陈旧中断目标的运行态收敛

@MainActor
extension ConversationDataFlowTests {
    /// 真实 app-server 回的「thread not found」必须被判成陈旧目标，而不是普通错误。
    func testTurnInterruptNotFoundErrorIsClassifiedAsStaleTarget() async throws {
        let project = AgentProject(
            id: "proj_interrupt_stale_classification",
            name: "Interrupt Stale Classification",
            path: "/tmp/interrupt-stale-classification"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            turnInterruptRecoveryDelaysNanoseconds: [],
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "turn/interrupt"]
                )
            }
        )

        let interruptTask = Task {
            try await runtime.interruptActiveTurn(
                sessionID: "thr_interrupt_stale_classification",
                expectedTurnID: "turn_gone"
            )
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let interruptRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/interrupt",
            after: 1
        )
        transportErrorResponse(
            transport,
            id: interruptRequest.id,
            code: -32600,
            message: "thread not found"
        )

        do {
            try await interruptTask.value
            XCTFail("陈旧线程的中断命令不应该成功")
        } catch {
            XCTAssertTrue(
                ControlCommandFailure.classify(error).isStaleTarget,
                "真实 app-server 的 thread not found 必须被识别为陈旧目标"
            )
        }
    }

    /// 远端已经不存在这个 thread：中断失败后必须收敛运行态，不能停在 Processing（gh-509）。
    func testStaleInterruptThreadConvergesRunningStateAndKeepsContent() async throws {
        let harness = try await makeInterruptHarness(
            projectID: "proj_stale_interrupt_thread",
            sessionID: "sess_stale_interrupt_thread",
            activeTurnID: "turn_stale_thread"
        )
        let store = harness.store
        harness.conversationStore.appendSystem("已经完成的历史内容", sessionID: harness.session.id)

        store.interruptSelectedTurn()
        XCTAssertEqual(harness.socket.sentCtrlCTurnIDs, ["turn_stale_thread"])
        XCTAssertEqual(store.statusMessage, L10n.text("ui.stopping_current_reply"))

        let didQueue = await store.sendTurn(CodexAppServerTurnPayload(prompt: "中断后继续发送"))
        XCTAssertTrue(didQueue)

        harness.socket.emitStaleControlTarget(
            "app-server error -32600: thread not found",
            expectedTurnID: "turn_stale_thread"
        )

        try await waitForSelectedActiveTurnID(nil, store: store)
        XCTAssertNotEqual(store.selectedSession?.status, SessionStatus.running.rawValue)
        // 陈旧目标已经被本地收敛，不能再把原始协议错误抛到界面上。
        XCTAssertNil(store.errorMessage)
        // 「正在停止」必须被清掉，否则界面会一直停在停止中。这里不能断言 statusMessage 为 nil：
        // 收敛会让待发送队列按正常路径派发，派发本身会写入「排队消息已发送」这类状态文案。
        XCTAssertNotEqual(store.statusMessage, L10n.text("ui.stopping_current_reply"))
        XCTAssertTrue(
            harness.conversationStore.messages(for: harness.session.id)
                .contains { $0.content == "已经完成的历史内容" },
            "收敛运行态不能删掉对话历史"
        )

        // 待发送队列不能被静默丢弃：要么仍在等待，要么已经作为下一轮发出。
        var queueSurvived = false
        for _ in 0..<80 {
            if store.selectedQueuedTurns.isEmpty == false
                || harness.socket.sentTurns.contains(where: { $0.payload.textPrompt == "中断后继续发送" }) {
                queueSurvived = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(queueSurvived, "陈旧目标收敛后待发送队列被丢弃")
    }

    /// 远端这一轮已经结束：同样属于可判定的陈旧状态，需要收敛而不是留在运行态（gh-509）。
    func testStaleInterruptTurnConvergesAfterRemoteAlreadyEnded() async throws {
        let harness = try await makeInterruptHarness(
            projectID: "proj_stale_interrupt_turn",
            sessionID: "sess_stale_interrupt_turn",
            activeTurnID: "turn_already_finished"
        )
        let store = harness.store

        store.interruptSelectedTurn()
        harness.socket.emitStaleControlTarget(
            "app-server error -32600: turn not found",
            expectedTurnID: "turn_already_finished"
        )

        try await waitForSelectedActiveTurnID(nil, store: store)
        XCTAssertNotEqual(store.selectedSession?.status, SessionStatus.running.rawValue)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.statusMessage)
    }

    /// 中断失败是异步投递的：回调到达时活跃轮次可能已经被队列里的下一个轮次取代。
    /// 此时不能拿新轮次去合成结束，否则会把仍在远端运行的新轮次误标为中断（PR #517 评审）。
    func testStaleInterruptForSupersededTurnKeepsNewerTurnRunning() async throws {
        let harness = try await makeInterruptHarness(
            projectID: "proj_stale_interrupt_superseded",
            sessionID: "sess_stale_interrupt_superseded",
            activeTurnID: "turn_new"
        )
        let store = harness.store

        store.interruptSelectedTurn()
        XCTAssertEqual(harness.socket.sentCtrlCTurnIDs, ["turn_new"])

        // 命令当初针对的是 turn_old；失败异步到达时，本地已经前进到了 turn_new。
        harness.socket.emitStaleControlTarget(
            "app-server error -32600: turn not found",
            expectedTurnID: "turn_old"
        )

        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(
            store.selectedSession?.activeTurnID,
            "turn_new",
            "已经取代旧轮次的新轮次不能被陈旧失败收敛掉"
        )
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.running.rawValue)
        XCTAssertNil(store.errorMessage)
    }

    /// 以 thread 为目标的陈旧失败不带具体轮次：仍然收敛当前活跃轮次（gh-509）。
    func testStaleThreadLevelFailureConvergesActiveTurn() async throws {
        let harness = try await makeInterruptHarness(
            projectID: "proj_stale_thread_level",
            sessionID: "sess_stale_thread_level",
            activeTurnID: "turn_thread_level"
        )
        let store = harness.store

        harness.socket.emitStaleControlTarget("app-server error -32600: thread not found")

        try await waitForSelectedActiveTurnID(nil, store: store)
        XCTAssertNotEqual(store.selectedSession?.status, SessionStatus.running.rawValue)
        XCTAssertNil(store.errorMessage)
    }

    /// 手动结束成功：仍然走既有的 turn/completed 收敛路径，且不会留下停止提示（gh-509）。
    func testInterruptSuccessConvergesThroughTurnCompletion() async throws {
        let harness = try await makeInterruptHarness(
            projectID: "proj_interrupt_success",
            sessionID: "sess_interrupt_success",
            activeTurnID: "turn_interrupt_success"
        )
        let store = harness.store

        store.interruptSelectedTurn()
        XCTAssertEqual(harness.socket.sentCtrlCCount, 1)
        XCTAssertEqual(store.statusMessage, L10n.text("ui.stopping_current_reply"))

        harness.socket.emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: harness.session.id,
            turnID: "turn_interrupt_success",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil,
            turnLifecycle: .interrupted
        )))

        try await waitForSelectedActiveTurnID(nil, store: store)
        XCTAssertNotEqual(store.selectedSession?.status, SessionStatus.running.rawValue)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.statusMessage)
    }

    /// 三点菜单的「结束会话」在远端已经不存在该 thread 时也要收敛为已停止（gh-509）。
    func testStaleStopSessionConvergesToClosedState() async throws {
        let project = makeProject(id: "proj_stale_stop_session")
        let running = makeSession(
            id: "sess_stale_stop_session",
            projectID: project.id,
            title: "Stale Stop",
            status: "running",
            source: "codex",
            activeTurnID: "turn_stale_stop"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        client.stopSessionResult = .failure(CodexAppServerConnectionError.appServer(
            CodexAppServerError(code: -32600, message: "thread not found", data: nil)
        ))
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)

        await store.stopSelectedSession()

        XCTAssertEqual(store.selectedSession?.status, "closed")
        XCTAssertNil(store.selectedSession?.activeTurnID)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.statusMessage, L10n.text("ui.session_stopped"))
    }

    /// 只有「目标不存在或已经结束」才算陈旧；其它 -32600 仍走原有错误路径。
    func testControlCommandFailureClassifiesStaleTargetMessages() {
        XCTAssertTrue(ControlCommandFailure.isStaleTargetMessage("thread not found"))
        XCTAssertTrue(ControlCommandFailure.isStaleTargetMessage("app-server error -32600: Thread not found"))
        XCTAssertTrue(ControlCommandFailure.isStaleTargetMessage("turn not found"))
        XCTAssertTrue(ControlCommandFailure.isStaleTargetMessage("no rollout found for thread id thr_1"))
        XCTAssertTrue(ControlCommandFailure.isStaleTargetMessage("thread does not exist"))
        XCTAssertTrue(ControlCommandFailure.isStaleTargetMessage("there is no active turn to interrupt"))

        XCTAssertFalse(ControlCommandFailure.isStaleTargetMessage("thread already has an active writer"))
        XCTAssertFalse(ControlCommandFailure.isStaleTargetMessage("external_thread_active"))
        XCTAssertFalse(ControlCommandFailure.isStaleTargetMessage("request timeout"))
        XCTAssertFalse(ControlCommandFailure.isStaleTargetMessage("return value is invalid"))
        XCTAssertFalse(ControlCommandFailure.isStaleTargetMessage("approval request not found"))

        XCTAssertTrue(ControlCommandFailure.classify(CodexAppServerConnectionError.appServer(
            CodexAppServerError(code: -32600, message: "thread not found", data: nil)
        )).isStaleTarget)
        XCTAssertFalse(ControlCommandFailure.classify(CodexAppServerConnectionError.appServer(
            CodexAppServerError(code: -32600, message: "thread already has an active writer", data: nil)
        )).isStaleTarget)
        XCTAssertFalse(ControlCommandFailure.classify(CodexAppServerConnectionError.notInitialized).isStaleTarget)
    }

    private func makeInterruptHarness(
        projectID: String,
        sessionID: String,
        activeTurnID: TurnID
    ) async throws -> (
        store: SessionStore,
        socket: MockWebSocketClient,
        conversationStore: ConversationStore,
        session: AgentSession
    ) {
        let project = makeProject(id: projectID)
        let running = makeSession(
            id: sessionID,
            projectID: project.id,
            title: "Interrupt Harness",
            status: "running",
            source: "codex",
            activeTurnID: activeTurnID
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        return (store, socket, conversationStore, running)
    }
}

// MARK: - Runtime / Store stale control integration

@MainActor
extension ConversationDataFlowTests {
    func testStaleInterruptRealRuntimeDispatchesQueuedTurnAfterResume() async throws {
        let fixture = try await makeStaleControlRuntimeFixture()
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        // 列表/历史不接入 Runtime，防止后台刷新恰好修好旧缓存而掩盖故障。
        let client = MockSessionStoreClient(
            projects: [fixture.project], sessions: [fixture.session], messagesResult: []
        )
        let socket = CodexAppServerSessionWebSocketClient(runtime: fixture.runtime)
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
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
        store.takeOverSession(fixture.session)
        await store.selectSession(fixture.session)
        try await waitForWebSocketStatus(.connected, store: store)

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "next message"))
        XCTAssertTrue(queued)
        store.interruptSelectedTurn()
        let interrupt = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        XCTAssertEqual(interrupt.params?["turnId"]?.stringValue, "turn_stale")
        transportErrorResponse(fixture.transport, id: interrupt.id, code: -32600, message: "thread not found")

        // 必须到达真实 thread/resume，再到 turn/start；mock 的 sentTurns 或 UI idle 不算成功。
        let resume = try await waitForFakeAppServerRequest(fixture.transport, method: "thread/resume")
        let runtimeActiveBeforeResume = await fixture.runtime.contextsBySessionID[fixture.session.id]?.activeTurnID
        XCTAssertNil(runtimeActiveBeforeResume)
        let thread = appServerThreadJSON(
            id: fixture.session.id, cwd: fixture.project.path, source: "cli", updatedAt: 10
        )
        transportResponse(fixture.transport, id: resume.id, result: "{\"thread\":\(thread)}")
        let start = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/start")
        XCTAssertEqual(start.params?["threadId"]?.stringValue, fixture.session.id)
        XCTAssertEqual(start.params?["input"]?.arrayValue?.first?["text"]?.stringValue, "next message")
        // app-server 会通过独立的 turn/started 通知确认新轮次真正开始；RPC ACK
        // 只代表请求已接受，不能让 Store 在缺少该边界时提前清掉队列门闩。
        fixture.transport.enqueue(
            #"{"method":"turn/started","params":{"threadId":"sess_stale_runtime","turn":{"id":"turn_next","status":"inProgress"}}}"#
        )
        transportResponse(
            fixture.transport, id: start.id,
            result: #"{"turn":{"id":"turn_next","status":"inProgress","items":[]}}"#
        )
        try await waitForSelectedActiveTurnID("turn_next", store: store)
        // session 投影可能早于发送 ACK 回调；等同一条消息完成出队，避免跨 actor 时序抖动。
        for _ in 0..<200 {
            if store.selectedQueuedTurns.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(store.selectedQueuedTurns.isEmpty)
        let active = await fixture.runtime.contextsBySessionID[fixture.session.id]?.activeTurnID
        XCTAssertEqual(active, "turn_next")
    }

    func testStaleInterruptRuntimeClearsPendingReplayAndRejectsLateRequests() async throws {
        let fixture = try await makeStaleControlRuntimeFixture()
        let approval = staleControlRequest(sessionID: fixture.session.id, turnID: "turn_stale", id: 801)
        let input = staleControlRequest(
            sessionID: fixture.session.id, turnID: "turn_stale", id: 802,
            method: "item/tool/requestUserInput"
        )
        await fixture.runtime.rememberPendingApprovalRequest(approval)
        await fixture.runtime.rememberPendingUserInputRequest(input)
        let oldApprovals = await fixture.runtime.pendingApprovalRequestsByID.count
        let oldInputs = await fixture.runtime.pendingUserInputRequestsByID.count
        XCTAssertGreaterThan(oldApprovals, 0)
        XCTAssertGreaterThan(oldInputs, 0)

        let task = Task {
            try await fixture.runtime.interruptActiveTurnRecoveringStaleTarget(
                sessionID: fixture.session.id, expectedTurnID: "turn_stale"
            )
        }
        let interrupt = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        transportErrorResponse(fixture.transport, id: interrupt.id, code: -32600, message: "turn not found")
        try await task.value

        let active = await fixture.runtime.contextsBySessionID[fixture.session.id]?.activeTurnID
        let pendingApprovals = await fixture.runtime.pendingApprovalRequestsByID
        let pendingInputs = await fixture.runtime.pendingUserInputRequestsByID
        let resumed = await fixture.runtime.threadsResumedOnConnection.contains(fixture.session.id)
        XCTAssertNil(active)
        XCTAssertTrue(pendingApprovals.isEmpty)
        XCTAssertTrue(pendingInputs.isEmpty)
        XCTAssertFalse(resumed)
        await fixture.runtime.handle(approval)
        await fixture.runtime.handle(input)
        let replay = await fixture.runtime.pendingInteractionEvents(sessionID: fixture.session.id)
        XCTAssertTrue(replay.isEmpty, "迟到请求不能恢复旧审批/输入卡片")
    }

    func testStaleInterruptRuntimePreservesSupersedingTurn() async throws {
        let fixture = try await makeStaleControlRuntimeFixture()
        let task = Task {
            try await fixture.runtime.interruptActiveTurnRecoveringStaleTarget(
                sessionID: fixture.session.id, expectedTurnID: "turn_stale"
            )
        }
        let interrupt = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        var newer = fixture.session
        newer.activeTurnID = "turn_new"
        await fixture.runtime.rememberForkedSession(newer)
        let approval = staleControlRequest(sessionID: newer.id, turnID: "turn_new", id: 803)
        await fixture.runtime.rememberPendingApprovalRequest(approval)
        transportErrorResponse(fixture.transport, id: interrupt.id, code: -32600, message: "turn not found")
        do {
            try await task.value
            XCTFail("旧失败必须保留新轮次，不能让 Store 再合成旧终态")
        } catch {
            XCTAssertFalse(ControlCommandFailure.classify(error).isStaleTarget)
        }
        let active = await fixture.runtime.contextsBySessionID[newer.id]?.activeTurnID
        let pending = await fixture.runtime.pendingApprovalRequestsByID
        let resumed = await fixture.runtime.threadsResumedOnConnection.contains(newer.id)
        XCTAssertEqual(active, "turn_new")
        XCTAssertFalse(pending.isEmpty)
        XCTAssertTrue(resumed)
    }

    func testNonStaleInterruptRuntimeFailureKeepsActiveTurn() async throws {
        let fixture = try await makeStaleControlRuntimeFixture()
        let task = Task {
            try await fixture.runtime.interruptActiveTurnRecoveringStaleTarget(
                sessionID: fixture.session.id, expectedTurnID: "turn_stale"
            )
        }
        let interrupt = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        transportErrorResponse(
            fixture.transport, id: interrupt.id, code: -32600,
            message: "thread already has an active writer"
        )
        do {
            try await task.value
            XCTFail("普通失败不能当作停止成功")
        } catch {
            XCTAssertFalse(ControlCommandFailure.classify(error).isStaleTarget)
        }
        let active = await fixture.runtime.contextsBySessionID[fixture.session.id]?.activeTurnID
        let resumed = await fixture.runtime.threadsResumedOnConnection.contains(fixture.session.id)
        XCTAssertEqual(active, "turn_stale")
        XCTAssertTrue(resumed)
    }

    func testStaleStopRealAPIClientsCloseRuntimeWithoutReleasingNextTurn() async throws {
        for usesRouting in [false, true] {
            let fixture = try await makeStaleControlRuntimeFixture()
            let client: any SessionStoreAPIClient
            if usesRouting {
                client = CodexAppServerRuntimeRoutingSessionAPIClient(
                    codexRuntime: fixture.runtime, claudeRuntime: fixture.runtime
                )
            } else {
                client = CodexAppServerSessionAPIClient(runtime: fixture.runtime)
            }
            let input = staleControlRequest(
                sessionID: fixture.session.id, turnID: "turn_stale", id: 804,
                method: "item/tool/requestUserInput"
            )
            await fixture.runtime.rememberPendingUserInputRequest(input)
            let task = Task { try await client.stopSession(id: fixture.session.id) }
            let interrupt = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
            transportErrorResponse(fixture.transport, id: interrupt.id, code: -32600, message: "thread not found")
            try await task.value
            let context = await fixture.runtime.contextsBySessionID[fixture.session.id]
            let pending = await fixture.runtime.pendingUserInputRequestsByID
            let events = await fixture.runtime.bufferedEvents(sessionID: fixture.session.id, replayPolicy: .all)
            XCTAssertNil(context?.activeTurnID)
            XCTAssertEqual(context?.session.status, "closed")
            XCTAssertTrue(pending.isEmpty)
            XCTAssertFalse(events.contains { event in
                if case .turnCompleted = event { return true }
                return false
            }, "停止会话不能先发 turnCompleted 放行本地队列")
        }
    }

    func testStaleStopRealAPIClientDoesNotCloseSupersedingTurn() async throws {
        let fixture = try await makeStaleControlRuntimeFixture()
        let client = CodexAppServerSessionAPIClient(runtime: fixture.runtime)
        let task = Task { try await client.stopSession(id: fixture.session.id) }
        let interrupt = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        var newer = fixture.session
        newer.activeTurnID = "turn_new"
        await fixture.runtime.rememberForkedSession(newer)
        transportErrorResponse(fixture.transport, id: interrupt.id, code: -32600, message: "turn not found")
        do {
            try await task.value
            XCTFail("旧停止请求不能关闭新轮次")
        } catch {
            XCTAssertFalse(ControlCommandFailure.classify(error).isStaleTarget)
        }
        let context = await fixture.runtime.contextsBySessionID[newer.id]
        XCTAssertEqual(context?.activeTurnID, "turn_new")
        XCTAssertNotEqual(context?.session.status, "closed")
    }

    private func makeStaleControlRuntimeFixture() async throws -> StaleControlRuntimeFixture {
        let project = makeProject(id: "proj_stale_runtime")
        let session = makeSession(
            id: "sess_stale_runtime", projectID: project.id, title: "Stale runtime",
            status: "running", source: "codex", activeTurnID: "turn_stale"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "test-token",
            transportFactory: { transport },
            turnInterruptRecoveryDelaysNanoseconds: [],
            configProvider: {
                makeDirectAppServerConfig(project: project, allowedMethods: [
                    "initialize", "initialized", "thread/resume", "turn/start", "turn/interrupt"
                ])
            }
        )
        addTeardownBlock { await runtime.shutdownForHostSwitch() }
        let warmup = Task { try await runtime.prepareForHostActivation() }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport, id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        try await warmup.value
        // 保留真实 start/resume 后的 Runtime 缓存和绑定，不能只在 Store 里伪造 active turn。
        await runtime.rememberForkedSession(session)
        return StaleControlRuntimeFixture(project: project, session: session, runtime: runtime, transport: transport)
    }

    private func staleControlRequest(
        sessionID: SessionID,
        turnID: TurnID,
        id: Int64,
        method: String = "item/commandExecution/requestApproval"
    ) -> CodexAppServerServerRequest {
        CodexAppServerServerRequest(id: .int(id), method: method, params: .object([
            "threadId": .string(sessionID),
            "turnId": .string(turnID),
            "itemId": .string("item_\(id)"),
            "command": .string("echo test"),
            "questions": .array([])
        ]))
    }
}

private struct StaleControlRuntimeFixture {
    let project: AgentProject
    let session: AgentSession
    let runtime: CodexAppServerSessionRuntime
    let transport: FakeCodexAppServerTransport
}
