import Foundation
import XCTest
@testable import MimiRemoteMac

@MainActor
final class HostStoreTests: XCTestCase {
    func testBootstrapRegistersBundledAgentWhenServiceRecordIsNotFound() async {
        let events = EventRecorder()
        var registrationState = ServiceRegistrationState.notFound
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["register-mac"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.lastError)
    }

    func testBootstrapReportsMissingBundledConfigurationWithoutRegistering() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            agentStatus: { .notFound },
            agentConfigurationError: { "App 包内缺少 LaunchAgent 配置，请重新安装正式版本。" },
            registerAgent: { events.append("register-mac") }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [])
        XCTAssertEqual(store.owner, .none)
        XCTAssertEqual(
            store.lifecycle,
            .failed("App 包内缺少 LaunchAgent 配置，请重新安装正式版本。")
        )
    }

    func testBootstrapRejectsAdHocSnapshotBeforeTouchingRegisteredAgent() async {
        let events = EventRecorder()
        let message = "当前 App 是未签名或 ad-hoc 结构快照，不能启动 macOS 后台服务。"
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            agentConfigurationError: { message },
            status: {
                events.append("status")
                return Self.stoppedStatus
            },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [])
        XCTAssertEqual(store.owner, .none)
        XCTAssertEqual(store.lifecycle, .failed(message))
        XCTAssertEqual(store.lastError, message)
    }

    func testPartialRegistrationFailureTriggersOneBoundedReregistration() async {
        let events = EventRecorder()
        var registrationState = ServiceRegistrationState.notRegistered
        var registrationAttempts = 0
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            registerAgent: {
                registrationAttempts += 1
                events.append("register-\(registrationAttempts)")
                registrationState = .enabled
                if registrationAttempts == 1 {
                    throw TestError.expected
                }
            },
            unregisterAgent: {
                events.append("unregister-mac")
                registrationState = .notRegistered
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["register-1", "unregister-mac", "register-2"])
        XCTAssertEqual(registrationAttempts, 2)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testUnregisterTimeoutRetriesOnceThenRegistersAfterStateConverges() async {
        let events = EventRecorder()
        let unregisterCalls = CallCounter()
        let statusCalls = CallCounter()
        var registrationState = ServiceRegistrationState.enabled
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                statusCalls.increment() == 1 ? Self.stoppedStatus : Self.readyStatus
            },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            },
            unregisterAgent: {
                let call = unregisterCalls.increment()
                events.append("unregister-\(call)")
                if call == 2 {
                    registrationState = .notRegistered
                }
            },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "unregister-1", "unregister-2", "register-mac",
        ])
        XCTAssertEqual(unregisterCalls.current, 2)
        XCTAssertEqual(statusCalls.current, 2)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.lastError)
    }

    func testSecondUnregisterTimeoutFailsWithoutThirdUnregisterOrRegister() async {
        let events = EventRecorder()
        let unregisterCalls = CallCounter()
        let registrationState = ServiceRegistrationState.enabled
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: { Self.stoppedStatus },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: {
                let call = unregisterCalls.increment()
                events.append("unregister-\(call)")
            },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["unregister-1", "unregister-2"])
        XCTAssertEqual(unregisterCalls.current, 2)
        XCTAssertEqual(registrationState, .enabled)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .failed(store.lastError ?? ""))
        XCTAssertTrue(store.lastError?.contains("服务停止超时") == true)
    }

    func testUnregisterRequiresApprovalDoesNotRetry() async {
        let events = EventRecorder()
        let unregisterCalls = CallCounter()
        var registrationState = ServiceRegistrationState.enabled
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: { Self.stoppedStatus },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: {
                unregisterCalls.increment()
                events.append("unregister-1")
                registrationState = .requiresApproval
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["unregister-1"])
        XCTAssertEqual(unregisterCalls.current, 1)
        XCTAssertFalse(events.values.contains("register-mac"))
        XCTAssertTrue(store.lastError?.contains("登录项") == true)
    }

    func testUnregisterCancellationDoesNotRetry() async {
        let events = EventRecorder()
        let unregisterCalls = CallCounter()
        let firstUnregister = expectation(description: "first unregister called")
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: { Self.stoppedStatus },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: {
                unregisterCalls.increment()
                events.append("unregister-1")
                firstUnregister.fulfill()
            }
        )

        let bootstrapTask = Task { await store.bootstrap() }
        await fulfillment(of: [firstUnregister], timeout: 1)
        bootstrapTask.cancel()
        await bootstrapTask.value

        XCTAssertEqual(events.values, ["unregister-1"])
        XCTAssertEqual(unregisterCalls.current, 1)
        XCTAssertFalse(events.values.contains("register-mac"))
    }

    func testEnabledAgentStatusFailureTriggersOneBoundedReregistration() async {
        let events = EventRecorder()
        let statusEvents = EventRecorder()
        var registrationState = ServiceRegistrationState.enabled
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                statusEvents.append("status")
                if statusEvents.values.count == 1 {
                    throw TestError.expected
                }
                return Self.readyStatus
            },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            },
            unregisterAgent: {
                events.append("unregister-mac")
                registrationState = .notRegistered
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["unregister-mac", "register-mac"])
        XCTAssertEqual(statusEvents.values, ["status", "status"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testEnabledRegistrationWithStoppedProcessRepairsWithoutUserAction() async {
        let events = EventRecorder()
        let statusCalls = CallCounter()
        var registrationState = ServiceRegistrationState.enabled
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                statusCalls.increment() == 1 ? Self.stoppedStatus : Self.readyStatus
            },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            },
            unregisterAgent: {
                events.append("unregister-mac")
                registrationState = .notRegistered
            },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["unregister-mac", "register-mac"])
        XCTAssertEqual(statusCalls.current, 2)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.lastError)
    }

    func testAgentConfigurationValidatorChecksPlistAndExecutable() throws {
        let fileManager = FileManager.default
        let bundleURL = fileManager.temporaryDirectory
            .appending(path: "mimi-agent-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: bundleURL) }

        XCTAssertTrue(
            ServiceManagementClient.validateAgentConfiguration(bundleURL: bundleURL)?
                .contains("缺少 LaunchAgent 配置") == true
        )

        let launchAgentsURL = bundleURL.appending(
            path: "Contents/Library/LaunchAgents",
            directoryHint: .isDirectory
        )
        let resourcesURL = bundleURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let propertyList: [String: Any] = [
            "Label": "com.gaixianggeng.mimi.mac.agentd",
            "BundleProgram": "Contents/Resources/agentd",
        ]
        let propertyListData = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try propertyListData.write(
            to: launchAgentsURL.appending(path: "com.gaixianggeng.mimi.mac.agentd.plist")
        )

        let executableURL = resourcesURL.appending(path: "agentd")
        try Data().write(to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let signingIdentity: (URL) -> CodeSigningIdentity? = { url in
            if url == bundleURL {
                return CodeSigningIdentity(
                    identifier: "com.gaixianggeng.mimi.mac",
                    teamIdentifier: "9HZ89R58PZ"
                )
            }
            if url == executableURL {
                return CodeSigningIdentity(
                    identifier: "com.gaixianggeng.mimi.mac.agentd",
                    teamIdentifier: "9HZ89R58PZ"
                )
            }
            return nil
        }
        XCTAssertNil(
            ServiceManagementClient.validateAgentConfiguration(
                bundleURL: bundleURL,
                signingIdentityProvider: signingIdentity
            )
        )
        XCTAssertTrue(
            ServiceManagementClient.validateAgentConfiguration(
                bundleURL: bundleURL,
                signingIdentityProvider: { url in
                    if url == bundleURL {
                        return CodeSigningIdentity(
                            identifier: "com.gaixianggeng.mimi.mac",
                            teamIdentifier: nil
                        )
                    }
                    return signingIdentity(url)
                }
            )?.contains("ad-hoc") == true
        )
        XCTAssertTrue(
            ServiceManagementClient.validateAgentConfiguration(
                bundleURL: bundleURL,
                signingIdentityProvider: { url in
                    if url == executableURL {
                        return CodeSigningIdentity(
                            identifier: "com.gaixianggeng.mimi.mac.agentd",
                            teamIdentifier: "OTHERTEAM"
                        )
                    }
                    return signingIdentity(url)
                }
            )?.contains("签名团队不一致") == true
        )
    }

    func testBootstrapRequiresSetupWhenConfigIsMissing() async {
        let store = makeStore(configExists: false)

        await store.bootstrap()

        XCTAssertEqual(store.lifecycle, .notConfigured)
        XCTAssertEqual(store.owner, .none)
    }

    func testBootstrapAutoEnablesClaudeAndReloadsRunningMacAgent() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            configureClaude: { preference, _ in
                events.append("configure-\(preference.rawValue)")
                return Self.claudeConfiguration(
                    enabled: true,
                    preference: .automatic,
                    previousEnabled: false,
                    previousPreference: .automatic,
                    changed: true,
                    restartRequired: true
                )
            },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "configure-auto", "unregister-mac", "register-mac",
        ])
        XCTAssertTrue(store.claudeEnabled)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testFirstLaunchConfiguresClaudeBeforeSingleAgentRegistration() async {
        let events = EventRecorder()
        var registrationState = ServiceRegistrationState.notRegistered
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: { Self.statusWithClaude(enabled: true, state: .connected) },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            },
            configureClaude: { preference, _ in
                events.append("configure-\(preference.rawValue)")
                return Self.claudeConfiguration(
                    enabled: true,
                    preference: .automatic,
                    previousEnabled: false,
                    previousPreference: .automatic,
                    changed: true,
                    restartRequired: true
                )
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["configure-auto", "register-mac"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertTrue(store.claudeEnabled)
        XCTAssertEqual(store.status?.runtimeStatus?.runtimes.first?.state, .connected)
    }

    func testDisablingClaudeReloadsServiceAndWaitsForDisabledRuntime() async {
        let events = EventRecorder()
        let disabledStatus = Self.statusWithClaude(enabled: false, state: .disabled)
        let store = makeStore(
            configExists: true,
            status: { disabledStatus },
            registerAgent: { events.append("register-mac") },
            configureClaude: { preference, restoreEnabled in
                events.append("configure-\(preference.rawValue)")
                if preference == .automatic {
                    return Self.claudeConfiguration(enabled: true, preference: .enabled)
                }
                return Self.claudeConfiguration(
                    enabled: restoreEnabled ?? false,
                    preference: preference,
                    previousEnabled: true,
                    previousPreference: .enabled,
                    changed: true,
                    restartRequired: true
                )
            }
        )
        await store.bootstrap()

        await store.setClaudeEnabled(false)

        XCTAssertEqual(events.values, [
            "configure-auto", "register-mac", "configure-disabled", "register-mac",
        ])
        XCTAssertFalse(store.claudeEnabled)
        XCTAssertNil(store.claudeError)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testClaudeServiceReloadFailureRestoresPreviousConfiguration() async {
        let events = EventRecorder()
        let registrations = CallCounter()
        let enabledStatus = Self.statusWithClaude(enabled: true, state: .connected)
        let store = makeStore(
            configExists: true,
            status: { enabledStatus },
            registerAgent: {
                let call = registrations.increment()
                events.append("register-\(call)")
                if call == 2 {
                    throw TestError.expected
                }
            },
            configureClaude: { preference, restoreEnabled in
                events.append("configure-\(preference.rawValue)-\(restoreEnabled.map(String.init) ?? "normal")")
                if preference == .automatic {
                    return Self.claudeConfiguration(enabled: true, preference: .enabled)
                }
                if let restoreEnabled {
                    return Self.claudeConfiguration(
                        enabled: restoreEnabled,
                        preference: preference,
                        previousEnabled: false,
                        previousPreference: .disabled,
                        changed: true,
                        restartRequired: true,
                        reason: "restored"
                    )
                }
                return Self.claudeConfiguration(
                    enabled: false,
                    preference: .disabled,
                    previousEnabled: true,
                    previousPreference: .enabled,
                    changed: true,
                    restartRequired: true
                )
            }
        )
        await store.bootstrap()

        await store.setClaudeEnabled(false)

        XCTAssertEqual(events.values, [
            "configure-auto-normal",
            "register-1",
            "configure-disabled-normal",
            "register-2",
            "configure-enabled-true",
            "register-3",
        ])
        XCTAssertTrue(store.claudeEnabled)
        XCTAssertTrue(store.claudeError?.contains("已恢复修改前") == true)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testBootstrapDetectsRunningHomebrewServiceWithoutChangingIt() async {
        let store = makeStore(configExists: true, homebrewLoaded: true)

        await store.bootstrap()

        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertTrue(store.homebrewLoaded)
    }

    func testTakeoverRejectsInvalidAppBeforeStoppingHomebrew() async {
        let events = EventRecorder()
        let message = "当前 App 是未签名或 ad-hoc 结构快照，不能启动 macOS 后台服务。"
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            agentConfigurationError: { message },
            registerAgent: { events.append("register-mac") },
            homebrewStop: { events.append("stop-homebrew") }
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, [])
        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertEqual(store.lastError, message)
    }

    func testFailedTakeoverRestoresHomebrewAutomatically() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: {
                events.append("register-mac")
                throw TestError.expected
            },
            unregisterAgent: { events.append("unregister-mac") },
            homebrewStart: { events.append("start-homebrew") },
            homebrewStop: { events.append("stop-homebrew") }
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, [
            "stop-homebrew", "register-mac", "unregister-mac", "start-homebrew",
        ])
        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertTrue(store.lastError?.contains("已恢复 Homebrew 服务") == true)
    }

    func testPairingFailureDoesNotRollBackSuccessfulTakeover() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            homebrewStart: { events.append("start-homebrew") },
            homebrewStop: { events.append("stop-homebrew") },
            pair: { _ in throw TestError.expected }
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, ["stop-homebrew", "register-mac"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertTrue(store.lastError?.contains("服务接管成功") == true)
    }

    func testSelectingLANEnablesAccessRestartsOnceAndReturnsLANPairing() async {
        let events = EventRecorder()
        let lanPairing = PairingInfo(
            endpoint: "http://192.168.31.20:8787",
            pairURL: "mimiremote://pair?pair_sig=lan",
            expiresAt: "2026-07-22T12:00:00Z",
            warnings: ["仅限同一局域网"]
        )
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            setLANAccess: { enabled in
                events.append("lan-\(enabled)")
                return NetworkConfigurationResult(
                    lanEnabled: enabled,
                    changed: true,
                    restartRequired: true
                )
            },
            pair: { network in
                events.append("pair-\(network.rawValue)")
                return network == .localNetwork ? lanPairing : Self.pairing
            },
            healthCheck: { _ in false }
        )
        await store.bootstrap()

        await store.refreshPairing(network: .localNetwork)

        XCTAssertEqual(events.values, [
            "pair-auto",
            "register-mac",
            "lan-true",
            "unregister-mac",
            "register-mac",
            "pair-lan",
        ])
        XCTAssertEqual(store.pairingNetwork, .localNetwork)
        XCTAssertEqual(store.pairing, lanPairing)
    }

    func testAutomaticPairingFallsBackToLANWhenTailscaleIsUnavailable() async {
        let events = EventRecorder()
        let lanPairing = PairingInfo(
            endpoint: "http://192.168.31.20:8787",
            network: .localNetwork,
            pairURL: "mimiremote://pair?pair_sig=automatic-lan",
            expiresAt: "2026-07-22T12:00:00Z",
            warnings: ["仅限同一局域网"]
        )
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register-mac") },
            setLANAccess: { enabled in
                events.append("lan-\(enabled)")
                return NetworkConfigurationResult(
                    lanEnabled: enabled,
                    changed: false,
                    restartRequired: false
                )
            },
            pair: { network in
                events.append("pair-\(network.rawValue)")
                if network == .automatic {
                    throw TestError.expected
                }
                return lanPairing
            }
        )
        await store.bootstrap()

        await store.refreshPairing()

        XCTAssertEqual(store.pairingNetwork, .localNetwork)
        XCTAssertEqual(store.pairing, lanPairing)
        XCTAssertEqual(events.values, [
            "pair-auto", "lan-true", "register-mac",
            "pair-auto", "lan-true", "pair-lan",
        ])
    }

    func testDoctorKeepsHomebrewMigrationState() async {
        let store = makeStore(configExists: true, homebrewLoaded: true)
        await store.bootstrap()

        await store.runDoctor(fix: false)

        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
    }

    func testDoctorRestartsMacAgentAfterConfigurationRepair() async {
        let events = EventRecorder()
        var registrationState = ServiceRegistrationState.notRegistered
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                events.append("status")
                return Self.readyStatus
            },
            doctor: { fix in
                events.append("doctor-\(fix)")
                return DoctorFixResults(
                    fixes: ["已恢复 Codex CLI 路径"],
                    results: Self.readyStatus.doctor,
                    restartRequired: true
                )
            },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            },
            unregisterAgent: {
                events.append("unregister-mac")
                registrationState = .notRegistered
            },
            healthCheck: { _ in false }
        )
        await store.bootstrap()

        await store.runDoctor(fix: true)

        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(events.values, [
            "register-mac", "status",
            "doctor-true", "unregister-mac", "register-mac", "status",
        ])
    }

    func testDoctorRestartsHomebrewAfterConfigurationRepair() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            doctor: { fix in
                events.append("doctor-\(fix)")
                return DoctorFixResults(
                    fixes: ["已恢复 Codex CLI 路径"],
                    results: Self.readyStatus.doctor,
                    restartRequired: true
                )
            },
            homebrewStart: { events.append("start-homebrew") },
            homebrewStop: { events.append("stop-homebrew") }
        )
        await store.bootstrap()

        await store.runDoctor(fix: true)

        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(events.values, [
            "doctor-true", "stop-homebrew", "start-homebrew",
        ])
    }

    func testFailedHomebrewRestoreReturnsToMacAgent() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            homebrewStart: {
                events.append("start-homebrew")
                throw TestError.expected
            },
            homebrewStop: { events.append("stop-homebrew") },
            healthCheck: { _ in false }
        )
        await store.bootstrap()
        await store.takeOverHomebrew()

        await store.restoreHomebrew()

        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertTrue(store.lastError?.contains("已继续使用 App 服务") == true)
        XCTAssertEqual(events.values, [
            "stop-homebrew", "register-mac", "unregister-mac", "start-homebrew",
            "stop-homebrew", "register-mac",
        ])
    }

    func testRestartWaitsForAgentToFinishUnregisteringBeforeRegisteringAgain() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            registerAgent: {
                // 模拟真实 SMAppService：状态仍为 enabled 时，registerAgent 会直接跳过。
                guard registration.nextStatus() != .enabled else { return }
                events.append("register-mac")
            },
            unregisterAgent: { events.append("unregister-mac") },
            healthCheck: { _ in
                events.append("health-stopped")
                return false
            }
        )
        await store.bootstrap()

        await store.restartService()

        XCTAssertEqual(events.values, [
            "unregister-mac", "health-stopped", "register-mac",
        ])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    func testStopAndQuitRequestSurvivesMenuDismissalAndWaitsForAgentShutdown() async {
        let events = EventRecorder()
        let terminated = expectation(description: "App terminates after agent shutdown")
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            healthCheck: { _ in
                events.append("health-stopped")
                return false
            },
            terminateApplication: {
                events.append("terminate-app")
                terminated.fulfill()
            }
        )
        await store.bootstrap()

        store.requestStopServiceAndQuit()

        XCTAssertTrue(store.isBusy)
        XCTAssertTrue(store.isStoppingForQuit)
        await fulfillment(of: [terminated], timeout: 1)
        XCTAssertEqual(events.values, [
            "register-mac", "unregister-mac", "health-stopped", "terminate-app",
        ])
        XCTAssertEqual(store.lifecycle, .stopped)
        XCTAssertEqual(store.owner, .none)
    }

    func testBootstrapReplacesOutdatedBundledAgentBeforeReportingReady() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let outdated = AgentStatus(
            processOK: true,
            serviceOK: false,
            processError: nil,
            serviceError: "运行中的 agentd 仍是旧构建",
            version: "0.1.5+mac.240",
            serverVersion: "0.1.5+mac.239",
            endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath,
            projects: Self.readyStatus.projects,
            doctorOK: false,
            doctor: Self.readyStatus.doctor,
            pairExpires: nil
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            status: {
                events.values.contains("register-mac") ? Self.readyStatus : outdated
            },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            healthCheck: { _ in
                events.append("health-stopped")
                return false
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "unregister-mac", "health-stopped", "register-mac",
        ])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    func testBootstrapReregistersEnabledAgentWhenRegistrationRevisionIsStale() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            isAgentRegistrationCurrent: { false },
            markAgentRegistrationCurrent: { events.append("mark-registration") },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "unregister-mac", "register-mac", "mark-registration",
        ])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    func testBootstrapReusesEnabledAgentWhenRegistrationRevisionIsCurrent() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            isAgentRegistrationCurrent: { true },
            markAgentRegistrationCurrent: { events.append("mark-registration") },
            status: {
                events.append("status")
                return Self.readyStatus
            },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["status"])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    func testMenuAppearanceReusesRecentBootstrapStatus() async {
        let events = EventRecorder()
        let current = AgentStatus(
            processOK: Self.readyStatus.processOK,
            serviceOK: Self.readyStatus.serviceOK,
            processError: Self.readyStatus.processError,
            serviceError: Self.readyStatus.serviceError,
            version: Self.readyStatus.version,
            serverVersion: Self.readyStatus.serverVersion,
            endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath,
            projects: Self.readyStatus.projects,
            doctorOK: Self.readyStatus.doctorOK,
            doctor: Self.readyStatus.doctor,
            pairExpires: Self.readyStatus.pairExpires,
            runtimeStatus: AgentRuntimeStatusSnapshot(
                checkedAt: "2026-07-28T02:00:00Z",
                runtimes: [],
                refreshing: false,
                stale: false
            )
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: {
                events.append("status")
                return current
            }
        )

        await store.bootstrap()
        await store.refreshIfNeeded()

        XCTAssertEqual(events.values, ["status"])
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testTransientMissingRuntimeStatusPreservesPreviousSnapshotAsStale() async {
        let events = EventRecorder()
        let snapshot = AgentRuntimeStatusSnapshot(
            checkedAt: "2026-07-28T02:00:00Z",
            runtimes: [
                AgentRuntimeStatus(
                    id: "codex",
                    title: "Codex",
                    enabled: true,
                    state: .connected,
                    authMode: "chatgpt",
                    planType: "pro",
                    reason: nil,
                    rateLimits: nil
                ),
            ],
            refreshing: false,
            stale: false
        )
        let statusWithRuntime = AgentStatus(
            processOK: Self.readyStatus.processOK,
            serviceOK: Self.readyStatus.serviceOK,
            processError: Self.readyStatus.processError,
            serviceError: Self.readyStatus.serviceError,
            version: Self.readyStatus.version,
            serverVersion: Self.readyStatus.serverVersion,
            endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath,
            projects: Self.readyStatus.projects,
            doctorOK: Self.readyStatus.doctorOK,
            doctor: Self.readyStatus.doctor,
            pairExpires: Self.readyStatus.pairExpires,
            runtimeStatus: snapshot
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: {
                events.append("status")
                return events.values.count == 1 ? statusWithRuntime : Self.readyStatus
            }
        )

        await store.bootstrap()
        await store.refresh()

        XCTAssertEqual(events.values, ["status", "status"])
        XCTAssertEqual(store.status?.runtimeStatus?.runtimes.map(\.id), ["codex"])
        XCTAssertEqual(store.status?.runtimeStatus?.stale, true)
    }


    func makeStore(
        configExists: Bool,
        homebrewLoaded: Bool = false,
        agentStatus: @escaping @MainActor () -> ServiceRegistrationState = { .notRegistered },
        agentConfigurationError: @escaping @MainActor () -> String? = { nil },
        isAgentRegistrationCurrent: @escaping @MainActor () -> Bool = { true },
        markAgentRegistrationCurrent: @escaping @MainActor () -> Void = {},
        status: @escaping @Sendable () async throws -> AgentStatus = {
            HostStoreTests.readyStatus
        },
        doctor: @escaping @Sendable (Bool) async throws -> DoctorFixResults = { _ in
            DoctorFixResults(fixes: [], results: HostStoreTests.readyStatus.doctor)
        },
        registerAgent: @escaping @MainActor () throws -> Void = {},
        unregisterAgent: @escaping @MainActor () async throws -> Void = {},
        homebrewStart: @escaping @Sendable () async throws -> Void = {},
        homebrewStop: @escaping @Sendable () async throws -> Void = {},
        configureClaude: @escaping @Sendable (
            ClaudeActivationPreference,
            Bool?
        ) async throws -> ClaudeConfigurationResult = { preference, restoreEnabled in
            HostStoreTests.claudeConfiguration(
                enabled: restoreEnabled ?? false,
                preference: preference,
                previousEnabled: false,
                previousPreference: .automatic
            )
        },
        setLANAccess: @escaping @Sendable (Bool) async throws -> NetworkConfigurationResult = {
            NetworkConfigurationResult(lanEnabled: $0, changed: false, restartRequired: false)
        },
        pair: (@Sendable (PairingNetwork) async throws -> PairingInfo)? = nil,
        healthCheck: @escaping @Sendable (String) async -> Bool = { _ in true },
        terminateApplication: @escaping @MainActor () -> Void = {}
    ) -> HostStore {
        let readyStatus = Self.readyStatus
        let agent = AgentCommandClient(
            configExists: { configExists },
            setup: { _ in Self.pairing },
            status: status,
            statusAt: { _ in readyStatus },
            doctor: doctor,
            configureClaude: configureClaude,
            setLANAccess: setLANAccess,
            pair: pair ?? { _ in Self.pairing },
            version: { readyStatus.version }
        )
        let services = ServiceManagementClient(
            agentStatus: agentStatus,
            agentConfigurationError: agentConfigurationError,
            isAgentRegistrationCurrent: isAgentRegistrationCurrent,
            markAgentRegistrationCurrent: markAgentRegistrationCurrent,
            registerAgent: registerAgent,
            unregisterAgent: unregisterAgent,
            mainAppStatus: { .enabled },
            registerMainApp: {},
            unregisterMainApp: {},
            openLoginItemsSettings: {}
        )
        let homebrew = HomebrewServiceClient(
            isLoaded: { homebrewLoaded },
            installedAgentBinary: { URL(filePath: "/opt/homebrew/bin/agentd") },
            start: homebrewStart,
            stop: homebrewStop
        )
        return HostStore(
            agent: agent,
            services: services,
            homebrew: homebrew,
            health: HealthClient(check: healthCheck, checkDirect: { _ in true }),
            logs: AgentLogClient(
                recentLines: { _ in [] },
                reveal: {},
                fileURL: URL(filePath: "/tmp/mimi-remote-agentd-test.log")
            ),
            terminateApplication: terminateApplication
        )
    }

    private nonisolated static let pairing = PairingInfo(
        endpoint: "http://127.0.0.1:8787",
        pairURL: "mimiremote://pair?pair_sig=test",
        expiresAt: "2026-07-22T12:00:00Z",
        warnings: []
    )

    private nonisolated static let readyStatus: AgentStatus = {
        let doctor = AgentDoctorResults(
            ok: true,
            version: "0.1.0",
            listen: "127.0.0.1:8787",
            checks: []
        )
        return AgentStatus(
            processOK: true,
            serviceOK: true,
            processError: nil,
            serviceError: nil,
            version: "0.1.0",
            endpoint: "http://127.0.0.1:8787",
            configPath: "/tmp/config.json",
            projects: 1,
            doctorOK: true,
            doctor: doctor,
            pairExpires: nil
        )
    }()

    private nonisolated static let stoppedStatus = AgentStatus(
        processOK: false,
        serviceOK: false,
        processError: "agentd 未运行",
        serviceError: "readyz 不可用",
        version: "0.1.0",
        endpoint: "http://127.0.0.1:8787",
        configPath: "/tmp/config.json",
        projects: 1,
        doctorOK: true,
        doctor: readyStatus.doctor,
        pairExpires: nil
    )

    private nonisolated static func statusWithClaude(
        enabled: Bool,
        state: AgentRuntimeConnectionState
    ) -> AgentStatus {
        AgentStatus(
            processOK: readyStatus.processOK,
            serviceOK: readyStatus.serviceOK,
            processError: readyStatus.processError,
            serviceError: readyStatus.serviceError,
            version: readyStatus.version,
            endpoint: readyStatus.endpoint,
            configPath: readyStatus.configPath,
            projects: readyStatus.projects,
            doctorOK: readyStatus.doctorOK,
            doctor: readyStatus.doctor,
            pairExpires: nil,
            runtimeStatus: AgentRuntimeStatusSnapshot(
                checkedAt: "2026-08-03T03:00:00Z",
                runtimes: [
                    AgentRuntimeStatus(
                        id: "claude",
                        title: "Claude",
                        enabled: enabled,
                        state: state,
                        authMode: enabled ? "oauth" : nil,
                        planType: enabled ? "pro" : nil,
                        reason: enabled ? nil : "disabled",
                        rateLimits: nil
                    ),
                ]
            )
        )
    }

    private nonisolated static func claudeConfiguration(
        enabled: Bool,
        preference: ClaudeActivationPreference,
        previousEnabled: Bool = false,
        previousPreference: ClaudeActivationPreference = .automatic,
        changed: Bool = false,
        restartRequired: Bool = false,
        reason: String? = nil
    ) -> ClaudeConfigurationResult {
        ClaudeConfigurationResult(
            enabled: enabled,
            available: enabled,
            preference: preference,
            previousEnabled: previousEnabled,
            previousPreference: previousPreference,
            changed: changed,
            restartRequired: restartRequired,
            reason: reason ?? (enabled ? "ready" : "disabled_by_user"),
            message: enabled
                ? "已检测到 Claude Code 和兼容的 Claude bridge。"
                : "Claude 实验通道已关闭。"
        )
    }
}

@MainActor
private final class LaggingAgentRegistration {
    private var statusChecks = 0

    func nextStatus() -> ServiceRegistrationState {
        statusChecks += 1
        // bootstrap 读取两次；重启后的第一次读取仍返回 enabled，随后才完成注销。
        return statusChecks <= 3 ? .enabled : .notRegistered
    }
}

enum TestError: LocalizedError {
    case expected

    var errorDescription: String? { "预期的测试错误" }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class SuspendedStatusGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var suspended = false
    private var released = false

    func suspendReturning<T: Sendable>(_ value: T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                suspended = true
                condition.broadcast()
                while !released {
                    condition.wait()
                }
                condition.unlock()
                continuation.resume(returning: value)
            }
        }
    }

    func waitUntilSuspended() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while !suspended {
                    condition.wait()
                }
                condition.unlock()
                continuation.resume()
            }
        }
    }

    func resume() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
