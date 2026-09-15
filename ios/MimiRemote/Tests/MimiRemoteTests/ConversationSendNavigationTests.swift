import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testReenteringCreatingSessionBlocksSecondSendUntilRemoteIdentityArrives() async throws {
        let project = makeProject(id: "proj_creating_reentry")
        let gate = TurnSubmissionClientGate()
        let client = TurnSubmissionGateClient(projects: [project], sessions: [], gate: gate)
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        await store.refreshAll(autoAttach: false)
        _ = await store.createSession(projectID: project.id, prompt: "", resume: nil)
        let firstSend = Task {
            await store.sendTurn(CodexAppServerTurnPayload(prompt: "首条消息"))
        }
        await gate.waitForModelRequest()
        await gate.resolveModels([])
        await gate.waitForCreateRequestCount(1)
        let placeholder = try XCTUnwrap(store.selectedSession)
        XCTAssertTrue(store.isLoading)

        store.returnToSessionList()
        _ = await store.createSession(projectID: project.id, prompt: "", resume: nil)
        XCTAssertTrue(store.canSendInSelectedSession, "新草稿不受原会话创建等待影响")
        await store.selectSession(placeholder)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.canSendInSelectedSession)
        XCTAssertEqual(store.conversationReadiness(for: placeholder), .sending, "重入创建中的会话应继续显示发送阶段")
        let didSendSecond = await store.sendTurn(CodexAppServerTurnPayload(prompt: "等待中的第二条"))
        XCTAssertFalse(didSendSecond, "不能接受发往尚无真实 ID 的会话的后续消息")
        XCTAssertTrue(store.queuedTurns(sessionID: placeholder.id).isEmpty)

        let created = makeSession(
            id: "sess_created_after_reentry",
            projectID: project.id,
            title: "首条消息",
            status: "running",
            source: "codex",
            activeTurnID: "turn-created-first"
        )
        await gate.resolveCreate(.success(try makeCreateSessionResponse(session: created)))
        let didSendFirst = await firstSend.value
        XCTAssertTrue(didSendFirst)
        XCTAssertEqual(store.selectedSessionID, created.id, "重入的占位应切换为同一会话的真实身份")
        XCTAssertTrue(store.canSendInSelectedSession)
        XCTAssertFalse(store.sessions.contains { $0.id == placeholder.id })

        let didSendAfterCreation = await store.sendTurn(CodexAppServerTurnPayload(prompt: "创建后的第二条"))
        XCTAssertTrue(didSendAfterCreation)
        XCTAssertEqual(store.queuedTurns(sessionID: created.id).map(\.previewText), ["创建后的第二条"])
        XCTAssertTrue(store.queuedTurns(sessionID: placeholder.id).isEmpty)
        let requests = await gate.createRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testBackgroundGuidanceWriterConflictDoesNotDisableSelectedSession() async throws {
        // 同时覆盖建连失败与发送后的 RPC 拒绝，两者必须把冲突登记给原会话。
        for rejectsAfterDispatch in [false, true] {
            let project = makeProject(id: "proj_guided_writer_conflict")
            let original = makeSession(
                id: "sess_guided_writer_original", projectID: project.id, title: "原会话",
                status: "running", source: "codex", activeTurnID: "turn-writer-original"
            )
            let other = makeSession(
                id: "sess_guided_writer_other", projectID: project.id, title: "另一会话",
                status: "running", source: "codex", activeTurnID: "turn-writer-other"
            )
            let appStore = makeIsolatedAppStore()
            appStore.token = "test-token"
            let conversationStore = ConversationStore()
            var sockets: [MockWebSocketClient] = []
            let store = SessionStore(
                appStore: appStore, conversationStore: conversationStore, logStore: LogStore(),
                clientFactory: {
                    MockSessionStoreClient(projects: [project], sessions: [original, other], messagesResult: [])
                },
                webSocketFactory: {
                    let socket = MockWebSocketClient()
                    sockets.append(socket)
                    return socket
                }
            )
            await store.refreshAll(autoAttach: false)
            store.takeOverSession(original)
            await store.selectSession(original)
            let submissionContext = store.captureTurnSubmissionContext()
            store.takeOverSession(other)
            await store.selectSession(other)
            let otherSocket = try XCTUnwrap(sockets.last)
            otherSocket.emitStatus(.connected)
            try await waitForWebSocketStatus(.connected, store: store)
            store.setErrorMessage("当前会话原有提示")
            let didSend = await store.sendTurn(
                CodexAppServerTurnPayload(prompt: "后台引导冲突"),
                runningDelivery: .guided,
                submissionContext: submissionContext
            )
            XCTAssertTrue(didSend)
            let backgroundSocket = try XCTUnwrap(sockets.last)
            XCTAssertFalse(backgroundSocket === otherSocket)
            let conflict = "-32600: thread already has an active writer"
            if rejectsAfterDispatch {
                backgroundSocket.emitStatus(.connected)
                try await waitForSentGuidanceCount(1, socket: backgroundSocket)
                let clientID = try XCTUnwrap(backgroundSocket.sentGuidance.first?.clientMessageID)
                backgroundSocket.onTurnSendOutcome?(clientID, .rejected(message: conflict))
            } else {
                backgroundSocket.emitStatus(.failed(conflict))
            }
            try await waitForMessageStatus(
                .failed, content: "后台引导冲突", sessionID: original.id, conversationStore: conversationStore
            )
            XCTAssertTrue(store.hasActiveWriterConflict(sessionID: original.id))
            XCTAssertFalse(store.hasActiveWriterConflict(sessionID: other.id))
            XCTAssertTrue(store.canSendInSelectedSession)
            XCTAssertEqual(store.selectedSessionID, other.id)
            XCTAssertEqual(store.errorMessage, "当前会话原有提示")
            XCTAssertNil(store.pendingGuidanceBySessionID[original.id])
        }
    }

    func testFirstSendPublishesPreparationBeforeAcknowledgementAndLiveSubscription() async throws {
        let project = makeProject(id: "proj_live_preparation")
        let gate = TurnSubmissionClientGate()
        let client = TurnSubmissionGateClient(projects: [project], sessions: [], gate: gate)
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let socket = MockWebSocketClient()
        let store = SessionStore(
            appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { client }, webSocketFactory: { socket }
        )
        await store.refreshAll(autoAttach: false)
        let didCreateDraft = await store.createSession(projectID: project.id, prompt: "", resume: nil)
        XCTAssertTrue(didCreateDraft)
        let send = Task { await store.sendTurn(CodexAppServerTurnPayload(prompt: "验证首发")) }
        await gate.waitForModelRequest()
        await gate.resolveModels([])
        await gate.waitForCreateRequestCount(1)
        let pending = try XCTUnwrap(store.selectedSession)
        XCTAssertEqual(store.conversationReadiness(for: pending), .sending)
        XCTAssertTrue(socket.connectedSessionIDs.isEmpty, "ACK 前不把临时 ID 发送到订阅接口")

        let created = makeSession(
            id: "sess_live_preparation", projectID: project.id, title: "验证首发",
            status: "running", source: "codex", activeTurnID: "turn-live-preparation"
        )
        await gate.resolveCreate(.success(try makeCreateSessionResponse(session: created)))
        let didSend = await send.value
        XCTAssertTrue(didSend)
        XCTAssertEqual(store.conversationReadiness(for: created), .connecting)
        XCTAssertEqual(store.webSocketStatus, .connecting, "订阅开始必须同步退出旧的 disconnected 状态")
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        XCTAssertEqual(store.conversationReadiness(for: created), .live)
        let requests = await gate.createRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(store.conversationStore.messages(for: created.id).filter { $0.role == .user }.count, 1)
        store.returnToSessionList()
        XCTAssertNil(store.selectedSessionID)
    }

    func testReopenShowsHistoryThenConnectionWithoutInventingNetworkFailure() async throws {
        let project = makeProject(id: "proj_live_reopen")
        let running = makeSession(
            id: "sess_live_reopen", projectID: project.id, title: "重入",
            status: "running", source: "codex", activeTurnID: "turn-live-reopen"
        )
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let socket = MockWebSocketClient()
        let store = SessionStore(
            appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { client }, webSocketFactory: { socket },
            webSocketReconnectDelayNanoseconds: { _ in 60_000_000_000 }
        )
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        let firstOpen = Task { await store.selectSession(running) }
        await client.waitForHistoryRequestCount(1)
        XCTAssertEqual(store.conversationReadiness(for: running), .loadingHistory)
        client.resolveHistoryRequest(at: 0, with: HistoryMessagesPage(messages: [
            CodexHistoryMessage(id: "rollout:101", role: "assistant", content: "已有正文", createdAt: Date(timeIntervalSince1970: 10))
        ]))
        let didOpen = await firstOpen.value
        XCTAssertTrue(didOpen)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        XCTAssertEqual(store.conversationReadiness(for: running), .live)
        store.returnToSessionList()
        XCTAssertEqual(store.webSocketStatus, .disconnected)

        // 过期缓存确保重入确实经过异步历史读取，覆盖用户遇到的等待窗口。
        store.historyFirstPageCacheByKey.removeAll()
        store.historyLoadedSignatureBySessionID.removeValue(forKey: running.id)
        let reopened = Task { await store.selectSession(running) }
        await client.waitForHistoryRequestCount(2)
        XCTAssertEqual(store.conversationReadiness(for: running), .loadingHistory)
        XCTAssertEqual(socket.connectedSessionIDs.count, 1)
        store.networkReachabilityStatus = .unsatisfied
        XCTAssertEqual(store.conversationReadiness(for: running), .disconnected)
        store.networkReachabilityStatus = .satisfied
        store.connectionTermination = .credentialsInvalid
        XCTAssertEqual(store.conversationReadiness(for: running), .unavailable(.credentialsInvalid))
        store.connectionTermination = nil
        XCTAssertEqual(store.conversationReadiness(for: running), .loadingHistory)
        client.resolveHistoryRequest(at: 1, with: HistoryMessagesPage(messages: [
            CodexHistoryMessage(id: "rollout:101", role: "assistant", content: "已有正文", createdAt: Date(timeIntervalSince1970: 10)),
            CodexHistoryMessage(id: "rollout:102", role: "assistant", content: "离开期间的新正文", createdAt: Date(timeIntervalSince1970: 20))
        ]))
        let didReopen = await reopened.value
        XCTAssertTrue(didReopen)
        XCTAssertEqual(store.conversationReadiness(for: running), .connecting)
        XCTAssertEqual(socket.replayBufferedEventsByConnect, [false, false], "快照之后不重复回放旧正文")
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        XCTAssertEqual(store.conversationReadiness(for: running), .live)
        XCTAssertEqual(store.conversationStore.messages(for: running.id).map(\.content), ["已有正文", "离开期间的新正文"])
        socket.emitStatus(.failed("test failure"))
        try await waitForWebSocketStatus(.connecting, store: store)
        XCTAssertEqual(store.conversationReadiness(for: running), .reconnecting)
        store.returnToSessionList()
    }

    func testCapturedGuidedSendAfterSelectingAnotherSessionUsesBackgroundSocketUntilACK() async throws {
        let project = makeProject(id: "proj_guided_navigation")
        let original = makeSession(
            id: "sess_guided_original",
            projectID: project.id,
            title: "原会话",
            status: "running",
            source: "codex",
            activeTurnID: "turn-guided-original"
        )
        let other = makeSession(
            id: "sess_guided_other",
            projectID: project.id,
            title: "另一会话",
            status: "running",
            source: "codex",
            activeTurnID: "turn-guided-other"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: {
                MockSessionStoreClient(projects: [project], sessions: [original, other], messagesResult: [])
            },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(original)
        await store.selectSession(original)
        let originalSocket = try XCTUnwrap(sockets.first)
        originalSocket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let submissionContext = store.captureTurnSubmissionContext()

        store.takeOverSession(other)
        await store.selectSession(other)
        XCTAssertEqual(sockets.count, 2)
        let otherSocket = try XCTUnwrap(sockets.dropFirst().first)
        otherSocket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let didSend = await store.sendTurn(
            CodexAppServerTurnPayload(prompt: "切页后的引导"),
            runningDelivery: .guided,
            submissionContext: submissionContext
        )

        XCTAssertTrue(didSend)
        XCTAssertEqual(store.selectedSessionID, other.id)
        XCTAssertEqual(sockets.count, 3)
        XCTAssertEqual(otherSocket.disconnectCallCount, 0)
        let backgroundSocket = try XCTUnwrap(sockets.dropFirst(2).first)
        backgroundSocket.emitStatus(.connected)
        try await waitForSentGuidanceCount(1, socket: backgroundSocket)
        let firstClientMessageID = try XCTUnwrap(backgroundSocket.sentGuidance.first?.clientMessageID)
        XCTAssertEqual(backgroundSocket.sentGuidance.first?.payload.textPrompt, "切页后的引导")
        XCTAssertEqual(backgroundSocket.sentGuidance.first?.expectedTurnID, "turn-guided-original")

        backgroundSocket.onTurnSendOutcome?(firstClientMessageID, .guidanceAccepted)
        try await waitForMessageStatus(
            .sent,
            content: "切页后的引导",
            sessionID: original.id,
            conversationStore: conversationStore
        )
        XCTAssertEqual(backgroundSocket.disconnectCallCount, 1)
        XCTAssertEqual(store.selectedSessionID, other.id)

        let didSendUncertain = await store.sendTurn(
            CodexAppServerTurnPayload(prompt: "断连后的引导"),
            runningDelivery: .guided,
            submissionContext: submissionContext
        )
        XCTAssertTrue(didSendUncertain)
        XCTAssertEqual(sockets.count, 4)
        let disconnectedSocket = try XCTUnwrap(sockets.dropFirst(3).first)
        disconnectedSocket.emitStatus(.connected)
        try await waitForSentGuidanceCount(1, socket: disconnectedSocket)
        disconnectedSocket.emitStatus(.disconnected)
        try await waitForMessageStatus(
            .uncertain,
            content: "断连后的引导",
            sessionID: original.id,
            conversationStore: conversationStore
        )
        XCTAssertEqual(disconnectedSocket.sentGuidance.count, 1, "未知结果不能自动重发")
        XCTAssertEqual(store.selectedSessionID, other.id)
    }

    func testForegroundGuidedSendACKAfterNavigationStillSettlesOriginalEcho() async throws {
        let project = makeProject(id: "proj_guided_foreground_ack")
        let original = makeSession(
            id: "sess_guided_foreground_original",
            projectID: project.id,
            title: "原会话",
            status: "running",
            source: "codex",
            activeTurnID: "turn-guided-foreground"
        )
        let other = makeSession(
            id: "sess_guided_foreground_other",
            projectID: project.id,
            title: "另一会话",
            status: "completed",
            source: "codex",
            resumeID: "thread-guided-other"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: {
                MockSessionStoreClient(projects: [project], sessions: [original, other], messagesResult: [])
            },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(original)
        await store.selectSession(original)
        let originalSocket = try XCTUnwrap(sockets.first)
        originalSocket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let didSend = await store.sendTurn(
            CodexAppServerTurnPayload(prompt: "前台已提交"),
            runningDelivery: .guided
        )
        XCTAssertTrue(didSend)
        let clientMessageID = try XCTUnwrap(originalSocket.sentGuidance.first?.clientMessageID)

        await store.selectSession(other)
        XCTAssertEqual(originalSocket.disconnectCallCount, 1)
        originalSocket.onTurnSendOutcome?(clientMessageID, .guidanceAccepted)

        try await waitForMessageStatus(
            .sent,
            content: "前台已提交",
            sessionID: original.id,
            conversationStore: conversationStore
        )
        XCTAssertEqual(store.selectedSessionID, other.id)
    }

    func testRunningQueuedSendDuringModelLookupSurvivesReturnToList() async throws {
        let project = makeProject(id: "proj_send_navigation_running")
        let running = makeSession(
            id: "sess_send_navigation_running",
            projectID: project.id,
            title: "运行中",
            status: "running",
            source: "codex",
            activeTurnID: "turn-active"
        )
        let gate = TurnSubmissionClientGate()
        let client = TurnSubmissionGateClient(projects: [project], sessions: [running], gate: gate)
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
        store.takeOverSession(running)
        await store.selectSession(running)
        let submissionContext = store.captureTurnSubmissionContext()
        let sendTask = Task {
            await store.sendTurn(
                CodexAppServerTurnPayload(prompt: "返回后仍发送"),
                submissionContext: submissionContext
            )
        }

        await gate.waitForModelRequest()
        store.returnToSessionList()
        await gate.resolveModels([])

        let didSend = await sendTask.value
        let createRequestCount = await gate.createRequestCount()
        XCTAssertTrue(didSend)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertEqual(store.queuedTurns(sessionID: running.id).map(\.previewText), ["返回后仍发送"])
        XCTAssertEqual(createRequestCount, 0)
        XCTAssertEqual(sockets.last?.connectedSessionIDs.last, running.id)
    }

    func testLocalDraftSendSurvivesDiscardAndKeepsNewDraftSelectedAfterCreateACK() async throws {
        let project = makeProject(id: "proj_send_navigation_draft")
        let gate = TurnSubmissionClientGate()
        let client = TurnSubmissionGateClient(projects: [project], sessions: [], gate: gate)
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let didCreateSubmittedDraft = await store.createSession(projectID: project.id, prompt: "", resume: nil)
        XCTAssertTrue(didCreateSubmittedDraft)
        let submittedDraftID = try XCTUnwrap(store.selectedSessionID)
        let submissionContext = store.captureTurnSubmissionContext()
        store.returnToSessionList()
        XCTAssertFalse(store.sessions.contains { $0.id == submittedDraftID })

        let sendTask = Task {
            await store.sendTurn(
                CodexAppServerTurnPayload(prompt: "首发内容"),
                submissionContext: submissionContext
            )
        }
        await gate.waitForModelRequest()
        await gate.resolveModels([])
        await gate.waitForCreateRequestCount(1)

        let didCreateNewDraft = await store.createSession(projectID: project.id, prompt: "", resume: nil)
        XCTAssertTrue(didCreateNewDraft)
        let newDraftID = try XCTUnwrap(store.selectedSessionID)
        XCTAssertNotEqual(newDraftID, submittedDraftID)
        let created = makeSession(
            id: "sess_send_navigation_created",
            projectID: project.id,
            title: "首发内容",
            status: "running",
            source: "codex"
        )
        await gate.resolveCreate(.success(try makeCreateSessionResponse(session: created)))

        let didSend = await sendTask.value
        XCTAssertTrue(didSend)
        XCTAssertEqual(store.selectedSessionID, newDraftID)
        XCTAssertTrue(store.sessions.contains { $0.id == newDraftID && $0.isLocalDraft })
        XCTAssertTrue(store.sessions.contains { $0.id == created.id })
        let requests = await gate.createRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.prompt, "首发内容")
        XCTAssertEqual(requests.first?.resumeID, "")
    }

    func testContinuationCreateACKDoesNotReplaceNewSessionSelection() async throws {
        let project = makeProject(id: "proj_send_navigation_resume")
        let original = makeSession(
            id: "sess_send_navigation_original",
            projectID: project.id,
            title: "原会话",
            status: "completed",
            source: "codex",
            resumeID: "thread-original"
        )
        let other = makeSession(
            id: "sess_send_navigation_other",
            projectID: project.id,
            title: "另一会话",
            status: "completed",
            source: "codex",
            resumeID: "thread-other"
        )
        let gate = TurnSubmissionClientGate()
        let client = TurnSubmissionGateClient(projects: [project], sessions: [original, other], gate: gate)
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(original)
        let submissionContext = store.captureTurnSubmissionContext()
        let sendTask = Task {
            await store.sendTurn(
                CodexAppServerTurnPayload(prompt: "继续原会话"),
                submissionContext: submissionContext
            )
        }
        await gate.waitForModelRequest()
        await gate.resolveModels([])
        await gate.waitForCreateRequestCount(1)
        XCTAssertTrue(store.isLoading)
        await store.selectSession(other)
        XCTAssertFalse(store.isLoading)

        let otherSendTask = Task {
            await store.sendTurn(CodexAppServerTurnPayload(prompt: "继续另一会话"))
        }
        await gate.waitForCreateRequestCount(2)
        XCTAssertTrue(store.isLoading)

        var resumed = original
        resumed.status = "running"
        await gate.resolveCreate(.success(try makeCreateSessionResponse(session: resumed)), at: 0)

        let didSend = await sendTask.value
        XCTAssertTrue(didSend)
        XCTAssertEqual(store.selectedSessionID, other.id)
        XCTAssertTrue(store.isLoading, "A 的迟到 ACK 不能清除 B 的创建 loading")
        XCTAssertEqual(store.conversationReadiness(for: other), .sending)
        XCTAssertNotEqual(store.conversationReadiness(for: original), .sending)

        var otherResumed = other
        otherResumed.status = "running"
        await gate.resolveCreate(.success(try makeCreateSessionResponse(session: otherResumed)), at: 1)
        let didSendOther = await otherSendTask.value
        XCTAssertTrue(didSendOther)
        XCTAssertFalse(store.isLoading)
        let requests = await gate.createRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].resumeID, "thread-original")
        XCTAssertEqual(requests[0].prompt, "继续原会话")
        XCTAssertEqual(requests[1].resumeID, "thread-other")
        XCTAssertEqual(requests[1].prompt, "继续另一会话")
    }

    func testHostChangeDuringModelLookupCancelsCapturedSubmission() async throws {
        let project = makeProject(id: "proj_send_navigation_host")
        let gate = TurnSubmissionClientGate()
        let client = TurnSubmissionGateClient(projects: [project], sessions: [], gate: gate)
        let appStore = makeIsolatedAppStore()
        appStore.token = "old-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let submissionContext = store.captureTurnSubmissionContext()
        let sendTask = Task {
            await store.sendTurn(
                CodexAppServerTurnPayload(prompt: "不能发到新主机"),
                submissionContext: submissionContext
            )
        }
        await gate.waitForModelRequest()
        _ = try await store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://127.0.0.1:9988",
            token: "new-token"
        ))
        XCTAssertNotEqual(appStore.activeHostScope, submissionContext.hostScope)
        await gate.resolveModels([])

        let didSend = await sendTask.value
        let createRequestCount = await gate.createRequestCount()
        XCTAssertFalse(didSend)
        XCTAssertEqual(createRequestCount, 0)
    }
}

