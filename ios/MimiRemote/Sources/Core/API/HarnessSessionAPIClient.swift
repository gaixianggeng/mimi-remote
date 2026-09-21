import Foundation

/// 原生 Harness 客户端接缝（H01）。
///
/// 只覆盖路由 facade 会委托给 Harness 的**受支持**操作。主机级 projects / worktree / git /
/// 文件 / 语音等服务继续走既有 agentd 客户端路径，不进这个协议——刻意保持窄，不造万能协议。
///
/// agentd 的 `/api/app-server` 已删除 deepseek 翻译层，`runtime=deepseek` 不再存在：
/// `deepseek` **只由原生通道承接**，`runtime(for:)` 不再回退到任何 Codex actor。
/// `AppServerRuntimeBundle.harness == nil` 时没有承接者，相关调用显式失败（绝不静默降级）。
/// Codex / Claude 仍走各自既有 app-server actor，行为不变。
/// 一次成功创建的结果。
///
/// `agentPreset` 是可选：只有 Harness 装配了 agent 名册时才返回（实测 0.1.5-rc.2 返回
/// `"standard"`）。客户端不得假设它存在。
struct HarnessCreatedSession: Equatable {
    let sessionID: String
    let agentPreset: String?
}

protocol HarnessSessionClient: AnyObject {
    /// 该 runtime 的事件客户端。事件包装器面向既有 `SessionWebSocketClient` 协议，
    /// 因此不再要求所有实现都是 `CodexAppServerSessionWebSocketClient`。
    func makeEventClient(sessionID: SessionID) -> any SessionWebSocketClient

    /// 原生通道是否可用。不可用时必须抛错或返回 false，**不得**用空成功冒充。
    func channelAvailable() async throws -> Bool

    func sessionsPage(
        projectID: String?,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse

    // MARK: - 历史分页
    //
    // `session/page` 需要**本次 follow** 的 `snapshot.cursor` 作为 `throughSeq`：
    // 传 0 只读到 seq 0，传一个过大的值返回空 records（契约 §5.5 实测）。
    // 因此这组方法的调用前提是该会话的 follow 已经建立过基线。

    /// 读取一页历史。`before` 是更早位置的游标；nil 表示从最新往回读。
    @MainActor
    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage

    /// 单轮补页。原生路径暂无按轮次聚合的读取入口。
    @MainActor
    func historyTurnItemsPage(
        sessionID: String,
        continuation: HistoryTurnItemsContinuation
    ) async throws -> HistoryTurnItemsPage

    /// 最新一轮的历史。原生路径暂不单独提供。
    @MainActor
    func latestTurnHistoryPage(sessionID: String) async throws -> HistoryMessagesPage?

    func modelOptions() async throws -> [CodexAppServerModelOption]

    // MARK: - H07 写路径
    //
    // 写方法与只读方法在**协议层**就分开列：读能力缺失时可以不实现，
    // 而写能力缺失必须是显式拒绝（见 HarnessNativeUnavailableError）。

    /// 创建会话。`cwd` 既是授权提示也是创建目标。
    func createSession(cwd: String, sessionID: String?) async throws -> HarnessCreatedSession

    /// 选择模型。provider/model 取值由模型目录决定。
    func selectModel(
        sessionID: String,
        provider: String,
        model: String,
        reasoningEffort: String?
    ) async throws

    /// 提交一次用户输入。`requestID` 是提交与 durable 记录的对账键，必须稳定。
    func submitPrompt(
        sessionID: String,
        requestID: String,
        text: String,
        mode: String,
        clientTimeZone: String?
    ) async throws

    /// 停止当前轮次（session 级，不是原子 turn 级条件取消）。
    func cancelSession(sessionID: String) async throws

    // MARK: - 宿主级事件
    //
    // `$events` 是宿主级通道（契约 D5）：别的会话的审批与追问可能在用户**从未打开**
    // 对应会话时到达。它必须由宿主持有，而不是每个会话页面各开一条——中继规定一条
    // 移动连接只绑定一个 `$events` 生命周期，且退订它会关闭整条共享连接。

    /// 接上宿主级交互事件的出口。装配方在宿主激活时调用一次。
    ///
    /// `rejected` 单独回传而不是只触发重绘：卡片被放回可应答是一件事，
    /// **告诉用户为什么、以及要不要解锁**是另一件事。带上结论（outcome）是关键：
    /// `rejected` 恢复按钮，`unknown` 必须保持锁定。只重绘会让卡片恢复原状却
    /// 没有任何解释，也让上层无从判断该不该解锁。
    @MainActor
    func setHostInteractionSinks(
        events: (@MainActor (AgentEvent) -> Void)?,
        changed: (@MainActor () -> Void)?,
        rejected: (@MainActor (_ sessionID: String, _ eventID: String, _ outcome: String, _ message: String) -> Void)?
    )

    /// 开始宿主级 `$events` 观察。幂等。
    @MainActor
    func startHostEvents()

    /// 停止宿主级观察。只在宿主退役时调用，**页面切换不得调用**。
    @MainActor
    func stopHostEvents() async

    /// 宿主级待处理交互，含用户从未打开过的会话。
    @MainActor
    func hostPendingInteractions() -> [HarnessInteractionStore.PendingInteraction]

    /// 主机或凭据退役时关闭本客户端唯一的 runtime。
    func shutdownForHostSwitch() async
}

/// 原生客户端工厂接缝。
///
/// 正式 App 由 `AppStore` 注入 live 工厂；可选形态只用于测试替身和不装配客户端的
/// 受控构造。是否启用由 agentd channel 决定，绝不因工厂缺失而回退旧 app-server 路径。
typealias HarnessSessionClientFactory = (_ endpoint: String, _ token: String) -> HarnessSessionClient?

/// 原生路径的显式失败。
///
/// 这些错误**不允许**被空列表、空成功或旧网关兜底掩盖：原生操作要么给出真实结果，
/// 要么显式失败，让上层把 runtime 标成 unavailable 并继续其他 runtime。
enum HarnessNativeUnavailableError: Error, LocalizedError, Equatable {
    /// 该 runtime 已由原生客户端承担，不能再用 Codex actor 假装 native。
    case routedNatively(runtimeProvider: String)
    /// 原生客户端尚未实现该操作（H01 骨架阶段的主要返回）。
    case notImplemented(operation: String)
    /// Harness 不支持该操作，必须显式拒绝而不是降级成普通请求。
    case unsupported(operation: String)
    /// 宿主声明了 DeepSeek，但没有当前 App 所需的原生协议能力。
    case agentdUpgradeRequired

