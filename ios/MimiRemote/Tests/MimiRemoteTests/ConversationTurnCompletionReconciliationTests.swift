import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testFinalAssistantMessageReconcilesCompletedActiveTurnAndDispatchesQueuedTurn() async throws {
        let fixture = try await makeTurnCompletionReconciliationFixture(
            suffix: "completed",
            authoritativeTurnID: "turn-active",
            lifecycle: .completed
        )

        fixture.socket.emitEvent(fixture.messageCompleted(kind: .message))

        try await waitForSentTurnCount(1, socket: fixture.socket)
        XCTAssertEqual(fixture.socket.sentTurns.first?.payload.textPrompt, "排队下一轮")
        XCTAssertNil(fixture.store.selectedSession?.activeTurnID)
        XCTAssertEqual(fixture.store.selectedSession?.status, SessionStatus.completed.rawValue)
    }

    func testFinalAssistantMessageDoesNotDispatchWhenActiveTurnIsStillInProgress() async throws {
        let fixture = try await makeTurnCompletionReconciliationFixture(
            suffix: "in-progress",
            authoritativeTurnID: "turn-active",
            lifecycle: .inProgress
        )

        fixture.socket.emitEvent(fixture.messageCompleted(kind: .message))
        try await waitForLatestTurnReconciliationRequest(fixture.client)

        XCTAssertTrue(fixture.socket.sentTurns.isEmpty)
        XCTAssertEqual(fixture.store.selectedSession?.activeTurnID, "turn-active")
        XCTAssertEqual(fixture.store.selectedQueuedTurns.first?.dispatchState, .waiting)
    }

    func testFinalAssistantMessageDoesNotDispatchWhenTerminalHistoryBelongsToAnotherTurn() async throws {
        let fixture = try await makeTurnCompletionReconciliationFixture(
            suffix: "other-turn",
            authoritativeTurnID: "turn-other",
            lifecycle: .completed
        )

        fixture.socket.emitEvent(fixture.messageCompleted(kind: .message))
        try await waitForLatestTurnReconciliationRequest(fixture.client)

        XCTAssertTrue(fixture.socket.sentTurns.isEmpty)
        XCTAssertEqual(fixture.store.selectedSession?.activeTurnID, "turn-active")
        XCTAssertEqual(fixture.store.selectedQueuedTurns.first?.dispatchState, .waiting)
    }

    func testCommentaryMessageCompletedDoesNotStartTurnCompletionReconciliation() async throws {
        let fixture = try await makeTurnCompletionReconciliationFixture(
            suffix: "commentary",
            authoritativeTurnID: "turn-active",
            lifecycle: .completed
        )
        let initialLatestTurnRequestCount = fixture.client.requestedMessageLimits.filter { $0 == 1 }.count

        fixture.socket.emitEvent(fixture.messageCompleted(kind: .commentary))
        try await waitForConversationMessage(
            id: "assistant-commentary",
            sessionID: fixture.sessionID,
            store: fixture.store
        )

        XCTAssertEqual(
            fixture.client.requestedMessageLimits.filter { $0 == 1 }.count,
            initialLatestTurnRequestCount
        )
        XCTAssertTrue(fixture.socket.sentTurns.isEmpty)
        XCTAssertEqual(fixture.store.selectedSession?.activeTurnID, "turn-active")
    }

    func testTurnCompletionReconciliationRetriesUntilHistoryBecomesTerminal() async throws {
        let history = LatestTurnHistorySequence(pages: [
            makeTurnCompletionHistoryPage(turnID: "turn-active", lifecycle: .inProgress),
            makeTurnCompletionHistoryPage(turnID: "turn-active", lifecycle: .completed),
        ])
        let fixture = try await makeTurnCompletionReconciliationFixture(
            suffix: "eventually-completed",
            authoritativeTurnID: "turn-active",
            lifecycle: .inProgress,
            reconciliationDelays: [0, 0],
            latestTurnHistoryHandler: { _ in await history.next() }
        )

        fixture.socket.emitEvent(fixture.messageCompleted(kind: .message))

        try await waitForSentTurnCount(1, socket: fixture.socket)
        let requestCount = await history.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertNil(fixture.store.selectedSession?.activeTurnID)
    }

    func testForegroundResumeRestartsCancelledTurnCompletionReconciliation() async throws {
        let history = LatestTurnHistorySequence(pages: [
            makeTurnCompletionHistoryPage(turnID: "turn-active", lifecycle: .completed),
        ])
        let fixture = try await makeTurnCompletionReconciliationFixture(
            suffix: "foreground-resume",
            authoritativeTurnID: "turn-active",
            lifecycle: .inProgress,
            reconciliationDelays: [1_000_000_000],
            latestTurnHistoryHandler: { _ in await history.next() }
        )
        fixture.socket.emitEvent(fixture.messageCompleted(kind: .message))
        try await waitForConversationMessage(
            id: "assistant-final",
            sessionID: fixture.sessionID,
            store: fixture.store
        )
        XCTAssertNotNil(fixture.store.turnCompletionReconciliationJobsBySessionID[fixture.sessionID])

        fixture.store.suspendForBackground()
        XCTAssertTrue(fixture.store.turnCompletionReconciliationJobsBySessionID.isEmpty)
        fixture.store.turnCompletionReconciliationDelaysNanoseconds = [0]
        await fixture.store.resumeFromForeground()

        let resumedSocket = try XCTUnwrap(fixture.store.webSocket as? MockWebSocketClient)
        resumedSocket.emitStatus(.connected)
        try await waitForSentTurnCount(1, socket: resumedSocket)
        let requestCount = await history.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(fixture.store.selectedSession?.activeTurnID)
    }
}

