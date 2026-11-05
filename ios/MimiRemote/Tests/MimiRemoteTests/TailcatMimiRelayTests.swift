import XCTest
@testable import MimiRemote

@MainActor
extension TailcatExperimentRoutingTests {
    func testRelayStatusUsesActualRouteDuringTemporaryFallback() {
        for route in [ConnectionProfileRoute.lan, .tailscale, .https, .customTailcat] {
            XCTAssertEqual(ManagedConnectionDevicesView.currentRoute(
                profileRoute: .managedTailcat, tailcatEnabled: route.usesTailcat,
                tailcatState: .usingTemporaryRoute(route), fallbackRoute: .lan
            ), route)
        }
        XCTAssertEqual(ManagedConnectionDevicesView.currentRoute(
            profileRoute: .managedTailcat, tailcatEnabled: false,
            tailcatState: .disabled, fallbackRoute: .tailscale
        ), .tailscale)
        XCTAssertEqual(ManagedConnectionDevicesView.currentRoute(
            profileRoute: .managedTailcat, tailcatEnabled: true,
            tailcatState: .connected(endpoint: "http://127.0.0.1:49152"), fallbackRoute: .lan
        ), .managedTailcat)
        XCTAssertNil(ManagedConnectionDevicesView.currentRoute(
            profileRoute: nil, tailcatEnabled: false, tailcatState: .disabled, fallbackRoute: nil
        ))
    }

    func testRelayStatusDoesNotClaimPendingOrUnknownServiceIsActive() {
        for route in [ConnectionProfileRoute.lan, .tailscale, .https] {
            XCTAssertNil(ManagedConnectionDevicesView.currentChoice(route: route, savedChoice: .mimi))
        }
        XCTAssertEqual(ManagedConnectionDevicesView.currentChoice(route: .managedTailcat, savedChoice: .custom), .mimi)
        XCTAssertEqual(ManagedConnectionDevicesView.currentChoice(route: .customTailcat, savedChoice: .tailcatDefault), .tailcatDefault)
        XCTAssertEqual(ManagedConnectionDevicesView.currentChoice(route: .customTailcat, savedChoice: .custom), .custom)
        XCTAssertNil(ManagedConnectionDevicesView.currentChoice(route: .customTailcat, savedChoice: .mimi))
        XCTAssertNil(ManagedConnectionDevicesView.currentChoice(route: .customTailcat, savedChoice: nil))
    }

    /// 启用完成前实际还在走免费线路：页面要显示那一项，不能因为选了 Mimi 就变成「由电脑配置」。
    func testRelayStatusShowsFreeRouteUntilMimiIsActuallyEnabled() {
        XCTAssertEqual(
            ManagedConnectionDevicesView.currentChoice(route: .customTailcat, savedChoice: .mimi, freeChoice: .tailcatDefault),
            .tailcatDefault
        )
        XCTAssertEqual(
            ManagedConnectionDevicesView.currentChoice(route: .customTailcat, savedChoice: .mimi, freeChoice: .custom),
            .custom
        )
        XCTAssertEqual(
            ManagedConnectionDevicesView.currentChoice(route: .managedTailcat, savedChoice: .mimi, freeChoice: .tailcatDefault),
            .mimi
        )
    }

    func testMimiRowSeparatesEntitlementFromThisComputer() {
        func state(
            profile: ConnectionProfileRoute? = .customTailcat, current: ConnectionProfileRoute? = .customTailcat,
            connected: Bool = true, entitled: Bool = true, activating: Bool = false
        ) -> ManagedConnectionDevicesView.MimiRowState {
            ManagedConnectionDevicesView.mimiRowState(
                profileRoute: profile, currentRoute: current,
                connected: connected, entitled: entitled, activating: activating
            )
        }
        XCTAssertEqual(state(), .readyToEnable)
        XCTAssertEqual(state(entitled: false), .notActivated)
        XCTAssertEqual(state(activating: true), .activating)
        XCTAssertEqual(state(connected: false), .entitledWaitingForConnection)
        XCTAssertEqual(state(profile: nil, current: nil), .entitledWaitingForConnection)
        XCTAssertEqual(state(profile: .tailscale, current: .tailscale), .entitledWaitingForConnection, "Tailscale 不提供一键启用")
        XCTAssertEqual(state(profile: .managedTailcat, current: .managedTailcat), .enabled)
        XCTAssertEqual(state(profile: .managedTailcat, current: .customTailcat), .temporarilyFree, "临时回退不能显示已启用")
    }

