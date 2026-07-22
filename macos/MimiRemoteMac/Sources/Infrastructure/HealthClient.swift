import Foundation

struct HealthClient: Sendable {
    var check: @Sendable (_ endpoint: String) async -> Bool
}

extension HealthClient {
    static let live = HealthClient { endpoint in
        guard var components = URLComponents(string: endpoint),
              let port = components.port
        else {
            return false
        }
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/healthz"
        components.query = nil
        guard let url = components.url else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
