import Foundation
import XCTest
@testable import MimiRemoteMac

@MainActor
final class HostStoreTests: XCTestCase {
    func testBootstrapRequiresSetupWhenConfigIsMissing() async {
        let store = makeStore(configExists: false)

        await store.bootstrap()

        XCTAssertEqual(store.lifecycle, .notConfigured)
        XCTAssertEqual(store.owner, .none)
    }

    func testBootstrapDetectsRunningHomebrewServiceWithoutChangingIt() async {
        let store = makeStore(configExists: true, homebrewLoaded: true)

        await store.bootstrap()

        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertTrue(store.homebrewLoaded)
    }

    func testTakeoverStopsHomebrewThenStartsBundledAgent() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            homebrewStop: { events.append("stop-homebrew") }
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, ["stop-homebrew", "register-mac"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNotNil(store.pairing)
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
            }
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
            homebrewStop: { events.append("stop-homebrew") }
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
            unregisterAgent: { events.append("unregister-mac") }
        )
        await store.bootstrap()

        await store.restartService()

        XCTAssertEqual(events.values, ["unregister-mac", "register-mac"])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    private func makeStore(
        configExists: Bool,
        homebrewLoaded: Bool = false,
        agentStatus: @escaping @MainActor () -> ServiceRegistrationState = { .notRegistered },
        registerAgent: @escaping @MainActor () throws -> Void = {},
        unregisterAgent: @escaping @MainActor () async throws -> Void = {},
        homebrewStart: @escaping @Sendable () async throws -> Void = {},
        homebrewStop: @escaping @Sendable () async throws -> Void = {},
        setLANAccess: @escaping @Sendable (Bool) async throws -> NetworkConfigurationResult = {
            NetworkConfigurationResult(lanEnabled: $0, changed: false, restartRequired: false)
        },
        pair: (@Sendable (PairingNetwork) async throws -> PairingInfo)? = nil
    ) -> HostStore {
        let status = Self.readyStatus
        let doctor = status.doctor
        let agent = AgentCommandClient(
            configExists: { configExists },
            setup: { _ in Self.pairing },
            status: { status },
            statusAt: { _ in status },
            doctor: { _ in DoctorFixResults(fixes: [], results: doctor) },
            setLANAccess: setLANAccess,
            pair: pair ?? { _ in Self.pairing },
            version: { status.version }
        )
        let services = ServiceManagementClient(
            agentStatus: agentStatus,
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
            health: HealthClient(check: { _ in true }, checkDirect: { _ in true }),
            logs: AgentLogClient(
                recentLines: { _ in [] },
                reveal: {},
                fileURL: URL(filePath: "/tmp/mimi-remote-agentd-test.log")
            )
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

private enum TestError: LocalizedError {
    case expected

    var errorDescription: String? { "预期的测试错误" }
}

private final class EventRecorder: @unchecked Sendable {
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
