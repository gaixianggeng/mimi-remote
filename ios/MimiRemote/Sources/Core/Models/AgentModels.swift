import Foundation

typealias SessionID = String
typealias MessageID = String
typealias ClientMessageID = String
typealias TurnID = String
typealias AgentItemID = String
typealias EventSequence = Int64
typealias ModelRevision = Int

struct AgentProject: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let path: String
}

struct AgentWorkspace: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let path: String
    let rootProjectID: String?
    let rootProjectName: String?
    let rootProjectPath: String?
    var lastOpenedAt: Date?

    var project: AgentProject {
        AgentProject(id: id, name: name, path: path)
    }

    init(
        id: String,
        name: String,
        path: String,
        rootProjectID: String? = nil,
        rootProjectName: String? = nil,
        rootProjectPath: String? = nil,
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.rootProjectID = rootProjectID
        self.rootProjectName = rootProjectName
        self.rootProjectPath = rootProjectPath
        self.lastOpenedAt = lastOpenedAt
    }

    init(project: AgentProject, lastOpenedAt: Date? = nil) {
        self.init(
            id: project.id,
            name: project.name,
            path: project.path,
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path,
            lastOpenedAt: lastOpenedAt
        )
    }

    func opened(at date: Date) -> AgentWorkspace {
        AgentWorkspace(
            id: id,
            name: name,
            path: path,
            rootProjectID: rootProjectID,
            rootProjectName: rootProjectName,
            rootProjectPath: rootProjectPath,
            lastOpenedAt: date
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case rootProjectID = "root_project_id"
        case rootProjectName = "root_project_name"
        case rootProjectPath = "root_project_path"
        case lastOpenedAt = "last_opened_at"
    }
}

struct AgentSession: Identifiable, Codable, Hashable {
    let id: SessionID
    let projectID: String
    let project: String
    let dir: String
    var title: String
    var status: String
    let source: String
    let runtimeProvider: String?
    let resumeID: String?
    var createdAt: Date?
    var updatedAt: Date?
    var recencyAt: Date?
    var preview: String?
    var activeTurnID: TurnID?
    let lastSeq: EventSequence?
    let revision: ModelRevision?
    var usage: UsageSummary?
    var rateLimit: RateLimitSummary?
    var pendingApproval: ApprovalSummary?
    var pendingUserInput: AgentUserInputRequest?
    var goal: ThreadGoal?
    var appServerSessionID: String?
    var parentThreadID: String?
    /// `parentThreadID` 缺失时仍可能是 source-only 子 Agent；nil 表示旧协议未提供身份结论。
    var isSubagent: Bool?
    var agentNickname: String?
    var agentRole: String?
    var canAcceptDirectInput: Bool?
    let context: SessionContextSnapshot?

    /// 会话列表只认有名称的分支；空白值和 detached HEAD 不应伪装成可读分支。
    var gitBranchName: String? {
        guard let branch = context?.git?.branch?.trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty else {
            return nil
        }
        return branch
    }

    var isAppServerHistory: Bool {
        status == "history"
    }

    /// 新建页在首条消息前只保留本地草稿，不提前创建没有 rollout 的远端 thread。
    var isLocalDraft: Bool {
        source == "local" && status == "draft" && resumeID == nil
    }

    var isRunning: Bool {
        status == "running" || status == "waiting_for_approval" || status == "waiting_for_input"
    }

    /// 旧 App Server 的普通顶层 thread 没有 capability 字段，继续沿用既有可写行为；
    /// 子会话缺字段则 fail-closed，避免把协议未知误当成可直接输入。
    var allowsDirectInput: Bool {
        canAcceptDirectInput ?? !isSubagentThread
    }

    /// 父子关系或明确的 subAgent source 任一成立，都按结构子任务处理。
    /// `forkedFromId` 不进入模型，普通 fork 因此不会被误判为子 Agent。
    var isSubagentThread: Bool {
        parentThreadID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || context?.parentThreadID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || isSubagent == true
            || context?.isSubagent == true
    }

    var displayStatusText: String {
        displayStatus(foregroundActivity: nil).title
    }

    init(
        id: SessionID,
        projectID: String,
        project: String,
        dir: String,
        title: String,
        status: String,
        source: String,
        runtimeProvider: String? = nil,
        resumeID: String?,
        createdAt: Date?,
        updatedAt: Date?,
        recencyAt: Date? = nil,
        preview: String? = nil,
        activeTurnID: TurnID? = nil,
        lastSeq: EventSequence? = nil,
        revision: ModelRevision? = nil,
        usage: UsageSummary? = nil,
        rateLimit: RateLimitSummary? = nil,
        pendingApproval: ApprovalSummary? = nil,
        pendingUserInput: AgentUserInputRequest? = nil,
        goal: ThreadGoal? = nil,
        appServerSessionID: String? = nil,
        parentThreadID: String? = nil,
        isSubagent: Bool? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        canAcceptDirectInput: Bool? = nil,
        context: SessionContextSnapshot? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.project = project
        self.dir = dir
        self.title = title
        self.status = status
        self.source = source
        let normalizedRuntimeProvider = runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runtimeProvider = normalizedRuntimeProvider?.isEmpty == false ? normalizedRuntimeProvider : nil
        self.resumeID = resumeID
        self.createdAt = createdAt ?? context?.createdAt
        self.updatedAt = updatedAt
        self.recencyAt = recencyAt
        self.preview = preview
        self.activeTurnID = activeTurnID
        self.lastSeq = lastSeq
        self.revision = revision
        self.usage = usage
        self.rateLimit = rateLimit
        // pendingApproval 只在真实等待审批状态下有效；历史快照偶发带回旧值时，
        // 这里先做归一化，避免输入框展示已经失效的审批卡。
        self.pendingApproval = status == "waiting_for_approval" ? pendingApproval : nil
        self.pendingUserInput = status == "waiting_for_input" ? pendingUserInput : nil
        self.goal = goal ?? context?.goal
        self.appServerSessionID = appServerSessionID
        let normalizedParentThreadID = parentThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContextParentThreadID = context?.parentThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.parentThreadID = normalizedParentThreadID?.isEmpty == false
            ? normalizedParentThreadID
            : (normalizedContextParentThreadID?.isEmpty == false ? normalizedContextParentThreadID : nil)
        if isSubagent == true || context?.isSubagent == true || self.parentThreadID != nil {
            self.isSubagent = true
        } else {
            self.isSubagent = isSubagent ?? context?.isSubagent
        }
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.canAcceptDirectInput = canAcceptDirectInput
        self.context = context
    }

    init(row: DataFlowSessionRow) {
        // DataFlowSessionRow 是新列表模型；这里保留旧 AgentSession 入口，方便现有 UI 渐进迁移。
        self.init(
            id: row.id,
            projectID: row.projectID,
            project: row.projectName ?? "",
            dir: row.projectPath ?? "",
            title: row.title,
            status: row.status.rawValue,
            source: row.source,
            runtimeProvider: row.runtimeProvider,
            resumeID: row.resumeID,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            recencyAt: row.recencyAt,
            preview: row.preview,
            activeTurnID: row.activeTurnID,
            lastSeq: row.lastSeq,
            revision: row.revision,
            usage: row.usage,
            rateLimit: row.rateLimit,
            pendingApproval: row.pendingApproval,
            pendingUserInput: nil,
            goal: row.context?.goal,
            context: row.context
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case project
        case dir
        case title
        case status
        case source
        case runtimeProvider = "runtime_provider"
        case resumeID = "resume_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case recencyAt = "recency_at"
        case preview
        case activeTurnID = "active_turn_id"
        case lastSeq = "last_seq"
        case revision
        case usage
        case rateLimit = "rate_limit"
        case pendingApproval = "pending_approval"
        case pendingUserInput = "pending_user_input"
        case goal
        case appServerSessionID = "app_server_session_id"
        case parentThreadID = "parent_thread_id"
        case isSubagent = "is_subagent"
        case agentNickname = "agent_nickname"
        case agentRole = "agent_role"
        case canAcceptDirectInput = "can_accept_direct_input"
        case context
    }
}

enum SessionForegroundActivity: Equatable, Sendable {
    case refreshing
    case waitingForAssistant
    case receivingAssistant

    var title: String {
        switch self {
        case .refreshing:
            return L10n.text("ui.synchronizing")
        case .waitingForAssistant:
            return L10n.text("ui.waiting_for_reply")
        case .receivingAssistant:
            return L10n.text("ui.replying")
        }
    }

    var showsSpinner: Bool {
        switch self {
        case .refreshing, .waitingForAssistant:
            return true
        case .receivingAssistant:
            return false
        }
    }

    var displayStatus: AgentSessionDisplayStatus {
        switch self {
        case .refreshing:
            return AgentSessionDisplayStatus(title: title, systemImage: "arrow.triangle.2.circlepath", tone: .neutral, showsSpinner: true)
        case .waitingForAssistant:
            return AgentSessionDisplayStatus(title: title, systemImage: "hourglass", tone: .active, showsSpinner: true)
        case .receivingAssistant:
            return AgentSessionDisplayStatus(title: title, systemImage: "ellipsis.message.fill", tone: .active, showsSpinner: false)
        }
    }
}

enum AgentSessionStatusTone: String, Hashable {
    case active
    case warning
    case danger
    case complete
    case neutral
}

struct AgentSessionDisplayStatus: Hashable {
    let title: String
    let systemImage: String
    let tone: AgentSessionStatusTone
    let showsSpinner: Bool
}

struct AgentSessionStatusBadge: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let tone: AgentSessionStatusTone
}

struct RuntimeActivitySnapshot: Equatable {
    let turnStartedAt: Date
    let lastActivityAt: Date
}

struct RuntimeActivityDisplay: Equatable {
    let detailText: String
    let tone: AgentSessionStatusTone
    let systemImage: String

    static let freshThreshold: TimeInterval = 20
    static let staleThreshold: TimeInterval = 90

