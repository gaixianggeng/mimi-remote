import Darwin
import Foundation

/// 为 Codex 桌面版安全、幂等、可撤销地配置本机回环 SSH（#376）。
/// 本实现聚焦「首次配置」与「撤销」两个核心操作，采用隔离目录方案：
/// - 所有 Mimi 自有配置、专用密钥与独立 `known_hosts` 均存放在 `~/.ssh/mimi/`（目录 `0700`、文件 `0600`）；
/// - `~/.ssh/config` 仅在最顶部加入一行带标记的 `Include "~/.ssh/mimi/config"`；
/// - `~/.ssh/authorized_keys` 仅追加一行带 Mimi 标记且带 `restrict,from="127.0.0.1,::1"` 限制的公钥；
/// - 已有配置时再次点击配置只做只读校验，不轮换密钥、不覆写现有文件；
/// - 遇到权限（组/全局可写）或属主不安全的 `~/.ssh`、`config`、`authorized_keys` 直接拒绝并提示用户手工修复，绝不自动修改权限，也不在回滚中保留其条目；
/// - 所有 `ssh -G` 评估与验连均基于同一份冻结快照执行，不读实时文件。
struct CodexLocalSSHConfigurator: Sendable {
    static let hostAlias = "mimi-local"
    static let mimiDirectoryName = "mimi"
    static let mimiConfigFileName = "config"
    static let knownHostsFileName = "known_hosts"
    static let keyFileName = "mimi_codex_local_ed25519"
    static let keyComment = "mimi-codex-local"
    static let keyStagingDirectoryPrefix = ".mimi-keygen-"
    static let keyQuarantineDirectoryPrefix = ".mimi-quarantine-"
    static let managedIncludeMarker = "# mimi-remote-local-ssh"
    static let managedIncludePath = "~/.ssh/mimi/config"
    static let managedIncludeLine = "Include \"\(managedIncludePath)\" \(managedIncludeMarker)"
    static let loopbackAuthorizedKeyOption = #"restrict,from="127.0.0.1,::1""#
    static let probeRemoteCommand = "/bin/cat"
    /// Codex 桌面版实际远端代理命令画像（覆盖 shell 包装与直接调用两种 `Match command` 匹配形态）。
    static let desktopProxyRemoteCommands: [[String]] = [
        ["sh", "-c", "exec codex app-server proxy"],
        ["codex", "app-server", "proxy"],
    ]

