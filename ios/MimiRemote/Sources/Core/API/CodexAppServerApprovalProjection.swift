import Foundation

// 审批、用户输入与 MCP 反向请求的挂起登记、校验与响应构造集中在同一投影边界。
extension CodexAppServerSessionRuntime {
    func approvalID(for request: CodexAppServerServerRequest) -> String? {
        let params = request.params?.objectValue ?? [:]
        return params["approvalId"]?.stringValue
            ?? params["itemId"]?.stringValue
            ?? params["item_id"]?.stringValue
            ?? params["callId"]?.stringValue
            ?? request.id.description
    }

    func userInputRequestID(for request: CodexAppServerServerRequest) -> String? {
        let params = request.params?.objectValue ?? [:]
        return params["itemId"]?.stringValue
            ?? params["item_id"]?.stringValue
            ?? params["requestId"]?.stringValue
            ?? params["request_id"]?.stringValue
            ?? request.id.description
    }

    func rememberPendingApprovalRequest(_ request: CodexAppServerServerRequest) {
        guard isApprovalLikeServerRequest(request) else {
            return
        }
        for key in pendingApprovalStorageKeys(for: request) {
            pendingApprovalRequestsByID[key] = request
        }
    }

    func removePendingApprovalRequest(_ request: CodexAppServerServerRequest) {
        for key in pendingApprovalStorageKeys(for: request) {
            pendingApprovalRequestsByID.removeValue(forKey: key)
        }
    }

    func rememberPendingUserInputRequest(_ request: CodexAppServerServerRequest) {
        guard isUserInputServerRequest(request) else {
            return
        }
        for key in pendingUserInputStorageKeys(for: request) {
            pendingUserInputRequestsByID[key] = request
        }
    }

    func removePendingUserInputRequest(_ request: CodexAppServerServerRequest) {
        for key in pendingUserInputStorageKeys(for: request) {
            pendingUserInputRequestsByID.removeValue(forKey: key)
        }
    }

    func clearResolvedServerRequest(from notification: CodexAppServerNotification) -> CodexAppServerResolvedServerRequests {
        guard notification.method == "serverRequest/resolved" else {
            return CodexAppServerResolvedServerRequests()
        }
        let params = notification.params?.objectValue ?? [:]
        let sessionID = approvalSessionID(from: params)
        let ids = uniqueStrings([
            params["requestId"]?.stringValue,
            params["request_id"]?.stringValue,
            params["id"]?.stringValue,
            params["approvalId"]?.stringValue,
            params["itemId"]?.stringValue,
            params["item_id"]?.stringValue
        ].compactMap { $0 })
        let tombstoneTime = Date()
        for id in ids {
            resolvedServerRequestTombstonesByKey[
                resolvedRequestTombstoneKey(sessionID: sessionID, requestID: id)
            ] = tombstoneTime
        }
        pruneInteractionTombstones()

        var resolved = CodexAppServerResolvedServerRequests()
        for id in ids {
            for key in pendingApprovalLookupKeys(sessionID: sessionID, approvalID: id) {
                if let request = pendingApprovalRequestsByID.removeValue(forKey: key) {
                    if let affected = approvalSessionID(for: request), !resolved.approvalSessionIDs.contains(affected) {
                        resolved.approvalSessionIDs.append(affected)
                    }
                    removePendingApprovalRequest(request)
                }
            }
            for key in pendingUserInputLookupKeys(sessionID: sessionID, requestID: id) {
                if let request = pendingUserInputRequestsByID.removeValue(forKey: key) {
                    if let affected = approvalSessionID(for: request), !resolved.userInputSessionIDs.contains(affected) {
                        resolved.userInputSessionIDs.append(affected)
                    }
                    removePendingUserInputRequest(request)
                }
            }
        }
        discardBufferedResolvedInteractionRequests(sessionID: sessionID, requestIDs: Set(ids))
        return resolved
    }

