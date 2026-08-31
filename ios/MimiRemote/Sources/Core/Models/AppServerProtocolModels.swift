import Foundation

// Codex app-server JSON-RPC 消息与请求构建器，字段兼容逻辑保持原样。
// 多个 app-server DTO 需要同一空字符串兼容规则，保持 module-internal。
extension String {
    var appServerNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum CodexAppServerRequestID: Codable, Hashable, CustomStringConvertible {
    case int(Int64)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: L10n.text("ui.json_rpc_id_must_be_string_number_or"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var description: String {
        switch self {
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        case .null:
            return "null"
        }
    }
}

struct CodexAppServerRequest: Codable, Hashable {
    let id: CodexAppServerRequestID
    let method: String
    let params: CodexAppServerJSONValue?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
    }

    init(id: CodexAppServerRequestID, method: String, params: CodexAppServerJSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(CodexAppServerRequestID.self, forKey: .id)
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .params)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Codex app-server 线路格式会省略 jsonrpc 字段；这里保持原样，避免 Swift 端引入额外协议差异。
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

struct CodexAppServerNotification: Codable, Hashable {
    let method: String
    let params: CodexAppServerJSONValue?
    /// Claude resident bridge 给可回放帧附加的单调序号。Codex 原生通知
    /// 没有该字段，保持 nil 即可。
    let replaySequence: UInt64?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case method
        case params
        case replaySequence = "_alleycat_seq"
    }

    init(method: String, params: CodexAppServerJSONValue? = nil, replaySequence: UInt64? = nil) {
        self.method = method
        self.params = params
        self.replaySequence = replaySequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .params)
        self.replaySequence = try container.decodeIfPresent(UInt64.self, forKey: .replaySequence)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
        try container.encodeIfPresent(replaySequence, forKey: .replaySequence)
    }
}

struct CodexAppServerServerRequest: Codable, Hashable {
    let id: CodexAppServerRequestID
    let method: String
    let params: CodexAppServerJSONValue?
    let replaySequence: UInt64?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case replaySequence = "_alleycat_seq"
    }

    init(
        id: CodexAppServerRequestID,
        method: String,
        params: CodexAppServerJSONValue? = nil,
        replaySequence: UInt64? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.replaySequence = replaySequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(CodexAppServerRequestID.self, forKey: .id)
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .params)
        self.replaySequence = try container.decodeIfPresent(UInt64.self, forKey: .replaySequence)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
        try container.encodeIfPresent(replaySequence, forKey: .replaySequence)
    }
}

struct CodexAppServerError: Codable, Hashable, LocalizedError {
    let code: Int
    let message: String
    let data: CodexAppServerJSONValue?

    var errorDescription: String? {
        L10n.format("ui.app_server_error_value_value", code, message)
    }
}

struct CodexAppServerResponse: Codable, Hashable {
    let id: CodexAppServerRequestID
    let result: CodexAppServerJSONValue?
    let error: CodexAppServerError?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }

    init(id: CodexAppServerRequestID, result: CodexAppServerJSONValue? = nil, error: CodexAppServerError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(CodexAppServerRequestID.self, forKey: .id)
        self.result = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .result)
        self.error = try container.decodeIfPresent(CodexAppServerError.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

enum CodexAppServerMessage: Hashable {
    case response(CodexAppServerResponse)
    case notification(CodexAppServerNotification)
    case serverRequest(CodexAppServerServerRequest)
}

extension CodexAppServerMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
        case result
        case error
        case replaySequence = "_alleycat_seq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let method = try container.decodeIfPresent(String.self, forKey: .method) {
            let params = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .params)
            // 分类器必须保留桥接层的 replay cursor，否则离开会话后重连会从错误边界续传。
            let replaySequence = try container.decodeIfPresent(UInt64.self, forKey: .replaySequence)
            if container.contains(.id) {
                self = .serverRequest(CodexAppServerServerRequest(
                    id: try container.decode(CodexAppServerRequestID.self, forKey: .id),
                    method: method,
                    params: params,
                    replaySequence: replaySequence
                ))
            } else {
                self = .notification(CodexAppServerNotification(
                    method: method,
                    params: params,
                    replaySequence: replaySequence
                ))
            }
            return
        }
        guard container.contains(.id) else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: L10n.text("ui.json_rpc_response_missing_id"))
            )
        }
        self = .response(CodexAppServerResponse(
            id: try container.decode(CodexAppServerRequestID.self, forKey: .id),
            result: try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .result),
            error: try container.decodeIfPresent(CodexAppServerError.self, forKey: .error)
        ))
    }
}

