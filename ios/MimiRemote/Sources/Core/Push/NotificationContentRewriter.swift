import Foundation
import UserNotifications

/// 在设备上把 Provider 的通用文案（「Codex 消息 / AI 已回复」）改写成会话标题。
///
/// 纯函数：输入推送解码结果与本地缓存条目，只改标题、副标题、正文。
/// threadIdentifier、category、userInfo、声音与打断级别一律不碰——它们决定
/// 通知的路由与动作，改写只负责让用户认出是哪个会话。
///
/// 这个文件同时编译进通知扩展，只允许依赖 Foundation 与 UserNotifications。
enum NotificationContentRewriter {
    static func runtimeDisplayName(_ runtime: LockScreenApprovalNotification.Runtime) -> String {
        switch runtime {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }

    /// 有标题后正文不再带「· 会话 7D92」后缀，因此用独立的 `.titled` key；
    /// 旧 key 继续服务缓存未命中与旧版 Provider 的系统渲染路径。
    static func bodyLocalizationKey(for notification: LockScreenApprovalNotification) -> String? {
        switch notification.event {
        case .completed: return "push.message.body.completed.titled"
        case .failed: return "push.message.body.failed.titled"
        case .interrupted: return "push.message.body.interrupted.titled"
        case .pending:
            guard notification.kind != .message else { return nil }
            return "push.approval.body.\(notification.kind.rawValue).titled"
        case .resolved:
            // 静默通知，没有可见内容可改。
            return nil
        }
    }

    /// 副标题保持一行：运行时 · 项目（· 主机，仅多档案时）。
    static func subtitle(
        entry: NotificationTitleCache.Entry,
        runtime: LockScreenApprovalNotification.Runtime,
        showsHostName: Bool
    ) -> String {
        var components = [runtimeDisplayName(runtime)]
        if !entry.project.isEmpty {
            components.append(entry.project)
        }
        if showsHostName, !entry.hostName.isEmpty {
            components.append(entry.hostName)
        }
        return components.joined(separator: " · ")
    }

    /// 返回是否真的改写了内容。缓存未命中或事件不可见时返回 false 且内容原样不动，
    /// 调用方应把原始内容交回系统。
    @discardableResult
    static func rewrite(
        _ content: UNMutableNotificationContent,
        notification: LockScreenApprovalNotification,
        entry: NotificationTitleCache.Entry?,
        showsHostName: Bool = false,
        localize: (String) -> String
    ) -> Bool {
        guard let entry, !entry.title.isEmpty,
              let bodyKey = bodyLocalizationKey(for: notification) else {
            return false
        }
        content.title = entry.title
        content.subtitle = subtitle(entry: entry, runtime: notification.runtime, showsHostName: showsHostName)
        let body = localize(bodyKey)
        // 缓存命中但扩展包里缺这条文案时保留系统已渲染的正文，不能显示裸 key。
        if body != bodyKey, !body.isEmpty {
            content.body = body
        }
        return true
    }
}