@MainActor
private func waitForSentGuidanceCount(_ expected: Int, socket: MockWebSocketClient) async throws {
    for _ in 0..<80 {
        if socket.sentGuidance.count == expected { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("guided 数量未在超时前变为 \(expected)，当前为 \(socket.sentGuidance.count)")
}

@MainActor
private func waitForMessageStatus(
    _ expected: MessageSendStatus,
    content: String,
    sessionID: SessionID,
    conversationStore: ConversationStore
) async throws {
    for _ in 0..<80 {
        if conversationStore.messages(for: sessionID).contains(where: {
            $0.content == content && $0.sendStatus == expected
        }) { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("消息 \(content) 未在超时前变为 \(expected)")
}

private actor TurnSubmissionClientGate {
    private var modelContinuation: CheckedContinuation<[CodexAppServerModelOption], Never>?
    private var modelRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var didRequestModels = false
    private var createContinuations: [CheckedContinuation<CreateSessionResponse, Error>] = []
    private var createRequestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var recordedCreateRequests: [CreateSessionRequest] = []

    func requestModels() async -> [CodexAppServerModelOption] {
        didRequestModels = true
        modelRequestWaiters.forEach { $0.resume() }
        modelRequestWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            modelContinuation = continuation
        }
    }

    func waitForModelRequest() async {
        guard !didRequestModels else { return }
        await withCheckedContinuation { continuation in
            modelRequestWaiters.append(continuation)
        }
    }

    func resolveModels(_ options: [CodexAppServerModelOption]) {
        modelContinuation?.resume(returning: options)
        modelContinuation = nil
    }

    func requestCreate(_ request: CreateSessionRequest) async throws -> CreateSessionResponse {
        recordedCreateRequests.append(request)
        notifyCreateWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            createContinuations.append(continuation)
            notifyCreateWaiters()
        }
    }

    func waitForCreateRequestCount(_ count: Int) async {
        guard createReadyCount >= count else {
            await withCheckedContinuation { continuation in
                createRequestWaiters.append((count, continuation))
            }
            return
        }
    }

    func resolveCreate(_ result: Result<CreateSessionResponse, Error>, at index: Int = 0) {
        switch result {
        case .success(let response):
            createContinuations[index].resume(returning: response)
        case .failure(let error):
            createContinuations[index].resume(throwing: error)
        }
    }

    func createRequests() -> [CreateSessionRequest] {
        recordedCreateRequests
    }

    func createRequestCount() -> Int {
        recordedCreateRequests.count
    }

    private var createReadyCount: Int {
        min(recordedCreateRequests.count, createContinuations.count)
    }

    private func notifyCreateWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in createRequestWaiters {
            if createReadyCount >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        createRequestWaiters = pending
    }
}

private final class TurnSubmissionGateClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let sessionsResult: [AgentSession]
    let gate: TurnSubmissionClientGate

    init(projects: [AgentProject], sessions: [AgentSession], gate: TurnSubmissionClientGate) {
        projectsResult = projects
        sessionsResult = sessions
        self.gate = gate
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        sessionsResult
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        await gate.requestModels()
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        try await gate.requestCreate(payload)
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }
}
