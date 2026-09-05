import Foundation

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
    func switchConnectionProfile(id: String) async throws -> Bool {
        HostSwitchSignpost.event("host_switch_tap")
        // 快速入口只执行 version + config 和一次可复用 initialize。验证或提交失败时，
        // commitPreparedConnection 不会运行，当前 Mac 的页面和 WebSocket 保持不变。
        return try await performPreparedConnectionChange(switchTargetProfileID: id) {
            if let controller = self.tailcatExperimentController {
                return try await controller.prepareConnectionProfileSwitch(
                    id: id,
                    appStore: self.appStore
                )
            }
            return try await self.appStore.prepareConnectionProfileSwitch(id: id)
        }
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
    func applyManagedPairingURL(_ url: URL) async throws -> Bool {
        try await performPreparedConnectionChange {
            guard let controller = self.tailcatExperimentController,
                  try TailcatPairingLink.parse(url) != nil else {
                throw ManagedConnectionDeviceStoreError.managedQRCodeRequired
            }
            return try await controller.preparePairingURL(
                url,
                appStore: self.appStore,
                profileTarget: .currentOrNew(displayName: nil),
                requiresManagedAuthorization: true
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
        _ prepare: @escaping () async throws -> PreparedConnectionSettings
    ) async throws -> Bool {
        let operationGeneration = try beginPreparedConnectionChange()
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
            let committed = try await commitPreparedConnection(prepared)
            await tailcatExperimentController?.commitPreparedRouteIfNeeded(prepared, appStore: appStore)
            preparedCandidate = nil
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
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    func beginPreparedConnectionChange() throws -> Int {
        guard !isAppInBackground else {
            throw CancellationError()
        }
        guard inFlightConnectionChangeGeneration == nil else {
            throw ConnectionProfileError.operationInProgress
        }
        connectionChangeGeneration += 1
        inFlightConnectionChangeGeneration = connectionChangeGeneration
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
    }

    func invalidatePreparedConnectionChange() {
        // 不提前释放占用：旧 prepare 可能仍在网络回调中。等它返回并在提交门前发现代次失效，
        // 才允许下一项操作开始，避免两个 validateConnection 同时改写 AppStore 状态。
        connectionChangeGeneration += 1
        preparedConnectionTask?.cancel()
    }

    func commitPreparedConnection(_ prepared: PreparedConnectionSettings) async throws -> Bool {
        // 必须先原子提交 Keychain/endpoint，再退役旧连接。若 Keychain 写入失败，
        // 旧 WebSocket、runtime bundle、connectionGeneration 和当前会话数据都保持不变。
        let previousProfileID = appStore.activeHostScope.profileID
        let previousWarmSnapshot = makeHostWarmSnapshot(profileID: previousProfileID)
        let didChange = try await appStore.commitConnectionSettings(prepared)
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
            if let warmSnapshot = hostWarmSnapshotCache.snapshot(for: appStore.activeHostScope.profileID) {
                applyHostWarmSnapshot(warmSnapshot)
                HostSwitchSignpost.event("warm_snapshot_visible")
            }
            reloadQueuedTurns()
        }
        setErrorMessage(nil)
        setStatusMessage(nil)
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