@MainActor
private struct TurnCompletionReconciliationFixture {
    let sessionID: SessionID
    let client: MockSessionStoreClient
    let socket: MockWebSocketClient
    let store: SessionStore

    func messageCompleted(kind: MessageKind) -> AgentEvent {
        .messageCompleted(
            AgentMessage(
                id: kind == .commentary ? "assistant-commentary" : "assistant-final",
                sessionID: sessionID,
                turnID: "turn-active",
                itemID: kind == .commentary ? "item-commentary" : "item-final",
                role: .assistant,
                kind: kind,
                content: kind == .commentary ? "正在处理。" : "处理完成。"
            ),
            AgentEventMetadata(
                seq: 10,
                sessionID: sessionID,
                turnID: "turn-active",
                itemID: kind == .commentary ? "item-commentary" : "item-final",
                messageID: kind == .commentary ? "assistant-commentary" : "assistant-final",
                clientMessageID: nil,
                revision: 1,
                createdAt: Date(timeIntervalSince1970: 10)
            )
        )
    }
}

@MainActor
private extension ConversationDataFlowTests {
    func makeTurnCompletionReconciliationFixture(
        suffix: String,
        authoritativeTurnID: TurnID,
        lifecycle: ConversationTurnLifecycle,
        reconciliationDelays: [UInt64] = [0],
        latestTurnHistoryHandler: ((String) async throws -> HistoryMessagesPage?)? = nil
    ) async throws -> TurnCompletionReconciliationFixture {
        let project = makeProject(id: "proj-reconcile-\(suffix)")
        let session = makeSession(
            id: "sess-reconcile-\(suffix)",
            projectID: project.id,
            title: "Turn completion reconciliation",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn-active"
        )
        let authoritativePage = makeTurnCompletionHistoryPage(
            turnID: authoritativeTurnID,
            lifecycle: lifecycle
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            messagesResult: [],
            historyPages: [session.id: authoritativePage],
            latestTurnHistoryHandler: latestTurnHistoryHandler
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
        store.turnCompletionReconciliationDelaysNanoseconds = reconciliationDelays

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(session)
        await store.selectSession(session)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "排队下一轮"))
        XCTAssertTrue(queued)
        XCTAssertTrue(socket.sentTurns.isEmpty)
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .waiting)

        return TurnCompletionReconciliationFixture(
            sessionID: session.id,
            client: client,
            socket: socket,
            store: store
        )
    }
}

private func makeTurnCompletionHistoryPage(
    turnID: TurnID,
    lifecycle: ConversationTurnLifecycle
) -> HistoryMessagesPage {
    HistoryMessagesPage(messages: [
        CodexHistoryMessage(
            id: "history-\(turnID)-\(lifecycle.rawValue)",
            role: "assistant",
            content: "权威历史",
            createdAt: Date(timeIntervalSince1970: 9),
            turnID: turnID,
            itemID: "history-item",
            turnLifecycle: lifecycle
        )
    ])
}

private actor LatestTurnHistorySequence {
    private let pages: [HistoryMessagesPage]
    private var index = 0

    init(pages: [HistoryMessagesPage]) {
        self.pages = pages
    }

    func next() -> HistoryMessagesPage? {
        guard !pages.isEmpty else { return nil }
        let page = pages[min(index, pages.count - 1)]
        index += 1
        return page
    }

    func requestCount() -> Int {
        index
    }
}

