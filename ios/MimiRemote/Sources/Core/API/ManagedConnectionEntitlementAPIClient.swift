import Foundation

struct ManagedConnectionEntitlement: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case trial
        case active
        case grace
        case expired
        case revoked
    }

    let id: String
    let productID: String
    let status: Status
    let expiresAt: Date
}

struct ManagedConnectionEntitlementGrant: Equatable, Sendable {
    let entitlement: ManagedConnectionEntitlement
    let token: String
    let tokenExpiresAt: Date
}

protocol ManagedConnectionEntitlementAPIClient: Sendable {
    func resolve(
        signedAppTransaction: String,
        signedTransaction: String
    ) async throws -> ManagedConnectionEntitlementGrant
}

struct LiveManagedConnectionEntitlementAPIClient: ManagedConnectionEntitlementAPIClient {
    private let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "https://api.code89757.com")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func resolve(
        signedAppTransaction: String,
        signedTransaction: String
    ) async throws -> ManagedConnectionEntitlementGrant {
        let url = baseURL.appending(path: "v1/entitlements/resolve")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(
            ResolveRequest(
                signedAppTransaction: signedAppTransaction,
                signedTransaction: signedTransaction
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagedConnectionEntitlementAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let code = try? JSONDecoder().decode(ErrorResponse.self, from: data).code
            throw ManagedConnectionEntitlementAPIError.rejected(code: code)
        }

        let payload: ResolveResponse
        do {
            payload = try Self.decoder.decode(ResolveResponse.self, from: data)
        } catch {
            throw ManagedConnectionEntitlementAPIError.invalidResponse
        }
        guard let status = ManagedConnectionEntitlement.Status(rawValue: payload.entitlement.status) else {
            throw ManagedConnectionEntitlementAPIError.inactive
        }
        if status == .expired {
            throw ManagedConnectionEntitlementAPIError.rejected(code: "expired")
        }
        if status == .revoked {
            throw ManagedConnectionEntitlementAPIError.rejected(code: "revoked")
        }
        return ManagedConnectionEntitlementGrant(
            entitlement: ManagedConnectionEntitlement(
                id: payload.entitlement.id,
                productID: payload.entitlement.productId,
                status: status,
                expiresAt: payload.entitlement.expiresAt
            ),
            token: payload.entitlementToken,
            tokenExpiresAt: payload.tokenExpiresAt
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: value)
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

private struct ResolveRequest: Encodable {
    let signedAppTransaction: String
    let signedTransaction: String
}

private struct ResolveResponse: Decodable {
    struct Entitlement: Decodable {
        let id: String
        let productId: String
        let status: String
        let expiresAt: Date
    }

    let entitlement: Entitlement
    let entitlementToken: String
    let tokenExpiresAt: Date
}

private struct ErrorResponse: Decodable {
    let code: String
}

enum ManagedConnectionEntitlementAPIError: LocalizedError, Equatable {
    case invalidResponse
    case rejected(code: String?)
    case inactive

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L10n.text("ui.managed_subscription_server_invalid")
        case .inactive:
            return L10n.text("ui.managed_subscription_inactive")
        case .rejected(let code):
            switch code {
            case "expired":
                return L10n.text("ui.managed_subscription_expired")
            case "revoked":
                return L10n.text("ui.managed_subscription_revoked")
            case "unverified_transaction":
                return L10n.text("ui.managed_subscription_unverified")
            default:
                return L10n.text("ui.managed_subscription_server_rejected")
            }
        }
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
