import Foundation

/// Codex Desktop 回答 `request_user_input_async` 提问时写回 Thread 的用户答复。
///
/// app-server 协议没有独立的答复 Item：Desktop 把 `[{questionItemId, question, answer}]`
/// 包进固定标签，作为普通 `userMessage` 引导当前回合。实时事件和历史读取都在投影入口
/// 用这里的结构化结果映射为 `MessageKind.questionReply`，协议标签、JSON 和调用标识
/// 不进入时间线。跳过的问题（答案缺失、为 null 或空白）仍属于答复，显示为“已跳过”。
/// 只有包装残缺、JSON 结构无法解析、正文中讨论标签、附带其他内容，或没有任何一项能
/// 关联到异步提问时，才保持普通用户消息，不能误吞用户真实输入。
struct CodexAsyncQuestionReply: Equatable {
    struct Answer: Equatable {
        /// 对应提问 `agentMessage` 的 Item ID（即 `request_user_input_async` 的 call id）。
        let questionItemID: String?
        /// 同一次提问中第几个问题；旧载荷缺失时为 nil。
        let questionIndex: Int?
        let question: String?
        /// 去除首尾空白后的答案；跳过的问题为 nil，展示时使用本地化占位而不是回退原始载荷。
        let answer: String?
    }

    static let openingTag = "<send_user_message_question_reply>"
    static let closingTag = "</send_user_message_question_reply>"
    private static let asyncQuestionToolName = "request_user_input_async"

    let answers: [Answer]

    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.openingTag),
              trimmed.hasSuffix(Self.closingTag),
              trimmed.count > Self.openingTag.count + Self.closingTag.count else {
            return nil
        }
        let body = trimmed
            .dropFirst(Self.openingTag.count)
            .dropLast(Self.closingTag.count)
        guard let data = String(body).data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              !entries.isEmpty else {
            return nil
        }
        var answers: [Answer] = []
        answers.reserveCapacity(entries.count)
        for entry in entries {
            guard let object = entry as? [String: Any],
                  let answer = Self.answerText(object["answer"]) else {
                return nil
            }
            let questionReference = Self.questionReference(object["questionItemId"])
            let question = (object["question"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            answers.append(Answer(
                questionItemID: questionReference?.itemID,
                questionIndex: questionReference?.index,
                question: question?.isEmpty == false ? question : nil,
                answer: answer.isEmpty ? nil : answer
            ))
        }
        // 用户手动粘贴的同形文本通常不带 Desktop 生成的提问标识；至少一项能关联到异步提问才识别。
        guard answers.contains(where: { $0.questionItemID != nil }) else {
            return nil
        }
        self.answers = answers
    }

    /// 时间线、复制和检索只使用用户选择或填写的答案；多问题按提问顺序逐行列出。
    var displayText: String {
        answers
            .map { $0.answer ?? L10n.text("ui.question_reply_skipped") }
            .joined(separator: "\n")
    }

    /// 返回 nil 表示答案字段类型无法识别（整条回退原文）；跳过的问题返回空串。
    private static func answerText(_ value: Any?) -> String? {
        let parts: [String]
        if value == nil || value is NSNull {
            // Desktop 允许跳过问题：字段缺失或为 null 都按跳过处理。
            parts = []
        } else if let text = value as? String {
            parts = [text]
        } else if let texts = value as? [String] {
            // 多选题可能返回数组；每个选项单独成行，不能拼成看似单个答案的文本。
            parts = texts
        } else {
            return nil
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// `questionItemId` 是 JSON 字符串编码的 `[工具名, callId, 问题序号]`。
    /// 只信任异步提问工具的结构，其他形态不推断关联关系。
    private static func questionReference(_ value: Any?) -> (itemID: String, index: Int?)? {
        guard let raw = value as? String,
              let data = raw.data(using: .utf8),
              let parts = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              parts.count >= 2,
              parts[0] as? String == asyncQuestionToolName,
              let itemID = (parts[1] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !itemID.isEmpty else {
            return nil
        }
        let index = parts.count > 2 ? (parts[2] as? NSNumber)?.intValue : nil
        return (itemID, index)
    }
}
