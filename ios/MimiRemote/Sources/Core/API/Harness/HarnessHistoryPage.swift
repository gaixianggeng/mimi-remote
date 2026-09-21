import Foundation

/// 原生历史页（`session/page`）的读取与投影。
///
/// ## throughSeq 为什么必须来自本次 follow
///
/// `session/page` 的 `throughSeq` 是**这一代** follow 打开帧 `cursor` 的闭区间切点。
/// 契约 §5.5 的实测：传 `0` 只读到 seq 0 一条，传一个远超当前 cursor 的值返回**空
/// records**，只有回传真实 cursor 才读到完整记录。所以历史读取在 follow 之前不可能
/// 发生，也不能拿别的代的游标充数——那会静默给出错误结果而不是报错。
///
/// ## 与 Store 的游标口径
///
/// Store 侧的历史分页用的是**不透明字符串游标**（`previousCursor`），而原生说的是
/// 整数 seq。两者之间的桥接只在这里做一次：把「更早的 seq」编码成游标字符串、
/// 再解回来。反过来在 Store 里各写一份必然漂移。
enum HarnessHistoryPageDecoding {

    /// Store 侧游标同时绑定读取边界与本次 opening snapshot。
    ///
    /// 只编码 `beforeSeq` 会让一次旧分页在新的 authoritative refresh 后继续复用新
    /// `throughSeq`，把两个快照上下文拼成一页。`contextID` 是客户端进程内的不透明
    /// 读取代次，只用于拒绝这种混用，不发给 Harness。
    struct Cursor: Equatable {
        let contextID: UInt64
        let beforeSeq: Int
    }

    /// `session/page` 的结果。
    struct Page: Equatable {
        let records: [HarnessDurableEvent]
        let hasMore: Bool
    }

    /// 解出一页。**坏结构必须显式失败**，不能退化成"历史为空/已读完"。
    ///
    /// 不解出「下一页位置」：上游结果只有 `{records, hasMore}`，没有 `nextBeforeSeq`。
    /// 下一个位置由**已取回记录的最小 seq** 推出——这不是编造游标，而是从实际拿到的
    /// 数据里读出边界；没有任何记录时无法推进，调用方必须停下。
    ///
    /// 三种坏形状都会被如实拒绝：
    /// - `records` 不是数组（例如返回了对象）：`arrayValue` 为 nil 时旧写法会 `?? []`
    ///   得到空页，调用方再因为"没有下一页游标"而停下——协议错误被伪装成了正常读完。
    /// - 某条记录缺 `event`：那一条的正文会静默消失，而分页游标仍按它推进。
    /// - `hasMore` 缺失或不是布尔：无法判断终止条件。
    ///
    /// 保留已有内容由调用方负责（它持有上一页），这里只保证"不假装成功"。
    static func page(from value: HarnessJSONValue) throws -> Page {
        guard let hasMore = value["hasMore"]?.boolValue else {
            throw HarnessTransportError.malformedResponse("session/page result is missing hasMore")
        }
        guard let rawRecords = value["records"] else {
            throw HarnessTransportError.malformedResponse("session/page result is missing records")
        }
        // 必须真的是数组：对象/字符串/数字都不是合法的 records 容器。
        guard let entries = rawRecords.arrayValue else {
            throw HarnessTransportError.malformedResponse(
                "session/page records is not an array"
            )
        }
        let decoded = try entries.map { entry -> HarnessDurableEvent in
            // 每条都必须是带 event 的记录对象。缺一条就失败——静默跳过会让
            // 用户看不到那段正文，而界面上没有任何异常迹象。
            guard let rawEvent = entry["event"] else {
                throw HarnessTransportError.malformedResponse(
                    "session/page record is missing its event"
                )
            }
            let event = try decode(HarnessDurableEvent.self, from: rawEvent, label: "session/page record")
            guard event.seq != nil else {
                // 没有 seq 就没有分页位置，也没有稳定身份。收下它会让游标推进不了，
                // 表现为"同一页反复返回"或"历史提前结束"。
                throw HarnessTransportError.malformedResponse(
                    "session/page record is missing its seq"
                )
            }
            return event
        }
        return Page(records: decoded, hasMore: hasMore)
    }

    /// 把「更早于 seq」编码成 Store 用的不透明游标。
    ///
    /// 前缀让原生游标与其它 runtime 的游标不可能混淆：拿到一个非本前缀的游标说明
    /// 请求跨了 runtime，这里显式拒绝而不是当成同一个空间。
    static let cursorPrefix = "hseq:"

    static func cursor(before seq: Int, contextID: UInt64) -> String {
        "\(cursorPrefix)\(contextID):\(seq)"
    }