    var errorDescription: String? {
        switch self {
        case .routedNatively(let runtimeProvider):
            return L10n.format("harness.native_routed_no_fallback", runtimeProvider)
        case .notImplemented(let operation):
            return L10n.format("harness.native_not_implemented", operation)
        case .unsupported(let operation):
            return L10n.format("harness.native_unsupported", operation)
        case .agentdUpgradeRequired:
            return L10n.text("harness.agentd_upgrade_required")
        }
    }
}

/// 原生 Harness 客户端。
///
/// 目录、create/model/prompt/cancel、follow、历史分页与交互应答共用一个 runtime。
///
/// 历史分页（`session/page`）需要**本次 follow** 的 `snapshot.cursor` 作 `throughSeq`，
/// 因此读取前先 `awaitSnapshotBaseline`：拿不到就显式失败，绝不猜一个游标。
///
/// 授权提示 `cwd` 走请求体（与 `internal/httpapi/harness_native_policy.go` 的
/// `harnessNativeCWDScopedMethods` 一致）：`session/list`、`session/search` 与 create 接受它，
/// 它**不进**上游 Harness 的 args。
final class HarnessSessionAPIClient: HarnessSessionClient {
    /// 原生通道承接的 runtime id。沿用既有 runtime 身份，不新建 `deepseek-native`。
    static let runtimeProvider = "deepseek"
    /// 正式构建使用的原生客户端工厂。是否让用户进入 Harness 仍由 agentd 返回的
    /// `enabled + harness_native_v1` channel 决定；工厂存在不等于用户已启用服务。
    static let liveFactory: HarnessSessionClientFactory = { endpoint, token in
        HarnessSessionAPIClient(endpoint: endpoint, token: token)
    }

