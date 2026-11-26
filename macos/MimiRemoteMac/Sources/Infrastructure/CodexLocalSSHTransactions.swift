import Darwin
import Foundation

extension CodexLocalSSHConfigurator {
    // MARK: - System ssh-keygen Staging & Zero-Copy Verification

    struct KeyMaterial {
        let publicKeyBody: String
        let fingerprint: String
    }

    struct StagedKeyPairBundle {
        let artifact: StagedKeyArtifact
        let privateKeyIdentity: FileIdentity
        let publicKeyIdentity: FileIdentity
        let privateSnapshot: FileSnapshot
        let publicSnapshot: FileSnapshot
        let publicKeyBody: String
        let fingerprint: String
    }

    // MARK: - Exclusive Inode-Tracked Key Staging & Publication

    /// 在 `~/.ssh/mimi/` 内独占创建 `0700` 暂存目录并先持久化其 `(dev, ino)`，再调用系统 `/usr/bin/ssh-keygen`
    /// 直接在 Mimi 目录内生成 Ed25519 密钥对（零额外私钥副本），校验 `.pub` 与 `ssh-keygen -y` 一致后持久化完整 WAL。
    func stageFreshKeyPairAndPersistWAL(
        plannedAuthorizedKeyAddedLeadingNewline: Bool,
        plannedUsername: String,
        plannedMimiConfigVersion: FileVersionFingerprint
    ) async throws -> (bundle: StagedKeyPairBundle, intentState: ManagedState) {
        let dirName = "\(Self.keyStagingDirectoryPrefix)\(UUID().uuidString)"
        guard Self.isValidStagedKeyDirectoryName(dirName) else {
            throw ConfigError.unsafeFileSystemTarget("非法的密钥暂存目录名称。")
        }

        let mimiDirFD = try openVerifiedParentDirectoryFD(for: privateKeyURL, label: "~/.ssh/mimi")
        defer { Darwin.close(mimiDirFD) }

        // 1. 独占创建 staging 目录（遇 EEXIST 立即失败，不登记、不删除任何已有目录）。
        guard Darwin.mkdirat(mimiDirFD, dirName, 0o700) == 0 else {
            throw ConfigError.fileOperationFailed("无法独占创建密钥临时目录：\(Self.posixErrorMessage())")
        }

        let stageFD = Darwin.openat(mimiDirFD, dirName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard stageFD >= 0 else {
            throw ConfigError.fileOperationFailed("无法打开独占密钥临时目录：\(Self.posixErrorMessage())")
        }
        var stageClosed = false
        defer {
            if !stageClosed { Darwin.close(stageFD) }
        }
        guard Darwin.fchmod(stageFD, 0o700) == 0 else {
            throw ConfigError.fileOperationFailed("设置密钥临时目录权限失败：\(Self.posixErrorMessage())")
        }
        var stageSt = stat()
        guard Darwin.fstat(stageFD, &stageSt) == 0,
              (stageSt.st_mode & S_IFMT) == S_IFDIR,
              stageSt.st_uid == Darwin.geteuid() else {
            throw ConfigError.unsafeFileSystemTarget("密钥临时目录属主或类型异常。")
        }
        let dirIdentity = FileIdentity(dev: stageSt.st_dev, ino: stageSt.st_ino)
        let preKeygenArtifact = StagedKeyArtifact(
            directoryName: dirName,
            directoryIdentity: dirIdentity,
            privateKeyIdentity: nil,
            publicKeyIdentity: nil
        )

        // 2. 调用 ssh-keygen 写盘前，先把独占创建的 staging 目录 inode 落盘登记。
        do {
            try saveManagedState(ManagedState(stagedKeyArtifacts: [preKeygenArtifact]), invokeHook: false)
        } catch {
            Darwin.close(stageFD)
            stageClosed = true
            _ = cleanupStagedKeyArtifact(preKeygenArtifact)
            throw error
        }

        let stagingDirURL = mimiSSHDirectory.appendingPathComponent(dirName, isDirectory: true)
        let stagedPrivateURL = stagingDirURL.appendingPathComponent(Self.keyFileName, isDirectory: false)
        let pubFileName = "\(Self.keyFileName).pub"
        var cleanupArtifact = preKeygenArtifact

        do {
            // 确认暂存目录内不存在同名残留，拒绝覆盖任何已有文件。
            var existingSt = stat()
            if Darwin.fstatat(stageFD, Self.keyFileName, &existingSt, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
                throw ConfigError.conflictingKeyFiles("暂存目录中已存在同名私钥或无法检查目标路径。")
            }
            if Darwin.fstatat(stageFD, pubFileName, &existingSt, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
                throw ConfigError.conflictingKeyFiles("暂存目录中已存在同名公钥或无法检查目标路径。")
            }

            // 3. 调用系统 /usr/bin/ssh-keygen 在 Mimi 目录内的独占路径生成 Ed25519 密钥对（空 stdin 拒绝交互覆盖）。
            let keygenResult: CommandResult
            do {
                keygenResult = try await runCommand(
                    URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                    ["-q", "-t", "ed25519", "-N", "", "-C", Self.keyComment, "-f", stagedPrivateURL.path],
                    .seconds(15),
                    Data()
                )
            } catch {
                throw ConfigError.keyGenerationFailed(error.localizedDescription)
            }
            guard keygenResult.status == 0 else {
                throw ConfigError.keyGenerationFailed(keygenResult.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            // 4. 在独占目录描述符下校验并收紧为 0600，记录确切 inode 与快照。
            let privFD = Darwin.openat(stageFD, Self.keyFileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard privFD >= 0 else {
                throw ConfigError.keyGenerationFailed("未能在暂存目录打开新建私钥：\(Self.posixErrorMessage())")
            }
            let privateSnapshot: FileSnapshot
            let privIdentity: FileIdentity
            do {
                defer { Darwin.close(privFD) }
                var privSt = stat()
                guard Darwin.fstat(privFD, &privSt) == 0,
                      (privSt.st_mode & S_IFMT) == S_IFREG,
                      privSt.st_uid == Darwin.geteuid() else {
                    throw ConfigError.unsafeFileSystemTarget("新建暂存私钥类型或属主异常。")
                }
                guard Darwin.fchmod(privFD, 0o600) == 0 else {
                    throw ConfigError.fileOperationFailed("设置暂存私钥权限失败：\(Self.posixErrorMessage())")
                }
                guard Darwin.fstat(privFD, &privSt) == 0 else {
                    throw ConfigError.fileOperationFailed("无法读取暂存私钥快照：\(Self.posixErrorMessage())")
                }
                let privData = try readAllBytes(from: privFD, label: Self.keyFileName)
                guard !privData.isEmpty else {
                    throw ConfigError.keyGenerationFailed("新建暂存私钥内容为空。")
                }
                privIdentity = FileIdentity(dev: privSt.st_dev, ino: privSt.st_ino)
                privateSnapshot = FileSnapshot(exists: true, info: LStatInfo(stat: privSt), data: privData)
            }

            let pubFD = Darwin.openat(stageFD, pubFileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard pubFD >= 0 else {
                cleanupArtifact = StagedKeyArtifact(
                    directoryName: dirName,
                    directoryIdentity: dirIdentity,
                    privateKeyIdentity: privIdentity,
                    publicKeyIdentity: nil
                )
                throw ConfigError.keyGenerationFailed("未能在暂存目录打开新建公钥：\(Self.posixErrorMessage())")
            }
            let publicSnapshot: FileSnapshot
            let pubIdentity: FileIdentity
            do {
                defer { Darwin.close(pubFD) }
                var pubSt = stat()
                guard Darwin.fstat(pubFD, &pubSt) == 0,
                      (pubSt.st_mode & S_IFMT) == S_IFREG,
                      pubSt.st_uid == Darwin.geteuid() else {
                    throw ConfigError.unsafeFileSystemTarget("新建暂存公钥类型或属主异常。")
                }
                guard Darwin.fchmod(pubFD, 0o600) == 0 else {
                    throw ConfigError.fileOperationFailed("设置暂存公钥权限失败：\(Self.posixErrorMessage())")
                }
                guard Darwin.fstat(pubFD, &pubSt) == 0 else {
                    throw ConfigError.fileOperationFailed("无法读取暂存公钥快照：\(Self.posixErrorMessage())")
                }
                let pubData = try readAllBytes(from: pubFD, label: pubFileName)
                pubIdentity = FileIdentity(dev: pubSt.st_dev, ino: pubSt.st_ino)
                publicSnapshot = FileSnapshot(exists: true, info: LStatInfo(stat: pubSt), data: pubData)
            }

            let artifact = StagedKeyArtifact(
                directoryName: dirName,
                directoryIdentity: dirIdentity,
                privateKeyIdentity: privIdentity,
                publicKeyIdentity: pubIdentity
            )
            cleanupArtifact = artifact

            Darwin.close(stageFD)
            stageClosed = true

            guard let pubText = String(data: publicSnapshot.data, encoding: .utf8),
                  let publicKeyBody = Self.extractPublicKeyBody(from: pubText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let fingerprint = Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: publicKeyBody) else {
                throw ConfigError.keyGenerationFailed("未读取到有效公钥内容。")
            }

            // 直接对暂存私钥路径调用 ssh-keygen -y 核验公私钥匹配，不写任何额外私钥副本。
            guard let derivedBody = await derivePublicKeyBody(at: stagedPrivateURL, expectedSnapshot: privateSnapshot),
                  derivedBody == publicKeyBody else {
                throw ConfigError.keyGenerationFailed("生成的私钥与公钥不匹配。")
            }

            // 5. 将确切目录/文件 inode 及完整 WAL 意图持久化落盘。
            let plannedAuthorizedKeyEntry = Self.formatManagedAuthorizedKeyEntry(publicKeyBody: publicKeyBody)
            let intentState = ManagedState(
                stagedKeyArtifacts: [artifact],
                pendingTransaction: PendingTransaction(
                    transactionID: UUID().uuidString,
                    keyFingerprint: fingerprint,
                    publicKeyBody: publicKeyBody,
                    plannedAuthorizedKeyEntry: plannedAuthorizedKeyEntry,
                    plannedAuthorizedKeyBody: publicKeyBody,
                    authorizedKeyAddedLeadingNewline: plannedAuthorizedKeyAddedLeadingNewline,
                    plannedHostAlias: Self.hostAlias,
                    plannedUsername: plannedUsername,
                    plannedMimiConfigVersion: plannedMimiConfigVersion,
                    plannedKnownHostsVersion: nil,
                    stagedKeyArtifact: artifact
                )
            )
            try saveManagedState(intentState, invokeHook: false)

            let bundle = StagedKeyPairBundle(
                artifact: artifact,
                privateKeyIdentity: privIdentity,
                publicKeyIdentity: pubIdentity,
                privateSnapshot: privateSnapshot,
                publicSnapshot: publicSnapshot,
                publicKeyBody: publicKeyBody,
                fingerprint: fingerprint
            )
            return (bundle, intentState)
        } catch {
            if !stageClosed {
                Darwin.close(stageFD)
                stageClosed = true
            }
            if cleanupStagedKeyArtifact(cleanupArtifact) {
                try? removeRegularFileIfPresent(stateFileURL, label: stateFileURL.lastPathComponent)
            }
            throw error
        }
    }

    static func isValidStagedKeyDirectoryName(_ name: String) -> Bool {
        name.hasPrefix(keyStagingDirectoryPrefix) &&
            name.count > keyStagingDirectoryPrefix.count &&
            !name.contains("/") &&
            !name.contains("\\") &&
            !name.contains("..")
    }

    /// 核验暂存目录内的全部条目：仅允许本次生成的密钥/公钥普通文件，且属主与已记录 inode 完全匹配。
    private func verifyStagedDirectoryContents(stageFD: Int32, artifact: StagedKeyArtifact) -> Bool {
        let dupFD = Darwin.dup(stageFD)
        guard dupFD >= 0 else { return false }
        guard let dir = Darwin.fdopendir(dupFD) else {
            Darwin.close(dupFD)
            return false
        }
        defer { Darwin.closedir(dir) }

        let expectedIdentities: [String: FileIdentity?] = [
            Self.keyFileName: artifact.privateKeyIdentity,
            "\(Self.keyFileName).pub": artifact.publicKeyIdentity,
        ]
        let currentUID = Darwin.geteuid()

        while let entryPtr = Darwin.readdir(dir) {
            let name = withUnsafePointer(to: &entryPtr.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard let expectedIdentityOptional = expectedIdentities[name] else {
                return false
            }
            var fileSt = stat()
            guard Darwin.fstatat(stageFD, name, &fileSt, AT_SYMLINK_NOFOLLOW) == 0,
                  (fileSt.st_mode & S_IFMT) == S_IFREG,
                  fileSt.st_uid == currentUID else {
                return false
            }
            if let expectedIdentity = expectedIdentityOptional, !expectedIdentity.matches(fileSt) {
                return false
            }
        }
        return true
    }

    /// 隔离-核验-清理本次独占创建的 `~/.ssh/mimi/.mimi-keygen-*` 暂存目录与文件：
    /// - 先做无破坏预检，再通过 `RENAME_EXCL` 将整个暂存目录原子移入独占 `0700` 隔离目录；
    /// - 在隔离目录内复核目录 `(dev, ino)` 与其中全部文件的 `(dev, ino)` 后才 `unlinkat` + `rmdir`，彻底消除 check-then-unlink 竞态；
    /// - 任一核验失败时通过 `RENAME_EXCL` 原子恢复回原路径（冲突则保留在隔离目录内），绝不误删同名替换目录或文件；
    /// - 返回 `true` 仅表示该独占目录已确认不存在。
    func cleanupStagedKeyArtifact(_ artifact: StagedKeyArtifact) -> Bool {
        let dirName = artifact.directoryName
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

        // 1. 无破坏预检：目录或文件 inode 不匹配时直接返回，不移动外部替换目录。
        let preStageFD = Darwin.openat(parentFD, dirName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        if preStageFD < 0 {
            return errno == ENOENT
        }
        var preStageSt = stat()
        let preOK: Bool = {
            defer { Darwin.close(preStageFD) }
            guard Darwin.fstat(preStageFD, &preStageSt) == 0,
                  (preStageSt.st_mode & S_IFMT) == S_IFDIR,
                  preStageSt.st_uid == Darwin.geteuid(),
                  artifact.directoryIdentity.matches(preStageSt) else {
                return false
            }
            return verifyStagedDirectoryContents(stageFD: preStageFD, artifact: artifact)
        }()
        guard preOK else { return false }

        // 2. 创建独占 0700 隔离目录并将暂存目录原子移入，阻断按路径并发替换窗口。
        let qDirName = ".mimi-quarantine-\(UUID().uuidString)"
        guard Darwin.mkdirat(parentFD, qDirName, 0o700) == 0 else {
            return false
        }
        let qDirFD = Darwin.openat(parentFD, qDirName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard qDirFD >= 0 else {
            _ = Darwin.unlinkat(parentFD, qDirName, AT_REMOVEDIR)
            return false
        }
        _ = Darwin.fchmod(qDirFD, 0o700)

        var keepQuarantineDir = false
        defer {
            Darwin.close(qDirFD)
            if !keepQuarantineDir {
                _ = Darwin.unlinkat(parentFD, qDirName, AT_REMOVEDIR)
            }
        }

        if Darwin.renameatx_np(parentFD, dirName, qDirFD, "dir", UInt32(RENAME_EXCL)) != 0 {
            return errno == ENOENT
        }

        // 3. 在隔离目录内复核目录与全部文件的 inode 及属主；不匹配时原子无覆盖恢复。
        let isoStageFD = Darwin.openat(qDirFD, "dir", O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        let verifiedInQuarantine: Bool
        if isoStageFD >= 0 {
            var isoStageSt = stat()
            verifiedInQuarantine = Darwin.fstat(isoStageFD, &isoStageSt) == 0 &&
                (isoStageSt.st_mode & S_IFMT) == S_IFDIR &&
                isoStageSt.st_uid == Darwin.geteuid() &&
                artifact.directoryIdentity.matches(isoStageSt) &&
                verifyStagedDirectoryContents(stageFD: isoStageFD, artifact: artifact)
        } else {
            verifiedInQuarantine = false
        }

        guard verifiedInQuarantine else {
            if isoStageFD >= 0 {
                Darwin.close(isoStageFD)
            }
            if Darwin.renameatx_np(qDirFD, "dir", parentFD, dirName, UInt32(RENAME_EXCL)) != 0 {
                keepQuarantineDir = true
            }
            return false
        }

        // 4. 在隔离目录内安全删除已核验的暂存文件并移除空目录。
        for fileName in [Self.keyFileName, "\(Self.keyFileName).pub"] {
            if Darwin.unlinkat(isoStageFD, fileName, 0) != 0 && errno != ENOENT {
                Darwin.close(isoStageFD)
                if Darwin.renameatx_np(qDirFD, "dir", parentFD, dirName, UInt32(RENAME_EXCL)) != 0 {
                    keepQuarantineDir = true
                }
                return false
            }
        }
        Darwin.close(isoStageFD)

        if Darwin.unlinkat(qDirFD, "dir", AT_REMOVEDIR) == 0 || errno == ENOENT {
            return true
        }
        if Darwin.renameatx_np(qDirFD, "dir", parentFD, dirName, UInt32(RENAME_EXCL)) != 0 {
            keepQuarantineDir = true
        }
        return false
    }

    func publishStagedKeyPairBundle(
        _ bundle: StagedKeyPairBundle,
        rollback: inout RollbackRecord
    ) throws -> KeyMaterial {
        let publishedPrivateSnapshot = try publishStagedKeyFile(
            inStagingDirectory: bundle.artifact.directoryName,
            expectedDirectoryIdentity: bundle.artifact.directoryIdentity,
            fileName: Self.keyFileName,
            expectedFileIdentity: bundle.privateKeyIdentity,
            stagedSnapshot: bundle.privateSnapshot,
            to: privateKeyURL,
            label: Self.keyFileName
        )
        rollback.createdPrivateKey = true
        rollback.createdPrivateKeySnapshot = publishedPrivateSnapshot
        rollback.generatedKeyBody = bundle.publicKeyBody
        rollback.generatedKeyFingerprint = bundle.fingerprint

        let publishedPublicSnapshot = try publishStagedKeyFile(
            inStagingDirectory: bundle.artifact.directoryName,
            expectedDirectoryIdentity: bundle.artifact.directoryIdentity,
            fileName: "\(Self.keyFileName).pub",
            expectedFileIdentity: bundle.publicKeyIdentity,
            stagedSnapshot: bundle.publicSnapshot,
            to: publicKeyURL,
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

        guard let expectedBody = state.effectiveKeyBody,
              let expectedFP = state.effectiveKeyFingerprint else {
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
               let derived = await derivePublicKeyBody(at: privateKeyURL, expectedSnapshot: snapshot),
               let derivedFP = Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: derived),
               derived == expectedBody, derivedFP == expectedFP {
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
               pubBody == expectedBody, pubFP == expectedFP {
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
        return await derivePublicKeyBody(at: privateKeyURL, expectedSnapshot: snapshot)
    }

    /// 直接对已有私钥文件调用系统 `/usr/bin/ssh-keygen -y -P "" -f <path>` 推导公钥主体，绝不写入任何额外私钥副本；
    /// 调用前后校验文件类型、属主与快照一致，防止路径替换竞态。
    func derivePublicKeyBody(at keyURL: URL, expectedSnapshot: FileSnapshot) async -> String? {
        guard expectedSnapshot.exists, !expectedSnapshot.data.isEmpty else { return nil }
        guard let preSnapshot = try? captureSnapshot(of: keyURL, label: keyURL.lastPathComponent),
              Self.snapshotsMatch(expectedSnapshot, preSnapshot) else {
            return nil
        }
        guard let result = try? await runCommand(
            URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            ["-y", "-P", "", "-f", keyURL.path],
            .seconds(10),
            Data()
        ), result.status == 0 else {
            return nil
        }
        guard let postSnapshot = try? captureSnapshot(of: keyURL, label: keyURL.lastPathComponent),
              Self.snapshotsMatch(expectedSnapshot, postSnapshot) else {
            return nil
        }
        let line = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.extractPublicKeyBody(from: line)
    }

    // MARK: - Transactional Rollback (First-Time Setup Only)

    enum KnownHostsMutation {
        case unchanged
        case created(writtenSnapshot: FileSnapshot)
    }

    struct RollbackRecord {
        var createdSSHDirectory: Bool = false
        var createdMimiDirectory: Bool = false
        var createdPrivateKey: Bool = false
        var createdPrivateKeySnapshot: FileSnapshot?
        var createdPublicKey: Bool = false
        var createdPublicKeySnapshot: FileSnapshot?
        var generatedKeyBody: String?
        var generatedKeyFingerprint: String?
        var wroteMimiConfig: Bool = false
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
        var knownHostsMutation: KnownHostsMutation = .unchanged
        var residualStagedKeyArtifacts: [StagedKeyArtifact] = []
    }

    struct RollbackOutcome {
        var fullyRolledBack: Bool = true
        var detail: String?
    }

    func performRollback(_ rollback: RollbackRecord) async -> RollbackOutcome {
        var failures: [String] = []
        var fallbackState = ManagedState()

        var residualAuthorizedEntry: String?
        var residualAuthBodies: [String] = []
        var residualConfigManaged = false
        var residualMimiConfigVersion: FileVersionFingerprint?
        var residualMimiConfigConflict = false
        var residualNewKeyManaged = false
        var residualKnownHostsVersion: FileVersionFingerprint?
        var residualKnownHostsConflict = false

        // 1. 回滚本次对 authorized_keys 的写入：
        //    - 外部已删除时保留删除，绝不重建；
        //    - 若 ~/.ssh 或 authorized_keys 权限/属主变为不安全（组/全局可写等），直接拒绝修改且绝不收紧权限或保留其条目！
        if rollback.wroteAuthorizedKeys {
            var authReverted = false
            do {
                if let sshDirInfo = try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh") {
                    try ensureNotGroupOrWorldWritable(
                        sshDirInfo,
                        label: "~/.ssh",
                        reason: "回滚期间检测到 ~/.ssh 权限不安全，已拒绝自动修改权限，请先手工修复权限（chmod 700 ~/.ssh）后再点击「移除本机 SSH 配置」。"
                    )
                }
                let snapshot = try captureSnapshot(of: authorizedKeysURL, label: "~/.ssh/authorized_keys")
                if !snapshot.exists {
                    // 外部进程已在 Mimi 写入后删除了 authorized_keys（例如吊销全部授权），必须保留该删除，绝不重建原文件！
                    authReverted = true
                } else {
                    if let info = snapshot.info {
                        try ensureNotGroupOrWorldWritable(
                            info,
                            label: "~/.ssh/authorized_keys",
                            reason: "回滚期间检测到 ~/.ssh/authorized_keys 权限变为组或其他用户可写，已拒绝修改权限或保留其中条目；请先手工核对文件内容并执行 chmod 600 ~/.ssh/authorized_keys。"
                        )
                    }
                    if let writtenSnap = rollback.writtenAuthSnapshot, Self.snapshotsMatch(writtenSnap, snapshot) {
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

                        let targetKeyBody = rollback.addedAuthorizedKeyBody ?? rollback.generatedKeyBody
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

                        if changed {
                            let mode = Self.preservedSafeFileMode(existing: snapshot.mode, defaultMode: 0o600)
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

        // 2. 回滚本次对 ~/.ssh/config 单行 Include 的写入：
        //    - 外部已删除时保留删除，绝不重建；
        //    - 权限/属主不安全时直接拒绝修改，不自动改权、不在回滚中保留其条目。
        if rollback.wroteSSHConfig {
            var configReverted = false
            do {
                if let sshDirInfo = try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh") {
                    try ensureNotGroupOrWorldWritable(
                        sshDirInfo,
                        label: "~/.ssh",
                        reason: "回滚期间检测到 ~/.ssh 权限不安全，已拒绝自动修改权限，请先手工修复权限（chmod 700 ~/.ssh）。"
                    )
                }
                let snapshot = try captureSnapshot(of: sshConfigURL, label: "~/.ssh/config")
                if !snapshot.exists {
                    // 外部进程已删除 ~/.ssh/config，保留外部删除，绝不重建！
                    configReverted = true
                } else {
                    if let info = snapshot.info {
                        try ensureNotGroupOrWorldWritable(
                            info,
                            label: "~/.ssh/config",
                            reason: "回滚期间检测到 ~/.ssh/config 权限变为组或其他用户可写，已拒绝修改权限或保留其中条目；请先手工核对文件内容并执行 chmod 600 ~/.ssh/config。"
                        )
                    }
                    if let writtenSnap = rollback.writtenConfigSnapshot, Self.snapshotsMatch(writtenSnap, snapshot) {
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
                                let mode = Self.preservedSafeFileMode(existing: snapshot.mode, defaultMode: 0o600)
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
                }
            } catch {
                configReverted = false
                failures.append("未能自动回滚 ~/.ssh/config（\(error.localizedDescription)）")
            }

            if !configReverted {
                residualConfigManaged = true
            }
        }

        // 3. 回滚本次新建的 ~/.ssh/mimi/config（仅匹配本次写入快照时删除；外部修改或替换则保全并记录冲突版本）
        if rollback.wroteMimiConfig, let writtenMimiSnap = rollback.writtenMimiConfigSnapshot {
            do {
                try removeFileMatchingSnapshot(
                    mimiConfigURL,
                    expectedSnapshot: writtenMimiSnap,
                    label: "~/.ssh/mimi/config",
                    invokeHook: false
                )
            } catch {
                residualMimiConfigVersion = FileVersionFingerprint.from(data: writtenMimiSnap.data)
                if case ConfigError.conflictingKeyFiles = error {
                    residualMimiConfigConflict = true
                }
                failures.append("未能自动回滚 ~/.ssh/mimi/config（\(error.localizedDescription)）")
            }
        }

        // 4. 回滚本次新建的 ~/.ssh/mimi/known_hosts（仅匹配本次写入快照时删除；外部替换则保全并记录冲突）
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
                if case ConfigError.conflictingKeyFiles = error {
                    residualKnownHostsConflict = true
                }
                failures.append("未能回滚新建的 ~/.ssh/mimi/\(Self.knownHostsFileName)（\(error.localizedDescription)）")
            }
        }

        // 5. 按发布快照隔离回滚本次新建的密钥文件（绝不删外部替换的同名文件）。
        //    遇到快照冲突（例如仅权限被改为 0400）或 I/O 失败时，均保留密钥归属记录，保证 Remove 仍可按密码学指纹核验并清理。
        if rollback.createdPrivateKey, let snapshot = rollback.createdPrivateKeySnapshot {
            do {
                try removeFileMatchingSnapshot(privateKeyURL, expectedSnapshot: snapshot, label: Self.keyFileName, invokeHook: false)
            } catch ConfigError.conflictingKeyFiles {
                residualNewKeyManaged = true
                failures.append("私钥 \(Self.keyFileName) 在回滚前权限或内容发生变化，已保留未删除与归属记录")
            } catch {
                residualNewKeyManaged = true
                failures.append("未能回滚新建私钥 \(Self.keyFileName)（\(error.localizedDescription)）")
            }
        }
        if rollback.createdPublicKey, let snapshot = rollback.createdPublicKeySnapshot {
            do {
                try removeFileMatchingSnapshot(publicKeyURL, expectedSnapshot: snapshot, label: "\(Self.keyFileName).pub", invokeHook: false)
            } catch ConfigError.conflictingKeyFiles {
                residualNewKeyManaged = true
                failures.append("公钥 \(Self.keyFileName).pub 在回滚前权限或内容发生变化，已保留未删除与归属记录")
            } catch {
                residualNewKeyManaged = true
                failures.append("未能回滚新建公钥 \(Self.keyFileName).pub（\(error.localizedDescription)）")
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
        if residualConfigManaged {
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
        if let ver = residualKnownHostsVersion {
            fallbackState.managedKnownHosts = true
            fallbackState.knownHostsVersion = ver
        }
        if residualKnownHostsConflict {
            fallbackState.managedKnownHosts = true
            fallbackState.knownHostsConflict = true
        }
        for artifact in rollback.residualStagedKeyArtifacts where !fallbackState.stagedKeyArtifacts.contains(artifact) {
            fallbackState.stagedKeyArtifacts.append(artifact)
            failures.append("未能清理密钥暂存目录 ~/.ssh/mimi/\(artifact.directoryName)")
        }

        do {
            if !failures.isEmpty && !fallbackState.isEmpty {
                try saveManagedState(fallbackState, invokeHook: false)
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

    // MARK: - OpenSSH Multi-Profile Effective Config & Isolated Verification (Frozen Snapshot Only)

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
            probeVerifyArguments: nil,
            txKnownHostsPath: nil
        )
    }

    /// 跨「无命令基准」「/bin/cat 探测命令」「Codex 桌面代理命令」与「实际验连参数」均仅针对同一份冻结快照执行 `ssh -G` 校验，
    /// 绝不重新读取实时 `~/.ssh/config` 或 `/etc/ssh/ssh_config`。
    func validateManagedEffectiveProfiles(
        frozenConfigPath: String,
        expectedUser: String,
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

        // 4. 实际验连命令行参数（绑定同一份冻结快照 + 事务内 known_hosts 副本）
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
    }

    /// 始终针对冻结快照执行 `ssh -G`（始终显式传递 `-F <frozenPath>`，绝不读取实时 `~/.ssh/config` 或系统实时配置）。
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
        if includeSystemConfig {
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
        } else {
            rawArgs.append(contentsOf: ["-F", configPath])
        }
        rawArgs.append(contentsOf: extraOptions)
        rawArgs.append(alias)
        rawArgs.append(contentsOf: remoteCommand)

        return try await resolveEffectiveSSHConfig(rawArguments: rawArgs)
    }

    func resolveEffectiveSSHConfig(rawArguments: [String]) async throws -> EffectiveSSHConfig {
        guard let fIndex = rawArguments.firstIndex(of: "-F"),
              fIndex + 1 < rawArguments.count,
              !rawArguments[fIndex + 1].isEmpty else {
            throw ConfigError.effectiveConfigConflict("ssh -G 必须绑定冻结快照配置文件（-F），已拒绝读取实时 SSH 配置。")
        }
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
        txKnownHostsPath: String,
        strictHostKeyChecking: String = "accept-new"
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
            "-o", "StrictHostKeyChecking=\(strictHostKeyChecking)",
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

    func removeTrackedAuthorizedEntry(
        entry: String?,
        expectedKeyBody: String?,
        addedLeadingNewline: Bool,
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
                reason: "请先手工核对授权条目并在终端执行 chmod 600 ~/.ssh/authorized_keys 后再试。"
            )
        }
        let content = try decodeUTF8(snapshot.data, label: "~/.ssh/authorized_keys")
        var working = content
        var removedAny = false

        if let entry, let keyBody = expectedKeyBody ?? Self.parseAuthorizedKeyLine(entry)?.keyBody {
            let result = Self.removeExactAuthorizedKeyEntry(
                entry,
                expectedKeyBody: keyBody,
                addedLeadingNewline: addedLeadingNewline,
                from: working
            )
            if result.removed {
                working = result.text
                removedAny = true
            }
        }

        if removedAny {
            let targetMode = Self.preservedSafeFileMode(existing: snapshot.mode, defaultMode: 0o600)
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
