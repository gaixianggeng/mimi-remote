import UserNotifications

/// 锁屏审批通知的动作类别。
///
/// 可在锁屏执行的审批保留「允许」与「拒绝」，并提供需要打开 App 的「查看详情」。
/// 不可在锁屏执行的请求使用只含「查看详情」的独立 category。
enum LockScreenApprovalCategory {
    static let identifier = "MIMI_APPROVAL"
    static let detailsIdentifier = "MIMI_APPROVAL_DETAILS"
    static let allowActionID = "MIMI_APPROVAL_ALLOW"
    static let denyActionID = "MIMI_APPROVAL_DENY"
    static let detailsActionID = "MIMI_APPROVAL_DETAILS_OPEN"

    static func register(on center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories([makeCategory(), makeDetailsCategory()])
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
            actions: [allow, deny, makeDetailsAction()],
            intentIdentifiers: [],
            options: [.hiddenPreviewsShowTitle]
        )
    }

    static func makeDetailsCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: detailsIdentifier,
            actions: [makeDetailsAction()],
            intentIdentifiers: [],
            options: [.hiddenPreviewsShowTitle]
        )
    }

    private static func makeDetailsAction() -> UNNotificationAction {
        UNNotificationAction(
            identifier: detailsActionID,
            title: L10n.text("ui.open_details"),
            options: [.foreground]
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
