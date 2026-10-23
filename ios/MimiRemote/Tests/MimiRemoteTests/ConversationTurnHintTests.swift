import XCTest
@testable import MimiRemote

@MainActor
final class ConversationTurnHintTests: XCTestCase {
    func testWrapUpParsesTrimmedContentAndCapsActions() throws {
        let hint = try XCTUnwrap(ConversationTurnHint(item: hintItem(
            server: "ccd_turn",
            tool: "wrap_up",
            arguments: [
                "recap": .string("  Finished the fix.  "),
                "ask": .string("  What next?  "),
                "actions": .array([
                    action("Review", "review it"),
                    action("Merge", "merge it"),
                    .object(["label": .string("Missing message")]),
                    action("Release", "release it"),
                    action("Ignored", "ignore it")
                ])
            ]
        )))

        XCTAssertEqual(hint.kind, .nextStep)
        XCTAssertEqual(hint.recap, "Finished the fix.")
        XCTAssertEqual(hint.question, "What next?")
        XCTAssertEqual(hint.actions.map(\.label), ["Review", "Merge", "Release"])
        XCTAssertEqual(hint.plainText, "Finished the fix.\n\nWhat next?")
    }

    func testStartSessionAndLegacySpawnTaskKeepTheirDisplayFields() throws {
        let start = try XCTUnwrap(ConversationTurnHint(item: hintItem(
            server: "ccd_session",
            tool: "start_session",
            arguments: ["title": .string("Follow-up"), "prompt": .string("Continue in a new session")]
        )))
        let trusted = try XCTUnwrap(ConversationTurnHint(item: hintItem(
            server: "ccd_session",
            tool: "start_session",
            arguments: ["title": .string("Mimi follow-up"), "prompt": .string("Continue from Mimi")],
            proposalID: "proposal-trusted"
        )))
        let spawn = try XCTUnwrap(ConversationTurnHint(item: hintItem(
            server: "ccd_session",
            tool: "spawn_task",
            arguments: [
                "title": .string("Legacy follow-up"),
                "tldr": .string("Short summary"),
                "prompt": .string("Long prompt"),
                "cwd": .string("/private/workspace")
            ]
        )))

        XCTAssertEqual(start.kind, .taskProposal)
        XCTAssertEqual(start.title, "Follow-up")
        XCTAssertEqual(start.brief, "Continue in a new session")
        XCTAssertNil(start.mimiProposalID, "桌面端同名卡片只能展示")
        XCTAssertEqual(trusted.mimiProposalID, "proposal-trusted")
        XCTAssertEqual(spawn.title, "Legacy follow-up")
        XCTAssertEqual(spawn.brief, "Short summary")
        XCTAssertFalse(spawn.plainText.contains("/private/workspace"))
        XCTAssertNil(spawn.mimiProposalID)
    }

    func testMimiTaskProposalUsesExactThreadStartBinding() throws {
        let project = AgentProject(id: "project", name: "Project", path: "/workspace")
        let request = try CodexAppServerRequestBuilder(allowlistedProjects: [project]).threadStart(
            cwd: project.path,
            options: CodexAppServerTurnOptions(runtimeProvider: "claude"),
            mimiTaskProposal: MimiTaskProposalRequest(id: "proposal-1", parentThreadID: "parent-1")
        )
        let params = try XCTUnwrap(request.params?.objectValue)

        XCTAssertEqual(params["mimiTaskProposal"], .object([
            "id": .string("proposal-1"),
            "parentThreadId": .string("parent-1")
        ]))
        XCTAssertEqual(params["cwd"], .string(project.path))
    }

    func testMalformedAndAcceptanceCallsDoNotBecomeCards() {
        XCTAssertNil(ConversationTurnHint(item: hintItem(
            server: "ccd_turn", tool: "wrap_up", arguments: ["actions": .array([])]
        )))
        XCTAssertNil(ConversationTurnHint(item: hintItem(
            server: "ccd_session", tool: "start_session", arguments: ["proposal_id": .string("proposal-1")]
        )))
        XCTAssertNil(ConversationTurnHint(item: hintItem(
            server: "other", tool: "wrap_up", arguments: ["recap": .string("done")]
        )))
        XCTAssertNil(ConversationTurnHint(item: hintItem(
            server: "ccd_turn", tool: "wrap_up", status: "failed", arguments: ["recap": .string("done")]
        )))
        XCTAssertNil(ConversationTurnHint(item: hintItem(
            server: "ccd_session",
            tool: "start_session",
            status: "interrupted",
            arguments: ["title": .string("Follow-up")]
        )))
        var inconsistent = hintItem(
            server: "ccd_turn",
            tool: "wrap_up",
            arguments: ["recap": .string("done")]
        )
        inconsistent["error"] = .object(["message": .string("failed")])
        XCTAssertNil(ConversationTurnHint(item: inconsistent))
        XCTAssertNotNil(ConversationTurnHint(item: hintItem(
            server: "ccd_turn", tool: "wrap_up", status: "inProgress", arguments: ["recap": .string("done")]
        )))
    }

