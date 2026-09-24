import Foundation

/// 原生 journal → Mimi 展示数据。**这是唯一的映射入口。**
///
/// 历史与实时共用它：同一条持久记录，无论来自 opening snapshot、历史分页还是 live 帧，
/// 都经过同一个 `project(durableEvent:)`。契约 D3 与 H08 卡片都要求这一点——
/// 两条路径各写一份映射，就是"流式到历史有重复/缺漏"的成因。
///
/// ## 三条必要的克制
///
/// 1. **不伪造成 Codex 形状**。Harness 的工具不是 shell 命令，也不是文件变更；
///    把它塞进 `commandExecution`/`fileChange` 会让 UI 用错误的语义渲染它
///    （例如给一个非 shell 工具显示"退出码"）。卡片明确禁止这么做。
/// 2. **不把注入内容当用户输入**。`system/message` 与 `request/context` 是 Harness
///    注入的上下文，它们不该在时间线上长得像用户说的话。
/// 3. **认不出的类型显式跳过**，不猜、也不假成功。未知事件留诊断即可，UI 不该因此崩。
///
/// ## 与 H06 的分工
///
/// H06 的 `HarnessSessionJournal` 管**数据**（seq 主键、去重、结算关联）；
/// 本文件只管**把已确认的数据翻译成展示类型**。因此它不持有可变状态，
/// 是纯函数集合——投影结果只依赖输入。
enum HarnessPresentationProjector {

    /// 一条持久记录的**稳定展示身份**。
    ///
    /// 历史页与实时投影必须算出同一个 id，否则同一条消息会在时间线上出现两次
    /// （历史一条、直播一条）。时间线 reducer 按 id 做原位覆盖，没有"seq 相同就自动
    /// 合并"的兜底，因此身份规则必须**只有一处**。
    ///
    /// 取值优先级：
    /// 1. 上游自带的原生消息 id（`data.message.id`）——最权威，历史与直播都拿得到；
    /// 2. 持久日志的 `seq`——它同样出现在两条路径上，且顺序无关。
    ///
    /// 两者都没有时返回 nil，调用方跳过而不是编一个 id。
    static func stableMessageID(
        for event: HarnessDurableEvent,
        prefix: String
    ) -> MessageID? {
        if let native = event.data?["message"]?["id"]?.stringValue?.trimmedNonEmpty {
            return "h-msg-\(native)-\(prefix)"
        }
        if let seq = event.seq {
            return "h-seq-\(seq)-\(prefix)"
        }
        return nil
    }

    /// 一条持久记录投影出的展示事件。
    ///
    /// 返回数组而不是单值：一条记录可能产生不止一个展示事件（例如同时更新正文与时间线），
    /// 也可能产生零个（未知类型）。
    static func project(
        durableEvent event: HarnessDurableEvent,
        sessionID: SessionID,
        assistantMessageID: MessageID? = nil
    ) -> [AgentEvent] {
        guard let type = event.type else { return [] }
        switch type {
        case HarnessWireEventType.turnStart:
            return [.turnStarted(metadata(event, sessionID: sessionID))]
        case HarnessWireEventType.turnEnd:
            return [.turnCompleted(metadata(event, sessionID: sessionID))]
        case HarnessWireEventType.userMessage:
            return projectUserMessage(event, sessionID: sessionID)
        case HarnessWireEventType.assistantMessage:
            return projectAssistantMessage(
                event,
                sessionID: sessionID,
                messageID: assistantMessageID
            )
        case HarnessWireEventType.systemMessage:
            return projectSystemMessage(event, sessionID: sessionID)
        case HarnessWireEventType.toolCall:
            return projectToolEvent(event, sessionID: sessionID, isResult: false)
        case HarnessWireEventType.toolResult:
            return projectToolEvent(event, sessionID: sessionID, isResult: true)
        case HarnessWireEventType.stepStart, HarnessWireEventType.stepEnd:
            // 步骤边界不单独展示：它们没有独立可读内容，展示出来只是噪声。
            // 进度感由工具活动与正文增量提供。
            return []
        default:
            // 认不出的类型不猜。保留诊断由上层决定，这里不产出展示事件。
            return []
        }
    }

