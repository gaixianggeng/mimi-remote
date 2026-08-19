import Foundation

/// agentd 的锁屏审批接口。
///
/// 这里只传 device_id、不透明 Ticket 与一次性 action_id；Device Token 从不经过
/// agentd，会话内容也从不经过 Provider。
struct PushStatusResponse: Decodable, Equatable {
    let enabled: Bool
    let providerConfigured: Bool
    let providerURL: String?
    let environment: String?
    let profileID: String?
    let actionableKinds: [String]?
    let devices: [PushDeviceSummary]?

    enum CodingKeys: String, CodingKey {
        case enabled
        case providerConfigured = "provider_configured"
        case providerURL = "provider_url"
        case environment
        case profileID = "profile_id"
        case actionableKinds = "actionable_kinds"
        case devices
    }
}

struct PushDeviceSummary: Decodable, Equatable {
    let deviceID: String
    let platform: String?
    let expiresAt: String?
    let needsRefresh: Bool?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case platform
        case expiresAt = "expires_at"
        case needsRefresh = "needs_refresh"
    }
}

struct PushDeviceRegistrationResponse: Decodable, Equatable {
    let deviceID: String
    let expiresAt: String
    let needsRefresh: Bool

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case expiresAt = "expires_at"
        case needsRefresh = "needs_refresh"
    }
}

/// 决策结果刻意区分「已处理」「冲突」「已过期」「未知」。UI 必须如实展示这些
/// 状态——把超时或冲突显示成成功，比不显示更危险。
struct PushDecisionResponse: Decodable, Equatable {
    let outcome: String?
    let state: String?
    let decision: String?
    let runtime: String?
    let reason: String?
}