struct CodexAppServerRequestSpec: Hashable {
    let method: String
    let params: CodexAppServerJSONValue?

    init(method: String, params: CodexAppServerJSONValue? = .object([:])) {
        self.method = method
        self.params = params
    }

    func request(id: CodexAppServerRequestID) -> CodexAppServerRequest {
        CodexAppServerRequest(id: id, method: method, params: params)
    }
}

enum CodexAppServerRequestBuilderError: LocalizedError, Equatable {
    case projectNotAllowlisted(String)
    case pathNotAllowlisted(String)
    case unsafeParameter(String)

    var errorDescription: String? {
        switch self {
        case .projectNotAllowlisted(let id):
            return L10n.format("ui.item_not_in_remote_allowlist_value", id)
        case .pathNotAllowlisted(let path):
            return L10n.format("ui.working_directory_is_not_in_remote_allowlist_value", path)
        case .unsafeParameter(let reason):
            return L10n.format("ui.app_server_request_parameters_are_unsafe_value", reason)
        }
    }
}

enum CodexAppServerReviewDelivery: String, Hashable {
    case inline
    case detached
}

enum CodexAppServerThreadUnsubscribeStatus: String, Hashable {
    case notLoaded
    case notSubscribed
    case unsubscribed
}

struct CodexAppServerReviewStartResult: Hashable {
    let reviewThreadID: String
    let turnID: String?
}

enum CodexAppServerReviewTarget: Hashable {
    case uncommittedChanges
    case baseBranch(String)
    case commit(sha: String, title: String? = nil)
    case custom(String)

    /// 移动端远程 Review 只接受可枚举目标；这里集中做 trim 和 custom 拒绝，
    /// 保证 UI、Store 与请求 builder 不会各自形成不同的安全边界。
    func validatedInlineTarget() throws -> CodexAppServerReviewTarget {
        switch self {
        case .uncommittedChanges:
            return .uncommittedChanges
        case .baseBranch(let branch):
            let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.review_base_branch_cannot_be_empty"))
            }
            return .baseBranch(normalized)
        case .commit(let sha, let title):
            let normalizedSHA = sha.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSHA.isEmpty else {
                throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.review_commit_sha_cannot_be_empty"))
            }
            return .commit(
                sha: normalizedSHA,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
            )
        case .custom:
            // custom 是自由提示词，应继续走 turn/start 的统一沙盒与审批约束。
            throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.remote_review_does_not_allow_custom_targets"))
        }
    }

    fileprivate func appServerValue() throws -> CodexAppServerJSONValue {
        switch self {
        case .uncommittedChanges:
            return .object(["type": .string("uncommittedChanges")])
        case .baseBranch(let branch):
            let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.review_base_branch_cannot_be_empty"))
            }
            return .object([
                "type": .string("baseBranch"),
                "branch": .string(normalized)
            ])
        case .commit(let sha, let title):
            let normalizedSHA = sha.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSHA.isEmpty else {
                throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.review_commit_sha_cannot_be_empty"))
            }
            return CodexAppServerJSONValue.objectValue([
                "type": .string("commit"),
                "sha": .string(normalizedSHA),
                "title": title?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty.map { .string($0) }
            ])
        case .custom(let instructions):
            let normalized = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.review_instructions_cannot_be_empty"))
            }
            return .object([
                "type": .string("custom"),
                "instructions": .string(normalized)
            ])
        }
    }
}

struct CodexAppServerRequestBuilder {
    private let projectsByID: [String: AgentProject]
    private let allowlistedPaths: Set<String>

    init(allowlistedProjects: [AgentProject]) {
        self.projectsByID = Dictionary(uniqueKeysWithValues: allowlistedProjects.map { ($0.id, $0) })
        self.allowlistedPaths = Set(allowlistedProjects.map(\.path).compactMap(Self.cleanedRemoteHostPath))
    }

