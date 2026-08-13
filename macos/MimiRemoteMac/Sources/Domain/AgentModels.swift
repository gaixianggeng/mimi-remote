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
    let tailscaleDNSName: String?
    let tailscaleDeviceName: String?
    let pairURL: String
    let expiresAt: String
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case endpoint
        case network
        case tailscaleDNSName = "tailscale_dns_name"
        case tailscaleDeviceName = "tailscale_device_name"
        case pairURL = "pair_url"
        case expiresAt = "pair_expires_at"
        case warnings
    }

    init(
        endpoint: String,
        network: PairingNetwork? = nil,
        tailscaleDNSName: String? = nil,
        tailscaleDeviceName: String? = nil,
        pairURL: String,
        expiresAt: String,
        warnings: [String]
    ) {
        self.endpoint = endpoint
        self.network = network ?? PairingNetwork.inferred(from: endpoint)
        self.tailscaleDNSName = tailscaleDNSName
        self.tailscaleDeviceName = tailscaleDeviceName
        self.pairURL = pairURL
        self.expiresAt = expiresAt
        self.warnings = warnings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        network = try container.decodeIfPresent(PairingNetwork.self, forKey: .network)
            ?? PairingNetwork.inferred(from: endpoint)
        tailscaleDNSName = try container.decodeIfPresent(String.self, forKey: .tailscaleDNSName)
        tailscaleDeviceName = try container.decodeIfPresent(String.self, forKey: .tailscaleDeviceName)
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

enum ClaudeActivationPreference: String, Codable, Equatable, Sendable {
    case automatic = "auto"
    case enabled
    case disabled
}

struct ClaudeConfigurationResult: Codable, Equatable, Sendable {
    let enabled: Bool
    let available: Bool
    let preference: ClaudeActivationPreference
    let previousEnabled: Bool
    let previousPreference: ClaudeActivationPreference
    let changed: Bool
    let restartRequired: Bool
    let reason: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case enabled = "claude_enabled"
        case available
        case preference
        case previousEnabled = "previous_enabled"
        case previousPreference = "previous_preference"
        case changed
        case restartRequired = "restart_required"
        case reason
        case message
    }
}

struct CodexSharingConfigurationResult: Codable, Equatable, Sendable {
    let enabled: Bool
    let changed: Bool
    let restartRequired: Bool
    let daemonRestartRequired: Bool?
    let transport: String?
    let codexHome: String?
    let warning: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case changed
        case restartRequired = "restart_required"
        case daemonRestartRequired = "daemon_restart_required"
        case transport
        case codexHome = "codex_home"
        case warning
        case message
    }

    init(
        enabled: Bool,
        changed: Bool = false,
        restartRequired: Bool = false,
        daemonRestartRequired: Bool? = nil,
        transport: String? = nil,
        codexHome: String? = nil,
        warning: String? = nil,
        message: String = ""
    ) {
        self.enabled = enabled
        self.changed = changed
        self.restartRequired = restartRequired
        self.daemonRestartRequired = daemonRestartRequired
        self.transport = transport
        self.codexHome = codexHome
        self.warning = warning
        self.message = message
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
    let restartRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case fixes
        case results
        case restartRequired = "restart_required"
    }

    init(
        fixes: [String],
        results: AgentDoctorResults,
        restartRequired: Bool? = nil
    ) {
        self.fixes = fixes
        self.results = results
        self.restartRequired = restartRequired
    }
}

struct AgentRuntimeStatusSnapshot: Codable, Equatable, Sendable {
    let checkedAt: String?
    let runtimes: [AgentRuntimeStatus]
    let refreshing: Bool?
    let stale: Bool?

    enum CodingKeys: String, CodingKey {
        case checkedAt = "checked_at"
        case runtimes
        case refreshing
        case stale
    }

    init(
        checkedAt: String?,
        runtimes: [AgentRuntimeStatus],
        refreshing: Bool? = nil,
        stale: Bool? = nil
    ) {
        self.checkedAt = checkedAt
        self.runtimes = runtimes
        self.refreshing = refreshing
        self.stale = stale
    }

