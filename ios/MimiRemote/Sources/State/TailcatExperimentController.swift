import Foundation

enum TailcatExperimentState: Equatable {
    case disabled
    case needsAddress
    case starting
    case connected(endpoint: String)
    case failed(message: String)
    case unavailable
}

struct TailcatPathDiagnostic: Codable, Equatable, Identifiable {
    let id: UUID
    let checkedAt: Date
    let path: String
    let latencyMillis: Int?
    let derpRegionCode: String?
    let succeeded: Bool
    let requestLatencyMillis: Int?
    let requestSucceeded: Bool?

    var summary: String {
        guard succeeded else { return L10n.text("ui.tailscale_path_unavailable") }
        let latency = latencyMillis.map { " · \($0) ms" } ?? ""
        switch path {
        case "direct": return L10n.text("ui.tailscale_path_direct") + latency
        case "peer-relay": return L10n.text("ui.tailscale_path_peer_relay") + latency
        case "derp":
            let region = derpRegionCode.map { " (\($0))" } ?? ""
            return L10n.text("ui.tailscale_path_derp") + region + latency
        default: return L10n.text("ui.tailscale_path_unknown") + latency
        }
    }

    var requestSummary: String? {
        guard let requestSucceeded else { return nil }
        guard requestSucceeded, let requestLatencyMillis else {
            return L10n.text("ui.tailcat_request_failed")
        }
        return L10n.format("ui.tailcat_request_latency_value", String(requestLatencyMillis))
    }
}

struct TailcatDiscoPingPayload: Decodable, Sendable {
    let path: String
    let latencyMillis: Int
    let derpRegionCode: String?

    enum CodingKeys: String, CodingKey {
        case path
        case latencyMillis = "latency_millis"
        case derpRegionCode = "derp_region_code"
    }
}

protocol TailcatExperimentRuntimeProtocol: Actor {
    func start(address: String, privateKey: String) async throws -> String
    func prepare(address: String, privateKey: String) async throws -> String
    func activatePrepared(endpoint: String) throws
    func discardPrepared(endpoint: String) throws
    func hasPrepared(endpoint: String) -> Bool
    func discoPing() throws -> TailcatDiscoPingPayload
    func stop() throws
    func stop(ifCurrentEndpoint endpoint: String) throws
}

struct TailcatExperimentBridgeAdapter {
    let isAvailable: Bool
    let generatePrivateKey: () throws -> String
    let publicKey: (String) throws -> String

    static let live = TailcatExperimentBridgeAdapter(
        isAvailable: MimiTailcatBridge.isAvailable,
        generatePrivateKey: { try MimiTailcatBridge.generatePrivateKey() },
        publicKey: { try MimiTailcatBridge.publicKey(privateKey: $0) }
    )
}

