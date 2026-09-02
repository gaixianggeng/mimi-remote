import Foundation

extension AppStore {
    func testConnection(
        endpoint: String,
        token: String,
        route: ConnectionTestRoute = .tailscale,
        affectsConnectionStatus: Bool = true
    ) async {
#if DEBUG
        if debugLaunchConfiguration.applyStoreScreenshotConnectionState(
            status: &connectionStatus,
            lastError: &lastError
        ) {
            return
        }
#endif
        do {
            _ = try await validateConnection(
                endpoint: endpoint,
                token: token,
                route: route,
                affectsConnectionStatus: affectsConnectionStatus
            )
        } catch {
            if affectsConnectionStatus {
                connectionStatus = .failed(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
    }
}
