import Foundation

/// 宿主级 `$events` 观察者。
///
/// ## 为什么必须独立于会话页面
///
/// `$events` 是**宿主级**通道（契约 D5）：别的会话、子 Agent、Harness Web 发出的
/// 审批与追问都从这一条流下来，而且**可能在用户从未打开对应会话时到达**。
/// 把它挂在会话页面上会同时错两件事：
///
/// 1. **跨会话审批收不到。** 页面只为自己的 sessionID 发 UI 事件，别的会话的
///    交互登记进 store 之后没人展示。
/// 2. **切页面会把共享连接拆掉。** 中继规定一条移动连接只绑定一个 `$events`
///    生命周期，而取消 `$events` 会**关闭整条连接**并拒绝在同一连接上重开。
///    每换一次会话就退订一次，等于每换一次会话就重连一次，还会和后台会话订阅
///    抢占那唯一的名额。
///
/// 因此这一层由 `HarnessSessionAPIClient`（宿主）持有，生命周期与宿主一致；
/// 页面只持有自己会话的 follow 观察引用。
///
/// ## 它做什么、不做什么
///
/// 只做两件事：把瀑布登记进共享的 `HarnessInteractionStore`、把交互事件发给
/// **宿主级** 观察者（`onEvent`）。它不持有会话时间线、不建 journal、不写 UI 状态
/// ——那些仍是页面客户端与 Store 的职责。
@MainActor
final class HarnessHostEventObserver {

    /// 宿主级事件出口。与页面客户端分开：页面断开不应中断这条订阅。
    var onEvent: (@MainActor (AgentEvent) -> Void)?
    /// 宿主级连接状态。页面自己还会按 follow 上报状态，这里只用于诊断与重连调度。
    var onStatus: ((WebSocketStatus) -> Void)?
    /// 一次应答被明确拒绝。
    ///
    /// `AgentEvent` 没有"交互失败"这一态（Codex 侧同样走回调），所以拒绝原因
    /// 单独回传，由上层决定提示还是回退卡片状态。
    var onInteractionRejected: ((_ sessionID: String, _ eventID: String, _ message: String) -> Void)?

    private let runtime: HarnessSessionRuntime
    private let interactionStore: HarnessInteractionStore
    private let recovery: HarnessRecoveryCoordinator

    /// `$events` 订阅的 streamId。整个宿主只有这一个。
    private(set) var eventsStreamID: String?
    private var consumeTask: Task<Void, Never>?
    private var runtimeGeneration: UInt64?
    /// 宿主代次。start/stop 各推进一次，用于拒绝迟到回调。
    private var generation: UInt64 = 0

    init(
        runtime: HarnessSessionRuntime,
        interactionStore: HarnessInteractionStore,
        recovery: HarnessRecoveryCoordinator
    ) {
        self.runtime = runtime
        self.interactionStore = interactionStore
        self.recovery = recovery
    }

    /// 开始观察。幂等：已经在观察时不重复开订阅。
    ///
    /// 幂等是承重的——中继拒绝同一连接上的第二个 `$events`，重复调用会让宿主
    /// 拿一个必然失败的请求去换掉一条正在工作的订阅。
    /// 但幂等只应对"确实还在跑"的任务：观察循环退出时必须清掉自己的标记，
    /// 否则一次不可重试的失败之后，宿主再也起不来（标记还在，判断成重复启动）。
    func start() {
        guard consumeTask == nil else { return }
        generation &+= 1
        let lease = generation
        consumeTask = Task { [weak self] in
            await self?.observe(lease: lease)
            // 按自身租约清理：只有这个任务仍是当前任务时才清。
            // 无条件清会踩掉 `start()` 刚建的新任务，让新订阅再也无人管理。
            await self?.finishObservation(lease: lease)
        }
    }

    /// 观察循环结束后的收尾。只清属于自己的运行标记。
    private func finishObservation(lease: UInt64) {
        guard generation == lease else { return }
        consumeTask = nil
        eventsStreamID = nil
        runtimeGeneration = nil
    }

    /// 停止观察并退订。
    ///
    /// 只在宿主退役（切 host、凭据失效、App 关闭）时调用。**页面切换不得调用它**：
    /// 那正是"`$events` 绑在会话页面上"要修掉的形态。
    func stop() async {
        generation &+= 1
        consumeTask?.cancel()
        consumeTask = nil
        let streamID = eventsStreamID
        eventsStreamID = nil
        runtimeGeneration = nil
        if let streamID {
            await runtime.cancelStream(streamID: streamID)
        }
    }

    // MARK: - 观察循环