    /// 「当前中转」只说这台手机实际走的线路，不把电脑上的选择或开通资格当成已经用上。
    func testCurrentRelayTitleReportsActualRoute() {
        func title(_ route: ConnectionProfileRoute?, _ saved: RelayServiceChoice?, _ free: RelayServiceChoice? = nil) -> String {
            ManagedConnectionDevicesView.currentRelayTitle(route: route, savedChoice: saved, freeChoice: free)
        }
        XCTAssertEqual(title(.tailscale, .mimi), L10n.text("ui.relay_not_needed"))
        XCTAssertEqual(title(.lan, nil), L10n.text("ui.relay_not_needed"))
        XCTAssertEqual(title(nil, nil), L10n.text("ui.not_connected"))
        XCTAssertEqual(title(.customTailcat, .tailcatDefault), RelayServiceChoice.tailcatDefault.title)
        XCTAssertEqual(title(.customTailcat, .mimi, .custom), RelayServiceChoice.custom.title, "选了 Mimi 但还没用上")
        XCTAssertEqual(title(.customTailcat, nil, .tailcatDefault), RelayServiceChoice.tailcatDefault.title, "旧二维码由电脑告知")
        XCTAssertEqual(title(.customTailcat, .mimi), L10n.text("ui.relay_free_status"), "没有信息时不猜默认还是自建")
        XCTAssertEqual(title(.customTailcat, nil), L10n.text("ui.relay_free_status"))
        XCTAssertEqual(title(.managedTailcat, .mimi, .tailcatDefault), RelayServiceChoice.mimi.title)
    }

    func testComputerSelectedMimiNoteOnlyAppliesToUnactivatedFreeRoute() {
        func shows(_ computer: RelayServiceChoice?, _ route: ConnectionProfileRoute?, entitled: Bool = false) -> Bool {
            ManagedConnectionDevicesView.computerSelectedMimiButNotActivated(
                computerChoice: computer, route: route, entitled: entitled
            )
        }
        XCTAssertTrue(shows(.mimi, .customTailcat))
        XCTAssertFalse(shows(.mimi, .customTailcat, entitled: true), "已开通会自动切换")
        XCTAssertFalse(shows(.mimi, .managedTailcat), "已经在用 Mimi")
        XCTAssertFalse(shows(.tailcatDefault, .customTailcat))
        XCTAssertFalse(shows(nil, .customTailcat))
        XCTAssertFalse(shows(.mimi, .tailscale))
    }

