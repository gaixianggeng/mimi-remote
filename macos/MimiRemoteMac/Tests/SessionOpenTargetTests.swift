import XCTest
@testable import MimiRemoteMac

final class SessionOpenTargetTests: XCTestCase {
    private let allApps: Set<String> = [
        SessionOpenTarget.codexDesktopBundleID, SessionOpenTarget.claudeDesktopBundleID,
        TerminalApp.ghostty.bundleID, TerminalApp.herdr.bundleID, TerminalApp.terminal.bundleID,
    ]

    private func session(_ runtime: SessionRuntime, activity: DesktopSession.Activity = .idle,
                         holder: DesktopSession.Holder? = nil, cwd: String = "/repo") -> DesktopSession {
        DesktopSession(threadID: "t1", runtime: runtime, title: "t", projectName: "p", cwd: cwd,
                       updatedAt: nil, activity: activity, holder: holder)
    }

    func testCandidatesListDesktopFirstAndOnlyInstalledTerminals() {
        XCTAssertEqual(
            SessionOpenTarget.candidates(for: .codex, installedBundleIDs: allApps),
            [.codexDesktop, .terminal(.ghostty), .terminal(.herdr), .terminal(.terminal)]
        )
        XCTAssertEqual(
            SessionOpenTarget.candidates(for: .claude, installedBundleIDs: [TerminalApp.terminal.bundleID]),
            [.claudeDesktop, .terminal(.terminal)]
        )
    }

    func testPreferredUsesStoredChoiceWhenStillAvailable() {
        let candidates = SessionOpenTarget.candidates(for: .codex, installedBundleIDs: allApps)
        XCTAssertEqual(SessionOpenTarget.preferred(stored: "terminal.ghostty", candidates: candidates, installedBundleIDs: allApps), .terminal(.ghostty))
        XCTAssertEqual(SessionOpenTarget.preferred(stored: "", candidates: candidates, installedBundleIDs: allApps), .codexDesktop)
        // 记住的是 Claude 桌面版或已卸载的终端时，退回第一个装着的。
        XCTAssertEqual(SessionOpenTarget.preferred(stored: "desktop.claude", candidates: candidates, installedBundleIDs: allApps), .codexDesktop)
        let onlyTerminal: Set<String> = [TerminalApp.terminal.bundleID]
        XCTAssertEqual(
            SessionOpenTarget.preferred(
                stored: "terminal.ghostty",
                candidates: SessionOpenTarget.candidates(for: .codex, installedBundleIDs: onlyTerminal),
                installedBundleIDs: onlyTerminal
            ),
            .terminal(.terminal),
            "桌面版没装时默认用装着的终端"
        )
    }

    func testStorageValueRoundTrips() {
        for target in [SessionOpenTarget.codexDesktop, .claudeDesktop, .terminal(.ghostty), .terminal(.herdr), .terminal(.terminal)] {
            XCTAssertEqual(SessionOpenTarget(storageValue: target.storageValue), target)
        }
        XCTAssertNil(SessionOpenTarget(storageValue: "terminal.unknown"))
    }

    func testUnavailableReasons() {
        XCTAssertNil(SessionOpenTarget.codexDesktop.unavailableReason(for: session(.codex, activity: .running), installedBundleIDs: allApps),
                     "Codex 桌面版不看占用状态，直接打开")
        XCTAssertNotNil(SessionOpenTarget.codexDesktop.unavailableReason(for: session(.codex), installedBundleIDs: []))
        XCTAssertNil(SessionOpenTarget.claudeDesktop.unavailableReason(for: session(.claude), installedBundleIDs: allApps))
        XCTAssertEqual(SessionOpenTarget.claudeDesktop.unavailableReason(for: session(.claude, activity: .running), installedBundleIDs: allApps),
                       "这一轮结束后才能打开。")
        XCTAssertEqual(SessionOpenTarget.claudeDesktop.unavailableReason(for: session(.claude, holder: .claudeTerminal), installedBundleIDs: allApps),
                       "这条会话已经在终端里打开。")
        XCTAssertNotNil(SessionOpenTarget.terminal(.ghostty).unavailableReason(for: session(.codex, cwd: ""), installedBundleIDs: allApps))
        XCTAssertEqual(SessionOpenTarget.claudeDesktop.buttonTitle(for: session(.claude, holder: .claudeDesktop)), "前往")
        XCTAssertEqual(SessionOpenTarget.terminal(.ghostty).buttonTitle(for: session(.claude, holder: .claudeDesktop)), "打开")
    }

    func testCodexDesktopLinkDetectsLocalSSHChild() {
        let ps = """
          1914     1 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
         65034  1914 /usr/bin/ssh -T -v -o BatchMode=yes -o ServerAliveInterval=15 127.0.0.1 sh -c 'codex app-server proxy'
         70000  1914 /usr/bin/ssh -T dev@build.example.com sh -c 'codex app-server proxy'
         70001   500 /usr/bin/ssh -T 127.0.0.1 true
        """
        let hosts: Set<String> = ["127.0.0.1", "localhost"]
        XCTAssertTrue(CodexDesktopLink.hasLocalSSHChild(psOutput: ps, desktopPIDs: [1914], localHosts: hosts))
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(psOutput: ps, desktopPIDs: [42], localHosts: hosts), "别的进程的 ssh 不算")
        let remoteOnly = ps.split(separator: "\n").filter { !$0.contains("65034") }.joined(separator: "\n")
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(psOutput: remoteOnly, desktopPIDs: [1914], localHosts: hosts), "只连了远端主机")
        XCTAssertTrue(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 9 1914 /usr/bin/ssh -T me@LOCALHOST sh", desktopPIDs: [1914], localHosts: hosts))
    }

    func testCodexDesktopLinkURLRejectsUnsafeIDs() {
        XCTAssertEqual(CodexDesktopLink.url(threadID: "019a-ABCD")?.absoluteString, "codex://threads/019a-ABCD")
        XCTAssertNil(CodexDesktopLink.url(threadID: "a/b?x=1"))
        XCTAssertNil(CodexDesktopLink.url(threadID: ""))
    }

    func testHerdrArgumentsCarryTitleAsData() throws {
        let args = TerminalLauncher.herdrArguments(scriptPath: "/tmp/x.command", cwd: "/repo dir", title: "--argv \"oops\"")
        XCTAssertEqual(Array(args.prefix(2)), ["do", "tab.new"])
        XCTAssertEqual(args.count, 3)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args[2].utf8)) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "--argv \"oops\"")
        XCTAssertEqual(object["folder"] as? String, "/repo dir")
        XCTAssertEqual(object["argv"] as? [String], ["/bin/zsh", "-l", "/tmp/x.command"])
    }
}
