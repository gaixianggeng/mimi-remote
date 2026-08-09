import Foundation

// API/WebSocket 适配器与多 runtime 路由独立于 runtime actor 的连接编排。
final class CodexAppServerSessionAPIClient: SessionStoreAPIClient {
    private let runtime: CodexAppServerSessionRuntime

    init(runtime: CodexAppServerSessionRuntime) {
        self.runtime = runtime
    }

    func projects() async throws -> [AgentProject] {
        try await runtime.projects()
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        try await runtime.modelOptions()
    }

    func runtimeChannelAvailable(runtimeProvider: String) async throws -> Bool {
        try await runtime.channelAvailable(runtimeProvider: runtimeProvider)
    }

    func externalActivities() async throws -> ExternalActivityResponse? {
        try await runtime.externalActivities()
    }

    func capabilities(path: String?, forceReload: Bool) async throws -> CapabilityListResponse {
        try await runtime.capabilities(path: path, forceReload: forceReload)
    }

    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        try await runtime.resolveWorkspace(path: path)
    }

    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        try await runtime.createWorktree(path: path, name: name, base: base, branch: branch)
    }

    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse {
        try await runtime.worktreeBranches(path: path)
    }

    func listWorktrees() async throws -> [WorktreeListItem] {
        try await runtime.listWorktrees()
    }

    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse {
        try await runtime.deleteWorktree(path: path, force: force)
    }

    func pruneMissingWorktrees() async throws -> WorktreePruneResponse {
        try await runtime.pruneMissingWorktrees()
    }

    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse {
        try await runtime.previewWorktreeCleanup()
    }

    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse {
        try await runtime.executeWorktreeCleanup(paths: paths, planID: planID)
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        try await runtime.listDirectories(path: path)
    }

    func readFile(path: String) async throws -> FileReadResponse {
        try await runtime.readFile(path: path)
    }

    func readHistoryMedia(id: String) async throws -> FileReadResponse {
        try await runtime.readHistoryMedia(id: id)
    }

    func readHistoryOutput(id: String) async throws -> FileReadResponse {
        try await runtime.readHistoryOutput(id: id)
    }

    func commandActions(path: String) async throws -> [AgentCommandAction] {
        try await runtime.commandActions(path: path)
    }

    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        try await runtime.runCommandAction(path: path, id: id, confirmed: confirmed)
    }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        try await runtime.gitStatus(path: path)
    }

    func gitStatusSummary(path: String) async throws -> GitStatusResponse {
        try await runtime.gitStatusSummary(path: path)
    }

    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse {
        try await runtime.gitAction(path: path, action: action, files: files)
    }

    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse {
        try await runtime.gitPatchAction(path: path, action: action, patch: patch)
    }

    func gitCommit(path: String, message: String) async throws -> GitStatusResponse {
        try await runtime.gitCommit(path: path, message: message)
    }

    func gitPush(path: String, remote: String?) async throws -> GitPushResponse {
        try await runtime.gitPush(path: path, remote: remote)
    }

    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse {
        try await runtime.gitQuickPublish(path: path, message: message, remote: remote, confirmed: confirmed)
    }

    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse {
        try await runtime.gitTestFlightStatus(path: path)
    }

    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse {
        try await runtime.gitTestFlightRun(path: path, whatToTest: whatToTest, confirmed: confirmed)
    }

    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse {
        try await runtime.gitCreatePullRequest(path: path, title: title, body: body, draft: draft)
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        try await runtime.gitPullRequestStatus(path: path)
    }

    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?) async throws -> VoiceTranscriptionResponse {
        try await runtime.transcribeVoice(
            filename: filename,
            contentType: contentType,
            audioData: audioData,
            language: language
        )
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await sessionsPage(projectID: projectID, cursor: cursor, limit: limit).sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await runtime.sessionsPage(projectID: projectID, cursor: cursor, limit: limit)
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await runtime.sessionsPage(workspace: workspace, cursor: cursor, limit: limit)
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage {
        try await runtime.sessionsPage(projectID: projectID, cursor: cursor, limit: limit, consistency: consistency)
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage {
        try await runtime.sessionsPage(workspace: workspace, cursor: cursor, limit: limit, consistency: consistency)
    }

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await runtime.controlledGlobalSessionsPage(cursor: cursor, limit: limit)
    }

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        try await runtime.searchSessions(query: query, cursor: cursor, limit: limit)
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        try await runtime.session(id: id, afterSeq: afterSeq)
    }

    func refreshRateLimit(sessionID: String?) async throws -> RateLimitSummary? {
        await runtime.refreshRateLimit()
    }

    func refreshRateLimit(runtimeProvider: String) async throws -> RateLimitSummary? {
        await runtime.refreshRateLimit()
    }

    func refreshAccountTokenUsage() async throws -> AccountTokenUsageFetch {
        await runtime.refreshAccountTokenUsage()
    }

    func refreshAccountTokenUsage(forceRefresh: Bool) async throws -> AccountTokenUsageFetch {
        await runtime.refreshAccountTokenUsage(forceRefresh: forceRefresh)
    }

    func threadGoal(threadID: String) async throws -> ThreadGoal? {
        try await runtime.threadGoal(threadID: threadID)
    }

    func setThreadGoal(threadID: String, objective: String?, status: ThreadGoalStatus?, tokenBudget: Int64?) async throws -> ThreadGoal {
        try await runtime.setThreadGoal(threadID: threadID, objective: objective, status: status, tokenBudget: tokenBudget)
    }

    func clearThreadGoal(threadID: String) async throws {
        try await runtime.clearThreadGoal(threadID: threadID)
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        try await runtime.createSession(payload)
    }

    func stopSession(id: String) async throws {
        try await runtime.stopSession(id: id)
    }

    func setSessionArchived(id: String, archived: Bool) async throws {
        try await runtime.setSessionArchived(id: id, archived: archived)
    }

    func setThreadName(threadID: String, name: String) async throws {
        try await runtime.setThreadName(threadID: threadID, name: name)
    }

    func compactThread(threadID: String) async throws {
        try await runtime.compactThread(threadID: threadID)
    }

    func unsubscribeThread(threadID: String) async throws -> CodexAppServerThreadUnsubscribeStatus? {
        try await runtime.unsubscribeThread(threadID: threadID)
    }

    func releaseThreadWriterWhenIdle(threadID: String) async throws -> ThreadHandoffResponse {
        try await runtime.releaseThreadWriterWhenIdle(threadID: threadID)
    }

    func startReview(
        threadID: String,
        target: CodexAppServerReviewTarget,
        delivery: CodexAppServerReviewDelivery? = nil
    ) async throws -> CodexAppServerReviewStartResult {
        try await runtime.startReview(threadID: threadID, target: target, delivery: delivery)
    }

    func forkSession(
        threadID: String,
        workspace: AgentWorkspace,
        reason: AgentSessionForkReason
    ) async throws -> AgentSession {
        try await runtime.forkSession(threadID: threadID, workspace: workspace, reason: reason)
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit).messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit, loadMode: .full)
    }

    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage {
        try await runtime.messagesPage(sessionID: sessionID, before: before, limit: limit, loadMode: loadMode)
    }
}

