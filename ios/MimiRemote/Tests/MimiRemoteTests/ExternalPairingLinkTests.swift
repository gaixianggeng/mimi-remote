import XCTest
@testable import MimiRemote

/// 系统相机扫码等外部配对链接由 App 层配对。还没有任何电脑时，首次配对页不读全局
/// `lastError`，只能靠 `pairingLinkAttempt` 看到进度和失败原因（#728）。
@MainActor
final class ExternalPairingLinkTests: XCTestCase {
    private static let expiredTicketLink = URL(
        string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787"
            + "&issued_at=2020-01-01T00%3A00%3A00Z&expires_at=2020-01-01T00%3A10%3A00Z&pair_sig=test-signature"
    )!
    private static let tokenLink = URL(
        string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=test-token"
    )!

    func testFirstConnectionFailurePublishesReasonForFirstConnectionPage() async throws {
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in })

        await store.openPairingLink(Self.expiredTicketLink)

        let expected = PairingLinkError.expired.localizedDescription
        XCTAssertEqual(store.pairingLinkAttempt, .failed(expected), "首次配对页要拿到原始原因，再按本页规则友好化")
        XCTAssertEqual(appStore.lastError, expected, "全局错误照旧记录，已有电脑的页面还在读它")
    }

    func testFirstConnectionReportsConnectingUntilPreparationFails() async throws {
        let gate = RouteProbeGate()
        let (store, _) = makeStores(routeProbe: { _, _, _ in try await gate.wait() })

        let opening = Task { await store.openPairingLink(Self.tokenLink) }
        try await waitUntil { gate.isWaiting }
        XCTAssertEqual(store.pairingLinkAttempt, .connecting, "验证进行中，首次配对页要能禁用按钮并显示正在连接")

        gate.fail(URLError(.cannotConnectToHost))
        await opening.value

        guard case .failed = store.pairingLinkAttempt else {
            return XCTFail("验证失败后必须交出失败原因，而不是停在连接中：\(store.pairingLinkAttempt)")
        }
    }

    func testFirstConnectionSuccessReturnsToIdle() async throws {
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in })

        await store.openPairingLink(Self.tokenLink)

        XCTAssertEqual(store.pairingLinkAttempt, .idle)
        XCTAssertEqual(appStore.connectionProfiles.count, 1)
    }

    func testCancelledPairingLinkRestoresPriorStateWithoutReportingFailure() async throws {
        // 1) 首次配对进行中被任务取消：不写 .failed / lastError / pairingLinkAttempt = .failed，
        //    进度回退到 .idle，路由恢复进入前状态。
        let gate = RouteProbeGate()
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in try await gate.wait() })

        let opening = Task { await store.openPairingLink(Self.tokenLink) }
        try await waitUntil { gate.isWaiting }
        XCTAssertEqual(store.pairingLinkAttempt, .connecting)

        opening.cancel()
        await opening.value

        XCTAssertEqual(appStore.connectionStatus, .idle, "取消配对不得写入 .failed")
        XCTAssertNil(appStore.lastError, "取消配对不得写入 lastError")
        XCTAssertEqual(store.pairingLinkAttempt, .idle, "取消后应把 .connecting 恢复为 .idle")
        XCTAssertNil(store.lastPairingLinkRoute, "取消后应恢复进入前的路由状态")

        // 2) 底层传输以 URLError.cancelled 结束同样视为取消，绝不展示原始取消文本。
        let (urlCancelStore, urlCancelAppStore) = makeStores(routeProbe: { _, _, _ in
            throw URLError(.cancelled)
        })
        await urlCancelStore.openPairingLink(Self.tokenLink)
        XCTAssertEqual(urlCancelAppStore.connectionStatus, .idle)
        XCTAssertNil(urlCancelAppStore.lastError)
        XCTAssertEqual(urlCancelStore.pairingLinkAttempt, .idle)
        XCTAssertNil(urlCancelStore.lastPairingLinkRoute)

        // 3) 场景切回后台导致 beginPreparedConnectionChange 抛出 CancellationError：同样恢复先前状态。
        let (bgStore, bgAppStore) = makeStores(routeProbe: { _, _, _ in })
        bgStore.suspendForBackground()
        await bgStore.openPairingLink(Self.tokenLink, foregroundWaitTimeoutNanoseconds: 10_000_000)
        XCTAssertEqual(bgAppStore.connectionStatus, .idle)
        XCTAssertNil(bgAppStore.lastError)
        XCTAssertEqual(bgStore.pairingLinkAttempt, .idle)
        XCTAssertNil(bgStore.lastPairingLinkRoute)

        // 4) 已有已连接档案时取消外部链接配对：保留原有已连接状态，不覆盖 lastError。
        let connectedGate = RouteProbeGate()
        let (connectedStore, connectedAppStore) = makeStores(routeProbe: { _, _, _ in try await connectedGate.wait() })
        _ = try await connectedAppStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.30:8787",
            token: "existing-token"
        ))
        connectedAppStore.markLiveConnectionEstablished()
        let previousStatus = connectedAppStore.connectionStatus
        XCTAssertTrue(previousStatus.isConnected)

        let connectedOpening = Task { await connectedStore.openPairingLink(Self.tokenLink) }
        try await waitUntil { connectedGate.isWaiting }
        connectedOpening.cancel()
        await connectedOpening.value

        XCTAssertEqual(connectedAppStore.connectionStatus, previousStatus)
        XCTAssertNil(connectedAppStore.lastError)
        XCTAssertEqual(connectedStore.pairingLinkAttempt, .idle)
        XCTAssertNil(connectedStore.lastPairingLinkRoute)
    }

    func testSharedCancellationClassifierCoversAllCancellationTypes() async {
        XCTAssertTrue(isCancellationError(CancellationError()))
        XCTAssertTrue(isCancellationError(URLError(.cancelled)))
        XCTAssertTrue(isCancellationError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ))
        XCTAssertTrue(isCancellationError(HarnessTransportError.cancelled))
        XCTAssertTrue(isCancellationError(CodexAppServerConnectionError.transport(URLError(.cancelled))))
        XCTAssertTrue(isCancellationError(CodexAppServerConnectionError.transport(CancellationError())))

        XCTAssertFalse(isCancellationError(URLError(.cannotConnectToHost)))
        XCTAssertFalse(isCancellationError(URLError(.timedOut)))
        XCTAssertFalse(isCancellationError(CodexAppServerConnectionError.transport(
            AgentAPIError.credentialsInvalid(status: 401)
        )))

        // 即使当前任务已取消，真实非取消错误也绝不能被判成取消。
        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertTrue(Task.isCancelled)
            XCTAssertFalse(isCancellationError(AgentAPIError.credentialsInvalid(status: 401)))
            XCTAssertFalse(isCancellationError(PairingLinkError.expired))
            XCTAssertTrue(isCancellationError(CancellationError()))
        }
        await cancelledTask.value
    }

    /// 真实失败（凭据被拒、短票过期）与任务取消竞态时，不得被裸 `Task.isCancelled` 改写成 CancellationError。
    func testRealFailureWhileTaskCancelledStillSurfacesInsteadOfConvertingToCancellation() async throws {
        // 1) performPreparedConnectionChange：任务已取消但 prepare 返回 401 凭据失效，仍原样抛出。
        let credGate = ControlledFailureGate()
        let (credStore, _) = makeStores(routeProbe: { _, _, _ in })
        let credTask = Task { @MainActor in
            try await credStore.performPreparedConnectionChange {
                try await credGate.waitIgnoringCancellation()
                return PreparedConnectionSettings(endpoint: "http://100.64.0.1:8787", token: "bad")
            }
        }
        try await waitUntil { credGate.isWaiting }
        credTask.cancel()
        credGate.fail(AgentAPIError.credentialsInvalid(status: 401))
        do {
            _ = try await credTask.value
            XCTFail("真实凭据失效不得吞掉或成功")
        } catch let error as AgentAPIError {
            XCTAssertTrue(error.invalidatesCredentials, "应保留原始 401 凭据失效，而不是改写成 CancellationError")
        } catch {
            XCTFail("预期 AgentAPIError.credentialsInvalid，实际是 \(error)")
        }

        // 2) openPairingLink：任务已取消但底层返回过期的配对短票，页面仍收到真实过期反馈。
        let ticketGate = ControlledFailureGate()
        let (ticketStore, ticketAppStore) = makeStores(routeProbe: { _, _, _ in
            try await ticketGate.waitIgnoringCancellation()
        })
        let expiredBody = Data(
            #"{"ok":false,"error":{"code":"pair_ticket_expired","step":"network_any","message":"expired","fix":{"kind":"retry"}}}"#.utf8
        )
        let expiredError = PairingOnboardingAPIError(
            status: 401,
            mapped: PairingErrorMapper.mapHTTPResponse(
                data: expiredBody,
                statusCode: 401,
                contentType: PairingErrorMapper.acceptMediaType,
                varyHeader: PairingErrorMapper.expectedVaryHeaderValue
            ),
            contentType: PairingErrorMapper.acceptMediaType,
            varyHeader: PairingErrorMapper.expectedVaryHeaderValue
        )
        let opening = Task { await ticketStore.openPairingLink(Self.tokenLink) }
        try await waitUntil { ticketGate.isWaiting }
        opening.cancel()
        ticketGate.fail(expiredError)
        await opening.value

        XCTAssertEqual(ticketStore.lastPairingOnboardingError?.code, "pair_ticket_expired")
        XCTAssertEqual(ticketAppStore.lastError, expiredError.userFacingMessage)
        XCTAssertEqual(ticketStore.pairingLinkAttempt, .failed(expiredError.userFacingMessage))
    }

    /// 生产快速路径中 WebSocket `initialized` 发送因取消失败并被包装进 `CodexAppServerConnectionError.transport`：
    /// 首轮取消后不得重试握手，且 `openPairingLink` 必须按取消回滚而不是写入 `.failed`。
    func testWrappedTransportCancellationOnInitializedSendStopsHandshakeRetryWithoutReportingFailure() async throws {
        let suiteName = "ExternalPairingLinkTests.WrappedCancel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingFastPathStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let project = AgentProject(id: "fast-cancel", name: "Fast", path: "/tmp/fast-cancel")
        let configData = try JSONEncoder().encode(makeDirectAppServerConfig(project: project))
        let versionData = try JSONSerialization.data(withJSONObject: [
            "name": "agentd",
            "version": "test",
            "installation_id": "inst-fast-cancel",
            "platform": "macos",
            "protocol_revision": 2,
            "minimum_client_protocol_revision": 1
        ])
        PairingFastPathStubURLProtocol.configure { request in
            switch request.url?.path {
            case "/api/version":
                return (200, "application/json", versionData)
            case "/api/app-server/config":
                return (200, "application/json", configData)
            default:
                return (404, "application/json", Data("{}".utf8))
            }
        }
        defer { PairingFastPathStubURLProtocol.reset() }

        let transportPool = InitializedCancelTransportPool()
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            agentAPISession: session,
            gatewayTransportFactory: { transportPool.makeTransport() }
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: [], messagesResult: []) },
            webSocketFactory: { MockWebSocketClient() },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.openPairingLink(Self.tokenLink)

        XCTAssertEqual(transportPool.createdCount, 1, "首次握手收到包装取消后不得再重试第二次 WebSocket 握手")
        XCTAssertEqual(appStore.connectionStatus, .idle, "包装传输取消不得写入 .failed")
        XCTAssertNil(appStore.lastError, "包装传输取消不得写入原始取消文案")
        XCTAssertEqual(store.pairingLinkAttempt, .idle)
        XCTAssertNil(store.lastPairingLinkRoute)
        XCTAssertTrue(appStore.connectionProfiles.isEmpty)
    }

    /// 含 DNS 与 IP 双候选的配对链接：DNS 候选显式返回 `URLError.cancelled` 时必须立即停止，
    /// 不得继续尝试 IP 候选，也不得提交配对或覆盖成失败。
    func testCancelledDNSCandidateStopsBeforeTryingIPCandidate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalPairingClaimStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 200,
            contentType: "application/json",
            vary: nil,
            body: #"{"endpoint":"http://100.64.0.1:8787","token":"claimed-token","tailscale_dns_name":"mac.tailnet.ts.net"}"#
        )
        var probedEndpoints: [String] = []
        let (store, appStore) = makeStores(
            routeProbe: { endpoint, _, _ in
                probedEndpoints.append(endpoint)
                if endpoint.contains("mac.tailnet.ts.net") {
                    throw URLError(.cancelled)
                }
            },
            agentAPISession: session
        )
        let liveTicketURL = try XCTUnwrap(URL(
            string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787"
                + "&issued_at=2026-07-23T10%3A00%3A00Z&expires_at=4102444800&pair_sig=test-sig"
        ))

        await store.openPairingLink(liveTicketURL)

        XCTAssertEqual(probedEndpoints, ["http://mac.tailnet.ts.net:8787"], "DNS 候选显式取消后不得继续落到 IP 候选")
        XCTAssertTrue(appStore.connectionProfiles.isEmpty, "取消后不得提交配对")
        XCTAssertEqual(appStore.connectionStatus, .idle)
        XCTAssertNil(appStore.lastError)
        XCTAssertEqual(store.pairingLinkAttempt, .idle)
        XCTAssertNil(store.lastPairingLinkRoute)
    }

    /// 两条同路由外部链接先后触发：较早那条被取消回滚时，绝不能清掉较新同路由尝试的 `.connecting` 进度与路由。
    func testOlderCancelledSameRoutePairingLinkDoesNotClearNewerSameRouteProgress() async throws {
        let gate = RouteProbeGate()
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in try await gate.wait() })
        store.suspendForBackground()

        // 尝试 1 停在等待前台恢复，占据 .tailscale 路由与 .connecting 进度。
        let older = Task {
            await store.openPairingLink(Self.tokenLink, foregroundWaitTimeoutNanoseconds: 2_000_000_000)
        }
        try await waitUntil { store.pairingLinkAttempt == .connecting }

        // 尝试 2 以相同路由接管展示所有权，同样等待前台恢复。
        let newer = Task {
            await store.openPairingLink(Self.tokenLink, foregroundWaitTimeoutNanoseconds: 2_000_000_000)
        }
        try await waitUntil { store.foregroundResumeWaiters.count == 2 }
        XCTAssertEqual(store.pairingLinkAttempt, .connecting)
        XCTAssertEqual(store.lastPairingLinkRoute, .tailscale)

        // 取消旧尝试 1：其回滚必须按 token 校验所有权，不得清掉新同路由尝试 2 的进度与路由。
        older.cancel()
        await older.value
        XCTAssertEqual(store.pairingLinkAttempt, .connecting, "旧尝试取消不得把新同路由尝试清成 .idle")
        XCTAssertEqual(store.lastPairingLinkRoute, .tailscale, "旧尝试取消不得清掉新同路由尝试的路由")

        // 恢复前台后只有新尝试 2 进入 routeProbe 并完成配对。
        await store.resumeFromForeground()
        try await waitUntil { gate.isWaiting }
        gate.succeed()
        await newer.value
        XCTAssertEqual(store.pairingLinkAttempt, .idle)
        XCTAssertEqual(appStore.connectionProfiles.count, 1)
    }

    /// 首次配对页此前已展示失败（且页面消费了 `.failed` 并将 `pairingLinkAttempt` 置回 `.idle`），
    /// 重试被取消后必须恢复先前的可见错误、路由与结构化引导，而不是留下空白错误行。
    func testCancelledPairingRetryPreservesPreviousVisibleErrorAndMetadata() async throws {
        let lanLink = try XCTUnwrap(URL(
            string: "mimiremote://pair?endpoint=http%3A%2F%2F192.168.1.20%3A8787&token=test-token"
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalPairingClaimStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 401,
            contentType: "application/vnd.mimi.onboarding.v1+json",
            vary: "Accept",
            body: #"{"ok":false,"error":{"code":"pair_ticket_expired","step":"network_any","message":"expired","fix":{"kind":"retry"}}}"#
        )
        let retryGate = RouteProbeGate()
        let (store, appStore) = makeStores(
            routeProbe: { _, _, _ in try await retryGate.wait() },
            agentAPISession: session
        )
        let expiredTicketURL = try XCTUnwrap(URL(
            string: "mimiremote://pair?endpoint=http%3A%2F%2F192.168.1.20%3A8787"
                + "&issued_at=2026-07-23T10%3A00%3A00Z&expires_at=4102444800&pair_sig=test-sig"
        ))

        // 1) 首轮失败，记录错误、路由与结构化引导。
        await store.openPairingLink(expiredTicketURL)
        let expectedError = L10n.text("ui.pairing_onboarding_pair_ticket_expired")
        XCTAssertEqual(store.pairingLinkAttempt, .failed(expectedError))
        XCTAssertEqual(store.lastPairingLinkRoute, .lan)
        XCTAssertEqual(store.lastPairingOnboardingError?.code, "pair_ticket_expired")
        XCTAssertEqual(appStore.lastError, expectedError)

        // 2) 模拟首次配对页消费 `.failed`（InitialConnectionSettingsSections.swift:385）。
        store.pairingLinkAttempt = .idle

        // 3) 发起同页重试并在连接中取消。
        let retry = Task { await store.openPairingLink(lanLink) }
        try await waitUntil { retryGate.isWaiting }
        XCTAssertEqual(store.pairingLinkAttempt, .connecting)

        retry.cancel()
        await retry.value

        XCTAssertEqual(store.pairingLinkAttempt, .failed(expectedError), "取消重试后必须重新发布先前错误，避免首次配对页错误行变空")
        XCTAssertEqual(store.lastPairingLinkRoute, .lan)
        XCTAssertEqual(store.lastPairingOnboardingError?.code, "pair_ticket_expired")
        XCTAssertEqual(appStore.lastError, expectedError)
        XCTAssertEqual(appStore.connectionStatus, .failed(expectedError))
    }

    func testConfiguredAppLeavesFirstConnectionPageStateUntouched() async throws {
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in })
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.30:8787",
            token: "existing-token"
        ))

        await store.openPairingLink(Self.expiredTicketLink)

        XCTAssertEqual(store.pairingLinkAttempt, .idle, "已有电脑时由设备页显示全局错误，首次配对页的状态不能残留")
        XCTAssertEqual(appStore.lastError, PairingLinkError.expired.localizedDescription)
    }

    /// 忘记当前电脑后只剩其它电脑时，设备页没有当前电脑卡片显示全局错误，
    /// 外部链接配对失败只能经 `pairingLinkAttempt` 交给页面，否则用户看不到任何反馈（#959）。
    func testFailureWithoutCurrentComputerIsPublishedEvenWhenOtherComputersAreSaved() async throws {
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in })
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.30:8787",
            token: "other-token"
        ))
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.31:8787",
            token: "current-token",
            profileTarget: .newProfile(id: UUID().uuidString, displayName: "Current")
        ))
        try await store.clearCurrentConnectionProfile()
        XCTAssertNil(appStore.activeConnectionProfile)
        XCTAssertFalse(appStore.connectionProfiles.isEmpty)

        await store.openPairingLink(Self.expiredTicketLink)

        XCTAssertEqual(store.pairingLinkAttempt, .failed(PairingLinkError.expired.localizedDescription))
        XCTAssertEqual(store.lastPairingLinkRoute, .tailscale)
    }

    func testFailedLANPairingLinkRecordsLANRouteAndClearsAfterSuccess() async throws {
        let lanLink = URL(
            string: "mimiremote://pair?endpoint=http%3A%2F%2F192.168.1.20%3A8787&token=test-token"
        )!
        var shouldFail = true
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in
            if shouldFail {
                throw URLError(.cannotConnectToHost)
            }
        })

        await store.openPairingLink(lanLink)
        XCTAssertEqual(store.lastPairingLinkRoute, .lan)
        XCTAssertEqual(
            ConnectionFailureGuidance.friendlyMessage(
                from: try XCTUnwrap(appStore.lastError),
                route: store.lastPairingLinkRoute
            ),
            L10n.text("ui.connection_failure_guidance_lan")
        )

        shouldFail = false
        await store.openPairingLink(lanLink)
        XCTAssertNil(store.lastPairingLinkRoute)
    }

    func testBackgroundPairingLinkWaitsForForegroundResumeBeforeApplying() async throws {
        var probeCallCount = 0
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in
            probeCallCount += 1
        })
        store.suspendForBackground()
        XCTAssertTrue(store.isAppInBackground)

        let opening = Task {
            await store.openPairingLink(Self.tokenLink, foregroundWaitTimeoutNanoseconds: 2_000_000_000)
        }
        try await waitUntil { store.pairingLinkAttempt == .connecting }
        XCTAssertEqual(probeCallCount, 0, "前台恢复落地前不应提前触发会被后台门禁取消的连接变更")

        await store.resumeFromForeground()
        await opening.value

        XCTAssertEqual(probeCallCount, 1)
        XCTAssertEqual(store.pairingLinkAttempt, .idle)
        XCTAssertTrue(appStore.isConfigured)
        XCTAssertEqual(appStore.connectionProfiles.count, 1)
    }

    func testLANPairingGuidanceMentionsMimiRelayWhenEntitlementIsActive() {
        let error = URLError(.cannotConnectToHost)
        let withMimi = ConnectionFailureGuidance.message(
            for: error,
            route: .lan,
            hasActiveMimiEntitlement: true
        )
        let withoutMimi = ConnectionFailureGuidance.message(
            for: error,
            route: .lan,
            hasActiveMimiEntitlement: false
        )

        XCTAssertEqual(withMimi, L10n.text("ui.connection_failure_guidance_lan_with_mimi"))
        XCTAssertEqual(withoutMimi, L10n.text("ui.connection_failure_guidance_lan"))
        XCTAssertNotEqual(withMimi, withoutMimi)
    }

    func testShortSchemeLANPairingURLResolvesToLANRoute() {
        let shortLAN = URL(string: "mimi://pair?endpoint=http%3A%2F%2F192.168.1.20%3A8787&token=t")!
        let standardLAN = URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F192.168.1.20%3A8787&token=t")!

        XCTAssertEqual(ConnectionProfileRoute.fromPairingURL(shortLAN), .lan)
        XCTAssertEqual(ConnectionProfileRoute.fromPairingURL(standardLAN), .lan)
    }

    func testClaimPairingRetriesTransientTransportErrorAndStopsOnAuthError() async throws {
        var attempts = 0
        var sleepDelays: [UInt64] = []
        let expected = PairingClaimResponse(
            endpoint: "http://192.168.1.20:8787",
            token: "claimed-token",
            tailscaleDNSName: nil,
            tailscaleDeviceName: nil,
            tailcatAddress: nil
        )
        let claimed = try await AppStore.claimPairingWithRetry(
            maxAttempts: 3,
            retryDelaysNanoseconds: [10, 20],
            sleep: { sleepDelays.append($0) },
            operation: {
                attempts += 1
                if attempts == 1 {
                    throw URLError(.cannotConnectToHost)
                }
                return expected
            }
        )
        XCTAssertEqual(claimed, expected)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(sleepDelays, [10])

        var authAttempts = 0
        do {
            _ = try await AppStore.claimPairingWithRetry(
                maxAttempts: 3,
                retryDelaysNanoseconds: [10, 20],
                sleep: { _ in XCTFail("鉴权/过期等业务错误不应重试") },
                operation: { () async throws -> PairingClaimResponse in
                    authAttempts += 1
                    throw PairingLinkError.expired
                }
            )
            XCTFail("应立即抛出 PairingLinkError.expired")
        } catch let error as PairingLinkError {
            XCTAssertEqual(error, .expired)
            XCTAssertEqual(authAttempts, 1)
        }
    }

    func testClaimPairing401TicketErrorsPreserveSavedConnectedProfileAndSurfaceTypedGuidance() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalPairingClaimStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (store, appStore) = makeStores(routeProbe: { _, _, _ in }, agentAPISession: session)
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.30:8787",
            token: "existing-token"
        ))
        appStore.markLiveConnectionEstablished()
        let savedProfileID = try XCTUnwrap(appStore.activeConnectionProfileID)
        XCTAssertTrue(appStore.connectionStatus.isConnected)

        let liveTicketURL = try XCTUnwrap(URL(
            string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.99%3A8787"
                + "&issued_at=2026-07-23T10%3A00%3A00Z&expires_at=4102444800&pair_sig=test-sig"
        ))

        // v1 HTTP 401 pair_ticket_expired must NOT delete profile, invalidate credentials, or drop connected status.
        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 401,
            contentType: "application/vnd.mimi.onboarding.v1+json",
            vary: "Accept",
            body: #"{"ok":false,"error":{"code":"pair_ticket_expired","step":"network_any","message":"expired","fix":{"kind":"retry"}}}"#
        )
        await store.openPairingLink(liveTicketURL)

        XCTAssertEqual(appStore.connectionProfiles.map(\.id), [savedProfileID])
        XCTAssertEqual(appStore.activeConnectionProfileID, savedProfileID)
        XCTAssertEqual(appStore.token, "existing-token")
        XCTAssertTrue(appStore.isConfigured)
        XCTAssertTrue(appStore.connectionStatus.isConnected)
        XCTAssertNil(appStore.connectionTermination)
        XCTAssertFalse(appStore.requiresRePairing)
        XCTAssertEqual(store.lastPairingOnboardingError?.code, "pair_ticket_expired")
        let expiredError = try XCTUnwrap(appStore.lastError)
        XCTAssertEqual(expiredError, L10n.text("ui.pairing_onboarding_pair_ticket_expired"))
        XCTAssertEqual(
            ConnectionFailureGuidance.friendlyMessage(from: expiredError, route: store.lastPairingLinkRoute),
            expiredError
        )
        XCTAssertFalse(expiredError.contains("{"))
        XCTAssertFalse(expiredError.contains("10 分钟"))

        // v1 HTTP 401 pair_clock_skew preserves saved profile and gives text Date & Time guidance (no App-Prefs:).
        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 401,
            contentType: "application/vnd.mimi.onboarding.v1+json",
            vary: "Accept",
            body: #"{"ok":false,"error":{"code":"pair_clock_skew","step":"network_any","message":"skew","fix":{"kind":"open_settings","target":"date_time"}}}"#
        )
        await store.openPairingLink(liveTicketURL)

        XCTAssertEqual(appStore.connectionProfiles.map(\.id), [savedProfileID])
        XCTAssertTrue(appStore.connectionStatus.isConnected)
        XCTAssertNil(appStore.connectionTermination)
        XCTAssertEqual(store.lastPairingOnboardingError?.code, "pair_clock_skew")
        let clockError = try XCTUnwrap(appStore.lastError)
        XCTAssertEqual(clockError, PairingErrorMapper.dateTimeInstructions)
        XCTAssertFalse(clockError.contains("App-Prefs:"))
        XCTAssertEqual(
            ConnectionFailureGuidance.friendlyMessage(from: clockError, route: store.lastPairingLinkRoute),
            clockError
        )

        // Legacy host 401 on /api/pair/claim still preserves saved profile and avoids credentialsInvalid.
        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 401,
            contentType: "application/json",
            vary: nil,
            body: #"{"error":"配对二维码已过期"}"#
        )
        await store.openPairingLink(liveTicketURL)

        XCTAssertEqual(appStore.connectionProfiles.map(\.id), [savedProfileID])
        XCTAssertTrue(appStore.connectionStatus.isConnected)
        XCTAssertNil(appStore.connectionTermination)
        XCTAssertEqual(store.lastPairingOnboardingError?.isLegacyFallback, true)
        XCTAssertEqual(appStore.lastError, L10n.text("ui.pairing_onboarding_pair_ticket_expired"))
    }

    func testLocalAutoPairingSurfacesLegacyLoopbackDenial() async throws {
        let suite = "ExternalPairingLinkTests.LocalClaim." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalPairingClaimStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 403, contentType: "application/json", vary: nil,
            body: #"{"error":"本机自动配对仅允许 Mimi Mac 客户端通过 loopback 发起"}"#
        )
        let store = AppStore(
            defaults: defaults, tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: true, localAgentProbe: { _, _ in },
            localAgentPairingClaim: { endpoint, timeout in
                try await AgentAPIClient(endpoint: endpoint, token: "", session: session)
                    .claimLocalPairing(timeout: timeout).token
            }
        )
        let connected = await store.preflightConnection()
        XCTAssertFalse(connected)
        XCTAssertEqual(store.connectionStatus, .failed(L10n.text("ui.pairing_onboarding_pair_local_forbidden")))
        XCTAssertTrue(store.connectionProfiles.isEmpty)
    }

    func testFirstConnectionDeepLinkPropagates409And503TypedOnboardingErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalPairingClaimStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (store, _) = makeStores(routeProbe: { _, _, _ in }, agentAPISession: session)
        let liveTicketURL = try XCTUnwrap(URL(
            string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.99%3A8787"
                + "&issued_at=2026-07-23T10%3A00%3A00Z&expires_at=4102444800&pair_sig=test-sig"
        ))

        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 409,
            contentType: "application/vnd.mimi.onboarding.v1+json",
            vary: "Accept",
            body: #"{"ok":false,"error":{"code":"workspace_confirmation_required","step":"workspace_root","message":"confirm","fix":{"kind":"choose_path","target":"workspace_root"}}}"#
        )
        await store.openPairingLink(liveTicketURL)
        XCTAssertEqual(store.lastPairingOnboardingError?.code, "workspace_confirmation_required")
        XCTAssertEqual(store.pairingLinkAttempt, .failed(L10n.text("ui.pairing_onboarding_desktop_workspace_guidance")))

        ExternalPairingClaimStubURLProtocol.configure(
            statusCode: 503,
            contentType: "application/vnd.mimi.onboarding.v1+json",
            vary: "Accept",
            body: #"{"ok":false,"error":{"code":"no_enabled_assistant","step":"assistant_any","message":"none","fix":{"kind":"open_url","url":"https://github.com/gaixianggeng/mimi-remote/blob/main/docs/quickstart.md"}}}"#
        )
        await store.openPairingLink(liveTicketURL)
        XCTAssertEqual(store.lastPairingOnboardingError?.code, "no_enabled_assistant")
        XCTAssertEqual(store.lastPairingOnboardingError?.action, .openURL(.guide))
        XCTAssertEqual(store.pairingLinkAttempt, .failed(L10n.text("ui.pairing_onboarding_no_enabled_assistant")))
    }

    private func makeStores(
        routeProbe: @escaping ConnectionRouteProbe,
        agentAPISession: URLSession = .shared
    ) -> (SessionStore, AppStore) {
        let suiteName = "ExternalPairingLinkTests.\(UUID().uuidString)"
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
            routeProbe: routeProbe,
            agentAPISession: agentAPISession
        )
        let client = MockSessionStoreClient(projects: [], sessions: [], messagesResult: [])
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

