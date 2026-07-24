import Foundation

enum PairingNetwork: String, CaseIterable, Identifiable, Sendable, Codable {
    case automatic = "auto"
    case tailscale
    case localNetwork = "lan"

    var id: String { rawValue }

    static func inferred(from endpoint: String) -> PairingNetwork {
        guard let host = URLComponents(string: endpoint)?.host else {
            return .tailscale
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return .tailscale
        }
        if octets[0] == 100, (64...127).contains(octets[1]) {
            return .tailscale
        }
        if octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
        {
            return .localNetwork
        }
        return .tailscale
    }
}

struct PairingInfo: Codable, Equatable, Sendable {
    let endpoint: String
    let network: PairingNetwork
    let pairURL: String
    let expiresAt: String
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case endpoint
        case network
        case pairURL = "pair_url"
        case expiresAt = "pair_expires_at"
        case warnings
    }

    init(
        endpoint: String,
        network: PairingNetwork? = nil,
        pairURL: String,
        expiresAt: String,
        warnings: [String]
    ) {
        self.endpoint = endpoint
        self.network = network ?? PairingNetwork.inferred(from: endpoint)
        self.pairURL = pairURL
        self.expiresAt = expiresAt
        self.warnings = warnings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        network = try container.decodeIfPresent(PairingNetwork.self, forKey: .network)
            ?? PairingNetwork.inferred(from: endpoint)
        pairURL = try container.decode(String.self, forKey: .pairURL)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
        // agentd 会在没有警告时省略 warnings；客户端统一成空数组，简化视图状态。
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

struct NetworkConfigurationResult: Codable, Equatable, Sendable {
    let lanEnabled: Bool
    let changed: Bool
    let restartRequired: Bool

    enum CodingKeys: String, CodingKey {
        case lanEnabled = "lan_enabled"
        case changed
        case restartRequired = "restart_required"
    }
}

struct AgentCheck: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let ok: Bool
    let level: String
    let message: String
    let fix: String?

    var id: String { name }
    var isWarning: Bool { level.caseInsensitiveCompare("warning") == .orderedSame }
}

struct AgentDoctorResults: Codable, Equatable, Sendable {
    let ok: Bool
    let version: String
    let listen: String
    let checks: [AgentCheck]
}

struct DoctorFixResults: Codable, Equatable, Sendable {
    let fixes: [String]
    let results: AgentDoctorResults
}

struct AgentStatus: Codable, Equatable, Sendable {
    let processOK: Bool
    let serviceOK: Bool
    let processError: String?
    let serviceError: String?
    let version: String
    let endpoint: String
    let configPath: String
    let projects: Int
    let doctorOK: Bool
    let doctor: AgentDoctorResults
    let pairExpires: String?

    enum CodingKeys: String, CodingKey {
        case processOK = "process_ok"
        case serviceOK = "service_ok"
        case processError = "process_error"
        case serviceError = "service_error"
        case version
        case endpoint
        case configPath = "config_path"
        case projects
        case doctorOK = "doctor_ok"
        case doctor
        case pairExpires = "pair_expires"
    }
}

enum HostLifecycleState: Equatable, Sendable {
    case loading
    case notConfigured
    case migrationRequired
    case starting
    case ready
    case degraded(String)
    case stopped
    case failed(String)

    var title: String {
        switch self {
        case .loading: "正在检查"
        case .notConfigured: "需要完成设置"
        case .migrationRequired: "等待接管旧服务"
        case .starting: "正在启动"
        case .ready: "服务可用"
        case .degraded: "需要处理"
        case .stopped: "服务已停止"
        case .failed: "启动失败"
        }
    }

    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .loading, .starting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .notConfigured: "slider.horizontal.3"
        case .migrationRequired: "arrow.triangle.2.circlepath"
        case .degraded: "exclamationmark.triangle.fill"
        case .stopped: "pause.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var detail: String? {
        switch self {
        case .degraded(let message), .failed(let message): message
        default: nil
        }
    }
}

enum ServiceRegistrationState: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

enum ServiceOwner: Equatable, Sendable {
    case none
    case macApp
    case homebrew
}
