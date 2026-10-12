import XCTest
@testable import MimiRemote

/// #585：Codex Desktop 对 `request_user_input_async` 的答复以普通 userMessage 回传。
/// 实时事件、历史全量读取和摘要加分页补齐都必须映射为同一种答复类型，
/// 不展示协议标签、JSON 或调用标识，并保持服务端 Item 顺序。
@MainActor
final class ConversationQuestionReplyTests: XCTestCase {
    private typealias Fixture = QuestionReplyFixture

    // MARK: - 解析

    func testReplyEnvelopeParsesIntoStructuredAnswers() throws {
        let reply = try XCTUnwrap(CodexAsyncQuestionReply(text: Fixture.replyEnvelope(answer: Fixture.answer)))
        XCTAssertEqual(reply.answers, [
            CodexAsyncQuestionReply.Answer(
                questionItemID: Fixture.questionItemID,
                questionIndex: 0,
                question: Fixture.questionTitle,
                answer: Fixture.answer
            )
        ])
        XCTAssertEqual(reply.displayText, Fixture.answer)

        // 多问题、多选答案逐行保留；空答案使用本地化占位，不能回退成原始载荷。
        let multiple = try XCTUnwrap(CodexAsyncQuestionReply(text: Fixture.envelope([
            ["questionItemId": Fixture.questionReference(index: 0), "question": "范围", "answer": ["iPad", "iPhone"]],
            ["questionItemId": Fixture.questionReference(index: 1), "question": "备注", "answer": "  "],
        ])))
        XCTAssertEqual(multiple.answers.map(\.questionItemID), [Fixture.questionItemID, Fixture.questionItemID])
        XCTAssertEqual(multiple.answers.map(\.questionIndex), [0, 1])
        XCTAssertEqual(multiple.displayText, "iPad\niPhone\n" + L10n.text("ui.question_reply_no_answer"))
    }

