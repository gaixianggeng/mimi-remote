import CryptoKit
import Darwin
import Foundation

/// 为 Codex 桌面版安全、幂等、可撤销地配置本机回环 SSH（#376）。
/// 只操作标准 `~/.ssh`（专用密钥 + `from="127.0.0.1,::1"` 授权 + 独立标记块）与本应用归属状态文件，不触碰 Codex 私有数据库。
///
/// 整体状态机模型：
/// - 生命周期状态：`Absent` / `Ready` / `Degraded(isManaged=true, isReady=false)`。
/// - 文件探测统一使用三态 `PathProbe`（`ENOENT` -> `.missing`；存在 -> `.present`；任何权限/路径异常 -> 显式抛错），绝不把无法检查当作缺失。
/// - `configure` 分四阶段：Preflight（纯只读与多配置画像 `ssh -G` 核验）-> Stage & Commit `~/.ssh`（逐项记录精确前后快照到 `RollbackRecord`）
///   -> Isolated Verify（在独占 `0700` 沙箱内用冻结配置快照与事务内 `known_hosts` 副本执行双向握手，不触碰实时 `known_hosts`）
///   -> Commit Trust & Finalize（经归属与 CAS 核验后写回 `known_hosts` 与最终状态）。任意阶段失败均按 `RollbackRecord` 执行快照受控回滚。
/// - `remove` 独立清理 `authorized_keys` -> 专用密钥 -> `config` 托管块 -> `known_hosts`；仅当资源确证缺失或已清理时才清除对应状态字段，
///   任何失败或外部改写冲突均保留状态与重试入口。
struct CodexLocalSSHConfigurator: Sendable {
    static let hostAlias = "mimi-local"
    static let keyFileName = "mimi_codex_local_ed25519"
    static let keyComment = "mimi-codex-local"
    static let managedBlockStart = "# >>> mimi-remote local codex ssh >>>"
    static let managedBlockEnd = "# <<< mimi-remote local codex ssh <<<"
    static let loopbackAuthorizedKeyOption = #"from="127.0.0.1,::1""#
    static let probeRemoteCommand = "/bin/cat"
    /// Codex 桌面版实际远端代理命令画像（覆盖 shell 包装与直接调用两种 `Match command` 匹配形态）。
    static let desktopProxyRemoteCommands: [[String]] = [
        ["sh", "-c", "exec codex app-server proxy"],
        ["codex", "app-server", "proxy"],
    ]