    func threadList(
        cwd: String,
        limit: Int? = 20,
        cursor: String? = nil,
        useStateDBOnly: Bool = true,
        sortKey: String = "recency_at",
        refreshHistory: Bool = false
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        return CodexAppServerRequestSpec(method: "thread/list", params: CodexAppServerJSONValue.objectValue([
            "cwd": .string(path),
            "limit": limit.map { .int(Int64($0)) },
            "cursor": cursor.map { .string($0) },
            // recency_at 只随用户活动推进，避免 Agent 输出持续改写 updated_at 时侧栏来回跳。
            "sortKey": .string(sortKey),
            "sortDirection": .string("desc"),
            "archived": .bool(false),
            "useStateDbOnly": .bool(useStateDBOnly),
            // 只有 Claude 权威首屏才显式请求历史目录重扫；默认省略以兼容旧 runtime。
            "refreshHistory": refreshHistory ? .bool(true) : nil
        ]))
    }

    /// 无 cwd 列表只用于 agentd 的受控全局发现。客户端不携带项目过滤器，也不
    /// 依赖 experimental parent/ancestor API；路径与仓库身份裁剪完全由 gateway 完成。
    func controlledGlobalThreadList(
        limit: Int? = 50,
        cursor: String? = nil
    ) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/list", params: CodexAppServerJSONValue.objectValue([
            "limit": limit.map { .int(Int64($0)) },
            "cursor": cursor.map { .string($0) },
            "sortKey": .string("updated_at"),
            "sortDirection": .string("desc"),
            // thread/list 省略 sourceKinds 时只返回交互式会话。显式加入 subAgent，
            // 才能发现 Codex 从另一聊天派发、但没有 parentThreadId 的独立任务。
            // gateway 仍会按授权项目和 Git 仓库身份逐条裁剪这些全局结果。
            "sourceKinds": .array([
                .string("cli"),
                .string("vscode"),
                .string("appServer"),
                .string("subAgent"),
            ]),
            "archived": .bool(false),
            "useStateDbOnly": .bool(false)
        ]))
    }

    func threadSearch(
        query: String,
        limit: Int? = 50,
        cursor: String? = nil
    ) throws -> CodexAppServerRequestSpec {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchTerm.isEmpty else {
            throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.thread_search_search_term_cannot_be_empty"))
        }
        // thread/search 本身不接收 cwd。iOS 只发送搜索词和分页字段，目录授权与结果裁剪仍由
        // 既有 agentd gateway 策略负责，避免客户端借搜索接口注入任意工作目录。
        return CodexAppServerRequestSpec(method: "thread/search", params: CodexAppServerJSONValue.objectValue([
            "searchTerm": .string(searchTerm),
            "limit": limit.map { .int(Int64($0)) },
            "cursor": cursor.map { .string($0) },
            "sortKey": .string("updated_at"),
            "sortDirection": .string("desc"),
            "archived": .bool(false)
        ]))
    }

    func modelList() -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "model/list")
    }

    func permissionProfileList(cwd: String, limit: Int? = nil, cursor: String? = nil) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        return CodexAppServerRequestSpec(method: "permissionProfile/list", params: CodexAppServerJSONValue.objectValue([
            "cwd": .string(path),
            "limit": limit.map { .int(Int64($0)) },
            "cursor": cursor.map { .string($0) }
        ]))
    }

    func skillsList(cwd: String, forceReload: Bool = false) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        return CodexAppServerRequestSpec(method: "skills/list", params: .object([
            "cwds": .array([.string(path)]),
            "forceReload": .bool(forceReload)
        ]))
    }

    func installedPluginList(cwd: String) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        return CodexAppServerRequestSpec(method: "plugin/installed", params: .object([
            "cwds": .array([.string(path)])
        ]))
    }

    func accountRateLimitsRead() -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "account/rateLimits/read")
    }

    func accountUsageRead(forceRefresh: Bool = false) -> CodexAppServerRequestSpec {
        // 强制刷新提示只在 iOS 到 agentd 的 gateway 内生效；agentd 会在转发前剥离它。
        let params: CodexAppServerJSONValue? = forceRefresh
            ? .object(["mimiForceRefresh": .bool(true)])
            : nil
        return CodexAppServerRequestSpec(method: "account/usage/read", params: params)
    }

    func threadStart(projectID: String, model: String? = nil, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadStart(cwd: pathForProject(id: projectID), options: resolved)
    }

    func threadStart(cwd: String, model: String? = nil, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadStart(cwd: cwd, options: resolved)
    }

    func threadStart(cwd: String, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        options.threadParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/start", params: .object(params.compactMapValues { $0 }))
    }

    func threadStartForSharedQueue(
        cwd: String,
        options: CodexAppServerTurnOptions
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        options.threadParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        params["effort"] = options.reasoningEffort.map { .string($0.rawValue) }
        params["summary"] = options.reasoningSummary.map { .string($0.rawValue) }
        params["collaborationMode"] = options.turnParams(projectPath: path)["collaborationMode"] ?? nil
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(
            method: "thread/start",
            params: .object(params.compactMapValues { $0 })
        )
    }

    func threadResume(threadID: String, projectID: String, model: String? = nil, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadResume(threadID: threadID, cwd: pathForProject(id: projectID), options: resolved)
    }

    // 保留显式 model 的兼容入口；model 不设默认值，避免与支持初始历史页的新入口发生重载歧义。
    func threadResume(threadID: String, cwd: String, model: String?, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadResume(threadID: threadID, cwd: cwd, options: resolved)
    }

    func threadResume(
        threadID: String,
        cwd: String,
        options: CodexAppServerTurnOptions = .default,
        includeInitialTurnsPage: Bool = true
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        params["threadId"] = .string(threadID)
        params["excludeTurns"] = .bool(true)
        if includeInitialTurnsPage {
            // 恢复只顺带取最近小页，避免普通 resume 把整段 rollout 和内联图片重新下发。
            params["initialTurnsPage"] = .object([
                "limit": .int(5),
                "sortDirection": .string("desc"),
                // resume 只负责恢复监听和最近 turn 状态；完整内容继续由分页历史按需读取。
                "itemsView": .string("summary")
            ])
        }
        params["ephemeral"] = nil
        options.threadParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/resume", params: .object(params.compactMapValues { $0 }))
    }

    func threadResumePreservingSharedState(
        threadID: String,
        cwd: String,
        includeInitialTurnsPage: Bool = true
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params: [String: CodexAppServerJSONValue] = [
            "threadId": .string(threadID),
            "cwd": .string(path),
            "excludeTurns": .bool(true),
            // Shared SSH 中恢复只建立监听，不能让 gateway 写入 Mimi 的默认权限设置。
            "mimiPreserveThreadPermissions": .bool(true)
        ]
        if includeInitialTurnsPage {
            params["initialTurnsPage"] = .object([
                "limit": .int(5),
                "sortDirection": .string("desc"),
                "itemsView": .string("summary")
            ])
        }
        try validateRemoteSafeParams(params.mapValues { Optional($0) }, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/resume", params: .object(params))
    }

    func threadFork(
        threadID: String,
        cwd: String,
        lastTurnID: TurnID? = nil,
        options: CodexAppServerTurnOptions = .default
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        params["threadId"] = .string(threadID)
        params["excludeTurns"] = .bool(true)
        params["lastTurnId"] = lastTurnID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appServerNilIfEmpty
            .map(CodexAppServerJSONValue.string)
        options.threadParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        params["sessionStartSource"] = nil
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/fork", params: .object(params.compactMapValues { $0 }))
    }

    func threadRead(threadID: String, includeTurns: Bool = false) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/read", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "includeTurns": .bool(includeTurns)
        ]))
    }

    func threadSettingsUpdate(
        threadID: String,
        cwd: String,
        options: CodexAppServerTurnOptions
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        let turnParams = options.turnParams(projectPath: path)
        var params: [String: CodexAppServerJSONValue?] = [
            "threadId": .string(threadID)
        ]
        // 共享队列不接收 turn 级设置。只把本轮明确支持的运行设置提升为 Thread 设置，
        // 权限、输出结构和自定义指令仍走各自的受控链路，不能在普通消息里顺带改写。
        for key in ["model", "effort", "collaborationMode"] {
            params[key] = turnParams[key] ?? nil
        }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(
            method: "thread/settings/update",
            params: .object(params.compactMapValues { $0 })
        )
    }

    func threadQueueAdd(
        threadID: String,
        cwd: String,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        let params: [String: CodexAppServerJSONValue?] = [
            "threadId": .string(threadID),
            "input": payload.appServerInput,
            "clientUserMessageId": .string(clientMessageID)
        ]
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(
            method: "thread/queue/add",
            params: .object(params.compactMapValues { $0 })
        )
    }

    func threadQueueList(
        threadID: String,
        cursor: String? = nil,
        limit: Int = 100
    ) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/queue/list", params: .object([
            "threadId": .string(threadID),
            "cursor": cursor.map(CodexAppServerJSONValue.string),
            "limit": .int(Int64(limit))
        ].compactMapValues { $0 }))
    }

    func threadItemsList(
        threadID: String,
        turnID: TurnID? = nil,
        cursor: String? = nil,
        limit: Int = 100,
        sortDirection: String = "desc"
    ) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/items/list", params: .object([
            "threadId": .string(threadID),
            "turnId": turnID.map(CodexAppServerJSONValue.string),
            "cursor": cursor.map(CodexAppServerJSONValue.string),
            "limit": .int(Int64(limit)),
            "sortDirection": .string(sortDirection)
        ].compactMapValues { $0 }))
    }

    func threadTurnsList(
        threadID: String,
        cursor: String? = nil,
        limit: Int? = 40,
        sortDirection: String = "desc",
        itemsView: String = "full"
    ) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/turns/list", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "cursor": cursor.map { .string($0) },
            "limit": limit.map { .int(Int64($0)) },
            "sortDirection": .string(sortDirection),
            "itemsView": .string(itemsView)
        ]))
    }

    func threadGoalGet(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/goal/get", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func threadGoalSet(
        threadID: String,
        objective: String? = nil,
        status: ThreadGoalStatus? = nil,
        tokenBudget: Int64? = nil
    ) -> CodexAppServerRequestSpec {
        // 目标状态由 app-server 持久化；iPad 端只提交明确变化的字段。
        CodexAppServerRequestSpec(method: "thread/goal/set", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "objective": objective.map { .string($0) },
            "status": status.map { .string($0.rawValue) },
            "tokenBudget": tokenBudget.map { .int($0) }
        ]))
    }

    func threadGoalClear(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/goal/clear", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func threadArchive(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/archive", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func threadUnarchive(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/unarchive", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func threadSetName(threadID: String, name: String) throws -> CodexAppServerRequestSpec {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.session_name_cannot_be_empty"))
        }
        guard normalized.utf8.count <= 256 else {
            throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.session_name_cannot_exceed_256_bytes"))
        }
        return CodexAppServerRequestSpec(method: "thread/name/set", params: .object([
            "threadId": .string(threadID),
            "name": .string(normalized)
        ]))
    }

    func threadCompactStart(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/compact/start", params: .object([
            "threadId": .string(threadID)
        ]))
    }

    func threadUnsubscribe(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/unsubscribe", params: .object([
            "threadId": .string(threadID)
        ]))
    }

    func reviewStart(
        threadID: String,
        target: CodexAppServerReviewTarget,
        delivery: CodexAppServerReviewDelivery? = nil
    ) throws -> CodexAppServerRequestSpec {
        guard delivery != .detached else {
            // Gateway 第一批只允许原 thread 内 review，避免创建尚未登记授权的新 thread。
            throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.remote_review_only_allows_inline"))
        }
        let normalizedTarget = try target.validatedInlineTarget()
        // review target 使用官方当前的 discriminated union，避免继续传旧版自由 prompt。
        return CodexAppServerRequestSpec(method: "review/start", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "target": try normalizedTarget.appServerValue(),
            "delivery": delivery.map { .string($0.rawValue) }
        ]))
    }

    func turnStart(
        threadID: String,
        projectID: String,
        prompt: String,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        try turnStart(
            threadID: threadID,
            cwd: pathForProject(id: projectID),
            payload: CodexAppServerTurnPayload(prompt: prompt),
            clientMessageID: clientMessageID
        )
    }

    func turnStart(
        threadID: String,
        cwd: String,
        prompt: String,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        try turnStart(
            threadID: threadID,
            cwd: cwd,
            payload: CodexAppServerTurnPayload(prompt: prompt),
            clientMessageID: clientMessageID
        )
    }

    func turnStart(
        threadID: String,
        projectID: String,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        try turnStart(threadID: threadID, cwd: pathForProject(id: projectID), payload: payload, clientMessageID: clientMessageID)
    }

    func turnStart(
        threadID: String,
        cwd: String,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params: [String: CodexAppServerJSONValue?] = [
            "threadId": .string(threadID),
            "cwd": .string(path),
            "input": payload.appServerInput,
            "clientUserMessageId": clientMessageID.map { .string($0) }
        ]
        payload.options.turnParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "turn/start", params: .object(params.compactMapValues { $0 }))
    }

    func turnSteer(
        threadID: String,
        cwd: String,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID? = nil,
        expectedTurnID: TurnID
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        let params: [String: CodexAppServerJSONValue?] = [
            "threadId": .string(threadID),
            "input": payload.appServerInput,
            "clientUserMessageId": clientMessageID.map { .string($0) },
            "expectedTurnId": .string(expectedTurnID)
        ]
        // steer 是对当前 active turn 的补充输入，不携带模型/权限等 turn 启动参数；
        // 这里只复用结构化输入校验，确保附件路径仍然来自 allowlist。
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "turn/steer", params: .object(params.compactMapValues { $0 }))
    }

    func turnInterrupt(threadID: String, turnID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "turn/interrupt", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "turnId": .string(turnID)
        ]))
    }

    func validateRemoteSafeParams(_ params: CodexAppServerJSONValue, projectPath: String) throws {
        let path = try allowlistedPath(projectPath)
        guard let object = params.objectValue else {
            throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.params_must_be_object"))
        }
        try validateRemoteSafeParams(object.mapValues { Optional($0) }, projectPath: path)
    }

    private func pathForProject(id: String) throws -> String {
        guard let project = projectsByID[id] else {
            throw CodexAppServerRequestBuilderError.projectNotAllowlisted(id)
        }
        return try allowlistedPath(project.path)
    }

    private func allowlistedPath(_ path: String) throws -> String {
        let cleaned = Self.cleanedRemoteHostPath(path) ?? ""
        guard allowlistedPaths.contains(cleaned) else {
            throw CodexAppServerRequestBuilderError.pathNotAllowlisted(path.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return cleaned
    }

    private func safeThreadRuntimeParams(cwd: String) -> [String: CodexAppServerJSONValue?] {
        [
            "cwd": .string(cwd),
            // thread/start 只建立 app-server thread，使用 proven app-server 字段，不发送 runtimeWorkspaceRoots。
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"),
            "sandbox": .string("danger-full-access"),
            "ephemeral": .bool(false)
        ]
    }

    private func validateRemoteSafeParams(_ params: [String: CodexAppServerJSONValue?], projectPath: String) throws {
        if let cwd = params["cwd"]??.stringValue, cwd != projectPath {
            throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.cwd_must_be_from_project_allowlist"))
        }
        if normalizedDangerToken(params["approvalPolicy"]??.stringValue) == "never",
           !usesExplicitFullAccess(params) {
            throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.approvalpolicy_never_requires_full_access"))
        }
        try validateNoDangerousConfig(params["config"] ?? nil)
        if let profileID = params["permissions"]??.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard !profileID.isEmpty, profileID.utf8.count <= 256 else {
                throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.permission_profile_id_is_invalid"))
            }
            if (params["sandbox"] ?? nil) != nil || (params["sandboxPolicy"] ?? nil) != nil {
                throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.permission_profile_cannot_be_combined_with_legacy_sandbox"))
            }
        }
        guard let sandbox = params["sandboxPolicy"]??.objectValue else {
            return
        }
        // 完全访问可以显式关闭审批，但仍不默认打开网络访问。
        if sandbox["networkAccess"]?.boolValue == true {
            throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.remote_network_access_is_prohibited_by_default"))
        }
        let writableRoots = sandbox["writableRoots"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if writableRoots.contains(where: { $0 != projectPath }) {
            throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.writableroots_can_only_contain_the_current_allowlist_items"))
        }
        let inputPaths = try collectWorkspaceInputPaths(params["input"] ?? nil)
        if inputPaths.contains(where: { !isPathInAllowlist($0) }) {
            throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.structured_input_paths_must_come_from_the_current"))
        }
    }

    private func normalizedDangerToken(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private func usesExplicitFullAccess(_ params: [String: CodexAppServerJSONValue?]) -> Bool {
        if params["permissions"]??.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == ":danger-full-access" {
            return true
        }
        if normalizedDangerToken(params["sandbox"]??.stringValue) == "dangerfullaccess" {
            return true
        }
        return normalizedDangerToken(params["sandboxPolicy"]??.objectValue?["type"]?.stringValue) == "dangerfullaccess"
    }

    private func collectWorkspaceInputPaths(_ input: CodexAppServerJSONValue?) throws -> [String] {
        guard let items = input?.arrayValue else {
            return []
        }
        var paths: [String] = []
        for item in items {
            guard let object = item.objectValue else {
                throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.turn_start_input_item_must_be_object"))
            }
            let type = object["type"]?.stringValue ?? ""
            switch type {
            case "localImage", "mention":
                guard let path = object["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                    throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.format("ui.turn_start_input_value_path_cannot_be_empty", type))
                }
                paths.append(path)
            case "skill":
                // Skill 可能来自用户级 / 管理员级 skill root 或插件缓存，不一定在当前项目 allowlist 内。
                // 这里只校验字段完整性；skill root 的来源可信度由 agentd capabilities / app-server 负责。
                guard let path = object["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                    throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.turn_start_input_skill_path_cannot_be_empty"))
                }
            case "image":
                let url = object["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !url.isEmpty else {
                    throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.turn_start_input_image_url_cannot_be_empty"))
                }
                if url.lowercased().hasPrefix("file:") {
                    throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.image_url_does_not_allow_file_urls_please"))
                }
            case "text":
                continue
            default:
                throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.format("ui.turn_start_input_type_is_not_supported_value", type))
            }
        }
        return paths
    }

    private func isPathInAllowlist(_ raw: String) -> Bool {
        guard let path = Self.cleanedRemoteHostPath(raw) else {
            return false
        }
        return allowlistedPaths.contains { root in
            Self.remoteHostPath(path, isWithin: root)
        }
    }

    private func validateNoDangerousConfig(_ value: CodexAppServerJSONValue?, parentKey: String? = nil) throws {
        guard let value else {
            return
        }
        switch value {
        case .object(let object):
            for (key, child) in object {
                let normalizedKey = normalizedDangerToken(key)
                if normalizedKey == "dangerfullaccess" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.config_does_not_allow_dangerfullaccess"))
                }
                if normalizedKey == "approvalpolicy",
                   normalizedDangerToken(child.stringValue) == "never" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.config_does_not_allow_approvalpolicy_never"))
                }
                if normalizedKey == "sandbox" || normalizedKey == "sandboxmode" || (parentKey == "sandboxpolicy" && normalizedKey == "type"),
                   normalizedDangerToken(child.stringValue) == "dangerfullaccess" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.config_does_not_allow_dangerfullaccess"))
                }
                if normalizedKey == "networkaccess",
                   child.boolValue == true || child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter(L10n.text("ui.config_does_not_allow_networkaccess_true"))
                }
                try validateNoDangerousConfig(child, parentKey: normalizedKey)
            }
        case .array(let values):
            for child in values {
                try validateNoDangerousConfig(child, parentKey: parentKey)
            }
        default:
            return
        }
    }

    private static func cleanedRemoteHostPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        // 路径属于远程主机，可能使用 Windows、Unix 或其他文件系统语义。
        // iOS 只能清理传输层空白，不能用本机 Foundation URL 改写它。
        return trimmed
    }

    private static func remoteHostPath(_ path: String, isWithin root: String) -> Bool {
        guard path != root else {
            return true
        }

        let separator: Character = root.contains("\\") ? "\\" : "/"
        let prefix = root.last == separator ? root : root + String(separator)
        guard path.hasPrefix(prefix) else {
            return false
        }

        let relativePath = path.dropFirst(prefix.count)
        guard !relativePath.isEmpty else {
            return false
        }
        return !relativePath.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains {
            $0 == "." || $0 == ".."
        }
    }
}
