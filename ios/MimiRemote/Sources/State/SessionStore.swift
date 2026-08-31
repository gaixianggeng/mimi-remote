import Foundation
import Network
import UserNotifications

struct MissingRunningSessionState: Equatable {
    let projectID: String
    var consecutiveRefreshMisses: Int
}

struct FileUploadCompletionEvent: Equatable {
    let id = UUID()
    let attachment: UploadedFileAttachment
    let targetScope: ComposerDraftScopeKey
}

struct SessionArchivePreferenceState: Equatable {
    let isPinned: Bool
    let isArchived: Bool
}

struct SessionArchiveMutation: Equatable {
    let token: UInt64
    let hostScope: HostScope
    let before: SessionArchivePreferenceState
    let target: SessionArchivePreferenceState
}

/// `applyEventReducerOutput` 内部的会话工作副本。
///
/// 一个 runtime event 可能同时更新 status、active turn、审批卡和列表预览。
/// 这些更新必须按既有分组顺序彼此可见，但不能让每一步都触发整套索引/排序。
/// 这里只复制会话数组；lookup 仍由 Store 增量维护，避免 batch 与 Store 同时持有
/// Dictionary 导致每个 staged mutation 都触发整表 CoW。
final class EventReducerSessionMutationBatch {
    var sessions: [AgentSession]

    init(sessions: [AgentSession]) {
        self.sessions = sessions
    }

    func replace(at index: Int, with session: AgentSession) -> Bool {
        guard sessions.indices.contains(index), sessions[index] != session else {
            return false
        }
        sessions[index] = session
        return true
    }

