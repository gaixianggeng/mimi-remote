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

    /// #722：适配器读不到工作目录时给空串，不能冲掉已知目录，否则下一次发送会在本地被 allowlist 拒绝。
    func testEmptyThreadCWDKeepsKnownWorkingDirectory() async throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/tmp/repo")
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://localhost:8787", token: "test-token", runtimeProvider: "claude"
        )
        let created = try await runtime.agentSession(
            from: ["id": .string("claude_empty_cwd"), "cwd": .string(project.path)],
            projects: [project], fallbackProject: nil
        )
        await runtime.rememberForkedSession(created)

        let metadata: [String: CodexAppServerJSONValue] = ["id": .string(created.id), "cwd": .string("")]
        let context = await runtime.contextForHistoryThread(metadata, sessionID: created.id, projects: [project])
        XCTAssertEqual(context?.environment?.cwd, project.path)
        let reprojected = try await runtime.agentSession(from: metadata, projects: [project], fallbackProject: nil)
        XCTAssertEqual(reprojected.dir, project.path)
        XCTAssertEqual(reprojected.projectID, project.id)

        // 真的拿不到目录时，提示不能是一个冒号后面什么都没有。
        XCTAssertEqual(
            CodexAppServerRequestBuilderError.pathNotAllowlisted("").errorDescription,
            L10n.text("ui.working_directory_unknown")
        )
    }

    /// #722：历史会话续聊时 resume 先把会话投影成运行中；首个 turn 被明确拒绝后必须撤回，
    /// 否则额度刷新重放整条会话，界面会停在「运行中 / 思考中」。
    func testRejectedFirstTurnAfterResumeDoesNotLeaveSessionRunning() async throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/tmp/repo")
        let transport = FakeCodexAppServerTransport()
        let config = makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata(methods: [
            "initialize", "initialized", "thread/resume", "turn/start"
        ])])
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://localhost:8787", token: "test-token", runtimeProvider: "claude",
            transportFactory: { transport }, configProvider: { config }
        )
        let threadID = "claude_rejected_first_turn"
        let create = Task {
            try await runtime.createSession(CreateSessionRequest(
                projectID: project.id, prompt: "continue", resumeID: threadID, clientMessageID: "client-rejected"
            ))
        }
        try await initializeTakeoverRuntime(transport)
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume")
        // 适配器读不到工作目录时回空串；turn/start 仍要带发起 resume 的项目目录。
        transportResponse(transport, id: resume.id, result: #"{"thread":{"id":"\#(threadID)","cwd":"","status":{"type":"idle"},"turns":[]}}"#)
        let start = try await waitForFakeAppServerRequest(transport, method: "turn/start")
        XCTAssertEqual(start.params?.objectValue?["cwd"]?.stringValue, project.path)
        transportErrorResponse(transport, id: start.id, code: -32602, message: "rejected before start")
        do {
            _ = try await create.value
            XCTFail("首个 turn 被拒绝时 createSession 应抛错")
        } catch {}

        await runtime.applyAccountRateLimit(try JSONDecoder().decode(RateLimitSummary.self, from: Data("{}".utf8)))
        let replayed = await runtime.bufferedEvents(sessionID: threadID, replayPolicy: .stateOnly).compactMap { event -> AgentSession? in
            if case .session(let session) = event { return session }
            return nil
        }
        XCTAssertEqual(replayed.last?.status, SessionStatus.history.rawValue)
        XCTAssertNil(replayed.last?.activeTurnID)
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
        let statuses: [String?] = ["busy", "shell", "waiting", nil, "unknown"]
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

        for status: String? in ["busy", "shell", "waiting", nil, "idle"] {
            var held = fixture.held
            held.claudeOwner = ClaudeSessionOwner(
                entrypoint: "cli", kind: "interactive", status: status, pid: 4242,
                statusUpdatedAt: Date(timeIntervalSince1970: 1_000), waitingKind: status == "waiting" ? .input : nil
            )
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

    func testOwnershipStatusNotificationTogglesReadOnlyWithoutRefetch() async throws {
        let fixture = await makeHeldStore(id: "claude_ownership_push", supportsTakeover: true)
        let (runtime, _, _) = makeTakeoverRuntime(session: fixture.held)
        var driving = fixture.held
        driving.canAcceptDirectInput = true
        driving.claudeOwner = nil
        await runtime.rememberForkedSession(driving)

        func statusChanged(_ extra: [String: CodexAppServerJSONValue]) async {
            var params: [String: CodexAppServerJSONValue] = [
                "threadId": .string(driving.id), "status": .object(["type": .string("notLoaded")])
            ]
            params.merge(extra) { _, new in new }
            await runtime.handle(CodexAppServerNotification(method: "thread/status/changed", params: .object(params)))
        }

        // 终端接手：适配器让出并推送只读标记与持有方摘要。
        await statusChanged([
            "canAcceptDirectInput": .bool(false),
            "claudeOwner": .object([
                "entrypoint": .string("cli"), "kind": .string("interactive"), "status": .string("busy"), "pid": .int(4242)
            ])
        ])
        let yielded = try await replayRuntimeSession(runtime, id: driving.id)
        XCTAssertFalse(yielded.allowsDirectInput)
        XCTAssertEqual(yielded.claudeOwner?.pid, 4242)
        fixture.store.upsert(yielded)
        fixture.store.setSelectedSessionID(driving.id)
        XCTAssertEqual(fixture.store.selectedOwnershipNotice?.owner.status, "busy")

        // 不带扩展字段的普通状态通知不改变所有权。
        await statusChanged([:])
        let unchanged = try await replayRuntimeSession(runtime, id: driving.id)
        XCTAssertFalse(unchanged.allowsDirectInput)

        // 持有方退出：恢复可写，提示条消失。
        await statusChanged(["canAcceptDirectInput": .bool(true), "claudeOwner": .null])
        let released = try await replayRuntimeSession(runtime, id: driving.id)
        XCTAssertTrue(released.allowsDirectInput)
        XCTAssertNil(released.claudeOwner)
        fixture.store.upsert(released)
        XCTAssertNil(fixture.store.selectedOwnershipNotice)
        await runtime.shutdownForHostSwitch()
    }

    /// #718：Claude 网关按连接授权会话，重连后没先拉列表就读历史会被拒为「未由当前 gateway 连接授权」。
    /// 运行时在同一连接上按会话目录拉列表让网关重新授权，再重试一次。
    func testUnauthorizedHistoryReadReauthorizesOnCurrentConnectionAndRetriesOnce() async throws {
        let (runtime, transport, session) = try await makeReauthorizationRuntime(id: "claude_reauthorize")
        let page = Task {
            try await runtime.messagesPageFromTurnPages(
                sessionID: session.id, before: nil, limit: 20, loadMode: .economy,
                projects: [AgentProject(id: session.projectID, name: "Takeover", path: session.dir)],
                canHydrateTurnItems: false, recoveringInterruptedTurnID: nil
            )
        }
        try await initializeTakeoverRuntime(transport)
        let rejected = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        transportErrorResponse(
            transport, id: rejected.id, code: -32080,
            message: "thread/turns/list.threadId 未由当前 gateway 连接授权"
        )
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list")
        XCTAssertEqual(list.params?.objectValue?["cwd"]?.stringValue, session.dir, "按会话所在目录拉列表")
        let sentBeforeRetry = await transport.sentMessages().count
        transportResponse(transport, id: list.id, result: #"{"data":[{"id":"\#(session.id)"}],"nextCursor":null}"#)
        let retried = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list", after: sentBeforeRetry)
        XCTAssertEqual(retried.params?.objectValue?["threadId"]?.stringValue, session.id)
        transportResponse(transport, id: retried.id, result: #"{"data":[],"nextCursor":null}"#)
        _ = try await page.value
        await runtime.shutdownForHostSwitch()
    }

    /// 列表里找不到这个会话（已删除或超出可翻页数）时不再重试，照常报原错误。
    func testUnauthorizedHistoryReadSurfacesErrorWhenListingCannotAuthorize() async throws {
        let (runtime, transport, session) = try await makeReauthorizationRuntime(id: "claude_reauthorize_missing")
        let page = Task {
            try await runtime.messagesPageFromTurnPages(
                sessionID: session.id, before: nil, limit: 20, loadMode: .economy,
                projects: [AgentProject(id: session.projectID, name: "Takeover", path: session.dir)],
                canHydrateTurnItems: false, recoveringInterruptedTurnID: nil
            )
        }
        try await initializeTakeoverRuntime(transport)
        let rejected = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        transportErrorResponse(
            transport, id: rejected.id, code: -32080,
            message: "thread/turns/list.threadId 未由当前 gateway 连接授权"
        )
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list")
        let sentAfterList = await transport.sentMessages().count
        transportResponse(transport, id: list.id, result: #"{"data":[{"id":"someone-else"}],"nextCursor":null}"#)
        do {
            _ = try await page.value
            XCTFail("找不到会话时应报原错误")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("-32080"), "\(error)")
        }
        let methods = await transport.sentMessages().dropFirst(sentAfterList).compactMap { message -> String? in
            (try? decodeAppServerRequest(message))?.method
        }
        XCTAssertFalse(methods.contains("thread/turns/list"), "授权失败后不再重试")
        await runtime.shutdownForHostSwitch()
    }

    /// 同一目录的两个会话同时被拒：网关会把参数相同的并发列表当成重复请求拒绝，
    /// 运行时只翻一次列表，后到的会话直接复用这次翻到的授权结果。
    func testConcurrentUnauthorizedReadsInSameDirectoryShareOneListing() async throws {
        let (runtime, transport, first) = try await makeReauthorizationRuntime(id: "claude_reauthorize_a")
        var second = makeSession(
            id: "claude_reauthorize_b", projectID: first.projectID, title: "reauthorize", status: "history",
            source: "claude", runtimeProvider: "claude"
        )
        second.canAcceptDirectInput = true
        await runtime.rememberForkedSession(second)
        let project = AgentProject(id: first.projectID, name: "Takeover", path: first.dir)
        func load(_ id: SessionID) -> Task<HistoryMessagesPage, Error> {
            Task {
                try await runtime.messagesPageFromTurnPages(
                    sessionID: id, before: nil, limit: 20, loadMode: .economy, projects: [project],
                    canHydrateTurnItems: false, recoveringInterruptedTurnID: nil
                )
            }
        }
        let pages = [load(first.id), load(second.id)]
        // 两个读请求几乎同时发出，按数量等待，不按发送顺序找。
        func sent(_ method: String, atLeast count: Int) async throws -> [CodexAppServerRequest] {
            for _ in 0..<400 {
                let found = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
                    .filter { $0.method == method }
                if found.count >= count { return found }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("等待 \(count) 个 \(method) 超时")
            return []
        }
        try await initializeTakeoverRuntime(transport)
        for request in try await sent("thread/turns/list", atLeast: 2).prefix(2) {
            transportErrorResponse(
                transport, id: request.id, code: -32080,
                message: "thread/turns/list.threadId 未由当前 gateway 连接授权"
            )
        }
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list")
        transportResponse(
            transport, id: list.id,
            result: #"{"data":[{"id":"\#(first.id)"},{"id":"\#(second.id)"}],"nextCursor":null}"#
        )
        for request in try await sent("thread/turns/list", atLeast: 4).dropFirst(2) {
            transportResponse(transport, id: request.id, result: #"{"data":[],"nextCursor":null}"#)
        }
        for page in pages { _ = try await page.value }
        let listCount = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
            .filter { $0.method == "thread/list" }.count
        XCTAssertEqual(listCount, 1, "同一连接、同一目录只翻一次列表")
        await runtime.shutdownForHostSwitch()
    }

    /// Codex 会话不在 State DB 索引里时，与普通列表一样改用扫描找回再授权（#719 评审）。
    func testCodexReauthorizationFallsBackToScanWhenIndexMissesThread() async throws {
        let project = AgentProject(id: "proj_codex_reauthorize", name: "Codex", path: "/tmp/proj_codex_reauthorize")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://localhost:8787", token: "test-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, allowedMethods: [
                    "initialize", "initialized", "thread/list", "thread/read", "thread/turns/list"
                ])
            }
        )
        let session = makeSession(
            id: "codex_reauthorize", projectID: project.id, title: "codex", status: "history", source: "codex"
        )
        await runtime.rememberForkedSession(session)
        let page = Task {
            try await runtime.messagesPageFromTurnPages(
                sessionID: session.id, before: nil, limit: 20, loadMode: .economy, projects: [project],
                canHydrateTurnItems: false, recoveringInterruptedTurnID: nil
            )
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake","platformFamily":"macos"}"#)
        let rejected = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        transportErrorResponse(
            transport, id: rejected.id, code: -32080,
            message: "thread/turns/list.threadId 未由当前 gateway 连接授权"
        )
        let indexed = try await waitForFakeAppServerRequest(transport, method: "thread/list")
        XCTAssertEqual(indexed.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
        let afterIndexed = await transport.sentMessages().count
        transportResponse(transport, id: indexed.id, result: #"{"data":[],"nextCursor":null}"#)
        let scanned = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: afterIndexed)
        XCTAssertEqual(scanned.params?.objectValue?["useStateDbOnly"]?.boolValue, false, "索引缺漏时改用扫描")
        let afterScan = await transport.sentMessages().count
        transportResponse(transport, id: scanned.id, result: #"{"data":[{"id":"\#(session.id)"}],"nextCursor":null}"#)
        let retried = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list", after: afterScan)
        transportResponse(transport, id: retried.id, result: #"{"data":[],"nextCursor":null}"#)
        _ = try await page.value
        await runtime.shutdownForHostSwitch()
    }

    private func makeReauthorizationRuntime(
        id: String
    ) async throws -> (CodexAppServerSessionRuntime, FakeCodexAppServerTransport, AgentSession) {
        var session = makeSession(
            id: id, projectID: "proj_\(id)", title: "reauthorize", status: "history",
            source: "claude", runtimeProvider: "claude"
        )
        session.canAcceptDirectInput = true
        let (runtime, transport, _) = makeTakeoverRuntime(session: session)
        // 已知会话的目录，历史页不再先发 thread/read，直接读 turns。
        await runtime.rememberForkedSession(session)
        return (runtime, transport, session)
    }

    /// #706：电脑端执行中或等确认时打开的会话，命令按"仍在处理"显示；持有方停下只推状态，
    /// 打开着的会话要静默补拉一次历史。仍在处理的状态切换（等确认 → 执行）不补拉。
    func testOpenSessionReloadsHistoryOnceWhenComputerHolderStops() async throws {
        let fixture = await makeHeldStore(id: "claude_holder_stop_reload", supportsTakeover: true)
        let store = fixture.store
        let id = fixture.held.id
        XCTAssertEqual(store.selectedSessionID, id)
        let lease = HostSessionLease(hostScope: store.appStore.activeHostScope, sessionID: id)
        func push(_ status: String, waitingKind: ClaudeSessionOwner.WaitingKind? = nil) async throws {
            var session = try XCTUnwrap(store.sessionsByID[id])
            session.claudeOwner = ClaudeSessionOwner(
                entrypoint: "cli", kind: "interactive", status: status, pid: 4242, waitingKind: waitingKind
            )
            session.canAcceptDirectInput = false
            await store.applyRuntimeEvent(.session(session), lease: lease)
        }
        func historyRequests() -> Int {
            fixture.client.requestedMessageSessionIDs.filter { $0 == id }.count
        }
        func settle() async throws {
            for _ in 0..<20 { await Task.yield() }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        try await push("waiting", waitingKind: .permission)
        try await settle()
        let baseline = historyRequests()

        try await push("busy")
        try await settle()
        XCTAssertEqual(historyRequests(), baseline, "等确认转为执行时持有方仍在处理，不补拉")

        try await push("idle")
        for _ in 0..<100 where historyRequests() == baseline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(historyRequests(), baseline + 1, "持有方停下后补拉一次历史")

        try await push("idle")
        try await settle()
        XCTAssertEqual(historyRequests(), baseline + 1, "已经停下的会话再收到空闲快照不重复补拉")
    }

    /// #716：快档轮询只补偿本该有前台事件流却断开的会话。列表页和电脑端持有的只读会话
    /// 本来就没有可写事件流，也用快档会让常驻轮询撞上 gateway 的列表次数预算。
    func testSessionListPollsFastOnlyWhileAnExpectedLiveStreamIsDown() async throws {
        let fixture = await makeHeldStore(id: "claude_poll_cadence", supportsTakeover: true)
        let store = fixture.store
        let fast = store.sessionListDisconnectedPollingDelayNanoseconds
        let normal = store.sessionListConnectedPollingDelayNanoseconds
        XCTAssertEqual(store.selectedSessionID, fixture.held.id)

        store.setWebSocketStatus(.disconnected)
        XCTAssertEqual(store.sessionListPollingDelayNanoseconds(), normal, "电脑端持有的会话没有可写事件流")

        store.updateSession(fixture.held.id) { session in
            session.canAcceptDirectInput = true
            session.claudeOwner = nil
        }
        XCTAssertEqual(store.sessionListPollingDelayNanoseconds(), fast, "可控会话的事件流断开时靠轮询兜底")

        store.setWebSocketStatus(.connected)
        XCTAssertEqual(store.sessionListPollingDelayNanoseconds(), normal)

        store.setWebSocketStatus(.disconnected)
        store.selectedSessionID = nil
        XCTAssertEqual(store.sessionListPollingDelayNanoseconds(), normal, "列表页没有选中会话")
    }

    /// #683：没有被页面订阅的会话收到持有方状态推送时，运行时把快照交给列表观察者，
    /// 并把 active / busy 读成"电脑端运行中"、把随附的最后活动时间写进会话。
    func testStatusPushForUnsubscribedSessionReachesTheIndexObserverWithRunState() async throws {
        let fixture = await makeHeldStore(id: "claude_index_push", supportsTakeover: true)
        let (runtime, _, _) = makeTakeoverRuntime(session: fixture.held)
        // 电脑端执行时打开会话：thread/read 把最后一轮标成进行中，缓存里留下它的 turn ID。
        var openedWhileBusy = fixture.held
        openedWhileBusy.activeTurnID = "turn-read-while-busy"
        await runtime.rememberForkedSession(openedWhileBusy)
        let observed = ObservedSessions()
        await runtime.setSessionIndexObserver { session in observed.append(session) }

        func statusChanged(type: String, owner: [String: CodexAppServerJSONValue]?, updatedAt: Int64?) async {
            var params: [String: CodexAppServerJSONValue] = [
                "threadId": .string(fixture.held.id),
                "status": .object(["type": .string(type), "activeFlags": .array([])]),
                "canAcceptDirectInput": .bool(owner == nil)
            ]
            params["claudeOwner"] = owner.map { .object($0) } ?? .null
            if let updatedAt { params["updatedAt"] = .int(updatedAt) }
            await runtime.handle(CodexAppServerNotification(method: "thread/status/changed", params: .object(params)))
        }

        await statusChanged(type: "active", owner: [
            "entrypoint": .string("claude-desktop"), "kind": .string("interactive"), "status": .string("busy"),
            "pid": .int(4242), "statusUpdatedAt": .int(1_791_803_198_629)
        ], updatedAt: 1_791_803_200)
        let running = try XCTUnwrap(observed.last)
        XCTAssertEqual(running.status, SessionStatus.running.rawValue)
        XCTAssertTrue(running.isRunningOnComputer)
        XCTAssertEqual(running.claudeOwner?.statusUpdatedAt, Date(timeIntervalSince1970: 1_791_803_198.629))
        XCTAssertEqual(running.updatedAt, Date(timeIntervalSince1970: 1_791_803_200))
        XCTAssertEqual(running.displayStatus(foregroundActivity: nil).title, L10n.text("ui.running_on_computer"))

        // 持有方转空闲：回到只读的历史，时间不倒退；缓冲区里的快照与观察者拿到的一致。
        await statusChanged(type: "idle", owner: [
            "entrypoint": .string("claude-desktop"), "kind": .string("interactive"), "status": .string("idle"), "pid": .int(4242)
        ], updatedAt: 1_791_803_100)
        let idle = try XCTUnwrap(observed.last)
        XCTAssertEqual(idle.status, SessionStatus.history.rawValue)
        XCTAssertFalse(idle.isRunning)
        XCTAssertNil(idle.activeTurnID, "持有方空闲后不能留下读历史时的进行中 turn")
        XCTAssertEqual(idle.activityState, .idle)
        XCTAssertEqual(idle.claudeOwner?.status, "idle")
        XCTAssertEqual(idle.updatedAt, Date(timeIntervalSince1970: 1_791_803_200))
        // 缓冲区里留给稍后打开详情回放的快照，与观察者拿到的是同一份状态。
        let buffered = await runtime.bufferedEvents(sessionID: fixture.held.id, replayPolicy: .stateOnly)
        let replayed = try XCTUnwrap(buffered.compactMap { event -> AgentSession? in
            if case .session(let session) = event { return session }
            return nil
        }.last)
        XCTAssertEqual(replayed.status, idle.status)
        XCTAssertEqual(replayed.claudeOwner, idle.claudeOwner)
        XCTAssertEqual(replayed.updatedAt, idle.updatedAt)

        // 持有方退出：恢复可写。
        await statusChanged(type: "notLoaded", owner: nil, updatedAt: nil)
        let released = try XCTUnwrap(observed.last)
        XCTAssertTrue(released.allowsDirectInput)
        XCTAssertNil(released.claudeOwner)
        XCTAssertEqual(observed.count, 3)
        await runtime.shutdownForHostSwitch()
    }

    func testComputerWaitingStatusPushProjectsAReadOnlyReason() async throws {
        let fixture = await makeHeldStore(id: "claude_waiting_push", supportsTakeover: true)
        let (runtime, _, _) = makeTakeoverRuntime(session: fixture.held)
        await runtime.rememberForkedSession(fixture.held)
        let observed = ObservedSessions()
        await runtime.setSessionIndexObserver { session in observed.append(session) }
        for raw in ["permission", "input", "other", "future_reason"] {
            await runtime.handle(CodexAppServerNotification(method: "thread/status/changed", params: .object([
                "threadId": .string(fixture.held.id),
                "status": .object(["type": .string("active"), "activeFlags": .array([.string(raw == "permission" ? "waitingOnApproval" : "waitingOnUserInput")])]),
                "canAcceptDirectInput": .bool(false),
                "claudeOwner": .object([
                    "entrypoint": .string("cli"), "status": .string("waiting"), "pid": .int(4242),
                    "waitingKind": .string(raw), "statusUpdatedAt": .int(1_791_803_198_629)
                ])
            ])))
            let projected = try XCTUnwrap(observed.last)
            let reason = ClaudeSessionOwner.WaitingKind(rawValue: raw) ?? .other
            XCTAssertEqual(projected.activityState, .needsYou(.computer(reason)))
            XCTAssertEqual(projected.claudeOwner?.statusUpdatedAt, Date(timeIntervalSince1970: 1_791_803_198.629))
            XCTAssertNil(projected.pendingApproval)
            XCTAssertNil(projected.pendingUserInput)
            fixture.store.upsert(projected)
            let notice = try XCTUnwrap(fixture.store.selectedOwnershipNotice)
            XCTAssertEqual(notice.title, reason.title)
            XCTAssertEqual(notice.message, reason.message)
            XCTAssertFalse(notice.canTakeOver)
        }
        await runtime.shutdownForHostSwitch()
    }

    /// #683：用户在 Mimi 回合进行中离开详情页，回合结束时列表也要收到终态，而不是停在运行中。
    func testTurnCompletionForUnsubscribedSessionReachesTheIndexAsTerminal() async throws {
        let fixture = await makeHeldStore(id: "claude_index_complete", supportsTakeover: true)
        let (runtime, _, _) = makeTakeoverRuntime(session: fixture.held)
        var driving = fixture.held
        driving.canAcceptDirectInput = true
        driving.claudeOwner = nil
        await runtime.rememberForkedSession(driving)
        let observed = ObservedSessions()
        await runtime.setSessionIndexObserver { session in observed.append(session) }

        func turnEvent(_ method: String, turnID: String, status: String) async {
            await runtime.handle(CodexAppServerNotification(method: method, params: .object([
                "threadId": .string(driving.id),
                "turn": .object(["id": .string(turnID), "status": .string(status), "items": .array([])])
            ])))
        }

        await turnEvent("turn/started", turnID: "turn-left-behind", status: "inProgress")
        let running = try XCTUnwrap(observed.last)
        XCTAssertEqual(running.activeTurnID, "turn-left-behind")
        XCTAssertTrue(running.isRunning)

        await turnEvent("turn/completed", turnID: "turn-left-behind", status: "completed")
        let done = try XCTUnwrap(observed.last)
        XCTAssertEqual(done.status, SessionStatus.completed.rawValue, "终态快照不能停在 running")
        XCTAssertNil(done.activeTurnID)
        XCTAssertEqual(done.activityState, .idle)

        await runtime.handle(CodexAppServerNotification(method: "thread/name/updated", params: .object([
            "threadId": .string(driving.id), "threadName": .string("完成后改名")
        ])))
        await runtime.handle(CodexAppServerNotification(method: "thread/status/changed", params: .object([
            "threadId": .string(driving.id), "status": .object(["type": .string("idle")]),
            "updatedAt": .int(1)
        ])))
        let settled = try XCTUnwrap(observed.last)
        XCTAssertEqual(settled.status, SessionStatus.completed.rawValue, "迟到的 idle 不能抹掉明确终态")
        XCTAssertEqual(settled.title, "完成后改名")
        XCTAssertEqual(settled.updatedAt, done.updatedAt, "保留终态时不能把本地完成时间回退到旧 idle")
        let cachedSession = await runtime.contextsBySessionID[driving.id]?.session
        let cachedDone = try XCTUnwrap(cachedSession)
        XCTAssertEqual(cachedDone.status, SessionStatus.completed.rawValue, "canonical 缓存必须与列表终态一致")

        let newerRemoteTime = try XCTUnwrap(done.updatedAt).addingTimeInterval(1)
        await runtime.handle(CodexAppServerNotification(method: "thread/status/changed", params: .object([
            "threadId": .string(driving.id), "status": .object(["type": .string("idle")]),
            "updatedAt": .double(newerRemoteTime.timeIntervalSince1970)
        ])))
        XCTAssertEqual(observed.last?.status, SessionStatus.history.rawValue, "更新的远端活动应结束旧终态保留")

        await turnEvent("turn/started", turnID: "turn-fails", status: "inProgress")
        await turnEvent("turn/completed", turnID: "turn-fails", status: "failed")
        let failed = try XCTUnwrap(observed.last)
        XCTAssertEqual(failed.status, SessionStatus.failed.rawValue)
        XCTAssertEqual(failed.activityState, .failed)
        await runtime.handle(CodexAppServerNotification(method: "thread/status/changed", params: .object([
            "threadId": .string(driving.id), "status": .object(["type": .string("notLoaded")])
        ])))
        XCTAssertEqual(observed.last?.status, SessionStatus.failed.rawValue)
        let beforeLateResolved = observed.count
        await runtime.emitApprovalResolved(sessionID: driving.id)
        XCTAssertEqual(observed.count, beforeLateResolved, "迟到 resolved 不能把终态恢复为 running")

        // 旧回合的迟到完成不能把新开始的回合写成终态。
        await turnEvent("turn/started", turnID: "turn-new", status: "inProgress")
        let before = observed.count
        await turnEvent("turn/completed", turnID: "turn-fails", status: "completed")
        XCTAssertFalse(observed.items(after: before).contains { $0.status == SessionStatus.completed.rawValue })
        await runtime.shutdownForHostSwitch()
    }

    func testSubscribedTurnCompletionPublishesCanonicalTerminalBeforeBusinessEvent() async throws {
        let fixture = await makeHeldStore(id: "claude_terminal_order", supportsTakeover: true)
        let (runtime, _, _) = makeTakeoverRuntime(session: fixture.held)
        var running = fixture.held
        running.status = SessionStatus.running.rawValue
        running.activeTurnID = "turn-order"
        running.canAcceptDirectInput = true
        running.claudeOwner = nil
        await runtime.rememberForkedSession(running)
        let stream = await runtime.attachEvents(sessionID: running.id)
        defer { stream.cancel() }

        await runtime.handle(CodexAppServerNotification(method: "turn/completed", params: .object([
            "threadId": .string(running.id),
            "turn": .object(["id": .string("turn-order"), "status": .string("failed")])
        ])))

        var iterator = stream.makeAsyncIterator()
        guard case .session(let terminal)? = await iterator.next() else {
            return XCTFail("终态业务事件前应先发布 canonical session")
        }
        XCTAssertEqual(terminal.status, SessionStatus.failed.rawValue)
        XCTAssertNil(terminal.activeTurnID)
        guard case .turnCompleted(let metadata)? = await iterator.next() else {
            return XCTFail("canonical session 后应发布 turnCompleted")
        }
        XCTAssertEqual(metadata.turnLifecycle, .failed)
        await runtime.shutdownForHostSwitch()
    }

    func testUnsubscribedReplayedInteractionsSynchronizeAndResolveCanonicalSession() async throws {
        let fixture = await makeHeldStore(id: "claude_pending_index", supportsTakeover: true)
        let (runtime, _, _) = makeTakeoverRuntime(session: fixture.held)
        var running = fixture.held
        running.status = SessionStatus.running.rawValue
        running.activeTurnID = "turn-pending"
        running.canAcceptDirectInput = true
        running.claudeOwner = nil
        await runtime.rememberForkedSession(running)
        let observed = ObservedSessions()
        await runtime.setSessionIndexObserver { observed.append($0) }

        func replay(id: String, method: String, itemID: String, extra: [String: CodexAppServerJSONValue]) async {
            var params = extra
            params["threadId"] = .string(running.id)
            params["turnId"] = .string("turn-pending")
            params["itemId"] = .string(itemID)
            await runtime.handle(CodexAppServerNotification(method: "serverRequest/replay", params: .object([
                "outstanding": .array([.object([
                    "id": .string(id), "method": .string(method), "params": .object(params)
                ])])
            ])))
        }

        await replay(
            id: "approval-wire", method: "item/commandExecution/requestApproval", itemID: "approval-card",
            extra: ["command": .string("swift test")]
        )
        XCTAssertEqual(observed.last?.status, SessionStatus.waitingForApproval.rawValue)
        XCTAssertEqual(observed.last?.pendingApproval?.id, "approval-card")
        await runtime.handle(CodexAppServerNotification(method: "serverRequest/resolved", params: .object([
            "threadId": .string(running.id), "requestId": .string("approval-wire")
        ])))
        XCTAssertEqual(observed.last?.status, SessionStatus.running.rawValue)
        XCTAssertNil(observed.last?.pendingApproval)

        await replay(
            id: "input-wire", method: "item/tool/requestUserInput", itemID: "input-card",
            extra: ["questions": .array([.object([
                "id": .string("scope"), "header": .string("范围"), "question": .string("处理哪里？"),
                "isOther": .bool(true), "isSecret": .bool(false), "options": .array([])
            ])])]
        )
        XCTAssertEqual(observed.last?.status, SessionStatus.waitingForInput.rawValue)
        XCTAssertEqual(observed.last?.pendingUserInput?.id, "input-card")
        await runtime.handle(CodexAppServerNotification(method: "serverRequest/resolved", params: .object([
            "threadId": .string(running.id), "requestId": .string("input-wire")
        ])))
        XCTAssertEqual(observed.last?.status, SessionStatus.running.rawValue)
        XCTAssertNil(observed.last?.pendingUserInput)

        let old = CodexAppServerServerRequest(
            id: .string("old-wire"), method: "item/commandExecution/requestApproval",
            params: .object(["threadId": .string(running.id), "turnId": .string("turn-pending"), "itemId": .string("old-card")])
        )
        let new = CodexAppServerServerRequest(
            id: .string("new-wire"), method: "item/commandExecution/requestApproval",
            params: .object(["threadId": .string(running.id), "turnId": .string("turn-pending"), "itemId": .string("new-card")])
        )
        await runtime.handle(old)
        await runtime.handle(new)
        await runtime.handle(CodexAppServerNotification(method: "serverRequest/resolved", params: .object([
            "threadId": .string(running.id), "requestId": .string("old-wire")
        ])))
        XCTAssertEqual(observed.last?.status, SessionStatus.waitingForApproval.rawValue)
        XCTAssertEqual(observed.last?.pendingApproval?.id, "new-card", "旧 resolved 不能清掉更新的同类请求")
        await runtime.handle(CodexAppServerNotification(method: "serverRequest/resolved", params: .object([
            "threadId": .string(running.id), "requestId": .string("new-wire")
        ])))

        let remaining = CodexAppServerServerRequest(
            id: .string("remaining-wire"), method: "item/commandExecution/requestApproval",
            params: .object(["threadId": .string(running.id), "turnId": .string("turn-pending"), "itemId": .string("remaining-card")])
        )
        let newest = CodexAppServerServerRequest(
            id: .string("newest-wire"), method: "item/commandExecution/requestApproval",
            params: .object(["threadId": .string(running.id), "turnId": .string("turn-pending"), "itemId": .string("newest-card")])
        )
        await runtime.handle(remaining)
        await runtime.handle(newest)
        await runtime.handle(CodexAppServerNotification(method: "serverRequest/resolved", params: .object([
            "threadId": .string(running.id), "requestId": .string("newest-wire")
        ])))
        XCTAssertEqual(observed.last?.status, SessionStatus.waitingForApproval.rawValue)
        XCTAssertEqual(observed.last?.pendingApproval?.id, "remaining-card", "当前请求解决后应恢复仍未解决的同类请求")

        let refreshed = try await runtime.agentSession(from: [
            "id": .string(running.id), "cwd": .string(running.dir),
            "status": .object(["type": .string("active"), "activeFlags": .array([.string("waitingOnApproval")])]),
            "updatedAt": .int(4_000_000_000),
            "turns": .array([.object([
                "id": .string("turn-fresh"), "status": .string("inProgress"), "items": .array([])
            ])])
        ], projects: [], fallbackProject: nil)
        XCTAssertEqual(refreshed.status, SessionStatus.waitingForApproval.rawValue)
        XCTAssertEqual(refreshed.activeTurnID, "turn-fresh")
        XCTAssertNil(refreshed.pendingApproval, "更新一轮的权威快照不能继承旧审批 payload")
        await runtime.shutdownForHostSwitch()
    }

    func testTurnIndependentMCPKeepsBaseStatusThroughRequestAndResolution() async throws {
        let fixture = await makeHeldStore(id: "claude_independent_mcp", supportsTakeover: true)
        let (runtime, _, _) = makeTakeoverRuntime(session: fixture.held)
        var completed = fixture.held
        completed.status = SessionStatus.completed.rawValue
        completed.activeTurnID = nil
        completed.canAcceptDirectInput = true
        completed.claudeOwner = nil
        await runtime.rememberForkedSession(completed)
        let stream = await runtime.attachEvents(sessionID: completed.id)
        defer { stream.cancel() }
        let request = CodexAppServerServerRequest(
            id: .string("oauth-wire"), method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string(completed.id), "serverName": .string("calendar"),
                "mode": .string("url"), "message": .string("请完成授权"),
                "url": .string("https://example.test/oauth")
            ])
        )

        await runtime.handle(request)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        guard case .approvalRequest(_, _)? = await iterator.next(),
              case .session(let pending)? = await iterator.next() else {
            return XCTFail("独立 MCP 请求后应以 canonical session 收敛")
        }
        XCTAssertEqual(pending.status, SessionStatus.completed.rawValue)
        XCTAssertEqual(pending.pendingApproval?.id, "oauth-wire")

        await runtime.handle(CodexAppServerNotification(method: "serverRequest/resolved", params: .object([
            "threadId": .string(completed.id), "requestId": .string("oauth-wire")
        ])))
        _ = await iterator.next()
        guard case .approvalResolved(_)? = await iterator.next(),
              case .session(let resolved)? = await iterator.next() else {
            return XCTFail("独立 MCP resolved 后应以 canonical session 收敛")
        }
        XCTAssertEqual(resolved.status, SessionStatus.completed.rawValue)
        XCTAssertNil(resolved.pendingApproval)
        let cached = await runtime.contextsBySessionID[completed.id]?.session
        XCTAssertEqual(cached?.status, SessionStatus.completed.rawValue)
        XCTAssertNil(cached?.pendingApproval)
        await runtime.shutdownForHostSwitch()
    }

    func testResolvedWithoutCanonicalContextStillPublishesBusinessEvent() async throws {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://localhost:8787", token: "test-token")
        let stream = await runtime.attachEvents(sessionID: "missing-context")
        defer { stream.cancel() }
        await runtime.rememberPendingApprovalRequest(CodexAppServerServerRequest(
            id: .string("missing-wire"), method: "item/commandExecution/requestApproval",
            params: .object(["threadId": .string("missing-context"), "itemId": .string("missing-card")])
        ))

        await runtime.handle(CodexAppServerNotification(method: "serverRequest/resolved", params: .object([
            "threadId": .string("missing-context"), "requestId": .string("missing-wire")
        ])))

        var iterator = stream.makeAsyncIterator()
        guard case .approvalResolved(let metadata)? = await iterator.next() else {
            return XCTFail("缺少 canonical context 时仍需交付 resolved 业务事件")
        }
        XCTAssertEqual(metadata.sessionID, "missing-context")
        await runtime.shutdownForHostSwitch()
    }

    private final class ObservedSessions: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AgentSession] = []

        func append(_ session: AgentSession) {
            lock.lock()
            defer { lock.unlock() }
            items.append(session)
        }

        var last: AgentSession? {
            lock.lock()
            defer { lock.unlock() }
            return items.last
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return items.count
        }

        func items(after index: Int) -> [AgentSession] {
            lock.lock()
            defer { lock.unlock() }
            return Array(items.dropFirst(index))
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
