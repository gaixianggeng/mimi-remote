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

    func testPermissionBoundaryRequiresExactTurnStartedClientMessageID() async throws {
        let project = makeProject(id: "proj_permission_boundary_exact")
        let running = makeSession(
            id: "sess_permission_boundary_exact",
            projectID: project.id,
            title: "Permission Boundary Exact",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_permission_old"
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

        var composerState = ComposerState()
        composerState.applyPermissionMode(.readOnly, sessionIsRunning: true)
        let permissionSelection = composerState.permissionSelectionSnapshot()
        XCTAssertTrue(permissionSelection.requiresNewTurn)

        let queued = await store.sendTurn(
            CodexAppServerTurnPayload(prompt: "权限边界必须等待新轮次"),
            permissionSelection: permissionSelection
        )
        XCTAssertTrue(queued)
        let clientMessageID = try XCTUnwrap(store.selectedQueuedTurns.first?.clientMessageID)
        XCTAssertEqual(store.selectedQueuedTurns.first?.requiresFreshTurn, true)
        XCTAssertEqual(
            store.pendingPermissionTurnBoundary(for: running.id)?.clientMessageID,
            clientMessageID
        )
        XCTAssertFalse(store.guideQueuedTurnNow(clientMessageID: clientMessageID))

        composerState.applyPermissionMode(.fullAccess, sessionIsRunning: true)
        let secondQueued = await store.sendTurn(
            CodexAppServerTurnPayload(prompt: "第二条权限边界"),
            permissionSelection: composerState.permissionSelectionSnapshot()
        )
        XCTAssertTrue(secondQueued)
        let secondClientMessageID = try XCTUnwrap(store.selectedQueuedTurns.last?.clientMessageID)
        XCTAssertTrue(store.moveSelectedQueuedTurns(fromOffsets: IndexSet(integer: 1), toOffset: 0))
        XCTAssertEqual(
            store.pendingPermissionTurnBoundary(for: running.id)?.clientMessageID,
            secondClientMessageID,
            "拖动队列时必须同步权限边界顺序"
        )

        socket.emitEvent(.turnStarted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_permission_wrong",
            itemID: nil,
            messageID: nil,
            clientMessageID: "client-wrong",
            revision: nil,
            createdAt: nil
        )))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(store.pendingPermissionTurnBoundary(for: running.id))

        socket.emitEvent(.turnStarted(AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: "turn_permission_nil",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(store.pendingPermissionTurnBoundary(for: running.id))

        socket.emitEvent(.turnStarted(AgentEventMetadata(
            seq: 3,
            sessionID: running.id,
            turnID: "turn_permission_second",
            itemID: nil,
            messageID: nil,
            clientMessageID: secondClientMessageID,
            revision: nil,
            createdAt: nil
        )))
        for _ in 0..<50 where store.pendingPermissionTurnBoundary(for: running.id)?.clientMessageID != clientMessageID {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.pendingPermissionTurnBoundary(for: running.id)?.clientMessageID, clientMessageID)

        socket.emitEvent(.turnStarted(AgentEventMetadata(
            seq: 4,
            sessionID: running.id,
            turnID: "turn_permission_first",
            itemID: nil,
            messageID: nil,
            clientMessageID: clientMessageID,
            revision: nil,
            createdAt: nil
        )))
        for _ in 0..<50 where store.pendingPermissionTurnBoundary(for: running.id) != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(store.pendingPermissionTurnBoundary(for: running.id))
        XCTAssertEqual(store.latestSatisfiedPermissionTurnBoundary?.clientMessageID, clientMessageID)
    }

    func testPermissionBoundaryPersistsAndClearsTheNonCurrentComposerCache() throws {
        let sessionID = "sess_permission_boundary_cache"
        var state = ComposerState()
        state.applyPermissionMode(.readOnly, sessionIsRunning: true)
        let selection = state.permissionSelectionSnapshot()
        let boundary = PendingPermissionTurnBoundary(
            sessionID: sessionID,
            clientMessageID: "client_permission_boundary",
            permissionSelection: selection
        )
        let entry = QueuedTurnEntry(
            sessionID: sessionID,
            payload: CodexAppServerTurnPayload(prompt: "待新轮次"),
            clientMessageID: boundary.clientMessageID,
            intent: .standard,
            requiresFreshTurn: true
        )
        let snapshot = QueuedTurnProfileSnapshot(
            profileID: "profile-boundary",
            queuesBySessionID: [sessionID: [entry]],
            pendingPermissionTurnBoundariesBySessionID: [sessionID: [boundary]]
        )
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(QueuedTurnProfileSnapshot.self, from: data)
        XCTAssertEqual(restored.pendingPermissionTurnBoundariesBySessionID[sessionID], [boundary])
        XCTAssertEqual(restored.queuesBySessionID[sessionID]?.first?.requiresFreshTurn, true)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionBoundaryCacheTests.\(UUID().uuidString)", isDirectory: true)
        let queuedTurnStore = FileQueuedTurnStore(directoryURL: directory)
        try queuedTurnStore.save(snapshot)
        let diskRestored = try queuedTurnStore.load(profileID: snapshot.profileID)
        XCTAssertEqual(diskRestored.pendingPermissionTurnBoundariesBySessionID[sessionID], [boundary])

        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyJSON.removeValue(forKey: "pendingPermissionTurnBoundariesBySessionID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacy = try JSONDecoder().decode(QueuedTurnProfileSnapshot.self, from: legacyData)
        XCTAssertTrue(legacy.pendingPermissionTurnBoundariesBySessionID.isEmpty)

        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: FileQueuedTurnStore(directoryURL: directory)
        )
        store.saveComposerPermissionSelection(selection, for: .session(sessionID))
        store.pendingPermissionTurnBoundariesBySessionID = [sessionID: [boundary]]
        XCTAssertTrue(store.satisfyPendingPermissionTurnBoundary(
            sessionID: sessionID,
            clientMessageID: boundary.clientMessageID
        ))
        XCTAssertFalse(
            store.composerPermissionSelection(for: .session(sessionID))?.requiresNewTurn == true,
            "非当前会话的权限 cache 也必须在精确 started 后清除边界"
        )

        var newerState = ComposerState()
        newerState.applyPermissionMode(.fullAccess, sessionIsRunning: true)
        let newerSelection = newerState.permissionSelectionSnapshot()
        let newerBoundary = PendingPermissionTurnBoundary(
            sessionID: sessionID,
            clientMessageID: "client_permission_boundary_newer",
            permissionSelection: selection
        )
        store.saveComposerPermissionSelection(newerSelection, for: .session(sessionID))
        store.pendingPermissionTurnBoundariesBySessionID = [sessionID: [newerBoundary]]
        XCTAssertTrue(store.satisfyPendingPermissionTurnBoundary(
            sessionID: sessionID,
            clientMessageID: newerBoundary.clientMessageID
        ))
        XCTAssertEqual(
            store.composerPermissionSelection(for: .session(sessionID)),
            newerSelection,
            "旧边界的 started 不能清除切换会话期间保存的较新权限选择"
        )
    }

    func testComposerAutomaticPermissionChangesRequireFreshTurnWhileRunning() {
        var state = ComposerState()
        state.applyPermissionMode(.readOnly, sessionIsRunning: true)
        XCTAssertTrue(state.permissionSelectionRequiresNewTurn)

        state.preserveThreadPermissionSettings()
        XCTAssertFalse(state.permissionSelectionRequiresNewTurn)

        state.updatePermissionSelection(sessionIsRunning: true) { options in
            options.permissionProfileID = "missing-profile"
            options.preservesThreadPermissionSettings = false
        }
        XCTAssertTrue(state.permissionSelectionRequiresNewTurn)
        state.resetUnavailablePermissionProfile(sessionIsRunning: true)
        XCTAssertTrue(state.permissionSelectionRequiresNewTurn)
        XCTAssertEqual(state.permissionMode, .requestApproval)
    }

    func testConsecutivePermissionBoundariesAdvanceInSubmissionOrder() throws {
        let sessionID = "sess_consecutive_permission_boundaries"
        var readOnlyState = ComposerState()
        readOnlyState.applyPermissionMode(.readOnly, sessionIsRunning: true)
        let readOnly = readOnlyState.permissionSelectionSnapshot()
        var fullAccessState = ComposerState()
        fullAccessState.applyPermissionMode(.fullAccess, sessionIsRunning: true)
        let fullAccess = fullAccessState.permissionSelectionSnapshot()
        let boundaries = [
            PendingPermissionTurnBoundary(
                sessionID: sessionID,
                clientMessageID: "client_permission_a",
                permissionSelection: readOnly
            ),
            PendingPermissionTurnBoundary(
                sessionID: sessionID,
                clientMessageID: "client_permission_b",
                permissionSelection: fullAccess
            ),
            PendingPermissionTurnBoundary(
                sessionID: sessionID,
                clientMessageID: "client_permission_a_again",
                permissionSelection: readOnly
            )
        ]
        let entries = boundaries.map {
            QueuedTurnEntry(
                sessionID: sessionID,
                payload: CodexAppServerTurnPayload(prompt: $0.clientMessageID),
                clientMessageID: $0.clientMessageID,
                intent: .standard,
                requiresFreshTurn: true
            )
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConsecutivePermissionBoundaryTests.\(UUID().uuidString)", isDirectory: true)
        let queuedTurnStore = FileQueuedTurnStore(directoryURL: directory)
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore
        )
        store.saveComposerPermissionSelection(readOnly, for: .session(sessionID))
        XCTAssertTrue(store.mutateAndPersistQueuedTurns {
            store.queuedRunningTurnsBySessionID[sessionID] = entries
            store.pendingPermissionTurnBoundariesBySessionID[sessionID] = boundaries
        })
        XCTAssertEqual(
            try queuedTurnStore.load(profileID: appStore.notificationRoutingProfileID)
                .pendingPermissionTurnBoundariesBySessionID[sessionID],
            boundaries
        )
        XCTAssertEqual(
            store.latestPendingPermissionTurnBoundary(for: sessionID),
            boundaries.last,
            "Composer 重建时必须恢复最后一次提交的权限，不能回退到 FIFO 第一条"
        )

        XCTAssertTrue(store.satisfyPendingPermissionTurnBoundary(
            sessionID: sessionID,
            clientMessageID: boundaries[0].clientMessageID
        ))
        XCTAssertEqual(store.pendingPermissionTurnBoundary(for: sessionID), boundaries[1])
        XCTAssertTrue(store.composerPermissionSelection(for: .session(sessionID))?.requiresNewTurn == true)
        XCTAssertNil(store.latestSatisfiedPermissionTurnBoundary)

        XCTAssertTrue(store.satisfyPendingPermissionTurnBoundary(
            sessionID: sessionID,
            clientMessageID: boundaries[1].clientMessageID
        ))
        XCTAssertEqual(store.pendingPermissionTurnBoundary(for: sessionID), boundaries[2])
        XCTAssertTrue(store.composerPermissionSelection(for: .session(sessionID))?.requiresNewTurn == true)

        XCTAssertTrue(store.satisfyPendingPermissionTurnBoundary(
            sessionID: sessionID,
            clientMessageID: boundaries[2].clientMessageID
        ))
        XCTAssertNil(store.pendingPermissionTurnBoundary(for: sessionID))
        XCTAssertFalse(store.composerPermissionSelection(for: .session(sessionID))?.requiresNewTurn == true)
        XCTAssertEqual(store.latestSatisfiedPermissionTurnBoundary, boundaries[2])
    }

    func testDeletingUncertainPermissionTurnPreservesBoundary() {
        let sessionID = "sess_uncertain_permission_delete"
        var state = ComposerState()
        state.applyPermissionMode(.readOnly, sessionIsRunning: true)
        let boundary = PendingPermissionTurnBoundary(
            sessionID: sessionID,
            clientMessageID: "client_uncertain_permission_delete",
            permissionSelection: state.permissionSelectionSnapshot()
        )
        let entry = QueuedTurnEntry(
            sessionID: sessionID,
            payload: CodexAppServerTurnPayload(prompt: "结果不确定"),
            clientMessageID: boundary.clientMessageID,
            intent: .standard,
            dispatchState: .needsConfirmation,
            requiresFreshTurn: true
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncertainPermissionDeleteTests.\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: FileQueuedTurnStore(directoryURL: directory)
        )
        XCTAssertTrue(store.mutateAndPersistQueuedTurns {
            store.queuedRunningTurnsBySessionID[sessionID] = [entry]
            store.pendingPermissionTurnBoundariesBySessionID[sessionID] = [boundary]
        })

        XCTAssertTrue(store.deleteQueuedTurn(clientMessageID: boundary.clientMessageID))
        XCTAssertTrue(store.queuedTurns(sessionID: sessionID).isEmpty)
        XCTAssertEqual(store.pendingPermissionTurnBoundary(for: sessionID), boundary)
    }

    func testFailedPermissionTurnRetryCannotGuideTheOldTurn() async throws {
        let project = makeProject(id: "proj_permission_retry_boundary")
        let running = makeSession(
            id: "sess_permission_retry_boundary",
            projectID: project.id,
            title: "Permission Retry Boundary",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_permission_retry_old"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionRetryRestartTests.\(UUID().uuidString)", isDirectory: true)
        let queuedTurnStore = FileQueuedTurnStore(directoryURL: directory)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
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

        var state = ComposerState()
        state.applyPermissionMode(.readOnly, sessionIsRunning: true)
        let selection = state.permissionSelectionSnapshot()
        let payload = CodexAppServerTurnPayload(
            prompt: "重试仍要开启新轮次",
            options: state.turnOptions
        )
        let clientMessageID = "client_permission_retry"
        let boundary = PendingPermissionTurnBoundary(
            sessionID: running.id,
            clientMessageID: clientMessageID,
            permissionSelection: selection
        )
        let queued = QueuedTurnEntry(
            sessionID: running.id,
            projectID: running.projectID,
            payload: payload,
            clientMessageID: clientMessageID,
            intent: .standard,
            dispatchState: .dispatching,
            expectedTurnID: running.activeTurnID,
            requiresFreshTurn: true
        )
        conversationStore.appendLocalUser(
            payload.previewText,
            sessionID: running.id,
            clientMessageID: clientMessageID,
            sendStatus: .local,
            turnPayload: payload
        )
        XCTAssertTrue(store.mutateAndPersistQueuedTurns {
            store.queuedRunningTurnsBySessionID[running.id] = [queued]
            store.pendingPermissionTurnBoundariesBySessionID[running.id] = [boundary]
        })
        XCTAssertTrue(store.handleQueuedSendRejected(
            clientMessageID: clientMessageID,
            sessionID: running.id,
            message: "definite rejection"
        ))
        XCTAssertEqual(
            store.permissionTurnRetryRequirementsByClientMessageID[clientMessageID],
            boundary
        )

        // 新建 SessionStore 模拟 App 重启：Composer cache 为空，只能依赖落盘的 retry requirement。
        var restartedSockets: [MockWebSocketClient] = []
        let restartedStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: {
                MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
            },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                restartedSockets.append(socket)
                return socket
            }
        )
        XCTAssertNil(restartedStore.composerPermissionSelection(for: .session(running.id)))
        XCTAssertEqual(
            restartedStore.permissionTurnRetryRequirementsByClientMessageID[clientMessageID],
            boundary
        )
        await restartedStore.refreshAll(autoAttach: false)
        restartedStore.takeOverSession(running)
        await restartedStore.selectSession(running)
        let restartedSocket = try XCTUnwrap(restartedSockets.first)
        restartedSocket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: restartedStore)
        let failed = try XCTUnwrap(
            conversationStore.messages(for: running.id).first(where: { $0.clientMessageID == clientMessageID })
        )

        let retried = await restartedStore.retryFailedUserMessage(failed)
        XCTAssertTrue(retried)
        XCTAssertEqual(restartedStore.selectedQueuedTurns.first?.requiresFreshTurn, true)
        XCTAssertEqual(
            restartedStore.pendingPermissionTurnBoundary(for: running.id)?.clientMessageID,
            clientMessageID
        )
        XCTAssertNil(restartedStore.permissionTurnRetryRequirementsByClientMessageID[clientMessageID])
        XCTAssertFalse(restartedStore.guideQueuedTurnNow(clientMessageID: clientMessageID))
        XCTAssertTrue(restartedSocket.sentGuidance.isEmpty)
    }

    func testCompletedSessionPermissionRetryWaitsForExactStartedAcrossRestart() async throws {
        let project = makeProject(id: "proj_completed_permission_retry")
        let completed = makeSession(
            id: "sess_completed_permission_retry",
            projectID: project.id,
            title: "Completed Permission Retry",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        let resumed = makeSession(
            id: completed.id,
            projectID: project.id,
            title: completed.title,
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_completed_permission_retry"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletedPermissionRetryTests.\(UUID().uuidString)", isDirectory: true)
        let queuedTurnStore = FileQueuedTurnStore(directoryURL: directory)
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [completed],
            createSessionResponse: try makeCreateSessionResponse(session: resumed),
            messagesResult: []
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        await store.refreshAll(autoAttach: false)
        await store.selectSession(completed)

        var state = ComposerState()
        state.applyPermissionMode(.fullAccess, sessionIsRunning: true)
        let clientMessageID = "client_completed_permission_retry"
        let requirement = PendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: clientMessageID,
            permissionSelection: state.permissionSelectionSnapshot()
        )
        let payload = CodexAppServerTurnPayload(
            prompt: "完成态重试也要等 started",
            options: state.turnOptions
        )
        conversationStore.appendLocalUser(
            payload.previewText,
            sessionID: completed.id,
            clientMessageID: clientMessageID,
            sendStatus: .failed,
            turnPayload: payload
        )
        XCTAssertTrue(store.mutateAndPersistQueuedTurns {
            store.permissionTurnRetryRequirementsByClientMessageID[clientMessageID] = requirement
        })
        let failed = try XCTUnwrap(conversationStore.messages(for: completed.id).first)

        let didRetry = await store.retryFailedUserMessage(failed)
        XCTAssertTrue(didRetry)
        XCTAssertEqual(client.createPayloads.first?.clientMessageID, clientMessageID)
        XCTAssertEqual(
            store.pendingPermissionTurnBoundary(for: completed.id)?.clientMessageID,
            clientMessageID
        )
        XCTAssertNil(store.permissionTurnRetryRequirementsByClientMessageID[clientMessageID])

        // 模拟 create/resume 成功后、实时 started 落地前崩溃。错误 ID 或空 turnID
        // 都不能让新 Store 在权威历史恢复时提前解除边界。
        let incompleteHistoryClient = MockSessionStoreClient(
            projects: [project],
            sessions: [completed],
            messagesResult: [
                CodexHistoryMessage(
                    role: "user",
                    content: "错误消息",
                    createdAt: Date(timeIntervalSince1970: 1),
                    clientMessageID: "client_completed_permission_wrong",
                    turnID: "turn_completed_permission_wrong"
                ),
                CodexHistoryMessage(
                    role: "user",
                    content: payload.previewText,
                    createdAt: Date(timeIntervalSince1970: 2),
                    clientMessageID: clientMessageID,
                    turnID: ""
                )
            ]
        )
        let restartedStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { incompleteHistoryClient }
        )
        await restartedStore.selectSession(completed)
        XCTAssertEqual(
            restartedStore.pendingPermissionTurnBoundary(for: completed.id)?.clientMessageID,
            clientMessageID
        )

        // 已错过实时事件时，公开会话恢复路径必须用同一 clientMessageID 的非空 turnID 收敛。
        let startedHistoryClient = MockSessionStoreClient(
            projects: [project],
            sessions: [completed],
            messagesResult: [
                CodexHistoryMessage(
                    role: "user",
                    content: payload.previewText,
                    createdAt: Date(timeIntervalSince1970: 3),
                    clientMessageID: clientMessageID,
                    turnID: "turn_completed_permission_retry"
                )
            ]
        )
        let recoveredStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { startedHistoryClient }
        )
        await recoveredStore.selectSession(completed)
        XCTAssertNil(recoveredStore.pendingPermissionTurnBoundary(for: completed.id))
    }

    func testPermissionBoundarySurvivesCreateResumeRaceForMessageAndGoal() async throws {
        let project = makeProject(id: "proj_permission_create_resume_race")
        let completed = makeSession(
            id: "sess_permission_create_resume_race",
            projectID: project.id,
            title: "Permission Create Resume Race",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        let resumed = makeSession(
            id: completed.id,
            projectID: project.id,
            title: completed.title,
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_permission_create_resume_race"
        )
        var state = ComposerState()
        state.applyPermissionMode(.readOnly, sessionIsRunning: true)
        let permissionSelection = state.permissionSelectionSnapshot()
        XCTAssertTrue(permissionSelection.requiresNewTurn)

        let messageAppStore = makeIsolatedAppStore()
        messageAppStore.token = "test-token"
        let messageClient = MockSessionStoreClient(
            projects: [project],
            sessions: [completed],
            createSessionResponse: try makeCreateSessionResponse(session: resumed),
            messagesResult: []
        )
        let messageStore = SessionStore(
            appStore: messageAppStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { messageClient }
        )
        await messageStore.refreshAll(autoAttach: false)
        await messageStore.selectSession(completed)

        let messageSent = await messageStore.sendTurn(
            CodexAppServerTurnPayload(prompt: "完成竞态后的普通消息"),
            permissionSelection: permissionSelection
        )
        XCTAssertTrue(messageSent)
        let messageClientID = try XCTUnwrap(messageClient.createPayloads.last?.clientMessageID)
        XCTAssertEqual(
            messageStore.pendingPermissionTurnBoundary(for: completed.id)?.clientMessageID,
            messageClientID
        )
        XCTAssertTrue(messageStore.satisfyPendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: messageClientID
        ))

        let goalAppStore = makeIsolatedAppStore()
        goalAppStore.token = "test-token"
        let goalClient = MockSessionStoreClient(
            projects: [project],
            sessions: [completed],
            createSessionResponse: try makeCreateSessionResponse(session: resumed),
            messagesResult: []
        )
        let goalStore = SessionStore(
            appStore: goalAppStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { goalClient }
        )
        await goalStore.refreshAll(autoAttach: false)
        await goalStore.selectSession(completed)

        let goalSent = await goalStore.startGoalTurn(
            payload: CodexAppServerTurnPayload(prompt: "完成竞态后的目标消息"),
            objective: "完成目标",
            tokenBudget: nil,
            permissionSelection: permissionSelection
        )
        XCTAssertTrue(goalSent)
        let goalClientID = try XCTUnwrap(goalClient.createPayloads.last?.clientMessageID)
        XCTAssertEqual(goalClient.createPayloads.last?.initialGoalObjective, "完成目标")
        XCTAssertEqual(
            goalStore.pendingPermissionTurnBoundary(for: completed.id)?.clientMessageID,
            goalClientID
        )
        XCTAssertTrue(goalStore.satisfyPendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: goalClientID
        ))

        let failureAppStore = makeIsolatedAppStore()
        failureAppStore.token = "test-token"
        let failureClient = MockSessionStoreClient(
            projects: [project],
            sessions: [completed],
            createSessionResults: [.failure(NSError(
                domain: "PermissionCreateResumeRace",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "create failed"]
            ))],
            messagesResult: []
        )
        let failureStore = SessionStore(
            appStore: failureAppStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { failureClient }
        )
        await failureStore.refreshAll(autoAttach: false)
        await failureStore.selectSession(completed)

        let failureSent = await failureStore.sendTurn(
            CodexAppServerTurnPayload(prompt: "失败时回滚权限边界"),
            permissionSelection: permissionSelection
        )
        XCTAssertFalse(failureSent)
        let failedClientID = try XCTUnwrap(failureClient.createPayloads.last?.clientMessageID)
        XCTAssertNil(failureStore.pendingPermissionTurnBoundaryLocation(clientMessageID: failedClientID))
    }

    func testRestartedOrphanPermissionBoundaryBlocksMessageAndGoalFIFO() async throws {
        let project = makeProject(id: "proj_orphan_permission_fifo")
        let completed = makeSession(
            id: "sess_orphan_permission_fifo",
            projectID: project.id,
            title: "Orphan Permission FIFO",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrphanPermissionFIFOTests.\(UUID().uuidString)", isDirectory: true)
        let queuedTurnStore = FileQueuedTurnStore(directoryURL: directory)
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [completed],
            messagesResult: []
        )
        var permissionState = ComposerState()
        permissionState.applyPermissionMode(.readOnly, sessionIsRunning: true)
        let permissionSelection = permissionState.permissionSelectionSnapshot()
        let orphanPermissionSelection = ComposerState().permissionSelectionSnapshot()
        let orphanClientMessageID = "client_orphan_permission_a"
        let orphanBoundary = PendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: orphanClientMessageID,
            permissionSelection: orphanPermissionSelection
        )
        let seedStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { client }
        )
        XCTAssertTrue(seedStore.mutateAndPersistQueuedTurns {
            seedStore.pendingPermissionTurnBoundariesBySessionID[completed.id] = [orphanBoundary]
        })

        var sockets: [MockWebSocketClient] = []
        let restartedStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        await restartedStore.refreshAll(autoAttach: false)
        restartedStore.takeOverSession(completed)
        await restartedStore.selectSession(completed)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: restartedStore)

        let messageQueued = await restartedStore.sendTurn(
            CodexAppServerTurnPayload(prompt: "排在孤立边界后的普通消息"),
            permissionSelection: permissionSelection
        )
        XCTAssertTrue(messageQueued)
        let messageClientID = try XCTUnwrap(restartedStore.selectedQueuedTurns.first?.clientMessageID)
        let goalQueued = await restartedStore.startGoalTurn(
            payload: CodexAppServerTurnPayload(prompt: "排在普通消息后的目标"),
            objective: "保持 FIFO",
            permissionSelection: permissionSelection
        )
        XCTAssertTrue(goalQueued)
        let goalClientID = try XCTUnwrap(restartedStore.selectedQueuedTurns.last?.clientMessageID)

        XCTAssertTrue(client.createPayloads.isEmpty)
        XCTAssertTrue(socket.sentTurns.isEmpty)
        XCTAssertEqual(
            restartedStore.pendingPermissionTurnBoundariesBySessionID[completed.id]?.map(\.clientMessageID),
            [orphanClientMessageID, messageClientID, goalClientID]
        )

        restartedStore.applyHistoryFirstPage(
            HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    role: "user",
                    content: "权限 A 已开始",
                    createdAt: Date(timeIntervalSince1970: 1),
                    clientMessageID: orphanClientMessageID,
                    turnID: "turn_orphan_permission_a"
                )
            ]),
            sessionID: completed.id
        )

        XCTAssertEqual(socket.sentTurns.count, 1)
        XCTAssertEqual(socket.sentTurns.first?.clientMessageID, messageClientID)
        XCTAssertEqual(
            restartedStore.pendingPermissionTurnBoundary(for: completed.id)?.clientMessageID,
            messageClientID
        )
        XCTAssertEqual(restartedStore.selectedQueuedTurns.last?.clientMessageID, goalClientID)
    }

    func testCompletedSessionPermissionRetryStaysBehindExistingQueueBoundary() async throws {
        let project = makeProject(id: "proj_completed_permission_retry_fifo")
        let completed = makeSession(
            id: "sess_completed_permission_retry_fifo",
            projectID: project.id,
            title: "Completed Permission Retry FIFO",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        let client = MockSessionStoreClient(projects: [project], sessions: [completed], messagesResult: [])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(completed)
        await store.selectSession(completed)

        var waitingState = ComposerState()
        waitingState.applyPermissionMode(.readOnly, sessionIsRunning: true)
        let waitingBoundary = PendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: "client_waiting_permission_b",
            permissionSelection: waitingState.permissionSelectionSnapshot()
        )
        let waitingEntry = QueuedTurnEntry(
            sessionID: completed.id,
            projectID: project.id,
            payload: CodexAppServerTurnPayload(prompt: "先发送 B"),
            clientMessageID: waitingBoundary.clientMessageID,
            intent: .standard,
            requiresFreshTurn: true
        )
        var retryState = ComposerState()
        retryState.applyPermissionMode(.fullAccess, sessionIsRunning: true)
        let retryClientMessageID = "client_rejected_permission_a"
        let retryRequirement = PendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: retryClientMessageID,
            permissionSelection: retryState.permissionSelectionSnapshot()
        )
        let retryPayload = CodexAppServerTurnPayload(
            prompt: "B 之后再重试 A",
            options: retryState.turnOptions
        )
        conversationStore.appendLocalUser(
            retryPayload.previewText,
            sessionID: completed.id,
            clientMessageID: retryClientMessageID,
            sendStatus: .failed,
            turnPayload: retryPayload
        )
        XCTAssertTrue(store.mutateAndPersistQueuedTurns {
            store.queuedRunningTurnsBySessionID[completed.id] = [waitingEntry]
            store.pendingPermissionTurnBoundariesBySessionID[completed.id] = [waitingBoundary]
            store.permissionTurnRetryRequirementsByClientMessageID[retryClientMessageID] = retryRequirement
        })
        let failed = try XCTUnwrap(
            conversationStore.messages(for: completed.id).first(where: { $0.clientMessageID == retryClientMessageID })
        )

        let didRetry = await store.retryFailedUserMessage(failed)
        XCTAssertTrue(didRetry)
        XCTAssertTrue(client.createPayloads.isEmpty, "已有本地 FIFO 时不得绕过队列直接 create/resume")
        XCTAssertEqual(
            store.queuedTurns(sessionID: completed.id).map(\.clientMessageID),
            [waitingBoundary.clientMessageID, retryClientMessageID]
        )
        XCTAssertEqual(
            store.pendingPermissionTurnBoundariesBySessionID[completed.id]?.map(\.clientMessageID),
            [waitingBoundary.clientMessageID, retryClientMessageID]
        )
    }

    func testCompletedSessionPermissionRetryQueuesBehindOrphanBoundary() async throws {
        let project = makeProject(id: "proj_permission_retry_orphan_fifo")
        let completed = makeSession(
            id: "sess_permission_retry_orphan_fifo",
            projectID: project.id,
            title: "Permission Retry Orphan FIFO",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        let client = MockSessionStoreClient(projects: [project], sessions: [completed], messagesResult: [])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(completed)
        await store.selectSession(completed)

        let orphanBoundary = PendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: "client_permission_orphan_a",
            permissionSelection: ComposerState().permissionSelectionSnapshot()
        )
        var retryState = ComposerState()
        retryState.applyPermissionMode(.fullAccess, sessionIsRunning: true)
        let retryClientMessageID = "client_permission_retry_b"
        let retryRequirement = PendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: retryClientMessageID,
            permissionSelection: retryState.permissionSelectionSnapshot()
        )
        let retryPayload = CodexAppServerTurnPayload(
            prompt: "孤立边界后的权限重试",
            options: retryState.turnOptions
        )
        conversationStore.appendLocalUser(
            retryPayload.previewText,
            sessionID: completed.id,
            clientMessageID: retryClientMessageID,
            sendStatus: .failed,
            turnPayload: retryPayload
        )
        XCTAssertTrue(store.mutateAndPersistQueuedTurns {
            store.pendingPermissionTurnBoundariesBySessionID[completed.id] = [orphanBoundary]
            store.permissionTurnRetryRequirementsByClientMessageID[retryClientMessageID] = retryRequirement
        })
        let failed = try XCTUnwrap(
            conversationStore.messages(for: completed.id).first(where: { $0.clientMessageID == retryClientMessageID })
        )

        let didRetry = await store.retryFailedUserMessage(failed)
        XCTAssertTrue(didRetry)
        XCTAssertTrue(client.createPayloads.isEmpty, "仅存 orphan boundary 时也不得直接 create/resume")
        XCTAssertEqual(store.queuedTurns(sessionID: completed.id).map(\.clientMessageID), [retryClientMessageID])
        XCTAssertEqual(
            store.pendingPermissionTurnBoundariesBySessionID[completed.id]?.map(\.clientMessageID),
            [orphanBoundary.clientMessageID, retryClientMessageID]
        )
    }

    func testRetryReinsertsRetainedPermissionBoundaryBeforeLaterQueue() async throws {
        let project = makeProject(id: "proj_retained_permission_retry_fifo")
        let completed = makeSession(
            id: "sess_retained_permission_retry_fifo",
            projectID: project.id,
            title: "Retained Permission Retry FIFO",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        let client = MockSessionStoreClient(projects: [project], sessions: [completed], messagesResult: [])
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
        store.takeOverSession(completed)
        await store.selectSession(completed)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        var retryState = ComposerState()
        retryState.applyPermissionMode(.fullAccess, sessionIsRunning: true)
        let retryClientMessageID = "client_retained_permission_a"
        let retainedBoundary = PendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: retryClientMessageID,
            permissionSelection: retryState.permissionSelectionSnapshot()
        )
        let laterClientMessageID = "client_later_message_b"
        let laterEntry = QueuedTurnEntry(
            sessionID: completed.id,
            projectID: project.id,
            payload: CodexAppServerTurnPayload(prompt: "后续消息 B"),
            clientMessageID: laterClientMessageID,
            intent: .standard
        )
        let retryPayload = CodexAppServerTurnPayload(
            prompt: "重试 retained boundary A",
            options: retryState.turnOptions
        )
        conversationStore.appendLocalUser(
            retryPayload.previewText,
            sessionID: completed.id,
            clientMessageID: retryClientMessageID,
            sendStatus: .failed,
            turnPayload: retryPayload
        )
        XCTAssertTrue(store.mutateAndPersistQueuedTurns {
            store.queuedRunningTurnsBySessionID[completed.id] = [laterEntry]
            store.pendingPermissionTurnBoundariesBySessionID[completed.id] = [retainedBoundary]
        })
        let failed = try XCTUnwrap(
            conversationStore.messages(for: completed.id).first(where: { $0.clientMessageID == retryClientMessageID })
        )

        let didRetry = await store.retryFailedUserMessage(failed)
        XCTAssertTrue(didRetry)
        XCTAssertTrue(client.createPayloads.isEmpty)
        XCTAssertEqual(
            store.queuedTurns(sessionID: completed.id).map(\.clientMessageID),
            [retryClientMessageID, laterClientMessageID]
        )
        store.dispatchNextQueuedRunningTurnIfIdle(sessionID: completed.id)
        XCTAssertEqual(socket.sentTurns.first?.clientMessageID, retryClientMessageID)
    }

    func testQueueDispatchesOrdinaryItemBeforeLaterPermissionBoundary() async throws {
        let project = makeProject(id: "proj_queue_before_permission_boundary")
        let completed = makeSession(
            id: "sess_queue_before_permission_boundary",
            projectID: project.id,
            title: "Queue Before Permission Boundary",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [completed], messagesResult: [])
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
        store.takeOverSession(completed)
        await store.selectSession(completed)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let ordinaryClientMessageID = "client_ordinary_before_permission"
        let permissionClientMessageID = "client_later_permission_boundary"
        let ordinaryEntry = QueuedTurnEntry(
            sessionID: completed.id,
            projectID: project.id,
            payload: CodexAppServerTurnPayload(prompt: "先排队的普通消息"),
            clientMessageID: ordinaryClientMessageID,
            intent: .standard
        )
        var permissionState = ComposerState()
        permissionState.applyPermissionMode(.fullAccess, sessionIsRunning: true)
        let permissionEntry = QueuedTurnEntry(
            sessionID: completed.id,
            projectID: project.id,
            payload: CodexAppServerTurnPayload(
                prompt: "后排队的权限消息",
                options: permissionState.turnOptions
            ),
            clientMessageID: permissionClientMessageID,
            intent: .standard,
            requiresFreshTurn: true
        )
        let boundary = PendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: permissionClientMessageID,
            permissionSelection: permissionState.permissionSelectionSnapshot()
        )
        XCTAssertTrue(store.mutateAndPersistQueuedTurns {
            store.queuedRunningTurnsBySessionID[completed.id] = [ordinaryEntry, permissionEntry]
            store.pendingPermissionTurnBoundariesBySessionID[completed.id] = [boundary]
        })

        store.dispatchNextQueuedRunningTurnIfIdle(sessionID: completed.id)

        XCTAssertEqual(socket.sentTurns.first?.clientMessageID, ordinaryClientMessageID)
        XCTAssertEqual(store.pendingPermissionTurnBoundary(for: completed.id), boundary)
    }

    func testRestartHistoryClearsOrphanPermissionBoundaryAndDispatchesNext() async throws {
        let project = makeProject(id: "proj_permission_history_reconcile")
        let completed = makeSession(
            id: "sess_permission_history_reconcile",
            projectID: project.id,
            title: "Permission History Reconcile",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        let permissionClientMessageID = "client_uncertain_permission_a"
        let laterClientMessageID = "client_after_uncertain_permission_b"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [completed],
            messagesResult: [
                CodexHistoryMessage(
                    role: "user",
                    content: "权限消息 A 已开始",
                    createdAt: Date(timeIntervalSince1970: 1),
                    clientMessageID: permissionClientMessageID,
                    turnID: "turn_uncertain_permission_a"
                )
            ]
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
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
        store.takeOverSession(completed)
        await store.selectSession(completed)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        var permissionState = ComposerState()
        permissionState.applyPermissionMode(.fullAccess, sessionIsRunning: true)
        let boundary = PendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: permissionClientMessageID,
            permissionSelection: permissionState.permissionSelectionSnapshot()
        )
        let laterEntry = QueuedTurnEntry(
            sessionID: completed.id,
            projectID: project.id,
            payload: CodexAppServerTurnPayload(prompt: "后续消息 B"),
            clientMessageID: laterClientMessageID,
            intent: .standard
        )
        XCTAssertTrue(store.mutateAndPersistQueuedTurns {
            // 模拟 turn/start 已获 ACK、队列项已删除，但 started 事件落地前进程退出。
            store.queuedRunningTurnsBySessionID[completed.id] = [laterEntry]
            store.pendingPermissionTurnBoundariesBySessionID[completed.id] = [boundary]
        })

        await store.reconcilePersistedQueuedTurns()

        XCTAssertNil(store.pendingPermissionTurnBoundary(for: completed.id))
        XCTAssertNil(store.queuedTurnLocation(clientMessageID: permissionClientMessageID))
        XCTAssertEqual(socket.sentTurns.first?.clientMessageID, laterClientMessageID)
    }

    func testCompletedSessionAwaitingAcceptedStartMarksPermissionChangeForFreshTurn() async throws {
        let project = makeProject(id: "proj_completed_queue_permission_change")
        let completed = makeSession(
            id: "sess_completed_queue_permission_change",
            projectID: project.id,
            title: "Completed Queue Permission Change",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [completed], messagesResult: [])
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
        store.takeOverSession(completed)
        await store.selectSession(completed)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let earlierEntry = QueuedTurnEntry(
            sessionID: completed.id,
            projectID: project.id,
            payload: CodexAppServerTurnPayload(prompt: "先排队的消息 A"),
            clientMessageID: "client_completed_queue_a",
            intent: .standard
        )
        XCTAssertTrue(store.mutateAndPersistQueuedTurns {
            store.queuedRunningTurnsBySessionID[completed.id] = [earlierEntry]
        })
        XCTAssertTrue(store.selectedSessionRequiresFreshPermissionTurn)
        store.dispatchNextQueuedRunningTurnIfIdle(sessionID: completed.id)
        XCTAssertEqual(socket.sentTurns.first?.clientMessageID, earlierEntry.clientMessageID)
        XCTAssertTrue(store.handleQueuedSendAccepted(
            clientMessageID: earlierEntry.clientMessageID,
            sessionID: completed.id,
            disposition: .awaitingStart(turnID: "turn_completed_queue_a")
        ))
        XCTAssertTrue(store.queuedTurns(sessionID: completed.id).isEmpty)
        XCTAssertTrue(store.queuedTurnAwaitingStartSessionIDs.contains(completed.id))
        XCTAssertTrue(store.selectedSessionRequiresFreshPermissionTurn)

        var composerState = ComposerState()
        composerState.applyPermissionMode(
            .readOnly,
            sessionIsRunning: store.selectedSessionRequiresFreshPermissionTurn
        )
        let permissionSelection = composerState.permissionSelectionSnapshot()
        XCTAssertTrue(permissionSelection.requiresNewTurn)

        let didQueue = await store.sendTurn(
            CodexAppServerTurnPayload(
                prompt: "权限变更后的消息 B",
                options: composerState.turnOptions
            ),
            permissionSelection: permissionSelection
        )
        XCTAssertTrue(didQueue)
        let queued = store.queuedTurns(sessionID: completed.id)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.last?.requiresFreshTurn, true)
        XCTAssertEqual(
            store.pendingPermissionTurnBoundary(for: completed.id)?.clientMessageID,
            queued.last?.clientMessageID
        )
    }

    func testRestartKeepsAcceptedStartBarrierUntilExactHistory() async throws {
        let project = makeProject(id: "proj_restart_accepted_start_barrier")
        let completed = makeSession(
            id: "sess_restart_accepted_start_barrier",
            projectID: project.id,
            title: "Restart Accepted Start Barrier",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestartAcceptedStartBarrierTests.\(UUID().uuidString)", isDirectory: true)
        let queuedTurnStore = FileQueuedTurnStore(directoryURL: directory)
        let acceptedTurnID = "turn_accepted_before_restart_a"
        let permissionClientMessageID = "client_permission_after_restart_b"
        var permissionState = ComposerState()
        permissionState.applyPermissionMode(.readOnly, sessionIsRunning: true)
        let boundary = PendingPermissionTurnBoundary(
            sessionID: completed.id,
            clientMessageID: permissionClientMessageID,
            permissionSelection: permissionState.permissionSelectionSnapshot()
        )
        let waitingPermissionEntry = QueuedTurnEntry(
            sessionID: completed.id,
            projectID: project.id,
            payload: CodexAppServerTurnPayload(
                prompt: "A started 后再发送权限消息 B",
                options: permissionState.turnOptions
            ),
            clientMessageID: permissionClientMessageID,
            intent: .standard,
            expectedTurnID: acceptedTurnID,
            requiresFreshTurn: true,
            waitsForAcceptedTurnStart: true,
            blockedCompletionID: "turn_before_a"
        )
        try queuedTurnStore.save(QueuedTurnProfileSnapshot(
            profileID: appStore.notificationRoutingProfileID,
            queuesBySessionID: [completed.id: [waitingPermissionEntry]],
            pendingPermissionTurnBoundariesBySessionID: [completed.id: [boundary]]
        ))

        let incompleteClient = MockSessionStoreClient(
            projects: [project],
            sessions: [completed],
            messagesResult: []
        )
        var incompleteSockets: [MockWebSocketClient] = []
        let incompleteStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { incompleteClient },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                incompleteSockets.append(socket)
                return socket
            }
        )
        await incompleteStore.refreshAll(autoAttach: false)
        incompleteStore.takeOverSession(completed)
        await incompleteStore.selectSession(completed)
        let incompleteSocket = try XCTUnwrap(incompleteSockets.first)
        incompleteSocket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: incompleteStore)
        await incompleteStore.reconcilePersistedQueuedTurns()

        XCTAssertTrue(incompleteSocket.sentTurns.isEmpty)
        XCTAssertEqual(incompleteStore.selectedQueuedTurns.first?.waitsForAcceptedTurnStart, true)
        XCTAssertEqual(incompleteStore.selectedQueuedTurns.first?.expectedTurnID, acceptedTurnID)

        let recoveredClient = MockSessionStoreClient(
            projects: [project],
            sessions: [completed],
            messagesResult: [
                CodexHistoryMessage(
                    role: "user",
                    content: "普通消息 A 已开始",
                    createdAt: Date(timeIntervalSince1970: 1),
                    clientMessageID: "client_accepted_before_restart_a",
                    turnID: acceptedTurnID
                )
            ]
        )
        var recoveredSockets: [MockWebSocketClient] = []
        let recoveredStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { recoveredClient },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                recoveredSockets.append(socket)
                return socket
            }
        )
        await recoveredStore.refreshAll(autoAttach: false)
        recoveredStore.takeOverSession(completed)
        await recoveredStore.selectSession(completed)
        let recoveredSocket = try XCTUnwrap(recoveredSockets.first)
        recoveredSocket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: recoveredStore)
        await recoveredStore.reconcilePersistedQueuedTurns()

        XCTAssertEqual(recoveredSocket.sentTurns.first?.clientMessageID, permissionClientMessageID)
        XCTAssertFalse(recoveredStore.selectedQueuedTurns.first?.waitsForAcceptedTurnStart == true)
    }
}
