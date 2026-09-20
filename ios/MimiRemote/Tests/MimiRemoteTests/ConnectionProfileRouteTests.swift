import XCTest
@testable import MimiRemote

@MainActor
final class ConnectionProfileRouteTests: XCTestCase {
    func testLegacyTailcatMigratesToFreeCustomRoute() throws {
        let profile = try decodeLegacyProfile(
            endpoint: "http://100.64.0.10:8787",
            route: "tailcat"
        )
        XCTAssertEqual(profile.connectionRoute, .customTailcat)
    }

    func testLegacyConfiguredRouteUsesSavedEndpointWithoutChangingIt() throws {
        let tailscale = try decodeLegacyProfile(
            endpoint: "http://100.64.0.10:8787",
            route: "configured"
        )
        let lan = try decodeLegacyProfile(
            endpoint: "http://192.168.1.20:8787",
            route: "configured"
        )
        let https = try decodeLegacyProfile(
            endpoint: "https://mac.example.com",
            route: "configured"
        )

        XCTAssertEqual(tailscale.connectionRoute, .tailscale)
        XCTAssertEqual(lan.connectionRoute, .lan)
        XCTAssertEqual(https.connectionRoute, .https)
        XCTAssertEqual(tailscale.endpoint, "http://100.64.0.10:8787")
        XCTAssertEqual(lan.endpoint, "http://192.168.1.20:8787")
        XCTAssertEqual(https.endpoint, "https://mac.example.com")
    }

    func testManagedAndCustomPairingProduceDifferentPersistentTypes() async throws {
        let suiteName = "ConnectionProfileRouteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )

        let managed = try await store.prepareRoutedConnectionSettings(
            endpoint: "http://100.64.0.10:8787",
            activeEndpoint: "http://127.0.0.1:49152",
            tailcatAddress: "tailcat:managed",
            managed: true,
            token: "token",
            profileTarget: .newProfile(id: "managed", displayName: "Managed")
        )
        let custom = try await store.prepareRoutedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            activeEndpoint: "http://127.0.0.1:49153",
            tailcatAddress: "tailcat:custom",
            token: "token",
            profileTarget: .newProfile(id: "custom", displayName: "Custom")
        )

        XCTAssertEqual(managed.route.profileRoute, .managedTailcat)
        XCTAssertEqual(custom.route.profileRoute, .customTailcat)
    }

    func testTemporaryFallbackProbeDoesNotChangeManagedDefault() async throws {
        let suiteName = "ConnectionProfileRouteTests.Fallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = TokenStore(keychain: TestKeychainOperations())
        let profile = ConnectionProfile(
            id: "managed-mac",
            displayName: "Managed Mac",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil,
            installationID: "10000000-0000-4000-8000-000000000001",
            connectionRoute: .managedTailcat
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        try tokenStore.save("token", profileID: profile.id)
        let store = AppStore(
            defaults: defaults,
            tokenStore: tokenStore,
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )

        let connected = await store.preflightConnection(
            force: true,
            preferredProfileRoute: .tailscale
        )

        XCTAssertTrue(connected)
        XCTAssertEqual(store.activeConnectionProfile?.connectionRoute, .managedTailcat)
        XCTAssertEqual(store.savedFallbackConnectionRoute, .tailscale)
    }

    /// 「连接方式」里「已保存线路」那一项必须报出档案真实的传输方式。
    /// 局域网和 HTTPS 配对的电脑一律显示 Tailscale，等于把当前连接方式说错。
    func testConnectionMethodChoiceReportsSavedRouteTransport() {
        let cases: [(ConnectionProfileRoute?, String)] = [
            (.tailscale, "Tailscale"),
            (.lan, L10n.text("ui.local_network")),
            (.https, "HTTPS")
        ]
        for (route, expected) in cases {
            let options = ConnectionMethodChoice.options(savedRoute: route)
            XCTAssertEqual(options.count, 2)
            XCTAssertEqual(options[0].kind, .saved)
            XCTAssertEqual(options[0].choiceTitle, expected, "\(String(describing: route)) 应显示自身传输方式")
            XCTAssertEqual(options[1].kind, .tailcat)
            XCTAssertEqual(options[1].choiceTitle, L10n.text("ui.custom_tailcat"))
        }

        // 档案尚未落盘时没有可展示的线路名，与设备首页那一行的兜底保持一致。
        XCTAssertEqual(ConnectionMethodChoice.options(savedRoute: nil)[0].choiceTitle, "Tailscale")
    }

    /// 选中态按种类比对：换电脑会换掉标题，但「当前用的是已保存线路」这件事不变。
    func testConnectionMethodChoiceMatchesByKindNotTitle() {
        let lan = ConnectionMethodChoice.options(savedRoute: .lan)[0]
        let https = ConnectionMethodChoice.options(savedRoute: .https)[0]
        XCTAssertNotEqual(lan.choiceTitle, https.choiceTitle)
        XCTAssertEqual(lan, https)
        XCTAssertNotEqual(lan, ConnectionMethodChoice.options(savedRoute: .lan)[1])
    }

    private func decodeLegacyProfile(endpoint: String, route: String) throws -> ConnectionProfile {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "legacy",
            "displayName": "Legacy Mac",
            "endpoint": endpoint,
            "connectionRoute": route,
            "revision": 0,
        ])
        return try JSONDecoder().decode(ConnectionProfile.self, from: data)
    }
}
