import Foundation

/// app-server 的内部用户记录不能进入用户气泡或历史标题。中断标记只按完整文本
/// 过滤，普通用户讨论该字符串时仍可正常展示；既有协议标签继续沿用前缀规则。
func isVisibleAppServerUserMessageText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "[Request interrupted by user]" else {
        return false
    }
    let hiddenPrefixes = [
        "<subagent_notification>",
        "<turn_aborted>",
        "<environment_context>",
        "<codex_internal_context>"
    ]
    return !hiddenPrefixes.contains { trimmed.hasPrefix($0) }
}

// Codex 0.146+ 会把 MCP 工具审批编码成一个空 schema 的 form elicitation。
// 必须依赖私有元数据精确识别，不能把所有空表单都当成审批，否则第三方 MCP 的普通表单会被误授权。
enum CodexMCPToolApprovalProtocol {
    static let kind = "mcp_tool"

    static func isToolCall(_ params: [String: CodexAppServerJSONValue]) -> Bool {
        params["_meta"]?.objectValue?["codex_approval_kind"]?.stringValue == "mcp_tool_call"
    }

    static func persistenceModes(_ params: [String: CodexAppServerJSONValue]) -> Set<String> {
        guard let value = params["_meta"]?.objectValue?["persist"] else {
            return []
        }
        if let mode = value.stringValue {
            return [mode]
        }
        return Set(value.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    static func availableDecisions(_ params: [String: CodexAppServerJSONValue]) -> [String] {
        let modes = persistenceModes(params)
        var decisions = ["accept"]
        if modes.contains("session") {
            decisions.append("acceptForSession")
        }
        if modes.contains("always") {
            decisions.append("acceptAlways")
        }
        decisions.append("decline")
        return decisions
    }
}

enum AgentEvent {
    case session(AgentSession)
    case sessionRow(DataFlowSessionRow, AgentEventMetadata)
    case sessionStatus(String?, AgentEventMetadata)
    case sessionContext(SessionContextSnapshot, AgentEventMetadata)
    case goalUpdated(ThreadGoal, AgentEventMetadata)
    case goalCleared(AgentEventMetadata)
    case turnStarted(AgentEventMetadata)
    case assistantDelta(AgentDelta, AgentEventMetadata)
    case messageCompleted(AgentMessage, AgentEventMetadata)
    case processItemCompleted(AgentMessage, SessionContextSnapshot?, AgentEventMetadata)
    case logDelta(LogDelta, AgentEventMetadata)
    case diffUpdated(FileChangeSummary, AgentEventMetadata)
    case approvalRequest(AgentApprovalRequest, AgentEventMetadata)
    case approvalResolved(AgentEventMetadata)
    case userInputRequest(AgentUserInputRequest, AgentEventMetadata)
    case userInputResolved(AgentEventMetadata, skipped: Bool)
    case turnCompleted(AgentEventMetadata)
    case warning(AgentErrorPayload, AgentEventMetadata)
    case error(AgentErrorPayload, AgentEventMetadata)
    case unknown(String)
}

extension AgentEvent {
    func withReplayBoundarySequence(_ sequence: UInt64?, epoch: UInt64?) -> AgentEvent {
        guard let sequence else { return self }
        switch self {
        case .session, .unknown:
            return self
        case .sessionRow(let row, let metadata):
            return .sessionRow(row, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .sessionStatus(let status, let metadata):
            return .sessionStatus(status, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .sessionContext(let context, let metadata):
            return .sessionContext(context, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .goalUpdated(let goal, let metadata):
            return .goalUpdated(goal, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .goalCleared(let metadata):
            return .goalCleared(metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .turnStarted(let metadata):
            return .turnStarted(metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .assistantDelta(let delta, let metadata):
            return .assistantDelta(delta, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .messageCompleted(let message, let metadata):
            return .messageCompleted(message, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .processItemCompleted(let message, let context, let metadata):
            return .processItemCompleted(message, context, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .logDelta(let delta, let metadata):
            return .logDelta(delta, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .diffUpdated(let diff, let metadata):
            return .diffUpdated(diff, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .approvalRequest(let request, let metadata):
            return .approvalRequest(request, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .approvalResolved(let metadata):
            return .approvalResolved(metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .userInputRequest(let request, let metadata):
            return .userInputRequest(request, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .userInputResolved(let metadata, let skipped):
            return .userInputResolved(metadata.withReplayBoundarySequence(sequence, epoch: epoch), skipped: skipped)
        case .turnCompleted(let metadata):
            return .turnCompleted(metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .warning(let warning, let metadata):
            return .warning(warning, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        case .error(let error, let metadata):
            return .error(error, metadata.withReplayBoundarySequence(sequence, epoch: epoch))
        }
    }

    var contiguousPayloadByteCount: Int? {
        switch self {
        case .assistantDelta(let delta, _):
            return delta.text.utf8.count
        case .logDelta(let delta, _):
            return delta.text.utf8.count
        default:
            return nil
        }
    }

    /// 只合并相邻且属于同一 item 的高频事件，保留控制事件边界和最终文本语义。
    func mergingContiguous(with next: AgentEvent) -> AgentEvent? {
        switch (self, next) {
        case let (.assistantDelta(previousDelta, previousMetadata), .assistantDelta(nextDelta, nextMetadata))
            where Self.sameItem(previousMetadata, nextMetadata)
                && previousDelta.role == nextDelta.role
                && previousDelta.kind == nextDelta.kind:
            var text = previousDelta.text
            text.append(contentsOf: nextDelta.text)
            return .assistantDelta(
                AgentDelta(text: text, role: nextDelta.role, kind: nextDelta.kind),
                nextMetadata
            )
        case let (.logDelta(previousDelta, previousMetadata), .logDelta(nextDelta, nextMetadata))
            where Self.sameItem(previousMetadata, nextMetadata)
                && previousDelta.stream == nextDelta.stream:
            var text = previousDelta.text
            text.append(contentsOf: nextDelta.text)
            return .logDelta(LogDelta(text: text, stream: nextDelta.stream), nextMetadata)
        case let (.messageCompleted(previousMessage, previousMetadata), .messageCompleted(nextMessage, nextMetadata))
            where previousMessage.role == .system
                && nextMessage.role == .system
                && previousMessage.kind == nextMessage.kind
                && (nextMessage.kind == .plan || nextMessage.kind == .reasoningSummary)
                && Self.sameItem(previousMetadata, nextMetadata):
            return .messageCompleted(nextMessage, nextMetadata)
        default:
            return nil
        }
    }

    private static func sameItem(_ lhs: AgentEventMetadata, _ rhs: AgentEventMetadata) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.turnID == rhs.turnID
            && lhs.itemID == rhs.itemID
            && lhs.messageID == rhs.messageID
    }
}

/// 面向单个会话订阅者的事件邮箱。消费者被 MainActor 阻塞时，只合并语义上连续的文本事件；
/// 审批、完成、错误等控制事件会成为硬边界并按原顺序保留。
final class CodexAppServerEventMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let onCancellation: @Sendable () -> Void
    private var pendingEvents: [AgentEvent] = []
    private var pendingHead = 0
    private var waiter: CheckedContinuation<AgentEvent?, Never>?
    private var producerFinished = false
    private var subscriberCancelled = false
    private var didNotifyCancellation = false

    init(onCancellation: @escaping @Sendable () -> Void) {
        self.onCancellation = onCancellation
    }

    func send(_ event: AgentEvent) {
        var waitingConsumer: CheckedContinuation<AgentEvent?, Never>?
        lock.lock()
        if !producerFinished, !subscriberCancelled {
            if let waiter {
                self.waiter = nil
                waitingConsumer = waiter
            } else {
                appendOrMerge(event)
            }
        }
        lock.unlock()
        waitingConsumer?.resume(returning: event)
    }

    func next() async -> AgentEvent? {
        if Task.isCancelled {
            cancel()
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var immediateEvent: AgentEvent?
                var shouldResumeImmediately = false

                lock.lock()
                if let event = popFirstPendingEvent() {
                    immediateEvent = event
                    shouldResumeImmediately = true
                } else if producerFinished || subscriberCancelled {
                    shouldResumeImmediately = true
                } else {
                    // 每个 stream 只允许一个 iterator；重复等待时优先结束旧等待，避免悬挂 continuation。
                    if let previousWaiter = waiter {
                        previousWaiter.resume(returning: nil)
                    }
                    waiter = continuation
                }
                lock.unlock()

                if shouldResumeImmediately {
                    continuation.resume(returning: immediateEvent)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// 上游结束后先排空已接收事件，再结束 for-await，行为与 AsyncStream.finish() 一致。
    func finishFromProducer() {
        var waitingConsumer: CheckedContinuation<AgentEvent?, Never>?
        lock.lock()
        guard !producerFinished else {
            lock.unlock()
            return
        }
        producerFinished = true
        if pendingHead >= pendingEvents.count {
            waitingConsumer = waiter
            waiter = nil
        }
        lock.unlock()
        waitingConsumer?.resume(returning: nil)
    }

    func cancel() {
        var waitingConsumer: CheckedContinuation<AgentEvent?, Never>?
        var shouldNotify = false
        lock.lock()
        if !subscriberCancelled {
            subscriberCancelled = true
            producerFinished = true
            pendingEvents.removeAll(keepingCapacity: false)
            pendingHead = 0
            waitingConsumer = waiter
            waiter = nil
        }
        if !didNotifyCancellation {
            didNotifyCancellation = true
            shouldNotify = true
        }
        lock.unlock()

        waitingConsumer?.resume(returning: nil)
        if shouldNotify {
            onCancellation()
        }
    }

    private func appendOrMerge(_ event: AgentEvent) {
        if event.contiguousPayloadByteCount == nil, pendingHead < pendingEvents.count {
            let lastIndex = pendingEvents.index(before: pendingEvents.endIndex)
            if let merged = pendingEvents[lastIndex].mergingContiguous(with: event) {
                // reasoning/plan 是累计快照，保留最新完整内容即可。
                pendingEvents[lastIndex] = merged
                return
            }
        }
        pendingEvents.append(event)
        compactTrailingTextChunks()
    }

    /// 用近似二进制分层合并保持 O(log n) 个文本 chunk，避免每个 token 都复制完整前缀形成 O(n²)。
    private func compactTrailingTextChunks() {
        while pendingEvents.count - pendingHead >= 2 {
            let previousIndex = pendingEvents.index(pendingEvents.endIndex, offsetBy: -2)
            let nextIndex = pendingEvents.index(before: pendingEvents.endIndex)
            let previous = pendingEvents[previousIndex]
            let next = pendingEvents[nextIndex]
            guard let previousBytes = previous.contiguousPayloadByteCount,
                  let nextBytes = next.contiguousPayloadByteCount,
                  previousBytes <= max(1, nextBytes) * 2,
                  let merged = previous.mergingContiguous(with: next)
            else {
                return
            }
            pendingEvents.removeLast(2)
            pendingEvents.append(merged)
        }
    }

    private func popFirstPendingEvent() -> AgentEvent? {
        guard pendingHead < pendingEvents.count else {
            return nil
        }
        var event = pendingEvents[pendingHead]
        pendingHead += 1
        // 分层 chunk 在交付前再做一次从大到小的线性归并，调用方仍只看到一个完整连续事件。
        while pendingHead < pendingEvents.count,
              let merged = event.mergingContiguous(with: pendingEvents[pendingHead]) {
            event = merged
            pendingHead += 1
        }
        if pendingHead == pendingEvents.count {
            pendingEvents.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead >= 64, pendingHead * 2 >= pendingEvents.count {
            pendingEvents.removeFirst(pendingHead)
            pendingHead = 0
        }
        return event
    }
}

private final class CodexAppServerEventStreamLease: @unchecked Sendable {
    let mailbox: CodexAppServerEventMailbox

    init(mailbox: CodexAppServerEventMailbox) {
        self.mailbox = mailbox
    }

    deinit {
        mailbox.cancel()
    }
}

/// 保持调用方原有 `for await` 用法，同时把排队策略从无界 AsyncStream 收敛到可合并邮箱。
struct CodexAppServerEventStream: AsyncSequence, Sendable {
    typealias Element = AgentEvent

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let lease: CodexAppServerEventStreamLease

        mutating func next() async -> AgentEvent? {
            await lease.mailbox.next()
        }
    }

    private let lease: CodexAppServerEventStreamLease

    init(mailbox: CodexAppServerEventMailbox) {
        lease = CodexAppServerEventStreamLease(mailbox: mailbox)
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(lease: lease)
    }

    func cancel() {
        lease.mailbox.cancel()
    }
}

extension AgentEvent: Decodable {
    enum CodingKeys: String, CodingKey {
        case type
        case data
        case session
        case row
        case delta
        case log
        case exit
        case error
        case warning
        case message
        case diff
        case approval
        case userInput = "user_input"
        case skipped
        case meta
        case seq
        case sessionID = "session_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case messageID = "message_id"
        case clientMessageID = "client_message_id"
        case revision
        case createdAt = "created_at"
        case status
        case context
        case goal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let metadata = try Self.decodeMetadata(from: container)
        switch type {
        case "session":
            self = .session(try container.decode(AgentSession.self, forKey: .session))
        case "session_row":
            if let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row) {
                self = .sessionRow(row, metadata)
            } else {
                self = .unknown(type)
            }
        case "session_status":
            if let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row) {
                self = .sessionRow(row, metadata)
            } else if let context = try container.decodeIfPresent(SessionContextSnapshot.self, forKey: .context) {
                self = .sessionContext(context, metadata)
            } else {
                self = .sessionStatus(try container.decodeIfPresent(String.self, forKey: .status), metadata)
            }
        case "session_context":
            self = .sessionContext(try container.decode(SessionContextSnapshot.self, forKey: .context), metadata)
        case "goal_updated":
            self = .goalUpdated(try container.decode(ThreadGoal.self, forKey: .goal), metadata)
        case "goal_cleared":
            self = .goalCleared(metadata)
        case "turn_started":
            self = .turnStarted(metadata)
        case "assistant_delta":
            self = .assistantDelta(try Self.decodeDelta(from: container), metadata)
        case "message_completed":
            self = .messageCompleted(try container.decode(AgentMessage.self, forKey: .message), metadata)
        case "log_delta":
            self = .logDelta(try Self.decodeLogDelta(from: container), metadata)
        case "diff_updated":
            self = .diffUpdated(try container.decode(FileChangeSummary.self, forKey: .diff), metadata)
        case "approval_request":
            self = .approvalRequest(try container.decode(AgentApprovalRequest.self, forKey: .approval), metadata)
        case "approval_resolved":
            self = .approvalResolved(metadata)
        case "user_input_request":
            self = .userInputRequest(try container.decode(AgentUserInputRequest.self, forKey: .userInput), metadata)
        case "user_input_resolved":
            self = .userInputResolved(metadata, skipped: try container.decodeIfPresent(Bool.self, forKey: .skipped) ?? false)
        case "turn_completed":
            self = .turnCompleted(metadata)
        case "warning":
            self = .warning(try Self.decodePayload(from: container, key: .warning, fallback: L10n.text("ui.unknown_warning")), metadata)
        case "error":
            self = .error(
                try Self.decodePayload(from: container, key: .error, fallback: L10n.text("ui.unknown_error")),
                metadata
            )
        default:
            self = .unknown(type)
        }
    }

    private static func decodeMetadata(from container: KeyedDecodingContainer<CodingKeys>) throws -> AgentEventMetadata {
        try container.decodeIfPresent(AgentEventMetadata.self, forKey: .meta) ?? AgentEventMetadata(
            seq: try container.decodeIfPresent(EventSequence.self, forKey: .seq),
            sessionID: try container.decodeIfPresent(SessionID.self, forKey: .sessionID),
            turnID: try container.decodeIfPresent(TurnID.self, forKey: .turnID),
            itemID: try container.decodeIfPresent(AgentItemID.self, forKey: .itemID),
            messageID: try container.decodeIfPresent(MessageID.self, forKey: .messageID),
            clientMessageID: try container.decodeIfPresent(ClientMessageID.self, forKey: .clientMessageID),
            revision: try container.decodeIfPresent(ModelRevision.self, forKey: .revision),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt)
        )
    }

    private static func decodeDelta(from container: KeyedDecodingContainer<CodingKeys>) throws -> AgentDelta {
        if let delta = try container.decodeIfPresent(AgentDelta.self, forKey: .delta) {
            return delta
        }
        return AgentDelta(text: try container.decodeIfPresent(String.self, forKey: .data) ?? "", role: .assistant, kind: .message)
    }

    private static func decodeLogDelta(from container: KeyedDecodingContainer<CodingKeys>) throws -> LogDelta {
        if let log = try container.decodeIfPresent(LogDelta.self, forKey: .log) {
            return log
        }
        return LogDelta(text: try container.decodeIfPresent(String.self, forKey: .data) ?? "", stream: nil)
    }

    private static func decodePayload(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        fallback: String
    ) throws -> AgentErrorPayload {
        if let payload = try container.decodeIfPresent(AgentErrorPayload.self, forKey: key) {
            return payload
        }
        return AgentErrorPayload(message: try container.decodeIfPresent(String.self, forKey: key) ?? fallback, code: nil, retryable: nil)
    }
}

enum StructuredAgentEvent: Decodable, Hashable {
    case sessionRow(DataFlowSessionRow, AgentEventMetadata)
    case sessionStatus(String?, AgentEventMetadata)
    case sessionContext(SessionContextSnapshot, AgentEventMetadata)
    case goalUpdated(ThreadGoal, AgentEventMetadata)
    case goalCleared(AgentEventMetadata)
    case turnStarted(AgentEventMetadata)
    case assistantDelta(AgentDelta, AgentEventMetadata)
    case messageCompleted(AgentMessage, AgentEventMetadata)
    case logDelta(LogDelta, AgentEventMetadata)
    case diffUpdated(FileChangeSummary, AgentEventMetadata)
    case approvalRequest(AgentApprovalRequest, AgentEventMetadata)
    case approvalResolved(AgentEventMetadata)
    case userInputRequest(AgentUserInputRequest, AgentEventMetadata)
    case userInputResolved(AgentEventMetadata, skipped: Bool)
    case turnCompleted(AgentEventMetadata)
    case warning(AgentErrorPayload, AgentEventMetadata)
    case error(AgentErrorPayload, AgentEventMetadata)
    case unknown(String, AgentEventMetadata)

    enum CodingKeys: String, CodingKey {
        case type
        case data
        case row
        case message
        case delta
        case log
        case diff
        case approval
        case userInput = "user_input"
        case skipped
        case error
        case warning
        case meta
        case seq
        case sessionID = "session_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case messageID = "message_id"
        case clientMessageID = "client_message_id"
        case revision
        case createdAt = "created_at"
        case status
        case context
        case goal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let metadata = try container.decodeIfPresent(AgentEventMetadata.self, forKey: .meta) ?? AgentEventMetadata(
            seq: try container.decodeIfPresent(EventSequence.self, forKey: .seq),
            sessionID: try container.decodeIfPresent(SessionID.self, forKey: .sessionID),
            turnID: try container.decodeIfPresent(TurnID.self, forKey: .turnID),
            itemID: try container.decodeIfPresent(AgentItemID.self, forKey: .itemID),
            messageID: try container.decodeIfPresent(MessageID.self, forKey: .messageID),
            clientMessageID: try container.decodeIfPresent(ClientMessageID.self, forKey: .clientMessageID),
            revision: try container.decodeIfPresent(ModelRevision.self, forKey: .revision),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt)
        )

        switch type {
        case "session_row":
            self = .sessionRow(try container.decode(DataFlowSessionRow.self, forKey: .row), metadata)
        case "session_status":
            if let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row) {
                self = .sessionRow(row, metadata)
            } else if let context = try container.decodeIfPresent(SessionContextSnapshot.self, forKey: .context) {
                self = .sessionContext(context, metadata)
            } else {
                self = .sessionStatus(try container.decodeIfPresent(String.self, forKey: .status), metadata)
            }
        case "session_context":
            self = .sessionContext(try container.decode(SessionContextSnapshot.self, forKey: .context), metadata)
        case "goal_updated":
            self = .goalUpdated(try container.decode(ThreadGoal.self, forKey: .goal), metadata)
        case "goal_cleared":
            self = .goalCleared(metadata)
        case "turn_started":
            self = .turnStarted(metadata)
        case "assistant_delta":
            self = .assistantDelta(try Self.decodeDelta(from: container), metadata)
        case "message_completed":
            self = .messageCompleted(try container.decode(AgentMessage.self, forKey: .message), metadata)
        case "log_delta":
            self = .logDelta(try Self.decodeLogDelta(from: container), metadata)
        case "diff_updated":
            self = .diffUpdated(try container.decode(FileChangeSummary.self, forKey: .diff), metadata)
        case "approval_request":
            self = .approvalRequest(try container.decode(AgentApprovalRequest.self, forKey: .approval), metadata)
        case "approval_resolved":
            self = .approvalResolved(metadata)
        case "user_input_request":
            self = .userInputRequest(try container.decode(AgentUserInputRequest.self, forKey: .userInput), metadata)
        case "user_input_resolved":
            self = .userInputResolved(metadata, skipped: try container.decodeIfPresent(Bool.self, forKey: .skipped) ?? false)
        case "turn_completed":
            self = .turnCompleted(metadata)
        case "warning":
            self = .warning(try Self.decodePayload(from: container, key: .warning, fallback: L10n.text("ui.unknown_warning")), metadata)
        case "error":
            self = .error(try Self.decodePayload(from: container, key: .error, fallback: L10n.text("ui.unknown_error")), metadata)
        default:
            self = .unknown(type, metadata)
        }
    }

    private static func decodeDelta(from container: KeyedDecodingContainer<CodingKeys>) throws -> AgentDelta {
        if let delta = try container.decodeIfPresent(AgentDelta.self, forKey: .delta) {
            return delta
        }
        return AgentDelta(text: try container.decodeIfPresent(String.self, forKey: .data) ?? "", role: .assistant, kind: .message)
    }

    private static func decodeLogDelta(from container: KeyedDecodingContainer<CodingKeys>) throws -> LogDelta {
        if let log = try container.decodeIfPresent(LogDelta.self, forKey: .log) {
            return log
        }
        return LogDelta(text: try container.decodeIfPresent(String.self, forKey: .data) ?? "", stream: nil)
    }

    private static func decodePayload(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        fallback: String
    ) throws -> AgentErrorPayload {
        if let payload = try container.decodeIfPresent(AgentErrorPayload.self, forKey: key) {
            return payload
        }
        return AgentErrorPayload(message: try container.decodeIfPresent(String.self, forKey: key) ?? fallback, code: nil, retryable: nil)
    }
}

extension AgentEventMetadata {
    static let empty = AgentEventMetadata(
        seq: nil,
        sessionID: nil,
        turnID: nil,
        itemID: nil,
        messageID: nil,
        clientMessageID: nil,
        revision: nil,
        createdAt: nil
    )
}

enum CodexMCPElicitationPresentation: Equatable {
    case form
    case confirmation
    case unsupported
}

/// MCP form 只有在当前客户端能完整表达每个字段时才进入补充信息表单。
/// Codex 工具审批必须带精确的私有标记；空 schema、未知字段类型或未知 mode
/// 都不能靠消息文案猜测授权意图，统一 fail closed。
func codexMCPElicitationPresentation(
    params: [String: CodexAppServerJSONValue]
) -> CodexMCPElicitationPresentation {
    let mode = params["mode"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    if mode == "url" {
        return .confirmation
    }
    if let mode,
       !mode.isEmpty,
       !["form", "openai/form", "openai-form"].contains(mode) {
        return .unsupported
    }
    if CodexMCPToolApprovalProtocol.isToolCall(params) {
        return .confirmation
    }

    guard let properties = params["requestedSchema"]?
        .objectValue?["properties"]?.objectValue,
        !properties.isEmpty,
        properties.values.allSatisfy(codexMCPFormPropertyIsRenderable)
    else {
        return .unsupported
    }
    return .form
}

private func codexMCPFormPropertyIsRenderable(_ value: CodexAppServerJSONValue) -> Bool {
    guard let schema = value.objectValue else {
        return false
    }
    switch schema["type"]?.stringValue?.lowercased() {
    case "string", "boolean", "integer", "number":
        return true
    case "array":
        guard let items = schema["items"]?.objectValue else {
            return false
        }
        return items["type"]?.stringValue?.lowercased() == "string"
            || items["enum"]?.arrayValue?.isEmpty == false
            || items["anyOf"]?.arrayValue?.isEmpty == false
    case nil:
        return schema["enum"]?.arrayValue?.isEmpty == false
            || schema["oneOf"]?.arrayValue?.isEmpty == false
    default:
        return false
    }
}

struct CodexAppServerEventProjector {
    private struct StreamedTextKey: Hashable {
        let sessionID: SessionID?
        let turnID: TurnID?
        let itemID: AgentItemID?
        let suffix: String
    }

    private var nextSeqBySessionID: [SessionID: EventSequence] = [:]
    private var streamedTextByKey: [StreamedTextKey: String] = [:]
    private var agentMessageKindByItemID: [AgentItemID: MessageKind] = [:]

    mutating func project(_ notification: CodexAppServerNotification) -> AgentEvent? {
        let params = notification.params?.objectValue ?? [:]
        let metadata = makeMetadata(from: params)

        switch notification.method {
        case "thread/goal/updated":
            guard let goal = goal(from: params) else {
                return nil
            }
            return .goalUpdated(goal, metadata)
        case "thread/goal/cleared":
            return .goalCleared(metadata)
        case "turn/started":
            return .turnStarted(metadata)
        case "item/agentMessage/delta":
            guard let text = firstString(in: params, keys: ["delta", "text"]), !text.isEmpty else {
                return nil
            }
            return .assistantDelta(
                AgentDelta(text: text, role: .assistant, kind: agentMessageKind(from: params, metadata: metadata)),
                metadata
            )
        case "turn/plan/updated":
            let event = completedPlanEvent(params: params, metadata: metadata)
            clearStreamedText(sessionID: metadata.sessionID, turnID: metadata.turnID, suffix: "plan")
            return event
        case "item/plan/delta":
            return streamedSystemMessageEvent(
                params: params,
                metadata: metadata,
                deltaKeys: ["delta", "text"],
                bufferSuffix: "plan",
                kind: .plan
            )
        case "item/reasoning/summaryTextDelta":
            let summaryIndex = firstInt(in: params, keys: ["summaryIndex"]) ?? 0
            return streamedSystemMessageEvent(
                params: params,
                metadata: metadata,
                deltaKeys: ["delta", "text"],
                bufferSuffix: "reasoning-summary-\(summaryIndex)",
                kind: .reasoningSummary,
                activityCategory: .thinking,
                usesDistinctBufferItemID: true
            )
        case "item/reasoning/summaryPartAdded":
            // 这是新分段边界，本身没有可展示文本；后续 summaryTextDelta 会带 index。
            return nil
        case "thread/tokenUsage/updated":
            return tokenUsageContextEvent(params: params, metadata: metadata)
        case "thread/compacted":
            // compaction 只替换模型上下文，不是用户可见的 Turn Item；写入 transcript 会在
            // replacement_history 到达时制造重复或错序。token/context 状态由各自通知更新。
            return nil
        case "thread/name/updated":
            // 标题属于导航元数据，由 Runtime 的 Session 投影实时更新；不再向对话正文
            // 插入系统消息，避免自动标题和手动改名污染 transcript。
            return nil
        case "item/mcpToolCall/progress":
            return mcpProgressContextEvent(params: params, metadata: metadata)
        case "mcpServer/startupStatus/updated":
            return mcpServerStatusContextEvent(params: params, metadata: metadata)
        case "deprecationNotice":
            let summary = firstString(in: params, keys: ["summary"]) ?? L10n.text("ui.app_server_protocol_capability_is_obsolete")
            let details = firstString(in: params, keys: ["details"])
            return .warning(
                AgentErrorPayload(
                    message: [summary, details].compactMap { $0 }.joined(separator: "\n"),
                    code: "deprecationNotice",
                    retryable: false
                ),
                metadata
            )
        case "item/started":
            rememberAgentMessageKind(from: params, metadata: metadata)
            return startedProcessItemEvent(params: params, metadata: metadata)
                ?? itemContextEvent(params: params, metadata: metadata)
        case "item/completed":
            let event = completedUserMessageEvent(params: params, metadata: metadata)
                ?? completedAgentMessageEvent(params: params, metadata: metadata)
                ?? completedImageItemEvent(params: params, metadata: metadata)
                // collabAgentToolCall 的 receiverThreadIds 是子会话关系的唯一可信来源。
                // 必须先于通用工具活动投影处理，否则它会被 processItemCompleted 吞掉。
                ?? collabSubagentContextEvent(params: params, metadata: metadata)
                ?? completedProcessItemEvent(params: params, metadata: metadata)
                ?? itemContextEvent(params: params, metadata: metadata)
            if let itemID = metadata.itemID {
                clearStreamedText(
                    sessionID: metadata.sessionID,
                    turnID: metadata.turnID,
                    itemID: itemID
                )
            }
            return event
        case "item/commandExecution/outputDelta",
             "command/exec/outputDelta",
             "commandExecution/outputDelta",
             "command/execution/outputDelta",
             "process/outputDelta":
            guard let text = firstString(in: params, keys: ["delta", "data", "text", "chunk"]), !text.isEmpty else {
                return nil
            }
            return .logDelta(LogDelta(text: text, stream: firstString(in: params, keys: ["stream", "fd"])), metadata)
        case "item/fileChange/patchUpdated",
             "fileChange/patchUpdated",
             "turn/diff/updated":
            return fileChangeContextEvent(params: params, metadata: metadata)
        case "turn/completed":
            clearStreamedText(sessionID: metadata.sessionID, turnID: metadata.turnID)
            return .turnCompleted(metadata.withTurnLifecycle(turnLifecycle(from: params)))
        case "serverRequest/resolved":
            return .approvalResolved(metadata)
        case "warning":
            let payload = errorPayload(from: params, fallback: "app-server warning")
            // 兼容尚未升级的 Claude bridge：allowed_warning 只表示接近额度阈值，
            // 账号快照会单独更新用量，不应再生成红色时间线故障卡。
            guard !isNonBlockingClaudeRateLimitWarning(payload) else {
                return nil
            }
            return .warning(payload, metadata)
        case "error":
            clearStreamedText(sessionID: metadata.sessionID, turnID: metadata.turnID)
            return .error(errorPayload(from: params, fallback: "app-server error"), metadata)
        default:
            return nil
        }
    }

    mutating func project(_ request: CodexAppServerServerRequest) -> AgentEvent? {
        let params = request.params?.objectValue ?? [:]
        if request.method == "item/tool/requestUserInput" {
            let metadata = makeMetadata(from: params)
            guard let request = userInputRequest(from: params, requestID: request.id.description, metadata: metadata) else {
                return nil
            }
            return .userInputRequest(request, metadata)
        }
        if request.method == "mcpServer/elicitation/request" {
            switch codexMCPElicitationPresentation(params: params) {
            case .form:
                let metadata = makeMetadata(from: params)
                guard let userInput = mcpElicitationUserInputRequest(
                    from: params,
                    requestID: request.id.description,
                    metadata: metadata
                ) else {
                    return nil
                }
                return .userInputRequest(userInput, metadata)
            case .confirmation:
                break
            case .unsupported:
                return nil
            }
        }
        guard isApprovalLike(method: request.method, params: params) else {
            return nil
        }
        let metadata = makeMetadata(from: params)
        let kind = approvalKind(method: request.method, params: params)
        let itemID = metadata.itemID ?? request.id.description
        let availableDecisions: [String]?
        if kind == CodexMCPToolApprovalProtocol.kind {
            availableDecisions = CodexMCPToolApprovalProtocol.availableDecisions(params)
        } else if kind == "mcp_elicitation" {
            availableDecisions = ["accept", "decline"]
        } else {
            availableDecisions = params["availableDecisions"]?.arrayValue?.compactMap(\.stringValue)
        }
        return .approvalRequest(
            AgentApprovalRequest(
                id: firstString(in: params, keys: ["approvalId"]) ?? itemID,
                title: approvalTitle(kind: kind, params: params),
                body: approvalBody(kind: kind, params: params),
                kind: kind,
                risk: firstString(in: params, keys: ["risk"]) ?? "high",
                availableDecisions: availableDecisions,
                persistentPermissionRules: eligiblePersistentPermissionRules(from: params)
            ),
            metadata
        )
    }

    private mutating func makeMetadata(from params: [String: CodexAppServerJSONValue]) -> AgentEventMetadata {
        let sessionID = firstString(in: params, keys: ["threadId", "conversationId", "sessionId", "session_id"])
            ?? nestedString(in: params, key: "thread", nestedKey: "id")
        let turnID = firstString(in: params, keys: ["turnId", "turn_id"]) ?? nestedString(in: params, key: "turn", nestedKey: "id")
        let item = params["item"]?.objectValue
        let itemID = firstString(in: params, keys: ["itemId", "item_id", "requestId", "request_id", "callId", "approvalId"]) ?? item?["id"]?.stringValue
        let messageID = firstString(in: params, keys: ["messageId", "message_id"]) ?? appServerMessageID(turnID: turnID, itemID: itemID)
        let seq = nextSeq(for: sessionID)
        return AgentEventMetadata(
            seq: seq,
            sessionID: sessionID,
            turnID: turnID,
            itemID: itemID,
            messageID: messageID,
            clientMessageID: firstString(in: params, keys: ["clientUserMessageId", "clientMessageId", "client_message_id"])
                ?? item?["clientId"]?.stringValue,
            revision: Int(seq),
            createdAt: nil
        )
    }

    private mutating func nextSeq(for sessionID: SessionID?) -> EventSequence {
        let key = sessionID ?? "__appserver_global__"
        let next = (nextSeqBySessionID[key] ?? 0) + 1
        nextSeqBySessionID[key] = next
        return next
    }

    private mutating func completedAgentMessageEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let item = params["item"]?.objectValue,
              item["type"]?.stringValue == "agentMessage" else {
            return nil
        }
        let itemID = metadata.itemID ?? item["id"]?.stringValue
        defer {
            if let itemID {
                agentMessageKindByItemID.removeValue(forKey: itemID)
            }
        }
        let text = firstString(in: item, keys: ["text", "content"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return nil
        }
        // completed item 是 app-server 的权威最终内容，用稳定 message id 覆盖同一条 streaming 气泡。
        let messageID = metadata.messageID ?? appServerMessageID(turnID: metadata.turnID, itemID: itemID) ?? itemID ?? UUID().uuidString
        let sessionID = metadata.sessionID ?? ""
        let kind: MessageKind
        if let phase = firstString(in: item, keys: ["phase"]) {
            kind = phase == "commentary" ? .commentary : .message
        } else if let itemID {
            // 少数 app-server 版本 completed 不重复 phase，沿用 started 时记录的语义。
            kind = agentMessageKindByItemID[itemID] ?? .message
        } else {
            kind = .message
        }
        let message = AgentMessage(
            id: messageID,
            sessionID: sessionID,
            turnID: metadata.turnID,
            itemID: itemID,
            role: .assistant,
            kind: kind,
            content: text,
            createdAt: Date(),
            seq: metadata.seq,
            revision: metadata.revision ?? 0,
            sendStatus: .confirmed
        )
        return .messageCompleted(message, metadata)
    }

    private func completedUserMessageEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let item = params["item"]?.objectValue,
              item["type"]?.stringValue == "userMessage",
              let clientMessageID = metadata.clientMessageID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientMessageID.isEmpty else {
            return nil
        }
        let content = (item["content"]?.arrayValue ?? []).compactMap { value -> String? in
            guard let part = value.objectValue else {
                return nil
            }
            switch part["type"]?.stringValue {
            case "text":
                return part["text"]?.stringValue
            case "image":
                return L10n.text("ui.image_attachment")
            case "localImage":
                guard let path = part["path"]?.stringValue else {
                    return L10n.text("ui.image_attachment")
                }
                return L10n.format("ui.image_value", URL(fileURLWithPath: path).lastPathComponent)
            case "skill":
                return part["name"]?.stringValue.map { "[$\($0)]" }
            case "mention":
                return part["name"]?.stringValue.map { "[@\($0)]" }
            default:
                return nil
            }
        }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isVisibleAppServerUserMessageText(content) else {
            return nil
        }
        let itemID = metadata.itemID ?? item["id"]?.stringValue
        let messageID = metadata.messageID
            ?? appServerMessageID(turnID: metadata.turnID, itemID: itemID)
            ?? itemID
            ?? UUID().uuidString
        let message = AgentMessage(
            id: messageID,
            sessionID: metadata.sessionID ?? "",
            clientMessageID: clientMessageID,
            turnID: metadata.turnID,
            itemID: itemID,
            role: .user,
            content: content,
            createdAt: Date(),
            seq: metadata.seq,
            revision: metadata.revision ?? 0,
            sendStatus: .confirmed
        )
        return .messageCompleted(message, metadata)
    }

    private mutating func rememberAgentMessageKind(
        from params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) {
        guard let item = params["item"]?.objectValue,
              item["type"]?.stringValue == "agentMessage",
              let itemID = metadata.itemID ?? item["id"]?.stringValue
        else {
            return
        }
        agentMessageKindByItemID[itemID] = item["phase"]?.stringValue == "commentary" ? .commentary : .message
    }

    private func agentMessageKind(
        from params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> MessageKind {
        if firstString(in: params, keys: ["phase"]) == "commentary" ||
            params["item"]?.objectValue?["phase"]?.stringValue == "commentary" {
            return .commentary
        }
        guard let itemID = metadata.itemID else {
            return .message
        }
        return agentMessageKindByItemID[itemID] ?? .message
    }

    private func completedImageItemEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let item = params["item"]?.objectValue,
              let content = ConversationImageItemProjection.markdownContent(from: item) else {
            return nil
        }
        let itemID = metadata.itemID ?? item["id"]?.stringValue
        let messageID = metadata.messageID
            ?? appServerMessageID(turnID: metadata.turnID, itemID: itemID)
            ?? itemID
            ?? UUID().uuidString
        let message = AgentMessage(
            id: messageID,
            sessionID: metadata.sessionID ?? "",
            turnID: metadata.turnID,
            itemID: itemID,
            role: .assistant,
            kind: .message,
            content: content,
            createdAt: Date(),
            seq: metadata.seq,
            revision: metadata.revision ?? 0,
            sendStatus: .confirmed
        )
        return .messageCompleted(message, metadata)
    }

    private mutating func completedPlanEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        let steps = (params["plan"]?.arrayValue ?? []).compactMap { value -> String? in
            guard let object = value.objectValue,
                  let step = firstString(in: object, keys: ["step"]),
                  !step.isEmpty else {
                return nil
            }
            let marker: String
            switch firstString(in: object, keys: ["status"]) {
            case "completed": marker = "✓"
            case "inProgress": marker = "→"
            default: marker = "·"
            }
            return "\(marker) \(step)"
        }
        let explanation = firstString(in: params, keys: ["explanation"])
        let text = ([explanation].compactMap { $0 } + steps).joined(separator: "\n")
        guard !text.isEmpty else {
            return nil
        }
        return systemNoticeEvent(text: text, itemID: "turn-plan", kind: .plan, metadata: metadata)
    }

    private mutating func streamedSystemMessageEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata,
        deltaKeys: [String],
        bufferSuffix: String,
        kind: MessageKind,
        activityCategory: ConversationActivityCategory? = nil,
        usesDistinctBufferItemID: Bool = false
    ) -> AgentEvent? {
        guard let delta = firstString(in: params, keys: deltaKeys), !delta.isEmpty else {
            return nil
        }
        let key = StreamedTextKey(
            sessionID: metadata.sessionID,
            turnID: metadata.turnID,
            itemID: metadata.itemID,
            suffix: bufferSuffix
        )
        streamedTextByKey[key, default: ""].append(contentsOf: delta)
        guard let next = streamedTextByKey[key] else {
            return nil
        }
        let payload = activityCategory.map { category in
            ConversationActivityPayload(
                category: category,
                displayTitle: category == .thinking ? L10n.text("ui.reasoning_summary") : L10n.text("ui.process_update"),
                subtitle: next,
                status: "inProgress"
            )
        }
        return systemNoticeEvent(
            text: next,
            itemID: usesDistinctBufferItemID
                ? "\(metadata.itemID ?? "reasoning"):\(bufferSuffix)"
                : (metadata.itemID ?? bufferSuffix),
            kind: kind,
            metadata: metadata,
            activityPayload: payload
        )
    }

    private mutating func clearStreamedText(
        sessionID: SessionID?,
        turnID: TurnID?,
        itemID: AgentItemID? = nil,
        suffix: String? = nil
    ) {
        streamedTextByKey = streamedTextByKey.filter { key, _ in
            guard key.sessionID == sessionID, key.turnID == turnID else {
                return true
            }
            if let itemID, key.itemID != itemID {
                return true
            }
            if let suffix, key.suffix != suffix {
                return true
            }
            return false
        }
    }

    private func systemNoticeEvent(
        text: String,
        itemID: String,
        kind: MessageKind,
        metadata: AgentEventMetadata,
        activityPayload: ConversationActivityPayload? = nil
    ) -> AgentEvent {
        let projectedMetadata = metadataWithItemID(itemID, metadata: metadata)
        let messageID = projectedMetadata.messageID ?? itemID
        let message = AgentMessage(
            id: messageID,
            sessionID: projectedMetadata.sessionID ?? "",
            turnID: projectedMetadata.turnID,
            itemID: itemID,
            role: .system,
            kind: kind,
            content: text,
            activityPayload: activityPayload,
            createdAt: Date(),
            seq: projectedMetadata.seq,
            revision: projectedMetadata.revision ?? 0,
            sendStatus: .confirmed
        )
        return .messageCompleted(message, projectedMetadata)
    }

    private func metadataWithItemID(
        _ itemID: String,
        metadata: AgentEventMetadata
    ) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: metadata.seq,
            sessionID: metadata.sessionID,
            turnID: metadata.turnID,
            itemID: itemID,
            messageID: appServerMessageID(turnID: metadata.turnID, itemID: itemID),
            clientMessageID: metadata.clientMessageID,
            revision: metadata.revision,
            createdAt: metadata.createdAt
        )
    }

    private func tokenUsageContextEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let usage = params["tokenUsage"]?.objectValue else {
            return nil
        }
        let total = usage["total"]?.objectValue ?? [:]
        let totalTokens = firstInt(in: total, keys: ["totalTokens"])
        let inputTokens = firstInt(in: total, keys: ["inputTokens"])
        let outputTokens = firstInt(in: total, keys: ["outputTokens"])
        let window = firstInt(in: usage, keys: ["modelContextWindow"])
        var parts: [String] = []
        if let totalTokens { parts.append(L10n.format("ui.token_usage_total", totalTokens)) }
        if let inputTokens { parts.append(L10n.format("ui.token_usage_input", inputTokens)) }
        if let outputTokens { parts.append(L10n.format("ui.token_usage_output", outputTokens)) }
        if let window { parts.append(L10n.format("ui.token_usage_context_window", window)) }
        guard !parts.isEmpty else {
            return nil
        }
        return .sessionContext(
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: [SessionContextTask(
                    id: "token-usage",
                    kind: "token_usage",
                    title: L10n.text("ui.token_usage"),
                    subtitle: parts.joined(separator: " · "),
                    status: "updated"
                )],
                updatedAt: Date()
            ),
            metadata
        )
    }

    private func mcpProgressContextEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let message = firstString(in: params, keys: ["message"]), !message.isEmpty else {
            return nil
        }
        return .sessionContext(
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: [SessionContextTask(
                    id: metadata.itemID ?? "mcp-progress",
                    kind: "mcp_tool",
                    title: L10n.text("ui.mcp_tool_call"),
                    subtitle: message,
                    status: "inProgress"
                )],
                updatedAt: Date()
            ),
            metadata
        )
    }

    private func mcpServerStatusContextEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let name = firstString(in: params, keys: ["name"]),
              let status = firstString(in: params, keys: ["status"]) else {
            return nil
        }
        return .sessionContext(
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: [SessionContextTask(
                    id: "mcp-server-\(name)",
                    kind: "mcp_server",
                    title: name,
                    subtitle: firstString(in: params, keys: ["error", "failureReason"]),
                    status: status
                )],
                updatedAt: Date()
            ),
            metadata
        )
    }

    private func completedProcessItemEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let item = params["item"]?.objectValue,
              let payload = ConversationActivityPayload(item: item)
        else {
            return nil
        }
        let content = payload.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return nil
        }
        let itemID = metadata.itemID ?? item["id"]?.stringValue
        let messageID = metadata.messageID ?? appServerMessageID(turnID: metadata.turnID, itemID: itemID) ?? itemID ?? UUID().uuidString
        let sessionID = metadata.sessionID ?? ""
        let message = AgentMessage(
            id: messageID,
            sessionID: sessionID,
            turnID: metadata.turnID,
            itemID: itemID,
            role: .system,
            kind: payload.messageKind,
            content: content,
            activityPayload: payload,
            createdAt: Date(),
            seq: metadata.seq,
            revision: metadata.revision ?? 0,
            sendStatus: .confirmed
        )
        let context = contextTask(from: item, fallbackStatus: firstString(in: params, keys: ["status"])).map { task in
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: [task],
                updatedAt: Date()
            )
        }
        return .processItemCompleted(message, context, metadata)
    }

    private func startedProcessItemEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard var item = params["item"]?.objectValue,
              let type = firstString(in: item, keys: ["type"]),
              [
                "commandExecution",
                "fileChange",
                "mcpToolCall",
                "dynamicToolCall",
                "collabAgentToolCall",
                "webSearch",
              ].contains(type)
        else {
            return nil
        }
        // started 可能早于 status 字段到达。命令、Tool 与子 Agent 都先投影可见的运行中消息，
        // completed 再用同一 stable message ID 原位覆盖，避免查询或等待期间页面看起来卡住。
        if firstString(in: item, keys: ["status"]) == nil {
            item["status"] = .string("inProgress")
        }
        var normalizedParams = params
        normalizedParams["item"] = .object(item)
        return completedProcessItemEvent(params: normalizedParams, metadata: metadata)
    }