    func testReplyEnvelopeRejectsIncompleteOrMixedText() {
        let valid = Fixture.replyEnvelope(answer: Fixture.answer)
        let rejected = [
            "",
            CodexAsyncQuestionReply.openingTag + CodexAsyncQuestionReply.closingTag,
            String(valid.dropLast()),
            "补充说明\n" + valid,
            valid + "\n还有一句",
            "讨论 \(CodexAsyncQuestionReply.openingTag) 标签的含义",
            Fixture.wrapped("not json"),
            Fixture.wrapped("[]"),
            Fixture.wrapped(#"{"answer":"对象不是数组"}"#),
            Fixture.wrapped(#"[{"question":"缺少答案"}]"#),
            Fixture.wrapped(#"[{"answer":42}]"#),
        ]
        for text in rejected {
            XCTAssertNil(CodexAsyncQuestionReply(text: text), text)
            // 未识别的文本继续按普通用户消息展示，不能被静默吞掉。
            if !text.isEmpty {
                XCTAssertTrue(isVisibleAppServerUserMessageText(text), text)
            }
        }

        // 关联标识不是异步提问结构时只放弃关联，答案仍按结构化答复展示。
        let opaque = CodexAsyncQuestionReply(text: Fixture.envelope([["questionItemId": "opaque", "answer": "好"]]))
        XCTAssertNil(opaque?.answers.first?.questionItemID)
        XCTAssertEqual(opaque?.displayText, "好")
    }

    // MARK: - 投影

    func testLiveAndHistoryProjectionShareReplyTypeAndIdentity() async throws {
        var projector = CodexAppServerEventProjector()
        let started = try projectedMessage(projector.project(Fixture.notification("item/started", item: Fixture.replyItem)))
        let completed = try projectedMessage(projector.project(Fixture.notification("item/completed", item: Fixture.replyItem)))
        let followUp = try projectedMessage(projector.project(Fixture.notification("item/completed", item: Fixture.followUpItem)))
        let history = try await Fixture.fullHistory()
        let historyReply = try XCTUnwrap(history.first { $0.itemID == "user_reply" })

        for message in [started, completed] {
            XCTAssertEqual(message.role, .user)
            XCTAssertEqual(message.kind, .questionReply)
            XCTAssertEqual(message.content, Fixture.answer)
            XCTAssertEqual(message.clientMessageID, "client_reply")
            XCTAssertEqual(message.id, historyReply.id)
        }
        XCTAssertEqual(historyReply.role, "user")
        XCTAssertEqual(historyReply.kind, .questionReply)
        XCTAssertEqual(historyReply.content, Fixture.answer)
        XCTAssertEqual(historyReply.clientMessageID, "client_reply")
        XCTAssertNil(historyReply.userDelivery)
        XCTAssertNil(historyReply.turnPayload)

        // 答复记录了提问 Item 的身份，可与时间线中的提问稳定关联。
        let question = try XCTUnwrap(history.first { $0.itemID == Fixture.questionItemID })
        let reference = CodexAsyncQuestionReply(text: Fixture.replyEnvelope(answer: Fixture.answer))?.answers.first
        XCTAssertEqual(reference?.questionItemID, question.itemID)
        XCTAssertLessThan(try XCTUnwrap(question.timelineOrdinal), try XCTUnwrap(historyReply.timelineOrdinal))

        // 紧随其后的普通引导仍是独立请求，不与答复合并或互换。
        XCTAssertEqual(followUp.kind, .message)
        let historyFollowUp = try XCTUnwrap(history.first { $0.itemID == "user_follow_up" })
        XCTAssertEqual(historyFollowUp.kind, .message)
        XCTAssertEqual(historyFollowUp.userDelivery, .injected)
        XCTAssertLessThan(try XCTUnwrap(historyReply.timelineOrdinal), try XCTUnwrap(historyFollowUp.timelineOrdinal))
        assertNoProtocolLeak(history.map(\.content) + [started.content, completed.content])
    }

    // MARK: - 时间线顺序

    func testLiveHistoryAndPagedReloadProduceSameTimeline() async throws {
        let expected = [
            "user/message/更新商店素材，然后准备送审。",
            "process",
            "assistant/message/\(Fixture.questionText)",
            "process",
            "user/question_reply/\(Fixture.answer)",
            "user/message/可以先更新宣传图",
            "assistant/message/好的，先更新宣传图，并等待构建 101。",
        ]

        // 实时：事件按服务端顺序到达，时间来自接收时刻，可能落在同一秒。
        let live = try await liveConversationStore()
        XCTAssertEqual(timelineSignature(live.messages(for: Fixture.threadID)), expected)

        // 实时之后重新读取历史：权威快照与已显示消息合并，类型和顺序不变，答复只出现一次。
        live.replaceHistorySnapshot(try await Fixture.fullHistory(), sessionID: Fixture.threadID)
        XCTAssertEqual(timelineSignature(live.messages(for: Fixture.threadID)), expected)

        // 重新进入会话：只有历史全量读取。
        let reopened = ConversationStore()
        reopened.replaceHistorySnapshot(try await Fixture.fullHistory(), sessionID: Fixture.threadID)
        XCTAssertEqual(timelineSignature(reopened.messages(for: Fixture.threadID)), expected)

        // 历史分页：先展示摘要，再按两页补齐完整 Item。
        let paged = ConversationStore()
        paged.replaceHistorySnapshot(try await summaryHistory(), sessionID: Fixture.threadID)
        for page in try await hydratedItemPages(splitAt: 4) {
            paged.setHistory(page, sessionID: Fixture.threadID, timelineMutationKind: .enrichment)
        }
        XCTAssertEqual(timelineSignature(paged.messages(for: Fixture.threadID)), expected)
        assertNoProtocolLeak(paged.messages(for: Fixture.threadID).map(\.content))
    }

    func testSameSecondItemsAndLongHistoryKeepServerItemOrder() async throws {
        // Turn 只给完成时间时，所有 Item 的估算时间相同；顺序只能来自 Item 序号。
        let priorTurns = (0..<24).map { index in
            Fixture.turn(
                id: "turn_prior_\(index)",
                startedAt: 1_780_000_000 + index * 60,
                completedAt: 1_780_000_030 + index * 60,
                items: [
                    Fixture.userItem(id: "user_prior_\(index)", clientID: "client_prior_\(index)", text: "历史请求 \(index)"),
                    Fixture.agentItem(id: "agent_prior_\(index)", text: "历史答复 \(index)"),
                ]
            )
        }
        let sameSecondTurn = Fixture.turn(
            id: Fixture.turnID,
            startedAt: nil,
            completedAt: 1_780_100_000,
            items: Fixture.turnItems
        )
        let history = try await Fixture.projectedHistory(turns: priorTurns + [sameSecondTurn])
        let replyTurn = history.filter { $0.turnID == Fixture.turnID }
        XCTAssertEqual(Set(replyTurn.compactMap(\.createdAt)).count, 1, "同一完成时间下验证顺序不依赖时间")

        let store = ConversationStore()
        store.replaceHistorySnapshot(history, sessionID: Fixture.threadID)
        let messages = store.messages(for: Fixture.threadID)
        XCTAssertEqual(messages.count { $0.kind == .questionReply }, 1)
        XCTAssertEqual(
            Array(timelineSignature(messages.filter { $0.turnID == Fixture.turnID }).suffix(3)),
            [
                "user/question_reply/\(Fixture.answer)",
                "user/message/可以先更新宣传图",
                "assistant/message/好的，先更新宣传图，并等待构建 101。",
            ]
        )
        XCTAssertEqual(messages.first?.content, "历史请求 0")
        assertNoProtocolLeak(messages.map(\.content))
    }

    // MARK: - 辅助

    private func projectedMessage(_ event: AgentEvent?) throws -> AgentMessage {
        guard case .messageCompleted(let message, _) = try XCTUnwrap(event) else {
            throw NSError(domain: "ConversationQuestionReplyTests", code: 1)
        }
        return message
    }

    /// 摘要只带用户与 Agent 文案，数组下标不是完整 rollout 中的位置。
    private func summaryHistory() async throws -> [CodexHistoryMessage] {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let summaryItems = Fixture.turnItems.filter { ($0["type"] as? String) != "commandExecution" }
        var summaryTurn = Fixture.turn(
            id: Fixture.turnID,
            startedAt: Fixture.startedAt,
            completedAt: Fixture.completedAt,
            items: summaryItems
        )
        summaryTurn["itemsView"] = "summary"
        let turnValue = try XCTUnwrap(Fixture.jsonValue(summaryTurn).objectValue)
        return await runtime.historyMessages(
            fromTurns: [turnValue],
            sessionID: Fixture.threadID,
            timelineOrdinalsAreCanonical: false,
            snapshotReadAt: Fixture.snapshotReadAt
        )
    }

    private func hydratedItemPages(splitAt split: Int) async throws -> [[CodexHistoryMessage]] {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let shell = try XCTUnwrap(Fixture.jsonValue(Fixture.turn(
            id: Fixture.turnID,
            startedAt: Fixture.startedAt,
            completedAt: Fixture.completedAt,
            items: []
        )).objectValue)
        let items = try Fixture.turnItems.map { try XCTUnwrap(Fixture.jsonValue($0).objectValue) }
        var pages: [[CodexHistoryMessage]] = []
        var hasVisibleUserMessageBefore = false
        for (offset, slice) in [(0, items[..<split]), (split, items[split...])] {
            let continuation = HistoryTurnItemsContinuation(
                turnID: Fixture.turnID,
                turn: shell,
                turnIndex: 0,
                itemOffset: offset,
                cursor: nil,
                pageLimit: split,
                threadIsActive: false,
                isLatestTurn: true,
                hasVisibleUserMessageBefore: hasVisibleUserMessageBefore
            )
            let page = await runtime.historyMessages(
                fromItems: Array(slice),
                continuation: continuation,
                sessionID: Fixture.threadID,
                snapshotReadAt: Fixture.snapshotReadAt
            )
            hasVisibleUserMessageBefore = hasVisibleUserMessageBefore || page.contains { $0.role == "user" }
            pages.append(page)
        }
        return pages
    }

    private func liveConversationStore() async throws -> ConversationStore {
        let project = makeProject(id: "proj_question_reply")
        let running = makeSession(
            id: Fixture.threadID,
            projectID: project.id,
            title: "Question Reply",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: Fixture.turnID
        )
        let appStore = makeIsolatedAppStore()
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running]) }
        )
        store.sessions = [running]
        store.turnCompletionReconciliationDelaysNanoseconds = []
        let lease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: Fixture.threadID)
        var projector = CodexAppServerEventProjector()
        for item in Fixture.turnItems {
            for method in ["item/started", "item/completed"] {
                if let event = projector.project(try Fixture.notification(method, item: item)) {
                    await store.applyRuntimeEvent(event, lease: lease, sendsNotification: false)
                }
            }
        }
        return conversationStore
    }

    /// 用户消息按展示正文比较，过程组只比较位置，避免把展开状态和标题文案混进顺序断言。
    private func timelineSignature(_ messages: [ConversationMessage]) -> [String] {
        ConversationTimelineItemBuilder.items(from: messages).compactMap { item in
            switch item {
            case .message(let message):
                let content = message.role == .user
                    ? ConversationUserMessagePresentation.displayContent(from: message.content)
                    : message.content
                return "\(message.role.rawValue)/\(message.kind.rawValue)/\(content)"
            case .processGroup:
                return "process"
            case .activity, .processMessage, .fileChanges:
                return nil
            }
        }
    }

    private func assertNoProtocolLeak(
        _ contents: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for content in contents {
            XCTAssertFalse(content.contains("send_user_message_question_reply"), content, file: file, line: line)
            XCTAssertFalse(content.contains("questionItemId"), content, file: file, line: line)
            XCTAssertFalse(content.contains("request_user_input_async"), content, file: file, line: line)
        }
    }
}

