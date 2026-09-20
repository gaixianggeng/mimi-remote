import Foundation

extension AppStore {
    static func defaultConnectionRouteProbe(
        endpoint: String,
        token: String,
        timeout: TimeInterval,
        session: URLSession = .shared,
        transportFactory: @escaping () -> CodexAppServerTransport = { URLSessionCodexAppServerTransport() }
    ) async throws {
        let config = try await AgentAPIClient(endpoint: endpoint, token: token, session: session)
            .appServerConfig(timeout: timeout)
        try await validateAvailableGateway(
            endpoint: endpoint,
            token: token,
            timeout: timeout,
            config: config,
            transportFactory: transportFactory
        )
    }

    static func validateAvailableGateway(
        endpoint: String,
        token: String,
        timeout: TimeInterval,
        config: CodexAppServerConfigResponse,
        transportFactory: @escaping () -> CodexAppServerTransport
    ) async throws {
        guard let runtimeProvider = AppServerRuntimeBundle.preferredAvailableRuntimeProvider(in: config) else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        let runtime = CodexAppServerSessionRuntime(
            endpoint: endpoint,
            token: token,
            runtimeProvider: runtimeProvider,
            transportFactory: transportFactory,
            requestTimeout: timeout,
            configProvider: { config }
        )
        // 连通性检查只建立无名短连接，不登记 thread，也不复用正式 RuntimeBundle。
        try await runtime.validateDirectGateway()
    }

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
    /// 必须紧挨在探测把状态置为 .testing 之前调用：取消时要求期间只发生过这一次写入。
    func captureConnectionProbeSnapshot() -> ConnectionProbeSnapshot {
        ConnectionProbeSnapshot(
            status: connectionStatus,
            lastError: lastError,
            revision: connectionStatusRevision,
            hostScope: activeHostScope
        )
    }

    func restoreConnectionStatusAfterCancelledProbe(_ snapshot: ConnectionProbeSnapshot) {
        // 探测前若已在转圈，说明另一条验证正在跑，让它自己下结论，不在这里改写。
        if case .testing = snapshot.status { return }
        // 状态仍是这次探测写下的 .testing 才放回；等待期间 WebSocket 已连上、另一条探测已下结论
        // 或已经切换电脑时，保留那个更新的结果。
        guard case .testing = connectionStatus,
              connectionStatusRevision == snapshot.revision &+ 1,
              activeHostScope == snapshot.hostScope else { return }
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
