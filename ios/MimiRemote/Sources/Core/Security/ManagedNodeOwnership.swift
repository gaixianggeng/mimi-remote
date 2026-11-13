import CryptoKit
import Foundation

struct ManagedNodeOwnershipChallenge: Decodable, Sendable {
    let challengeId: String
    let challengePublicKey: String
    let expiresAt: Date
}

struct ManagedNodeOwnershipProof: Encodable, Sendable {
    let challengeId: String
    let mobile: String
    let mac: String
    let pairingMac: String
}

struct ManagedHostNodeOwnershipProof: Decodable, Sendable {
    let mac: String
    let pairingMac: String
}

struct ManagedPairingOwnershipRequest: Encodable, Sendable {
    let requestId: String
    let macInstallationId: String
    let mobileTailcatPublicKey: String
    let macTailcatPublicKey: String
    let pairingMacTailcatPublicKey: String
    let managedPairingGrant: String
    var nodeOwnershipProof: ManagedNodeOwnershipProof?
}

typealias ManagedNodeOwnershipProver = @MainActor (ManagedNodeOwnershipChallenge) async throws -> ManagedNodeOwnershipProof

enum ManagedNodeOwnership {
    // 私钥留在 Keychain；只把针对本次挑战的 HMAC 交给控制面，不能把私钥当签名发送。
    static func mobileProof(privateKey: String, publicKey: String, challenge: ManagedNodeOwnershipChallenge) throws -> String {
        guard privateKey.hasPrefix("privkey:"),
              privateKey.count == 72,
              UUID(uuidString: challenge.challengeId) != nil,
              let remote = Data(base64Encoded: challenge.challengePublicKey
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              remote.count == 32 else { throw ManagedConnectionDeviceAPIError.invalidResponse }
        let hex = String(privateKey.dropFirst(8))
        var raw = Data()
        for index in stride(from: 0, to: 64, by: 2) {
            let start = hex.index(hex.startIndex, offsetBy: index)
            let end = hex.index(start, offsetBy: 2)
            guard let byte = UInt8(hex[start..<end], radix: 16) else { throw ManagedConnectionDeviceAPIError.invalidResponse }
            raw.append(byte)
        }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        let expectedPublic = "nodekey:" + key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        guard expectedPublic == publicKey else { throw ManagedConnectionDeviceAPIError.invalidResponse }
        let shared = try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote))
        let secret = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let message = Data("mimi-node-ownership-v1\n\(challenge.challengeId)\n\(publicKey)".utf8)
        return HMAC<SHA256>.authenticationCode(for: message, using: secret).map { String(format: "%02x", $0) }.joined()
    }
}