actor TailcatExperimentRuntime: TailcatExperimentRuntimeProtocol {
    private var proxy: MimiTailcatProxy?
    private var preparedProxies: [String: MimiTailcatProxy] = [:]

    func start(address: String, privateKey: String) async throws -> String {
        try Task.checkCancellation()
        try stop()
        let nextProxy = try MimiTailcatBridge.startProxy(
            address: address,
            privateKey: privateKey,
            remotePort: 8787
        )
        guard !Task.isCancelled else {
            try? nextProxy.close()
            throw CancellationError()
        }
        let endpoint = nextProxy.localEndpoint
        guard !endpoint.isEmpty else {
            try? nextProxy.close()
            throw URLError(.cannotConnectToHost)
        }
        proxy = nextProxy
        return endpoint
    }

    func prepare(address: String, privateKey: String) async throws -> String {
        try Task.checkCancellation()
        let nextProxy = try MimiTailcatBridge.startProxy(
            address: address,
            privateKey: privateKey,
            remotePort: 8787
        )
        guard !Task.isCancelled else {
            try? nextProxy.close()
            throw CancellationError()
        }
        let endpoint = nextProxy.localEndpoint
        guard !endpoint.isEmpty else {
            try? nextProxy.close()
            throw URLError(.cannotConnectToHost)
        }
        preparedProxies[endpoint] = nextProxy
        return endpoint
    }

    func activatePrepared(endpoint: String) throws {
        guard let nextProxy = preparedProxies.removeValue(forKey: endpoint) else {
            throw URLError(.cannotConnectToHost)
        }
        let previousProxy = proxy
        proxy = nextProxy
        try? previousProxy?.close()
    }

    func discardPrepared(endpoint: String) throws {
        guard let preparedProxy = preparedProxies.removeValue(forKey: endpoint) else { return }
        try preparedProxy.close()
    }

    func hasPrepared(endpoint: String) -> Bool {
        preparedProxies[endpoint] != nil
    }

    func discoPing() throws -> TailcatDiscoPingPayload {
        guard let proxy else { throw URLError(.notConnectedToInternet) }
        let raw = try proxy.discoPing(timeoutSeconds: 10)
        return try JSONDecoder().decode(TailcatDiscoPingPayload.self, from: Data(raw.utf8))
    }

    func stop() throws {
        guard let proxy else { return }
        self.proxy = nil
        try proxy.close()
    }

    func stop(ifCurrentEndpoint endpoint: String) throws {
        guard proxy?.localEndpoint == endpoint else { return }
        try stop()
    }
}

@MainActor
final class TailcatExperimentController: ObservableObject {
    static let enabledKey = "agentd.tailcatExperiment.enabled.v1"
    static let legacyAddressKey = "agentd.tailcatExperiment.address.v1"
    static let diagnosticsKey = "agentd.tailcatExperiment.diagnostics.v1"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var address: String
    @Published private(set) var publicKey = ""
    @Published private(set) var state: TailcatExperimentState
    @Published private(set) var diagnostics: [TailcatPathDiagnostic]

    private struct PendingPairing {
        let stableAddress: String
        let localEndpoint: String
        let previousEnabled: Bool
        let previousAddress: String
        let previousLegacyAddress: String?
        var targetProfileID: String?
        var previousProfileAddress: String?
    }

    private struct RoutePreparation {
        let id: UUID
        let task: Task<Result<String, Error>, Never>
    }

    private let defaults: UserDefaults
    private let tokenStore: TokenStore
    private let runtime: any TailcatExperimentRuntimeProtocol
    private let bridge: TailcatExperimentBridgeAdapter
    private var generation: UInt64 = 0
    private var preparationTask: RoutePreparation?
    private var pendingPairing: PendingPairing?

