import Foundation

/// Claude 会话 `/` 菜单的命令目录（#765）。目录只在进入会话或打开菜单时按需读取，
/// 输入筛选只读内存里的快照；每个键的结果只写回自己的键，迟到的响应不会出现在别的会话里。
extension SessionStore {
    static let claudeSlashCommandCatalogTTL: TimeInterval = 5 * 60
    static let claudeSlashCommandCatalogRetryDelay: TimeInterval = 30

    func claudeSlashCommandCatalogKey(
        cwd: String?,
        runtimeProvider: String?,
        sandboxMode: CodexAppServerSandboxMode
    ) -> ClaudeSlashCommandCatalogKey? {
        guard Self.normalizedRuntimeProvider(runtimeProvider) == "claude",
              let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty
        else {
            return nil
        }
        return ClaudeSlashCommandCatalogKey(
            hostScope: appStore.activeHostScope,
            cwd: cwd,
            fullAccess: sandboxMode == .dangerFullAccess
        )
    }

    func claudeSlashCommands(for key: ClaudeSlashCommandCatalogKey?) -> [ClaudeSlashCommand] {
        guard let key, key.hostScope == appStore.activeHostScope else {
            return []
        }
        return claudeSlashCommandCatalogs[key]?.commands ?? []
    }

    /// 已加载且未过期、正在加载或刚失败时不重复请求。刷新期间保留旧目录，菜单不会闪空。
    func refreshClaudeSlashCommands(for key: ClaudeSlashCommandCatalogKey, forceReload: Bool = false) async {
        guard key.hostScope == appStore.activeHostScope else { return }
        let now = Date()
        var state = claudeSlashCommandCatalogs[key] ?? ClaudeSlashCommandCatalogState()
        if state.isLoading { return }
        if !forceReload {
            if let fetchedAt = state.fetchedAt, now.timeIntervalSince(fetchedAt) < Self.claudeSlashCommandCatalogTTL { return }
            if let failedAt = state.failedAt, now.timeIntervalSince(failedAt) < Self.claudeSlashCommandCatalogRetryDelay { return }
        }
        state.isLoading = true
        // 换过主机的目录不会再用到，顺带丢掉。
        var catalogs = claudeSlashCommandCatalogs.filter { $0.key.hostScope == key.hostScope }
        catalogs[key] = state
        claudeSlashCommandCatalogs = catalogs

        let sandboxMode: CodexAppServerSandboxMode = key.fullAccess ? .dangerFullAccess : .workspaceWrite
        do {
            let commands = try await clientFactory().claudeSlashCommands(
                cwd: key.cwd,
                sandboxMode: sandboxMode,
                forceReload: forceReload
            )
            state.commands = commands
            state.fetchedAt = Date()
            state.failedAt = nil
        } catch is CancellationError {
            // 视图离开或换了键：不算失败，下次打开菜单再读。
        } catch ClaudeSlashCommandCatalogError.unsupported {
            // 旧主机没有这个方法：按空目录缓存，不反复探测。
            state.commands = []
            state.fetchedAt = Date()
        } catch {
            // 读取失败不影响 App 自己的动作；保留上次的目录，稍后再试。
            state.failedAt = Date()
        }
        state.isLoading = false
        guard key.hostScope == appStore.activeHostScope else {
            claudeSlashCommandCatalogs[key] = nil
            return
        }
        claudeSlashCommandCatalogs[key] = state
    }
}
