import Foundation
import UserNotifications

/// 用户意愿与推送注册结果分开保存。旧版 false 也可能来自失败，无法区分时保守保留。
enum MessageNotificationPreferences {
    static let key = "messageNotifications.enabled.v1"
    static let legacyKey = "lockScreenApproval.enabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key) as? Bool)
            ?? (defaults.object(forKey: legacyKey) as? Bool)
            ?? true
    }

    @discardableResult
    static func migrate(in defaults: UserDefaults) -> Bool {
        let enabled = isEnabled(in: defaults)
        if defaults.object(forKey: key) == nil {
            defaults.set(enabled, forKey: key)
        }
        return enabled
    }
}

/// 所有通知入口共用系统授权任务，避免多窗口和手动提醒同时请求权限。
actor NotificationAuthorizationController {
    static let shared = NotificationAuthorizationController()
    private let readStatus: @Sendable () async -> UNAuthorizationStatus
    private let request: @Sendable () async throws -> Bool
    private var pendingRequest: Task<Bool, Error>?

    init(
        readStatus: @escaping @Sendable () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        },
        request: @escaping @Sendable () async throws -> Bool = {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    ) {
        self.readStatus = readStatus
        self.request = request
    }

    func authorize(requestIfNeeded: Bool) async throws -> Bool {
        let status = await readStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            guard requestIfNeeded else { return false }
            if let pendingRequest { return try await pendingRequest.value }
            let task = Task { try await request() }
            pendingRequest = task
            defer { pendingRequest = nil }
            return try await task.value
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
