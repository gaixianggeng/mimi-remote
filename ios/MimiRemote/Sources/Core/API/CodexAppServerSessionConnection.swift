import Foundation

extension CodexAppServerSessionRuntime {
    /// `handshakeTimeout` 只用于这次新建连接的 initialize，不改变之后请求的超时（#801）。
    func ensureConnection(handshakeTimeout: TimeInterval? = nil) async throws -> CodexAppServerConnection {
        if let connection {
            if await connection.isReadyForRequests() { return connection }
            await retireConnection(connection)
        }
        if let connectionAttempt { return try await awaitConnectionAttempt(connectionAttempt) }

        let config = try await connectionConfig()
        // 配置读取会让 actor 重入；恢复后必须重新检查，避免并发冷启动创建第二条连接。
        if let connection {
            if await connection.isReadyForRequests() { return connection }
            await retireConnection(connection)
        }
        if let connectionAttempt { return try await awaitConnectionAttempt(connectionAttempt) }
        guard runtimeGatewayAvailable(in: config) else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }

        let gatewayURL = try gatewayURL(from: config)
        let next = CodexAppServerConnection(transport: transportFactory(), requestTimeout: requestTimeout)
        let task = Task { [next, gatewayURL, token] in
            let notifications = await next.notifications()
            let serverRequests = await next.serverRequests()
            try await next.connect(url: gatewayURL, token: token, initializeTimeout: handshakeTimeout)
            return CodexAppServerPreparedConnection(
                connection: next,
                notifications: notifications,
                serverRequests: serverRequests
            )
        }
        let attempt = CodexAppServerConnectionAttempt(
            id: UUID(),
            connection: next,
            task: task,
            waiterIDs: []
        )
        connectionAttempt = attempt
        return try await awaitConnectionAttempt(attempt)
    }

    func awaitConnectionAttempt(
        _ snapshot: CodexAppServerConnectionAttempt
    ) async throws -> CodexAppServerConnection {
        let waiterID = UUID()
        guard var current = connectionAttempt, current.id == snapshot.id else {
            if let connection, await connection.isReadyForRequests() { return connection }
            throw CancellationError()
        }
        current.waiterIDs.insert(waiterID)
        connectionAttempt = current
        return try await installPreparedConnectionIfNeeded(from: current, waiterID: waiterID)
    }

    func installPreparedConnectionIfNeeded(
        from attempt: CodexAppServerConnectionAttempt,
        waiterID: UUID
    ) async throws -> CodexAppServerConnection {
        let prepared: CodexAppServerPreparedConnection
        do {
            prepared = try await waitForPreparedConnection(attempt, waiterID: waiterID)
            // 仍持有 attempt 租约时完成取消检查；抛出后由 catch 释放当前 waiter。
            // 清空 connectionAttempt 后不再抛取消，避免遗留无人安装的 candidate。
            try Task.checkCancellation()
        } catch {
            await releaseConnectionAttemptWaiter(attemptID: attempt.id, waiterID: waiterID)
            throw error
        }

        // 第一个成功 waiter 安装连接；其他 waiter 复用已安装连接，不能覆盖新代次。
        guard connectionAttempt?.id == attempt.id else {
            if let connection, await connection.isReadyForRequests() { return connection }
            await prepared.connection.disconnect()
            throw CancellationError()
        }
        connectionAttempt = nil
        if let connection, await connection.isReadyForRequests() {
            if connection !== prepared.connection { await prepared.connection.disconnect() }
            return connection
        }
        installConnection(prepared)
        return prepared.connection
    }

    func waitForPreparedConnection(
        _ attempt: CodexAppServerConnectionAttempt,
        waiterID: UUID
    ) async throws -> CodexAppServerPreparedConnection {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connectionAttemptWaiters[waiterID] = continuation
                Task {
                    let result = await attempt.task.result
                    self.completeConnectionAttemptWaiter(waiterID, result: result)
                }
            }
        } onCancel: {
            Task {
                await self.cancelConnectionAttemptWaiter(attemptID: attempt.id, waiterID: waiterID)
            }
        }
    }

    func completeConnectionAttemptWaiter(
        _ waiterID: UUID,
        result: Result<CodexAppServerPreparedConnection, Error>
    ) {
        guard let continuation = connectionAttemptWaiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(with: result)
    }

    func cancelConnectionAttemptWaiter(attemptID: UUID, waiterID: UUID) async {
        connectionAttemptWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
        await releaseConnectionAttemptWaiter(attemptID: attemptID, waiterID: waiterID)
    }

    func releaseConnectionAttemptWaiter(attemptID: UUID, waiterID: UUID) async {
        guard var attempt = connectionAttempt, attempt.id == attemptID else { return }
        attempt.waiterIDs.remove(waiterID)
        guard attempt.waiterIDs.isEmpty else {
            connectionAttempt = attempt
            return
        }
        connectionAttempt = nil
        connectionAttemptWaiters.removeAll(keepingCapacity: true)
        attempt.task.cancel()
        await attempt.connection.disconnect()
    }

    func cancelConnectionAttempt(id: UUID? = nil) async {
        guard let attempt = connectionAttempt, id == nil || attempt.id == id else { return }
        connectionAttempt = nil
        let waiters = connectionAttemptWaiters
        connectionAttemptWaiters.removeAll(keepingCapacity: true)
        for continuation in waiters.values { continuation.resume(throwing: CancellationError()) }
        attempt.task.cancel()
        await attempt.connection.disconnect()
    }

    func connectionConfig() async throws -> CodexAppServerConfigResponse {
        let cached = try await ensureConfig()
        if runtimeGatewayAvailable(in: cached) { return cached }
        let fresh = try await ensureConfig(forceRefresh: true)
        if runtimeGatewayAvailable(in: fresh) { return fresh }
        throw CodexAppServerSessionRuntimeError.gatewayUnavailable
    }

    func installConnection(_ prepared: CodexAppServerPreparedConnection) {
        notificationPumpTask?.cancel()
        serverRequestPumpTask?.cancel()
        cancelAllTurnInterruptRecoveryTasks()
        threadResumeTasksBySessionID.values.forEach { $0.task.cancel() }
        threadResumeTasksBySessionID.removeAll(keepingCapacity: true)
        threadsResumedOnConnection.removeAll(keepingCapacity: true)
        connection = prepared.connection
        notificationPumpTask = Task { [weak self, notifications = prepared.notifications, installedConnection = prepared.connection] in
            for await notification in notifications {
                await self?.handle(notification, from: installedConnection)
            }
            guard !Task.isCancelled else { return }
            await self?.handleNotificationStreamEnded(for: installedConnection)
        }
        serverRequestPumpTask = Task { [weak self, serverRequests = prepared.serverRequests] in
            for await request in serverRequests { await self?.handle(request) }
        }
    }

    func handle(_ notification: CodexAppServerNotification, from source: CodexAppServerConnection) {
        // 取消旧 pump 后仍可能有已排队的尾包；建议不能跨连接代次进入当前草稿。
        if notification.method == "_mimi/turn/promptSuggestion", connection !== source { return }
        handle(notification)
    }

    func handleNotificationStreamEnded(for endedConnection: CodexAppServerConnection) async {
        guard let current = connection, current === endedConnection else { return }

        // 底层 receive 失败会结束 notification stream。这里必须继续结束上层 AgentEvent stream，
        // 否则 SessionWebSocketClient 的 for-await 永远不退出，UI 会一直误认为连接仍是 connected。
        notificationPumpTask = nil
        serverRequestPumpTask?.cancel()
        serverRequestPumpTask = nil
        cancelThreadResumeTasks(for: endedConnection)
        connection = nil
        invalidateConfigSnapshot()
        threadsResumedOnConnection.removeAll(keepingCapacity: true)
        threadUnsubscribeRetryTasksBySessionID.values.forEach { $0.task.cancel() }
        threadUnsubscribeRetryTasksBySessionID.removeAll(keepingCapacity: true)
        let affected = clearAllPendingServerRequests()
        for sessionID in affected.approvalSessionIDs { emitApprovalResolved(sessionID: sessionID) }
        for sessionID in affected.userInputSessionIDs {
            emitUserInputResolved(sessionID: sessionID, skipped: false)
        }
        finishAttachedEventStreams()
        await endedConnection.disconnect()
    }

    func finishAttachedEventStreams() {
        cancelMimiTaskRequests()
        let mailboxes = eventMailboxesBySessionID.values.flatMap { $0.values }
        eventMailboxesBySessionID.removeAll(keepingCapacity: true)
        for mailbox in mailboxes { mailbox.finishFromProducer() }
    }

    func finishAttachedEventStreams(sessionID: SessionID) {
        let mailboxes = eventMailboxesBySessionID.removeValue(forKey: sessionID)?.values ?? [:].values
        for mailbox in mailboxes { mailbox.finishFromProducer() }
    }
}

