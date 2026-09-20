import Foundation

/// 写路径的提交编排：创建、选模型、发送、停止。
///
/// ## 这个类型存在的唯一理由：**响应未知 ≠ 未执行**
///
/// 契约 D4 的硬要求是"create/prompt/approval/cancel 不因超时或 reconnect 被盲目自动重发"。
/// 一条 HTTP 请求的失败有三种完全不同的含义，它们的正确处置也完全不同：
///
/// | 情况 | 含义 | 正确处置 |
/// |---|---|---|
/// | 收到明确业务失败（`result.ok=false`） | 上游明确拒绝了 | 可以重试（用户改了条件之后） |
/// | 链路层失败（连不上、超时） | **可能已执行** | 不重发；按 requestId 读取对账 |
/// | 响应丢了但上游已 accepted | **很可能已执行** | 不重发；等待重投或读取对账 |
///
/// 把后两种当成"没发生"去重发，会让一次用户提交变成两次工具执行——这是本任务
/// 最需要防住的后果。所以本类型**没有**任何自动重试路径：`submit` 只发一次，
/// 结果不明时把状态留在 `.responseUnknown` 交给上层对账。
///
/// ## 稳定 requestId
///
/// `requestId` 在**构造提交时**生成一次，之后无论发生什么（重试、页面切换、重连）
/// 都用同一个值。上层拿到 `.responseUnknown` 后应当用同一个 requestId 去读取对账，
/// 而不是换一个 id 重发。这也是为什么它由调用方持有而不是内部现生成。
@MainActor
final class HarnessSubmissionController {

    /// 一次提交的状态机。
    ///
    /// `responseUnknown` 是独立状态，不是 `failed` 的子类：它要求"读取对账"这个不同的
    /// 后续动作，而 `failed` 要求"用户改条件后重试"。
    enum SubmissionState: Equatable {
        /// 尚未提交。
        case idle
        /// 已发出，等待结果。
        case submitting
        /// 上游明确接受。注意这不表示生成完成。
        case accepted
        /// 上游明确拒绝（业务失败）。可以重试。
        case rejected(String)
        /// 结果未知。**不得自动重发**，等对账。
        case responseUnknown(String)
    }

    /// 一次提交被拒绝放行的原因。
    ///
    /// 与 `SubmissionState.rejected` 刻意分开：后者是**上游对这次提交**给出的业务结论
    /// （"没执行、改条件后可重试"），而这里是"这次提交根本没发出去"。
    /// 混用会让一处从未发生的写入被报成"上游拒绝了它"，用户据此重试的其实是他
    /// 还没发过的那条消息——文案与事实都对不上。
    enum SubmissionBlockReason: Equatable {
        /// 同一会话上一次提交结果未确认，必须先对账。
        case previousSubmissionUnconfirmed
    }

    /// 一次提交的身份。上层持有它，用于对账与关联乐观记录。
    struct Submission: Equatable, Identifiable {
        let requestID: String
        let sessionID: String
        let text: String
        var state: SubmissionState
        /// 非 nil 表示这次提交没有被发出，连同原因一起返回。
        var blockReason: SubmissionBlockReason?

        var id: String { requestID }

        init(
            requestID: String,
            sessionID: String,
            text: String,
            state: SubmissionState,
            blockReason: SubmissionBlockReason? = nil
        ) {
            self.requestID = requestID
            self.sessionID = sessionID
            self.text = text
            self.state = state
            self.blockReason = blockReason
        }
    }

    /// 该 runtime 的写能力实现。注入以便测试替身。
    typealias PromptSender = @MainActor (
        _ sessionID: String,
        _ requestID: String,
        _ text: String
    ) async throws -> Void
    typealias CancelSender = @MainActor (_ sessionID: String) async throws -> Void

    private let sendPrompt: PromptSender
    private let sendCancel: CancelSender

    /// 写入状态按 request 保存，并按 session 指向各自最新一条。
    /// 一个会话的结果未知不能冻结同一 runtime 下的其他会话。
    private var submissionsByRequestID: [String: Submission] = [:]
    private var latestRequestIDBySessionID: [String: String] = [:]

    init(sendPrompt: @escaping PromptSender, sendCancel: @escaping CancelSender) {
        self.sendPrompt = sendPrompt
        self.sendCancel = sendCancel
    }

    func latestSubmission(sessionID: String) -> Submission? {
        guard let requestID = latestRequestIDBySessionID[sessionID] else { return nil }
        return submissionsByRequestID[requestID]
    }

    func submission(requestID: String) -> Submission? {
        submissionsByRequestID[requestID]
    }

