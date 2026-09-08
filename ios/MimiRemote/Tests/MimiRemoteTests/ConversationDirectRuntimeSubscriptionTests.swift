import XCTest
@testable import MimiRemote

private actor FirstConfigRequestGate {
    private let config: CodexAppServerConfigResponse
    private var callCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(config: CodexAppServerConfigResponse) {
        self.config = config
    }

    func next() async -> CodexAppServerConfigResponse {
        callCount += 1
        if callCount == 1 {
            let waiters = firstStartWaiters
            firstStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return config
    }

    func waitUntilFirstRequestStarts() async {
        if callCount > 0 { return }
        await withCheckedContinuation { continuation in
            firstStartWaiters.append(continuation)
        }
    }

    func releaseFirstRequest() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

@MainActor
extension ConversationDataFlowTests {
    func testMimiTaskIdentityUsesCallIDInsteadOfJSONRPCIDAndRejectsReplay() async throws {
        let project = AgentProject(id: "proj_identity", name: "Identity", path: "/tmp/identity")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "identity-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let pageTask = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
        let initialList = try await waitForFakeAppServerRequest(transport, method: "thread/list")
        let caller = #"{"id":"caller-identity","sessionId":"caller-identity","preview":"","ephemeral":false,"createdAt":1,"updatedAt":2,"status":{"type":"idle"},"cwd":"/tmp/identity","source":"appServer","name":"Caller","turns":[]}"#
        transportResponse(transport, id: initialList.id, result: "{\"data\":[\(caller)],\"nextCursor\":null}")
        _ = try await pageTask.value

        let requestCursor = await transport.sentMessages().count
        for callID in ["call-one", "call-two"] {
            transport.enqueue(#"{"id":"reused-rpc-id","method":"item/tool/call","params":{"namespace":"mimi_tasks","tool":"list_threads","threadId":"caller-identity","turnId":"turn-identity","callId":"\#(callID)","arguments":{}}}"#)
        }
        let first = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/list",
            after: requestCursor
        )
        let second = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/list",
            after: requestCursor + 1
        )
        transportResponse(transport, id: first.id, result: #"{"data":[],"nextCursor":null}"#)
        transportResponse(transport, id: second.id, result: #"{"data":[],"nextCursor":null}"#)

        transport.enqueue(#"{"id":"replay-rpc-id","method":"item/tool/call","params":{"namespace":"mimi_tasks","tool":"list_threads","threadId":"caller-identity","turnId":"turn-identity","callId":"call-one","arguments":{}}}"#)
        let replay = try await waitForFakeAppServerResponse(transport, id: .string("replay-rpc-id"))
        let text = replay.result?.objectValue?["contentItems"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        XCTAssertEqual(replay.result?.objectValue?["success"]?.boolValue, false)
        XCTAssertEqual(text, #"{"error":"duplicate_call"}"#)
    }

    func testMimiTaskDispatcherRejectsWrongNamespaceWithSafeToolResult() async throws {
        let project = AgentProject(id: "proj_tasks", name: "Tasks", path: "/tmp/tasks")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "tasks-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list")
        transportResponse(transport, id: list.id, result: #"{"data":[],"nextCursor":null}"#)
        _ = try await pageTask.value

        transport.enqueue(#"{"id":"tool-wrong-namespace","method":"item/tool/call","params":{"namespace":"other","tool":"read_thread","threadId":"caller","turnId":"turn-caller","callId":"call-wrong-namespace","arguments":{"threadId":"target"}}}"#)
        let response = try await waitForFakeAppServerResponse(transport, id: .string("tool-wrong-namespace"))
        let result = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(result["success"]?.boolValue, false)
        let item = try XCTUnwrap(result["contentItems"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(item["type"]?.stringValue, "inputText")
        XCTAssertEqual(item["text"]?.stringValue, #"{"error":"unsupported_tool"}"#)
    }

    func testMimiTaskWaitTreatsIdleThreadAsTerminalWithoutWaiting() async throws {
        let project = AgentProject(id: "proj_wait", name: "Wait", path: "/tmp/wait")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "wait-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list")
        let thread = #"{"id":"caller-wait","sessionId":"caller-wait","preview":"","ephemeral":false,"createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"cwd":"/tmp/wait","source":"appServer","name":"Caller","turns":[]}"#
        transportResponse(transport, id: list.id, result: "{\"data\":[\(thread)],\"nextCursor\":null}")
        _ = try await pageTask.value

        let readCursor = await transport.sentMessages().count
        transport.enqueue(#"{"id":"tool-wait","method":"item/tool/call","params":{"namespace":"mimi_tasks","tool":"wait_threads","threadId":"caller-wait","turnId":"turn-wait","callId":"call-wait","arguments":{"threadIds":["caller-wait"],"timeoutMs":120000}}}"#)
        let read = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/read",
            after: readCursor
        )
        transportResponse(transport, id: read.id, result: "{\"thread\":\(thread)}")
        let response = try await waitForFakeAppServerResponse(transport, id: .string("tool-wait"))
        XCTAssertEqual(response.result?.objectValue?["success"]?.boolValue, true)
        let text = response.result?.objectValue?["contentItems"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        XCTAssertTrue(text?.contains(#""timedOut":false"#) == true)
    }

    func testMimiTaskReadReturnsRecentTaskOutput() async throws {
        let project = AgentProject(id: "proj_read", name: "Read", path: "/tmp/read")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "read-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list")
        let thread = #"{"id":"caller-read","sessionId":"caller-read","preview":"","ephemeral":false,"createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"cwd":"/tmp/read","source":"appServer","name":"Caller","turns":[]}"#
        transportResponse(transport, id: list.id, result: "{\"data\":[\(thread)],\"nextCursor\":null}")
        _ = try await pageTask.value

        transport.enqueue(#"{"id":"tool-read","method":"item/tool/call","params":{"namespace":"mimi_tasks","tool":"read_thread","threadId":"caller-read","turnId":"turn-read","callId":"call-read","arguments":{"threadId":"caller-read"}}}"#)
        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        transportResponse(transport, id: read.id, result: "{\"thread\":\(thread)}")
        let turns = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        transportResponse(
            transport,
            id: turns.id,
            result: #"{"data":[{"id":"turn-read","itemsView":"summary","status":"completed","items":[{"type":"agentMessage","id":"answer-read","text":"任务已经完成","phase":"final_answer"}]}],"nextCursor":null}"#
        )
        let response = try await waitForFakeAppServerResponse(transport, id: .string("tool-read"))
        let text = response.result?.objectValue?["contentItems"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        XCTAssertTrue(text?.contains("任务已经完成") == true)
    }

    func testCodexAuthoritativeFirstPageReadsFreshIndexIncludingExternalUnarchive() async throws {
        let project = AgentProject(id: "fresh-index", name: "Fresh Index", path: "/tmp/fresh-index")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let firstTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20, consistency: .authoritative)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex"}"#)
        let firstList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        XCTAssertEqual(firstList.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
        let existing = appServerThreadJSON(id: "existing", cwd: project.path, source: "appServer", updatedAt: 200)
        transportResponse(transport, id: firstList.id, result: appServerThreadListResult([existing], nextCursor: nil))
        let firstPage = try await firstTask.value
        XCTAssertEqual(firstPage.sessions.map(\.id), ["existing"])

        let sentBeforeRefresh = await transport.sentMessages().count
        let refreshTask = Task {
            try await runtime.sessionsPage(
                workspace: AgentWorkspace(project: project), cursor: nil, limit: 20, consistency: .authoritative
            )
        }
        let freshList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: sentBeforeRefresh)
        XCTAssertEqual(freshList.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
        XCTAssertEqual(freshList.params?.objectValue?["sortKey"]?.stringValue, "recency_at")
        XCTAssertNil(freshList.params?.objectValue?["refreshHistory"])
        let restored = appServerThreadJSON(id: "externally-unarchived", cwd: project.path, source: "appServer", updatedAt: 300)
        transportResponse(transport, id: freshList.id, result: appServerThreadListResult([restored, existing], nextCursor: nil))
        let refreshed = try await refreshTask.value
        XCTAssertEqual(refreshed.sessions.map(\.id), ["externally-unarchived", "existing"])
    }

    func testCodexAuthoritativeEmptyIndexFallsBackToHistoryScan() async throws {
        let project = AgentProject(id: "empty-index", name: "Empty Index", path: "/tmp/empty-index")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20, consistency: .authoritative)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex"}"#)
        let indexedList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        XCTAssertEqual(indexedList.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
        let sentBeforeScan = await transport.sentMessages().count
        transportResponse(transport, id: indexedList.id, result: appServerThreadListResult([], nextCursor: nil))
        let scan = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: sentBeforeScan)
        XCTAssertEqual(scan.params?.objectValue?["useStateDbOnly"]?.boolValue, false)
        let recovered = appServerThreadJSON(id: "history-only", cwd: project.path, source: "appServer", updatedAt: 200)
        transportResponse(transport, id: scan.id, result: appServerThreadListResult([recovered], nextCursor: nil))
        let page = try await pageTask.value
        XCTAssertEqual(page.sessions.map(\.id), ["history-only"])
    }

    func testClaudeAuthoritativeFirstPageRequestsHistoryRefresh() async throws {
        let project = AgentProject(
            id: "proj_claude_history_refresh",
            name: "Claude History Refresh",
            path: "/tmp/claude-history-refresh"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/list"],
                    channels: [makeClaudeChannelMetadata()]
                )
            }
        )

        let pageTask = Task {
            try await runtime.sessionsPage(
                projectID: project.id,
                cursor: nil,
                limit: 20,
                consistency: .authoritative
            )
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        XCTAssertEqual(list.params?.objectValue?["useStateDbOnly"]?.boolValue, false)
        XCTAssertEqual(list.params?.objectValue?["refreshHistory"]?.boolValue, true)
        transportResponse(transport, id: list.id, result: #"{"data":[],"nextCursor":null}"#)

        let page = try await pageTask.value
        XCTAssertTrue(page.sessions.isEmpty)
    }

    func testClaudeHistoryRefreshPolicyAndRecoveryCommand() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        let request = try builder.threadList(
            cwd: project.path,
            useStateDBOnly: false,
            refreshHistory: true
        )
        let params = try XCTUnwrap(request.params?.objectValue)
        XCTAssertEqual(params["refreshHistory"]?.boolValue, true)

        XCTAssertTrue(
            CodexAppServerSessionRuntime.shouldRefreshHistory(
                runtimeProvider: "claude",
                consistency: .authoritative,
                cursor: nil
            )
        )
        XCTAssertFalse(
            CodexAppServerSessionRuntime.shouldRefreshHistory(
                runtimeProvider: "claude",
                consistency: .authoritative,
                cursor: "older"
            )
        )
        XCTAssertFalse(
            CodexAppServerSessionRuntime.shouldRefreshHistory(
                runtimeProvider: "claude",
                consistency: .fastIndexed,
                cursor: nil
            )
        )
        XCTAssertFalse(
            CodexAppServerSessionRuntime.shouldRefreshHistory(
                runtimeProvider: "codex",
                consistency: .authoritative,
                cursor: nil
            )
        )

        XCTAssertEqual(
            ClaudeSessionRecoveryCommand.make(
                sessionID: "session'42",
                cwd: "/Users/me/it's repo",
                hostPlatform: .apple
            ),
            #"cd '/Users/me/it'\''s repo' && claude --resume 'session'\''42'"#
        )
        XCTAssertEqual(
            ClaudeSessionRecoveryCommand.make(
                sessionID: "session'42",
                cwd: #"C:\Users\O'Brien Repo"#,
                hostPlatform: .windows
            ),
            #"Set-Location -LiteralPath 'C:\Users\O''Brien Repo' -ErrorAction Stop; claude --resume 'session''42'"#
        )
    }

    func testConnectSuspendedBeforeHydrationCannotOverrideNewerUnsubscribeLease() async throws {
        let project = AgentProject(
            id: "proj_connect_hydration_lease",
            name: "Connect Hydration Lease",
            path: "/tmp/connect-hydration-lease"
        )
        let transport = FakeCodexAppServerTransport()
        let config = makeDirectAppServerConfig(
            project: project,
            allowedMethods: [
                "initialize",
                "initialized",
                "thread/read",
                "thread/resume",
                "thread/unsubscribe"
            ]
        )
        let configGate = FirstConfigRequestGate(config: config)
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { await configGate.next() }
        )
        let threadID = "thr_connect_hydration_lease"
        let thread = #"{"id":"thr_connect_hydration_lease","sessionId":"thr_connect_hydration_lease","preview":"连接代次","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"idle"},"path":null,"cwd":"/tmp/connect-hydration-lease","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"连接代次","turns":[]}"#

        let staleConnect = Task {
            try await runtime.connectForEvents(sessionID: threadID)
        }
        await configGate.waitUntilFirstRequestStarts()

        let unsubscribe = Task {
            try await runtime.unsubscribeThread(threadID: threadID)
        }
        let unsubscribeStatus = try await unsubscribe.value
        XCTAssertEqual(unsubscribeStatus, .notSubscribed)

        await configGate.releaseFirstRequest()
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let read = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/read"
        )
        transportResponse(transport, id: read.id, result: #"{"thread":\#(thread)}"#)
        try await staleConnect.value

        let requests = await transport.sentMessages().compactMap {
            try? decodeAppServerRequest($0)
        }
        XCTAssertEqual(requests.filter { $0.method == "thread/unsubscribe" }.count, 0)
        XCTAssertEqual(
            requests.filter { $0.method == "thread/resume" }.count,
            0,
            "旧 connect 恢复后不能覆盖更新一代退订意图"
        )
    }

    func testLateThreadUnsubscribeCannotOverrideNewerSubscriptionLease() async throws {
        let project = AgentProject(
            id: "proj_unsubscribe_lease",
            name: "Unsubscribe Lease",
            path: "/tmp/unsubscribe-lease"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: [
                        "initialize",
                        "initialized",
                        "thread/list",
                        "thread/resume",
                        "thread/unsubscribe"
                    ]
                )
            }
        )
        let threadID = "thr_unsubscribe_lease"
        let thread = #"{"id":"thr_unsubscribe_lease","sessionId":"thr_unsubscribe_lease","preview":"订阅代次","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/unsubscribe-lease","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"订阅代次","turns":[]}"#

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
        transportResponse(transport, id: list.id, result: #"{"data":[\#(thread)],"nextCursor":null}"#)
        _ = try await pageTask.value

        let initialConnect = Task {
            try await runtime.connectForEvents(sessionID: threadID)
        }
        let initialResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: 2
        )
        transportResponse(transport, id: initialResume.id, result: #"{"thread":\#(thread)}"#)
        try await initialConnect.value

        let unsubscribe = Task {
            try await runtime.unsubscribeThread(threadID: threadID)
        }
        let unsubscribeRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/unsubscribe",
            after: 3
        )
        let messagesAfterUnsubscribe = await transport.sentMessages().count

        // 旧退订仍在等待响应时重新进入同一会话；新 lease 必须真的发送 resume。
        let reopen = Task {
            try await runtime.connectForEvents(sessionID: threadID)
        }
        let reopenResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: messagesAfterUnsubscribe
        )
        transportResponse(transport, id: reopenResume.id, result: #"{"thread":\#(thread)}"#)
        try await reopen.value

        // 让旧 unsubscribe 最后返回，复现“迟到退订覆盖新订阅”。runtime 应按当前
        // generation 再确认一次 resume，使服务端最终状态与最新页面一致。
        let messagesBeforeLateResponse = await transport.sentMessages().count
        transportResponse(
            transport,
            id: unsubscribeRequest.id,
            result: #"{"status":"unsubscribed"}"#
        )
        let reassertedResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: messagesBeforeLateResponse
        )
        transportResponse(transport, id: reassertedResume.id, result: #"{"thread":\#(thread)}"#)

        let status = try await unsubscribe.value
        XCTAssertEqual(status, .unsubscribed)
        let requests = await transport.sentMessages().compactMap {
            try? decodeAppServerRequest($0)
        }
        XCTAssertEqual(requests.filter { $0.method == "thread/unsubscribe" }.count, 1)
        XCTAssertEqual(requests.filter { $0.method == "thread/resume" }.count, 3)
    }

    func testLastEventObserverUnsubscribesThreadOnlyOnce() async throws {
        let project = AgentProject(id: "proj_last_observer", name: "Last Observer", path: "/tmp/last-observer")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: [
                        "initialize", "initialized", "thread/list", "thread/resume", "thread/unsubscribe"
                    ]
                )
            }
        )
        let threadID = "thr_last_observer"
        let thread = #"{"id":"thr_last_observer","sessionId":"thr_last_observer","preview":"最后观察者","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/last-observer","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"最后观察者","turns":[]}"#
        let pageTask = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: list.id, result: #"{"data":[\#(thread)],"nextCursor":null}"#)
        _ = try await pageTask.value
        let first = await runtime.attachEvents(sessionID: threadID)
        let second = await runtime.attachEvents(sessionID: threadID)
        let connect = Task { try await runtime.connectForEvents(sessionID: threadID) }
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 2)
        transportResponse(transport, id: resume.id, result: #"{"thread":\#(thread)}"#)
        try await connect.value

        first.cancel()
        for _ in 0..<10 { await Task.yield() }
        let observerCount = await runtime.eventMailboxesBySessionID[threadID]?.count
        let requestsAfterFirstCancel = await transport.sentMessages().compactMap {
            try? decodeAppServerRequest($0)
        }
        XCTAssertEqual(observerCount, 1)
        XCTAssertEqual(requestsAfterFirstCancel.filter { $0.method == "thread/unsubscribe" }.count, 0)

        second.cancel()
        let unsubscribe = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/unsubscribe",
            after: 3
        )
        transportResponse(transport, id: unsubscribe.id, result: #"{"status":"unsubscribed"}"#)

        for _ in 0..<10 { await Task.yield() }
        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        let remainsResumed = await runtime.threadsResumedOnConnection.contains(threadID)
        XCTAssertEqual(requests.filter { $0.method == "thread/unsubscribe" }.count, 1)
        XCTAssertFalse(remainsResumed)
    }

    func testLastObserverRetriesFailedUnsubscribeOnExistingConnection() async throws {
        let project = AgentProject(id: "proj_retry_unsubscribe", name: "Retry Unsubscribe", path: "/tmp/retry-unsubscribe")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/list", "thread/resume", "thread/unsubscribe"]
                )
            }
        )
        let threadID = "thr_retry_unsubscribe"
        let thread = #"{"id":"thr_retry_unsubscribe","sessionId":"thr_retry_unsubscribe","preview":"重试退订","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/retry-unsubscribe","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"重试退订","turns":[]}"#
        let pageTask = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: list.id, result: #"{"data":[\#(thread)],"nextCursor":null}"#)
        _ = try await pageTask.value
        let events = await runtime.attachEvents(sessionID: threadID)
        let connect = Task { try await runtime.connectForEvents(sessionID: threadID) }
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 2)
        transportResponse(transport, id: resume.id, result: #"{"thread":\#(thread)}"#)
        try await connect.value

        events.cancel()
        let first = try await waitForFakeAppServerRequest(transport, method: "thread/unsubscribe", after: 3)
        let messagesAfterFirst = await transport.sentMessages().count
        transportErrorResponse(transport, id: first.id, code: -32603, message: "temporary failure")
        let retry = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/unsubscribe",
            after: messagesAfterFirst
        )
        transportResponse(transport, id: retry.id, result: #"{"status":"unsubscribed"}"#)

        for _ in 0..<20 {
            if await runtime.threadUnsubscribeRetryTasksBySessionID[threadID] == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        let retryTask = await runtime.threadUnsubscribeRetryTasksBySessionID[threadID]
        XCTAssertEqual(requests.filter { $0.method == "thread/unsubscribe" }.count, 2)
        XCTAssertEqual(requests.filter { $0.method == "initialize" }.count, 1)
        XCTAssertNil(retryTask)
    }

    func testObserverReentryCancelsAndDeduplicatesUnsubscribeRetry() async throws {
        let project = AgentProject(id: "proj_cancel_retry", name: "Cancel Retry", path: "/tmp/cancel-retry")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/list", "thread/resume", "thread/unsubscribe"]
                )
            }
        )
        let threadID = "thr_cancel_retry"
        let thread = #"{"id":"thr_cancel_retry","sessionId":"thr_cancel_retry","preview":"取消重试","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/cancel-retry","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"取消重试","turns":[]}"#
        let pageTask = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: list.id, result: #"{"data":[\#(thread)],"nextCursor":null}"#)
        _ = try await pageTask.value
        let firstEvents = await runtime.attachEvents(sessionID: threadID)
        let initialConnect = Task { try await runtime.connectForEvents(sessionID: threadID) }
        let initialResume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 2)
        transportResponse(transport, id: initialResume.id, result: #"{"thread":\#(thread)}"#)
        try await initialConnect.value

        firstEvents.cancel()
        let first = try await waitForFakeAppServerRequest(transport, method: "thread/unsubscribe", after: 3)
        let messagesAfterFirst = await transport.sentMessages().count
        transportErrorResponse(transport, id: first.id, code: -32603, message: "temporary failure")
        let retry = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/unsubscribe",
            after: messagesAfterFirst
        )
        transportErrorResponse(transport, id: retry.id, code: -32603, message: "temporary failure")

        let reopenedEvents = await runtime.attachEvents(sessionID: threadID)
        let reopen = Task { try await runtime.connectForEvents(sessionID: threadID) }
        let reopenResume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 5)
        transportResponse(transport, id: reopenResume.id, result: #"{"thread":\#(thread)}"#)
        try await reopen.value
        try await Task.sleep(nanoseconds: 400_000_000)

        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        let retryTask = await runtime.threadUnsubscribeRetryTasksBySessionID[threadID]
        XCTAssertEqual(requests.filter { $0.method == "thread/unsubscribe" }.count, 2)
        XCTAssertEqual(requests.filter { $0.method == "initialize" }.count, 1)
        XCTAssertNil(retryTask)
        await runtime.finishAttachedEventStreams()
        reopenedEvents.cancel()
    }

    func testNewFalseLeaseReplacesOlderUnsubscribeRetry() async throws {
        let project = AgentProject(id: "proj_replace_retry", name: "Replace Retry", path: "/tmp/replace-retry")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/list", "thread/resume", "thread/unsubscribe"]
                )
            }
        )
        let threadID = "thr_replace_retry"
        let thread = #"{"id":"thr_replace_retry","sessionId":"thr_replace_retry","preview":"替换重试","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/replace-retry","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"替换重试","turns":[]}"#
        let pageTask = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: list.id, result: #"{"data":[\#(thread)],"nextCursor":null}"#)
        _ = try await pageTask.value
        let connect = Task { try await runtime.connectForEvents(sessionID: threadID) }
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 2)
        transportResponse(transport, id: resume.id, result: #"{"thread":\#(thread)}"#)
        try await connect.value

        let firstCleanup = Task {
            try await runtime.unsubscribeThread(threadID: threadID, usingExistingConnectionOnly: true)
        }
        let first = try await waitForFakeAppServerRequest(transport, method: "thread/unsubscribe", after: 3)
        let messagesAfterFirst = await transport.sentMessages().count
        transportErrorResponse(transport, id: first.id, code: -32603, message: "first failure")
        do {
            _ = try await firstCleanup.value
            XCTFail("首次退订应失败")
        } catch {}
        let oldRetry = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/unsubscribe",
            after: messagesAfterFirst
        )
        transportErrorResponse(transport, id: oldRetry.id, code: -32603, message: "old retry failure")

        let messagesBeforeNewLease = await transport.sentMessages().count
        let secondCleanup = Task {
            try await runtime.unsubscribeThread(threadID: threadID, usingExistingConnectionOnly: true)
        }
        let second = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/unsubscribe",
            after: messagesBeforeNewLease
        )
        let messagesAfterSecond = await transport.sentMessages().count
        transportErrorResponse(transport, id: second.id, code: -32603, message: "second failure")
        do {
            _ = try await secondCleanup.value
            XCTFail("第二代退订应失败")
        } catch {}
        let newRetry = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/unsubscribe",
            after: messagesAfterSecond
        )
        transportResponse(transport, id: newRetry.id, result: #"{"status":"unsubscribed"}"#)

        for _ in 0..<20 {
            if await runtime.threadUnsubscribeRetryTasksBySessionID[threadID] == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        let retryTask = await runtime.threadUnsubscribeRetryTasksBySessionID[threadID]
        XCTAssertEqual(requests.filter { $0.method == "thread/unsubscribe" }.count, 4)
        XCTAssertNil(retryTask)
    }

    func testProducerFinishDoesNotCreateConnectionToUnsubscribe() async {
        let project = AgentProject(id: "proj_producer_finish", name: "Producer Finish", path: "/tmp/producer-finish")
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
        let threadID = "thr_producer_finish"
        let thread = #"{"id":"thr_producer_finish","sessionId":"thr_producer_finish","preview":"生产者结束","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/producer-finish","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"生产者结束","turns":[]}"#
        let pageTask = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try! await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let list = try! await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: list.id, result: #"{"data":[\#(thread)],"nextCursor":null}"#)
        _ = try! await pageTask.value
        let events = await runtime.attachEvents(sessionID: threadID)
        let connect = Task { try await runtime.connectForEvents(sessionID: threadID) }
        let resume = try! await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 2)
        transportResponse(transport, id: resume.id, result: #"{"thread":\#(thread)}"#)
        _ = try! await connect.value

        await runtime.finishAttachedEventStreams()
        events.cancel()
        for _ in 0..<10 { await Task.yield() }

        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        let lease = await runtime.threadSubscriptionLeaseBySessionID[threadID]
        XCTAssertEqual(requests.filter { $0.method == "thread/unsubscribe" }.count, 0)
        XCTAssertTrue(lease?.wantsEvents == true)
    }

    func testObserverCancelDuringPhysicalDisconnectDoesNotReconnectToUnsubscribe() async throws {
        let project = AgentProject(id: "proj_disconnect_cancel", name: "Disconnect Cancel", path: "/tmp/disconnect-cancel")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: [
                        "initialize", "initialized", "thread/list", "thread/resume", "thread/unsubscribe"
                    ]
                )
            }
        )
        let threadID = "thr_disconnect_cancel"
        let thread = #"{"id":"thr_disconnect_cancel","sessionId":"thr_disconnect_cancel","preview":"断线取消","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/disconnect-cancel","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"断线取消","turns":[]}"#
        let pageTask = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: list.id, result: #"{"data":[\#(thread)],"nextCursor":null}"#)
        _ = try await pageTask.value
        let events = await runtime.attachEvents(sessionID: threadID)
        let connect = Task { try await runtime.connectForEvents(sessionID: threadID) }
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 2)
        transportResponse(transport, id: resume.id, result: #"{"thread":\#(thread)}"#)
        try await connect.value

        // 固定竞态窗口：底层连接已断开，但 producer pump 尚未清理邮箱。
        // 自动退订只能放弃发送，不能通过 ensureConnection 创建第二条连接。
        let notificationPump = await runtime.notificationPumpTask
        notificationPump?.cancel()
        let activeConnection = await runtime.connection
        await activeConnection?.disconnect()
        events.cancel()
        for _ in 0..<20 { await Task.yield() }

        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(requests.filter { $0.method == "initialize" }.count, 1)
        XCTAssertEqual(requests.filter { $0.method == "thread/unsubscribe" }.count, 0)
        let lease = await runtime.threadSubscriptionLeaseBySessionID[threadID]
        XCTAssertTrue(lease?.wantsEvents == false)
    }

    func testArchiveClearsSubscriptionStateAndReopenResumesAfterUnarchive() async throws {
        let project = AgentProject(id: "proj_archive_subscription", name: "Archive Subscription", path: "/tmp/archive-subscription")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: [
                        "initialize", "initialized", "thread/archive", "thread/unarchive",
                        "thread/read", "thread/resume"
                    ]
                )
            }
        )
        let threadID = "thr_archive_subscription"
        let thread = #"{"id":"thr_archive_subscription","sessionId":"thr_archive_subscription","preview":"归档订阅","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/archive-subscription","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"归档订阅","turns":[]}"#
        let pageTask = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: list.id, result: #"{"data":[\#(thread)],"nextCursor":null}"#)
        _ = try await pageTask.value
        let events = await runtime.attachEvents(sessionID: threadID)
        let initialConnect = Task { try await runtime.connectForEvents(sessionID: threadID) }
        let initialResume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 2)
        transportResponse(transport, id: initialResume.id, result: #"{"thread":\#(thread)}"#)
        try await initialConnect.value

        let archiveTask = Task { try await runtime.setSessionArchived(id: threadID, archived: true) }
        let archive = try await waitForFakeAppServerRequest(transport, method: "thread/archive", after: 3)
        transportResponse(transport, id: archive.id, result: #"{}"#)
        try await archiveTask.value

        let remainsResumedAfterArchive = await runtime.threadsResumedOnConnection.contains(threadID)
        let leaseAfterArchive = await runtime.threadSubscriptionLeaseBySessionID[threadID]
        let observersAfterArchive = await runtime.eventMailboxesBySessionID[threadID]
        XCTAssertFalse(remainsResumedAfterArchive)
        XCTAssertNil(leaseAfterArchive)
        XCTAssertNil(observersAfterArchive)
        events.cancel()

        let unarchiveTask = Task { try await runtime.setSessionArchived(id: threadID, archived: false) }
        let unarchive = try await waitForFakeAppServerRequest(transport, method: "thread/unarchive", after: 4)
        transportResponse(transport, id: unarchive.id, result: #"{}"#)
        try await unarchiveTask.value

        let reopen = Task { try await runtime.connectForEvents(sessionID: threadID) }
        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read", after: 5)
        transportResponse(transport, id: read.id, result: #"{"thread":\#(thread)}"#)
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 6)
        transportResponse(transport, id: resume.id, result: #"{"thread":\#(thread)}"#)
        try await reopen.value
        let resumedAfterUnarchive = await runtime.threadsResumedOnConnection.contains(threadID)
        XCTAssertTrue(resumedAfterUnarchive)
    }
}

@MainActor
extension ConversationDataFlowTests {
    func testExternalArchiveDoesNotPermanentlyDisableDirectoryIndex() async throws {
        let project = AgentProject(id: "archive-index", name: "Archive Index", path: "/tmp/archive-index")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "test",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let archived = appServerThreadJSON(id: "external-archive", cwd: project.path, source: "appServer", updatedAt: 300)
        let remaining = appServerThreadJSON(id: "remaining", cwd: project.path, source: "appServer", updatedAt: 200)
        let initial = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
        let first = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: first.id, result: appServerThreadListResult([archived, remaining], nextCursor: nil))
        _ = try await initial.value

        // 首次缺失由扫描确认；之后仍访问新索引，不能把一次正常归档变成目录永久扫描。
        for round in 0..<3 {
            let sentBefore = await transport.sentMessages().count
            let refresh = Task {
                try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20, consistency: .authoritative)
            }
            let indexed = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: sentBefore)
            XCTAssertEqual(indexed.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
            let rows = round == 2 ? [archived, remaining] : [remaining]
            let beforeResponse = await transport.sentMessages().count
            transportResponse(transport, id: indexed.id, result: appServerThreadListResult(rows, nextCursor: nil))
            if round == 0 {
                let scan = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: beforeResponse)
                XCTAssertEqual(scan.params?.objectValue?["useStateDbOnly"]?.boolValue, false)
                transportResponse(transport, id: scan.id, result: appServerThreadListResult([remaining], nextCursor: nil))
            }
            let page = try await refresh.value
            XCTAssertEqual(page.sessions.map(\.id), round == 2 ? ["external-archive", "remaining"] : ["remaining"])
        }
        let verifiedMissing = await runtime.stateDBOnlyVerifiedMissingSessionIDs
        XCTAssertTrue(verifiedMissing.isEmpty, "取消归档重新返回后，不保留过期缺失记录")
    }

    func testCodexContinuationUsesIndexWithoutRepairingFirstPageRows() async throws {
        let project = AgentProject(id: "page-index", name: "Page Index", path: "/tmp/page-index")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "test",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let firstTask = Task { try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 1, consistency: .authoritative) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
        let first = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        let recent = appServerThreadJSON(id: "recent", cwd: project.path, source: "appServer", updatedAt: 300)
        transportResponse(transport, id: first.id, result: appServerThreadListResult([recent], nextCursor: "older"))
        _ = try await firstTask.value
        let beforePage = await transport.sentMessages().count
        let nextTask = Task { try await runtime.sessionsPage(projectID: project.id, cursor: "older", limit: 1, consistency: .authoritative) }
        let next = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: beforePage)
        XCTAssertEqual(next.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
        XCTAssertEqual(next.params?.objectValue?["cursor"]?.stringValue, "older")
        let old = appServerThreadJSON(id: "old", cwd: project.path, source: "appServer", updatedAt: 100)
        transportResponse(transport, id: next.id, result: appServerThreadListResult([old], nextCursor: nil))
        let page = try await nextTask.value
        XCTAssertEqual(page.sessions.map(\.id), ["old"])
    }

    func testCodexGlobalDiscoveryUsesIndexAcrossPages() async throws {
        let project = AgentProject(id: "global-index", name: "Global Index", path: "/tmp/global-index")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "test",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let firstTask = Task { try await runtime.controlledGlobalSessionsPage(cursor: nil, limit: 50) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
        let first = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        XCTAssertEqual(first.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
        XCTAssertNil(first.params?.objectValue?["cwd"])
        // 授权裁剪后的空页还有下一页时不能额外扫描历史。
        transportResponse(transport, id: first.id, result: appServerThreadListResult([], nextCursor: "opaque-next"))
        _ = try await firstTask.value
        let beforePage = await transport.sentMessages().count
        let nextTask = Task { try await runtime.controlledGlobalSessionsPage(cursor: "opaque-next", limit: 50) }
        let next = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: beforePage)
        XCTAssertEqual(next.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
        XCTAssertEqual(next.params?.objectValue?["cursor"]?.stringValue, "opaque-next")
        let row = appServerThreadJSON(id: "visible", cwd: project.path, source: "appServer", updatedAt: 100)
        transportResponse(transport, id: next.id, result: appServerThreadListResult([row], nextCursor: nil))
        let page = try await nextTask.value
        XCTAssertEqual(page.sessions.map(\.id), ["visible"])
    }

    func testCodexGlobalDiscoveryFallsBackWhenIndexUnsupported() async throws {
        let project = AgentProject(id: "legacy-index", name: "Legacy Index", path: "/tmp/legacy-index")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "test",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let task = Task { try await runtime.controlledGlobalSessionsPage(cursor: nil, limit: 50) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
        let indexed = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        let beforeError = await transport.sentMessages().count
        transportErrorResponse(transport, id: indexed.id, code: -32602, message: "useStateDbOnly unsupported")
        let scan = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: beforeError)
        XCTAssertEqual(scan.params?.objectValue?["useStateDbOnly"]?.boolValue, false)
        let row = appServerThreadJSON(id: "visible", cwd: project.path, source: "appServer", updatedAt: 100)
        transportResponse(transport, id: scan.id, result: appServerThreadListResult([row], nextCursor: nil))
        let page = try await task.value
        XCTAssertEqual(page.sessions.map(\.id), ["visible"])
        let beforeNext = await transport.sentMessages().count
        let nextTask = Task { try await runtime.controlledGlobalSessionsPage(cursor: nil, limit: 50) }
        let next = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: beforeNext)
        XCTAssertEqual(next.params?.objectValue?["useStateDbOnly"]?.boolValue, false)
        transportResponse(transport, id: next.id, result: appServerThreadListResult([row], nextCursor: nil))
        _ = try await nextTask.value
    }
}