    func clearAllPendingServerRequests() -> CodexAppServerResolvedServerRequests {
        let approvalSessionIDs = uniqueStrings(pendingApprovalRequestsByID.values.compactMap { request in
            approvalSessionID(for: request)
        })
        let userInputSessionIDs = uniqueStrings(pendingUserInputRequestsByID.values.compactMap { request in
            approvalSessionID(for: request)
        })
        pendingApprovalRequestsByID.removeAll(keepingCapacity: false)
        pendingUserInputRequestsByID.removeAll(keepingCapacity: false)
        return CodexAppServerResolvedServerRequests(approvalSessionIDs: approvalSessionIDs, userInputSessionIDs: userInputSessionIDs)
    }

    func emitApprovalResolved(sessionID: SessionID) {
        emit(.approvalResolved(AgentEventMetadata(
            seq: nil,
            sessionID: sessionID,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: Date()
        )))
    }

    func emitUserInputResolved(sessionID: SessionID, skipped: Bool) {
        emit(.userInputResolved(AgentEventMetadata(
            seq: nil,
            sessionID: sessionID,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: Date()
        ), skipped: skipped))
    }

    func pendingApprovalStorageKeys(for request: CodexAppServerServerRequest) -> [String] {
        let sessionID = approvalSessionID(for: request)
        let ids = uniqueStrings([approvalID(for: request), request.id.description].compactMap { $0 })
        return ids.flatMap { id in
            pendingApprovalLookupKeys(sessionID: sessionID, approvalID: id)
        }
    }

    func pendingApprovalLookupKeys(sessionID: SessionID?, approvalID: String) -> [String] {
        uniqueStrings([
            pendingApprovalScopedKey(sessionID: sessionID, approvalID: approvalID),
            approvalID
        ].compactMap { $0 })
    }

    func pendingApprovalScopedKey(sessionID: SessionID?, approvalID: String) -> String? {
        guard let sessionID, !sessionID.isEmpty else {
            return nil
        }
        return "\(sessionID)#\(approvalID)"
    }

    func pendingUserInputStorageKeys(for request: CodexAppServerServerRequest) -> [String] {
        let sessionID = approvalSessionID(for: request)
        let ids = uniqueStrings([userInputRequestID(for: request), request.id.description].compactMap { $0 })
        return ids.flatMap { id in
            pendingUserInputLookupKeys(sessionID: sessionID, requestID: id)
        }
    }

    func pendingUserInputLookupKeys(sessionID: SessionID?, requestID: String) -> [String] {
        uniqueStrings([
            pendingUserInputScopedKey(sessionID: sessionID, requestID: requestID),
            requestID
        ].compactMap { $0 })
    }

    func pendingUserInputScopedKey(sessionID: SessionID?, requestID: String) -> String? {
        guard let sessionID, !sessionID.isEmpty else {
            return nil
        }
        return "\(sessionID)#\(requestID)"
    }

    func approvalSessionID(for request: CodexAppServerServerRequest) -> SessionID? {
        approvalSessionID(from: request.params?.objectValue ?? [:])
    }

    func approvalTurnID(for request: CodexAppServerServerRequest) -> TurnID? {
        let params = request.params?.objectValue ?? [:]
        return params["turnId"]?.stringValue
            ?? params["turnID"]?.stringValue
            ?? params["turn_id"]?.stringValue
    }

    func approvalSessionID(from params: [String: CodexAppServerJSONValue]) -> SessionID? {
        CodexAppServerRequestScope.sessionID(in: params)
    }

