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
        // 404 是内容不存在（过期、删除、thread 已不在），不是电脑端版本过旧。
        assertFriendly(UserFacingError(AgentAPIError.server(status: 404, message: "not found")), .notFound)
        assertFriendly(UserFacingError(AgentAPIError.server(status: 405, message: "method not allowed")), .unsupported)
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

        // 字符串出口拿到的是随系统语言变化的 Foundation 兜底句，同样不能原样展示。
        let raw = UserFacingError(rawMessage: MockError.timeout.localizedDescription)
        XCTAssertEqual(raw.category, .unknown)
        XCTAssertEqual(raw.message, L10n.text("ui.error_unknown"))
    }

    func testHistoryMediaAndOutput404MeanExpiredCacheNotOldVersion() {
        let gone = AgentAPIError.server(status: 404, message: "history media expired")
        XCTAssertEqual(
            UserFacingError(gone, context: .historyMedia).message,
            L10n.text("ui.the_historical_image_cache_has_expired_please_refresh")
        )
        XCTAssertEqual(
            UserFacingError(gone, context: .historyOutput).message,
            L10n.text("ui.the_historical_output_cache_has_expired_please_refresh")
        )
        let general = UserFacingError(gone)
        XCTAssertEqual(general.category, .notFound)
        XCTAssertEqual(general.message, L10n.text("ui.error_not_found"))
        XCTAssertNotEqual(general.message, L10n.text("ui.error_unsupported"))
        XCTAssertFalse(general.suggestsReconnect)
    }

    /// 在指定界面语言下执行，结束后恢复原设置。
    private func withInterfaceLanguage(_ language: AppLanguage, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: AppLanguage.preferenceKey)
        defaults.set(language.rawValue, forKey: AppLanguage.preferenceKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppLanguage.preferenceKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.preferenceKey)
            }
        }
        body()
    }

    func testWhitelistedComputerReasonIsShownInsteadOfHiddenInDetails() {
        withInterfaceLanguage(.simplifiedChinese) { assertWhitelistedReasons() }
    }

    func testTimestampsInReadableReasonsAreNotMistakenForAddresses() {
        withInterfaceLanguage(.english) {
            let english = UserFacingError(AgentAPIError.server(status: 500, message: "Not logged in since 12:30:45"))
            XCTAssertEqual(english.message, "Not logged in since 12:30:45")
        }
        withInterfaceLanguage(.simplifiedChinese) {
            let chinese = UserFacingError(AgentAPIError.server(status: 500, message: "请于 09:30 前重新登录"))
            XCTAssertEqual(chinese.message, "请于 09:30 前重新登录")
        }
        // 真正的地址仍然拦下。
        XCTAssertTrue(UserFacingError.containsSensitiveDetail("connect to fe80::1"))
        XCTAssertTrue(UserFacingError.containsSensitiveDetail("connect to 2001:db8:85a3:0:0:8a2e:370:7334"))
        XCTAssertTrue(UserFacingError.containsSensitiveDetail("open localhost:4180"))
        XCTAssertFalse(UserFacingError.containsSensitiveDetail("since 12:30:45"))
        XCTAssertFalse(UserFacingError.containsSensitiveDetail("before 09:30"))
    }

    func testChineseComputerReasonFallsBackOnEnglishInterface() {
        withInterfaceLanguage(.english) {
            let chinese = UserFacingError(AgentAPIError.server(status: 500, message: "Codex 登录态已失效，请先运行 codex login"))
            XCTAssertEqual(chinese.category, .hostError, "未本地化的中文原因不上英文界面")
            XCTAssertNotNil(chinese.technicalDetail)
            let english = UserFacingError(AgentAPIError.server(status: 500, message: "Not logged in. Run codex login first."))
            XCTAssertEqual(english.message, "Not logged in. Run codex login first.")
        }
    }

    func testReadableReasonNeedsWholeWordsAndNoSensitiveDetail() {
        withInterfaceLanguage(.english) {
            // 子串误中：catalog in / design in / assign in 都不是登录说明。
            for message in [
                "catalog index failed in catalog in workspace",
                "design in progress",
                "could not assign in the current state"
            ] {
                XCTAssertEqual(UserFacingError(AgentAPIError.server(status: 500, message: message)).category, .hostError, message)
            }
            // 命中白名单但带地址、路径、IP、主机名或疑似凭据：退回分类文案，原文只留在详情。
            for message in [
                "Please log in at https://example.invalid/login",
                "Run codex login; missing /Users/demo/.codex/auth.json",
                "Run codex login on 192.0.2.10",
                "Run codex login on build-mac.example.com",
                "codex login failed for token abcdefghijklmnopqrstuvwx1234",
                // 第七轮复审的反例：全角冒号 / 等号后的路径、其他根目录、带端口或少见后缀的主机名、短凭据赋值。
                "请先登录：/Users/demo/.codex/auth.json",
                "Run codex login, config=/srv/codex/config.toml",
                "codex login required under /root/.codex",
                "codex login: check /mnt/data first",
                "Run codex login; see /Library/Application Support/Codex",
                "Run codex login on build-mac:8080",
                "Run codex login on studio.home",
                "Run codex login via relay.ai",
                "codex login failed, key=abc123",
                "codex login failed: token=short1",
                "codex login failed for demo@example.invalid",
                // 最终复审的反例：无分隔符或全角写法的短凭据、无后缀主机名、账号、反斜杠路径。
                "codex login failed with key abc123",
                "codex login failed, API key abcd1234",
                "codex login: Authorization: Basic dXNlcjpwYXNz",
                "codex login failed, pass: hunter2",
                "Please log in again, key：abc123",
                "Please log in again, key＝abc123",
                "Please sign in again: Permission to owner/repo denied to someuser.",
                "Run codex login on build-mac",
                "Run codex login on gais-mac-mini",
                "Run codex login on [::1]:8080",
                "codex login failed for @someuser",
                "codex login failed: \\Users\\demo\\auth"
            ] {
                let presented = UserFacingError(AgentAPIError.server(status: 500, message: message))
                XCTAssertEqual(presented.category, .hostError, message)
                XCTAssertFalse(presented.message.contains("codex login"), message)
                XCTAssertTrue(presented.technicalDetail?.contains(message) == true, message)
            }
        }
    }

    private func assertWhitelistedReasons() {
        // 中文界面下，带路径的中文原因同样不能上主界面（全角冒号后紧跟路径）。
        for message in [
            "请先登录：/Users/demo/.codex/auth.json",
            "请先登录，配置在 /root/.codex",
            "登录凭据 key=abc123 已失效",
            "请先登录，密码 hunter2",
            "请先登录，凭据：abc123",
            "请先登录，配对码 482913",
            "请在 mac-mini 上重新登录",
            "Run codex login (~/文档/codex)"
        ] {
            let presented = UserFacingError(AgentAPIError.server(status: 500, message: message))
            XCTAssertEqual(presented.category, .hostError, message)
            XCTAssertTrue(presented.technicalDetail?.contains(message) == true, message)
        }
        let codexLogin = "Codex 登录态已失效，请先在电脑上运行 codex login 后重试"
        let http = UserFacingError(AgentAPIError.server(status: 500, message: codexLogin))
        XCTAssertEqual(http.category, .described)
        XCTAssertEqual(http.message, codexLogin)
        XCTAssertNotNil(http.technicalDetail)
        XCTAssertFalse(http.suggestsReconnect, "登录态问题重连解决不了")

        let rpc = CodexAppServerError(code: -32603, message: "Not logged in. Run codex login first.", data: nil)
        XCTAssertEqual(
            UserFacingError(CodexAppServerConnectionError.appServer(rpc)).message,
            "Not logged in. Run codex login first."
        )

        // 不在白名单里的原因、带协议细节的原因、访问码失效，都不能顶替分类文案。
        XCTAssertEqual(UserFacingError(AgentAPIError.server(status: 500, message: "internal error")).category, .hostError)
        XCTAssertEqual(
            UserFacingError(AgentAPIError.server(status: 500, message: "login failed: HTTP 502 from upstream")).category,
            .hostError
        )
        XCTAssertEqual(
            UserFacingError(AgentAPIError.server(status: 401, message: "please log in")).category,
            .authenticationExpired
        )
    }

    func testCarrierErrorsKeepTheirRecoverability() {
        let rejected = UserFacingError(HarnessTransportError.carrier(
            HarnessRemoteError(code: "gateway/arguments-invalid", message: nil, details: nil)
        ))
        XCTAssertEqual(rejected.category, .rejected)
        XCTAssertFalse(rejected.suggestsReconnect, "确定性拒绝不能给只会重复失败的重连入口")

        let recoverable = UserFacingError(HarnessTransportError.carrier(
            HarnessRemoteError(code: "gateway/service-unavailable", message: nil, details: nil)
        ))
        XCTAssertEqual(recoverable.category, .hostError)
        XCTAssertTrue(recoverable.suggestsReconnect)
    }

    // MARK: - 只有字符串的出口

    func testPolicyRejectionIsAStoppedStateInEveryLanguage() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            let raw = String(
                format: L10n.text("ui.the_connection_was_rejected_by_server_policy_and", language: language),
                "app-server error -32080: gateway rejected thread/resume"
            )
            let presented = UserFacingError(rawMessage: raw)
            XCTAssertEqual(presented.category, .policyRejected, "\(language): \(presented.message)")
            XCTAssertFalse(presented.isInProgress, "已停止自动重连，不能显示成进度")
            XCTAssertFalse(presented.suggestsReconnect, "重新连接只会再次被策略拒绝")
            XCTAssertEqual(presented.technicalDetail, raw)
        }
    }

    func testPolicyWordAloneIsNotAConnectionPolicyRejection() {
        for raw in [
            "审批失败：JSON-RPC -32602 invalid sandbox policy",
            "Approval failed: JSON-RPC -32602 invalid sandbox policy",
            "app-server error -32603: approval policy unavailable",
            "审批失败：app-server 错误 -32602：沙箱策略无效"
        ] {
            let presented = UserFacingError(rawMessage: raw)
            XCTAssertNotEqual(presented.category, .policyRejected, raw)
            XCTAssertNotEqual(presented.message, L10n.text("ui.error_connection_policy_rejected"), raw)
        }
        XCTAssertEqual(
            UserFacingError(rawMessage: "审批失败：JSON-RPC -32602 invalid sandbox policy").category,
            .rejected
        )
    }

    func testStoppedReconnectIsNotPresentedAsInProgress() {
        let presented = UserFacingError(rawMessage: "WebSocket closed; automatic reconnect stopped after 5 attempts")
        XCTAssertNotEqual(presented.category, .reconnecting)
    }

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

    func testConnectionResetDropsFailureFeedbackSoRetryCannotReachAnotherComputer() async {
        let session = makeCodexSession()
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: [session]))
        _ = await store.compactSessionContext(session)
        XCTAssertNotNil(store.operationFeedback?.retry, "前置条件：失败提示带着捕获旧会话的重试")

        store.resetConnectionForSettingsChange()

        XCTAssertNil(store.operationFeedback, "换连接后旧主机的失败提示与重试不能留下")
        XCTAssertNil(store.statusMessage)
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