    /// 工具事件投影成"过程条目"的**唯一解释**。
    ///
    /// 历史页与实时都消费它，因此两边对"哪些工具事件可展示、叫什么名字、
    /// 是运行中还是完成"给出**同一个答案**。各写一份必然漂移——漂移的表现
    /// 就是"看着有、重开会话没有"。
    ///
    /// 认不出归属时返回 nil：不产出，也不伪造 id。否则会留下一个永远"运行中"
    /// 的条目，同时凭空多出一条"已完成"的记录。
    static func toolEntry(from event: HarnessDurableEvent) -> HarnessToolEntry? {
        let isResult = event.type == HarnessWireEventType.toolResult
        guard let identity = toolIdentity(from: event, isResult: isResult) else {
            return nil
        }
        let name = event.data?["name"]?.stringValue?.trimmedNonEmpty
            ?? toolNameInResult(event)
        // 完成与失败只由真实证据决定：`tool/call` 只说明模型决定了调什么，
        // 工具还没跑完；失败也是一次结果，不借"结果到达"冒充成功。
        let status = !isResult ? "running" : (toolResultIsError(event) ? "failed" : "completed")
        return HarnessToolEntry(
            id: identity,
            toolName: name,
            status: status,
            seq: event.seq
        )
    }

    /// 工具条目走既有过程通道（与 Codex 的 `processItemCompleted` 同一处）。
    private static func projectToolEvent(
        _ event: HarnessDurableEvent,
        sessionID: SessionID,
        isResult: Bool
    ) -> [AgentEvent] {
        guard let entry = toolEntry(from: event) else { return [] }
        return [.processItemCompleted(
            AgentMessage(
                id: entry.id,
                sessionID: sessionID,
                itemID: entry.id,
                role: .system,
                kind: .commandSummary,
                content: entry.displayTitle,
                activityPayload: entry.activityPayload,
                seq: entry.seq.map { EventSequence($0) },
                sendStatus: .confirmed
            ),
            nil,
            metadata(event, sessionID: sessionID)
        )]
    }

    /// 这次工具事件的稳定身份，找不到就返回 nil。
    ///
    /// `tool/call` 的 `callId` 是文档形状。`tool/result` 的 callId 位置在冻结契约里
    /// **没有**实测记录，因此按文档里确实出现过的两个位置依次尝试：
    /// 结果消息的 `source.callId`、内容块上的 `toolCallId`。都取不到就**不猜**。
    private static func toolIdentity(from event: HarnessDurableEvent, isResult: Bool) -> String? {
        if !isResult {
            return event.data?["callId"]?.stringValue?.trimmedNonEmpty.map { "h-tool-\($0)" }
        }
        if let callID = event.data?["message"]?["source"]?["callId"]?.stringValue?.trimmedNonEmpty {
            return "h-tool-\(callID)"
        }
        for block in event.data?["message"]?["content"]?.arrayValue ?? [] {
            if let callID = block["toolCallId"]?.stringValue?.trimmedNonEmpty {
                return "h-tool-\(callID)"
            }
        }
        return nil
    }

    /// 结果是否明确标了失败。
    ///
    /// 只有**明确**为 error 才算失败；读不到按成功处理。代价不对称：
    /// 把成功显示成失败会让用户以为工具坏了。
    private static func toolResultIsError(_ event: HarnessDurableEvent) -> Bool {
        if event.data?["error"] != nil { return true }
        for block in event.data?["message"]?["content"]?.arrayValue ?? [] {
            if block["isError"]?.boolValue == true { return true }
        }
        return false
    }

    private static func toolNameInResult(_ event: HarnessDurableEvent) -> String? {
        for block in event.data?["message"]?["content"]?.arrayValue ?? [] {
            if let name = block["name"]?.stringValue?.trimmedNonEmpty { return name }
        }
        return nil
    }

