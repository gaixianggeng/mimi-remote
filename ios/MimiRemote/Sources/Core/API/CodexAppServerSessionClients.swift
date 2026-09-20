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

    func permissionProfiles(cwd: String) async throws -> [CodexAppServerPermissionProfileSummary] {
        try await runtime.permissionProfiles(cwd: cwd)
    }

    func runtimeChannelAvailable(runtimeProvider: String) async throws -> Bool {
        try await runtime.channelAvailable(runtimeProvider: runtimeProvider)
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

    func updateThreadPermissions(threadID: String, options: CodexAppServerTurnOptions) async throws {
        try await runtime.updateThreadPermissions(threadID: threadID, options: options)
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

    func takeOverThread(threadID: String) async throws -> CodexAppServerThreadTakeoverResult {
        try await runtime.takeOverThread(sessionID: threadID)
    }

    func sessionSupportsThreadTakeover(sessionID: String) async throws -> Bool {
        try await runtime.supportsThreadTakeover()
    }

    func unsubscribeThread(threadID: String) async throws -> CodexAppServerThreadUnsubscribeStatus? {
        try await runtime.unsubscribeThread(threadID: threadID)
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
        reason: AgentSessionForkReason,
        lastTurnID: TurnID? = nil
    ) async throws -> AgentSession {
        try await runtime.forkSession(
            threadID: threadID,
            workspace: workspace,
            reason: reason,
            lastTurnID: lastTurnID
        )
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

    func historyTurnItemsPage(
        sessionID: String,
        continuation: HistoryTurnItemsContinuation
    ) async throws -> HistoryTurnItemsPage {
        try await runtime.historyTurnItemsPage(sessionID: sessionID, continuation: continuation)
    }

    func latestTurnHistoryPage(sessionID: String) async throws -> HistoryMessagesPage? {
        try await runtime.latestTurnHistoryPage(sessionID: sessionID)
    }
}

final class AppServerRuntimeRouteStore {
    private var lock = NSLock()
    private var runtimeBySessionID: [SessionID: String] = [:]

    func remember(_ session: AgentSession) {
        remember(runtimeProvider: session.runtimeProvider, source: session.source, for: session.id)
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

    func remember(runtimeProvider: String?, source: String?, for sessionID: SessionID) {
        if let explicit = runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            // 显式 provider 即使未知也要保留，让后续请求安全失败，不能误投到 Codex。
            remember(explicit, for: sessionID)
            return
        }
        let sourceRuntime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(source)
        let knownRuntimes: Set<String> = ["codex", "claude", "deepseek"]
        remember(knownRuntimes.contains(sourceRuntime) ? sourceRuntime : "codex", for: sessionID)
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
    /// 原生通道承接的 runtime ID。沿用既有 `deepseek`，不新建 `deepseek-native`，
    /// 以免切断既有路由、收藏与通知身份。
    static let nativeRuntimeProvider = "deepseek"

    let codex: CodexAppServerSessionRuntime
    let claude: CodexAppServerSessionRuntime
    /// 仅在**未**注入原生客户端时构造。注入后 `deepseek` 不再经过 Codex actor，
    /// 从根上避免「拿 Codex actor 假装 native」。
    let deepseek: CodexAppServerSessionRuntime?
    /// 原生 Harness 接缝。默认 `nil`：开发期沿用既有 app-server 路径，行为不变。
    let harness: HarnessSessionClient?
    let routes = AppServerRuntimeRouteStore()

    init(endpoint: String, token: String, harnessFactory: HarnessSessionClientFactory? = nil) {
        codex = CodexAppServerSessionRuntime(endpoint: endpoint, token: token, runtimeProvider: "codex")
        claude = CodexAppServerSessionRuntime(endpoint: endpoint, token: token, runtimeProvider: "claude")
        let native = harnessFactory?(endpoint, token)
        harness = native
        deepseek = native == nil
            ? CodexAppServerSessionRuntime(endpoint: endpoint, token: token, runtimeProvider: "deepseek")
            : nil
    }

    /// 快速切换已经拿到 config，候选 Runtime 必须复用它，不能在提交后再次请求
    /// `/api/app-server/config`。Codex 连接在 prepare 阶段初始化；Claude 按实际使用延迟建连。
    init(
        endpoint: String,
        token: String,
        requestTimeout: TimeInterval,
        preparedConfig: CodexAppServerConfigResponse,
        harnessFactory: HarnessSessionClientFactory? = nil
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
        let native = harnessFactory?(endpoint, token)
        harness = native
        deepseek = native == nil
            ? CodexAppServerSessionRuntime(
                endpoint: endpoint,
                token: token,
                runtimeProvider: "deepseek",
                requestTimeout: requestTimeout,
                configProvider: configProvider
            )
            : nil
    }

    init(
        codexRuntime: CodexAppServerSessionRuntime,
        claudeRuntime: CodexAppServerSessionRuntime,
        deepseekRuntime: CodexAppServerSessionRuntime? = nil,
        harness: HarnessSessionClient? = nil
    ) {
        codex = codexRuntime
        claude = claudeRuntime
        self.harness = harness
        // 两者同时给出时以原生为准：Codex actor 不得与原生通道并存来「兜底」。
        self.deepseek = harness == nil ? deepseekRuntime : nil
    }

    /// 该 provider 是否由原生客户端承接；不是则返回 `nil`。
    func nativeClient(for provider: String?) -> HarnessSessionClient? {
        guard let harness else { return nil }
        let normalized = CodexAppServerSessionRuntime.normalizedRuntimeProvider(provider)
        return normalized == Self.nativeRuntimeProvider ? harness : nil
    }

    func nativeClient(forSessionID sessionID: SessionID) -> HarnessSessionClient? {
        nativeClient(for: routes.runtimeProvider(for: sessionID))
    }

    func runtime(for provider: String?) throws -> CodexAppServerSessionRuntime {
        let normalized = CodexAppServerSessionRuntime.normalizedRuntimeProvider(provider)
        if harness != nil, normalized == Self.nativeRuntimeProvider {
            // 原生通道激活时不得回退到 Codex actor 假装 native。调用方必须改走
            // nativeClient(for:)；这里显式失败，让误用立刻暴露而不是静默走错协议。
            throw HarnessNativeUnavailableError.routedNatively(runtimeProvider: normalized)
        }
        switch normalized {
        case "codex":
            return codex
        case "claude":
            return claude
        case "deepseek":
            guard let deepseek else {
                throw CodexAppServerSessionRuntimeError.gatewayUnavailable
            }
            return deepseek
        default:
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
    }

    func runtime(forSessionID sessionID: SessionID) throws -> CodexAppServerSessionRuntime {
        try runtime(for: routes.runtimeProvider(for: sessionID))
    }

    func prepareForHostActivation() async throws {
        try await codex.prepareForHostActivation()
    }

    func shutdownForHostSwitch() async {
        await harness?.shutdownForHostSwitch()
        await codex.shutdownForHostSwitch()
        await claude.shutdownForHostSwitch()
        await deepseek?.shutdownForHostSwitch()
    }
}

/// 各 Runtime 共用一个路由 facade，但列表请求始终显式落到单一 Runtime。
/// 不在客户端合并多条 opaque cursor 流，避免重新引入跨 Runtime 排序状态机。
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
        var options: [CodexAppServerModelOption] = []
        var codexError: Error?
        do {
            options = try await bundle.codex.modelOptions()
        } catch {
            codexError = error
        }
        let secondaryRuntimes: [(provider: String, runtime: CodexAppServerSessionRuntime?)] = [
            ("claude", bundle.claude),
            ("deepseek", bundle.deepseek)
        ]
        var secondarySucceeded = false
        for secondary in secondaryRuntimes {
            do {
                let secondaryOptions: [CodexAppServerModelOption]
                if let native = bundle.nativeClient(for: secondary.provider) {
                    // 原生通道：Codex 上游不可用时依然能独立进入准备流程并给出模型目录。
                    guard try await native.channelAvailable() else { continue }
                    secondaryOptions = try await native.modelOptions()
                } else {
                    guard let runtime = secondary.runtime else { continue }
                    guard (try? await runtime.channelAvailable(runtimeProvider: secondary.provider)) == true else {
                        continue
                    }
                    secondaryOptions = try await runtime.modelOptions()
                }
                options.append(contentsOf: secondaryOptions)
                secondarySucceeded = true
            } catch {
                // 次要 Runtime 的模型列表失败不能拖垮 Codex 主路径。
                // config/channel metadata 会继续暴露 bridge 状态，菜单这里优先保持可用。
                print("\(secondary.provider) model/list unavailable: \(error.localizedDescription)")
            }
        }
        if !secondarySucceeded, options.isEmpty, let codexError {
            throw codexError
        }
        var seen: Set<String> = []
        return options.filter { option in
            let runtime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(option.runtimeProvider)
            let key = [runtime, option.provider ?? "", option.model].joined(separator: "\u{1F}")
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    func permissionProfiles(cwd: String) async throws -> [CodexAppServerPermissionProfileSummary] {
        try await bundle.codex.permissionProfiles(cwd: cwd)
    }

    func runtimeChannelAvailable(runtimeProvider: String) async throws -> Bool {
        if let native = bundle.nativeClient(for: runtimeProvider) {
            return try await native.channelAvailable()
        }
        return try await bundle.codex.channelAvailable(runtimeProvider: runtimeProvider)
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
        // 原生通道承接的 runtime 直接走原生客户端，不经 Codex wire。
        if let native = bundle.nativeClient(for: runtimeProvider) {
            let page = try await native.sessionsPage(
                projectID: projectID,
                cursor: cursor,
                limit: limit,
                consistency: consistency
            )
            bundle.routes.remember(page.sessions)
            return page
        }
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
        if let native = bundle.nativeClient(for: runtimeProvider) {
            let page = try await native.sessionsPage(
                workspace: workspace,
                cursor: cursor,
                limit: limit,
                consistency: consistency
            )
            bundle.routes.remember(page.sessions)
            return page
        }
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
        try await controlledGlobalSessionsPage(runtimeProvider: "codex", cursor: cursor, limit: limit)
    }

    /// 受控全局发现按 runtime 分头遍历：两条 opaque cursor 流各自独立推进，
    /// 从不交织成一条，调用方把两趟结果并进同一份 canonical sessions。
    /// 这样既让 Claude 会话在「会话」tab 可见，也不引入跨 Runtime 排序状态机。
    func controlledGlobalSessionsPage(
        runtimeProvider: String,
        cursor: String?,
        limit: Int?
    ) async throws -> SessionsPage {
        if let native = bundle.nativeClient(for: runtimeProvider) {
            let page = try await native.controlledGlobalSessionsPage(cursor: cursor, limit: limit)
            bundle.routes.remember(page.sessions)
            return page
        }
        let page = try await bundle.runtime(for: runtimeProvider)
            .controlledGlobalSessionsPage(cursor: cursor, limit: limit)
        bundle.routes.remember(page.sessions)
        return page
    }

    /// 搜索的分页由 Codex 的 thread/search 独占驱动：只有首页会额外查询其他 Runtime，
    /// 并把结果拼在后面。Claude 没有 thread/search，它走 thread/list + searchTerm；
    /// DeepSeek 直接走 thread/search。这样不需要把多条游标流编进一个复合
    /// cursor（那会重新引入跨 Runtime 的分页状态机）。
    ///
    /// 代价说明：次要 Runtime 的搜索结果限于首页 limit 条。搜索场景下用户通常继续收窄
    /// 关键词而不是翻页；真出现「Claude 结果翻不动」再升级为按 runtime 分段。
    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        if cursor != nil {
            let page = try await codexClient.searchSessions(query: query, cursor: cursor, limit: limit)
            bundle.routes.remember(page.sessions)
            return page
        }

        // 首页各 runtime 独立失败；Codex 的搜索故障不能阻断仍可用的 Harness。
        // 游标仍只归 Codex 所有，不把失败通道的游标伪装成另一条分页流。
        var codexPage: ThreadSearchPage?
        var pages: [ThreadSearchPage] = []
        var unavailable: [String] = []
        var firstError: Error?
        do {
            let page = try await codexClient.searchSessions(query: query, cursor: nil, limit: limit)
            codexPage = page
            pages.append(page)
        } catch {
            try Task.checkCancellation()
            firstError = error
            unavailable.append("codex")
        }
        let secondaryRuntimes: [(String, CodexAppServerSessionRuntime?)] = [
            ("claude", bundle.claude), ("deepseek", bundle.deepseek)
        ]
        for (provider, runtime) in secondaryRuntimes {
            try Task.checkCancellation()
            do {
                let page: ThreadSearchPage
                if let native = bundle.nativeClient(for: provider) {
                    // 原生通道与 Codex wire 完全无关：它失败只把自己记成 unavailable。
                    guard try await native.channelAvailable() else { continue }
                    page = try await native.searchSessions(query: query, cursor: nil, limit: limit)
                } else {
                    guard let runtime else { continue }
                    guard try await runtime.channelAvailable(runtimeProvider: provider) else { continue }
                    page = provider == "claude"
                        ? try await runtime.globalThreadListSearchPage(query: query, limit: limit)
                        : try await runtime.searchSessions(query: query, cursor: nil, limit: limit)
                }
                pages.append(page)
            } catch {
                try Task.checkCancellation()
                if firstError == nil { firstError = error }
                unavailable.append(provider)
            }
        }
        if pages.isEmpty, let firstError { throw firstError }
        var merged: [ThreadSearchResult] = []
        var existingIDs: Set<SessionID> = []
        for page in pages {
            bundle.routes.remember(page.sessions)
            merged.append(contentsOf: page.results.filter { existingIDs.insert($0.session.id).inserted })
        }
        return ThreadSearchPage(
            results: merged,
            nextCursor: codexPage?.nextCursor,
            backwardsCursor: codexPage?.backwardsCursor,
            unavailableRuntimeProviders: unavailable
        )
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        if let native = bundle.nativeClient(forSessionID: id) {
            let response = try await native.session(id: id, afterSeq: afterSeq)
            bundle.routes.remember(response.session)
            return response
        }
        let response = try await bundle.runtime(forSessionID: id).session(id: id, afterSeq: afterSeq)
        bundle.routes.remember(response.session)
        return response
    }

    /// 空值不覆盖已有路由；显式未知值保留到路由表并在使用时安全失败，不能误投到 Codex。
    func rememberRuntimeRoute(_ runtimeProvider: String?, forSessionID sessionID: SessionID) {
        guard let raw = runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return
        }
        let normalized = CodexAppServerSessionRuntime.normalizedRuntimeProvider(raw)
        bundle.routes.remember(normalized, for: sessionID)
    }

    func rememberedRuntimeRoute(forSessionID sessionID: SessionID) -> String? {
        bundle.routes.runtimeProvider(for: sessionID)
    }

    func refreshRateLimit(sessionID: String?) async throws -> RateLimitSummary? {
        if let sessionID {
            return try await bundle.runtime(forSessionID: sessionID).refreshRateLimit()
        }
        return await bundle.codex.refreshRateLimit()
    }

    func refreshRateLimit(runtimeProvider: String) async throws -> RateLimitSummary? {
        try await bundle.runtime(for: runtimeProvider).refreshRateLimit()
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

    func updateThreadPermissions(threadID: String, options: CodexAppServerTurnOptions) async throws {
        try await bundle.runtime(forSessionID: threadID).updateThreadPermissions(threadID: threadID, options: options)
    }

    func setThreadGoal(threadID: String, objective: String?, status: ThreadGoalStatus?, tokenBudget: Int64?) async throws -> ThreadGoal {
        try await bundle.runtime(forSessionID: threadID).setThreadGoal(threadID: threadID, objective: objective, status: status, tokenBudget: tokenBudget)
    }

    func clearThreadGoal(threadID: String) async throws {
        try await bundle.runtime(forSessionID: threadID).clearThreadGoal(threadID: threadID)
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        if let native = bundle.nativeClient(for: payload.turnOptions.runtimeProvider) {
            guard let cwd = payload.projectPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cwd.isEmpty else {
                throw HarnessNativeUnavailableError.unsupported(operation: "session/create without cwd")
            }
            let resumedID = payload.resumeID.trimmingCharacters(in: .whitespacesAndNewlines)
            let created: HarnessCreatedSession
            if resumedID.isEmpty {
                created = try await native.createSession(cwd: cwd, sessionID: nil)
            } else {
                // Harness 会话本身可继续使用；历史“继续”不能再创建一个同内容的新会话。
                created = HarnessCreatedSession(sessionID: resumedID, agentPreset: nil)
            }
            if let provider = payload.turnOptions.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
               !provider.isEmpty,
               let model = payload.turnOptions.model?.trimmingCharacters(in: .whitespacesAndNewlines),
               !model.isEmpty {
                try await native.selectModel(
                    sessionID: created.sessionID,
                    provider: provider,
                    model: model,
                    reasoningEffort: payload.turnOptions.reasoningEffort?.rawValue
                )
            }
            let session = AgentSession(
                id: created.sessionID,
                projectID: payload.projectID,
                project: payload.projectName ?? "",
                dir: cwd,
                title: payload.prompt,
                status: "running",
                source: AppServerRuntimeBundle.nativeRuntimeProvider,
                runtimeProvider: AppServerRuntimeBundle.nativeRuntimeProvider,
                resumeID: nil,
                createdAt: nil,
                updatedAt: nil
            )
            bundle.routes.remember(session)
            return CreateSessionResponse(
                session: session,
                wsURL: "",
                requiresQueuedInitialInput: !payload.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        let runtime = try bundle.runtime(for: payload.turnOptions.runtimeProvider)
        let response = try await runtime.createSession(payload)
        bundle.routes.remember(response.session)
        return response
    }

    func forkSession(
        threadID: String,
        workspace: AgentWorkspace,
        reason: AgentSessionForkReason,
        lastTurnID: TurnID? = nil
    ) async throws -> AgentSession {
        let session = try await bundle.runtime(forSessionID: threadID).forkSession(
            threadID: threadID,
            workspace: workspace,
            reason: reason,
            lastTurnID: lastTurnID
        )
        bundle.routes.remember(session)
        return session
    }

    func stopSession(id: String) async throws {
        if let native = bundle.nativeClient(forSessionID: id) {
            try await native.cancelSession(sessionID: id)
            return
        }
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

    func takeOverThread(threadID: String) async throws -> CodexAppServerThreadTakeoverResult {
        try await bundle.runtime(forSessionID: threadID).takeOverThread(sessionID: threadID)
    }

    func sessionSupportsThreadTakeover(sessionID: String) async throws -> Bool {
        try await bundle.runtime(forSessionID: sessionID).supportsThreadTakeover()
    }

    func unsubscribeThread(threadID: String) async throws -> CodexAppServerThreadUnsubscribeStatus? {
        try await bundle.runtime(forSessionID: threadID).unsubscribeThread(threadID: threadID)
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

    func historyTurnItemsPage(
        sessionID: String,
        continuation: HistoryTurnItemsContinuation
    ) async throws -> HistoryTurnItemsPage {
        try await bundle.runtime(forSessionID: sessionID).historyTurnItemsPage(
            sessionID: sessionID,
            continuation: continuation
        )
    }

    func latestTurnHistoryPage(sessionID: String) async throws -> HistoryMessagesPage? {
        try await bundle.runtime(forSessionID: sessionID).latestTurnHistoryPage(sessionID: sessionID)
    }

}

final class MultiRuntimeSessionWebSocketClient: SessionWebSocketClient {
    var onEvent: (@MainActor (AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendAccepted: ((ClientMessageID?) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?
    var onTurnSendOutcome: ((ClientMessageID?, TurnSendOutcome) -> Void)?
    var onApprovalDecisionFailure: ((String, String) -> Void)?
    var onUserInputResponseFailure: ((String, String, Bool) -> Void)?
    var onControlFailure: ((String) -> Void)?

    private let bundle: AppServerRuntimeBundle
    /// 面向既有协议而不是具体 Codex 类型：原生 Harness 事件客户端可以并列接入。
    private var activeClient: (any SessionWebSocketClient)?

    init(bundle: AppServerRuntimeBundle) {
        self.bundle = bundle
    }

    func connect(sessionID: SessionID) {
        connect(sessionID: sessionID, replayBufferedEvents: true)
    }

    func connect(sessionID: SessionID, replayBufferedEvents: Bool) {
        let client: any SessionWebSocketClient
        if let native = bundle.nativeClient(forSessionID: sessionID) {
            client = native.makeEventClient(sessionID: sessionID)
        } else {
            let runtime: CodexAppServerSessionRuntime
            do {
                runtime = try bundle.runtime(forSessionID: sessionID)
            } catch {
                activeClient?.disconnect()
                activeClient = nil
                onStatus?(.failed(error.localizedDescription))
                return
            }
            client = CodexAppServerSessionWebSocketClient(runtime: runtime)
        }
        // “单活”边界是当前 Mac，而不是 Runtime provider。同一台 Mac 上当前会话与后台
        // 排队会话可能分别属于 Codex/Claude；两者各复用一条共享连接，不能互相退役。
        // 切换 Mac、进入后台或凭据失效时仍由 AppServerRuntimeBundle 整体关闭。
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
        guard let activeClient else {
            return false
        }
        // guidance 已提交后可能随页面切换释放 wrapper。把本次 generation 的结果处理器
        // 直接交给底层 Task，避免弱转发链随 wrapper 消失，同时保留 Store 自己的 host/generation 校验。
        // 这条 Codex 专用的结果所有权路径必须保留，不能因为改成协议类型而丢掉。
        if let codexClient = activeClient as? CodexAppServerSessionWebSocketClient {
            return codexClient.sendGuidance(
                payload,
                clientMessageID: clientMessageID,
                expectedTurnID: expectedTurnID,
                acceptedHandler: onSendAccepted,
                failureHandler: onSendFailure,
                outcomeHandler: onTurnSendOutcome
            )
        }
        // Harness 不支持 guidance：显式拒绝，不把它当普通 prompt 发出去。
        onSendFailure?(
            clientMessageID,
            HarnessNativeUnavailableError.unsupported(operation: "guidance").localizedDescription
        )
        return false
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

    private func wireHandlers(to client: any SessionWebSocketClient) {
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
        client.onUserInputResponseFailure = { [weak self] requestID, message, expired in
            self?.onUserInputResponseFailure?(requestID, message, expired)
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
            bundle.routes.remember(runtimeProvider: row.runtimeProvider, source: row.source, for: row.id)
        default:
            break
        }
    }
}

final class CodexAppServerSessionWebSocketClient: SessionWebSocketClient {
    private(set) var turnDeliveryMode: TurnDeliveryMode = .direct
    var onEvent: (@MainActor (AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendAccepted: ((ClientMessageID?) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?
    var onTurnSendOutcome: ((ClientMessageID?, TurnSendOutcome) -> Void)?
    var onApprovalDecisionFailure: ((String, String) -> Void)?
    var onUserInputResponseFailure: ((String, String, Bool) -> Void)?
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
                // 输入框按 Desktop 使用本地排队和 turn/start；每条新回合自带权限。
                // thread/queue/add 只供独立任务工具向服务端队列提交消息。
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
             .permissionProfileUpdated(_, let metadata),
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
        sendGuidance(
            payload,
            clientMessageID: clientMessageID,
            expectedTurnID: expectedTurnID,
            acceptedHandler: onSendAccepted,
            failureHandler: onSendFailure,
            outcomeHandler: onTurnSendOutcome
        )
    }

    @discardableResult
    fileprivate func sendGuidance(
        _ payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID?,
        expectedTurnID: TurnID,
        acceptedHandler: ((ClientMessageID?) -> Void)?,
        failureHandler: ((ClientMessageID?, String) -> Void)?,
        outcomeHandler: ((ClientMessageID?, TurnSendOutcome) -> Void)?
    ) -> Bool {
        guard let sessionID else {
            failureHandler?(clientMessageID, L10n.text("ui.direct_websocket_not_connected"))
            return false
        }
        guard !payload.isEmpty else {
            return true
        }
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
            onUserInputResponseFailure?(requestID, L10n.text("ui.direct_websocket_not_connected"), false)
            return false
        }
        let failureHandler = onUserInputResponseFailure
        Task { [runtime, sessionID] in
            do {
                try await runtime.respondToUserInput(sessionID: sessionID, requestID: requestID, answers: answers)
            } catch {
                // 挂起表里查不到，说明这条请求在对端已经不存在了：Claude 进程重启会
                // 把那次工具调用一起带走，而历史里的卡片还在。重试只会一直失败。
                let expired: Bool
                if case CodexAppServerSessionRuntimeError.userInputRequestNotFound = error {
                    expired = true
                } else {
                    expired = false
                }
                await MainActor.run {
                    failureHandler?(requestID, error.localizedDescription, expired)
                }
            }
        }
        return true
    }
}
