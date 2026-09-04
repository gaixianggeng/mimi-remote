import Foundation
import Network

enum AgentSessionForkReason: String, Hashable, Sendable {
    case worktreeHandoff = "worktree_handoff"
    case duplicate = "duplicate"
}

// API 外观、网络状态源与事件批处理从 SessionStore 生命周期实现中解耦。
enum NetworkReachabilityStatus: Equatable, Sendable {
    case unknown
    case satisfied
    case unsatisfied
}

struct NetworkPathStatusUpdate: Equatable, Sendable {
    let sequence: UInt64
    let status: NetworkReachabilityStatus
}

protocol NetworkPathStatusSource: AnyObject {
    var currentStatus: NetworkReachabilityStatus { get }
    var onStatusChange: ((NetworkPathStatusUpdate) -> Void)? { get set }

    func start()
    func stop()
}

/// 生产环境的 Network.framework 适配层。SessionStore 只依赖精简状态协议，测试可以注入确定性事件源。
final class NWNetworkPathStatusSource: NetworkPathStatusSource {
    let monitor: NWPathMonitor
    let queue: DispatchQueue
    let lock = NSLock()
    var statusStorage: NetworkReachabilityStatus = .unknown
    var handlerStorage: ((NetworkPathStatusUpdate) -> Void)?
    var sequenceStorage: UInt64 = 0
    var started = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        self.queue = DispatchQueue(label: "com.gaixianggeng.mimi.network-path")
    }

    var currentStatus: NetworkReachabilityStatus {
        lock.withLock { statusStorage }
    }

    var onStatusChange: ((NetworkPathStatusUpdate) -> Void)? {
        get { lock.withLock { handlerStorage } }
        set { lock.withLock { handlerStorage = newValue } }
    }

    func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.publish(path.status == .satisfied ? .satisfied : .unsatisfied)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard started else { return false }
            started = false
            handlerStorage = nil
            return true
        }
        guard shouldStop else { return }
        monitor.cancel()
    }

    func publish(_ status: NetworkReachabilityStatus) {
        let delivery = lock.withLock { () -> (((NetworkPathStatusUpdate) -> Void)?, NetworkPathStatusUpdate) in
            statusStorage = status
            // 序号必须在 NWPathMonitor 的串行回调里生成，不能等 MainActor Task 开始后再编号；
            // 否则快速断网再联网时，晚执行的旧 Task 仍可能拿到更大的序号并覆盖新状态。
            sequenceStorage &+= 1
            return (handlerStorage, NetworkPathStatusUpdate(sequence: sequenceStorage, status: status))
        }
        delivery.0?(delivery.1)
    }
}

/// 注入了 API mock 的测试默认使用稳定在线源，避免每个单元测试都启动系统 monitor。
final class StaticNetworkPathStatusSource: NetworkPathStatusSource {
    let currentStatus: NetworkReachabilityStatus
    var onStatusChange: ((NetworkPathStatusUpdate) -> Void)?

    init(_ status: NetworkReachabilityStatus) {
        self.currentStatus = status
    }

    func start() {}
    func stop() { onStatusChange = nil }
}

