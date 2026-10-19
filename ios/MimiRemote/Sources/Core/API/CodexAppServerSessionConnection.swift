import Foundation

extension CodexAppServerSessionRuntime {
    func ensureConnection() async throws -> CodexAppServerConnection {
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
            for await notification in notifications { await self?.handle(notification) }
            guard !Task.isCancelled else { return }
            await self?.handleNotificationStreamEnded(for: installedConnection)
        }
        serverRequestPumpTask = Task { [weak self, serverRequests = prepared.serverRequests] in
            for await request in serverRequests { await self?.handle(request) }
        }
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
            guard let object = (try? await sendRecoveringFromStaleInitialization(request, timeout: longRunningRequestTimeout))??.objectValue else {
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
