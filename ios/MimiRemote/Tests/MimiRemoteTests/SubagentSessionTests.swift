import XCTest
@testable import MimiRemote

extension CodexAppServerProtocolTests {
    func testProjectorMapsLiveCollabReceiversWithoutUsingToolItemID() throws {
        let notification = CodexAppServerNotification(method: "item/completed", params: .object([
            "threadId": .string("parent-thread"),
            "turnId": .string("turn-1"),
            "item": .object([
                "id": .string("tool-item-is-not-thread"),
                "type": .string("collabAgentToolCall"),
                "tool": .string("review"),
                "receiverThreadIds": .array([
                    .string("child-a"),
                    .string("child-b"),
                    .string(" child-padded "),
                ]),
                "agentsStates": .object([
                    "child-a": .object([
                        "status": .string("running"),
                        "sessionId": .string("session-a"),
                        "canAcceptDirectInput": .bool(false),
                    ]),
                    "child-b": .object([
                        "status": .string("completed"),
                        "message": .string("done"),
                    ]),
                ]),
            ]),
        ]))

        var projector = CodexAppServerEventProjector()
        guard case .processItemCompleted(let message, let projectedContext, let metadata) = projector.project(notification) else {
            return XCTFail("expected completed activity and live session context")
        }
        let context = try XCTUnwrap(projectedContext)
        XCTAssertEqual(message.content, "done")
        XCTAssertEqual(metadata.sessionID, "parent-thread")
        XCTAssertEqual(context.subagents.map(\.id), ["child-a", "child-b"])
        XCTAssertFalse(context.subagents.contains { $0.id == "tool-item-is-not-thread" })
        XCTAssertFalse(context.subagents.contains { $0.id.contains("padded") })
        XCTAssertEqual(context.subagents[0].parentThreadID, "parent-thread")
        XCTAssertEqual(context.subagents[0].sessionID, "session-a")
        XCTAssertEqual(context.subagents[0].status, "running")
        XCTAssertEqual(context.subagents[0].canAcceptDirectInput, false)
        XCTAssertEqual(context.subagents[1].statusMessage, "done")
    }