    var checkedDate: Date? {
        guard let checkedAt = checkedAt?.trimmedNonEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: checkedAt) ?? ISO8601DateFormatter().date(from: checkedAt)
    }

    func isExpired(at now: Date = Date()) -> Bool {
        if stale == true { return true }
        guard let checkedDate else {
            return refreshing != true
        }
        // 服务端成功快照缓存 5 分钟；本地多留 1 分钟容差，避免时钟/调度抖动
        // 把服务端仍认可的数据提前染成“已过期”。
        return now.timeIntervalSince(checkedDate) > 6 * 60
    }

    var hasRetryableFailure: Bool {
        runtimes.contains {
            guard $0.enabled else { return false }
            if $0.reason == "quota_refresh_in_progress" {
                return true
            }
            if $0.rateLimits?.availability?.lowercased() == "unavailable" {
                return true
            }
            return $0.state == .unavailable
                && $0.reason != "refresh_in_progress"
        }
    }
}

enum AgentRuntimeConnectionState: String, Codable, Equatable, Sendable {
    case connected
    case available
    case signedOut = "signed_out"
    case disabled
    case unavailable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // 服务端新增状态时 fail closed，但不要让整个 agent status 解码失败。
        self = AgentRuntimeConnectionState(rawValue: raw) ?? .unavailable
    }
}

struct AgentRuntimeStatus: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let enabled: Bool
    let state: AgentRuntimeConnectionState
    let version: String?
    let startedAt: String?
    let authMode: String?
    let planType: String?
    let reason: String?
    let rateLimits: AgentRuntimeRateLimits?
    /// agentd 通过 Unix socket 暴露给 Codex Desktop 的传输类型。
    /// 旧 agentd 不返回这些字段，因此必须保持可选并按未确认处理。
    let transport: String?
    let shared: Bool?
    /// Mimi-owned launchd owner 已安装，但现有 daemon 尚未在用户确认后迁移。
    let daemonRestartRequired: Bool?
    let codexHome: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case enabled
        case state
        case version
        case startedAt = "started_at"
        case authMode = "auth_mode"
        case planType = "plan_type"
        case reason
        case rateLimits = "rate_limits"
        case transport
        case shared
        case daemonRestartRequired = "daemon_restart_required"
        case codexHome = "codex_home"
    }

    init(
        id: String,
        title: String,
        enabled: Bool,
        state: AgentRuntimeConnectionState,
        version: String? = nil,
        startedAt: String? = nil,
        authMode: String?,
        planType: String?,
        reason: String?,
        rateLimits: AgentRuntimeRateLimits?,
        transport: String? = nil,
        shared: Bool? = nil,
        daemonRestartRequired: Bool? = nil,
        codexHome: String? = nil
    ) {
        self.id = id
        self.title = title
        self.enabled = enabled
        self.state = state
        self.version = version
        self.startedAt = startedAt
        self.authMode = authMode
        self.planType = planType
        self.reason = reason
        self.rateLimits = rateLimits
        self.transport = transport
        self.shared = shared
        self.daemonRestartRequired = daemonRestartRequired
        self.codexHome = codexHome
    }

    var effectivePlanType: String? {
        planType?.trimmedNonEmpty ?? rateLimits?.planType?.trimmedNonEmpty
    }

    var startedDate: Date? {
        guard let startedAt = startedAt?.trimmedNonEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: startedAt) ?? ISO8601DateFormatter().date(from: startedAt)
    }
}

/// Codex Desktop 的环境开关由 Mimi Remote Mac 写入 launchd 后，只能在新进程
/// 创建时生效。这个状态同时保留环境快照和 Desktop 发现结果，方便 UI 明确区分
/// “未安装、未确认共享、需要重启、已就绪”和外部冲突，而不是把所有情况显示成成功。
struct CodexDesktopEnvironmentSnapshot: Equatable, Sendable {
    let hasLocalPreference: Bool
    let enabled: Bool
    let environmentValue: String?
    let codexHome: String?
    let previousValue: String?
    let previousCodexHome: String?
    let writtenValue: String?
    let writtenCodexHome: String?
    let ownsEnvironment: Bool
    let ownsCodexHome: Bool
    /// launchd 中的当前会话 ownership epoch。它不是官方 Codex 配置，
    /// 只用于区分注销/登录后新会话里外部恰好写入相同值的情况。
    let sessionEpoch: String?
    let writtenSessionEpoch: String?
    let ownsSessionEpoch: Bool
    let appInstalled: Bool
    let appRunning: Bool
    let restartRequired: Bool
    let bundleURL: URL?

