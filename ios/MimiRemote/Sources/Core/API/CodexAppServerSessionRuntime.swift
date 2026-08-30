import Foundation
enum CodexAppServerSessionRuntimeError: LocalizedError {
    case invalidGatewayURL
    case gatewayUnavailable
    case threadSearchUnavailable
    case projectNotFound(String)
    case projectRequired
    case sessionNotFound(SessionID)
    case missingActiveTurn(SessionID)
    case activeTurnConflict(session: AgentSession, activeTurnID: TurnID)
    case approvalNotFound(String)
    case userInputRequestNotFound(String)
    case serverQueueUnavailable(String)
    case serverQueueOutputSchemaUnsupported
    case serverQueueSubmissionInFlight(SessionID)
    case paginatedHistoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidGatewayURL:
            return L10n.text("ui.app_server_gateway_url_is_invalid")
        case .gatewayUnavailable:
            return L10n.text("ui.agentd_does_not_enable_app_server_gateway_please")
        case .threadSearchUnavailable:
            return L10n.text("ui.currently_agentd_or_codex_app_server_does_not")
        case .projectNotFound(let projectID):
            return L10n.format("ui.the_project_does_not_exist_or_is_not", projectID)
        case .projectRequired:
            return L10n.text("ui.direct_mode_must_first_select_the_allowlist_item")
        case .sessionNotFound(let sessionID):
            return L10n.format("ui.app_server_thread_does_not_exist_value", sessionID)
        case .missingActiveTurn(let sessionID):
            return L10n.format("ui.there_is_no_interruptible_active_turn_for_the", sessionID)
        case .activeTurnConflict:
            return L10n.text("ui.please_wait_for_the_current_turn_to_complete")
        case .approvalNotFound(let approvalID):
            return L10n.format("ui.approval_request_has_expired_value", approvalID)
        case .userInputRequestNotFound(let requestID):
            return L10n.format("ui.the_request_for_additional_information_has_expired_value", requestID)
        case .serverQueueUnavailable(let method):
            return String(
                format: String(localized: "ui.current_ssh_app_server_does_not_support_experimental_api"),
                method
            )
        case .serverQueueOutputSchemaUnsupported:
            return String(localized: "ui.shared_ssh_queue_does_not_support_output_schema")
        case .serverQueueSubmissionInFlight:
            return String(
                localized: "ui.this_session_already_has_a_mimi_message_waiting_for_app_server"
            )
        case .paginatedHistoryUnavailable(let method):
            return String(
                format: String(localized: "ui.current_app_server_does_not_support_paginated_history_api"),
                method
            )
        }
    }
}

struct CodexAppServerSessionContext {
    var session: AgentSession
    var cwd: String
    var activeTurnID: TurnID?
}

struct CodexAppServerPreparedConnection {
    let connection: CodexAppServerConnection
    let notifications: AsyncStream<CodexAppServerNotification>
    let serverRequests: AsyncStream<CodexAppServerServerRequest>
}

struct CodexAppServerConnectionAttempt {
    let id: UUID
    let connection: CodexAppServerConnection
    let task: Task<CodexAppServerPreparedConnection, Error>
}

struct CodexAppServerResolvedServerRequests {
    var approvalSessionIDs: [SessionID] = []
    var userInputSessionIDs: [SessionID] = []
}

struct CodexAppServerThreadResumeTask {
    let connection: CodexAppServerConnection
    let token: UUID
    let task: Task<Void, Error>
}

struct CodexAppServerThreadSubscriptionLease: Equatable {
    let generation: UInt64
    let wantsEvents: Bool
}

struct CodexAppServerTurnInterruptRecoveryTask {
    let turnID: TurnID
    let token: UUID
    let task: Task<Void, Never>
}

enum CodexAppServerTurnStartOutcome: Equatable {
    // RPC 已接受，且当前仍是这一轮或尚在等待 turn/started。
    case active(turnID: TurnID?)
    // RPC 已接受，但 ACK 到达前已观察到终态；上层应完成发送，不再建立 start barrier。
    case terminal(turnID: TurnID?)
    // RPC 已接受，但实时事件已推进到另一轮；上层应绑定权威 active turn。
    case superseded(turnID: TurnID?, activeTurnID: TurnID)
    // thread 已关闭；本次发送已由 RPC 接受，但同一 thread 上不能继续自动派发。
    case threadClosed(turnID: TurnID?)

    var activeTurnID: TurnID? {
        guard case .active(let turnID) = self else {
            return nil
        }
        return turnID
    }
}

enum CodexAppServerTurnSubmissionOutcome: Equatable {
    case direct(CodexAppServerTurnStartOutcome)
    case serverQueued(submissionID: String, startedTurnID: TurnID?)
}

struct CodexAppServerPendingTurnStartObservation {
    let attemptID: UUID
    var terminalTurnIDs: Set<TurnID> = []
    var sawUnidentifiedTerminal = false
    var threadClosed = false
}

enum CodexAppServerBufferedEventReplayPolicy {
    case all
    case stateOnly
}

