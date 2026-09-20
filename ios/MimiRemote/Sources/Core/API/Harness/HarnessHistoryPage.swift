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

    /// `session/page` 的结果。
    struct Page: Equatable {
        let records: [HarnessDurableEvent]
        let hasMore: Bool
    }

    /// 不解出「下一页位置」：上游结果只有 `{records, hasMore}`，没有 `nextBeforeSeq`。
    /// 下一个位置由**已取回记录的最小 seq** 推出——这不是编造游标，而是从实际拿到的
    /// 数据里读出边界；没有任何记录时无法推进，调用方必须停下。
    static func page(from value: HarnessJSONValue) throws -> Page {
        guard let hasMore = value["hasMore"]?.boolValue else {
            throw HarnessTransportError.malformedResponse("session/page result is missing hasMore")
        }
        guard let rawRecords = value["records"] else {
            throw HarnessTransportError.malformedResponse("session/page result is missing records")
        }
        let records = rawRecords.arrayValue?.compactMap { $0["event"] } ?? []
        let decoded = try records.map { raw -> HarnessDurableEvent in
            try decode(HarnessDurableEvent.self, from: raw, label: "session/page record")
        }
        return Page(records: decoded, hasMore: hasMore)
    }

    /// 把「更早于 seq」编码成 Store 用的不透明游标。
    ///
    /// 前缀让原生游标与其它 runtime 的游标不可能混淆：拿到一个非本前缀的游标说明
    /// 请求跨了 runtime，这里显式拒绝而不是当成同一个空间。
    static let cursorPrefix = "hseq:"

    static func cursor(before seq: Int) -> String {
        "\(cursorPrefix)\(seq)"
    }

    static func seq(fromCursor cursor: String?) throws -> Int? {
        guard let cursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cursor.isEmpty else {
            return nil
        }
        guard cursor.hasPrefix(cursorPrefix) else {
            throw HarnessTransportError.malformedResponse(
                "history cursor does not belong to the native Harness path: \(cursor)"
            )
        }
        guard let seq = Int(cursor.dropFirst(cursorPrefix.count)) else {
            throw HarnessTransportError.malformedResponse("history cursor is malformed: \(cursor)")
        }
        return seq
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
        sessionID: SessionID
    ) -> [CodexHistoryMessage] {
        records.compactMap { message(from: $0, sessionID: sessionID) }
    }

    private static func message(
        from event: HarnessDurableEvent,
        sessionID: SessionID
    ) -> CodexHistoryMessage? {
        switch event.type {
        case HarnessWireEventType.userMessage:
            return userMessage(event, sessionID: sessionID)
        case HarnessWireEventType.assistantMessage:
            return assistantMessage(event, sessionID: sessionID)
        case HarnessWireEventType.systemMessage:
            return systemMessage(event, sessionID: sessionID)
        default:
            // 步骤边界、权限预设、注入上下文等不单独展示：它们没有独立可读内容，
            // 展示出来只是噪声（与实时投影同一取舍）。
            return nil
        }
    }

    private static func userMessage(
        _ event: HarnessDurableEvent,
        sessionID: SessionID
    ) -> CodexHistoryMessage? {
        guard let text = messageText(from: event), !text.isEmpty else { return nil }
        // `user/message` 也承载 plugin、skill-catalog 等注入上下文。只有 source.kind=user
        // 才是人真正提交的输入。
        guard event.data?["source"]?["kind"]?.stringValue == "user" else { return nil }
        // `source.rpcId` 是提交时的 requestId，带上它上层才能把乐观记录与真实回显对上。
        let rpcID = event.data?["source"]?["rpcId"]?.stringValue
        return CodexHistoryMessage(
            id: stableID(prefix: "user", event: event),
            role: "user",
            content: text,
            createdAt: date(from: event),
            clientMessageID: rpcID.map { ClientMessageID($0) },
            seq: event.seq.map { EventSequence($0) }
        )
    }

    private static func assistantMessage(
        _ event: HarnessDurableEvent,
        sessionID: SessionID
    ) -> CodexHistoryMessage? {
        guard let text = messageText(from: event), !text.isEmpty else { return nil }
        return CodexHistoryMessage(
            id: stableID(prefix: "assistant", event: event),
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
        guard let text = messageText(from: event), !text.isEmpty else { return nil }
        // 注入上下文用 `context` kind，不在时间线上长得像用户说的话。
        return CodexHistoryMessage(
            id: stableID(prefix: "context", event: event),
            role: "system",
            kind: .context,
            content: text,
            createdAt: date(from: event),
            seq: event.seq.map(EventSequence.init)
        )
    }

    /// 历史与直播共用的身份：以原生 seq 为准。
    ///
    /// seq 是持久日志主键，因此无论走历史页还是流式，同一条记录算出的 id 相同——
    /// 这正是"历史与直播不产生重复气泡"的依据。
    static func stableID(prefix: String, event: HarnessDurableEvent) -> MessageID {
        "h-seq-\(event.seq ?? -1)-\(prefix)"
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
