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
    func rememberRegisteredDeviceID(_ id: String)
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
        let installationID = validInstallationID(defaults.string(forKey: Self.installationIDKey))
            ?? createInstallationID()
        var deviceToken = try tokenStore.loadManagedMobileDeviceToken(installationID: installationID)
        if !Self.isCanonicalDeviceToken(deviceToken) {
            deviceToken = try makeToken()
            guard Self.isCanonicalDeviceToken(deviceToken) else {
                throw ManagedConnectionDeviceAPIError.invalidResponse
            }
            try tokenStore.saveManagedMobileDeviceToken(deviceToken, installationID: installationID)
        }
        return ManagedConnectionMobileIdentity(
            installationID: installationID,
            deviceToken: deviceToken,
            registeredDeviceID: defaults.string(forKey: Self.registeredDeviceIDKey)
        )
    }

    func rememberRegisteredDeviceID(_ id: String) {
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
        defaults.removeObject(forKey: Self.registeredDeviceIDKey)
    }

    private func createInstallationID() -> String {
        var value = makeUUID().uuidString.lowercased()
        while !Self.isUUIDv4(value) {
            value = UUID().uuidString.lowercased()
        }
        defaults.set(value, forKey: Self.installationIDKey)
        defaults.removeObject(forKey: Self.registeredDeviceIDKey)
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