    func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    func approvalResponse(
        method: String,
        params: [String: CodexAppServerJSONValue],
        decision: String
    ) -> CodexAppServerJSONValue {
        if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            return .object(["decision": .string(decision)])
        }
        if method == "item/permissions/requestApproval" {
            let normalizedDecision = normalizeApprovalDecision(decision)
            let requested = params["permissions"]
            let granted: CodexAppServerJSONValue
            if normalizedDecision == "accept", let requested, isValidRequestedPermissionProfile(requested) {
                // 当前界面只提供“批准全部请求项”与“拒绝”。原请求对象经过本地结构校验后
                // 原样返回，因此不会生成 App Server 没有请求过的路径或网络权限。
                granted = requested
            } else {
                granted = .object([:])
            }
            return .object([
                "permissions": granted,
                "scope": .string("turn"),
                "strictAutoReview": .bool(true)
            ])
        }
        if method == "mcpServer/elicitation/request" {
            if CodexMCPToolApprovalProtocol.isToolCall(params) {
                return mcpToolApprovalResponse(params: params, decision: decision)
            }
            return .object([
                "action": .string(decision == "accept" ? "accept" : decision == "cancel" ? "cancel" : "decline"),
                "content": .null,
                "_meta": .null
            ])
        }
        return .object(["decision": .string(decision)])
    }

    func isValidRequestedPermissionProfile(_ value: CodexAppServerJSONValue) -> Bool {
        guard let profile = value.objectValue,
              hasOnlyKeys(profile, ["fileSystem", "network"])
        else {
            return false
        }
        if let fileSystem = profile["fileSystem"], !isNull(fileSystem) {
            guard let object = fileSystem.objectValue, isValidRequestedFileSystemPermissions(object) else {
                return false
            }
        }
        if let network = profile["network"], !isNull(network) {
            guard let object = network.objectValue,
                  hasOnlyKeys(object, ["enabled"]),
                  object["enabled"].map({ isNull($0) || $0.boolValue != nil }) ?? true
            else {
                return false
            }
        }
        return true
    }

    private func isValidRequestedFileSystemPermissions(
        _ object: [String: CodexAppServerJSONValue]
    ) -> Bool {
        guard hasOnlyKeys(object, ["entries", "globScanMaxDepth", "read", "write"]) else {
            return false
        }
        for key in ["read", "write"] {
            guard let value = object[key], !isNull(value) else { continue }
            guard let paths = value.arrayValue,
                  paths.allSatisfy({ strictNonEmptyString($0) != nil })
            else {
                return false
            }
        }
        if let depth = object["globScanMaxDepth"], !isNull(depth) {
            guard case .int(let value) = depth, value > 0 else {
                return false
            }
        }
        if let entries = object["entries"], !isNull(entries) {
            guard let values = entries.arrayValue,
                  values.allSatisfy(isValidRequestedFileSystemEntry)
            else {
                return false
            }
        }
        return true
    }

    private func isValidRequestedFileSystemEntry(_ value: CodexAppServerJSONValue) -> Bool {
        guard let object = value.objectValue,
              hasOnlyKeys(object, ["access", "path"]),
              let access = object["access"].flatMap(strictNonEmptyString),
              ["read", "write", "deny"].contains(access),
              let path = object["path"]?.objectValue,
              let type = path["type"].flatMap(strictNonEmptyString)
        else {
            return false
        }
        switch type {
        case "path":
            return hasOnlyKeys(path, ["type", "path"])
                && path["path"].flatMap(strictNonEmptyString) != nil
        case "glob_pattern":
            return hasOnlyKeys(path, ["type", "pattern"])
                && path["pattern"].flatMap(strictNonEmptyString) != nil
        case "special":
            guard hasOnlyKeys(path, ["type", "value"]),
                  let special = path["value"]?.objectValue,
                  let kind = special["kind"].flatMap(strictNonEmptyString)
            else {
                return false
            }
            switch kind {
            case "root", "minimal", "tmpdir", "slash_tmp":
                return hasOnlyKeys(special, ["kind"])
            case "project_roots":
                return hasOnlyKeys(special, ["kind", "subpath"])
                    && validOptionalString(special["subpath"])
            case "unknown":
                return hasOnlyKeys(special, ["kind", "path", "subpath"])
                    && special["path"].flatMap(strictNonEmptyString) != nil
                    && validOptionalString(special["subpath"])
            default:
                return false
            }
        default:
            return false
        }
    }

    private func hasOnlyKeys(
        _ object: [String: CodexAppServerJSONValue],
        _ allowed: Set<String>
    ) -> Bool {
        Set(object.keys).isSubset(of: allowed)
    }

    private func strictNonEmptyString(_ value: CodexAppServerJSONValue) -> String? {
        guard case .string(let raw) = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || raw.contains("\0") ? nil : trimmed
    }

    private func validOptionalString(_ value: CodexAppServerJSONValue?) -> Bool {
        guard let value else { return true }
        return isNull(value) || strictNonEmptyString(value) != nil
    }

    private func isNull(_ value: CodexAppServerJSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    func mcpToolApprovalResponse(
        params: [String: CodexAppServerJSONValue],
        decision: String
    ) -> CodexAppServerJSONValue {
        let persistenceModes = CodexMCPToolApprovalProtocol.persistenceModes(params)
        let normalized = normalizeApprovalDecision(decision)
        let persist: String?
        switch normalized {
        case "accept":
            persist = nil
        case "acceptForSession" where persistenceModes.contains("session"):
            persist = "session"
        case "acceptAlways" where persistenceModes.contains("always"):
            persist = "always"
        case "cancel":
            return .object(["action": .string("cancel"), "content": .null, "_meta": .null])
        default:
            // 客户端不能扩大上游声明的权限范围；未知或未提供的持久化选项一律拒绝。
            return .object(["action": .string("decline"), "content": .null, "_meta": .null])
        }
        return .object([
            "action": .string("accept"),
            "content": .null,
            "_meta": persist.map { .object(["persist": .string($0)]) } ?? .null
        ])
    }

    func userInputResponse(
        for request: CodexAppServerServerRequest,
        answers: [String: [String]]
    ) -> CodexAppServerJSONValue {
        if request.method == "mcpServer/elicitation/request" {
            return mcpElicitationResponse(request: request, answers: answers)
        }
        return .object([
            "answers": .object(answers.mapValues { values in
                .object([
                    "answers": .array(values.map { .string($0) })
                ])
            })
        ])
    }

    func mcpElicitationResponse(
        request: CodexAppServerServerRequest,
        answers: [String: [String]]
    ) -> CodexAppServerJSONValue {
        guard !answers.isEmpty else {
            // 没有可验证的内容时 fail closed，避免对未知/unsupported schema 误回 accept。
            return .object([
                "action": .string("decline"),
                "content": .null,
                "_meta": .null
            ])
        }

        let schemaProperties = request.params?.objectValue?["requestedSchema"]?
            .objectValue?["properties"]?.objectValue ?? [:]
        let content = answers.reduce(into: [String: CodexAppServerJSONValue]()) { result, entry in
            guard !entry.value.isEmpty else {
                return
            }
            let propertySchema = schemaProperties[entry.key]?.objectValue ?? [:]
            result[entry.key] = mcpElicitationValue(from: entry.value, schema: propertySchema)
        }
        guard !content.isEmpty else {
            return .object(["action": .string("decline"), "content": .null, "_meta": .null])
        }
        return .object([
            "action": .string("accept"),
            "content": .object(content),
            "_meta": .null
        ])
    }

    func mcpElicitationValue(
        from answers: [String],
        schema: [String: CodexAppServerJSONValue]
    ) -> CodexAppServerJSONValue {
        let first = answers[0]
        switch schema["type"]?.stringValue {
        case "array":
            return .array(answers.map { .string($0) })
        case "boolean":
            let normalized = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Upstream payload values are protocol data, not UI copy. Keep both known
            // Chinese spellings accepted regardless of the device display language.
            return .bool(["true", "1", "yes", "是", "允许"].contains(normalized))
        case "integer":
            return Int64(first).map(CodexAppServerJSONValue.int) ?? .string(first)
        case "number":
            return Double(first).map(CodexAppServerJSONValue.double) ?? .string(first)
        default:
            return .string(first)
        }
    }

    func normalizeApprovalDecision(_ decision: String) -> String {
        switch decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "accept", "approve", "approved", "yes":
            return "accept"
        case "acceptforsession", "accept_for_session":
            return "acceptForSession"
        case "acceptalways", "accept_always", "acceptandremember", "accept_and_remember":
            return "acceptAlways"
        case "acceptwithpermissionupdate", "accept_with_permission_update":
            return "acceptWithPermissionUpdate"
        case "cancel":
            return "cancel"
        default:
            return "decline"
        }
    }
}
