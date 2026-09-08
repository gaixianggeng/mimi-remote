import XCTest
@testable import MimiRemote

/// MIM-265：Claude 渠道的 itemsView 与历史提示。
/// 从 ConversationDirectRuntimeHistoryTests 拆出，该文件已达 check-source-size.sh
/// 的测试文件上限；这几个用例自成一个职责，独立成文件而不是加例外。
extension ConversationDataFlowTests {

    // Claude bridge 无视 itemsView，thread/turns/list 直接回完整 items 并标 itemsView=full。
    // 这类首屏已经是完整历史，不能再排 thread/items/list 补齐任务：Claude 渠道的 gateway
    // 白名单没有该方法，请求必被打回，一次成功的加载会被误报成"内容未加载"。
    func testDirectRuntimeClaudeFullHistorySkipsItemHydrationWhenTurnsCarryFullItems() async throws {
        let project = AgentProject(id: "proj_claude_hist", name: "Claude History", path: "/tmp/claude-history")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata()])
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_claude_hist", before: nil, limit: 120)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#
        )

        let metadataRead = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        transportResponse(
            transport,
            id: metadataRead.id,
            result: #"{"thread":{"id":"thr_claude_hist","sessionId":"thr_claude_hist","preview":"claude","ephemeral":false,"modelProvider":"anthropic","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/claude-history","cliVersion":"0.0.0","source":"claude","threadSource":"user","name":"claude","turns":[]}}"#
        )

        let turnsRequest = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        transportResponse(
            transport,
            id: turnsRequest.id,
            result: #"{"data":[{"id":"turn_claude","status":"completed","itemsView":"full","started_at":1780490300,"completed_at":1780490301,"items":[{"type":"userMessage","id":"claude_1","content":[{"type":"text","text":"claude question"}]},{"type":"agentMessage","id":"claude_2","text":"claude answer","phase":"final_answer"}]}],"nextCursor":null}"#
        )

        let page = try await pageTask.value
        XCTAssertEqual(page.messages.map(\.content), ["claude question", "claude answer"])
        XCTAssertTrue(
            page.itemContinuations.isEmpty,
            "itemsView=full 的 Turn 内容已经齐了，不该再排补齐任务"
        )
        XCTAssertNil(page.notice, "内容完整时不能声称有图片或工具输出未加载")

        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        XCTAssertFalse(
            requests.contains { $0.method == "thread/items/list" },
            "Claude 渠道没有 thread/items/list，一条都不该发出去"
        )
    }

    // 反向边界：Turn 确实只回了 summary，而这个 runtime 又补不了 Item。这时快照真的不完整，
    // 必须如实提示，不能因为不再排补齐任务就沉默地当成完整历史。
    func testDirectRuntimeReportsNoticeWhenSummaryTurnsCannotBeHydrated() async throws {
        let project = AgentProject(id: "proj_claude_summary", name: "Claude Summary", path: "/tmp/claude-summary")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata()])
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_claude_summary", before: nil, limit: 120)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#
        )

        let metadataRead = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        transportResponse(
            transport,
            id: metadataRead.id,
            result: #"{"thread":{"id":"thr_claude_summary","sessionId":"thr_claude_summary","preview":"claude","ephemeral":false,"modelProvider":"anthropic","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/claude-summary","cliVersion":"0.0.0","source":"claude","threadSource":"user","name":"claude","turns":[]}}"#
        )

        let turnsRequest = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        transportResponse(
            transport,
            id: turnsRequest.id,
            result: #"{"data":[{"id":"turn_summary","status":"completed","itemsView":"summary","started_at":1780490300,"completed_at":1780490301,"items":[{"type":"userMessage","id":"summary_1","content":[{"type":"text","text":"summary question"}]}]}],"nextCursor":null}"#
        )

        let page = try await pageTask.value
        XCTAssertTrue(page.itemContinuations.isEmpty, "补不了就不该排空转的补齐任务")
        XCTAssertEqual(
            page.notice,
            CodexAppServerSessionRuntime.economyHistoryNotice,
            "summary Turn 无法补齐时必须如实提示内容不完整"
        )
    }

    // 省流页只要非空就挂提示，会让"是否真的省了内容"这个判断形同虚设。
    func testEconomyHistoryNoticeRequiresRealLazyContentSignal() {
        let completeTurn: [String: CodexAppServerJSONValue] = [
            "id": .string("turn_full"),
            "itemsView": .string("full")
        ]
        XCTAssertNil(
            CodexAppServerSessionRuntime.historyNotice(
                loadMode: .economy,
                hasMoreBefore: false,
                turns: [completeTurn]
            ),
            "整页内容都在、也没有更早分页时不该提示"
        )

        let summaryTurn: [String: CodexAppServerJSONValue] = [
            "id": .string("turn_summary"),
            "itemsView": .string("summary")
        ]
        XCTAssertEqual(
            CodexAppServerSessionRuntime.historyNotice(
                loadMode: .economy,
                hasMoreBefore: false,
                turns: [summaryTurn]
            ),
            CodexAppServerSessionRuntime.economyHistoryNotice
        )
        XCTAssertEqual(
            CodexAppServerSessionRuntime.historyNotice(
                loadMode: .economy,
                hasMoreBefore: true,
                turns: [completeTurn]
            ),
            CodexAppServerSessionRuntime.economyHistoryNotice
        )
    }
}
