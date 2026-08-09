import XCTest
import Combine
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testExternalActivityResponseDecodesOnlyReadOnlyIdentityAndRevisionFields() throws {
        let data = Data(#"""
        {
          "activities": [{
            "thread_id": "thread-1",
            "project_id": "project-1",
            "source": "codex_desktop",
            "state": "running",
            "turn_id": "turn-1",
            "revision": "rev-1",
            "last_activity_at": "2026-07-28T14:00:00.123Z"
          }],
          "scanned_at": "2026-07-28T14:00:01Z"
        }
        """#.utf8)

        let response = try AgentAPIClient.decoder.decode(ExternalActivityResponse.self, from: data)

        XCTAssertEqual(response.activities.count, 1)
        XCTAssertEqual(response.activities[0].threadID, "thread-1")
        XCTAssertEqual(response.activities[0].projectID, "project-1")
        XCTAssertEqual(response.activities[0].turnID, "turn-1")
        XCTAssertEqual(response.activities[0].revision, "rev-1")
    }

    func testExternalActivitySnapshotBatchPublishesSessionsOnceForMultipleActivities() async throws {
        let project = makeProject(id: "proj_external_activity_batch")
        let firstSession = makeSession(
            id: "thread-external-batch-1",
            projectID: project.id,
            title: "批量活动一",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: "thread-external-batch-1"
        )
        let secondSession = makeSession(
            id: "thread-external-batch-2",
            projectID: project.id,
            title: "批量活动二",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: "thread-external-batch-2"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [firstSession, secondSession],
            workspacePages: [project.id: SessionsPage(sessions: [firstSession, secondSession])]
        )
        let store = makeExternalActivityStore(
            project: project,
            session: firstSession,
            client: client
        )
        store.sessions = [
            historyAligned(firstSession, project: project),
            historyAligned(secondSession, project: project)
        ]

        var sessionsPublishCount = 0
        var cancellables = Set<AnyCancellable>()
        store.$sessions
            .dropFirst()
            .sink { _ in sessionsPublishCount += 1 }
            .store(in: &cancellables)

        await store.applyExternalActivitySnapshot(
            [
                makeExternalActivity(
                    threadID: firstSession.id,
                    projectID: project.id,
                    turnID: "turn-batch-1",
                    revision: "rev-batch-1"
                ),
                makeExternalActivity(
                    threadID: secondSession.id,
                    projectID: project.id,
                    turnID: "turn-batch-2",
                    revision: "rev-batch-2"
                )
            ],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        XCTAssertEqual(sessionsPublishCount, 1)
        XCTAssertEqual(store.sessionsByID[firstSession.id]?.activeTurnID, "turn-batch-1")
        XCTAssertEqual(store.sessionsByID[secondSession.id]?.activeTurnID, "turn-batch-2")
    }

    func testIdenticalExternalActivitySnapshotDoesNotRepublishSessionsOrActivity() async throws {
        let project = makeProject(id: "proj_external_activity_noop")
        let session = makeSession(
            id: "thread-external-noop",
            projectID: project.id,
            title: "相同活动快照",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: "thread-external-noop"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            workspacePages: [project.id: SessionsPage(sessions: [session])]
        )
        let store = makeExternalActivityStore(project: project, session: session, client: client)
        let activity = makeExternalActivity(
            threadID: session.id,
            projectID: project.id,
            turnID: "turn-noop",
            revision: "rev-noop"
        )

        var sessionsPublishCount = 0
        var externalActivityPublishCount = 0
        var cancellables = Set<AnyCancellable>()
        store.$sessions
            .dropFirst()
            .sink { _ in sessionsPublishCount += 1 }
            .store(in: &cancellables)
        store.$externalActivityBySessionID
            .dropFirst()
            .sink { _ in externalActivityPublishCount += 1 }
            .store(in: &cancellables)

        await store.applyExternalActivitySnapshot(
            [activity],
            client: client,
            hostScope: store.appStore.activeHostScope
        )
        await store.applyExternalActivitySnapshot(
            [activity],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        XCTAssertEqual(sessionsPublishCount, 1)
        XCTAssertEqual(externalActivityPublishCount, 1)
    }

    func testExternalActivityKeepsControlReadOnlyButDefersSessionPublishDuringScroll() async throws {
        let project = makeProject(id: "proj_external_scroll_gate")
        let session = makeSession(
            id: "thread-external-scroll-gate",
            projectID: project.id,
            title: "滚动中的外部活动",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: "thread-external-scroll-gate"
        )
        let activity = makeExternalActivity(
            threadID: session.id,
            projectID: project.id,
            turnID: "turn-external-scroll-gate",
            revision: "rev-external-scroll-gate"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            externalActivityResponses: [
                ExternalActivityResponse(activities: [activity], scannedAt: Date())
            ]
        )
        let store = makeExternalActivityStore(project: project, session: session, client: client)
        var sessionsPublishCount = 0
        let observation = store.$sessions.dropFirst().sink { _ in
            sessionsPublishCount += 1
        }
        let sourceID = UUID()
        store.setConversationTimelineInteractionActive(true, sourceID: sourceID)

        await store.applyExternalActivitySnapshot(
            [activity],
            client: client,
            hostScope: store.appStore.activeHostScope,
            deferWhileTimelineScrolling: true
        )

        XCTAssertTrue(store.externalReadOnlySessionIDs.contains(session.id), "控制权必须立即收紧")
        XCTAssertEqual(store.externalActivityBySessionID[session.id], activity)
        XCTAssertTrue(store.deferredExternalActivityVisiblePoll)
        XCTAssertEqual(sessionsPublishCount, 0, "滚动中不能发布会触发全量索引的 sessions")
        XCTAssertEqual(store.sessionsByID[session.id]?.status, SessionStatus.history.rawValue)

        store.setConversationTimelineInteractionActive(false, sourceID: sourceID)
        let flushTask = try XCTUnwrap(store.deferredVisiblePollingFlushTask)
        await flushTask.value

        XCTAssertFalse(store.deferredExternalActivityVisiblePoll)
        XCTAssertEqual(sessionsPublishCount, 1)
        XCTAssertEqual(store.sessionsByID[session.id]?.status, SessionStatus.running.rawValue)
        XCTAssertEqual(store.sessionsByID[session.id]?.activeTurnID, activity.turnID)
        withExtendedLifetime(observation) {}
    }

    func testExternalActivityMovesSessionBetweenActiveAndHistoryAndDeduplicatesRevision() async throws {
        let project = makeProject(id: "proj_external_activity")
        let threadID = "thread-external"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Mac 会话",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let firstActivity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-1",
            revision: "rev-1"
        )
        let revisedActivity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-1",
            revision: "rev-2"
        )
        let responses = [
            ExternalActivityResponse(activities: [firstActivity], scannedAt: Date()),
            ExternalActivityResponse(activities: [firstActivity], scannedAt: Date()),
            ExternalActivityResponse(activities: [revisedActivity], scannedAt: Date()),
            ExternalActivityResponse(activities: [], scannedAt: Date())
        ].map(Optional.some)
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            historyPages: [
                threadID: HistoryMessagesPage(messages: [
                    CodexHistoryMessage(role: "assistant", content: "Mac 输出", createdAt: Date())
                ])
            ],
            externalActivityResponses: responses
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID

        let firstRefresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(firstRefresh)
        let activePartition = SessionListPartition(sessions: store.sessions)
        XCTAssertEqual(activePartition.active.map(\.id), [threadID])
        XCTAssertTrue(activePartition.history.isEmpty)
        XCTAssertEqual(store.sessionsByID[threadID]?.activeTurnID, "turn-1")
        XCTAssertEqual(store.externalActivityPollingDelayNanoseconds(), 5_000_000_000)
        XCTAssertEqual(client.requestedMessageSessionIDs.count, 1)

        let duplicateRefresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(duplicateRefresh)
        XCTAssertEqual(
            client.requestedMessageSessionIDs.count,
            1,
            "相同 revision 不应重复拉取历史"
        )

        let revisedRefresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(revisedRefresh)
        XCTAssertEqual(client.requestedMessageSessionIDs.count, 2)

        let completedRefresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(completedRefresh)
        let completedPartition = SessionListPartition(sessions: store.sessions)
        XCTAssertTrue(completedPartition.active.isEmpty)
        XCTAssertEqual(completedPartition.history.map(\.id), [threadID])
        XCTAssertEqual(store.sessionsByID[threadID]?.status, SessionStatus.history.rawValue)
        XCTAssertNil(store.externalActivityBySessionID[threadID])
        XCTAssertFalse(store.isExternalReadOnlySession(try XCTUnwrap(store.sessionsByID[threadID])))
        XCTAssertEqual(store.externalActivityPollingDelayNanoseconds(), 8_000_000_000)
        XCTAssertEqual(
            client.requestedMessageSessionIDs.count,
            3,
            "terminal 快照应执行一次最终历史刷新"
        )
    }

    func testExternalActivityOverridesLegacyTakenOverAndBlocksControlRPCs() async throws {
        let project = makeProject(id: "proj_external_read_only")
        let threadID = "thread-read-only"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Mac 运行中",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            externalActivityResponses: [
                ExternalActivityResponse(
                    activities: [makeExternalActivity(
                        threadID: threadID,
                        projectID: project.id,
                        turnID: "turn-read-only",
                        revision: "rev-read-only"
                    )],
                    scannedAt: Date()
                )
            ]
        )
        let socket = MockWebSocketClient()
        let store = makeExternalActivityStore(
            project: project,
            session: history,
            client: client,
            socket: socket
        )
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.sessionControlStateByID[threadID] = .takenOver

        let refresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(refresh)
        let external = try XCTUnwrap(store.sessionsByID[threadID])
        XCTAssertEqual(store.controlState(for: external), .observing)
        XCTAssertFalse(store.canControlSession(external))
        XCTAssertFalse(store.supportsCodexThreadManagement(external))
        XCTAssertFalse(store.selectedSessionAllowsTakeOver)

        store.takeOverSession(external)
        store.connectWebSocket(external, allowNonRunning: true)
        store.interruptSelectedTurn()
        let didSend = await store.sendTurn(CodexAppServerTurnPayload(prompt: "不要发送"))
        let didGuide = await store.sendTurn(
            CodexAppServerTurnPayload(prompt: "不要引导"),
            runningDelivery: .guided
        )
        store.decideApproval(
            ApprovalSummary(id: "approval-external", title: "不要审批", kind: "command", count: 1),
            accept: true
        )
        XCTAssertFalse(didSend)
        XCTAssertFalse(didGuide)
        await store.stopSelectedSession()

        // terminal 快照到达后，最终历史补拉会暂时把行降为 history，但只读 tombstone 仍在。
        // 这一窗口也不能走“恢复历史会话并发送”的 createSession 分支。
        store.updateSession(threadID) { session in
            session.status = SessionStatus.history.rawValue
            session.activeTurnID = nil
        }
        let didResume = await store.sendTurn(CodexAppServerTurnPayload(prompt: "不要恢复"))
        XCTAssertFalse(didResume)

        XCTAssertTrue(socket.connectedSessionIDs.isEmpty)
        XCTAssertTrue(socket.sentTurns.isEmpty)
        XCTAssertTrue(socket.sentGuidance.isEmpty)
        XCTAssertTrue(socket.sentApprovals.isEmpty)
        XCTAssertEqual(socket.sentCtrlCCount, 0)
        XCTAssertTrue(client.createPayloads.isEmpty)
    }

    func testLocallyStartedTurnIgnoresMatchingDesktopOriginActivityButNotNewMacTurn() async throws {
        let project = makeProject(id: "proj_local_turn_ownership")
        let threadID = "thread-desktop-origin"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "由 Mac 创建、在 iPad 续写",
            status: SessionStatus.running.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID,
            activeTurnID: "turn-ipad"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])]
        )
        let socket = MockWebSocketClient()
        let store = makeExternalActivityStore(
            project: project,
            session: history,
            client: client,
            socket: socket
        )
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.sessionControlStateByID[threadID] = .takenOver
        store.recordLocallyStartedTurn(
            sessionID: threadID,
            turnID: "turn-ipad",
            restoreSelectedConnection: false
        )

        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-ipad",
                revision: "rev-ipad"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        let ipadOwned = try XCTUnwrap(store.sessionsByID[threadID])
        XCTAssertNil(store.externalActivityBySessionID[threadID])
        XCTAssertFalse(store.isExternalReadOnlySession(ipadOwned))
        XCTAssertEqual(store.controlState(for: ipadOwned), .takenOver)
        XCTAssertEqual(ipadOwned.activeTurnID, "turn-ipad")
        XCTAssertEqual(socket.disconnectCallCount, 0)

        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-mac-next",
                revision: "rev-mac-next"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        let macOwned = try XCTUnwrap(store.sessionsByID[threadID])
        XCTAssertEqual(store.externalActivityBySessionID[threadID]?.turnID, "turn-mac-next")
        XCTAssertTrue(store.isExternalReadOnlySession(macOwned))
        XCTAssertEqual(store.controlState(for: macOwned), .observing)
        XCTAssertFalse(store.canControlSession(macOwned))
    }

    func testHistoricalResumeRecordsReturnedTurnBeforeExternalPolling() async throws {
        let project = makeProject(id: "proj_desktop_history_resume")
        let threadID = "thread-desktop-history-resume"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Mac 历史会话",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let resumed = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Mac 历史会话",
            status: SessionStatus.running.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID,
            activeTurnID: "turn-ipad-resume"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [resumed])],
            createSessionResponse: CreateSessionResponse(
                session: resumed,
                row: nil,
                wsURL: "/api/app-server/ws?thread_id=\(threadID)",
                firstMessage: nil
            )
        )
        let socket = MockWebSocketClient()
        let store = makeExternalActivityStore(
            project: project,
            session: history,
            client: client,
            socket: socket
        )
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID

        let didSend = await store.sendTurn(CodexAppServerTurnPayload(prompt: "从 iPad 继续"))

        XCTAssertTrue(didSend)
        XCTAssertEqual(client.createPayloads.first?.resumeID, threadID)
        XCTAssertEqual(store.locallyStartedTurnIDBySessionID[threadID], "turn-ipad-resume")
        XCTAssertEqual(store.controlState(for: try XCTUnwrap(store.sessionsByID[threadID])), .takenOver)

        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-ipad-resume",
                revision: "rev-ipad-resume"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        let controlled = try XCTUnwrap(store.sessionsByID[threadID])
        XCTAssertNil(store.externalActivityBySessionID[threadID])
        XCTAssertFalse(store.isExternalReadOnlySession(controlled))
        XCTAssertEqual(store.controlState(for: controlled), .takenOver)
        XCTAssertEqual(socket.disconnectCallCount, 0)
    }

    func testLocalTurnAckReconcilesExternalSnapshotThatArrivedFirstAndReconnects() async throws {
        let project = makeProject(id: "proj_external_ack_race")
        let threadID = "thread-ack-race"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "轮询早于 ACK",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])]
        )
        let socket = MockWebSocketClient()
        let store = makeExternalActivityStore(
            project: project,
            session: history,
            client: client,
            socket: socket
        )
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.sessionControlStateByID[threadID] = .takenOver
        store.connectWebSocket(history, allowNonRunning: true)
        XCTAssertEqual(socket.connectedSessionIDs, [threadID])

        let activity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-local-race",
            revision: "rev-race"
        )
        await store.applyExternalActivitySnapshot(
            [activity],
            client: client,
            hostScope: store.appStore.activeHostScope
        )
        XCTAssertTrue(store.externalReadOnlySessionIDs.contains(threadID))
        XCTAssertNil(store.connectedSessionID)
        XCTAssertGreaterThanOrEqual(socket.disconnectCallCount, 1)
        XCTAssertTrue(store.canReconcileAcceptedTurnFromRetiredSocket(
            sessionID: threadID,
            outcome: .accepted(turnID: "turn-local-race"),
            hostScope: store.appStore.activeHostScope
        ))

        socket.onTurnSendOutcome?(
            nil,
            .accepted(turnID: "turn-local-race")
        )
        for _ in 0..<10 where store.externalActivityBySessionID[threadID] != nil {
            await Task.yield()
        }

        let recovered = try XCTUnwrap(store.sessionsByID[threadID])
        XCTAssertNil(store.externalActivityBySessionID[threadID])
        XCTAssertFalse(store.isExternalReadOnlySession(recovered))
        XCTAssertEqual(recovered.activeTurnID, "turn-local-race")
        XCTAssertEqual(store.controlState(for: recovered), .takenOver)
        XCTAssertEqual(store.connectedSessionID, threadID)
        XCTAssertEqual(socket.connectedSessionIDs, [threadID, threadID])
    }

    func testLateAcceptedAckCompletesQueuedItemAfterExternalDisconnect() throws {
        let project = makeProject(id: "proj_external_queue_ack")
        let threadID = "thread-queue-ack"
        let clientMessageID = "client-queue-ack"
        let session = makeSession(
            id: threadID,
            projectID: project.id,
            title: "排队 ACK 竞态",
            status: SessionStatus.running.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID,
            activeTurnID: "turn-queue-local"
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [session])
        let store = makeExternalActivityStore(project: project, session: session, client: client)
        let payload = CodexAppServerTurnPayload(prompt: "排队消息")
        store.queuedRunningTurnsBySessionID[threadID] = [QueuedTurnEntry(
            sessionID: threadID,
            projectID: project.id,
            payload: payload,
            clientMessageID: clientMessageID,
            intent: .standard,
            dispatchState: .needsConfirmation
        )]
        store.conversationStore.appendLocalUser(
            "排队消息",
            sessionID: threadID,
            clientMessageID: clientMessageID,
            sendStatus: .sending,
            turnPayload: payload,
            userDelivery: .queued
        )
        let activity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-queue-local",
            revision: "rev-queue-local"
        )
        store.externalActivityBySessionID[threadID] = activity
        store.externalReadOnlySessionIDs.insert(threadID)

        store.handleTurnSendOutcome(
            clientMessageID: clientMessageID,
            sessionID: threadID,
            outcome: .accepted(turnID: "turn-queue-local")
        )

        XCTAssertTrue(store.queuedRunningTurnsBySessionID[threadID]?.isEmpty != false)
        XCTAssertNil(store.externalActivityBySessionID[threadID])
        XCTAssertFalse(store.externalReadOnlySessionIDs.contains(threadID))
        XCTAssertEqual(store.locallyStartedTurnIDBySessionID[threadID], "turn-queue-local")
        XCTAssertEqual(
            store.conversationStore.messages(for: threadID)
                .first(where: { $0.clientMessageID == clientMessageID })?
                .sendStatus,
            .sent
        )
    }

    func testTerminalAckAfterExternalMisclassificationDispatchesNextQueuedTurn() async throws {
        let project = makeProject(id: "proj_external_terminal_ack")
        let threadID = "thread-terminal-ack"
        let acceptedClientMessageID = "client-terminal-ack"
        let nextClientMessageID = "client-terminal-next"
        let localTurnID = "turn-terminal-local"
        let session = makeSession(
            id: threadID,
            projectID: project.id,
            title: "终态 ACK 撤销误判",
            status: SessionStatus.running.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID,
            activeTurnID: localTurnID
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [session])
        let socket = MockWebSocketClient()
        let store = makeExternalActivityStore(
            project: project,
            session: session,
            client: client,
            socket: socket
        )
        store.sessionControlStateByID[threadID] = .takenOver
        store.queuedRunningTurnsBySessionID[threadID] = [
            QueuedTurnEntry(
                sessionID: threadID,
                projectID: project.id,
                payload: CodexAppServerTurnPayload(prompt: "已接受且快速完成"),
                clientMessageID: acceptedClientMessageID,
                intent: .standard,
                dispatchState: .needsConfirmation
            ),
            QueuedTurnEntry(
                sessionID: threadID,
                projectID: project.id,
                payload: CodexAppServerTurnPayload(prompt: "终态后继续"),
                clientMessageID: nextClientMessageID,
                intent: .standard,
                expectedTurnID: localTurnID
            )
        ]
        store.externalActivityBySessionID[threadID] = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: localTurnID,
            revision: "rev-terminal-local"
        )
        store.externalReadOnlySessionIDs.insert(threadID)

        store.handleTurnSendOutcome(
            clientMessageID: acceptedClientMessageID,
            sessionID: threadID,
            outcome: .acceptedTerminal(turnID: localTurnID)
        )

        XCTAssertNil(store.externalActivityBySessionID[threadID])
        XCTAssertFalse(store.externalReadOnlySessionIDs.contains(threadID))
        XCTAssertEqual(store.locallyStartedTurnIDBySessionID[threadID], localTurnID)
        XCTAssertNil(store.sessionsByID[threadID]?.activeTurnID)
        XCTAssertEqual(socket.connectedSessionIDs, [threadID])

        socket.emitStatus(.connected)
        try await waitForSentTurnCount(1, socket: socket)
        XCTAssertEqual(socket.sentTurns.first?.payload.textPrompt, "终态后继续")
        XCTAssertEqual(
            store.queuedRunningTurnsBySessionID[threadID]?.first?.dispatchState,
            .dispatching
        )
    }

    func testTerminalAckAfterLaggingExternalSnapshotRestoresCompletedStatus() async throws {
        let project = makeProject(id: "proj_external_terminal_status")
        let threadID = "thread-terminal-status"
        let clientMessageID = "client-terminal-status"
        let localTurnID = "turn-terminal-status"
        let session = makeSession(
            id: threadID,
            projectID: project.id,
            title: "终态 ACK 恢复完成状态",
            status: SessionStatus.completed.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [session])
        let socket = MockWebSocketClient()
        let store = makeExternalActivityStore(
            project: project,
            session: session,
            client: client,
            socket: socket
        )
        store.sessionControlStateByID[threadID] = .takenOver
        store.queuedRunningTurnsBySessionID[threadID] = [QueuedTurnEntry(
            sessionID: threadID,
            projectID: project.id,
            payload: CodexAppServerTurnPayload(prompt: "已完成但 ACK 迟到"),
            clientMessageID: clientMessageID,
            intent: .standard,
            dispatchState: .needsConfirmation
        )]
        store.conversationStore.updateTurnLifecycle(
            .completed,
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: threadID,
                turnID: localTurnID,
                itemID: nil,
                messageID: nil,
                clientMessageID: clientMessageID,
                revision: nil,
                createdAt: nil
            ),
            fallbackSessionID: threadID
        )

        // completion 已先投影，随后滞后的外部活动快照又错误复活同一 turn。
        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: localTurnID,
                revision: "rev-terminal-status"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )
        XCTAssertEqual(store.sessionsByID[threadID]?.status, SessionStatus.running.rawValue)
        XCTAssertTrue(store.externalReadOnlySessionIDs.contains(threadID))

        store.handleTurnSendOutcome(
            clientMessageID: clientMessageID,
            sessionID: threadID,
            outcome: .acceptedTerminal(turnID: localTurnID)
        )

        XCTAssertTrue(store.queuedRunningTurnsBySessionID[threadID]?.isEmpty != false)
        XCTAssertNil(store.externalActivityBySessionID[threadID])
        XCTAssertFalse(store.externalReadOnlySessionIDs.contains(threadID))
        XCTAssertNil(store.sessionsByID[threadID]?.activeTurnID)
        XCTAssertEqual(store.sessionsByID[threadID]?.status, SessionStatus.completed.rawValue)
        XCTAssertTrue(socket.connectedSessionIDs.isEmpty, "无后续队列时不应复活已结束连接")
    }

    func testSupersededAckAfterExternalMisclassificationRestoresBackgroundMonitoring() async throws {
        let project = makeProject(id: "proj_external_superseded_ack")
        let threadID = "thread-superseded-ack"
        let acceptedClientMessageID = "client-superseded-ack"
        let nextClientMessageID = "client-superseded-next"
        let localTurnID = "turn-superseded-local"
        let authoritativeTurnID = "turn-superseded-authoritative"
        let session = makeSession(
            id: threadID,
            projectID: project.id,
            title: "新轮次 ACK 撤销误判",
            status: SessionStatus.running.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID,
            activeTurnID: localTurnID
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [session])
        let socket = MockWebSocketClient()
        let store = makeExternalActivityStore(
            project: project,
            session: session,
            client: client,
            socket: socket
        )
        store.sessionControlStateByID[threadID] = .takenOver
        store.queuedRunningTurnsBySessionID[threadID] = [
            QueuedTurnEntry(
                sessionID: threadID,
                projectID: project.id,
                payload: CodexAppServerTurnPayload(prompt: "已被新轮次取代"),
                clientMessageID: acceptedClientMessageID,
                intent: .standard,
                dispatchState: .needsConfirmation
            ),
            QueuedTurnEntry(
                sessionID: threadID,
                projectID: project.id,
                payload: CodexAppServerTurnPayload(prompt: "等待权威轮次完成"),
                clientMessageID: nextClientMessageID,
                intent: .standard,
                expectedTurnID: localTurnID
            )
        ]
        store.externalActivityBySessionID[threadID] = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: localTurnID,
            revision: "rev-superseded-local"
        )
        store.externalReadOnlySessionIDs.insert(threadID)

        store.handleTurnSendOutcome(
            clientMessageID: acceptedClientMessageID,
            sessionID: threadID,
            outcome: .acceptedSuperseded(
                turnID: localTurnID,
                activeTurnID: authoritativeTurnID
            )
        )

        XCTAssertNil(store.externalActivityBySessionID[threadID])
        XCTAssertFalse(store.externalReadOnlySessionIDs.contains(threadID))
        XCTAssertEqual(store.locallyStartedTurnIDBySessionID[threadID], localTurnID)
        XCTAssertEqual(store.sessionsByID[threadID]?.activeTurnID, authoritativeTurnID)
        XCTAssertEqual(
            store.queuedRunningTurnsBySessionID[threadID]?.first?.expectedTurnID,
            authoritativeTurnID
        )
        XCTAssertEqual(socket.connectedSessionIDs, [threadID])

        socket.emitStatus(.connected)
        socket.emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: threadID,
            turnID: authoritativeTurnID,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: socket)
        XCTAssertEqual(socket.sentTurns.first?.payload.textPrompt, "等待权威轮次完成")
        XCTAssertEqual(
            store.queuedRunningTurnsBySessionID[threadID]?.first?.dispatchState,
            .dispatching
        )
    }

    func testCompletedLocalTurnIgnoresLaggingSameTurnSnapshot() async throws {
        let project = makeProject(id: "proj_external_terminal_lag")
        let threadID = "thread-terminal-lag"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "本轮已完成",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [history])
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.recordLocallyStartedTurn(
            sessionID: threadID,
            turnID: "turn-local-completed",
            restoreSelectedConnection: false
        )

        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-local-completed",
                revision: "rev-terminal-lag"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        let completed = try XCTUnwrap(store.sessionsByID[threadID])
        XCTAssertEqual(completed.status, SessionStatus.history.rawValue)
        XCTAssertNil(completed.activeTurnID)
        XCTAssertNil(store.externalActivityBySessionID[threadID])
        XCTAssertFalse(store.isExternalReadOnlySession(completed))
    }

    func testAgentDRestartEmptySnapshotClearsZombieTurnRuntimeActivityAndReadOnlyTombstone() async throws {
        let project = makeProject(id: "proj_agentd_restart_reconcile")
        let threadID = "thread-agentd-restart"
        let turnID = "turn-managed-before-restart"
        let running = makeSession(
            id: threadID,
            projectID: project.id,
            title: "重启前由 iPad 发起",
            status: SessionStatus.running.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID,
            activeTurnID: turnID
        )
        let authoritativeIdle = makeSession(
            id: threadID,
            projectID: project.id,
            title: "重启后恢复",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [authoritativeIdle],
            workspacePages: [
                project.id: SessionsPage(sessions: [authoritativeIdle])
            ],
            historyPages: [
                threadID: HistoryMessagesPage(messages: [])
            ],
            externalActivityResponses: [
                ExternalActivityResponse(activities: [], scannedAt: Date())
            ]
        )
        let store = makeExternalActivityStore(
            project: project,
            session: running,
            client: client
        )
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.sessionControlStateByID[threadID] = .takenOver
        store.externalActivityBySessionID[threadID] = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: turnID,
            revision: "rev-zombie-before-restart"
        )
        store.externalReadOnlySessionIDs.insert(threadID)
        store.recordRuntimeActivity(
            sessionID: threadID,
            turnStartedAt: Date(timeIntervalSince1970: 100),
            activityAt: Date(timeIntervalSince1970: 101)
        )

        let refreshed = await store.refreshExternalActivities(client: client)

        XCTAssertTrue(refreshed)
        let reconciled = try XCTUnwrap(store.sessionsByID[threadID])
        XCTAssertEqual(reconciled.status, SessionStatus.history.rawValue)
        XCTAssertNil(reconciled.activeTurnID)
        XCTAssertNil(store.runtimeActivitySnapshot(for: threadID))
        XCTAssertNil(store.externalActivityBySessionID[threadID])
        XCTAssertFalse(store.externalReadOnlySessionIDs.contains(threadID))
        XCTAssertFalse(store.isExternalReadOnlySession(reconciled))
        XCTAssertEqual(store.controlState(for: reconciled), .takenOver)
        XCTAssertTrue(store.canControlSession(reconciled))
        XCTAssertEqual(
            client.requestedMessageSessionIDs,
            [threadID],
            "权威空快照应自动完成一次最终历史对账，无需用户手动刷新"
        )
    }

    func testExternalActivityPollingStopsWhenOldAgentDDoesNotAdvertiseCapability() async {
        let project = makeProject(id: "proj_external_legacy")
        let history = makeSession(
            id: "thread-legacy",
            projectID: project.id,
            title: "旧 agentd",
            status: SessionStatus.history.rawValue,
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            externalActivityResponses: [nil]
        )
        var sleepCalls = 0
        let store = makeExternalActivityStore(
            project: project,
            session: history,
            client: client,
            externalActivitySleep: { _ in sleepCalls += 1 }
        )
        let staleActivity = makeExternalActivity(
            threadID: history.id,
            projectID: project.id,
            turnID: "turn-old-agent",
            revision: "rev-old-agent"
        )
        store.externalActivityBySessionID[history.id] = staleActivity
        store.externalReadOnlySessionIDs.insert(history.id)
        store.updateSession(history.id) { session in
            session.status = SessionStatus.running.rawValue
            session.activeTurnID = staleActivity.turnID
        }

        await store.pollExternalActivitiesWhileVisible()

        XCTAssertEqual(client.externalActivityCallCount, 1)
        XCTAssertEqual(sleepCalls, 0)
        XCTAssertTrue(store.externalActivityCapabilityUnavailable)
        XCTAssertTrue(store.externalActivityBySessionID.isEmpty)
        XCTAssertEqual(store.sessionsByID[history.id]?.status, SessionStatus.history.rawValue)
        XCTAssertFalse(store.isExternalReadOnlySession(store.sessionsByID[history.id]!))
    }

    func testExternalActivityRetriesTerminalRefreshLeftByForegroundCancellation() async throws {
        let project = makeProject(id: "proj_external_terminal_retry")
        let threadID = "thread-terminal-retry"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "待完成刷新",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            historyPages: [threadID: HistoryMessagesPage(messages: [])],
            externalActivityResponses: [
                ExternalActivityResponse(activities: [], scannedAt: Date())
            ]
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        // 模拟上一次 apply 在清空 activity 后、最终补拉完成前因退后台被取消。
        store.externalReadOnlySessionIDs.insert(threadID)

        let refreshed = await store.refreshExternalActivities(client: client)

        XCTAssertTrue(refreshed)
        XCTAssertEqual(client.requestedMessageSessionIDs, [threadID])
        XCTAssertFalse(store.isExternalReadOnlySession(try XCTUnwrap(store.sessionsByID[threadID])))
    }

    private func makeExternalActivity(
        threadID: SessionID,
        projectID: String,
        turnID: TurnID,
        revision: String
    ) -> ExternalSessionActivity {
        ExternalSessionActivity(
            threadID: threadID,
            projectID: projectID,
            source: "codex_desktop",
            state: "running",
            turnID: turnID,
            revision: revision,
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeExternalActivityStore(
        project: AgentProject,
        session: AgentSession,
        client: MockSessionStoreClient,
        socket: MockWebSocketClient = MockWebSocketClient(),
        externalActivitySleep: @escaping (UInt64) async -> Void = { _ in }
    ) -> SessionStore {
        let suiteName = "ExternalActivitySessionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        appStore.endpoint = "http://127.0.0.1:8787"
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { socket },
            externalActivitySleep: externalActivitySleep
        )
        store.setProjectsIfChanged([project])
        store.setRecentWorkspacesIfChanged([AgentWorkspace(project: project)])
        store.setSidebarProjectsIfChanged([project])
        store.sessions = [historyAligned(session, project: project)]
        return store
    }

    private func historyAligned(_ session: AgentSession, project: AgentProject) -> AgentSession {
        AgentSession(
            id: session.id,
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: session.title,
            status: session.status,
            source: session.source,
            runtimeProvider: session.runtimeProvider,
            resumeID: session.resumeID,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            recencyAt: session.recencyAt,
            preview: session.preview,
            activeTurnID: session.activeTurnID
        )
    }
}
