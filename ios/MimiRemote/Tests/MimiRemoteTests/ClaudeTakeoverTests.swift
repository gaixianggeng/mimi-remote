import XCTest
@testable import MimiRemote

/// #451：Claude 会话被 Mac 持有时的"在此设备上接管"。
@MainActor
final class ClaudeTakeoverTests: XCTestCase {
    private final class SocketRecorder {
        var items: [MockWebSocketClient] = []
    }

    private struct HeldStore {
        let store: SessionStore
        let client: MockSessionStoreClient
        let appStore: AppStore
        let held: AgentSession
        let sockets: SocketRecorder
    }

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

        let respawned = Self.takeoverError(reason: "holder_respawned", retryable: false, holderPID: 4343)
        XCTAssertEqual(
            CodexAppServerThreadTakeoverResult.failure(from: respawned),
            CodexAppServerThreadTakeoverFailure(reason: "holder_respawned", retryable: false, holderPID: 4343)
        )
        XCTAssertNil(CodexAppServerThreadTakeoverResult.failure(from: AgentAPIError.invalidResponse))
    }

    func testTakeOverHeldClaudeSessionUnlocksInputAndReconnects() async throws {
        let fixture = await makeHeldStore(id: "claude_held", supportsTakeover: true)
        var takeoverRequests: [String] = []
        fixture.client.takeOverThreadHandler = { threadID in
            takeoverRequests.append(threadID)
            return CodexAppServerThreadTakeoverResult(released: true, holderEntrypoint: "cli", signal: "SIGINT", canAcceptDirectInput: true)
        }
        XCTAssertEqual(fixture.store.selectedSessionID, fixture.held.id)
        XCTAssertFalse(fixture.store.selectedOwnershipNotice?.canTakeOver ?? true, "未探测能力前不显示接管按钮")

        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)
        let notice = try XCTUnwrap(fixture.store.selectedOwnershipNotice)
        XCTAssertTrue(notice.canTakeOver)
        XCTAssertFalse(notice.isTakingOver)

        let socketsBefore = fixture.sockets.items.count
        let didTakeOver = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)

        XCTAssertTrue(didTakeOver)
        XCTAssertEqual(takeoverRequests, [fixture.held.id])
        let updated = try XCTUnwrap(fixture.store.sessions.first { $0.id == fixture.held.id })
        XCTAssertTrue(updated.allowsDirectInput)
        XCTAssertNil(updated.claudeOwner)
        XCTAssertNil(fixture.store.selectedOwnershipNotice, "接管后提示条应消失")
        XCTAssertEqual(fixture.store.controlState(for: updated), .takenOver)
        XCTAssertNil(fixture.store.claudeTakeoverInFlightSessionID)
        XCTAssertEqual(fixture.store.statusMessage, L10n.text("ui.taken_over_to_ipad"))
        XCTAssertGreaterThan(fixture.sockets.items.count, socketsBefore, "接管后应重连 WebSocket")
        XCTAssertEqual(fixture.sockets.items.last?.connectedSessionIDs.last, fixture.held.id)
    }

    func testNonRetryableFailureKeepsReadOnlyAndDisarmsButtonForThatHolder() async throws {
        let fixture = await makeHeldStore(id: "claude_held_respawn", supportsTakeover: true)
        fixture.client.takeOverThreadHandler = { _ in
            throw Self.takeoverError(reason: "holder_respawned", retryable: false, holderPID: 4344)
        }
        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, true)

        let didTakeOver = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)

        XCTAssertFalse(didTakeOver)
        let unchanged = try XCTUnwrap(fixture.store.sessions.first { $0.id == fixture.held.id })
        XCTAssertFalse(unchanged.allowsDirectInput, "失败时会话必须保持只读")
        XCTAssertNotNil(unchanged.claudeOwner)
        XCTAssertNil(fixture.store.claudeTakeoverInFlightSessionID)
        XCTAssertEqual(fixture.store.statusMessage, L10n.text("ui.take_over_claude_failed_respawned"))
        let refused = try XCTUnwrap(fixture.store.selectedOwnershipNotice, "失败时提示条保留")
        XCTAssertFalse(refused.canTakeOver, "bridge 明确拒绝后不能立刻再提供按钮，否则会反复结束重启的进程")

        // 刷新后提示条显示的是重启出来的新 pid：同样不能点。
        fixture.store.updateSession(fixture.held.id) { current in
            current.claudeOwner = ClaudeSessionOwner(entrypoint: "claude-desktop", kind: "interactive", status: "busy", pid: 4344)
        }
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, false)
        // 再次点击也不会发请求。
        var extraRequests = 0
        fixture.client.takeOverThreadHandler = { _ in
            extraRequests += 1
            throw AgentAPIError.invalidResponse
        }
        _ = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)
        XCTAssertEqual(extraRequests, 0)

        // 用户在 Mac 上关掉后重新打开，是一个全新的持有方：按钮恢复。
        fixture.store.updateSession(fixture.held.id) { current in
            current.claudeOwner = ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: "idle", pid: 9999)
        }
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, true)
    }

    func testRetryableTimeoutKeepsButtonArmed() async throws {
        let fixture = await makeHeldStore(id: "claude_held_timeout", supportsTakeover: true)
        fixture.client.takeOverThreadHandler = { _ in
            throw Self.takeoverError(reason: "takeover_timeout", retryable: true, holderPID: 4242)
        }
        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)

        let didTakeOver = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)

        XCTAssertFalse(didTakeOver)
        XCTAssertEqual(fixture.store.statusMessage, L10n.text("ui.take_over_claude_failed_timeout"))
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, true, "可重试的超时不应收起按钮")
    }

    func testSignalFailureExplainsPossiblePartialInterruption() async throws {
        let fixture = await makeHeldStore(id: "claude_held_signal", supportsTakeover: true)
        fixture.client.takeOverThreadHandler = { _ in
            throw Self.takeoverError(reason: "signal_failed", retryable: false, holderPID: 4242)
        }
        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)

        _ = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)

        XCTAssertEqual(fixture.store.statusMessage, L10n.text("ui.take_over_claude_failed_signal"))
        XCTAssertNotEqual(
            fixture.store.statusMessage,
            L10n.text("ui.take_over_claude_failed_unverified"),
            "发信号失败时前面的持有方可能已被中断，不能说成未做任何改动"
        )
    }

    func testCapabilityProbeErrorIsNotCachedAsUnsupported() async throws {
        let fixture = await makeHeldStore(id: "claude_held_probe", supportsTakeover: true)
        fixture.client.sessionSupportsThreadTakeoverError = AgentAPIError.invalidResponse

        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)
        XCTAssertNil(fixture.store.claudeTakeoverSupport, "探测请求失败不能被缓存成不支持")
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, false)

        fixture.client.sessionSupportsThreadTakeoverError = nil
        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, true, "恢复后再探应放出按钮")
    }

    func testUnsupportedHostHidesTakeoverButton() async throws {
        let fixture = await makeHeldStore(id: "claude_held_unsupported", supportsTakeover: false)

        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)

        XCTAssertEqual(fixture.store.claudeTakeoverSupport?.supported, false)
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, false, "旧 agentd / 旧 bridge 不声明方法时按钮不出现")
    }

    // MARK: - Fixtures

    private static func takeoverError(reason: String, retryable: Bool, holderPID: Int) -> Error {
        CodexAppServerConnectionError.appServer(CodexAppServerError(
            code: -32602,
            message: "takeover failed",
            data: .object([
                "accepted": .bool(false),
                "reason": .string(reason),
                "retryable": .bool(retryable),
                "claudeOwner": .object(["entrypoint": .string("cli"), "pid": .int(Int64(holderPID))])
            ])
        ))
    }

    private func makeHeldStore(id: String, supportsTakeover: Bool) async -> HeldStore {
        let project = makeProject(id: "proj_\(id)")
        var held = makeSession(
            id: id,
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
        client.sessionSupportsThreadTakeoverResult = supportsTakeover
        let sockets = SocketRecorder()
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
                sockets.items.append(socket)
                return socket
            }
        )
        _ = await store.bootstrap(restoring: SessionRestoreSnapshot(endpoint: appStore.endpoint, session: held))
        return HeldStore(store: store, client: client, appStore: appStore, held: held, sockets: sockets)
    }
}
