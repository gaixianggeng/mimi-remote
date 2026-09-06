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