    let endpoint: String
    let token: String
    /// RPC、follow、宿主事件和应答共用这一份 runtime；不另建第二套连接管理器。
    private let runtime: HarnessSessionRuntime
    /// 提交编排缓存。每建一个事件客户端都新建控制器会让"上一次提交尚未确认"
    /// 这条判断失效——状态机必须跨事件客户端存活。
    private var cachedSubmissionController: HarnessSubmissionController?
    private var cachedInteractionStore: HarnessInteractionStore?
    /// 宿主级 `$events` 观察者。**整个宿主只有这一条**（见类型注释与 D5）。
    private var cachedHostObserver: HarnessHostEventObserver?
    /// 宿主级交互事件的出口。页面未打开时也要能到达 Store。
    private var hostEventSink: (@MainActor (AgentEvent) -> Void)?
    /// 宿主级 pending 集合变化时的通知出口。
    private var hostChangeSink: (@MainActor () -> Void)?
    /// 一次宿主级应答未以"接受"收场时的出口（会话、交互、结论、原因）。
    private var hostRejectionSink: (@MainActor (_ sessionID: String, _ eventID: String, _ outcome: String, _ message: String) -> Void)?
    /// 每个会话**当前这一代** follow 的 `snapshot.cursor`。
    ///
    /// `session/page` 的 `throughSeq` 必须取自**本次** follow 的 opening snapshot
    /// （契约 §5.5 实测：传 0 只读到 seq 0，传过大的值返回空 records）。
    ///
    /// 带代次存储的原因：重开或重连会换一个 reading context，旧游标属于上一代
    /// snapshot，拿它当读取边界会静默读到错误的区间。代次落后于当前登记的即作废。
    struct SnapshotBaseline: Equatable {
        let cursor: Int
        /// 由 API client 在观察**开始时**分配，不使用页面自己的局部 generation。
        /// 不同页面实例都会从 1 起步，直接比较它们会把新旧关系判断反。
        let contextID: UInt64
    }
    private var baselineBySessionID: [SessionID: SnapshotBaseline] = [:]
    private var newestSnapshotContextBySessionID: [SessionID: UInt64] = [:]
    private var snapshotContextSequence: UInt64 = 0

    /// 已结算 assistant 的唯一展示身份，按「会话 + settlement seq」索引。
    ///
    /// `end.outcome.seq` 是 attempt 与 durable `assistant/message` 的桥。结算时保留已经
    /// 进入 Store 的 attempt 身份；之后同 seq 的 snapshot、live durable 与
    /// `session/page` 都复用该身份，不再插入第二个 durable 气泡。
    private var assistantMessageIDBySessionID: [SessionID: [Int: MessageID]] = [:]

    /// 普通输入的提交模式。实测取值域只有 queue|steer，普通发送用 queue。
    static let defaultPromptMode = "queue"

    init(
        endpoint: String,
        token: String,
        rpc: HarnessRPCTransport? = nil,
        stream: HarnessStreamTransport? = nil
    ) {
        self.endpoint = endpoint
        self.token = token
        let rpcTransport: HarnessRPCTransport
        let streamTransport: HarnessStreamTransport
        if let baseURL = URL(string: endpoint) {
            rpcTransport = rpc ?? URLSessionHarnessRPCTransport(baseURL: baseURL, token: token)
            streamTransport = stream ?? URLSessionHarnessStreamTransport(baseURL: baseURL, token: token)
        } else {
            // 地址不可解析时保留一个必然失败的传输，让失败发生在调用点而不是 init 抛错，
            // 调用方因此总能拿到一个显式错误而不是构造期的崩溃路径。
            rpcTransport = rpc ?? UnreachableHarnessRPCTransport(endpoint: endpoint)
            streamTransport = stream ?? UnreachableHarnessStreamTransport(endpoint: endpoint)
        }
        runtime = HarnessSessionRuntime(
            configuration: HarnessSessionRuntime.Configuration(endpoint: endpoint, token: token),
            transports: HarnessSessionRuntime.TransportPair(
                rpc: rpcTransport,
                stream: streamTransport
            )
        )
    }