@MainActor
extension ConversationDataFlowTests {
    func testScanFallbackContinuationKeepsItsQueryModeForDirectoryAndGlobalLists() async throws {
        let project = AgentProject(id: "scan-cursor", name: "Scan Cursor", path: "/tmp/scan-cursor")
        for global in [false, true] {
            let transport = FakeCodexAppServerTransport()
            let runtime = CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787", token: "test",
                transportFactory: { transport },
                configProvider: { makeDirectAppServerConfig(project: project) }
            )
            func page(_ cursor: String?) async throws -> SessionsPage {
                if global { return try await runtime.controlledGlobalSessionsPage(cursor: cursor, limit: 20) }
                return try await runtime.sessionsPage(projectID: project.id, cursor: cursor, limit: 20, consistency: .authoritative)
            }
            let initial = Task { try await page(nil) }
            let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
            transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
            let indexed = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
            XCTAssertEqual(indexed.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
            let beforeFallback = await transport.sentMessages().count
            transportResponse(transport, id: indexed.id, result: appServerThreadListResult([], nextCursor: nil))
            let scanned = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: beforeFallback)
            XCTAssertEqual(scanned.params?.objectValue?["useStateDbOnly"]?.boolValue, false)
            let first = appServerThreadJSON(id: "history", cwd: project.path, source: "appServer", updatedAt: 200)
            transportResponse(transport, id: scanned.id, result: appServerThreadListResult([first], nextCursor: "scan-only-cursor"))
            let firstPage = try await initial.value
            XCTAssertEqual(firstPage.nextCursor, "scan-only-cursor")

            let beforeNext = await transport.sentMessages().count
            let nextTask = Task { try await page(firstPage.nextCursor) }
            let next = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: beforeNext)
            XCTAssertEqual(next.params?.objectValue?["cursor"]?.stringValue, "scan-only-cursor")
            XCTAssertEqual(next.params?.objectValue?["useStateDbOnly"]?.boolValue, false, "扫描生成的游标不能交给索引查询")
            let second = appServerThreadJSON(id: "older-history", cwd: project.path, source: "appServer", updatedAt: 100)
            transportResponse(transport, id: next.id, result: appServerThreadListResult([second], nextCursor: nil))
            _ = try await nextTask.value

