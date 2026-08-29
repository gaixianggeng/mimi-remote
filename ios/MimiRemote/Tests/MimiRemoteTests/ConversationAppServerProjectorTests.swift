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