    static func cursor(from value: String?) throws -> Cursor? {
        guard let cursor = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cursor.isEmpty else {
            return nil
        }
        guard cursor.hasPrefix(cursorPrefix) else {
            throw HarnessTransportError.malformedResponse(
                "history cursor does not belong to the native Harness path: \(cursor)"
            )
        }
        let components = cursor.dropFirst(cursorPrefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let contextID = UInt64(components[0]),
              let beforeSeq = Int(components[1]) else {
            throw HarnessTransportError.malformedResponse("history cursor is malformed: \(cursor)")
        }
        return Cursor(contextID: contextID, beforeSeq: beforeSeq)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from value: HarnessJSONValue,
        label: String
    ) throws -> T {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HarnessTransportError.malformedResponse("\(label) is invalid: \(error)")
        }
    }
}

/// 原生持久记录 → 既有 `CodexHistoryMessage` 的投影。
///
/// 与实时投影（`HarnessPresentationProjector`）刻意分工：那边产出 `AgentEvent` 供
/// Store 增量消费，这边把**一页**记录变成历史快照。两者共用同一套身份规则
/// （`harnessMessageID`），否则"同一轮在历史里和直播里是两个气泡"。
enum HarnessHistoryProjection {

    /// 一页记录投影出的历史消息。只保留可展示的记录：
    /// 认不出的类型不猜（与实时投影同一原则）。
    static func messages(
        from records: [HarnessDurableEvent],
        sessionID: SessionID,
        assistantMessageID: ((HarnessDurableEvent) -> MessageID?)? = nil
    ) -> [CodexHistoryMessage] {
        var messages: [CodexHistoryMessage] = []
        var toolIndexByID: [MessageID: Int] = [:]
        for event in records {
            guard let projected = message(
                from: event,
                sessionID: sessionID,
                assistantMessageID: assistantMessageID?(event)
            ) else { continue }
            guard projected.activityPayload?.category == .toolCall else {
                messages.append(projected)
                continue
            }
            if let index = toolIndexByID[projected.id] {
                messages[index] = mergedToolMessage(messages[index], projected)
            } else {
                toolIndexByID[projected.id] = messages.count
                messages.append(projected)
            }
        }
        return messages
    }

    private static func message(
        from event: HarnessDurableEvent,
        sessionID: SessionID,
        assistantMessageID: MessageID?
    ) -> CodexHistoryMessage? {
        switch event.type {
        case HarnessWireEventType.userMessage:
            // 与实时投影一致：user/message 也承载 Harness 注入上下文。
            return event.data?["source"]?["kind"]?.stringValue == "user"
                ? userMessage(event, sessionID: sessionID)
                : systemMessage(event, sessionID: sessionID)
        case HarnessWireEventType.assistantMessage:
            return assistantMessage(
                event,
                sessionID: sessionID,
                messageID: assistantMessageID
            )
        case HarnessWireEventType.systemMessage:
            return systemMessage(event, sessionID: sessionID)
        case HarnessWireEventType.toolCall, HarnessWireEventType.toolResult:
            return toolMessage(event, sessionID: sessionID)
        default:
            // 步骤边界、权限预设、注入上下文等不单独展示：它们没有独立可读内容，
            // 展示出来只是噪声（与实时投影同一取舍）。
            return nil
        }
    }

    /// 工具条目走**与实时投影同一个解释**（`HarnessPresentationProjector.toolEntry`）。
    ///
    /// 历史若跳过它们，用户重新打开会话就会发现过程条目消失——同一轮对话
    /// "看着有、重开没有"。两处各写一份解释必然漂移，所以这里只做形式适配
    /// （产出 `CodexHistoryMessage` 而不是 `AgentEvent`），判断逻辑共用。
    private static func toolMessage(
        _ event: HarnessDurableEvent,
        sessionID: SessionID
    ) -> CodexHistoryMessage? {
        guard let entry = HarnessPresentationProjector.toolEntry(from: event) else { return nil }
        return CodexHistoryMessage(
            id: entry.id,
            role: "system",
            kind: .commandSummary,
            content: entry.displayTitle,
            activityPayload: entry.activityPayload,
            createdAt: date(from: event),
            seq: entry.seq.map { EventSequence($0) },
            sendStatus: .confirmed
        )
    }

