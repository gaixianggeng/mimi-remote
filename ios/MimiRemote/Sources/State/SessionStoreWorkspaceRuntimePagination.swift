import Foundation

extension SessionStore {
    func availableSessionRuntimeProviders(
        client: any SessionStoreAPIClient
    ) async -> [String] {
        var runtimes: [String] = []
        for runtime in ["codex", "claude"] {
            if (try? await client.runtimeChannelAvailable(runtimeProvider: runtime)) == true {
                runtimes.append(runtime)
            }
        }
        return runtimes
    }

    func primarySessionRuntimeProvider(
        client: any SessionStoreAPIClient
    ) async throws -> String {
        guard let runtime = await availableSessionRuntimeProviders(client: client).first else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        return runtime
    }

    func workspaceDirectoryScopeKey(
        for workspace: AgentWorkspace,
        runtimeProvider: String
    ) -> WorkspaceDirectorySessionScopeKey {
        WorkspaceDirectorySessionScopeKey(
            hostScope: appStore.activeHostScope,
            workspaceID: workspace.id,
            workspacePath: standardizedSessionListPath(workspace.path),
            runtimeProvider: Self.normalizedRuntimeProvider(runtimeProvider)
        )
    }

    func recordWorkspaceDirectorySessionPage(
        _ items: [AgentSession],
        in workspace: AgentWorkspace,
        runtimeProvider: String,
        replacing: Bool
    ) {
        guard isCurrentWorkspaceIdentity(workspace) else { return }
        let normalizedRuntime = Self.normalizedRuntimeProvider(runtimeProvider)
        let key = workspaceDirectoryScopeKey(for: workspace, runtimeProvider: normalizedRuntime)
        // agentd 已按 canonical scope 校验本次 cwd 查询；返回项仍可能保留 symlink 形式的上游 cwd。
        // 因此归属只认“由该查询返回的 ID”，不能再次用 item.dir 的原始拼写做路径比较。
        let pageIDs = Set(items.compactMap { item in
            Self.normalizedRuntimeProvider(item.runtimeProvider ?? item.source) == normalizedRuntime
                ? item.id
                : nil
        })
        var next = workspaceDirectorySessionIDsByKey
        // 整页覆盖只能替换服务端查到的部分；本设备刚创建的会话可能晚于这页请求发出，
        // 不并回去就会在下一轮全局发现后被过滤掉。
        let created = workspaceCreatedSessionIDsByKey[key] ?? []
        next[key] = replacing ? pageIDs.union(created) : next[key, default: []].union(pageIDs)
        if next != workspaceDirectorySessionIDsByKey {
            workspaceDirectorySessionIDsByKey = next
        }
    }

    /// 创建成功时用服务端确认的工作区和 runtime 登记归属。除了并入目录登记，还单独
    /// 记住"本设备创建"，让稍后落地的旧首屏页不能把它冲掉。
    func recordWorkspaceCreatedSession(
        _ session: AgentSession,
        in workspace: AgentWorkspace,
        runtimeProvider: String
    ) {
        guard isCurrentWorkspaceIdentity(workspace) else { return }
        let key = workspaceDirectoryScopeKey(for: workspace, runtimeProvider: runtimeProvider)
        workspaceCreatedSessionIDsByKey[key, default: []].insert(session.id)
        recordWorkspaceDirectorySessionPage([session], in: workspace, runtimeProvider: runtimeProvider, replacing: false)
    }

    func workspaceForDirectoryScopedSession(_ item: AgentSession) -> AgentWorkspace? {
        let runtime = Self.normalizedRuntimeProvider(item.runtimeProvider ?? item.source)
        return recentWorkspaces.first { workspace in
            if controlledGlobalSessionIDs.contains(item.id) {
                let key = workspaceDirectoryScopeKey(for: workspace, runtimeProvider: runtime)
                return workspaceDirectorySessionIDsByKey[key]?.contains(item.id) == true
            }
            return item.projectID == workspace.id
        }
    }

