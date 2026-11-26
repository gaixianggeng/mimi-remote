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

        // 已有残留状态时再次调用 configure() 只做校验/拒绝，绝不轮换密钥或丢弃旧记录！
        let reconfigureAttempt = makeConfigurator(home: flowHome, username: "alice")
        do {
            try await reconfigureAttempt.configure(verifyConnection: false)
            XCTFail("存在未能清除的历史同公钥授权时，再次配置必须拒绝并保留旧记录")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingAuthorizedKey = error else {
                return XCTFail("期望 conflictingAuthorizedKey，实际：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: authURL, encoding: .utf8), editedAuthSnapshot)
        let managedAfterReject = await reconfigureAttempt.inspect().isManaged
        XCTAssertTrue(managedAfterReject, "再次配置被拒后必须完整保留残留授权记录")

        // 调用 remove()：仍检测到残留公钥授权，保留文件与记录并报冲突。
        do {
            try await reconfigureAttempt.remove()
            XCTFail("残留改注释授权存在时 remove 必须报错并保留记录")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingAuthorizedKey = error else {
                return XCTFail("期望 conflictingAuthorizedKey，实际：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: authURL, encoding: .utf8), editedAuthSnapshot)
        let managedAfterRemoveConflict = await reconfigureAttempt.inspect().isManaged
        XCTAssertTrue(managedAfterRemoveConflict)

        // 用户手工删掉被改注释的行后再 remove()，彻底清空状态。
        try "".write(to: authURL, atomically: true, encoding: .utf8)
        try await reconfigureAttempt.remove()
        let managedAfterManualClear = await reconfigureAttempt.inspect().isManaged
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

    // MARK: - Final Round P0-1: Validate Source Owner/Permissions & Block Match exec Before ssh -G

    func testFinal_P0_1RejectsUnsafeSSHConfigPermissionsAndMatchExecBeforeSnapshotOrSSHG() async throws {
        // 1. 组/全局可写的 ~/.ssh/config 包含 Match exec：评估、探测、检查与配置都必须拒绝，绝不复制到 0600 快照后执行 shell！
        let writableHome = tempHome.appendingPathComponent("final-p0-1-writable", isDirectory: true)
        try FileManager.default.createDirectory(at: writableHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        _ = Darwin.chmod(writableHome.appendingPathComponent(".ssh").path, 0o700)
        let marker1 = writableHome.appendingPathComponent("pwned-writable-root")
        let configurator1 = makeConfigurator(home: writableHome, username: "alice", systemSSHConfigPath: nil)
        try """
        Match exec "touch '\(marker1.path)'"
            User alice
        Host 127.0.0.1
            User alice
        """.write(to: configurator1.sshConfigURL, atomically: true, encoding: .utf8)
        _ = Darwin.chmod(configurator1.sshConfigURL.path, 0o666)

        XCTAssertThrowsError(try configurator1.materializeCurrentSSHConfigForEvaluation(includeSystemConfig: false)) { error in
            guard case CodexLocalSSHConfigurator.ConfigError.unsafeFileSystemTarget = error else {
                return XCTFail("组/全局可写的 ~/.ssh/config 应报 unsafeFileSystemTarget，实际：\(error)")
            }
        }
        let probeWritable = await CodexSharedSetupChecks.probeTarget(
            "127.0.0.1",
            configurator: configurator1,
            runProbe: { _, _, _, stdin in CommandResult(status: 0, stdout: stdin ?? Data(), stderr: Data()) }
        )
        XCTAssertFalse(probeWritable)
        let inspectWritable = await configurator1.inspect()
        XCTAssertTrue(inspectWritable.hasUnsafeFileSystemState)
        XCTAssertFalse(inspectWritable.isReady)
        do {
            try await configurator1.configure(verifyConnection: false)
            XCTFail("组/全局可写的 ~/.ssh/config 必须拒绝配置")
        } catch CodexLocalSSHConfigurator.ConfigError.unsafeFileSystemTarget {
            // 预期
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker1.path), "绝不得执行不安全来源里的 Match exec")
        XCTAssertEqual(try posixPermissions(of: configurator1.sshConfigURL), 0o666, "拒绝时不得私自改写原文件权限")

        // 2. 0600 主配置 Include 了一个组可写（0664）且含 Match exec 的子配置：整个 Include 树必须前置校验并拒绝！
        let includeHome = tempHome.appendingPathComponent("final-p0-1-include", isDirectory: true)
        let confD = includeHome.appendingPathComponent(".ssh/conf.d", isDirectory: true)
        try FileManager.default.createDirectory(at: confD, withIntermediateDirectories: true)
        _ = Darwin.chmod(includeHome.appendingPathComponent(".ssh").path, 0o700)
        _ = Darwin.chmod(confD.path, 0o700)
        let marker2 = includeHome.appendingPathComponent("pwned-writable-include")
        let badInclude = confD.appendingPathComponent("evil.conf")
        try "Match exec \"touch '\(marker2.path)'\"\n    User alice\n".write(to: badInclude, atomically: true, encoding: .utf8)
        _ = Darwin.chmod(badInclude.path, 0o664)
        let configurator2 = makeConfigurator(home: includeHome, username: "alice", systemSSHConfigPath: nil)
        try "Include conf.d/*.conf\nHost 127.0.0.1\n    User alice\n".write(to: configurator2.sshConfigURL, atomically: true, encoding: .utf8)
        _ = Darwin.chmod(configurator2.sshConfigURL.path, 0o600)

        XCTAssertThrowsError(try configurator2.materializeCurrentSSHConfigForEvaluation(includeSystemConfig: false)) { error in
            guard case CodexLocalSSHConfigurator.ConfigError.unsafeFileSystemTarget = error else {
                return XCTFail("组可写 Include 文件应报 unsafeFileSystemTarget，实际：\(error)")
            }
        }
        let probeBadInclude = await CodexSharedSetupChecks.probeTarget(
            "127.0.0.1",
            configurator: configurator2,
            runProbe: { _, _, _, stdin in CommandResult(status: 0, stdout: stdin ?? Data(), stderr: Data()) }
        )
        XCTAssertFalse(probeBadInclude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker2.path), "Include 树内不安全来源的 Match exec 绝不得执行")

        // 3. 即便权限是 0600，被动只读评估也必须拒绝 Match exec / !exec / exec=，禁止在 ssh -G 中执行外部 shell！
        let execHome = tempHome.appendingPathComponent("final-p0-1-match-exec", isDirectory: true)
        try FileManager.default.createDirectory(at: execHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        _ = Darwin.chmod(execHome.appendingPathComponent(".ssh").path, 0o700)
        let marker3 = execHome.appendingPathComponent("pwned-0600-exec")
        let configurator3 = makeConfigurator(home: execHome, username: "alice", systemSSHConfigPath: nil)
        for rule in [
            "Match exec \"touch '\(marker3.path)'\"\n    User alice\n",
            "Match host * !exec \"touch '\(marker3.path)'\"\n    User alice\n",
            "Match all exec=\"touch '\(marker3.path)'\"\n    User alice\n",
        ] {
            try rule.write(to: configurator3.sshConfigURL, atomically: true, encoding: .utf8)
            _ = Darwin.chmod(configurator3.sshConfigURL.path, 0o600)
            XCTAssertThrowsError(try configurator3.materializeCurrentSSHConfigForEvaluation(includeSystemConfig: false)) { error in
                guard case CodexLocalSSHConfigurator.ConfigError.effectiveConfigConflict = error else {
                    return XCTFail("Match exec 应报 effectiveConfigConflict，实际：\(error)")
                }
            }
            let probeExec = await CodexSharedSetupChecks.probeTarget(
                "127.0.0.1",
                configurator: configurator3,
                runProbe: { _, _, _, stdin in CommandResult(status: 0, stdout: stdin ?? Data(), stderr: Data()) }
            )
            XCTAssertFalse(probeExec)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker3.path), "被动评估绝不得执行 Match exec：\(rule)")
        }
    }

    // MARK: - Final Round P0-2: Reject Group/World-Writable authorized_keys & .ssh Without Tightening

    func testFinal_P0_2RejectsGroupOrWorldWritableAuthorizedKeysAndSSHDirectoryWithoutTightening() async throws {
        // 1. authorized_keys 为 0664（组可写）和 0666（全局可写）：必须拒绝采纳且绝不收紧权限激活 StrictModes 拒绝的授权！
        let existingAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUntrustedStrictModesKey1234567890123456 untrusted@host\n"
        for unsafeMode in [0o664, 0o666] {
            let authHome = tempHome.appendingPathComponent("final-p0-2-auth-\(String(unsafeMode, radix: 8))", isDirectory: true)
            try FileManager.default.createDirectory(at: authHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            _ = Darwin.chmod(authHome.appendingPathComponent(".ssh").path, 0o700)
            let cfg = makeConfigurator(home: authHome, username: "alice", systemSSHConfigPath: nil)
            try existingAuth.write(to: cfg.authorizedKeysURL, atomically: true, encoding: .utf8)
            XCTAssertEqual(Darwin.chmod(cfg.authorizedKeysURL.path, mode_t(unsafeMode)), 0)

            let inspected = await cfg.inspect()
            XCTAssertTrue(inspected.hasUnsafeFileSystemState)
            XCTAssertFalse(inspected.isReady)

            do {
                try await cfg.configure(verifyConnection: false)
                XCTFail("权限 \(String(unsafeMode, radix: 8)) 的 authorized_keys 必须拒绝采纳")
            } catch CodexLocalSSHConfigurator.ConfigError.unsafeFileSystemTarget {
                // 预期
            }
            XCTAssertEqual(try posixPermissions(of: cfg.authorizedKeysURL), unsafeMode, "绝不得收紧组/全局可写的 authorized_keys 权限")
            XCTAssertEqual(try String(contentsOf: cfg.authorizedKeysURL, encoding: .utf8), existingAuth)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cfg.mimiSSHDirectory.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: cfg.stateFileURL.path))
        }

        // 2. ~/.ssh 目录为 0775（组可写）和 0777（全局可写）：同样必须拒绝采纳且绝不收紧 ~/.ssh 权限！
        for unsafeDirMode in [0o775, 0o777] {
            let dirHome = tempHome.appendingPathComponent("final-p0-2-dir-\(String(unsafeDirMode, radix: 8))", isDirectory: true)
            try FileManager.default.createDirectory(at: dirHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            let cfg = makeConfigurator(home: dirHome, username: "alice", systemSSHConfigPath: nil)
            try existingAuth.write(to: cfg.authorizedKeysURL, atomically: true, encoding: .utf8)
            XCTAssertEqual(Darwin.chmod(cfg.authorizedKeysURL.path, 0o600), 0)
            XCTAssertEqual(Darwin.chmod(cfg.sshDirectory.path, mode_t(unsafeDirMode)), 0)

            let inspected = await cfg.inspect()
            XCTAssertTrue(inspected.hasUnsafeFileSystemState)
            XCTAssertFalse(inspected.isReady)

            do {
                try await cfg.configure(verifyConnection: false)
                XCTFail("权限 \(String(unsafeDirMode, radix: 8)) 的 ~/.ssh 目录必须拒绝采纳")
            } catch CodexLocalSSHConfigurator.ConfigError.unsafeFileSystemTarget {
                // 预期
            }
            XCTAssertEqual(try posixPermissions(of: cfg.sshDirectory), unsafeDirMode, "绝不得收紧组/全局可写的 ~/.ssh 权限")
            XCTAssertEqual(try String(contentsOf: cfg.authorizedKeysURL, encoding: .utf8), existingAuth)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cfg.mimiSSHDirectory.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: cfg.stateFileURL.path))
        }
    }

    // MARK: - Scope Cut & Security Regressions (Verify-Only, Unsafe Rollback, Frozen ssh -G, Inode Staging, Transient I/O)

    func testExistingConfigIsVerifyOnlyNeverRotatesKeysOrOverwritesPendingTransaction() async throws {
        let verifyHome = tempHome.appendingPathComponent("scope-verify-only", isDirectory: true)
        try FileManager.default.createDirectory(at: verifyHome, withIntermediateDirectories: true)
        let cfg = makeConfigurator(home: verifyHome, username: "alice", systemSSHConfigPath: nil)
        try await cfg.configure(verifyConnection: true)

        var privStBefore = stat()
        var pubStBefore = stat()
        XCTAssertEqual(Darwin.lstat(cfg.privateKeyURL.path, &privStBefore), 0)
        XCTAssertEqual(Darwin.lstat(cfg.publicKeyURL.path, &pubStBefore), 0)
        let privDataBefore = try Data(contentsOf: cfg.privateKeyURL)

        // 1. 已有健康配置再次调用 configure() 只做校验，不换钥、不改写磁盘文件。
        try await cfg.configure(verifyConnection: true)
        var privStAfter = stat()
        var pubStAfter = stat()
        XCTAssertEqual(Darwin.lstat(cfg.privateKeyURL.path, &privStAfter), 0)
        XCTAssertEqual(Darwin.lstat(cfg.publicKeyURL.path, &pubStAfter), 0)
        XCTAssertEqual(privStAfter.st_ino, privStBefore.st_ino)
        XCTAssertEqual(pubStAfter.st_ino, pubStBefore.st_ino)
        XCTAssertEqual(try Data(contentsOf: cfg.privateKeyURL), privDataBefore)

        // 2. 删除私钥后再次调用 configure()：绝不轮换生成新密钥，必须拒绝并提示先移除。
        try FileManager.default.removeItem(at: cfg.privateKeyURL)
        do {
            try await cfg.configure(verifyConnection: false)
            XCTFail("已有配置缺少私钥时不得轮换生成新密钥")
        } catch CodexLocalSSHConfigurator.ConfigError.conflictingKeyFiles {
            // 预期
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfg.privateKeyURL.path))

        // 3. 首次配置崩溃留下 pendingTransaction 后再次 configure()：绝不覆盖 pendingTransaction。
        let pendingHome = tempHome.appendingPathComponent("scope-pending-no-overwrite", isDirectory: true)
        try FileManager.default.createDirectory(at: pendingHome, withIntermediateDirectories: true)
        let crashingCfg = makeConfigurator(
            home: pendingHome,
            username: "alice",
            systemSSHConfigPath: nil,
            simulateHardCrashPoint: .afterAuthorizedKeysCommit
        )
        do {
            try await crashingCfg.configure(verifyConnection: true)
            XCTFail("应触发模拟崩溃")
        } catch is CodexLocalSSHConfigurator.SimulatedHardCrashError {}
        let stateBeforeRetry = try Data(contentsOf: crashingCfg.stateFileURL)

        let secondAttempt = makeConfigurator(home: pendingHome, username: "alice", systemSSHConfigPath: nil)
        do {
            try await secondAttempt.configure(verifyConnection: false)
            XCTFail("存在未完成 pendingTransaction 时再次配置必须拒绝，不得覆盖记录")
        } catch CodexLocalSSHConfigurator.ConfigError.conflictingKeyFiles {
            // 预期
        }
        XCTAssertEqual(try Data(contentsOf: crashingCfg.stateFileURL), stateBeforeRetry, "pendingTransaction 绝不得被覆盖")
    }

    func testRollbackRefusesUnsafeGroupOrWorldWritableAuthorizedKeysAndConfigWithoutTighteningOrPreservingEntries() async throws {
        // 1. 配置进行中 authorized_keys 被改成 0666 并追加未授权公钥，随后验连失败触发回滚：
        //    回滚必须直接拒绝修改 authorized_keys，绝不将其重写为 0600 激活其中条目！
        let authHome = tempHome.appendingPathComponent("p0-2-rollback-auth-unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: authHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        _ = Darwin.chmod(authHome.appendingPathComponent(".ssh").path, 0o700)
        let origAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOrigSafeKey1234567890123456789012345678 orig@host\n"
        let attackerKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAttackerKeyMustNotActivate123456789012 attacker@evil\n"
        let authURL = authHome.appendingPathComponent(".ssh/authorized_keys")
        try origAuth.write(to: authURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(Darwin.chmod(authURL.path, 0o600), 0)

        let failingAuthCfg = makeConfigurator(
            home: authHome,
            username: "alice",
            systemSSHConfigPath: nil,
            sshExitStatus: 255,
            sshStderr: "Connection refused",
            beforeVerifySSH: {
                let current = try String(contentsOf: authURL, encoding: .utf8)
                try (current + attackerKey).write(to: authURL, atomically: true, encoding: .utf8)
                _ = Darwin.chmod(authURL.path, 0o666)
            }
        )
        do {
            try await failingAuthCfg.configure(verifyConnection: true)
            XCTFail("验连与不安全回滚必须报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .fileOperationFailed(let detail) = error else {
                return XCTFail("期望 fileOperationFailed 报告回滚被拒，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("chmod 600 ~/.ssh/authorized_keys"), "应包含明确手动修复提示：\(detail)")
        }
        // 关键：权限仍为 0666（绝不能收紧为 0600 激活 attackerKey！），且状态保留以便用户手动核对修复后移除。
        XCTAssertEqual(try posixPermissions(of: authURL), 0o666, "回滚绝不得将组/全局可写的 authorized_keys 收紧为 0600")
        let inspectedUnsafeAuth = await failingAuthCfg.inspect()
        XCTAssertTrue(inspectedUnsafeAuth.hasUnsafeFileSystemState)
        XCTAssertTrue(inspectedUnsafeAuth.isManaged)

        // 2. 配置进行中 ~/.ssh/config 被改成 0666 并改动，随后验连失败触发回滚：同样绝不收紧权限或改写！
        let cfgHome = tempHome.appendingPathComponent("p0-2-rollback-cfg-unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: cfgHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        _ = Darwin.chmod(cfgHome.appendingPathComponent(".ssh").path, 0o700)
        let cfgURL = cfgHome.appendingPathComponent(".ssh/config")
        try "Host keep\n    HostName 10.0.0.1\n".write(to: cfgURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(Darwin.chmod(cfgURL.path, 0o600), 0)

        let failingCfg = makeConfigurator(
            home: cfgHome,
            username: "alice",
            systemSSHConfigPath: nil,
            sshExitStatus: 255,
            sshStderr: "Connection refused",
            beforeVerifySSH: {
                let current = try String(contentsOf: cfgURL, encoding: .utf8)
                try (current + "\nHost injected\n    HostName 10.9.9.9\n").write(to: cfgURL, atomically: true, encoding: .utf8)
                _ = Darwin.chmod(cfgURL.path, 0o666)
            }
        )
        do {
            try await failingCfg.configure(verifyConnection: true)
            XCTFail("config 变为 0666 后回滚必须拒绝修改")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .fileOperationFailed(let detail) = error else {
                return XCTFail("期望 fileOperationFailed，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("chmod 600 ~/.ssh/config"), "应包含明确手动修复提示：\(detail)")
        }
        XCTAssertEqual(try posixPermissions(of: cfgURL), 0o666, "回滚绝不得自动收紧不安全的 ~/.ssh/config 权限")

        // 3. 已存在的安全权限（~/.ssh 0755、config 0644）配置与撤销后保持原权限不变，绝不擅自 chmod。
        let keepModeHome = tempHome.appendingPathComponent("p0-2-keep-safe-modes", isDirectory: true)
        try FileManager.default.createDirectory(at: keepModeHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let keepCfg = makeConfigurator(home: keepModeHome, username: "alice", systemSSHConfigPath: nil)
        try "Host work\n    HostName 10.1.1.1\n".write(to: keepCfg.sshConfigURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(Darwin.chmod(keepCfg.sshDirectory.path, 0o755), 0)
        XCTAssertEqual(Darwin.chmod(keepCfg.sshConfigURL.path, 0o644), 0)
        try await keepCfg.configure(verifyConnection: false)
        XCTAssertEqual(try posixPermissions(of: keepCfg.sshDirectory), 0o755)
        XCTAssertEqual(try posixPermissions(of: keepCfg.sshConfigURL), 0o644)
        try await keepCfg.remove()
        XCTAssertEqual(try posixPermissions(of: keepCfg.sshDirectory), 0o755)
        XCTAssertEqual(try posixPermissions(of: keepCfg.sshConfigURL), 0o644)
    }

    func testSSHGAlwaysUsesFrozenSnapshotAndNeverReadsLiveFiles() async throws {
        let frozenHome = tempHome.appendingPathComponent("p0-1-frozen-only", isDirectory: true)
        try FileManager.default.createDirectory(at: frozenHome, withIntermediateDirectories: true)
        let sshGArgsBox = IsolatedArgsRecorder()
        let cfg = CodexLocalSSHConfigurator(
            homeDirectory: frozenHome,
            username: "alice",
            systemSSHConfigPath: nil,
            runCommand: { executable, arguments, timeout, standardInput in
                if executable.lastPathComponent == "ssh", arguments.first == "-G" {
                    await sshGArgsBox.record(arguments)
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
            }
        )

        try await cfg.configure(verifyConnection: true)
        _ = await cfg.inspect()

        let recorded = await sshGArgsBox.all
        XCTAssertFalse(recorded.isEmpty)
        for args in recorded {
            guard let fIdx = args.firstIndex(of: "-F"), fIdx + 1 < args.count else {
                return XCTFail("每次 ssh -G 都必须携带 -F 指向冻结快照：\(args)")
            }
            XCTAssertNotEqual(args[fIdx + 1], cfg.sshConfigURL.path, "ssh -G 绝不得直接读取实时 ~/.ssh/config：\(args)")
        }

        // 不带 -F 直接调用 resolveEffectiveSSHConfig(rawArguments:) 必须被拒绝。
        do {
            _ = try await cfg.resolveEffectiveSSHConfig(rawArguments: [CodexLocalSSHConfigurator.hostAlias])
            XCTFail("缺少 -F 冻结快照参数的 ssh -G 必须被拒绝")
        } catch CodexLocalSSHConfigurator.ConfigError.effectiveConfigConflict {
            // 预期
        }
    }

    func testInMemoryKeyGenerationIsOpenSSHCompatibleAndStagingCleanupOnlyDeletesRecordedInodes() async throws {
        // 1. 内存生成的 OpenSSH Ed25519 私钥能被系统真实 /usr/bin/ssh-keygen -y 与 -lf 识别且公钥、指纹完全一致。
        let generated = try CodexLocalSSHConfigurator.generateEd25519OpenSSHKeyPair()
        XCTAssertEqual(
            CodexLocalSSHConfigurator.derivePublicKeyBody(fromOpenSSHPrivateKeyData: generated.privateKeyData),
            generated.publicKeyBody
        )
        let compatDir = tempHome.appendingPathComponent("openssh-compat", isDirectory: true)
        try FileManager.default.createDirectory(at: compatDir, withIntermediateDirectories: true)
        let compatPriv = compatDir.appendingPathComponent("id_ed25519")
        try generated.privateKeyData.write(to: compatPriv)
        XCTAssertEqual(Darwin.chmod(compatPriv.path, 0o600), 0)

        let derivedResult = try await CodexLocalSSHConfigurator.defaultCommandRunner(
            executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: ["-y", "-P", "", "-f", compatPriv.path],
            timeout: .seconds(10)
        )
        XCTAssertEqual(derivedResult.status, 0, derivedResult.stderrText)
        XCTAssertEqual(
            CodexLocalSSHConfigurator.extractPublicKeyBody(from: derivedResult.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)),
            generated.publicKeyBody
        )

        let fpResult = try await CodexLocalSSHConfigurator.defaultCommandRunner(
            executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: ["-lf", compatPriv.path],
            timeout: .seconds(10)
        )
        XCTAssertEqual(fpResult.status, 0, fpResult.stderrText)
        XCTAssertTrue(fpResult.stdoutText.contains(generated.fingerprint), "ssh-keygen -lf 指纹必须与内存计算一致：\(fpResult.stdoutText)")

        // 2. staging 清理必须严格核验目录与文件 inode：若目录或其中文件被同用户替换为不同 inode，绝不误删！
        let stageHome = tempHome.appendingPathComponent("inode-staging-guard", isDirectory: true)
        let cfg = makeConfigurator(home: stageHome, username: "alice", systemSSHConfigPath: nil)
        try FileManager.default.createDirectory(at: cfg.mimiSSHDirectory, withIntermediateDirectories: true)
        let dirName = "\(CodexLocalSSHConfigurator.keyStagingDirectoryPrefix)\(UUID().uuidString)"
        let stageDir = cfg.mimiSSHDirectory.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: false)
        let privFile = stageDir.appendingPathComponent(CodexLocalSSHConfigurator.keyFileName)
        let pubFile = stageDir.appendingPathComponent("\(CodexLocalSSHConfigurator.keyFileName).pub")
        try Data("orig-priv".utf8).write(to: privFile)
        try Data("orig-pub".utf8).write(to: pubFile)

        var dirSt = stat()
        var privSt = stat()
        var pubSt = stat()
        XCTAssertEqual(Darwin.lstat(stageDir.path, &dirSt), 0)
        XCTAssertEqual(Darwin.lstat(privFile.path, &privSt), 0)
        XCTAssertEqual(Darwin.lstat(pubFile.path, &pubSt), 0)

        let artifact = CodexLocalSSHConfigurator.StagedKeyArtifact(
            directoryName: dirName,
            directoryIdentity: CodexLocalSSHConfigurator.FileIdentity(dev: dirSt.st_dev, ino: dirSt.st_ino),
            privateKeyIdentity: CodexLocalSSHConfigurator.FileIdentity(dev: privSt.st_dev, ino: privSt.st_ino),
            publicKeyIdentity: CodexLocalSSHConfigurator.FileIdentity(dev: pubSt.st_dev, ino: pubSt.st_ino)
        )

        // 替换私钥文件为新 inode：staging 清理必须拒绝删除替换文件！
        try FileManager.default.removeItem(at: privFile)
        let replacementPriv = Data("REPLACEMENT-KEY-MUST-SURVIVE".utf8)
        try replacementPriv.write(to: privFile)
        XCTAssertFalse(cfg.cleanupStagedKeyArtifact(artifact), "文件 inode 变化后 staging 清理必须拒绝删除")
        XCTAssertEqual(try Data(contentsOf: privFile), replacementPriv, "同名替换文件绝不得被 staging 清理误删")

        // 替换整个 staging 目录为新 inode：同样必须拒绝删除其中文件！
        let wrongDirArtifact = CodexLocalSSHConfigurator.StagedKeyArtifact(
            directoryName: dirName,
            directoryIdentity: CodexLocalSSHConfigurator.FileIdentity(dev: dirSt.st_dev, ino: dirSt.st_ino &+ 999999),
            privateKeyIdentity: CodexLocalSSHConfigurator.FileIdentity(dev: privSt.st_dev, ino: privSt.st_ino),
            publicKeyIdentity: CodexLocalSSHConfigurator.FileIdentity(dev: pubSt.st_dev, ino: pubSt.st_ino)
        )
        XCTAssertFalse(cfg.cleanupStagedKeyArtifact(wrongDirArtifact), "目录 inode 不匹配时 staging 清理必须拒绝")
        XCTAssertEqual(try Data(contentsOf: privFile), replacementPriv)

        // 记录当前真实 inode 时，清理精准删除并移除目录。
        var curPrivSt = stat()
        var curPubSt = stat()
        XCTAssertEqual(Darwin.lstat(privFile.path, &curPrivSt), 0)
        XCTAssertEqual(Darwin.lstat(pubFile.path, &curPubSt), 0)
        let matchingArtifact = CodexLocalSSHConfigurator.StagedKeyArtifact(
            directoryName: dirName,
            directoryIdentity: CodexLocalSSHConfigurator.FileIdentity(dev: dirSt.st_dev, ino: dirSt.st_ino),
            privateKeyIdentity: CodexLocalSSHConfigurator.FileIdentity(dev: curPrivSt.st_dev, ino: curPrivSt.st_ino),
            publicKeyIdentity: CodexLocalSSHConfigurator.FileIdentity(dev: curPubSt.st_dev, ino: curPubSt.st_ino)
        )
        XCTAssertTrue(cfg.cleanupStagedKeyArtifact(matchingArtifact))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stageDir.path))
    }

    func testTransientIOErrorDuringRemoveDoesNotSetPersistentConflictFlagBlockingRetry() async throws {
        let retryHome = tempHome.appendingPathComponent("p2-2-transient-io-retry", isDirectory: true)
        try FileManager.default.createDirectory(at: retryHome, withIntermediateDirectories: true)
        let setupCfg = makeConfigurator(home: retryHome, username: "alice", systemSSHConfigPath: nil)
        try await setupCfg.configure(verifyConnection: true)

        // 首次 remove 在删除 known_hosts 前遇到临时 I/O 错误：不得置位 knownHostsConflict 阻断重试。
        let transientFailRemover = makeConfigurator(
            home: retryHome,
            username: "alice",
            systemSSHConfigPath: nil,
            beforeAtomicCommit: { targetURL in
                if targetURL.lastPathComponent == CodexLocalSSHConfigurator.knownHostsFileName {
                    throw CodexLocalSSHConfigurator.ConfigError.fileOperationFailed("模拟临时 I/O 错误")
                }
            }
        )
        do {
            try await transientFailRemover.remove()
            XCTFail("临时 I/O 错误应向上报告")
        } catch CodexLocalSSHConfigurator.ConfigError.fileOperationFailed {}

        // 重试 remove() 必须直接识别匹配版本的 known_hosts 并彻底清理！
        let retryRemover = makeConfigurator(home: retryHome, username: "alice", systemSSHConfigPath: nil)
        try await retryRemover.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: setupCfg.knownHostsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: setupCfg.stateFileURL.path))
        let managedAfterRetry = await retryRemover.inspect().isManaged
        XCTAssertFalse(managedAfterRetry)
    }

    // MARK: - Final Round P1-2: Rollback Must Preserve External Deletions of authorized_keys & config

    func testFinal_P1_2RollbackPreservesExternallyDeletedAuthorizedKeysAndSSHConfig() async throws {
        // 1. 外部在 Mimi 写入后删除了 authorized_keys（吊销访问）：验连失败回滚绝不能重建原 authorized_keys！
        let authDelHome = tempHome.appendingPathComponent("final-p1-2-auth-deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: authDelHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let origAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRevokedKeyMustStayDeleted12345678901234 revoked@host\n"
        let origConfig = "Host keep-me\n    HostName 10.9.9.9\n"
        try origAuth.write(to: authDelHome.appendingPathComponent(".ssh/authorized_keys"), atomically: true, encoding: .utf8)
        try origConfig.write(to: authDelHome.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)

        let authURL = authDelHome.appendingPathComponent(".ssh/authorized_keys")
        let cfgAuthDeleted = makeConfigurator(
            home: authDelHome,
            username: "alice",
            sshExitStatus: 255,
            sshStderr: "Connection refused",
            beforeVerifySSH: {
                try FileManager.default.removeItem(at: authURL)
            }
        )
        do {
            try await cfgAuthDeleted.configure(verifyConnection: true)
            XCTFail("验连失败必须报错并回滚")
        } catch CodexLocalSSHConfigurator.ConfigError.verificationFailed {
            // 预期
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: authURL.path), "回滚绝不得重建外部已删除的 authorized_keys（避免恢复被吊销访问）")
        XCTAssertEqual(try String(contentsOf: cfgAuthDeleted.sshConfigURL, encoding: .utf8), origConfig, "未改动的 config 应正常回滚恢复")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfgAuthDeleted.privateKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfgAuthDeleted.mimiSSHDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfgAuthDeleted.stateFileURL.path))

        // 2. 外部在 Mimi 写入后删除了 ~/.ssh/config：验连失败回滚绝不能重建原 ~/.ssh/config！
        let cfgDelHome = tempHome.appendingPathComponent("final-p1-2-cfg-deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: cfgDelHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try origAuth.write(to: cfgDelHome.appendingPathComponent(".ssh/authorized_keys"), atomically: true, encoding: .utf8)
        try origConfig.write(to: cfgDelHome.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)

        let cfgURL = cfgDelHome.appendingPathComponent(".ssh/config")
        let cfgConfigDeleted = makeConfigurator(
            home: cfgDelHome,
            username: "alice",
            sshExitStatus: 255,
            sshStderr: "Connection refused",
            beforeVerifySSH: {
                try FileManager.default.removeItem(at: cfgURL)
            }
        )
        do {
            try await cfgConfigDeleted.configure(verifyConnection: true)
            XCTFail("验连失败必须报错并回滚")
        } catch CodexLocalSSHConfigurator.ConfigError.verificationFailed {
            // 预期
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfgURL.path), "回滚绝不得重建外部已删除的 ~/.ssh/config")
        XCTAssertEqual(try String(contentsOf: cfgConfigDeleted.authorizedKeysURL, encoding: .utf8), origAuth, "未改动的 authorized_keys 应正常回滚恢复")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfgConfigDeleted.privateKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfgConfigDeleted.mimiSSHDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfgConfigDeleted.stateFileURL.path))
    }

    // MARK: - Final Round P1-3: Register Staging Inodes Before Key Write & Clean Across Actual Process Exit (SIGKILL)

    func testFinal_P1_3PreRegisteredStagingArtifactCleanedAfterRealSIGKILLProcessExit() async throws {
#if !DEBUG
        throw XCTSkip("真实 SIGKILL 暂存崩溃测试辅助入口仅在 Debug 构建编译。")
#else
        let hostExecutable = try XCTUnwrap(Bundle.main.executableURL, "测试宿主可执行文件应存在")
        let crashHome = tempHome.appendingPathComponent("final-p1-3-sigkill", isDirectory: true)
        try FileManager.default.createDirectory(at: crashHome, withIntermediateDirectories: true)

        // 启动真实子进程执行 configure()，在独占写入暂存私钥并持久化 inode 后立刻 SIGKILL 终止进程（完全跳过 Swift defer）。
        let process = Process()
        process.executableURL = hostExecutable
        process.arguments = []
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "XCTestConfigurationFilePath")
        env["MIMI_TEST_SSH_CRASH_STAGING_HOME"] = crashHome.path
        process.environment = env
        try process.run()

        // 有界等待（最多 15 秒），防止辅助入口不可用或异常时测试无限挂起。
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            XCTFail("真实 SIGKILL 崩溃恢复测试子进程在 15 秒内未退出")
            return
        }

        XCTAssertEqual(process.terminationReason, .uncaughtSignal, "子进程应由真实信号终止而非正常退出")
        XCTAssertEqual(process.terminationStatus, SIGKILL, "子进程应由 SIGKILL 终止以跳过所有 Swift defer")

        let configurator = makeConfigurator(home: crashHome, username: "alice")
        // 验证：1) 密钥写入前已落盘登记 staging 目录与文件 inode；2) SIGKILL 确实在 ~/.ssh/mimi/.mimi-keygen-* 遗留了真实私钥。
        let mimiEntries = try FileManager.default.contentsOfDirectory(atPath: configurator.mimiSSHDirectory.path)
        let stagingDirs = mimiEntries.filter { $0.hasPrefix(CodexLocalSSHConfigurator.keyStagingDirectoryPrefix) }
        XCTAssertEqual(stagingDirs.count, 1, "真实 SIGKILL 后应遗留 1 个密钥暂存目录")
        let stagingDirName = try XCTUnwrap(stagingDirs.first, "应安全解包暂存目录名称")
        let stagingDirURL = configurator.mimiSSHDirectory.appendingPathComponent(stagingDirName, isDirectory: true)
        let stagedPrivateKeyURL = stagingDirURL.appendingPathComponent(CodexLocalSSHConfigurator.keyFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedPrivateKeyURL.path), "SIGKILL 跳过 defer 后暂存私钥应留在磁盘上")

        let stateJSON = try String(contentsOf: configurator.stateFileURL, encoding: .utf8)
        XCTAssertTrue(stateJSON.contains(stagingDirName), "写入私钥前状态文件必须已登记该 staging 目录与 inode")

        // 新实例 inspect 应识别为已托管但未就绪，调用 remove() 必须按 inode 核验彻底清理暂存私钥、暂存目录、空 mimi 目录与状态文件。
        let inspected = await configurator.inspect()
        XCTAssertTrue(inspected.isManaged)
        XCTAssertTrue(inspected.hasPendingTransaction)
        XCTAssertFalse(inspected.isReady)

        try await configurator.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedPrivateKeyURL.path), "remove() 必须清理暂存私钥")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirURL.path), "remove() 必须清理暂存目录")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.mimiSSHDirectory.path), "清理后空 ~/.ssh/mimi 应被移除")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.stateFileURL.path), "清理完成后状态文件应被移除")
        let managedAfterClean = await configurator.inspect().isManaged
        XCTAssertFalse(managedAfterClean)
