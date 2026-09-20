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
/// 它不持有连接代次——那是 `HarnessSessionRuntime` 的唯一职责（契约 D1）。
/// 因此这里不自己建连接、不自己记代次。
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

    var turnDeliveryMode: TurnDeliveryMode { .direct }
    var onEvent: (@MainActor (AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendAccepted: ((ClientMessageID?) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?
    var onTurnSendOutcome: ((ClientMessageID?, TurnSendOutcome) -> Void)?
    var onApprovalDecisionFailure: ((String, String) -> Void)?
    var onUserInputResponseFailure: ((String, String, Bool) -> Void)?
    var onControlFailure: ((String) -> Void)?

    /// 本会话的原生 journal。`connect` 建立基线后非空。
    private(set) var journal: HarnessSessionJournal?

    init(
        endpoint: String,
        token: String,
        sessionID: SessionID,
        submission: HarnessSubmissionController,
        fetchSnapshot: (@MainActor (String) async throws -> HarnessSnapshot)? = nil
    ) {
        self.endpoint = endpoint
        self.token = token
        self.sessionID = sessionID
        self.submission = submission
        self.fetchSnapshot = fetchSnapshot
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
        self.sessionID = sessionID
        onStatus?(.connecting)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.openBaseline(sessionID: sessionID)
                self.onStatus?(.connected)
            } catch {
                // 连接失败如实上报。**不**返回"看起来已连上"的假状态——
                // 那会让上层以为原生通道可用。
                self.onStatus?(.failed(Self.describe(error)))
            }
        }
    }

    private func openBaseline(sessionID: SessionID) async throws {
        guard let fetchSnapshot else {
            // 没有 snapshot 来源就建不了基线。显式失败而不是假装连上。
            throw HarnessTransportError.notConnected
        }
        let snapshot = try await fetchSnapshot(sessionID)
        var fresh = HarnessSessionJournal(generation: 1)
        _ = fresh.apply(snapshot: snapshot, acceptingGeneration: 1)
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
    }

    func disconnect() {
        journal = nil
        onStatus?(.disconnected)
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
        for projected in HarnessPresentationProjector.project(durableEvent: event, sessionID: sessionID) {
            onEvent?(projected)
        }
        return true
    }

    /// 应用一帧 assistant-stream 直播片段。
    ///
    /// 失败（断档 / 缺 start / attempt 不符）时如实上报——不能把断档后的片段接上去。
    /// 调用方据此重开 follow；这里不自动重连，那属于 H10 的恢复编排。
    @discardableResult
    func apply(assistantStream frame: HarnessAssistantStreamFrame) -> HarnessJournalStreamRejection? {
        guard var current = journal else { return .beforeSnapshot }
        let rejection = current.apply(assistantStream: frame)
        journal = current
        if let rejection {
            onStatus?(.failed("原生流中断（\(rejection.diagnosticSummary)），需要重新订阅"))
        }
        return rejection
    }

    /// 结算当前 attempt 并投影结果。
    ///
    /// 由流投影层在收到 `end` 帧后调用。被取消的 attempt 不会投影出助手消息
    /// （见 `HarnessPresentationProjector.project(attempt:)`）。
    func settleActiveAttempt() {
        guard var current = journal, let attempt = current.activeAttempt else { return }
        for projected in HarnessPresentationProjector.project(attempt: attempt, sessionID: sessionID) {
            onEvent?(projected)
        }
        current.retireSettledAttempt()
        journal = current
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
            onSendFailure?(clientMessageID, "会话基线尚未建立，请稍后重试")
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
            onSendFailure?(clientMessageID, "Harness 首版只接受文本输入")
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
        onSendFailure?(clientMessageID, "Harness 不支持 guidance，请使用普通输入")
        return false
    }

    /// 停止当前轮次。
    ///
    /// 已读版本只有 session 级 cancel：它停的是这个会话正在跑的轮次，
    /// 不是"某个指定轮次"。因此这里**不**校验 expectedTurnID——那会假装
    /// 我们有原子 turn 级条件取消。
    @discardableResult
    func sendCtrlC(expectedTurnID: TurnID) -> Bool {
        Task { [weak self] in
            guard let self else { return }
            let state = await self.submission.cancel(sessionID: self.sessionID)
            self.publish(cancelState: state)
        }
        return true
    }

    /// 审批应答与追问应答属于 H09：`$events/result` 必须绑定活连接的 clientId。
    /// 在它实现之前保持显式拒绝——不返回假成功。
    @discardableResult
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        onApprovalDecisionFailure?(approvalID, "原生审批应答尚未接线")
        return false
    }

    @discardableResult
    func sendUserInputResponse(requestID: String, answers: [String: [String]]) -> Bool {
        onUserInputResponseFailure?(requestID, "原生追问应答尚未接线", false)
        return false
    }

    func acknowledgeAppliedEvent(_ event: AgentEvent) {
        // 原生路径没有"应用确认"这一步：event 携带原生 seq，去重靠它而不是 ack。
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
            onSendFailure?(clientMessageID, "提交结果未知，请稍后对账（\(detail)）")
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
            onControlFailure?(message)
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
