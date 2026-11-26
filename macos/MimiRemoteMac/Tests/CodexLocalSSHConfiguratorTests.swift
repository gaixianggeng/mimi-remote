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
        sshExitStatus: Int32 = 0,
        sshStderr: String = "",
        beforeAtomicCommit: CodexLocalSSHConfigurator.CommitHook? = nil
    ) -> (CodexLocalSSHConfigurator, CommandRecorder) {
        let recorder = CommandRecorder()
        let configurator = CodexLocalSSHConfigurator(
            homeDirectory: tempHome,
            username: username,
            runCommand: { executable, arguments, timeout in
                await recorder.record(executable: executable.path, arguments: arguments)
                if executable.lastPathComponent == "ssh-keygen" {
                    return try await CodexLocalSSHConfigurator.defaultCommandRunner(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout
                    )
                }
                if executable.lastPathComponent == "ssh", arguments.first == "-G" {
                    return try await CodexLocalSSHConfigurator.defaultCommandRunner(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout
                    )
                }
                return CommandResult(
                    status: sshExitStatus,
                    stdout: Data(),
                    stderr: Data(sshStderr.utf8)
                )
            },
            beforeAtomicCommit: beforeAtomicCommit
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
        XCTAssertTrue(config.contains("ProxyJump none"))
        XCTAssertTrue(config.contains("ControlMaster no"))
        XCTAssertTrue(config.contains(CodexLocalSSHConfigurator.managedBlockEnd))

        // 验证最后一步使用完全隔离的 ssh 配置直接验证当前用户、回环 22 端口和专用私钥。
        let calls = await recorder.calls
        let liveVerifyCalls = calls.filter { $0.executable == "/usr/bin/ssh" && $0.arguments.first != "-G" }
        XCTAssertEqual(liveVerifyCalls.count, 1)
        let verifyArgs = try XCTUnwrap(liveVerifyCalls.first?.arguments)
        XCTAssertTrue(verifyArgs.contains("/dev/null"))
        XCTAssertTrue(verifyArgs.contains(configurator.privateKeyURL.path))
        XCTAssertTrue(verifyArgs.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(verifyArgs.contains("IdentityAgent=none"))
        XCTAssertTrue(verifyArgs.contains("ControlMaster=no"))
        XCTAssertTrue(verifyArgs.contains("ProxyJump=none"))
        XCTAssertTrue(verifyArgs.contains("BatchMode=yes"))
        XCTAssertTrue(verifyArgs.contains("127.0.0.1"))
        XCTAssertTrue(verifyArgs.contains("alice"))
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