    /// 把一条已确认的推理 chunk 交给既有过程通道。
    ///
    /// 推理走 `processItemCompleted` + `category: .thinking`——**与 Codex/Claude 同一条
    /// 通道**，过程展开不必为原生再学一套渲染。不混进正文：正文只取 text 块，
    /// 把推理当正文会让用户看到模型的思考被当成最终回答。
    ///
    /// 契约标注 `reasoning-delta` 属**源码级**（本轮回环模型未产出推理），因此这里
    /// 按形状接收、认不出就跳过，不声称已实测。
    static func liveReasoningEvent(
        text: String,
        attempt: HarnessJournalAttempt,
        sessionID: SessionID
    ) -> AgentEvent? {
        guard !text.isEmpty else { return nil }
        let id = messageID(attempt: attempt, suffix: "reasoning")
        return .processItemCompleted(
            AgentMessage(
                id: id,
                sessionID: sessionID,
                itemID: id,
                role: .system,
                kind: .reasoningSummary,
                content: text,
                activityPayload: ConversationActivityPayload(
                    category: .thinking,
                    displayTitle: L10n.text("harness.thinking_title"),
                    status: "running"
                ),
                revision: attempt.lastRevision,
                sendStatus: .confirmed
            ),
            nil,
            metadata(
                seq: nil,
                sessionID: sessionID,
                itemID: id,
                messageID: id,
                revision: attempt.lastRevision
            )
        )
    }

    /// 投影一轮活动 attempt 的收尾。
    ///
    /// `producedAssistantMessage == false` 时**不产出 messageCompleted**：
    /// 被用户取消的 attempt（`eventType == assistant/attempt`）没有完整正文，
    /// 把它当成一条助手消息会让用户看到半截内容被标记为"完成"。
    /// 这是契约 §2.7 那条"committed 不等于有正文"在展示层的落点。
    static func project(
        attempt: HarnessJournalAttempt,
        sessionID: SessionID,
        assistantMessageID: MessageID? = nil
    ) -> [AgentEvent] {
        guard attempt.isSettled else { return [] }
        var events: [AgentEvent] = []
        if attempt.wasSuperseded {
            // 未结算就被下一条取代：输出被中断。如实告知，不假装完成。
            events.append(.warning(
                AgentErrorPayload(message: L10n.text("harness.attempt_superseded"),
                                  code: "harness/attempt-superseded", retryable: false),
                metadata(seq: attempt.settledSeq, sessionID: sessionID)
            ))
        }
        if attempt.producedAssistantMessage {
            let text = assistantText(from: attempt)
            if !text.isEmpty {
                let resolvedMessageID = assistantMessageID
                    ?? messageID(attempt: attempt, suffix: "assistant")
                events.append(.messageCompleted(
                    AgentMessage(
                        id: resolvedMessageID,
                        sessionID: sessionID,
                        itemID: attempt.attemptID,
                        role: .assistant,
                        content: text,
                        seq: attempt.settledSeq.map(EventSequence.init),
                        sendStatus: .confirmed
                    ),
                    metadata(
                        seq: nil,
                        sessionID: sessionID,
                        itemID: resolvedMessageID,
                        messageID: resolvedMessageID,
                        revision: attempt.lastRevision
                    )
                ))
            }
        }
        return events
    }

    /// 把一个已确认接收的文本 chunk 立即交给既有 UI 增量通道。
    /// messageID 与收尾、durable 回显共用 attempt 身份，避免生成第二条气泡。
    static func liveTextEvent(
        text: String,
        attempt: HarnessJournalAttempt,
        sessionID: SessionID
    ) -> AgentEvent? {
        guard !text.isEmpty else { return nil }
        let id = messageID(attempt: attempt, suffix: "assistant")
        return .assistantDelta(
            AgentDelta(text: text, role: .assistant, kind: .message),
            metadata(
                seq: nil,
                sessionID: sessionID,
                itemID: id,
                messageID: id,
                revision: attempt.lastRevision
            )
        )
    }

    /// 从 attempt 的帧序列拼出助手正文。
    ///
    /// 文本块按 `text-delta` 累积——**不能等 `block-end` 才渲染**（契约 §2.7：
    /// 文本块必须先累积）。这里做的是终态拼接：把全部 delta 连起来。
    /// 实时更新由 `HarnessSessionWebSocketClient` 逐帧下发，两者共用同一个累积规则。
    static func assistantText(from attempt: HarnessJournalAttempt) -> String {
        var out = ""
        for frame in attempt.chunks {
            guard let chunk = frame.chunk else { continue }
            if chunk.type == HarnessWireChunkType.textDelta, let text = chunk.text {
                out += text
            }
        }
        return out
    }

