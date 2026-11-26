import Darwin
import XCTest
@testable import MimiRemoteMac

final class CodexLocalSSHConfiguratorTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-codex-ssh-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            // 若用例把文件收紧成 0400，先恢复写权限确保临时目录能彻底清理。
            if let enumerator = FileManager.default.enumerator(at: tempHome, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator {
                    _ = Darwin.chmod(url.path, 0o700)
                }
            }
            try? FileManager.default.removeItem(at: tempHome)
        }
        try super.tearDownWithError()
    }

    /// 放行真实 `/usr/bin/ssh-keygen` 与只读 `/usr/bin/ssh -G`，仅桩化真正发起 TCP 22 连接的验连命令。
    private func makeConfigurator(
        username: String = "tester",
        systemSSHConfigPath: String? = "/etc/ssh/ssh_config",
        sshExitStatus: Int32 = 0,
        sshStderr: String = "",
        echoStdinOnVerify: Bool = true,
        beforeAtomicCommit: CodexLocalSSHConfigurator.CommitHook? = nil,
        afterVerifyBeforeDelete: CodexLocalSSHConfigurator.CommitHook? = nil,
        beforeVerifySSH: (@Sendable () throws -> Void)? = nil
    ) -> (CodexLocalSSHConfigurator, CommandRecorder) {
        let recorder = CommandRecorder()
        let configurator = CodexLocalSSHConfigurator(
            homeDirectory: tempHome,
            username: username,
            systemSSHConfigPath: systemSSHConfigPath,
            runCommand: { executable, arguments, timeout, standardInput in
                await recorder.record(executable: executable.path, arguments: arguments)
                if executable.lastPathComponent == "ssh-keygen" {
                    return try await CodexLocalSSHConfigurator.defaultCommandRunner(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        standardInput: standardInput
                    )
                }
                if executable.lastPathComponent == "ssh", arguments.first == "-G" {
                    return try await CodexLocalSSHConfigurator.defaultCommandRunner(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        standardInput: standardInput
                    )
                }
                try beforeVerifySSH?()
                let stdout = (sshExitStatus == 0 && echoStdinOnVerify) ? (standardInput ?? Data()) : Data()
                return CommandResult(
                    status: sshExitStatus,
                    stdout: stdout,
                    stderr: Data(sshStderr.utf8)
                )
            },
            beforeAtomicCommit: beforeAtomicCommit,
            afterVerifyBeforeDelete: afterVerifyBeforeDelete
        )
        return (configurator, recorder)
    }

    // MARK: - Core lifecycle

    func testConfigureFromEmptyHomeCreatesScopedKeyAuthorizedKeyConfigAndVerifies() async throws {
        let (configurator, recorder) = makeConfigurator(username: "alice")
        let initial = await configurator.inspect()
        XCTAssertFalse(initial.isManaged)

        try await configurator.configure(verifyConnection: true)

        let status = await configurator.inspect()
        XCTAssertTrue(status.isReady)
        XCTAssertTrue(status.isManaged)
        XCTAssertTrue(status.effectiveLoopbackVerified)
        XCTAssertFalse(status.hasAnyConflict)

        XCTAssertEqual(try posixPermissions(of: configurator.sshDirectory), 0o700)
        XCTAssertEqual(try posixPermissions(of: configurator.privateKeyURL), 0o600)
        XCTAssertEqual(try posixPermissions(of: configurator.authorizedKeysURL), 0o600)
        XCTAssertEqual(try posixPermissions(of: configurator.sshConfigURL), 0o600)

        let authorized = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
        XCTAssertTrue(authorized.hasPrefix(#"from="127.0.0.1,::1" ssh-ed25519 "#))
        XCTAssertTrue(authorized.hasSuffix("mimi-codex-local\n"))

        let config = try String(contentsOf: configurator.sshConfigURL, encoding: .utf8)
        XCTAssertTrue(config.contains(CodexLocalSSHConfigurator.managedBlockStart))
        XCTAssertTrue(config.contains("Host \(CodexLocalSSHConfigurator.hostAlias)"))
        XCTAssertTrue(config.contains("HostName 127.0.0.1"))
        XCTAssertTrue(config.contains("Port 22"))
        XCTAssertTrue(config.contains("User alice"))
        XCTAssertTrue(config.contains("IdentityFile ~/.ssh/\(CodexLocalSSHConfigurator.keyFileName)"))
        XCTAssertTrue(config.contains("IdentitiesOnly yes"))
        XCTAssertTrue(config.contains("IdentityAgent none"))
        XCTAssertTrue(config.contains("PubkeyAuthentication yes"))
        XCTAssertTrue(config.contains("PreferredAuthentications publickey"))
        XCTAssertTrue(config.contains("ClearAllForwardings yes"))
        XCTAssertTrue(config.contains("UserKnownHostsFile \"\(configurator.expectedKnownHostsPath)\""))
        XCTAssertTrue(config.contains("GlobalKnownHostsFile none"))
        XCTAssertTrue(config.contains("ProxyJump none"))
        XCTAssertTrue(config.contains("ControlMaster no"))
        XCTAssertTrue(config.contains(CodexLocalSSHConfigurator.managedBlockEnd))

        // 应用专用主机信任文件已创建且为 0600，未触碰 ~/.ssh/known_hosts。
        XCTAssertEqual(try posixPermissions(of: configurator.knownHostsURL), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.sshDirectory.appendingPathComponent("known_hosts").path))

        // 验证最后一步使用桌面版实际托管别名 mimi-local 验连（非 -F /dev/null 绕过用户与系统配置）。
        let calls = await recorder.calls
        let liveVerifyCalls = calls.filter { $0.executable == "/usr/bin/ssh" && $0.arguments.first != "-G" }
        XCTAssertEqual(liveVerifyCalls.count, 1)
        let verifyArgs = try XCTUnwrap(liveVerifyCalls.first?.arguments)
        XCTAssertFalse(verifyArgs.contains("/dev/null"))
        XCTAssertTrue(verifyArgs.contains("BatchMode=yes"))
        XCTAssertTrue(verifyArgs.contains("PasswordAuthentication=no"))
        XCTAssertTrue(verifyArgs.contains(CodexLocalSSHConfigurator.hostAlias))
        XCTAssertEqual(verifyArgs.last, "/bin/cat")
    }

    func testConfigurePreservesExistingConfigWithoutTrailingNewlineCreatesBackupAndIsIdempotent() async throws {
        let (configurator, recorder) = makeConfigurator(username: "bob")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let originalConfig = "Host prod\n    HostName 10.0.0.5\n    User deploy"
        try originalConfig.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)
        let originalAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExistingKey existing@host"
        try originalAuth.write(to: configurator.authorizedKeysURL, atomically: true, encoding: .utf8)

        try await configurator.configure(verifyConnection: true)

        let configAfterFirst = try String(contentsOf: configurator.sshConfigURL, encoding: .utf8)
        XCTAssertTrue(configAfterFirst.hasPrefix(CodexLocalSSHConfigurator.managedBlockStart))
        XCTAssertTrue(configAfterFirst.hasSuffix("\n\n" + originalConfig))

        let authAfterFirst = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
        let authLines = authAfterFirst.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(authLines.count, 2)
        XCTAssertEqual(authLines[0], originalAuth)

        let backups = try FileManager.default.contentsOfDirectory(atPath: configurator.sshDirectory.path)
            .filter { $0.hasPrefix("config.before-mimi.") && $0.hasSuffix(".bak") }
        XCTAssertEqual(backups.count, 1)
        let backupURL = configurator.sshDirectory.appendingPathComponent(try XCTUnwrap(backups.first))
        XCTAssertEqual(try Data(contentsOf: backupURL), Data(originalConfig.utf8))
        XCTAssertEqual(try posixPermissions(of: backupURL), 0o600)

        // 第二次运行保持幂等，不重复追加公钥或托管块，也不重生成密钥。
        try await configurator.configure(verifyConnection: true)
        XCTAssertEqual(try String(contentsOf: configurator.sshConfigURL, encoding: .utf8), configAfterFirst)
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), authAfterFirst)
        let calls = await recorder.calls
        let keygenCreateCalls = calls.filter {
            $0.executable == "/usr/bin/ssh-keygen" && $0.arguments.contains("-t")
        }
        XCTAssertEqual(keygenCreateCalls.count, 1)
    }

    func testConfigureRefusesConflictingUnmanagedHostAliasWithoutTouchingExistingFiles() async throws {
        let (configurator, _) = makeConfigurator(username: "carol")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let customConfig = "Host mimi-local\n    HostName 192.168.1.99\n"
        try customConfig.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)

        let inspected = await configurator.inspect()
        XCTAssertTrue(inspected.hasConflictingHostAlias)
        XCTAssertFalse(inspected.isReady)

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("已有自定义 mimi-local 时必须拒绝覆盖")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            XCTAssertEqual(error, .conflictingHostAlias("mimi-local"))
        }

        XCTAssertEqual(try String(contentsOf: configurator.sshConfigURL, encoding: .utf8), customConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.privateKeyURL.path))
    }

    func testConfigureRefusesCorruptedManagedMarkers() async throws {
        let (configurator, _) = makeConfigurator(username: "dave")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let broken = "\(CodexLocalSSHConfigurator.managedBlockStart)\nHost mimi-local\n"
        try broken.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("标记块不完整时必须拒绝修改")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            XCTAssertEqual(error, .invalidManagedBlock)
        }
    }

    func testConfigureReportsVerificationFailureClearly() async throws {
        let (configurator, _) = makeConfigurator(
            username: "erin",
            sshExitStatus: 255,
            sshStderr: "ssh: connect to host 127.0.0.1 port 22: Connection refused"
        )

        do {
            try await configurator.configure(verifyConnection: true)
            XCTFail("22 端口拒绝连接时必须报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .verificationFailed(let detail) = error else {
                return XCTFail("期望 verificationFailed，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("远程登录"))
        }
    }

    func testRemoveCleanlyRevertsManagedBlockAuthorizedKeyAndDedicatedKey() async throws {
        let (configurator, _) = makeConfigurator(username: "frank")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let originalConfig = "Host work\n    HostName 10.1.2.3\n"
        let originalAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeepMe keep@host\n"
        try originalConfig.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)
        try originalAuth.write(to: configurator.authorizedKeysURL, atomically: true, encoding: .utf8)

        try await configurator.configure(verifyConnection: true)
        let readyBeforeRemove = await configurator.inspect().isReady
        XCTAssertTrue(readyBeforeRemove)

        try await configurator.remove()

        let after = await configurator.inspect()
        XCTAssertFalse(after.isManaged)
        XCTAssertFalse(after.isReady)
        XCTAssertEqual(try String(contentsOf: configurator.sshConfigURL, encoding: .utf8), originalConfig)
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), originalAuth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.privateKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.publicKeyURL.path))
    }

    // MARK: - P1-1: Key Ownership & Fingerprint Verification

    func testP1_1RefusesUnknownPrivateKeyOnlyWithoutDeletingIt() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let sentinelPrivate = Data("USER-PRIVATE-KEY-DO-NOT-DELETE".utf8)
        try sentinelPrivate.write(to: configurator.privateKeyURL)

        let inspected = await configurator.inspect()
        XCTAssertTrue(inspected.hasConflictingKeyFiles)
        XCTAssertFalse(inspected.isReady)

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("仅有未知私钥时不得删除并应报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingKeyFiles = error else {
                return XCTFail("期望 conflictingKeyFiles，实际：\(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: configurator.privateKeyURL), sentinelPrivate)
    }

    func testP1_1RefusesCompleteUserOwnedKeyPairWithSameFilename() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        try await generateRawEd25519Key(at: configurator.privateKeyURL, comment: "user-personal-key")
        let originalPrivate = try Data(contentsOf: configurator.privateKeyURL)
        let originalPublic = try Data(contentsOf: configurator.publicKeyURL)

        let inspected = await configurator.inspect()
        XCTAssertTrue(inspected.hasConflictingKeyFiles)
        XCTAssertFalse(inspected.keyExists)
        XCTAssertFalse(inspected.isReady)

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("完整用户同名密钥不应被 Mimi 直接接管")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingKeyFiles = error else {
                return XCTFail("期望 conflictingKeyFiles，实际：\(error)")
            }
        }

        // 撤销也不得删除未确认归属的同名密钥。
        do {
            try await configurator.remove()
            XCTFail("撤销遇到无归属同名密钥时应报错并保留文件")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingKeyFiles = error else {
                return XCTFail("期望 conflictingKeyFiles，实际：\(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: configurator.privateKeyURL), originalPrivate)
        XCTAssertEqual(try Data(contentsOf: configurator.publicKeyURL), originalPublic)
    }

    func testP1_1DetectsReplacedKeyFileDuringInspectConfigureAndRemove() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try await configurator.configure(verifyConnection: false)
        let originalAuthEntry = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)

        // 用户用自己的另一把密钥替换了同名私钥。
        let replacementDir = tempHome.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementDir, withIntermediateDirectories: true)
        let replacementPriv = replacementDir.appendingPathComponent("new_key")
        try await generateRawEd25519Key(at: replacementPriv, comment: "replaced-by-user")
        let replacementData = try Data(contentsOf: replacementPriv)
        try FileManager.default.removeItem(at: configurator.privateKeyURL)
        try replacementData.write(to: configurator.privateKeyURL)
        _ = Darwin.chmod(configurator.privateKeyURL.path, 0o600)

        let inspected = await configurator.inspect()
        XCTAssertTrue(inspected.hasConflictingKeyFiles)
        XCTAssertFalse(inspected.keyExists)
        XCTAssertFalse(inspected.isReady)

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("密钥被替换后必须停止")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingKeyFiles = error else {
                return XCTFail("期望 conflictingKeyFiles，实际：\(error)")
            }
        }

        // remove 时：已被替换的私钥必须原样保留，已核验归属的公钥、授权行与 config 托管块应撤销，并报告密钥冲突。
        do {
            try await configurator.remove()
            XCTFail("被替换的私钥应报错并保留")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingKeyFiles = error else {
                return XCTFail("期望 conflictingKeyFiles，实际：\(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: configurator.privateKeyURL), replacementData, "用户替换后的私钥绝不能被删")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.publicKeyURL.path), "原属 Mimi 的公钥应已清理")
        let authAfterRemove = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
        XCTAssertNotEqual(authAfterRemove, originalAuthEntry)
        XCTAssertTrue(authAfterRemove.isEmpty)
    }

    func testP1_1ReconstructsMissingPublicKeyForVerifiedOwnedPrivateKey() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try await configurator.configure(verifyConnection: false)
        let originalPub = try String(contentsOf: configurator.publicKeyURL, encoding: .utf8)

        try FileManager.default.removeItem(at: configurator.publicKeyURL)
        try await configurator.configure(verifyConnection: false)

        let restoredPub = try String(contentsOf: configurator.publicKeyURL, encoding: .utf8)
        XCTAssertEqual(
            CodexLocalSSHConfigurator.extractPublicKeyBody(from: restoredPub),
            CodexLocalSSHConfigurator.extractPublicKeyBody(from: originalPub)
        )
        let inspected = await configurator.inspect()
        XCTAssertTrue(inspected.isReady)
    }

    // MARK: - P1-2: Structural authorized_keys Parsing, Scoping, Deduplication & Safe Removal

    func testP1_2RejectsUnrestrictedAndNonLoopbackSamePublicKeyAndPreservesUserLinesOnRemove() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try await configurator.configure(verifyConnection: false)
        let pubBody = try XCTUnwrap(
            CodexLocalSSHConfigurator.extractPublicKeyBody(
                from: try String(contentsOf: configurator.publicKeyURL, encoding: .utf8)
            )
        )

        // 1. 追加一条没有 from= 限制的同公钥授权行 -> 必须报告冲突，不得误判就绪。
        let unrestrictedLine = "\(pubBody) user-unrestricted"
        let currentAuth = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
        try (currentAuth + unrestrictedLine + "\n").write(to: configurator.authorizedKeysURL, atomically: true, encoding: .utf8)

        let inspected = await configurator.inspect()
        XCTAssertTrue(inspected.hasConflictingAuthorizedKey)
        XCTAssertFalse(inspected.isReady)

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("存在不受限同公钥授权时必须报告冲突")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingAuthorizedKey = error else {
                return XCTFail("期望 conflictingAuthorizedKey，实际：\(error)")
            }
        }

        // 撤销只删除 Mimi 实际写入的托管行，绝不删除用户自配的同公钥行。
        try await configurator.remove()
        let remaining = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
        XCTAssertEqual(remaining, unrestrictedLine + "\n")
    }

    func testP1_2HandlesDifferentOptionsMultipleSameKeyLinesAndSimilarComments() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try await configurator.configure(verifyConnection: false)
        let pubBody = try XCTUnwrap(
            CodexLocalSSHConfigurator.extractPublicKeyBody(
                from: try String(contentsOf: configurator.publicKeyURL, encoding: .utf8)
            )
        )
        let managedLine = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
            .trimmingCharacters(in: .newlines)

        // 其他密钥，但在注释与 command= 选项中刻意包含相似文本与 Mimi 公钥文本。
        let otherKeyBody = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyMaterial123456789012345678901234"
        let commentLine = "# \(managedLine)"
        let similarCommentLine = "\(otherKeyBody) from=\"127.0.0.1,::1\" \(pubBody) mimi-codex-local"
        let similarOptionLine = "from=\"10.0.0.1\",command=\"echo \(pubBody) mimi-codex-local\" \(otherKeyBody) ops"
        let userLoopbackSameKey = "from=\"127.0.0.1\",no-port-forwarding \(pubBody) user-local-copy"

        let combined = [
            commentLine,
            similarCommentLine,
            similarOptionLine,
            userLoopbackSameKey,
            managedLine,
        ].joined(separator: "\n") + "\n"
        try combined.write(to: configurator.authorizedKeysURL, atomically: true, encoding: .utf8)

        // 重复 configure 应幂等且保留所有已有条目及 from= 限制。
        try await configurator.configure(verifyConnection: false)
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), combined)

        // 测试带 command= 或非回环 from= 的同公钥行被识别为冲突。
        let badFromEval = CodexLocalSSHConfigurator.evaluateAuthorizedKeys(
            content: "from=\"127.0.0.1,10.0.0.9\" \(pubBody) bad\n",
            keyBody: pubBody,
            recordedEntry: managedLine
        )
        XCTAssertTrue(badFromEval.hasConflict)

        let badCommandEval = CodexLocalSSHConfigurator.evaluateAuthorizedKeys(
            content: "from=\"127.0.0.1\",command=\"/bin/false\" \(pubBody) bad\n",
            keyBody: pubBody,
            recordedEntry: managedLine
        )
        XCTAssertTrue(badCommandEval.hasConflict)

        // remove 只删 Mimi 实际写入的那一行；用户的同公钥行、注释与相似文本行均原样保留。
        try await configurator.remove()
        let expectedAfterRemove = [
            commentLine,
            similarCommentLine,
            similarOptionLine,
            userLoopbackSameKey,
        ].joined(separator: "\n") + "\n"
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), expectedAfterRemove)

        // 若仅有用户自建的同公钥回环条目（注释与附加选项不同），再次配置时按公钥内容识别重复，不追加重复行且保留原条目。
        let (dedupConfigurator, _) = makeConfigurator(username: "alice")
        try await dedupConfigurator.configure(verifyConnection: false)
        let dedupPubBody = try XCTUnwrap(
            CodexLocalSSHConfigurator.extractPublicKeyBody(
                from: try String(contentsOf: dedupConfigurator.publicKeyURL, encoding: .utf8)
            )
        )
        let customSameKeyOnly = "from=\"127.0.0.1\",no-agent-forwarding \(dedupPubBody) custom-comment\n"
        try customSameKeyOnly.write(to: dedupConfigurator.authorizedKeysURL, atomically: true, encoding: .utf8)
        try await dedupConfigurator.configure(verifyConnection: false)
        XCTAssertEqual(try String(contentsOf: dedupConfigurator.authorizedKeysURL, encoding: .utf8), customSameKeyOnly)
    }

    func testAuthorizedKeysDoesNotRelaxStrictExistingPermissionsAndDeduplicatesByKeyContent() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        _ = Darwin.chmod(configurator.sshDirectory.path, 0o700)

        let existingAuth = "from=\"10.0.0.2\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeepStrict123456789012345678901234 keep@host"
        try existingAuth.write(to: configurator.authorizedKeysURL, atomically: true, encoding: .utf8)
        _ = Darwin.chmod(configurator.authorizedKeysURL.path, 0o400)

        try await configurator.configure(verifyConnection: false)

        // 绝不把 0400 的 authorized_keys 放宽到 0600，也不放宽 ~/.ssh。
        XCTAssertEqual(try posixPermissions(of: configurator.authorizedKeysURL), 0o400)
        XCTAssertEqual(try posixPermissions(of: configurator.sshDirectory), 0o700)

        // 将公钥文件收紧到 0600 后再次运行 configure，也不得放宽回 0644。
        _ = Darwin.chmod(configurator.publicKeyURL.path, 0o600)
        try await configurator.configure(verifyConnection: false)
        XCTAssertEqual(try posixPermissions(of: configurator.publicKeyURL), 0o600)
        XCTAssertEqual(try posixPermissions(of: configurator.authorizedKeysURL), 0o400)

        // 末尾无换行的已有条目必须被正确分行保留，撤销后逐字节恢复且保持 0400。
        let authAfterConfigure = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
        XCTAssertTrue(authAfterConfigure.hasPrefix(existingAuth + "\nfrom=\"127.0.0.1,::1\" "))

        try await configurator.remove()
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), existingAuth)
        XCTAssertEqual(try posixPermissions(of: configurator.authorizedKeysURL), 0o400)
    }

    // MARK: - P1-3: Symlinks, Non-Regular Files, Backup Bytes & Permissions

    func testP1_3RejectsSymlinkConfigWithoutModifyingTargetContentOrPermissions() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)

        let dotfilesDir = tempHome.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfilesDir, withIntermediateDirectories: true)
        let targetConfig = dotfilesDir.appendingPathComponent("ssh_config")
        let targetContent = "Host dotfiles-host\n    HostName 10.10.10.10\n"
        try targetContent.write(to: targetConfig, atomically: true, encoding: .utf8)
        _ = Darwin.chmod(targetConfig.path, 0o644)

        try FileManager.default.createSymbolicLink(at: configurator.sshConfigURL, withDestinationURL: targetConfig)

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("符号链接 ~/.ssh/config 必须被安全拒绝")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .unsafeFileSystemTarget = error else {
                return XCTFail("期望 unsafeFileSystemTarget，实际：\(error)")
            }
        }

        // 链接目标的内容、权限必须原样保持，且不产生损坏的备份文件。
        XCTAssertEqual(try String(contentsOf: targetConfig, encoding: .utf8), targetContent)
        XCTAssertEqual(try posixPermissions(of: targetConfig), 0o644)
        let backups = try FileManager.default.contentsOfDirectory(atPath: configurator.sshDirectory.path)
            .filter { $0.hasPrefix("config.before-mimi.") }
        XCTAssertTrue(backups.isEmpty)
    }

    func testP1_3RejectsSymlinkSSHDirectoryAuthorizedKeysAndNonRegularConfig() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")

        // 1. ~/.ssh 为符号链接
        let realDir = tempHome.appendingPathComponent("real-ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        _ = Darwin.chmod(realDir.path, 0o755)
        try FileManager.default.createSymbolicLink(at: configurator.sshDirectory, withDestinationURL: realDir)

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("符号链接 ~/.ssh 必须被拒绝")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .unsafeFileSystemTarget = error else {
                return XCTFail("期望 unsafeFileSystemTarget，实际：\(error)")
            }
        }
        XCTAssertEqual(try posixPermissions(of: realDir), 0o755)
        try FileManager.default.removeItem(at: configurator.sshDirectory)

        // 2. ~/.ssh/authorized_keys 为符号链接
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let authTarget = tempHome.appendingPathComponent("external_authorized_keys")
        try "ssh-ed25519 AAAA... ext\n".write(to: authTarget, atomically: true, encoding: .utf8)
        _ = Darwin.chmod(authTarget.path, 0o644)
        try FileManager.default.createSymbolicLink(at: configurator.authorizedKeysURL, withDestinationURL: authTarget)

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("符号链接 authorized_keys 必须被拒绝")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .unsafeFileSystemTarget = error else {
                return XCTFail("期望 unsafeFileSystemTarget，实际：\(error)")
            }
        }
        XCTAssertEqual(try posixPermissions(of: authTarget), 0o644)
        try FileManager.default.removeItem(at: configurator.authorizedKeysURL)

        // 3. ~/.ssh/config 为非常规文件（目录）
        try FileManager.default.createDirectory(at: configurator.sshConfigURL, withIntermediateDirectories: false)
        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("非常规文件 ~/.ssh/config 必须被拒绝")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .unsafeFileSystemTarget = error else {
                return XCTFail("期望 unsafeFileSystemTarget，实际：\(error)")
            }
        }
    }

    // MARK: - P1-4: Real ssh -G Resolution, Precedence Over Host *, Quotes & Include

    func testP1_4OverridesPreexistingHostStarAndPreservesOtherHostsEffectiveSSHConfig() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)

        let existingConfig = """
        ServerAliveInterval 45

        Host *
            User ops
            Port 2222
            ProxyJump bastion.example.com
            ControlMaster auto
            ControlPath ~/.ssh/cm-%r@%h:%p
            RemoteCommand tmux attach

        Host prod
            HostName 10.0.0.5
        """
        try existingConfig.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)

        let prodBefore = try await configurator.resolveEffectiveSSHConfig(
            configPath: configurator.sshConfigURL.path,
            alias: "prod"
        )
        let otherBefore = try await configurator.resolveEffectiveSSHConfig(
            configPath: configurator.sshConfigURL.path,
            alias: "example.com"
        )

        try await configurator.configure(verifyConnection: false)

        let mimiAfter = try await configurator.resolveEffectiveSSHConfig(
            configPath: configurator.sshConfigURL.path,
            alias: CodexLocalSSHConfigurator.hostAlias
        )
        XCTAssertEqual(mimiAfter.hostname, "127.0.0.1")
        XCTAssertEqual(mimiAfter.port, "22")
        XCTAssertEqual(mimiAfter.user, "alice")
        XCTAssertEqual(mimiAfter.identitiesOnly?.lowercased(), "yes")
        XCTAssertEqual(mimiAfter.identityAgent?.lowercased(), "none")
        XCTAssertEqual(mimiAfter.identityFiles.first, configurator.expectedIdentityFileConfigValue)
        XCTAssertNil(mimiAfter.proxyJump)
        XCTAssertNil(mimiAfter.proxyCommand)
        XCTAssertEqual(mimiAfter.controlMaster?.lowercased(), "false")
        XCTAssertNil(mimiAfter.controlPath)
        XCTAssertNil(mimiAfter.remoteCommand)

        // 修改前后其他主机的有效选项必须完全一致（顶层指令也没有被吞进 Host mimi-local）。
        let prodAfter = try await configurator.resolveEffectiveSSHConfig(
            configPath: configurator.sshConfigURL.path,
            alias: "prod"
        )
        let otherAfter = try await configurator.resolveEffectiveSSHConfig(
            configPath: configurator.sshConfigURL.path,
            alias: "example.com"
        )
        XCTAssertEqual(prodAfter, prodBefore)
        XCTAssertEqual(otherAfter, otherBefore)

        // 撤销后恢复原始配置字节。
        try await configurator.remove()
        XCTAssertEqual(try String(contentsOf: configurator.sshConfigURL, encoding: .utf8), existingConfig)
    }

    func testP1_4DetectsQuotedHostAliasIncludedHostAliasAndMatchHostConflicts() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)

        // 1. 带引号的 Host "mimi-local"
        try "Host \"mimi-local\"\n    HostName 203.0.113.10\n"
            .write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)
        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("带引号的 Host \"mimi-local\" 必须判为冲突")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            XCTAssertEqual(error, .conflictingHostAlias("mimi-local"))
        }

        // 2. Include 子文件中的 Host mimi-local
        let confDir = configurator.sshDirectory.appendingPathComponent("conf.d", isDirectory: true)
        try FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        try "Host mimi-local\n    HostName 198.51.100.7\n"
            .write(to: confDir.appendingPathComponent("custom.conf"), atomically: true, encoding: .utf8)
        try "Include conf.d/*.conf\nHost work\n    HostName 10.0.0.9\n"
            .write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)

        let inspectedInclude = await configurator.inspect()
        XCTAssertTrue(inspectedInclude.hasConflictingHostAlias)
        XCTAssertFalse(inspectedInclude.isReady)

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("Include 中的 Host mimi-local 必须判为冲突")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            XCTAssertEqual(error, .conflictingHostAlias("mimi-local"))
        }

        // 3. Match host mimi-local
        try "Match host mimi-local\n    HostName 198.51.100.8\n"
            .write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)
        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("Match host mimi-local 必须判为冲突")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            XCTAssertEqual(error, .conflictingHostAlias("mimi-local"))
        }
    }

    // MARK: - P1-6: Concurrency Serialization, Mid-way Rollback, External Edit & Corrupted Remove

    func testP1_6ConcurrentConfigureCallsAreSerializedAndIdempotent() async throws {
        let (configurator, recorder) = makeConfigurator(username: "alice")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await configurator.configure(verifyConnection: true)
                }
            }
            try await group.waitForAll()
        }

        let inspected = await configurator.inspect()
        XCTAssertTrue(inspected.isReady)

        let authLines = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(authLines.count, 1, "并发调用不得重复写入多条授权行")

        let calls = await recorder.calls
        let keygenCreates = calls.filter { $0.executable == "/usr/bin/ssh-keygen" && $0.arguments.contains("-t") }
        XCTAssertEqual(keygenCreates.count, 1, "并发调用只能生成一次密钥")
    }

    func testP1_6SecondWriteFailureRollsBackFirstWriteAndGeneratedKeys() async throws {
        try FileManager.default.createDirectory(
            at: tempHome.appendingPathComponent(".ssh", isDirectory: true),
            withIntermediateDirectories: true
        )
        let originalConfig = "Host keep\n    HostName 10.2.3.4\n"
        let originalAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUserKeep12345678901234567890123456789 keep@host\n"
        let sshDir = tempHome.appendingPathComponent(".ssh", isDirectory: true)
        let configURL = sshDir.appendingPathComponent("config")
        let authURL = sshDir.appendingPathComponent("authorized_keys")
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        try originalAuth.write(to: authURL, atomically: true, encoding: .utf8)

        let (configurator, _) = makeConfigurator(
            username: "alice",
            beforeAtomicCommit: { targetURL in
                if targetURL.lastPathComponent == "authorized_keys" {
                    throw CodexLocalSSHConfigurator.ConfigError.fileOperationFailed("模拟第二次写入失败")
                }
            }
        )

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("第二次写入失败必须抛出错误")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            XCTAssertEqual(error, .fileOperationFailed("模拟第二次写入失败"))
        }

        // 第一次写入的 ~/.ssh/config 与新建密钥必须已完整回滚，且 authorized_keys 保持原样。
        XCTAssertEqual(try String(contentsOf: configurator.sshConfigURL, encoding: .utf8), originalConfig)
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), originalAuth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.privateKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.publicKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.stateFileURL.path))
    }

    func testP1_6ExternalEditBeforeCommitAbortsWithoutOverwritingAndRollsBack() async throws {
        let sshDir = tempHome.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let originalConfig = "Host keep\n    HostName 10.2.3.4\n"
        let originalAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUserKeep12345678901234567890123456789 keep@host\n"
        let externalAuthEdit = originalAuth + "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExternalEdit123456789012345678901234 ext@host\n"
        try originalConfig.write(to: sshDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try originalAuth.write(to: sshDir.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)

        let (configurator, _) = makeConfigurator(
            username: "alice",
            beforeAtomicCommit: { targetURL in
                if targetURL.lastPathComponent == "authorized_keys" {
                    // 模拟提交前瞬间其他进程修改了 authorized_keys。
                    try externalAuthEdit.write(to: targetURL, atomically: true, encoding: .utf8)
                }
            }
        )

        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("检测到外部编辑时必须中止")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .concurrentModification = error else {
                return XCTFail("期望 concurrentModification，实际：\(error)")
            }
        }

        // 外部编辑必须被完整保留，Mimi 写入的 config 与新建密钥必须已回滚。
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), externalAuthEdit)
        XCTAssertEqual(try String(contentsOf: configurator.sshConfigURL, encoding: .utf8), originalConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.privateKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.publicKeyURL.path))
    }

    func testP1_6RemoveStillRevokesAuthorizedKeyAndOwnedKeyWhenConfigMarkersCorrupted() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let keepAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUserKeep12345678901234567890123456789 keep@host\n"
        try keepAuth.write(to: configurator.authorizedKeysURL, atomically: true, encoding: .utf8)

        try await configurator.configure(verifyConnection: false)

        // 破坏 ~/.ssh/config 的结束标记。
        let brokenConfig = "\(CodexLocalSSHConfigurator.managedBlockStart)\nHost mimi-local\n    HostName 127.0.0.1\n"
        try brokenConfig.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)

        do {
            try await configurator.remove()
            XCTFail("配置标记损坏时仍应向调用方报告 invalidManagedBlock")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            XCTAssertEqual(error, .invalidManagedBlock)
        }

        // 尽管 config 标记损坏，authorized_keys 里的托管授权与 Mimi 专用密钥必须已经撤销！
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), keepAuth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.privateKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.publicKeyURL.path))
        XCTAssertEqual(try String(contentsOf: configurator.sshConfigURL, encoding: .utf8), brokenConfig)
    }

    // MARK: - P2-1: Byte-for-Byte Round Trip (CRLF, No Trailing Newline, Leading/Trailing Blank Lines)

    func testP2_1ByteForByteRoundTripPreservesCRLFNoTrailingNewlineAndLeadingTrailingBlankLines() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)

        let originalConfig = "\r\n\r\nHost prod\r\n    HostName 10.0.0.5\r\n    User deploy\r\n\r\n# no-trailing-newline"
        let originalAuth = "\r\n# user header\r\nfrom=\"10.0.0.1\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeepOne1234567890123456789012345678 one@host\r\n\r\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeepTwo1234567890123456789012345678 two@host"
        let originalConfigData = Data(originalConfig.utf8)
        let originalAuthData = Data(originalAuth.utf8)

        try originalConfigData.write(to: configurator.sshConfigURL)
        try originalAuthData.write(to: configurator.authorizedKeysURL)

        try await configurator.configure(verifyConnection: false)
        try await configurator.remove()

        XCTAssertEqual(try Data(contentsOf: configurator.sshConfigURL), originalConfigData)
        XCTAssertEqual(try Data(contentsOf: configurator.authorizedKeysURL), originalAuthData)
    }

    // MARK: - Round 2 P1 Regressions

    /// R2 P1-1: authorized_keys 写回失败后，密钥虽已删除，但重试 remove() 不得跳过残留授权，且 inspect().isManaged 保持 true。
    func testR2_P1_1RevokeRetryStillRemovesResidualAuthorizedKeyAfterWriteBackFailure() async throws {
        let (setupConfigurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: setupConfigurator.sshDirectory, withIntermediateDirectories: true)
        let userAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUserStay1234567890123456789012345678 user@host\n"
        try userAuth.write(to: setupConfigurator.authorizedKeysURL, atomically: true, encoding: .utf8)
        try await setupConfigurator.configure(verifyConnection: false)

        // 第一次 remove：authorized_keys 写回失败，但密钥与 config 随后被清理。
        let (failingRemover, _) = makeConfigurator(
            username: "alice",
            beforeAtomicCommit: { targetURL in
                if targetURL.lastPathComponent == "authorized_keys" {
                    throw CodexLocalSSHConfigurator.ConfigError.fileOperationFailed("模拟 authorized_keys 写回失败")
                }
            }
        )
        do {
            try await failingRemover.remove()
            XCTFail("authorized_keys 写回失败必须报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            XCTAssertEqual(error, .fileOperationFailed("模拟 authorized_keys 写回失败"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: setupConfigurator.privateKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: setupConfigurator.publicKeyURL.path))
        let authAfterFirstFail = try String(contentsOf: setupConfigurator.authorizedKeysURL, encoding: .utf8)
        XCTAssertTrue(authAfterFirstFail.contains(CodexLocalSSHConfigurator.keyComment), "写回失败时托管授权仍残留")

        // 此时界面必须保留撤销入口（isManaged == true），且不误报就绪。
        let inspectedMid = await setupConfigurator.inspect()
        XCTAssertTrue(inspectedMid.isManaged, "残留托管授权存在时 isManaged 必须为 true，不能丢失撤销入口")
        XCTAssertTrue(inspectedMid.hasRecordedAuthorizedEntry)
        XCTAssertFalse(inspectedMid.isReady)

        // 第二次重试 remove()：必须成功撤销残留授权并清除状态文件。
        try await setupConfigurator.remove()
        XCTAssertEqual(try String(contentsOf: setupConfigurator.authorizedKeysURL, encoding: .utf8), userAuth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setupConfigurator.stateFileURL.path))
        let inspectedAfter = await setupConfigurator.inspect()
        XCTAssertFalse(inspectedAfter.isManaged)
    }

    /// R2 P1-2: CRLF 分行不得漏检注释后的无限制授权、转成 CRLF 的托管行、CRLF 同名 Host 或顶层全局 Port。
    func testR2_P1_2CRLFConflictRevocationAndOtherHostsEffectiveOptions() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)

        // 1. 带首行注释和全局 Port 2222 的 CRLF 配置：配置前后其他主机有效选项必须完全一致（Port 仍是 2222）。
        let crlfGlobalConfig = "# top comment\r\nPort 2222\r\n\r\nHost prod\r\n    HostName 10.0.0.5\r\n"
        try Data(crlfGlobalConfig.utf8).write(to: configurator.sshConfigURL)

        let prodBefore = try await configurator.resolveEffectiveSSHConfig(configPath: configurator.sshConfigURL.path, alias: "prod")
        let otherBefore = try await configurator.resolveEffectiveSSHConfig(configPath: configurator.sshConfigURL.path, alias: "example.com")
        XCTAssertEqual(prodBefore.port, "2222")
        XCTAssertEqual(otherBefore.port, "2222")

        try await configurator.configure(verifyConnection: false)

        let prodAfter = try await configurator.resolveEffectiveSSHConfig(configPath: configurator.sshConfigURL.path, alias: "prod")
        let otherAfter = try await configurator.resolveEffectiveSSHConfig(configPath: configurator.sshConfigURL.path, alias: "example.com")
        XCTAssertEqual(prodAfter, prodBefore, "CRLF 配置含首行注释和顶层 Port 时，无关主机有效选项绝不能变")
        XCTAssertEqual(otherAfter, otherBefore)

        // 2. 将 authorized_keys 转为 CRLF，并在注释后追加同公钥无限制授权 -> 必须检出冲突。
        let pubBody = try XCTUnwrap(
            CodexLocalSSHConfigurator.extractPublicKeyBody(
                from: try String(contentsOf: configurator.publicKeyURL, encoding: .utf8)
            )
        )
        let managedAuthLine = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        let crlfAuthWithConflict = "# comment\r\n\(pubBody) unrestricted-after-comment\r\n\(managedAuthLine)\r\n"
        try Data(crlfAuthWithConflict.utf8).write(to: configurator.authorizedKeysURL)

        let conflictInspect = await configurator.inspect()
        XCTAssertTrue(conflictInspect.hasConflictingAuthorizedKey, "CRLF 注释后的同公钥无限制授权不得漏检")
        XCTAssertFalse(conflictInspect.isReady)
        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("CRLF 无限制同公钥授权必须报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingAuthorizedKey = error else {
                return XCTFail("期望 conflictingAuthorizedKey，实际：\(error)")
            }
        }

        // 3. 转成 CRLF 的托管授权行在 remove() 时必须被精准移除，同时保留用户 CRLF 行与原始 CRLF config。
        try await configurator.remove()
        XCTAssertEqual(
            try Data(contentsOf: configurator.authorizedKeysURL),
            Data("# comment\r\n\(pubBody) unrestricted-after-comment\r\n".utf8),
            "CRLF 托管授权行必须被撤销，其余 CRLF 行逐字节保留"
        )
        XCTAssertEqual(try Data(contentsOf: configurator.sshConfigURL), Data(crlfGlobalConfig.utf8))

        // 4. CRLF 配置中注释后的同名 Host mimi-local 必须被检出冲突。
        let crlfAliasConflict = "# leading comment\r\nHost mimi-local\r\n    HostName 198.51.100.42\r\n"
        try Data(crlfAliasConflict.utf8).write(to: configurator.sshConfigURL)
        let aliasInspect = await configurator.inspect()
        XCTAssertTrue(aliasInspect.hasConflictingHostAlias, "CRLF 注释后的同名 Host 不得漏检")
        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("CRLF 同名 Host 必须判为冲突")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            XCTAssertEqual(error, .conflictingHostAlias("mimi-local"))
        }
    }

    /// R2 P1-3: 密钥在独占临时目录生成并逐个禁止覆盖发布；发布 .pub 遇同名文件时保留原文件并回滚刚发布的私钥；删除前快照变化时保留文件。
    func testR2_P1_3KeyPublishNoOverwriteRollbackAndDeleteSnapshotGuard() async throws {
        // 1. 发布 .pub 前瞬间出现同名用户公钥 -> 拒绝覆盖且回滚已发布的私钥。
        let userPubSentinel = Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUserPubSentinel123456789012345678901234 user-pub\n".utf8)
        let (racyConfig, _) = makeConfigurator(
            username: "alice",
            beforeAtomicCommit: { targetURL in
                if targetURL.lastPathComponent == "\(CodexLocalSSHConfigurator.keyFileName).pub" {
                    try userPubSentinel.write(to: targetURL)
                }
            }
        )
        do {
            try await racyConfig.configure(verifyConnection: false)
            XCTFail("发布 .pub 时出现同名文件必须报错且不得覆盖")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingKeyFiles = error else {
                return XCTFail("期望 conflictingKeyFiles，实际：\(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: racyConfig.publicKeyURL), userPubSentinel, "并发出现的 .pub 绝不能被覆盖")
        XCTAssertFalse(FileManager.default.fileExists(atPath: racyConfig.privateKeyURL.path), "刚发布的私钥必须随回滚清理")
        XCTAssertFalse(FileManager.default.fileExists(atPath: racyConfig.stateFileURL.path))

        // 清理 sentinel 后正常配置，再测试 remove() 异步验指纹后、删除前私钥被替换的竞态。
        try FileManager.default.removeItem(at: racyConfig.publicKeyURL)
        let (normalConfig, _) = makeConfigurator(username: "alice")
        try await normalConfig.configure(verifyConnection: false)

        let replacementSentinel = Data("USER-REPLACED-PRIVATE-KEY-AFTER-VERIFY\n".utf8)
        let (racyRemover, _) = makeConfigurator(
            username: "alice",
            beforeAtomicCommit: { targetURL in
                if targetURL.lastPathComponent == CodexLocalSSHConfigurator.keyFileName {
                    try FileManager.default.removeItem(at: targetURL)
                    try replacementSentinel.write(to: targetURL)
                    _ = Darwin.chmod(targetURL.path, 0o600)
                }
            }
        )
        do {
            try await racyRemover.remove()
            XCTFail("删除前私钥被替换为不同文件时必须中止删除并报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingKeyFiles = error else {
                return XCTFail("期望 conflictingKeyFiles，实际：\(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: normalConfig.privateKeyURL), replacementSentinel, "校验后被替换的同名文件绝不能被误删")
    }

    /// R2 P1-4: 首连验连使用经校验的应用专用主机信任文件，绝不改动 `~/.ssh/known_hosts` 符号链接目标；专用文件为链接时安全拒绝。
    func testR2_P1_4FirstConnectionNeverTouchesSymlinkKnownHostsAndRejectsSymlinkDedicatedFile() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)

        let dotfilesDir = tempHome.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfilesDir, withIntermediateDirectories: true)
        let dotfilesKnownHosts = dotfilesDir.appendingPathComponent("known_hosts")
        let originalKH = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGitHubHostKey\n"
        try originalKH.write(to: dotfilesKnownHosts, atomically: true, encoding: .utf8)
        _ = Darwin.chmod(dotfilesKnownHosts.path, 0o644)
        let userKnownHosts = configurator.sshDirectory.appendingPathComponent("known_hosts")
        try FileManager.default.createSymbolicLink(at: userKnownHosts, withDestinationURL: dotfilesKnownHosts)

        try await configurator.configure(verifyConnection: true)

        // 用户 dotfiles known_hosts 链接目标内容和权限必须完全原样不变。
        XCTAssertEqual(try String(contentsOf: dotfilesKnownHosts, encoding: .utf8), originalKH)
        XCTAssertEqual(try posixPermissions(of: dotfilesKnownHosts), 0o644)

        // ssh -G 必须解析到应用专用主机信任文件。
        let effective = try await configurator.resolveEffectiveSSHConfig(
            configPath: configurator.sshConfigURL.path,
            alias: CodexLocalSSHConfigurator.hostAlias
        )
        XCTAssertEqual(effective.userKnownHostsFile, configurator.expectedKnownHostsPath)

        // 撤销后清理应用专用主机信任文件。
        try await configurator.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.knownHostsURL.path))

        // 若应用专用主机信任路径本身被替换成符号链接，必须拒绝操作且不改动目标。
        try FileManager.default.createDirectory(
            at: configurator.knownHostsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: configurator.knownHostsURL, withDestinationURL: dotfilesKnownHosts)
        do {
            try await configurator.configure(verifyConnection: false)
            XCTFail("应用专用 known_hosts 为符号链接时必须拒绝")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .unsafeFileSystemTarget = error else {
                return XCTFail("期望 unsafeFileSystemTarget，实际：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: dotfilesKnownHosts, encoding: .utf8), originalKH)
        XCTAssertEqual(try posixPermissions(of: dotfilesKnownHosts), 0o644)
    }

    /// R2 P1-5: 桌面版实际解析路径（含后续 Host * 与系统 ssh_config）出现额外 IdentityFile 时必须在写入前停止；Host * 的禁用公钥和转发必须被锁定。
    func testR2_P1_5DetectsExtraIdentityFileInUserAndSystemConfigAndLocksAuthAndForwardings() async throws {
        // 1. 后续 Host * 添加额外 IdentityFile -> 写入前必须停止且不创建任何新文件。
        let (userExtraConfig, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: userExtraConfig.sshDirectory, withIntermediateDirectories: true)
        let extraIdentityConfig = """
        Host *
            IdentityFile ~/.ssh/id_extra
        """
        try extraIdentityConfig.write(to: userExtraConfig.sshConfigURL, atomically: true, encoding: .utf8)

        do {
            try await userExtraConfig.configure(verifyConnection: false)
            XCTFail("后续 Host * 带来额外 IdentityFile 时必须在写入前停止")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .effectiveConfigConflict(let detail) = error else {
                return XCTFail("期望 effectiveConfigConflict，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("IdentityFile"))
        }
        XCTAssertEqual(try String(contentsOf: userExtraConfig.sshConfigURL, encoding: .utf8), extraIdentityConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userExtraConfig.privateKeyURL.path))

        // 2. 系统 ssh_config 添加额外 IdentityFile -> 走桌面版解析路径必须在写入前检出并停止。
        let fakeSysConfig = tempHome.appendingPathComponent("system_ssh_config")
        try "Host *\n    IdentityFile ~/.ssh/system_extra\n".write(to: fakeSysConfig, atomically: true, encoding: .utf8)
        let (sysConflictConfig, _) = makeConfigurator(username: "alice", systemSSHConfigPath: fakeSysConfig.path)
        try FileManager.default.removeItem(at: sysConflictConfig.sshConfigURL)

        do {
            try await sysConflictConfig.configure(verifyConnection: false)
            XCTFail("系统 ssh_config 带来额外 IdentityFile 时必须在写入前停止")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .effectiveConfigConflict = error else {
                return XCTFail("期望 effectiveConfigConflict，实际：\(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sysConflictConfig.sshConfigURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sysConflictConfig.privateKeyURL.path))

        // 3. 后续 Host * 设置 PubkeyAuthentication no 及各类端口/X11 转发 -> 托管块必须成功锁定且 ssh -G 全部通过。
        let (lockedConfig, _) = makeConfigurator(username: "alice")
        let hostileHostStar = """
        Host *
            PubkeyAuthentication no
            LocalForward 8080 127.0.0.1:80
            RemoteForward 9090 127.0.0.1:90
            DynamicForward 1080
            ForwardX11 yes
            ForwardAgent yes
        """
        try hostileHostStar.write(to: lockedConfig.sshConfigURL, atomically: true, encoding: .utf8)
        try await lockedConfig.configure(verifyConnection: false)

        let effective = try await lockedConfig.resolveEffectiveSSHConfig(
            configPath: lockedConfig.sshConfigURL.path,
            alias: CodexLocalSSHConfigurator.hostAlias
        )
        XCTAssertEqual(effective.identityFiles, [lockedConfig.expectedIdentityFileConfigValue])
        XCTAssertEqual(effective.pubkeyAuthentication?.lowercased(), "true")
        XCTAssertTrue(effective.localForwards.isEmpty)
        XCTAssertTrue(effective.remoteForwards.isEmpty)
        XCTAssertTrue(effective.dynamicForwards.isEmpty)
        XCTAssertEqual(effective.forwardX11?.lowercased(), "no")
        XCTAssertEqual(effective.forwardAgent?.lowercased(), "no")
    }

    /// R2 P1-7: 最终验连失败事务性回滚所有新建文件；更新已有托管块后失败时恢复旧托管块并保留外部编辑。
    func testR2_P1_7FinalVerificationFailureAndUpdatingExistingBlockFailureRollBackTransactionally() async throws {
        // 1. 首次配置在最终验连失败 -> 新密钥、新授权、新配置块、known_hosts 与状态文件必须全部回滚。
        let sshDir = tempHome.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let origConfig = "Host work\n    HostName 10.0.0.8\n"
        let origAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOrigKeep1234567890123456789012345678 orig@host\n"
        try origConfig.write(to: sshDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try origAuth.write(to: sshDir.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)

        let (failingVerify, _) = makeConfigurator(
            username: "alice",
            sshExitStatus: 255,
            sshStderr: "Permission denied (publickey)."
        )
        do {
            try await failingVerify.configure(verifyConnection: true)
            XCTFail("最终验连失败必须抛出 verificationFailed")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .verificationFailed = error else {
                return XCTFail("期望 verificationFailed，实际：\(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("已回滚"))
        }

        XCTAssertEqual(try String(contentsOf: failingVerify.sshConfigURL, encoding: .utf8), origConfig, "验连失败后 config 必须完整回滚")
        XCTAssertEqual(try String(contentsOf: failingVerify.authorizedKeysURL, encoding: .utf8), origAuth, "验连失败后不得残留新授权")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failingVerify.privateKeyURL.path), "验连失败后不得残留新私钥")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failingVerify.publicKeyURL.path), "验连失败后不得残留新公钥")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failingVerify.knownHostsURL.path), "验连失败后不得残留新建 known_hosts")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failingVerify.stateFileURL.path), "验连失败后不得残留 state 文件")

        // 2. 已有托管块（User alice）更新为 User bob，但在更新后验连失败 -> 必须恢复旧托管块（User alice），绝不删掉原托管块。
        let (initialAlice, _) = makeConfigurator(username: "alice")
        try await initialAlice.configure(verifyConnection: false)
        let aliceConfigBeforeUpdate = try String(contentsOf: initialAlice.sshConfigURL, encoding: .utf8)
        let aliceAuthBeforeUpdate = try String(contentsOf: initialAlice.authorizedKeysURL, encoding: .utf8)
        XCTAssertTrue(aliceConfigBeforeUpdate.contains("User alice"))

        let (failingBobUpdate, _) = makeConfigurator(
            username: "bob",
            sshExitStatus: 255,
            sshStderr: "Connection refused"
        )
        do {
            try await failingBobUpdate.configure(verifyConnection: true)
            XCTFail("更新托管块后验连失败必须报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .verificationFailed = error else {
                return XCTFail("期望 verificationFailed，实际：\(error)")
            }
        }
        XCTAssertEqual(
            try String(contentsOf: initialAlice.sshConfigURL, encoding: .utf8),
            aliceConfigBeforeUpdate,
            "更新已有托管块失败回滚后必须恢复旧托管块（User alice），不能把旧托管块删掉"
        )
        XCTAssertEqual(try String(contentsOf: initialAlice.authorizedKeysURL, encoding: .utf8), aliceAuthBeforeUpdate)

        // 3. 更新已有托管块期间出现外部编辑后授权写入失败 -> 既恢复旧托管块（User alice），又保留外部新增 Host！
        let externalSuffix = "\nHost added-externally\n    HostName 10.9.9.9\n"
        // 删除原授权行迫使本次更新需要写 authorized_keys，同时在写入 authorized_keys 前向 config 追加外部编辑并失败。
        try origAuth.write(to: initialAlice.authorizedKeysURL, atomically: true, encoding: .utf8)
        let (failingUpdateWithExternalEdit, _) = makeConfigurator(
            username: "bob",
            beforeAtomicCommit: { targetURL in
                if targetURL.lastPathComponent == "authorized_keys" {
                    let cur = try String(contentsOf: initialAlice.sshConfigURL, encoding: .utf8)
                    try (cur + externalSuffix).write(to: initialAlice.sshConfigURL, atomically: true, encoding: .utf8)
                    throw CodexLocalSSHConfigurator.ConfigError.fileOperationFailed("模拟更新期间授权写入失败")
                }
            }
        )
        do {
            try await failingUpdateWithExternalEdit.configure(verifyConnection: false)
            XCTFail("模拟授权写入失败必须报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            XCTAssertEqual(error, .fileOperationFailed("模拟更新期间授权写入失败"))
        }
        let configAfterExternalRollback = try String(contentsOf: initialAlice.sshConfigURL, encoding: .utf8)
        XCTAssertTrue(configAfterExternalRollback.contains("User alice"), "旧托管块必须被恢复")
        XCTAssertFalse(configAfterExternalRollback.contains("User bob"), "失败的新托管块不得残留")
        XCTAssertTrue(configAfterExternalRollback.contains("Host added-externally"), "回滚必须保留外部编辑")
    }

    // MARK: - Round 3 P1 & P2 Regressions

    /// R3 P1-1: 专用 known_hosts 变符号链接或 authorized_keys 不可读/不可解码时，inspect 必须保留撤销入口，remove 必须先撤销有效授权再独立报告信任文件错误。
    func testR3_P1_1RevokeAndInspectKeepEntryWhenKnownHostsIsSymlinkOrAuthUnreadable() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let keepAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeepAlice1234567890123456789012345678 alice@host\n"
        try keepAuth.write(to: configurator.authorizedKeysURL, atomically: true, encoding: .utf8)
        try await configurator.configure(verifyConnection: false)

        // 1. 专用 known_hosts 变成符号链接：inspect 必须标记不安全但保留 isManaged == true；remove 必须先撤销授权、密钥和 config，再报 known_hosts 错误。
        let sentinel = tempHome.appendingPathComponent("sentinel-known-hosts")
        try "KEEP-SENTINEL\n".write(to: sentinel, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: configurator.knownHostsURL)
        try FileManager.default.createSymbolicLink(at: configurator.knownHostsURL, withDestinationURL: sentinel)

        let inspectedWithSymlink = await configurator.inspect()
        XCTAssertTrue(inspectedWithSymlink.hasUnsafeFileSystemState)
        XCTAssertFalse(inspectedWithSymlink.isReady)
        XCTAssertTrue(inspectedWithSymlink.isManaged, "known_hosts 为符号链接时不得隐藏移除入口")
        XCTAssertTrue(inspectedWithSymlink.hasRecordedAuthorizedEntry)

        do {
            try await configurator.remove()
            XCTFail("known_hosts 为符号链接时 remove 必须独立报告 unsafeFileSystemTarget")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .unsafeFileSystemTarget = error else {
                return XCTFail("期望 unsafeFileSystemTarget，实际：\(error)")
            }
        }
        // 关键：在报告 known_hosts 错误前，authorized_keys 里的托管授权、密钥与 config 托管块必须已全部撤销！
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), keepAuth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.privateKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.publicKeyURL.path))
        XCTAssertEqual(try String(contentsOf: configurator.sshConfigURL, encoding: .utf8), "")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "KEEP-SENTINEL\n", "不得删除或修改符号链接目标")

        // 2. 清理符号链接后重新配置，然后清理密钥和 config、仅保留 state 与不可解码的 authorized_keys -> inspect 仍须保留撤销入口。
        try FileManager.default.removeItem(at: configurator.knownHostsURL)
        try await configurator.configure(verifyConnection: false)
        try FileManager.default.removeItem(at: configurator.privateKeyURL)
        try FileManager.default.removeItem(at: configurator.publicKeyURL)
        try FileManager.default.removeItem(at: configurator.sshConfigURL)
        try FileManager.default.removeItem(at: configurator.knownHostsURL)
        let originalAuthData = try Data(contentsOf: configurator.authorizedKeysURL)
        try Data([0xFF, 0xFE, 0x00]).write(to: configurator.authorizedKeysURL)

        let inspectedBadUTF8 = await configurator.inspect()
        XCTAssertFalse(inspectedBadUTF8.isReady)
        XCTAssertTrue(inspectedBadUTF8.isManaged, "authorized_keys 无法解码但持久化记录仍有托管授权时，不得隐藏移除入口")
        XCTAssertTrue(inspectedBadUTF8.hasRecordedAuthorizedEntry)

        // 恢复可读有效 UTF-8 后再次 remove() 必须彻底撤销。
        try originalAuthData.write(to: configurator.authorizedKeysURL)
        try await configurator.remove()
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), keepAuth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.stateFileURL.path))
    }

    /// R3 P1-2: 仅剩公钥恢复路径必须贯穿使用计划阶段已核验指纹的快照，删除前若文件被替换为其他公钥则拒绝误删。
    func testR3_P1_2OrphanPublicKeyRecoveryUsesVerifiedSnapshotAndNeverDeletesReplacement() async throws {
        let (setupConfigurator, _) = makeConfigurator(username: "alice")
        try await setupConfigurator.configure(verifyConnection: false)
        // 删除私钥，仅留 Mimi 归属公钥。
        try FileManager.default.removeItem(at: setupConfigurator.privateKeyURL)

        let replacementPub = Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUserReplacementPub123456789012345678901 user-replacement\n".utf8)
        let (racyRecover, _) = makeConfigurator(
            username: "alice",
            beforeAtomicCommit: { targetURL in
                if targetURL.lastPathComponent == "\(CodexLocalSSHConfigurator.keyFileName).pub" {
                    try FileManager.default.removeItem(at: targetURL)
                    try replacementPub.write(to: targetURL)
                    _ = Darwin.chmod(targetURL.path, 0o644)
                }
            }
        )
        do {
            try await racyRecover.configure(verifyConnection: false)
            XCTFail("仅剩公钥在核验后、删除前被替换时必须停止且不得误删替换文件")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingKeyFiles = error else {
                return XCTFail("期望 conflictingKeyFiles，实际：\(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: setupConfigurator.publicKeyURL), replacementPub, "被替换的同名公钥必须原样保留")
    }

    /// R3 P1-3: 最终验连必须绑定到刚核验的冻结快照，并显式固定回环地址、端口、当前用户、专用密钥与专用 known_hosts。
    func testR3_P1_3FinalVerifyBindsToVerifiedSnapshotAndPinsTargetIdentityAndKnownHosts() async throws {
        let (configurator, recorder) = makeConfigurator(username: "alice")
        try await configurator.configure(verifyConnection: true)

        let calls = await recorder.calls
        let verifyCall = try XCTUnwrap(calls.last(where: { $0.executable == "/usr/bin/ssh" && $0.arguments.first != "-G" }))
        let args = verifyCall.arguments
        XCTAssertEqual(args.first, "-F", "最终验连必须绑定到刚核验的冻结快照文件而非重新读取实时 ~/.ssh/config")
        XCTAssertNotEqual(args[1], configurator.sshConfigURL.path, "最终验连应使用独立冻结快照而非实时 ~/.ssh/config")
        XCTAssertTrue(args.contains("-T"))
        XCTAssertTrue(args.contains("HostName=127.0.0.1"))
        XCTAssertTrue(args.contains("Port=22"))
        XCTAssertTrue(args.contains("User=alice"))
        XCTAssertTrue(args.contains("IdentityFile=\"\(configurator.privateKeyURL.path)\""))
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
        let ukhArg = try XCTUnwrap(args.first(where: { $0.hasPrefix("UserKnownHostsFile=") }))
        XCTAssertFalse(ukhArg.contains(configurator.expectedKnownHostsPath), "验连必须使用事务内专用信任副本而非实时 known_hosts")
        XCTAssertTrue(args.contains("GlobalKnownHostsFile=none"))
        XCTAssertTrue(args.contains("KnownHostsCommand=none"))
        XCTAssertTrue(args.contains("VerifyHostKeyDNS=no"))
        XCTAssertTrue(args.contains("UpdateHostKeys=no"))
        XCTAssertTrue(args.contains("ProxyJump=none"))
        XCTAssertTrue(args.contains("ProxyCommand=none"))
        XCTAssertEqual(args.last, "/bin/cat")
    }

    /// R3 P1-4: 锁定并校验 StdinNull/RequestTTY/SessionType/ForkAfterAuthentication；双向握手失败必须回滚；系统配置相对 Include 按系统目录解析。
    func testR3_P1_4StdinNullBidirectionalHandshakeAndSystemRelativeInclude() async throws {
        // 1. 后续 Host * 设置 StdinNull yes / RequestTTY force / SessionType none / ForkAfterAuthentication yes -> 托管块必须成功锁定。
        let (lockedConfig, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: lockedConfig.sshDirectory, withIntermediateDirectories: true)
        let hostileTransport = """
        Host *
            StdinNull yes
            RequestTTY force
            SessionType none
            ForkAfterAuthentication yes
        """
        try hostileTransport.write(to: lockedConfig.sshConfigURL, atomically: true, encoding: .utf8)
        try await lockedConfig.configure(verifyConnection: true)

        let effective = try await lockedConfig.resolveEffectiveSSHConfig(
            configPath: lockedConfig.sshConfigURL.path,
            alias: CodexLocalSSHConfigurator.hostAlias
        )
        XCTAssertEqual(effective.stdinNull?.lowercased(), "no")
        XCTAssertEqual(effective.requestTTY?.lowercased(), "auto")
        XCTAssertEqual(effective.sessionType?.lowercased(), "default")
        XCTAssertEqual(effective.forkAfterAuthentication?.lowercased(), "no")

        // 2. 校验函数必须拒绝 StdinNull yes / RequestTTY force / SessionType none / ForkAfterAuthentication yes。
        var broken = effective
        broken.stdinNull = "yes"
        XCTAssertNotNil(CodexLocalSSHConfigurator.validateEffectiveLoopbackConfig(
            broken,
            expectedUser: "alice",
            expectedIdentityFile: lockedConfig.expectedIdentityFileConfigValue,
            expectedKnownHostsFile: lockedConfig.expectedKnownHostsPath
        ))
        broken = effective
        broken.requestTTY = "force"
        XCTAssertNotNil(CodexLocalSSHConfigurator.validateEffectiveLoopbackConfig(
            broken,
            expectedUser: "alice",
            expectedIdentityFile: lockedConfig.expectedIdentityFileConfigValue,
            expectedKnownHostsFile: lockedConfig.expectedKnownHostsPath
        ))
        broken = effective
        broken.sessionType = "none"
        XCTAssertNotNil(CodexLocalSSHConfigurator.validateEffectiveLoopbackConfig(
            broken,
            expectedUser: "alice",
            expectedIdentityFile: lockedConfig.expectedIdentityFileConfigValue,
            expectedKnownHostsFile: lockedConfig.expectedKnownHostsPath
        ))
        broken = effective
        broken.forkAfterAuthentication = "yes"
        XCTAssertNotNil(CodexLocalSSHConfigurator.validateEffectiveLoopbackConfig(
            broken,
            expectedUser: "alice",
            expectedIdentityFile: lockedConfig.expectedIdentityFileConfigValue,
            expectedKnownHostsFile: lockedConfig.expectedKnownHostsPath
        ))

        // 3. 双向代理握手回归：模拟 StdinNull yes（ssh 退出码 0 但 stdout 未回显输入负载）-> 必须判为验证失败并事务回滚。
        try await lockedConfig.remove()
        try? FileManager.default.removeItem(at: lockedConfig.sshConfigURL)
        try? FileManager.default.removeItem(at: lockedConfig.authorizedKeysURL)
        let (stdinNullBrokenVerify, _) = makeConfigurator(username: "alice", sshExitStatus: 0, echoStdinOnVerify: false)
        do {
            try await stdinNullBrokenVerify.configure(verifyConnection: true)
            XCTFail("双向输入输出未回显时必须报 verificationFailed")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .verificationFailed(let detail) = error else {
                return XCTFail("期望 verificationFailed，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("双向"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stdinNullBrokenVerify.privateKeyURL.path), "双向握手失败必须回滚新建密钥")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stdinNullBrokenVerify.authorizedKeysURL.path), "双向握手失败必须回滚新建授权")

        // 4. 系统配置包含相对路径 `Include ssh_config.d/*`（按 /etc/ssh 目录解析而非 ~/.ssh）-> 候选检查必须准确识别其中额外 IdentityFile。
        let fakeEtcSSH = tempHome.appendingPathComponent("fake_etc_ssh", isDirectory: true)
        let fakeEtcSSHD = fakeEtcSSH.appendingPathComponent("ssh_config.d", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeEtcSSHD, withIntermediateDirectories: true)
        let fakeSysConfig = fakeEtcSSH.appendingPathComponent("ssh_config")
        try "Include ssh_config.d/*\n".write(to: fakeSysConfig, atomically: true, encoding: .utf8)
        try "Host *\n    IdentityFile ~/.ssh/system_relative_extra\n".write(
            to: fakeEtcSSHD.appendingPathComponent("10-extra.conf"),
            atomically: true,
            encoding: .utf8
        )
        let (relSysConfig, _) = makeConfigurator(username: "alice", systemSSHConfigPath: fakeSysConfig.path)
        do {
            try await relSysConfig.configure(verifyConnection: false)
            XCTFail("系统配置相对 Include 中的额外 IdentityFile 必须在写入前检出并停止")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .effectiveConfigConflict(let detail) = error else {
                return XCTFail("期望 effectiveConfigConflict，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("IdentityFile"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: relSysConfig.privateKeyURL.path))
    }

    /// R3 P1-6: 回滚必须区分文件不存在与读取失败、逐项记录错误、保留残留授权的可撤销状态，且替换托管块前确认仍是本次写入内容。
    func testR3_P1_6RollbackDistinguishesReadFailureTracksErrorsAndVerifiesManagedBlockBeforeReplacing() async throws {
        // 1. 新建 authorized_keys 在最终验连失败前变为不可读（chmod 000）：绝不能把读取失败误判为不存在并宣称已回滚！
        let authURL = tempHome.appendingPathComponent(".ssh/authorized_keys")
        let (unreadableRollback, _) = makeConfigurator(
            username: "alice",
            sshExitStatus: 255,
            sshStderr: "Connection refused",
            beforeVerifySSH: {
                _ = Darwin.chmod(authURL.path, 0o000)
            }
        )
        do {
            try await unreadableRollback.configure(verifyConnection: true)
            XCTFail("验连与回滚失败必须报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .fileOperationFailed(let detail) = error else {
                return XCTFail("回滚不完整时应抛 fileOperationFailed 明确报告残留，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("未能自动回滚"), "必须明确告知用户存在未回滚项：\(detail)")
            XCTAssertTrue(detail.contains("authorized_keys"))
        }
        // 状态文件必须保留残留授权记录，inspect 必须保留撤销入口；恢复权限后 remove() 必须彻底撤销残留授权！
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadableRollback.stateFileURL.path), "残留授权时必须保留状态文件")
        let inspectedMid = await unreadableRollback.inspect()
        XCTAssertTrue(inspectedMid.isManaged, "回滚残留不可读 authorized_keys 时必须保留撤销入口")
        XCTAssertTrue(inspectedMid.hasRecordedAuthorizedEntry)

        _ = Darwin.chmod(authURL.path, 0o600)
        try await unreadableRollback.remove()
        XCTAssertEqual(try String(contentsOf: authURL, encoding: .utf8), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadableRollback.stateFileURL.path))

        // 2. 外部编辑修改了托管块自身内容，随后最终验连失败 -> 回滚绝不能盲目覆盖外部改写后的托管块，且必须报告未完全回滚。
        let (initial, _) = makeConfigurator(username: "alice")
        try await initial.configure(verifyConnection: false)
        let configURL = initial.sshConfigURL
        let externallyEditedBlock = """
        # >>> mimi-remote local codex ssh >>>
        Host mimi-local
            HostName 127.0.0.1
            User externally-edited-user
        # <<< mimi-remote local codex ssh <<<
        """
        let (externalEditRollback, _) = makeConfigurator(
            username: "bob",
            sshExitStatus: 255,
            sshStderr: "Connection refused",
            beforeVerifySSH: {
                try (externallyEditedBlock + "\n").write(to: configURL, atomically: true, encoding: .utf8)
            }
        )
        do {
            try await externalEditRollback.configure(verifyConnection: true)
            XCTFail("托管块被外部改写导致回滚中止时必须报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .fileOperationFailed(let detail) = error else {
                return XCTFail("期望 fileOperationFailed 报告回滚受阻，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("未能自动回滚"))
            XCTAssertTrue(detail.contains("config"))
        }
        XCTAssertTrue(
            try String(contentsOf: configURL, encoding: .utf8).contains("externally-edited-user"),
            "回滚前托管块已被外部改写，绝不能覆盖外部改动"
        )

        // 3. Phase 4 写回新建的 known_hosts 后，最终状态持久化前 known_hosts 被替换为符号链接 -> 不得静默忽略 known_hosts 回滚失败，也不得动链接目标。
        let freshHome = tempHome.appendingPathComponent("kh-rollback-home", isDirectory: true)
        try FileManager.default.createDirectory(at: freshHome, withIntermediateDirectories: true)
        let sentinel = freshHome.appendingPathComponent("sentinel-kh")
        try "KEEP\n".write(to: sentinel, atomically: true, encoding: .utf8)
        let stateURL = freshHome.appendingPathComponent("Library/Application Support/MimiRemoteMac/codex-local-ssh-state.json")
        let khURL = stateURL.deletingLastPathComponent().appendingPathComponent("codex-local-known-hosts")
        let khFailConfigurator = CodexLocalSSHConfigurator(
            homeDirectory: freshHome,
            username: "alice",
            stateFileURL: stateURL,
            runCommand: { executable, arguments, timeout, standardInput in
                if executable.lastPathComponent == "ssh-keygen" || (executable.lastPathComponent == "ssh" && arguments.first == "-G") {
                    return try await CodexLocalSSHConfigurator.defaultCommandRunner(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        standardInput: standardInput
                    )
                }
                return CommandResult(status: 0, stdout: standardInput ?? Data(), stderr: Data())
            },
            beforeAtomicCommit: { targetURL in
                if targetURL.lastPathComponent == stateURL.lastPathComponent {
                    // Phase 4 刚提交新建 known_hosts 后、最终写状态前，把 known_hosts 替换为符号链接并触发回滚。
                    try FileManager.default.removeItem(at: khURL)
                    try FileManager.default.createSymbolicLink(at: khURL, withDestinationURL: sentinel)
                    throw CodexLocalSSHConfigurator.ConfigError.fileOperationFailed("模拟最终状态持久化失败")
                }
            }
        )
        do {
            try await khFailConfigurator.configure(verifyConnection: true)
            XCTFail("known_hosts 回滚失败不得静默报告已回滚")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .fileOperationFailed(let detail) = error else {
                return XCTFail("期望 fileOperationFailed 报告 known_hosts 回滚失败，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("codex-local-known-hosts"))
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "KEEP\n")
    }

    /// R3 P2-1: 原 authorized_keys 无尾换行、追加授权后又被外部转为 CRLF 时，撤销不得留下裸 CR。
    func testR3_P2_1NoTrailingNewlineConvertedToCRLFRevokesWithoutBareCR() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let originalNoTrailingNewline = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINoNewline12345678901234567890123456 user@host"
        try Data(originalNoTrailingNewline.utf8).write(to: configurator.authorizedKeysURL)

        try await configurator.configure(verifyConnection: false)

        // 外部编辑器将整个文件转换为 CRLF（把 Mimi 追加的前导 LF 转为 \r\n）。
        let lfContent = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
        let crlfContent = lfContent.replacingOccurrences(of: "\n", with: "\r\n")
        try Data(crlfContent.utf8).write(to: configurator.authorizedKeysURL)

        try await configurator.remove()

        let finalData = try Data(contentsOf: configurator.authorizedKeysURL)
        let expectedData = Data((originalNoTrailingNewline + "\r\n").utf8)
        XCTAssertEqual(finalData, expectedData, "无尾换行文件转为 CRLF 后撤销不得剥掉 \\r\\n 的 LF 而残留裸 CR")
        XCTAssertFalse(finalData.last == 0x0D, "绝不能在文件末尾留下裸 CR")
    }

    // MARK: - Round 4 P1 & P2 Structural Regressions

    /// R4 P1-1: ~/.ssh 临时失去目录搜索权限（0600）时，inspect 与 remove 必须区分「无法检查」与「确实缺失」，绝不能清空授权记录或删除状态文件。
    func testR4_P1_1RevokePreservesAuthRecordAndEntryWhenSSHDirLosesSearchPermission() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let keepAuth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeepSearchPerm12345678901234567890123 alice@host\n"
        try keepAuth.write(to: configurator.authorizedKeysURL, atomically: true, encoding: .utf8)
        try await configurator.configure(verifyConnection: false)

        // 移除 ~/.ssh 目录搜索权限（0600：对 ~/.ssh 自身的 lstat 仍成功，但访问其内部文件报 EACCES）。
        XCTAssertEqual(Darwin.chmod(configurator.sshDirectory.path, 0o600), 0)
        defer { _ = Darwin.chmod(configurator.sshDirectory.path, 0o700) }

        let inspectedLocked = await configurator.inspect()
        XCTAssertTrue(inspectedLocked.hasUnsafeFileSystemState, "目录不可搜索时必须标记不安全/不可检")
        XCTAssertFalse(inspectedLocked.isReady)
        XCTAssertTrue(inspectedLocked.isManaged, "目录不可搜索但持久化记录仍在时，必须保留撤销入口")
        XCTAssertTrue(inspectedLocked.hasRecordedAuthorizedEntry)

        do {
            try await configurator.remove()
            XCTFail("~/.ssh 不可搜索时 remove 必须报错，绝不能把 EACCES 当成文件不存在并静默成功")
        } catch {
            // 预期抛出文件检查/读取失败错误
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: configurator.stateFileURL.path), "未能确认授权已撤销时绝不能删除状态文件")

        // 恢复 ~/.ssh 搜索权限后：原授权仍在，inspect 仍保留撤销入口，重试 remove() 必须彻底撤销！
        XCTAssertEqual(Darwin.chmod(configurator.sshDirectory.path, 0o700), 0)
        let authBeforeRetry = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
        XCTAssertTrue(authBeforeRetry.contains(CodexLocalSSHConfigurator.keyComment))
        let inspectedRestored = await configurator.inspect()
        XCTAssertTrue(inspectedRestored.isManaged, "恢复权限后撤销重试入口绝不能丢失")
        XCTAssertTrue(inspectedRestored.hasRecordedAuthorizedEntry)

        try await configurator.remove()
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), keepAuth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.stateFileURL.path))
    }

    /// R4 P1-2: 核验后、删除前被原子替换为同名文件时，隔离-核验-删除模型必须拒绝误删并无覆盖恢复替换文件。
    func testR4_P1_2PostVerifySwapNeverDeletesReplacementAndQuarantineRestoresSafely() async throws {
        let (setupConfigurator, _) = makeConfigurator(username: "alice")
        try await setupConfigurator.configure(verifyConnection: false)

        let replacementSentinel = Data("USER-POST-VERIFY-SWAP-SENTINEL\n".utf8)
        let (racyRemover, _) = makeConfigurator(
            username: "alice",
            afterVerifyBeforeDelete: { targetURL in
                if targetURL.lastPathComponent == CodexLocalSSHConfigurator.keyFileName {
                    try FileManager.default.removeItem(at: targetURL)
                    try replacementSentinel.write(to: targetURL)
                    _ = Darwin.chmod(targetURL.path, 0o600)
                }
            }
        )

        do {
            try await racyRemover.remove()
            XCTFail("预核验后被替换为不同文件时必须中止删除并报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .conflictingKeyFiles = error else {
                return XCTFail("期望 conflictingKeyFiles，实际：\(error)")
            }
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: setupConfigurator.privateKeyURL.path),
            "核验后被同名替换的文件绝不能被 unlinkat 误删"
        )
        XCTAssertEqual(
            try Data(contentsOf: setupConfigurator.privateKeyURL),
            replacementSentinel,
            "替换文件必须被无覆盖地完整恢复在原路径"
        )
    }

    /// R4 P1-3: 托管块与验连必须禁用 KnownHostsCommand，且验连必须使用事务内信任副本、经归属核验后再写回首次登记的主机密钥。
    func testR4_P1_3VerifyDisablesKnownHostsCommandAndUsesTransactionalKnownHostsCopy() async throws {
        let sshDir = tempHome.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let hostileTrustConfig = """
        Host *
            KnownHostsCommand /usr/bin/true
        """
        try hostileTrustConfig.write(to: sshDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let fakeHostKeyLine = "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITxKnownHostsCommitKey1234567890123456\n"
        let recorder = CommandRecorder()
        let configurator = CodexLocalSSHConfigurator(
            homeDirectory: tempHome,
            username: "alice",
            runCommand: { executable, arguments, timeout, standardInput in
                await recorder.record(executable: executable.path, arguments: arguments)
                if executable.lastPathComponent == "ssh-keygen" || (executable.lastPathComponent == "ssh" && arguments.first == "-G") {
                    return try await CodexLocalSSHConfigurator.defaultCommandRunner(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        standardInput: standardInput
                    )
                }
                // 模拟 ssh 首次验连把主机密钥写入其收到的 UserKnownHostsFile 路径。
                if let opt = arguments.first(where: { $0.hasPrefix("UserKnownHostsFile=") }) {
                    let rawPath = String(opt.dropFirst("UserKnownHostsFile=".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    try fakeHostKeyLine.write(to: URL(fileURLWithPath: rawPath), atomically: true, encoding: .utf8)
                }
                return CommandResult(status: 0, stdout: standardInput ?? Data(), stderr: Data())
            }
        )

        try await configurator.configure(verifyConnection: true)

        // 1. 托管块必须禁用 KnownHostsCommand，且 ssh -G 确认未继承 Host * 的 KnownHostsCommand。
        let configText = try String(contentsOf: configurator.sshConfigURL, encoding: .utf8)
        XCTAssertTrue(configText.contains("KnownHostsCommand none"), "托管块必须显式禁用 KnownHostsCommand")

        // 2. 验连参数必须显式禁用 KnownHostsCommand 且使用事务内副本而非实时 knownHostsURL。
        let calls = await recorder.calls
        let verifyCall = try XCTUnwrap(calls.last(where: { $0.executable == "/usr/bin/ssh" && $0.arguments.first != "-G" }))
        let args = verifyCall.arguments
        XCTAssertTrue(args.contains("KnownHostsCommand=none"), "验连参数必须显式禁用 KnownHostsCommand")
        let ukhArg = try XCTUnwrap(args.first(where: { $0.hasPrefix("UserKnownHostsFile=") }))
        XCTAssertFalse(
            ukhArg.contains(configurator.expectedKnownHostsPath),
            "验连必须使用事务内的专用信任副本，不得直接打开实时 knownHostsURL：\(ukhArg)"
        )

        // 3. 首次验连写入事务副本的主机密钥必须在归属核验后提交回应用专用 knownHostsURL。
        XCTAssertEqual(
            try String(contentsOf: configurator.knownHostsURL, encoding: .utf8),
            fakeHostKeyLine,
            "事务副本中首次登记的主机密钥必须经归属核验后写回 knownHostsURL"
        )
    }

    /// R4 P1-4: Match command 让桌面代理命令加载额外 IdentityFile/StdinNull 或存在无法忠实冻结的 Include 时，必须明确报错。
    func testR4_P1_4DetectsMatchCommandDesktopProxyDivergenceAndRejectsUnfreezableIncludes() async throws {
        // 1. Match command "*codex*" 仅在桌面版实际代理命令下注入额外 IdentityFile -> 写入前必须检出并拒绝。
        let (matchCmdConfig, _) = makeConfigurator(username: "alice")
        try FileManager.default.createDirectory(at: matchCmdConfig.sshDirectory, withIntermediateDirectories: true)
        let matchCmdText = """
        Match command "*codex*"
            IdentityFile ~/.ssh/match_cmd_extra
        """
        try matchCmdText.write(to: matchCmdConfig.sshConfigURL, atomically: true, encoding: .utf8)
        do {
            try await matchCmdConfig.configure(verifyConnection: false)
            XCTFail("Match command 导致桌面代理命令加载额外 IdentityFile 时必须在写入前停止")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .effectiveConfigConflict(let detail) = error else {
                return XCTFail("期望 effectiveConfigConflict，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("IdentityFile"), "错误信息应指出 IdentityFile 冲突：\(detail)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: matchCmdConfig.privateKeyURL.path))

        // 2. 无法忠实冻结的动态 Include（环境变量 / token）-> 绝不能静默丢弃，必须明确报错。
        let envIncConfigText = "Include ${MIMI_DYNAMIC_SSH_INCLUDE}\n"
        try envIncConfigText.write(to: matchCmdConfig.sshConfigURL, atomically: true, encoding: .utf8)
        do {
            try await matchCmdConfig.configure(verifyConnection: false)
            XCTFail("包含环境变量的无法忠实冻结 Include 必须明确报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .effectiveConfigConflict = error else {
                return XCTFail("期望 effectiveConfigConflict，实际：\(error)")
            }
        }

        // 3. 用户配置 Include 指向符号链接文件（OpenSSH 可读取）-> 绝不能静默丢弃其中额外的 IdentityFile。
        let dotfilesDir = tempHome.appendingPathComponent("dotfiles-inc", isDirectory: true)
        let confD = matchCmdConfig.sshDirectory.appendingPathComponent("conf.d", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: confD, withIntermediateDirectories: true)
        let dotfileTarget = dotfilesDir.appendingPathComponent("extra.conf")
        try "Host *\n    IdentityFile ~/.ssh/from_symlink_include\n".write(to: dotfileTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: confD.appendingPathComponent("extra.conf"),
            withDestinationURL: dotfileTarget
        )
        try "Include conf.d/*.conf\n".write(to: matchCmdConfig.sshConfigURL, atomically: true, encoding: .utf8)
        do {
            try await matchCmdConfig.configure(verifyConnection: false)
            XCTFail("符号链接 Include 中的额外 IdentityFile 绝不能被静默丢弃")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .effectiveConfigConflict(let detail) = error else {
                return XCTFail("期望 effectiveConfigConflict，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("IdentityFile"), "应检出符号链接 Include 中的额外 IdentityFile：\(detail)")
        }

        // 4. 旧式 127.0.0.1 探测同样必须拒绝 Match command 导致的桌面代理配置偏移与无法忠实冻结的 Include。
        try "Match command \"*codex*\"\n    StdinNull yes\n".write(to: matchCmdConfig.sshConfigURL, atomically: true, encoding: .utf8)
        let probeRejectedMatchCmd = await CodexSharedSetupChecks.probeTarget(
            "127.0.0.1",
            configurator: matchCmdConfig,
            runProbe: { _, _, _, stdin in
                CommandResult(status: 0, stdout: stdin ?? Data(), stderr: Data())
            }
        )
        XCTAssertFalse(probeRejectedMatchCmd, "旧式 127.0.0.1 探测在 Match command 切断桌面代理 Stdin 时绝不能误报免密就绪")

        try "Include ${MIMI_UNFREEZABLE_INCLUDE}\n".write(to: matchCmdConfig.sshConfigURL, atomically: true, encoding: .utf8)
        let probeRejectedUnfreezableInc = await CodexSharedSetupChecks.probeTarget(
            "127.0.0.1",
            configurator: matchCmdConfig,
            runProbe: { _, _, _, stdin in
                CommandResult(status: 0, stdout: stdin ?? Data(), stderr: Data())
            }
        )
        XCTAssertFalse(probeRejectedUnfreezableInc, "旧式 127.0.0.1 探测遇到无法忠实冻结的 Include 时绝不能误报免密就绪")
    }

    /// R4 P1-6: 回滚遇到外部改写新增授权行注释时必须按公钥标识检出残留并保留记录；known_hosts 回滚绝不删除同名替换文件或覆盖外部更新。
    func testR4_P1_6RollbackDetectsEditedAddedAuthKeyAndProtectsExternalKnownHosts() async throws {
        // 1. 外部编辑只改了本次新增授权行的注释 -> 精确删除失败，但该公钥仍有效授权，回滚绝不能标记成功或丢弃状态记录！
        let authURL = tempHome.appendingPathComponent(".ssh/authorized_keys")
        let (editedCommentConfig, _) = makeConfigurator(
            username: "alice",
            sshExitStatus: 255,
            sshStderr: "Connection refused",
            beforeVerifySSH: {
                let current = try String(contentsOf: authURL, encoding: .utf8)
                let edited = current.replacingOccurrences(of: CodexLocalSSHConfigurator.keyComment, with: "user-edited-comment")
                try edited.write(to: authURL, atomically: true, encoding: .utf8)
            }
        )
        do {
            try await editedCommentConfig.configure(verifyConnection: true)
            XCTFail("新增授权行注释被外部修改导致未能撤销时，绝不能标记回滚成功")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .fileOperationFailed(let detail) = error else {
                return XCTFail("期望 fileOperationFailed 报告残留授权，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("authorized_keys"), "应明确报告 authorized_keys 残留：\(detail)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: editedCommentConfig.stateFileURL.path), "残留有效授权时绝不能丢弃状态记录")
        let inspectedAfterEdited = await editedCommentConfig.inspect()
        XCTAssertTrue(inspectedAfterEdited.isManaged, "残留授权时必须保留撤销入口")
        XCTAssertTrue(inspectedAfterEdited.hasRecordedAuthorizedEntry)

        // 2. 已有 known_hosts 在事务期间被外部更新 -> 验连失败回滚绝不能用旧内容覆盖外部更新！
        let khUpdateHome = tempHome.appendingPathComponent("kh-ext-update", isDirectory: true)
        try FileManager.default.createDirectory(at: khUpdateHome, withIntermediateDirectories: true)
        let stateURL = khUpdateHome.appendingPathComponent("Library/Application Support/MimiRemoteMac/codex-local-ssh-state.json")
        let khURL = stateURL.deletingLastPathComponent().appendingPathComponent("codex-local-known-hosts")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalKH = "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOldHostKey12345678901234567890123456\n"
        let externallyUpdatedKH = originalKH + "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExternalUpdateKey1234567890123456\n"
        try originalKH.write(to: khURL, atomically: true, encoding: .utf8)
        _ = Darwin.chmod(khURL.path, 0o600)

        let khExtConfig = CodexLocalSSHConfigurator(
            homeDirectory: khUpdateHome,
            username: "alice",
            stateFileURL: stateURL,
            runCommand: { executable, arguments, timeout, standardInput in
                if executable.lastPathComponent == "ssh-keygen" || (executable.lastPathComponent == "ssh" && arguments.first == "-G") {
                    return try await CodexLocalSSHConfigurator.defaultCommandRunner(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        standardInput: standardInput
                    )
                }
                // 模拟外部进程在验连期间更新了 known_hosts，随后验连失败触发回滚。
                try externallyUpdatedKH.write(to: khURL, atomically: true, encoding: .utf8)
                return CommandResult(status: 255, stdout: Data(), stderr: Data("Connection refused".utf8))
            }
        )
        do {
            try await khExtConfig.configure(verifyConnection: true)
            XCTFail("验连失败必须抛错")
        } catch {
            // 预期失败
        }
        XCTAssertEqual(
            try String(contentsOf: khURL, encoding: .utf8),
            externallyUpdatedKH,
            "known_hosts 发生外部更新后，回滚绝不能用旧内容覆盖外部更新"
        )

        // 3. 新建 known_hosts 后在回滚前被替换为同名普通文件 -> 回滚绝不能删除同名替换文件！
        let khReplaceHome = tempHome.appendingPathComponent("kh-ext-replace", isDirectory: true)
        try FileManager.default.createDirectory(at: khReplaceHome, withIntermediateDirectories: true)
        let replaceStateURL = khReplaceHome.appendingPathComponent("Library/Application Support/MimiRemoteMac/codex-local-ssh-state.json")
        let replaceKHURL = replaceStateURL.deletingLastPathComponent().appendingPathComponent("codex-local-known-hosts")
        let replacementKHContent = "EXTERNAL-REPLACEMENT-KNOWN-HOSTS-DO-NOT-DELETE\n"

        let khReplaceConfig = CodexLocalSSHConfigurator(
            homeDirectory: khReplaceHome,
            username: "alice",
            stateFileURL: replaceStateURL,
            runCommand: { executable, arguments, timeout, standardInput in
                if executable.lastPathComponent == "ssh-keygen" || (executable.lastPathComponent == "ssh" && arguments.first == "-G") {
                    return try await CodexLocalSSHConfigurator.defaultCommandRunner(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        standardInput: standardInput
                    )
                }
                // 模拟事务写入后/失败前，known_hosts 被替换为外部普通文件。
                if FileManager.default.fileExists(atPath: replaceKHURL.path) {
                    try FileManager.default.removeItem(at: replaceKHURL)
                }
                try replacementKHContent.write(to: replaceKHURL, atomically: true, encoding: .utf8)
                return CommandResult(status: 255, stdout: Data(), stderr: Data("Connection refused".utf8))
            }
        )
        do {
            try await khReplaceConfig.configure(verifyConnection: true)
            XCTFail("验连失败必须抛错")
        } catch {
            // 预期失败
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: replaceKHURL.path),
            "被外部替换的同名 known_hosts 绝不能被回滚删除"
        )
        XCTAssertEqual(
            try String(contentsOf: replaceKHURL, encoding: .utf8),
            replacementKHContent,
            "同名替换文件的内容必须原样保留"
        )

        // 4. Phase 4 实际写回 known_hosts 后，在状态落盘失败触发回滚前被外部更新/替换 -> 同样绝不覆盖外部更新或删除替换文件！
        let p4UpdateHome = tempHome.appendingPathComponent("kh-p4-update", isDirectory: true)
        try FileManager.default.createDirectory(at: p4UpdateHome, withIntermediateDirectories: true)
        let p4StateURL = p4UpdateHome.appendingPathComponent("Library/Application Support/MimiRemoteMac/codex-local-ssh-state.json")
        let p4KHURL = p4StateURL.deletingLastPathComponent().appendingPathComponent("codex-local-known-hosts")
        try FileManager.default.createDirectory(at: p4StateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalKH.write(to: p4KHURL, atomically: true, encoding: .utf8)
        _ = Darwin.chmod(p4KHURL.path, 0o600)

        let p4NewKey = "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPhase4TxKey1234567890123456789012345678\n"
        let p4ExternalAfterCommit = originalKH + p4NewKey + "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfterCommitExt1234567890123456789012345\n"
        let p4UpdateConfig = CodexLocalSSHConfigurator(
            homeDirectory: p4UpdateHome,
            username: "alice",
            stateFileURL: p4StateURL,
            runCommand: { executable, arguments, timeout, standardInput in
                if executable.lastPathComponent == "ssh-keygen" || (executable.lastPathComponent == "ssh" && arguments.first == "-G") {
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
                    try (originalKH + p4NewKey).write(to: URL(fileURLWithPath: rawPath), atomically: true, encoding: .utf8)
                }
                return CommandResult(status: 0, stdout: standardInput ?? Data(), stderr: Data())
            },
            beforeAtomicCommit: { targetURL in
                if targetURL.lastPathComponent == p4StateURL.lastPathComponent {
                    // Phase 4 提交 known_hosts 后，外部再追加一行，然后最终状态落盘失败触发回滚。
                    try p4ExternalAfterCommit.write(to: p4KHURL, atomically: true, encoding: .utf8)
                    throw CodexLocalSSHConfigurator.ConfigError.fileOperationFailed("模拟 Phase 4 状态落盘失败")
                }
            }
        )
        do {
            try await p4UpdateConfig.configure(verifyConnection: true)
            XCTFail("Phase 4 状态落盘失败必须报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .fileOperationFailed(let detail) = error else {
                return XCTFail("期望 fileOperationFailed 报告 known_hosts 外部更新冲突，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("codex-local-known-hosts"))
        }
        XCTAssertEqual(
            try String(contentsOf: p4KHURL, encoding: .utf8),
            p4ExternalAfterCommit,
            "Phase 4 提交 known_hosts 后若发生外部更新，回滚绝不能覆盖外部更新"
        )
    }

    /// R4 P2-1: 授权、密钥和配置都已清空，仅应用专用 known_hosts 清理失败时，必须保留状态与重试入口。
    func testR4_P2_1KnownHostsCleanupFailurePreservesRetryEntry() async throws {
        let (configurator, _) = makeConfigurator(username: "alice")
        try await configurator.configure(verifyConnection: false)

        let sentinel = tempHome.appendingPathComponent("p2-sentinel")
        try "KEEP\n".write(to: sentinel, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: configurator.knownHostsURL)
        try FileManager.default.createSymbolicLink(at: configurator.knownHostsURL, withDestinationURL: sentinel)

        do {
            try await configurator.remove()
            XCTFail("known_hosts 为符号链接时必须报错")
        } catch let error as CodexLocalSSHConfigurator.ConfigError {
            guard case .unsafeFileSystemTarget = error else {
                return XCTFail("期望 unsafeFileSystemTarget，实际：\(error)")
            }
        }

        // 即使 authorized_keys、密钥与 config 已清理，因 known_hosts 清理失败仍必须保留状态文件与移除重试入口。
        XCTAssertTrue(FileManager.default.fileExists(atPath: configurator.stateFileURL.path), "known_hosts 清理失败时必须保留状态文件")
        let inspectedMid = await configurator.inspect()
        XCTAssertTrue(inspectedMid.isManaged, "known_hosts 单独清理失败时必须保留重试入口")
        XCTAssertTrue(inspectedMid.hasUnsafeFileSystemState)

        // 手动清除异常符号链接后再次 remove() 应彻底清空状态文件。
        try FileManager.default.removeItem(at: configurator.knownHostsURL)
        try await configurator.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.stateFileURL.path))
        let inspectedAfter = await configurator.inspect()
        XCTAssertFalse(inspectedAfter.isManaged)
    }

    // MARK: - Helpers

    private func generateRawEd25519Key(at url: URL, comment: String) async throws {
        let result = try await CodexLocalSSHConfigurator.defaultCommandRunner(
            executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", url.path],
            timeout: .seconds(15)
        )
        XCTAssertEqual(result.status, 0, result.stderrText)
    }

    private func posixPermissions(of url: URL) throws -> Int {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Int(st.st_mode & 0o777)
    }
}

private actor CommandRecorder {
    struct Call {
        let executable: String
        let arguments: [String]
    }

    var calls: [Call] = []

    func record(executable: String, arguments: [String]) {
        calls.append(Call(executable: executable, arguments: arguments))
    }
}
