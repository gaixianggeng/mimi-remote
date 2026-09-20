import Foundation

/// 原生 Harness 事件客户端。
///
/// 面向既有 `SessionWebSocketClient` 协议，所以 `MultiRuntimeSessionWebSocketClient`
/// 不必再要求所有实现都是 `CodexAppServerSessionWebSocketClient`。Codex guidance 的
/// 结果回调保活路径由包装器按具体类型保留，不因为改成协议类型而丢掉所有权。
///
/// ## 职责边界
///
/// 这一层只做两件事：**把 follow 的帧流投影成 AgentEvent**、**把发送意图转成原生提交**。
/// 它不持有传输连接代次——那是 `HarnessSessionRuntime` 的唯一职责（契约 D1）。
/// 这里仅持有页面观察租约，用于拒绝切换会话后迟到的 snapshot。
///
/// ## 发送为什么同步返回 Bool 而实现是异步
///
/// `SessionWebSocketClient` 的发送方法签名是同步返回 Bool，原生提交是异步的。
/// 因此这里立刻返回"已受理"，真实结果通过既有回调回传——与 Codex 客户端一致，
/// 上层不因此需要改协议。
///
/// **关键**：`responseUnknown` 必须映射成 `.uncertain`，不能映射成 `.rejected`。
/// 后者会告诉上层"没执行、可以重试"，而它可能已经执行了（契约 D4）。
@MainActor
final class HarnessSessionWebSocketClient: SessionWebSocketClient {
    let endpoint: String
    let token: String
    private(set) var sessionID: SessionID

    /// 写路径的通道。与 API 客户端共用同一个实例，不新开网络路径。
    private let submission: HarnessSubmissionController
    /// opening snapshot 的来源。生产实现走流载体；测试注入替身。
    private let fetchSnapshot: (@MainActor (String) async throws -> HarnessSnapshot)?
    /// H11 生产路径。RPC、follow、`$events` 与应答共用 API client 持有的唯一 runtime。
    private let runtime: HarnessSessionRuntime?
    /// 宿主级 pending 集合由 API client 复用；页面断开不清空其它会话的交互。
    private let interactionStore: HarnessInteractionStore?
    /// 只做恢复决策，不拥有传输或第二条 reader。
    private let recovery: HarnessRecoveryCoordinator?

