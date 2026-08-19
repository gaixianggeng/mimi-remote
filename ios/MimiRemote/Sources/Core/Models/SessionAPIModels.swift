import Foundation

// 会话、历史与 Turn DTO 独立成领域文件，Codable 默认值和兼容分支不变。
struct SessionsResponse: Codable {
    let sessions: [AgentSession]
    let rows: [DataFlowSessionRow]
    let nextCursor: String?
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case sessions
        case rows
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decodeIfPresent([DataFlowSessionRow].self, forKey: .rows) ?? []
        self.rows = rows
        self.sessions = try container.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? rows.map(AgentSession.init(row:))
        self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        self.hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }
}

struct SessionsPage: Equatable {
    let sessions: [AgentSession]
    let nextCursor: String?
    let hasMore: Bool

    init(response: SessionsResponse) {
        self.sessions = response.sessions
        self.nextCursor = response.nextCursor
        self.hasMore = response.hasMore ?? false
    }

    init(sessions: [AgentSession], nextCursor: String? = nil, hasMore: Bool = false) {
        self.sessions = sessions
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

enum SessionListConsistency: Hashable {
    /// 默认使用 State DB 索引；发现应位于当前页的已知会话缺失时由 runtime 自动回退扫描。
    case fastIndexed
    /// 用户主动刷新时直接扫描历史，作为索引暂时落后的权威恢复路径。
    case authoritative
}

struct ThreadSearchResult: Equatable {
    let session: AgentSession
    let snippet: String
}

struct ThreadSearchPage: Equatable {
    let results: [ThreadSearchResult]
    let nextCursor: String?
    let backwardsCursor: String?

    var sessions: [AgentSession] {
        results.map(\.session)
    }

    init(
        results: [ThreadSearchResult],
        nextCursor: String? = nil,
        backwardsCursor: String? = nil
    ) {
        self.results = results
        self.nextCursor = nextCursor
        self.backwardsCursor = backwardsCursor
    }
}

struct SessionResponse: Codable {
    let session: AgentSession
    let row: DataFlowSessionRow?
    let recentOutput: String?
    let lastSeq: EventSequence?

    enum CodingKeys: String, CodingKey {
        case session
        case row
        case recentOutput = "recent_output"
        case lastSeq = "last_seq"
    }

    init(session: AgentSession, row: DataFlowSessionRow? = nil, recentOutput: String? = nil, lastSeq: EventSequence? = nil) {
        self.session = session
        self.row = row
        self.recentOutput = recentOutput
        self.lastSeq = lastSeq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row)
        self.row = row
        if let session = try container.decodeIfPresent(AgentSession.self, forKey: .session) {
            self.session = session
        } else if let row {
            self.session = AgentSession(row: row)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.session,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: L10n.text("ui.missing_session_or_row"))
            )
        }
        self.recentOutput = try container.decodeIfPresent(String.self, forKey: .recentOutput)
        self.lastSeq = try container.decodeIfPresent(EventSequence.self, forKey: .lastSeq)
    }
}

struct CreateSessionResponse: Codable {
    let session: AgentSession
    let row: DataFlowSessionRow?
    let wsURL: String
    let firstMessage: AgentMessage?

    enum CodingKeys: String, CodingKey {
        case session
        case row
        case wsURL = "ws_url"
        case firstMessage = "first_message"
    }

    init(session: AgentSession, row: DataFlowSessionRow? = nil, wsURL: String, firstMessage: AgentMessage? = nil) {
        self.session = session
        self.row = row
        self.wsURL = wsURL
        self.firstMessage = firstMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row)
        self.row = row
        if let session = try container.decodeIfPresent(AgentSession.self, forKey: .session) {
            self.session = session
        } else if let row {
            self.session = AgentSession(row: row)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.session,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: L10n.text("ui.missing_session_or_row"))
            )
        }
        self.wsURL = try container.decode(String.self, forKey: .wsURL)
        self.firstMessage = try container.decodeIfPresent(AgentMessage.self, forKey: .firstMessage)
    }
}

struct MessagesResponse: Codable {
    let messages: [CodexHistoryMessage]
    let page: MessagePage?
    let nextCursor: String?
    let previousCursor: String?
    let hasMoreBefore: Bool?
    let snapshotSeq: EventSequence?

    enum CodingKeys: String, CodingKey {
        case messages
        case page
        case nextCursor = "next_cursor"
        case previousCursor = "previous_cursor"
        case hasMoreBefore = "has_more_before"
        case snapshotSeq = "snapshot_seq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.page = try container.decodeIfPresent(MessagePage.self, forKey: .page)
        if let page {
            self.messages = page.messages.map {
                CodexHistoryMessage(
                    id: $0.id,
                    role: $0.role.rawValue,
                    content: $0.content,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    clientMessageID: $0.clientMessageID,
                    turnID: $0.turnID,
                    itemID: $0.itemID,
                    seq: $0.seq,
                    revision: $0.revision,
                    sendStatus: $0.sendStatus,
                    isTimestampFallback: $0.isTimestampFallback
                )
            }
            self.nextCursor = page.nextCursor
            self.previousCursor = page.previousCursor
            self.hasMoreBefore = page.hasMoreBefore
            self.snapshotSeq = page.snapshotSeq
        } else {
            self.messages = try container.decodeIfPresent([CodexHistoryMessage].self, forKey: .messages) ?? []
            self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            self.previousCursor = try container.decodeIfPresent(String.self, forKey: .previousCursor)
            self.hasMoreBefore = try container.decodeIfPresent(Bool.self, forKey: .hasMoreBefore)
            self.snapshotSeq = try container.decodeIfPresent(EventSequence.self, forKey: .snapshotSeq)
        }
    }
}

