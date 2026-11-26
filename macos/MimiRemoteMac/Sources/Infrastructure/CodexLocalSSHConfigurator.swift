import CryptoKit
import Darwin
import Foundation

/// 为 Codex 桌面版安全、幂等、可撤销地配置本机回环 SSH（#376）。
/// 采用隔离目录方案：所有 Mimi 自有配置、专用密钥与独立 `known_hosts` 均存放在 `~/.ssh/mimi/`（目录 `0700`、文件 `0600`）；
/// `~/.ssh/config` 仅在最顶部加入一行带标记的 `Include "~/.ssh/mimi/config"`；`~/.ssh/authorized_keys` 仅追加一行带 Mimi 标记且带 `restrict,from="127.0.0.1,::1"` 限制的公钥。
///
/// 整体状态机与事务模型：
/// - 生命周期状态：`Absent` / `PendingTransaction(崩溃恢复态)` / `Ready` / `Degraded(isManaged=true, isReady=false)`。
/// - 文件探测统一使用三态 `PathProbe`（`ENOENT` -> `.missing`；存在 -> `.present`；任何权限/路径异常 -> 显式抛错）。
/// - `configure` 五阶段：
///   - Phase 0 · Preflight（纯只读探测、归属与版本核验、残余授权检查、候选配置虚拟注入多画像 `ssh -G` 校验，零磁盘写入）
///   - Phase 1 · Write-Ahead Intent（在独占 `0700` 临时目录生成并校验密钥后，先将 `pendingTransaction` 写入 `stateFileURL`，保证后续任意中断点重启后均无孤儿授权）
///   - Phase 2 · Atomic Commit（逐项无覆盖发布或 `RENAME_SWAP` 原子交换并核验实际换下的 inode，登记 `RollbackRecord`）
///   - Phase 3 · Isolated Verification（冻结快照 + 事务内 `tx-known-hosts` 副本 + 固定 `HostKeyAlias`/`AddressFamily`/`NoHostAuthenticationForLocalhost=no` + 双向握手 + 确认目标主机公钥已写入非空信任副本）
///   - Phase 4 · Commit Trust & Finalize（先更新 WAL 目标版本，再原子提交 `~/.ssh/mimi/known_hosts` 并落盘清除 `pendingTransaction`）
/// - `remove` 合并 `pendingTransaction` 后按顺序清理：`authorized_keys`（仅删标记行 + 共用按公钥残留检查）-> `~/.ssh/mimi/` 专用密钥（指纹核验）-> `~/.ssh/config` 单行 `Include` -> `~/.ssh/mimi/config`（版本核验）-> `~/.ssh/mimi/known_hosts`（版本与冲突核验）-> 空目录 `rmdir` `~/.ssh/mimi`。
struct CodexLocalSSHConfigurator: Sendable {
    static let hostAlias = "mimi-local"
    static let mimiDirectoryName = "mimi"
    static let mimiConfigFileName = "config"
    static let knownHostsFileName = "known_hosts"
    static let keyFileName = "mimi_codex_local_ed25519"
    static let keyComment = "mimi-codex-local"
    static let keyStagingDirectoryPrefix = ".mimi-keygen-"
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

    struct TrackedKeyIdentity: Codable, Equatable, Sendable {
        var keyFingerprint: String
        var publicKeyBody: String
    }

    struct TrackedAuthorizedEntry: Codable, Equatable, Sendable {
        var entry: String
        var keyBody: String
        var addedLeadingNewline: Bool = false
    }