protocol SessionStoreAPIClient {
    func projects() async throws -> [AgentProject]
    func modelOptions() async throws -> [CodexAppServerModelOption]
    func permissionProfiles(cwd: String) async throws -> [CodexAppServerPermissionProfileSummary]
    func runtimeChannelAvailable(runtimeProvider: String) async throws -> Bool
    func capabilities(path: String?, forceReload: Bool) async throws -> CapabilityListResponse
    func resolveWorkspace(path: String) async throws -> AgentWorkspace
    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse
    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse
    func listWorktrees() async throws -> [WorktreeListItem]
    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse
    func pruneMissingWorktrees() async throws -> WorktreePruneResponse
    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse
    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse
    func listDirectories(path: String) async throws -> DirectoryListResponse
    func readFile(path: String) async throws -> FileReadResponse
    func readHistoryMedia(id: String) async throws -> FileReadResponse
    func readHistoryOutput(id: String) async throws -> FileReadResponse
    func commandActions(path: String) async throws -> [AgentCommandAction]
    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse
    func gitStatus(path: String) async throws -> GitStatusResponse
    func gitStatusSummary(path: String) async throws -> GitStatusResponse
    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse
    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse
    func gitCommit(path: String, message: String) async throws -> GitStatusResponse
    func gitPush(path: String, remote: String?) async throws -> GitPushResponse
    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse
    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse
    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse
    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse
    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse
    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?) async throws -> VoiceTranscriptionResponse
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession]
    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage
    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage
    func sessionsPage(projectID: String?, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage
    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage
    func sessionsPage(projectID: String?, runtimeProvider: String, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage
    func sessionsPage(workspace: AgentWorkspace, runtimeProvider: String, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage
    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage
    func controlledGlobalSessionsPage(runtimeProvider: String, cursor: String?, limit: Int?) async throws -> SessionsPage
    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse
    func threadGoal(threadID: String) async throws -> ThreadGoal?
    func setThreadGoal(threadID: String, objective: String?, status: ThreadGoalStatus?, tokenBudget: Int64?) async throws -> ThreadGoal
    func clearThreadGoal(threadID: String) async throws
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse
    func forkSession(
        threadID: String,
        workspace: AgentWorkspace,
        reason: AgentSessionForkReason,
        lastTurnID: TurnID?
    ) async throws -> AgentSession
    func stopSession(id: String) async throws
    func setSessionArchived(id: String, archived: Bool) async throws
    func setThreadName(threadID: String, name: String) async throws
    func compactThread(threadID: String) async throws
    func unsubscribeThread(threadID: String) async throws -> CodexAppServerThreadUnsubscribeStatus?
    func startReview(threadID: String, target: CodexAppServerReviewTarget, delivery: CodexAppServerReviewDelivery?) async throws -> CodexAppServerReviewStartResult
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage]
    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage
    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage
    func historyTurnItemsPage(
        sessionID: String,
        continuation: HistoryTurnItemsContinuation
    ) async throws -> HistoryTurnItemsPage
    /// 仅在底层支持原生 turn 分页时返回最新完整 turn；旧 thread/read 实现返回 nil，
    /// 调用方必须回退完整历史，不能把一条 message 误当成一个 turn。
    func latestTurnHistoryPage(sessionID: String) async throws -> HistoryMessagesPage?
    func refreshRateLimit(sessionID: String?) async throws -> RateLimitSummary?
    func refreshRateLimit(runtimeProvider: String) async throws -> RateLimitSummary?
    func refreshAccountTokenUsage() async throws -> AccountTokenUsageFetch
    func refreshAccountTokenUsage(forceRefresh: Bool) async throws -> AccountTokenUsageFetch
}

extension SessionStoreAPIClient {
    func sessionsPage(
        projectID: String?,
        runtimeProvider: String,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        try await sessionsPage(
            projectID: projectID,
            cursor: cursor,
            limit: limit,
            consistency: consistency
        )
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        runtimeProvider: String,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        try await sessionsPage(
            workspace: workspace,
            cursor: cursor,
            limit: limit,
            consistency: consistency
        )
    }

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage {
        SessionsPage(sessions: [])
    }

    /// 默认忽略 runtime 维度，回落到单一 runtime 的实现：既有 mock 与只服务 Codex
    /// 的客户端无需改动。真正按 runtime 分头请求的是路由 facade。
    func controlledGlobalSessionsPage(
        runtimeProvider: String,
        cursor: String?,
        limit: Int?
    ) async throws -> SessionsPage {
        try await controlledGlobalSessionsPage(cursor: cursor, limit: limit)
    }

    func runtimeChannelAvailable(runtimeProvider: String) async throws -> Bool {
        let value = runtimeProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty || value == "codex" || value == "openai"
    }

    func refreshRateLimit(sessionID: String?) async throws -> RateLimitSummary? {
        nil
    }
    func refreshRateLimit(runtimeProvider: String) async throws -> RateLimitSummary? {
        try await refreshRateLimit(sessionID: nil)
    }
    func refreshAccountTokenUsage() async throws -> AccountTokenUsageFetch {
        // 没有实现该能力的客户端是“不提供”，不是“请求失败”。
        .unsupported
    }
    func refreshAccountTokenUsage(forceRefresh: Bool) async throws -> AccountTokenUsageFetch {
        // 兼容旧客户端与测试替身；生产客户端会覆盖该方法并把强制刷新提示传到 agentd。
        try await refreshAccountTokenUsage()
    }
    func modelOptions() async throws -> [CodexAppServerModelOption] {
        []
    }

    func permissionProfiles(cwd: String) async throws -> [CodexAppServerPermissionProfileSummary] {
        []
    }

    func capabilities(path: String?, forceReload: Bool) async throws -> CapabilityListResponse {
        throw AgentAPIError.invalidResponse
    }

    func capabilities(path: String?) async throws -> CapabilityListResponse {
        try await capabilities(path: path, forceReload: false)
    }

    func session(id: String) async throws -> SessionResponse {
        try await session(id: id, afterSeq: nil)
    }

    func setSessionArchived(id: String, archived: Bool) async throws {
        throw AgentAPIError.invalidResponse
    }

    func setThreadName(threadID: String, name: String) async throws {
        throw AgentAPIError.invalidResponse
    }

    func compactThread(threadID: String) async throws {
        throw AgentAPIError.invalidResponse
    }

    func unsubscribeThread(threadID: String) async throws -> CodexAppServerThreadUnsubscribeStatus? {
        throw AgentAPIError.invalidResponse
    }

    func startReview(
        threadID: String,
        target: CodexAppServerReviewTarget,
        delivery: CodexAppServerReviewDelivery? = nil
    ) async throws -> CodexAppServerReviewStartResult {
        throw AgentAPIError.invalidResponse
    }

    func threadGoal(threadID: String) async throws -> ThreadGoal? {
        throw AgentAPIError.invalidResponse
    }

    func setThreadGoal(threadID: String, objective: String?, status: ThreadGoalStatus?, tokenBudget: Int64?) async throws -> ThreadGoal {
        throw AgentAPIError.invalidResponse
    }

    func clearThreadGoal(threadID: String) async throws {
        throw AgentAPIError.invalidResponse
    }

    func forkSession(
        threadID: String,
        workspace: AgentWorkspace,
        reason: AgentSessionForkReason,
        lastTurnID: TurnID?
    ) async throws -> AgentSession {
        throw AgentAPIError.invalidResponse
    }

    func forkSession(
        threadID: String,
        workspace: AgentWorkspace,
        reason: AgentSessionForkReason
    ) async throws -> AgentSession {
        try await forkSession(
            threadID: threadID,
            workspace: workspace,
            reason: reason,
            lastTurnID: nil
        )
    }

    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/workspaces/resolve。
        throw AgentAPIError.invalidResponse
    }

    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/worktrees/create。
        throw AgentAPIError.invalidResponse
    }

    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/worktrees/branches。
        throw AgentAPIError.invalidResponse
    }

    func listWorktrees() async throws -> [WorktreeListItem] {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/worktrees/list。
        throw AgentAPIError.invalidResponse
    }

    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/worktrees/delete。
        throw AgentAPIError.invalidResponse
    }

    func pruneMissingWorktrees() async throws -> WorktreePruneResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/worktrees/prune。
        throw AgentAPIError.invalidResponse
    }

    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse {
        // 清理预览必须先由 agentd 根据固定保留策略重新计算，客户端不在本地猜候选。
        throw AgentAPIError.invalidResponse
    }

    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse {
        // 默认替身不执行破坏性操作；真实 client 固定走带 confirm 的 cleanup API。
        throw AgentAPIError.invalidResponse
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/directories/list。
        throw AgentAPIError.invalidResponse
    }

    func readFile(path: String) async throws -> FileReadResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/files/read。
        throw AgentAPIError.invalidResponse
    }

    func readHistoryMedia(id: String) async throws -> FileReadResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/app-server/history-media/{id}。
        throw AgentAPIError.invalidResponse
    }

    func readHistoryOutput(id: String) async throws -> FileReadResponse {
        // 超大历史过程输出只能通过 agentd 鉴权控制面按需读取。
        throw AgentAPIError.invalidResponse
    }

    func commandActions(path: String) async throws -> [AgentCommandAction] {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/actions/list。
        throw AgentAPIError.invalidResponse
    }

    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/actions/run。
        throw AgentAPIError.invalidResponse
    }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/status。
        throw AgentAPIError.invalidResponse
    }

    func gitStatusSummary(path: String) async throws -> GitStatusResponse {
        // 测试替身未关心摘要时复用完整状态；生产 client 会发送 summary_only=true。
        try await gitStatus(path: path)
    }

    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/action。
        throw AgentAPIError.invalidResponse
    }

    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/action。
        throw AgentAPIError.invalidResponse
    }

    func gitCommit(path: String, message: String) async throws -> GitStatusResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/commit。
        throw AgentAPIError.invalidResponse
    }

    func gitPush(path: String, remote: String?) async throws -> GitPushResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/push。
        throw AgentAPIError.invalidResponse
    }

    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse {
        // 快捷发布涉及 stage、commit 和 push，测试替身默认不执行任何写操作。
        throw AgentAPIError.invalidResponse
    }

    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse {
        // TestFlight 能力必须由主机预检，客户端不能根据文件名自行推断。
        throw AgentAPIError.invalidResponse
    }

    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse {
        // TestFlight 是外部发布动作，默认替身不执行。
        throw AgentAPIError.invalidResponse
    }

    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/pull-request。
        throw AgentAPIError.invalidResponse
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/pull-request/status。
        throw AgentAPIError.invalidResponse
    }

    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?) async throws -> VoiceTranscriptionResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/voice/transcribe。
        throw AgentAPIError.invalidResponse
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        SessionsPage(sessions: try await sessions(projectID: projectID, cursor: cursor, limit: limit))
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await sessionsPage(projectID: workspace.rootProjectID ?? workspace.id, cursor: cursor, limit: limit)
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage {
        try await sessionsPage(projectID: projectID, cursor: cursor, limit: limit)
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage {
        try await sessionsPage(workspace: workspace, cursor: cursor, limit: limit)
    }

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        // 旧测试替身与尚未升级的服务默认视为不支持；SessionStore 会静默保留本地搜索结果。
        throw AgentAPIError.invalidResponse
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        HistoryMessagesPage(messages: try await messages(sessionID: sessionID, before: before, limit: limit))
    }

    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit)
    }

    func latestTurnHistoryPage(sessionID: String) async throws -> HistoryMessagesPage? {
        nil
    }

    func historyTurnItemsPage(
        sessionID: String,
        continuation: HistoryTurnItemsContinuation
    ) async throws -> HistoryTurnItemsPage {
        throw AgentAPIError.invalidResponse
    }

}

