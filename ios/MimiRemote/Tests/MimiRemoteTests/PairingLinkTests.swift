import XCTest
import Security
@testable import MimiRemote

@MainActor
final class PairingLinkTests: XCTestCase {
    func testHostPlatformNormalizesServerValuesAndKeepsLegacyProfilesCompatible() throws {
        XCTAssertEqual(HostPlatform(serverValue: "darwin"), .apple)
        XCTAssertEqual(HostPlatform(serverValue: "macOS"), .apple)
        XCTAssertEqual(HostPlatform(serverValue: "windows"), .windows)
        XCTAssertEqual(HostPlatform(serverValue: "linux"), .linux)
        XCTAssertEqual(HostPlatform(serverValue: "freebsd"), .unknown)
        XCTAssertEqual(HostPlatform.windows.iconKind, .windows11)
        XCTAssertEqual(HostPlatform.linux.iconKind, .linuxTux)
        XCTAssertEqual(HostPlatform.unknown.iconKind, .genericComputer)

        let legacyProfile = try JSONDecoder().decode(
            ConnectionProfile.self,
            from: Data(
                #"{"id":"legacy","displayName":"旧设备","endpoint":"http://127.0.0.1:8787"}"#.utf8
            )
        )
        XCTAssertEqual(legacyProfile.hostPlatform, .unknown)

        let futureProfile = try JSONDecoder().decode(
            ConnectionProfile.self,
            from: Data(
                #"{"id":"future","displayName":"新设备","endpoint":"http://127.0.0.1:8787","hostPlatform":"freebsd"}"#.utf8
            )
        )
        XCTAssertEqual(futureProfile.hostPlatform, .unknown)
    }

