import CryptoKit
import Darwin
import Foundation

extension CodexLocalSSHConfigurator {
    // MARK: - In-Memory OpenSSH Ed25519 Generation & Verification (Zero Extra Private Key Copies)

    struct GeneratedEd25519KeyPair {
        let privateKeyData: Data
        let publicKeyData: Data
        let publicKeyBody: String
        let fingerprint: String
    }

    struct KeyMaterial {
        let publicKeyBody: String
        let fingerprint: String
    }

    struct StagedKeyPairBundle {
        let artifact: StagedKeyArtifact
        let privateSnapshot: FileSnapshot
        let publicSnapshot: FileSnapshot
        let publicKeyBody: String
        let fingerprint: String
    }

    /// 纯内存生成标准 OpenSSH v1 Ed25519 密钥对（`openssh-key-v1` 格式），不产生额外临时私钥副本。
    static func generateEd25519OpenSSHKeyPair(comment: String = keyComment) throws -> GeneratedEd25519KeyPair {
        let signingKey = Curve25519.Signing.PrivateKey()
        let seed32 = signingKey.rawRepresentation
        let pub32 = signingKey.publicKey.rawRepresentation

        var pubWireBlob = Data()
        appendSSHString(Data("ssh-ed25519".utf8), to: &pubWireBlob)
        appendSSHString(pub32, to: &pubWireBlob)

        let publicKeyBody = "ssh-ed25519 \(pubWireBlob.base64EncodedString())"
        guard let fingerprint = computeOpenSSHSHA256Fingerprint(fromKeyBody: publicKeyBody) else {
            throw ConfigError.keyGenerationFailed("无法计算新建 Ed25519 公钥指纹。")
        }

        var checkInt: UInt32 = 0
        withUnsafeMutableBytes(of: &checkInt) { raw in
            arc4random_buf(raw.baseAddress, raw.count)
        }

        var privSection = Data()
        appendSSHUInt32(checkInt, to: &privSection)
        appendSSHUInt32(checkInt, to: &privSection)
        appendSSHString(Data("ssh-ed25519".utf8), to: &privSection)
        appendSSHString(pub32, to: &privSection)
        var priv64 = Data()
        priv64.append(seed32)
        priv64.append(pub32)
        appendSSHString(priv64, to: &privSection)
        appendSSHString(Data(comment.utf8), to: &privSection)
        var padByte: UInt8 = 1
        while privSection.count % 8 != 0 {
            privSection.append(padByte)
            padByte &+= 1
        }

        var payload = Data("openssh-key-v1\0".utf8)
        appendSSHString(Data("none".utf8), to: &payload) // ciphername
        appendSSHString(Data("none".utf8), to: &payload) // kdfname
        appendSSHString(Data(), to: &payload)            // kdfoptions
        appendSSHUInt32(1, to: &payload)                 // number of keys
        appendSSHString(pubWireBlob, to: &payload)       // public key blob
        appendSSHString(privSection, to: &payload)       // private section

        let base64 = payload.base64EncodedString()
        var pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        var index = base64.startIndex
        while index < base64.endIndex {
            let next = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            pem.append(contentsOf: base64[index..<next])
            pem.append("\n")
            index = next
        }
        pem.append("-----END OPENSSH PRIVATE KEY-----\n")

        let privateKeyData = Data(pem.utf8)
        let publicKeyData = Data("\(publicKeyBody) \(comment)\n".utf8)
        return GeneratedEd25519KeyPair(
            privateKeyData: privateKeyData,
            publicKeyData: publicKeyData,
            publicKeyBody: publicKeyBody,
            fingerprint: fingerprint
        )
    }