    func testContextSubagentsUsesAllReceiversAndNeverToolItemID() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test"
        )
        let thread: [String: CodexAppServerJSONValue] = [
            "id": .string("parent-thread"),
            "turns": .array([
                .object([
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "id": .string("tool-item-is-not-thread"),
                            "type": .string("collabAgentToolCall"),
                            "receiverThreadIds": .array([
                                .string("child-a"),
                                .string("child-b"),
                            ]),
                            "agentNickname": .string("Noether"),
                            "agentRole": .string("review"),
                            "agentsStates": .object([
                                "child-a": .object([
                                    "status": .string("running"),
                                    "message": .string("checking"),
                                    "sessionId": .string("session-a"),
                                    "canAcceptDirectInput": .bool(false),
                                ]),
                                "child-b": .object([
                                    "status": .string("completed"),
                                    "canAcceptDirectInput": .bool(true),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]

        let subagents = await runtime.contextSubagents(from: thread, status: "history")

        XCTAssertEqual(subagents.map(\.id), ["child-a", "child-b"])
        XCTAssertFalse(subagents.contains { $0.id == "tool-item-is-not-thread" })
        XCTAssertEqual(subagents[0].parentThreadID, "parent-thread")
        XCTAssertEqual(subagents[0].sessionID, "session-a")
        XCTAssertEqual(subagents[0].nickname, "Noether")
        XCTAssertEqual(subagents[0].role, "review")
        XCTAssertEqual(subagents[0].status, "running")
        XCTAssertEqual(subagents[0].statusMessage, "checking")
        XCTAssertEqual(subagents[0].canAcceptDirectInput, false)
        XCTAssertEqual(subagents[1].canAcceptDirectInput, true)
    }

    func testThreadProjectionRecognizesSourceOnlySubagentAndSnakeCaseOwnership() async throws {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test"
        )
        let createdAt = Date(timeIntervalSince1970: 1_780_490_200)
        let sourceOnlyThread: [String: CodexAppServerJSONValue] = [
            "id": .string("source-only-child"),
            "cwd": .string("/tmp/source-only-child"),
            "status": .object(["type": .string("idle")]),
            "created_at": .double(createdAt.timeIntervalSince1970),
            "source": .object(["subAgent": .object(["thread_spawn": .object([:])])]),
        ]

        let sourceOnly = try await runtime.agentSession(
            from: sourceOnlyThread,
            projects: [],
            fallbackProject: nil
        )

        XCTAssertNil(sourceOnly.parentThreadID)
        XCTAssertEqual(sourceOnly.isSubagent, true)
        XCTAssertTrue(sourceOnly.isSubagentThread)
        XCTAssertFalse(sourceOnly.allowsDirectInput, "source-only 子 Agent 缺 capability 时必须 fail-closed")
        XCTAssertEqual(sourceOnly.createdAt, createdAt)
        XCTAssertEqual(sourceOnly.context?.createdAt, createdAt)
        XCTAssertNil(sourceOnly.context?.parentThreadID)
        XCTAssertEqual(sourceOnly.context?.isSubagent, true)

        let snakeCaseParent = try await runtime.agentSession(
            from: [
                "id": .string("snake-case-child"),
                "cwd": .string("/tmp/snake-case-child"),
                "status": .object(["type": .string("idle")]),
                "parent_thread_id": .string("snake-case-parent"),
                "thread_source": .string("SubAgent/worker"),
            ],
            projects: [],
            fallbackProject: nil
        )
        XCTAssertEqual(snakeCaseParent.parentThreadID, "snake-case-parent")
        XCTAssertTrue(snakeCaseParent.isSubagentThread)
        XCTAssertEqual(snakeCaseParent.context?.parentThreadID, "snake-case-parent")
        XCTAssertEqual(snakeCaseParent.context?.subagents.first?.parentThreadID, "snake-case-parent")
    }

    func testThreadProjectionNeverTreatsOrdinaryForkAsSubagent() async throws {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test"
        )
        let session = try await runtime.agentSession(
            from: [
                "id": .string("ordinary-fork"),
                "cwd": .string("/tmp/ordinary-fork"),
                "status": .object(["type": .string("idle")]),
                "forkedFromId": .string("root-thread"),
                "threadSource": .string("user"),
                "source": .string("vscode"),
            ],
            projects: [],
            fallbackProject: nil
        )

        XCTAssertNil(session.parentThreadID)
        XCTAssertNotEqual(session.isSubagent, true)
        XCTAssertFalse(session.isSubagentThread)
        XCTAssertTrue(session.allowsDirectInput)
        XCTAssertEqual(session.context?.sources.first(where: { $0.kind == "fork" })?.label, "root-thread")
    }

    func testSparseThreadProjectionDoesNotDowngradeCachedSubagentOwnership() async throws {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test"
        )
        let createdAt = Date(timeIntervalSince1970: 1_780_490_300)
        await runtime.handle(CodexAppServerNotification(
            method: "thread/started",
            params: .object([
                "thread": .object([
                    "id": .string("sticky-source-child"),
                    "cwd": .string("/tmp/sticky-source-child"),
                    "status": .object(["type": .string("active")]),
                    "createdAt": .double(createdAt.timeIntervalSince1970),
                    "source": .string("subAgent"),
                ]),
            ])
        ))

        let sparse = try await runtime.agentSession(
            from: [
                "id": .string("sticky-source-child"),
                "cwd": .string("/tmp/sticky-source-child"),
                "status": .object(["type": .string("idle")]),
            ],
            projects: [],
            fallbackProject: nil
        )

        XCTAssertEqual(sparse.createdAt, createdAt)
        XCTAssertEqual(sparse.isSubagent, true)
        XCTAssertTrue(sparse.isSubagentThread)
        XCTAssertEqual(sparse.context?.createdAt, createdAt)
        XCTAssertEqual(sparse.context?.isSubagent, true)
    }
}

@MainActor
extension ConversationDataFlowTests {
    func testAgentSessionOwnershipCodableRemainsBackwardCompatible() throws {
        let legacyJSON = #"{"id":"legacy","project_id":"repo","project":"Repo","dir":"/tmp/repo","title":"Legacy","status":"history","source":"codex"}"#
        let legacy = try JSONDecoder().decode(AgentSession.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(legacy.isSubagent)
        XCTAssertFalse(legacy.isSubagentThread)
        XCTAssertTrue(legacy.allowsDirectInput)

        let child = AgentSession(
            id: "source-child",
            projectID: "repo",
            project: "Repo",
            dir: "/tmp/repo",
            title: "Child",
            status: "history",
            source: "codex",
            resumeID: "source-child",
            createdAt: Date(timeIntervalSince1970: 123),
            updatedAt: nil,
            isSubagent: true
        )
        let roundTrip = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(child)
        )
        XCTAssertEqual(roundTrip.isSubagent, true)
        XCTAssertTrue(roundTrip.isSubagentThread)
        XCTAssertFalse(roundTrip.allowsDirectInput)
    }

    func testDataFlowSessionRowRestoresOwnershipFromContext() throws {
        let rowJSON = #"{"id":"row-child","project_id":"repo","project_name":"Repo","project_path":"/tmp/repo","title":"Row child","status":"history","source":"codex","context":{"session_id":"row-child","created_at":789,"parent_thread_id":"row-parent","is_subagent":true}}"#
        let row = try JSONDecoder().decode(DataFlowSessionRow.self, from: Data(rowJSON.utf8))
        let session = AgentSession(row: row)

        XCTAssertEqual(session.createdAt, Date(timeIntervalSinceReferenceDate: 789))
        XCTAssertEqual(session.parentThreadID, "row-parent")
        XCTAssertEqual(session.isSubagent, true)
        XCTAssertTrue(session.isSubagentThread)
        XCTAssertFalse(session.allowsDirectInput)
    }

    func testSessionStoreSparseMergePreservesKnownSubagentOwnership() {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        let createdAt = Date(timeIntervalSince1970: 1_234)
        let knownChild = AgentSession(
            id: "sticky-store-child",
            projectID: "repo",
            project: "Repo",
            dir: "/tmp/repo",
            title: "Known child",
            status: "running",
            source: "codex",
            resumeID: "sticky-store-child",
            createdAt: createdAt,
            updatedAt: nil,
            parentThreadID: "sticky-store-parent",
            isSubagent: true
        )
        store.sessions = [knownChild]

        let sparse = AgentSession(
            id: knownChild.id,
            projectID: knownChild.projectID,
            project: knownChild.project,
            dir: knownChild.dir,
            title: knownChild.title,
            status: "history",
            source: knownChild.source,
            resumeID: knownChild.resumeID,
            createdAt: nil,
            updatedAt: Date()
        )
        store.mergeSessionPage([sparse])

        let merged = store.sessionsByID[knownChild.id]
        XCTAssertEqual(merged?.createdAt, createdAt)
        XCTAssertEqual(merged?.parentThreadID, "sticky-store-parent")
        XCTAssertEqual(merged?.isSubagent, true)
        XCTAssertTrue(merged?.isSubagentThread == true)
    }

    func testWorkspaceFirstPageRefreshKeepsChildCanonicalButHiddenFromTopLevel() {
        let project = makeProject(id: "proj-child-refresh")
        let parent = makeSession(
            id: "refresh-parent",
            projectID: project.id,
            title: "Parent",
            status: "history",
            source: "codex"
        )
        var child = makeSession(
            id: "refresh-child",
            projectID: project.id,
            title: "Child",
            status: "history",
            source: "codex"
        )
        child.parentThreadID = parent.id
        child.isSubagent = true
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [parent]) }
        )
        store.projects = [project]
        store.sessions = [parent, child]

        let refreshedPage = store.pageSessionsPreservingLoadedWindow(
            [parent],
            projectID: project.id
        )
        store.replaceSessionsIfChanged(with: refreshedPage, projectID: project.id)

        XCTAssertNotNil(store.sessionsByID[child.id], "顶层首屏缺少 child 时不能删除 canonical 父子关系")
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [parent.id])
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [parent.id])
    }

    func testSessionContextOwnershipSurvivesSparseUpdatesAndCodableRoundTrip() throws {
        let store = SessionContextStore()
        let createdAt = Date(timeIntervalSince1970: 456)
        let child = AgentSession(
            id: "sticky-child",
            projectID: "repo",
            project: "Repo",
            dir: "/tmp/repo",
            title: "Child",
            status: "running",
            source: "codex",
            resumeID: "sticky-child",
            createdAt: createdAt,
            updatedAt: nil,
            parentThreadID: "parent-thread",
            isSubagent: true
        )

        store.upsert(from: child)
        store.upsert(
            SessionContextSnapshot(
                sessionID: child.id,
                status: SessionContextStatus(type: "idle"),
                updatedAt: Date()
            ),
            fallbackSessionID: child.id
        )

        let merged = try XCTUnwrap(store.context(for: child.id))
        XCTAssertEqual(merged.createdAt, createdAt)
        XCTAssertEqual(merged.parentThreadID, "parent-thread")
        XCTAssertEqual(merged.isSubagent, true)

        let roundTrip = try JSONDecoder().decode(
            SessionContextSnapshot.self,
            from: JSONEncoder().encode(merged)
        )
        XCTAssertEqual(roundTrip.createdAt, createdAt)
        XCTAssertEqual(roundTrip.parentThreadID, "parent-thread")
        XCTAssertEqual(roundTrip.isSubagent, true)

        let legacyContextJSON = #"{"session_id":"legacy-context","tasks":[],"sources":[],"subagents":[]}"#
        let legacy = try JSONDecoder().decode(
            SessionContextSnapshot.self,
            from: Data(legacyContextJSON.utf8)
        )
        XCTAssertNil(legacy.createdAt)
        XCTAssertNil(legacy.parentThreadID)
        XCTAssertNil(legacy.isSubagent)
    }

    func testSessionContextStoreMergesUpdatesAndAttachesSubagents() {
        let store = SessionContextStore()
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_parent",
                threadID: "thr_parent",
                status: SessionContextStatus(type: "idle"),
                environment: SessionContextEnvironment(
                    id: "local",
                    kind: "local",
                    label: "本地",
                    cwd: "/tmp/parent",
                    provider: "openai"
                ),
                sources: [
                    SessionContextSource(
                        id: "session_source",
                        kind: "session",
                        label: "appServer"
                    ),
                ]
            ),
            fallbackSessionID: nil
        )
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_parent",
                status: SessionContextStatus(
                    type: "active",
                    activeFlags: ["waitingOnApproval"]
                ),
                tasks: [
                    SessionContextTask(
                        id: "cmd_1",
                        kind: "command",
                        title: "go test ./...",
                        subtitle: "/tmp/parent",
                        status: "running"
                    ),
                ]
            ),
            fallbackSessionID: nil
        )
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_child",
                threadID: "thr_child",
                subagents: [
                    SessionContextSubagent(
                        id: "thr_child",
                        parentThreadID: "thr_parent",
                        sessionID: "session_child",
                        nickname: "Noether",
                        role: "review",
                        status: "running",
                        canAcceptDirectInput: false
                    ),
                ]
            ),
            fallbackSessionID: nil
        )
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_child",
                threadID: "thr_child",
                subagents: [
                    SessionContextSubagent(
                        id: "thr_child",
                        status: "completed",
                        statusMessage: "done",
                        canAcceptDirectInput: true
                    ),
                ]
            ),
            fallbackSessionID: nil
        )

        let parent = store.context(for: "thr_parent")
        XCTAssertEqual(parent?.status?.activeFlags, ["waitingOnApproval"])
        XCTAssertEqual(parent?.environment?.cwd, "/tmp/parent")
        XCTAssertEqual(parent?.tasks.first?.title, "go test ./...")
        XCTAssertEqual(parent?.subagents.first?.displayName, "Noether")
        XCTAssertEqual(parent?.subagents.first?.sessionID, "session_child")
        XCTAssertEqual(parent?.subagents.first?.status, "completed")
        XCTAssertEqual(parent?.subagents.first?.statusMessage, "done")
        XCTAssertEqual(parent?.subagents.first?.canAcceptDirectInput, false)
        XCTAssertEqual(
            store.context(for: "codex_thr_parent")?.subagents.first?.id,
            "thr_child"
        )
    }
}
