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