    typealias CommandRunner = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: Duration, _ standardInput: Data?) async throws -> CommandResult
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
        /// 记录应用专用主机信任文件是否仍待管理/清理，避免其他项已清空后因 `known_hosts` 单独清理失败而丢失重试入口。
        var managedKnownHosts: Bool = false

        init(
            version: Int = 1,
            keyFingerprint: String? = nil,
            publicKeyBody: String? = nil,
            authorizedKeyEntry: String? = nil,
            authorizedKeyBody: String? = nil,
            authorizedKeyAddedLeadingNewline: Bool = false,
            managedHostAlias: String? = nil,
            managedUsername: String? = nil,
            managedKnownHosts: Bool = false
        ) {
            self.version = version
            self.keyFingerprint = keyFingerprint
            self.publicKeyBody = publicKeyBody
            self.authorizedKeyEntry = authorizedKeyEntry
            self.authorizedKeyBody = authorizedKeyBody
            self.authorizedKeyAddedLeadingNewline = authorizedKeyAddedLeadingNewline
            self.managedHostAlias = managedHostAlias
            self.managedUsername = managedUsername
            self.managedKnownHosts = managedKnownHosts
        }

        enum CodingKeys: String, CodingKey {
            case version
            case keyFingerprint
            case publicKeyBody
            case authorizedKeyEntry
            case authorizedKeyBody
            case authorizedKeyAddedLeadingNewline
            case managedHostAlias
            case managedUsername
            case managedKnownHosts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            keyFingerprint = try container.decodeIfPresent(String.self, forKey: .keyFingerprint)
            publicKeyBody = try container.decodeIfPresent(String.self, forKey: .publicKeyBody)
            authorizedKeyEntry = try container.decodeIfPresent(String.self, forKey: .authorizedKeyEntry)
            authorizedKeyBody = try container.decodeIfPresent(String.self, forKey: .authorizedKeyBody)
            authorizedKeyAddedLeadingNewline = try container.decodeIfPresent(Bool.self, forKey: .authorizedKeyAddedLeadingNewline) ?? false
            managedHostAlias = try container.decodeIfPresent(String.self, forKey: .managedHostAlias)
            managedUsername = try container.decodeIfPresent(String.self, forKey: .managedUsername)
            managedKnownHosts = try container.decodeIfPresent(Bool.self, forKey: .managedKnownHosts) ?? false
        }

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
                managedHostAlias == nil &&
                !managedKnownHosts
        }
    }

    struct Inspection: Equatable, Sendable {
        var keyExists: Bool = false
        var authorizedKeyInstalled: Bool = false
        var hasRecordedAuthorizedEntry: Bool = false
        var hasPersistedManagedState: Bool = false
        var sshConfigInstalled: Bool = false
        var effectiveLoopbackVerified: Bool = false
        var hasConflictingHostAlias: Bool = false
        var hasConflictingKeyFiles: Bool = false
        var hasConflictingAuthorizedKey: Bool = false
        var hasUnsafeFileSystemState: Bool = false

        var isManaged: Bool {
            keyExists ||
                authorizedKeyInstalled ||
                hasRecordedAuthorizedEntry ||
                sshConfigInstalled ||
                hasPersistedManagedState
        }

        var hasAnyConflict: Bool {
            hasConflictingHostAlias || hasConflictingKeyFiles || hasConflictingAuthorizedKey || hasUnsafeFileSystemState
        }

        /// 只有经 Mimi 归属核验、回环授权无冲突且多画像 `ssh -G` 确认直连当前用户 127.0.0.1:22 时才为 true。
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
        var knownHostsCommand: String?
        var verifyHostKeyDNS: String?
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
        var stdinNull: String?
        var requestTTY: String?
        var sessionType: String?
        var forkAfterAuthentication: String?
        var updateHostKeys: String?
        var escapeChar: String?
        var enableEscapeCommandline: String?
    }

    let homeDirectory: URL
    let username: String
    let stateFileURL: URL
    let systemSSHConfigPath: String?
    private let runCommand: CommandRunner
    let beforeAtomicCommit: CommitHook?
    let afterVerifyBeforeDelete: CommitHook?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        username: String = NSUserName(),
        stateFileURL: URL? = nil,
        systemSSHConfigPath: String? = "/etc/ssh/ssh_config",
        runCommand: @escaping CommandRunner = CodexLocalSSHConfigurator.defaultCommandRunner,
        beforeAtomicCommit: CommitHook? = nil,
        afterVerifyBeforeDelete: CommitHook? = nil
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
        self.afterVerifyBeforeDelete = afterVerifyBeforeDelete
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

    var isDefaultUserHome: Bool {
        homeDirectory.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    var lockFileURL: URL {
        stateFileURL.deletingLastPathComponent().appendingPathComponent(".codex-local-ssh.lock")
    }

    static func defaultCommandRunner(
        executable: URL,
        arguments: [String],
        timeout: Duration,
        standardInput: Data? = nil
    ) async throws -> CommandResult {
        try await ProcessExecutor.shared.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            forceKillAfterTimeout: true,
            standardInput: standardInput
        )
    }

    // MARK: - Public API

    /// 只读检查当前本机 SSH 托管配置状态。
    /// 使用三态探测区分「确实缺失（ENOENT）」与「无法检查（EACCES/符号链接/非 UTF-8）」；
    /// 任一异常均标为不就绪，并基于持久化记录保留撤销与重试入口。
    func inspect() async -> Inspection {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = Inspection()

        // 0. 独立校验并读取持久化状态，确保即便 known_hosts 或 ~/.ssh 异常/失去搜索权限，仍可保留待撤销记录。
        var state: ManagedState?
        do {
            try validateStateDirectoryAndStateFile()
            state = try loadManagedState()
        } catch {
            result.hasUnsafeFileSystemState = true
        }

        var knownHostsExists = false
        do {
            knownHostsExists = try validateRegularFileIfPresent(knownHostsURL, label: knownHostsURL.lastPathComponent) != nil
        } catch {
            result.hasUnsafeFileSystemState = true
        }

        if let state, !state.isEmpty {
            // 只要持久化状态账本仍有未清空记录，就必须保留撤销/重试入口，避免出现残留文件或权限异常时隐藏入口。
            result.hasPersistedManagedState = true
        }
        _ = knownHostsExists

        var sshDirectorySafe = true
        do {
            _ = try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh")
        } catch {
            result.hasUnsafeFileSystemState = true
            sshDirectorySafe = false
        }

        if !sshDirectorySafe {
            if let state, !state.isEmpty {
                result.hasPersistedManagedState = true
                if state.authorizedKeyEntry != nil {
                    result.hasRecordedAuthorizedEntry = true
                }
            }
            return result
        }

        // 1. 独立三态探测并核验密钥归属与公私钥匹配
        var privateSafe = true
        var publicSafe = true
        var privateExists = false
        var publicExists = false
        do {
            privateExists = try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName) != nil
        } catch {
            result.hasUnsafeFileSystemState = true
            privateSafe = false
        }
        do {
            publicExists = try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub") != nil
        } catch {
            result.hasUnsafeFileSystemState = true
            publicSafe = false
        }

        if privateSafe && publicSafe {
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
                    if singleOwned {
                        result.hasPersistedManagedState = true
                    } else {
                        result.hasConflictingKeyFiles = true
                    }
                }
            } else if privateExists || publicExists {
                result.hasConflictingKeyFiles = true
            }
        } else if state?.keyFingerprint != nil {
            result.hasPersistedManagedState = true
        }

        // 2. 独立三态探测并核验 authorized_keys：无法探测（如 ~/.ssh 0600 报 EACCES）、非普通文件或不可解码时，只要持久化记录有授权项就必须保留撤销入口。
        do {
            let authSnapshot = try captureSnapshot(of: authorizedKeysURL, label: "authorized_keys")
            if authSnapshot.exists {
                let authorizedContent = try decodeUTF8(authSnapshot.data, label: "~/.ssh/authorized_keys")
                if let state, let expectedAuthBody = state.effectiveAuthorizedKeyBody {
                    let evaluation = Self.evaluateAuthorizedKeys(
                        content: authorizedContent,
                        keyBody: expectedAuthBody,
                        recordedEntry: state.authorizedKeyEntry
                    )
                    result.hasConflictingAuthorizedKey = evaluation.hasConflict
                    result.authorizedKeyInstalled = evaluation.hasValidLoopbackEntry && !evaluation.hasConflict
                    if let recorded = state.authorizedKeyEntry {
                        if Self.containsExactLine(recorded, in: authorizedContent) ||
                            Self.containsAuthorizedKeyBody(expectedAuthBody, in: authorizedContent) {
                            result.hasRecordedAuthorizedEntry = true
                        }
                    }
                }
            }
        } catch {
            result.hasUnsafeFileSystemState = true
            if state?.authorizedKeyEntry != nil {
                result.hasRecordedAuthorizedEntry = true
                result.hasPersistedManagedState = true
            }
        }

        // 3. 独立三态探测并核验 ~/.ssh/config 托管块、冲突与多画像 ssh -G 有效目标
        do {
            let configSnapshot = try captureSnapshot(of: sshConfigURL, label: "config")
            if configSnapshot.exists {
                let configContent = try decodeUTF8(configSnapshot.data, label: "~/.ssh/config")
                if let stripped = try? Self.stripManagedBlock(from: configContent) {
                    let hasConflict = containsConflictingHostAlias(Self.hostAlias, in: stripped.remaining)
                    result.hasConflictingHostAlias = hasConflict
                    let managedByState = state?.managedHostAlias == Self.hostAlias
                    result.sshConfigInstalled = stripped.hadManagedBlock && managedByState
                    if result.sshConfigInstalled && !hasConflict && !trimmedUser.isEmpty && !result.hasUnsafeFileSystemState {
                        if let frozen = try? materializeEvaluationSSHConfig(
                            userConfigText: configContent,
                            includeSystemConfig: true
                        ) {
                            defer { frozen.cleanup() }
                            let valid = (try? await validateManagedEffectiveProfiles(
                                frozenConfigPath: frozen.configFileURL.path,
                                expectedUser: trimmedUser,
                                checkRealDesktopPath: isDefaultUserHome && systemSSHConfigPath == "/etc/ssh/ssh_config",
                                probeVerifyArguments: nil,
                                txKnownHostsPath: nil
                            )) != nil
                            result.effectiveLoopbackVerified = valid
                        }
                    }
                } else {
                    result.hasConflictingHostAlias = true
                    if state?.managedHostAlias == Self.hostAlias {
                        result.hasPersistedManagedState = true
                    }
                }
            }
        } catch {
            result.hasUnsafeFileSystemState = true
            if state?.managedHostAlias == Self.hostAlias {
                result.hasPersistedManagedState = true
            }
        }

        return result
    }

    /// 一键配置本机回环 SSH 并验证免密连通（串行化、防外部覆盖、事务内隔离验连、失败回滚）。
    func configure(verifyConnection: Bool = true) async throws {
        try await withSerializedLock {
            try await configureLocked(verifyConnection: verifyConnection)
        }
    }

    /// 撤销由 Mimi 写入的本机 SSH 托管授权、专用密钥、配置块与应用专用主机信任文件。
    /// 仅在资源确证缺失或成功清理后才清除对应状态字段，任何无法检查（如 EACCES）或冲突均保留状态与重试入口。
    func remove() async throws {
        try await withSerializedLock {
            try await removeLocked()
        }
    }

    // MARK: - Serialized State Machine Implementations

    private func configureLocked(verifyConnection: Bool) async throws {
        // =========================================================================
        // Phase 1 · Preflight（纯只读探测、归属核验与多画像 ssh -G 校验，零磁盘写入）
        // =========================================================================
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

        try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh")
        try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName)
        try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub")
        try validateRegularFileIfPresent(authorizedKeysURL, label: "authorized_keys")
        try validateRegularFileIfPresent(sshConfigURL, label: "config")
        try validateStateDirectoryAndFile()

        let previousState = try loadManagedState()
        let configSnapshot = try captureSnapshot(of: sshConfigURL, label: "~/.ssh/config")
        let authSnapshot = try captureSnapshot(of: authorizedKeysURL, label: "~/.ssh/authorized_keys")
        let initialKnownHostsSnapshot = try captureSnapshot(of: knownHostsURL, label: knownHostsURL.lastPathComponent)

        let existingConfigText = try decodeUTF8(configSnapshot.data, label: "~/.ssh/config")
        let strippedConfig = try Self.stripManagedBlock(from: existingConfigText)
        if containsConflictingHostAlias(Self.hostAlias, in: strippedConfig.remaining) {
            throw ConfigError.conflictingHostAlias(Self.hostAlias)
        }

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

        let keyPlan = try await planKeyPair(existingState: previousState)

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

        // =========================================================================
        // Phase 2 · Stage & Commit ~/.ssh（每步在 RollbackRecord 登记精确写入快照）
        // =========================================================================
        let createdSSHDirectory = try ensureSSHDirectory()
        try ensureStateDirectory()

        var rollback = RollbackRecord(
            previousState: previousState,
            createdSSHDirectory: createdSSHDirectory
        )

        do {
            let keyMaterial = try await materializeKeyPair(plan: keyPlan, rollback: &rollback)

            let latestAuthSnapshot = try captureSnapshot(of: authorizedKeysURL, label: "~/.ssh/authorized_keys")
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

            // 写入 ~/.ssh/config 并登记精确写入快照
            let configTargetMode = Self.tightenedFileMode(existing: configSnapshot.mode, maxMode: 0o600)
            if candidateConfigText != existingConfigText {
                var backupURL: URL?
                if configSnapshot.exists && !existingConfigText.isEmpty {
                    backupURL = try createExclusiveBackup(of: configSnapshot.data)
                }
                let configData = Data(candidateConfigText.utf8)
                let writtenConfigSnapshot = try writeFileAtomically(
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
                rollback.writtenManagedBlockRaw = managedBlock
                rollback.writtenUsername = trimmedUser
                rollback.writtenConfigData = configData
                rollback.writtenConfigSnapshot = writtenConfigSnapshot
                rollback.createdBackupURL = backupURL
            } else if configSnapshot.exists {
                try tightenExistingFileIfNeeded(sshConfigURL, currentMode: configSnapshot.mode, maxMode: 0o600)
            }

            // 构造并单次原子写入 ~/.ssh/authorized_keys
            var nextState = previousState ?? ManagedState()
            nextState.keyFingerprint = keyMaterial.fingerprint
            nextState.publicKeyBody = keyMaterial.publicKeyBody
            nextState.managedHostAlias = Self.hostAlias
            nextState.managedUsername = trimmedUser
            nextState.managedKnownHosts = initialKnownHostsSnapshot.exists || (previousState?.managedKnownHosts ?? false)

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
                let writtenAuthSnapshot = try writeFileAtomically(
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
                rollback.writtenAuthSnapshot = writtenAuthSnapshot
                rollback.addedAuthorizedKeyEntry = addedEntry
                rollback.addedAuthorizedKeyBody = addedEntry != nil ? keyMaterial.publicKeyBody : nil
                rollback.addedAuthorizedKeyLeadingNewline = addedLeadingNewline
                rollback.removedPreviousAuthorizedEntry = removedPreviousAuthEntry
            } else if latestAuthSnapshot.exists {
                try tightenExistingFileIfNeeded(authorizedKeysURL, currentMode: latestAuthSnapshot.mode, maxMode: 0o600)
            }

            // 持久化崩溃安全账本（即便进程在验连中途意外终止，下次启动仍有撤销入口）。
            try saveManagedState(nextState, invokeHook: false)

            // =========================================================================
            // Phase 3 · Isolated Verification（冻结快照 + 事务内 known_hosts 副本，零实时信任文件改动）
            // =========================================================================
            let finalConfigSnapshot = try captureSnapshot(of: sshConfigURL, label: "~/.ssh/config")
            guard finalConfigSnapshot.exists else {
                throw ConfigError.effectiveConfigConflict("写入后未能读取 ~/.ssh/config。")
            }
            let finalConfigText = try decodeUTF8(finalConfigSnapshot.data, label: "~/.ssh/config")
            let verifiedSnapshotConfig = try materializeEvaluationSSHConfig(
                userConfigText: finalConfigText,
                includeSystemConfig: true
            )
            defer { verifiedSnapshotConfig.cleanup() }

            let txKnownHostsURL = verifiedSnapshotConfig.tempDirectory.appendingPathComponent("tx-known-hosts")
            try writeExclusiveTempFile(initialKnownHostsSnapshot.data, to: txKnownHostsURL, mode: 0o600)

            let verifyArguments = buildVerifyLoopbackSSHArguments(
                username: trimmedUser,
                verifiedConfigPath: verifiedSnapshotConfig.configFileURL.path,
                txKnownHostsPath: txKnownHostsURL.path
            )

            try await validateManagedEffectiveProfiles(
                frozenConfigPath: verifiedSnapshotConfig.configFileURL.path,
                expectedUser: trimmedUser,
                checkRealDesktopPath: isDefaultUserHome && systemSSHConfigPath == "/etc/ssh/ssh_config",
                probeVerifyArguments: verifyConnection ? verifyArguments : nil,
                txKnownHostsPath: verifyConnection ? txKnownHostsURL.path : nil
            )

            if verifyConnection {
                try await verifyLoopbackSSH(arguments: verifyArguments)
            }

            // =========================================================================
            // Phase 4 · Commit Host Trust & Finalize State（CAS 核验归属后写回 known_hosts）
            // =========================================================================
            let desiredKnownHostsData: Data
            if verifyConnection {
                let txSnapshot = try captureSnapshot(of: txKnownHostsURL, label: "tx-known-hosts")
                desiredKnownHostsData = txSnapshot.data
            } else {
                desiredKnownHostsData = initialKnownHostsSnapshot.data
            }

            try commitKnownHostsTransactionalResult(
                desiredData: desiredKnownHostsData,
                initialSnapshot: initialKnownHostsSnapshot,
                rollback: &rollback
            )

            nextState.managedKnownHosts = true
            try saveManagedState(nextState, invokeHook: true)
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

    private func commitKnownHostsTransactionalResult(
        desiredData: Data,
        initialSnapshot: FileSnapshot,
        rollback: inout RollbackRecord
    ) throws {
        try ensureStateDirectory()
        try validateRegularFileIfPresent(knownHostsURL, label: knownHostsURL.lastPathComponent)

        if !initialSnapshot.exists {
            let writtenSnapshot = try publishExclusiveNewFile(
                desiredData,
                to: knownHostsURL,
                mode: 0o600,
                label: knownHostsURL.lastPathComponent,
                invokeHook: true
            )
            rollback.knownHostsMutation = .created(writtenSnapshot: writtenSnapshot)
            return
        }

        if desiredData != initialSnapshot.data {
            let targetMode = Self.tightenedFileMode(existing: initialSnapshot.mode, maxMode: 0o600)
            let writtenSnapshot = try writeFileAtomically(
                desiredData,
                to: knownHostsURL,
                mode: targetMode,
                expectedSnapshot: initialSnapshot,
                label: knownHostsURL.lastPathComponent,
                invokeHook: true
            )
            rollback.knownHostsMutation = .updated(originalSnapshot: initialSnapshot, writtenSnapshot: writtenSnapshot)
            return
        }

        let currentKH = try captureSnapshot(of: knownHostsURL, label: knownHostsURL.lastPathComponent)
        try verifySnapshotUnchanged(initialSnapshot, current: currentKH, label: knownHostsURL.lastPathComponent)
        try tightenExistingFileIfNeeded(knownHostsURL, currentMode: currentKH.mode, maxMode: 0o600)
    }

    private func removeLocked() async throws {
        // 先独立校验并读取状态文件，不被专用 known_hosts 异常阻断授权撤销。
        try validateStateDirectoryAndStateFile()

        var state = (try loadManagedState()) ?? ManagedState()
        var errors: [ConfigError] = []

        var sshDirectorySafe = true
        do {
            _ = try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh")
        } catch let error as ConfigError {
            errors.append(error)
            sshDirectorySafe = false
        } catch {
            errors.append(.fileOperationFailed(error.localizedDescription))
            sshDirectorySafe = false
        }

        if sshDirectorySafe {
            // 1. 优先撤销 authorized_keys：严格使用三态探测，仅在确证 ENOENT 缺失或确证无该公钥残留授权后才清空记录。
            do {
                switch try probePath(authorizedKeysURL, label: "authorized_keys") {
                case .missing:
                    state.authorizedKeyEntry = nil
                    state.authorizedKeyBody = nil
                    state.authorizedKeyAddedLeadingNewline = false
                case .present:
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
                        state.authorizedKeyEntry = nil
                        state.authorizedKeyBody = nil
                        state.authorizedKeyAddedLeadingNewline = false
                    }
                }
            } catch let error as ConfigError {
                errors.append(error)
            } catch {
                errors.append(.fileOperationFailed(error.localizedDescription))
            }

            // 2. 仅删除经指纹、公私钥匹配与隔离快照核验确属 Mimi 的专用密钥文件。
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

            // 3. 移除 ~/.ssh/config 中的托管块（三态探测：仅在 ENOENT 或写回成功后清除记录）。
            do {
                switch try probePath(sshConfigURL, label: "config") {
                case .missing:
                    state.managedHostAlias = nil
                    state.managedUsername = nil
                case .present:
                    try validateRegularFileIfPresent(sshConfigURL, label: "config")
                    let snapshot = try captureSnapshot(of: sshConfigURL, label: "~/.ssh/config")
                    let content = try decodeUTF8(snapshot.data, label: "~/.ssh/config")
                    let stripped = try Self.stripManagedBlock(from: content)
                    if stripped.hadManagedBlock {
                        let targetMode = Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
                        _ = try writeFileAtomically(
                            Data(stripped.remaining.utf8),
                            to: sshConfigURL,
                            mode: targetMode,
                            expectedSnapshot: snapshot,
                            label: "~/.ssh/config"
                        )
                    }
                    state.managedHostAlias = nil
                    state.managedUsername = nil
                }
            } catch let error as ConfigError {
                errors.append(error)
            } catch {
                errors.append(.fileOperationFailed(error.localizedDescription))
            }
        }

        // 4. 独立安全清理应用专用主机信任文件：清理失败时保留 managedKnownHosts 状态与重试入口。
        do {
            switch try probePath(knownHostsURL, label: knownHostsURL.lastPathComponent) {
            case .missing:
                state.managedKnownHosts = false
            case .present:
                try removeRegularFileIfPresent(knownHostsURL, label: knownHostsURL.lastPathComponent)
                state.managedKnownHosts = false
            }
        } catch let error as ConfigError {
            state.managedKnownHosts = true
            errors.append(error)
        } catch {
            state.managedKnownHosts = true
            errors.append(.fileOperationFailed(error.localizedDescription))
        }

        // 5. 按实际清理结果更新或移除状态文件，不静默忽略持久化错误。
        do {
            if state.isEmpty {
                try removeRegularFileIfPresent(stateFileURL, label: stateFileURL.lastPathComponent)
            } else {
                try saveManagedState(state, invokeHook: false)
            }
        } catch let error as ConfigError {
            errors.append(error)
        } catch {
            errors.append(.fileOperationFailed(error.localizedDescription))
        }

        if let firstError = errors.first {
            throw firstError
        }
    }

    // MARK: - Key Ownership & Generation

    private enum KeyPlanAction {
        case reuseExisting(body: String, fingerprint: String)
        case reconstructPublicKey(body: String, fingerprint: String)
        case regenerateAfterRemovingOwnedPublicKey(verifiedPublicKeySnapshot: FileSnapshot)
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
        let hasPrivate = try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName) != nil
        let hasPublic = try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub") != nil

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

        // !hasPrivate && hasPublic：直接捕获并在执行阶段贯穿使用该已核验快照，绝不二次按路径重抓快照删除。
        let pubSnapshot = try captureSnapshot(of: publicKeyURL, label: "\(Self.keyFileName).pub")
        guard pubSnapshot.exists,
              let rawPub = String(data: pubSnapshot.data, encoding: .utf8),
              let existingPubBody = Self.extractPublicKeyBody(from: rawPub.trimmingCharacters(in: .whitespacesAndNewlines)),
              existingPubBody == expectedBody,
              Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: existingPubBody) == expectedFingerprint else {
            throw ConfigError.conflictingKeyFiles("仅存在公钥 \(Self.keyFileName).pub，且与 Mimi 记录的密钥指纹不一致。")
        }
        return KeyPlan(
            action: .regenerateAfterRemovingOwnedPublicKey(verifiedPublicKeySnapshot: pubSnapshot),
            shouldRemovePreviousAuthorizedEntry: true
        )
    }

    private func materializeKeyPair(plan: KeyPlan, rollback: inout RollbackRecord) async throws -> KeyMaterial {
        switch plan.action {
        case .reuseExisting(let body, let fingerprint):
            if let privInfo = try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName) {
                try tightenExistingFileIfNeeded(privateKeyURL, currentMode: privInfo.permissions, maxMode: 0o600)
            }
            if let pubInfo = try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub") {
                try tightenExistingFileIfNeeded(publicKeyURL, currentMode: pubInfo.permissions, maxMode: 0o644)
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
            rollback.generatedKeyFingerprint = fingerprint
            return KeyMaterial(publicKeyBody: body, fingerprint: fingerprint)

        case .regenerateAfterRemovingOwnedPublicKey(let verifiedPublicKeySnapshot):
            try removeFileMatchingSnapshot(
                publicKeyURL,
                expectedSnapshot: verifiedPublicKeySnapshot,
                label: "\(Self.keyFileName).pub",
                invokeHook: true
            )
            rollback.removedOwnedPublicKeyData = verifiedPublicKeySnapshot.data
            rollback.removedOwnedPublicKeyMode = verifiedPublicKeySnapshot.mode
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
                .seconds(15),
                nil
            )
        } catch {
            throw ConfigError.keyGenerationFailed(error.localizedDescription)
        }
        guard result.status == 0 else {
            throw ConfigError.keyGenerationFailed(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let privInfo = try validateRegularFileIfPresent(stagingPrivateURL, label: Self.keyFileName) {
            try tightenExistingFileIfNeeded(stagingPrivateURL, currentMode: privInfo.permissions, maxMode: 0o600)
        }
        if let pubInfo = try validateRegularFileIfPresent(stagingPublicURL, label: "\(Self.keyFileName).pub") {
            try tightenExistingFileIfNeeded(stagingPublicURL, currentMode: pubInfo.permissions, maxMode: 0o644)
        }

        let stagedPrivateSnapshot = try captureSnapshot(of: stagingPrivateURL, label: Self.keyFileName)
        let stagedPublicSnapshot = try captureSnapshot(of: stagingPublicURL, label: "\(Self.keyFileName).pub")
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
        rollback.generatedKeyFingerprint = fingerprint

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
        let privateProbe = try probePath(privateKeyURL, label: Self.keyFileName)
        let publicProbe = try probePath(publicKeyURL, label: "\(Self.keyFileName).pub")
        let hasPrivate: Bool
        switch privateProbe {
        case .missing: hasPrivate = false
        case .present: hasPrivate = true
        }
        let hasPublic: Bool
        switch publicProbe {
        case .missing: hasPublic = false
        case .present: hasPublic = true
        }
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
            let snapshot = try captureSnapshot(of: privateKeyURL, label: Self.keyFileName)
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
            let snapshot = try captureSnapshot(of: publicKeyURL, label: "\(Self.keyFileName).pub")
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
        guard let snapshot = try? captureSnapshot(of: privateKeyURL, label: Self.keyFileName), snapshot.exists else {
            return nil
        }
        return await derivePublicKeyBody(fromPrivateKeySnapshot: snapshot)
    }

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
            .seconds(10),
            nil
        ), result.status == 0 else {
            return nil
        }
        let line = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.extractPublicKeyBody(from: line)
    }

    // MARK: - Transactional Rollback

    enum KnownHostsMutation {
        case unchanged
        case created(writtenSnapshot: FileSnapshot)
        case updated(originalSnapshot: FileSnapshot, writtenSnapshot: FileSnapshot)
    }

    struct RollbackRecord {
        var previousState: ManagedState?
        var createdSSHDirectory: Bool = false
        var createdPrivateKey: Bool = false
        var createdPrivateKeySnapshot: FileSnapshot?
        var createdPublicKey: Bool = false
        var createdPublicKeySnapshot: FileSnapshot?
        var generatedKeyBody: String?
        var generatedKeyFingerprint: String?
        var removedOwnedPublicKeyData: Data?
        var removedOwnedPublicKeyMode: mode_t?
        var wroteSSHConfig: Bool = false
        var originalConfigData: Data = Data()
        var originalConfigExisted: Bool = false
        var originalConfigMode: mode_t?
        var originalHadManagedBlock: Bool = false
        var originalManagedBlockRaw: String?
        var writtenManagedBlockRaw: String?
        var writtenUsername: String?
        var writtenConfigData: Data?
        var writtenConfigSnapshot: FileSnapshot?
        var createdBackupURL: URL?
        var wroteAuthorizedKeys: Bool = false
        var originalAuthExisted: Bool = false
        var originalAuthData: Data = Data()
        var originalAuthMode: mode_t?
        var writtenAuthData: Data?
        var writtenAuthSnapshot: FileSnapshot?
        var addedAuthorizedKeyEntry: String?
        var addedAuthorizedKeyBody: String?
        var addedAuthorizedKeyLeadingNewline: Bool = false
        var removedPreviousAuthorizedEntry: String?
        var knownHostsMutation: KnownHostsMutation = .unchanged
    }

    private struct RollbackOutcome {
        var fullyRolledBack: Bool = true
        var detail: String?
    }

    private func performRollback(_ rollback: RollbackRecord) async -> RollbackOutcome {
        var failures: [String] = []
        var fallbackState = rollback.previousState ?? ManagedState()
        var residualAuthorizedEntry: String?
        var residualConfigManaged = false
        var residualNewKeyManaged = false
        var residualKnownHostsManaged = false

        // 1. 回滚本次对 authorized_keys 的写入：
        // - 明确区分文件不存在与读取失败；
        // - 新建文件未改动时按写入快照隔离删除；
        // - 外部编辑导致精确删除失败时，必须按公钥标识确认是否仍存在有效授权，若仍存在则保留记录并报告冲突！
        if rollback.wroteAuthorizedKeys {
            var authReverted = false
            do {
                let snapshot = try captureSnapshot(of: authorizedKeysURL, label: "~/.ssh/authorized_keys")
                if !snapshot.exists {
                    if !rollback.originalAuthExisted {
                        authReverted = true
                    } else {
                        _ = try publishExclusiveNewFile(
                            rollback.originalAuthData,
                            to: authorizedKeysURL,
                            mode: rollback.originalAuthMode ?? 0o600,
                            label: "~/.ssh/authorized_keys",
                            invokeHook: false
                        )
                        authReverted = true
                    }
                } else if let writtenSnap = rollback.writtenAuthSnapshot, Self.snapshotsMatch(writtenSnap, snapshot) {
                    if !rollback.originalAuthExisted {
                        try removeFileMatchingSnapshot(
                            authorizedKeysURL,
                            expectedSnapshot: writtenSnap,
                            label: "~/.ssh/authorized_keys",
                            invokeHook: false
                        )
                    } else {
                        let mode = rollback.originalAuthMode ?? 0o600
                        _ = try writeFileAtomically(
                            rollback.originalAuthData,
                            to: authorizedKeysURL,
                            mode: mode,
                            expectedSnapshot: writtenSnap,
                            label: "~/.ssh/authorized_keys",
                            invokeHook: false
                        )
                    }
                    authReverted = true
                } else {
                    let text = try decodeUTF8(snapshot.data, label: "~/.ssh/authorized_keys")
                    var working = text
                    var changed = false
                    var residualAddedKeyRemains = false

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
                        if Self.containsAuthorizedKeyBody(keyBody, in: working) {
                            residualAddedKeyRemains = true
                        }
                    }

                    if let oldEntry = rollback.removedPreviousAuthorizedEntry,
                       !Self.containsExactLine(oldEntry, in: working) {
                        working = Self.appendAuthorizedKeyEntry(oldEntry, to: working).text
                        changed = true
                    }

                    if changed {
                        let mode = Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
                        _ = try writeFileAtomically(
                            Data(working.utf8),
                            to: authorizedKeysURL,
                            mode: mode,
                            expectedSnapshot: snapshot,
                            label: "~/.ssh/authorized_keys",
                            invokeHook: false
                        )
                    }

                    if residualAddedKeyRemains {
                        authReverted = false
                        failures.append("~/.ssh/authorized_keys 中本次新增公钥的授权行已被外部修改，未能自动撤销，已保留外部改动与撤销记录")
                    } else {
                        authReverted = true
                    }
                }
            } catch {
                authReverted = false
                failures.append("未能自动回滚 ~/.ssh/authorized_keys（\(error.localizedDescription)）")
            }

            if !authReverted {
                residualAuthorizedEntry = rollback.addedAuthorizedKeyEntry
            }
        }

        // 2. 回滚本次对 ~/.ssh/config 的写入
        if rollback.wroteSSHConfig {
            var configReverted = false
            do {
                let snapshot = try captureSnapshot(of: sshConfigURL, label: "~/.ssh/config")
                if !snapshot.exists {
                    if !rollback.originalConfigExisted {
                        configReverted = true
                    } else {
                        _ = try publishExclusiveNewFile(
                            rollback.originalConfigData,
                            to: sshConfigURL,
                            mode: rollback.originalConfigMode ?? 0o600,
                            label: "~/.ssh/config",
                            invokeHook: false
                        )
                        configReverted = true
                    }
                } else if let writtenSnap = rollback.writtenConfigSnapshot, Self.snapshotsMatch(writtenSnap, snapshot) {
                    if !rollback.originalConfigExisted {
                        try removeFileMatchingSnapshot(
                            sshConfigURL,
                            expectedSnapshot: writtenSnap,
                            label: "~/.ssh/config",
                            invokeHook: false
                        )
                    } else {
                        let mode = rollback.originalConfigMode ?? 0o600
                        _ = try writeFileAtomically(
                            rollback.originalConfigData,
                            to: sshConfigURL,
                            mode: mode,
                            expectedSnapshot: writtenSnap,
                            label: "~/.ssh/config",
                            invokeHook: false
                        )
                    }
                    configReverted = true
                } else {
                    let text = try decodeUTF8(snapshot.data, label: "~/.ssh/config")
                    let currentStripped = try Self.stripManagedBlock(from: text)
                    guard currentStripped.hadManagedBlock,
                          Self.managedBlocksMatch(currentStripped.originalManagedBlock, expected: rollback.writtenManagedBlockRaw) else {
                        throw ConfigError.concurrentModification("~/.ssh/config 中的托管块在回滚前已被外部修改，已保留外部改动未覆盖。")
                    }
                    if rollback.originalHadManagedBlock, let oldBlock = rollback.originalManagedBlockRaw {
                        guard let restoredText = try Self.replaceManagedBlock(in: text, with: oldBlock) else {
                            throw ConfigError.invalidManagedBlock
                        }
                        let mode = rollback.originalConfigMode ?? Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
                        _ = try writeFileAtomically(
                            Data(restoredText.utf8),
                            to: sshConfigURL,
                            mode: mode,
                            expectedSnapshot: snapshot,
                            label: "~/.ssh/config",
                            invokeHook: false
                        )
                    } else if !rollback.originalConfigExisted && currentStripped.remaining.isEmpty {
                        try removeFileMatchingSnapshot(
                            sshConfigURL,
                            expectedSnapshot: snapshot,
                            label: "~/.ssh/config",
                            invokeHook: false
                        )
                    } else {
                        let mode = rollback.originalConfigMode ?? Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
                        _ = try writeFileAtomically(
                            Data(currentStripped.remaining.utf8),
                            to: sshConfigURL,
                            mode: mode,
                            expectedSnapshot: snapshot,
                            label: "~/.ssh/config",
                            invokeHook: false
                        )
                    }
                    configReverted = true
                }
            } catch {
                configReverted = false
                failures.append("未能自动回滚 ~/.ssh/config（\(error.localizedDescription)）")
            }

            if !configReverted {
                residualConfigManaged = true
            } else if let backupURL = rollback.createdBackupURL {
                try? removeRegularFileIfPresent(backupURL, label: backupURL.lastPathComponent)
            }
        }

        // 3. 仅当应用专用 known_hosts 确实由本次事务写入、且当前版本仍与本次写入快照完全一致时才回滚；绝不删除同名替换文件或覆盖外部更新。
        switch rollback.knownHostsMutation {
        case .unchanged:
            break
        case .created(let writtenSnapshot):
            do {
                try removeFileMatchingSnapshot(
                    knownHostsURL,
                    expectedSnapshot: writtenSnapshot,
                    label: knownHostsURL.lastPathComponent,
                    invokeHook: false
                )
            } catch {
                residualKnownHostsManaged = true
                failures.append("未能回滚新建的 \(knownHostsURL.lastPathComponent)（\(error.localizedDescription)）")
            }
        case .updated(let originalSnapshot, let writtenSnapshot):
            do {
                let currentKH = try captureSnapshot(of: knownHostsURL, label: knownHostsURL.lastPathComponent)
                guard Self.snapshotsMatch(writtenSnapshot, currentKH) else {
                    throw ConfigError.concurrentModification("\(knownHostsURL.lastPathComponent) 在回滚前已被外部修改或替换，已保留外部更新未覆盖。")
                }
                _ = try writeFileAtomically(
                    originalSnapshot.data,
                    to: knownHostsURL,
                    mode: originalSnapshot.mode ?? 0o600,
                    expectedSnapshot: writtenSnapshot,
                    label: knownHostsURL.lastPathComponent,
                    invokeHook: false
                )
            } catch {
                residualKnownHostsManaged = true
                failures.append("未能恢复 \(knownHostsURL.lastPathComponent)（\(error.localizedDescription)）")
            }
        }

        // 4. 按发布快照隔离回滚本次新建的密钥文件并逐项记录失败（绝不删外部替换的同名文件）。
        if rollback.createdPrivateKey, let snapshot = rollback.createdPrivateKeySnapshot {
            do {
                try removeFileMatchingSnapshot(privateKeyURL, expectedSnapshot: snapshot, label: Self.keyFileName, invokeHook: false)
            } catch ConfigError.conflictingKeyFiles {
                failures.append("私钥 \(Self.keyFileName) 在回滚前已被外部替换，已保留未删除")
            } catch {
                residualNewKeyManaged = true
                failures.append("未能回滚新建私钥 \(Self.keyFileName)（\(error.localizedDescription)）")
            }
        }
        if rollback.createdPublicKey, let snapshot = rollback.createdPublicKeySnapshot {
            do {
                try removeFileMatchingSnapshot(publicKeyURL, expectedSnapshot: snapshot, label: "\(Self.keyFileName).pub", invokeHook: false)
            } catch ConfigError.conflictingKeyFiles {
                failures.append("公钥 \(Self.keyFileName).pub 在回滚前已被外部替换，已保留未删除")
            } catch {
                residualNewKeyManaged = true
                failures.append("未能回滚新建公钥 \(Self.keyFileName).pub（\(error.localizedDescription)）")
            }
        }
        if let oldPubData = rollback.removedOwnedPublicKeyData {
            do {
                _ = try publishExclusiveNewFile(
                    oldPubData,
                    to: publicKeyURL,
                    mode: rollback.removedOwnedPublicKeyMode ?? 0o644,
                    label: "\(Self.keyFileName).pub",
                    invokeHook: false
                )
            } catch {
                failures.append("未能恢复原有公钥 \(Self.keyFileName).pub（\(error.localizedDescription)）")
            }
        }

        // 5. 恢复或保留可撤销的 state 文件，并显式记录持久化错误。
        if let residualAuthorizedEntry {
            fallbackState.authorizedKeyEntry = residualAuthorizedEntry
            fallbackState.authorizedKeyBody = rollback.addedAuthorizedKeyBody ?? rollback.generatedKeyBody
            fallbackState.authorizedKeyAddedLeadingNewline = rollback.addedAuthorizedKeyLeadingNewline
        }
        if residualConfigManaged && fallbackState.managedHostAlias == nil {
            fallbackState.managedHostAlias = Self.hostAlias
            fallbackState.managedUsername = rollback.writtenUsername
        }
        if residualNewKeyManaged {
            if let fp = rollback.generatedKeyFingerprint { fallbackState.keyFingerprint = fp }
            if let body = rollback.generatedKeyBody { fallbackState.publicKeyBody = body }
        }
        if residualKnownHostsManaged {
            fallbackState.managedKnownHosts = true
        }

        do {
            if !failures.isEmpty && !fallbackState.isEmpty {
                try saveManagedState(fallbackState, invokeHook: false)
            } else if let previousState = rollback.previousState {
                try saveManagedState(previousState, invokeHook: false)
            } else {
                try removeRegularFileIfPresent(stateFileURL, label: stateFileURL.lastPathComponent)
            }
        } catch {
            failures.append("未能恢复 Mimi SSH 状态文件（\(error.localizedDescription)）")
        }

        if failures.isEmpty {
            return RollbackOutcome(fullyRolledBack: true, detail: nil)
        }
        return RollbackOutcome(
            fullyRolledBack: false,
            detail: "部分已写入项未能自动回滚，请点击「移除本机 SSH 配置」清理：\(failures.joined(separator: "；"))"
        )
    }

    // MARK: - OpenSSH Multi-Profile Effective Config & Isolated Verification

    private func validateCandidateSSHConfig(_ candidateText: String, expectedUser: String) async throws {
        let materialized = try materializeEvaluationSSHConfig(
            userConfigText: candidateText,
            includeSystemConfig: true
        )
        defer { materialized.cleanup() }

        try await validateManagedEffectiveProfiles(
            frozenConfigPath: materialized.configFileURL.path,
            expectedUser: expectedUser,
            checkRealDesktopPath: false,
            probeVerifyArguments: nil,
            txKnownHostsPath: nil
        )
    }

    /// 跨「无命令基准」「/bin/cat 探测命令」「实际验连参数」「Codex 桌面代理命令」与「真实桌面默认路径」逐一执行 `ssh -G` 校验，
    /// 彻底阻断 `Match command` 让桌面版加载与探测不同的 `IdentityFile`/`StdinNull`/信任配置。
    func validateManagedEffectiveProfiles(
        frozenConfigPath: String,
        expectedUser: String,
        checkRealDesktopPath: Bool,
        probeVerifyArguments: [String]?,
        txKnownHostsPath: String?
    ) async throws {
        // 1. 冻结快照：无命令基准
        let baseEffective = try await resolveEffectiveSSHConfig(
            configPath: frozenConfigPath,
            alias: Self.hostAlias,
            includeSystemConfig: false
        )
        if let conflict = Self.validateEffectiveLoopbackConfig(
            baseEffective,
            expectedUser: expectedUser,
            expectedIdentityFile: expectedIdentityFileConfigValue,
            expectedKnownHostsFile: expectedKnownHostsPath
        ) {
            throw ConfigError.effectiveConfigConflict(conflict)
        }

        // 2. 冻结快照：非固定参数下的 /bin/cat 探测命令
        let catEffective = try await resolveEffectiveSSHConfig(
            configPath: frozenConfigPath,
            alias: Self.hostAlias,
            includeSystemConfig: false,
            extraOptions: ["-T"],
            remoteCommand: [Self.probeRemoteCommand]
        )
        if let conflict = Self.validateEffectiveLoopbackConfig(
            catEffective,
            expectedUser: expectedUser,
            expectedIdentityFile: expectedIdentityFileConfigValue,
            expectedKnownHostsFile: expectedKnownHostsPath
        ) {
            throw ConfigError.effectiveConfigConflict("探测命令（/bin/cat）有效配置异常：\(conflict)")
        }

        // 3. 冻结快照：Codex 桌面版代理命令画像（捕获 Match command "*codex*" 等规则）
        for proxyCmd in Self.desktopProxyRemoteCommands {
            let proxyEffective = try await resolveEffectiveSSHConfig(
                configPath: frozenConfigPath,
                alias: Self.hostAlias,
                includeSystemConfig: false,
                extraOptions: ["-T"],
                remoteCommand: proxyCmd
            )
            if let conflict = Self.validateEffectiveLoopbackConfig(
                proxyEffective,
                expectedUser: expectedUser,
                expectedIdentityFile: expectedIdentityFileConfigValue,
                expectedKnownHostsFile: expectedKnownHostsPath
            ) {
                throw ConfigError.effectiveConfigConflict("Codex 桌面代理命令有效配置异常：\(conflict)")
            }
        }

        // 4. 实际验连命令行参数（含事务内 known_hosts 副本与固定选项）
        if let probeVerifyArguments, let txKnownHostsPath {
            let probeEffective = try await resolveEffectiveSSHConfig(rawArguments: probeVerifyArguments)
            if let conflict = Self.validateEffectiveLoopbackConfig(
                probeEffective,
                expectedUser: expectedUser,
                expectedIdentityFile: privateKeyURL.path,
                expectedKnownHostsFile: txKnownHostsPath,
                additionalAllowedIdentityFiles: [expectedIdentityFileConfigValue]
            ) {
                throw ConfigError.effectiveConfigConflict("实际验连参数有效配置异常：\(conflict)")
            }
        }

        // 5. 默认主目录下对照不带 -F 的真实桌面解析路径（基准 + 桌面代理命令）
        if checkRealDesktopPath {
            let desktopBase = try await resolveEffectiveSSHConfig(
                configPath: sshConfigURL.path,
                alias: Self.hostAlias,
                includeSystemConfig: true
            )
            if let conflict = Self.validateEffectiveLoopbackConfig(
                desktopBase,
                expectedUser: expectedUser,
                expectedIdentityFile: expectedIdentityFileConfigValue,
                expectedKnownHostsFile: expectedKnownHostsPath
            ) {
                throw ConfigError.effectiveConfigConflict(conflict)
            }
            for proxyCmd in Self.desktopProxyRemoteCommands {
                let desktopProxy = try await resolveEffectiveSSHConfig(
                    configPath: sshConfigURL.path,
                    alias: Self.hostAlias,
                    includeSystemConfig: true,
                    extraOptions: ["-T"],
                    remoteCommand: proxyCmd
                )
                if let conflict = Self.validateEffectiveLoopbackConfig(
                    desktopProxy,
                    expectedUser: expectedUser,
                    expectedIdentityFile: expectedIdentityFileConfigValue,
                    expectedKnownHostsFile: expectedKnownHostsPath
                ) {
                    throw ConfigError.effectiveConfigConflict("真实桌面解析路径代理命令配置异常：\(conflict)")
                }
            }
        }
    }

    func resolveEffectiveSSHConfig(
        configPath: String,
        alias: String,
        includeSystemConfig: Bool = true,
        extraOptions: [String] = [],
        remoteCommand: [String] = []
    ) async throws -> EffectiveSSHConfig {
        var materialized: MaterializedSSHConfig?
        defer { materialized?.cleanup() }

        var rawArgs: [String] = []
        if includeSystemConfig,
           isDefaultUserHome,
           configPath == sshConfigURL.path,
           systemSSHConfigPath == "/etc/ssh/ssh_config" {
            // 默认用户主目录直接走不带 -F 的真实桌面版解析路径（同时加载 ~/.ssh/config 与 /etc/ssh/ssh_config）。
            rawArgs.append(contentsOf: extraOptions)
            rawArgs.append(alias)
            rawArgs.append(contentsOf: remoteCommand)
        } else if includeSystemConfig {
            let rawText: String
            if let rawData = try readRegularFileDataIfPresent(URL(fileURLWithPath: configPath), label: "~/.ssh/config") {
                rawText = try decodeUTF8(rawData, label: "~/.ssh/config")
            } else {
                rawText = ""
            }
            let snapshot = try materializeEvaluationSSHConfig(
                userConfigText: rawText,
                includeSystemConfig: true
            )
            materialized = snapshot
            rawArgs.append(contentsOf: ["-F", snapshot.configFileURL.path])
            rawArgs.append(contentsOf: extraOptions)
            rawArgs.append(alias)
            rawArgs.append(contentsOf: remoteCommand)
        } else {
            rawArgs.append(contentsOf: ["-F", configPath])
            rawArgs.append(contentsOf: extraOptions)
            rawArgs.append(alias)
            rawArgs.append(contentsOf: remoteCommand)
        }

        return try await resolveEffectiveSSHConfig(rawArguments: rawArgs)
    }

    func resolveEffectiveSSHConfig(rawArguments: [String]) async throws -> EffectiveSSHConfig {
        let arguments = ["-G"] + rawArguments
        let result: CommandResult
        do {
            result = try await runCommand(
                URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments,
                .seconds(10),
                nil
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

    /// 构造绑定到冻结配置快照与事务内专用 `known_hosts` 副本的验连参数，显式禁用 `KnownHostsCommand`、`VerifyHostKeyDNS` 与一切转发/重定向。
    func buildVerifyLoopbackSSHArguments(
        username: String,
        verifiedConfigPath: String,
        txKnownHostsPath: String
    ) -> [String] {
        [
            "-F", verifiedConfigPath,
            "-T",
            "-o", "BatchMode=yes",
            "-o", "HostName=127.0.0.1",
            "-o", "AddressFamily=inet",
            "-o", "Port=22",
            "-o", "User=\(username)",
            "-o", "IdentityFile=\"\(privateKeyURL.path)\"",
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "PubkeyAuthentication=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "UserKnownHostsFile=\"\(txKnownHostsPath)\"",
            "-o", "GlobalKnownHostsFile=none",
            "-o", "KnownHostsCommand=none",
            "-o", "VerifyHostKeyDNS=no",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UpdateHostKeys=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ProxyJump=none",
            "-o", "ProxyCommand=none",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ControlPersist=no",
            "-o", "CanonicalizeHostname=no",
            "-o", "PermitLocalCommand=no",
            "-o", "RemoteCommand=none",
            "-o", "RequestTTY=no",
            "-o", "SessionType=default",
            "-o", "ForkAfterAuthentication=no",
            "-o", "ConnectTimeout=5",
            Self.hostAlias,
            Self.probeRemoteCommand,
        ]
    }

    private func verifyLoopbackSSH(arguments: [String]) async throws {
        let probePayload = Data("mimi-ssh-probe-\(UUID().uuidString)\n".utf8)
        let result: CommandResult
        do {
            result = try await runCommand(
                URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments,
                .seconds(12),
                probePayload
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
        guard result.stdout == probePayload else {
            throw ConfigError.verificationFailed("本机 SSH 双向输入输出握手未通过，Codex 桌面版代理可能无法正常通信（请检查 StdinNull 或 shell 启动输出）。")
        }
    }

    // MARK: - Authorized Keys Helpers

    private func removeRecordedAuthorizedEntryIfPresent(
        entry: String,
        expectedKeyBody: String,
        addedLeadingNewline: Bool
    ) throws {
        let snapshot = try captureSnapshot(of: authorizedKeysURL, label: "~/.ssh/authorized_keys")
        guard snapshot.exists else { return }
        let content = try decodeUTF8(snapshot.data, label: "~/.ssh/authorized_keys")
        let result = Self.removeExactAuthorizedKeyEntry(
            entry,
            expectedKeyBody: expectedKeyBody,
            addedLeadingNewline: addedLeadingNewline,
            from: content
        )
        if result.removed {
            let targetMode = Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
            _ = try writeFileAtomically(
                Data(result.text.utf8),
                to: authorizedKeysURL,
                mode: targetMode,
                expectedSnapshot: snapshot,
                label: "~/.ssh/authorized_keys"
            )
            return
        }
        // 精确行未匹配时，按公钥标识检查该密钥是否仍有效授权（例如用户仅改了托管行注释），绝不静默丢弃撤销记录。
        if Self.containsAuthorizedKeyBody(expectedKeyBody, in: content) {
            throw ConfigError.conflictingAuthorizedKey(
                "~/.ssh/authorized_keys 中仍存在 Mimi 专用公钥的有效授权，但对应行已被外部修改，已保留记录未自动删除，请手工核对。"
            )
        }
    }
}
