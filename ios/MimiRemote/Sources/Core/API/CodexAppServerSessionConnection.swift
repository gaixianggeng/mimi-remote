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
        let mailboxes = eventMailboxesBySessionID.values.flatMap { $0.values }
        eventMailboxesBySessionID.removeAll(keepingCapacity: true)
        for mailbox in mailboxes { mailbox.finishFromProducer() }
    }

    func finishAttachedEventStreams(sessionID: SessionID) {
        let mailboxes = eventMailboxesBySessionID.removeValue(forKey: sessionID)?.values ?? [:].values
        for mailbox in mailboxes { mailbox.finishFromProducer() }
    }
}
