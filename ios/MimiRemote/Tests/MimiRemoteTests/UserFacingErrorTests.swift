import XCTest
@testable import MimiRemote

/// #508：操作失败要「看得见、能看懂、可重试」。
///
/// 这里覆盖两层：错误到用户文案的映射（主界面不再出现 HTTP / JSON-RPC / WebSocket 原文，
/// 原文保留在技术详情里），以及失败后 SessionStore 的状态复原与可见反馈。
final class UserFacingErrorTests: XCTestCase {
    private let protocolTerms = ["HTTP", "JSON-RPC", "WebSocket", "app-server", "DecodingError", "-32601", "500"]

    private func assertFriendly(
        _ presented: UserFacingError,
        _ category: UserFacingErrorCategory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(presented.category, category, file: file, line: line)
        for term in protocolTerms {
            XCTAssertFalse(
                presented.message.contains(term),
                "用户文案不应包含 \(term)：\(presented.message)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - 结构化错误

    func testURLErrorsMapToNetworkCategoriesAndKeepTheRawDescription() {
        let offline = UserFacingError(URLError(.notConnectedToInternet))
        assertFriendly(offline, .offline)
        XCTAssertEqual(offline.message, L10n.text("ui.error_offline"))
        XCTAssertNotNil(offline.technicalDetail)

        assertFriendly(UserFacingError(URLError(.cannotConnectToHost)), .hostUnreachable)
        assertFriendly(UserFacingError(URLError(.timedOut)), .timedOut)
        assertFriendly(UserFacingError(URLError(.networkConnectionLost)), .connectionLost)
        XCTAssertTrue(UserFacingError(URLError(.timedOut)).suggestsReconnect)
        XCTAssertFalse(offline.suggestsReconnect, "离线由网络横幅负责，不在错误横幅上重复给重连入口")
    }

    func testHTTPStatusIsTranslatedAndOnlyKeptInDetails() {
        let serverError = UserFacingError(AgentAPIError.server(status: 500, message: "internal error"))
        assertFriendly(serverError, .hostError)
        XCTAssertEqual(serverError.message, L10n.text("ui.error_host_error"))
        XCTAssertTrue(serverError.technicalDetail?.contains("500") == true)
        XCTAssertTrue(serverError.technicalDetail?.contains("internal error") == true)

        assertFriendly(UserFacingError(AgentAPIError.server(status: 401, message: "nope")), .authenticationExpired)
        // agentd 自身的目录审批也会返回 403；它不是访问码失效，只是权限被拒。
        assertFriendly(
            UserFacingError(AgentAPIError.server(status: 403, message: "path outside allowlist")),
            .permissionDenied
        )
        assertFriendly(UserFacingError(AgentAPIError.server(status: 404, message: "not found")), .unsupported)
        assertFriendly(UserFacingError(AgentAPIError.server(status: 429, message: "slow down")), .rateLimited)
        assertFriendly(UserFacingError(AgentAPIError.server(status: 409, message: "conflict")), .rejected)
    }

    func testDecodingFailuresBecomeInvalidResponseCopy() {
        let decodingError = DecodingError.keyNotFound(
            AnyCodingKey("thread"),
            DecodingError.Context(codingPath: [], debugDescription: "missing thread")
        )
        let presented = UserFacingError(AgentAPIError.decoding(decodingError))
        assertFriendly(presented, .invalidResponse)
        XCTAssertEqual(presented.message, L10n.text("ui.error_invalid_response"))
        XCTAssertNotNil(presented.technicalDetail)
        assertFriendly(UserFacingError(decodingError), .invalidResponse)
    }

    func testAppServerConnectionErrorsMapByMeaningNotByProtocol() {
        assertFriendly(UserFacingError(CodexAppServerConnectionError.disconnected), .connectionLost)
        assertFriendly(UserFacingError(CodexAppServerConnectionError.notInitialized), .connectionLost)
        assertFriendly(
            UserFacingError(CodexAppServerConnectionError.timeout(method: "thread/resume", id: .int(7))),
            .timedOut
        )
        assertFriendly(
            UserFacingError(CodexAppServerConnectionError.outcomeUnknown(method: "turn/start", id: .int(8), cause: "eof")),
            .outcomeUnknown
        )
        let methodNotFound = CodexAppServerError(code: -32601, message: "Method not found", data: nil)
        assertFriendly(UserFacingError(CodexAppServerConnectionError.appServer(methodNotFound)), .unsupported)
        assertFriendly(
            UserFacingError(CodexAppServerConnectionError.transport(URLError(.notConnectedToInternet))),
            .offline
        )
    }

    func testAlreadyReadableErrorsKeepTheirOwnMessage() {
        let upstream = CodexAppServerError(
            code: -32000,
            message: "upstream down",
            data: .object(["reason": .string("codex_upstream_unavailable")])
        )
        let upstreamPresented = UserFacingError(CodexAppServerConnectionError.appServer(upstream))
        XCTAssertEqual(upstreamPresented.category, .described)
        XCTAssertEqual(upstreamPresented.message, L10n.text("ui.codex_upstream_unavailable"))

        let endpoint = UserFacingError(AgentAPIError.invalidEndpoint)
        XCTAssertEqual(endpoint.category, .described)
        XCTAssertEqual(endpoint.message, AgentAPIError.invalidEndpoint.localizedDescription)
        XCTAssertNil(endpoint.technicalDetail, "可读说明不需要再展开一份相同的详情")
    }

    func testNonLocalizedSwiftErrorsFallBackToGenericCopyWithTypeInDetails() {
        let presented = UserFacingError(MockError.timeout)
        XCTAssertEqual(presented.category, .unknown)
        XCTAssertEqual(presented.message, L10n.text("ui.error_unknown"))
        XCTAssertTrue(presented.technicalDetail?.contains("MockError") == true)
    }

    // MARK: - 只有字符串的出口

    func testRawProtocolMessageKeepsActionPrefixAndMovesDetailsAside() {
        let raw = L10n.text("ui.approval_failed_websocket_not_connected")
        let presented = UserFacingError(rawMessage: raw)
        assertFriendly(presented, .connectionLost)
        XCTAssertTrue(
            presented.message.hasSuffix(L10n.text("ui.error_connection_lost")),
            "应保留「审批失败」前缀并换上可读的原因：\(presented.message)"
        )
        XCTAssertFalse(presented.message.hasPrefix(L10n.text("ui.error_connection_lost")))
        XCTAssertEqual(presented.technicalDetail, raw)
    }

    func testAutomaticReconnectIsPresentedAsProgressNotError() {
        let raw = L10n.format("ui.websocket_disconnected_and_reconnecting_automatically_value", "EOF")
        let presented = UserFacingError(rawMessage: raw)
        assertFriendly(presented, .reconnecting)
        XCTAssertTrue(presented.isInProgress)
        XCTAssertEqual(presented.message, L10n.text("ui.error_reconnecting"))
    }

    func testReadableMessagesPassThroughUnchanged() {
        let raw = L10n.text("ui.please_select_the_project_first")
        let presented = UserFacingError(rawMessage: raw)
        XCTAssertEqual(presented, .described(raw))
        XCTAssertNil(presented.technicalDetail)
    }

    func testRawHTTPAndJSONRPCStringsAreClassified() {
        assertFriendly(UserFacingError(rawMessage: "HTTP 503: upstream unavailable"), .hostError)
        assertFriendly(UserFacingError(rawMessage: "app-server error -32601: Method not found"), .unsupported)
        assertFriendly(
            UserFacingError(rawMessage: "DecodingError.keyNotFound(thread)"),
            .invalidResponse
        )
    }

    func testRuntimeFailureKeepsReadableReasonButHidesTransportNoise() {
        XCTAssertEqual(
            UserFacingError(runtimeFailureMessage: "Context window exceeded. Start a new session."),
            .described("Context window exceeded. Start a new session.")
        )
        let noisy = "unexpected status 502 Bad Gateway: error sending request for url (https://example.invalid/v1/responses)"
        let presented = UserFacingError(runtimeFailureMessage: noisy)
        XCTAssertEqual(presented.message, L10n.text("ui.error_run_failed"))
        XCTAssertEqual(presented.technicalDetail, noisy)
    }
}

/// `DecodingError` 需要一个 CodingKey 实例来构造。
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) {
        stringValue = value
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

@MainActor
final class OperationFeedbackStoreTests: XCTestCase {
    private func makeStore(client: MockSessionStoreClient) -> SessionStore {
        SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
    }

    private func makeCodexSession(title: String = "修复 Git 状态") -> AgentSession {
        makeSession(
            id: "thread_rename",
            projectID: "proj_feedback",
            title: title,
            status: "history",
            source: "codex",
            resumeID: "thread_rename"
        )
    }

    func testRenameFailureIsVisibleTranslatedAndLeavesTheTitleUntouched() async {
        let session = makeCodexSession()
        let client = MockSessionStoreClient(projects: [], sessions: [session])
        client.setThreadNameError = AgentAPIError.server(status: 500, message: "internal error")
        let store = makeStore(client: client)
        store.upsert(session)

        let failure = await store.renameSessionReportingFailure(session, name: "新的名字")

        let expected = L10n.format("ui.rename_failed_value", L10n.text("ui.error_host_error"))
        XCTAssertEqual(failure?.kind, .failure)
        XCTAssertEqual(failure?.message, expected)
        XCTAssertTrue(failure?.technicalDetail?.contains("500") == true, "原始 HTTP 状态只进详情")
        XCTAssertEqual(store.statusMessage, expected)
        XCTAssertEqual(store.operationFeedback?.id, failure?.id, "失败必须有可见反馈，不能静默")
        XCTAssertEqual(store.sessionsByID[session.id]?.title, "修复 Git 状态", "失败后标题保持原样")
        XCTAssertEqual(client.requestedThreadNames, [RequestedThreadName(threadID: session.id, name: "新的名字")])

        // 弹窗就地展示后收起浮层；再次保存（重试）成功时得到普通反馈。
        store.dismissOperationFeedback(id: failure?.id)
        XCTAssertNil(store.operationFeedback)
        client.setThreadNameError = nil
        let retried = await store.renameSessionReportingFailure(session, name: "新的名字")
        XCTAssertNil(retried)
        XCTAssertEqual(store.statusMessage, L10n.format("ui.session_renamed_to_value", "新的名字"))
        XCTAssertEqual(store.operationFeedback?.kind, .info)
    }

    func testRenameValidationFailureIsReportedInsteadOfSilentlyIgnored() async {
        let session = makeCodexSession()
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: [session]))
        let tooLong = String(repeating: "名", count: 100)

        let failure = await store.renameSessionReportingFailure(session, name: tooLong)

        XCTAssertEqual(failure?.message, L10n.text("ui.session_name_cannot_exceed_256_bytes"))
        XCTAssertNil(failure?.technicalDetail)
        XCTAssertEqual(store.operationFeedback?.kind, .failure)
    }

    func testCompactionFailureOffersRetryThatRunsTheOperationAgain() async {
        let session = makeCodexSession()
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: [session]))

