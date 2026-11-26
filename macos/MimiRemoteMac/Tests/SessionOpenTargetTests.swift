import CryptoKit
import Darwin
import os
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

        // R2 P1-6: 进程参数包含 -F / -o HostName / -o ProxyCommand / -o ProxyJump / -p 非22 / -l 非当前用户 覆盖时必须拒绝。
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 20 1914 /usr/bin/ssh -F /tmp/custom.conf 127.0.0.1 sh",
            desktopPIDs: [1914],
            localHosts: hosts,
            expectedUsername: "alice"
        ), "自定义 -F 可能重定向目标，不得判为本机共享")
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 21 1914 /usr/bin/ssh -o HostName=remote.example.com 127.0.0.1 sh",
            desktopPIDs: [1914],
            localHosts: hosts,
            expectedUsername: "alice"
        ), "-o HostName 重定向到远端不得判为本机共享")
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 22 1914 /usr/bin/ssh -o ProxyCommand=nc 127.0.0.1 sh",
            desktopPIDs: [1914],
            localHosts: hosts,
            expectedUsername: "alice"
        ), "-o ProxyCommand 不得判为本机共享")
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 23 1914 /usr/bin/ssh -o ProxyJump=bastion 127.0.0.1 sh",
            desktopPIDs: [1914],
            localHosts: hosts,
            expectedUsername: "alice"
        ), "-o ProxyJump 不得判为本机共享")
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 24 1914 /usr/bin/ssh -p 2222 127.0.0.1 sh",
            desktopPIDs: [1914],
            localHosts: hosts,
            expectedUsername: "alice"
        ), "非 22 端口（如本地端口转发）不得判为本机共享")
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 25 1914 /usr/bin/ssh -l bob 127.0.0.1 sh",
            desktopPIDs: [1914],
            localHosts: hosts,
            expectedUsername: "alice"
        ), "其他用户不得判为当前用户共享")
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 26 1914 /usr/bin/ssh -o User=bob 127.0.0.1 sh",
            desktopPIDs: [1914],
            localHosts: hosts,
            expectedUsername: "alice"
        ))
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 27 1914 /usr/bin/ssh -Tp 2222 127.0.0.1 sh",
            desktopPIDs: [1914],
            localHosts: hosts,
            expectedUsername: "alice"
        ), "合并短选项 -Tp 2222 必须识别出非 22 端口")
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: " 28 1914 /usr/bin/ssh -Tl bob 127.0.0.1 sh",
            desktopPIDs: [1914],
            localHosts: hosts,
            expectedUsername: "alice"
        ), "合并短选项 -Tl bob 必须识别出非当前用户")

        // R2 P1-6: 结合 lsof 实际已建立 TCP 对端校验，拒绝配置改写前连向远端的 mimi-local 进程。
        let mimiPS = " 30 1914 /usr/bin/ssh -T -v -o BatchMode=yes mimi-local sh -c 'codex app-server proxy'"
        let remotePeerLsof = """
        p30
        n192.168.1.5:54321->198.51.100.10:22
        """
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: mimiPS,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            lsofOutput: remotePeerLsof
        ), "实际 TCP 对端为远端 IP 时，即使当前配置已改写，也不得误报为共享")

        let noSocketLsof = "p30\n"
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: mimiPS,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            lsofOutput: noSocketLsof
        ), "无已建立回环 22 端口连接时不得误报共享")

        let mixedRemoteAndLocalLsof = """
        p30
        n127.0.0.1:50000->127.0.0.1:22
        n192.168.1.5:50001->198.51.100.10:443
        """
        XCTAssertFalse(CodexDesktopLink.hasLocalSSHChild(
            psOutput: mimiPS,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            lsofOutput: mixedRemoteAndLocalLsof
        ))

        let loopbackV4Lsof = """
        p30
        n127.0.0.1:54321->127.0.0.1:22
        """
        XCTAssertTrue(CodexDesktopLink.hasLocalSSHChild(
            psOutput: mimiPS,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            lsofOutput: loopbackV4Lsof
        ))

        let loopbackV6Lsof = """
        p30
        n[::1]:54321->[::1]:22
        """
        XCTAssertTrue(CodexDesktopLink.hasLocalSSHChild(
            psOutput: mimiPS,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            lsofOutput: loopbackV6Lsof
        ))

        // R2 P1-8: 官方 Codex 桌面版 SSH 设置页深链。
        XCTAssertEqual(CodexDesktopLink.sshSettingsURL.absoluteString, "codex://settings/connections/ssh")
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
        XCTAssertFalse(directSSH.isFailure)
        XCTAssertTrue(directSSH.feedbackMessage?.contains("发送") == true, "成功交付 URL 时应准确反馈为已发送并提示连接页回退")
        XCTAssertTrue(directSSH.feedbackMessage?.contains("打开连接设置") == true)

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

    func testR2_P1_6DirectLoopbackProbeRestrictsTargetAndRejectsRedirection() {
        let bareArgs = CodexSharedSetupChecks.buildDirectLoopbackProbeArguments(
            for: "127.0.0.1",
            username: "alice",
            configPath: "/tmp/verified-desktop.conf"
        )
        XCTAssertEqual(Array(bareArgs.prefix(2)), ["-F", "/tmp/verified-desktop.conf"], "自动探测必须绑定到已核验的桌面配置快照，不得改用 -F /dev/null 验另一套身份")
        XCTAssertTrue(bareArgs.contains("-T"))
        XCTAssertTrue(bareArgs.contains("HostName=127.0.0.1"))
        XCTAssertTrue(bareArgs.contains("Port=22"))
        XCTAssertTrue(bareArgs.contains("User=alice"))
        XCTAssertTrue(bareArgs.contains("ProxyJump=none"))
        XCTAssertTrue(bareArgs.contains("ProxyCommand=none"))
        XCTAssertTrue(bareArgs.contains("ControlMaster=no"))
        XCTAssertTrue(bareArgs.contains("ControlPath=none"))
        XCTAssertTrue(bareArgs.contains("ClearAllForwardings=yes"))
        XCTAssertTrue(bareArgs.contains("StrictHostKeyChecking=yes"), "自动探测必须只读，不得自动写入 known_hosts")
        XCTAssertTrue(bareArgs.contains("UpdateHostKeys=no"), "自动探测必须禁用 UpdateHostKeys，防止认证后写回用户 known_hosts")
        XCTAssertTrue(bareArgs.contains("BatchMode=yes"))
        XCTAssertEqual(bareArgs.last, "/bin/cat", "自动探测应验证双向输入输出而非仅执行 true")

        let redirected = CodexLocalSSHConfigurator.EffectiveSSHConfig(
            hostname: "remote.example.com",
            port: "22",
            user: "alice"
        )
        XCTAssertFalse(CodexLocalSSHConfigurator.isDirectLoopbackConfig(redirected, expectedUser: "alice"))

        let proxied = CodexLocalSSHConfigurator.EffectiveSSHConfig(
            hostname: "127.0.0.1",
            port: "22",
            user: "alice",
            proxyJump: "bastion.example.com"
        )
        XCTAssertFalse(CodexLocalSSHConfigurator.isDirectLoopbackConfig(proxied, expectedUser: "alice"))

        let wrongUser = CodexLocalSSHConfigurator.EffectiveSSHConfig(
            hostname: "127.0.0.1",
            port: "22",
            user: "bob"
        )
        XCTAssertFalse(CodexLocalSSHConfigurator.isDirectLoopbackConfig(wrongUser, expectedUser: "alice"))

        let pubkeyDisabled = CodexLocalSSHConfigurator.EffectiveSSHConfig(
            hostname: "127.0.0.1",
            port: "22",
            user: "alice",
            pubkeyAuthentication: "no"
        )
        XCTAssertFalse(CodexLocalSSHConfigurator.isDirectLoopbackConfig(pubkeyDisabled, expectedUser: "alice"))

        let stdinNullEnabled = CodexLocalSSHConfigurator.EffectiveSSHConfig(
            hostname: "127.0.0.1",
            port: "22",
            user: "alice",
            stdinNull: "yes"
        )
        XCTAssertFalse(CodexLocalSSHConfigurator.isDirectLoopbackConfig(stdinNullEnabled, expectedUser: "alice"))

        let forceTTY = CodexLocalSSHConfigurator.EffectiveSSHConfig(
            hostname: "127.0.0.1",
            port: "22",
            user: "alice",
            requestTTY: "force"
        )
        XCTAssertFalse(CodexLocalSSHConfigurator.isDirectLoopbackConfig(forceTTY, expectedUser: "alice"))

        let noSession = CodexLocalSSHConfigurator.EffectiveSSHConfig(
            hostname: "127.0.0.1",
            port: "22",
            user: "alice",
            sessionType: "none"
        )
        XCTAssertFalse(CodexLocalSSHConfigurator.isDirectLoopbackConfig(noSession, expectedUser: "alice"))

        let forkAfterAuth = CodexLocalSSHConfigurator.EffectiveSSHConfig(
            hostname: "127.0.0.1",
            port: "22",
            user: "alice",
            forkAfterAuthentication: "yes"
        )
        XCTAssertFalse(CodexLocalSSHConfigurator.isDirectLoopbackConfig(forkAfterAuth, expectedUser: "alice"))

        let directLoopback = CodexLocalSSHConfigurator.EffectiveSSHConfig(
            hostname: "127.0.0.1",
            port: "22",
            user: "alice",
            pubkeyAuthentication: "true",
            proxyJump: "none",
            proxyCommand: "none",
            controlMaster: "false",
            controlPath: "none",
            stdinNull: "no",
            requestTTY: "auto",
            sessionType: "default",
            forkAfterAuthentication: "no"
        )
        XCTAssertTrue(CodexLocalSSHConfigurator.isDirectLoopbackConfig(directLoopback, expectedUser: "alice"))
    }

    func testR3_P1_5LoopbackTCPAloneIsNotSharedRequiresAuthenticatedCurrentUserSharedBackendEvidence() {
        let socketPath = "/Users/alice/.codex/app-server-control/app-server-control.sock"
        let sharedSockets: Set<String> = [socketPath]
        let tcpLsof = """
        p30
        n127.0.0.1:54321->127.0.0.1:22
        """
        let psBase = """
          1914     1   501 /Applications/Codex.app/Contents/MacOS/Codex
            30  1914   501 /usr/bin/ssh -T -o BatchMode=yes mimi-local sh -c 'codex app-server proxy'
           500     1     0 /usr/sbin/sshd
           501   500   501 sshd-session: alice@notty
           502   501   501 /bin/zsh -c exec codex app-server proxy
           503   502   501 /opt/homebrew/bin/codex app-server proxy
           600     1   501 /Applications/Terminal.app/Contents/MacOS/Terminal
           601   600   501 /opt/homebrew/bin/codex app-server proxy
           700   500   502 sshd-session: bob@notty
           701   700   502 /opt/homebrew/bin/codex app-server proxy
        """

        func makeUnixLsof(_ entries: [(pid: Int32, cmd: String, fd: String, addr: String, name: String)]) -> Data {
            var data = Data()
            for entry in entries {
                for field in ["p\(entry.pid)", "c\(entry.cmd)", "f\(entry.fd)", "tunix", "d\(entry.addr)", "n\(entry.name)"] {
                    data.append(contentsOf: field.utf8)
                    data.append(0)
                }
                data.append(0x0A)
            }
            return data
        }

        // 1. 仅有回环 TCP ESTABLISHED（认证未完成或共享后端未接入）-> 绝不能标为 .shared。
        XCTAssertFalse(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psBase,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: 501,
            tcpLsofOutput: tcpLsof,
            unixLsofOutput: Data(),
            sharedSocketPaths: sharedSockets
        ), "仅建立回环 TCP 连接但尚无共享后端连接证据时不得标为已共享")

        // 2. 只有本地终端里的 codex 接了共享 socket（非 sshd 后代）-> 不能把未认证完的桌面版 SSH 标为 .shared。
        let terminalOnlyUnix = makeUnixLsof([
            (pid: 900, cmd: "agentd", fd: "5", addr: "0x1111", name: socketPath),
            (pid: 601, cmd: "codex", fd: "7", addr: "0x2222", name: "->0x1111"),
        ])
        XCTAssertFalse(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psBase,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: 501,
            tcpLsofOutput: tcpLsof,
            unixLsofOutput: terminalOnlyUnix,
            sharedSocketPaths: sharedSockets
        ), "非 sshd 拉起的本地终端 codex 连接不得误证桌面版 SSH 已接入共享后端")

        // 3. 其他账号（UID 502）经 sshd 接入 -> 属于他人账号，不得标为当前账号已共享。
        let otherUserUnix = makeUnixLsof([
            (pid: 900, cmd: "agentd", fd: "5", addr: "0x1111", name: socketPath),
            (pid: 701, cmd: "codex", fd: "7", addr: "0x3333", name: "->0x1111"),
        ])
        XCTAssertFalse(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psBase,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: 501,
            tcpLsofOutput: tcpLsof,
            unixLsofOutput: otherUserUnix,
            sharedSocketPaths: sharedSockets
        ), "其他账号的 sshd 会话不得标为当前账号已共享")

        // 4. 当前账号（UID 501）经同一 TCP 四元组的已认证 sshd-session 拉起的 codex 连接到共享控制 socket -> 满足完整共享证据。
        let matchedTcpLsof = """
        p30
        n127.0.0.1:54321->127.0.0.1:22
        p501
        n127.0.0.1:22->127.0.0.1:54321
        """
        let verifiedUnix = makeUnixLsof([
            (pid: 900, cmd: "agentd", fd: "5", addr: "0x1111", name: socketPath),
            (pid: 503, cmd: "codex-aarch64-apple-darwin", fd: "8", addr: "0x4444", name: "->0x1111"),
        ])
        XCTAssertTrue(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psBase,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: 501,
            tcpLsofOutput: matchedTcpLsof,
            unixLsofOutput: verifiedUnix,
            sharedSocketPaths: sharedSockets
        ))
    }

    /// R4 P1-5: 两条独立 SSH 会话并存时（桌面端回环 TCP 仍在认证 + 同账号另一条 SSH 会话已连共享 Codex socket），
    /// 必须用同一 TCP 四元组关联桌面 ssh、服务端 sshd 与 Codex 后代，绝不能把两条无关会话拼出 .shared。
    func testR4_P1_5TwoIndependentSSHSessionsDoNotCombineIntoSharedRequiresMatchingTCPFourTuple() {
        let socketPath = "/Users/alice/.codex/app-server-control/app-server-control.sock"
        let sharedSockets: Set<String> = [socketPath]
        let psTwoSessions = """
          1914     1   501 /Applications/Codex.app/Contents/MacOS/Codex
            30  1914   501 /usr/bin/ssh -T -o BatchMode=yes mimi-local sh -c 'codex app-server proxy'
            40   600   501 /usr/bin/ssh -T 127.0.0.1 sh -c 'codex app-server proxy'
           500     1     0 /usr/sbin/sshd
           501   500   501 sshd-session: alice@notty
           502   501   501 /bin/zsh -c exec codex app-server proxy
           503   502   501 /opt/homebrew/bin/codex app-server proxy
           510   500   501 sshd-session: alice@notty
           600     1   501 /Applications/Terminal.app/Contents/MacOS/Terminal
        """

        func makeUnixLsof(_ entries: [(pid: Int32, cmd: String, fd: String, addr: String, name: String)]) -> Data {
            var data = Data()
            for entry in entries {
                for field in ["p\(entry.pid)", "c\(entry.cmd)", "f\(entry.fd)", "tunix", "d\(entry.addr)", "n\(entry.name)"] {
                    data.append(contentsOf: field.utf8)
                    data.append(0)
                }
                data.append(0x0A)
            }
            return data
        }

        let codexConnectedUnix = makeUnixLsof([
            (pid: 900, cmd: "agentd", fd: "5", addr: "0x1111", name: socketPath),
            (pid: 503, cmd: "codex-aarch64-apple-darwin", fd: "8", addr: "0x4444", name: "->0x1111"),
        ])

        // 负例：桌面 ssh (30) 用源端口 54321，但带 codex 后代的 sshd-session (501) 对应的是另一条终端 ssh (40) 的源端口 59999。
        let mismatchedSessionsTCP = """
        p30
        n127.0.0.1:54321->127.0.0.1:22
        p510
        n127.0.0.1:22->127.0.0.1:54321
        p40
        n127.0.0.1:59999->127.0.0.1:22
        p501
        n127.0.0.1:22->127.0.0.1:59999
        """
        XCTAssertFalse(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psTwoSessions,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: 501,
            tcpLsofOutput: mismatchedSessionsTCP,
            unixLsofOutput: codexConnectedUnix,
            sharedSocketPaths: sharedSockets
        ), "两条独立 SSH 会话并存时，绝不能把桌面未认证 TCP 与另一条 SSH 会话的 Codex socket 拼出 .shared")

        // 正例：带 codex 后代的 sshd-session (501) 持有与桌面 ssh (30) 完全镜像的 TCP 四元组 (127.0.0.1:22->127.0.0.1:54321)。
        let matchedSessionTCP = """
        p30
        n127.0.0.1:54321->127.0.0.1:22
        p501
        n127.0.0.1:22->127.0.0.1:54321
        """
        XCTAssertTrue(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psTwoSessions,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: 501,
            tcpLsofOutput: matchedSessionTCP,
            unixLsofOutput: codexConnectedUnix,
            sharedSocketPaths: sharedSockets
        ), "同一 TCP 四元组串联桌面 ssh、sshd-session 与共享 Codex socket 时应判为 .shared")

        // IPv6 回环四元组同样校验精确匹配，不同源端口仍拒绝。
        let ipv6MismatchedTCP = """
        p30
        n[::1]:54321->[::1]:22
        p501
        n[::1]:22->[::1]:59999
        """
        XCTAssertFalse(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psTwoSessions,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: 501,
            tcpLsofOutput: ipv6MismatchedTCP,
            unixLsofOutput: codexConnectedUnix,
            sharedSocketPaths: sharedSockets
        ))

        let ipv6MatchedTCP = """
        p30
        n[::1]:54321->[::1]:22
        p501
        n[::1]:22->[::1]:54321
        """
        XCTAssertTrue(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psTwoSessions,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: 501,
            tcpLsofOutput: ipv6MatchedTCP,
            unixLsofOutput: codexConnectedUnix,
            sharedSocketPaths: sharedSockets
        ))
    }

    @MainActor
    func testP1_6CoordinatorSerializesDualEntryAndDiscardsOutOfOrderChecksAndPreservesRemoveError() async {
        // 1. 乱序检查（确定性信号调度）：显式等待第一个慢检查进入挂起点后再发起第二个快检查。
        var checkIndex = 0
        var slowContinuation: CheckedContinuation<CodexSharedSetupStatus, Never>?
        let firstEnteredSlowBranch = SetupAsyncGate()
        let outOfOrderCoordinator = CodexSharedSetupCoordinator(
            checker: {
                checkIndex += 1
                if checkIndex == 1 {
                    return await withCheckedContinuation { cont in
                        slowContinuation = cont
                        Task { await firstEnteredSlowBranch.open() }
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
        await firstEnteredSlowBranch.wait()
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

        // 2. 双入口并发触发一键配置（确定性信号调度）：等入口 A 确已进入配置且被阻塞后，再触发入口 B 并等入口 B 返回，最后释放入口 A。
        let entryAEntered = SetupAsyncGate()
        let releaseEntryA = SetupAsyncGate()
        let counter = SetupCallCounter()
        let concurrentCoordinator = CodexSharedSetupCoordinator(
            checker: {
                CodexSharedSetupStatus.make(desktop: .separate, remoteLogin: true, passwordless: true, localSSHManaged: true, managedAliasReady: true)
            },
            configureSSH: {
                let callNumber = await counter.increment()
                // 仅阻塞第一次调用：若序列化回归让入口 B 意外进入，重复调用会立即返回并确定性触发计数断言，而不会死锁到超时。
                if callNumber == 1 {
                    await entryAEntered.open()
                    await releaseEntryA.wait()
                }
            },
            sharedSeenSetter: { _ in }
        )

        let entryA = Task { await concurrentCoordinator.runOneClickSSHSetup() }
        await entryAEntered.wait()
        // 入口 A 仍被 releaseEntryA 阻塞时，入口 B 必须被协调器直接拦截并立即返回。
        let entryB = Task { await concurrentCoordinator.runOneClickSSHSetup() }
        await entryB.value
        let countWhileABlocked = await counter.count
        XCTAssertEqual(countWhileABlocked, 1, "入口 A 进行中时，入口 B 必须被拦截而不得重复触发配置")

        await releaseEntryA.open()
        await entryA.value
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

    // MARK: - Final Round P1-5: Match Shared Session Against agentd Effective Transport & Public Socket

    func testFinal_P1_5SharedSessionDetectionMatchesAgentdEffectiveTransportAndPublicSocket() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-agentd-sock-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fakeHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        let customCodexHome = tempRoot.appendingPathComponent("custom-codex", isDirectory: true)
        let guiCodexHome = tempRoot.appendingPathComponent("gui-codex", isDirectory: true)
        let configDir = fakeHome.appendingPathComponent("Library/Application Support/mimi-remote", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: guiCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let configURL = configDir.appendingPathComponent("config.json")
        let currentUID = Darwin.geteuid()

        func makeUnixLsof(_ entries: [(pid: Int32, cmd: String, fd: String, addr: String, name: String)]) -> Data {
            var data = Data()
            for entry in entries {
                for field in ["p\(entry.pid)", "c\(entry.cmd)", "f\(entry.fd)", "tunix", "d\(entry.addr)", "n\(entry.name)"] {
                    data.append(contentsOf: field.utf8)
                    data.append(0)
                }
                data.append(0x0A)
            }
            return data
        }

        // 1. agentd 配置了自定义 CODEX_HOME 且 transport=local，同时 GUI 环境变量有另一个 CODEX_HOME：
        //    只匹配 agentd 的自定义公共 socket，绝不回退或放行默认 ~/.codex 或 GUI 的 CODEX_HOME！
        let customCfg = """
        {
          "app_server": { "transport": "local" },
          "codex": { "enabled": true, "env": { "CODEX_HOME": "\(customCodexHome.path)" } }
        }
        """
        try customCfg.write(to: configURL, atomically: true, encoding: .utf8)

        let sockets = CodexDesktopLink.sharedCodexControlSocketPaths(
            homeDirectory: fakeHome,
            environment: ["CODEX_HOME": guiCodexHome.path],
            expectedUID: currentUID
        )
        let customSock = customCodexHome.appendingPathComponent("app-server-control/app-server-control.sock").standardizedFileURL.path
        let defaultSock = fakeHome.appendingPathComponent(".codex/app-server-control/app-server-control.sock").standardizedFileURL.path
        let guiSock = guiCodexHome.appendingPathComponent("app-server-control/app-server-control.sock").standardizedFileURL.path
        XCTAssertTrue(sockets.contains(customSock), "必须包含 agentd 实际配置的 CODEX_HOME 公共 socket")
        XCTAssertFalse(sockets.contains(defaultSock), "agentd 配置自定义 CODEX_HOME 时绝不得额外接受默认 ~/.codex socket")
        XCTAssertFalse(sockets.contains(guiSock), "绝不得采用 GUI 进程的 CODEX_HOME")

        let psOutput = """
          1914     1   \(currentUID) /Applications/Codex.app/Contents/MacOS/Codex
            30  1914   \(currentUID) /usr/bin/ssh -T -o BatchMode=yes mimi-local sh -c 'codex app-server proxy'
           500     1     0 /usr/sbin/sshd
           501   500   \(currentUID) sshd-session: alice@notty
           502   501   \(currentUID) /opt/homebrew/bin/codex app-server proxy
        """
        let matchedTCP = """
        p30
        n127.0.0.1:54321->127.0.0.1:22
        p501
        n127.0.0.1:22->127.0.0.1:54321
        """
        // 连接到默认 ~/.codex（与 agentd 不同后端）-> 必须判为 false！
        let defaultBackendUnix = makeUnixLsof([
            (pid: 900, cmd: "codex", fd: "5", addr: "0x1111", name: defaultSock),
            (pid: 502, cmd: "codex", fd: "8", addr: "0x2222", name: "->0x1111"),
        ])
        XCTAssertFalse(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psOutput,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: currentUID,
            tcpLsofOutput: matchedTCP,
            unixLsofOutput: defaultBackendUnix,
            sharedSocketPaths: sockets
        ), "桌面 SSH 连到默认 ~/.codex 而 agentd 使用自定义 CODEX_HOME 时不得误判为共享")

        // 连接到 agentd 实际配置的自定义 CODEX_HOME socket -> 必须判为 true！
        let customBackendUnix = makeUnixLsof([
            (pid: 900, cmd: "agentd", fd: "5", addr: "0x1111", name: customSock),
            (pid: 502, cmd: "codex", fd: "8", addr: "0x2222", name: "->0x1111"),
        ])
        XCTAssertTrue(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psOutput,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: currentUID,
            tcpLsofOutput: matchedTCP,
            unixLsofOutput: customBackendUnix,
            sharedSocketPaths: sockets
        ), "桌面 SSH 连接到 agentd 实际公共 socket 时应判为共享")

        // 2. agentd 使用 ssh transport、省略 transport 或配置文件缺失时均不共享本机 socket（与 agentd 默认 ssh 对齐）-> 返回空集合！
        try #"{"app_server":{"transport":"ssh","ssh_target":"remote-box"},"codex":{"enabled":true}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(CodexDesktopLink.sharedCodexControlSocketPaths(
            homeDirectory: fakeHome,
            environment: [:],
            expectedUID: currentUID
        ).isEmpty, "agentd 使用 ssh transport 时不得匹配任何本机 socket")

        try #"{"codex":{"enabled":true}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(CodexDesktopLink.sharedCodexControlSocketPaths(
            homeDirectory: fakeHome,
            environment: [:],
            expectedUID: currentUID
        ).isEmpty, "省略 app_server.transport 时应与 agentd 一致默认 ssh，不得误判为 local 共享")

        let missingConfigHome = tempRoot.appendingPathComponent("missing-config-home", isDirectory: true)
        try FileManager.default.createDirectory(at: missingConfigHome, withIntermediateDirectories: true)
        XCTAssertTrue(CodexDesktopLink.sharedCodexControlSocketPaths(
            homeDirectory: missingConfigHome,
            environment: [:],
            expectedUID: currentUID
        ).isEmpty, "配置文件缺失时应默认 ssh，不得误判为 local 共享")

        // 3. agentd 禁用 codex 或配置文件损坏时 fail-closed 返回空集合！
        try #"{"app_server":{"transport":"local"},"codex":{"enabled":false}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(CodexDesktopLink.sharedCodexControlSocketPaths(
            homeDirectory: fakeHome,
            environment: [:],
            expectedUID: currentUID
        ).isEmpty)

        try "{invalid json".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(CodexDesktopLink.sharedCodexControlSocketPaths(
            homeDirectory: fakeHome,
            environment: [:],
            expectedUID: currentUID
        ).isEmpty, "agentd 配置损坏时不得回退到默认 ~/.codex")

        // 4. 运行中 agentd serve 带显式 --config 参数（含带空格的目录与可执行文件路径）时优先读取该配置文件。
        let spacedConfigDir = tempRoot.appendingPathComponent("My Config Dir", isDirectory: true)
        try FileManager.default.createDirectory(at: spacedConfigDir, withIntermediateDirectories: true)
        let altConfigURL = spacedConfigDir.appendingPathComponent("alt agentd.json")
        try customCfg.write(to: altConfigURL, atomically: true, encoding: .utf8)
        let psWithAltAgentd = CodexDesktopLink.parseProcessesWithUID(psOutput: """
          888     1   \(currentUID) /Applications/Mimi Remote.app/Contents/Resources/agentd serve --config \(altConfigURL.path) --listen 127.0.0.1:8787
        """)
        let altSockets = CodexDesktopLink.sharedCodexControlSocketPaths(
            homeDirectory: fakeHome,
            environment: [:],
            expectedUID: currentUID,
            processes: psWithAltAgentd
        )
        XCTAssertTrue(altSockets.contains(customSock), "含空格的 --config 路径必须完整保留并命中自定义 CODEX_HOME")
        XCTAssertFalse(altSockets.contains(defaultSock))

        // 5. 显式配置 app_server.shared_codex_home（私有后端目录）时，公共控制 socket 仍与前门一致按 codex.env.CODEX_HOME（缺失时 ~/.codex）定位。
        let sharedHomeDir = tempRoot.appendingPathComponent("shared-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedHomeDir, withIntermediateDirectories: true)
        let privateBackendControlSock = sharedHomeDir
            .appendingPathComponent("app-server-control/app-server-control.sock")
            .standardizedFileURL.path

        let sharedHomeCfg = """
        {
          "app_server": { "transport": "local", "shared_codex_home": "\(sharedHomeDir.path)" },
          "codex": { "enabled": true, "env": { "CODEX_HOME": "\(customCodexHome.path)" } }
        }
        """
        try sharedHomeCfg.write(to: configURL, atomically: true, encoding: .utf8)
        let sharedHomeSockets = CodexDesktopLink.sharedCodexControlSocketPaths(
            homeDirectory: fakeHome,
            environment: [:],
            expectedUID: currentUID
        )
        XCTAssertTrue(sharedHomeSockets.contains(customSock), "设置 shared_codex_home 时公共控制 socket 仍应按 codex.env.CODEX_HOME 解析")
        XCTAssertFalse(sharedHomeSockets.contains(privateBackendControlSock), "不得把私有后端 shared_codex_home 当成公共控制 socket 目录")
        XCTAssertTrue(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psOutput,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: currentUID,
            tcpLsofOutput: matchedTCP,
            unixLsofOutput: customBackendUnix,
            sharedSocketPaths: sharedHomeSockets
        ), "设置 shared_codex_home 时连接到前门公共控制 socket 的桌面连接必须正确识别为共享")

        // 5b. 仅配置 app_server.shared_codex_home 且未覆写 codex.env.CODEX_HOME 时，公共控制 socket 回退到默认 ~/.codex。
        let sharedHomeDefaultPublicCfg = """
        {
          "app_server": { "transport": "local", "shared_codex_home": "\(sharedHomeDir.path)" },
          "codex": { "enabled": true }
        }
        """
        try sharedHomeDefaultPublicCfg.write(to: configURL, atomically: true, encoding: .utf8)
        let defaultPublicSockets = CodexDesktopLink.sharedCodexControlSocketPaths(
            homeDirectory: fakeHome,
            environment: [:],
            expectedUID: currentUID
        )
        XCTAssertTrue(defaultPublicSockets.contains(defaultSock), "未覆写 codex.env.CODEX_HOME 时公共控制 socket 应回退到 ~/.codex")
        XCTAssertFalse(defaultPublicSockets.contains(privateBackendControlSock))
        XCTAssertTrue(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psOutput,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
            expectedUsername: "alice",
            expectedUID: currentUID,
            tcpLsofOutput: matchedTCP,
            unixLsofOutput: defaultBackendUnix,
            sharedSocketPaths: defaultPublicSockets
        ))
    }

    // MARK: - Final Round P1-6: Active Connection Check Accepts localhost

    func testFinal_P1_6ActiveConnectionCheckAcceptsLocalhostWhileKeepingLoopbackAndCorrelationGuards() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-localhost-active-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let configurator = CodexLocalSSHConfigurator(
            homeDirectory: tempHome,
            username: "alice",
            systemSSHConfigPath: nil
        )
        try "Host localhost\n    User alice\n".write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)

        // 1. 真实 `ssh -G localhost` 报告 `hostname localhost`：活动连接检查接受 localhost，而只读探测默认 numeric-only 保持不变。
        let effective = try await configurator.resolveEffectiveSSHConfig(
            configPath: configurator.sshConfigURL.path,
            alias: "localhost",
            includeSystemConfig: true
        )
        XCTAssertEqual(effective.hostname?.lowercased(), "localhost")
        XCTAssertTrue(
            CodexDesktopLink.isDirectActiveLoopbackConfig(effective, expectedUser: "alice"),
            "活动连接检查必须接受 ssh -G 报告的 hostname localhost"
        )
        XCTAssertFalse(
            CodexLocalSSHConfigurator.isDirectLoopbackConfig(effective, expectedUser: "alice"),
            "非活动探测默认仍仅接受数字回环地址"
        )

        // 2. 被重定向到远端主机或 ProxyJump 的 localhost 仍被拒绝！
        try "Host localhost\n    HostName remote.example.com\n    User alice\n"
            .write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)
        let redirected = try await configurator.resolveEffectiveSSHConfig(
            configPath: configurator.sshConfigURL.path,
            alias: "localhost",
            includeSystemConfig: true
        )
        XCTAssertFalse(CodexDesktopLink.isDirectActiveLoopbackConfig(redirected, expectedUser: "alice"))

        // 3. 完整活动连接链路：ssh localhost 仍要求本机回环 TCP 22 与服务端 sshd + 共享后端四元组关联！
        let socketPath = "/Users/alice/.codex/app-server-control/app-server-control.sock"
        let sharedSockets: Set<String> = [socketPath]
        let psLocalhost = """
          1914     1   501 /Applications/Codex.app/Contents/MacOS/Codex
            30  1914   501 /usr/bin/ssh -T -o BatchMode=yes localhost sh -c 'codex app-server proxy'
           500     1     0 /usr/sbin/sshd
           501   500   501 sshd-session: alice@notty
           502   501   501 /opt/homebrew/bin/codex app-server proxy
        """
        var unixLsof = Data()
        for entry in [
            (pid: Int32(900), cmd: "agentd", fd: "5", addr: "0x1111", name: socketPath),
            (pid: Int32(502), cmd: "codex", fd: "8", addr: "0x2222", name: "->0x1111"),
        ] {
            for field in ["p\(entry.pid)", "c\(entry.cmd)", "f\(entry.fd)", "tunix", "d\(entry.addr)", "n\(entry.name)"] {
                unixLsof.append(contentsOf: field.utf8)
                unixLsof.append(0)
            }
            unixLsof.append(0x0A)
        }

        // 远端 TCP 对端 -> 拒绝
        let remoteTCP = """
        p30
        n10.0.0.2:54321->198.51.100.10:22
        p501
        n127.0.0.1:22->127.0.0.1:54321
        """
        XCTAssertFalse(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psLocalhost,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: false),
            expectedUsername: "alice",
            expectedUID: 501,
            tcpLsofOutput: remoteTCP,
            unixLsofOutput: unixLsof,
            sharedSocketPaths: sharedSockets
        ))

        // 缺少后端关联 -> 拒绝
        let loopbackTCP = """
        p30
        n127.0.0.1:54321->127.0.0.1:22
        p501
        n127.0.0.1:22->127.0.0.1:54321
        """
        XCTAssertFalse(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psLocalhost,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: false),
            expectedUsername: "alice",
            expectedUID: 501,
            tcpLsofOutput: loopbackTCP,
            unixLsofOutput: Data(),
            sharedSocketPaths: sharedSockets
        ))

        // 回环 TCP + 镜像四元组 + 共享后端关联 -> 通过
        XCTAssertTrue(CodexDesktopLink.hasVerifiedSharedConnection(
            psWithUIDOutput: psLocalhost,
            desktopPIDs: [1914],
            localHosts: CodexDesktopLink.localHosts(includeManagedAlias: false),
            expectedUsername: "alice",
            expectedUID: 501,
            tcpLsofOutput: loopbackTCP,
            unixLsofOutput: unixLsof,
            sharedSocketPaths: sharedSockets
        ))
    }

    // MARK: - Scope 3 P1-5: Validate shared_codex_home Like agentd & Confirm Managed Front-Door Listener

    func testScope3_P1_5SharedCodexHomeValidationAndManagedFrontDoorListenerEnforcement() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-scope3-p1-5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fakeHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        let defaultPublicHome = fakeHome.appendingPathComponent(".codex", isDirectory: true)
        let customPublicHome = tempRoot.appendingPathComponent("public-codex", isDirectory: true)
        let validPrivateHome = tempRoot.appendingPathComponent("private-backend", isDirectory: true)
        let otherPrivateHome = tempRoot.appendingPathComponent("other-backend", isDirectory: true)
        let nestedInsidePublic = customPublicHome.appendingPathComponent("nested-backend", isDirectory: true)
        let parentWrappingPublic = tempRoot.appendingPathComponent("parent-wrap", isDirectory: true)
        let publicInsideParent = parentWrappingPublic.appendingPathComponent("public-child", isDirectory: true)
        let symlinkToPublic = tempRoot.appendingPathComponent("symlink-to-public", isDirectory: false)
        let regularFileNotDir = tempRoot.appendingPathComponent("not-a-dir", isDirectory: false)
        let missingDir = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        let configDir = fakeHome.appendingPathComponent("Library/Application Support/mimi-remote", isDirectory: true)
        let launchAgentsDir = fakeHome.appendingPathComponent("Library/LaunchAgents", isDirectory: true)

        for dir in [defaultPublicHome, customPublicHome, validPrivateHome, otherPrivateHome, nestedInsidePublic, publicInsideParent, configDir, launchAgentsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("not-dir".utf8).write(to: regularFileNotDir)
        try FileManager.default.createSymbolicLink(at: symlinkToPublic, withDestinationURL: customPublicHome)

        let configURL = configDir.appendingPathComponent("config.json")
        let plistURL = launchAgentsDir.appendingPathComponent("com.gaixianggeng.mimi.mac.codex-front.plist")
        let currentUID = Darwin.geteuid()

        func makeUnixLsof(_ entries: [(pid: Int32, cmd: String, fd: String, addr: String, name: String)]) -> Data {
            var data = Data()
            for entry in entries {
                for field in ["p\(entry.pid)", "c\(entry.cmd)", "f\(entry.fd)", "tunix", "d\(entry.addr)", "n\(entry.name)"] {
                    data.append(contentsOf: field.utf8)
                    data.append(0)
                }
                data.append(0x0A)
            }
            return data
        }

        let customPublicSock = customPublicHome
            .appendingPathComponent("app-server-control/app-server-control.sock")
            .standardizedFileURL.path
        let matchedTCP = """
        p30
        n127.0.0.1:54321->127.0.0.1:22
        p501
        n127.0.0.1:22->127.0.0.1:54321
        """
        let psStandaloneOnly = """
          1914     1   \(currentUID) /Applications/Codex.app/Contents/MacOS/Codex
            30  1914   \(currentUID) /usr/bin/ssh -T -o BatchMode=yes mimi-local sh -c 'codex app-server proxy'
           500     1     0 /usr/sbin/sshd
           501   500   \(currentUID) sshd-session: alice@notty
           502   501   \(currentUID) /opt/homebrew/bin/codex app-server proxy
           900     1   \(currentUID) /opt/homebrew/bin/codex app-server --listen unix://\(customPublicSock)
        """
        let standaloneListenerUnix = makeUnixLsof([
            (pid: 900, cmd: "codex", fd: "5", addr: "0x1111", name: customPublicSock),
            (pid: 502, cmd: "codex", fd: "8", addr: "0x2222", name: "->0x1111"),
        ])

        // 1. shared_codex_home 缺失、非目录、或与公共 CODEX_HOME 重叠（相同/子目录/父目录/符号链接）时，
        //    agentd 会拒绝该后端；向导必须返回 nil / 空集合并判为非共享，绝不得把独立 listener 误报为 shared！
        let invalidConfigs: [(label: String, json: String)] = [
            (
                "missing shared_codex_home",
                #"{"app_server":{"transport":"local","shared_codex_home":"\#(missingDir.path)"},"codex":{"enabled":true,"env":{"CODEX_HOME":"\#(customPublicHome.path)"}}}"#
            ),
            (
                "shared_codex_home is regular file",
                #"{"app_server":{"transport":"local","shared_codex_home":"\#(regularFileNotDir.path)"},"codex":{"enabled":true,"env":{"CODEX_HOME":"\#(customPublicHome.path)"}}}"#
            ),
            (
                "shared_codex_home equals explicit CODEX_HOME",
                #"{"app_server":{"transport":"local","shared_codex_home":"\#(customPublicHome.path)"},"codex":{"enabled":true,"env":{"CODEX_HOME":"\#(customPublicHome.path)"}}}"#
            ),
            (
                "shared_codex_home equals default ~/.codex",
                #"{"app_server":{"transport":"local","shared_codex_home":"\#(defaultPublicHome.path)"},"codex":{"enabled":true}}"#
            ),
            (
                "shared_codex_home nested inside CODEX_HOME",
                #"{"app_server":{"transport":"local","shared_codex_home":"\#(nestedInsidePublic.path)"},"codex":{"enabled":true,"env":{"CODEX_HOME":"\#(customPublicHome.path)"}}}"#
            ),
            (
                "CODEX_HOME nested inside shared_codex_home",
                #"{"app_server":{"transport":"local","shared_codex_home":"\#(parentWrappingPublic.path)"},"codex":{"enabled":true,"env":{"CODEX_HOME":"\#(publicInsideParent.path)"}}}"#
            ),
            (
                "shared_codex_home symlink alias overlaps CODEX_HOME",
                #"{"app_server":{"transport":"local","shared_codex_home":"\#(symlinkToPublic.path)"},"codex":{"enabled":true,"env":{"CODEX_HOME":"\#(customPublicHome.path)"}}}"#
            ),
            (
                "explicit CODEX_HOME missing on disk",
                #"{"app_server":{"transport":"local","shared_codex_home":"\#(validPrivateHome.path)"},"codex":{"enabled":true,"env":{"CODEX_HOME":"\#(missingDir.path)"}}}"#
            ),
        ]

        for testCase in invalidConfigs {
            try testCase.json.write(to: configURL, atomically: true, encoding: .utf8)
            let target = CodexDesktopLink.resolveSharedCodexSocketTarget(
                homeDirectory: fakeHome,
                environment: [:],
                expectedUID: currentUID
            )
            XCTAssertNil(target, "\(testCase.label) 必须被拒绝返回 nil")
            XCTAssertTrue(
                CodexDesktopLink.sharedCodexControlSocketPaths(
                    homeDirectory: fakeHome,
                    environment: [:],
                    expectedUID: currentUID
                ).isEmpty,
                "\(testCase.label) 不得返回任何共享 socket 路径"
            )
            XCTAssertFalse(
                CodexDesktopLink.hasVerifiedSharedConnection(
                    psWithUIDOutput: psStandaloneOnly,
                    desktopPIDs: [1914],
                    localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
                    expectedUsername: "alice",
                    expectedUID: currentUID,
                    tcpLsofOutput: matchedTCP,
                    unixLsofOutput: standaloneListenerUnix,
                    sharedTarget: target,
                    homeDirectory: fakeHome
                ),
                "\(testCase.label) 时绝不得将独立 listener 误报为共享"
            )
        }

        // 2. 配置合法且不重叠的 shared_codex_home 时，必须要求受管前门（agentd codex-front serve）监听；
        //    独立 codex listener、普通 agentd serve、配置不匹配的前门或转发到错误 backend 的前门一律判为非共享！
        let validCfgJSON = """
        {
          "app_server": { "transport": "local", "shared_codex_home": "\(validPrivateHome.path)" },
          "codex": { "enabled": true, "env": { "CODEX_HOME": "\(customPublicHome.path)" } }
        }
        """
        try validCfgJSON.write(to: configURL, atomically: true, encoding: .utf8)

        let validTarget = try XCTUnwrap(
            CodexDesktopLink.resolveSharedCodexSocketTarget(
                homeDirectory: fakeHome,
                environment: [:],
                expectedUID: currentUID
            )
        )
        XCTAssertTrue(validTarget.requiresManagedFrontDoor, "配置 shared_codex_home 时必须要求受管前门")

        // 2a. 独立 codex listener -> 必须拒绝！
        XCTAssertFalse(
            CodexDesktopLink.hasVerifiedSharedConnection(
                psWithUIDOutput: psStandaloneOnly,
                desktopPIDs: [1914],
                localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
                expectedUsername: "alice",
                expectedUID: currentUID,
                tcpLsofOutput: matchedTCP,
                unixLsofOutput: standaloneListenerUnix,
                sharedTarget: validTarget,
                homeDirectory: fakeHome
            ),
            "配置 shared_codex_home 时独立 codex listener 绝不得被判为共享"
        )

        // 2b. 普通 agentd serve（非 codex-front serve）-> 必须拒绝！
        let psAgentdServeNotFront = """
          1914     1   \(currentUID) /Applications/Codex.app/Contents/MacOS/Codex
            30  1914   \(currentUID) /usr/bin/ssh -T -o BatchMode=yes mimi-local sh -c 'codex app-server proxy'
           500     1     0 /usr/sbin/sshd
           501   500   \(currentUID) sshd-session: alice@notty
           502   501   \(currentUID) /opt/homebrew/bin/codex app-server proxy
           900     1   \(currentUID) /Applications/Mimi Remote Mac.app/Contents/Resources/agentd serve --config \(configURL.path)
        """
        let agentdListenerUnix = makeUnixLsof([
            (pid: 900, cmd: "agentd", fd: "5", addr: "0x1111", name: customPublicSock),
            (pid: 502, cmd: "codex", fd: "8", addr: "0x2222", name: "->0x1111"),
        ])
        XCTAssertFalse(
            CodexDesktopLink.hasVerifiedSharedConnection(
                psWithUIDOutput: psAgentdServeNotFront,
                desktopPIDs: [1914],
                localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
                expectedUsername: "alice",
                expectedUID: currentUID,
                tcpLsofOutput: matchedTCP,
                unixLsofOutput: agentdListenerUnix,
                sharedTarget: validTarget,
                homeDirectory: fakeHome
            ),
            "普通 agentd serve 不是受管前门，必须拒绝"
        )

        // 2c. 受管前门但指向不同 --config -> 必须拒绝！
        let psMismatchedFront = """
          1914     1   \(currentUID) /Applications/Codex.app/Contents/MacOS/Codex
            30  1914   \(currentUID) /usr/bin/ssh -T -o BatchMode=yes mimi-local sh -c 'codex app-server proxy'
           500     1     0 /usr/sbin/sshd
           501   500   \(currentUID) sshd-session: alice@notty
           502   501   \(currentUID) /opt/homebrew/bin/codex app-server proxy
           900     1   \(currentUID) /Applications/Mimi Remote Mac.app/Contents/Resources/agentd codex-front serve --config /tmp/other-agentd.json
        """
        XCTAssertFalse(
            CodexDesktopLink.hasVerifiedSharedConnection(
                psWithUIDOutput: psMismatchedFront,
                desktopPIDs: [1914],
                localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
                expectedUsername: "alice",
                expectedUID: currentUID,
                tcpLsofOutput: matchedTCP,
                unixLsofOutput: agentdListenerUnix,
                sharedTarget: validTarget,
                homeDirectory: fakeHome
            ),
            "配置路径不一致的 codex-front serve 必须拒绝"
        )

        // 2d. 受管前门存在且配置一致，但转发到了错误的 app-server-backend.sock -> 必须拒绝！
        let psMatchingFront = """
          1914     1   \(currentUID) /Applications/Codex.app/Contents/MacOS/Codex
            30  1914   \(currentUID) /usr/bin/ssh -T -o BatchMode=yes mimi-local sh -c 'codex app-server proxy'
           500     1     0 /usr/sbin/sshd
           501   500   \(currentUID) sshd-session: alice@notty
           502   501   \(currentUID) /opt/homebrew/bin/codex app-server proxy
           900     1   \(currentUID) /Applications/Mimi Remote Mac.app/Contents/Resources/agentd codex-front serve --log-file /tmp/codex-front.log
        """
        let wrongBackendSock = otherPrivateHome.appendingPathComponent("app-server-control/app-server-backend.sock").standardizedFileURL.path
        let wrongBackendUnix = makeUnixLsof([
            (pid: 900, cmd: "agentd", fd: "5", addr: "0x1111", name: customPublicSock),
            (pid: 502, cmd: "codex", fd: "8", addr: "0x2222", name: "->0x1111"),
            (pid: 950, cmd: "codex", fd: "4", addr: "0x4444", name: wrongBackendSock),
            (pid: 900, cmd: "agentd", fd: "9", addr: "0x3333", name: "->0x4444"),
        ])
        XCTAssertFalse(
            CodexDesktopLink.hasVerifiedSharedConnection(
                psWithUIDOutput: psMatchingFront,
                desktopPIDs: [1914],
                localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
                expectedUsername: "alice",
                expectedUID: currentUID,
                tcpLsofOutput: matchedTCP,
                unixLsofOutput: wrongBackendUnix,
                sharedTarget: validTarget,
                homeDirectory: fakeHome
            ),
            "前门连接到非期望 shared_codex_home 的 backend socket 时必须拒绝"
        )

        // 2e. 受管前门 LaunchAgent plist 登记了不同的后端目录（配置漂移）-> resolveSharedCodexSocketTarget 必须返回 nil！
        let driftedPlist: [String: Any] = [
            "Label": "com.gaixianggeng.mimi.mac.codex-front",
            "Sockets": ["Listeners": ["SockPathName": customPublicSock]],
            "EnvironmentVariables": ["MIMI_CODEX_FRONT_BACKEND_HOME": otherPrivateHome.path],
        ]
        let driftedPlistData = try PropertyListSerialization.data(fromPropertyList: driftedPlist, format: .xml, options: 0)
        try driftedPlistData.write(to: plistURL)
        XCTAssertNil(
            CodexDesktopLink.resolveSharedCodexSocketTarget(
                homeDirectory: fakeHome,
                environment: [:],
                expectedUID: currentUID
            ),
            "前门 plist 登记的后端目录与 config.json 不一致时必须拒绝"
        )

        // 2f. plist、前门进程与 backend socket 全部一致 -> 正确判为共享！
        let matchedPlist: [String: Any] = [
            "Label": "com.gaixianggeng.mimi.mac.codex-front",
            "Sockets": ["Listeners": ["SockPathName": customPublicSock]],
            "EnvironmentVariables": ["MIMI_CODEX_FRONT_BACKEND_HOME": validPrivateHome.path],
        ]
        let matchedPlistData = try PropertyListSerialization.data(fromPropertyList: matchedPlist, format: .xml, options: 0)
        try matchedPlistData.write(to: plistURL)

        let verifiedTarget = try XCTUnwrap(
            CodexDesktopLink.resolveSharedCodexSocketTarget(
                homeDirectory: fakeHome,
                environment: [:],
                expectedUID: currentUID
            )
        )
        let expectedBackendSock = validPrivateHome.appendingPathComponent("app-server-control/app-server-backend.sock").standardizedFileURL.path
        let matchedFrontUnix = makeUnixLsof([
            (pid: 900, cmd: "agentd", fd: "5", addr: "0x1111", name: customPublicSock),
            (pid: 502, cmd: "codex", fd: "8", addr: "0x2222", name: "->0x1111"),
            (pid: 950, cmd: "codex", fd: "4", addr: "0x4444", name: expectedBackendSock),
            (pid: 900, cmd: "agentd", fd: "9", addr: "0x3333", name: "->0x4444"),
        ])
        XCTAssertTrue(
            CodexDesktopLink.hasVerifiedSharedConnection(
                psWithUIDOutput: psMatchingFront,
                desktopPIDs: [1914],
                localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
                expectedUsername: "alice",
                expectedUID: currentUID,
                tcpLsofOutput: matchedTCP,
                unixLsofOutput: matchedFrontUnix,
                sharedTarget: verifiedTarget,
                homeDirectory: fakeHome
            ),
            "受管前门、plist、公共 socket 与私有 backend 全部核验通过时应判为共享"
        )
    }

    // MARK: - PR #1169 r1 P1-4 & P2-1: Active Mimi Agentd Live Backend Verification & Explicit Connections Fallback

    func testR1_P1VerifiesDesktopAndActiveMimiAgentdAgainstSameLiveBackend() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-r1-p1-4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fakeHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        let mimiCodexHome = tempRoot.appendingPathComponent("mimi-codex", isDirectory: true)
        let otherCodexHome = tempRoot.appendingPathComponent("other-codex", isDirectory: true)
        let privateBackendHome = tempRoot.appendingPathComponent("private-backend", isDirectory: true)
        let configDir = fakeHome.appendingPathComponent("Library/Application Support/mimi-remote", isDirectory: true)
        for dir in [fakeHome, mimiCodexHome, otherCodexHome, privateBackendHome, configDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let defaultConfigURL = configDir.appendingPathComponent("config.json")
        let otherConfigURL = tempRoot.appendingPathComponent("other-agentd.json")
        let currentUID = Darwin.geteuid()

        // 默认 Mimi 配置使用 ssh transport，但同用户另一个 agentd serve --config other.json 使用 local transport。
        try #"{"listen":"127.0.0.1:8787","app_server":{"transport":"ssh","ssh_target":"remote"},"codex":{"enabled":true}}"#
            .write(to: defaultConfigURL, atomically: true, encoding: .utf8)
        try #"{"listen":"127.0.0.1:9797","app_server":{"transport":"local"},"codex":{"enabled":true,"env":{"CODEX_HOME":"\#(otherCodexHome.path)"}}}"#
            .write(to: otherConfigURL, atomically: true, encoding: .utf8)

        // 1. 两个同用户 agentd serve（Mimi 受管 supervisor 子进程 700 + 另一个带 --config 的 888）：
        //    必须严格绑定到 Mimi 自己的活动守护进程 700（ssh transport -> 返回 nil），绝不借用 888 的配置！
        let psDualAgentd = """
          699     1   \(currentUID) /Applications/Mimi Remote Mac.app/Contents/MacOS/Mimi Remote Mac --agentd-supervisor
          700   699   \(currentUID) /Applications/Mimi Remote Mac.app/Contents/Resources/agentd serve --log-file /tmp/mimi.log
          888     1   \(currentUID) /opt/homebrew/bin/agentd serve --config \(otherConfigURL.path)
        """
        let dualProcesses = CodexDesktopLink.parseProcessesWithUID(psOutput: psDualAgentd)
        let listenLsof = """
        p700
        n127.0.0.1:8787
        p888
        n127.0.0.1:9797
        """
        let listeningPorts = CodexDesktopLink.parseListeningTCPPorts(lsofOutput: listenLsof)
        let activeFromDual = try XCTUnwrap(CodexDesktopLink.resolveActiveMimiAgentd(
            processes: dualProcesses,
            listeningPortsByPID: listeningPorts,
            launchdSupervisorPID: 699,
            homeDirectory: fakeHome,
            expectedUID: currentUID
        ))
        XCTAssertEqual(activeFromDual.pid, 700, "必须识别 Mimi 自己的活动 agentd 700，而非其他同用户 agentd 888")
        XCTAssertNil(
            CodexDesktopLink.resolveSharedCodexSocketTarget(
                homeDirectory: fakeHome,
                environment: [:],
                expectedUID: currentUID,
                agentdConfigURL: activeFromDual.configURL,
                processes: dualProcesses
            ),
            "Mimi 活动守护进程使用 ssh transport 时，绝不得因另一个 agentd 使用 local 而判为共享"
        )

        // 无 supervisor 且存在多个不同配置的 agentd serve -> resolveSharedCodexSocketTarget 必须 fail closed 返回 nil！
        let psAmbiguous = """
          700     1   \(currentUID) /Applications/Mimi Remote Mac.app/Contents/Resources/agentd serve --log-file /tmp/mimi.log
          888     1   \(currentUID) /opt/homebrew/bin/agentd serve --config \(otherConfigURL.path)
        """
        XCTAssertNil(
            CodexDesktopLink.resolveSharedCodexSocketTarget(
                homeDirectory: fakeHome,
                environment: [:],
                expectedUID: currentUID,
                processes: CodexDesktopLink.parseProcessesWithUID(psOutput: psAmbiguous)
            ),
            "存在多个配置不同的同用户 agentd 且无法确认归属时必须 fail closed"
        )

        // 2. 即使 Mimi 配置为 local，判定 sharing 仍必须确认活动 Mimi agentd PID 700 与桌面 codex 代理连在同一个实时后端 socket！
        try #"{"listen":"127.0.0.1:8787","app_server":{"transport":"local"},"codex":{"enabled":true,"env":{"CODEX_HOME":"\#(mimiCodexHome.path)"}}}"#
            .write(to: defaultConfigURL, atomically: true, encoding: .utf8)
        let mimiTarget = try XCTUnwrap(CodexDesktopLink.resolveSharedCodexSocketTarget(
            homeDirectory: fakeHome,
            environment: [:],
            expectedUID: currentUID,
            agentdConfigURL: defaultConfigURL,
            processes: dualProcesses
        ))
        let mimiSock = mimiCodexHome.appendingPathComponent("app-server-control/app-server-control.sock").standardizedFileURL.path
        let otherSock = otherCodexHome.appendingPathComponent("app-server-control/app-server-control.sock").standardizedFileURL.path

        func makeUnixLsof(_ entries: [(pid: Int32, cmd: String, fd: String, addr: String, name: String)]) -> Data {
            var data = Data()
            for entry in entries {
                for field in ["p\(entry.pid)", "c\(entry.cmd)", "f\(entry.fd)", "tunix", "d\(entry.addr)", "n\(entry.name)"] {
                    data.append(contentsOf: field.utf8)
                    data.append(0)
                }
                data.append(0x0A)
            }
            return data
        }

        let psLive = """
          1914     1   \(currentUID) /Applications/Codex.app/Contents/MacOS/Codex
            30  1914   \(currentUID) /usr/bin/ssh -T -o BatchMode=yes mimi-local sh -c 'codex app-server proxy'
           500     1     0 /usr/sbin/sshd
           501   500   \(currentUID) sshd-session: alice@notty
           502   501   \(currentUID) /opt/homebrew/bin/codex app-server proxy
           699     1   \(currentUID) /Applications/Mimi Remote Mac.app/Contents/MacOS/Mimi Remote Mac --agentd-supervisor
           700   699   \(currentUID) /Applications/Mimi Remote Mac.app/Contents/Resources/agentd serve --log-file /tmp/mimi.log
           888     1   \(currentUID) /opt/homebrew/bin/agentd serve --config \(otherConfigURL.path)
        """
        let matchedTCP = """
        p30
        n127.0.0.1:54321->127.0.0.1:22
        p501
        n127.0.0.1:22->127.0.0.1:54321
        """

        // 2a. 只有另一个 agentd (888) 连着 mimiSock，而活动 Mimi agentd (700) 连着不同后端 otherSock -> 必须判为 false！
        let mismatchedAgentdUnix = makeUnixLsof([
            (pid: 900, cmd: "codex", fd: "5", addr: "0x1111", name: mimiSock),
            (pid: 502, cmd: "codex", fd: "8", addr: "0x2222", name: "->0x1111"),
            (pid: 888, cmd: "agentd", fd: "9", addr: "0x3333", name: "->0x1111"),
            (pid: 901, cmd: "codex", fd: "5", addr: "0x4444", name: otherSock),
            (pid: 700, cmd: "agentd", fd: "9", addr: "0x5555", name: "->0x4444"),
        ])
        XCTAssertFalse(
            CodexDesktopLink.hasVerifiedSharedConnection(
                psWithUIDOutput: psLive,
                desktopPIDs: [1914],
                localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
                expectedUsername: "alice",
                expectedUID: currentUID,
                tcpLsofOutput: matchedTCP,
                unixLsofOutput: mismatchedAgentdUnix,
                sharedTarget: mimiTarget,
                activeAgentdPID: 700,
                homeDirectory: fakeHome
            ),
            "活动 Mimi agentd (700) 实际连向不同后端时，不得因另一个 agentd (888) 误报为共享"
        )

        // 2b. 活动 Mimi agentd (700) 与桌面 codex 代理 (502) 连接到同一 listener PID 900 的不同 accepted socket -> 判为 true！
        let sameBackendUnix = makeUnixLsof([
            (pid: 900, cmd: "codex", fd: "5", addr: "0x1111", name: mimiSock),
            (pid: 900, cmd: "codex", fd: "6", addr: "0x1112", name: mimiSock),
            (pid: 502, cmd: "codex", fd: "8", addr: "0x2222", name: "->0x1111"),
            (pid: 700, cmd: "agentd", fd: "9", addr: "0x3333", name: "->0x1112"),
        ])
        XCTAssertTrue(
            CodexDesktopLink.hasVerifiedSharedConnection(
                psWithUIDOutput: psLive,
                desktopPIDs: [1914],
                localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
                expectedUsername: "alice",
                expectedUID: currentUID,
                tcpLsofOutput: matchedTCP,
                unixLsofOutput: sameBackendUnix,
                sharedTarget: mimiTarget,
                activeAgentdPID: 700,
                homeDirectory: fakeHome
            ),
            "桌面 codex 代理与活动 Mimi agentd 连接到同一实时监听进程及 socket 时应判为共享"
        )

        // 2c. 受管前门模式但前门尚未建立任何到 app-server-backend.sock 的活动连接 -> 必须 fail closed 判为 false！
        try #"{"listen":"127.0.0.1:8787","app_server":{"transport":"local","shared_codex_home":"\#(privateBackendHome.path)"},"codex":{"enabled":true,"env":{"CODEX_HOME":"\#(mimiCodexHome.path)"}}}"#
            .write(to: defaultConfigURL, atomically: true, encoding: .utf8)
        let frontTarget = try XCTUnwrap(CodexDesktopLink.resolveSharedCodexSocketTarget(
            homeDirectory: fakeHome,
            environment: [:],
            expectedUID: currentUID,
            agentdConfigURL: defaultConfigURL,
            processes: dualProcesses
        ))
        let psFront = psLive + "\n  900     1   \(currentUID) /Applications/Mimi Remote Mac.app/Contents/Resources/agentd codex-front serve --log-file /tmp/front.log\n"
        let frontNoBackendUnix = makeUnixLsof([
            (pid: 900, cmd: "agentd", fd: "5", addr: "0x1111", name: mimiSock),
            (pid: 900, cmd: "agentd", fd: "6", addr: "0x1112", name: mimiSock),
            (pid: 502, cmd: "codex", fd: "8", addr: "0x2222", name: "->0x1111"),
            (pid: 700, cmd: "agentd", fd: "9", addr: "0x3333", name: "->0x1112"),
        ])
        XCTAssertFalse(
            CodexDesktopLink.hasVerifiedSharedConnection(
                psWithUIDOutput: psFront,
                desktopPIDs: [1914],
                localHosts: CodexDesktopLink.localHosts(includeManagedAlias: true),
                expectedUsername: "alice",
                expectedUID: currentUID,
                tcpLsofOutput: matchedTCP,
                unixLsofOutput: frontNoBackendUnix,
                sharedTarget: frontTarget,
                activeAgentdPID: 700,
                homeDirectory: fakeHome
            ),
            "受管前门缺少到期望私有 backend socket 的活动连接时必须 fail closed"
        )

        // 3. launchctl pid 解析辅助核验
        XCTAssertEqual(
            CodexDesktopLink.parseLaunchctlServicePID(from: "gui/501/com.gaixianggeng.mimi.mac.agentd = {\n\tstate = running\n\tpid = 699\n}\n"),
            699
        )
        XCTAssertNil(CodexDesktopLink.parseLaunchctlServicePID(from: "state = waiting\npid = 0\n"))
    }

    @MainActor
    func testR1_P2CoordinatorExplicitConnectionsFallbackOpensConnectionsURL() async {
        var recordedPrefers: [Bool] = []
        let coordinator = CodexSharedSetupCoordinator(
            checker: {
                CodexSharedSetupStatus.make(
                    desktop: .separate,
                    remoteLogin: true,
                    passwordless: true,
                    localSSHManaged: true,
                    managedAliasReady: true
                )
            },
            openDesktopSettings: { preferSSH in
                recordedPrefers.append(preferSSH)
                return preferSSH ? .openedSSHSettings : .openedConnectionsFallback
            }
        )
        await coordinator.refresh()
        await coordinator.openCodexSSHSettings()
        XCTAssertEqual(recordedPrefers, [true])
        XCTAssertFalse(coordinator.desktopOpenFeedbackIsError)
        XCTAssertTrue(coordinator.desktopOpenFeedback?.contains("发送") == true)

        await coordinator.openCodexConnectionsSettings()
        XCTAssertEqual(recordedPrefers, [true, false])
        XCTAssertFalse(coordinator.desktopOpenFeedbackIsError)
        XCTAssertTrue(coordinator.desktopOpenFeedback?.contains("连接") == true)
    }

    // MARK: - PR #1169 r2 P1-4 & P1-5: Pairing-Independent Probe & Live Loopback Listener Override

    func testR2_P1_5IdentifiesActiveDaemonWithAgentdListenAndPortOverrides() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-r2-p1-5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fakeHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        let configDir = fakeHome.appendingPathComponent("Library/Application Support/mimi-remote", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let configURL = configDir.appendingPathComponent("config.json")
        try #"{"listen":"127.0.0.1:8787","auth":{"token":"cfg-secret-token"},"app_server":{"transport":"local"},"codex":{"enabled":true}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)

        let currentUID = Darwin.geteuid()
        let basePS = """
          699     1   \(currentUID) /Applications/Mimi Remote Mac.app/Contents/MacOS/Mimi Remote Mac --agentd-supervisor
          700   699   \(currentUID) /Applications/Mimi Remote Mac.app/Contents/Resources/agentd serve --log-file /tmp/mimi.log
        """

        // 1. AGENTD_LISTEN 覆写端口为 18787（与 JSON 8787 不同），lsof 实时回环监听在 127.0.0.1:18787 -> 必须识别成功！
        var procsListenOverride = CodexDesktopLink.parseProcessesWithUID(psOutput: basePS)
        procsListenOverride[700]?.environment = ["AGENTD_LISTEN": "127.0.0.1:18787"]
        let listenOverridePorts = CodexDesktopLink.parseListeningTCPPorts(lsofOutput: "p700\nn127.0.0.1:18787\n")
        let activeListen = try XCTUnwrap(CodexDesktopLink.resolveActiveMimiAgentd(
            processes: procsListenOverride,
            listeningPortsByPID: listenOverridePorts,
            launchdSupervisorPID: 699,
            homeDirectory: fakeHome,
            expectedUID: currentUID
        ))
        XCTAssertEqual(activeListen.pid, 700)
        XCTAssertEqual(activeListen.listenPort, 18787)
        XCTAssertEqual(activeListen.authToken, "cfg-secret-token")

        // 2. AGENTD_PORT + AGENTD_TOKEN 覆写且绑定通配地址 *:19001 -> 必须识别端口 19001 与 env token！
        var procsPortOverride = CodexDesktopLink.parseProcessesWithUID(psOutput: basePS)
        procsPortOverride[700]?.environment = ["AGENTD_PORT": "19001", "AGENTD_TOKEN": "env-override-token"]
        let wildcardPorts = CodexDesktopLink.parseListeningTCPPorts(lsofOutput: "p700\nn*:19001\n")
        let activePort = try XCTUnwrap(CodexDesktopLink.resolveActiveMimiAgentd(
            processes: procsPortOverride,
            listeningPortsByPID: wildcardPorts,
            launchdSupervisorPID: 699,
            homeDirectory: fakeHome,
            expectedUID: currentUID
        ))
        XCTAssertEqual(activePort.listenPort, 19001)
        XCTAssertEqual(activePort.authToken, "env-override-token")

        // 3. 即使未读到进程环境变量，已锁定唯一活动进程且仅有一个实时回环监听端口 20444（与 JSON 8787 不同）-> 直接采用实时回环端口！
        let procsNoEnv = CodexDesktopLink.parseProcessesWithUID(psOutput: basePS)
        let singleLivePorts = CodexDesktopLink.parseListeningTCPPorts(lsofOutput: "p700\nn[::1]:20444\n")
        let activeSingleLive = try XCTUnwrap(CodexDesktopLink.resolveActiveMimiAgentd(
            processes: procsNoEnv,
            listeningPortsByPID: singleLivePorts,
            launchdSupervisorPID: 699,
            homeDirectory: fakeHome,
            expectedUID: currentUID
        ))
        XCTAssertEqual(activeSingleLive.listenPort, 20444)

        // 4. 仅监听非回环地址（192.168.1.10:18787）-> 不属于本机回环监听，必须忽略并返回 nil！
        let nonLoopbackPorts = CodexDesktopLink.parseListeningTCPPorts(lsofOutput: "p700\nn192.168.1.10:18787\n")
        XCTAssertTrue(nonLoopbackPorts[700]?.isEmpty ?? true)
        XCTAssertNil(CodexDesktopLink.resolveActiveMimiAgentd(
            processes: procsNoEnv,
            listeningPortsByPID: nonLoopbackPorts,
            launchdSupervisorPID: 699,
            homeDirectory: fakeHome,
            expectedUID: currentUID
        ))
    }

    func testR2_P1_4IdleDaemonProbeUsesBearerTokenIndependentOfPairing503() async throws {
        // 构造真实本机回环 HTTP+WebSocket 服务端：/api/pair/local 永远返回 503，
        // 而 /api/app-server/ws?runtime=codex 校验 Bearer Token 后完成 WebSocket 升级并响应 initialize。
        let expectedToken = "mimi-direct-probe-token-\(UUID().uuidString)"
        let listenFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listenFD, 0)
        defer { Darwin.close(listenFD) }
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindRC, 0)
        XCTAssertEqual(Darwin.listen(listenFD, 4), 0)

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRC = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.getsockname(listenFD, sa, &addrLen)
            }
        }
        XCTAssertEqual(nameRC, 0)
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))

        let pairLocalHits = OSAllocatedUnfairLock(initialState: 0)
        let wsAuthMatched = OSAllocatedUnfairLock(initialState: false)
        let serverTask = Task.detached {
            while true {
                let clientFD = Darwin.accept(listenFD, nil, nil)
                if clientFD < 0 { break }
                defer { Darwin.close(clientFD) }
                var reqBuf = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.read(clientFD, &reqBuf, reqBuf.count)
                guard n > 0 else { continue }
                let reqText = String(decoding: reqBuf.prefix(n), as: UTF8.self)
                let lines = reqText.components(separatedBy: "\r\n")
                let firstLine = lines.first ?? ""

                if firstLine.contains("/api/pair/local") {
                    pairLocalHits.withLock { $0 += 1 }
                    let resp = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 29\r\nConnection: close\r\n\r\n{\"error\":\"pairing not ready\"}"
                    _ = resp.withCString { Darwin.write(clientFD, $0, strlen($0)) }
                    continue
                }

                var wsKey = ""
                var authHeader = ""
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") {
                        let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                        let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        if k == "sec-websocket-key" { wsKey = v }
                        if k == "authorization" { authHeader = v }
                    }
                }
                guard firstLine.contains("/api/app-server/ws?runtime=codex"),
                      authHeader == "Bearer \(expectedToken)",
                      !wsKey.isEmpty else {
                    let resp = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    _ = resp.withCString { Darwin.write(clientFD, $0, strlen($0)) }
                    continue
                }
                wsAuthMatched.withLock { $0 = true }

                let magic = wsKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                let acceptVal = Data(Insecure.SHA1.hash(data: Data(magic.utf8))).base64EncodedString()
                let upgradeResp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptVal)\r\n\r\n"
                _ = upgradeResp.withCString { Darwin.write(clientFD, $0, strlen($0)) }

                // 读取客户端 initialize 文本帧并回复合法 JSON-RPC result 帧（服务端帧不加掩码）。
                var frameBuf = [UInt8](repeating: 0, count: 4096)
                let frameN = Darwin.read(clientFD, &frameBuf, frameBuf.count)
                guard frameN > 2 else { continue }
                let replyJSON = Data(#"{"jsonrpc":"2.0","id":1,"result":{"userAgent":"codex-test"}}"#.utf8)
                var outFrame: [UInt8] = [0x81, UInt8(replyJSON.count)]
                outFrame.append(contentsOf: replyJSON)
                _ = outFrame.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress, $0.count) }
                // 读取客户端 initialized 帧后等待关闭。
                _ = Darwin.read(clientFD, &frameBuf, frameBuf.count)
                break
            }
        }

        // 先确认若调用 /api/pair/local 确实返回 503（模拟 Codex 唯一助手且无新观测的配对未就绪场景）。
        let client = LocalGatewayClient(requestTimeout: 5)
        do {
            _ = try await client.claimToken(port: port)
            XCTFail("/api/pair/local 在本夹具中应返回 503")
        } catch LocalGatewayError.claimRejected {}
        XCTAssertEqual(pairLocalHits.withLock { $0 }, 1)

        // 核心回归：openCodexProbeChannel 直接携带 Bearer Token 建立探针通道，完全绕开 /api/pair/local 并成功握手！
        let channel = try await client.openCodexProbeChannel(port: port, bearerToken: expectedToken)
        channel.close()
        Darwin.shutdown(listenFD, SHUT_RDWR)
        await serverTask.value

        XCTAssertEqual(pairLocalHits.withLock { $0 }, 1, "openCodexProbeChannel 绝不得调用 /api/pair/local")
        XCTAssertTrue(wsAuthMatched.withLock { $0 }, "探针通道必须携带 Bearer Token 直连 /api/app-server/ws?runtime=codex")
    }
}

private actor ProbeTargetRecorder {
    var targets: [String] = []
    func record(_ target: String) { targets.append(target) }
}

private actor SetupCallCounter {
    var count = 0
    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
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
