import Foundation
import Security

struct ManagedConnectionMobileIdentity: Equatable, Sendable {
    let installationID: String
    let deviceToken: String
    let registeredDeviceID: String?
}

@MainActor
protocol ManagedConnectionMobileIdentityStoring: AnyObject {
    func loadOrCreate() throws -> ManagedConnectionMobileIdentity
    func rememberRegisteredDeviceID(_ id: String) throws
    func rotateCredentialAfterRevocation(deviceID: String) throws
}

enum ManagedConnectionSecretGenerator {
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TokenStoreError.saveFailed(status)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class ManagedConnectionMobileIdentityStore: ManagedConnectionMobileIdentityStoring {
    private static let installationIDKey = "managedConnection.mobileInstallationID.v1"
    private static let registeredDeviceIDKey = "managedConnection.mobileDeviceID.v1"

    private let defaults: UserDefaults
    private let tokenStore: TokenStore
    private let makeUUID: () -> UUID
    private let makeToken: () throws -> String

    init(
        defaults: UserDefaults = .standard,
        tokenStore: TokenStore = TokenStore(),
        makeUUID: @escaping () -> UUID = UUID.init,
        makeToken: @escaping () throws -> String = ManagedConnectionSecretGenerator.token
    ) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.makeUUID = makeUUID
        self.makeToken = makeToken
    }

    func loadOrCreate() throws -> ManagedConnectionMobileIdentity {
        let installationID = try loadOrCreateInstallationID()
        var deviceToken = try tokenStore.loadManagedMobileDeviceToken(installationID: installationID)
        if !Self.isCanonicalDeviceToken(deviceToken) {
            deviceToken = try makeToken()
            guard Self.isCanonicalDeviceToken(deviceToken) else {
                throw ManagedConnectionDeviceAPIError.invalidResponse
            }
            try tokenStore.saveManagedMobileDeviceToken(deviceToken, installationID: installationID)
        }
        let registeredDeviceID = try loadRegisteredDeviceID()
        return ManagedConnectionMobileIdentity(
            installationID: installationID,
            deviceToken: deviceToken,
            registeredDeviceID: registeredDeviceID
        )
    }

    func rememberRegisteredDeviceID(_ id: String) throws {
        try tokenStore.saveManagedMobileRegisteredDeviceID(id)
        defaults.set(id, forKey: Self.registeredDeviceIDKey)
    }

    func rotateCredentialAfterRevocation(deviceID: String) throws {
        guard defaults.string(forKey: Self.registeredDeviceIDKey) == deviceID,
              let installationID = validInstallationID(
                  defaults.string(forKey: Self.installationIDKey)
              ) else {
            return
        }
        // 服务端明确禁止复用已撤销 Token。安装 ID 保持稳定，下一次登记生成新 Token。
        try tokenStore.deleteManagedMobileDeviceToken(installationID: installationID)
        try tokenStore.deleteManagedMobileRegisteredDeviceID()
        defaults.removeObject(forKey: Self.registeredDeviceIDKey)
    }

    private func loadRegisteredDeviceID() throws -> String? {
        let keychainValue = try tokenStore.loadManagedMobileRegisteredDeviceID()
        if !keychainValue.isEmpty {
            defaults.set(keychainValue, forKey: Self.registeredDeviceIDKey)
            return keychainValue
        }
        guard let legacyValue = defaults.string(forKey: Self.registeredDeviceIDKey),
              !legacyValue.isEmpty else {
            return nil
        }
        try tokenStore.saveManagedMobileRegisteredDeviceID(legacyValue)
        return legacyValue
    }

    private func loadOrCreateInstallationID() throws -> String {
        let defaultsInstallationID = validInstallationID(defaults.string(forKey: Self.installationIDKey))
        let keychainValue = try tokenStore.loadManagedMobileInstallationID()
        if !keychainValue.isEmpty {
            guard let installationID = validInstallationID(keychainValue) else {
                throw ManagedConnectionDeviceAPIError.invalidResponse
            }
            if defaultsInstallationID != installationID {
                defaults.removeObject(forKey: Self.registeredDeviceIDKey)
            }
            defaults.set(installationID, forKey: Self.installationIDKey)
            return installationID
        }

        // 首次升级优先迁移 UserDefaults 中的旧安装身份，保持原 device token 的 Keychain account 可寻址。
        let installationID = defaultsInstallationID ?? createInstallationID()
        // 先持久化不可重建的安装身份；Keychain 写入失败时不能发布一个临时身份。
        try tokenStore.saveManagedMobileInstallationID(installationID)
        defaults.set(installationID, forKey: Self.installationIDKey)
        if defaultsInstallationID == nil {
            defaults.removeObject(forKey: Self.registeredDeviceIDKey)
        }
        return installationID
    }

    private func createInstallationID() -> String {
        var value = makeUUID().uuidString.lowercased()
        while !Self.isUUIDv4(value) {
            value = UUID().uuidString.lowercased()
        }
        return value
    }

    private func validInstallationID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased()
        return Self.isUUIDv4(normalized) ? normalized : nil
    }

    private static func isUUIDv4(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard UUID(uuidString: value) != nil,
              parts.count == 5,
              parts[2].first == "4",
              let variant = parts[3].first?.lowercased()
        else {
            return false
        }
        return ["8", "9", "a", "b"].contains(variant)
    }

    private static func isCanonicalDeviceToken(_ value: String) -> Bool {
        guard value.count == 43,
              !value.contains("="),
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else {
            return false
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append("=")
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return false }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") == value
    }
}
