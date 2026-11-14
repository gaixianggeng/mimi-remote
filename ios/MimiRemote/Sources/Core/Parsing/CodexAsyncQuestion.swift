import Foundation

/// Desktop 的异步问题是带结构化字段的助手消息，不是等待 RPC 应答的同步请求。
struct CodexAsyncQuestion: Codable, Hashable {
    struct Question: Codable, Hashable {
        let title: String
        let options: [String]
    }

    let itemID: String
    let questions: [Question]

    init?(item: [String: CodexAppServerJSONValue]) {
        guard item["type"] == .string("agentMessage"),
              item["delivery"] == .string("async"),
              case .string(let itemID)? = item["id"], !itemID.isEmpty,
              let entries = item["questions"]?.arrayValue, !entries.isEmpty else { return nil }
        var questions: [Question] = []
        for entry in entries {
            guard let object = entry.objectValue,
                  case .string(let title)? = object["title"],
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let options: [String]
            if let raw = object["options"] {
                guard let values = raw.arrayValue,
                      values.allSatisfy({ if case .string = $0 { true } else { false } }) else { return nil }
                options = values.compactMap(\.stringValue)
            } else {
                options = []
            }
            questions.append(Question(title: title, options: options))
        }
        self.itemID = itemID
        self.questions = questions
    }

    var displayText: String { questions.map(\.title).joined(separator: "\n") }

    var activityPayload: ConversationActivityPayload {
        ConversationActivityPayload(category: .toolCall, displayTitle: displayText, asyncQuestion: self)
    }

    func request(sessionID: SessionID, turnID: TurnID?, answeredIndices: Set<Int> = []) -> AgentUserInputRequest {
        AgentUserInputRequest(
            id: itemID, threadID: sessionID, turnID: turnID, itemID: itemID,
            questions: questions.enumerated().compactMap { index, question in
                guard !answeredIndices.contains(index) else { return nil }
                return AgentUserInputQuestion(
                    id: String(index), header: "", question: question.title, isOther: true, isSecret: false,
                    options: question.options.map { AgentUserInputOption(label: $0, description: nil) }
                )
            }
        )
    }

    /// 使用与 Desktop 一致的 questionItemId 和答案信封，经普通 turn/steer 通道发送。
    /// 只提交尚未回答的题目；不能把另一端已经回答的题目隐式覆盖成“跳过”。
    func replyText(answers: [String: [String]], indices: Set<Int>) throws -> String {
        let entries = questions.enumerated().compactMap { index, question -> [String: String]? in
            guard indices.contains(index) else { return nil }
            let reference = try? JSONSerialization.data(withJSONObject: ["request_user_input_async", itemID, index])
            guard let reference, let questionID = String(data: reference, encoding: .utf8) else { return nil }
            return [
                "questionItemId": questionID,
                "question": question.title,
                "answer": (answers[String(index)] ?? []).joined(separator: "\n")
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys, .withoutEscapingSlashes])
        return "\(CodexAsyncQuestionReply.openingTag)\n\(String(decoding: data, as: UTF8.self))\n\(CodexAsyncQuestionReply.closingTag)"
    }
}

extension CodexAsyncQuestionReply {
    var activityPayload: ConversationActivityPayload {
        ConversationActivityPayload(category: .toolCall, displayTitle: displayText, questionReply: self)
    }
}

struct CodexAsyncQuestionProgress: Equatable {
    var answeredIndices: Set<Int> = []
    var isSubmitting = false
    var isExpired = false

    static func make(question: CodexAsyncQuestion, message: ConversationMessage, messages: [ConversationMessage]) -> Self {
        var result = Self()
        result.isExpired = message.turnLifecycle == .failed || message.turnLifecycle == .interrupted
        // Desktop 在新的普通用户回合开始时收起上一组问题；steering 和异步答复不构成该边界。
        if let turnID = message.turnID, let position = messages.firstIndex(where: { $0.id == message.id }) {
            result.isExpired = result.isExpired || messages.dropFirst(position + 1).contains {
                $0.role == .user && $0.kind == .message && $0.sendStatus != .failed
                    && $0.turnID != nil && $0.turnID != turnID
                    && $0.userDelivery != .guided && $0.userDelivery != .injected
            }
        }
        for candidate in messages where candidate.role == .user && candidate.sendStatus != .failed {
            guard let reply = candidate.activityPayload?.questionReply else { continue }
            for answer in reply.answers where answer.questionItemID == question.itemID {
                // 旧答复没有题目序号时不能猜测它回答了哪一题。
                guard let index = answer.questionIndex, question.questions.indices.contains(index) else { continue }
                if candidate.sendStatus == .sending || candidate.sendStatus == .uncertain || candidate.sendStatus == .local {
                    result.isSubmitting = true
                } else {
                    result.answeredIndices.insert(index)
                }
            }
        }
        if result.isResolved(question) { result.isExpired = false }
        return result
    }

    func isResolved(_ question: CodexAsyncQuestion) -> Bool {
        answeredIndices.count == question.questions.count
    }
}

extension ConversationActivityPayload {
    /// 只识别宿主工具的结构化身份。失败不等于待授权，提示始终使用条件语气。
    var needsDesktopWorktreeNotice: Bool {
        toolName == "codex_app.create_worktree" && (isInProgress || isFailure || status == nil)
    }
}
