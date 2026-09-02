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
        defaults: UserDefaults = .standard,
        tokenStore: TokenStore = TokenStore(),
        runtime: any TailcatExperimentRuntimeProtocol = TailcatExperimentRuntime(),
        bridge: TailcatExperimentBridgeAdapter = .live
    ) {
        let available = bridge.isAvailable
        let savedEnabled = defaults.bool(forKey: Self.enabledKey)
        var savedAddress = (try? tokenStore.loadTailcatExperimentAddress()) ?? ""
        if savedAddress.isEmpty,
           let legacyAddress = defaults.string(forKey: Self.legacyAddressKey),
           !legacyAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            savedAddress = legacyAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            try? tokenStore.saveTailcatExperimentAddress(savedAddress)
        }
        defaults.removeObject(forKey: Self.legacyAddressKey)
        let initialEnabled = savedEnabled && available
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
            defaults.set(false, forKey: Self.enabledKey)
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
        guard !address.isEmpty else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            state = .needsAddress
            return false
        }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        return await prepareRoute(appStore: appStore)
    }

    @discardableResult
    func prepareRoute(appStore: AppStore) async -> Bool {
        await prepareRoute(appStore: appStore, forceRestart: false)
    }

    /// iOS 锁屏会挂起 Tailcat 的 DERP/WireGuard 状态，但旧 proxy 仍可能保留本地 listener。
    /// 真正经历后台后创建全新 Client，确保重新握手，再让 REST/WebSocket 恢复。
    @discardableResult
    func recoverRouteFromForeground(appStore: AppStore) async -> Bool {
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
        return await prepareRoute(appStore: appStore, forceRestart: true)
    }

    private func prepareRoute(appStore: AppStore, forceRestart: Bool) async -> Bool {
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
            Task { await refreshPathDiagnostic(appStore: appStore) }
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
        let previousEnabled = isEnabled
        let previousAddress = address
        state = .starting
        generation &+= 1
        do {
            let privateKey = try loadOrCreatePrivateKey()
            let clientKey = try bridge.publicKey(privateKey)
            publicKey = clientKey
            let pairingEndpoint = try await runtime.start(
                address: link.pairAddress,
                privateKey: privateKey
            )
            let response = try await AgentAPIClient(endpoint: pairingEndpoint, token: "")
                .claimPairing(link.ticket.claimRequest(tailcatClientKey: clientKey))
            let stableAddress = response.tailcatAddress?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !stableAddress.isEmpty else {
                throw PairingLinkError.missingTailcatAddress
            }
            let stableEndpoint = try await runtime.start(
                address: stableAddress,
                privateKey: privateKey
            )
            let canonicalEndpoint = try AppStore.validatedEndpoint(
                response.endpoint.isEmpty ? link.ticket.endpoint : response.endpoint
            )
            let prepared = try await appStore.prepareRoutedConnectionSettings(
                endpoint: canonicalEndpoint,
                activeEndpoint: stableEndpoint,
                token: response.token,
                profileTarget: profileTarget
            )
            try tokenStore.saveTailcatExperimentAddress(stableAddress)
            pendingPairing = PendingPairing(
                stableAddress: stableAddress,
                localEndpoint: stableEndpoint,
                previousEnabled: previousEnabled,
                previousAddress: previousAddress
            )
            return prepared
        } catch {
            await restoreAfterPairingFailure(
                previousEnabled: previousEnabled,
                previousAddress: previousAddress,
                appStore: appStore
            )
            throw error
        }
    }

    func commitPreparedRouteIfNeeded(_ prepared: PreparedConnectionSettings, appStore: AppStore) {
        guard let pendingPairing,
              AgentAPIClient.normalizedEndpoint(pendingPairing.localEndpoint) ==
                AgentAPIClient.normalizedEndpoint(prepared.activeEndpoint)
        else { return }
        self.pendingPairing = nil
        address = pendingPairing.stableAddress
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
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
        await restoreAfterPairingFailure(
            previousEnabled: pendingPairing.previousEnabled,
            previousAddress: pendingPairing.previousAddress,
            appStore: appStore
        )
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
        appStore: AppStore
    ) async {
        if previousAddress.isEmpty {
            try? tokenStore.deleteTailcatExperimentAddress()
        } else {
            try? tokenStore.saveTailcatExperimentAddress(previousAddress)
        }
        address = previousAddress
        isEnabled = previousEnabled
        defaults.set(previousEnabled, forKey: Self.enabledKey)
        guard previousEnabled, !previousAddress.isEmpty else {
            try? await runtime.stop()
            appStore.setTailcatExperimentModeEnabled(false)
            state = isAvailable ? .disabled : .unavailable
            return
        }
        do {
            let endpoint = try await runtime.start(
                address: previousAddress,
                privateKey: try loadOrCreatePrivateKey()
            )
            appStore.setTailcatExperimentEndpoint(endpoint)
            appStore.setTailcatExperimentModeEnabled(true)
            state = .connected(endpoint: endpoint)
        } catch {
            appStore.setTailcatExperimentEndpoint(nil)
            appStore.setTailcatExperimentModeEnabled(true)
            state = .failed(message: error.localizedDescription)
        }
    }

    private func loadOrCreatePrivateKey() throws -> String {
        let saved = try tokenStore.loadTailcatExperimentPrivateKey()
        if !saved.isEmpty { return saved }
        let privateKey = try bridge.generatePrivateKey()
        try tokenStore.saveTailcatExperimentPrivateKey(privateKey)
        return privateKey
    }

    private static func loadDiagnostics(defaults: UserDefaults) -> [TailcatPathDiagnostic] {
        guard let data = defaults.data(forKey: diagnosticsKey),
              let decoded = try? JSONDecoder().decode([TailcatPathDiagnostic].self, from: data)
        else { return [] }
        return Array(decoded.prefix(10))
    }
}