    /// 事件客户端。写路径复用本客户端持有的提交编排，不另建一条网络路径。
    ///
    /// opening snapshot 与后续增量都经由 runtime 的真实 `session/follow` 载体获取。
    /// `$events` 由**宿主级**观察者独占（见 `startHostEvents`），页面只拿自己会话的
    /// follow 观察引用——中继规定一条移动连接只能有一个 `$events` 生命周期，
    /// 每页各开一条会被拒，页面退订还会关掉整条共享连接。
    @MainActor
    func makeEventClient(sessionID: SessionID) -> any SessionWebSocketClient {
        HarnessSessionWebSocketClient(
            endpoint: endpoint,
            token: token,
            sessionID: sessionID,
            submission: submissionController(),
            runtime: runtime,
            interactionStore: interactionStore(),
            recovery: HarnessRecoveryCoordinator(),
            // 发送前先应用本次模型/档位：只在创建会话时选择覆盖不到后续每一次发送。
            selectModel: { [weak self] sessionID, provider, model, effort in
                guard let self else { throw HarnessTransportError.notConnected }
                try await self.selectModel(
                    sessionID: sessionID,
                    provider: provider,
                    model: model,
                    reasoningEffort: effort
                )
            },
            // 在 follow 开始时先登记全局读取上下文；晚到的旧页面不能覆盖后来开始的刷新。
            beginSnapshotObservation: { [weak self] sessionID in
                self?.beginSnapshotObservation(for: sessionID) ?? 0
            },
            // 基线建立后回报 snapshot 游标：历史分页的 throughSeq 只能用本次的值。
            reportSnapshotCursor: { [weak self] sessionID, cursor, contextID in
                self?.rememberSnapshotCursor(cursor, for: sessionID, contextID: contextID)
            },
            reconcileDurableEvent: { [weak self] sessionID, event in
                self?.reconcileCommittedEvent(event, sessionID: sessionID)
            },
            settleAssistantIdentity: { [weak self] sessionID, seq, attemptMessageID in
                self?.settleAssistantIdentity(
                    sessionID: sessionID,
                    seq: seq,
                    attemptMessageID: attemptMessageID
                ) ?? attemptMessageID
            }
        )
    }

    /// 宿主级交互事件的出口与 pending 变化通知。
    ///
    /// 由装配方（`AppServerRuntimeBundle`）接上，使"用户从未打开该会话"时收到的
    /// 审批也能到达 Store 与 UI（契约 D5）。
    @MainActor
    func setHostInteractionSinks(
        events: (@MainActor (AgentEvent) -> Void)?,
        changed: (@MainActor () -> Void)?,
        rejected: (@MainActor (_ sessionID: String, _ eventID: String, _ outcome: String, _ message: String) -> Void)?
    ) {
        hostEventSink = events
        hostChangeSink = changed
        hostRejectionSink = rejected
        let observer = hostEventObserver()
        observer.onEvent = { [weak self] event in
            self?.hostEventSink?(event)
            self?.hostChangeSink?()
        }
        observer.onStatus = { _ in }
        observer.onInteractionRejected = { [weak self] sessionID, eventID, outcome, message in
            // 先刷新（底层 pending 已变化），再把**结论与原因**一起交给上层——
            // 上层据此决定恢复按钮还是保持锁定。只刷新等于让卡片恢复原状却没有解释。
            self?.hostChangeSink?()
            self?.hostRejectionSink?(sessionID, eventID, outcome, message)
        }
    }

    /// 开始宿主级 `$events` 观察。幂等，可在每次宿主激活时安全调用。
    @MainActor
    func startHostEvents() {
        hostEventObserver().start()
    }

    /// 停止宿主级观察。只在宿主退役（切 host / 凭据失效 / 关闭）时调用。
    @MainActor
    func stopHostEvents() async {
        await cachedHostObserver?.stop()
    }

    /// 当前宿主级 pending 交互（含用户从未打开过的会话）。
    @MainActor
    func hostPendingInteractions() -> [HarnessInteractionStore.PendingInteraction] {
        interactionStore().pendingInteractions
    }

    @MainActor
    private func hostEventObserver() -> HarnessHostEventObserver {
        if let existing = cachedHostObserver { return existing }
        let created = HarnessHostEventObserver(
            runtime: runtime,
            interactionStore: interactionStore(),
            recovery: HarnessRecoveryCoordinator()
        )
        cachedHostObserver = created
        return created
    }

    @MainActor
    private func interactionStore() -> HarnessInteractionStore {
        if let existing = cachedInteractionStore { return existing }
        let created = HarnessInteractionStore()
        cachedInteractionStore = created
        return created
    }

    /// 提交编排。同一个 client 实例复用同一个控制器：写路径的状态机不该每建一个
    /// 事件客户端就重置一次，否则"上一次提交尚未确认"这条判断会失效。
    @MainActor
    private func submissionController() -> HarnessSubmissionController {
        if let existing = cachedSubmissionController { return existing }
        let created = HarnessSubmissionController(
            sendPrompt: { [weak self] sessionID, requestID, text in
                guard let self else { throw HarnessTransportError.notConnected }
                try await self.submitPrompt(
                    sessionID: sessionID, requestID: requestID, text: text,
                    mode: Self.defaultPromptMode, clientTimeZone: TimeZone.current.identifier
                )
            },
            sendCancel: { [weak self] sessionID in
                guard let self else { throw HarnessTransportError.notConnected }
                try await self.cancelSession(sessionID: sessionID)
            }
        )
        cachedSubmissionController = created
        return created
    }

