import Combine
import Foundation
import Network
import UserNotifications

extension SessionStore {
    var filteredSessions: [AgentSession] {
        let base: [AgentSession]
        guard let selectedProjectID else {
            base = sortedAllSessions
            return sessionsMatchingSearch(sessionsIncludingRemoteSearch(base))
        }
        base = sortedSessionsByProjectID[selectedProjectID] ?? []
        return sessionsMatchingSearch(sessionsIncludingRemoteSearch(base, projectID: selectedProjectID))
    }

    /// 会话库不跟随 selectedProjectID 过滤；根侧栏和会话页始终看到同一份跨工作区轻量索引。
    var sessionLibrarySessions: [AgentSession] {
        let merged = sessionsIncludingRemoteSearch(sessions.filter(isListableSession))
        // 规划 Tab 必须直接依赖当前 pinnedSessionIDs 生成顺序，避免只有切换 Tab
        // 触发整页重建后才看到置顶结果；搜索补入的远端会话也使用同一排序口径。
        return sessionsMatchingSearch(sortedSessionsForList(merged))
    }

    /// 具体工作区和侧栏使用目录查询确认过的投影；全部会话保留受控全局发现的结果。
    var openedWorkspaceSessionLibrarySessions: [AgentSession] {
        sessionLibrarySessions.compactMap(sessionAlignedToOpenedWorkspace)
    }

    func sessionAlignedToOpenedWorkspace(_ item: AgentSession) -> AgentSession? {
        workspaceForDirectoryScopedSession(item).map { session(item, in: $0) }
    }

    /// 最近列表严格按活动时间排序，置顶只影响完整会话库，不改变“最近”的时间语义。
    var recentSessions: [AgentSession] {
        Array(Self.sortedSessions(sessions.filter(isListableSession)).prefix(8))
    }

    /// 进行中的任务不能被“最近 8 条”截断；侧栏始终展示当前已加载索引里的全部运行态。
    var activeSessions: [AgentSession] {
        Self.sortedSessions(sessions.filter { isListableSession($0) && ($0.isRunning || $0.isLocalDraft) })
    }

    /// 历史区保留普通最近 8 条，并从 agentd 已裁剪授权的全局结果中稳定补入少量
    /// Codex 派生只读会话。补充集仍按 recencyAt 排序，不读取 updatedAt 制造列表跳动。
    var recentHistorySessions: [AgentSession] {
        let sortedHistory = Self.sortedSessions(
            sessions.filter { isListableSession($0) && !$0.isRunning && !$0.isLocalDraft }
        )
        return sessionsIncludingDerivedReadOnlySupplements(
            base: Array(sortedHistory.prefix(8)),
            candidates: sortedHistory
        )
    }

    var filteredSidebarProjects: [AgentProject] {
        guard isSessionSearchActive else {
            return sidebarProjects
        }
        return sidebarProjects.filter { project in
            projectMatchesSearch(project)
                || !sessionsMatchingSearch(sessionsIncludingRemoteSearch(sortedSessionsByProjectID[project.id] ?? [], projectID: project.id)).isEmpty
        }
    }

    var sessionSidebarProjects: [AgentProject] {
        guard let sessionWorkspaceIDs else {
            return sidebarProjects
        }
        return sidebarProjects.filter { sessionWorkspaceIDs.contains($0.id) }
    }

    var filteredSessionSidebarProjects: [AgentProject] {
        let projects = effectiveSessionSidebarProjects
        guard isSessionSearchActive else {
            return projects
        }
        return projects.filter { project in
            projectMatchesSearch(project)
                || !sessionsMatchingSearch(sessionsIncludingRemoteSearch(sortedSessionsByProjectID[project.id] ?? [], projectID: project.id)).isEmpty
        }
    }

    var effectiveSessionSidebarProjects: [AgentProject] {
        let projects = sessionSidebarProjects
        guard selectedSessionID != nil,
              let selectedProjectID,
              !projects.contains(where: { $0.id == selectedProjectID })
        else {
            return projects
        }

        // 当前正在查看的会话必须在左侧保留上下文；这里只做临时补项，不写回工作区筛选偏好。
        return sidebarProjects.filter { project in
            project.id == selectedProjectID || projects.contains(where: { $0.id == project.id })
        }
    }