struct HistoryMessagesPage: Equatable {
    enum LoadMode: String, Equatable, Hashable {
        case full
        case economy
    }

    let messages: [CodexHistoryMessage]
    let previousCursor: String?
    let hasMoreBefore: Bool
    let context: SessionContextSnapshot?
    let snapshotSeq: EventSequence?
    let loadMode: LoadMode
    let notice: String?
    let authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>]

    init(response: MessagesResponse) {
        self.messages = response.messages
        self.previousCursor = response.previousCursor
        self.hasMoreBefore = response.hasMoreBefore ?? false
        self.context = nil
        self.snapshotSeq = response.snapshotSeq
        self.loadMode = .full
        self.notice = nil
        self.authoritativeCompletedTurnItems = [:]
    }

    init(
        messages: [CodexHistoryMessage],
        previousCursor: String? = nil,
        hasMoreBefore: Bool = false,
        context: SessionContextSnapshot? = nil,
        snapshotSeq: EventSequence? = nil,
        loadMode: LoadMode = .full,
        notice: String? = nil,
        authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>] = [:]
    ) {
        self.messages = messages
        self.previousCursor = previousCursor
        self.hasMoreBefore = hasMoreBefore
        self.context = context
        self.snapshotSeq = snapshotSeq
        self.loadMode = loadMode
        self.notice = notice
        self.authoritativeCompletedTurnItems = authoritativeCompletedTurnItems
    }
}

struct CreateSessionRequest: Encodable {
    let projectID: String
    let projectPath: String?
    let projectName: String?
    let rootProjectID: String?
    let prompt: String
    let input: [CodexAppServerUserInput]
    let turnOptions: CodexAppServerTurnOptions
    let initialGoalObjective: String?
    let resumeID: String
    let clientMessageID: ClientMessageID?

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectPath = "project_path"
        case projectName = "project_name"
        case rootProjectID = "root_project_id"
        case prompt
        case input
        case turnOptions = "turn_options"
        case initialGoalObjective = "initial_goal_objective"
        case resumeID = "resume_id"
        case clientMessageID = "client_message_id"
    }

    init(
        projectID: String,
        projectPath: String? = nil,
        projectName: String? = nil,
        rootProjectID: String? = nil,
        prompt: String,
        input: [CodexAppServerUserInput]? = nil,
        turnOptions: CodexAppServerTurnOptions = .default,
        initialGoalObjective: String? = nil,
        resumeID: String,
        clientMessageID: ClientMessageID? = nil
    ) {
        self.projectID = projectID
        self.projectPath = projectPath
        self.projectName = projectName
        self.rootProjectID = rootProjectID
        self.prompt = prompt
        self.input = input ?? CodexAppServerTurnPayload.defaultInput(for: prompt)
        self.turnOptions = turnOptions
        self.initialGoalObjective = initialGoalObjective
        self.resumeID = resumeID
        self.clientMessageID = clientMessageID
    }
}

enum CodexAppServerImageDetail: String, Codable, CaseIterable, Hashable, Identifiable {
    case auto
    case low
    case high
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return L10n.text("ui.automatic")
        case .low:
            return L10n.text("ui.low")
        case .high:
            return L10n.text("ui.high")
        case .original:
            return L10n.text("ui.original_picture")
        }
    }
}

enum CodexAppServerUserInput: Codable, Hashable, Identifiable {
    case text(String, textElements: [CodexAppServerJSONValue] = [])
    case image(url: String, detail: CodexAppServerImageDetail? = nil)
    case localImage(path: String, detail: CodexAppServerImageDetail? = nil)
    case uploadedFile(UploadedFileAttachment)
    case skill(name: String, path: String)
    case mention(name: String, path: String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case textElements = "text_elements"
        case url
        case path
        case name
        case detail
        case file
    }