    static func make(
        snapshot: RuntimeActivitySnapshot?,
        webSocketStatus: WebSocketStatus,
        now: Date = Date()
    ) -> RuntimeActivityDisplay? {
        guard let snapshot else {
            return nil
        }
        // 这里表达的是“最近收到 runtime 事件”的证据，不判断命令是否真的卡死。
        // 长命令无输出时，用户看到的是无新事件时长和连接状态，避免误报。
        let runningText = L10n.format("ui.run_value", compactClockDuration(now.timeIntervalSince(snapshot.turnStartedAt)))
        let idleSeconds = max(0, now.timeIntervalSince(snapshot.lastActivityAt))

        switch webSocketStatus {
        case .connected:
            if idleSeconds <= freshThreshold {
                return RuntimeActivityDisplay(
                    detailText: L10n.format("ui.value_last_activity_value_ago", runningText, relativeDurationText(idleSeconds)),
                    tone: .active,
                    systemImage: "dot.radiowaves.left.and.right"
                )
            }
            if idleSeconds <= staleThreshold {
                return RuntimeActivityDisplay(
                    detailText: L10n.format("ui.value_waiting_for_output_value_no_new_events", runningText, relativeDurationText(idleSeconds)),
                    tone: .neutral,
                    systemImage: "hourglass"
                )
            }
            return RuntimeActivityDisplay(
                detailText: L10n.format("ui.value_the_connection_is_normal_value_no_new", runningText, relativeDurationText(idleSeconds)),
                tone: .warning,
                systemImage: "exclamationmark.triangle"
            )
        case .connecting:
            return RuntimeActivityDisplay(
                detailText: L10n.format("ui.value_reconnecting_unable_to_confirm_running_status", runningText),
                tone: .warning,
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
        case .disconnected, .failed:
            return RuntimeActivityDisplay(
                detailText: L10n.format("ui.value_connection_disconnected_unable_to_confirm_running_status", runningText),
                tone: .warning,
                systemImage: "wifi.slash"
            )
        case .terminated(let reason):
            return RuntimeActivityDisplay(
                detailText: L10n.format("ui.value_value_unable_to_confirm_running_status", runningText, reason.title),
                tone: .warning,
                systemImage: "lock.trianglebadge.exclamationmark"
            )
        }
    }

    static func compactClockDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3_600
        let minutes = seconds / 60 % 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    static func relativeDurationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 {
            return L10n.plural("ui.seconds_count", count: seconds)
        }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? L10n.plural("ui.minutes_count", count: minutes) : "\(minutes)m \(remainingSeconds)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? L10n.plural("ui.hours_count", count: hours) : "\(hours)h \(remainingMinutes)m"
    }
}

extension AgentSession {
    func displayStatus(foregroundActivity: SessionForegroundActivity?) -> AgentSessionDisplayStatus {
        // 侧栏和对话顶部共用这套优先级，避免同一个会话在不同入口显示成两种状态。
        // 审批/输入是需要用户处理的状态，优先级高于流式输出；foreground activity 负责区分等待回复和正在回复。
        if isLocalDraft {
            return AgentSessionDisplayStatus(title: L10n.text("ui.new_session"), systemImage: "square.and.pencil", tone: .neutral, showsSpinner: false)
        }
        if status == SessionStatus.waitingForApproval.rawValue || pendingApproval != nil {
            return AgentSessionDisplayStatus(title: L10n.text("ui.pending_approval"), systemImage: "checkmark.seal.fill", tone: .warning, showsSpinner: false)
        }
        if status == SessionStatus.waitingForInput.rawValue || pendingUserInput != nil {
            return AgentSessionDisplayStatus(title: L10n.text("ui.to_be_entered"), systemImage: "keyboard", tone: .warning, showsSpinner: false)
        }
        if let foregroundActivity {
            return foregroundActivity.displayStatus
        }
        if activeTurnID != nil {
            return AgentSessionDisplayStatus(title: L10n.text("ui.processing"), systemImage: "bolt.fill", tone: .active, showsSpinner: false)
        }

        switch status {
        case SessionStatus.running.rawValue:
            return AgentSessionDisplayStatus(title: L10n.text("ui.running"), systemImage: "circle.dotted", tone: .active, showsSpinner: true)
        case SessionStatus.history.rawValue:
            return AgentSessionDisplayStatus(title: L10n.text("ui.history"), systemImage: "clock.arrow.circlepath", tone: .neutral, showsSpinner: false)
        case SessionStatus.completed.rawValue:
            return AgentSessionDisplayStatus(title: L10n.text("ui.complete"), systemImage: "checkmark.circle", tone: .complete, showsSpinner: false)
        case SessionStatus.failed.rawValue:
            return AgentSessionDisplayStatus(title: L10n.text("ui.failed_status"), systemImage: "exclamationmark.triangle.fill", tone: .danger, showsSpinner: false)
        case SessionStatus.closed.rawValue:
            return AgentSessionDisplayStatus(title: L10n.text("ui.ended"), systemImage: "checkmark.circle", tone: .neutral, showsSpinner: false)
        case SessionStatus.idle.rawValue:
            return AgentSessionDisplayStatus(title: L10n.text("ui.free"), systemImage: "pause.circle", tone: .neutral, showsSpinner: false)
        case SessionStatus.unknown.rawValue, "":
            return AgentSessionDisplayStatus(title: L10n.text("ui.status_awaiting_confirmation"), systemImage: "circle", tone: .neutral, showsSpinner: false)
        default:
            let text = status.replacingOccurrences(of: "_", with: " ")
            return AgentSessionDisplayStatus(title: text, systemImage: "circle", tone: .neutral, showsSpinner: false)
        }
    }

    func statusBadges(foregroundActivity: SessionForegroundActivity?) -> [AgentSessionStatusBadge] {
        var badges: [AgentSessionStatusBadge] = []
        if activeTurnID != nil {
            badges.append(AgentSessionStatusBadge(id: "active-turn", title: L10n.text("ui.round_in_progress"), systemImage: "bolt.fill", tone: .active))
        }
        if let approval = pendingApproval {
            badges.append(AgentSessionStatusBadge(id: "approval-\(approval.id)", title: L10n.format("ui.approval_value", approval.title), systemImage: "checkmark.seal", tone: .warning))
        } else if let userInput = pendingUserInput {
            badges.append(AgentSessionStatusBadge(id: "input-\(userInput.id)", title: L10n.format("ui.boot_value", userInput.title), systemImage: "questionmark.bubble", tone: .warning))
        } else if status == SessionStatus.waitingForInput.rawValue {
            badges.append(AgentSessionStatusBadge(id: "waiting-input", title: L10n.text("ui.waiting_for_input"), systemImage: "keyboard", tone: .warning))
        }
        if let foregroundActivity {
            badges.append(AgentSessionStatusBadge(id: "foreground-\(foregroundActivity.title)", title: foregroundActivity.title, systemImage: foregroundActivity.displayStatus.systemImage, tone: foregroundActivity.displayStatus.tone))
        }
        if let goal {
            badges.append(AgentSessionStatusBadge(id: "goal-\(goal.threadID)-\(goal.status.rawValue)", title: L10n.format("ui.target_value", goal.sidebarProgressText), systemImage: "target", tone: goal.status.sessionStatusTone))
        }
        if let usage = usage?.compactText {
            badges.append(AgentSessionStatusBadge(id: "usage-\(usage)", title: usage, systemImage: "gauge.with.dots.needle.33percent", tone: .neutral))
        }
        if let rateLimit = rateLimit?.compactText {
            badges.append(AgentSessionStatusBadge(id: "rate-\(rateLimit)", title: rateLimit, systemImage: "speedometer", tone: .neutral))
        }
        return badges
    }
}

enum ThreadGoalStatus: String, Codable, Hashable, CaseIterable {
    case active
    case paused
    case blocked
    case usageLimited
    case budgetLimited
    case complete

    var displayText: String {
        switch self {
        case .active:
            return L10n.text("ui.running")
        case .paused:
            return L10n.text("ui.suspended")
        case .blocked:
            return L10n.text("ui.blocked_059c4d40")
        case .usageLimited:
            return L10n.text("ui.dosage_limited")
        case .budgetLimited:
            return L10n.text("ui.budget_exhausted")
        case .complete:
            return L10n.text("ui.completed_status")
        }
    }

    var tintRole: String {
        switch self {
        case .active:
            return "success"
        case .blocked, .usageLimited, .budgetLimited:
            return "warning"
        case .complete:
            return "complete"
        case .paused:
            return "neutral"
        }
    }

    var sessionStatusTone: AgentSessionStatusTone {
        switch self {
        case .active:
            return .active
        case .blocked, .usageLimited, .budgetLimited:
            return .warning
        case .complete:
            return .complete
        case .paused:
            return .neutral
        }
    }
}

struct ThreadGoal: Identifiable, Codable, Hashable {
    var id: String { threadID }

