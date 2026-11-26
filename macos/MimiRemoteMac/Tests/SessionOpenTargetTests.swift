import XCTest
@testable import MimiRemoteMac

final class SessionOpenTargetTests: XCTestCase {
    private let allApps: Set<String> = [
        SessionOpenTarget.codexDesktopBundleID,
        TerminalApp.ghostty.bundleID, TerminalApp.herdr.bundleID, TerminalApp.terminal.bundleID,
    ]

    private func session(_ runtime: SessionRuntime, activity: DesktopSession.Activity = .idle,
                         holder: DesktopSession.Holder? = nil, cwd: String = "/repo") -> DesktopSession {
        DesktopSession(threadID: "t1", runtime: runtime, title: "t", projectName: "p", cwd: cwd,
                       updatedAt: nil, activity: activity, holder: holder)
    }

    func testCandidatesListDesktopForCodexAndOnlyInstalledTerminalsForClaude() {
        XCTAssertEqual(
            SessionOpenTarget.candidates(for: .codex, installedBundleIDs: allApps),
            [.codexDesktop, .terminal(.ghostty), .terminal(.herdr), .terminal(.terminal)]
        )
        XCTAssertEqual(
            SessionOpenTarget.candidates(for: .claude, installedBundleIDs: [TerminalApp.terminal.bundleID]),
            [.terminal(.terminal)]
        )
        XCTAssertEqual(
            SessionOpenTarget.candidates(for: .claude, installedBundleIDs: []),
            [.terminal(.terminal)],
            "Claude 至少保底系统终端"
        )
    }

    func testPreferredUsesStoredChoiceWhenStillAvailable() {
        let candidates = SessionOpenTarget.candidates(for: .codex, installedBundleIDs: allApps)
        XCTAssertEqual(SessionOpenTarget.preferred(stored: "terminal.ghostty", candidates: candidates, installedBundleIDs: allApps), .terminal(.ghostty))
        XCTAssertEqual(SessionOpenTarget.preferred(stored: "", candidates: candidates, installedBundleIDs: allApps), .codexDesktop)
        // 记住的是旧版 Claude 桌面版或已卸载的终端时，退回第一个装着的。
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
        for target in [SessionOpenTarget.codexDesktop, .terminal(.ghostty), .terminal(.herdr), .terminal(.terminal)] {
            XCTAssertEqual(SessionOpenTarget(storageValue: target.storageValue), target)
        }
        XCTAssertNil(SessionOpenTarget(storageValue: "desktop.claude"))
        XCTAssertNil(SessionOpenTarget(storageValue: "terminal.unknown"))
    }