        let didCompact = await store.compactSessionContext(session)

        XCTAssertFalse(didCompact)
        let failure = try? XCTUnwrap(store.operationFeedback)
        XCTAssertEqual(failure?.kind, .failure)
        XCTAssertEqual(
            failure?.message,
            L10n.format("ui.context_compression_failed_value", L10n.text("ui.error_invalid_response"))
        )
        XCTAssertNotNil(failure?.retry, "压缩失败应直接提供重试")

        if let failure {
            await store.retryOperationFeedback(failure)
        }
        XCTAssertEqual(store.operationFeedback?.kind, .failure, "重试仍失败时继续给出反馈")
        XCTAssertNotEqual(store.operationFeedback?.id, failure?.id, "重试是一次新的尝试")
    }

    func testStatusMessagesBecomeToastsUnlessMarkedSilent() {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))

        store.setStatusMessage(L10n.plural("ui.sessions_loaded_count", count: 3), presentation: .silent)
        XCTAssertEqual(store.statusMessage, L10n.plural("ui.sessions_loaded_count", count: 3))
        XCTAssertNil(store.operationFeedback, "后台计数刷新不弹提示")

        store.setStatusMessage(L10n.text("ui.goal_updated"))
        XCTAssertEqual(store.operationFeedback?.kind, .info)
        XCTAssertEqual(store.operationFeedback?.message, L10n.text("ui.goal_updated"))
        let firstID = store.operationFeedback?.id
        store.setStatusMessage(L10n.text("ui.goal_updated"))
        XCTAssertEqual(store.operationFeedback?.id, firstID, "同一条提示仍在显示时不重复弹出")

        store.setStatusMessage(nil)
        XCTAssertNil(store.operationFeedback, "进行中的提示随状态清空一起收起")

        store.reportOperationFailure(.described(L10n.text("ui.read_only")))
        store.setStatusMessage(nil)
        XCTAssertEqual(store.operationFeedback?.kind, .failure, "失败提示不能被后续清空静默吞掉")
    }

    func testStatusMessageWithRawProtocolErrorIsTranslatedForDisplay() {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))
        let raw = L10n.format("ui.failed_to_connect_to_queue_to_be_sent", "app-server WebSocket 未连接")

        store.setStatusMessage(raw)

        XCTAssertEqual(store.statusMessage, raw)
        XCTAssertFalse(store.operationFeedback?.message.contains("WebSocket") ?? true)
        XCTAssertEqual(store.operationFeedback?.technicalDetail, raw)
    }

    func testErrorChannelKeepsRawDescriptionForLogicButPresentsFriendlyCopy() {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))
        let error = AgentAPIError.server(status: 502, message: "bad gateway")

        store.setErrorMessage(for: error)

        XCTAssertEqual(store.errorMessage, error.localizedDescription, "原始描述继续供冲突识别、额度判断使用")
        XCTAssertEqual(store.errorPresentation?.category, .hostError)
        XCTAssertEqual(store.errorPresentation?.message, L10n.text("ui.error_host_error"))
        XCTAssertTrue(store.errorPresentation?.suggestsReconnect == true)
        XCTAssertEqual(store.userFacingErrorMessage, L10n.text("ui.error_host_error"))

        store.dismissErrorMessage()
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.errorPresentation)
    }

    func testStringErrorWritesGetTheSameTranslation() {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))
        let raw = L10n.text("ui.approval_sending_failed_websocket_not_connected")

        store.setErrorMessage(raw)

        XCTAssertEqual(store.errorMessage, raw)
        XCTAssertEqual(store.errorPresentation?.category, .connectionLost)
        XCTAssertFalse(store.errorPresentation?.message.contains("WebSocket") ?? true)
    }

    func testConversationModelHidesTranslatedErrorWhenQuotaBannerOwnsIt() {
        let quotaError = "You've hit your usage limit. Try again later."
        let notice = CodexQuotaNotice.make(rateLimit: nil, errorMessage: quotaError)
        XCTAssertNotNil(notice)
        let model = ConversationScreenModel(
            selectedSession: nil,
            selectedProject: nil,
            foregroundActivity: nil,
            runtimeActivitySnapshot: nil,
            historySavingsNotice: nil,
            quotaNotice: notice,
            webSocketStatus: .disconnected,
            errorMessage: quotaError,
            errorPresentation: UserFacingError(runtimeFailureMessage: quotaError)
        )
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.errorPresentation)
    }
}
