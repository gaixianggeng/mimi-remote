import Foundation

enum HostProbeState: Equatable {
    case unknown
    case checking
    case available
    case unavailable
    case authenticationRequired
    case identityMismatch
    case upgradeRequired
}

struct HostProbeStatus: Equatable {
    let state: HostProbeState
    let profileRevision: UInt64
    let checkedAt: Date?
    let nextEligibleAt: Date
    let failureCount: Int

    static func unknown(profileRevision: UInt64) -> Self {
        Self(
            state: .unknown,
            profileRevision: profileRevision,
            checkedAt: nil,
            nextEligibleAt: .distantPast,
            failureCount: 0
        )
    }
}

private struct HostProbeResult {
    let descriptor: HostProbeDescriptor
    let version: VersionResponse?
    let error: Error?
}

private enum HostProbeCandidateError: Error {
    case installationIdentityRequired
    case installationIdentityMismatch
}

/// 只由 Mac 选择器观察。这里的 `@Published` 更新不会经过 AppStore/SessionStore，
/// 因而非当前主机状态变化不会让 Timeline 或工作台重算。
@MainActor
final class HostStatusStore: ObservableObject {
    @Published private(set) var statusesByProfileID: [String: HostProbeStatus] = [:]

    private let session: URLSession
    private let now: () -> Date
    private let jitter: () -> Double
    private var refreshTask: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var roundRobinOffset = 0

    init(
        session: URLSession? = nil,
        now: @escaping () -> Date = Date.init,
        jitter: @escaping () -> Double = { Double.random(in: 0.8...1.2) }
    ) {
        self.now = now
        self.jitter = jitter
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        refreshTask?.cancel()
        session.invalidateAndCancel()
    }

    func status(for profile: ConnectionProfile) -> HostProbeStatus {
        guard let status = statusesByProfileID[profile.id],
              status.profileRevision == profile.revision else {
            return .unknown(profileRevision: profile.revision)
        }
        return status
    }

    func refreshIfNeeded(appStore: AppStore, sessionStore: SessionStore) {
        guard refreshTask == nil,
              !appStore.hasNoConfiguredHost,
              !sessionStore.isAppInBackground,
              !sessionStore.isConnectionSwitchInProgress,
              !sessionStore.isNetworkUnavailable,
              !sessionStore.isLoading else {
            return
        }
        epoch &+= 1
        let requestedEpoch = epoch
        refreshTask = Task { [weak self, weak appStore, weak sessionStore] in
            guard let self, let appStore, let sessionStore else { return }
            await self.performRefresh(
                appStore: appStore,
                sessionStore: sessionStore,
                requestedEpoch: requestedEpoch
            )
            if self.epoch == requestedEpoch {
                self.refreshTask = nil
            }
        }
    }