    func testUnavailableReasons() {
        XCTAssertNil(SessionOpenTarget.codexDesktop.unavailableReason(for: session(.codex, activity: .running), installedBundleIDs: allApps),
                     "Codex 桌面版不看占用状态，直接打开")
        XCTAssertNotNil(SessionOpenTarget.codexDesktop.unavailableReason(for: session(.codex), installedBundleIDs: []))
        XCTAssertNil(SessionOpenTarget.terminal(.ghostty).unavailableReason(for: session(.claude), installedBundleIDs: allApps))
        XCTAssertEqual(SessionOpenTarget.terminal(.ghostty).unavailableReason(for: session(.claude, activity: .running), installedBundleIDs: allApps),
                       "这一轮结束后才能在终端继续。")
        XCTAssertEqual(SessionOpenTarget.terminal(.ghostty).unavailableReason(for: session(.claude, holder: .claudeTerminal), installedBundleIDs: allApps),
                       "这条会话已经在终端里打开。")
        XCTAssertNotNil(SessionOpenTarget.terminal(.ghostty).unavailableReason(for: session(.codex, cwd: ""), installedBundleIDs: allApps))
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

        // P1-5: 未确认归 Mimi 管理且直连回环时，不得把 mimi-local 当作本机共享连接！
        XCTAssertFalse(CodexDesktopLink.localHosts().contains(CodexLocalSSHConfigurator.hostAlias))
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 12 1914 /usr/bin/ssh -T -v -o BatchMode=yes mimi-local sh -c 'codex app-server proxy'",
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: false)
        ), "未托管或冲突的同名 mimi-local 可能是远端连接，绝不能误判为本机共享")

        XCTAssertTrue(CodexDesktopLink.localHosts(includeManagedAlias: true).contains(CodexLocalSSHConfigurator.hostAlias))
        XCTAssertTrue(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 12 1914 /usr/bin/ssh -T -v -o BatchMode=yes mimi-local sh -c 'codex app-server proxy'",
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true)
        ))

        // 跳板机或远端命令参数里出现 127.0.0.1 不得误判为本机连接。
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 13 1914 /usr/bin/ssh -J 127.0.0.1 remote.example.com sh -c 'echo 127.0.0.1'",
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true)
        ))

        XCTAssertEqual(CodexDesktopLink.sshSettingsURL.absoluteString, "codex://settings/ssh")
        XCTAssertEqual(CodexDesktopLink.connectionsSettingsURL.absoluteString, "codex://settings/connections")
    }

    @MainActor
    func testOpenSSHSettingsHandlesDirectFallbackAndFailureFeedback() async {
        let fakeApp = URL(fileURLWithPath: "/Applications/Codex.app")

        // 1. 未安装
        let notInstalled = await CodexDesktopLink.openSSHSettings(
            preferSSHSubpage: true,
            findApp: { nil },
            openURL: { _, _ in XCTFail("未安装时不应调用 openURL") },
            openApp: { _ in XCTFail("未安装时不应调用 openApp") }
        )
        XCTAssertEqual(notInstalled, .notInstalled)
        XCTAssertTrue(notInstalled.isFailure)
        XCTAssertNotNil(notInstalled.feedbackMessage)

        // 2. 托管别名可用 -> 优先打开 SSH 子页
        var openedURLs: [URL] = []
        let directSSH = await CodexDesktopLink.openSSHSettings(
            preferSSHSubpage: true,
            findApp: { fakeApp },
            openURL: { url, _ in openedURLs.append(url) },
            openApp: { _ in XCTFail("SSH 子页成功时不应回退 openApp") }
        )
        XCTAssertEqual(directSSH, .openedSSHSettings)
        XCTAssertEqual(openedURLs, [CodexDesktopLink.sshSettingsURL])
        XCTAssertNil(directSSH.feedbackMessage)

        // 3. SSH 子页失败 -> 回退通用连接页并返回提示
        openedURLs = []
        let connFallback = await CodexDesktopLink.openSSHSettings(
            preferSSHSubpage: true,
            findApp: { fakeApp },
            openURL: { url, _ in
                openedURLs.append(url)
                if url == CodexDesktopLink.sshSettingsURL {
                    throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported"])
                }
            },
            openApp: { _ in XCTFail("连接页成功时不应回退 openApp") }
        )
        XCTAssertEqual(connFallback, .openedConnectionsFallback)
        XCTAssertEqual(openedURLs, [CodexDesktopLink.sshSettingsURL, CodexDesktopLink.connectionsSettingsURL])
        XCTAssertFalse(connFallback.isFailure)
        XCTAssertNotNil(connFallback.feedbackMessage)

        // 4. 两次深链均失败 -> 回退启动应用并提示用户手动进 SSH 设置
        var openedAppCount = 0
        let appFallback = await CodexDesktopLink.openSSHSettings(
            preferSSHSubpage: true,
            findApp: { fakeApp },
            openURL: { _, _ in
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "url failed"])
            },
            openApp: { _ in openedAppCount += 1 }
        )
        XCTAssertEqual(appFallback, .openedAppFallback)
        XCTAssertEqual(openedAppCount, 1)
        XCTAssertFalse(appFallback.isFailure)
        XCTAssertTrue(appFallback.feedbackMessage?.contains("SSH") == true)

        // 5. 深链和应用启动全失败 -> 明确返回启动失败
        let launchFailed = await CodexDesktopLink.openSSHSettings(
            preferSSHSubpage: false,
            findApp: { fakeApp },
            openURL: { _, _ in
                throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "url failed"])
            },
            openApp: { _ in
                throw NSError(domain: "test", code: 4, userInfo: [NSLocalizedDescriptionKey: "app damaged"])
            }
        )
        XCTAssertEqual(launchFailed, .launchFailed("app damaged"))
        XCTAssertTrue(launchFailed.isFailure)
        XCTAssertTrue(launchFailed.feedbackMessage?.contains("app damaged") == true)
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

