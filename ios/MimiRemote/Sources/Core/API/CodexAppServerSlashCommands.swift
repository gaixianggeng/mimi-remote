import Foundation

extension CodexAppServerSessionRuntime {
    /// Claude 会话 `/` 菜单的命令目录（#765）。只有 Claude 通道声明了 slashCommand/list 才请求；
    /// 旧主机抛出 unsupported，菜单只显示 App 自己的动作。
    func slashCommands(
        cwd: String,
        sandboxMode: CodexAppServerSandboxMode,
        forceReload: Bool
    ) async throws -> [ClaudeSlashCommand] {
        guard runtimeSupportsMethod("slashCommand/list", in: try await ensureConfig()) else {
            throw ClaudeSlashCommandCatalogError.unsupported
        }
        // 会话可能在 worktree 或浏览目录里：与续聊相同，把会话自己的 cwd 作为工作区交给请求构造，
        // 是否授权仍由 agentd 网关按 projects allowlist / browse_roots 判定。
        let projects = projectsIncludingWorkspace(
            try await projects(),
            workspace: AgentWorkspace(id: cwd, name: URL(fileURLWithPath: cwd).lastPathComponent, path: cwd)
        )
        let result = try await sendRecoveringFromStaleInitialization(
            CodexAppServerRequestBuilder(allowlistedProjects: projects)
                .slashCommandList(cwd: cwd, sandboxMode: sandboxMode, forceReload: forceReload),
            // 没有常驻进程时适配器要冷启动一次 Claude Code 才能读到目录。
            timeout: longRunningRequestTimeout
        )
        return ClaudeSlashCommand.parseListResult(result)
    }
}
