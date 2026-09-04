import Foundation

enum ManagedConnectionDeviceType: String, Codable, Equatable, Sendable {
    case mac
    case mobile
}

struct ManagedConnectionDevice: Identifiable, Equatable, Sendable {
    let id: String
    let deviceType: ManagedConnectionDeviceType
    let createdAt: Date
}

struct ManagedConnectionDeviceRegistration: Equatable, Sendable {
    let device: ManagedConnectionDevice
    let created: Bool
}

struct ManagedConnectionManagementSession: Equatable, Sendable {
    let token: String
    let expiresAt: Date
}

struct ManagedConnectionPairingSession: Equatable, Sendable {
    enum MacSlot: String, Equatable, Sendable {
        case reserved
        case existing
    }

    let id: String
    let expiresAt: Date
    let macSlot: MacSlot
    let created: Bool
}

protocol ManagedConnectionDeviceAPIClient: Sendable {
    func registerMobileDevice(
        entitlementToken: String,
        installationID: String,
        deviceToken: String
    ) async throws -> ManagedConnectionDeviceRegistration

    func authorizePairing(
        deviceToken: String,
        requestID: String,
        macInstallationID: String,
        mobileTailcatPublicKey: String,
        macTailcatPublicKey: String,
        managedPairingGrant: String
    ) async throws -> ManagedConnectionPairingSession

    func createManagementSession(
        signedAppTransaction: String,
        signedTransaction: String
    ) async throws -> ManagedConnectionManagementSession

    func listDevices(managementToken: String) async throws -> [ManagedConnectionDevice]
    func removeDevice(id: String, managementToken: String) async throws
}

struct LiveManagedConnectionDeviceAPIClient: ManagedConnectionDeviceAPIClient {
    private let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "https://api.code89757.com")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func registerMobileDevice(
        entitlementToken: String,
        installationID: String,
        deviceToken: String
    ) async throws -> ManagedConnectionDeviceRegistration {
        var request = jsonRequest(path: "v1/devices", method: "POST", bearerToken: entitlementToken)
        request.httpBody = try JSONEncoder().encode(
            RegisterDeviceRequest(
                installationId: installationID,
                deviceType: ManagedConnectionDeviceType.mobile.rawValue,
                deviceToken: deviceToken
            )
        )
        let payload: RegisterDeviceResponse = try await decodedResponse(for: request)
        return ManagedConnectionDeviceRegistration(
            device: try payload.device.model(),
            created: payload.created
        )
    }

    func authorizePairing(
        deviceToken: String,
        requestID: String,
        macInstallationID: String,
        mobileTailcatPublicKey: String,
        macTailcatPublicKey: String,
        managedPairingGrant: String
    ) async throws -> ManagedConnectionPairingSession {
        var request = jsonRequest(
            path: "v1/pairing-sessions/authorize",
            method: "POST",
            bearerToken: deviceToken
        )
        request.httpBody = try JSONEncoder().encode(
            AuthorizePairingRequest(
                requestId: requestID,
                macInstallationId: macInstallationID,
                mobileTailcatPublicKey: mobileTailcatPublicKey,
                macTailcatPublicKey: macTailcatPublicKey,
                managedPairingGrant: managedPairingGrant
            )
        )
        let payload: AuthorizePairingResponse = try await decodedResponse(for: request)
        guard let macSlot = ManagedConnectionPairingSession.MacSlot(
            rawValue: payload.pairingSession.macSlot
        ) else {
            throw ManagedConnectionDeviceAPIError.invalidResponse
        }
        return ManagedConnectionPairingSession(
            id: payload.pairingSession.id,
            expiresAt: payload.pairingSession.expiresAt,
            macSlot: macSlot,
            created: payload.created
        )
    }

    func createManagementSession(
        signedAppTransaction: String,
        signedTransaction: String
    ) async throws -> ManagedConnectionManagementSession {
        var request = jsonRequest(path: "v1/device-management-sessions", method: "POST")
        request.httpBody = try JSONEncoder().encode(
            ManagementSessionRequest(
                signedAppTransaction: signedAppTransaction,
                signedTransaction: signedTransaction
            )
        )
        let payload: ManagementSessionResponse = try await decodedResponse(for: request)
        guard payload.scope == "device:manage" else {
            throw ManagedConnectionDeviceAPIError.invalidResponse
        }
        return ManagedConnectionManagementSession(
            token: payload.managementToken,
            expiresAt: payload.expiresAt
        )
    }

    func listDevices(managementToken: String) async throws -> [ManagedConnectionDevice] {
        let request = jsonRequest(path: "v1/devices", method: "GET", bearerToken: managementToken)
        let payload: DeviceListResponse = try await decodedResponse(for: request)
        return try payload.devices.map { try $0.model() }
    }

    func removeDevice(id: String, managementToken: String) async throws {
        let request = jsonRequest(
            path: "v1/devices/\(id)",
            method: "DELETE",
            bearerToken: managementToken
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagedConnectionDeviceAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.rejection(from: data)
        }
    }

    private func jsonRequest(
        path: String,
        method: String,
        bearerToken: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20
        return request
    }

    private func decodedResponse<Response: Decodable>(for request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagedConnectionDeviceAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.rejection(from: data)
        }
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw ManagedConnectionDeviceAPIError.invalidResponse
        }
    }

    private static func rejection(from data: Data) -> ManagedConnectionDeviceAPIError {
        let payload = try? JSONDecoder().decode(DeviceErrorResponse.self, from: data)
        return .rejected(
            code: payload?.code,
            deviceType: payload?.deviceType.flatMap(ManagedConnectionDeviceType.init(rawValue:)),
            limit: payload?.limit
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.deviceAPIWithFractionalSeconds.date(from: value)
                ?? ISO8601DateFormatter().date(from: value)
            {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid RFC 3339 date"
            )
        }
        return decoder
    }()
}