    let threadID: SessionID
    let objective: String
    let status: ThreadGoalStatus
    let tokenBudget: Int64?
    let tokensUsed: Int64
    let timeUsedSeconds: Int64
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case objective
        case status
        case tokenBudget
        case tokensUsed
        case timeUsedSeconds
        case createdAt
        case updatedAt
    }

    private enum SnakeCodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case tokenBudget = "token_budget"
        case tokensUsed = "tokens_used"
        case timeUsedSeconds = "time_used_seconds"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        threadID: SessionID,
        objective: String,
        status: ThreadGoalStatus,
        tokenBudget: Int64? = nil,
        tokensUsed: Int64 = 0,
        timeUsedSeconds: Int64 = 0,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.threadID = threadID
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init?(object: [String: CodexAppServerJSONValue]) {
        guard
            let threadID = object["threadId"]?.stringValue ?? object["thread_id"]?.stringValue,
            let rawObjective = object["objective"]?.stringValue,
            let rawStatus = object["status"]?.stringValue,
            let status = ThreadGoalStatus(rawValue: rawStatus)
        else {
            return nil
        }
        let objective = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty, !objective.isEmpty else {
            return nil
        }
        self.init(
            threadID: threadID,
            objective: objective,
            status: status,
            tokenBudget: Self.int64(from: object["tokenBudget"] ?? object["token_budget"]),
            tokensUsed: Self.int64(from: object["tokensUsed"] ?? object["tokens_used"]) ?? 0,
            timeUsedSeconds: Self.int64(from: object["timeUsedSeconds"] ?? object["time_used_seconds"]) ?? 0,
            createdAt: Self.date(from: object["createdAt"] ?? object["created_at"]),
            updatedAt: Self.date(from: object["updatedAt"] ?? object["updated_at"])
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snake = try decoder.container(keyedBy: SnakeCodingKeys.self)
        self.threadID = try container.decodeIfPresent(SessionID.self, forKey: .threadID)
            ?? snake.decode(SessionID.self, forKey: .threadID)
        self.objective = try container.decode(String.self, forKey: .objective)
        self.status = try container.decode(ThreadGoalStatus.self, forKey: .status)
        self.tokenBudget = try container.decodeIfPresent(Int64.self, forKey: .tokenBudget)
            ?? snake.decodeIfPresent(Int64.self, forKey: .tokenBudget)
        self.tokensUsed = try container.decodeIfPresent(Int64.self, forKey: .tokensUsed)
            ?? snake.decodeIfPresent(Int64.self, forKey: .tokensUsed)
            ?? 0
        self.timeUsedSeconds = try container.decodeIfPresent(Int64.self, forKey: .timeUsedSeconds)
            ?? snake.decodeIfPresent(Int64.self, forKey: .timeUsedSeconds)
            ?? 0
        self.createdAt = try Self.decodeFlexibleDate(container, key: .createdAt)
            ?? Self.decodeFlexibleDate(snake, key: .createdAt)
        self.updatedAt = try Self.decodeFlexibleDate(container, key: .updatedAt)
            ?? Self.decodeFlexibleDate(snake, key: .updatedAt)
    }

    var progressText: String {
        guard let tokenBudget else {
            return "\(Self.compactNumber(tokensUsed)) tokens"
        }
        return "\(Self.compactNumber(tokensUsed)) / \(Self.compactNumber(tokenBudget)) tokens"
    }

    var budgetProgressFraction: Double? {
        guard let tokenBudget, tokenBudget > 0 else {
            return nil
        }
        // 进度条只接受 0...1；百分比另算，保留超预算的真实比例提示。
        let ratio = Double(max(0, tokensUsed)) / Double(tokenBudget)
        return min(max(ratio, 0), 1)
    }

    var budgetPercentText: String? {
        guard let tokenBudget, tokenBudget > 0 else {
            return nil
        }
        let ratio = Double(max(0, tokensUsed)) / Double(tokenBudget)
        return "\(Int((ratio * 100).rounded()))%"
    }

    var sidebarProgressText: String {
        if let budgetPercentText {
            return "\(status.displayText) \(budgetPercentText)"
        }
        return status.displayText
    }

    var elapsedText: String {
        Self.durationText(seconds: timeUsedSeconds)
    }

    private static func int64(from value: CodexAppServerJSONValue?) -> Int64? {
        switch value {
        case .int(let number):
            return number
        case .double(let number):
            return number.isFinite ? Int64(number) : nil
        case .string(let text):
            return Int64(text)
        default:
            return nil
        }
    }

    private static func date(from value: CodexAppServerJSONValue?) -> Date? {
        switch value {
        case .int(let number):
            return date(fromNumericSeconds: Double(number))
        case .double(let number):
            return date(fromNumericSeconds: number)
        case .string(let text):
            return date(from: text)
        default:
            return nil
        }
    }

    private static func date(from text: String) -> Date? {
        if let number = Double(text) {
            return date(fromNumericSeconds: number)
        }
        if let date = iso8601Fractional.date(from: text) ?? iso8601.date(from: text) {
            return date
        }
        return nil
    }

    private static func date(fromNumericSeconds value: Double) -> Date? {
        guard value.isFinite, value > 0 else {
            return nil
        }
        // app-server 版本可能用秒，也可能经 JSON 桥接成毫秒；这里按数量级兼容。
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func decodeFlexibleDate<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        key: K
    ) throws -> Date? {
        if let date = try? container.decodeIfPresent(Date.self, forKey: key) {
            return date
        }
        if let number = try? container.decodeIfPresent(Double.self, forKey: key) {
            return date(fromNumericSeconds: number)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return date(from: text)
        }
        return nil
    }

    private static func compactNumber(_ value: Int64) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if absolute >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private static func durationText(seconds: Int64) -> String {
        if seconds >= 3_600 {
            return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
        }
        if seconds >= 60 {
            return "\(seconds / 60)m"
        }
        return "\(max(0, seconds))s"
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

enum ConversationTurnLifecycle: String, Codable, Hashable {
    case inProgress
    case completed
    case interrupted
    case failed
    case unknown

    var isTerminal: Bool {
        self == .completed || self == .interrupted || self == .failed
    }
}

struct CodexHistoryMessage: Identifiable, Codable, Hashable {
    var id: MessageID
    let role: String
    let kind: MessageKind
    let content: String
    let turnPayload: CodexAppServerTurnPayload?
    let activityPayload: ConversationActivityPayload?
    let createdAt: Date?
    let updatedAt: Date?
    let clientMessageID: ClientMessageID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    let seq: EventSequence?
    let revision: ModelRevision?
    let sendStatus: MessageSendStatus?
    let timelineOrdinal: Int64?
    let turnLifecycle: ConversationTurnLifecycle?
    let userDelivery: UserMessageDelivery?
    let isTimestampFallback: Bool

    init(
        id: MessageID = UUID().uuidString,
        role: String,
        kind: MessageKind = .message,
        content: String,
        turnPayload: CodexAppServerTurnPayload? = nil,
        activityPayload: ConversationActivityPayload? = nil,
        createdAt: Date?,
        updatedAt: Date? = nil,
        clientMessageID: ClientMessageID? = nil,
        turnID: TurnID? = nil,
        itemID: AgentItemID? = nil,
        seq: EventSequence? = nil,
        revision: ModelRevision? = nil,
        sendStatus: MessageSendStatus? = nil,
        timelineOrdinal: Int64? = nil,
        turnLifecycle: ConversationTurnLifecycle? = nil,
        userDelivery: UserMessageDelivery? = nil,
        isTimestampFallback: Bool = false
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.content = content
        self.turnPayload = turnPayload
        self.activityPayload = activityPayload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.clientMessageID = clientMessageID
        self.turnID = turnID
        self.itemID = itemID
        self.seq = seq
        self.revision = revision
        self.sendStatus = sendStatus
        self.timelineOrdinal = timelineOrdinal
        self.turnLifecycle = turnLifecycle
        self.userDelivery = userDelivery
        self.isTimestampFallback = isTimestampFallback
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case kind
        case content
        case turnPayload = "turn_payload"
        case activityPayload = "activity_payload"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case clientMessageID = "client_message_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case seq
        case revision
        case sendStatus = "send_status"
        case timelineOrdinal = "timeline_ordinal"
        case turnLifecycle = "turn_lifecycle"
        case userDelivery = "user_delivery"
        case isTimestampFallback = "is_timestamp_fallback"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(String.self, forKey: .role)
        let content = try container.decode(String.self, forKey: .content)
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        let updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        let clientMessageID = try container.decodeIfPresent(ClientMessageID.self, forKey: .clientMessageID)
        self.init(
            id: try container.decodeIfPresent(MessageID.self, forKey: .id) ?? clientMessageID ?? UUID().uuidString,
            role: role,
            kind: try container.decodeIfPresent(MessageKind.self, forKey: .kind) ?? .message,
            content: content,
            turnPayload: try container.decodeIfPresent(CodexAppServerTurnPayload.self, forKey: .turnPayload),
            activityPayload: try container.decodeIfPresent(ConversationActivityPayload.self, forKey: .activityPayload),
            createdAt: createdAt,
            updatedAt: updatedAt,
            clientMessageID: clientMessageID,
            turnID: try container.decodeIfPresent(TurnID.self, forKey: .turnID),
            itemID: try container.decodeIfPresent(AgentItemID.self, forKey: .itemID),
            seq: try container.decodeIfPresent(EventSequence.self, forKey: .seq),
            revision: try container.decodeIfPresent(ModelRevision.self, forKey: .revision),
            sendStatus: try container.decodeIfPresent(MessageSendStatus.self, forKey: .sendStatus),
            timelineOrdinal: try container.decodeIfPresent(Int64.self, forKey: .timelineOrdinal),
            turnLifecycle: try container.decodeIfPresent(ConversationTurnLifecycle.self, forKey: .turnLifecycle),
            userDelivery: try container.decodeIfPresent(UserMessageDelivery.self, forKey: .userDelivery),
            isTimestampFallback: try container.decodeIfPresent(Bool.self, forKey: .isTimestampFallback) ?? false
        )
    }

    func withTimestampFallback(createdAt: Date, updatedAt: Date? = nil) -> CodexHistoryMessage {
        CodexHistoryMessage(
            id: id,
            role: role,
            kind: kind,
            content: content,
            turnPayload: turnPayload,
            activityPayload: activityPayload,
            createdAt: createdAt,
            updatedAt: updatedAt ?? self.updatedAt,
            clientMessageID: clientMessageID,
            turnID: turnID,
            itemID: itemID,
            seq: seq,
            revision: revision,
            sendStatus: sendStatus,
            timelineOrdinal: timelineOrdinal,
            turnLifecycle: turnLifecycle,
            userDelivery: userDelivery,
            isTimestampFallback: true
        )
    }

    func withTurnLifecycle(_ lifecycle: ConversationTurnLifecycle) -> CodexHistoryMessage {
        CodexHistoryMessage(
            id: id,
            role: role,
            kind: kind,
            content: content,
            turnPayload: turnPayload,
            activityPayload: activityPayload,
            createdAt: createdAt,
            updatedAt: updatedAt,
            clientMessageID: clientMessageID,
            turnID: turnID,
            itemID: itemID,
            seq: seq,
            revision: revision,
            sendStatus: sendStatus,
            timelineOrdinal: timelineOrdinal,
            turnLifecycle: lifecycle,
            userDelivery: userDelivery,
            isTimestampFallback: isTimestampFallback
        )
    }
}

struct ConversationMessageRenderFingerprint: Hashable {
    let contentRevision: UInt64
    let contentDigest: UInt64
    let contentByteCount: Int
}

enum ConversationImageItemProjection {
    static func markdownContent(from item: [String: CodexAppServerJSONValue]) -> String? {
        let title: String
        let source: String?
        switch item["type"]?.stringValue {
        case "imageGeneration":
            title = L10n.text("ui.generated_image")
            let result = item["result"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            // gateway 会把生成图的大段 base64 改写成短 history-media URL；若改写被关闭，
            // 优先回退 savedPath，避免再把 1-2 MB base64 塞进 Markdown 和 SwiftUI diff。
            source = result.flatMap(supportedImageSource) ?? firstNonEmptyPath(in: item, keys: ["savedPath", "saved_path"])
        case "imageView":
            title = L10n.text("ui.screenshot")
            source = firstNonEmptyPath(in: item, keys: ["path"])
        default:
            return nil
        }
        guard let source else {
            return nil
        }
        let destination = source.hasPrefix("/") ? URL(fileURLWithPath: source).absoluteString : source
        return "![\(title)](\(destination))"
    }

    private static func supportedImageSource(_ value: String) -> String? {
        guard !value.isEmpty else {
            return nil
        }
        if value.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil ||
            value.hasPrefix("agentd-history-media://") ||
            value.hasPrefix("/") {
            return value
        }
        guard let scheme = URL(string: value)?.scheme?.lowercased(),
              ["file", "http", "https"].contains(scheme) else {
            return nil
        }
        return value
    }

    private static func firstNonEmptyPath(
        in item: [String: CodexAppServerJSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = item[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

struct MessageRenderPlan: Hashable {
    let messageKey: String
    let content: String
    let contentDigest: UInt64
    let contentByteCount: Int
    let blocks: [MarkdownBlock]
    let openTailByteOffset: Int
    let isProvisionalPlainStreaming: Bool

    var isSinglePlainParagraph: Bool {
        guard blocks.count == 1, case let .paragraph(inline) = blocks[0].kind else {
            return false
        }
        return !inline.hasFormatting
    }
}

@MainActor
final class MessageRenderPlanCache {
    static let shared = MessageRenderPlanCache()

    private let limit: Int
    private let byteLimit: Int
    private let streamingPlainTextThreshold: Int
    private var plansByMessageKey: [String: MessageRenderPlan] = [:]
    private var accessOrder: [String] = []
    private var cachedContentByteCount = 0

#if DEBUG
    private(set) var incrementalReuseCountForTesting = 0
    private(set) var markdownParseInvocationCountForTesting = 0
    var cachedContentByteCountForTesting: Int { cachedContentByteCount }
    var cachedPlanCountForTesting: Int { plansByMessageKey.count }
#endif

    init(
        limit: Int = 256,
        byteLimit: Int = 16 * 1_024 * 1_024,
        streamingPlainTextThreshold: Int = 4 * 1_024
    ) {
        self.limit = max(1, limit)
        self.byteLimit = max(1, byteLimit)
        self.streamingPlainTextThreshold = max(256, streamingPlainTextThreshold)
    }

    func plan(for message: ConversationMessage) -> MessageRenderPlan {
        plan(for: message, rendering: message.content)
    }

    func plan(for message: ConversationMessage, rendering content: String) -> MessageRenderPlan {
        let messageKey = message.stableID ?? message.clientMessageID ?? message.id.uuidString
        let fingerprint = content == message.content
            ? (digest: message.contentDigest, byteCount: message.contentByteCount)
            : makeContentFingerprint(content)
        return plan(
            messageKey: messageKey,
            content: content,
            contentDigest: fingerprint.digest,
            contentByteCount: fingerprint.byteCount,
            isStreaming: message.role == .assistant && message.sendStatus == .sending
        )
    }

    func plan(
        messageKey: String,
        content: String,
        contentDigest: UInt64,
        contentByteCount: Int,
        isStreaming: Bool = false
    ) -> MessageRenderPlan {
        if let cached = plansByMessageKey[messageKey],
           cached.contentDigest == contentDigest,
           cached.contentByteCount == contentByteCount,
           isStreaming || !cached.isProvisionalPlainStreaming {
            touch(messageKey)
            return cached
        }

        let plan: MessageRenderPlan
        if let cached = plansByMessageKey[messageKey],
           cached.isProvisionalPlainStreaming,
           !isStreaming {
            // streaming 结束必须完整解析一次，不能把临时纯文本计划当成最终 Markdown。
            plan = parse(messageKey: messageKey, content: content, contentDigest: contentDigest, contentByteCount: contentByteCount)
        } else if let cached = plansByMessageKey[messageKey],
                  isStreaming,
                  contentByteCount >= streamingPlainTextThreshold,
                  cached.isSinglePlainParagraph,
                  content.hasPrefix(cached.content),
                  isPlainStreamingSuffix(content.utf8.dropFirst(cached.contentByteCount)) {
            // 超长单段回复在流式阶段最容易让开放尾块每帧全量重解析。此时纯文本视觉语义
            // 与原段落一致；完成事件到达后再执行最终 Markdown 解析。
            plan = provisionalPlainStreamingPlan(
                messageKey: messageKey,
                content: content,
                contentDigest: contentDigest,
                contentByteCount: contentByteCount
            )
        } else if let cached = plansByMessageKey[messageKey],
           content.hasPrefix(cached.content),
           contentByteCount >= cached.contentByteCount {
            plan = extend(cached, content: content, contentDigest: contentDigest, contentByteCount: contentByteCount)
#if DEBUG
            incrementalReuseCountForTesting += 1
#endif
        } else {
            plan = parse(messageKey: messageKey, content: content, contentDigest: contentDigest, contentByteCount: contentByteCount)
        }

        if let replaced = plansByMessageKey[messageKey] {
            cachedContentByteCount -= replaced.contentByteCount
        }
        plansByMessageKey[messageKey] = plan
        cachedContentByteCount += plan.contentByteCount
        touch(messageKey)
        trimIfNeeded()
        return plan
    }

    private func extend(
        _ cached: MessageRenderPlan,
        content: String,
        contentDigest: UInt64,
        contentByteCount: Int
    ) -> MessageRenderPlan {
        guard content != cached.content else {
            return MessageRenderPlan(
                messageKey: cached.messageKey,
                content: content,
                contentDigest: contentDigest,
                contentByteCount: contentByteCount,
                blocks: cached.blocks,
                openTailByteOffset: cached.openTailByteOffset,
                isProvisionalPlainStreaming: false
            )
        }

        let safeTailStart = min(cached.openTailByteOffset, contentByteCount)
        // 只复用稳定前缀块，尾部开放块交给 swift-markdown 重算；
        // 这样列表续行、表格分隔行、未闭合代码围栏都能在下一帧自然收敛。
        let reusableBlocks = cached.blocks.filter { block in
            guard let range = block.sourceByteRange else {
                return false
            }
            return range.upperBound > range.lowerBound && range.upperBound <= safeTailStart
        }
        let tail = String(decoding: content.utf8.dropFirst(safeTailStart), as: UTF8.self)
        let parsedTail = MarkdownParser.shared.parse(tail, baseByteOffset: safeTailStart)
        let mergedBlocks = renumber(reusableBlocks + parsedTail.blocks)

        return MessageRenderPlan(
            messageKey: cached.messageKey,
            content: content,
            contentDigest: contentDigest,
            contentByteCount: contentByteCount,
            blocks: mergedBlocks,
            openTailByteOffset: parsedTail.openTailByteOffset,
            isProvisionalPlainStreaming: false
        )
    }

    private func parse(messageKey: String, content: String, contentDigest: UInt64, contentByteCount: Int) -> MessageRenderPlan {
#if DEBUG
        markdownParseInvocationCountForTesting += 1
#endif
        let parsed = MarkdownParser.shared.parse(content)
        return MessageRenderPlan(
            messageKey: messageKey,
            content: content,
            contentDigest: contentDigest,
            contentByteCount: contentByteCount,
            blocks: parsed.blocks,
            openTailByteOffset: parsed.openTailByteOffset,
            isProvisionalPlainStreaming: false
        )
    }

    private func provisionalPlainStreamingPlan(
        messageKey: String,
        content: String,
        contentDigest: UInt64,
        contentByteCount: Int
    ) -> MessageRenderPlan {
        let inline = MarkdownInlineText(
            attributed: AttributedString(content),
            plain: content,
            hasFormatting: false
        )
        return MessageRenderPlan(
            messageKey: messageKey,
            content: content,
            contentDigest: contentDigest,
            contentByteCount: contentByteCount,
            blocks: [MarkdownBlock(id: 0, sourceByteRange: 0..<contentByteCount, kind: .paragraph(inline))],
            // 0 表示完成时不能复用这个临时块，必须从头解析最终 Markdown。
            openTailByteOffset: 0,
            isProvisionalPlainStreaming: true
        )
    }

    private func isPlainStreamingSuffix(_ bytes: String.UTF8View.SubSequence) -> Bool {
        // 只对确定没有 Markdown 结构的增量走临时纯文本快路径；一旦出现换行或语法标记，
        // 立即回到增量 Markdown 解析，保证代码块、列表、链接等流式展示行为不变。
        return !bytes.contains { byte in
            switch byte {
            case 0x0A, // 换行
                 0x23, // #
                 0x2A, // *
                 0x2B, // +
                 0x2D, // -
                 0x3E, // >
                 0x5B, // [
                 0x5D, // ]
                 0x5F, // _
                 0x60, // `
                 0x7C, // |
                 0x7E: // ~
                return true
            default:
                return false
            }
        }
    }

    private func makeContentFingerprint(_ content: String) -> (digest: UInt64, byteCount: Int) {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var byteCount = 0
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
            byteCount += 1
        }
        return (hash, byteCount)
    }

    private func renumber(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        blocks.enumerated().map { index, block in
            MarkdownBlock(id: index, sourceByteRange: block.sourceByteRange, kind: block.kind)
        }
    }

    private func touch(_ messageKey: String) {
        accessOrder.removeAll { $0 == messageKey }
        accessOrder.append(messageKey)
    }

    private func trimIfNeeded() {
        while (accessOrder.count > limit || cachedContentByteCount > byteLimit),
              let oldest = accessOrder.first {
            accessOrder.removeFirst()
            if let removed = plansByMessageKey.removeValue(forKey: oldest) {
                cachedContentByteCount -= removed.contentByteCount
            }
        }
    }
}

struct ConversationFileReference: Identifiable, Hashable {
    let path: String
    let name: String

    var id: String { path }
}

enum ConversationFileReferenceDetector {
    private static let previewExtensions: Set<String> = [
        "csv", "doc", "docx", "gif", "heic", "html", "jpeg", "jpg", "json", "log",
        "md", "numbers", "pages", "pdf", "png", "ppt", "pptx", "rtf", "txt", "webp",
        "xls", "xlsx", "yaml", "yml", "zip"
    ]
    private static let imageExtensions: Set<String> = ["gif", "heic", "jpeg", "jpg", "png", "webp"]
    private static let edgeTrimCharacters = CharacterSet(charactersIn: "`\"'“”‘’()[]{}<>.,;")
    private static let pathStartBoundaryCharacters = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "`\"'“”‘’([{<：:，,;；"))
    private static let candidateStopCharacters = CharacterSet.newlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "`\"'“”‘’<>"))
    private static let extensionTerminatorCharacters = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "`\"'“”‘’()[]{}<>,;:.!?。！？、，；："))

    static func references(in text: String, limit: Int = 5) -> [ConversationFileReference] {
        references(in: text, limit: limit, allowedExtensions: previewExtensions)
    }

    static func imageReferences(in text: String, limit: Int = 5) -> [ConversationFileReference] {
        references(in: text, limit: limit, allowedExtensions: imageExtensions)
    }

    private static func references(
        in text: String,
        limit: Int,
        allowedExtensions: Set<String>
    ) -> [ConversationFileReference] {
        guard limit > 0 else {
            return []
        }

        var result: [ConversationFileReference] = []
        var seen = Set<String>()
        for candidate in pathCandidates(in: text, allowedExtensions: allowedExtensions) {
            guard let path = normalizedPathCandidate(candidate) else {
                continue
            }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard allowedExtensions.contains(ext), seen.insert(path).inserted else {
                continue
            }
            result.append(ConversationFileReference(path: path, name: URL(fileURLWithPath: path).lastPathComponent))
            if result.count >= limit {
                break
            }
        }
        return result
    }

    private static func pathCandidates(in text: String, allowedExtensions: Set<String>) -> [String] {
        let extensions = allowedExtensions
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }

        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard isPathStart(in: text, at: index) else {
                index = text.index(after: index)
                continue
            }

            if let candidate = pathCandidate(in: text, start: index, allowedExtensions: extensions) {
                result.append(candidate.value)
                index = candidate.end
            } else {
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func pathCandidate(
        in text: String,
        start: String.Index,
        allowedExtensions: [String]
    ) -> (value: String, end: String.Index)? {
        var index = start
        while index < text.endIndex {
            if index != start, isPathStart(in: text, at: index) {
                return nil
            }

            let character = text[index]
            if characterBelongsToSet(character, candidateStopCharacters) {
                return nil
            }

            if character == "." {
                let extensionStart = text.index(after: index)
                for ext in allowedExtensions where hasCaseInsensitivePrefix(ext, in: text, at: extensionStart) {
                    guard let extensionEnd = text.index(extensionStart, offsetBy: ext.count, limitedBy: text.endIndex),
                          isExtensionTerminator(in: text, at: extensionEnd)
                    else {
                        continue
                    }
                    return (String(text[start..<extensionEnd]), extensionEnd)
                }
            }

            index = text.index(after: index)
        }
        return nil
    }

    private static func isPathStart(in text: String, at index: String.Index) -> Bool {
        guard hasPathStartBoundary(in: text, at: index) else {
            return false
        }
        if hasCaseInsensitivePrefix("file://", in: text, at: index) {
            return true
        }
        guard text[index] == "/" else {
            return false
        }
        let nextIndex = text.index(after: index)
        if nextIndex < text.endIndex, text[nextIndex] == "/" {
            return false
        }
        return true
    }

    private static func hasPathStartBoundary(in text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else {
            return true
        }
        let previousIndex = text.index(before: index)
        return characterBelongsToSet(text[previousIndex], pathStartBoundaryCharacters)
    }

    private static func isExtensionTerminator(in text: String, at index: String.Index) -> Bool {
        guard index < text.endIndex else {
            return true
        }
        let character = text[index]
        return character == "?"
            || character == "#"
            || characterBelongsToSet(character, extensionTerminatorCharacters)
    }

    private static func hasCaseInsensitivePrefix(_ prefix: String, in text: String, at index: String.Index) -> Bool {
        guard let end = text.index(index, offsetBy: prefix.count, limitedBy: text.endIndex) else {
            return false
        }
        return text[index..<end].lowercased() == prefix.lowercased()
    }

    private static func characterBelongsToSet(_ character: Character, _ set: CharacterSet) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return set.contains(scalar)
    }

    private static func normalizedPathCandidate(_ raw: String) -> String? {
        var token = raw.trimmingCharacters(in: edgeTrimCharacters)
        guard !token.isEmpty else {
            return nil
        }
        if let queryIndex = token.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            token = String(token[..<queryIndex])
        }
        if token.lowercased().hasPrefix("file://") {
            let rawPath = String(token.dropFirst("file://".count))
            if rawPath.hasPrefix("/") {
                token = rawPath.removingPercentEncoding ?? rawPath
            } else {
                guard let url = URL(string: token), url.isFileURL else {
                    return nil
                }
                token = url.path
            }
        }
        token = stripLineSuffix(from: token)
        guard token.hasPrefix("/"), token.count > 1, !token.contains("\u{0}") else {
            return nil
        }
        return token.replacingOccurrences(of: "\\ ", with: " ")
    }

    private static func stripLineSuffix(from token: String) -> String {
        guard let colonIndex = token.lastIndex(of: ":") else {
            return token
        }
        let suffix = token[token.index(after: colonIndex)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else {
            return token
        }
        return String(token[..<colonIndex])
    }
}

