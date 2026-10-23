import Foundation

/// Claude 回合末尾给用户的交互提示。协议上它们是普通 MCP 工具调用，
/// 这里按 server/tool 白名单识别，并只读取渲染卡片需要的参数字段。
struct ConversationTurnHint: Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case nextStep = "next_step"
        case taskProposal = "task_proposal"
    }

    struct Action: Codable, Hashable {
        let label: String
        let message: String
    }

    enum UserAction: Hashable {
        case reply(Action)
        case startTask
    }

    let kind: Kind
    let recap: String?
    let question: String?
    let actions: [Action]
    let title: String?
    let brief: String?
    /// 只有 Mimi Bridge 用本机 Overlay 随机 ID 签发的提议才有此字段。
    let mimiProposalID: String?

    /// 按钮最多显示三个，与桌面版一致；文案过长的按钮会挤掉其他按钮。
    static let maximumActions = 3
    /// 任务说明可能有几千字，卡片只保留可读长度，完整内容仍在原会话记录里。
    static let maximumBriefCharacters = 4_000

    init(
        kind: Kind,
        recap: String? = nil,
        question: String? = nil,
        actions: [Action] = [],
        title: String? = nil,
        brief: String? = nil,
        mimiProposalID: String? = nil
    ) {
        self.kind = kind
        self.recap = recap
        self.question = question
        self.actions = actions
        self.title = title
        self.brief = brief
        self.mimiProposalID = mimiProposalID
    }

    init?(item: [String: CodexAppServerJSONValue]) {
        // 失败或中断的同名工具仍按普通 MCP 失败展示，不能降级成可操作卡片。
        guard item["type"]?.stringValue == "mcpToolCall",
              let status = item["status"]?.stringValue,
              status == "completed" || status == "inProgress",
              !Self.hasError(item["error"]),
              let server = item["server"]?.stringValue,
              let tool = item["tool"]?.stringValue,
              let arguments = item["arguments"]?.objectValue else {
            return nil
        }
        let kind: Kind
        switch (server, tool) {
        case ("ccd_turn", "wrap_up"):
            kind = .nextStep
        case ("ccd_session", "start_session"), ("ccd_session", "spawn_task"):
            kind = .taskProposal
        default:
            return nil
        }
        switch kind {
        case .nextStep:
            let actions = (arguments["actions"]?.arrayValue ?? []).compactMap { value -> Action? in
                guard let object = value.objectValue,
                      let label = Self.text(object["label"]),
                      let message = Self.text(object["message"]) else { return nil }
                return Action(label: label, message: message)
            }
            let recap = Self.text(arguments["recap"])
            let question = Self.text(arguments["ask"])
            guard recap != nil || question != nil else { return nil }
            self.init(
                kind: kind,
                recap: recap,
                // 没有问题时按钮没有上下文，桌面版也只在提问时画按钮。
                question: question,
                actions: question == nil ? [] : Array(actions.prefix(Self.maximumActions))
            )
        case .taskProposal:
            // 桌面版「接受提议」只回传 proposal_id，没有标题，这类调用不是新提议。
            guard let title = Self.text(arguments["title"]) else { return nil }
            // spawn_task 用 tldr 作为给用户看的摘要，start_session 只有 prompt。
            let brief = Self.text(arguments["tldr"]) ?? Self.text(arguments["prompt"])
            self.init(
                kind: kind,
                title: title,
                brief: brief.map { String($0.prefix(Self.maximumBriefCharacters)) },
                mimiProposalID: tool == "start_session" ? Self.trustedProposalID(item) : nil
            )
        }
    }

    /// 无法渲染卡片的场景（旧版本、复制、通知摘要）使用的纯文本。
    var plainText: String {
        switch kind {
        case .nextStep:
            return [recap, question].compactMap { $0 }.joined(separator: "\n\n")
        case .taskProposal:
            return [title, brief].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    private static func text(_ value: CodexAppServerJSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func hasError(_ value: CodexAppServerJSONValue?) -> Bool {
        guard let value else { return false }
        if case .null = value { return false }
        return true
    }

    private static func trustedProposalID(_ item: [String: CodexAppServerJSONValue]) -> String? {
        guard let marker = item["result"]?.objectValue?["structuredContent"]?
            .objectValue?["mimi_task_proposal"]?.objectValue,
              marker["version"]?.intValue == 1,
              let proposalID = text(marker["proposal_id"]),
              proposalID.utf8.count <= 256 else {
            return nil
        }
        return proposalID
    }
}

/// 卡片身份必须同时绑定 turn 和 item。缺少任一协议身份时仍可展示，但不能发送动作。
struct ConversationTurnHintIdentity: Hashable {
    let turnID: TurnID
    let itemID: AgentItemID

    init?(message: ConversationMessage) {
        guard message.activityPayload?.turnHint != nil,
              let turnID = message.turnID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !turnID.isEmpty,
              let itemID = message.itemID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !itemID.isEmpty else {
            return nil
        }
        self.turnID = turnID
        self.itemID = itemID
    }

    func matches(_ message: ConversationMessage) -> Bool {
        message.turnID == turnID && message.itemID == itemID && message.activityPayload?.turnHint != nil
    }
}

enum ConversationTurnHintActionPolicy {
    /// 只允许回复当前会话最后一张提示卡；提示后出现用户消息时，旧动作立即失效。
    static func isLatestActionableHint(
        _ identity: ConversationTurnHintIdentity,
        in messages: [ConversationMessage]
    ) -> Bool {
        for message in messages.reversed() {
            if identity.matches(message) {
                return true
            }
            if message.role == .user {
                return false
            }
            if let turnID = message.turnID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !turnID.isEmpty,
               turnID != identity.turnID {
                return false
            }
            if message.activityPayload?.turnHint != nil {
                return false
            }
        }
        return false
    }
}

/// 卡片本地交互状态。失败回到 idle 允许重试；成功后保持 submitted，阻止重复发送。
struct ConversationTurnHintInteractionState: Equatable {
    enum Submission: Equatable {
        case idle
        case submitting(actionIndex: Int)
        case submitted(actionIndex: Int)
    }

    private(set) var submission: Submission = .idle
    private(set) var isDismissed = false

    mutating func begin(actionIndex: Int) -> Bool {
        guard !isDismissed, submission == .idle else { return false }
        submission = .submitting(actionIndex: actionIndex)
        return true
    }

    mutating func finish(actionIndex: Int, succeeded: Bool) {
        guard submission == .submitting(actionIndex: actionIndex) else { return }
        submission = succeeded ? .submitted(actionIndex: actionIndex) : .idle
    }

    mutating func dismiss() -> Bool {
        guard submission == .idle else { return false }
        isDismissed = true
        return true
    }

    func canSubmit(cardCanAct: Bool) -> Bool {
        cardCanAct && !isDismissed && submission == .idle
    }

    func isSelected(actionIndex: Int) -> Bool {
        submission == .submitting(actionIndex: actionIndex)
            || submission == .submitted(actionIndex: actionIndex)
    }
}
