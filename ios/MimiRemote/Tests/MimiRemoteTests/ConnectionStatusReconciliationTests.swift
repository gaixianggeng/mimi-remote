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

    func testCancelledPreflightKeepsNewerLiveConnection() async throws {
        let suiteName = "ConnectionStatusReconciliationTests.CancelledAfterLive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 5,
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in
                try await Task.sleep(for: .seconds(30))
            }
        )
        store.endpoint = "http://100.64.0.1:8787"
        store.token = "test-token"
        store.connectionStatus = .failed("冷启动首个探测失败")
        store.lastError = "冷启动首个探测失败"

        let preflight = Task { await store.preflightConnection() }
        try await waitUntil { store.connectionStatus == .testing }
        // 探测还挂着时会话通道先连上：这是更新的结论，取消探测不能把它改回旧的失败值。
        store.markLiveConnectionEstablished()
        preflight.cancel()
        _ = await preflight.value

        XCTAssertEqual(store.connectionStatus, .connected(ActiveConnectionRoute.configured.statusTitle))
        XCTAssertNil(store.lastError)
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

    // MARK: - 配对成功后不再沿用上一轮配对失败（#730）

    private static let expiredTicketLink = URL(
        string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787"
            + "&issued_at=2020-01-01T00%3A00%3A00Z&expires_at=2020-01-01T00%3A10%3A00Z&pair_sig=test-signature"
    )!
    private static let tokenLink = URL(
        string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=test-token"
    )!
    private static let secondComputerLink = URL(
        string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.2%3A8787&token=second-token"
    )!

    func testSuccessfulPreparedChangeReplacesStaleFailedStatus() async throws {
        let (store, appStore) = makePairingStores()
        appStore.connectionStatus = .failed("旧错误")
        appStore.lastError = "旧错误"

        do {
            try await store.performPreparedConnectionChange { throw URLError(.cannotConnectToHost) }
            XCTFail("准备失败必须抛出")
        } catch {}
        XCTAssertEqual(appStore.connectionStatus, .failed("旧错误"), "准备失败照旧回滚到准备前的展示状态")

        try await store.performPreparedConnectionChange {
            try await appStore.prepareConnectionSettings(endpoint: "http://100.64.0.1:8787", token: "new-token")
        }

        XCTAssertEqual(appStore.connectionStatus, .connected(ActiveConnectionRoute.configured.statusTitle))
        XCTAssertNil(appStore.lastError)
        XCTAssertEqual(sessionListPresentation(store, appStore), .needsWorkspace, "不能再整页显示上一轮的「会话服务不可用」")
    }

    func testExternalPairingLinkSucceedingAfterFailureShowsConnectedSessionList() async throws {
        let (store, appStore) = makePairingStores()

        await openPairingLinkLikeApp(Self.expiredTicketLink, store: store, appStore: appStore)
        XCTAssertEqual(
            sessionListPresentation(store, appStore),
            .runtimeUnavailable(PairingLinkError.expired.localizedDescription),
            "前置条件：失败的外部链接留下全局 .failed"
        )

        await openPairingLinkLikeApp(Self.tokenLink, store: store, appStore: appStore)

        XCTAssertEqual(appStore.connectionProfiles.count, 1)
        XCTAssertEqual(appStore.connectionStatus, .connected(ActiveConnectionRoute.configured.statusTitle))
        XCTAssertNil(appStore.lastError)
        XCTAssertEqual(sessionListPresentation(store, appStore), .needsWorkspace)
    }

    func testAddComputerScanSucceedingAfterFailureShowsConnectedSessionList() async throws {
        let (store, appStore) = makePairingStores()
        try await store.applyPairingURL(Self.tokenLink)
        let firstProfileID = try XCTUnwrap(appStore.activeConnectionProfileID)

        await scanAddComputerLinkLikeSettings(Self.expiredTicketLink, store: store, appStore: appStore)
        XCTAssertEqual(appStore.activeConnectionProfileID, firstProfileID)
        guard case .failed = appStore.connectionStatus else {
            return XCTFail("前置条件：扫码失败留下全局 .failed：\(appStore.connectionStatus)")
        }

        await scanAddComputerLinkLikeSettings(Self.secondComputerLink, store: store, appStore: appStore)

        XCTAssertEqual(appStore.connectionProfiles.count, 2)
        XCTAssertNotEqual(appStore.activeConnectionProfileID, firstProfileID)
        XCTAssertEqual(appStore.connectionStatus, .connected(ActiveConnectionRoute.configured.statusTitle))
        XCTAssertNil(appStore.lastError)
        XCTAssertEqual(sessionListPresentation(store, appStore), .needsWorkspace)
    }

    /// 按 `MimiRemoteApp.onOpenURL` 的流程：成功后等首屏，失败时写入全局 .failed。
    private func openPairingLinkLikeApp(_ url: URL, store: SessionStore, appStore: AppStore) async {
        do {
            let wasConfigured = appStore.isConfigured
            _ = try await store.applyPairingURL(url)
            _ = await store.refreshAfterConnectionCommit(maxWait: wasConfigured ? 10 : 45)
        } catch {
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
        }
    }

    /// 按设置页「添加电脑」扫码（`applyScannedConnection`）的流程：成功后等首屏，失败时写入全局 .failed。
    private func scanAddComputerLinkLikeSettings(_ url: URL, store: SessionStore, appStore: AppStore) async {
        do {
            _ = try await store.addConnectionProfile(pairingURL: url, displayName: "")
            _ = await store.refreshAfterConnectionCommit(maxWait: 10)
        } catch {
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
        }
    }

    private func sessionListPresentation(_ store: SessionStore, _ appStore: AppStore) -> SessionListPresentationState {
        SessionListPresentationState.resolve(
            hasVisibleSessions: !store.sessions.isEmpty,
            hasOpenedWorkspace: !store.sidebarProjects.isEmpty,
            isLoading: store.isLoading,
            isSearching: false,
            isFiltering: false,
            isNetworkUnavailable: store.isNetworkUnavailable,
            errorMessage: store.errorMessage,
            connectionStatus: appStore.connectionStatus,
            hasLoadedWorkspaceCatalog: store.loadedWorkspaceCatalogScope == appStore.activeHostScope,
            isEstablishingConnection: store.isEstablishingConnection
        )
    }

    private func makePairingStores() -> (SessionStore, AppStore) {
        let suiteName = "ConnectionStatusReconciliationTests.Pairing.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建隔离测试 UserDefaults suite: \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )
        let client = MockSessionStoreClient(projects: [makeProject(id: "proj_new_pairing")], sessions: [])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )
        return (store, appStore)
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