    /// 发起一次提交。
    ///
    /// 返回值是本次提交的身份；调用方应保留它用于对账。
    ///
    /// 已经有一次 `.submitting` 或 `.responseUnknown` 的提交在途时**拒绝**新的提交：
    /// 放行会让同一个会话上出现两条无法区分先后的用户输入。这条判断放在这里而不是
    /// 上层，是因为"能不能再发一条"依赖的正是本类型持有的状态。
    @discardableResult
    func submit(sessionID: String, text: String, requestID: String) async -> Submission {
        if let latest = latestSubmission(sessionID: sessionID) {
            switch latest.state {
            case .submitting, .responseUnknown:
                // 在途或结果未知：不放行新提交，且**不谎称上游拒绝了它**——
                // 这次提交从未发出，用户该做的是对账而不是重试。
                // 注意这里不改写该会话的 latest：被拒的这次没有发生。
                return Submission(
                    requestID: requestID, sessionID: sessionID, text: text,
                    state: .idle,
                    blockReason: .previousSubmissionUnconfirmed
                )
            case .idle, .accepted, .rejected:
                break
            }
        }

        var submission = Submission(
            requestID: requestID, sessionID: sessionID, text: text, state: .submitting
        )
        submissionsByRequestID[requestID] = submission
        latestRequestIDBySessionID[sessionID] = requestID

        do {
            try await sendPrompt(sessionID, requestID, text)
            // 上游明确接受。**这不表示生成完成**（契约 D4），只是"已收到"。
            submission.state = .accepted
        } catch {
            submission.state = Self.stateForFailure(error)
        }
        submissionsByRequestID[requestID] = submission
        return submission
    }

    /// 把一次失败翻译成状态。
    ///
    /// 这是本类型最关键的一处判断：**只有携带上游业务结论的失败才算 `rejected`**，
    /// 其余一律 `responseUnknown`。宁可让用户多按一次"对账"，也不能把一次可能已经
    /// 执行的写操作当成没发生。
    static func stateForFailure(_ error: Error) -> SubmissionState {
        guard let transport = error as? HarnessTransportError else {
            // 认不出的错误同样按未知处理：猜错方向的代价不对称——
            // 把"可能已执行"当成"没执行"会重复副作用，反之只是多一次对账。
            return .responseUnknown(String(describing: error))
        }
        switch transport {
        case .business(let remote):
            // 上游给出了明确业务结论（例如 session/agent-busy）。这类重试是安全的。
            return .rejected(remote.message ?? remote.diagnosticCode)
        case .carrier(let remote):
            // 载体错误帧要**逐码**看，不能一概当业务结论。
            //
            // `gateway/service-unavailable` 是中继在上游物理断流时发的：那次写完全
            // 可能已经落到上游，只是结论没回来。把它当成"没执行、可重试"会重复副作用，
            // 正是本类型头注释要防住的那个后果——所以它走 `responseUnknown`。
            // 真正的业务码（越权、参数非法、agent-busy 等）才是可重试的明确拒绝。
            if HarnessTransportError.carrierCodeIsRecoverable(remote.diagnosticCode) {
                return .responseUnknown(transport.diagnosticSummary)
            }
            return .rejected(remote.message ?? remote.diagnosticCode)
        case .rejected(_, let message):
            // 中继本地策略拒绝（越权、参数非法）：重试不会改变结论。
            return .rejected(message)
        case .unauthorized(let status):
            // 凭据失效：明确结论，但需要换凭据而不是重试同一次写。
            return .rejected(L10n.format("harness.credentials_expired_http", status))
        case .server, .malformedResponse, .unattributedResponse, .notConnected,
             .closed, .timedOut, .continuityLost, .unsupportedInteraction, .cancelled:
            // 这些都可能发生在"上游已经执行、只是我们没拿到结论"之后。
            return .responseUnknown(transport.diagnosticSummary)
        }
    }

    /// 请求停止当前轮次。
    ///
    /// 与提交共享同一条原则：停止的响应未知时也不自动重发。已读版本只有 session 级
    /// cancel，因此它停的是"这个会话正在跑的轮次"——契约要求如实记录这点，
    /// 不宣传成原子 turn 级条件取消。
    func cancel(sessionID: String) async -> SubmissionState {
        do {
            try await sendCancel(sessionID)
            return .accepted
        } catch {
            return Self.stateForFailure(error)
        }
    }

    /// 一次提交被对账确认后，清掉在途状态。
    ///
    /// 由读取对账（`session/page` 里出现该 requestId 的 user/message）或上游重投确认调用。
    /// 这是 `.responseUnknown` 的唯一合法出口——它不能被超时或"用户等太久"清掉。
    func resolveAfterReconciliation(requestID: String) {
        guard var resolved = submissionsByRequestID[requestID] else { return }
        guard case .responseUnknown = resolved.state else { return }
        resolved.state = .accepted
        submissionsByRequestID[requestID] = resolved
    }
}