/// 与 Desktop 真实异步提问回合同形、已脱敏的 fixture；投影单测与会话快照共用。
enum QuestionReplyFixture {
    static let threadID = "thr_question_reply"
    static let turnID = "turn_question_reply"
    static let questionItemID = "call_async_question"
    static let questionTitle = "构建 101 仍在处理，等待它完成还是改用构建 100 送审？"
    static let answer = "等待构建 101"
    static let startedAt = 1_780_100_000
    static let completedAt = 1_780_100_090
    static let snapshotReadAt = Date(timeIntervalSince1970: 1_780_200_000)

    static var questionText: String {
        "\(questionTitle)\n- 等待构建 101\n- 改用构建 100"
    }

    static var replyItem: [String: Any] {
        userItem(id: "user_reply", clientID: "client_reply", text: replyEnvelope(answer: answer))
    }

    static var followUpItem: [String: Any] {
        userItem(
            id: "user_follow_up",
            clientID: "client_follow_up",
            text: """

            <in-app-browser-context source="ambient-ui-state">
            # In app browser:
            - Current URL: https://example.com/builds
            </in-app-browser-context>

            ## My request:
            可以先更新宣传图

            """
        )
    }

    /// 顺序与真实回合一致：提问之后还有工具活动，Desktop 随后连续写入答复和普通引导。
    static var turnItems: [[String: Any]] {
        [
            userItem(id: "user_prompt", clientID: "client_prompt", text: "更新商店素材，然后准备送审。"),
            agentItem(id: "commentary_check", text: "我先核对当前可用构建。", phase: "commentary"),
            [
                "type": "agentMessage",
                "id": questionItemID,
                "text": questionText,
                "phase": "final_answer",
                "delivery": "async",
                "questions": [["title": questionTitle, "options": ["等待构建 101", "改用构建 100"]]],
            ],
            [
                "type": "commandExecution",
                "id": "cmd_check_builds",
                "command": "asc builds list",
                "cwd": "/tmp/question-reply",
                "status": "completed",
                "aggregatedOutput": "101 processing",
                "exitCode": 0,
            ],
            replyItem,
            followUpItem,
            agentItem(id: "agent_final", text: "好的，先更新宣传图，并等待构建 101。"),
        ]
    }

