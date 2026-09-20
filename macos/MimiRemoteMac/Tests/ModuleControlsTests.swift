import Foundation
import XCTest
@testable import MimiRemoteMac

final class ModuleModelsTests: XCTestCase {
    func testEqualAgentEntriesAndIndependentConnections() {
        XCTAssertEqual(HostModuleGroup.agents.modules, [.codex, .claude])
        XCTAssertEqual(HostModuleGroup.connections.modules, [.tailscale, .tailcat, .lan])
        XCTAssertTrue(ModuleChangePresentation.impact(.claude, enabled: false).contains("所有移动连接"))
        XCTAssertTrue(ModuleChangePresentation.boundary(.tailscale).contains("不修改系统"))
    }

    func testUnknownAndNonfiniteQuotaNeverBecomesZero() {
        for used in [nil, Double.nan, Double.infinity] as [Double?] {
            let window = AgentRuntimeRateLimitWindow(usedPercent: used, windowDurationMins: 300, resetsAt: nil)
            XCTAssertNil(window.remainingFraction)
            XCTAssertNil(window.remainingPercentText)
        }
        let exhausted = AgentRuntimeRateLimitWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: nil)
        XCTAssertEqual(exhausted.remainingPercentText, "0%")
    }

    func testNetworkTransactionDecodesOriginalAbsentTailscalePreference() throws {
        let data = Data(#"{"lan_enabled":true,"tailscale_enabled":true,"changed":true,"restart_required":true,"previous":{"allow_lan":false},"applied":{"allow_lan":true,"allow_tailscale":true}}"#.utf8)
        let result = try JSONDecoder().decode(NetworkConfigurationResult.self, from: data)
        XCTAssertNil(result.previous?.allowTailscale)
        XCTAssertEqual(result.applied?.allowTailscale, true)
        XCTAssertEqual(try JSONDecoder().decode(NetworkConfigurationResult.self, from: JSONEncoder().encode(result)), result)
    }
}

@MainActor
final class ModuleControlsTests: XCTestCase {
    func testAllAgentsOffDisablesPairingWithoutDisablingHostService() async {
        let fixture = ModuleFixture(codex: false, claude: false, ts: true, lan: true)
        let store = fixture.store()
        await store.bootstrap()
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertFalse(store.canPair)
        XCTAssertTrue(store.pairingUnavailableReason.contains("全部"))
        await store.refreshPairing()
        XCTAssertNil(store.pairing)
        XCTAssertEqual(fixture.pairCalls, 0)
    }

    func testOnlyEnabledAvailableNetworkIsOffered() async {
        let fixture = ModuleFixture(codex: true, claude: false, ts: false, lan: true)
        let store = fixture.store()
        await store.bootstrap()
        XCTAssertEqual(store.availablePairingNetworks, [.localNetwork])
        XCTAssertEqual(store.moduleStateTitle(.tailscale), "已关闭")
        await store.refreshPairing(network: .tailscale)
        XCTAssertNil(store.pairing)
        XCTAssertEqual(fixture.pairCalls, 0)
    }

    func testCodexToggleRequiresResidentConfirmationAndPreservesClaude() async {
        let fixture = ModuleFixture(codex: true, claude: true, ts: true, lan: false)
        let store = fixture.store()
        await store.bootstrap()
        await store.setCodexEnabled(false)
        XCTAssertFalse(store.codexEnabled)
        XCTAssertTrue(store.claudeEnabled)
        XCTAssertNil(store.codexError)
        XCTAssertEqual(fixture.codexCalls, 1)
    }

    func testNetworkFailureRestoresReturnedSnapshotNotBooleanInversion() async {
        let fixture = ModuleFixture(codex: true, claude: true, ts: true, lan: false)
        let store = fixture.store()
        await store.bootstrap()
        fixture.failNextRegistration = true
        await store.setLANEnabled(true)
        XCTAssertNotNil(store.networkError)
        XCTAssertFalse(store.lanEnabled)
        XCTAssertTrue(store.tailscaleEnabled)
        XCTAssertEqual(fixture.restoredNetwork?.previous, NetworkModuleState(allowLAN: false, allowTailscale: true))
    }
}

