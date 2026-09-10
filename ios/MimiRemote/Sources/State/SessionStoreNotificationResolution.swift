import Foundation

/// 通知目标会话的网络解析结果。
/// `missing` 表示直读与列表兜底都没有找到；`profileSwitched` 表示等待网络期间当前
/// Profile 已不再是通知来源，调用方必须提示切换而不是静默放弃。
enum NotificationSessionRefreshResult: Equatable {
    case found(AgentSession)
    case missing
    case profileSwitched
}

// 通知路由（锁屏审批 / 回复提醒 / 本地提醒）到本地会话的解析。
//
// 线程 ID 是唯一身份；项目归属只是标签。agentd 按线程 cwd 推导 project_id（根项目 id 或
// scope id），iOS 却用 /api/workspaces/resolve 铸出的 ws_ 工作区 id 标注同一线程，两边对
// 同一线程的归属天然可能不同。这里一律容忍并留下诊断，不再据此静默丢弃通知。
extension SessionStore {
    // MARK: - 选择意图

    /// 通知意图是否已被用户可见的导航取代。
    ///
    /// `selectionGeneration` 会被通知流程自身的项目/工作区同步、身份重映射等自动推进，
    /// 这些都不代表用户去了别处。只有预留意图之后真正提交过的选择——用户打开、启动恢复、
    /// 返回列表、把当前会话替换成别的会话、另一条通知打开了别的会话——才算取代。
    /// 返回 false 时调用方应重新预留意图后继续，而不是放弃。
    func notificationIntentSuperseded(
        since intent: SessionSelectionLease,
        target targetSessionID: SessionID? = nil
    ) -> Bool {
        if isSelectionLeaseCurrent(intent) {
            return false
        }
        guard let commit = lastSelectionCommit, commit.sequence > intent.generation else {
            return false
        }
        switch commit.reason {
        case .userOpen, .restoration, .invalidation:
            return true
        case .notification:
            // 同一目标的重复通知不算取代；换了目标才是用户去了别处。
            guard let targetSessionID else { return true }
            return commit.sessionID != targetSessionID
        case .identityReplacement(let previousID):
            // 通知目标自己的 optimistic / resume ID 被替换仍是同一会话。
            guard let targetSessionID else { return true }
            return previousID != targetSessionID && commit.sessionID != targetSessionID
        }
    }

    /// 校验并在需要时重新预留意图。只有用户可见的导航才让通知让路。
    func notificationIntentAfterAwait(
        _ intent: SessionSelectionLease,
        target targetSessionID: SessionID
    ) -> SessionSelectionLease? {
        if isSelectionLeaseCurrent(intent) {
            return intent
        }
        if notificationIntentSuperseded(since: intent, target: targetSessionID) {
            return nil
        }
        return reserveSelectionIntent()
    }

    // MARK: - 本地标签匹配

    /// 用推送里的会话短标签在本地索引里找目标；只在恰好一个候选命中时返回。
    ///
    /// 回复通知带 16 位标签，直接等值比较；审批通知只带前 4 位（agentd pushbridge.SessionTag），
    /// 碰撞空间小，先限定在运行中 / 待审批 / 待输入的会话里，没有命中再退到最近 24 小时
    /// 活动过的会话。多个命中一律返回 nil，交给网络定位，不猜。
    func localNotificationSession(matching notification: LockScreenApprovalNotification) -> AgentSession? {
        let correlation = NotificationRouteDiagnostics.shortReference(notification.actionID)
        let runtime = notification.runtime.rawValue
        let expectedTag = notification.sessionTag.uppercased()
        let candidates = sessionsByID.values.filter { session in
            guard !session.isLocalDraft else { return false }
            guard let provider = session.runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !provider.isEmpty else {
                return true
            }
            return Self.normalizedRuntimeProvider(provider) == runtime
        }

        let matches: [AgentSession]
        if notification.event.isMessage {
            matches = candidates.filter {
                Self.notificationSessionTags(for: $0, prefixLength: expectedTag.count).contains(expectedTag)
            }
        } else {
            let active = candidates.filter {
                $0.isRunning || $0.pendingApproval != nil || $0.pendingUserInput != nil
            }
            let activeMatches = active.filter {
                Self.notificationSessionTags(for: $0, prefixLength: expectedTag.count).contains(expectedTag)
            }
            if !activeMatches.isEmpty {
                matches = activeMatches
            } else {
                let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
                let recent = candidates.filter {
                    ($0.recencyAt ?? $0.updatedAt ?? .distantPast) >= cutoff
                }
                matches = recent.filter {
                    Self.notificationSessionTags(for: $0, prefixLength: expectedTag.count).contains(expectedTag)
                }
            }
        }
        NotificationRouteDiagnostics.record(
            stage: NotificationRouteDiagnostics.Stage.localResolve,
            outcome: matches.count == 1 ? "hit" : "miss",
            reason: "matches=\(matches.count)",
            correlation: correlation
        )
        return matches.count == 1 ? matches.first : nil
    }