    func insert(_ session: AgentSession) {
        // 与 SessionStore.upsert 保持一致：新会话放在数组头部。
        sessions.insert(session, at: 0)
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published var projects: [AgentProject] = [] {
        didSet {
            rebuildProjectIndex()
        }
    }
    @Published var recentWorkspaces: [AgentWorkspace] = [] {
        didSet {
            rebuildWorkspaceIndex()
        }
    }
    @Published var sidebarProjects: [AgentProject] = [] {
        didSet {
            rebuildProjectSessionListSnapshots()
        }
    }
    // 某个工作区的目录被删除、或 Mac 端 scan_roots 改动后掉出 allowlist 时记入这里：
    // 侧栏单独标记该行不可用，避免把“某个 recent 失效”冒泡成整页的全局错误。
    @Published var unavailableWorkspaceIDs: Set<String> = []
    @Published var sessions: [AgentSession] = [] {
        didSet {
            rebuildSessionIndexes()
            synchronizeCarStatusSnapshot()
        }
    }
    @Published var remoteSessionSearchResults: [AgentSession] = [] {
        didSet {
            rebuildProjectSessionListSnapshots()
            synchronizeCarStatusSnapshot()
        }
    }
    @Published var sessionSearchNextCursor: String?
    @Published var sessionSearchHasMore = false
    // 首屏搜索覆盖 300ms 防抖和实际请求；与分页 loading 分离，避免“继续搜索”误占空态。
    @Published var isSearchingRemoteSessionResults = false
    @Published var isLoadingMoreSessionSearchResults = false
    @Published var pinnedSessionIDs: Set<SessionID> = []
    @Published var archivedSessionIDs: Set<SessionID> = []
    /// UI 只通过 `isSessionArchiveMutationPending` 查询当前 Profile；这里保留完整作用域，
    /// 避免两台 Mac 上碰巧相同的 Session ID 互相禁用操作。
    @Published private(set) var pendingSessionArchiveMutationKeys: Set<ScopedSessionID> = []
    @Published private(set) var unreadHistorySessionIDs: Set<SessionID> = []
    /// 真实观察到 running → terminal 的本地时间，独立于已读水位，供侧边栏展示短时完成结果。
    @Published private(set) var historyCompletionObservedAtBySessionID: [SessionID: Date] = [:]
    @Published var sessionWorkspaceIDs: Set<String>? = nil
    @Published var sessionRemindersByID: [SessionID: SessionReminder] = [:]
    @Published var selectedProjectID: String?
    @Published var selectedSessionID: String?
    /// 路由只监听明确的导航提交，不再把后台数据更新等同于“打开会话”。
    @Published var lastSelectionCommit: SessionSelectionCommit?
    /// 系统搜索框是否处于激活态（聚焦/展开），与 `isSessionSearchActive` 不同：
    /// 后者按查询是否非空判定，聚焦但没输入时仍是 false，盖不住"键盘已弹出"这一段。
    /// iPad 紧凑布局的设备入口是画在 TabView 上的浮层，不归导航栏管，搜索激活时
    /// 系统会收起 Tab 胶囊和顶栏按钮，浮层却留在原地被搜索框压住，所以需要这个信号。
    @Published var isSessionSearchPresented = false

    @Published var sessionSearchQuery = "" {
        didSet {
            guard oldValue != sessionSearchQuery else {
                return
            }
            rebuildProjectSessionListSnapshots()
            scheduleRemoteSessionSearch()
        }
    }
    @Published var expandedProjectIDs: Set<String> = []
    @Published var showingAllSessionProjectIDs: Set<String> = []
    @Published var isLoading = false
    @Published var webSocketStatus: WebSocketStatus = .disconnected
    @Published var connectionTermination: ConnectionTerminationStatus? {
        didSet {
            guard oldValue != connectionTermination else { return }
            synchronizeCarStatusSnapshot()
        }
    }
    @Published var networkReachabilityStatus: NetworkReachabilityStatus = .unknown {
        didSet {
            guard oldValue != networkReachabilityStatus else { return }
            synchronizeCarStatusSnapshot()
        }
    }
    /// 最近一次真正收到当前 Host API 成功响应的时间。仅有 iPad 网络路径并不能证明
    /// 目标 Mac、Tailscale 或 agentd 可达，因此 Widget 的在线判断必须同时依赖这份证据。
    var carStatusLastSuccessfulHostObservationAt: Date?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var isRefreshingSelectedSession = false
    @Published var isUpdatingThreadGoal = false
    @Published var threadGoalErrorMessage: String?
    @Published var appServerModelOptions: [CodexAppServerModelOption] = []
    @Published var appServerPermissionProfiles: [CodexAppServerPermissionProfileSummary] = []
    @Published var activePermissionProfileBySessionID: [SessionID: CodexAppServerActivePermissionProfile] = [:]
    @Published var isRefreshingPermissionProfiles = false
    @Published var isClaudeRuntimeChannelAvailable = false
    @Published var accountRateLimitsByRuntime: [String: RateLimitSummary] = [:]
    /// 账号维度的累计用量。与活动历史分开保存：服务端可以给出 lifetime 却不给日粒度历史。
    @Published var accountTokenUsage: AccountTokenUsageSnapshot?
    @Published var accountTokenActivity: AccountTokenActivityState = .idle
    /// 只表示活动请求本身在飞。不能把配额刷新并进来，否则配额一刷新就会把
    /// 活动的失败态和空态一起伪装成“正在加载”。
    @Published var isRefreshingAccountTokenActivity = false
    // 使用量刷新跨设置页、个人页和侧栏共享，由 Store 按 runtime 去重。
    // 视图只观察自己的 provider，避免 Claude loading 禁用其他按钮，也避免
    // 页面关闭后由未结构化 Task 回写已销毁的局部 @State。
    @Published var refreshingUsageRuntimeProviders: Set<String> = []
    @Published var isRefreshingAppServerModels = false
    @Published var capabilityList: CapabilityListResponse?
    @Published var isRefreshingCapabilities = false
    @Published var capabilityErrorMessage: String?
    @Published var isCreatingWorktree = false
    @Published var duplicatingSessionIDs: Set<SessionID> = []
    @Published var writerConflictForkAvailabilityByLease: [HostSessionLease: WriterConflictForkAvailability] = [:]
    @Published var writerConflictForkErrorByLease: [HostSessionLease: String] = [:]
    @Published var writerConflictForkPreparationRevision: UInt64 = 0
    @Published var worktreeBranchesByPath: [String: WorktreeBranchListResponse] = [:]
    @Published var worktreeBranchErrorByPath: [String: String] = [:]
    @Published var isRefreshingWorktreeBranches = false
    @Published var managedWorktrees: [WorktreeListItem] = []
    @Published var isRefreshingWorktrees = false
    @Published var isDeletingWorktree = false
    @Published var isPruningWorktrees = false
    @Published var worktreeErrorMessage: String?
    @Published var gitStatusByPath: [String: GitStatusResponse] = [:]
    @Published var gitStatusErrorByPath: [String: String] = [:]
    @Published var workspaceGitSummaryByPath: [String: GitStatusResponse] = [:]
    @Published var workspaceGitSummaryUpdatedAtByPath: [String: Date] = [:]
    @Published var refreshingWorkspaceGitSummaryPaths: Set<String> = []
    @Published var isRefreshingGitStatus = false
    @Published var gitActionErrorByPath: [String: String] = [:]
    @Published var commandActionsByPath: [String: [AgentCommandAction]] = [:]
    @Published var commandActionErrorByPath: [String: String] = [:]
    @Published var commandActionResultByPath: [String: CommandActionRunResponse] = [:]
    @Published var commandActionHistoryByPath: [String: [CommandActionRunResponse]] = [:]
    @Published var isRefreshingCommandActions = false
    @Published var queuedCommandActionIDsByPath: [String: [String]] = [:]
    @Published var runningCommandActionPath: String?
    @Published var runningCommandActionID: String?
    @Published var isRunningGitAction = false
    @Published var isCommittingGitChanges = false
    @Published var isPushingGitBranch = false
    @Published var isQuickPublishingGitChanges = false
    @Published var gitQuickPublishResultByPath: [String: GitQuickPublishResponse] = [:]
    @Published var gitTestFlightStatusByPath: [String: GitTestFlightStatusResponse] = [:]
    @Published var gitTestFlightErrorByPath: [String: String] = [:]
    @Published var isRefreshingGitTestFlightStatus = false
    @Published var isStartingGitTestFlightRelease = false
    @Published var isCreatingPullRequest = false
    @Published var pullRequestURLByPath: [String: String] = [:]
    @Published var pullRequestStatusByPath: [String: GitPullRequestStatusResponse] = [:]
    @Published var pullRequestStatusErrorByPath: [String: String] = [:]
    @Published var isRefreshingPullRequestStatus = false
    @Published var pendingApprovalDecisionIDsBySessionID: [SessionID: Set<String>] = [:]
    @Published var pendingUserInputResponseIDsBySessionID: [SessionID: Set<String>] = [:]
    var pendingUserInputRequestsBySessionID: [SessionID: [String: AgentUserInputRequest]] = [:]
    @Published var foregroundActivityBySessionID: [SessionID: SessionForegroundActivity] = [:]
    @Published var runtimeActivityBySessionID: [SessionID: RuntimeActivitySnapshot] = [:]
    @Published var sessionControlStateByID: [SessionID: SessionControlState] = [:]
    /// 仅记录 App Server 明确返回的单 writer 冲突。不能从 thread/list 的 idle/notLoaded
    /// 推断写权限，否则只读打开历史也会被误判为可写或被另一端占用。
    @Published var activeWriterConflictLeases: Set<HostSessionLease> = []
    @Published var queuedRunningTurnsBySessionID: [SessionID: [QueuedTurnEntry]] = [:]
    /// 同一 Session 可连续提交多次权限变更；必须按提交顺序逐条等待精确 turn/started。
    @Published var pendingPermissionTurnBoundariesBySessionID: [SessionID: [PendingPermissionTurnBoundary]] = [:]
    /// 明确拒绝的消息离开队列后，仍持久化重试所需的 fresh-turn 权限快照。
    @Published var permissionTurnRetryRequirementsByClientMessageID: [ClientMessageID: PendingPermissionTurnBoundary] = [:]
    /// 用于让当前 Composer 收到“哪个已提交快照真正开始”的通知；非当前会话仍先更新 cache。
    @Published var latestSatisfiedPermissionTurnBoundary: PendingPermissionTurnBoundary?
    @Published var queuedTurnStorageErrorMessage: String?
    /// 只驱动主机选择器和写操作禁用态，不承载探活结果，避免状态圆点刷新整棵工作台。
    @Published private(set) var connectionSwitchTargetProfileID: String?
    @Published private(set) var latestFileUploadCompletion: FileUploadCompletionEvent?

    var isConnectionSwitchInProgress: Bool {
        connectionSwitchTargetProfileID != nil
    }

    func setConnectionSwitchTargetProfileID(_ profileID: String?) {
        guard connectionSwitchTargetProfileID != profileID else {
            return
        }
        connectionSwitchTargetProfileID = profileID
    }

    func setUnreadHistorySessionIDs(_ value: Set<SessionID>) {
        guard unreadHistorySessionIDs != value else {
            return
        }
        unreadHistorySessionIDs = value
    }

    func setHistoryCompletionObservedAtBySessionID(_ value: [SessionID: Date]) {
        guard historyCompletionObservedAtBySessionID != value else {
            return
        }
        historyCompletionObservedAtBySessionID = value
    }

    func insertPendingSessionArchiveMutationKey(_ key: ScopedSessionID) {
        pendingSessionArchiveMutationKeys.insert(key)
    }

    func removePendingSessionArchiveMutationKey(_ key: ScopedSessionID) {
        pendingSessionArchiveMutationKeys.remove(key)
    }

    let appStore: AppStore
    let conversationStore: ConversationStore
    let logStore: LogStore
    let contextStore: SessionContextStore
    let eventReducer: EventReducer
    let recentWorkspaceStore: RecentWorkspaceStore
    let workspaceAppearanceStore: WorkspaceAppearanceStore
    let sessionListPreferenceStore: SessionListPreferenceStore
    let sessionHistoryReadStateStore: SessionHistoryReadStateStore
    let sessionControlStateStore: SessionControlStateStore
    let sessionReminderStore: SessionReminderStore
    let sessionReminderScheduler: any SessionReminderScheduling
    let sessionReminderNow: () -> Date
    let carStatusSnapshotCoordinator: CarStatusSnapshotCoordinator
    let runtimeCompletionNotificationsEnabled: Bool
    let historySavingsNoticeStore: HistorySavingsNoticeStore
    let queuedTurnStore: any QueuedTurnPersisting
    let terminalStreamStore = TerminalStreamStore()
    let hostWarmSnapshotCache = HostWarmSnapshotCache()
    // 文件上传任务跨 ComposerView 重建持续存在，避免旋转、Split View 或切会话时丢失进度。
    let fileUploadStore: FileUploadStore
    // 草稿跟随 SessionStore 生命周期，避免窗口 resize 或详情页重建时随 ComposerView 的 @State 一起丢失。
    // 不使用 @Published，防止每次键入都触发整个工作台刷新。
    var composerDraftCache = ComposerDraftCache()
    // 模型与推理强度按会话保留，但只存在当前连接的内存生命周期内。
    // 与内容草稿分开后，空输入或发送成功也不会误删模型偏好。
    var composerModelSelectionCache = ComposerModelSelectionCache()
    // 权限选择按会话保留；未显式选择的既有 Thread 使用“沿用服务端当前设置”。
    var composerPermissionSelectionCache = ComposerPermissionSelectionCache()

    func storeCompletedFileUpload(_ attachment: UploadedFileAttachment, for scope: ComposerDraftScopeKey) {
        guard scope != .none else {
            return
        }
        var snapshot = composerDraftCache.snapshot(for: scope)
        guard !snapshot.attachments.contains(where: { $0.id == "uploadedFile:\(attachment.uploadID)" }) else {
            return
        }
        snapshot.attachments.append(.uploadedFile(attachment))
        composerDraftCache.save(snapshot, for: scope)
        latestFileUploadCompletion = FileUploadCompletionEvent(
            attachment: attachment,
            targetScope: scope
        )
    }

    func clearFileUploadsForConnectionChange() {
        fileUploadStore.cancelAll()
        latestFileUploadCompletion = nil
    }

    // Goal / Plan 选择同样需要跨横竖屏 View 重建，但不应持久化到下次启动。
    // 保持非 @Published，ComposerView 自己维持当前可见状态，避免放大刷新范围。
    var composerSendModeCache = ComposerSendModeCache()
    // 补充信息可能包含 isSecret 答案，只在 SessionStore 生命周期内暂存，绝不落盘。
    // 这样既能跨横竖屏导致的 ComposerView 重建恢复，又不会扩大敏感数据存储范围。
    var pendingUserInputFormStateCache = PendingUserInputFormState()
    let clientFactory: () throws -> any SessionStoreAPIClient
    let webSocketFactory: () -> any SessionWebSocketClient
    let sessionWebSocketFactory: ((AgentSession) -> any SessionWebSocketClient)?
    let webSocketReconnectDelayNanoseconds: (Int) -> UInt64
    let webSocketReconnectSleep: (UInt64) async throws -> Void
    let networkPathStatusSource: any NetworkPathStatusSource
    let sessionListNow: () -> Date
    let sessionListSleep: (UInt64) async -> Void
    let sessionSearchDebounceNanoseconds: UInt64
    let sessionSearchSleep: (UInt64) async throws -> Void
    var webSocket: (any SessionWebSocketClient)?
    var connectedSessionID: String?
    var connectedHostScope: HostScope?
    var connectedCredentialFingerprint: String?
    // iPad 同时保留父会话与一个子会话阅读区；子会话使用独立只读订阅，
    // 不复用 selectedSession 的前台 socket，避免切换右栏时断开父会话。
    var relatedSessionSocket: (any SessionWebSocketClient)?
    var relatedSessionSocketID: SessionID?
    var relatedSessionSocketGeneration = 0
    var selectionGeneration: UInt64 = 0
    var webSocketConnectionGeneration = 0
    /// 单调递增的重连租约。attempt 会在 reset 后从 1 重新开始，不能单独作为异步任务身份。
    var webSocketReconnectGeneration: UInt64 = 0
    var webSocketReconnectTask: Task<Void, Never>?
    var webSocketReconnectAttemptBySessionID: [SessionID: Int] = [:]
    var lastAppliedNetworkPathSequence: UInt64 = 0
    var networkPathGeneration = 0
    /// 前台/网络恢复各自推进一次代次；同一代次对当前会话只做一次强制历史对账。
    var recoveryHistoryGeneration: UInt64 = 0
    var reconciledRecoveryGenerationBySessionID: [SessionID: UInt64] = [:]
    var recoveryHistorySucceededBySessionID: [SessionID: Bool] = [:]
    var networkSuspendedSessionID: SessionID?
    var networkRecoveryTask: Task<Void, Never>?
    var appLifecycleSuspendedSessionID: SessionID?
    var isAppInBackground = false
    // 旧 agentd 不接受无 cwd thread/list 时，本 Host 生命周期只探测一次；
    // 精确工作区列表仍继续工作，形成明确能力检测与兼容回退。
    var controlledGlobalDiscoveryUnavailable = false
    // 记录当前 Host 经 agentd 受控全局发现授权过的 Thread。精确 cwd 的工作区刷新
    // 不会返回外部 Worktree，必须保留这些 ID；完整全局遍历确认消失后再收缩集合。
    // 这组 ID 也参与根侧栏的派生会话补充投影；授权集合变化必须通知 SwiftUI，
    // 否则全局页只更新既有 Session 时，外部 Worktree 会等到下一次刷新才出现。
    @Published var controlledGlobalSessionIDs: Set<SessionID> = [] {
        didSet {
            guard oldValue != controlledGlobalSessionIDs else { return }
            // 项目预览是缓存快照；即使 Session 本身早已由精确 cwd 加载，
            // 新确认的受控全局身份也必须立即更新派生会话补充行。
            rebuildProjectSessionListSnapshots()
        }
    }
    var connectionChangeGeneration = 0
    var inFlightConnectionChangeGeneration: Int?
    var connectionSwitchTargetGeneration: Int?
    var preparedConnectionTask: Task<PreparedConnectionSettings, Error>?
    var lastSeenEventSeqBySessionID: [SessionID: EventSequence] = [:]
    var historySnapshotSeqBySessionID: [SessionID: EventSequence] = [:]
    var runtimeEventFlushTasks: [HostSessionLease: Task<Void, Never>] = [:]
    var foregroundActivityClearTasks: [SessionID: Task<Void, Never>] = [:]
#if DEBUG
    var didApplyDebugWorkbenchUISeed = false
#endif
    var deliveredRuntimeNotificationIDs: Set<String> = []
    var locallyCompletedSessionIDs: Set<SessionID> = []
    var locallyCompletedGoalThreadIDs: Set<SessionID> = []
    var historyReadStateBySessionID: [SessionID: SessionHistoryReadState] = [:]
    var sessionArchiveMutationToken: UInt64 = 0
    var sessionArchiveMutationsByKey: [ScopedSessionID: SessionArchiveMutation] = [:]
    var listProjectionBySessionID: [SessionID: SessionListProjection] = [:]
    var recentActivityProjectionBySessionID: [SessionID: SessionRecentActivityProjection] = [:]
    // 队列订阅不依赖当前页面；用户切到其他会话后，原 thread 仍能在完成时继续 FIFO 派发。
    var queuedSessionSockets: [SessionID: any SessionWebSocketClient] = [:]
    var queuedSessionSocketGenerationByID: [SessionID: Int] = [:]
    var queuedSessionCredentialFingerprintByID: [SessionID: String] = [:]
    var queuedSessionReadyIDs: Set<SessionID> = []
    var queuedSessionReconnectTasks: [SessionID: Task<Void, Never>] = [:]
    var queuedTurnStartedIDBySessionID: [SessionID: TurnID] = [:]
    var queuedTurnAwaitingStartSessionIDs: Set<SessionID> = []
    // shared queue 的 started 事件可能早于 queue/add 回调。按 client ID 保留 RPC 门闩，
    // 避免 Runtime 的同 session 单提交保护仍占用时提前派发下一项。
    var queuedServerSubmissionAwaitingOutcomeBySessionID: [SessionID: ClientMessageID] = [:]
    var queuedServerSubmissionStartedBeforeOutcomeClientMessageIDs: Set<ClientMessageID> = []
    var queuedTurnBlockedCompletionIDBySessionID: [SessionID: TurnID] = [:]
    var queuedGuidanceDispatchClientMessageIDs: Set<ClientMessageID> = []
    var currentQueuedTurnProfileID: String?
    var queuedCommandActionRuns: [QueuedCommandActionRun] = []
    var projectsByID: [String: AgentProject] = [:]
    var workspacesByID: [String: AgentWorkspace] = [:]
    // 工作区页维护独立的本地浏览选择；保留当前 Profile 内的旧→新 ID，
    // 让卡片列表去重时能原位切换到幸存卡片，而不是跳到全局会话所在工作区。
    var workspaceIdentityReplacementByOldID: [String: String] = [:]
    var sidebarProjectsByID: [String: AgentProject] = [:]
    var sessionsByID: [SessionID: AgentSession] = [:]
    var sessionIndexByID: [SessionID: Int] = [:]
    // 只在 applyEventReducerOutput 的同步作用域存在；不能跨 event 或 await。
    // lookup 在每个 staged mutation 后同步，保证 storage-protection helper 读取到最新状态。
    var eventReducerSessionMutationBatch: EventReducerSessionMutationBatch?
    // @Published 在实际写入 sessions 前同步通知。通知回调若重入 reducer，不能直接从旧
    // canonical sessions 开新批次，否则外层赋值会覆盖内层结果；先排队，待提交完成后顺序处理。
    var isPublishingEventReducerSessions = false
    var deferredEventReducerOutputs: [EventReducerOutput] = []
    var isDrainingDeferredEventReducerOutputs = false
    var sortedAllSessions: [AgentSession] = []
    var sortedSessionsByProjectID: [String: [AgentSession]] = [:]
    var previewSessionsByProjectID: [String: [AgentSession]] = [:]
    var hiddenSessionCountByProjectID: [String: Int] = [:]
    @Published var sessionVisibleLimitByProjectID: [String: Int] = [:]
    var sessionListSnapshotsByProjectID: [String: ProjectSessionListSnapshot] = [:]
    var sessionPageCursorByProjectID: [String: String] = [:]
    var sessionHasMoreByProjectID: [String: Bool] = [:]
    /// 工作区详情独立于侧栏展开状态记录已经加载过旧页的项目，供下拉刷新保留分页窗口。
    var sessionProjectsWithAdditionalPages: Set<String> = []
    var sessionPageRequestTokenByProjectID: [String: Int] = [:]
    var sessionPageLoadingTokenByProjectID: [String: Int] = [:]
    var sessionFirstPageLoadingConsistencyByProjectID: [String: SessionListConsistency] = [:]
    var sessionFirstPageWaiterCountByProjectID: [String: Int] = [:]
    var sessionListFirstPageInFlightByKey: [SessionListFirstPageRequestKey: SessionListFirstPageInFlight] = [:]
    var sessionListFirstPageCacheByKey: [SessionListFirstPageRequestKey: SessionListFirstPageCacheEntry] = [:]
    @Published var workspaceSessionFirstPageCompletionByKey: [WorkspaceSessionFirstPageKey: WorkspaceSessionFirstPageCompletion] = [:]
    var sessionListCooldownUntilByBudgetKey: [SessionListBudgetKey: Date] = [:]
    var sessionListReconciliationTasksByProjectID: [String: Task<Void, Never>] = [:]
    var gitRefreshTasksByPath: [String: Task<Void, Never>] = [:]
    var gitRefreshRevisionByPath: [String: UInt64] = [:]
    var missingRunningSessionStateByID: [SessionID: MissingRunningSessionState] = [:]
    var missingRunningSessionReconciliationTasksByID: [SessionID: Task<Void, Never>] = [:]
    var lastSessionLibraryIndexRefreshAt: Date?
    var sessionLibraryIndexRefreshJob: SessionLibraryIndexRefreshJob?
    var sessionSearchTask: Task<Void, Never>?
    var sessionSearchLoadMoreTask: Task<Void, Never>?
    var sessionSearchGeneration = 0
    var sessionSearchLoadingCursor: String?
    var remoteSessionSearchSnippetByID: [SessionID: String] = [:]
    var historyPreviousCursorBySessionID: [SessionID: String] = [:]
    var historyHasMoreBeforeBySessionID: [SessionID: Bool] = [:]
    var historySeenPreviousCursorsBySessionID: [SessionID: Set<String>] = [:]
    var historyPageRequestTokenBySessionID: [SessionID: Int] = [:]
    var historyFirstPageInFlightByKey: [HistoryFirstPageRequestKey: HistoryFirstPageInFlight] = [:]
    var historyFirstPageCacheByKey: [HistoryFirstPageRequestKey: HistoryFirstPageCacheEntry] = [:]
    var historyLoadJobsBySessionID: [SessionID: HistoryLoadJob] = [:]
    var historyLoadJobTokenBySessionID: [SessionID: Int] = [:]
    var historyLoadedSignatureBySessionID: [SessionID: HistoryLoadSignature] = [:]
    var historyLoadedQualityBySessionID: [SessionID: HistoryLoadQuality] = [:]
    var historyItemEnrichmentBySessionID: [SessionID: HistoryItemEnrichmentState] = [:]
    /// 运行中的 full 历史可能暂时携带大量过程输出。命中网关单包上限后先显示 summary，
    /// 等对应 Turn 完成再补拉 canonical full，避免把临时膨胀误判成永久大历史。
    var deferredFullHistorySessionIDs: Set<SessionID> = []
    var freshEmptyHistorySignatureBySessionID: [SessionID: HistoryLoadSignature] = [:]
    var initialHistoryLoadingSessionIDs: Set<SessionID> = []
    @Published var historyLoadProgressBySessionID: [SessionID: HistoryLoadProgress] = [:]
    @Published var historySavingsNoticesBySessionID: [SessionID: HistorySavingsNotice] = [:]
    @Published var dismissedHistorySavingsNoticeEndpoints: Set<String> = []
    var appServerModelOptionsLastRefresh: Date?
    var permissionProfilesCWD: String?
    var permissionProfilesRefreshRequestedCWD: String?
    var permissionProfilesRefreshGeneration = 0
    var accountTokenUsageRefreshHostScope: HostScope?
    @Published var loadingEarlierHistorySessionIDs: Set<SessionID> = []

    let foregroundOutputIdleClearDelay: UInt64 = 8_000_000_000
    let runtimeEventFlushDelayNanoseconds: UInt64 = 80_000_000
    let sessionListConnectedPollingDelayNanoseconds: UInt64 = 60_000_000_000
    let sessionListDisconnectedPollingDelayNanoseconds: UInt64 = 8_000_000_000
    let sessionListFirstPageCacheTTL: TimeInterval = 2
    let sessionLibraryIndexPollingInterval: TimeInterval = 60
    let sessionListReconciliationDelayNanoseconds: UInt64 = 1_500_000_000
    var gitRefreshDelayNanoseconds: UInt64 = 600_000_000
    let economyHistoryPageLimit = 60
    let fullHistoryPageLimit = 20
    // full 首屏被 gateway cap 阻断且已知量级时，从首屏 turn 数向下逐级缩页重试完整历史，
    // 再回退缩略。顶端 10 必须与 CodexAppServerSessionRuntime.fullHistoryTurnPageLadderTop 一致。
    let fullHistoryTurnPageLadder = [10, 5, 2, 1]
    let historyFirstPageCacheTTL: TimeInterval = 4
    let historyPolicyRetryFallbackNanoseconds: UInt64 = 15_000_000_000
    let historyPolicyRetryMaxNanoseconds: UInt64 = 20_000_000_000
    static let optimisticSessionSource = "local"
    /// 项目侧栏只承担快速切换职责；每个项目固定展示最近 5 条，完整历史在工作区页分页查看。
    static let sessionPreviewLimit = 5
    static let sessionExpansionStep = 5
    /// 根侧栏在普通最近 8 条之外，最多稳定补入 3 条 Codex 派生只读会话。
    /// 保持有界可见性，避免为了发现外部 Worktree 而退回无界全局列表。
    static let derivedReadOnlyHistorySupplementLimit = 3
    // Tailscale 在弱网下可能经 Peer Relay 或 DERP 转发 thread/list 的较大响应。
    // 首屏先拿较小窗口，避免为了预览历史会话而卡住整个工作台。
    static let initialSessionPageLimit = 20
    static let expandedSessionPageLimit = 20
    /// presentation 补页保持顺序且有界：最小批量避免 child 密集时退化成逐条 RPC，页数上限防止异常 cursor 请求风暴。
    static let minimumSessionPresentationFillPageLimit = 5
    static let maximumSessionPresentationFillPageCount = 12
    /// 顶层会话常被 sub-agent child 稀释：首包仍保持 20 条小窗口，确认欠填后才按已观察到的
    /// root/raw 密度估算补页。3/2 是对密度波动的安全余量，避免估得过紧又多走一次远程 RTT。
    static let sessionPresentationFillEstimateSafetyNumerator = 3
    static let sessionPresentationFillEstimateSafetyDenominator = 2
    /// agentd Gateway 的 thread/list 协议硬上限是 50；客户端必须在发请求前守住同一边界。
    static let maximumSessionPresentationFillRawPageLimit = 50
    /// 单批达到页数上限时从已提交 cursor 续跑；每 4 批主动让出执行权并短暂退避，避免高密度历史长期独占链路。
    static let sessionPresentationFillBatchCountPerBurst = 4
    static let sessionPresentationFillBurstBackoffNanoseconds: UInt64 = 250_000_000
    static let missingRunningSessionReadThreshold = 2
    static let maximumUnverifiedRunningSessionMisses = 3
    static let commandActionHistoryLimit = 10
    static let queuedTurnLimitPerSession = 20
    static let workspaceGitSummaryTTL: TimeInterval = 60
    static let workspaceGitSummaryConcurrencyLimit = 3

    init(
        appStore: AppStore,
        conversationStore: ConversationStore,
        logStore: LogStore,
        contextStore: SessionContextStore? = nil,
        recentWorkspaceStore: RecentWorkspaceStore? = nil,
        workspaceAppearanceStore: WorkspaceAppearanceStore? = nil,
        sessionListPreferenceStore: SessionListPreferenceStore? = nil,
        sessionHistoryReadStateStore: SessionHistoryReadStateStore? = nil,
        sessionControlStateStore: SessionControlStateStore? = nil,
        sessionReminderStore: SessionReminderStore? = nil,
        carStatusSnapshotCoordinator: CarStatusSnapshotCoordinator? = nil,
        historySavingsNoticeStore: HistorySavingsNoticeStore? = nil,
        queuedTurnStore: (any QueuedTurnPersisting)? = nil,
        sessionReminderScheduler: (any SessionReminderScheduling)? = nil,
        sessionReminderNow: @escaping () -> Date = Date.init,
        runtimeCompletionNotificationsEnabled: Bool = false,
        fileUploadStore: FileUploadStore? = nil,
        clientFactory: (() throws -> any SessionStoreAPIClient)? = nil,
        webSocketFactory: (() -> any SessionWebSocketClient)? = nil,
        sessionWebSocketFactory: ((AgentSession) -> any SessionWebSocketClient)? = nil,
        webSocketReconnectDelayNanoseconds: ((Int) -> UInt64)? = nil,
        webSocketReconnectRandom: @escaping () -> Double = { Double.random(in: 0...1) },
        webSocketReconnectSleep: @escaping (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        networkPathStatusSource: (any NetworkPathStatusSource)? = nil,
        sessionListNow: @escaping () -> Date = Date.init,
        sessionListSleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        sessionSearchDebounceNanoseconds: UInt64 = 300_000_000,
        sessionSearchSleep: @escaping (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.appStore = appStore
        self.conversationStore = conversationStore
        self.logStore = logStore
        self.fileUploadStore = fileUploadStore ?? FileUploadStore()
        self.contextStore = contextStore ?? SessionContextStore()
        let initialProfileID = appStore.activeHostScope.profileID
        // 三个高频内存 Store 共用全局预算，但所有读写必须先绑定当前 Profile namespace。
        // 初始化阶段完成绑定，避免首批 bootstrap 数据落入空字符串兼容命名空间。
        conversationStore.activate(profileID: initialProfileID)
        logStore.activate(profileID: initialProfileID)
        self.contextStore.activate(profileID: initialProfileID)
        self.eventReducer = EventReducer()
        if let recentWorkspaceStore {
            self.recentWorkspaceStore = recentWorkspaceStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(suiteName: "SessionStore.RecentWorkspaces.\(UUID().uuidString)") ?? .standard
            self.recentWorkspaceStore = RecentWorkspaceStore(defaults: defaults)
        } else {
            self.recentWorkspaceStore = RecentWorkspaceStore()
        }
        if let workspaceAppearanceStore {
            self.workspaceAppearanceStore = workspaceAppearanceStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(
                suiteName: "SessionStore.WorkspaceAppearance.\(UUID().uuidString)"
            ) ?? .standard
            self.workspaceAppearanceStore = WorkspaceAppearanceStore(defaults: defaults)
        } else {
            self.workspaceAppearanceStore = WorkspaceAppearanceStore()
        }
        if let sessionListPreferenceStore {
            self.sessionListPreferenceStore = sessionListPreferenceStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(suiteName: "SessionStore.SessionListPreferences.\(UUID().uuidString)") ?? .standard
            self.sessionListPreferenceStore = SessionListPreferenceStore(defaults: defaults)
        } else {
            self.sessionListPreferenceStore = SessionListPreferenceStore()
        }
        if let sessionHistoryReadStateStore {
            self.sessionHistoryReadStateStore = sessionHistoryReadStateStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(suiteName: "SessionStore.HistoryReadStates.\(UUID().uuidString)") ?? .standard
            self.sessionHistoryReadStateStore = SessionHistoryReadStateStore(defaults: defaults)
        } else {
            self.sessionHistoryReadStateStore = SessionHistoryReadStateStore()
        }
        if let sessionControlStateStore {
            self.sessionControlStateStore = sessionControlStateStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(suiteName: "SessionStore.SessionControlStates.\(UUID().uuidString)") ?? .standard
            self.sessionControlStateStore = SessionControlStateStore(defaults: defaults)
        } else {
            self.sessionControlStateStore = SessionControlStateStore()
        }
        if let sessionReminderStore {
            self.sessionReminderStore = sessionReminderStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(suiteName: "SessionStore.SessionReminders.\(UUID().uuidString)") ?? .standard
            self.sessionReminderStore = SessionReminderStore(defaults: defaults)
        } else {
            self.sessionReminderStore = SessionReminderStore()
        }
        if let historySavingsNoticeStore {
            self.historySavingsNoticeStore = historySavingsNoticeStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(suiteName: "SessionStore.HistorySavingsNotice.\(UUID().uuidString)") ?? .standard
            self.historySavingsNoticeStore = HistorySavingsNoticeStore(defaults: defaults)
        } else {
            self.historySavingsNoticeStore = HistorySavingsNoticeStore()
        }
        if let queuedTurnStore {
            self.queuedTurnStore = queuedTurnStore
        } else if clientFactory != nil {
            self.queuedTurnStore = FileQueuedTurnStore(
                directoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SessionStore.QueuedTurns.\(UUID().uuidString)", isDirectory: true)
            )
        } else {
            self.queuedTurnStore = FileQueuedTurnStore()
        }
        if let sessionReminderScheduler {
            self.sessionReminderScheduler = sessionReminderScheduler
        } else if clientFactory != nil {
            self.sessionReminderScheduler = NoopSessionReminderScheduler()
        } else {
            self.sessionReminderScheduler = UserNotificationSessionReminderScheduler()
        }
        self.sessionReminderNow = sessionReminderNow
        if let carStatusSnapshotCoordinator {
            self.carStatusSnapshotCoordinator = carStatusSnapshotCoordinator
        } else if clientFactory != nil {
            let namespace = UUID().uuidString
            self.carStatusSnapshotCoordinator = CarStatusSnapshotCoordinator(
                selectionDefaults: UserDefaults(
                    suiteName: "SessionStore.CarStatus.Selection.\(namespace)"
                ) ?? .standard,
                sharedDefaults: UserDefaults(
                    suiteName: "SessionStore.CarStatus.Shared.\(namespace)"
                ),
                reloadTimelines: {}
            )
        } else {
            self.carStatusSnapshotCoordinator = CarStatusSnapshotCoordinator()
        }
        // 审批和补充信息始终允许提醒；完成/失败属于高频日常事件，首版默认关闭。
        self.runtimeCompletionNotificationsEnabled = runtimeCompletionNotificationsEnabled
        self.clientFactory = clientFactory ?? { try appStore.makeSessionStoreAPIClient() }
        self.webSocketFactory = webSocketFactory ?? { appStore.makeSessionWebSocketClient() }
        if let sessionWebSocketFactory {
            self.sessionWebSocketFactory = sessionWebSocketFactory
        } else if webSocketFactory == nil {
            self.sessionWebSocketFactory = { appStore.makeSessionWebSocketClient(for: $0) }
        } else {
            self.sessionWebSocketFactory = nil
        }
        if let webSocketReconnectDelayNanoseconds {
            self.webSocketReconnectDelayNanoseconds = webSocketReconnectDelayNanoseconds
        } else {
            self.webSocketReconnectDelayNanoseconds = { attempt in
                Self.defaultWebSocketReconnectDelayNanoseconds(
                    attempt: attempt,
                    randomUnit: webSocketReconnectRandom()
                )
            }
        }
        self.webSocketReconnectSleep = webSocketReconnectSleep
        if let networkPathStatusSource {
            self.networkPathStatusSource = networkPathStatusSource
        } else if clientFactory == nil {
            self.networkPathStatusSource = NWNetworkPathStatusSource()
        } else {
            self.networkPathStatusSource = StaticNetworkPathStatusSource(.satisfied)
        }
        self.sessionListNow = sessionListNow
        self.sessionListSleep = sessionListSleep
        self.sessionSearchDebounceNanoseconds = sessionSearchDebounceNanoseconds
        self.sessionSearchSleep = sessionSearchSleep
        self.dismissedHistorySavingsNoticeEndpoints = self.historySavingsNoticeStore.loadDismissedEndpoints()
        reloadSessionListPreferences()
        reloadHistoryReadStates()
        reloadSessionControlStates()
        reloadSessionReminders()
        reloadQueuedTurns()
        self.networkReachabilityStatus = self.networkPathStatusSource.currentStatus
        self.networkPathStatusSource.onStatusChange = { [weak self] update in
            Task { @MainActor in
                self?.applyNetworkReachabilityStatus(update)
            }
        }
        self.networkPathStatusSource.start()
    }

    deinit {
        networkRecoveryTask?.cancel()
        webSocketReconnectTask?.cancel()
        sessionSearchTask?.cancel()
        sessionSearchLoadMoreTask?.cancel()
        missingRunningSessionReconciliationTasksByID.values.forEach { $0.cancel() }
        queuedSessionReconnectTasks.values.forEach { $0.cancel() }
        networkPathStatusSource.stop()
    }

    static func defaultWebSocketReconnectDelayNanoseconds(
        attempt: Int,
        randomUnit: Double,
        maximumNanoseconds: UInt64 = 30_000_000_000
    ) -> UInt64 {
        let boundedExponent = max(0, min(attempt - 1, 5))
        let baseSeconds = min(30.0, Double(1 << boundedExponent))
        let normalizedRandom = min(1, max(0, randomUnit))
        // ±20% jitter 避免多台移动设备在同一秒同时打向 Mac；最终值仍受硬上限约束。
        let jitteredNanoseconds = baseSeconds * (0.8 + normalizedRandom * 0.4) * 1_000_000_000
        return min(maximumNanoseconds, UInt64(jitteredNanoseconds.rounded()))
    }

    var isNetworkUnavailable: Bool {
        networkReachabilityStatus == .unsatisfied
    }

    func sessionSearchSnippet(for sessionID: SessionID) -> String? {
        guard isSessionSearchActive else {
            return nil
        }
        return remoteSessionSearchSnippetByID[sessionID]
    }

    func loadMoreSessionSearchResults() async {
        let searchTerm = sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchTerm.isEmpty,
              sessionSearchHasMore,
              let requestedCursor = sessionSearchNextCursor,
              !requestedCursor.isEmpty,
              !isLoadingMoreSessionSearchResults,
              sessionSearchLoadingCursor == nil,
              !isNetworkUnavailable,
              connectionTermination == nil
        else {
            return
        }

        let generation = sessionSearchGeneration
        let connectionGeneration = appStore.connectionGeneration
        isLoadingMoreSessionSearchResults = true
        sessionSearchLoadingCursor = requestedCursor

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // 旧分页任务只能收尾自己的 loading；新查询即使复用了同一 cursor，也由 generation 隔离。
                if self.sessionSearchGeneration == generation,
                   self.sessionSearchLoadingCursor == requestedCursor {
                    self.sessionSearchLoadingCursor = nil
                    self.isLoadingMoreSessionSearchResults = false
                    self.sessionSearchLoadMoreTask = nil
                }
            }

            guard !Task.isCancelled,
                  self.sessionSearchGeneration == generation,
                  self.appStore.connectionGeneration == connectionGeneration,
                  self.sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == searchTerm,
                  self.sessionSearchNextCursor == requestedCursor
            else {
                return
            }

            do {
                let client = try self.clientFactory()
                let page = try await client.searchSessions(query: searchTerm, cursor: requestedCursor, limit: 50)
                guard !Task.isCancelled,
                      self.sessionSearchGeneration == generation,
                      self.appStore.connectionGeneration == connectionGeneration,
                      self.sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == searchTerm,
                      self.sessionSearchNextCursor == requestedCursor
                else {
                    return
                }
                self.applyRemoteSessionSearchPage(page, replacing: false, requestedCursor: requestedCursor)
            } catch {
                // 翻页失败只结束本次 loading，保留既有结果和 cursor，用户可显式重试。
                // 搜索增强不应改写全局连接、鉴权或错误状态。
            }
        }
        sessionSearchLoadMoreTask = task
        await task.value
    }

    func saveComposerDraft(_ snapshot: ComposerDraftSnapshot, for scope: ComposerDraftScopeKey) {
        composerDraftCache.save(snapshot, for: scope)
    }

    func composerDraft(for scope: ComposerDraftScopeKey) -> ComposerDraftSnapshot {
        composerDraftCache.snapshot(for: scope)
    }

    func removeComposerDraft(for scope: ComposerDraftScopeKey) {
        composerDraftCache.remove(scope: scope)
    }

    func saveComposerModelSelection(
        _ snapshot: ComposerModelSelectionSnapshot,
        for scope: ComposerDraftScopeKey
    ) {
        composerModelSelectionCache.save(snapshot, for: scope)
    }

    func composerModelSelection(
        for scope: ComposerDraftScopeKey
    ) -> ComposerModelSelectionSnapshot? {
        composerModelSelectionCache.snapshot(for: scope)
    }

    func removeComposerModelSelection(for scope: ComposerDraftScopeKey) {
        composerModelSelectionCache.remove(scope: scope)
    }

    func saveComposerPermissionSelection(
        _ snapshot: ComposerPermissionSelectionSnapshot,
        for scope: ComposerDraftScopeKey
    ) {
        composerPermissionSelectionCache.save(snapshot, for: scope)
    }

    func composerPermissionSelection(
        for scope: ComposerDraftScopeKey
    ) -> ComposerPermissionSelectionSnapshot? {
        composerPermissionSelectionCache.snapshot(for: scope)
    }

    func removeComposerPermissionSelection(for scope: ComposerDraftScopeKey) {
        composerPermissionSelectionCache.remove(scope: scope)
    }

    func pendingPermissionTurnBoundary(for sessionID: SessionID) -> PendingPermissionTurnBoundary? {
        pendingPermissionTurnBoundariesBySessionID[sessionID]?.first
    }

    func latestPendingPermissionTurnBoundary(for sessionID: SessionID) -> PendingPermissionTurnBoundary? {
        pendingPermissionTurnBoundariesBySessionID[sessionID]?.last
    }

    func pendingPermissionTurnBoundaryLocation(
        clientMessageID: ClientMessageID
    ) -> (sessionID: SessionID, index: Int, boundary: PendingPermissionTurnBoundary)? {
        for (sessionID, boundaries) in pendingPermissionTurnBoundariesBySessionID {
            if let index = boundaries.firstIndex(where: { $0.clientMessageID == clientMessageID }) {
                return (sessionID, index, boundaries[index])
            }
        }
        return nil
    }

    var hasPendingPermissionTurnBoundaryForSelectedSession: Bool {
        guard let selectedSessionID else { return false }
        return pendingPermissionTurnBoundariesBySessionID[selectedSessionID]?.isEmpty == false
    }

    var selectedSessionRequiresFreshPermissionTurn: Bool {
        guard let selectedSession else { return false }
        return selectedSession.isRunning
            || queuedRunningTurnsBySessionID[selectedSession.id]?.isEmpty == false
            || pendingPermissionTurnBoundariesBySessionID[selectedSession.id]?.isEmpty == false
            || queuedTurnAwaitingStartSessionIDs.contains(selectedSession.id)
    }

    @discardableResult
    func satisfyPendingPermissionTurnBoundary(
        sessionID: SessionID,
        clientMessageID: ClientMessageID?
    ) -> Bool {
        // nil 或错误 ID 都不是这条权限提交的权威 started，不能解除边界。
        guard let clientMessageID,
              let pending = pendingPermissionTurnBoundariesBySessionID[sessionID]?.first,
              pending.sessionID == sessionID,
              pending.clientMessageID == clientMessageID
        else {
            return false
        }
        guard mutateAndPersistQueuedTurns({
            var boundaries = pendingPermissionTurnBoundariesBySessionID[sessionID] ?? []
            guard boundaries.first?.clientMessageID == clientMessageID else { return }
            boundaries.removeFirst()
            if var queue = queuedRunningTurnsBySessionID[sessionID],
               let index = queue.firstIndex(where: { $0.clientMessageID == pending.clientMessageID }) {
                queue[index].requiresFreshTurn = nil
                queuedRunningTurnsBySessionID[sessionID] = queue
            }

            // 同一权限快照的后续消息已被这次 started 覆盖，不再强制额外创建 Turn。
            while boundaries.first?.permissionSelection == pending.permissionSelection {
                let covered = boundaries.removeFirst()
                if var queue = queuedRunningTurnsBySessionID[sessionID],
                   let index = queue.firstIndex(where: { $0.clientMessageID == covered.clientMessageID }) {
                    queue[index].requiresFreshTurn = nil
                    queuedRunningTurnsBySessionID[sessionID] = queue
                }
            }
            if boundaries.isEmpty {
                pendingPermissionTurnBoundariesBySessionID.removeValue(forKey: sessionID)
            } else {
                pendingPermissionTurnBoundariesBySessionID[sessionID] = boundaries
            }
        }) else {
            return false
        }

        // 还有更新的权限边界时，旧 started 只推进 FIFO，不能清理当前 Composer 标记。
        guard pendingPermissionTurnBoundariesBySessionID[sessionID]?.isEmpty != false else {
            return true
        }

        let scope = ComposerDraftScopeKey.session(sessionID)
        if let cached = composerPermissionSelectionCache.snapshot(for: scope),
           cached == pending.permissionSelection {
            var satisfied = cached
            satisfied.requiresNewTurn = false
            composerPermissionSelectionCache.save(satisfied, for: scope)
        }
        latestSatisfiedPermissionTurnBoundary = pending
        return true
    }

    func reconcilePendingPermissionTurnBoundaries(
        sessionID: SessionID,
        historyMessages: [CodexHistoryMessage]
    ) {
        let startedClientMessageIDs = Set(historyMessages.compactMap { message -> ClientMessageID? in
            guard let clientMessageID = message.clientMessageID,
                  let turnID = message.turnID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !turnID.isEmpty
            else {
                return nil
            }
            return clientMessageID
        })

        // App 可能在服务端 started 后、实时事件落地前退出。权威历史只能按 FIFO 头部
        // 解除边界，避免较新的历史消息越过尚未证明开始的权限提交。
        var didAdvanceBoundary = false
        while let pending = pendingPermissionTurnBoundary(for: sessionID),
              startedClientMessageIDs.contains(pending.clientMessageID) {
            guard satisfyPendingPermissionTurnBoundary(
                sessionID: sessionID,
                clientMessageID: pending.clientMessageID
            ) else {
                break
            }
            didAdvanceBoundary = true
        }
        if didAdvanceBoundary,
           sessionsByID[sessionID]?.activeTurnID == nil {
            dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID)
        }
    }