struct ConversationMessage: Identifiable, Hashable {
    enum Role: String {
        case user
        case assistant
        case system
    }

    let id: UUID
    var stableID: MessageID?
    let clientMessageID: ClientMessageID?
    var turnID: TurnID?
    var itemID: AgentItemID?
    var role: Role
    var kind: MessageKind
    var content: String {
        didSet {
            if let appendedContentForFingerprint {
                updateRenderFingerprint(appending: appendedContentForFingerprint)
            } else {
                updateRenderFingerprint()
            }
        }
    }
    var createdAt: Date
    var updatedAt: Date?
    var sendStatus: MessageSendStatus
    var revision: ModelRevision?
    var turnPayload: CodexAppServerTurnPayload?
    var activityPayload: ConversationActivityPayload?
    var timelineOrdinal: Int64?
    var turnLifecycle: ConversationTurnLifecycle?
    var userDelivery: UserMessageDelivery?
    var isTimestampFallback: Bool
    private(set) var contentRevision: UInt64
    private(set) var contentDigest: UInt64
    private(set) var contentByteCount: Int
    private var appendedContentForFingerprint: String?

    var renderFingerprint: ConversationMessageRenderFingerprint {
        ConversationMessageRenderFingerprint(
            contentRevision: contentRevision,
            contentDigest: contentDigest,
            contentByteCount: contentByteCount
        )
    }

