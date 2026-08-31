import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testComposerQueueTrayHidesDispatchingTurnButKeepsRecoverableEntries() {
        let sessionID = "composer-queue-tray"
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        store.selectedSessionID = sessionID
        store.queuedRunningTurnsBySessionID[sessionID] = [
            QueuedTurnEntry(
                sessionID: sessionID,
                payload: CodexAppServerTurnPayload(prompt: "waiting"),
                clientMessageID: "waiting",
                intent: .standard
            ),
            QueuedTurnEntry(
                sessionID: sessionID,
                payload: CodexAppServerTurnPayload(prompt: "dispatching"),
                clientMessageID: "dispatching",
                intent: .standard,
                dispatchState: .dispatching
            ),
            QueuedTurnEntry(
                sessionID: sessionID,
                payload: CodexAppServerTurnPayload(prompt: "needs confirmation"),
                clientMessageID: "needs-confirmation",
                intent: .standard,
                dispatchState: .needsConfirmation
            ),
        ]

        XCTAssertEqual(
            store.selectedComposerTrayQueuedTurns.map(\.clientMessageID),
            ["waiting", "dispatching", "needs-confirmation"],
            "尚未进入对话气泡的派发项仍需保持可见"
        )
        conversationStore.applyAssistantDelta(
            AgentDelta(text: "runtime replay", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "runtime-turn",
                itemID: "runtime-item",
                messageID: "runtime-message",
                clientMessageID: "dispatching",
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        XCTAssertEqual(
            store.selectedComposerTrayQueuedTurns.map(\.clientMessageID),
            ["waiting", "dispatching", "needs-confirmation"],
            "非用户消息即使复用 clientMessageID，也不能提前隐藏派发项"
        )

        conversationStore.appendLocalUser(
            "dispatching",
            sessionID: sessionID,
            clientMessageID: "dispatching"
        )

        XCTAssertEqual(
            store.selectedQueuedTurns.map(\.clientMessageID),
            ["waiting", "dispatching", "needs-confirmation"],
            "完整队列必须继续保留正在派发的消息，供管理和重连对账使用"
        )
        XCTAssertEqual(
            store.selectedComposerTrayQueuedTurns.map(\.clientMessageID),
            ["waiting", "needs-confirmation"]
        )
    }

    func testSharedSSHOpeningIdleThreadResumesToValidateWriter() async throws {
        let project = AgentProject(id: "shared-open", name: "Shared Open", path: "/tmp/shared-open")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeSharedSSHConfig(project: project) }
        )
        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        socket.onStatus = { statuses.append($0) }

        socket.connect(sessionID: "thread-shared-open")
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read", after: 1)
        transportResponse(
            transport,
            id: read.id,
            result: sharedIdleThreadJSON(id: "thread-shared-open", cwd: project.path)
        )

        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 2)
        XCTAssertEqual(resume.params?.objectValue?["threadId"]?.stringValue, "thread-shared-open")
        transportErrorResponse(
            transport,
            id: resume.id,
            code: -32600,
            message: "thread thread-shared-open already has an active writer"
        )

        for _ in 0..<100 where !statuses.contains(where: {
            if case .failed(let message) = $0 {
                return SessionStore.isCodexActiveWriterConflict(message)
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(statuses.count, 2)
        XCTAssertEqual(statuses.first, .connecting)
        guard case .failed(let failureMessage) = statuses.last else {
            XCTFail("SSH writer 检查失败必须以 failed 结束，当前为 \(statuses)")
            return
        }
        XCTAssertTrue(SessionStore.isCodexActiveWriterConflict(failureMessage))
        XCTAssertFalse(statuses.contains(.connected), "writer 冲突确认前不能把 Composer 误判为可发送")
        socket.disconnect()
    }

    func testSharedSSHResumeActiveThreadQueuesFirstPromptWithoutTurnStart() async throws {
        let project = AgentProject(id: "shared-active", name: "Shared Active", path: "/tmp/shared-active")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeSharedSSHConfig(project: project) }
        )
        let createTask = Task {
            try await runtime.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "排进共享队列",
                resumeID: "thread-active",
                clientMessageID: "client-first"
            ))
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume")
        XCTAssertEqual(
            Set(try XCTUnwrap(resume.params?.objectValue).keys),
            ["threadId", "cwd", "excludeTurns", "initialTurnsPage", "mimiPreserveThreadPermissions"]
        )
        XCTAssertEqual(resume.params?.objectValue?["cwd"]?.stringValue, project.path)
        XCTAssertEqual(resume.params?.objectValue?["mimiPreserveThreadPermissions"]?.boolValue, true)
        transportResponse(
            transport,
            id: resume.id,
            result: #"{"thread":{"id":"thread-active","sessionId":"thread-active","preview":"active","ephemeral":false,"modelProvider":"openai","createdAt":1,"updatedAt":2,"status":{"type":"active"},"cwd":"/tmp/shared-active","source":"appServer","threadSource":"user","turns":[{"id":"external-turn","status":"inProgress","items":[]}]}}"#
        )

        let created = try await createTask.value
        XCTAssertEqual(created.session.activeTurnID, "external-turn")
        XCTAssertEqual(created.requiresQueuedInitialInput, true)
        let createRequests = await appServerRequests(transport)
        XCTAssertFalse(createRequests.contains { $0.method == "turn/start" })

        var queueOptions = CodexAppServerTurnOptions.default
        queueOptions.model = "gpt-5.6-luna"
        queueOptions.reasoningEffort = .high
        queueOptions.collaborationMode = .plan
        let submitTask = Task {
            try await runtime.submitTurnOutcome(
                sessionID: "thread-active",
                payload: CodexAppServerTurnPayload(prompt: "排进共享队列", options: queueOptions),
                clientMessageID: "client-first"
            )
        }
        let settings = try await waitForFakeAppServerRequest(transport, method: "thread/settings/update")
        let settingsParams = try XCTUnwrap(settings.params?.objectValue)
        XCTAssertEqual(Set(settingsParams.keys), ["threadId", "model", "effort", "collaborationMode"])
        XCTAssertEqual(settingsParams["threadId"]?.stringValue, "thread-active")
        XCTAssertEqual(settingsParams["model"]?.stringValue, "gpt-5.6-luna")
        XCTAssertEqual(settingsParams["effort"]?.stringValue, "high")
        let collaborationMode = try XCTUnwrap(settingsParams["collaborationMode"]?.objectValue)
        XCTAssertEqual(collaborationMode["mode"]?.stringValue, "plan")
        let collaborationSettings = try XCTUnwrap(collaborationMode["settings"]?.objectValue)
        XCTAssertEqual(Set(collaborationSettings.keys), ["model", "reasoning_effort", "developer_instructions"])
        XCTAssertEqual(collaborationSettings["model"]?.stringValue, "gpt-5.6-luna")
        XCTAssertEqual(collaborationSettings["reasoning_effort"]?.stringValue, "high")
        XCTAssertEqual(collaborationSettings["developer_instructions"], .null)
        let requestsBeforeSettingsACK = await appServerRequests(transport)
        XCTAssertEqual(requestsBeforeSettingsACK.last?.method, "thread/settings/update")
        XCTAssertFalse(requestsBeforeSettingsACK.contains { $0.method == "thread/queue/add" })
        transportResponse(transport, id: settings.id, result: #"{}"#)
        let add = try await waitForFakeAppServerRequest(transport, method: "thread/queue/add")
        let params = try XCTUnwrap(add.params?.objectValue)
        XCTAssertEqual(Set(params.keys), ["threadId", "input", "clientUserMessageId"])
        XCTAssertEqual(params["clientUserMessageId"]?.stringValue, "client-first")
        transportResponse(
            transport,
            id: add.id,
            result: #"{"queuedSubmission":{"id":"submission-first","clientUserMessageId":"client-first"}}"#
        )
        let submitOutcome = try await submitTask.value
        XCTAssertEqual(submitOutcome, .serverQueued(submissionID: "submission-first", startedTurnID: nil))
        let requestsAfterSubmit = await appServerRequests(transport)
        let settingsIndex = try XCTUnwrap(requestsAfterSubmit.firstIndex { $0.method == "thread/settings/update" })
        let addIndex = try XCTUnwrap(requestsAfterSubmit.firstIndex { $0.method == "thread/queue/add" })
        XCTAssertLessThan(settingsIndex, addIndex)
        XCTAssertFalse(requestsAfterSubmit.contains { $0.method == "turn/start" })

        let beforeUnsupported = await transport.sentMessages().count
        let unsupportedTask = Task {
            try await runtime.submitTurnOutcome(
                sessionID: "thread-active",
                payload: CodexAppServerTurnPayload(prompt: "unsupported"),
                clientMessageID: "client-unsupported"
            )
        }
        let unsupportedSettings = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/settings/update",
            after: beforeUnsupported
        )
        transportResponse(transport, id: unsupportedSettings.id, result: #"{}"#)
        let unsupportedAdd = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/queue/add",
            after: beforeUnsupported
        )
        transportErrorResponse(transport, id: unsupportedAdd.id, code: -32601, message: "method not found")
        do {
            _ = try await unsupportedTask.value
            XCTFail("queue API 缺失必须明确拒绝")
        } catch CodexAppServerSessionRuntimeError.serverQueueUnavailable(let method) {
            XCTAssertEqual(method, "thread/queue/add")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let unsupportedRequests = Array((await appServerRequests(transport)).dropFirst(beforeUnsupported))
        XCTAssertFalse(unsupportedRequests.contains { $0.method == "thread/queue/list" })
        XCTAssertFalse(unsupportedRequests.contains { $0.method == "thread/items/list" })
    }

    func testSharedSSHSettingsFailureDoesNotQueueAndClearsSubmissionInFlight() async throws {
        let project = AgentProject(id: "shared-settings-error", name: "Shared Settings Error", path: "/tmp/shared-settings-error")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeSharedSSHConfig(project: project) }
        )
        let first = try await prepareEmptySharedThread(
            runtime: runtime,
            pool: pool,
            project: project,
            id: "thread-settings-error"
        )
        let firstSubmit = Task {
            try await runtime.submitTurnOutcome(
                sessionID: "thread-settings-error",
                payload: CodexAppServerTurnPayload(prompt: "first"),
                clientMessageID: "client-settings-error"
            )
        }
        let firstResume = try await waitForFakeAppServerRequest(first, method: "thread/resume")
        transportResponse(
            first,
            id: firstResume.id,
            result: sharedIdleThreadJSON(id: "thread-settings-error", cwd: project.path)
        )
        let failedSettings = try await waitForFakeAppServerRequest(first, method: "thread/settings/update")
        transportErrorResponse(first, id: failedSettings.id, code: -32600, message: "settings rejected")
        do {
            _ = try await firstSubmit.value
            XCTFail("settings/update 失败时必须终止提交")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("settings rejected"))
        }
        let failedRequests = await appServerRequests(first)
        XCTAssertFalse(failedRequests.contains { $0.method == "thread/queue/add" })
        let retryStartIndex = await first.sentMessages().count

        let retrySubmit = Task {
            try await runtime.submitTurnOutcome(
                sessionID: "thread-settings-error",
                payload: CodexAppServerTurnPayload(prompt: "retry"),
                clientMessageID: "client-settings-retry"
            )
        }
        try await respondToSharedSettingsUpdate(first, after: retryStartIndex)
        let retryAdd = try await waitForFakeAppServerRequest(
            first,
            method: "thread/queue/add",
            after: retryStartIndex
        )
        transportResponse(
            first,
            id: retryAdd.id,
            result: #"{"queuedSubmission":{"id":"submission-retry","clientUserMessageId":"client-settings-retry"}}"#
        )
        let retryOutcome = try await retrySubmit.value
        XCTAssertEqual(
            retryOutcome,
            .serverQueued(submissionID: "submission-retry", startedTurnID: nil)
        )
    }

    func testSharedSSHQueueACKLossReconcilesQueueItemsQueueWithFullPagination() async throws {
        let project = AgentProject(id: "shared-reconcile", name: "Shared Reconcile", path: "/tmp/shared-reconcile")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeSharedSSHConfig(project: project) }
        )
        let first = try await prepareEmptySharedThread(runtime: runtime, pool: pool, project: project)

        let submitTask = Task {
            try await runtime.submitTurnOutcome(
                sessionID: "thread-reconcile",
                payload: CodexAppServerTurnPayload(prompt: "只写一次"),
                clientMessageID: "client-reconcile"
            )
        }
        let initialResume = try await waitForFakeAppServerRequest(first, method: "thread/resume")
        transportResponse(
            first,
            id: initialResume.id,
            result: sharedIdleThreadJSON(id: "thread-reconcile", cwd: project.path)
        )
        try await respondToSharedSettingsUpdate(first)
        _ = try await waitForFakeAppServerRequest(first, method: "thread/queue/add")
        first.failReceive()

        let second = try await waitForFakeAppServerTransport(in: pool, index: 1)
        try await initializeFakeTransport(second)
        let resume = try await waitForFakeAppServerRequest(second, method: "thread/resume")
        transportResponse(second, id: resume.id, result: sharedIdleThreadJSON(id: "thread-reconcile", cwd: project.path))

        var offset = await second.sentMessages().count
        let queue1 = try await waitForFakeAppServerRequest(second, method: "thread/queue/list", after: offset)
        transportResponse(second, id: queue1.id, result: #"{"data":[],"nextCursor":"queue-2"}"#)
        offset = await second.sentMessages().count
        let queue2 = try await waitForFakeAppServerRequest(second, method: "thread/queue/list", after: offset)
        XCTAssertEqual(queue2.params?.objectValue?["cursor"]?.stringValue, "queue-2")
        transportResponse(second, id: queue2.id, result: #"{"data":[],"nextCursor":null}"#)

        offset = await second.sentMessages().count
        let items1 = try await waitForFakeAppServerRequest(second, method: "thread/items/list", after: offset)
        XCTAssertEqual(items1.params?.objectValue?["sortDirection"]?.stringValue, "desc")
        transportResponse(second, id: items1.id, result: #"{"data":[],"nextCursor":"items-2"}"#)
        offset = await second.sentMessages().count
        let items2 = try await waitForFakeAppServerRequest(second, method: "thread/items/list", after: offset)
        XCTAssertEqual(items2.params?.objectValue?["cursor"]?.stringValue, "items-2")
        transportResponse(second, id: items2.id, result: #"{"data":[],"nextCursor":null}"#)

        offset = await second.sentMessages().count
        let queue3 = try await waitForFakeAppServerRequest(second, method: "thread/queue/list", after: offset)
        transportResponse(second, id: queue3.id, result: #"{"data":[],"nextCursor":"queue-4"}"#)
        offset = await second.sentMessages().count
        let queue4 = try await waitForFakeAppServerRequest(second, method: "thread/queue/list", after: offset)
        transportResponse(
            second,
            id: queue4.id,
            result: #"{"data":[{"id":"submission-recovered","clientUserMessageId":"client-reconcile"}],"nextCursor":null}"#
        )

        let recoveredOutcome = try await submitTask.value
        XCTAssertEqual(recoveredOutcome, .serverQueued(submissionID: "submission-recovered", startedTurnID: nil))
        let allRequests = await appServerRequests(first) + appServerRequests(second)
        XCTAssertEqual(allRequests.filter { $0.method == "thread/queue/add" }.count, 1)
        XCTAssertEqual(allRequests.filter { $0.method == "thread/queue/list" }.count, 4)
        XCTAssertEqual(allRequests.filter { $0.method == "thread/items/list" }.count, 2)
    }

    func testSharedSSHQueueACKLossNotFoundDoesNotRepeatWrite() async throws {
        let project = AgentProject(id: "shared-not-found", name: "Shared Not Found", path: "/tmp/shared-not-found")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeSharedSSHConfig(project: project) }
        )
        let first = try await prepareEmptySharedThread(runtime: runtime, pool: pool, project: project, id: "thread-not-found")
        let submitTask = Task {
            try await runtime.submitTurnOutcome(
                sessionID: "thread-not-found",
                payload: CodexAppServerTurnPayload(prompt: "结果未知"),
                clientMessageID: "client-not-found"
            )
        }
        let initialResume = try await waitForFakeAppServerRequest(first, method: "thread/resume")
        transportResponse(
            first,
            id: initialResume.id,
            result: sharedIdleThreadJSON(id: "thread-not-found", cwd: project.path)
        )
        try await respondToSharedSettingsUpdate(first)
        _ = try await waitForFakeAppServerRequest(first, method: "thread/queue/add")
        first.failReceive()

        let second = try await waitForFakeAppServerTransport(in: pool, index: 1)
        try await initializeFakeTransport(second)
        let resume = try await waitForFakeAppServerRequest(second, method: "thread/resume")
        transportResponse(second, id: resume.id, result: sharedIdleThreadJSON(id: "thread-not-found", cwd: project.path))
        for method in ["thread/queue/list", "thread/items/list", "thread/queue/list"] {
            let offset = await second.sentMessages().count
            let request = try await waitForFakeAppServerRequest(second, method: method, after: offset)
            transportResponse(second, id: request.id, result: #"{"data":[],"nextCursor":null}"#)
        }

        do {
            _ = try await submitTask.value
            XCTFail("ACK 丢失且两处均未找到时必须保持结果不确定")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fake app-server receive failed"))
        }
        let allRequests = await appServerRequests(first) + appServerRequests(second)
        XCTAssertEqual(allRequests.filter { $0.method == "thread/queue/add" }.count, 1)
    }

    func testSharedSSHQueueACKLossRecoversStartedItemWithTurnID() async throws {
        let project = AgentProject(id: "shared-items", name: "Shared Items", path: "/tmp/shared-items")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeSharedSSHConfig(project: project) }
        )
        let first = try await prepareEmptySharedThread(runtime: runtime, pool: pool, project: project, id: "thread-items")
        let submitTask = Task {
            try await runtime.submitTurnOutcome(
                sessionID: "thread-items",
                payload: CodexAppServerTurnPayload(prompt: "从持久化 item 恢复"),
                clientMessageID: "client-items"
            )
        }
        let initialResume = try await waitForFakeAppServerRequest(first, method: "thread/resume")
        transportResponse(first, id: initialResume.id, result: sharedIdleThreadJSON(id: "thread-items", cwd: project.path))
        try await respondToSharedSettingsUpdate(first)
        _ = try await waitForFakeAppServerRequest(first, method: "thread/queue/add")
        first.failReceive()

        let second = try await waitForFakeAppServerTransport(in: pool, index: 1)
        try await initializeFakeTransport(second)
        let resume = try await waitForFakeAppServerRequest(second, method: "thread/resume")
        transportResponse(second, id: resume.id, result: sharedIdleThreadJSON(id: "thread-items", cwd: project.path))
        let queue = try await waitForFakeAppServerRequest(second, method: "thread/queue/list")
        transportResponse(second, id: queue.id, result: #"{"data":[],"nextCursor":null}"#)
        let items = try await waitForFakeAppServerRequest(second, method: "thread/items/list")
        transportResponse(
            second,
            id: items.id,
            result: #"{"data":[{"turnId":"turn-items","item":{"id":"user-items","type":"userMessage","clientId":"client-items","content":[]}}],"nextCursor":null}"#
        )

        let outcome = try await submitTask.value
        XCTAssertEqual(
            outcome,
            .serverQueued(
                submissionID: "reconciled:client-items",
                startedTurnID: "turn-items"
            )
        )
        let allRequests = await appServerRequests(first) + appServerRequests(second)
        XCTAssertEqual(allRequests.filter { $0.method == "thread/queue/add" }.count, 1)
        XCTAssertEqual(allRequests.filter { $0.method == "thread/queue/list" }.count, 1)
        XCTAssertEqual(allRequests.filter { $0.method == "thread/items/list" }.count, 1)
    }

    func testServerQueueEarlyMatchingStartedWaitsForAddOutcomeBeforeNextFIFO() async throws {
        let project = makeProject(id: "shared-early-started")
        let session = makeSession(
            id: "shared-early-started-thread",
            projectID: project.id,
            title: "Shared Early Started",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "external-running-turn"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [session], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                socket.turnDeliveryMode = .sharedServerQueue
                sockets.append(socket)
                return socket
            }
        )
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(session)
        await store.selectSession(session)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let sentFirst = await store.sendTurn(CodexAppServerTurnPayload(prompt: "first"))
        XCTAssertTrue(sentFirst)
        try await waitForSentTurnCount(1, socket: sockets[0])
        let firstID = try XCTUnwrap(sockets[0].sentTurns.first?.clientMessageID)
        let sentSecond = await store.sendTurn(CodexAppServerTurnPayload(prompt: "second"))
        XCTAssertTrue(sentSecond)
        let secondID = try XCTUnwrap(store.selectedQueuedTurns.last?.clientMessageID)
        XCTAssertEqual(sockets[0].sentTurns.count, 1)

        var projector = CodexAppServerEventProjector()
        let userItemStarted = try XCTUnwrap(projector.project(CodexAppServerNotification(
            method: "item/started",
            params: .object([
                "threadId": .string(session.id),
                "turnId": .string("turn-first"),
                "item": .object([
                    "id": .string("user-first"),
                    "type": .string("userMessage"),
                    "clientId": .string(firstID),
                    "content": .array([.object(["type": .string("text"), "text": .string("first")])])
                ])
            ])
        )))
        sockets[0].emitEvent(userItemStarted)
        try await waitForSelectedQueueHead(secondID, store: store)
        XCTAssertEqual(sockets[0].sentTurns.count, 1, "queue/add outcome 前不能派发第二条")
        XCTAssertEqual(
            conversationStore.messages(for: session.id).first(where: {
                $0.clientMessageID == firstID
            })?.sendStatus,
            .confirmed
        )

        sockets[0].onTurnSendOutcome?(
            firstID,
            .serverQueued(submissionID: "submission-first", startedTurnID: nil)
        )
        try await waitForSentTurnCount(2, socket: sockets[0])
        XCTAssertEqual(sockets[0].sentTurns.last?.clientMessageID, secondID)
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .dispatching)
        XCTAssertNil(store.selectedQueuedTurns.first?.lastError)
        XCTAssertNotEqual(
            conversationStore.messages(for: session.id).first(where: {
                $0.clientMessageID == secondID
            })?.sendStatus,
            .failed
        )
    }

    func testServerQueueLateMatchingStartedResolvesNeedsConfirmationAndContinuesFIFO() async throws {
        let project = makeProject(id: "shared-receipt")
        let session = makeSession(
            id: "shared-receipt-thread",
            projectID: project.id,
            title: "Shared Receipt",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "external-running-turn"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [session], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                socket.turnDeliveryMode = .sharedServerQueue
                sockets.append(socket)
                return socket
            }
        )
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(session)
        await store.selectSession(session)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let sentFirst = await store.sendTurn(CodexAppServerTurnPayload(prompt: "first"))
        XCTAssertTrue(sentFirst)
        try await waitForSentTurnCount(1, socket: sockets[0])
        let firstID = try XCTUnwrap(sockets[0].sentTurns.first?.clientMessageID)
        var projector = CodexAppServerEventProjector()
        let bareTurnStarted = try XCTUnwrap(projector.project(CodexAppServerNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(session.id),
                "turn": .object(["id": .string("turn-first"), "status": .string("inProgress")])
            ])
        )))
        sockets[0].emitEvent(bareTurnStarted)
        await Task.yield()
        XCTAssertNil(store.selectedQueuedTurns.first?.serverStartedTurnID)

        let userItemStarted = try XCTUnwrap(projector.project(CodexAppServerNotification(
            method: "item/started",
            params: .object([
                "threadId": .string(session.id),
                "turnId": .string("turn-first"),
                "item": .object([
                    "id": .string("user-first"),
                    "type": .string("userMessage"),
                    "clientId": .string(firstID),
                    "content": .array([.object(["type": .string("text"), "text": .string("first")])])
                ])
            ])
        )))
        sockets[0].emitEvent(userItemStarted)
        try await waitForSelectedQueueToBecomeEmpty(store: store)
        XCTAssertEqual(
            conversationStore.messages(for: session.id).first(where: {
                $0.clientMessageID == firstID
            })?.sendStatus,
            .confirmed
        )
        // 精确 started 已经完成队首，迟到的 ACK 不得重新加入队列。
        store.handleTurnSendOutcome(
            clientMessageID: firstID,
            sessionID: session.id,
            outcome: .serverQueued(submissionID: "submission-first", startedTurnID: nil)
        )
        XCTAssertTrue(store.selectedQueuedTurns.isEmpty)

        let sentSecond = await store.sendTurn(CodexAppServerTurnPayload(prompt: "second"))
        XCTAssertTrue(sentSecond)
        try await waitForSentTurnCount(2, socket: sockets[0])
        let secondID = try XCTUnwrap(sockets[0].sentTurns.last?.clientMessageID)
        XCTAssertTrue(store.handleQueuedSendFailure(
            clientMessageID: secondID,
            sessionID: session.id,
            message: "queue/add ACK 丢失且 reconciliation 未找到"
        ))
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .needsConfirmation)

        let sentThird = await store.sendTurn(CodexAppServerTurnPayload(prompt: "third"))
        XCTAssertTrue(sentThird)
        XCTAssertEqual(sockets[0].sentTurns.count, 2)
        let thirdID = try XCTUnwrap(store.selectedQueuedTurns.last?.clientMessageID)
        XCTAssertFalse(store.handleServerQueueTurnStarted(
            clientMessageID: "external-client",
            sessionID: session.id,
            turnID: "external-turn"
        ))
        XCTAssertEqual(store.selectedQueuedTurns.first?.clientMessageID, secondID)
        XCTAssertEqual(sockets[0].sentTurns.count, 2)
        XCTAssertTrue(store.handleServerQueueTurnStarted(
            clientMessageID: secondID,
            sessionID: session.id,
            turnID: "turn-second"
        ))
        try await waitForSentTurnCount(3, socket: sockets[0])
        XCTAssertEqual(sockets[0].sentTurns.last?.clientMessageID, thirdID)
        XCTAssertEqual(store.selectedQueuedTurns.first?.clientMessageID, thirdID)
        XCTAssertEqual(
            conversationStore.messages(for: session.id).first(where: {
                $0.clientMessageID == secondID
            })?.sendStatus,
            .sent
        )
    }

    func testPersistedServerQueueReceiptSurvivesRestartForItemsReconciliation() throws {
        let appStore = makeIsolatedAppStore()
        let sessionID = "shared-restart-thread"
        let entry = QueuedTurnEntry(
            sessionID: sessionID,
            payload: CodexAppServerTurnPayload(prompt: "persisted"),
            clientMessageID: "client-persisted",
            intent: .standard,
            dispatchState: .dispatching,
            serverSubmissionID: "submission-persisted"
        )
        let queuedStore = SharedQueueTestStore(snapshot: QueuedTurnProfileSnapshot(
            profileID: appStore.notificationRoutingProfileID,
            queuesBySessionID: [sessionID: [entry]]
        ))
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedStore
        )

        let restored = try XCTUnwrap(store.queuedRunningTurnsBySessionID[sessionID]?.first)
        XCTAssertEqual(restored.dispatchState, .dispatching)
        XCTAssertEqual(restored.serverSubmissionID, "submission-persisted")
        XCTAssertEqual(queuedStore.saveCallCount, 0)
    }

    func testPersistedServerQueueReceiptReconciliationPagesUntilClientID() async throws {
        let project = makeProject(id: "shared-restart-pages")
        let session = makeSession(
            id: "shared-restart-pages-thread",
            projectID: project.id,
            title: "Shared Restart Pages",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        let clientMessageID = "client-on-older-page"
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let queuedStore = SharedQueueTestStore(snapshot: QueuedTurnProfileSnapshot(
            profileID: appStore.notificationRoutingProfileID,
            queuesBySessionID: [session.id: [QueuedTurnEntry(
                sessionID: session.id,
                projectID: project.id,
                payload: CodexAppServerTurnPayload(prompt: "older persisted message"),
                clientMessageID: clientMessageID,
                intent: .standard,
                dispatchState: .dispatching,
                serverSubmissionID: "submission-on-older-page"
            )]]
        ))
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            historyPages: [session.id: HistoryMessagesPage(
                messages: [CodexHistoryMessage(
                    role: "assistant",
                    content: "newer page",
                    createdAt: Date(timeIntervalSince1970: 2),
                    turnID: "turn-newer"
                )],
                previousCursor: "older-page",
                hasMoreBefore: true
            )],
            historyCursorPages: ["older-page": HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    role: "user",
                    content: "older persisted message",
                    createdAt: Date(timeIntervalSince1970: 1),
                    clientMessageID: clientMessageID,
                    turnID: "turn-older"
                )
            ])]
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedStore,
            clientFactory: { client }
        )
        store.sessions = [session]

        await store.reconcilePersistedQueuedTurns()

        XCTAssertTrue((store.queuedRunningTurnsBySessionID[session.id] ?? []).isEmpty)
        XCTAssertEqual(client.requestedMessageCursors.count, 2)
        XCTAssertNil(client.requestedMessageCursors[0])
        XCTAssertEqual(client.requestedMessageCursors[1], "older-page")
    }

    func testServerQueueACKDoesNotMarkSentWhenReceiptPersistenceFails() throws {
        let appStore = makeIsolatedAppStore()
        let sessionID = "shared-save-failure"
        let clientMessageID = "client-save-failure"
        let queuedStore = SharedQueueTestStore(
            snapshot: QueuedTurnProfileSnapshot(
                profileID: appStore.notificationRoutingProfileID,
                queuesBySessionID: [:]
            ),
            saveError: SharedQueueTestStoreError.saveFailed
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            queuedTurnStore: queuedStore
        )
        conversationStore.appendLocalUser(
            "must remain sending",
            sessionID: sessionID,
            clientMessageID: clientMessageID,
            sendStatus: .sending
        )
        store.queuedRunningTurnsBySessionID[sessionID] = [QueuedTurnEntry(
            sessionID: sessionID,
            payload: CodexAppServerTurnPayload(prompt: "must remain sending"),
            clientMessageID: clientMessageID,
            intent: .standard,
            dispatchState: .dispatching
        )]

        store.handleTurnSendOutcome(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            outcome: .serverQueued(submissionID: "submission-not-persisted", startedTurnID: nil)
        )
        XCTAssertNil(store.queuedRunningTurnsBySessionID[sessionID]?.first?.serverSubmissionID)
        XCTAssertEqual(conversationStore.messages(for: sessionID).first?.sendStatus, .sending)
    }

    func testMatchingStartedCompletesAfterACKReceiptPersistenceFailure() throws {
        let appStore = makeIsolatedAppStore()
        let sessionID = "shared-save-recovery"
        let clientMessageID = "client-save-recovery"
        let queuedStore = SharedQueueTestStore(
            snapshot: QueuedTurnProfileSnapshot(
                profileID: appStore.notificationRoutingProfileID,
                queuesBySessionID: [:]
            ),
            saveError: SharedQueueTestStoreError.saveFailed,
            saveErrorCallNumbers: [1]
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            queuedTurnStore: queuedStore
        )
        conversationStore.appendLocalUser(
            "started is stronger than ACK",
            sessionID: sessionID,
            clientMessageID: clientMessageID,
            sendStatus: .sending
        )
        store.queuedRunningTurnsBySessionID[sessionID] = [QueuedTurnEntry(
            sessionID: sessionID,
            payload: CodexAppServerTurnPayload(prompt: "started is stronger than ACK"),
            clientMessageID: clientMessageID,
            intent: .standard,
            dispatchState: .dispatching
        )]

        store.handleTurnSendOutcome(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            outcome: .serverQueued(submissionID: "submission-not-persisted", startedTurnID: nil)
        )
        XCTAssertNil(store.queuedRunningTurnsBySessionID[sessionID]?.first?.serverSubmissionID)
        XCTAssertEqual(conversationStore.messages(for: sessionID).first?.sendStatus, .sending)
        XCTAssertFalse(store.handleServerQueueTurnStarted(
            clientMessageID: "another-client",
            sessionID: sessionID,
            turnID: "another-turn"
        ))
        XCTAssertTrue(store.handleServerQueueTurnStarted(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            turnID: "turn-save-recovery"
        ))

        XCTAssertTrue((store.queuedRunningTurnsBySessionID[sessionID] ?? []).isEmpty)
        let message = try XCTUnwrap(conversationStore.messages(for: sessionID).first)
        XCTAssertEqual(message.sendStatus, .sent)
        XCTAssertEqual(message.turnID, "turn-save-recovery")
        XCTAssertEqual(queuedStore.saveCallCount, 2)
    }

    func testReconciledStartedReceiptFinishesQueueAfterDurableSave() throws {
        let appStore = makeIsolatedAppStore()
        let sessionID = "shared-reconciled-start"
        let clientMessageID = "client-reconciled-start"
        let queuedStore = SharedQueueTestStore(snapshot: QueuedTurnProfileSnapshot(
            profileID: appStore.notificationRoutingProfileID,
            queuesBySessionID: [:]
        ))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            queuedTurnStore: queuedStore
        )
        conversationStore.appendLocalUser(
            "already persisted by app-server",
            sessionID: sessionID,
            clientMessageID: clientMessageID,
            sendStatus: .sending
        )
        store.queuedRunningTurnsBySessionID[sessionID] = [QueuedTurnEntry(
            sessionID: sessionID,
            payload: CodexAppServerTurnPayload(prompt: "already persisted by app-server"),
            clientMessageID: clientMessageID,
            intent: .standard,
            dispatchState: .dispatching
        )]

        store.handleTurnSendOutcome(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            outcome: .serverQueued(
                submissionID: "reconciled:client-reconciled-start",
                startedTurnID: "turn-reconciled-start"
            )
        )

        XCTAssertTrue((store.queuedRunningTurnsBySessionID[sessionID] ?? []).isEmpty)
        let message = try XCTUnwrap(conversationStore.messages(for: sessionID).first)
        XCTAssertEqual(message.sendStatus, .sent)
        XCTAssertEqual(message.turnID, "turn-reconciled-start")
        XCTAssertEqual(queuedStore.saveCallCount, 1)
    }

    func testQueuedInitialInputContinuesAfterSelectionChangesDuringCreate() async throws {
        let project = makeProject(id: "shared-create-switch")
        let selected = makeSession(
            id: "selected-thread",
            projectID: project.id,
            title: "Selected",
            status: "history",
            source: "codex"
        )
        let created = makeSession(
            id: "created-shared-thread",
            projectID: project.id,
            title: "Created",
            status: "running",
            source: "codex"
        )
        let client = DelayedCreateSessionClient(projects: [project], sessions: [selected])
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
                socket.turnDeliveryMode = .sharedServerQueue
                sockets.append(socket)
                return socket
            }
        )
        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(selected)

        let createTask = Task {
            await store.createSession(
                projectID: project.id,
                prompt: "queued after switch",
                resume: nil,
                clientMessageID: "client-create-switch"
            )
        }
        await client.waitForCreateRequestCount(1)
        await store.selectSession(selected)
        client.resolveCreate(with: .success(CreateSessionResponse(
            session: created,
            wsURL: "/api/app-server/ws?thread_id=\(created.id)",
            requiresQueuedInitialInput: true
        )))
        let didCreate = await createTask.value
        XCTAssertTrue(didCreate)
        XCTAssertEqual(store.selectedSessionID, selected.id)

        let queueSocket = try await waitForSocketConnected(to: created.id, sockets: sockets)
        queueSocket.emitStatus(.connected)
        try await waitForSentTurnCount(1, socket: queueSocket)
        XCTAssertEqual(queueSocket.sentTurns.first?.clientMessageID, "client-create-switch")
    }

    func testUnknownPrivateRequestAndResolutionDoNotCloseKnownApproval() async throws {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let known = CodexAppServerServerRequest(
            id: .string("known-request"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-approval"),
                "turnId": .string("turn-known"),
                "itemId": .string("known-item")
            ])
        )
        await runtime.rememberPendingApprovalRequest(known)
        let privateRequest = CodexAppServerServerRequest(
            id: .string("private-request"),
            method: "codexDesktop/privateRequest",
            params: .object(["threadId": .string("thread-approval")])
        )
        await runtime.handle(privateRequest)

        let unknownResolved = CodexAppServerNotification(
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string("thread-approval"),
                "requestId": .string("private-request")
            ])
        )
        let clearedUnknown = await runtime.clearResolvedServerRequest(from: unknownResolved)
        XCTAssertTrue(clearedUnknown.approvalSessionIDs.isEmpty)
        XCTAssertTrue(clearedUnknown.userInputSessionIDs.isEmpty)
        let pendingAfterUnknown = await runtime.pendingApprovalRequestsByID
        XCTAssertFalse(pendingAfterUnknown.isEmpty)

        let knownResolved = CodexAppServerNotification(
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string("thread-approval"),
                "requestId": .string("known-request")
            ])
        )
        let clearedKnown = await runtime.clearResolvedServerRequest(from: knownResolved)
        XCTAssertEqual(clearedKnown.approvalSessionIDs, ["thread-approval"])
        let pendingAfterKnown = await runtime.pendingApprovalRequestsByID
        XCTAssertTrue(pendingAfterKnown.isEmpty)
    }

    func testHistoryAndQueueBuildersUseOnlyPaginatedPublicMethods() throws {
        let project = AgentProject(id: "builder", name: "Builder", path: "/tmp/builder")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        XCTAssertEqual(builder.threadRead(threadID: "thread").params?.objectValue?["includeTurns"]?.boolValue, false)
        let turns = builder.threadTurnsList(threadID: "thread", cursor: "turn-cursor")
        XCTAssertEqual(turns.method, "thread/turns/list")
        XCTAssertEqual(turns.params?.objectValue?["cursor"]?.stringValue, "turn-cursor")
        let items = builder.threadItemsList(threadID: "thread", cursor: "item-cursor")
        XCTAssertEqual(items.method, "thread/items/list")
        XCTAssertEqual(items.params?.objectValue?["cursor"]?.stringValue, "item-cursor")
        XCTAssertEqual(items.params?.objectValue?["sortDirection"]?.stringValue, "desc")
    }

    func testSharedResumeBuilderValidatesCWDAndPreservesThreadPermissions() throws {
        let project = AgentProject(id: "builder", name: "Builder", path: "/tmp/builder")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        let resume = try builder.threadResumePreservingSharedState(
            threadID: "thread",
            cwd: project.path,
            includeInitialTurnsPage: false
        )
        let params = try XCTUnwrap(resume.params?.objectValue)
        XCTAssertEqual(
            Set(params.keys),
            ["threadId", "cwd", "excludeTurns", "mimiPreserveThreadPermissions"]
        )
        XCTAssertEqual(params["cwd"]?.stringValue, project.path)
        XCTAssertEqual(params["mimiPreserveThreadPermissions"]?.boolValue, true)
        XCTAssertThrowsError(try builder.threadResumePreservingSharedState(
            threadID: "thread",
            cwd: "/tmp/not-allowlisted"
        )) { error in
            XCTAssertEqual(
                error as? CodexAppServerRequestBuilderError,
                .pathNotAllowlisted("/tmp/not-allowlisted")
            )
        }
    }
}