final class AppServerRuntimeRouteStore {
    private var lock = NSLock()
    private var runtimeBySessionID: [SessionID: String] = [:]

    func remember(_ session: AgentSession) {
        remember(session.runtimeProvider ?? session.source, for: session.id)
    }

    func remember(_ sessions: [AgentSession]) {
        for session in sessions {
            remember(session)
        }
    }

    func remember(_ runtimeProvider: String?, for sessionID: SessionID) {
        let runtime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        lock.lock()
        runtimeBySessionID[sessionID] = runtime.isEmpty ? "codex" : runtime
        lock.unlock()
    }

    func runtimeProvider(for sessionID: SessionID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return runtimeBySessionID[sessionID]
    }

    func remove(sessionID: SessionID) {
        lock.lock()
        runtimeBySessionID.removeValue(forKey: sessionID)
        lock.unlock()
    }
}

final class AppServerRuntimeBundle {
    let codex: CodexAppServerSessionRuntime
    let claude: CodexAppServerSessionRuntime
    let routes = AppServerRuntimeRouteStore()

    init(endpoint: String, token: String) {
        codex = CodexAppServerSessionRuntime(endpoint: endpoint, token: token, runtimeProvider: "codex")
        claude = CodexAppServerSessionRuntime(endpoint: endpoint, token: token, runtimeProvider: "claude")
    }

