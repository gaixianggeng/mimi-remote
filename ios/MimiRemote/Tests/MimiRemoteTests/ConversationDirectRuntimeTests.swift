import XCTest
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testDirectRuntimeCompactsUnobservedDeltaBacklogWithoutLosingText() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "buffer-test",
            transportFactory: { FakeCodexAppServerTransport() },
            configProvider: { throw MockError.unimplemented }
        )
        let sessionID = "thread-buffer-compaction"

        for index in 0..<1_000 {
            let metadata = AgentEventMetadata(
                seq: EventSequence(index + 1),
                sessionID: sessionID,
                turnID: "turn-buffer-compaction",
                itemID: "item-buffer-compaction",
                messageID: "message-buffer-compaction",
                clientMessageID: nil,
                revision: ModelRevision(index + 1),
                createdAt: nil
            )
            await runtime.emit(.assistantDelta(
                AgentDelta(text: "x", role: .assistant, kind: .message),
                metadata
            ))
        }

        let buffered = await runtime.bufferedEvents(sessionID: sessionID, replayPolicy: .all)
        let text = buffered.compactMap { event -> String? in
            guard case .assistantDelta(let delta, _) = event else { return nil }
            return delta.text
        }.joined()

        XCTAssertEqual(text, String(repeating: "x", count: 1_000))
        XCTAssertLessThan(buffered.count, 32)
    }

    func testDirectRuntimeCoalescesVisibleDeltasWhileConsumerIsSlow() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "visible-mailbox-test",
            transportFactory: { FakeCodexAppServerTransport() },
            configProvider: { throw MockError.unimplemented }
        )
        let sessionID = "thread-visible-mailbox"
        let turnID = "turn-visible-mailbox"
        let stream = await runtime.attachEvents(sessionID: sessionID)
        defer { stream.cancel() }

        // 先让生产者远快于消费者；同一 item 的 5,000 个增量应以对数级 chunk 暂存并一次完整交付。
        for index in 0..<5_000 {
            let metadata = AgentEventMetadata(
                seq: EventSequence(index + 1),
                sessionID: sessionID,
                turnID: turnID,
                itemID: "assistant-item",
                messageID: "assistant-message",
                clientMessageID: nil,
                revision: ModelRevision(index + 1),
                createdAt: nil
            )
            await runtime.emit(.assistantDelta(
                AgentDelta(text: "x", role: .assistant, kind: .message),
                metadata
            ))
        }

        // reasoning/plan 上游给的是累计快照，慢消费者只需要最新完整快照，不能把快照彼此拼接。
        for index in 1...1_000 {
            let metadata = AgentEventMetadata(
                seq: EventSequence(5_000 + index),
                sessionID: sessionID,
                turnID: turnID,
                itemID: "reasoning-item",
                messageID: "reasoning-message",
                clientMessageID: nil,
                revision: ModelRevision(5_000 + index),
                createdAt: nil
            )
            let message = AgentMessage(
                id: "reasoning-message",
                sessionID: sessionID,
                turnID: turnID,
                itemID: "reasoning-item",
                role: .system,
                kind: .reasoningSummary,
                content: String(repeating: "r", count: index),
                seq: metadata.seq,
                revision: metadata.revision ?? 0
            )
            await runtime.emit(.messageCompleted(message, metadata))
        }

        let completedMetadata = AgentEventMetadata(
            seq: 6_001,
            sessionID: sessionID,
            turnID: turnID,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: 6_001,
            createdAt: nil
        )
        await runtime.emit(.turnCompleted(completedMetadata))

        var iterator = stream.makeAsyncIterator()
        guard case .assistantDelta(let assistantDelta, _)? = await iterator.next() else {
            return XCTFail("第一项应为合并后的 assistant delta")
        }
        XCTAssertEqual(assistantDelta.text, String(repeating: "x", count: 5_000))

        guard case .messageCompleted(let reasoning, _)? = await iterator.next() else {
            return XCTFail("第二项应为最新 reasoning 快照")
        }
        XCTAssertEqual(reasoning.content, String(repeating: "r", count: 1_000))

        guard case .turnCompleted(let metadata)? = await iterator.next() else {
            return XCTFail("控制事件必须保留在文本事件之后")
        }
        XCTAssertEqual(metadata.seq, completedMetadata.seq)
    }

    func testDirectRuntimeMailboxPreservesControlEventBoundariesAndOrder() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "mailbox-order-test",
            transportFactory: { FakeCodexAppServerTransport() },
            configProvider: { throw MockError.unimplemented }
        )
        let sessionID = "thread-mailbox-order"
        let turnID = "turn-mailbox-order"
        let stream = await runtime.attachEvents(sessionID: sessionID)
        defer { stream.cancel() }
        let metadata: (Int, String?) -> AgentEventMetadata = { seq, itemID in
            AgentEventMetadata(
                seq: EventSequence(seq),
                sessionID: sessionID,
                turnID: turnID,
                itemID: itemID,
                messageID: itemID.map { "message-\($0)" },
                clientMessageID: nil,
                revision: ModelRevision(seq),
                createdAt: nil
            )
        }

        await runtime.emit(.turnStarted(metadata(1, nil)))
        await runtime.emit(.assistantDelta(AgentDelta(text: "A", role: .assistant, kind: .message), metadata(2, "assistant")))
        await runtime.emit(.assistantDelta(AgentDelta(text: "B", role: .assistant, kind: .message), metadata(3, "assistant")))
        await runtime.emit(.approvalRequest(
            AgentApprovalRequest(
                id: "approval",
                title: "需要确认",
                body: nil,
                kind: "command",
                risk: "high"
            ),
            metadata(4, "approval")
        ))
        await runtime.emit(.logDelta(LogDelta(text: "X", stream: "stdout"), metadata(5, "process")))
        await runtime.emit(.logDelta(LogDelta(text: "Y", stream: "stdout"), metadata(6, "process")))
        await runtime.emit(.error(
            AgentErrorPayload(message: "failed", code: "test", retryable: false),
            metadata(7, nil)
        ))
        await runtime.emit(.assistantDelta(AgentDelta(text: "C", role: .assistant, kind: .message), metadata(8, "assistant")))
        await runtime.emit(.assistantDelta(AgentDelta(text: "D", role: .assistant, kind: .message), metadata(9, "assistant")))
        await runtime.emit(.turnCompleted(metadata(10, nil)))

        var iterator = stream.makeAsyncIterator()
        var events: [AgentEvent] = []
        for _ in 0..<7 {
            guard let event = await iterator.next() else {
                return XCTFail("控制事件或其边界被意外丢失")
            }
            events.append(event)
        }

        guard case .turnStarted = events[0],
              case .assistantDelta(let firstDelta, _) = events[1],
              case .approvalRequest = events[2],
              case .logDelta(let logDelta, _) = events[3],
              case .error = events[4],
              case .assistantDelta(let secondDelta, _) = events[5],
              case .turnCompleted = events[6]
        else {
            return XCTFail("邮箱改变了控制事件顺序")
        }
        XCTAssertEqual(firstDelta.text, "AB")
        XCTAssertEqual(logDelta.text, "XY")
        XCTAssertEqual(secondDelta.text, "CD")
    }

    func testDirectRuntimeThreadSearchParsesSnippetAndCursors() async throws {
        let project = AgentProject(id: "proj_search_runtime", name: "Search Runtime", path: "/tmp/search-runtime")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/search"]
                )
            }
        )

        let searchTask = Task {
            try await runtime.searchSessions(query: "  历史正文  ", cursor: "cursor-in", limit: 25)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let request = try await waitForFakeAppServerRequest(transport, method: "thread/search", after: 1)
        let params = try XCTUnwrap(request.params?.objectValue)
        XCTAssertEqual(params["searchTerm"]?.stringValue, "历史正文")
        XCTAssertEqual(params["cursor"]?.stringValue, "cursor-in")
        XCTAssertEqual(params["limit"]?.intValue, 25)
        XCTAssertNil(params["cwd"])

        let authorizedManagedWorktree = appServerThreadJSON(
            id: "thr_search_runtime",
            cwd: "/tmp/authorized-managed-worktree",
            source: "cli",
            updatedAt: 1_780_491_100
        )
        transportResponse(
            transport,
            id: request.id,
            result: #"{"data":[{"thread":\#(authorizedManagedWorktree),"snippet":"命中的历史正文片段"}],"nextCursor":"cursor-next","backwardsCursor":"cursor-back"}"#
        )

        let page = try await searchTask.value
        let result = try XCTUnwrap(page.results.first)
        XCTAssertEqual(page.nextCursor, "cursor-next")
        XCTAssertEqual(page.backwardsCursor, "cursor-back")
        XCTAssertEqual(result.session.id, "thr_search_runtime")
        XCTAssertEqual(result.session.dir, "/tmp/authorized-managed-worktree")
        XCTAssertEqual(result.session.preview, "thr_search_runtime", "搜索 snippet 不能覆盖 canonical preview")
        XCTAssertEqual(result.snippet, "命中的历史正文片段")
    }

    func testCodexAppServerConnectionMatchesResponsesByRequestID() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        let connectTask = Task {
            try await connection.connect(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:7777/api/app-server/ws")), token: "test-token")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)
        try await connectTask.value

        let connectedMessages = try await waitForFakeAppServerMessages(transport, count: 2)
        let initialized = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(connectedMessages[1].utf8)
        )
        XCTAssertEqual(initialized.method, "initialized")

        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [
            AgentProject(id: "proj_rpc", name: "RPC", path: "/tmp/rpc")
        ])
        let listTask = Task {
            try await connection.send(try builder.threadList(cwd: "/tmp/rpc", limit: 1))
        }
        let readTask = Task {
            try await connection.send(builder.threadRead(threadID: "thr_out_of_order"))
        }

        let sentMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let requests = try sentMessages.dropFirst(2).map(decodeAppServerRequest)
        let listRequest = try XCTUnwrap(requests.first { $0.method == "thread/list" })
        let readRequest = try XCTUnwrap(requests.first { $0.method == "thread/read" })

        transport.enqueue(#"{"id":\#(try jsonFragment(for: readRequest.id)),"result":{"name":"read-first"}}"#)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: listRequest.id)),"result":{"name":"list-second"}}"#)

        let listResult = try await listTask.value?.objectValue
        let readResult = try await readTask.value?.objectValue
        XCTAssertEqual(listResult?["name"]?.stringValue, "list-second")
        XCTAssertEqual(readResult?["name"]?.stringValue, "read-first")

        await connection.disconnect()
    }

    func testCandidatePrepareCancellationClosesInitializingConnectionImmediately() async throws {
        let project = AgentProject(
            id: "proj_cancel_candidate",
            name: "Cancel Candidate",
            path: "/tmp/cancel-candidate"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "candidate-token",
            transportFactory: { transport },
            requestTimeout: 30,
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let prepareTask = Task {
            try await runtime.prepareForHostActivation()
        }

        // 保持 initialize 不响应，精确覆盖过去会一直挂到 requestTimeout 的窗口。
        _ = try await waitForFakeAppServerRequest(transport, method: "initialize")
        let cancelled = expectation(description: "候选连接取消后立即退出 initialize")
        Task {
            if case .success = await prepareTask.result {
                XCTFail("已取消的候选连接不应完成激活")
            }
            cancelled.fulfill()
        }

        prepareTask.cancel()
        await fulfillment(of: [cancelled], timeout: 1)

        let closeCallCount = await transport.closeCallCount()
        let hasReadyConnection = await runtime.hasReadyConnectionForTesting()
        XCTAssertGreaterThanOrEqual(closeCallCount, 1)
        XCTAssertFalse(hasReadyConnection)
    }

    func testCodexAppServerCapabilitiesOnlyForceReloadsForExplicitRefresh() async throws {
        let project = AgentProject(id: "proj_capability_reload", name: "Capabilities", path: "/tmp/capability-reload")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let automaticTask = Task {
            try await runtime.capabilities(path: project.path)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let automaticSkills = try await waitForFakeAppServerRequest(transport, method: "skills/list", after: 1)
        XCTAssertEqual(automaticSkills.params?["forceReload"]?.boolValue, false)
        transportResponse(transport, id: automaticSkills.id, result: #"{"data":[]}"#)
        let automaticPlugins = try await waitForFakeAppServerRequest(transport, method: "plugin/installed", after: 3)
        transportResponse(transport, id: automaticPlugins.id, result: #"{"plugins":[]}"#)
        _ = try await automaticTask.value

        let manualTask = Task {
            try await runtime.capabilities(path: project.path, forceReload: true)
        }
        let manualSkills = try await waitForFakeAppServerRequest(transport, method: "skills/list", after: 4)
        XCTAssertEqual(manualSkills.params?["forceReload"]?.boolValue, true)
        transportResponse(transport, id: manualSkills.id, result: #"{"data":[]}"#)
        let manualPlugins = try await waitForFakeAppServerRequest(transport, method: "plugin/installed", after: 5)
        transportResponse(transport, id: manualPlugins.id, result: #"{"plugins":[]}"#)
        _ = try await manualTask.value
    }

    func testCodexAppServerConnectionRoutesNotificationsAndServerRequests() async throws {
        let connection = CodexAppServerConnection(transport: FakeCodexAppServerTransport(), requestTimeout: 2)
        let notificationStream = await connection.notifications()
        let serverRequestStream = await connection.serverRequests()
        var notificationIterator = notificationStream.makeAsyncIterator()
        var serverRequestIterator = serverRequestStream.makeAsyncIterator()

        await connection.ingestTextForTesting(#"{"method":"turn/started","params":{"threadId":"thr_stream","turn":{"id":"turn_stream"}}}"#)
        let notification = await notificationIterator.next()
        XCTAssertEqual(notification?.method, "turn/started")
        XCTAssertEqual(notification?.params?["threadId"]?.stringValue, "thr_stream")

        await connection.ingestTextForTesting(#"{"id":99,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_stream","turnId":"turn_stream","itemId":"cmd_1","command":"go test ./..."}}"#)
        let request = await serverRequestIterator.next()
        XCTAssertEqual(request?.id, .int(99))
        XCTAssertEqual(request?.method, "item/commandExecution/requestApproval")
        XCTAssertEqual(request?.params?["command"]?.stringValue, "go test ./...")
    }

    func testCodexAppServerConnectionRoutesRejectedReverseResponseAsPrivateNotification() async {
        let connection = CodexAppServerConnection(
            transport: FakeCodexAppServerTransport(),
            requestTimeout: 2
        )
        let notificationStream = await connection.notifications()
        var iterator = notificationStream.makeAsyncIterator()

        await connection.ingestTextForTesting(
            #"{"id":"approval-rpc","error":{"code":-32600,"message":"Desktop 正在运行此会话","data":{"reason":"external_thread_active","accepted":false,"retryable":true,"response_to_server_request":true,"thread_id":"thr_reverse"}}}"#
        )

        let notification = await iterator.next()
        XCTAssertEqual(notification?.method, "_mimi/serverRequestResponse/rejected")
        XCTAssertEqual(notification?.params?["requestId"]?.stringValue, "approval-rpc")
        XCTAssertEqual(notification?.params?["reason"]?.stringValue, "external_thread_active")
        XCTAssertEqual(notification?.params?["thread_id"]?.stringValue, "thr_reverse")
    }

    func testDirectRuntimeRestoresApprovalCardAfterGatewayRejectsReverseResponse() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "reverse-response-rejection"
        )
        let request = CodexAppServerServerRequest(
            id: .string("approval-rpc"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "conversation_id": .string("thr_reverse"),
                "turnId": .string("turn_reverse"),
                "itemId": .string("cmd_reverse"),
                "command": .string("go test ./...")
            ])
        )
        await runtime.handle(request)
        _ = await runtime.bufferedEvents(sessionID: "thr_reverse", replayPolicy: .all)

        await runtime.handle(CodexAppServerNotification(
            method: "_mimi/serverRequestResponse/rejected",
            params: .object([
                "requestId": .string("approval-rpc"),
                "reason": .string("external_thread_active"),
                "message": .string("Desktop 正在运行此会话")
            ])
        ))

        let events = await runtime.bufferedEvents(sessionID: "thr_reverse", replayPolicy: .all)
        XCTAssertTrue(events.contains {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_reverse"
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .approvalRequest(let approval, let metadata) = $0 {
                return approval.id == "cmd_reverse" && metadata.sessionID == "thr_reverse"
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .warning(let warning, let metadata) = $0 {
                return warning.code == "external_thread_active"
                    && metadata.sessionID == "thr_reverse"
            }
            return false
        })
        let pending = await runtime.pendingInteractionEvents(sessionID: "thr_reverse")
        XCTAssertTrue(pending.contains {
            if case .approvalRequest(let approval, _) = $0 {
                return approval.id == "cmd_reverse"
            }
            return false
        })
    }

    func testCodexAppServerConnectionBuffersInboundStreamsWithoutDroppingOldEvents() async throws {
        let connection = CodexAppServerConnection(transport: FakeCodexAppServerTransport(), requestTimeout: 2)
        let notificationStream = await connection.notifications()
        let serverRequestStream = await connection.serverRequests()

        for index in 0..<700 {
            await connection.ingestTextForTesting(#"{"method":"turn/probe","params":{"index":\#(index)}}"#)
        }
        for index in 0..<180 {
            await connection.ingestTextForTesting(#"{"id":\#(index + 1),"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_buffer","turnId":"turn_buffer","itemId":"cmd_\#(index)","index":\#(index)}}"#)
        }

        let notificationValuesTask = Task {
            var iterator = notificationStream.makeAsyncIterator()
            var values: [Int] = []
            for _ in 0..<700 {
                guard let item = await iterator.next() else {
                    break
                }
                values.append(item.params?["index"]?.intValue ?? -1)
            }
            return values
        }
        let requestValuesTask = Task {
            var iterator = serverRequestStream.makeAsyncIterator()
            var values: [Int] = []
            for _ in 0..<180 {
                guard let item = await iterator.next() else {
                    break
                }
                values.append(item.params?["index"]?.intValue ?? -1)
            }
            return values
        }

        let notificationValues = try await valuesOrTimeout(notificationValuesTask, expectedCount: 700)
        let requestValues = try await valuesOrTimeout(requestValuesTask, expectedCount: 180)

        XCTAssertEqual(notificationValues.count, 700)
        XCTAssertEqual(notificationValues.first, 0)
        XCTAssertEqual(notificationValues.last, 699)
        XCTAssertEqual(requestValues.count, 180)
        XCTAssertEqual(requestValues.first, 0)
        XCTAssertEqual(requestValues.last, 179)
    }

    func testCodexAppServerConnectionMapsAppServerErrors() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        try await connectFakeAppServer(connection, transport: transport)

        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [
            AgentProject(id: "proj_error", name: "Error", path: "/tmp/error")
        ])
        let requestTask = Task {
            try await connection.send(try builder.threadList(cwd: "/tmp/error", limit: 1))
        }

        let sentMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let request = try decodeAppServerRequest(sentMessages[2])
        XCTAssertEqual(request.method, "thread/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: request.id)),"error":{"code":-32000,"message":"Not initialized"}}"#)

        do {
            _ = try await requestTask.value
            XCTFail("Expected app-server error")
        } catch CodexAppServerConnectionError.appServer(let error) {
            XCTAssertEqual(error.code, -32000)
            XCTAssertEqual(error.message, "Not initialized")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await connection.disconnect()
    }

    func testCodexAppServerConnectionSkipsMalformedFrameWithoutFailingPendingRequests() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        try await connectFakeAppServer(connection, transport: transport)

        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [
            AgentProject(id: "proj_bad_frame", name: "Bad Frame", path: "/tmp/bad-frame")
        ])
        let requestTask = Task {
            try await connection.send(try builder.threadList(cwd: "/tmp/bad-frame", limit: 1))
        }

        let sentMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let request = try decodeAppServerRequest(sentMessages[2])
        XCTAssertEqual(request.method, "thread/list")

        transport.enqueue(#"{"id": "#)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: request.id)),"result":{"name":"still-ok"}}"#)

        let result = try await requestTask.value?.objectValue
        XCTAssertEqual(result?["name"]?.stringValue, "still-ok")

        await connection.disconnect()
    }

    func testCodexAppServerFakeSmokeCoversThreadTurnAndApproval() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        let notificationStream = await connection.notifications()
        let serverRequestStream = await connection.serverRequests()
        var notificationIterator = notificationStream.makeAsyncIterator()
        var serverRequestIterator = serverRequestStream.makeAsyncIterator()
        var projector = CodexAppServerEventProjector()

        try await connectFakeAppServer(connection, transport: transport)

        let project = AgentProject(id: "proj_smoke", name: "Smoke", path: "/tmp/smoke")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        let threadTask = Task {
            try await connection.send(builder.threadStart(projectID: project.id))
        }

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thread-smoke","title":"Smoke"}}}"#)
        _ = try await threadTask.value

        transport.enqueue(#"{"method":"thread/started","params":{"thread":{"id":"thread-smoke","title":"Smoke","cwd":"/tmp/smoke"}}}"#)
        let threadStarted = await notificationIterator.next()
        XCTAssertEqual(threadStarted?.method, "thread/started")
        XCTAssertEqual(threadStarted?.params?["thread"]?.objectValue?["id"]?.stringValue, "thread-smoke")

        let turnTask = Task {
            try await connection.send(builder.turnStart(
                threadID: "thread-smoke",
                projectID: project.id,
                prompt: "帮我验收",
                clientMessageID: "client-smoke"
            ))
        }

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let turnStart = try decodeAppServerRequest(turnMessages[3])
        XCTAssertEqual(turnStart.method, "turn/start")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thread-smoke")
        XCTAssertEqual(turnParams["approvalPolicy"]?.stringValue, "on-request")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn-smoke","status":"inProgress"}}}"#)
        _ = try await turnTask.value

        transport.enqueue(#"{"method":"turn/started","params":{"threadId":"thread-smoke","turn":{"id":"turn-smoke"}}}"#)
        let nextNotification = await notificationIterator.next()
        let turnStarted = try XCTUnwrap(nextNotification)
        if case .turnStarted(let meta) = try XCTUnwrap(projector.project(turnStarted)) {
            XCTAssertEqual(meta.sessionID, "thread-smoke")
            XCTAssertEqual(meta.turnID, "turn-smoke")
        } else {
            XCTFail("Expected turnStarted")
        }

        transport.enqueue(#"{"id":77,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-smoke","turnId":"turn-smoke","itemId":"cmd-smoke","command":"go test ./...","reason":"验收直连链路"}}"#)
        let nextServerRequest = await serverRequestIterator.next()
        let approvalRequest = try XCTUnwrap(nextServerRequest)
        if case .approvalRequest(let approval, let meta) = try XCTUnwrap(projector.project(approvalRequest)) {
            XCTAssertEqual(meta.sessionID, "thread-smoke")
            XCTAssertEqual(approval.id, "cmd-smoke")
            XCTAssertEqual(approval.kind, "command")
            XCTAssertTrue(approval.body?.contains("验收直连链路") == true)
        } else {
            XCTFail("Expected approvalRequest")
        }

        await connection.disconnect()
    }

    func testCodexAppServerSessionRuntimeDrivesDirectClientAndSocket() async throws {
        let project = AgentProject(id: "proj_direct", name: "Direct", path: "/tmp/direct")
        let config = CodexAppServerConfigResponse(
            gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws",
            runtime: CodexAppServerRuntimeMetadata(
                type: "codex_app_server",
                transport: "ws",
                managed: true,
                gatewayAvailable: true,
                upstreamConfigured: true,
                running: true,
                initialized: false,
                pendingRequests: 0
            ),
            projects: [project],
            policy: CodexAppServerPolicyMetadata(
                allowedMethods: ["initialize", "initialized", "thread/start", "turn/start"],
                projectsSource: "agentd_allowlist"
            )
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { config }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "帮我验收",
                resumeID: "",
                clientMessageID: "client_direct_1"
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_direct","sessionId":"thr_direct","preview":"帮我验收","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"直连验收","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let firstTurnStart = try decodeAppServerRequest(turnMessages[3])
        XCTAssertEqual(firstTurnStart.method, "turn/start")
        let firstTurnParams = try XCTUnwrap(firstTurnStart.params?.objectValue)
        XCTAssertEqual(firstTurnParams["threadId"]?.stringValue, "thr_direct")
        XCTAssertEqual(firstTurnParams["cwd"]?.stringValue, project.path)
        XCTAssertEqual(firstTurnParams["clientUserMessageId"]?.stringValue, "client_direct_1")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: firstTurnStart.id)),"result":{"turn":{"id":"turn_direct_1","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490002,"completedAt":null,"durationMs":null}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_direct")
        XCTAssertEqual(created.session.status, "running")
        XCTAssertEqual(created.session.activeTurnID, "turn_direct_1")
        let createdContext = try XCTUnwrap(created.session.context)
        XCTAssertEqual(createdContext.status?.type, "active")
        XCTAssertEqual(createdContext.environment?.cwd, project.path)
        XCTAssertEqual(createdContext.environment?.provider, "openai")
        XCTAssertTrue(createdContext.sources.contains { $0.label == "appServer" })
        XCTAssertEqual(try CodexAppServerSessionRuntime.gatewayURL(endpoint: "http://127.0.0.1:8787", sessionID: "thr_direct").path, "/api/app-server/ws")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_direct")

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        transport.enqueue(#"{"method":"item/agentMessage/delta","params":{"threadId":"thr_direct","turnId":"turn_direct_1","itemId":"assistant_1","delta":"收到"}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .assistantDelta(let delta, _) = $0 {
                return delta.text == "收到"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .assistantDelta(let delta, _) = $0 {
                return delta.text == "收到"
            }
            return false
        })

        // 下一条用户输入只能在上一轮明确完成后启动，避免制造第二个并发 turn。
        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_direct","turnId":"turn_direct_1"}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .turnCompleted(let metadata) = $0 {
                return metadata.turnID == "turn_direct_1"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .turnCompleted(let metadata) = $0 {
                return metadata.turnID == "turn_direct_1"
            }
            return false
        })

        XCTAssertTrue(socket.sendInput("继续\r", clientMessageID: "client_direct_2"))
        let followUpTurnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: 4)
        XCTAssertEqual(followUpTurnStart.method, "turn/start")
        let followUpParams = try XCTUnwrap(followUpTurnStart.params?.objectValue)
        XCTAssertEqual(followUpParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "继续")
        XCTAssertEqual(followUpParams["clientUserMessageId"]?.stringValue, "client_direct_2")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: followUpTurnStart.id)),"result":{"turn":{"id":"turn_direct_2","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490003,"completedAt":null,"durationMs":null}}}"#)

        transport.enqueue(#"{"id":99,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_direct","turnId":"turn_direct_2","itemId":"cmd_direct","command":"go test ./..."}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .approvalRequest(let approval, _) = $0 {
                return approval.id == "cmd_direct"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(socket.sendApprovalDecision(approvalID: "cmd_direct", decision: "accept", message: nil))
        let approvalResponse = try await waitForFakeAppServerResponse(transport, id: .int(99))
        XCTAssertEqual(approvalResponse.id, .int(99))
        XCTAssertEqual(approvalResponse.result?["decision"]?.stringValue, "accept")

        transport.enqueue(#"{"id":100,"method":"item/permissions/requestApproval","params":{"threadId":"thr_direct","turnId":"turn_direct_2","itemId":"perm_direct","permissions":{"fileSystem":{"entries":[{"access":"read","path":{"type":"path","path":"/tmp/report.txt"}}]},"network":{"enabled":true}}}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .approvalRequest(let approval, _) = $0 {
                return approval.id == "perm_direct"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(socket.sendApprovalDecision(approvalID: "perm_direct", decision: "accept", message: nil))
        let permissionsResponse = try await waitForFakeAppServerResponse(transport, id: .int(100))
        XCTAssertEqual(permissionsResponse.id, .int(100))
        let grantedPermissions = try XCTUnwrap(permissionsResponse.result?["permissions"]?.objectValue)
        XCTAssertEqual(
            grantedPermissions["fileSystem"]?.objectValue?["entries"]?.arrayValue?.first?
                .objectValue?["path"]?.objectValue?["path"]?.stringValue,
            "/tmp/report.txt"
        )
        XCTAssertEqual(grantedPermissions["network"]?.objectValue?["enabled"]?.boolValue, true)
        XCTAssertEqual(permissionsResponse.result?["scope"]?.stringValue, "turn")
        XCTAssertEqual(permissionsResponse.result?["strictAutoReview"]?.boolValue, true)
        XCTAssertNil(permissionsResponse.result?["decision"])

        socket.disconnect()
    }

    func testRuntimeCreateSessionKeepsModelOnTurnOnly() async throws {
        let project = AgentProject(id: "proj_thread_model_guard", name: "Thread Model Guard", path: "/tmp/thread-model-guard")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        var options = CodexAppServerTurnOptions.default
        options.model = "gpt-selected"
        options.modelProvider = "openai"

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "模型只属于 turn",
                input: [.text("模型只属于 turn")],
                turnOptions: options,
                resumeID: "",
                clientMessageID: "client_thread_model_guard"
            ))
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let threadStart = try await waitForFakeAppServerRequest(transport, method: "thread/start", after: 1)
        let threadParams = try XCTUnwrap(threadStart.params?.objectValue)
        XCTAssertNil(threadParams["model"], "thread/start 不应携带 model，避免回归旧 app-server 校验问题")
        XCTAssertNil(threadParams["modelProvider"])
        transportResponse(transport, id: threadStart.id, result: #"{"thread":{"id":"thr_thread_model_guard","sessionId":"thr_thread_model_guard","preview":"模型只属于 turn","ephemeral":false,"createdAt":1780491000,"updatedAt":1780491001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/thread-model-guard","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"模型只属于 turn","turns":[]}}"#)

        let turnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: 3)
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["model"]?.stringValue, "gpt-selected")
        XCTAssertNil(turnParams["modelProvider"])
        transportResponse(transport, id: turnStart.id, result: #"{"turn":{"id":"turn_thread_model_guard","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780491002,"completedAt":null,"durationMs":null}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_thread_model_guard")
        XCTAssertEqual(created.session.activeTurnID, "turn_thread_model_guard")
    }

    func testDirectRuntimeBackfillsActiveTurnFromDeltaBeforeGuidance() async throws {
        let project = AgentProject(id: "proj_delta_guidance", name: "Delta Guidance", path: "/tmp/delta-guidance")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let listTask = Task {
            try await client.sessions(projectID: project.id, cursor: nil, limit: nil)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: threadList.id, result: #"{"data":[{"id":"thr_delta_guidance","sessionId":"thr_delta_guidance","preview":"delta 回填","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"idle"},"path":null,"cwd":"/tmp/delta-guidance","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"delta 回填","turns":[]}],"nextCursor":null}"#)
        _ = try await listTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        var sendOutcome: TurnSendOutcome?
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.onTurnSendOutcome = { _, outcome in sendOutcome = outcome }
        socket.connect(sessionID: "thr_delta_guidance")

        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        transportResponse(transport, id: resume.id, result: #"{"thread":{"id":"thr_delta_guidance","sessionId":"thr_delta_guidance","preview":"delta 回填","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490902,"status":{"type":"idle"},"path":null,"cwd":"/tmp/delta-guidance","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"delta 回填","turns":[]}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        // 模拟重连后漏掉 turn/started，但先收到带 turnId 的流式输出。
        // UI reducer 已经会开放“引导当前回复”，runtime 自己的 context 也必须同步回填，否则 steerTurn 会误拒发。
        transport.enqueue(#"{"method":"item/agentMessage/delta","params":{"threadId":"thr_delta_guidance","turnId":"turn_delta_guidance","itemId":"assistant_delta_guidance","delta":"正在继续"}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .assistantDelta(let delta, _) = $0 {
                return delta.text == "正在继续"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .assistantDelta(let delta, _) = $0 {
                return delta.text == "正在继续"
            }
            return false
        })

        XCTAssertTrue(socket.sendGuidance(
            CodexAppServerTurnPayload(prompt: "沿着当前回复继续"),
            clientMessageID: "client_delta_guidance",
            expectedTurnID: "turn_delta_guidance"
        ))
        let steer = try await waitForFakeAppServerRequest(transport, method: "turn/steer", after: 4)
        let steerParams = try XCTUnwrap(steer.params?.objectValue)
        XCTAssertEqual(steerParams["threadId"]?.stringValue, "thr_delta_guidance")
        XCTAssertEqual(steerParams["expectedTurnId"]?.stringValue, "turn_delta_guidance")
        XCTAssertEqual(steerParams["clientUserMessageId"]?.stringValue, "client_delta_guidance")
        XCTAssertEqual(steerParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "沿着当前回复继续")
        transportResponse(transport, id: steer.id, result: #"{}"#)
        for _ in 0..<200 where sendOutcome == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(sendOutcome, .guidanceAccepted)

        socket.disconnect()
    }

    func testDirectRuntimeRetriesModelListAfterStaleInitializationError() async throws {
        let project = AgentProject(id: "proj_stale_model", name: "Stale Model", path: "/tmp/stale-model")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let modelsTask = Task {
            try await runtime.modelOptions()
        }

        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let firstInitializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let firstInitialize = try decodeAppServerRequest(firstInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(firstInitialize)
        transportResponse(firstTransport, id: firstInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let staleModelList = try await waitForFakeAppServerRequest(firstTransport, method: "model/list", after: 1)
        // 旧 gateway/upstream 状态会把已初始化连接误判为未初始化；客户端应重连并重试一次。
        transportErrorResponse(firstTransport, id: staleModelList.id, code: -32600, message: "Not initialized")

        let secondTransport = try await waitForFakeAppServerTransport(in: pool, index: 1)
        let secondInitializeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 1)
        let secondInitialize = try decodeAppServerRequest(secondInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(secondInitialize)
        transportResponse(secondTransport, id: secondInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let retryModelList = try await waitForFakeAppServerRequest(secondTransport, method: "model/list", after: 1)
        transportResponse(secondTransport, id: retryModelList.id, result: #"{"models":[{"id":"gpt-stale-default","title":"Stale Default","provider":"openai","isDefault":true},{"id":"gpt-side"}]}"#)

        let options = try await modelsTask.value
        XCTAssertEqual(options.first?.model, "gpt-stale-default")
        XCTAssertEqual(options.first?.provider, "openai")
        XCTAssertEqual(options.first?.isDefault, true)
    }

    func testMultiRuntimeModelOptionsKeepCodexWhenClaudeFails() async throws {
        let project = AgentProject(id: "proj_multi_models", name: "Multi Models", path: "/tmp/multi-models")
        let config = makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata()])
        let codexTransport = FakeCodexAppServerTransport()
        let claudeTransport = FakeCodexAppServerTransport()
        let codex = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "codex",
            transportFactory: { codexTransport },
            configProvider: { config }
        )
        let claude = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { claudeTransport },
            configProvider: { config }
        )
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(codexRuntime: codex, claudeRuntime: claude)

        let modelTask = Task { try await client.modelOptions() }
        let codexInitialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: codexInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let codexModelList = try await waitForFakeAppServerRequest(codexTransport, method: "model/list", after: 1)
        transportResponse(codexTransport, id: codexModelList.id, result: #"{"models":[{"id":"gpt-live","title":"GPT Live","provider":"openai","isDefault":true}]}"#)

        let claudeInitialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(claudeTransport, id: claudeInitialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        let claudeModelList = try await waitForFakeAppServerRequest(claudeTransport, method: "model/list", after: 1)
        transportErrorResponse(claudeTransport, id: claudeModelList.id, code: -32000, message: "Claude CLI not logged in")

        let options = try await modelTask.value
        XCTAssertEqual(options.map(\.model), ["gpt-live"])
        XCTAssertEqual(options.first?.runtimeProvider, "codex")
        let claudeRemainsReady = await claude.hasReadyConnectionForTesting()
        let claudeCloseCount = await claudeTransport.closeCallCount()
        XCTAssertTrue(claudeRemainsReady, "模型列表失败不能回收可能正被会话订阅复用的 Claude 连接")
        XCTAssertEqual(claudeCloseCount, 0)
    }

    func testMultiRuntimeSocketsKeepCodexAndClaudeConnectionsOnActiveHost() async throws {
        let project = AgentProject(id: "proj_multi_socket", name: "Multi Socket", path: "/tmp/multi-socket")
        let config = makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata()])
        let codexTransport = FakeCodexAppServerTransport()
        let claudeTransport = FakeCodexAppServerTransport()
        let codex = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "codex",
            transportFactory: { codexTransport },
            configProvider: { config }
        )
        let claude = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { claudeTransport },
            configProvider: { config }
        )

        let codexPrepareTask = Task { try await codex.prepareForHostActivation() }
        let codexInitialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: codexInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        try await codexPrepareTask.value

        let claudePrepareTask = Task { try await claude.prepareForHostActivation() }
        let claudeInitialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(claudeTransport, id: claudeInitialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        try await claudePrepareTask.value

        let bundle = AppServerRuntimeBundle(codexRuntime: codex, claudeRuntime: claude)
        bundle.routes.remember("codex", for: "thread-codex")
        bundle.routes.remember("claude", for: "thread-claude")
        let selectedSessionSocket = MultiRuntimeSessionWebSocketClient(bundle: bundle)
        let queuedSessionSocket = MultiRuntimeSessionWebSocketClient(bundle: bundle)
        defer {
            selectedSessionSocket.disconnect()
            queuedSessionSocket.disconnect()
        }

        // 复现线上组合：前台选中的 Codex 会话与后台排队的 Claude 会话同时监听。
        selectedSessionSocket.connect(sessionID: "thread-codex")
        queuedSessionSocket.connect(sessionID: "thread-claude")
        _ = try await waitForFakeAppServerRequest(codexTransport, method: "thread/read")
        _ = try await waitForFakeAppServerRequest(claudeTransport, method: "thread/read")

        let codexRemainsReady = await codex.hasReadyConnectionForTesting()
        let claudeRemainsReady = await claude.hasReadyConnectionForTesting()
        let codexCloseCount = await codexTransport.closeCallCount()
        let claudeCloseCount = await claudeTransport.closeCallCount()
        XCTAssertTrue(codexRemainsReady)
        XCTAssertTrue(claudeRemainsReady)
        XCTAssertEqual(codexCloseCount, 0, "Claude 队列监听不能关闭当前 Codex Runtime")
        XCTAssertEqual(claudeCloseCount, 0, "Codex 前台监听不能关闭 Claude 队列 Runtime")
    }

    func testMultiRuntimeClaudeRateLimitReadUsesClaudeGateway() async throws {
        let project = AgentProject(id: "proj_claude_quota", name: "Claude Quota", path: "/tmp/claude-quota")
        let config = makeDirectAppServerConfig(
            project: project,
            allowedMethods: ["initialize", "initialized", "account/rateLimits/read"],
            channels: [makeClaudeChannelMetadata()]
        )
        let codexTransport = FakeCodexAppServerTransport()
        let claudeTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(
            codexRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                runtimeProvider: "codex",
                transportFactory: { codexTransport },
                configProvider: { config }
            ),
            claudeRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                runtimeProvider: "claude",
                transportFactory: { claudeTransport },
                configProvider: { config }
            )
        )

        let refreshTask = Task { try await client.refreshRateLimit(runtimeProvider: "claude") }
        let initialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(claudeTransport, id: initialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        let rateLimitRead = try await waitForFakeAppServerRequest(claudeTransport, method: "account/rateLimits/read", after: 1)
        transportResponse(
            claudeTransport,
            id: rateLimitRead.id,
            result: #"{"rateLimits":{"limitId":"claude","limitName":"Claude","availability":"partial","primary":{"usedPercent":57,"resetsAt":1780494300,"windowDurationMins":300}}}"#
        )

        let summary = try await refreshTask.value
        XCTAssertEqual(summary?.limitID, "claude")
        XCTAssertEqual(summary?.availability, "partial")
        XCTAssertEqual(summary?.primaryResetsAt, 1_780_494_300)
        XCTAssertEqual(summary?.primaryUsedPercent, 57)
        XCTAssertEqual(summary?.primaryWindowDurationMins, 300)
        let codexMessages = await codexTransport.sentMessages()
        XCTAssertTrue(codexMessages.isEmpty)
    }

    func testClaudeRateLimitTimeoutAllowsDelegatedCredentialRefresh() async {
        let config = makeDirectAppServerConfig(
            project: AgentProject(id: "proj", name: "Demo", path: "/tmp/demo")
        )
        let claudeRuntime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            requestTimeout: 20,
            configProvider: { config }
        )
        let codexRuntime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "codex",
            requestTimeout: 20,
            configProvider: { config }
        )

        let claudeTimeout = await claudeRuntime.rateLimitRequestTimeout
        let codexTimeout = await codexRuntime.rateLimitRequestTimeout
        XCTAssertEqual(claudeTimeout, 15)
        XCTAssertEqual(codexTimeout, 5)
    }

    func testClaudeRateLimitNotificationAppliesObservedUtilization() async throws {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { FakeCodexAppServerTransport() },
            configProvider: { makeDirectAppServerConfig(project: AgentProject(id: "proj", name: "Demo", path: "/tmp/demo")) }
        )
        let notification = try decodeAppServerNotification(
            #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"claude","limitName":"Claude","availability":"partial","primary":{"usedPercent":57,"resetsAt":1780494300,"windowDurationMins":300}}}}"#
        )

        await runtime.handle(notification)
        let summary = await runtime.accountRateLimit

        XCTAssertEqual(summary?.limitID, "claude")
        XCTAssertEqual(summary?.primaryUsedPercent, 57)
        XCTAssertEqual(summary?.primaryResetsAt, 1_780_494_300)
    }

    func testRuntimeRoutingSessionListRequestsOnlySelectedRuntimeAndPreservesCursor() async throws {
        let project = AgentProject(id: "proj_runtime_filter", name: "Runtime Filter", path: "/tmp/runtime-filter")
        let config = makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata()])
        let codexTransport = FakeCodexAppServerTransport()
        let claudeTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(
            codexRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                runtimeProvider: "codex",
                transportFactory: { codexTransport },
                configProvider: { config }
            ),
            claudeRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                runtimeProvider: "claude",
                transportFactory: { claudeTransport },
                configProvider: { config }
            )
        )

        let claudeTask = Task {
            try await client.sessionsPage(
                workspace: AgentWorkspace(project: project),
                runtimeProvider: "claude",
                cursor: "claude-cursor",
                limit: 20,
                consistency: .authoritative
            )
        }
        let claudeInitialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(claudeTransport, id: claudeInitialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        let claudeList = try await waitForFakeAppServerRequest(claudeTransport, method: "thread/list", after: 1)
        XCTAssertEqual(claudeList.params?.objectValue?["cursor"]?.stringValue, "claude-cursor")
        transportResponse(claudeTransport, id: claudeList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "claude-only", cwd: project.path, source: "claude", updatedAt: 1_780_493_000)
        ], nextCursor: "claude-older"))

        let claudePage = try await claudeTask.value
        XCTAssertEqual(claudePage.sessions.map(\.id), ["claude-only"])
        XCTAssertEqual(claudePage.nextCursor, "claude-older")
        let codexMessagesAfterClaudeList = await codexTransport.sentMessages()
        XCTAssertTrue(codexMessagesAfterClaudeList.isEmpty, "Claude 列表不能顺带请求 Codex")

        let claudeMessageCount = (await claudeTransport.sentMessages()).count
        let codexTask = Task {
            try await client.sessionsPage(
                workspace: AgentWorkspace(project: project),
                runtimeProvider: "codex",
                cursor: "codex-cursor",
                limit: 20,
                consistency: .authoritative
            )
        }
        let codexInitialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: codexInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let codexList = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        XCTAssertEqual(codexList.params?.objectValue?["cursor"]?.stringValue, "codex-cursor")
        transportResponse(codexTransport, id: codexList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "codex-only", cwd: project.path, source: "appServer", updatedAt: 1_780_492_000)
        ], nextCursor: nil))

        let codexPage = try await codexTask.value
        XCTAssertEqual(codexPage.sessions.map(\.id), ["codex-only"])
        XCTAssertNil(codexPage.nextCursor)
        let claudeMessagesAfterCodexList = await claudeTransport.sentMessages()
        XCTAssertEqual(claudeMessagesAfterCodexList.count, claudeMessageCount, "Codex 列表不能顺带请求 Claude")
    }

    func testDirectRuntimeRetriesNewSessionAfterStaleInitializationError() async throws {
        let project = AgentProject(id: "proj_stale_init_new", name: "Stale Init New", path: "/tmp/stale-init-new")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "恢复发送",
                resumeID: "",
                clientMessageID: "client_stale_new"
            ))
        }

        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let firstInitializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let firstInitialize = try decodeAppServerRequest(firstInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(firstInitialize)
        transportResponse(firstTransport, id: firstInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let firstThreadMessages = try await waitForFakeAppServerMessages(firstTransport, count: 3)
        let staleThreadStart = try decodeAppServerRequest(firstThreadMessages[2])
        XCTAssertEqual(staleThreadStart.method, "thread/start")
        // app-server 上游重启后可能对旧连接返回 Not initialized；这里应重建连接而不是把用户发送直接标失败。
        transportErrorResponse(firstTransport, id: staleThreadStart.id, code: -32600, message: "Not initialized")

        let secondTransport = try await waitForFakeAppServerTransport(in: pool, index: 1)
        let secondInitializeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 1)
        let secondInitialize = try decodeAppServerRequest(secondInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(secondInitialize)
        transportResponse(secondTransport, id: secondInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let secondThreadMessages = try await waitForFakeAppServerMessages(secondTransport, count: 3)
        let threadStart = try decodeAppServerRequest(secondThreadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transportResponse(secondTransport, id: threadStart.id, result: #"{"thread":{"id":"thr_stale_new","sessionId":"thr_stale_new","preview":"恢复发送","ephemeral":false,"modelProvider":"openai","createdAt":1780490800,"updatedAt":1780490801,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale-init-new","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"恢复发送","turns":[]}}"#)

        let turnStart = try await waitForFakeAppServerRequest(secondTransport, method: "turn/start", after: 3)
        XCTAssertEqual(turnStart.params?.objectValue?["threadId"]?.stringValue, "thr_stale_new")
        XCTAssertEqual(turnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_stale_new")
        transportResponse(secondTransport, id: turnStart.id, result: #"{"turn":{"id":"turn_stale_new","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490802,"completedAt":null,"durationMs":null}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_stale_new")
        XCTAssertEqual(created.session.activeTurnID, "turn_stale_new")
    }

    func testDirectRuntimeRetriesGoalSetAfterStaleInitializationError() async throws {
        let project = AgentProject(id: "proj_stale_goal", name: "Stale Goal", path: "/tmp/stale-goal")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                input: [],
                resumeID: "",
                clientMessageID: nil
            ))
        }

        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(firstTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadMessages = try await waitForFakeAppServerMessages(firstTransport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transportResponse(firstTransport, id: threadStart.id, result: #"{"thread":{"id":"thr_stale_goal","sessionId":"thr_stale_goal","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":1780490810,"updatedAt":1780490811,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale-goal","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"目标恢复","turns":[]}}"#)
        _ = try await createTask.value

        let goalTask = Task {
            try await runtime.setThreadGoal(threadID: "thr_stale_goal", objective: "恢复目标", status: .active)
        }
        let staleGoalSet = try await waitForFakeAppServerRequest(firstTransport, method: "thread/goal/set", after: 3)
        transportErrorResponse(firstTransport, id: staleGoalSet.id, code: -32600, message: "Not initialized")

        let secondTransport = try await waitForFakeAppServerTransport(in: pool, index: 1)
        let secondInitializeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 1)
        let secondInitialize = try decodeAppServerRequest(secondInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(secondInitialize)
        transportResponse(secondTransport, id: secondInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let goalSet = try await waitForFakeAppServerRequest(secondTransport, method: "thread/goal/set", after: 1)
        XCTAssertEqual(goalSet.params?.objectValue?["threadId"]?.stringValue, "thr_stale_goal")
        XCTAssertEqual(goalSet.params?.objectValue?["objective"]?.stringValue, "恢复目标")
        transportResponse(secondTransport, id: goalSet.id, result: #"{"goal":{"threadId":"thr_stale_goal","objective":"恢复目标","status":"active","tokenBudget":null,"tokensUsed":0,"timeUsedSeconds":0,"createdAt":1780490812,"updatedAt":1780490812}}"#)

        let goal = try await goalTask.value
        XCTAssertEqual(goal.threadID, "thr_stale_goal")
        XCTAssertEqual(goal.objective, "恢复目标")
        XCTAssertEqual(goal.status, .active)
    }

    func testDirectRuntimeFansOutEventsToMultipleSubscribersForSameThread() async throws {
        let project = AgentProject(id: "proj_event_fanout", name: "Event Fanout", path: "/tmp/event-fanout")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                input: [],
                resumeID: "",
                clientMessageID: nil
            ))
        }
        let transport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        transportResponse(transport, id: threadStart.id, result: #"{"thread":{"id":"thr_event_fanout","sessionId":"thr_event_fanout","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":1780490820,"updatedAt":1780490821,"status":{"type":"idle"},"path":null,"cwd":"/tmp/event-fanout","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"事件扇出","turns":[]}}"#)
        _ = try await createTask.value

        let firstStream = await runtime.attachEvents(sessionID: "thr_event_fanout")
        let secondStream = await runtime.attachEvents(sessionID: "thr_event_fanout")
        let firstReceivedGoal = expectation(description: "first subscriber receives goal")
        let secondReceivedGoal = expectation(description: "second subscriber receives goal")
        let firstObserver = Task {
            for await event in firstStream {
                if case .goalUpdated = event {
                    firstReceivedGoal.fulfill()
                    return
                }
            }
        }
        let secondObserver = Task {
            for await event in secondStream {
                if case .goalUpdated = event {
                    secondReceivedGoal.fulfill()
                    return
                }
            }
        }
        defer {
            firstObserver.cancel()
            secondObserver.cancel()
        }

        let goalTask = Task {
            try await runtime.setThreadGoal(threadID: "thr_event_fanout", objective: "验证双订阅", status: .active)
        }
        let goalSet = try await waitForFakeAppServerRequest(transport, method: "thread/goal/set", after: 3)
        transportResponse(transport, id: goalSet.id, result: #"{"goal":{"threadId":"thr_event_fanout","objective":"验证双订阅","status":"active","tokenBudget":null,"tokensUsed":0,"timeUsedSeconds":0,"createdAt":1780490822,"updatedAt":1780490822}}"#)
        _ = try await goalTask.value

        await fulfillment(of: [firstReceivedGoal, secondReceivedGoal], timeout: 2)
    }

    func testDirectRuntimeRetriesQueuedTurnStartAfterStaleInitializationError() async throws {
        let project = AgentProject(id: "proj_stale_turn", name: "Stale Turn", path: "/tmp/stale-turn")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let listTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: nil)
        }
        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(firstTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadList = try await waitForFakeAppServerRequest(firstTransport, method: "thread/list", after: 1)
        XCTAssertEqual(threadList.params?.objectValue?["cwd"]?.stringValue, project.path)
        transportResponse(firstTransport, id: threadList.id, result: #"{"data":[{"id":"thr_stale_turn","sessionId":"thr_stale_turn","preview":"可恢复 turn","ephemeral":false,"modelProvider":"openai","createdAt":1780490820,"updatedAt":1780490821,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"恢复 turn","turns":[]}],"nextCursor":null}"#)
        let page = try await listTask.value
        XCTAssertEqual(page.sessions.first?.id, "thr_stale_turn")

        let startTask = Task {
            try await runtime.startTurn(
                sessionID: "thr_stale_turn",
                payload: CodexAppServerTurnPayload(prompt: "旧连接后继续"),
                clientMessageID: "client_stale_turn"
            )
        }
        let beforeResumeMessages = await firstTransport.sentMessages()
        let firstResume = try await waitForFakeAppServerRequest(firstTransport, method: "thread/resume", after: beforeResumeMessages.count)
        XCTAssertEqual(firstResume.params?.objectValue?["threadId"]?.stringValue, "thr_stale_turn")
        transportResponse(firstTransport, id: firstResume.id, result: #"{"thread":{"id":"thr_stale_turn","sessionId":"thr_stale_turn","preview":"可恢复 turn","ephemeral":false,"modelProvider":"openai","createdAt":1780490820,"updatedAt":1780490822,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"恢复 turn","turns":[]}}"#)

        let beforeTurnMessages = await firstTransport.sentMessages()
        let staleTurnStart = try await waitForFakeAppServerRequest(firstTransport, method: "turn/start", after: beforeTurnMessages.count)
        XCTAssertEqual(staleTurnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_stale_turn")
        transportErrorResponse(firstTransport, id: staleTurnStart.id, code: -32600, message: "Not initialized")

        let secondTransport = try await waitForFakeAppServerTransport(in: pool, index: 1)
        let secondInitializeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 1)
        let secondInitialize = try decodeAppServerRequest(secondInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(secondInitialize)
        transportResponse(secondTransport, id: secondInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        // 新连接必须重新 thread/resume，然后再发同一个 turn/start；否则 app-server 仍会认为线程未绑定。
        let secondResume = try await waitForFakeAppServerRequest(secondTransport, method: "thread/resume", after: 1)
        XCTAssertEqual(secondResume.params?.objectValue?["threadId"]?.stringValue, "thr_stale_turn")
        transportResponse(secondTransport, id: secondResume.id, result: #"{"thread":{"id":"thr_stale_turn","sessionId":"thr_stale_turn","preview":"可恢复 turn","ephemeral":false,"modelProvider":"openai","createdAt":1780490820,"updatedAt":1780490823,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"恢复 turn","turns":[]}}"#)

        let retryTurnStart = try await waitForFakeAppServerRequest(secondTransport, method: "turn/start", after: 2)
        let retryParams = try XCTUnwrap(retryTurnStart.params?.objectValue)
        XCTAssertEqual(retryParams["threadId"]?.stringValue, "thr_stale_turn")
        XCTAssertEqual(retryParams["clientUserMessageId"]?.stringValue, "client_stale_turn")
        XCTAssertEqual(retryParams["collaborationMode"]?.objectValue?["mode"]?.stringValue, "default")
        transportResponse(secondTransport, id: retryTurnStart.id, result: #"{"turn":{"id":"turn_stale_turn","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490824,"completedAt":null,"durationMs":null}}"#)

        let turnID = try await startTask.value
        XCTAssertEqual(turnID, "turn_stale_turn")
    }

    func testDirectRuntimeDoesNotRetryNonStaleInvalidRequestError() async throws {
        let project = AgentProject(id: "proj_invalid_32600", name: "Invalid 32600", path: "/tmp/invalid-32600")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "非法请求不应重试",
                resumeID: "",
                clientMessageID: "client_invalid_32600"
            ))
        }
        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(firstTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadStart = try await waitForFakeAppServerRequest(firstTransport, method: "thread/start", after: 1)
        transportErrorResponse(firstTransport, id: threadStart.id, code: -32600, message: "Invalid request: collaborationMode.mode")

        do {
            _ = try await createTask.value
            XCTFail("非 Not initialized 的 -32600 应直接暴露协议错误")
        } catch let error as CodexAppServerConnectionError {
            guard case .appServer(let appServerError) = error else {
                XCTFail("应保留 app-server 错误类型，got \(error)")
                return
            }
            XCTAssertEqual(appServerError.code, -32600)
            XCTAssertEqual(appServerError.message, "Invalid request: collaborationMode.mode")
        }
        // 只有 Not initialized 才允许自动重建连接；协议错误重试会掩盖真正的 payload bug。
        XCTAssertNil(pool.transport(at: 1))
    }

    func testDirectRuntimeDoesNotRetryNoRolloutFoundAppServerError() async throws {
        let project = AgentProject(id: "proj_no_rollout_direct", name: "No Rollout Direct", path: "/tmp/no-rollout-direct")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let listTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: nil)
        }
        let transport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: threadList.id, result: #"{"data":[{"id":"thr_no_rollout","sessionId":"thr_no_rollout","preview":"缺失 rollout","ephemeral":false,"modelProvider":"openai","createdAt":1780490830,"updatedAt":1780490831,"status":{"type":"idle"},"path":null,"cwd":"/tmp/no-rollout-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"缺失 rollout","turns":[]}],"nextCursor":null}"#)
        _ = try await listTask.value

        let startTask = Task {
            try await runtime.startTurn(
                sessionID: "thr_no_rollout",
                payload: CodexAppServerTurnPayload(prompt: "继续"),
                clientMessageID: "client_no_rollout"
            )
        }
        let beforeResumeMessages = await transport.sentMessages()
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: beforeResumeMessages.count)
        transportResponse(transport, id: resume.id, result: #"{"thread":{"id":"thr_no_rollout","sessionId":"thr_no_rollout","preview":"缺失 rollout","ephemeral":false,"modelProvider":"openai","createdAt":1780490830,"updatedAt":1780490832,"status":{"type":"idle"},"path":null,"cwd":"/tmp/no-rollout-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"缺失 rollout","turns":[]}}"#)

        let beforeTurnMessages = await transport.sentMessages()
        let turnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: beforeTurnMessages.count)
        transportErrorResponse(transport, id: turnStart.id, code: -32000, message: "no rollout found")

        do {
            _ = try await startTask.value
            XCTFail("no rollout found 是上游业务状态错误，不应被当成 stale initialize 自动重试")
        } catch let error as CodexAppServerConnectionError {
            guard case .appServer(let appServerError) = error else {
                XCTFail("应保留 app-server 错误类型，got \(error)")
                return
            }
            XCTAssertEqual(appServerError.code, -32000)
            XCTAssertEqual(appServerError.message, "no rollout found")
        }
        XCTAssertNil(pool.transport(at: 1))
    }

    func testEmptyNewDirectSessionResumesBeforeFirstFollowUpTurn() async throws {
        let project = AgentProject(id: "proj_empty_direct", name: "Empty Direct", path: "/tmp/empty-direct")
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
                input: [],
                resumeID: "",
                clientMessageID: nil
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_empty_direct","sessionId":"thr_empty_direct","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":1780490600,"updatedAt":1780490601,"status":{"type":"idle"},"path":null,"cwd":"/tmp/empty-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"空会话","turns":[]}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_empty_direct")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        socket.onStatus = { statuses.append($0) }
        socket.connect(sessionID: "thr_empty_direct")

        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        XCTAssertEqual(resume.params?.objectValue?["threadId"]?.stringValue, "thr_empty_direct")
        // 真实 app-server：刚 thread/start、还没跑过 turn 的空线程没有 rollout 文件，thread/resume 回
        // -32600 "no rollout found"。监听不能因此报错重连，必须吞掉并照常进入 connected。
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"error":{"code":-32600,"message":"no rollout found for thread id thr_empty_direct"}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))
        XCTAssertFalse(statuses.contains { if case .failed = $0 { return true } else { return false } },
                       "空会话 resume 命中 no rollout found 不应让 WebSocket 进入 failed/重连")

        XCTAssertTrue(socket.sendTurn(CodexAppServerTurnPayload(prompt: "第一条消息"), clientMessageID: "client_empty_first"))
        let turnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: 4)
        XCTAssertEqual(turnStart.params?.objectValue?["threadId"]?.stringValue, "thr_empty_direct")
        XCTAssertEqual(turnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_empty_first")
        XCTAssertEqual(turnStart.params?.objectValue?["collaborationMode"]?.objectValue?["mode"]?.stringValue, "default")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_empty_first","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490603,"completedAt":null,"durationMs":null}}}"#)

        socket.disconnect()
    }

    // 回归：Claude 通道的 thread/start / thread/resume 必须先按 runtime 策略把 .default 草稿的
    // dangerFullAccess 降级为 workspace-write。旧行为原样携带 danger-full-access，gateway 以
    // -32080 拒绝 resume，事件订阅进入确定性失败的重连死循环，Claude 会话永远打不开。
    func testClaudeRuntimeThreadStartAndResumeDowngradeSandboxToWorkspaceWrite() async throws {
        let project = AgentProject(id: "proj_claude_sandbox", name: "Claude Sandbox", path: "/tmp/claude-sandbox")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata()]) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                input: [],
                resumeID: "",
                clientMessageID: nil
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-claude-bridge","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        XCTAssertEqual(
            threadStart.params?.objectValue?["sandbox"]?.stringValue,
            "workspace-write",
            "Claude 通道 thread/start 不应携带 danger-full-access"
        )
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_claude_sandbox","sessionId":"thr_claude_sandbox","preview":"","ephemeral":false,"modelProvider":"anthropic","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/claude-sandbox","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Claude 会话","turns":[]}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_claude_sandbox")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        socket.onStatus = { statuses.append($0) }
        socket.connect(sessionID: "thr_claude_sandbox")

        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        XCTAssertEqual(resume.params?.objectValue?["threadId"]?.stringValue, "thr_claude_sandbox")
        XCTAssertEqual(
            resume.params?.objectValue?["sandbox"]?.stringValue,
            "workspace-write",
            "Claude 通道 thread/resume 不应携带 danger-full-access（gateway 会 -32080 拒绝并造成重连死循环）"
        )
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_claude_sandbox","sessionId":"thr_claude_sandbox","preview":"","ephemeral":false,"modelProvider":"anthropic","createdAt":1780490700,"updatedAt":1780490702,"status":{"type":"idle"},"path":null,"cwd":"/tmp/claude-sandbox","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Claude 会话","turns":[]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))
        XCTAssertFalse(
            statuses.contains { if case .failed = $0 { return true } else { return false } },
            "Claude 会话 resume 不应进入 failed/重连"
        )
        socket.disconnect()
    }

    // performStartTurn 路径：thread/list 里认识但本连接尚未 resume 过的新线程，首次 startTurn 会先补
    // thread/resume。真实 app-server 对没跑过 turn 的线程回 -32600 no rollout found；修复后这一步被良性
    // 吞掉，turn/start 仍照常发出并落盘 rollout，而不是把首条消息直接打回失败。
    func testDirectStartTurnToleratesNoRolloutFoundResumeBeforeFirstTurn() async throws {
        let project = AgentProject(id: "proj_start_no_rollout", name: "Start No Rollout", path: "/tmp/start-no-rollout")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        // thread/list 让 runtime 认识这个还没跑过 turn 的线程（contextsBySessionID 填充），但本连接尚未
        // thread/resume 过它，于是首次 startTurn 会先补 resume。
        let listTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: nil)
        }
        let transport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: threadList.id, result: #"{"data":[{"id":"thr_start_no_rollout","sessionId":"thr_start_no_rollout","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/start-no-rollout","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"空会话","turns":[]}],"nextCursor":null}"#)
        _ = try await listTask.value

        let startTask = Task {
            try await runtime.startTurn(
                sessionID: "thr_start_no_rollout",
                payload: CodexAppServerTurnPayload(prompt: "第一条消息"),
                clientMessageID: "client_start_no_rollout"
            )
        }

        let beforeResumeMessages = await transport.sentMessages()
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: beforeResumeMessages.count)
        XCTAssertEqual(resume.params?.objectValue?["threadId"]?.stringValue, "thr_start_no_rollout")
        // 真实 app-server 对没跑过 turn 的新线程回 -32600 no rollout found；修复后这一步被良性吞掉，不阻断
        // 后续 turn/start，而不是把首条消息直接打回失败。
        transportErrorResponse(transport, id: resume.id, code: -32600, message: "no rollout found for thread id thr_start_no_rollout")

        let beforeTurnMessages = await transport.sentMessages()
        let turnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: beforeTurnMessages.count)
        XCTAssertEqual(turnStart.params?.objectValue?["threadId"]?.stringValue, "thr_start_no_rollout")
        XCTAssertEqual(turnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_start_no_rollout")
        transportResponse(transport, id: turnStart.id, result: #"{"turn":{"id":"turn_start_no_rollout","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490702,"completedAt":null,"durationMs":null}}"#)

        let turnID = try await startTask.value
        XCTAssertEqual(turnID, "turn_start_no_rollout")
        XCTAssertNil(pool.transport(at: 1), "no rollout found 被良性吞掉，不应触发重连建立新 transport")
    }

    // 窄化保护：只有 no rollout found 才良性放行；其它 resume 失败（这里用 -32603 internal error）仍必须
    // 冒泡成 WebSocket failed，避免 isNoRolloutFoundError 把所有 resume 错误一锅端、掩盖真实故障。
    func testEmptyNewDirectSessionSurfacesNonRolloutResumeError() async throws {
        let project = AgentProject(id: "proj_resume_fail", name: "Resume Fail", path: "/tmp/resume-fail")
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
                input: [],
                resumeID: "",
                clientMessageID: nil
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_resume_fail","sessionId":"thr_resume_fail","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":1780490800,"updatedAt":1780490801,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resume-fail","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"空会话","turns":[]}}}"#)
        _ = try await createTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        socket.onStatus = { statuses.append($0) }
        socket.connect(sessionID: "thr_resume_fail")

        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        XCTAssertEqual(resume.params?.objectValue?["threadId"]?.stringValue, "thr_resume_fail")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"error":{"code":-32603,"message":"internal error"}}"#)

        func containsFailed(_ items: [WebSocketStatus]) -> Bool {
            items.contains { if case .failed = $0 { return true } else { return false } }
        }
        for _ in 0..<200 where !containsFailed(statuses) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(containsFailed(statuses), "非 no rollout found 的 resume 错误必须冒泡为 failed")
        XCTAssertFalse(statuses.contains(.connected), "resume 真失败时不应进入 connected")

        socket.disconnect()
    }

    func testDirectRuntimeResumeWithActiveTurnDoesNotStartSecondTurn() async throws {
        let project = AgentProject(id: "proj_active_resume", name: "Active Resume", path: "/tmp/active-resume")
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
                prompt: "不要重复启动",
                resumeID: "thr_active_resume",
                clientMessageID: "client_active_resume"
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let resume = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(resume.method, "thread/resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_active_resume","sessionId":"thr_active_resume","preview":"旧任务","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490100,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/active-resume","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"活动会话","turns":[{"id":"turn_live","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490001,"completedAt":null,"durationMs":null}]}}}"#)

        do {
            _ = try await createTask.value
            XCTFail("活动会话恢复后必须拒绝第二个 turn/start")
        } catch CodexAppServerSessionRuntimeError.activeTurnConflict(let session, let activeTurnID) {
            XCTAssertEqual(session.id, "thr_active_resume")
            XCTAssertEqual(session.status, "running")
            XCTAssertEqual(activeTurnID, "turn_live")
        } catch {
            XCTFail("应返回 typed activeTurnConflict，实际为 \(error)")
        }

        let methods = await transport.sentMessages().compactMap {
            try? decodeAppServerRequest($0).method
        }
        XCTAssertFalse(methods.contains("turn/start"))
    }

    func testDirectRuntimeSurfacesUserInputAndWaitsForExplicitResponse() async throws {
        let project = AgentProject(id: "proj_plan_skip", name: "Plan Skip", path: "/tmp/plan-skip")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        var options = CodexAppServerTurnOptions.default
        options.model = "gpt-5-codex"
        options.collaborationMode = .plan

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "先规划",
                turnOptions: options,
                resumeID: "",
                clientMessageID: "client_plan_skip"
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_plan_skip","sessionId":"thr_plan_skip","preview":"先规划","ephemeral":false,"modelProvider":"openai","createdAt":1780490100,"updatedAt":1780490101,"status":{"type":"idle"},"path":null,"cwd":"/tmp/plan-skip","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"计划跳过","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let turnStart = try decodeAppServerRequest(turnMessages[3])
        XCTAssertEqual(turnStart.method, "turn/start")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["collaborationMode"]?.objectValue?["mode"]?.stringValue, "plan")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_plan_skip","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490102,"completedAt":null,"durationMs":null}}}"#)
        _ = try await createTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var events: [AgentEvent] = []
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_plan_skip")

        transport.enqueue(#"{"id":501,"method":"item/tool/requestUserInput","params":{"threadId":"thr_plan_skip","turnId":"turn_plan_skip","itemId":"input_skip","questions":[{"id":"scope","header":"范围","question":"要补充吗？","isOther":true,"isSecret":false,"options":[{"label":"后端","description":"先做 API"}]}]}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .userInputRequest(let request, _) = $0 {
                return request.id == "input_skip"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .userInputRequest(let request, _) = $0 {
                return request.id == "input_skip"
            }
            return false
        })

        // 上游提问必须一直挂起到用户明确操作，不能再由普通/Plan 发送选项伪造空回答。
        try await Task.sleep(nanoseconds: 50_000_000)
        let prematureResponse = await transport.sentMessages().contains { text in
            (try? AgentAPIClient.decoder.decode(
                CodexAppServerResponse.self,
                from: Data(text.utf8)
            ))?.id == .int(501)
        }
        XCTAssertFalse(prematureResponse)

        XCTAssertTrue(socket.sendUserInputResponse(requestID: "input_skip", answers: ["scope": ["后端"]]))
        let response = try await waitForFakeAppServerResponse(transport, id: .int(501))
        XCTAssertEqual(
            response.result?["answers"]?.objectValue?["scope"]?.objectValue?["answers"]?.arrayValue?.first?.stringValue,
            "后端"
        )
        socket.disconnect()
    }

    func testDirectSocketEmitsSendAcceptedOnlyAfterTurnStartSucceeds() async throws {
        let project = AgentProject(id: "proj_direct_accept", name: "Direct Accept", path: "/tmp/direct-accept")
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
                prompt: "准备直连 socket",
                resumeID: "",
                clientMessageID: "client_direct_accept_initial"
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_direct_accept","sessionId":"thr_direct_accept","preview":"准备直连 socket","ephemeral":false,"modelProvider":"openai","createdAt":1780490500,"updatedAt":1780490501,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-accept","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Direct accept","turns":[]}}}"#)

        let initialTurnMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let initialTurnStart = try decodeAppServerRequest(initialTurnMessages[3])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialTurnStart.id)),"result":{"turn":{"id":"turn_direct_accept_initial","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490502,"completedAt":null,"durationMs":null}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_direct_accept")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        var acceptedIDs: [ClientMessageID?] = []
        var failures: [(ClientMessageID?, String)] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.onSendAccepted = { acceptedIDs.append($0) }
        socket.onSendFailure = { failures.append(($0, $1)) }
        socket.connect(sessionID: "thr_direct_accept")

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_direct_accept","turnId":"turn_direct_accept_initial"}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .turnCompleted(let metadata) = $0 {
                return metadata.turnID == "turn_direct_accept_initial"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .turnCompleted(let metadata) = $0 {
                return metadata.turnID == "turn_direct_accept_initial"
            }
            return false
        })

        XCTAssertTrue(socket.sendTurn(CodexAppServerTurnPayload(prompt: "成功 turn"), clientMessageID: "client_direct_accept_success"))
        let successTurnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: 4)
        XCTAssertEqual(successTurnStart.method, "turn/start")
        XCTAssertEqual(successTurnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_direct_accept_success")
        XCTAssertTrue(acceptedIDs.isEmpty)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: successTurnStart.id)),"result":{"turn":{"id":"turn_direct_accept_success","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490503,"completedAt":null,"durationMs":null}}}"#)

        for _ in 0..<200 where !acceptedIDs.contains("client_direct_accept_success") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(acceptedIDs.contains("client_direct_accept_success"))
        XCTAssertTrue(failures.isEmpty)

        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_direct_accept","turnId":"turn_direct_accept_success"}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .turnCompleted(let metadata) = $0 {
                return metadata.turnID == "turn_direct_accept_success"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .turnCompleted(let metadata) = $0 {
                return metadata.turnID == "turn_direct_accept_success"
            }
            return false
        })

        XCTAssertTrue(socket.sendTurn(CodexAppServerTurnPayload(prompt: "失败 turn"), clientMessageID: "client_direct_accept_fail"))
        let sentAfterSuccess = await transport.sentMessages()
        let failureTurnStart = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/start",
            after: sentAfterSuccess.count
        )
        XCTAssertEqual(failureTurnStart.method, "turn/start")
        XCTAssertEqual(failureTurnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_direct_accept_fail")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: failureTurnStart.id)),"error":{"code":-32000,"message":"turn failed"}}"#)

        for _ in 0..<200 where failures.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(failures.first?.0, "client_direct_accept_fail")
        XCTAssertFalse(acceptedIDs.contains("client_direct_accept_fail"))

        socket.disconnect()
    }

    func testCodexAppServerSessionRuntimeForwardsRichCreatePayload() async throws {
        let project = AgentProject(id: "proj_direct_rich", name: "Direct Rich", path: "/tmp/direct-rich")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        var options = CodexAppServerTurnOptions.default
        options.model = "gpt-5.1-codex"
        options.modelProvider = "openai"
        options.serviceTier = "priority"
        options.reasoningEffort = .high
        options.approvalPolicy = .onRequest
        options.sandboxMode = .readOnly
        options.baseInstructions = "base"
        options.developerInstructions = "dev"
        let payload = CodexAppServerTurnPayload(input: [
            .text("分析截图"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .skill(name: "review", path: project.path + "/.codex/skills/review/SKILL.md")
        ], options: options)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: payload.previewText,
                input: payload.input,
                turnOptions: payload.options,
                resumeID: "",
                clientMessageID: "client_direct_rich"
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        let threadParams = try XCTUnwrap(threadStart.params?.objectValue)
        XCTAssertNil(threadParams["model"]?.stringValue)
        XCTAssertNil(threadParams["modelProvider"])
        XCTAssertEqual(threadParams["serviceTier"]?.stringValue, "priority")
        XCTAssertEqual(threadParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(threadParams["sandbox"]?.stringValue, "read-only")
        XCTAssertEqual(threadParams["baseInstructions"]?.stringValue, "base")
        XCTAssertEqual(threadParams["developerInstructions"]?.stringValue, "dev")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_direct_rich","sessionId":"thr_direct_rich","preview":"分析截图","ephemeral":false,"modelProvider":"openai","createdAt":1780490400,"updatedAt":1780490401,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-rich","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Rich direct","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let turnStart = try decodeAppServerRequest(turnMessages[3])
        XCTAssertEqual(turnStart.method, "turn/start")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thr_direct_rich")
        XCTAssertEqual(turnParams["clientUserMessageId"]?.stringValue, "client_direct_rich")
        XCTAssertEqual(turnParams["model"]?.stringValue, "gpt-5.1-codex")
        XCTAssertEqual(turnParams["serviceTier"]?.stringValue, "priority")
        XCTAssertEqual(turnParams["effort"]?.stringValue, "high")
        XCTAssertEqual(turnParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertNil(turnParams["modelProvider"])
        XCTAssertNil(turnParams["baseInstructions"])
        let input = try XCTUnwrap(turnParams["input"]?.arrayValue)
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[0].objectValue?["text"]?.stringValue, "分析截图")
        XCTAssertEqual(input[1].objectValue?["detail"]?.stringValue, "high")
        XCTAssertEqual(input[2].objectValue?["path"]?.stringValue, project.path + "/.codex/skills/review/SKILL.md")
        let sandbox = try XCTUnwrap(turnParams["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(sandbox["type"]?.stringValue, "readOnly")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_direct_rich","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490402,"completedAt":null,"durationMs":null}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_direct_rich")
        XCTAssertEqual(created.session.activeTurnID, "turn_direct_rich")
    }

    func testClaudeRuntimeCreateSessionResponseUsesClaudeGatewayURL() async throws {
        let project = AgentProject(id: "proj_claude_url", name: "Claude URL", path: "/tmp/claude-url")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, channels: [
                    CodexAppServerChannelMetadata(
                        id: "claude",
                        runtimeID: "claude",
                        title: "Claude Code",
                        provider: "anthropic",
                        type: "claude_code_bridge",
                        protocolName: "app_server_jsonrpc_stdio_v1",
                        gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws?runtime=claude",
                        gatewayAvailable: true,
                        managed: false,
                        experimental: true,
                        lifecycle: "per_connection",
                        bridge: nil,
                        methods: ["initialize", "initialized", "thread/start"],
                        capabilities: ["history": true]
                    )
                ])
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                input: [],
                turnOptions: .default,
                resumeID: "",
                clientMessageID: nil
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-claude","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_claude_url","sessionId":"thr_claude_url","preview":"","ephemeral":false,"createdAt":1780490400,"updatedAt":1780490401,"status":{"type":"idle"},"path":null,"cwd":"/tmp/claude-url","cliVersion":"0.0.0","source":"claude","threadSource":"user","name":"Claude URL","turns":[]}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.runtimeProvider, "claude")
        XCTAssertTrue(created.wsURL.contains("runtime=claude"), "Claude create wsURL 应包含 runtime=claude，got \(created.wsURL)")
    }

    func testDirectRuntimeClearsApprovalWhenResolvedNotificationOnlyHasRequestID() async throws {
        let project = AgentProject(id: "proj_resolved", name: "Resolved", path: "/tmp/resolved")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let sessionTask = Task {
            try await client.session(id: "thr_resolved")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_resolved","sessionId":"thr_resolved","preview":"等待审批清理","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resolved","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"等待审批清理","turns":[]}}}"#)
        _ = try await sessionTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_resolved")

        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resume = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resume.method, "thread/resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_resolved","sessionId":"thr_resolved","preview":"等待审批清理","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resolved","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"等待审批清理","turns":[]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        // 真实审批一定发生在进行中的 turn 内：先让 thread 进入活跃 turn，审批才会被当作有效请求展示，
        // 而不是被当成 resume 重放的过期僵尸丢弃。
        transport.enqueue(#"{"method":"turn/started","params":{"threadId":"thr_resolved","turn":{"id":"turn_resolved"}}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .turnStarted(let metadata) = $0 {
                return metadata.sessionID == "thr_resolved"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        transport.enqueue(#"{"id":101,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_resolved","turnId":"turn_resolved","itemId":"cmd_resolved","command":"xcrun devicectl list devices"}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .approvalRequest(let approval, _) = $0 {
                return approval.id == "cmd_resolved"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .approvalRequest(let approval, _) = $0 {
                return approval.id == "cmd_resolved"
            }
            return false
        })

        XCTAssertTrue(socket.sendApprovalDecision(approvalID: "cmd_resolved", decision: "accept", message: nil))
        let approvalResponse = try await waitForFakeAppServerResponse(transport, id: .int(101))
        XCTAssertEqual(approvalResponse.result?["decision"]?.stringValue, "accept")

        transport.enqueue(#"{"method":"serverRequest/resolved","params":{"requestId":101}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_resolved"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_resolved"
            }
            return false
        })

        transport.enqueue(#"{"id":102,"method":"item/tool/requestUserInput","params":{"threadId":"thr_resolved","turnId":"turn_resolved","itemId":"input_resolved","questions":[{"id":"scope","header":"范围","question":"修复哪里？","isOther":true,"isSecret":false,"options":[{"label":"客户端","description":"修复 iPad 端"}]}]}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .userInputRequest(let request, let metadata) = $0 {
                return request.id == "input_resolved" && metadata.sessionID == "thr_resolved"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .userInputRequest(let request, let metadata) = $0 {
                return request.id == "input_resolved" && metadata.sessionID == "thr_resolved"
            }
            return false
        })

        XCTAssertTrue(socket.sendUserInputResponse(requestID: "input_resolved", answers: ["scope": ["客户端"]]))
        let userInputResponse = try await waitForFakeAppServerResponse(transport, id: .int(102))
        XCTAssertEqual(userInputResponse.result?["answers"]?.objectValue?["scope"]?.objectValue?["answers"]?.arrayValue?.first?.stringValue, "客户端")

        let eventCountBeforeUserInputResolved = events.count
        // 带 threadId 才能覆盖旧故障：投影出的 approvalResolved 与 userInputResolved 属于同一 session，
        // 旧实现会错误保留前者并过滤后者。
        transport.enqueue(#"{"method":"serverRequest/resolved","params":{"threadId":"thr_resolved","requestId":102}}"#)
        for _ in 0..<200 where !events.dropFirst(eventCountBeforeUserInputResolved).contains(where: {
            if case .userInputResolved(let metadata, _) = $0 {
                return metadata.sessionID == "thr_resolved"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let userInputResolvedEvents = Array(events.dropFirst(eventCountBeforeUserInputResolved))
        XCTAssertTrue(userInputResolvedEvents.contains {
            if case .userInputResolved(let metadata, _) = $0 {
                return metadata.sessionID == "thr_resolved"
            }
            return false
        })
        XCTAssertFalse(userInputResolvedEvents.contains {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_resolved"
            }
            return false
        }, "requestUserInput 完成后不能投影成 approvalResolved")

        socket.disconnect()
    }

    func testDirectRuntimeServesEarlierHistoryFromCacheWithoutRefetch() async throws {
        let project = AgentProject(id: "proj_hist", name: "Hist", path: "/tmp/hist")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        // 首屏 before=nil：触发一次整段 thread/read。
        let firstPageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist", before: nil, limit: 2)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist","sessionId":"thr_hist","preview":"hist","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/hist","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"hist","turns":[{"id":"turn_h","startedAt":1780490000,"items":[{"type":"userMessage","id":"item_0","content":[{"type":"text","text":"m0"}]},{"type":"userMessage","id":"item_1","content":[{"type":"text","text":"m1"}]},{"type":"userMessage","id":"item_2","content":[{"type":"text","text":"m2"}]}]}]}}}"#)

        let firstPage = try await firstPageTask.value
        XCTAssertEqual(firstPage.messages.map(\.content), ["m1", "m2"])
        XCTAssertTrue(firstPage.hasMoreBefore)
        let cursor = try XCTUnwrap(firstPage.previousCursor)

        // 翻看更早 before=cursor：必须命中缓存，能取回最早的 m0，并且不再发第二次 thread/read。
        let earlier = try await client.messagesPage(sessionID: "thr_hist", before: cursor, limit: 2)
        XCTAssertEqual(earlier.messages.map(\.content), ["m0"])
        XCTAssertFalse(earlier.hasMoreBefore)

        let sent = await transport.sentMessages()
        let threadReadCount = sent.compactMap { try? decodeAppServerRequest($0) }.filter { $0.method == "thread/read" }.count
        XCTAssertEqual(threadReadCount, 1, "翻看更早历史应命中缓存，不应再次拉取整段 thread/read")
    }

    func testDirectRuntimePreservesHistoryImagePayloadAsLazyMedia() async throws {
        let project = AgentProject(id: "proj_hist_image", name: "Hist Image", path: "/tmp/hist-image")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist_image", before: nil, limit: 10)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist_image","sessionId":"thr_hist_image","preview":"hist image","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/hist-image","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"hist image","turns":[{"id":"turn_img","startedAt":1780490000,"items":[{"type":"userMessage","id":"item_img","content":[{"type":"text","text":"看这张截图"},{"type":"image","url":"agentd-history-media://media_abc","detail":"high","redacted":true,"contentType":"image/png","byteCount":2048}]},{"type":"imageGeneration","id":"exec-generated","status":"completed","result":"agentd-history-media://media_generated","resultContentType":"image/png","resultByteCount":1349508,"resultRedacted":true,"savedPath":"/Users/me/.codex/generated_images/thread/exec-generated.png"},{"type":"imageView","id":"view-simulator","path":"/tmp/simulator screen.png"}]}]}}}"#)

        let page = try await pageTask.value
        let message = try XCTUnwrap(page.messages.first { $0.role == "user" })
        XCTAssertEqual(message.content, "看这张截图")
        XCTAssertEqual(message.turnPayload?.textPrompt, "看这张截图")
        XCTAssertTrue(payloadContainsImageURL(message.turnPayload, url: "agentd-history-media://media_abc"))
        XCTAssertEqual(
            page.messages.first { $0.itemID == "exec-generated" }?.content,
            "![生成的图片](agentd-history-media://media_generated)"
        )
        XCTAssertEqual(
            page.messages.first { $0.itemID == "view-simulator" }?.content,
            "![截图](file:///tmp/simulator%20screen.png)"
        )

        let conversationStore = ConversationStore()
        conversationStore.replaceHistorySnapshot(page.messages, sessionID: "thr_hist_image")
        let projected = conversationStore.messages(for: "thr_hist_image")
        XCTAssertTrue(payloadContainsImageURL(
            projected.first { $0.role == .user }?.turnPayload,
            url: "agentd-history-media://media_abc"
        ))
        XCTAssertEqual(projected.filter { $0.role == .assistant }.count, 2)
    }

    func testDirectRuntimeParsesHistoryTurnDatesFromISOAndMilliseconds() async throws {
        let project = AgentProject(id: "proj_hist_dates", name: "Hist Dates", path: "/tmp/hist-dates")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist_dates", before: nil, limit: 10)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist_dates","sessionId":"thr_hist_dates","preview":"hist dates","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/hist-dates","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"hist dates","turns":[{"id":"turn_iso","startedAt":"2026-07-01T18:16:00.000Z","completedAt":"2026-07-01T18:16:01.154Z","items":[{"type":"userMessage","id":"user_iso","content":[{"type":"text","text":"iso user"}]},{"type":"agentMessage","id":"assistant_iso","text":"iso assistant","phase":"final_answer"}]},{"id":"turn_ms","startedAt":1782929761154,"completedAt":"1782929762123","items":[{"type":"userMessage","id":"user_ms","content":[{"type":"text","text":"ms user"}]},{"type":"agentMessage","id":"assistant_ms","text":"ms assistant","phase":"final_answer"}]},{"id":"turn_snake","started_at":"2026-07-01T19:00:00.000Z","completed_at":"2026-07-01T19:00:02.000Z","items":[{"type":"userMessage","id":"user_snake","content":[{"type":"text","text":"snake user"}]},{"type":"agentMessage","id":"assistant_snake","text":"snake assistant","phase":"final_answer"}]},{"id":"turn_item_only","items":[{"type":"userMessage","id":"user_item","created_at":1782932403,"content":[{"type":"text","text":"item user"}]},{"type":"agentMessage","id":"assistant_item","updated_at":"2026-07-01T19:00:04.500Z","text":"item assistant","phase":"final_answer"}]}]}}}"#)

        let page = try await pageTask.value
        let isoUser = try XCTUnwrap(page.messages.first { $0.content == "iso user" })
        let isoAssistant = try XCTUnwrap(page.messages.first { $0.content == "iso assistant" })
        let msUser = try XCTUnwrap(page.messages.first { $0.content == "ms user" })
        let msAssistant = try XCTUnwrap(page.messages.first { $0.content == "ms assistant" })
        let snakeUser = try XCTUnwrap(page.messages.first { $0.content == "snake user" })
        let snakeAssistant = try XCTUnwrap(page.messages.first { $0.content == "snake assistant" })
        let itemUser = try XCTUnwrap(page.messages.first { $0.content == "item user" })
        let itemAssistant = try XCTUnwrap(page.messages.first { $0.content == "item assistant" })

        XCTAssertEqual(try XCTUnwrap(isoUser.createdAt).timeIntervalSince1970, 1_782_929_760, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(isoAssistant.createdAt).timeIntervalSince1970, 1_782_929_761.154, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(isoAssistant.updatedAt).timeIntervalSince1970, 1_782_929_761.154, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(msUser.createdAt).timeIntervalSince1970, 1_782_929_761.154, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(msAssistant.createdAt).timeIntervalSince1970, 1_782_929_762.123, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(msAssistant.updatedAt).timeIntervalSince1970, 1_782_929_762.123, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snakeUser.createdAt).timeIntervalSince1970, 1_782_932_400, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snakeAssistant.createdAt).timeIntervalSince1970, 1_782_932_402, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(itemUser.createdAt).timeIntervalSince1970, 1_782_932_403, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(itemAssistant.createdAt).timeIntervalSince1970, 1_782_932_404.5, accuracy: 0.001)
        XCTAssertTrue(isoUser.isTimestampFallback)
        XCTAssertFalse(isoAssistant.isTimestampFallback)
        XCTAssertTrue(msUser.isTimestampFallback)
        XCTAssertFalse(msAssistant.isTimestampFallback)
        XCTAssertTrue(snakeUser.isTimestampFallback)
        XCTAssertFalse(snakeAssistant.isTimestampFallback)
        XCTAssertFalse(itemUser.isTimestampFallback)
        XCTAssertFalse(itemAssistant.isTimestampFallback)
    }

    func testDirectRuntimeStampsActiveSnapshotItemsWithReadTime() async throws {
        let project = AgentProject(id: "proj_hist_active_time", name: "Hist Active", path: "/tmp/hist-active")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist_active_time", before: nil, limit: 10)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        let lowerBound = Date()
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist_active_time","sessionId":"thr_hist_active_time","preview":"active time","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active"},"path":null,"cwd":"/tmp/hist-active","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"active time","turns":[{"id":"turn_live_time","startedAt":1780490000,"status":"inProgress","items":[{"type":"userMessage","id":"user_live","content":[{"type":"text","text":"继续观察"}]},{"type":"commandExecution","id":"cmd_live","command":"go test ./...","status":"running"},{"type":"commandExecution","id":"cmd_failed","command":"xcodebuild test","status":"failed"},{"type":"agentMessage","id":"assistant_live","text":"还在输出日志","phase":"final_answer"}]}]}}}"#)

        let page = try await pageTask.value
        let upperBound = Date()
        let user = try XCTUnwrap(page.messages.first { $0.content == "继续观察" })
        let command = try XCTUnwrap(page.messages.first { $0.content.contains("go test ./...") })
        let failedCommand = try XCTUnwrap(page.messages.first { $0.content.contains("xcodebuild test") })
        let assistant = try XCTUnwrap(page.messages.first { $0.content == "还在输出日志" })

        XCTAssertNil(user.updatedAt)
        XCTAssertNil(failedCommand.updatedAt)
        for message in [command, assistant] {
            let updatedAt = try XCTUnwrap(message.updatedAt)
            XCTAssertGreaterThan(updatedAt, try XCTUnwrap(message.createdAt))
            XCTAssertGreaterThanOrEqual(updatedAt.timeIntervalSince1970, lowerBound.addingTimeInterval(-1).timeIntervalSince1970)
            XCTAssertLessThanOrEqual(updatedAt.timeIntervalSince1970, upperBound.addingTimeInterval(1).timeIntervalSince1970)
        }
    }

    func testDirectRuntimeMarksMissingHistoryTimestampsAsFallback() async throws {
        let project = AgentProject(id: "proj_hist_fallback", name: "Hist Fallback", path: "/tmp/hist-fallback")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist_fallback", before: nil, limit: 10)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist_fallback","sessionId":"thr_hist_fallback","preview":"hist fallback","ephemeral":false,"modelProvider":"openai","createdAt":1780490400,"updatedAt":1780490500,"status":{"type":"idle"},"path":null,"cwd":"/tmp/hist-fallback","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"hist fallback","turns":[{"id":"turn_missing","items":[{"type":"userMessage","id":"user_missing","content":[{"type":"text","text":"missing user"}]},{"type":"agentMessage","id":"assistant_missing","text":"missing assistant","phase":"final_answer"}]}]}}}"#)

        let page = try await pageTask.value
        XCTAssertEqual(page.messages.map(\.content), ["missing user", "missing assistant"])
        XCTAssertTrue(page.messages.allSatisfy(\.isTimestampFallback))
        XCTAssertEqual(try XCTUnwrap(page.messages.first?.createdAt).timeIntervalSince1970, 1_780_490_500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(page.messages.last?.createdAt).timeIntervalSince1970, 1_780_490_500, accuracy: 0.001)
    }

    func testDirectRuntimeMarksMiddleUserMessageAsInjectedServerFact() async throws {
        let project = AgentProject(id: "proj_hist_injected", name: "Hist Injected", path: "/tmp/hist-injected")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist_injected", before: nil, limit: 10)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist_injected","sessionId":"thr_hist_injected","preview":"injected","ephemeral":false,"modelProvider":"openai","createdAt":1780490600,"updatedAt":1780490630,"status":{"type":"idle"},"path":null,"cwd":"/tmp/hist-injected","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"injected","turns":[{"id":"turn_injected","startedAt":1780490600,"completedAt":1780490630,"items":[{"type":"userMessage","id":"user_initial","clientId":"client_initial","content":[{"type":"text","text":"先排查"}]},{"type":"agentMessage","id":"commentary_injected","text":"我先看当前状态。","phase":"commentary"},{"type":"userMessage","id":"user_mid","clientId":"client_mid","content":[{"type":"text","text":"要求后续变更"}]},{"type":"agentMessage","id":"assistant_injected","text":"已按后续要求完成。","phase":"final_answer"}]}]}}}"#)

        let page = try await pageTask.value
        XCTAssertEqual(page.messages.map(\.content), ["先排查", "我先看当前状态。", "要求后续变更", "已按后续要求完成。"])
        let firstUser = try XCTUnwrap(page.messages.first { $0.content == "先排查" })
        let middleUser = try XCTUnwrap(page.messages.first { $0.content == "要求后续变更" })

        XCTAssertNil(firstUser.userDelivery)
        XCTAssertEqual(middleUser.userDelivery, .injected)
        XCTAssertLessThan(try XCTUnwrap(firstUser.timelineOrdinal), try XCTUnwrap(middleUser.timelineOrdinal))
    }

}
