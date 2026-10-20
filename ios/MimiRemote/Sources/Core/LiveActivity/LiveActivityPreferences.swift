import Foundation
import Security

/// 锁屏 / 灵动岛实时活动的开关（#830）。
///
/// 默认开启并跟随「消息通知」总开关：活动票据只能挂在已登记消息提醒的设备上，
/// 消息通知关闭时活动也不再启动或更新；单独关掉本开关不影响消息通知。
enum LiveActivityPreferences {
    static let key = "liveActivity.enabled.v1"

    static func isToggleOn(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? true
    }

    static func setToggle(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }

    /// 真正决定是否登记票据、是否本机拉起活动的值。
    static func isEffective(in defaults: UserDefaults = .standard) -> Bool {
        isToggleOn(in: defaults) && MessageNotificationPreferences.isEnabled(in: defaults)
    }
}

/// 本机已登记的 Live Activity 票据。用于判断 Token 没变时跳过重复登记，以及关闭时
/// 向推送服务撤销。和通知 Ticket 一样放 Keychain、ThisDeviceOnly。
struct LiveActivityTicketRecord: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let ticket: String
        let expiresAt: Date
        /// Token 指纹，不保存原始 Token。
        let tokenFingerprint: String
    }

    /// 票据登记到的连接档案与推送服务；与当前消息提醒绑定不一致时整体作废。
    let profileID: String
    let providerURL: String
    let hostTag: String
    var start: Entry?
    /// 键为 App 端 `Activity.id`。
    var updates: [String: Entry]

    init(profileID: String, providerURL: String, hostTag: String, start: Entry? = nil, updates: [String: Entry] = [:]) {
        self.profileID = profileID
        self.providerURL = providerURL
        self.hostTag = hostTag
        self.start = start
        self.updates = updates
    }

    func matches(profileID: String, providerURL: String, hostTag: String) -> Bool {
        self.profileID == profileID && self.providerURL == providerURL && self.hostTag == hostTag
    }

    /// push-to-start Ticket 还能用一周以上且 Token 没变时不必重新登记。
    func startIsCurrent(tokenFingerprint: String, now: Date) -> Bool {
        guard let start else { return false }
        return start.tokenFingerprint == tokenFingerprint
            && start.expiresAt.timeIntervalSince(now) >= 7 * 24 * 60 * 60
    }

    /// 单个活动的更新 Ticket 最长 24 小时；还剩一小时以上且 Token 没变就沿用。
    func updateIsCurrent(activityID: String, tokenFingerprint: String, now: Date) -> Bool {
        guard let entry = updates[activityID] else { return false }
        return entry.tokenFingerprint == tokenFingerprint && entry.expiresAt.timeIntervalSince(now) >= 60 * 60
    }

    /// 过期的更新票据已经无法撤销也无需撤销，直接丢掉。
    mutating func pruneExpiredUpdates(now: Date) {
        updates = updates.filter { $0.value.expiresAt > now }
    }

    var allTickets: [String] {
        [start?.ticket].compactMap { $0 } + updates.values.map(\.ticket).sorted()
    }
}

struct LiveActivityTicketStore {
    private let service = "com.gaixianggeng.mimiremote"
    private let account = "live-activity-tickets.v1"
    private let keychain: any KeychainOperating

    init(keychain: any KeychainOperating = SystemKeychainOperations()) {
        self.keychain = keychain
    }

    /// 读不出或格式损坏都按没有记录处理：最坏情况是多登记一次，不影响消息提醒。
    func load() -> LiveActivityTicketRecord? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard keychain.copyMatching(query as CFDictionary, result: &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(LiveActivityTicketRecord.self, from: data)
    }

    func save(_ record: LiveActivityTicketRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if keychain.update(query as CFDictionary, attributesToUpdate: attributes as CFDictionary) == errSecSuccess {
            return
        }
        var insert = query
        insert.merge(attributes) { _, new in new }
        _ = keychain.add(insert as CFDictionary)
    }

    func delete() {
        _ = keychain.delete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// 设置页实时活动开关下方的说明。只依赖两个输入，便于单测覆盖每种状态的文案。
enum LiveActivitySettingsCopy {
    static func statusKey(
        notificationsEnabled: Bool,
        availability: LiveActivityCoordinator.Availability
    ) -> String {
        guard notificationsEnabled else { return "ui.live_activity_requires_notifications" }
        switch availability {
        case .off: return "ui.live_activity_status_off"
        case .requiresNotifications: return "ui.live_activity_requires_notifications"
        case .systemDisabled: return "ui.live_activity_system_disabled"
        case .unavailableOnHost: return "ui.live_activity_unavailable_on_host"
        case .failed: return "ui.live_activity_status_failed"
        case .pending, .ready: return "ui.live_activity_status_on"
        }
    }
}