    func cancel() {
        epoch &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    func invalidate(profileID: String) {
        statusesByProfileID.removeValue(forKey: profileID)
    }

#if DEBUG
    func waitForRefreshForTesting() async {
        await refreshTask?.value
    }
#endif

    private func performRefresh(
        appStore: AppStore,
        sessionStore: SessionStore,
        requestedEpoch: UInt64
    ) async {
        // 非当前主机始终需要探活；当前主机仅在旧 Profile 还没有平台元数据时补探一次。
        // 这样升级后无需用户先切走再切回，入口也能自动获得正确系统图标。
        let profiles = appStore.connectionProfiles.filter {
            $0.id != appStore.activeConnectionProfileID || $0.hostPlatform == .unknown
        }
        guard !profiles.isEmpty else { return }
        let currentDate = now()
        let rotated = rotatedProfiles(profiles)
        let targets = rotated.filter { profile in
            let status = status(for: profile)
            return status.nextEligibleAt <= currentDate
        }.prefix(8)
        guard !targets.isEmpty else { return }
        roundRobinOffset = (roundRobinOffset + targets.count) % max(1, profiles.count)

        var nextStatuses = statusesByProfileID
        for profile in targets {
            nextStatuses[profile.id] = HostProbeStatus(
                state: .checking,
                profileRevision: profile.revision,
                checkedAt: nextStatuses[profile.id]?.checkedAt,
                nextEligibleAt: .distantPast,
                failureCount: nextStatuses[profile.id]?.failureCount ?? 0
            )
        }
        statusesByProfileID = nextStatuses

        var descriptors: [HostProbeDescriptor] = []
        for profile in targets {
            guard !Task.isCancelled, epoch == requestedEpoch else { return }
            do {
                descriptors.append(try await appStore.hostProbeDescriptor(profileID: profile.id))
            } catch {
                apply(error: error, profile: profile, requestedEpoch: requestedEpoch)
            }
        }

        for startIndex in stride(from: 0, to: descriptors.count, by: 2) {
            guard !Task.isCancelled,
                  epoch == requestedEpoch,
                  !sessionStore.isConnectionSwitchInProgress,
                  !sessionStore.isAppInBackground else {
                return
            }
            let endIndex = min(startIndex + 2, descriptors.count)
            let batch = Array(descriptors[startIndex..<endIndex])
            let results = await withTaskGroup(of: HostProbeResult.self, returning: [HostProbeResult].self) { group in
                for descriptor in batch {
                    group.addTask { [session] in
                        var finalError: Error?
                        for endpoint in descriptor.endpoints {
                            do {
                                let version = try await AgentAPIClient(
                                    endpoint: endpoint,
                                    token: descriptor.token,
                                    session: session
                                ).version(timeout: 2)
                                let actualID = version.installationID?
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .lowercased()
                                guard let actualID, !actualID.isEmpty else {
                                    throw HostProbeCandidateError.installationIdentityRequired
                                }
                                if let expectedID = descriptor.expectedInstallationID?
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .lowercased(),
                                   !expectedID.isEmpty,
                                   expectedID != actualID {
                                    // MagicDNS 可能已指向另一台主机；逐候选校验身份后才能决定是否回退到保存的 IP。
                                    throw HostProbeCandidateError.installationIdentityMismatch
                                }
                                return HostProbeResult(
                                    descriptor: descriptor,
                                    version: version,
                                    error: nil
                                )
                            } catch {
                                if Task.isCancelled || error is CancellationError {
                                    return HostProbeResult(
                                        descriptor: descriptor,
                                        version: nil,
                                        error: error
                                    )
                                }
                                finalError = error
                            }
                        }
                        return HostProbeResult(
                            descriptor: descriptor,
                            version: nil,
                            error: finalError ?? URLError(.cannotConnectToHost)
                        )
                    }
                }
                var values: [HostProbeResult] = []
                for await result in group {
                    values.append(result)
                }
                return values
            }
            guard !Task.isCancelled, epoch == requestedEpoch else { return }
            for result in results {
                apply(result: result, appStore: appStore, requestedEpoch: requestedEpoch)
            }
        }
    }

    private func apply(
        result: HostProbeResult,
        appStore: AppStore,
        requestedEpoch: UInt64
    ) {
        guard epoch == requestedEpoch,
              let profile = appStore.connectionProfiles.first(where: { $0.id == result.descriptor.profileID }),
              profile.revision == result.descriptor.profileRevision else {
            return
        }
        if let error = result.error {
            apply(error: error, profile: profile, requestedEpoch: requestedEpoch)
            return
        }
        guard let version = result.version else {
            apply(error: AgentAPIError.invalidResponse, profile: profile, requestedEpoch: requestedEpoch)
            return
        }
        let actualID = version.installationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let actualID, !actualID.isEmpty else {
            applyTerminal(.upgradeRequired, profile: profile)
            return
        }
        if let expectedID = profile.installationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !expectedID.isEmpty,
           expectedID != actualID {
            applyTerminal(.identityMismatch, profile: profile)
            return
        }
        let refreshedProfile = appStore.refreshConnectionProfileHostMetadata(
            profileID: profile.id,
            expectedRevision: profile.revision,
            version: version
        ) ?? profile
        appStore.rememberHostPlatform(
            HostPlatform(serverValue: version.platform),
            profileID: profile.id,
            expectedRevision: refreshedProfile.revision
        )
        let date = now()
        statusesByProfileID[profile.id] = HostProbeStatus(
            state: .available,
            profileRevision: refreshedProfile.revision,
            checkedAt: date,
            nextEligibleAt: date.addingTimeInterval(60),
            failureCount: 0
        )
    }

    private func apply(
        error: Error,
        profile: ConnectionProfile,
        requestedEpoch: UInt64
    ) {
        guard epoch == requestedEpoch else { return }
        if error is CancellationError {
            return
        }
        if error as? ConnectionProfileError == .missingToken || isCredentialInvalidatingError(error) {
            applyTerminal(.authenticationRequired, profile: profile)
            return
        }
        if let candidateError = error as? HostProbeCandidateError {
            switch candidateError {
            case .installationIdentityRequired:
                applyTerminal(.upgradeRequired, profile: profile)
            case .installationIdentityMismatch:
                applyTerminal(.identityMismatch, profile: profile)
            }
            return
        }
        if error is ProtocolCompatibilityError {
            applyTerminal(.upgradeRequired, profile: profile)
            return
        }
        let previousFailures = statusesByProfileID[profile.id]?.failureCount ?? 0
        let nextFailureCount = previousFailures + 1
        let backoffSteps: [TimeInterval] = [15, 30, 60, 120, 300]
        let base = backoffSteps[min(previousFailures, backoffSteps.count - 1)]
        let date = now()
        statusesByProfileID[profile.id] = HostProbeStatus(
            state: .unavailable,
            profileRevision: profile.revision,
            checkedAt: date,
            nextEligibleAt: date.addingTimeInterval(base * min(max(jitter(), 0.8), 1.2)),
            failureCount: nextFailureCount
        )
    }

    private func applyTerminal(_ state: HostProbeState, profile: ConnectionProfile) {
        statusesByProfileID[profile.id] = HostProbeStatus(
            state: state,
            profileRevision: profile.revision,
            checkedAt: now(),
            nextEligibleAt: .distantFuture,
            failureCount: statusesByProfileID[profile.id]?.failureCount ?? 0
        )
    }

    private func rotatedProfiles(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        guard !profiles.isEmpty else { return [] }
        let offset = roundRobinOffset % profiles.count
        return Array(profiles[offset...]) + Array(profiles[..<offset])
    }
}