    /// 仅删除已明确不会再 started 的边界；结果不确定的派发必须保留。
    @discardableResult
    func removePendingPermissionTurnBoundary(
        sessionID: SessionID,
        clientMessageID: ClientMessageID
    ) -> PendingPermissionTurnBoundary? {
        guard var boundaries = pendingPermissionTurnBoundariesBySessionID[sessionID],
              let index = boundaries.firstIndex(where: { $0.clientMessageID == clientMessageID })
        else {
            return nil
        }
        let removed = boundaries.remove(at: index)
        if boundaries.isEmpty {
            pendingPermissionTurnBoundariesBySessionID.removeValue(forKey: sessionID)
        } else {
            pendingPermissionTurnBoundariesBySessionID[sessionID] = boundaries
        }
        return removed
    }

    func preservePermissionTurnRetryRequirementAfterRejection(
        sessionID: SessionID,
        clientMessageID: ClientMessageID
    ) {
        _ = mutateAndPersistQueuedTurns {
            guard let boundary = removePendingPermissionTurnBoundary(
                sessionID: sessionID,
                clientMessageID: clientMessageID
            ) else {
                return
            }
            permissionTurnRetryRequirementsByClientMessageID[clientMessageID] = boundary
        }
    }

    func migratePendingPermissionTurnBoundary(
        clientMessageID: ClientMessageID,
        to sessionID: SessionID
    ) {
        guard let location = pendingPermissionTurnBoundaryLocation(clientMessageID: clientMessageID),
              location.sessionID != sessionID else {
            return
        }
        _ = mutateAndPersistQueuedTurns {
            _ = removePendingPermissionTurnBoundary(
                sessionID: location.sessionID,
                clientMessageID: clientMessageID
            )
            pendingPermissionTurnBoundariesBySessionID[sessionID, default: []].append(
                PendingPermissionTurnBoundary(
                    sessionID: sessionID,
                    clientMessageID: clientMessageID,
                    permissionSelection: location.boundary.permissionSelection
                )
            )
        }
    }