actor CodexAppServerSessionRuntime {
    let endpoint: String
    let token: String
    let runtimeProvider: String
    let transportFactory: () -> CodexAppServerTransport
    let configProvider: () async throws -> CodexAppServerConfigResponse
    var config: CodexAppServerConfigResponse?
    var connection: CodexAppServerConnection?
    var connectionAttempt: CodexAppServerConnectionAttempt?
    var notificationPumpTask: Task<Void, Never>?
    var serverRequestPumpTask: Task<Void, Never>?
    var projector = CodexAppServerEventProjector()
    var contextsBySessionID: [SessionID: CodexAppServerSessionContext] = [:]
    // app-server 只向「在当前 gateway 连接上 resume/start 过」的 thread 推送 turn 事件；记录本连接已
    // 经绑定的 thread，断线重连后这个集合随新连接清空，确保再次发送时会先补一次 thread/resume。
    var threadsResumedOnConnection: Set<SessionID> = []
    // actor 会在 await thread/resume 时重入；同一连接、同一 thread 的并发监听和发送必须等待同一任务，
    // 否则 gateway 会拒绝重复历史请求，进一步放大上游高负载。
    var threadResumeTasksBySessionID: [SessionID: CodexAppServerThreadResumeTask] = [:]
    // unsubscribe 是后台 best-effort RPC，响应可能晚于同一 thread 的新 connectForEvents。
    // 每次订阅意图都换代；迟到退订只能作用于自己的 lease，不能覆盖更新一代的监听。
    var threadSubscriptionLeaseBySessionID: [SessionID: CodexAppServerThreadSubscriptionLease] = [:]
    var bufferedEventsBySessionID: [SessionID: [AgentEvent]] = [:]
    var eventMailboxesBySessionID: [
        SessionID: [UUID: CodexAppServerEventMailbox]
    ] = [:]
    var pendingApprovalRequestsByID: [String: CodexAppServerServerRequest] = [:]
    var pendingUserInputRequestsByID: [String: CodexAppServerServerRequest] = [:]
    // notification 与 reverse server request 由两条 pump 投递。resolved/terminal 可能先落到 actor，
    // 因此保留有界 tombstone，拒绝随后迟到的旧请求，避免重新生成孤儿待输入状态。
    var resolvedServerRequestTombstonesByKey: [String: Date] = [:]
    var terminalTurnTombstonesByKey: [String: Date] = [:]
    var terminalSessionBarriers: [SessionID: Date] = [:]
    var accountRateLimit: RateLimitSummary?
    var rateLimitRefreshTask: Task<RateLimitSummary?, Never>?
    var lastRateLimitRefreshAt: Date?
    var accountTokenUsage: AccountTokenUsageSnapshot?
    var accountTokenUsageRefreshTask: Task<AccountTokenUsageFetch, Never>?
    // 正在 startTurn 中的 thread：turn/start 请求挂起期间，actor 会重入处理 server-request，
    // 此时本地还没记上 activeTurnID、状态也可能仍是空闲。这一窗口内到达的审批一定属于刚发起的
    // 新 turn，不能被 isStaleReplayedApproval 误判成过期重放。
    var sessionsStartingTurn: Set<SessionID> = []
    // Claude bridge 可能先推送 turn/completed，随后才返回 turn/start ACK。只在对应 RPC 真正
    // 等待回执的窗口记录终态，回执或错误到达后立即清理，避免历史重放污染下一次发送。
    var pendingTurnStartObservationsBySessionID: [
        SessionID: CodexAppServerPendingTurnStartObservation
    ] = [:]
    // 本端这条 runtime 亲自发起过的 turn。app-server 在 resume 时会重放“仍未应答”的审批；只有属于这些
    // turn 的审批才是当前用户真正在等待的，其余（Desktop 发起、或历史里没 terminal 化的旧审批）需要按
    // 过期处理。即使本端的审批挂了很久也不能误杀，所以单列出来优先放行。
    var turnsStartedByThisRuntime: Set<TurnID> = []
    // 历史只读取 thread 元数据，并通过 turns/items 游标分页；这里不保留整段 thread 历史缓存。
    var stateDBOnlyListUnavailable = false
    var stateDBOnlyScanRequiredCWDs: Set<String> = []
    var recencySortUnavailable = false
    var turnStartTasksBySessionID: [
        SessionID: (token: UUID, task: Task<CodexAppServerTurnStartOutcome, Error>)
    ] = [:]
    var serverQueueSubmissionSessionIDs: Set<SessionID> = []
    // turn/interrupt 的 RPC ACK 与 turn/completed 通知是两条独立链路。通知若落在连接切换窗口，
    // SessionStore 会一直保留旧 activeTurnID。按被中断的 turn 去重保存有界恢复任务，
    // 只在权威 turns 快照确认终态后补发完成事件。
    var turnInterruptRecoveryTasksBySessionID: [SessionID: CodexAppServerTurnInterruptRecoveryTask] = [:]
    let requestTimeout: TimeInterval
    let longRunningRequestTimeout: TimeInterval
    let turnInterruptRecoveryDelaysNanoseconds: [UInt64]
    let gatewayDefaults: UserDefaults
    var rateLimitRequestTimeout: TimeInterval {
        // Claude 首次读取可能需要通过交互式 `/status` 刷新 Keychain 凭据；
        // 该请求仍在独立 actor/transport 上等待，不阻塞主线程。Codex 保持原 5 秒上限。
        runtimeProvider == "claude" ? min(requestTimeout, 15) : min(requestTimeout, 5)
    }
    // 每个 thread 最近一次收到上游实时通知的时间。thread/list、thread/read 偶发把正在执行的
    // turn 误读成 idle/notLoaded；刚收到过实时信号的 thread 在这个时间窗内不接受 history 降级。
    var lastLiveSignalAtBySessionID: [SessionID: Date] = [:]
    let historyDowngradeGraceInterval: TimeInterval = 15
    var replayCursorEpoch: UInt64 = 0

    init(
        endpoint: String,
        token: String,
        runtimeProvider: String = "codex",
        transportFactory: @escaping () -> CodexAppServerTransport = { URLSessionCodexAppServerTransport() },
        requestTimeout: TimeInterval = 20,
        longRunningRequestTimeout: TimeInterval = 60,
        gatewayDefaults: UserDefaults = .standard,
        turnInterruptRecoveryDelaysNanoseconds: [UInt64] = [400_000_000, 1_000_000_000, 2_000_000_000],
        configProvider: (() async throws -> CodexAppServerConfigResponse)? = nil
    ) {
        let normalizedEndpoint = AgentAPIClient.normalizedEndpoint(endpoint)
        self.endpoint = normalizedEndpoint
        self.token = token
        self.runtimeProvider = Self.normalizedRuntimeProvider(runtimeProvider)
        self.transportFactory = transportFactory
        self.requestTimeout = requestTimeout
        self.longRunningRequestTimeout = longRunningRequestTimeout
        self.turnInterruptRecoveryDelaysNanoseconds = turnInterruptRecoveryDelaysNanoseconds
        self.gatewayDefaults = gatewayDefaults
        self.configProvider = configProvider ?? {
            try await AgentAPIClient(endpoint: normalizedEndpoint, token: token).appServerConfig()
        }
    }

    deinit {
        connectionAttempt?.task.cancel()
        notificationPumpTask?.cancel()
        serverRequestPumpTask?.cancel()
        rateLimitRefreshTask?.cancel()
        accountTokenUsageRefreshTask?.cancel()
        threadResumeTasksBySessionID.values.forEach { $0.task.cancel() }
        turnInterruptRecoveryTasksBySessionID.values.forEach { $0.task.cancel() }
    }

    func projects() async throws -> [AgentProject] {
        try await ensureConfig().projects
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        let result = try await sendRecoveringFromStaleInitialization(
            CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).modelList()
        )
        return CodexAppServerModelOption.parseListResult(result).map {
            $0.withRuntimeProvider($0.runtimeProvider ?? runtimeProvider)
        }
    }

    func permissionProfiles(cwd: String) async throws -> [CodexAppServerPermissionProfileSummary] {
        let result = try await sendRecoveringFromStaleInitialization(
            CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
                .permissionProfileList(cwd: cwd)
        )
        return CodexAppServerPermissionProfileSummary.parseListResult(result)
    }

    func capabilities(path: String?, forceReload: Bool = false) async throws -> CapabilityListResponse {
        let legacyClient = AgentAPIClient(endpoint: endpoint, token: token)
        guard let cwd = path?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return try await legacyClient.capabilities(path: path)
        }

        // Skill 与已安装插件都以 app-server 的只读列表为准；旧 REST 发现继续作为
        // Skill 兼容兜底并提供 MCP 摘要。plugin/installed 失败时只降级为空列表。
        do {
            let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
            let skillResult = try await sendRecoveringFromStaleInitialization(
                builder.skillsList(cwd: cwd, forceReload: forceReload),
                timeout: forceReload ? longRunningRequestTimeout : requestTimeout
            )
            let pluginResult = try? await sendRecoveringFromStaleInitialization(
                builder.installedPluginList(cwd: cwd)
            )
            let skills = SkillCapability.parseAppServerListResult(skillResult, cwd: cwd)
            let plugins = CodexPluginCapability.parseAppServerInstalledResult(pluginResult)
            let legacy = try? await legacyClient.capabilities(path: cwd)
            return CapabilityListResponse(
                path: cwd,
                skills: skills.isEmpty ? (legacy?.skills ?? []) : skills,
                mcpServers: legacy?.mcpServers ?? [],
                plugins: plugins
            )
        } catch {
            if let legacy = try? await legacyClient.capabilities(path: cwd) {
                return legacy
            }
            throw error
        }
    }

    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?) async throws -> VoiceTranscriptionResponse {
        // 语音转写属于 agentd 控制面：移动端只上传音频，Codex 登录态始终留在 Mac。
        try await AgentAPIClient(endpoint: endpoint, token: token).transcribeVoice(
            filename: filename,
            contentType: contentType,
            audioData: audioData,
            language: language
        )
    }

    func validateDirectGateway() async throws {
        let config = try await ensureConfig(forceRefresh: true)
        guard runtimeGatewayAvailable(in: config) else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        let gatewayURL = try gatewayURL(from: config)
        let probe = CodexAppServerConnection(transport: transportFactory())
        try await probe.connect(url: gatewayURL, token: token)
        await probe.disconnect()
    }

    /// 候选主机只初始化共享 gateway，不 resume thread、不拉取任何业务数据。
    /// 提交后 SessionStore 会直接复用这条连接，避免 bootstrap 再次 initialize。
    func prepareForHostActivation() async throws {
        try await withTaskCancellationHandler {
            _ = try await ensureConnection()
        } onCancel: {
            Task {
                await self.shutdownForHostSwitch()
            }
        }
    }

    /// 主机切换结束或候选验证失败时显式释放连接和 pump。
    /// 不能只依赖 deinit，否则短时间内可能同时残留多条业务 WebSocket。
    func shutdownForHostSwitch() async {
        await cancelConnectionAttempt()
        rateLimitRefreshTask?.cancel()
        rateLimitRefreshTask = nil
        accountTokenUsageRefreshTask?.cancel()
        accountTokenUsageRefreshTask = nil
        cancelAllTurnInterruptRecoveryTasks()
        guard let activeConnection = connection else {
            notificationPumpTask?.cancel()
            notificationPumpTask = nil
            serverRequestPumpTask?.cancel()
            serverRequestPumpTask = nil
            threadResumeTasksBySessionID.values.forEach { $0.task.cancel() }
            threadResumeTasksBySessionID.removeAll(keepingCapacity: false)
            finishAttachedEventStreams()
            return
        }
        await retireConnection(activeConnection)
    }

    func channelAvailable(runtimeProvider raw: String) async throws -> Bool {
        let runtime = Self.normalizedRuntimeProvider(raw)
        let config = try await ensureConfig()
        if runtime == "codex" {
            return true
        }
        return config.channels.contains { channel in
            (Self.normalizedRuntimeProvider(channel.runtimeID ?? channel.id) == runtime ||
                Self.normalizedRuntimeProvider(channel.provider) == runtime) &&
                channel.gatewayAvailable
        }
    }

    func sessionsPage(
        projectID: String?,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency = .fastIndexed
    ) async throws -> SessionsPage {
        let projects = try await projects()
        guard let projectID else {
            throw CodexAppServerSessionRuntimeError.projectRequired
        }
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw CodexAppServerSessionRuntimeError.projectNotFound(projectID)
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let page = try await threadListPageWithIndexedFallback(
            cwd: project.path,
            cursor: cursor,
            limit: limit,
            builder: builder,
            projects: projects,
            fallbackProject: project,
            consistency: consistency
        )
        for session in page.sessions {
            contextsBySessionID[session.id] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
        }
        scheduleRateLimitRefreshIfAvailable()
        return page
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency = .fastIndexed
    ) async throws -> SessionsPage {
        let baseProjects = try await projects()
        let projects = projectsIncludingWorkspace(baseProjects, workspace: workspace)
        let workspaceProject = workspace.project
        let listCWD = threadListCWD(for: workspace)
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let page = try await threadListPageWithIndexedFallback(
            cwd: listCWD,
            cursor: cursor,
            limit: limit,
            builder: builder,
            projects: projects,
            fallbackProject: workspaceProject,
            consistency: consistency
        )
        for session in page.sessions {
            contextsBySessionID[session.id] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
        }
        scheduleRateLimitRefreshIfAvailable()
        return page
    }

    func controlledGlobalSessionsPage(
        cursor: String?,
        limit: Int?
    ) async throws -> SessionsPage {
        let projects = try await projects()
        let result = try await sendRecoveringFromStaleInitialization(
            CodexAppServerRequestBuilder(allowlistedProjects: projects)
                .controlledGlobalThreadList(limit: limit, cursor: cursor),
            timeout: longRunningRequestTimeout
        )
        let page = threadListPage(from: result, projects: projects, fallbackProject: nil)
        for session in page.sessions {
            contextsBySessionID[session.id] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
        }
        return page
    }

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchTerm.isEmpty else {
            return ThreadSearchPage(results: [])
        }
        let config = try await ensureConfig()
        guard config.policy.allowedMethods.contains("thread/search") else {
            throw CodexAppServerSessionRuntimeError.threadSearchUnavailable
        }
        let projects = config.projects
        let result = try await sendRecoveringFromStaleInitialization(
            try CodexAppServerRequestBuilder(allowlistedProjects: projects).threadSearch(
                query: searchTerm,
                limit: limit,
                cursor: cursor
            ),
            timeout: longRunningRequestTimeout
        )
        let page = try threadSearchPage(from: result, projects: projects)
        for session in page.sessions {
            contextsBySessionID[session.id] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
        }
        return page
    }

    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        // resolve 是 agentd 控制面的 REST 接口（非 app-server JSON-RPC），用 runtime 自己的 endpoint/token 直接请求。
        try await AgentAPIClient(endpoint: endpoint, token: token).resolveWorkspace(path: path)
    }

    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        // Worktree 是 agentd 管理的本机 Git checkout；创建后返回可直接用于 thread/start 的 workspace。
        try await AgentAPIClient(endpoint: endpoint, token: token).createWorktree(path: path, name: name, base: base, branch: branch)
    }

    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse {
        // 分支列表是 agentd 控制面的只读 Git 引用发现，不走 app-server JSON-RPC。
        try await AgentAPIClient(endpoint: endpoint, token: token).worktreeBranches(path: path)
    }

    func listWorktrees() async throws -> [WorktreeListItem] {
        // Worktree registry 属于 agentd 控制面状态；列表用于 iPad 管理本机 checkout，不走 app-server。
        try await AgentAPIClient(endpoint: endpoint, token: token).listWorktrees()
    }

    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse {
        // 删除会改变本机文件系统，所有路径和 managed registry 校验都留在 agentd 后端执行。
        try await AgentAPIClient(endpoint: endpoint, token: token).deleteWorktree(path: path, force: force)
    }

    func pruneMissingWorktrees() async throws -> WorktreePruneResponse {
        // 只清理 agentd registry 中已经不存在的 checkout 登记，不删除真实文件。
        try await AgentAPIClient(endpoint: endpoint, token: token).pruneMissingWorktrees()
    }

    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse {
        try await AgentAPIClient(endpoint: endpoint, token: token).previewWorktreeCleanup()
    }

    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse {
        try await AgentAPIClient(endpoint: endpoint, token: token).executeWorktreeCleanup(paths: paths, planID: planID)
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        // 目录浏览同样走 agentd 控制面 REST 接口，传空 path 表示从服务端默认浏览根开始。
        try await AgentAPIClient(endpoint: endpoint, token: token).listDirectories(path: path)
    }

    func readFile(path: String) async throws -> FileReadResponse {
        // 文件预览只通过 agentd 控制面读取授权边界内的普通文件，iPad 端不直接访问本机文件系统。
        try await AgentAPIClient(endpoint: endpoint, token: token).readFile(path: path)
    }

    func readHistoryMedia(id: String) async throws -> FileReadResponse {
        // 历史媒体是 gateway 脱水后生成的短期缓存，只在用户点按历史图片占位时读取。
        try await AgentAPIClient(endpoint: endpoint, token: token).readHistoryMedia(id: id)
    }

    func readHistoryOutput(id: String) async throws -> FileReadResponse {
        // 命令/MCP/diff 大输出不走 WebSocket 首屏；用户明确打开时再走鉴权 REST。
        try await AgentAPIClient(endpoint: endpoint, token: token).readHistoryOutput(id: id)
    }

    func commandActions(path: String) async throws -> [AgentCommandAction] {
        // 快捷动作是 agentd 配置的 allowlist 能力，只在控制面列出，不让 app-server 接触命令定义。
        try await AgentAPIClient(endpoint: endpoint, token: token).commandActions(path: path)
    }

    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        // 执行动作会改变本机状态或产生副作用，统一交给 agentd 做路径和 action ID 校验。
        try await AgentAPIClient(endpoint: endpoint, token: token).runCommandAction(path: path, id: id, confirmed: confirmed)
    }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        // Git 状态是 agentd 控制面的只读接口；不走 app-server，避免把 Git 审查和对话协议耦合。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitStatus(path: path)
    }

    func gitStatusSummary(path: String) async throws -> GitStatusResponse {
        // 工作区卡片只需要轻量摘要，不能为每张卡片下载完整 diff。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitStatus(path: path, summaryOnly: true)
    }

    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse {
        // Git 写动作仍由 agentd 控制面执行，方便统一做 allowlist、路径和动作白名单校验。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitAction(path: path, action: action, files: files)
    }

    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse {
        // hunk 级 Git 动作仍复用 agentd 控制面，由后端限制单 hunk 和安全相对路径。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitPatchAction(path: path, action: action, patch: patch)
    }

    func gitCommit(path: String, message: String) async throws -> GitStatusResponse {
        // 本地 commit 属于 Git 控制面能力；只提交已暂存内容，保持对话协议单纯。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitCommit(path: path, message: message)
    }

    func gitPush(path: String, remote: String?) async throws -> GitPushResponse {
        // push 仍由 agentd 控制面执行，禁止 force，复用本机 Git 凭证。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitPush(path: path, remote: remote)
    }

    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse {
        // 快捷发布固定走 agentd 的受限组合动作，客户端不直接拼接 Git 命令。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitQuickPublish(
            path: path,
            message: message,
            remote: remote,
            confirmed: confirmed
        )
    }

    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse {
        // 发布能力以主机本地预检为准，避免只看到 iOS 工程就错误开放按钮。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitTestFlightStatus(path: path)
    }

    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse {
        try await AgentAPIClient(endpoint: endpoint, token: token).gitTestFlightRun(
            path: path,
            whatToTest: whatToTest,
            confirmed: confirmed
        )
    }

    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse {
        // PR 通过本机已登录的 gh CLI 创建，iPad 不接触 GitHub token。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitCreatePullRequest(path: path, title: title, body: body, draft: draft)
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        // PR 状态同样读取本机 gh CLI，移动端只展示当前分支摘要。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitPullRequestStatus(path: path)
    }

    func session(id: SessionID, afterSeq: EventSequence?) async throws -> SessionResponse {
        let result = try await sendRecoveringFromStaleInitialization(
            CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).threadRead(threadID: id, includeTurns: false),
            timeout: longRunningRequestTimeout
        )
        guard let thread = threadObject(from: result) else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(id)
        }
        _ = await refreshRateLimitIfAvailable(force: true)
        let session = try agentSession(from: thread, projects: try await projects(), fallbackProject: nil)
        contextsBySessionID[id] = CodexAppServerSessionContext(
            session: session,
            cwd: session.dir,
            activeTurnID: session.activeTurnID
        )
        return SessionResponse(session: session, recentOutput: nil, lastSeq: session.lastSeq)
    }

    func refreshRateLimit() async -> RateLimitSummary? {
        await refreshRateLimitIfAvailable(force: true)
    }

    func threadGoal(threadID: SessionID) async throws -> ThreadGoal? {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        let result = try await sendRecoveringFromStaleInitialization(builder.threadGoalGet(threadID: threadID))
        guard let goal = threadGoal(from: result) else {
            clearThreadGoalLocal(threadID: threadID)
            emit(.goalCleared(metadata(threadID: threadID, turnID: nil)))
            return nil
        }
        applyThreadGoal(goal)
        emit(.goalUpdated(goal, metadata(threadID: goal.threadID, turnID: nil)))
        return goal
    }

    @discardableResult
    func setThreadGoal(
        threadID: SessionID,
        objective: String? = nil,
        status: ThreadGoalStatus? = nil,
        tokenBudget: Int64? = nil
    ) async throws -> ThreadGoal {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        let normalizedObjective = objective?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await sendRecoveringFromStaleInitialization(builder.threadGoalSet(
            threadID: threadID,
            objective: normalizedObjective?.isEmpty == false ? normalizedObjective : nil,
            status: status,
            tokenBudget: tokenBudget
        ))
        guard let goal = threadGoal(from: result) else {
            throw AgentAPIError.invalidResponse
        }
        applyThreadGoal(goal)
        emit(.goalUpdated(goal, metadata(threadID: goal.threadID, turnID: nil)))
        return goal
    }

    func clearThreadGoal(threadID: SessionID) async throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        _ = try await sendRecoveringFromStaleInitialization(builder.threadGoalClear(threadID: threadID))
        clearThreadGoalLocal(threadID: threadID)
        emit(.goalCleared(metadata(threadID: threadID, turnID: nil)))
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        let baseProjects = try await projects()
        let projectPath = payload.projectPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let project: AgentProject
        let projects: [AgentProject]
        if let projectPath, !projectPath.isEmpty {
            project = AgentProject(
                id: payload.projectID,
                name: firstNonEmpty(payload.projectName?.trimmingCharacters(in: .whitespacesAndNewlines), URL(fileURLWithPath: projectPath).lastPathComponent),
                path: projectPath
            )
            projects = projectsIncludingWorkspace(baseProjects, workspace: AgentWorkspace(
                id: project.id,
                name: project.name,
                path: project.path,
                rootProjectID: payload.rootProjectID
            ))
        } else {
            guard let existingProject = baseProjects.first(where: { $0.id == payload.projectID }) else {
                throw CodexAppServerSessionRuntimeError.projectNotFound(payload.projectID)
            }
            project = existingProject
            projects = baseProjects
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let usesSharedServerQueue = try await turnDeliveryMode() == .sharedServerQueue
        var threadOptions = payload.turnOptions
        // 线程级请求只负责创建/恢复会话；模型由随后的 turn/start 携带。
        // 部分 app-server 版本会拒绝 thread/start/resume 上的 model/modelProvider，
        // 所以这里必须保持主线兼容行为，不能让纯 Codex 用户回归。
        if !usesSharedServerQueue {
            threadOptions.model = nil
            threadOptions.modelProvider = nil
        }
        threadOptions = runtimeScopedThreadOptions(threadOptions)
        let spec: CodexAppServerRequestSpec
        if payload.resumeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            spec = usesSharedServerQueue
                ? try builder.threadStartForSharedQueue(cwd: project.path, options: threadOptions)
                : (projectPath?.isEmpty == false
                    ? try builder.threadStart(cwd: project.path, options: threadOptions)
                    : try builder.threadStart(projectID: payload.projectID, options: threadOptions))
        } else {
            spec = usesSharedServerQueue
                ? try builder.threadResumePreservingSharedState(
                    threadID: payload.resumeID,
                    cwd: project.path
                )
                : (projectPath?.isEmpty == false
                    ? try builder.threadResume(threadID: payload.resumeID, cwd: project.path, options: threadOptions)
                    : try builder.threadResume(threadID: payload.resumeID, projectID: payload.projectID, options: threadOptions))
        }

        let result: CodexAppServerJSONValue?
        do {
            result = try await sendRecoveringFromStaleInitialization(spec, timeout: longRunningRequestTimeout)
        } catch {
            guard !payload.resumeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  shouldFallbackFromInitialTurnsPage(error) else {
                throw error
            }
            // idle 历史会话的发送会通过 createSession(resume:) 进入这里；发送链路必须允许
            // initialTurnsPage 因响应过大或版本不兼容而降级，否则 turn/start 永远不会发出。
            let fallback = usesSharedServerQueue
                ? try builder.threadResumePreservingSharedState(
                    threadID: payload.resumeID,
                    cwd: project.path,
                    includeInitialTurnsPage: false
                )
                : try builder.threadResume(
                    threadID: payload.resumeID,
                    cwd: project.path,
                    options: threadOptions,
                    includeInitialTurnsPage: false
                )
            result = try await sendRecoveringFromStaleInitialization(fallback, timeout: longRunningRequestTimeout)
        }
        guard let thread = threadObject(from: result) else {
            throw AgentAPIError.invalidResponse
        }
        var session = try agentSession(from: thread, projects: projects, fallbackProject: project, forceRunning: true)
        emitActivePermissionProfile(from: result, threadID: session.id)
        let cwd = session.dir
        contextsBySessionID[session.id] = CodexAppServerSessionContext(session: session, cwd: cwd, activeTurnID: session.activeTurnID)
        let turnPayload = CodexAppServerTurnPayload(input: payload.input, options: payload.turnOptions)
        if !turnPayload.isEmpty {
            // thread/start 后立刻 turn/start 仍沿用当前连接；但空会话没有立即 turn，
            // 后续监听/发送前必须补 thread/resume，否则真实 app-server 可能不回推事件。
            threadsResumedOnConnection.insert(session.id)
        }

        if !usesSharedServerQueue,
           !turnPayload.isEmpty,
           let activeTurnID = session.activeTurnID {
            // resume 已经证明旧 turn 仍活跃，此时绝不能再发第二个 turn/start。
            throw CodexAppServerSessionRuntimeError.activeTurnConflict(
                session: session,
                activeTurnID: activeTurnID
            )
        }

        let initialGoalObjective = payload.initialGoalObjective?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let initialGoalObjective, !initialGoalObjective.isEmpty {
            // 目标任务必须先写入 thread 元数据，再启动首个 turn；这样 app-server 从一开始就知道
            // 这次执行属于 goal，而不是普通 turn 完成后再补标签。
            try await setThreadGoal(threadID: session.id, objective: initialGoalObjective, status: .active)
            if let updated = contextsBySessionID[session.id]?.session {
                session = updated
            }
        }

        if !turnPayload.isEmpty, !usesSharedServerQueue {
            _ = try await submitTurnOutcome(
                sessionID: session.id,
                payload: turnPayload,
                clientMessageID: payload.clientMessageID
            )
            // 通知可能在 turn/start ACK 前已经把会话推进到 terminal/closed/下一轮。
            // 直接采用 Runtime 的最新投影，不能用 ACK 再无条件覆盖。
            session = contextsBySessionID[session.id]?.session ?? session
        }

        return CreateSessionResponse(
            session: session,
            wsURL: try Self.gatewayURL(endpoint: endpoint, sessionID: session.id, runtimeProvider: runtimeProvider).absoluteString,
            requiresQueuedInitialInput: usesSharedServerQueue && !turnPayload.isEmpty
        )
    }

    func stopSession(id: SessionID) async throws {
        guard let activeTurnID = contextsBySessionID[id]?.activeTurnID else {
            _ = withUpdatedSession(id) { item in
                item.status = "closed"
            }
            return
        }
        let spec = CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).turnInterrupt(threadID: id, turnID: activeTurnID)
        _ = try await sendRecoveringFromStaleInitialization(spec)
        _ = withUpdatedSession(id) { item in
            item.status = "closed"
            item.activeTurnID = nil
        }
    }

    func setSessionArchived(id: SessionID, archived: Bool) async throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        let spec = archived
            ? builder.threadArchive(threadID: id)
            : builder.threadUnarchive(threadID: id)
        _ = try await sendRecoveringFromStaleInitialization(spec)
        if archived {
            contextsBySessionID.removeValue(forKey: id)
            pendingTurnStartObservationsBySessionID.removeValue(forKey: id)
            threadSubscriptionLeaseBySessionID.removeValue(forKey: id)
        }
    }

    func setThreadName(threadID: SessionID, name: String) async throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        _ = try await sendRecoveringFromStaleInitialization(
            try builder.threadSetName(threadID: threadID, name: name)
        )
        // thread/name/updated 会实时更新 Runtime 的 Session 投影；调用方仍可在弱网或
        // 通知丢失时通过 thread/read 拉取权威名称，不维护第二份本地标题。
    }

    func compactThread(threadID: SessionID) async throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        _ = try await sendRecoveringFromStaleInitialization(builder.threadCompactStart(threadID: threadID))
    }

    @discardableResult
    func unsubscribeThread(threadID: SessionID) async throws -> CodexAppServerThreadUnsubscribeStatus? {
        let hadResumeBinding = threadsResumedOnConnection.contains(threadID)
            || threadResumeTasksBySessionID[threadID] != nil
        let lease = replaceThreadSubscriptionLease(sessionID: threadID, wantsEvents: false)
        cancelThreadResumeTask(sessionID: threadID)
        // 在 RPC 发出前先清本地标记。若用户随即重新打开，新的 connectForEvents 必须真的
        // 发送 thread/resume，而不能被旧的“已 resume”缓存短路。
        threadsResumedOnConnection.remove(threadID)
        guard hadResumeBinding else {
            // 独立模式查看空闲历史时从未订阅上游。不要发送多余 unsubscribe，
            // 也不要让一次纯文件读取触发额外的写入路径。
            return .notSubscribed
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        guard threadSubscriptionLeaseBySessionID[threadID] == lease else {
            return nil
        }
        let result: CodexAppServerJSONValue?
        do {
            result = try await sendRecoveringFromStaleInitialization(
                builder.threadUnsubscribe(threadID: threadID)
            )
        } catch {
            // timeout 可能表示服务端已经执行退订、只是 ACK 丢失；若这时已经有更新一代
            // 订阅，仍需 best-effort 恢复，不能把不确定结果留成静默断流。
            if threadSubscriptionLeaseBySessionID[threadID] != lease {
                try? await reassertThreadSubscriptionIfNeeded(
                    sessionID: threadID,
                    supersededLease: lease
                )
            }
            throw error
        }
        if threadSubscriptionLeaseBySessionID[threadID] == lease {
            threadsResumedOnConnection.remove(threadID)
        } else {
            // 退订等待响应期间若已有更新一代订阅，旧 RPC 可能在新 resume 之后才完成。
            // 响应回来后再确认一次当前期望状态，确保服务端最终仍监听最新页面。
            try await reassertThreadSubscriptionIfNeeded(
                sessionID: threadID,
                supersededLease: lease
            )
        }
        return result?.objectValue?["status"]?.stringValue.flatMap(CodexAppServerThreadUnsubscribeStatus.init(rawValue:))
    }

    @discardableResult
    func startReview(
        threadID: SessionID,
        target: CodexAppServerReviewTarget,
        delivery: CodexAppServerReviewDelivery? = nil
    ) async throws -> CodexAppServerReviewStartResult {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        let result = try await sendRecoveringFromStaleInitialization(
            try builder.reviewStart(threadID: threadID, target: target, delivery: delivery)
        )
        guard let object = result?.objectValue,
              let reviewThreadID = object["reviewThreadId"]?.stringValue else {
            throw AgentAPIError.invalidResponse
        }
        let turnID = object["turn"]?.objectValue?["id"]?.stringValue
        if reviewThreadID == threadID {
            _ = withUpdatedSession(threadID) { session in
                session.status = "running"
                session.activeTurnID = turnID
            }
        }
        return CodexAppServerReviewStartResult(reviewThreadID: reviewThreadID, turnID: turnID)
    }

    func forkSession(
        threadID: SessionID,
        workspace: AgentWorkspace,
        reason: AgentSessionForkReason,
        lastTurnID: TurnID? = nil
    ) async throws -> AgentSession {
        let baseProjects = try await projects()
        let project = AgentProject(id: workspace.id, name: workspace.name, path: workspace.path)
        let projects = projectsIncludingWorkspace(baseProjects, workspace: workspace)
        var options = CodexAppServerTurnOptions.default
        options.threadSource = reason.rawValue
        options.preservesThreadPermissionSettings = true
        let result = try await sendRecoveringFromStaleInitialization(
            try CodexAppServerRequestBuilder(allowlistedProjects: projects).threadFork(
                threadID: threadID,
                cwd: workspace.path,
                lastTurnID: lastTurnID,
                options: options
            ),
            timeout: longRunningRequestTimeout
        )
        guard let thread = threadObject(from: result) else {
            throw AgentAPIError.invalidResponse
        }
        let session = try agentSession(from: thread, projects: projects, fallbackProject: project)
        emitActivePermissionProfile(from: result, threadID: session.id)
        contextsBySessionID[session.id] = CodexAppServerSessionContext(
            session: session,
            cwd: session.dir,
            activeTurnID: session.activeTurnID
        )
        threadsResumedOnConnection.insert(session.id)
        return session
    }

    static let threadTurnsCursorPrefix = "turns:"
    static let economyHistoryNotice = L10n.text("ui.this_session_contains_large_images_or_tool_output")
    static let historyItemPageLimit = 50

    func messagesPage(
        sessionID: SessionID,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode = .full,
        recoveringInterruptedTurnID: TurnID? = nil
    ) async throws -> HistoryMessagesPage {
        let config = try await ensureConfig()
        let hasTurnsList = config.policy.allowedMethods.contains("thread/turns/list")
        let hasRequiredItemsList = loadMode == .economy
            || config.policy.allowedMethods.contains("thread/items/list")
        guard hasTurnsList, hasRequiredItemsList else {
            let method = hasTurnsList ? "thread/items/list" : "thread/turns/list"
            throw CodexAppServerSessionRuntimeError.paginatedHistoryUnavailable(method)
        }
        return try await messagesPageFromTurnPages(
            sessionID: sessionID,
            before: before,
            limit: limit,
            loadMode: loadMode,
            projects: config.projects,
            recoveringInterruptedTurnID: recoveringInterruptedTurnID
        )
    }

    /// 外部活动轮询只需要对账正在写入的最新 turn。这里明确禁止回退 thread/read：
    /// legacy 路径的 limit 是 message 数，不具备“完整一个 turn”的增量合并语义。
    func latestTurnHistoryPage(sessionID: SessionID) async throws -> HistoryMessagesPage? {
        let config = try await ensureConfig()
        guard config.policy.allowedMethods.contains("thread/turns/list"),
              config.policy.allowedMethods.contains("thread/items/list") else {
            throw CodexAppServerSessionRuntimeError.paginatedHistoryUnavailable("thread/turns/list")
        }
        return try await messagesPageFromTurnPages(
            sessionID: sessionID,
            before: nil,
            limit: 1,
            loadMode: .full,
            projects: config.projects,
            recoveringInterruptedTurnID: nil
        )
    }

    func messagesPageFromTurnPages(
        sessionID: SessionID,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode,
        projects: [AgentProject],
        recoveringInterruptedTurnID: TurnID?
    ) async throws -> HistoryMessagesPage {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let cursor = Self.decodeThreadTurnsCursor(before)
        let threadMetadata = try await threadMetadataForHistoryPage(
            sessionID: sessionID,
            builder: builder,
            projects: projects,
            shouldRefresh: contextsBySessionID[sessionID] == nil
        )
        var thread = threadMetadata ?? historyThreadShell(sessionID: sessionID, projects: projects)
        let result = try await sendRecoveringFromStaleInitialization(
            builder.threadTurnsList(
                threadID: sessionID,
                cursor: cursor,
                limit: Self.threadTurnPageLimit(forMessageLimit: limit, loadMode: loadMode),
                sortDirection: "desc",
                itemsView: "summary"
            ),
            timeout: longRunningRequestTimeout
        )
        let object = result?.objectValue ?? [:]
        let rawTurns = object["data"]?.arrayValue?.compactMap(\.objectValue) ?? []
        // summary 先把用户和 Agent 文案交给 UI。full 模式的完整 Item 在首屏返回后逐页补齐；
        // 不能在这里同步排空所有 Item cursor，否则一个超大 Turn 会重新变成全量加载。
        let rawChronologicalTurns = Array(rawTurns.reversed())
        let chronologicalTurns = childOwnedHistoryTurns(
            in: thread,
            turns: rawChronologicalTurns
        )
        // desc 分页一旦碰到 child 创建前的父 Turn（或无时间戳的继承 rollout），
        // 后续 cursor 只会继续向更早的父前缀移动。此时必须本地关闭分页，不能把过滤后的
        // 空页配上上游 nextCursor 再交给 UI。
        let reachedInheritedBoundary = chronologicalTurns.count < rawChronologicalTurns.count
        // iPad 在 turn 结束后才恢复连接时，会错过实时 turn/completed，但分页历史已经能看到
        // 对应 turn 的终态。这里用最新一页的权威 turn 结果补回完成事件，避免消息已显示完成，
        // runtime 仍保留陈旧 activeTurnID，进而让后续输入永久卡在本地队列。
        let recoveredTerminalTurn = cursor == nil
            ? recoverCompletedActiveTurnFromLatestTurnsPage(
                sessionID: sessionID,
                turns: chronologicalTurns,
                recoveringInterruptedTurnID: recoveringInterruptedTurnID
            )
            : nil
        thread["turns"] = .array(chronologicalTurns.map { .object($0) })
        let messages = historyMessages(
            fromTurns: chronologicalTurns,
            sessionID: sessionID,
            threadCreatedAt: firstDate(in: thread, keys: ["createdAt", "created_at"]),
            threadUpdatedAt: firstDate(in: thread, keys: ["updatedAt", "updated_at"]),
            threadIsActive: isActiveHistoryThread(thread),
            snapshotReadAt: Date()
        )
        let context = contextForHistoryThread(thread, sessionID: sessionID, projects: projects)
        if let recoveredTerminalTurn {
            emit(.turnCompleted(
                metadata(threadID: sessionID, turnID: recoveredTerminalTurn.turnID)
                    .withTurnLifecycle(recoveredTerminalTurn.lifecycle)
            ))
            finishTurnInterruptRecoveryIfMatching(
                sessionID: sessionID,
                turnID: recoveredTerminalTurn.turnID
            )
        }
        let upstreamNextCursor = firstString(in: object, keys: ["nextCursor", "next_cursor"])
        let nextCursor = reachedInheritedBoundary ? nil : upstreamNextCursor
        let itemContinuations = loadMode == .full
            ? chronologicalTurns.enumerated().compactMap { turnIndex, turn -> HistoryTurnItemsContinuation? in
                guard let turnID = turn["id"]?.stringValue, !turnID.isEmpty else {
                    return nil
                }
                var turnShell = turn
                turnShell.removeValue(forKey: "items")
                return HistoryTurnItemsContinuation(
                    turnID: turnID,
                    turn: turnShell,
                    turnIndex: turnIndex,
                    itemOffset: 0,
                    cursor: nil,
                    pageLimit: Self.historyItemPageLimit,
                    threadIsActive: isActiveHistoryThread(thread),
                    isLatestTurn: cursor == nil && turnIndex == chronologicalTurns.index(before: chronologicalTurns.endIndex),
                    hasVisibleUserMessageBefore: false
                )
            }
            : []
        return HistoryMessagesPage(
            messages: messages,
            previousCursor: nextCursor.map(Self.encodeThreadTurnsCursor),
            hasMoreBefore: nextCursor != nil,
            context: context,
            loadMode: loadMode,
            notice: Self.historyNotice(loadMode: loadMode, hasMoreBefore: nextCursor != nil, turns: chronologicalTurns),
            authoritativeCompletedTurnItems: [:],
            itemContinuations: itemContinuations,
            latestForkableTurnID: Self.latestForkableTurnID(fromTurns: chronologicalTurns)
        )
    }

    func historyTurnItemsPage(
        sessionID: SessionID,
        continuation: HistoryTurnItemsContinuation
    ) async throws -> HistoryTurnItemsPage {
        let config = try await ensureConfig()
        guard config.policy.allowedMethods.contains("thread/items/list") else {
            throw CodexAppServerSessionRuntimeError.paginatedHistoryUnavailable("thread/items/list")
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: config.projects)
        let result = try await sendRecoveringFromStaleInitialization(
            builder.threadItemsList(
                threadID: sessionID,
                turnID: continuation.turnID,
                cursor: continuation.cursor,
                limit: max(1, min(250, continuation.pageLimit)),
                sortDirection: "asc"
            ),
            timeout: longRunningRequestTimeout
        )
        let page = result?.objectValue ?? [:]
        let items = page["data"]?.arrayValue?
            .compactMap(\.objectValue)
            .filter { entry in
                entry["turnId"]?.stringValue == nil || entry["turnId"]?.stringValue == continuation.turnID
            }
            .compactMap { $0["item"]?.objectValue } ?? []
        let messages = historyMessages(
            fromItems: items,
            continuation: continuation,
            sessionID: sessionID,
            snapshotReadAt: Date()
        )
        let itemIDs = Set(items.compactMap { item -> AgentItemID? in
            guard let itemID = item["id"]?.stringValue, !itemID.isEmpty else {
                return nil
            }
            return itemID
        })
        let upstreamNextCursor = firstString(in: page, keys: ["nextCursor", "next_cursor"])
        if let upstreamNextCursor, upstreamNextCursor == continuation.cursor {
            // 重复 cursor 不是分页完成。若把它当成 nil，Store 会把不完整 Item 集合
            // 误标成权威快照，并删除仍未拉到的消息。
            throw AgentAPIError.invalidResponse
        }
        return HistoryTurnItemsPage(
            messages: messages,
            itemIDs: itemIDs,
            continuation: upstreamNextCursor.map {
                continuation.continuing(
                    cursor: $0,
                    loadedItemCount: items.count,
                    hasVisibleUserMessage: continuation.hasVisibleUserMessageBefore
                        || messages.contains { $0.role == "user" }
                )
            }
        )
    }

    func recoverCompletedActiveTurnFromLatestTurnsPage(
        sessionID: SessionID,
        turns: [[String: CodexAppServerJSONValue]],
        recoveringInterruptedTurnID: TurnID? = nil
    ) -> (turnID: TurnID, lifecycle: ConversationTurnLifecycle)? {
        let context = contextsBySessionID[sessionID]
        guard let activeTurnID = recoveringInterruptedTurnID ?? context?.activeTurnID,
              context?.activeTurnID == nil || context?.activeTurnID == activeTurnID,
              let activeTurnIndex = turns.lastIndex(where: { $0["id"]?.stringValue == activeTurnID })
        else {
            return nil
        }
        let activeTurn = turns[activeTurnIndex]
        let hasTerminalStatus = isTerminalHistoryStatus(activeTurn["status"])
        let hasCompletionTimestamp = firstDate(in: activeTurn, keys: ["completedAt", "completed_at"]) != nil
        guard hasTerminalStatus || hasCompletionTimestamp else {
            return nil
        }

        // 如果分页里已经出现更新但尚未确认终态的 turn，旧 turn 的完成不能把当前执行误判为空闲。
        let laterTurns = turns.index(after: activeTurnIndex)..<turns.endIndex
        guard !laterTurns.contains(where: { index in
            let turn = turns[index]
            return !isTerminalHistoryStatus(turn["status"])
                && firstDate(in: turn, keys: ["completedAt", "completed_at"]) == nil
        }) else {
            return nil
        }

        if var context, context.activeTurnID == activeTurnID {
            context.activeTurnID = nil
            context.session.activeTurnID = nil
            context.session.status = SessionStatus.history.rawValue
            context.session.pendingApproval = nil
            context.session.pendingUserInput = nil
            contextsBySessionID[sessionID] = context
        }
        return (
            activeTurnID,
            historyTurnLifecycle(
                activeTurn,
                isInProgress: false,
                completedAt: firstDate(in: activeTurn, keys: ["completedAt", "completed_at"])
            )
        )
    }

    func threadMetadataForHistoryPage(
        sessionID: SessionID,
        builder: CodexAppServerRequestBuilder,
        projects: [AgentProject],
        shouldRefresh: Bool
    ) async throws -> [String: CodexAppServerJSONValue]? {
        if !shouldRefresh {
            return nil
        }
        let result = try await sendRecoveringFromStaleInitialization(
            builder.threadRead(threadID: sessionID, includeTurns: false),
            timeout: longRunningRequestTimeout
        )
        guard let thread = threadObject(from: result) else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        if let session = try? agentSession(from: thread, projects: projects, fallbackProject: nil) {
            contextsBySessionID[sessionID] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
        }
        return thread
    }

    func contextForHistoryThread(
        _ thread: [String: CodexAppServerJSONValue],
        sessionID: SessionID,
        projects: [AgentProject]
    ) -> SessionContextSnapshot? {
        if let session = try? agentSession(from: thread, projects: projects, fallbackProject: nil) {
            contextsBySessionID[sessionID] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
            return session.context
        }
        return contextsBySessionID[sessionID]?.session.context
    }

    /// Codex 子 Agent 的 Thread 会带上 spawn/fork 时继承的父 Turn，供模型建立上下文。
    /// 这段前缀不属于子 Agent 自己的执行历史；只有 child 身份和创建时间都明确时才裁剪。
    /// 已确认 child 后，无 startedAt 的 synthetic rollout 无法证明归 child 所有，按隔离优先丢弃；
    /// 普通 fork、身份/创建时间缺失仍 fail-open，同秒创建的第一个真实 child Turn 继续保留。
    func childOwnedHistoryTurns(
        in thread: [String: CodexAppServerJSONValue],
        turns: [[String: CodexAppServerJSONValue]]
    ) -> [[String: CodexAppServerJSONValue]] {
        let hasParentThread = nonEmpty(
            thread["parentThreadId"]?.stringValue,
            thread["parent_thread_id"]?.stringValue
        ) != nil

        guard hasParentThread || hasSubagentSource(in: thread),
              let threadCreatedAt = firstDate(in: thread, keys: ["createdAt", "created_at"])
        else {
            return turns
        }

        return turns.filter { turn in
            guard let turnStartedAt = firstDate(in: turn, keys: ["startedAt", "started_at"]) else {
                return false
            }
            return turnStartedAt >= threadCreatedAt
        }
    }

    func historyThreadShell(
        sessionID: SessionID,
        projects: [AgentProject]
    ) -> [String: CodexAppServerJSONValue] {
        if let cached = contextsBySessionID[sessionID]?.session {
            return [
                "id": .string(cached.id),
                "sessionId": .string(cached.id),
                "cwd": .string(cached.dir),
                "name": .string(cached.title),
                "preview": cached.preview.map { .string($0) } ?? .null,
                "status": .object(["type": .string(cached.isRunning ? "active" : "notLoaded")]),
                "modelProvider": .string("openai"),
                "createdAt": cached.createdAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                "updatedAt": cached.updatedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                // prepareRelatedSession 会先 thread/read，再走 turns/list；缓存壳层必须保留
                // parent 与 source-only subAgent 身份，否则分页历史会因缺 metadata 而错误 fail-open。
                "parentThreadId": cached.parentThreadID.map { .string($0) } ?? .null,
                "threadSource": cached.isSubagentThread ? .string("subagent") : .null
            ]
        }
        let project = projects.first
        let cwd: CodexAppServerJSONValue
        if let path = project?.path {
            cwd = .string(path)
        } else {
            cwd = .null
        }
        return [
            "id": .string(sessionID),
            "sessionId": .string(sessionID),
            "cwd": cwd,
            // 这层壳只是拿不到 thread 元数据时的占位；名字留空由投影统一填占位标题，
            // 不要把 thread id 当成会话名写进去。
            "name": .null,
            "status": .object(["type": .string("notLoaded")]),
            "modelProvider": .string("openai")
        ]
    }

    func threadListPageWithIndexedFallback(
        cwd: String,
        cursor: String?,
        limit: Int?,
        builder: CodexAppServerRequestBuilder,
        projects: [AgentProject],
        fallbackProject: AgentProject,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        let canUseIndexedList = consistency == .fastIndexed
            && cursor == nil
            && !stateDBOnlyListUnavailable
            && !stateDBOnlyScanRequiredCWDs.contains(cwd)
        let sortKey = preferredThreadListSortKey
        do {
            let result = try await sendRecoveringFromStaleInitialization(
                try builder.threadList(
                    cwd: cwd,
                    limit: limit,
                    cursor: cursor,
                    useStateDBOnly: canUseIndexedList,
                    sortKey: sortKey,
                    refreshHistory: Self.shouldRefreshHistory(
                        runtimeProvider: runtimeProvider,
                        consistency: consistency,
                        cursor: cursor
                    )
                ),
                timeout: longRunningRequestTimeout
            )
            let page = threadListPage(from: result, projects: projects, fallbackProject: fallbackProject)
            guard canUseIndexedList, indexedThreadListNeedsRepair(page, cwd: cwd) else {
                return page
            }
            // 状态库漏掉本连接已知 thread 时，本连接后续固定走普通扫描，避免每轮都先错一次再回退。
            stateDBOnlyScanRequiredCWDs.insert(cwd)
            return try await ordinaryThreadListPage(
                cwd: cwd,
                cursor: cursor,
                limit: limit,
                builder: builder,
                projects: projects,
                fallbackProject: fallbackProject
            )
        } catch {
            if sortKey == "recency_at", shouldFallbackFromRecencySort(error) {
                // 旧 agentd/Codex 不认识 recency_at 时，本连接只探测一次，之后稳定退回 updated_at。
                recencySortUnavailable = true
                return try await threadListPageWithIndexedFallback(
                    cwd: cwd,
                    cursor: cursor,
                    limit: limit,
                    builder: builder,
                    projects: projects,
                    fallbackProject: fallbackProject,
                    consistency: consistency
                )
            }
            guard canUseIndexedList, shouldFallbackFromStateDBOnlyList(error) else {
                throw error
            }
            stateDBOnlyListUnavailable = true
            return try await ordinaryThreadListPage(
                cwd: cwd,
                cursor: cursor,
                limit: limit,
                builder: builder,
                projects: projects,
                fallbackProject: fallbackProject
            )
        }
    }

    func ordinaryThreadListPage(
        cwd: String,
        cursor: String?,
        limit: Int?,
        builder: CodexAppServerRequestBuilder,
        projects: [AgentProject],
        fallbackProject: AgentProject
    ) async throws -> SessionsPage {
        let result = try await sendRecoveringFromStaleInitialization(
            try builder.threadList(
                cwd: cwd,
                limit: limit,
                cursor: cursor,
                useStateDBOnly: false,
                sortKey: preferredThreadListSortKey
            ),
            timeout: longRunningRequestTimeout
        )
        return threadListPage(from: result, projects: projects, fallbackProject: fallbackProject)
    }

    /// Claude 的目录扫描只能由用户主动发起的权威首屏触发；其余请求保持索引/分页语义，
    /// 避免翻页或兼容性回退把全量 JSONL 扫描变成无界后台工作。
    static func shouldRefreshHistory(
        runtimeProvider: String,
        consistency: SessionListConsistency,
        cursor: String?
    ) -> Bool {
        normalizedRuntimeProvider(runtimeProvider) == "claude"
            && consistency == .authoritative
            && cursor == nil
    }

    func indexedThreadListNeedsRepair(_ page: SessionsPage, cwd: String) -> Bool {
        let knownSessions = contextsBySessionID.values.compactMap { context in
            context.cwd == cwd ? context.session : nil
        }
        guard !knownSessions.isEmpty else {
            return false
        }
        let pageIDs = Set(page.sessions.map(\.id))
        let missing = knownSessions.filter { !pageIDs.contains($0.id) }
        guard !missing.isEmpty else {
            return false
        }
        guard page.hasMore, let tail = page.sessions.last else {
            return true
        }
        let tailDate = SessionIndexStore.orderingDate(for: tail)
        // 满页时只修复“按最近活动本应位于本页”的缺口；更老的已知会话留在后续分页，避免无谓扫描。
        return missing.contains { known in
            let knownDate = SessionIndexStore.orderingDate(for: known)
            return knownDate > tailDate || (knownDate == tailDate && known.id > tail.id)
        }
    }

    var preferredThreadListSortKey: String {
        runtimeProvider == "codex" && !recencySortUnavailable ? "recency_at" : "updated_at"
    }

    func shouldFallbackFromRecencySort(_ error: Error) -> Bool {
        guard case CodexAppServerConnectionError.appServer(let appError) = error else {
            return false
        }
        let message = appError.message.lowercased()
        return appError.code == -32601
            || message.contains("recency_at")
            || message.contains("sortkey") && (message.contains("unsupported") || message.contains("not supported"))
            || message.contains("sortkey") && message.contains("不支持")
    }

    func shouldFallbackFromStateDBOnlyList(_ error: Error) -> Bool {
        guard case CodexAppServerConnectionError.appServer(let appError) = error else {
            return false
        }
        let message = appError.message.lowercased()
        return appError.code == -32601
            || message.contains("usestatedbonly")
            || message.contains("unknown field")
            || message.contains("unsupported")
            || message.contains("not supported")
    }

    func shouldFallbackFromThreadTurnsList(_ error: Error) -> Bool {
        guard case CodexAppServerConnectionError.appServer(let appError) = error else {
            return false
        }
        let message = appError.message.lowercased()
        return appError.code == -32601
            || message.contains("unsupported")
            || message.contains("not supported")
            || message.contains("method not found")
            || message.contains("method 不允许")
            || message.contains("experimentalapi")
    }

    // full 首屏默认 10 turn；SessionStore 在 history_response_too_large 后按此上限向下
    // 逐级缩页（10→5→2→1，见 SessionStore.fullHistoryTurnPageLadder）。两处必须保持一致。
    static let fullHistoryTurnPageLadderTop = 10

    static func threadTurnPageLimit(forMessageLimit limit: Int?, loadMode: HistoryMessagesPage.LoadMode) -> Int {
        let requestedMessages = max(1, limit ?? 120)
        switch loadMode {
        case .economy:
            // 核心逻辑：一条 turn 可能包含 base64 图片或超长工具输出。
            // 控制 turn 页大小，比降低 WebSocket message size 更温和，不会制造重连风暴。
            return max(5, min(20, (requestedMessages + 3) / 4))
        case .full:
            // 自适应缩页：SessionStore 缩页时直接传入目标 turn 数（均 ≤ 首屏 10），
            // 这些小 limit 按精确 turn 数请求，便于命中 gateway full cap 以下；默认首屏
            // (limit=20) 与翻页(limit=20) 等较大 message limit 仍走原有 message→turn 折算，
            // 结果 10 turn，既是首屏也是 ladder 顶端。
            if requestedMessages <= fullHistoryTurnPageLadderTop {
                return max(1, requestedMessages)
            }
            // full 手动加载仍要服从 Go gateway 的硬上限，避免弱网下大响应被 50 limit 拒绝。
            return max(10, min(50, (requestedMessages + 1) / 2))
        }
    }

    static func authoritativeCompletedTurnItems(
        fromTurns turns: [[String: CodexAppServerJSONValue]]
    ) -> [TurnID: Set<AgentItemID>] {
        var result: [TurnID: Set<AgentItemID>] = [:]
        for turn in turns {
            guard turn["status"]?.stringValue == "completed",
                  turn["itemsView"]?.stringValue == "full" || turn["items_view"]?.stringValue == "full",
                  let turnID = turn["id"]?.stringValue else {
                continue
            }
            let itemIDs = Set(
                turn["items"]?.arrayValue?
                    .compactMap(\.objectValue)
                    .compactMap { $0["id"]?.stringValue }
                    .filter { !$0.isEmpty } ?? []
            )
            result[turnID] = itemIDs
        }
        return result
    }

    static func latestForkableTurnID(
        fromTurns turns: [[String: CodexAppServerJSONValue]]
    ) -> TurnID? {
        let terminalStatuses: Set<String> = ["completed", "interrupted", "failed"]
        return turns.reversed().lazy.compactMap { turn -> TurnID? in
            let rawStatus = turn["status"]?.stringValue
                ?? turn["status"]?.objectValue?["type"]?.stringValue
                ?? turn["status"]?.objectValue?["status"]?.stringValue
            guard let status = rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  terminalStatuses.contains(status),
                  let turnID = turn["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !turnID.isEmpty else {
                return nil
            }
            return turnID
        }.first
    }

    static func historyNotice(
        loadMode: HistoryMessagesPage.LoadMode,
        hasMoreBefore: Bool,
        turns: [[String: CodexAppServerJSONValue]]
    ) -> String? {
        guard loadMode == .economy else {
            return nil
        }
        // 后端 summary 视图表示 item 详情可按需再拉；没有显式字段时，大历史分页也按省流提示处理。
        let hasLazyContentSignal = turns.contains { turn in
            turn["itemsView"]?.stringValue == "summary"
                || turn["items_view"]?.stringValue == "summary"
                || turn["hasFullItems"]?.boolValue == false
                || turn["has_full_items"]?.boolValue == false
        }
        guard hasMoreBefore || hasLazyContentSignal || !turns.isEmpty else {
            return nil
        }
        return economyHistoryNotice
    }

    static func encodeThreadTurnsCursor(_ cursor: String) -> String {
        threadTurnsCursorPrefix + Data(cursor.utf8).base64EncodedString()
    }

    static func decodeThreadTurnsCursor(_ cursor: String?) -> String? {
        guard let cursor,
              cursor.hasPrefix(threadTurnsCursorPrefix)
        else {
            return nil
        }
        let encoded = String(cursor.dropFirst(threadTurnsCursorPrefix.count))
        guard let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func attachEvents(
        sessionID: SessionID,
        replayPolicy: CodexAppServerBufferedEventReplayPolicy = .all
    ) -> CodexAppServerEventStream {
        // 这里承接的是已经投影好的 thread 事件；正常连接完整保序交付，切回会话的 backlog
        // 可降级为状态级回放，避免历史输出在消息区重新直播一遍。每个订阅者使用独立合并邮箱：
        // 主线程渲染变慢时连续 delta 会收敛为少量完整 chunk，控制事件仍严格无损有序。
        let token = UUID()
        let mailbox = CodexAppServerEventMailbox { [weak self] in
            Task {
                await self?.detachEvents(sessionID: sessionID, token: token)
            }
        }
        let isFirstSubscriber = eventMailboxesBySessionID[sessionID]?.isEmpty != false
        eventMailboxesBySessionID[sessionID, default: [:]][token] = mailbox
        // backlog 只能被第一个订阅者消费一次；之后同 thread 的可见页面与后台队列
        // 都从实时扇出接收事件，避免两个 SessionWebSocketClient 互相顶掉订阅者。
        var replayedInteractionIDs: Set<String> = []
        if isFirstSubscriber {
            for event in bufferedEvents(sessionID: sessionID, replayPolicy: replayPolicy) {
                if let interactionID = pendingInteractionReplayID(for: event) {
                    replayedInteractionIDs.insert(interactionID)
                }
                mailbox.send(event)
            }
        }
        // server request 本身不在 thread/list/read 里，页面切换或进后台时又可能已经从
        // runtime 收到、但还没投影到新页面。新订阅者必须直接补放 runtime 内存里仍挂起的
        // 审批/补充信息请求，否则侧边栏只会显示“待输入”，详情却没有可操作卡片。
        for event in pendingInteractionEvents(sessionID: sessionID) {
            guard let interactionID = pendingInteractionReplayID(for: event),
                  replayedInteractionIDs.insert(interactionID).inserted else {
                continue
            }
            mailbox.send(event)
        }
        return CodexAppServerEventStream(mailbox: mailbox)
    }

    func bufferedEvents(
        sessionID: SessionID,
        replayPolicy: CodexAppServerBufferedEventReplayPolicy
    ) -> [AgentEvent] {
        let events = bufferedEventsBySessionID.removeValue(forKey: sessionID) ?? []
        switch replayPolicy {
        case .all:
            return events
        case .stateOnly:
            // 切回运行会话前已经用 thread/read 快照补齐消息区；旧 delta 和日志不再逐条补播。
            // 但审批、补充信息、turn 完成和会话状态仍要回放，避免丢掉当前可操作状态。
            return events.filter(shouldReplayBufferedStateEvent)
        }
    }

    nonisolated func shouldReplayBufferedStateEvent(_ event: AgentEvent) -> Bool {
        switch event {
        case .session,
             .sessionRow,
             .sessionStatus,
             .sessionContext,
             .permissionProfileUpdated,
             .goalUpdated,
             .goalCleared,
             .turnStarted,
             .approvalRequest,
             .approvalResolved,
             .userInputRequest,
             .userInputResolved,
             .turnCompleted,
             .warning,
             .error,
             .unknown:
            return true
        case .messageCompleted:
            // thread/read 快照不含 commandExecution 等过程 item；completed 内容事件必须补播，
            // 否则离开期间完成的命令卡会永久丢失。排序与去重由 ConversationStore 兜底。
            return true
        case .processItemCompleted(let message, _, _):
            // item/started 复用该事件类型以便当前页面立即看到运行态；stateOnly 恢复已经先加载
            // thread/read 权威快照，不能让旧 started 再把已完成命令覆盖回 inProgress。
            return message.activityPayload?.isInProgress != true
        case .assistantDelta,
             .logDelta,
             .diffUpdated:
            return false
        }
    }

    func pendingInteractionEvents(sessionID: SessionID) -> [AgentEvent] {
        var seenApprovalRequestIDs: Set<CodexAppServerRequestID> = []
        let approvalEvents = pendingApprovalRequestsByID.values.compactMap { request -> AgentEvent? in
            guard approvalSessionID(for: request) == sessionID,
                  seenApprovalRequestIDs.insert(request.id).inserted else {
                return nil
            }
            return projector.project(request)
        }
        var seenUserInputRequestIDs: Set<CodexAppServerRequestID> = []
        let userInputEvents = pendingUserInputRequestsByID.values.compactMap { request -> AgentEvent? in
            guard approvalSessionID(for: request) == sessionID,
                  seenUserInputRequestIDs.insert(request.id).inserted else {
                return nil
            }
            return projector.project(request)
        }
        return approvalEvents + userInputEvents
    }

    nonisolated func pendingInteractionReplayID(for event: AgentEvent) -> String? {
        switch event {
        case .approvalRequest(let request, _):
            return "approval:\(request.id)"
        case .userInputRequest(let request, _):
            return "user-input:\(request.id)"
        default:
            return nil
        }
    }

    func connectForEvents(sessionID: SessionID) async throws {
        // 必须在第一次 suspension 前登记订阅意图。若页面离开期间 unsubscribe 安装了
        // 更新一代 false lease，旧 connect 恢复后只能退出，不能重新覆盖成 true。
        let lease = replaceThreadSubscriptionLease(sessionID: sessionID, wantsEvents: true)
        if contextsBySessionID[sessionID] == nil {
            _ = try await session(id: sessionID, afterSeq: nil)
        }
        guard threadSubscriptionLeaseBySessionID[sessionID] == lease else {
            return
        }
        guard let context = contextsBySessionID[sessionID] else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        let connection = try await ensureConnection()
        guard threadSubscriptionLeaseBySessionID[sessionID] == lease else {
            return
        }
        let config = try await ensureConfig()
        guard shouldResumeThreadForEventSubscription(context.session, config: config) else {
            // 普通 WS 模式打开空闲历史时只读取 state DB / rollout。SSH 共享模式会在这里
            // resume，以服务端真实结果决定当前入口是否拥有 writer。
            return
        }
        let projects = try await projects()
        guard threadSubscriptionLeaseBySessionID[sessionID] == lease else {
            return
        }
        let builder = CodexAppServerRequestBuilder(
            allowlistedProjects: projectsIncludingSessionContext(projects, context: context)
        )
        if needsPendingInteractionRecovery(for: context.session) {
            // App 进后台时只取消页面事件泵，底层 gateway 连接可能仍存活，所以这个
            // thread 仍被记为已 resume。若列表已是等待态、runtime 却没有对应 server request，
            // 说明请求落在了 iOS 挂起/切会话窗口；清掉本地绑定标记，强制 thread/resume 让
            // app-server 重放未处理请求。
            threadsResumedOnConnection.remove(sessionID)
        }
        guard threadSubscriptionLeaseBySessionID[sessionID] == lease else {
            return
        }
        // 运行中的 thread 需要 resume 建立 live listener；thread/read/list 只能做 hydration。
        try await ensureThreadResumedOnConnection(sessionID: sessionID, cwd: context.cwd, builder: builder, connection: connection)
        // 目标状态是增强信息，不应该卡住实时事件连接。旧 app-server 可能不支持 thread/goal/get，
        // 慢链路也可能延迟响应；后台刷新即可，连接状态先进入 connected。
        Task {
            await refreshThreadGoalIfAvailable(sessionID: sessionID, builder: builder, connection: connection)
        }
    }

    func needsPendingInteractionRecovery(for session: AgentSession) -> Bool {
        switch session.status {
        case SessionStatus.waitingForApproval.rawValue:
            return !pendingApprovalRequestsByID.values.contains {
                approvalSessionID(for: $0) == session.id
            }
        case SessionStatus.waitingForInput.rawValue:
            return !pendingUserInputRequestsByID.values.contains {
                approvalSessionID(for: $0) == session.id
            }
        default:
            return false
        }
    }

    func shouldResumeThreadForEventSubscription(
        _ session: AgentSession,
        config: CodexAppServerConfigResponse
    ) -> Bool {
        guard runtimeProvider == "codex" else {
            return true
        }
        // 共享 SSH 的多个入口必须在打开时就得到同一份 writer 结论。普通 WS 仍保持
        // 空闲历史只读，避免仅浏览历史就提前取得 writer。
        let transport = config.runtime.transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return transport == "ssh" || session.isRunning
    }

    func replaceThreadSubscriptionLease(
        sessionID: SessionID,
        wantsEvents: Bool
    ) -> CodexAppServerThreadSubscriptionLease {
        let generation = (threadSubscriptionLeaseBySessionID[sessionID]?.generation ?? 0) &+ 1
        let lease = CodexAppServerThreadSubscriptionLease(
            generation: generation,
            wantsEvents: wantsEvents
        )
        threadSubscriptionLeaseBySessionID[sessionID] = lease
        return lease
    }

    func reassertThreadSubscriptionIfNeeded(
        sessionID: SessionID,
        supersededLease: CodexAppServerThreadSubscriptionLease
    ) async throws {
        guard let desiredLease = threadSubscriptionLeaseBySessionID[sessionID],
              desiredLease.generation != supersededLease.generation,
              desiredLease.wantsEvents,
              let context = contextsBySessionID[sessionID]
        else {
            return
        }
        let config = try await ensureConfig()
        guard shouldResumeThreadForEventSubscription(context.session, config: config) else {
            // 普通 WS 的空闲历史没有服务端订阅需要恢复。旧 unsubscribe 的迟到 ACK
            // 不能把一次纯读取重新升级成 thread/resume；SSH 共享模式不走这里。
            return
        }
        let connection = try await ensureConnection()
        let builder = CodexAppServerRequestBuilder(
            allowlistedProjects: projectsIncludingSessionContext(
                try await projects(),
                context: context
            )
        )
        guard threadSubscriptionLeaseBySessionID[sessionID] == desiredLease else {
            return
        }
        // 新订阅可能已经完成；旧 unsubscribe 的响应仍晚于它，所以必须从本地标记中
        // 移除后再 resume 一次。若新 resume 仍在执行，先等待 single-flight 收口。
        if let pendingResume = threadResumeTasksBySessionID[sessionID],
           pendingResume.connection === connection {
            _ = try? await pendingResume.task.value
        }
        guard threadSubscriptionLeaseBySessionID[sessionID] == desiredLease else {
            return
        }
        threadsResumedOnConnection.remove(sessionID)
        try await ensureThreadResumedOnConnection(
            sessionID: sessionID,
            cwd: context.cwd,
            builder: builder,
            connection: connection
        )
    }

    @discardableResult
    func startTurn(sessionID: SessionID, prompt: String, clientMessageID: ClientMessageID?) async throws -> TurnID? {
        try await startTurn(
            sessionID: sessionID,
            payload: CodexAppServerTurnPayload(prompt: prompt),
            clientMessageID: clientMessageID
        )
    }

    @discardableResult
    func startTurn(sessionID: SessionID, payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) async throws -> TurnID? {
        try await startTurnOutcome(
            sessionID: sessionID,
            payload: payload,
            clientMessageID: clientMessageID
        ).activeTurnID
    }

    func startTurnOutcome(
        sessionID: SessionID,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID?
    ) async throws -> CodexAppServerTurnStartOutcome {
        guard !payload.isEmpty else {
            return .active(turnID: nil)
        }
        let previous = turnStartTasksBySessionID[sessionID]?.task
        let token = UUID()
        let task = Task { [self] in
            if let previous {
                _ = try? await previous.value
            }
            return try await performStartTurn(sessionID: sessionID, payload: payload, clientMessageID: clientMessageID)
        }
        turnStartTasksBySessionID[sessionID] = (token, task)
        do {
            let turnID = try await task.value
            clearTurnStartTask(sessionID: sessionID, token: token)
            return turnID
        } catch {
            clearTurnStartTask(sessionID: sessionID, token: token)
            throw error
        }
    }

    @discardableResult
    func performStartTurn(
        sessionID: SessionID,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID?
    ) async throws -> CodexAppServerTurnStartOutcome {
        guard let context = contextsBySessionID[sessionID] else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        if let activeTurnID = context.activeTurnID {
            throw CodexAppServerSessionRuntimeError.activeTurnConflict(
                session: context.session,
                activeTurnID: activeTurnID
            )
        }
        sessionsStartingTurn.insert(sessionID)
        defer {
            sessionsStartingTurn.remove(sessionID)
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projectsIncludingSessionContext(try await projects(), context: context))
        let result: CodexAppServerJSONValue?
        var responseObservation: CodexAppServerPendingTurnStartObservation?
        var didRetryAfterStaleInitialization = false
        while true {
            try Task.checkCancellation()
            let connection = try await ensureConnection()
            var activeAttemptID: UUID?
            do {
                try await ensureThreadResumedOnConnection(
                    sessionID: sessionID,
                    cwd: context.cwd,
                    builder: builder,
                    connection: connection
                )
                try Task.checkCancellation()
                if let activeTurnID = contextsBySessionID[sessionID]?.activeTurnID {
                    let session = contextsBySessionID[sessionID]?.session ?? context.session
                    throw CodexAppServerSessionRuntimeError.activeTurnConflict(
                        session: session,
                        activeTurnID: activeTurnID
                    )
                }
                let attemptID = beginPendingTurnStartObservation(sessionID: sessionID)
                activeAttemptID = attemptID
                // turn/start 不能在同一个 helper 里裸重发：旧 frame 可能已经与 executing
                // handoff 重叠，下一次必须先重新 thread/resume，再创建新的 turn/start observation。
                result = try await connection.send(try builder.turnStart(
                        threadID: sessionID,
                        cwd: context.cwd,
                        payload: payload,
                        clientMessageID: clientMessageID
                    ), timeout: longRunningRequestTimeout)
                responseObservation = takePendingTurnStartObservation(
                    sessionID: sessionID,
                    attemptID: attemptID
                )
                break
            } catch {
                if let activeAttemptID {
                    _ = takePendingTurnStartObservation(
                        sessionID: sessionID,
                        attemptID: activeAttemptID
                    )
                }
                if !didRetryAfterStaleInitialization,
                   await recoverConnectionAfterStaleInitialization(connection, error: error) {
                    didRetryAfterStaleInitialization = true
                    continue
                }
                if let activeTurnID = Self.activeTurnIDFromConflict(error) {
                    let session = withUpdatedSession(sessionID) { item in
                        item.status = "running"
                        item.activeTurnID = activeTurnID
                    } ?? context.session
                    throw CodexAppServerSessionRuntimeError.activeTurnConflict(
                        session: session,
                        activeTurnID: activeTurnID
                    )
                }
                await refreshRateLimitAfterQuotaError(error)
                await retireCurrentConnectionAfterRecoverableError(connection, error: error)
                throw error
            }
        }
        let responseTurn = result?["turn"]?.objectValue
        let turnID = responseTurn?["id"]?.stringValue
        if let turnID {
            turnsStartedByThisRuntime.insert(turnID)
        }
        guard let latestContext = contextsBySessionID[sessionID] else {
            return .threadClosed(turnID: turnID)
        }
        let currentActiveTurnID = latestContext.activeTurnID
        if responseObservation?.threadClosed == true
            || latestContext.session.status == "closed" {
            return .threadClosed(turnID: turnID)
        }
        if let currentActiveTurnID,
           turnID == nil || currentActiveTurnID != turnID {
            // ACK 等待期间已经出现更新 turn；旧 ACK 只完成原消息的发送对账。
            return .superseded(turnID: turnID, activeTurnID: currentActiveTurnID)
        }
        let terminalFromNotification = responseObservation.map {
            turnStartObservationMatchesTerminal($0, turnID: turnID)
        } ?? false
        let terminalFromResponse = responseTurnIsTerminal(responseTurn)
        if terminalFromNotification || terminalFromResponse {
            if currentActiveTurnID == nil || currentActiveTurnID == turnID {
                _ = withUpdatedSession(sessionID) { item in
                    item.activeTurnID = nil
                }
            }
            let knownTerminalWasAlreadyProjected = turnID.map {
                responseObservation?.terminalTurnIDs.contains($0) == true
            } ?? false
            if !knownTerminalWasAlreadyProjected {
                let lifecycle = responseTurn.map {
                    historyTurnLifecycle(
                        $0,
                        isInProgress: false,
                        completedAt: firstDate(in: $0, keys: ["completedAt", "completed_at"])
                    )
                } ?? .completed
                // ACK 自身已终态或旧协议 completion 无 ID 时，补一条可精确关联的完成事件，
                // 让消息状态与 FIFO 都能收敛，不依赖手动刷新。
                emit(
                    .turnCompleted(
                        metadata(threadID: sessionID, turnID: turnID)
                            .withTurnLifecycle(lifecycle)
                    )
                )
            }
            return .terminal(turnID: turnID)
        }
        _ = withUpdatedSession(sessionID) { item in
            item.status = "running"
            item.activeTurnID = turnID
        }
        if responseObservation?.sawUnidentifiedTerminal == true,
           let turnID {
            // 无 ID completion 可能是连接重放，不能据此宣告本次 turn 已完成。
            // 先保留 ACK 的 active 状态，再以权威 turns 页有界确认真实终态。
            scheduleTurnInterruptRecovery(sessionID: sessionID, turnID: turnID)
        }
        return .active(turnID: turnID)
    }

    func beginPendingTurnStartObservation(sessionID: SessionID) -> UUID {
        let attemptID = UUID()
        pendingTurnStartObservationsBySessionID[sessionID] = CodexAppServerPendingTurnStartObservation(
            attemptID: attemptID
        )
        return attemptID
    }

    func takePendingTurnStartObservation(
        sessionID: SessionID,
        attemptID: UUID
    ) -> CodexAppServerPendingTurnStartObservation? {
        guard let observation = pendingTurnStartObservationsBySessionID[sessionID],
              observation.attemptID == attemptID else {
            return nil
        }
        pendingTurnStartObservationsBySessionID.removeValue(forKey: sessionID)
        return observation
    }

    nonisolated static func activeTurnIDFromConflict(_ error: Error) -> TurnID? {
        guard case CodexAppServerConnectionError.appServer(let appError) = error,
              let data = appError.data?.objectValue,
              data["accepted"]?.boolValue == false,
              data["reason"]?.stringValue == "active_turn",
              let activeTurnID = data["activeTurnId"]?.stringValue,
              !activeTurnID.isEmpty else {
            return nil
        }
        return activeTurnID
    }

    func steerTurn(
        sessionID: SessionID,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID?,
        expectedTurnID: TurnID
    ) async throws {
        guard !payload.isEmpty else {
            return
        }
        guard let context = contextsBySessionID[sessionID] else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        guard context.activeTurnID == expectedTurnID else {
            throw CodexAppServerSessionRuntimeError.missingActiveTurn(sessionID)
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projectsIncludingSessionContext(try await projects(), context: context))
        var didRetryAfterStaleInitialization = false
        while true {
            let connection = try await ensureConnection()
            do {
                try await ensureThreadResumedOnConnection(sessionID: sessionID, cwd: context.cwd, builder: builder, connection: connection)
                _ = try await connection.send(try builder.turnSteer(
                    threadID: sessionID,
                    cwd: context.cwd,
                    payload: payload,
                    clientMessageID: clientMessageID,
                    expectedTurnID: expectedTurnID
                ), timeout: longRunningRequestTimeout)
                return
            } catch {
                if !didRetryAfterStaleInitialization,
                   await recoverConnectionAfterStaleInitialization(connection, error: error) {
                    didRetryAfterStaleInitialization = true
                    continue
                }
                await refreshRateLimitAfterQuotaError(error)
                await retireCurrentConnectionAfterRecoverableError(connection, error: error)
                throw error
            }
        }
    }

    func clearTurnStartTask(sessionID: SessionID, token: UUID) {
        guard turnStartTasksBySessionID[sessionID]?.token == token else {
            return
        }
        turnStartTasksBySessionID.removeValue(forKey: sessionID)
    }

    // thread/start、thread/resume 的 options 必须按本 runtime 的通道策略先降级再发送：
    // Claude 通道不接受 dangerFullAccess，.default 草稿直接上桥会被 gateway 拒绝，
    // 会话恢复就会陷入确定性失败的重连循环。runtime 连接的 gateway 由自身 runtimeProvider
    // 决定，所以这里强制以 actor 的 runtime 为准，而不是相信 payload 里的残留值。
    func runtimeScopedThreadOptions(_ options: CodexAppServerTurnOptions) -> CodexAppServerTurnOptions {
        var scoped = options
        scoped.runtimeProvider = runtimeProvider
        return scoped.sanitizedForRuntimePolicy()
    }

    // 直连发送路径下，thread 可能只在 thread/list 或 thread/start 里出现过，但没有在当前 gateway
    // 连接上执行过 thread/resume。真实 app-server 只有 resume 后才稳定建立 live listener；
    // 否则 turn/start 虽然被接受，iPad 也可能收不到 turn/started、delta 和 completed，界面就会一直等待。
    func ensureThreadResumedOnConnection(
        sessionID: SessionID,
        cwd: String,
        builder: CodexAppServerRequestBuilder,
        connection: CodexAppServerConnection
    ) async throws {
        guard !threadsResumedOnConnection.contains(sessionID) else {
            return
        }
        if let existing = threadResumeTasksBySessionID[sessionID] {
            if existing.connection === connection {
                return try await existing.task.value
            }
            // 理论上连接替换路径会统一清理；这里再做代次防线，避免旧任务迟到后把新连接误标为已 resume。
            existing.task.cancel()
            threadResumeTasksBySessionID.removeValue(forKey: sessionID)
        }

        let token = UUID()
        let task = Task { [self] in
            try await performThreadResume(
                sessionID: sessionID,
                cwd: cwd,
                builder: builder,
                connection: connection
            )
        }
        threadResumeTasksBySessionID[sessionID] = CodexAppServerThreadResumeTask(
            connection: connection,
            token: token,
            task: task
        )
        do {
            try await task.value
            clearThreadResumeTask(sessionID: sessionID, connection: connection, token: token)
        } catch {
            clearThreadResumeTask(sessionID: sessionID, connection: connection, token: token)
            throw error
        }
    }

    func performThreadResume(
        sessionID: SessionID,
        cwd: String,
        builder: CodexAppServerRequestBuilder,
        connection: CodexAppServerConnection
    ) async throws {
        let usesSharedServerQueue = try await turnDeliveryMode() == .sharedServerQueue
        var passiveResumeOptions = CodexAppServerTurnOptions.default
        // 被动监听/重连不能把 Mimi 的安全默认重新写进已有 Codex Thread；否则 Windows
        // managed permission profiles 会把原来的 :danger-full-access 静默改成 :workspace。
        passiveResumeOptions.preservesThreadPermissionSettings = runtimeProvider == "codex"
        let scopedPassiveResumeOptions = runtimeScopedThreadOptions(passiveResumeOptions)
        let result: CodexAppServerJSONValue?
        do {
            let request = usesSharedServerQueue
                ? try builder.threadResumePreservingSharedState(
                    threadID: sessionID,
                    cwd: cwd
                )
                : try builder.threadResume(
                    threadID: sessionID,
                    cwd: cwd,
                    options: scopedPassiveResumeOptions
                )
            result = try await connection.send(request, timeout: longRunningRequestTimeout)
        } catch {
            if shouldFallbackFromInitialTurnsPage(error) {
                let request = usesSharedServerQueue
                    ? try builder.threadResumePreservingSharedState(
                        threadID: sessionID,
                        cwd: cwd,
                        includeInitialTurnsPage: false
                    )
                    : try builder.threadResume(
                        threadID: sessionID,
                        cwd: cwd,
                        options: scopedPassiveResumeOptions,
                        includeInitialTurnsPage: false
                    )
                result = try await connection.send(request, timeout: longRunningRequestTimeout)
            } else if isNoRolloutFoundError(error) {
                // 刚 thread/start、还没跑过任何 turn 的新线程在上游没有 rollout 文件，thread/resume 会返回
                // -32600 "no rollout found"。这类线程已经在本连接上被 thread/start 绑定，resume 只是冗余；
                // 标记为已 resume 并放行，等首个 turn/start 落盘 rollout 后事件自然回流。否则空会话开屏即
                // 因 connectForEvents 抛错进入“WebSocket 断开，正在自动重连”的死循环。
                try Task.checkCancellation()
                threadsResumedOnConnection.insert(sessionID)
                return
            } else {
                throw error
            }
        }
        if let thread = threadObject(from: result),
           let session = try? agentSession(
            from: thread,
            projects: (try? projectsFromCache()) ?? [],
            fallbackProject: nil
           ) {
            emitActivePermissionProfile(from: result, threadID: session.id)
            let recoveredTerminalTurn = storeAuthoritativeTurnsSnapshot(session, thread: thread)
            emit(.session(session))
            if let recoveredTerminalTurn {
                // 断线可能发生在最终 item/completed 与 turn/completed 之间。resume 返回的 turns
                // 是当前连接的权威快照；确认旧 active turn 已进入终态后，补回完成事件，让上层
                // 清理陈旧 activeTurnID 并继续发送本地排队消息。
                emit(.turnCompleted(
                    metadata(threadID: session.id, turnID: recoveredTerminalTurn.turnID)
                        .withTurnLifecycle(recoveredTerminalTurn.lifecycle)
                ))
            }
        }
        try Task.checkCancellation()
        threadsResumedOnConnection.insert(sessionID)
    }

    func emitActivePermissionProfile(from result: CodexAppServerJSONValue?, threadID: SessionID) {
        guard let object = result?.objectValue else {
            return
        }
        let source: [String: CodexAppServerJSONValue]
        if object.keys.contains("activePermissionProfile") {
            source = object
        } else if let thread = object["thread"]?.objectValue,
                  thread.keys.contains("activePermissionProfile") {
            source = thread
        } else {
            return
        }
        emit(.permissionProfileUpdated(
            CodexAppServerActivePermissionProfile(value: source["activePermissionProfile"]),
            metadata(threadID: threadID, turnID: nil)
        ))
    }

    func clearThreadResumeTask(
        sessionID: SessionID,
        connection: CodexAppServerConnection,
        token: UUID
    ) {
        guard let current = threadResumeTasksBySessionID[sessionID],
              current.connection === connection,
              current.token == token else {
            return
        }
        threadResumeTasksBySessionID.removeValue(forKey: sessionID)
    }

    func cancelThreadResumeTask(sessionID: SessionID) {
        guard let current = threadResumeTasksBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        current.task.cancel()
    }

    func cancelThreadResumeTasks(for connection: CodexAppServerConnection) {
        let sessionIDs = threadResumeTasksBySessionID.compactMap { entry in
            entry.value.connection === connection ? entry.key : nil
        }
        for sessionID in sessionIDs {
            cancelThreadResumeTask(sessionID: sessionID)
        }
    }

    func storeAuthoritativeTurnsSnapshot(
        _ session: AgentSession,
        thread: [String: CodexAppServerJSONValue],
        recoveringInterruptedTurnID: TurnID? = nil
    ) -> (turnID: TurnID, lifecycle: ConversationTurnLifecycle)? {
        let previouslyActiveTurnID = recoveringInterruptedTurnID
            ?? contextsBySessionID[session.id]?.activeTurnID
        let recoveredTerminalTurn = completedTurnConfirmedByAuthoritativeSnapshot(
            thread,
            previouslyActiveTurnID: previouslyActiveTurnID,
            currentActiveTurnID: session.activeTurnID
        )
        contextsBySessionID[session.id] = CodexAppServerSessionContext(
            session: session,
            cwd: session.dir,
            activeTurnID: session.activeTurnID
        )
        return recoveredTerminalTurn
    }

    func completedTurnConfirmedByAuthoritativeSnapshot(
        _ thread: [String: CodexAppServerJSONValue],
        previouslyActiveTurnID: TurnID?,
        currentActiveTurnID: TurnID?
    ) -> (turnID: TurnID, lifecycle: ConversationTurnLifecycle)? {
        guard currentActiveTurnID == nil,
              let previouslyActiveTurnID,
              let turns = thread["turns"]?.arrayValue?.compactMap(\.objectValue),
              let previousTurn = turns.last(where: { $0["id"]?.stringValue == previouslyActiveTurnID })
        else {
            return nil
        }
        let hasTerminalStatus = isTerminalHistoryStatus(previousTurn["status"])
        let hasCompletionTimestamp = firstDate(in: previousTurn, keys: ["completedAt", "completed_at"]) != nil
        guard hasTerminalStatus || hasCompletionTimestamp else {
            return nil
        }
        return (
            previouslyActiveTurnID,
            historyTurnLifecycle(
                previousTurn,
                isInProgress: false,
                completedAt: firstDate(in: previousTurn, keys: ["completedAt", "completed_at"])
            )
        )
    }

    func shouldFallbackFromInitialTurnsPage(_ error: Error) -> Bool {
        guard case CodexAppServerConnectionError.appServer(let appError) = error else {
            return false
        }
        let message = appError.message.lowercased()
        let reason = appError.data?.objectValue?["reason"]?.stringValue?.lowercased()
        return reason == "history_response_too_large"
            || message.contains("initialturnspage")
            || message.contains("unknown field")
            || message.contains("unsupported")
            || message.contains("not supported")
    }

    func refreshThreadGoalIfAvailable(
        sessionID: SessionID,
        builder: CodexAppServerRequestBuilder,
        connection: CodexAppServerConnection
    ) async {
        do {
            let result = try await connection.send(builder.threadGoalGet(threadID: sessionID))
            guard let goal = threadGoal(from: result) else {
                clearThreadGoalLocal(threadID: sessionID)
                emit(.goalCleared(metadata(threadID: sessionID, turnID: nil)))
                return
            }
            applyThreadGoal(goal)
            emit(.goalUpdated(goal, metadata(threadID: goal.threadID, turnID: nil)))
        } catch {
            // 目标能力在旧 app-server 上可能不可用；监听会话本身不应因此失败。
        }
    }

    func interruptActiveTurn(
        sessionID: SessionID,
        expectedTurnID: TurnID? = nil
    ) async throws {
        let cachedTurnID = contextsBySessionID[sessionID]?.activeTurnID
        if let expectedTurnID,
           let cachedTurnID,
           cachedTurnID != expectedTurnID,
           let session = contextsBySessionID[sessionID]?.session {
            // Store 与 runtime 已观察到不同的 active turn 时，宁可拒绝旧控制命令，
            // 也不能误停用户刚开始的新一轮。
            throw CodexAppServerSessionRuntimeError.activeTurnConflict(
                session: session,
                activeTurnID: cachedTurnID
            )
        }
        // SessionStore 是当前 Composer 的交互事实来源。列表/历史刷新可能先把 runtime
        // 的局部缓存清空，但 Store 仍握有用户实际看到的 turn ID；把它作为安全回退，
        // 避免控制命令尚未发出就误报 missingActiveTurn。
        guard let turnID = cachedTurnID ?? expectedTurnID else {
            throw CodexAppServerSessionRuntimeError.missingActiveTurn(sessionID)
        }
        let spec = CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).turnInterrupt(threadID: sessionID, turnID: turnID)
        _ = try await sendRecoveringFromStaleInitialization(spec)
        scheduleTurnInterruptRecovery(sessionID: sessionID, turnID: turnID)
    }

    func scheduleTurnInterruptRecovery(sessionID: SessionID, turnID: TurnID) {
        turnInterruptRecoveryTasksBySessionID.removeValue(forKey: sessionID)?.task.cancel()
        guard !turnInterruptRecoveryDelaysNanoseconds.isEmpty else {
            return
        }
        let token = UUID()
        let delays = turnInterruptRecoveryDelaysNanoseconds
        let task = Task { [weak self] in
            for delay in delays {
                guard !Task.isCancelled else { return }
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        return
                    }
                }
                guard let self,
                      await self.isCurrentTurnInterruptRecovery(
                        sessionID: sessionID,
                        turnID: turnID,
                        token: token
                      ) else {
                    return
                }
                do {
                    // economy 只取最新的 summary turn，足以确认目标 turn 是否进入终态；
                    // 两种历史后端都会复用既有的权威完成恢复逻辑。
                    _ = try await self.messagesPage(
                        sessionID: sessionID,
                        before: nil,
                        limit: 80,
                        loadMode: .economy,
                        recoveringInterruptedTurnID: turnID
                    )
                } catch {
                    // 短暂网络或 app-server 高负载不应把本地 turn 乐观清空；
                    // 保留后续有界重试，最终仍由实时事件或重新连接的 resume 快照收敛。
                }
            }
            await self?.clearTurnInterruptRecovery(sessionID: sessionID, token: token)
        }
        turnInterruptRecoveryTasksBySessionID[sessionID] = CodexAppServerTurnInterruptRecoveryTask(
            turnID: turnID,
            token: token,
            task: task
        )
    }

    func isCurrentTurnInterruptRecovery(
        sessionID: SessionID,
        turnID: TurnID,
        token: UUID
    ) -> Bool {
        guard let current = turnInterruptRecoveryTasksBySessionID[sessionID] else {
            return false
        }
        return current.turnID == turnID && current.token == token
    }

    func finishTurnInterruptRecoveryIfMatching(sessionID: SessionID, turnID: TurnID) {
        guard let current = turnInterruptRecoveryTasksBySessionID[sessionID],
              current.turnID == turnID else {
            return
        }
        turnInterruptRecoveryTasksBySessionID.removeValue(forKey: sessionID)
        current.task.cancel()
    }

    func clearTurnInterruptRecovery(sessionID: SessionID, token: UUID) {
        guard let current = turnInterruptRecoveryTasksBySessionID[sessionID],
              current.token == token else {
            return
        }
        turnInterruptRecoveryTasksBySessionID.removeValue(forKey: sessionID)
    }

    func cancelAllTurnInterruptRecoveryTasks() {
        let tasks = turnInterruptRecoveryTasksBySessionID.values.map(\.task)
        turnInterruptRecoveryTasksBySessionID.removeAll(keepingCapacity: false)
        tasks.forEach { $0.cancel() }
    }

    func respondToApproval(sessionID: SessionID? = nil, approvalID: String, decision: String) async throws {
        let lookupKeys = pendingApprovalLookupKeys(sessionID: sessionID, approvalID: approvalID)
        guard let request = lookupKeys.compactMap({ pendingApprovalRequestsByID[$0] }).first else {
            throw CodexAppServerSessionRuntimeError.approvalNotFound(approvalID)
        }
        let normalized = normalizeApprovalDecision(decision)
        let result = approvalResponse(method: request.method, params: request.params?.objectValue ?? [:], decision: normalized)
        try await ensureConnection().respond(to: request, result: result)
    }

    func respondToUserInput(sessionID: SessionID? = nil, requestID: String, answers: [String: [String]]) async throws {
        let lookupKeys = pendingUserInputLookupKeys(sessionID: sessionID, requestID: requestID)
        guard let request = lookupKeys.compactMap({ pendingUserInputRequestsByID[$0] }).first else {
            throw CodexAppServerSessionRuntimeError.userInputRequestNotFound(requestID)
        }
        try await ensureConnection().respond(to: request, result: userInputResponse(for: request, answers: answers))
    }

    /// Stable per-install name for this client's resumable gateway session.
    ///
    /// One gateway connection carries every thread of a runtime — the URL's
    /// `thread_id` is empty on the real connection — so the resident bridge
    /// session it maps to is keyed to the app install, not to a thread. It
    /// has to survive app restarts, because that is the case the resident
    /// bridge exists for: close the app mid-task, come back an hour later,
    /// and reattach to the session that kept running.
    /// Minting is serialized: two connections coming up together must not each
    /// generate a key and race to persist it, or one of them would connect
    /// under a name that is not the one stored — and silently fail to find its
    /// session on the next launch.
    private static let gatewaySessionKeyLock = NSLock()

    static func gatewaySessionKey(defaults: UserDefaults = .standard) -> String {
        let storageKey = "appServer.gatewaySessionKey"
        gatewaySessionKeyLock.lock()
        defer { gatewaySessionKeyLock.unlock() }
        if let stored = defaults.string(forKey: storageKey), !stored.isEmpty {
            return stored
        }
        let minted = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defaults.set(minted, forKey: storageKey)
        return minted
    }

    static func gatewayURL(
        endpoint: String,
        sessionID: SessionID,
        runtimeProvider: String = "codex",
        defaults: UserDefaults = .standard
    ) throws -> URL {
        // WebSocket 也必须复用 HTTP Endpoint 策略；ATS 不会替应用阻止自行构造的公网 ws:// 地址。
        let validatedEndpoint = try EndpointTransportPolicy.validatedEndpoint(endpoint)
        guard var components = URLComponents(string: validatedEndpoint) else {
            throw AgentAPIError.invalidEndpoint
        }
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            throw AgentAPIError.invalidEndpoint
        }
        components.path = "/api/app-server/ws"
        var queryItems = [URLQueryItem(name: "thread_id", value: sessionID)]
        let runtime = normalizedRuntimeProvider(runtimeProvider)
        if runtime != "codex" {
            queryItems.append(URLQueryItem(name: "runtime", value: runtime))
        }
        // 命名这条连接对应的常驻会话。不带它，网关只能按连接给一个隔离会话，
        // 断线重连拿不回还在跑的 turn 和未应答的审批。
        let gatewaySession = "\(gatewaySessionKey(defaults: defaults))-\(runtime)"
        queryItems.append(URLQueryItem(name: "session", value: gatewaySession))
        // Go 写 WebSocket 成功不等于 App 已经投影完该帧。由客户端带回最后
        // 处理完成的 turn 边界，bridge 才能从真正安全的 cursor 继续回放。
        if runtime == "claude", let lastSeen = gatewayLastSeenSequence(
            endpoint: validatedEndpoint,
            gatewaySession: gatewaySession,
            runtimeProvider: runtime,
            defaults: defaults
        ) {
            queryItems.append(URLQueryItem(name: "last_seen", value: String(lastSeen)))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw AgentAPIError.invalidEndpoint
        }
        return url
    }

    static func normalizedRuntimeProvider(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch value {
        case "", "codex", "openai", "codex_app_server", "codex-app-server":
            return "codex"
        case "claude", "anthropic", "claude_code", "claude-code", "claude_code_bridge", "claude-code-bridge":
            return "claude"
        default:
            return value
        }
    }

    private static func gatewayLastSeenStorageKey(
        endpoint: String,
        gatewaySession: String,
        runtimeProvider: String
    ) -> String {
        // endpoint 可能含 UserDefaults key 不友好的字符；base64 只作为稳定命名，不承载密钥。
        let endpointKey = Data(AgentAPIClient.normalizedEndpoint(endpoint).utf8).base64EncodedString()
        return "appServer.gatewayLastSeen.v2.\(normalizedRuntimeProvider(runtimeProvider)).\(gatewaySession).\(endpointKey)"
    }

    static func gatewayLastSeenSequence(
        endpoint: String,
        gatewaySession: String,
        runtimeProvider: String,
        defaults: UserDefaults = .standard
    ) -> UInt64? {
        let key = gatewayLastSeenStorageKey(
            endpoint: endpoint,
            gatewaySession: gatewaySession,
            runtimeProvider: runtimeProvider
        )
        guard let raw = defaults.string(forKey: key) else {
            return nil
        }
        return UInt64(raw)
    }

    static func storeGatewayLastSeenSequence(
        _ sequence: UInt64,
        endpoint: String,
        gatewaySession: String,
        runtimeProvider: String,
        defaults: UserDefaults = .standard
    ) {
        let key = gatewayLastSeenStorageKey(
            endpoint: endpoint,
            gatewaySession: gatewaySession,
            runtimeProvider: runtimeProvider
        )
        let current = defaults.string(forKey: key).flatMap(UInt64.init) ?? 0
        guard sequence > current else { return }
        defaults.set(String(sequence), forKey: key)
    }

    static func resetGatewayLastSeenSequence(
        _ sequence: UInt64,
        endpoint: String,
        gatewaySession: String,
        runtimeProvider: String,
        defaults: UserDefaults = .standard
    ) {
        let key = gatewayLastSeenStorageKey(
            endpoint: endpoint,
            gatewaySession: gatewaySession,
            runtimeProvider: runtimeProvider
        )
        // bridge 进程重启后 sequence 会从头计数，必须允许显式倒退；普通确认仍走
        // storeGatewayLastSeenSequence 的单调写入，避免迟到任务误覆盖新 cursor。
        defaults.set(String(sequence), forKey: key)
    }

    func detachEvents(sessionID: SessionID, token: UUID) {
        eventMailboxesBySessionID[sessionID]?.removeValue(forKey: token)
        if eventMailboxesBySessionID[sessionID]?.isEmpty == true {
            eventMailboxesBySessionID.removeValue(forKey: sessionID)
        }
    }

    func ensureConfig(forceRefresh: Bool = false) async throws -> CodexAppServerConfigResponse {
        if let config, !forceRefresh {
            return config
        }
        let next = try await configProvider()
        config = next
        return next
    }

    func ensureConnection() async throws -> CodexAppServerConnection {
        if let connection {
            if await connection.isReadyForRequests() {
                return connection
            }
            await retireConnection(connection)
        }
        if let connectionAttempt {
            return try await installPreparedConnectionIfNeeded(from: connectionAttempt)
        }
        let config = try await connectionConfig()
        guard runtimeGatewayAvailable(in: config) else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        let gatewayURL = try gatewayURL(from: config)
        let next = CodexAppServerConnection(transport: transportFactory(), requestTimeout: requestTimeout)
        let task = Task { [next, gatewayURL, token] in
            let notifications = await next.notifications()
            let serverRequests = await next.serverRequests()
            try await next.connect(url: gatewayURL, token: token)
            return CodexAppServerPreparedConnection(
                connection: next,
                notifications: notifications,
                serverRequests: serverRequests
            )
        }
        let attempt = CodexAppServerConnectionAttempt(
            id: UUID(),
            connection: next,
            task: task
        )
        connectionAttempt = attempt
        return try await installPreparedConnectionIfNeeded(from: attempt)
    }

    func installPreparedConnectionIfNeeded(
        from attempt: CodexAppServerConnectionAttempt
    ) async throws -> CodexAppServerConnection {
        try await withTaskCancellationHandler {
            let prepared: CodexAppServerPreparedConnection
            do {
                prepared = try await attempt.task.value
                try Task.checkCancellation()
            } catch {
                await cancelConnectionAttempt(id: attempt.id)
                throw error
            }

            // 相同 single-flight 可能有多个等待者；只有仍持有租约的第一个等待者可以安装连接。
            // 旧尝试即使迟到成功，也只能复用已经安装的新连接或立即释放，不能覆盖当前代次。
            guard connectionAttempt?.id == attempt.id else {
                if let connection, await connection.isReadyForRequests() {
                    return connection
                }
                await prepared.connection.disconnect()
                throw CancellationError()
            }
            connectionAttempt = nil
            if let connection, await connection.isReadyForRequests() {
                if connection !== prepared.connection {
                    await prepared.connection.disconnect()
                }
                return connection
            }
            try Task.checkCancellation()
            installConnection(prepared)
            return prepared.connection
        } onCancel: {
            // Task.value 不会把等待者的取消自动传给非结构化 Task。转回 runtime actor 后按租约
            // 同时取消连接任务和 candidate，disconnect 会恢复 initialize 的挂起 continuation。
            Task {
                await self.cancelConnectionAttempt(id: attempt.id)
            }
        }
    }

    func cancelConnectionAttempt(id: UUID? = nil) async {
        guard let attempt = connectionAttempt,
              id == nil || attempt.id == id else {
            return
        }
        connectionAttempt = nil
        attempt.task.cancel()
        await attempt.connection.disconnect()
    }

    func connectionConfig() async throws -> CodexAppServerConfigResponse {
        let cached = try await ensureConfig()
        if runtimeGatewayAvailable(in: cached) {
            return cached
        }
        // 首次冷启动时 agentd 可能先返回项目列表，但 app-server gateway 仍在启动。
        // 这种不可用 config 不能长期缓存，否则 bootstrap 重试会一直复用旧状态，直到用户杀掉 APP。
        let fresh = try await ensureConfig(forceRefresh: true)
        if runtimeGatewayAvailable(in: fresh) {
            return fresh
        }
        throw CodexAppServerSessionRuntimeError.gatewayUnavailable
    }

    func installConnection(_ prepared: CodexAppServerPreparedConnection) {
        notificationPumpTask?.cancel()
        serverRequestPumpTask?.cancel()
        cancelAllTurnInterruptRecoveryTasks()
        threadResumeTasksBySessionID.values.forEach { $0.task.cancel() }
        threadResumeTasksBySessionID.removeAll(keepingCapacity: true)
        // 新连接还没在 app-server 上 resume 任何 thread，清空记录，逼迫下一次发送先补 resume。
        threadsResumedOnConnection.removeAll(keepingCapacity: true)
        connection = prepared.connection
        notificationPumpTask = Task { [weak self, notifications = prepared.notifications, installedConnection = prepared.connection] in
            for await notification in notifications {
                await self?.handle(notification)
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.handleNotificationStreamEnded(for: installedConnection)
        }
        serverRequestPumpTask = Task { [weak self, serverRequests = prepared.serverRequests] in
            for await request in serverRequests {
                await self?.handle(request)
            }
        }
    }

    func handleNotificationStreamEnded(for endedConnection: CodexAppServerConnection) async {
        guard let current = connection, current === endedConnection else {
            return
        }

        // 底层 receive 失败会结束 notification stream。这里必须继续结束上层 AgentEvent stream，
        // 否则 SessionWebSocketClient 的 for-await 永远不退出，UI 会一直误认为连接仍是 connected。
        notificationPumpTask = nil
        serverRequestPumpTask?.cancel()
        serverRequestPumpTask = nil
        cancelThreadResumeTasks(for: endedConnection)
        connection = nil
        threadsResumedOnConnection.removeAll(keepingCapacity: true)
        let affected = clearAllPendingServerRequests()
        for sessionID in affected.approvalSessionIDs {
            emitApprovalResolved(sessionID: sessionID)
        }
        for sessionID in affected.userInputSessionIDs {
            emitUserInputResolved(sessionID: sessionID, skipped: false)
        }
        finishAttachedEventStreams()
        await endedConnection.disconnect()
    }

    func finishAttachedEventStreams() {
        let mailboxes = eventMailboxesBySessionID.values.flatMap { $0.values }
        eventMailboxesBySessionID.removeAll(keepingCapacity: true)
        for mailbox in mailboxes {
            mailbox.finishFromProducer()
        }
    }

    func sendRecoveringFromStaleInitialization(
        _ request: CodexAppServerRequestSpec,
        timeout: TimeInterval? = nil
    ) async throws -> CodexAppServerJSONValue? {
        let firstConnection = try await ensureConnection()
        do {
            return try await firstConnection.send(request, timeout: timeout)
        } catch {
            if await recoverConnectionAfterStaleInitialization(firstConnection, error: error) {
                let secondConnection = try await ensureConnection()
                do {
                    return try await secondConnection.send(request, timeout: timeout)
                } catch {
                    await retireCurrentConnectionAfterRecoverableError(secondConnection, error: error)
                    throw error
                }
            }
            await retireCurrentConnectionAfterRecoverableError(firstConnection, error: error)
            throw error
        }
    }

    func recoverConnectionAfterStaleInitialization(_ stale: CodexAppServerConnection, error: Error) async -> Bool {
        guard isStaleInitializationError(error) else {
            return false
        }
        if let current = connection, current === stale {
            // app-server upstream 重启或 gateway 旧连接错位时会返回 -32600 Not initialized。
            // 这不是用户请求本身非法，丢弃当前连接并重新 initialize 后重试一次即可自愈。
            await retireConnection(stale)
        } else {
            // 并发发送/重连可能已经把 actor 里的 current connection 清空或替换；
            // stale 请求仍应允许重试一次，但不能误删另一条刚建立好的连接。
            await stale.disconnect()
        }
        return true
    }

    func retireConnection(_ stale: CodexAppServerConnection) async {
        guard let current = connection, current === stale else {
            // actor 在前面的 await 期间可能已经安装了新连接；旧请求只能关闭自己，不能清理新代次。
            await stale.disconnect()
            return
        }
        notificationPumpTask?.cancel()
        notificationPumpTask = nil
        serverRequestPumpTask?.cancel()
        serverRequestPumpTask = nil
        cancelThreadResumeTasks(for: stale)
        connection = nil
        threadsResumedOnConnection.removeAll(keepingCapacity: true)
        let affected = clearAllPendingServerRequests()
        for sessionID in affected.approvalSessionIDs {
            emitApprovalResolved(sessionID: sessionID)
        }
        for sessionID in affected.userInputSessionIDs {
            emitUserInputResolved(sessionID: sessionID, skipped: false)
        }
        // 主动淘汰不可用连接时也要结束上层订阅；否则被取消的 notification pump 不会再走
        // 异常结束 handler，SessionStore 仍可能把这条已失效连接看成 connected。
        finishAttachedEventStreams()
        await stale.disconnect()
    }

    func retireCurrentConnectionAfterRecoverableError(_ stale: CodexAppServerConnection, error: Error) async {
        guard isRecoverableConnectionError(error),
              let current = connection,
              current === stale else {
            return
        }
        // 只有连接级错误才淘汰共享连接；单个 RPC 超时可能只是 app-server 高负载，
        // 此时保留通知流和其他 pending 请求，避免一个慢请求拖断所有会话。
        await retireConnection(stale)
    }

    func isRecoverableConnectionError(_ error: Error) -> Bool {
        guard let error = error as? CodexAppServerConnectionError else {
            return false
        }
        switch error {
        case .disconnected, .notInitialized, .transport:
            return true
        case .appServer(let appServerError):
            return isStaleInitializationAppServerError(appServerError)
        case .timeout, .duplicateRequestID, .decoding:
            return false
        }
    }

    func isStaleInitializationError(_ error: Error) -> Bool {
        guard let error = error as? CodexAppServerConnectionError else {
            return false
        }
        switch error {
        case .notInitialized:
            return true
        case .appServer(let appServerError):
            return isStaleInitializationAppServerError(appServerError)
        default:
            return false
        }
    }

    func isStaleInitializationAppServerError(_ error: CodexAppServerError) -> Bool {
        error.code == -32600
            && error.message.range(of: "not initialized", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // thread/resume 命中“no rollout found for thread id …”：线程已存在于 app-server，但还没有任何 turn
    // 落盘 rollout（新建空会话的典型状态）。不同 app-server 版本回的 code 不一致（实测 -32600，旧 mock 用
    // -32000），所以只认消息、不锁 code，避免漏判。仅用于 thread/resume 这类“绑定监听”路径的良性放行；
    // turn/start 自身回的 no rollout 仍按业务错误向上抛。
    func isNoRolloutFoundError(_ error: Error) -> Bool {
        guard let error = error as? CodexAppServerConnectionError,
              case .appServer(let appServerError) = error else {
            return false
        }
        return appServerError.message.range(of: "no rollout found", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    func hasReadyConnectionForTesting() async -> Bool {
        guard let connection else {
            return false
        }
        return await connection.isReadyForRequests()
    }

    func gatewayURL(from config: CodexAppServerConfigResponse) throws -> URL {
        guard runtimeGatewayAvailable(in: config) else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        // config 只用于确认 gateway 能力；真实 URL 始终从当前连接代次的 endpoint 派生。
        // 这样 REST 与 WebSocket 不会因为反向代理返回了另一 Host 而分裂到不同链路。
        return try Self.gatewayURL(
            endpoint: endpoint,
            sessionID: "",
            runtimeProvider: runtimeProvider,
            defaults: gatewayDefaults
        )
    }

    func runtimeGatewayAvailable(in config: CodexAppServerConfigResponse) -> Bool {
        if runtimeProvider == "codex" {
            return runtimeGatewayChannel(in: config)?.gatewayAvailable ?? config.runtime.gatewayAvailable
        }
        return runtimeGatewayChannel(in: config)?.gatewayAvailable == true
    }

    func runtimeGatewayChannel(in config: CodexAppServerConfigResponse) -> CodexAppServerChannelMetadata? {
        config.channels.first { channel in
            Self.normalizedRuntimeProvider(channel.runtimeID ?? channel.id) == runtimeProvider ||
                Self.normalizedRuntimeProvider(channel.provider) == runtimeProvider
        }
    }

    /// 上游在连接重建或线程卸载时可能发送 thread/closed 或 notLoaded。这里只清理当前
    /// 连接的 resume binding，让下一次发送重新建立监听；不修改会话历史或所有权。
    func invalidateThreadResumeBinding(from notification: CodexAppServerNotification) {
        guard notification.method == "thread/closed"
                || notification.method == "thread/status/changed" else {
            return
        }
        let params = notification.params?.objectValue ?? [:]
        guard let threadID = firstString(in: params, keys: ["threadId", "threadID", "thread_id"]) else {
            return
        }
        if notification.method == "thread/status/changed" {
            let statusType = params["status"]?.objectValue?["type"]?.stringValue
                ?? params["status"]?.stringValue
            guard statusType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "notloaded" else {
                return
            }
        }
        threadsResumedOnConnection.remove(threadID)
    }

    func handle(_ notification: CodexAppServerNotification) {
        if notification.method == "_mimi/serverRequestResponse/rejected" {
            // 另一入口已抢先响应或拒绝时，不复活本地卡片；等待 resolved/terminal 收敛即可。
            return
        }
        if notification.method == "_mimi/claudeReplayCursor/reset",
           runtimeProvider == "claude",
           let rawSequence = notification.params?.objectValue?["sequence"]?.intValue,
           rawSequence >= 0 {
            replayCursorEpoch &+= 1
            let gatewaySession = "\(Self.gatewaySessionKey(defaults: gatewayDefaults))-\(runtimeProvider)"
            Self.resetGatewayLastSeenSequence(
                UInt64(rawSequence),
                endpoint: endpoint,
                gatewaySession: gatewaySession,
                runtimeProvider: runtimeProvider,
                defaults: gatewayDefaults
            )
            return
        }
        updateTerminalInteractionBarrier(from: notification)
        recordLiveSignal(from: notification)
        recordPendingTurnStartBoundary(from: notification)
        invalidateThreadResumeBinding(from: notification)
        if runtimeProvider == "claude",
           notification.method == "turn/completed" {
            let params = notification.params?.objectValue ?? [:]
            if let threadID = params["threadId"]?.stringValue,
               completedTurnID(from: params) == nil {
                // 无 ID completion 无法安全区分旧 turn 与当前新 turn。禁止猜测 activeTurnID，
                // 以最新历史页做精确终态对账；若 ACK 仍挂起，则 ACK 还会补出带 ID 的完成事件。
                if let activeTurnID = contextsBySessionID[threadID]?.activeTurnID {
                    scheduleTurnInterruptRecovery(
                        sessionID: threadID,
                        turnID: activeTurnID
                    )
                }
                if let replaySequence = notification.replaySequence {
                    acknowledgeAppliedReplayBoundary(
                        replaySequence,
                        epoch: replayCursorEpoch
                    )
                }
                return
            }
        }
        updateContext(from: notification)
        let resolved = clearResolvedServerRequest(from: notification)
        if notification.method == "serverRequest/resolved" {
            // resolved 通知本身不区分 approval 和 requestUserInput/MCP form。必须根据本地挂起表
            // 投影对应的 resolved 事件，否则 MCP 表单已回答后补充信息卡仍会留在 UI。
            for sessionID in resolved.approvalSessionIDs {
                emitApprovalResolved(sessionID: sessionID)
            }
            for sessionID in resolved.userInputSessionIDs {
                emitUserInputResolved(sessionID: sessionID, skipped: false)
            }
            return
        }
        if isTerminalInteractionNotification(notification) {
            // terminal 本身会让 Store/Conversation 投影收敛，不再补发 resolved 事件；
            // 否则 resolved 的“恢复为 running”语义会覆盖刚落地的 completed/failed/closed。
            clearPendingServerRequestsForTerminalNotification(notification)
        }
        if notification.method == "serverRequest/replay" {
            redeliverReplayedServerRequests(notification)
            return
        }
        if notification.method == "deprecationNotice",
           approvalSessionID(from: notification.params?.objectValue ?? [:]) == nil {
            // deprecationNotice 是连接级通知，官方协议不带 threadId。直接 emit 会被路由层丢弃，
            // 因此将它投递给当前连接已知会话，让用户真正看到升级提示。
            let params = notification.params?.objectValue ?? [:]
            let summary = params["summary"]?.stringValue ?? L10n.text("ui.app_server_protocol_capability_is_obsolete")
            let details = params["details"]?.stringValue
            let payload = AgentErrorPayload(
                message: [summary, details].compactMap { $0 }.joined(separator: "\n"),
                code: "deprecationNotice",
                retryable: false
            )
            for sessionID in contextsBySessionID.keys {
                emit(.warning(payload, metadata(threadID: sessionID, turnID: nil)))
            }
            return
        }
        guard var event = projector.project(notification) else {
            for sessionID in resolved.approvalSessionIDs {
                emitApprovalResolved(sessionID: sessionID)
            }
            for sessionID in resolved.userInputSessionIDs {
                emitUserInputResolved(sessionID: sessionID, skipped: false)
            }
            return
        }
        if notification.method == "turn/completed" || notification.method == "thread/closed" {
            event = event.withReplayBoundarySequence(
                notification.replaySequence,
                epoch: replayCursorEpoch
            )
        }
        emit(event)
        let emittedSessionID = sessionID(from: event)
        for sessionID in resolved.approvalSessionIDs where sessionID != emittedSessionID {
            emitApprovalResolved(sessionID: sessionID)
        }
        for sessionID in resolved.userInputSessionIDs where sessionID != emittedSessionID {
            emitUserInputResolved(sessionID: sessionID, skipped: false)
        }
    }

    /// 由 MainActor 在 Conversation/Session 投影全部落地后调用。单调提交避免并行订阅
    /// 的迟到完成事件把 cursor 倒退；scope 隔离不同 Mac、安装会话与 runtime。
    func acknowledgeAppliedReplayBoundary(_ sequence: UInt64, epoch: UInt64?) {
        guard runtimeProvider == "claude",
              epoch == replayCursorEpoch else {
            return
        }
        let gatewaySession = "\(Self.gatewaySessionKey(defaults: gatewayDefaults))-\(runtimeProvider)"
        Self.storeGatewayLastSeenSequence(
            sequence,
            endpoint: endpoint,
            gatewaySession: gatewaySession,
            runtimeProvider: runtimeProvider,
            defaults: gatewayDefaults
        )
    }

    func updateTerminalInteractionBarrier(from notification: CodexAppServerNotification) {
        let params = notification.params?.objectValue ?? [:]
        guard let sessionID = approvalSessionID(from: params) else {
            return
        }
        if notification.method == "turn/started" {
            // 新 turn 是 thread 重新进入活动态的明确边界；无 turnId 的新 MCP 请求可以继续显示。
            terminalSessionBarriers.removeValue(forKey: sessionID)
            return
        }
        guard isTerminalInteractionNotification(notification) else {
            return
        }
        let now = Date()
        terminalSessionBarriers[sessionID] = now
        if let turnID = firstString(in: params, keys: ["turnId", "turnID", "turn_id"])
            ?? params["turn"]?.objectValue?["id"]?.stringValue {
            terminalTurnTombstonesByKey[terminalTurnTombstoneKey(sessionID: sessionID, turnID: turnID)] = now
        }
        pruneInteractionTombstones()
    }

    func handle(_ request: CodexAppServerServerRequest) {
        if isResolvedServerRequestTombstoned(request) {
            return
        }
        if isUnsupportedMCPElicitation(request) {
            return
        }
        if isTerminallyStaleServerRequest(request) {
            return
        }
        if isUserInputServerRequest(request) {
            guard let event = projector.project(request) else { return }
            rememberPendingUserInputRequest(request)
            emit(event)
            return
        }
        if isStaleReplayedApproval(request) {
            return
        }
        guard let event = projector.project(request) else {
            return
        }
        rememberPendingApprovalRequest(request)
        emit(event)
    }

    /// Re-deliver the server requests a reconnect found still waiting.
    ///
    /// A bridge whose sessions outlive the connection keeps an approval
    /// prompt pending across a disconnect — that is the whole point of it —
    /// and lists the survivors in one notification as soon as we attach.
    /// Each entry goes back through the live path, so a restored prompt is
    /// bookkept and rendered exactly like the original was.
    ///
    /// `isStaleReplayedApproval` is deliberately not consulted here. That
    /// check exists for app-servers that re-deliver zombie approvals from
    /// turns they have long since moved past; this list is the bridge's own
    /// not-yet-answered table, emptied the moment a request resolves or its
    /// turn dies, so everything in it is live by construction. Running the
    /// check would decline the very prompts the user came back to answer,
    /// because a thread parked on an approval still reports itself as idle.
    func redeliverReplayedServerRequests(_ notification: CodexAppServerNotification) {
        for entry in notification.params?["outstanding"]?.arrayValue ?? [] {
            guard let method = entry["method"]?.stringValue,
                  let id = replayedServerRequestID(entry["id"]) else {
                continue
            }
            let request = CodexAppServerServerRequest(id: id, method: method, params: entry["params"])
            if isResolvedServerRequestTombstoned(request) {
                continue
            }
            if isUnsupportedMCPElicitation(request) || isTerminallyStaleServerRequest(request) {
                continue
            }
            if isUserInputServerRequest(request) {
                guard let event = projector.project(request) else { continue }
                rememberPendingUserInputRequest(request)
                emit(event)
                continue
            }
            if isStaleReplayedApproval(request) {
                continue
            }
            guard let event = projector.project(request) else {
                continue
            }
            rememberPendingApprovalRequest(request)
            emit(event)
        }
    }

    /// The id travels back to the bridge verbatim when the user answers, so
    /// keep its JSON type instead of coercing everything to a string.
    func replayedServerRequestID(_ value: CodexAppServerJSONValue?) -> CodexAppServerRequestID? {
        switch value {
        case .string(let text):
            return .string(text)
        case .int(let number):
            return .int(number)
        default:
            return nil
        }
    }

    func handleUserInputRequest(_ request: CodexAppServerServerRequest) {
        // requestUserInput 是上游明确要求用户作答的协议事件。无论普通、Plan
        // 还是 Goal turn，都必须先展示；只有用户点击“跳过”才允许回空 answers。
        rememberPendingUserInputRequest(request)
        guard let event = projector.project(request) else {
            return
        }
        emit(event)
    }

    func isStaleReplayedApproval(_ request: CodexAppServerServerRequest) -> Bool {
        if request.method == "mcpServer/elicitation/request" {
            // MCP elicitation 可以是与 turn 无关的独立请求，turnId 在官方协议中本来就可为 null。
            // 不能因 thread 当前 idle 就把真实 URL 确认当成过期审批自动拒绝。
            return false
        }
        guard isApprovalLikeServerRequest(request),
              let sessionID = approvalSessionID(for: request),
              let context = contextsBySessionID[sessionID] else {
            // 不认识的 thread 或拿不到本地会话状态时，保守地照常弹卡，避免误杀真实审批。
            return false
        }
        if sessionsStartingTurn.contains(sessionID) {
            // 正在 startTurn 的挂起窗口内：activeTurnID/状态都还没回填，这一刻到达的审批属于刚发起的
            // 新 turn，绝不能当成过期重放。
            return false
        }
        let requestTurnID = approvalTurnID(for: request)
        if let requestTurnID, turnsStartedByThisRuntime.contains(requestTurnID) {
            // 本端这条 runtime 亲自发起的 turn 的审批一定是 live 的，必须展示（即使已经挂了很久）。
            return false
        }
        // app-server 已切到新的 active turn，但仍重放旧 turn 的审批：本地 active turn 与审批 turnId 不同。
        if let requestTurnID,
           let activeTurnID = context.activeTurnID,
           context.session.status == "waiting_for_approval",
           requestTurnID != activeTurnID {
            return true
        }

        // 正在执行的 turn（无论谁发起）本地状态都会是 running/waiting 且记着 activeTurnID；
        // 只有 app-server 自己把该 thread 报成空闲、且本地没有活跃 turn 时，才判定为过期重放。
        return context.activeTurnID == nil && isInactiveThreadStatus(context.session.status)
    }

    func isInactiveThreadStatus(_ status: String) -> Bool {
        switch status {
        case "running", "waiting_for_approval", "waiting_for_input":
            return false
        default:
            return true
        }
    }
}