enum ManagedConnectionDeviceAPIError: LocalizedError, Equatable {
    case invalidResponse
    case rejected(code: String?, deviceType: ManagedConnectionDeviceType?, limit: Int?)

    var rejectionCode: String? {
        guard case .rejected(let code, _, _) = self else { return nil }
        return code
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L10n.text("ui.managed_devices_server_invalid")
        case .rejected(let code, let deviceType, let limit):
            switch code {
            case "device_limit_reached":
                let name = deviceType == .mac
                    ? L10n.text("ui.managed_devices_mac")
                    : L10n.text("ui.managed_devices_mobile")
                return L10n.format("ui.managed_devices_limit_reached", name, limit ?? 0)
            case "unauthorized":
                return L10n.text("ui.managed_devices_authorization_expired")
            case "device_token_conflict":
                return L10n.text("ui.managed_devices_credential_conflict")
            case "installation_id_conflict", "pairing_request_conflict", "pairing_grant_conflict":
                return L10n.text("ui.managed_devices_pairing_conflict")
            case "device_not_found":
                return L10n.text("ui.managed_devices_not_found")
            default:
                return L10n.text("ui.managed_devices_server_rejected")
            }
        }
    }
}

private struct RegisterDeviceRequest: Encodable {
    let installationId: String
    let deviceType: String
    let deviceToken: String
}

private struct RegisterDeviceResponse: Decodable {
    let device: DeviceResponse
    let created: Bool
}

private struct AuthorizePairingRequest: Encodable {
    let requestId: String
    let macInstallationId: String
    let mobileTailcatPublicKey: String
    let macTailcatPublicKey: String
    let managedPairingGrant: String
}

private struct AuthorizePairingResponse: Decodable {
    struct PairingSession: Decodable {
        let id: String
        let expiresAt: Date
        let macSlot: String
    }

    let pairingSession: PairingSession
    let created: Bool
}

private struct ManagementSessionRequest: Encodable {
    let signedAppTransaction: String
    let signedTransaction: String
}

private struct ManagementSessionResponse: Decodable {
    let managementToken: String
    let scope: String
    let expiresAt: Date
}

private struct DeviceListResponse: Decodable {
    let devices: [DeviceResponse]
}

private struct DeviceResponse: Decodable {
    let id: String
    let deviceType: String
    let createdAt: Date

    func model() throws -> ManagedConnectionDevice {
        guard let type = ManagedConnectionDeviceType(rawValue: deviceType) else {
            throw ManagedConnectionDeviceAPIError.invalidResponse
        }
        return ManagedConnectionDevice(id: id, deviceType: type, createdAt: createdAt)
    }
}

private struct DeviceErrorResponse: Decodable {
    let code: String
    let deviceType: String?
    let limit: Int?
}

private extension ISO8601DateFormatter {
    static let deviceAPIWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
