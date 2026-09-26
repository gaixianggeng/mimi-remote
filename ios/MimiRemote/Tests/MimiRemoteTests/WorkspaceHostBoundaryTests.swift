import XCTest
@testable import MimiRemote

@MainActor
final class WorkspaceHostBoundaryTests: XCTestCase {
    private let root = AgentProject(id: "root", name: "Root", path: "/tmp/root")

    func testWorkspaceBootstrapCatalogAndWorktreeListDoNotCreateSessionRuntime() async throws {
        let host = WorkspaceHostProbe(projects: [root])
        var sessionClientCreations = 0
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: {
                sessionClientCreations += 1
                throw AgentAPIError.invalidResponse
            },
            workspaceHostClientFactory: { host }
        )

        try await store.refreshWorkspaceCatalog()
        await store.refreshManagedWorktrees()
        await store.refreshAll()

        XCTAssertEqual(sessionClientCreations, 0)
        XCTAssertEqual(host.projectRequests, 2)
        XCTAssertEqual(host.worktreeListRequests, 1)
        XCTAssertEqual(store.projects, [root])
    }

    func testOldHostWorktreeCreateCannotWriteNewHostWorkspaceState() async throws {
        let appStore = makeIsolatedAppStore()
        let gate = WorkspaceCreateResponseGate()
        let host = WorkspaceHostProbe(projects: [root])
        host.createHandler = { await gate.waitForResponse() }
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { throw AgentAPIError.invalidResponse },
            workspaceHostClientFactory: { host }
        )

        let task = Task { await store.createWorktreeAndOpen(project: root) }
        await gate.waitForRequest()
        let oldScope = appStore.activeHostScope
        try await switchHost(appStore)
        XCTAssertNotEqual(appStore.activeHostScope, oldScope)
        store.clearConnectionData()
        gate.finish(worktreeResponse())

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertNil(store.workspacesByID["old-worktree"])
        XCTAssertTrue(store.managedWorktrees.isEmpty)
    }

    func testOldHostWorktreeListCannotReplaceCurrentDataOrLoading() async throws {
        let appStore = makeIsolatedAppStore()
        let host = WorkspaceHostProbe(projects: [root])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { throw AgentAPIError.invalidResponse },
            workspaceHostClientFactory: { host }
        )
        host.listHandler = {
            try await self.switchHost(appStore)
            store.clearConnectionData()
            store.worktreeErrorMessage = "new-host-error"
            store.isRefreshingWorktrees = true
            let response = self.worktreeResponse()
            return [WorktreeListItem(workspace: response.workspace, worktree: response.worktree)]
        }

        await store.refreshManagedWorktrees()

        XCTAssertTrue(store.managedWorktrees.isEmpty)
        XCTAssertEqual(store.worktreeErrorMessage, "new-host-error")
        XCTAssertTrue(store.isRefreshingWorktrees)
    }

    func testOldHostCatalogFailureBecomesCancellation() async throws {
        let appStore = makeIsolatedAppStore()
        let host = WorkspaceHostProbe(projects: [root])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { throw AgentAPIError.invalidResponse },
            workspaceHostClientFactory: { host }
        )
        host.projectHandler = {
            try await self.switchHost(appStore)
            throw URLError(.timedOut)
        }

        do {
            try await store.refreshWorkspaceCatalog()
            XCTFail("旧主机请求必须取消")
        } catch is CancellationError {
            XCTAssertTrue(store.projects.isEmpty)
        }
    }

    func testHandoffHistorySuccessAfterHostSwitchCannotWriteNewHostConversation() async throws {
        try await assertOldHostHandoffCannotWriteNewHost(historyError: nil)
    }

    func testHandoffHistoryCancellationAfterHostSwitchCannotWriteNewHostConversation() async throws {
        try await assertOldHostHandoffCannotWriteNewHost(historyError: CancellationError())
    }

    func testCancelledHandoffCannotAppendCompletionAfterHistoryReturns() async {
        let fixture = handoffFixture()
        let task = Task { await fixture.store.handoffSessionToWorktree(fixture.source) }
        await fixture.history.waitForHistoryRequestCount(1)

        task.cancel()
        fixture.history.resolveHistoryRequest(at: 0, with: HistoryMessagesPage(messages: []))

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertTrue(fixture.store.conversationStore.messages(for: fixture.forked.id).isEmpty)
    }

    func testHandoffHistoryCompletionAppendsToForkedConversation() async {
        await assertHandoffAppendsCompletion(navigateAway: false)
    }

    func testHandoffHistoryCompletionAfterSameHostNavigationKeepsForkedConversation() async {
        await assertHandoffAppendsCompletion(navigateAway: true)
    }

    func testOldHostEarlierHistorySuccessCannotChangeNewHostPageOrLoading() async throws {
        try await assertOldHostEarlierHistoryCannotChangeNewHost(error: nil)
    }

    func testOldHostEarlierHistoryFailureCannotChangeNewHostPageOrLoading() async throws {
        try await assertOldHostEarlierHistoryCannotChangeNewHost(error: AgentAPIError.invalidResponse)
    }

    func testEarlierHistoryCompletionCannotOverwritePendingFirstPageRefresh() async {
        let (store, session, history) = paginationFixture()
        let older = Task { await store.loadEarlierHistory(sessionID: session.id) }
        await history.waitForHistoryRequestCount(1)
        let refresh = Task { await store.loadHistory(for: session, force: true) }
        await history.waitForHistoryRequestCount(2)
        let refreshProgress = store.historyLoadProgress(sessionID: session.id)

        // 新首屏等待时不允许使用旧 cursor 再发分页；旧 defer 也不能清除首屏进度。
        await store.loadEarlierHistory(sessionID: session.id)
        XCTAssertEqual(history.requestedMessageCursors.count, 2)
        history.resolveHistoryRequest(at: 0, with: paginationPage("obsolete", cursor: "obsolete-cursor"))
        await older.value

        XCTAssertFalse(store.conversationStore.messages(for: session.id).contains { $0.content == "obsolete" })
        XCTAssertEqual(store.historyLoadProgress(sessionID: session.id), refreshProgress)
        XCTAssertFalse(store.loadingEarlierHistorySessionIDs.contains(session.id))
        history.resolveHistoryRequest(at: 1, with: paginationPage("refreshed", cursor: "refreshed-cursor"))
        let loaded = await refresh.value
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.historyPreviousCursorBySessionID[session.id], "refreshed-cursor")
        XCTAssertNil(store.historyLoadProgress(sessionID: session.id))
    }

    func testEarlierHistoryFailureAfterRefreshCannotCloseNewPaginationOrClearItsLoading() async {
        let (store, session, history) = paginationFixture()
        let older = Task { await store.loadEarlierHistory(sessionID: session.id) }
        await history.waitForHistoryRequestCount(1)
        let refresh = Task { await store.loadHistory(for: session, force: true) }
        await history.waitForHistoryRequestCount(2)
        history.resolveHistoryRequest(at: 1, with: paginationPage("refreshed", cursor: "refreshed-cursor"))
        _ = await refresh.value
        let currentOlder = Task { await store.loadEarlierHistory(sessionID: session.id) }
        await history.waitForHistoryRequestCount(3)
        let currentProgress = store.historyLoadProgress(sessionID: session.id)
        store.setErrorMessage("current-error")

        history.failHistoryRequest(at: 0, with: AgentAPIError.invalidResponse)
        await older.value

        XCTAssertEqual(store.historyPreviousCursorBySessionID[session.id], "refreshed-cursor")
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: session.id))
        XCTAssertTrue(store.loadingEarlierHistorySessionIDs.contains(session.id))
        XCTAssertEqual(store.historyLoadProgress(sessionID: session.id), currentProgress)
        XCTAssertEqual(store.errorMessage, "current-error")
        history.resolveHistoryRequest(at: 2, with: paginationPage("current-older"))
        await currentOlder.value
        XCTAssertTrue(store.conversationStore.messages(for: session.id).contains { $0.content == "current-older" })
        XCTAssertFalse(store.loadingEarlierHistorySessionIDs.contains(session.id))
    }

    func testCancelledEarlierHistoryCannotApplyLateSuccessAndReleasesItsLoading() async {
        let (store, session, history) = paginationFixture()
        let older = Task { await store.loadEarlierHistory(sessionID: session.id) }
        await history.waitForHistoryRequestCount(1)
        store.setErrorMessage("existing-error")
        older.cancel()
        history.resolveHistoryRequest(at: 0, with: paginationPage("cancelled"))
        await older.value

        XCTAssertEqual(store.conversationStore.messages(for: session.id).map(\.content), ["initial"])
        XCTAssertEqual(store.historyPreviousCursorBySessionID[session.id], "initial-cursor")
        XCTAssertEqual(store.errorMessage, "existing-error")
        XCTAssertFalse(store.loadingEarlierHistorySessionIDs.contains(session.id))
        XCTAssertNil(store.historyLoadProgress(sessionID: session.id))
    }

    func testEarlierHistoryAfterSameHostNavigationStillUpdatesOriginalConversation() async {
        let (store, session, history) = paginationFixture()
        let older = Task { await store.loadEarlierHistory(sessionID: session.id) }
        await history.waitForHistoryRequestCount(1)
        _ = store.commitSelection(projectID: root.id, sessionID: nil, reason: .userOpen)
        store.setErrorMessage("other-selection-error")
        history.resolveHistoryRequest(at: 0, with: paginationPage("older"))
        await older.value

        XCTAssertTrue(store.conversationStore.messages(for: session.id).contains { $0.content == "older" })
        XCTAssertFalse(store.canLoadEarlierHistory(sessionID: session.id))
        XCTAssertEqual(store.errorMessage, "other-selection-error")
        XCTAssertNil(store.historyLoadProgress(sessionID: session.id))
    }

    func testEarlierHistoryContinuityRecoveryFailureDoesNotRetryIndefinitely() async {
        let (store, session, history) = paginationFixture()
        let older = Task { await store.loadEarlierHistory(sessionID: session.id) }
        await history.waitForHistoryRequestCount(1)
        history.failHistoryRequest(at: 0, with: HarnessTransportError.continuityLost("obsolete cursor"))
        await history.waitForHistoryRequestCount(2)
        history.failHistoryRequest(at: 1, with: HarnessTransportError.continuityLost("snapshot unavailable"))
        await older.value

        XCTAssertEqual(history.requestedMessageCursors, ["initial-cursor", nil])
        XCTAssertEqual(store.conversationStore.messages(for: session.id).map(\.content), ["initial"])
        XCTAssertFalse(store.loadingEarlierHistorySessionIDs.contains(session.id))
        XCTAssertNil(store.historyLoadProgress(sessionID: session.id))
        // full 首屏失败统一显示历史失败提示与状态；summary 才使用全局 errorMessage。
        XCTAssertEqual(store.historySavingsNoticesBySessionID[session.id]?.kind, .fullFailed)
        XCTAssertNotNil(store.statusMessage)
        XCTAssertNil(store.errorMessage)
    }

    func testOldHostContinuityRecoverySuccessCannotCommitOrClearNewHostFirstPage() async throws {
        try await assertOldHostContinuityRecoveryCannotChangeNewHost(error: nil)
    }

    func testOldHostContinuityRecoveryFailureCannotCommitOrClearNewHostFirstPage() async throws {
        try await assertOldHostContinuityRecoveryCannotChangeNewHost(error: AgentAPIError.invalidResponse, reuseProfile: true)
    }

    func testCachedFirstPageDoesNotResetAlreadyAdvancedPagination() async throws {
        let (store, session, history) = paginationFixture()
        let first = Task {
            try await store.historyFirstPage(sessionID: session.id, limit: 20, loadMode: .full, cachePolicy: .bypass)
        }
        await history.waitForHistoryRequestCount(1)
        history.resolveHistoryRequest(
            at: 0, with: paginationPage("first", cursor: "first-cursor", resetsPaginationContext: true)
        )
        let firstResult = try await first.value
        store.updateHistoryPageState(sessionID: session.id, page: firstResult.page, preserveExistingCursorOnEmptyPage: false)
        store.updateHistoryPageState(
            sessionID: session.id, page: paginationPage("older", cursor: "deep-cursor"),
            requestedCursor: "first-cursor", preserveExistingCursorOnEmptyPage: false
        )
        store.historySessionsWithAdditionalPages.insert(session.id)

        let cached = try await store.historyFirstPage(
            sessionID: session.id, limit: 20, loadMode: .full, cachePolicy: .reuseRecent
        )
        store.updateHistoryPageState(sessionID: session.id, page: cached.page, preserveExistingCursorOnEmptyPage: true)

        XCTAssertFalse(cached.page.resetsPaginationContext)
        XCTAssertEqual(history.requestedMessageCursors.count, 1)
        XCTAssertEqual(store.historyPreviousCursorBySessionID[session.id], "deep-cursor")
    }

    func testNewPaginationContextReopensExhaustedHistoryToFillOfflineGrowthGap() async {
        let (store, session, history) = paginationFixture()
        store.historySessionsWithAdditionalPages.insert(session.id)
        store.closeHistoryPagination(sessionID: session.id)
        let refresh = Task { await store.loadHistory(for: session, force: true) }
        await history.waitForHistoryRequestCount(1)
        history.resolveHistoryRequest(
            at: 0, with: paginationPage("offline-newest", cursor: "gap-page-1", resetsPaginationContext: true)
        )
        let refreshed = await refresh.value
        XCTAssertTrue(refreshed)
        guard store.canLoadEarlierHistory(sessionID: session.id) else {
            return XCTFail("新快照有更多消息，必须重新开放分页来填补离线增长的间隙")
        }
        XCTAssertEqual(Set(store.conversationStore.messages(for: session.id).map(\.content)), ["initial", "offline-newest"])

        let gap = Task { await store.loadEarlierHistory(sessionID: session.id) }
        await history.waitForHistoryRequestCount(2)
        history.resolveHistoryRequest(at: 1, with: paginationPage("offline-middle", cursor: "gap-page-2"))
        await gap.value
        let overlap = Task { await store.loadEarlierHistory(sessionID: session.id) }
        await history.waitForHistoryRequestCount(3)
        history.resolveHistoryRequest(at: 2, with: paginationPage("initial"))
        await overlap.value

        XCTAssertEqual(history.requestedMessageCursors, [nil, "gap-page-1", "gap-page-2"])
        XCTAssertEqual(Set(store.conversationStore.messages(for: session.id).map(\.content)),
                       ["initial", "offline-newest", "offline-middle"])
        XCTAssertEqual(store.conversationStore.messages(for: session.id).filter { $0.content == "initial" }.count, 1)
        XCTAssertFalse(store.canLoadEarlierHistory(sessionID: session.id))
        XCTAssertNil(store.historyPreviousCursorBySessionID[session.id])
    }

    func testEmptyNewPaginationContextCannotPreserveObsoleteCursor() {
        let (store, session, _) = paginationFixture()
        store.historySessionsWithAdditionalPages.insert(session.id)
        store.updateHistoryPageState(
            sessionID: session.id,
            page: HistoryMessagesPage(messages: [], resetsPaginationContext: true),
            preserveExistingCursorOnEmptyPage: true
        )

        XCTAssertFalse(store.canLoadEarlierHistory(sessionID: session.id))
        XCTAssertNil(store.historyPreviousCursorBySessionID[session.id])
        XCTAssertEqual(store.conversationStore.messages(for: session.id).map(\.content), ["initial"])
    }

    func testAcceptedResumeIsSentWhileHistoryWaitsThenSubscribesWithoutContentReplay() async {
        await assertResumeAcknowledgementPrecedesHistory(historyFails: false, queuesInitialInput: false)
    }

    func testAcceptedResumeStaysSentWhenHistoryFailsThenSubscribesWithContentReplay() async {
        await assertResumeAcknowledgementPrecedesHistory(historyFails: true, queuesInitialInput: false)
    }

    func testNativeResumePreparationDoesNotMarkQueuedInputSentWhileHistoryWaits() async {
        await assertResumeAcknowledgementPrecedesHistory(historyFails: false, queuesInitialInput: true)
    }

    private func assertResumeAcknowledgementPrecedesHistory(historyFails: Bool, queuesInitialInput: Bool) async {
        let provider = queuesInitialInput ? "deepseek" : "codex"
        let session = AgentSession(
            id: "resume-thread", projectID: root.id, project: root.name, dir: root.path,
            title: "Resume", status: "history", source: provider, resumeID: "resume-thread",
            createdAt: nil, updatedAt: nil
        )
        var resumed = session
        resumed.status = "running"
        let history = OrderedHistoryPageClient(projects: [root], page: SessionsPage(sessions: [session]))
        let client = ResumeAcknowledgementClient(
            response: CreateSessionResponse(
                session: resumed, wsURL: "/ws", requiresQueuedInitialInput: queuesInitialInput
            ),
            history: history
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let socket = MockWebSocketClient()
        let store = SessionStore(
            appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { client }, webSocketFactory: { socket }
        )
        store.projects = [root]
        store.sessions = [session]
        _ = store.commitSelection(projectID: root.id, sessionID: session.id, reason: .userOpen)
        var payload = CodexAppServerTurnPayload(prompt: "continue history")
        payload.options.runtimeProvider = provider
        payload.options.model = "fixture-model"
        payload.options.modelSelectionPolicy = .allowUnlisted
        payload.options.sandboxMode = .dangerFullAccess
        let send = Task {
            await store.createSession(projectID: root.id, payload: payload, resume: session, clientMessageID: "resume-input")
        }
        await history.waitForHistoryRequestCount(1)

        let pendingMessages = store.conversationStore.messages(for: session.id)
        XCTAssertEqual(pendingMessages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(pendingMessages.first { $0.clientMessageID == "resume-input" }?.sendStatus,
                       queuesInitialInput ? .sending : .sent)
        XCTAssertTrue(store.isLoading, "上下文仍未准备完成，不提前解除发送中的页面占用")
        XCTAssertTrue(socket.connectedSessionIDs.isEmpty, "历史首屏仍先于 live 订阅")
        if historyFails {
            history.failHistoryRequest(at: 0, with: URLError(.timedOut))
        } else {
            history.resolveHistoryRequest(at: 0, with: paginationPage("existing history"))
        }
        let accepted = await send.value

        XCTAssertTrue(accepted)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(socket.replayBufferedEventsByConnect, [historyFails])
        let messages = store.conversationStore.messages(for: session.id)
        XCTAssertEqual(messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(messages.first { $0.clientMessageID == "resume-input" }?.sendStatus,
                       queuesInitialInput ? .sending : .sent)
        if !historyFails {
            XCTAssertTrue(messages.contains { $0.content == "existing history" })
        }
        store.clearConnectionData()
    }

    private func assertOldHostEarlierHistoryCannotChangeNewHost(error: Error?) async throws {
        let (store, session, history) = paginationFixture()
        let oldScope = store.appStore.activeHostScope
        let older = Task { await store.loadEarlierHistory(sessionID: session.id) }
        await history.waitForHistoryRequestCount(1)
        _ = try await store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "host-b", displayName: "Host B"),
            installationID: "installation-b"
        ))
        XCTAssertNotEqual(store.appStore.activeHostScope, oldScope)
        preparePagination(store: store, session: session, content: "new-host", cursor: "new-host-cursor")
        let currentOlder = Task { await store.loadEarlierHistory(sessionID: session.id) }
        await history.waitForHistoryRequestCount(2)
        let currentProgress = store.historyLoadProgress(sessionID: session.id)
        store.setErrorMessage("new-host-error")

        if let error {
            history.failHistoryRequest(at: 0, with: error)
        } else {
            history.resolveHistoryRequest(at: 0, with: paginationPage("old-host", cursor: "old-host-cursor"))
        }
        await older.value

        XCTAssertEqual(store.conversationStore.messages(for: session.id).map(\.content), ["new-host"])
        XCTAssertEqual(store.historyPreviousCursorBySessionID[session.id], "new-host-cursor")
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: session.id))
        XCTAssertTrue(store.loadingEarlierHistorySessionIDs.contains(session.id))
        XCTAssertEqual(store.historyLoadProgress(sessionID: session.id), currentProgress)
        XCTAssertEqual(store.errorMessage, "new-host-error")
        history.resolveHistoryRequest(at: 1, with: paginationPage("new-host-older"))
        await currentOlder.value
        XCTAssertTrue(store.conversationStore.messages(for: session.id).contains { $0.content == "new-host-older" })
        XCTAssertFalse(store.loadingEarlierHistorySessionIDs.contains(session.id))
        XCTAssertNil(store.historyLoadProgress(sessionID: session.id))
    }

    private func assertOldHostContinuityRecoveryCannotChangeNewHost(error: Error?, reuseProfile: Bool = false) async throws {
        let (store, session, history) = paginationFixture()
        _ = try await store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.10:8787", token: "token-a",
            profileTarget: .newProfile(id: "host-a", displayName: "Host A")
        ))
        preparePagination(store: store, session: session, content: "initial", cursor: "initial-cursor")
        let oldScope = store.appStore.activeHostScope
        let older = Task { await store.loadEarlierHistory(sessionID: session.id) }
        await history.waitForHistoryRequestCount(1)
        history.failHistoryRequest(at: 0, with: HarnessTransportError.continuityLost("obsolete cursor"))
        await history.waitForHistoryRequestCount(2)
        let oldJobToken = store.historyLoadJobsBySessionID[session.id]?.token
        let oldPageToken = store.historyPageRequestTokenBySessionID[session.id]

        _ = try await store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787", token: "token-b",
            profileTarget: reuseProfile ? .existingProfile(id: "host-a") : .newProfile(id: "host-b", displayName: "Host B")
        ))
        XCTAssertNotEqual(store.appStore.activeHostScope, oldScope)
        if reuseProfile {
            XCTAssertEqual(store.appStore.activeHostScope.profileID, oldScope.profileID)
            store.conversationStore.reset(sessionID: session.id)
        }
        preparePagination(store: store, session: session, content: "new-host", cursor: "new-host-cursor")
        let current = Task { await store.loadHistory(for: session, force: true) }
        await history.waitForHistoryRequestCount(3)
        // clearConnectionData 后两个整数代次都重新从 1 开始，明确制造 token 相同的 ABA。
        XCTAssertEqual(store.historyLoadJobsBySessionID[session.id]?.token, oldJobToken)
        XCTAssertEqual(store.historyPageRequestTokenBySessionID[session.id], oldPageToken)
        let currentPageKey = store.historyFirstPageInFlightByKey.keys.first
        let currentProgress = store.historyLoadProgress(sessionID: session.id)
        store.setErrorMessage("new-host-error")
        store.setStatusMessage("new-host-status")

        if let error {
            history.failHistoryRequest(at: 1, with: error)
        } else {
            history.resolveHistoryRequest(at: 1, with: paginationPage("old-host-recovery", cursor: "old-host-cursor"))
        }
        await older.value

        XCTAssertEqual(store.conversationStore.messages(for: session.id).map(\.content), ["new-host"])
        XCTAssertEqual(store.historyPreviousCursorBySessionID[session.id], "new-host-cursor")
        XCTAssertEqual(store.historyLoadJobsBySessionID[session.id]?.token, oldJobToken)
        XCTAssertEqual(currentPageKey.flatMap { store.historyFirstPageInFlightByKey[$0]?.token }, oldPageToken)
        XCTAssertEqual(store.historyLoadProgress(sessionID: session.id), currentProgress)
        XCTAssertNil(store.historySavingsNoticesBySessionID[session.id])
        XCTAssertEqual(store.errorMessage, "new-host-error")
        XCTAssertEqual(store.statusMessage, "new-host-status")
        history.resolveHistoryRequest(at: 2, with: paginationPage("new-host-refreshed", cursor: "new-host-next"))
        let loaded = await current.value
        XCTAssertTrue(loaded)
        XCTAssertTrue(store.conversationStore.messages(for: session.id).contains { $0.content == "new-host-refreshed" })
        XCTAssertEqual(store.historyPreviousCursorBySessionID[session.id], "new-host-next")
        XCTAssertNil(store.historyLoadProgress(sessionID: session.id))
        XCTAssertNil(store.historyLoadJobsBySessionID[session.id])
    }

    private func paginationFixture() -> (SessionStore, AgentSession, OrderedHistoryPageClient) {
        let session = AgentSession(
            id: "history-thread", projectID: root.id, project: root.name, dir: root.path,
            title: "History", status: "history", source: "codex", resumeID: "history-thread",
            createdAt: nil, updatedAt: nil
        )
        let history = OrderedHistoryPageClient(projects: [root], page: SessionsPage(sessions: [session]))
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(),
            logStore: LogStore(), clientFactory: { history }
        )
        preparePagination(store: store, session: session, content: "initial", cursor: "initial-cursor")
        return (store, session, history)
    }

    private func preparePagination(store: SessionStore, session: AgentSession, content: String, cursor: String) {
        store.projects = [root]
        store.sessions = [session]
        _ = store.commitSelection(projectID: root.id, sessionID: session.id, reason: .userOpen)
        _ = store.beginHistoryLoadJob(sessionID: session.id)
        _ = store.beginHistoryPageRequest(sessionID: session.id)
        let page = paginationPage(content, cursor: cursor)
        store.conversationStore.setHistory(page.messages, sessionID: session.id)
        store.updateHistoryPageState(sessionID: session.id, page: page, preserveExistingCursorOnEmptyPage: false)
        store.historyLoadedQualityBySessionID[session.id] = .full
    }

    private func paginationPage(
        _ content: String, cursor: String? = nil, resetsPaginationContext: Bool = false
    ) -> HistoryMessagesPage {
        HistoryMessagesPage(
            messages: [CodexHistoryMessage(id: content, role: "assistant", content: content, createdAt: nil)],
            previousCursor: cursor, hasMoreBefore: cursor != nil,
            resetsPaginationContext: resetsPaginationContext
        )
    }

    private func assertOldHostHandoffCannotWriteNewHost(historyError: Error?) async throws {
        let fixture = handoffFixture()
        let task = Task { await fixture.store.handoffSessionToWorktree(fixture.source) }
        await fixture.history.waitForHistoryRequestCount(1)
        let oldScope = fixture.store.appStore.activeHostScope

        // 使用真实提交入口切换 ConversationStore namespace，并取消旧历史 job。
        _ = try await fixture.store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "host-b", displayName: "Host B"),
            installationID: "installation-b"
        ))
        XCTAssertNotEqual(fixture.store.appStore.activeHostScope, oldScope)
        fixture.store.conversationStore.appendSystem("new-host-message", sessionID: fixture.forked.id)

        if let historyError {
            fixture.history.failHistoryRequest(at: 0, with: historyError)
        } else {
            fixture.history.resolveHistoryRequest(at: 0, with: HistoryMessagesPage(messages: []))
        }

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(
            fixture.store.conversationStore.messages(for: fixture.forked.id).map(\.content),
            ["new-host-message"]
        )
    }

    private func assertHandoffAppendsCompletion(navigateAway: Bool) async {
        let fixture = handoffFixture()
        let task = Task { await fixture.store.handoffSessionToWorktree(fixture.source) }
        await fixture.history.waitForHistoryRequestCount(1)

        if navigateAway {
            _ = fixture.store.commitSelection(
                projectID: root.id,
                sessionID: fixture.source.id,
                reason: .userOpen
            )
        }
        fixture.history.resolveHistoryRequest(at: 0, with: HistoryMessagesPage(messages: []))

        let result = await task.value
        XCTAssertTrue(result)
        XCTAssertEqual(
            fixture.store.selectedSessionID,
            navigateAway ? fixture.source.id : fixture.forked.id
        )
        XCTAssertEqual(
            fixture.store.conversationStore.messages(for: fixture.forked.id).map(\.content),
            [L10n.text("ui.this_worktree_has_been_forked_from_the_source")]
        )
        XCTAssertTrue(fixture.store.conversationStore.messages(for: fixture.source.id).isEmpty)
    }

    private func handoffFixture() -> (
        store: SessionStore, source: AgentSession, forked: AgentSession, history: OrderedHistoryPageClient
    ) {
        let response = worktreeResponse()
        let source = AgentSession(
            id: "source-thread", projectID: root.id, project: root.name, dir: root.path,
            title: "Source", status: "history", source: "codex", resumeID: "source-thread",
            createdAt: nil, updatedAt: nil
        )
        let forked = AgentSession(
            id: "forked-thread", projectID: response.workspace.id,
            project: response.workspace.name, dir: response.workspace.path,
            title: "Forked", status: "history", source: "codex", resumeID: "forked-thread",
            createdAt: nil, updatedAt: nil
        )
        let history = OrderedHistoryPageClient(projects: [root], page: SessionsPage(sessions: []))
        let client = HandoffHistoryClient(forked: forked, history: history)
        let host = WorkspaceHostProbe(projects: [root])
        host.createHandler = { response }
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            workspaceHostClientFactory: { host }
        )
        store.projects = [root]
        store.sessions = [source]
        return (store, source, forked, history)
    }

    private func switchHost(_ appStore: AppStore) async throws {
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "host-b", displayName: "Host B"),
            installationID: "installation-b"
        ))
    }

    private func worktreeResponse() -> WorktreeCreateResponse {
        let workspace = AgentWorkspace(id: "old-worktree", name: "Old", path: "/tmp/root/old")
        let descriptor = WorktreeDescriptor(
            path: workspace.path, repositoryPath: root.path, base: "main", branch: "old",
            gitState: "clean", dirty: false, ahead: 0, behind: 0, upstream: nil,
            rootProjectID: root.id, rootProjectName: root.name, rootProjectPath: root.path
        )
        return WorktreeCreateResponse(workspace: workspace, worktree: descriptor)
    }
}

