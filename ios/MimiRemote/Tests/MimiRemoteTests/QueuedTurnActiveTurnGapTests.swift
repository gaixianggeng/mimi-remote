import XCTest
@testable import MimiRemote

/// #751：回合进行中本地丢了 activeTurnID 时，「排队」消息被当成空闲立即 turn/start，
/// Codex 0.163 把它插进当前回合，原任务的回复丢失。
@MainActor
final class QueuedTurnActiveTurnGapTests: XCTestCase {
    func testThreadListEmptyTurnsKeepsRuntimeActiveTurnOfRunningThread() async throws {
        let project = AgentProject(id: "turn-gap-runtime", name: "Turn gap", path: "/tmp/turn-gap-runtime")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        // Codex 的 thread/list 恒带 `turns: []`：只有 resume/fork/read(includeTurns) 才填充。
        let runningRow = appServerThreadJSON(
            id: "thr_turn_gap",
            cwd: project.path,
            source: "appServer",
            updatedAt: 1_780_490_900,
            statusType: "active"
        )
        let firstList = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake","platformFamily":"macos"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list")
        transportResponse(transport, id: list.id, result: appServerThreadListResult([runningRow], nextCursor: nil))
        _ = try await firstList.value

        await runtime.handle(try decodeAppServerNotification(
            #"{"method":"turn/started","params":{"threadId":"thr_turn_gap","turn":{"id":"turn_sleep","status":"inProgress"}}}"#
        ))
        let activeBeforeRefresh = await runtime.contextsBySessionID["thr_turn_gap"]?.activeTurnID
        XCTAssertEqual(activeBeforeRefresh, "turn_sleep")

