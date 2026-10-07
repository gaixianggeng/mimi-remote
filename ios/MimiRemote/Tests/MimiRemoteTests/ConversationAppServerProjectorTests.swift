import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testClaudeQuotaPresentationFiltersCompatibilityWarningsAndUsesRuntimeName() throws {
        var projector = CodexAppServerEventProjector()

        let claudeQuotaWarning = try decodeAppServerNotification(#"{"method":"warning","params":{"threadId":"thr_demo","message":"claude rate-limit status: allowed_warning (resets_at=123)"}}"#)
        XCTAssertNil(projector.project(claudeQuotaWarning))

        let interruptMarker = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"userMessage","id":"interrupt_marker","clientId":"client_interrupt","content":[{"type":"text","text":"[Request interrupted by user]\n"}]}}}"#)
        XCTAssertNil(projector.project(interruptMarker))
        XCTAssertFalse(isVisibleAppServerUserMessageText("[Request interrupted by user]\n"))
        XCTAssertTrue(isVisibleAppServerUserMessageText("讨论 [Request interrupted by user] 的含义"))

        let now = Date(timeIntervalSince1970: 1_780_490_700)
        let claudeNotice = try XCTUnwrap(CodexQuotaNotice.make(
            rateLimit: RateLimitSummary(
                limitID: "claude",
                limitName: "Claude",
                reachedType: "rejected",
                primaryUsedPercent: 91,
                primaryResetsAt: Int64(now.timeIntervalSince1970) + 3_600
            ),
            errorMessage: nil,
            now: now
        ))
        XCTAssertEqual(claudeNotice.title, L10n.format("ui.value_message_quota_has_been_exhausted", "Claude"))
        XCTAssertTrue(claudeNotice.blocksSending)
    }

    func testCodexAppServerProjectorKeepsLiveToolActionAndLifecycleSemantics() throws {
        var projector = CodexAppServerEventProjector()

        let started = try decodeAppServerNotification(#"{"method":"item/started","params":{"threadId":"thr_tools","turnId":"turn_tools","item":{"type":"dynamicToolCall","id":"task_list","namespace":"codex_app","tool":"list_threads"}}}"#)
        guard case .processItemCompleted(let runningMessage, let runningContext, let runningMetadata) = try XCTUnwrap(projector.project(started)) else {
            return XCTFail("Tool started 应立即投影为可见过程行")
        }
        XCTAssertEqual(runningMessage.activityPayload?.displayTitle, L10n.text("ui.query_task_list"))
        XCTAssertEqual(runningMessage.activityPayload?.displayStatusText, L10n.text("ui.in_progress"))
        XCTAssertEqual(runningMessage.activityPayload?.toolPresentationKind, .independentTaskQuery)
        XCTAssertEqual(runningContext?.tasks.first?.status, "inProgress")

        let completed = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_tools","turnId":"turn_tools","item":{"type":"dynamicToolCall","id":"task_list","namespace":"codex_app","tool":"list_threads","status":"completed"}}}"#)
        guard case .processItemCompleted(let completedMessage, _, let completedMetadata) = try XCTUnwrap(projector.project(completed)) else {
            return XCTFail("Tool completed 应原位更新过程行")
        }
        XCTAssertEqual(completedMessage.id, runningMessage.id)
        XCTAssertEqual(completedMetadata.messageID, runningMetadata.messageID)
        XCTAssertEqual(completedMessage.activityPayload?.displayStatusText, L10n.text("ui.completed_status"))

        let terminalCases: [(id: String, tool: String, status: String, statusKey: String)] = [
            ("task_start", "create_thread", "failed", "ui.failed_status"),
            ("task_wait", "wait_threads", "timed_out", "ui.timed_out_status"),
            ("task_resume", "send_message_to_thread", "interrupted", "ui.interrupted_status"),
        ]
        for terminalCase in terminalCases {
            let event = try decodeAppServerNotification(
                #"{"method":"item/completed","params":{"threadId":"thr_tools","turnId":"turn_tools","item":{"type":"dynamicToolCall","id":"\#(terminalCase.id)","namespace":"codex_app","tool":"\#(terminalCase.tool)","status":"\#(terminalCase.status)"}}}"#
            )
            guard case .processItemCompleted(let message, _, _) = try XCTUnwrap(projector.project(event)) else {
                return XCTFail("Expected visible \(terminalCase.tool) event")
            }
            XCTAssertEqual(message.activityPayload?.displayStatusText, L10n.text(terminalCase.statusKey))
            XCTAssertTrue(message.activityPayload?.accessibilityDescription.contains(L10n.text(terminalCase.statusKey)) == true)
            XCTAssertNotEqual(message.activityPayload?.displayTitle, L10n.text("ui.call_tool"))
        }
    }

    // MIM-120：缺 name/preview 的会话只能拿到稳定占位标题，不能暴露 thread id。
    func testThreadListPlaceholderTitleNeverEmbedsThreadID() async throws {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let placeholder = L10n.text("ui.unnamed_session")
        let threads: [[String: CodexAppServerJSONValue]] = [
            [
                "id": .string("019f36d2-0000-7000-8000-000000000001"),
                "cwd": .string(project.path),
                "status": .object(["type": .string("idle")]),
            ],
            [
                "id": .string("019f36d2-0000-7000-8000-000000000002"),
                "cwd": .string(project.path),
                "name": .string("   "),
                "preview": .string("  \n "),
                "status": .object(["type": .string("idle")]),
            ],
            [
                "id": .string("sonnet"),
                "cwd": .string(project.path),
                "status": .object(["type": .string("idle")]),
            ],
        ]

        for thread in threads {
            let session = try await runtime.agentSession(
                from: thread,
                projects: [project],
                fallbackProject: project
            )
            let id = try XCTUnwrap(thread["id"]?.stringValue)
            XCTAssertEqual(session.title, placeholder, "缺标题信息时必须使用稳定占位标题")
            XCTAssertFalse(session.title.contains(id), "占位标题不能内嵌 thread id")
            XCTAssertEqual(session.id, id, "占位标题不得改写真实 thread id")
            XCTAssertEqual(session.resumeID, id, "恢复仍要走真实 thread id")
        }
    }

    // 有名称或首条用户消息时不能被占位标题顶掉，空白 name 也必须回退到 preview。
    func testThreadListKeepsRealNameAndPreviewFirstLine() async throws {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let cases: [([String: CodexAppServerJSONValue], String)] = [
            ([
                "id": .string("thread-named"),
                "cwd": .string(project.path),
                "name": .string("  重构会话列表  "),
                "preview": .string("忽略我"),
            ], "重构会话列表"),
            ([
                "id": .string("thread-preview"),
                "cwd": .string(project.path),
                "preview": .string("修一下底部色差\n第二行不要"),
            ], "修一下底部色差"),
            ([
                "id": .string("thread-blank-name"),
                "cwd": .string(project.path),
                "name": .string("   "),
                "preview": .string("保留这条真实首消息\n第二行不要"),
            ], "保留这条真实首消息"),
        ]

        for (thread, expectedTitle) in cases {
            let session = try await runtime.agentSession(
                from: thread,
                projects: [project],
                fallbackProject: project
            )
            XCTAssertEqual(session.title, expectedTitle)
        }
    }

}

