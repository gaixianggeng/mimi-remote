import Darwin
import XCTest
@testable import MimiRemoteMac

/// 隔离目录方案（`~/.ssh/mimi/`）与 r5 六条 P1 回归专项测试（#376）。
final class CodexLocalSSHIsolationTests: XCTestCase {
    private var tempHome: URL!

    private static let mockVerifiedHostKeyLine =
        "mimi-local ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIsolationMockHostKey12345678901234567890123\n"

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-ssh-iso-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            if let enumerator = FileManager.default.enumerator(at: tempHome, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator {
                    _ = Darwin.chmod(url.path, 0o700)
                }
            }
            try? FileManager.default.removeItem(at: tempHome)
        }
        try super.tearDownWithError()
    }

    private func makeConfigurator(
        home: URL? = nil,
        username: String = "alice",
        systemSSHConfigPath: String? = "/etc/ssh/ssh_config",
        sshExitStatus: Int32 = 0,
        sshStderr: String = "",
        echoStdinOnVerify: Bool = true,
        writeKnownHostOnVerify: Bool = true,
        customKnownHostPayload: String? = nil,
        beforeAtomicCommit: CodexLocalSSHConfigurator.CommitHook? = nil,
        afterVerifyBeforeCommit: CodexLocalSSHConfigurator.CommitHook? = nil,
        afterVerifyBeforeDelete: CodexLocalSSHConfigurator.CommitHook? = nil,
        simulateHardCrashPoint: CodexLocalSSHConfigurator.HardCrashSimulationPoint? = nil,
        beforeVerifySSH: (@Sendable () throws -> Void)? = nil
    ) -> CodexLocalSSHConfigurator {
        let effectiveHome = home ?? tempHome!
        let payload = customKnownHostPayload ?? Self.mockVerifiedHostKeyLine
        return CodexLocalSSHConfigurator(
            homeDirectory: effectiveHome,
            username: username,
            systemSSHConfigPath: systemSSHConfigPath,
            runCommand: { executable, arguments, timeout, standardInput in
                if executable.lastPathComponent == "ssh-keygen" ||
                    (executable.lastPathComponent == "ssh" && arguments.first == "-G") {
                    return try await CodexLocalSSHConfigurator.defaultCommandRunner(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        standardInput: standardInput
                    )
                }
                try beforeVerifySSH?()
                if sshExitStatus == 0 && writeKnownHostOnVerify,
                   let opt = arguments.first(where: { $0.hasPrefix("UserKnownHostsFile=") }) {
                    let rawPath = String(opt.dropFirst("UserKnownHostsFile=".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    let existing = (try? String(contentsOfFile: rawPath, encoding: .utf8)) ?? ""
                    if existing.isEmpty {
                        try payload.write(toFile: rawPath, atomically: true, encoding: .utf8)
                    }
                }
                let stdout = (sshExitStatus == 0 && echoStdinOnVerify) ? (standardInput ?? Data()) : Data()
                return CommandResult(status: sshExitStatus, stdout: stdout, stderr: Data(sshStderr.utf8))
            },
            beforeAtomicCommit: beforeAtomicCommit,
            afterVerifyBeforeCommit: afterVerifyBeforeCommit,
            afterVerifyBeforeDelete: afterVerifyBeforeDelete,
            simulateHardCrashPoint: simulateHardCrashPoint
        )
    }

    private func posixPermissions(of url: URL) throws -> Int {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Int(st.st_mode & 0o777)
    }

    // MARK: - Isolation Layout & Uninstall Cleanliness

    func testIsolationLayoutPermissionsSingleIncludeAndPreservesNonEmptyMimiDirOnRemove() async throws {
        let configurator = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let originalConfig = "# user comment\nHost prod\n    HostName 10.0.0.5\n"
        let originalAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUserPrimaryKey123456789012345678901234 user@host\n"
        try originalConfig.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)
        try originalAuth.write(to: configurator.authorizedKeysURL, atomically: true, encoding: .utf8)

        try await configurator.configure(verifyConnection: true)

        // 目录 700，Mimi 目录内全部文件 600
        XCTAssertEqual(try posixPermissions(of: configurator.mimiSSHDirectory), 0o700)
        XCTAssertEqual(try posixPermissions(of: configurator.mimiConfigURL), 0o600)
        XCTAssertEqual(try posixPermissions(of: configurator.privateKeyURL), 0o600)
        XCTAssertEqual(try posixPermissions(of: configurator.publicKeyURL), 0o600)
        XCTAssertEqual(try posixPermissions(of: configurator.knownHostsURL), 0o600)

        // ~/.ssh/config 最顶部仅增加一行带引号与标记的 Include
        let configText = try String(contentsOf: configurator.sshConfigURL, encoding: .utf8)
        XCTAssertEqual(configText, CodexLocalSSHConfigurator.managedIncludeLine + "\n" + originalConfig)

        // authorized_keys 仅追加一行带 restrict,from="127.0.0.1,::1" 与 mimi-codex-local 标记的公钥
        let authLines = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(authLines.count, 3) // user line + mimi line + trailing empty
        XCTAssertEqual(String(authLines[0]), originalAuth.trimmingCharacters(in: .newlines))
        XCTAssertTrue(authLines[1].hasPrefix(#"restrict,from="127.0.0.1,::1" ssh-ed25519 "#))
        XCTAssertTrue(authLines[1].hasSuffix(" mimi-codex-local"))

        // 卸载后空 ~/.ssh/mimi/ 自动移除，用户文件逐字节恢复
        try await configurator.remove()
        XCTAssertEqual(try String(contentsOf: configurator.sshConfigURL, encoding: .utf8), originalConfig)
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), originalAuth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.mimiSSHDirectory.path))

        // 若 ~/.ssh/mimi/ 中有用户自行放置的其他文件，卸载绝不删除该未知文件
        try await configurator.configure(verifyConnection: true)
        let extraFile = configurator.mimiSSHDirectory.appendingPathComponent("user-note.txt")
        try "keep me".write(to: extraFile, atomically: true, encoding: .utf8)
        try await configurator.remove()
        XCTAssertEqual(try String(contentsOf: extraFile, encoding: .utf8), "keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.mimiConfigURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.knownHostsURL.path))
    }

    // MARK: - r5 P1-1: NoHostAuthenticationForLocalhost & Reject Empty Trust File

    func testR5_P1_1LocksNoHostAuthenticationForLocalhostAndRejectsEmptyKnownHostsOnEchoSuccess() async throws {
        // 1. 继承 Host * 的 NoHostAuthenticationForLocalhost yes 时，托管配置与验连参数均锁定为 no，且 ssh -G 核验通过。
        let configurator = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        try "Host *\n    NoHostAuthenticationForLocalhost yes\n"
            .write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)

        try await configurator.configure(verifyConnection: true)
        let effective = try await configurator.resolveEffectiveSSHConfig(
            configPath: configurator.sshConfigURL.path,
            alias: CodexLocalSSHConfigurator.hostAlias
        )
        XCTAssertEqual(effective.noHostAuthenticationForLocalhost?.lowercased(), "no")

        // 2. 校验函数必须拒绝 NoHostAuthenticationForLocalhost=yes（托管与旧式均拒绝）。
        var badManaged = effective
        badManaged.noHostAuthenticationForLocalhost = "yes"
        let errMsg = CodexLocalSSHConfigurator.validateEffectiveLoopbackConfig(
            badManaged,
            expectedUser: "alice",
            expectedIdentityFile: configurator.expectedIdentityFileConfigValue,
            expectedKnownHostsFile: configurator.expectedKnownHostsPath
        )
        XCTAssertNotNil(errMsg)
        XCTAssertTrue(errMsg?.contains("NoHostAuthenticationForLocalhost") == true)

        var badLegacy = CodexLocalSSHConfigurator.EffectiveSSHConfig(
            hostname: "127.0.0.1",
            addressFamily: "inet",
            port: "22",
            user: "alice",
            noHostAuthenticationForLocalhost: "yes"
        )
        XCTAssertFalse(CodexLocalSSHConfigurator.isDirectLoopbackConfig(badLegacy, expectedUser: "alice"))
        badLegacy.noHostAuthenticationForLocalhost = "no"
        XCTAssertTrue(CodexLocalSSHConfigurator.isDirectLoopbackConfig(badLegacy, expectedUser: "alice"))

        // 3. 首次验连回显成功但未向事务副本写入主机公钥（空信任文件）-> 必须报错、拒绝提交空信任文件并完整回滚！
        let emptyKHHome = tempHome.appendingPathComponent("empty-kh", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyKHHome, withIntermediateDirectories: true)
        let noRegConfigurator = makeConfigurator(
            home: emptyKHHome,
            username: "alice",
            echoStdinOnVerify: true,
            writeKnownHostOnVerify: false
        )
        do {
            try await noRegConfigurator.configure(verifyConnection: true)
            XCTFail("回显成功但主机密钥未写入事务副本时，必须拒绝提交空信任文件并报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .verificationFailed(let detail) = error else {
                return XCTFail("期望 verificationFailed，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("信任"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: noRegConfigurator.knownHostsURL.path), "空信任文件绝不得提交落盘")
        XCTAssertFalse(FileManager.default.fileExists(atPath: noRegConfigurator.privateKeyURL.path), "验连未登记主机密钥必须回滚新建密钥")
        XCTAssertFalse(FileManager.default.fileExists(atPath: noRegConfigurator.sshConfigURL.path), "验连未登记主机密钥必须回滚新建 config")
        XCTAssertFalse(FileManager.default.fileExists(atPath: noRegConfigurator.authorizedKeysURL.path), "验连未登记主机密钥必须回滚新建授权")
        XCTAssertFalse(FileManager.default.fileExists(atPath: noRegConfigurator.stateFileURL.path), "完整回滚后不得残留状态文件")

        // 4. 事务副本只写了错误主机的记录（不含 HostKeyAlias mimi-local）-> 同样拒绝提交并回滚！
        let wrongHostHome = tempHome.appendingPathComponent("wrong-host-kh", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongHostHome, withIntermediateDirectories: true)
        let wrongHostConfig = makeConfigurator(
            home: wrongHostHome,
            username: "alice",
            writeKnownHostOnVerify: true,
            customKnownHostPayload: "other-host.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIWrongHost123456789012345678901234567890123\n"
        )
        do {
            try await wrongHostConfig.configure(verifyConnection: true)
            XCTFail("事务副本缺少 mimi-local 记录时必须拒绝提交")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .verificationFailed = error else {
                return XCTFail("期望 verificationFailed，实际：\(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrongHostConfig.knownHostsURL.path))
    }

    // MARK: - r5 P1-2: Probe/Desktop Equivalence, HostKeyAlias & Mid-Path Quoted Include Freezing

    func testR5_P1_2EnforcesProbeDesktopEquivalenceHostKeyAliasAndMidPathQuotedInclude() async throws {
        let configurator = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)

        // 1. 正对照（显式 User alice，不依赖运行测试机器的当前用户名）必须通过
        let baseLegacyConfig = """
        Host 127.0.0.1
            User alice
            AddressFamily inet
        """
        try baseLegacyConfig.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)
        let positive = await CodexSharedSetupChecks.probeTarget(
            "127.0.0.1",
            configurator: configurator,
            runProbe: { _, _, _, stdin in CommandResult(status: 0, stdout: stdin ?? Data(), stderr: Data()) }
        )
        XCTAssertTrue(positive, "同一夹具正对照必须通过")

        // 2. /bin/cat 使用独有 IdentityFile（无命令基准与代理相同但 /bin/cat 多出一把钥匙）-> 必须拒绝！
        let catUniqueIdentity = baseLegacyConfig + """

        Match command "/bin/cat"
            IdentityFile ~/.ssh/cat_only_key
        """
        try catUniqueIdentity.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)
        let rejectedCatOnlyKey = await CodexSharedSetupChecks.probeTarget(
            "127.0.0.1",
            configurator: configurator,
            runProbe: { _, _, _, stdin in CommandResult(status: 0, stdout: stdin ?? Data(), stderr: Data()) }
        )
        XCTAssertFalse(rejectedCatOnlyKey, "/bin/cat 独有 IdentityFile 绝不能误报旧式就绪")

        // 3. 探测走 IPv4 而桌面代理走 IPv6（Match command 改 HostName ::1 或 AddressFamily inet6）-> 必须拒绝！
        let ipv6Divergence = """
        Host 127.0.0.1
            User alice
        Match command "*codex*"
            HostName ::1
            AddressFamily inet6
        """
        try ipv6Divergence.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)
        let rejectedIPv6Divergence = await CodexSharedSetupChecks.probeTarget(
            "127.0.0.1",
            configurator: configurator,
            runProbe: { _, _, _, stdin in CommandResult(status: 0, stdout: stdin ?? Data(), stderr: Data()) }
        )
        XCTAssertFalse(rejectedIPv6Divergence, "探测走 IPv4 而代理走 IPv6 绝不能误报就绪")

        // 4. 托管画像校验 HostKeyAlias：HostKeyAlias 偏差必须在 validateEffectiveLoopbackConfig 与 Match command 下被拦住！
        var badAlias = CodexLocalSSHConfigurator.EffectiveSSHConfig(
            hostname: "127.0.0.1",
            addressFamily: "inet",
            port: "22",
            user: "alice",
            hostKeyAlias: "wrong-alias",
            identitiesOnly: "yes",
            identityAgent: "none",
            identityFiles: [configurator.expectedIdentityFileConfigValue],
            pubkeyAuthentication: "yes",
            userKnownHostsFile: configurator.expectedKnownHostsPath,
            globalKnownHostsFile: "none",
            knownHostsCommand: "none",
            verifyHostKeyDNS: "no",
            noHostAuthenticationForLocalhost: "no",
            strictHostKeyChecking: "accept-new",
            controlMaster: "no"
        )
        XCTAssertNotNil(CodexLocalSSHConfigurator.validateEffectiveLoopbackConfig(
            badAlias,
            expectedUser: "alice",
            expectedIdentityFile: configurator.expectedIdentityFileConfigValue,
            expectedKnownHostsFile: configurator.expectedKnownHostsPath
        ))
        badAlias.hostKeyAlias = CodexLocalSSHConfigurator.hostAlias
        XCTAssertNil(CodexLocalSSHConfigurator.validateEffectiveLoopbackConfig(
            badAlias,
            expectedUser: "alice",
            expectedIdentityFile: configurator.expectedIdentityFileConfigValue,
            expectedKnownHostsFile: configurator.expectedKnownHostsPath
        ))

        // 5. 路径中段带双引号/单引号/反斜杠空格的 Include 必须被冻结器忠实展开，不得静默丢弃其中规则！
        let spacedDir = configurator.sshDirectory.appendingPathComponent("a b", isDirectory: true)
        try FileManager.default.createDirectory(at: spacedDir, withIntermediateDirectories: true)
        try "Host *\n    IdentityFile ~/.ssh/mid_quote_extra\n"
            .write(to: spacedDir.appendingPathComponent("extra.conf"), atomically: true, encoding: .utf8)

        for includeSyntax in [
            "Include \(configurator.sshDirectory.path)/\"a b\"/extra.conf\n",
            "Include \(configurator.sshDirectory.path)/'a b'/extra.conf\n",
            "Include \(configurator.sshDirectory.path)/a\\ b/extra.conf\n",
        ] {
            try includeSyntax.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)
            do {
                try await configurator.configure(verifyConnection: false)
                XCTFail("路径中段带引号/转义空格的 Include 中的额外 IdentityFile 不得被静默丢弃：\(includeSyntax)")
            } catch let error as CodexLocalSSHConfigurator.ConfigError {
                guard case .effectiveConfigConflict(let detail) = error else {
                    return XCTFail("期望 effectiveConfigConflict，实际：\(error)")
                }
                XCTAssertTrue(detail.contains("IdentityFile"), "应检出展开后的额外 IdentityFile：\(detail)")
            }
        }

        // 6. 语法损坏的 Include（悬空反斜杠）必须显式报错，绝不静默丢弃！
        try "Include conf.d/broken\\\n".write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)
        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("含悬空反斜杠的 Include 必须显式报 effectiveConfigConflict")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .effectiveConfigConflict = error else {
                return XCTFail("期望 effectiveConfigConflict，实际：\(error)")
            }
        }
    }

    // MARK: - r5 P1-3: Post-Verify External Swap Never Clobbered (RENAME_SWAP & RENAME_EXCL)

    func testR5_P1_3PostVerifyExternalCreateOrSaveIsNeverClobberedForConfigAuthAndKnownHosts() async throws {
        // 1. 原本缺失的 ~/.ssh/config 在最终比对之后、原子发布之前瞬间被外部创建 -> 无覆盖发布报 concurrentModification 且外部内容原样保留！
        let missingConfigHome = tempHome.appendingPathComponent("p1-3-missing-cfg", isDirectory: true)
        try FileManager.default.createDirectory(at: missingConfigHome, withIntermediateDirectories: true)
        let externalCreatedConfig = "Host external-created-late\n    HostName 10.77.77.77\n"
        let missingCfgRace = makeConfigurator(
            home: missingConfigHome,
            username: "alice",
            afterVerifyBeforeCommit: { targetURL in
                if targetURL.path == missingConfigHome.appendingPathComponent(".ssh/config").path {
                    try externalCreatedConfig.write(to: targetURL, atomically: true, encoding: .utf8)
                }
            }
        )
        do {
            try await missingCfgRace.configure(verifyConnection: false)
            XCTFail("最终比对后外部创建缺失的 config 必须中止且不得覆盖")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .concurrentModification = error else {
                return XCTFail("期望 concurrentModification，实际：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: missingCfgRace.sshConfigURL, encoding: .utf8), externalCreatedConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingCfgRace.privateKeyURL.path))

        // 2. 已有 ~/.ssh/config 在最终比对之后、RENAME_SWAP 之前瞬间被外部换档保存 -> RENAME_SWAP 检出实际换下的 inode 不匹配并无损恢复外部版本！
        let existingCfgHome = tempHome.appendingPathComponent("p1-3-existing-cfg", isDirectory: true)
        try FileManager.default.createDirectory(at: existingCfgHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let initialCfg = "Host initial\n    HostName 10.0.0.1\n"
        let externalSavedCfg = "Host external-saved-after-verify\n    HostName 10.88.88.88\n"
        try initialCfg.write(to: existingCfgHome.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        let existingCfgRace = makeConfigurator(
            home: existingCfgHome,
            username: "alice",
            afterVerifyBeforeCommit: { targetURL in
                if targetURL.path == existingCfgHome.appendingPathComponent(".ssh/config").path {
                    try externalSavedCfg.write(to: targetURL, atomically: true, encoding: .utf8)
                }
            }
        )
        do {
            try await existingCfgRace.configure(verifyConnection: false)
            XCTFail("最终比对后外部保存已有 config 必须中止并恢复外部版本")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .concurrentModification = error else {
                return XCTFail("期望 concurrentModification，实际：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: existingCfgRace.sshConfigURL, encoding: .utf8), externalSavedCfg)
        XCTAssertFalse(FileManager.default.fileExists(atPath: existingCfgRace.privateKeyURL.path))

        // 3. 已有 ~/.ssh/authorized_keys 在最终比对之后瞬间被外部换档保存 -> 无损恢复外部版本且回滚其余写入！
        let existingAuthHome = tempHome.appendingPathComponent("p1-3-existing-auth", isDirectory: true)
        try FileManager.default.createDirectory(at: existingAuthHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let initialAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIInitAuth1234567890123456789012345678 init@host\n"
        let externalSavedAuth = initialAuth + "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfterVerifyExt12345678901234567890 ext@host\n"
        try initialAuth.write(to: existingAuthHome.appendingPathComponent(".ssh/authorized_keys"), atomically: true, encoding: .utf8)
        let existingAuthRace = makeConfigurator(
            home: existingAuthHome,
            username: "alice",
            afterVerifyBeforeCommit: { targetURL in
                if targetURL.lastPathComponent == "authorized_keys" {
                    try externalSavedAuth.write(to: targetURL, atomically: true, encoding: .utf8)
                }
            }
        )
        do {
            try await existingAuthRace.configure(verifyConnection: false)
            XCTFail("最终比对后外部保存 authorized_keys 必须中止并恢复外部版本")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .concurrentModification = error else {
                return XCTFail("期望 concurrentModification，实际：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: existingAuthRace.authorizedKeysURL, encoding: .utf8), externalSavedAuth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: existingAuthRace.sshConfigURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: existingAuthRace.privateKeyURL.path))

        // 4. 已有 ~/.ssh/mimi/known_hosts 在 Phase 4 最终比对之后瞬间被外部更新 -> RENAME_SWAP 无损恢复外部版本！
        let existingKHHome = tempHome.appendingPathComponent("p1-3-existing-kh", isDirectory: true)
        try FileManager.default.createDirectory(at: existingKHHome, withIntermediateDirectories: true)
        let initKHConfig = makeConfigurator(home: existingKHHome, username: "alice")
        try await initKHConfig.configure(verifyConnection: true)

        let secondHostKey = Self.mockVerifiedHostKeyLine + "mimi-local ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISecondTxKey12345678901234567890123456789012\n"
        let externalLateKH = Self.mockVerifiedHostKeyLine + "mimi-local ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILateExternalKH12345678901234567890123456789\n"
        let racyKHUpdate = CodexLocalSSHConfigurator(
            homeDirectory: existingKHHome,
            username: "alice",
            runCommand: { executable, arguments, timeout, standardInput in
                if executable.lastPathComponent == "ssh-keygen" ||
                    (executable.lastPathComponent == "ssh" && arguments.first == "-G") {
                    return try await CodexLocalSSHConfigurator.defaultCommandRunner(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        standardInput: standardInput
                    )
                }
                if let opt = arguments.first(where: { $0.hasPrefix("UserKnownHostsFile=") }) {
                    let rawPath = String(opt.dropFirst("UserKnownHostsFile=".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    try secondHostKey.write(toFile: rawPath, atomically: true, encoding: .utf8)
                }
                return CommandResult(status: 0, stdout: standardInput ?? Data(), stderr: Data())
            },
            afterVerifyBeforeCommit: { targetURL in
                if targetURL.lastPathComponent == CodexLocalSSHConfigurator.knownHostsFileName {
                    try externalLateKH.write(to: targetURL, atomically: true, encoding: .utf8)
                }
            }
        )
        do {
            try await racyKHUpdate.configure(verifyConnection: true)
            XCTFail("最终比对后外部更新 known_hosts 必须中止并恢复外部版本")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .concurrentModification = error else {
                return XCTFail("期望 concurrentModification，实际：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: initKHConfig.knownHostsURL, encoding: .utf8), externalLateKH)
    }

    // MARK: - r5 P1-4: Retry Remove Preserves External Known Hosts Protected by Rollback

    func testR5_P1_4Phase4ReplacedKnownHostsProtectedByRollbackIsNotDeletedByFormalRemove() async throws {
        let khHome = tempHome.appendingPathComponent("p1-4-kh-remove", isDirectory: true)
        try FileManager.default.createDirectory(at: khHome, withIntermediateDirectories: true)
        let stateURL = khHome.appendingPathComponent("Library/Application Support/MimiRemoteMac/codex-local-ssh-state.json")
        let khURL = khHome.appendingPathComponent(".ssh/mimi/known_hosts")
        let externalReplacement = "SAME-UID-EXTERNAL-TRUST-FILE-MUST-NEVER-BE-DELETED\n"

        // Phase 4 新建 known_hosts 后、最终状态写入前，known_hosts 被同一用户的外部普通文件替换，触发回滚。
        let racyConfig = CodexLocalSSHConfigurator(
            homeDirectory: khHome,
            username: "alice",
            stateFileURL: stateURL,
            runCommand: { executable, arguments, timeout, standardInput in
                if executable.lastPathComponent == "ssh-keygen" ||
                    (executable.lastPathComponent == "ssh" && arguments.first == "-G") {
                    return try await CodexLocalSSHConfigurator.defaultCommandRunner(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        standardInput: standardInput
                    )
                }
                if let opt = arguments.first(where: { $0.hasPrefix("UserKnownHostsFile=") }) {
                    let rawPath = String(opt.dropFirst("UserKnownHostsFile=".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    try Self.mockVerifiedHostKeyLine.write(toFile: rawPath, atomically: true, encoding: .utf8)
                }
                return CommandResult(status: 0, stdout: standardInput ?? Data(), stderr: Data())
            },
            beforeAtomicCommit: { targetURL in
                if targetURL.lastPathComponent == stateURL.lastPathComponent {
                    try FileManager.default.removeItem(at: khURL)
                    try externalReplacement.write(to: khURL, atomically: true, encoding: .utf8)
                    _ = Darwin.chmod(khURL.path, 0o600)
                    throw CodexLocalSSHConfigurator.ConfigError.fileOperationFailed("模拟最终状态写入失败")
                }
            }
        )

        do {
            try await racyConfig.configure(verifyConnection: true)
            XCTFail("Phase 4 状态写入失败与 known_hosts 回滚冲突必须报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .fileOperationFailed(let detail) = error else {
                return XCTFail("期望 fileOperationFailed，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("known_hosts"))
        }

        // 回滚保全了外部替换文件，并保留了冲突状态与移除重试入口。
        XCTAssertEqual(try String(contentsOf: khURL, encoding: .utf8), externalReplacement)
        let inspectedMid = await racyConfig.inspect()
        XCTAssertTrue(inspectedMid.isManaged)
        XCTAssertFalse(inspectedMid.isReady)

        // 用户按提示调用正式 remove()：按版本核验发现不是 Mimi 归属版本，绝不能删除同一用户的外部文件！
        let formalRemover = makeConfigurator(home: khHome, username: "alice")
        do {
            try await formalRemover.remove()
            XCTFail("正式 remove 面对被外部替换的 known_hosts 必须报错且保留文件")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingKeyFiles = error else {
                return XCTFail("期望 conflictingKeyFiles，实际：\(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: khURL.path), "正式 remove 绝不能删除回滚刚保全的外部信任文件")
        XCTAssertEqual(try String(contentsOf: khURL, encoding: .utf8), externalReplacement)
        let managedDuringKHConflict = await formalRemover.inspect().isManaged
        XCTAssertTrue(managedDuringKHConflict, "冲突未解时必须继续保留状态与入口")

        // 用户手工移走外部文件后再次 remove()，状态账本彻底清空。
        try FileManager.default.removeItem(at: khURL)
        try await formalRemover.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        let managedAfterKHClear = await formalRemover.inspect().isManaged
        XCTAssertFalse(managedAfterKHClear)
    }

    // MARK: - r5 P1-5: Rollback Failure -> Reconfigure (Reuse & Rotate) -> Remove & Multi-Line Same Key

    func testR5_P1_5RollbackFailureThenReconfigureAndMultiLineSameKeyNeverLoseTracking() async throws {
        // 场景 A：回滚失败（新增授权行注释被改）-> 重配（复用同公钥 / 轮换新密钥）-> 撤销：绝不清空或丢失授权记录！
        let flowHome = tempHome.appendingPathComponent("p1-5-flow", isDirectory: true)
        try FileManager.default.createDirectory(at: flowHome, withIntermediateDirectories: true)
        let authURL = flowHome.appendingPathComponent(".ssh/authorized_keys")

        let firstFailing = makeConfigurator(
            home: flowHome,
            username: "alice",
            sshExitStatus: 255,
            sshStderr: "Connection refused",
            beforeVerifySSH: {
                let cur = try String(contentsOf: authURL, encoding: .utf8)
                let edited = cur.replacingOccurrences(of: CodexLocalSSHConfigurator.keyComment, with: "edited-by-user")
                try edited.write(to: authURL, atomically: true, encoding: .utf8)
            }
        )
        do {
            try await firstFailing.configure(verifyConnection: true)
            XCTFail("验连失败且授权注释被改导致回滚受阻必须报错")
        } catch {
            // 预期报错，状态保留 residualAuthorizedKeyBodies
        }
        let editedAuthSnapshot = try String(contentsOf: authURL, encoding: .utf8)
        XCTAssertTrue(editedAuthSnapshot.contains("edited-by-user"))
        let managedAfterFirstFail = await firstFailing.inspect().isManaged
        XCTAssertTrue(managedAfterFirstFail)

        // 重配（此时密钥已被回滚删除，触发轮换生成新密钥）：绝不能在旧行精确删除失败后丢弃旧记录提交新记录！
        let reconfigureRotate = makeConfigurator(home: flowHome, username: "alice")
        do {
            try await reconfigureRotate.configure(verifyConnection: false)
            XCTFail("存在未能清除的历史同公钥授权时，重配轮换必须拒绝并保留旧记录")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingAuthorizedKey = error else {
                return XCTFail("期望 conflictingAuthorizedKey，实际：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: authURL, encoding: .utf8), editedAuthSnapshot)
        let managedAfterRotateReject = await reconfigureRotate.inspect().isManaged
        XCTAssertTrue(managedAfterRotateReject, "重配被拒后必须完整保留残留授权记录")

        // 调用 remove()：仍检测到残留公钥授权，保留文件与记录并报冲突。
        do {
            try await reconfigureRotate.remove()
            XCTFail("残留改注释授权存在时 remove 必须报错并保留记录")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingAuthorizedKey = error else {
                return XCTFail("期望 conflictingAuthorizedKey，实际：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: authURL, encoding: .utf8), editedAuthSnapshot)
        let managedAfterRemoveConflict = await reconfigureRotate.inspect().isManaged
        XCTAssertTrue(managedAfterRemoveConflict)

        // 用户手工删掉被改注释的行后再 remove()，彻底清空状态。
        try "".write(to: authURL, atomically: true, encoding: .utf8)
        try await reconfigureRotate.remove()
        let managedAfterManualClear = await reconfigureRotate.inspect().isManaged
        XCTAssertFalse(managedAfterManualClear)

        // 场景 B：复用同密钥路径（密钥仍在，仅把 authorized_keys 注释改掉）-> 重配绝不得复用并清空记录！
        let reuseHome = tempHome.appendingPathComponent("p1-5-reuse", isDirectory: true)
        try FileManager.default.createDirectory(at: reuseHome, withIntermediateDirectories: true)
        let reuseCfg = makeConfigurator(home: reuseHome, username: "alice")
        try await reuseCfg.configure(verifyConnection: false)
        let reuseAuthBefore = try String(contentsOf: reuseCfg.authorizedKeysURL, encoding: .utf8)
        let reuseAuthEdited = reuseAuthBefore.replacingOccurrences(of: CodexLocalSSHConfigurator.keyComment, with: "custom-note")
        try reuseAuthEdited.write(to: reuseCfg.authorizedKeysURL, atomically: true, encoding: .utf8)

        do {
            try await reuseCfg.configure(verifyConnection: false)
            XCTFail("复用阶段发现被改注释的同公钥行不得清空记录")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingAuthorizedKey = error else {
                return XCTFail("期望 conflictingAuthorizedKey，实际：\(error)")
            }
        }
        let reuseManaged = await reuseCfg.inspect().isManaged
        XCTAssertTrue(reuseManaged)

        // 场景 C：同公钥多行（既有精确 Mimi 标记行，又有另一条用户同公钥行）-> remove 只删 Mimi 标记行，保留另一行并保留冲突记录！
        let multiHome = tempHome.appendingPathComponent("p1-5-multiline", isDirectory: true)
        try FileManager.default.createDirectory(at: multiHome, withIntermediateDirectories: true)
        let multiCfg = makeConfigurator(home: multiHome, username: "alice")
        try await multiCfg.configure(verifyConnection: false)
        let managedLine = try String(contentsOf: multiCfg.authorizedKeysURL, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        let pubBody = try XCTUnwrap(
            CodexLocalSSHConfigurator.extractPublicKeyBody(
                from: try String(contentsOf: multiCfg.publicKeyURL, encoding: .utf8)
            )
        )
        let extraSameKeyLine = "restrict,from=\"127.0.0.1\" \(pubBody) extra-user-copy"
        try "\(extraSameKeyLine)\n\(managedLine)\n".write(to: multiCfg.authorizedKeysURL, atomically: true, encoding: .utf8)

        do {
            try await multiCfg.remove()
            XCTFail("删除 Mimi 精确行后仍有同公钥另一行时，必须报告冲突并保留记录")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingAuthorizedKey = error else {
                return XCTFail("期望 conflictingAuthorizedKey，实际：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: multiCfg.authorizedKeysURL, encoding: .utf8), extraSameKeyLine + "\n")
        let multiManaged = await multiCfg.inspect().isManaged
        XCTAssertTrue(multiManaged)
    }

    // MARK: - r5 P1-6: First-Time Configure Crash Recovery (Write-Ahead Transaction Intent)

    func testR5_P1_6HardCrashAfterAuthorizedKeysCommitRecoversCleanlyOnRestartWithoutOrphanAuth() async throws {
        let crashHome = tempHome.appendingPathComponent("p1-6-crash", isDirectory: true)
        try FileManager.default.createDirectory(at: crashHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let originalConfig = "Host work\n    HostName 10.1.2.3\n"
        let originalAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUserBaseKey12345678901234567890123456 base@host\n"
        try originalConfig.write(to: crashHome.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        try originalAuth.write(to: crashHome.appendingPathComponent(".ssh/authorized_keys"), atomically: true, encoding: .utf8)

        // 首次配置在 authorized_keys 刚提交、进入 Phase 3/4 与最终状态写入前模拟进程强杀（不执行内存回滚）。
        let crashingConfig = makeConfigurator(
            home: crashHome,
            username: "alice",
            simulateHardCrashPoint: .afterAuthorizedKeysCommit
        )
        do {
            try await crashingConfig.configure(verifyConnection: true)
            XCTFail("模拟进程崩溃点必须抛出 SimulatedHardCrashError")
        } catch is CodexLocalSSHConfigurator.SimulatedHardCrashError {
            // 预期：模拟 SIGKILL 后的落盘现场
        }

        // 确认此时 authorized_keys 与密钥确实已经落盘，且预写 WAL 状态文件已存在。
        let authAfterCrash = try String(contentsOf: crashingConfig.authorizedKeysURL, encoding: .utf8)
        XCTAssertTrue(authAfterCrash.contains(CodexLocalSSHConfigurator.keyComment))
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashingConfig.privateKeyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashingConfig.stateFileURL.path))

        // 重启后以全新实例检查：必须识别为 isManaged == true、hasPendingTransaction == true、isReady == false，绝不留孤儿授权！
        let restarted = makeConfigurator(home: crashHome, username: "alice")
        let inspectedAfterRestart = await restarted.inspect()
        XCTAssertTrue(inspectedAfterRestart.isManaged, "崩溃重启后必须保留撤销入口")
        XCTAssertTrue(inspectedAfterRestart.hasPendingTransaction, "崩溃重启后必须识别未完成事务意图")
        XCTAssertTrue(inspectedAfterRestart.hasRecordedAuthorizedEntry, "崩溃重启后必须能追溯刚提交的授权行")
        XCTAssertFalse(inspectedAfterRestart.isReady, "未完成事务绝不能误报就绪")

        // 重启后直接调用 remove()：必须干净撤销授权行、专用密钥、~/.ssh/mimi/config、Include 行、空目录与状态文件！
        try await restarted.remove()
        XCTAssertEqual(try String(contentsOf: restarted.sshConfigURL, encoding: .utf8), originalConfig)
        XCTAssertEqual(try String(contentsOf: restarted.authorizedKeysURL, encoding: .utf8), originalAuth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.privateKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.publicKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.mimiConfigURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.mimiSSHDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.stateFileURL.path))
        let managedAfterRestartRemove = await restarted.inspect().isManaged
        XCTAssertFalse(managedAfterRestartRemove)

        // 再测试 Phase 4 提交 known_hosts 后、最终状态写入前崩溃 -> 重启后 remove() 连同 known_hosts 一并干净清理！
        let crashHome2 = tempHome.appendingPathComponent("p1-6-crash-kh", isDirectory: true)
        try FileManager.default.createDirectory(at: crashHome2, withIntermediateDirectories: true)
        let crashingKH = makeConfigurator(
            home: crashHome2,
            username: "alice",
            simulateHardCrashPoint: .afterKnownHostsCommit
        )
        do {
            try await crashingKH.configure(verifyConnection: true)
            XCTFail("模拟 Phase 4 崩溃点必须抛出 SimulatedHardCrashError")
        } catch is CodexLocalSSHConfigurator.SimulatedHardCrashError {
            // 预期
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashingKH.knownHostsURL.path))
        let restarted2 = makeConfigurator(home: crashHome2, username: "alice")
        let pendingAfterKHCash = await restarted2.inspect().hasPendingTransaction
        XCTAssertTrue(pendingAfterKHCash)
        try await restarted2.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted2.knownHostsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted2.mimiSSHDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted2.stateFileURL.path))
    }
}
