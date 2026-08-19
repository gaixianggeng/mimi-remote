import UserNotifications

/// 锁屏审批通知的动作类别。
///
/// Apple 在锁屏与通知中心空间有限时最多展示两个自定义动作，因此这两个位置留给
/// 「允许」与「拒绝」；「查看详情」用点击通知本身完成，不再占一个按钮。
enum LockScreenApprovalCategory {
    static let identifier = "MIMI_APPROVAL"
    static let allowActionID = "MIMI_APPROVAL_ALLOW"
    static let denyActionID = "MIMI_APPROVAL_DENY"

    static func register(on center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories([makeCategory()])
    }

    static func makeCategory() -> UNNotificationCategory {
        // 「允许」必须先解锁设备：authenticationRequired 保证的是系统身份验证，
        // 它不替代 agentd 的 Bearer、设备绑定与一次性句柄校验，是叠加的一层。
        let allow = UNNotificationAction(
            identifier: allowActionID,
            title: L10n.text("ui.push_approval_action_allow"),
            options: [.authenticationRequired]
        )
        // 拒绝同样要求解锁：仅凭锁屏访问就能中断他人正在跑的任务，同样是破坏性操作。
        let deny = UNNotificationAction(
            identifier: denyActionID,
            title: L10n.text("ui.push_approval_action_deny"),
            options: [.authenticationRequired, .destructive]
        )
        return UNNotificationCategory(
            identifier: identifier,
            actions: [allow, deny],
            intentIdentifiers: [],
            options: [.hiddenPreviewsShowTitle]
        )
    }

    static func decision(forActionIdentifier identifier: String) -> LockScreenApprovalDecision? {
        switch identifier {
        case allowActionID:
            return .allow
        case denyActionID:
            return .deny
        default:
            return nil
        }
    }
}

enum LockScreenApprovalDecision: String, Sendable {
    case allow
    case deny
}
