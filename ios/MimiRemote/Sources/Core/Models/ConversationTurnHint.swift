import Foundation

/// Claude 回合末尾给用户的交互提示：桌面版注入的「下一步提示框」与「新任务提议」，
/// 以及 Mimi 适配器提供的同名工具。协议上它们是普通 MCP 工具调用，这里按 server/tool
/// 白名单识别，并只读取渲染卡片需要的参数字段。
struct ConversationTurnHint: Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case nextStep = "next_step"
        case taskProposal = "task_proposal"
    }

    /// 谁提供的工具：桌面版的提议只能在桌面版开启，Mimi 的提议可以在 App 里开启。
    enum Origin: String, Codable, Hashable {
        case claudeDesktop = "claude_desktop"
        case mimi
    }

    struct Action: Codable, Hashable {
        let label: String
        let message: String
    }

    let kind: Kind
    let origin: Origin
    let recap: String?
    let question: String?
    let actions: [Action]
    let title: String?
    let brief: String?

    /// 按钮最多显示三个，与桌面版一致；文案过长的按钮会挤掉其他按钮。
    static let maximumActions = 3
    /// 任务说明可能有几千字，卡片只保留可读长度，完整内容仍在原会话记录里。
    static let maximumBriefCharacters = 4_000

    init(
        kind: Kind,
        origin: Origin,
        recap: String? = nil,
        question: String? = nil,
        actions: [Action] = [],
        title: String? = nil,
        brief: String? = nil
    ) {
        self.kind = kind
        self.origin = origin
        self.recap = recap
        self.question = question
        self.actions = actions
        self.title = title
        self.brief = brief
    }

    init?(item: [String: CodexAppServerJSONValue]) {
        guard item["type"]?.stringValue == "mcpToolCall",
              let server = item["server"]?.stringValue,
              let tool = item["tool"]?.stringValue,
              let arguments = item["arguments"]?.objectValue else {
            return nil
        }
        let origin: Origin
        let kind: Kind
        switch (server, tool) {
        case ("ccd_turn", "wrap_up"):
            (origin, kind) = (.claudeDesktop, .nextStep)
        case ("ccd_session", "start_session"), ("ccd_session", "spawn_task"):
            (origin, kind) = (.claudeDesktop, .taskProposal)
        case ("mimi", "wrap_up"):
            (origin, kind) = (.mimi, .nextStep)
        case ("mimi", "start_session"):
            (origin, kind) = (.mimi, .taskProposal)
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
                origin: origin,
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
                origin: origin,
                title: title,
                brief: brief.map { String($0.prefix(Self.maximumBriefCharacters)) }
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
}