final class CodexSharedSetupStatusTests: XCTestCase {
    func testSharedDesktopMarksEveryStepDone() {
        let status = CodexSharedSetupStatus.make(desktop: .shared, remoteLogin: false, passwordless: false)
        XCTAssertTrue(status.allDone, "桌面版已经经本机 SSH 连上，前两步必然已做好")
    }

    func testStepsWithoutDesktopConnection() {
        let off = CodexSharedSetupStatus.make(desktop: .separate, remoteLogin: false, passwordless: true)
        XCTAssertEqual(off.remoteLogin, .todo)
        XCTAssertEqual(off.passwordlessLogin, .todo, "远程登录没开时免密登录不可能成立")
        XCTAssertEqual(off.desktopConnected, .todo)
        XCTAssertFalse(off.desktopNotRunning)

        let ready = CodexSharedSetupStatus.make(desktop: .notRunning, remoteLogin: true, passwordless: true)
        XCTAssertEqual(ready.remoteLogin, .done)
        XCTAssertEqual(ready.passwordlessLogin, .done)
        XCTAssertEqual(ready.desktopConnected, .todo)
        XCTAssertTrue(ready.desktopNotRunning)
        XCTAssertFalse(ready.allDone)
    }

    func testKeySetupCommandIsIdempotentAndNonInteractive() {
        let command = CodexSharedSetupChecks.keySetupCommand
        XCTAssertTrue(command.contains("[ -f ~/.ssh/id_ed25519 ] ||"), "已有钥匙时不覆盖")
        XCTAssertTrue(command.contains("grep -qxF"), "公钥已在 authorized_keys 里时不重复追加")
        XCTAssertTrue(command.contains("BatchMode=yes"), "按桌面版的方式试登，不弹密码")
        XCTAssertFalse(command.contains("sudo"))
    }

    func testP1_5PasswordlessProbeNeverTouchesAliasWhenUnmanagedOrConflicting() async {
        let recorder = ProbeTargetRecorder()
        let unmanaged = await CodexSharedSetupChecks.probePasswordlessLogin(
            managedAliasVerified: false,
            prober: { target in
                await recorder.record(target)
                return false
            }
        )
        XCTAssertFalse(unmanaged.anyWorks)
        let unmanagedTargets = await recorder.targets
        XCTAssertEqual(unmanagedTargets, ["127.0.0.1"], "未托管或冲突时绝不得探测 mimi-local")

        let managedRecorder = ProbeTargetRecorder()
        let managed = await CodexSharedSetupChecks.probePasswordlessLogin(
            managedAliasVerified: true,
            prober: { target in
                await managedRecorder.record(target)
                return target == CodexLocalSSHConfigurator.hostAlias
            }
        )
        XCTAssertTrue(managed.managedAliasWorks)
        XCTAssertFalse(managed.legacyLoopbackWorks)
        let managedTargets = await managedRecorder.targets
        XCTAssertEqual(managedTargets, [CodexLocalSSHConfigurator.hostAlias])
    }

