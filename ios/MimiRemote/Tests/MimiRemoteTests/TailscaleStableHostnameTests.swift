import XCTest
@testable import MimiRemote

@MainActor
final class TailscaleStableHostnameTests: XCTestCase {
    func testLegacyProfileMigrationInfersAutomaticAndCustomizedDisplayNames() throws {
        let automatic = try JSONDecoder().decode(
            ConnectionProfile.self,
            from: Data(#"{"id":"auto","displayName":"100.64.0.10","endpoint":"http://100.64.0.10:8787","revision":0}"#.utf8)
        )
        let customized = try JSONDecoder().decode(
            ConnectionProfile.self,
            from: Data(#"{"id":"custom","displayName":"工作室","endpoint":"http://100.64.0.20:8787","revision":0}"#.utf8)
        )

        XCTAssertFalse(automatic.isDisplayNameCustomized)
        XCTAssertEqual(automatic.displayName, "100.64.0.10")
        XCTAssertTrue(customized.isDisplayNameCustomized)
        XCTAssertEqual(customized.displayName, "工作室")
        XCTAssertNil(automatic.tailscaleDNSName)
        XCTAssertEqual(automatic.connectionCandidates, ["http://100.64.0.10:8787"])
    }

    func testConnectionProfilePrefersMagicDNSAndKeepsIPFallback() throws {
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "100.64.0.10",
            endpoint: "http://100.64.0.10:8787",
            tailscaleDNSName: "Studio-Mac.tailnet.ts.net.",
            tailscaleDeviceName: "studio-mac",
            isDisplayNameCustomized: false,
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )

        XCTAssertEqual(profile.displayName, "studio-mac")
        XCTAssertEqual(profile.tailscaleDNSName, "studio-mac.tailnet.ts.net")
        XCTAssertEqual(
            profile.connectionCandidates,
            [
                "http://studio-mac.tailnet.ts.net:8787",
                "http://100.64.0.10:8787",
            ]
        )
        XCTAssertEqual(profile.endpoint, "http://100.64.0.10:8787")
    }

    func testLANOnlyProfileIgnoresAdvertisedTailscaleMetadata() {
        let profile = ConnectionProfile(
            id: "lan-mac",
            displayName: "192.168.1.20",
            endpoint: "http://192.168.1.20:8787",
            tailscaleDNSName: "studio-mac.tailnet.ts.net",
            tailscaleDeviceName: "studio-mac",
            isDisplayNameCustomized: false,
            lastSuccessfulAt: nil,
            installationID: "installation-lan"
        )

        XCTAssertNil(profile.tailscaleDNSName)
        XCTAssertNil(profile.tailscaleDeviceName)
        XCTAssertEqual(profile.displayName, "192.168.1.20")
        XCTAssertEqual(profile.connectionCandidates, ["http://192.168.1.20:8787"])
    }

    func testPreparationTriesMagicDNSBeforeIPAndCommitsSuccessfulFallbackRoute() async throws {
        let suiteName = "TailscaleStableHostnameTests.CandidateFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = ConnectionRouteProbeRecorder()
        let keychain = TestKeychainOperations()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
                if endpoint.contains("old-mac.tailnet.ts.net") {
                    throw URLError(.cannotFindHost)
                }
            }
        )