    func testFailedHintKeepsOrdinaryToolFailurePresentation() throws {
        let item = hintItem(
            server: "ccd_turn",
            tool: "wrap_up",
            status: "failed",
            arguments: ["recap": .string("done"), "ask": .string("continue?")]
        )
        let payload = try XCTUnwrap(ConversationActivityPayload(item: item))

        XCTAssertNil(payload.turnHint)
        XCTAssertEqual(payload.status, "failed")
        XCTAssertTrue(payload.isFailure)
        let message = ConversationMessage(
            turnID: "turn-failed",
            itemID: "hint-failed",
            role: .system,
            kind: payload.messageKind,
            content: payload.detailText(from: item),
            activityPayload: payload
        )
        let rows = ConversationTimelineItemBuilder.items(from: [message], showsDetailedTranscript: true)
        guard case .processGroup = try XCTUnwrap(rows.first),
              case .activity = try XCTUnwrap(rows.last) else {
            return XCTFail("failed hint must use the ordinary tool failure timeline")
        }
    }

    func testLiveAndHistoryProjectionProduceTheSameCardPayload() async throws {
        let item = hintItem(
            server: "ccd_turn",
            tool: "wrap_up",
            arguments: [
                "recap": .string("Tests passed"),
                "ask": .string("Open a PR?"),
                "actions": .array([action("Open PR", "open the PR")])
            ]
        )
        var projector = CodexAppServerEventProjector()
        let event = try XCTUnwrap(projector.project(CodexAppServerNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string("session-hint"),
                "turnId": .string("turn-hint"),
                "item": .object(item)
            ])
        )))
        guard case .processItemCompleted(let live, _, _) = event else {
            return XCTFail("turn hint must remain visible as a completed process item")
        }

        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let restored = await runtime.historyMessages(from: [
            "turns": .array([.object([
                "id": .string("turn-hint"),
                "status": .string("completed"),
                "startedAt": .int(100),
                "completedAt": .int(101),
                "items": .array([.object(item)])
            ])])
        ], sessionID: "session-hint", snapshotReadAt: Date(timeIntervalSince1970: 102))
        let history = try XCTUnwrap(restored.first)

        XCTAssertEqual(live.activityPayload, history.activityPayload)
        XCTAssertEqual(live.content, history.content)
        XCTAssertEqual(live.turnID, history.turnID)
        XCTAssertEqual(live.itemID, history.itemID)
        let timelineMessage = ConversationMessage(
            turnID: history.turnID,
            itemID: history.itemID,
            role: .system,
            kind: history.kind,
            content: history.content,
            activityPayload: history.activityPayload
        )
        let rows = ConversationTimelineItemBuilder.items(from: [timelineMessage])
        guard case .message(let cardMessage) = try XCTUnwrap(rows.first) else {
            return XCTFail("turn hint must stay outside the collapsible process group")
        }
        XCTAssertEqual(cardMessage.activityPayload?.turnHint?.question, "Open a PR?")
    }

    func testInteractionRetriesFailureLocksSuccessAndDismissesWithoutSubmitting() {
        var state = ConversationTurnHintInteractionState()
        XCTAssertTrue(state.begin(actionIndex: 0))
        XCTAssertFalse(state.begin(actionIndex: 0))
        state.finish(actionIndex: 0, succeeded: false)
        XCTAssertTrue(state.canSubmit(cardCanAct: true))

        XCTAssertTrue(state.begin(actionIndex: 0))
        state.finish(actionIndex: 0, succeeded: true)
        XCTAssertFalse(state.canSubmit(cardCanAct: true))
        XCTAssertFalse(state.begin(actionIndex: 1))

        var dismissed = ConversationTurnHintInteractionState()
        XCTAssertTrue(dismissed.dismiss())
        XCTAssertTrue(dismissed.isDismissed)
        XCTAssertFalse(dismissed.begin(actionIndex: 0))
    }

    func testActionTargetRejectsHostConnectionSessionTurnAndReadOnlyChanges() throws {
        let host = HostScope(profileID: "host-a", installationID: "install-a", generation: 7)
        let session = makeSession()
        let lease = SessionSelectionLease(
            hostScope: host,
            generation: 11,
            projectID: session.projectID,
            sessionID: session.id
        )
        let message = turnHintMessage(itemID: "hint-1", turnID: "turn-1")
        let context = TurnSubmissionContext(
            hostScope: host,
            selectionLease: lease,
            projectID: session.projectID,
            session: session
        )
        let target = try XCTUnwrap(ConversationTurnHintActionTarget(
            submissionContext: context,
            connectionGeneration: 21,
            message: message
        ))

        XCTAssertTrue(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: session,
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: HostScope(profileID: "host-a", installationID: "install-a", generation: 8),
            selectionLease: lease,
            connectionGeneration: 21,
            session: session,
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: SessionSelectionLease(
                hostScope: host, generation: 12, projectID: session.projectID, sessionID: session.id
            ),
            connectionGeneration: 21,
            session: session,
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 22,
            session: session,
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: makeSession(status: "running"),
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: makeSession(canAcceptDirectInput: false),
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: session,
            messages: [message, ConversationMessage(turnID: "turn-2", role: .user, content: "new request")]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: session,
            messages: [message, ConversationMessage(turnID: "turn-2", role: .assistant, content: "newer turn")]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: session,
            messages: [message, turnHintMessage(itemID: "hint-2", turnID: "turn-2")]
        ))
    }

    func testTrustedTaskStartsWritableSpawnedConversationWithExactProposal() async throws {
        let project = AgentProject(id: "project-hint", name: "Project", path: "/workspace")
        let parent = makeSession()
        let gate = TurnHintTaskGate()
        let client = TurnHintTaskClient(projects: [project], sessions: [parent], gate: gate)
        let store = makeTurnHintStore(project: project, parent: parent, client: client)
        let message = try installTaskProposal(
            proposalID: "proposal-trusted",
            sessionID: parent.id,
            in: store.conversationStore
        )
        let target = try XCTUnwrap(store.captureTurnHintActionTarget(for: message))

        let start = Task { @MainActor in
            await store.sendTurnHintAction(.startTask, target: target)
        }
        await gate.waitForModelRequest()
        await gate.resolveModels([])
        await gate.waitForCreateRequest()
        let capturedRequest = await gate.createRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.prompt, "Continue in a new session")
        XCTAssertEqual(request.turnOptions.runtimeProvider, "claude")
        XCTAssertEqual(request.mimiTaskProposal, MimiTaskProposalRequest(
            id: "proposal-trusted",
            parentThreadID: parent.id
        ))
        XCTAssertEqual(request.clientMessageID, "proposal-trusted")

        let child = AgentSession(
            id: "child-session",
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "Follow-up",
            status: "running",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "child-session",
            createdAt: nil,
            updatedAt: nil,
            canAcceptDirectInput: true,
            spawnedFromThreadID: parent.id
        )
        await gate.resolveCreate(.success(CreateSessionResponse(
            session: child,
            wsURL: "ws://127.0.0.1/session/child-session"
        )))

        let didStart = await start.value
        XCTAssertTrue(didStart)
        XCTAssertEqual(store.selectedSessionID, child.id)
        let storedChild = try XCTUnwrap(store.sessionsByID[child.id])
        XCTAssertEqual(storedChild.spawnedFromThreadID, parent.id)
        XCTAssertNil(storedChild.parentThreadID)
        XCTAssertTrue(storedChild.allowsDirectInput)
    }

    func testTrustedTaskRetryOpensStartedChildWithoutDuplicateLocalPrompt() async throws {
        let project = AgentProject(id: "project-hint", name: "Project", path: "/workspace")
        let parent = makeSession()
        let gate = TurnHintTaskGate()
        let client = TurnHintTaskClient(projects: [project], sessions: [parent], gate: gate)
        let store = makeTurnHintStore(project: project, parent: parent, client: client)
        let message = try installTaskProposal(
            proposalID: "proposal-retry",
            sessionID: parent.id,
            in: store.conversationStore
        )
        let target = try XCTUnwrap(store.captureTurnHintActionTarget(for: message))

        let start = Task { @MainActor in
            await store.sendTurnHintAction(.startTask, target: target)
        }
        await gate.waitForModelRequest()
        await gate.resolveModels([])
        await gate.waitForCreateRequest()
        let capturedRequest = await gate.createRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.clientMessageID, "proposal-retry")

        let child = AgentSession(
            id: "child-retry",
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "Follow-up",
            status: "running",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "child-retry",
            createdAt: nil,
            updatedAt: nil,
            canAcceptDirectInput: true,
            spawnedFromThreadID: parent.id
        )
        await gate.resolveCreate(.success(CreateSessionResponse(
            session: child,
            wsURL: "ws://127.0.0.1/session/child-retry",
            initialInputAlreadyStarted: true
        )))

        let didStart = await start.value
        XCTAssertTrue(didStart)
        XCTAssertEqual(store.selectedSessionID, child.id)
        XCTAssertFalse(store.conversationStore.messages(for: child.id).contains { message in
            message.role == .user && message.content == "Continue in a new session"
        })
    }

    func testRuntimeDoesNotResendInitialTurnWhenProposalChildAlreadyStarted() async throws {
        let project = AgentProject(id: "project-hint", name: "Project", path: "/workspace")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test",
            runtimeProvider: "claude",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    channels: [makeClaudeChannelMetadata()]
                )
            }
        )
        let create = Task {
            try await runtime.createSession(CreateSessionRequest(
                projectID: project.id,
                projectPath: project.path,
                projectName: project.name,
                prompt: "Continue in a new session",
                turnOptions: CodexAppServerTurnOptions(runtimeProvider: "claude"),
                resumeID: "",
                clientMessageID: "proposal-started",
                mimiTaskProposal: MimiTaskProposalRequest(
                    id: "proposal-started",
                    parentThreadID: "session-hint"
                )
            ))
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#
        )
        let threadStart = try await waitForFakeAppServerRequest(transport, method: "thread/start")
        XCTAssertEqual(threadStart.params?.objectValue?["mimiTaskProposal"], .object([
            "id": .string("proposal-started"),
            "parentThreadId": .string("session-hint")
        ]))
        transportResponse(
            transport,
            id: threadStart.id,
            result: #"{"thread":{"id":"child-started","sessionId":"child-started","preview":"Continue in a new session","ephemeral":false,"modelProvider":"anthropic","createdAt":1780490100,"updatedAt":1780490101,"status":{"type":"idle"},"path":null,"cwd":"/workspace","cliVersion":"0.0.0","source":"claude","threadSource":"user","name":"Follow-up","turns":[]},"mimiTaskProposal":{"initialTurnStarted":true}}"#
        )

        let response = try await create.value
        XCTAssertEqual(response.initialInputAlreadyStarted, true)
        XCTAssertFalse(response.session.isRunning)
        let sentMessages = await transport.sentMessages()
        let methods = sentMessages.compactMap { text in
            try? decodeAppServerRequest(text).method
        }
        XCTAssertFalse(methods.contains("turn/start"))
    }

    func testTaskProposalRevalidatesCapturedTargetAfterModelAwait() async throws {
        let project = AgentProject(id: "project-hint", name: "Project", path: "/workspace")
        let parent = makeSession()
        let gate = TurnHintTaskGate()
        let client = TurnHintTaskClient(projects: [project], sessions: [parent], gate: gate)
        let store = makeTurnHintStore(project: project, parent: parent, client: client)
        let message = try installTaskProposal(
            proposalID: "proposal-trusted",
            sessionID: parent.id,
            in: store.conversationStore
        )
        let target = try XCTUnwrap(store.captureTurnHintActionTarget(for: message))

        let start = Task { @MainActor in
            await store.sendTurnHintAction(.startTask, target: target)
        }
        await gate.waitForModelRequest()
        store.selectedSessionID = "another-session"
        await gate.resolveModels([])

        let didStart = await start.value
        let capturedRequest = await gate.createRequest()
        XCTAssertFalse(didStart)
        XCTAssertNil(capturedRequest)
    }

    private func action(_ label: String, _ message: String) -> CodexAppServerJSONValue {
        .object(["label": .string(label), "message": .string(message)])
    }

    private func hintItem(
        server: String,
        tool: String,
        status: String = "completed",
        arguments: [String: CodexAppServerJSONValue],
        proposalID: String? = nil
    ) -> [String: CodexAppServerJSONValue] {
        var item: [String: CodexAppServerJSONValue] = [
            "type": .string("mcpToolCall"),
            "id": .string("hint-item"),
            "server": .string(server),
            "tool": .string(tool),
            "status": .string(status),
            "arguments": .object(arguments)
        ]
        if let proposalID {
            item["result"] = .object([
                "structuredContent": .object([
                    "mimi_task_proposal": .object([
                        "version": .int(1),
                        "proposal_id": .string(proposalID)
                    ])
                ])
            ])
        }
        return item
    }

    private func turnHintMessage(itemID: String, turnID: String) -> ConversationMessage {
        let item = hintItem(
            server: "ccd_turn",
            tool: "wrap_up",
            arguments: ["recap": .string("done"), "ask": .string("continue?")]
        )
        let payload = ConversationActivityPayload(item: item)
        return ConversationMessage(
            turnID: turnID,
            itemID: itemID,
            role: .system,
            kind: payload?.messageKind ?? .commandSummary,
            content: payload?.detailText(from: item) ?? "",
            activityPayload: payload
        )
    }

    private func taskProposalMessage(proposalID: String?) -> ConversationMessage {
        let item = hintItem(
            server: "ccd_session",
            tool: "start_session",
            arguments: [
                "title": .string("Follow-up"),
                "prompt": .string("Continue in a new session")
            ],
            proposalID: proposalID
        )
        let payload = ConversationActivityPayload(item: item)
        return ConversationMessage(
            turnID: "turn-task",
            itemID: "hint-task",
            role: .system,
            kind: payload?.messageKind ?? .commandSummary,
            content: payload?.detailText(from: item) ?? "",
            activityPayload: payload
        )
    }

    private func installTaskProposal(
        proposalID: String,
        sessionID: String,
        in store: ConversationStore
    ) throws -> ConversationMessage {
        let message = taskProposalMessage(proposalID: proposalID)
        store.replaceHistorySnapshot([
            CodexHistoryMessage(
                id: "history-task-proposal",
                role: "system",
                kind: message.kind,
                content: message.content,
                activityPayload: message.activityPayload,
                createdAt: Date(timeIntervalSince1970: 1),
                turnID: message.turnID,
                itemID: message.itemID,
                turnLifecycle: .completed
            )
        ], sessionID: sessionID)
        return try XCTUnwrap(store.messages(for: sessionID).first)
    }

    private func makeTurnHintStore(
        project: AgentProject,
        parent: AgentSession,
        client: TurnHintTaskClient
    ) -> SessionStore {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        store.projects = [project]
        store.sessions = [parent]
        store.selectedProjectID = project.id
        store.selectedSessionID = parent.id
        return store
    }

    private func makeSession(
        status: String = "idle",
        canAcceptDirectInput: Bool = true
    ) -> AgentSession {
        AgentSession(
            id: "session-hint",
            projectID: "project-hint",
            project: "Project",
            dir: "/workspace",
            title: "Hint session",
            status: status,
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "session-hint",
            createdAt: nil,
            updatedAt: nil,
            canAcceptDirectInput: canAcceptDirectInput
        )
    }
}