    func composerSendModeForScopeActivation(
        previousScope: ComposerDraftScopeKey,
        nextScope: ComposerDraftScopeKey,
        currentMode: ComposerSendMode,
        isOptimisticSessionHandoff: Bool
    ) -> ComposerSendMode {
        composerSendModeCache.modeForScopeActivation(
            previousScope: previousScope,
            nextScope: nextScope,
            currentMode: currentMode,
            isOptimisticSessionHandoff: isOptimisticSessionHandoff
        )
    }

    func saveComposerSendMode(_ mode: ComposerSendMode, for scope: ComposerDraftScopeKey) {
        composerSendModeCache.save(mode, for: scope)
    }

    var selectedQueuedTurns: [QueuedTurnEntry] {
        guard let selectedSessionID else {
            return []
        }
        return queuedRunningTurnsBySessionID[selectedSessionID] ?? []
    }

    var selectedComposerTrayQueuedTurns: [QueuedTurnEntry] {
        guard let selectedSessionID else {
            return []
        }
        let timelineClientMessageIDs: Set<ClientMessageID> = Set(
            conversationStore.messages(for: selectedSessionID).compactMap { message in
                guard message.role == .user else { return nil }
                return message.clientMessageID
            }
        )
        // 只有对应用户气泡进入时间线后才隐藏；runtime/assistant 消息可能复用 clientMessageID。
        return selectedQueuedTurns.filter {
            $0.dispatchState != .dispatching || !timelineClientMessageIDs.contains($0.clientMessageID)
        }
    }