    typealias CommandRunner = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: Duration, _ standardInput: Data?) async throws -> CommandResult
    typealias CommitHook = @Sendable (_ targetURL: URL) throws -> Void

    enum HardCrashSimulationPoint: Sendable {
        case afterAuthorizedKeysCommit
        case afterKnownHostsCommit
        case afterStageQuarantineMove
        case afterFileQuarantineMove
    }

    struct SimulatedHardCrashError: LocalizedError, Equatable {
        let point: HardCrashSimulationPoint
        var errorDescription: String? { "模拟进程在 \(point) 后意外中断。" }
    }

    struct FileVersionFingerprint: Codable, Equatable, Sendable {
        var sha256Hex: String
        var size: Int64

        static func from(data: Data) -> FileVersionFingerprint {
            FileVersionFingerprint(
                sha256Hex: CodexLocalSSHConfigurator.computeSHA256Hex(of: data),
                size: Int64(data.count)
            )
        }

        func matches(data: Data) -> Bool {
            size == Int64(data.count) && sha256Hex == CodexLocalSSHConfigurator.computeSHA256Hex(of: data)
        }
    }

    /// 文件/目录的 `(dev, ino)` 唯一标识，用于保证 staging 清理仅删除本次独占创建并已记录 inode 的对象。
    struct FileIdentity: Codable, Equatable, Sendable {
        var dev: Int64
        var ino: UInt64

        init(dev: dev_t, ino: ino_t) {
            self.dev = Int64(dev)
            self.ino = UInt64(ino)
        }

        func matches(_ st: stat) -> Bool {
            Int64(st.st_dev) == dev && UInt64(st.st_ino) == ino
        }
    }

    /// 本次首次配置独占创建的密钥暂存目录及文件 inode 记录，调用 ssh-keygen 前先登记目录 inode，生成后补全文件 inode；
    /// 清理移入隔离目录前同时持久化隔离目录名与 `(dev, ino)`，确保中断恢复时可复核真实 inode 而不漏清或误删。
    struct StagedKeyArtifact: Codable, Equatable, Sendable {
        var directoryName: String
        var directoryIdentity: FileIdentity
        var privateKeyIdentity: FileIdentity?
        var publicKeyIdentity: FileIdentity?
        var quarantineDirectoryName: String? = nil
        var quarantineDirectoryIdentity: FileIdentity? = nil
    }

    /// 已移入独占隔离目录等待删除的单个托管文件记录：在 `renameatx_np` 之前持久化，确保崩溃或 `unlink` 失败后可复核 inode 与指纹并回收。
    struct QuarantinedFileArtifact: Codable, Equatable, Sendable {
        var parentScope: String
        var originalFileName: String
        var quarantineDirectoryName: String
        var quarantineDirectoryIdentity: FileIdentity
        var fileIdentity: FileIdentity
        var fileVersion: FileVersionFingerprint
    }

    /// 首次配置写入前落盘的预写事务意图（WAL）：保证首次配置在任意写盘点被强杀后，重启仍能识别归属并安全撤销。
    struct PendingTransaction: Codable, Equatable, Sendable {
        var transactionID: String
        var keyFingerprint: String
        var publicKeyBody: String
        var plannedAuthorizedKeyEntry: String
        var plannedAuthorizedKeyBody: String
        var authorizedKeyAddedLeadingNewline: Bool = false
        var plannedHostAlias: String
        var plannedUsername: String
        var plannedMimiConfigVersion: FileVersionFingerprint?
        var plannedKnownHostsVersion: FileVersionFingerprint?
        var stagedKeyArtifact: StagedKeyArtifact? = nil
    }

    struct ManagedState: Codable, Equatable, Sendable {
        var version: Int = 2
        var keyFingerprint: String?
        var publicKeyBody: String?
        var authorizedKeyEntry: String?
        /// 独立保存托管授权行对应的公钥主体，确保即使密钥已被删除、授权写回失败后重试仍能核验并撤销残留授权。
        var authorizedKeyBody: String?
        var authorizedKeyAddedLeadingNewline: Bool = false
        /// 回滚或撤销未能清除的同公钥残留主体，确保不丢弃有效授权记录。
        var residualAuthorizedKeyBodies: [String] = []
        var managedHostAlias: String?
        var managedUsername: String?
        var mimiConfigVersion: FileVersionFingerprint?
        var mimiConfigConflict: Bool = false
        /// 记录独立主机信任文件是否仍待管理/清理，并配对已证实归属的版本指纹与冲突标记。
        var managedKnownHosts: Bool = false
        var knownHostsVersion: FileVersionFingerprint?
        var knownHostsConflict: Bool = false
        /// 本次独占创建并已记录 inode 的 `~/.ssh/mimi/.mimi-keygen-*` 暂存产物。
        var stagedKeyArtifacts: [StagedKeyArtifact] = []
        /// 隔离删除前已入账的单文件隔离记录，确保崩溃或 `unlink` 失败后重试能回收滞留隔离文件。
        var quarantinedFileArtifacts: [QuarantinedFileArtifact] = []
        var pendingTransaction: PendingTransaction?

        init(
            version: Int = 2,
            keyFingerprint: String? = nil,
            publicKeyBody: String? = nil,
            authorizedKeyEntry: String? = nil,
            authorizedKeyBody: String? = nil,
            authorizedKeyAddedLeadingNewline: Bool = false,
            residualAuthorizedKeyBodies: [String] = [],
            managedHostAlias: String? = nil,
            managedUsername: String? = nil,
            mimiConfigVersion: FileVersionFingerprint? = nil,
            mimiConfigConflict: Bool = false,
            managedKnownHosts: Bool = false,
            knownHostsVersion: FileVersionFingerprint? = nil,
            knownHostsConflict: Bool = false,
            stagedKeyArtifacts: [StagedKeyArtifact] = [],
            quarantinedFileArtifacts: [QuarantinedFileArtifact] = [],
            pendingTransaction: PendingTransaction? = nil
        ) {
            self.version = version
            self.keyFingerprint = keyFingerprint
            self.publicKeyBody = publicKeyBody
            self.authorizedKeyEntry = authorizedKeyEntry
            self.authorizedKeyBody = authorizedKeyBody
            self.authorizedKeyAddedLeadingNewline = authorizedKeyAddedLeadingNewline
            self.residualAuthorizedKeyBodies = residualAuthorizedKeyBodies
            self.managedHostAlias = managedHostAlias
            self.managedUsername = managedUsername
            self.mimiConfigVersion = mimiConfigVersion
            self.mimiConfigConflict = mimiConfigConflict
            self.managedKnownHosts = managedKnownHosts
            self.knownHostsVersion = knownHostsVersion
            self.knownHostsConflict = knownHostsConflict
            self.stagedKeyArtifacts = stagedKeyArtifacts
            self.quarantinedFileArtifacts = quarantinedFileArtifacts
            self.pendingTransaction = pendingTransaction
        }

        enum CodingKeys: String, CodingKey {
            case version
            case keyFingerprint
            case publicKeyBody
            case authorizedKeyEntry
            case authorizedKeyBody
            case authorizedKeyAddedLeadingNewline
            case residualAuthorizedKeyBodies
            case managedHostAlias
            case managedUsername
            case mimiConfigVersion
            case mimiConfigConflict
            case managedKnownHosts
            case knownHostsVersion
            case knownHostsConflict
            case stagedKeyArtifacts
            case quarantinedFileArtifacts
            case pendingTransaction
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
            keyFingerprint = try container.decodeIfPresent(String.self, forKey: .keyFingerprint)
            publicKeyBody = try container.decodeIfPresent(String.self, forKey: .publicKeyBody)
            authorizedKeyEntry = try container.decodeIfPresent(String.self, forKey: .authorizedKeyEntry)
            authorizedKeyBody = try container.decodeIfPresent(String.self, forKey: .authorizedKeyBody)
            authorizedKeyAddedLeadingNewline = try container.decodeIfPresent(Bool.self, forKey: .authorizedKeyAddedLeadingNewline) ?? false
            residualAuthorizedKeyBodies = try container.decodeIfPresent([String].self, forKey: .residualAuthorizedKeyBodies) ?? []
            managedHostAlias = try container.decodeIfPresent(String.self, forKey: .managedHostAlias)
            managedUsername = try container.decodeIfPresent(String.self, forKey: .managedUsername)
            mimiConfigVersion = try container.decodeIfPresent(FileVersionFingerprint.self, forKey: .mimiConfigVersion)
            mimiConfigConflict = try container.decodeIfPresent(Bool.self, forKey: .mimiConfigConflict) ?? false
            managedKnownHosts = try container.decodeIfPresent(Bool.self, forKey: .managedKnownHosts) ?? false
            knownHostsVersion = try container.decodeIfPresent(FileVersionFingerprint.self, forKey: .knownHostsVersion)
            knownHostsConflict = try container.decodeIfPresent(Bool.self, forKey: .knownHostsConflict) ?? false
            stagedKeyArtifacts = try container.decodeIfPresent([StagedKeyArtifact].self, forKey: .stagedKeyArtifacts) ?? []
            quarantinedFileArtifacts = try container.decodeIfPresent([QuarantinedFileArtifact].self, forKey: .quarantinedFileArtifacts) ?? []
            pendingTransaction = try container.decodeIfPresent(PendingTransaction.self, forKey: .pendingTransaction)
        }

        var effectiveKeyFingerprint: String? {
            if let keyFingerprint, !keyFingerprint.isEmpty { return keyFingerprint }
            if let pending = pendingTransaction, !pending.keyFingerprint.isEmpty { return pending.keyFingerprint }
            return nil
        }

        var effectiveKeyBody: String? {
            if let publicKeyBody, !publicKeyBody.isEmpty { return publicKeyBody }
            if let pending = pendingTransaction, !pending.publicKeyBody.isEmpty { return pending.publicKeyBody }
            return nil
        }

        var effectiveAuthorizedKeyEntry: String? {
            if let authorizedKeyEntry, !authorizedKeyEntry.isEmpty { return authorizedKeyEntry }
            if let pending = pendingTransaction, !pending.plannedAuthorizedKeyEntry.isEmpty { return pending.plannedAuthorizedKeyEntry }
            return nil
        }

        var effectiveAuthorizedKeyBody: String? {
            if let authorizedKeyBody, !authorizedKeyBody.isEmpty { return authorizedKeyBody }
            if let pendingBody = pendingTransaction?.plannedAuthorizedKeyBody, !pendingBody.isEmpty { return pendingBody }
            if let publicKeyBody, !publicKeyBody.isEmpty { return publicKeyBody }
            if let entry = authorizedKeyEntry {
                return CodexLocalSSHConfigurator.parseAuthorizedKeyLine(entry)?.keyBody
            }
            return residualAuthorizedKeyBodies.first
        }

        var effectiveAuthorizedKeyAddedLeadingNewline: Bool {
            if authorizedKeyEntry != nil {
                return authorizedKeyAddedLeadingNewline
            }
            return pendingTransaction?.authorizedKeyAddedLeadingNewline ?? authorizedKeyAddedLeadingNewline
        }

        var allTrackedAuthorizedKeyBodies: [String] {
            var bodies: [String] = []
            func appendUnique(_ value: String?) {
                guard let value, !value.isEmpty, !bodies.contains(value) else { return }
                bodies.append(value)
            }
            appendUnique(authorizedKeyBody)
            appendUnique(publicKeyBody)
            if let entry = authorizedKeyEntry {
                appendUnique(CodexLocalSSHConfigurator.parseAuthorizedKeyLine(entry)?.keyBody)
            }
            for body in residualAuthorizedKeyBodies {
                appendUnique(body)
            }
            if let pending = pendingTransaction {
                appendUnique(pending.plannedAuthorizedKeyBody)
                appendUnique(pending.publicKeyBody)
            }
            return bodies
        }

        var effectiveManagedHostAlias: String? {
            managedHostAlias ?? pendingTransaction?.plannedHostAlias
        }

        var effectiveMimiConfigVersion: FileVersionFingerprint? {
            mimiConfigVersion ?? pendingTransaction?.plannedMimiConfigVersion
        }

        var effectiveKnownHostsVersion: FileVersionFingerprint? {
            knownHostsVersion ?? pendingTransaction?.plannedKnownHostsVersion
        }

        var allTrackedStagedKeyArtifacts: [StagedKeyArtifact] {
            var artifacts = stagedKeyArtifacts
            if let pendingArtifact = pendingTransaction?.stagedKeyArtifact,
               !artifacts.contains(pendingArtifact) {
                artifacts.append(pendingArtifact)
            }
            return artifacts
        }

        var isEmpty: Bool {
            keyFingerprint == nil &&
                publicKeyBody == nil &&
                authorizedKeyEntry == nil &&
                authorizedKeyBody == nil &&
                residualAuthorizedKeyBodies.isEmpty &&
                managedHostAlias == nil &&
                mimiConfigVersion == nil &&
                !mimiConfigConflict &&
                !managedKnownHosts &&
                knownHostsVersion == nil &&
                !knownHostsConflict &&
                stagedKeyArtifacts.isEmpty &&
                quarantinedFileArtifacts.isEmpty &&
                pendingTransaction == nil
        }
    }

    struct Inspection: Equatable, Sendable {
        var keyExists: Bool = false
        var authorizedKeyInstalled: Bool = false
        var hasRecordedAuthorizedEntry: Bool = false
        var hasPersistedManagedState: Bool = false
        var hasPendingTransaction: Bool = false
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
                hasPersistedManagedState ||
                hasPendingTransaction
        }

        var hasAnyConflict: Bool {
            hasConflictingHostAlias || hasConflictingKeyFiles || hasConflictingAuthorizedKey || hasUnsafeFileSystemState
        }

        /// 只有无未完成事务、经 Mimi 归属核验、回环 `restrict,from=` 授权无冲突且冻结快照 `ssh -G` 确认直连当前用户 127.0.0.1:22 时才为 true。
        var isReady: Bool {
            keyExists &&
                authorizedKeyInstalled &&
                sshConfigInstalled &&
                effectiveLoopbackVerified &&
                !hasPendingTransaction &&
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
                "检测到并非由 Mimi 创建或已被修改的自有 SSH 文件，已停止操作以保护你的文件：\(detail)"
            case .conflictingAuthorizedKey(let detail):
                "~/.ssh/authorized_keys 中存在不受本机回环/restrict 限制或已被外部修改的同公钥授权，已停止：\(detail)"
            case .effectiveConfigConflict(let detail):
                "~/.ssh/config 的有效 SSH 解析结果未指向本机 127.0.0.1:22、独立信任文件与专用密钥，已停止：\(detail)"
            case .unsafeFileSystemTarget(let detail):
                "SSH 目录或文件权限、属主或类型不安全，已拒绝修改：\(detail)"
            case .concurrentModification(let detail):
                "写入前或原子替换瞬间检测到 SSH 配置文件被外部修改，已中止并保留外部版本：\(detail)"
            case .invalidManagedBlock:
                "~/.ssh/config 中的 Mimi 托管 Include 标记行不完整或重复，请先手工核对后再试。"
            case .keyGenerationFailed(let detail):
                detail.isEmpty ? "没能生成本机 SSH 密钥。" : "没能生成本机 SSH 密钥：\(detail)"
            case .verificationFailed(let detail):
                detail.isEmpty
                    ? "本机免密验证未通过。请确认第 1 步「远程登录」已开启。"
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

        var hasRestrictOption: Bool {
            options.contains { $0.name == "restrict" && $0.value == nil }
        }

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

        /// 仅允许 `restrict` 与回环 `from="..."` 两个选项，拒绝任何会放宽能力（如 `pty`、`port-forwarding`、`agent-forwarding`、`x11-forwarding`、`user-rc`、`permitopen`、`environment`）的附加选项。
        var hasOnlyManagedRestrictAndLoopbackFromOptions: Bool {
            guard options.count == 2, hasRestrictOption, isStrictlyLoopbackFrom else {
                return false
            }
            return options.allSatisfy { opt in
                (opt.name == "restrict" && opt.value == nil) ||
                    (opt.name == "from" && opt.value != nil)
            }
        }

        var isMimiMarked: Bool {
            comment == CodexLocalSSHConfigurator.keyComment
        }

        func isValidMimiManagedEntry(expectedKeyBody: String) -> Bool {
            keyBody == expectedKeyBody &&
                hasOnlyManagedRestrictAndLoopbackFromOptions &&
                !hasCommandOption &&
                isMimiMarked
        }
    }

    struct EffectiveSSHConfig: Equatable, Sendable {
        var hostname: String?
        var addressFamily: String?
        var port: String?
        var user: String?
        var hostKeyAlias: String?
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
        var noHostAuthenticationForLocalhost: String?
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
    let runCommand: CommandRunner
    let beforeAtomicCommit: CommitHook?
    let afterVerifyBeforeCommit: CommitHook?
    let afterVerifyBeforeDelete: CommitHook?
    let afterStageQuarantineMove: CommitHook?
    let afterFileQuarantineMove: CommitHook?
    let simulateUnlinkFailure: (@Sendable (_ label: String) -> Bool)?
    let injectMetadataPreservationError: (@Sendable (_ label: String) -> String?)?
    let simulateHardCrashPoint: HardCrashSimulationPoint?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        username: String = NSUserName(),
        stateFileURL: URL? = nil,
        systemSSHConfigPath: String? = "/etc/ssh/ssh_config",
        runCommand: @escaping CommandRunner = CodexLocalSSHConfigurator.defaultCommandRunner,
        beforeAtomicCommit: CommitHook? = nil,
        afterVerifyBeforeCommit: CommitHook? = nil,
        afterVerifyBeforeDelete: CommitHook? = nil,
        afterStageQuarantineMove: CommitHook? = nil,
        afterFileQuarantineMove: CommitHook? = nil,
        simulateUnlinkFailure: (@Sendable (_ label: String) -> Bool)? = nil,
        injectMetadataPreservationError: (@Sendable (_ label: String) -> String?)? = nil,
        simulateHardCrashPoint: HardCrashSimulationPoint? = nil
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
        self.afterVerifyBeforeCommit = afterVerifyBeforeCommit
        self.afterVerifyBeforeDelete = afterVerifyBeforeDelete
        self.afterStageQuarantineMove = afterStageQuarantineMove
        self.afterFileQuarantineMove = afterFileQuarantineMove
        self.simulateUnlinkFailure = simulateUnlinkFailure
        self.injectMetadataPreservationError = injectMetadataPreservationError
        self.simulateHardCrashPoint = simulateHardCrashPoint
    }

    var sshDirectory: URL { homeDirectory.appendingPathComponent(".ssh", isDirectory: true) }
    /// 所有 Mimi 自有 SSH 配置、密钥与独立主机信任文件的隔离目录（权限 `0700`）。
    var mimiSSHDirectory: URL { sshDirectory.appendingPathComponent(Self.mimiDirectoryName, isDirectory: true) }
    var mimiConfigURL: URL { mimiSSHDirectory.appendingPathComponent(Self.mimiConfigFileName, isDirectory: false) }
    var privateKeyURL: URL { mimiSSHDirectory.appendingPathComponent(Self.keyFileName, isDirectory: false) }
    var publicKeyURL: URL { mimiSSHDirectory.appendingPathComponent("\(Self.keyFileName).pub", isDirectory: false) }
    var knownHostsURL: URL { mimiSSHDirectory.appendingPathComponent(Self.knownHostsFileName, isDirectory: false) }
    var authorizedKeysURL: URL { sshDirectory.appendingPathComponent("authorized_keys", isDirectory: false) }
    var sshConfigURL: URL { sshDirectory.appendingPathComponent("config", isDirectory: false) }
    var expectedIdentityFileConfigValue: String { privateKeyURL.path }
    var expectedKnownHostsPath: String { knownHostsURL.path }

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
    /// 任一异常、冲突或中断事务均标为不就绪，并基于持久化记录保留撤销入口。
    func inspect() async -> Inspection {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = Inspection()

        // 0. 独立校验并读取持久化状态，确保即便 ~/.ssh 或 ~/.ssh/mimi 权限异常，仍保留待撤销记录。
        var state: ManagedState?
        do {
            try validateStateDirectoryAndStateFile()
            state = try loadManagedState()
        } catch {
            result.hasUnsafeFileSystemState = true
        }

        if let state {
            if !state.isEmpty {
                result.hasPersistedManagedState = true
            }
            if state.pendingTransaction != nil || !state.stagedKeyArtifacts.isEmpty || !state.quarantinedFileArtifacts.isEmpty {
                result.hasPendingTransaction = true
            }
            if state.knownHostsConflict || state.mimiConfigConflict {
                result.hasUnsafeFileSystemState = true
            }
        }

        var sshDirectorySafe = true
        do {
            if let info = try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh") {
                try ensureNotGroupOrWorldWritable(
                    info,
                    label: "~/.ssh",
                    reason: "请先手工修复权限（chmod 700 ~/.ssh）。"
                )
            }
        } catch {
            result.hasUnsafeFileSystemState = true
            sshDirectorySafe = false
        }

        if !sshDirectorySafe {
            if let state, !state.allTrackedAuthorizedKeyBodies.isEmpty {
                result.hasRecordedAuthorizedEntry = true
            }
            return result
        }

        var mimiDirSafe = true
        var mimiDirExists = false
        do {
            if let info = try validateDirectoryIfPresent(mimiSSHDirectory, label: "~/.ssh/mimi") {
                try ensureNotGroupOrWorldWritable(
                    info,
                    label: "~/.ssh/mimi",
                    reason: "请先手工修复权限（chmod 700 ~/.ssh/mimi）。"
                )
                mimiDirExists = true
            }
        } catch {
            result.hasUnsafeFileSystemState = true
            mimiDirSafe = false
        }

        // 1. 检查 ~/.ssh/mimi/known_hosts 安全性与归属
        if mimiDirSafe && mimiDirExists {
            do {
                let khSnap = try captureSnapshot(of: knownHostsURL, label: "~/.ssh/mimi/\(Self.knownHostsFileName)")
                if khSnap.exists {
                    if let expectedKHVersion = state?.effectiveKnownHostsVersion {
                        if !expectedKHVersion.matches(data: khSnap.data) {
                            result.hasUnsafeFileSystemState = true
                        }
                    } else if state?.managedKnownHosts != true {
                        result.hasUnsafeFileSystemState = true
                    }
                }
            } catch {
                result.hasUnsafeFileSystemState = true
            }
        }

        // 2. 独立三态探测并核验 ~/.ssh/mimi/ 内的密钥归属与公私钥匹配（直接调用 ssh-keygen -y，不写临时私钥副本）
        if mimiDirSafe && mimiDirExists {
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
                if let expectedBody = state?.effectiveKeyBody,
                   let expectedFP = state?.effectiveKeyFingerprint {
                    if privateExists && publicExists {
                        if await verifyOwnedKeyPair(expectedBody: expectedBody, expectedFingerprint: expectedFP) {
                            result.keyExists = true
                        } else {
                            result.hasConflictingKeyFiles = true
                        }
                    } else if privateExists || publicExists {
                        if await verifyPartialOwnedKey(
                            privateExists: privateExists,
                            publicExists: publicExists,
                            expectedBody: expectedBody,
                            expectedFingerprint: expectedFP
                        ) {
                            result.hasPersistedManagedState = true
                        } else {
                            result.hasConflictingKeyFiles = true
                        }
                    }
                } else if privateExists || publicExists {
                    result.hasConflictingKeyFiles = true
                }
            } else if state?.effectiveKeyFingerprint != nil {
                result.hasPersistedManagedState = true
            }
        }

        // 3. 独立三态探测并核验 authorized_keys（含权限检查与同公钥残留检查）
        do {
            let authSnapshot = try captureSnapshot(of: authorizedKeysURL, label: "authorized_keys")
            if authSnapshot.exists {
                if let info = authSnapshot.info {
                    try ensureNotGroupOrWorldWritable(
                        info,
                        label: "~/.ssh/authorized_keys",
                        reason: "请先手工核对并修复权限（chmod 600 ~/.ssh/authorized_keys）。"
                    )
                }
                let authorizedContent = try decodeUTF8(authSnapshot.data, label: "~/.ssh/authorized_keys")
                if let state {
                    let trackedBodies = state.allTrackedAuthorizedKeyBodies
                    let residualPresent = Self.findResidualAuthorizedKeyBodies(trackedBodies, in: authorizedContent)
                    if !residualPresent.isEmpty {
                        result.hasRecordedAuthorizedEntry = true
                    }
                    if let expectedAuthBody = state.effectiveAuthorizedKeyBody {
                        let evaluation = Self.evaluateAuthorizedKeys(
                            content: authorizedContent,
                            keyBody: expectedAuthBody,
                            recordedEntry: state.effectiveAuthorizedKeyEntry
                        )
                        let hasOtherResidualKey = !Self.findResidualAuthorizedKeyBodies(state.residualAuthorizedKeyBodies, in: authorizedContent).isEmpty
                        result.hasConflictingAuthorizedKey = evaluation.hasConflict || hasOtherResidualKey
                        result.authorizedKeyInstalled = evaluation.hasExactMimiEntry && !result.hasConflictingAuthorizedKey
                    } else if !residualPresent.isEmpty {
                        result.hasConflictingAuthorizedKey = true
                    }
                }
            }
        } catch {
            result.hasUnsafeFileSystemState = true
            if let state, !state.allTrackedAuthorizedKeyBodies.isEmpty {
                result.hasRecordedAuthorizedEntry = true
                result.hasPersistedManagedState = true
            }
        }

        // 4. 独立三态探测并核验 ~/.ssh/config 单行 Include、~/.ssh/mimi/config 与冻结快照 ssh -G 有效目标
        do {
            let configSnapshot = try captureSnapshot(of: sshConfigURL, label: "config")
            if configSnapshot.exists, let info = configSnapshot.info {
                try ensureNotGroupOrWorldWritable(
                    info,
                    label: "~/.ssh/config",
                    reason: "请先手工核对并修复权限（chmod 600 ~/.ssh/config）。"
                )
            }
            let mimiConfigSnap = mimiDirSafe && mimiDirExists
                ? try captureSnapshot(of: mimiConfigURL, label: "~/.ssh/mimi/config")
                : .missing
            if mimiConfigSnap.exists,
               let expectedMimiVer = state?.effectiveMimiConfigVersion,
               !expectedMimiVer.matches(data: mimiConfigSnap.data) {
                result.hasConflictingKeyFiles = true
            }
            if configSnapshot.exists {
                let configContent = try decodeUTF8(configSnapshot.data, label: "~/.ssh/config")
                if let stripped = try? Self.stripManagedIncludeLine(from: configContent) {
                    let hasConflict = containsConflictingHostAlias(Self.hostAlias, in: stripped.remaining)
                    result.hasConflictingHostAlias = hasConflict
                    let managedByState = state?.effectiveManagedHostAlias == Self.hostAlias
                    result.sshConfigInstalled = stripped.hadManagedInclude && mimiConfigSnap.exists && managedByState
                    if result.sshConfigInstalled && !hasConflict && !trimmedUser.isEmpty && !result.hasUnsafeFileSystemState && !result.hasConflictingKeyFiles {
                        if let frozen = try? materializeEvaluationSSHConfig(
                            userConfigText: configContent,
                            includeSystemConfig: true
                        ) {
                            defer { frozen.cleanup() }
                            let valid = (try? await validateManagedEffectiveProfiles(
                                frozenConfigPath: frozen.configFileURL.path,
                                expectedUser: trimmedUser,
                                probeVerifyArguments: nil,
                                txKnownHostsPath: nil
                            )) != nil
                            result.effectiveLoopbackVerified = valid
                        }
                    }
                } else {
                    result.hasConflictingHostAlias = true
                    if state?.effectiveManagedHostAlias == Self.hostAlias {
                        result.hasPersistedManagedState = true
                    }
                }
            }
        } catch {
            result.hasUnsafeFileSystemState = true
            if state?.effectiveManagedHostAlias == Self.hostAlias {
                result.hasPersistedManagedState = true
            }
        }

        return result
    }

    /// 首次配置本机回环 SSH 并验证免密连通；若已有 Mimi 配置，则仅在已校验的现有共享锁下执行纯只读校验（不改状态目录权限、不新建/改权锁文件、不换钥、不改写磁盘文件）。
    func configure(verifyConnection: Bool = true) async throws {
        try await withReadOnlyFirstSerializedLock(
            tryReadOnly: {
                try validateStateDirectoryAndStateFile()
                guard let existingState = try loadManagedState(), !existingState.isEmpty else {
                    return nil
                }
                let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedUser.isEmpty,
                      trimmedUser.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                    throw ConfigError.invalidUsername
                }
                for checkedPath in [expectedKnownHostsPath, expectedIdentityFileConfigValue] {
                    guard !checkedPath.contains("\""),
                          !checkedPath.contains("\n"),
                          !checkedPath.contains("\r"),
                          !checkedPath.contains("%") else {
                        throw ConfigError.unsafeFileSystemTarget("Mimi SSH 隔离目录路径包含非法字符。")
                    }
                }
                if let sshDirInfo = try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh") {
                    try ensureNotGroupOrWorldWritable(
                        sshDirInfo,
                        label: "~/.ssh",
                        reason: "请先手工核对目录内容并在终端执行 chmod 700 ~/.ssh 后重试。"
                    )
                }
                try validateMimiDirectoryAndFiles()
                if let mimiDirInfo = try validateDirectoryIfPresent(mimiSSHDirectory, label: "~/.ssh/mimi") {
                    try ensureNotGroupOrWorldWritable(
                        mimiDirInfo,
                        label: "~/.ssh/mimi",
                        reason: "请先手工核对目录内容并在终端执行 chmod 700 ~/.ssh/mimi 后重试。"
                    )
                }
                try validateRegularFileIfPresent(authorizedKeysURL, label: "authorized_keys")
                try validateRegularFileIfPresent(sshConfigURL, label: "config")
                let configSnapshot = try captureSnapshot(of: sshConfigURL, label: "~/.ssh/config")
                let mimiConfigSnapshot = try captureSnapshot(of: mimiConfigURL, label: "~/.ssh/mimi/config")
                let authSnapshot = try captureSnapshot(of: authorizedKeysURL, label: "~/.ssh/authorized_keys")
                let initialKnownHostsSnapshot = try captureSnapshot(of: knownHostsURL, label: "~/.ssh/mimi/\(Self.knownHostsFileName)")
                if configSnapshot.exists, let info = configSnapshot.info {
                    try ensureNotGroupOrWorldWritable(
                        info,
                        label: "~/.ssh/config",
                        reason: "请先手工核对文件内容并在终端执行 chmod 600 ~/.ssh/config 后重试。"
                    )
                }
                if authSnapshot.exists, let info = authSnapshot.info {
                    try ensureNotGroupOrWorldWritable(
                        info,
                        label: "~/.ssh/authorized_keys",
                        reason: "请先手工核对授权条目并在终端执行 chmod 600 ~/.ssh/authorized_keys 后重试。"
                    )
                }
                try await verifyExistingConfigurationLocked(
                    previousState: existingState,
                    trimmedUser: trimmedUser,
                    configSnapshot: configSnapshot,
                    mimiConfigSnapshot: mimiConfigSnapshot,
                    authSnapshot: authSnapshot,
                    knownHostsSnapshot: initialKnownHostsSnapshot,
                    verifyConnection: verifyConnection
                )
                return ()
            },
            performWrite: {
                try await configureLocked(verifyConnection: verifyConnection)
            }
        )
    }

    /// 撤销由 Mimi 写入的本机 SSH 托管授权、`~/.ssh/mimi/` 专用密钥/配置/信任文件与 `~/.ssh/config` 顶部单行 `Include`。
    /// 仅在资源确证缺失或经归属/版本/inode 核验清理后才清除对应状态字段，任何冲突或权限异常均保留原文件与重试入口。
    func remove() async throws {
        try await withSerializedLock {
            try await removeLocked()
        }
    }

    // MARK: - Serialized State Machine Implementations

    private func configureLocked(verifyConnection: Bool) async throws {
        // =========================================================================
        // Phase 0 · Preflight（纯只读探测、权限与属主校验、冲突核查，零磁盘写入）
        // =========================================================================
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty,
              trimmedUser.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ConfigError.invalidUsername
        }
        for checkedPath in [expectedKnownHostsPath, expectedIdentityFileConfigValue] {
            guard !checkedPath.contains("\""),
                  !checkedPath.contains("\n"),
                  !checkedPath.contains("\r"),
                  !checkedPath.contains("%") else {
                throw ConfigError.unsafeFileSystemTarget("Mimi SSH 隔离目录路径包含非法字符。")
            }
        }

        if let sshDirInfo = try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh") {
            try ensureNotGroupOrWorldWritable(
                sshDirInfo,
                label: "~/.ssh",
                reason: "请先手工核对目录内容并在终端执行 chmod 700 ~/.ssh 后重试。"
            )
        }
        try validateMimiDirectoryAndFiles()
        if let mimiDirInfo = try validateDirectoryIfPresent(mimiSSHDirectory, label: "~/.ssh/mimi") {
            try ensureNotGroupOrWorldWritable(
                mimiDirInfo,
                label: "~/.ssh/mimi",
                reason: "请先手工核对目录内容并在终端执行 chmod 700 ~/.ssh/mimi 后重试。"
            )
        }
        try validateRegularFileIfPresent(authorizedKeysURL, label: "authorized_keys")
        try validateRegularFileIfPresent(sshConfigURL, label: "config")
        try validateStateDirectoryAndStateFile()

        let previousState = try loadManagedState()
        let configSnapshot = try captureSnapshot(of: sshConfigURL, label: "~/.ssh/config")
        let mimiConfigSnapshot = try captureSnapshot(of: mimiConfigURL, label: "~/.ssh/mimi/config")
        let authSnapshot = try captureSnapshot(of: authorizedKeysURL, label: "~/.ssh/authorized_keys")
        let initialKnownHostsSnapshot = try captureSnapshot(of: knownHostsURL, label: "~/.ssh/mimi/\(Self.knownHostsFileName)")

        if configSnapshot.exists, let info = configSnapshot.info {
            try ensureNotGroupOrWorldWritable(
                info,
                label: "~/.ssh/config",
                reason: "请先手工核对文件内容并在终端执行 chmod 600 ~/.ssh/config 后重试。"
            )
        }
        if authSnapshot.exists, let info = authSnapshot.info {
            try ensureNotGroupOrWorldWritable(
                info,
                label: "~/.ssh/authorized_keys",
                reason: "请先手工核对授权条目并在终端执行 chmod 600 ~/.ssh/authorized_keys 后重试。"
            )
        }

        // 已有配置时不再轮换密钥、不覆写现有配置，只做只读校验。
        if let previousState, !previousState.isEmpty {
            try await verifyExistingConfigurationLocked(
                previousState: previousState,
                trimmedUser: trimmedUser,
                configSnapshot: configSnapshot,
                mimiConfigSnapshot: mimiConfigSnapshot,
                authSnapshot: authSnapshot,
                knownHostsSnapshot: initialKnownHostsSnapshot,
                verifyConnection: verifyConnection
            )
            return
        }

        // =========================================================================
        // 首次配置 Preflight：拒绝覆盖任何未知已有文件或冲突 Host 别名
        // =========================================================================
        let hasPrivate = try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName) != nil
        let hasPublic = try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub") != nil
        if hasPrivate || hasPublic {
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
        if mimiConfigSnapshot.exists {
            throw ConfigError.conflictingKeyFiles("~/.ssh/mimi/config 已存在且无 Mimi 归属记录，已停止以免覆盖外部文件。")
        }
        if initialKnownHostsSnapshot.exists {
            throw ConfigError.conflictingKeyFiles("~/.ssh/mimi/\(Self.knownHostsFileName) 已存在且无 Mimi 归属记录，已停止以免覆盖外部文件。")
        }

        let existingConfigText = try decodeUTF8(configSnapshot.data, label: "~/.ssh/config")
        let strippedConfig = try Self.stripManagedIncludeLine(from: existingConfigText)
        if strippedConfig.hadManagedInclude &&
            (!strippedConfig.wasAtTop || strippedConfig.originalManagedLine != Self.managedIncludeLine) {
            // 拒绝在写入前静默移动非顶部或格式偏移的已有标记 Include，避免验连失败回滚时遗留被搬移的配置行。
            throw ConfigError.invalidManagedBlock
        }
        if containsConflictingHostAlias(Self.hostAlias, in: strippedConfig.remaining) {
            throw ConfigError.conflictingHostAlias(Self.hostAlias)
        }

        let candidateMimiConfigText = Self.renderMimiConfig(
            alias: Self.hostAlias,
            username: trimmedUser,
            identityFilePath: expectedIdentityFileConfigValue,
            knownHostsFilePath: expectedKnownHostsPath
        )
        let candidateConfigText: String
        if strippedConfig.hadManagedInclude && strippedConfig.wasAtTop && strippedConfig.originalManagedLine == Self.managedIncludeLine {
            candidateConfigText = existingConfigText
        } else {
            candidateConfigText = Self.composeSSHConfigWithTopInclude(remaining: strippedConfig.remaining)
        }

        try await validateCandidateSSHConfig(
            candidateUserConfig: candidateConfigText,
            candidateMimiConfig: candidateMimiConfigText,
            expectedUser: trimmedUser
        )

        let existingAuthText = try decodeUTF8(authSnapshot.data, label: "~/.ssh/authorized_keys")

        // =========================================================================
        // Phase 1 · Exclusive Inode-Tracked Staging & Write-Ahead Intent (WAL)
        // 在 ~/.ssh/mimi/ 内独占创建 0700 暂存目录并先登记 inode，再调用系统 /usr/bin/ssh-keygen
        // 生成 Ed25519 密钥对，校验后把文件 inode 与完整 WAL 落盘，绝不产生任何额外私钥副本。
        // =========================================================================
        let createdSSHDirectory = try ensureSSHDirectory()
        let createdMimiDirectory = try ensureMimiSSHDirectory()
        try ensureStateDirectory()

        let plannedMimiConfigData = Data(candidateMimiConfigText.utf8)
        let plannedMimiConfigVersion = FileVersionFingerprint.from(data: plannedMimiConfigData)
        let plannedAuthAddedLeadingNewline = !existingAuthText.isEmpty && existingAuthText.utf8.last != 0x0A

        let stagedKeyBundle: StagedKeyPairBundle
        var intentState: ManagedState
        do {
            let staged = try await stageFreshKeyPairAndPersistWAL(
                plannedAuthorizedKeyAddedLeadingNewline: plannedAuthAddedLeadingNewline,
                plannedUsername: trimmedUser,
                plannedMimiConfigVersion: plannedMimiConfigVersion
            )
            stagedKeyBundle = staged.bundle
            intentState = staged.intentState
        } catch {
            if createdMimiDirectory {
                removeDirectoryIfEmpty(mimiSSHDirectory, label: "~/.ssh/mimi")
            }
            throw error
        }
        let plannedAuthEntry = Self.formatManagedAuthorizedKeyEntry(publicKeyBody: stagedKeyBundle.publicKeyBody)

        // =========================================================================
        // Phase 2 · Atomic Commit（首次配置原子发布并记录 RollbackRecord）
        // =========================================================================
        var rollback = RollbackRecord(
            createdSSHDirectory: createdSSHDirectory,
            createdMimiDirectory: createdMimiDirectory
        )
        var trackedStagedArtifact = stagedKeyBundle.artifact
        let persistStagedQuarantine: (StagedKeyArtifact) throws -> Void = { updated in
            trackedStagedArtifact = updated
            intentState.stagedKeyArtifacts = [updated]
            intentState.pendingTransaction?.stagedKeyArtifact = updated
            try saveManagedState(intentState, invokeHook: false)
        }

        do {
            // 2a. 原子移动独占暂存目录中的唯一私钥与公钥到 `~/.ssh/mimi/`（同 inode 移动，无副本、无覆盖）
            let keyMaterial = try publishStagedKeyPairBundle(stagedKeyBundle, rollback: &rollback)
            let initialStageCleanup = try cleanupStagedKeyArtifactWithLedger(
                trackedStagedArtifact,
                persistQuarantine: persistStagedQuarantine
            )
            trackedStagedArtifact = initialStageCleanup.artifact

            // 2b. 独占新建 `~/.ssh/mimi/config`（0600）
            let writtenMimiSnapshot = try publishExclusiveNewFile(
                plannedMimiConfigData,
                to: mimiConfigURL,
                mode: 0o600,
                label: "~/.ssh/mimi/config",
                invokeHook: true,
                reportExistAsConcurrentModification: true
            )
            rollback.wroteMimiConfig = true
            rollback.writtenMimiConfigSnapshot = writtenMimiSnapshot

            // 2c. 仅在 `~/.ssh/config` 最顶部写入单行带标记 Include（保持安全原权限不变，绝不自动改权）
            let configTargetMode = Self.preservedSafeFileMode(existing: configSnapshot.mode, defaultMode: 0o600)
            if candidateConfigText != existingConfigText {
                let configData = Data(candidateConfigText.utf8)
                let writtenConfigSnapshot = try writeFileAtomically(
                    configData,
                    to: sshConfigURL,
                    mode: configTargetMode,
                    expectedSnapshot: configSnapshot,
                    label: "~/.ssh/config"
                )
                rollback.wroteSSHConfig = true
                rollback.originalConfigSnapshot = configSnapshot
                rollback.originalHadManagedInclude = strippedConfig.hadManagedInclude
                rollback.writtenConfigSnapshot = writtenConfigSnapshot
                rollback.writtenUsername = trimmedUser
            }

            // 2d. 重新核验 `authorized_keys` 快照与权限后原子追加单行受限公钥（保持安全原权限不变）
            let latestAuthSnapshot = try captureSnapshot(of: authorizedKeysURL, label: "~/.ssh/authorized_keys")
            try verifySnapshotUnchanged(authSnapshot, current: latestAuthSnapshot, label: "~/.ssh/authorized_keys")
            if latestAuthSnapshot.exists, let info = latestAuthSnapshot.info {
                try ensureNotGroupOrWorldWritable(
                    info,
                    label: "~/.ssh/authorized_keys",
                    reason: "请先手工核对授权条目并在终端执行 chmod 600 ~/.ssh/authorized_keys 后重试。"
                )
            }
            let latestAuthText = try decodeUTF8(latestAuthSnapshot.data, label: "~/.ssh/authorized_keys")
            let authEvaluation = Self.evaluateAuthorizedKeys(
                content: latestAuthText,
                keyBody: keyMaterial.publicKeyBody,
                recordedEntry: nil
            )
            if let conflictReason = authEvaluation.conflictReason {
                throw ConfigError.conflictingAuthorizedKey(conflictReason)
            }

            var nextState = ManagedState(
                keyFingerprint: keyMaterial.fingerprint,
                publicKeyBody: keyMaterial.publicKeyBody,
                authorizedKeyEntry: plannedAuthEntry,
                authorizedKeyBody: keyMaterial.publicKeyBody,
                authorizedKeyAddedLeadingNewline: false,
                managedHostAlias: Self.hostAlias,
                managedUsername: trimmedUser,
                mimiConfigVersion: plannedMimiConfigVersion,
                managedKnownHosts: false,
                knownHostsVersion: nil
            )

            let composed = Self.appendAuthorizedKeyEntry(plannedAuthEntry, to: latestAuthText)
            nextState.authorizedKeyAddedLeadingNewline = composed.addedLeadingNewline

            let authTargetMode = Self.preservedSafeFileMode(existing: latestAuthSnapshot.mode, defaultMode: 0o600)
            let writtenAuthSnapshot = try writeFileAtomically(
                Data(composed.text.utf8),
                to: authorizedKeysURL,
                mode: authTargetMode,
                expectedSnapshot: latestAuthSnapshot,
                label: "~/.ssh/authorized_keys"
            )
            rollback.wroteAuthorizedKeys = true
            rollback.originalAuthSnapshot = latestAuthSnapshot
            rollback.writtenAuthSnapshot = writtenAuthSnapshot
            rollback.addedAuthorizedKeyEntry = plannedAuthEntry
            rollback.addedAuthorizedKeyBody = keyMaterial.publicKeyBody
            rollback.addedAuthorizedKeyLeadingNewline = composed.addedLeadingNewline

            if simulateHardCrashPoint == .afterAuthorizedKeysCommit {
                throw SimulatedHardCrashError(point: .afterAuthorizedKeysCommit)
            }

            // =========================================================================
            // Phase 3 · Frozen Snapshot Verification（ssh -G 与验连共享同一份冻结快照）
            // =========================================================================
            let finalConfigSnapshot = try captureSnapshot(of: sshConfigURL, label: "~/.ssh/config")
            guard finalConfigSnapshot.exists else {
                throw ConfigError.effectiveConfigConflict("写入后未能读取 ~/.ssh/config。")
            }
            if let info = finalConfigSnapshot.info {
                try ensureNotGroupOrWorldWritable(
                    info,
                    label: "~/.ssh/config",
                    reason: "请先手工核对文件内容并在终端执行 chmod 600 ~/.ssh/config 后重试。"
                )
            }
            let finalConfigText = try decodeUTF8(finalConfigSnapshot.data, label: "~/.ssh/config")
            let verifiedSnapshotConfig = try materializeEvaluationSSHConfig(
                userConfigText: finalConfigText,
                includeSystemConfig: true
            )
            defer { verifiedSnapshotConfig.cleanup() }

            let txKnownHostsURL = verifiedSnapshotConfig.tempDirectory.appendingPathComponent("tx-known-hosts")
            try writeExclusiveTempFile(Data(), to: txKnownHostsURL, mode: 0o600)

            let verifyArguments = buildVerifyLoopbackSSHArguments(
                username: trimmedUser,
                verifiedConfigPath: verifiedSnapshotConfig.configFileURL.path,
                txKnownHostsPath: txKnownHostsURL.path,
                strictHostKeyChecking: "accept-new"
            )

            try await validateManagedEffectiveProfiles(
                frozenConfigPath: verifiedSnapshotConfig.configFileURL.path,
                expectedUser: trimmedUser,
                probeVerifyArguments: verifyConnection ? verifyArguments : nil,
                txKnownHostsPath: verifyConnection ? txKnownHostsURL.path : nil
            )

            if verifyConnection {
                try await verifyLoopbackSSH(arguments: verifyArguments)
            }

            // =========================================================================
            // Phase 4 · Commit Host Trust & Finalize State（空信任文件绝不提交）
            // =========================================================================
            if verifyConnection {
                let txSnapshot = try captureSnapshot(of: txKnownHostsURL, label: "tx-known-hosts")
                guard Self.containsValidKnownHostEntry(in: txSnapshot.data, expectedHostAlias: Self.hostAlias) else {
                    throw ConfigError.verificationFailed(
                        "本机 SSH 验连未在独立信任副本中登记 \(Self.hostAlias) 的有效主机公钥，拒绝提交空或无效信任文件并已回滚。"
                    )
                }
                let plannedKHVersion = FileVersionFingerprint.from(data: txSnapshot.data)
                intentState.pendingTransaction?.plannedKnownHostsVersion = plannedKHVersion
                try saveManagedState(intentState, invokeHook: false)

                try commitKnownHostsTransactionalResult(
                    desiredData: txSnapshot.data,
                    rollback: &rollback
                )
                nextState.managedKnownHosts = true
                nextState.knownHostsVersion = plannedKHVersion
                nextState.knownHostsConflict = false

                if simulateHardCrashPoint == .afterKnownHostsCommit {
                    throw SimulatedHardCrashError(point: .afterKnownHostsCommit)
                }
            }

            // 确认清理本次独占创建的 staging 目录（核验 inode 并先登记隔离路径），未清理成功则保留记录。
            let finalStageCleanup = try cleanupStagedKeyArtifactWithLedger(
                trackedStagedArtifact,
                persistQuarantine: persistStagedQuarantine
            )
            trackedStagedArtifact = finalStageCleanup.artifact
            if !finalStageCleanup.cleaned {
                nextState.stagedKeyArtifacts = [trackedStagedArtifact]
            }

            try saveManagedState(nextState, invokeHook: true)
        } catch let crash as SimulatedHardCrashError {
            // 仅测试崩溃模拟：跳过内存回滚与暂存清理，直接模拟进程被 SIGKILL 终止后的落盘现场。
            throw crash
        } catch {
            let fallbackStageCleanup = (try? cleanupStagedKeyArtifactWithLedger(
                trackedStagedArtifact,
                persistQuarantine: persistStagedQuarantine
            )) ?? StagedCleanupResult(cleaned: false, artifact: trackedStagedArtifact)
            trackedStagedArtifact = fallbackStageCleanup.artifact
            if !fallbackStageCleanup.cleaned {
                rollback.residualStagedKeyArtifacts.append(trackedStagedArtifact)
            }
            let rollbackOutcome = await performRollback(rollback)
            if !rollbackOutcome.fullyRolledBack {
                let baseMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let detail = rollbackOutcome.detail ?? "部分已写入项未能自动回滚，请点击「移除本机 SSH 配置」清理。"
                throw ConfigError.fileOperationFailed("\(baseMessage)（\(detail)）")
            }
            if case ConfigError.verificationFailed(let detail) = error {
                let prefix = "本机免密验证未通过，已回滚本次写入的配置"
                if detail.isEmpty {
                    throw ConfigError.verificationFailed("已回滚本次写入的配置。请确认第 1 步「远程登录」已开启。")
                }
                if !detail.contains("已回滚") {
                    throw ConfigError.verificationFailed("\(prefix)：\(detail)")
                }
            }
            throw error
        }
    }

    /// 已有 Mimi 配置时重新点击配置：仅做纯只读校验，不换钥、不覆写任何文件、不覆盖未完成事务记录。
    private func verifyExistingConfigurationLocked(
        previousState: ManagedState,
        trimmedUser: String,
        configSnapshot: FileSnapshot,
        mimiConfigSnapshot: FileSnapshot,
        authSnapshot: FileSnapshot,
        knownHostsSnapshot: FileSnapshot,
        verifyConnection: Bool
    ) async throws {
        if previousState.pendingTransaction != nil || !previousState.stagedKeyArtifacts.isEmpty || !previousState.quarantinedFileArtifacts.isEmpty {
            throw ConfigError.conflictingKeyFiles(
                "检测到上次本机 SSH 配置未完成或存在残留暂存/隔离记录，请先点击「移除本机 SSH 配置」清理后再重新配置。"
            )
        }
        if !previousState.residualAuthorizedKeyBodies.isEmpty {
            throw ConfigError.conflictingAuthorizedKey(
                "~/.ssh/authorized_keys 中仍存在历史残留同公钥授权行，请先手工核对并点击「移除本机 SSH 配置」清理后再试。"
            )
        }
        if previousState.mimiConfigConflict {
            throw ConfigError.conflictingKeyFiles(
                "~/.ssh/mimi/config 存在待核对的外部修改冲突，请先手工核对或点击「移除本机 SSH 配置」清理。"
            )
        }
        if previousState.knownHostsConflict {
            throw ConfigError.conflictingKeyFiles(
                "~/.ssh/mimi/\(Self.knownHostsFileName) 存在待核对的外部修改冲突，请先手工核对或点击「移除本机 SSH 配置」清理。"
            )
        }
        guard previousState.managedHostAlias == Self.hostAlias,
              previousState.managedUsername == trimmedUser else {
            throw ConfigError.conflictingKeyFiles(
                "已有本机 SSH 配置与当前用户不一致，为避免自动换钥或改写配置已停止；请先点击「移除本机 SSH 配置」后再重新配置。"
            )
        }

        // 1. 核验现有专用密钥对完整且与记录指纹一致（不换钥、不重建）
        guard let expectedKeyBody = previousState.publicKeyBody, !expectedKeyBody.isEmpty,
              let expectedKeyFP = previousState.keyFingerprint, !expectedKeyFP.isEmpty else {
            throw ConfigError.conflictingKeyFiles("状态记录缺少 Mimi 密钥指纹，请先点击「移除本机 SSH 配置」后重新配置。")
        }
        let hasPrivate = try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName) != nil
        let hasPublic = try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub") != nil
        let ownedKeyVerified: Bool
        if hasPrivate && hasPublic {
            ownedKeyVerified = await verifyOwnedKeyPair(expectedBody: expectedKeyBody, expectedFingerprint: expectedKeyFP)
        } else {
            ownedKeyVerified = false
        }
        guard ownedKeyVerified else {
            throw ConfigError.conflictingKeyFiles(
                "现有 Mimi 专用密钥缺失、损坏或与记录指纹不一致（本向导不会自动轮换密钥），请先点击「移除本机 SSH 配置」后再重新配置。"
            )
        }

        // 2. 核验 ~/.ssh/mimi/config 与记录版本及期望渲染一致
        guard mimiConfigSnapshot.exists else {
            throw ConfigError.conflictingKeyFiles("~/.ssh/mimi/config 缺失，请先点击「移除本机 SSH 配置」后再重新配置。")
        }
        guard let expectedMimiVer = previousState.mimiConfigVersion,
              expectedMimiVer.matches(data: mimiConfigSnapshot.data) else {
            throw ConfigError.conflictingKeyFiles("~/.ssh/mimi/config 与 Mimi 记录版本不一致，已停止以免覆盖外部改动。")
        }
        let expectedMimiConfigText = Self.renderMimiConfig(
            alias: Self.hostAlias,
            username: trimmedUser,
            identityFilePath: expectedIdentityFileConfigValue,
            knownHostsFilePath: expectedKnownHostsPath
        )
        let currentMimiConfigText = try decodeUTF8(mimiConfigSnapshot.data, label: "~/.ssh/mimi/config")
        guard currentMimiConfigText == expectedMimiConfigText else {
            throw ConfigError.conflictingKeyFiles("~/.ssh/mimi/config 内容与当前预期配置不一致，请先点击「移除本机 SSH 配置」后再重新配置。")
        }

        // 3. 核验 ~/.ssh/config 包含顶部托管 Include 且无冲突别名
        guard configSnapshot.exists else {
            throw ConfigError.effectiveConfigConflict("~/.ssh/config 缺失，请先点击「移除本机 SSH 配置」后再重新配置。")
        }
        let existingConfigText = try decodeUTF8(configSnapshot.data, label: "~/.ssh/config")
        let strippedConfig = try Self.stripManagedIncludeLine(from: existingConfigText)
        if containsConflictingHostAlias(Self.hostAlias, in: strippedConfig.remaining) {
            throw ConfigError.conflictingHostAlias(Self.hostAlias)
        }
        guard strippedConfig.hadManagedInclude && strippedConfig.wasAtTop && strippedConfig.originalManagedLine == Self.managedIncludeLine else {
            throw ConfigError.effectiveConfigConflict("~/.ssh/config 顶部缺少完整的 Mimi 托管 Include 行，请先点击「移除本机 SSH 配置」后再重新配置。")
        }

        // 4. 核验 ~/.ssh/authorized_keys 包含精确托管授权且无冲突
        guard authSnapshot.exists else {
            throw ConfigError.conflictingAuthorizedKey("~/.ssh/authorized_keys 缺失，请先点击「移除本机 SSH 配置」后再重新配置。")
        }
        let existingAuthText = try decodeUTF8(authSnapshot.data, label: "~/.ssh/authorized_keys")
        let authEvaluation = Self.evaluateAuthorizedKeys(
            content: existingAuthText,
            keyBody: expectedKeyBody,
            recordedEntry: previousState.authorizedKeyEntry
        )
        if let conflictReason = authEvaluation.conflictReason {
            throw ConfigError.conflictingAuthorizedKey(conflictReason)
        }
        guard authEvaluation.hasExactMimiEntry else {
            throw ConfigError.conflictingAuthorizedKey("~/.ssh/authorized_keys 缺少 Mimi 托管授权行，请先点击「移除本机 SSH 配置」后再重新配置。")
        }

        // 5. 核验 ~/.ssh/mimi/known_hosts 归属版本（若存在）
        if knownHostsSnapshot.exists {
            guard let expectedKHVer = previousState.knownHostsVersion,
                  expectedKHVer.matches(data: knownHostsSnapshot.data) else {
                throw ConfigError.conflictingKeyFiles("~/.ssh/mimi/\(Self.knownHostsFileName) 与 Mimi 记录版本不一致，已停止。")
            }
        }

        // 6. 基于同一份冻结快照执行 ssh -G 校验与（可选）只读回环验连，绝不改写磁盘
        let frozenConfig = try materializeEvaluationSSHConfig(
            userConfigText: existingConfigText,
            includeSystemConfig: true
        )
        defer { frozenConfig.cleanup() }

        if verifyConnection {
            guard knownHostsSnapshot.exists,
                  Self.containsValidKnownHostEntry(in: knownHostsSnapshot.data, expectedHostAlias: Self.hostAlias) else {
                throw ConfigError.verificationFailed("独立主机信任文件缺失或无效，请先点击「移除本机 SSH 配置」后再重新配置。")
            }
            let txKnownHostsURL = frozenConfig.tempDirectory.appendingPathComponent("tx-known-hosts")
            try writeExclusiveTempFile(knownHostsSnapshot.data, to: txKnownHostsURL, mode: 0o600)
            let verifyArguments = buildVerifyLoopbackSSHArguments(
                username: trimmedUser,
                verifiedConfigPath: frozenConfig.configFileURL.path,
                txKnownHostsPath: txKnownHostsURL.path,
                strictHostKeyChecking: "yes"
            )
            try await validateManagedEffectiveProfiles(
                frozenConfigPath: frozenConfig.configFileURL.path,
                expectedUser: trimmedUser,
                probeVerifyArguments: verifyArguments,
                txKnownHostsPath: txKnownHostsURL.path
            )
            try await verifyLoopbackSSH(arguments: verifyArguments)
        } else {
            try await validateManagedEffectiveProfiles(
                frozenConfigPath: frozenConfig.configFileURL.path,
                expectedUser: trimmedUser,
                probeVerifyArguments: nil,
                txKnownHostsPath: nil
            )
        }
    }

    private func commitKnownHostsTransactionalResult(
        desiredData: Data,
        rollback: inout RollbackRecord
    ) throws {
        guard Self.containsValidKnownHostEntry(in: desiredData, expectedHostAlias: Self.hostAlias) else {
            throw ConfigError.verificationFailed("独立主机信任文件内容为空或缺少 \(Self.hostAlias) 的有效主机公钥，已拒绝提交。")
        }
        _ = try ensureMimiSSHDirectory()
        try validateRegularFileIfPresent(knownHostsURL, label: "~/.ssh/mimi/\(Self.knownHostsFileName)")

        let writtenSnapshot = try publishExclusiveNewFile(
            desiredData,
            to: knownHostsURL,
            mode: 0o600,
            label: "~/.ssh/mimi/\(Self.knownHostsFileName)",
            invokeHook: true,
            reportExistAsConcurrentModification: true
        )
        rollback.knownHostsMutation = .created(writtenSnapshot: writtenSnapshot)
    }

    private func removeLocked() async throws {
        // 先独立校验并读取状态文件，不被 ~/.ssh/mimi 异常阻断授权撤销。
        try validateStateDirectoryAndStateFile()

        var state = (try loadManagedState()) ?? ManagedState()
        // 将任何中断的首次配置 WAL 意图合并为待清理目标。
        if let pending = state.pendingTransaction {
            if state.keyFingerprint == nil {
                state.keyFingerprint = pending.keyFingerprint
            }
            if state.publicKeyBody == nil {
                state.publicKeyBody = pending.publicKeyBody
            }
            if state.authorizedKeyEntry == nil {
                state.authorizedKeyEntry = pending.plannedAuthorizedKeyEntry
                state.authorizedKeyBody = pending.plannedAuthorizedKeyBody
                state.authorizedKeyAddedLeadingNewline = pending.authorizedKeyAddedLeadingNewline
            }
            if state.managedHostAlias == nil {
                state.managedHostAlias = pending.plannedHostAlias
                state.managedUsername = pending.plannedUsername
            }
            if state.mimiConfigVersion == nil {
                state.mimiConfigVersion = pending.plannedMimiConfigVersion
            }
            if let khVer = pending.plannedKnownHostsVersion {
                if state.knownHostsVersion == nil {
                    state.knownHostsVersion = khVer
                }
                state.managedKnownHosts = true
            }
            if let stagedArtifact = pending.stagedKeyArtifact,
               !state.stagedKeyArtifacts.contains(stagedArtifact) {
                state.stagedKeyArtifacts.append(stagedArtifact)
            }
            state.pendingTransaction = nil
        }

        var errors: [ConfigError] = []

        var sshDirectorySafe = true
        do {
            if let sshDirInfo = try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh") {
                try ensureNotGroupOrWorldWritable(
                    sshDirInfo,
                    label: "~/.ssh",
                    reason: "请先手工核对目录内容并在终端执行 chmod 700 ~/.ssh 后再试。"
                )
            }
        } catch let error as ConfigError {
            errors.append(error)
            sshDirectorySafe = false
        } catch {
            errors.append(.fileOperationFailed(error.localizedDescription))
            sshDirectorySafe = false
        }

        if sshDirectorySafe {
            let persistQuarantinedFile: (QuarantinedFileArtifact) throws -> Void = { artifact in
                if !state.quarantinedFileArtifacts.contains(artifact) {
                    state.quarantinedFileArtifacts.append(artifact)
                }
                try saveManagedState(state, invokeHook: false)
            }
            let clearQuarantinedFile: (QuarantinedFileArtifact) throws -> Void = { artifact in
                state.quarantinedFileArtifacts.removeAll { $0 == artifact }
            }

            // 0. 崩溃/unlink 失败恢复：优先按已持久化账本核验并清理所有滞留隔离文件，未恢复完成绝不报告移除成功。
            if !state.quarantinedFileArtifacts.isEmpty {
                var remainingQuarantined: [QuarantinedFileArtifact] = []
                for artifact in state.quarantinedFileArtifacts {
                    do {
                        let cleaned = try recoverQuarantinedFileArtifact(artifact)
                        if !cleaned {
                            remainingQuarantined.append(artifact)
                        }
                    } catch let error as ConfigError {
                        remainingQuarantined.append(artifact)
                        errors.append(error)
                    } catch {
                        remainingQuarantined.append(artifact)
                        errors.append(.fileOperationFailed(error.localizedDescription))
                    }
                }
                state.quarantinedFileArtifacts = remainingQuarantined
            }

            // 1. 优先撤销 authorized_keys：仅删带 Mimi 标记的精确行，并检查同公钥残留。
            do {
                switch try probePath(authorizedKeysURL, label: "authorized_keys") {
                case .missing:
                    state.authorizedKeyEntry = nil
                    state.authorizedKeyBody = nil
                    state.authorizedKeyAddedLeadingNewline = false
                    state.residualAuthorizedKeyBodies = []
                case .present:
                    try validateRegularFileIfPresent(authorizedKeysURL, label: "authorized_keys")
                    let trackedBodies = state.allTrackedAuthorizedKeyBodies
                    if state.authorizedKeyEntry != nil || !trackedBodies.isEmpty {
                        let outcome = try removeTrackedAuthorizedEntry(
                            entry: state.authorizedKeyEntry,
                            expectedKeyBody: state.effectiveAuthorizedKeyBody,
                            addedLeadingNewline: state.authorizedKeyAddedLeadingNewline,
                            trackedBodies: trackedBodies
                        )
                        if outcome.residualBodies.isEmpty {
                            state.authorizedKeyEntry = nil
                            state.authorizedKeyBody = nil
                            state.authorizedKeyAddedLeadingNewline = false
                            state.residualAuthorizedKeyBodies = []
                        } else {
                            // 绝不丢失残留同公钥授权记录！
                            state.authorizedKeyEntry = nil
                            state.authorizedKeyAddedLeadingNewline = false
                            state.authorizedKeyBody = outcome.residualBodies.first
                            state.residualAuthorizedKeyBodies = outcome.residualBodies
                            throw ConfigError.conflictingAuthorizedKey(
                                "~/.ssh/authorized_keys 中仍存在同公钥的其他授权行（Mimi 标记行已清理或已被修改），已保留其他行与撤销记录，请手工核对。"
                            )
                        }
                    }
                }
            } catch let error as ConfigError {
                errors.append(error)
            } catch {
                errors.append(.fileOperationFailed(error.localizedDescription))
            }

            // 2. 检查 ~/.ssh/mimi 目录，独立安全清理密钥、已登记 inode 暂存产物、mimi/config 与 mimi/known_hosts
            var mimiDirSafe = true
            var mimiDirPresent = false
            do {
                switch try probePath(mimiSSHDirectory, label: "~/.ssh/mimi") {
                case .missing:
                    mimiDirPresent = false
                    state.keyFingerprint = nil
                    state.publicKeyBody = nil
                    state.stagedKeyArtifacts = []
                    state.quarantinedFileArtifacts.removeAll { $0.parentScope == "mimi" }
                    state.mimiConfigVersion = nil
                    state.mimiConfigConflict = false
                    state.managedKnownHosts = false
                    state.knownHostsVersion = nil
                    state.knownHostsConflict = false
                case .present:
                    if let mimiDirInfo = try validateDirectoryIfPresent(mimiSSHDirectory, label: "~/.ssh/mimi") {
                        try ensureNotGroupOrWorldWritable(
                            mimiDirInfo,
                            label: "~/.ssh/mimi",
                            reason: "请先手工核对目录内容并在终端执行 chmod 700 ~/.ssh/mimi 后再试。"
                        )
                    }
                    mimiDirPresent = true
                }
            } catch let error as ConfigError {
                errors.append(error)
                mimiDirSafe = false
            } catch {
                errors.append(.fileOperationFailed(error.localizedDescription))
                mimiDirSafe = false
            }

            if mimiDirSafe && mimiDirPresent {
                // 2a. 仅删除经字节密码学指纹核验与隔离快照核验确属 Mimi 的专用密钥文件（隔离移动前先入账，崩溃/unlink 失败不丢归属记录）。
                do {
                    let removedKeys = try await removeOwnedKeyFilesIfVerified(
                        state: state,
                        journalQuarantine: persistQuarantinedFile,
                        clearQuarantine: clearQuarantinedFile
                    )
                    let hasStrandedKeyQuarantine = state.quarantinedFileArtifacts.contains {
                        $0.parentScope == "mimi" &&
                            ($0.originalFileName == Self.keyFileName || $0.originalFileName == "\(Self.keyFileName).pub")
                    }
                    if removedKeys && !hasStrandedKeyQuarantine {
                        state.keyFingerprint = nil
                        state.publicKeyBody = nil
                    }
                } catch let crash as SimulatedHardCrashError {
                    throw crash
                } catch let error as ConfigError {
                    errors.append(error)
                } catch {
                    errors.append(.fileOperationFailed(error.localizedDescription))
                }

                // 2b. 清理本次独占创建且记录了 inode 的 `~/.ssh/mimi/.mimi-keygen-*` 暂存产物（移入隔离目录前必须先持久化隔离目录名与 inode）。
                if !state.stagedKeyArtifacts.isEmpty {
                    var remainingStaged: [StagedKeyArtifact] = []
                    for index in state.stagedKeyArtifacts.indices {
                        let artifact = state.stagedKeyArtifacts[index]
                        do {
                            let result = try cleanupStagedKeyArtifactWithLedger(
                                artifact,
                                persistQuarantine: { updated in
                                    var persistedState = state
                                    persistedState.stagedKeyArtifacts[index] = updated
                                    try saveManagedState(persistedState, invokeHook: false)
                                    state.stagedKeyArtifacts[index] = updated
                                }
                            )
                            if !result.cleaned {
                                remainingStaged.append(result.artifact)
                            }
                        } catch let crash as SimulatedHardCrashError {
                            throw crash
                        } catch {
                            remainingStaged.append(state.stagedKeyArtifacts[index])
                            errors.append(.fileOperationFailed(error.localizedDescription))
                        }
                    }
                    state.stagedKeyArtifacts = remainingStaged
                    if !remainingStaged.isEmpty {
                        let names = remainingStaged.map { artifact -> String in
                            if let qDir = artifact.quarantineDirectoryName {
                                return "\(artifact.directoryName)（隔离目录：\(qDir)）"
                            }
                            return artifact.directoryName
                        }.joined(separator: "、")
                        errors.append(.fileOperationFailed("未能清理残留密钥暂存目录（缺少已记录 inode、inode 不匹配或目录非空），已保守保留未删除，请手工核对 ~/.ssh/mimi/：\(names)"))
                    }
                }
            }

            // 3. 仅移除 ~/.ssh/config 中的单行带标记 Include（拒绝修改不安全权限文件，保持安全原权限不变）。
            do {
                switch try probePath(sshConfigURL, label: "config") {
                case .missing:
                    state.managedHostAlias = nil
                    state.managedUsername = nil
                case .present:
                    try validateRegularFileIfPresent(sshConfigURL, label: "config")
                    let snapshot = try captureSnapshot(of: sshConfigURL, label: "~/.ssh/config")
                    if let info = snapshot.info {
                        try ensureNotGroupOrWorldWritable(
                            info,
                            label: "~/.ssh/config",
                            reason: "请先手工核对文件内容并在终端执行 chmod 600 ~/.ssh/config 后再试。"
                        )
                    }
                    let content = try decodeUTF8(snapshot.data, label: "~/.ssh/config")
                    let stripped = try Self.stripManagedIncludeLine(from: content)
                    if stripped.hadManagedInclude {
                        let targetMode = Self.preservedSafeFileMode(existing: snapshot.mode, defaultMode: 0o600)
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

            if mimiDirSafe && mimiDirPresent {
                // 4. 按版本指纹核验并清理 ~/.ssh/mimi/config（临时 I/O 错误不置位持久冲突标记，隔离前先入账）
                do {
                    try removeVersionVerifiedManagedFile(
                        at: mimiConfigURL,
                        label: "~/.ssh/mimi/config",
                        expectedVersion: state.effectiveMimiConfigVersion,
                        hasConflictFlag: state.mimiConfigConflict,
                        journalQuarantine: persistQuarantinedFile,
                        clearQuarantine: clearQuarantinedFile
                    )
                    let hasStrandedMimiConfig = state.quarantinedFileArtifacts.contains {
                        $0.parentScope == "mimi" && $0.originalFileName == Self.mimiConfigFileName
                    }
                    if !hasStrandedMimiConfig {
                        state.mimiConfigVersion = nil
                        state.mimiConfigConflict = false
                    }
                } catch let crash as SimulatedHardCrashError {
                    throw crash
                } catch let error as ConfigError {
                    if case .conflictingKeyFiles = error {
                        state.mimiConfigConflict = true
                    }
                    errors.append(error)
                } catch {
                    errors.append(.fileOperationFailed(error.localizedDescription))
                }

                // 5. 按版本指纹与冲突标记核验并清理 ~/.ssh/mimi/known_hosts（临时 I/O 错误不置位持久冲突标记，隔离前先入账）
                do {
                    try removeVersionVerifiedManagedFile(
                        at: knownHostsURL,
                        label: "~/.ssh/mimi/\(Self.knownHostsFileName)",
                        expectedVersion: state.effectiveKnownHostsVersion,
                        hasConflictFlag: state.knownHostsConflict,
                        journalQuarantine: persistQuarantinedFile,
                        clearQuarantine: clearQuarantinedFile
                    )
                    let hasStrandedKH = state.quarantinedFileArtifacts.contains {
                        $0.parentScope == "mimi" && $0.originalFileName == Self.knownHostsFileName
                    }
                    if !hasStrandedKH {
                        state.managedKnownHosts = false
                        state.knownHostsVersion = nil
                        state.knownHostsConflict = false
                    }
                } catch let crash as SimulatedHardCrashError {
                    throw crash
                } catch let error as ConfigError {
                    state.managedKnownHosts = true
                    if case .conflictingKeyFiles = error {
                        state.knownHostsConflict = true
                    }
                    errors.append(error)
                } catch {
                    state.managedKnownHosts = true
                    errors.append(.fileOperationFailed(error.localizedDescription))
                }

                // 6. 仅当 ~/.ssh/mimi 目录已空时安全移除空目录。
                removeDirectoryIfEmpty(mimiSSHDirectory, label: "~/.ssh/mimi")
            }
        }

        // 7. 按实际清理结果更新或移除状态文件，不静默忽略持久化错误。
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

    private func removeVersionVerifiedManagedFile(
        at url: URL,
        label: String,
        expectedVersion: FileVersionFingerprint?,
        hasConflictFlag: Bool,
        journalQuarantine: ((QuarantinedFileArtifact) throws -> Void)? = nil,
        clearQuarantine: ((QuarantinedFileArtifact) throws -> Void)? = nil
    ) throws {
        switch try probePath(url, label: label) {
        case .missing:
            return
        case .present:
            try validateRegularFileIfPresent(url, label: label)
            let snapshot = try captureSnapshot(of: url, label: label)
            guard snapshot.exists else { return }
            guard !hasConflictFlag,
                  let expectedVersion,
                  expectedVersion.matches(data: snapshot.data) else {
                throw ConfigError.conflictingKeyFiles(
                    "\(label) 已被外部修改、替换或缺少已证实的 Mimi 版本归属记录，撤销时已保留未删除，请手工核对。"
                )
            }
            try removeFileMatchingSnapshot(
                url,
                expectedSnapshot: snapshot,
                label: label,
                invokeHook: true,
                journalQuarantine: journalQuarantine,
                clearQuarantine: clearQuarantine
            )
        }
    }
}