            let beforeRefresh = await transport.sentMessages().count
            let refresh = Task { try await page(nil) }
            let fresh = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: beforeRefresh)
            XCTAssertEqual(fresh.params?.objectValue?["useStateDbOnly"]?.boolValue, true, "扫描游标不能降级下一次新首屏")
            transportResponse(transport, id: fresh.id, result: appServerThreadListResult([first, second], nextCursor: nil))
            _ = try await refresh.value
        }
    }
}

@MainActor
extension ConversationDataFlowTests {
    func testGlobalIndexRepairsKnownMissingSessionsAcrossFilteredAndCompletePages() async throws {
        let project = AgentProject(id: "global-repair", name: "Global Repair", path: "/tmp/global-repair")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "test",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let known = appServerThreadJSON(id: "known", cwd: project.path, source: "appServer", updatedAt: 300)
        let remaining = appServerThreadJSON(id: "remaining", cwd: project.path, source: "appServer", updatedAt: 200)
        let firstTask = Task { try await runtime.controlledGlobalSessionsPage(cursor: nil, limit: 50) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
        let first = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: first.id, result: appServerThreadListResult([known, remaining], nextCursor: nil))
        _ = try await firstTask.value

        for round in 0..<4 {
            let beforeRefresh = await transport.sentMessages().count
            let refresh = Task { try await runtime.controlledGlobalSessionsPage(cursor: nil, limit: 50) }
            let indexed = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: beforeRefresh)
            XCTAssertEqual(indexed.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
            let beforeScan = await transport.sentMessages().count
            transportResponse(transport, id: indexed.id, result: appServerThreadListResult(
                round == 0 ? [] : [remaining], nextCursor: round == 0 ? "filtered-next" : nil
            ))
            if round < 3 {
                let scan = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: beforeScan)
                XCTAssertEqual(scan.params?.objectValue?["useStateDbOnly"]?.boolValue, false)
                // 前两次覆盖授权裁剪空页和非空索引漏行，第三次正常归档才允许免除重复扫描。
                transportResponse(transport, id: scan.id, result: appServerThreadListResult(round < 2 ? [known, remaining] : [remaining], nextCursor: nil))
            }
            let result = try await refresh.value
            XCTAssertEqual(result.sessions.map(\.id), round < 2 ? ["known", "remaining"] : ["remaining"])
        }
    }
}