    func testConnectionCommitPersistsNormalizedHostPlatform() async throws {
        let suiteName = "PairingLinkTests.HostPlatform.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )

        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.30:8787",
            token: "windows-token",
            installationID: "windows-installation",
            hostPlatform: .windows
        ))

        XCTAssertEqual(store.activeConnectionProfile?.hostPlatform, .windows)
        let persistedData = try XCTUnwrap(defaults.data(forKey: "agentd.connectionProfiles.v2"))
        let persistedProfiles = try JSONDecoder().decode([ConnectionProfile].self, from: persistedData)
        XCTAssertEqual(persistedProfiles.first?.hostPlatform, .windows)
    }

    func testQRCodeScanIntentKeepsPresentationAndSubmissionModeTogether() {
        XCTAssertTrue(ConnectionQRCodeScanIntent.initialConnection.isValid(activeProfileID: nil))
        XCTAssertFalse(ConnectionQRCodeScanIntent.initialConnection.isValid(activeProfileID: "current"))

        XCTAssertTrue(ConnectionQRCodeScanIntent.addConnectionProfile.addsConnectionProfile)
        XCTAssertTrue(ConnectionQRCodeScanIntent.addConnectionProfile.isValid(activeProfileID: "current"))

        let repair = ConnectionQRCodeScanIntent.repairCurrentProfile(expectedProfileID: "expected")
        XCTAssertFalse(repair.addsConnectionProfile)
        XCTAssertTrue(repair.isValid(activeProfileID: "expected"))
        XCTAssertFalse(repair.isValid(activeProfileID: "changed"))
    }

    func testQRCodeScannerPermissionFailuresOfferSettingsAndManualRecovery() {
        for failure in [QRCodeScannerFailure.permissionDenied, .permissionRestricted] {
            XCTAssertEqual(failure.recoveryActions, [.openSettings, .manualConnection])
        }
    }

    func testQRCodeScannerCameraFailuresAlwaysOfferManualRecovery() {
        let failures: [QRCodeScannerFailure] = [
            .cameraUnavailable,
            .configurationFailed("测试配置失败")
        ]

        for failure in failures {
            XCTAssertTrue(failure.recoveryActions.contains(.manualConnection))
            XCTAssertFalse(failure.recoveryActions.contains(.openSettings))
        }
    }

    func testQRCodeScannerRejectedCodeCanRetryWithoutLeavingCamera() {
        let failure = QRCodeScannerFailure.rejectedCode("二维码已过期")

        XCTAssertEqual(failure.message, "二维码已过期")
        XCTAssertEqual(failure.recoveryActions, [.retryScanning, .manualConnection])
        XCTAssertEqual(
            QRCodeScannerSubmissionResult.accepted("已添加并切换到这台 Mac"),
            .accepted("已添加并切换到这台 Mac")
        )
        XCTAssertEqual(
            QRCodeScannerSubmissionResult.rejected("连接失败"),
            .rejected("连接失败")
        )
    }

    func testTokenStoreUpdatesExistingItemWithoutDeletingIt() throws {
        let keychain = TestKeychainOperations(itemData: Data("old-token".utf8))
        let store = TokenStore(keychain: keychain)

        try store.save("new-token")

        XCTAssertEqual(keychain.itemData, Data("new-token".utf8))
        XCTAssertEqual(keychain.updateCallCount, 1)
        XCTAssertEqual(keychain.addCallCount, 0)
        XCTAssertEqual(keychain.deleteCallCount, 0)
    }

    func testTokenStoreUpdateFailurePreservesExistingItem() throws {
        let keychain = TestKeychainOperations(
            itemData: Data("old-token".utf8),
            forcedUpdateStatus: errSecInteractionNotAllowed
        )
        let store = TokenStore(keychain: keychain)

        XCTAssertThrowsError(try store.save("new-token")) { error in
            guard case TokenStoreError.saveFailed(let status) = error else {
                return XCTFail("应返回 Keychain 保存失败，实际为：\(error)")
            }
            XCTAssertEqual(status, errSecInteractionNotAllowed)
        }

        XCTAssertEqual(keychain.itemData, Data("old-token".utf8))
        XCTAssertEqual(keychain.updateCallCount, 1)
        XCTAssertEqual(keychain.addCallCount, 0)
        XCTAssertEqual(keychain.deleteCallCount, 0)
    }

    func testTokenStoreAddsOnlyWhenItemIsMissing() throws {
        let keychain = TestKeychainOperations()
        let store = TokenStore(keychain: keychain)

        try store.save("new-token")

        XCTAssertEqual(keychain.itemData, Data("new-token".utf8))
        XCTAssertEqual(keychain.updateCallCount, 1)
        XCTAssertEqual(keychain.addCallCount, 1)
        XCTAssertEqual(keychain.deleteCallCount, 0)
    }

    func testTokenStoreAddFailureDoesNotCreatePartialItem() throws {
        let keychain = TestKeychainOperations(forcedAddStatus: errSecNotAvailable)
        let store = TokenStore(keychain: keychain)

        XCTAssertThrowsError(try store.save("new-token")) { error in
            guard case TokenStoreError.saveFailed(let status) = error else {
                return XCTFail("应返回 Keychain 保存失败，实际为：\(error)")
            }
            XCTAssertEqual(status, errSecNotAvailable)
        }

        XCTAssertNil(keychain.itemData)
        XCTAssertEqual(keychain.updateCallCount, 1)
        XCTAssertEqual(keychain.addCallCount, 1)
        XCTAssertEqual(keychain.deleteCallCount, 0)
    }

    func testTokenStoreKeepsProfileTokensInIndependentAccounts() throws {
        let keychain = TestKeychainOperations()
        let store = TokenStore(keychain: keychain)

        try store.save("token-a", profileID: "mac-a")
        try store.save("token-b", profileID: "mac-b")

        XCTAssertEqual(try store.load(profileID: "mac-a"), "token-a")
        XCTAssertEqual(try store.load(profileID: "mac-b"), "token-b")
        XCTAssertEqual(store.load(), "")
        XCTAssertEqual(keychain.accounts, ["agentd-profile.mac-a", "agentd-profile.mac-b"])
    }

    func testLoopbackConnectionUsesMemoryWhenCatalystKeychainEntitlementIsMissing() async throws {
        let suiteName = "PairingLinkTests.EphemeralLocalCredential.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = TestKeychainOperations(forcedCopyStatus: errSecMissingEntitlement)
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            allowsEphemeralLocalCredentialFallback: true
        )

        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://127.0.0.1:8787",
            token: "local-token"
        ))

        XCTAssertTrue(store.isConfigured)
        XCTAssertEqual(store.token, "local-token")
        XCTAssertEqual(store.activeConnectionProfile?.endpoint, "http://127.0.0.1:8787")
        XCTAssertNil(defaults.data(forKey: "agentd.connectionProfiles.v2"))
        XCTAssertNil(defaults.string(forKey: "agentd.activeConnectionProfileID.v1"))
        XCTAssertNil(defaults.string(forKey: "agentd.endpoint"))

        let profileID = try XCTUnwrap(store.activeConnectionProfileID)
        XCTAssertTrue(try store.renameConnectionProfile(id: profileID, displayName: "本机调试"))
        XCTAssertNil(defaults.data(forKey: "agentd.connectionProfiles.v2"))

        store.suspendCredentialsForBackground()
        XCTAssertEqual(store.token, "local-token")
        XCTAssertTrue(store.isConfigured)

        try await store.clearPairing()
        XCTAssertFalse(store.isConfigured)
        XCTAssertTrue(store.connectionProfiles.isEmpty)
        let persistedProfiles = try XCTUnwrap(defaults.data(forKey: "agentd.connectionProfiles.v2"))
        XCTAssertTrue(try JSONDecoder().decode([ConnectionProfile].self, from: persistedProfiles).isEmpty)
    }

    func testPrivateSimulatorConnectionUsesMemoryWhenKeychainEntitlementIsMissing() async throws {
        let suiteName = "PairingLinkTests.EphemeralSimulatorCredential.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = TestKeychainOperations(forcedCopyStatus: errSecMissingEntitlement)
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            allowsEphemeralLocalCredentialFallback: true
        )

        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://192.168.1.20:8787",
            token: "simulator-token"
        ))

        XCTAssertTrue(store.isConfigured)
        XCTAssertEqual(store.token, "simulator-token")
        XCTAssertEqual(store.activeConnectionProfile?.endpoint, "http://192.168.1.20:8787")
        XCTAssertNil(defaults.data(forKey: "agentd.connectionProfiles.v2"))
        XCTAssertNil(defaults.string(forKey: "agentd.activeConnectionProfileID.v1"))
        XCTAssertNil(defaults.string(forKey: "agentd.endpoint"))
    }

    func testSwitchingFromEphemeralProfileRemovesItsMetadataAndMemoryCredential() async throws {
        let suiteName = "PairingLinkTests.EphemeralSwitchCleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = TestKeychainOperations(forcedCopyStatus: errSecMissingEntitlement)
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            allowsEphemeralLocalCredentialFallback: true
        )

        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://192.168.1.20:8787",
            token: "ephemeral-token"
        ))
        let ephemeralProfileID = try XCTUnwrap(store.activeConnectionProfileID)

        keychain.forcedCopyStatus = nil
        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "https://agent.example.com",
            token: "persistent-token",
            profileTarget: .newProfile(id: "mac-b", displayName: "远程 Mac")
        ))

        XCTAssertEqual(store.connectionProfiles.map(\.id), ["mac-b"])
        let persistedData = try XCTUnwrap(defaults.data(forKey: "agentd.connectionProfiles.v2"))
        XCTAssertEqual(try JSONDecoder().decode([ConnectionProfile].self, from: persistedData).map(\.id), ["mac-b"])
        XCTAssertNil(keychain.data(account: "agentd-profile.\(ephemeralProfileID)"))
        await XCTAssertThrowsErrorAsync(try await store.prepareConnectionProfileSwitch(id: ephemeralProfileID)) { error in
            XCTAssertEqual(error as? ConnectionProfileError, .notFound)
        }

        let relaunchedStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        XCTAssertEqual(relaunchedStore.connectionProfiles.map(\.id), ["mac-b"])
        XCTAssertEqual(relaunchedStore.activeConnectionProfileID, "mac-b")
        XCTAssertEqual(relaunchedStore.token, "persistent-token")

        // 复用同一个 ID 时必须重新写入 Keychain；若旧内存 Token 未清理，Vault 会误判 unchanged。
        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "https://replacement.example.com",
            token: "ephemeral-token",
            profileTarget: .newProfile(id: ephemeralProfileID, displayName: "重新添加")
        ))
        XCTAssertEqual(
            keychain.data(account: "agentd-profile.\(ephemeralProfileID)"),
            Data("ephemeral-token".utf8)
        )
    }

    func testEphemeralProfilePersistsOnlyAfterKeychainRecovers() async throws {
        let suiteName = "PairingLinkTests.EphemeralPersistenceTransition.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = TestKeychainOperations(forcedCopyStatus: errSecMissingEntitlement)
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            allowsEphemeralLocalCredentialFallback: true
        )

        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://192.168.1.20:8787",
            token: "ephemeral-token"
        ))
        let profileID = try XCTUnwrap(store.activeConnectionProfileID)

        await XCTAssertThrowsErrorAsync(try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "https://agent.example.com",
            token: "ephemeral-token",
            profileTarget: .existingProfile(id: profileID)
        ))) { error in
            XCTAssertTrue((error as? TokenStoreError)?.isMissingEntitlement == true)
        }
        XCTAssertEqual(store.activeConnectionProfile?.endpoint, "http://192.168.1.20:8787")
        XCTAssertEqual(store.token, "ephemeral-token")
        XCTAssertNil(defaults.data(forKey: "agentd.connectionProfiles.v2"))

        keychain.forcedCopyStatus = nil
        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "https://agent.example.com",
            token: "ephemeral-token",
            profileTarget: .existingProfile(id: profileID)
        ))

        XCTAssertEqual(store.activeConnectionProfile?.endpoint, "https://agent.example.com")
        XCTAssertEqual(keychain.data(account: "agentd-profile.\(profileID)"), Data("ephemeral-token".utf8))
        let persistedData = try XCTUnwrap(defaults.data(forKey: "agentd.connectionProfiles.v2"))
        XCTAssertEqual(try JSONDecoder().decode([ConnectionProfile].self, from: persistedData).map(\.id), [profileID])
    }

    func testMissingKeychainEntitlementNeverFallsBackForPublicEndpoint() async throws {
        let suiteName = "PairingLinkTests.RemoteCredential.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = TestKeychainOperations(forcedCopyStatus: errSecMissingEntitlement)
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            allowsEphemeralLocalCredentialFallback: true
        )

        do {
            _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
                endpoint: "https://agent.example.com",
                token: "remote-token"
            ))
            XCTFail("公网地址不得降级为进程内凭据")
        } catch let error as TokenStoreError {
            XCTAssertTrue(error.isMissingEntitlement)
        }

        XCTAssertFalse(store.isConfigured)
        XCTAssertTrue(store.connectionProfiles.isEmpty)
    }

    func testInitialConnectionErrorClassifierRequiresStandaloneHTTP401() {
        XCTAssertTrue(InitialConnectionErrorClassifier.isCredentialRejection("HTTP 401 Unauthorized"))
        XCTAssertTrue(InitialConnectionErrorClassifier.isCredentialRejection("unauthorized"))
        XCTAssertFalse(InitialConnectionErrorClassifier.isCredentialRejection("OSStatus -34018"))
        XCTAssertFalse(InitialConnectionErrorClassifier.isCredentialRejection("request 14018 failed"))
    }

    func testLegacySingleConnectionMigratesWithoutWritingTokenToDefaults() throws {
        let suiteName = "PairingLinkTests.ProfileMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.10:8787/", forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations(itemData: Data("legacy-secret".utf8))

        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        let profile = try XCTUnwrap(store.activeConnectionProfile)
        XCTAssertEqual(profile.endpoint, "http://100.64.0.10:8787")
        XCTAssertEqual(store.endpoint, profile.endpoint)
        XCTAssertEqual(store.token, "legacy-secret")
        XCTAssertEqual(keychain.data(account: "agentd-profile.\(profile.id)"), Data("legacy-secret".utf8))
        XCTAssertNil(keychain.data(account: "agentd-token"))
        let persistedData = try XCTUnwrap(defaults.data(forKey: "agentd.connectionProfiles.v1"))
        let persistedText = String(decoding: persistedData, as: UTF8.self)
        XCTAssertFalse(persistedText.contains("legacy-secret"), "UserDefaults 只能保存非敏感档案元数据")
    }

    func testLegacyMigrationKeychainFailurePreservesOldConnection() throws {
        let suiteName = "PairingLinkTests.ProfileMigrationFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let endpoint = "http://100.64.0.11:8787"
        defaults.set(endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations(
            itemData: Data("legacy-secret".utf8),
            forcedUpdateStatus: errSecInteractionNotAllowed
        )

        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        XCTAssertEqual(store.endpoint, endpoint)
        XCTAssertEqual(store.token, "legacy-secret")
        XCTAssertTrue(store.connectionProfiles.isEmpty)
        XCTAssertNil(store.activeConnectionProfileID)
        XCTAssertNil(defaults.data(forKey: "agentd.connectionProfiles.v1"))
        XCTAssertEqual(defaults.string(forKey: "agentd.endpoint"), endpoint)
        XCTAssertEqual(keychain.data(account: "agentd-token"), Data("legacy-secret".utf8))
        XCTAssertEqual(keychain.deleteCallCount, 0)
    }

    func testLegacyTokenNeverOverwritesExistingProfilesWhenActiveTokenIsMissing() throws {
        let suiteName = "PairingLinkTests.ProfileMigrationExistingProfiles.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(id: "mac-a", displayName: "当前 Mac", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: nil),
            ConnectionProfile(id: "mac-b", displayName: "备用 Mac", endpoint: "http://100.64.0.20:8787", lastSuccessfulAt: nil)
        ]
        let encodedProfiles = try JSONEncoder().encode(profiles)
        defaults.set(encodedProfiles, forKey: "agentd.connectionProfiles.v1")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profiles[0].endpoint, forKey: "agentd.endpoint")
        // 模拟旧迁移已留下档案，但 legacy 删除失败、当前 profile Token 又暂时缺失的恢复现场。
        let keychain = TestKeychainOperations(itemData: Data("legacy-leftover".utf8))

        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        XCTAssertEqual(store.connectionProfiles, profiles)
        XCTAssertNil(store.activeConnectionProfileID)
        XCTAssertEqual(store.endpoint, profiles[0].endpoint)
        XCTAssertEqual(store.token, "")
        XCTAssertFalse(store.isConfigured, "残留 legacy Token 不能绕过缺失的当前档案 Token")
        XCTAssertFalse(store.canEnterWorkbench)
        XCTAssertEqual(defaults.data(forKey: "agentd.connectionProfiles.v1"), encodedProfiles)
        XCTAssertEqual(keychain.accounts, ["agentd-token"])
        XCTAssertEqual(keychain.copyCallCount, 1, "已有 Profile 时只读取当前 account，不得回退扫描 legacy")
        XCTAssertEqual(keychain.deleteCallCount, 0)
    }

    func testBackgroundCredentialSuspensionKeepsWorkbenchUntilForegroundRestore() async throws {
        let suiteName = "PairingLinkTests.BackgroundCredentialSuspension.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "当前 Mac",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        XCTAssertTrue(store.isConfigured)
        XCTAssertTrue(store.canEnterWorkbench)

        store.suspendCredentialsForBackground()

        XCTAssertEqual(store.token, "", "后台仍需清空公开内存 Token")
        XCTAssertFalse(store.isConfigured)
        XCTAssertTrue(store.isCredentialMemorySuspended)
        XCTAssertTrue(store.canEnterWorkbench, "后台缩略图应保留离开前的工作台或会话")
        XCTAssertNil(store.authenticatedCredentialFingerprint)
        XCTAssertThrowsError(try store.makeSessionStoreAPIClient()) { error in
            XCTAssertTrue(error is CancellationError, "凭据挂起期间应取消认证请求，而不是创建空 Token Runtime")
        }

        try await store.restoreCredentialsForForeground()

        XCTAssertEqual(store.token, "token-a")
        XCTAssertFalse(store.isCredentialMemorySuspended)
        XCTAssertTrue(store.isConfigured)
        XCTAssertTrue(store.canEnterWorkbench)
        XCTAssertEqual(store.authenticatedCredentialFingerprint, connectionCredentialFingerprint("token-a"))
        XCTAssertFalse(store.acceptsCredentialInvalidation(AgentAPIError.credentialsInvalid(
            status: 401,
            credentialFingerprint: connectionCredentialFingerprint("")
        )))
        XCTAssertTrue(store.acceptsCredentialInvalidation(AgentAPIError.credentialsInvalid(
            status: 401,
            credentialFingerprint: connectionCredentialFingerprint("token-a")
        )))
    }

    func testCommittingNewProfileKeepsPreviousTokenAndPersistsMetadataOnly() async throws {
        let suiteName = "PairingLinkTests.AddProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.10:8787", forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations(itemData: Data("token-a".utf8))
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let oldProfile = try XCTUnwrap(store.activeConnectionProfile)

        try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787/",
            token: "token-b",
            profileTarget: .newProfile(id: "mac-b", displayName: "工作室 Mac")
        ))

        XCTAssertEqual(store.connectionProfiles.count, 2)
        XCTAssertEqual(store.activeConnectionProfileID, "mac-b")
        XCTAssertEqual(store.activeConnectionProfile?.displayName, "工作室 Mac")
        XCTAssertEqual(store.activeConnectionProfile?.endpoint, "http://100.64.0.20:8787")
        XCTAssertEqual(keychain.data(account: "agentd-profile.\(oldProfile.id)"), Data("token-a".utf8))
        XCTAssertEqual(keychain.data(account: "agentd-profile.mac-b"), Data("token-b".utf8))
        let persistedData = try XCTUnwrap(defaults.data(forKey: "agentd.connectionProfiles.v1"))
        let persistedText = String(decoding: persistedData, as: UTF8.self)
        XCTAssertFalse(persistedText.contains("token-a"))
        XCTAssertFalse(persistedText.contains("token-b"))

        let reloaded = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        XCTAssertEqual(reloaded.activeConnectionProfileID, "mac-b")
        XCTAssertEqual(reloaded.token, "token-b")
        XCTAssertEqual(reloaded.connectionProfiles.count, 2)
    }

    func testCapabilityNegotiationIsIsolatedPerHostAndRejectsStaleLease() async throws {
        let suiteName = "PairingLinkTests.CapabilityIsolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = TestKeychainOperations()
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        let enabled = HostCapabilityNegotiation(
            wasNegotiated: true,
            declared: ["file_upload_v1"],
            statuses: [
                AgentCapabilityStatus(
                    name: "file_upload_v1",
                    state: "enabled",
                    reason: "available"
                )
            ]
        )
        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.10:8787",
            token: "token-a",
            profileTarget: .newProfile(id: "mac-a", displayName: "Mac A"),
            installationID: "installation-a",
            capabilityNegotiation: enabled
        ))
        let macALease = try XCTUnwrap(store.capabilityLease(for: "file_upload_v1"))
        XCTAssertEqual(store.capabilityDecision(for: "file_upload_v1"), .enabled)

        let disabled = HostCapabilityNegotiation(
            wasNegotiated: true,
            declared: [],
            statuses: [
                AgentCapabilityStatus(
                    name: "file_upload_v1",
                    state: "locally_disabled",
                    reason: "disabled_by_local_config"
                )
            ]
        )
        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "mac-b", displayName: "Mac B"),
            installationID: "installation-b",
            capabilityNegotiation: disabled
        ))

        XCTAssertEqual(store.capabilityDecision(for: "file_upload_v1"), .locallyDisabled)
        XCTAssertNil(store.capabilityLease(for: "file_upload_v1"))
        XCTAssertFalse(
            store.isCurrentCapabilityLease(macALease),
            "切换主机后不能继续使用上一台 Mac 的 capability lease"
        )
    }

    func testV1ProfileBindsInstallationIdentityOnFirstSuccessfulCommit() async throws {
        let suiteName = "PairingLinkTests.ProfileV2IdentityMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let generation = store.connectionGeneration

        _ = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: profile.endpoint,
            token: "token-a",
            profileTarget: .existingProfile(id: profile.id),
            installationID: " 550E8400-E29B-41D4-A716-446655440000 "
        ))

        XCTAssertEqual(
            store.activeConnectionProfile?.installationID,
            "550e8400-e29b-41d4-a716-446655440000"
        )
        XCTAssertEqual(store.activeHostScope.profileID, profile.id)
        XCTAssertEqual(
            store.activeHostScope.installationID,
            "550e8400-e29b-41d4-a716-446655440000"
        )
        XCTAssertEqual(store.connectionGeneration, generation + 1)
        XCTAssertNotNil(defaults.data(forKey: "agentd.connectionProfiles.v2"))
    }

    func testInstallationIdentityMismatchRejectsCommitWithoutChangingActiveHost() async throws {
        let suiteName = "PairingLinkTests.ProfileIdentityMismatch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let oldScope = store.activeHostScope
        let oldGeneration = store.connectionGeneration
        let oldUpdateCount = keychain.updateCallCount

        await XCTAssertThrowsErrorAsync(try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.99:8787",
            token: "replacement-token",
            profileTarget: .existingProfile(id: profile.id),
            installationID: "installation-b"
        ))) { error in
            XCTAssertEqual(
                error as? ConnectionProfileError,
                .installationIdentityMismatch(profileName: "Mac A")
            )
        }

        XCTAssertEqual(store.activeHostScope, oldScope)
        XCTAssertEqual(store.connectionGeneration, oldGeneration)
        XCTAssertEqual(store.endpoint, profile.endpoint)
        XCTAssertEqual(store.token, "token-a")
        XCTAssertEqual(keychain.updateCallCount, oldUpdateCount)
    }

    func testDuplicateInstallationCannotCreateSecondProfile() async throws {
        let suiteName = "PairingLinkTests.DuplicateInstallation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil,
            installationID: "same-installation"
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        await XCTAssertThrowsErrorAsync(try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "mac-b", displayName: "重复 Mac"),
            installationID: "same-installation"
        ))) { error in
            XCTAssertEqual(
                error as? ConnectionProfileError,
                .duplicateInstallation(profileName: "Mac A")
            )
        }
        XCTAssertEqual(store.connectionProfiles, [profile])
        XCTAssertNil(keychain.data(account: "agentd-profile.mac-b"))
    }

    func testNewPairingURLCarriesNewProfileTargetThroughPreparationAndCommit() async throws {
        let suiteName = "PairingLinkTests.NewPairingTarget.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let currentProfile = ConnectionProfile(
            id: "windows-a",
            displayName: "Windows",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil,
            installationID: "installation-windows"
        )
        defaults.set(try JSONEncoder().encode([currentProfile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(currentProfile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(currentProfile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("windows-token".utf8), account: "agentd-profile.windows-a")
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            routeProbe: { _, _, _ in }
        )
        let url = try XCTUnwrap(URL(
            string: "mimiremote://connect?endpoint=http%3A%2F%2F100.94.18.120%3A8787&token=mac-token"
        ))

        let prepared = try await store.prepareNewPairingURL(url, displayName: "本机 Mac")
        guard case .newProfile(let newProfileID, let displayName) = prepared.profileTarget else {
            return XCTFail("新增二维码必须在连接准备前携带 newProfile 目标")
        }
        XCTAssertFalse(newProfileID.isEmpty)
        XCTAssertEqual(displayName, "本机 Mac")

        // 注入候选 Mac 在 /api/version 返回的稳定安装身份，验证它不会与当前 Windows
        // 档案做“必须相等”校验，而是按独立档案提交。
        let preparedWithInstallationIdentity = PreparedConnectionSettings(
            endpoint: prepared.endpoint,
            token: prepared.token,
            profileTarget: prepared.profileTarget,
            validatedAt: prepared.validatedAt,
            installationID: "installation-mac"
        )
        _ = try await store.commitConnectionSettings(preparedWithInstallationIdentity)

        XCTAssertEqual(store.connectionProfiles.count, 2)
        XCTAssertEqual(store.activeConnectionProfileID, newProfileID)
        XCTAssertEqual(store.activeConnectionProfile?.displayName, "本机 Mac")
        XCTAssertEqual(store.activeConnectionProfile?.installationID, "installation-mac")
        XCTAssertEqual(
            keychain.data(account: "agentd-profile.\(newProfileID)"),
            Data("mac-token".utf8)
        )
    }

    func testUnboundV1ProfileCannotBindToAnotherSavedMacInstallation() async throws {
        let suiteName = "PairingLinkTests.DuplicateV1Binding.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(
                id: "mac-a",
                displayName: "Mac A",
                endpoint: "http://100.64.0.10:8787",
                lastSuccessfulAt: nil,
                installationID: "installation-a"
            ),
            ConnectionProfile(
                id: "mac-b",
                displayName: "旧版 Mac B",
                endpoint: "http://100.64.0.20:8787",
                lastSuccessfulAt: nil
            )
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v2")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profiles[0].endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        await XCTAssertThrowsErrorAsync(try await store.commitConnectionSettings(
            PreparedConnectionSettings(
                endpoint: profiles[1].endpoint,
                token: "token-b",
                profileTarget: .existingProfile(id: "mac-b"),
                installationID: "installation-a"
            )
        )) { error in
            XCTAssertEqual(
                error as? ConnectionProfileError,
                .duplicateInstallation(profileName: "Mac A")
            )
        }
        XCTAssertNil(store.connectionProfiles.first(where: { $0.id == "mac-b" })?.installationID)
    }

    func testPreparedHostContextRejectsProfileRevisionOrTokenLeaseMismatch() async {
        let endpoint = "http://100.64.0.20:8787"
        let target = PreparedConnectionProfileTarget.existingProfile(id: "mac-b")
        let originalLease = PreparedHostLease(
            endpoint: endpoint,
            installationID: "installation-b",
            profileTarget: target,
            profileRevision: 3,
            tokenFingerprint: "token-fingerprint-a"
        )
        let context = PreparedHostContext(
            lease: originalLease,
            runtimeBundle: AppServerRuntimeBundle(endpoint: endpoint, token: "token-b"),
            expiresAt: Date().addingTimeInterval(8)
        )
        let mismatchedLease = PreparedHostLease(
            endpoint: endpoint,
            installationID: "installation-b",
            profileTarget: target,
            profileRevision: 4,
            tokenFingerprint: "token-fingerprint-b"
        )

        XCTAssertThrowsError(try context.validatedRuntimeBundle(matching: mismatchedLease)) { error in
            XCTAssertEqual(error as? ConnectionProfileError, .preparedContextMismatch)
        }
        await context.discard()
    }

    func testSameInstallationCanUpdateExistingProfileEndpoint() async throws {
        let suiteName = "PairingLinkTests.UpdateProfileEndpoint.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        let didCommit = try await store.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.88:8787",
            token: "token-a",
            profileTarget: .existingProfile(id: profile.id),
            installationID: "installation-a"
        ))

        XCTAssertTrue(didCommit)
        XCTAssertEqual(store.activeConnectionProfileID, profile.id)
        XCTAssertEqual(store.activeConnectionProfile?.endpoint, "http://100.64.0.88:8787")
        XCTAssertEqual(store.activeConnectionProfile?.installationID, "installation-a")
    }

    func testDeletingOtherProfileIsKeychainFirstAndKeepsCurrentProfile() async throws {
        let suiteName = "PairingLinkTests.DeleteOtherProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(id: "mac-a", displayName: "当前 Mac", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: nil),
            ConnectionProfile(id: "mac-b", displayName: "备用 Mac", endpoint: "http://100.64.0.20:8787", lastSuccessfulAt: nil)
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v1")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        keychain.forcedDeleteStatus = errSecInteractionNotAllowed
        await XCTAssertThrowsErrorAsync(try await store.deleteConnectionProfile(id: "mac-b"))
        XCTAssertEqual(store.connectionProfiles.map(\.id), ["mac-a", "mac-b"])
        XCTAssertEqual(keychain.data(account: "agentd-profile.mac-b"), Data("token-b".utf8))

        keychain.forcedDeleteStatus = nil
        try await store.deleteConnectionProfile(id: "mac-b")
        XCTAssertEqual(store.connectionProfiles.map(\.id), ["mac-a"])
        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(keychain.data(account: "agentd-profile.mac-a"), Data("token-a".utf8))
        XCTAssertNil(keychain.data(account: "agentd-profile.mac-b"))
    }

    func testCurrentProfileRequiresClearPairingAndFailureDoesNotHalfCommit() async throws {
        let suiteName = "PairingLinkTests.ClearCurrentProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(id: "mac-a", displayName: "当前 Mac", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: nil),
            ConnectionProfile(id: "mac-b", displayName: "备用 Mac", endpoint: "http://100.64.0.20:8787", lastSuccessfulAt: nil)
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v1")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profiles[0].endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        await XCTAssertThrowsErrorAsync(try await store.deleteConnectionProfile(id: "mac-a")) { error in
            XCTAssertEqual(error as? ConnectionProfileError, .cannotDeleteCurrent)
        }
        keychain.forcedDeleteStatus = errSecInteractionNotAllowed
        await XCTAssertThrowsErrorAsync(try await store.clearPairing())
        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(store.token, "token-a")
        XCTAssertEqual(store.connectionProfiles, profiles)

        keychain.forcedDeleteStatus = nil
        try await store.clearPairing()
        XCTAssertNil(store.activeConnectionProfileID)
        XCTAssertEqual(store.token, "")
        XCTAssertEqual(store.connectionProfiles.map(\.id), ["mac-b"])
        XCTAssertNil(keychain.data(account: "agentd-profile.mac-a"))
        XCTAssertEqual(keychain.data(account: "agentd-profile.mac-b"), Data("token-b".utf8))
    }

    func testConnectionProfileSettingsModelSeparatesCurrentAndActionableOthers() throws {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let model = ConnectionProfileSettingsModel(
            profiles: [
                ConnectionProfile(id: "mac-b", displayName: "备用", endpoint: "http://100.64.0.20:8787", lastSuccessfulAt: newer),
                ConnectionProfile(id: "mac-a", displayName: "当前", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: older)
            ],
            activeProfileID: "mac-a"
        )

        XCTAssertEqual(model.current?.id, "mac-a")
        XCTAssertEqual(model.savedCount, 2)
        XCTAssertEqual(model.current?.canSwitch, false)
        XCTAssertEqual(model.current?.canDelete, false)
        XCTAssertEqual(model.others.map(\.id), ["mac-b"])
        XCTAssertEqual(model.others.first?.canSwitch, true)
        XCTAssertEqual(model.others.first?.canDelete, true)
    }

    func testConnectionTransferLinkReadsSelectedProfileWithoutSwitchingCurrentMac() async throws {
        let suiteName = "PairingLinkTests.ConnectionTransferLink.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(
                id: "mac-a",
                displayName: "Mac A",
                endpoint: "http://100.64.0.10:8787",
                lastSuccessfulAt: nil
            ),
            ConnectionProfile(
                id: "mac-b",
                displayName: "Mac B",
                endpoint: "http://100.64.0.20:8787",
                lastSuccessfulAt: nil
            )
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v2")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profiles[0].endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        let link = try await store.connectionTransferLink(
            profileID: "mac-b",
            issuedAt: Date()
        )
        let credentials = try AppStore.pairingCredentials(from: link.url)

        XCTAssertEqual(credentials.endpoint, profiles[1].endpoint)
        XCTAssertEqual(credentials.token, "token-b")
        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(store.endpoint, profiles[0].endpoint)
        XCTAssertEqual(store.token, "token-a")
    }

    func testFiveSavedProfilesColdStartReadsOnlyActiveProfileToken() throws {
        let suiteName = "PairingLinkTests.ColdStartFiveProfiles.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = (0..<5).map { index in
            ConnectionProfile(
                id: "mac-\(index)",
                displayName: "Mac \(index)",
                endpoint: "http://100.64.0.\(10 + index):8787",
                lastSuccessfulAt: nil,
                installationID: "installation-\(index)"
            )
        }
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v2")
        defaults.set("mac-3", forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profiles[3].endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        for index in 0..<5 {
            keychain.setData(Data("token-\(index)".utf8), account: "agentd-profile.mac-\(index)")
        }

        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        XCTAssertEqual(store.activeConnectionProfileID, "mac-3")
        XCTAssertEqual(store.token, "token-3")
        XCTAssertEqual(keychain.copyCallCount, 1, "冷启动不得读取任何非当前 Mac 的 Keychain 项")
        XCTAssertEqual(keychain.updateCallCount, 0)
        XCTAssertEqual(keychain.addCallCount, 0)
        XCTAssertEqual(keychain.deleteCallCount, 0)
    }

    func testConnectionCredentialRemovalConfirmationCarriesTargetAndExplicitWarning() {
        let currentProfile = ConnectionProfile(
            id: "mac-a",
            displayName: "工作室 Mac",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil
        )
        let savedProfile = ConnectionProfile(
            id: "mac-b",
            displayName: "随身 Mac",
            endpoint: "http://100.64.0.20:8787",
            lastSuccessfulAt: nil
        )

        let forgetCurrent = ConnectionCredentialRemovalConfirmation.forgettingCurrent(currentProfile)
        XCTAssertEqual(forgetCurrent.id, "forget-current:mac-a")
        XCTAssertEqual(forgetCurrent.target, .current(profileID: "mac-a"))
        XCTAssertEqual(forgetCurrent.title, L10n.text("ui.forgot_your_current_mac"))
        XCTAssertTrue(forgetCurrent.message.contains("工作室 Mac"))
        XCTAssertTrue(forgetCurrent.message.contains("Keychain"))
        XCTAssertTrue(forgetCurrent.message.contains(L10n.text("ui.scan_the_qr_code_again_to_pair")))

        let deleteSaved = ConnectionCredentialRemovalConfirmation.deletingSavedProfile(savedProfile)
        XCTAssertEqual(deleteSaved.id, "delete-profile:mac-b")
        XCTAssertEqual(deleteSaved.target, .savedProfile(profileID: "mac-b"))
        XCTAssertTrue(deleteSaved.title.contains("随身 Mac"))
        XCTAssertTrue(deleteSaved.message.contains("随身 Mac"))
        XCTAssertTrue(deleteSaved.message.contains(L10n.text("ui.current_mac")))
        XCTAssertTrue(deleteSaved.message.contains(L10n.text("ui.scan_the_qr_code_again_to_pair")))
    }

    func testRenamingCurrentAndOtherProfilesOnlyPersistsDisplayNames() throws {
        let suiteName = "PairingLinkTests.RenameProfiles.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(id: "mac-a", displayName: "当前 Mac", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: Date(timeIntervalSince1970: 100)),
            ConnectionProfile(id: "mac-b", displayName: "备用 Mac", endpoint: "http://100.64.0.20:8787", lastSuccessfulAt: Date(timeIntervalSince1970: 200))
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v1")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profiles[0].endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        store.connectionStatus = .connected("当前 Mac")
        let copyCallCount = keychain.copyCallCount
        let updateCallCount = keychain.updateCallCount
        let addCallCount = keychain.addCallCount
        let deleteCallCount = keychain.deleteCallCount
        let generation = store.connectionGeneration

        XCTAssertTrue(try store.renameConnectionProfile(id: "mac-a", displayName: "  工作室 Mac  "))
        XCTAssertTrue(try store.renameConnectionProfile(id: "mac-b", displayName: "随身 Mac"))

        XCTAssertEqual(store.connectionProfiles.map(\.displayName), ["工作室 Mac", "随身 Mac"])
        XCTAssertEqual(store.connectionProfiles.map(\.endpoint), profiles.map(\.endpoint))
        XCTAssertEqual(store.connectionProfiles.map(\.lastSuccessfulAt), profiles.map(\.lastSuccessfulAt))
        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(store.endpoint, profiles[0].endpoint)
        XCTAssertEqual(store.token, "token-a")
        XCTAssertEqual(store.connectionGeneration, generation)
        XCTAssertEqual(store.connectionStatus, .connected("当前 Mac"))
        XCTAssertEqual(keychain.copyCallCount, copyCallCount)
        XCTAssertEqual(keychain.updateCallCount, updateCallCount)
        XCTAssertEqual(keychain.addCallCount, addCallCount)
        XCTAssertEqual(keychain.deleteCallCount, deleteCallCount)
        XCTAssertEqual(keychain.data(account: "agentd-profile.mac-a"), Data("token-a".utf8))
        XCTAssertEqual(keychain.data(account: "agentd-profile.mac-b"), Data("token-b".utf8))

        let persistedData = try XCTUnwrap(defaults.data(forKey: "agentd.connectionProfiles.v1"))
        let persistedProfiles = try JSONDecoder().decode([ConnectionProfile].self, from: persistedData)
        XCTAssertEqual(persistedProfiles, store.connectionProfiles)
        XCTAssertEqual(defaults.string(forKey: "agentd.activeConnectionProfileID.v1"), "mac-a")
        XCTAssertEqual(defaults.string(forKey: "agentd.endpoint"), profiles[0].endpoint)
    }

    func testProfileRenameRejectsInvalidOrMissingAndSameNameIsNoOp() throws {
        let suiteName = "PairingLinkTests.RenameValidation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(id: "mac-a", displayName: "当前 Mac", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: nil)
        ]
        let originalData = try JSONEncoder().encode(profiles)
        defaults.set(originalData, forKey: "agentd.connectionProfiles.v1")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profiles[0].endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let copyCallCount = keychain.copyCallCount
        let generation = store.connectionGeneration

        XCTAssertThrowsError(try store.renameConnectionProfile(id: "mac-a", displayName: " \n\t ")) { error in
            XCTAssertEqual(error as? ConnectionProfileError, .invalidDisplayName)
        }
        let oversizedName = String(repeating: "名", count: AppStore.connectionProfileDisplayNameLimit + 1)
        XCTAssertThrowsError(try store.renameConnectionProfile(id: "mac-a", displayName: oversizedName)) { error in
            XCTAssertEqual(
                error as? ConnectionProfileError,
                .displayNameTooLong(maximum: AppStore.connectionProfileDisplayNameLimit)
            )
        }
        XCTAssertThrowsError(try store.renameConnectionProfile(id: "missing", displayName: "其它 Mac")) { error in
            XCTAssertEqual(error as? ConnectionProfileError, .notFound)
        }
        XCTAssertFalse(try store.renameConnectionProfile(id: "mac-a", displayName: "  当前 Mac  "))

        XCTAssertEqual(store.connectionProfiles, profiles)
        XCTAssertEqual(defaults.data(forKey: "agentd.connectionProfiles.v1"), originalData)
        XCTAssertEqual(store.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(store.endpoint, profiles[0].endpoint)
        XCTAssertEqual(store.token, "token-a")
        XCTAssertEqual(store.connectionGeneration, generation)
        XCTAssertEqual(keychain.copyCallCount, copyCallCount)
        XCTAssertEqual(keychain.updateCallCount, 0)
        XCTAssertEqual(keychain.addCallCount, 0)
        XCTAssertEqual(keychain.deleteCallCount, 0)
        XCTAssertEqual(keychain.data(account: "agentd-profile.mac-a"), Data("token-a".utf8))
    }

    func testClearPairingDeleteFailurePreservesPreviousConnection() async throws {
        let suiteName = "PairingLinkTests.ClearPairingFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oldEndpoint = "http://100.64.0.10:8787"
        let oldToken = "old-token"
        defaults.set(oldEndpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations(
            itemData: Data(oldToken.utf8),
            forcedDeleteStatus: errSecInteractionNotAllowed
        )
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain)
        )
        store.connectionStatus = .connected("Tailscale")
        store.lastError = "保留现场"
        let oldGeneration = store.connectionGeneration
        let deleteCallCountBeforeClear = keychain.deleteCallCount

        await XCTAssertThrowsErrorAsync(try await store.clearPairing()) { error in
            guard case TokenStoreError.deleteFailed(let status) = error else {
                return XCTFail("应返回 Keychain 删除失败，实际为：\(error)")
            }
            XCTAssertEqual(status, errSecInteractionNotAllowed)
        }

        XCTAssertEqual(store.endpoint, oldEndpoint)
        XCTAssertEqual(store.token, oldToken)
        XCTAssertEqual(store.connectionGeneration, oldGeneration)
        XCTAssertEqual(store.connectionStatus, .connected("Tailscale"))
        XCTAssertEqual(store.lastError, "保留现场")
        XCTAssertEqual(defaults.string(forKey: "agentd.endpoint"), oldEndpoint)
        XCTAssertEqual(keychain.itemData, Data(oldToken.utf8))
        XCTAssertEqual(keychain.deleteCallCount, deleteCallCountBeforeClear + 1)
    }

    func testClearPairingCommitsAfterKeychainDeleteSucceeds() async throws {
        let suiteName = "PairingLinkTests.ClearPairingSuccess.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("http://100.64.0.10:8787", forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations(itemData: Data("old-token".utf8))
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain)
        )
        let oldGeneration = store.connectionGeneration
        let deleteCallCountBeforeClear = keychain.deleteCallCount

        try await store.clearPairing()

        XCTAssertEqual(store.endpoint, "http://127.0.0.1:8787")
        XCTAssertEqual(store.token, "")
        XCTAssertEqual(store.connectionGeneration, oldGeneration + 1)
        XCTAssertNil(defaults.string(forKey: "agentd.endpoint"))
        XCTAssertNil(keychain.itemData)
        XCTAssertEqual(keychain.deleteCallCount, deleteCallCountBeforeClear + 1)
    }

    func testATSAllowsTailscaleHTTPWithoutLocalNetworkingOverride() throws {
        let ats = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        XCTAssertEqual(
            ats["NSAllowsArbitraryLoads"] as? Bool,
            true,
            "iOS 27 上 Tailscale 裸 IP HTTP 需要系统层放行，公网 HTTP 由应用层拒绝"
        )
        XCTAssertNil(
            ats["NSAllowsLocalNetworking"],
            "不得与 NSAllowsArbitraryLoads 同时声明，否则新系统会忽略全局放行"
        )

        let domains = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: Any])
        let tailscale = try XCTUnwrap(domains["ts.net"] as? [String: Any])
        XCTAssertEqual(tailscale["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true)
        XCTAssertEqual(tailscale["NSIncludesSubdomains"] as? Bool, true)
    }

    func testParsesEncodedPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }

    func testParsesConnectURL() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://connect?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }

    func testConnectionTransferLinkUsesMacCompatibleConnectFormatAndTenMinuteWindow() throws {
        let issuedAt = Date()
        let link = try ConnectionTransferLink(
            endpoint: "http://100.64.0.1:8787/",
            token: "token+with/slash",
            issuedAt: issuedAt
        )
        let components = try XCTUnwrap(URLComponents(url: link.url, resolvingAgainstBaseURL: false))
        let queryItems = try XCTUnwrap(components.queryItems)
        let queryValues = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        let credentials = try AppStore.pairingCredentials(from: link.url)

        XCTAssertEqual(components.scheme, "mimiremote")
        XCTAssertEqual(components.host, "connect")
        XCTAssertEqual(queryItems.map(\.name), ["endpoint", "expires_at", "issued_at", "token"])
        XCTAssertEqual(queryValues["endpoint"], "http://100.64.0.1:8787")
        XCTAssertEqual(queryValues["token"], "token+with/slash")
        XCTAssertEqual(link.expiresAt.timeIntervalSince(issuedAt), 10 * 60)
        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(credentials.token, "token+with/slash")
    }

    func testParsesUnexpiredPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://connect?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef&expires_at=4102444800"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
    }

    func testParsesSignedPairingTicketWithoutLongTermToken() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&issued_at=2026-06-29T10%3A00%3A00Z&expires_at=4102444800&pair_sig=abcdef"))

        let ticket = try XCTUnwrap(AppStore.pairingTicket(from: url))

        XCTAssertEqual(ticket.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(ticket.issuedAt, "2026-06-29T10:00:00Z")
        XCTAssertEqual(ticket.expiresAt, "4102444800")
        XCTAssertEqual(ticket.pairSignature, "abcdef")
        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .missingToken)
        }
    }

    func testParsesSignedPairingTicketWithRFC3339NanoTimestamps() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&issued_at=2026-07-14T15%3A07%3A00.819278Z&expires_at=2099-12-31T23%3A59%3A59.123456Z&pair_sig=abcdef"))

        let ticket = try XCTUnwrap(AppStore.pairingTicket(from: url))

        XCTAssertEqual(ticket.issuedAt, "2026-07-14T15:07:00.819278Z")
        XCTAssertEqual(ticket.expiresAt, "2099-12-31T23:59:59.123456Z")
        XCTAssertEqual(ticket.pairSignature, "abcdef")
    }

    func testTailcatPairingLinkCarriesTemporaryAddressAndClientKey() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F127.0.0.1%3A8787&issued_at=2026-09-01T00%3A00%3A00Z&expires_at=4102444800&pair_sig=abcdef&transport=tailcat&tailcat_pair_address=tc%3Atest-address"))
        let link = try XCTUnwrap(TailcatPairingLink.parse(url))

        XCTAssertEqual(link.ticket.endpoint, "http://127.0.0.1:8787")
        XCTAssertEqual(link.pairAddress, "tc:test-address")
        let request = link.ticket.claimRequest(tailcatClientKey: "nodekey:test-client")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String]
        )
        XCTAssertEqual(object["tailcat_client_key"], "nodekey:test-client")
    }

    func testTailcatPairingLinkRequiresTemporaryAddress() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F127.0.0.1%3A8787&issued_at=2026-09-01T00%3A00%3A00Z&expires_at=4102444800&pair_sig=abcdef&transport=tailcat"))

        XCTAssertThrowsError(try TailcatPairingLink.parse(url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .missingTailcatAddress)
        }
    }

    func testRejectsExpiredPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://connect?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef&expires_at=1"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .expired)
        }
    }

    func testParsesSingleSlashPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote:/pair?endpoint=100.64.0.1:8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
    }

    func testRejectsPairingURLWithoutEndpoint() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?token=0123456789abcdef0123456789abcdef"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .missingEndpoint)
        }
    }

    func testRejectsPairingURLWithoutToken() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .missingToken)
        }
    }

    func testRejectsUnsupportedScheme() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .unsupportedURL)
        }
    }

    func testRejectsEndpointWithPath() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787%2Fapi&token=0123456789abcdef0123456789abcdef"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertTrue(error is AgentAPIError)
        }
    }

    func testRejectsPublicHTTPHost() throws {
        XCTAssertThrowsError(try AppStore.validatedEndpoint("http://example.com:8787")) { error in
            guard let apiError = error as? AgentAPIError,
                  case .insecurePublicHTTPEndpoint(let host) = apiError
            else {
                return XCTFail("公网 HTTP 应返回可操作的安全错误")
            }
            XCTAssertEqual(host, "example.com")
            XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
            XCTAssertTrue(error.localizedDescription.contains("agentd pair"))
        }
    }

    func testRejectsRetiredPublicHTTPIPv4Endpoint() throws {
        XCTAssertThrowsError(try AppStore.validatedEndpoint("http://14.103.53.126"))
        XCTAssertThrowsError(try AppStore.validatedEndpoint("14.103.53.126:80"))
    }

    func testRejectsSingleLabelHTTPHost() throws {
        XCTAssertThrowsError(try AppStore.validatedEndpoint("http://macbook:8787")) { error in
            XCTAssertTrue(error is AgentAPIError)
        }
    }

    func testRejectsInvalidHTTPIPv4Host() throws {
        XCTAssertThrowsError(try AppStore.validatedEndpoint("http://0.0.0.0:8787")) { error in
            XCTAssertTrue(error is AgentAPIError)
        }
    }

    func testAllowsHTTPSPublicHost() throws {
        XCTAssertEqual(try AppStore.validatedEndpoint("https://example.com"), "https://example.com")
    }

    func testEndpointTransportAssessmentExplainsAllowedAndBlockedRoutes() {
        let tailscale = EndpointTransportPolicy.assess("100.100.10.20:8787")
        XCTAssertEqual(tailscale.status, .allowedPrivateHTTP)
        XCTAssertEqual(tailscale.normalizedEndpoint, "http://100.100.10.20:8787")
        XCTAssertTrue(tailscale.isAllowed)

        let securePublic = EndpointTransportPolicy.assess("HTTPS://example.com:8787/")
        XCTAssertEqual(securePublic.status, .allowedHTTPS)
        XCTAssertEqual(securePublic.normalizedEndpoint, "https://example.com:8787")
        XCTAssertTrue(securePublic.isAllowed)

        let publicHTTP = EndpointTransportPolicy.assess("http://14.103.53.126:8787")
        XCTAssertEqual(publicHTTP.status, .blockedPublicHTTP)
        XCTAssertEqual(publicHTTP.host, "14.103.53.126")
        XCTAssertFalse(publicHTTP.isAllowed)
        XCTAssertTrue(publicHTTP.guidance.contains("明文传输"))
    }

    func testPrivateHTTPEndpointWithoutPortUsesAgentDDefaultPort() throws {
        XCTAssertEqual(
            try AppStore.validatedEndpoint("127.0.0.1"),
            "http://127.0.0.1:8787"
        )
        XCTAssertEqual(
            try AppStore.validatedEndpoint("localhost"),
            "http://localhost:8787"
        )
        XCTAssertEqual(
            try AppStore.validatedEndpoint("100.100.10.20"),
            "http://100.100.10.20:8787"
        )
        XCTAssertEqual(
            try AppStore.validatedEndpoint("127.0.0.1:9000"),
            "http://127.0.0.1:9000"
        )
        XCTAssertEqual(
            try AppStore.validatedEndpoint("https://example.com"),
            "https://example.com"
        )
    }

    func testAllowsLoopbackAndPrivateIPv6HTTP() throws {
        XCTAssertEqual(try AppStore.validatedEndpoint("http://[::1]:8787"), "http://[::1]:8787")
        XCTAssertEqual(
            try AppStore.validatedEndpoint("http://[fd7a:115c:a1e0::1]:8787"),
            "http://[fd7a:115c:a1e0::1]:8787"
        )
    }

    func testPublicHTTPIsRejectedBeforeConnectionProbe() async throws {
        let suiteName = "PairingLinkTests.PublicHTTPPreflight.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
            }
        )

        do {
            _ = try await store.prepareConnectionSettings(
                endpoint: "http://example.com:8787",
                token: "test-token"
            )
            XCTFail("公网 HTTP 不应进入连接探测")
        } catch let error as AgentAPIError {
            guard case .insecurePublicHTTPEndpoint(let host) = error else {
                return XCTFail("应返回公网 HTTP 安全错误")
            }
            XCTAssertEqual(host, "example.com")
        }
        let probedEndpoints = await recorder.endpoints()
        XCTAssertEqual(probedEndpoints, [])
    }

    func testHTTPClientRejectsPublicHTTPBeforeURLSessionRequest() async {
        let client = AgentAPIClient(endpoint: "http://example.com:8787", token: "should-not-leave-device")

        do {
            _ = try await client.health()
            XCTFail("HTTP Client 不应向公网 HTTP 发出请求")
        } catch let error as AgentAPIError {
            guard case .insecurePublicHTTPEndpoint(let host) = error else {
                return XCTFail("HTTP Client 应复用 Endpoint 传输策略")
            }
            XCTAssertEqual(host, "example.com")
        } catch {
            XCTFail("应在进入 URLSession 前返回 Endpoint 安全错误：\(error)")
        }
    }

    func testRESTAuthenticationRejectionBecomesTypedCredentialFailure() async {
        for (token, expectedStatus) in [("expired-401", 401), ("expired-403", 403)] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AuthenticationStubURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = AgentAPIClient(
                endpoint: "http://127.0.0.1:8787",
                token: token,
                session: session
            )

            do {
                _ = try await client.version()
                XCTFail("HTTP \(expectedStatus) 鉴权拒绝应进入访问码失效终态")
            } catch let error as AgentAPIError {
                guard case .credentialsInvalid(let status, let fingerprint) = error else {
                    return XCTFail("应保留鉴权失败类型，实际为：\(error)")
                }
                XCTAssertEqual(status, expectedStatus)
                XCTAssertEqual(fingerprint, connectionCredentialFingerprint(token))
                XCTAssertTrue(error.invalidatesCredentials)
            } catch {
                XCTFail("应返回 AgentAPIError.credentialsInvalid，实际为：\(error)")
            }
        }
    }

    func testRESTPolicy403DoesNotInvalidateCredentials() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = AgentAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "policy-403",
            session: session
        )

        do {
            _ = try await client.version()
            XCTFail("业务策略 403 应正常返回 server error")
        } catch let error as AgentAPIError {
            guard case .server(let status, let message) = error else {
                return XCTFail("目录 allowlist 403 不能误判为访问码失效：\(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "路径不在允许范围内或不可访问")
            XCTAssertFalse(error.invalidatesCredentials)
        } catch {
            XCTFail("应返回 AgentAPIError.server，实际为：\(error)")
        }
    }

    func testWebSocketHandshake401And403BecomeTypedCredentialFailure() throws {
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:8787/api/app-server/ws"))

        for status in [401, 403] {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ))
            let fingerprint = connectionCredentialFingerprint("ws-token")
            let mapped = URLSessionCodexAppServerTransport.mappedTaskError(
                URLError(.badServerResponse),
                response: response,
                credentialFingerprint: fingerprint
            )
            guard case AgentAPIError.credentialsInvalid(let actualStatus, let actualFingerprint) = mapped else {
                return XCTFail("WebSocket 握手 \(status) 应保留访问码失效类型：\(mapped)")
            }
            XCTAssertEqual(actualStatus, status)
            XCTAssertEqual(actualFingerprint, fingerprint)
            XCTAssertTrue(isCredentialInvalidatingError(mapped))
        }
    }

    func testWebSocketGatewayRejectsPublicHTTP() {
        XCTAssertThrowsError(
            try CodexAppServerSessionRuntime.gatewayURL(
                endpoint: "http://example.com:8787",
                sessionID: "thr_security"
            )
        ) { error in
            guard let apiError = error as? AgentAPIError,
                  case .insecurePublicHTTPEndpoint = apiError
            else {
                return XCTFail("WebSocket 也必须阻止公网明文地址")
            }
        }
    }

    func testParsesMimiRemoteScheme() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://connect?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }

    func testParsesLegacyMimiScheme() throws {
        let url = try XCTUnwrap(URL(string: "mimi://connect?endpoint=http%3A%2F%2F192.168.31.163%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://192.168.31.163:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }

    func testInitializationRemovesRetiredFallbackEndpoint() throws {
        let suiteName = "PairingLinkTests.RetiredFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.1:8787", forKey: "agentd.endpoint")
        defaults.set("https://relay.example.com", forKey: "agentd.fallbackEndpoint")
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )

        XCTAssertEqual(store.endpoint, "http://100.64.0.1:8787")
        XCTAssertNil(defaults.object(forKey: "agentd.fallbackEndpoint"))
    }

    func testConnectionPreflightPublishesConnectedStatus() async throws {
        let suiteName = "PairingLinkTests.ConnectionPreflight.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.1:8787", forKey: "agentd.endpoint")
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
            }
        )
        store.token = "test-token"

        let connected = await store.preflightConnection()
        let probedEndpoints = await recorder.endpoints()

        XCTAssertTrue(connected)
        XCTAssertEqual(store.connectionStatus, .connected("Tailscale"))
        XCTAssertEqual(probedEndpoints, ["http://100.64.0.1:8787"])
    }

    func testConnectionPreflightDoesNotRepeatAfterSuccess() async throws {
        let suiteName = "PairingLinkTests.ConnectionPreflightReuse.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.1:8787", forKey: "agentd.endpoint")
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
            }
        )
        store.token = "test-token"

        let firstConnected = await store.preflightConnection()
        let secondConnected = await store.preflightConnection()
        let probedEndpoints = await recorder.endpoints()

        XCTAssertTrue(firstConnected)
        XCTAssertTrue(secondConnected)
        XCTAssertEqual(probedEndpoints, ["http://100.64.0.1:8787"])
    }

    func testSettingsAutomaticConnectionTestRunsOnlyOncePerAppLifetime() async throws {
        let suiteName = "PairingLinkTests.SettingsAutomaticConnectionTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false
        )
        // 使用同步失败的非法地址验证一次性门闩，测试不发出真实网络请求。
        store.endpoint = "not-a-valid-endpoint"
        store.token = "test-token"

        let firstAttemptStarted = await store.testConnectionOnFirstSettingsAppearanceIfNeeded()
        let secondAttemptStarted = await store.testConnectionOnFirstSettingsAppearanceIfNeeded()

        XCTAssertTrue(firstAttemptStarted)
        XCTAssertFalse(secondAttemptStarted)
        guard case .failed = store.connectionStatus else {
            return XCTFail("首次自动测速失败后应发布失败状态")
        }
    }

    func testConnectionPreflightPublishesFailure() async throws {
        let suiteName = "PairingLinkTests.ConnectionPreflightFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.1:8787", forKey: "agentd.endpoint")
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in
                throw URLError(.cannotConnectToHost)
            }
        )
        store.token = "test-token"

        let connected = await store.preflightConnection()

        XCTAssertFalse(connected)
        guard case .failed = store.connectionStatus else {
            return XCTFail("探测失败后应展示连接失败")
        }
    }

    func testConnectionPreflightSkipsUnconfiguredStore() async throws {
        let suiteName = "PairingLinkTests.ConnectionPreflightUnconfigured.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
            }
        )
        store.token = ""

        let connected = await store.preflightConnection()
        let probedEndpoints = await recorder.endpoints()

        XCTAssertFalse(connected)
        XCTAssertEqual(store.connectionStatus, .idle)
        XCTAssertEqual(probedEndpoints, [])
    }

    func testMacCatalystPreflightPrefersDetectedLoopbackWithoutChangingProfileIdentity() async throws {
        let suiteName = "PairingLinkTests.LocalRoutePreferred.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.1:8787", forKey: "agentd.endpoint")
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: true,
            localAgentProbe: { _, _ in },
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
            }
        )
        store.token = "test-token"

        let connected = await store.preflightConnection()
        let probedEndpoints = await recorder.endpoints()

        XCTAssertTrue(connected)
        XCTAssertTrue(store.localAgentDetected)
        XCTAssertTrue(store.isUsingLocalConnection)
        XCTAssertEqual(store.connectionStatus, .connected(L10n.text("ui.direct_connection_to_this_machine")))
        XCTAssertEqual(store.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(store.connectionEndpoint, "http://127.0.0.1:8787")
        XCTAssertEqual(try store.client().endpoint, "http://127.0.0.1:8787")
        XCTAssertEqual(probedEndpoints, ["http://127.0.0.1:8787"])
    }

    func testMacCatalystPreflightFallsBackToConfiguredRouteWhenLocalTokenDoesNotMatch() async throws {
        let suiteName = "PairingLinkTests.LocalRouteFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.1:8787", forKey: "agentd.endpoint")
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: true,
            localAgentProbe: { _, _ in },
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
                if endpoint == "http://127.0.0.1:8787" {
                    throw AgentAPIError.credentialsInvalid(status: 401)
                }
            }
        )
        store.token = "test-token"

        let connected = await store.preflightConnection()
        let probedEndpoints = await recorder.endpoints()

        XCTAssertTrue(connected)
        XCTAssertTrue(store.localAgentDetected)
        XCTAssertFalse(store.isUsingLocalConnection)
        XCTAssertEqual(store.connectionStatus, .connected("Tailscale"))
        XCTAssertEqual(store.connectionEndpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(
            probedEndpoints,
            ["http://127.0.0.1:8787", "http://100.64.0.1:8787"]
        )
    }

    func testMacCatalystPreflightAutomaticallyPairsDetectedLocalAgent() async throws {
        let suiteName = "PairingLinkTests.LocalAgentAutoPairing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = ConnectionRouteProbeRecorder()
        let keychain = TestKeychainOperations()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: true,
            localAgentProbe: { endpoint, _ in
                await recorder.record(endpoint)
            },
            localAgentPairingClaim: { endpoint, _ in
                XCTAssertEqual(endpoint, "http://127.0.0.1:8787")
                return "local-auto-token"
            },
            routeProbe: { endpoint, token, _ in
                XCTAssertEqual(token, "local-auto-token")
                await recorder.record(endpoint)
            }
        )
        store.token = ""

        let connected = await store.preflightConnection()
        let probedEndpoints = await recorder.endpoints()

        XCTAssertTrue(connected)
        XCTAssertTrue(store.localAgentDetected)
        XCTAssertTrue(store.isConfigured)
        XCTAssertTrue(store.isUsingLocalConnection)
        XCTAssertEqual(store.endpoint, "http://127.0.0.1:8787")
        XCTAssertEqual(store.token, "local-auto-token")
        XCTAssertEqual(store.connectionProfiles.first?.displayName, L10n.text("ui.this_mac"))
        XCTAssertEqual(store.connectionStatus, .connected(L10n.text("ui.direct_connection_to_this_machine")))
        XCTAssertEqual(
            probedEndpoints,
            ["http://127.0.0.1:8787", "http://127.0.0.1:8787"]
        )
    }

    func testMacCatalystPreflightKeepsManualPairingFallbackForOldLocalAgent() async throws {
        let suiteName = "PairingLinkTests.LocalAgentOldVersion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: true,
            localAgentProbe: { _, _ in },
            localAgentPairingClaim: { _, _ in
                throw AgentAPIError.server(status: 404, message: "not found")
            },
            routeProbe: { _, _, _ in
                XCTFail("旧助手无法领取 Token 时不应执行鉴权选路")
            }
        )

        let connected = await store.preflightConnection()

        XCTAssertFalse(connected)
        XCTAssertTrue(store.localAgentDetected)
        XCTAssertFalse(store.isConfigured)
        guard case .failed(let message) = store.connectionStatus else {
            return XCTFail("旧助手应保留可扫码修复的失败状态")
        }
        XCTAssertTrue(message.contains("升级并重启 agentd"))
    }

    func testMacCatalystPreflightRepairsInvalidSavedLoopbackTokenAutomatically() async throws {
        let suiteName = "PairingLinkTests.LocalAgentTokenRepair.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://127.0.0.1:8787", forKey: "agentd.endpoint")
        let recorder = ConnectionRouteCredentialRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: true,
            localAgentProbe: { _, _ in },
            localAgentPairingClaim: { _, _ in "fresh-local-token" },
            routeProbe: { endpoint, token, _ in
                await recorder.record(endpoint: endpoint, token: token)
                if token == "stale-local-token" {
                    throw AgentAPIError.credentialsInvalid(status: 401)
                }
            }
        )
        store.token = "stale-local-token"

        let connected = await store.preflightConnection()
        let calls = await recorder.calls()

        XCTAssertTrue(connected)
        XCTAssertEqual(store.token, "fresh-local-token")
        XCTAssertTrue(store.isUsingLocalConnection)
        XCTAssertFalse(store.requiresRePairing)
        XCTAssertEqual(store.connectionStatus, .connected(L10n.text("ui.direct_connection_to_this_machine")))
        XCTAssertEqual(calls.map(\.token), ["stale-local-token", "fresh-local-token"])
        XCTAssertEqual(Set(calls.map(\.endpoint)), ["http://127.0.0.1:8787"])
    }

    func testMacCatalystConcurrentLocalDetectionSharesSingleProbe() async throws {
        let suiteName = "PairingLinkTests.LocalAgentProbeCoalescing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = LocalAgentProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            routeProbeTimeout: 0.2,
            prefersLocalConnection: true,
            localAgentProbe: { _, _ in
                await recorder.record()
                try await Task.sleep(nanoseconds: 30_000_000)
            },
            localAgentPairingClaim: { _, _ in
                XCTFail("单独探测不应触发自动配对")
                return ""
            },
            routeProbe: { _, _, _ in }
        )

        async let first = store.detectLocalAgent()
        async let second = store.detectLocalAgent()
        let results = await [first, second]
        let probeCount = await recorder.count()

        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(probeCount, 1)
        XCTAssertTrue(store.localAgentDetected)
    }

    func testFormatsConnectionTestDuration() {
        XCTAssertEqual(AppStore.connectionTestDurationText(milliseconds: 98), "98 ms")
        XCTAssertEqual(AppStore.connectionTestDurationText(milliseconds: 1_250), "1.2 秒")
        XCTAssertEqual(AppStore.connectionTestDurationText(milliseconds: 12_400), "12 秒")
    }

    func testConnectionTestReportFindsSlowestAndFailedStage() {
        let report = ConnectionTestReport(
            startedAt: Date(timeIntervalSince1970: 0),
            totalMillis: 3_700,
            stages: [
                ConnectionTestStageTiming(kind: .health, durationMillis: 120, status: .succeeded),
                ConnectionTestStageTiming(kind: .version, durationMillis: 260, status: .failed("unauthorized")),
                ConnectionTestStageTiming(kind: .appServerConfig, durationMillis: 1_100, status: .succeeded),
                ConnectionTestStageTiming(kind: .appServerGateway, durationMillis: 2_200, status: .failed("timeout"))
            ]
        )

        XCTAssertEqual(report.slowestStage?.kind, .appServerGateway)
        XCTAssertEqual(report.failedStage?.kind, .version)
    }

    func testTailscaleNetworkPathDecodesKnownAndFutureKinds() throws {
        let derpJSON = """
        {
          "kind": "derp",
          "observed_at": "2026-07-22T12:00:00Z",
          "relay_region": "hkg"
        }
        """
        let derp = try AgentAPIClient.decoder.decode(
            TailscaleNetworkPathResponse.self,
            from: Data(derpJSON.utf8)
        )
        XCTAssertEqual(derp.kind, .derp)
        XCTAssertEqual(derp.relayRegion, "hkg")

        let futureJSON = """
        {
          "kind": "future_transport",
          "observed_at": "2026-07-22T12:00:00Z"
        }
        """
        let future = try AgentAPIClient.decoder.decode(
            TailscaleNetworkPathResponse.self,
            from: Data(futureJSON.utf8)
        )
        XCTAssertEqual(future.kind, .unknown)
        XCTAssertNil(future.relayRegion)
    }

    func testConnectionTestStabilitySummarizesRecentReports() throws {
        let reports = [
            ConnectionTestReport(
                startedAt: Date(timeIntervalSince1970: 0),
                totalMillis: 800,
                stages: [
                    ConnectionTestStageTiming(kind: .health, durationMillis: 80, status: .succeeded),
                    ConnectionTestStageTiming(kind: .appServerGateway, durationMillis: 200, status: .succeeded)
                ]
            ),
            ConnectionTestReport(
                startedAt: Date(timeIntervalSince1970: 1),
                totalMillis: 2_100,
                stages: [
                    ConnectionTestStageTiming(kind: .health, durationMillis: 120, status: .succeeded),
                    ConnectionTestStageTiming(kind: .appServerGateway, durationMillis: 1_700, status: .failed("timeout"))
                ]
            )
        ]

        let stabilities = AppStore.connectionTestStageStabilities(reports: reports)
        let gateway = try XCTUnwrap(stabilities.first { $0.kind == .appServerGateway })

        XCTAssertEqual(gateway.sampleCount, 2)
        XCTAssertEqual(gateway.failureCount, 1)
        XCTAssertEqual(gateway.spreadMillis, 1_500)
        XCTAssertEqual(gateway.maxMillis, 1_700)
    }

    func testRelayDiagnosticsSnapshotBuildsGatewayEvidence() throws {
        let baseline = try decodeRelayDiagnostics(totalConnections: 11, failedDials: 1)
        let snapshot = try decodeRelayDiagnostics(totalConnections: 12, failedDials: 2)
        let formatter = ISO8601DateFormatter()
        let gatewayStartedAt = try XCTUnwrap(formatter.date(from: "2026-07-03T02:24:58Z"))

        let diagnostics = ConnectionTestGatewayDiagnostics.make(
            baseline: baseline,
            snapshot: snapshot,
            gatewayStartedAt: gatewayStartedAt
        )

        XCTAssertEqual(diagnostics.totalConnectionsDelta, 1)
        XCTAssertEqual(diagnostics.failedUpstreamDialsDelta, 1)
        XCTAssertEqual(diagnostics.relatedConnection?.id, "gateway-12")
        XCTAssertEqual(diagnostics.relatedConnection?.recentRPC, [])
        XCTAssertEqual(diagnostics.latestRPC?.method, "initialize")
        XCTAssertEqual(diagnostics.latestRPC?.latencyMillis, 4_200)
        XCTAssertEqual(diagnostics.writeBackMillisMax, 480)
    }

    func testRelayDiagnosticsDecodesNullSlicesAsEmptyLists() throws {
        let json = """
        {
          "generated_at": "2026-07-03T02:25:00Z",
          "app_server_gateway": {
            "total_connections": 0,
            "active_connections": 0,
            "failed_upstream_dials": 1,
            "upstream_dial_ms_max": 6300,
            "client_to_upstream": {
              "frames": 0,
              "bytes": 0,
              "write_ms_max": 0,
              "last_write_ms": 0,
              "last_frame_bytes": 0
            },
            "upstream_to_client": {
              "frames": 0,
              "bytes": 0,
              "write_ms_max": 0,
              "last_write_ms": 0,
              "last_frame_bytes": 0
            },
            "rpc": {
              "responses": 0,
              "latency_ms_max": 0,
              "outstanding_requests": 0,
              "outstanding_ms_max": 0
            },
            "recent_connections": null,
            "active_connections_detail": null,
            "recent_rpc": null
          },
          "hints": null
        }
        """

        let diagnostics = try AgentAPIClient.decoder.decode(RelayDiagnosticsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(diagnostics.hints, [])
        XCTAssertEqual(diagnostics.appServerGateway.recentConnections, [])
        XCTAssertEqual(diagnostics.appServerGateway.activeConnectionDetail, [])
        XCTAssertEqual(diagnostics.appServerGateway.recentRPC, [])
        XCTAssertEqual(diagnostics.appServerGateway.failedUpstreamDials, 1)
    }

    private func decodeRelayDiagnostics(totalConnections: Int, failedDials: Int) throws -> RelayDiagnosticsResponse {
        let json = """
        {
          "generated_at": "2026-07-03T02:25:00Z",
          "app_server_gateway": {
            "total_connections": \(totalConnections),
            "active_connections": 1,
            "failed_upstream_dials": \(failedDials),
            "upstream_dial_ms_max": 6300,
            "client_to_upstream": {
              "frames": 1,
              "bytes": 120,
              "write_ms_max": 12,
              "last_write_ms": 12,
              "last_frame_bytes": 120
            },
            "upstream_to_client": {
              "frames": 1,
              "bytes": 240,
              "write_ms_max": 480,
              "last_write_ms": 480,
              "last_frame_bytes": 240
            },
            "rpc": {
              "responses": 1,
              "latency_ms_max": 4200,
              "outstanding_requests": 0,
              "outstanding_ms_max": 0
            },
            "recent_connections": [],
            "active_connections_detail": [
              {
                "id": "gateway-12",
                "started_at": "2026-07-03T02:24:59Z",
                "duration_ms": 900,
                "upstream_dial_ms": 951,
                "client_to_upstream": {
                  "frames": 1,
                  "bytes": 120,
                  "write_ms_max": 12,
                  "last_write_ms": 12,
                  "last_frame_bytes": 120
                },
                "upstream_to_client": {
                  "frames": 1,
                  "bytes": 240,
                  "write_ms_max": 480,
                  "last_write_ms": 480,
                  "last_frame_bytes": 240
                },
                "rpc": {
                  "responses": 1,
                  "latency_ms_max": 4200,
                  "outstanding_requests": 0,
                  "outstanding_ms_max": 0
                },
                "last_client_method": "initialize"
              }
            ],
            "recent_rpc": [
              {
                "completed_at": "2026-07-03T02:25:00Z",
                "method": "initialize",
                "latency_ms": 4200,
                "request_bytes": 120,
                "response_bytes": 240
              }
            ]
          },
          "hints": ["app-server JSON-RPC 最大响应耗时 4200ms。"]
        }
        """
        return try AgentAPIClient.decoder.decode(RelayDiagnosticsResponse.self, from: Data(json.utf8))
    }
}