    private func observe(lease: UInt64) async {
        while isCurrent(lease: lease), !Task.isCancelled {
            var openedStreamID: String?
            do {
                let connectionGeneration = try await runtime.connect()
                guard isCurrent(lease: lease) else { return }
                runtimeGeneration = connectionGeneration
                // 旧代次的卡片不得替新连接做决定；上游会在新连接上重投仍 pending 的。
                interactionStore.dropStaleGeneration(connectionGeneration)

                let streamID = await runtime.nextStreamID()
                openedStreamID = streamID
                eventsStreamID = streamID
                try await runtime.openStream(
                    streamID: streamID,
                    endpoint: HarnessWireEndpoint.events
                )
                try await waitForReady(
                    streamID: streamID,
                    runtimeGeneration: connectionGeneration,
                    lease: lease
                )
                recovery.recordSuccess()
                onStatus?(.connected)

                try await consume(
                    streamID: streamID,
                    runtimeGeneration: connectionGeneration,
                    lease: lease
                )
            } catch is CancellationError {
                return
            } catch {
                await closeStream(openedStreamID)
                guard isCurrent(lease: lease), !Task.isCancelled else { return }
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
        lease: UInt64
    ) async throws {
        while true {
            let frame = try await nextFrame(
                streamID: streamID,
                runtimeGeneration: runtimeGeneration,
                lease: lease
            )
            switch frame {
            case .value(let value) where value.type == HarnessWireFrame.ready:
                return
            case .value(let value):
                try apply(value)
            case .carrierError(let remote):
                throw HarnessTransportError.carrier(remote)
            case .carrierEnd:
                throw HarnessTransportError.closed
            }
        }
    }

    private func consume(
        streamID: String,
        runtimeGeneration: UInt64,
        lease: UInt64
    ) async throws {
        while isCurrent(lease: lease), !Task.isCancelled {
            let frame = try await nextFrame(
                streamID: streamID,
                runtimeGeneration: runtimeGeneration,
                lease: lease
            )
            switch frame {
            case .value(let value):
                try apply(value)
            case .carrierError(let remote):
                throw HarnessTransportError.carrier(remote)
            case .carrierEnd:
                throw HarnessTransportError.closed
            }
        }
        throw CancellationError()
    }

    /// 从 runtime 的有界邮箱取一帧。读 socket 仍由 runtime 的唯一 reader 完成。
    private func nextFrame(
        streamID: String,
        runtimeGeneration: UInt64,
        lease: UInt64
    ) async throws -> HarnessStreamFrame {
        while isCurrent(lease: lease), !Task.isCancelled {
            // 丢帧检查与页面 follow 同等重要：待处理集合的状态完整性依赖**每一帧**。
            // 漏掉一条 waterfall 会让用户看不到一次授权请求；漏掉一条 cancel 或回执
            // 会让卡片停在错误状态。因此这里不能"继续消费一个已经不完整的状态"，
            // 必须如实失败并让上层重开订阅。
            if await runtime.droppedFrameCount(streamID: streamID) > 0 {
                throw HarnessTransportError.continuityLost("dropped frames on \(streamID)")
            }
            if let carrier = await runtime.pollFrame(streamID: streamID) {
                guard let decoded = try HarnessCarrierDecoder.decode(frame: carrier) else {
                    // 无 streamId 的帧无法归属。如实失败并让上层重开，不静默吞掉。
                    throw HarnessTransportError.malformedResponse("unattributable Harness carrier frame")
                }
                return decoded.frame
            }
            guard await runtime.isConnectionCurrent(runtimeGeneration) else {
                throw HarnessTransportError.closed
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    private func isCurrent(lease: UInt64) -> Bool {
        generation == lease
    }

    private func closeStream(_ streamID: String?) async {
        guard let streamID else { return }
        await runtime.cancelStream(streamID: streamID)
    }

    // MARK: - 帧处理

    /// 处理一帧 `$events` 值。
    ///
    /// 不做会话归属过滤——**这是这一层与页面客户端的根本区别**。瀑布按事件自身的
    /// `agentId` 归属（契约 §2.8：Harness 的 agent 注册表 id 等于会话 id），
    /// 登记与展示都按那个身份走，而不是按"当前打开的是哪个会话"。
    private func apply(_ value: HarnessStreamValue) throws {
        switch value.type {
        case HarnessWireFrame.ready:
            return

        case HarnessWireFrame.waterfall:
            let waterfall = try Self.decode(HarnessWaterfallRequest.self, from: value.raw, label: "waterfall")
            if let validation = HarnessInteractionAnswer.validate(waterfall: waterfall) {
                throw HarnessTransportError.unsupportedInteraction(validation.localizedMessage)
            }
            guard let eventID = waterfall.eventId?.trimmedNonEmpty,
                  let event = waterfall.event,
                  let request = waterfall.request,
                  let targetSessionID = waterfall.threadHint.trimmedNonEmpty,
                  let generation = runtimeGeneration else {
                throw HarnessTransportError.malformedResponse("waterfall has no attributable session")
            }
            _ = interactionStore.deliver(
                eventID: eventID,
                sessionID: targetSessionID,
                event: event,
                request: request,
                generation: generation
            )
            let context = HarnessInteractionProjection.Context(
                eventID: eventID,
                sessionID: targetSessionID,
                generation: generation
            )
            onEvent?(event == HarnessWireWaterfallEvent.approvalRequest
                ? HarnessInteractionProjection.approvalRequest(context, request: request)
                : HarnessInteractionProjection.questionRequest(context, request: request))

        case HarnessWireFrame.cancel:
            guard let eventID = value.raw["eventId"]?.stringValue?.trimmedNonEmpty,
                  let generation = runtimeGeneration else {
                throw HarnessTransportError.malformedResponse("interaction cancel is missing eventId")
            }
            let existing = interactionStore.interaction(eventID: eventID)
            guard interactionStore.cancelExternally(eventID: eventID, generation: generation) else {
                return
            }
            guard let existing else { return }
            onEvent?(HarnessInteractionProjection.resolved(
                HarnessInteractionProjection.Context(
                    eventID: eventID,
                    sessionID: existing.sessionID,
                    generation: generation
                ),
                isQuestion: existing.isQuestion
            ))

        case HarnessWireFrame.responded:
            applyRespondAck(value)

        default:
            // `$events` 还携带目录提示等 emit；它们不属于会话时间线。
            return
        }
    }

    /// 应用一帧应答回执。**这是撤卡的唯一依据。**
    ///
    /// 中继在"上游已接受 / 明确拒绝 / 已由他端终结 / 结果未知"时发这一帧。
    /// 四种结论的动作**互不相同**，因此不能只看一个布尔值：
    ///
    /// - 接受 → 撤卡；
    /// - 他端终结 → 撤卡，但不声称本端回答获胜；
    /// - 明确拒绝 → 放回，允许用户改条件后重试；
    /// - 结果未知 → **保持锁定**，不重发、也不当成"没执行"。这一点最关键：
    ///   上游可能已经接受了这次应答，只是响应丢了；判成可重试会重复执行一次审批。
    private func applyRespondAck(_ value: HarnessStreamValue) {
        guard let eventID = value.raw["eventId"]?.stringValue?.trimmedNonEmpty,
              let generation = runtimeGeneration,
              let pending = interactionStore.interaction(eventID: eventID) else { return }

        let context = HarnessInteractionProjection.Context(
            eventID: eventID,
            sessionID: pending.sessionID,
            generation: generation
        )
        let outcome = value.raw["outcome"]?.stringValue?.trimmedNonEmpty

        switch outcome {
        case HarnessRespondOutcome.accepted, HarnessRespondOutcome.settled:
            // 两者都终结这张卡。`settled` 只额外说明"不是本端回答赢了"，
            // 但对卡片而言结果相同：不再可应答。
            interactionStore.resolve(eventID: eventID)
            onEvent?(HarnessInteractionProjection.resolved(context, isQuestion: pending.isQuestion))
            return

        case HarnessRespondOutcome.rejected:
            // 明确拒绝 = 没生效，放回让用户重试。
            interactionStore.releaseAfterExplicitFailure(eventID: eventID)
            onInteractionRejected?(pending.sessionID, eventID, Self.respondErrorMessage(value))

        case HarnessRespondOutcome.unknown:
            // 结果未知：锁定并等待对账/重投。这里**不**调用
            // `releaseAfterExplicitFailure`，否则一次可能已生效的审批会被重复执行。
            interactionStore.markResponseUnknown(
                eventID: eventID,
                detail: Self.respondErrorMessage(value)
            )
            onInteractionRejected?(pending.sessionID, eventID, Self.respondErrorMessage(value))

        default:
            // 认不出的结论不猜。保持现状（仍是 submitting），并如实提示——
            // 猜"接受"会撤掉一张可能还待处理的卡，猜"拒绝"会诱发重复提交。
            onInteractionRejected?(pending.sessionID, eventID, Self.respondErrorMessage(value))
        }
    }

    /// 从回执里取可读的错误文案。
    private static func respondErrorMessage(_ value: HarnessStreamValue) -> String {
        value.raw["error"]?["message"]?.stringValue?.trimmedNonEmpty
            ?? value.raw["error"]?["code"]?.stringValue?.trimmedNonEmpty
            ?? L10n.text("harness.interaction_response_rejected")
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