    init(
        id: UUID = UUID(),
        stableID: MessageID? = nil,
        clientMessageID: ClientMessageID? = nil,
        turnID: TurnID? = nil,
        itemID: AgentItemID? = nil,
        role: Role,
        kind: MessageKind = .message,
        content: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        sendStatus: MessageSendStatus = .sent,
        revision: ModelRevision? = nil,
        turnPayload: CodexAppServerTurnPayload? = nil,
        activityPayload: ConversationActivityPayload? = nil,
        timelineOrdinal: Int64? = nil,
        turnLifecycle: ConversationTurnLifecycle? = nil,
        userDelivery: UserMessageDelivery? = nil,
        isTimestampFallback: Bool = false
    ) {
        self.id = id
        self.stableID = stableID
        self.clientMessageID = clientMessageID
        self.turnID = turnID
        self.itemID = itemID
        self.role = role
        self.kind = kind
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sendStatus = sendStatus
        self.revision = revision
        self.turnPayload = turnPayload
        self.activityPayload = activityPayload
        self.timelineOrdinal = timelineOrdinal
        self.turnLifecycle = turnLifecycle
        self.userDelivery = userDelivery
        self.isTimestampFallback = isTimestampFallback
        self.appendedContentForFingerprint = nil
        let fingerprint = Self.makeRenderFingerprint(for: content)
        self.contentRevision = 0
        self.contentDigest = fingerprint.digest
        self.contentByteCount = fingerprint.byteCount
    }

    static func == (lhs: ConversationMessage, rhs: ConversationMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.stableID == rhs.stableID
            && lhs.clientMessageID == rhs.clientMessageID
            && lhs.turnID == rhs.turnID
            && lhs.itemID == rhs.itemID
            && lhs.role == rhs.role
            && lhs.kind == rhs.kind
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.sendStatus == rhs.sendStatus
            && lhs.revision == rhs.revision
            && lhs.turnPayload == rhs.turnPayload
            && lhs.activityPayload == rhs.activityPayload
            && lhs.timelineOrdinal == rhs.timelineOrdinal
            && lhs.turnLifecycle == rhs.turnLifecycle
            && lhs.userDelivery == rhs.userDelivery
            && lhs.isTimestampFallback == rhs.isTimestampFallback
            && lhs.contentDigest == rhs.contentDigest
            && lhs.contentByteCount == rhs.contentByteCount
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(stableID)
        hasher.combine(clientMessageID)
        hasher.combine(turnID)
        hasher.combine(itemID)
        hasher.combine(role)
        hasher.combine(kind)
        hasher.combine(createdAt)
        hasher.combine(updatedAt)
        hasher.combine(sendStatus)
        hasher.combine(revision)
        hasher.combine(turnPayload)
        hasher.combine(activityPayload)
        hasher.combine(timelineOrdinal)
        hasher.combine(turnLifecycle)
        hasher.combine(userDelivery)
        hasher.combine(isTimestampFallback)
        hasher.combine(contentDigest)
        hasher.combine(contentByteCount)
    }

    private mutating func updateRenderFingerprint() {
        let fingerprint = Self.makeRenderFingerprint(for: content)
        contentRevision &+= 1
        contentDigest = fingerprint.digest
        contentByteCount = fingerprint.byteCount
    }

    mutating func appendContent(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }
        // 流式正文只散列新增字节，避免每次 delta 都重新扫描整条长回复。
        appendedContentForFingerprint = delta
        content.append(contentsOf: delta)
        appendedContentForFingerprint = nil
    }

    private mutating func updateRenderFingerprint(appending delta: String) {
        var hash = contentDigest
        var appendedByteCount = 0
        for byte in delta.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
            appendedByteCount += 1
        }
        contentRevision &+= 1
        contentDigest = hash
        contentByteCount += appendedByteCount
    }

    private static func makeRenderFingerprint(for content: String) -> (digest: UInt64, byteCount: Int) {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var count = 0
        // 内容变化时生成固定大小 fingerprint，供 SwiftUI row diff 使用；
        // 避免长消息在每次 Equatable 比较里反复扫描整段 content。
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
            count += 1
        }
        return (hash, count)
    }
}

enum SessionStatus: String, Codable, Hashable {
    case history
    case idle
    case running
    case waitingForInput = "waiting_for_input"
    case waitingForApproval = "waiting_for_approval"
    case completed
    case failed
    case closed
    case unknown
}

