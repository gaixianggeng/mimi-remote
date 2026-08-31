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