private final class ResumeAcknowledgementClient: SessionStoreAPIClient {
    let response: CreateSessionResponse
    let history: OrderedHistoryPageClient

    init(response: CreateSessionResponse, history: OrderedHistoryPageClient) {
        self.response = response
        self.history = history
    }

    func projects() async throws -> [AgentProject] { try await history.projects() }
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await history.sessions(projectID: projectID, cursor: cursor, limit: limit)
    }
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw AgentAPIError.invalidResponse
    }
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse { response }
    func stopSession(id: String) async throws { throw AgentAPIError.invalidResponse }
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        try await history.messages(sessionID: sessionID, before: before, limit: limit)
    }
    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        try await history.messagesPage(sessionID: sessionID, before: before, limit: limit)
    }
}

/// 复用可控历史响应，只为 handoff 提供列表和 fork；其他写操作仍明确失败。
private final class HandoffHistoryClient: SessionStoreAPIClient {
    let forked: AgentSession
    let history: OrderedHistoryPageClient

    init(forked: AgentSession, history: OrderedHistoryPageClient) {
        self.forked = forked
        self.history = history
    }

    func projects() async throws -> [AgentProject] { try await history.projects() }
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await history.sessions(projectID: projectID, cursor: cursor, limit: limit)
    }
    func forkSession(
        threadID: String,
        workspace: AgentWorkspace,
        reason: AgentSessionForkReason,
        lastTurnID: TurnID?
    ) async throws -> AgentSession {
        forked
    }
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw AgentAPIError.invalidResponse
    }
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw AgentAPIError.invalidResponse
    }
    func stopSession(id: String) async throws { throw AgentAPIError.invalidResponse }
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        try await history.messages(sessionID: sessionID, before: before, limit: limit)
    }
    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        try await history.messagesPage(sessionID: sessionID, before: before, limit: limit)
    }
}

