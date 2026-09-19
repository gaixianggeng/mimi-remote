from pathlib import Path
import subprocess

def edit(path, old, new):
    p = Path(path); s = p.read_text()
    assert s.count(old) == 1, f'{path}: expected one match for {old[:90]!r}, got {s.count(old)}'
    p.write_text(s.replace(old, new))
root = Path('macos/MimiRemoteMac/Sources')
p = root/'State/HostStore.swift'
# Availability is observed state, independent of the UI mutation lock. Public
# pairing entry points still gate on isBusy. Internal takeover already owns it.
edit(p, 'guard moduleEnabled(module), status?.serviceOK == true, !isBusy else { return false }', 'guard moduleEnabled(module), status?.serviceOK == true else { return false }')
edit(p, 'if module == .tailcat { return tailcatStatus?.running == true }', 'if module == .tailcat { return tailcatError == nil && tailcatStatus?.running == true }')
edit(p, '''    var pairingBlockReason: String? {
        if isBusy { return "正在应用设置，请稍后重新配对。" }
        guard status?.moduleConfiguration != nil else {''', '''    var pairingBlockReason: String? {
        if isBusy { return "正在应用设置，请稍后重新配对。" }
        return pairingCapabilityBlockReason
    }

    private var pairingCapabilityBlockReason: String? {
        guard status?.moduleConfiguration != nil else {''')
edit(p, 'if let reason = pairingBlockReason { throw AgentClientError.commandFailed(reason) }', 'if let reason = pairingCapabilityBlockReason { throw AgentClientError.commandFailed(reason) }')
p = root/'Features/MenuBar/MenuBarContentView.swift'
edit(p, '''struct ModuleDetailsView: View {
    let store: HostStore
    let module: HostModule
''', '''struct ModuleDetailsView: View {
    let store: HostStore
    let module: HostModule
    @Environment(\.openWindow) private var openWindow
''')
edit(p, '''                if let auth = runtime.authMode { LabeledContent("认证", value: auth) }
''', '''                if let auth = runtime.authMode { LabeledContent("认证", value: auth) }
                if let reason = runtime.reason, !reason.isEmpty {
                    LabeledContent("诊断原因", value: reason).font(.caption).textSelection(.enabled)
                }
                if runtime.state == .signedOut {
                    Text("请在这台 Mac 上完成对应 Agent 的登录，然后刷新状态。启用开关不会代替账号登录。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if runtime.state == .unavailable {
                    Text("请检查本机安装与登录状态；诊断中可查看检测结果及修复建议。")
                        .font(.caption).foregroundStyle(.secondary)
                }
''')
edit(p, '''            Button("刷新状态") { Task { await store.refreshModules() } }.disabled(store.isBusy)
        }.padding(18).frame(width: 310)''', '''            HStack {
                Button("刷新状态") { Task { await store.refreshModules() } }.disabled(store.isBusy)
                Button("诊断与日志…") { openWindow(id: AppWindow.diagnostics.rawValue) }
            }
        }.padding(18).frame(width: 310)''')
p = Path('macos/MimiRemoteMac/Tests/HostStoreTests.swift')
edit(p, '    func testPairingFailureDoesNotRollBackSuccessfulTakeover() async {', '''    func testSuccessfulTakeoverCanPairWhileOwningLifecycleLock() async {
        let store = makeStore(configExists: true, homebrewLoaded: true,
            status: { Self.moduleStatus(tailscale: true, lan: false) },
            pair: { _ in Self.pairing })
        await store.bootstrap()
        await store.takeOverHomebrew()
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.pairing, Self.pairing)
        XCTAssertNil(store.lastError)
    }

    func testPairingFailureDoesNotRollBackSuccessfulTakeover() async {''')
subprocess.run(['bash', 'scripts/check-source-size.sh'], check=True)
subprocess.run(['bash', 'scripts/check-docs-static.sh'], check=True)
print('Completed lifecycle pairing lock and actionable provider details', flush=True)
