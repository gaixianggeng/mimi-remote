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
        sessions.mimiRelayTask = Task { }
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
