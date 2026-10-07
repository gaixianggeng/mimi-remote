import Foundation

struct DeepSeekConfigurationResult: Decodable, Equatable, Sendable {
    let enabled: Bool
    let available: Bool
    let discovered: Bool
    let baseURL: String?
    let message: String
    let restartRequired: Bool

    enum CodingKeys: String, CodingKey {
        case enabled, available, discovered, message
        case baseURL = "base_url"
        case restartRequired = "restart_required"
    }
}

enum DeepSeekConfigurationAction: String, Sendable {
    case inspect, connect, disabled, refresh
}
