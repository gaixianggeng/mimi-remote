import XCTest
@testable import MimiRemote

/// #451：Claude 会话被 Mac 持有时的"在此设备上接管"。
@MainActor
final class ClaudeTakeoverTests: XCTestCase {
    private final class SocketRecorder {
        var items: [MockWebSocketClient] = []
    }

    private final class ClientFailureSwitch {
        var shouldFail = false
    }

    private struct HeldStore {
        let clientFailure: ClientFailureSwitch
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

    func testRefusalReasonSurvivesLeavingConversationAndStatusReplacement() async throws {
        let fixture = await makeHeldStore(id: "claude_held_return", supportsTakeover: true)
        fixture.client.takeOverThreadHandler = { _ in
            throw Self.takeoverError(reason: "holder_unverified", retryable: false, holderPID: 4242)
        }
        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)
        _ = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)

        fixture.store.setSelectedSessionID(nil)
        fixture.store.setStatusMessage(nil)
        fixture.store.setSelectedSessionID(fixture.held.id)
        let notice = try XCTUnwrap(fixture.store.selectedOwnershipNotice)
        XCTAssertFalse(notice.canTakeOver)
        XCTAssertEqual(notice.message, L10n.text("ui.take_over_claude_failed_unverified"))

        fixture.store.updateSession(fixture.held.id) { current in
            current.claudeOwner = ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: "idle", pid: 9999)
        }
        XCTAssertNil(fixture.store.selectedOwnershipNotice?.failureMessage)
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
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.message, L10n.text("ui.take_over_claude_failed_timeout"))
        fixture.client.takeOverThreadHandler = { _ in
            CodexAppServerThreadTakeoverResult(released: true, holderEntrypoint: "cli", signal: "SIGINT", canAcceptDirectInput: true)
        }
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, true, "可重试的超时不应收起按钮")
        let retried = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)
        XCTAssertTrue(retried)
        XCTAssertNil(fixture.store.claudeTakeoverFailures[fixture.held.id])
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

    /// 确认弹窗要点名实际持有方：桌面版、VS Code 持有时不能再说"终端里的会话"。
    func testTakeoverConfirmationNamesActualHolder() {
        let desktop = SessionOwnershipNotice(
            sessionID: "held",
            owner: ClaudeSessionOwner(entrypoint: "claude-desktop", kind: "interactive", status: "idle", pid: 4242)
        )
        XCTAssertTrue(desktop.takeOverConfirmationMessage.contains(L10n.text("ui.claude_owner_desktop")))
        XCTAssertFalse(desktop.takeOverConfirmationMessage.contains(L10n.text("ui.claude_owner_terminal")))

        let terminal = SessionOwnershipNotice(
            sessionID: "held",
            owner: ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: "busy", pid: 4243)
        )
        XCTAssertTrue(terminal.takeOverConfirmationMessage.contains(L10n.text("ui.claude_owner_terminal")))
    }

    /// 接管入口在输入框托盘里；即便持有态叠上写入冲突，也不能让冲突卡把输入框连同接管一起换掉。
    func testOwnershipKeepsComposerWhenWriterConflictIsRecorded() async throws {
        let fixture = await makeHeldStore(id: "claude_held_conflict", supportsTakeover: true)
        fixture.store.setActiveWriterConflict(true, sessionID: fixture.held.id)

        XCTAssertTrue(fixture.store.selectedSessionHasActiveWriterConflict)
        XCTAssertNotNil(fixture.store.selectedOwnershipNotice)
        XCTAssertFalse(fixture.store.selectedSessionShowsWriterConflictCard, "持有态要保留输入框托盘里的接管入口")

        fixture.store.updateSession(fixture.held.id) { current in
            current.claudeOwner = nil
        }
        XCTAssertTrue(fixture.store.selectedSessionShowsWriterConflictCard, "没有持有方时冲突卡照常出现")
    }

    func testUnsupportedHostHidesTakeoverButton() async throws {
        let fixture = await makeHeldStore(id: "claude_held_unsupported", supportsTakeover: false)

        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)

        XCTAssertEqual(fixture.store.claudeTakeoverSupport?.supported, false)
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, false, "旧 agentd / 旧 bridge 不声明方法时按钮不出现")
    }

    func testBusyAndUnknownOwnersStayReadOnlyUntilIdle() async throws {
        let fixture = await makeHeldStore(id: "claude_wait_idle", supportsTakeover: true)
        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)
        var calls = 0
        fixture.client.takeOverThreadHandler = { _ in
            calls += 1
            return CodexAppServerThreadTakeoverResult(released: true, canAcceptDirectInput: true)
        }
        let statuses: [String?] = ["busy", "shell", nil, "unknown"]
        for status in statuses {
            fixture.store.updateSession(fixture.held.id) { current in
                current.claudeOwner = ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: status, pid: 4242)
            }
            XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, false)
            let taken = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)
            XCTAssertFalse(taken)
            XCTAssertEqual(calls, 0)
        }
        fixture.store.updateSession(fixture.held.id) { current in
            current.claudeOwner = fixture.held.claudeOwner
        }
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, true)
        XCTAssertEqual(calls, 0, "完成后等待用户手动操作，不自动接管")
        let taken = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)
        XCTAssertTrue(taken)
        XCTAssertEqual(calls, 1)
    }

    func testServerBusyRejectionDoesNotPermanentlyBlockTakeover() async throws {
        let fixture = await makeHeldStore(id: "claude_stale_idle", supportsTakeover: true)
        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)
        fixture.client.takeOverThreadHandler = { _ in
            throw Self.takeoverError(reason: "holder_busy", retryable: true, holderPID: 4242)
        }
        let taken = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)
        XCTAssertFalse(taken)
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.message, L10n.text("ui.take_over_claude_wait_until_idle"))
        XCTAssertFalse(fixture.store.claudeTakeoverIsBlocked(for: fixture.held))
        XCTAssertFalse(fixture.store.selectedSession?.allowsDirectInput ?? true)
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, false)
        fixture.store.updateSession(fixture.held.id) { current in current.claudeOwner = fixture.held.claudeOwner }
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.canTakeOver, true)
        XCTAssertNil(fixture.store.selectedOwnershipNotice?.failureMessage)
    }

    func testOldHostCannotBeInvokedThroughStaleConfirmation() async throws {
        let fixture = await makeHeldStore(id: "claude_old_takeover", supportsTakeover: false)
        var calls = 0
        fixture.client.takeOverThreadHandler = { _ in
            calls += 1
            throw AgentAPIError.invalidResponse
        }
        let taken = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)
        XCTAssertFalse(taken)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.message, L10n.text("ui.take_over_claude_upgrade_required"))
    }

    func testClientConstructionFailureIsVisibleAfterReturning() async throws {
        let fixture = await makeHeldStore(id: "claude_client_failure", supportsTakeover: true)
        fixture.clientFailure.shouldFail = true
        let taken = await fixture.store.takeOverHeldClaudeSession(sessionID: fixture.held.id)
        XCTAssertFalse(taken)
        fixture.store.setStatusMessage(nil)
        fixture.store.setSelectedSessionID(nil)
        fixture.store.setSelectedSessionID(fixture.held.id)
        XCTAssertNotNil(fixture.store.selectedOwnershipNotice?.failureMessage)
        XCTAssertFalse(fixture.store.claudeTakeoverIsBlocked(for: fixture.held))
    }

    func testRuntimeRequiresIdleTakeoverCapabilityInAdditionToMethod() async throws {
        let capabilities: [Bool?] = [nil, false, true]
        for capability in capabilities {
            let base = makeDirectAppServerConfig(project: makeProject(id: "takeover-capability"))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
            var channel: [String: Any] = [
                "id": "claude", "runtime_id": "claude", "title": "Claude", "provider": "anthropic",
                "type": "claude_code_bridge", "gateway_ws_url": "ws://localhost:8787/claude",
                "gateway_available": true, "managed": false, "methods": ["thread/takeover"]
            ]
            if let capability { channel["capabilities"] = ["idle_takeover": capability] }
            object["channels"] = [channel]
            let config = try JSONDecoder().decode(CodexAppServerConfigResponse.self, from: JSONSerialization.data(withJSONObject: object))
            let runtime = CodexAppServerSessionRuntime(endpoint: "http://localhost:8787", token: "test-token", runtimeProvider: "claude", configProvider: { config })
            let supported = try await runtime.supportsThreadTakeover()
            XCTAssertEqual(supported, capability == true)
        }
    }

    func testHistoryReloadAndRateLimitReplayPreserveOwnershipAfterReopening() async throws {
        let fixture = await makeHeldStore(id: "claude_history_reopen", supportsTakeover: true)
        await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://localhost:8787", token: "test-token", runtimeProvider: "claude"
        )
        let limits = try JSONDecoder().decode(RateLimitSummary.self, from: Data("{}".utf8))

        for status: String? in ["busy", "shell", nil, "idle"] {
            var held = fixture.held
            held.claudeOwner = ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: status, pid: 4242)
            fixture.store.upsert(held)
            await runtime.rememberForkedSession(held)
            fixture.store.setSelectedSessionID(nil)

            // 重入会复用历史缓存壳；随后额度刷新会把壳投影后的整条会话重新推给 Store。
            let shell = await runtime.historyThreadShell(sessionID: held.id, projects: [])
            _ = await runtime.contextForHistoryThread(shell, sessionID: held.id, projects: [])
            await runtime.applyAccountRateLimit(limits)
            let events = await runtime.bufferedEvents(sessionID: held.id, replayPolicy: .stateOnly)
            let replayed = try XCTUnwrap(events.compactMap { event -> AgentSession? in
                if case .session(let session) = event { return session }
                return nil
            }.last)
            fixture.store.upsert(replayed)
            fixture.store.setSelectedSessionID(held.id)

            let notice = try XCTUnwrap(fixture.store.selectedOwnershipNotice)
            XCTAssertEqual(notice.owner, held.claudeOwner)
            XCTAssertEqual(notice.canTakeOver, status == "idle")
            XCTAssertFalse(try XCTUnwrap(fixture.store.selectedSession).allowsDirectInput)
        }

        // 权威快照明确解除持有后，后续缓存重建也不能复活旧提示。
        var released = fixture.held
        released.canAcceptDirectInput = true
        released.claudeOwner = nil
        await runtime.rememberForkedSession(released)
        let shell = await runtime.historyThreadShell(sessionID: released.id, projects: [])
        let projected = try await runtime.agentSession(from: shell, projects: [], fallbackProject: nil)
        fixture.store.upsert(projected)
        XCTAssertNil(fixture.store.selectedOwnershipNotice)
        XCTAssertTrue(projected.allowsDirectInput)
    }

    func testTakeoverRefusalSurvivesRuntimeRateLimitReplayUntilAuthoritativeIdle() async throws {
        for reason in ["holder_busy", "holder_state_unknown"] {
            let fixture = await makeHeldStore(id: "claude_refusal_\(reason)", supportsTakeover: true)
            await fixture.store.refreshClaudeTakeoverSupportIfNeeded(sessionID: fixture.held.id)
            let (runtime, transport, _) = makeTakeoverRuntime(session: fixture.held)
            await runtime.rememberForkedSession(fixture.held)
            fixture.client.takeOverThreadHandler = { try await runtime.takeOverThread(sessionID: $0) }
            let task = Task { await fixture.store.takeOverHeldClaudeSession(fixture.held) }
            try await initializeTakeoverRuntime(transport)
            let request = try await waitForFakeAppServerRequest(transport, method: "thread/takeover")
            let response = CodexAppServerResponse(id: request.id, result: nil, error: CodexAppServerError(
                code: -32602, message: "takeover refused", data: .object([
                    "accepted": .bool(false), "reason": .string(reason), "retryable": .bool(true),
                    "claudeOwner": .object(["pid": .int(4242)])
                ])
            ))
            transport.enqueue(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
            let taken = await task.value
            XCTAssertFalse(taken)
            fixture.store.upsert(try await replayRuntimeSession(runtime, id: fixture.held.id))
            let rejected = try XCTUnwrap(fixture.store.selectedSession)
            XCTAssertEqual(rejected.claudeOwner?.status, reason == "holder_busy" ? "busy" : nil)
            XCTAssertNotNil(fixture.store.claudeTakeoverFailure(for: rejected))
            XCTAssertFalse(fixture.store.selectedOwnershipNotice?.canTakeOver ?? true)

            // 真正的 thread/read 更新 owner 后才解除等待，额度事件本身不能解除。
            try await readAuthoritativeOwner(runtime, transport: transport, session: fixture.held, status: "idle")
            fixture.store.upsert(try await replayRuntimeSession(runtime, id: fixture.held.id))
            XCTAssertNil(fixture.store.claudeTakeoverFailure(for: try XCTUnwrap(fixture.store.selectedSession)))
            XCTAssertTrue(fixture.store.selectedOwnershipNotice?.canTakeOver ?? false)
            await runtime.shutdownForHostSwitch()
        }
    }

    func testSuccessfulTakeoverClearsRuntimeOwnerWithoutDependingOnReconnect() async throws {
        for leavePage in [false, true] {
            let fixture = await makeHeldStore(id: "claude_success_replay", supportsTakeover: true)
            let (runtime, transport, _) = makeTakeoverRuntime(session: fixture.held)
            await runtime.rememberForkedSession(fixture.held)
            fixture.client.takeOverThreadHandler = { try await runtime.takeOverThread(sessionID: $0) }
            let task = Task { await fixture.store.takeOverHeldClaudeSession(fixture.held) }
            try await initializeTakeoverRuntime(transport)
            let request = try await waitForFakeAppServerRequest(transport, method: "thread/takeover")
            if leavePage {
                fixture.store.setSelectedSessionID(nil)
            } else {
                // 同一页面已有连接时 connectWebSocket 会早退，不会重新 resume。
                fixture.store.connectedSessionID = fixture.held.id
                fixture.store.connectedHostScope = fixture.appStore.activeHostScope
                fixture.store.setWebSocketStatus(.connected)
            }
            let socketsBefore = fixture.sockets.items.count
            transportResponse(transport, id: request.id, result: ownerResult(fixture.held, status: nil))
            let taken = await task.value
            XCTAssertTrue(taken)
            XCTAssertEqual(fixture.sockets.items.count, socketsBefore)
            let replayed = try await replayRuntimeSession(runtime, id: fixture.held.id)
            fixture.store.upsert(replayed)
            fixture.store.setSelectedSessionID(fixture.held.id)
            XCTAssertTrue(replayed.allowsDirectInput)
            XCTAssertNil(replayed.claudeOwner)
            XCTAssertNil(fixture.store.selectedOwnershipNotice)
            await runtime.shutdownForHostSwitch()
        }
    }

    func testInFlightHistoryPagePreservesNewAuthoritativeOwnership() async throws {
        let changes: [(String?, String?)] = [("busy", "idle"), ("idle", "busy"), ("busy", nil), (nil, "busy")]
        for cached in [false, true] {
            for (oldStatus, newStatus) in changes {
                let fixture = await makeHeldStore(id: "claude_history_race", supportsTakeover: true)
                let (runtime, transport, project) = makeTakeoverRuntime(session: fixture.held)
                if cached {
                    var initial = fixture.held
                    initial.canAcceptDirectInput = oldStatus == nil
                    initial.claudeOwner = oldStatus.map { ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: $0, pid: 4242) }
                    await runtime.rememberForkedSession(initial)
                }
                let page = Task {
                    try await runtime.messagesPageFromTurnPages(
                        sessionID: fixture.held.id, before: nil, limit: 20, loadMode: .economy,
                        projects: [project], canHydrateTurnItems: false, recoveringInterruptedTurnID: nil
                    )
                }
                try await initializeTakeoverRuntime(transport)
                if !cached {
                    let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
                    transportResponse(transport, id: read.id, result: ownerResult(fixture.held, status: oldStatus))
                }
                let turns = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
                // 保持分页 RPC 挂起，让更新的权威快照先落入 Runtime，再返回旧分页。
                try await readAuthoritativeOwner(runtime, transport: transport, session: fixture.held, status: newStatus)
                transportResponse(transport, id: turns.id, result: #"{"data":[],"nextCursor":null}"#)
                _ = try await page.value
                let replayed = try await replayRuntimeSession(runtime, id: fixture.held.id)
                XCTAssertEqual(replayed.canAcceptDirectInput, newStatus == nil)
                XCTAssertEqual(replayed.claudeOwner?.status, newStatus)
                XCTAssertEqual(replayed.claudeOwner == nil, newStatus == nil)
                await runtime.shutdownForHostSwitch()
            }
        }
    }

    // MARK: - Fixtures

    private func makeTakeoverRuntime(session: AgentSession) -> (CodexAppServerSessionRuntime, FakeCodexAppServerTransport, AgentProject) {
        let project = AgentProject(id: session.projectID, name: "Takeover", path: session.dir)
        let transport = FakeCodexAppServerTransport()
        let config = makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata(methods: [
            "initialize", "initialized", "thread/read", "thread/turns/list", "thread/takeover"
        ])])
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://localhost:8787", token: "test-token", runtimeProvider: "claude",
            transportFactory: { transport }, configProvider: { config }
        )
        return (runtime, transport, project)
    }

    private func initializeTakeoverRuntime(_ transport: FakeCodexAppServerTransport) async throws {
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
    }

    private func ownerResult(_ session: AgentSession, status: String?) -> String {
        let owner: CodexAppServerJSONValue = status.map { .object([
            "entrypoint": .string("cli"), "kind": .string("interactive"), "status": .string($0), "pid": .int(4242)
        ]) } ?? .null
        let result = CodexAppServerJSONValue.object(["thread": .object([
            "id": .string(session.id), "cwd": .string(session.dir), "name": .string("Held"),
            "status": .object(["type": .string("idle")]), "canAcceptDirectInput": .bool(status == nil),
            "claudeOwner": owner
        ])])
        return String(decoding: try! JSONEncoder().encode(result), as: UTF8.self)
    }

    private func readAuthoritativeOwner(
        _ runtime: CodexAppServerSessionRuntime, transport: FakeCodexAppServerTransport,
        session: AgentSession, status: String?
    ) async throws {
        let cursor = await transport.sentMessages().count
        let read = Task { try await runtime.session(id: session.id, afterSeq: nil) }
        let request = try await waitForFakeAppServerRequest(transport, method: "thread/read", after: cursor)
        transportResponse(transport, id: request.id, result: ownerResult(session, status: status))
        _ = try await read.value
    }

    private func replayRuntimeSession(_ runtime: CodexAppServerSessionRuntime, id: String) async throws -> AgentSession {
        await runtime.applyAccountRateLimit(try JSONDecoder().decode(RateLimitSummary.self, from: Data("{}".utf8)))
        let events = await runtime.bufferedEvents(sessionID: id, replayPolicy: .stateOnly)
        return try XCTUnwrap(events.compactMap { event -> AgentSession? in
            if case .session(let session) = event { return session }
            return nil
        }.last)
    }

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
        held.claudeOwner = ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: "idle", pid: 4242)
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [held], messagesResult: [])
        client.sessionSupportsThreadTakeoverResult = supportsTakeover
        let sockets = SocketRecorder()
        let clientFailure = ClientFailureSwitch()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: {
                if clientFailure.shouldFail { throw AgentAPIError.invalidResponse }
                return client
            },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.items.append(socket)
                return socket
            }
        )
        _ = await store.bootstrap(restoring: SessionRestoreSnapshot(endpoint: appStore.endpoint, session: held))
        return HeldStore(clientFailure: clientFailure, store: store, client: client, appStore: appStore, held: held, sockets: sockets)
    }
}