    /// 快速切换已经拿到 config，候选 Runtime 必须复用它，不能在提交后再次请求
    /// `/api/app-server/config`。Codex 连接在 prepare 阶段初始化；Claude 按实际使用延迟建连。
    init(
        endpoint: String,
        token: String,
        requestTimeout: TimeInterval,
        preparedConfig: CodexAppServerConfigResponse
    ) {
        let configProvider = { preparedConfig }
        codex = CodexAppServerSessionRuntime(
            endpoint: endpoint,
            token: token,
            runtimeProvider: "codex",
            requestTimeout: requestTimeout,
            configProvider: configProvider
        )
        claude = CodexAppServerSessionRuntime(
            endpoint: endpoint,
            token: token,
            runtimeProvider: "claude",
            requestTimeout: requestTimeout,
            configProvider: configProvider
        )
    }

    init(codexRuntime: CodexAppServerSessionRuntime, claudeRuntime: CodexAppServerSessionRuntime) {
        codex = codexRuntime
        claude = claudeRuntime
    }

    func runtime(for provider: String?) -> CodexAppServerSessionRuntime {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(provider) == "claude" ? claude : codex
    }

    func runtime(forSessionID sessionID: SessionID) -> CodexAppServerSessionRuntime {
        runtime(for: routes.runtimeProvider(for: sessionID))
    }

    func prepareForHostActivation() async throws {
        try await codex.prepareForHostActivation()
    }

    func shutdownForHostSwitch() async {
        await codex.shutdownForHostSwitch()
        await claude.shutdownForHostSwitch()
    }
}

/// Codex 与 Claude 共用一个路由 facade，但列表请求始终显式落到单一 Runtime。
/// 不在客户端合并两条 opaque cursor 流，避免重新引入跨 Runtime 排序状态机。
final class CodexAppServerRuntimeRoutingSessionAPIClient: SessionStoreAPIClient {
    private let bundle: AppServerRuntimeBundle
    private let codexClient: CodexAppServerSessionAPIClient

    init(bundle: AppServerRuntimeBundle) {
        self.bundle = bundle
        self.codexClient = CodexAppServerSessionAPIClient(runtime: bundle.codex)
    }

    convenience init(codexRuntime: CodexAppServerSessionRuntime, claudeRuntime: CodexAppServerSessionRuntime) {
        self.init(bundle: AppServerRuntimeBundle(codexRuntime: codexRuntime, claudeRuntime: claudeRuntime))
    }

