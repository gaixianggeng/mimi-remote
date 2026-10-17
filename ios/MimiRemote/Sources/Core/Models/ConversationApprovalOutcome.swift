import Foundation

/// 时间线里一条审批记录的处理结果（#750）。
///
/// 实时链路在写入消息时就把结果记进 `ConversationMessage.approvalState`，之后不再从正文推断：
/// App 可以在运行时切换语言，已经写好的正文仍是旧语言，按当前语言比前缀会把已处理的审批
/// 误判回「等待审批」。只有没记录结果的消息（历史回放、旧版本写入）才按全部已支持语言识别前缀。
enum ConversationApprovalOutcome: Equatable, Hashable {
    case pending
    case approved
    case declined
    /// 远端只告诉我们请求已清理（`serverRequest/resolved`、回合结束或中断），不知道具体决定。
    case resolved

    private static let supportedLanguages: [AppLanguage] = [.simplifiedChinese, .english]

    /// 按全部已支持语言识别审批正文；不认识的审批正文视为待处理。
    static func classify(_ content: String) -> ConversationApprovalOutcome {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasLocalizedPrefix(content, keys: ["ui.approval_approved", "ui.approved"]) {
            return .approved
        }
        if hasLocalizedPrefix(content, keys: ["ui.approval_rejected", "ui.rejected"]) {
            return .declined
        }
        if hasLocalizedPrefix(content, keys: ["ui.approval_resolved"]) {
            return .resolved
        }
        return .pending
    }

    /// 从「等待审批：标题，风险：高」里取出标题。前缀和风险后缀按全部已支持语言识别，
    /// 这样待处理时与解决时的界面语言不同，也能取到同一个标题。
    static func pendingTitle(from content: String) -> String {
        guard let prefix = localizedVariants(of: "ui.awaiting_approval").first(where: { content.hasPrefix($0) }) else {
            return content
        }
        var value = String(content.dropFirst(prefix.count))
        let riskSeparators = templateVariants(of: "ui.risk_value").map {
            L10n.formatTemplate($0, arguments: [""])
        }
        if let range = riskSeparators.compactMap({ value.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            value = String(value[..<range.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func hasLocalizedPrefix(_ content: String, keys: [String]) -> Bool {
        keys.contains { key in
            localizedVariants(of: key).contains { content.hasPrefix($0) }
        }
    }

    private static func localizedVariants(of key: String) -> [String] {
        templateVariants(of: key).filter { !$0.isEmpty && $0 != key }
    }

    private static func templateVariants(of key: String) -> [String] {
        var values: [String] = []
        for value in [L10n.text(key)] + supportedLanguages.map({ L10n.text(key, language: $0) })
        where !values.contains(value) {
            values.append(value)
        }
        return values
    }
}

extension ConversationMessage {
    /// 审批记录的处理结果；非审批消息为 nil。优先用写入时记下的结果，见 `ConversationApprovalOutcome`。
    var approvalOutcome: ConversationApprovalOutcome? {
        guard kind == .approval else {
            return nil
        }
        return approvalState ?? ConversationApprovalOutcome.classify(content)
    }
}