#endif
    }

    // MARK: - Final Round P1-4: Read-Only Probe Allows Trusted Regular Symlink Config While Writes Refuse

    func testFinal_P1_4ReadOnlyProbeAllowsTrustedSymlinkConfigWhileWritesStillRefuse() async throws {
        let dotHome = tempHome.appendingPathComponent("final-p1-4-symlink", isDirectory: true)
        let dotfilesDir = dotHome.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        _ = Darwin.chmod(dotfilesDir.path, 0o755)
        _ = Darwin.chmod(dotHome.appendingPathComponent(".ssh").path, 0o700)

        let targetConfig = dotfilesDir.appendingPathComponent("ssh_config")
        let dotfileContent = """
        Host 127.0.0.1
            User alice
            AddressFamily inet
        """
        try dotfileContent.write(to: targetConfig, atomically: true, encoding: .utf8)
        _ = Darwin.chmod(targetConfig.path, 0o644)

        let configurator = makeConfigurator(home: dotHome, username: "alice", systemSSHConfigPath: nil)
        try FileManager.default.createSymbolicLink(at: configurator.sshConfigURL, withDestinationURL: targetConfig)

        // 1. 只读探测与只读 ssh -G 评估允许可信的普通符号链接 config，dotfiles 用户不会失去向导按钮！
        let probeOK = await CodexSharedSetupChecks.probeTarget(
            "127.0.0.1",
            configurator: configurator,
            runProbe: { _, _, _, stdin in CommandResult(status: 0, stdout: stdin ?? Data(), stderr: Data()) }
        )
        XCTAssertTrue(probeOK, "可信普通符号链接 ~/.ssh/config 在只读探测中必须通过")

        let effective = try await configurator.resolveEffectiveSSHConfig(
            configPath: configurator.sshConfigURL.path,
            alias: "127.0.0.1",
            includeSystemConfig: true
        )
        XCTAssertEqual(effective.hostname, "127.0.0.1")
        XCTAssertEqual(effective.user, "alice")

        // 2. 写入路径（configure）仍必须拒绝符号链接且不改动目标文件内容与权限！
        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("写入路径必须继续拒绝符号链接 ~/.ssh/config")
        } catch CodexLocalSSHConfigurator.ConfigError.unsafeFileSystemTarget {
            // 预期
        }
        XCTAssertEqual(try String(contentsOf: targetConfig, encoding: .utf8), dotfileContent)
        XCTAssertEqual(try posixPermissions(of: targetConfig), 0o644)

        // 3. 若符号链接目标变为组可写（0664），只读探测也必须拒绝！
        _ = Darwin.chmod(targetConfig.path, 0o664)
        let probeWritableTarget = await CodexSharedSetupChecks.probeTarget(
            "127.0.0.1",
            configurator: configurator,
            runProbe: { _, _, _, stdin in CommandResult(status: 0, stdout: stdin ?? Data(), stderr: Data()) }
        )
        XCTAssertFalse(probeWritableTarget, "符号链接指向组/全局可写目标时只读探测必须拒绝")
    }
}

private actor IsolatedArgsRecorder {
    var all: [[String]] = []
    func record(_ args: [String]) { all.append(args) }
}