    func queuedTurns(sessionID: SessionID) -> [QueuedTurnEntry] {
        queuedRunningTurnsBySessionID[sessionID] ?? []
    }

    @discardableResult
    func updateQueuedTurn(
        clientMessageID: ClientMessageID,
        payload: CodexAppServerTurnPayload
    ) -> Bool {
        guard !payload.isEmpty,
              let location = queuedTurnLocation(clientMessageID: clientMessageID),
              let queuedTurn = queuedRunningTurnsBySessionID[location.sessionID]?[location.index],
              queuedTurn.dispatchState != .dispatching,
              !queuedTurn.intent.startsGoal || !payload.textPrompt.isEmpty
        else {
            return false
        }
        return mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[location.sessionID],
                  queue.indices.contains(location.index) else { return }
            queue[location.index].payload = payload
            if case .goal(_, let tokenBudget) = queue[location.index].intent {
                queue[location.index].intent = .goal(
                    objective: payload.textPrompt,
                    tokenBudget: tokenBudget
                )
            }
            queue[location.index].lastError = nil
            queuedRunningTurnsBySessionID[location.sessionID] = queue
        }
    }

    @discardableResult
    func deleteQueuedTurn(clientMessageID: ClientMessageID) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              queuedRunningTurnsBySessionID[location.sessionID]?[location.index].dispatchState != .dispatching
        else {
            return false
        }
        let didPersist = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[location.sessionID],
                  queue.indices.contains(location.index) else { return }
            let removed = queue.remove(at: location.index)
            if removed.dispatchState == .waiting,
               removePendingPermissionTurnBoundary(
                   sessionID: location.sessionID,
                   clientMessageID: removed.clientMessageID
               ) != nil {
                // 删除尚未开始的边界项后，后续等待项不能永久继承 accepted-but-not-started 门闩。
                for index in queue.indices where queue[index].waitsForAcceptedTurnStart == true {
                    queue[index].waitsForAcceptedTurnStart = nil
                    queue[index].blockedCompletionID = nil
                    queue[index].expectedTurnID = sessionsByID[location.sessionID]?.activeTurnID
                }
            }
            setQueuedTurns(queue, sessionID: location.sessionID)
        }
        if didPersist {
            stopQueuedSessionMonitoringIfIdle(sessionID: location.sessionID)
        }
        return didPersist
    }

    @discardableResult
    func retryQueuedTurn(clientMessageID: ClientMessageID) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              queuedRunningTurnsBySessionID[location.sessionID]?[location.index].dispatchState == .needsConfirmation
        else {
            return false
        }
        let didPersist = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[location.sessionID],
                  queue.indices.contains(location.index) else { return }
            queue[location.index].dispatchState = .waiting
            queue[location.index].expectedTurnID = sessionsByID[location.sessionID]?.activeTurnID
            queue[location.index].lastError = nil
            queuedRunningTurnsBySessionID[location.sessionID] = queue
        }
        if didPersist {
            ensureQueuedSessionMonitoring(sessionID: location.sessionID)
            dispatchNextQueuedRunningTurnIfIdle(sessionID: location.sessionID)
        }
        return didPersist
    }

    @discardableResult
    func guideQueuedTurnNow(clientMessageID: ClientMessageID) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              location.sessionID == selectedSessionID,
              let session = selectedSession,
              let queue = queuedRunningTurnsBySessionID[location.sessionID],
              queue.indices.contains(location.index)
        else {
            setErrorMessage(L10n.text("ui.there_are_currently_no_active_rounds_to_boot"))
            return false
        }
        let item = queue[location.index]
        let hasEarlierFreshTurnBoundary = queue[..<location.index].contains {
            $0.requiresFreshTurn == true
        }
        guard item.dispatchState == .waiting,
              item.intent.canGuideCurrentTurn,
              item.requiresFreshTurn != true,
              !hasEarlierFreshTurnBoundary,
              pendingPermissionTurnBoundariesBySessionID[location.sessionID]?.isEmpty != false,
              item.waitsForAcceptedTurnStart != true,
              let activeTurnID = session.activeTurnID,
              let socket = readyWebSocket(for: session)
        else {
            setErrorMessage(L10n.text("ui.there_are_currently_no_active_rounds_to_boot"))
            return false
        }
        guard mutateAndPersistQueuedTurns({
            guard var queue = queuedRunningTurnsBySessionID[location.sessionID],
                  queue.indices.contains(location.index) else { return }
            queue[location.index].dispatchState = .dispatching
            queue[location.index].lastAttemptAt = Date()
            queue[location.index].lastError = nil
            queuedRunningTurnsBySessionID[location.sessionID] = queue
        }) else {
            return false
        }
        queuedGuidanceDispatchClientMessageIDs.insert(clientMessageID)
        guard socket.sendGuidance(
            item.payload,
            clientMessageID: item.clientMessageID,
            expectedTurnID: activeTurnID
        ) else {
            queuedGuidanceDispatchClientMessageIDs.remove(clientMessageID)
            markQueuedTurnWaitingAfterDefiniteFailure(
                clientMessageID: clientMessageID,
                message: L10n.text("ui.the_connection_is_not_ready_yet_the_message")
            )
            return false
        }
        conversationStore.appendLocalUser(
            item.previewText,
            sessionID: session.id,
            clientMessageID: item.clientMessageID,
            sendStatus: .sending,
            turnPayload: item.payload,
            userDelivery: .guided
        )
        setForegroundActivity(.waitingForAssistant, sessionID: session.id)
        setStatusMessage(L10n.text("ui.directed_current_reply_immediately"))
        return true
    }

    @discardableResult
    func moveSelectedQueuedTurns(fromOffsets: IndexSet, toOffset: Int) -> Bool {
        guard let selectedSessionID,
              var queue = queuedRunningTurnsBySessionID[selectedSessionID],
              queue.allSatisfy({ $0.dispatchState == .waiting })
        else {
            return false
        }
        let boundaryIDs = Set(
            (pendingPermissionTurnBoundariesBySessionID[selectedSessionID] ?? []).map(\.clientMessageID)
        )
        guard boundaryIDs.isSubset(of: Set(queue.map(\.clientMessageID))) else {
            // 已离开队列的 uncertain 边界没有可见拖动位置，不能让等待项跨过它。
            return false
        }
        let moving = fromOffsets.sorted().compactMap { queue.indices.contains($0) ? queue[$0] : nil }
        for index in fromOffsets.sorted(by: >) where queue.indices.contains(index) {
            queue.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let destination = min(max(0, toOffset - removedBeforeDestination), queue.count)
        queue.insert(contentsOf: moving, at: destination)
        return mutateAndPersistQueuedTurns {
            queuedRunningTurnsBySessionID[selectedSessionID] = queue
            guard let boundaries = pendingPermissionTurnBoundariesBySessionID[selectedSessionID] else {
                return
            }
            let boundaryByID = Dictionary(uniqueKeysWithValues: boundaries.map { ($0.clientMessageID, $0) })
            pendingPermissionTurnBoundariesBySessionID[selectedSessionID] = queue.compactMap {
                boundaryByID[$0.clientMessageID]
            }
        }
    }

    func reloadQueuedTurns() {
        let profileID = appStore.notificationRoutingProfileID
        currentQueuedTurnProfileID = profileID
        queuedServerSubmissionAwaitingOutcomeBySessionID.removeAll()
        queuedServerSubmissionStartedBeforeOutcomeClientMessageIDs.removeAll()
        do {
            var snapshot = try queuedTurnStore.load(profileID: profileID)
            // 没有 server receipt 的 dispatching 项在 RPC 确认前中断，必须阻止盲目重放。
            // 已持久化 submissionID 的项已确认入队，重启后保持 dispatching 并等 items 对账。
            var didRecoverAmbiguousDispatch = false
            for sessionID in snapshot.queuesBySessionID.keys {
                guard var queue = snapshot.queuesBySessionID[sessionID] else { continue }
                for index in queue.indices
                where queue[index].dispatchState == .dispatching
                    && queue[index].serverSubmissionID == nil {
                    queue[index].dispatchState = .needsConfirmation
                    queue[index].lastError = L10n.text("ui.the_last_sending_was_interrupted_before_confirmation_checking")
                    didRecoverAmbiguousDispatch = true
                }
                snapshot.queuesBySessionID[sessionID] = queue
            }
            queuedRunningTurnsBySessionID = snapshot.queuesBySessionID.filter { !$0.value.isEmpty }
            pendingPermissionTurnBoundariesBySessionID = snapshot.pendingPermissionTurnBoundariesBySessionID
            permissionTurnRetryRequirementsByClientMessageID = snapshot.permissionTurnRetryRequirementsByClientMessageID
            if didRecoverAmbiguousDispatch {
                try queuedTurnStore.save(snapshot)
            }
            queuedTurnStorageErrorMessage = nil
        } catch {
            // 解码失败不覆盖原文件；否则一次版本不兼容会把待发指令静默清空。
            queuedRunningTurnsBySessionID = [:]
            pendingPermissionTurnBoundariesBySessionID = [:]
            permissionTurnRetryRequirementsByClientMessageID = [:]
            reportQueuedTurnStorageError(error)
        }
    }

    func persistQueuedTurns() throws {
        let profileID = currentQueuedTurnProfileID ?? appStore.notificationRoutingProfileID
        let snapshot = QueuedTurnProfileSnapshot(
            profileID: profileID,
            queuesBySessionID: queuedRunningTurnsBySessionID.filter { !$0.value.isEmpty },
            pendingPermissionTurnBoundariesBySessionID: pendingPermissionTurnBoundariesBySessionID,
            permissionTurnRetryRequirementsByClientMessageID: permissionTurnRetryRequirementsByClientMessageID
        )
        try queuedTurnStore.save(snapshot)
    }

    @discardableResult
    func mutateAndPersistQueuedTurns(_ mutation: () -> Void) -> Bool {
        let previous = queuedRunningTurnsBySessionID
        let previousPermissionBoundaries = pendingPermissionTurnBoundariesBySessionID
        let previousRetryRequirements = permissionTurnRetryRequirementsByClientMessageID
        mutation()
        do {
            try persistQueuedTurns()
            queuedTurnStorageErrorMessage = nil
            return true
        } catch {
            queuedRunningTurnsBySessionID = previous
            pendingPermissionTurnBoundariesBySessionID = previousPermissionBoundaries
            permissionTurnRetryRequirementsByClientMessageID = previousRetryRequirements
            reportQueuedTurnStorageError(error)
            return false
        }
    }

    func reportQueuedTurnStorageError(_ error: Error) {
        let message = L10n.format("ui.failed_to_save_local_queue_value", error.localizedDescription)
        queuedTurnStorageErrorMessage = message
        setErrorMessage(message)
    }

    func queuedTurnLocation(
        clientMessageID: ClientMessageID
    ) -> (sessionID: SessionID, index: Int)? {
        for (sessionID, queue) in queuedRunningTurnsBySessionID {
            if let index = queue.firstIndex(where: { $0.clientMessageID == clientMessageID }) {
                return (sessionID, index)
            }
        }
        return nil
    }

    func setQueuedTurns(_ queue: [QueuedTurnEntry], sessionID: SessionID) {
        if queue.isEmpty {
            queuedRunningTurnsBySessionID.removeValue(forKey: sessionID)
            queuedTurnStartedIDBySessionID.removeValue(forKey: sessionID)
        } else {
            queuedRunningTurnsBySessionID[sessionID] = queue
        }
    }

    static func safePreviewFilename(_ rawName: String) -> String {
        let fallback = "preview"
        let lastComponent = (rawName as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lastComponent.isEmpty else {
            return fallback
        }
        let blocked = CharacterSet(charactersIn: "/\\:\u{0}")
        let cleaned = lastComponent
            .components(separatedBy: blocked)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    var selectedProject: AgentProject? {
        guard let selectedProjectID else {
            return nil
        }
        return sidebarProjectsByID[selectedProjectID] ?? projectsByID[selectedProjectID]
    }

    var selectedSession: AgentSession? {
        guard let selectedSessionID else {
            return nil
        }
        return sessionsByID[selectedSessionID]
    }

    var selectedThreadGoal: ThreadGoal? {
        guard let session = selectedSession else {
            return nil
        }
        return Self.matchingThreadGoal(for: session, context: contextStore.context(for: session.id))
    }

    var selectedForegroundActivity: SessionForegroundActivity? {
        if isRefreshingSelectedSession {
            return .refreshing
        }
        guard let selectedSessionID else {
            return nil
        }
        guard selectedSession?.isRunning == true else {
            return nil
        }
        return foregroundActivityBySessionID[selectedSessionID]
    }

    var selectedRuntimeActivitySnapshot: RuntimeActivitySnapshot? {
        guard let selectedSessionID else {
            return nil
        }
        guard selectedSession?.isRunning == true else {
            return nil
        }
        return runtimeActivityBySessionID[selectedSessionID]
    }

    func foregroundActivity(for sessionID: SessionID) -> SessionForegroundActivity? {
        guard sessionsByID[sessionID]?.isRunning == true else {
            return nil
        }
        return foregroundActivityBySessionID[sessionID]
    }

    func runtimeActivitySnapshot(for sessionID: SessionID) -> RuntimeActivitySnapshot? {
        guard sessionsByID[sessionID]?.isRunning == true else {
            return nil
        }
        return runtimeActivityBySessionID[sessionID]
    }

    var selectedGitStatusPath: String? {
        if let session = selectedSession, !session.dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.dir
        }
        return selectedProject?.path
    }

    var selectedCommandActionPath: String? {
        selectedGitStatusPath
    }

    var selectedCommandActions: [AgentCommandAction] {
        guard let path = selectedCommandActionPath else {
            return []
        }
        return commandActionsByPath[path] ?? []
    }

    var selectedCommandActionErrorMessage: String? {
        guard let path = selectedCommandActionPath else {
            return nil
        }
        return commandActionErrorByPath[path]
    }

    var selectedCommandActionResult: CommandActionRunResponse? {
        guard let path = selectedCommandActionPath else {
            return nil
        }
        return commandActionResultByPath[path]
    }

    var selectedCommandActionHistory: [CommandActionRunResponse] {
        guard let path = selectedCommandActionPath else {
            return []
        }
        return commandActionHistoryByPath[path] ?? []
    }

    var selectedQueuedCommandActionIDs: [String] {
        guard let path = selectedCommandActionPath else {
            return []
        }
        return queuedCommandActionIDsByPath[path] ?? []
    }

    var isRunningCommandAction: Bool {
        runningCommandActionID != nil
    }

    var selectedGitStatus: GitStatusResponse? {
        gitStatus(for: selectedGitStatusPath)
    }

    var selectedGitStatusErrorMessage: String? {
        gitStatusError(for: selectedGitStatusPath)
    }

    var selectedGitActionErrorMessage: String? {
        gitActionError(for: selectedGitStatusPath)
    }

    var selectedGitQuickPublishResult: GitQuickPublishResponse? {
        gitQuickPublishResult(for: selectedGitStatusPath)
    }

    var selectedGitTestFlightStatus: GitTestFlightStatusResponse? {
        gitTestFlightStatus(for: selectedGitStatusPath)
    }

    var selectedGitTestFlightErrorMessage: String? {
        gitTestFlightError(for: selectedGitStatusPath)
    }

    var selectedPullRequestURL: String? {
        pullRequestURL(for: selectedGitStatusPath)
    }

    var selectedPullRequestStatus: GitPullRequestStatusResponse? {
        pullRequestStatus(for: selectedGitStatusPath)
    }

    var selectedPullRequestStatusErrorMessage: String? {
        pullRequestStatusError(for: selectedGitStatusPath)
    }

    func gitStatus(for path: String?) -> GitStatusResponse? {
        normalizedGitStatePath(path).flatMap { gitStatusByPath[$0] }
    }

    func gitStatusError(for path: String?) -> String? {
        normalizedGitStatePath(path).flatMap { gitStatusErrorByPath[$0] }
    }

    func gitActionError(for path: String?) -> String? {
        normalizedGitStatePath(path).flatMap { gitActionErrorByPath[$0] }
    }

    func gitQuickPublishResult(for path: String?) -> GitQuickPublishResponse? {
        normalizedGitStatePath(path).flatMap { gitQuickPublishResultByPath[$0] }
    }

    func gitTestFlightStatus(for path: String?) -> GitTestFlightStatusResponse? {
        normalizedGitStatePath(path).flatMap { gitTestFlightStatusByPath[$0] }
    }

    func gitTestFlightError(for path: String?) -> String? {
        normalizedGitStatePath(path).flatMap { gitTestFlightErrorByPath[$0] }
    }

    func pullRequestURL(for path: String?) -> String? {
        guard let path = normalizedGitStatePath(path) else { return nil }
        return pullRequestStatusByPath[path]?.url ?? pullRequestURLByPath[path]
    }

    func pullRequestStatus(for path: String?) -> GitPullRequestStatusResponse? {
        normalizedGitStatePath(path).flatMap { pullRequestStatusByPath[$0] }
    }

    func pullRequestStatusError(for path: String?) -> String? {
        normalizedGitStatePath(path).flatMap { pullRequestStatusErrorByPath[$0] }
    }

    private func normalizedGitStatePath(_ path: String?) -> String? {
        let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    var connectionBadgeTitle: String? {
        guard let selectedSession else {
            return nil
        }
        if selectedSession.isLocalDraft {
            return L10n.text("ui.new_session")
        }
        guard selectedSession.isRunning else {
            if selectedSession.isAppServerHistory {
                return L10n.text("ui.history")
            }
            return selectedSession.status == "closed" ? L10n.text("ui.ended") : selectedSession.status
        }
        return webSocketStatus.title
    }

    var filteredSessions: [AgentSession] {
        let base: [AgentSession]
        guard let selectedProjectID else {
            base = sortedAllSessions
            return sessionsMatchingSearch(sessionsIncludingRemoteSearch(base))
        }
        base = sortedSessionsByProjectID[selectedProjectID] ?? []
        return sessionsMatchingSearch(sessionsIncludingRemoteSearch(base, projectID: selectedProjectID))
    }

    /// 会话库不跟随 selectedProjectID 过滤；根侧栏和会话页始终看到同一份跨工作区轻量索引。
    var sessionLibrarySessions: [AgentSession] {
        let merged = sessionsIncludingRemoteSearch(sessions.filter(isListableSession))
        // 规划 Tab 必须直接依赖当前 pinnedSessionIDs 生成顺序，避免只有切换 Tab
        // 触发整页重建后才看到置顶结果；搜索补入的远端会话也使用同一排序口径。
        return sessionsMatchingSearch(sortedSessionsForList(merged))
    }

    /// 最近列表严格按活动时间排序，置顶只影响完整会话库，不改变“最近”的时间语义。
    var recentSessions: [AgentSession] {
        Array(Self.sortedSessions(sessions.filter(isListableSession)).prefix(8))
    }

    /// 进行中的任务不能被“最近 8 条”截断；侧栏始终展示当前已加载索引里的全部运行态。
    var activeSessions: [AgentSession] {
        Self.sortedSessions(sessions.filter { isListableSession($0) && ($0.isRunning || $0.isLocalDraft) })
    }

    /// 历史区保留普通最近 8 条，并从 agentd 已裁剪授权的全局结果中稳定补入少量
    /// Codex 派生只读会话。补充集仍按 recencyAt 排序，不读取 updatedAt 制造列表跳动。
    var recentHistorySessions: [AgentSession] {
        let sortedHistory = Self.sortedSessions(
            sessions.filter { isListableSession($0) && !$0.isRunning && !$0.isLocalDraft }
        )
        return sessionsIncludingDerivedReadOnlySupplements(
            base: Array(sortedHistory.prefix(8)),
            candidates: sortedHistory
        )
    }

    var filteredSidebarProjects: [AgentProject] {
        guard isSessionSearchActive else {
            return sidebarProjects
        }
        return sidebarProjects.filter { project in
            projectMatchesSearch(project)
                || !sessionsMatchingSearch(sessionsIncludingRemoteSearch(sortedSessionsByProjectID[project.id] ?? [], projectID: project.id)).isEmpty
        }
    }

    var sessionSidebarProjects: [AgentProject] {
        guard let sessionWorkspaceIDs else {
            return sidebarProjects
        }
        return sidebarProjects.filter { sessionWorkspaceIDs.contains($0.id) }
    }

    var filteredSessionSidebarProjects: [AgentProject] {
        let projects = effectiveSessionSidebarProjects
        guard isSessionSearchActive else {
            return projects
        }
        return projects.filter { project in
            projectMatchesSearch(project)
                || !sessionsMatchingSearch(sessionsIncludingRemoteSearch(sortedSessionsByProjectID[project.id] ?? [], projectID: project.id)).isEmpty
        }
    }

    var effectiveSessionSidebarProjects: [AgentProject] {
        let projects = sessionSidebarProjects
        guard selectedSessionID != nil,
              let selectedProjectID,
              !projects.contains(where: { $0.id == selectedProjectID })
        else {
            return projects
        }

        // 当前正在查看的会话必须在左侧保留上下文；这里只做临时补项，不写回工作区筛选偏好。
        return sidebarProjects.filter { project in
            project.id == selectedProjectID || projects.contains(where: { $0.id == project.id })
        }
    }

    var sessionWorkspaceSelectionCount: Int {
        sessionSidebarProjects.count
    }

    var isSessionSearchActive: Bool {
        !normalizedSessionSearchQuery.isEmpty
    }

    func isProjectExpanded(_ projectID: String) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    func isShowingAllSessions(projectID: String) -> Bool {
        sessionVisibleLimit(forProjectID: projectID) > Self.sessionPreviewLimit
    }

    func sessions(forProjectID projectID: String) -> [AgentSession] {
        sortedSessionsByProjectID[projectID] ?? []
    }

    func isSessionPinned(_ sessionID: SessionID) -> Bool {
        pinnedSessionIDs.contains(sessionID)
    }

    func isSessionArchived(_ sessionID: SessionID) -> Bool {
        archivedSessionIDs.contains(sessionID)
    }

    func isWorkspaceShownInSessions(_ projectID: String) -> Bool {
        sessionWorkspaceIDs?.contains(projectID) ?? true
    }

    func toggleWorkspaceInSessions(_ project: AgentProject) {
        let allProjectIDs = Set(sidebarProjects.map(\.id))
        var next = sessionWorkspaceIDs ?? allProjectIDs
        if next.contains(project.id) {
            next.remove(project.id)
            setStatusMessage(L10n.format("ui.value_has_been_removed_from_the_conversation", project.name))
        } else {
            next.insert(project.id)
            setStatusMessage(L10n.format("ui.already_shown_in_session_value", project.name))
        }
        setSessionWorkspaceIDs(next.intersection(allProjectIDs))
    }

    func resetSessionWorkspaceSelection() {
        setStatusMessage(L10n.text("ui.session_resumed_show_all_workspaces"))
        setSessionWorkspaceIDs(nil)
    }

    func visibleSessions(forProjectID projectID: String) -> [AgentSession] {
        let sessions = sessions(forProjectID: projectID)
        return sessionsIncludingDerivedReadOnlySupplements(
            base: Self.lifecycleVisibleSessions(
                sessions,
                limit: sessionVisibleLimit(forProjectID: projectID)
            ),
            candidates: sessions
        )
    }

    func hiddenSessionCount(forProjectID projectID: String) -> Int {
        let sessions = sessions(forProjectID: projectID)
        return max(0, sessions.count - visibleSessions(forProjectID: projectID).count)
    }

    func canLoadMoreSessions(projectID: String) -> Bool {
        sessionHasMoreByProjectID[projectID] == true
    }

    func sessionListSnapshot(forProjectID projectID: String) -> ProjectSessionListSnapshot {
        sessionListSnapshotsByProjectID[projectID] ?? makeProjectSessionListSnapshot(forProjectID: projectID)
    }

    func controlState(for session: AgentSession) -> SessionControlState {
        if isProtocolReadOnlySession(session) {
            return .observing
        }
        if session.isRunning,
           session.id.hasPrefix("local:"),
           session.source == Self.optimisticSessionSource,
           session.resumeID == nil {
            // 新会话首发时会先发布 local:* 的 running 占位，再等待 thread/start 返回真实 ID。
            // 该占位由本机刚刚创建，应保持可控；这里只做内存态判定，避免把临时 ID 持久化到控制权存储。
            return .ipadOwned
        }
        if let state = sessionControlStateByID[session.id] {
            return state
        }
        return session.isRunning ? .observing : .takenOver
    }

    func canControlSession(_ session: AgentSession?) -> Bool {
        guard !isConnectionSwitchInProgress else {
            return false
        }
        guard let session else {
            return true
        }
        guard !isProtocolReadOnlySession(session) else {
            return false
        }
        guard !hasActiveWriterConflict(sessionID: session.id) else {
            return false
        }
        guard session.isRunning else {
            return true
        }
        return controlState(for: session).isControllable
    }

    var canSendInSelectedSession: Bool {
        canControlSession(selectedSession) && selectedQuotaNotice?.blocksSending != true
    }

    var selectedQuotaNotice: CodexQuotaNotice? {
        CodexQuotaNotice.make(rateLimit: selectedSession?.rateLimit, errorMessage: errorMessage)
    }

    var selectedCodexUsageDisplay: CodexUsageDisplaySummary? {
        CodexUsageDisplaySummary.make(rateLimit: selectedSession?.rateLimit)
    }

    var accountCodexUsageWindowsDisplay: CodexUsageWindowsDisplay {
        CodexUsageWindowsDisplay.make(rateLimit: latestRateLimit(runtimeProvider: "codex"), fallbackDisplayName: "Codex")
    }

    var accountClaudeUsageWindowsDisplay: CodexUsageWindowsDisplay {
        CodexUsageWindowsDisplay.make(rateLimit: latestRateLimit(runtimeProvider: "claude"), fallbackDisplayName: "Claude")
    }

    func latestRateLimit(runtimeProvider: String) -> RateLimitSummary? {
        let normalizedProvider = Self.normalizedRuntimeProvider(runtimeProvider)
        if let cached = accountRateLimitsByRuntime[normalizedProvider] {
            return cached
        }
        if let session = selectedSession,
           Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == normalizedProvider,
           let rateLimit = session.rateLimit {
            return rateLimit
        }
        return mostRecentSessionRateLimit(runtimeProvider: normalizedProvider)
    }

    func mostRecentSessionRateLimit(runtimeProvider: String) -> RateLimitSummary? {
        sessions
            .filter { session in
                session.rateLimit != nil
                    && Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == runtimeProvider
            }
            .sorted {
                ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            .first?
            .rateLimit
    }

    var isSelectedSessionObserving: Bool {
        guard let session = selectedSession else {
            return false
        }
        return isSessionObserving(session)
    }

    func isSessionObserving(_ session: AgentSession) -> Bool {
        session.isRunning && !canControlSession(session)
    }

    var selectedSessionControlNotice: String? {
        guard isSelectedSessionObserving else {
            return nil
        }
        if let session = selectedSession,
           isProtocolReadOnlySession(session) {
            return L10n.text("ui.read_only")
        }
        return L10n.text("ui.this_session_is_running_on_other_clients_the")
    }

    var selectedSessionHasActiveWriterConflict: Bool {
        guard let selectedSessionID else {
            return false
        }
        return hasActiveWriterConflict(sessionID: selectedSessionID)
    }

    func hasActiveWriterConflict(sessionID: SessionID) -> Bool {
        activeWriterConflictLeases.contains(
            HostSessionLease(hostScope: appStore.activeHostScope, sessionID: sessionID)
        )
    }

    func setActiveWriterConflict(_ hasConflict: Bool, sessionID: SessionID) {
        let lease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: sessionID)
        if hasConflict {
            activeWriterConflictLeases.insert(lease)
            // 每次明确的 writer 拒绝都代表远端状态可能已经变化。清掉旧边界，
            // 让冲突卡重新读取最近的精简 Turn 摘要，不能复用上一次重试前的结果。
            writerConflictForkAvailabilityByLease.removeValue(forKey: lease)
            writerConflictForkErrorByLease.removeValue(forKey: lease)
            writerConflictForkPreparationRevision &+= 1
        } else {
            activeWriterConflictLeases.remove(lease)
            writerConflictForkAvailabilityByLease.removeValue(forKey: lease)
            writerConflictForkErrorByLease.removeValue(forKey: lease)
            writerConflictForkPreparationRevision &+= 1
        }
    }

    var selectedSessionAllowsTakeOver: Bool {
        guard let session = selectedSession else {
            return false
        }
        return !isProtocolReadOnlySession(session)
    }

    func isProtocolReadOnlySession(_ session: AgentSession) -> Bool {
        !session.allowsDirectInput
    }

    func takeOverSession(_ session: AgentSession) {
        guard !isProtocolReadOnlySession(session) else {
            setStatusMessage(L10n.text("ui.read_only"))
            return
        }
        setSessionControlState(.takenOver, sessionID: session.id)
        if session.id == selectedSessionID, session.isRunning {
            // 接管前消息区已经由 selectSession/刷新用 thread/read 快照兜底；backlog 走状态级
            // 回放（completed 内容仍会补播），完整回放会把旧 delta 再直播一遍。
            connectWebSocket(session, replayBufferedEvents: false)
        }
        setStatusMessage(L10n.text("ui.taken_over_to_ipad"))
    }

    func takeOverSelectedSession() {
        guard let session = selectedSession else {
            return
        }
        takeOverSession(session)
    }

    func canLoadEarlierHistory(sessionID: SessionID?) -> Bool {
        guard let sessionID else {
            return false
        }
        return historyHasMoreBeforeBySessionID[sessionID] == true
    }

    var selectedHistorySavingsNotice: HistorySavingsNotice? {
        guard let selectedSessionID else {
            return nil
        }
        return historySavingsNoticesBySessionID[selectedSessionID]
    }

    func isLoadingEarlierHistory(sessionID: SessionID?) -> Bool {
        guard let sessionID else {
            return false
        }
        return loadingEarlierHistorySessionIDs.contains(sessionID)
    }

    func historyLoadProgress(sessionID: SessionID?) -> HistoryLoadProgress? {
        guard let sessionID else {
            return nil
        }
        return historyLoadProgressBySessionID[sessionID]
    }

}
