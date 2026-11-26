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
        var authorizedKeyAddedLeadingNewline: Bool = false
        var managedHostAlias: String?
        var managedUsername: String?

        var isEmpty: Bool {
            keyFingerprint == nil &&
                publicKeyBody == nil &&
                authorizedKeyEntry == nil &&
                managedHostAlias == nil
        }
    }

    struct Inspection: Equatable, Sendable {
        var keyExists: Bool = false
        var authorizedKeyInstalled: Bool = false
        var sshConfigInstalled: Bool = false
        var effectiveLoopbackVerified: Bool = false
        var hasConflictingHostAlias: Bool = false
        var hasConflictingKeyFiles: Bool = false
        var hasConflictingAuthorizedKey: Bool = false
        var hasUnsafeFileSystemState: Bool = false

        var isManaged: Bool {
            keyExists || authorizedKeyInstalled || sshConfigInstalled
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
                    ? "配置已写入，但本机免密验证未通过。请确认第 1 步「远程登录」已开启。"
                    : "本机免密验证未通过：\(detail)"
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
        var proxyJump: String?
        var proxyCommand: String?
        var controlMaster: String?
        var controlPath: String?
        var remoteCommand: String?
    }

    let homeDirectory: URL
    let username: String
    let stateFileURL: URL
    private let runCommand: CommandRunner
    private let beforeAtomicCommit: CommitHook?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        username: String = NSUserName(),
        stateFileURL: URL? = nil,
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
        self.runCommand = runCommand
        self.beforeAtomicCommit = beforeAtomicCommit
    }

    var sshDirectory: URL { homeDirectory.appendingPathComponent(".ssh", isDirectory: true) }
    var privateKeyURL: URL { sshDirectory.appendingPathComponent(Self.keyFileName) }
    var publicKeyURL: URL { sshDirectory.appendingPathComponent("\(Self.keyFileName).pub") }
    var authorizedKeysURL: URL { sshDirectory.appendingPathComponent("authorized_keys") }
    var sshConfigURL: URL { sshDirectory.appendingPathComponent("config") }
    var expectedIdentityFileConfigValue: String { "~/.ssh/\(Self.keyFileName)" }

    private var lockFileURL: URL {
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
            try validateRegularFileIfPresent(stateFileURL, label: stateFileURL.lastPathComponent)
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

        // 2. 核验 authorized_keys（仅当密钥已确认归属时检查是否有效且无不受限同公钥）
        if let state, let expectedBody = state.publicKeyBody,
           let authorizedData = try? readRegularFileDataIfPresent(authorizedKeysURL),
           let authorizedContent = String(data: authorizedData, encoding: .utf8) {
            let evaluation = Self.evaluateAuthorizedKeys(
                content: authorizedContent,
                keyBody: expectedBody,
                recordedEntry: state.authorizedKeyEntry
            )
            result.hasConflictingAuthorizedKey = evaluation.hasConflict
            result.authorizedKeyInstalled = evaluation.hasValidLoopbackEntry && !evaluation.hasConflict
        }

        // 3. 核验 ~/.ssh/config 托管块、冲突与真实 ssh -G 有效目标
        if let configData = try? readRegularFileDataIfPresent(sshConfigURL),
           let configContent = String(data: configData, encoding: .utf8) {
            if let stripped = try? Self.stripManagedBlock(from: configContent) {
                let hasConflict = containsConflictingHostAlias(Self.hostAlias, in: stripped.remaining)
                result.hasConflictingHostAlias = hasConflict
                let managedByState = state?.managedHostAlias == Self.hostAlias
                result.sshConfigInstalled = stripped.hadManagedBlock && managedByState
                if result.sshConfigInstalled && !hasConflict && !trimmedUser.isEmpty {
                    if let effective = try? await resolveEffectiveSSHConfig(configPath: sshConfigURL.path, alias: Self.hostAlias) {
                        result.effectiveLoopbackVerified = Self.validateEffectiveLoopbackConfig(
                            effective,
                            expectedUser: trimmedUser,
                            expectedIdentityFile: expectedIdentityFileConfigValue
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

        // 1. 任何改动前验证所有目录与文件类型及属主（拒绝符号链接与非常规文件）。
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

        // 2. 生成候选 ~/.ssh/config 并在任何写入前用真实 ssh -G 核验有效目标。
        let needsHostReset = Self.hasTopLevelDirectivesBeforeFirstHostOrMatch(strippedConfig.remaining)
        let managedBlock = Self.renderManagedBlock(
            alias: Self.hostAlias,
            username: trimmedUser,
            identityFile: expectedIdentityFileConfigValue,
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

        // 跟踪本次调用实际写入的内容，用于中途失败时仅回滚本次变更。
        var rollback = RollbackRecord(
            previousState: previousState,
            createdSSHDirectory: createdSSHDirectory
        )

        do {
            // 5. 生成或修复 Mimi 专用密钥对。
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

            // 6. 先写 ~/.ssh/config（如果后续授权写入失败，残留配置不会开放未授权登录，且会回滚）。
            let configTargetMode = Self.tightenedFileMode(existing: configSnapshot.mode, maxMode: 0o600)
            if candidateConfigText != existingConfigText {
                if configSnapshot.exists && !existingConfigText.isEmpty {
                    try createExclusiveBackup(of: configSnapshot.data)
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
            } else if configSnapshot.exists {
                try tightenExistingFileIfNeeded(sshConfigURL, currentMode: configSnapshot.mode, maxMode: 0o600)
            }

            // 7. 写入 ~/.ssh/authorized_keys（按公钥内容识别重复，保留已有条目/选项与原始换行格式）。
            var nextState = previousState ?? ManagedState()
            nextState.keyFingerprint = keyMaterial.fingerprint
            nextState.publicKeyBody = keyMaterial.publicKeyBody
            nextState.managedHostAlias = Self.hostAlias
            nextState.managedUsername = trimmedUser

            if !authEvaluation.hasValidLoopbackEntry {
                let entry = "\(Self.loopbackAuthorizedKeyOption) \(keyMaterial.publicKeyBody) \(Self.keyComment)"
                let composed = Self.appendAuthorizedKeyEntry(entry, to: latestAuthText)
                let authTargetMode = Self.tightenedFileMode(existing: latestAuthSnapshot.mode, maxMode: 0o600)
                try writeFileAtomically(
                    Data(composed.text.utf8),
                    to: authorizedKeysURL,
                    mode: authTargetMode,
                    expectedSnapshot: latestAuthSnapshot,
                    label: "~/.ssh/authorized_keys"
                )
                rollback.addedAuthorizedKeyEntry = entry
                rollback.addedAuthorizedKeyLeadingNewline = composed.addedLeadingNewline
                rollback.createdAuthorizedKeysFile = !latestAuthSnapshot.exists
                nextState.authorizedKeyEntry = entry
                nextState.authorizedKeyAddedLeadingNewline = composed.addedLeadingNewline
            } else {
                // 已有合法回环授权：若与 Mimi 记录一致则保留记录；若是用户自建回环条目则不冒领归属。
                if let recorded = previousState?.authorizedKeyEntry,
                   Self.containsExactLine(recorded, in: latestAuthText) {
                    nextState.authorizedKeyEntry = recorded
                    nextState.authorizedKeyAddedLeadingNewline = previousState?.authorizedKeyAddedLeadingNewline ?? false
                } else {
                    nextState.authorizedKeyEntry = nil
                    nextState.authorizedKeyAddedLeadingNewline = false
                }
                if latestAuthSnapshot.exists {
                    try tightenExistingFileIfNeeded(authorizedKeysURL, currentMode: latestAuthSnapshot.mode, maxMode: 0o600)
                }
            }

            // 若本次重新生成了新密钥，清理之前记录的旧托管授权行（仅限可核验旧条目）。
            if keyPlan.shouldRemovePreviousAuthorizedEntry,
               let oldEntry = previousState?.authorizedKeyEntry,
               let oldBody = previousState?.publicKeyBody,
               oldEntry != nextState.authorizedKeyEntry {
                try removeRecordedAuthorizedEntryIfPresent(
                    entry: oldEntry,
                    expectedKeyBody: oldBody,
                    addedLeadingNewline: previousState?.authorizedKeyAddedLeadingNewline ?? false
                )
            }

            // 8. 持久化归属状态文件。
            try saveManagedState(nextState)
        } catch {
            await performRollback(rollback)
            throw error
        }

        // 9. 提交后再次确认 ~/.ssh/config 的有效 ssh -G 目标，再执行隔离免密验连。
        let postEffective = try await resolveEffectiveSSHConfig(configPath: sshConfigURL.path, alias: Self.hostAlias)
        if let reason = Self.validateEffectiveLoopbackConfig(
            postEffective,
            expectedUser: trimmedUser,
            expectedIdentityFile: expectedIdentityFileConfigValue
        ) {
            throw ConfigError.effectiveConfigConflict(reason)
        }

        if verifyConnection {
            try await verifyLoopbackSSH(username: trimmedUser)
        }
    }

    private func removeLocked() async throws {
        try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh")
        try validateStateDirectoryAndFile()

        var state = (try loadManagedState()) ?? ManagedState()
        var errors: [ConfigError] = []

        // 1. 优先撤销 authorized_keys 中可核验的 Mimi 托管行（不受 config 标记损坏阻断）。
        if lstatInfo(for: authorizedKeysURL) != nil {
            do {
                try validateRegularFileIfPresent(authorizedKeysURL, label: "authorized_keys")
                if let recordedEntry = state.authorizedKeyEntry,
                   let recordedBody = state.publicKeyBody {
                    try removeRecordedAuthorizedEntryIfPresent(
                        entry: recordedEntry,
                        expectedKeyBody: recordedBody,
                        addedLeadingNewline: state.authorizedKeyAddedLeadingNewline
                    )
                    state.authorizedKeyEntry = nil
                    state.authorizedKeyAddedLeadingNewline = false
                }
            } catch let error as ConfigError {
                errors.append(error)
            } catch {
                errors.append(.fileOperationFailed(error.localizedDescription))
            }
        } else {
            state.authorizedKeyEntry = nil
            state.authorizedKeyAddedLeadingNewline = false
        }

        // 2. 仅删除经指纹与公私钥匹配核验确属 Mimi 的专用密钥文件。
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

        // 3. 最后移除 ~/.ssh/config 中的托管块（逐字节保留托管块之外的格式）。
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

        // 4. 按实际清理结果更新或移除状态文件。
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
            try writeFileAtomically(
                Data(pubContent.utf8),
                to: publicKeyURL,
                mode: 0o644,
                expectedSnapshot: FileSnapshot.missing,
                label: "\(Self.keyFileName).pub"
            )
            rollback.createdPublicKey = true
            rollback.generatedKeyBody = body
            return KeyMaterial(publicKeyBody: body, fingerprint: fingerprint)

        case .regenerateAfterRemovingOwnedPublicKey:
            let backupPub = try readRegularFileDataIfPresent(publicKeyURL)
            try removeRegularFileIfPresent(publicKeyURL)
            rollback.removedOwnedPublicKeyData = backupPub
            return try await generateNewKeyPair(rollback: &rollback)

        case .generateFresh:
            return try await generateNewKeyPair(rollback: &rollback)
        }
    }

    private func generateNewKeyPair(rollback: inout RollbackRecord) async throws -> KeyMaterial {
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

        try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName)
        try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub")
        if let privInfo = lstatInfo(for: privateKeyURL) {
            try tightenExistingFileIfNeeded(privateKeyURL, currentMode: privInfo.mode, maxMode: 0o600)
        }
        if let pubInfo = lstatInfo(for: publicKeyURL) {
            try tightenExistingFileIfNeeded(publicKeyURL, currentMode: pubInfo.mode, maxMode: 0o644)
        }

        guard let pubBody = readPublicKeyBody(),
              let fingerprint = Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: pubBody) else {
            throw ConfigError.keyGenerationFailed("未读取到有效公钥内容。")
        }
        guard let derivedBody = await derivePublicKeyBodyFromPrivateKey(),
              derivedBody == pubBody else {
            throw ConfigError.keyGenerationFailed("生成的私钥与公钥不匹配。")
        }

        rollback.createdPrivateKey = true
        rollback.createdPublicKey = true
        rollback.generatedKeyBody = pubBody
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
        var privateVerified = !hasPrivate
        var publicVerified = !hasPublic

        if hasPrivate {
            try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName)
            if let derived = await derivePublicKeyBodyFromPrivateKey(),
               derived == expectedBody,
               Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: derived) == expectedFingerprint {
                privateVerified = true
            } else {
                mismatchDetails.append(Self.keyFileName)
            }
        }
        if hasPublic {
            try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub")
            if let pubBody = readPublicKeyBody(),
               pubBody == expectedBody,
               Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: pubBody) == expectedFingerprint {
                publicVerified = true
            } else {
                mismatchDetails.append("\(Self.keyFileName).pub")
            }
        }

        if hasPrivate && privateVerified {
            try removeRegularFileIfPresent(privateKeyURL)
        }
        if hasPublic && publicVerified {
            try removeRegularFileIfPresent(publicKeyURL)
        }

        if !mismatchDetails.isEmpty {
            throw ConfigError.conflictingKeyFiles("密钥文件 \(mismatchDetails.joined(separator: "、")) 与 Mimi 记录的指纹不匹配，已保留未删除。")
        }
        return true
    }

    private func derivePublicKeyBodyFromPrivateKey() async -> String? {
        guard (try? validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName)) != nil,
              lstatInfo(for: privateKeyURL) != nil else {
            return nil
        }
        guard let result = try? await runCommand(
            URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            ["-y", "-P", "", "-f", privateKeyURL.path],
            .seconds(10)
        ), result.status == 0 else {
            return nil
        }
        let line = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.extractPublicKeyBody(from: line)
    }

    // MARK: - Rollback

    private struct RollbackRecord {
        var previousState: ManagedState?
        var createdSSHDirectory: Bool = false
        var createdPrivateKey: Bool = false
        var createdPublicKey: Bool = false
        var generatedKeyBody: String?
        var removedOwnedPublicKeyData: Data?
        var wroteSSHConfig: Bool = false
        var originalConfigData: Data = Data()
        var originalConfigExisted: Bool = false
        var originalConfigMode: mode_t?
        var addedAuthorizedKeyEntry: String?
        var addedAuthorizedKeyLeadingNewline: Bool = false
        var createdAuthorizedKeysFile: Bool = false
    }

    private func performRollback(_ rollback: RollbackRecord) async {
        // 1. 回滚本次追加的 authorized_keys 行（仅删本次写入的行）
        if let entry = rollback.addedAuthorizedKeyEntry,
           let keyBody = rollback.generatedKeyBody ?? rollback.previousState?.publicKeyBody {
            if let snapshot = try? captureSnapshot(of: authorizedKeysURL),
               snapshot.exists,
               let text = String(data: snapshot.data, encoding: .utf8) {
                let reverted = Self.removeExactAuthorizedKeyEntry(
                    entry,
                    expectedKeyBody: keyBody,
                    addedLeadingNewline: rollback.addedAuthorizedKeyLeadingNewline,
                    from: text
                )
                if reverted.removed {
                    if rollback.createdAuthorizedKeysFile && reverted.text.isEmpty {
                        try? removeRegularFileIfPresent(authorizedKeysURL)
                    } else {
                        let mode = Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
                        try? writeFileAtomically(
                            Data(reverted.text.utf8),
                            to: authorizedKeysURL,
                            mode: mode,
                            expectedSnapshot: nil,
                            label: "~/.ssh/authorized_keys",
                            invokeHook: false
                        )
                    }
                }
            }
        }

        // 2. 回滚本次写入的 ~/.ssh/config（仅剥离本次写入的托管块或恢复空状态）
        if rollback.wroteSSHConfig {
            if !rollback.originalConfigExisted {
                if let data = try? readRegularFileDataIfPresent(sshConfigURL),
                   let text = String(data: data, encoding: .utf8),
                   let stripped = try? Self.stripManagedBlock(from: text),
                   stripped.remaining.isEmpty {
                    try? removeRegularFileIfPresent(sshConfigURL)
                }
            } else if let snapshot = try? captureSnapshot(of: sshConfigURL),
                      snapshot.exists,
                      let text = String(data: snapshot.data, encoding: .utf8),
                      let stripped = try? Self.stripManagedBlock(from: text),
                      stripped.hadManagedBlock {
                let restoreData = stripped.remaining == String(decoding: rollback.originalConfigData, as: UTF8.self)
                    ? rollback.originalConfigData
                    : Data(stripped.remaining.utf8)
                let mode = rollback.originalConfigMode ?? 0o600
                try? writeFileAtomically(
                    restoreData,
                    to: sshConfigURL,
                    mode: mode,
                    expectedSnapshot: nil,
                    label: "~/.ssh/config",
                    invokeHook: false
                )
            }
        }

        // 3. 回滚本次新建的密钥文件
        if rollback.createdPrivateKey, let expectedBody = rollback.generatedKeyBody {
            if await derivePublicKeyBodyFromPrivateKey() == expectedBody {
                try? removeRegularFileIfPresent(privateKeyURL)
            }
        }
        if rollback.createdPublicKey, let expectedBody = rollback.generatedKeyBody {
            if readPublicKeyBody() == expectedBody {
                try? removeRegularFileIfPresent(publicKeyURL)
            }
        }
        if let oldPubData = rollback.removedOwnedPublicKeyData, lstatInfo(for: publicKeyURL) == nil {
            try? writeFileAtomically(
                oldPubData,
                to: publicKeyURL,
                mode: 0o644,
                expectedSnapshot: nil,
                label: "\(Self.keyFileName).pub",
                invokeHook: false
            )
        }

        // 4. 恢复之前的 state 文件
        if let previousState = rollback.previousState {
            try? saveManagedState(previousState)
        } else {
            try? removeRegularFileIfPresent(stateFileURL)
        }
    }

    // MARK: - OpenSSH Effective Config & Isolated Verification

    private func validateCandidateSSHConfig(_ candidateText: String, expectedUser: String) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(".mimi-ssh-candidate-\(UUID().uuidString).conf")
        try writeExclusiveTempFile(Data(candidateText.utf8), to: tempURL, mode: 0o600)
        defer { _ = Darwin.unlink(tempURL.path) }

        let effective = try await resolveEffectiveSSHConfig(configPath: tempURL.path, alias: Self.hostAlias)
        if let conflict = Self.validateEffectiveLoopbackConfig(
            effective,
            expectedUser: expectedUser,
            expectedIdentityFile: expectedIdentityFileConfigValue
        ) {
            throw ConfigError.effectiveConfigConflict(conflict)
        }
    }

    func resolveEffectiveSSHConfig(configPath: String, alias: String) async throws -> EffectiveSSHConfig {
        let result: CommandResult
        do {
            result = try await runCommand(
                URL(fileURLWithPath: "/usr/bin/ssh"),
                ["-G", "-F", configPath, alias],
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

    private func verifyLoopbackSSH(username: String) async throws {
        let knownHostsPath = sshDirectory.appendingPathComponent("known_hosts").path
        let result: CommandResult
        do {
            result = try await runCommand(
                URL(fileURLWithPath: "/usr/bin/ssh"),
                [
                    "-F", "/dev/null",
                    "-i", privateKeyURL.path,
                    "-o", "IdentitiesOnly=yes",
                    "-o", "IdentityAgent=none",
                    "-o", "BatchMode=yes",
                    "-o", "PasswordAuthentication=no",
                    "-o", "KbdInteractiveAuthentication=no",
                    "-o", "ControlMaster=no",
                    "-o", "ControlPath=none",
                    "-o", "ControlPersist=no",
                    "-o", "ProxyJump=none",
                    "-o", "ProxyCommand=none",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "UserKnownHostsFile=\(knownHostsPath)",
                    "-o", "ConnectTimeout=5",
                    "-p", "22",
                    "-l", username,
                    "127.0.0.1",
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

    // MARK: - Safe POSIX File Operations & Locking

    private struct LStatInfo: Equatable {
        let mode: mode_t
        let uid: uid_t
        let dev: dev_t
        let ino: ino_t
        let size: off_t
        let mtimeSec: Int
        let mtimeNsec: Int

        var fileType: mode_t { mode & S_IFMT }
        var permissions: mode_t { mode & 0o7777 }
        var isRegularFile: Bool { fileType == S_IFREG }
        var isDirectory: Bool { fileType == S_IFDIR }
        var isSymlink: Bool { fileType == S_IFLNK }
    }

    private struct FileSnapshot: Equatable {
        let exists: Bool
        let info: LStatInfo?
        let data: Data

        var mode: mode_t? { info?.permissions }

        static let missing = FileSnapshot(exists: false, info: nil, data: Data())
    }

    private func lstatInfo(for url: URL) -> LStatInfo? {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else { return nil }
        return LStatInfo(
            mode: st.st_mode,
            uid: st.st_uid,
            dev: st.st_dev,
            ino: st.st_ino,
            size: st.st_size,
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec
        )
    }

    private func validateDirectoryIfPresent(_ url: URL, label: String) throws {
        guard let info = lstatInfo(for: url) else { return }
        if info.isSymlink {
            throw ConfigError.unsafeFileSystemTarget("\(label) 是符号链接。")
        }
        guard info.isDirectory else {
            throw ConfigError.unsafeFileSystemTarget("\(label) 不是普通目录。")
        }
        guard info.uid == Darwin.geteuid() else {
            throw ConfigError.unsafeFileSystemTarget("\(label) 不属于当前用户。")
        }
    }

    private func validateRegularFileIfPresent(_ url: URL, label: String) throws {
        guard let info = lstatInfo(for: url) else { return }
        if info.isSymlink {
            throw ConfigError.unsafeFileSystemTarget("\(label) 是符号链接。")
        }
        guard info.isRegularFile else {
            throw ConfigError.unsafeFileSystemTarget("\(label) 不是普通文件。")
        }
        guard info.uid == Darwin.geteuid() else {
            throw ConfigError.unsafeFileSystemTarget("\(label) 不属于当前用户。")
        }
    }

    private func validateStateDirectoryAndFile() throws {
        let stateDir = stateFileURL.deletingLastPathComponent()
        try validateDirectoryIfPresent(stateDir, label: stateDir.lastPathComponent)
        try validateRegularFileIfPresent(stateFileURL, label: stateFileURL.lastPathComponent)
    }

    private func ensureSSHDirectory() throws -> Bool {
        if let info = lstatInfo(for: sshDirectory) {
            try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh")
            try tightenExistingDirectoryIfNeeded(sshDirectory, currentMode: info.permissions)
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: sshDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            // 确保不受宽 umask 影响，且仅对刚新建的目录设置 0700。
            let fd = Darwin.open(sshDirectory.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
            if fd >= 0 {
                defer { Darwin.close(fd) }
                _ = Darwin.fchmod(fd, 0o700)
            }
            return true
        } catch {
            throw ConfigError.fileOperationFailed(error.localizedDescription)
        }
    }

    private func ensureStateDirectory() throws {
        let dir = stateFileURL.deletingLastPathComponent()
        if let info = lstatInfo(for: dir) {
            try validateDirectoryIfPresent(dir, label: dir.lastPathComponent)
            try tightenExistingDirectoryIfNeeded(dir, currentMode: info.permissions)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let fd = Darwin.open(dir.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
            if fd >= 0 {
                defer { Darwin.close(fd) }
                _ = Darwin.fchmod(fd, 0o700)
            }
        } catch {
            throw ConfigError.fileOperationFailed(error.localizedDescription)
        }
    }

    /// 绝不放宽目录权限：仅当存在 group/other 权限位时收紧（与 0700 做按位与）。
    private func tightenExistingDirectoryIfNeeded(_ url: URL, currentMode: mode_t) throws {
        let tightened = currentMode & 0o700
        guard tightened != (currentMode & 0o777) else { return }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard fd >= 0 else {
            throw ConfigError.fileOperationFailed("无法打开目录 \(url.lastPathComponent)：\(Self.posixErrorMessage())")
        }
        defer { Darwin.close(fd) }
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == Darwin.geteuid() else {
            throw ConfigError.unsafeFileSystemTarget(url.lastPathComponent)
        }
        guard Darwin.fchmod(fd, tightened) == 0 else {
            throw ConfigError.fileOperationFailed("收紧目录权限失败：\(Self.posixErrorMessage())")
        }
    }

    /// 绝不放宽已有文件权限：若文件已存在，取 `existing & maxMode`；新建文件取 `maxMode`。
    static func tightenedFileMode(existing: mode_t?, maxMode: mode_t) -> mode_t {
        guard let existing else { return maxMode }
        return (existing & 0o777) & maxMode
    }

    private func tightenExistingFileIfNeeded(_ url: URL, currentMode: mode_t?, maxMode: mode_t) throws {
        guard let currentMode else { return }
        let masked = currentMode & 0o777
        let target = masked & maxMode
        guard target != masked else { return }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw ConfigError.fileOperationFailed("无法打开文件 \(url.lastPathComponent)：\(Self.posixErrorMessage())")
        }
        defer { Darwin.close(fd) }
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == Darwin.geteuid() else {
            throw ConfigError.unsafeFileSystemTarget(url.lastPathComponent)
        }
        guard Darwin.fchmod(fd, target) == 0 else {
            throw ConfigError.fileOperationFailed("收紧文件权限失败：\(Self.posixErrorMessage())")
        }
    }

    private func captureSnapshot(of url: URL) throws -> FileSnapshot {
        guard lstatInfo(for: url) != nil else {
            return .missing
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT { return .missing }
            if err == ELOOP {
                throw ConfigError.unsafeFileSystemTarget("\(url.lastPathComponent) 是符号链接。")
            }
            throw ConfigError.fileOperationFailed("无法读取 \(url.lastPathComponent)：\(Self.posixErrorMessage(err))")
        }
        defer { Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            throw ConfigError.fileOperationFailed("无法检查 \(url.lastPathComponent)：\(Self.posixErrorMessage())")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw ConfigError.unsafeFileSystemTarget("\(url.lastPathComponent) 不是普通文件。")
        }
        guard st.st_uid == Darwin.geteuid() else {
            throw ConfigError.unsafeFileSystemTarget("\(url.lastPathComponent) 不属于当前用户。")
        }

        let data = try readAllBytes(from: fd, label: url.lastPathComponent)
        let info = LStatInfo(
            mode: st.st_mode,
            uid: st.st_uid,
            dev: st.st_dev,
            ino: st.st_ino,
            size: st.st_size,
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec
        )
        return FileSnapshot(exists: true, info: info, data: data)
    }

    func readRegularFileDataIfPresent(_ url: URL) throws -> Data? {
        let snapshot = try captureSnapshot(of: url)
        return snapshot.exists ? snapshot.data : nil
    }

    private func verifySnapshotUnchanged(_ expected: FileSnapshot, current: FileSnapshot, label: String) throws {
        if expected.exists != current.exists {
            throw ConfigError.concurrentModification("\(label) 在操作期间被创建或删除。")
        }
        guard expected.exists else { return }
        if expected.info?.dev != current.info?.dev ||
            expected.info?.ino != current.info?.ino ||
            expected.info?.size != current.info?.size ||
            expected.info?.mtimeSec != current.info?.mtimeSec ||
            expected.info?.mtimeNsec != current.info?.mtimeNsec ||
            expected.data != current.data {
            throw ConfigError.concurrentModification("\(label) 在写入前已被其他进程修改。")
        }
    }

    private func createExclusiveBackup(of originalData: Data) throws {
        let timestamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8)
        let backupURL = sshDirectory.appendingPathComponent("config.before-mimi.\(timestamp)-\(suffix).bak")
        try writeExclusiveTempFile(originalData, to: backupURL, mode: 0o600)
    }

    private func writeExclusiveTempFile(_ data: Data, to url: URL, mode: mode_t) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw ConfigError.fileOperationFailed("无法独占创建文件 \(url.lastPathComponent)：\(Self.posixErrorMessage())")
        }
        var closed = false
        defer {
            if !closed { Darwin.close(fd) }
        }
        do {
            guard Darwin.fchmod(fd, 0o600) == 0 else {
                throw ConfigError.fileOperationFailed("设置临时文件权限失败：\(Self.posixErrorMessage())")
            }
            try writeAllBytes(data, to: fd, label: url.lastPathComponent)
            if mode != 0o600 {
                guard Darwin.fchmod(fd, mode) == 0 else {
                    throw ConfigError.fileOperationFailed("设置目标文件权限失败：\(Self.posixErrorMessage())")
                }
            }
            _ = Darwin.fsync(fd)
            Darwin.close(fd)
            closed = true
        } catch {
            if !closed {
                Darwin.close(fd)
                closed = true
            }
            _ = Darwin.unlink(url.path)
            throw error
        }
    }

    private func writeFileAtomically(
        _ data: Data,
        to targetURL: URL,
        mode: mode_t,
        expectedSnapshot: FileSnapshot?,
        label: String,
        invokeHook: Bool = true
    ) throws {
        let tempURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).mimi-\(UUID().uuidString).tmp")
        try writeExclusiveTempFile(data, to: tempURL, mode: mode)
        var committed = false
        defer {
            if !committed {
                _ = Darwin.unlink(tempURL.path)
            }
        }

        if invokeHook, let beforeAtomicCommit {
            try beforeAtomicCommit(targetURL)
        }

        // 提交前再次检查目标类型及是否被外部修改。
        try validateRegularFileIfPresent(targetURL, label: label)
        if let expectedSnapshot {
            let current = try captureSnapshot(of: targetURL)
            try verifySnapshotUnchanged(expectedSnapshot, current: current, label: label)
        }

        guard Darwin.rename(tempURL.path, targetURL.path) == 0 else {
            throw ConfigError.fileOperationFailed("原子替换 \(label) 失败：\(Self.posixErrorMessage())")
        }
        committed = true
    }

    private func removeRegularFileIfPresent(_ url: URL) throws {
        guard lstatInfo(for: url) != nil else { return }
        try validateRegularFileIfPresent(url, label: url.lastPathComponent)
        guard Darwin.unlink(url.path) == 0 else {
            let err = errno
            if err == ENOENT { return }
            throw ConfigError.fileOperationFailed("删除 \(url.lastPathComponent) 失败：\(Self.posixErrorMessage(err))")
        }
    }

    private func loadManagedState() throws -> ManagedState? {
        guard let data = try readRegularFileDataIfPresent(stateFileURL) else { return nil }
        do {
            return try JSONDecoder().decode(ManagedState.self, from: data)
        } catch {
            throw ConfigError.fileOperationFailed("读取 Mimi SSH 状态文件失败：\(error.localizedDescription)")
        }
    }

    private func saveManagedState(_ state: ManagedState) throws {
        try ensureStateDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw ConfigError.fileOperationFailed("序列化 Mimi SSH 状态失败：\(error.localizedDescription)")
        }
        try writeFileAtomically(
            data,
            to: stateFileURL,
            mode: 0o600,
            expectedSnapshot: nil,
            label: stateFileURL.lastPathComponent,
            invokeHook: false
        )
    }

    private func readPublicKeyBody() -> String? {
        guard let data = try? readRegularFileDataIfPresent(publicKeyURL),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Self.extractPublicKeyBody(from: trimmed)
    }

    private func decodeUTF8(_ data: Data, label: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError.fileOperationFailed("\(label) 不是有效的 UTF-8 文本。")
        }
        return text
    }

    private func readAllBytes(from fd: Int32, label: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else {
                if errno == EINTR { continue }
                throw ConfigError.fileOperationFailed("读取 \(label) 失败：\(Self.posixErrorMessage())")
            }
        }
        return data
    }

    private func writeAllBytes(_ data: Data, to fd: Int32, label: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: written), rawBuffer.count - written)
                if result > 0 {
                    written += result
                } else if result < 0 && errno == EINTR {
                    continue
                } else {
                    throw ConfigError.fileOperationFailed("写入 \(label) 失败：\(Self.posixErrorMessage())")
                }
            }
        }
    }

    private static func posixErrorMessage(_ code: Int32 = errno) -> String {
        String(cString: Darwin.strerror(code))
    }

    // MARK: - Concurrency Serialization (In-process + Cross-process Advisory Lock)

    private func withSerializedLock<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        let key = homeDirectory.standardizedFileURL.path
        return try await CodexLocalSSHOperationLock.shared.withLock(key: key) {
            try ensureStateDirectory()
            let lockFD = try await acquireAdvisoryFileLock(at: lockFileURL)
            defer {
                Darwin.close(lockFD)
            }
            return try await operation()
        }
    }

    private func acquireAdvisoryFileLock(at url: URL) async throws -> Int32 {
        let deadline = ContinuousClock.now + .seconds(20)
        while true {
            let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK, 0o600)
            if fd >= 0 {
                _ = Darwin.fchmod(fd, 0o600)
                return fd
            }
            let err = errno
            if err != EWOULDBLOCK && err != EAGAIN && err != EINTR {
                throw ConfigError.fileOperationFailed("获取并发锁失败：\(Self.posixErrorMessage(err))")
            }
            if ContinuousClock.now >= deadline {
                throw ConfigError.concurrentModification("等待另一项 SSH 配置操作超时。")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

/// 进程内按目录串行化所有 SSH 配置读写与撤销，避免双入口或重入并发写盘。
private actor CodexLocalSSHOperationLock {
    static let shared = CodexLocalSSHOperationLock()

    private var lockedKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withLock<T: Sendable>(key: String, operation: () async throws -> T) async throws -> T {
        await acquire(key: key)
        defer { release(key: key) }
        return try await operation()
    }

    private func acquire(key: String) async {
        if !lockedKeys.contains(key) {
            lockedKeys.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = queue
            }
            next.resume()
        } else {
            lockedKeys.remove(key)
        }
    }
}