    /// 会话可能同时以 thread id 和 resume id 被引用；两者都算它的标签。
    static func notificationSessionTags(for session: AgentSession, prefixLength: Int) -> Set<String> {
        var threadIDs = [session.id]
        if let resumeID = session.resumeID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resumeID.isEmpty,
           resumeID != session.id {
            threadIDs.append(resumeID)
        }
        let length = max(1, min(prefixLength, 16))
        return Set(threadIDs.map {
            String(LockScreenApprovalRouting.messageSessionTag(threadID: $0).prefix(length))
        })
    }

    // MARK: - 项目归属

    /// 把 agentd 的线程定位信息落到本地工作区 id。按可信度依次尝试：
    /// 1. 本地已知会话的归属；2. scope id 恰好是本地工作区；3. cwd 落在某个本地工作区路径内
    /// （取最深者）；4. 根项目 id 对应的工作区（优先包含 cwd 的那个）；5. 原样返回 project id。
    func notificationProjectID(
        threadID: String,
        cwd: String?,
        scopeID: String?,
        projectID: String
    ) -> String? {
        let correlation = NotificationRouteDiagnostics.shortReference(threadID)
        let trimmedCwd = Self.nonEmptyTrimmed(cwd)
        let trimmedScopeID = Self.nonEmptyTrimmed(scopeID)
        let trimmedProjectID = Self.nonEmptyTrimmed(projectID)
        func resolved(_ id: String, rule: String) -> String {
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.projectResolve,
                outcome: "hit",
                reason: rule,
                correlation: correlation
            )
            return id
        }