    @MainActor
    func testP1_6CoordinatorSerializesDualEntryAndDiscardsOutOfOrderChecksAndPreservesRemoveError() async {
        // 1. 乱序检查：先发起慢检查（返回旧状态），再发起快检查（返回新状态），慢检查晚到不得覆盖新状态。
        var checkIndex = 0
        var slowContinuation: CheckedContinuation<CodexSharedSetupStatus, Never>?
        let outOfOrderCoordinator = CodexSharedSetupCoordinator(
            checker: {
                checkIndex += 1
                if checkIndex == 1 {
                    return await withCheckedContinuation { cont in
                        slowContinuation = cont
                    }
                }
                return CodexSharedSetupStatus.make(
                    desktop: .separate,
                    remoteLogin: true,
                    passwordless: true,
                    localSSHManaged: true,
                    managedAliasReady: true
                )
            },
            sharedSeenSetter: { _ in }
        )

        let firstTask = Task { await outOfOrderCoordinator.refresh() }
        await Task.yield()
        let secondTask = Task { await outOfOrderCoordinator.refresh() }
        await secondTask.value
        XCTAssertEqual(outOfOrderCoordinator.status.passwordlessLogin, .done)
        XCTAssertTrue(outOfOrderCoordinator.status.managedAliasReady)

        // 让更早发起的慢检查现在才返回过期的 todo 状态。
        slowContinuation?.resume(returning: CodexSharedSetupStatus.make(
            desktop: .separate,
            remoteLogin: false,
            passwordless: false
        ))
        await firstTask.value
        XCTAssertEqual(outOfOrderCoordinator.status.passwordlessLogin, .done, "旧检查结果不得覆盖更新的快照")
        XCTAssertTrue(outOfOrderCoordinator.status.managedAliasReady)

        // 2. 双入口并发触发一键配置 -> 协调器只执行一次，避免菜单窗口和会话弹窗并发写盘。
        let gate = SetupAsyncGate()
        let counter = SetupCallCounter()
        let concurrentCoordinator = CodexSharedSetupCoordinator(
            checker: {
                CodexSharedSetupStatus.make(desktop: .separate, remoteLogin: true, passwordless: true, localSSHManaged: true, managedAliasReady: true)
            },
            configureSSH: {
                await counter.increment()
                await gate.wait()
            },
            sharedSeenSetter: { _ in }
        )

        let entryA = Task { await concurrentCoordinator.runOneClickSSHSetup() }
        await Task.yield()
        let entryB = Task { await concurrentCoordinator.runOneClickSSHSetup() }
        await gate.open()
        await entryA.value
        await entryB.value
        let configureCount = await counter.count
        XCTAssertEqual(configureCount, 1, "共享协调器应拦住双入口并发配置")

        // 3. 撤销失败后，即使检查返回 allDone，也不能把撤销错误清掉。
        let removeErrorCoordinator = CodexSharedSetupCoordinator(
            checker: {
                CodexSharedSetupStatus.make(desktop: .shared, remoteLogin: true, passwordless: true, localSSHManaged: true, managedAliasReady: true)
            },
            removeSSH: {
                throw CodexLocalSSHConfigurator.ConfigError.invalidManagedBlock
            },
            sharedSeenSetter: { _ in }
        )
        await removeErrorCoordinator.runRemoveSSHSetup()
        XCTAssertEqual(
            removeErrorCoordinator.actionError,
            CodexLocalSSHConfigurator.ConfigError.invalidManagedBlock.localizedDescription,
            "撤销错误不能被随后的状态刷新清掉"
        )
    }

    func testP2_3StepAccessibilityLabelIncludesNumberTitleAndState() {
        XCTAssertEqual(
            CodexSharedSetupView.stepAccessibilityLabel(number: 1, title: "打开「远程登录」", state: .checking),
            "第 1 步：打开「远程登录」，检查中"
        )
        XCTAssertEqual(
            CodexSharedSetupView.stepAccessibilityLabel(number: 2, title: "一键配置本机 SSH", state: .todo),
            "第 2 步：一键配置本机 SSH，待完成"
        )
        XCTAssertEqual(
            CodexSharedSetupView.stepAccessibilityLabel(number: 3, title: "在 Codex 桌面版连接本机", state: .done),
            "第 3 步：在 Codex 桌面版连接本机，已完成"
        )
    }
}

private actor ProbeTargetRecorder {
    var targets: [String] = []
    func record(_ target: String) { targets.append(target) }
}

private actor SetupCallCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor SetupAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let list = waiters
        waiters.removeAll()
        for waiter in list {
            waiter.resume()
        }
    }
}