    // MARK: - 单类投影

    private static func projectUserMessage(_ event: HarnessDurableEvent, sessionID: SessionID) -> [AgentEvent] {
        guard let text = messageText(from: event), !text.isEmpty else { return [] }
        // user/message 也承载 plugin、skill-catalog 等注入上下文。只有 source.kind=user
        // 才是人真正提交的输入；未知扩展来源按上下文处理，避免伪造成用户发言。
        guard event.data?["source"]?["kind"]?.stringValue == "user" else {
            return projectSystemMessage(event, sessionID: sessionID)
        }
        return [.messageCompleted(
            AgentMessage(
                id: stableMessageID(for: event, prefix: "user") ?? "h-seq-\(event.seq ?? -1)-user",
                sessionID: sessionID,
                // 契约 D4：durable user/message.source.rpcId 就是提交的 requestId。
                // 把它带出来，上层才能把乐观记录与真实回显对上。
                clientMessageID: sourceRPCID(from: event),
                role: .user,
                content: text,
                seq: event.seq.map(EventSequence.init),
                sendStatus: .confirmed
            ),
            metadata(event, sessionID: sessionID)
        )]
    }

    private static func projectAssistantMessage(
        _ event: HarnessDurableEvent,
        sessionID: SessionID,
        messageID: MessageID?
    ) -> [AgentEvent] {
        guard let text = messageText(from: event), !text.isEmpty else { return [] }
        // 优先用上游原生消息 id：历史与直播都拿得到它，因此两条路径算出同一个 id。
        // `messageID` 是实时结算时从 attempt 反查出来的（同代次的强关联），优先于它。
        guard let id = messageID ?? stableMessageID(for: event, prefix: "assistant") else {
            return []
        }
        return [.messageCompleted(
            AgentMessage(
                id: id,
                sessionID: sessionID,
                role: .assistant,
                content: text,
                seq: event.seq.map(EventSequence.init),
                sendStatus: .confirmed
            ),
            metadata(
                seq: event.seq,
                sessionID: sessionID,
                itemID: id,
                messageID: id
            )
        )]
    }

    private static func projectSystemMessage(_ event: HarnessDurableEvent, sessionID: SessionID) -> [AgentEvent] {
        guard let text = messageText(from: event), !text.isEmpty else { return [] }
        // 注入上下文用 `context` kind 而不是 user：它不该在时间线上长得像用户说的话。
        return [.messageCompleted(
            AgentMessage(
                id: stableMessageID(for: event, prefix: "context") ?? "h-seq-\(event.seq ?? -1)-context",
                sessionID: sessionID,
                role: .system,
                kind: .context,
                content: text,
                seq: event.seq.map(EventSequence.init),
                sendStatus: .confirmed
            ),
            metadata(event, sessionID: sessionID)
        )]
    }

    // MARK: - 解析辅助

    /// 从事件的 data 里取正文。
    ///
    /// 真实形状（实测 `assistant/message`）：`data.message.content` 是块数组，
    /// 文本块形如 `{"type":"text","text":"..."}`；`reasoning` 块不是正文。
    /// 这里**只取 text 块**，reasoning 不混进正文（它是"可展示推理"，独立通道）。
    private static func messageText(from event: HarnessDurableEvent) -> String? {
        let data = event.data
        // 直接是 content 数组（user/message 的常见形态）
        if let content = data?["content"]?.arrayValue {
            return textFromBlocks(content)
        }
        // 包在 message 里（assistant/message）
        if let content = data?["message"]?["content"]?.arrayValue {
            return textFromBlocks(content)
        }
        // 纯文本字段
        if let text = data?["text"]?.stringValue { return text }
        return nil
    }

    private static func textFromBlocks(_ blocks: [HarnessJSONValue]) -> String {
        var out = ""
        for block in blocks {
            guard block["type"]?.stringValue == "text",
                  let text = block["text"]?.stringValue else { continue }
            out += text
        }
        return out
    }

    /// 取 `data.source.rpcId`（契约 D4 的提交对账键）。
    private static func sourceRPCID(from event: HarnessDurableEvent) -> ClientMessageID? {
        guard let value = event.data?["source"]?["rpcId"]?.stringValue,
              !value.isEmpty else { return nil }
        return ClientMessageID(value)
    }

