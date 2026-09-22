import Foundation
import XCTest
@testable import MimiRemoteMac

final class ModuleModelsTests: XCTestCase {
    func testEqualAgentEntriesAndIndependentConnections() {
        XCTAssertEqual(HostModuleGroup.agents.modules, [.codex, .claude])
        XCTAssertEqual(HostModuleGroup.connections.modules, [.tailscale, .lan, .tailcat])
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
        XCTAssertNotNil(store.moduleError(.lan))
        XCTAssertNil(store.moduleError(.tailscale))
        XCTAssertFalse(store.lanEnabled)
        XCTAssertTrue(store.tailscaleEnabled)
        XCTAssertEqual(fixture.restoredNetwork?.previous, NetworkModuleState(allowLAN: false, allowTailscale: true))
    }

    /// reload 把 lifecycle 置为 .starting 后，注销/登记失败且自动恢复也失败。
    /// 操作必须结束在明确的失败/降级态并保留真实错误，不能停在"正在启动"把开关一直锁住。
    func testFailedNetworkModuleChangeDoesNotRemainStarting() async {
        let fixture = ModuleFixture(codex: true, claude: true, ts: true, lan: false)
        let store = fixture.store()
        await store.bootstrap()
        XCTAssertEqual(store.lifecycle, .ready)

        fixture.failNextRegistration = true
        fixture.failNetworkRestore = true
        await store.setLANEnabled(true)

        XCTAssertFalse(store.isBusy)
        XCTAssertNotEqual(store.lifecycle, .starting, "失败后不得继续假装正在启动")
        XCTAssertNotEqual(store.lifecycle, .ready, "退出启动中不等于宣称服务健康")
        XCTAssertNotNil(store.networkError)
        XCTAssertEqual(store.moduleError(.lan), store.networkError)
        // 服务状态仍可确认时应收敛到真实状态，而不是无差别标成失败。
        XCTAssertEqual(store.lifecycle, .degraded(store.networkError ?? ""))
    }

    /// 状态也不可确认时同样不能留在 .starting，错误必须归到正确模块。
    func testFailedNetworkModuleChangeSettlesWithoutTrustworthyStatus() async {
        let fixture = ModuleFixture(codex: true, claude: true, ts: true, lan: false)
        let store = fixture.store()
        await store.bootstrap()

        fixture.failNextRegistration = true
        fixture.failNetworkRestore = true
        fixture.failStatusReads = true
        await store.setLANEnabled(true)

        XCTAssertFalse(store.isBusy)
        XCTAssertNotEqual(store.lifecycle, .starting)
        XCTAssertNotEqual(store.lifecycle, .ready)
        XCTAssertNotNil(store.moduleError(.lan))
        XCTAssertNil(store.moduleError(.tailscale), "错误不得归到未操作的模块")
    }

    /// Codex 分支走同一收尾，不能只在网络路径生效。
    func testFailedCodexModuleChangeDoesNotRemainStarting() async {
        let fixture = ModuleFixture(codex: true, claude: true, ts: true, lan: true)
        let store = fixture.store()
        await store.bootstrap()

        fixture.failNextRegistration = true
        await store.setCodexEnabled(false)

        XCTAssertFalse(store.isBusy)
        XCTAssertNotEqual(store.lifecycle, .starting)
        XCTAssertNotEqual(store.lifecycle, .ready)
        XCTAssertNotNil(store.moduleError(.codex))
    }

    func testClaudeToggleReloadsWhenDiskAlreadyMatchesButResidentDoesNot() async {
        let fixture = ModuleFixture(codex: true, claude: true, claudeOnDisk: false, ts: true, lan: false)
        let store = fixture.store()
        await store.bootstrap()
        let registrationsBeforeToggle = fixture.registrationCalls

        await store.setClaudeEnabled(false)

        XCTAssertFalse(store.claudeEnabled)
        XCTAssertNil(store.claudeError)
        XCTAssertEqual(fixture.registrationCalls, registrationsBeforeToggle + 1)
    }

    func testClaudeEnableReloadsWhenDiskIsOnButResidentIsOff() async {
        let fixture = ModuleFixture(codex: true, claude: false, claudeOnDisk: true, ts: true, lan: false)
        let store = fixture.store()
        await store.bootstrap()
        let registrationsBeforeToggle = fixture.registrationCalls

        await store.setClaudeEnabled(true)

        XCTAssertTrue(store.claudeEnabled)
        XCTAssertNil(store.claudeError)
        XCTAssertEqual(fixture.registrationCalls, registrationsBeforeToggle + 1)
    }
}