private func makeSharedSSHConfig(project: AgentProject) -> CodexAppServerConfigResponse {
    CodexAppServerConfigResponse(
        gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws",
        runtime: CodexAppServerRuntimeMetadata(
            type: "codex_app_server",
            transport: "ssh",
            managed: false,
            gatewayAvailable: true,
            upstreamConfigured: true,
            running: true,
            initialized: false,
            pendingRequests: 0
        ),
        projects: [project],
        policy: CodexAppServerPolicyMetadata(
            allowedMethods: [
                "initialize", "initialized", "thread/start", "thread/resume", "thread/read",
                "thread/turns/list", "thread/items/list", "thread/settings/update",
                "thread/queue/add", "thread/queue/list"
            ],
            projectsSource: "agentd_allowlist"
        )
    )
}

private func appServerRequests(_ transport: FakeCodexAppServerTransport) async -> [CodexAppServerRequest] {
    await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
}

private func respondToSharedSettingsUpdate(
    _ transport: FakeCodexAppServerTransport,
    after startIndex: Int = 0
) async throws {
    let settings = try await waitForFakeAppServerRequest(
        transport,
        method: "thread/settings/update",
        after: startIndex
    )
    let requestsBeforeSettingsACK = await appServerRequests(transport)
    XCTAssertFalse(requestsBeforeSettingsACK.contains { request in
        request.method == "thread/queue/add"
    })
    transportResponse(transport, id: settings.id, result: #"{}"#)
}

@MainActor
private func waitForSelectedQueueToBecomeEmpty(store: SessionStore) async throws {
    for _ in 0..<80 {
        if store.selectedQueuedTurns.isEmpty {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("精确 userMessage item/started 未完成 server queue 队首")
}

@MainActor
private func waitForSelectedQueueHead(
    _ clientMessageID: ClientMessageID,
    store: SessionStore
) async throws {
    for _ in 0..<80 {
        if store.selectedQueuedTurns.first?.clientMessageID == clientMessageID {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("server queue 队首未在超时前变为 \(clientMessageID)")
}

@MainActor
private func waitForSocketConnected(
    to sessionID: SessionID,
    sockets: [MockWebSocketClient]
) async throws -> MockWebSocketClient {
    for _ in 0..<80 {
        if let socket = sockets.first(where: { $0.connectedSessionIDs.contains(sessionID) }) {
            return socket
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("未为已切离的新会话建立队列监听")
    throw MockError.timeout
}

private enum SharedQueueTestStoreError: Error {
    case saveFailed
}

private final class SharedQueueTestStore: QueuedTurnPersisting {
    private let snapshot: QueuedTurnProfileSnapshot
    private let saveError: Error?
    private let saveErrorCallNumbers: Set<Int>?
    private(set) var saveCallCount = 0

    init(
        snapshot: QueuedTurnProfileSnapshot,
        saveError: Error? = nil,
        saveErrorCallNumbers: Set<Int>? = nil
    ) {
        self.snapshot = snapshot
        self.saveError = saveError
        self.saveErrorCallNumbers = saveErrorCallNumbers
    }

    func load(profileID: String) throws -> QueuedTurnProfileSnapshot {
        snapshot
    }

    func save(_ snapshot: QueuedTurnProfileSnapshot) throws {
        saveCallCount += 1
        if let saveError,
           saveErrorCallNumbers?.contains(saveCallCount) ?? true {
            throw saveError
        }
    }

    func remove(profileID: String) throws {}
}

private func initializeFakeTransport(_ transport: FakeCodexAppServerTransport) async throws {
    let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
    transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
}

private func sharedIdleThreadJSON(id: String, cwd: String) -> String {
    #"{"thread":{"id":"\#(id)","sessionId":"\#(id)","preview":"idle","ephemeral":false,"modelProvider":"openai","createdAt":1,"updatedAt":2,"status":{"type":"idle"},"cwd":"\#(cwd)","source":"appServer","threadSource":"user","turns":[]}}"#
}

@MainActor
private func prepareEmptySharedThread(
    runtime: CodexAppServerSessionRuntime,
    pool: FakeCodexAppServerTransportPool,
    project: AgentProject,
    id: String = "thread-reconcile"
) async throws -> FakeCodexAppServerTransport {
    let createTask = Task {
        try await runtime.createSession(CreateSessionRequest(
            projectID: project.id,
            prompt: "",
            resumeID: "",
            clientMessageID: nil
        ))
    }
    let transport = try await waitForFakeAppServerTransport(in: pool, index: 0)
    try await initializeFakeTransport(transport)
    let start = try await waitForFakeAppServerRequest(transport, method: "thread/start")
    transportResponse(transport, id: start.id, result: sharedIdleThreadJSON(id: id, cwd: project.path))
    _ = try await createTask.value
    return transport
}