private final class ModuleFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var codex: Bool
    private let claude: Bool
    private var ts: Bool
    private var lan: Bool
    private var pendingCodex: Bool?
    private var pendingNetwork: NetworkConfigurationResult?
    private var _pairCalls = 0
    private var _codexCalls = 0
    private var _restoredNetwork: NetworkConfigurationResult?
    // Only read/written by the MainActor service-registration stub.
    @MainActor var failNextRegistration = false
    var pairCalls: Int { lock.withLock { _pairCalls } }
    var codexCalls: Int { lock.withLock { _codexCalls } }
    var restoredNetwork: NetworkConfigurationResult? { lock.withLock { _restoredNetwork } }

    init(codex: Bool, claude: Bool, ts: Bool, lan: Bool) {
        self.codex = codex; self.claude = claude; self.ts = ts; self.lan = lan
    }
    func status() -> AgentStatus {
        lock.withLock {
            AgentStatus(processOK: true, serviceOK: true, processError: nil, serviceError: nil,
                        version: "test", endpoint: "http://127.0.0.1:8787", configPath: "/tmp/module-test.json",
                        projects: 1, doctorOK: true,
                        doctor: AgentDoctorResults(ok: true, version: "test", listen: "127.0.0.1:8787", checks: []),
                        pairExpires: nil,
                        moduleStatus: AgentModuleStatus(codexEnabled: codex, claudeEnabled: claude,
                                                       tailscaleEnabled: ts, lanEnabled: lan,
                                                       tailscaleAvailable: true, lanAvailable: true))
        }
    }
    func apply() {
        lock.withLock {
            if let pendingCodex { codex = pendingCodex; self.pendingCodex = nil }
            if let pendingNetwork {
                ts = pendingNetwork.tailscaleEnabled ?? ts
                lan = pendingNetwork.lanEnabled
                self.pendingNetwork = nil
            }
        }
    }
    @MainActor func store() -> HostStore {
        let agent = AgentCommandClient(
            configExists: { true }, setup: { _ in throw ModuleTestError.unexpected },
            status: { self.status() }, readiness: { self.status() }, statusAt: { _ in self.status() },
            doctor: { _ in DoctorFixResults(fixes: [], results: self.status().doctor) },
            configureClaude: { _, _ in
                ClaudeConfigurationResult(enabled: self.claude, available: self.claude, preference: .disabled,
                                          previousEnabled: self.claude, previousPreference: .disabled,
                                          changed: false, restartRequired: false, reason: "test", message: "")
            },
            setLANAccess: { _ in throw ModuleTestError.unexpected },
            pair: { _ in
                self.lock.withLock { self._pairCalls += 1 }
                throw ModuleTestError.unexpected
            },
            version: { "test" },
            configureCodex: { preference in
                self.lock.withLock {
                    self._codexCalls += 1
                    let enabled = preference == "enabled"
                    let before = CodexModuleState(enabled: self.codex, activation: self.codex ? "enabled" : "disabled")
                    self.pendingCodex = enabled
                    return CodexConfigurationResult(enabled: enabled, available: enabled, changed: true,
                                                    restartRequired: true, reason: "test", message: "",
                                                    previous: before, applied: CodexModuleState(enabled: enabled, activation: preference))
                }
            },
            configureNetwork: { network, enabled in
                self.lock.withLock {
                    let before = NetworkModuleState(allowLAN: self.lan, allowTailscale: self.ts)
                    let after = NetworkModuleState(allowLAN: network == .localNetwork ? enabled : self.lan,
                                                   allowTailscale: network == .tailscale ? enabled : self.ts)
                    let result = NetworkConfigurationResult(lanEnabled: after.allowLAN, changed: true,
                                                            restartRequired: true, tailscaleEnabled: after.allowTailscale,
                                                            previous: before, applied: after)
                    self.pendingNetwork = result
                    return result
                }
            },
            restoreNetwork: { result in
                self.lock.withLock {
                    self._restoredNetwork = result
                    let restored = NetworkConfigurationResult(lanEnabled: result.previous!.allowLAN,
                                                              changed: true, restartRequired: true,
                                                              tailscaleEnabled: result.previous!.allowTailscale,
                                                              previous: result.applied, applied: result.previous)
                    self.pendingNetwork = restored
                    return restored
                }
            }
        )
        let services = ServiceManagementClient(
            agentStatus: { .notRegistered }, agentConfigurationError: { nil },
            isAgentRegistrationCurrent: { true }, markAgentRegistrationCurrent: {}, registerAgent: {
                if self.failNextRegistration { self.failNextRegistration = false; throw ModuleTestError.unexpected }
                self.apply()
            }, unregisterAgent: {}, agentLaunchFailure: { nil }, mainAppStatus: { .enabled }, registerMainApp: {},
            unregisterMainApp: {}, openLoginItemsSettings: {}
        )
        return HostStore(agent: agent, services: services,
                         homebrew: HomebrewServiceClient(isLoaded: { false }, installedAgentBinary: { nil }, start: {}, stop: {}),
                         health: HealthClient(check: { _ in false }, checkDirect: { _ in true }),
                         logs: AgentLogClient(recentLines: { _ in [] }, reveal: {}, fileURL: URL(filePath: "/tmp/module-test.log")))
    }
}
private enum ModuleTestError: Error { case unexpected }
