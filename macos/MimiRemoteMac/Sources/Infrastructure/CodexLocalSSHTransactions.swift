import Darwin
import Foundation

extension CodexLocalSSHConfigurator {
    // MARK: - Key Ownership, Staging & Generation

    enum KeyPlanAction {
        case reuseExisting(body: String, fingerprint: String)
        case reconstructPublicKey(body: String, fingerprint: String)
        case regenerateAfterRemovingOwnedPublicKey(verifiedPublicKeySnapshot: FileSnapshot)
        case generateFresh
    }

    struct KeyPlan {
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

    struct KeyMaterial {
        let publicKeyBody: String
        let fingerprint: String
    }

    struct StagedKeyPairBundle {
        let stagingDir: URL
        let privateKeyURL: URL
        let publicKeyURL: URL
        let privateSnapshot: FileSnapshot
        let publicSnapshot: FileSnapshot
        let publicKeyBody: String
        let fingerprint: String

        func cleanup() {
            _ = Darwin.unlink(privateKeyURL.path)
            _ = Darwin.unlink(publicKeyURL.path)
            _ = Darwin.rmdir(stagingDir.path)
        }
    }

    func planKeyPair(existingState: ManagedState?) async throws -> KeyPlan {
        let hasPrivate = try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName) != nil
        let hasPublic = try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub") != nil

        guard hasPrivate || hasPublic else {
            return KeyPlan(
                action: .generateFresh,
                shouldRemovePreviousAuthorizedEntry: !(existingState?.allTrackedAuthorizedKeyBodies.isEmpty ?? true)
            )
        }

        let trackedIdentities = existingState?.allTrackedKeyIdentities ?? []
        guard !trackedIdentities.isEmpty else {
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
            for identity in trackedIdentities {
                if await verifyOwnedKeyPair(expectedBody: identity.publicKeyBody, expectedFingerprint: identity.keyFingerprint) {
                    let hasOtherAuthBody = (existingState?.allTrackedAuthorizedKeyBodies ?? []).contains { $0 != identity.publicKeyBody }
                    return KeyPlan(
                        action: .reuseExisting(body: identity.publicKeyBody, fingerprint: identity.keyFingerprint),
                        shouldRemovePreviousAuthorizedEntry: hasOtherAuthBody
                    )
                }
            }
            throw ConfigError.conflictingKeyFiles("\(Self.keyFileName) 的公钥指纹或公私钥匹配关系与 Mimi 记录不一致。")
        }

        if hasPrivate && !hasPublic {
            if let derived = await derivePublicKeyBodyFromPrivateKey(),
               let derivedFP = Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: derived),
               let matched = trackedIdentities.first(where: { $0.publicKeyBody == derived && $0.keyFingerprint == derivedFP }) {
                let hasOtherAuthBody = (existingState?.allTrackedAuthorizedKeyBodies ?? []).contains { $0 != matched.publicKeyBody }
                return KeyPlan(
                    action: .reconstructPublicKey(body: matched.publicKeyBody, fingerprint: matched.keyFingerprint),
                    shouldRemovePreviousAuthorizedEntry: hasOtherAuthBody
                )
            }
            throw ConfigError.conflictingKeyFiles("仅存在私钥 \(Self.keyFileName)，且与 Mimi 记录的密钥指纹不一致。")
        }

