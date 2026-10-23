import Foundation

/// 外部配对链接在首次配对页上的进度；失败只保留原始描述，文案由页面统一友好化。
enum PairingLinkAttempt: Equatable {
    case idle
    case connecting
    case failed(String)
}

/// 换电脑请求之间的取代关系（#801）。一台电脑握手慢时，用户可以改选或取消，
/// 不必等它的预热时限耗尽；配对、改地址等其它连接变更仍然互斥。
struct ConnectionSwitchSupersession {
    /// 最新一次换电脑选择；排队中的旧选择被唤醒后发现自己不是最新就放弃。
    var latestRequestID: UUID?
    /// 在途的连接变更是不是换电脑：只有换电脑可以被新的换电脑取代。
    var inFlightIsSwitch = false
    /// 等在途变更回收的请求，变更结束时统一唤醒。
    var idleWaiters: [CheckedContinuation<Void, Never>] = []
}

/// 一键接入的请求与二次确认共用同一份主机快照。切走再切回也会改变 scope 代次，
/// 旧确认不能重新获得授权；client 固定为最初的电脑，不能在确认时重新取当前电脑。
@MainActor
struct ManagedConnectionUpgradeContext {
    let id = UUID()
    let profile: ConnectionProfile
    private let hostScope: HostScope
    private let credentialFingerprint: String
    private let client: AgentAPIClient

    init(appStore: AppStore, client: AgentAPIClient) throws {
        guard let profile = appStore.activeConnectionProfile,
              let fingerprint = appStore.authenticatedCredentialFingerprint else {
            throw CancellationError()
        }
        self.profile = profile
        hostScope = appStore.activeHostScope
        credentialFingerprint = fingerprint
        self.client = client
    }

    func isCurrent(in appStore: AppStore) -> Bool {
        appStore.activeHostScope == hostScope &&
            appStore.activeConnectionProfile?.revision == profile.revision &&
            appStore.authenticatedCredentialFingerprint == credentialFingerprint
    }

    func requestPairingLink(
        confirmResetSelfHosted: Bool,
        appStore: AppStore
    ) async throws -> ManagedPairingLinkResponse {
        try checkCurrent(in: appStore)
        do {
            let response = try await client.managedPairingLink(confirmResetSelfHosted: confirmResetSelfHosted)
            try checkCurrent(in: appStore)
            return response
        } catch {
            // 迟到的 409 也必须失效，否则它会在另一台电脑上重新弹出危险操作确认。
            try checkCurrent(in: appStore)
            throw error
        }
    }

    func checkCurrent(in appStore: AppStore) throws {
        try Task.checkCancellation()
        guard isCurrent(in: appStore) else { throw CancellationError() }
    }
}

// 多 Mac 连接变更、Profile 清理和暖快照恢复共享同一事务边界。
extension SessionStore {
    func resetConnectionForSettingsChange(clearData: Bool = false) {
        invalidatePreparedConnectionChange()
        connectionTermination = nil
        appLifecycleSuspendedSessionID = nil
        networkSuspendedSessionID = nil
        disconnectWebSocket()
        activeWriterConflictLeases.removeAll()
        clearAllWriterConflictForkState()
        if clearData {
            if !appStore.isConfigured, let profileID = currentQueuedTurnProfileID {
                do {
                    try queuedTurnStore.remove(profileID: profileID)
                    queuedTurnStorageErrorMessage = nil
                } catch {
                    reportQueuedTurnStorageError(error)
                }
            }
            clearConnectionData()
        }
        setErrorMessage(nil)
        setStatusMessage(nil)
        // setStatusMessage(nil) 只收起信息提示；失败提示的重试闭包捕获的是旧主机上的会话，
        // 换连接后再点「重试」会把旧 thread ID 发给当前主机，所以连接边界上一并收起。
        dismissOperationFeedback()
    }

    @discardableResult
    func retryManagedConnection() async -> Bool {
        guard let tailcatExperimentController else { return false }
        resetConnectionForSettingsChange()
        guard await tailcatExperimentController.retryManagedConnection(appStore: appStore) else {
            return false
        }
        return await refreshAfterConnectionCommit(maxWait: 10)
    }

