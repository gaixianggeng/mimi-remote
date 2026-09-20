import Foundation

/// 宿主级交互的待处理集合：审批与选择题。
///
/// ## 为什么它独立于页面
///
/// `$events` 是**宿主级**通道：别的会话（Harness Web、子 Agent）的审批与追问同样送到这里，
/// 而且**可能在用户从未打开对应会话时到达**（契约 D5）。因此：
/// - 已授权的交互在这里登记，不依附任何对话页面；页面只消费同一份数据。
/// - 页面释放不能移除 pending：那会让"用户离开页面"等于"静默丢弃一次授权请求"。
///
/// ## 状态机（契约 D5）
///
/// ```
/// pending → submitting → resolved
///                      ↘ responseUnknown
///          ↘ externallyCancelled
/// ```
///
/// 两条硬规则：
/// 1. **只有明确成功或同 eventId 的上游 cancel 才能移除 pending。**
///    超时、页面关闭、"用户两分钟没理"都不行——把未决请求标成已解决，
///    等于替用户做了一个他没做的决定。
/// 2. **`responseUnknown` 是独立状态，且不自动重发。** 回传失败的请求可能已经生效，
///    自动重发会让一次审批被应用两次。
@MainActor
final class HarnessInteractionStore {

    /// 一条待处理交互的状态。
    enum State: Equatable {
        /// 等待用户应答。
        case pending
        /// 已提交，等待上游结论。
        case submitting
        /// 上游明确接受。
        case resolved
        /// 回传结果未知（**可能已生效**）。不自动重发，等对账。
        case responseUnknown(String)
        /// 上游（或另一端）已取消/解答。撤卡，不再可应答。
        case externallyCancelled
    }

    /// 一条交互请求。
    struct PendingInteraction: Identifiable, Equatable {
        let eventID: String
        let sessionID: String
        /// waterfall 事件名：approval/request 或 user-questions/request。
        let event: String
        let request: HarnessWaterfallPayload
        var state: State
        /// 投递它的连接代次。应答必须来自同一代次（重连后旧卡不替新连接做决定）。
        let generation: UInt64

        var id: String { eventID }

        var isApproval: Bool { event == HarnessWireWaterfallEvent.approvalRequest }
        var isQuestion: Bool { event == HarnessWireWaterfallEvent.userQuestions }
    }

    private var pending: [String: PendingInteraction] = [:]
    private enum TerminalState: Equatable {
        case resolved
        /// cancel 只结算其所在代次；新代次重投可受控恢复成 pending。
        case externallyCancelled(generation: UInt64)
    }

    /// 终态 eventId。明确解决永久结算；外部 cancel 只结算到其可信代次。
    private var terminal: [String: TerminalState] = [:]

    var pendingCount: Int { pending.count }

    var pendingInteractions: [PendingInteraction] {
        pending.values.sorted { $0.eventID < $1.eventID }
    }

    func interaction(eventID: String) -> PendingInteraction? { pending[eventID] }

    // MARK: - 接收

    /// 登记一条交互。
    ///
    /// 返回是否新增。重复投递（同 eventId）更新原卡片的内容与状态而不是新增副本——
    /// 重连后上游会重投同一个 eventId，新增副本会让用户看到两张同样的卡。
    @discardableResult
    func deliver(
        eventID: String,
        sessionID: String,
        event: String,
        request: HarnessWaterfallPayload,
        generation: UInt64
    ) -> Bool {
        let id = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        if let terminalState = terminal[id] {
            switch terminalState {
            case .resolved:
                return false
            case .externallyCancelled(let cancelledGeneration):
                guard generation > cancelledGeneration else { return false }
                // 新连接上游重投代表它仍待处理；只恢复卡片，不重发旧决定。
                terminal[id] = nil
            }
        }

        if var existing = pending[id] {
            // 同 eventId 重投：更新内容，但**保留应答中的状态**——
            // 重投不能把一次正在回传的应答回退成"待应答"，那会让用户重复决定。
            if case .submitting = existing.state { return false }
            if case .responseUnknown = existing.state { return false }
            existing = PendingInteraction(
                eventID: id, sessionID: sessionID, event: event,
                request: request, state: .pending, generation: generation
            )
            pending[id] = existing
            return false
        }

        pending[id] = PendingInteraction(
            eventID: id, sessionID: sessionID, event: event,
            request: request, state: .pending, generation: generation
        )
        return true
    }

