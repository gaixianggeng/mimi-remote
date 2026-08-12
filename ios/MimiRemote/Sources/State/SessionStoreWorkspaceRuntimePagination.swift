import Foundation

extension SessionStore {
    /// 工作区详情按 Runtime 独立分页。Codex 首屏复用 canonical single-flight，
    /// opaque cursor 和 Claude 请求仍独立归属于当前 Runtime。
    func workspaceRuntimeSessionsPage(
        projectID: String,
        runtimeProvider: String,
        cursor: String?,
        limit: Int,
        excludingListableSessionIDs: Set<SessionID> = []
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
                client: lease.client,
                hostScope: lease.scope
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

        let prepared = sessions(page.sessions, in: workspace).map(sessionPreparedForStorage)
        if let canonicalFirstPageResult {
            // 复用 canonical 请求也必须提交同一条 authoritative cursor 的推进结果；
            // 否则 child-dense 首屏会反复从旧 continuation 重拉，View 与 Store 看到两套进度。
            _ = applyWorkspaceSessionFirstPage(
                workspace: workspace,
                page: page,
                consistency: .authoritative,
                requestedCursor: canonicalFirstPageResult.requestedCursor,
                // Runtime 页面只拿到 Codex rows，不能整页替换并误删同工作区已缓存的
                // Claude 会话或旧分页；沿用该入口原先的 merge-only 展示语义。
                preserveAllLoaded: true
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