enum MessageRole: String, Codable, Hashable {
    case user
    case assistant
    case system
    case tool
}

enum MessageKind: String, Codable, Hashable {
    case message
    case commentary
    case plan
    case reasoningSummary = "reasoning_summary"
    case commandSummary = "command_summary"
    case fileChangeSummary = "file_change_summary"
    case approval
    case userInput = "user_input"
    case warning
    case error
}

enum MessageSendStatus: String, Codable, Hashable {
    case local
    case sending
    case uncertain
    case sent
    case failed
    case confirmed
}

enum UserMessageDelivery: String, Codable, Hashable {
    case queued
    case guided
    case injected
}

enum ConversationActivityCategory: String, Codable, Hashable {
    case thinking
    case plan
    case runCommand = "run_command"
    case editFile = "edit_file"
    case toolCall = "tool_call"
    case error
}

/// 命令在主时间线中的展示语义。协议能明确给出只读动作时展示为探索，
/// 其余命令统一视为执行；不要再通过已经本地化的标题反推语义。
enum ConversationCommandPresentationKind: String, Codable, Hashable {
    case exploration
    case execution
}

/// Tool 活动的用户语义只来自受信任的 namespace / tool 白名单。
/// 不从 arguments、prompt 或原始输出拼标题，避免把 Token、账号、路径和用户内容带进时间线。
enum ConversationToolPresentationKind: String, Codable, Hashable {
    case linearQuery = "linear_query"
    case linearComment = "linear_comment"
    case linearUpdate = "linear_update"
    case independentTaskQuery = "independent_task_query"
    case independentTaskStart = "independent_task_start"
    case independentTaskResume = "independent_task_resume"
    case independentTaskWait = "independent_task_wait"
    case subagent
    case generic

    var systemImageName: String {
        switch self {
        case .linearQuery:
            return "checklist"
        case .linearComment:
            return "text.bubble"
        case .linearUpdate:
            return "square.and.pencil"
        case .independentTaskQuery:
            return "list.bullet.rectangle"
        case .independentTaskStart:
            return "arrow.up.right.square"
        case .independentTaskResume:
            return "arrow.clockwise"
        case .independentTaskWait:
            return "hourglass"
        case .subagent:
            return "person.2.fill"
        case .generic:
            return "wrench.and.screwdriver"
        }
    }
}

struct ConversationActivityPayload: Codable, Hashable {
    let category: ConversationActivityCategory
    let displayTitle: String
    let subtitle: String?
    let status: String?
    let command: String?
    let cwd: String?
    let toolName: String?
    let filePaths: [String]
    let exitCode: Int?
    let outputPreview: String?
    let outputDigest: UInt64?
    let outputByteCount: Int?
    let historyOutputID: String?
    let commandPresentationKind: ConversationCommandPresentationKind?
    let toolPresentationKind: ConversationToolPresentationKind?

    enum CodingKeys: String, CodingKey {
        case category
        case displayTitle = "display_title"
        case subtitle
        case status
        case command
        case cwd
        case toolName = "tool_name"
        case filePaths = "file_paths"
        case exitCode = "exit_code"
        case outputPreview = "output_preview"
        case outputDigest = "output_digest"
        case outputByteCount = "output_byte_count"
        case historyOutputID = "history_output_id"
        case commandPresentationKind = "command_presentation_kind"
        case toolPresentationKind = "tool_presentation_kind"
    }

    init(
        category: ConversationActivityCategory,
        displayTitle: String,
        subtitle: String? = nil,
        status: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        toolName: String? = nil,
        filePaths: [String] = [],
        exitCode: Int? = nil,
        outputPreview: String? = nil,
        outputDigest: UInt64? = nil,
        outputByteCount: Int? = nil,
        historyOutputID: String? = nil,
        commandPresentationKind: ConversationCommandPresentationKind? = nil,
        toolPresentationKind: ConversationToolPresentationKind? = nil
    ) {
        self.category = category
        self.displayTitle = displayTitle
        self.subtitle = subtitle
        self.status = status
        self.command = command
        self.cwd = cwd
        self.toolName = toolName
        self.filePaths = filePaths
        self.exitCode = exitCode
        self.outputPreview = outputPreview
        self.outputDigest = outputDigest
        self.outputByteCount = outputByteCount
        self.historyOutputID = historyOutputID
        self.commandPresentationKind = commandPresentationKind
        self.toolPresentationKind = toolPresentationKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = try container.decode(ConversationActivityCategory.self, forKey: .category)
        displayTitle = try container.decode(String.self, forKey: .displayTitle)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        filePaths = try container.decodeIfPresent([String].self, forKey: .filePaths) ?? []
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        outputPreview = try container.decodeIfPresent(String.self, forKey: .outputPreview)
        outputDigest = try container.decodeIfPresent(UInt64.self, forKey: .outputDigest)
        outputByteCount = try container.decodeIfPresent(Int.self, forKey: .outputByteCount)
        historyOutputID = try container.decodeIfPresent(String.self, forKey: .historyOutputID)
        // 服务端未来增加枚举值时，旧客户端仍应能加载历史；未知值保守按执行类展示。
        if let rawKind = try container.decodeIfPresent(String.self, forKey: .commandPresentationKind) {
            commandPresentationKind = ConversationCommandPresentationKind(rawValue: rawKind) ?? .execution
        } else {
            commandPresentationKind = nil
        }
        if let rawKind = try container.decodeIfPresent(String.self, forKey: .toolPresentationKind) {
            toolPresentationKind = ConversationToolPresentationKind(rawValue: rawKind) ?? .generic
        } else {
            toolPresentationKind = nil
        }
    }

    init?(item: [String: CodexAppServerJSONValue]) {
        guard let type = Self.firstString(in: item, keys: ["type"]) else {
            return nil
        }
        let historyOutputID = Self.historyOutputID(from: item)
        let historyOutputPreview = Self.firstString(in: item, keys: ["historyOutputPreview"])?.trimmedNonEmpty
        let historyOutputByteCount = Self.firstInt(in: item, keys: ["historyOutputByteCount"])
        switch type {
        case "plan":
            guard let text = Self.firstString(in: item, keys: ["text"])?.trimmedNonEmpty else {
                return nil
            }
            self.init(category: .plan, displayTitle: L10n.text("ui.plan"), subtitle: text)

        case "reasoning":
            let text = Self.reasoningText(from: item)
            guard !text.isEmpty else {
                return nil
            }
            self.init(category: .thinking, displayTitle: L10n.text("ui.reasoning_summary"), subtitle: text)

        case "commandExecution":
            let command = Self.firstString(in: item, keys: ["command", "processId"])?.trimmedNonEmpty ?? L10n.text("ui.command_execution")
            let commandActions = item["commandActions"]?.arrayValue
            let actionTitle = Self.commandActionTitle(from: commandActions)
            let status = Self.firstString(in: item, keys: ["status"])?.trimmedNonEmpty
            let cwd = Self.firstString(in: item, keys: ["cwd"])?.trimmedNonEmpty
            let output = Self.firstString(in: item, keys: ["aggregatedOutput"])?.trimmedNonEmpty
            let outputDigest = historyOutputID.map(Self.stableDigest) ?? output.map(Self.stableDigest)
            let outputByteCount = historyOutputByteCount ?? output?.utf8.count
            self.init(
                category: .runCommand,
                displayTitle: actionTitle ?? L10n.format("ui.run_value", command),
                subtitle: cwd,
                status: status,
                command: command,
                cwd: cwd,
                exitCode: Self.firstInt(in: item, keys: ["exitCode"]),
                outputPreview: (historyOutputPreview ?? output).map { Self.truncatedText($0, limit: Self.outputPreviewLimit) },
                outputDigest: outputDigest,
                outputByteCount: outputByteCount,
                historyOutputID: historyOutputID,
                commandPresentationKind: Self.commandPresentationKind(from: commandActions)
            )

        case "fileChange":
            let changes = item["changes"]?.arrayValue?.compactMap(\.objectValue) ?? []
            let filePaths = Self.filePaths(from: changes)
            let status = Self.firstString(in: item, keys: ["status"])?.trimmedNonEmpty ?? "modified"
            let summary = filePaths.first.map(Self.shortPath) ?? L10n.text("ui.workspace")
            let title = filePaths.count > 1 ? L10n.plural("ui.files_modified_count", count: filePaths.count) : L10n.format("ui.modify_value", summary)
            self.init(
                category: .editFile,
                displayTitle: title,
                subtitle: status,
                status: status,
                filePaths: filePaths,
                outputPreview: historyOutputPreview,
                outputDigest: historyOutputID.map(Self.stableDigest),
                outputByteCount: historyOutputByteCount,
                historyOutputID: historyOutputID
            )

        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch":
            let identifier = Self.toolIdentifier(from: item, type: type)
            let presentation = Self.toolPresentation(from: item, type: type, identifier: identifier)
            let status = Self.firstString(in: item, keys: ["status"])?.trimmedNonEmpty
            self.init(
                category: .toolCall,
                displayTitle: presentation.title,
                subtitle: presentation.subtitle,
                status: status,
                toolName: identifier,
                outputPreview: historyOutputPreview,
                outputDigest: historyOutputID.map(Self.stableDigest),
                outputByteCount: historyOutputByteCount,
                historyOutputID: historyOutputID,
                toolPresentationKind: presentation.kind
            )

        default:
            return nil
        }
    }

    var messageKind: MessageKind {
        switch category {
        case .thinking:
            return .reasoningSummary
        case .plan:
            return .plan
        case .runCommand, .toolCall:
            return .commandSummary
        case .editFile:
            return .fileChangeSummary
        case .error:
            return .error
        }
    }

    var summaryText: String {
        switch category {
        case .thinking, .plan:
            return subtitle ?? displayTitle
        case .runCommand:
            return commandSummaryText
        case .editFile:
            return fileChangeSummaryText
        case .toolCall:
            return toolSummaryText
        case .error:
            return subtitle ?? displayTitle
        }
    }

