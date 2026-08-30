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
