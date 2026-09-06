import XCTest
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testQueuedTurnActiveConflictReturnsToWaitingWithoutFailingSession() async throws {
        let project = makeProject(id: "proj_active_conflict_queue")
        let staleIdle = makeSession(
            id: "sess_active_conflict_queue",
            projectID: project.id,
            title: "Stale Idle",
            status: "running",
            source: "claude"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [staleIdle], messagesResult: [])
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
        store.takeOverSession(staleIdle)
        await store.selectSession(staleIdle)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let didQueue = await store.sendTurn(CodexAppServerTurnPayload(prompt: "等旧任务完成后发送"))
        XCTAssertTrue(didQueue)
        let clientMessageID = try XCTUnwrap(sockets[0].sentTurns.first?.clientMessageID)
        sockets[0].onTurnSendOutcome?(
            clientMessageID,
            .activeTurnConflict(activeTurnID: "turn-live", message: "already active")
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertEqual(store.selectedSession?.activeTurnID, "turn-live")
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .waiting)
        XCTAssertEqual(store.selectedQueuedTurns.first?.expectedTurnID, "turn-live")
        XCTAssertEqual(
            conversationStore.messages(for: staleIdle.id).first { $0.clientMessageID == clientMessageID }?.sendStatus,
            .local
        )
        XCTAssertNil(store.errorMessage)
    }

    func testRunningSessionGuidedDeliverySteersActiveTurn() async throws {
        let project = makeProject(id: "proj_ws_guided")
        let running = makeSession(
            id: "sess_ws_guided",
            projectID: project.id,
            title: "Running",
            status: "running",
            source: "codex",
            activeTurnID: "turn_active_guided"
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "排队下一轮"))
        let guided = await store.sendTurn(CodexAppServerTurnPayload(prompt: "直接引导当前回复"), runningDelivery: .guided)

        XCTAssertTrue(queued)
        XCTAssertTrue(guided)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty, "排队消息不能在当前 turn 仍活跃时调用 turn/start")
        XCTAssertNil(conversationStore.messages(for: running.id).first { $0.content == "排队下一轮" })
        XCTAssertEqual(store.selectedQueuedTurns.map(\.previewText), ["排队下一轮"])
        XCTAssertEqual(sockets[0].sentGuidance.count, 1)
        XCTAssertEqual(sockets[0].sentGuidance.first?.payload.textPrompt, "直接引导当前回复")
        XCTAssertEqual(sockets[0].sentGuidance.first?.expectedTurnID, "turn_active_guided")

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_active_guided",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: sockets[0])
        XCTAssertEqual(sockets[0].sentTurns.first?.payload.textPrompt, "排队下一轮")
        XCTAssertEqual(
            conversationStore.messages(for: running.id).first { $0.content == "排队下一轮" }?.sendStatus,
            .sending
        )
    }

    func testRunningQueuedDeliverySendsOneMessageAfterEachCompletedTurn() async throws {
        let project = makeProject(id: "proj_ws_queue_sequence")
        let running = makeSession(
            id: "sess_ws_queue_sequence",
            projectID: project.id,
            title: "Running Queue",
            status: "running",
            source: "codex",
            activeTurnID: "turn_queue_1"
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let firstQueued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "下一轮第一条"))
        let secondQueued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "下一轮第二条"))
        XCTAssertTrue(firstQueued)
        XCTAssertTrue(secondQueued)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_stale_history",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty, "其他历史 turn 的完成事件不能放行队列")
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.running.rawValue)
        XCTAssertEqual(store.selectedSession?.activeTurnID, "turn_queue_1")

        let firstCompletion = AgentEvent.turnCompleted(AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: "turn_queue_1",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        ))
        sockets[0].emitEvent(firstCompletion)
        try await waitForSentTurnCount(1, socket: sockets[0])
        XCTAssertEqual(sockets[0].sentTurns.map(\.payload.textPrompt), ["下一轮第一条"])
        sockets[0].onSendAccepted?(sockets[0].sentTurns[0].clientMessageID)
        try await Task.sleep(nanoseconds: 60_000_000)

        // 重放相同完成事件不能把第二条也提前发送。
        sockets[0].emitEvent(firstCompletion)
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertEqual(sockets[0].sentTurns.count, 1)

        sockets[0].emitEvent(.turnStarted(AgentEventMetadata(
            seq: 3,
            sessionID: running.id,
            turnID: "turn_queue_2",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID("turn_queue_2", store: store)
        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 4,
            sessionID: running.id,
            turnID: "turn_queue_2",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(2, socket: sockets[0])
        XCTAssertEqual(sockets[0].sentTurns.map(\.payload.textPrompt), ["下一轮第一条", "下一轮第二条"])
    }

    func testTerminalBeforeStartACKImmediatelyAdvancesQueuedFIFO() async throws {
        let project = makeProject(id: "proj_terminal_before_ack_queue")
        let running = makeSession(
            id: "sess_terminal_before_ack_queue",
            projectID: project.id,
            title: "Terminal Before ACK",
            status: SessionStatus.running.rawValue,
            source: "claude",
            activeTurnID: "turn_existing"
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let acceptedFirst = await store.sendTurn(CodexAppServerTurnPayload(prompt: "快速第一条"))
        let acceptedSecond = await store.sendTurn(CodexAppServerTurnPayload(prompt: "紧接第二条"))
        XCTAssertTrue(acceptedFirst)
        XCTAssertTrue(acceptedSecond)
        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_existing",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: sockets[0])
        let firstClientMessageID = try XCTUnwrap(sockets[0].sentTurns.first?.clientMessageID)

        // Claude 的 completion 先到，随后 ACK 才确认这条消息已接受且已终态。
        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: "turn_fast",
            itemID: nil,
            messageID: nil,
            clientMessageID: firstClientMessageID,
            revision: nil,
            createdAt: nil
        )))
        try await Task.sleep(nanoseconds: 50_000_000)
        sockets[0].onTurnSendOutcome?(
            firstClientMessageID,
            .acceptedTerminal(turnID: "turn_fast")
        )

        try await waitForSentTurnCount(2, socket: sockets[0])
        XCTAssertEqual(
            sockets[0].sentTurns.map(\.payload.textPrompt),
            ["快速第一条", "紧接第二条"]
        )
        XCTAssertFalse(store.selectedQueuedTurns.first?.waitsForAcceptedTurnStart == true)
    }

    func testNewTurnBeforeOldACKBindsQueuedFIFOToNewestTurn() async throws {
        let project = makeProject(id: "proj_new_turn_before_old_ack")
        let running = makeSession(
            id: "sess_new_turn_before_old_ack",
            projectID: project.id,
            title: "New Turn Before Old ACK",
            status: SessionStatus.running.rawValue,
            source: "claude",
            activeTurnID: "turn_existing"
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let acceptedOldACKMessage = await store.sendTurn(CodexAppServerTurnPayload(prompt: "旧 ACK 消息"))
        let acceptedWaitingMessage = await store.sendTurn(CodexAppServerTurnPayload(prompt: "等待新轮次"))
        XCTAssertTrue(acceptedOldACKMessage)
        XCTAssertTrue(acceptedWaitingMessage)
        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_existing",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: sockets[0])
        let firstClientMessageID = try XCTUnwrap(sockets[0].sentTurns.first?.clientMessageID)
        sockets[0].emitEvent(.turnStarted(AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: "turn_newest",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID("turn_newest", store: store)
        // B 的完成先落地，随后旧的 superseded(A,B) outcome 才切到 MainActor。
        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 3,
            sessionID: running.id,
            turnID: "turn_newest",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID(nil, store: store)
        sockets[0].onTurnSendOutcome?(
            firstClientMessageID,
            .acceptedSuperseded(
                turnID: "turn_old_ack",
                activeTurnID: "turn_newest"
            )
        )
        try await waitForSentTurnCount(2, socket: sockets[0])
        XCTAssertNil(store.selectedSession?.activeTurnID, "迟到 superseded outcome 不得复活已完成的 B")
        XCTAssertEqual(sockets[0].sentTurns.last?.payload.textPrompt, "等待新轮次")
    }

    func testQueuedTurnPersistsAcrossStoreRestartAndAmbiguousDispatchRequiresConfirmation() async throws {
        let project = makeProject(id: "proj_queue_restart")
        let running = makeSession(
            id: "sess_queue_restart",
            projectID: project.id,
            title: "Queue Restart",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_before_restart"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueuedTurnRestartTests.\(UUID().uuidString)", isDirectory: true)
        let queuedTurnStore = FileQueuedTurnStore(directoryURL: directory)
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let firstStore = SessionStore(
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

        await firstStore.refreshAll(autoAttach: false)
        firstStore.takeOverSession(running)
        await firstStore.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: firstStore)
        let didQueue = await firstStore.sendTurn(CodexAppServerTurnPayload(prompt: "重启后不能重复发送"))
        XCTAssertTrue(didQueue)

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_before_restart",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: sockets[0])

        let restoredStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        let restored = try XCTUnwrap(restoredStore.queuedTurns(sessionID: running.id).first)
        XCTAssertEqual(restored.previewText, "重启后不能重复发送")
        XCTAssertEqual(restored.dispatchState, .needsConfirmation)
        XCTAssertTrue(restored.lastError?.contains("确认") == true)
    }

    func testAcceptedQueuedTurnRestartKeepsFollowingTurnBehindPersistentStartBarrier() async throws {
        let project = makeProject(id: "proj_queue_start_barrier")
        let running = makeSession(
            id: "sess_queue_start_barrier",
            projectID: project.id,
            title: "Start Barrier",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_before_barrier"
        )
        let idleSnapshot = makeSession(
            id: running.id,
            projectID: project.id,
            title: running.title,
            status: SessionStatus.completed.rawValue,
            source: running.source
        )
        let defaultsSuiteName = "ConversationTurnQueueTests.StartBarrier.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        appStore.token = "test-token"
        let queuedTurnStore = FileQueuedTurnStore(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("QueuedTurnBarrierTests.\(UUID().uuidString)", isDirectory: true)
        )
        let runningClient = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var firstSockets: [MockWebSocketClient] = []
        let firstStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { runningClient },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                firstSockets.append(socket)
                return socket
            }
        )

        await firstStore.refreshAll(autoAttach: false)
        firstStore.takeOverSession(running)
        await firstStore.selectSession(running)
        // 控制连接由异步任务创建；先等待工厂产出 socket，避免测试调度较慢时数组越界崩溃。
        for _ in 0..<80 where firstSockets.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstSocket = try XCTUnwrap(firstSockets.first, "控制连接未在超时前创建")
        firstSocket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: firstStore)
        let firstQueued = await firstStore.sendTurn(CodexAppServerTurnPayload(prompt: "第一条实际派发"))
        let secondQueued = await firstStore.sendTurn(CodexAppServerTurnPayload(prompt: "第二条必须等待 started"))
        XCTAssertTrue(firstQueued)
        XCTAssertTrue(secondQueued)
        firstSocket.emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_before_barrier",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: firstSocket)
        let sentTurn = try XCTUnwrap(firstSocket.sentTurns.first)
        firstSocket.onSendAccepted?(sentTurn.clientMessageID)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(firstStore.selectedQueuedTurns.first?.waitsForAcceptedTurnStart, true)
        XCTAssertEqual(firstStore.selectedQueuedTurns.first?.blockedCompletionID, "turn_before_barrier")

        let restoredClient = MockSessionStoreClient(projects: [project], sessions: [idleSnapshot], messagesResult: [])
        var restoredSockets: [MockWebSocketClient] = []
        let restoredStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { restoredClient },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                restoredSockets.append(socket)
                return socket
            }
        )
        restoredStore.selectedProjectID = project.id
        await restoredStore.refreshAll(autoAttach: false)
        let restoredSession = try XCTUnwrap(restoredStore.sessions.first { $0.id == running.id })
        restoredStore.takeOverSession(restoredSession)
        await restoredStore.selectSession(restoredSession)
        let socket = try XCTUnwrap(restoredSockets.last)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: restoredStore)

        socket.emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: "turn_before_barrier",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(socket.sentTurns.isEmpty, "重复的上一轮完成事件不能越过持久化 started 门闩")

        socket.emitEvent(.turnStarted(AgentEventMetadata(
            seq: 3,
            sessionID: running.id,
            turnID: "turn_after_barrier",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        socket.emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 4,
            sessionID: running.id,
            turnID: "turn_after_barrier",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: socket)
        XCTAssertEqual(socket.sentTurns.first?.payload.textPrompt, "第二条必须等待 started")
    }

    func testPersistedWaitingQueueResumesAfterRestartWhenThreadIsIdle() async throws {
        let project = makeProject(id: "proj_queue_restart_resume")
        let running = makeSession(
            id: "sess_queue_restart_resume",
            projectID: project.id,
            title: "Queue Restart Resume",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_before_restart_resume"
        )
        let idle = makeSession(
            id: running.id,
            projectID: project.id,
            title: running.title,
            status: SessionStatus.completed.rawValue,
            source: running.source
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueuedTurnRestartResumeTests.\(UUID().uuidString)", isDirectory: true)
        let queuedTurnStore = FileQueuedTurnStore(directoryURL: directory)
        let runningClient = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var firstSockets: [MockWebSocketClient] = []
        let firstStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { runningClient },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                firstSockets.append(socket)
                return socket
            }
        )
        await firstStore.refreshAll(autoAttach: false)
        firstStore.takeOverSession(running)
        await firstStore.selectSession(running)
        firstSockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: firstStore)
        let queued = await firstStore.sendTurn(CodexAppServerTurnPayload(prompt: "重启后自动继续"))
        XCTAssertTrue(queued)
        XCTAssertTrue(firstSockets[0].sentTurns.isEmpty)

        let idleClient = MockSessionStoreClient(
            projects: [project],
            sessions: [idle],
            sessionResponses: [idle.id: SessionResponse(session: idle)],
            messagesResult: []
        )
        var restoredSockets: [MockWebSocketClient] = []
        let restoredStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            queuedTurnStore: queuedTurnStore,
            clientFactory: { idleClient },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                restoredSockets.append(socket)
                return socket
            }
        )
        await restoredStore.refreshAll(autoAttach: false)
        let queueSocket = try XCTUnwrap(restoredSockets.first)
        queueSocket.emitStatus(.connected)
        try await waitForSentTurnCount(1, socket: queueSocket)
        XCTAssertEqual(queueSocket.sentTurns.first?.payload.textPrompt, "重启后自动继续")
        XCTAssertEqual(restoredStore.queuedTurns(sessionID: idle.id).first?.dispatchState, .dispatching)
    }

    func testQueuedTurnContinuesAfterNavigatingToAnotherSession() async throws {
        let project = makeProject(id: "proj_queue_navigation")
        let first = makeSession(
            id: "sess_queue_navigation_first",
            projectID: project.id,
            title: "First",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_navigation_first"
        )
        let second = makeSession(
            id: "sess_queue_navigation_second",
            projectID: project.id,
            title: "Second",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_navigation_second"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [first, second], messagesResult: [])
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
        store.takeOverSession(first)
        store.takeOverSession(second)
        await store.selectSession(first)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let didQueue = await store.sendTurn(CodexAppServerTurnPayload(prompt: "切走后继续发送"))
        XCTAssertTrue(didQueue)

        await store.selectSession(second)
        XCTAssertGreaterThanOrEqual(sockets.count, 3)
        let queueSocket = sockets[1]
        queueSocket.emitStatus(.connected)
        queueSocket.emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: first.id,
            turnID: "turn_navigation_first",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: queueSocket)
        XCTAssertEqual(queueSocket.sentTurns.first?.payload.textPrompt, "切走后继续发送")
        XCTAssertEqual(store.selectedSessionID, second.id)
    }

    func testQueuedTurnsCanBeEditedReorderedAndDeleted() async throws {
        let project = makeProject(id: "proj_queue_management")
        let running = makeSession(
            id: "sess_queue_management",
            projectID: project.id,
            title: "Queue Management",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_queue_management"
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let firstQueued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "第一条"))
        let secondQueued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "第二条"))
        XCTAssertTrue(firstQueued)
        XCTAssertTrue(secondQueued)
        let firstID = try XCTUnwrap(store.selectedQueuedTurns.first?.id)
        let secondID = try XCTUnwrap(store.selectedQueuedTurns.last?.id)

        XCTAssertTrue(store.updateQueuedTurn(
            clientMessageID: firstID,
            payload: CodexAppServerTurnPayload(prompt: "编辑后的第一条")
        ))
        XCTAssertTrue(store.moveSelectedQueuedTurns(fromOffsets: IndexSet(integer: 1), toOffset: 0))
        XCTAssertEqual(store.selectedQueuedTurns.map(\.id), [secondID, firstID])
        XCTAssertEqual(store.selectedQueuedTurns.last?.previewText, "编辑后的第一条")

        XCTAssertTrue(store.deleteQueuedTurn(clientMessageID: secondID))
        XCTAssertEqual(store.selectedQueuedTurns.map(\.previewText), ["编辑后的第一条"])
    }


    func testExistingQueueStaysFIFOWhenSnapshotTemporarilyLosesActiveTurn() async throws {
        let project = makeProject(id: "proj_ws_queue_snapshot_gap")
        let running = makeSession(
            id: "sess_ws_queue_snapshot_gap",
            projectID: project.id,
            title: "Queue Snapshot Gap",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn_snapshot_gap_1"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let firstQueued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "恢复后第一条"))
        XCTAssertTrue(firstQueued)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)

        // 模拟截图里的恢复窗口：历史快照先把会话投影成 completed，但当前 turn 的
        // turn/completed 事件还没有补回。已有本地队列不能因此被后续输入绕过。
        let completedSnapshot = makeSession(
            id: running.id,
            projectID: project.id,
            title: running.title,
            status: SessionStatus.completed.rawValue,
            source: running.source
        )
        sockets[0].emitEvent(.session(completedSnapshot))
        try await waitForSelectedSessionStatus(SessionStatus.completed.rawValue, store: store)

        let secondQueued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "恢复后第二条"))
        XCTAssertTrue(secondQueued)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)
        XCTAssertTrue(
            conversationStore.messages(for: running.id)
                .filter { $0.content == "恢复后第一条" || $0.content == "恢复后第二条" }
                .isEmpty
        )
        XCTAssertEqual(store.selectedQueuedTurns.map(\.previewText), ["恢复后第一条", "恢复后第二条"])

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_snapshot_gap_1",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: sockets[0])
        XCTAssertEqual(sockets[0].sentTurns.map(\.payload.textPrompt), ["恢复后第一条"])
        sockets[0].onSendAccepted?(sockets[0].sentTurns[0].clientMessageID)
        try await Task.sleep(nanoseconds: 60_000_000)

        sockets[0].emitEvent(.turnStarted(AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: "turn_snapshot_gap_2",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 3,
            sessionID: running.id,
            turnID: "turn_snapshot_gap_2",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(2, socket: sockets[0])
        XCTAssertEqual(sockets[0].sentTurns.map(\.payload.textPrompt), ["恢复后第一条", "恢复后第二条"])
    }

    func testRunningQueueDoesNotDispatchMerelyBecauseWebSocketReconnected() async throws {
        let project = makeProject(id: "proj_ws_queue_reconnect")
        let running = makeSession(
            id: "sess_ws_queue_reconnect",
            projectID: project.id,
            title: "Queue Reconnect",
            status: "running",
            source: "codex",
            activeTurnID: "turn_queue_reconnect"
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
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "重连后仍需等待完成确认"))
        XCTAssertTrue(queued)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)

        sockets[0].emitStatus(.disconnected)
        for _ in 0..<80 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(sockets.count, 2)
        sockets[1].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        XCTAssertTrue(sockets[1].sentTurns.isEmpty, "重连成功本身不能证明原 turn 已完成")

        sockets[1].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_queue_reconnect",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: sockets[1])
        XCTAssertEqual(sockets[1].sentTurns.first?.payload.textPrompt, "重连后仍需等待完成确认")
    }

    func testRunningQueuedDeliveryWorksWithoutActiveTurnButGuidedDoesNot() async throws {
        let project = makeProject(id: "proj_ws_queued_without_active_turn")
        let running = makeSession(
            id: "sess_ws_queued_without_active_turn",
            projectID: project.id,
            title: "Running Without Active Turn",
            status: "running",
            source: "codex"
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "排队下一轮"))
        let guided = await store.sendTurn(CodexAppServerTurnPayload(prompt: "尝试引导"), runningDelivery: .guided)

        XCTAssertTrue(queued)
        XCTAssertFalse(guided)
        XCTAssertEqual(sockets[0].sentTurns.count, 1)
        XCTAssertEqual(sockets[0].sentTurns.first?.payload.textPrompt, "排队下一轮")
        XCTAssertTrue(sockets[0].sentGuidance.isEmpty)
        XCTAssertEqual(store.errorMessage, L10n.text("ui.failed_to_guide_conversation_there_is_no_active"))
    }

    func testSendCtrlCIgnoresRunningSessionWithoutActiveTurn() async throws {
        let project = makeProject(id: "proj_ctrl_c_without_active_turn")
        let running = makeSession(
            id: "sess_ctrl_c_without_active_turn",
            projectID: project.id,
            title: "No Active Turn",
            status: "running",
            source: "codex"
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.interruptSelectedTurn()

        XCTAssertEqual(sockets[0].sentCtrlCCount, 0)
        XCTAssertEqual(store.statusMessage, L10n.text("ui.there_are_currently_no_active_rounds_to_interrupt"))
        XCTAssertNil(store.errorMessage)
    }

    func testSendCtrlCSendsForConnectedActiveTurn() async throws {
        let project = makeProject(id: "proj_ctrl_c_active_turn")
        let running = makeSession(
            id: "sess_ctrl_c_active_turn",
            projectID: project.id,
            title: "Active Turn",
            status: "running",
            source: "codex",
            activeTurnID: "turn_ctrl_c"
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.interruptSelectedTurn()

        XCTAssertEqual(sockets[0].sentCtrlCCount, 1)
        XCTAssertEqual(sockets[0].sentCtrlCTurnIDs, ["turn_ctrl_c"])
        XCTAssertEqual(store.statusMessage, L10n.text("ui.stopping_current_reply"))
        XCTAssertNil(store.errorMessage)

        let didQueue = await store.sendTurn(CodexAppServerTurnPayload(prompt: "中断后继续发送"))
        XCTAssertTrue(didQueue)
        XCTAssertEqual(store.selectedQueuedTurns.first?.expectedTurnID, "turn_ctrl_c")
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_ctrl_c",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil,
            turnLifecycle: .interrupted
        )))
        try await waitForSentTurnCount(1, socket: sockets[0])

        XCTAssertEqual(sockets[0].sentTurns.first?.payload.textPrompt, "中断后继续发送")
        XCTAssertNil(store.selectedSession?.activeTurnID)
    }

    func testRunningSessionGuidedDeliveryUsesTurnStartedActiveTurn() async throws {
        let project = makeProject(id: "proj_ws_guided_event")
        let running = makeSession(id: "sess_ws_guided_event", projectID: project.id, title: "Running", status: "running", source: "codex")
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.turnStarted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_from_event",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID("turn_from_event", store: store)

        let guided = await store.sendTurn(CodexAppServerTurnPayload(prompt: "继续按这个方向"), runningDelivery: .guided)

        XCTAssertTrue(guided)
        XCTAssertEqual(sockets[0].sentGuidance.count, 1)
        XCTAssertEqual(sockets[0].sentGuidance.first?.payload.textPrompt, "继续按这个方向")
        XCTAssertEqual(sockets[0].sentGuidance.first?.expectedTurnID, "turn_from_event")
    }

    func testRunningSessionGuidedDeliveryBackfillsActiveTurnFromAssistantDelta() async throws {
        let project = makeProject(id: "proj_ws_guided_delta")
        let running = makeSession(id: "sess_ws_guided_delta", projectID: project.id, title: "Running", status: "running", source: "codex")
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.assistantDelta(
            AgentDelta(text: "正在继续", role: .assistant, kind: .message),
            AgentEventMetadata(
                seq: 1,
                sessionID: running.id,
                turnID: "turn_from_delta",
                itemID: "assistant_delta",
                messageID: "assistant_delta",
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            )
        ))
        try await waitForSelectedActiveTurnID("turn_from_delta", store: store)

        let guided = await store.sendTurn(CodexAppServerTurnPayload(prompt: "沿着这个回复继续"), runningDelivery: .guided)

        XCTAssertTrue(guided)
        XCTAssertEqual(sockets[0].sentGuidance.count, 1)
        XCTAssertEqual(sockets[0].sentGuidance.first?.expectedTurnID, "turn_from_delta")
    }

    func testLateRuntimeEventDoesNotRestoreActiveTurnAfterCompletion() async throws {
        let project = makeProject(id: "proj_ws_late_turn")
        let running = makeSession(
            id: "sess_ws_late_turn",
            projectID: project.id,
            title: "Running",
            status: "running",
            source: "codex",
            activeTurnID: "turn_late"
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: "turn_late",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID(nil, store: store)
        try await waitForSelectedSessionStatus(SessionStatus.completed.rawValue, store: store)

        sockets[0].emitEvent(.assistantDelta(
            AgentDelta(text: "迟到片段", role: .assistant, kind: .message),
            AgentEventMetadata(
                seq: 3,
                sessionID: running.id,
                turnID: "turn_late",
                itemID: "assistant_late",
                messageID: "assistant_late",
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            )
        ))
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertNil(store.selectedSession?.activeTurnID)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)
    }

    func testTakeOverSelectedRunningSessionReconnectsWithoutContentReplay() async throws {
        // 接管时消息区已由 thread/read 快照兜底；完整回放会把 backlog 旧卡追加到
        // 已合并时间线后面（plan 在前、命令在后的事故路径），必须走状态级回放。
        let project = makeProject(id: "proj_takeover_replay")
        let running = makeSession(id: "sess_takeover_replay", projectID: project.id, title: "Running", status: "running", source: "codex")
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
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 0, "未接管的运行会话应保持观察，不建立控制连接")

        store.takeOverSession(running)

        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets[0].replayBufferedEventsByConnect, [false])
    }

    func testForegroundRefreshReattachDoesNotRequestContentReplay() async throws {
        // 前台恢复的 refreshAll 会重走 prepareSelectedSessionAfterRefresh；已加载会话的
        // loadHistoryIfNeeded 是 no-op，此时重连若要求完整回放，backlog 旧卡会破坏时间线顺序。
        let project = makeProject(id: "proj_foreground_replay")
        let running = makeSession(id: "sess_foreground_replay", projectID: project.id, title: "Running", status: "running", source: "codex")
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
        XCTAssertEqual(sockets.count, 1)

        await store.refreshAll(autoAttach: true)

        XCTAssertGreaterThanOrEqual(sockets.count, 1)
        for socket in sockets {
            XCTAssertFalse(
                socket.replayBufferedEventsByConnect.contains(true),
                "前台恢复重连不应要求完整回放 backlog"
            )
        }
    }

    func testBackgroundSuspensionRetiresGhostSocketWithoutFailingLocalMessages() async throws {
        let project = makeProject(id: "proj_background_suspend")
        let running = makeSession(
            id: "sess_background_suspend",
            projectID: project.id,
            title: "后台挂起",
            status: "running",
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
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

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let sentImmediately = await store.sendTurn(CodexAppServerTurnPayload(prompt: "发送中消息"))
        XCTAssertTrue(sentImmediately)
        socket.onSendAccepted?(socket.sentTurns.first?.clientMessageID)
        try await Task.sleep(nanoseconds: 60_000_000)
        socket.emitEvent(.turnStarted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_background_active",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID("turn_background_active", store: store)
        let queuedForLater = await store.sendTurn(CodexAppServerTurnPayload(prompt: "后台期间保留的排队消息"))
        XCTAssertTrue(queuedForLater)
        let messagesBeforeBackground = conversationStore.messages(for: running.id)

        store.suspendForBackground()
        await store.refreshAll(autoAttach: true) // 后台前已启动的刷新不能重新创建第二条 socket。
        socket.emitStatus(.connected) // 旧 URLSession 的迟到回调不能复活幽灵连接。
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(socket.disconnectCallCount, 1)
        XCTAssertEqual(store.webSocketStatus, .disconnected)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.selectedSessionID, running.id)
        XCTAssertEqual(conversationStore.messages(for: running.id), messagesBeforeBackground)
        XCTAssertEqual(
            conversationStore.messages(for: running.id).first { $0.content == "发送中消息" }?.sendStatus,
            .sent
        )
        XCTAssertNil(conversationStore.messages(for: running.id).first { $0.content == "后台期间保留的排队消息" })
        XCTAssertEqual(store.selectedQueuedTurns.map(\.previewText), ["后台期间保留的排队消息"])
    }

    func testForegroundResumeRebuildsBackgroundSocketExactlyOnceWithoutContentReplay() async throws {
        let project = makeProject(id: "proj_background_resume")
        let running = makeSession(
            id: "sess_background_resume",
            projectID: project.id,
            title: "前台恢复",
            status: "running",
            source: "codex"
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

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.suspendForBackground()
        await store.resumeFromForeground()
        for _ in 0..<80 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(sockets[0].disconnectCallCount, 1)
        XCTAssertEqual(sockets[1].connectedSessionIDs, [running.id])
        XCTAssertEqual(sockets[1].replayBufferedEventsByConnect, [false])
    }

    func testForegroundResumeWhileOfflineDefersBackgroundReconnectUntilPathRecovery() async throws {
        let project = makeProject(id: "proj_background_offline")
        let running = makeSession(
            id: "sess_background_offline",
            projectID: project.id,
            title: "后台离线",
            status: "running",
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let pathSource = TestNetworkPathStatusSource(initialStatus: .satisfied)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: []) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            networkPathStatusSource: pathSource
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.suspendForBackground()
        pathSource.emit(.unsatisfied)
        try await waitForNetworkReachability(.unsatisfied, store: store)
        await store.resumeFromForeground()
        XCTAssertEqual(sockets.count, 1, "已知离线时回前台不能抢先创建 WebSocket")

        pathSource.emit(.satisfied)
        try await waitForNetworkReachability(.satisfied, store: store)
        for _ in 0..<80 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(sockets[1].connectedSessionIDs, [running.id])
    }

    func testBufferedStateReplayKeepsCompletedContentEvents() {
        // thread/read 快照不含 commandExecution 过程 item；状态级回放必须保留 completed
        // 内容事件，否则离开期间完成的命令卡会永久丢失。流式 delta/日志仍不补播。
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { FakeCodexAppServerTransport() },
            configProvider: { makeDirectAppServerConfig(project: AgentProject(id: "proj_replay_filter", name: "Replay", path: "/tmp/replay-filter")) }
        )
        let metadata = AgentEventMetadata.empty
        let completed = AgentMessage(id: "m1", sessionID: "s1", role: .system, kind: .commandSummary, content: "命令：ls", revision: 1)
        let started = AgentMessage(
            id: "m1",
            sessionID: "s1",
            role: .system,
            kind: .commandSummary,
            content: "命令：ls",
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行命令",
                status: "inProgress",
                command: "ls",
                commandPresentationKind: .execution
            ),
            revision: 1
        )

        XCTAssertTrue(runtime.shouldReplayBufferedStateEvent(.processItemCompleted(completed, nil, metadata)))
        XCTAssertFalse(runtime.shouldReplayBufferedStateEvent(.processItemCompleted(started, nil, metadata)))
        XCTAssertTrue(runtime.shouldReplayBufferedStateEvent(.messageCompleted(completed, metadata)))
        XCTAssertTrue(runtime.shouldReplayBufferedStateEvent(.turnCompleted(metadata)))
        XCTAssertFalse(runtime.shouldReplayBufferedStateEvent(.assistantDelta(AgentDelta(text: "t", role: .assistant, kind: .message), metadata)))
        XCTAssertFalse(runtime.shouldReplayBufferedStateEvent(.logDelta(LogDelta(text: "l", stream: nil), metadata)))
    }

    func testRunningSessionSendWaitsForConnectedWebSocket() async throws {
        let project = makeProject(id: "proj_ws_connecting_guard")
        let running = makeSession(id: "sess_ws_connecting_guard", projectID: project.id, title: "连接中", status: "running", source: "codex")
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
        try await waitForWebSocketStatus(.connecting, store: store)

        let sentWhileConnecting = await store.sendTurn(CodexAppServerTurnPayload(prompt: "不要在连接中发送"))

        XCTAssertTrue(sentWhileConnecting)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)
        XCTAssertTrue(conversationStore.messages(for: running.id).isEmpty)
        XCTAssertEqual(store.selectedQueuedTurns.map(\.previewText), ["不要在连接中发送"])

        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        try await waitForSentTurnCount(1, socket: sockets[0])
        let sentAfterConnected = await store.sendTurn(CodexAppServerTurnPayload(prompt: "连接好后再发送"))

        XCTAssertTrue(sentAfterConnected)
        XCTAssertEqual(sockets[0].sentTurns.count, 1)
        XCTAssertEqual(sockets[0].sentTurns.first?.payload.textPrompt, "不要在连接中发送")
        XCTAssertEqual(store.selectedQueuedTurns.map(\.previewText), ["不要在连接中发送", "连接好后再发送"])
    }

    func testWebSocketFailureMarksSendingUserMessagesFailedAndIgnoresStaleAccepted() async throws {
        let project = makeProject(id: "proj_ws_sending_failed")
        let running = makeSession(id: "sess_ws_sending_failed", projectID: project.id, title: "Sending Failed", status: "running", source: "codex")
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
            },
            webSocketReconnectDelayNanoseconds: { _ in 1_000_000_000 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let acceptedSend = await store.sendTurn(CodexAppServerTurnPayload(prompt: "已经 accepted 的消息"))

        XCTAssertTrue(acceptedSend)
        let acceptedEcho = try XCTUnwrap(conversationStore.messages(for: running.id).first { $0.content == "已经 accepted 的消息" })
        let acceptedClientMessageID = try XCTUnwrap(acceptedEcho.clientMessageID)
        sockets[0].onSendAccepted?(acceptedClientMessageID)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.clientMessageID == acceptedClientMessageID && $0.sendStatus == .sent }
        }

        let sent = await store.sendTurn(CodexAppServerTurnPayload(prompt: "断线时不要卡在发送中"))

        XCTAssertTrue(sent)
        let queuedClientMessageID = try XCTUnwrap(
            store.selectedQueuedTurns.first { $0.previewText == "断线时不要卡在发送中" }?.clientMessageID
        )
        XCTAssertNil(conversationStore.messages(for: running.id).first { $0.content == "断线时不要卡在发送中" })

        sockets[0].emitStatus(.failed("network dropped"))
        try await Task.sleep(nanoseconds: 80_000_000)
        let messages = conversationStore.messages(for: running.id)

        XCTAssertEqual(messages.first(where: { $0.clientMessageID == acceptedClientMessageID })?.sendStatus, .sent)
        XCTAssertEqual(store.queuedTurns(sessionID: running.id).first { $0.clientMessageID == queuedClientMessageID }?.dispatchState, .waiting)

        sockets[0].onSendAccepted?(queuedClientMessageID)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(store.queuedTurns(sessionID: running.id).first { $0.clientMessageID == queuedClientMessageID })
    }

    func testRunningSendFailureNoRolloutFoundMarksLocalEchoFailedAndRetainsRetryPayload() async throws {
        let project = makeProject(id: "proj_no_rollout_send")
        let running = makeSession(id: "sess_no_rollout_send", projectID: project.id, title: "No Rollout", status: "running", source: "codex")
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
        let payload = CodexAppServerTurnPayload(input: [
            .text("继续这轮"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .mention(name: "README", path: project.path)
        ])

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let sent = await store.sendTurn(payload)
        XCTAssertTrue(sent)
        let localEcho = try XCTUnwrap(conversationStore.messages(for: running.id).first { $0.role == .user })
        let clientMessageID = try XCTUnwrap(localEcho.clientMessageID)
        XCTAssertEqual(localEcho.sendStatus, .sending)

        sockets[0].onSendFailure?(clientMessageID, "app-server 错误 -32000：no rollout found")
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.clientMessageID == clientMessageID && $0.sendStatus == .failed }
        }

        let failedMessage = try XCTUnwrap(conversationStore.messages(for: running.id).first { $0.clientMessageID == clientMessageID })
        XCTAssertEqual(failedMessage.turnPayload?.input, payload.input)
        XCTAssertEqual(failedMessage.turnPayload?.options.model, "gpt-6-astra")
        XCTAssertTrue(payloadContainsInlineImage(failedMessage.turnPayload))
        XCTAssertTrue(payloadContainsMention(failedMessage.turnPayload, name: "README"))
        let expectedError = "待发送消息结果不确定，请确认后重试：app-server 错误 -32000：no rollout found"
        for _ in 0..<50 where store.errorMessage != expectedError {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.errorMessage, expectedError)
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .needsConfirmation)
        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testApprovalDecisionSendsThroughCurrentWebSocket() async throws {
        let project = makeProject(id: "proj_approval")
        let approval = ApprovalSummary(id: "approval-1", title: "运行 go test", kind: "command", count: 1)
        let waiting = AgentSession(
            id: "codex_thread_approval",
            projectID: project.id,
            project: project.id,
            dir: "/tmp/\(project.id)",
            title: "待审批",
            status: "waiting_for_approval",
            source: "codex",
            resumeID: "thread_approval",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            pendingApproval: approval
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [waiting])
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
        store.takeOverSession(waiting)
        await store.selectSession(waiting)
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.decideApproval(approval, accept: true)

        XCTAssertEqual(sockets[0].sentApprovals.count, 1)
        XCTAssertEqual(sockets[0].sentApprovals.first?.approvalID, "approval-1")
        XCTAssertEqual(sockets[0].sentApprovals.first?.decision, "accept")
        XCTAssertEqual(store.selectedSession?.status, "waiting_for_approval")
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "approval-1")
        XCTAssertTrue(store.isApprovalDecisionPending(approval))

        sockets[0].onControlFailure?("interrupt failed")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(store.isApprovalDecisionPending(approval))

        sockets[0].onApprovalDecisionFailure?("approval-1", "write failed")
        for _ in 0..<80 where store.isApprovalDecisionPending(approval) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.isApprovalDecisionPending(approval))
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "approval-1")

        store.decideApproval(approval, accept: true)
        XCTAssertTrue(store.isApprovalDecisionPending(approval))
        sockets[0].emitEvent(.approvalResolved(AgentEventMetadata(
            seq: nil,
            sessionID: waiting.id,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: Date()
        )))
        for _ in 0..<80 where store.selectedSession?.pendingApproval != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertNil(store.selectedSession?.pendingApproval)
        XCTAssertFalse(store.isApprovalDecisionPending(approval))
    }

    func testApprovalRequestUpdatesSelectedSessionPendingApproval() async throws {
        let project = makeProject(id: "proj_approval_event")
        let running = makeSession(id: "sess_approval_event", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let conversationStore = ConversationStore()
        let scheduler = FakeSessionReminderScheduler()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            sessionReminderScheduler: scheduler,
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
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.approvalRequest(
            AgentApprovalRequest(
                id: "cmd-approval",
                title: "运行 curl",
                body: "curl -I https://example.com",
                kind: "command",
                risk: "high"
            ),
            AgentEventMetadata(
                seq: 21,
                sessionID: running.id,
                turnID: "turn-approval",
                itemID: "cmd-approval",
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )
        ))
        for _ in 0..<80 where store.selectedSession?.pendingApproval?.id != "cmd-approval" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.selectedSession?.status, "waiting_for_approval")
        XCTAssertEqual(store.selectedSession?.pendingApproval?.title, "运行 curl")
        XCTAssertTrue(conversationStore.messages(for: running.id).contains { $0.kind == .approval })
        // pendingApproval 会先落到主状态，通知调度随后跨 actor 完成；完整测试集下不能假设两者同一拍结束。
        for _ in 0..<80 where scheduler.runtimeNotifications.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(scheduler.runtimeNotifications, [
            SessionRuntimeNotification(
                id: "approval:\(running.id):cmd-approval",
                sessionID: running.id,
                title: "等待审批",
                body: "\(running.title)：运行 curl",
                kind: .approval
            )
        ])

        store.decideApproval(try XCTUnwrap(store.selectedSession?.pendingApproval), accept: true)

        XCTAssertEqual(sockets[0].sentApprovals.first?.approvalID, "cmd-approval")
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "cmd-approval")
        XCTAssertEqual(store.selectedSession?.status, "waiting_for_approval")
        XCTAssertTrue(store.isApprovalDecisionPending(try XCTUnwrap(store.selectedSession?.pendingApproval)))
        XCTAssertTrue(conversationStore.messages(for: running.id).contains { message in
            message.kind == .approval && message.content.contains("等待审批：运行 curl")
        })
    }

    func testClaudeApprovalRequestUsesSharedRuntimeNotificationPipeline() async throws {
        let project = makeProject(id: "proj_claude_approval_notice")
        let running = makeSession(
            id: "sess_claude_approval_notice",
            projectID: project.id,
            title: "Claude 运行中",
            status: "running",
            source: "claude",
            runtimeProvider: "claude"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let scheduler = FakeSessionReminderScheduler()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionReminderScheduler: scheduler,
            clientFactory: {
                MockSessionStoreClient(projects: [project], sessions: [running])
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

        socket.emitEvent(.approvalRequest(
            AgentApprovalRequest(
                id: "claude-tool-approval",
                title: "运行 Bash",
                body: "go test ./...",
                kind: "command",
                risk: "medium"
            ),
            AgentEventMetadata(
                seq: 22,
                sessionID: running.id,
                turnID: "claude-turn-approval",
                itemID: "claude-tool-approval",
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )
        ))
        for _ in 0..<80 where scheduler.runtimeNotifications.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(scheduler.runtimeNotifications, [
            SessionRuntimeNotification(
                id: "approval:\(running.id):claude-tool-approval",
                sessionID: running.id,
                title: "等待审批",
                body: "\(running.title)：运行 Bash",
                kind: .approval
            )
        ])
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "claude-tool-approval")
    }

    func testApprovalRequestSurvivesLateRunningStatusAndRefresh() async throws {
        let project = makeProject(id: "proj_approval_race")
        let running = makeSession(id: "sess_approval_race", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.approvalRequest(
            AgentApprovalRequest(
                id: "cmd-race",
                title: "运行危险命令",
                body: "rm -rf build",
                kind: "command",
                risk: "high"
            ),
            AgentEventMetadata(
                seq: 41,
                sessionID: running.id,
                turnID: "turn-race",
                itemID: "cmd-race",
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )
        ))
        for _ in 0..<80 where store.selectedSession?.pendingApproval?.id != "cmd-race" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "cmd-race")

        sockets[0].emitEvent(.sessionStatus("running", AgentEventMetadata(
            seq: 42,
            sessionID: running.id,
            turnID: "turn-race",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "cmd-race")

        // 前台刷新或分页刷新拿到的普通 running 快照不能覆盖实时 approval_request。
        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.selectedSession?.status, "waiting_for_approval")
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "cmd-race")
    }

    func testRuntimeEventsScheduleCompletionAndFailureNotifications() async throws {
        let project = makeProject(id: "proj_runtime_notice")
        let running = makeSession(id: "sess_runtime_notice", projectID: project.id, title: "长任务", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let conversationStore = ConversationStore()
        let scheduler = FakeSessionReminderScheduler()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            sessionReminderScheduler: scheduler,
            runtimeCompletionNotificationsEnabled: true,
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
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let completed = AgentEvent.turnCompleted(AgentEventMetadata(
            seq: 31,
            sessionID: running.id,
            turnID: "turn-done",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        ))
        sockets[0].emitEvent(completed)
        sockets[0].emitEvent(completed)
        for _ in 0..<80 where scheduler.runtimeNotifications.count < 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(scheduler.runtimeNotifications, [
            SessionRuntimeNotification(
                id: "completed:\(running.id):turn-done",
                sessionID: running.id,
                title: "会话已完成",
                body: running.title,
                kind: .completed
            )
        ])

        sockets[0].emitEvent(.sessionStatus("failed", AgentEventMetadata(
            seq: 32,
            sessionID: running.id,
            turnID: "turn-failed",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        for _ in 0..<80 where scheduler.runtimeNotifications.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(scheduler.runtimeNotifications.last, SessionRuntimeNotification(
            id: "failed:\(running.id):turn-failed",
            sessionID: running.id,
            title: "会话失败",
            body: running.title,
            kind: .failed
        ))
    }

    func testEventReducerClearsPendingApprovalWhenServerRequestResolved() async throws {
        let reducer = EventReducer()
        let output = await reducer.reduce(
            .approvalResolved(AgentEventMetadata(
                seq: 31,
                sessionID: "sess_resolved",
                turnID: "turn_resolved",
                itemID: "99",
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )),
            fallbackSessionID: "fallback_session",
            outputIdleClearDelay: 0
        )

        XCTAssertEqual(output.pendingApprovalUpdates.count, 1)
        XCTAssertEqual(output.pendingApprovalUpdates.first?.0, "sess_resolved")
        XCTAssertNil(output.pendingApprovalUpdates.first?.1)
        XCTAssertEqual(output.statusUpdates.first?.0, "sess_resolved")
        XCTAssertEqual(output.statusUpdates.first?.1, "running")
        XCTAssertEqual(output.pendingApprovalTaskClears, ["sess_resolved"])
        XCTAssertEqual(output.messageMutations.count, 1)
        if case .resolveLatestPendingApproval(let sessionID) = output.messageMutations[0] {
            XCTAssertEqual(sessionID, "sess_resolved")
        } else {
            XCTFail("Expected resolveLatestPendingApproval mutation")
        }
    }

    func testEventReducerDoesNotClearPendingApprovalForActiveStatusRefresh() async throws {
        let reducer = EventReducer()
        let running = await reducer.reduce(
            .sessionStatus("running", AgentEventMetadata(
                seq: 33,
                sessionID: "sess_active",
                turnID: "turn_active",
                itemID: nil,
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )),
            fallbackSessionID: "fallback_session",
            outputIdleClearDelay: 0
        )

        XCTAssertEqual(running.statusUpdates.first?.0, "sess_active")
        XCTAssertEqual(running.statusUpdates.first?.1, "running")
        XCTAssertTrue(running.pendingApprovalUpdates.isEmpty)

        let failed = await reducer.reduce(
            .sessionStatus("failed", AgentEventMetadata(
                seq: 34,
                sessionID: "sess_active",
                turnID: "turn_active",
                itemID: nil,
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )),
            fallbackSessionID: "fallback_session",
            outputIdleClearDelay: 0
        )

        XCTAssertEqual(failed.pendingApprovalUpdates.count, 1)
        XCTAssertEqual(failed.pendingApprovalUpdates.first?.0, "sess_active")
        XCTAssertNil(failed.pendingApprovalUpdates.first?.1)
    }

    func testConversationStoreResolvesRemotePendingApprovalAndDeduplicatesReplay() {
        let store = ConversationStore()
        let sessionID = "sess_remote_approval"
        let waitingText = "等待审批：运行 curl，风险：high"

        store.appendSystem(waitingText, sessionID: sessionID, kind: .approval)
        store.appendSystem(waitingText, sessionID: sessionID, kind: .approval)

        XCTAssertEqual(store.messages(for: sessionID).filter { $0.kind == .approval }.count, 1)

        store.resolveLatestPendingApproval(sessionID: sessionID)

        XCTAssertEqual(store.messages(for: sessionID).filter { $0.kind == .approval }.count, 1)
        XCTAssertEqual(store.messages(for: sessionID).last?.content, "审批已解决：运行 curl")
    }

    func testConversationStoreDeduplicatesPendingUserInputReplayByRequestID() {
        let store = ConversationStore()
        let sessionID = "sess_remote_user_input"
        let waitingText = L10n.format("ui.waiting_for_additional_information_named", "修复策略")

        func metadata(itemID: String) -> AgentEventMetadata {
            AgentEventMetadata(
                seq: nil,
                sessionID: sessionID,
                turnID: "turn_remote_user_input",
                itemID: itemID,
                messageID: "appserver:turn_remote_user_input:\(itemID)",
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )
        }

        // 旧版本写入的卡没有 itemID；实时重放时必须先升级为 request-1。
        store.appendSystem(waitingText, sessionID: sessionID, kind: .userInput)
        store.appendSystem(waitingText, sessionID: sessionID, kind: .userInput, metadata: metadata(itemID: "request-1"))
        XCTAssertEqual(
            store.messages(for: sessionID).first(where: { $0.kind == .userInput })?.itemID,
            "request-1"
        )
        store.appendSystem(waitingText, sessionID: sessionID, kind: .userInput, metadata: metadata(itemID: "request-1"))
        XCTAssertEqual(store.messages(for: sessionID).filter { $0.kind == .userInput }.count, 1)

        // 标题相同但 request id 不同仍是两个独立交互，不能被文本去重误合并。
        store.appendSystem(waitingText, sessionID: sessionID, kind: .userInput, metadata: metadata(itemID: "request-2"))
        XCTAssertEqual(store.messages(for: sessionID).filter { $0.kind == .userInput }.count, 2)
    }

    func testSessionStoreReplaysDirectAppServerEventStreamFixture() async throws {
        let sessionID = "thr_fixture_stream"
        let project = AgentProject(id: "proj_fixture_stream", name: "Fixture Stream", path: "/tmp/fixture-stream")
        let running = makeSession(id: sessionID, projectID: project.id, title: "Fixture 直连", status: "running", source: "codex", resumeID: sessionID)
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            historyPages: [sessionID: HistoryMessagesPage(messages: [])]
        )
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
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let events = try loadDirectAppServerEventStreamFixture(named: "direct_app_server_approval_stream.jsonl")
        let approvalIndex = try XCTUnwrap(events.firstIndex {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        })

        for event in events[..<approvalIndex] {
            sockets[0].emitEvent(event)
        }
        let completedMessages = try await waitForConversationMessages(in: conversationStore, sessionID: sessionID) { messages in
            messages.contains { $0.role == .assistant && $0.content == "第一段：真实 app-server 事件流。" && $0.sendStatus == .confirmed }
        }

        XCTAssertEqual(completedMessages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(completedMessages.first?.stableID, "appserver:turn_fixture_stream:assistant_fixture")
        XCTAssertEqual(completedMessages.first?.turnID, "turn_fixture_stream")
        XCTAssertEqual(completedMessages.first?.itemID, "assistant_fixture")
        XCTAssertEqual(conversationStore.lastSeenSeq(for: sessionID), 5)
        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertNil(store.selectedSession?.pendingApproval)
        XCTAssertNil(store.selectedForegroundActivity)

        sockets[0].emitEvent(events[approvalIndex])
        for _ in 0..<80 where store.selectedSession?.pendingApproval?.id != "cmd_fixture_approval" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let pendingApproval = try XCTUnwrap(store.selectedSession?.pendingApproval)
        XCTAssertEqual(store.selectedSession?.status, "waiting_for_approval")
        XCTAssertEqual(pendingApproval.title, L10n.format("ui.agent_requests_execution_command_value", "go test ./ios/MimiRemote"))
        XCTAssertTrue(conversationStore.messages(for: sessionID).contains { $0.kind == .approval && $0.content.contains(L10n.text("ui.waiting_for_approval")) })

        store.decideApproval(pendingApproval, accept: true)

        XCTAssertEqual(sockets[0].sentApprovals.first?.approvalID, "cmd_fixture_approval")
        XCTAssertEqual(sockets[0].sentApprovals.first?.decision, "accept")
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "cmd_fixture_approval")

        for event in events.dropFirst(approvalIndex + 1) {
            sockets[0].emitEvent(event)
        }
        for _ in 0..<80 where conversationStore.lastSeenSeq(for: sessionID) != 7 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(conversationStore.lastSeenSeq(for: sessionID), 7)
        XCTAssertNil(store.selectedSession?.pendingApproval)
        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testApprovalDecisionKeepsConversationRecordPendingUntilResolved() async throws {
        let project = makeProject(id: "proj_decline")
        let approval = ApprovalSummary(id: "approval-decline", title: "运行危险命令", kind: "command", count: 1)
        let waiting = AgentSession(
            id: "codex_thread_decline",
            projectID: project.id,
            project: project.id,
            dir: "/tmp/\(project.id)",
            title: "待审批",
            status: "waiting_for_approval",
            source: "codex",
            resumeID: "thread_decline",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            pendingApproval: approval
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        conversationStore.activate(profileID: appStore.activeHostScope.profileID)
        conversationStore.appendSystem("等待审批：运行危险命令，风险：high", sessionID: waiting.id, kind: .approval)
        let client = MockSessionStoreClient(projects: [project], sessions: [waiting])
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
        store.takeOverSession(waiting)
        await store.selectSession(waiting)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.decideApproval(approval, accept: false)

        XCTAssertEqual(sockets[0].sentApprovals.first?.decision, "decline")
        XCTAssertTrue(store.isApprovalDecisionPending(approval))
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, approval.id)
        XCTAssertEqual(conversationStore.messages(for: waiting.id).filter { $0.kind == .approval }.last?.content, "等待审批：运行危险命令，风险：high")
    }

    func testRuntimeSummaryEventsKeepStructuredTimelineKinds() {
        let store = ConversationStore()
        let sessionID = "sess_runtime_summary"

        store.appendSystem("文件变更：README.md modified", sessionID: sessionID, kind: .fileChangeSummary)
        store.appendSystem("等待审批：运行 go test", sessionID: sessionID, kind: .approval)
        store.appendSystem("运行错误：timeout", sessionID: sessionID, kind: .error)

        XCTAssertEqual(store.messages(for: sessionID).map(\.kind), [.fileChangeSummary, .approval, .error])
    }

    func testToolMessageCompletedFallsBackToCommandSummaryKind() throws {
        let store = ConversationStore()
        let sessionID = "sess_tool_summary"
        let message = try AgentAPIClient.decoder.decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "tool:1",
              "session_id": "\(sessionID)",
              "role": "tool",
              "content": "go test ./... 通过",
              "created_at": "2026-06-03T10:00:00Z",
              "revision": 1,
              "send_status": "confirmed"
            }
            """.utf8)
        )

        store.completeMessage(message, metadata: .empty, fallbackSessionID: sessionID)

        let rendered = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(rendered.role, .system)
        XCTAssertEqual(rendered.kind, .commandSummary)
        XCTAssertEqual(rendered.content, "go test ./... 通过")
    }

    func testStructuredAssistantDeltaCreatesStableBubble() {
        let store = ConversationStore()
        let sessionID = "sess_structured_delta"

        store.applyAssistantDelta(
            AgentDelta(text: "结构化回复", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "结构化回复")
        XCTAssertEqual(messages.first?.stableID, "item_1")
    }

}
