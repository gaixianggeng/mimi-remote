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
            try? FileManager.default.removeItem(at: tempHome)
        }
        try super.tearDownWithError()
    }

    private func makeConfigurator(
        username: String = "tester",
        sshExitStatus: Int32 = 0,
        sshStderr: String = ""
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
                return CommandResult(
                    status: sshExitStatus,
                    stdout: Data(),
                    stderr: Data(sshStderr.utf8)
                )
            }
        )
        return (configurator, recorder)
    }

    func testConfigureFromEmptyHomeCreatesScopedKeyAuthorizedKeyConfigAndVerifies() async throws {
        let (configurator, recorder) = makeConfigurator(username: "alice")
        XCTAssertFalse(configurator.inspect().isManaged)

        try await configurator.configure(verifyConnection: true)

        let status = configurator.inspect()
        XCTAssertTrue(status.isReady)
        XCTAssertTrue(status.isManaged)
        XCTAssertFalse(status.hasConflictingHostAlias)

        // 权限检查：~/.ssh 为 0700，私钥、authorized_keys 和 config 为 0600。
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
        XCTAssertTrue(config.contains("User alice"))
        XCTAssertTrue(config.contains("IdentityFile ~/.ssh/\(CodexLocalSSHConfigurator.keyFileName)"))
        XCTAssertTrue(config.contains("IdentitiesOnly yes"))
        XCTAssertTrue(config.contains(CodexLocalSSHConfigurator.managedBlockEnd))

        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].executable, "/usr/bin/ssh-keygen")
        XCTAssertEqual(calls[1].executable, "/usr/bin/ssh")
        XCTAssertTrue(calls[1].arguments.contains(CodexLocalSSHConfigurator.hostAlias))
        XCTAssertTrue(calls[1].arguments.contains("BatchMode=yes"))
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
        XCTAssertTrue(configAfterFirst.hasPrefix(originalConfig + "\n\n" + CodexLocalSSHConfigurator.managedBlockStart))

        let authAfterFirst = try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8)
        let authLines = authAfterFirst.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(authLines.count, 2)
        XCTAssertEqual(authLines[0], originalAuth)

        let backups = try FileManager.default.contentsOfDirectory(atPath: configurator.sshDirectory.path)
            .filter { $0.hasPrefix("config.before-mimi.") && $0.hasSuffix(".bak") }
        XCTAssertEqual(backups.count, 1)

        // 第二次运行保持幂等，不重复追加公钥或托管块，也不重生成密钥。
        try await configurator.configure(verifyConnection: true)
        XCTAssertEqual(try String(contentsOf: configurator.sshConfigURL, encoding: .utf8), configAfterFirst)
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), authAfterFirst)
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter { $0.executable == "/usr/bin/ssh-keygen" }.count, 1)
    }

    func testConfigureRefusesConflictingUnmanagedHostAliasWithoutTouchingExistingFiles() async throws {
        let (configurator, _) = makeConfigurator(username: "carol")
        try FileManager.default.createDirectory(at: configurator.sshDirectory, withIntermediateDirectories: true)
        let customConfig = "Host mimi-local\n    HostName 192.168.1.99\n"
        try customConfig.write(to: configurator.sshConfigURL, atomically: true, encoding: .utf8)

        let inspected = configurator.inspect()
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
        XCTAssertTrue(configurator.inspect().isReady)

        try configurator.remove()

        let after = configurator.inspect()
        XCTAssertFalse(after.isManaged)
        XCTAssertFalse(after.isReady)
        XCTAssertEqual(try String(contentsOf: configurator.sshConfigURL, encoding: .utf8), originalConfig)
        XCTAssertEqual(try String(contentsOf: configurator.authorizedKeysURL, encoding: .utf8), originalAuth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.privateKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.publicKeyURL.path))
    }

    private func posixPermissions(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
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
