from pathlib import Path

def edit(path, old, new, count=1):
    p = Path(path); s = p.read_text()
    assert s.count(old) == count, f'{path}: expected {count}, got {s.count(old)}: {old[:80]!r}'
    p.write_text(s.replace(old, new))
root = Path('macos/MimiRemoteMac/Sources')
p = root/'State/HostStore.swift'
edit(p, '    private func preservingRuntimeSnapshotIfNeeded(in current: AgentStatus) -> AgentStatus {', '    private func preservingRuntimeSnapshotIfNeeded(in current: AgentStatus, markStale: Bool = true) -> AgentStatus {')
edit(p, '            stale: true,\n            modules: previousSnapshot.modules', '            stale: markStale ? true : previousSnapshot.stale,\n            modules: previousSnapshot.modules')
edit(p, '            let resolved = preservingRuntimeSnapshotIfNeeded(in: current)\n            status = resolved', '            let resolved = preservingRuntimeSnapshotIfNeeded(in: current, markStale: false)\n            status = resolved')
# Lightweight readiness intentionally omits provider/quota data. It must not
# turn a still-fresh provider snapshot stale once per minute and block pairing.
edit(p, '    private(set) var moduleUndo: ModuleUndo?\n', '    private(set) var moduleUndo: ModuleUndo?\n    @ObservationIgnored private var tailcatStatusSequence: UInt64 = 0\n')
edit(p, '''    func refreshTailcatStatus() async {
        guard owner == .macApp else { return }
        do {
            tailcatStatus = try await agent.tailcatStatus()
            tailcatError = nil
            tailcatNotice = nil
        } catch {
            tailcatError = error.localizedDescription
        }
    }''', '''    func refreshTailcatStatus() async {
        guard owner == .macApp else { return }
        tailcatStatusSequence &+= 1
        let sequence = tailcatStatusSequence
        do {
            let current = try await agent.tailcatStatus()
            guard sequence == tailcatStatusSequence else { return }
            tailcatStatus = current
            tailcatError = nil
            tailcatNotice = nil
        } catch {
            guard sequence == tailcatStatusSequence else { return }
            tailcatError = error.localizedDescription
        }
    }''')
edit(p, '        invalidateModulePairing()\n        isBusy = true\n        isUpdatingTailcat = true', '        invalidateModulePairing()\n        tailcatStatusSequence &+= 1\n        isBusy = true\n        isUpdatingTailcat = true', count=3)
# Undo is also a configuration transaction: failure to reload the inverse
# operation restores its own prior revision, not an unrelated disk snapshot.
edit(p, '''        defer { isBusy = false; modulePending = nil }
        do {
            let restored = try await agent.configureModule(undo.module, nil, change.previous, change.revision)
            if restored.restartRequired { try await reloadMacAgentForConfigurationChange() }
            try await waitForModuleConfiguration(restored.configuration)
            lastError = nil
        } catch {
            lastError = "撤销未完成：\\(error.localizedDescription)。请刷新后检查模块状态。"
        }''', '''        defer { isBusy = false; modulePending = nil }
        var inverse: ModuleChange?
        do {
            let restored = try await agent.configureModule(undo.module, nil, change.previous, change.revision)
            inverse = restored
            if restored.restartRequired { try await reloadMacAgentForConfigurationChange() }
            try await waitForModuleConfiguration(restored.configuration)
            lastError = nil
        } catch {
            let message = error.localizedDescription
            if let inverse, inverse.changed {
                do {
                    let restored = try await agent.configureModule(undo.module, nil, inverse.previous, inverse.revision)
                    try await reloadMacAgentForConfigurationChange()
                    try await waitForModuleConfiguration(restored.configuration)
                    lastError = "撤销失败，已恢复撤销前设置：\\(message)"
                } catch {
                    lastError = "撤销失败：\\(message)。自动恢复未完成：\\(error.localizedDescription)"
                }
            } else {
                lastError = "撤销未完成：\\(message)。请刷新后检查模块状态。"
            }
        }''')

p = root/'Features/Pairing/PairingView.swift'
edit(p, '        .onChange(of: selectedNetwork) { _, network in', '''        .onChange(of: store.pairingBlockReason) { _, reason in
            if reason == nil, store.pairing == nil { refreshPairing(network: .automatic) }
        }
        .onChange(of: store.availablePairingNetworks) { _, networks in
            guard !store.isBusy, let first = networks.first else { return }
            if !networks.contains(selectedNetwork) {
                suppressNextNetworkChange = true
                selectedNetwork = first
            }
            if let pairing = store.pairing, !networks.contains(pairing.network) {
                refreshPairing(network: first)
            }
        }
        .onChange(of: selectedNetwork) { _, network in''')

p = Path('internal/setup/modules.go')
edit(p, '''		case "tailscale":
			next.Tailscale = &enabled''', '''        case "tailscale":
            // Legacy private/wildcard binds implied LAN even without allow_lan.
            // Opting into explicit transport policy must not change that other
            // module's effective intent. Undo still restores absent fields.
            if previous.Tailscale == nil && previous.LAN == nil {
                legacy, err := config.LoadSnapshot(raw)
                if err != nil { return result, err }
                lanEnabled := legacy.LANAccessEnabled()
                next.LAN = &lanEnabled
            }
            next.Tailscale = &enabled''')
