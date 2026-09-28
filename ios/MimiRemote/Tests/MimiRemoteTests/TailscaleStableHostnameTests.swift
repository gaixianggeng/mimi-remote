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

    func testTailcatPairingUsesHostDeviceNameAsDefaultDisplayName() async throws {
        let suiteName = "TailscaleStableHostnameTests.TailcatDeviceName.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )

        // Tailcat 配对链接签发的规范地址就是 loopback；设备名必须能独立于地址写进档案，
        // 否则设置页只能显示「这台电脑」。
        let prepared = PreparedConnectionSettings(
            endpoint: "http://127.0.0.1:8787",
            activeEndpoint: "http://127.0.0.1:28787",
            route: .customTailcat(address: "tailcat:stable-address"),
            token: "tailcat-token",
            profileTarget: .newProfile(id: "tailcat-mac", displayName: ""),
            installationID: "installation-tailcat",
            hostDeviceName: "工作室的 Mac Studio"
        )
        _ = try await store.commitConnectionSettings(prepared)

        XCTAssertEqual(store.activeConnectionProfile?.displayName, "工作室的 Mac Studio")
        XCTAssertEqual(store.activeConnectionProfile?.hostDeviceName, "工作室的 Mac Studio")
        XCTAssertEqual(store.activeConnectionProfile?.isDisplayNameCustomized, false)
        XCTAssertEqual(store.activeConnectionProfile?.connectionRoute, .customTailcat)
    }

    func testLANProfileWithoutNameUsesHostDeviceName() async throws {
        let suiteName = "TailscaleStableHostnameTests.LanPrepareDeviceName.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )

        let prepared = try await store.prepareConnectionSettings(
            endpoint: "http://192.168.1.20:8787",
            token: "lan-token",
            profileTarget: .newProfile(id: "lan-mac", displayName: ""),
            hostDeviceName: "工作室的 Mac Studio"
        )
        _ = try await store.commitConnectionSettings(prepared)

        XCTAssertEqual(store.activeConnectionProfile?.displayName, "工作室的 Mac Studio")
        XCTAssertEqual(store.activeConnectionProfile?.hostDeviceName, "工作室的 Mac Studio")
    }

    func testManualProfileNameStillWinsOverHostDeviceName() async throws {
        let suiteName = "TailscaleStableHostnameTests.ManualName.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )

        let prepared = try await store.prepareConnectionSettings(
            endpoint: "http://192.168.1.20:8787",
            token: "lan-token",
            profileTarget: .newProfile(id: "lan-mac", displayName: "书房电脑"),
            hostDeviceName: "工作室的 Mac Studio"
        )
        _ = try await store.commitConnectionSettings(prepared)

        XCTAssertEqual(store.activeConnectionProfile?.displayName, "书房电脑")
        XCTAssertEqual(store.activeConnectionProfile?.isDisplayNameCustomized, true)
    }

    func testLocalLoopbackPairingKeepsThisComputerName() async throws {
        let suiteName = "TailscaleStableHostnameTests.LocalName.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )

        // 本机直连读写的是当前设备，保留「这台电脑」而不是把宿主设备名写进去。
        let prepared = try await store.prepareConnectionSettings(
            endpoint: "http://127.0.0.1:8787",
            token: "local-token",
            profileTarget: .currentOrNew(displayName: L10n.text("ui.this_mac")),
            hostDeviceName: "工作室的 Mac Studio",
            adoptsHostDeviceName: false
        )
        XCTAssertNil(prepared.hostDeviceName)
        _ = try await store.commitConnectionSettings(prepared)

        XCTAssertEqual(store.activeConnectionProfile?.displayName, L10n.text("ui.this_mac"))
        XCTAssertNil(store.activeConnectionProfile?.hostDeviceName)
    }

    func testStoredHostDeviceNameSurvivesDecodingAndStoreReload() throws {
        let profile = ConnectionProfile(
            id: "tailcat-mac",
            displayName: "这台电脑",
            endpoint: "http://127.0.0.1:8787",
            hostDeviceName: "工作室的 Mac Studio",
            isDisplayNameCustomized: false,
            lastSuccessfulAt: nil,
            installationID: "installation-tailcat",
            connectionRoute: .customTailcat
        )
        let encoded = try JSONEncoder().encode([profile])
        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: encoded)
        XCTAssertEqual(decoded.first?.displayName, "工作室的 Mac Studio")
        XCTAssertEqual(decoded.first?.hostDeviceName, "工作室的 Mac Studio")

        let suiteName = "TailscaleStableHostnameTests.StoredDeviceName.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(encoded, forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-tailcat".utf8), account: "agentd-profile.\(profile.id)")
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain)
        )

        // 重新加载档案时不能把已持久化的设备名退回地址占位。
        XCTAssertEqual(store.activeConnectionProfile?.displayName, "工作室的 Mac Studio")
    }

    func testLegacyProfileWithoutHostDeviceNameKeepsAddressFallback() throws {
        let decoded = try JSONDecoder().decode(
            ConnectionProfile.self,
            from: Data(#"{"id":"legacy","displayName":"192.168.1.20","endpoint":"http://192.168.1.20:8787","isDisplayNameCustomized":false,"revision":0}"#.utf8)
        )
        XCTAssertNil(decoded.hostDeviceName)
        XCTAssertEqual(decoded.displayName, "192.168.1.20")
    }

    func testHostMetadataRefreshAdoptsDeviceNameForNonTailscaleProfile() throws {
        let suiteName = "TailscaleStableHostnameTests.LanDeviceName.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "lan-mac",
            displayName: "192.168.1.20",
            endpoint: "http://192.168.1.20:8787",
            isDisplayNameCustomized: false,
            lastSuccessfulAt: nil,
            installationID: "installation-lan"
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )

        let refreshed = try XCTUnwrap(store.refreshConnectionProfileHostMetadata(
            profileID: profile.id,
            expectedRevision: profile.revision,
            version: VersionResponse(
                name: "agentd",
                version: "test",
                installationID: "installation-lan",
                deviceName: "工作室的 Mac Studio"
            )
        ))
        XCTAssertEqual(refreshed.displayName, "工作室的 Mac Studio")
        XCTAssertEqual(refreshed.hostDeviceName, "工作室的 Mac Studio")
        XCTAssertFalse(refreshed.isDisplayNameCustomized)

        // 旧 agentd 不再上报设备名时必须保留已存名称，不能擦回地址。
        let withoutName = try XCTUnwrap(store.refreshConnectionProfileHostMetadata(
            profileID: profile.id,
            expectedRevision: refreshed.revision,
            version: VersionResponse(
                name: "agentd",
                version: "test",
                installationID: "installation-lan"
            )
        ))
        XCTAssertEqual(withoutName.displayName, "工作室的 Mac Studio")
        XCTAssertEqual(withoutName.hostDeviceName, "工作室的 Mac Studio")
    }

    func testHostMetadataRefreshKeepsCustomNameWhenHostIsRenamed() throws {
        let suiteName = "TailscaleStableHostnameTests.RenamedHost.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "工作室电脑",
            endpoint: "http://127.0.0.1:8787",
            hostDeviceName: "旧设备名",
            isDisplayNameCustomized: true,
            lastSuccessfulAt: nil,
            installationID: "installation-a",
            connectionRoute: .customTailcat
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )

        let refreshed = try XCTUnwrap(store.refreshConnectionProfileHostMetadata(
            profileID: profile.id,
            expectedRevision: profile.revision,
            version: VersionResponse(
                name: "agentd",
                version: "test",
                installationID: "installation-a",
                deviceName: "新设备名"
            )
        ))
        XCTAssertEqual(refreshed.displayName, "工作室电脑")
        XCTAssertEqual(refreshed.hostDeviceName, "新设备名")
    }

    func testVersionResponseTreatsHostDeviceNameAsAdditiveField() throws {
        let legacy = try JSONDecoder().decode(
            VersionResponse.self,
            from: Data(#"{"name":"agentd","version":"test","protocol_revision":2,"minimum_client_protocol_revision":1}"#.utf8)
        )
        XCTAssertNil(legacy.deviceName)

        let current = try JSONDecoder().decode(
            VersionResponse.self,
            from: Data(#"{"name":"agentd","version":"test","device_name":"工作室的 Mac Studio","protocol_revision":2,"minimum_client_protocol_revision":1}"#.utf8)
        )
        XCTAssertEqual(current.deviceName, "工作室的 Mac Studio")
    }
}
