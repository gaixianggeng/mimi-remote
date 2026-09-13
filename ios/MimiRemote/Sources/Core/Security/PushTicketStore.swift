import Foundation
import Security

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
        try? loadRequired()
    }

    /// 身份迁移必须区分“本机没有 Ticket”和“Keychain 暂时不可读”。
    /// 后一种情况不能被当成新设备，否则会静默铸造另一套设备身份。
    func loadRequired() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, result: &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw PushTicketStoreError.keychain(status: status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw PushTicketStoreError.keychain(status: errSecDecode)
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

/// Provider 与 agentd 使用的本机推送身份。
///
/// 两个值放在同一个 Keychain item 中，避免只更新其中一个。ThisDeviceOnly
/// 可访问性保证备份恢复到另一台设备时不会复制这套身份。
struct PushInstallationIdentity: Codable, Equatable {
    let deviceID: String
    let installationID: String

    static func make() -> PushInstallationIdentity {
        PushInstallationIdentity(
            deviceID: identifier(prefix: "dev"),
            installationID: identifier(prefix: "ins")
        )
    }

    static func validated(deviceID: String?, installationID: String?) -> PushInstallationIdentity? {
        guard let deviceID,
              let installationID,
              isValid(deviceID, prefix: "dev"),
              isValid(installationID, prefix: "ins") else {
            return nil
        }
        return PushInstallationIdentity(deviceID: deviceID, installationID: installationID)
    }

    private static func identifier(prefix: String) -> String {
        prefix + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func isValid(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix + "-"), value.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "-_").union(.alphanumerics)
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

struct PushInstallationIdentityStore {
    private let service = "com.gaixianggeng.mimiremote"
    private let account = "push-installation-identity.v1"
    private let keychain: any KeychainOperating

    init(keychain: any KeychainOperating = SystemKeychainOperations()) {
        self.keychain = keychain
    }

    func load() throws -> PushInstallationIdentity? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, result: &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw PushInstallationIdentityStoreError.keychain(status: status)
        }
        guard let data = item as? Data,
              let identity = try? JSONDecoder().decode(PushInstallationIdentity.self, from: data),
              PushInstallationIdentity.validated(
                deviceID: identity.deviceID,
                installationID: identity.installationID
              ) != nil else {
            throw PushInstallationIdentityStoreError.invalidData
        }
        return identity
    }

    func save(_ identity: PushInstallationIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = keychain.update(
            query as CFDictionary,
            attributesToUpdate: attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw PushInstallationIdentityStoreError.keychain(status: updateStatus)
        }
        var insert = query
        insert.merge(attributes) { _, new in new }
        let addStatus = keychain.add(insert as CFDictionary)
        guard addStatus == errSecSuccess else {
            throw PushInstallationIdentityStoreError.keychain(status: addStatus)
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

enum PushInstallationIdentityStoreError: Error, Equatable {
    case keychain(status: OSStatus)
    case invalidData
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
