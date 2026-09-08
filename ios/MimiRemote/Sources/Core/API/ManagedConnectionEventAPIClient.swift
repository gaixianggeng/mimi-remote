import Foundation

enum ManagedConnectionEventPath: String, Codable, Equatable, Sendable {
    case direct
    case peerRelay = "peer_relay"
    case derp
    case unknown

    init(tailcatPath: String) {
        switch tailcatPath.lowercased() {
        case "direct": self = .direct
        case "peer-relay", "peer_relay": self = .peerRelay
        case "derp": self = .derp
        default: self = .unknown
        }
    }
}

enum ManagedConnectionEventDurationBucket: String, Codable, Equatable, Sendable {
    case underOneSecond = "under_1s"
    case oneToThreeSeconds = "1s_to_3s"
    case threeToEightSeconds = "3s_to_8s"
    case eightToTenSeconds = "8s_to_10s"
    case overTenSeconds = "over_10s"

    init(milliseconds: Int) {
        switch max(0, milliseconds) {
        case ..<1_000: self = .underOneSecond
        case ..<3_000: self = .oneToThreeSeconds
        case ..<8_000: self = .threeToEightSeconds
        case ..<10_000: self = .eightToTenSeconds
        default: self = .overTenSeconds
        }
    }
}

enum ManagedConnectionEventErrorCategory: String, Codable, Equatable, Sendable {
    case none
    case network
    case timeout
    case authentication
    case policy
    case unknown

    init(error: Error?) {
        guard let error else {
            self = .none
            return
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                self = .timeout
            case .userAuthenticationRequired, .userCancelledAuthentication:
                self = .authentication
            case .appTransportSecurityRequiresSecureConnection:
                self = .policy
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .internationalRoamingOff, .networkConnectionLost, .notConnectedToInternet:
                self = .network
            default:
                self = .unknown
            }
            return
        }
        self = .unknown
    }
}

struct ManagedConnectionEvent: Encodable, Equatable, Sendable {
    let id: UUID
    let path: ManagedConnectionEventPath
    let succeeded: Bool
    let durationBucket: ManagedConnectionEventDurationBucket
    let errorCategory: ManagedConnectionEventErrorCategory
    let regionCode: String?
    let appVersion: String

    init(
        id: UUID = UUID(),
        path: ManagedConnectionEventPath,
        succeeded: Bool,
        durationMillis: Int,
        errorCategory: ManagedConnectionEventErrorCategory,
        regionCode: String?,
        appVersion: String
    ) {
        self.id = id
        self.path = path
        self.succeeded = succeeded
        durationBucket = ManagedConnectionEventDurationBucket(milliseconds: durationMillis)
        self.errorCategory = succeeded
            ? .none
            : (errorCategory == .none ? .unknown : errorCategory)
        self.regionCode = path == .derp
            ? Self.normalizedRegionCode(regionCode)
            : nil
        self.appVersion = appVersion.isEmpty ? "unknown" : appVersion
    }

    private static func normalizedRegionCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (2...12).contains(value.count),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return value
    }
}

protocol ManagedConnectionEventAPIClient: Sendable {
    func send(_ event: ManagedConnectionEvent, deviceToken: String) async throws
}

struct LiveManagedConnectionEventAPIClient: ManagedConnectionEventAPIClient {
    private let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "https://mimi.code89757.com")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func send(_ event: ManagedConnectionEvent, deviceToken: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/connection-events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(event)

        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

@MainActor
protocol ManagedConnectionEventReporting: AnyObject {
    func report(_ event: ManagedConnectionEvent) async
}

@MainActor
final class ManagedConnectionEventReporter: ManagedConnectionEventReporting {
    private let api: any ManagedConnectionEventAPIClient
    private let identityStore: any ManagedConnectionMobileIdentityStoring

    init(
        api: any ManagedConnectionEventAPIClient = LiveManagedConnectionEventAPIClient(),
        identityStore: any ManagedConnectionMobileIdentityStoring
    ) {
        self.api = api
        self.identityStore = identityStore
    }

    func report(_ event: ManagedConnectionEvent) async {
        guard let identity = try? identityStore.loadOrCreate(),
              identity.registeredDeviceID != nil else {
            return
        }
        // 遥测永远不影响连接结果，也不把服务端响应或设备凭据写入本地日志。
        try? await api.send(event, deviceToken: identity.deviceToken)
    }
}