@MainActor
private final class WorkspaceCreateResponseGate {
    private var request: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<WorktreeCreateResponse, Never>?

    func waitForRequest() async {
        if response != nil { return }
        await withCheckedContinuation { request = $0 }
    }

    func waitForResponse() async -> WorktreeCreateResponse {
        await withCheckedContinuation { continuation in
            response = continuation
            request?.resume()
            request = nil
        }
    }

    func finish(_ value: WorktreeCreateResponse) {
        response?.resume(returning: value)
        response = nil
    }
}

/// 未使用的主机能力显式失败，确保测试不会误把会话请求当作成功。
@MainActor
private final class WorkspaceHostProbe: WorkspaceHostAPIClient {
    let catalog: [AgentProject]
    var projectRequests = 0
    var projectHandler: (@MainActor () async throws -> [AgentProject])?
    var worktreeListRequests = 0
    var listHandler: (@MainActor () async throws -> [WorktreeListItem])?
    var createHandler: (@MainActor () async -> WorktreeCreateResponse)?

    init(projects: [AgentProject]) { catalog = projects }

    func projects() async throws -> [AgentProject] {
        projectRequests += 1
        if let projectHandler { return try await projectHandler() }
        return catalog
    }
    func listWorktrees() async throws -> [WorktreeListItem] {
        worktreeListRequests += 1
        if let listHandler { return try await listHandler() }
        return []
    }
    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        guard let createHandler else { throw AgentAPIError.invalidResponse }
        return await createHandler()
    }
    func resolveWorkspace(path: String) async throws -> AgentWorkspace { throw AgentAPIError.invalidResponse }
    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse { throw AgentAPIError.invalidResponse }
    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse { throw AgentAPIError.invalidResponse }
    func pruneMissingWorktrees() async throws -> WorktreePruneResponse { throw AgentAPIError.invalidResponse }
    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse { throw AgentAPIError.invalidResponse }
    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse { throw AgentAPIError.invalidResponse }
    func listDirectories(path: String) async throws -> DirectoryListResponse { throw AgentAPIError.invalidResponse }
    func readFile(path: String) async throws -> FileReadResponse { throw AgentAPIError.invalidResponse }
    func readHistoryMedia(id: String) async throws -> FileReadResponse { throw AgentAPIError.invalidResponse }
    func readHistoryOutput(id: String) async throws -> FileReadResponse { throw AgentAPIError.invalidResponse }
    func commandActions(path: String) async throws -> [AgentCommandAction] { throw AgentAPIError.invalidResponse }
    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse { throw AgentAPIError.invalidResponse }
}