    func directoryScopedSessions(
        workspaceID: String,
        runtimeProvider: String
    ) -> [AgentSession] {
        guard let workspace = workspacesByID[workspaceID] else { return [] }
        let runtime = Self.normalizedRuntimeProvider(runtimeProvider)
        let key = workspaceDirectoryScopeKey(for: workspace, runtimeProvider: runtime)
        let confirmedGlobalIDs = workspaceDirectorySessionIDsByKey[key] ?? []
        let scoped = sessions.compactMap { item -> AgentSession? in
            let belongsToWorkspace = controlledGlobalSessionIDs.contains(item.id)
                ? confirmedGlobalIDs.contains(item.id)
                : item.projectID == workspace.id
            guard isListableSession(item),
                  Self.normalizedRuntimeProvider(item.runtimeProvider ?? item.source) == runtime,
                  belongsToWorkspace
            else {
                return nil
            }
            return session(item, in: workspace)
        }
        return Self.sortedSessions(scoped)
    }

    func alignGlobalSessionToKnownDirectoryScope(_ item: AgentSession) -> AgentSession {
        guard controlledGlobalSessionIDs.contains(item.id),
              let workspace = workspaceForDirectoryScopedSession(item) else {
            return item
        }
        return session(item, in: workspace)
    }

    func removeWorkspaceDirectorySessionScopes(workspaceID: String) {
        workspaceCreatedSessionIDsByKey = workspaceCreatedSessionIDsByKey.filter { $0.key.workspaceID != workspaceID }
        let next = workspaceDirectorySessionIDsByKey.filter { $0.key.workspaceID != workspaceID }
        if next != workspaceDirectorySessionIDsByKey {
            workspaceDirectorySessionIDsByKey = next
        }
    }

    func removeWorkspaceDirectorySessionIDs(_ sessionIDs: Set<SessionID>) {
        guard !sessionIDs.isEmpty else { return }
        // 全局发现完整遍历后撤权的会话已经不存在，"本设备创建"的记忆也一起清掉。
        workspaceCreatedSessionIDsByKey = workspaceCreatedSessionIDsByKey.mapValues { $0.subtracting(sessionIDs) }
        let next = workspaceDirectorySessionIDsByKey.mapValues { $0.subtracting(sessionIDs) }
        if next != workspaceDirectorySessionIDsByKey {
            workspaceDirectorySessionIDsByKey = next
        }
    }

