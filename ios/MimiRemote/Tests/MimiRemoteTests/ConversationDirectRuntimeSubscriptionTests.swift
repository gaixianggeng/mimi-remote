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
                    transport: "unix",
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
        let thread = #"{"id":"thr_unsubscribe_lease","sessionId":"thr_unsubscribe_lease","preview":"订阅代次","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"idle"},"path":null,"cwd":"/tmp/unsubscribe-lease","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"订阅代次","turns":[]}"#

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
}
