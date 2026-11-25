import Foundation

/// 为 Codex 桌面版安全、幂等、可撤销地配置本机回环 SSH（#376）。
/// 只操作标准 `~/.ssh`（专用密钥 + `from="127.0.0.1,::1"` 授权 + 独立标记块），不触碰 Codex 私有数据库。
struct CodexLocalSSHConfigurator: Sendable {
    static let hostAlias = "mimi-local"
    static let keyFileName = "mimi_codex_local_ed25519"
    static let keyComment = "mimi-codex-local"
    static let managedBlockStart = "# >>> mimi-remote local codex ssh >>>"
    static let managedBlockEnd = "# <<< mimi-remote local codex ssh <<<"
    static let loopbackAuthorizedKeyOption = #"from="127.0.0.1,::1""#

    typealias CommandRunner = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: Duration) async throws -> CommandResult

    struct Inspection: Equatable, Sendable {
        var keyExists: Bool = false
        var authorizedKeyInstalled: Bool = false
        var sshConfigInstalled: Bool = false
        var hasConflictingHostAlias: Bool = false

        var isManaged: Bool {
            keyExists || authorizedKeyInstalled || sshConfigInstalled
        }

        var isReady: Bool {
            keyExists && authorizedKeyInstalled && sshConfigInstalled && !hasConflictingHostAlias
        }
    }

    enum ConfigError: LocalizedError, Equatable {
        case invalidUsername
        case conflictingHostAlias(String)
        case invalidManagedBlock
        case keyGenerationFailed(String)
        case verificationFailed(String)
        case fileOperationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidUsername:
                "无法识别当前系统用户名，不能生成本机 SSH 配置。"
            case .conflictingHostAlias(let alias):
                "~/.ssh/config 里已有自定义的「Host \(alias)」，为避免覆盖你的原配置已停止。"
            case .invalidManagedBlock:
                "~/.ssh/config 中的 Mimi 托管标记块不完整，请先手工核对后再试。"
            case .keyGenerationFailed(let detail):
                detail.isEmpty ? "没能生成本机 SSH 密钥。" : "没能生成本机 SSH 密钥：\(detail)"
            case .verificationFailed(let detail):
                detail.isEmpty
                    ? "配置已写入，但本机免密验证未通过。请确认第 1 步「远程登录」已开启。"
                    : "本机免密验证未通过：\(detail)"
            case .fileOperationFailed(let detail):
                "读写 SSH 配置文件失败：\(detail)"
            }
        }
    }

    let homeDirectory: URL
    let username: String
    private let runCommand: CommandRunner

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        username: String = NSUserName(),
        runCommand: @escaping CommandRunner = CodexLocalSSHConfigurator.defaultCommandRunner
    ) {
        self.homeDirectory = homeDirectory
        self.username = username
        self.runCommand = runCommand
    }

    var sshDirectory: URL { homeDirectory.appendingPathComponent(".ssh", isDirectory: true) }
    var privateKeyURL: URL { sshDirectory.appendingPathComponent(Self.keyFileName) }
    var publicKeyURL: URL { sshDirectory.appendingPathComponent("\(Self.keyFileName).pub") }
    var authorizedKeysURL: URL { sshDirectory.appendingPathComponent("authorized_keys") }
    var sshConfigURL: URL { sshDirectory.appendingPathComponent("config") }

    static func defaultCommandRunner(executable: URL, arguments: [String], timeout: Duration) async throws -> CommandResult {
        try await ProcessExecutor.shared.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            forceKillAfterTimeout: true
        )
    }

    /// 只读检查当前本机 SSH 托管配置状态。
    func inspect() -> Inspection {
        let fm = FileManager.default
        let keyExists = fm.fileExists(atPath: privateKeyURL.path) && fm.fileExists(atPath: publicKeyURL.path)

        var authorizedInstalled = false
        if let keyBody = readPublicKeyBody(),
           let authorizedContent = try? String(contentsOf: authorizedKeysURL, encoding: .utf8) {
            authorizedInstalled = authorizedContent
                .components(separatedBy: .newlines)
                .contains { Self.lineContainsPublicKey($0, keyBody: keyBody) }
        }

        var configInstalled = false
        var hasConflict = false
        if let configContent = try? String(contentsOf: sshConfigURL, encoding: .utf8) {
            if let stripped = try? Self.stripManagedBlock(from: configContent) {
                configInstalled = stripped.hadManagedBlock
                hasConflict = Self.containsHostAlias(Self.hostAlias, in: stripped.remaining)
            } else {
                hasConflict = true
            }
        }

        return Inspection(
            keyExists: keyExists,
            authorizedKeyInstalled: authorizedInstalled,
            sshConfigInstalled: configInstalled,
            hasConflictingHostAlias: hasConflict
        )
    }

    /// 一键配置本机回环 SSH 并验证免密连通。
    func configure(verifyConnection: Bool = true) async throws {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty,
              trimmedUser.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ConfigError.invalidUsername
        }

        // 先检查 ~/.ssh/config 冲突，避免冲突时还多生成一把无用密钥。
        try validateConfigForUpdate()

        try ensureSSHDirectory()
        try await ensureDedicatedKeyPair()
        guard let publicKeyLine = readPublicKeyTrimmed(),
              let keyBody = Self.extractPublicKeyBody(from: publicKeyLine) else {
            throw ConfigError.keyGenerationFailed("未读取到有效公钥内容。")
        }

        try ensureAuthorizedKey(keyBody: keyBody)
        try ensureSSHConfig(username: trimmedUser)

        if verifyConnection {
            try await verifyLoopbackSSH()
        }
    }

    /// 撤销由 Mimi 写入的本机 SSH 托管块、公钥行和专用密钥。
    func remove() throws {
        let fm = FileManager.default
        let keyBody = readPublicKeyBody()

        if fm.fileExists(atPath: sshConfigURL.path) {
            let content = try readText(from: sshConfigURL)
            let stripped = try Self.stripManagedBlock(from: content)
            if stripped.hadManagedBlock {
                try writeAtomicText(stripped.remaining, to: sshConfigURL, permissions: 0o600)
            }
        }

        if fm.fileExists(atPath: authorizedKeysURL.path) {
            let content = try readText(from: authorizedKeysURL)
            let lines = Self.splitLinesPreservingStructure(content)
            let filtered = lines.filter { line in
                if let keyBody, Self.lineContainsPublicKey(line, keyBody: keyBody) {
                    return false
                }
                if line.contains(Self.loopbackAuthorizedKeyOption) && line.contains(Self.keyComment) {
                    return false
                }
                return true
            }
            if filtered.count != lines.count {
                let updated = filtered.isEmpty ? "" : filtered.joined(separator: "\n") + "\n"
                try writeAtomicText(updated, to: authorizedKeysURL, permissions: 0o600)
            }
        }

        for url in [privateKeyURL, publicKeyURL] where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                throw ConfigError.fileOperationFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Internal helpers

    private func ensureSSHDirectory() throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDirectory.path)
        } catch {
            throw ConfigError.fileOperationFailed(error.localizedDescription)
        }
    }

    private func ensureDedicatedKeyPair() async throws {
        let fm = FileManager.default
        let hasPrivate = fm.fileExists(atPath: privateKeyURL.path)
        let hasPublic = fm.fileExists(atPath: publicKeyURL.path)
        if hasPrivate && hasPublic {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicKeyURL.path)
            return
        }
        // 半残状态先清理再生成，避免 ssh-keygen 交互提示覆写。
        if hasPrivate { try? fm.removeItem(at: privateKeyURL) }
        if hasPublic { try? fm.removeItem(at: publicKeyURL) }

        let result: CommandResult
        do {
            result = try await runCommand(
                URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                ["-q", "-t", "ed25519", "-N", "", "-C", Self.keyComment, "-f", privateKeyURL.path],
                .seconds(15)
            )
        } catch {
            throw ConfigError.keyGenerationFailed(error.localizedDescription)
        }
        guard result.status == 0 else {
            throw ConfigError.keyGenerationFailed(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicKeyURL.path)
    }

    private func ensureAuthorizedKey(keyBody: String) throws {
        let fm = FileManager.default
        let existing = fm.fileExists(atPath: authorizedKeysURL.path)
            ? try readText(from: authorizedKeysURL)
            : ""
        let lines = Self.splitLinesPreservingStructure(existing)
        if lines.contains(where: { Self.lineContainsPublicKey($0, keyBody: keyBody) }) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedKeysURL.path)
            return
        }
        let entry = "\(Self.loopbackAuthorizedKeyOption) \(keyBody) \(Self.keyComment)"
        var updatedLines = lines
        updatedLines.append(entry)
        let updated = updatedLines.joined(separator: "\n") + "\n"
        try writeAtomicText(updated, to: authorizedKeysURL, permissions: 0o600)
    }

    private func validateConfigForUpdate() throws {
        guard FileManager.default.fileExists(atPath: sshConfigURL.path) else { return }
        let existing = try readText(from: sshConfigURL)
        let stripped = try Self.stripManagedBlock(from: existing)
        if Self.containsHostAlias(Self.hostAlias, in: stripped.remaining) {
            throw ConfigError.conflictingHostAlias(Self.hostAlias)
        }
    }

    private func ensureSSHConfig(username: String) throws {
        let fm = FileManager.default
        let existing = fm.fileExists(atPath: sshConfigURL.path)
            ? try readText(from: sshConfigURL)
            : ""
        let stripped = try Self.stripManagedBlock(from: existing)
        if Self.containsHostAlias(Self.hostAlias, in: stripped.remaining) {
            throw ConfigError.conflictingHostAlias(Self.hostAlias)
        }

        let managedBlock = Self.renderManagedBlock(
            alias: Self.hostAlias,
            username: username,
            identityFile: "~/.ssh/\(Self.keyFileName)"
        )
        let updated = Self.composeSSHConfig(remaining: stripped.remaining, managedBlock: managedBlock)
        guard updated != existing else {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sshConfigURL.path)
            return
        }

        if fm.fileExists(atPath: sshConfigURL.path) && !existing.isEmpty {
            let backupName = "config.before-mimi.\(Int(Date().timeIntervalSince1970)).bak"
            let backupURL = sshDirectory.appendingPathComponent(backupName)
            do {
                if fm.fileExists(atPath: backupURL.path) {
                    try fm.removeItem(at: backupURL)
                }
                try fm.copyItem(at: sshConfigURL, to: backupURL)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            } catch {
                throw ConfigError.fileOperationFailed("备份原 ~/.ssh/config 失败：\(error.localizedDescription)")
            }
        }

        try writeAtomicText(updated, to: sshConfigURL, permissions: 0o600)
    }

    private func verifyLoopbackSSH() async throws {
        let result: CommandResult
        do {
            result = try await runCommand(
                URL(fileURLWithPath: "/usr/bin/ssh"),
                [
                    "-F", sshConfigURL.path,
                    "-o", "BatchMode=yes",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=5",
                    Self.hostAlias,
                    "true",
                ],
                .seconds(12)
            )
        } catch {
            throw ConfigError.verificationFailed(error.localizedDescription)
        }
        guard result.status == 0 else {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.localizedCaseInsensitiveContains("Connection refused") {
                throw ConfigError.verificationFailed("本机 22 端口未响应，请先完成第 1 步打开「远程登录」。")
            }
            throw ConfigError.verificationFailed(stderr)
        }
    }

    private func readPublicKeyTrimmed() -> String? {
        guard let raw = try? String(contentsOf: publicKeyURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readPublicKeyBody() -> String? {
        guard let trimmed = readPublicKeyTrimmed() else { return nil }
        return Self.extractPublicKeyBody(from: trimmed)
    }

    private func readText(from url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigError.fileOperationFailed(error.localizedDescription)
        }
    }

    private func writeAtomicText(_ content: String, to url: URL, permissions: Int) throws {
        let fm = FileManager.default
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).mimi-\(UUID().uuidString).tmp")
        do {
            let data = Data(content.utf8)
            guard fm.createFile(atPath: tempURL.path, contents: data, attributes: [.posixPermissions: permissions]) else {
                throw ConfigError.fileOperationFailed("无法创建临时文件 \(tempURL.lastPathComponent)")
            }
            defer { try? fm.removeItem(at: tempURL) }
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
            _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.fileOperationFailed(error.localizedDescription)
        }
    }

    // MARK: - Pure parsing / formatting

    static func renderManagedBlock(alias: String, username: String, identityFile: String) -> String {
        """
        \(managedBlockStart)
        Host \(alias)
            HostName 127.0.0.1
            User \(username)
            IdentityFile \(identityFile)
            IdentitiesOnly yes
            StrictHostKeyChecking accept-new
        \(managedBlockEnd)
        """
    }

    static func extractPublicKeyBody(from line: String) -> String? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2 else { return nil }
        return "\(tokens[0]) \(tokens[1])"
    }

    static func lineContainsPublicKey(_ line: String, keyBody: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        return trimmed.contains(keyBody)
    }

    static func splitLinesPreservingStructure(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    struct StrippedConfig: Equatable {
        let remaining: String
        let hadManagedBlock: Bool
    }

    static func stripManagedBlock(from text: String) throws -> StrippedConfig {
        let lines = splitLinesPreservingStructure(text)
        var output: [String] = []
        var inside = false
        var hadBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == managedBlockStart {
                if inside { throw ConfigError.invalidManagedBlock }
                inside = true
                hadBlock = true
                continue
            }
            if trimmed == managedBlockEnd {
                if !inside { throw ConfigError.invalidManagedBlock }
                inside = false
                continue
            }
            if !inside {
                output.append(line)
            }
        }
        if inside { throw ConfigError.invalidManagedBlock }

        // 清理因剥离托管块留下的多余尾空行。
        while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            output.removeLast()
        }
        let remaining = output.isEmpty ? "" : output.joined(separator: "\n") + "\n"
        return StrippedConfig(remaining: remaining, hadManagedBlock: hadBlock)
    }

    static func composeSSHConfig(remaining: String, managedBlock: String) -> String {
        let trimmedRemaining = remaining.trimmingCharacters(in: .newlines)
        if trimmedRemaining.isEmpty {
            return managedBlock + "\n"
        }
        return trimmedRemaining + "\n\n" + managedBlock + "\n"
    }

    static func containsHostAlias(_ alias: String, in configText: String) -> Bool {
        let target = alias.lowercased()
        for rawLine in splitLinesPreservingStructure(configText) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace || $0 == "=" })
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for token in parts.dropFirst() {
                if token.hasPrefix("#") { break }
                if token.lowercased() == target {
                    return true
                }
            }
        }
        return false
    }
}