/// 让路由探测停住直到测试放行；放行为失败后，后续候选地址的探测也立即失败，避免挂住。
@MainActor
private final class RouteProbeGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private(set) var isWaiting = false

    func wait() async throws {
        if let failure {
            throw failure
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                isWaiting = true
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel()
            }
        }
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func succeed() {
        continuation?.resume(returning: ())
        continuation = nil
    }

    func fail(_ error: Error) {
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// 忽略任务取消、只由测试显式交付真实失败，用来稳定复现“真实错误与任务取消竞态”。
@MainActor
private final class ControlledFailureGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isWaiting = false

    func waitIgnoringCancellation() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// 模拟 WebSocket 握手：回答 `initialize`，随后在发送 `initialized` 通知时抛出 `URLError(.cancelled)`。
private final class InitializedCancelTransportPool: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var createdCount = 0

    func makeTransport() -> CodexAppServerTransport {
        lock.withLock { createdCount += 1 }
        return InitializedCancelTransport()
    }
}

private final class InitializedCancelTransport: CodexAppServerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inboundQueue: [String] = []
    private var receiveWaiter: CheckedContinuation<String?, Error>?
    private var isClosed = false

    func connect(url: URL, token: String) async throws {}

    func send(_ text: String) async throws {
        if let request = try? decodeAppServerRequest(text), request.method == "initialize" {
            let idJSON: String
            switch request.id {
            case .int(let value): idJSON = "\(value)"
            case .string(let value): idJSON = "\"\(value)\""
            case .null: idJSON = "null"
            }
            pushInbound(#"{"id":\#(idJSON),"result":{"userAgent":"fixture"}}"#)
            return
        }
        if text.contains(#""method":"initialized""#) {
            throw URLError(.cancelled)
        }
    }

    func receive() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let next: String?? = lock.withLock {
                if !inboundQueue.isEmpty {
                    return .some(inboundQueue.removeFirst())
                }
                if isClosed {
                    return .some(nil)
                }
                receiveWaiter = continuation
                return nil
            }
            if let next {
                continuation.resume(returning: next)
            }
        }
    }

    func close() async {
        let waiter: CheckedContinuation<String?, Error>? = lock.withLock {
            isClosed = true
            let existing = receiveWaiter
            receiveWaiter = nil
            return existing
        }
        waiter?.resume(returning: nil)
    }

    private func pushInbound(_ text: String) {
        let waiter: CheckedContinuation<String?, Error>? = lock.withLock {
            if let existing = receiveWaiter {
                receiveWaiter = nil
                return existing
            }
            inboundQueue.append(text)
            return nil
        }
        waiter?.resume(returning: text)
    }
}

private final class PairingFastPathStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, String, Data))?

    static func configure(_ handler: @escaping (URLRequest) -> (Int, String, Data)) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock { self.handler = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        let (status, contentType, body) = handler?(request) ?? (500, "application/json", Data("{}".utf8))
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ExternalPairingClaimStubURLProtocol: URLProtocol {
    private struct StubResponse {
        let statusCode: Int
        let contentType: String
        let vary: String?
        let body: String
    }

    private static let lock = NSLock()
    private static var response = StubResponse(statusCode: 500, contentType: "application/json", vary: nil, body: "{}")

    static func configure(statusCode: Int, contentType: String, vary: String?, body: String) {
        lock.withLock {
            response = StubResponse(statusCode: statusCode, contentType: contentType, vary: vary, body: body)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.lock.withLock { Self.response }
        var headers = ["Content-Type": stub.contentType]
        if let vary = stub.vary {
            headers["Vary"] = vary
        }
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