        let prepared = try await store.prepareConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            tailscaleDNSName: "old-mac.tailnet.ts.net",
            tailscaleDeviceName: "old-mac"
        )
        _ = try await store.commitConnectionSettings(prepared)
        let probedEndpoints = await recorder.endpoints()

        XCTAssertEqual(
            probedEndpoints,
            [
                "http://old-mac.tailnet.ts.net:8787",
                "http://100.64.0.20:8787",
            ]
        )
        XCTAssertEqual(prepared.endpoint, "http://100.64.0.20:8787")
        XCTAssertEqual(prepared.activeEndpoint, "http://100.64.0.20:8787")
        XCTAssertEqual(store.activeConnectionProfile?.displayName, "old-mac")
        XCTAssertEqual(store.activeConnectionProfile?.endpoint, "http://100.64.0.20:8787")
        XCTAssertEqual(store.connectionEndpoint, "http://100.64.0.20:8787")
        XCTAssertEqual(try store.client().endpoint, "http://100.64.0.20:8787")
    }

    func testTailcatPreparationValidatesLoopbackRouteButKeepsCanonicalEndpoint() async throws {
        let suiteName = "TailscaleStableHostnameTests.TailcatRoute.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in await recorder.record(endpoint) }
        )

        let prepared = try await store.prepareRoutedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            activeEndpoint: "http://127.0.0.1:28787",
            tailcatAddress: "tailcat:stable-address",
            token: "tailcat-token",
            profileTarget: .currentOrNew(displayName: nil)
        )

        let probedEndpoints = await recorder.endpoints()
        XCTAssertEqual(probedEndpoints, ["http://127.0.0.1:28787"])
        XCTAssertEqual(prepared.endpoint, "http://100.64.0.20:8787")
        XCTAssertEqual(prepared.activeEndpoint, "http://127.0.0.1:28787")
        XCTAssertEqual(prepared.route, .tailcat(address: "tailcat:stable-address"))
    }

    func testMetadataRefreshRequiresStableIdentityAndPreservesCustomName() throws {
        let suiteName = "TailscaleStableHostnameTests.MetadataRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "我的工作室",
            endpoint: "http://100.64.0.10:8787",
            tailscaleDNSName: "old.tailnet.ts.net",
            tailscaleDeviceName: "old",
            isDisplayNameCustomized: true,
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        XCTAssertNil(store.refreshConnectionProfileHostMetadata(
            profileID: profile.id,
            expectedRevision: profile.revision,
            version: VersionResponse(
                name: "agentd",
                version: "test",
                installationID: "different-installation",
                tailscaleDNSName: "wrong.tailnet.ts.net",
                tailscaleDeviceName: "wrong"
            )
        ))
        let refreshed = try XCTUnwrap(store.refreshConnectionProfileHostMetadata(
            profileID: profile.id,
            expectedRevision: profile.revision,
            version: VersionResponse(
                name: "agentd",
                version: "test",
                installationID: "installation-a",
                tailscaleDNSName: "new.tailnet.ts.net",
                tailscaleDeviceName: "new"
            )
        ))

        XCTAssertEqual(refreshed.displayName, "我的工作室")
        XCTAssertTrue(refreshed.isDisplayNameCustomized)
        XCTAssertEqual(refreshed.tailscaleDNSName, "new.tailnet.ts.net")
        XCTAssertEqual(
            refreshed.connectionCandidates,
            ["http://new.tailnet.ts.net:8787", "http://100.64.0.10:8787"]
        )
    }

    func testConnectionPreflightFallsBackFromSavedDNSNameToIP() async throws {
        let suiteName = "TailscaleStableHostnameTests.PreflightFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "studio",
            endpoint: "http://100.64.0.10:8787",
            tailscaleDNSName: "studio.tailnet.ts.net",
            tailscaleDeviceName: "studio",
            isDisplayNameCustomized: false,
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
                if endpoint.contains("studio.tailnet.ts.net") {
                    throw URLError(.cannotFindHost)
                }
            }
        )

        let connected = await store.preflightConnection()
        let probedEndpoints = await recorder.endpoints()

        XCTAssertTrue(connected)
        XCTAssertEqual(
            probedEndpoints,
            [
                "http://studio.tailnet.ts.net:8787",
                "http://100.64.0.10:8787",
            ]
        )
        XCTAssertEqual(store.connectionEndpoint, "http://100.64.0.10:8787")
        XCTAssertEqual(try store.client().endpoint, "http://100.64.0.10:8787")
    }

    func testConnectionPreflightFallsBackWhenDNSPointsToDifferentInstallation() async throws {
        let suiteName = "TailscaleStableHostnameTests.IdentityFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "studio",
            endpoint: "http://100.64.0.10:8787",
            tailscaleDNSName: "studio.tailnet.ts.net",
            tailscaleDeviceName: "studio",
            isDisplayNameCustomized: false,
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
            },
            routeVersionProbe: { endpoint, _, _ in
                VersionResponse(
                    name: "agentd",
                    version: "test",
                    installationID: endpoint.contains("studio.tailnet.ts.net")
                        ? "different-installation"
                        : "installation-a"
                )
            }
        )

        let connected = await store.preflightConnection()
        let probedEndpoints = await recorder.endpoints()

        XCTAssertTrue(connected)
        XCTAssertEqual(
            probedEndpoints,
            [
                "http://studio.tailnet.ts.net:8787",
                "http://100.64.0.10:8787",
            ]
        )
        XCTAssertEqual(store.connectionEndpoint, "http://100.64.0.10:8787")
        XCTAssertEqual(try store.client().endpoint, "http://100.64.0.10:8787")
    }
}
