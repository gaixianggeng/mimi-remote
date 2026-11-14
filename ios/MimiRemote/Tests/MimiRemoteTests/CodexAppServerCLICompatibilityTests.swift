import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testCLIUnmaterializedThreadHasEmptyFirstHistoryPage() async throws {
        let (runtime, transport) = await makeCLICompatibilityRuntime()
        let read = Task { try await runtime.messagesPage(sessionID: "cli-thread", before: nil, limit: 1) }
        try await rejectCLIHistoryRequest(transport, message: unmaterializedCLIHistoryMessage)
        let page = try await read.value
        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertFalse(page.hasMoreBefore)
        XCTAssertNil(page.previousCursor)
        XCTAssertNil(page.notice)
    }

    func testCLIEmptyHistoryCompatibilityPreservesOtherErrorsAndOlderPageFailures() async throws {
        for (before, code, message) in [
            (nil, -32600, "thread cli-thread was not found"),
            (nil, -32001, unmaterializedCLIHistoryMessage),
            (nil, -32600, unmaterializedCLIHistoryMessage.replacingOccurrences(of: "cli-thread", with: "other-thread")),
            (CodexAppServerSessionRuntime.encodeThreadTurnsCursor("older"), -32600, unmaterializedCLIHistoryMessage)
        ] {
            let (runtime, transport) = await makeCLICompatibilityRuntime()
            let read = Task { try await runtime.messagesPage(sessionID: "cli-thread", before: before, limit: 1) }
            try await rejectCLIHistoryRequest(transport, code: code, message: message)
            do {
                _ = try await read.value
                XCTFail("只有当前会话第一页的明确空历史结果可以降级")
            } catch CodexAppServerConnectionError.appServer(let failure) {
                XCTAssertEqual(failure.code, code)
                XCTAssertEqual(failure.message, message)
            }
        }
    }

    func testCLICrossRepositoryApprovalSupportsOnceAndDeclineWithNumericRequestID() async throws {
        // 保留 CLI 0.167.2 实测请求的结构。混合的 availableDecisions 还包含永久命令规则，
        // 本次批准或拒绝都不能误回这类扩大授权的对象。
        let wire = #"{"id":0,"method":"item/commandExecution/requestApproval","params":{"kind":"command","threadId":"cli-thread","turnId":"cli-turn","itemId":"cli-command","startedAtMs":1790000000000,"environmentId":"local","reason":"Create a worktree outside the workspace","command":"git -C ../repo-b worktree add -b probe ../worktree main","cwd":"/workspace/repo-a","commandActions":[{"type":"unknown","command":"git -C ../repo-b worktree add -b probe ../worktree main"}],"proposedExecpolicyAmendment":["git","-C","../repo-b","worktree","add"],"availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["git","-C","../repo-b","worktree","add"]}},"cancel"]}}"#
        guard case .serverRequest(let request) = try JSONDecoder().decode(CodexAppServerMessage.self, from: Data(wire.utf8)) else {
            return XCTFail("Expected CLI approval request")
        }
        var projector = CodexAppServerEventProjector()
        guard case .approvalRequest(let approval, let metadata) = projector.project(request) else {
            return XCTFail("跨仓库 Git 操作必须进入已有命令审批")
        }
        XCTAssertEqual(approval.kind, "command")
        XCTAssertEqual(approval.id, "cli-command")
        XCTAssertEqual(metadata.sessionID, "cli-thread")
        XCTAssertEqual(approval.availableDecisions, ["accept", "cancel"])
        XCTAssertTrue(approval.body?.contains("../repo-b") == true)

        for decision in ["accept", "decline"] {
            let (runtime, transport) = await makeCLICompatibilityRuntime()
            await runtime.handle(request)
            let response = Task {
                try await runtime.respondToApproval(sessionID: "cli-thread", approvalID: "cli-command", decision: decision)
            }
            let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
            transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
            try await response.value
            let frames = await transport.sentMessages()
            let replies = try frames.compactMap { frame -> CodexAppServerResponse? in
                guard case .response(let reply) = try JSONDecoder().decode(CodexAppServerMessage.self, from: Data(frame.utf8)) else { return nil }
                return reply
            }
            XCTAssertEqual(replies.count, 1)
            XCTAssertEqual(replies.first?.id, request.id)
            XCTAssertEqual(replies.first?.result, .object(["decision": .string(decision)]))
        }
    }

    private var unmaterializedCLIHistoryMessage: String {
        "thread cli-thread is not materialized yet; thread/turns/list is unavailable before first user message"
    }

    private func makeCLICompatibilityRuntime() async -> (CodexAppServerSessionRuntime, FakeCodexAppServerTransport) {
        let project = AgentProject(id: "cli-project", name: "CLI", path: "/workspace/repo-a")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "test-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, allowedMethods: ["initialize", "initialized", "thread/turns/list"])
            }
        )
        await runtime.handle(CodexAppServerNotification(method: "thread/started", params: .object([
            "thread": .object(["id": .string("cli-thread"), "cwd": .string(project.path), "status": .object(["type": .string("idle")])])
        ])))
        return (runtime, transport)
    }

    private func rejectCLIHistoryRequest(
        _ transport: FakeCodexAppServerTransport,
        code: Int = -32600,
        message: String
    ) async throws {
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let request = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        let error = CodexAppServerResponse(id: request.id, result: nil, error: CodexAppServerError(code: code, message: message, data: nil))
        transport.enqueue(String(decoding: try JSONEncoder().encode(error), as: UTF8.self))
    }
}
