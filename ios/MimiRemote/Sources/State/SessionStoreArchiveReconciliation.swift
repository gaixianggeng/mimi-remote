import Foundation

struct AuthoritativeArchiveReconciliation {
    let profileID: String
    let mutationToken: UInt64
    let protectedSessionIDs: Set<SessionID>
}

@MainActor
extension SessionStore {
    func authoritativeArchiveReconciliation(
        _ authoritative: Bool,
        hostScope: HostScope
    ) -> AuthoritativeArchiveReconciliation? {
        guard authoritative, appStore.activeHostScope == hostScope else { return nil }
        let profileID = appStore.notificationRoutingProfileID
        let protectedSessionIDs = Set(
            sessionArchiveMutationsByKey.keys.compactMap { key in
                key.profileID == profileID ? key.sessionID : nil
            }
        )
        return AuthoritativeArchiveReconciliation(
            profileID: profileID,
            mutationToken: sessionArchiveMutationToken,
            protectedSessionIDs: protectedSessionIDs
        )
    }

    func reconcileArchivedSessionsReturnedByAuthoritativeList(
        _ sessions: [AgentSession],
        using reconciliation: AuthoritativeArchiveReconciliation,
        hostScope: HostScope
    ) {
        guard appStore.activeHostScope == hostScope,
              appStore.notificationRoutingProfileID == reconciliation.profileID,
              sessionArchiveMutationToken == reconciliation.mutationToken else { return }
        let restoredSessionIDs = archivedSessionIDs
            .intersection(sessions.map(\.id))
            .subtracting(reconciliation.protectedSessionIDs)
        guard !restoredSessionIDs.isEmpty else { return }

        // 权威请求只查询未归档 Thread；重新返回即证明其他客户端已取消归档。
        archivedSessionIDs.subtract(restoredSessionIDs)
        saveSessionListPreferences()
        rebuildSessionIndexes()
    }
}