    var id: String {
        switch self {
        case .text(let text, _):
            return "text:\(text)"
        case .image(let url, _):
            return "image:\(Self.stableDigest(url))"
        case .localImage(let path, _):
            return "localImage:\(path)"
        case .uploadedFile(let file):
            return "uploadedFile:\(file.uploadID)"
        case .skill(let name, let path):
            return "skill:\(name):\(path)"
        case .mention(let name, let path):
            return "mention:\(name):\(path)"
        }
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    var retainedAfterAcceptedSend: CodexAppServerUserInput? {
        switch self {
        case .image:
            // 图片消息发送成功后仍然要保留可渲染来源，否则 UI 只能剩下「[图片]」占位。
            // 这里牺牲一点内存，换取当前会话里的真实图片预览和失败重试一致性。
            return self
        default:
            return self
        }
    }

    var previewText: String {
        switch self {
        case .text(let text, _):
            return text
        case .image:
            return L10n.text("ui.image_attachment")
        case .localImage(let path, _):
            return L10n.format("ui.image_value", URL(fileURLWithPath: path).lastPathComponent)
        case .uploadedFile(let file):
            return file.name
        case .skill(let name, _):
            return "[$\(name)]"
        case .mention(let name, _):
            return "[@\(name)]"
        }
    }

    var jsonValue: CodexAppServerJSONValue {
        switch self {
        case .text(let text, let textElements):
            return .object([
                "type": .string("text"),
                "text": .string(text),
                "text_elements": .array(textElements)
            ])
        case .image(let url, let detail):
            var object: [String: CodexAppServerJSONValue] = [
                "type": .string("image"),
                "url": .string(url)
            ]
            if let detail {
                object["detail"] = .string(detail.rawValue)
            }
            return .object(object)
        case .localImage(let path, let detail):
            var object: [String: CodexAppServerJSONValue] = [
                "type": .string("localImage"),
                "path": .string(path)
            ]
            if let detail {
                object["detail"] = .string(detail.rawValue)
            }
            return .object(object)
        case .uploadedFile(let file):
            // uploadedFile 是移动端本地持久化类型；真正发往 app-server 时由
            // appServerJSONValues 展开为 text + image，绝不发送未知协议类型。
            return MimiFileContextCodec.contextInput(for: file).jsonValue
        case .skill(let name, let path):
            return .object([
                "type": .string("skill"),
                "name": .string(name),
                "path": .string(path)
            ])
        case .mention(let name, let path):
            return .object([
                "type": .string("mention"),
                "name": .string(name),
                "path": .string(path)
            ])
        }
    }

    var appServerJSONValues: [CodexAppServerJSONValue] {
        switch self {
        case .uploadedFile(let file):
            return MimiFileContextCodec.expandedInputs(for: file).map(\.jsonValue)
        default:
            return [jsonValue]
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(
                try container.decode(String.self, forKey: .text),
                textElements: try container.decodeIfPresent([CodexAppServerJSONValue].self, forKey: .textElements) ?? []
            )
        case "image":
            self = .image(
                url: try container.decode(String.self, forKey: .url),
                detail: try container.decodeIfPresent(CodexAppServerImageDetail.self, forKey: .detail)
            )
        case "localImage":
            self = .localImage(
                path: try container.decode(String.self, forKey: .path),
                detail: try container.decodeIfPresent(CodexAppServerImageDetail.self, forKey: .detail)
            )
        case "uploadedFile":
            self = .uploadedFile(try container.decode(UploadedFileAttachment.self, forKey: .file))
        case "skill":
            self = .skill(
                name: try container.decode(String.self, forKey: .name),
                path: try container.decode(String.self, forKey: .path)
            )
        case "mention":
            self = .mention(
                name: try container.decode(String.self, forKey: .name),
                path: try container.decode(String.self, forKey: .path)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: L10n.format("ui.unknown_app_server_userinput_type_value", type)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let textElements):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(textElements, forKey: .textElements)
        case .image(let url, let detail):
            try container.encode("image", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(detail, forKey: .detail)
        case .localImage(let path, let detail):
            try container.encode("localImage", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(detail, forKey: .detail)
        case .uploadedFile(let file):
            try container.encode("uploadedFile", forKey: .type)
            try container.encode(file, forKey: .file)
        case .skill(let name, let path):
            try container.encode("skill", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        case .mention(let name, let path):
            try container.encode("mention", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        }
    }
}

enum CodexAppServerReasoningEffort: String, Codable, CaseIterable, Hashable, Identifiable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var id: String { rawValue }
}

enum CodexAppServerReasoningSummary: String, Codable, CaseIterable, Hashable, Identifiable {
    case auto
    case concise
    case detailed
    case none

    var id: String { rawValue }
}

enum CodexAppServerPersonality: String, Codable, CaseIterable, Hashable, Identifiable {
    case none
    case friendly
    case pragmatic

    var id: String { rawValue }
}

private enum CodexAppServerDefaults {
    static let model: String? = nil
    static let reasoningEffort: CodexAppServerReasoningEffort = .xhigh
}

enum CodexAppServerApprovalPolicy: String, Codable, CaseIterable, Hashable, Identifiable {
    case untrusted
    case onRequest = "on-request"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.untrusted.rawValue:
            self = .untrusted
        case Self.onRequest.rawValue, "on-failure":
            // 旧版 Mimi 会把自动审批持久化为 on-failure。新版 app-server 已删除该值，
            // 因此只在本地解码时迁移，任何后续持久化和请求都统一写回 on-request。
            self = .onRequest
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported approval policy: \(rawValue)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum CodexAppServerSandboxMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case readOnly
    case workspaceWrite
    case dangerFullAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readOnly:
            return L10n.text("ui.read_only")
        case .workspaceWrite:
            return L10n.text("ui.writable")
        case .dangerFullAccess:
            return L10n.text("ui.full_access")
        }
    }
}

struct CodexAppServerTurnOptions: Codable, Hashable {
    enum CollaborationMode: String, Codable, Hashable {
        case plan
        case `default`
    }

    enum ModelSelectionPolicy: String, Codable, Hashable {
        case catalogOnly
        case allowUnlisted
    }

    var runtimeProvider: String?
    var model: String?
    var modelProvider: String?
    var serviceTier: String?
    var reasoningEffort: CodexAppServerReasoningEffort?
    var reasoningSummary: CodexAppServerReasoningSummary?
    var approvalPolicy: CodexAppServerApprovalPolicy
    var approvalsReviewer: String
    var sandboxMode: CodexAppServerSandboxMode
    var networkAccess: Bool
    // 命名权限配置档案由 app-server 解析。存在时必须替代旧 sandbox 字段，不能叠加发送。
    var permissionProfileID: String?
    var personality: CodexAppServerPersonality?
    var config: CodexAppServerJSONValue?
    var baseInstructions: String?
    var developerInstructions: String?
    var outputSchema: CodexAppServerJSONValue?
    var serviceName: String?
    var sessionStartSource: String?
    var threadSource: String?
    // 只在 iPad 发起 turn/start 时消费的本地发送配置；不模拟 prompt，不影响 thread/start。
    var collaborationMode: CollaborationMode?
    // 仅供本地派发前校验使用，不进入 app-server 请求；随队列持久化以保留提交时的权限边界。
    var modelSelectionPolicy: ModelSelectionPolicy

    enum CodingKeys: String, CodingKey {
        case runtimeProvider = "runtime_provider"
        case model
        case modelProvider = "model_provider"
        case serviceTier = "service_tier"
        case reasoningEffort = "reasoning_effort"
        case reasoningSummary = "reasoning_summary"
        case approvalPolicy = "approval_policy"
        case approvalsReviewer = "approvals_reviewer"
        case sandboxMode = "sandbox_mode"
        case networkAccess = "network_access"
        case permissionProfileID = "permission_profile_id"
        case personality
        case config
        case baseInstructions = "base_instructions"
        case developerInstructions = "developer_instructions"
        case outputSchema = "output_schema"
        case serviceName = "service_name"
        case sessionStartSource = "session_start_source"
        case threadSource = "thread_source"
        case collaborationMode = "collaboration_mode"
        case modelSelectionPolicy = "model_selection_policy"
    }

    init(
        runtimeProvider: String? = nil,
        model: String? = CodexAppServerDefaults.model,
        modelProvider: String? = nil,
        serviceTier: String? = nil,
        reasoningEffort: CodexAppServerReasoningEffort? = CodexAppServerDefaults.reasoningEffort,
        reasoningSummary: CodexAppServerReasoningSummary? = nil,
        approvalPolicy: CodexAppServerApprovalPolicy = .onRequest,
        approvalsReviewer: String = "user",
        sandboxMode: CodexAppServerSandboxMode = .dangerFullAccess,
        networkAccess: Bool = false,
        permissionProfileID: String? = nil,
        personality: CodexAppServerPersonality? = nil,
        config: CodexAppServerJSONValue? = nil,
        baseInstructions: String? = nil,
        developerInstructions: String? = nil,
        outputSchema: CodexAppServerJSONValue? = nil,
        serviceName: String? = nil,
        sessionStartSource: String? = nil,
        threadSource: String? = nil,
        collaborationMode: CollaborationMode? = .default,
        modelSelectionPolicy: ModelSelectionPolicy = .catalogOnly
    ) {
        self.runtimeProvider = runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
        self.model = model
        self.modelProvider = modelProvider
        self.serviceTier = serviceTier
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.sandboxMode = sandboxMode
        self.networkAccess = networkAccess
        self.permissionProfileID = permissionProfileID?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
        self.personality = personality
        self.config = config
        self.baseInstructions = baseInstructions
        self.developerInstructions = developerInstructions
        self.outputSchema = outputSchema
        self.serviceName = serviceName
        self.sessionStartSource = sessionStartSource
        self.threadSource = threadSource
        self.collaborationMode = collaborationMode
        self.modelSelectionPolicy = modelSelectionPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            runtimeProvider: try container.decodeIfPresent(String.self, forKey: .runtimeProvider),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            modelProvider: try container.decodeIfPresent(String.self, forKey: .modelProvider),
            serviceTier: try container.decodeIfPresent(String.self, forKey: .serviceTier),
            reasoningEffort: try container.decodeIfPresent(CodexAppServerReasoningEffort.self, forKey: .reasoningEffort) ?? CodexAppServerDefaults.reasoningEffort,
            reasoningSummary: try container.decodeIfPresent(CodexAppServerReasoningSummary.self, forKey: .reasoningSummary),
            approvalPolicy: try container.decodeIfPresent(CodexAppServerApprovalPolicy.self, forKey: .approvalPolicy) ?? .onRequest,
            approvalsReviewer: try container.decodeIfPresent(String.self, forKey: .approvalsReviewer) ?? "user",
            sandboxMode: try container.decodeIfPresent(CodexAppServerSandboxMode.self, forKey: .sandboxMode) ?? .dangerFullAccess,
            networkAccess: try container.decodeIfPresent(Bool.self, forKey: .networkAccess) ?? false,
            permissionProfileID: try container.decodeIfPresent(String.self, forKey: .permissionProfileID),
            personality: try container.decodeIfPresent(CodexAppServerPersonality.self, forKey: .personality),
            config: try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .config),
            baseInstructions: try container.decodeIfPresent(String.self, forKey: .baseInstructions),
            developerInstructions: try container.decodeIfPresent(String.self, forKey: .developerInstructions),
            outputSchema: try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .outputSchema),
            serviceName: try container.decodeIfPresent(String.self, forKey: .serviceName),
            sessionStartSource: try container.decodeIfPresent(String.self, forKey: .sessionStartSource),
            threadSource: try container.decodeIfPresent(String.self, forKey: .threadSource),
            collaborationMode: try container.decodeIfPresent(CollaborationMode.self, forKey: .collaborationMode) ?? .default,
            modelSelectionPolicy: try container.decodeIfPresent(ModelSelectionPolicy.self, forKey: .modelSelectionPolicy) ?? .catalogOnly
        )
    }

    static let `default` = CodexAppServerTurnOptions(
        runtimeProvider: nil,
        model: CodexAppServerDefaults.model,
        modelProvider: nil,
        serviceTier: nil,
        reasoningEffort: CodexAppServerDefaults.reasoningEffort,
        reasoningSummary: nil,
        approvalPolicy: .onRequest,
        approvalsReviewer: "user",
        sandboxMode: .dangerFullAccess,
        networkAccess: false,
        permissionProfileID: nil,
        personality: nil,
        config: nil,
        baseInstructions: nil,
        developerInstructions: nil,
        outputSchema: nil,
        serviceName: nil,
        sessionStartSource: nil,
        threadSource: nil,
        collaborationMode: .default,
        modelSelectionPolicy: .catalogOnly
    )

    func sanitizedForStandardComposer() -> CodexAppServerTurnOptions {
        var sanitized = self
        // 标准模式只保留用户能从主工具栏明确选择的运行偏好；权限按钮现在是主工具栏的一部分，
        // 因此保留安全的审批/沙盒预设，但仍清掉高级 JSON、网络访问和其它隐藏运行时字段。
        sanitized.applyStandardComposerPermissionPreset()
        sanitized.modelProvider = nil
        sanitized.networkAccess = false
        sanitized.config = nil
        sanitized.baseInstructions = nil
        sanitized.developerInstructions = nil
        sanitized.outputSchema = nil
        sanitized.serviceName = nil
        sanitized.sessionStartSource = nil
        sanitized.threadSource = nil
        sanitized.collaborationMode = .default
        sanitized.modelSelectionPolicy = .catalogOnly
        return sanitized
    }

    func sanitizedForRuntimePolicy() -> CodexAppServerTurnOptions {
        var sanitized = self
        guard sanitized.runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "claude" else {
            return sanitized
        }
        // Claude 只开放 default / plan / auto 三档安全映射。旧草稿或高级 JSON 即使携带
        // fullAccess/never，也必须在移动端和 gateway 两端同时降级，绝不映射 bypassPermissions。
        let reviewer = sanitized.approvalsReviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.sandboxMode == .readOnly {
            sanitized.approvalPolicy = .onRequest
            sanitized.approvalsReviewer = "user"
        } else if sanitized.approvalPolicy == .onRequest, reviewer == "auto_review" {
            sanitized.sandboxMode = .workspaceWrite
            sanitized.approvalsReviewer = "auto_review"
        } else {
            sanitized.approvalPolicy = .onRequest
            sanitized.approvalsReviewer = "user"
            sanitized.sandboxMode = .workspaceWrite
        }
        sanitized.networkAccess = false
        return sanitized
    }

    private mutating func applyStandardComposerPermissionPreset() {
        if permissionProfileID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            approvalPolicy = .onRequest
            approvalsReviewer = "user"
            networkAccess = false
            return
        }
        let reviewer = approvalsReviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        if sandboxMode == .readOnly {
            approvalPolicy = .onRequest
            approvalsReviewer = "user"
            return
        }
        if sandboxMode == .dangerFullAccess {
            approvalPolicy = .onRequest
            approvalsReviewer = "user"
            return
        }
        if approvalPolicy == .onRequest, reviewer == "auto_review" {
            approvalsReviewer = reviewer
            sandboxMode = .workspaceWrite
            return
        }
        approvalPolicy = .onRequest
        approvalsReviewer = "user"
        sandboxMode = .workspaceWrite
    }

    func turnParams(projectPath: String) -> [String: CodexAppServerJSONValue?] {
        let profileID = permissionProfileID.flatMap(nonEmptyString)
        return [
            "model": model.flatMap(nonEmptyString).map { .string($0) },
            "serviceTier": serviceTier.flatMap(nonEmptyString).map { .string($0) },
            "effort": reasoningEffort.map { .string($0.rawValue) },
            "summary": reasoningSummary.map { .string($0.rawValue) },
            "approvalPolicy": .string(approvalPolicy.rawValue),
            "approvalsReviewer": .string(approvalsReviewer),
            "permissions": profileID.map { .string($0) },
            "sandboxPolicy": profileID == nil ? sandboxPolicy(projectPath: projectPath) : nil,
            "personality": personality.map { .string($0.rawValue) },
            "outputSchema": outputSchema,
            // app-server 会把 collaboration mode 作为 turn 级状态处理；普通模式也必须显式发送
            // default，避免上一轮 Plan Mode 在上游被沿用。
            "collaborationMode": collaborationModePayload(mode: collaborationMode ?? .default)
        ]
    }

    func threadParams(projectPath: String) -> [String: CodexAppServerJSONValue?] {
        let profileID = permissionProfileID.flatMap(nonEmptyString)
        return [
            "model": model.flatMap(nonEmptyString).map { .string($0) },
            "modelProvider": modelProvider.flatMap(nonEmptyString).map { .string($0) },
            "serviceTier": serviceTier.flatMap(nonEmptyString).map { .string($0) },
            "approvalPolicy": .string(approvalPolicy.rawValue),
            "approvalsReviewer": .string(approvalsReviewer),
            "permissions": profileID.map { .string($0) },
            "sandbox": profileID == nil ? .string(threadSandboxValue) : nil,
            "personality": personality.map { .string($0.rawValue) },
            "config": config,
            "serviceName": serviceName.flatMap(nonEmptyString).map { .string($0) },
            "baseInstructions": baseInstructions.flatMap(nonEmptyString).map { .string($0) },
            "developerInstructions": developerInstructions.flatMap(nonEmptyString).map { .string($0) },
            "sessionStartSource": sessionStartSource.flatMap(nonEmptyString).map { .string($0) },
            "threadSource": threadSource.flatMap(nonEmptyString).map { .string($0) }
        ]
    }

    private func sandboxPolicy(projectPath: String) -> CodexAppServerJSONValue {
        switch sandboxMode {
        case .readOnly:
            return .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(networkAccess)
            ])
        case .workspaceWrite:
            return .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array([.string(projectPath)]),
                "networkAccess": .bool(networkAccess),
                "excludeTmpdirEnvVar": .bool(false),
                "excludeSlashTmp": .bool(false)
            ])
        case .dangerFullAccess:
            return .object([
                "type": .string("dangerFullAccess"),
                "networkAccess": .bool(networkAccess)
            ])
        }
    }

    private var threadSandboxValue: String {
        switch sandboxMode {
        case .readOnly:
            return "read-only"
        case .workspaceWrite:
            return "workspace-write"
        case .dangerFullAccess:
            return "danger-full-access"
        }
    }

    private func nonEmptyString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func collaborationModePayload(mode: CollaborationMode) -> CodexAppServerJSONValue {
        // Plan/default 都带 settings：Plan 用于启用规划协作，default 用于明确退出规划协作。
        // 移动端固定发送 null，避免透传危险自定义指令；可信 gateway 会为 default
        // 注入固定的退出 Plan 指令，规避部分 app-server 版本不展开 null 的问题。
        var settings: [String: CodexAppServerJSONValue] = [
            "reasoning_effort": reasoningEffort.map { .string($0.rawValue) } ?? .null,
            "developer_instructions": .null
        ]
        // 默认模型交给 app-server 根据账号 rollout 选择；只有用户显式选模型时才透传，避免
        // 硬编码模型在没有 rollout 权限的账号上触发 “no rollout found”。
        if let model = model.flatMap(nonEmptyString) {
            settings["model"] = .string(model)
        }
        return .object([
            "mode": .string(mode.rawValue),
            "settings": .object(settings)
        ])
    }
}