    /// 电脑改选 Mimi 时手机跟随一次；手机改回免费后，电脑没有新动作就不能把它切回去。
    func testPhoneFollowsComputerOnlyWhenSelectionBecomesMimi() throws {
        let fixture = try makeControllerFixture(startResults: [], managedProfile: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let controller = fixture.controller
        func note(_ relay: RelayServiceChoice, free: RelayServiceChoice? = .tailcatDefault, id: String = "first") -> Bool {
            controller.noteComputerRelayChoice(ComputerRelayChoice(relay: relay, free: free), profileID: id)
        }
        XCTAssertFalse(note(.tailcatDefault), "默认不跟随")
        XCTAssertEqual(controller.lastFreeRelayChoice(profileID: "first"), .tailcatDefault)
        XCTAssertTrue(note(.mimi), "电脑改选 Mimi")
        XCTAssertFalse(note(.mimi), "同一次选择只跟随一次，手机改回免费后不会被切回去")
        XCTAssertFalse(note(.tailcatDefault))
        XCTAssertTrue(note(.mimi), "电脑重新选一次才算新的选择")
        XCTAssertTrue(note(.mimi, id: "second"), "第一次看到电脑已选 Mimi 也要跟随")
        XCTAssertFalse(note(.custom, free: .custom))
        XCTAssertEqual(controller.lastFreeRelayChoice(profileID: "first"), .custom)
        XCTAssertEqual(controller.computerRelayChoice(profileID: "first"), .custom)
        XCTAssertEqual(controller.computerRelayChoice(profileID: "second"), .mimi, "按电脑隔离")
        try controller.deleteProfileRoute(profileID: "first")
        XCTAssertNil(controller.computerRelayChoice(profileID: "first"))
    }

    func testRelayNoticeOnlyKeepsWhatTheRowCannotSay() {
        let visible = ManagedConnectionDevicesView.visibleRelayNotice
        XCTAssertNil(visible(nil, false))
        XCTAssertNil(visible(L10n.text("ui.relay_enabled"), false), "已启用由行本身表达")
        XCTAssertNil(visible(L10n.text("ui.relay_activating"), false))
        XCTAssertNil(visible("启用失败", true), "启用中不显示上一次的失败")
        XCTAssertEqual(visible("启用失败", false), "启用失败")
    }

    /// 刷新时 Store 会短暂回到检查中，已有权益的人不能每次进页都看到邀请码输入框闪一下。
    func testRefreshingKeepsShowingValidEntitlement() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func grant(expiresIn seconds: TimeInterval) -> ManagedConnectionEntitlementGrant {
            ManagedConnectionEntitlementGrant(
                entitlement: ManagedConnectionEntitlement(
                    id: "e", productID: ManagedConnectionProductID.betaRedemption, status: .active,
                    expiresAt: now.addingTimeInterval(seconds)
                ),
                token: "t", tokenExpiresAt: now.addingTimeInterval(60)
            )
        }
        let valid = grant(expiresIn: 3_600)
        for status in [ManagedConnectionEntitlementStore.Status.loading, .resolving] {
            XCTAssertEqual(
                ManagedConnectionSubscriptionView.displayStatus(status, grant: valid, now: now),
                .entitled(valid.entitlement)
            )
            XCTAssertEqual(ManagedConnectionSubscriptionView.displayStatus(status, grant: nil, now: now), status)
            XCTAssertEqual(
                ManagedConnectionSubscriptionView.displayStatus(status, grant: grant(expiresIn: -1), now: now), status
            )
        }
        XCTAssertEqual(ManagedConnectionSubscriptionView.displayStatus(.expired, grant: valid, now: now), .expired)
        XCTAssertEqual(ManagedConnectionSubscriptionView.displayStatus(.available, grant: nil, now: now), .available)
    }

    func testRelayActivationRequiresExplicitSelectionAndPreservesFreeChoice() {
        for route in [ConnectionProfileRoute.lan, .tailscale, .https, .customTailcat] {
            XCTAssertFalse(SessionStore.shouldAutomaticallyActivateRelay(route: route, connected: true, entitled: true))
            XCTAssertTrue(SessionStore.shouldAutomaticallyActivateRelay(route: route, connected: true, entitled: true, selectedMimi: true))
            XCTAssertFalse(SessionStore.shouldAutomaticallyActivateRelay(route: route, connected: false, entitled: true, selectedMimi: true))
            XCTAssertFalse(SessionStore.shouldAutomaticallyActivateRelay(route: route, connected: true, entitled: false, selectedMimi: true))
        }
        XCTAssertFalse(SessionStore.shouldAutomaticallyActivateRelay(route: nil, connected: true, entitled: true, selectedMimi: true))
        XCTAssertFalse(SessionStore.shouldAutomaticallyActivateRelay(route: .managedTailcat, connected: true, entitled: true, selectedMimi: true))
    }