    // MARK: - 应答

    /// 认领一次应答。返回可否发起回传。
    ///
    /// 只有"待应答 + 代次匹配"才允许；其余情况分两类，这个区分是安全边界：
    /// - 已终结 → 空操作（迟到应答不是错误）。
    /// - 正在应答 / 代次不符 → 拒绝（伪造或重复）。
    enum ClaimResult: Equatable {
        case accepted(PendingInteraction)
        /// 已终结：迟到应答是空操作。
        case settled
        /// 正在应答中。
        case alreadySubmitting
        /// 连接代次已失效。
        case staleGeneration
        /// 从未投递给本连接。
        case unknown
    }

    func claim(eventID: String, generation: UInt64) -> ClaimResult {
        let id = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .unknown }
        if terminal[id] != nil { return .settled }
        guard var existing = pending[id] else { return .unknown }
        guard existing.generation == generation else { return .staleGeneration }

        switch existing.state {
        case .pending:
            existing.state = .submitting
            pending[id] = existing
            return .accepted(existing)
        case .submitting:
            return .alreadySubmitting
        case .responseUnknown:
            // 结果未知时不允许再次应答：重发可能让一次审批被应用两次。
            return .alreadySubmitting
        case .resolved, .externallyCancelled:
            return .settled
        }
    }

    /// 回传成功：终结该交互。
    func resolve(eventID: String) {
        let id = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let existing = pending[id] else { return }
        var updated = existing
        updated.state = .resolved
        pending[id] = updated
        // 立刻从待处理集合移除：卡片不再可应答。
        pending[id] = nil
        terminal[id] = .resolved
    }

    /// 回传结果未知：**保留卡片并标记**，不解除应答锁。
    ///
    /// 不自动重发（契约 D5）：这个请求可能已经生效，重发会让一次审批被应用两次。
    /// 上层的正确动作是重连后由 Harness 重投或读对账，而不是再发一次。
    func markResponseUnknown(eventID: String, detail: String) {
        let id = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var existing = pending[id] else { return }
        existing.state = .responseUnknown(detail)
        pending[id] = existing
    }

    /// 回传明确失败：放回待应答，允许用户重试。
    ///
    /// 只有**上游明确拒绝**才走这里——那是"没生效"的确定结论。
    func releaseAfterExplicitFailure(eventID: String) {
        let id = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var existing = pending[id] else { return }
        if case .responseUnknown = existing.state { return }
        existing.state = .pending
        pending[id] = existing
    }

    // MARK: - 撤卡

    /// 另一端先应答了（或上游取消）：撤卡并阻止同一 eventId 复活。
    ///
    /// 返回是否确实撤下了一张卡——只有本连接展示过的才需要通知 UI。
    @discardableResult
    func cancelExternally(eventID: String, generation: UInt64) -> Bool {
        let id = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let existing = pending[id] else {
            // 未投递给本连接的 eventId：记终态防"cancel 先于 waterfall"时复活，
            // 但不通知 UI（本连接从没展示过它）。
            terminal[id] = .externallyCancelled(generation: generation)
            return false
        }
        guard existing.generation == generation else {
            // 旧连接迟到的 cancel 不能撤掉新连接刚重投的卡片。
            return false
        }
        pending[id] = nil
        terminal[id] = .externallyCancelled(generation: generation)
        return true
    }

    /// 撤权：只丢弃该会话的待处理交互。
    ///
    /// 与 `cancelExternally` 的差别是刻意的：**不记终态**——撤权后重新获得授权时，
    /// 上游重投的卡片应当能正常登记（重复投递本身会再过一次授权检查）。
    /// 若记了终态，重新授权后就再也收不到这张卡了。
    func forgetSession(_ sessionID: String) {
        let target = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        for (eventID, interaction) in pending where interaction.sessionID == target {
            pending[eventID] = nil
        }
    }

    /// 重连：清掉属于旧代次的待处理项。
    ///
    /// 旧代次的卡片不得替新连接做决定（契约 D5）。**不记终态**：
    /// 上游会在新连接上重投仍 pending 的请求。
    func dropStaleGeneration(_ generation: UInt64) {
        for (eventID, interaction) in pending where interaction.generation < generation {
            pending[eventID] = nil
        }
    }

    /// 清空。仅用于彻底断开。
    func removeAll() {
        pending.removeAll()
        terminal.removeAll()
    }
}