// MARK: - 会话授权恢复（#718）

extension CodexAppServerSessionRuntime {
    static let threadReauthorizationPageLimit = 50
    static let threadReauthorizationMaxPages = 5

    /// 网关只放行当前连接上已经授权过的会话：Claude 通道每条新连接的授权表都是空的，agentd 重启后
    /// Codex broker 也会丢失授权。读会话被以「未由当前 gateway 连接授权」拒绝时返回其 threadId。
    nonisolated static func unauthorizedThreadID(
        in request: CodexAppServerRequestSpec,
        error: Error
    ) -> SessionID? {
        guard case CodexAppServerConnectionError.appServer(let appError) = error,
              appError.code == -32080,
              appError.message.contains("未由当前 gateway 连接授权"),
              let threadID = request.params?.objectValue?["threadId"]?.stringValue,
              !threadID.isEmpty
        else {
            return nil
        }
        return threadID
    }

    func setThreadRuntimeOwnerLookup(_ lookup: (@Sendable (SessionID) -> String?)?) {
        threadRuntimeOwnerLookup = lookup
    }

    /// 用列表让网关在当前连接上重新授权这个会话。同一连接、同一列表范围（目录或全局）同时只翻一次：
    /// 网关会把参数相同的并发列表当成重复请求拒绝；后到的会话先等前一次翻完，已被翻到（即已授权）就直接成功。
    func reauthorizeThread(_ threadID: SessionID, on connection: CodexAppServerConnection) async -> Bool {
        if let owner = threadRuntimeOwnerLookup?(threadID),
           Self.normalizedRuntimeProvider(owner) != runtimeProvider {
            // 别的 Runtime 的会话不会出现在本通道列表里，翻满也找不到，只会拖慢回前台（#784）。
            return false
        }
        let scopedCWD = contextsBySessionID[threadID]?.cwd
        let key = "\(ObjectIdentifier(connection).hashValue)|\(scopedCWD ?? "")"
        while let running = threadReauthorizationTasks[key] {
            if await running.value.contains(threadID) {
                return true
            }
            if threadReauthorizationTasks[key] == running {
                threadReauthorizationTasks.removeValue(forKey: key)
            }
        }
        let task = Task { await self.listUntilThreadAuthorized(threadID, cwd: scopedCWD) }
        threadReauthorizationTasks[key] = task
        let seen = await task.value
        if threadReauthorizationTasks[key] == task {
            threadReauthorizationTasks.removeValue(forKey: key)
        }
        return seen.contains(threadID)
    }

