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

    /// 一条持久记录投影出的展示事件。
    ///
    /// 返回数组而不是单值：一条记录可能产生不止一个展示事件（例如同时更新正文与时间线），
    /// 也可能产生零个（未知类型）。
    static func project(durableEvent event: HarnessDurableEvent, sessionID: SessionID) -> [AgentEvent] {
        guard let type = event.type else { return [] }
        switch type {
        case HarnessWireEventType.turnStart:
            return [.turnStarted(metadata(event, sessionID: sessionID))]
        case HarnessWireEventType.turnEnd:
            return [.turnCompleted(metadata(event, sessionID: sessionID))]
        case HarnessWireEventType.userMessage:
            return projectUserMessage(event, sessionID: sessionID)
        case HarnessWireEventType.assistantMessage:
            return projectAssistantMessage(event, sessionID: sessionID)
        case HarnessWireEventType.systemMessage:
            return projectSystemMessage(event, sessionID: sessionID)
        case HarnessWireEventType.stepStart, HarnessWireEventType.stepEnd:
            // 步骤边界不单独展示：它们没有独立可读内容，展示出来只是噪声。
            // 进度感由 assistant-stream 的正文/工具活动提供。
            return []
        default:
            // 认不出的类型不猜。保留诊断由上层决定，这里不产出展示事件。
            return []
        }
    }

    /// 投影一轮活动 attempt 的收尾。
    ///
    /// `producedAssistantMessage == false` 时**不产出 messageCompleted**：
    /// 被用户取消的 attempt（`eventType == assistant/attempt`）没有完整正文，
    /// 把它当成一条助手消息会让用户看到半截内容被标记为"完成"。
    /// 这是契约 §2.7 那条"committed 不等于有正文"在展示层的落点。
    static func project(attempt: HarnessJournalAttempt, sessionID: SessionID) -> [AgentEvent] {
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
                events.append(.messageCompleted(
                    AgentMessage(
                        id: messageID(attempt: attempt, suffix: "assistant"),
                        sessionID: sessionID,
                        itemID: attempt.attemptID,
                        role: .assistant,
                        content: text,
                        seq: attempt.settledSeq.map(EventSequence.init),
                        sendStatus: .confirmed
                    ),
                    metadata(seq: attempt.settledSeq, sessionID: sessionID)
                ))
            }
        }
        return events
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

    /// 从 attempt 抽出的工具活动（供 UI 呈现"运行中/失败"）。
    ///
    /// 保持通用工具条目：不伪装成 shell command 或文件变更。
    static func toolActivities(from attempt: HarnessJournalAttempt) -> [HarnessToolActivity] {
        var activities: [HarnessToolActivity] = []
        var pendingByIndex: [Int: HarnessToolActivity] = [:]
        for frame in attempt.chunks {
            guard let chunk = frame.chunk else { continue }
            switch chunk.type {
            case HarnessWireChunkType.blockStart where chunk.blockType == "tool-call":
                let index = chunk.index ?? -1
                pendingByIndex[index] = HarnessToolActivity(
                    blockIndex: index, toolName: nil, argumentsJSON: "", isComplete: false
                )
            case HarnessWireChunkType.toolCallDelta:
                let index = chunk.index ?? -1
                var item = pendingByIndex[index] ?? HarnessToolActivity(
                    blockIndex: index, toolName: nil, argumentsJSON: "", isComplete: false
                )
                // 工具参数是增量字符串，必须自行拼接后再解析（契约 §2.7）。
                if let delta = chunk.argumentsDelta { item.argumentsJSON += delta }
                pendingByIndex[index] = item
            case HarnessWireChunkType.blockEnd:
                let index = chunk.index ?? -1
                if var item = pendingByIndex[index] {
                    item.isComplete = true
                    activities.append(item)
                    pendingByIndex[index] = nil
                }
            default:
                continue
            }
        }
        // 未收到 block-end 的（例如 attempt 被中断）也要如实给出，标记为未完成。
        activities.append(contentsOf: pendingByIndex.values.sorted { $0.blockIndex < $1.blockIndex })
        return activities.sorted { $0.blockIndex < $1.blockIndex }
    }

    // MARK: - 单类投影

    private static func projectUserMessage(_ event: HarnessDurableEvent, sessionID: SessionID) -> [AgentEvent] {
        guard let text = messageText(from: event), !text.isEmpty else { return [] }
        return [.messageCompleted(
            AgentMessage(
                id: "h-seq-\(event.seq ?? -1)-user",
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

    private static func projectAssistantMessage(_ event: HarnessDurableEvent, sessionID: SessionID) -> [AgentEvent] {
        guard let text = messageText(from: event), !text.isEmpty else { return [] }
        return [.messageCompleted(
            AgentMessage(
                id: "h-seq-\(event.seq ?? -1)-assistant",
                sessionID: sessionID,
                role: .assistant,
                content: text,
                seq: event.seq.map(EventSequence.init),
                sendStatus: .confirmed
            ),
            metadata(event, sessionID: sessionID)
        )]
    }

    private static func projectSystemMessage(_ event: HarnessDurableEvent, sessionID: SessionID) -> [AgentEvent] {
        guard let text = messageText(from: event), !text.isEmpty else { return [] }
        // 注入上下文用 `context` kind 而不是 user：它不该在时间线上长得像用户说的话。
        return [.messageCompleted(
            AgentMessage(
                id: "h-seq-\(event.seq ?? -1)-context",
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

    /// 取 `message.source.rpcId`（契约 D4 的提交对账键）。
    private static func sourceRPCID(from event: HarnessDurableEvent) -> ClientMessageID? {
        guard let value = event.data?["message"]?["source"]?["rpcId"]?.stringValue,
              !value.isEmpty else { return nil }
        return ClientMessageID(value)
    }

    private static func metadata(_ event: HarnessDurableEvent, sessionID: SessionID) -> AgentEventMetadata {
        metadata(seq: event.seq, sessionID: sessionID)
    }

    private static func metadata(seq: Int?, sessionID: SessionID) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: seq.map(EventSequence.init),
            sessionID: sessionID,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )
    }

    private static func messageID(attempt: HarnessJournalAttempt, suffix: String) -> MessageID {
        // 用原生身份（attemptId）派生展示 id：同一 attempt 的历史与直播算出同一个 id，
        // 因此"流式到历史"时不会产生第二条气泡。
        if let attemptID = attempt.attemptID, !attemptID.isEmpty {
            return "h-attempt-\(attemptID)-\(suffix)"
        }
        return "h-attempt-seq-\(attempt.settledSeq ?? -1)-\(suffix)"
    }
}

/// 一条原生工具活动。刻意保持通用形状，不伪装成 shell/文件变更。
struct HarnessToolActivity: Equatable {
    let blockIndex: Int
    var toolName: String?
    var argumentsJSON: String
    var isComplete: Bool
}

/// durable 事件类型词表。取自实测（`stream/durable-events.json` 的 `eventTypesObserved`），
/// 只登记本层会投影的那几个——其余保持"认不出就跳过"，不在这里穷举。
enum HarnessWireEventType {
    static let turnStart = "turn/start"
    static let turnEnd = "turn/end"
    static let stepStart = "step/start"
    static let stepEnd = "step/end"
    static let userMessage = "user/message"
    static let assistantMessage = "assistant/message"
    static let systemMessage = "system/message"
}