    var sessionWorkspaceSelectionCount: Int {
        sessionSidebarProjects.count
    }

    var isSessionSearchActive: Bool {
        !normalizedSessionSearchQuery.isEmpty
    }

    func isProjectExpanded(_ projectID: String) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    func isShowingAllSessions(projectID: String) -> Bool {
        sessionVisibleLimit(forProjectID: projectID) > Self.sessionPreviewLimit
    }

    func sessions(forProjectID projectID: String) -> [AgentSession] {
        sortedSessionsByProjectID[projectID] ?? []
    }

    func isSessionPinned(_ sessionID: SessionID) -> Bool {
        pinnedSessionIDs.contains(sessionID)
    }

    func isSessionArchived(_ sessionID: SessionID) -> Bool {
        archivedSessionIDs.contains(sessionID)
    }

    func isWorkspaceShownInSessions(_ projectID: String) -> Bool {
        sessionWorkspaceIDs?.contains(projectID) ?? true
    }

    func visibleSessions(forProjectID projectID: String) -> [AgentSession] {
        let sessions = sessions(forProjectID: projectID)
        return sessionsIncludingDerivedReadOnlySupplements(
            base: Self.lifecycleVisibleSessions(
                sessions,
                limit: sessionVisibleLimit(forProjectID: projectID)
            ),
            candidates: sessions
        )
    }

    func hiddenSessionCount(forProjectID projectID: String) -> Int {
        let sessions = sessions(forProjectID: projectID)
        return max(0, sessions.count - visibleSessions(forProjectID: projectID).count)
    }

    func canLoadMoreSessions(projectID: String) -> Bool {
        sessionHasMoreByProjectID[projectID] == true
    }

    func sessionListSnapshot(forProjectID projectID: String) -> ProjectSessionListSnapshot {
        sessionListSnapshotsByProjectID[projectID] ?? makeProjectSessionListSnapshot(forProjectID: projectID)
    }

    func controlState(for session: AgentSession) -> SessionControlState {
        if isProtocolReadOnlySession(session) {
            return .observing
        }
        if session.isRunning,
           session.id.hasPrefix("local:"),
           session.source == Self.optimisticSessionSource,
           session.resumeID == nil {
            // 新会话首发时会先发布 local:* 的 running 占位，再等待 thread/start 返回真实 ID。
            // 该占位由本机刚刚创建，应保持可控；这里只做内存态判定，避免把临时 ID 持久化到控制权存储。
            return .ipadOwned
        }
        if let state = sessionControlStateByID[session.id] {
            return state
        }
        return session.isRunning ? .observing : .takenOver
    }

    func canControlSession(_ session: AgentSession?) -> Bool {
        guard !isConnectionSwitchInProgress else {
            return false
        }
        guard let session else {
            return true
        }
        guard !isProtocolReadOnlySession(session) else {
            return false
        }
        guard !hasActiveWriterConflict(sessionID: session.id) else {
            return false
        }
        guard session.isRunning else {
            return true
        }
        return controlState(for: session).isControllable
    }

    var selectedQuotaNotice: CodexQuotaNotice? {
        CodexQuotaNotice.make(rateLimit: selectedSession?.rateLimit, errorMessage: errorMessage)
    }

    var selectedCodexUsageDisplay: CodexUsageDisplaySummary? {
        CodexUsageDisplaySummary.make(rateLimit: selectedSession?.rateLimit)
    }

    var accountCodexUsageWindowsDisplay: CodexUsageWindowsDisplay {
        CodexUsageWindowsDisplay.make(rateLimit: latestRateLimit(runtimeProvider: "codex"), fallbackDisplayName: "Codex")
    }

    var accountClaudeUsageWindowsDisplay: CodexUsageWindowsDisplay {
        CodexUsageWindowsDisplay.make(rateLimit: latestRateLimit(runtimeProvider: "claude"), fallbackDisplayName: "Claude")
    }

    func latestRateLimit(runtimeProvider: String) -> RateLimitSummary? {
        let normalizedProvider = Self.normalizedRuntimeProvider(runtimeProvider)
        if let cached = accountRateLimitsByRuntime[normalizedProvider] {
            return cached
        }
        if let session = selectedSession,
           Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == normalizedProvider,
           let rateLimit = session.rateLimit {
            return rateLimit
        }
        return mostRecentSessionRateLimit(runtimeProvider: normalizedProvider)
    }