struct CodexAppServerTurnPayload: Codable, Hashable {
    static let maximumEncodedInputBytes = 12 << 20

    var input: [CodexAppServerUserInput]
    var options: CodexAppServerTurnOptions

    init(input: [CodexAppServerUserInput], options: CodexAppServerTurnOptions = .default) {
        self.input = input
        self.options = options
    }

    init(prompt: String, options: CodexAppServerTurnOptions = .default) {
        self.input = Self.defaultInput(for: prompt)
        self.options = options
    }

    var isEmpty: Bool {
        input.allSatisfy { item in
            switch item {
            case .text(let text, _):
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return false
            }
        }
    }

    var previewText: String {
        input.map(\.previewText)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var textPrompt: String {
        input.compactMap { item in
            if case .text(let text, _) = item {
                return text
            }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var appServerInput: CodexAppServerJSONValue {
        .array(input.flatMap(\.appServerJSONValues))
    }

    var encodedAppServerInputByteCount: Int {
        (try? JSONEncoder().encode(appServerInput).count) ?? Int.max
    }

    func retainedAfterAcceptedSend() -> CodexAppServerTurnPayload? {
        let retainedInput = input.compactMap(\.retainedAfterAcceptedSend)
        let retained = CodexAppServerTurnPayload(input: retainedInput, options: options)
        if retained.input.isEmpty && retained.options == .default {
            return nil
        }
        return retained
    }

    static func defaultInput(for prompt: String) -> [CodexAppServerUserInput] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [.text(trimmed)]
    }
}

struct CodexAppServerPermissionProfileSummary: Codable, Hashable, Identifiable {
    let id: String
    let description: String?

    static func parseListResult(_ result: CodexAppServerJSONValue?) -> [CodexAppServerPermissionProfileSummary] {
        guard let values = result?.objectValue?["data"]?.arrayValue else {
            return []
        }
        var seen: Set<String> = []
        return values.compactMap { value in
            guard let object = value.objectValue,
                  object["allowed"]?.boolValue == true,
                  let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  seen.insert(id).inserted
            else {
                return nil
            }
            return CodexAppServerPermissionProfileSummary(
                id: id,
                description: object["description"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
            )
        }
    }
}

struct CodexAppServerActivePermissionProfile: Codable, Hashable {
    let id: String
    let extends: String?

    init?(value: CodexAppServerJSONValue?) {
        guard let object = value?.objectValue,
              let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else {
            return nil
        }
        self.id = id
        self.extends = object["extends"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
    }
}

struct CodexAppServerModelOption: Codable, Hashable, Identifiable {
    let model: String
    let title: String
    let provider: String?
    let runtimeProvider: String?
    let description: String?
    let isDefault: Bool
    let supportedReasoningEfforts: [String]
    let defaultReasoningEffort: String?
    let hidden: Bool

    init(
        id: String,
        title: String? = nil,
        provider: String? = nil,
        runtimeProvider: String? = nil,
        description: String? = nil,
        isDefault: Bool = false,
        supportedReasoningEfforts: [String] = [],
        defaultReasoningEffort: String? = nil,
        hidden: Bool = false
    ) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmedID
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty ?? trimmedID
        self.provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
        self.runtimeProvider = runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
        self.description = description?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
        self.isDefault = isDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        self.defaultReasoningEffort = defaultReasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .appServerNilIfEmpty
        self.hidden = hidden
    }

    var id: String {
        [runtimeProvider, model, provider]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty }
            .joined(separator: "@")
    }

    func withRuntimeProvider(_ runtimeProvider: String) -> CodexAppServerModelOption {
        CodexAppServerModelOption(
            id: model,
            title: title,
            provider: provider,
            runtimeProvider: runtimeProvider,
            description: description,
            isDefault: isDefault,
            supportedReasoningEfforts: supportedReasoningEfforts,
            defaultReasoningEffort: defaultReasoningEffort,
            hidden: hidden
        )
    }

    var menuTitle: String {
        guard let provider else {
            return title
        }
        return "\(title) · \(provider)"
    }

    static let builtInFallback: [CodexAppServerModelOption] = [
        CodexAppServerModelOption(
            id: "gpt-5.6-sol",
            title: "GPT-5.6 Sol",
            description: "Detail and polish",
            isDefault: true,
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
            defaultReasoningEffort: "xhigh"
        ),
        CodexAppServerModelOption(
            id: "gpt-5.6-terra",
            title: "GPT-5.6 Terra",
            description: "Everyday workhorse",
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
            defaultReasoningEffort: "medium"
        ),
        CodexAppServerModelOption(
            id: "gpt-5.6-luna",
            title: "GPT-5.6 Luna",
            description: "Clear and repeatable",
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"],
            defaultReasoningEffort: "medium"
        ),
        CodexAppServerModelOption(id: "gpt-5.5", title: "GPT-5.5"),
        CodexAppServerModelOption(id: "gpt-5-codex", title: "gpt-5-codex"),
        CodexAppServerModelOption(id: "gpt-5.1-codex", title: "gpt-5.1-codex"),
        CodexAppServerModelOption(id: "gpt-5", title: "gpt-5"),
        CodexAppServerModelOption(id: "gpt-5.1", title: "gpt-5.1")
    ]

    static let builtInClaudeFallback: [CodexAppServerModelOption] = [
        CodexAppServerModelOption(
            id: "claude-fable-5",
            title: "Claude Fable 5",
            provider: "anthropic",
            runtimeProvider: "claude",
            description: "Anthropic's most capable generally available model for the hardest, longest-running agentic work.",
            supportedReasoningEfforts: ["medium", "high", "xhigh", "max"],
            defaultReasoningEffort: "high"
        ),
        CodexAppServerModelOption(
            id: "opus",
            title: "Claude Opus 5",
            provider: "anthropic",
            runtimeProvider: "claude",
            description: "Claude CLI alias resolved to the latest available Opus model.",
            isDefault: true,
            supportedReasoningEfforts: ["medium", "high", "xhigh", "max"],
            defaultReasoningEffort: "high"
        ),
        CodexAppServerModelOption(
            id: "sonnet",
            title: "Claude Sonnet 5",
            provider: "anthropic",
            runtimeProvider: "claude",
            description: "Claude CLI alias resolved to the latest available Sonnet model.",
            supportedReasoningEfforts: ["medium", "high", "xhigh", "max"],
            defaultReasoningEffort: "high"
        ),
        CodexAppServerModelOption(
            id: "haiku",
            title: "Claude Haiku 4.5",
            provider: "anthropic",
            runtimeProvider: "claude",
            description: "Claude CLI alias resolved to the latest available Haiku model."
        )
    ]

    static func parseListResult(_ result: CodexAppServerJSONValue?) -> [CodexAppServerModelOption] {
        let rawItems = modelItems(from: result)
        var seen: Set<String> = []
        var options: [CodexAppServerModelOption] = []
        for item in rawItems {
            guard let option = option(from: item), !seen.contains(option.id) else {
                continue
            }
            seen.insert(option.id)
            options.append(option)
        }
        // 数组顺序由各运行时的 model/list 定义，代表其推荐/新旧顺序；
        // 展示层会直接截取前三项，因此这里不能再按默认项或标题二次排序。
        return options
    }

    private static func modelItems(from result: CodexAppServerJSONValue?) -> [CodexAppServerJSONValue] {
        guard let result else {
            return []
        }
        if let items = result.arrayValue {
            return items
        }
        guard let object = result.objectValue else {
            return []
        }
        for key in ["models", "data", "items"] {
            if let items = object[key]?.arrayValue {
                return items
            }
            if let keyed = object[key]?.objectValue {
                return keyed.sorted(by: { $0.key < $1.key }).map { key, value in
                    if var object = value.objectValue {
                        object["id"] = object["id"] ?? .string(key)
                        return .object(object)
                    }
                    return .object(["id": .string(key), "title": value])
                }
            }
        }
        return object.sorted(by: { $0.key < $1.key }).map { key, value in
            if var item = value.objectValue {
                item["id"] = item["id"] ?? .string(key)
                return .object(item)
            }
            return .object(["id": .string(key), "title": value])
        }
    }

    private static func option(from item: CodexAppServerJSONValue) -> CodexAppServerModelOption? {
        if let id = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return CodexAppServerModelOption(id: id)
        }
        guard let object = item.objectValue else {
            return nil
        }
        let id = firstString(in: object, keys: ["id", "model", "name", "slug"])
        guard let id, !id.isEmpty else {
            return nil
        }
        return CodexAppServerModelOption(
            id: id,
            title: firstString(in: object, keys: ["title", "label", "displayName", "display_name", "name"]),
            provider: firstString(in: object, keys: ["provider", "modelProvider", "model_provider"]),
            runtimeProvider: firstString(in: object, keys: ["runtimeProvider", "runtime_provider", "runtime"]),
            description: firstString(in: object, keys: ["description", "summary"]),
            // app-server 历史返回里默认标记存在 camelCase 和 snake_case 两种形态。
            isDefault: object["isDefault"]?.boolValue ?? object["is_default"]?.boolValue ?? object["default"]?.boolValue ?? false,
            supportedReasoningEfforts: reasoningEfforts(in: object),
            defaultReasoningEffort: firstString(in: object, keys: ["defaultReasoningEffort", "default_reasoning_effort"]),
            hidden: object["hidden"]?.boolValue ?? false
        )
    }

    private static func reasoningEfforts(in object: [String: CodexAppServerJSONValue]) -> [String] {
        let values = object["supportedReasoningEfforts"]?.arrayValue
            ?? object["supported_reasoning_efforts"]?.arrayValue
            ?? []
        return values.compactMap { value in
            if let raw = value.stringValue {
                return raw
            }
            guard let option = value.objectValue else {
                return nil
            }
            return firstString(in: option, keys: ["reasoningEffort", "reasoning_effort", "effort", "id"])
        }
    }

    private static func firstString(in object: [String: CodexAppServerJSONValue], keys: [String]) -> String? {
        for key in keys {
            let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

indirect enum CodexAppServerJSONValue: Codable, Hashable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case object([String: CodexAppServerJSONValue])
    case array([CodexAppServerJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexAppServerJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CodexAppServerJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: L10n.text("ui.app_server_json_value_format_is_invalid"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return Int(value)
        case .double(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: CodexAppServerJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [CodexAppServerJSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    subscript(key: String) -> CodexAppServerJSONValue? {
        objectValue?[key]
    }

    static func objectValue(_ values: [String: CodexAppServerJSONValue?]) -> CodexAppServerJSONValue {
        .object(values.compactMapValues { $0 })
    }
}
