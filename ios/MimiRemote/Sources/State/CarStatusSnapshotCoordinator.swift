import Foundation

#if os(iOS) && !targetEnvironment(macCatalyst)
import WidgetKit
#endif

struct CarStatusSessionSelection: Codable, Equatable {
    let profileID: String
    let sessionID: String
}

@MainActor
final class CarStatusSnapshotCoordinator {
    nonisolated static let appGroupID = CarStatusSnapshotStore.appGroupID
    nonisolated static let widgetKind = "MimiCarStatusWidget"
    nonisolated static let heartbeatInterval = CarStatusSnapshotV1.defaultStaleInterval / 2

    private static let selectionKey = "carStatus.selection.v1"
    private static let snapshotKey = CarStatusSnapshotStore.snapshotKey

    private let selectionDefaults: UserDefaults
    private let sharedDefaults: UserDefaults?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let now: () -> Date
    private let reloadTimelines: () -> Void

    private(set) var selection: CarStatusSessionSelection?

    init(
        selectionDefaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults? = UserDefaults(suiteName: appGroupID),
        now: @escaping () -> Date = Date.init,
        reloadTimelines: @escaping () -> Void = CarStatusSnapshotCoordinator.reloadWidgetTimelines
    ) {
        self.selectionDefaults = selectionDefaults
        self.sharedDefaults = sharedDefaults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.now = now
        self.reloadTimelines = reloadTimelines
        self.selection = Self.decodeSelection(
            selectionDefaults.data(forKey: Self.selectionKey),
            decoder: decoder
        )
    }

    func isSelected(profileID: String, sessionID: String) -> Bool {
        selection == CarStatusSessionSelection(profileID: profileID, sessionID: sessionID)
    }

    func select(profileID: String, session: AgentSession, isReachable: Bool) {
        let next = CarStatusSessionSelection(profileID: profileID, sessionID: session.id)
        selection = next
        if let data = try? encoder.encode(next) {
            selectionDefaults.set(data, forKey: Self.selectionKey)
        }
        writeIfChanged(
            CarStatusSnapshotV1(
                profileID: profileID,
                session: session,
                isReachable: isReachable,
                now: now()
            )
        )
    }

    func clearSelection() {
        let hadSelection = selection != nil
        let hadSnapshot = sharedDefaults?.data(forKey: Self.snapshotKey) != nil
        selection = nil
        selectionDefaults.removeObject(forKey: Self.selectionKey)
        sharedDefaults?.removeObject(forKey: Self.snapshotKey)
        if hadSelection || hadSnapshot {
            reloadTimelines()
        }
    }

    func synchronize(profileID: String, sessions: [AgentSession], isReachable: Bool) {
        guard let selection,
              selection.profileID == profileID,
              let session = sessions.first(where: { $0.id == selection.sessionID }) else {
            // 主机切换或列表暂时缺页时保留最后快照，由 timeline 自行转为过期。
            return
        }
        writeIfChanged(
            CarStatusSnapshotV1(
                profileID: profileID,
                session: session,
                isReachable: isReachable,
                now: now()
            )
        )
    }

    func storedSnapshot() -> CarStatusSnapshotV1? {
        guard let data = sharedDefaults?.data(forKey: Self.snapshotKey) else {
            return nil
        }
        return CarStatusSnapshotV1.decode(from: data, decoder: decoder)
    }

    private func writeIfChanged(_ snapshot: CarStatusSnapshotV1) {
        if let stored = storedSnapshot(), stored.hasSamePayload(as: snapshot) {
            // 相同内容不需要频繁 reload；但主 App 持续成功观察到 Host 时，允许在 TTL
            // 中点做一次有界 heartbeat，避免状态未变化的长任务永久停在 stale。
            let age = max(0, snapshot.publishedAt.timeIntervalSince(stored.publishedAt))
            if age < Self.heartbeatInterval {
                return
            }
        }
        guard let data = try? encoder.encode(snapshot) else {
            return
        }
        sharedDefaults?.set(data, forKey: Self.snapshotKey)
        reloadTimelines()
    }

    private static func decodeSelection(
        _ data: Data?,
        decoder: JSONDecoder
    ) -> CarStatusSessionSelection? {
        guard let data,
              let selection = try? decoder.decode(CarStatusSessionSelection.self, from: data),
              !selection.profileID.isEmpty,
              !selection.sessionID.isEmpty else {
            return nil
        }
        return selection
    }

    private nonisolated static func reloadWidgetTimelines() {
#if os(iOS) && !targetEnvironment(macCatalyst)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
#endif
    }
}

@MainActor
extension SessionStore {
    var selectedCarStatusSession: CarStatusSessionSelection? {
        carStatusSnapshotCoordinator.selection
    }

    func synchronizeCarStatusSnapshot() {
        carStatusSnapshotCoordinator.synchronize(
            profileID: appStore.notificationRoutingProfileID,
            sessions: carStatusCandidateSessions,
            isReachable: isCarStatusHostReachable
        )
    }

    private var isCarStatusHostReachable: Bool {
        guard connectionTermination == nil, !appStore.requiresRePairing else {
            return false
        }
        return Self.hasRecentCarStatusHostObservation(
            networkStatus: networkReachabilityStatus,
            lastSuccessfulObservationAt: carStatusLastSuccessfulHostObservationAt,
            now: sessionListNow()
        )
    }

    static func hasRecentCarStatusHostObservation(
        networkStatus: NetworkReachabilityStatus,
        lastSuccessfulObservationAt: Date?,
        now: Date
    ) -> Bool {
        guard networkStatus == .satisfied,
              let lastSuccessfulObservationAt else {
            // .unknown 必须 fail-closed，不能把“尚未确认”显示成在线。
            return false
        }
        let age = now.timeIntervalSince(lastSuccessfulObservationAt)
        return age >= 0 && age < CarStatusSnapshotV1.defaultStaleInterval
    }

    func recordCarStatusHostObservation(at date: Date) {
        carStatusLastSuccessfulHostObservationAt = date
        synchronizeCarStatusSnapshot()
    }

    static func carStatusHostDidRespond(to error: Error) -> Bool {
        guard let apiError = error as? AgentAPIError else {
            return false
        }
        switch apiError {
        case .server, .credentialsInvalid, .decoding:
            // HTTP 业务错误、鉴权响应或响应体解码错误都证明 transport 已到达 Host。
            return true
        case .invalidEndpoint, .insecurePublicHTTPEndpoint, .invalidResponse:
            return false
        }
    }

    func invalidateCarStatusHostObservation(ifNotNewerThan requestStartedAt: Date? = nil) {
        if let requestStartedAt,
           let lastObservation = carStatusLastSuccessfulHostObservationAt,
           lastObservation > requestStartedAt {
            // 并发请求的迟到失败不能覆盖另一请求刚写入的更新成功证据。
            return
        }
        guard carStatusLastSuccessfulHostObservationAt != nil else {
            synchronizeCarStatusSnapshot()
            return
        }
        carStatusLastSuccessfulHostObservationAt = nil
        synchronizeCarStatusSnapshot()
    }

    private var carStatusCandidateSessions: [AgentSession] {
        let canonicalIDs = Set(sessions.map(\.id))
        return sessions + remoteSessionSearchResults.filter { !canonicalIDs.contains($0.id) }
    }
}