    init(
        appStore: AppStore,
        defaults: UserDefaults = .standard,
        tokenStore: TokenStore = TokenStore(),
        runtime: any TailcatExperimentRuntimeProtocol = TailcatExperimentRuntime(),
        bridge: TailcatExperimentBridgeAdapter = .live
    ) {
        let available = bridge.isAvailable
        let savedEnabled = defaults.bool(forKey: Self.enabledKey)
        var legacyAddress = (try? tokenStore.loadTailcatExperimentAddress()) ?? ""
        if legacyAddress.isEmpty,
           let legacyDefaultAddress = defaults.string(forKey: Self.legacyAddressKey),
           !legacyDefaultAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let migrated = legacyDefaultAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            try? tokenStore.saveTailcatExperimentAddress(migrated)
            legacyAddress = migrated
        }
        defaults.removeObject(forKey: Self.legacyAddressKey)
        var savedAddress = legacyAddress
        var profileRoute = appStore.activeConnectionProfile?.connectionRoute ?? .configured
        if let profileID = appStore.activeConnectionProfileID {
            let profileAddress = (try? tokenStore.loadTailcatAddress(profileID: profileID)) ?? ""
            var profileAddressReady = !profileAddress.isEmpty
            if !profileAddress.isEmpty {
                savedAddress = profileAddress
            } else if appStore.connectionProfiles.count == 1, !legacyAddress.isEmpty {
                do {
                    try tokenStore.saveTailcatAddress(legacyAddress, profileID: profileID)
                    let persisted = try tokenStore.loadTailcatAddress(profileID: profileID)
                    if persisted == legacyAddress {
                        savedAddress = persisted
                        profileAddressReady = true
                    }
                } catch {}
            }
            if savedEnabled, profileAddressReady, !savedAddress.isEmpty {
                try? appStore.setActiveConnectionProfileRoute(.tailcat)
                profileRoute = .tailcat
            }
            if profileAddressReady, appStore.connectionProfiles.count == 1 {
                try? tokenStore.deleteTailcatExperimentAddress()
                defaults.removeObject(forKey: Self.enabledKey)
            }
        }
        let initialEnabled = (appStore.activeConnectionProfileID == nil
            ? savedEnabled
            : profileRoute == .tailcat) && available
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.runtime = runtime
        self.bridge = bridge
        address = savedAddress
        diagnostics = Self.loadDiagnostics(defaults: defaults)
        isEnabled = initialEnabled
        if savedEnabled && !available {
            defaults.set(false, forKey: Self.enabledKey)
        }
        if !available {
            state = .unavailable
        } else if !initialEnabled {
            state = .disabled
        } else if savedAddress.isEmpty {
            state = .needsAddress
        } else {
            state = .starting
        }
    }

    var isAvailable: Bool { bridge.isAvailable }
    var lastDiagnostic: TailcatPathDiagnostic? { diagnostics.first }

    func loadPublicKey() {
        guard isAvailable, publicKey.isEmpty else { return }
        do {
            let privateKey = try loadOrCreatePrivateKey()
            publicKey = try bridge.publicKey(privateKey)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    // 兼容早期实验数据和测试入口。正式产品配对只从二维码写入地址。
    func setAddress(_ value: String) {
        address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty {
            try? tokenStore.deleteTailcatExperimentAddress()
        } else {
            try? tokenStore.saveTailcatExperimentAddress(address)
        }
        generation &+= 1
        if isEnabled {
            state = address.isEmpty ? .needsAddress : .starting
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, appStore: AppStore) async -> Bool {
        generation &+= 1
        if !enabled {
            isEnabled = false
            if appStore.activeConnectionProfileID == nil {
                defaults.set(false, forKey: Self.enabledKey)
            } else {
                defaults.removeObject(forKey: Self.enabledKey)
                try? appStore.setActiveConnectionProfileRoute(.configured)
            }
            pendingPairing = nil
            preparationTask?.task.cancel()
            preparationTask = nil
            try? await runtime.stop()
            appStore.setTailcatExperimentModeEnabled(false)
            state = isAvailable ? .disabled : .unavailable
            return true
        }
        guard isAvailable else {
            state = .unavailable
            return false
        }
        if let profileID = appStore.activeConnectionProfileID {
            address = ((try? tokenStore.loadTailcatAddress(profileID: profileID)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !address.isEmpty else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            state = .needsAddress
            return false
        }
        isEnabled = true
        if appStore.activeConnectionProfileID == nil {
            defaults.set(true, forKey: Self.enabledKey)
        }
        let ready = await prepareRoute(appStore: appStore)
        if ready {
            try? appStore.setActiveConnectionProfileRoute(.tailcat)
        }
        return ready
    }

    @discardableResult
    func prepareRoute(appStore: AppStore) async -> Bool {
        await prepareRoute(
            appStore: appStore,
            forceRestart: false,
            refreshPathDiagnosticAfterPreparation: true
        )
    }

    /// iOS 锁屏会挂起 Tailcat 的 DERP/WireGuard 状态，但旧 proxy 仍可能保留本地 listener。
    /// 真正经历后台后创建全新 Client，确保重新握手，再让 REST/WebSocket 恢复。
    @discardableResult
    func recoverRouteFromForeground(
        appStore: AppStore,
        refreshPathDiagnosticAfterPreparation: Bool = true
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isEnabled else { return true }
        if let inFlightPreparation = preparationTask {
            _ = await inFlightPreparation.task.value
            if preparationTask?.id == inFlightPreparation.id {
                preparationTask = nil
            }
        }
        guard !Task.isCancelled else { return false }
        generation &+= 1
        appStore.setTailcatExperimentEndpoint(nil)
        return await prepareRoute(
            appStore: appStore,
            forceRestart: true,
            refreshPathDiagnosticAfterPreparation: refreshPathDiagnosticAfterPreparation
        )
    }

    private func prepareRoute(
        appStore: AppStore,
        forceRestart: Bool,
        refreshPathDiagnosticAfterPreparation: Bool
    ) async -> Bool {
        appStore.setTailcatExperimentModeEnabled(isEnabled)
        guard isAvailable else {
            state = .unavailable
            return false
        }
        guard isEnabled else {
            state = .disabled
            return false
        }
        let capturedAddress = address
        guard !capturedAddress.isEmpty else {
            appStore.setTailcatExperimentEndpoint(nil)
            state = .needsAddress
            return false
        }
        if !forceRestart,
           case .connected(let endpoint) = state,
           appStore.tailcatExperimentEndpoint == endpoint {
            return true
        }

        let capturedGeneration = generation
        state = .starting
        var preparationID: UUID?
        do {
            let privateKey = try loadOrCreatePrivateKey()
            publicKey = try bridge.publicKey(privateKey)
            let preparation: RoutePreparation
            if let preparationTask {
                preparation = preparationTask
            } else {
                let task = Task<Result<String, Error>, Never> {
                    do {
                        return .success(try await runtime.start(
                            address: capturedAddress,
                            privateKey: privateKey
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
                preparation = RoutePreparation(id: UUID(), task: task)
                preparationTask = preparation
            }
            preparationID = preparation.id
            let result = await preparation.task.value
            if preparationTask?.id == preparation.id {
                preparationTask = nil
            }
            let endpoint = try result.get()
            guard !Task.isCancelled,
                  capturedGeneration == generation,
                  isEnabled,
                  capturedAddress == address else {
                try? await runtime.stop(ifCurrentEndpoint: endpoint)
                return false
            }
            appStore.setTailcatExperimentEndpoint(endpoint)
            state = .connected(endpoint: endpoint)
            if refreshPathDiagnosticAfterPreparation {
                Task { await refreshPathDiagnostic(appStore: appStore) }
            }
            return true
        } catch {
            if let preparationID, preparationTask?.id == preparationID {
                preparationTask = nil
            }
            guard !Task.isCancelled, capturedGeneration == generation else { return false }
            appStore.setTailcatExperimentEndpoint(nil)
            state = .failed(message: error.localizedDescription)
            return false
        }
    }

    func preparePairingURL(
        _ url: URL,
        appStore: AppStore,
        profileTarget: PreparedConnectionProfileTarget
    ) async throws -> PreparedConnectionSettings {
        guard let link = try TailcatPairingLink.parse(url) else {
            throw PairingLinkError.unsupportedURL
        }
        guard isAvailable else {
            throw PairingLinkError.unsupportedURL
        }
        let resolvedProfileTarget: PreparedConnectionProfileTarget
        if case .currentOrNew(let displayName) = profileTarget,
           appStore.activeConnectionProfileID == nil {
            resolvedProfileTarget = .newProfile(id: UUID().uuidString, displayName: displayName ?? "")
        } else {
            resolvedProfileTarget = profileTarget
        }
        let previousEnabled = isEnabled
        let previousAddress = address
        let previousLegacyAddress = (try? tokenStore.loadTailcatExperimentAddress()) ?? ""
        var stableCandidateEndpoint: String?
        state = .starting
        generation &+= 1
        do {
            let privateKey = try loadOrCreatePrivateKey()
            let clientKey = try bridge.publicKey(privateKey)
            publicKey = clientKey
            let pairingEndpoint = try await runtime.prepare(
                address: link.pairAddress,
                privateKey: privateKey
            )
            let response: PairingClaimResponse
            do {
                response = try await AgentAPIClient(endpoint: pairingEndpoint, token: "")
                    .claimPairing(link.ticket.claimRequest(tailcatClientKey: clientKey))
            } catch {
                try? await runtime.discardPrepared(endpoint: pairingEndpoint)
                throw error
            }
            try? await runtime.discardPrepared(endpoint: pairingEndpoint)
            let stableAddress = response.tailcatAddress?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !stableAddress.isEmpty else {
                throw PairingLinkError.missingTailcatAddress
            }
            let stableEndpoint = try await runtime.prepare(
                address: stableAddress,
                privateKey: privateKey
            )
            stableCandidateEndpoint = stableEndpoint
            let canonicalEndpoint = try AppStore.validatedEndpoint(
                response.endpoint.isEmpty ? link.ticket.endpoint : response.endpoint
            )
            let prepared = try await appStore.prepareRoutedConnectionSettings(
                endpoint: canonicalEndpoint,
                activeEndpoint: stableEndpoint,
                tailcatAddress: stableAddress,
                token: response.token,
                profileTarget: resolvedProfileTarget
            )
            pendingPairing = PendingPairing(
                stableAddress: stableAddress,
                localEndpoint: stableEndpoint,
                previousEnabled: previousEnabled,
                previousAddress: previousAddress,
                previousLegacyAddress: previousLegacyAddress,
                targetProfileID: nil,
                previousProfileAddress: nil
            )
            return prepared
        } catch {
            if let stableCandidateEndpoint {
                try? await runtime.discardPrepared(endpoint: stableCandidateEndpoint)
            }
            await restoreAfterPairingFailure(
                previousEnabled: previousEnabled,
                previousAddress: previousAddress,
                previousLegacyAddress: previousLegacyAddress,
                appStore: appStore
            )
            throw error
        }
    }

    func prepareConnectionProfileSwitch(
        id: String,
        appStore: AppStore
    ) async throws -> PreparedConnectionSettings {
        guard let profile = appStore.connectionProfiles.first(where: { $0.id == id }) else {
            throw ConnectionProfileError.notFound
        }
        guard profile.connectionRoute == .tailcat else {
            return try await appStore.prepareConnectionProfileSwitch(id: id)
        }
        let targetAddress = try tokenStore.loadTailcatAddress(profileID: id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetAddress.isEmpty else {
            throw PairingLinkError.missingTailcatAddress
        }
        let previousEnabled = isEnabled
        let previousAddress = address
        var candidateEndpoint: String?
        generation &+= 1
        state = .starting
        do {
            let endpoint = try await runtime.prepare(
                address: targetAddress,
                privateKey: try loadOrCreatePrivateKey()
            )
            candidateEndpoint = endpoint
            let prepared = try await appStore.prepareConnectionProfileSwitch(
                id: id,
                activeEndpoint: endpoint,
                tailcatAddress: targetAddress
            )
            pendingPairing = PendingPairing(
                stableAddress: targetAddress,
                localEndpoint: endpoint,
                previousEnabled: previousEnabled,
                previousAddress: previousAddress,
                previousLegacyAddress: nil,
                targetProfileID: nil,
                previousProfileAddress: nil
            )
            return prepared
        } catch {
            if let candidateEndpoint {
                try? await runtime.discardPrepared(endpoint: candidateEndpoint)
            }
            await restoreAfterPairingFailure(
                previousEnabled: previousEnabled,
                previousAddress: previousAddress,
                previousLegacyAddress: nil,
                appStore: appStore
            )
            throw error
        }
    }

    func stagePreparedRouteIfNeeded(_ prepared: PreparedConnectionSettings, appStore: AppStore) async throws {
        guard case .tailcat = prepared.route,
              var pendingPairing,
              AgentAPIClient.normalizedEndpoint(pendingPairing.localEndpoint) ==
                AgentAPIClient.normalizedEndpoint(prepared.activeEndpoint)
        else { return }
        guard await runtime.hasPrepared(endpoint: pendingPairing.localEndpoint) else {
            throw URLError(.cannotConnectToHost)
        }
        let profileID: String
        switch prepared.profileTarget {
        case .existingProfile(let id), .newProfile(let id, _):
            profileID = id
        case .currentOrNew:
            guard let activeProfileID = appStore.activeConnectionProfileID else {
                throw ConnectionProfileError.notFound
            }
            profileID = activeProfileID
        }
        let previousAddress = try tokenStore.loadTailcatAddress(profileID: profileID)
        do {
            try tokenStore.saveTailcatAddress(pendingPairing.stableAddress, profileID: profileID)
            guard try tokenStore.loadTailcatAddress(profileID: profileID) == pendingPairing.stableAddress else {
                throw URLError(.cannotWriteToFile)
            }
        } catch {
            try? restoreProfileAddress(previousAddress, profileID: profileID)
            throw error
        }
        pendingPairing.targetProfileID = profileID
        pendingPairing.previousProfileAddress = previousAddress
        self.pendingPairing = pendingPairing
    }

    func commitPreparedRouteIfNeeded(_ prepared: PreparedConnectionSettings, appStore: AppStore) async {
        guard case .tailcat = prepared.route else {
            pendingPairing = nil
            generation &+= 1
            try? await runtime.stop()
            isEnabled = false
            defaults.removeObject(forKey: Self.enabledKey)
            if let profileID = appStore.activeConnectionProfileID {
                address = ((try? tokenStore.loadTailcatAddress(profileID: profileID)) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                address = ""
            }
            appStore.setTailcatExperimentModeEnabled(false)
            state = isAvailable ? .disabled : .unavailable
            return
        }
        guard let pendingPairing,
              AgentAPIClient.normalizedEndpoint(pendingPairing.localEndpoint) ==
                AgentAPIClient.normalizedEndpoint(prepared.activeEndpoint)
        else { return }
        self.pendingPairing = nil
        do {
            try await runtime.activatePrepared(endpoint: pendingPairing.localEndpoint)
        } catch {
            state = .failed(message: error.localizedDescription)
            return
        }
        let legacyWasAssigned = pendingPairing.previousLegacyAddress == pendingPairing.stableAddress
        if pendingPairing.targetProfileID != nil,
           appStore.connectionProfiles.count == 1 || legacyWasAssigned {
            try? tokenStore.deleteTailcatExperimentAddress()
            defaults.removeObject(forKey: Self.enabledKey)
        }
        address = pendingPairing.stableAddress
        isEnabled = true
        appStore.setTailcatExperimentEndpoint(pendingPairing.localEndpoint)
        appStore.setTailcatExperimentModeEnabled(true)
        state = .connected(endpoint: pendingPairing.localEndpoint)
        Task { await refreshPathDiagnostic(appStore: appStore) }
    }

    func discardPreparedRouteIfNeeded(_ prepared: PreparedConnectionSettings?, appStore: AppStore) async {
        guard let pendingPairing else { return }
        if let prepared,
           AgentAPIClient.normalizedEndpoint(pendingPairing.localEndpoint) !=
            AgentAPIClient.normalizedEndpoint(prepared.activeEndpoint) {
            return
        }
        self.pendingPairing = nil
        try? await runtime.discardPrepared(endpoint: pendingPairing.localEndpoint)
        if let profileID = pendingPairing.targetProfileID,
           let previousProfileAddress = pendingPairing.previousProfileAddress {
            try? restoreProfileAddress(previousProfileAddress, profileID: profileID)
        }
        await restoreAfterPairingFailure(
            previousEnabled: pendingPairing.previousEnabled,
            previousAddress: pendingPairing.previousAddress,
            previousLegacyAddress: pendingPairing.previousLegacyAddress,
            appStore: appStore
        )
    }

    func deleteProfileRoute(profileID: String) throws {
        try tokenStore.deleteTailcatAddress(profileID: profileID)
    }

    func refreshPathDiagnostic(appStore: AppStore? = nil) async {
        guard isEnabled else { return }
        var path = "failed"
        var latencyMillis: Int?
        var derpRegionCode: String?
        var pathSucceeded = false
        do {
            let result = try await runtime.discoPing()
            path = result.path
            latencyMillis = result.latencyMillis
            derpRegionCode = result.derpRegionCode
            pathSucceeded = true
        } catch {}

        var requestLatencyMillis: Int?
        var requestSucceeded: Bool?
        if let appStore, appStore.isConfigured {
            let startedAt = Date()
            do {
                _ = try await appStore.client().health()
                requestLatencyMillis = max(
                    0,
                    Int((Date().timeIntervalSince(startedAt) * 1_000).rounded())
                )
                requestSucceeded = true
            } catch {
                requestSucceeded = false
            }
        }
        let diagnostic = TailcatPathDiagnostic(
            id: UUID(),
            checkedAt: Date(),
            path: path,
            latencyMillis: latencyMillis,
            derpRegionCode: derpRegionCode,
            succeeded: pathSucceeded,
            requestLatencyMillis: requestLatencyMillis,
            requestSucceeded: requestSucceeded
        )
        diagnostics.insert(diagnostic, at: 0)
        diagnostics = Array(diagnostics.prefix(10))
        if let encoded = try? JSONEncoder().encode(diagnostics) {
            defaults.set(encoded, forKey: Self.diagnosticsKey)
        }
    }

    var redactedDiagnosticsText: String {
        diagnostics.map { item in
            let request = item.requestSummary.map { " · \($0)" } ?? ""
            return "\(item.checkedAt.formatted(date: .numeric, time: .standard)) · \(item.summary)\(request)"
        }.joined(separator: "\n")
    }

    private func restoreAfterPairingFailure(
        previousEnabled: Bool,
        previousAddress: String,
        previousLegacyAddress: String?,
        appStore: AppStore
    ) async {
        if let previousLegacyAddress {
            if previousLegacyAddress.isEmpty {
                try? tokenStore.deleteTailcatExperimentAddress()
            } else {
                try? tokenStore.saveTailcatExperimentAddress(previousLegacyAddress)
            }
        }
        address = previousAddress
        isEnabled = previousEnabled
        if previousLegacyAddress != nil {
            defaults.set(previousEnabled, forKey: Self.enabledKey)
        } else {
            defaults.removeObject(forKey: Self.enabledKey)
        }
        guard previousEnabled, !previousAddress.isEmpty else {
            appStore.setTailcatExperimentModeEnabled(false)
            state = isAvailable ? .disabled : .unavailable
            return
        }
        appStore.setTailcatExperimentModeEnabled(true)
        state = appStore.tailcatExperimentEndpoint.map { .connected(endpoint: $0) } ?? .starting
    }

    private func loadOrCreatePrivateKey() throws -> String {
        let saved = try tokenStore.loadTailcatExperimentPrivateKey()
        if !saved.isEmpty { return saved }
        let privateKey = try bridge.generatePrivateKey()
        try tokenStore.saveTailcatExperimentPrivateKey(privateKey)
        return privateKey
    }

    private func restoreProfileAddress(_ address: String, profileID: String) throws {
        if address.isEmpty {
            try tokenStore.deleteTailcatAddress(profileID: profileID)
        } else {
            try tokenStore.saveTailcatAddress(address, profileID: profileID)
        }
    }

    private static func loadDiagnostics(defaults: UserDefaults) -> [TailcatPathDiagnostic] {
        guard let data = defaults.data(forKey: diagnosticsKey),
              let decoded = try? JSONDecoder().decode([TailcatPathDiagnostic].self, from: data)
        else { return [] }
        return Array(decoded.prefix(10))
    }
}
