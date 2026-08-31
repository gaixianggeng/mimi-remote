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
}