        let sentBeforeRefresh = await transport.sentMessages().count
        let refresh = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let relist = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: sentBeforeRefresh)
        transportResponse(transport, id: relist.id, result: appServerThreadListResult([runningRow], nextCursor: nil))
        let page = try await refresh.value

        XCTAssertEqual(page.sessions.first?.status, SessionStatus.running.rawValue)
        XCTAssertEqual(page.sessions.first?.activeTurnID, "turn_sleep")
        let activeAfterRefresh = await runtime.contextsBySessionID["thr_turn_gap"]?.activeTurnID
        XCTAssertEqual(activeAfterRefresh, "turn_sleep", "运行时缓存丢 turn 后 turn/start 不再报 activeTurnConflict")
    }

    func testRunningListSnapshotKeepsConnectedActiveTurnSoQueuedTurnWaits() async throws {
        let fixture = try await makeConnectedFixture(suffix: "list", activeTurnID: "turn_sleep")
        let store = fixture.store
        let socket = fixture.socket

        store.mergeSessionPage([fixture.session.withActiveTurnID(nil)])
        XCTAssertEqual(store.selectedSession?.activeTurnID, "turn_sleep")

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "Stop waiting and say hi."))
        XCTAssertTrue(queued)
        XCTAssertTrue(socket.sentTurns.isEmpty)
        XCTAssertEqual(store.selectedQueuedTurns.first?.expectedTurnID, "turn_sleep")
        XCTAssertEqual(store.statusMessage, L10n.text("ui.saved_to_this_machine_and_will_be_sent"))

        socket.emitEvent(.turnCompleted(turnMetadata(sessionID: fixture.session.id, turnID: "turn_sleep", seq: 1)))
        try await waitForSentTurnCount(1, socket: socket)
        XCTAssertEqual(socket.sentTurns.first?.payload.textPrompt, "Stop waiting and say hi.")
    }

    func testGuideQueuedTurnNowStillSteersAfterRunningListSnapshot() async throws {
        let fixture = try await makeConnectedFixture(suffix: "guide", activeTurnID: "turn_sleep")
        let store = fixture.store
        let socket = fixture.socket

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "改成立即引导"))
        XCTAssertTrue(queued)
        store.mergeSessionPage([fixture.session.withActiveTurnID(nil)])
        let clientMessageID = try XCTUnwrap(store.selectedQueuedTurns.first?.clientMessageID)

        XCTAssertTrue(store.guideQueuedTurnNow(clientMessageID: clientMessageID))
        XCTAssertEqual(socket.sentGuidance.map(\.expectedTurnID), ["turn_sleep"])
        XCTAssertTrue(socket.sentTurns.isEmpty)
    }

    func testQueuedTurnWaitsForInProgressTurnWhenRunningSessionLostActiveTurn() async throws {
        let fixture = try await makeConnectedFixture(
            suffix: "in-progress",
            activeTurnID: nil,
            latestTurn: HistoryTurnState(id: "turn_sleep", lifecycle: .inProgress)
        )
        let store = fixture.store
        let socket = fixture.socket

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "Stop waiting and say hi."))
        XCTAssertTrue(queued)
        XCTAssertEqual(store.statusMessage, L10n.text("ui.saved_to_this_machine_and_will_be_sent"))
        try await waitForSelectedActiveTurnID("turn_sleep", store: store)
        XCTAssertTrue(socket.sentTurns.isEmpty, "进行中的回合里不能发 turn/start")
        XCTAssertEqual(store.selectedQueuedTurns.first?.expectedTurnID, "turn_sleep")
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .waiting)

        socket.emitEvent(.turnCompleted(turnMetadata(sessionID: fixture.session.id, turnID: "turn_sleep", seq: 1)))
        try await waitForSentTurnCount(1, socket: socket)
        XCTAssertEqual(socket.sentTurns.first?.payload.textPrompt, "Stop waiting and say hi.")
    }

    func testQueuedTurnDispatchesWhenLostActiveTurnIsAuthoritativelyTerminal() async throws {
        let fixture = try await makeConnectedFixture(
            suffix: "terminal",
            activeTurnID: nil,
            latestTurn: HistoryTurnState(id: "turn_finished", lifecycle: .completed)
        )
        let store = fixture.store
        let socket = fixture.socket

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "完成通知丢了也要继续"))
        XCTAssertTrue(queued)
        try await waitForSentTurnCount(1, socket: socket)
        XCTAssertEqual(socket.sentTurns.first?.payload.textPrompt, "完成通知丢了也要继续")
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)
    }

    func testQueuedTurnKeepsIdleDispatchWhenRuntimeCannotReadLatestTurn() async throws {
        let fixture = try await makeConnectedFixture(
            suffix: "unsupported",
            activeTurnID: nil,
            supportsLatestTurnHistoryPage: false
        )

        let queued = await fixture.store.sendTurn(CodexAppServerTurnPayload(prompt: "无法确认时保持原行为"))
        XCTAssertTrue(queued)
        try await waitForSentTurnCount(1, socket: fixture.socket)
    }

    private struct ConnectedFixture {
        let session: AgentSession
        let store: SessionStore
        let socket: MockWebSocketClient
    }

    private func makeConnectedFixture(
        suffix: String,
        activeTurnID: TurnID?,
        latestTurn: HistoryTurnState? = nil,
        supportsLatestTurnHistoryPage: Bool = true
    ) async throws -> ConnectedFixture {
        let project = makeProject(id: "proj-turn-gap-\(suffix)")
        let session = makeSession(
            id: "sess-turn-gap-\(suffix)",
            projectID: project.id,
            title: "Turn gap",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: activeTurnID
        )
        let latestPage = HistoryMessagesPage(messages: [], turnStates: latestTurn.map { [$0] } ?? [])
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            messagesResult: [],
            supportsLatestTurnHistoryPage: supportsLatestTurnHistoryPage,
            latestTurnHistoryHandler: { _ in latestPage }
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
        store.turnCompletionReconciliationDelaysNanoseconds = [0]
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(session)
        await store.selectSession(session)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        return ConnectedFixture(session: session, store: store, socket: socket)
    }

    private func turnMetadata(sessionID: SessionID, turnID: TurnID, seq: EventSequence) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: seq,
            sessionID: sessionID,
            turnID: turnID,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )
    }
}

private extension AgentSession {
    func withActiveTurnID(_ turnID: TurnID?) -> AgentSession {
        var copy = self
        copy.activeTurnID = turnID
        return copy
    }
}
