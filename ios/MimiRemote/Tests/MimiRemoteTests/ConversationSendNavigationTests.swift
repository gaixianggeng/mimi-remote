import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
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
        await store.selectSession(other)

        var resumed = original
        resumed.status = "running"
        await gate.resolveCreate(.success(try makeCreateSessionResponse(session: resumed)))

        let didSend = await sendTask.value
        XCTAssertTrue(didSend)
        XCTAssertEqual(store.selectedSessionID, other.id)
        let requests = await gate.createRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.resumeID, "thread-original")
        XCTAssertEqual(requests.first?.prompt, "继续原会话")
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