private final class ModuleFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var codex: Bool
    private var claude: Bool
    private var claudeOnDisk: Bool
    private var ts: Bool
    private var lan: Bool
    private var pendingCodex: Bool?
    private var pendingClaude: Bool?
    private var pendingNetwork: NetworkConfigurationResult?
    private var _pairCalls = 0
    private var _codexCalls = 0
    private var _restoredNetwork: NetworkConfigurationResult?
    private var _registrationCalls = 0
    // Only read/written by the MainActor service-registration stub.
    @MainActor var failNextRegistration = false
    /// 恢复也失败（模拟配置已被其他操作改动的 CAS 冲突）。
    private var _failNetworkRestore = false
    /// 失败收尾时状态不可确认，用于区分"读到真实状态"和"只能进入降级态"两条出口。
    private var _failStatusReads = false
    var failNetworkRestore: Bool {
        get { lock.withLock { _failNetworkRestore } }
        set { lock.withLock { _failNetworkRestore = newValue } }
    }
    var failStatusReads: Bool {
        get { lock.withLock { _failStatusReads } }
        set { lock.withLock { _failStatusReads = newValue } }
    }
    var pairCalls: Int { lock.withLock { _pairCalls } }
    var codexCalls: Int { lock.withLock { _codexCalls } }
    var restoredNetwork: NetworkConfigurationResult? { lock.withLock { _restoredNetwork } }
    var registrationCalls: Int { lock.withLock { _registrationCalls } }

    init(codex: Bool, claude: Bool, claudeOnDisk: Bool? = nil, ts: Bool, lan: Bool) {
        self.codex = codex
        self.claude = claude
        self.claudeOnDisk = claudeOnDisk ?? claude
        self.ts = ts
        self.lan = lan
    }
    func status() -> AgentStatus {
        lock.withLock {
            AgentStatus(processOK: true, serviceOK: true, processError: nil, serviceError: nil,
                        version: "test", endpoint: "http://127.0.0.1:8787", configPath: "/tmp/module-test.json",
                        projects: 1, doctorOK: true,
                        doctor: AgentDoctorResults(ok: true, version: "test", listen: "127.0.0.1:8787", checks: []),
                        pairExpires: nil,
                        runtimeStatus: AgentRuntimeStatusSnapshot(
                            checkedAt: ISO8601DateFormatter().string(from: Date()),
                            runtimes: [
                                AgentRuntimeStatus(
                                    id: "claude", title: "Claude", enabled: claude,
                                    state: claude ? .available : .disabled,
                                    authMode: nil, planType: nil, reason: nil, rateLimits: nil
                                )
                            ],
                            refreshing: false,
                            stale: false
                        ),
                        moduleStatus: AgentModuleStatus(codexEnabled: codex, claudeEnabled: claude,
                                                       tailscaleEnabled: ts, lanEnabled: lan,
                                                       tailscaleAvailable: true, lanAvailable: true))
        }
    }
    func apply() {
        lock.withLock {
            if let pendingCodex { codex = pendingCodex; self.pendingCodex = nil }
            if let pendingClaude { claude = pendingClaude; self.pendingClaude = nil }
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
            status: {
                if self.failStatusReads { throw ModuleTestError.unexpected }
                return self.status()
            },
            readiness: { self.status() }, statusAt: { _ in self.status() },
            doctor: { _ in DoctorFixResults(fixes: [], results: self.status().doctor) },
            configureClaude: { preference, _ in
                self.lock.withLock {
                    if preference == .automatic {
                        return ClaudeConfigurationResult(
                            enabled: self.claude, available: self.claude, preference: .automatic,
                            previousEnabled: self.claudeOnDisk, previousPreference: .automatic,
                            changed: false, restartRequired: false, reason: "test", message: ""
                        )
                    }
                    let target = preference != .disabled
                    let previous = self.claudeOnDisk
                    self.claudeOnDisk = target
                    self.pendingClaude = target
                    return ClaudeConfigurationResult(
                        enabled: target, available: target, preference: preference,
                        previousEnabled: previous, previousPreference: previous ? .enabled : .disabled,
                        changed: previous != target, restartRequired: previous != target,
                        reason: "test", message: ""
                    )
                }
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
                if self.failNetworkRestore { throw ModuleTestError.unexpected }
                return self.lock.withLock {
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
                self.lock.withLock { self._registrationCalls += 1 }
                if self.failNextRegistration { self.failNextRegistration = false; throw ModuleTestError.unexpected }
                self.apply()
            }, unregisterAgent: {}, agentLaunchFailure: { nil }, mainAppStatus: { .enabled }, registerMainApp: {},
            unregisterMainApp: {}, openLoginItemsSettings: {}
        )
        return HostStore(agent: agent, services: services,
                         homebrew: HomebrewServiceClient(isLoaded: { false }, installedAgentBinary: { nil }, start: {}, stop: {}),
                         health: HealthClient(check: { _ in false }, checkDirect: { _ in true }),
                         logs: AgentLogClient(recentLines: { _ in [] }, exportLines: { [] }))
    }
}
private enum ModuleTestError: Error { case unexpected }
