import Foundation
import Security

protocol KeychainOperating {
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct SystemKeychainOperations: KeychainOperating {
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributesToUpdate)
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

enum TokenStoreError: LocalizedError {
    case loadFailed(OSStatus)
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var isMissingEntitlement: Bool {
        switch self {
        case .loadFailed(let status), .saveFailed(let status), .deleteFailed(let status):
            return status == errSecMissingEntitlement
        }
    }

    var errorDescription: String? {
        switch self {
        case .loadFailed(let status):
            return L10n.format("ui.failed_to_read_token_value", status)
        case .saveFailed(let status):
            return L10n.format("ui.failed_to_save_token_value", status)
        case .deleteFailed(let status):
            return L10n.format("ui.failed_to_delete_token_value", status)
        }
    }
}

struct TokenStore {
    private let service = "com.gaixianggeng.mimiremote"
    private let legacyAccount = "agentd-token"
    private let profileAccountPrefix = "agentd-profile."
    private let tailcatExperimentAccount = "tailcat-experiment-client-key.v1"
    private let keychain: any KeychainOperating

    init(keychain: any KeychainOperating = SystemKeychainOperations()) {
        self.keychain = keychain
    }

    func load() -> String {
        (try? load(account: legacyAccount)) ?? ""
    }

    func load(profileID: String) throws -> String {
        try load(account: profileAccount(for: profileID))
    }

    func loadTailcatExperimentPrivateKey() throws -> String {
        try load(account: tailcatExperimentAccount)
    }

    private func load(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, result: &item)
        if status == errSecItemNotFound {
            return ""
        }
        guard status == errSecSuccess else {
            throw TokenStoreError.loadFailed(status)
        }
        guard let data = item as? Data else {
            throw TokenStoreError.loadFailed(errSecDecode)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func save(_ token: String) throws {
        try save(token, account: legacyAccount)
    }

    func save(_ token: String, profileID: String) throws {
        try save(token, account: profileAccount(for: profileID))
    }

    func saveTailcatExperimentPrivateKey(_ privateKey: String) throws {
        try save(privateKey, account: tailcatExperimentAccount)
    }

    private func save(_ token: String, account: String) throws {
        let value: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = keychain.update(
            baseQuery(account: account) as CFDictionary,
            attributesToUpdate: value as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            // 只有确认 item 不存在才 Add；已有 item 的更新失败时绝不先 Delete，
            // 否则一次 Keychain 瞬时错误会把仍可用的旧访问码永久清掉。
            var item = baseQuery(account: account)
            value.forEach { item[$0.key] = $0.value }
            let addStatus = keychain.add(item as CFDictionary)
            guard addStatus == errSecSuccess else {
                throw TokenStoreError.saveFailed(addStatus)
            }
        default:
            throw TokenStoreError.saveFailed(updateStatus)
        }
    }

    func delete(allowMissing: Bool = false) throws {
        try delete(account: legacyAccount, allowMissing: allowMissing)
    }

    func delete(profileID: String, allowMissing: Bool = false) throws {
        try delete(account: profileAccount(for: profileID), allowMissing: allowMissing)
    }

    private func delete(account: String, allowMissing: Bool) throws {
        let status = keychain.delete(baseQuery(account: account) as CFDictionary)
        if status == errSecItemNotFound && allowMissing {
            return
        }
        guard status == errSecSuccess else {
            throw TokenStoreError.deleteFailed(status)
        }
    }

    private func profileAccount(for profileID: String) -> String {
        profileAccountPrefix + profileID
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