    /// 首次持久变更前落盘的预写事务意图（WAL）：保证进程在任意写盘点被强杀后，重启仍能识别归属并安全撤销，绝不产生孤儿授权。
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
        var stagedKeyDirectoryName: String? = nil
    }

    struct ManagedState: Codable, Equatable, Sendable {
        var version: Int = 2
        var keyFingerprint: String?
        var publicKeyBody: String?
        /// 轮换密钥崩溃恢复期间保留新旧全部受管密钥身份，直到核验清理完成才销账。
        var additionalKeyIdentities: [TrackedKeyIdentity] = []
        var authorizedKeyEntry: String?
        /// 独立保存托管授权行对应的公钥主体，确保即使密钥已被删除、授权写回失败后重试仍能核验并撤销残留授权。
        var authorizedKeyBody: String?
        var authorizedKeyAddedLeadingNewline: Bool = false
        /// 轮换密钥崩溃恢复期间保留新旧精确托管授权行（含前导换行记录），避免丢失替换密钥的精确撤销记录。
        var additionalAuthorizedEntries: [TrackedAuthorizedEntry] = []
        /// 跨回滚、重配、撤销记录未能清除的同一/历史公钥主体，避免任何入口静默丢弃有效授权记录。
        var residualAuthorizedKeyBodies: [String] = []
        var managedHostAlias: String?
        var managedUsername: String?
        var mimiConfigVersion: FileVersionFingerprint?
        var additionalMimiConfigVersions: [FileVersionFingerprint] = []
        var mimiConfigConflict: Bool = false
        /// 记录独立主机信任文件是否仍待管理/清理，并配对已证实归属的版本指纹与冲突标记。
        var managedKnownHosts: Bool = false
        var knownHostsVersion: FileVersionFingerprint?
        var additionalKnownHostsVersions: [FileVersionFingerprint] = []
        var knownHostsConflict: Bool = false
        /// 密钥生成前登记的 `~/.ssh/mimi/.mimi-keygen-*` 暂存目录名，确保进程异常终止后移除流程可完整清理私钥产物。
        var stagedKeyDirectories: [String] = []
        var pendingTransaction: PendingTransaction?

        init(
            version: Int = 2,
            keyFingerprint: String? = nil,
            publicKeyBody: String? = nil,
            additionalKeyIdentities: [TrackedKeyIdentity] = [],
            authorizedKeyEntry: String? = nil,
            authorizedKeyBody: String? = nil,
            authorizedKeyAddedLeadingNewline: Bool = false,
            additionalAuthorizedEntries: [TrackedAuthorizedEntry] = [],
            residualAuthorizedKeyBodies: [String] = [],
            managedHostAlias: String? = nil,
            managedUsername: String? = nil,
            mimiConfigVersion: FileVersionFingerprint? = nil,
            additionalMimiConfigVersions: [FileVersionFingerprint] = [],
            mimiConfigConflict: Bool = false,
            managedKnownHosts: Bool = false,
            knownHostsVersion: FileVersionFingerprint? = nil,
            additionalKnownHostsVersions: [FileVersionFingerprint] = [],
            knownHostsConflict: Bool = false,
            stagedKeyDirectories: [String] = [],
            pendingTransaction: PendingTransaction? = nil
        ) {
            self.version = version
            self.keyFingerprint = keyFingerprint
            self.publicKeyBody = publicKeyBody
            self.additionalKeyIdentities = additionalKeyIdentities
            self.authorizedKeyEntry = authorizedKeyEntry
            self.authorizedKeyBody = authorizedKeyBody
            self.authorizedKeyAddedLeadingNewline = authorizedKeyAddedLeadingNewline
            self.additionalAuthorizedEntries = additionalAuthorizedEntries
            self.residualAuthorizedKeyBodies = residualAuthorizedKeyBodies
            self.managedHostAlias = managedHostAlias
            self.managedUsername = managedUsername
            self.mimiConfigVersion = mimiConfigVersion
            self.additionalMimiConfigVersions = additionalMimiConfigVersions
            self.mimiConfigConflict = mimiConfigConflict
            self.managedKnownHosts = managedKnownHosts
            self.knownHostsVersion = knownHostsVersion
            self.additionalKnownHostsVersions = additionalKnownHostsVersions
            self.knownHostsConflict = knownHostsConflict
            self.stagedKeyDirectories = stagedKeyDirectories
            self.pendingTransaction = pendingTransaction
        }

        enum CodingKeys: String, CodingKey {
            case version
            case keyFingerprint
            case publicKeyBody
            case additionalKeyIdentities
            case authorizedKeyEntry
            case authorizedKeyBody
            case authorizedKeyAddedLeadingNewline
            case additionalAuthorizedEntries
            case residualAuthorizedKeyBodies
            case managedHostAlias
            case managedUsername
            case mimiConfigVersion
            case additionalMimiConfigVersions
            case mimiConfigConflict
            case managedKnownHosts
            case knownHostsVersion
            case additionalKnownHostsVersions
            case knownHostsConflict
            case stagedKeyDirectories
            case pendingTransaction
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
            keyFingerprint = try container.decodeIfPresent(String.self, forKey: .keyFingerprint)
            publicKeyBody = try container.decodeIfPresent(String.self, forKey: .publicKeyBody)
            additionalKeyIdentities = try container.decodeIfPresent([TrackedKeyIdentity].self, forKey: .additionalKeyIdentities) ?? []
            authorizedKeyEntry = try container.decodeIfPresent(String.self, forKey: .authorizedKeyEntry)
            authorizedKeyBody = try container.decodeIfPresent(String.self, forKey: .authorizedKeyBody)
            authorizedKeyAddedLeadingNewline = try container.decodeIfPresent(Bool.self, forKey: .authorizedKeyAddedLeadingNewline) ?? false
            additionalAuthorizedEntries = try container.decodeIfPresent([TrackedAuthorizedEntry].self, forKey: .additionalAuthorizedEntries) ?? []
            residualAuthorizedKeyBodies = try container.decodeIfPresent([String].self, forKey: .residualAuthorizedKeyBodies) ?? []
            managedHostAlias = try container.decodeIfPresent(String.self, forKey: .managedHostAlias)
            managedUsername = try container.decodeIfPresent(String.self, forKey: .managedUsername)
            mimiConfigVersion = try container.decodeIfPresent(FileVersionFingerprint.self, forKey: .mimiConfigVersion)
            additionalMimiConfigVersions = try container.decodeIfPresent([FileVersionFingerprint].self, forKey: .additionalMimiConfigVersions) ?? []
            mimiConfigConflict = try container.decodeIfPresent(Bool.self, forKey: .mimiConfigConflict) ?? false
            managedKnownHosts = try container.decodeIfPresent(Bool.self, forKey: .managedKnownHosts) ?? false
            knownHostsVersion = try container.decodeIfPresent(FileVersionFingerprint.self, forKey: .knownHostsVersion)
            additionalKnownHostsVersions = try container.decodeIfPresent([FileVersionFingerprint].self, forKey: .additionalKnownHostsVersions) ?? []
            knownHostsConflict = try container.decodeIfPresent(Bool.self, forKey: .knownHostsConflict) ?? false
            stagedKeyDirectories = try container.decodeIfPresent([String].self, forKey: .stagedKeyDirectories) ?? []
            pendingTransaction = try container.decodeIfPresent(PendingTransaction.self, forKey: .pendingTransaction)
        }

        var allTrackedKeyIdentities: [TrackedKeyIdentity] {
            var identities: [TrackedKeyIdentity] = []
            func appendUnique(fingerprint: String?, body: String?) {
                guard let fingerprint, !fingerprint.isEmpty,
                      let body, !body.isEmpty else { return }
                let item = TrackedKeyIdentity(keyFingerprint: fingerprint, publicKeyBody: body)
                if !identities.contains(item) {
                    identities.append(item)
                }
            }
            appendUnique(fingerprint: keyFingerprint, body: publicKeyBody)
            for item in additionalKeyIdentities {
                appendUnique(fingerprint: item.keyFingerprint, body: item.publicKeyBody)
            }
            if let pending = pendingTransaction {
                appendUnique(fingerprint: pending.keyFingerprint, body: pending.publicKeyBody)
            }
            return identities
        }

        var effectiveKeyBody: String? {
            allTrackedKeyIdentities.first?.publicKeyBody
        }

        var effectiveKeyFingerprint: String? {
            allTrackedKeyIdentities.first?.keyFingerprint
        }

        var effectiveAuthorizedKeyBody: String? {
            if let authorizedKeyBody, !authorizedKeyBody.isEmpty { return authorizedKeyBody }
            if let pendingBody = pendingTransaction?.plannedAuthorizedKeyBody, !pendingBody.isEmpty { return pendingBody }
            if let additionalBody = additionalAuthorizedEntries.first?.keyBody, !additionalBody.isEmpty { return additionalBody }
            if let publicKeyBody, !publicKeyBody.isEmpty { return publicKeyBody }
            if let entry = authorizedKeyEntry {
                return CodexLocalSSHConfigurator.parseAuthorizedKeyLine(entry)?.keyBody
            }
            return residualAuthorizedKeyBodies.first
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
            for item in additionalKeyIdentities {
                appendUnique(item.publicKeyBody)
            }
            for item in additionalAuthorizedEntries {
                appendUnique(item.keyBody)
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

        var allTrackedAuthorizedEntries: [TrackedAuthorizedEntry] {
            var items: [TrackedAuthorizedEntry] = []
            func appendUnique(_ item: TrackedAuthorizedEntry) {
                guard !item.entry.isEmpty, !item.keyBody.isEmpty else { return }
                if !items.contains(where: { $0.entry == item.entry && $0.keyBody == item.keyBody }) {
                    items.append(item)
                }
            }
            if let entry = authorizedKeyEntry, let body = authorizedKeyBody ?? CodexLocalSSHConfigurator.parseAuthorizedKeyLine(entry)?.keyBody {
                appendUnique(TrackedAuthorizedEntry(entry: entry, keyBody: body, addedLeadingNewline: authorizedKeyAddedLeadingNewline))
            }
            for item in additionalAuthorizedEntries {
                appendUnique(item)
            }
            if let pending = pendingTransaction {
                appendUnique(TrackedAuthorizedEntry(
                    entry: pending.plannedAuthorizedKeyEntry,
                    keyBody: pending.plannedAuthorizedKeyBody,
                    addedLeadingNewline: pending.authorizedKeyAddedLeadingNewline
                ))
            }
            return items
        }

        var effectiveManagedHostAlias: String? {
            managedHostAlias ?? pendingTransaction?.plannedHostAlias
        }

        var allTrackedMimiConfigVersions: [FileVersionFingerprint] {
            var versions: [FileVersionFingerprint] = []
            func appendUnique(_ ver: FileVersionFingerprint?) {
                guard let ver, !versions.contains(ver) else { return }
                versions.append(ver)
            }
            appendUnique(mimiConfigVersion)
            for ver in additionalMimiConfigVersions { appendUnique(ver) }
            appendUnique(pendingTransaction?.plannedMimiConfigVersion)
            return versions
        }

        var effectiveMimiConfigVersion: FileVersionFingerprint? {
            allTrackedMimiConfigVersions.first
        }

        var allTrackedKnownHostsVersions: [FileVersionFingerprint] {
            var versions: [FileVersionFingerprint] = []
            func appendUnique(_ ver: FileVersionFingerprint?) {
                guard let ver, !versions.contains(ver) else { return }
                versions.append(ver)
            }
            appendUnique(knownHostsVersion)
            for ver in additionalKnownHostsVersions { appendUnique(ver) }
            appendUnique(pendingTransaction?.plannedKnownHostsVersion)
            return versions
        }

        var effectiveKnownHostsVersion: FileVersionFingerprint? {
            allTrackedKnownHostsVersions.first
        }

        var allTrackedStagedKeyDirectories: [String] {
            var dirs = stagedKeyDirectories
            if let pendingDir = pendingTransaction?.stagedKeyDirectoryName,
               !pendingDir.isEmpty,
               !dirs.contains(pendingDir) {
                dirs.append(pendingDir)
            }
            return dirs
        }

        var isEmpty: Bool {
            keyFingerprint == nil &&
                publicKeyBody == nil &&
                additionalKeyIdentities.isEmpty &&
                authorizedKeyEntry == nil &&
                authorizedKeyBody == nil &&
                additionalAuthorizedEntries.isEmpty &&
                residualAuthorizedKeyBodies.isEmpty &&
                managedHostAlias == nil &&
                mimiConfigVersion == nil &&
                additionalMimiConfigVersions.isEmpty &&
                !mimiConfigConflict &&
                !managedKnownHosts &&
                knownHostsVersion == nil &&
                additionalKnownHostsVersions.isEmpty &&
                !knownHostsConflict &&
                stagedKeyDirectories.isEmpty &&
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

        /// 只有无未完成事务、经 Mimi 归属核验、回环 `restrict,from=` 授权无冲突且多画像 `ssh -G` 确认直连当前用户 127.0.0.1:22 时才为 true。
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
                "SSH 目录或文件为符号链接、非常规文件或属主异常，已拒绝修改：\(detail)"
            case .concurrentModification(let detail):
                "写入前或原子替换瞬间检测到 SSH 配置文件被外部修改，已中止并保留外部版本：\(detail)"
            case .invalidManagedBlock:
                "~/.ssh/config 中的 Mimi 托管 Include 标记行不完整或重复，请先手工核对后再试。"
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

        var isMimiMarked: Bool {
            comment == CodexLocalSSHConfigurator.keyComment
        }

        func isValidMimiManagedEntry(expectedKeyBody: String) -> Bool {
            keyBody == expectedKeyBody &&
                hasRestrictOption &&
                isStrictlyLoopbackFrom &&
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
    /// 任一异常、冲突或中断事务均标为不就绪，并基于持久化记录保留撤销与重试入口。
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
            if state.pendingTransaction != nil || !state.stagedKeyDirectories.isEmpty {
                result.hasPendingTransaction = true
            }
            if state.knownHostsConflict || state.mimiConfigConflict {
                result.hasUnsafeFileSystemState = true
            }
        }

        var sshDirectorySafe = true
        do {
            if let info = try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh") {
                try ensureNotGroupOrWorldWritable(info, label: "~/.ssh", reason: "目录对组或其他用户可写。")
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
                try ensureNotGroupOrWorldWritable(info, label: "~/.ssh/mimi", reason: "目录对组或其他用户可写。")
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
                    let trackedKHVersions = state?.allTrackedKnownHostsVersions ?? []
                    if !trackedKHVersions.isEmpty {
                        if !trackedKHVersions.contains(where: { $0.matches(data: khSnap.data) }) {
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

        // 2. 独立三态探测并核验 ~/.ssh/mimi/ 内的密钥归属与公私钥匹配
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
                let trackedIdentities = state?.allTrackedKeyIdentities ?? []
                if !trackedIdentities.isEmpty {
                    if privateExists && publicExists {
                        var matched = false
                        for identity in trackedIdentities {
                            if await verifyOwnedKeyPair(expectedBody: identity.publicKeyBody, expectedFingerprint: identity.keyFingerprint) {
                                matched = true
                                break
                            }
                        }
                        if matched {
                            result.keyExists = true
                        } else {
                            result.hasConflictingKeyFiles = true
                        }
                    } else if privateExists || publicExists {
                        var singleOwned = false
                        for identity in trackedIdentities {
                            if await verifyPartialOwnedKey(
                                privateExists: privateExists,
                                publicExists: publicExists,
                                expectedBody: identity.publicKeyBody,
                                expectedFingerprint: identity.keyFingerprint
                            ) {
                                singleOwned = true
                                break
                            }
                        }
                        if singleOwned {
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

        // 3. 独立三态探测并核验 authorized_keys（含 StrictModes 权限检查与共用按公钥残留检查）
        do {
            let authSnapshot = try captureSnapshot(of: authorizedKeysURL, label: "authorized_keys")
            if authSnapshot.exists {
                if let info = authSnapshot.info {
                    try ensureNotGroupOrWorldWritable(info, label: "~/.ssh/authorized_keys", reason: "文件对组或其他用户可写。")
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
                            recordedEntry: state.authorizedKeyEntry ?? state.pendingTransaction?.plannedAuthorizedKeyEntry
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

        // 4. 独立三态探测并核验 ~/.ssh/config 单行 Include、~/.ssh/mimi/config 与多画像 ssh -G 有效目标
        do {
            let configSnapshot = try captureSnapshot(of: sshConfigURL, label: "config")
            if configSnapshot.exists, let info = configSnapshot.info {
                try ensureNotGroupOrWorldWritable(info, label: "~/.ssh/config", reason: "文件对组或其他用户可写。")
            }
            let mimiConfigSnap = mimiDirSafe && mimiDirExists
                ? try captureSnapshot(of: mimiConfigURL, label: "~/.ssh/mimi/config")
                : .missing
            let trackedMimiVersions = state?.allTrackedMimiConfigVersions ?? []
            if mimiConfigSnap.exists, !trackedMimiVersions.isEmpty, !trackedMimiVersions.contains(where: { $0.matches(data: mimiConfigSnap.data) }) {
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
                                checkRealDesktopPath: isDefaultUserHome && systemSSHConfigPath == "/etc/ssh/ssh_config",
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

    /// 一键配置本机回环 SSH 并验证免密连通（隔离目录、预写事务意图、原子 CAS 替换、隔离验连、失败回滚）。
    func configure(verifyConnection: Bool = true) async throws {
        try await withSerializedLock {
            try await configureLocked(verifyConnection: verifyConnection)
        }
    }

    /// 撤销由 Mimi 写入的本机 SSH 托管授权、`~/.ssh/mimi/` 专用密钥/配置/信任文件与 `~/.ssh/config` 顶部单行 `Include`。
    /// 仅在资源确证缺失或经归属/版本核验清理后才清除对应状态字段，任何冲突或外部修改均保留原文件与重试入口。
    func remove() async throws {
        try await withSerializedLock {
            try await removeLocked()
        }
    }

    // MARK: - Serialized State Machine Implementations

    private func configureLocked(verifyConnection: Bool) async throws {
        // =========================================================================
        // Phase 0 · Preflight（纯只读探测、归属与版本核验、残余授权核查、多画像 ssh -G 校验，零磁盘写入）
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
                reason: "为避免收紧权限后激活原本被 StrictModes 拒绝的授权或采纳不安全配置，已拒绝采纳，请先手工修复权限。"
            )
        }
        try validateMimiDirectoryAndFiles()
        if let mimiDirInfo = try validateDirectoryIfPresent(mimiSSHDirectory, label: "~/.ssh/mimi") {
            try ensureNotGroupOrWorldWritable(
                mimiDirInfo,
                label: "~/.ssh/mimi",
                reason: "请先手工修复 ~/.ssh/mimi 权限后再试。"
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
                reason: "OpenSSH 会拒绝组或其他用户可写的配置文件，已拒绝复制到快照进行评估或修改。"
            )
        }
        if authSnapshot.exists, let info = authSnapshot.info {
            try ensureNotGroupOrWorldWritable(
                info,
                label: "~/.ssh/authorized_keys",
                reason: "为避免收紧权限后激活原本被 StrictModes 拒绝的授权，已拒绝采纳，请先手工核对并修复权限。"
            )
        }

        // 若上次存在未解冲突或 ~/.ssh/mimi/ 内的 config/known_hosts 与 Mimi 归属版本不匹配，拒绝盲目覆盖。
        if mimiConfigSnapshot.exists {
            if previousState?.mimiConfigConflict == true {
                throw ConfigError.conflictingKeyFiles("~/.ssh/mimi/config 存在待核对的外部修改冲突，请先手工核对或移除。")
            }
            let trackedMimiVersions = previousState?.allTrackedMimiConfigVersions ?? []
            guard trackedMimiVersions.contains(where: { $0.matches(data: mimiConfigSnapshot.data) }) else {
                throw ConfigError.conflictingKeyFiles("~/.ssh/mimi/config 已存在且与 Mimi 记录版本不一致，已停止以免覆盖外部改动。")
            }
        }
        if initialKnownHostsSnapshot.exists {
            if previousState?.knownHostsConflict == true {
                throw ConfigError.conflictingKeyFiles("~/.ssh/mimi/\(Self.knownHostsFileName) 存在待核对的外部替换/更新冲突，请先手工核对或移除。")
            }
            let trackedKHVersions = previousState?.allTrackedKnownHostsVersions ?? []
            guard trackedKHVersions.contains(where: { $0.matches(data: initialKnownHostsSnapshot.data) }) else {
                throw ConfigError.conflictingKeyFiles("~/.ssh/mimi/\(Self.knownHostsFileName) 已存在且与 Mimi 记录版本不一致，已停止以免覆盖外部文件。")
            }
        }

        let existingConfigText = try decodeUTF8(configSnapshot.data, label: "~/.ssh/config")
        let strippedConfig = try Self.stripManagedIncludeLine(from: existingConfigText)
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

        let keyPlan = try await planKeyPair(existingState: previousState)

        let existingAuthText = try decodeUTF8(authSnapshot.data, label: "~/.ssh/authorized_keys")
        try preflightCheckAuthorizedKeys(
            existingAuthText: existingAuthText,
            keyPlan: keyPlan,
            previousState: previousState
        )

        // =========================================================================
        // Phase 1 · Register Staging Artifact, Generate Key & Persist Write-Ahead Intent (WAL)
        // 密钥生成前先将暂存目录名写入状态账本，并在发布前写入完整事务意图，确保进程在任意时刻被终止均无孤儿私钥或授权。
        // =========================================================================
        let createdSSHDirectory = try ensureSSHDirectory()
        let createdMimiDirectory = try ensureMimiSSHDirectory()
        try ensureStateDirectory()

        var stagedKeyBundle: StagedKeyPairBundle?
        var trackedStagingDirName: String?
        switch keyPlan.action {
        case .reuseExisting, .reconstructPublicKey:
            break
        case .regenerateAfterRemovingOwnedPublicKey, .generateFresh:
            let dirName = "\(Self.keyStagingDirectoryPrefix)\(UUID().uuidString)"
            trackedStagingDirName = dirName
            var preStageState = previousState ?? ManagedState()
            if !preStageState.stagedKeyDirectories.contains(dirName) {
                preStageState.stagedKeyDirectories.append(dirName)
            }
            try saveManagedState(preStageState, invokeHook: false)
            do {
                stagedKeyBundle = try await stageFreshKeyPair(directoryName: dirName)
            } catch {
                let cleaned = cleanupStagedKeyDirectory(named: dirName)
                if cleaned {
                    if let prev = previousState {
                        try? saveManagedState(prev, invokeHook: false)
                    } else {
                        try? removeRegularFileIfPresent(stateFileURL, label: stateFileURL.lastPathComponent)
                    }
                }
                if createdMimiDirectory {
                    removeDirectoryIfEmpty(mimiSSHDirectory, label: "~/.ssh/mimi")
                }
                throw error
            }
        }

        let plannedKeyBody: String
        let plannedKeyFingerprint: String
        switch keyPlan.action {
        case .reuseExisting(let body, let fp), .reconstructPublicKey(let body, let fp):
            plannedKeyBody = body
            plannedKeyFingerprint = fp
        case .regenerateAfterRemovingOwnedPublicKey, .generateFresh:
            guard let stagedKeyBundle else {
                throw ConfigError.keyGenerationFailed("未能准备临时密钥材料。")
            }
            plannedKeyBody = stagedKeyBundle.publicKeyBody
            plannedKeyFingerprint = stagedKeyBundle.fingerprint
        }

        let plannedAuthEntry = Self.formatManagedAuthorizedKeyEntry(publicKeyBody: plannedKeyBody)
        let plannedMimiConfigData = Data(candidateMimiConfigText.utf8)
        let plannedMimiConfigVersion = FileVersionFingerprint.from(data: plannedMimiConfigData)
        let plannedAuthAddedLeadingNewline = !existingAuthText.isEmpty && existingAuthText.utf8.last != 0x0A

        var intentState = previousState ?? ManagedState()
        if let dirName = trackedStagingDirName, !intentState.stagedKeyDirectories.contains(dirName) {
            intentState.stagedKeyDirectories.append(dirName)
        }
        intentState.pendingTransaction = PendingTransaction(
            transactionID: UUID().uuidString,
            keyFingerprint: plannedKeyFingerprint,
            publicKeyBody: plannedKeyBody,
            plannedAuthorizedKeyEntry: plannedAuthEntry,
            plannedAuthorizedKeyBody: plannedKeyBody,
            authorizedKeyAddedLeadingNewline: plannedAuthAddedLeadingNewline,
            plannedHostAlias: Self.hostAlias,
            plannedUsername: trimmedUser,
            plannedMimiConfigVersion: plannedMimiConfigVersion,
            plannedKnownHostsVersion: nil,
            stagedKeyDirectoryName: trackedStagingDirName
        )
        // 预写 WAL：从此行之后任意时刻进程被强杀，重启均可通过 stateFileURL 精准撤销，不留孤儿授权或暂存私钥。
        try saveManagedState(intentState, invokeHook: false)

        // =========================================================================
        // Phase 2 · Atomic Commit（逐项记录精确前后快照到 RollbackRecord）
        // =========================================================================
        var rollback = RollbackRecord(
            previousState: previousState,
            createdSSHDirectory: createdSSHDirectory,
            createdMimiDirectory: createdMimiDirectory
        )

        do {
            let keyMaterial = try materializeKeyPair(plan: keyPlan, stagedBundle: stagedKeyBundle, rollback: &rollback)

            // 2a. 写入 ~/.ssh/mimi/config（0600，CAS 原子替换）
            let existingMimiConfigText = try decodeUTF8(mimiConfigSnapshot.data, label: "~/.ssh/mimi/config")
            if candidateMimiConfigText != existingMimiConfigText || !mimiConfigSnapshot.exists {
                let targetMode = Self.tightenedFileMode(existing: mimiConfigSnapshot.mode, maxMode: 0o600)
                let writtenMimiSnapshot = try writeFileAtomically(
                    plannedMimiConfigData,
                    to: mimiConfigURL,
                    mode: targetMode,
                    expectedSnapshot: mimiConfigSnapshot,
                    label: "~/.ssh/mimi/config"
                )
                rollback.wroteMimiConfig = true
                rollback.originalMimiConfigSnapshot = mimiConfigSnapshot
                rollback.writtenMimiConfigSnapshot = writtenMimiSnapshot
            } else {
                try tightenExistingFileIfNeeded(mimiConfigURL, currentMode: mimiConfigSnapshot.mode, maxMode: 0o600)
            }

            // 2b. 仅在 ~/.ssh/config 最顶部写入单行带标记 Include（绝不改写用户原有行）
            let configTargetMode = Self.tightenedFileMode(existing: configSnapshot.mode, maxMode: 0o600)
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
            } else if configSnapshot.exists {
                try tightenExistingFileIfNeeded(sshConfigURL, currentMode: configSnapshot.mode, maxMode: 0o600)
            }

            // 2c. 重新核验 authorized_keys 快照后单次原子写入（仅追加带标记 restrict,from= 行，轮换时仅移除旧标记行）
            let latestAuthSnapshot = try captureSnapshot(of: authorizedKeysURL, label: "~/.ssh/authorized_keys")
            try verifySnapshotUnchanged(authSnapshot, current: latestAuthSnapshot, label: "~/.ssh/authorized_keys")
            if latestAuthSnapshot.exists, let info = latestAuthSnapshot.info {
                try ensureNotGroupOrWorldWritable(
                    info,
                    label: "~/.ssh/authorized_keys",
                    reason: "为避免收紧权限后激活原本被 StrictModes 拒绝的授权，已拒绝采纳，请先手工核对并修复权限。"
                )
            }
            let latestAuthText = try decodeUTF8(latestAuthSnapshot.data, label: "~/.ssh/authorized_keys")
            let authEvaluation = Self.evaluateAuthorizedKeys(
                content: latestAuthText,
                keyBody: keyMaterial.publicKeyBody,
                recordedEntry: previousState?.authorizedKeyEntry ?? previousState?.pendingTransaction?.plannedAuthorizedKeyEntry
            )
            if let conflictReason = authEvaluation.conflictReason {
                throw ConfigError.conflictingAuthorizedKey(conflictReason)
            }

            var nextState = previousState ?? ManagedState()
            nextState.pendingTransaction = nil
            nextState.keyFingerprint = keyMaterial.fingerprint
            nextState.publicKeyBody = keyMaterial.publicKeyBody
            nextState.additionalKeyIdentities = []
            nextState.additionalAuthorizedEntries = []
            nextState.managedHostAlias = Self.hostAlias
            nextState.managedUsername = trimmedUser
            nextState.mimiConfigVersion = plannedMimiConfigVersion
            nextState.additionalMimiConfigVersions = []
            nextState.mimiConfigConflict = false
            nextState.managedKnownHosts = initialKnownHostsSnapshot.exists || (previousState?.managedKnownHosts ?? false)
            nextState.knownHostsVersion = previousState?.effectiveKnownHostsVersion
            nextState.additionalKnownHostsVersions = []
            nextState.knownHostsConflict = false
            nextState.residualAuthorizedKeyBodies = []

            var workingAuthText = latestAuthText
            var addedEntry: String?
            var addedLeadingNewline = false

            if !authEvaluation.hasExactMimiEntry {
                let composed = Self.appendAuthorizedKeyEntry(plannedAuthEntry, to: workingAuthText)
                workingAuthText = composed.text
                addedEntry = plannedAuthEntry
                addedLeadingNewline = composed.addedLeadingNewline
                nextState.authorizedKeyEntry = plannedAuthEntry
                nextState.authorizedKeyBody = keyMaterial.publicKeyBody
                nextState.authorizedKeyAddedLeadingNewline = composed.addedLeadingNewline
            } else {
                nextState.authorizedKeyEntry = plannedAuthEntry
                nextState.authorizedKeyBody = keyMaterial.publicKeyBody
                nextState.authorizedKeyAddedLeadingNewline = previousState?.authorizedKeyAddedLeadingNewline ?? false
            }

            var removedPreviousAuthEntry: String?
            if keyPlan.shouldRemovePreviousAuthorizedEntry, let prev = previousState {
                for tracked in prev.allTrackedAuthorizedEntries where tracked.keyBody != keyMaterial.publicKeyBody {
                    let cleaned = Self.removeExactAuthorizedKeyEntry(
                        tracked.entry,
                        expectedKeyBody: tracked.keyBody,
                        addedLeadingNewline: tracked.addedLeadingNewline,
                        from: workingAuthText
                    )
                    if cleaned.removed {
                        workingAuthText = cleaned.text
                        removedPreviousAuthEntry = tracked.entry
                    }
                }
                let oldBodies = prev.allTrackedAuthorizedKeyBodies.filter { $0 != keyMaterial.publicKeyBody }
                let residualOld = Self.findResidualAuthorizedKeyBodies(oldBodies, in: workingAuthText)
                if !residualOld.isEmpty {
                    throw ConfigError.conflictingAuthorizedKey("无法安全轮换密钥：~/.ssh/authorized_keys 中旧密钥仍存在非 Mimi 标记授权行，已保留旧记录未覆盖。")
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
                rollback.originalAuthSnapshot = latestAuthSnapshot
                rollback.writtenAuthSnapshot = writtenAuthSnapshot
                rollback.addedAuthorizedKeyEntry = addedEntry
                rollback.addedAuthorizedKeyBody = addedEntry != nil ? keyMaterial.publicKeyBody : nil
                rollback.addedAuthorizedKeyLeadingNewline = addedLeadingNewline
                rollback.removedPreviousAuthorizedEntry = removedPreviousAuthEntry
            } else if latestAuthSnapshot.exists {
                try tightenExistingFileIfNeeded(authorizedKeysURL, currentMode: latestAuthSnapshot.mode, maxMode: 0o600)
            }

            if simulateHardCrashPoint == .afterAuthorizedKeysCommit {
                throw SimulatedHardCrashError(point: .afterAuthorizedKeysCommit)
            }

            // =========================================================================
            // Phase 3 · Isolated Verification（冻结快照 + 事务内 known_hosts 副本 + 非空登记核验）
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
                    initialSnapshot: initialKnownHostsSnapshot,
                    rollback: &rollback
                )
                nextState.managedKnownHosts = true
                nextState.knownHostsVersion = plannedKHVersion
                nextState.knownHostsConflict = false

                if simulateHardCrashPoint == .afterKnownHostsCommit {
                    throw SimulatedHardCrashError(point: .afterKnownHostsCommit)
                }
            } else if initialKnownHostsSnapshot.exists {
                let currentKH = try captureSnapshot(of: knownHostsURL, label: "~/.ssh/mimi/\(Self.knownHostsFileName)")
                try verifySnapshotUnchanged(initialKnownHostsSnapshot, current: currentKH, label: "~/.ssh/mimi/\(Self.knownHostsFileName)")
                try tightenExistingFileIfNeeded(knownHostsURL, currentMode: currentKH.mode, maxMode: 0o600)
                nextState.managedKnownHosts = true
                nextState.knownHostsVersion = FileVersionFingerprint.from(data: currentKH.data)
                nextState.knownHostsConflict = false
            }

            // 确认清理本次及历史遗留的密钥暂存目录，仅对确认删除的条目销账。
            var allTrackedStagingDirs = nextState.allTrackedStagedKeyDirectories
            if let dirName = trackedStagingDirName, !allTrackedStagingDirs.contains(dirName) {
                allTrackedStagingDirs.append(dirName)
            }
            nextState.stagedKeyDirectories = allTrackedStagingDirs.filter { !cleanupStagedKeyDirectory(named: $0) }

            try saveManagedState(nextState, invokeHook: true)
        } catch let crash as SimulatedHardCrashError {
            // 仅测试崩溃模拟：跳过内存回滚与暂存清理，直接模拟进程被 SIGKILL 终止后的落盘现场。
            throw crash
        } catch {
            if let dirName = trackedStagingDirName, !cleanupStagedKeyDirectory(named: dirName) {
                rollback.residualStagedKeyDirectories.append(dirName)
            }
            let rollbackOutcome = await performRollback(rollback)
            if !rollbackOutcome.fullyRolledBack {
                let baseMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let detail = rollbackOutcome.detail ?? "部分已写入项未能自动回滚，请点击「移除本机 SSH 配置」清理。"
                throw ConfigError.fileOperationFailed("\(baseMessage)（\(detail)）")
            }
            throw error
        }
    }

    private func preflightCheckAuthorizedKeys(
        existingAuthText: String,
        keyPlan: KeyPlan,
        previousState: ManagedState?
    ) throws {
        if let prev = previousState {
            let existingResiduals = Self.findResidualAuthorizedKeyBodies(prev.residualAuthorizedKeyBodies, in: existingAuthText)
            if !existingResiduals.isEmpty {
                throw ConfigError.conflictingAuthorizedKey(
                    "~/.ssh/authorized_keys 中仍存在历史残留同公钥授权行，请先手工核对或移除后再重新配置。"
                )
            }
            if keyPlan.shouldRemovePreviousAuthorizedEntry {
                var simulated = existingAuthText
                for tracked in prev.allTrackedAuthorizedEntries {
                    let cleaned = Self.removeExactAuthorizedKeyEntry(
                        tracked.entry,
                        expectedKeyBody: tracked.keyBody,
                        addedLeadingNewline: tracked.addedLeadingNewline,
                        from: simulated
                    )
                    if cleaned.removed {
                        simulated = cleaned.text
                    }
                }
                let remainingOld = Self.findResidualAuthorizedKeyBodies(prev.allTrackedAuthorizedKeyBodies, in: simulated)
                if !remainingOld.isEmpty {
                    throw ConfigError.conflictingAuthorizedKey(
                        "无法轮换密钥：~/.ssh/authorized_keys 中原有 Mimi 公钥的授权行已被外部修改或存在其他同公钥行，已保留记录未丢弃。"
                    )
                }
            }
        }
        if let existingKeyBody = keyPlan.existingKeyBody {
            let evaluation = Self.evaluateAuthorizedKeys(
                content: existingAuthText,
                keyBody: existingKeyBody,
                recordedEntry: previousState?.authorizedKeyEntry ?? previousState?.pendingTransaction?.plannedAuthorizedKeyEntry
            )
            if let conflictReason = evaluation.conflictReason {
                throw ConfigError.conflictingAuthorizedKey(conflictReason)
            }
        }
    }

    private func commitKnownHostsTransactionalResult(
        desiredData: Data,
        initialSnapshot: FileSnapshot,
        rollback: inout RollbackRecord
    ) throws {
        guard Self.containsValidKnownHostEntry(in: desiredData, expectedHostAlias: Self.hostAlias) else {
            throw ConfigError.verificationFailed("独立主机信任文件内容为空或缺少 \(Self.hostAlias) 的有效主机公钥，已拒绝提交。")
        }
        _ = try ensureMimiSSHDirectory()
        try validateRegularFileIfPresent(knownHostsURL, label: "~/.ssh/mimi/\(Self.knownHostsFileName)")

        if !initialSnapshot.exists {
            let writtenSnapshot = try publishExclusiveNewFile(
                desiredData,
                to: knownHostsURL,
                mode: 0o600,
                label: "~/.ssh/mimi/\(Self.knownHostsFileName)",
                invokeHook: true,
                reportExistAsConcurrentModification: true
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
                label: "~/.ssh/mimi/\(Self.knownHostsFileName)",
                invokeHook: true
            )
            rollback.knownHostsMutation = .updated(originalSnapshot: initialSnapshot, writtenSnapshot: writtenSnapshot)
            return
        }

        let currentKH = try captureSnapshot(of: knownHostsURL, label: "~/.ssh/mimi/\(Self.knownHostsFileName)")
        try verifySnapshotUnchanged(initialSnapshot, current: currentKH, label: "~/.ssh/mimi/\(Self.knownHostsFileName)")
        try tightenExistingFileIfNeeded(knownHostsURL, currentMode: currentKH.mode, maxMode: 0o600)
    }

    private func removeLocked() async throws {
        // 先独立校验并读取状态文件，不被 ~/.ssh/mimi 异常阻断授权撤销。
        try validateStateDirectoryAndStateFile()

        var state = (try loadManagedState()) ?? ManagedState()
        // 将任何中断的 WAL 意图完整合并为待清理目标（同时保留新旧两代密钥身份、精确授权行、版本指纹与暂存目录，直至核验清理完成）。
        if let pending = state.pendingTransaction {
            if state.keyFingerprint == nil || state.publicKeyBody == nil {
                state.keyFingerprint = pending.keyFingerprint
                state.publicKeyBody = pending.publicKeyBody
            } else if state.keyFingerprint != pending.keyFingerprint || state.publicKeyBody != pending.publicKeyBody {
                let replacementIdentity = TrackedKeyIdentity(
                    keyFingerprint: pending.keyFingerprint,
                    publicKeyBody: pending.publicKeyBody
                )
                if !state.additionalKeyIdentities.contains(replacementIdentity) {
                    state.additionalKeyIdentities.append(replacementIdentity)
                }
            }
            if state.authorizedKeyEntry == nil {
                state.authorizedKeyEntry = pending.plannedAuthorizedKeyEntry
                state.authorizedKeyBody = pending.plannedAuthorizedKeyBody
                state.authorizedKeyAddedLeadingNewline = pending.authorizedKeyAddedLeadingNewline
            } else if state.authorizedKeyEntry != pending.plannedAuthorizedKeyEntry ||
                        state.authorizedKeyBody != pending.plannedAuthorizedKeyBody {
                let replacementEntry = TrackedAuthorizedEntry(
                    entry: pending.plannedAuthorizedKeyEntry,
                    keyBody: pending.plannedAuthorizedKeyBody,
                    addedLeadingNewline: pending.authorizedKeyAddedLeadingNewline
                )
                if !state.additionalAuthorizedEntries.contains(where: { $0.entry == replacementEntry.entry && $0.keyBody == replacementEntry.keyBody }) {
                    state.additionalAuthorizedEntries.append(replacementEntry)
                }
            }
            if state.managedHostAlias == nil {
                state.managedHostAlias = pending.plannedHostAlias
                state.managedUsername = pending.plannedUsername
            }
            if let plannedMimiVer = pending.plannedMimiConfigVersion {
                if state.mimiConfigVersion == nil {
                    state.mimiConfigVersion = plannedMimiVer
                } else if state.mimiConfigVersion != plannedMimiVer,
                          !state.additionalMimiConfigVersions.contains(plannedMimiVer) {
                    state.additionalMimiConfigVersions.append(plannedMimiVer)
                }
            }
            if let khVer = pending.plannedKnownHostsVersion {
                if state.knownHostsVersion == nil {
                    state.knownHostsVersion = khVer
                } else if state.knownHostsVersion != khVer,
                          !state.additionalKnownHostsVersions.contains(khVer) {
                    state.additionalKnownHostsVersions.append(khVer)
                }
                state.managedKnownHosts = true
            }
            if let stagedDir = pending.stagedKeyDirectoryName,
               !stagedDir.isEmpty,
               !state.stagedKeyDirectories.contains(stagedDir) {
                state.stagedKeyDirectories.append(stagedDir)
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
                    reason: "为避免收紧或操作不安全目录，请先手工核对并修复 ~/.ssh 权限。"
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
            // 1. 优先撤销 authorized_keys：仅删带 Mimi 标记的精确行（含轮换新旧精确条目），并共用按公钥检查残留逻辑。
            do {
                switch try probePath(authorizedKeysURL, label: "authorized_keys") {
                case .missing:
                    state.authorizedKeyEntry = nil
                    state.authorizedKeyBody = nil
                    state.authorizedKeyAddedLeadingNewline = false
                    state.additionalAuthorizedEntries = []
                    state.residualAuthorizedKeyBodies = []
                case .present:
                    try validateRegularFileIfPresent(authorizedKeysURL, label: "authorized_keys")
                    let trackedEntries = state.allTrackedAuthorizedEntries
                    let trackedBodies = state.allTrackedAuthorizedKeyBodies
                    if !trackedEntries.isEmpty || !trackedBodies.isEmpty {
                        let outcome = try removeTrackedAuthorizedEntries(
                            trackedEntries: trackedEntries,
                            trackedBodies: trackedBodies
                        )
                        if outcome.residualBodies.isEmpty {
                            state.authorizedKeyEntry = nil
                            state.authorizedKeyBody = nil
                            state.authorizedKeyAddedLeadingNewline = false
                            state.additionalAuthorizedEntries = []
                            state.residualAuthorizedKeyBodies = []
                        } else {
                            // 绝不丢失残留同公钥授权记录！
                            state.authorizedKeyEntry = nil
                            state.authorizedKeyAddedLeadingNewline = false
                            state.additionalAuthorizedEntries = state.additionalAuthorizedEntries.filter {
                                outcome.residualBodies.contains($0.keyBody)
                            }
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

            // 2. 检查 ~/.ssh/mimi 目录，独立安全清理密钥、已登记暂存目录、mimi/config 与 mimi/known_hosts
            var mimiDirSafe = true
            var mimiDirPresent = false
            do {
                switch try probePath(mimiSSHDirectory, label: "~/.ssh/mimi") {
                case .missing:
                    mimiDirPresent = false
                    state.keyFingerprint = nil
                    state.publicKeyBody = nil
                    state.additionalKeyIdentities = []
                    state.stagedKeyDirectories = []
                    state.mimiConfigVersion = nil
                    state.additionalMimiConfigVersions = []
                    state.mimiConfigConflict = false
                    state.managedKnownHosts = false
                    state.knownHostsVersion = nil
                    state.additionalKnownHostsVersions = []
                    state.knownHostsConflict = false
                case .present:
                    if let mimiDirInfo = try validateDirectoryIfPresent(mimiSSHDirectory, label: "~/.ssh/mimi") {
                        try ensureNotGroupOrWorldWritable(
                            mimiDirInfo,
                            label: "~/.ssh/mimi",
                            reason: "请先手工核对并修复 ~/.ssh/mimi 目录权限。"
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
                // 2a. 仅删除经指纹、公私钥匹配（支持轮换新旧身份）与隔离快照核验确属 Mimi 的专用密钥文件。
                do {
                    let removedKeys = try await removeOwnedKeyFilesIfVerified(state: state)
                    if removedKeys {
                        state.keyFingerprint = nil
                        state.publicKeyBody = nil
                        state.additionalKeyIdentities = []
                    }
                } catch let error as ConfigError {
                    errors.append(error)
                } catch {
                    errors.append(.fileOperationFailed(error.localizedDescription))
                }

                // 2b. 清理进程异常终止前登记在状态文件中的 `~/.ssh/mimi/.mimi-keygen-*` 暂存产物。
                if !state.stagedKeyDirectories.isEmpty {
                    var remainingStaged: [String] = []
                    for dirName in state.stagedKeyDirectories {
                        if !cleanupStagedKeyDirectory(named: dirName) {
                            remainingStaged.append(dirName)
                        }
                    }
                    state.stagedKeyDirectories = remainingStaged
                    if !remainingStaged.isEmpty {
                        errors.append(.fileOperationFailed("未能清理残留密钥暂存目录：\(remainingStaged.joined(separator: "、"))"))
                    }
                }
            }

            // 3. 仅移除 ~/.ssh/config 中的单行带标记 Include（绝不动其他行）。
            do {
                switch try probePath(sshConfigURL, label: "config") {
                case .missing:
                    state.managedHostAlias = nil
                    state.managedUsername = nil
                case .present:
                    try validateRegularFileIfPresent(sshConfigURL, label: "config")
                    let snapshot = try captureSnapshot(of: sshConfigURL, label: "~/.ssh/config")
                    let content = try decodeUTF8(snapshot.data, label: "~/.ssh/config")
                    let stripped = try Self.stripManagedIncludeLine(from: content)
                    if stripped.hadManagedInclude {
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

            if mimiDirSafe && mimiDirPresent {
                // 4. 按版本指纹核验并清理 ~/.ssh/mimi/config
                do {
                    try removeVersionVerifiedManagedFile(
                        at: mimiConfigURL,
                        label: "~/.ssh/mimi/config",
                        expectedVersions: state.allTrackedMimiConfigVersions,
                        hasConflictFlag: state.mimiConfigConflict
                    )
                    state.mimiConfigVersion = nil
                    state.additionalMimiConfigVersions = []
                    state.mimiConfigConflict = false
                } catch let error as ConfigError {
                    state.mimiConfigConflict = true
                    errors.append(error)
                } catch {
                    state.mimiConfigConflict = true
                    errors.append(.fileOperationFailed(error.localizedDescription))
                }

                // 5. 按版本指纹与冲突标记核验并清理 ~/.ssh/mimi/known_hosts（绝不删除外部替换或更新的同名文件）
                do {
                    try removeVersionVerifiedManagedFile(
                        at: knownHostsURL,
                        label: "~/.ssh/mimi/\(Self.knownHostsFileName)",
                        expectedVersions: state.allTrackedKnownHostsVersions,
                        hasConflictFlag: state.knownHostsConflict
                    )
                    state.managedKnownHosts = false
                    state.knownHostsVersion = nil
                    state.additionalKnownHostsVersions = []
                    state.knownHostsConflict = false
                } catch let error as ConfigError {
                    state.managedKnownHosts = true
                    state.knownHostsConflict = true
                    errors.append(error)
                } catch {
                    state.managedKnownHosts = true
                    state.knownHostsConflict = true
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
        expectedVersions: [FileVersionFingerprint],
        hasConflictFlag: Bool
    ) throws {
        switch try probePath(url, label: label) {
        case .missing:
            return
        case .present:
            try validateRegularFileIfPresent(url, label: label)
            let snapshot = try captureSnapshot(of: url, label: label)
            guard snapshot.exists else { return }
            guard !hasConflictFlag,
                  expectedVersions.contains(where: { $0.matches(data: snapshot.data) }) else {
                throw ConfigError.conflictingKeyFiles(
                    "\(label) 已被外部修改、替换或缺少已证实的 Mimi 版本归属记录，撤销时已保留未删除，请手工核对。"
                )
            }
            try removeFileMatchingSnapshot(url, expectedSnapshot: snapshot, label: label, invokeHook: true)
        }
    }
}
