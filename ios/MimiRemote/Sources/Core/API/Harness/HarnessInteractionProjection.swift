import Foundation

/// `$events` 交互（审批 / 追问）→ 既有 `AgentEvent` 的唯一投影入口。
///
/// 宿主级观察者与页面级客户端都要产出这些事件，两处各写一份必然漂移：
/// 漂移的后果是"同一个审批在列表页和会话页长得不一样"。因此形状只在这里定义一次。
///
/// 形状上的两条约束（契约 §2.8）：
/// - 归属用**瀑布自己的 `agentId`**（Harness 的 agent 注册表 id 等于会话 id），
///   不拿"当前打开的是哪个会话"兜底。
/// - 追问的选项只有 `label`，没有 `option.id`；不得凭空造一个 id 出来。
enum HarnessInteractionProjection {

    /// 一次交互的身份。三处（登记、展示、应答）共用它，避免各自算一份。
    struct Context: Equatable {
        let eventID: String
        let sessionID: String
        let generation: UInt64
    }

    /// 审批请求。
    static func approvalRequest(
        _ context: Context,
        request: HarnessWaterfallPayload
    ) -> AgentEvent {
        .approvalRequest(
            AgentApprovalRequest(
                id: context.eventID,
                title: request.toolName?.trimmedNonEmpty ?? L10n.text("ui.request_approval"),
                body: request.reason?.trimmedNonEmpty,
                kind: "harness_tool",
                risk: "high",
                availableDecisions: ["accept", "decline"]
            ),
            metadata(context)
        )
    }

    /// 选择题请求。
    static func questionRequest(
        _ context: Context,
        request: HarnessWaterfallPayload
    ) -> AgentEvent {
        let questions = (request.questions ?? []).compactMap { question -> AgentUserInputQuestion? in
            guard let id = question.id?.trimmedNonEmpty,
                  let text = question.question?.trimmedNonEmpty else { return nil }
            return AgentUserInputQuestion(
                id: id,
                header: text,
                question: text,
                isOther: false,
                isSecret: false,
                options: (question.options ?? []).compactMap { option in
                    option.label?.trimmedNonEmpty.map {
                        AgentUserInputOption(label: $0, description: nil)
                    }
                }
            )
        }
        return .userInputRequest(
            AgentUserInputRequest(
                id: context.eventID,
                threadID: context.sessionID,
                turnID: nil,
                itemID: context.eventID,
                questions: questions
            ),
            metadata(context)
        )
    }

    /// 交互已终结（上游接受、另一端先答、或上游取消）：撤卡。
    static func resolved(_ context: Context, isQuestion: Bool) -> AgentEvent {
        isQuestion
            ? .userInputResolved(metadata(context), skipped: false)
            : .approvalResolved(metadata(context))
    }

    /// 交互元数据。**会话归属由 `context.sessionID` 决定**，不是调用方当前的会话。
    static func metadata(_ context: Context) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: nil,
            sessionID: context.sessionID,
            turnID: nil,
            itemID: context.eventID,
            messageID: "h-interaction-\(context.eventID)",
            clientMessageID: nil,
            revision: Int(truncatingIfNeeded: context.generation),
            createdAt: nil
        )
    }
}