    /// 通道可用性探测。
    ///
    /// 用 `session/modelCatalog` 而不是 `session/list`：它零参数、只读、不触发任何模型调用，
    /// 却同样要走完整条鉴权与上游链路，因此足以区分"通道通了"和"通道没通"。
    /// 失败必须抛错——返回 false 会与"探测本身没跑"混成同一件事。
    func channelAvailable() async throws -> Bool {
        _ = try await runtime.call(
            method: HarnessWireMethod.sessionModelCatalog,
            args: .object([:]),
            cwd: nil
        )
        return true
    }

    /// Harness 没有 Codex 的 project 维度；非空 projectID 不能被静默丢弃。
    func sessionsPage(
        projectID: String?,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        guard projectID?.trimmedNonEmpty == nil else {
            throw HarnessNativeUnavailableError.unsupported(operation: "session/list(projectID)")
        }
        return try await listSessions(cwd: nil, workspace: nil)
    }

    /// 工作区目录查询：带 cwd 提示，由 agentd 用既有 canonical scope 逻辑裁剪。
    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        try await listSessions(cwd: workspace.path, workspace: workspace)
    }

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await listSessions(cwd: nil, workspace: nil)
    }

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 中继会拒空 query；本地先拒能给出可操作文案，也避免把空查询当成"零命中"。
            throw HarnessTransportError.rejected(status: 400, message: "Search query must not be empty")
        }
        let value = try await runtime.call(
            method: HarnessWireMethod.sessionSearch,
            args: .object(["request": .object(["query": .string(trimmed)])]),
            cwd: nil
        )
        return try HarnessSessionDirectoryDecoding.searchPage(
            from: value,
            runtimeProvider: Self.runtimeProvider,
            workspace: nil
        )
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        let value = try await runtime.call(
            method: HarnessWireMethod.sessionModelCatalog,
            // 该方法描述符没有参数：必须传空对象，省略或带键都会被中继拒。
            args: .object([:]),
            cwd: nil
        )
        return try HarnessSessionDirectoryDecoding.modelOptions(
            from: value,
            runtimeProvider: Self.runtimeProvider
        )
    }

    /// 会话快照读取（重连前刷新、重命名等入口使用）。
    ///
    /// 原生路径没有等价的"读一份会话快照"入口：会话元数据由目录（`session/list`）
    /// 提供，消息由 follow 与 `session/page` 提供。这里显式拒绝，不用半成品冒充成功——
    /// 历史分页本身已经接通（见 `messagesPage`），本条不是它的前置。
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw HarnessNativeUnavailableError.unsupported(operation: "session(snapshot)")
    }

    /// 读取一页历史。
    @MainActor
    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage {
        let decodedCursor = try HarnessHistoryPageDecoding.cursor(from: before)
        guard let baseline = await awaitSnapshotBaseline(
            for: sessionID,
            requiringNewSnapshot: decodedCursor == nil
        ) else {
            // 没有基线就没有合法的 throughSeq。猜一个会产生静默错误的页，
            // 比显式失败危险得多（契约 §5.5 明确禁止）。
            throw HarnessTransportError.notConnected
        }
        if let decodedCursor, decodedCursor.contextID != baseline.contextID {
            // 这是上一轮 authoritative snapshot 的分页位置。混用新 throughSeq 会静默
            // 拼接两个读取上下文；显式失败，让 Store 重新从首屏开始。
            throw HarnessTransportError.continuityLost(
                "history cursor belongs to an obsolete Harness snapshot"
            )
        }
        let beforeSeq = decodedCursor?.beforeSeq

        var request: [String: HarnessJSONValue] = [
            "address": .object([
                "kind": .string("session"),
                "sessionId": .string(sessionID),
            ]),
            // 必填。中继按描述符逐字校验，缺键直接 400。
            "throughSeq": .number(Double(baseline.cursor)),
        ]
        if let beforeSeq {
            request["beforeSeq"] = .number(Double(beforeSeq))
        }
        if let limit {
            request["maxMessages"] = .number(Double(limit))
        }

        let value = try await runtime.call(
            method: HarnessWireMethod.sessionPage,
            args: .object(["request": .object(request)]),
            cwd: nil
        )
        let page = try HarnessHistoryPageDecoding.page(from: value)
        // snapshot、live durable 与 session/page 必须进入同一个提交/身份对账入口。
        for event in page.records {
            _ = reconcileCommittedEvent(event, sessionID: sessionID)
        }
        let messages = HarnessHistoryProjection.messages(
            from: page.records,
            sessionID: sessionID,
            assistantMessageID: { [weak self] event in
                guard let self, let seq = event.seq else { return nil }
                return self.assistantMessageIDBySessionID[sessionID]?[seq]
            }
        )
        // 下一页位置由**已取回记录的最小 seq** 推出，不是编造游标：
        // 上游结果只有 {records, hasMore}，没有 nextBeforeSeq。
        // 没有任何记录时无法推进，此时不给游标（调用方据此停止）。
        let nextCursor = page.records.compactMap(\.seq).min().map {
            HarnessHistoryPageDecoding.cursor(before: $0, contextID: baseline.contextID)
        }
        return HistoryMessagesPage(
            messages: messages,
            previousCursor: page.hasMore ? nextCursor : nil,
            hasMoreBefore: page.hasMore && nextCursor != nil,
            // 原生路径不做"缩略/完整"两种装载策略：每页就是上游给的那么多条。
            loadMode: loadMode,
            notice: nil
        )
    }

    /// 单轮补页：原生路径没有按轮次聚合的读取入口。
    @MainActor
    func historyTurnItemsPage(
        sessionID: String,
        continuation: HistoryTurnItemsContinuation
    ) async throws -> HistoryTurnItemsPage {
        throw HarnessNativeUnavailableError.unsupported(operation: "historyTurnItemsPage")
    }

    /// 最新一轮历史：原生路径不单独提供，调用方走整页读取。
    @MainActor
    func latestTurnHistoryPage(sessionID: String) async throws -> HistoryMessagesPage? {
        nil
    }

    /// 取该会话本次 follow 的 `snapshot.cursor`。
    /// 取得某个会话的读取基线（`throughSeq`），必要时**主动建立**观察。
    ///
    /// ## 为什么必须主动建立
    ///
    /// Store 冷打开的真实顺序是"先读历史、再连事件"（`SessionStoreTurns.selectSession`）。
    /// 如果这里只是被动等待，就会和"基线由事件连接产生"互相等待——历史等连接、
    /// 连接等历史返回，两边都不动，用户看到一个永远转圈的长会话。
    ///
    /// 因此这里不等待页面来建连，而是用**同一个 runtime** 起一次观察拿基线，
    /// 拿到后立刻 `disconnect()`（它只退订自己的 follow，不碰宿主 `$events`，
    /// 也不关共享连接）。页面随后建自己的连接时会登记新代次的基线。
    ///
    /// ## 为什么是有界轮询而不是 continuation + 任务组
    ///
    /// 等待必须**可取消、可超时、且真的会退出**。任务组写法有个结构陷阱：
    /// `cancelAll()` 不会恢复挂起的续体，而任务组退出前要等全部子任务结束——
    /// 把清理写在组外就永远到不了，超时形同虚设。
    /// 有界轮询没有这个结构，`Task.sleep` 在取消时直接抛出。
    ///
    /// 拿不到就返回 nil，调用方按"暂时读不到"处理：**不**拿猜的游标去读，
    /// 那会静默给出错误的页（契约 §5.5 明确禁止）。
    @MainActor
    func awaitSnapshotBaseline(
        for sessionID: SessionID,
        requiringNewSnapshot: Bool = true,
        timeout: Duration = .seconds(10)
    ) async -> SnapshotBaseline? {
        if !requiringNewSnapshot, let baseline = baselineBySessionID[sessionID] {
            return baseline
        }

        // 先记住调用前的上下文。`connect` 会异步登记新上下文；如果在它之后读取，
        // opening snapshot 先返回时可能把新上下文误当成旧值，导致本次刷新一直等待。
        let previousContextID = newestSnapshotContextBySessionID[sessionID] ?? 0
        let warmUp = makeEventClient(sessionID: sessionID)
        warmUp.connect(sessionID: sessionID)
        defer { warmUp.disconnect() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let baseline = baselineBySessionID[sessionID],
               !requiringNewSnapshot || baseline.contextID > previousContextID {
                return baseline
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                // 被取消：立即退出，不再占用调用方。
                break
            }
        }
        guard let baseline = baselineBySessionID[sessionID],
              !requiringNewSnapshot || baseline.contextID > previousContextID else {
            return nil
        }
        return baseline
    }


    /// 在 opening snapshot 请求**开始前**分配读取上下文。
    ///
    /// 分配点不能放在 snapshot 返回后：旧页面先开始、晚返回时会拿到更大的序号，反而
    /// 覆盖真正的新刷新。登记新上下文时清掉旧 baseline，确保首屏读取不会复用旧 cursor。
    @MainActor
    private func beginSnapshotObservation(for sessionID: SessionID) -> UInt64 {
        snapshotContextSequence &+= 1
        let contextID = snapshotContextSequence
        newestSnapshotContextBySessionID[sessionID] = contextID
        baselineBySessionID[sessionID] = nil
        return contextID
    }


    /// 登记某会话本次 follow 的 opening snapshot 游标。
    ///
    /// 由页面客户端在建立基线后回调。代次只增不减：`throughSeq` 属于**这一代**
    /// snapshot，用上一代的游标会读到错误的区间。
    @MainActor
    func rememberSnapshotCursor(
        _ cursor: Int,
        for sessionID: SessionID,
        contextID: UInt64
    ) {
        guard contextID != 0,
              newestSnapshotContextBySessionID[sessionID] == contextID else {
            // 迟到的旧页面/旧 follow 基线不得覆盖后来开始的 authoritative refresh。
            return
        }
        baselineBySessionID[sessionID] = SnapshotBaseline(cursor: cursor, contextID: contextID)
    }

    /// 所有 durable 来源的唯一提交与身份对账入口。
    @MainActor
    @discardableResult
    private func reconcileCommittedEvent(
        _ event: HarnessDurableEvent,
        sessionID: SessionID
    ) -> MessageID? {
        if event.type == HarnessWireEventType.userMessage,
           let requestID = event.data?["source"]?["rpcId"]?.stringValue?.trimmedNonEmpty {
            submissionController().resolveAfterReconciliation(requestID: requestID)
        }
        guard event.type == HarnessWireEventType.assistantMessage,
              let seq = event.seq,
              let durableID = HarnessPresentationProjector.stableMessageID(
                  for: event,
                  prefix: "assistant"
              ) else {
            return nil
        }
        return assistantMessageIDBySessionID[sessionID]?[seq] ?? durableID
    }

    /// 用 `end.outcome.seq` 把直播 attempt 与 durable message 结算成一个展示身份。
    @MainActor
    private func settleAssistantIdentity(
        sessionID: SessionID,
        seq: Int,
        attemptMessageID: MessageID
    ) -> MessageID {
        var identities = assistantMessageIDBySessionID[sessionID] ?? [:]
        // 直播增量已经用 attempt 身份进入既有 ConversationStore。即使 durable 先到，
        // 结算也必须保留这个身份，再让后续 durable/历史按 seq 复用它；改成 durable id
        // 会留下那条直播气泡，并额外插入一条“完成”消息。
        let settled = identities[seq] ?? attemptMessageID
        identities[seq] = settled
        assistantMessageIDBySessionID[sessionID] = identities
        return settled
    }

    // MARK: - H07 写路径

    /// 创建会话。`cwd` 同时作为授权提示与创建目标——中继会校验后者落在前者授权的范围内。
    ///
    /// `sessionId` 可选：给出它是为了把本地乐观记录与服务端身份稳定关联。
    /// `agentPreset` 刻意不传：默认值由 Harness 决定（契约 D4）。
    func createSession(cwd: String, sessionID: String?) async throws -> HarnessCreatedSession {
        var request: [String: HarnessJSONValue] = ["cwd": .string(cwd)]
        if let sessionID = sessionID?.trimmedNonEmpty {
            request["sessionId"] = .string(sessionID)
        }
        let value = try await runtime.call(
            method: HarnessWireMethod.sessionCreate,
            args: .object(["request": .object(request)]),
            cwd: cwd
        )
        guard let created = value["sessionId"]?.stringValue?.trimmedNonEmpty else {
            // 建成功了却拿不到身份，后续没有任何操作能指向它。显式失败而不是返回空 id。
            throw HarnessTransportError.malformedResponse("session/create result is missing sessionId")
        }
        return HarnessCreatedSession(
            sessionID: created,
            agentPreset: value["agentPreset"]?.stringValue
        )
    }

    /// 选择模型。provider/model 取值由模型目录决定，这里不按名字推断。
    func selectModel(
        sessionID: String,
        provider: String,
        model: String,
        reasoningEffort: String?
    ) async throws {
        var request: [String: HarnessJSONValue] = [
            "sessionId": .string(sessionID),
            "provider": .string(provider),
            "model": .string(model),
        ]
        // 可选档位：只在确实给了非空值时才带上，避免把"没选档位"变成一个显式空档位。
        if let effort = reasoningEffort?.trimmedNonEmpty {
            request["reasoningEffort"] = .string(effort)
        }
        _ = try await runtime.call(
            method: HarnessWireMethod.sessionSelectModel,
            args: .object(["request": .object(request)]),
            cwd: nil
        )
    }

    /// 提交一次用户输入。
    ///
    /// `requestId` 由调用方生成并**保持不变**：它是这次提交与 durable
    /// `user/message.source.rpcId` 的对账键（契约 D4）。响应未知时不得换一个 id 重发——
    /// 那会让一次提交变成两次。
    func submitPrompt(
        sessionID: String,
        requestID: String,
        text: String,
        mode: String,
        clientTimeZone: String?
    ) async throws {
        var request: [String: HarnessJSONValue] = [
            "requestId": .string(requestID),
            "sessionId": .string(sessionID),
            "mode": .string(mode),
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(text),
            ])]),
        ]
        if let zone = clientTimeZone?.trimmedNonEmpty {
            request["clientTimeZone"] = .string(zone)
        }
        _ = try await runtime.call(
            method: HarnessWireMethod.sessionPrompt,
            args: .object(["request": .object(request)]),
            cwd: nil
        )
    }

    /// 停止当前轮次。
    ///
    /// 已读版本只有 session 级 cancel——它停的是这个会话正在跑的轮次，不是"某个指定轮次"。
    /// 契约要求如实记录这一点，不宣传成原子 turn 级条件取消。
    func cancelSession(sessionID: String) async throws {
        _ = try await runtime.call(
            method: HarnessWireMethod.sessionCancel,
            args: .object(["request": .object(["sessionId": .string(sessionID)])]),
            cwd: nil
        )
    }

    func shutdownForHostSwitch() async {
        // 先退订宿主级 `$events`：中继在它退役时会关闭整条连接，
        // 顺序反过来会留下一条"已关连接上还挂着订阅"的状态。
        await stopHostEvents()
        await runtime.shutdown()
    }

    // MARK: 支撑

    private func listSessions(cwd: String?, workspace: AgentWorkspace?) async throws -> SessionsPage {
        let value = try await runtime.call(
            method: HarnessWireMethod.sessionList,
            // 形参名带下划线；写成 "request" 会被 Harness 网关判为 gateway/arguments-invalid。
            // 上游 list 没有服务端分页，因此不传 cursor。
            args: .object(["_request": .object([:])]),
            cwd: cwd
        )
        return try HarnessSessionDirectoryDecoding.sessionsPage(
            from: value,
            runtimeProvider: Self.runtimeProvider,
            workspace: workspace
        )
    }

}

/// endpoint 无法解析成 URL 时的占位传输：调用必然显式失败。
private final class UnreachableHarnessRPCTransport: HarnessRPCTransport {
    private let endpoint: String

    init(endpoint: String) {
        self.endpoint = endpoint
    }

    func call(_ request: HarnessRPCRequest) async throws -> HarnessJSONValue {
        throw HarnessTransportError.malformedResponse("Invalid native Harness endpoint: \(endpoint)")
    }
}

/// endpoint 无法解析时的流占位；任何连接都显式失败，不产生旧路径回退。
private final class UnreachableHarnessStreamTransport: HarnessStreamTransport {
    private let endpoint: String

    init(endpoint: String) {
        self.endpoint = endpoint
    }

    func connect() async throws {
        throw HarnessTransportError.malformedResponse("Invalid native Harness endpoint: \(endpoint)")
    }

    func send(_ frame: HarnessClientFrame) async throws {
        throw HarnessTransportError.notConnected
    }

    func receive() async throws -> HarnessCarrierFrame? {
        throw HarnessTransportError.notConnected
    }

    func ping() async throws {
        throw HarnessTransportError.notConnected
    }

    func close() async {}
}
