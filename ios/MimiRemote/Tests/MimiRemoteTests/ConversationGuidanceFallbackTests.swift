import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testQueuedTurnCanGuideNowAndUncertainFailureRequiresExplicitRetry() async throws {
        let project = makeProject(id: "proj_queue_guide_now")
        let running = makeSession(
            id: "sess_queue_guide_now",
            projectID: project.id,
            title: "Queue Guide Now",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_queue_guide_now"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
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
        let acceptedGuidance = await store.sendTurn(CodexAppServerTurnPayload(prompt: "成功引导"))
        XCTAssertTrue(acceptedGuidance)
        let acceptedGuidanceID = try XCTUnwrap(store.selectedQueuedTurns.first?.id)
        let acceptedFailure = await store.sendTurn(CodexAppServerTurnPayload(prompt: "失败后重试"))
        XCTAssertTrue(acceptedFailure)
        let clientMessageID = try XCTUnwrap(store.selectedQueuedTurns.last?.id)

        XCTAssertTrue(store.guideQueuedTurnNow(clientMessageID: acceptedGuidanceID))
        socket.onTurnSendOutcome?(acceptedGuidanceID, .guidanceAccepted)
        for _ in 0..<50 where store.selectedQueuedTurns.contains(where: { $0.id == acceptedGuidanceID }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.selectedQueuedTurns.contains(where: { $0.id == acceptedGuidanceID }))
        XCTAssertFalse(store.selectedQueuedTurns.first?.waitsForAcceptedTurnStart == true)

        XCTAssertTrue(store.guideQueuedTurnNow(clientMessageID: clientMessageID))
        XCTAssertEqual(socket.sentGuidance.last?.payload.textPrompt, "失败后重试")
        XCTAssertEqual(socket.sentGuidance.first?.expectedTurnID, "turn_queue_guide_now")
        socket.onTurnSendOutcome?(clientMessageID, .uncertain(message: "ack lost"))
        for _ in 0..<50 where store.selectedQueuedTurns.first?.dispatchState != .needsConfirmation {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .needsConfirmation)
        XCTAssertTrue(store.retryQueuedTurn(clientMessageID: clientMessageID))
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .waiting)
        XCTAssertEqual(store.selectedQueuedTurns.first?.expectedTurnID, "turn_queue_guide_now")
    }

    func testQueuedGuidanceFallbackAcceptedAsNewTurnDoesNotNeedConfirmation() async throws {
        let project = makeProject(id: "proj_queue_guide_stale_active")
        let running = makeSession(
            id: "sess_queue_guide_stale_active",
            projectID: project.id,
            title: "Queue Guide Stale Active",
            status: SessionStatus.running.rawValue,
            source: "claude",
            activeTurnID: "turn_stale"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
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
        let acceptedFirstTurn = await store.sendTurn(CodexAppServerTurnPayload(prompt: "下一条普通消息"))
        XCTAssertTrue(acceptedFirstTurn)
        let clientMessageID = try XCTUnwrap(store.selectedQueuedTurns.first?.id)
        let acceptedFollowingTurn = await store.sendTurn(CodexAppServerTurnPayload(prompt: "后续仍需等待"))
        XCTAssertTrue(acceptedFollowingTurn)
        XCTAssertTrue(store.guideQueuedTurnNow(clientMessageID: clientMessageID))

        socket.onTurnSendOutcome?(clientMessageID, .accepted(turnID: "turn_fallback"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(socket.sentGuidance.count, 1)
        XCTAssertEqual(store.selectedQueuedTurns.map(\.previewText), ["后续仍需等待"])
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .waiting)
        XCTAssertFalse(store.selectedQueuedTurns.first?.waitsForAcceptedTurnStart == true)
        XCTAssertEqual(store.selectedQueuedTurns.first?.expectedTurnID, "turn_fallback")
        XCTAssertEqual(store.selectedSession?.activeTurnID, "turn_fallback")
        XCTAssertFalse(store.queuedGuidanceDispatchClientMessageIDs.contains(clientMessageID))
        XCTAssertNil(store.errorMessage)
    }

    func testQueuedGuidanceFallbackCompletedBeforeACKImmediatelyAdvancesFIFO() async throws {
        let project = makeProject(id: "proj_queue_guide_terminal_before_ack")
        let running = makeSession(
            id: "sess_queue_guide_terminal_before_ack",
            projectID: project.id,
            title: "Queue Guide Terminal Before ACK",
            status: SessionStatus.running.rawValue,
            source: "claude",
            activeTurnID: "turn_stale"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: {
                MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
            },
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
        let firstAccepted = await store.sendTurn(
            CodexAppServerTurnPayload(prompt: "fallback 第一条")
        )
        XCTAssertTrue(firstAccepted)
        let clientMessageID = try XCTUnwrap(store.selectedQueuedTurns.first?.id)
        let secondAccepted = await store.sendTurn(
            CodexAppServerTurnPayload(prompt: "fallback 后续")
        )
        XCTAssertTrue(secondAccepted)
        XCTAssertTrue(store.guideQueuedTurnNow(clientMessageID: clientMessageID))

        socket.emitEvent(.turnStarted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_fallback_fast",
            itemID: nil,
            messageID: nil,
            clientMessageID: clientMessageID,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID("turn_fallback_fast", store: store)
        socket.emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: "turn_fallback_fast",
            itemID: nil,
            messageID: nil,
            clientMessageID: clientMessageID,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID(nil, store: store)

        socket.onTurnSendOutcome?(
            clientMessageID,
            .accepted(turnID: "turn_fallback_fast")
        )

        try await waitForSentTurnCount(1, socket: socket)
        XCTAssertEqual(socket.sentTurns.first?.payload.textPrompt, "fallback 后续")
        XCTAssertNil(store.selectedSession?.activeTurnID, "迟到 ACK 不得复活已完成的 fallback turn")
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .dispatching)
        XCTAssertFalse(store.selectedQueuedTurns.first?.waitsForAcceptedTurnStart == true)
        XCTAssertFalse(store.queuedGuidanceDispatchClientMessageIDs.contains(clientMessageID))
        XCTAssertNil(store.errorMessage)
    }

    func testQueuedGuidanceFallbackConflictPreservesNewActiveTurn() async throws {
        let project = makeProject(id: "proj_queue_guide_new_active")
        let running = makeSession(
            id: "sess_queue_guide_new_active",
            projectID: project.id,
            title: "Queue Guide New Active",
            status: SessionStatus.running.rawValue,
            source: "claude",
            activeTurnID: "turn_old"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
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
        let acceptedTurn = await store.sendTurn(CodexAppServerTurnPayload(prompt: "等待新 turn 完成"))
        XCTAssertTrue(acceptedTurn)
        let clientMessageID = try XCTUnwrap(store.selectedQueuedTurns.first?.id)
        XCTAssertTrue(store.guideQueuedTurnNow(clientMessageID: clientMessageID))
        socket.onTurnSendOutcome?(
            clientMessageID,
            .activeTurnConflict(activeTurnID: "turn_new", message: "already active")
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.selectedSession?.activeTurnID, "turn_new")
        XCTAssertTrue(socket.sentTurns.isEmpty)
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .waiting)
        XCTAssertEqual(store.selectedQueuedTurns.first?.expectedTurnID, "turn_new")
        XCTAssertNil(store.selectedQueuedTurns.first?.lastError)
        XCTAssertFalse(store.queuedGuidanceDispatchClientMessageIDs.contains(clientMessageID))
    }

    func testDirectGuidanceWithStaleLocalActiveStartsExactlyOneOrdinaryTurn() async throws {
        let project = AgentProject(
            id: "proj_guidance_fallback_runtime",
            name: "Guidance Fallback",
            path: "/tmp/guidance-fallback"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, transport: "unix")
            }
        )
        let apiClient = CodexAppServerSessionAPIClient(runtime: runtime)

        let listTask = Task {
            try await apiClient.sessions(projectID: project.id, cursor: nil, limit: nil)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(
            transport,
            id: threadList.id,
            result: #"{"data":[{"id":"thr_guidance_fallback","sessionId":"thr_guidance_fallback","preview":"stale active","ephemeral":false,"createdAt":1780491000,"updatedAt":1780491001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/guidance-fallback","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"stale active","turns":[]}],"nextCursor":null}"#
        )
        _ = try await listTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var outcome: TurnSendOutcome?
        socket.onStatus = { statuses.append($0) }
        socket.onTurnSendOutcome = { _, value in outcome = value }
        socket.connect(sessionID: "thr_guidance_fallback")

        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        transportResponse(
            transport,
            id: resume.id,
            result: #"{"thread":{"id":"thr_guidance_fallback","sessionId":"thr_guidance_fallback","preview":"stale active","ephemeral":false,"createdAt":1780491000,"updatedAt":1780491002,"status":{"type":"idle"},"path":null,"cwd":"/tmp/guidance-fallback","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"stale active","turns":[]}}"#
        )
        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        XCTAssertTrue(socket.sendGuidance(
            CodexAppServerTurnPayload(prompt: "作为下一轮发送"),
            clientMessageID: "client_guidance_fallback",
            expectedTurnID: "turn_stale"
        ))
        let turnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: 4)
        let params = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(params["clientUserMessageId"]?.stringValue, "client_guidance_fallback")
        XCTAssertEqual(params["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "作为下一轮发送")
        transportResponse(
            transport,
            id: turnStart.id,
            result: #"{"turn":{"id":"turn_guidance_fallback","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780491003,"completedAt":null,"durationMs":null}}"#
        )
        for _ in 0..<200 where outcome == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(outcome, .accepted(turnID: "turn_guidance_fallback"))
        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(requests.filter { $0.method == "turn/start" }.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.method != "turn/steer" })
        socket.disconnect()
    }

    func testDirectGuidanceUncertainSteerFailureDoesNotFallbackToTurnStart() async throws {
        let project = AgentProject(
            id: "proj_guidance_uncertain_runtime",
            name: "Guidance Uncertain",
            path: "/tmp/guidance-uncertain"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let apiClient = CodexAppServerSessionAPIClient(runtime: runtime)

        let listTask = Task {
            try await apiClient.sessions(projectID: project.id, cursor: nil, limit: nil)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(
            transport,
            id: threadList.id,
            result: #"{"data":[{"id":"thr_guidance_uncertain","sessionId":"thr_guidance_uncertain","preview":"active","ephemeral":false,"createdAt":1780491000,"updatedAt":1780491001,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/guidance-uncertain","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"active","turns":[{"id":"turn_live","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780491001,"completedAt":null,"durationMs":null}]}],"nextCursor":null}"#
        )
        _ = try await listTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var outcome: TurnSendOutcome?
        socket.onStatus = { statuses.append($0) }
        socket.onTurnSendOutcome = { _, value in outcome = value }
        socket.connect(sessionID: "thr_guidance_uncertain")

        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        transportResponse(
            transport,
            id: resume.id,
            result: #"{"thread":{"id":"thr_guidance_uncertain","sessionId":"thr_guidance_uncertain","preview":"active","ephemeral":false,"createdAt":1780491000,"updatedAt":1780491002,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/guidance-uncertain","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"active","turns":[{"id":"turn_live","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780491001,"completedAt":null,"durationMs":null}]}}"#
        )
        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        XCTAssertTrue(socket.sendGuidance(
            CodexAppServerTurnPayload(prompt: "继续当前回复"),
            clientMessageID: "client_guidance_uncertain",
            expectedTurnID: "turn_live"
        ))
        let steer = try await waitForFakeAppServerRequest(transport, method: "turn/steer", after: 4)
        transportErrorResponse(
            transport,
            id: steer.id,
            code: -32603,
            message: "internal error after possible acceptance"
        )
        for _ in 0..<200 where outcome == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(
            outcome,
            .uncertain(
                message: CodexAppServerConnectionError.appServer(CodexAppServerError(
                    code: -32603,
                    message: "internal error after possible acceptance",
                    data: nil
                )).localizedDescription
            )
        )
        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(requests.filter { $0.method == "turn/steer" }.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.method != "turn/start" })
        socket.disconnect()
    }
}
