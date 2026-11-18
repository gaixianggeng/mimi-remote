import Foundation

struct AsyncQuestionSubmissionKey: Hashable {
    let hostScope: HostScope
    let sessionID: SessionID
    let itemID: AgentItemID
}

@MainActor
extension SessionStore {
    func isAnsweringAsyncQuestion(_ question: CodexAsyncQuestion, sessionID: SessionID) -> Bool {
        asyncQuestionSubmissions.contains(AsyncQuestionSubmissionKey(
            hostScope: appStore.activeHostScope, sessionID: sessionID, itemID: question.itemID
        ))
    }

    func canAnswerAsyncQuestion(_ message: ConversationMessage, sessionID: SessionID) -> Bool {
        guard selectedSessionID == sessionID,
              let session = sessionsByID[sessionID],
              !isProtocolReadOnlySession(session),
              session.allowsDirectInput,
              canControlSession(session),
              (!session.isRunning || (connectedSessionID == sessionID
                  && connectedHostScope == appStore.activeHostScope
                  && webSocket != nil && webSocketStatus == .connected)),
              connectionTermination == nil, !appStore.requiresRePairing, !isNetworkUnavailable,
              let question = message.activityPayload?.asyncQuestion else { return false }
        let progress = CodexAsyncQuestionProgress.make(
            question: question, message: message, messages: conversationStore.messages(for: sessionID)
        )
        return !progress.isExpired && !progress.isSubmitting && !progress.isResolved(question)
    }

    /// 点击时同步捕获主机、会话和连接，模型准备之后重新检查，防止切页后发到其他会话。
    func answerAsyncQuestion(
        _ message: ConversationMessage,
        sessionID: SessionID,
        answers: [String: [String]]
    ) -> Task<Bool, Never>? {
        guard canAnswerAsyncQuestion(message, sessionID: sessionID),
              let question = message.activityPayload?.asyncQuestion else { return nil }
        let context = captureTurnSubmissionContext()
        let generation = webSocketConnectionGeneration
        let key = AsyncQuestionSubmissionKey(hostScope: context.hostScope, sessionID: sessionID, itemID: question.itemID)
        guard asyncQuestionSubmissions.insert(key).inserted else { return nil }
        return Task { [weak self] in
            guard let self else { return false }
            defer { asyncQuestionSubmissions.remove(key) }
            let payload = await payloadResolvingRequiredModel(
                CodexAppServerTurnPayload(prompt: question.displayText), submissionContext: context
            )
            guard !Task.isCancelled,
                  context.selectionLease == currentSelectionLease(),
                  context.hostScope == appStore.activeHostScope,
                  generation == webSocketConnectionGeneration,
                  let current = conversationStore.messages(for: sessionID).first(where: {
                      $0.id == message.id && $0.activityPayload?.asyncQuestion == question
                  }),
                  canAnswerAsyncQuestion(current, sessionID: sessionID) else { return false }
            let progress = CodexAsyncQuestionProgress.make(
                question: question, message: current, messages: conversationStore.messages(for: sessionID)
            )
            let indices = Set(question.questions.indices).subtracting(progress.answeredIndices)
            guard let text = try? question.replyText(answers: answers, indices: indices) else { return false }
            let currentContext = captureTurnSubmissionContext()
            var reply = payload
            reply.input = [.text(text)]
            // 异步问题可以在执行中回答；复用既有 guidance/新回合选择和发送结果对账。
            return await sendTurn(reply, runningDelivery: .guided, submissionContext: currentContext)
        }
    }
}