    /// 纯内存解析并密码学验证 OpenSSH v1 未加密 Ed25519 私钥，推导对应的 `ssh-ed25519 <base64>` 公钥主体，绝不落盘任何临时私钥副本。
    static func derivePublicKeyBody(fromOpenSSHPrivateKeyData data: Data) -> String? {
        guard !data.isEmpty,
              let pem = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = pem
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3,
              lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              lines.last == "-----END OPENSSH PRIVATE KEY-----" else {
            return nil
        }
        let bodyBase64 = lines.dropFirst().dropLast().joined()
        guard let payload = Data(base64Encoded: bodyBase64) else {
            return nil
        }

        let magic = Data("openssh-key-v1\0".utf8)
        guard payload.starts(with: magic) else { return nil }
        var offset = magic.count

        guard let cipherName = readSSHString(from: payload, offset: &offset),
              cipherName == Data("none".utf8),
              let kdfName = readSSHString(from: payload, offset: &offset),
              kdfName == Data("none".utf8),
              let kdfOptions = readSSHString(from: payload, offset: &offset),
              kdfOptions.isEmpty,
              let keyCount = readSSHUInt32(from: payload, offset: &offset),
              keyCount == 1,
              let pubWireBlob = readSSHString(from: payload, offset: &offset),
              let privSection = readSSHString(from: payload, offset: &offset),
              offset == payload.count,
              privSection.count % 8 == 0 else {
            return nil
        }

        var pubOffset = 0
        guard let pubKeyType = readSSHString(from: pubWireBlob, offset: &pubOffset),
              pubKeyType == Data("ssh-ed25519".utf8),
              let headerPub32 = readSSHString(from: pubWireBlob, offset: &pubOffset),
              headerPub32.count == 32,
              pubOffset == pubWireBlob.count else {
            return nil
        }

        var privOffset = 0
        guard let check1 = readSSHUInt32(from: privSection, offset: &privOffset),
              let check2 = readSSHUInt32(from: privSection, offset: &privOffset),
              check1 == check2,
              let privKeyType = readSSHString(from: privSection, offset: &privOffset),
              privKeyType == Data("ssh-ed25519".utf8),
              let privPub32 = readSSHString(from: privSection, offset: &privOffset),
              privPub32 == headerPub32,
              let priv64 = readSSHString(from: privSection, offset: &privOffset),
              priv64.count == 64,
              readSSHString(from: privSection, offset: &privOffset) != nil else {
            return nil
        }

        // 核验剩余填充字节严格遵循 OpenSSH 1, 2, 3... 规则。
        let remaining = privSection.count - privOffset
        guard remaining < 8 else { return nil }
        for idx in 0..<remaining {
            if privSection[privOffset + idx] != UInt8(idx + 1) {
                return nil
            }
        }

        let seed32 = priv64.prefix(32)
        let embeddedPub32 = priv64.suffix(32)
        guard embeddedPub32 == headerPub32,
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed32),
              signingKey.publicKey.rawRepresentation == headerPub32 else {
            return nil
        }

