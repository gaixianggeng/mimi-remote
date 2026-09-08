import Foundation

struct SessionArchiveReconciliationSnapshot {
    let hostScope: HostScope
    let profileID: String
    let mutationToken: UInt64
    let protectedSessionIDs: Set<SessionID>
}

extension SessionStore {
    func archiveReconciliationSnapshot(
        consistency: SessionListConsistency
    ) -> SessionArchiveReconciliationSnapshot? {
        guard consistency == .authoritative, !archivedSessionIDs.isEmpty else { return nil }
        let profileID = appStore.notificationRoutingProfileID
        return SessionArchiveReconciliationSnapshot(
            hostScope: appStore.activeHostScope,
            profileID: profileID,
            mutationToken: sessionArchiveMutationToken,
            protectedSessionIDs: Set(sessionArchiveMutationsByKey.keys.compactMap {
                $0.profileID == profileID ? $0.sessionID : nil
            })
        )
    }

    func reconcileArchivedSessions(
        _ returnedSessions: [AgentSession],
        snapshot: SessionArchiveReconciliationSnapshot?
    ) {
        guard let snapshot, !Task.isCancelled,
              appStore.activeHostScope == snapshot.hostScope,
              appStore.notificationRoutingProfileID == snapshot.profileID,
              sessionArchiveMutationToken == snapshot.mutationToken else { return }

        // 只认本次未归档权威响应真正返回的 ID，未出现的会话不能据此恢复。
        // 快照必须在实际网络请求前取得；共享请求的后加入者不能重置保护窗口。
        // 请求期间新发起的归档，以及请求前尚未完成的归档，都不能被旧响应撤销。
        let restoredIDs = archivedSessionIDs.intersection(returnedSessions.map(\.id))
            .subtracting(snapshot.protectedSessionIDs)
        guard !restoredIDs.isEmpty else { return }
        archivedSessionIDs.subtract(restoredIDs)
        saveSessionListPreferences()
        rebuildSessionIndexes()
    }
}
