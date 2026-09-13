import Foundation
import UserNotifications

/// 通知服务扩展：推送到达后、展示之前，在设备上把通用文案改写成会话标题。
///
/// 隐私边界：Provider 与 APNs 只见枚举与摘要；标题、项目、主机名来自 App 写进
/// App Group 的本地缓存，这里只读不写，也不发起任何网络请求。
///
/// 时间预算：系统只给扩展约 30 秒，超时就按原始内容展示。这里的工作只有一次
/// 文件读取加字典查找，全程同步完成；任何失败都把原始内容原样交回。
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        lock.withLock {
            self.contentHandler = contentHandler
            self.bestAttemptContent = request.content
        }
        let content = Self.rewrittenContent(for: request.content) ?? request.content
        deliver(content)
    }

    /// 系统即将回收扩展：把手上最好的版本交出去，绝不让 contentHandler 落空。
    override func serviceExtensionTimeWillExpire() {
        let content = lock.withLock { bestAttemptContent }
        if let content {
            deliver(content)
        }
    }

    /// 命中缓存才返回改写后的副本；解码失败、缓存未命中或文案缺失都返回 nil。
    static func rewrittenContent(for content: UNNotificationContent) -> UNNotificationContent? {
        guard let notification = LockScreenApprovalNotification(userInfo: content.userInfo),
              let mutable = content.mutableCopy() as? UNMutableNotificationContent else {
            return nil
        }
        let cache = NotificationTitleCache.load()
        let entry = cache.entry(profileTag: notification.profileID, sessionTag: notification.sessionTag)
        guard NotificationContentRewriter.rewrite(
            mutable,
            notification: notification,
            entry: entry,
            showsHostName: cache.showsHostName,
            localize: localize
        ) else {
            return nil
        }
        return mutable
    }

    /// 扩展包自带 Localizable.xcstrings，语言跟随系统设置，与 APNs 系统渲染路径一致。
    private static func localize(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// contentHandler 只能调用一次；didReceive 与 timeWillExpire 谁先到谁交付。
    private func deliver(_ content: UNNotificationContent) {
        let handler: ((UNNotificationContent) -> Void)? = lock.withLock {
            let handler = contentHandler
            contentHandler = nil
            return handler
        }
        handler?(content)
    }
}