    @discardableResult
    func useSavedConnectionRouteOnce(_ route: ConnectionProfileRoute) async -> Bool {
        guard let tailcatExperimentController else { return false }
        resetConnectionForSettingsChange()
        guard await tailcatExperimentController.useSavedRouteOnce(route, appStore: appStore) else {
            return false
        }
        return await refreshAfterConnectionCommit(maxWait: 10)
    }

    @discardableResult
    func applyConnectionSettings(
        endpoint: String,
        token: String
    ) async throws -> Bool {
        try await performPreparedConnectionChange {
            try await self.appStore.prepareConnectionSettings(
                endpoint: endpoint,
                token: token
            )
        }
    }

    @discardableResult
    func addConnectionProfile(
        endpoint: String,
        token: String,
        displayName: String
    ) async throws -> Bool {
        try await performPreparedConnectionChange {
            try await self.appStore.prepareNewConnectionProfile(
                endpoint: endpoint,
                token: token,
                displayName: displayName
            )
        }
    }

    @discardableResult
    func switchConnectionProfile(id: String, notificationIntent: UUID? = nil) async throws -> Bool {
        if let notificationIntent {
            guard notificationNavigation.isCurrent(notificationIntent) else { throw CancellationError() }
        } else {
            notificationNavigation.userNavigated()
        }
        HostSwitchSignpost.event("host_switch_tap")
        try await supersedeInFlightConnectionSwitch()
        // 快速入口只执行 version + config 和一次可复用 initialize。验证或提交失败时，
        // commitPreparedConnection 不会运行，当前 Mac 的页面和 WebSocket 保持不变。
        return try await performPreparedConnectionChange(
            switchTargetProfileID: id,
            isNavigationCurrent: { notificationIntent.map(self.notificationNavigation.isCurrent) ?? true }
        ) {
            if let controller = self.tailcatExperimentController {
                return try await controller.prepareConnectionProfileSwitch(
                    id: id,
                    appStore: self.appStore
                )
            }
            return try await self.appStore.prepareConnectionProfileSwitch(id: id)
        }
    }

    /// 新的换电脑选择取代在途的换电脑：旧候选在提交门前失效，等它回收后再开始，
    /// 同一时刻仍只有一个 prepare 在改写连接状态。旧候选没提交，当前电脑的链路始终保留。
    private func supersedeInFlightConnectionSwitch() async throws {
        let requestID = UUID()
        connectionSwitchSupersession.latestRequestID = requestID
        while inFlightConnectionChangeGeneration != nil {
            guard connectionSwitchSupersession.inFlightIsSwitch else {
                throw ConnectionProfileError.operationInProgress
            }
            invalidatePreparedConnectionChange()
            await withCheckedContinuation { connectionSwitchSupersession.idleWaiters.append($0) }
            guard connectionSwitchSupersession.latestRequestID == requestID, !Task.isCancelled else {
                throw CancellationError()
            }
        }
    }

    /// 菜单里的「取消切换」：撤销在途和排队中的换电脑，留在当前电脑。
    func cancelConnectionSwitch() {
        connectionSwitchSupersession.latestRequestID = nil
        guard inFlightConnectionChangeGeneration != nil,
              connectionSwitchSupersession.inFlightIsSwitch else { return }
        invalidatePreparedConnectionChange()
    }

    func deleteConnectionProfile(id: String) async throws {
        try await appStore.deleteConnectionProfile(id: id)
        try? tailcatExperimentController?.deleteProfileRoute(profileID: id)
        purgeConnectionProfileData(profileID: id)
        // 删除重复 endpoint 的非当前 Profile 后，旧版 endpoint 数据可能刚刚变为唯一可归属。
        // 立即重载本地 Store，避免必须切换 Mac 或手动刷新后才恢复最近工作区等偏好。
        reloadRecentWorkspaces()
    }