@MainActor
extension ConversationDataFlowTests {
    func testFailedTurnCompletionKeepsReasonAndTerminalBehavior() async throws {
        var projector = CodexAppServerEventProjector()
        let turn = failureReasonTestTurn()
        let event = try XCTUnwrap(projector.project(failureReasonTestCompletion(turn)))
        guard case .turnCompleted(let metadata) = event else {
            return XCTFail("展示错误不能改变 completion 的队列与迟到事件语义")
        }
        XCTAssertEqual(metadata.turnLifecycle, .failed)
        XCTAssertEqual(metadata.turnError?.message, failureReasonTestMessage)
        XCTAssertEqual(metadata.turnID, "turn-failure-reason")
        guard case .turnCompleted(let replayMetadata) = event.withReplayBoundarySequence(42, epoch: 3) else {
            return XCTFail("Expected completion with replay boundary")
        }
        XCTAssertEqual(replayMetadata.turnError, metadata.turnError)
        XCTAssertEqual(replayMetadata.replayBoundarySequence, 42)

        let output = await EventReducer().reduce(event, fallbackSessionID: "wrong-thread", outputIdleClearDelay: 0)
        XCTAssertEqual(output.statusUpdates.first?.0, "thread-failure-reason")
        XCTAssertEqual(output.statusUpdates.first?.1, SessionStatus.failed.rawValue)
        XCTAssertTrue(output.messageMutations.contains {
            if case .markCurrentAssistantCompleted = $0 { return true }
            return false
        })
        guard case .completed(let message, _, _) = try XCTUnwrap(output.messageMutations.first) else {
            return XCTFail("具体原因必须进入可见错误消息")
        }
        XCTAssertEqual(message.kind, .error)
        XCTAssertTrue(message.content.contains(failureReasonTestMessage))
    }