        let pubSnapshot = try captureSnapshot(of: publicKeyURL, label: "\(Self.keyFileName).pub")
        guard pubSnapshot.exists,
              let rawPub = String(data: pubSnapshot.data, encoding: .utf8),
              let existingPubBody = Self.extractPublicKeyBody(from: rawPub.trimmingCharacters(in: .whitespacesAndNewlines)),
              let existingFP = Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: existingPubBody),
              trackedIdentities.contains(where: { $0.publicKeyBody == existingPubBody && $0.keyFingerprint == existingFP }) else {
            throw ConfigError.conflictingKeyFiles("仅存在公钥 \(Self.keyFileName).pub，且与 Mimi 记录的密钥指纹不一致。")
        }
        return KeyPlan(
            action: .regenerateAfterRemovingOwnedPublicKey(verifiedPublicKeySnapshot: pubSnapshot),
            shouldRemovePreviousAuthorizedEntry: true
        )
    }

    /// 在 `~/.ssh/mimi/` 内的预登记独占临时目录（`0700`）预生成并校验密钥对（`0600`），供 WAL 先持久化指纹后再无覆盖发布。
    func stageFreshKeyPair(directoryName: String) async throws -> StagedKeyPairBundle {
        guard Self.isValidStagedKeyDirectoryName(directoryName) else {
            throw ConfigError.unsafeFileSystemTarget("非法的密钥暂存目录名称。")
        }
        let stagingDir = mimiSSHDirectory.appendingPathComponent(directoryName, isDirectory: true)
        guard Darwin.mkdir(stagingDir.path, 0o700) == 0 else {
            throw ConfigError.fileOperationFailed("无法创建独占密钥临时目录：\(Self.posixErrorMessage())")
        }
        let stagingPrivateURL = stagingDir.appendingPathComponent(Self.keyFileName)
        let stagingPublicURL = stagingDir.appendingPathComponent("\(Self.keyFileName).pub")
        var succeeded = false
        defer {
            if !succeeded {
                _ = cleanupStagedKeyDirectory(named: directoryName)
            }
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

        // 所有 ~/.ssh/mimi/ 内文件统一收紧为 0600（与 BE-3 一致）。
        if let privInfo = try validateRegularFileIfPresent(stagingPrivateURL, label: Self.keyFileName) {
            try tightenExistingFileIfNeeded(stagingPrivateURL, currentMode: privInfo.permissions, maxMode: 0o600)
        }
        if let pubInfo = try validateRegularFileIfPresent(stagingPublicURL, label: "\(Self.keyFileName).pub") {
            try tightenExistingFileIfNeeded(stagingPublicURL, currentMode: pubInfo.permissions, maxMode: 0o600)
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

        succeeded = true
        return StagedKeyPairBundle(
            stagingDir: stagingDir,
            privateKeyURL: stagingPrivateURL,
            publicKeyURL: stagingPublicURL,
            privateSnapshot: stagedPrivateSnapshot,
            publicSnapshot: stagedPublicSnapshot,
            publicKeyBody: pubBody,
            fingerprint: fingerprint
        )
    }

    static func isValidStagedKeyDirectoryName(_ name: String) -> Bool {
        name.hasPrefix(keyStagingDirectoryPrefix) &&
            name.count > keyStagingDirectoryPrefix.count &&
            !name.contains("/") &&
            !name.contains("\\") &&
            !name.contains("..")
    }

    /// 安全清理 `~/.ssh/mimi/` 中已登记的密钥暂存目录（仅删除当前用户普通密钥暂存文件，再 `rmdir`）；返回 `true` 表示目录已确认不存在。
    func cleanupStagedKeyDirectory(named dirName: String) -> Bool {
        guard Self.isValidStagedKeyDirectoryName(dirName) else { return false }
        guard (try? validateDirectoryIfPresent(mimiSSHDirectory, label: "~/.ssh/mimi")) != nil else {
            var st = stat()
            return Darwin.lstat(mimiSSHDirectory.path, &st) != 0 && errno == ENOENT
        }
        let parentFD = Darwin.open(mimiSSHDirectory.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard parentFD >= 0 else {
            return errno == ENOENT
        }
        defer { Darwin.close(parentFD) }

        var parentSt = stat()
        guard Darwin.fstat(parentFD, &parentSt) == 0,
              (parentSt.st_mode & S_IFMT) == S_IFDIR,
              parentSt.st_uid == Darwin.geteuid() else {
            return false
        }

        let stageFD = Darwin.openat(parentFD, dirName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        if stageFD < 0 {
            return errno == ENOENT
        }

        var stageSt = stat()
        guard Darwin.fstat(stageFD, &stageSt) == 0,
              (stageSt.st_mode & S_IFMT) == S_IFDIR,
              stageSt.st_uid == Darwin.geteuid() else {
            Darwin.close(stageFD)
            return false
        }

        // 仅清理 Mimi 暂存的密钥文件名（含可能存在的私钥与公钥），绝不盲删未知文件。
        for fileName in [Self.keyFileName, "\(Self.keyFileName).pub"] {
            var fileSt = stat()
            if Darwin.fstatat(stageFD, fileName, &fileSt, AT_SYMLINK_NOFOLLOW) == 0 {
                guard (fileSt.st_mode & S_IFMT) == S_IFREG, fileSt.st_uid == Darwin.geteuid() else {
                    Darwin.close(stageFD)
                    return false
                }
                if Darwin.unlinkat(stageFD, fileName, 0) != 0 && errno != ENOENT {
                    Darwin.close(stageFD)
                    return false
                }
            } else if errno != ENOENT {
                Darwin.close(stageFD)
                return false
            }
        }
        Darwin.close(stageFD)

        if Darwin.unlinkat(parentFD, dirName, AT_REMOVEDIR) == 0 || errno == ENOENT {
            return true
        }
        return false
    }

    func materializeKeyPair(
        plan: KeyPlan,
        stagedBundle: StagedKeyPairBundle?,
        rollback: inout RollbackRecord
    ) throws -> KeyMaterial {
        switch plan.action {
        case .reuseExisting(let body, let fingerprint):
            if let privInfo = try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName) {
                try tightenExistingFileIfNeeded(privateKeyURL, currentMode: privInfo.permissions, maxMode: 0o600)
            }
            if let pubInfo = try validateRegularFileIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub") {
                try tightenExistingFileIfNeeded(publicKeyURL, currentMode: pubInfo.permissions, maxMode: 0o600)
            }
            return KeyMaterial(publicKeyBody: body, fingerprint: fingerprint)

        case .reconstructPublicKey(let body, let fingerprint):
            let pubContent = "\(body) \(Self.keyComment)\n"
            let publishedSnapshot = try publishExclusiveNewFile(
                Data(pubContent.utf8),
                to: publicKeyURL,
                mode: 0o600,
                label: "\(Self.keyFileName).pub"
            )
            rollback.createdPublicKey = true
            rollback.createdPublicKeySnapshot = publishedSnapshot
            rollback.generatedKeyBody = body
            rollback.generatedKeyFingerprint = fingerprint
            return KeyMaterial(publicKeyBody: body, fingerprint: fingerprint)

        case .regenerateAfterRemovingOwnedPublicKey(let verifiedPublicKeySnapshot):
            guard let stagedBundle else {
                throw ConfigError.keyGenerationFailed("缺少预生成的密钥材料。")
            }
            try removeFileMatchingSnapshot(
                publicKeyURL,
                expectedSnapshot: verifiedPublicKeySnapshot,
                label: "\(Self.keyFileName).pub",
                invokeHook: true
            )
            rollback.removedOwnedPublicKeyData = verifiedPublicKeySnapshot.data
            rollback.removedOwnedPublicKeyMode = verifiedPublicKeySnapshot.mode
            return try publishStagedKeyPairBundle(stagedBundle, rollback: &rollback)

        case .generateFresh:
            guard let stagedBundle else {
                throw ConfigError.keyGenerationFailed("缺少预生成的密钥材料。")
            }
            return try publishStagedKeyPairBundle(stagedBundle, rollback: &rollback)
        }
    }

    private func publishStagedKeyPairBundle(
        _ bundle: StagedKeyPairBundle,
        rollback: inout RollbackRecord
    ) throws -> KeyMaterial {
        let publishedPrivateSnapshot = try publishStagedKeyFile(
            from: bundle.privateKeyURL,
            stagedSnapshot: bundle.privateSnapshot,
            to: privateKeyURL,
            mode: 0o600,
            label: Self.keyFileName
        )
        rollback.createdPrivateKey = true
        rollback.createdPrivateKeySnapshot = publishedPrivateSnapshot
        rollback.generatedKeyBody = bundle.publicKeyBody
        rollback.generatedKeyFingerprint = bundle.fingerprint

        let publishedPublicSnapshot = try publishStagedKeyFile(
            from: bundle.publicKeyURL,
            stagedSnapshot: bundle.publicSnapshot,
            to: publicKeyURL,
            mode: 0o600,
            label: "\(Self.keyFileName).pub"
        )
        rollback.createdPublicKey = true
        rollback.createdPublicKeySnapshot = publishedPublicSnapshot

        return KeyMaterial(publicKeyBody: bundle.publicKeyBody, fingerprint: bundle.fingerprint)
    }

    func verifyOwnedKeyPair(expectedBody: String, expectedFingerprint: String) async -> Bool {
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

    func verifyPartialOwnedKey(
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

    func removeOwnedKeyFilesIfVerified(state: ManagedState) async throws -> Bool {
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

        let trackedIdentities = state.allTrackedKeyIdentities
        guard !trackedIdentities.isEmpty else {
            throw ConfigError.conflictingKeyFiles("存在未记录归属的同名密钥文件，撤销时已保留未删除。")
        }

        var mismatchDetails: [String] = []
        var preservedConflictMessages: [String] = []
        var verifiedPrivateSnapshot: FileSnapshot?
        var verifiedPublicSnapshot: FileSnapshot?

        if hasPrivate {
            try validateRegularFileIfPresent(privateKeyURL, label: Self.keyFileName)
            let snapshot = try captureSnapshot(of: privateKeyURL, label: Self.keyFileName)
            if snapshot.exists,
               let derived = await derivePublicKeyBody(fromPrivateKeySnapshot: snapshot),
               let derivedFP = Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: derived),
               trackedIdentities.contains(where: { $0.publicKeyBody == derived && $0.keyFingerprint == derivedFP }) {
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
               let pubFP = Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: pubBody),
               trackedIdentities.contains(where: { $0.publicKeyBody == pubBody && $0.keyFingerprint == pubFP }) {
                verifiedPublicSnapshot = snapshot
            } else {
                mismatchDetails.append("\(Self.keyFileName).pub")
            }
        }

        if let privSnapshot = verifiedPrivateSnapshot {
            do {
                try removeFileMatchingSnapshot(privateKeyURL, expectedSnapshot: privSnapshot, label: Self.keyFileName, invokeHook: true)
            } catch ConfigError.conflictingKeyFiles(let detail) {
                mismatchDetails.append(Self.keyFileName)
                preservedConflictMessages.append(detail)
            }
        }
        if let pubSnapshot = verifiedPublicSnapshot {
            do {
                try removeFileMatchingSnapshot(publicKeyURL, expectedSnapshot: pubSnapshot, label: "\(Self.keyFileName).pub", invokeHook: true)
            } catch ConfigError.conflictingKeyFiles(let detail) {
                mismatchDetails.append("\(Self.keyFileName).pub")
                preservedConflictMessages.append(detail)
            }
        }

        if !mismatchDetails.isEmpty {
            let extra = preservedConflictMessages.isEmpty ? "" : "（\(preservedConflictMessages.joined(separator: "；"))）"
            throw ConfigError.conflictingKeyFiles("密钥文件 \(mismatchDetails.joined(separator: "、")) 与 Mimi 记录的指纹不匹配或在删除前被替换，已保留未删除\(extra)。")
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
        var createdMimiDirectory: Bool = false
        var createdPrivateKey: Bool = false
        var createdPrivateKeySnapshot: FileSnapshot?
        var createdPublicKey: Bool = false
        var createdPublicKeySnapshot: FileSnapshot?
        var generatedKeyBody: String?
        var generatedKeyFingerprint: String?
        var removedOwnedPublicKeyData: Data?
        var removedOwnedPublicKeyMode: mode_t?
        var wroteMimiConfig: Bool = false
        var originalMimiConfigSnapshot: FileSnapshot = .missing
        var writtenMimiConfigSnapshot: FileSnapshot?
        var wroteSSHConfig: Bool = false
        var originalConfigSnapshot: FileSnapshot = .missing
        var originalHadManagedInclude: Bool = false
        var writtenConfigSnapshot: FileSnapshot?
        var writtenUsername: String?
        var wroteAuthorizedKeys: Bool = false
        var originalAuthSnapshot: FileSnapshot = .missing
        var writtenAuthSnapshot: FileSnapshot?
        var addedAuthorizedKeyEntry: String?
        var addedAuthorizedKeyBody: String?
        var addedAuthorizedKeyLeadingNewline: Bool = false
        var removedPreviousAuthorizedEntry: String?
        var knownHostsMutation: KnownHostsMutation = .unchanged
        var residualStagedKeyDirectories: [String] = []
    }

    struct RollbackOutcome {
        var fullyRolledBack: Bool = true
        var detail: String?
    }

    func performRollback(_ rollback: RollbackRecord) async -> RollbackOutcome {
        var failures: [String] = []
        var fallbackState = rollback.previousState ?? ManagedState()
        fallbackState.pendingTransaction = nil

        var residualAuthorizedEntry: String?
        var residualAuthBodies: [String] = []
        var residualConfigManaged = false
        var residualMimiConfigVersion: FileVersionFingerprint?
        var residualMimiConfigConflict = false
        var residualNewKeyManaged = false
        var residualKnownHostsVersion: FileVersionFingerprint?
        var residualKnownHostsConflict = false

        // 1. 回滚本次对 authorized_keys 的写入（外部已删除时绝不重建，仅在当前文件仍匹配本次写入时恢复原快照）
        if rollback.wroteAuthorizedKeys {
            var authReverted = false
            do {
                let snapshot = try captureSnapshot(of: authorizedKeysURL, label: "~/.ssh/authorized_keys")
                if !snapshot.exists {
                    // 外部进程已在 Mimi 写入后删除了 authorized_keys（例如吊销全部授权），必须保留该删除，绝不重建原文件！
                    authReverted = true
                } else if let writtenSnap = rollback.writtenAuthSnapshot, Self.snapshotsMatch(writtenSnap, snapshot) {
                    if !rollback.originalAuthSnapshot.exists {
                        try removeFileMatchingSnapshot(
                            authorizedKeysURL,
                            expectedSnapshot: writtenSnap,
                            label: "~/.ssh/authorized_keys",
                            invokeHook: false
                        )
                    } else {
                        _ = try writeFileAtomically(
                            rollback.originalAuthSnapshot.data,
                            to: authorizedKeysURL,
                            mode: rollback.originalAuthSnapshot.mode ?? 0o600,
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

                    let targetKeyBody = rollback.addedAuthorizedKeyBody ?? rollback.generatedKeyBody ?? rollback.previousState?.effectiveAuthorizedKeyBody
                    if let entry = rollback.addedAuthorizedKeyEntry, let keyBody = targetKeyBody {
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
                        _ = try writeFileAtomically(
                            Data(working.utf8),
                            to: authorizedKeysURL,
                            mode: mode,
                            expectedSnapshot: snapshot,
                            label: "~/.ssh/authorized_keys",
                            invokeHook: false
                        )
                    }

                    if let keyBody = targetKeyBody {
                        let residuals = Self.findResidualAuthorizedKeyBodies([keyBody], in: working)
                        if !residuals.isEmpty {
                            authReverted = false
                            residualAuthBodies.append(contentsOf: residuals)
                            failures.append("~/.ssh/authorized_keys 中本次新增公钥的授权行已被外部修改，未能自动撤销，已保留外部改动与撤销记录")
                        } else {
                            authReverted = true
                        }
                    } else {
                        authReverted = true
                    }
                }
            } catch {
                authReverted = false
                if let body = rollback.addedAuthorizedKeyBody ?? rollback.generatedKeyBody {
                    residualAuthBodies.append(body)
                }
                failures.append("未能自动回滚 ~/.ssh/authorized_keys（\(error.localizedDescription)）")
            }

            if !authReverted {
                residualAuthorizedEntry = rollback.addedAuthorizedKeyEntry
            }
        }

        // 2. 回滚本次对 ~/.ssh/config 单行 Include 的写入（外部已删除时绝不重建，仅在当前文件仍匹配本次写入时恢复原快照）
        if rollback.wroteSSHConfig {
            var configReverted = false
            do {
                let snapshot = try captureSnapshot(of: sshConfigURL, label: "~/.ssh/config")
                if !snapshot.exists {
                    // 外部进程已删除 ~/.ssh/config，保留外部删除，绝不重建！
                    configReverted = true
                } else if let writtenSnap = rollback.writtenConfigSnapshot, Self.snapshotsMatch(writtenSnap, snapshot) {
                    if !rollback.originalConfigSnapshot.exists {
                        try removeFileMatchingSnapshot(
                            sshConfigURL,
                            expectedSnapshot: writtenSnap,
                            label: "~/.ssh/config",
                            invokeHook: false
                        )
                    } else {
                        _ = try writeFileAtomically(
                            rollback.originalConfigSnapshot.data,
                            to: sshConfigURL,
                            mode: rollback.originalConfigSnapshot.mode ?? 0o600,
                            expectedSnapshot: writtenSnap,
                            label: "~/.ssh/config",
                            invokeHook: false
                        )
                    }
                    configReverted = true
                } else {
                    let text = try decodeUTF8(snapshot.data, label: "~/.ssh/config")
                    let currentStripped = try Self.stripManagedIncludeLine(from: text)
                    if rollback.originalHadManagedInclude {
                        configReverted = true
                    } else if currentStripped.hadManagedInclude {
                        if !rollback.originalConfigSnapshot.exists && currentStripped.remaining.isEmpty {
                            try removeFileMatchingSnapshot(
                                sshConfigURL,
                                expectedSnapshot: snapshot,
                                label: "~/.ssh/config",
                                invokeHook: false
                            )
                        } else {
                            let mode = rollback.originalConfigSnapshot.mode ?? Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
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
                    } else {
                        configReverted = true
                    }
                }
            } catch {
                configReverted = false
                failures.append("未能自动回滚 ~/.ssh/config（\(error.localizedDescription)）")
            }

            if !configReverted {
                residualConfigManaged = true
            }
        }

        // 3. 回滚 ~/.ssh/mimi/config（仅匹配本次写入快照时回滚；外部修改或替换则保全并记录冲突版本）
        if rollback.wroteMimiConfig, let writtenMimiSnap = rollback.writtenMimiConfigSnapshot {
            do {
                if !rollback.originalMimiConfigSnapshot.exists {
                    try removeFileMatchingSnapshot(
                        mimiConfigURL,
                        expectedSnapshot: writtenMimiSnap,
                        label: "~/.ssh/mimi/config",
                        invokeHook: false
                    )
                } else {
                    _ = try writeFileAtomically(
                        rollback.originalMimiConfigSnapshot.data,
                        to: mimiConfigURL,
                        mode: rollback.originalMimiConfigSnapshot.mode ?? 0o600,
                        expectedSnapshot: writtenMimiSnap,
                        label: "~/.ssh/mimi/config",
                        invokeHook: false
                    )
                }
            } catch {
                residualMimiConfigVersion = FileVersionFingerprint.from(data: writtenMimiSnap.data)
                residualMimiConfigConflict = true
                failures.append("未能自动回滚 ~/.ssh/mimi/config（\(error.localizedDescription)）")
            }
        }

        // 4. 回滚 ~/.ssh/mimi/known_hosts（仅匹配本次写入快照时回滚；若被外部替换或更新，保留冲突标记与 Mimi 已证实版本）
        switch rollback.knownHostsMutation {
        case .unchanged:
            break
        case .created(let writtenSnapshot):
            do {
                try removeFileMatchingSnapshot(
                    knownHostsURL,
                    expectedSnapshot: writtenSnapshot,
                    label: "~/.ssh/mimi/\(Self.knownHostsFileName)",
                    invokeHook: false
                )
            } catch {
                residualKnownHostsVersion = FileVersionFingerprint.from(data: writtenSnapshot.data)
                residualKnownHostsConflict = true
                failures.append("未能回滚新建的 ~/.ssh/mimi/\(Self.knownHostsFileName)（\(error.localizedDescription)）")
            }
        case .updated(let originalSnapshot, let writtenSnapshot):
            do {
                _ = try writeFileAtomically(
                    originalSnapshot.data,
                    to: knownHostsURL,
                    mode: originalSnapshot.mode ?? 0o600,
                    expectedSnapshot: writtenSnapshot,
                    label: "~/.ssh/mimi/\(Self.knownHostsFileName)",
                    invokeHook: false
                )
            } catch {
                residualKnownHostsVersion = FileVersionFingerprint.from(data: writtenSnapshot.data)
                residualKnownHostsConflict = true
                failures.append("未能恢复 ~/.ssh/mimi/\(Self.knownHostsFileName)（\(error.localizedDescription)）")
            }
        }

        // 5. 按发布快照隔离回滚本次新建的密钥文件（绝不删外部替换的同名文件）。
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
                    mode: rollback.removedOwnedPublicKeyMode ?? 0o600,
                    label: "\(Self.keyFileName).pub",
                    invokeHook: false
                )
            } catch {
                failures.append("未能恢复原有公钥 \(Self.keyFileName).pub（\(error.localizedDescription)）")
            }
        }

        if rollback.createdMimiDirectory {
            removeDirectoryIfEmpty(mimiSSHDirectory, label: "~/.ssh/mimi")
        }

        // 6. 恢复或保留可撤销状态账本（明确区分已证实归属版本与待处理冲突）。
        if let residualAuthorizedEntry {
            fallbackState.authorizedKeyEntry = residualAuthorizedEntry
            fallbackState.authorizedKeyBody = rollback.addedAuthorizedKeyBody ?? rollback.generatedKeyBody
            fallbackState.authorizedKeyAddedLeadingNewline = rollback.addedAuthorizedKeyLeadingNewline
        }
        for body in residualAuthBodies where !fallbackState.residualAuthorizedKeyBodies.contains(body) {
            fallbackState.residualAuthorizedKeyBodies.append(body)
        }
        if residualConfigManaged && fallbackState.managedHostAlias == nil {
            fallbackState.managedHostAlias = Self.hostAlias
            fallbackState.managedUsername = rollback.writtenUsername
        }
        if let ver = residualMimiConfigVersion {
            fallbackState.mimiConfigVersion = ver
        }
        if residualMimiConfigConflict {
            fallbackState.mimiConfigConflict = true
        }
        if residualNewKeyManaged {
            if let fp = rollback.generatedKeyFingerprint { fallbackState.keyFingerprint = fp }
            if let body = rollback.generatedKeyBody { fallbackState.publicKeyBody = body }
        }
        if residualKnownHostsConflict {
            fallbackState.managedKnownHosts = true
            fallbackState.knownHostsConflict = true
            if let ver = residualKnownHostsVersion {
                fallbackState.knownHostsVersion = ver
            }
        }
        for dirName in rollback.residualStagedKeyDirectories where !fallbackState.stagedKeyDirectories.contains(dirName) {
            fallbackState.stagedKeyDirectories.append(dirName)
            failures.append("未能清理密钥暂存目录 ~/.ssh/mimi/\(dirName)")
        }

        do {
            if !failures.isEmpty && !fallbackState.isEmpty {
                try saveManagedState(fallbackState, invokeHook: false)
            } else if var previousState = rollback.previousState {
                previousState.pendingTransaction = nil
                if previousState.isEmpty {
                    try removeRegularFileIfPresent(stateFileURL, label: stateFileURL.lastPathComponent)
                } else {
                    try saveManagedState(previousState, invokeHook: false)
                }
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

    func validateCandidateSSHConfig(
        candidateUserConfig: String,
        candidateMimiConfig: String,
        expectedUser: String
    ) async throws {
        let materialized = try materializeEvaluationSSHConfig(
            userConfigText: candidateUserConfig,
            includeSystemConfig: true,
            virtualFileOverrides: [mimiConfigURL.path: candidateMimiConfig]
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

    /// 跨「无命令基准」「/bin/cat 探测命令」「实际验连参数」「Codex 桌面代理命令」与「真实桌面默认路径」逐一执行 `ssh -G` 校验与跨画像一致性比对，
    /// 锁定 `HostKeyAlias`、`AddressFamily`、`IdentityFile`、`IdentitiesOnly`、`UserKnownHostsFile` 与 `NoHostAuthenticationForLocalhost=no`。
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

        // 2. 冻结快照：/bin/cat 探测命令
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
        guard Self.effectiveEndpointAuthAndTrustMatch(baseEffective, catEffective) else {
            throw ConfigError.effectiveConfigConflict("探测命令（/bin/cat）与基准配置的有效端点、身份或信任参数不一致。")
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
            guard Self.effectiveEndpointAuthAndTrustMatch(catEffective, proxyEffective) else {
                throw ConfigError.effectiveConfigConflict("Codex 桌面代理命令与探测命令的有效端点、身份或信任参数不一致。")
            }
        }

        // 4. 实际验连命令行参数（含事务内 known_hosts 副本与固定选项）
        if let probeVerifyArguments, let txKnownHostsPath {
            let probeEffective = try await resolveEffectiveSSHConfig(rawArguments: probeVerifyArguments)
            if let conflict = Self.validateEffectiveLoopbackConfig(
                probeEffective,
                expectedUser: expectedUser,
                expectedIdentityFile: expectedIdentityFileConfigValue,
                expectedKnownHostsFile: txKnownHostsPath
            ) {
                throw ConfigError.effectiveConfigConflict("实际验连参数有效配置异常：\(conflict)")
            }
            guard Self.effectiveEndpointAuthAndTrustMatch(baseEffective, probeEffective, ignoreKnownHostsPath: true) else {
                throw ConfigError.effectiveConfigConflict("实际验连参数与托管配置的有效端点、身份或信任参数不一致。")
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
            guard Self.effectiveEndpointAuthAndTrustMatch(baseEffective, desktopBase) else {
                throw ConfigError.effectiveConfigConflict("真实桌面解析路径与冻结快照的有效配置不一致。")
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
                guard Self.effectiveEndpointAuthAndTrustMatch(catEffective, desktopProxy) else {
                    throw ConfigError.effectiveConfigConflict("真实桌面代理路径与探测命令的有效端点、身份或信任参数不一致。")
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
            // 执行被动 ssh -G 前先核验整个配置与 Include 树的来源属主、权限并拒绝 Match exec。
            let preflight = try materializeCurrentSSHConfigForEvaluation(includeSystemConfig: true)
            preflight.cleanup()
            rawArgs.append(contentsOf: extraOptions)
            rawArgs.append(alias)
            rawArgs.append(contentsOf: remoteCommand)
        } else if includeSystemConfig {
            let rawText: String
            if let rawData = try readEvaluationRegularFileIfPresent(at: URL(fileURLWithPath: configPath), label: "~/.ssh/config") {
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

    /// 构造绑定到冻结配置快照与事务内专用 `known_hosts` 副本的验连参数：
    /// 显式固定 `HostKeyAlias`、`AddressFamily=inet`、`IdentityFile`、`IdentitiesOnly=yes`、`NoHostAuthenticationForLocalhost=no`、`HashKnownHosts=no`、`KnownHostsCommand=none` 与 `VerifyHostKeyDNS=no`。
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
            "-o", "HostKeyAlias=\(Self.hostAlias)",
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
            "-o", "NoHostAuthenticationForLocalhost=no",
            "-o", "HashKnownHosts=no",
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

    func verifyLoopbackSSH(arguments: [String]) async throws {
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

    struct AuthorizedKeysRemovalOutcome {
        let removedAny: Bool
        let residualBodies: [String]
    }

    func removeTrackedAuthorizedEntries(
        trackedEntries: [TrackedAuthorizedEntry],
        trackedBodies: [String]
    ) throws -> AuthorizedKeysRemovalOutcome {
        let snapshot = try captureSnapshot(of: authorizedKeysURL, label: "~/.ssh/authorized_keys")
        guard snapshot.exists else {
            return AuthorizedKeysRemovalOutcome(removedAny: false, residualBodies: [])
        }
        if let info = snapshot.info {
            try ensureNotGroupOrWorldWritable(
                info,
                label: "~/.ssh/authorized_keys",
                reason: "为避免撤销写回时收紧权限从而激活原本被 StrictModes 拒绝的授权，已拒绝修改，请先手工核对并修复权限。"
            )
        }
        let content = try decodeUTF8(snapshot.data, label: "~/.ssh/authorized_keys")
        var working = content
        var removedAny = false

        for item in trackedEntries {
            let result = Self.removeExactAuthorizedKeyEntry(
                item.entry,
                expectedKeyBody: item.keyBody,
                addedLeadingNewline: item.addedLeadingNewline,
                from: working
            )
            if result.removed {
                working = result.text
                removedAny = true
            }
        }

        if removedAny {
            let targetMode = Self.tightenedFileMode(existing: snapshot.mode, maxMode: 0o600)
            _ = try writeFileAtomically(
                Data(working.utf8),
                to: authorizedKeysURL,
                mode: targetMode,
                expectedSnapshot: snapshot,
                label: "~/.ssh/authorized_keys"
            )
        }

        // 共用按公钥残留检查：即便精确 Mimi 标记行已删，只要同公钥还有其他授权行就必须保留记录并报告冲突！
        let residuals = Self.findResidualAuthorizedKeyBodies(trackedBodies, in: working)
        return AuthorizedKeysRemovalOutcome(removedAny: removedAny, residualBodies: residuals)
    }
}
