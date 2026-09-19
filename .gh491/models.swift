
// Module management values contain no credentials. The status command reports
// disk intent; runtimeStatus.modules is the configuration of the live process.
enum HostModule: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, tailscale, lan, tailcat
    var id: String { rawValue }
    var isAgent: Bool { self == .codex || self == .claude }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .tailscale: "Tailscale"
        case .lan: "局域网"
        case .tailcat: "Tailcat"
        }
    }
    var symbol: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        case .tailscale: "network"
        case .lan: "wifi"
        case .tailcat: "point.3.connected.trianglepath.dotted"
        }
    }
    var network: PairingNetwork? {
        switch self {
        case .tailscale: .tailscale
        case .lan: .localNetwork
        case .tailcat: .tailcat
        default: nil
        }
    }
}

struct ModuleConfiguration: Codable, Equatable, Sendable {
    let codexEnabled: Bool
    let claudeEnabled: Bool
    let tailscaleEnabled: Bool
    let lanEnabled: Bool
    let tailcatEnabled: Bool
    enum CodingKeys: String, CodingKey {
        case codexEnabled = "codex_enabled"
        case claudeEnabled = "claude_enabled"
        case tailscaleEnabled = "tailscale_enabled"
        case lanEnabled = "lan_enabled"
        case tailcatEnabled = "tailcat_enabled"
    }
    func isEnabled(_ module: HostModule) -> Bool {
        switch module {
        case .codex: codexEnabled
        case .claude: claudeEnabled
        case .tailscale: tailscaleEnabled
        case .lan: lanEnabled
        case .tailcat: tailcatEnabled
        }
    }
    // Tailcat has its own authenticated hot-control path and status endpoint.
    func matchesResident(_ other: Self) -> Bool {
        codexEnabled == other.codexEnabled && claudeEnabled == other.claudeEnabled
            && tailscaleEnabled == other.tailscaleEnabled && lanEnabled == other.lanEnabled
    }
}

struct ModulePreferences: Codable, Equatable, Sendable {
    let codex: Bool?
    let claude: Bool?
    let claudeActivation: String?
    let lan: Bool?
    let tailscale: Bool?
    enum CodingKeys: String, CodingKey {
        case codex, claude, lan, tailscale
        case claudeActivation = "claude_activation"
    }
}

struct ModuleChange: Codable, Equatable, Sendable {
    let module: String
    let configuration: ModuleConfiguration
    let previous: ModulePreferences
    let revision: String
    let changed: Bool
    let restartRequired: Bool
    enum CodingKeys: String, CodingKey {
        case module, configuration, previous, revision, changed
        case restartRequired = "restart_required"
    }
}

struct ConnectionModuleStatus: Codable, Equatable, Sendable {
    let id: String
    let enabled: Bool
    let available: Bool
    let endpoint: String?
    let reason: String?
}

struct ModuleUndo: Sendable {
    let id = UUID()
    let module: HostModule
    let change: ModuleChange?
    let expiresAt = Date().addingTimeInterval(6)
}
