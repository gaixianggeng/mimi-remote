from pathlib import Path
import subprocess
script = Path('.gh491/refine.py').read_text()
old = '    doc["listen"] = "192.168.1.2:8787"\n'
assert script.count(old) == 1
# A valid legacy private bind already required explicit allow_lan. Preserve
# that intent; do not construct an invalid fixture merely to exercise migration.
script = script.replace(old, old + '    doc["network"] = map[string]any{"allow_lan": true}\n')
exec(compile(script, 'module-boundary-refinement.py', 'exec'))

p = Path('macos/MimiRemoteMac/Tests/HostStoreTests.swift')
s = p.read_text()
a = s.index('    func testSelectingLANEnablesAccessRestartsOnceAndReturnsLANPairing()')
b = s.index('    func testConfiguringTailcatRelayUpdatesStatusAndClearsOldPairing()', a)
s = s[:a] + '''    func testSelectingEnabledLANDoesNotMutateNetworkOrRestart() async {
        let events = EventRecorder()
        let lanPairing = PairingInfo(endpoint: "http://192.168.31.20:8787", network: .localNetwork,
            pairURL: "mimiremote://pair?pair_sig=lan", expiresAt: "2026-09-20T12:00:00Z", warnings: [])
        let store = makeStore(configExists: true,
            status: { Self.moduleStatus(tailscale: true, lan: true) },
            registerAgent: { events.append("register") },
            unregisterAgent: { events.append("unregister") },
            setLANAccess: { enabled in
                events.append("write-lan")
                return NetworkConfigurationResult(lanEnabled: enabled, changed: true, restartRequired: true)
            },
            pair: { network in events.append("pair-\\(network.rawValue)"); return lanPairing })
        await store.bootstrap()
        let before = events.values
        await store.refreshPairing(network: .localNetwork)
        XCTAssertEqual(Array(events.values.dropFirst(before.count)), ["pair-lan"])
        XCTAssertFalse(events.values.contains("write-lan"))
        XCTAssertEqual(store.pairing, lanPairing)
        XCTAssertEqual(store.pairingNetwork, .localNetwork)
    }

    func testAutomaticPairingUsesOnlyAnAlreadyEnabledAvailableLAN() async {
        let events = EventRecorder()
        let lanPairing = PairingInfo(endpoint: "http://192.168.31.20:8787", network: .localNetwork,
            pairURL: "mimiremote://pair?pair_sig=lan", expiresAt: "2026-09-20T12:00:00Z", warnings: [])
        let store = makeStore(configExists: true,
            status: { Self.moduleStatus(tailscale: false, lan: true) },
            setLANAccess: { enabled in
                events.append("write-lan")
                return NetworkConfigurationResult(lanEnabled: enabled, changed: false, restartRequired: false)
            },
            pair: { network in events.append("pair-\\(network.rawValue)"); return lanPairing })
        await store.bootstrap()
        await store.refreshPairing()
        XCTAssertEqual(events.values, ["pair-lan"])
        XCTAssertEqual(store.pairing, lanPairing)
    }

    func testNoAvailableConnectionDoesNotEnableLANOrGeneratePairing() async {
        let events = EventRecorder()
        let store = makeStore(configExists: true,
            status: { Self.moduleStatus(tailscale: false, lan: false) },
            setLANAccess: { enabled in
                events.append("write-lan")
                return NetworkConfigurationResult(lanEnabled: enabled, changed: true, restartRequired: true)
            },
            pair: { _ in events.append("pair"); return Self.pairing })
        await store.bootstrap()
        await store.refreshPairing()
        XCTAssertTrue(events.values.isEmpty)
        XCTAssertNil(store.pairing)
        XCTAssertNotNil(store.pairingBlockReason)
        XCTAssertNotNil(store.lastError)
    }

    func testLatestPairingRefreshWinsWhenAutomaticRequestFinishesLast() async {
        let gate = SuspendedStatusGate()
        let automaticPairing = PairingInfo(endpoint: "http://100.64.0.8:8787", network: .tailscale,
            pairURL: "mimiremote://pair?pair_sig=automatic", expiresAt: "2026-09-20T12:00:00Z", warnings: [])
        let lanPairing = PairingInfo(endpoint: "http://192.168.31.20:8787", network: .localNetwork,
            pairURL: "mimiremote://pair?pair_sig=lan", expiresAt: "2026-09-20T12:00:00Z", warnings: [])
        let store = makeStore(configExists: true,
            status: { Self.moduleStatus(tailscale: true, lan: true) },
            pair: { network in
                if network == .tailscale { return await gate.suspendReturning(automaticPairing) }
                return lanPairing
            })
        await store.bootstrap()
        let automaticRefresh = Task { await store.refreshPairing() }
        await gate.waitUntilSuspended()
        await store.refreshPairing(network: .localNetwork)
        gate.resume()
        await automaticRefresh.value
        XCTAssertEqual(store.pairingNetwork, .localNetwork)
        XCTAssertEqual(store.pairing, lanPairing)
    }

    func testLightReadinessKeepsFreshModuleAvailability() async {
        let full = Self.moduleStatus(tailscale: true, lan: false)
        let light = Self.moduleStatus(tailscale: true, lan: false, includeRuntime: false)
        let store = makeStore(configExists: true, status: { full }, readiness: { light })
        await store.bootstrap()
        XCTAssertNil(store.pairingBlockReason)
        await store.performMonitoringTick(6, now: Date())
        XCTAssertNil(store.pairingBlockReason)
        XCTAssertEqual(store.status?.runtimeStatus?.stale, false)
        XCTAssertTrue(store.modulesApplied)
    }

    private static func moduleStatus(tailscale: Bool, lan: Bool, includeRuntime: Bool = true) -> AgentStatus {
        let intent = ModuleConfiguration(codexEnabled: true, claudeEnabled: false,
            tailscaleEnabled: tailscale, lanEnabled: lan, tailcatEnabled: false)
        let snapshot = AgentRuntimeStatusSnapshot(checkedAt: ISO8601DateFormatter().string(from: Date()),
            runtimes: [AgentRuntimeStatus(id: "codex", title: "Codex", enabled: true, state: .connected,
                authMode: "chatgpt", planType: "pro", reason: nil, rateLimits: nil)],
            refreshing: false, stale: false, modules: intent)
        let ready = Self.readyStatus
        return AgentStatus(processOK: true, serviceOK: true, processError: nil, serviceError: nil,
            version: ready.version, serverVersion: ready.serverVersion, endpoint: ready.endpoint,
            configPath: ready.configPath, projects: ready.projects, doctorOK: true, doctor: ready.doctor,
            pairExpires: nil, runtimeStatus: includeRuntime ? snapshot : nil, moduleConfiguration: intent,
            connectionStatus: includeRuntime ? [
                ConnectionModuleStatus(id: "tailscale", enabled: tailscale, available: tailscale, endpoint: nil, reason: nil),
                ConnectionModuleStatus(id: "lan", enabled: lan, available: lan, endpoint: nil, reason: nil)
            ] : nil)
    }

''' + s[b:]
# Relay invalidation test needs an actual eligible provider before producing QR.
needle = '            pair: { _ in tailcatPairing },'
pos = s.index(needle)
anchor = s.rfind('            agentStatus: { .enabled },', 0, pos)
assert anchor != -1 and pos - anchor < 120
s = s[:anchor] + s[anchor:].replace('            agentStatus: { .enabled },', '            agentStatus: { .enabled },\n            status: { Self.moduleStatus(tailscale: true, lan: true) },', 1)
p.write_text(s)

p = Path('macos/MimiRemoteMac/Sources/Features/MenuBar/MenuBarContentView.swift')
s = p.read_text()
s = s.replace('Button("日志与完整诊断…")', 'Button("修复可修复项") { Task { await store.runDoctor(fix: true) } }\n                            .disabled(store.isBusy)\n                        Button("日志与完整诊断…")', 1)
p.write_text(s)
subprocess.run(['bash', 'scripts/check-source-size.sh'], check=True)
subprocess.run(['bash', 'scripts/check-docs-static.sh'], check=True)
subprocess.run(['bash', 'scripts/verify-change.sh', '--plan'], check=True)
print('Updated pairing regressions to explicit module intent; static repository checks passed', flush=True)