    static func userItem(id: String, clientID: String, text: String) -> [String: Any] {
        [
            "type": "userMessage",
            "id": id,
            "clientId": clientID,
            "content": [["type": "text", "text": text, "text_elements": [Any]()]],
        ]
    }

    static func agentItem(id: String, text: String, phase: String = "final_answer") -> [String: Any] {
        ["type": "agentMessage", "id": id, "text": text, "phase": phase]
    }

    static func turn(id: String, startedAt: Int?, completedAt: Int?, items: [[String: Any]]) -> [String: Any] {
        var turn: [String: Any] = ["id": id, "status": "completed", "items": items]
        turn["startedAt"] = startedAt
        turn["completedAt"] = completedAt
        return turn
    }

    static func questionReference(index: Int) -> String {
        #"["request_user_input_async","\#(questionItemID)",\#(index)]"#
    }

    static func replyEnvelope(answer: String) -> String {
        envelope([["questionItemId": questionReference(index: 0), "question": questionTitle, "answer": answer]])
    }

    static func envelope(_ entries: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: entries)) ?? Data()
        return wrapped(String(decoding: data, as: UTF8.self))
    }

    static func wrapped(_ body: String) -> String {
        "\(CodexAsyncQuestionReply.openingTag)\n\(body)\n\(CodexAsyncQuestionReply.closingTag)"
    }

    static func jsonValue(_ object: Any) throws -> CodexAppServerJSONValue {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(CodexAppServerJSONValue.self, from: data)
    }

    static func notification(_ method: String, item: [String: Any]) throws -> CodexAppServerNotification {
        let object: [String: Any] = [
            "method": method,
            "params": ["threadId": threadID, "turnId": turnID, "item": item],
        ]
        return try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    static func projectedHistory(turns: [[String: Any]]) async throws -> [CodexHistoryMessage] {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let thread = try XCTUnwrap(jsonValue(["turns": turns]).objectValue)
        return await runtime.historyMessages(from: thread, sessionID: threadID, snapshotReadAt: snapshotReadAt)
    }

    static func fullHistory() async throws -> [CodexHistoryMessage] {
        try await projectedHistory(turns: [
            turn(id: turnID, startedAt: startedAt, completedAt: completedAt, items: turnItems)
        ])
    }
}