p = Path('internal/httpapi/module_access.go')
edit(p, 'return r.cfg.Network.AllowLAN && local.IsPrivate()', 'return r.cfg.Network.AllowLAN && local.IsPrivate() && remote.IsPrivate()')
p = Path('internal/httpapi/module_access_test.go')
edit(p, '\t\t{"lan_only",', '\t\t{"public_origin_not_lan", "192.168.1.2:8787", "203.0.113.2:50000", true, false, false},\n\t\t{"lan_only",')
p.write_text(p.read_text() + '''
func TestModuleDisabledCodexDoesNotProbeProvider(t *testing.T) {
    enabled := false
    router := &Router{cfg: config.Config{Codex: config.CodexConfig{Enabled: &enabled}}}
    status := router.probeCodexRuntime(context.Background())
    if status.Enabled || status.State != runtimeStateDisabled {
        t.Fatalf("disabled provider was probed: %+v", status)
    }
}
''')
p = Path('internal/setup/modules_test.go')
p.write_text(p.read_text() + '''
func TestModuleTailscaleTogglePreservesLegacyLANAndUndo(t *testing.T) {
    path := moduleTestConfig(t)
    raw, err := os.ReadFile(path)
    if err != nil { t.Fatal(err) }
    var doc map[string]any
    if err := json.Unmarshal(raw, &doc); err != nil { t.Fatal(err) }
    doc["listen"] = "192.168.1.2:8787"
    raw, err = json.Marshal(doc)
    if err != nil { t.Fatal(err) }
    if err := os.WriteFile(path, raw, 0600); err != nil { t.Fatal(err) }
    change, err := ConfigureModule(context.Background(), path, "tailscale", false, "", nil)
    if err != nil { t.Fatal(err) }
    if !change.Configuration.LANEnabled || change.Configuration.TailscaleEnabled {
        t.Fatalf("another module's intent changed: %+v", change)
    }
    restored, err := ConfigureModule(context.Background(), path, "tailscale", true, change.Revision, &change.Previous)
    if err != nil { t.Fatal(err) }
    if !restored.Configuration.LANEnabled || !restored.Configuration.TailscaleEnabled {
        t.Fatalf("legacy intent not restored: %+v", restored)
    }
}

func TestModuleAllConnectionsOffKeepsOnlyLocalControl(t *testing.T) {
    path := moduleTestConfig(t)
    change, err := ConfigureModule(context.Background(), path, "tailscale", false, "", nil)
    if err != nil { t.Fatal(err) }
    if change.Configuration.LANEnabled { t.Fatal("LAN was silently enabled") }
    _, err = ConfigureModule(context.Background(), path, "lan", false, "", nil)
    if err != nil { t.Fatal(err) }
}
''')

p = Path('macos/MimiRemoteMac/Tests/AgentModelsTests.swift')
p.write_text(p.read_text() + '''
final class ModuleManagementModelsTests: XCTestCase {
    func testModuleIntentDecodesSeparatelyFromLiveState() throws {
        let data = Data(#"{"checked_at":"2026-09-19T00:00:00Z","runtimes":[],"modules":{"codex_enabled":false,"claude_enabled":true,"tailscale_enabled":false,"lan_enabled":true,"tailcat_enabled":false}}"#.utf8)
        let snapshot = try JSONDecoder().decode(AgentRuntimeStatusSnapshot.self, from: data)
        XCTAssertEqual(snapshot.modules?.isEnabled(.codex), false)
        XCTAssertEqual(snapshot.modules?.isEnabled(.claude), true)
        XCTAssertEqual(snapshot.modules?.isEnabled(.lan), true)
        XCTAssertTrue(snapshot.runtimes.isEmpty)
    }

    func testOldRuntimeSnapshotHasNoFabricatedModuleConfiguration() throws {
        let snapshot = try JSONDecoder().decode(AgentRuntimeStatusSnapshot.self, from: Data(#"{"runtimes":[]}"#.utf8))
        XCTAssertNil(snapshot.modules)
    }

    func testHotTailcatStateDoesNotInvalidateResidentConfiguration() {
        let a = ModuleConfiguration(codexEnabled: false, claudeEnabled: true, tailscaleEnabled: false, lanEnabled: true, tailcatEnabled: false)
        let b = ModuleConfiguration(codexEnabled: false, claudeEnabled: true, tailscaleEnabled: false, lanEnabled: true, tailcatEnabled: true)
        XCTAssertTrue(a.matchesResident(b))
        let c = ModuleConfiguration(codexEnabled: true, claudeEnabled: true, tailscaleEnabled: false, lanEnabled: true, tailcatEnabled: true)
        XCTAssertFalse(a.matchesResident(c))
    }

    func testUndoPayloadContainsOnlyModuleIntent() throws {
        let value = ModulePreferences(codex: nil, claude: false, claudeActivation: "disabled", lan: nil, tailscale: false)
        let bytes = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ModulePreferences.self, from: bytes)
        XCTAssertEqual(decoded, value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: ["codex", "claude", "claude_activation", "lan", "tailscale"]))
    }
}
''')
for path in root.rglob('*.swift'):
    assert len(path.read_text().splitlines()) <= 2000, f'source size limit: {path}'
print('Refined migration, readiness, undo and pairing boundaries', flush=True)
