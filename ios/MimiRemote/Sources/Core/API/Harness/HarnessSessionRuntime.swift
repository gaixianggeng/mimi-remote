import Foundation

/// 一个 host/runtime 的原生 Harness 运行时（H04 基础部分）。
///
/// 职责严格限定在传输编排，不含任何 UI 状态：
/// - **连接代次**：一次连接对应一个代次。代次一变，旧连接上迟到的帧立即失去归属，
///   不会被当成当前会话的内容。切 host 就是一次代次更替。
/// - **在途请求**：RPC 以 rpcId 登记，响应回来前可观测；响应与请求对不上号时如实
///   记录，而不是张冠李戴。
/// - **单 reader**：整条连接只有一个读循环。多开读循环会让帧序错乱，而 seq/revision
///   的连续性正是判断"要不要重开 follow"的依据。
/// - **写入串行**：actor 隔离天然串行，不需要额外加锁。
/// - **有限缓冲**：每个订阅一个定长环形缓冲。溢出丢最旧并计数——静默丢帧会让客户端
///   以为流是连续的。
/// - **可取消**：`shutdown()` 幂等，取消 reader 与心跳。
///
/// clientId **不在客户端保存**：中继已经把它剔除（ready 只下发 `{"type":"ready"}`），
/// 应答要用哪个 clientId 由中继自己持有。这里连防御性地存一下都不做，只在 ready 帧
/// 真的带了 clientId 时记一条诊断。
actor HarnessSessionRuntime {

    // MARK: - 配置

    struct Configuration: Equatable {
        /// agentd 基址。移动端只知道 agentd，不知道 Harness 地址。
        var endpoint: String
        var token: String
        /// 每个订阅的缓冲容量。溢出丢最旧并计数。
        var bufferCapacity: Int = 256
        /// 心跳周期。半开链路只有主动探测才能发现。
        var pingInterval: Duration = .seconds(30)
        /// 诊断保留条数上限。诊断本身也不能无限增长。
        var diagnosticCapacity: Int = 128

        static func == (lhs: Configuration, rhs: Configuration) -> Bool {
            lhs.endpoint == rhs.endpoint
                && lhs.token == rhs.token
                && lhs.bufferCapacity == rhs.bufferCapacity
                && lhs.pingInterval == rhs.pingInterval
                && lhs.diagnosticCapacity == rhs.diagnosticCapacity
        }
    }

    /// 一次连接用到的两条通道。切 host 时整体替换。
    struct TransportPair {
        let rpc: HarnessRPCTransport
        let stream: HarnessStreamTransport
    }

    // MARK: - 观测类型

    /// 连接恢复动作。
    ///
    /// 只有链路层失败才允许重连。业务失败、策略拒绝、协议缺陷重连多少次都是同一个结论。
    enum RecoveryAction: Equatable {
        case reconnect
        case surfaceOnly
    }

    /// 传输层诊断。保留原生身份字段，便于把"哪条会话的第几个 seq/revision"说清楚。
    enum Diagnostic: Equatable {
        /// 缓冲溢出：客户端读得比上游推得慢。丢了几帧必须说出来。
        case slowConsumer(streamID: String, dropped: Int)
        /// 帧没有 streamId 或载体 type 认不出：无法归属。
        case unattributableFrame(carrierType: String?)
        /// 帧归属到一个当前代次里不存在的订阅（多半是上一代的迟到帧）。
        case staleFrame(streamID: String)
        /// 认不出的安全交互：移动端无法为它构造合法应答。
        case unsupportedInteraction(streamID: String, event: String)
        /// ready 帧带了 clientId：客户端不保存它，但要记录这次违反约定的下行。
        case unexpectedClientID(streamID: String)
        /// 响应 rpcId 与在途请求不符。
        case unattributedResponse(rpcId: String)
        /// 链路层失败。
        case transport(HarnessTransportError)

        var summary: String {
            switch self {
            case .slowConsumer(let streamID, let dropped):
                return "slow-consumer:\(streamID):dropped=\(dropped)"
            case .unattributableFrame(let carrierType):
                return "unattributable-frame:\(carrierType ?? "nil")"
            case .staleFrame(let streamID):
                return "stale-frame:\(streamID)"
            case .unsupportedInteraction(let streamID, let event):
                return "unsupported-interaction:\(streamID):\(event)"
            case .unexpectedClientID(let streamID):
                return "unexpected-client-id:\(streamID)"
            case .unattributedResponse(let rpcId):
                return "unattributed-response:\(rpcId)"
            case .transport(let error):
                return "transport:\(error.diagnosticSummary)"
            }
        }
    }

    /// 一帧里的原生身份字段。
    ///
    /// 抽出来是为了让"原生 seq/revision/attemptId/eventId 被保留"成为可断言的事实，
    /// 而不是注释里的承诺。
    struct FrameIdentity: Equatable {
        var carrierType: String?
        var frameType: String?
        var eventID: String?
        var eventType: String?
        var seq: Int?
        var revision: Int?
        var attemptID: String?
    }

    // MARK: - 状态

    private var configuration: Configuration
    private var rpcTransport: HarnessRPCTransport
    private var streamTransport: HarnessStreamTransport

    /// 连接代次。任何代次更替都会让旧连接上的帧失去归属。
    private(set) var connectionGeneration: UInt64 = 0
    private var isConnected = false
    /// ready 帧所在代次。只记代次，不记 clientId。
    private(set) var readyGeneration: UInt64?

    private struct Subscription {
        var endpoint: String
        var generation: UInt64
        var buffer: HarnessStreamBuffer
        /// 已收到载体 end。此后不再收新帧，但必须等消费者读走 end 才真正删除。
        var isEnded = false
    }

    private var subscriptions: [String: Subscription] = [:]
    private(set) var inFlightRPCIDs: Set<String> = []
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var recoveryAction: RecoveryAction = .surfaceOnly

    private var readerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// 在途建连。合并在途请求，避免同一连接出现两个 reader 与两个心跳。
    private var connectTask: Task<UInt64, Error>?
    /// 在途建连的序号，用于"只清自己那一次"。
    private var connectSequence: UInt64 = 0
    private var rpcSequence: UInt64 = 0
    private var streamSequence: UInt64 = 0

    init(configuration: Configuration, transports: TransportPair) {
        self.configuration = configuration
        self.rpcTransport = transports.rpc
        self.streamTransport = transports.stream
    }

    // MARK: - 连接

    /// 建立连接并开启新代次。已连接时是空操作。
    ///
    /// ## 为什么必须合并在途建连
    ///
    /// actor 只保证同步片段互斥，**不能**让跨越 `await` 的整个流程变成原子操作。
    /// 宿主观察器与页面观察器都会调这个入口：两者可能都看到 `isConnected == false`，
    /// 都进入 `streamTransport.connect()`，回来时各自推进一次代次并重启 reader——
    /// 于是同一个连接上出现两个 reader 与两个心跳，帧被两条 reader 抢。
    ///
    /// ## 为什么建连结果要绑定发起时的生命周期
    ///
    /// `streamTransport.connect()` 是挂起点。等待期间 host 可能已切走、或连接已退役；
    /// 旧调用回来后若无条件写 `isConnected = true`，就**复活了一个已经退役的状态**，
    /// 而 transport 早已属于上一代。因此这里比对发起时的生命周期标识，
    /// 不一致就丢弃结果并释放资源，不发布在线状态。
    @discardableResult
    func connect() async throws -> UInt64 {
        if isConnected { return connectionGeneration }

        // 已有一次建连在途：等它，并返回**它产生的代次**。
        // 返回自己当时读到的 `connectionGeneration` 是错的——那时它还没被推进，
        // 调用方会拿到一个不属于任何连接的旧值。
        if let inFlight = connectTask {
            return try await inFlight.value
        }

        // 生命周期标识：任何退役都会推进它，用来判断"这次建连还算不算数"。
        let lifecycle = connectionGeneration
        connectSequence &+= 1
        let sequence = connectSequence
        let task = Task { [weak self] () throws -> UInt64 in
            guard let self else { throw HarnessTransportError.cancelled }
            return try await self.performConnect(lifecycle: lifecycle)
        }
        connectTask = task
        defer {
            // 只清自己那一次：期间可能有新调用已经登记了新的在途任务。
            if connectSequence == sequence { connectTask = nil }
        }
        return try await task.value
    }

    /// 真正执行一次建连。抽出来是为了让"在途任务返回它产生的代次"成为可能——
    /// 合并在途请求时，等待者必须拿到同一个结果，而不是各自再算一遍。
    private func performConnect(lifecycle: UInt64) async throws -> UInt64 {
        do {
            try await streamTransport.connect()
        } catch let error as HarnessTransportError {
            record(.transport(error))
            recoveryAction = Self.action(for: error)
            throw error
        }

        // 等待期间发生过退役（切 host / 断连）：这次建连属于上一代，丢弃。
        // 不能写 isConnected——那会让旧调用的迟到结果复活已退役的状态。
        guard connectionGeneration == lifecycle else {
            await streamTransport.close()
            throw HarnessTransportError.closed
        }

        connectionGeneration &+= 1
        isConnected = true
        readyGeneration = nil
        startReader(generation: connectionGeneration)
        startHeartbeat(generation: connectionGeneration)
        return connectionGeneration
    }

    /// 切换到另一个 host/runtime。
    ///
    /// 先拆旧连接再换配置：顺序反过来会出现"配置已是新 host、连接还是旧 host"的窗口，
    /// 这个窗口里发出的请求会带着新 token 打到旧 host 上。
    func switchHost(to configuration: Configuration, transports: TransportPair) async {
        await teardown(recordReason: nil)
        self.configuration = configuration
        self.rpcTransport = transports.rpc
        self.streamTransport = transports.stream
    }

    /// 幂等关闭。
    func shutdown() async {
        await teardown(recordReason: nil)
    }

    private func teardown(recordReason: HarnessTransportError?) async {
        // 代次先自增：任何仍在途的旧帧从这一刻起就失去归属。
        // 在途建连也据此判断自己已失效（见 `connect`）。
        connectionGeneration &+= 1
        isConnected = false
        readyGeneration = nil
        readerTask?.cancel()
        readerTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let recordReason {
            record(.transport(recordReason))
            // 链路层失败才允许重连；分类在这里落定，调用方不必自己再判一遍。
            recoveryAction = Self.action(for: recordReason)
        }
        subscriptions.removeAll()
        inFlightRPCIDs.removeAll()
        await streamTransport.close()
    }

    private func startReader(generation: UInt64) {
        readerTask?.cancel()
        readerTask = Task { [weak self] in
            await self?.readLoop(generation: generation)
        }
    }

    /// 唯一的读循环。
    ///
    /// 每条退出路径都必须先确认自己仍是当前代次，再动连接级状态。
    ///
    /// 为什么这一条是承重的：`switchHost` 会先 `readerTask.cancel()` 再 `close()` 旧传输。
    /// cancel 唤不醒阻塞在 `receive()` 上的续体，真正唤醒它的是 `close()`——于是旧 reader
    /// 会在**新连接可能已经建立之后**才恢复执行，拿到 `nil` 或一个错误。若此时无条件
    /// `teardown`，它会把代次再推一位、清空 `subscriptions`，把新 host 刚建立的订阅一并抹掉。
    /// 契约 §5.1 要求旧代次的 Task 回调不得覆盖新主机或新连接，这里就是那个落点。
    private func readLoop(generation: UInt64) async {
        while !Task.isCancelled {
            guard generation == connectionGeneration else { return }
            do {
                guard let frame = try await streamTransport.receive() else {
                    await teardownIfCurrent(generation: generation, recordReason: nil)
                    return
                }
                dispatch(frame, generation: generation)
            } catch let error as HarnessTransportError {
                await teardownIfCurrent(generation: generation, recordReason: error)
                return
            } catch {
                await teardownIfCurrent(generation: generation, recordReason: .closed)
                return
            }
        }
    }

    /// 只有仍属于当前代次时才拆连接。
    ///
    /// 陈旧 reader 直接退出：它持有的连接早已被 `switchHost` / `teardown` 关掉，
    /// 没有遗留资源需要它来释放；再拆一次只会误伤新代次。
    private func teardownIfCurrent(generation: UInt64, recordReason: HarnessTransportError?) async {
        guard generation == connectionGeneration else { return }
        await teardown(recordReason: recordReason)
    }

    private func startHeartbeat(generation: UInt64) {
        heartbeatTask?.cancel()
        let interval = configuration.pingInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                guard await self.isCurrent(generation: generation) else { return }
                do {
                    try await self.pingTransport()
                } catch let error as HarnessTransportError {
                    // ping 是挂起点：等待期间 runtime 可能已经重建连接。迟到的失败
                    // 只能拆**它自己那一代**，否则会把新连接的订阅和 reader 一起清掉
                    // ——与 reader 用同一个入口，不能只保护 reader。
                    await self.teardownIfCurrent(generation: generation, recordReason: error)
                    return
                } catch {
                    await self.teardownIfCurrent(generation: generation, recordReason: .timedOut)
                    return
                }
            }
        }
    }

    /// 心跳探测。把传输访问收在 actor 内，避免在 `@Sendable` 闭包里跨隔离域取属性。
    private func pingTransport() async throws {
        guard isConnected else {
            throw HarnessTransportError.notConnected
        }
        try await streamTransport.ping()
    }

    private func isCurrent(generation: UInt64) -> Bool {
        generation == connectionGeneration && isConnected
    }

    // MARK: - 订阅

    /// 声明一条订阅。`args` 用原生形参对象（follow 用 `HarnessFollowTarget.argsValue`）。
    func openStream(streamID: String, endpoint: String, args: HarnessJSONValue? = nil) async throws {
        guard subscriptions[streamID] == nil else {
            throw HarnessTransportError.rejected(status: 0, message: "streamId is already in use")
        }
        if !isConnected {
            try await connect()
        }
        subscriptions[streamID] = Subscription(
            endpoint: endpoint,
            generation: connectionGeneration,
            buffer: HarnessStreamBuffer(capacity: configuration.bufferCapacity),
            isEnded: false
        )
        do {
            try await streamTransport.send(.open(streamID: streamID, endpoint: endpoint, args: args))
        } catch {
            subscriptions[streamID] = nil
            if let typed = error as? HarnessTransportError {
                record(.transport(typed))
                recoveryAction = Self.action(for: typed)
            }
            throw error
        }
    }

    /// 退订。对不存在的订阅是空操作——客户端与中继对"谁先发现流已结束"本来就有竞态。
    func cancelStream(streamID: String) async {
        guard subscriptions.removeValue(forKey: streamID) != nil else { return }
        try? await streamTransport.send(.cancel(streamID: streamID))
    }

    /// 回传一次人机应答。
    ///
    /// 调用方**不能**指定 clientId：那由中继自己持有。这里连参数都不提供。
    func respond(
        eventID: String,
        outcome: HarnessOutcome,
        expectedGeneration: UInt64? = nil
    ) async throws {
        let generation = connectionGeneration
        guard isConnected,
              expectedGeneration == nil || expectedGeneration == generation else {
            throw HarnessTransportError.notConnected
        }
        do {
            try await streamTransport.send(.respond(eventID: eventID, outcome: outcome))
            // send 是挂起点。若期间重连，旧 eventId 不能在新 clientId 上被当成已确认。
            guard isConnected, connectionGeneration == generation else {
                throw HarnessTransportError.closed
            }
        } catch let error as HarnessTransportError {
            record(.transport(error))
            recoveryAction = Self.action(for: error)
            throw error
        }
    }

    // MARK: - 消费

    /// 消费一帧。缓冲空返回 nil，调用方自己决定要不要等。
    ///
    /// 慢消费者的诊断**不在这里**发：一个读得慢的消费方恰恰不会来调用这个方法，
    /// 把信号挂在消费路径上等于永远发不出来。诊断在入队溢出时立刻记录（见 `dispatch`）。
    func pollFrame(streamID: String) -> HarnessCarrierFrame? {
        guard var subscription = subscriptions[streamID] else { return nil }
        let frame = subscription.buffer.dequeue()
        if subscription.isEnded, subscription.buffer.frames.isEmpty {
            subscriptions[streamID] = nil
        } else {
            subscriptions[streamID] = subscription
        }
        return frame
    }

    func openStreamIDs() -> [String] {
        subscriptions.compactMap { streamID, subscription in
            subscription.isEnded ? nil : streamID
        }.sorted()
    }

    /// 当前缓冲深度。只读，不影响消费顺序。
    func bufferedFrameCount(streamID: String) -> Int {
        subscriptions[streamID]?.buffer.frames.count ?? 0
    }

    /// 订阅累计丢帧数。持续读取层发现大于 0 必须结束本次观察，不能在缺口后继续拼接。
    func droppedFrameCount(streamID: String) -> Int {
        subscriptions[streamID]?.buffer.dropped ?? 0
    }

    /// 观察租约仍属于当前活连接。旧代次任务只读这个判据，不得自行改连接状态。
    func isConnectionCurrent(_ generation: UInt64) -> Bool {
        isConnected && connectionGeneration == generation
    }

    // MARK: - Connection RPC

    /// 一次只读 RPC。
    ///
    /// rpcId 在途期间可观测；响应与请求对不上号时由传输层抛出 `.unattributedResponse`，
    /// 这里只负责如实记录并保持分类。
    func call(method: String, args: HarnessJSONValue? = nil, cwd: String? = nil) async throws -> HarnessJSONValue {
        let rpcId = nextRPCID()
        inFlightRPCIDs.insert(rpcId)
        defer { inFlightRPCIDs.remove(rpcId) }
        do {
            let value = try await rpcTransport.call(HarnessRPCRequest(
                rpcId: rpcId,
                method: method,
                args: args,
                cwd: cwd
            ))
            recoveryAction = .surfaceOnly
            return value
        } catch let error as HarnessTransportError {
            record(Self.diagnostic(for: error))
            recoveryAction = Self.action(for: error)
            throw error
        }
    }

    // MARK: - 帧分发

    /// 分发一帧。代次不符的帧直接丢弃并记诊断。
    private func dispatch(_ frame: HarnessCarrierFrame, generation: UInt64) {
        guard generation == connectionGeneration else {
            record(.unattributableFrame(carrierType: frame.type))
            return
        }
        let decoded: (streamID: String, frame: HarnessStreamFrame)?
        do {
            decoded = try HarnessCarrierDecoder.decode(frame: frame)
        } catch {
            record(.unattributableFrame(carrierType: frame.type))
            return
        }
        guard let decoded else {
            record(.unattributableFrame(carrierType: frame.type))
            return
        }
        guard var subscription = subscriptions[decoded.streamID] else {
            record(.staleFrame(streamID: decoded.streamID))
            return
        }
        guard subscription.generation == generation else {
            record(.staleFrame(streamID: decoded.streamID))
            return
        }
        guard !subscription.isEnded else {
            record(.staleFrame(streamID: decoded.streamID))
            return
        }

        switch decoded.frame {
        case .value(let value):
            if value.type == HarnessWireFrame.ready {
                readyGeneration = generation
                // 中继已经剔除 clientId。真的收到就记一条，但绝不保存。
                if value.raw["clientId"] != nil {
                    record(.unexpectedClientID(streamID: decoded.streamID))
                }
            }
            if value.type == HarnessWireFrame.waterfall {
                let event = value.raw["event"]?.stringValue ?? ""
                guard HarnessWireWaterfallEvent.isSupported(event) else {
                    // 认不出的安全交互：不投递给 UI（UI 无法为它构造合法应答），
                    // 但必须记下来，不能静默丢弃。
                    record(.unsupportedInteraction(streamID: decoded.streamID, event: event))
                    subscriptions[decoded.streamID] = subscription
                    return
                }
            }
            if subscription.buffer.enqueue(frame) {
                // 溢出立刻记诊断：读得慢的消费方不会来 poll，把信号挂在消费路径上
                // 等于永远发不出来。dropped 是单调累计，所以这里报的是"一共漏了多少"。
                record(.slowConsumer(
                    streamID: decoded.streamID,
                    dropped: subscription.buffer.dropped
                ))
            }

        case .carrierError:
            // 载体层错误是流的真实原因，必须投递给消费方，不能吞成"没有帧"。
            subscription.buffer.enqueue(frame)

        case .carrierEnd:
            subscription.buffer.enqueue(frame)
            subscription.isEnded = true
        }
        subscriptions[decoded.streamID] = subscription
    }

    // MARK: - 分类

    /// 一个错误对应的恢复动作。
    static func action(for error: HarnessTransportError) -> RecoveryAction {
        error.shouldReconnect ? .reconnect : .surfaceOnly
    }

    private static func diagnostic(for error: HarnessTransportError) -> Diagnostic {
        if case .unattributedResponse(let rpcId) = error {
            return .unattributedResponse(rpcId: rpcId)
        }
        return .transport(error)
    }

    private func record(_ diagnostic: Diagnostic) {
        diagnostics.append(diagnostic)
        if diagnostics.count > configuration.diagnosticCapacity {
            diagnostics.removeFirst(diagnostics.count - configuration.diagnosticCapacity)
        }
    }

    private func nextRPCID() -> String {
        rpcSequence &+= 1
        return "ios-rpc-\(rpcSequence)"
    }

    // MARK: - 身份字段

    /// 取出原生身份字段。未知字段留在 `HarnessStreamValue.raw` 里，不在这里丢弃。
    ///
    /// `seq` 有三个来源，按帧型取：durable event 在 `event.seq`；直播片段在 `outcome.seq`
    /// （收尾结算指向的持久日志位置）；少数帧直接放在顶层。
    static func identity(of value: HarnessStreamValue) -> FrameIdentity {
        let durable = value.raw["event"]
        let assistantFrame = value.type == HarnessWireFrame.assistantStream
            ? value.raw["frame"]
            : nil
        let outcome = assistantFrame?["outcome"] ?? value.raw["outcome"]
        return FrameIdentity(
            carrierType: HarnessWireCarrier.item,
            frameType: value.type,
            eventID: value.raw["eventId"]?.stringValue,
            eventType: durable?["type"]?.stringValue,
            seq: durable?["seq"]?.intValue
                ?? outcome?["seq"]?.intValue
                ?? value.raw["seq"]?.intValue,
            revision: assistantFrame?["revision"]?.intValue
                ?? value.raw["revision"]?.intValue,
            attemptID: assistantFrame?["attemptId"]?.stringValue
                ?? value.raw["attemptId"]?.stringValue
                ?? value.raw["attempt"]?["attemptId"]?.stringValue
                ?? outcome?["attemptId"]?.stringValue
        )
    }

    /// 生成一条 streamId。由运行时统一发放，避免调用方各自造号造成撞号。
    func nextStreamID() -> String {
        streamSequence &+= 1
        return "ios-stream-\(streamSequence)"
    }
}