    func projects() async throws -> [AgentProject] { try await codexClient.projects() }
    func externalActivities() async throws -> ExternalActivityResponse? { try await codexClient.externalActivities() }
    func capabilities(path: String?, forceReload: Bool) async throws -> CapabilityListResponse {
        try await codexClient.capabilities(path: path, forceReload: forceReload)
    }
    func resolveWorkspace(path: String) async throws -> AgentWorkspace { try await codexClient.resolveWorkspace(path: path) }
    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse { try await codexClient.createWorktree(path: path, name: name, base: base, branch: branch) }
    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse { try await codexClient.worktreeBranches(path: path) }
    func listWorktrees() async throws -> [WorktreeListItem] { try await codexClient.listWorktrees() }
    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse { try await codexClient.deleteWorktree(path: path, force: force) }
    func pruneMissingWorktrees() async throws -> WorktreePruneResponse { try await codexClient.pruneMissingWorktrees() }
    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse { try await codexClient.previewWorktreeCleanup() }
    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse { try await codexClient.executeWorktreeCleanup(paths: paths, planID: planID) }
    func listDirectories(path: String) async throws -> DirectoryListResponse { try await codexClient.listDirectories(path: path) }
    func readFile(path: String) async throws -> FileReadResponse { try await codexClient.readFile(path: path) }
    func readHistoryMedia(id: String) async throws -> FileReadResponse { try await codexClient.readHistoryMedia(id: id) }
    func readHistoryOutput(id: String) async throws -> FileReadResponse { try await codexClient.readHistoryOutput(id: id) }
    func commandActions(path: String) async throws -> [AgentCommandAction] { try await codexClient.commandActions(path: path) }
    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse { try await codexClient.runCommandAction(path: path, id: id, confirmed: confirmed) }
    func gitStatus(path: String) async throws -> GitStatusResponse { try await codexClient.gitStatus(path: path) }
    func gitStatusSummary(path: String) async throws -> GitStatusResponse { try await codexClient.gitStatusSummary(path: path) }
    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse { try await codexClient.gitAction(path: path, action: action, files: files) }
    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse { try await codexClient.gitPatchAction(path: path, action: action, patch: patch) }
    func gitCommit(path: String, message: String) async throws -> GitStatusResponse { try await codexClient.gitCommit(path: path, message: message) }
    func gitPush(path: String, remote: String?) async throws -> GitPushResponse { try await codexClient.gitPush(path: path, remote: remote) }
    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse { try await codexClient.gitQuickPublish(path: path, message: message, remote: remote, confirmed: confirmed) }
    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse { try await codexClient.gitTestFlightStatus(path: path) }
    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse { try await codexClient.gitTestFlightRun(path: path, whatToTest: whatToTest, confirmed: confirmed) }
    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse { try await codexClient.gitCreatePullRequest(path: path, title: title, body: body, draft: draft) }
    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse { try await codexClient.gitPullRequestStatus(path: path) }
    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?) async throws -> VoiceTranscriptionResponse {
        try await codexClient.transcribeVoice(filename: filename, contentType: contentType, audioData: audioData, language: language)
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        var options = try await bundle.codex.modelOptions()
        if try await bundle.codex.channelAvailable(runtimeProvider: "claude") {
            do {
                options.append(contentsOf: try await bundle.claude.modelOptions())
            } catch {
                // Claude 是 experimental runtime；模型列表失败不能拖垮 Codex 主路径。
                // config/channel metadata 会继续暴露 bridge 状态，菜单这里优先保持可用。
                print("Claude model/list unavailable: \(error.localizedDescription)")
            }
        }
        var seen: Set<String> = []
        return options.filter { option in
            guard !seen.contains(option.id) else { return false }
            seen.insert(option.id)
            return true
        }
    }

    func runtimeChannelAvailable(runtimeProvider: String) async throws -> Bool {
        try await bundle.codex.channelAvailable(runtimeProvider: runtimeProvider)
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await sessionsPage(projectID: projectID, cursor: cursor, limit: limit).sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await sessionsPage(
            projectID: projectID,
            runtimeProvider: "codex",
            cursor: cursor,
            limit: limit,
            consistency: .fastIndexed
        )
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage {
        try await sessionsPage(
            projectID: projectID,
            runtimeProvider: "codex",
            cursor: cursor,
            limit: limit,
            consistency: consistency
        )
    }

    func sessionsPage(
        projectID: String?,
        runtimeProvider: String,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        let page = try await bundle.runtime(for: runtimeProvider).sessionsPage(
            projectID: projectID,
            cursor: cursor,
            limit: limit,
            consistency: consistency
        )
        bundle.routes.remember(page.sessions)
        return page
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await sessionsPage(
            workspace: workspace,
            runtimeProvider: "codex",
            cursor: cursor,
            limit: limit,
            consistency: .fastIndexed
        )
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage {
        try await sessionsPage(
            workspace: workspace,
            runtimeProvider: "codex",
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
        let page = try await bundle.runtime(for: runtimeProvider).sessionsPage(
            workspace: workspace,
            cursor: cursor,
            limit: limit,
            consistency: consistency
        )
        bundle.routes.remember(page.sessions)
        return page
    }

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage {
        // 受控全局发现是 Codex App Server 能力；Claude bridge 没有同构的无 cwd 合同。
        let page = try await codexClient.controlledGlobalSessionsPage(cursor: cursor, limit: limit)
        bundle.routes.remember(page.sessions)
        return page
    }

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        // Codex 的 thread/search 是独立能力；Claude channel 目前没有同构接口，避免为搜索额外发双路请求。
        let page = try await codexClient.searchSessions(query: query, cursor: cursor, limit: limit)
        bundle.routes.remember(page.sessions)
        return page
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        let response = try await bundle.runtime(forSessionID: id).session(id: id, afterSeq: afterSeq)
        bundle.routes.remember(response.session)
        return response
    }

    func refreshRateLimit(sessionID: String?) async throws -> RateLimitSummary? {
        if let sessionID {
            return await bundle.runtime(forSessionID: sessionID).refreshRateLimit()
        }
        return await bundle.codex.refreshRateLimit()
    }

    func refreshRateLimit(runtimeProvider: String) async throws -> RateLimitSummary? {
        await bundle.runtime(for: runtimeProvider).refreshRateLimit()
    }

    func refreshAccountTokenUsage() async throws -> AccountTokenUsageFetch {
        // Token 活动来自 ChatGPT 账号，只允许走 Codex channel。
        await bundle.codex.refreshAccountTokenUsage()
    }

    func refreshAccountTokenUsage(forceRefresh: Bool) async throws -> AccountTokenUsageFetch {
        // Token 活动来自 ChatGPT 账号，只允许走 Codex channel。
        await bundle.codex.refreshAccountTokenUsage(forceRefresh: forceRefresh)
    }

    func threadGoal(threadID: String) async throws -> ThreadGoal? {
        try await bundle.runtime(forSessionID: threadID).threadGoal(threadID: threadID)
    }

    func setThreadGoal(threadID: String, objective: String?, status: ThreadGoalStatus?, tokenBudget: Int64?) async throws -> ThreadGoal {
        try await bundle.runtime(forSessionID: threadID).setThreadGoal(threadID: threadID, objective: objective, status: status, tokenBudget: tokenBudget)
    }

    func clearThreadGoal(threadID: String) async throws {
        try await bundle.runtime(forSessionID: threadID).clearThreadGoal(threadID: threadID)
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        let runtime = bundle.runtime(for: payload.turnOptions.runtimeProvider)
        let response = try await runtime.createSession(payload)
        bundle.routes.remember(response.session)
        return response
    }

    func forkSession(
        threadID: String,
        workspace: AgentWorkspace,
        reason: AgentSessionForkReason
    ) async throws -> AgentSession {
        let session = try await bundle.runtime(forSessionID: threadID).forkSession(
            threadID: threadID,
            workspace: workspace,
            reason: reason
        )
        bundle.routes.remember(session)
        return session
    }

    func stopSession(id: String) async throws {
        try await bundle.runtime(forSessionID: id).stopSession(id: id)
    }

    func setSessionArchived(id: String, archived: Bool) async throws {
        try await bundle.runtime(forSessionID: id).setSessionArchived(id: id, archived: archived)
        if archived {
            bundle.routes.remove(sessionID: id)
        }
    }

    func setThreadName(threadID: String, name: String) async throws {
        try await bundle.runtime(forSessionID: threadID).setThreadName(threadID: threadID, name: name)
    }

    func compactThread(threadID: String) async throws {
        try await bundle.runtime(forSessionID: threadID).compactThread(threadID: threadID)
    }

    func unsubscribeThread(threadID: String) async throws -> CodexAppServerThreadUnsubscribeStatus? {
        try await bundle.runtime(forSessionID: threadID).unsubscribeThread(threadID: threadID)
    }

    func releaseThreadWriterWhenIdle(threadID: String) async throws -> ThreadHandoffResponse {
        try await bundle.runtime(forSessionID: threadID)
            .releaseThreadWriterWhenIdle(threadID: threadID)
    }

    func startReview(
        threadID: String,
        target: CodexAppServerReviewTarget,
        delivery: CodexAppServerReviewDelivery? = nil
    ) async throws -> CodexAppServerReviewStartResult {
        try await bundle.runtime(forSessionID: threadID).startReview(
            threadID: threadID,
            target: target,
            delivery: delivery
        )
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit).messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        try await bundle.runtime(forSessionID: sessionID).messagesPage(sessionID: sessionID, before: before, limit: limit)
    }

    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage {
        try await bundle.runtime(forSessionID: sessionID).messagesPage(
            sessionID: sessionID,
            before: before,
            limit: limit,
            loadMode: loadMode
        )
    }

}

