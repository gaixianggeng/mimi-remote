import CryptoKit
import Darwin
import Foundation

/// 为 Codex 桌面版安全、幂等、可撤销地配置本机回环 SSH（#376）。
/// 只操作标准 `~/.ssh`（专用密钥 + `from="127.0.0.1,::1"` 授权 + 独立标记块）与本应用归属状态文件，不触碰 Codex 私有数据库。
struct CodexLocalSSHConfigurator: Sendable {
    static let hostAlias = "mimi-local"
    static let keyFileName = "mimi_codex_local_ed25519"
    static let keyComment = "mimi-codex-local"
    static let managedBlockStart = "# >>> mimi-remote local codex ssh >>>"
    static let managedBlockEnd = "# <<< mimi-remote local codex ssh <<<"
    static let loopbackAuthorizedKeyOption = #"from="127.0.0.1,::1""#

    typealias CommandRunner = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: Duration) async throws -> CommandResult
    typealias CommitHook = @Sendable (_ targetURL: URL) throws -> Void

    struct ManagedState: Codable, Equatable, Sendable {
        var version: Int = 1
        var keyFingerprint: String?
        var publicKeyBody: String?
        var authorizedKeyEntry: String?
        /// 独立保存托管授权行对应的公钥主体，确保即使密钥已被删除、授权写回失败后重试仍能核验并撤销残留授权。
        var authorizedKeyBody: String?
        var authorizedKeyAddedLeadingNewline: Bool = false
        var managedHostAlias: String?
        var managedUsername: String?

        var effectiveAuthorizedKeyBody: String? {
            if let authorizedKeyBody, !authorizedKeyBody.isEmpty {
                return authorizedKeyBody
            }
            if let publicKeyBody, !publicKeyBody.isEmpty {
                return publicKeyBody
            }
            if let entry = authorizedKeyEntry {
                return CodexLocalSSHConfigurator.parseAuthorizedKeyLine(entry)?.keyBody
            }
            return nil
        }

        var isEmpty: Bool {
            keyFingerprint == nil &&
                publicKeyBody == nil &&
                authorizedKeyEntry == nil &&
                authorizedKeyBody == nil &&
                managedHostAlias == nil
        }
    }

    struct Inspection: Equatable, Sendable {
        var keyExists: Bool = false
        var authorizedKeyInstalled: Bool = false
        var hasRecordedAuthorizedEntry: Bool = false
        var sshConfigInstalled: Bool = false
        var effectiveLoopbackVerified: Bool = false
        var hasConflictingHostAlias: Bool = false
        var hasConflictingKeyFiles: Bool = false
        var hasConflictingAuthorizedKey: Bool = false
        var hasUnsafeFileSystemState: Bool = false

        var isManaged: Bool {
            keyExists || authorizedKeyInstalled || hasRecordedAuthorizedEntry || sshConfigInstalled
        }

        var hasAnyConflict: Bool {
            hasConflictingHostAlias || hasConflictingKeyFiles || hasConflictingAuthorizedKey || hasUnsafeFileSystemState
        }

        /// 只有经 Mimi 归属核验、回环授权无冲突且 `ssh -G` 确认直连当前用户 127.0.0.1:22 时才为 true。
        var isReady: Bool {
            keyExists &&
                authorizedKeyInstalled &&
                sshConfigInstalled &&
                effectiveLoopbackVerified &&
                !hasAnyConflict
        }
    }

    enum ConfigError: LocalizedError, Equatable {
        case invalidUsername
        case conflictingHostAlias(String)
        case conflictingKeyFiles(String)
        case conflictingAuthorizedKey(String)
        case effectiveConfigConflict(String)
        case unsafeFileSystemTarget(String)
        case concurrentModification(String)
        case invalidManagedBlock
        case keyGenerationFailed(String)
        case verificationFailed(String)
        case fileOperationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidUsername:
                "无法识别当前系统用户名，不能生成本机 SSH 配置。"
            case .conflictingHostAlias(let alias):
                "~/.ssh/config（或 Include 的配置）里已有自定义的「Host \(alias)」，为避免覆盖你的原配置已停止。"
            case .conflictingKeyFiles(let detail):
                "检测到并非由 Mimi 创建或已被修改的同名密钥文件，已停止操作以保护你的密钥：\(detail)"
            case .conflictingAuthorizedKey(let detail):
                "~/.ssh/authorized_keys 中存在不受本机回环限制或含冲突选项的同公钥授权，已停止：\(detail)"
            case .effectiveConfigConflict(let detail):
                "~/.ssh/config 的有效 SSH 解析结果未指向本机 127.0.0.1:22 与专用密钥，已停止：\(detail)"
            case .unsafeFileSystemTarget(let detail):
                "SSH 目录或文件为符号链接、非常规文件或属主异常，已拒绝修改：\(detail)"
            case .concurrentModification(let detail):
                "写入前检测到 SSH 配置文件被外部修改，已中止并回滚本次变更：\(detail)"
            case .invalidManagedBlock:
                "~/.ssh/config 中的 Mimi 托管标记块不完整，请先手工核对后再试。"
            case .keyGenerationFailed(let detail):
                detail.isEmpty ? "没能生成本机 SSH 密钥。" : "没能生成本机 SSH 密钥：\(detail)"
            case .verificationFailed(let detail):
                detail.isEmpty
                    ? "本机免密验证未通过，已回滚本次写入的配置。请确认第 1 步「远程登录」已开启。"
                    : "本机免密验证未通过，已回滚本次写入的配置：\(detail)"
            case .fileOperationFailed(let detail):
                "读写 SSH 配置文件失败：\(detail)"
            }
        }
    }

    struct ParsedAuthorizedKeyOption: Equatable, Sendable {
        let name: String
        let value: String?
    }

    struct ParsedAuthorizedKeyLine: Equatable, Sendable {
        let options: [ParsedAuthorizedKeyOption]
        let keyType: String
        let keyBase64: String
        let comment: String

        var keyBody: String { "\(keyType) \(keyBase64)" }

        var isStrictlyLoopbackFrom: Bool {
            let fromOptions = options.filter { $0.name == "from" }
            guard fromOptions.count == 1, let raw = fromOptions[0].value, !raw.isEmpty else {
                return false
            }
            let patterns = raw.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard !patterns.isEmpty else { return false }
            let allowed: Set<String> = ["127.0.0.1", "::1", "127.0.0.1/32", "::1/128"]
            return patterns.allSatisfy { allowed.contains($0.lowercased()) }
        }

        var hasCommandOption: Bool {
            options.contains { $0.name == "command" }
        }
    }

    struct EffectiveSSHConfig: Equatable, Sendable {
        var hostname: String?
        var port: String?
        var user: String?
        var identitiesOnly: String?
        var identityAgent: String?
        var identityFiles: [String] = []
        var certificateFiles: [String] = []
        var pubkeyAuthentication: String?
        var preferredAuthentications: String?
        var pubkeyAcceptedAlgorithms: String?
        var userKnownHostsFile: String?
        var globalKnownHostsFile: String?
        var strictHostKeyChecking: String?
        var clearAllForwardings: String?
        var forwardAgent: String?
        var forwardX11: String?
        var localForwards: [String] = []
        var remoteForwards: [String] = []
        var dynamicForwards: [String] = []
        var proxyJump: String?
        var proxyCommand: String?
        var controlMaster: String?
        var controlPath: String?
        var remoteCommand: String?
        var permitLocalCommand: String?
        var canonicalizeHostname: String?
    }

    let homeDirectory: URL
    let username: String
    let stateFileURL: URL
    let systemSSHConfigPath: String?
    private let runCommand: CommandRunner
    let beforeAtomicCommit: CommitHook?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        username: String = NSUserName(),
        stateFileURL: URL? = nil,
        systemSSHConfigPath: String? = "/etc/ssh/ssh_config",
        runCommand: @escaping CommandRunner = CodexLocalSSHConfigurator.defaultCommandRunner,
        beforeAtomicCommit: CommitHook? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.username = username
        self.stateFileURL = stateFileURL ?? homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MimiRemoteMac", isDirectory: true)
            .appendingPathComponent("codex-local-ssh-state.json", isDirectory: false)
        self.systemSSHConfigPath = systemSSHConfigPath
        self.runCommand = runCommand
        self.beforeAtomicCommit = beforeAtomicCommit
    }

    var sshDirectory: URL { homeDirectory.appendingPathComponent(".ssh", isDirectory: true) }
    var privateKeyURL: URL { sshDirectory.appendingPathComponent(Self.keyFileName) }
    var publicKeyURL: URL { sshDirectory.appendingPathComponent("\(Self.keyFileName).pub") }
    var authorizedKeysURL: URL { sshDirectory.appendingPathComponent("authorized_keys") }
    var sshConfigURL: URL { sshDirectory.appendingPathComponent("config") }
    /// 应用专用主机信任文件：与托管别名和验连共用，绝不写入用户可能由 dotfiles 链接管理的 `~/.ssh/known_hosts`。
    var knownHostsURL: URL {
        stateFileURL.deletingLastPathComponent().appendingPathComponent("codex-local-known-hosts", isDirectory: false)
    }
    var expectedIdentityFileConfigValue: String { "~/.ssh/\(Self.keyFileName)" }
    var expectedKnownHostsPath: String { knownHostsURL.path }

    private var isDefaultUserHome: Bool {
        homeDirectory.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    var lockFileURL: URL {
        stateFileURL.deletingLastPathComponent().appendingPathComponent(".codex-local-ssh.lock")
    }

    static func defaultCommandRunner(executable: URL, arguments: [String], timeout: Duration) async throws -> CommandResult {
        try await ProcessExecutor.shared.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            forceKillAfterTimeout: true
        )
    }

    // MARK: - Public API

    /// 只读检查当前本机 SSH 托管配置状态。
    func inspect() async -> Inspection {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = Inspection()

        do {
            try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh")
            try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName)
            try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub")
            try validateRegularFileIfPresent(authorizedKeysURL, label: "authorized_keys")
            try validateRegularFileIfPresent(sshConfigURL, label: "config")
            try validateStateDirectoryAndFile()
        } catch {
            result.hasUnsafeFileSystemState = true
            return result
        }

        let state = (try? loadManagedState()) ?? nil
        let privateExists = lstatInfo(for: privateKeyURL) != nil
        let publicExists = lstatInfo(for: publicKeyURL) != nil

        // 1. 核验密钥归属与公私钥匹配
        if let state, let expectedBody = state.publicKeyBody, let expectedFingerprint = state.keyFingerprint {
            if privateExists && publicExists {
                if await verifyOwnedKeyPair(expectedBody: expectedBody, expectedFingerprint: expectedFingerprint) {
                    result.keyExists = true
                } else {
                    result.hasConflictingKeyFiles = true
                }
            } else if privateExists || publicExists {
                let singleOwned = await verifyPartialOwnedKey(
                    privateExists: privateExists,
                    publicExists: publicExists,
                    expectedBody: expectedBody,
                    expectedFingerprint: expectedFingerprint
                )
                if !singleOwned {
                    result.hasConflictingKeyFiles = true
                }
            }
        } else if privateExists || publicExists {
            result.hasConflictingKeyFiles = true
        }

        // 2. 核验 authorized_keys（使用独立保存的授权公钥标识，即使密钥已被删除也能识别残留托管授权以保留撤销入口）
        if let state, let expectedAuthBody = state.effectiveAuthorizedKeyBody,
           let authorizedData = try? readRegularFileDataIfPresent(authorizedKeysURL),
           let authorizedContent = String(data: authorizedData, encoding: .utf8) {
            let evaluation = Self.evaluateAuthorizedKeys(
                content: authorizedContent,
                keyBody: expectedAuthBody,
                recordedEntry: state.authorizedKeyEntry
            )
            result.hasConflictingAuthorizedKey = evaluation.hasConflict
            result.authorizedKeyInstalled = evaluation.hasValidLoopbackEntry && !evaluation.hasConflict
            if let recorded = state.authorizedKeyEntry,
               Self.containsExactLine(recorded, in: authorizedContent) {
                result.hasRecordedAuthorizedEntry = true
            }
        }

        // 3. 核验 ~/.ssh/config 托管块、冲突与桌面版实际解析路径的 ssh -G 有效目标
        if let configData = try? readRegularFileDataIfPresent(sshConfigURL),
           let configContent = String(data: configData, encoding: .utf8) {
            if let stripped = try? Self.stripManagedBlock(from: configContent) {
                let hasConflict = containsConflictingHostAlias(Self.hostAlias, in: stripped.remaining)
                result.hasConflictingHostAlias = hasConflict
                let managedByState = state?.managedHostAlias == Self.hostAlias
                result.sshConfigInstalled = stripped.hadManagedBlock && managedByState
                if result.sshConfigInstalled && !hasConflict && !trimmedUser.isEmpty {
                    if let effective = try? await resolveEffectiveSSHConfig(configPath: sshConfigURL.path, alias: Self.hostAlias, includeSystemConfig: true) {
                        result.effectiveLoopbackVerified = Self.validateEffectiveLoopbackConfig(
                            effective,
                            expectedUser: trimmedUser,
                            expectedIdentityFile: expectedIdentityFileConfigValue,
                            expectedKnownHostsFile: expectedKnownHostsPath
                        ) == nil
                    }
                }
            } else {
                result.hasConflictingHostAlias = true
            }
        }

        return result
    }

    /// 一键配置本机回环 SSH 并验证免密连通（串行化、防外部覆盖、失败回滚）。
    func configure(verifyConnection: Bool = true) async throws {
        try await withSerializedLock {
            try await configureLocked(verifyConnection: verifyConnection)
        }
    }

    /// 撤销由 Mimi 写入的本机 SSH 托管授权、专用密钥和配置块。
    /// 即使 ~/.ssh/config 标记损坏，仍先撤销已核验的授权与专用密钥，再报告配置错误。
    func remove() async throws {
        try await withSerializedLock {
            try await removeLocked()
        }
    }

    // MARK: - Serialized Implementations

    private func configureLocked(verifyConnection: Bool) async throws {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty,
              trimmedUser.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ConfigError.invalidUsername
        }
        guard !expectedKnownHostsPath.contains("\""),
              !expectedKnownHostsPath.contains("\n"),
              !expectedKnownHostsPath.contains("\r") else {
            throw ConfigError.unsafeFileSystemTarget("应用专用 known_hosts 路径包含非法字符。")
        }

        // 1. 任何改动前验证所有目录与文件类型及属主（拒绝符号链接与非常规文件，含应用专用 known_hosts）。
        try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh")
        try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName)
        try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub")
        try validateRegularFileIfPresent(authorizedKeysURL, label: "authorized_keys")
        try validateRegularFileIfPresent(sshConfigURL, label: "config")
        try validateStateDirectoryAndFile()

        let previousState = try loadManagedState()
        let configSnapshot = try captureSnapshot(of: sshConfigURL)
        let authSnapshot = try captureSnapshot(of: authorizedKeysURL)

        let existingConfigText = try decodeUTF8(configSnapshot.data, label: "~/.ssh/config")
        let strippedConfig = try Self.stripManagedBlock(from: existingConfigText)
        if containsConflictingHostAlias(Self.hostAlias, in: strippedConfig.remaining) {
            throw ConfigError.conflictingHostAlias(Self.hostAlias)
        }

        // 2. 生成候选 ~/.ssh/config 并在任何写入前按桌面版实际解析路径（含系统 ssh_config）用真实 ssh -G 核验有效目标、身份列表、认证与转发。
        let needsHostReset = Self.hasTopLevelDirectivesBeforeFirstHostOrMatch(strippedConfig.remaining)
        let managedBlock = Self.renderManagedBlock(
            alias: Self.hostAlias,
            username: trimmedUser,
            identityFile: expectedIdentityFileConfigValue,
            knownHostsFile: expectedKnownHostsPath,
            appendGlobalHostReset: needsHostReset
        )
        let candidateConfigText = Self.composeSSHConfig(
            remaining: strippedConfig.remaining,
            managedBlock: managedBlock
        )
        try await validateCandidateSSHConfig(candidateConfigText, expectedUser: trimmedUser)

        // 3. 在改动前校验已有同名密钥文件归属，避免误删或接管用户密钥。
        let keyPlan = try await planKeyPair(existingState: previousState)

        // 若复用已有归属密钥，先校验 authorized_keys 无不受限冲突。
        let existingAuthText = try decodeUTF8(authSnapshot.data, label: "~/.ssh/authorized_keys")
        if let existingKeyBody = keyPlan.existingKeyBody {
            let evaluation = Self.evaluateAuthorizedKeys(
                content: existingAuthText,
                keyBody: existingKeyBody,
                recordedEntry: previousState?.authorizedKeyEntry
            )
            if let conflictReason = evaluation.conflictReason {
                throw ConfigError.conflictingAuthorizedKey(conflictReason)
            }
        }

        // 4. 确保 ~/.ssh 目录存在（新建 0700；已有仅收紧不放宽）。
        let createdSSHDirectory = try ensureSSHDirectory()

        // 跟踪本次调用实际写入的内容与操作前原始快照，用于中途失败或最终验连失败时事务性回滚。
        var rollback = RollbackRecord(
            previousState: previousState,
            createdSSHDirectory: createdSSHDirectory
        )

        do {
            // 5. 在独占临时目录生成并校验 Mimi 专用密钥对，以禁止覆盖方式逐个发布并即时记录。
            let keyMaterial = try await materializeKeyPair(plan: keyPlan, rollback: &rollback)

            // 再次检查 authorized_keys（对于新生成密钥，这里完成首次冲突判定）。
            let latestAuthSnapshot = try captureSnapshot(of: authorizedKeysURL)
            try verifySnapshotUnchanged(authSnapshot, current: latestAuthSnapshot, label: "~/.ssh/authorized_keys")
            let latestAuthText = try decodeUTF8(latestAuthSnapshot.data, label: "~/.ssh/authorized_keys")
            let authEvaluation = Self.evaluateAuthorizedKeys(
                content: latestAuthText,
                keyBody: keyMaterial.publicKeyBody,
                recordedEntry: previousState?.authorizedKeyEntry
            )
            if let conflictReason = authEvaluation.conflictReason {
                throw ConfigError.conflictingAuthorizedKey(conflictReason)
            }

            // 6. 确保应用专用主机信任文件已校验且存在（绝不写入用户 ~/.ssh/known_hosts）。
            try ensureKnownHostsFile(rollback: &rollback)

            // 7. 写 ~/.ssh/config（记录操作前完整数据与原托管块，便于失败回滚并保留外部编辑）。
            let configTargetMode = Self.tightenedFileMode(existing: configSnapshot.mode, maxMode: 0o600)
            if candidateConfigText != existingConfigText {
                var backupURL: URL?
                if configSnapshot.exists && !existingConfigText.isEmpty {
                    backupURL = try createExclusiveBackup(of: configSnapshot.data)
                }
                let configData = Data(candidateConfigText.utf8)
                try writeFileAtomically(
                    configData,
                    to: sshConfigURL,
                    mode: configTargetMode,
                    expectedSnapshot: configSnapshot,
                    label: "~/.ssh/config"
                )
                rollback.wroteSSHConfig = true
                rollback.originalConfigData = configSnapshot.data
                rollback.originalConfigExisted = configSnapshot.exists
                rollback.originalConfigMode = configSnapshot.mode
                rollback.originalHadManagedBlock = strippedConfig.hadManagedBlock
                rollback.originalManagedBlockRaw = strippedConfig.originalManagedBlock
                rollback.writtenConfigData = configData
                rollback.createdBackupURL = backupURL
            } else if configSnapshot.exists {
                try tightenExistingFileIfNeeded(sshConfigURL, currentMode: configSnapshot.mode, maxMode: 0o600)
            }

            // 8. 合并构造 ~/.ssh/authorized_keys（单次原子写入：追加新条目 + 清理重新生成前的旧托管行）。
            var nextState = previousState ?? ManagedState()
            nextState.keyFingerprint = keyMaterial.fingerprint
            nextState.publicKeyBody = keyMaterial.publicKeyBody
            nextState.managedHostAlias = Self.hostAlias
            nextState.managedUsername = trimmedUser

            var workingAuthText = latestAuthText
            var addedEntry: String?
            var addedLeadingNewline = false

            if !authEvaluation.hasValidLoopbackEntry {
                let entry = "\(Self.loopbackAuthorizedKeyOption) \(keyMaterial.publicKeyBody) \(Self.keyComment)"
                let composed = Self.appendAuthorizedKeyEntry(entry, to: workingAuthText)
                workingAuthText = composed.text
                addedEntry = entry
                addedLeadingNewline = composed.addedLeadingNewline
                nextState.authorizedKeyEntry = entry
                nextState.authorizedKeyBody = keyMaterial.publicKeyBody
                nextState.authorizedKeyAddedLeadingNewline = composed.addedLeadingNewline
            } else {
                // 已有合法回环授权：若与 Mimi 记录一致则保留记录；若是用户自建回环条目则不冒领归属。
                if let recorded = previousState?.authorizedKeyEntry,
                   Self.containsExactLine(recorded, in: latestAuthText) {
                    nextState.authorizedKeyEntry = recorded
                    nextState.authorizedKeyBody = previousState?.effectiveAuthorizedKeyBody ?? keyMaterial.publicKeyBody
                    nextState.authorizedKeyAddedLeadingNewline = previousState?.authorizedKeyAddedLeadingNewline ?? false
                } else {
                    nextState.authorizedKeyEntry = nil
                    nextState.authorizedKeyBody = nil
                    nextState.authorizedKeyAddedLeadingNewline = false
                }
            }

            // 若本次重新生成了新密钥，在同一次原子写回中清理之前记录的旧托管授权行。
            var removedPreviousAuthEntry: String?
            if keyPlan.shouldRemovePreviousAuthorizedEntry,
               let oldEntry = previousState?.authorizedKeyEntry,
               let oldBody = previousState?.effectiveAuthorizedKeyBody,
               oldEntry != nextState.authorizedKeyEntry {
                let cleaned = Self.removeExactAuthorizedKeyEntry(
                    oldEntry,
                    expectedKeyBody: oldBody,
                    addedLeadingNewline: previousState?.authorizedKeyAddedLeadingNewline ?? false,
                    from: workingAuthText
                )
                if cleaned.removed {
                    workingAuthText = cleaned.text
                    removedPreviousAuthEntry = oldEntry
                }
            }

            if workingAuthText != latestAuthText {
                let authTargetMode = Self.tightenedFileMode(existing: latestAuthSnapshot.mode, maxMode: 0o600)
                let authData = Data(workingAuthText.utf8)
                try writeFileAtomically(
                    authData,
                    to: authorizedKeysURL,
                    mode: authTargetMode,
                    expectedSnapshot: latestAuthSnapshot,
                    label: "~/.ssh/authorized_keys"
                )
                rollback.wroteAuthorizedKeys = true
                rollback.originalAuthExisted = latestAuthSnapshot.exists
                rollback.originalAuthData = latestAuthSnapshot.data
                rollback.originalAuthMode = latestAuthSnapshot.mode
                rollback.writtenAuthData = authData
                rollback.addedAuthorizedKeyEntry = addedEntry
                rollback.addedAuthorizedKeyBody = addedEntry != nil ? keyMaterial.publicKeyBody : nil
                rollback.addedAuthorizedKeyLeadingNewline = addedLeadingNewline
                rollback.removedPreviousAuthorizedEntry = removedPreviousAuthEntry
            } else if latestAuthSnapshot.exists {
                try tightenExistingFileIfNeeded(authorizedKeysURL, currentMode: latestAuthSnapshot.mode, maxMode: 0o600)
            }

            // 9. 持久化归属状态文件。
            try saveManagedState(nextState)

            // 10. 在回滚事务内按桌面版实际解析路径再次确认 ~/.ssh/config 有效目标，并按托管别名执行免密验连。
            let postEffective = try await resolveEffectiveSSHConfig(
                configPath: sshConfigURL.path,
                alias: Self.hostAlias,
                includeSystemConfig: true
            )
            if let reason = Self.validateEffectiveLoopbackConfig(
                postEffective,
                expectedUser: trimmedUser,
                expectedIdentityFile: expectedIdentityFileConfigValue,
                expectedKnownHostsFile: expectedKnownHostsPath
            ) {
                throw ConfigError.effectiveConfigConflict(reason)
            }

            if verifyConnection {
                try await verifyLoopbackSSH(username: trimmedUser)
            }
        } catch {
            let rollbackOutcome = await performRollback(rollback)
            if !rollbackOutcome.fullyRolledBack {
                let baseMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let detail = rollbackOutcome.detail ?? "部分已写入项未能自动回滚，请点击「移除本机 SSH 配置」清理。"
                throw ConfigError.fileOperationFailed("\(baseMessage)（\(detail)）")
            }
            throw error
        }
    }

    private func removeLocked() async throws {
        try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh")
        try validateStateDirectoryAndFile()

        var state = (try loadManagedState()) ?? ManagedState()
        var errors: [ConfigError] = []

        // 1. 优先撤销 authorized_keys 中可核验的 Mimi 托管行（使用独立保存的 authorizedKeyBody，不受密钥或 config 状态阻断）。
        if lstatInfo(for: authorizedKeysURL) != nil {
            do {
                try validateRegularFileIfPresent(authorizedKeysURL, label: "authorized_keys")
                if let recordedEntry = state.authorizedKeyEntry {
                    guard let recordedBody = state.effectiveAuthorizedKeyBody else {
                        throw ConfigError.fileOperationFailed("Mimi 状态记录缺少托管授权对应的公钥标识，无法安全撤销。")
                    }
                    try removeRecordedAuthorizedEntryIfPresent(
                        entry: recordedEntry,
                        expectedKeyBody: recordedBody,
                        addedLeadingNewline: state.authorizedKeyAddedLeadingNewline
                    )
                    // 仅确认授权已从 authorized_keys 移除后才清除记录。
                    state.authorizedKeyEntry = nil
                    state.authorizedKeyBody = nil
                    state.authorizedKeyAddedLeadingNewline = false
                }
            } catch let error as ConfigError {
                errors.append(error)
            } catch {
                errors.append(.fileOperationFailed(error.localizedDescription))
            }
        } else {
            state.authorizedKeyEntry = nil
            state.authorizedKeyBody = nil
            state.authorizedKeyAddedLeadingNewline = false
        }

        // 2. 仅删除经指纹、公私钥匹配与删除前快照核验确属 Mimi 的专用密钥文件。
        do {
            let removedKeys = try await removeOwnedKeyFilesIfVerified(state: state)
            if removedKeys {
                state.keyFingerprint = nil
                state.publicKeyBody = nil
            }
        } catch let error as ConfigError {
            errors.append(error)
        } catch {
            errors.append(.fileOperationFailed(error.localizedDescription))
        }

        // 3. 移除 ~/.ssh/config 中的托管块（逐字节保留托管块之外的格式）。
        if lstatInfo(for: sshConfigURL) != nil {
            do {
                try validateRegularFileIfPresent(sshConfigURL, label: "config")
                let snapshot = try captureSnapshot(of: sshConfigURL)
                let content = try decodeUTF8(snapshot.data, label: "~/.ssh/config")
                let stripped = try Self.stripManagedBlock(from: content)
                if stripped.hadManagedBlock {
                    let targetMode = Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
                    try writeFileAtomically(
                        Data(stripped.remaining.utf8),
                        to: sshConfigURL,
                        mode: targetMode,
                        expectedSnapshot: snapshot,
                        label: "~/.ssh/config"
                    )
                }
                state.managedHostAlias = nil
                state.managedUsername = nil
            } catch let error as ConfigError {
                errors.append(error)
            } catch {
                errors.append(.fileOperationFailed(error.localizedDescription))
            }
        } else {
            state.managedHostAlias = nil
            state.managedUsername = nil
        }

        // 4. 安全清理应用专用主机信任文件。
        if lstatInfo(for: knownHostsURL) != nil {
            do {
                try removeRegularFileIfPresent(knownHostsURL)
            } catch let error as ConfigError {
                errors.append(error)
            } catch {
                errors.append(.fileOperationFailed(error.localizedDescription))
            }
        }

        // 5. 按实际清理结果更新或移除状态文件。
        if state.isEmpty {
            try? removeRegularFileIfPresent(stateFileURL)
        } else {
            try? saveManagedState(state)
        }

        if let firstError = errors.first {
            throw firstError
        }
    }

    // MARK: - Key Ownership & Generation

    private enum KeyPlanAction {
        case reuseExisting(body: String, fingerprint: String)
        case reconstructPublicKey(body: String, fingerprint: String)
        case regenerateAfterRemovingOwnedPublicKey
        case generateFresh
    }

    private struct KeyPlan {
        let action: KeyPlanAction
        let shouldRemovePreviousAuthorizedEntry: Bool

        var existingKeyBody: String? {
            switch action {
            case .reuseExisting(let body, _), .reconstructPublicKey(let body, _):
                return body
            case .regenerateAfterRemovingOwnedPublicKey, .generateFresh:
                return nil
            }
        }
    }

    private struct KeyMaterial {
        let publicKeyBody: String
        let fingerprint: String
    }

    private func planKeyPair(existingState: ManagedState?) async throws -> KeyPlan {
        let hasPrivate = lstatInfo(for: privateKeyURL) != nil
        let hasPublic = lstatInfo(for: publicKeyURL) != nil

        guard hasPrivate || hasPublic else {
            return KeyPlan(
                action: .generateFresh,
                shouldRemovePreviousAuthorizedEntry: existingState?.authorizedKeyEntry != nil
            )
        }

        guard let expectedBody = existingState?.publicKeyBody,
              let expectedFingerprint = existingState?.keyFingerprint else {
            let detail: String
            if hasPrivate && hasPublic {
                detail = "\(Self.keyFileName) 与 \(Self.keyFileName).pub 已存在且无 Mimi 归属记录。"
            } else if hasPrivate {
                detail = "仅存在未知私钥 \(Self.keyFileName)。"
            } else {
                detail = "仅存在未知公钥 \(Self.keyFileName).pub。"
            }
            throw ConfigError.conflictingKeyFiles(detail)
        }

        if hasPrivate && hasPublic {
            let owned = await verifyOwnedKeyPair(expectedBody: expectedBody, expectedFingerprint: expectedFingerprint)
            guard owned else {
                throw ConfigError.conflictingKeyFiles("\(Self.keyFileName) 的公钥指纹或公私钥匹配关系与 Mimi 记录不一致。")
            }
            return KeyPlan(action: .reuseExisting(body: expectedBody, fingerprint: expectedFingerprint), shouldRemovePreviousAuthorizedEntry: false)
        }

        if hasPrivate && !hasPublic {
            let derived = await derivePublicKeyBodyFromPrivateKey()
            guard let derived,
                  derived == expectedBody,
                  Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: derived) == expectedFingerprint else {
                throw ConfigError.conflictingKeyFiles("仅存在私钥 \(Self.keyFileName)，且与 Mimi 记录的密钥指纹不一致。")
            }
            return KeyPlan(action: .reconstructPublicKey(body: expectedBody, fingerprint: expectedFingerprint), shouldRemovePreviousAuthorizedEntry: false)
        }

        // !hasPrivate && hasPublic
        let existingPubBody = readPublicKeyBody()
        guard let existingPubBody,
              existingPubBody == expectedBody,
              Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: existingPubBody) == expectedFingerprint else {
            throw ConfigError.conflictingKeyFiles("仅存在公钥 \(Self.keyFileName).pub，且与 Mimi 记录的密钥指纹不一致。")
        }
        return KeyPlan(action: .regenerateAfterRemovingOwnedPublicKey, shouldRemovePreviousAuthorizedEntry: true)
    }

    private func materializeKeyPair(plan: KeyPlan, rollback: inout RollbackRecord) async throws -> KeyMaterial {
        switch plan.action {
        case .reuseExisting(let body, let fingerprint):
            if let privInfo = lstatInfo(for: privateKeyURL) {
                try tightenExistingFileIfNeeded(privateKeyURL, currentMode: privInfo.mode, maxMode: 0o600)
            }
            if let pubInfo = lstatInfo(for: publicKeyURL) {
                try tightenExistingFileIfNeeded(publicKeyURL, currentMode: pubInfo.mode, maxMode: 0o644)
            }
            return KeyMaterial(publicKeyBody: body, fingerprint: fingerprint)

        case .reconstructPublicKey(let body, let fingerprint):
            let pubContent = "\(body) \(Self.keyComment)\n"
            let publishedSnapshot = try publishExclusiveNewFile(
                Data(pubContent.utf8),
                to: publicKeyURL,
                mode: 0o644,
                label: "\(Self.keyFileName).pub"
            )
            rollback.createdPublicKey = true
            rollback.createdPublicKeySnapshot = publishedSnapshot
            rollback.generatedKeyBody = body
            return KeyMaterial(publicKeyBody: body, fingerprint: fingerprint)

        case .regenerateAfterRemovingOwnedPublicKey:
            let pubSnapshot = try captureSnapshot(of: publicKeyURL)
            if pubSnapshot.exists {
                try removeFileMatchingSnapshot(publicKeyURL, expectedSnapshot: pubSnapshot, label: "\(Self.keyFileName).pub", invokeHook: false)
                rollback.removedOwnedPublicKeyData = pubSnapshot.data
                rollback.removedOwnedPublicKeyMode = pubSnapshot.mode
            }
            return try await generateNewKeyPair(rollback: &rollback)

        case .generateFresh:
            return try await generateNewKeyPair(rollback: &rollback)
        }
    }

    /// 在独占临时目录（0700）生成并校验密钥对，随后以禁止覆盖方式逐个发布到 `~/.ssh` 并即时登记回滚快照。
    private func generateNewKeyPair(rollback: inout RollbackRecord) async throws -> KeyMaterial {
        let stagingDir = sshDirectory.appendingPathComponent(".mimi-keygen-\(UUID().uuidString)", isDirectory: true)
        guard Darwin.mkdir(stagingDir.path, 0o700) == 0 else {
            throw ConfigError.fileOperationFailed("无法创建独占密钥临时目录：\(Self.posixErrorMessage())")
        }
        let stagingPrivateURL = stagingDir.appendingPathComponent(Self.keyFileName)
        let stagingPublicURL = stagingDir.appendingPathComponent("\(Self.keyFileName).pub")
        defer {
            _ = Darwin.unlink(stagingPrivateURL.path)
            _ = Darwin.unlink(stagingPublicURL.path)
            _ = Darwin.rmdir(stagingDir.path)
        }
        let dirFD = Darwin.open(stagingDir.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard dirFD >= 0 else {
            throw ConfigError.fileOperationFailed("无法校验密钥临时目录：\(Self.posixErrorMessage())")
        }
        _ = Darwin.fchmod(dirFD, 0o700)
        Darwin.close(dirFD)

        let result: CommandResult
        do {
            result = try await runCommand(
                URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                ["-q", "-t", "ed25519", "-N", "", "-C", Self.keyComment, "-f", stagingPrivateURL.path],
                .seconds(15)
            )
        } catch {
            throw ConfigError.keyGenerationFailed(error.localizedDescription)
        }
        guard result.status == 0 else {
            throw ConfigError.keyGenerationFailed(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try validateRegularFileIfPresent(stagingPrivateURL, label: Self.keyFileName)
        try validateRegularFileIfPresent(stagingPublicURL, label: "\(Self.keyFileName).pub")
        if let privInfo = lstatInfo(for: stagingPrivateURL) {
            try tightenExistingFileIfNeeded(stagingPrivateURL, currentMode: privInfo.mode, maxMode: 0o600)
        }
        if let pubInfo = lstatInfo(for: stagingPublicURL) {
            try tightenExistingFileIfNeeded(stagingPublicURL, currentMode: pubInfo.mode, maxMode: 0o644)
        }

        let stagedPrivateSnapshot = try captureSnapshot(of: stagingPrivateURL)
        let stagedPublicSnapshot = try captureSnapshot(of: stagingPublicURL)
        guard stagedPrivateSnapshot.exists, stagedPublicSnapshot.exists else {
            throw ConfigError.keyGenerationFailed("临时目录中未生成完整的公私钥文件。")
        }

        guard let pubText = String(data: stagedPublicSnapshot.data, encoding: .utf8),
              let pubBody = Self.extractPublicKeyBody(from: pubText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let fingerprint = Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: pubBody) else {
            throw ConfigError.keyGenerationFailed("未读取到有效公钥内容。")
        }
        guard let derivedBody = await derivePublicKeyBody(fromPrivateKeySnapshot: stagedPrivateSnapshot),
              derivedBody == pubBody else {
            throw ConfigError.keyGenerationFailed("生成的私钥与公钥不匹配。")
        }

        // 先以禁止覆盖方式发布私钥，发布成功立即登记回滚快照；若后续发布公钥失败，回滚必会清理该私钥。
        let publishedPrivateSnapshot = try publishStagedKeyFile(
            from: stagingPrivateURL,
            stagedSnapshot: stagedPrivateSnapshot,
            to: privateKeyURL,
            mode: 0o600,
            label: Self.keyFileName
        )
        rollback.createdPrivateKey = true
        rollback.createdPrivateKeySnapshot = publishedPrivateSnapshot
        rollback.generatedKeyBody = pubBody

        let publishedPublicSnapshot = try publishStagedKeyFile(
            from: stagingPublicURL,
            stagedSnapshot: stagedPublicSnapshot,
            to: publicKeyURL,
            mode: 0o644,
            label: "\(Self.keyFileName).pub"
        )
        rollback.createdPublicKey = true
        rollback.createdPublicKeySnapshot = publishedPublicSnapshot

        return KeyMaterial(publicKeyBody: pubBody, fingerprint: fingerprint)
    }

    private func verifyOwnedKeyPair(expectedBody: String, expectedFingerprint: String) async -> Bool {
        guard let pubBody = readPublicKeyBody(),
              pubBody == expectedBody,
              Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: pubBody) == expectedFingerprint else {
            return false
        }
        guard let derivedBody = await derivePublicKeyBodyFromPrivateKey(),
              derivedBody == expectedBody else {
            return false
        }
        return true
    }

    private func verifyPartialOwnedKey(
        privateExists: Bool,
        publicExists: Bool,
        expectedBody: String,
        expectedFingerprint: String
    ) async -> Bool {
        if privateExists {
            guard let derived = await derivePublicKeyBodyFromPrivateKey(),
                  derived == expectedBody,
                  Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: derived) == expectedFingerprint else {
                return false
            }
            return true
        }
        if publicExists {
            guard let pubBody = readPublicKeyBody(),
                  pubBody == expectedBody,
                  Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: pubBody) == expectedFingerprint else {
                return false
            }
            return true
        }
        return true
    }

    private func removeOwnedKeyFilesIfVerified(state: ManagedState) async throws -> Bool {
        let hasPrivate = lstatInfo(for: privateKeyURL) != nil
        let hasPublic = lstatInfo(for: publicKeyURL) != nil
        guard hasPrivate || hasPublic else { return true }

        guard let expectedBody = state.publicKeyBody,
              let expectedFingerprint = state.keyFingerprint else {
            throw ConfigError.conflictingKeyFiles("存在未记录归属的同名密钥文件，撤销时已保留未删除。")
        }

        var mismatchDetails: [String] = []
        var verifiedPrivateSnapshot: FileSnapshot?
        var verifiedPublicSnapshot: FileSnapshot?

        if hasPrivate {
            try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName)
            let snapshot = try captureSnapshot(of: privateKeyURL)
            if snapshot.exists,
               let derived = await derivePublicKeyBody(fromPrivateKeySnapshot: snapshot),
               derived == expectedBody,
               Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: derived) == expectedFingerprint {
                verifiedPrivateSnapshot = snapshot
            } else {
                mismatchDetails.append(Self.keyFileName)
            }
        }
        if hasPublic {
            try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub")
            let snapshot = try captureSnapshot(of: publicKeyURL)
            if snapshot.exists,
               let raw = String(data: snapshot.data, encoding: .utf8),
               let pubBody = Self.extractPublicKeyBody(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               pubBody == expectedBody,
               Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: pubBody) == expectedFingerprint {
                verifiedPublicSnapshot = snapshot
            } else {
                mismatchDetails.append("\(Self.keyFileName).pub")
            }
        }

        // 删除前再次核对已验证的文件快照（dev/ino/size/mtime/data），防止异步验指纹期间被替换为其他文件后误删。
        if let privSnapshot = verifiedPrivateSnapshot {
            do {
                try removeFileMatchingSnapshot(privateKeyURL, expectedSnapshot: privSnapshot, label: Self.keyFileName, invokeHook: true)
            } catch ConfigError.conflictingKeyFiles {
                mismatchDetails.append(Self.keyFileName)
            }
        }
        if let pubSnapshot = verifiedPublicSnapshot {
            do {
                try removeFileMatchingSnapshot(publicKeyURL, expectedSnapshot: pubSnapshot, label: "\(Self.keyFileName).pub", invokeHook: true)
            } catch ConfigError.conflictingKeyFiles {
                mismatchDetails.append("\(Self.keyFileName).pub")
            }
        }

        if !mismatchDetails.isEmpty {
            throw ConfigError.conflictingKeyFiles("密钥文件 \(mismatchDetails.joined(separator: "、")) 与 Mimi 记录的指纹不匹配或在删除前被替换，已保留未删除。")
        }
        return true
    }

    private func derivePublicKeyBodyFromPrivateKey() async -> String? {
        guard let snapshot = try? captureSnapshot(of: privateKeyURL), snapshot.exists else {
            return nil
        }
        return await derivePublicKeyBody(fromPrivateKeySnapshot: snapshot)
    }

    /// 对已捕获的私钥字节快照写入独占 0600 临时副本后调用 `ssh-keygen -y`，确保校验结果严格绑定该快照字节。
    private func derivePublicKeyBody(fromPrivateKeySnapshot snapshot: FileSnapshot) async -> String? {
        guard snapshot.exists, !snapshot.data.isEmpty else { return nil }
        let tempKeyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(".mimi-keyverify-\(UUID().uuidString)")
        do {
            try writeExclusiveTempFile(snapshot.data, to: tempKeyURL, mode: 0o600)
        } catch {
            return nil
        }
        defer { _ = Darwin.unlink(tempKeyURL.path) }

        guard let result = try? await runCommand(
            URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            ["-y", "-P", "", "-f", tempKeyURL.path],
            .seconds(10)
        ), result.status == 0 else {
            return nil
        }
        let line = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.extractPublicKeyBody(from: line)
    }

    // MARK: - Rollback

    struct RollbackRecord {
        var previousState: ManagedState?
        var createdSSHDirectory: Bool = false
        var createdPrivateKey: Bool = false
        var createdPrivateKeySnapshot: FileSnapshot?
        var createdPublicKey: Bool = false
        var createdPublicKeySnapshot: FileSnapshot?
        var generatedKeyBody: String?
        var removedOwnedPublicKeyData: Data?
        var removedOwnedPublicKeyMode: mode_t?
        var wroteSSHConfig: Bool = false
        var originalConfigData: Data = Data()
        var originalConfigExisted: Bool = false
        var originalConfigMode: mode_t?
        var originalHadManagedBlock: Bool = false
        var originalManagedBlockRaw: String?
        var writtenConfigData: Data?
        var createdBackupURL: URL?
        var wroteAuthorizedKeys: Bool = false
        var originalAuthExisted: Bool = false
        var originalAuthData: Data = Data()
        var originalAuthMode: mode_t?
        var writtenAuthData: Data?
        var addedAuthorizedKeyEntry: String?
        var addedAuthorizedKeyBody: String?
        var addedAuthorizedKeyLeadingNewline: Bool = false
        var removedPreviousAuthorizedEntry: String?
        var createdKnownHostsFile: Bool = false
        var originalKnownHostsData: Data?
        var originalKnownHostsMode: mode_t?
    }

    private struct RollbackOutcome {
        var fullyRolledBack: Bool = true
        var detail: String?
    }

    private func performRollback(_ rollback: RollbackRecord) async -> RollbackOutcome {
        var outcome = RollbackOutcome()
        var fallbackState = rollback.previousState ?? ManagedState()
        var residualAuthorizedEntry: String?

        // 1. 回滚本次对 authorized_keys 的写入：若无外部编辑则精确恢复原始字节；若有外部编辑则仅撤回本次条目并保留外部修改。
        if rollback.wroteAuthorizedKeys {
            var authReverted = false
            if let snapshot = try? captureSnapshot(of: authorizedKeysURL), snapshot.exists {
                if let written = rollback.writtenAuthData, snapshot.data == written {
                    if !rollback.originalAuthExisted {
                        authReverted = (try? removeRegularFileIfPresent(authorizedKeysURL)) != nil
                    } else {
                        let mode = rollback.originalAuthMode ?? 0o600
                        authReverted = (try? writeFileAtomically(
                            rollback.originalAuthData,
                            to: authorizedKeysURL,
                            mode: mode,
                            expectedSnapshot: snapshot,
                            label: "~/.ssh/authorized_keys",
                            invokeHook: false
                        )) != nil
                    }
                } else if let text = String(data: snapshot.data, encoding: .utf8) {
                    var working = text
                    var changed = false
                    if let entry = rollback.addedAuthorizedKeyEntry,
                       let keyBody = rollback.addedAuthorizedKeyBody ?? rollback.generatedKeyBody ?? rollback.previousState?.effectiveAuthorizedKeyBody {
                        let reverted = Self.removeExactAuthorizedKeyEntry(
                            entry,
                            expectedKeyBody: keyBody,
                            addedLeadingNewline: rollback.addedAuthorizedKeyLeadingNewline,
                            from: working
                        )
                        if reverted.removed {
                            working = reverted.text
                            changed = true
                        }
                    }
                    if let oldEntry = rollback.removedPreviousAuthorizedEntry,
                       !Self.containsExactLine(oldEntry, in: working) {
                        working = Self.appendAuthorizedKeyEntry(oldEntry, to: working).text
                        changed = true
                    }
                    if changed {
                        let mode = Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
                        authReverted = (try? writeFileAtomically(
                            Data(working.utf8),
                            to: authorizedKeysURL,
                            mode: mode,
                            expectedSnapshot: snapshot,
                            label: "~/.ssh/authorized_keys",
                            invokeHook: false
                        )) != nil
                    } else {
                        authReverted = true
                    }
                }
            } else {
                authReverted = !rollback.originalAuthExisted
            }

            if !authReverted {
                outcome.fullyRolledBack = false
                outcome.detail = "未能自动回滚 ~/.ssh/authorized_keys，请点击「移除本机 SSH 配置」清理。"
                residualAuthorizedEntry = rollback.addedAuthorizedKeyEntry
            }
        }

        // 2. 回滚本次对 ~/.ssh/config 的写入：若更新过原有托管块则恢复旧块，同时保留外部编辑。
        if rollback.wroteSSHConfig {
            var configReverted = false
            if let snapshot = try? captureSnapshot(of: sshConfigURL), snapshot.exists {
                if let written = rollback.writtenConfigData, snapshot.data == written {
                    if !rollback.originalConfigExisted {
                        configReverted = (try? removeRegularFileIfPresent(sshConfigURL)) != nil
                    } else {
                        let mode = rollback.originalConfigMode ?? 0o600
                        configReverted = (try? writeFileAtomically(
                            rollback.originalConfigData,
                            to: sshConfigURL,
                            mode: mode,
                            expectedSnapshot: snapshot,
                            label: "~/.ssh/config",
                            invokeHook: false
                        )) != nil
                    }
                } else if let text = String(data: snapshot.data, encoding: .utf8) {
                    if rollback.originalHadManagedBlock, let oldBlock = rollback.originalManagedBlockRaw {
                        if let restoredText = try? Self.replaceManagedBlock(in: text, with: oldBlock) {
                            let mode = rollback.originalConfigMode ?? Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
                            configReverted = (try? writeFileAtomically(
                                Data(restoredText.utf8),
                                to: sshConfigURL,
                                mode: mode,
                                expectedSnapshot: snapshot,
                                label: "~/.ssh/config",
                                invokeHook: false
                            )) != nil
                        }
                    } else if let stripped = try? Self.stripManagedBlock(from: text), stripped.hadManagedBlock {
                        if !rollback.originalConfigExisted && stripped.remaining.isEmpty {
                            configReverted = (try? removeRegularFileIfPresent(sshConfigURL)) != nil
                        } else {
                            let mode = rollback.originalConfigMode ?? Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
                            configReverted = (try? writeFileAtomically(
                                Data(stripped.remaining.utf8),
                                to: sshConfigURL,
                                mode: mode,
                                expectedSnapshot: snapshot,
                                label: "~/.ssh/config",
                                invokeHook: false
                            )) != nil
                        }
                    }
                }
            } else {
                configReverted = !rollback.originalConfigExisted
            }

            if !configReverted {
                outcome.fullyRolledBack = false
                if outcome.detail == nil {
                    outcome.detail = "未能自动回滚 ~/.ssh/config，请核对或点击「移除本机 SSH 配置」清理。"
                }
            } else if let backupURL = rollback.createdBackupURL {
                try? removeRegularFileIfPresent(backupURL)
            }
        }

        // 3. 回滚应用专用 known_hosts 文件
        if rollback.createdKnownHostsFile {
            try? removeRegularFileIfPresent(knownHostsURL)
        } else if let origKH = rollback.originalKnownHostsData,
                  let currentKH = try? captureSnapshot(of: knownHostsURL),
                  currentKH.exists,
                  currentKH.data != origKH {
            try? writeFileAtomically(
                origKH,
                to: knownHostsURL,
                mode: rollback.originalKnownHostsMode ?? 0o600,
                expectedSnapshot: currentKH,
                label: knownHostsURL.lastPathComponent,
                invokeHook: false
            )
        }

        // 4. 按发布快照安全回滚本次新建的密钥文件（绝不删外部替换的同名文件）
        if rollback.createdPrivateKey, let snapshot = rollback.createdPrivateKeySnapshot {
            do {
                try removeFileMatchingSnapshot(privateKeyURL, expectedSnapshot: snapshot, label: Self.keyFileName, invokeHook: false)
            } catch {
                // 若文件已被外部替换，不删除并保留状态提醒。
            }
        }
        if rollback.createdPublicKey, let snapshot = rollback.createdPublicKeySnapshot {
            do {
                try removeFileMatchingSnapshot(publicKeyURL, expectedSnapshot: snapshot, label: "\(Self.keyFileName).pub", invokeHook: false)
            } catch {
                // 若文件已被外部替换，不删除。
            }
        }
        if let oldPubData = rollback.removedOwnedPublicKeyData, lstatInfo(for: publicKeyURL) == nil {
            _ = try? publishExclusiveNewFile(
                oldPubData,
                to: publicKeyURL,
                mode: rollback.removedOwnedPublicKeyMode ?? 0o644,
                label: "\(Self.keyFileName).pub",
                invokeHook: false
            )
        }

        // 5. 恢复之前的 state 文件；若授权回滚失败则保留残留授权记录以便后续 remove() 撤销。
        if !outcome.fullyRolledBack, let residualAuthorizedEntry {
            fallbackState.authorizedKeyEntry = residualAuthorizedEntry
            fallbackState.authorizedKeyBody = rollback.addedAuthorizedKeyBody ?? rollback.generatedKeyBody
            fallbackState.authorizedKeyAddedLeadingNewline = rollback.addedAuthorizedKeyLeadingNewline
            try? saveManagedState(fallbackState)
        } else if let previousState = rollback.previousState {
            try? saveManagedState(previousState)
        } else {
            try? removeRegularFileIfPresent(stateFileURL)
        }

        return outcome
    }

    // MARK: - OpenSSH Effective Config & Desktop-Path Verification

    private func buildCombinedSSHConfigForEvaluation(userConfigText: String) -> String {
        guard let sysPath = systemSSHConfigPath,
              !sysPath.isEmpty,
              FileManager.default.isReadableFile(atPath: sysPath) else {
            return userConfigText
        }
        var combined = userConfigText
        if !combined.isEmpty && combined.utf8.last != 0x0A {
            combined.append("\n")
        }
        combined.append("Host *\nInclude \"\(sysPath)\"\n")
        return combined
    }

    private func validateCandidateSSHConfig(_ candidateText: String, expectedUser: String) async throws {
        let evalText = buildCombinedSSHConfigForEvaluation(userConfigText: candidateText)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(".mimi-ssh-candidate-\(UUID().uuidString).conf")
        try writeExclusiveTempFile(Data(evalText.utf8), to: tempURL, mode: 0o600)
        defer { _ = Darwin.unlink(tempURL.path) }

        let effective = try await resolveEffectiveSSHConfig(
            configPath: tempURL.path,
            alias: Self.hostAlias,
            includeSystemConfig: false
        )
        if let conflict = Self.validateEffectiveLoopbackConfig(
            effective,
            expectedUser: expectedUser,
            expectedIdentityFile: expectedIdentityFileConfigValue,
            expectedKnownHostsFile: expectedKnownHostsPath
        ) {
            throw ConfigError.effectiveConfigConflict(conflict)
        }
    }

    func resolveEffectiveSSHConfig(
        configPath: String,
        alias: String,
        includeSystemConfig: Bool = true
    ) async throws -> EffectiveSSHConfig {
        var tempCombinedURL: URL?
        defer {
            if let tempCombinedURL {
                _ = Darwin.unlink(tempCombinedURL.path)
            }
        }

        let arguments: [String]
        if includeSystemConfig,
           isDefaultUserHome,
           configPath == sshConfigURL.path,
           systemSSHConfigPath == "/etc/ssh/ssh_config" {
            // 默认用户主目录直接走不带 -F 的真实桌面版解析路径（同时加载 ~/.ssh/config 与 /etc/ssh/ssh_config）。
            arguments = ["-G", alias]
        } else if includeSystemConfig,
                  let sysPath = systemSSHConfigPath,
                  !sysPath.isEmpty,
                  FileManager.default.isReadableFile(atPath: sysPath),
                  let rawData = try? readRegularFileDataIfPresent(URL(fileURLWithPath: configPath)),
                  let rawText = String(data: rawData, encoding: .utf8) {
            let combined = buildCombinedSSHConfigForEvaluation(userConfigText: rawText)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(".mimi-ssh-eval-\(UUID().uuidString).conf")
            try writeExclusiveTempFile(Data(combined.utf8), to: tempURL, mode: 0o600)
            tempCombinedURL = tempURL
            arguments = ["-G", "-F", tempURL.path, alias]
        } else {
            arguments = ["-G", "-F", configPath, alias]
        }

        let result: CommandResult
        do {
            result = try await runCommand(
                URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments,
                .seconds(10)
            )
        } catch {
            throw ConfigError.effectiveConfigConflict("无法解析 SSH 配置：\(error.localizedDescription)")
        }
        guard result.status == 0 else {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConfigError.effectiveConfigConflict(stderr.isEmpty ? "ssh -G 返回状态码 \(result.status)" : stderr)
        }
        return Self.parseEffectiveSSHConfig(result.stdoutText)
    }

    /// 使用桌面版实际调用的托管别名 `mimi-local`（经 ssh -G 验证直连当前用户 127.0.0.1:22、仅专用私钥与应用专用 known_hosts）验证免密连通。
    private func verifyLoopbackSSH(username: String) async throws {
        try validateStateDirectoryAndFile()

        var tempCombinedURL: URL?
        defer {
            if let tempCombinedURL {
                _ = Darwin.unlink(tempCombinedURL.path)
            }
        }

        var arguments: [String] = []
        if isDefaultUserHome, systemSSHConfigPath == "/etc/ssh/ssh_config" {
            // 与 Codex 桌面版完全一致的默认配置加载路径（~/.ssh/config + /etc/ssh/ssh_config）。
        } else if let sysPath = systemSSHConfigPath,
                  !sysPath.isEmpty,
                  FileManager.default.isReadableFile(atPath: sysPath),
                  let rawData = try? readRegularFileDataIfPresent(sshConfigURL),
                  let rawText = String(data: rawData, encoding: .utf8) {
            let combined = buildCombinedSSHConfigForEvaluation(userConfigText: rawText)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(".mimi-ssh-verify-\(UUID().uuidString).conf")
            try writeExclusiveTempFile(Data(combined.utf8), to: tempURL, mode: 0o600)
            tempCombinedURL = tempURL
            arguments.append(contentsOf: ["-F", tempURL.path])
        } else {
            arguments.append(contentsOf: ["-F", sshConfigURL.path])
        }

        arguments.append(contentsOf: [
            "-o", "BatchMode=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "ConnectTimeout=5",
            Self.hostAlias,
            "true",
        ])

        let result: CommandResult
        do {
            result = try await runCommand(
                URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments,
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
        _ = username
    }

    // MARK: - Authorized Keys Helpers

    private func removeRecordedAuthorizedEntryIfPresent(
        entry: String,
        expectedKeyBody: String,
        addedLeadingNewline: Bool
    ) throws {
        let snapshot = try captureSnapshot(of: authorizedKeysURL)
        guard snapshot.exists else { return }
        let content = try decodeUTF8(snapshot.data, label: "~/.ssh/authorized_keys")
        let result = Self.removeExactAuthorizedKeyEntry(
            entry,
            expectedKeyBody: expectedKeyBody,
            addedLeadingNewline: addedLeadingNewline,
            from: content
        )
        guard result.removed else { return }
        let targetMode = Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
        try writeFileAtomically(
            Data(result.text.utf8),
            to: authorizedKeysURL,
            mode: targetMode,
            expectedSnapshot: snapshot,
            label: "~/.ssh/authorized_keys"
        )
    }
}
