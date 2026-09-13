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
        let probeSnapshot = captureConnectionProbeSnapshot()
        do {
            _ = try await validateConnection(
                endpoint: endpoint,
                token: token,
                route: route,
                affectsConnectionStatus: affectsConnectionStatus
            )
        } catch {
            guard affectsConnectionStatus else { return }
            // 页面切走导致的取消不是连接失败：把探测前的状态放回去，
            // 不能让设备页显示「连接失败」外加一条「已取消」。
            if Self.isConnectionProbeCancellation(error) {
                restoreConnectionStatusAfterCancelledProbe(probeSnapshot)
                return
            }
            connectionStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    /// 会话 WebSocket 真正连上时调用。这是比探测更强的「已连接」证据，用来覆盖冷启动首个
    /// preflight 在隧道建好前留下的失败值。凭据失效等终态不能被一条迟到的连接改写。
    func markLiveConnectionEstablished() {
        guard connectionTermination == nil else { return }
        if case .connected = connectionStatus { return }
        connectionStatus = .connected(activeConnectionRoute.statusTitle)
        lastError = nil
    }

    /// 进入探测态前记住原状态。探测被取消只说明这次没做完，不是「未连接」的结论；
    /// 否则「我」页的 task 被 Tab 切换打断后，设备页会一直显示「未连接」，直到下一次探测。
    func captureConnectionProbeSnapshot() -> ConnectionProbeSnapshot {
        ConnectionProbeSnapshot(status: connectionStatus, lastError: lastError)
    }

    func restoreConnectionStatusAfterCancelledProbe(_ snapshot: ConnectionProbeSnapshot) {
        // 探测前若已在转圈，说明另一条验证正在跑，让它自己下结论，不在这里改写。
        if case .testing = snapshot.status { return }
        connectionStatus = snapshot.status
        lastError = snapshot.lastError
    }

    static func isConnectionProbeCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }
}