    /// 当前 Mac 与非当前 Mac 共用同一条清理路径。先完成 Keychain 提交，再退役连接和清理
    /// Profile namespace，确保 Keychain 失败时旧页面、Runtime 与本地数据都保持原样。
    func clearCurrentConnectionProfile() async throws {
        let removedProfileID = appStore.activeHostScope.profileID
        try await appStore.clearPairing()
        try? tailcatExperimentController?.deleteProfileRoute(profileID: removedProfileID)
        resetConnectionForSettingsChange(clearData: true)
        purgeConnectionProfileData(profileID: removedProfileID)
    }

    private func purgeConnectionProfileData(profileID: String) {
        // Profile 已删除后不再保留事务锁；token 同时失效，迟到请求不会重新写回已清理的偏好。
        discardSessionArchiveMutationState(profileID: profileID)
        hostWarmSnapshotCache.remove(profileID: profileID)
        conversationStore.remove(profileID: profileID)
        logStore.remove(profileID: profileID)
        contextStore.remove(profileID: profileID)
        terminalStreamStore.removeAll(profileID: profileID)
        recentWorkspaceStore.remove(profileID: profileID)
        sessionListPreferenceStore.remove(profileID: profileID)
        sessionHistoryReadStateStore.remove(profileID: profileID)
        sessionControlStateStore.remove(profileID: profileID)
        sessionReminderStore.remove(profileID: profileID)
        sessionReminderScheduler.cancel(profileID: profileID)
        workspaceAppearanceStore.remove(profileID: profileID)
        do {
            try queuedTurnStore.remove(profileID: profileID)
            queuedTurnStorageErrorMessage = nil
        } catch {
            // 档案凭据已经按 AppStore 的事务边界删除；本地队列清理失败不回滚凭据，
            // 只显式提示残留，避免界面误以为 Mac 连接仍然存在。
            reportQueuedTurnStorageError(error)
        }
    }

