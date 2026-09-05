import Foundation

// 补充信息（requestUserInput）在时间线上的状态机：等待、提交、跳过、失效、退回。
// 这几段文案靠彼此的前缀互相识别，改一处必须同时看另一处，所以放在同一个文件里。
extension ConversationStore {
    func resolveLatestPendingUserInput(sessionID: String, skipped: Bool) {
        guard var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)],
              let index = list.lastIndex(where: { message in
                  message.kind == .userInput
                      && (message.content.hasPrefix(L10n.text("ui.waiting_for_additional_information_3a146c9c")) || message.content.hasPrefix(L10n.text("ui.waiting_for_boot_input")))
              }) else {
            if skipped {
                appendSystem(L10n.text("ui.supplementary_information_skipped_continue_execution"), sessionID: sessionID, kind: .userInput)
            }
            return
        }
        let title = pendingUserInputTitle(from: list[index].content)
        let prefix = skipped ? L10n.text("ui.additional_information_skipped") : L10n.text("ui.additional_information_has_been_submitted")
        list[index].content = title.isEmpty ? prefix : L10n.format("ui.labeled_value", prefix, title)
        list[index].updatedAt = Date()
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
    }

    /// 把最后一条补充信息记录改写成「已失效」。
    ///
    /// 与 `resolveLatestPendingUserInput` 的差别是不挑前缀：提交是乐观收起的，
    /// 失败传回来时那行往往已经被改写成「补充信息已提交」，再按「等待补充信息」
    /// 去找就找不到，只能补一条无关的「已跳过」。用户需要看到的是这次没送到。
    func markLatestUserInputExpired(sessionID: String) {
        guard var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)],
              let index = list.lastIndex(where: { $0.kind == .userInput }) else {
            return
        }
        list[index].content = L10n.text("ui.supplemental_information_request_expired")
        list[index].updatedAt = Date()
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
    }

    func restorePendingUserInput(_ request: AgentUserInputRequest, sessionID: String) {
        let text = L10n.format("ui.waiting_for_additional_information_named", request.title)
        guard var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)] else {
            appendSystem(text, sessionID: sessionID, kind: .userInput)
            return
        }
        // 补充信息提交是乐观收起 UI；如果发送失败，需要把时间线从“已提交”退回“等待补充信息”。
        if let index = list.lastIndex(where: { message in
            message.kind == .userInput
                && (message.content.hasPrefix(L10n.text("ui.additional_information_has_been_submitted")) || message.content.hasPrefix(L10n.text("ui.boot_input_submitted")))
        }) {
            list[index].content = text
            list[index].updatedAt = Date()
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
            return
        }
        appendSystem(text, sessionID: sessionID, kind: .userInput)
    }

    func upsertPendingUserInputMessage(
        _ text: String,
        sessionID: String,
        metadata: AgentEventMetadata?
    ) -> Bool {
        guard var list = messagesByScopedSessionID[scopedSessionID(for: sessionID)] else {
            return false
        }
        let requestID = metadata?.itemID
        let title = pendingUserInputTitle(from: text)
        guard let index = list.lastIndex(where: { message in
            guard message.kind == .userInput, isPendingUserInputText(message.content) else {
                return false
            }
            if let requestID, let existingRequestID = message.itemID {
                return existingRequestID == requestID
            }
            // 旧历史可能没有 itemID；仅在标题一致时把它升级为当前仍挂起的同一交互。
            return message.content == text || pendingUserInputTitle(from: message.content) == title
        }) else {
            return false
        }
        var didChange = false
        // 旧历史卡没有 request id 时，在首次实时重放时补齐身份。否则后续同标题的新请求
        // 仍会被误认为同一张卡，造成新的补充信息交互不可见。
        if list[index].itemID == nil, let requestID {
            list[index].itemID = requestID
            didChange = true
        }
        if list[index].turnID == nil, let turnID = metadata?.turnID {
            list[index].turnID = turnID
            didChange = true
        }
        if list[index].stableID == nil, let messageID = metadata?.messageID {
            list[index].stableID = messageID
            didChange = true
        }
        if list[index].content != text {
            list[index].content = text
            didChange = true
        }
        if didChange {
            // stableID 可能在旧卡升级时首次出现，必须同步重建索引，避免数组与按稳定 ID 查找不一致。
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: true)
        }
        return true
    }

    func pendingUserInputTitle(from text: String) -> String {
        for prefix in [L10n.text("ui.waiting_for_additional_information_3a146c9c"), L10n.text("ui.waiting_for_boot_input")] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }

    func isPendingUserInputText(_ text: String) -> Bool {
        text.hasPrefix(L10n.text("ui.waiting_for_additional_information_3a146c9c"))
            || text.hasPrefix(L10n.text("ui.waiting_for_boot_input"))
    }
}
