import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testExternalThreadActiveTurnSendOutcomeRemainsRetryable() {
        let error = CodexAppServerConnectionError.appServer(CodexAppServerError(
            code: -32600,
            message: "thread is active in Codex Desktop",
            data: .object([
                "accepted": .bool(false),
                "retryable": .bool(true),
                "reason": .string("external_thread_active"),
                "retry_after_ms": .int(1_500)
            ])
        ))

        XCTAssertEqual(
            CodexAppServerSessionWebSocketClient.turnSendOutcome(for: error),
            .retryableExternalThreadActive(
                message: error.localizedDescription,
                retryAfterMilliseconds: 1_500
            )
        )
    }

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

    func testDirectRuntimeLatestTurnHistoryUsesOneCompleteTurnPage() async throws {
        let project = AgentProject(id: "proj_latest_turn", name: "Latest Turn", path: "/tmp/latest-turn")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/read", "thread/turns/list"]
                )
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        let pageTask = Task {
            try await client.latestTurnHistoryPage(sessionID: "thr_latest_turn")
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let metadataRead = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        XCTAssertEqual(metadataRead.params?.objectValue?["includeTurns"]?.boolValue, false)
        transportResponse(
            transport,
            id: metadataRead.id,
            result: #"{"thread":{"id":"thr_latest_turn","sessionId":"thr_latest_turn","preview":"latest","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"active"},"path":null,"cwd":"/tmp/latest-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"latest","turns":[]}}"#
        )
        let turnsRequest = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        XCTAssertEqual(turnsRequest.params?.objectValue?["limit"]?.intValue, 1)
        XCTAssertEqual(turnsRequest.params?.objectValue?["sortDirection"]?.stringValue, "desc")
        XCTAssertEqual(turnsRequest.params?.objectValue?["itemsView"]?.stringValue, "full")
        transportResponse(
            transport,
            id: turnsRequest.id,
            result: #"{"data":[{"id":"turn_latest","status":"inProgress","items":[{"type":"userMessage","id":"item_latest_user","content":[{"type":"text","text":"latest prompt"}]},{"type":"agentMessage","id":"item_latest_agent","text":"latest answer","phase":"commentary"}]}],"nextCursor":"older"}"#
        )

        let pageResult = try await pageTask.value
        let page = try XCTUnwrap(pageResult)
        XCTAssertEqual(page.messages.map(\.content), ["latest prompt", "latest answer"])
        XCTAssertEqual(Set(page.messages.compactMap(\.turnID)), ["turn_latest"])
    }

    func testDirectRuntimeLatestTurnHistoryDoesNotFallbackToFullThreadRead() async throws {
        let project = AgentProject(id: "proj_latest_turn_legacy", name: "Legacy Latest", path: "/tmp/latest-legacy")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/read"]
                )
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        let pageTask = Task {
            try await client.latestTurnHistoryPage(sessionID: "thr_latest_legacy")
        }

        let page = try await pageTask.value
        XCTAssertNil(page)
        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        XCTAssertFalse(requests.contains { $0.method == "thread/read" })
        XCTAssertFalse(requests.contains { $0.method == "thread/turns/list" })
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
                    CodexHistoryMessage(
                        role: "assistant",
                        content: "Mac 输出",
                        createdAt: Date(),
                        turnID: "turn-1"
                    )
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
        XCTAssertEqual(client.requestedMessageLimits, [20])

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
        XCTAssertEqual(
            client.requestedMessageLimits,
            [20, 1],
            "运行中 revision 更新只应增量读取最新一个 turn"
        )

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
        XCTAssertEqual(client.requestedMessageLimits, [20, 1, 20])
    }

    func testExternalActivitySnapshotDrivesProcessingSidebarAndReadOnlyComposerLifecycle() async throws {
        let project = makeProject(id: "proj_external_activity_presentation")
        let threadID = "thread-external-presentation"
        let turnID = "turn-external-presentation"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Desktop session",
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
                        turnID: turnID,
                        revision: "rev-external-presentation"
                    )],
                    scannedAt: Date()
                ),
                ExternalActivityResponse(activities: [], scannedAt: Date())
            ]
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID

        let activeRefresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(activeRefresh)

        let external = try XCTUnwrap(store.sessionsByID[threadID])
        let externalStatus = external.displayStatus(foregroundActivity: nil)
        XCTAssertEqual(external.status, SessionStatus.running.rawValue)
        XCTAssertEqual(external.activeTurnID, turnID)
        XCTAssertEqual(externalStatus.title, L10n.text("ui.processing"))
        XCTAssertFalse(externalStatus.showsSpinner)
        let activeSections = SessionListPresentation.sidebarSections(store.sessions)
        let runningSection = try XCTUnwrap(activeSections.first(where: { $0.kind == .running }))
        XCTAssertEqual(runningSection.sessions.map(\.id), [threadID])
        XCTAssertTrue(store.isExternalReadOnlySession(external))
        XCTAssertTrue(store.isSelectedSessionObserving)
        XCTAssertFalse(store.canSendInSelectedSession)
        XCTAssertFalse(store.selectedSessionAllowsTakeOver)
        XCTAssertEqual(store.selectedSessionControlNotice, L10n.text("ui.mac_observe_only"))

        let terminalRefresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(terminalRefresh)

        let released = try XCTUnwrap(store.sessionsByID[threadID])
        XCTAssertEqual(released.status, SessionStatus.history.rawValue)
        XCTAssertNil(released.activeTurnID)
        XCTAssertFalse(
            SessionListPresentation.sidebarSections(store.sessions)
                .contains(where: { $0.kind == .running && $0.sessions.contains(where: { $0.id == threadID }) })
        )
        XCTAssertFalse(store.isExternalReadOnlySession(released))
        XCTAssertFalse(store.isSelectedSessionObserving)
        XCTAssertTrue(store.canSendInSelectedSession)
        XCTAssertNil(store.selectedSessionControlNotice)
    }

    func testExternalActivityRevisionMergesLatestTurnWithoutReplacingLoadedHistoryCursor() async throws {
        let project = makeProject(id: "proj_external_tail_refresh")
        let threadID = "thread-external-tail"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Mac 长会话",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let olderMessage = CodexHistoryMessage(
            role: "user",
            content: "已加载的较早历史",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let latestMessage = CodexHistoryMessage(
            role: "assistant",
            content: "Mac 最新输出",
            createdAt: Date(timeIntervalSince1970: 20),
            turnID: "turn-running"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            historyPages: [
                threadID: HistoryMessagesPage(
                    messages: [latestMessage],
                    previousCursor: "turns:new-tail-cursor",
                    hasMoreBefore: true
                )
            ]
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.conversationStore.setHistory([olderMessage], sessionID: threadID)
        store.historyLoadedSignatureBySessionID[threadID] = HistoryLoadSignature(session: history)
        store.historyLoadedQualityBySessionID[threadID] = .full
        store.historyPreviousCursorBySessionID[threadID] = "turns:loaded-full-cursor"
        store.historyHasMoreBeforeBySessionID[threadID] = true

        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-running",
                revision: "rev-tail"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        XCTAssertEqual(client.requestedMessageLimits, [1])
        XCTAssertEqual(
            store.conversationStore.messages(for: threadID).map(\.content),
            ["已加载的较早历史", "Mac 最新输出"]
        )
        XCTAssertEqual(store.historyPreviousCursorBySessionID[threadID], "turns:loaded-full-cursor")
        XCTAssertTrue(store.historyHasMoreBeforeBySessionID[threadID] == true)
        XCTAssertEqual(store.externalActivityHistoryRevisionBySessionID[threadID], "rev-tail")
    }

    func testExternalActivityRevisionRetriesWhenLatestTurnRefreshFails() async throws {
        let project = makeProject(id: "proj_external_tail_retry")
        let threadID = "thread-external-tail-retry"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Mac 长会话",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            messagesError: MockError.timeout
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.conversationStore.setHistory([
            CodexHistoryMessage(role: "user", content: "已有历史", createdAt: Date(timeIntervalSince1970: 10))
        ], sessionID: threadID)
        store.historyLoadedSignatureBySessionID[threadID] = HistoryLoadSignature(session: history)
        store.historyLoadedQualityBySessionID[threadID] = .full
        let activity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-running",
            revision: "rev-retry"
        )

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

        XCTAssertEqual(client.requestedMessageLimits, [1, 1])
        XCTAssertNil(store.externalActivityHistoryRevisionBySessionID[threadID])
    }

    func testExternalActivityRevisionWithoutTurnIDRetriesOnlyWhenRevisionChanges() async throws {
        let project = makeProject(id: "proj_external_missing_turn")
        let threadID = "thread-external-missing-turn"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "缺少 turn 身份",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            historyPages: [threadID: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    role: "assistant",
                    content: "未归属输出",
                    createdAt: Date(timeIntervalSince1970: 20),
                    turnID: "turn-now-visible"
                )
            ])]
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.conversationStore.setHistory([
            CodexHistoryMessage(role: "user", content: "已有历史", createdAt: Date(timeIntervalSince1970: 10))
        ], sessionID: threadID)
        store.historyLoadedSignatureBySessionID[threadID] = HistoryLoadSignature(session: history)
        store.historyLoadedQualityBySessionID[threadID] = .full
        let activity = ExternalSessionActivity(
            threadID: threadID,
            projectID: project.id,
            source: "codex_desktop",
            state: "running",
            turnID: nil,
            revision: "rev-no-turn",
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )

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

        let revisedWithoutTurn = ExternalSessionActivity(
            threadID: threadID,
            projectID: project.id,
            source: "codex_desktop",
            state: "running",
            turnID: nil,
            revision: "rev-no-turn-2",
            lastActivityAt: Date(timeIntervalSince1970: 110)
        )
        await store.applyExternalActivitySnapshot(
            [revisedWithoutTurn],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        XCTAssertEqual(client.requestedMessageLimits, [20, 20])
        XCTAssertNil(store.externalActivityHistoryRevisionBySessionID[threadID])
        XCTAssertEqual(
            store.externalActivityHistoryAttemptBySessionID[threadID],
            ExternalActivityHistoryAttempt(revision: "rev-no-turn-2", turnID: nil)
        )
        XCTAssertNil(store.externalActivityHistoryFallbackBySessionID[threadID])

        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-now-visible",
                revision: "rev-turn-visible"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        XCTAssertEqual(client.requestedMessageLimits, [20, 20, 1])
        XCTAssertEqual(store.externalActivityHistoryRevisionBySessionID[threadID], "rev-turn-visible")
        XCTAssertNil(store.externalActivityHistoryFallbackBySessionID[threadID])
    }

    func testExternalActivityLatestTurnOversizeDoesNotRetryFullForSameTurn() async throws {
        let project = makeProject(id: "proj_external_tail_oversize")
        let threadID = "thread-external-tail-oversize"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "最新 turn 超限",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            messagesError: historyPolicyError(
                reason: "history_response_too_large",
                responseBytes: 9_000_000,
                maxResponseBytes: 5_242_880,
                method: "thread/turns/list",
                itemsView: "full"
            )
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.conversationStore.setHistory([
            CodexHistoryMessage(role: "user", content: "已有历史", createdAt: Date(timeIntervalSince1970: 10))
        ], sessionID: threadID)
        store.historyLoadedSignatureBySessionID[threadID] = HistoryLoadSignature(session: history)
        store.historyLoadedQualityBySessionID[threadID] = .full
        let firstActivity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-oversize",
            revision: "rev-oversize-1"
        )

        await store.applyExternalActivitySnapshot(
            [firstActivity],
            client: client,
            hostScope: store.appStore.activeHostScope
        )
        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-oversize",
                revision: "rev-oversize-2"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        XCTAssertEqual(client.requestedMessageLimits, [1, 60])
        XCTAssertNil(store.externalActivityHistoryRevisionBySessionID[threadID])
        XCTAssertEqual(store.externalActivityHistoryFallbackBySessionID[threadID]?.mode, .skip)
        XCTAssertEqual(store.externalActivityHistoryFallbackBySessionID[threadID]?.turnID, "turn-oversize")

        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-new",
                revision: "rev-new-turn"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        XCTAssertEqual(client.requestedMessageLimits, [1, 60, 1, 60])
        XCTAssertEqual(store.externalActivityHistoryFallbackBySessionID[threadID]?.turnID, "turn-new")
    }

    func testExternalActivityFullOversizeRetriesOnlyEconomyUntilNewTurnOrTerminal() async throws {
        let project = makeProject(id: "proj_external_full_oversize")
        let threadID = "thread-external-full-oversize"
        let running = makeSession(
            id: threadID,
            projectID: project.id,
            title: "完整历史超限",
            status: SessionStatus.running.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [running])
        )
        let store = makeExternalActivityStore(project: project, session: running, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        let firstActivity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-running",
            revision: "rev-full-oversize-1"
        )

        let firstRefresh = Task {
            await store.applyExternalActivitySnapshot(
                [firstActivity],
                client: client,
                hostScope: store.appStore.activeHostScope
            )
        }
        await client.waitForHistoryRequestCount(1)
        client.failHistoryRequest(
            at: 0,
            with: historyPolicyError(
                reason: "history_response_too_large",
                responseBytes: 9_000_000,
                maxResponseBytes: 5_242_880,
                method: "thread/read",
                itemsView: "fullread"
            )
        )
        await client.waitForHistoryRequestCount(2)
        client.failHistoryRequest(at: 1, with: MockError.timeout)
        await firstRefresh.value

        XCTAssertEqual(client.requestedMessageLimits, [20, 60])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy])
        XCTAssertEqual(store.externalActivityHistoryFallbackBySessionID[threadID]?.mode, .economy)
        XCTAssertNil(store.externalActivityHistoryAttemptBySessionID[threadID])

        let retryEconomy = Task {
            await store.applyExternalActivitySnapshot(
                [firstActivity],
                client: client,
                hostScope: store.appStore.activeHostScope
            )
        }
        await client.waitForHistoryRequestCount(3)
        client.resolveHistoryRequest(
            at: 2,
            with: HistoryMessagesPage(
                messages: [CodexHistoryMessage(
                    role: "assistant",
                    content: "缩略历史 R1",
                    createdAt: Date(timeIntervalSince1970: 20),
                    turnID: "turn-running"
                )],
                loadMode: .economy,
                notice: "当前显示缩略历史。"
            )
        )
        await retryEconomy.value

        await store.applyExternalActivitySnapshot(
            [firstActivity],
            client: client,
            hostScope: store.appStore.activeHostScope
        )
        XCTAssertEqual(client.requestedMessageLimits, [20, 60, 60])

        let revisedActivity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-running",
            revision: "rev-full-oversize-2"
        )
        let revisedEconomy = Task {
            await store.applyExternalActivitySnapshot(
                [revisedActivity],
                client: client,
                hostScope: store.appStore.activeHostScope
            )
        }
        await client.waitForHistoryRequestCount(4)
        client.resolveHistoryRequest(
            at: 3,
            with: HistoryMessagesPage(
                messages: [CodexHistoryMessage(
                    role: "assistant",
                    content: "缩略历史 R2",
                    createdAt: Date(timeIntervalSince1970: 30),
                    turnID: "turn-running"
                )],
                loadMode: .economy
            )
        )
        await revisedEconomy.value

        let newTurnActivity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-new",
            revision: "rev-new-turn"
        )
        let newTurnFull = Task {
            await store.applyExternalActivitySnapshot(
                [newTurnActivity],
                client: client,
                hostScope: store.appStore.activeHostScope
            )
        }
        await client.waitForHistoryRequestCount(5)
        client.resolveHistoryRequest(
            at: 4,
            with: HistoryMessagesPage(messages: [CodexHistoryMessage(
                role: "assistant",
                content: "新 turn 完整历史",
                createdAt: Date(timeIntervalSince1970: 40),
                turnID: "turn-new"
            )])
        )
        await newTurnFull.value

        let terminalRefresh = Task {
            await store.applyExternalActivitySnapshot(
                [],
                client: client,
                hostScope: store.appStore.activeHostScope
            )
        }
        await client.waitForHistoryRequestCount(6)
        client.resolveHistoryRequest(
            at: 5,
            with: HistoryMessagesPage(messages: [CodexHistoryMessage(
                role: "assistant",
                content: "终态完整历史",
                createdAt: Date(timeIntervalSince1970: 50),
                turnID: "turn-new"
            )])
        )
        await terminalRefresh.value

        XCTAssertEqual(client.requestedMessageLimits, [20, 60, 60, 60, 20, 20])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy, .economy, .economy, .full, .full])
        XCTAssertNil(store.externalActivityHistoryFallbackBySessionID[threadID])
    }

    func testExternalActivityRevisionMissingExpectedTurnRetriesLatestPage() async throws {
        let project = makeProject(id: "proj_external_wrong_turn")
        let threadID = "thread-external-wrong-turn"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "turn 尚未可见",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            historyPages: [threadID: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    role: "assistant",
                    content: "旧 turn 输出",
                    createdAt: Date(timeIntervalSince1970: 20),
                    turnID: "turn-older"
                )
            ])]
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.conversationStore.setHistory([
            CodexHistoryMessage(role: "user", content: "已有历史", createdAt: Date(timeIntervalSince1970: 10))
        ], sessionID: threadID)
        store.historyLoadedSignatureBySessionID[threadID] = HistoryLoadSignature(session: history)
        store.historyLoadedQualityBySessionID[threadID] = .full
        let activity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-running",
            revision: "rev-wrong-turn"
        )

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

        XCTAssertEqual(client.requestedMessageLimits, [1, 1])
        XCTAssertNil(store.externalActivityHistoryRevisionBySessionID[threadID])
    }

    func testExternalActivityFullHistoryWithoutExpectedTurnDoesNotAdvanceCoverage() async throws {
        let project = makeProject(id: "proj_external_full_lag")
        let threadID = "thread-external-full-lag"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "完整页尚未看见 turn",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            historyPages: [threadID: HistoryMessagesPage(messages: [])]
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        let activity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-running",
            revision: "rev-full-lag"
        )

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

        XCTAssertEqual(client.requestedMessageLimits, [20, 1])
        XCTAssertNil(store.externalActivityHistoryRevisionBySessionID[threadID])
    }

    func testLateExternalActivityTailDoesNotOverwriteNewerFullHistoryJob() async throws {
        let project = makeProject(id: "proj_external_tail_race")
        let threadID = "thread-external-tail-race"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "并发历史刷新",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [history])
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.conversationStore.setHistory([
            CodexHistoryMessage(role: "user", content: "已有历史", createdAt: Date(timeIntervalSince1970: 10))
        ], sessionID: threadID)
        store.historyLoadedSignatureBySessionID[threadID] = HistoryLoadSignature(session: history)
        store.historyLoadedQualityBySessionID[threadID] = .full
        let activity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-running",
            revision: "rev-race"
        )

        let activityTask = Task { @MainActor in
            await store.applyExternalActivitySnapshot(
                [activity],
                client: client,
                hostScope: store.appStore.activeHostScope
            )
        }
        await client.waitForHistoryRequestCount(1)

        let fullHistoryTask = Task { @MainActor in
            guard let currentSession = store.sessionsByID[threadID] else { return false }
            return await store.loadHistory(
                for: currentSession,
                quiet: true,
                loadMode: .full,
                force: true,
                reason: .manualFull
            )
        }
        await client.waitForHistoryRequestCount(2)
        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    id: "fresh-full-message",
                    role: "assistant",
                    content: "更新的完整历史",
                    createdAt: Date(timeIntervalSince1970: 30),
                    turnID: "turn-running"
                )
            ])
        )
        let didLoadFullHistory = await fullHistoryTask.value
        XCTAssertTrue(didLoadFullHistory)

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    id: "late-tail-message",
                    role: "assistant",
                    content: "迟到的旧增量",
                    createdAt: Date(timeIntervalSince1970: 20),
                    turnID: "turn-running"
                )
            ])
        )
        await activityTask.value

        XCTAssertEqual(client.requestedMessageLimits, [1, 20])
        XCTAssertEqual(
            store.conversationStore.messages(for: threadID).map(\.content),
            ["更新的完整历史"]
        )
        XCTAssertEqual(store.externalActivityHistoryRevisionBySessionID[threadID], "rev-race")
    }

    func testExternalActivityRevisionFallsBackToOneFullRefreshWithoutTurnPaging() async throws {
        let project = makeProject(id: "proj_external_legacy_refresh")
        let threadID = "thread-external-legacy"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "旧 app-server 会话",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            historyPages: [
                threadID: HistoryMessagesPage(messages: [
                    CodexHistoryMessage(
                        role: "assistant",
                        content: "完整历史回退",
                        createdAt: Date(timeIntervalSince1970: 20),
                        turnID: "turn-running"
                    )
                ])
            ],
            supportsLatestTurnHistoryPage: false
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.conversationStore.setHistory([
            CodexHistoryMessage(role: "user", content: "已有历史", createdAt: Date(timeIntervalSince1970: 10))
        ], sessionID: threadID)
        store.historyLoadedSignatureBySessionID[threadID] = HistoryLoadSignature(session: history)
        store.historyLoadedQualityBySessionID[threadID] = .full

        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-running",
                revision: "rev-legacy"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )

        XCTAssertEqual(client.requestedMessageLimits, [20])
        XCTAssertEqual(store.externalActivityHistoryRevisionBySessionID[threadID], "rev-legacy")
        XCTAssertEqual(store.externalActivityHistoryFallbackBySessionID[threadID]?.mode, .skip)

        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-running",
                revision: "rev-legacy-2"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )
        XCTAssertEqual(client.requestedMessageLimits, [20])

        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-new",
                revision: "rev-legacy-new-turn"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )
        XCTAssertEqual(client.requestedMessageLimits, [20, 20])
    }

    func testExternalActivityLegacyFullOversizeRetriesOnlyEconomyAfterTransientFailure() async throws {
        let project = makeProject(id: "proj_external_legacy_oversize")
        let threadID = "thread-external-legacy-oversize"
        let running = makeSession(
            id: threadID,
            projectID: project.id,
            title: "旧协议大历史",
            status: SessionStatus.running.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [running]),
            supportsLatestTurnHistoryPage: false
        )
        let store = makeExternalActivityStore(project: project, session: running, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.conversationStore.setHistory([
            CodexHistoryMessage(
                role: "assistant",
                content: "已加载历史",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: "turn-running"
            )
        ], sessionID: threadID)
        store.historyLoadedSignatureBySessionID[threadID] = HistoryLoadSignature(session: running)
        store.historyLoadedQualityBySessionID[threadID] = .full

        let firstRefresh = Task {
            await store.applyExternalActivitySnapshot(
                [makeExternalActivity(
                    threadID: threadID,
                    projectID: project.id,
                    turnID: "turn-running",
                    revision: "rev-legacy-oversize-1"
                )],
                client: client,
                hostScope: store.appStore.activeHostScope
            )
        }
        await client.waitForHistoryRequestCount(1)
        client.failHistoryRequest(
            at: 0,
            with: historyPolicyError(
                reason: "history_response_too_large",
                responseBytes: 9_000_000,
                maxResponseBytes: 5_242_880,
                method: "thread/read",
                itemsView: "fullread"
            )
        )
        await client.waitForHistoryRequestCount(2)
        client.failHistoryRequest(at: 1, with: MockError.timeout)
        await firstRefresh.value

        XCTAssertEqual(client.requestedMessageLimits, [20, 60])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy])
        XCTAssertEqual(store.externalActivityHistoryFallbackBySessionID[threadID]?.mode, .economy)

        let economyRetry = Task {
            await store.applyExternalActivitySnapshot(
                [makeExternalActivity(
                    threadID: threadID,
                    projectID: project.id,
                    turnID: "turn-running",
                    revision: "rev-legacy-oversize-2"
                )],
                client: client,
                hostScope: store.appStore.activeHostScope
            )
        }
        await client.waitForHistoryRequestCount(3)
        client.resolveHistoryRequest(
            at: 2,
            with: HistoryMessagesPage(
                messages: [CodexHistoryMessage(
                    role: "assistant",
                    content: "缩略历史恢复",
                    createdAt: Date(timeIntervalSince1970: 20),
                    turnID: "turn-running"
                )],
                loadMode: .economy
            )
        )
        await economyRetry.value

        XCTAssertEqual(client.requestedMessageLimits, [20, 60, 60])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy, .economy])
        XCTAssertEqual(store.externalActivityHistoryFallbackBySessionID[threadID]?.mode, .economy)
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

    func testExternalReadOnlySessionDoesNotRunPendingWebSocketReconnectPreflight() async throws {
        let project = makeProject(id: "proj_external_reconnect_guard")
        let threadID = "thread-external-reconnect-guard"
        let running = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Mac 只读会话",
            status: SessionStatus.running.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID,
            activeTurnID: "turn-mac"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            workspacePages: [project.id: SessionsPage(sessions: [running])],
            historyPages: [threadID: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    role: "assistant",
                    content: "不应由迟到 reconnect 重拉",
                    createdAt: Date(timeIntervalSince1970: 20),
                    turnID: "turn-mac"
                )
            ])]
        )
        let store = makeExternalActivityStore(project: project, session: running, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.externalReadOnlySessionIDs.insert(threadID)
        store.externalActivityBySessionID[threadID] = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-mac",
            revision: "rev-external-reconnect"
        )
        store.connectedSessionID = threadID
        store.connectedHostScope = store.appStore.activeHostScope
        store.webSocketReconnectAttemptBySessionID[threadID] = 1

        XCTAssertFalse(store.shouldAutoReconnectWebSocket(sessionID: threadID))
        let reconnectGeneration = store.webSocketReconnectGeneration
        let refreshed = await store.refreshSessionSnapshotBeforeReconnect(
            sessionID: threadID,
            reconnectGeneration: reconnectGeneration
        )
        XCTAssertNil(refreshed)
        await store.runScheduledWebSocketReconnect(
            sessionID: threadID,
            attempt: 1,
            reconnectGeneration: reconnectGeneration
        )

        XCTAssertTrue(client.requestedSessionIDs.isEmpty)
        XCTAssertTrue(client.requestedMessageLimits.isEmpty)
    }

    func testReconnectPreflightReusesJustLoadedFullHistoryAfterMetadataRefresh() async throws {
        let project = makeProject(id: "proj_reconnect_recent_history")
        let threadID = "thread-reconnect-recent-history"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "刚加载完成的长会话",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        var refreshed = history
        refreshed.updatedAt = Date(timeIntervalSince1970: 200)
        let sessionGate = SessionResponseGate()
        let socket = MockWebSocketClient()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            sessionHandler: { _, _ in try await sessionGate.response() },
            historyPages: [threadID: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    role: "assistant",
                    content: "刚完成的完整首屏",
                    createdAt: Date(timeIntervalSince1970: 100)
                )
            ])]
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client, socket: socket)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID

        let firstLoad = await store.loadHistory(for: history, quiet: true)
        XCTAssertTrue(firstLoad)
        XCTAssertEqual(client.requestedMessageLimits, [20])

        store.webSocketReconnectAttemptBySessionID[threadID] = 1
        let reconnectGeneration = store.webSocketReconnectGeneration
        let reconnect = Task { @MainActor in
            await store.runScheduledWebSocketReconnect(
                sessionID: threadID,
                attempt: 1,
                reconnectGeneration: reconnectGeneration
            )
        }
        await sessionGate.waitUntilRequested()
        // 模拟 thread/read 自身很慢并跨过 4 秒 TTL；是否复用必须锚定 preflight 开始时刻。
        for key in Array(store.historyFirstPageCacheByKey.keys) {
            guard let entry = store.historyFirstPageCacheByKey[key] else { continue }
            store.historyFirstPageCacheByKey[key] = HistoryFirstPageCacheEntry(
                page: entry.page,
                loadedAt: .distantPast,
                token: entry.token
            )
        }
        sessionGate.resolve(SessionResponse(session: refreshed))
        await reconnect.value

        XCTAssertEqual(store.sessionsByID[threadID]?.updatedAt, refreshed.updatedAt)
        XCTAssertEqual(client.requestedSessionIDs, [threadID])
        XCTAssertEqual(
            client.requestedMessageLimits,
            [20],
            "thread/read 更新 metadata 后，4 秒短窗内不能再次下载同一完整首屏"
        )
        XCTAssertEqual(socket.connectedSessionIDs, [threadID], "短缓存只省略重复历史，不能阻止 reconnect/resume")

        // 下一次 preflight 开始时缓存已经过期，必须恢复正常的历史补拉，不能把短窗变成长久跳过。
        store.webSocketReconnectAttemptBySessionID[threadID] = 2
        let expiredReconnectGeneration = store.webSocketReconnectGeneration
        let expiredReconnect = Task { @MainActor in
            await store.runScheduledWebSocketReconnect(
                sessionID: threadID,
                attempt: 2,
                reconnectGeneration: expiredReconnectGeneration
            )
        }
        await sessionGate.waitUntilRequested()
        sessionGate.resolve(SessionResponse(session: refreshed))
        await expiredReconnect.value

        XCTAssertEqual(client.requestedMessageLimits, [20, 20])
        XCTAssertEqual(socket.connectedSessionIDs, [threadID, threadID])
    }

    func testExternalActivityInvalidatesReconnectWhileSessionReadIsInFlight() async throws {
        let project = makeProject(id: "proj_external_reconnect_race")
        let threadID = "thread-external-reconnect-race"
        let running = makeSession(
            id: threadID,
            projectID: project.id,
            title: "重连中切为 Mac 只读",
            status: SessionStatus.running.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID,
            activeTurnID: "turn-mac"
        )
        let gate = SessionResponseGate()
        let socket = MockWebSocketClient()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            workspacePages: [project.id: SessionsPage(sessions: [running])],
            sessionHandler: { _, _ in try await gate.response() },
            historyPages: [threadID: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    role: "assistant",
                    content: "Mac 最新输出",
                    createdAt: Date(timeIntervalSince1970: 20),
                    turnID: "turn-mac"
                )
            ])]
        )
        let store = makeExternalActivityStore(project: project, session: running, client: client, socket: socket)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.connectedSessionID = threadID
        store.connectedHostScope = store.appStore.activeHostScope
        store.webSocketReconnectAttemptBySessionID[threadID] = 1
        let reconnectGeneration = store.webSocketReconnectGeneration

        let reconnect = Task { @MainActor in
            await store.runScheduledWebSocketReconnect(
                sessionID: threadID,
                attempt: 1,
                reconnectGeneration: reconnectGeneration
            )
        }
        await gate.waitUntilRequested()

        await store.applyExternalActivitySnapshot(
            [makeExternalActivity(
                threadID: threadID,
                projectID: project.id,
                turnID: "turn-mac",
                revision: "rev-race"
            )],
            client: client,
            hostScope: store.appStore.activeHostScope
        )
        gate.resolve(SessionResponse(session: running))
        await reconnect.value

        XCTAssertEqual(client.requestedSessionIDs, [threadID])
        XCTAssertEqual(
            client.requestedMessageLimits,
            [20],
            "唯一 full 来自 external-activity 对账；迟到的 reconnect 不能再发第二页"
        )
        XCTAssertTrue(socket.connectedSessionIDs.isEmpty)
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
        XCTAssertTrue(store.canReconcileTurnOutcomeFromRetiredSocket(
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

    func testRetryableExternalThreadActiveKeepsMessageQueuedUntilDesktopTurnEnds() async throws {
        let project = makeProject(id: "proj_external_retryable_send")
        let threadID = "thread-external-retryable-send"
        let clientMessageID = "client-external-retryable-send"
        let session = makeSession(
            id: threadID,
            projectID: project.id,
            title: "外部占用后续发",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let activity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-desktop-live",
            revision: "rev-desktop-live"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            workspacePages: [project.id: SessionsPage(sessions: [session])],
            historyPages: [threadID: HistoryMessagesPage(messages: [])],
            externalActivityResponses: [
                ExternalActivityResponse(activities: [activity], scannedAt: Date()),
                ExternalActivityResponse(activities: [], scannedAt: Date())
            ]
        )
        let socket = MockWebSocketClient()
        let store = makeExternalActivityStore(
            project: project,
            session: session,
            client: client,
            socket: socket
        )
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.sessionControlStateByID[threadID] = .takenOver
        let payload = CodexAppServerTurnPayload(prompt: "Desktop 完成后继续发送")
        store.conversationStore.appendLocalUser(
            payload.previewText,
            sessionID: threadID,
            clientMessageID: clientMessageID,
            sendStatus: .sending,
            turnPayload: payload
        )

        store.handleTurnSendOutcome(
            clientMessageID: clientMessageID,
            sessionID: threadID,
            outcome: .retryableExternalThreadActive(
                message: "Desktop 正在执行这个会话",
                retryAfterMilliseconds: 0
            )
        )

        for _ in 0..<80 where client.externalActivityCallCount < 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(client.externalActivityCallCount, 1)
        XCTAssertEqual(
            store.queuedRunningTurnsBySessionID[threadID]?.first?.dispatchState,
            .waiting
        )
        XCTAssertEqual(
            store.conversationStore.messages(for: threadID)
                .first(where: { $0.clientMessageID == clientMessageID })?
                .sendStatus,
            .local
        )
        XCTAssertTrue(store.externalReadOnlySessionIDs.contains(threadID))
        XCTAssertTrue(socket.sentTurns.isEmpty)

        let terminalRefresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(terminalRefresh)
        XCTAssertFalse(store.externalReadOnlySessionIDs.contains(threadID))
        XCTAssertEqual(socket.connectedSessionIDs, [threadID])

        socket.emitStatus(.connected)
        try await waitForSentTurnCount(1, socket: socket)
        XCTAssertEqual(socket.sentTurns.first?.payload.textPrompt, payload.textPrompt)
        XCTAssertEqual(
            store.queuedRunningTurnsBySessionID[threadID]?.first?.dispatchState,
            .dispatching
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
        client: any SessionStoreAPIClient,
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