    /// 选 Mimi 不能抹掉原来的免费线路，否则启用失败后页面说不清实际在用哪一项。
    func testChoosingMimiRemembersFreeChoiceUntilRouteIsRemoved() throws {
        let fixture = try makeControllerFixture(startResults: [], managedProfile: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.controller.selectRelayService(.custom, profileID: "first")
        fixture.controller.selectRelayService(.mimi, profileID: "first")
        XCTAssertEqual(fixture.controller.relayServiceChoice(profileID: "first"), .mimi)
        XCTAssertEqual(fixture.controller.lastFreeRelayChoice(profileID: "first"), .custom)
        XCTAssertNil(fixture.controller.lastFreeRelayChoice(profileID: "second"), "按电脑隔离")
        fixture.controller.selectRelayService(nil, profileID: "first")
        XCTAssertNil(fixture.controller.lastFreeRelayChoice(profileID: "first"), "旧二维码清掉后不再猜测")
        fixture.controller.selectRelayService(.tailcatDefault, profileID: "first")
        try fixture.controller.deleteProfileRoute(profileID: "first")
        XCTAssertNil(fixture.controller.lastFreeRelayChoice(profileID: "first"))
    }

    /// 改回免费是长期选择：下次启动也不回到 Mimi；免费地址保留，之后还能一键启用。
    func testSwitchToFreeRelayCommitsFreeRouteAndKeepsWayBack() async throws {
        let fixture = try makeControllerFixture(
            startResults: [.success("http://127.0.0.1:49152")], managedProfile: true
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try fixture.tokenStore.saveFreeTailcatAddress("tailcat:free-backup", profileID: "managed-mac")
        fixture.controller.selectRelayService(.tailcatDefault, profileID: "managed-mac")
        fixture.controller.selectRelayService(.mimi, profileID: "managed-mac")
        let sessions = SessionStore(
            appStore: fixture.store, conversationStore: ConversationStore(), logStore: LogStore(),
            tailcatExperimentController: fixture.controller
        )

        let switched = await sessions.switchToFreeRelay()

        XCTAssertTrue(switched)
        XCTAssertEqual(fixture.store.activeConnectionProfile?.connectionRoute, .customTailcat, "必须写入档案，不是临时线路")
        XCTAssertEqual(try fixture.tokenStore.loadTailcatAddress(profileID: "managed-mac"), "tailcat:free-backup")
        XCTAssertEqual(try fixture.tokenStore.loadFreeTailcatAddress(profileID: "managed-mac"), "tailcat:free-backup")
        XCTAssertEqual(fixture.controller.relayServiceChoice(profileID: "managed-mac"), .tailcatDefault)
        XCTAssertEqual(fixture.controller.state, .connected(endpoint: "http://127.0.0.1:49152"))
        // 电脑还选着 Mimi 时，下一次检查不能把这次改回当成新选择。
        XCTAssertFalse(fixture.controller.noteComputerRelayChoice(
            ComputerRelayChoice(relay: .mimi, free: .tailcatDefault), profileID: "managed-mac"
        ))
        XCTAssertNil(sessions.inFlightConnectionChangeGeneration)
        XCTAssertFalse(sessions.isSwitchingToFreeRelay)
        // 选择已不是 Mimi，提交后的连接变化不能把线路自动启用回去。
        XCTAssertFalse(SessionStore.shouldAutomaticallyActivateRelay(
            route: .customTailcat, connected: true, entitled: true,
            selectedMimi: fixture.controller.relayServiceChoice(profileID: "managed-mac") == .mimi
        ))
    }

    /// 切换失败要留在原线路：档案、地址和选择都不变，否则下一次对账会走错方向。
    func testSwitchToFreeRelayFailureLeavesMimiUntouched() async throws {
        let fixture = try makeControllerFixture(startResults: [.failure(.startFailed)], managedProfile: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try fixture.tokenStore.saveFreeTailcatAddress("tailcat:free-backup", profileID: "managed-mac")
        fixture.controller.selectRelayService(.tailcatDefault, profileID: "managed-mac")
        fixture.controller.selectRelayService(.mimi, profileID: "managed-mac")
        let sessions = SessionStore(
            appStore: fixture.store, conversationStore: ConversationStore(), logStore: LogStore(),
            tailcatExperimentController: fixture.controller
        )

        let switched = await sessions.switchToFreeRelay()

        XCTAssertFalse(switched)
        XCTAssertEqual(fixture.store.activeConnectionProfile?.connectionRoute, .managedTailcat)
        XCTAssertEqual(try fixture.tokenStore.loadTailcatAddress(profileID: "managed-mac"), "tailcat:managed-mac")
        XCTAssertEqual(try fixture.tokenStore.loadFreeTailcatAddress(profileID: "managed-mac"), "tailcat:free-backup")
        XCTAssertEqual(fixture.controller.relayServiceChoice(profileID: "managed-mac"), .mimi)
        XCTAssertEqual(fixture.controller.lastFreeRelayChoice(profileID: "managed-mac"), .tailcatDefault)
        XCTAssertNotNil(sessions.mimiRelayNotice)
        XCTAssertFalse(sessions.isSwitchingToFreeRelay)
    }

    func testSwitchToFreeRelayRequiresManagedRouteAndAuthorizedFreeAddress() async throws {
        let noBackup = try makeControllerFixture(startResults: [], managedProfile: true)
        defer { noBackup.defaults.removePersistentDomain(forName: noBackup.suiteName) }
        let sessions = SessionStore(
            appStore: noBackup.store, conversationStore: ConversationStore(), logStore: LogStore(),
            tailcatExperimentController: noBackup.controller
        )
        let switched = await sessions.switchToFreeRelay()
        XCTAssertFalse(switched, "没有已授权的免费地址时不能猜测")
        let starts = await noBackup.runtime.startCallCount()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(noBackup.store.activeConnectionProfile?.connectionRoute, .managedTailcat)
    }

    func testSwitchToFreeOnlyOfferedWhenThisPhoneHasFreeRoute() {
        func can(_ route: ConnectionProfileRoute?, hasFree: Bool = true) -> Bool {
            ManagedConnectionDevicesView.canSwitchToFree(profileRoute: route, hasFreeRoute: hasFree)
        }
        XCTAssertTrue(can(.managedTailcat))
        XCTAssertFalse(can(.managedTailcat, hasFree: false))
        XCTAssertFalse(can(.customTailcat), "已经在免费线路上")
        XCTAssertFalse(can(.tailscale))
        XCTAssertFalse(can(nil))
    }

    func testRelayChoiceIsScopedToComputerAndRemovedWithItsRoute() throws {
        let fixture = try makeControllerFixture(startResults: [], managedProfile: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.controller.selectRelayService(.mimi, profileID: "first")
        fixture.controller.selectRelayService(.custom, profileID: "second")
        XCTAssertEqual(fixture.controller.relayServiceChoice(profileID: "first"), .mimi)
        XCTAssertEqual(fixture.controller.relayServiceChoice(profileID: "second"), .custom)
        XCTAssertNil(fixture.controller.relayServiceChoice(profileID: "third"))
        fixture.controller.selectRelayService(.tailcatDefault, profileID: "first")
        XCTAssertEqual(fixture.defaults.string(forKey: "mimi.relayChoice.first"), "default")
        try fixture.controller.deleteProfileRoute(profileID: "first")
        XCTAssertNil(fixture.controller.relayServiceChoice(profileID: "first"))
        XCTAssertEqual(fixture.controller.relayServiceChoice(profileID: "second"), .custom)
    }

    func testPairingRelayChoiceDoesNotTreatOtherTransportsAsMimi() throws {
        for choice in RelayServiceChoice.allCases {
            let url = try XCTUnwrap(URL(string: "mimiremote://pair?transport=tailcat&relay_service=" + choice.rawValue))
            XCTAssertEqual(RelayServiceChoice.fromPairingURL(url), choice)
        }
        for suffix in ["transport=lan&relay_service=mimi", "transport=tailcat", "transport=tailcat&relay_service=unknown"] {
            XCTAssertNil(RelayServiceChoice.fromPairingURL(try XCTUnwrap(URL(string: "mimiremote://pair?" + suffix))))
        }
    }

    func testRelayOperationPollsAcceptedRequestWithoutStartingAnother() async throws {
        let id = UUID()
        ManagedUpgradeURLProtocol.configure { request in
            let state = request.request.httpMethod == "POST" ? "pending" : "completed"
            request.respond(status: 200, body: """
            {"id":"\(id.uuidString)","state":"\(state)","result":{"pair_url":"mimiremote://pair","pair_expires_at":"2100-01-01T00:00:00Z","mode":"managed"}}
            """)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagedUpgradeURLProtocol.self]
        let client = AgentAPIClient(endpoint: "http://100.64.0.10:8787", token: "test-token", session: URLSession(configuration: configuration))
        let result = try await client.activateManagedRelay(requestID: id)
        XCTAssertEqual(result.mode, "managed")
        XCTAssertEqual(ManagedUpgradeURLProtocol.requests.map(\.httpMethod), ["POST", "GET"])
        XCTAssertEqual(ManagedUpgradeURLProtocol.requests.last?.url?.lastPathComponent, id.uuidString)
        let body = try XCTUnwrap(ManagedUpgradeURLProtocol.requests.first?.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload["request_id"], id.uuidString)
    }

    func testRelayOperationRejectsWrongOperationAndExpiredResult() async throws {
        ManagedUpgradeURLProtocol.configure { request in
            request.respond(body: """
            {"id":"\(UUID().uuidString)","state":"pending"}
            """)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagedUpgradeURLProtocol.self]
        let client = AgentAPIClient(endpoint: "http://100.64.0.10:8787", token: "test-token", session: URLSession(configuration: configuration))
        await XCTAssertThrowsErrorAsync(try await client.activateManagedRelay(requestID: UUID())) { error in
            guard case AgentAPIError.invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let expired = ManagedPairingLinkAPIError.decode(status: 404, data: Data(#"{"code":"tailcat_operation_expired","error":"Expired"}"#.utf8))
        XCTAssertEqual(expired, .failed(code: "tailcat_operation_expired", message: "Expired"))
    }

    func testRelayRequestSurvivesRestartAndIsScopedToComputer() throws {
        let fixture = try makeControllerFixture(startResults: [], managedProfile: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let first = fixture.controller.relayActivationRequestID(profileID: "managed-mac")
        let restored = TailcatExperimentController(appStore: fixture.store, defaults: fixture.defaults, tokenStore: fixture.tokenStore)
        XCTAssertEqual(restored.relayActivationRequestID(profileID: "managed-mac"), first)
        XCTAssertNotEqual(restored.relayActivationRequestID(profileID: "another-mac"), first)
        restored.clearRelayActivationRequest(profileID: "managed-mac")
        XCTAssertNotEqual(restored.relayActivationRequestID(profileID: "managed-mac"), first)
    }

    func testFreeFallbackValidatesComputerAndPreservesManagedPreference() async throws {
        let recorder = TailcatRouteRecorder()
        let fixture = try makeControllerFixture(
            startResults: [.success("http://127.0.0.1:49152")], managedProfile: true,
            routeProbe: { endpoint, _, _ in await recorder.record(endpoint) }
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try fixture.tokenStore.saveFreeTailcatAddress("tailcat:free-backup", profileID: "managed-mac")
        let recovered = await fixture.controller.useFreeRouteOnce(appStore: fixture.store)
        XCTAssertTrue(recovered)
        XCTAssertEqual(fixture.store.activeConnectionProfile?.connectionRoute, .managedTailcat)
        XCTAssertEqual(fixture.controller.state, .usingTemporaryRoute(.customTailcat))
        XCTAssertEqual(try fixture.tokenStore.loadTailcatAddress(profileID: "managed-mac"), "tailcat:managed-mac")
        XCTAssertEqual(fixture.store.connectionEndpoint, "http://127.0.0.1:49152")
        let probes = await recorder.endpoints
        XCTAssertEqual(probes, ["http://127.0.0.1:49152"])
    }

    func testFreeFallbackRejectsRevokedCredentialsAndStopsFurtherAttempts() async throws {
        let fixture = try makeControllerFixture(
            startResults: [.success("http://127.0.0.1:49152")], managedProfile: true,
            routeProbe: { _, _, _ in throw AgentAPIError.credentialsInvalid(status: 401) }
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try fixture.tokenStore.saveFreeTailcatAddress("tailcat:free-backup", profileID: "managed-mac")
        let recovered = await fixture.controller.useFreeRouteOnce(appStore: fixture.store)
        XCTAssertFalse(recovered)
        XCTAssertTrue(fixture.store.requiresRePairing)
        let retried = await fixture.controller.useFreeRouteOnce(appStore: fixture.store)
        XCTAssertFalse(retried)
        let starts = await fixture.runtime.startCallCount()
        XCTAssertEqual(starts, 1)
    }

    func testFreeFallbackWithoutSavedAuthorizationNeverInventsAddress() async throws {
        let fixture = try makeControllerFixture(startResults: [], managedProfile: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let recovered = await fixture.controller.useFreeRouteOnce(appStore: fixture.store)
        XCTAssertFalse(recovered)
        let starts = await fixture.runtime.startCallCount()
        XCTAssertEqual(starts, 0)
    }

    func testFreeFallbackCannotCommitAfterChangingComputer() async throws {
        let fixture = try makeControllerFixture(
            startResults: [.success("http://127.0.0.1:49152")], blockedStartCall: 1, managedProfile: true
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try fixture.tokenStore.saveFreeTailcatAddress("tailcat:free-backup", profileID: "managed-mac")
        let task = Task { await fixture.controller.useFreeRouteOnce(appStore: fixture.store) }
        await fixture.runtime.waitForBlockedStart()
        let other = try await fixture.store.prepareNewConnectionProfile(endpoint: "http://100.64.0.20:8787", token: "other-token", displayName: "Other")
        _ = try await fixture.store.commitConnectionSettings(other)
        let profileID = fixture.store.activeConnectionProfileID
        await fixture.runtime.releaseBlockedStart()
        let recovered = await task.value
        XCTAssertFalse(recovered)
        XCTAssertEqual(fixture.store.activeConnectionProfileID, profileID)
        XCTAssertNotEqual(fixture.store.connectionEndpoint, "http://127.0.0.1:49152")
    }

    func testManualRouteChangesWaitForAutomaticRelayOperation() async throws {
        let fixture = try makeControllerFixture(startResults: [], managedProfile: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let sessions = SessionStore(
            appStore: fixture.store, conversationStore: ConversationStore(), logStore: LogStore(),
            tailcatExperimentController: fixture.controller
        )
        sessions.mimiRelay.task = Task { }
        let retried = await sessions.retryManagedConnection()
        let switched = await sessions.useSavedConnectionRouteOnce(.customTailcat)
        XCTAssertFalse(retried)
        XCTAssertFalse(switched)
        let starts = await fixture.runtime.startCallCount()
        XCTAssertEqual(starts, 0)
        sessions.cancelMimiRelay()
    }

    func testManualRouteChangesShareConnectionTransaction() async throws {
        let fixture = try makeControllerFixture(
            startResults: [.success("http://127.0.0.1:49152")], blockedStartCall: 1, managedProfile: true
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try fixture.tokenStore.saveFreeTailcatAddress("tailcat:free-backup", profileID: "managed-mac")
        let sessions = SessionStore(
            appStore: fixture.store, conversationStore: ConversationStore(), logStore: LogStore(),
            tailcatExperimentController: fixture.controller
        )
        let first = Task { await sessions.useSavedConnectionRouteOnce(.customTailcat) }
        await fixture.runtime.waitForBlockedStart()
        XCTAssertNotNil(sessions.inFlightConnectionChangeGeneration)
        let competing = await sessions.retryManagedConnection()
        XCTAssertFalse(competing)
        first.cancel()
        await fixture.runtime.releaseBlockedStart()
        _ = await first.value
        XCTAssertNil(sessions.inFlightConnectionChangeGeneration)
        let starts = await fixture.runtime.startCallCount()
        XCTAssertEqual(starts, 1)
    }

}