        if let known = localSessionForNotification(threadID: threadID) {
            return resolved(known.projectID, rule: "rule1_known_session")
        }
        if let scope = trimmedScopeID, isKnownNotificationWorkspaceID(scope) {
            return resolved(scope, rule: "rule2_scope_id")
        }
        if let cwd = trimmedCwd, let workspace = workspaceForPath(cwd) {
            return resolved(workspace.id, rule: "rule3_cwd_path")
        }
        if let rootID = trimmedProjectID,
           let workspace = notificationWorkspaceRooted(at: rootID, containing: trimmedCwd) {
            return resolved(workspace.id, rule: "rule4_root_project")
        }
        if let rootID = trimmedProjectID {
            return resolved(rootID, rule: "rule5_project_id")
        }
        NotificationRouteDiagnostics.record(
            stage: NotificationRouteDiagnostics.Stage.projectResolve,
            outcome: "miss",
            reason: "no_attribution",
            correlation: correlation
        )
        return nil
    }

    /// 通知路由与本地会话是否指向同一线程。身份只看 id / resume id；
    /// 项目标签不同只记录诊断，不影响判定。
    func sessionMatchesNotificationRoute(_ session: AgentSession, _ route: SessionNotificationRoute) -> Bool {
        let target = route.sessionID
        let resumeID = Self.nonEmptyTrimmed(session.resumeID)
        guard session.id == target || resumeID == target else {
            return false
        }
        if session.projectID != route.projectID {
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.projectResolve,
                outcome: "tolerated",
                reason: "project_mismatch_tolerated",
                correlation: NotificationRouteDiagnostics.shortReference(target)
            )
        }
        return true
    }

    /// 本地索引按 thread id 直查，其次按 resume id；草稿没有远端线程，不参与。
    func localSessionForNotification(threadID: String) -> AgentSession? {
        if let session = sessionsByID[threadID], !session.isLocalDraft {
            return session
        }
        return sessionsByID.values.first { session in
            !session.isLocalDraft && Self.nonEmptyTrimmed(session.resumeID) == threadID
        }
    }

    func isKnownNotificationWorkspaceID(_ id: String) -> Bool {
        workspacesByID[id] != nil || sidebarProjectsByID[id] != nil || projectsByID[id] != nil
    }

    /// 根项目下的工作区（根本身、worktree、子目录）。
    /// cwd 已知时只取包含它的最深者；cwd 不落在任何同根工作区内就不猜 worktree，交给规则 5。
    /// cwd 未知时优先根本身：兼容 project id 可能已被去重掉，只剩指向根目录的 ws_ 规范 id，
    /// 它比任何 worktree 都更接近 agentd 的归属。
    func notificationWorkspaceRooted(at projectID: String, containing cwd: String?) -> AgentWorkspace? {
        let rooted = recentWorkspaces.filter { $0.id == projectID || $0.rootProjectID == projectID }
        guard !rooted.isEmpty else {
            return nil
        }
        if let cwd {
            return rooted
                .filter { remoteHostPath(cwd, isWithin: $0.path.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .sorted(by: Self.notificationWorkspacePrecedes(_:_:))
                .first
        }
        if let root = rooted.first(where: { $0.id == projectID }) {
            return root
        }
        let rootDirectoryWorkspaces = rooted.filter { workspace in
            guard let rootPath = Self.nonEmptyTrimmed(workspace.rootProjectPath) else { return false }
            return workspace.path.trimmingCharacters(in: .whitespacesAndNewlines) == rootPath
        }
        return (rootDirectoryWorkspaces.isEmpty ? rooted : rootDirectoryWorkspaces)
            .sorted(by: Self.notificationWorkspacePrecedes(_:_:))
            .first
    }

    private static func notificationWorkspacePrecedes(_ lhs: AgentWorkspace, _ rhs: AgentWorkspace) -> Bool {
        let lhsDepth = lhs.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).count
        let rhsDepth = rhs.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).count
        if lhsDepth != rhsDepth {
            return lhsDepth > rhsDepth
        }
        let lhsCanonical = lhs.id.hasPrefix("ws_")
        let rhsCanonical = rhs.id.hasPrefix("ws_")
        if lhsCanonical != rhsCanonical {
            return lhsCanonical
        }
        if lhs.lastOpenedAt != rhs.lastOpenedAt {
            return (lhs.lastOpenedAt ?? .distantPast) > (rhs.lastOpenedAt ?? .distantPast)
        }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: - 打开结果

    /// 通知来自别的 Mac：只提示切换档案，绝不自动切换连接。
    func notificationProfileSwitchOutcome(for route: SessionNotificationRoute) -> SessionNotificationOpenOutcome {
        let profileName = appStore.connectionProfiles
            .first(where: { $0.id == route.profileID })?
            .displayName
        let message: String
        if let profileName {
            message = L10n.format("ui.the_notification_comes_from_value_please_switch_the", profileName)
        } else {
            message = L10n.text("ui.the_notification_comes_from_another_mac_please_switch")
        }
        setStatusMessage(message)
        return .requiresProfileSwitch(displayName: profileName)
    }

    static func notificationOpenOutcomeLabel(_ outcome: SessionNotificationOpenOutcome) -> String {
        switch outcome {
        case .opened:
            return "opened"
        case .superseded:
            return "superseded"
        case .unavailable:
            return "unavailable"
        case .requiresProfileSwitch:
            return "requires_profile_switch"
        }
    }

    // MARK: - 网络解析

    /// thread/read 直读。凭据失效与取消直接抛出；其它失败（线程不存在、网关未授权、传输错误）
    /// 记录后返回 missing，由调用方走列表兜底。
    func readNotificationSession(
        _ route: SessionNotificationRoute,
        workspace: AgentWorkspace?,
        client: any SessionStoreAPIClient
    ) async throws -> NotificationSessionRefreshResult {
        let correlation = NotificationRouteDiagnostics.shortReference(route.sessionID)
        let startedAt = Date()
        let response: SessionResponse
        do {
            response = try await client.session(id: route.sessionID, afterSeq: nil)
        } catch {
            if isCancellationError(error) || appStore.acceptsCredentialInvalidation(error) {
                throw error
            }
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.sessionOpen,
                outcome: "read_failed",
                reason: Self.notificationReadFailureReason(error),
                correlation: correlation,
                elapsedMilliseconds: NotificationRouteDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            return .missing
        }
        guard route.profileID == appStore.notificationRoutingProfileID else {
            return .profileSwitched
        }
        guard let session = integrateNotificationReadSession(
            response.session,
            route: route,
            workspace: workspace
        ) else {
            return .missing
        }
        NotificationRouteDiagnostics.record(
            stage: NotificationRouteDiagnostics.Stage.sessionOpen,
            outcome: "read_hit",
            correlation: correlation,
            elapsedMilliseconds: NotificationRouteDiagnostics.elapsedMilliseconds(since: startedAt)
        )
        return .found(session)
    }

    /// 校验并合并直读结果。必须检查原始响应而不是重标签后的会话：`session(_:in:)` 会把
    /// projectID 强制改成工作区 id、把空 dir 填成工作区路径，重标签后再比较只会恒真。
    func integrateNotificationReadSession(
        _ raw: AgentSession,
        route: SessionNotificationRoute,
        workspace routeWorkspace: AgentWorkspace?
    ) -> AgentSession? {
        let correlation = NotificationRouteDiagnostics.shortReference(route.sessionID)
        let rawID = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawID == route.sessionID else {
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.sessionOpen,
                outcome: "read_rejected",
                reason: "read_id_mismatch",
                correlation: correlation
            )
            return nil
        }
        let rawDir = raw.dir.trimmingCharacters(in: .whitespacesAndNewlines)
        // 等待网络期间工作区身份可能被去重合并；按 id / 路径重新取当前对象。
        var workspace = routeWorkspace.flatMap { workspacesByID[$0.id] ?? workspaceForPath($0.path) }
        if let current = workspace {
            let workspacePath = current.path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawDir.isEmpty, !workspacePath.isEmpty, !remoteHostPath(rawDir, isWithin: workspacePath) {
                NotificationRouteDiagnostics.record(
                    stage: NotificationRouteDiagnostics.Stage.projectResolve,
                    outcome: "reresolve",
                    reason: "read_dir_outside_workspace",
                    correlation: correlation
                )
                workspace = nil
            }
        }
        if workspace == nil {
            let attributedProjectID = Self.nonEmptyTrimmed(raw.projectID) ?? route.projectID
            let resolvedID = notificationProjectID(
                threadID: rawID,
                cwd: rawDir.isEmpty ? nil : rawDir,
                scopeID: nil,
                projectID: attributedProjectID
            )
            // 目录既不在任何本地工作区、根项目也解析不到时，保留 agentd 的归属而不是空标签：
            // 符号链接等路径差异不应让会话脱离它本来所属的工作区。
            workspace = resolvedID.flatMap(ensureWorkspaceForKnownProjectID)
                ?? workspaceForPath(rawDir)
                ?? routeWorkspace
        }
        let relabelled = session(raw, in: workspace)
        mergeSessionPage([relabelled])
        if let workspace {
            clearWorkspaceUnavailable(workspace.id)
        }
        return sessionsByID[rawID]
    }

    /// 首屏列表兜底。runtime 已知（路由或已记住的会话路由）只查一趟；未知时先 Codex 再 Claude，
    /// 最多两次列表请求，不自动翻页。
    func listNotificationSession(
        _ route: SessionNotificationRoute,
        workspace: AgentWorkspace,
        client: any SessionStoreAPIClient,
        hostScope: HostScope
    ) async throws -> NotificationSessionRefreshResult {
        let correlation = NotificationRouteDiagnostics.shortReference(route.sessionID)
        let knownRuntime = route.runtimeProvider
            ?? client.rememberedRuntimeRoute(forSessionID: route.sessionID)
        let runtimes = knownRuntime.map { [Self.normalizedRuntimeProvider($0)] } ?? ["codex", "claude"]

        for (attempt, runtime) in runtimes.enumerated() {
            let startedAt = Date()
            let page: SessionsPage
            do {
                page = try await client.sessionsPage(
                    workspace: workspace,
                    runtimeProvider: runtime,
                    cursor: nil,
                    limit: Self.initialSessionPageLimit,
                    consistency: .fastIndexed
                )
            } catch {
                // 第二趟 Claude 只是补充尝试：bridge 未启用或不健康时，
                // 不能把已经成功的 Codex 未命中变成“无法打开”。
                guard attempt > 0, !isCancellationError(error),
                      !appStore.acceptsCredentialInvalidation(error) else {
                    throw error
                }
                NotificationRouteDiagnostics.record(
                    stage: NotificationRouteDiagnostics.Stage.sessionOpen,
                    outcome: "list_failed",
                    reason: "runtime=\(runtime)",
                    correlation: correlation,
                    elapsedMilliseconds: NotificationRouteDiagnostics.elapsedMilliseconds(since: startedAt)
                )
                break
            }
            guard route.profileID == appStore.notificationRoutingProfileID else {
                return .profileSwitched
            }
            guard isCurrentWorkspaceIdentity(workspace, hostScope: hostScope) else {
                return .missing
            }
            let refreshed = sessions(page.sessions, in: workspace)
            mergeFastIndexedSessionPagePreservingAuthoritativeFields(refreshed, workspace: workspace)
            if runtime == "codex" {
                // 只有 Codex 首屏参与 canonical 分页状态；Claude 页只补行，不能篡改 cursor。
                updateWorkspaceSessionFirstPageState(workspace: workspace, page: page, consistency: .fastIndexed)
                recordWorkspaceSessionFirstPageCompletion(workspace: workspace, page: page, consistency: .fastIndexed)
            }
            clearWorkspaceUnavailable(workspace.id)
            if let target = localSessionForNotification(threadID: route.sessionID) {
                NotificationRouteDiagnostics.record(
                    stage: NotificationRouteDiagnostics.Stage.sessionOpen,
                    outcome: "list_hit",
                    reason: "runtime=\(runtime)",
                    correlation: correlation,
                    elapsedMilliseconds: NotificationRouteDiagnostics.elapsedMilliseconds(since: startedAt)
                )
                return .found(target)
            }
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.sessionOpen,
                outcome: "list_miss",
                reason: "runtime=\(runtime)",
                correlation: correlation,
                elapsedMilliseconds: NotificationRouteDiagnostics.elapsedMilliseconds(since: startedAt)
            )
        }
        return .missing
    }

    /// 只输出枚举式原因；HTTP 状态可以帮助区分“线程不存在”和“网关未授权”，错误文本不进日志。
    static func notificationReadFailureReason(_ error: Error) -> String {
        if let apiError = error as? AgentAPIError {
            switch apiError {
            case .server(let status, _):
                return "read_http_\(status)"
            case .invalidResponse, .decoding:
                return "read_invalid_response"
            case .invalidEndpoint, .insecurePublicHTTPEndpoint, .credentialsInvalid:
                return "read_endpoint"
            }
        }
        return "read_transport"
    }
}