    /// 协议状态保留原值用于诊断；会话时间线只显示稳定、可理解的用户状态。
    /// 未知或未来新增状态不应直接泄漏成 `unknown` 或内部枚举名。
    var displayStatusText: String? {
        switch normalizedStatus {
        case "completed", "complete", "success", "succeeded":
            return L10n.text("ui.completed_status")
        case "failed", "failure", "error":
            return L10n.text("ui.failed_status")
        case "inprogress", "running", "started":
            return L10n.text("ui.in_progress")
        case "pending", "queued":
            return L10n.text("ui.waiting")
        case "cancelled", "canceled":
            return L10n.text("ui.canceled")
        case "interrupted", "aborted", "stopped":
            return L10n.text("ui.interrupted_status")
        case "timeout", "timedout":
            return L10n.text("ui.timed_out_status")
        case "modified":
            return L10n.text("ui.modified")
        case "added", "created":
            return L10n.text("ui.added")
        case "deleted", "removed":
            return L10n.text("ui.deleted")
        default:
            return nil
        }
    }

    var isInProgress: Bool {
        switch normalizedStatus {
        case "inprogress", "running", "started":
            return true
        default:
            return false
        }
    }

    var isFailure: Bool {
        if let exitCode, exitCode != 0 {
            return true
        }
        switch normalizedStatus {
        case "failed", "failure", "error", "timeout", "timedout":
            return true
        default:
            return false
        }
    }

    var isInterrupted: Bool {
        switch normalizedStatus {
        case "interrupted", "aborted", "stopped", "cancelled", "canceled":
            return true
        default:
            return false
        }
    }

    /// VoiceOver 始终读出具体动作、安全目标摘要和终态；完成态不能因为视觉上省略状态而丢失语义。
    var accessibilityDescription: String {
        var parts = [displayTitle]
        if let subtitle = subtitle?.trimmedNonEmpty, subtitle != displayTitle {
            parts.append(subtitle)
        }
        if let displayStatusText {
            parts.append(displayStatusText)
        }
        return parts.joined(separator: L10n.text("ui.list_separator"))
    }

    /// 过程行不是 Markdown 正文。这里移除最常见的强调和行内代码标记，
    /// 避免把格式符号当成运行日志打印，同时保留原始 payload 供详情和诊断使用。
    static func plainProgressText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var value = String(line).trimmingCharacters(in: .whitespaces)
                for level in (1...6).reversed() {
                    let headingPrefix = String(repeating: "#", count: level) + " "
                    if value.hasPrefix(headingPrefix) {
                        value.removeFirst(headingPrefix.count)
                        break
                    }
                }
                if value.count >= 2,
                   let marker = value.first,
                   (marker == "*" || marker == "_"),
                   value.last == marker {
                    value.removeFirst()
                    value.removeLast()
                }
                return value
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func == (lhs: ConversationActivityPayload, rhs: ConversationActivityPayload) -> Bool {
        lhs.category == rhs.category
            && lhs.displayTitle == rhs.displayTitle
            && lhs.subtitle == rhs.subtitle
            && lhs.status == rhs.status
            && lhs.command == rhs.command
            && lhs.cwd == rhs.cwd
            && lhs.toolName == rhs.toolName
            && lhs.filePaths == rhs.filePaths
            && lhs.exitCode == rhs.exitCode
            && lhs.outputDigest == rhs.outputDigest
            && lhs.outputByteCount == rhs.outputByteCount
            && lhs.historyOutputID == rhs.historyOutputID
            && lhs.commandPresentationKind == rhs.commandPresentationKind
            && lhs.toolPresentationKind == rhs.toolPresentationKind
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(category)
        hasher.combine(displayTitle)
        hasher.combine(subtitle)
        hasher.combine(status)
        hasher.combine(command)
        hasher.combine(cwd)
        hasher.combine(toolName)
        hasher.combine(filePaths)
        hasher.combine(exitCode)
        hasher.combine(outputDigest)
        hasher.combine(outputByteCount)
        hasher.combine(historyOutputID)
        hasher.combine(commandPresentationKind)
        hasher.combine(toolPresentationKind)
    }

    private var commandSummaryText: String {
        let command = command?.trimmedNonEmpty ?? displayTitle
        var lines = [L10n.format("ui.command_value", command)]
        if let cwd {
            lines.append(L10n.format("ui.directory_value", cwd))
        }
        let statusLine = [displayStatusText.map { L10n.format("ui.status_value_bcee9cc0", $0) }, exitCode.map { L10n.format("ui.exit_code_value_3dde4ee9", $0) }]
            .compactMap { $0 }
            .joined(separator: L10n.text("ui.list_separator"))
        if !statusLine.isEmpty {
            lines.append(statusLine)
        }
        if let outputPreview {
            lines.append(L10n.format("ui.output_value_301e2a77", outputPreview))
        }
        return lines.joined(separator: "\n")
    }

    private var fileChangeSummaryText: String {
        let summary = filePaths.isEmpty ? (displayTitle.replacingOccurrences(of: L10n.text("ui.modify"), with: "")) : Self.compactFileSummary(filePaths)
        guard let displayStatusText else {
            return L10n.format("ui.file_changes_value", summary)
        }
        return L10n.format("ui.file_changes_value_value", summary, displayStatusText)
    }

    private var toolSummaryText: String {
        guard let displayStatusText else {
            return L10n.format("ui.tool_value", displayTitle)
        }
        return L10n.format("ui.tool_value_status_value", displayTitle, displayStatusText)
    }