    /// 由 durable 事件构造 metadata，**带上原生轮次身份**。
    ///
    /// 轮次是所有 turn 相关事件（开始、过程条目、结束）共用的身份；
    /// 丢掉它，Store 就不知道当前有哪一轮在跑，停止入口拿不到目标。
    private static func metadata(_ event: HarnessDurableEvent, sessionID: SessionID) -> AgentEventMetadata {
        metadata(
            seq: event.seq,
            sessionID: sessionID,
            turnID: turnIdentity(from: event)
        )
    }

    private static func metadata(
        seq: Int?,
        sessionID: SessionID,
        itemID: AgentItemID? = nil,
        messageID: MessageID? = nil,
        revision: ModelRevision? = nil,
        turnID: TurnID? = nil
    ) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: seq.map(EventSequence.init),
            sessionID: sessionID,
            turnID: turnID,
            itemID: itemID,
            messageID: messageID,
            clientMessageID: nil,
            revision: revision,
            createdAt: nil
        )
    }

    /// durable 事件里的原生轮次身份。
    ///
    /// Harness 的 `turn` 是数字（契约 §1.7），而共用状态层用的是字符串 TurnID。
    /// 必须在这一层稳定映射：`EventReducer` 只在 `.turnStarted` 的 metadata 带 turnID
    /// 时才更新活动轮次，UI 的停止入口又要求 `session.activeTurnID` 存在——
    /// 丢掉它，用户点停止时根本进不到 `sendCtrlC(expectedTurnID:)` 的校验，
    /// journal 里再准确的轮次判断也没有入口。
    ///
    /// 前缀与 `HarnessSessionWebSocketClient.currentKnownTurnID()` 保持一致，
    /// 确保"UI 认为的活动轮次"与"停止校验用的轮次"是同一个值。
    static func turnIdentity(from event: HarnessDurableEvent) -> TurnID? {
        guard let turn = event.data?["turn"]?.intValue else { return nil }
        return "h-turn-\(turn)"
    }

    static func messageID(attempt: HarnessJournalAttempt, suffix: String) -> MessageID {
        // 用原生身份（attemptId）派生展示 id：同一 attempt 的历史与直播算出同一个 id，
        // 因此"流式到历史"时不会产生第二条气泡。
        if let attemptID = attempt.attemptID, !attemptID.isEmpty {
            return "h-attempt-\(attemptID)-\(suffix)"
        }
        return "h-attempt-seq-\(attempt.settledSeq ?? -1)-\(suffix)"
    }
}

/// 一次工具事件的可展示描述。历史与实时共用它，避免两边对同一件事给出不同解释。
struct HarnessToolEntry: Equatable {
    let id: MessageID
    let toolName: String?
    /// running / completed / failed。
    let status: String
    let seq: Int?

    var displayTitle: String {
        toolName ?? L10n.text("harness.tool_activity_title")
    }

    var activityPayload: ConversationActivityPayload {
        ConversationActivityPayload(
            category: .toolCall,
            displayTitle: displayTitle,
            status: status,
            toolName: toolName,
            // 参数是模型生成的字符串，只作过程详情，不拿它拼标题——
            // 那会把用户数据带进时间线。
            toolPresentationKind: .generic
        )
    }
}

/// durable 事件类型词表。取自实测（`stream/durable-events.json` 的 `eventTypesObserved`），
/// 加上 `docs/deepseek-harness-protocol.md` 记录的 `tool/call` / `tool/result`。
///
/// 后两者在冻结夹具的实测清单里没有出现（本轮回环模型未跑真实工具），属**源码级**：
/// 按文档形状接收，认不出就跳过，不声称已实测。
enum HarnessWireEventType {
    static let turnStart = "turn/start"
    static let turnEnd = "turn/end"
    static let stepStart = "step/start"
    static let stepEnd = "step/end"
    static let userMessage = "user/message"
    static let assistantMessage = "assistant/message"
    static let systemMessage = "system/message"
    /// 工具调用：`{callId, name, arguments(字符串), step, turn}`。
    static let toolCall = "tool/call"
    /// 工具结果：`{message:{id,role,content[]}, meta:{...}, step, turn}`。
    static let toolResult = "tool/result"
}
