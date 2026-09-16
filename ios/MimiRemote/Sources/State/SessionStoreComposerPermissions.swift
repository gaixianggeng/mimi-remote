import Foundation

extension SessionStore {
    func saveComposerPermissionSelection(
        _ snapshot: ComposerPermissionSelectionSnapshot,
        for scope: ComposerDraftScopeKey
    ) {
        composerPermissionSelectionCache.save(snapshot, for: scope)
        guard case .session(let sessionID) = scope, !sessionID.hasPrefix("local:") else { return }
        sessionControlStateStore.savePermissionSelection(
            snapshot, sessionID: sessionID, profileID: appStore.notificationRoutingProfileID
        )
    }

    func composerPermissionSelection(
        for scope: ComposerDraftScopeKey
    ) -> ComposerPermissionSelectionSnapshot? {
        composerPermissionSelectionCache.snapshot(for: scope)
    }

    func removeComposerPermissionSelection(for scope: ComposerDraftScopeKey) {
        composerPermissionSelectionCache.remove(scope: scope)
    }

    func restoredComposerPermissionSelection(
        for scope: ComposerDraftScopeKey,
        runtimeProvider: String?,
        defaultMode: ComposerPermissionMode
    ) -> ComposerPermissionSelectionSnapshot {
        if let snapshot = composerPermissionSelection(for: scope) {
            return snapshot
        }
        var options = CodexAppServerTurnOptions.default
        if case .session(let sessionID) = scope, !sessionID.hasPrefix("local:") {
            // 待发送边界保存了 requiresNewTurn，优先于持久化的稳定权限选择。
            if let boundary = latestPendingPermissionTurnBoundary(for: sessionID) {
                return boundary.permissionSelection
            }
            if let snapshot = sessionControlStateStore.permissionSelection(
                sessionID: sessionID, profileID: appStore.notificationRoutingProfileID
            ) {
                return snapshot
            }
            if runtimeProvider == "claude" {
                // 旧版本没有保存会话权限，Claude bridge 也不支持继承标记。
                // 无法还原的历史选择从请求审批开始，不能套用其他会话的完全访问偏好。
                ComposerPermissionMode.requestApproval.apply(to: &options)
            } else {
                options.preservesThreadPermissionSettings = true
            }
        } else {
            defaultMode.apply(to: &options)
        }
        return ComposerPermissionSelectionSnapshot(options: options)
    }
}

extension SessionControlStateStore {
    private typealias PermissionStorage = ProfileScopedStorage<[SessionID: ComposerPermissionSelectionSnapshot]>
    private var permissionKey: String { key + ".permissions" }

    func permissionSelection(sessionID: SessionID, profileID: String) -> ComposerPermissionSelectionSnapshot? {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else { return nil }
        return permissionStorage().byProfileID[profileKey]?[sessionID]
    }

    func savePermissionSelection(
        _ snapshot: ComposerPermissionSelectionSnapshot,
        sessionID: SessionID,
        profileID: String
    ) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else { return }
        var storage = permissionStorage()
        var stableSelection = snapshot
        // 新轮次边界由队列单独持久化；完成的边界不能在下次启动时被重新激活。
        stableSelection.requiresNewTurn = false
        storage.byProfileID[profileKey, default: [:]][sessionID] = stableSelection
        persistPermissions(storage)
    }

    func removePermissionSelections(profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else { return }
        var storage = permissionStorage()
        guard storage.byProfileID.removeValue(forKey: profileKey) != nil else { return }
        persistPermissions(storage)
    }

    private func permissionStorage() -> PermissionStorage {
        guard let data = defaults.data(forKey: permissionKey),
              let storage = try? JSONDecoder().decode(PermissionStorage.self, from: data)
        else { return PermissionStorage() }
        return storage
    }

    private func persistPermissions(_ storage: PermissionStorage) {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: permissionKey)
    }
}