    func testTurnFailureReasonMergesLiveHistoryAndRepeatedNotifications() async throws {
        let conversation = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversation,
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        let reducer = EventReducer()
        var projector = CodexAppServerEventProjector()
        let turn = failureReasonTestTurn()
        let separateError = CodexAppServerNotification(method: "error", params: .object([
            "threadId": .string("thread-failure-reason"),
            "turnId": .string("turn-failure-reason"),
            "error": turn["error"]!,
            "willRetry": .bool(false)
        ]))
        for notification in [separateError, failureReasonTestCompletion(turn)] {
            let event = try XCTUnwrap(projector.project(notification))
            store.applyEventReducerOutput(await reducer.reduce(event, fallbackSessionID: "wrong-thread", outputIdleClearDelay: 0))
        }
        let original = try XCTUnwrap(conversation.messages(for: "thread-failure-reason").first)
        XCTAssertEqual(conversation.messages(for: "thread-failure-reason").count, 1)

        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let history = await runtime.historyMessages(
            fromTurns: [turn], sessionID: "thread-failure-reason", snapshotReadAt: Date()
        )
        conversation.setHistory(history, sessionID: "thread-failure-reason")
        conversation.setHistory(history, sessionID: "thread-failure-reason")
        let replay = try XCTUnwrap(projector.project(failureReasonTestCompletion(turn)))
        store.applyEventReducerOutput(await reducer.reduce(replay, fallbackSessionID: "wrong-thread", outputIdleClearDelay: 0))
        let messages = conversation.messages(for: "thread-failure-reason")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, original.id)
        XCTAssertEqual(messages.first?.turnLifecycle, .failed)
        XCTAssertTrue(messages.first?.content.contains(failureReasonTestMessage) == true)
        guard case .message(let visibleError) = try XCTUnwrap(ConversationTimelineItemBuilder.items(from: messages).first) else {
            return XCTFail("错误原因不能折叠进已处理组")
        }
        XCTAssertEqual(visibleError.kind, .error)
    }

    func testHistoricalFailedTurnShowsReasonAfterUserItem() async throws {
        var turn = failureReasonTestTurn()
        turn["items"] = .array([.object([
            "id": .string("failure-user"), "type": .string("userMessage"),
            "content": .array([.object(["type": .string("text"), "text": .string("test")])])
        ])])
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let history = await runtime.historyMessages(
            fromTurns: [turn], sessionID: "thread-failure-reason", snapshotReadAt: Date()
        )
        XCTAssertEqual(history.map(\.kind), [.message, .error])
        XCTAssertEqual(history.map(\.role), ["user", "system"])
        XCTAssertEqual(history.last?.createdAt, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(history.last?.content.contains(failureReasonTestMessage) == true)
        XCTAssertGreaterThan(try XCTUnwrap(history.last?.timelineOrdinal), try XCTUnwrap(history.first?.timelineOrdinal))
    }

    func testTurnFailureReasonIgnoresEmptyErrorsAndNonFailedTurns() async throws {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let cases: [(String, CodexAppServerJSONValue)] = [
            ("failed", .null), ("failed", .string(" \n ")),
            ("failed", .object(["message": .string(" ")])),
            ("completed", .object(["message": .string(failureReasonTestMessage)])),
            ("interrupted", .object(["message": .string(failureReasonTestMessage)]))
        ]
        for (status, error) in cases {
            var turn = failureReasonTestTurn()
            turn["status"] = .string(status)
            turn["error"] = error
            var projector = CodexAppServerEventProjector()
            guard case .turnCompleted(let metadata) = try XCTUnwrap(projector.project(failureReasonTestCompletion(turn))) else {
                return XCTFail("Expected completion")
            }
            XCTAssertNil(metadata.turnError)
            let history = await runtime.historyMessages(
                fromTurns: [turn], sessionID: "thread-failure-reason", snapshotReadAt: Date()
            )
            XCTAssertTrue(history.isEmpty)
        }
    }

    func testHistoricalTurnErrorSupportsStringAndClaudeRecovery() async throws {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        var turn = failureReasonTestTurn()
        turn["error"] = .string("  \(failureReasonTestMessage)\n")
        let stringHistory = await runtime.historyMessages(
            fromTurns: [turn], sessionID: "thread-failure-reason", snapshotReadAt: Date()
        )
        XCTAssertEqual(stringHistory.first?.content, L10n.format("ui.run_error_value", failureReasonTestMessage))
        turn["error"] = .object([
            "message": .string("Failed to authenticate"),
            "code": .string(ClaudeAuthenticationRecovery.errorCode)
        ])
        let recoveryHistory = await runtime.historyMessages(
            fromTurns: [turn], sessionID: "thread-failure-reason", snapshotReadAt: Date()
        )
        XCTAssertEqual(recoveryHistory.first?.content, ClaudeAuthenticationRecovery.recoveryMessage)
        XCTAssertTrue(recoveryHistory.first?.activityPayload?.isClaudeAuthenticationRecovery == true)
    }

    func testTurnErrorMetadataRemainsCompatibleWithOlderEvents() throws {
        let legacyData = Data(#"{"session_id":"thread-failure-reason","turn_id":"turn-failure-reason","turn_lifecycle":"failed"}"#.utf8)
        let legacy = try JSONDecoder().decode(AgentEventMetadata.self, from: legacyData)
        XCTAssertNil(legacy.turnError)
        let updated = legacy.withTurnLifecycle(.failed, error: AgentErrorPayload(
            message: failureReasonTestMessage, code: nil, retryable: false
        ))
        let decoded = try JSONDecoder().decode(AgentEventMetadata.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(decoded, updated)
    }

    private var failureReasonTestMessage: String {
        "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."
    }

    private func failureReasonTestTurn() -> [String: CodexAppServerJSONValue] {
        [
            "id": .string("turn-failure-reason"), "status": .string("failed"),
            "startedAt": .int(100), "completedAt": .int(200), "items": .array([]),
            "error": .object(["message": .string(failureReasonTestMessage)])
        ]
    }

    private func failureReasonTestCompletion(_ turn: [String: CodexAppServerJSONValue]) -> CodexAppServerNotification {
        CodexAppServerNotification(method: "turn/completed", params: .object([
            "threadId": .string("thread-failure-reason"), "turn": .object(turn)
        ]))
    }
}