    /// 翻列表直到看到该会话，返回途中见到（即已被网关授权）的全部会话。目录在授权项目里时走与普通列表
    /// 相同的索引兜底路径（State DB 缺漏扫描修复、排序与索引兼容）；Codex 索引整段缺失时再用普通扫描
    /// 补翻一轮。目录不在授权项目里（例如 managed worktree）时改用受控全局发现。
    private func listUntilThreadAuthorized(_ threadID: SessionID, cwd: String?) async -> Set<SessionID> {
        let projects = (try? await projects()) ?? []
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let limit = Self.threadReauthorizationPageLimit
        var seen: Set<SessionID> = []
        if let cwd, (try? builder.threadList(cwd: cwd, limit: limit)) != nil {
            let project = projects.first(where: { $0.path == cwd })
                ?? AgentProject(id: contextsBySessionID[threadID]?.session.projectID ?? cwd, name: cwd, path: cwd)
            let indexed: (String?) async throws -> SessionsPage = { cursor in
                try await self.threadListPageWithIndexedFallback(
                    cwd: cwd, cursor: cursor, limit: limit, builder: builder,
                    projects: projects, fallbackProject: project, consistency: .authoritative
                )
            }
            let scanned: (String?) async throws -> SessionsPage = { cursor in
                try await self.ordinaryThreadListPage(
                    cwd: cwd, cursor: cursor, limit: limit, builder: builder,
                    projects: projects, fallbackProject: project
                )
            }
            for nextPage in runtimeProvider == "codex" ? [indexed, scanned] : [indexed] {
                var cursor: String?
                for _ in 0..<Self.threadReauthorizationMaxPages {
                    guard let page = try? await nextPage(cursor) else { break }
                    seen.formUnion(page.sessions.map(\.id))
                    if seen.contains(threadID) { return seen }
                    guard let next = page.nextCursor, !next.isEmpty else { break }
                    cursor = next
                }
            }
            return seen
        }
        var cursor: String?
        for _ in 0..<Self.threadReauthorizationMaxPages {
            let request = builder.controlledGlobalThreadList(limit: limit, cursor: cursor)
            guard let object = (try? await sendControlledGlobalThreadList(request, cursor: cursor))??.objectValue else {
                break
            }
            seen.formUnion((object["data"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue })
            if seen.contains(threadID) { break }
            guard let next = object["nextCursor"]?.stringValue, !next.isEmpty else { break }
            cursor = next
        }
        return seen
    }
}

/// 受控全局发现 cursor 的签发连接（#792）。弱引用：连接退役释放后，cursor 自然判为失效。
struct CodexAppServerGlobalListCursorIssuer {
    weak var connection: CodexAppServerConnection?
}

/// 受控全局发现的 cursor 已不属于当前网关连接（#792）。调用方应从首页重走，不当作普通失败。
struct ControlledGlobalListCursorExpiredError: Error {}

extension CodexAppServerSessionRuntime {
    static let globalListCursorIssuerLimit = 64