    func refreshDirectoryScopedSessionLibrary(
        workspace: AgentWorkspace,
        consistency: SessionListConsistency,
        restartFromFirst: Bool = false,
        client: any SessionStoreAPIClient,
        hostScope: HostScope,
        generation: Int
    ) async {
        for runtimeProvider in RuntimeFeatureSupport.runtimeProviders {
            if runtimeProvider != "codex",
               (try? await client.runtimeChannelAvailable(runtimeProvider: runtimeProvider)) != true { continue }
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return }
            // deepseek 由原生通道承接时走协调器：它管代次、single-flight 与失败保留旧页。
            // 未启用时这段完全不参与，下面照旧走既有 app-server 路径。
            if isNativeHarnessDirectoryEnabled,
               Self.normalizedRuntimeProvider(runtimeProvider) == Self.nativeHarnessRuntimeProvider {
                await refreshNativeHarnessDirectory(
                    workspace: workspace,
                    consistency: consistency,
                    restartFromFirst: restartFromFirst,
                    hostScope: hostScope,
                    generation: generation
                )
                continue
            }
            let result = await sessionLibraryPage(
                workspace: workspace,
                runtimeProvider: runtimeProvider,
                consistency: consistency,
                restartFromFirst: restartFromFirst,
                client: client,
                hostScope: hostScope
            )
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return }
            mergeSessionLibraryPages(
                [result],
                generation: generation,
                consistency: consistency,
                runtimeProvider: runtimeProvider,
                restartsFromFirst: restartFromFirst
            )
        }
    }

    /// 工作区详情按 Runtime 独立分页。Codex 首屏复用 canonical single-flight，
    /// opaque cursor 和 Claude 请求仍独立归属于当前 Runtime。
    func workspaceRuntimeSessionsPage(
        projectID: String,
        runtimeProvider: String,
        cursor: String?,
        limit: Int,
        excludingListableSessionIDs: Set<SessionID> = [],
        restartFromFirst: Bool = false
    ) async throws -> SessionsPage {
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            throw CancellationError()
        }
        let lease = try captureProjectsGitHostLease()
        let normalizedRuntime = Self.normalizedRuntimeProvider(runtimeProvider)
        let requestedLimit = max(1, limit)
        let page: SessionsPage
        var canonicalFirstPageResult: SessionListFirstPageResult?
        if normalizedRuntime == "codex",
           cursor == nil,
           excludingListableSessionIDs.isEmpty {
            // Host 切换后的 refreshAll 与工作区 View 会同时请求 Codex 首屏。直接调用
            // client 会让后发 thread/list 被 app-server 以 -32080 拒绝。
            let result = try await sessionListFirstPage(
                workspace: workspace,
                limit: requestedLimit,
                reuseRecent: false,
                consistency: .authoritative,
                source: .workspaceForeground,
                restartFromFirst: restartFromFirst,
                client: lease.client,
                hostScope: lease.scope,
                runtimeProvider: normalizedRuntime
            )
            canonicalFirstPageResult = result
            page = result.page
        } else {
            page = try await sessionListPageFillingPresentationWindow(
                client: lease.client,
                workspace: workspace,
                runtimeProvider: normalizedRuntime,
                cursor: cursor,
                limit: requestedLimit,
                consistency: .authoritative,
                source: cursor == nil ? .workspaceForeground : .workspaceLoadMore,
                expectedHostScope: lease.scope,
                excludingListableSessionIDs: excludingListableSessionIDs
            )
        }
        try requireCurrentProjectsGitHost(lease)
        if let canonicalFirstPageResult,
           let requestLineage = canonicalFirstPageResult.requestLineage,
           !isCurrentSessionListRequestLineage(
               requestLineage,
               workspace: workspace,
               hostScope: lease.scope,
               runtimeProvider: normalizedRuntime
           ) {
            // 旧首屏即使稍后在 apply 阶段会被拒绝，也不能先覆盖目录成员集合。
            throw CancellationError()
        }

        let prepared = sessions(page.sessions, in: workspace).map(sessionPreparedForStorage)
        recordWorkspaceDirectorySessionPage(
            page.sessions,
            in: workspace,
            runtimeProvider: normalizedRuntime,
            replacing: cursor == nil
        )
        if let canonicalFirstPageResult {
            // 复用 canonical 请求也必须提交同一条 authoritative cursor 的推进结果；
            // 否则 child-dense 首屏会反复从旧 continuation 重拉，View 与 Store 看到两套进度。
            _ = applyWorkspaceSessionFirstPage(
                workspace: workspace,
                page: page,
                runtimeProvider: normalizedRuntime,
                consistency: .authoritative,
                requestedCursor: canonicalFirstPageResult.requestedCursor,
                // Runtime 页面只拿到 Codex rows，不能整页替换并误删同工作区已缓存的
                // Claude 会话或旧分页；沿用该入口原先的 merge-only 展示语义。
                preserveAllLoaded: true,
                restartsFromFirst: restartFromFirst,
                requestLineage: canonicalFirstPageResult.requestLineage
            )
        } else {
            mergeSessionPage(prepared)
            clearWorkspaceUnavailable(workspace.id)
        }

        let listable = prepared.filter { session in
            isListableSession(session)
                && !excludingListableSessionIDs.contains(session.id)
                && Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == normalizedRuntime
        }
        return SessionsPage(
            sessions: SessionIndexStore.sortedSessions(listable),
            nextCursor: page.nextCursor,
            hasMore: page.hasMore
        )
    }
}