    /// 系统相机扫码或其它 App 打开的配对链接。配对仍在 App 层执行，停在哪一页都能连上；
    /// 但首次配对页按 #557 只显示本页操作的反馈、不读全局 `lastError`，所以还没有任何电脑时
    /// 要把进度和失败原因经 `pairingLinkAttempt` 交给它，否则失败时页面毫无变化（#728）。
    func openPairingLink(_ url: URL) async {
        let wasConfigured = appStore.isConfigured
        let reportsToFirstConnectionPage = appStore.connectionProfiles.isEmpty
        if reportsToFirstConnectionPage {
            pairingLinkAttempt = .connecting
        }
        do {
            _ = try await applyPairingURL(url)
            if reportsToFirstConnectionPage {
                pairingLinkAttempt = .idle
            }
            // 首次 URL 配对要覆盖 Tailscale / gateway 冷启动窗口；已有档案修复只做短等待。
            _ = await refreshAfterConnectionCommit(maxWait: wasConfigured ? 10 : 45)
        } catch {
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            if reportsToFirstConnectionPage {
                pairingLinkAttempt = .failed(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func applyPairingURL(_ url: URL) async throws -> Bool {
        try await performPreparedConnectionChange {
            if let controller = self.tailcatExperimentController,
               try TailcatPairingLink.parse(url) != nil {
                return try await controller.preparePairingURL(
                    url,
                    appStore: self.appStore,
                    profileTarget: .currentOrNew(displayName: nil)
                )
            }
            return try await self.appStore.preparePairingURL(url)
        }
    }

    @discardableResult
    func applyManagedPairingURL(
        _ url: URL,
        upgrading context: ManagedConnectionUpgradeContext? = nil
    ) async throws -> Bool {
        try context?.checkCurrent(in: appStore)
        return try await performPreparedConnectionChange(
            isNavigationCurrent: { context?.isCurrent(in: self.appStore) ?? true }
        ) {
            try context?.checkCurrent(in: self.appStore)
            guard let controller = self.tailcatExperimentController,
                  try TailcatPairingLink.parse(url) != nil else {
                throw ManagedConnectionDeviceStoreError.managedQRCodeRequired
            }
            return try await controller.preparePairingURL(
                url,
                appStore: self.appStore,
                profileTarget: context.map { .existingProfile(id: $0.profile.id) }
                    ?? .currentOrNew(displayName: nil),
                requiresManagedAuthorization: true,
                preservingEndpoint: context?.profile.endpoint
            )
        }
    }

    @discardableResult
    func addConnectionProfile(pairingURL url: URL, displayName: String) async throws -> Bool {
        try await performPreparedConnectionChange {
            if let controller = self.tailcatExperimentController,
               try TailcatPairingLink.parse(url) != nil {
                return try await controller.preparePairingURL(
                    url,
                    appStore: self.appStore,
                    profileTarget: .newProfile(
                        id: UUID().uuidString,
                        displayName: displayName
                    )
                )
            }
            return try await self.appStore.prepareNewPairingURL(url, displayName: displayName)
        }
    }

    @discardableResult
    func addManagedConnectionProfile(pairingURL url: URL, displayName: String) async throws -> Bool {
        try await performPreparedConnectionChange {
            guard let controller = self.tailcatExperimentController,
                  try TailcatPairingLink.parse(url) != nil else {
                throw ManagedConnectionDeviceStoreError.managedQRCodeRequired
            }
            return try await controller.preparePairingURL(
                url,
                appStore: self.appStore,
                profileTarget: .newProfile(id: UUID().uuidString, displayName: displayName),
                requiresManagedAuthorization: true
            )
        }
    }

    /// 串行化所有“验证新凭据后提交”的入口。该方法保持 internal 是为了让 XCTest 能用
    /// 可控 prepare 闭包确定性复现取消/并发，不把测试钩子带进线上分支。
    @discardableResult
    func performPreparedConnectionChange(
        switchTargetProfileID: String? = nil,
        isNavigationCurrent: @escaping () -> Bool = { true },
        _ prepare: @escaping () async throws -> PreparedConnectionSettings
    ) async throws -> Bool {
        let operationGeneration = try beginPreparedConnectionChange(isSwitch: switchTargetProfileID != nil)
        if let switchTargetProfileID {
            connectionSwitchTargetGeneration = operationGeneration
            setConnectionSwitchTargetProfileID(switchTargetProfileID)
        }
        let previousStatus = appStore.connectionStatus
        let previousError = appStore.lastError
        let previousDuration = appStore.lastConnectionTestDurationMillis
        let previousReport = appStore.lastConnectionTestReport
        let previousRecentReports = appStore.recentConnectionTestReports
        let previousSessionTermination = connectionTermination
        let previousAppTermination = appStore.connectionTermination
        var preparedCandidate: PreparedConnectionSettings?
        defer { finishPreparedConnectionChange(operationGeneration) }

        do {
            let prepareTask = Task { @MainActor in
                try await prepare()
            }
            preparedConnectionTask = prepareTask
            let prepared = try await withTaskCancellationHandler {
                try await prepareTask.value
            } onCancel: {
                prepareTask.cancel()
            }
            preparedCandidate = prepared
            try Task.checkCancellation()
            guard operationGeneration == connectionChangeGeneration,
                  inFlightConnectionChangeGeneration == operationGeneration,
                  !isAppInBackground else {
                throw CancellationError()
            }
            try await tailcatExperimentController?.stagePreparedRouteIfNeeded(prepared, appStore: appStore)
            // stage 和提交里的凭据写入都会 await，取消或改选可能正落在这期间；只撤销已结束的
            // prepare 任务拦不住，提交门前必须再核对代次（#801）。
            let isOperationCurrent = {
                self.connectionChangeGeneration == operationGeneration && isNavigationCurrent()
            }
            guard isOperationCurrent() else { throw CancellationError() }
            let committed = try await commitPreparedConnection(prepared, isStillCurrent: isOperationCurrent)
            await tailcatExperimentController?.commitPreparedRouteIfNeeded(prepared, appStore: appStore)
            preparedCandidate = nil
            // 换到已有电脑不算配对；扫码、粘贴链接和新增电脑当天都不邀请评分（#842）。
            if switchTargetProfileID == nil { appReviewPrompt?.recordPairingCompleted() }
            return committed
        } catch {
            if let preparedCandidate {
                await preparedCandidate.hostContext?.discard()
            }
            await tailcatExperimentController?.discardPreparedRouteIfNeeded(
                preparedCandidate,
                appStore: appStore
            )
            // 失败时恢复验证前的展示状态，但若等待期间旧 WS 已进入鉴权终态，必须保留
            // 新终态；否则一次失败的切换会把“访问码已失效”错误覆盖回已连接。
            if connectionTermination == previousSessionTermination,
               appStore.connectionTermination == previousAppTermination {
                appStore.connectionStatus = previousStatus
                appStore.lastError = previousError
                appStore.lastConnectionTestDurationMillis = previousDuration
                appStore.lastConnectionTestReport = previousReport
                appStore.recentConnectionTestReports = previousRecentReports
            }
            // 被改选、取消或退后台撤销的候选，底层可能以 URLError.cancelled 等形式结束；
            // 统一按取消上报，界面不把用户自己的改选显示成切换失败（#801）。
            if Task.isCancelled || error is CancellationError || operationGeneration != connectionChangeGeneration {
                throw CancellationError()
            }
            throw error
        }
    }

    func beginPreparedConnectionChange(isSwitch: Bool = false) throws -> Int {
        guard !isAppInBackground else {
            throw CancellationError()
        }
        guard inFlightConnectionChangeGeneration == nil else {
            throw ConnectionProfileError.operationInProgress
        }
        connectionChangeGeneration += 1
        inFlightConnectionChangeGeneration = connectionChangeGeneration
        connectionSwitchSupersession.inFlightIsSwitch = isSwitch
        return connectionChangeGeneration
    }

    func finishPreparedConnectionChange(_ generation: Int) {
        guard inFlightConnectionChangeGeneration == generation else { return }
        preparedConnectionTask = nil
        if connectionSwitchTargetGeneration == generation {
            connectionSwitchTargetGeneration = nil
            setConnectionSwitchTargetProfileID(nil)
        }
        inFlightConnectionChangeGeneration = nil
        connectionSwitchSupersession.inFlightIsSwitch = false
        let waiters = connectionSwitchSupersession.idleWaiters
        connectionSwitchSupersession.idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func invalidatePreparedConnectionChange() {
        // 不提前释放占用：旧 prepare 可能仍在网络回调中。等它返回并在提交门前发现代次失效，
        // 才允许下一项操作开始，避免两个 validateConnection 同时改写 AppStore 状态。
        connectionChangeGeneration += 1
        preparedConnectionTask?.cancel()
    }

    func commitPreparedConnection(
        _ prepared: PreparedConnectionSettings,
        isStillCurrent: () -> Bool = { true }
    ) async throws -> Bool {
        // 必须先原子提交 Keychain/endpoint，再退役旧连接。若 Keychain 写入失败，
        // 旧 WebSocket、runtime bundle、connectionGeneration 和当前会话数据都保持不变。
        let previousHostScope = appStore.activeHostScope
        let previousProfileID = previousHostScope.profileID
        let previousWarmSnapshot = makeHostWarmSnapshot(profileID: previousProfileID)
        let didChange = try await appStore.commitConnectionSettings(prepared, isStillCurrent: isStillCurrent)
        if didChange {
            for sessionID in Array(queuedRunningTurnsBySessionID.keys) {
                markDispatchingQueuedTurnsNeedsConfirmation(
                    sessionID: sessionID,
                    message: L10n.text("ui.unconfirmed_send_after_mac_switch")
                )
            }
        }
        connectionTermination = nil
        appLifecycleSuspendedSessionID = nil
        networkSuspendedSessionID = nil
        // 必须在三个 Store 仍指向旧 Profile 时退役旧 socket；disconnect 会把旧主机中
        // 未确认的本地发送标记为失败，不能误写到新主机的同名 session。
        disconnectWebSocket()
        if didChange {
            let activeProfileID = appStore.activeHostScope.profileID
            // activeHostState 已原子提交后再切换所有高频 Store namespace。
            // 延迟 delta/flush 自己捕获旧 ScopedSessionID，因此迟到结果不会写入新 Mac。
            conversationStore.activate(profileID: activeProfileID)
            logStore.activate(profileID: activeProfileID)
            contextStore.activate(profileID: activeProfileID)
            terminalStreamStore.removeAll(profileID: previousProfileID)
            Task {
                await hostWarmSnapshotCache.store(previousWarmSnapshot)
            }
            clearConnectionData()
            let activeHostScope = appStore.activeHostScope
            if activeHostScope.profileID != previousHostScope.profileID
                || activeHostScope.installationID != previousHostScope.installationID {
                // 提交到清空旧数据之间，旧主机的会话可能已被补进新档案的路由表；换档案时清掉，
                // 再由暖快照和新主机列表补齐（#784）。
                appStore.runtimeRoutesForActiveHost().removeAll()
            }
            if let warmSnapshot = hostWarmSnapshotCache.snapshot(for: appStore.activeHostScope.profileID) {
                applyHostWarmSnapshot(warmSnapshot)
                HostSwitchSignpost.event("warm_snapshot_visible")
            }
            reloadQueuedTurns()
        }
        setErrorMessage(nil)
        setStatusMessage(nil)
        // 同上：旧主机的失败提示（及其重试闭包）不能带到新主机。
        dismissOperationFeedback()
        return didChange
    }

    private func makeHostWarmSnapshot(profileID: String) -> HostWarmSnapshot {
        var firstPageSessions = Array(sessions.prefix(Self.initialSessionPageLimit))
        if let selectedSessionID,
           !firstPageSessions.contains(where: { $0.id == selectedSessionID }),
           let selectedSession = sessionsByID[selectedSessionID] {
            if firstPageSessions.count == Self.initialSessionPageLimit {
                firstPageSessions.removeLast()
            }
            firstPageSessions.append(selectedSession)
        }
        let blockingTaskCount = pendingApprovalDecisionIDsBySessionID.values.reduce(0) { $0 + $1.count }
            + pendingUserInputResponseIDsBySessionID.values.reduce(0) { $0 + $1.count }
        return HostWarmSnapshot(
            profileID: profileID,
            projects: Array(projects.prefix(50)),
            recentWorkspaces: Array(recentWorkspaces.prefix(50)),
            sidebarProjects: Array(sidebarProjects.prefix(50)),
            sessions: firstPageSessions,
            selectedProjectID: selectedProjectID,
            selectedSessionID: selectedSessionID,
            selectedProjectCursor: selectedProjectID.flatMap { sessionPageCursorByProjectID[$0] },
            selectedProjectHasMore: selectedProjectID.flatMap { sessionHasMoreByProjectID[$0] } ?? false,
            blockingTaskCount: blockingTaskCount,
            capturedAt: Date()
        )
    }

    private func applyHostWarmSnapshot(_ snapshot: HostWarmSnapshot) {
        guard snapshot.profileID == appStore.activeHostScope.profileID else {
            return
        }
        setProjectsIfChanged(snapshot.projects)
        setRecentWorkspacesIfChanged(snapshot.recentWorkspaces)
        setSidebarProjectsIfChanged(snapshot.sidebarProjects)
        sessions = snapshot.sessions
        if let projectID = snapshot.selectedProjectID {
            sessionPageCursorByProjectID[projectID] = snapshot.selectedProjectCursor
            sessionHasMoreByProjectID[projectID] = snapshot.selectedProjectHasMore
        }
        let selectedSessionID = snapshot.selectedSessionID.flatMap { sessionsByID[$0] == nil ? nil : $0 }
        _ = commitSelection(
            projectID: snapshot.selectedProjectID,
            sessionID: selectedSessionID,
            reason: .restoration
        )
    }
}
