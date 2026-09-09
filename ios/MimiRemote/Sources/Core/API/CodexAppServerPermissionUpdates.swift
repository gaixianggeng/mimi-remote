import Foundation

extension CodexAppServerSessionRuntime {
    func updateThreadPermissions(
        threadID: String,
        options: CodexAppServerTurnOptions
    ) async throws {
        guard runtimeProvider == "codex", !options.preservesThreadPermissionSettings else { return }
        let previous = threadPermissionUpdateTasks[threadID]?.task
        let token = UUID()
        let task = Task { [self] in
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            guard let context = contextsBySessionID[threadID] else {
                throw CodexAppServerSessionRuntimeError.sessionNotFound(threadID)
            }
            let config = try await ensureConfig()
            let builder = CodexAppServerRequestBuilder(
                allowlistedProjects: projectsIncludingSessionContext(config.projects, context: context)
            )
            let connection = try await ensureConnection()
            try await ensureThreadResumedOnConnection(
                sessionID: threadID, cwd: context.cwd, builder: builder, connection: connection
            )
            try Task.checkCancellation()
            // 与 Desktop 一致：切换只等 RPC ACK，权威显示仍消费 settings/updated。
            // 下一回合的 turn/start 会再次携带权限，不依赖通知是否重复发送。
            _ = try await connection.send(
                try builder.threadPermissionsUpdate(threadID: threadID, cwd: context.cwd, options: options),
                timeout: longRunningRequestTimeout
            )
        }
        threadPermissionUpdateTasks[threadID] = (token, task)
        defer {
            if threadPermissionUpdateTasks[threadID]?.token == token {
                threadPermissionUpdateTasks.removeValue(forKey: threadID)
            }
        }
        try await task.value
    }

    func waitForPendingThreadPermissionUpdate(sessionID: SessionID) async throws {
        // 快速连续选择按会话串行。等待期间又有新选择时，一并等待最新请求。
        while let pending = threadPermissionUpdateTasks[sessionID] {
            try await pending.task.value
            if threadPermissionUpdateTasks[sessionID]?.token == pending.token { return }
        }
    }
}