@MainActor
final class TerminalStreamStore {
    /// 每个数组元素代表一个“逻辑事件”。连续文本增量只保存原始 chunk，
    /// 不在 append 时复制已有前缀；真正交付前再一次性线性拼接，避免高频 token 造成 O(n²)。
    private struct BufferedEvent {
        var event: AgentEvent
        private var textChunks: [String]?

        init(_ event: AgentEvent) {
            self.event = event
            switch event {
            case .assistantDelta(let delta, _):
                textChunks = [delta.text]
            case .logDelta(let delta, _):
                textChunks = [delta.text]
            default:
                textChunks = nil
            }
        }

        var canMergeText: Bool {
            textChunks != nil
        }

        mutating func appendTextChunk(from next: AgentEvent) {
            switch next {
            case .assistantDelta(let delta, _):
                textChunks?.append(delta.text)
                event = next
            case .logDelta(let delta, _):
                textChunks?.append(delta.text)
                event = next
            default:
                assertionFailure("only text events can append chunks")
            }
        }

        mutating func replace(with next: AgentEvent) {
            event = next
            textChunks = nil
        }

        func materialized() -> AgentEvent {
            guard let textChunks else {
                return event
            }
            let text = textChunks.joined()
            switch event {
            case .assistantDelta(let delta, let metadata):
                return .assistantDelta(
                    AgentDelta(text: text, role: delta.role, kind: delta.kind),
                    metadata
                )
            case .logDelta(let delta, let metadata):
                return .logDelta(
                    LogDelta(text: text, stream: delta.stream),
                    metadata
                )
            default:
                assertionFailure("text chunks must belong to a text event")
                return event
            }
        }
    }