    private func turnLifecycle(
        from params: [String: CodexAppServerJSONValue]
    ) -> ConversationTurnLifecycle {
        let turn = params["turn"]?.objectValue
        let raw = firstString(in: turn ?? params, keys: ["status"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "failed", "failure", "systemerror", "system_error":
            return .failed
        case "interrupted", "cancelled", "canceled", "aborted":
            return .interrupted
        default:
            // 兼容旧 app-server 只携带 threadId/turnId 的完成通知。
            return .completed
        }
    }

    private func itemContextEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let item = params["item"]?.objectValue else {
            return nil
        }
        let task = contextTask(from: item, fallbackStatus: firstString(in: params, keys: ["status"]))
        let subagents = contextSubagents(from: item, parentThreadID: metadata.sessionID)
        guard task != nil || !subagents.isEmpty else { return nil }
        return .sessionContext(
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: task.map { [$0] } ?? [],
                subagents: subagents,
                updatedAt: Date()
            ),
            metadata
        )
    }

    private func collabSubagentContextEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let item = params["item"]?.objectValue else {
            return nil
        }
        let subagents = contextSubagents(from: item, parentThreadID: metadata.sessionID)
        guard !subagents.isEmpty else {
            return nil
        }
        return .sessionContext(
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                subagents: subagents,
                updatedAt: Date()
            ),
            metadata
        )
    }

    private func contextSubagents(
        from item: [String: CodexAppServerJSONValue],
        parentThreadID: SessionID?
    ) -> [SessionContextSubagent] {
        guard firstString(in: item, keys: ["type"]) == "collabAgentToolCall",
              let parentThreadID,
              !parentThreadID.isEmpty
        else {
            return []
        }
        let receiverThreadIDs = item["receiverThreadIds"]?.arrayValue?
            .compactMap(\.stringValue)
            .filter { rawID in
                !rawID.isEmpty
                    && rawID == rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            ?? []
        let agentStates = item["agentsStates"]?.objectValue ?? [:]
        return Array(Set(receiverThreadIDs)).sorted().map { childThreadID in
            let state = agentStates[childThreadID]?.objectValue
            return SessionContextSubagent(
                id: childThreadID,
                parentThreadID: parentThreadID,
                sessionID: firstString(in: state ?? [:], keys: ["sessionId"]),
                nickname: firstString(in: item, keys: ["agentNickname", "nickname", "tool"]),
                role: firstString(in: item, keys: ["agentRole", "role"]),
                status: firstString(in: state ?? [:], keys: ["status"])
                    ?? agentStates[childThreadID]?.stringValue
                    ?? firstString(in: item, keys: ["status"]),
                statusMessage: firstString(in: state ?? [:], keys: ["message"]),
                canAcceptDirectInput: state?["canAcceptDirectInput"]?.boolValue
            )
        }
    }

    private func contextTask(
        from item: [String: CodexAppServerJSONValue],
        fallbackStatus: String?
    ) -> SessionContextTask? {
        let id = firstString(in: item, keys: ["id"]) ?? UUID().uuidString
        let status = firstString(in: item, keys: ["status"]) ?? fallbackStatus
        switch firstString(in: item, keys: ["type"]) {
        case "commandExecution":
            let title = firstString(in: item, keys: ["command", "processId"]) ?? L10n.text("ui.command_execution")
            let subtitle = firstString(in: item, keys: ["cwd"]) ?? commandActionSummary(from: item["commandActions"]?.arrayValue)
            return SessionContextTask(id: id, kind: "command", title: String(title.prefix(80)), subtitle: subtitle, status: status)
        case "fileChange":
            let changes = item["changes"]?.arrayValue?.compactMap(\.objectValue) ?? []
            let title = changes.isEmpty ? L10n.text("ui.file_changes") : L10n.plural("ui.files_changed_count", count: changes.count)
            return SessionContextTask(id: id, kind: "file_change", title: title, subtitle: fileChangeTaskSummary(from: changes), status: status)
        case "mcpToolCall":
            let server = firstString(in: item, keys: ["server"])
            let tool = firstString(in: item, keys: ["tool"])
            let title = [server, tool].compactMap { $0 }.joined(separator: ".")
            return SessionContextTask(
                id: id,
                kind: "mcp_tool",
                title: ConversationActivityPayload(item: item)?.displayTitle ?? (title.isEmpty ? L10n.text("ui.mcp_tools") : title),
                subtitle: firstString(in: item, keys: ["pluginId"]),
                status: status
            )
        case "dynamicToolCall":
            let namespace = firstString(in: item, keys: ["namespace"])
            let tool = firstString(in: item, keys: ["tool"]) ?? L10n.text("ui.dynamic_tools")
            let title = [namespace, tool].compactMap { $0 }.joined(separator: ".")
            return SessionContextTask(
                id: id,
                kind: "dynamic_tool",
                title: ConversationActivityPayload(item: item)?.displayTitle ?? title,
                subtitle: nil,
                status: status
            )
        case "collabAgentToolCall":
            let title = firstString(in: item, keys: ["tool", "agentNickname", "nickname"]) ?? L10n.text("ui.sub_agent")
            return SessionContextTask(id: id, kind: "subagent", title: title, subtitle: firstString(in: item, keys: ["agentRole", "role"]), status: status)
        default:
            return nil
        }
    }

    private func commandActionSummary(from actions: [CodexAppServerJSONValue]?) -> String? {
        for action in actions?.compactMap(\.objectValue) ?? [] {
            if let value = [firstString(in: action, keys: ["name"]), firstString(in: action, keys: ["path"])]
                .compactMap({ $0 })
                .joined(separator: " ")
                .nilIfEmpty {
                return value
            }
            if let query = firstString(in: action, keys: ["query"]) {
                return query
            }
        }
        return nil
    }

    private func fileChangeTaskSummary(from changes: [[String: CodexAppServerJSONValue]]) -> String? {
        guard !changes.isEmpty else {
            return nil
        }
        var parts = changes.prefix(3).compactMap { change in
            firstString(in: change, keys: ["path", "kind"])
        }
        if changes.count > parts.count {
            parts.append("+\(changes.count - parts.count)")
        }
        return parts.joined(separator: ", ")
    }

    private func fileChangeContextEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent {
        let change = fileChangeSummary(from: params)
        return .sessionContext(
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: [
                    SessionContextTask(
                        id: metadata.itemID ?? change.path,
                        kind: "file_change",
                        title: L10n.text("ui.file_changes"),
                        subtitle: change.path,
                        status: change.status
                    )
                ],
                updatedAt: Date()
            ),
            metadata
        )
    }

    private func fileChangeSummary(from params: [String: CodexAppServerJSONValue]) -> FileChangeSummary {
        let source = params["fileChange"]?.objectValue
            ?? params["change"]?.objectValue
            ?? params["diff"]?.objectValue
            ?? params["item"]?.objectValue
            ?? params
        return FileChangeSummary(
            path: firstString(in: source, keys: ["path", "filePath", "relativePath", "filename"]) ?? "workspace",
            status: firstString(in: source, keys: ["status", "kind", "type"]) ?? "modified",
            additions: firstInt(in: source, keys: ["additions", "added"]),
            deletions: firstInt(in: source, keys: ["deletions", "removed"])
        )
    }

    private func goal(from params: [String: CodexAppServerJSONValue]) -> ThreadGoal? {
        if let object = params["goal"]?.objectValue {
            return ThreadGoal(object: object)
        }
        return ThreadGoal(object: params)
    }

    private func errorPayload(from params: [String: CodexAppServerJSONValue], fallback: String) -> AgentErrorPayload {
        AgentErrorPayload(
            message: firstString(in: params, keys: ["message", "warning", "error"])
                ?? nestedString(in: params, key: "error", nestedKey: "message")
                ?? fallback,
            code: firstString(in: params, keys: ["code"])
                ?? nestedString(in: params, key: "error", nestedKey: "code"),
            retryable: params["retryable"]?.boolValue ?? params["willRetry"]?.boolValue
        )
    }

    private func isNonBlockingClaudeRateLimitWarning(_ payload: AgentErrorPayload) -> Bool {
        payload.message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("claude rate-limit status: allowed_warning")
    }

    private func appServerMessageID(turnID: TurnID?, itemID: AgentItemID?) -> MessageID? {
        guard let itemID, !itemID.isEmpty else {
            return nil
        }
        guard let turnID, !turnID.isEmpty else {
            return itemID
        }
        return "appserver:\(turnID):\(itemID)"
    }

    private func firstString(in params: [String: CodexAppServerJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = params[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    private func firstInt(in params: [String: CodexAppServerJSONValue], keys: [String]) -> Int? {
        for key in keys {
            if let value = params[key]?.intValue {
                return value
            }
        }
        return nil
    }

    private func nestedString(
        in params: [String: CodexAppServerJSONValue],
        key: String,
        nestedKey: String
    ) -> String? {
        params[key]?.objectValue?[nestedKey]?.stringValue
    }

    private func userInputRequest(
        from params: [String: CodexAppServerJSONValue],
        requestID: String,
        metadata: AgentEventMetadata
    ) -> AgentUserInputRequest? {
        guard let threadID = metadata.sessionID ?? firstString(in: params, keys: ["threadId", "sessionId", "session_id"]) else {
            return nil
        }
        let itemID = metadata.itemID ?? firstString(in: params, keys: ["itemId", "item_id"]) ?? requestID
        let questions = (params["questions"]?.arrayValue ?? []).compactMap(userInputQuestion(from:))
        return AgentUserInputRequest(
            id: itemID,
            threadID: threadID,
            turnID: metadata.turnID ?? firstString(in: params, keys: ["turnId", "turn_id"]),
            itemID: itemID,
            questions: questions
        )
    }

    private func userInputQuestion(from value: CodexAppServerJSONValue) -> AgentUserInputQuestion? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return nil
        }
        let options = (object["options"]?.arrayValue ?? []).compactMap(userInputOption(from:))
        return AgentUserInputQuestion(
            id: id,
            header: object["header"]?.stringValue ?? "",
            question: object["question"]?.stringValue ?? "",
            isOther: object["isOther"]?.boolValue ?? object["is_other"]?.boolValue ?? false,
            isSecret: object["isSecret"]?.boolValue ?? object["is_secret"]?.boolValue ?? false,
            options: options,
            multiSelect: object["multiSelect"]?.boolValue ?? object["multi_select"]?.boolValue
        )
    }

    private func userInputOption(from value: CodexAppServerJSONValue) -> AgentUserInputOption? {
        guard let object = value.objectValue,
              let label = object["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return nil
        }
        return AgentUserInputOption(label: label, description: object["description"]?.stringValue)
    }

    private func mcpElicitationUserInputRequest(
        from params: [String: CodexAppServerJSONValue],
        requestID: String,
        metadata: AgentEventMetadata
    ) -> AgentUserInputRequest? {
        guard let threadID = metadata.sessionID else {
            return nil
        }
        let properties = params["requestedSchema"]?.objectValue?["properties"]?.objectValue ?? [:]
        let questions = properties.keys.sorted().compactMap { key -> AgentUserInputQuestion? in
            guard let schema = properties[key]?.objectValue else {
                return nil
            }
            let options = mcpElicitationOptions(from: schema)
            let title = firstString(in: schema, keys: ["title"]) ?? key
            let description = firstString(in: schema, keys: ["description"])
                ?? L10n.format("ui.please_fill_in_value", title)
            return AgentUserInputQuestion(
                id: key,
                header: title,
                question: description,
                isOther: options.isEmpty || schema["type"]?.stringValue == "array",
                isSecret: false,
                options: options
            )
        }
        guard !questions.isEmpty else {
            return nil
        }
        return AgentUserInputRequest(
            id: requestID,
            threadID: threadID,
            turnID: metadata.turnID,
            itemID: requestID,
            questions: questions
        )
    }

    private func mcpElicitationOptions(
        from schema: [String: CodexAppServerJSONValue]
    ) -> [AgentUserInputOption] {
        if schema["type"]?.stringValue == "boolean" {
            return [
                AgentUserInputOption(label: "true", description: L10n.text("ui.yes")),
                AgentUserInputOption(label: "false", description: L10n.text("ui.no"))
            ]
        }
        if let values = schema["enum"]?.arrayValue?.compactMap(\.stringValue), !values.isEmpty {
            let names = schema["enumNames"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return values.enumerated().map { index, value in
                AgentUserInputOption(label: value, description: names.indices.contains(index) ? names[index] : nil)
            }
        }
        let variants = schema["oneOf"]?.arrayValue
            ?? schema["items"]?.objectValue?["anyOf"]?.arrayValue
            ?? []
        let titled = variants.compactMap { value -> AgentUserInputOption? in
            guard let object = value.objectValue,
                  let raw = object["const"]?.stringValue else {
                return nil
            }
            return AgentUserInputOption(label: raw, description: object["title"]?.stringValue)
        }
        if !titled.isEmpty {
            return titled
        }
        let arrayEnum = schema["items"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return arrayEnum.map { AgentUserInputOption(label: $0, description: nil) }
    }

    private func isApprovalLike(
        method: String,
        params: [String: CodexAppServerJSONValue] = [:]
    ) -> Bool {
        let lower = method.lowercased()
        return lower.contains("approval")
            || (method == "mcpServer/elicitation/request"
                && codexMCPElicitationPresentation(params: params) == .confirmation)
    }

    private func approvalKind(
        method: String,
        params: [String: CodexAppServerJSONValue]
    ) -> String {
        let lower = method.lowercased()
        if lower.contains("filechange") || lower.contains("applypatch") {
            return "file_change"
        }
        if lower.contains("permission") {
            return "permission"
        }
        if lower.contains("mcpserver/elicitation"),
           CodexMCPToolApprovalProtocol.isToolCall(params) {
            return CodexMCPToolApprovalProtocol.kind
        }
        if lower.contains("mcpserver/elicitation") {
            return "mcp_elicitation"
        }
        return "command"
    }

    private func approvalTitle(kind: String, params: [String: CodexAppServerJSONValue]) -> String {
        switch kind {
        case "file_change":
            return L10n.text("ui.agent_requests_to_modify_a_file")
        case "permission":
            return L10n.text("ui.agent_requests_elevated_privileges")
        case "user_input":
            return L10n.text("ui.agent_requests_additional_input")
        case "mcp_elicitation", CodexMCPToolApprovalProtocol.kind:
            let server = firstString(in: params, keys: ["serverName"]) ?? L10n.text("ui.mcp_service")
            return L10n.format("ui.value_requests_user_confirmation", server)
        default:
            if let command = commandSummary(params: params) {
                return L10n.format("ui.agent_requests_execution_command_value", command)
            }
            if let toolName = firstString(in: params, keys: ["toolName", "tool_name"]) {
                return L10n.format("ui.claude_requested_tools_value", toolName)
            }
            return L10n.text("ui.agent_requests_to_execute_a_command")
        }
    }

    private func approvalBody(kind: String, params: [String: CodexAppServerJSONValue]) -> String? {
        if kind == "command" {
            let command = commandSummary(params: params)
            let toolName = firstString(in: params, keys: ["toolName", "tool_name"])
            let inputSummary = firstString(in: params, keys: ["inputSummary", "input_summary"])
            let reason = firstString(in: params, keys: ["reason", "message"])
            return [command, toolName, inputSummary, reason].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty
        }
        if kind == "mcp_elicitation" || kind == CodexMCPToolApprovalProtocol.kind {
            return [
                firstString(in: params, keys: ["message"]),
                firstString(in: params, keys: ["url"])
            ].compactMap { $0 }.joined(separator: "\n\n")
        }
        let path = firstString(in: params, keys: ["path", "filePath", "file_path", "grantRoot", "grant_root"])
        let diff = firstString(in: params, keys: ["diff", "patch"])
        let inputSummary = firstString(in: params, keys: ["inputSummary", "input_summary", "prompt"])
        let reason = firstString(in: params, keys: ["reason", "message"])
        return [path, diff, inputSummary, reason].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty
    }

    private func eligiblePersistentPermissionRules(
        from params: [String: CodexAppServerJSONValue]
    ) -> [String]? {
        let suggestions = params["permissionSuggestions"]?.arrayValue
            ?? params["permission_suggestions"]?.arrayValue
            ?? []
        var rules: [String] = []
        for value in suggestions {
            guard let suggestion = value.objectValue,
                  firstString(in: suggestion, keys: ["type"])?.lowercased() == "addrules",
                  firstString(in: suggestion, keys: ["behavior"])?.lowercased() == "allow",
                  firstString(in: suggestion, keys: ["destination"])?.lowercased() == "localsettings"
            else {
                continue
            }
            for ruleValue in suggestion["rules"]?.arrayValue ?? [] {
                if let rule = ruleValue.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty {
                    rules.append(rule)
                    continue
                }
                guard let object = ruleValue.objectValue,
                      let toolName = firstString(in: object, keys: ["toolName", "tool_name"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !toolName.isEmpty else {
                    continue
                }
                let content = firstString(in: object, keys: ["ruleContent", "rule_content"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                rules.append(content?.isEmpty == false ? "\(toolName)(\(content!))" : toolName)
            }
        }
        var seen: Set<String> = []
        let unique = rules.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique
    }

    private func commandSummary(params: [String: CodexAppServerJSONValue]) -> String? {
        if let command = params["command"]?.stringValue {
            return command
        }
        if let parts = params["command"]?.arrayValue?.compactMap(\.stringValue), !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
