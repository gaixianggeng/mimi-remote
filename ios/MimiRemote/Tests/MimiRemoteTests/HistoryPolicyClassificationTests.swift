import XCTest
@testable import MimiRemote

/// 网关 -32080 拒绝的历史策略分类（#785）：只有限流、同请求占用与体量阻断才算历史策略失败，
/// 授权、作用域与参数校验类拒绝即使带 thread/read、thread/turns/list 方法名也不能触发缩略降级。
@MainActor
final class HistoryPolicyClassificationTests: XCTestCase {
    func testAuthorizationAndScopeRejectionsAreNotHistoryPolicyFailures() {
        let store = makeStore(client: OrderedHistoryPageClient(projects: [], page: SessionsPage(sessions: [])))

        // 回前台路由丢失（#784）或重新授权失败（#718）时网关返回的原文，不带 data.reason。
        XCTAssertNil(store.historyPolicyFailure(from: gatewayRejection("thread/read.threadId 未由当前 gateway 连接授权")))
        XCTAssertNil(store.historyPolicyFailure(from: gatewayRejection("thread/turns/list.threadId 未由当前 gateway 连接授权")))
        XCTAssertNil(store.historyPolicyFailure(from: gatewayRejection("thread/turns/list.limit 不能超过 50")))
        // 作用域校验带结构化 reason，但不是 history_*，同样与历史体量无关。
        XCTAssertNil(store.historyPolicyFailure(from: gatewayRejection(
            "thread/read 返回的只读子会话不在授权作用域",
            data: ["reason": .string("thread_read_scope_mismatch"), "threadId": .string("claude_small")]
        )))
    }

    func testStructuredAndLegacyHistoryPolicyRejectionsAreStillRecognized() {
        let store = makeStore(client: OrderedHistoryPageClient(projects: [], page: SessionsPage(sessions: [])))

        XCTAssertEqual(
            store.historyPolicyFailure(from: historyPolicyError(reason: "history_response_too_large"))?.reason,
            "history_response_too_large"
        )
        XCTAssertEqual(
            store.historyPolicyFailure(from: historyPolicyError(reason: "history_budget_limited", retryAfterMs: 1))?.isGatewayBusy,
            true
        )
        XCTAssertEqual(
            store.historyPolicyFailure(from: historyPolicyError(reason: "history_request_in_flight"))?.isGatewayBusy,
            true
        )

        // 旧版 agentd 不带 reason 的限流、预算与体量措辞仍按历史策略处理。
        let legacyMessages = [
            "thread/turns/list 同一 thread/method 正在临时限流，请稍后重试或降低 limit/itemsView",
            "thread/turns/list 同一 thread/method 请求过于频繁，请稍后重试",
            "thread/turns/list 同一 thread/method 请求字节预算已用尽，请稍后重试",
            "thread/read 同一 thread/method 历史响应预算已用尽，请稍后重试",
            "thread/read history response 过大（9000000 bytes > 5242880 bytes），gateway 已阻断；请降低 limit/itemsView 或改用分页读取"
        ]
        for message in legacyMessages {
            let failure = store.historyPolicyFailure(from: gatewayRejection(message))
            XCTAssertNotNil(failure, message)
            XCTAssertNil(failure?.reason, message)
        }
    }

    func testFullHistoryAuthorizationRejectionShowsFullFailureInsteadOfSummary() async {
        let project = makeProject(id: "proj_claude_unauthorized")
        let history = makeSession(
            id: "claude_small_unauthorized",
            projectID: project.id,
            title: "Claude 小会话",
            status: "history",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "small"
        )
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let store = makeStore(client: client)

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)
        client.failHistoryRequest(
            at: 0,
            with: gatewayRejection("thread/turns/list.threadId 未由当前 gateway 连接授权")
        )
        await selectTask.value

        XCTAssertEqual(client.requestedMessageLoadModes, [.full], "授权拒绝与体量无关，不能改发 economy")
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .fullFailed)
        XCTAssertNotEqual(store.historyLoadedQualityBySessionID[history.id], .summary)
        XCTAssertFalse(store.deferredFullHistorySessionIDs.contains(history.id))
        XCTAssertNotEqual(
            store.selectedHistorySavingsNotice?.message,
            L10n.text("ui.the_full_history_content_is_large_and_the")
        )
    }

    func testFullHistoryLegacyOversizeRejectionStillFallsBackToSummary() async {
        let project = makeProject(id: "proj_legacy_oversize")
        let history = makeSession(
            id: "codex_legacy_oversize",
            projectID: project.id,
            title: "旧版网关大历史",
            status: "history",
            source: "codex",
            resumeID: "legacy-large"
        )
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = makeStore(client: client, conversationStore: conversationStore)

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)
        client.failHistoryRequest(
            at: 0,
            with: gatewayRejection(
                "thread/turns/list history response 过大（9000000 bytes > 5242880 bytes），gateway 已阻断；请降低 limit/itemsView 或改用分页读取"
            )
        )
        await client.waitForHistoryRequestCount(2)

        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingSummary)

        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:legacy-summary", role: "assistant", content: "缩略历史", createdAt: Date(timeIntervalSince1970: 20))
                ],
                loadMode: .economy,
                notice: "当前显示缩略历史。"
            )
        )
        await selectTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["缩略历史"])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryLoaded)
    }

    private func makeStore(
        client: OrderedHistoryPageClient,
        conversationStore: ConversationStore? = nil
    ) -> SessionStore {
        SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore ?? ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
    }

    private func gatewayRejection(_ message: String, data: [String: CodexAppServerJSONValue]? = nil) -> Error {
        CodexAppServerConnectionError.appServer(CodexAppServerError(
            code: -32080,
            message: message,
            data: data.map { .object($0) }
        ))
    }
}