    /// 以引用类型持有单个 lease 的数组，避免从 Dictionary 取出值后每个 append 都触发数组 CoW。
    private final class LeaseBuffer {
        var events: [BufferedEvent] = []
    }

    let maxBatchSize: Int
    private var eventsByLease: [HostSessionLease: LeaseBuffer] = [:]

    init(maxBatchSize: Int = 64) {
        self.maxBatchSize = max(1, maxBatchSize)
    }

    func append(_ event: AgentEvent, lease: HostSessionLease) -> Bool {
        let buffer: LeaseBuffer
        if let existing = eventsByLease[lease] {
            buffer = existing
        } else {
            let created = LeaseBuffer()
            eventsByLease[lease] = created
            buffer = created
        }

        if let previousIndex = buffer.events.indices.last,
           Self.canMergeContiguous(buffer.events[previousIndex].event, with: event) {
            if buffer.events[previousIndex].canMergeText {
                buffer.events[previousIndex].appendTextChunk(from: event)
            } else {
                // messageCompleted 的 plan/reasoningSummary 是累计快照，保留最新事件。
                buffer.events[previousIndex].replace(with: event)
            }
        } else {
            buffer.events.append(BufferedEvent(event))
        }
        return buffer.events.count >= maxBatchSize
    }

    func drain(lease: HostSessionLease) -> [AgentEvent] {
        guard let buffer = eventsByLease.removeValue(forKey: lease) else {
            return []
        }
        return buffer.events.map { $0.materialized() }
    }

