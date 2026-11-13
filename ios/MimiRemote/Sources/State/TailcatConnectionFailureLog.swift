import Foundation
import Network

/// 设备侧的连接失败记录，用来和 Mac 的 tailcat-events.log 按时间对照。
/// 只存阶段、错误类别和网络类型：错误原文里可能有 IP、端口和地址串，这里不保留。
struct TailcatConnectionFailure: Codable, Equatable, Identifiable {
    enum Stage: String, Codable {
        case tunnelStart = "tunnel_start"
        case routeProbe = "route_probe"
        case requestProbe = "request_probe"
        case foregroundProbe = "foreground_probe"
        case preflight

        var title: String {
            switch self {
            case .tunnelStart: return L10n.text("ui.tailcat_failure_stage_tunnel_start")
            case .routeProbe: return L10n.text("ui.tailcat_failure_stage_route_probe")
            case .requestProbe: return L10n.text("ui.tailcat_failure_stage_request_probe")
            case .foregroundProbe: return L10n.text("ui.tailcat_failure_stage_foreground_probe")
            case .preflight: return L10n.text("ui.tailcat_failure_stage_preflight")
            }
        }
    }

    enum Reason: String, Codable {
        case network
        case timeout
        case authentication
        case policy
        case unknown

        init(error: Error?) {
            switch ManagedConnectionEventErrorCategory(error: error) {
            case .network: self = .network
            case .timeout: self = .timeout
            case .authentication: self = .authentication
            case .policy: self = .policy
            case .none, .unknown: self = Self.classify(message: error?.localizedDescription)
            }
        }

        /// Tailcat 的错误从 Go 桥接过来，不是 URLError，只能按文本归类。
        private static func classify(message: String?) -> Reason {
            let message = message?.lowercased() ?? ""
            if ["timeout", "timed out", "deadline exceeded"].contains(where: message.contains) {
                return .timeout
            }
            if ["no route to host", "network is", "connection refused", "connection reset", "unreachable"]
                .contains(where: message.contains) {
                return .network
            }
            return .unknown
        }

        var title: String {
            switch self {
            case .network: return L10n.text("ui.tailcat_failure_reason_network")
            case .timeout: return L10n.text("ui.tailcat_failure_reason_timeout")
            case .authentication: return L10n.text("ui.tailcat_failure_reason_authentication")
            case .policy: return L10n.text("ui.tailcat_failure_reason_policy")
            case .unknown: return L10n.text("ui.tailcat_failure_reason_unknown")
            }
        }
    }

    enum NetworkKind: String, Codable {
        case wifi
        case cellular
        case wired
        case other
        case none
        case unknown

        init(path: NWPath) {
            guard path.status == .satisfied else {
                self = .none
                return
            }
            if path.usesInterfaceType(.wifi) {
                self = .wifi
            } else if path.usesInterfaceType(.cellular) {
                self = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                self = .wired
            } else {
                self = .other
            }
        }

        var title: String {
            switch self {
            case .wifi: return L10n.text("ui.tailcat_failure_network_wifi")
            case .cellular: return L10n.text("ui.tailcat_failure_network_cellular")
            case .wired: return L10n.text("ui.tailcat_failure_network_wired")
            case .other: return L10n.text("ui.tailcat_failure_network_other")
            case .none: return L10n.text("ui.tailcat_failure_network_none")
            case .unknown: return L10n.text("ui.tailcat_failure_network_unknown")
            }
        }
    }

    let id: UUID
    let occurredAt: Date
    let stage: Stage
    let reason: Reason
    let network: NetworkKind

    /// 复制给排查者的固定格式：英文枚举值不随语言变化，时间带时区，能直接与 Mac 日志比较。
    var redactedLine: String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return "\(formatter.string(from: occurredAt)) failure stage=\(stage.rawValue) "
            + "reason=\(reason.rawValue) network=\(network.rawValue)"
    }

    /// 任务取消是 App 自己放弃，不是连接失败。
    static func shouldRecord(_ error: Error?) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        return true
    }
}

enum TailcatConnectionFailureLog {
    static let defaultsKey = "agentd.tailcatExperiment.connectionFailures.v1"
    static let capacity = 20

    static func load(defaults: UserDefaults) -> [TailcatConnectionFailure] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([TailcatConnectionFailure].self, from: data)
        else { return [] }
        return Array(decoded.prefix(capacity))
    }

    static func save(_ failures: [TailcatConnectionFailure], defaults: UserDefaults) {
        if let encoded = try? JSONEncoder().encode(failures) {
            defaults.set(encoded, forKey: defaultsKey)
        }
    }
}

/// 常驻监听一份网络路径。记录失败时才读取，不触发任何 UI 更新。
final class TailcatNetworkKindReader: @unchecked Sendable {
    static let shared = TailcatNetworkKindReader()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var kind = TailcatConnectionFailure.NetworkKind.unknown

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let kind = TailcatConnectionFailure.NetworkKind(path: path)
            self.lock.withLock { self.kind = kind }
        }
        monitor.start(queue: DispatchQueue(label: "com.gaixianggeng.mimi.tailcat-network-kind"))
    }

    var current: TailcatConnectionFailure.NetworkKind {
        lock.withLock { kind }
    }
}
