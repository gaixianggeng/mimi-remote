import Foundation

private enum CodexMimiTaskError: LocalizedError {
    case invalidArguments(String)
    case unsupportedTool(String)
    case callerUnavailable
    case unauthorizedThread(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): return message
        case .unsupportedTool(let name): return "Unsupported dynamic tool: \(name)"
        case .callerUnavailable: return "The calling thread is unavailable."
        case .unauthorizedThread(let id): return "Thread is outside the calling thread's project: \(id)"
        }
    }
}

private struct CodexMimiTaskScope {
    let projectID: String
    let projectPath: String
    let projectName: String
}

extension CodexAppServerSessionRuntime {
    func handleMimiTaskRequest(_ request: CodexAppServerServerRequest) {
        guard let connection else { return }
        guard let identity = Self.mimiTaskCallIdentity(request) else {
            Task { try? await self.respondMimiTaskFailure(request, code: "invalid_call_identity", connection: connection) }
            return
        }
        // JSON-RPC id 可以被网关重用；只有业务调用身份能阻止副作用重放。
        guard mimiTaskRequests[identity] == nil,
              !resolvedMimiTaskRequestIDs.contains(identity) else {
            Task { try? await self.respondMimiTaskFailure(request, code: "duplicate_call", connection: connection) }
            return
        }
        let task = Task { [weak self, request, connection] in
            guard let self else { return }
            do {
                let result = try await self.executeMimiTaskRequest(request)
                try Task.checkCancellation()
                try await connection.respond(
                    to: request,
                    result: try Self.mimiTaskToolResponse(result, success: true)
                )
            } catch is CancellationError {
                // 断连后旧 connection 已不可写；有界取消避免请求继续产生副作用。
            } catch {
                let failure = CodexAppServerJSONValue.object([
                    "error": .string(Self.safeMimiTaskErrorCode(error))
                ])
                try? await connection.respond(
                    to: request,
                    result: try Self.mimiTaskToolResponse(failure, success: false)
                )
            }
            await self.finishMimiTaskRequest(identity)
        }
        mimiTaskRequests[identity] = task
    }

    private func finishMimiTaskRequest(_ id: CodexMimiTaskCallIdentity) {
        mimiTaskRequests.removeValue(forKey: id)
        rememberResolvedMimiTaskRequest(id)
    }

    private func rememberResolvedMimiTaskRequest(_ id: CodexMimiTaskCallIdentity) {
        guard resolvedMimiTaskRequestIDs.insert(id).inserted else { return }
        resolvedMimiTaskRequestOrder.append(id)
        if resolvedMimiTaskRequestOrder.count > 256 {
            resolvedMimiTaskRequestIDs.remove(resolvedMimiTaskRequestOrder.removeFirst())
        }
    }

    func cancelMimiTaskRequests() {
        let identities = Array(mimiTaskRequests.keys)
        let tasks = mimiTaskRequests.values
        mimiTaskRequests.removeAll(keepingCapacity: true)
        identities.forEach(rememberResolvedMimiTaskRequest)
        tasks.forEach { $0.cancel() }
    }

    private func respondMimiTaskFailure(
        _ request: CodexAppServerServerRequest,
        code: String,
        connection: CodexAppServerConnection
    ) async throws {
        let failure = CodexAppServerJSONValue.object(["error": .string(code)])
        try await connection.respond(
            to: request,
            result: try Self.mimiTaskToolResponse(failure, success: false)
        )
    }