// MARK: - 有限缓冲

/// 定长环形缓冲。
///
/// 溢出时丢**最旧**的一帧并计数：直播流上最新帧才是用户要看的；而丢帧必须被计数——
/// 契约里 revision 断档意味着"重开 follow"，静默丢帧会让客户端以为流是连续的。
///
/// `dropped` 是**单调累计**，不随消费清零：它回答的是"这条订阅一共漏了多少帧"，
/// 那正是判断"要不要重开 follow"需要的量。
struct HarnessStreamBuffer: Equatable {
    let capacity: Int
    private(set) var frames: [HarnessCarrierFrame] = []
    private(set) var dropped = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// 入队。返回 true 表示这次入队挤掉了一帧（缓冲已满）。
    @discardableResult
    mutating func enqueue(_ frame: HarnessCarrierFrame) -> Bool {
        var overflowed = false
        if frames.count >= capacity {
            frames.removeFirst()
            dropped += 1
            overflowed = true
        }
        frames.append(frame)
        return overflowed
    }

    mutating func dequeue() -> HarnessCarrierFrame? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    static func == (lhs: HarnessStreamBuffer, rhs: HarnessStreamBuffer) -> Bool {
        lhs.capacity == rhs.capacity && lhs.dropped == rhs.dropped && lhs.frames.count == rhs.frames.count
    }
}
