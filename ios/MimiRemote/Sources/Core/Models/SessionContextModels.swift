import Foundation

struct SessionContextSnapshot: Codable, Hashable {
    var sessionID: SessionID?
    var threadID: String?
    var createdAt: Date?
    var parentThreadID: String?
    /// Optional 保留“旧协议未知”与“明确不是子 Agent”的差异，并兼容旧持久化 JSON。
    var isSubagent: Bool?
    var status: SessionContextStatus?
    var environment: SessionContextEnvironment?
    var git: SessionContextGitInfo?
    var goal: ThreadGoal?
    var tasks: [SessionContextTask]
    var sources: [SessionContextSource]
    var subagents: [SessionContextSubagent]
    var updatedAt: Date?
    /// 仅随实时 `thread/tokenUsage/updated` 传递的数值用量，供本轮 token 计数使用；
    /// 不在 CodingKeys 中，不进入持久化。
    var tokenUsage: AppServerTokenUsageSample?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case threadID = "thread_id"
        case createdAt = "created_at"
        case parentThreadID = "parent_thread_id"
        case isSubagent = "is_subagent"
        case status
        case environment
        case git
        case goal
        case tasks
        case sources
        case subagents
        case updatedAt = "updated_at"
    }

    init(
        sessionID: SessionID? = nil,
        threadID: String? = nil,
        createdAt: Date? = nil,
        parentThreadID: String? = nil,
        isSubagent: Bool? = nil,
        status: SessionContextStatus? = nil,
        environment: SessionContextEnvironment? = nil,
        git: SessionContextGitInfo? = nil,
        goal: ThreadGoal? = nil,
        tasks: [SessionContextTask] = [],
        sources: [SessionContextSource] = [],
        subagents: [SessionContextSubagent] = [],
        updatedAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.threadID = threadID
        self.createdAt = createdAt
        self.parentThreadID = parentThreadID
        self.isSubagent = isSubagent
        self.status = status
        self.environment = environment
        self.git = git
        self.goal = goal
        self.tasks = tasks
        self.sources = sources
        self.subagents = subagents
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decodeIfPresent(SessionID.self, forKey: .sessionID)
        self.threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.parentThreadID = try container.decodeIfPresent(String.self, forKey: .parentThreadID)
        self.isSubagent = try container.decodeIfPresent(Bool.self, forKey: .isSubagent)
        self.status = try container.decodeIfPresent(SessionContextStatus.self, forKey: .status)
        self.environment = try container.decodeIfPresent(SessionContextEnvironment.self, forKey: .environment)
        self.git = try container.decodeIfPresent(SessionContextGitInfo.self, forKey: .git)
        self.goal = try container.decodeIfPresent(ThreadGoal.self, forKey: .goal)
        self.tasks = try container.decodeIfPresent([SessionContextTask].self, forKey: .tasks) ?? []
        self.sources = try container.decodeIfPresent([SessionContextSource].self, forKey: .sources) ?? []
        self.subagents = try container.decodeIfPresent([SessionContextSubagent].self, forKey: .subagents) ?? []
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct SessionContextStatus: Codable, Hashable {
    var type: String
    var activeFlags: [String]

    enum CodingKeys: String, CodingKey {
        case type
        case activeFlags = "active_flags"
    }

    private enum AlternateCodingKeys: String, CodingKey {
        case activeFlags
    }

    init(type: String, activeFlags: [String] = []) {
        self.type = type
        self.activeFlags = activeFlags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alternate = try decoder.container(keyedBy: AlternateCodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        self.activeFlags = try container.decodeIfPresent([String].self, forKey: .activeFlags)
            ?? alternate.decodeIfPresent([String].self, forKey: .activeFlags)
            ?? []
    }
}

struct SessionContextEnvironment: Codable, Hashable {
    var id: String?
    var kind: String?
    var label: String?
    var cwd: String?
    var provider: String?
    var runtimeProvider: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case label
        case cwd
        case provider
        case runtimeProvider = "runtime_provider"
    }
}

struct SessionContextGitInfo: Codable, Hashable {
    var sha: String?
    var branch: String?
    var originURL: String?

    enum CodingKeys: String, CodingKey {
        case sha
        case branch
        case originURL = "origin_url"
    }

    private enum AlternateCodingKeys: String, CodingKey {
        case originURL = "originUrl"
    }

    init(sha: String? = nil, branch: String? = nil, originURL: String? = nil) {
        self.sha = sha
        self.branch = branch
        self.originURL = originURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alternate = try decoder.container(keyedBy: AlternateCodingKeys.self)
        self.sha = try container.decodeIfPresent(String.self, forKey: .sha)
        self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
        self.originURL = try container.decodeIfPresent(String.self, forKey: .originURL)
            ?? alternate.decodeIfPresent(String.self, forKey: .originURL)
    }
}

struct SessionContextTask: Identifiable, Codable, Hashable {
    var id: String
    var kind: String
    var title: String
    var subtitle: String?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case subtitle
        case status
    }

    init(id: String, kind: String, title: String, subtitle: String? = nil, status: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decodeIfPresent(String.self, forKey: .title) ?? L10n.text("ui.task")
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? title
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "task"
        self.title = title
        self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
    }
}

