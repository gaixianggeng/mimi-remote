import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testChildOwnedHistoryTurnsFiltersOnlyProvablyInheritedSubagentPrefix() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test"
        )
        let thread: [String: CodexAppServerJSONValue] = [
            "id": .string("child-thread"),
            "parentThreadId": .string("parent-thread"),
            "createdAt": .int(200),
            "threadSource": .string("subagent"),
        ]
        let turns: [[String: CodexAppServerJSONValue]] = [
            ["id": .string("inherited-turn"), "startedAt": .int(100)],
            ["id": .string("same-second-turn"), "startedAt": .int(200)],
            ["id": .string("missing-time-turn")],
            ["id": .string("child-turn"), "startedAt": .int(201)],
        ]

        let filtered = await runtime.childOwnedHistoryTurns(in: thread, turns: turns)
        let sourceOnlyFiltered = await runtime.childOwnedHistoryTurns(
            in: [
                "id": .string("source-only-child"),
                "createdAt": .int(200),
                "source": .object(["subAgent": .object(["thread_spawn": .object([:])])]),
            ],
            turns: turns
        )

        XCTAssertEqual(
            filtered.compactMap { $0["id"]?.stringValue },
            ["same-second-turn", "child-turn"]
        )
        XCTAssertEqual(
            sourceOnlyFiltered.compactMap { $0["id"]?.stringValue },
            ["same-second-turn", "child-turn"]
        )
    }

    func testChildOwnedHistoryTurnsFailsOpenForOrdinaryForkAndIncompleteMetadata() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test"
        )
        let preCreationTurns: [[String: CodexAppServerJSONValue]] = [
            ["id": .string("pre-creation-turn"), "startedAt": .int(100)],
            ["id": .string("missing-time-turn")],
        ]
        let ordinaryFork: [String: CodexAppServerJSONValue] = [
            "id": .string("ordinary-fork"),
            "forkedFromId": .string("root-thread"),
            "createdAt": .int(200),
            "source": .string("vscode"),
            "threadSource": .string("user"),
        ]
        let childWithoutCreatedAt: [String: CodexAppServerJSONValue] = [
            "id": .string("child-without-created-at"),
            "parentThreadId": .string("parent-thread"),
            "threadSource": .string("subagent"),
        ]

        let ordinaryForkResult = await runtime.childOwnedHistoryTurns(
            in: ordinaryFork,
            turns: preCreationTurns
        )
        let missingMetadataResult = await runtime.childOwnedHistoryTurns(
            in: childWithoutCreatedAt,
            turns: preCreationTurns
        )

        XCTAssertEqual(
            ordinaryForkResult.compactMap { $0["id"]?.stringValue },
            ["pre-creation-turn", "missing-time-turn"]
        )
        XCTAssertEqual(
            missingMetadataResult.compactMap { $0["id"]?.stringValue },
            ["pre-creation-turn", "missing-time-turn"]
        )
    }

    func testPagedTurnHistoryUsesCachedSourceOnlyChildMetadataAndClosesInheritedCursor() async throws {
        let project = AgentProject(id: "subagent-paged", name: "Subagent Paged", path: "/tmp/subagent-paged")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/read",
            "thread/turns/list",
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods)
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let hydrateTask = Task {
            try await client.session(id: "child-thread", afterSeq: nil)
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
            result: #"{"thread":{"id":"child-thread","sessionId":"child-thread","preview":"child","ephemeral":false,"modelProvider":"openai","createdAt":200,"updatedAt":220,"status":{"type":"idle"},"path":null,"cwd":"/tmp/subagent-paged","cliVersion":"0.0.0","source":{"subAgent":{"thread_spawn":{}}},"agentNickname":"Curie","name":null,"turns":[]}}"#
        )
        _ = try await hydrateTask.value

        let sentBeforePage = await transport.sentMessages().count
        let pageTask = Task {
            try await client.messagesPage(sessionID: "child-thread", before: nil, limit: 50)
        }
        let turnsRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: sentBeforePage
        )
        transportResponse(
            transport,
            id: turnsRequest.id,
            result: #"{"data":[{"id":"child-turn","startedAt":201,"completedAt":220,"status":"completed","items":[{"type":"agentMessage","id":"child-result","text":"child result","phase":"final_answer"}]},{"id":"synthetic-parent-rollout","status":"completed","items":[{"type":"agentMessage","id":"synthetic-parent-result","text":"synthetic parent result","phase":"final_answer"}]},{"id":"inherited-turn","startedAt":100,"status":"interrupted","items":[{"type":"userMessage","id":"parent-user","content":[{"type":"text","text":"parent request"}]},{"type":"agentMessage","id":"parent-commentary","text":"parent commentary","phase":"commentary"}]}],"nextCursor":"older-parent-prefix"}"#
        )

        let page = try await pageTask.value
        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }

        XCTAssertEqual(page.messages.map(\.content), ["child result"])
        XCTAssertNil(page.previousCursor)
        XCTAssertFalse(page.hasMoreBefore)
        XCTAssertEqual(requests.filter { $0.method == "thread/read" }.count, 1)
        XCTAssertEqual(requests.filter { $0.method == "thread/turns/list" }.count, 1)

        // 人工直达一个更老 cursor，覆盖真实数据里“整页都是继承 synthetic rollout”的边界；
        // 即使上游继续给 nextCursor，返回给 Store 的 cursor/hasMore/notice 也必须一致关闭。
        let sentBeforeInheritedOnlyPage = await transport.sentMessages().count
        let inheritedOnlyTask = Task {
            try await runtime.messagesPage(
                sessionID: "child-thread",
                before: CodexAppServerSessionRuntime.encodeThreadTurnsCursor("forced-parent-page"),
                limit: 50,
                loadMode: .economy
            )
        }
        let inheritedOnlyRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: sentBeforeInheritedOnlyPage
        )
        XCTAssertEqual(inheritedOnlyRequest.params?.objectValue?["cursor"]?.stringValue, "forced-parent-page")
        transportResponse(
            transport,
            id: inheritedOnlyRequest.id,
            result: #"{"data":[{"id":"synthetic-parent-only","status":"completed","items":[{"type":"agentMessage","id":"synthetic-parent-only-result","text":"parent only","phase":"final_answer"}]},{"id":"older-parent-only","startedAt":50,"status":"completed","items":[{"type":"agentMessage","id":"older-parent-only-result","text":"older parent only","phase":"final_answer"}]}],"nextCursor":"even-older-parent"}"#
        )

        let inheritedOnlyPage = try await inheritedOnlyTask.value
        XCTAssertTrue(inheritedOnlyPage.messages.isEmpty)
        XCTAssertNil(inheritedOnlyPage.previousCursor)
        XCTAssertFalse(inheritedOnlyPage.hasMoreBefore)
        XCTAssertNil(inheritedOnlyPage.notice)
    }

    func testOrdinaryForkPagedHistoryKeepsPreCreationTurnsAndCursor() async throws {
        let project = AgentProject(id: "ordinary-fork-paged", name: "Ordinary Fork", path: "/tmp/ordinary-fork-paged")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/read",
            "thread/turns/list",
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods)
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let hydrateTask = Task {
            try await client.session(id: "ordinary-fork", afterSeq: nil)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let metadataRead = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        transportResponse(
            transport,
            id: metadataRead.id,
            result: #"{"thread":{"id":"ordinary-fork","sessionId":"ordinary-fork","forkedFromId":"root-thread","preview":"fork","ephemeral":false,"modelProvider":"openai","createdAt":200,"updatedAt":220,"status":{"type":"idle"},"path":null,"cwd":"/tmp/ordinary-fork-paged","cliVersion":"0.0.0","source":{"custom":"vscode"},"threadSource":"user","name":"Ordinary fork","turns":[]}}"#
        )
        _ = try await hydrateTask.value

        let sentBeforePage = await transport.sentMessages().count
        let pageTask = Task {
            try await client.messagesPage(sessionID: "ordinary-fork", before: nil, limit: 50)
        }
        let turnsRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: sentBeforePage
        )
        transportResponse(
            transport,
            id: turnsRequest.id,
            result: #"{"data":[{"id":"missing-time-turn","status":"completed","items":[{"type":"agentMessage","id":"missing-time-result","text":"missing time root result","phase":"final_answer"}]},{"id":"pre-creation-turn","startedAt":100,"completedAt":110,"status":"completed","items":[{"type":"agentMessage","id":"pre-creation-result","text":"pre-creation root result","phase":"final_answer"}]}],"nextCursor":"ordinary-older"}"#
        )

        let page = try await pageTask.value

        XCTAssertEqual(
            Set(page.messages.map(\.content)),
            Set(["missing time root result", "pre-creation root result"])
        )
        XCTAssertNotNil(page.previousCursor)
        XCTAssertTrue(page.hasMoreBefore)
    }
}