    var turnDeliveryMode: TurnDeliveryMode { .direct }
    var onEvent: (@MainActor (AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendAccepted: ((ClientMessageID?) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?
    var onTurnSendOutcome: ((ClientMessageID?, TurnSendOutcome) -> Void)?
    var onApprovalDecisionFailure: ((String, String) -> Void)?
    var onUserInputResponseFailure: ((String, String, Bool) -> Void)?
    var onControlFailure: ((ControlCommandFailure) -> Void)?

    /// 本会话的原生 journal。`connect` 建立基线后非空。
    private(set) var journal: HarnessSessionJournal?
    /// assistant-stream 的结算 seq 与直播消息身份之间的唯一替换关系。
    private var settledAssistantMessageIDBySeq: [Int: MessageID] = [:]
    /// durable assistant 可能先于 end 到达；在 outcome.seq 明确前不能先造 h-seq 气泡。
    private var pendingAssistantDurableBySeq: [Int: HarnessDurableEvent] = [:]
    /// 页面观察租约。只保护异步 snapshot 提交，不创建第二套 transport manager。
    private var observationGeneration: UInt64 = 0
    /// runtime 路径的一条消费任务。底层 socket reader 仍只有 `HarnessSessionRuntime` 那一条。
    private var observationTask: Task<Void, Never>?
    private var followStreamID: String?
    private var eventsStreamID: String?
    private var runtimeGeneration: UInt64?

    init(
        endpoint: String,
        token: String,
        sessionID: SessionID,
        submission: HarnessSubmissionController,
        fetchSnapshot: (@MainActor (String) async throws -> HarnessSnapshot)? = nil,
        runtime: HarnessSessionRuntime? = nil,
        interactionStore: HarnessInteractionStore? = nil,
        recovery: HarnessRecoveryCoordinator? = nil
    ) {
        self.endpoint = endpoint
        self.token = token
        self.sessionID = sessionID
        self.submission = submission
        self.fetchSnapshot = fetchSnapshot
        self.runtime = runtime
        self.interactionStore = interactionStore
        self.recovery = recovery
    }

    // MARK: - 连接

    func connect(sessionID: SessionID) {
        connect(sessionID: sessionID, replayBufferedEvents: true)
    }

    /// 建立会话基线：开 follow 拿 opening snapshot，再把其中已有记录投影出来。
    ///
    /// 顺序不可换（契约 §5.5）：`session/page` 的 throughSeq 必须取自**本次** follow
    /// 的 snapshot.cursor，所以 follow 必须先完成。
    func connect(sessionID: SessionID, replayBufferedEvents: Bool) {
        observationTask?.cancel()
        observationGeneration &+= 1
        let generation = observationGeneration
        self.sessionID = sessionID
        onStatus?(.connecting)
        observationTask = Task { [weak self] in
            guard let self else { return }
            if self.runtime != nil {
                await self.observeRuntime(sessionID: sessionID, lease: generation)
                return
            }
            do {
                guard try await self.openBaseline(
                    sessionID: sessionID,
                    generation: generation
                ) else { return }
                guard self.observationGeneration == generation,
                      self.sessionID == sessionID else { return }
                self.onStatus?(.connected)
            } catch {
                // 连接失败如实上报。**不**返回"看起来已连上"的假状态——
                // 那会让上层以为原生通道可用。
                guard self.observationGeneration == generation,
                      self.sessionID == sessionID else { return }
                self.onStatus?(.failed(Self.describe(error)))
            }
        }
    }

    private func openBaseline(sessionID: SessionID, generation: UInt64) async throws -> Bool {
        guard let fetchSnapshot else {
            // 没有 snapshot 来源就建不了基线。显式失败而不是假装连上。
            throw HarnessTransportError.notConnected
        }
        let snapshot = try await fetchSnapshot(sessionID)
        return openBaseline(snapshot: snapshot, sessionID: sessionID, generation: generation)
    }

    /// 接受当前观察租约的 opening snapshot，并立即发布已有历史与直播前缀。
    private func openBaseline(
        snapshot: HarnessSnapshot,
        sessionID: SessionID,
        generation: UInt64
    ) -> Bool {
        guard observationGeneration == generation, self.sessionID == sessionID else { return false }
        // 冻结版本中 header.id 是 snapshot/session header 的内部 id，并不等于
        // follow request 的 address.sessionId；归属由本次观察租约和 streamId 保证。
        var fresh = HarnessSessionJournal(generation: generation)
        _ = fresh.apply(snapshot: snapshot, acceptingGeneration: generation)
        journal = fresh

        // snapshot 里已有的持久记录立刻投影：这是"中途打开"能看到历史的来源。
        for record in snapshot.records ?? [] {
            guard let event = record.event else { continue }
            for projected in HarnessPresentationProjector.project(
                durableEvent: event, sessionID: sessionID
            ) {
                onEvent?(projected)
            }
        }
        if let attempt = fresh.activeAttempt,
           let event = HarnessPresentationProjector.liveTextEvent(
               text: HarnessPresentationProjector.assistantText(from: attempt),
               attempt: attempt,
               sessionID: sessionID
           ) {
            onEvent?(event)
        }
        return true
    }

    func disconnect() {
        // 使仍在等待 snapshot 的旧观察租约立即失效。
        observationGeneration &+= 1
        observationTask?.cancel()
        observationTask = nil
        let runtime = self.runtime
        let followStreamID = self.followStreamID
        let eventsStreamID = self.eventsStreamID
        self.followStreamID = nil
        self.eventsStreamID = nil
        runtimeGeneration = nil
        if let runtime {
            Task {
                if let followStreamID { await runtime.cancelStream(streamID: followStreamID) }
                if let eventsStreamID { await runtime.cancelStream(streamID: eventsStreamID) }
            }
        }
        journal = nil
        settledAssistantMessageIDBySeq.removeAll()
        pendingAssistantDurableBySeq.removeAll()
        onStatus?(.disconnected)
    }

    // MARK: - H11 runtime 观察

    /// 同一 runtime 上按「ready → follow snapshot → 持续增量」顺序运行。
    /// 恢复协调器只决定是否重开这些订阅，不拥有第二条连接或 reader。
    private func observeRuntime(sessionID: SessionID, lease: UInt64) async {
        guard let runtime, let recovery else {
            guard isCurrentObservation(sessionID: sessionID, lease: lease) else { return }
            onStatus?(.failed(HarnessTransportError.notConnected.diagnosticSummary))
            return
        }

        while isCurrentObservation(sessionID: sessionID, lease: lease), !Task.isCancelled {
            var openedFollowID: String?
            var openedEventsID: String?
            do {
                let generation = try await runtime.connect()
                guard isCurrentObservation(sessionID: sessionID, lease: lease) else { return }
                runtimeGeneration = generation
                interactionStore?.dropStaleGeneration(generation)

                let eventsID = await runtime.nextStreamID()
                openedEventsID = eventsID
                eventsStreamID = eventsID
                try await runtime.openStream(
                    streamID: eventsID,
                    endpoint: HarnessWireEndpoint.events
                )
                try await waitForReady(
                    streamID: eventsID,
                    runtimeGeneration: generation,
                    sessionID: sessionID,
                    lease: lease
                )

                let followID = await runtime.nextStreamID()
                openedFollowID = followID
                followStreamID = followID
                try await runtime.openStream(
                    streamID: followID,
                    endpoint: HarnessWireEndpoint.sessionFollow,
                    args: HarnessFollowTarget(
                        sessionID: sessionID,
                        assistantStream: true,
                        maxMessages: 200
                    ).argsValue
                )
                let snapshot = try await waitForOpeningSnapshot(
                    streamID: followID,
                    runtimeGeneration: generation,
                    sessionID: sessionID,
                    lease: lease
                )
                guard openBaseline(
                    snapshot: snapshot,
                    sessionID: sessionID,
                    generation: lease
                ) else { return }
                recovery.recordSuccess()
                onStatus?(.connected)

                try await consumeRuntimeFrames(
                    followStreamID: followID,
                    eventsStreamID: eventsID,
                    runtimeGeneration: generation,
                    sessionID: sessionID,
                    lease: lease
                )
            } catch is CancellationError {
                await closeRuntimeStreams(
                    followStreamID: openedFollowID,
                    eventsStreamID: openedEventsID
                )
                return
            } catch {
                await closeRuntimeStreams(
                    followStreamID: openedFollowID,
                    eventsStreamID: openedEventsID
                )
                guard isCurrentObservation(sessionID: sessionID, lease: lease),
                      !Task.isCancelled else { return }
                let transport = error as? HarnessTransportError ?? .closed
                switch recovery.decide(for: transport) {
                case .retry:
                    onStatus?(.connecting)
                    guard await recovery.waitForNextAttempt() else { return }
                case .pausedInBackground:
                    onStatus?(.failed(transport.diagnosticSummary))
                    return
                case .surface(let reason):
                    onStatus?(.failed(reason))
                    return
                }
            }
        }
    }

    private func waitForReady(
        streamID: String,
        runtimeGeneration: UInt64,
        sessionID: SessionID,
        lease: UInt64
    ) async throws {
        while true {
            let frame = try await nextRuntimeFrame(
                streamID: streamID,
                runtimeGeneration: runtimeGeneration,
                sessionID: sessionID,
                lease: lease
            )
            switch frame {
            case .value(let value) where value.type == HarnessWireFrame.ready:
                return
            case .value(let value):
                try processEventsValue(value, runtimeGeneration: runtimeGeneration)
            case .carrierError(let remote):
                throw HarnessTransportError.carrier(remote)
            case .carrierEnd:
                throw HarnessTransportError.closed
            }
        }
    }

    private func waitForOpeningSnapshot(
        streamID: String,
        runtimeGeneration: UInt64,
        sessionID: SessionID,
        lease: UInt64
    ) async throws -> HarnessSnapshot {
        let frame = try await nextRuntimeFrame(
            streamID: streamID,
            runtimeGeneration: runtimeGeneration,
            sessionID: sessionID,
            lease: lease
        )
        switch frame {
        case .value(let value) where value.type == HarnessWireFrame.snapshot:
            return try Self.decode(HarnessSnapshot.self, from: value.raw, label: "opening snapshot")
        case .value(let value):
            throw HarnessTransportError.malformedResponse(
                "session/follow first frame is \(value.type), expected snapshot"
            )
        case .carrierError(let remote):
            throw HarnessTransportError.carrier(remote)
        case .carrierEnd:
            throw HarnessTransportError.closed
        }
    }

    /// 轮询的是 runtime 的有界邮箱；WebSocket 读取仍由 runtime 唯一 reader 完成。
    private func consumeRuntimeFrames(
        followStreamID: String,
        eventsStreamID: String,
        runtimeGeneration: UInt64,
        sessionID: SessionID,
        lease: UInt64
    ) async throws {
        guard let runtime else { throw HarnessTransportError.notConnected }
        while isCurrentObservation(sessionID: sessionID, lease: lease), !Task.isCancelled {
            try await ensureNoDroppedFrames(
                streamIDs: [followStreamID, eventsStreamID],
                runtime: runtime
            )
            var consumed = false
            while let carrier = await runtime.pollFrame(streamID: eventsStreamID) {
                consumed = true
                let frame = try Self.decodeCarrier(carrier)
                switch frame {
                case .value(let value):
                    try processEventsValue(value, runtimeGeneration: runtimeGeneration)
                case .carrierError(let remote):
                    throw HarnessTransportError.carrier(remote)
                case .carrierEnd:
                    throw HarnessTransportError.closed
                }
            }
            while let carrier = await runtime.pollFrame(streamID: followStreamID) {
                consumed = true
                let frame = try Self.decodeCarrier(carrier)
                switch frame {
                case .value(let value):
                    try processFollowValue(value)
                case .carrierError(let remote):
                    throw HarnessTransportError.carrier(remote)
                case .carrierEnd:
                    throw HarnessTransportError.closed
                }
            }
            guard await runtime.isConnectionCurrent(runtimeGeneration) else {
                throw HarnessTransportError.closed
            }
            if !consumed {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw CancellationError()
    }

    private func nextRuntimeFrame(
        streamID: String,
        runtimeGeneration: UInt64,
        sessionID: SessionID,
        lease: UInt64
    ) async throws -> HarnessStreamFrame {
        guard let runtime else { throw HarnessTransportError.notConnected }
        while isCurrentObservation(sessionID: sessionID, lease: lease), !Task.isCancelled {
            try await ensureNoDroppedFrames(streamIDs: [streamID], runtime: runtime)
            if let carrier = await runtime.pollFrame(streamID: streamID) {
                return try Self.decodeCarrier(carrier)
            }
            guard await runtime.isConnectionCurrent(runtimeGeneration) else {
                throw HarnessTransportError.closed
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    private func ensureNoDroppedFrames(
        streamIDs: [String],
        runtime: HarnessSessionRuntime
    ) async throws {
        for streamID in streamIDs where await runtime.droppedFrameCount(streamID: streamID) > 0 {
            // 本地缓冲丢弃让这一段的原生顺序不再完整。重开 follow 会拿到新的
            // opening snapshot 与 revision 基线，丢的那段由 snapshot + 历史补回，
            // 因此归为**可恢复**的连续性丢失，而不是解析不了的协议错误。
            throw HarnessTransportError.continuityLost("dropped frames on \(streamID)")
        }
    }

    private func processFollowValue(_ value: HarnessStreamValue) throws {
        switch value.type {
        case HarnessWireFrame.durableEvent:
            guard let event = value.raw["event"] else {
                throw HarnessTransportError.malformedResponse("durable frame is missing event")
            }
            _ = apply(durableEvent: try Self.decode(
                HarnessDurableEvent.self,
                from: event,
                label: "durable event"
            ))
        case HarnessWireFrame.assistantStream:
            let frame = try HarnessAssistantStreamFrame.decode(from: value)
            if let rejection = apply(assistantStream: frame) {
                // revision 断档 / index 不连续：重开 follow 就拿到新基线，
                // 属于可恢复的连续性丢失（契约 §2.7「跳号即载体失败，必须重开 follow」）。
                throw HarnessTransportError.continuityLost(rejection.diagnosticSummary)
            }
            if frame.type == HarnessWireAssistantFrame.end {
                settleActiveAttempt()
            }
        default:
            throw HarnessTransportError.malformedResponse(
                "unsupported session/follow value: \(value.type)"
            )
        }
    }

    private func processEventsValue(
        _ value: HarnessStreamValue,
        runtimeGeneration: UInt64
    ) throws {
        switch value.type {
        case HarnessWireFrame.ready:
            return
        case HarnessWireFrame.waterfall:
            let waterfall = try Self.decode(
                HarnessWaterfallRequest.self,
                from: value.raw,
                label: "waterfall"
            )
            if let validation = HarnessInteractionAnswer.validate(waterfall: waterfall) {
                throw HarnessTransportError.unsupportedInteraction(validation.localizedMessage)
            }
            guard let eventID = waterfall.eventId?.trimmedNonEmpty,
                  let event = waterfall.event,
                  let request = waterfall.request,
                  let targetSessionID = waterfall.threadHint.trimmedNonEmpty else {
                throw HarnessTransportError.malformedResponse("waterfall has no attributable session")
            }
            _ = interactionStore?.deliver(
                eventID: eventID,
                sessionID: targetSessionID,
                event: event,
                request: request,
                generation: runtimeGeneration
            )
            guard targetSessionID == sessionID else { return }
            if event == HarnessWireWaterfallEvent.approvalRequest {
                onEvent?(approvalEvent(
                    eventID: eventID,
                    sessionID: targetSessionID,
                    request: request,
                    generation: runtimeGeneration
                ))
            } else {
                onEvent?(questionEvent(
                    eventID: eventID,
                    sessionID: targetSessionID,
                    request: request,
                    generation: runtimeGeneration
                ))
            }
        case HarnessWireFrame.cancel:
            guard let eventID = value.raw["eventId"]?.stringValue?.trimmedNonEmpty else {
                throw HarnessTransportError.malformedResponse("interaction cancel is missing eventId")
            }
            let existing = interactionStore?.interaction(eventID: eventID)
            guard interactionStore?.cancelExternally(
                eventID: eventID,
                generation: runtimeGeneration
            ) == true, existing?.sessionID == sessionID else { return }
            let metadata = interactionMetadata(
                eventID: eventID,
                sessionID: sessionID,
                generation: runtimeGeneration
            )
            onEvent?(existing?.isQuestion == true
                ? .userInputResolved(metadata, skipped: false)
                : .approvalResolved(metadata))
        case HarnessWireFrame.responded:
            applyRespondAck(value, runtimeGeneration: runtimeGeneration)
        default:
            // `$events` 还会携带目录提示等 emit；它们不属于会话时间线，也不能伪装成用户输入。
            return
        }
    }

    /// 应用一帧应答回执。**这是撤卡的唯一依据。**
    ///
    /// 中继在"上游已接受"或"明确拒绝"时才发这一帧，并带上 eventId。在此之前的
    /// 一切（帧写出成功、socket 未报错）都只代表"提交中"，不能用来撤卡：
    /// 上游随后仍可能拒绝，届时用户会看到一个已经消失的卡片，以为决定已生效。
    private func applyRespondAck(_ value: HarnessStreamValue, runtimeGeneration: UInt64) {
        guard let eventID = value.raw["eventId"]?.stringValue?.trimmedNonEmpty else { return }
        // 迟到的旧代次回执不得结算新连接上的卡片。
        guard self.runtimeGeneration == runtimeGeneration else { return }
        guard let pending = interactionStore?.interaction(eventID: eventID) else { return }

        if value.raw["accepted"]?.boolValue == true {
            interactionStore?.resolve(eventID: eventID)
            let metadata = interactionMetadata(
                eventID: eventID,
                sessionID: pending.sessionID,
                generation: runtimeGeneration
            )
            // 归属仍按事件自己的会话判定，卡片可能属于当前未打开的会话。
            guard pending.sessionID == sessionID else { return }
            onEvent?(pending.isQuestion
                ? .userInputResolved(metadata, skipped: false)
                : .approvalResolved(metadata))
            return
        }

        // 明确拒绝：放回待应答，允许用户改条件后重试。只有**非**临时故障才这样处理，
        // 否则会把"可能已生效"的请求重新开放，诱发重复提交。
        let message = Self.remoteErrorMessage(from: value.raw["error"])
            ?? HarnessTransportError.business(
                HarnessRemoteError(code: nil, message: nil, details: nil)
            ).diagnosticSummary
        interactionStore?.releaseAfterExplicitFailure(eventID: eventID)
        publishInteractionFailure(
            eventID: eventID,
            kind: pending.isQuestion ? .question : .approval,
            message: message
        )
    }

    /// 从回执的 `error` 字段取可读文案。
    private static func remoteErrorMessage(from raw: HarnessJSONValue?) -> String? {
        guard let raw else { return nil }
        if let message = raw["message"]?.stringValue?.trimmedNonEmpty {
            return message
        }
        return raw["code"]?.stringValue?.trimmedNonEmpty
    }

    private func approvalEvent(
        eventID: String,
        sessionID: String,
        request: HarnessWaterfallPayload,
        generation: UInt64
    ) -> AgentEvent {
        .approvalRequest(
            AgentApprovalRequest(
                id: eventID,
                title: request.toolName?.trimmedNonEmpty ?? L10n.text("ui.request_approval"),
                body: request.reason?.trimmedNonEmpty,
                kind: "harness_tool",
                risk: "high",
                availableDecisions: ["accept", "decline"]
            ),
            interactionMetadata(
                eventID: eventID,
                sessionID: sessionID,
                generation: generation
            )
        )
    }

    private func questionEvent(
        eventID: String,
        sessionID: String,
        request: HarnessWaterfallPayload,
        generation: UInt64
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
        let metadata = interactionMetadata(
            eventID: eventID,
            sessionID: sessionID,
            generation: generation
        )
        return .userInputRequest(
            AgentUserInputRequest(
                id: eventID,
                threadID: sessionID,
                turnID: nil,
                itemID: eventID,
                questions: questions
            ),
            metadata
        )
    }

    private func interactionMetadata(
        eventID: String,
        sessionID: String,
        generation: UInt64
    ) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: nil,
            sessionID: sessionID,
            turnID: nil,
            itemID: eventID,
            messageID: "h-interaction-\(eventID)",
            clientMessageID: nil,
            revision: Int(truncatingIfNeeded: generation),
            createdAt: nil
        )
    }

    private func closeRuntimeStreams(
        followStreamID: String?,
        eventsStreamID: String?
    ) async {
        guard let runtime else { return }
        if let followStreamID { await runtime.cancelStream(streamID: followStreamID) }
        if let eventsStreamID { await runtime.cancelStream(streamID: eventsStreamID) }
        if self.followStreamID == followStreamID { self.followStreamID = nil }
        if self.eventsStreamID == eventsStreamID { self.eventsStreamID = nil }
    }

    private func isCurrentObservation(sessionID: SessionID, lease: UInt64) -> Bool {
        observationGeneration == lease && self.sessionID == sessionID
    }

    private static func decodeCarrier(_ carrier: HarnessCarrierFrame) throws -> HarnessStreamFrame {
        guard let decoded = try HarnessCarrierDecoder.decode(frame: carrier) else {
            throw HarnessTransportError.malformedResponse("unattributable Harness carrier frame")
        }
        return decoded.frame
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from value: HarnessJSONValue,
        label: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        } catch {
            throw HarnessTransportError.malformedResponse("\(label) is invalid: \(error)")
        }
    }

    // MARK: - 接收

    /// 应用一条 live durable 事件，投影成展示事件。
    ///
    /// 返回是否新增（false = 同 seq 重复）。重复投递是正常现象（契约 D3）：
    /// journal 按 seq 去重之后不会产生第二条气泡——这就是"流式到历史无重复"。
    @discardableResult
    func apply(durableEvent event: HarnessDurableEvent) -> Bool {
        guard var current = journal else { return false }
        let isNew = current.apply(durableEvent: event)
        journal = current
        guard isNew else { return false }
        if event.type == HarnessWireEventType.assistantMessage,
           current.activeAttempt != nil,
           let seq = event.seq {
            pendingAssistantDurableBySeq[seq] = event
            return true
        }
        publish(durableEvent: event)
        return true
    }

    private func publish(durableEvent event: HarnessDurableEvent) {
        let messageID = event.seq.flatMap { settledAssistantMessageIDBySeq[$0] }
        for projected in HarnessPresentationProjector.project(
            durableEvent: event,
            sessionID: sessionID,
            assistantMessageID: messageID
        ) {
            onEvent?(projected)
        }
    }

    /// 应用一帧 assistant-stream 直播片段。
    ///
    /// 失败（断档 / 缺 start / attempt 不符）时如实上报——不能把断档后的片段接上去。
    /// 调用方据此进入 recovery coordinator；恢复只重建观察链路，不重发写操作。
    @discardableResult
    func apply(assistantStream frame: HarnessAssistantStreamFrame) -> HarnessJournalStreamRejection? {
        guard var current = journal else { return .beforeSnapshot }
        let previousChunkCount = current.activeAttempt?.chunks.count ?? 0
        let rejection = current.apply(assistantStream: frame)
        journal = current
        if let rejection {
            onStatus?(.failed(L10n.format(
                "harness.stream_interrupted",
                rejection.diagnosticSummary
            )))
        } else if frame.type == HarnessWireAssistantFrame.chunk,
                  current.activeAttempt?.chunks.count ?? 0 > previousChunkCount,
                  frame.chunk?.type == HarnessWireChunkType.textDelta,
                  let text = frame.chunk?.text,
                  let attempt = current.activeAttempt,
                  let event = HarnessPresentationProjector.liveTextEvent(
                      text: text,
                      attempt: attempt,
                      sessionID: sessionID
                  ) {
            onEvent?(event)
        } else if frame.type == HarnessWireAssistantFrame.end,
                  let attempt = current.activeAttempt,
                  attempt.producedAssistantMessage,
                  let seq = attempt.settledSeq {
            settledAssistantMessageIDBySeq[seq] = HarnessPresentationProjector.messageID(
                attempt: attempt,
                suffix: "assistant"
            )
        }
        return rejection
    }

    /// 结算当前 attempt 并投影结果。
    ///
    /// 由流投影层在收到 `end` 帧后调用。被取消的 attempt 不会投影出助手消息
    /// （见 `HarnessPresentationProjector.project(attempt:)`）。
    func settleActiveAttempt() {
        guard var current = journal, let attempt = current.activeAttempt else { return }
        if attempt.producedAssistantMessage, let seq = attempt.settledSeq {
            settledAssistantMessageIDBySeq[seq] = HarnessPresentationProjector.messageID(
                attempt: attempt,
                suffix: "assistant"
            )
        }
        for projected in HarnessPresentationProjector.project(attempt: attempt, sessionID: sessionID) {
            onEvent?(projected)
        }
        current.retireSettledAttempt()
        journal = current
        let pending = pendingAssistantDurableBySeq
        pendingAssistantDurableBySeq.removeAll()
        for event in pending.values.sorted(by: { ($0.seq ?? -1) < ($1.seq ?? -1) }) {
            publish(durableEvent: event)
        }
    }

    // MARK: - 发送

    /// 文本输入。
    ///
    /// `clientMessageID` 给出时直接当 requestId 用——上层因此能把本地乐观记录与
    /// 服务端回显（`user/message.source.rpcId`）对上，不必依赖"下一条 turn/start
    /// 恰好属于自己"这种猜测（契约 D4）。
    @discardableResult
    func sendInput(_ text: String, clientMessageID: ClientMessageID?) -> Bool {
        guard let journal, journal.hasOpenedSnapshot else {
            // 基线未建立就发送，服务端回显无法与本地记录关联。
            onSendFailure?(clientMessageID, L10n.text("harness.session_baseline_not_ready"))
            return false
        }
        let requestID = clientMessageID ?? Self.makeRequestID()
        Task { [weak self] in
            guard let self else { return }
            let submission = await self.submission.submit(
                sessionID: self.sessionID, text: text, requestID: requestID
            )
            self.publish(submission: submission, clientMessageID: clientMessageID ?? requestID)
        }
        return true
    }

    @discardableResult
    func sendTurn(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) -> Bool {
        // 原生路径上 turn 载荷等价于其中的文本。Harness 首版只接受文本，
        // 其余输入显式拒绝而不是静默丢弃。
        let text = payload.previewText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onSendFailure?(clientMessageID, L10n.text("harness.text_input_only"))
            return false
        }
        return sendInput(text, clientMessageID: clientMessageID)
    }

    /// Harness 不支持 guidance：必须显式拒绝，**不得**当成普通 prompt 发出去。
    ///
    /// 当成 prompt 发会让一次"引导"变成一条新的用户消息，语义与用户预期不同。
    @discardableResult
    func sendGuidance(
        _ payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID?,
        expectedTurnID: TurnID
    ) -> Bool {
        onSendFailure?(clientMessageID, L10n.text("harness.guidance_unsupported"))
        return false
    }

    /// 停止当前轮次。
    ///
    /// 已读版本只有 session 级 cancel，不能提供原子 turn 条件取消。但**能确认**目标过期时
    /// 必须拒绝：`session/cancel` 停的是这个会话正在跑的轮次，一次迟到的停止 A 会停掉
    /// 之后开始的 B。契约要求如实保留"检查与取消不是原子操作"这一限制，但不因此放弃
    /// 目标校验。
    ///
    /// 判定依据是**整轮**的活跃目标（`activeAttempt` 与最近 durable turn），不是只看
    /// assistant attempt：工具运行中、两个 attempt 之间、观察尚未恢复时都可能没有
    /// activeAttempt，而会话仍有正在执行的 turn。
    @discardableResult
    func sendCtrlC(expectedTurnID: TurnID) -> Bool {
        if let currentTurnID = currentKnownTurnID() {
            guard expectedTurnID == currentTurnID else {
                // 目标已过期：这次的意图是停旧轮次，而当前是另一个轮次。
                // 按 gh-509 的语义归入 staleTarget，让调用方收敛本地运行态，
                // 而不是把它当成一次普通失败去提示重试。
                onControlFailure?(ControlCommandFailure(
                    kind: .staleTarget,
                    message: L10n.format(
                        "harness.cancel_turn_mismatch",
                        expectedTurnID,
                        currentTurnID
                    ),
                    expectedTurnID: expectedTurnID
                ))
                return false
            }
        }
        // 无法确认目标时只能发 session 级 cancel；这是非原子限制，不伪装条件取消。
        Task { [weak self] in
            guard let self else { return }
            let state = await self.submission.cancel(sessionID: self.sessionID)
            self.publish(cancelState: state)
        }
        return true
    }

    /// 当前已知的轮次身份，用于拒绝明确过期的停止目标。
    ///
    /// 取值优先级：活动 attempt 的 turn（最精确）→ 最近一条 durable `turn/start` 尚未被
    /// `turn/end` 收尾的 turn。两者都没有时返回 `nil`，表示**无法确认**——
    /// 这种情况不阻拦取消，但也不谎称已经校验过。
    private func currentKnownTurnID() -> TurnID? {
        if let turn = journal?.activeAttempt?.turn {
            return "h-turn-\(turn)"
        }
        // attempt 已结算但整轮没结束（例如正在跑工具、或等待人机应答）：
        // 这时的会话仍在执行，停止目标必须仍然可比对。
        if let turn = journal?.activeTurnNumber {
            return "h-turn-\(turn)"
        }
        return nil
    }

    /// 审批应答。clientId 仍只由 agentd 持有；移动端只提交 eventId 与 outcome。
    @discardableResult
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        let normalized: String
        switch decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "accept", "approve", "approved", "yes", HarnessWireApprovalDecision.allowedOnce:
            normalized = HarnessWireApprovalDecision.allowedOnce
        case "decline", "deny", "denied", "reject", HarnessWireApprovalDecision.rejected:
            normalized = HarnessWireApprovalDecision.rejected
        default:
            onApprovalDecisionFailure?(
                approvalID,
                HarnessInteractionAnswerError.unsupportedDecision(decision).localizedMessage
            )
            return false
        }
        do {
            let outcome = try HarnessInteractionAnswer.approvalOutcome(decision: normalized)
            return submitInteractionResponse(
                eventID: approvalID,
                outcome: outcome,
                kind: .approval
            )
        } catch let error as HarnessInteractionAnswerError {
            onApprovalDecisionFailure?(approvalID, error.localizedMessage)
            return false
        } catch {
            onApprovalDecisionFailure?(approvalID, Self.describe(error))
            return false
        }
    }

    @discardableResult
    func sendUserInputResponse(requestID: String, answers: [String: [String]]) -> Bool {
        guard let pending = interactionStore?.interaction(eventID: requestID), pending.isQuestion else {
            onUserInputResponseFailure?(
                requestID,
                L10n.text("harness.question_response_not_connected"),
                false
            )
            return false
        }
        do {
            let outcome = try HarnessInteractionAnswer.questionsOutcome(
                answers: answers,
                questions: pending.request.questions ?? []
            )
            return submitInteractionResponse(
                eventID: requestID,
                outcome: outcome,
                kind: .question
            )
        } catch let error as HarnessInteractionAnswerError {
            onUserInputResponseFailure?(requestID, error.localizedMessage, false)
            return false
        } catch {
            onUserInputResponseFailure?(requestID, Self.describe(error), false)
            return false
        }
    }

    func acknowledgeAppliedEvent(_ event: AgentEvent) {
        // 原生路径没有"应用确认"这一步：event 携带原生 seq，去重靠它而不是 ack。
    }

    private enum InteractionResponseKind: Equatable {
        case approval
        case question
    }

    private func submitInteractionResponse(
        eventID: String,
        outcome: HarnessOutcome,
        kind: InteractionResponseKind
    ) -> Bool {
        guard let runtime,
              let interactionStore,
              let generation = runtimeGeneration else {
            publishInteractionFailure(
                eventID: eventID,
                kind: kind,
                message: kind == .approval
                    ? L10n.text("harness.approval_response_not_connected")
                    : L10n.text("harness.question_response_not_connected")
            )
            return false
        }
        switch interactionStore.claim(eventID: eventID, generation: generation) {
        case .accepted:
            break
        case .settled:
            return true
        case .alreadySubmitting:
            publishInteractionFailure(
                eventID: eventID,
                kind: kind,
                message: L10n.text("harness.previous_submission_unconfirmed")
            )
            return false
        case .staleGeneration, .unknown:
            publishInteractionFailure(
                eventID: eventID,
                kind: kind,
                message: kind == .approval
                    ? L10n.text("harness.approval_response_not_connected")
                    : L10n.text("harness.question_response_not_connected")
            )
            return false
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.respond(
                    eventID: eventID,
                    outcome: outcome,
                    expectedGeneration: generation
                )
                // **写出成功 ≠ 上游已接受。** 帧写进 socket 只说明中继收到了它；
                // 中继完全可能在这之后拒绝（越权、形状非法、无 clientId）。
                // 因此这里停在 `.submitting`，卡片继续显示"提交中"，
                // 由 `applyRespondAck` 收到同 eventId 的回执才撤卡。
                guard self.runtimeGeneration == generation else {
                    interactionStore.markResponseUnknown(
                        eventID: eventID,
                        detail: HarnessTransportError.closed.diagnosticSummary
                    )
                    return
                }
            } catch {
                let message = Self.describe(error)
                if let transport = error as? HarnessTransportError,
                   transport.shouldReconnect {
                    interactionStore.markResponseUnknown(eventID: eventID, detail: message)
                } else {
                    // 只有明确业务/协议拒绝才重新开放卡片；未知结果保持锁定，禁止重发。
                    interactionStore.releaseAfterExplicitFailure(eventID: eventID)
                }
                self.publishInteractionFailure(
                    eventID: eventID,
                    kind: kind,
                    message: message
                )
            }
        }
        return true
    }

    private func publishInteractionFailure(
        eventID: String,
        kind: InteractionResponseKind,
        message: String
    ) {
        switch kind {
        case .approval:
            onApprovalDecisionFailure?(eventID, message)
        case .question:
            onUserInputResponseFailure?(eventID, message, false)
        }
    }

    // MARK: - 结果发布

    /// 把一次提交的结果映射成既有回调。
    ///
    /// 三个分支的区分是承重的：`accepted`/`rejected` 上层可以做不同的事，
    /// 而 `responseUnknown` **必须**走 `.uncertain`——那是"可能已执行"的唯一诚实表达。
    /// 映射成 `.rejected` 会诱导上层重发，从而重复执行一次写操作。
    private func publish(
        submission: HarnessSubmissionController.Submission,
        clientMessageID: ClientMessageID?
    ) {
        switch submission.state {
        case .accepted:
            onSendAccepted?(clientMessageID)
            onTurnSendOutcome?(clientMessageID, .accepted(turnID: nil))
        case .rejected(let message):
            onSendFailure?(clientMessageID, message)
            onTurnSendOutcome?(clientMessageID, .rejected(message: message))
        case .responseUnknown(let detail):
            // 不报成功，也不报"失败可重试"。
            onSendFailure?(clientMessageID, L10n.format("harness.submission_result_unknown", detail))
            onTurnSendOutcome?(clientMessageID, .uncertain(message: detail))
        case .idle, .submitting:
            break
        }
    }

    private func publish(cancelState: HarnessSubmissionController.SubmissionState) {
        switch cancelState {
        case .accepted:
            onSendAccepted?(nil)
        case .rejected(let message), .responseUnknown(let message):
            // 归入 `.other` 而不是 `.staleTarget`：这里只有一个已经本地化过的结论串，
            // 没有可判定的上游错误码。靠文案反推"目标已过期"会把措辞变化变成
            // 语义变化，而 gh-509 的 staleTarget 是需要收敛本地运行态的强结论。
            // 明确过期目标由 `sendCtrlC` 在发送前用本地轮次身份拦下（那里有确切依据）。
            onControlFailure?(ControlCommandFailure(kind: .other, message: message))
        case .idle, .submitting:
            break
        }
    }

    private static func describe(_ error: Error) -> String {
        if let transport = error as? HarnessTransportError {
            return transport.diagnosticSummary
        }
        return String(describing: error)
    }

    private static func makeRequestID() -> String {
        "h-req-\(UUID().uuidString)"
    }
}
