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

/// agentd 的通知定位响应。它只用于打开会话，不携带也不恢复任何审批执行资格。
/// 新字段全部可选：旧版 agentd 不返回时仍按 runtime / thread_id / project_id 定位。
struct PushActionRouteResponse: Decodable, Equatable {
	let runtime: String
	let threadID: String
	let projectID: String
	/// 网关作用域 ID（项目根为项目 ID，worktree / 浏览目录为 ws_ 前缀）。
	let scopeID: String?
	/// 线程真实工作目录；仅经 Bearer 鉴权的定位接口返回，不进入推送载荷。
	let cwd: String?
	/// "message" 或 "approval"。
	let kind: String?
	/// 审批句柄状态（pending / approved / rejected / expired / revoked / unknown）；消息路由为空。
	let state: String?
	/// agentd 是否已为当前 runtime 重新登记该线程的网关授权，允许随后直接 thread/read。
	let threadAuthorized: Bool?

	init(
		runtime: String,
		threadID: String,
		projectID: String,
		scopeID: String? = nil,
		cwd: String? = nil,
		kind: String? = nil,
		state: String? = nil,
		threadAuthorized: Bool? = nil
	) {
		self.runtime = runtime
		self.threadID = threadID
		self.projectID = projectID
		self.scopeID = scopeID
		self.cwd = cwd
		self.kind = kind
		self.state = state
		self.threadAuthorized = threadAuthorized
	}

	enum CodingKeys: String, CodingKey {
		case runtime
		case threadID = "thread_id"
		case projectID = "project_id"
		case scopeID = "scope_id"
		case cwd
		case kind
		case state
		case threadAuthorized = "thread_authorized"
	}
}