struct SessionContextSource: Identifiable, Codable, Hashable {
    var id: String
    var kind: String
    var label: String
    var subtitle: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case label
        case subtitle
    }

    init(id: String, kind: String, label: String, subtitle: String? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.subtitle = subtitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let label = try container.decodeIfPresent(String.self, forKey: .label) ?? L10n.text("ui.source")
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? label
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "source"
        self.label = label
        self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
    }
}

struct SessionContextSubagent: Identifiable, Codable, Hashable {
    var id: String
    var parentThreadID: String?
    var sessionID: String?
    var nickname: String?
    var role: String?
    var status: String?
    var statusMessage: String?
    var canAcceptDirectInput: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case parentThreadID = "parent_thread_id"
        case sessionID = "session_id"
        case nickname
        case role
        case status
        case statusMessage = "status_message"
        case canAcceptDirectInput = "can_accept_direct_input"
    }

    private enum AlternateCodingKeys: String, CodingKey {
        case parentThreadID = "parentThreadId"
        case sessionID = "sessionId"
        case statusMessage
        case canAcceptDirectInput
    }

    var displayName: String {
        if let nickname, !nickname.isEmpty {
            return nickname
        }
        return id.isEmpty ? "Subagent" : id
    }

    init(
        id: String,
        parentThreadID: String? = nil,
        sessionID: String? = nil,
        nickname: String? = nil,
        role: String? = nil,
        status: String? = nil,
        statusMessage: String? = nil,
        canAcceptDirectInput: Bool? = nil
    ) {
        self.id = id
        self.parentThreadID = parentThreadID
        self.sessionID = sessionID
        self.nickname = nickname
        self.role = role
        self.status = status
        self.statusMessage = statusMessage
        self.canAcceptDirectInput = canAcceptDirectInput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alternate = try decoder.container(keyedBy: AlternateCodingKeys.self)
        let nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.parentThreadID = try container.decodeIfPresent(String.self, forKey: .parentThreadID)
            ?? alternate.decodeIfPresent(String.self, forKey: .parentThreadID)
        self.sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? alternate.decodeIfPresent(String.self, forKey: .sessionID)
        self.nickname = nickname
        self.role = try container.decodeIfPresent(String.self, forKey: .role)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
            ?? alternate.decodeIfPresent(String.self, forKey: .statusMessage)
        self.canAcceptDirectInput = try container.decodeIfPresent(Bool.self, forKey: .canAcceptDirectInput)
            ?? alternate.decodeIfPresent(Bool.self, forKey: .canAcceptDirectInput)
    }
}