    private var normalizedStatus: String {
        (status ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static let outputPreviewLimit = 1_000

    private static func historyOutputID(from item: [String: CodexAppServerJSONValue]) -> String? {
        let prefix = "agentd-history-output://"
        guard let reference = firstString(in: item, keys: ["historyOutputRef"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              reference.hasPrefix(prefix) else {
            return nil
        }
        let id = String(reference.dropFirst(prefix.count))
        guard !id.isEmpty,
              id.utf8.count <= 256,
              !id.contains("/"),
              !id.contains("?"),
              !id.contains("#") else {
            return nil
        }
        return id
    }

    private static func reasoningText(from item: [String: CodexAppServerJSONValue]) -> String {
        let summary = item["summary"]?.arrayValue?
            .compactMap(\.stringValue)
            .compactMap(\.trimmedNonEmpty) ?? []
        if let latestSummary = summary.last {
            // app-server 会持续把新的 summary part 追加到同一个 reasoning item；
            // 原生客户端用最新 part 作为当前阶段标题，而不是把历史标题全部铺开。
            return latestSummary
        }
        let content = item["content"]?.arrayValue?
            .compactMap(\.stringValue)
            .compactMap(\.trimmedNonEmpty) ?? []
        return content.last ?? ""
    }

    private static func commandActionTitle(from actions: [CodexAppServerJSONValue]?) -> String? {
        for action in actions?.compactMap(\.objectValue) ?? [] {
            let discriminator = normalizedActionDiscriminator(
                firstString(in: action, keys: ["type", "kind"])?.trimmedNonEmpty
            )
            let query = firstString(in: action, keys: ["query"])?.trimmedNonEmpty
            let path = firstString(in: action, keys: ["path", "file", "filePath", "relativePath"])?.trimmedNonEmpty

            // 官方 CommandAction 以 type 为判别字段；Read 的 name 可能是 sed/cat，
            // 不能优先拿 name 判断，否则只读命令会被误标为执行命令。
            if let discriminator {
                switch discriminator {
                case "read":
                    return path.map { "\(L10n.text("ui.view")) \(shortPath($0))" } ?? L10n.text("ui.view")
                case "listfiles":
                    return path.map { "\(L10n.text("ui.list")) \(shortPath($0))" } ?? L10n.text("ui.list")
                case "search":
                    if let query {
                        return L10n.format("ui.search_query", query)
                    }
                    return path.map { "\(L10n.text("ui.search")) \(shortPath($0))" } ?? L10n.text("ui.search")
                default:
                    // unknown 表示协议无法结构化解析，不直接泄漏给用户。
                    return L10n.text("ui.run_command")
                }
            }

            // 兼容旧 gateway 曾使用的 name/query/path 结构。
            if let query {
                return L10n.format("ui.search_query", query)
            }
            let name = firstString(in: action, keys: ["name"])?.trimmedNonEmpty
            if name != nil, localizedActionVerb(name) == nil {
                return L10n.text("ui.run_command")
            }
            if let path {
                let verb = localizedActionVerb(name) ?? L10n.text("ui.view")
                return "\(verb) \(shortPath(path))"
            }
            if let verb = localizedActionVerb(name) {
                return verb
            }
        }
        return nil
    }

    private static func commandPresentationKind(
        from actions: [CodexAppServerJSONValue]?
    ) -> ConversationCommandPresentationKind {
        let actionObjects = actions?.compactMap(\.objectValue) ?? []
        guard !actionObjects.isEmpty else {
            return .execution
        }
        let onlyExplorationActions = actionObjects.allSatisfy { action in
            if let discriminator = normalizedActionDiscriminator(
                firstString(in: action, keys: ["type", "kind"])?.trimmedNonEmpty
            ) {
                return discriminator == "read" || discriminator == "listfiles" || discriminator == "search"
            }
            if firstString(in: action, keys: ["query"])?.trimmedNonEmpty != nil {
                return true
            }
            let name = firstString(in: action, keys: ["name"])?.trimmedNonEmpty
            if localizedActionVerb(name) != nil {
                return true
            }
            let path = firstString(in: action, keys: ["path", "file", "filePath", "relativePath"])?.trimmedNonEmpty
            return name == nil && path != nil
        }
        return onlyExplorationActions ? .exploration : .execution
    }

    private static func localizedActionVerb(_ value: String?) -> String? {
        switch normalizedActionDiscriminator(value) {
        case "read", "view", "open", "cat":
            return L10n.text("ui.view")
        case "search", "grep", "rg", "find":
            return L10n.text("ui.search")
        case "list", "listfiles", "ls":
            return L10n.text("ui.list")
        default:
            return nil
        }
    }

    private static func normalizedActionDiscriminator(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmedNonEmpty
    }

    private struct ToolPresentation {
        let title: String
        let subtitle: String?
        let kind: ConversationToolPresentationKind
    }

    private static func toolPresentation(
        from item: [String: CodexAppServerJSONValue],
        type: String,
        identifier: String?
    ) -> ToolPresentation {
        if type == "webSearch" {
            // 搜索词属于用户内容，过程时间线只说明动作，不回显原始 query。
            return ToolPresentation(title: L10n.text("ui.web_search"), subtitle: nil, kind: .generic)
        }

        let namespace = firstString(in: item, keys: ["server", "namespace"])?.trimmedNonEmpty
        let tool = firstString(in: item, keys: ["tool", "name"])?.trimmedNonEmpty
        let normalizedNamespace = normalizedToolComponent(namespace)
        let normalizedTool = normalizedToolComponent(tool)

        // collabAgentToolCall 与 collaboration namespace 表示真实子 Agent；
        // create_thread 等 Codex App 工具表示独立任务，两者必须先于通用工具映射判断。
        let isSubagentTool = type == "collabAgentToolCall"
            || normalizedNamespace == "collaboration"
            || normalizedTool.map {
                [
                    "spawn_agent",
                    "followup_task",
                    "wait_agent",
                    "list_agents",
                    "interrupt_agent",
                ].contains($0)
            } == true
        if isSubagentTool {
            let title: String
            switch normalizedTool {
            case "spawn_agent":
                title = L10n.text("ui.start_subagent")
            case "followup_task", "send_message":
                title = L10n.text("ui.continue_subagent")
            case "wait_agent":
                title = L10n.text("ui.wait_for_subagent_result")
            case "list_agents":
                title = L10n.text("ui.query_subagents")
            case "interrupt_agent":
                title = L10n.text("ui.interrupt_subagent")
            default:
                title = type == "collabAgentToolCall"
                    ? L10n.text("ui.start_subagent")
                    : L10n.text("ui.perform_subagent_collaboration")
            }
            return ToolPresentation(title: title, subtitle: nil, kind: .subagent)
        }

        if normalizedNamespace == "linear" || normalizedNamespace?.hasSuffix("__linear") == true {
            switch normalizedTool {
            case "list_issues", "search_issues":
                return ToolPresentation(title: L10n.text("ui.query_linear_issues"), subtitle: nil, kind: .linearQuery)
            case "get_issue":
                return ToolPresentation(title: L10n.text("ui.read_linear_issue"), subtitle: nil, kind: .linearQuery)
            case "list_comments", "get_comment":
                return ToolPresentation(title: L10n.text("ui.read_issue_comments"), subtitle: nil, kind: .linearComment)
            case "save_issue", "create_issue", "update_issue":
                return ToolPresentation(title: L10n.text("ui.update_linear_issue"), subtitle: nil, kind: .linearUpdate)
            case "save_comment", "create_comment", "update_comment", "delete_comment":
                return ToolPresentation(title: L10n.text("ui.update_issue_comments"), subtitle: nil, kind: .linearUpdate)
            default:
                if normalizedTool?.hasPrefix("list_") == true {
                    return ToolPresentation(title: L10n.text("ui.query_linear"), subtitle: nil, kind: .linearQuery)
                }
                if normalizedTool?.hasPrefix("get_") == true {
                    return ToolPresentation(title: L10n.text("ui.read_linear"), subtitle: nil, kind: .linearQuery)
                }
                if ["save_", "create_", "update_", "delete_"].contains(where: { normalizedTool?.hasPrefix($0) == true }) {
                    return ToolPresentation(title: L10n.text("ui.update_linear"), subtitle: nil, kind: .linearUpdate)
                }
            }
        }

        switch normalizedTool {
        case "list_threads":
            return ToolPresentation(title: L10n.text("ui.query_task_list"), subtitle: nil, kind: .independentTaskQuery)
        case "create_thread":
            return ToolPresentation(title: L10n.text("ui.start_independent_task"), subtitle: nil, kind: .independentTaskStart)
        case "read_thread":
            return ToolPresentation(title: L10n.text("ui.read_independent_task"), subtitle: nil, kind: .independentTaskQuery)
        case "send_message_to_thread":
            return ToolPresentation(title: L10n.text("ui.resume_independent_task"), subtitle: nil, kind: .independentTaskResume)
        case "wait_threads":
            return ToolPresentation(title: L10n.text("ui.wait_for_task_results"), subtitle: nil, kind: .independentTaskWait)
        case "session_set_defaults":
            return ToolPresentation(title: L10n.text("ui.configure_an_xcode_session"), subtitle: nil, kind: .generic)
        case "test_sim":
            return ToolPresentation(title: L10n.text("ui.run_emulator_tests"), subtitle: nil, kind: .generic)
        case "test_device":
            return ToolPresentation(title: L10n.text("ui.run_real_device_tests"), subtitle: nil, kind: .generic)
        case "build_sim":
            return ToolPresentation(title: L10n.text("ui.build_emulator_version"), subtitle: nil, kind: .generic)
        case "build_device":
            return ToolPresentation(title: L10n.text("ui.build_a_real_device_version"), subtitle: nil, kind: .generic)
        case "build_run_sim":
            return ToolPresentation(title: L10n.text("ui.build_and_run_the_app"), subtitle: nil, kind: .generic)
        case "launch_app_sim":
            return ToolPresentation(title: L10n.text("ui.launch_the_app"), subtitle: nil, kind: .generic)
        case "stop_app_sim":
            return ToolPresentation(title: L10n.text("ui.stop_app"), subtitle: nil, kind: .generic)
        case "clean":
            return ToolPresentation(title: L10n.text("ui.clean_build_artifacts"), subtitle: nil, kind: .generic)
        case "screenshot":
            return ToolPresentation(title: L10n.text("ui.interception_interface"), subtitle: nil, kind: .generic)
        case "ui_describe_all":
            return ToolPresentation(title: L10n.text("ui.read_interface_structure"), subtitle: nil, kind: .generic)
        case "tap":
            return ToolPresentation(title: L10n.text("ui.click_interface"), subtitle: nil, kind: .generic)
        case "swipe":
            return ToolPresentation(title: L10n.text("ui.sliding_interface"), subtitle: nil, kind: .generic)
        case "type_text":
            return ToolPresentation(title: L10n.text("ui.enter_text"), subtitle: nil, kind: .generic)
        case "key_press":
            return ToolPresentation(title: L10n.text("ui.press_button"), subtitle: nil, kind: .generic)
        case "open", "navigate":
            let title = normalizedNamespace == "browser" ? L10n.text("ui.open_web_page") : L10n.text("ui.open_content")
            return ToolPresentation(title: title, subtitle: nil, kind: .generic)
        case "click":
            return ToolPresentation(title: L10n.text("ui.click_page"), subtitle: nil, kind: .generic)
        case "find":
            return ToolPresentation(title: L10n.text("ui.find_page_content"), subtitle: nil, kind: .generic)
        case "search", "search_query":
            return ToolPresentation(title: L10n.text("ui.search_the_web"), subtitle: nil, kind: .generic)
        case "view_image":
            return ToolPresentation(title: L10n.text("ui.view_pictures"), subtitle: nil, kind: .generic)
        case "imagegen":
            return ToolPresentation(title: L10n.text("ui.generate_pictures"), subtitle: nil, kind: .generic)
        case "apply_patch":
            return ToolPresentation(title: L10n.text("ui.modify_files_action"), subtitle: nil, kind: .generic)
        case "exec_command":
            return ToolPresentation(title: L10n.text("ui.run_command"), subtitle: nil, kind: .generic)
        case "wait":
            return ToolPresentation(title: L10n.text("ui.wait_for_task_to_complete"), subtitle: nil, kind: .generic)
        case "update_plan":
            return ToolPresentation(title: L10n.text("ui.update_plan"), subtitle: nil, kind: .generic)
        case "request_user_input":
            return ToolPresentation(title: L10n.text("ui.request_additional_information"), subtitle: nil, kind: .generic)
        case "read_mcp_resource":
            return ToolPresentation(title: L10n.text("ui.read_resources"), subtitle: nil, kind: .generic)
        case "list_mcp_resources", "list_mcp_resource_templates":
            return ToolPresentation(title: L10n.text("ui.list_resources"), subtitle: nil, kind: .generic)
        default:
            break
        }

        switch normalizedNamespace {
        case "xcodebuildmcp":
            return ToolPresentation(title: L10n.text("ui.run_xcode_tools"), subtitle: nil, kind: .generic)
        case "browser":
            return ToolPresentation(title: L10n.text("ui.manipulate_the_web_page"), subtitle: nil, kind: .generic)
        case "image_gen", "imagegen":
            return ToolPresentation(title: L10n.text("ui.generate_pictures"), subtitle: nil, kind: .generic)
        default:
            // 未知工具只展示严格白名单后的 namespace/tool 标识，不显示 arguments 或结果。
            return ToolPresentation(title: L10n.text("ui.call_tool"), subtitle: identifier, kind: .generic)
        }
    }

    private static func toolIdentifier(from item: [String: CodexAppServerJSONValue], type: String) -> String? {
        let components: [String?]
        switch type {
        case "mcpToolCall":
            components = [firstString(in: item, keys: ["server"]), firstString(in: item, keys: ["tool"])]
        case "dynamicToolCall":
            components = [firstString(in: item, keys: ["namespace"]), firstString(in: item, keys: ["tool"])]
        case "collabAgentToolCall":
            components = ["collaboration", firstString(in: item, keys: ["tool"])]
        case "webSearch":
            return "web.search"
        default:
            return nil
        }
        return components
            .compactMap(safeToolIdentifierComponent)
            .joined(separator: ".")
            .trimmedNonEmpty
    }

    private static func normalizedToolComponent(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .trimmedNonEmpty
    }

    private static func safeToolIdentifierComponent(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 64
        else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return value
    }

    private static func filePaths(from changes: [[String: CodexAppServerJSONValue]]) -> [String] {
        changes.compactMap { change in
            firstString(in: change, keys: ["path", "filePath", "relativePath", "filename"])?.trimmedNonEmpty
        }
    }

    private static func fileChangeSummary(from changes: [[String: CodexAppServerJSONValue]]) -> String? {
        let paths = filePaths(from: changes)
        guard !paths.isEmpty else {
            return nil
        }
        return compactFileSummary(paths)
    }

    private static func compactFileSummary(_ paths: [String]) -> String {
        var parts = Array(paths.prefix(3))
        if paths.count > parts.count {
            parts.append("+\(paths.count - parts.count)")
        }
        return parts.joined(separator: ", ")
    }

    private static func shortPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return path
        }
        if let last = trimmed.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return trimmed
    }

    private static func truncatedText(_ text: String, limit: Int) -> String {
        let prefix = text.prefix(limit)
        guard prefix.endIndex != text.endIndex else {
            return text
        }
        return String(prefix) + "\n... output truncated"
    }

    private static func stableDigest(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func firstString(in params: [String: CodexAppServerJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = params[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    private static func firstInt(in params: [String: CodexAppServerJSONValue], keys: [String]) -> Int? {
        for key in keys {
            if let value = params[key]?.intValue {
                return value
            }
        }
        return nil
    }
}
