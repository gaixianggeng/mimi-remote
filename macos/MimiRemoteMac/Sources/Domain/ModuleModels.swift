import Foundation

enum HostModuleID: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, agy, deepseek, tailscale, tailcat, lan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .agy: "Antigravity"
        case .deepseek: "DeepSeek Harness"
        case .tailscale: "Tailscale"
        case .tailcat: "内置连接（Tailcat）"
        case .lan: "局域网"
        }
    }
    var symbol: String {
        switch self {
        case .codex: "terminal"
        case .claude: "text.bubble"
        case .agy: "wand.and.stars"
        case .deepseek: "sparkles"
        case .tailscale: "network"
        case .tailcat: "antenna.radiowaves.left.and.right"
        case .lan: "wifi"
        }
    }
    var isAgent: Bool { self == .codex || self == .claude || self == .agy || self == .deepseek }
    var network: PairingNetwork? {
        switch self {
        case .tailscale: .tailscale
        case .tailcat: .tailcat
        case .lan: .localNetwork
        default: nil
        }
    }
}

enum HostModuleGroup: CaseIterable {
    case agents, connections
    var title: String { self == .agents ? "AI 编程助手" : "连接方式" }
    var modules: [HostModuleID] {
        self == .agents ? [.codex, .claude, .agy, .deepseek] : [.tailscale, .lan, .tailcat]
    }
}

enum AgentModuleStatusState: String, Codable, Equatable, Sendable {
    case available, unsupported, unavailable
}

struct AgentModuleStatus: Codable, Equatable, Sendable {
    let codexEnabled: Bool
    let claudeEnabled: Bool
    let agyEnabled: Bool
    let tailscaleEnabled: Bool
    let lanEnabled: Bool
    let tailscaleAvailable: Bool
    let lanAvailable: Bool
    enum CodingKeys: String, CodingKey {
        case codexEnabled = "codex_enabled"
        case claudeEnabled = "claude_enabled"
        case agyEnabled = "agy_enabled"
        case tailscaleEnabled = "tailscale_enabled"
        case lanEnabled = "lan_enabled"
        case tailscaleAvailable = "tailscale_available"
        case lanAvailable = "lan_available"
    }

    init(
        codexEnabled: Bool,
        claudeEnabled: Bool,
        agyEnabled: Bool = false,
        tailscaleEnabled: Bool,
        lanEnabled: Bool,
        tailscaleAvailable: Bool,
        lanAvailable: Bool
    ) {
        self.codexEnabled = codexEnabled
        self.claudeEnabled = claudeEnabled
        self.agyEnabled = agyEnabled
        self.tailscaleEnabled = tailscaleEnabled
        self.lanEnabled = lanEnabled
        self.tailscaleAvailable = tailscaleAvailable
        self.lanAvailable = lanAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codexEnabled = try container.decode(Bool.self, forKey: .codexEnabled)
        claudeEnabled = try container.decode(Bool.self, forKey: .claudeEnabled)
        agyEnabled = try container.decodeIfPresent(Bool.self, forKey: .agyEnabled) ?? false
        tailscaleEnabled = try container.decode(Bool.self, forKey: .tailscaleEnabled)
        lanEnabled = try container.decode(Bool.self, forKey: .lanEnabled)
        tailscaleAvailable = try container.decode(Bool.self, forKey: .tailscaleAvailable)
        lanAvailable = try container.decode(Bool.self, forKey: .lanAvailable)
    }
}

struct NetworkModuleState: Codable, Equatable, Sendable {
    let allowLAN: Bool
    let allowTailscale: Bool?
    enum CodingKeys: String, CodingKey {
        case allowLAN = "allow_lan"
        case allowTailscale = "allow_tailscale"
    }
}

struct NetworkConfigurationResult: Codable, Equatable, Sendable {
    let lanEnabled: Bool
    let changed: Bool
    let restartRequired: Bool
    let tailscaleEnabled: Bool?
    let previous: NetworkModuleState?
    let applied: NetworkModuleState?
    enum CodingKeys: String, CodingKey {
        case lanEnabled = "lan_enabled"
        case changed
        case restartRequired = "restart_required"
        case tailscaleEnabled = "tailscale_enabled"
        case previous, applied
    }
    init(lanEnabled: Bool, changed: Bool, restartRequired: Bool,
         tailscaleEnabled: Bool? = nil, previous: NetworkModuleState? = nil,
         applied: NetworkModuleState? = nil) {
        self.lanEnabled = lanEnabled
        self.changed = changed
        self.restartRequired = restartRequired
        self.tailscaleEnabled = tailscaleEnabled
        self.previous = previous
        self.applied = applied
    }
}

struct CodexModuleState: Codable, Equatable, Sendable {
    let enabled: Bool?
    let activation: String?
}

struct CodexConfigurationResult: Codable, Equatable, Sendable {
    let enabled: Bool
    let available: Bool
    let changed: Bool
    let restartRequired: Bool
    let reason: String
    let message: String
    let previous: CodexModuleState
    let applied: CodexModuleState
    enum CodingKeys: String, CodingKey {
        case enabled = "codex_enabled"
        case available, changed
        case restartRequired = "restart_required"
        case reason, message, previous, applied
    }
}
