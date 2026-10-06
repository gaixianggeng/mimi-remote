import Foundation
import os

enum HostCapabilityDecision: String, Equatable, Sendable {
    case enabled
    case serverUnsupported = "server_unsupported"
    case locallyDisabled = "locally_disabled"
    case dependencyUnavailable = "dependency_unavailable"
    case negotiationFailed = "negotiation_failed"
}

struct HostCapabilityNegotiation: Equatable, Sendable {
    static let notNegotiated = HostCapabilityNegotiation(
        wasNegotiated: false,
        declared: [],
        statuses: []
    )

    let wasNegotiated: Bool
    let declared: Set<String>
    let statuses: [AgentCapabilityStatus]

    func decision(for capability: String) -> HostCapabilityDecision {
        guard wasNegotiated else {
            return .negotiationFailed
        }
        let matchingStatuses = statuses.filter { $0.name == capability }
        guard matchingStatuses.count <= 1 else {
            return .negotiationFailed
        }
        let isDeclared = declared.contains(capability)
        guard let status = matchingStatuses.first else {
            // MIM-28 的 agentd 只声明 capabilities，没有状态说明；该兼容窗口仍然有效。
            return isDeclared ? .enabled : .serverUnsupported
        }
        if isDeclared {
            return status.state == HostCapabilityDecision.enabled.rawValue
                ? .enabled
                : .negotiationFailed
        }
        switch status.state {
        case HostCapabilityDecision.locallyDisabled.rawValue:
            return .locallyDisabled
        case HostCapabilityDecision.dependencyUnavailable.rawValue:
            return .dependencyUnavailable
        default:
            // “enabled 但未声明”或未来未知状态都不能授权当前客户端走新路径。
            return .negotiationFailed
        }
    }
}

/// 所有跨异步边界的数据都必须携带完整主机作用域。
/// endpoint 只是可变路由，不参与身份；同一台 Mac 更换地址后仍复用原有 Profile 数据。
struct HostScope: Hashable, Sendable {
    let profileID: String
    let installationID: String
    let generation: UInt64
}

struct ScopedSessionID: Hashable, Sendable {
    let profileID: String
    let sessionID: String
}

/// 实时事件不只按 Profile 隔离，还必须绑定连接代次；切回同一台 Mac 后，
/// 上一个 generation 的尾包也不能进入新的 Runtime。
struct HostSessionLease: Hashable, Sendable {
    let hostScope: HostScope
    let sessionID: String
}

struct HostCapabilityLease: Equatable, Sendable {
    let capability: String
    let hostScope: HostScope
}

/// AppStore 只通过这个值发布当前主机身份，避免异步任务分别读取 profile、installation 和代次后
/// 拼出一份可能跨提交边界的混合状态。
struct ActiveHostState: Equatable, Sendable {
    let scope: HostScope
    let endpoint: String
    let displayName: String
    let committedAt: Date
    let capabilityNegotiation: HostCapabilityNegotiation

    func replacingCapabilityNegotiation(
        with negotiation: HostCapabilityNegotiation
    ) -> ActiveHostState {
        ActiveHostState(
            scope: scope,
            endpoint: endpoint,
            displayName: displayName,
            committedAt: committedAt,
            capabilityNegotiation: negotiation
        )
    }
}

enum CapabilityNegotiationLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gaixianggeng.mimi",
        category: "CapabilityNegotiation"
    )

    static func record(capability: String, decision: HostCapabilityDecision) {
        // capability 名称与决策是公开协议机器码；不记录 endpoint、Token 或 installation ID。
        logger.notice(
            "capability decision name=\(capability, privacy: .public) state=\(decision.rawValue, privacy: .public)"
        )
    }
}
