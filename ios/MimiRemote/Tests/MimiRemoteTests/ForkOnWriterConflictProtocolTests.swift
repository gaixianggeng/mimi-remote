import XCTest
@testable import MimiRemote

@MainActor
final class ForkOnWriterConflictProtocolTests: XCTestCase {
    func testThreadForkSerializesTerminalBoundaryAndPreservesPermissions() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        var options = CodexAppServerTurnOptions.default
        options.preservesThreadPermissionSettings = true

        let request = try builder.threadFork(
            threadID: "thread-1",
            cwd: project.path,
            lastTurnID: " turn-completed ",
            options: options
        )

        let params = try XCTUnwrap(request.params?.objectValue)
        XCTAssertEqual(request.method, "thread/fork")
        XCTAssertEqual(params["lastTurnId"]?.stringValue, "turn-completed")
        XCTAssertEqual(params["mimiPreserveThreadPermissions"]?.boolValue, true)
        XCTAssertNil(params["approvalPolicy"])
        XCTAssertNil(params["approvalsReviewer"])
        XCTAssertNil(params["permissions"])
        XCTAssertNil(params["sandbox"])
    }

    func testThreadForkOmitsEmptyTerminalBoundary() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        let missing = try builder.threadFork(threadID: "thread-1", cwd: project.path)
        let blank = try builder.threadFork(
            threadID: "thread-1",
            cwd: project.path,
            lastTurnID: "  \n "
        )

        XCTAssertNil(missing.params?.objectValue?["lastTurnId"])
        XCTAssertNil(blank.params?.objectValue?["lastTurnId"])
    }

    func testLiveClientPassesTerminalBoundaryToRuntimeFork() async throws {
        let project = AgentProject(id: "proj-fork", name: "Fork", path: "/tmp/fork-boundary")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/fork"]
                )
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let forkTask = Task {
            try await client.forkSession(
                threadID: "thread-source",
                workspace: AgentWorkspace(project: project),
                reason: .duplicate,
                lastTurnID: "turn-terminal"
            )
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let fork = try await waitForFakeAppServerRequest(transport, method: "thread/fork", after: 1)
        let params = try XCTUnwrap(fork.params?.objectValue)
        XCTAssertEqual(params["lastTurnId"]?.stringValue, "turn-terminal")
        XCTAssertEqual(params["threadSource"]?.stringValue, "duplicate")
        XCTAssertEqual(params["mimiPreserveThreadPermissions"]?.boolValue, true)
        XCTAssertNil(params["approvalPolicy"])
        XCTAssertNil(params["approvalsReviewer"])
        XCTAssertNil(params["permissions"])
        XCTAssertNil(params["sandbox"])

        transportResponse(
            transport,
            id: fork.id,
            result: #"{"thread":{"id":"thread-forked","sessionId":"thread-forked","preview":"forked","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/fork-boundary","cliVersion":"0.0.0","source":"appServer","threadSource":"duplicate","name":"forked","turns":[]}}"#
        )

        let forked = try await forkTask.value
        XCTAssertEqual(forked.id, "thread-forked")
    }

    func testForkTimeoutReconcilesLateResponseFromThreadStarted() async throws {
        let project = AgentProject(id: "proj-late-fork", name: "Late Fork", path: "/tmp/late-fork")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            requestTimeout: 0.1,
            longRunningRequestTimeout: 0.1,
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/fork"]
                )
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let forkTask = Task {
            try await client.forkSession(
                threadID: "thread-source",
                workspace: AgentWorkspace(project: project),
                reason: .duplicate,
                lastTurnID: "turn-terminal"
            )
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let fork = try await waitForFakeAppServerRequest(transport, method: "thread/fork", after: 1)

        try await Task.sleep(nanoseconds: 130_000_000)
        transportResponse(
            transport,
            id: fork.id,
            result: #"{"thread":{"id":"thread-late","cwd":"/tmp/late-fork","forkedFromId":"thread-source","threadSource":"duplicate","turns":[]}}"#
        )
        transport.enqueue(
            #"{"method":"thread/started","params":{"thread":{"id":"thread-late","sessionId":"thread-late","preview":"","ephemeral":false,"modelProvider":"openai","status":{"type":"idle"},"cwd":"/tmp/late-fork","source":"appServer","threadSource":"duplicate","forkedFromId":"thread-source","turns":[]}}}"#
        )

        let forked = try await forkTask.value
        XCTAssertEqual(forked.id, "thread-late")
        XCTAssertFalse(forked.isRunning)
    }

    func testClaudeForkDoesNotRegisterThreadStartedReconciliation() async throws {
        let project = AgentProject(id: "proj-claude-fork", name: "Claude Fork", path: "/tmp/claude-fork")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/fork"],
                    channels: [makeClaudeChannelMetadata()]
                )
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let forkTask = Task {
            try await client.forkSession(
                threadID: "claude-source",
                workspace: AgentWorkspace(project: project),
                reason: .duplicate
            )
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#
        )
        let fork = try await waitForFakeAppServerRequest(transport, method: "thread/fork", after: 1)
        let pendingReconciliations = await runtime.pendingForkReconciliationsByToken.count
        XCTAssertEqual(pendingReconciliations, 0)

        transportResponse(
            transport,
            id: fork.id,
            result: #"{"thread":{"id":"claude-forked","sessionId":"claude-forked","preview":"forked","ephemeral":false,"modelProvider":"anthropic","status":{"type":"idle"},"cwd":"/tmp/claude-fork","source":"appServer","forkedFromId":"claude-source","turns":[]}}"#
        )
        let forked = try await forkTask.value
        XCTAssertEqual(forked.id, "claude-forked")
    }

    func testSessionStoreProtocolAndMockCarryOptionalTerminalBoundary() async throws {
        let project = AgentProject(id: "proj-mock", name: "Mock", path: "/tmp/proj-mock")
        let source = makeSession(
            id: "thread-source",
            projectID: project.id,
            title: "Source",
            status: "running",
            source: "codex"
        )
        let forked = makeSession(
            id: "thread-forked",
            projectID: project.id,
            title: "Forked",
            status: "history",
            source: "codex"
        )
        let mock = MockSessionStoreClient(
            projects: [project],
            sessions: [source],
            sessionForkResults: [source.id: .success(forked)]
        )
        let client: any SessionStoreAPIClient = mock

        let result = try await client.forkSession(
            threadID: source.id,
            workspace: AgentWorkspace(project: project),
            reason: .duplicate,
            lastTurnID: "turn-terminal"
        )

        XCTAssertEqual(result.id, forked.id)
        XCTAssertEqual(mock.requestedSessionForks, [
            RequestedSessionFork(
                threadID: source.id,
                workspaceID: project.id,
                reason: .duplicate,
                lastTurnID: "turn-terminal"
            )
        ])
    }

    func testEconomyHistoryUsesRawTerminalTurnWithoutItemsHydration() async throws {
        let project = AgentProject(id: "proj-history", name: "History", path: "/tmp/fork-history")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: [
                        "initialize", "initialized", "thread/read", "thread/turns/list", "thread/items/list"
                    ]
                )
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(
                sessionID: "thread-history",
                before: nil,
                limit: 20,
                loadMode: .economy
            )
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let metadata = try await waitForFakeAppServerRequest(transport, method: "thread/read", after: 1)
        transportResponse(
            transport,
            id: metadata.id,
            result: #"{"thread":{"id":"thread-history","sessionId":"thread-history","preview":"history","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490004,"status":{"type":"active"},"path":null,"cwd":"/tmp/fork-history","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"history","turns":[]}}"#
        )
        let turns = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list", after: 2)
        XCTAssertEqual(turns.params?.objectValue?["itemsView"]?.stringValue, "summary")
        transportResponse(
            transport,
            id: turns.id,
            result: #"{"data":[{"id":"turn-active","status":"inProgress","itemsView":"summary","items":[]},{"id":"turn-failed-empty","status":"failed","itemsView":"summary","items":[]},{"id":"turn-completed","status":"completed","itemsView":"summary","items":[]}],"nextCursor":null}"#
        )

        let page = try await pageTask.value
        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertEqual(page.latestForkableTurnID, "turn-failed-empty")
        let requests = (await transport.sentMessages()).compactMap { try? decodeAppServerRequest($0) }
        XCTAssertFalse(requests.contains { $0.method == "thread/items/list" })
        XCTAssertFalse(requests.contains {
            $0.method == "thread/read" && $0.params?.objectValue?["includeTurns"]?.boolValue == true
        })
    }

    func testLatestForkableTurnAcceptsOnlyDeclaredTerminalStatuses() {
        let completed: [String: CodexAppServerJSONValue] = [
            "id": .string("turn-completed"),
            "status": .string("completed")
        ]
        let interrupted: [String: CodexAppServerJSONValue] = [
            "id": .string("turn-interrupted"),
            "status": .object(["type": .string("interrupted")])
        ]
        let failed: [String: CodexAppServerJSONValue] = [
            "id": .string("turn-failed"),
            "status": .object(["status": .string("failed")])
        ]
        let active: [String: CodexAppServerJSONValue] = [
            "id": .string("turn-active"),
            "status": .string("inProgress")
        ]
        let blankCompleted: [String: CodexAppServerJSONValue] = [
            "id": .string("  "),
            "status": .string("completed")
        ]

        XCTAssertEqual(
            CodexAppServerSessionRuntime.latestForkableTurnID(
                fromTurns: [completed, interrupted, failed, active]
            ),
            "turn-failed"
        )
        XCTAssertEqual(
            CodexAppServerSessionRuntime.latestForkableTurnID(
                fromTurns: [completed, interrupted, active]
            ),
            "turn-interrupted"
        )
        XCTAssertNil(
            CodexAppServerSessionRuntime.latestForkableTurnID(
                fromTurns: [blankCompleted, active]
            )
        )
        XCTAssertNil(HistoryMessagesPage(messages: []).latestForkableTurnID)
    }

    func testWindowsManagedWebSocketIdleRetryRequiresServerThreadResumeBeforeClearingConflict() async throws {
        let project = AgentProject(id: "proj-win-ws-retry", name: "WinWS", path: "C:/repo/win-ws")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "win-ws-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: [
                        "initialize",
                        "initialized",
                        "thread/list",
                        "thread/read",
                        "thread/turns/list",
                        "thread/items/list",
                        "thread/resume"
                    ],
                    transport: "ws"
                )
            }
        )
        let apiClient = CodexAppServerSessionAPIClient(runtime: runtime)
        let appStore = makeIsolatedAppStore()
        appStore.token = "win-ws-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { apiClient },
            webSocketFactory: { CodexAppServerSessionWebSocketClient(runtime: runtime) }
        )
        defer { store.returnToSessionList() }

        let threadID = "thr-win-idle-conflict"
        let idleThreadJSON = #"{"id":"thr-win-idle-conflict","sessionId":"thr-win-idle-conflict","preview":"Windows idle","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490005,"status":{"type":"idle"},"path":null,"cwd":"C:/repo/win-ws","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Windows idle","turns":[]}"#
        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"windows"}"#
        )
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(
            transport,
            id: list.id,
            result: #"{"data":[\#(idleThreadJSON)],"nextCursor":null}"#
        )
        let page = try await pageTask.value
        let source = try XCTUnwrap(page.sessions.first)
        XCTAssertFalse(source.isRunning)

        store.projects = [project]
        store.sidebarProjects = [project]
        store.sessions = [source]
        store.selectedProjectID = project.id
        store.selectedSessionID = source.id
        store.setActiveWriterConflict(true, sessionID: source.id)
        let originLease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: source.id)

        // 1. 普通空闲连接（非显式重试）：Windows 受管 WS 会跳过 thread/resume，
        // 不得清除本地冲突，也不得将引导状态切到已解除锁定。
        let messagesBeforePassiveConnect = await transport.sentMessages().count
        store.connectWebSocket(source, replayBufferedEvents: false, allowNonRunning: true)
        try await waitForWebSocketStatus(.connected, store: store)

        let passiveRequests = await transport.sentMessages().dropFirst(messagesBeforePassiveConnect).compactMap {
            try? decodeAppServerRequest($0)
        }
        XCTAssertFalse(
            passiveRequests.contains { $0.method == "thread/resume" },
            "普通 Windows 受管 WS 打开空闲历史仍应保持只读，不主动 thread/resume"
        )
        XCTAssertTrue(
            store.hasActiveWriterConflict(sessionID: source.id),
            "跳过 thread/resume 的连接不得清除已有写入冲突"
        )
        XCTAssertNil(store.writerVerifiedWebSocketLease)
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .activeConflict)

        // 2. 用户点「重试」且电脑端仍占锁：必须强制发起 thread/resume；服务端拒绝后保持冲突，
        // 绝不进入 .live 或显示已解除锁定。
        let cursorBeforeLockedRetry = await transport.sentMessages().count
        let lockedRetryTask = Task { await store.retrySelectedSessionWriterAccess() }
        let lockedTurns = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: cursorBeforeLockedRetry
        )
        transportResponse(transport, id: lockedTurns.id, result: #"{"data":[],"nextCursor":null}"#)
        await lockedRetryTask.value

        let lockedResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: cursorBeforeLockedRetry
        )
        XCTAssertEqual(lockedResume.params?["threadId"]?.stringValue, threadID)
        let conflictMessage = "thread thr-win-idle-conflict already has an active writer"
        transportErrorResponse(
            transport,
            id: lockedResume.id,
            code: -32600,
            message: conflictMessage
        )
        let expectedFailure = CodexAppServerConnectionError.appServer(
            CodexAppServerError(code: -32600, message: conflictMessage, data: nil)
        ).localizedDescription
        try await waitForWebSocketStatus(.failed(expectedFailure), store: store)

        XCTAssertTrue(store.hasActiveWriterConflict(sessionID: source.id))
        XCTAssertNil(store.writerVerifiedWebSocketLease)
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .activeConflict)

        // 3. 电脑端释放锁后再次点「重试」：thread/resume 成功后才清除冲突并显示已解除锁定。
        let cursorBeforeUnlockedRetry = await transport.sentMessages().count
        let unlockedRetryTask = Task { await store.retrySelectedSessionWriterAccess() }
        let unlockedTurns = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: cursorBeforeUnlockedRetry
        )
        transportResponse(transport, id: unlockedTurns.id, result: #"{"data":[],"nextCursor":null}"#)
        await unlockedRetryTask.value

        let unlockedResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: cursorBeforeUnlockedRetry
        )
        transportResponse(transport, id: unlockedResume.id, result: #"{"thread":\#(idleThreadJSON)}"#)
        try await waitForWebSocketStatus(.connected, store: store)

        XCTAssertFalse(store.hasActiveWriterConflict(sessionID: source.id))
        XCTAssertEqual(store.writerVerifiedWebSocketLease, originLease)
        XCTAssertEqual(store.conversationReadiness(for: source), .live)
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .resolvedWritable)
    }

    func testWriterConflictRetryRejectsNoRolloutFoundAndRequiresServerResumeConfirmation() async throws {
        let project = AgentProject(id: "proj-win-no-rollout", name: "WinNoRollout", path: "C:/repo/win-no-rollout")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "win-no-rollout-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: [
                        "initialize",
                        "initialized",
                        "thread/list",
                        "thread/read",
                        "thread/turns/list",
                        "thread/items/list",
                        "thread/resume"
                    ],
                    transport: "ws"
                )
            }
        )
        let apiClient = CodexAppServerSessionAPIClient(runtime: runtime)
        let appStore = makeIsolatedAppStore()
        appStore.token = "win-no-rollout-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { apiClient },
            webSocketFactory: { CodexAppServerSessionWebSocketClient(runtime: runtime) }
        )
        defer { store.returnToSessionList() }

        let threadID = "thr-win-no-rollout-conflict"
        let idleThreadJSON = #"{"id":"thr-win-no-rollout-conflict","sessionId":"thr-win-no-rollout-conflict","preview":"Windows no rollout","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490005,"status":{"type":"idle"},"path":null,"cwd":"C:/repo/win-no-rollout","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Windows no rollout","turns":[]}"#
        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"windows"}"#
        )
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(
            transport,
            id: list.id,
            result: #"{"data":[\#(idleThreadJSON)],"nextCursor":null}"#
        )
        let page = try await pageTask.value
        let source = try XCTUnwrap(page.sessions.first)

        store.projects = [project]
        store.sidebarProjects = [project]
        store.sessions = [source]
        store.selectedProjectID = project.id
        store.selectedSessionID = source.id
        store.setActiveWriterConflict(true, sessionID: source.id)
        let originLease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: source.id)

        // 显式写入权校验遇到 "no rollout found" 时不得良性返回：必须向上失败、不缓存 resume、
        // 不清除写入冲突，也不能把引导状态推进到 .resolvedWritable。
        let cursorBeforeRejectedRetry = await transport.sentMessages().count
        let rejectedRetryTask = Task { await store.retrySelectedSessionWriterAccess() }
        let rejectedTurns = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: cursorBeforeRejectedRetry
        )
        transportResponse(transport, id: rejectedTurns.id, result: #"{"data":[],"nextCursor":null}"#)
        await rejectedRetryTask.value

        let rejectedResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: cursorBeforeRejectedRetry
        )
        XCTAssertEqual(rejectedResume.params?["threadId"]?.stringValue, threadID)
        let noRolloutMessage = "no rollout found for thread id \(threadID)"
        transportErrorResponse(
            transport,
            id: rejectedResume.id,
            code: -32600,
            message: noRolloutMessage
        )
        let expectedFailure = CodexAppServerConnectionError.appServer(
            CodexAppServerError(code: -32600, message: noRolloutMessage, data: nil)
        ).localizedDescription
        try await waitForWebSocketStatus(.failed(expectedFailure), store: store)

        let cachedAfterRejection = await runtime.threadsResumedOnConnection.contains(threadID)
        XCTAssertFalse(cachedAfterRejection, "被拒的写入权校验不得把会话写入已 resume 缓存")
        XCTAssertTrue(store.hasActiveWriterConflict(sessionID: source.id))
        XCTAssertNil(store.writerVerifiedWebSocketLease)
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .activeConflict)

        // 仅当服务端实际接受 thread/resume 后，才允许清除冲突并恢复可写态。
        let cursorBeforeConfirmedRetry = await transport.sentMessages().count
        let confirmedRetryTask = Task { await store.retrySelectedSessionWriterAccess() }
        let confirmedTurns = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: cursorBeforeConfirmedRetry
        )
        transportResponse(transport, id: confirmedTurns.id, result: #"{"data":[],"nextCursor":null}"#)
        await confirmedRetryTask.value

        let confirmedResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: cursorBeforeConfirmedRetry
        )
        transportResponse(transport, id: confirmedResume.id, result: #"{"thread":\#(idleThreadJSON)}"#)
        try await waitForWebSocketStatus(.connected, store: store)

        XCTAssertFalse(store.hasActiveWriterConflict(sessionID: source.id))
        XCTAssertEqual(store.writerVerifiedWebSocketLease, originLease)
        XCTAssertEqual(store.conversationReadiness(for: source), .live)
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .resolvedWritable)
    }

    func testPassiveNoRolloutFallbackDoesNotConfirmWriterAccessOrClearConflict() async throws {
        let project = AgentProject(id: "proj-ssh-no-rollout", name: "SSHNoRollout", path: "/tmp/ssh-no-rollout")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "ssh-no-rollout-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: [
                        "initialize",
                        "initialized",
                        "thread/list",
                        "thread/read",
                        "thread/turns/list",
                        "thread/items/list",
                        "thread/resume"
                    ],
                    transport: "ssh"
                )
            }
        )
        let apiClient = CodexAppServerSessionAPIClient(runtime: runtime)
        let appStore = makeIsolatedAppStore()
        appStore.token = "ssh-no-rollout-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { apiClient },
            webSocketFactory: { CodexAppServerSessionWebSocketClient(runtime: runtime) }
        )
        defer { store.returnToSessionList() }

        let threadID = "thr-ssh-no-rollout"
        let idleThreadJSON = #"{"id":"thr-ssh-no-rollout","sessionId":"thr-ssh-no-rollout","preview":"SSH idle","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490005,"status":{"type":"idle"},"path":null,"cwd":"/tmp/ssh-no-rollout","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"SSH idle","turns":[]}"#
        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(
            transport,
            id: list.id,
            result: #"{"data":[\#(idleThreadJSON)],"nextCursor":null}"#
        )
        let page = try await pageTask.value
        let source = try XCTUnwrap(page.sessions.first)

        store.projects = [project]
        store.sidebarProjects = [project]
        store.sessions = [source]
        store.selectedProjectID = project.id
        store.selectedSessionID = source.id
        store.setActiveWriterConflict(true, sessionID: source.id)
        let originLease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: source.id)

        // 1. 被动连接命中 no rollout found 仍可放行进入 .connected（避免空线程重连死循环），
        // 但未获得服务端写入权确认：不得清除冲突，也不得写入 writerVerifiedWebSocketLease。
        let cursorBeforePassive = await transport.sentMessages().count
        store.connectWebSocket(source, replayBufferedEvents: false, allowNonRunning: true)
        let passiveResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: cursorBeforePassive
        )
        transportErrorResponse(
            transport,
            id: passiveResume.id,
            code: -32600,
            message: "no rollout found for thread id \(threadID)"
        )
        try await waitForWebSocketStatus(.connected, store: store)

        XCTAssertTrue(store.hasActiveWriterConflict(sessionID: source.id))
        XCTAssertNil(store.writerVerifiedWebSocketLease)
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .activeConflict)

        // 2. 同连接上再次被动 connectForEvents 命中 no rollout found 放行缓存时，
        // 不得把回退缓存误判为服务端已确认写入权（返回 false，且不重发多余 thread/resume）。
        let sentCountBeforeCachedPassive = await transport.sentMessages().count
        let cachedPassiveConfirmed = try await runtime.connectForEvents(
            sessionID: threadID,
            verifyWriterAccess: false
        )
        XCTAssertFalse(cachedPassiveConfirmed, "no rollout found 放行缓存绝不得返回已确认写入权")
        let sentCountAfterCachedPassive = await transport.sentMessages().count
        XCTAssertEqual(sentCountAfterCachedPassive, sentCountBeforeCachedPassive)
        XCTAssertTrue(store.hasActiveWriterConflict(sessionID: source.id))
        XCTAssertNil(store.writerVerifiedWebSocketLease)
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .activeConflict)

        // 3. 显式重试必须绕过 no rollout found 放行缓存重新发起 thread/resume，
        // 服务端确认成功后才允许清除冲突并进入 .resolvedWritable。
        let cursorBeforeRetry = await transport.sentMessages().count
        let retryTask = Task { await store.retrySelectedSessionWriterAccess() }
        let retryTurns = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: cursorBeforeRetry
        )
        transportResponse(transport, id: retryTurns.id, result: #"{"data":[],"nextCursor":null}"#)
        await retryTask.value

        let retryResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: cursorBeforeRetry
        )
        transportResponse(transport, id: retryResume.id, result: #"{"thread":\#(idleThreadJSON)}"#)
        try await waitForWebSocketStatus(.connected, store: store)

        XCTAssertFalse(store.hasActiveWriterConflict(sessionID: source.id))
        XCTAssertEqual(store.writerVerifiedWebSocketLease, originLease)
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .resolvedWritable)
    }
}
