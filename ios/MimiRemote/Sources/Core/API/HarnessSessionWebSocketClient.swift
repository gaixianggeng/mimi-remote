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
    /// 发送前应用模型/档位选择。生产走原生 `session/selectModel`。
    private let selectModel: (@MainActor (String, String, String, String?) async throws -> Void)?
    /// 建立基线后把本次 follow 的 `snapshot.cursor` 交给宿主。
    ///
    /// `session/page` 的 `throughSeq` 只能取自**本次** follow 的 opening snapshot，
    /// 因此这个值必须由建立基线的一侧上报，历史读取侧不能自己猜。
    private let reportSnapshotCursor: (@MainActor (SessionID, Int) -> Void)?

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
    /// 本页面唯一持有的订阅：自己会话的 `session/follow`。
    ///
    /// **没有 `eventsStreamID`。** `$events` 是宿主级通道，由 `HarnessHostEventObserver`
    /// 独占；页面再开一条会被中继拒绝，退订还会关闭整条共享连接。
    private var followStreamID: String?
    private var runtimeGeneration: UInt64?

    init(
        endpoint: String,
        token: String,
        sessionID: SessionID,
        submission: HarnessSubmissionController,
        fetchSnapshot: (@MainActor (String) async throws -> HarnessSnapshot)? = nil,
        runtime: HarnessSessionRuntime? = nil,
        interactionStore: HarnessInteractionStore? = nil,
        recovery: HarnessRecoveryCoordinator? = nil,
        selectModel: (@MainActor (String, String, String, String?) async throws -> Void)? = nil,
        reportSnapshotCursor: (@MainActor (SessionID, Int) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.token = token
        self.sessionID = sessionID
        self.submission = submission
        self.fetchSnapshot = fetchSnapshot
        self.runtime = runtime
        self.interactionStore = interactionStore
        self.recovery = recovery
        self.selectModel = selectModel
        self.reportSnapshotCursor = reportSnapshotCursor
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

        // 把本次 follow 的 snapshot 游标交给宿主：`session/page` 的 throughSeq 只能是它。
        if let cursor = fresh.snapshotCursor {
            reportSnapshotCursor?(sessionID, cursor)
        }

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

    /// 释放本页面的观察。
    ///
    /// **只退订自己会话的 follow。** 页面的 pending 交互不属于页面（契约 D5）：
    /// 登记在宿主级 store 里，离开页面不等于用户放弃了那次授权请求。
    /// `$events` 同样不动——它归宿主，退订它会关闭整条共享连接。
    func disconnect() {
        // 使仍在等待 snapshot 的旧观察租约立即失效。
        observationGeneration &+= 1
        observationTask?.cancel()
        observationTask = nil
        let runtime = self.runtime
        let followStreamID = self.followStreamID
        self.followStreamID = nil
        runtimeGeneration = nil
        if let runtime, let followStreamID {
            Task {
                await runtime.cancelStream(streamID: followStreamID)
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
            do {
                let generation = try await runtime.connect()
                guard isCurrentObservation(sessionID: sessionID, lease: lease) else { return }
                runtimeGeneration = generation

                // **不在这里开 `$events`。** 它是宿主级通道，由 `HarnessSessionAPIClient`
                // 的唯一观察者持有（见 `HarnessHostEventObserver`）。页面各开一条会被中继
                // 拒绝（一条移动连接只绑定一个 `$events`），而页面退订会关闭整条共享连接
                // 并波及其它会话的订阅。
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
                    runtimeGeneration: generation,
                    sessionID: sessionID,
                    lease: lease
                )
            } catch is CancellationError {
                await closeFollowStream(openedFollowID)
                return
            } catch {
                await closeFollowStream(openedFollowID)
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
        runtimeGeneration: UInt64,
        sessionID: SessionID,
        lease: UInt64
    ) async throws {
        guard let runtime else { throw HarnessTransportError.notConnected }
        while isCurrentObservation(sessionID: sessionID, lease: lease), !Task.isCancelled {
            try await ensureNoDroppedFrames(streamIDs: [followStreamID], runtime: runtime)
            var consumed = false
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

    /// 退订本页面的 follow。`$events` 不在这里——它归宿主。
    private func closeFollowStream(_ streamID: String?) async {
        guard let runtime, let streamID else { return }
        await runtime.cancelStream(streamID: streamID)
        if self.followStreamID == streamID { self.followStreamID = nil }
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
        // durable 用户回显是对账的**权威事实**：`source.rpcId` 就是提交时的 requestId。
        // 提交响应丢失（`.responseUnknown`）时，这条回显证明那次提交其实已经落到上游，
        // 必须据此解锁——否则该会话会被永久冻结，用户看到自己的消息和回复都在，
        // 下一条却仍提示"上一次提交尚未确认"，而且被误报成"没执行、可重试"。
        //
        // 顺序无关：回显先到、HTTP 之后才失败时，`resolveAfterReconciliation` 只在
        // 仍处 `.responseUnknown` 时改写状态，已经确认过的不会被降回去。
        if event.type == HarnessWireEventType.userMessage,
           let requestID = event.data?["source"]?["rpcId"]?.stringValue?.trimmedNonEmpty {
            submission.resolveAfterReconciliation(requestID: requestID)
        }
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
                  let attempt = current.activeAttempt,
                  let chunk = frame.chunk {
            // 正文、推理、工具三类增量各有自己的展示通道。**只发正文**会让模型
            // 思考或跑工具时界面看起来像停住了——那正是"处理中没有进度"的来源。
            switch chunk.type {
            case HarnessWireChunkType.textDelta:
                if let text = chunk.text,
                   let event = HarnessPresentationProjector.liveTextEvent(
                       text: text, attempt: attempt, sessionID: sessionID
                   ) {
                    onEvent?(event)
                }
            case HarnessWireChunkType.reasoningDelta:
                if let text = chunk.text, !text.isEmpty,
                   let event = HarnessPresentationProjector.liveReasoningEvent(
                       text: text, attempt: attempt, sessionID: sessionID
                   ) {
                    onEvent?(event)
                }
            case HarnessWireChunkType.blockStart where chunk.blockType == "tool-call":
                // 工具开始：状态是"运行中"。参数还没生成完，但用户已经该看到它了。
                if let event = HarnessPresentationProjector.toolActivityEvent(
                    HarnessToolActivity(
                        blockIndex: chunk.index ?? -1,
                        toolName: chunk.name,
                        argumentsJSON: "",
                        isComplete: false
                    ),
                    attempt: attempt,
                    sessionID: sessionID,
                    isFinished: false
                ) {
                    onEvent?(event)
                }
            case HarnessWireChunkType.toolCallDelta:
                // 参数增量：拼接后才是完整 JSON（契约 §2.7）。这里只用来保持
                // "还在动"的进度感，不解析参数、也不拿它拼标题。
                if let event = HarnessPresentationProjector.toolActivityEvent(
                    HarnessToolActivity(
                        blockIndex: chunk.index ?? -1,
                        toolName: attempt.toolName(atBlockIndex: chunk.index ?? -1),
                        argumentsJSON: "",
                        isComplete: false
                    ),
                    attempt: attempt,
                    sessionID: sessionID,
                    isFinished: false
                ) {
                    onEvent?(event)
                }
            case HarnessWireChunkType.blockEnd:
                // 参数生成结束 ≠ 工具执行结束。这里不标完成；真正的完成由
                // durable `tool/result` 决定，否则用户会看到一个"已完成"却仍在跑的工具。
                break
            default:
                break
            }
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

    /// 发送前先落地本次的模型与推理档位选择。
    ///
    /// 只取文本就发是有问题的：用户在已存在的会话里换了模型，界面看起来接受了，
    /// 实际请求仍用服务端上一次的配置。`selectModel` 只在创建/恢复会话时调用过，
    /// 覆盖不到后续每一次发送。
    ///
    /// 选择失败**不发 prompt**：把模型选择失败当成"用默认模型继续"会让用户以为
    /// 换的模型生效了。
    private func applyTurnOptions(
        _ options: CodexAppServerTurnOptions,
        clientMessageID: ClientMessageID?
    ) async -> Bool {
        guard let model = options.model?.trimmedNonEmpty,
              let provider = options.modelProvider?.trimmedNonEmpty else {
            // 没有显式选择就沿用服务端当前配置；这不是失败。
            return true
        }
        guard let selectModel else {
            onSendFailure?(clientMessageID, L10n.text("harness.model_selection_unsupported"))
            return false
        }
        do {
            try await selectModel(sessionID, provider, model, options.reasoningEffort?.rawValue)
            return true
        } catch {
            onSendFailure?(
                clientMessageID,
                L10n.format("harness.model_selection_failed", Self.describe(error))
            )
            return false
        }
    }

    /// 原生路径的发送入口。
    ///
    /// 两件事必须在这里做完，缺一个就会静默改变用户意图：
    ///
    /// 1. **非文本输入显式拒绝。** `previewText` 对图片/文件给出的是**本地化占位文案**
    ///    （如「[图片]」），把它当 prompt 发出去等于伪造了一条用户消息，附件却被丢掉。
    /// 2. **先应用本次模型与档位选择**，选择失败就不发 prompt。
    @discardableResult
    func sendTurn(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) -> Bool {
        let unsupported = payload.input.filter {
            if case .text = $0 { return false }
            return true
        }
        guard unsupported.isEmpty else {
            // 认不出的输入不猜、不降级成占位文本。附件在原生路径上尚未实现。
            onSendFailure?(clientMessageID, L10n.text("harness.text_input_only"))
            return false
        }
        let text = payload.textPrompt
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onSendFailure?(clientMessageID, L10n.text("harness.text_input_only"))
            return false
        }
        guard let journal, journal.hasOpenedSnapshot else {
            onSendFailure?(clientMessageID, L10n.text("harness.session_baseline_not_ready"))
            return false
        }

        let requestID = clientMessageID ?? Self.makeRequestID()
        let options = payload.options
        Task { [weak self] in
            guard let self else { return }
            // 选择失败不带 prompt 下发：那会让用户以为换的模型生效了。
            guard await self.applyTurnOptions(options, clientMessageID: clientMessageID) else { return }
            let submission = await self.submission.submit(
                sessionID: self.sessionID, text: text, requestID: requestID
            )
            self.publish(submission: submission, clientMessageID: clientMessageID ?? requestID)
        }
        return true
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
        // 没发出去的提交不能被报成"上游拒绝了它"。用户的下一步是**对账**，
        // 而不是重试一条他还没发过的消息。
        if submission.blockReason == .previousSubmissionUnconfirmed {
            let message = L10n.text("harness.previous_submission_unconfirmed")
            onSendFailure?(clientMessageID, message)
            onTurnSendOutcome?(clientMessageID, .uncertain(message: message))
            return
        }
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