        return "ssh-ed25519 \(pubWireBlob.base64EncodedString())"
    }

    private static func appendSSHUInt32(_ value: UInt32, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func appendSSHString(_ bytes: Data, to data: inout Data) {
        appendSSHUInt32(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func readSSHUInt32(from data: Data, offset: inout Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        offset += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func readSSHString(from data: Data, offset: inout Int) -> Data? {
        guard let len = readSSHUInt32(from: data, offset: &offset) else { return nil }
        let length = Int(len)
        guard length >= 0, offset + length <= data.count else { return nil }
        let slice = data.subdata(in: offset..<(offset + length))
        offset += length
        return slice
    }

    // MARK: - Exclusive Inode-Tracked Key Staging & Publication

    /// 独占创建 `~/.ssh/mimi/.mimi-keygen-*`（`0700`）与独占空密钥文件（`O_CREAT|O_EXCL|O_NOFOLLOW`, `0600`），
    /// 在写入私钥字节前先把目录与文件的 `(dev, ino)` 及 WAL 持久化到 `stateFileURL`，随后写入唯一一份私钥材料。
    func stageFreshKeyPairAndPersistWAL(
        generatedKey: GeneratedEd25519KeyPair,
        plannedAuthorizedKeyEntry: String,
        plannedAuthorizedKeyAddedLeadingNewline: Bool,
        plannedUsername: String,
        plannedMimiConfigVersion: FileVersionFingerprint
    ) throws -> (bundle: StagedKeyPairBundle, intentState: ManagedState) {
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

        // 2. 在独占目录内独占创建空私钥与空公钥文件，获取确切 inode（写入私钥字节前）。
        let privFD = Darwin.openat(stageFD, Self.keyFileName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard privFD >= 0 else {
            _ = Darwin.unlinkat(mimiDirFD, dirName, AT_REMOVEDIR)
            throw ConfigError.fileOperationFailed("无法独占创建暂存私钥文件：\(Self.posixErrorMessage())")
        }
        var privClosed = false
        defer {
            if !privClosed { Darwin.close(privFD) }
        }
        guard Darwin.fchmod(privFD, 0o600) == 0 else {
            Darwin.close(privFD)
            privClosed = true
            _ = Darwin.unlinkat(stageFD, Self.keyFileName, 0)
            _ = Darwin.unlinkat(mimiDirFD, dirName, AT_REMOVEDIR)
            throw ConfigError.fileOperationFailed("设置暂存私钥权限失败：\(Self.posixErrorMessage())")
        }
        var privInitSt = stat()
        guard Darwin.fstat(privFD, &privInitSt) == 0 else {
            Darwin.close(privFD)
            privClosed = true
            _ = Darwin.unlinkat(stageFD, Self.keyFileName, 0)
            _ = Darwin.unlinkat(mimiDirFD, dirName, AT_REMOVEDIR)
            throw ConfigError.fileOperationFailed("无法记录暂存私钥 inode：\(Self.posixErrorMessage())")
        }
        let privIdentity = FileIdentity(dev: privInitSt.st_dev, ino: privInitSt.st_ino)

        let pubFileName = "\(Self.keyFileName).pub"
        let pubFD = Darwin.openat(stageFD, pubFileName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard pubFD >= 0 else {
            Darwin.close(privFD)
            privClosed = true
            _ = Darwin.unlinkat(stageFD, Self.keyFileName, 0)
            _ = Darwin.unlinkat(mimiDirFD, dirName, AT_REMOVEDIR)
            throw ConfigError.fileOperationFailed("无法独占创建暂存公钥文件：\(Self.posixErrorMessage())")
        }
        var pubClosed = false
        defer {
            if !pubClosed { Darwin.close(pubFD) }
        }
        guard Darwin.fchmod(pubFD, 0o600) == 0 else {
            Darwin.close(privFD)
            privClosed = true
            Darwin.close(pubFD)
            pubClosed = true
            _ = Darwin.unlinkat(stageFD, Self.keyFileName, 0)
            _ = Darwin.unlinkat(stageFD, pubFileName, 0)
            _ = Darwin.unlinkat(mimiDirFD, dirName, AT_REMOVEDIR)
            throw ConfigError.fileOperationFailed("设置暂存公钥权限失败：\(Self.posixErrorMessage())")
        }
        var pubInitSt = stat()
        guard Darwin.fstat(pubFD, &pubInitSt) == 0 else {
            Darwin.close(privFD)
            privClosed = true
            Darwin.close(pubFD)
            pubClosed = true
            _ = Darwin.unlinkat(stageFD, Self.keyFileName, 0)
            _ = Darwin.unlinkat(stageFD, pubFileName, 0)
            _ = Darwin.unlinkat(mimiDirFD, dirName, AT_REMOVEDIR)
            throw ConfigError.fileOperationFailed("无法记录暂存公钥 inode：\(Self.posixErrorMessage())")
        }
        let pubIdentity = FileIdentity(dev: pubInitSt.st_dev, ino: pubInitSt.st_ino)

        let artifact = StagedKeyArtifact(
            directoryName: dirName,
            directoryIdentity: dirIdentity,
            privateKeyIdentity: privIdentity,
            publicKeyIdentity: pubIdentity
        )

        // 3. 在写入私钥内容前，先将目录与文件 inode 及完整 WAL 意图持久化落盘。
        let intentState = ManagedState(
            stagedKeyArtifacts: [artifact],
            pendingTransaction: PendingTransaction(
                transactionID: UUID().uuidString,
                keyFingerprint: generatedKey.fingerprint,
                publicKeyBody: generatedKey.publicKeyBody,
                plannedAuthorizedKeyEntry: plannedAuthorizedKeyEntry,
                plannedAuthorizedKeyBody: generatedKey.publicKeyBody,
                authorizedKeyAddedLeadingNewline: plannedAuthorizedKeyAddedLeadingNewline,
                plannedHostAlias: Self.hostAlias,
                plannedUsername: plannedUsername,
                plannedMimiConfigVersion: plannedMimiConfigVersion,
                plannedKnownHostsVersion: nil,
                stagedKeyArtifact: artifact
            )
        )

        do {
            try saveManagedState(intentState, invokeHook: false)
        } catch {
            Darwin.close(privFD)
            privClosed = true
            Darwin.close(pubFD)
            pubClosed = true
            Darwin.close(stageFD)
            stageClosed = true
            _ = cleanupStagedKeyArtifact(artifact)
            throw error
        }

        // 4. 向已打开的独占文件描述符写入唯一一份私钥与公钥内容并抓取最终快照。
        do {
            try writeAllBytes(generatedKey.privateKeyData, to: privFD, label: Self.keyFileName)
            _ = Darwin.fsync(privFD)
            var privAfterSt = stat()
            guard Darwin.fstat(privFD, &privAfterSt) == 0, privIdentity.matches(privAfterSt) else {
                throw ConfigError.fileOperationFailed("无法确认暂存私钥快照。")
            }
            let privateSnapshot = FileSnapshot(
                exists: true,
                info: LStatInfo(stat: privAfterSt),
                data: generatedKey.privateKeyData
            )
            Darwin.close(privFD)
            privClosed = true

            try writeAllBytes(generatedKey.publicKeyData, to: pubFD, label: pubFileName)
            _ = Darwin.fsync(pubFD)
            var pubAfterSt = stat()
            guard Darwin.fstat(pubFD, &pubAfterSt) == 0, pubIdentity.matches(pubAfterSt) else {
                throw ConfigError.fileOperationFailed("无法确认暂存公钥快照。")
            }
            let publicSnapshot = FileSnapshot(
                exists: true,
                info: LStatInfo(stat: pubAfterSt),
                data: generatedKey.publicKeyData
            )
            Darwin.close(pubFD)
            pubClosed = true

            Darwin.close(stageFD)
            stageClosed = true

            guard Self.derivePublicKeyBody(fromOpenSSHPrivateKeyData: privateSnapshot.data) == generatedKey.publicKeyBody else {
                throw ConfigError.keyGenerationFailed("生成的私钥与公钥不匹配。")
            }

            let bundle = StagedKeyPairBundle(
                artifact: artifact,
                privateSnapshot: privateSnapshot,
                publicSnapshot: publicSnapshot,
                publicKeyBody: generatedKey.publicKeyBody,
                fingerprint: generatedKey.fingerprint
            )
            return (bundle, intentState)
        } catch {
            if !privClosed {
                Darwin.close(privFD)
                privClosed = true
            }
            if !pubClosed {
                Darwin.close(pubFD)
                pubClosed = true
            }
            if !stageClosed {
                Darwin.close(stageFD)
                stageClosed = true
            }
            if cleanupStagedKeyArtifact(artifact) {
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

    /// 严格按 inode 清理本次独占创建的 `~/.ssh/mimi/.mimi-keygen-*` 暂存目录与文件：
    /// - 目录 `(dev, ino)` 不匹配 `artifact.directoryIdentity` 时直接拒绝，绝不触碰其中任何文件；
    /// - 暂存私钥/公钥 `(dev, ino)` 不匹配已记录的 `privateKeyIdentity` / `publicKeyIdentity` 时拒绝删除，绝不误删同名替换文件；
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

        let stageFD = Darwin.openat(parentFD, dirName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        if stageFD < 0 {
            return errno == ENOENT
        }

        var stageSt = stat()
        guard Darwin.fstat(stageFD, &stageSt) == 0,
              (stageSt.st_mode & S_IFMT) == S_IFDIR,
              stageSt.st_uid == Darwin.geteuid(),
              artifact.directoryIdentity.matches(stageSt) else {
            Darwin.close(stageFD)
            return false
        }

        let targets: [(String, FileIdentity)] = [
            (Self.keyFileName, artifact.privateKeyIdentity),
            ("\(Self.keyFileName).pub", artifact.publicKeyIdentity),
        ]
        for (fileName, expectedIdentity) in targets {
            var fileSt = stat()
            if Darwin.fstatat(stageFD, fileName, &fileSt, AT_SYMLINK_NOFOLLOW) == 0 {
                guard (fileSt.st_mode & S_IFMT) == S_IFREG,
                      fileSt.st_uid == Darwin.geteuid(),
                      expectedIdentity.matches(fileSt) else {
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

        // 再次确认父目录中的该条目仍匹配本次独占创建的目录 inode 后执行 rmdir。
        var recheckSt = stat()
        if Darwin.fstatat(parentFD, dirName, &recheckSt, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (recheckSt.st_mode & S_IFMT) == S_IFDIR,
                  recheckSt.st_uid == Darwin.geteuid(),
                  artifact.directoryIdentity.matches(recheckSt) else {
                return false
            }
        } else {
            return errno == ENOENT
        }

        if Darwin.unlinkat(parentFD, dirName, AT_REMOVEDIR) == 0 || errno == ENOENT {
            return true
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
            expectedFileIdentity: bundle.artifact.privateKeyIdentity,
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
            expectedFileIdentity: bundle.artifact.publicKeyIdentity,
            stagedSnapshot: bundle.publicSnapshot,
            to: publicKeyURL,
            label: "\(Self.keyFileName).pub"
        )
        rollback.createdPublicKey = true
        rollback.createdPublicKeySnapshot = publishedPublicSnapshot

        return KeyMaterial(publicKeyBody: bundle.publicKeyBody, fingerprint: bundle.fingerprint)
    }

    func verifyOwnedKeyPair(expectedBody: String, expectedFingerprint: String) -> Bool {
        guard let pubBody = readPublicKeyBody(),
              pubBody == expectedBody,
              Self.computeOpenSSHSHA256Fingerprint(fromKeyBody: pubBody) == expectedFingerprint else {
            return false
        }
        guard let derivedBody = derivePublicKeyBodyFromPrivateKey(),
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
    ) -> Bool {
        if privateExists {
            guard let derived = derivePublicKeyBodyFromPrivateKey(),
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

    func removeOwnedKeyFilesIfVerified(state: ManagedState) throws -> Bool {
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
               let derived = Self.derivePublicKeyBody(fromOpenSSHPrivateKeyData: snapshot.data),
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

    private func derivePublicKeyBodyFromPrivateKey() -> String? {
        guard let snapshot = try? captureSnapshot(of: privateKeyURL, label: Self.keyFileName), snapshot.exists else {
            return nil
        }
        return Self.derivePublicKeyBody(fromOpenSSHPrivateKeyData: snapshot.data)
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
