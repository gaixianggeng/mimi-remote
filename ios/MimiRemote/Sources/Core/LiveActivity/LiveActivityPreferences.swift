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

/// 关闭或换绑后还没撤销成功的票据（#830）。它和当前绑定的记录分开存放，从不阻塞重新开启
/// 或绑定另一台 Mac：推送服务撤销才是真正的关闭保证，撤销后 agentd 再用这张 Ticket 投递
/// 会得到 ticket_revoked 并自行删除。
struct LiveActivityRevocationBacklog: Codable, Equatable {
    struct Ticket: Codable, Equatable {
        let providerURL: String
        let ticket: String
        let expiresAt: Date
    }

    var tickets: [Ticket] = []
    /// 关闭开关时 agentd 暂时联系不上，注销留到之后重试；只在实时活动仍关闭时有意义，
    /// 重新开启后新票据会覆盖旧的，这一步随之放弃。
    var unregisterProfileID: String?

    var isEmpty: Bool { tickets.isEmpty && unregisterProfileID == nil }

    mutating func append(_ record: LiveActivityTicketRecord) {
        let entries = [record.start].compactMap { $0 } + record.updates.values.sorted { $0.ticket < $1.ticket }
        for entry in entries where !tickets.contains(where: { $0.ticket == entry.ticket }) {
            tickets.append(Ticket(providerURL: record.providerURL, ticket: entry.ticket, expiresAt: entry.expiresAt))
        }
    }
}

/// agentd 注销失败的两类原因要分开：主机已经不在（档案删了、没有设备身份、agentd 明确拒绝）
/// 时这一步永远不会成功，视为完成；只有暂时联系不上才留着重试。
enum LiveActivityRevocationError: Error, Equatable {
    case hostGone
}

enum LiveActivityTicketRevocation {
    /// 返回仍未完成的部分；nil 表示已全部完成。过期票据推送服务已不再接受，无需撤销。
    static func run(
        backlog: LiveActivityRevocationBacklog,
        now: Date = Date(),
        unregister: (String) async throws -> Void,
        revoke: (LiveActivityRevocationBacklog.Ticket) async throws -> Void
    ) async -> LiveActivityRevocationBacklog? {
        var remaining = backlog
        remaining.tickets = remaining.tickets.filter { $0.expiresAt > now }
        if let profileID = remaining.unregisterProfileID {
            do {
                try await unregister(profileID)
                remaining.unregisterProfileID = nil
            } catch LiveActivityRevocationError.hostGone {
                remaining.unregisterProfileID = nil
            } catch {
                // 暂时联系不上：保留这一步，推送服务撤销照常进行。
            }
        }
        var kept: [LiveActivityRevocationBacklog.Ticket] = []
        for ticket in remaining.tickets {
            if (try? await revoke(ticket)) == nil {
                kept.append(ticket)
            }
        }
        remaining.tickets = kept
        return remaining.isEmpty ? nil : remaining
    }

    /// agentd 的明确拒绝（4xx，超时与限流除外）说明那台电脑上已经没有可注销的设备。
    static func isHostGone(_ error: Error) -> Bool {
        if let error = error as? LiveActivityRevocationError, error == .hostGone { return true }
        if let error = error as? AgentAPIError, case .server(let status, _) = error {
            return (400..<500).contains(status) && status != 408 && status != 429
        }
        return false
    }
}

struct LiveActivityTicketStore {
    private let service = "com.gaixianggeng.mimiremote"
    private let account = "live-activity-tickets.v1"
    private let backlogAccount = "live-activity-revocations.v1"
    private let keychain: any KeychainOperating

    init(keychain: any KeychainOperating = SystemKeychainOperations()) {
        self.keychain = keychain
    }

    /// 读不出或格式损坏都按没有记录处理：最坏情况是多登记一次，不影响消息提醒。
    func load() -> LiveActivityTicketRecord? {
        read(account: account)
    }

    func save(_ record: LiveActivityTicketRecord) {
        write(record, account: account)
    }

    func delete() {
        _ = keychain.delete(baseQuery(account: account) as CFDictionary)
    }

    func loadBacklog() -> LiveActivityRevocationBacklog? {
        read(account: backlogAccount)
    }

    func saveBacklog(_ backlog: LiveActivityRevocationBacklog?) {
        guard let backlog, !backlog.isEmpty else {
            _ = keychain.delete(baseQuery(account: backlogAccount) as CFDictionary)
            return
        }
        write(backlog, account: backlogAccount)
    }

    private func read<Value: Decodable>(account: String) -> Value? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard keychain.copyMatching(query as CFDictionary, result: &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let query = baseQuery(account: account)
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

    private func baseQuery(account: String) -> [String: Any] {
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
        if availability == .disablePending { return "ui.live_activity_disable_pending" }
        guard notificationsEnabled else { return "ui.live_activity_requires_notifications" }
        switch availability {
        case .off: return "ui.live_activity_status_off"
        case .requiresNotifications: return "ui.live_activity_requires_notifications"
        case .systemDisabled: return "ui.live_activity_system_disabled"
        case .unavailableOnHost: return "ui.live_activity_unavailable_on_host"
        case .failed: return "ui.live_activity_status_failed"
        case .pending, .ready: return "ui.live_activity_status_on"
        case .disablePending: return "ui.live_activity_disable_pending"
        }
    }
}