    private func executeMimiTaskRequest(
        _ request: CodexAppServerServerRequest
    ) async throws -> CodexAppServerJSONValue {
        let params = request.params?.objectValue ?? [:]
        guard params["namespace"]?.stringValue == CodexMimiTasksToolCatalog.namespace else {
            throw CodexMimiTaskError.unsupportedTool("invalid_namespace")
        }
        try Self.requireOnly(
            params,
            allowed: ["arguments", "callId", "namespace", "threadId", "tool", "turnId"]
        )
        let callerThreadID = try Self.requiredMimiTaskString(params, "threadId", maximumLength: 256)
        _ = try Self.requiredMimiTaskString(params, "turnId", maximumLength: 256)
        let callID = try Self.requiredMimiTaskString(params, "callId", maximumLength: 256)
        let tool = try Self.requiredMimiTaskString(params, "tool", maximumLength: 256)
        guard let arguments = params["arguments"]?.objectValue else {
            throw CodexMimiTaskError.invalidArguments("arguments must be a JSON object.")
        }
        let scope = try mimiTaskScope(callerThreadID: callerThreadID)
        let clientMessageID = Self.mimiTaskClientMessageID(callID: callID)

        switch tool {
        case "create_thread":
            try Self.requireOnly(arguments, allowed: ["prompt"])
            let prompt = try Self.requiredMimiTaskString(arguments, "prompt", maximumLength: 20_000)
            var options = CodexAppServerTurnOptions.default
            options.runtimeProvider = runtimeProvider
            let response = try await createSession(CreateSessionRequest(
                projectID: scope.projectID,
                projectPath: scope.projectPath,
                projectName: scope.projectName,
                prompt: prompt,
                turnOptions: options,
                resumeID: "",
                clientMessageID: clientMessageID
            ))
            if response.requiresQueuedInitialInput == true {
                let outcome = try await submitTurnOutcome(
                    sessionID: response.session.id,
                    payload: CodexAppServerTurnPayload(prompt: prompt),
                    clientMessageID: clientMessageID
                )
                if case .serverQueued = outcome {
                    rememberMimiTaskExpectedDelivery(
                        threadID: response.session.id,
                        clientMessageID: clientMessageID
                    )
                }
            }
            return .object(["thread": Self.mimiTaskThread(response.session)])

        case "list_threads":
            try Self.requireOnly(arguments, allowed: ["limit"])
            let limit = try Self.optionalMimiTaskInt(arguments, "limit", range: 1...50) ?? 20
            let page = try await sessionsPage(
                projectID: scope.projectID,
                cursor: nil,
                limit: limit,
                consistency: .fastIndexed
            )
            return .object(["threads": .array(page.sessions.map(Self.mimiTaskThread))])

        case "read_thread":
            try Self.requireOnly(arguments, allowed: ["threadId"])
            let threadID = try Self.requiredMimiTaskString(arguments, "threadId", maximumLength: 256)
            let session = try await authorizedMimiTaskSession(threadID, scope: scope)
            let page = try await messagesPage(
                sessionID: threadID,
                before: nil,
                limit: 6,
                loadMode: .economy
            )
            return .object([
                "thread": Self.mimiTaskThread(session),
                "messages": .array(Self.mimiTaskMessages(page.messages)),
                "hasMoreBefore": .bool(page.hasMoreBefore),
            ])

        case "send_message_to_thread":
            try Self.requireOnly(arguments, allowed: ["threadId", "prompt"])
            let threadID = try Self.requiredMimiTaskString(arguments, "threadId", maximumLength: 256)
            let prompt = try Self.requiredMimiTaskString(arguments, "prompt", maximumLength: 20_000)
            _ = try await authorizedMimiTaskSession(threadID, scope: scope)
            let outcome = try await submitTurnOutcome(
                sessionID: threadID,
                payload: CodexAppServerTurnPayload(prompt: prompt),
                clientMessageID: clientMessageID
            )
            if case .serverQueued = outcome {
                rememberMimiTaskExpectedDelivery(
                    threadID: threadID,
                    clientMessageID: clientMessageID
                )
            }
            return Self.mimiTaskSendResult(threadID: threadID, outcome: outcome)

        case "wait_threads":
            try Self.requireOnly(arguments, allowed: ["threadIds", "timeoutMs"])
            let ids = try Self.requiredMimiTaskStrings(arguments, "threadIds", count: 1...8)
            let timeout = try Self.optionalMimiTaskInt(arguments, "timeoutMs", range: 0...120_000) ?? 30_000
            return try await waitForMimiTaskThreads(ids, scope: scope, timeoutMilliseconds: timeout)

        default:
            throw CodexMimiTaskError.unsupportedTool(tool)
        }
    }

    private func mimiTaskScope(callerThreadID: SessionID) throws -> CodexMimiTaskScope {
        guard let caller = contextsBySessionID[callerThreadID]?.session else {
            throw CodexMimiTaskError.callerUnavailable
        }
        return CodexMimiTaskScope(
            projectID: caller.projectID,
            projectPath: caller.dir,
            projectName: caller.project
        )
    }

    private func authorizedMimiTaskSession(
        _ id: SessionID,
        scope: CodexMimiTaskScope
    ) async throws -> AgentSession {
        let value = try await session(id: id, afterSeq: nil).session
        guard value.projectID == scope.projectID,
              value.dir == scope.projectPath else {
            throw CodexMimiTaskError.unauthorizedThread(id)
        }
        return value
    }

