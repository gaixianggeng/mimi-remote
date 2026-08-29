import Foundation

/// 锁屏审批通知的严格解码。
///
/// Payload 由 Provider 单方面组装，只含枚举与不透明标识；这里再做一次白名单校验，
/// 保证即使中间环节被篡改，也不可能有自由文本进入 App 的请求路径或界面。
struct LockScreenApprovalNotification: Equatable, Sendable {
    enum Event: String, Sendable {
        case pending = "approval.pending"
        case resolved = "approval.resolved"
    }

    enum Runtime: String, Sendable {
        case codex
        case claude
    }

    enum Kind: String, Sendable {
        case command
        case patch
        case permission
        case userInput = "user_input"
        case elicitation

        /// 只有响应形状无歧义的两类才提供锁屏「允许 / 拒绝」。
        ///
        /// permission 的允许会授予一个作用域、拒绝须以 JSON-RPC error 表达；
        /// user_input 与 elicitation 离开内容根本无法作答，而内容正是刻意不放进
        /// 推送的东西。这三类只提供「查看详情」。
        var isActionableFromLockScreen: Bool {
            switch self {
            case .command, .patch:
                return true
            case .permission, .userInput, .elicitation:
                return false
            }
        }
    }

    static let currentVersion = 1
    static let payloadKey = "mimi"

    let event: Event
    let actionID: String
    let deviceID: String
    let profileID: String
    let runtime: Runtime
    let kind: Kind
    let hostTag: String
    let sessionTag: String
    let expiresAt: Date

    init?(userInfo: [AnyHashable: Any]) {
        guard let payload = userInfo[Self.payloadKey] as? [String: Any],
              let version = payload["version"] as? Int,
              version == Self.currentVersion,
              let event = (payload["event"] as? String).flatMap(Event.init(rawValue:)),
              let runtime = (payload["runtime"] as? String).flatMap(Runtime.init(rawValue:)),
              let kind = (payload["approval_kind"] as? String).flatMap(Kind.init(rawValue:)),
              let actionID = Self.opaqueIdentifier(payload["action_id"]),
              let deviceID = Self.opaqueIdentifier(payload["device_id"]),
              let profileID = Self.opaqueIdentifier(payload["profile_id"]),
              let hostTag = Self.shortTag(payload["host_tag"]),
              let sessionTag = Self.shortTag(payload["session_tag"]),
              let expiresAt = Self.timestamp(payload["expires_at"])
        else {
            return nil
        }
        self.event = event
        self.actionID = actionID
        self.deviceID = deviceID
        self.profileID = profileID
        self.runtime = runtime
        self.kind = kind
        self.hostTag = hostTag
        self.sessionTag = sessionTag
        self.expiresAt = expiresAt
    }

    /// 用于把不同事件里的同一审批关联起来。它不是
    /// `UNNotificationRequest.identifier`，不能传给通知中心删除 API。
    var approvalIdentifier: String { "mimi.approval.\(actionID)" }

    /// 兼容旧的调用方。删除通知时必须使用系统回调或 delivered 列表里的真实请求 ID。
    @available(*, deprecated, message: "仅用于逻辑关联，不是 UNNotificationRequest.identifier")
    var notificationIdentifier: String { approvalIdentifier }

    func identifiesSameApproval(as other: LockScreenApprovalNotification) -> Bool {
        actionID == other.actionID
            && deviceID == other.deviceID
            && profileID == other.profileID
    }

    func isExpired(at moment: Date = Date()) -> Bool { expiresAt <= moment }

    private static func opaqueIdentifier(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        let allowed = CharacterSet(charactersIn: "-_")
            .union(.alphanumerics)
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return trimmed
    }

    /// 短标签是 agentd 生成的大写十六进制摘要。限制字符集同时挡住了把主机名或
    /// 会话标题塞进来的可能。
    private static func shortTag(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 16 else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return trimmed
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