final class MultiRuntimeSessionWebSocketClient: SessionWebSocketClient {
    var onEvent: (@MainActor (AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendAccepted: ((ClientMessageID?) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?
    var onTurnSendOutcome: ((ClientMessageID?, TurnSendOutcome) -> Void)?
    var onApprovalDecisionFailure: ((String, String) -> Void)?
    var onUserInputResponseFailure: ((String, String) -> Void)?
    var onControlFailure: ((String) -> Void)?

    private let bundle: AppServerRuntimeBundle
    private var activeClient: CodexAppServerSessionWebSocketClient?

    init(bundle: AppServerRuntimeBundle) {
        self.bundle = bundle
    }

    func connect(sessionID: SessionID) {
        connect(sessionID: sessionID, replayBufferedEvents: true)
    }

    func connect(sessionID: SessionID, replayBufferedEvents: Bool) {
        let runtime = bundle.runtime(forSessionID: sessionID)
        // “单活”边界是当前 Mac，而不是 Runtime provider。同一台 Mac 上当前会话与后台
        // 排队会话可能分别属于 Codex/Claude；两者各复用一条共享连接，不能互相退役。
        // 切换 Mac、进入后台或凭据失效时仍由 AppServerRuntimeBundle 整体关闭。
        let client = CodexAppServerSessionWebSocketClient(runtime: runtime)
        activeClient?.disconnect()
        activeClient = client
        wireHandlers(to: client)
        client.connect(sessionID: sessionID, replayBufferedEvents: replayBufferedEvents)
    }

    func disconnect() {
        activeClient?.disconnect()
        activeClient = nil
    }

    @discardableResult
    func sendInput(_ text: String, clientMessageID: ClientMessageID?) -> Bool {
        activeClient?.sendInput(text, clientMessageID: clientMessageID) ?? false
    }

    @discardableResult
    func sendTurn(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) -> Bool {
        activeClient?.sendTurn(payload, clientMessageID: clientMessageID) ?? false
    }

    @discardableResult
    func sendGuidance(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?, expectedTurnID: TurnID) -> Bool {
        activeClient?.sendGuidance(payload, clientMessageID: clientMessageID, expectedTurnID: expectedTurnID) ?? false
    }

    @discardableResult
    func sendCtrlC(expectedTurnID: TurnID) -> Bool {
        activeClient?.sendCtrlC(expectedTurnID: expectedTurnID) ?? false
    }

    @discardableResult
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        activeClient?.sendApprovalDecision(approvalID: approvalID, decision: decision, message: message) ?? false
    }

    @discardableResult
    func sendUserInputResponse(requestID: String, answers: [String: [String]]) -> Bool {
        activeClient?.sendUserInputResponse(requestID: requestID, answers: answers) ?? false
    }

    func acknowledgeAppliedEvent(_ event: AgentEvent) {
        activeClient?.acknowledgeAppliedEvent(event)
    }

    private func wireHandlers(to client: CodexAppServerSessionWebSocketClient) {
        client.onStatus = { [weak self] status in
            self?.onStatus?(status)
        }
        client.onEvent = { [weak self] event in
            self?.rememberRoute(from: event)
            self?.onEvent?(event)
        }
        client.onSendAccepted = { [weak self] clientMessageID in
            self?.onSendAccepted?(clientMessageID)
        }
        client.onSendFailure = { [weak self] clientMessageID, message in
            self?.onSendFailure?(clientMessageID, message)
        }
        client.onTurnSendOutcome = { [weak self] clientMessageID, outcome in
            self?.onTurnSendOutcome?(clientMessageID, outcome)
        }
        client.onApprovalDecisionFailure = { [weak self] approvalID, message in
            self?.onApprovalDecisionFailure?(approvalID, message)
        }
        client.onUserInputResponseFailure = { [weak self] requestID, message in
            self?.onUserInputResponseFailure?(requestID, message)
        }
        client.onControlFailure = { [weak self] message in
            self?.onControlFailure?(message)
        }
    }

    private func rememberRoute(from event: AgentEvent) {
        switch event {
        case .session(let session):
            bundle.routes.remember(session)
        case .sessionRow(let row, _):
            bundle.routes.remember(row.runtimeProvider ?? row.source, for: row.id)
        default:
            break
        }
    }
}

final class CodexAppServerSessionWebSocketClient: SessionWebSocketClient {
    var onEvent: (@MainActor (AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendAccepted: ((ClientMessageID?) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?
    var onTurnSendOutcome: ((ClientMessageID?, TurnSendOutcome) -> Void)?
    var onApprovalDecisionFailure: ((String, String) -> Void)?
    var onUserInputResponseFailure: ((String, String) -> Void)?
    var onControlFailure: ((String) -> Void)?

    private let runtime: CodexAppServerSessionRuntime
    private var sessionID: SessionID?
    private var eventPumpTask: Task<Void, Never>?

    init(runtime: CodexAppServerSessionRuntime) {
        self.runtime = runtime
    }

    func connect(sessionID threadID: SessionID) {
        connect(sessionID: threadID, replayBufferedEvents: true)
    }

    func connect(sessionID threadID: SessionID, replayBufferedEvents: Bool) {
        sessionID = threadID
        onStatus?(.connecting)
        eventPumpTask?.cancel()
        let statusHandler = onStatus
        let eventHandler = onEvent
        let replayPolicy: CodexAppServerBufferedEventReplayPolicy = replayBufferedEvents ? .all : .stateOnly
        eventPumpTask = Task { [runtime] in
            let events = await runtime.attachEvents(sessionID: threadID, replayPolicy: replayPolicy)
            defer {
                // Task 可能在等待 MainActor 时被取消；显式释放订阅，避免 runtime 长期保留邮箱。
                events.cancel()
            }
            do {
                try await runtime.connectForEvents(sessionID: threadID)
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    statusHandler?(.connected)
                }
                for await event in events {
                    guard !Task.isCancelled else {
                        return
                    }
                    await MainActor.run {
                        eventHandler?(event)
                    }
                }
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    statusHandler?(.disconnected)
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    if isCredentialInvalidatingError(error) {
                        statusHandler?(.terminated(.credentialsInvalid))
                    } else {
                        statusHandler?(.failed(error.localizedDescription))
                    }
                }
            }
        }
    }

    func disconnect() {
        eventPumpTask?.cancel()
        eventPumpTask = nil
        onStatus?(.disconnected)
    }

    @discardableResult
    func sendInput(_ text: String, clientMessageID: ClientMessageID?) -> Bool {
        var prompt = text
        if prompt.hasSuffix("\r") {
            prompt.removeLast()
        }
        return sendTurn(CodexAppServerTurnPayload(prompt: prompt), clientMessageID: clientMessageID)
    }

    @discardableResult
    func sendTurn(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) -> Bool {
        guard let sessionID else {
            onSendFailure?(clientMessageID, L10n.text("ui.direct_websocket_not_connected"))
            return false
        }
        guard !payload.isEmpty else {
            return true
        }
        let acceptedHandler = onSendAccepted
        let failureHandler = onSendFailure
        let outcomeHandler = onTurnSendOutcome
        Task { [runtime] in
            do {
                let startOutcome = try await runtime.startTurnOutcome(
                    sessionID: sessionID,
                    payload: payload,
                    clientMessageID: clientMessageID
                )
                await MainActor.run {
                    if let outcomeHandler {
                        outcomeHandler(clientMessageID, Self.turnSendOutcome(for: startOutcome))
                    } else {
                        acceptedHandler?(clientMessageID)
                    }
                }
            } catch {
                await MainActor.run {
                    if let outcomeHandler {
                        outcomeHandler(clientMessageID, Self.turnSendOutcome(for: error))
                    } else {
                        failureHandler?(clientMessageID, error.localizedDescription)
                    }
                }
            }
        }
        return true
    }

    func acknowledgeAppliedEvent(_ event: AgentEvent) {
        guard let metadata = Self.metadata(for: event),
              let sequence = metadata.replayBoundarySequence else {
            return
        }
        Task { [runtime] in
            await runtime.acknowledgeAppliedReplayBoundary(
                sequence,
                epoch: metadata.replayCursorEpoch
            )
        }
    }

    static func turnSendOutcome(
        for startOutcome: CodexAppServerTurnStartOutcome
    ) -> TurnSendOutcome {
        switch startOutcome {
        case .active(let turnID):
            return .accepted(turnID: turnID)
        case .terminal(let turnID):
            return .acceptedTerminal(turnID: turnID)
        case .superseded(let turnID, let activeTurnID):
            return .acceptedSuperseded(
                turnID: turnID,
                activeTurnID: activeTurnID
            )
        case .threadClosed(let turnID):
            return .acceptedThreadClosed(turnID: turnID)
        }
    }

    static func turnSendOutcome(for error: Error) -> TurnSendOutcome {
        if case CodexAppServerSessionRuntimeError.activeTurnConflict(_, let activeTurnID) = error {
            return .activeTurnConflict(
                activeTurnID: activeTurnID,
                message: error.localizedDescription
            )
        }
        if case CodexAppServerConnectionError.appServer(let appError) = error {
            if let activeTurnID = CodexAppServerSessionRuntime.activeTurnIDFromConflict(error) {
                return .activeTurnConflict(
                    activeTurnID: activeTurnID,
                    message: error.localizedDescription
                )
            }
            let wasExplicitlyRejected = appError.data?.objectValue?["accepted"]?.boolValue == false
            // -32602 表示请求参数在执行前即被拒绝；-32603 等内部错误可能发生在
            // bridge 已接受并启动 turn 之后，不能允许自动重试制造重复消息。
            if wasExplicitlyRejected || appError.code == -32602 {
                return .rejected(message: error.localizedDescription)
            }
            return .uncertain(message: error.localizedDescription)
        }
        if error is CodexAppServerRequestBuilderError
            || error is CodexAppServerSessionRuntimeError
            || error is AgentAPIError {
            return .rejected(message: error.localizedDescription)
        }
        return .uncertain(message: error.localizedDescription)
    }

    private static func metadata(for event: AgentEvent) -> AgentEventMetadata? {
        switch event {
        case .session, .unknown:
            return nil
        case .sessionRow(_, let metadata),
             .sessionStatus(_, let metadata),
             .sessionContext(_, let metadata),
             .goalUpdated(_, let metadata),
             .goalCleared(let metadata),
             .turnStarted(let metadata),
             .assistantDelta(_, let metadata),
             .messageCompleted(_, let metadata),
             .processItemCompleted(_, _, let metadata),
             .logDelta(_, let metadata),
             .diffUpdated(_, let metadata),
             .approvalRequest(_, let metadata),
             .approvalResolved(let metadata),
             .userInputRequest(_, let metadata),
             .userInputResolved(let metadata, _),
             .turnCompleted(let metadata),
             .warning(_, let metadata),
             .error(_, let metadata):
            return metadata
        }
    }

    @discardableResult
    func sendGuidance(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?, expectedTurnID: TurnID) -> Bool {
        guard let sessionID else {
            onSendFailure?(clientMessageID, L10n.text("ui.direct_websocket_not_connected"))
            return false
        }
        guard !payload.isEmpty else {
            return true
        }
        let acceptedHandler = onSendAccepted
        let failureHandler = onSendFailure
        let outcomeHandler = onTurnSendOutcome
        Task { [runtime, sessionID] in
            do {
                try await runtime.steerTurn(
                    sessionID: sessionID,
                    payload: payload,
                    clientMessageID: clientMessageID,
                    expectedTurnID: expectedTurnID
                )
                await MainActor.run {
                    if let outcomeHandler {
                        // steer 成功仍属于当前 turn，必须和降级后的 turn/start 明确区分。
                        outcomeHandler(clientMessageID, .guidanceAccepted)
                    } else {
                        acceptedHandler?(clientMessageID)
                    }
                }
            } catch {
                if case CodexAppServerSessionRuntimeError.missingActiveTurn = error {
                    // missingActiveTurn 来自 steerTurn 的 RPC 前本地校验，确定没有发送。
                    // 仅此情形安全降级成普通 turn/start；任何上游/网络错误都禁止自动重试。
                    do {
                        let turnID = try await runtime.startTurn(
                            sessionID: sessionID,
                            payload: payload,
                            clientMessageID: clientMessageID
                        )
                        await MainActor.run {
                            if let outcomeHandler {
                                outcomeHandler(clientMessageID, .accepted(turnID: turnID))
                            } else {
                                acceptedHandler?(clientMessageID)
                            }
                        }
                    } catch {
                        await MainActor.run {
                            if let outcomeHandler {
                                outcomeHandler(clientMessageID, Self.turnSendOutcome(for: error))
                            } else {
                                failureHandler?(clientMessageID, error.localizedDescription)
                            }
                        }
                    }
                    return
                }
                await MainActor.run {
                    if let outcomeHandler {
                        outcomeHandler(clientMessageID, Self.turnSendOutcome(for: error))
                    } else {
                        failureHandler?(clientMessageID, error.localizedDescription)
                    }
                }
            }
        }
        return true
    }

    @discardableResult
    func sendCtrlC(expectedTurnID: TurnID) -> Bool {
        guard let sessionID else {
            onControlFailure?(L10n.text("ui.direct_websocket_not_connected"))
            return false
        }
        let failureHandler = onControlFailure
        Task { [runtime] in
            do {
                try await runtime.interruptActiveTurn(
                    sessionID: sessionID,
                    expectedTurnID: expectedTurnID
                )
            } catch {
                await MainActor.run {
                    failureHandler?(error.localizedDescription)
                }
            }
        }
        return true
    }

    @discardableResult
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        guard let sessionID else {
            onApprovalDecisionFailure?(approvalID, L10n.text("ui.direct_websocket_not_connected"))
            return false
        }
        let failureHandler = onApprovalDecisionFailure
        Task { [runtime, sessionID] in
            do {
                try await runtime.respondToApproval(sessionID: sessionID, approvalID: approvalID, decision: decision)
            } catch {
                await MainActor.run {
                    failureHandler?(approvalID, error.localizedDescription)
                }
            }
        }
        return true
    }

    @discardableResult
    func sendUserInputResponse(requestID: String, answers: [String: [String]]) -> Bool {
        guard let sessionID else {
            onUserInputResponseFailure?(requestID, L10n.text("ui.direct_websocket_not_connected"))
            return false
        }
        let failureHandler = onUserInputResponseFailure
        Task { [runtime, sessionID] in
            do {
                try await runtime.respondToUserInput(sessionID: sessionID, requestID: requestID, answers: answers)
            } catch {
                await MainActor.run {
                    failureHandler?(requestID, error.localizedDescription)
                }
            }
        }
        return true
    }
}
