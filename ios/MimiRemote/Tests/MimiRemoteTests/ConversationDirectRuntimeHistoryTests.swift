import XCTest
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testIndexedThreadListRepairsKnownRecentSessionMissingFromFullPage() async throws {
        let project = AgentProject(id: "proj_state_db_boundary", name: "State DB Boundary", path: "/tmp/state-db-boundary")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, allowedMethods: ["initialize", "initialized", "thread/list"])
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        func threadRow(id: String, recencyAt: Int) -> String {
            #"{"id":"\#(id)","sessionId":"\#(id)","preview":"\#(id)","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":\#(recencyAt),"recencyAt":\#(recencyAt),"status":{"type":"idle"},"path":null,"cwd":"/tmp/state-db-boundary","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"\#(id)","turns":[]}"#
        }

        let firstTask = Task { try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let firstList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        XCTAssertEqual(firstList.params?.objectValue?["sortKey"]?.stringValue, "recency_at")
        XCTAssertEqual(firstList.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
        XCTAssertNil(firstList.params?.objectValue?["refreshHistory"])
        transportResponse(
            transport,
            id: firstList.id,
            result: #"{"data":[\#(threadRow(id: "known-recent", recencyAt: 300))],"nextCursor":null}"#
        )
        _ = try await firstTask.value

        let sentBeforeIndexedPage = await transport.sentMessages().count
        let repairedTask = Task { try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let indexedList = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/list",
            after: sentBeforeIndexedPage
        )
        XCTAssertEqual(indexedList.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
        let indexedRows = (0..<20).map { threadRow(id: "indexed-\($0)", recencyAt: 200 - $0) }.joined(separator: ",")
        let sentBeforeRepair = await transport.sentMessages().count
        transportResponse(
            transport,
            id: indexedList.id,
            result: #"{"data":[\#(indexedRows)],"nextCursor":"older"}"#
        )

        let repairList = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/list",
            after: sentBeforeRepair
        )
        XCTAssertEqual(repairList.params?.objectValue?["useStateDbOnly"]?.boolValue, false)
        transportResponse(
            transport,
            id: repairList.id,
            result: #"{"data":[\#(threadRow(id: "known-recent", recencyAt: 300)),\#(threadRow(id: "indexed-0", recencyAt: 200))],"nextCursor":null}"#
        )

        let repaired = try await repairedTask.value
        XCTAssertEqual(repaired.sessions.map(\.id), ["known-recent", "indexed-0"])
    }

    func testDirectRuntimeFallsBackOnceWhenRecencySortIsUnsupported() async throws {
        let project = AgentProject(id: "proj_recency_fallback", name: "Recency Fallback", path: "/tmp/recency-fallback")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, allowedMethods: ["initialize", "initialized", "thread/list"])
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        let pageTask = Task { try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let recencyList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        XCTAssertEqual(recencyList.params?.objectValue?["sortKey"]?.stringValue, "recency_at")
        let sentBeforeFallback = await transport.sentMessages().count
        transportErrorResponse(transport, id: recencyList.id, code: -32602, message: "sortKey recency_at unsupported")

        let fallbackList = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/list",
            after: sentBeforeFallback
        )
        XCTAssertEqual(fallbackList.params?.objectValue?["sortKey"]?.stringValue, "updated_at")
        transportResponse(
            transport,
            id: fallbackList.id,
            result: #"{"data":[{"id":"legacy-thread","sessionId":"legacy-thread","preview":"legacy","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":200,"status":{"type":"idle"},"path":null,"cwd":"/tmp/recency-fallback","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"legacy","turns":[]}],"nextCursor":null}"#
        )

        let page = try await pageTask.value
        XCTAssertEqual(page.sessions.map(\.id), ["legacy-thread"])
    }

    func testDirectRuntimeUsesPagedThreadTurnsListWhenGatewayAllowsIt() async throws {
        let project = AgentProject(id: "proj_turn_pages", name: "Turn Pages", path: "/tmp/turn-pages")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/list",
            "thread/start",
            "thread/read",
            "thread/turns/list",
            "turn/start",
            "turn/interrupt"
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let firstPageTask = Task {
            try await client.messagesPage(sessionID: "thr_turn_pages", before: nil, limit: 120)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let metadataRead = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        XCTAssertEqual(metadataRead.params?.objectValue?["includeTurns"]?.boolValue, false)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: metadataRead.id)),"result":{"thread":{"id":"thr_turn_pages","sessionId":"thr_turn_pages","preview":"turn pages","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"notLoaded"},"path":null,"cwd":"/tmp/turn-pages","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"turn pages","turns":[]}}}"#)

        let firstTurnsRequest = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        XCTAssertEqual(firstTurnsRequest.params?.objectValue?["limit"]?.intValue, 50)
        XCTAssertEqual(firstTurnsRequest.params?.objectValue?["sortDirection"]?.stringValue, "desc")
        XCTAssertEqual(firstTurnsRequest.params?.objectValue?["itemsView"]?.stringValue, "full")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: firstTurnsRequest.id)),"result":{"data":[{"id":"turn_new","items":[{"type":"userMessage","id":"item_3","created_at":1780490302,"content":[{"type":"text","text":"m3"}]},{"type":"agentMessage","id":"item_4","updated_at":1780490303,"text":"m4","phase":"final_answer"}]},{"id":"turn_old","started_at":1780490300,"completed_at":1780490301,"items":[{"type":"userMessage","id":"item_1","content":[{"type":"text","text":"m1"}]},{"type":"agentMessage","id":"item_2","text":"m2","phase":"final_answer"}]}],"nextCursor":"older-cursor","backwardsCursor":"newer-cursor"}}"#)

        let firstPage = try await firstPageTask.value
        XCTAssertEqual(firstPage.messages.map(\.content), ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(try XCTUnwrap(firstPage.messages.first { $0.content == "m4" }?.createdAt).timeIntervalSince1970, 1_780_490_303, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(firstPage.messages.first { $0.content == "m1" }).isTimestampFallback)
        XCTAssertFalse(try XCTUnwrap(firstPage.messages.first { $0.content == "m2" }).isTimestampFallback)
        XCTAssertFalse(try XCTUnwrap(firstPage.messages.first { $0.content == "m3" }).isTimestampFallback)
        XCTAssertFalse(try XCTUnwrap(firstPage.messages.first { $0.content == "m4" }).isTimestampFallback)
        XCTAssertTrue(firstPage.hasMoreBefore)
        let cursor = try XCTUnwrap(firstPage.previousCursor)

        let sentBeforeEarlierPage = await transport.sentMessages().count
        let earlierPageTask = Task {
            try await client.messagesPage(sessionID: "thr_turn_pages", before: cursor, limit: 120)
        }
        let earlierTurnsRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: sentBeforeEarlierPage
        )
        XCTAssertEqual(earlierTurnsRequest.params?.objectValue?["cursor"]?.stringValue, "older-cursor")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: earlierTurnsRequest.id)),"result":{"data":[{"id":"turn_earliest","startedAt":1780490200,"items":[{"type":"userMessage","id":"item_0","content":[{"type":"text","text":"m0"}]}]}],"nextCursor":null,"backwardsCursor":"mid-cursor"}}"#)

        let earlierPage = try await earlierPageTask.value
        XCTAssertEqual(earlierPage.messages.map(\.content), ["m0"])
        XCTAssertFalse(earlierPage.hasMoreBefore)

        let sent = await transport.sentMessages()
        let requests = sent.compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(requests.filter { $0.method == "thread/turns/list" }.count, 2)
        XCTAssertFalse(requests.contains { request in
            request.method == "thread/read" && request.params?.objectValue?["includeTurns"]?.boolValue == true
        })
    }

    func testPagedTurnsRecoverMissedCompletionForCachedActiveSession() async throws {
        let project = AgentProject(id: "proj_turn_page_recovery", name: "Turn Page Recovery", path: "/tmp/turn-page-recovery")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/list",
            "thread/start",
            "thread/read",
            "thread/turns/list",
            "turn/start",
            "turn/interrupt"
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let listTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let listRequest = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(
            transport,
            id: listRequest.id,
            result: #"{"data":[{"id":"thr_turn_page_recovery","sessionId":"thr_turn_page_recovery","preview":"分页恢复","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"active"},"path":null,"cwd":"/tmp/turn-page-recovery","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"分页恢复","turns":[{"id":"turn_page_recovery","status":"inProgress","items":[]}]}],"nextCursor":null,"backwardsCursor":null}"#
        )
        let sessions = try await listTask.value
        XCTAssertEqual(sessions.sessions.first?.activeTurnID, "turn_page_recovery")

        let events = await runtime.attachEvents(sessionID: "thr_turn_page_recovery")
        var recoveredMetadata: AgentEventMetadata?
        let recovered = expectation(description: "分页 turn 终态补回 turn/completed")
        let eventTask = Task { @MainActor in
            for await event in events {
                guard case .turnCompleted(let metadata) = event else {
                    continue
                }
                recoveredMetadata = metadata
                recovered.fulfill()
                return
            }
        }

        let pageTask = Task {
            try await client.messagesPage(
                sessionID: "thr_turn_page_recovery",
                before: nil,
                limit: 50,
                loadMode: .full
            )
        }
        let turnsRequest = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list", after: 3)
        transportResponse(
            transport,
            id: turnsRequest.id,
            result: #"{"data":[{"id":"turn_page_recovery","status":"failed","startedAt":1780490300,"completedAt":1780490310,"itemsView":"full","items":[{"type":"userMessage","id":"user_page_recovery","content":[{"type":"text","text":"恢复前的问题"}]},{"type":"agentMessage","id":"assistant_page_recovery","text":"恢复后的最终回答","phase":"final_answer"}]}],"nextCursor":null}"#
        )
        let page = try await pageTask.value
        await fulfillment(of: [recovered], timeout: 1)
        eventTask.cancel()

        XCTAssertEqual(page.messages.map(\.content), ["恢复前的问题", "恢复后的最终回答"])
        XCTAssertEqual(recoveredMetadata?.sessionID, "thr_turn_page_recovery")
        XCTAssertEqual(recoveredMetadata?.turnID, "turn_page_recovery")
        XCTAssertEqual(recoveredMetadata?.turnLifecycle, .failed)
        XCTAssertEqual(Set(page.messages.compactMap(\.turnLifecycle)), [.failed])
        let sent = await transport.sentMessages()
        let requests = sent.compactMap { try? decodeAppServerRequest($0) }
        XCTAssertFalse(requests.contains { request in
            request.method == "thread/read" && request.params?.objectValue?["includeTurns"]?.boolValue == true
        })
    }

    func testTurnInterruptAcknowledgementPollsUntilAuthoritativeTerminalTurn() async throws {
        let project = AgentProject(
            id: "proj_interrupt_recovery",
            name: "Interrupt Recovery",
            path: "/tmp/interrupt-recovery"
        )
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/list",
            "thread/start",
            "thread/read",
            "thread/turns/list",
            "turn/start",
            "turn/interrupt"
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            turnInterruptRecoveryDelaysNanoseconds: [1, 100_000_000],
            configProvider: {
                makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods)
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let listTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let listRequest = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(
            transport,
            id: listRequest.id,
            result: #"{"data":[{"id":"thr_interrupt_recovery","sessionId":"thr_interrupt_recovery","preview":"中断恢复","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"active"},"path":null,"cwd":"/tmp/interrupt-recovery","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"中断恢复","turns":[{"id":"turn_interrupt_recovery","status":"inProgress","items":[]}]}],"nextCursor":null,"backwardsCursor":null}"#
        )
        let sessions = try await listTask.value
        XCTAssertEqual(sessions.sessions.first?.activeTurnID, "turn_interrupt_recovery")

        let events = await runtime.attachEvents(sessionID: "thr_interrupt_recovery")
        var recoveredMetadata: AgentEventMetadata?
        let recovered = expectation(description: "中断后权威快照补回 turn/completed")
        let eventTask = Task { @MainActor in
            for await event in events {
                guard case .turnCompleted(let metadata) = event else {
                    continue
                }
                recoveredMetadata = metadata
                recovered.fulfill()
                return
            }
        }

        let interruptTask = Task {
            try await runtime.interruptActiveTurn(sessionID: "thr_interrupt_recovery")
        }
        let interruptRequest = try await waitForFakeAppServerRequest(transport, method: "turn/interrupt")
        XCTAssertEqual(interruptRequest.params?.objectValue?["threadId"]?.stringValue, "thr_interrupt_recovery")
        XCTAssertEqual(interruptRequest.params?.objectValue?["turnId"]?.stringValue, "turn_interrupt_recovery")
        transportResponse(transport, id: interruptRequest.id, result: #"{}"#)
        try await interruptTask.value

        let activeSnapshotRequest = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        let sentThroughActiveSnapshot = await transport.sentMessages().count
        transportResponse(
            transport,
            id: activeSnapshotRequest.id,
            result: #"{"data":[{"id":"turn_interrupt_recovery","status":"inProgress","items":[]}],"nextCursor":null}"#
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(recoveredMetadata, "权威快照仍为 inProgress 时不能乐观结束当前 turn")

        let terminalSnapshotRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: sentThroughActiveSnapshot
        )
        transportResponse(
            transport,
            id: terminalSnapshotRequest.id,
            result: #"{"data":[{"id":"turn_interrupt_recovery","status":"interrupted","startedAt":1780490300,"completedAt":1780490302,"items":[]}],"nextCursor":null}"#
        )
        await fulfillment(of: [recovered], timeout: 1)
        eventTask.cancel()

        XCTAssertEqual(recoveredMetadata?.sessionID, "thr_interrupt_recovery")
        XCTAssertEqual(recoveredMetadata?.turnID, "turn_interrupt_recovery")
        XCTAssertEqual(recoveredMetadata?.turnLifecycle, .interrupted)
        let sent = await transport.sentMessages()
        let requests = sent.compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(requests.filter { $0.method == "thread/turns/list" }.count, 2)
    }

    func testTargetedInterruptRecoveryWorksWithoutCachedActiveTurnAndProtectsNewerTurn() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token"
        )
        let interruptedTurn: [String: CodexAppServerJSONValue] = [
            "id": .string("turn_interrupted"),
            "status": .string("interrupted")
        ]

        let recovered = await runtime.recoverCompletedActiveTurnFromLatestTurnsPage(
            sessionID: "thr_targeted_recovery",
            turns: [interruptedTurn],
            recoveringInterruptedTurnID: "turn_interrupted"
        )
        XCTAssertEqual(recovered?.turnID, "turn_interrupted")
        XCTAssertEqual(recovered?.lifecycle, .interrupted)

        let newerActiveTurn: [String: CodexAppServerJSONValue] = [
            "id": .string("turn_newer"),
            "status": .string("inProgress")
        ]
        let mustNotRecover = await runtime.recoverCompletedActiveTurnFromLatestTurnsPage(
            sessionID: "thr_targeted_recovery",
            turns: [interruptedTurn, newerActiveTurn],
            recoveringInterruptedTurnID: "turn_interrupted"
        )
        XCTAssertNil(mustNotRecover, "新 turn 已开始时，旧中断完成不能把当前执行误判为空闲")
    }

    func testDirectRuntimeEconomyHistoryUsesSummaryTurnPagesAndNotice() async throws {
        let project = AgentProject(id: "proj_turn_pages_economy", name: "Turn Pages Economy", path: "/tmp/turn-pages-economy")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/list",
            "thread/start",
            "thread/read",
            "thread/turns/list",
            "turn/start",
            "turn/interrupt"
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(
                sessionID: "thr_turn_pages_economy",
                before: nil,
                limit: 60,
                loadMode: .economy
            )
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let metadataRead = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        XCTAssertEqual(metadataRead.params?.objectValue?["includeTurns"]?.boolValue, false)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: metadataRead.id)),"result":{"thread":{"id":"thr_turn_pages_economy","sessionId":"thr_turn_pages_economy","preview":"economy","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"notLoaded"},"path":null,"cwd":"/tmp/turn-pages-economy","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"economy","turns":[]}}}"#)

        let turnsRequest = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        XCTAssertEqual(turnsRequest.params?.objectValue?["limit"]?.intValue, 15)
        XCTAssertEqual(turnsRequest.params?.objectValue?["itemsView"]?.stringValue, "summary")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnsRequest.id)),"result":{"data":[{"id":"turn_summary","itemsView":"summary","items":[{"type":"userMessage","id":"item_1","created_at":1780490302,"content":[{"type":"text","text":"m1"}]},{"type":"agentMessage","id":"item_2","updated_at":1780490303,"text":"m2","phase":"final_answer"}]}],"nextCursor":"older-cursor"}}"#)

        let page = try await pageTask.value
        XCTAssertEqual(page.messages.map(\.content), ["m1", "m2"])
        XCTAssertEqual(page.loadMode, .economy)
        XCTAssertEqual(page.notice, L10n.text("ui.this_session_contains_large_images_or_tool_output"))
        XCTAssertTrue(page.hasMoreBefore)
    }

    func testDirectRuntimeThreadReadBackfillsHistoryContextFromTurns() async throws {
        let project = AgentProject(id: "proj_context", name: "Context", path: "/tmp/context")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let firstPageTask = Task {
            try await client.messagesPage(sessionID: "thr_context", before: nil, limit: 2)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        XCTAssertEqual(read.params?.objectValue?["includeTurns"]?.boolValue, true)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_context","sessionId":"thr_context","preview":"context","ephemeral":false,"modelProvider":"openai","createdAt":1780490200,"updatedAt":1780490201,"status":{"type":"idle"},"path":null,"cwd":"/tmp/context","cliVersion":"0.0.0","source":{"custom":"vscode"},"threadSource":"user","forkedFromId":"thr_parent","name":"context","turns":[{"id":"turn_context","startedAt":1780490200,"completedAt":1780490201,"status":"completed","items":[{"type":"userMessage","id":"user_context","content":[{"type":"text","text":"检查右栏 context"}]},{"type":"commandExecution","id":"cmd_context","command":"go test ./...","cwd":"/tmp/context","status":"completed","commandActions":[]},{"type":"fileChange","id":"file_context","status":"modified","changes":[{"path":"Sources/App.swift","kind":"modified"}]},{"type":"mcpToolCall","id":"mcp_context","server":"figma","tool":"get_design","pluginId":"figma","status":"completed"},{"type":"dynamicToolCall","id":"dyn_context","namespace":"tool_search","tool":"tool_search_tool","pluginId":"browser","status":"completed"},{"type":"collabAgentToolCall","id":"sub_context","tool":"Zeno","agentNickname":"Zeno","agentRole":"review","childThreadId":"thr_child","status":"completed"},{"type":"webSearch","id":"web_context","query":"SwiftUI Inspector","status":"completed"},{"type":"agentMessage","id":"assistant_context","text":"已完成 context 检查","phase":"final_answer"}]}]}}}"#)

        let firstPage = try await firstPageTask.value
        let context = try XCTUnwrap(firstPage.context)
        XCTAssertEqual(context.sessionID, "thr_context")
        XCTAssertEqual(context.environment?.cwd, "/tmp/context")
        XCTAssertEqual(context.sources.map(\.id), ["session_source", "thread_source", "forked_from"])
        XCTAssertEqual(context.sources.first?.label, "vscode")
        XCTAssertTrue(context.tasks.contains { $0.id == "cmd_context" && $0.kind == "command" && $0.title == "go test ./..." })
        XCTAssertTrue(context.tasks.contains { $0.id == "file_context" && $0.kind == "file_change" })
        XCTAssertTrue(context.tasks.contains { $0.id == "mcp_context" && $0.kind == "mcp_tool" })
        XCTAssertTrue(context.tasks.contains { $0.id == "dyn_context" && $0.kind == "dynamic_tool" })
        XCTAssertTrue(context.tasks.contains { $0.id == "sub_context" && $0.kind == "subagent" })
        XCTAssertTrue(context.tasks.contains { $0.id == "web_context" && $0.kind == "web_search" })
        XCTAssertEqual(context.subagents.first?.id, "thr_child")
        XCTAssertEqual(context.subagents.first?.parentThreadID, "thr_context")
        XCTAssertEqual(context.subagents.first?.displayName, "Zeno")

        let cursor = try XCTUnwrap(firstPage.previousCursor)
        let earlier = try await client.messagesPage(sessionID: "thr_context", before: cursor, limit: 2)
        XCTAssertEqual(earlier.context?.subagents.first?.id, "thr_child")

        let sent = await transport.sentMessages()
        let threadReadCount = sent.compactMap { try? decodeAppServerRequest($0) }.filter { $0.method == "thread/read" }.count
        XCTAssertEqual(threadReadCount, 1, "翻看更早历史应复用 history/context 缓存")
    }

    func testDirectRuntimeMapsThreadReadProcessItemsForTimelineCollapse() async throws {
        let project = AgentProject(id: "proj_processed_history", name: "Processed", path: "/tmp/processed")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_processed", before: nil, limit: nil)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_processed","sessionId":"thr_processed","preview":"调用子 agent 讲个笑话","ephemeral":false,"modelProvider":"openai","createdAt":1780490100,"updatedAt":1780490134,"status":{"type":"idle"},"path":null,"cwd":"/tmp/processed","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"processed","turns":[{"id":"turn_processed","startedAt":1780490100,"completedAt":1780490134,"itemsView":"full","status":"completed","error":null,"items":[{"type":"userMessage","id":"user_processed","clientId":"client_processed","content":[{"type":"text","text":"调用子 agent 讲个笑话"}]},{"type":"agentMessage","id":"commentary_processed","text":"我先调用一个子 agent。","phase":"commentary","memoryCitation":null},{"type":"plan","id":"plan_processed","text":"让子 agent 生成一个短笑话。"},{"type":"reasoning","id":"reasoning_processed","summary":["确认请求要讲笑话","准备生成最终笑话"],"content":[]},{"type":"commandExecution","id":"cmd_processed","command":"echo joke","cwd":"/tmp/processed","processId":null,"source":"exec","status":"completed","commandActions":[],"aggregatedOutput":"ok","exitCode":0,"durationMs":1000},{"type":"agentMessage","id":"assistant_processed","text":"程序员相亲，对方问：你会浪漫吗？","phase":"final_answer","memoryCitation":null}]}]}}}"#)

        let page = try await pageTask.value
        XCTAssertEqual(page.messages.map(\.role), ["user", "assistant", "system", "system", "system", "assistant"])
        XCTAssertEqual(page.messages.map(\.kind), [.message, .commentary, .plan, .reasoningSummary, .commandSummary, .message])
        XCTAssertEqual(page.messages.last?.createdAt, Date(timeIntervalSince1970: 1780490134))
        XCTAssertEqual(page.messages.first { $0.itemID == "reasoning_processed" }?.activityPayload?.subtitle, "准备生成最终笑话")
        let historyCommand = try XCTUnwrap(page.messages.first { $0.itemID == "cmd_processed" })
        XCTAssertEqual(historyCommand.activityPayload?.category, .runCommand)
        XCTAssertEqual(historyCommand.activityPayload?.displayTitle, "运行 echo joke")

        var projector = CodexAppServerEventProjector()
        let liveCommand = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_processed","turnId":"turn_processed","item":{"type":"commandExecution","id":"cmd_processed","command":"echo joke","cwd":"/tmp/processed","processId":null,"source":"exec","status":"completed","commandActions":[],"aggregatedOutput":"ok","exitCode":0,"durationMs":1000}}}"#)
        if case .processItemCompleted(let liveMessage, _, _) = try XCTUnwrap(projector.project(liveCommand)) {
            XCTAssertEqual(liveMessage.content, historyCommand.content)
            XCTAssertEqual(liveMessage.activityPayload, historyCommand.activityPayload)
        } else {
            XCTFail("Expected live command process item")
        }

        let conversationStore = ConversationStore()
        conversationStore.setHistory(page.messages, sessionID: "thr_processed")
        let items = ConversationTimelineItemBuilder.items(from: conversationStore.messages(for: "thr_processed"))

        XCTAssertEqual(items.count, 5)
        guard case .message(let commentary) = items[1] else {
            return XCTFail("commentary 应保持完整正文")
        }
        XCTAssertEqual(commentary.itemID, "commentary_processed")
        XCTAssertEqual(commentary.kind, .commentary)
        guard case .message(let plan) = items[2] else {
            return XCTFail("plan 应保留在服务端 source order 中")
        }
        XCTAssertEqual(plan.kind, .plan)
        XCTAssertEqual(plan.content, "让子 agent 生成一个短笑话。")
        guard case .workGroup(let workGroup) = items[3],
              case .processGroup(let processGroup) = workGroup.entries.first else {
            return XCTFail("真实 reasoning 与后续命令应合并为可折叠阶段")
        }
        XCTAssertEqual(processGroup.header.itemID, "reasoning_processed")
        XCTAssertEqual(processGroup.activities.map(\.itemID), ["cmd_processed"])
        guard case .message(let final) = items[4] else {
            return XCTFail("最终 assistant 应保持独立展开")
        }
        XCTAssertEqual(final.role, .assistant)
        XCTAssertEqual(final.content, "程序员相亲，对方问：你会浪漫吗？")
    }

    // 关掉 App 一小时后回来：bridge 的会话还活着、turn 还停在审批上，attach 时用
    // serverRequest/replay 把未应答的请求推回来。这条路必须绕开僵尸审批检查——
    // Claude bridge 把停在审批上的线程仍报成 idle，走那个检查会把真正在等的提示
    // 直接 decline 掉，用户看到的就是一个永远不动的任务。
    func testDirectRuntimeRestoresReplayedServerRequestOnIdleReportingThread() async throws {
        let project = AgentProject(id: "proj_replay", name: "Replay", path: "/tmp/replay")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let sessionTask = Task {
            try await client.session(id: "thr_replay")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_replay","sessionId":"thr_replay","preview":"等审批","ephemeral":false,"modelProvider":"anthropic","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/replay","cliVersion":"0.0.0","source":"claude","threadSource":"user","name":"等审批","turns":[]}}}"#)
        _ = try await sessionTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_replay")

        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resume = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resume.method, "thread/resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_replay","sessionId":"thr_replay","preview":"等审批","ephemeral":false,"modelProvider":"anthropic","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/replay","cliVersion":"0.0.0","source":"claude","threadSource":"user","name":"等审批","turns":[]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        transport.enqueue(#"{"jsonrpc":"2.0","method":"serverRequest/replay","params":{"outstanding":[{"id":"req-abc","method":"item/commandExecution/requestApproval","params":{"threadId":"thr_replay","turnId":"turn_live","itemId":"cmd_live","command":"cargo install --path ."}}]}}"#)

        for _ in 0..<200 where !events.contains(where: { if case .approvalRequest = $0 { return true } else { return false } }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        }, "重放的未应答审批应当重新弹出审批卡")

        // 它是活的，不能被当成僵尸请求自动 decline 掉。
        let sent = await transport.sentMessages()
        XCTAssertFalse(sent.contains { $0.contains("\"decision\":\"decline\"") },
                       "重放的审批不应被自动拒绝")

        socket.disconnect()
    }

    func testDirectRuntimeDropsStaleReplayedApprovalForIdleThread() async throws {
        let project = AgentProject(id: "proj_stale", name: "Stale", path: "/tmp/stale")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let sessionTask = Task {
            try await client.session(id: "thr_stale")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_stale","sessionId":"thr_stale","preview":"僵尸审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"僵尸审批","turns":[]}}}"#)
        _ = try await sessionTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_stale")

        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resume = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resume.method, "thread/resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_stale","sessionId":"thr_stale","preview":"僵尸审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"僵尸审批","turns":[]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        // 模拟 app-server 在 resume 时重放一个早已被放弃的审批：thread 当前权威状态是 idle、没有活跃 turn。
        transport.enqueue(#"{"id":4242,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_stale","turnId":"turn_dead","itemId":"cmd_dead","command":"xcrun devicectl list devices"}}"#)

        // 运行时应当直接回 decline 把僵尸请求从 app-server 挂起表里释放，而不是把它当成有效审批弹给 UI。
        let release = try await waitForFakeAppServerResponse(transport, id: .int(4242))
        XCTAssertEqual(release.result?["decision"]?.stringValue, "decline")

        XCTAssertFalse(events.contains {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        }, "过期重放的审批不应再作为有效审批卡展示")

        socket.disconnect()
    }

    func testDirectRuntimeDropsStaleReplayedApprovalForOldTurnWhileCurrentTurnIsActive() async throws {
        let project = AgentProject(id: "proj_stale_turn", name: "Stale Turn", path: "/tmp/stale-turn")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let sessionTask = Task {
            try await client.session(id: "thr_stale_turn")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_stale_turn","sessionId":"thr_stale_turn","preview":"旧 turn 审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/stale-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"旧 turn 审批","turns":[{"id":"turn_current","status":"inProgress","items":[]}]}}}"#)
        let sessionResponse = try await sessionTask.value
        let session = sessionResponse.session
        XCTAssertEqual(session.status, "waiting_for_approval")
        XCTAssertEqual(session.activeTurnID, "turn_current")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_stale_turn")

        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resume = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resume.method, "thread/resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_stale_turn","sessionId":"thr_stale_turn","preview":"旧 turn 审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/stale-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"旧 turn 审批","turns":[{"id":"turn_current","status":"inProgress","items":[]}]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        // 真实现场：thread 当前有新的 active turn，但 app-server 还重放旧 turn 的未决审批。
        transport.enqueue(#"{"id":5151,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_stale_turn","turnId":"turn_old","itemId":"cmd_old","command":"/bin/zsh -lc 'xcrun devicectl list devices'"}}"#)

        let release = try await waitForFakeAppServerResponse(transport, id: .int(5151))
        XCTAssertEqual(release.result?["decision"]?.stringValue, "decline")

        for _ in 0..<200 where !events.contains(where: {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_stale_turn"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_stale_turn"
            }
            return false
        })
        XCTAssertFalse(events.contains {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        }, "旧 turn 的审批不应重新变成输入框上方的审批卡")

        socket.disconnect()
    }

    func testDirectRuntimeShowsOldApprovalWhenItsTurnIsStillActive() async throws {
        // 即便 approval 自带的 startedAtMs 很早，只要 app-server 当前仍把同一个 turn 报为等待审批，
        // runtime 就不能自动 decline/cancel；真实用户可能隔很久才回到 iPad 处理这个审批。
        let project = AgentProject(id: "proj_ancient", name: "Ancient", path: "/tmp/ancient")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let sessionTask = Task {
            try await client.session(id: "thr_ancient")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        // 关键：active turn 就是旧审批所在的 turn（turn_ancient），按 turn 比对识别不出来。
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_ancient","sessionId":"thr_ancient","preview":"远古审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/ancient","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"远古审批","turns":[{"id":"turn_ancient","status":"inProgress","items":[]}]}}}"#)
        let sessionResponse = try await sessionTask.value
        XCTAssertEqual(sessionResponse.session.activeTurnID, "turn_ancient")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_ancient")

        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resume = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resume.method, "thread/resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_ancient","sessionId":"thr_ancient","preview":"远古审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/ancient","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"远古审批","turns":[{"id":"turn_ancient","status":"inProgress","items":[]}]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        // startedAtMs=1000 表示 1970 年。过去这里会被 10 分钟阈值自动 cancel，现在必须继续交给用户决定。
        transport.enqueue(#"{"id":6262,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_ancient","turnId":"turn_ancient","itemId":"cmd_ancient","startedAtMs":1000,"command":"/bin/zsh -lc 'xcrun devicectl list devices'","availableDecisions":["accept","cancel"]}}"#)

        for _ in 0..<200 where !events.contains(where: {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .approvalRequest(let approval, let metadata) = $0 {
                return approval.id == "cmd_ancient" && metadata.sessionID == "thr_ancient"
            }
            return false
        }, "当前 active turn 的长时间等待审批仍应弹给用户处理")
        let sentMessages = await transport.sentMessages()
        XCTAssertFalse(sentMessages.contains { message in
            guard let response = try? AgentAPIClient.decoder.decode(
                CodexAppServerResponse.self,
                from: Data(message.utf8)
            ) else {
                return false
            }
            return response.id == .int(6262)
        }, "runtime 不应因 startedAtMs 很早自动回复审批")

        socket.disconnect()
    }

    func testDirectRuntimeRefreshesCachedActiveTurnBeforeDroppingOldReplayedApproval() async throws {
        let project = AgentProject(id: "proj_stale_cached_turn", name: "Stale Cached Turn", path: "/tmp/stale-cached-turn")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let sessionTask = Task {
            try await client.session(id: "thr_stale_cached_turn")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_stale_cached_turn","sessionId":"thr_stale_cached_turn","preview":"缓存旧 turn","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/stale-cached-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"缓存旧 turn","turns":[{"id":"turn_old","status":"inProgress","items":[]}]}}}"#)
        let sessionResponse = try await sessionTask.value
        XCTAssertEqual(sessionResponse.session.status, "waiting_for_approval")
        XCTAssertEqual(sessionResponse.session.activeTurnID, "turn_old")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_stale_cached_turn")

        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resume = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resume.method, "thread/resume")
        // 真实现场里，app-server 可能同时保留旧审批 turn 和后来真正活跃的新 turn。
        // resume 返回 turns 时应以最新 inProgress 为准，不能让本地旧缓存继续覆盖当前 turn。
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_stale_cached_turn","sessionId":"thr_stale_cached_turn","preview":"缓存旧 turn","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490002,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/stale-cached-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"缓存旧 turn","turns":[{"id":"turn_old","status":"inProgress","items":[]},{"id":"turn_middle","status":"completed","items":[]},{"id":"turn_current","status":"inProgress","items":[]}]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        transport.enqueue(#"{"id":6161,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_stale_cached_turn","turnId":"turn_old","itemId":"cmd_old","command":"/bin/zsh -lc 'xcrun devicectl list devices'"}}"#)

        let release = try await waitForFakeAppServerResponse(transport, id: .int(6161))
        XCTAssertEqual(release.result?["decision"]?.stringValue, "decline")

        for _ in 0..<200 where !events.contains(where: {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_stale_cached_turn"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_stale_cached_turn"
            }
            return false
        })
        XCTAssertFalse(events.contains {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        }, "缓存里的旧 activeTurnID 不应让旧审批重新显示成审批卡")

        socket.disconnect()
    }

    func testCodexAppServerSessionRuntimeReconnectsAfterTransportReceiveFailure() async throws {
        let project = AgentProject(id: "proj_direct_reconnect", name: "Direct Reconnect", path: "/tmp/direct-reconnect")
        let transportPool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transportPool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                resumeID: "",
                clientMessageID: "client_reconnect_create"
            ))
        }

        let firstTransport = try await waitForFakeAppServerTransport(in: transportPool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        firstTransport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(firstTransport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        firstTransport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_reconnect","sessionId":"thr_reconnect","preview":"可重连会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490200,"updatedAt":1780490201,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-reconnect","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"直连重连","turns":[]}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_reconnect")
        let isReadyAfterCreate = await runtime.hasReadyConnectionForTesting()
        XCTAssertTrue(isReadyAfterCreate)

        firstTransport.failReceive()
        try await waitForRuntimeConnectionToBecomeUnavailable(runtime)

        let reconnectTask = Task {
            try await runtime.connectForEvents(sessionID: "thr_reconnect")
        }
        let secondTransport = try await waitForFakeAppServerTransport(in: transportPool, index: 1)
        let reconnectInitializeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 1)
        let reconnectInitialize = try decodeAppServerRequest(reconnectInitializeMessages[0])
        XCTAssertEqual(reconnectInitialize.method, "initialize")
        secondTransport.enqueue(#"{"id":\#(try jsonFragment(for: reconnectInitialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let reconnectHandshakeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 2)
        let initialized = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(reconnectHandshakeMessages[1].utf8)
        )
        XCTAssertEqual(initialized.method, "initialized")

        // connectForEvents 本身就要按官方 app-server 客户端流程 thread/resume，建立当前连接的 live listener。
        // 不能等到下一次 turn/start 才 resume，否则历史 pending approval 和早到 turn 事件都可能丢在上游。
        let reconnectResumeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 3)
        let reconnectResumeRequest = try decodeAppServerRequest(reconnectResumeMessages[2])
        XCTAssertEqual(reconnectResumeRequest.method, "thread/resume")
        XCTAssertEqual(reconnectResumeRequest.params?["threadId"]?.stringValue, "thr_reconnect")
        XCTAssertEqual(reconnectResumeRequest.params?["cwd"]?.stringValue, project.path)
        secondTransport.enqueue(#"{"id":\#(try jsonFragment(for: reconnectResumeRequest.id)),"result":{"thread":{"id":"thr_reconnect","sessionId":"thr_reconnect","preview":"可重连会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490200,"updatedAt":1780490202,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-reconnect","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"直连重连","turns":[]}}}"#)
        try await reconnectTask.value

        let turnTask = Task {
            try await runtime.startTurn(
                sessionID: "thr_reconnect",
                prompt: "断线后继续",
                clientMessageID: "client_reconnect_turn"
            )
        }
        let turnStart = try await waitForFakeAppServerRequest(secondTransport, method: "turn/start", after: 3)
        XCTAssertEqual(turnStart.method, "turn/start")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thr_reconnect")
        XCTAssertEqual(turnParams["cwd"]?.stringValue, project.path)
        XCTAssertEqual(turnParams["clientUserMessageId"]?.stringValue, "client_reconnect_turn")
        secondTransport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_reconnect","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490202,"completedAt":null,"durationMs":null}}}"#)

        let turnID = try await turnTask.value
        XCTAssertEqual(turnID, "turn_reconnect")
        let firstSentMessages = await firstTransport.sentMessages()
        let secondSentMessages = await secondTransport.sentMessages()
        XCTAssertEqual(firstSentMessages.count, 3)
        XCTAssertTrue(secondSentMessages.count >= 4)
        let secondRequests = secondSentMessages.compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(secondRequests.filter { $0.method == "thread/resume" }.count, 1)
        XCTAssertEqual(secondRequests.filter { $0.method == "turn/start" }.count, 1)
    }

    func testDirectRuntimeRecoversPendingUserInputAfterForegroundReconnectWithoutColdStart() async throws {
        let project = AgentProject(id: "proj_pending_input_recovery", name: "Pending Input Recovery", path: "/tmp/pending-input-recovery")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/list", "thread/resume"]
                )
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        // 回前台时 thread/list 能看到 waitingOnUserInput，但列表快照不包含
        // server request 的 questions/options；这就是侧边栏“待输入”但详情无卡片的现场状态。
        let listTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(
            transport,
            id: list.id,
            result: #"{"data":[{"id":"thr_pending_input_recovery","sessionId":"thr_pending_input_recovery","preview":"等待补充信息","ephemeral":false,"modelProvider":"openai","createdAt":1780491200,"updatedAt":1780491201,"status":{"type":"active","activeFlags":["waitingOnUserInput"]},"path":null,"cwd":"/tmp/pending-input-recovery","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"等待补充信息","turns":[{"id":"turn_pending_input_recovery","status":"inProgress","items":[]}]}],"nextCursor":null,"backwardsCursor":null}"#
        )
        let page = try await listTask.value
        XCTAssertEqual(page.sessions.first?.status, SessionStatus.waitingForInput.rawValue)
        XCTAssertNil(page.sessions.first?.pendingUserInput)

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }

        socket.connect(sessionID: "thr_pending_input_recovery", replayBufferedEvents: false)
        let firstResume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        transportResponse(
            transport,
            id: firstResume.id,
            result: #"{"thread":{"id":"thr_pending_input_recovery","sessionId":"thr_pending_input_recovery","preview":"等待补充信息","ephemeral":false,"modelProvider":"openai","createdAt":1780491200,"updatedAt":1780491202,"status":{"type":"active","activeFlags":["waitingOnUserInput"]},"path":null,"cwd":"/tmp/pending-input-recovery","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"等待补充信息","turns":[{"id":"turn_pending_input_recovery","status":"inProgress","items":[]}]}}"#
        )
        for _ in 0..<200 where statuses.filter({ $0 == .connected }).count < 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(statuses.filter { $0 == .connected }.count, 1)

        // 模拟 App 进后台后页面订阅被取消，底层 runtime/gateway 连接仍在。
        // 此时重连必须再发 thread/resume，不能被“已 resume”的本地标记短路。
        socket.disconnect()
        let beforeRecoveryConnect = await transport.sentMessages().count
        socket.connect(sessionID: "thr_pending_input_recovery", replayBufferedEvents: false)
        let recoveryResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: beforeRecoveryConnect
        )
        transportResponse(
            transport,
            id: recoveryResume.id,
            result: #"{"thread":{"id":"thr_pending_input_recovery","sessionId":"thr_pending_input_recovery","preview":"等待补充信息","ephemeral":false,"modelProvider":"openai","createdAt":1780491200,"updatedAt":1780491203,"status":{"type":"active","activeFlags":["waitingOnUserInput"]},"path":null,"cwd":"/tmp/pending-input-recovery","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"等待补充信息","turns":[{"id":"turn_pending_input_recovery","status":"inProgress","items":[]}]}}"#
        )
        transport.enqueue(#"{"id":701,"method":"item/tool/requestUserInput","params":{"threadId":"thr_pending_input_recovery","turnId":"turn_pending_input_recovery","itemId":"input_pending_recovery","questions":[{"id":"strategy","header":"策略","question":"期望怎么处理？","isOther":true,"isSecret":false,"options":[{"label":"确认并发送","description":"保留当前文本"}]}]}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .userInputRequest(let request, _) = $0 {
                return request.id == "input_pending_recovery"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains { event in
            if case .userInputRequest(let request, let metadata) = event {
                return request.id == "input_pending_recovery"
                    && metadata.sessionID == "thr_pending_input_recovery"
            }
            return false
        })

        // 再次切换会话时，runtime 已保有未处理请求；新页面应直接补放该请求，
        // 无需冷启动，也无需第三次 thread/resume。
        let userInputEventCount = events.filter {
            if case .userInputRequest(let request, _) = $0 {
                return request.id == "input_pending_recovery"
            }
            return false
        }.count
        socket.disconnect()
        let beforeKnownRequestReconnect = await transport.sentMessages().count
        socket.connect(sessionID: "thr_pending_input_recovery", replayBufferedEvents: false)
        for _ in 0..<200 where events.filter({
            if case .userInputRequest(let request, _) = $0 {
                return request.id == "input_pending_recovery"
            }
            return false
        }).count <= userInputEventCount {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(
            events.filter {
                if case .userInputRequest(let request, _) = $0 {
                    return request.id == "input_pending_recovery"
                }
                return false
            }.count,
            userInputEventCount
        )
        let messagesAfterKnownRequestReconnect = await transport.sentMessages()
        let reconnectRequests = messagesAfterKnownRequestReconnect
            .dropFirst(beforeKnownRequestReconnect)
            .compactMap { try? decodeAppServerRequest($0) }
        XCTAssertFalse(reconnectRequests.contains { $0.method == "thread/resume" })

        socket.disconnect()
    }

    func testCodexAppServerSessionWebSocketReportsDisconnectedAfterTransportReceiveFailure() async throws {
        let project = AgentProject(id: "proj_stream_disconnect", name: "Stream Disconnect", path: "/tmp/stream-disconnect")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                resumeID: "",
                clientMessageID: "client_stream_disconnect"
            ))
        }
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let threadStart = try await waitForFakeAppServerRequest(transport, method: "thread/start", after: 2)
        transportResponse(
            transport,
            id: threadStart.id,
            result: #"{"thread":{"id":"thr_stream_disconnect","sessionId":"thr_stream_disconnect","preview":"断线传播","ephemeral":false,"modelProvider":"openai","createdAt":1780490200,"updatedAt":1780490201,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stream-disconnect","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"断线传播","turns":[]}}"#
        )
        _ = try await createTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        socket.onStatus = { status in
            statuses.append(status)
        }
        socket.connect(sessionID: "thr_stream_disconnect")
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        transportResponse(
            transport,
            id: resume.id,
            result: #"{"thread":{"id":"thr_stream_disconnect","sessionId":"thr_stream_disconnect","preview":"断线传播","ephemeral":false,"modelProvider":"openai","createdAt":1780490200,"updatedAt":1780490202,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stream-disconnect","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"断线传播","turns":[]}}"#
        )
        try await waitForStatus(.connected, in: { statuses })

        transport.failReceive()
        try await waitForStatus(.disconnected, in: { statuses })

        XCTAssertEqual(statuses.last, .disconnected)
        XCTAssertFalse(statuses.contains {
            if case .failed = $0 {
                return true
            }
            return false
        })
        let ready = await runtime.hasReadyConnectionForTesting()
        XCTAssertFalse(ready)
    }

    func testAuthoritativeThreadReadRecoversMissingTurnCompleted() async throws {
        let project = AgentProject(id: "proj_snapshot_completion", name: "Snapshot Completion", path: "/tmp/snapshot-completion")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let listTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let listRequest = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 2)
        transportResponse(
            transport,
            id: listRequest.id,
            result: #"{"data":[{"id":"thr_snapshot_completion","sessionId":"thr_snapshot_completion","preview":"快照恢复","ephemeral":false,"modelProvider":"openai","createdAt":1780490200,"updatedAt":1780490201,"status":{"type":"active"},"path":null,"cwd":"/tmp/snapshot-completion","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"快照恢复","turns":[{"id":"turn_snapshot_old","status":"inProgress","items":[]}]}],"nextCursor":null,"backwardsCursor":null}"#
        )
        let sessions = try await listTask.value
        XCTAssertEqual(sessions.sessions.first?.activeTurnID, "turn_snapshot_old")

        let events = await runtime.attachEvents(sessionID: "thr_snapshot_completion")
        var recoveredMetadata: AgentEventMetadata?
        let recovered = expectation(description: "权威快照补回 turn/completed")
        let eventTask = Task { @MainActor in
            for await event in events {
                guard case .turnCompleted(let metadata) = event else {
                    continue
                }
                recoveredMetadata = metadata
                recovered.fulfill()
                return
            }
        }

        // 权威快照仍显示旧 turn 运行时不能补完成事件，否则会提前放行本地队列。
        let activeHistoryTask = Task {
            try await client.messagesPage(
                sessionID: "thr_snapshot_completion",
                before: nil,
                limit: 50,
                loadMode: .full
            )
        }
        let activeReadRequest = try await waitForFakeAppServerRequest(transport, method: "thread/read", after: 3)
        transportResponse(
            transport,
            id: activeReadRequest.id,
            result: #"{"thread":{"id":"thr_snapshot_completion","sessionId":"thr_snapshot_completion","preview":"快照恢复","ephemeral":false,"modelProvider":"openai","createdAt":1780490200,"updatedAt":1780490201,"status":{"type":"active"},"path":null,"cwd":"/tmp/snapshot-completion","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"快照恢复","turns":[{"id":"turn_snapshot_old","status":"inProgress","items":[]}]}}"#
        )
        _ = try await activeHistoryTask.value
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(recoveredMetadata)

        let completedHistoryTask = Task {
            try await client.messagesPage(
                sessionID: "thr_snapshot_completion",
                before: nil,
                limit: 50,
                loadMode: .full
            )
        }
        let completedReadRequest = try await waitForFakeAppServerRequest(transport, method: "thread/read", after: 4)
        transportResponse(
            transport,
            id: completedReadRequest.id,
            result: #"{"thread":{"id":"thr_snapshot_completion","sessionId":"thr_snapshot_completion","preview":"快照恢复","ephemeral":false,"modelProvider":"openai","createdAt":1780490200,"updatedAt":1780490202,"status":{"type":"idle"},"path":null,"cwd":"/tmp/snapshot-completion","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"快照恢复","turns":[{"id":"turn_snapshot_old","status":"interrupted","completedAt":1780490202,"items":[]}]}}"#
        )
        _ = try await completedHistoryTask.value
        await fulfillment(of: [recovered], timeout: 1)
        eventTask.cancel()

        XCTAssertEqual(recoveredMetadata?.sessionID, "thr_snapshot_completion")
        XCTAssertEqual(recoveredMetadata?.turnID, "turn_snapshot_old")
        XCTAssertEqual(recoveredMetadata?.turnLifecycle, .interrupted)
    }

    func testCodexAppServerSessionRuntimeKeepsConnectionAndEventsAfterTurnStartTimeout() async throws {
        let project = AgentProject(id: "proj_turn_timeout", name: "Turn Timeout", path: "/tmp/turn-timeout")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            requestTimeout: 0.05,
            longRunningRequestTimeout: 0.05,
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transportResponse(firstTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let listMessages = try await waitForFakeAppServerMessages(firstTransport, count: 3)
        let listRequest = try decodeAppServerRequest(listMessages[2])
        XCTAssertEqual(listRequest.method, "thread/list")
        transportResponse(firstTransport, id: listRequest.id, result: #"{"data":[{"id":"thr_turn_timeout","sessionId":"thr_turn_timeout","preview":"超时会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/turn-timeout","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"超时会话","turns":[]}],"nextCursor":null,"backwardsCursor":null}"#)
        _ = try await pageTask.value

        let events = await runtime.attachEvents(sessionID: "thr_turn_timeout")
        let receivedLateTurn = expectation(description: "超时后仍收到 turn/started")
        let eventTask = Task { @MainActor in
            for await event in events {
                guard case .turnStarted(let metadata) = event,
                      metadata.turnID == "turn_late_after_timeout" else {
                    continue
                }
                receivedLateTurn.fulfill()
                return
            }
        }

        let timeoutTask = Task {
            try await runtime.startTurn(sessionID: "thr_turn_timeout", prompt: "这次会超时", clientMessageID: "client_timeout")
        }
        let firstResumeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 4)
        let firstResume = try decodeAppServerRequest(firstResumeMessages[3])
        XCTAssertEqual(firstResume.method, "thread/resume")
        transportResponse(firstTransport, id: firstResume.id, result: #"{"thread":{"id":"thr_turn_timeout","sessionId":"thr_turn_timeout","preview":"超时会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490702,"status":{"type":"idle"},"path":null,"cwd":"/tmp/turn-timeout","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"超时会话","turns":[]}}"#)

        let firstTurnMessages = try await waitForFakeAppServerMessages(firstTransport, count: 5)
        let firstTurnStart = try decodeAppServerRequest(firstTurnMessages[4])
        XCTAssertEqual(firstTurnStart.method, "turn/start")

        do {
            _ = try await timeoutTask.value
            XCTFail("turn/start timeout should fail")
        } catch CodexAppServerConnectionError.timeout(let method, _) {
            XCTAssertEqual(method, "turn/start")
        } catch {
            XCTFail("Unexpected timeout error: \(error)")
        }

        // 已超时响应会被忽略，但同一连接上的通知仍必须继续投影到上层事件流。
        transportResponse(firstTransport, id: firstTurnStart.id, result: #"{"turn":{"id":"turn_late_after_timeout","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490704,"completedAt":null,"durationMs":null}}"#)
        firstTransport.enqueue(#"{"method":"turn/started","params":{"threadId":"thr_turn_timeout","turn":{"id":"turn_late_after_timeout"}}}"#)
        await fulfillment(of: [receivedLateTurn], timeout: 1)
        eventTask.cancel()

        // 后续轻量请求复用原连接；如果 timeout 被错误升级为连接故障，这里会创建第二个 transport。
        let modelTask = Task { try await runtime.modelOptions() }
        let modelList = try await waitForFakeAppServerRequest(firstTransport, method: "model/list", after: 5)
        transportResponse(firstTransport, id: modelList.id, result: #"{"models":[{"id":"gpt-timeout-recovered","title":"Recovered","provider":"openai","isDefault":true}]}"#)
        let models = try await modelTask.value

        XCTAssertEqual(models.map(\.model), ["gpt-timeout-recovered"])
        XCTAssertNil(pool.transport(at: 1), "单个 RPC timeout 不应创建第二条共享连接")
    }

    func testCodexAppServerSessionRuntimeCoalescesConcurrentThreadResumeOnSameConnection() async throws {
        let project = AgentProject(id: "proj_resume_singleflight", name: "Resume Single Flight", path: "/tmp/resume-singleflight")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let listRequest = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: listRequest.id, result: #"{"data":[{"id":"thr_resume_singleflight","sessionId":"thr_resume_singleflight","preview":"并发恢复","ephemeral":false,"modelProvider":"openai","createdAt":1780490800,"updatedAt":1780490801,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resume-singleflight","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"并发恢复","turns":[]}],"nextCursor":null,"backwardsCursor":null}"#)
        _ = try await pageTask.value

        async let first: Void = runtime.connectForEvents(sessionID: "thr_resume_singleflight")
        async let second: Void = runtime.connectForEvents(sessionID: "thr_resume_singleflight")
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)

        try await Task.sleep(nanoseconds: 80_000_000)
        let resumeCount = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
            .filter { $0.method == "thread/resume" }
            .count
        XCTAssertEqual(resumeCount, 1)

        transportResponse(transport, id: resume.id, result: #"{"thread":{"id":"thr_resume_singleflight","sessionId":"thr_resume_singleflight","preview":"并发恢复","ephemeral":false,"modelProvider":"openai","createdAt":1780490800,"updatedAt":1780490802,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resume-singleflight","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"并发恢复","turns":[]}}"#)
        try await first
        try await second
    }

    func testCodexAppServerSessionRuntimeRefreshesUnavailableGatewayConfigBeforeConnecting() async throws {
        let project = AgentProject(id: "proj_cold_start", name: "Cold Start", path: "/tmp/cold-start")
        let configProvider = SequencedDirectConfigProvider([
            makeDirectAppServerConfig(project: project, gatewayAvailable: false),
            makeDirectAppServerConfig(project: project, gatewayAvailable: true)
        ])
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { try await configProvider.next() }
        )

        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let listMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let listRequest = try decodeAppServerRequest(listMessages[2])
        XCTAssertEqual(listRequest.method, "thread/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: listRequest.id)),"result":{"data":[{"id":"thr_cold_start","sessionId":"thr_cold_start","preview":"首启恢复","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/cold-start","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"首启恢复","turns":[]}],"nextCursor":null,"backwardsCursor":null}}"#)

        let page = try await pageTask.value
        XCTAssertEqual(configProvider.callCount, 2)
        XCTAssertEqual(page.sessions.map(\.id), ["thr_cold_start"])
    }

    func testCodexAppServerSessionRuntimeListsExactChildWorkspaceDirectory() async throws {
        let project = AgentProject(id: "proj_root_list", name: "Root List", path: "/tmp/root-list")
        let childWorkspace = AgentWorkspace(
            id: "ws_root_list_child",
            name: "ios",
            path: "/tmp/root-list/apps/ios",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let worktreeWorkspace = AgentWorkspace(
            id: "ws_root_list_worktree",
            name: "feature",
            path: "/tmp/mimi-worktrees/root-list-feature",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let childPageTask = Task {
            try await runtime.sessionsPage(workspace: childWorkspace, cursor: nil, limit: 20)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let childMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let childList = try decodeAppServerRequest(childMessages[2])
        XCTAssertEqual(childList.method, "thread/list")
        XCTAssertEqual(childList.params?.objectValue?["cwd"]?.stringValue, childWorkspace.path)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: childList.id)),"result":{"data":[{"id":"thr_child_history","sessionId":"thr_child_history","preview":"child history","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"notLoaded"},"path":null,"cwd":"/tmp/root-list/apps/ios","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Child history","turns":[]}],"nextCursor":null,"backwardsCursor":null}}"#)

        let childPage = try await childPageTask.value
        XCTAssertEqual(childPage.sessions.map(\.id), ["thr_child_history"])
        XCTAssertEqual(childPage.sessions.first?.projectID, childWorkspace.id)

        let worktreePageTask = Task {
            try await runtime.sessionsPage(workspace: worktreeWorkspace, cursor: nil, limit: 20)
        }

        let worktreeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let worktreeList = try decodeAppServerRequest(worktreeMessages[3])
        XCTAssertEqual(worktreeList.method, "thread/list")
        XCTAssertEqual(worktreeList.params?.objectValue?["cwd"]?.stringValue, worktreeWorkspace.path)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: worktreeList.id)),"result":{"data":[],"nextCursor":null,"backwardsCursor":null}}"#)

        let worktreePage = try await worktreePageTask.value
        XCTAssertTrue(worktreePage.sessions.isEmpty)
    }

    func testSessionStoreConsumesDirectAppServerEventsWithoutMobileProtocolConversion() async throws {
        let project = AgentProject(id: "proj_store_direct", name: "Store Direct", path: "/tmp/store-direct")
        let config = makeDirectAppServerConfig(project: project)
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { config }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        let suiteName = "ConversationDataFlowTests.StoreDirect.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "store-direct",
            displayName: "Store Direct",
            endpoint: "http://127.0.0.1:8787",
            lastSuccessfulAt: nil
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("test-token".utf8), account: "agentd-profile.\(profile.id)")
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        let contextStore = SessionContextStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            contextStore: contextStore,
            clientFactory: { client },
            webSocketFactory: { CodexAppServerSessionWebSocketClient(runtime: runtime) },
            webSocketReconnectDelayNanoseconds: { _ in 1_000_000 }
        )

        store.selectedProjectID = project.id
        let refreshTask = Task { await store.refreshAll(autoAttach: false) }
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)
        let listMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let listRequest = try decodeAppServerRequest(listMessages[2])
        XCTAssertEqual(listRequest.method, "thread/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: listRequest.id)),"result":{"data":[],"nextCursor":null,"backwardsCursor":null}}"#)
        await refreshTask.value
        XCTAssertEqual(store.selectedProjectID, project.id)

        let sendTask = Task { await store.sendPrompt("帮我验收 direct Store") }
        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let modelList = try decodeAppServerRequest(threadMessages[3])
        XCTAssertEqual(modelList.method, "model/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: modelList.id)),"result":{"models":[{"id":"gpt-store-default","name":"Store Default","provider":"openai","isDefault":true}]}}"#)

        let threadStartMessages = try await waitForFakeAppServerMessages(transport, count: 5)
        let threadStart = try decodeAppServerRequest(threadStartMessages[4])
        XCTAssertEqual(threadStart.method, "thread/start")
        XCTAssertNil(threadStart.params?.objectValue?["model"]?.stringValue)
        XCTAssertNil(threadStart.params?.objectValue?["modelProvider"])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_store_direct","sessionId":"thr_store_direct","preview":"帮我验收 direct Store","ephemeral":false,"modelProvider":"openai","createdAt":1780490100,"updatedAt":1780490101,"status":{"type":"idle"},"path":null,"cwd":"/tmp/store-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Store 直连","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 6)
        let turnStart = try decodeAppServerRequest(turnMessages[5])
        XCTAssertEqual(turnStart.method, "turn/start")
        XCTAssertEqual(turnStart.params?.objectValue?["model"]?.stringValue, "gpt-store-default")
        let collaborationMode = try XCTUnwrap(turnStart.params?.objectValue?["collaborationMode"]?.objectValue)
        XCTAssertEqual(collaborationMode["mode"]?.stringValue, "default")
        XCTAssertEqual(collaborationMode["settings"]?.objectValue?["model"]?.stringValue, "gpt-store-default")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_store_direct","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490102,"completedAt":null,"durationMs":null}}}"#)
        // 新线程首轮由本地回显和 buffered event replay 承接，不能在 rollout 尚未就绪时
        // 追加 thread/read；若未来回归到旧行为，先响应请求让 sendTask 能退出，再给出明确断言。
        for _ in 0..<20 {
            if (await transport.sentMessages()).count > 6 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requestsAfterTurnStart = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        let unexpectedHistoryRead = requestsAfterTurnStart.first { $0.method == "thread/read" }
        if let unexpectedHistoryRead {
            transport.enqueue(#"{"id":\#(try jsonFragment(for: unexpectedHistoryRead.id)),"result":{"thread":{"id":"thr_store_direct","sessionId":"thr_store_direct","preview":"帮我验收 direct Store","ephemeral":false,"modelProvider":"openai","createdAt":1780490100,"updatedAt":1780490102,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/store-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Store 直连","turns":[]}}}"#)
        }
        let didSend = await sendTask.value
        XCTAssertTrue(didSend)
        XCTAssertNil(unexpectedHistoryRead, "新线程首轮 ACK 后不能同步读取尚未就绪的 rollout")
        XCTAssertFalse(conversationStore.hasLoadedHistory(sessionID: "thr_store_direct"))
        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertEqual(store.connectedSessionID, "thr_store_direct")
        XCTAssertNotNil(store.webSocket)
        XCTAssertNotNil(appStore.authenticatedCredentialFingerprint)
        try await waitForWebSocketStatus(.connected, store: store)
        XCTAssertEqual(store.selectedSessionID, "thr_store_direct")

        transport.enqueue(#"{"method":"item/agentMessage/delta","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","itemId":"assistant_store","delta":"阶段一"}}"#)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: "thr_store_direct") {
            $0.contains { $0.role == .assistant && $0.content.contains("阶段一") }
        }

        transport.enqueue(#"{"method":"item/completed","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","item":{"type":"agentMessage","id":"assistant_store","text":"最终回答"}}}"#)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: "thr_store_direct") {
            $0.contains { $0.role == .assistant && $0.content == "最终回答" }
        }

        transport.enqueue(#"{"method":"item/commandExecution/outputDelta","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","itemId":"cmd_store","delta":"go test ok\n","stream":"stdout"}}"#)
        for _ in 0..<300 where !logStore.log(for: "thr_store_direct").contains("go test ok") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(logStore.log(for: "thr_store_direct").contains("go test ok"))

        transport.enqueue(#"{"method":"turn/diff/updated","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","path":"Sources/App.swift","status":"modified"}}"#)
        for _ in 0..<300 where contextStore.context(for: "thr_store_direct")?.tasks.contains(where: { $0.kind == "file_change" && $0.subtitle == "Sources/App.swift" }) != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(contextStore.context(for: "thr_store_direct")?.tasks.contains { $0.kind == "file_change" && $0.subtitle == "Sources/App.swift" } == true)
        XCTAssertFalse(conversationStore.messages(for: "thr_store_direct").contains { $0.kind == .fileChangeSummary })

        transport.enqueue(#"{"method":"item/completed","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","item":{"type":"fileChange","id":"file_change_store","status":"modified","changes":[{"path":"Sources/App.swift","kind":"modified"}]}}}"#)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: "thr_store_direct") {
            $0.contains { $0.kind == .fileChangeSummary && $0.content.contains("Sources/App.swift") }
        }
        XCTAssertEqual(conversationStore.messages(for: "thr_store_direct").filter { $0.kind == .fileChangeSummary }.count, 1)

        transport.enqueue(#"{"id":101,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","itemId":"cmd_store","command":"go test ./..."}}"#)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: "thr_store_direct") {
            $0.contains { $0.kind == .approval && $0.content.contains("等待审批") }
        }
        store.decideApproval(ApprovalSummary(id: "cmd_store", title: "运行 go test", kind: "command", count: 1), accept: true)
        let approvalResponse = try await waitForFakeAppServerResponse(transport, id: .int(101))
        XCTAssertEqual(approvalResponse.id, .int(101))
        XCTAssertEqual(approvalResponse.result?["decision"]?.stringValue, "accept")

        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct"}}"#)
        for _ in 0..<200 where store.selectedForegroundActivity != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testDirectIdleHistorySessionSendsThroughResumePath() async throws {
        let project = AgentProject(id: "proj_direct_history", name: "Direct History", path: "/tmp/direct-history")
        let config = makeDirectAppServerConfig(project: project)
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { config }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        let conversationStore = ConversationStore()
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { CodexAppServerSessionWebSocketClient(runtime: runtime) },
            webSocketReconnectDelayNanoseconds: { _ in 1_000_000 }
        )

        store.selectedProjectID = project.id
        let refreshTask = Task { await store.refreshAll(autoAttach: false) }
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let listMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let listRequest = try decodeAppServerRequest(listMessages[2])
        XCTAssertEqual(listRequest.method, "thread/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: listRequest.id)),"result":{"data":[{"id":"thr_idle_history","sessionId":"thr_idle_history","preview":"历史 idle","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-history","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"历史 idle","turns":[]}],"nextCursor":null,"backwardsCursor":null}}"#)
        await refreshTask.value

        let historySession = try XCTUnwrap(store.filteredSessions.first)
        XCTAssertEqual(historySession.id, "thr_idle_history")
        XCTAssertEqual(historySession.status, "history")
        XCTAssertFalse(historySession.isRunning)

        let selectTask = Task { await store.selectSession(historySession) }
        let historyReadMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let historyRead = try decodeAppServerRequest(historyReadMessages[3])
        XCTAssertEqual(historyRead.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: historyRead.id)),"result":{"thread":{"id":"thr_idle_history","sessionId":"thr_idle_history","preview":"历史 idle","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-history","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"历史 idle","turns":[]}}}"#)
        await selectTask.value

        // 选中历史会话现在也会立即建立事件订阅：先在当前连接补一次 thread/resume。
        let subscriptionResumeMessages = try await waitForFakeAppServerMessages(transport, count: 5)
        let subscriptionResume = try decodeAppServerRequest(subscriptionResumeMessages[4])
        XCTAssertEqual(subscriptionResume.method, "thread/resume")
        XCTAssertEqual(subscriptionResume.params?.objectValue?["threadId"]?.stringValue, "thr_idle_history")
        XCTAssertEqual(
            subscriptionResume.params?.objectValue?["initialTurnsPage"]?.objectValue?["itemsView"]?.stringValue,
            "summary"
        )
        transport.enqueue(#"{"id":\#(try jsonFragment(for: subscriptionResume.id)),"result":{"thread":{"id":"thr_idle_history","sessionId":"thr_idle_history","preview":"历史 idle","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-history","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"历史 idle","turns":[]}}}"#)

        // 订阅建立后会异步刷新 thread 目标；回空结果即可。
        let goalMessages = try await waitForFakeAppServerMessages(transport, count: 6)
        let goalGet = try decodeAppServerRequest(goalMessages[5])
        XCTAssertEqual(goalGet.method, "thread/goal/get")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: goalGet.id)),"result":{}}"#)

        let sendTask = Task { await store.sendPrompt("继续排查") }
        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 7)
        let modelList = try decodeAppServerRequest(resumeMessages[6])
        XCTAssertEqual(modelList.method, "model/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: modelList.id)),"result":{"models":[{"id":"gpt-history-default","name":"History Default","provider":"openai","isDefault":true}]}}"#)

        let resumeRequestMessages = try await waitForFakeAppServerMessages(transport, count: 8)
        let resumeRequest = try decodeAppServerRequest(resumeRequestMessages[7])
        XCTAssertEqual(resumeRequest.method, "thread/resume")
        XCTAssertEqual(resumeRequest.params?.objectValue?["threadId"]?.stringValue, "thr_idle_history")
        XCTAssertNil(resumeRequest.params?.objectValue?["model"]?.stringValue)
        XCTAssertNil(resumeRequest.params?.objectValue?["modelProvider"])
        XCTAssertEqual(
            resumeRequest.params?.objectValue?["initialTurnsPage"]?.objectValue?["itemsView"]?.stringValue,
            "summary"
        )
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resumeRequest.id)),"error":{"code":-32080,"message":"thread/resume history response 过大，gateway 已阻断；请降低 limit/itemsView 或改用分页读取","data":{"reason":"history_response_too_large","method":"thread/resume","itemsView":"summary"}}}"#)

        let fallbackResumeMessages = try await waitForFakeAppServerMessages(transport, count: 9)
        let fallbackResume = try decodeAppServerRequest(fallbackResumeMessages[8])
        XCTAssertEqual(fallbackResume.method, "thread/resume")
        XCTAssertEqual(fallbackResume.params?.objectValue?["threadId"]?.stringValue, "thr_idle_history")
        XCTAssertNil(fallbackResume.params?.objectValue?["initialTurnsPage"])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: fallbackResume.id)),"result":{"thread":{"id":"thr_idle_history","sessionId":"thr_idle_history","preview":"继续排查","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490302,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-history","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"历史 idle","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 10)
        let turnStart = try decodeAppServerRequest(turnMessages[9])
        XCTAssertEqual(turnStart.method, "turn/start")
        XCTAssertEqual(turnStart.params?.objectValue?["threadId"]?.stringValue, "thr_idle_history")
        XCTAssertEqual(turnStart.params?.objectValue?["clientUserMessageId"]?.stringValue?.isEmpty, false)
        XCTAssertEqual(turnStart.params?.objectValue?["model"]?.stringValue, "gpt-history-default")
        let collaborationMode = try XCTUnwrap(turnStart.params?.objectValue?["collaborationMode"]?.objectValue)
        XCTAssertEqual(collaborationMode["mode"]?.stringValue, "default")
        XCTAssertEqual(collaborationMode["settings"]?.objectValue?["model"]?.stringValue, "gpt-history-default")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_idle_history","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490303,"completedAt":null,"durationMs":null}}}"#)

        let sent = await sendTask.value
        XCTAssertTrue(sent)
        XCTAssertFalse(
            conversationStore.messages(for: "thr_idle_history").contains {
                $0.content == L10n.text("ui.this_historical_conversation_has_been_continued")
            },
            "恢复提示是本地生命周期反馈，不能混入服务端 transcript"
        )
        XCTAssertEqual(store.statusMessage, L10n.text("ui.this_historical_conversation_has_been_continued"))
        let allRequests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(allRequests.filter { $0.method == "turn/start" }.count, 1)
    }

    func testStartTurnResumesThreadOnConnectionBeforeFirstTurnStart() async throws {
        // idle 历史 thread 会进入 runtime 的上下文缓存。若 startTurn 不先在当前 gateway 连接上
        // thread/resume，app-server 不会回推这个 thread 的 turn 事件。这里锁定修复：首次
        // turn/start 前必须补一次 thread/resume，且同一连接内不再重复 resume。
        let project = AgentProject(id: "proj_resume_guard", name: "Resume Guard", path: "/tmp/resume-guard")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        // thread/list 把 idle thread 灌进 contextsBySessionID，但不会把它登记成「已在本连接 resume」。
        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)
        let listMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let listRequest = try decodeAppServerRequest(listMessages[2])
        XCTAssertEqual(listRequest.method, "thread/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: listRequest.id)),"result":{"data":[{"id":"thr_idle_guard","sessionId":"thr_idle_guard","preview":"上次的会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resume-guard","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"上次的会话","turns":[]}],"nextCursor":null,"backwardsCursor":null}}"#)
        let page = try await pageTask.value
        XCTAssertEqual(page.sessions.map(\.id), ["thr_idle_guard"])
        XCTAssertFalse(try XCTUnwrap(page.sessions.first).isRunning, "idle 历史 thread 在列表语义上应保持 history，但 runtime startTurn 仍需要先 resume")

        // 第一次直连发送：startTurn 必须先 thread/resume，再 turn/start。
        let firstTurnTask = Task {
            try await runtime.startTurn(sessionID: "thr_idle_guard", prompt: "继续上次", clientMessageID: nil)
        }
        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resumeRequest = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resumeRequest.method, "thread/resume", "首次 turn/start 前应先在当前连接 resume thread")
        XCTAssertEqual(resumeRequest.params?["threadId"]?.stringValue, "thr_idle_guard")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resumeRequest.id)),"result":{"thread":{"id":"thr_idle_guard","sessionId":"thr_idle_guard","preview":"上次的会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490302,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resume-guard","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"上次的会话","turns":[]}}}"#)

        let firstTurnMessages = try await waitForFakeAppServerMessages(transport, count: 5)
        let firstTurnStart = try decodeAppServerRequest(firstTurnMessages[4])
        XCTAssertEqual(firstTurnStart.method, "turn/start")
        XCTAssertEqual(firstTurnStart.params?["threadId"]?.stringValue, "thr_idle_guard")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: firstTurnStart.id)),"result":{"turn":{"id":"turn_resume_guard","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490303,"completedAt":null,"durationMs":null}}}"#)
        let firstTurnID = try await firstTurnTask.value
        XCTAssertEqual(firstTurnID, "turn_resume_guard")

        let events = await runtime.attachEvents(sessionID: "thr_idle_guard")
        defer { events.cancel() }
        let firstTurnCompleted = expectation(description: "第一轮完成后允许启动下一轮")
        let eventTask = Task { @MainActor in
            for await event in events {
                guard case .turnCompleted(let metadata) = event,
                      metadata.turnID == "turn_resume_guard" else {
                    continue
                }
                firstTurnCompleted.fulfill()
                return
            }
        }
        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_idle_guard","turnId":"turn_resume_guard"}}"#)
        await fulfillment(of: [firstTurnCompleted], timeout: 2)
        eventTask.cancel()

        // 同一连接内第二次发送不应再 resume，只发 turn/start。
        let secondTurnTask = Task {
            try await runtime.startTurn(sessionID: "thr_idle_guard", prompt: "再来一次", clientMessageID: nil)
        }
        let secondTurnMessages = try await waitForFakeAppServerMessages(transport, count: 6)
        let secondTurnStart = try decodeAppServerRequest(secondTurnMessages[5])
        XCTAssertEqual(secondTurnStart.method, "turn/start", "已在本连接 resume 过的 thread 不应重复 resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: secondTurnStart.id)),"result":{"turn":{"id":"turn_resume_guard_2","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490304,"completedAt":null,"durationMs":null}}}"#)
        let secondTurnID = try await secondTurnTask.value
        XCTAssertEqual(secondTurnID, "turn_resume_guard_2")

        let allMessages = await transport.sentMessages()
        let resumeCount = allMessages.filter { (try? decodeAppServerRequest($0))?.method == "thread/resume" }.count
        XCTAssertEqual(resumeCount, 1, "同一连接内只应 resume 一次")
    }

    func testCodexAppServerSessionRuntimeRequiresProjectForThreadList() async throws {
        let project = AgentProject(id: "proj_direct_required", name: "Direct Required", path: "/tmp/direct-required")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "agent-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        do {
            _ = try await runtime.sessionsPage(projectID: nil, cursor: nil, limit: 20)
            XCTFail("direct thread/list 必须绑定 allowlist project")
        } catch CodexAppServerSessionRuntimeError.projectRequired {
            let sentMessages = await transport.sentMessages()
            XCTAssertTrue(sentMessages.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCodexAppServerProjectorMapsCommonNotifications() throws {
        var projector = CodexAppServerEventProjector()
        var startedCommandMessage: AgentMessage?
        var startedCommandMetadata: AgentEventMetadata?

        let started = try decodeAppServerNotification(#"{"method":"turn/started","params":{"threadId":"thr_demo","turn":{"id":"turn_demo"}}}"#)
        if case .turnStarted(let meta) = try XCTUnwrap(projector.project(started)) {
            XCTAssertEqual(meta.sessionID, "thr_demo")
            XCTAssertEqual(meta.turnID, "turn_demo")
        } else {
            XCTFail("Expected turnStarted")
        }

        let delta = try decodeAppServerNotification(#"{"method":"item/agentMessage/delta","params":{"threadId":"thr_demo","turnId":"turn_demo","itemId":"assistant_1","delta":"hello"}}"#)
        if case .assistantDelta(let payload, let meta) = try XCTUnwrap(projector.project(delta)) {
            XCTAssertEqual(payload.text, "hello")
            XCTAssertEqual(payload.role, .assistant)
            XCTAssertEqual(meta.messageID, "appserver:turn_demo:assistant_1")
        } else {
            XCTFail("Expected assistantDelta")
        }

        let commandStarted = try decodeAppServerNotification(#"{"method":"item/started","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"commandExecution","id":"cmd_1","command":"go test ./...","cwd":"/tmp/demo","status":"inProgress"}}}"#)
        if case .processItemCompleted(let message, let context, let meta) = try XCTUnwrap(projector.project(commandStarted)) {
            XCTAssertEqual(meta.sessionID, "thr_demo")
            XCTAssertEqual(message.id, "appserver:turn_demo:cmd_1")
            XCTAssertEqual(message.kind, .commandSummary)
            XCTAssertEqual(message.activityPayload?.status, "inProgress")
            XCTAssertEqual(message.activityPayload?.commandPresentationKind, .execution)
            XCTAssertEqual(context?.tasks.first?.kind, "command")
            XCTAssertEqual(context?.tasks.first?.title, "go test ./...")
            XCTAssertEqual(context?.tasks.first?.status, "inProgress")
            startedCommandMessage = message
            startedCommandMetadata = meta
        } else {
            XCTFail("Expected visible command process item at start")
        }

        let completed = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"agentMessage","id":"assistant_1","text":"hello world"}}}"#)
        if case .messageCompleted(let message, let meta) = try XCTUnwrap(projector.project(completed)) {
            XCTAssertEqual(message.id, "appserver:turn_demo:assistant_1")
            XCTAssertEqual(message.sessionID, "thr_demo")
            XCTAssertEqual(message.content, "hello world")
            XCTAssertEqual(message.role, .assistant)
            XCTAssertEqual(message.kind, .message)
            XCTAssertEqual(message.sendStatus, .confirmed)
            XCTAssertEqual(meta.itemID, "assistant_1")
        } else {
            XCTFail("Expected messageCompleted")
        }

        let commentary = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"agentMessage","id":"commentary_1","text":"我先检查上下文。","phase":"commentary"}}}"#)
        if case .messageCompleted(let message, _) = try XCTUnwrap(projector.project(commentary)) {
            XCTAssertEqual(message.role, .assistant)
            XCTAssertEqual(message.kind, .commentary)
            XCTAssertEqual(message.content, "我先检查上下文。")
        } else {
            XCTFail("Expected commentary messageCompleted")
        }

        let planCompleted = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"plan","id":"plan_1","text":"检查上下文并给出答案。"}}}"#)
        if case .processItemCompleted(let message, let context, _) = try XCTUnwrap(projector.project(planCompleted)) {
            XCTAssertEqual(message.id, "appserver:turn_demo:plan_1")
            XCTAssertEqual(message.role, .system)
            XCTAssertEqual(message.kind, .plan)
            XCTAssertEqual(message.content, "检查上下文并给出答案。")
            XCTAssertNil(context)
        } else {
            XCTFail("Expected plan processItemCompleted")
        }

        let commandCompleted = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"commandExecution","id":"cmd_1","command":"go test ./...","cwd":"/tmp/demo","status":"completed","commandActions":[{"type":"read","command":"sed -n '1,80p' README.md","name":"sed","path":"README.md"}],"aggregatedOutput":"ok","exitCode":0}}}"#)
        if case .processItemCompleted(let message, let context, let completedMetadata) = try XCTUnwrap(projector.project(commandCompleted)) {
            XCTAssertEqual(message.id, startedCommandMessage?.id, "started/completed 必须原位更新同一条时间线消息")
            XCTAssertEqual(message.role, .system)
            XCTAssertEqual(message.kind, .commandSummary)
            XCTAssertTrue(message.content.contains("命令：go test ./..."))
            XCTAssertTrue(message.content.contains("输出：\nok"))
            XCTAssertEqual(message.activityPayload?.category, .runCommand)
            XCTAssertEqual(message.activityPayload?.displayTitle, "查看 README.md")
            XCTAssertEqual(message.activityPayload?.commandPresentationKind, .exploration)
            XCTAssertEqual(message.activityPayload?.cwd, "/tmp/demo")
            XCTAssertEqual(message.activityPayload?.exitCode, 0)
            XCTAssertEqual(context?.tasks.first?.kind, "command")
            XCTAssertEqual(context?.tasks.first?.status, "completed")

            let store = ConversationStore()
            let startMessage = try XCTUnwrap(startedCommandMessage)
            let startMetadata = try XCTUnwrap(startedCommandMetadata)
            store.completeMessage(startMessage, metadata: startMetadata, fallbackSessionID: "thr_demo")
            let runningConversation = try XCTUnwrap(store.messages(for: "thr_demo").first)
            let runningUUID = runningConversation.id
            let runningBatchID = try XCTUnwrap(ConversationTimelineItemBuilder.items(from: [runningConversation]).first?.id)
            XCTAssertTrue(runningConversation.activityPayload?.isInProgress == true)

            store.completeMessage(message, metadata: completedMetadata, fallbackSessionID: "thr_demo")
            let completedConversation = try XCTUnwrap(store.messages(for: "thr_demo").first)
            XCTAssertEqual(completedConversation.id, runningUUID)
            XCTAssertEqual(ConversationTimelineItemBuilder.items(from: [completedConversation]).first?.id, runningBatchID)
            XCTAssertFalse(completedConversation.activityPayload?.isInProgress == true)
        } else {
            XCTFail("Expected command processItemCompleted")
        }

        let toolCompleted = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"dynamicToolCall","id":"tool_1","namespace":"browser","tool":"open","status":"completed"}}}"#)
        if case .processItemCompleted(let message, let context, _) = try XCTUnwrap(projector.project(toolCompleted)) {
            XCTAssertEqual(message.role, .system)
            XCTAssertEqual(message.kind, .commandSummary)
            XCTAssertEqual(
                message.content,
                L10n.format(
                    "ui.tool_value_status_value",
                    L10n.text("ui.open_web_page"),
                    L10n.text("ui.completed_status")
                )
            )
            XCTAssertEqual(message.activityPayload?.category, .toolCall)
            XCTAssertEqual(message.activityPayload?.displayTitle, L10n.text("ui.open_web_page"))
            XCTAssertEqual(context?.tasks.first?.kind, "dynamic_tool")
            XCTAssertEqual(context?.tasks.first?.title, L10n.text("ui.open_web_page"))
            XCTAssertEqual(context?.tasks.first?.status, "completed")
        } else {
            XCTFail("Expected tool completed processItemCompleted")
        }

        let log = try decodeAppServerNotification(#"{"method":"item/commandExecution/outputDelta","params":{"threadId":"thr_demo","turnId":"turn_demo","itemId":"cmd_1","delta":"go test output","stream":"stdout"}}"#)
        if case .logDelta(let payload, _) = try XCTUnwrap(projector.project(log)) {
            XCTAssertEqual(payload.text, "go test output")
            XCTAssertEqual(payload.stream, "stdout")
        } else {
            XCTFail("Expected logDelta")
        }

        let diff = try decodeAppServerNotification(#"{"method":"turn/diff/updated","params":{"threadId":"thr_demo","turnId":"turn_demo","path":"Sources/App.swift","status":"modified","additions":2,"deletions":1}}"#)
        if case .sessionContext(let context, let meta) = try XCTUnwrap(projector.project(diff)) {
            XCTAssertEqual(meta.sessionID, "thr_demo")
            XCTAssertEqual(context.tasks.first?.kind, "file_change")
            XCTAssertEqual(context.tasks.first?.subtitle, "Sources/App.swift")
            XCTAssertEqual(context.tasks.first?.status, "modified")
        } else {
            XCTFail("Expected file change sessionContext")
        }

        let turnCompleted = try decodeAppServerNotification(#"{"method":"turn/completed","params":{"threadId":"thr_demo","turnId":"turn_demo"}}"#)
        if case .turnCompleted(let meta) = try XCTUnwrap(projector.project(turnCompleted)) {
            XCTAssertEqual(meta.sessionID, "thr_demo")
            XCTAssertEqual(meta.turnID, "turn_demo")
        } else {
            XCTFail("Expected turnCompleted")
        }

        let requestResolved = try decodeAppServerNotification(#"{"method":"serverRequest/resolved","params":{"threadId":"thr_demo","requestId":99}}"#)
        if case .approvalResolved(let meta) = try XCTUnwrap(projector.project(requestResolved)) {
            XCTAssertEqual(meta.sessionID, "thr_demo")
            XCTAssertEqual(meta.itemID, "99")
        } else {
            XCTFail("Expected approvalResolved")
        }

        let warning = try decodeAppServerNotification(#"{"method":"warning","params":{"threadId":"thr_demo","message":"rate limit soon","code":"rate_limit"}}"#)
        if case .warning(let payload, let meta) = try XCTUnwrap(projector.project(warning)) {
            XCTAssertEqual(payload.message, "rate limit soon")
            XCTAssertEqual(payload.code, "rate_limit")
            XCTAssertEqual(meta.sessionID, "thr_demo")
        } else {
            XCTFail("Expected warning")
        }

        let error = try decodeAppServerNotification(#"{"method":"error","params":{"threadId":"thr_demo","turnId":"turn_demo","error":{"message":"Failed to authenticate","code":"claude_authentication_required"},"willRetry":false}}"#)
        if case .error(let payload, let meta) = try XCTUnwrap(projector.project(error)) {
            XCTAssertEqual(payload.message, "Failed to authenticate")
            XCTAssertEqual(payload.code, ClaudeAuthenticationRecovery.errorCode)
            XCTAssertEqual(payload.retryable, false)
            XCTAssertEqual(meta.sessionID, "thr_demo")
            XCTAssertEqual(meta.turnID, "turn_demo")
        } else {
            XCTFail("Expected error")
        }
    }

    func testAgentEventDecodesSessionContextAlternateKeys() throws {
        let event = try AgentAPIClient.decoder.decode(
            AgentEvent.self,
            from: Data("""
            {
              "type": "session_context",
              "meta": {"session_id": "codex_thr_parent"},
              "context": {
                "session_id": "codex_thr_parent",
                "thread_id": "thr_parent",
                "status": {"type": "active", "activeFlags": ["waitingOnApproval"]},
                "git": {"branch": "codex/status-sidebar", "originUrl": "https://example.test/repo.git"},
                "subagents": [
                  {"id": "thr_child", "parentThreadId": "thr_parent", "nickname": "Noether", "role": "review"}
                ]
              }
            }
            """.utf8)
        )

        guard case .sessionContext(let context, let metadata) = event else {
            return XCTFail("Expected sessionContext event")
        }
        XCTAssertEqual(metadata.sessionID, "codex_thr_parent")
        XCTAssertEqual(context.status?.activeFlags, ["waitingOnApproval"])
        XCTAssertEqual(context.git?.originURL, "https://example.test/repo.git")
        XCTAssertEqual(context.subagents.first?.parentThreadID, "thr_parent")
    }

    func testSessionContextStoreClearsPendingApprovalTasks() {
        let store = SessionContextStore()
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_approval_tasks",
                status: SessionContextStatus(type: "active", activeFlags: ["waitingOnApproval"]),
                tasks: [
                    SessionContextTask(id: "cmd_waiting", kind: "command", title: "Agent 请求执行命令：curl -I https://example.com", subtitle: "high", status: "waiting"),
                    SessionContextTask(id: "cmd_running", kind: "command", title: "go test ./...", subtitle: nil, status: "running")
                ]
            ),
            fallbackSessionID: nil
        )

        store.clearPendingApprovalTasks(sessionID: "thr_approval_tasks")

        let context = store.context(for: "thr_approval_tasks")
        XCTAssertEqual(context?.tasks.map(\.id), ["cmd_running"])
        XCTAssertEqual(context?.status?.activeFlags, ["waitingOnApproval"])
    }

    func testSessionContextStoreScopesSameSessionByProfile() {
        let store = SessionContextStore()
        let sessionID = "shared_session"

        store.activate(profileID: "mac-a")
        store.upsert(
            SessionContextSnapshot(
                sessionID: sessionID,
                environment: SessionContextEnvironment(
                    id: "local-a",
                    kind: "local",
                    label: "Mac A",
                    cwd: "/tmp/a",
                    provider: "openai"
                )
            ),
            fallbackSessionID: nil
        )

        store.activate(profileID: "mac-b")
        XCTAssertNil(store.context(for: sessionID))
        store.upsert(
            SessionContextSnapshot(
                sessionID: sessionID,
                environment: SessionContextEnvironment(
                    id: "local-b",
                    kind: "local",
                    label: "Mac B",
                    cwd: "/tmp/b",
                    provider: "openai"
                )
            ),
            fallbackSessionID: nil
        )
        XCTAssertEqual(store.context(for: sessionID)?.environment?.cwd, "/tmp/b")

        store.activate(profileID: "mac-a")
        XCTAssertEqual(store.context(for: sessionID)?.environment?.cwd, "/tmp/a")
    }

    func testCodexAppServerRequestBuildersUseRemoteSafeDefaults() throws {
        let project = AgentProject(id: "proj_safe", name: "Safe", path: "/tmp/safe-project")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        let threadStart = try builder.threadStart(projectID: project.id)
        XCTAssertEqual(threadStart.method, "thread/start")
        let threadParams = try XCTUnwrap(threadStart.params?.objectValue)
        XCTAssertEqual(threadParams["cwd"]?.stringValue, project.path)
        XCTAssertNil(threadParams["model"]?.stringValue)
        XCTAssertEqual(threadParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(threadParams["approvalsReviewer"]?.stringValue, "user")
        XCTAssertEqual(threadParams["sandbox"]?.stringValue, "danger-full-access")
        XCTAssertNil(threadParams["runtimeWorkspaceRoots"])

        let turnStart = try builder.turnStart(
            threadID: "thr_safe",
            projectID: project.id,
            prompt: "只回复 ok",
            clientMessageID: "client_safe"
        )
        XCTAssertEqual(turnStart.method, "turn/start")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["cwd"]?.stringValue, project.path)
        XCTAssertNil(turnParams["model"]?.stringValue)
        XCTAssertEqual(turnParams["effort"]?.stringValue, "xhigh")
        XCTAssertEqual(turnParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(turnParams["approvalsReviewer"]?.stringValue, "user")
        XCTAssertEqual(turnParams["clientUserMessageId"]?.stringValue, "client_safe")
        let sandbox = try XCTUnwrap(turnParams["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(sandbox["type"]?.stringValue, "dangerFullAccess")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
        XCTAssertNil(sandbox["writableRoots"])

        XCTAssertThrowsError(try builder.threadStart(cwd: "/tmp/not-allowlisted"))
        XCTAssertThrowsError(try builder.turnStart(threadID: "thr_safe", cwd: "/tmp/not-allowlisted", prompt: "hi"))
        XCTAssertThrowsError(try builder.validateRemoteSafeParams(
            .object(["cwd": .string(project.path), "approvalPolicy": .string("never")]),
            projectPath: project.path
        ))
        XCTAssertNoThrow(try builder.validateRemoteSafeParams(
            .object(["cwd": .string(project.path), "sandbox": .string("danger-full-access")]),
            projectPath: project.path
        ))
        XCTAssertEqual(builder.accountRateLimitsRead().method, "account/rateLimits/read")
        XCTAssertEqual(builder.accountUsageRead().method, "account/usage/read")
    }

    func testCodexUsageDisplaySummaryFormatsRateLimit() throws {
        XCTAssertEqual(RateLimitSummary(remainingRequests: 18).compactText, L10n.plural("ui.times_remaining_count", count: 18))
        XCTAssertEqual(RateLimitSummary(primaryUsedPercent: 72).compactText, L10n.format("ui.used_value", "72%"))
        XCTAssertEqual(RateLimitSummary(primaryUsedPercent: 100).compactText, L10n.text("ui.quota_has_been_exhausted"))
        XCTAssertNil(CodexUsageDisplaySummary.make(rateLimit: nil))
        XCTAssertNil(CodexUsageDisplaySummary.make(rateLimit: RateLimitSummary(limitID: "codex")))

        let now = Date(timeIntervalSince1970: 1_780_490_700)
        let resetEpoch: Int64 = 1_780_494_300
        let summary = RateLimitSummary(
            limitName: "Codex",
            primaryUsedPercent: 60,
            secondaryUsedPercent: 42,
            primaryResetsAt: resetEpoch,
            primaryWindowDurationMins: 300,
            secondaryWindowDurationMins: 10_080
        )
        let display = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: summary, now: now))
        XCTAssertEqual(display.title, L10n.text("ui.codex_usage"))
        XCTAssertEqual(display.primaryText, L10n.format("ui.used_value", "60%"))
        XCTAssertFalse(display.secondaryText.isEmpty)
        XCTAssertEqual(display.progress ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(display.resetDate, Date(timeIntervalSince1970: TimeInterval(resetEpoch)))
        XCTAssertFalse(display.isNearLimit)
        XCTAssertFalse(display.isExhausted)

        let windowsDisplay = CodexUsageWindowsDisplay.make(rateLimit: summary, now: now)
        let fiveHourWindow = try XCTUnwrap(windowsDisplay.windows.first { $0.kind == .primary })
        let sevenDayWindow = try XCTUnwrap(windowsDisplay.windows.first { $0.kind == .secondary })
        XCTAssertEqual(windowsDisplay.displayName, "Codex")
        XCTAssertEqual(windowsDisplay.creditText, L10n.text("ui.no_balance_information_yet"))
        XCTAssertTrue(windowsDisplay.hasLiveData)
        XCTAssertEqual(
            windowsDisplay.windowSummaryText,
            L10n.format("ui.value_account_window", ["5h", "7d"].joined(separator: L10n.text("ui.and")))
        )
        XCTAssertEqual(fiveHourWindow.label, "5h")
        XCTAssertEqual(fiveHourWindow.title, L10n.text("ui.short_window"))
        XCTAssertEqual(fiveHourWindow.primaryText, L10n.format("ui.used_value", "60%"))
        XCTAssertEqual(fiveHourWindow.progress ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(fiveHourWindow.remainingProgress ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(fiveHourWindow.remainingPercentText, "40%")
        XCTAssertEqual(fiveHourWindow.remainingText, L10n.format("ui.value_remaining", "40%"))
        XCTAssertEqual(fiveHourWindow.resetDate, Date(timeIntervalSince1970: TimeInterval(resetEpoch)))
        XCTAssertFalse(fiveHourWindow.resetText.isEmpty)
        XCTAssertEqual(sevenDayWindow.primaryText, L10n.format("ui.used_value", "42%"))
        XCTAssertEqual(sevenDayWindow.label, "7d")
        XCTAssertEqual(sevenDayWindow.title, L10n.text("ui.weekly_window"))
        XCTAssertEqual(sevenDayWindow.remainingProgress ?? -1, 0.58, accuracy: 0.0001)
        XCTAssertEqual(sevenDayWindow.remainingText, L10n.format("ui.value_remaining", "58%"))
        XCTAssertNil(sevenDayWindow.resetDate)
        XCTAssertEqual(sevenDayWindow.resetText, L10n.text("ui.no_reset_time_yet"))

        let pendingWindowsDisplay = CodexUsageWindowsDisplay.make(rateLimit: nil, now: now)
        XCTAssertFalse(pendingWindowsDisplay.hasLiveData)
        XCTAssertTrue(pendingWindowsDisplay.windows.isEmpty)
        XCTAssertEqual(pendingWindowsDisplay.windowSummaryText, L10n.text("ui.account_usage_has_not_been_obtained_yet"))

        let claudeWindowsDisplay = CodexUsageWindowsDisplay.make(
            rateLimit: RateLimitSummary(
                limitID: "claude",
                limitName: "Claude",
                primaryUsedPercent: 35,
                secondaryUsedPercent: 12,
                primaryWindowDurationMins: 300,
                secondaryWindowDurationMins: 10_080
            ),
            now: now,
            fallbackDisplayName: "Claude"
        )
        XCTAssertEqual(claudeWindowsDisplay.displayName, "Claude")
        XCTAssertEqual(claudeWindowsDisplay.windows.map(\.label), ["5h", "7d"])
        XCTAssertTrue(claudeWindowsDisplay.windows.allSatisfy { $0.accessibilityName.hasPrefix("Claude") })

        let unavailableClaude = CodexUsageWindowsDisplay.make(
            rateLimit: RateLimitSummary(
                limitID: "claude",
                limitName: "Claude",
                availability: "unavailable",
                unavailableReason: "headless_statusline_unavailable"
            ),
            now: now,
            fallbackDisplayName: "Claude"
        )
        XCTAssertEqual(unavailableClaude.creditText, L10n.text("ui.headless_no_quota_percentage_yet"))
        XCTAssertTrue(unavailableClaude.windows.isEmpty)

        let boundedWindows = CodexUsageWindowsDisplay.make(
            rateLimit: RateLimitSummary(primaryUsedPercent: -10, secondaryUsedPercent: 125),
            now: now
        )
        let boundedFiveHour = try XCTUnwrap(boundedWindows.windows.first { $0.kind == .primary })
        let boundedSevenDay = try XCTUnwrap(boundedWindows.windows.first { $0.kind == .secondary })
        XCTAssertEqual(boundedFiveHour.remainingProgress ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(boundedFiveHour.remainingText, L10n.format("ui.value_remaining", "100%"))
        XCTAssertEqual(boundedSevenDay.remainingProgress ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(boundedSevenDay.remainingText, L10n.format("ui.value_remaining", "0%"))

        let fractionalWindows = CodexUsageWindowsDisplay.make(
            rateLimit: RateLimitSummary(primaryUsedPercent: 10.5),
            now: now
        )
        let fractionalFiveHour = try XCTUnwrap(fractionalWindows.windows.first { $0.kind == .primary })
        XCTAssertEqual(fractionalFiveHour.remainingText, L10n.format("ui.value_remaining", "89.5%"))

        let weeklyOnly = CodexUsageWindowsDisplay.make(
            rateLimit: RateLimitSummary(
                primaryUsedPercent: 2,
                primaryResetsAt: resetEpoch,
                primaryWindowDurationMins: 10_080
            ),
            now: now
        )
        XCTAssertEqual(weeklyOnly.windows.count, 1)
        XCTAssertEqual(weeklyOnly.windows.first?.label, "7d")
        XCTAssertEqual(weeklyOnly.windows.first?.title, L10n.text("ui.weekly_window"))
        XCTAssertEqual(weeklyOnly.windowSummaryText, L10n.format("ui.value_account_window", "7d"))

        let customAndUnknown = CodexUsageWindowsDisplay.make(
            rateLimit: RateLimitSummary(
                primaryUsedPercent: 12,
                secondaryUsedPercent: 24,
                primaryWindowDurationMins: 90
            ),
            now: now
        )
        XCTAssertEqual(customAndUnknown.windows.map(\.label), ["90m", L10n.text("ui.window")])
        XCTAssertEqual(customAndUnknown.windows.map(\.title), [L10n.text("ui.account_window_title"), L10n.text("ui.account_window_title")])

        let eightyPercent = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: RateLimitSummary(primaryUsedPercent: 80), now: now))
        XCTAssertFalse(eightyPercent.isNearLimit)
        let almostNearLimit = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: RateLimitSummary(primaryUsedPercent: 84), now: now))
        XCTAssertFalse(almostNearLimit.isNearLimit)
        let nearLimit = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: RateLimitSummary(primaryUsedPercent: 85), now: now))
        XCTAssertTrue(nearLimit.isNearLimit)

        let exhaustedLimit = RateLimitSummary(limitName: "Codex", primaryUsedPercent: 100, primaryResetsAt: resetEpoch)
        let exhaustedDisplay = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: exhaustedLimit, now: now))
        XCTAssertTrue(exhaustedDisplay.isExhausted)
        let exhaustedNotice = try XCTUnwrap(CodexQuotaNotice.make(rateLimit: exhaustedLimit, errorMessage: nil, now: now))
        XCTAssertTrue(exhaustedNotice.blocksSending)
        XCTAssertEqual(exhaustedNotice.title, L10n.format("ui.value_message_quota_has_been_exhausted", "Codex"))

        let secondaryResetEpoch: Int64 = 1_780_497_900
        let secondaryDriven = try XCTUnwrap(CodexUsageDisplaySummary.make(
            rateLimit: RateLimitSummary(
                primaryUsedPercent: 40,
                secondaryUsedPercent: 90,
                primaryResetsAt: resetEpoch,
                secondaryResetsAt: secondaryResetEpoch
            ),
            now: now
        ))
        XCTAssertEqual(secondaryDriven.primaryText, "已用 90%")
        XCTAssertEqual(secondaryDriven.resetDate, Date(timeIntervalSince1970: TimeInterval(secondaryResetEpoch)))

        let secondaryWindows = CodexUsageWindowsDisplay.make(
            rateLimit: RateLimitSummary(
                reachedType: "secondary",
                primaryUsedPercent: 40,
                secondaryUsedPercent: 100,
                secondaryResetsAt: secondaryResetEpoch
            ),
            now: now
        )
        XCTAssertFalse(try XCTUnwrap(secondaryWindows.windows.first { $0.kind == .primary }).isExhausted)
        XCTAssertTrue(try XCTUnwrap(secondaryWindows.windows.first { $0.kind == .secondary }).isExhausted)
    }

    func testUsageRingMetricsAdaptToIPadMiniAndIPhone() {
        let iPadMini = CodexUsageRingMetrics(isCompact: false)
        XCTAssertEqual(iPadMini.diameter, 36)
        XCTAssertEqual(iPadMini.lineWidth, 3.2)
        XCTAssertEqual(iPadMini.ringSpacing, 1.8)
        XCTAssertEqual(iPadMini.hitSize, 44)

        let iPhone = CodexUsageRingMetrics(isCompact: true)
        XCTAssertEqual(iPhone.diameter, 32)
        XCTAssertEqual(iPhone.lineWidth, 3)
        XCTAssertEqual(iPhone.ringSpacing, 1.5)
        XCTAssertEqual(iPhone.hitSize, 44)

        let floatingSidebar = CodexUsageRingMetrics(
            isCompact: false,
            usesCondensedVisual: true
        )
        XCTAssertEqual(floatingSidebar.diameter, 30)
        XCTAssertEqual(floatingSidebar.lineWidth, 3)
        XCTAssertEqual(floatingSidebar.ringSpacing, 1.4)
        XCTAssertEqual(floatingSidebar.hitSize, 44)
    }

    func testPhotoLibraryPickerConfigurationSupportsOrderedMultipleSelection() {
        let configuration = PhotoLibraryPicker.makeConfiguration(selectionLimit: 8)
        XCTAssertEqual(configuration.selectionLimit, 8)
        XCTAssertEqual(configuration.selection, .ordered)

        let clampedConfiguration = PhotoLibraryPicker.makeConfiguration(selectionLimit: 0)
        XCTAssertEqual(clampedConfiguration.selectionLimit, 1)
    }

    func testDirectRuntimeAttachesUsageDisplayForAvailableRateLimit() async throws {
        let project = AgentProject(id: "proj_rate_limit_available", name: "Rate Limit", path: "/tmp/rate-limit-available")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/list",
            "thread/start",
            "thread/read",
            "turn/start",
            "turn/interrupt",
            "account/rateLimits/read"
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: threadList.id, result: #"{"data":[{"id":"thr_rate_limit_available","sessionId":"thr_rate_limit_available","preview":"quota","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/rate-limit-available","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"额度展示","turns":[]}],"nextCursor":null}"#)

        let page = try await pageTask.value
        let initialSession = try XCTUnwrap(page.sessions.first)
        XCTAssertNil(initialSession.rateLimit)

        let rateLimit = try await waitForFakeAppServerRequest(transport, method: "account/rateLimits/read")
        transportResponse(transport, id: rateLimit.id, result: #"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":"Codex","primary":{"usedPercent":60,"resetsAt":1780494300,"windowDurationMins":300},"secondary":{"usedPercent":42,"window_duration_mins":10080},"credits":{"hasCredits":false,"unlimited":false}}}}"#)

        let messagesBeforeSecondPage = await transport.sentMessages().count
        let secondPageTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let secondThreadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: messagesBeforeSecondPage)
        transportResponse(transport, id: secondThreadList.id, result: #"{"data":[{"id":"thr_rate_limit_available","sessionId":"thr_rate_limit_available","preview":"quota","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/rate-limit-available","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"额度展示","turns":[]}],"nextCursor":null}"#)

        let refreshedPage = try await secondPageTask.value
        let session = try XCTUnwrap(refreshedPage.sessions.first)
        XCTAssertEqual(session.rateLimit?.compactText, "已用 60%")
        XCTAssertEqual(session.rateLimit?.primaryWindowDurationMins, 300)
        XCTAssertEqual(session.rateLimit?.secondaryWindowDurationMins, 10_080)
        let display = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: session.rateLimit, now: Date(timeIntervalSince1970: 1_780_490_700)))
        XCTAssertEqual(display.primaryText, "已用 60%")
        XCTAssertEqual(display.progress ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertFalse(display.isExhausted)
    }

    func testDirectRuntimeAttachesAccountRateLimitToSessionRows() async throws {
        let project = AgentProject(id: "proj_rate_limit", name: "Rate Limit", path: "/tmp/rate-limit")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/list",
            "thread/start",
            "thread/read",
            "turn/start",
            "turn/interrupt",
            "account/rateLimits/read"
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: threadList.id, result: #"{"data":[{"id":"thr_rate_limit","sessionId":"thr_rate_limit","preview":"quota","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/rate-limit","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"额度提示","turns":[]}],"nextCursor":null}"#)

        let initialPage = try await pageTask.value
        XCTAssertNil(try XCTUnwrap(initialPage.sessions.first).rateLimit)

        let rateLimit = try await waitForFakeAppServerRequest(transport, method: "account/rateLimits/read")
        transportResponse(transport, id: rateLimit.id, result: #"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":"Codex","rateLimitReachedType":"primary","primary":{"usedPercent":100,"resetsAt":1780494300},"credits":{"hasCredits":false,"unlimited":false}}}}"#)

        let messagesBeforeSecondPage = await transport.sentMessages().count
        let secondPageTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let secondThreadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: messagesBeforeSecondPage)
        transportResponse(transport, id: secondThreadList.id, result: #"{"data":[{"id":"thr_rate_limit","sessionId":"thr_rate_limit","preview":"quota","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/rate-limit","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"额度提示","turns":[]}],"nextCursor":null}"#)

        let page = try await secondPageTask.value
        let session = try XCTUnwrap(page.sessions.first)
        XCTAssertEqual(session.rateLimit?.limitID, "codex")
        XCTAssertEqual(session.rateLimit?.limitName, "Codex")
        XCTAssertEqual(session.rateLimit?.primaryUsedPercent, 100)
        XCTAssertEqual(session.rateLimit?.primaryResetsAt, 1_780_494_300)
        XCTAssertTrue(try XCTUnwrap(session.rateLimit?.isExhausted))
        XCTAssertEqual(session.rateLimit?.compactText, L10n.text("ui.quota_has_been_exhausted"))
    }

    func testQuotaNoticeRecognizesQuotaButIgnoresSkillBudgetWarning() {
        XCTAssertTrue(CodexQuotaNotice.isQuotaError("Your Codex message limit has been exhausted."))
        XCTAssertTrue(CodexQuotaNotice.isQuotaError("You've hit your usage limit."))
        XCTAssertFalse(CodexQuotaNotice.isQuotaError("HTTP 429: rate limit exceeded"))
        XCTAssertFalse(CodexQuotaNotice.isQuotaError("Usage limit status is temporarily unavailable"))
        XCTAssertTrue(CodexQuotaNotice.isRateLimitError("HTTP 429: rate limit exceeded"))
        XCTAssertFalse(CodexQuotaNotice.isQuotaError("Skill descriptions were shortened to fit the 2% skills context budget."))
        XCTAssertFalse(CodexQuotaNotice.isRateLimitError("Skill descriptions were shortened to fit the 2% skills context budget."))
    }

    func testQuotaNoticeIgnoresExhaustedSnapshotAfterResetTime() {
        let now = Date(timeIntervalSince1970: 1_780_490_700)
        let staleLimit = RateLimitSummary(
            primaryUsedPercent: 100,
            primaryResetsAt: Int64(now.timeIntervalSince1970) - 1
        )

        XCTAssertNil(CodexQuotaNotice.make(rateLimit: staleLimit, errorMessage: nil, now: now))
    }
}
