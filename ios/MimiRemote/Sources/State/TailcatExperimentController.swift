import Foundation

enum TailcatExperimentState: Equatable {
    case disabled
    case needsAddress
    case starting
    case connected(endpoint: String)
    case failed(message: String)
    case unavailable
}

actor TailcatExperimentRuntime {
    private var proxy: MimiTailcatProxy?

    func start(address: String, privateKey: String) throws -> String {
        try stop()
        let nextProxy = try MimiTailcatBridge.startProxy(
            address: address,
            privateKey: privateKey,
            remotePort: 8787
        )
        let endpoint = nextProxy.localEndpoint
        guard !endpoint.isEmpty else {
            try? nextProxy.close()
            throw URLError(.cannotConnectToHost)
        }
        proxy = nextProxy
        return endpoint
    }

    func stop() throws {
        guard let proxy else { return }
        self.proxy = nil
        try proxy.close()
    }
}

@MainActor
final class TailcatExperimentController: ObservableObject {
    static let enabledKey = "agentd.tailcatExperiment.enabled.v1"
    static let addressKey = "agentd.tailcatExperiment.address.v1"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var address: String
    @Published private(set) var publicKey = ""
    @Published private(set) var state: TailcatExperimentState

    private let defaults: UserDefaults
    private let tokenStore: TokenStore
    private let runtime = TailcatExperimentRuntime()
    private var generation: UInt64 = 0
    private var preparationTask: Task<Result<String, Error>, Never>?

    init(defaults: UserDefaults = .standard, tokenStore: TokenStore = TokenStore()) {
        let available = MimiTailcatBridge.isAvailable
        let savedEnabled = defaults.bool(forKey: Self.enabledKey)
        let initialEnabled = savedEnabled && available
        let initialAddress = defaults.string(forKey: Self.addressKey) ?? ""
        self.defaults = defaults
        self.tokenStore = tokenStore
        isEnabled = initialEnabled
        address = initialAddress
        if savedEnabled && !available {
            defaults.set(false, forKey: Self.enabledKey)
        }
        if !available {
            state = .unavailable
        } else if !initialEnabled {
            state = .disabled
        } else if initialAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .needsAddress
        } else {
            state = .starting
        }
    }

    var isAvailable: Bool {
        MimiTailcatBridge.isAvailable
    }

    func loadPublicKey() {
        guard isAvailable, publicKey.isEmpty else { return }
        do {
            let privateKey = try loadOrCreatePrivateKey()
            publicKey = try MimiTailcatBridge.publicKey(privateKey: privateKey)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    func setAddress(_ value: String) {
        address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(address, forKey: Self.addressKey)
        generation &+= 1
        if isEnabled {
            state = address.isEmpty ? .needsAddress : .starting
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, appStore: AppStore) async -> Bool {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        generation &+= 1
        appStore.setTailcatExperimentModeEnabled(enabled)
        if !enabled {
            try? await runtime.stop()
            state = isAvailable ? .disabled : .unavailable
            return true
        }
        return await prepareRoute(appStore: appStore)
    }

    @discardableResult
    func prepareRoute(appStore: AppStore) async -> Bool {
        appStore.setTailcatExperimentModeEnabled(isEnabled)
        guard isAvailable else {
            state = .unavailable
            return false
        }
        guard isEnabled else {
            state = .disabled
            return false
        }
        let capturedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capturedAddress.isEmpty else {
            appStore.setTailcatExperimentEndpoint(nil)
            state = .needsAddress
            return false
        }
        if case .connected(let endpoint) = state,
           appStore.tailcatExperimentEndpoint == endpoint {
            return true
        }

        let capturedGeneration = generation
        state = .starting
        do {
            let privateKey = try loadOrCreatePrivateKey()
            publicKey = try MimiTailcatBridge.publicKey(privateKey: privateKey)
            let task: Task<Result<String, Error>, Never>
            if let preparationTask {
                task = preparationTask
            } else {
                task = Task {
                    do {
                        return .success(try await runtime.start(
                            address: capturedAddress,
                            privateKey: privateKey
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
                preparationTask = task
            }
            let endpoint = try await task.value.get()
            preparationTask = nil
            guard capturedGeneration == generation, isEnabled, capturedAddress == address else {
                try? await runtime.stop()
                return false
            }
            appStore.setTailcatExperimentEndpoint(endpoint)
            state = .connected(endpoint: endpoint)
            return true
        } catch {
            preparationTask = nil
            appStore.setTailcatExperimentEndpoint(nil)
            state = .failed(message: error.localizedDescription)
            return false
        }
    }

    private func loadOrCreatePrivateKey() throws -> String {
        let saved = try tokenStore.loadTailcatExperimentPrivateKey()
        if !saved.isEmpty {
            return saved
        }
        let privateKey = try MimiTailcatBridge.generatePrivateKey()
        try tokenStore.saveTailcatExperimentPrivateKey(privateKey)
        return privateKey
    }
}