    func mostRecentSessionRateLimit(runtimeProvider: String) -> RateLimitSummary? {
        sessions
            .filter { session in
                session.rateLimit != nil
                    && Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == runtimeProvider
            }
            .sorted {
                ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            .first?
            .rateLimit
    }

    var isSelectedSessionObserving: Bool {
        guard let session = selectedSession else {
            return false
        }
        return isSessionObserving(session)
    }

    func isSessionObserving(_ session: AgentSession) -> Bool {
        session.isRunning && !canControlSession(session)
    }

    var selectedSessionControlNotice: String? {
        guard isSelectedSessionObserving else {
            return nil
        }
        if let session = selectedSession,
           isProtocolReadOnlySession(session) {
            return L10n.text("ui.read_only")
        }
        return L10n.text("ui.this_session_is_running_on_other_clients_the")
    }

    var selectedSessionHasActiveWriterConflict: Bool {
        guard let selectedSessionID else {
            return false
        }
        return hasActiveWriterConflict(sessionID: selectedSessionID)
    }

    func hasActiveWriterConflict(sessionID: SessionID) -> Bool {
        activeWriterConflictLeases.contains(
            HostSessionLease(hostScope: appStore.activeHostScope, sessionID: sessionID)
        )
    }

    func setActiveWriterConflict(_ hasConflict: Bool, sessionID: SessionID) {
        syncWriterHeldElsewhere(hasConflict, sessionID: sessionID)
        let lease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: sessionID)
        if hasConflict {
            activeWriterConflictLeases.insert(lease)
            // 每次明确的 writer 拒绝都代表远端状态可能已经变化。清掉旧边界，
            // 让冲突卡重新读取最近的精简 Turn 摘要，不能复用上一次重试前的结果。
            writerConflictForkAvailabilityByLease.removeValue(forKey: lease)
            writerConflictForkErrorByLease.removeValue(forKey: lease)
            writerConflictForkPreparationRevision &+= 1
        } else {
            activeWriterConflictLeases.remove(lease)
            writerConflictForkAvailabilityByLease.removeValue(forKey: lease)
            writerConflictForkErrorByLease.removeValue(forKey: lease)
            writerConflictForkPreparationRevision &+= 1
        }
    }

    var selectedSessionAllowsTakeOver: Bool {
        guard let session = selectedSession else {
            return false
        }
        return !isProtocolReadOnlySession(session)
    }

    func isProtocolReadOnlySession(_ session: AgentSession) -> Bool {
        !session.allowsDirectInput
    }

    func settleInitialSessionLibrary(profileID: String) {
        guard !settledInitialSessionLibraryProfileIDs.contains(profileID) else { return }
        settledInitialSessionLibraryProfileIDs.insert(profileID)
    }

    func forgetInitialSessionLibrary(profileID: String) {
        settledInitialSessionLibraryProfileIDs.remove(profileID)
        initialSessionLibraryGateTimeoutScheduledProfileIDs.remove(profileID)
    }

    func canLoadEarlierHistory(sessionID: SessionID?) -> Bool {
        guard let sessionID else {
            return false
        }
        return historyHasMoreBeforeBySessionID[sessionID] == true
    }

    /// bridge 用 `canAcceptDirectInput=false` + `claudeOwner` 表示会话正被 Mac 上其他
    /// Claude 进程持有。只读本身由 `allowsDirectInput` 处理，这里只负责解释原因。
    var selectedOwnershipNotice: SessionOwnershipNotice? {
        guard let session = selectedSession,
              session.canAcceptDirectInput == false,
              let owner = session.claudeOwner else {
            return nil
        }
        return SessionOwnershipNotice(
            sessionID: session.id,
            owner: owner,
            canTakeOver: claudeTakeoverSupport?.scope == appStore.activeHostScope
                && claudeTakeoverSupport?.supported == true
                && owner.status == "idle"
                && !claudeTakeoverIsBlocked(for: session),
            isTakingOver: claudeTakeoverInFlightSessionID == session.id,
            failureMessage: claudeTakeoverFailure(for: session)?.message
        )
    }

    var selectedHistorySavingsNotice: HistorySavingsNotice? {
        guard let selectedSessionID else {
            return nil
        }
        return historySavingsNoticesBySessionID[selectedSessionID]
    }


}
