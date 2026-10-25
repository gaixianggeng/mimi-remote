import Foundation

/// 与最小推送服务之间的全部通信。
///
/// 设备用自己的 APNs Token 直接向 Provider 换取不透明 Push Ticket，再把 Ticket
/// 交给 agentd——agentd 因此从不接触原始 Device Token，Provider 也从不接触 agentd
/// 的访问 Token。两边都只拿到自己那一半。
struct PushProviderClient {
    /// 维护者运营的默认服务。默认流程只请求系统通知权限；自定义地址需单独确认。
    static let defaultBaseURL = "https://api.code89757.com/mimi-push"

    let baseURL: String
    private let session: URLSession

    init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    var host: String? { URL(string: baseURL)?.host }

    var isOfficialService: Bool {
        host == URL(string: Self.defaultBaseURL)?.host
    }

    struct Ticket: Equatable, Sendable {
        let value: String
        let expiresAt: Date
    }

    /// Ticket 用途（#830）。通知 Ticket 不带 `kind`，请求与旧版推送服务完全一致；
    /// Live Activity 的两类 Token 只有部署了阶段一的推送服务才认。
    enum TicketKind: String, Sendable {
        case notification
        case activityUpdate = "activity_update"
        case activityStart = "activity_start"
    }

    func issueTicket(
        deviceToken: String,
        installation: String,
        environment: PushEnvironment,
        kind: TicketKind = .notification
    ) async throws -> Ticket {
        struct Request: Encodable {
            let version = 1
            let environment: String
            let deviceToken: String
            let installation: String
            /// nil 时整个键省略（合成的 Encodable 对 Optional 用 encodeIfPresent）。
            let kind: String?

            enum CodingKeys: String, CodingKey {
                case version
                case environment
                case deviceToken = "device_token"
                case installation
                case kind
            }
        }
        struct Response: Decodable {
            let ticket: String
            let expiresAt: String

            enum CodingKeys: String, CodingKey {
                case ticket
                case expiresAt = "expires_at"
            }
        }
        let data = try await send(
            path: "/v1/ticket",
            body: Request(
                environment: environment.rawValue,
                deviceToken: deviceToken,
                installation: installation,
                kind: kind == .notification ? nil : kind.rawValue
            )
        )
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let expiry = Self.parseTimestamp(response.expiresAt)
        else {
            throw PushProviderError.malformedResponse
        }
        return Ticket(value: response.ticket, expiresAt: expiry)
    }

    /// 关闭开关等价于撤销：本地删除之外，还要让 Provider 把 Ticket ID 加进撤销表。
    func revokeTicket(_ ticket: String) async throws {
        struct Request: Encodable {
            let version = 1
            let ticket: String
        }
        _ = try await send(path: "/v1/ticket/revoke", body: Request(ticket: ticket))
    }

    private func send<Body: Encodable>(path: String, body: Body) async throws -> Data {
        guard let url = URL(string: baseURL + path), url.scheme == "https" else {
            // Device Token 只走 TLS。允许 http 就等于允许它在链路上被读走。
            throw PushProviderError.insecureEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PushProviderError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PushProviderError.rejected(status: http.statusCode)
        }
        return data
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

enum PushProviderError: Error, Equatable, LocalizedError {
    case insecureEndpoint
    case malformedResponse
    case rejected(status: Int)

    var errorDescription: String? {
        switch self {
        case .insecureEndpoint:
            return L10n.text("ui.push_provider_requires_https")
        case .malformedResponse:
            return L10n.text("ui.push_provider_response_invalid")
        case .rejected(let status):
            return L10n.format("ui.push_provider_rejected_value", status)
        }
    }
}
