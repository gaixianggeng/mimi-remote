import XCTest
@testable import MimiRemote

/// #451：Claude 会话被 Mac 持有时的"在此设备上接管"。
@MainActor
final class ClaudeTakeoverTests: XCTestCase {
    func testThreadTakeoverBuilderSendsOnlyThreadAndAllowlistedCWD() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/tmp/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        let request = try builder.threadTakeover(threadID: "thread-held", cwd: " /tmp/repo ")
        let params = try XCTUnwrap(request.params?.objectValue)

        XCTAssertEqual(request.method, "thread/takeover")
        XCTAssertEqual(params["threadId"]?.stringValue, "thread-held")
        XCTAssertEqual(params["cwd"]?.stringValue, "/tmp/repo")
        XCTAssertEqual(params["excludeTurns"]?.boolValue, true)
        XCTAssertEqual(Set(params.keys), ["threadId", "cwd", "excludeTurns"])
        XCTAssertThrowsError(try builder.threadTakeover(threadID: "thread-held", cwd: "/tmp/elsewhere"))
    }

    func testTakeoverResultParsesSummaryAndStructuredFailure() {
        let released = CodexAppServerThreadTakeoverResult(result: .object([
            "thread": .object(["id": .string("thread-held"), "canAcceptDirectInput": .bool(true)]),
            "takeover": .object([
                "released": .bool(true),
                "signal": .string("SIGINT"),
                "holder": .object(["entrypoint": .string("cli"), "pid": .int(4242)])
            ])
        ]))
        XCTAssertEqual(
            released,
            CodexAppServerThreadTakeoverResult(released: true, holderEntrypoint: "cli", signal: "SIGINT", canAcceptDirectInput: true)
        )
        let plainResume = CodexAppServerThreadTakeoverResult(result: .object([
            "thread": .object(["id": .string("thread-held")])
        ]))
        XCTAssertFalse(plainResume.released)
        XCTAssertNil(plainResume.canAcceptDirectInput)

        let respawned = CodexAppServerConnectionError.appServer(CodexAppServerError(
            code: -32602,
            message: "takeover failed",
            data: .object(["accepted": .bool(false), "reason": .string("holder_respawned"), "retryable": .bool(false)])
        ))
        XCTAssertEqual(
            CodexAppServerThreadTakeoverResult.failure(from: respawned),
            CodexAppServerThreadTakeoverFailure(reason: "holder_respawned", retryable: false)
        )
        XCTAssertNil(CodexAppServerThreadTakeoverResult.failure(from: AgentAPIError.invalidResponse))
    }

    func testTakeOverHeldClaudeSessionUnlocksInputAndReconnects() async throws {
        let project = makeProject(id: "proj_claude_takeover")
        var held = makeSession(
            id: "claude_held",
            projectID: project.id,
            title: "held",
            status: "history",
            source: "claude",
            runtimeProvider: "claude"
        )
        held.canAcceptDirectInput = false
        held.claudeOwner = ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: "busy", pid: 4242)
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [held], messagesResult: [])
        client.sessionSupportsThreadTakeoverResult = true
        var takeoverRequests: [String] = []
        client.takeOverThreadHandler = { threadID in
            takeoverRequests.append(threadID)
            return CodexAppServerThreadTakeoverResult(released: true, holderEntrypoint: "cli", signal: "SIGINT", canAcceptDirectInput: true)
        }
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        _ = await store.bootstrap(restoring: SessionRestoreSnapshot(endpoint: appStore.endpoint, session: held))
        XCTAssertEqual(store.selectedSessionID, held.id)
        XCTAssertFalse(store.selectedOwnershipNotice?.canTakeOver ?? true, "未探测能力前不显示接管按钮")

        await store.refreshClaudeTakeoverSupportIfNeeded(sessionID: held.id)
        let notice = try XCTUnwrap(store.selectedOwnershipNotice)
        XCTAssertTrue(notice.canTakeOver)
        XCTAssertFalse(notice.isTakingOver)

        let socketsBefore = sockets.count
        let didTakeOver = await store.takeOverHeldClaudeSession(sessionID: held.id)

        XCTAssertTrue(didTakeOver)
        XCTAssertEqual(takeoverRequests, [held.id])
        let updated = try XCTUnwrap(store.sessions.first { $0.id == held.id })
        XCTAssertTrue(updated.allowsDirectInput)
        XCTAssertNil(updated.claudeOwner)
        XCTAssertNil(store.selectedOwnershipNotice, "接管后提示条应消失")
        XCTAssertEqual(store.controlState(for: updated), .takenOver)
        XCTAssertNil(store.claudeTakeoverInFlightSessionID)
        XCTAssertEqual(store.statusMessage, L10n.text("ui.taken_over_to_ipad"))
        XCTAssertGreaterThan(sockets.count, socketsBefore, "接管后应重连 WebSocket")
        XCTAssertEqual(sockets.last?.connectedSessionIDs.last, held.id)
    }

    func testTakeOverHeldClaudeSessionKeepsReadOnlyAndExplainsStructuredFailure() async throws {
        let project = makeProject(id: "proj_claude_takeover_fail")
        var held = makeSession(
            id: "claude_held_fail",
            projectID: project.id,
            title: "held",
            status: "history",
            source: "claude",
            runtimeProvider: "claude"
        )
        held.canAcceptDirectInput = false
        held.claudeOwner = ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: "idle", pid: 4243)
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [held], messagesResult: [])
        client.sessionSupportsThreadTakeoverResult = false
        client.takeOverThreadHandler = { _ in
            throw CodexAppServerConnectionError.appServer(CodexAppServerError(
                code: -32602,
                message: "takeover failed",
                data: .object(["accepted": .bool(false), "reason": .string("holder_respawned"), "retryable": .bool(false)])
            ))
        }
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        _ = await store.bootstrap(restoring: SessionRestoreSnapshot(endpoint: appStore.endpoint, session: held))

        // 旧 agentd / 旧 bridge 不声明 thread/takeover：按钮不出现。
        await store.refreshClaudeTakeoverSupportIfNeeded(sessionID: held.id)
        XCTAssertEqual(store.selectedOwnershipNotice?.canTakeOver, false)

        let didTakeOver = await store.takeOverHeldClaudeSession(sessionID: held.id)

        XCTAssertFalse(didTakeOver)
        let unchanged = try XCTUnwrap(store.sessions.first { $0.id == held.id })
        XCTAssertFalse(unchanged.allowsDirectInput, "失败时会话必须保持只读")
        XCTAssertNotNil(unchanged.claudeOwner)
        XCTAssertNotNil(store.selectedOwnershipNotice, "失败时提示条保留，按钮可重试")
        XCTAssertNil(store.claudeTakeoverInFlightSessionID)
        XCTAssertEqual(store.statusMessage, L10n.text("ui.take_over_claude_failed_respawned"))
    }
}