    private func waitForMimiTaskThreads(
        _ ids: [SessionID],
        scope: CodexMimiTaskScope,
        timeoutMilliseconds: Int
    ) async throws -> CodexAppServerJSONValue {
        let initial = try await mimiTaskSessions(ids, scope: scope)
        if timeoutMilliseconds == 0 {
            return Self.mimiTaskWaitResult(
                initial,
                timedOut: !mimiTaskFinishedFromSessionState(initial)
            )
        }
        if try await mimiTaskWaitFinished(initial) {
            return Self.mimiTaskWaitResult(initial, timedOut: false)
        }
        return try await withThrowingTaskGroup(of: CodexAppServerJSONValue.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw CancellationError() }
                while true {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let all = try await self.mimiTaskSessions(ids, scope: scope)
                    if try await self.mimiTaskWaitFinished(all) {
                        return Self.mimiTaskWaitResult(all, timedOut: false)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000)
                let all = try await self.mimiTaskSessions(ids, scope: scope)
                return Self.mimiTaskWaitResult(all, timedOut: true)
            }
            let result = try await group.next() ?? Self.mimiTaskWaitResult(initial, timedOut: true)
            group.cancelAll()
            return result
        }
    }

    private func mimiTaskSessions(
        _ ids: [SessionID],
        scope: CodexMimiTaskScope
    ) async throws -> [AgentSession] {
        var result: [AgentSession] = []
        for id in ids { result.append(try await authorizedMimiTaskSession(id, scope: scope)) }
        return result
    }

    private func mimiTaskWaitFinished(_ sessions: [AgentSession]) async throws -> Bool {
        if mimiTaskFinishedFromSessionState(sessions) {
            return true
        }
        for session in sessions {
            guard let expected = mimiTaskExpectedDeliveries[session.id] else {
                continue
            }
            if try await mimiTaskQueuedDeliveryTerminal(
                sessionID: session.id,
                clientMessageID: expected.clientMessageID
            ) {
                mimiTaskExpectedDeliveries.removeValue(forKey: session.id)
                return true
            }
        }
        return false
    }

    private func mimiTaskFinishedFromSessionState(_ sessions: [AgentSession]) -> Bool {
        for session in sessions {
            if session.status == "waiting_for_input" || session.status == "waiting_for_approval" {
                return true
            }
            if session.status == "failed" || session.status == "closed" || session.status == "completed" {
                mimiTaskExpectedDeliveries.removeValue(forKey: session.id)
                return true
            }
            if mimiTaskExpectedDeliveries[session.id] == nil,
               session.status != "running",
               session.status != "queued" {
                return true
            }
        }
        return false
    }

    private func rememberMimiTaskExpectedDelivery(
        threadID: SessionID,
        clientMessageID: ClientMessageID
    ) {
        if mimiTaskExpectedDeliveries[threadID] == nil,
           mimiTaskExpectedDeliveries.count >= 256,
           let evictedThreadID = mimiTaskExpectedDeliveries.keys.first {
            mimiTaskExpectedDeliveries.removeValue(forKey: evictedThreadID)
        }
        mimiTaskExpectedDeliveries[threadID] = CodexMimiTaskExpectedDelivery(
            clientMessageID: clientMessageID
        )
    }

    private static func mimiTaskCallIdentity(
        _ request: CodexAppServerServerRequest
    ) -> CodexMimiTaskCallIdentity? {
        guard let params = request.params?.objectValue,
              let threadID = params["threadId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let turnID = params["turnId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let callID = params["callId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !threadID.isEmpty, threadID.count <= 256,
              !turnID.isEmpty, turnID.count <= 256,
              !callID.isEmpty, callID.count <= 256 else { return nil }
        return CodexMimiTaskCallIdentity(threadID: threadID, turnID: turnID, callID: callID)
    }

    private static func mimiTaskWaitResult(
        _ sessions: [AgentSession],
        timedOut: Bool
    ) -> CodexAppServerJSONValue {
        .object([
            "timedOut": .bool(timedOut),
            "threads": .array(sessions.map(mimiTaskThread)),
        ])
    }

    private static func mimiTaskSendResult(
        threadID: String,
        outcome: CodexAppServerTurnSubmissionOutcome
    ) -> CodexAppServerJSONValue {
        var value: [String: CodexAppServerJSONValue] = ["threadId": .string(threadID)]
        switch outcome {
        case .direct(let start):
            value["turnId"] = start.activeTurnID.map(CodexAppServerJSONValue.string) ?? .null
        case .serverQueued(let submissionID, let startedTurnID):
            value["submissionId"] = .string(submissionID)
            value["turnId"] = startedTurnID.map(CodexAppServerJSONValue.string) ?? .null
        }
        return .object(value)
    }

    private static func mimiTaskThread(_ session: AgentSession) -> CodexAppServerJSONValue {
        .object([
            "id": .string(session.id),
            "title": .string(mimiTaskUTF8Prefix(session.title, maximumBytes: 200)),
            "status": .string(session.status),
            "updatedAt": session.updatedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
        ])
    }

    private static func mimiTaskMessages(_ messages: [CodexHistoryMessage]) -> [CodexAppServerJSONValue] {
        let relevant = messages.filter {
            $0.kind == .message || $0.kind == .commentary || $0.kind == .error
        }
        var remainingBytes = 8_000
        var latestFirst: [CodexAppServerJSONValue] = []
        for message in relevant.suffix(12).reversed() where remainingBytes > 0 {
            let content = mimiTaskUTF8Prefix(message.content, maximumBytes: min(4_000, remainingBytes))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            remainingBytes -= content.utf8.count
            latestFirst.append(.object([
                "role": .string(message.role),
                "kind": .string(message.kind.rawValue),
                "content": .string(content),
            ]))
        }
        return Array(latestFirst.reversed())
    }

    private static func mimiTaskUTF8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var result = ""
        result.reserveCapacity(min(value.count, maximumBytes))
        var usedBytes = 0
        for character in value {
            let text = String(character)
            let bytes = text.utf8.count
            guard usedBytes + bytes <= maximumBytes else { break }
            result.append(character)
            usedBytes += bytes
        }
        return result
    }

    private static func requireOnly(
        _ arguments: [String: CodexAppServerJSONValue],
        allowed: Set<String>
    ) throws {
        let unknown = Set(arguments.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw CodexMimiTaskError.invalidArguments("Unknown argument: \(unknown.sorted().joined(separator: ", "))")
        }
    }

    private static func requiredMimiTaskString(
        _ arguments: [String: CodexAppServerJSONValue],
        _ key: String,
        maximumLength: Int
    ) throws -> String {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= maximumLength else {
            throw CodexMimiTaskError.invalidArguments("\(key) must be a non-empty string.")
        }
        return value
    }

    private static func requiredMimiTaskStrings(
        _ arguments: [String: CodexAppServerJSONValue],
        _ key: String,
        count: ClosedRange<Int>
    ) throws -> [String] {
        guard let rawValues = arguments[key]?.arrayValue,
              rawValues.allSatisfy({ $0.stringValue != nil }) else {
            throw CodexMimiTaskError.invalidArguments("\(key) must contain \(count.lowerBound)...\(count.upperBound) thread identifiers.")
        }
        let values = rawValues.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var seen: Set<String> = []
        let unique = values.filter { seen.insert($0).inserted }
        guard count.contains(unique.count),
              unique.allSatisfy({ !$0.isEmpty && $0.count <= 256 }) else {
            throw CodexMimiTaskError.invalidArguments("\(key) must contain \(count.lowerBound)...\(count.upperBound) unique thread identifiers.")
        }
        return unique
    }

    private static func optionalMimiTaskInt(
        _ arguments: [String: CodexAppServerJSONValue],
        _ key: String,
        range: ClosedRange<Int>
    ) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        guard case .int(let raw) = value,
              let number = Int(exactly: raw),
              range.contains(number) else {
            throw CodexMimiTaskError.invalidArguments("\(key) must be an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return number
    }

    private static func mimiTaskJSONString(_ value: CodexAppServerJSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func mimiTaskToolResponse(
        _ value: CodexAppServerJSONValue,
        success: Bool
    ) throws -> CodexAppServerJSONValue {
        .object([
            "contentItems": .array([.object([
                "type": .string("inputText"),
                "text": .string(try mimiTaskJSONString(value)),
            ])]),
            "success": .bool(success),
        ])
    }

    private static func safeMimiTaskErrorCode(_ error: Error) -> String {
        guard let error = error as? CodexMimiTaskError else { return "task_failed" }
        switch error {
        case .invalidArguments: return "invalid_arguments"
        case .unsupportedTool: return "unsupported_tool"
        case .callerUnavailable: return "caller_unavailable"
        case .unauthorizedThread: return "unauthorized_thread"
        }
    }

    private static func mimiTaskClientMessageID(callID: String) -> String {
        let safe = callID.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return String(("mimi-task-" + String(safe)).prefix(256))
    }
}

// 终态请求清理与跨 pump 乱序防护独立维护，避免事件投影文件继续膨胀。
extension CodexAppServerSessionRuntime {
    private var terminalInteractionTombstoneLimit: Int { 512 }

    func isTerminalInteractionNotification(_ notification: CodexAppServerNotification) -> Bool {
        switch notification.method {
        case "turn/completed", "thread/closed":
            return true
        case "error":
            // app-server 会在同一 turn 内重试部分错误；willRetry 为 true 时仍会继续发送
            // 审批或补充信息请求，不能提前写 tombstone 或清空 pending request。
            return notification.params?.objectValue?["willRetry"]?.boolValue != true
        default:
            return false
        }
    }

    func clearPendingServerRequestsForTerminalNotification(_ notification: CodexAppServerNotification) {
        let params = notification.params?.objectValue ?? [:]
        guard let sessionID = approvalSessionID(from: params) else {
            return
        }
        let turnID = notification.method == "thread/closed"
            ? nil
            : firstString(in: params, keys: ["turnId", "turnID", "turn_id"])
                ?? params["turn"]?.objectValue?["id"]?.stringValue

        for request in Set(pendingApprovalRequestsByID.values)
        where terminalNotificationMatches(request: request, sessionID: sessionID, turnID: turnID) {
            removePendingApprovalRequest(request)
        }
        for request in Set(pendingUserInputRequestsByID.values)
        where terminalNotificationMatches(request: request, sessionID: sessionID, turnID: turnID) {
            removePendingUserInputRequest(request)
        }
        discardBufferedInteractionRequests(sessionID: sessionID, turnID: turnID)
    }

    func terminalNotificationMatches(
        request: CodexAppServerServerRequest,
        sessionID: SessionID,
        turnID: TurnID?
    ) -> Bool {
        guard approvalSessionID(for: request) == sessionID else {
            return false
        }
        guard let turnID else {
            return true
        }
        // URL 型 MCP elicitation 是协议允许的 thread 级独立请求，不属于刚结束的 turn。
        // 其它无 turnId 交互仍按当前 turn 处理，避免旧 form 在 reattach 时复活。
        guard let requestTurnID = approvalTurnID(for: request) else {
            return !isTurnIndependentMCPElicitation(request)
        }
        return requestTurnID == turnID
    }

    func discardBufferedInteractionRequests(sessionID: SessionID, turnID: TurnID?) {
        guard var events = bufferedEventsBySessionID[sessionID] else {
            return
        }
        events.removeAll { event in
            switch event {
            case .approvalRequest(_, let metadata),
                 .userInputRequest(_, let metadata):
                guard let turnID else {
                    return true
                }
                return metadata.turnID == nil || metadata.turnID == turnID
            default:
                return false
            }
        }
        if events.isEmpty {
            bufferedEventsBySessionID.removeValue(forKey: sessionID)
        } else {
            bufferedEventsBySessionID[sessionID] = events
        }
    }

    func isResolvedServerRequestTombstoned(_ request: CodexAppServerServerRequest) -> Bool {
        let sessionID = approvalSessionID(for: request)
        let ids = uniqueStrings([
            approvalID(for: request),
            userInputRequestID(for: request),
            request.id.description
        ].compactMap { $0 })
        return ids.contains { id in
            if let sessionID,
               resolvedServerRequestTombstonesByKey[
                   resolvedRequestTombstoneKey(sessionID: sessionID, requestID: id)
               ] != nil {
                return true
            }
            return resolvedServerRequestTombstonesByKey[
                resolvedRequestTombstoneKey(sessionID: nil, requestID: id)
            ] != nil
        }
    }

    func isTerminallyStaleServerRequest(_ request: CodexAppServerServerRequest) -> Bool {
        guard let sessionID = approvalSessionID(for: request) else {
            return false
        }
        if let turnID = approvalTurnID(for: request),
           terminalTurnTombstonesByKey[
               terminalTurnTombstoneKey(sessionID: sessionID, turnID: turnID)
           ] != nil {
            return true
        }
        guard approvalTurnID(for: request) == nil,
              terminalSessionBarriers[sessionID] != nil else {
            return false
        }
        // URL 型 MCP elicitation 可以在 thread 空闲时独立到达，不能被上一轮的 session
        // barrier 当作迟到请求拒绝；form 和工具授权仍保留原有 fail-closed 防护。
        if isTurnIndependentMCPElicitation(request) {
            return false
        }
        // 新 turn 的 RPC 与 turn/started 通知也可能跨 pump 乱序；本地已经明确在启动或持有
        // 非 terminal active turn 时，无 turnId MCP 请求属于新一轮，不能被上一轮 barrier 误杀。
        if sessionsStartingTurn.contains(sessionID)
            || contextsBySessionID[sessionID]?.activeTurnID != nil {
            return false
        }
        return true
    }

    func isTurnIndependentMCPElicitation(_ request: CodexAppServerServerRequest) -> Bool {
        guard request.method == "mcpServer/elicitation/request" else {
            return false
        }
        return request.params?.objectValue?["mode"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "url"
    }

    func discardBufferedResolvedInteractionRequests(
        sessionID: SessionID?,
        requestIDs: Set<String>
    ) {
        guard !requestIDs.isEmpty else {
            return
        }
        let sessionIDs = sessionID.map { [$0] } ?? Array(bufferedEventsBySessionID.keys)
        for candidateSessionID in sessionIDs {
            guard var events = bufferedEventsBySessionID[candidateSessionID] else {
                continue
            }
            events.removeAll { event in
                switch event {
                case .approvalRequest(let request, let metadata):
                    return requestIDs.contains(request.id)
                        || metadata.itemID.map(requestIDs.contains) == true
                case .userInputRequest(let request, let metadata):
                    return requestIDs.contains(request.id)
                        || metadata.itemID.map(requestIDs.contains) == true
                default:
                    return false
                }
            }
            if events.isEmpty {
                bufferedEventsBySessionID.removeValue(forKey: candidateSessionID)
            } else {
                bufferedEventsBySessionID[candidateSessionID] = events
            }
        }
    }

    func isApprovalLikeServerRequest(_ request: CodexAppServerServerRequest) -> Bool {
        let lower = request.method.lowercased()
        if lower.contains("approval") {
            return true
        }
        // URL 与带精确协议标记的 Codex MCP 工具调用使用明确的授权交互。
        return request.method == "mcpServer/elicitation/request"
            && codexMCPElicitationPresentation(
                params: request.params?.objectValue ?? [:]
            ) == .confirmation
    }

    func isUserInputServerRequest(_ request: CodexAppServerServerRequest) -> Bool {
        if request.method == "item/tool/requestUserInput" {
            return true
        }
        // 只有能被当前 UI 完整表达的 form 才进入补充信息卡。
        return request.method == "mcpServer/elicitation/request"
            && codexMCPElicitationPresentation(
                params: request.params?.objectValue ?? [:]
            ) == .form
    }

    func isUnsupportedMCPElicitation(_ request: CodexAppServerServerRequest) -> Bool {
        request.method == "mcpServer/elicitation/request"
            && codexMCPElicitationPresentation(
                params: request.params?.objectValue ?? [:]
            ) == .unsupported
    }

    func resolvedRequestTombstoneKey(sessionID: SessionID?, requestID: String) -> String {
        "\(sessionID ?? "*")#\(requestID)"
    }

    func terminalTurnTombstoneKey(sessionID: SessionID, turnID: TurnID) -> String {
        "\(sessionID)#\(turnID)"
    }

    func pruneInteractionTombstones() {
        for key in oldestTombstoneKeysToRemove(resolvedServerRequestTombstonesByKey) {
            resolvedServerRequestTombstonesByKey.removeValue(forKey: key)
        }
        for key in oldestTombstoneKeysToRemove(terminalTurnTombstonesByKey) {
            terminalTurnTombstonesByKey.removeValue(forKey: key)
        }
        for key in oldestTombstoneKeysToRemove(terminalSessionBarriers) {
            terminalSessionBarriers.removeValue(forKey: key)
        }
    }

    func oldestTombstoneKeysToRemove<Key: Hashable>(_ entries: [Key: Date]) -> [Key] {
        guard entries.count > terminalInteractionTombstoneLimit else {
            return []
        }
        return entries
            .sorted(by: { $0.value < $1.value })
            .prefix(entries.count - terminalInteractionTombstoneLimit)
            .map(\.key)
    }
}