    /// 同一 callId 的 `tool/call` 与 `tool/result` 是一个过程条目。
    ///
    /// 结果事件的 seq 更大，但经常不再携带工具名；因此状态与时间取较新的原生事件，
    /// 名称沿用两条事件中已知的值。这样历史投影在进入通用 reducer 前就已收敛，
    /// 不会因为 reducer 保留第一条而让完成的工具永远停在 running。
    static func mergedToolMessage(
        _ lhs: CodexHistoryMessage,
        _ rhs: CodexHistoryMessage
    ) -> CodexHistoryMessage {
        let newer: CodexHistoryMessage
        let older: CodexHistoryMessage
        if (rhs.seq ?? .min) >= (lhs.seq ?? .min) {
            newer = rhs
            older = lhs
        } else {
            newer = lhs
            older = rhs
        }
        guard let newerPayload = newer.activityPayload else { return newer }
        let olderPayload = older.activityPayload
        let toolName = newerPayload.toolName ?? olderPayload?.toolName
        let title = toolName ?? newerPayload.displayTitle
        return CodexHistoryMessage(
            id: newer.id,
            role: newer.role,
            kind: newer.kind,
            content: title,
            activityPayload: ConversationActivityPayload(
                category: newerPayload.category,
                displayTitle: title,
                subtitle: newerPayload.subtitle ?? olderPayload?.subtitle,
                status: newerPayload.status,
                command: newerPayload.command ?? olderPayload?.command,
                cwd: newerPayload.cwd ?? olderPayload?.cwd,
                toolName: toolName,
                filePaths: newerPayload.filePaths.isEmpty
                    ? (olderPayload?.filePaths ?? [])
                    : newerPayload.filePaths,
                exitCode: newerPayload.exitCode ?? olderPayload?.exitCode,
                outputPreview: newerPayload.outputPreview ?? olderPayload?.outputPreview,
                outputDigest: newerPayload.outputDigest ?? olderPayload?.outputDigest,
                outputByteCount: newerPayload.outputByteCount ?? olderPayload?.outputByteCount,
                historyOutputID: newerPayload.historyOutputID ?? olderPayload?.historyOutputID,
                commandPresentationKind: newerPayload.commandPresentationKind
                    ?? olderPayload?.commandPresentationKind,
                toolPresentationKind: newerPayload.toolPresentationKind
                    ?? olderPayload?.toolPresentationKind
            ),
            createdAt: newer.createdAt ?? older.createdAt,
            updatedAt: newer.updatedAt ?? older.updatedAt,
            seq: newer.seq,
            sendStatus: newer.sendStatus
        )
    }

    private static func userMessage(
        _ event: HarnessDurableEvent,
        sessionID: SessionID
    ) -> CodexHistoryMessage? {
        guard let text = messageText(from: event), !text.isEmpty else { return nil }
        // `source.rpcId` 是提交时的 requestId，带上它上层才能把乐观记录与真实回显对上。
        // 没有稳定身份就不展示：编一个 id 会让同一条消息在时间线上出现两次。
        guard let id = stableID(prefix: "user", event: event) else { return nil }
        let rpcID = event.data?["source"]?["rpcId"]?.stringValue
        return CodexHistoryMessage(
            id: id,
            role: "user",
            content: text,
            createdAt: date(from: event),
            clientMessageID: rpcID.map { ClientMessageID($0) },
            seq: event.seq.map { EventSequence($0) }
        )
    }

    private static func assistantMessage(
        _ event: HarnessDurableEvent,
        sessionID: SessionID,
        messageID: MessageID?
    ) -> CodexHistoryMessage? {
        guard let text = messageText(from: event), !text.isEmpty,
              let id = messageID ?? stableID(prefix: "assistant", event: event) else { return nil }
        return CodexHistoryMessage(
            id: id,
            role: "assistant",
            content: text,
            createdAt: date(from: event),
            seq: event.seq.map(EventSequence.init)
        )
    }

    private static func systemMessage(
        _ event: HarnessDurableEvent,
        sessionID: SessionID
    ) -> CodexHistoryMessage? {
        guard let text = messageText(from: event), !text.isEmpty,
              let id = stableID(prefix: "context", event: event) else { return nil }
        // 注入上下文用 `context` kind，不在时间线上长得像用户说的话。
        return CodexHistoryMessage(
            id: id,
            role: "system",
            kind: .context,
            content: text,
            createdAt: date(from: event),
            seq: event.seq.map(EventSequence.init)
        )
    }

    /// 历史与直播共用的身份。**规则只有一处**（见
    /// `HarnessPresentationProjector.stableMessageID`）：两处各写一份，
    /// 历史与直播就会各自算出不同的 id，同一条消息在时间线上出现两次。
    static func stableID(prefix: String, event: HarnessDurableEvent) -> MessageID? {
        HarnessPresentationProjector.stableMessageID(for: event, prefix: prefix)
    }

    /// 从事件的 data 取正文。只取 text 块，reasoning 不混进正文。
    static func messageText(from event: HarnessDurableEvent) -> String? {
        let data = event.data
        if let content = data?["content"]?.arrayValue {
            return textFromBlocks(content)
        }
        if let content = data?["message"]?["content"]?.arrayValue {
            return textFromBlocks(content)
        }
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

    /// `time` 是毫秒（契约 §2.4：`updatedAt` 与 `time` 都是毫秒）。
    private static func date(from event: HarnessDurableEvent) -> Date? {
        guard let milliseconds = event.time else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
