import XCTest
@testable import MimiRemote

/// 放在既有异步答复测试组内，使核心回归入口同时覆盖提问、发送和答复。
extension ConversationQuestionReplyTests {
    private var asyncQuestionItem: [String: Any] {
        ["type": "agentMessage", "id": "async-question", "text": "请选择", "delivery": "async", "phase": "final_answer",
         "questions": [["title": "使用什么设备？", "options": ["iPad", "iPhone"]], ["title": "补充说明"]]]
    }

    private func parsedAsyncQuestion() throws -> CodexAsyncQuestion {
        try XCTUnwrap(CodexAsyncQuestion(item: XCTUnwrap(QuestionReplyFixture.jsonValue(asyncQuestionItem).objectValue)))
    }

    func testAsyncQuestionRequiresStructuredDeliveryAndValidQuestions() throws {
        let question = try parsedAsyncQuestion()
        XCTAssertEqual(question.questions.map(\.options), [["iPad", "iPhone"], []])
        for (key, value) in [("delivery", "sync" as Any), ("id", "" as Any), ("questions", [["title": "bad", "options": [42]]] as Any)] {
            var item = asyncQuestionItem
            item[key] = value
            XCTAssertNil(CodexAsyncQuestion(item: try XCTUnwrap(QuestionReplyFixture.jsonValue(item).objectValue)))
        }
        let ordinary = QuestionReplyFixture.agentItem(id: "ordinary", text: "选择：\n- iPad\n- iPhone")
        XCTAssertNil(CodexAsyncQuestion(item: try XCTUnwrap(QuestionReplyFixture.jsonValue(ordinary).objectValue)))
    }