private actor TurnHintTaskGate {
    private var modelContinuation: CheckedContinuation<[CodexAppServerModelOption], Never>?
    private var modelRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var didRequestModels = false
    private var createContinuation: CheckedContinuation<CreateSessionResponse, Error>?
    private var createRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var request: CreateSessionRequest?

    func requestModels() async -> [CodexAppServerModelOption] {
        didRequestModels = true
        modelRequestWaiters.forEach { $0.resume() }
        modelRequestWaiters.removeAll()
        return await withCheckedContinuation { modelContinuation = $0 }
    }

    func waitForModelRequest() async {
        guard !didRequestModels else { return }
        await withCheckedContinuation { modelRequestWaiters.append($0) }
    }

    func resolveModels(_ models: [CodexAppServerModelOption]) {
        modelContinuation?.resume(returning: models)
        modelContinuation = nil
    }

    func requestCreate(_ request: CreateSessionRequest) async throws -> CreateSessionResponse {
        self.request = request
        createRequestWaiters.forEach { $0.resume() }
        createRequestWaiters.removeAll()
        return try await withCheckedThrowingContinuation { createContinuation = $0 }
    }

    func waitForCreateRequest() async {
        guard request == nil else { return }
        await withCheckedContinuation { createRequestWaiters.append($0) }
    }

    func createRequest() -> CreateSessionRequest? { request }

    func resolveCreate(_ result: Result<CreateSessionResponse, Error>) {
        switch result {
        case .success(let response): createContinuation?.resume(returning: response)
        case .failure(let error): createContinuation?.resume(throwing: error)
        }
        createContinuation = nil
    }
}

private final class TurnHintTaskClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let sessionsResult: [AgentSession]
    let gate: TurnHintTaskGate

    init(projects: [AgentProject], sessions: [AgentSession], gate: TurnHintTaskGate) {
        projectsResult = projects
        sessionsResult = sessions
        self.gate = gate
    }

    func projects() async throws -> [AgentProject] { projectsResult }
    func modelOptions() async throws -> [CodexAppServerModelOption] { await gate.requestModels() }
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] { sessionsResult }
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse { throw MockError.unimplemented }
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        try await gate.requestCreate(payload)
    }
    func stopSession(id: String) async throws { throw MockError.unimplemented }
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] { [] }
}