    /// 无 cwd 的 thread/list 续页只能发给签发 cursor 的那条网关连接：gateway 按连接保存 cursor 表，
    /// 换连接必然被拒（#792）。签发连接已退役时不为续页新建连接，换连接重试也不重放旧 cursor。
    func sendControlledGlobalThreadList(
        _ request: CodexAppServerRequestSpec,
        cursor: String?
    ) async throws -> CodexAppServerJSONValue? {
        let issuer = cursor.flatMap { globalListCursorIssuers[$0] }
        if let issuer, issuer.connection.map({ $0 !== connection }) ?? true {
            throw ControlledGlobalListCursorExpiredError()
        }
        var servingConnection: CodexAppServerConnection?
        do {
            let result = try await sendRecoveringFromStaleInitialization(
                request,
                timeout: longRunningRequestTimeout
            ) { candidate in
                if let issuer, issuer.connection !== candidate {
                    throw ControlledGlobalListCursorExpiredError()
                }
                servingConnection = candidate
            }
            rememberGlobalListCursor(result?.objectValue?["nextCursor"]?.stringValue, issuedBy: servingConnection)
            return result
        } catch let error where Self.isGatewayGlobalListCursorRejection(error) {
            // gateway 的 cursor 表整体换代时同样拒绝；对调用方是同一种「从首页重来」。
            throw ControlledGlobalListCursorExpiredError()
        }
    }

    func rememberGlobalListCursor(_ cursor: String?, issuedBy connection: CodexAppServerConnection?) {
        guard let cursor, !cursor.isEmpty, let connection else { return }
        if globalListCursorIssuers.count >= Self.globalListCursorIssuerLimit {
            // 与 gateway 一样整体换代；查不到签发者的 cursor 照常发出，由 gateway 裁决。
            globalListCursorIssuers.removeAll(keepingCapacity: true)
        }
        globalListCursorIssuers[cursor] = CodexAppServerGlobalListCursorIssuer(connection: connection)
    }

    nonisolated static func isGatewayGlobalListCursorRejection(_ error: Error) -> Bool {
        guard case CodexAppServerConnectionError.appServer(let appError) = error else { return false }
        return appError.code == -32080 && appError.message.contains("thread/list.cursor")
    }
}

// MARK: - Claude 常驻会话的重连游标（#873）

extension CodexAppServerSessionRuntime {
    /// 投影落地后可以提交为 `last_seen` 的通知。重连时 bridge 只补发游标之后的帧。
    ///
    /// 回合与线程终态之外，Claude 的 `item/completed` 也算：完成的条目已写进会话历史，
    /// 冷启动读历史即可拿回。以前只在回合结束时提交，长回合进行中每次重开都会把整轮重放
    /// 一遍，其中已答复的补充信息请求会再弹出一次。流式增量不算，否则冷启动只能收到一条
    /// 消息的后半段。
    func isReplayBoundaryNotification(_ notification: CodexAppServerNotification) -> Bool {
        switch notification.method {
        case "turn/completed", "thread/closed":
            return true
        case "item/completed":
            return runtimeProvider == "claude" && notification.replaySequence != nil
        default:
            return false
        }
    }
}