    init(
        hasLocalPreference: Bool = false,
        enabled: Bool = false,
        environmentValue: String? = nil,
        codexHome: String? = nil,
        previousValue: String? = nil,
        previousCodexHome: String? = nil,
        writtenValue: String? = nil,
        writtenCodexHome: String? = nil,
        ownsEnvironment: Bool = false,
        ownsCodexHome: Bool = false,
        sessionEpoch: String? = nil,
        writtenSessionEpoch: String? = nil,
        ownsSessionEpoch: Bool = false,
        appInstalled: Bool = false,
        appRunning: Bool = false,
        restartRequired: Bool = false,
        bundleURL: URL? = nil
    ) {
        self.hasLocalPreference = hasLocalPreference
        self.enabled = enabled
        self.environmentValue = environmentValue
        self.codexHome = codexHome
        self.previousValue = previousValue
        self.previousCodexHome = previousCodexHome
        self.writtenValue = writtenValue
        self.writtenCodexHome = writtenCodexHome
        self.ownsEnvironment = ownsEnvironment
        self.ownsCodexHome = ownsCodexHome
        self.sessionEpoch = sessionEpoch
        self.writtenSessionEpoch = writtenSessionEpoch
        self.ownsSessionEpoch = ownsSessionEpoch
        self.appInstalled = appInstalled
        self.appRunning = appRunning
        self.restartRequired = restartRequired
        self.bundleURL = bundleURL
    }
}

enum CodexDesktopStatusState: Equatable, Sendable {
    case disabled
    case notInstalled
    case backendNotShared
    case pendingRestart
    case ready
    case failed
    case externalConflict
}

struct CodexDesktopStatus: Equatable, Sendable {
    let environment: CodexDesktopEnvironmentSnapshot
    let state: CodexDesktopStatusState
    let error: String?

    init(
        environment: CodexDesktopEnvironmentSnapshot = CodexDesktopEnvironmentSnapshot(),
        state: CodexDesktopStatusState = .backendNotShared,
        error: String? = nil
    ) {
        self.environment = environment
        self.state = state
        self.error = error
    }

    var enabled: Bool { environment.enabled }
    var appInstalled: Bool { environment.appInstalled }
    var appRunning: Bool { environment.appRunning }
}

struct AgentRuntimeRateLimits: Codable, Equatable, Sendable {
    let limitID: String?
    let limitName: String?
    let planType: String?
    let reachedType: String?
    let availability: String?
    let unavailableReason: String?
    let primary: AgentRuntimeRateLimitWindow?
    let secondary: AgentRuntimeRateLimitWindow?
    let hasCredits: Bool?
    let creditsUnlimited: Bool?
    let creditBalance: String?

    enum CodingKeys: String, CodingKey {
        case limitID = "limit_id"
        case limitName = "limit_name"
        case planType = "plan_type"
        case reachedType = "reached_type"
        case availability
        case unavailableReason = "unavailable_reason"
        case primary
        case secondary
        case hasCredits = "has_credits"
        case creditsUnlimited = "credits_unlimited"
        case creditBalance = "credit_balance"
    }

    var windows: [AgentRuntimeRateLimitWindow] {
        [primary, secondary]
            .compactMap { $0 }
            .sorted {
                ($0.windowDurationMins ?? Int64.max) < ($1.windowDurationMins ?? Int64.max)
            }
    }

    var isExhausted: Bool {
        if reachedType?.trimmedNonEmpty != nil {
            return true
        }
        return windows.contains { ($0.usedPercent ?? 0) >= 100 }
    }
}

