import Foundation

/// Push Ticket 的本地存放处。
///
/// 它不是 agentd 的访问凭据——拿到它最多只能向这一台设备发送固定格式的 Mimi
/// 通知，既不能批准任何请求，也读不到会话内容。但它仍然是一段能影响用户设备的
/// 数据，所以和 Bearer Token 一样放 Keychain，并使用同样的可访问性策略：
/// 首次解锁后可读、且不参与备份迁移到别的设备。
struct PushTicketStore {
    private let service = "com.gaixianggeng.mimiremote"
    private let account = "push-ticket"
    private let keychain: any KeychainOperating

    init(keychain: any KeychainOperating = SystemKeychainOperations()) {
        self.keychain = keychain
    }

    func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, result: &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    func save(_ ticket: String) throws {
        let data = Data(ticket.utf8)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = keychain.update(query as CFDictionary, attributesToUpdate: attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw PushTicketStoreError.keychain(status: updateStatus)
        }
        var insert = query
        insert.merge(attributes) { _, new in new }
        let addStatus = keychain.add(insert as CFDictionary)
        guard addStatus == errSecSuccess else {
            throw PushTicketStoreError.keychain(status: addStatus)
        }
    }

    func delete() throws {
        let status = keychain.delete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PushTicketStoreError.keychain(status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum PushTicketStoreError: LocalizedError, Equatable {
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return L10n.format("ui.push_ticket_keychain_failed_value", Int(status))
        }
    }
}