    func removeAll(lease: HostSessionLease) {
        eventsByLease.removeValue(forKey: lease)
    }

    func removeAll(profileID: String) {
        eventsByLease = eventsByLease.filter { $0.key.hostScope.profileID != profileID }
    }

    /// 与 AgentEvent.mergingContiguous 保持同一合并判定，但不构造拼接后的 String。
    /// 这让 append 只追加 chunk/逻辑事件，文本复制集中到 drain 的一次性 joined()。
    private static func canMergeContiguous(_ event: AgentEvent, with next: AgentEvent) -> Bool {
        switch (event, next) {
        case let (.assistantDelta(previousDelta, previousMetadata), .assistantDelta(nextDelta, nextMetadata)):
            return sameItem(previousMetadata, nextMetadata)
                && previousDelta.role == nextDelta.role
                && previousDelta.kind == nextDelta.kind
        case let (.logDelta(previousDelta, previousMetadata), .logDelta(nextDelta, nextMetadata)):
            return sameItem(previousMetadata, nextMetadata)
                && previousDelta.stream == nextDelta.stream
        case let (.messageCompleted(previousMessage, previousMetadata), .messageCompleted(nextMessage, nextMetadata)):
            return previousMessage.role == .system
                && nextMessage.role == .system
                && previousMessage.kind == nextMessage.kind
                && (nextMessage.kind == .plan || nextMessage.kind == .reasoningSummary)
                && sameItem(previousMetadata, nextMetadata)
        default:
            return false
        }
    }

    private static func sameItem(_ lhs: AgentEventMetadata, _ rhs: AgentEventMetadata) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.turnID == rhs.turnID
            && lhs.itemID == rhs.itemID
            && lhs.messageID == rhs.messageID
    }

}
