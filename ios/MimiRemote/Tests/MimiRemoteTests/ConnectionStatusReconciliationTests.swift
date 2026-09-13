import XCTest
@testable import MimiRemote

/// 设备页显示的连接状态必须收敛到事实：探测被取消不算「未连接」，
/// 会话通道连上就是「已连接」，首页线路行只写直连/中转和延迟。
@MainActor
final class ConnectionStatusReconciliationTests: XCTestCase {
    func testCancelledPreflightKeepsPreviousStatusInsteadOfIdle() async throws {
        let suiteName = "ConnectionStatusReconciliationTests.CancelledPreflight.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 5,
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in
                // 探测挂住直到被取消，模拟「我」页的 task 被 Tab 切换打断。
                try await Task.sleep(for: .seconds(30))
            }
        )
        store.endpoint = "http://100.64.0.1:8787"
        store.token = "test-token"
        store.connectionStatus = .failed("冷启动首个探测失败")
        store.lastError = "冷启动首个探测失败"

        let preflight = Task { await store.preflightConnection() }
        try await waitUntil { store.connectionStatus == .testing }
        preflight.cancel()
        let connected = await preflight.value

        XCTAssertFalse(connected)
        XCTAssertEqual(store.connectionStatus, .failed("冷启动首个探测失败"), "取消不是「未连接」的结论，应放回探测前的状态")
        XCTAssertEqual(store.lastError, "冷启动首个探测失败")
    }

    func testCancelledAutomaticConnectionTestKeepsConnectedStatus() async throws {
        let store = makeIsolatedAppStore()
        store.endpoint = "http://100.64.0.1:8787"
        store.token = "test-token"
        store.connectionStatus = .connected("Tailscale")

        // 任务先取消再执行：URLSession 会以 cancelled 结束，不能被当成连接失败发布。
        let connectionTest = Task { await store.testConnection(endpoint: store.endpoint, token: store.token) }
        connectionTest.cancel()
        await connectionTest.value

        XCTAssertEqual(store.connectionStatus, .connected("Tailscale"))
        XCTAssertNil(store.lastError)
    }

    func testLiveWebSocketConnectionPromotesStaleFailedStatus() async throws {
        let project = makeProject(id: "proj_status_reconciliation")
        let running = makeSession(
            id: "sess_status_reconciliation",
            projectID: project.id,
            title: "会话",
            status: "running",
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        appStore.connectionStatus = .failed("冷启动首个探测失败")
        appStore.lastError = "冷启动首个探测失败"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        XCTAssertEqual(
            appStore.connectionStatus,
            .connected(ActiveConnectionRoute.configured.statusTitle),
            "真实会话通道连上后，探测遗留的失败值必须被覆盖"
        )
        XCTAssertNil(appStore.lastError)
    }

    func testLiveConnectionDoesNotOverrideCredentialTermination() {
        let store = makeIsolatedAppStore()
        store.markCredentialsInvalid()

        store.markLiveConnectionEstablished()

        XCTAssertEqual(store.connectionTermination, .credentialsInvalid)
        guard case .failed = store.connectionStatus else {
            return XCTFail("凭据失效是终态，不能被迟到的连接改写为已连接")
        }
    }

    func testBriefRouteSummaryOnlyNamesDirectOrRelayWithLatency() {
        let relay = makeDiagnostic(path: "derp", latencyMillis: 42, derpRegionCode: "sha", requestLatencyMillis: 180)
        XCTAssertEqual(
            ConnectionRouteFormatting.briefSummary(relay),
            "\(L10n.text("ui.route_path_relay")) · 42 ms"
        )

        let peerRelay = makeDiagnostic(path: "peer-relay", latencyMillis: 30, requestLatencyMillis: 90)
        XCTAssertEqual(
            ConnectionRouteFormatting.briefSummary(peerRelay),
            "\(L10n.text("ui.route_path_relay")) · 30 ms"
        )

        let direct = makeDiagnostic(path: "direct", latencyMillis: 8, requestLatencyMillis: 40)
        XCTAssertEqual(
            ConnectionRouteFormatting.briefSummary(direct),
            "\(L10n.text("ui.route_path_direct")) · 8 ms"
        )

        let httpFailed = makeDiagnostic(path: "direct", latencyMillis: 8, requestSucceeded: false)
        XCTAssertEqual(
            ConnectionRouteFormatting.briefSummary(httpFailed),
            "\(L10n.text("ui.route_path_direct")) · \(L10n.text("ui.tailcat_request_failed"))"
        )

        let pathFailed = makeDiagnostic(path: "failed", succeeded: false, requestSucceeded: false)
        XCTAssertEqual(
            ConnectionRouteFormatting.briefSummary(pathFailed),
            L10n.text("ui.route_probe_failed")
        )
    }

    func testBriefFallbackRouteSummaryUsesHTTPLatency() {
        let relay = FallbackRouteProbe(
            checkedAt: Date(),
            pathKind: .peerRelay,
            relayRegion: nil,
            httpMillis: 65,
            succeeded: true
        )
        XCTAssertEqual(
            ConnectionRouteFormatting.briefSummary(relay),
            "\(L10n.text("ui.route_path_relay")) · 65 ms"
        )

        let unknownPath = FallbackRouteProbe(
            checkedAt: Date(),
            pathKind: .unknown,
            relayRegion: nil,
            httpMillis: 21,
            succeeded: true
        )
        XCTAssertEqual(ConnectionRouteFormatting.briefSummary(unknownPath), "21 ms")

        let failed = FallbackRouteProbe(
            checkedAt: Date(),
            pathKind: nil,
            relayRegion: nil,
            httpMillis: nil,
            succeeded: false
        )
        XCTAssertEqual(
            ConnectionRouteFormatting.briefSummary(failed),
            L10n.text("ui.route_probe_failed")
        )
    }

    private func makeDiagnostic(
        path: String,
        latencyMillis: Int? = nil,
        derpRegionCode: String? = nil,
        succeeded: Bool = true,
        requestLatencyMillis: Int? = nil,
        requestSucceeded: Bool? = true
    ) -> TailcatPathDiagnostic {
        TailcatPathDiagnostic(
            id: UUID(),
            checkedAt: Date(),
            path: path,
            latencyMillis: latencyMillis,
            derpRegionCode: derpRegionCode,
            succeeded: succeeded,
            requestLatencyMillis: requestLatencyMillis,
            requestSucceeded: requestSucceeded
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                return XCTFail("等待条件超时")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