    func testAsyncQuestionLiveHistoryAndReloadKeepOptionsAndIdentity() async throws {
        var projector = CodexAppServerEventProjector()
        guard case .messageCompleted(let live, _) = projector.project(try QuestionReplyFixture.notification("item/completed", item: asyncQuestionItem)) else {
            return XCTFail("Missing async question")
        }
        let history = try await QuestionReplyFixture.projectedHistory(turns: [
            QuestionReplyFixture.turn(id: QuestionReplyFixture.turnID, startedAt: 1, completedAt: 2, items: [asyncQuestionItem])
        ])
        XCTAssertEqual(live.activityPayload?.asyncQuestion, history.first?.activityPayload?.asyncQuestion)
        XCTAssertEqual(live.itemID, "async-question")
        guard case .messageCompleted(let started, _) = projector.project(try QuestionReplyFixture.notification("item/started", item: asyncQuestionItem)) else {
            return XCTFail("Started async question must be visible")
        }
        XCTAssertEqual(started.activityPayload, live.activityPayload)
        var emptyTextItem = asyncQuestionItem
        emptyTextItem["text"] = ""
        guard case .messageCompleted(let fallback, _) = projector.project(try QuestionReplyFixture.notification("item/completed", item: emptyTextItem)) else {
            return XCTFail("Structured questions do not require a duplicate text body")
        }
        XCTAssertEqual(fallback.content, "使用什么设备？\n补充说明")
        let store = ConversationStore()
        store.replaceHistorySnapshot(history, sessionID: "thread")
        store.replaceHistorySnapshot(history, sessionID: "thread")
        XCTAssertEqual(store.messages(for: "thread").count, 1)
        let message = try XCTUnwrap(store.messages(for: "thread").first)
        let rows = ConversationTimelineItemBuilder.items(from: [message])
        guard case .message = rows.first else { return XCTFail("Question must remain visible outside process groups") }
        let restored = try JSONDecoder().decode(CodexHistoryMessage.self, from: JSONEncoder().encode(XCTUnwrap(history.first)))
        XCTAssertEqual(restored.activityPayload?.asyncQuestion, live.activityPayload?.asyncQuestion)
        let legacyPayload = try JSONDecoder().decode(ConversationActivityPayload.self, from: Data(#"{"category":"tool_call","display_title":"Old activity","file_paths":[]}"#.utf8))
        XCTAssertNil(legacyPayload.asyncQuestion)
        XCTAssertNil(legacyPayload.questionReply)
    }

    func testAsyncReplyEnvelopeSupportsPartialAnswersSkipAndQuotedInput() throws {
        let question = try parsedAsyncQuestion()
        let text = try question.replyText(answers: ["0": ["iPhone", "内容含有 \"引号\"\n和换行"]], indices: [0, 1])
        let reply = try XCTUnwrap(CodexAsyncQuestionReply(text: text))
        XCTAssertEqual(reply.answers.map(\.questionItemID), [question.itemID, question.itemID])
        XCTAssertEqual(reply.answers.map(\.questionIndex), [0, 1])
        XCTAssertEqual(reply.answers.map(\.answer), ["iPhone\n内容含有 \"引号\"\n和换行", nil])
        let remaining = try XCTUnwrap(CodexAsyncQuestionReply(text: question.replyText(answers: ["1": ["说明"]], indices: [1])))
        XCTAssertEqual(remaining.answers.map(\.questionIndex), [1])
        XCTAssertEqual(question.request(sessionID: "thread", turnID: nil, answeredIndices: [0]).questions.map(\.id), ["1"])
    }

    func testAsyncReplyLocalEchoPendingFailureAndHistoryResolution() async throws {
        let question = try parsedAsyncQuestion()
        let store = ConversationStore()
        let message = ConversationMessage(turnID: "question-turn", role: .assistant, content: "请选择", activityPayload: question.activityPayload)
        let text = try question.replyText(answers: ["0": ["iPhone"]], indices: [0])
        store.appendLocalUser(text, sessionID: "thread", clientMessageID: "reply", sendStatus: .sending)
        let echo = try XCTUnwrap(store.messages(for: "thread").first)
        XCTAssertEqual(echo.kind, .questionReply)
        XCTAssertEqual(echo.content, "iPhone")
        XCTAssertEqual(echo.activityPayload?.questionReply?.answers.first?.questionItemID, question.itemID)
        var progress = CodexAsyncQuestionProgress.make(question: question, message: message, messages: store.messages(for: "thread"))
        XCTAssertTrue(progress.isSubmitting)
        XCTAssertTrue(progress.answeredIndices.isEmpty)
        store.updateSendStatus(clientMessageID: "reply", sessionID: "thread", status: .failed)
        progress = CodexAsyncQuestionProgress.make(question: question, message: message, messages: store.messages(for: "thread"))
        XCTAssertFalse(progress.isSubmitting)
        XCTAssertTrue(progress.answeredIndices.isEmpty)

        let replyItem = QuestionReplyFixture.userItem(id: "desktop-reply", clientID: "desktop-client", text: text)
        let history = try await QuestionReplyFixture.projectedHistory(turns: [
            QuestionReplyFixture.turn(id: QuestionReplyFixture.turnID, startedAt: 1, completedAt: 2, items: [asyncQuestionItem, replyItem])
        ])
        store.replaceHistorySnapshot(history, sessionID: "thread")
        progress = CodexAsyncQuestionProgress.make(question: question, message: message, messages: store.messages(for: "thread"))
        XCTAssertEqual(progress.answeredIndices, [0])
        XCTAssertFalse(progress.isResolved(question))
        let unrelated = try XCTUnwrap(CodexAsyncQuestionReply(text: QuestionReplyFixture.replyEnvelope(answer: "同标题的其他问题")))
        let otherMessage = ConversationMessage(role: .user, content: unrelated.displayText, activityPayload: unrelated.activityPayload)
        XCTAssertTrue(CodexAsyncQuestionProgress.make(question: question, message: message, messages: [otherMessage]).answeredIndices.isEmpty)
        let newRequest = ConversationMessage(turnID: "next-turn", role: .user, content: "开始另一个任务")
        XCTAssertTrue(CodexAsyncQuestionProgress.make(question: question, message: message, messages: [message, newRequest]).isExpired)
        let guidance = ConversationMessage(turnID: "question-turn", role: .user, content: "继续")
        XCTAssertFalse(CodexAsyncQuestionProgress.make(question: question, message: message, messages: [message, guidance]).isExpired)
        var interrupted = message
        interrupted.turnLifecycle = .interrupted
        XCTAssertTrue(CodexAsyncQuestionProgress.make(question: question, message: interrupted, messages: []).isExpired)
        var completed = message
        completed.turnLifecycle = .completed
        XCTAssertFalse(CodexAsyncQuestionProgress.make(question: question, message: completed, messages: []).isExpired,
                       "异步问题允许在产生它的回合结束后回答")
    }

    func testDesktopWorktreeNoticeUsesExactToolIdentityAndDoesNotClaimPendingApproval() throws {
        for status in ["inProgress", "failed"] {
            let item: [String: Any] = ["type": "dynamicToolCall", "id": "worktree", "namespace": "codex_app", "tool": "create_worktree", "status": status]
            let payload = try XCTUnwrap(ConversationActivityPayload(item: XCTUnwrap(QuestionReplyFixture.jsonValue(item).objectValue)))
            XCTAssertTrue(payload.needsDesktopWorktreeNotice)
            let message = ConversationMessage(role: .system, kind: .commandSummary, content: "worktree", activityPayload: payload)
            guard case .message = ConversationTimelineItemBuilder.items(from: [message]).first else {
                return XCTFail("Desktop operation notice must stay visible")
            }
        }
        XCTAssertFalse(ConversationActivityPayload(category: .toolCall, displayTitle: "worktree", status: "completed", toolName: "codex_app.create_worktree").needsDesktopWorktreeNotice)
        XCTAssertFalse(ConversationActivityPayload(category: .toolCall, displayTitle: "codex_app.create_worktree", status: "failed", toolName: "other.create_worktree").needsDesktopWorktreeNotice)
    }

    func testCompletedAsyncQuestionCanBeAnsweredWithoutRunningSocket() throws {
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversations = ConversationStore()
        let session = makeSession(id: "idle-async", projectID: "project", title: "Idle", status: "idle", source: "codex")
        let store = SessionStore(appStore: appStore, conversationStore: conversations, logStore: LogStore(), clientFactory: {
            MockSessionStoreClient(projects: [], sessions: [session])
        })
        store.sessions = [session]
        store.selectedSessionID = session.id
        let question = try parsedAsyncQuestion()
        let message = ConversationMessage(role: .assistant, content: "问题", activityPayload: question.activityPayload, turnLifecycle: .completed)
        XCTAssertNil(store.webSocket)
        XCTAssertTrue(store.canAnswerAsyncQuestion(message, sessionID: session.id), "空闲会话通过既有新回合路径回答，不要求先有运行中的 Socket")
    }

    func testAsyncAnswerUsesGuidanceAndRejectsDuplicateSubmission() async throws {
        let project = makeProject(id: "async-project")
        let running = makeSession(id: "async-session", projectID: project.id, title: "Async", status: "running", source: "codex", activeTurnID: "turn-async")
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversations = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(appStore: appStore, conversationStore: conversations, logStore: LogStore(), clientFactory: { client }, webSocketFactory: {
            let socket = MockWebSocketClient()
            sockets.append(socket)
            return socket
        })
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        for _ in 0..<50 where sockets.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let question = try parsedAsyncQuestion()
        let history = CodexHistoryMessage(id: "question", role: "assistant", content: "请选择", activityPayload: question.activityPayload, createdAt: Date(), turnID: "turn-async", itemID: question.itemID)
        conversations.replaceHistorySnapshot([history], sessionID: running.id)
        let message = try XCTUnwrap(conversations.messages(for: running.id).first { $0.itemID == question.itemID })
        let task = try XCTUnwrap(store.answerAsyncQuestion(message, sessionID: running.id, answers: ["0": ["iPhone"], "1": ["备注"]]))
        XCTAssertNil(store.answerAsyncQuestion(message, sessionID: running.id, answers: ["0": ["iPad"]]))
        let accepted = await task.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(socket.sentUserInputResponses.count, 0, "异步问题不能应答同步 RPC")
        let echo = try XCTUnwrap(conversations.messages(for: running.id).last)
        XCTAssertEqual(echo.kind, .questionReply)
        XCTAssertEqual(echo.content, "iPhone\n备注")
        XCTAssertEqual(echo.userDelivery, .guided)
        XCTAssertEqual(store.selectedSession?.preview, "iPhone")
        XCTAssertFalse(store.canAnswerAsyncQuestion(message, sessionID: running.id), "未确认的本地答复阻止重复提交")

        var secondItem = asyncQuestionItem
        secondItem["id"] = "second-question"
        let secondQuestion = try XCTUnwrap(CodexAsyncQuestion(item: XCTUnwrap(QuestionReplyFixture.jsonValue(secondItem).objectValue)))
        let secondHistory = CodexHistoryMessage(id: "second", role: "assistant", content: "请选择", activityPayload: secondQuestion.activityPayload, createdAt: Date(), turnID: "turn-async", itemID: secondQuestion.itemID)
        conversations.replaceHistorySnapshot([history, secondHistory], sessionID: running.id)
        let second = try XCTUnwrap(conversations.messages(for: running.id).first { $0.itemID == secondQuestion.itemID })
        let switchingTask = try XCTUnwrap(store.answerAsyncQuestion(second, sessionID: running.id, answers: ["0": ["iPad"]]))
        let beforeSwitch = conversations.messages(for: running.id).count
        store.selectedSessionID = "another-session"
        let switchAccepted = await switchingTask.value
        XCTAssertFalse(switchAccepted)
        XCTAssertEqual(conversations.messages(for: running.id).count, beforeSwitch, "切换会话后不得创建答复")
        XCTAssertTrue(store.asyncQuestionSubmissions.isEmpty)
    }
}