struct AgentRuntimeRateLimitWindow: Codable, Equatable, Sendable {
    let usedPercent: Double?
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowDurationMins = "window_duration_mins"
        case resetsAt = "resets_at"
    }

    var remainingFraction: Double? {
        usedPercent.map { min(max(1 - $0 / 100, 0), 1) }
    }

    var remainingPercentText: String? {
        remainingFraction.map { fraction in
            let percent = fraction * 100
            if abs(percent.rounded() - percent) < 0.0001 {
                return "\(Int(percent.rounded()))%"
            }
            return String(format: "%.1f%%", percent)
        }
    }

    var durationLabel: String {
        guard let minutes = windowDurationMins, minutes > 0 else {
            return "额度窗口"
        }
        if minutes.isMultiple(of: 24 * 60) {
            return "\(minutes / (24 * 60))d"
        }
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    var resetDate: Date? {
        guard let resetsAt, resetsAt > 0 else { return nil }
        let seconds = resetsAt > 10_000_000_000
            ? TimeInterval(resetsAt) / 1_000
            : TimeInterval(resetsAt)
        return Date(timeIntervalSince1970: seconds)
    }

    var isExhausted: Bool {
        (usedPercent ?? 0) >= 100
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct AgentStatus: Codable, Equatable, Sendable {
    let processOK: Bool
    let serviceOK: Bool
    let processError: String?
    let serviceError: String?
    let version: String
    let serverVersion: String?
    let endpoint: String
    let configPath: String
    let projects: Int
    let doctorOK: Bool
    let doctor: AgentDoctorResults
    let pairExpires: String?
    let runtimeStatus: AgentRuntimeStatusSnapshot?

    enum CodingKeys: String, CodingKey {
        case processOK = "process_ok"
        case serviceOK = "service_ok"
        case processError = "process_error"
        case serviceError = "service_error"
        case version
        case serverVersion = "server_version"
        case endpoint
        case configPath = "config_path"
        case projects
        case doctorOK = "doctor_ok"
        case doctor
        case pairExpires = "pair_expires"
        case runtimeStatus = "runtime_status"
    }

    init(
        processOK: Bool,
        serviceOK: Bool,
        processError: String?,
        serviceError: String?,
        version: String,
        serverVersion: String? = nil,
        endpoint: String,
        configPath: String,
        projects: Int,
        doctorOK: Bool,
        doctor: AgentDoctorResults,
        pairExpires: String?,
        runtimeStatus: AgentRuntimeStatusSnapshot? = nil
    ) {
        self.processOK = processOK
        self.serviceOK = serviceOK
        self.processError = processError
        self.serviceError = serviceError
        self.version = version
        self.serverVersion = serverVersion
        self.endpoint = endpoint
        self.configPath = configPath
        self.projects = projects
        self.doctorOK = doctorOK
        self.doctor = doctor
        self.pairExpires = pairExpires
        self.runtimeStatus = runtimeStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processOK = try container.decode(Bool.self, forKey: .processOK)
        serviceOK = try container.decode(Bool.self, forKey: .serviceOK)
        processError = try container.decodeIfPresent(String.self, forKey: .processError)
        serviceError = try container.decodeIfPresent(String.self, forKey: .serviceError)
        version = try container.decode(String.self, forKey: .version)
        serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        configPath = try container.decode(String.self, forKey: .configPath)
        projects = try container.decode(Int.self, forKey: .projects)
        doctorOK = try container.decode(Bool.self, forKey: .doctorOK)
        doctor = try container.decode(AgentDoctorResults.self, forKey: .doctor)
        pairExpires = try container.decodeIfPresent(String.self, forKey: .pairExpires)
        do {
            runtimeStatus = try container.decodeIfPresent(
                AgentRuntimeStatusSnapshot.self,
                forKey: .runtimeStatus
            )
        } catch {
            // runtime_status 是菜单栏增强字段。混合版本或局部协议漂移时只丢弃
            // 该快照，不能让健康检查、迁移和服务控制一起解码失败。
            runtimeStatus = nil
        }
    }

    var hasAgentVersionMismatch: Bool {
        guard let running = serverVersion?.trimmedNonEmpty,
              let bundled = version.trimmedNonEmpty
        else {
            return false
        }
        return running != bundled
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
