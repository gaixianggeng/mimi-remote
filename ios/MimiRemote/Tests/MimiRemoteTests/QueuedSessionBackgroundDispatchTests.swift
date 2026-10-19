import XCTest
@testable import MimiRemote

/// 用户离开会话后，排队消息由后台连接替原会话派发。重连节奏、错误归属和监听入口
/// 都只属于原会话，不能打扰用户正在看的页面。
@MainActor
final class QueuedSessionBackgroundDispatchTests: XCTestCase {
    private let writerConflict = "-32600: thread already has an active writer"

    // MARK: - #802 后台排队连接的重连节奏

    func testDeterministicBackgroundConnectionFailureStopsReconnectAndKeepsReasonOnQueuedItem() async throws {
        let policyRejection = "-32080: gateway policy rejected thread/resume"
        for (index, failure) in [writerConflict, policyRejection].enumerated() {
            let fixture = try await makeLeftQueueFixture(suffix: "deterministic-\(index)", reconnectDelay: { _ in 0 })
            let store = fixture.store
            store.setErrorMessage("当前会话原有提示")
            let background = try XCTUnwrap(fixture.log.latest(connectedTo: fixture.original.id))
            let socketCount = fixture.log.sockets.count

            background.emitStatus(.failed(failure))

            try await waitUntil("确定性拒绝后队首等待用户确认") {
                store.queuedTurns(sessionID: fixture.original.id).first?.dispatchState == .needsConfirmation
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertNil(store.queuedSessionReconnectTasks[fixture.original.id], "确定性拒绝不再排重连")
            XCTAssertNil(store.queuedSessionSockets[fixture.original.id])
            XCTAssertEqual(fixture.log.sockets.count, socketCount, "不能继续向 Mac 发起连接")
            let item = try XCTUnwrap(store.queuedTurns(sessionID: fixture.original.id).first)
            XCTAssertEqual(item.previewText, "后台排队")
            XCTAssertNotNil(item.lastError, "原因记在原会话的排队项上")
            XCTAssertEqual(store.hasActiveWriterConflict(sessionID: fixture.original.id), failure == writerConflict)
            XCTAssertFalse(store.hasActiveWriterConflict(sessionID: fixture.other.id))
            XCTAssertTrue(store.canSendInSelectedSession)
            XCTAssertEqual(store.errorMessage, "当前会话原有提示")

            // 用户确认后才重新建立后台连接；连上即说明 writer 已释放，排队消息照常派发。
            XCTAssertTrue(store.retryQueuedTurn(clientMessageID: item.clientMessageID))
            XCTAssertEqual(fixture.log.sockets.count, socketCount + 1)
            let retried = try XCTUnwrap(fixture.log.sockets.last)
            XCTAssertEqual(retried.connectedSessionIDs.last, fixture.original.id)
            retried.emitStatus(.connected)
            try await waitUntil("后台连上后清掉原会话的冲突") {
                !store.hasActiveWriterConflict(sessionID: fixture.original.id)
            }
            retried.emitEvent(.turnCompleted(turnMetadata(
                sessionID: fixture.original.id,
                turnID: try XCTUnwrap(fixture.original.activeTurnID)
            )))
            try await waitForSentTurnCount(1, socket: retried)
            XCTAssertEqual(retried.sentTurns.first?.payload.textPrompt, "后台排队")
        }
    }

    func testTransientBackgroundConnectionFailuresBackOffAndStopAtLimit() async throws {
        let recorder = QueuedReconnectDelayRecorder()
        let fixture = try await makeLeftQueueFixture(
            suffix: "transient",
            reconnectDelay: { attempt in UInt64(attempt) * 1_000 },
            reconnectSleep: { delay in await recorder.record(delay) }
        )
        let store = fixture.store
        let originalID = fixture.original.id
        store.dismissOperationFeedback()
        let limit = SessionStore.maximumQueuedSessionReconnectAttempts
        let initialSocketCount = fixture.log.sockets.count
        var expectedDelays: [UInt64] = []

        for attempt in 1...limit {
            let background = try XCTUnwrap(fixture.log.latest(connectedTo: originalID))
            background.emitStatus(.failed("app-server WebSocket 未连接"))
            expectedDelays.append(UInt64(attempt) * 1_000)
            try await waitUntil("第 \(attempt) 次失败后按退避重建连接") {
                fixture.log.sockets.count == initialSocketCount + attempt
            }
            let delays = await recorder.delays
            XCTAssertEqual(delays, expectedDelays, "重连间隔随失败次数递增")
            XCTAssertNil(store.operationFeedback, "后台重试不能打断当前页面")
        }

        let lastBackground = try XCTUnwrap(fixture.log.latest(connectedTo: originalID))
        lastBackground.emitStatus(.failed("app-server WebSocket 未连接"))
        try await waitUntil("达到上限后停止重连") {
            store.queuedSessionSockets[originalID] == nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let delaysAtLimit = await recorder.delays
        XCTAssertEqual(delaysAtLimit, expectedDelays)
        XCTAssertEqual(fixture.log.sockets.count, initialSocketCount + limit)
        XCTAssertNil(store.queuedSessionReconnectTasks[originalID])
        XCTAssertEqual(
            store.queuedTurns(sessionID: originalID).first?.dispatchState, .waiting,
            "暂时性失败保留等待，下次打开会话或刷新时继续"
        )
        XCTAssertNotNil(store.operationFeedback, "停止重连时提示一次")

        // 之后的刷新等入口只再试一次，不会重新开始一轮退避。
        store.ensureAllQueuedSessionMonitoring()
        XCTAssertEqual(fixture.log.sockets.count, initialSocketCount + limit + 1)
        try XCTUnwrap(fixture.log.latest(connectedTo: originalID)).emitStatus(.failed("app-server WebSocket 未连接"))
        try await waitUntil("单次重试失败后再次停止") {
            store.queuedSessionSockets[originalID] == nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let delaysAfterRetry = await recorder.delays
        XCTAssertEqual(delaysAfterRetry, expectedDelays)
        XCTAssertEqual(fixture.log.sockets.count, initialSocketCount + limit + 1)
    }

    func testExhaustedRetryBudgetSurvivesBackgroundAndNetworkSuspension() async throws {
        for suspendsNetwork in [false, true] {
            let pathSource = TestNetworkPathStatusSource(initialStatus: .satisfied)
            let fixture = try await makeLeftQueueFixture(
                suffix: "budget-\(suspendsNetwork)",
                reconnectDelay: { _ in 0 },
                reconnectSleep: { _ in },
                networkPathStatusSource: pathSource
            )
            let store = fixture.store
            let originalID = fixture.original.id
            let limit = SessionStore.maximumQueuedSessionReconnectAttempts
            for attempt in 0...limit {
                let socketCount = fixture.log.sockets.count
                try XCTUnwrap(fixture.log.latest(connectedTo: originalID)).emitStatus(.failed("app-server WebSocket 未连接"))
                if attempt < limit {
                    try await waitUntil("第 \(attempt + 1) 次失败后重建连接") {
                        fixture.log.sockets.count > socketCount
                    }
                } else {
                    try await waitUntil("预算用尽后停止") {
                        store.queuedSessionSockets[originalID] == nil
                    }
                }
            }
            let socketCountBeforeSuspension = fixture.log.sockets.count
            func originalSocketsSinceSuspension() -> [MockWebSocketClient] {
                fixture.log.sockets.dropFirst(socketCountBeforeSuspension).filter {
                    $0.connectedSessionIDs.last == originalID
                }
            }

            if suspendsNetwork {
                pathSource.emit(.unsatisfied)
                try await waitForNetworkReachability(.unsatisfied, store: store)
                pathSource.emit(.satisfied)
            } else {
                store.suspendForBackground()
                await store.resumeFromForeground()
            }
            try await waitUntil("恢复后对原会话再试一次") {
                !originalSocketsSinceSuspension().isEmpty
            }
            try XCTUnwrap(originalSocketsSinceSuspension().last).emitStatus(.failed("app-server WebSocket 未连接"))
            try await waitUntil("这次失败后停止") {
                store.queuedSessionSockets[originalID] == nil
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(originalSocketsSinceSuspension().count, 1, "挂起恢复不能重新开始一轮退避")
            XCTAssertNil(store.queuedSessionReconnectTasks[originalID])
        }
    }

    func testPendingBackgroundReconnectStopsWhenQueueClearsOrSessionReopens() async throws {
        for reopensSession in [false, true] {
            for destination in [LeaveDestination.sessionList, .otherSession] {
                let fixture = try await makeLeftQueueFixture(
                    suffix: "cancel-\(reopensSession)-\(destination)",
                    leaveTo: destination,
                    reconnectDelay: { _ in 60_000_000_000 }
                )
                let store = fixture.store
                let originalID = fixture.original.id
                try XCTUnwrap(fixture.log.latest(connectedTo: originalID)).emitStatus(.failed("app-server WebSocket 未连接"))
                try await waitUntil("暂时性失败后排上重连") {
                    store.queuedSessionReconnectTasks[originalID] != nil
                }

                if reopensSession {
                    await store.selectSession(fixture.original)
                } else {
                    let clientMessageID = try XCTUnwrap(store.queuedTurns(sessionID: originalID).first?.clientMessageID)
                    XCTAssertTrue(store.deleteQueuedTurn(clientMessageID: clientMessageID))
                }

                XCTAssertNil(store.queuedSessionReconnectTasks[originalID], "重连循环立即停止")
                XCTAssertNil(store.queuedSessionSockets[originalID])
            }
        }
    }

    // MARK: - #803 后台排队发送结果的错误归属

    func testBackgroundQueuedWriterConflictOutcomeStaysWithOriginalSession() async throws {
        let outcomes: [TurnSendOutcome] = [.uncertain(message: writerConflict), .rejected(message: writerConflict)]
        for (index, outcome) in outcomes.enumerated() {
            let fixture = try await makeLeftQueueFixture(suffix: "outcome-\(index)")
            let store = fixture.store
            let originalID = fixture.original.id
            store.setErrorMessage("当前会话原有提示")
            let background = try XCTUnwrap(fixture.log.latest(connectedTo: originalID))
            background.emitStatus(.connected)
            background.emitEvent(.turnCompleted(turnMetadata(
                sessionID: originalID,
                turnID: try XCTUnwrap(fixture.original.activeTurnID)
            )))
            try await waitForSentTurnCount(1, socket: background)
            let clientMessageID = try XCTUnwrap(background.sentTurns.first?.clientMessageID)

            background.onTurnSendOutcome?(clientMessageID, outcome)

            try await waitUntil("排队消息按结果收口") {
                fixture.conversationStore.messages(for: originalID).contains {
                    $0.clientMessageID == clientMessageID && $0.sendStatus == .failed
                }
            }
            XCTAssertTrue(store.hasActiveWriterConflict(sessionID: originalID), "冲突记到排队项所属会话")
            XCTAssertFalse(store.hasActiveWriterConflict(sessionID: fixture.other.id))
            XCTAssertEqual(store.selectedSessionID, fixture.other.id)
            XCTAssertTrue(store.canSendInSelectedSession, "当前会话仍可发送")
            XCTAssertEqual(store.errorMessage, "当前会话原有提示", "当前会话的提示不被覆盖")
        }
    }

    func testForegroundQueuedWriterConflictStillShowsOnCurrentSession() async throws {
        let fixture = try await makeLeftQueueFixture(suffix: "foreground", leaveTo: nil)
        let store = fixture.store
        let originalID = fixture.original.id
        let foreground = try XCTUnwrap(fixture.log.latest(connectedTo: originalID))
        foreground.emitEvent(.turnCompleted(turnMetadata(
            sessionID: originalID,
            turnID: try XCTUnwrap(fixture.original.activeTurnID)
        )))
        try await waitForSentTurnCount(1, socket: foreground)
        let clientMessageID = try XCTUnwrap(foreground.sentTurns.first?.clientMessageID)

        foreground.onTurnSendOutcome?(clientMessageID, .rejected(message: writerConflict))

        try await waitUntil("前台失败照常提示") {
            store.errorMessage == L10n.text("ui.codex_active_writer_conflict")
        }
        XCTAssertTrue(store.hasActiveWriterConflict(sessionID: originalID))
        XCTAssertFalse(store.canSendInSelectedSession)
    }

    // MARK: - Fixture

    private enum LeaveDestination: CustomStringConvertible {
        case sessionList
        case otherSession

        var description: String {
            switch self {
            case .sessionList: return "list"
            case .otherSession: return "other"
            }
        }
    }

    private struct LeftQueueFixture {
        let store: SessionStore
        let conversationStore: ConversationStore
        let original: AgentSession
        let other: AgentSession
        let log: SocketLog
    }

    /// 在运行中的原会话里排队一条消息，然后离开到列表或另一个运行中的会话；`nil` 表示留在原会话。
    private func makeLeftQueueFixture(
        suffix: String,
        leaveTo destination: LeaveDestination? = .otherSession,
        reconnectDelay: ((Int) -> UInt64)? = nil,
        reconnectSleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        networkPathStatusSource: (any NetworkPathStatusSource)? = nil
    ) async throws -> LeftQueueFixture {
        let project = makeProject(id: "proj_bg_queue_\(suffix)")
        let original = makeSession(
            id: "sess_bg_queue_original_\(suffix)", projectID: project.id, title: "原会话",
            status: "running", source: "codex", activeTurnID: "turn-original-\(suffix)"
        )
        let other = makeSession(
            id: "sess_bg_queue_other_\(suffix)", projectID: project.id, title: "另一会话",
            status: "running", source: "codex", activeTurnID: "turn-other-\(suffix)"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        let log = SocketLog()
        let store = SessionStore(
            appStore: appStore, conversationStore: conversationStore, logStore: LogStore(),
            clientFactory: {
                MockSessionStoreClient(projects: [project], sessions: [original, other], messagesResult: [])
            },
            webSocketFactory: { log.make() },
            webSocketReconnectDelayNanoseconds: reconnectDelay,
            webSocketReconnectSleep: reconnectSleep,
            networkPathStatusSource: networkPathStatusSource
        )
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(original)
        store.takeOverSession(other)
        await store.selectSession(original)
        try XCTUnwrap(log.latest(connectedTo: original.id)).emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let didQueue = await store.sendTurn(CodexAppServerTurnPayload(prompt: "后台排队"))
        XCTAssertTrue(didQueue)
        XCTAssertEqual(store.queuedTurns(sessionID: original.id).map(\.previewText), ["后台排队"])

        switch destination {
        case .sessionList:
            store.returnToSessionList()
        case .otherSession:
            await store.selectSession(other)
            try XCTUnwrap(log.latest(connectedTo: other.id)).emitStatus(.connected)
            try await waitForWebSocketStatus(.connected, store: store)
        case nil:
            break
        }
        return LeftQueueFixture(
            store: store,
            conversationStore: conversationStore,
            original: original,
            other: other,
            log: log
        )
    }

    private func turnMetadata(sessionID: SessionID, turnID: TurnID) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: turnID,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )
    }

    private func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                XCTFail("超时未满足：\(description)")
                throw WaitTimeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct WaitTimeout: Error {}

private final class SocketLog {
    private(set) var sockets: [MockWebSocketClient] = []

    func make() -> MockWebSocketClient {
        let socket = MockWebSocketClient()
        sockets.append(socket)
        return socket
    }

    func latest(connectedTo sessionID: SessionID) -> MockWebSocketClient? {
        sockets.last { $0.connectedSessionIDs.last == sessionID }
    }
}

private actor QueuedReconnectDelayRecorder {
    private(set) var delays: [UInt64] = []

    func record(_ delay: UInt64) {
        delays.append(delay)
    }
}