@MainActor
private func waitForLatestTurnReconciliationRequest(_ client: MockSessionStoreClient) async throws {
    for _ in 0..<80 {
        if client.requestedMessageLimits.contains(where: { $0 == 1 }) {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("latest-turn 对账请求未在超时前发出")
}

@MainActor
private func waitForConversationMessage(
    id: MessageID,
    sessionID: SessionID,
    store: SessionStore
) async throws {
    for _ in 0..<80 {
        if store.conversationStore.messages(for: sessionID).contains(where: { $0.stableID == id }) {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("消息 \(id) 未在超时前写入会话")
}

// MARK: - turn 完成但回复正文缺失时的兜底补读

@MainActor
extension ConversationDataFlowTests {
    private struct MissingReplyBackfillFixture {
        let store: SessionStore
        let client: MockSessionStoreClient
        let conversationStore: ConversationStore
        let socket: MockWebSocketClient
        let session: AgentSession

        func turnMetadata(turnID: String, seq: EventSequence, lifecycle: ConversationTurnLifecycle? = nil) -> AgentEventMetadata {
            let metadata = AgentEventMetadata(
                seq: seq, sessionID: session.id, turnID: turnID, itemID: nil, messageID: nil,
                clientMessageID: nil, revision: Int(seq), createdAt: nil
            )
            guard let lifecycle else { return metadata }
            return metadata.withTurnLifecycle(lifecycle)
        }

        func assistantReply(turnID: String, seq: EventSequence) throws -> AgentEvent {
            let message = try AgentAPIClient.decoder.decode(
                AgentMessage.self,
                from: Data("""
                {
                  "id": "appserver:\(turnID):item-1",
                  "session_id": "\(session.id)",
                  "turn_id": "\(turnID)",
                  "item_id": "item-1",
                  "role": "assistant",
                  "kind": "message",
                  "content": "收到，消息正常。",
                  "created_at": "2026-09-10T03:32:35Z",
                  "revision": \(seq),
                  "send_status": "confirmed"
                }
                """.utf8)
            )
            return .messageCompleted(
                message,
                AgentEventMetadata(
                    seq: seq, sessionID: session.id, turnID: turnID, itemID: "item-1",
                    messageID: message.id, clientMessageID: nil, revision: Int(seq), createdAt: nil
                )
            )
        }
    }

    private func makeMissingReplyBackfillFixture(suffix: String) async throws -> MissingReplyBackfillFixture {
        let project = makeProject(id: "proj_backfill_\(suffix)")
        let running = makeSession(
            id: "sess_backfill_\(suffix)", projectID: project.id, title: "运行中",
            status: "running", source: "codex"
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
        return MissingReplyBackfillFixture(
            store: store, client: client, conversationStore: conversationStore, socket: socket, session: running
        )
    }

    private func settleMissingReplyBackfill() async throws {
        try await Task.sleep(nanoseconds: SessionStore.missingAssistantReplyBackfillDelayNanoseconds + 600_000_000)
    }

    /// 网关在断线窗口丢掉了 assistant 正文、只剩 turn/completed 到达：完成事件本身不经水位线，
    /// 本地却没有该 turn 的回复。此时必须自动做一次权威补读，而不是等用户点刷新。
    func testTurnCompletedWithoutAssistantReplyTriggersAuthoritativeHistoryBackfill() async throws {
        let fixture = try await makeMissingReplyBackfillFixture(suffix: "missing")
        let historyReadsBefore = fixture.client.requestedMessageSessionIDs.count

        fixture.socket.emitEvent(.turnStarted(fixture.turnMetadata(turnID: "turn-1", seq: 1)))
        fixture.socket.emitEvent(.turnCompleted(fixture.turnMetadata(turnID: "turn-1", seq: 2, lifecycle: .completed)))
        try await settleMissingReplyBackfill()

        XCTAssertEqual(
            fixture.client.requestedMessageSessionIDs.count, historyReadsBefore + 1,
            "turn 完成却没有回复正文时，应自动补读一次权威历史"
        )
        XCTAssertEqual(fixture.client.requestedMessageSessionIDs.last, fixture.session.id)
    }

    func testTurnCompletedAfterAssistantReplyDoesNotBackfillHistory() async throws {
        let fixture = try await makeMissingReplyBackfillFixture(suffix: "present")
        let historyReadsBefore = fixture.client.requestedMessageSessionIDs.count

        fixture.socket.emitEvent(.turnStarted(fixture.turnMetadata(turnID: "turn-1", seq: 1)))
        fixture.socket.emitEvent(try fixture.assistantReply(turnID: "turn-1", seq: 2))
        fixture.socket.emitEvent(.turnCompleted(fixture.turnMetadata(turnID: "turn-1", seq: 3, lifecycle: .completed)))
        try await settleMissingReplyBackfill()

        XCTAssertTrue(
            fixture.conversationStore.messages(for: fixture.session.id).contains { $0.role == .assistant && $0.content == "收到，消息正常。" }
        )
        XCTAssertEqual(
            fixture.client.requestedMessageSessionIDs.count, historyReadsBefore,
            "回复正文已经在本地时不应产生额外的历史读取"
        )
    }

    func testInterruptedTurnWithoutAssistantReplyDoesNotBackfillHistory() async throws {
        let fixture = try await makeMissingReplyBackfillFixture(suffix: "interrupted")
        let historyReadsBefore = fixture.client.requestedMessageSessionIDs.count

        fixture.socket.emitEvent(.turnStarted(fixture.turnMetadata(turnID: "turn-1", seq: 1)))
        fixture.socket.emitEvent(.turnCompleted(fixture.turnMetadata(turnID: "turn-1", seq: 2, lifecycle: .interrupted)))
        try await settleMissingReplyBackfill()

        XCTAssertEqual(
            fixture.client.requestedMessageSessionIDs.count, historyReadsBefore,
            "用户中断的 turn 本来就没有回复，不应补读"
        )
    }
}