actor ConnectionRouteProbeRecorder {
    private var recordedEndpoints: [String] = []

    func record(_ endpoint: String) {
        recordedEndpoints.append(endpoint)
    }

    func endpoints() -> [String] {
        recordedEndpoints
    }
}

private struct ConnectionRouteCredentialCall: Equatable {
    let endpoint: String
    let token: String
}

private actor ConnectionRouteCredentialRecorder {
    private var recordedCalls: [ConnectionRouteCredentialCall] = []

    func record(endpoint: String, token: String) {
        recordedCalls.append(ConnectionRouteCredentialCall(endpoint: endpoint, token: token))
    }

    func calls() -> [ConnectionRouteCredentialCall] {
        recordedCalls
    }
}

private actor LocalAgentProbeRecorder {
    private var probeCount = 0

    func record() {
        probeCount += 1
    }

    func count() -> Int {
        probeCount
    }
}

private final class AuthenticationStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let status: Int
        let body: String
        let headers: [String: String]
        if authorization.contains("expired-401") {
            status = 401
            body = #"{"error":"unauthorized"}"#
            headers = ["Content-Type": "application/json", "WWW-Authenticate": "Bearer"]
        } else if authorization.contains("expired-403") {
            status = 403
            body = #"{"error":"forbidden"}"#
            headers = ["Content-Type": "application/json"]
        } else {
            // 真实 agentd 的路径 allowlist 也会返回 403；该分支用于防止客户端误清有效访问码。
            status = 403
            body = #"{"error":"路径不在允许范围内或不可访问"}"#
            headers = ["Content-Type": "application/json"]
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TestKeychainOperations: KeychainOperating {
    private var itemsByAccount: [String: Data]
    var itemData: Data? {
        get { itemsByAccount["agentd-token"] ?? itemsByAccount.values.first }
        set {
            if let newValue {
                itemsByAccount["agentd-token"] = newValue
            } else {
                itemsByAccount.removeAll()
            }
        }
    }
    var forcedCopyStatus: OSStatus?
    var forcedUpdateStatus: OSStatus?
    var forcedAddStatus: OSStatus?
    var forcedDeleteStatus: OSStatus?

    private(set) var updateCallCount = 0
    private(set) var addCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var copyCallCount = 0

    init(
        itemData: Data? = nil,
        forcedCopyStatus: OSStatus? = nil,
        forcedUpdateStatus: OSStatus? = nil,
        forcedAddStatus: OSStatus? = nil,
        forcedDeleteStatus: OSStatus? = nil
    ) {
        if let itemData {
            itemsByAccount = ["agentd-token": itemData]
        } else {
            itemsByAccount = [:]
        }
        self.forcedCopyStatus = forcedCopyStatus
        self.forcedUpdateStatus = forcedUpdateStatus
        self.forcedAddStatus = forcedAddStatus
        self.forcedDeleteStatus = forcedDeleteStatus
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        copyCallCount += 1
        if let forcedCopyStatus {
            return forcedCopyStatus
        }
        guard let itemData = itemsByAccount[account(from: query)] else {
            return errSecItemNotFound
        }
        result?.pointee = itemData as CFData
        return errSecSuccess
    }

    func update(
        _ query: CFDictionary,
        attributesToUpdate: CFDictionary
    ) -> OSStatus {
        updateCallCount += 1
        if let forcedUpdateStatus {
            return forcedUpdateStatus
        }
        let account = account(from: query)
        guard itemsByAccount[account] != nil else {
            return errSecItemNotFound
        }
        let attributes = attributesToUpdate as NSDictionary
        guard let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        itemsByAccount[account] = data
        return errSecSuccess
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        addCallCount += 1
        if let forcedAddStatus {
            return forcedAddStatus
        }
        let attributes = attributes as NSDictionary
        guard let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        itemsByAccount[account(from: attributes)] = data
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        deleteCallCount += 1
        if let forcedDeleteStatus {
            return forcedDeleteStatus
        }
        let account = account(from: query)
        guard itemsByAccount[account] != nil else {
            return errSecItemNotFound
        }
        itemsByAccount.removeValue(forKey: account)
        return errSecSuccess
    }

    func data(account: String) -> Data? {
        itemsByAccount[account]
    }

    func setData(_ data: Data, account: String) {
        itemsByAccount[account] = data
    }

    var accounts: Set<String> {
        Set(itemsByAccount.keys)
    }

    private func account(from dictionary: CFDictionary) -> String {
        let values = dictionary as NSDictionary
        return values[kSecAttrAccount as String] as? String ?? ""
    }
}

final class DoctorDiagnosticsTests: XCTestCase {
    func testParsesStructuredDoctorResponseAndKeepsPrettyRawJSON() throws {
        let url = try XCTUnwrap(URL(string: "https://mac.example/api/doctor"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        let data = Data(#"{"ok":false,"version":"1.4.0","listen":"127.0.0.1:8787","checks":[{"name":"token","ok":true,"level":"ok","message":"Token 已配置"},{"name":"tailscale","ok":false,"level":"warning","message":"未检测到 Tailscale"},{"name":"codex","ok":false,"level":"error","message":"未找到 Codex CLI","fix":"安装 Codex CLI"}],"future":{"ignored":true}}"#.utf8)

        let document = try DoctorDiagnosticsParser.parseDoctorResponse(data: data, response: response)

        XCTAssertFalse(document.report.ok)
        XCTAssertEqual(document.report.version, "1.4.0")
        XCTAssertEqual(document.report.listen, "127.0.0.1:8787")
        XCTAssertEqual(document.report.checks.count, 3)
        XCTAssertEqual(document.report.checks[0].displayName, L10n.text("ui.access_token"))
        XCTAssertEqual(document.report.checks[0].displayMessage, L10n.text("ui.doctor_access_token_ready"))
        XCTAssertNil(document.report.checks[0].displayFix)
        XCTAssertTrue(document.report.checks[1].isWarning)
        XCTAssertEqual(document.report.checks[2].displayMessage, L10n.text("ui.doctor_codex_cli_needs_attention"))
        XCTAssertEqual(document.report.checks[2].displayFix, L10n.text("ui.doctor_fix_codex"))
        XCTAssertTrue(document.rawJSON.contains("\n"))
        XCTAssertTrue(document.rawJSON.contains(#""version" : "1.4.0""#))
    }

    func testUnknownDoctorCheckUsesLocalizedSummaryAndKeepsRawDetails() {
        let check = DoctorDiagnosticCheck(
            name: "future-check",
            ok: false,
            level: "warning",
            message: "服务端新增的诊断详情：/private/path",
            fix: "运行 future-fix --repair"
        )

        XCTAssertEqual(check.displayMessage, L10n.text("ui.doctor_check_warning"))
        XCTAssertEqual(check.displayFix, L10n.text("ui.doctor_fix_generic"))
        XCTAssertTrue(check.hasRawDiagnosticDetails)
        XCTAssertEqual(check.message, "服务端新增的诊断详情：/private/path")
        XCTAssertEqual(check.fix, "运行 future-fix --repair")
    }

    func testRejectsNonSuccessHTTPResponseWithServerMessage() throws {
        let url = try XCTUnwrap(URL(string: "https://mac.example/api/doctor"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        ))
        let data = Data(#"{"error":{"message":"token 无效"}}"#.utf8)

        XCTAssertThrowsError(try DoctorDiagnosticsParser.parseDoctorResponse(data: data, response: response)) { error in
            XCTAssertEqual(
                error as? DoctorDiagnosticError,
                .httpStatus(code: 401, message: "token 无效")
            )
            XCTAssertEqual(error.localizedDescription, "诊断请求失败（HTTP 401）：token 无效")
        }
    }

    func testRejectsNonHTTPResponseAndMalformedPayload() throws {
        let url = try XCTUnwrap(URL(string: "https://mac.example/api/doctor"))
        let nonHTTP = URLResponse(
            url: url,
            mimeType: "application/json",
            expectedContentLength: 2,
            textEncodingName: "utf-8"
        )
        XCTAssertThrowsError(
            try DoctorDiagnosticsParser.parseDoctorResponse(data: Data("{}".utf8), response: nonHTTP)
        ) { error in
            XCTAssertEqual(error as? DoctorDiagnosticError, .invalidHTTPResponse)
        }

        let okResponse = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        XCTAssertThrowsError(
            try DoctorDiagnosticsParser.parseDoctorResponse(data: Data(#"{"ok":true}"#.utf8), response: okResponse)
        ) { error in
            guard case .invalidPayload = error as? DoctorDiagnosticError else {
                return XCTFail("expected invalidPayload, got \(error)")
            }
        }
    }

    func testBuildsDoctorURLAndFormatsFallbackPayload() throws {
        let url = try DoctorDiagnosticsParser.doctorURL(endpoint: " https://mac.example:8787/old/path?token=ignored ")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "mac.example")
        XCTAssertEqual(url.port, 8787)
        XCTAssertEqual(url.path, "/api/doctor")
        XCTAssertNil(url.query)

        XCTAssertThrowsError(try DoctorDiagnosticsParser.doctorURL(endpoint: "not a URL")) { error in
            XCTAssertEqual(error as? DoctorDiagnosticError, .invalidEndpoint)
        }
        XCTAssertEqual(
            DoctorDiagnosticsParser.formatDiagnosticPayload(Data([0xFF]), fallback: "无法解码"),
            "无法解码"
        )
    }
}
