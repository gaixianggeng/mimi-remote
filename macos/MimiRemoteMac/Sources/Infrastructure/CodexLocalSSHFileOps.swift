import Darwin
import Foundation

extension CodexLocalSSHConfigurator {
    // MARK: - Safe POSIX File Operations, Tri-State Probing & Locking

    struct LStatInfo: Equatable {
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

        init(
            mode: mode_t,
            uid: uid_t,
            dev: dev_t,
            ino: ino_t,
            size: off_t,
            mtimeSec: Int,
            mtimeNsec: Int
        ) {
            self.mode = mode
            self.uid = uid
            self.dev = dev
            self.ino = ino
            self.size = size
            self.mtimeSec = mtimeSec
            self.mtimeNsec = mtimeNsec
        }

        init(stat st: stat) {
            self.mode = st.st_mode
            self.uid = st.st_uid
            self.dev = st.st_dev
            self.ino = st.st_ino
            self.size = st.st_size
            self.mtimeSec = st.st_mtimespec.tv_sec
            self.mtimeNsec = st.st_mtimespec.tv_nsec
        }
    }

    /// 明确区分「确实缺失（仅 ENOENT）」与「存在」；任何其他 errno（如 EACCES、ENOTDIR、ELOOP）必须显式抛错，绝不静默降级为缺失。
    enum PathProbe: Equatable {
        case missing
        case present(LStatInfo)
    }

    struct FileSnapshot: Equatable {
        let exists: Bool
        let info: LStatInfo?
        let data: Data

        var mode: mode_t? { info?.permissions }

        static let missing = FileSnapshot(exists: false, info: nil, data: Data())
    }

    func probePath(_ url: URL, label: String) throws -> PathProbe {
        var st = stat()
        if Darwin.lstat(url.path, &st) == 0 {
            return .present(LStatInfo(stat: st))
        }
        let err = errno
        if err == ENOENT {
            return .missing
        }
        throw ConfigError.fileOperationFailed("无法检查 \(label)：\(Self.posixErrorMessage(err))")
    }

    @discardableResult
    func validateDirectoryIfPresent(_ url: URL, label: String) throws -> LStatInfo? {
        switch try probePath(url, label: label) {
        case .missing:
            return nil
        case .present(let info):
            if info.isSymlink {
                throw ConfigError.unsafeFileSystemTarget("\(label) 是符号链接。")
            }
            guard info.isDirectory else {
                throw ConfigError.unsafeFileSystemTarget("\(label) 不是普通目录。")
            }
            guard info.uid == Darwin.geteuid() else {
                throw ConfigError.unsafeFileSystemTarget("\(label) 不属于当前用户。")
            }
            return info
        }
    }

    @discardableResult
    func validateRegularFileIfPresent(_ url: URL, label: String) throws -> LStatInfo? {
        switch try probePath(url, label: label) {
        case .missing:
            return nil
        case .present(let info):
            if info.isSymlink {
                throw ConfigError.unsafeFileSystemTarget("\(label) 是符号链接。")
            }
            guard info.isRegularFile else {
                throw ConfigError.unsafeFileSystemTarget("\(label) 不是普通文件。")
            }
            guard info.uid == Darwin.geteuid() else {
                throw ConfigError.unsafeFileSystemTarget("\(label) 不属于当前用户。")
            }
            return info
        }
    }

    func validateStateDirectoryAndStateFile() throws {
        let stateDir = stateFileURL.deletingLastPathComponent()
        try validateDirectoryIfPresent(stateDir, label: stateDir.lastPathComponent)
        try validateRegularFileIfPresent(stateFileURL, label: stateFileURL.lastPathComponent)
    }

    func validateKnownHostsFile() throws {
        try validateRegularFileIfPresent(knownHostsURL, label: knownHostsURL.lastPathComponent)
    }

    func validateStateDirectoryAndFile() throws {
        try validateStateDirectoryAndStateFile()
        try validateKnownHostsFile()
    }

    func ensureSSHDirectory() throws -> Bool {
        if let info = try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh") {
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

    func ensureStateDirectory() throws {
        let dir = stateFileURL.deletingLastPathComponent()
        if let info = try validateDirectoryIfPresent(dir, label: dir.lastPathComponent) {
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
    func tightenExistingDirectoryIfNeeded(_ url: URL, currentMode: mode_t) throws {
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

    func tightenExistingFileIfNeeded(_ url: URL, currentMode: mode_t?, maxMode: mode_t) throws {
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

    func captureSnapshot(of url: URL, label: String? = nil) throws -> FileSnapshot {
        let effectiveLabel = label ?? url.lastPathComponent
        guard try validateRegularFileIfPresent(url, label: effectiveLabel) != nil else {
            return .missing
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT { return .missing }
            if err == ELOOP {
                throw ConfigError.unsafeFileSystemTarget("\(effectiveLabel) 是符号链接。")
            }
            throw ConfigError.fileOperationFailed("无法读取 \(effectiveLabel)：\(Self.posixErrorMessage(err))")
        }
        defer { Darwin.close(fd) }
        return try captureSnapshot(fromFD: fd, label: effectiveLabel)
    }

    /// 在指定已校验父目录描述符下通过 `openat(O_NOFOLLOW)` 抓取快照，避免路径重解析窗口。
    func captureSnapshot(inDirectoryFD dirFD: Int32, fileName: String, label: String) throws -> FileSnapshot {
        let fd = Darwin.openat(dirFD, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT { return .missing }
            if err == ELOOP {
                throw ConfigError.unsafeFileSystemTarget("\(label) 是符号链接。")
            }
            throw ConfigError.fileOperationFailed("无法读取 \(label)：\(Self.posixErrorMessage(err))")
        }
        defer { Darwin.close(fd) }
        return try captureSnapshot(fromFD: fd, label: label)
    }

    private func captureSnapshot(fromFD fd: Int32, label: String) throws -> FileSnapshot {
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            throw ConfigError.fileOperationFailed("无法检查 \(label)：\(Self.posixErrorMessage())")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw ConfigError.unsafeFileSystemTarget("\(label) 不是普通文件。")
        }
        guard st.st_uid == Darwin.geteuid() else {
            throw ConfigError.unsafeFileSystemTarget("\(label) 不属于当前用户。")
        }

        let data = try readAllBytes(from: fd, label: label)
        return FileSnapshot(exists: true, info: LStatInfo(stat: st), data: data)
    }

    func readRegularFileDataIfPresent(_ url: URL, label: String? = nil) throws -> Data? {
        let snapshot = try captureSnapshot(of: url, label: label)
        return snapshot.exists ? snapshot.data : nil
    }

    static func snapshotsMatch(_ expected: FileSnapshot, _ current: FileSnapshot) -> Bool {
        guard expected.exists == current.exists else { return false }
        guard expected.exists else { return true }
        return expected.info?.dev == current.info?.dev &&
            expected.info?.ino == current.info?.ino &&
            expected.info?.size == current.info?.size &&
            expected.info?.mtimeSec == current.info?.mtimeSec &&
            expected.info?.mtimeNsec == current.info?.mtimeNsec &&
            expected.data == current.data
    }

    func verifySnapshotUnchanged(_ expected: FileSnapshot, current: FileSnapshot, label: String) throws {
        if expected.exists != current.exists {
            throw ConfigError.concurrentModification("\(label) 在操作期间被创建或删除。")
        }
        guard expected.exists else { return }
        guard Self.snapshotsMatch(expected, current) else {
            throw ConfigError.concurrentModification("\(label) 在写入前已被其他进程修改。")
        }
    }

    @discardableResult
    func createExclusiveBackup(of originalData: Data) throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8)
        let backupURL = sshDirectory.appendingPathComponent("config.before-mimi.\(timestamp)-\(suffix).bak")
        _ = try publishExclusiveNewFile(
            originalData,
            to: backupURL,
            mode: 0o600,
            label: backupURL.lastPathComponent,
            invokeHook: false
        )
        return backupURL
    }

    // MARK: - Stage-Then-Exclusive-Publish & Quarantine-Then-Verify-Then-Delete

    private func openVerifiedParentDirectoryFD(for url: URL, label: String) throws -> Int32 {
        let parentDir = url.deletingLastPathComponent()
        let dirFD = Darwin.open(parentDir.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard dirFD >= 0 else {
            let err = errno
            if err == ELOOP {
                throw ConfigError.unsafeFileSystemTarget("\(parentDir.lastPathComponent) 是符号链接。")
            }
            throw ConfigError.fileOperationFailed("无法打开目录检查 \(label)：\(Self.posixErrorMessage(err))")
        }
        var dirSt = stat()
        guard Darwin.fstat(dirFD, &dirSt) == 0,
              (dirSt.st_mode & S_IFMT) == S_IFDIR,
              dirSt.st_uid == Darwin.geteuid() else {
            Darwin.close(dirFD)
            throw ConfigError.unsafeFileSystemTarget(parentDir.lastPathComponent)
        }
        return dirFD
    }

    /// 以禁止覆盖方式将已校验的临时密钥文件发布到最终路径（优先使用原子 `link`，遇已有同名文件报错绝不覆盖）。
    /// `Darwin.link` 直接绑定到独占临时文件的同一 inode，返回该已校验快照，避免发布后按目标路径重抓快照的竞态窗口。
    func publishStagedKeyFile(
        from stagedURL: URL,
        stagedSnapshot: FileSnapshot,
        to targetURL: URL,
        mode: mode_t,
        label: String
    ) throws -> FileSnapshot {
        if let beforeAtomicCommit {
            try beforeAtomicCommit(targetURL)
        }
        if Darwin.link(stagedURL.path, targetURL.path) == 0 {
            return stagedSnapshot
        }
        let err = errno
        if err == EEXIST {
            throw ConfigError.conflictingKeyFiles("发布期间出现同名文件 \(label)，已停止且未覆盖。")
        }
        if err == EXDEV || err == ENOTSUP || err == EPERM {
            return try publishExclusiveNewFile(stagedSnapshot.data, to: targetURL, mode: mode, label: label, invokeHook: false)
        }
        throw ConfigError.fileOperationFailed("发布 \(label) 失败：\(Self.posixErrorMessage(err))")
    }

    /// 先在目标父目录内创建独占 `0700` 暂存目录写盘并从已落盘描述符记录快照，再原子无覆盖发布到目标路径。
    /// 写入/改权/同步失败绝不会在目标路径创建半成品，也绝不会按目标路径执行 `unlink`。
    func publishExclusiveNewFile(
        _ data: Data,
        to targetURL: URL,
        mode: mode_t,
        label: String,
        invokeHook: Bool = true
    ) throws -> FileSnapshot {
        let parentFD = try openVerifiedParentDirectoryFD(for: targetURL, label: label)
        defer { Darwin.close(parentFD) }

        let stageDirName = ".mimi-stage-\(UUID().uuidString)"
        guard Darwin.mkdirat(parentFD, stageDirName, 0o700) == 0 else {
            throw ConfigError.fileOperationFailed("无法创建独占暂存目录发布 \(label)：\(Self.posixErrorMessage())")
        }
        let stageDirFD = Darwin.openat(parentFD, stageDirName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard stageDirFD >= 0 else {
            _ = Darwin.unlinkat(parentFD, stageDirName, AT_REMOVEDIR)
            throw ConfigError.fileOperationFailed("无法校验暂存目录发布 \(label)：\(Self.posixErrorMessage())")
        }
        _ = Darwin.fchmod(stageDirFD, 0o700)

        var itemRemainingInStage = false
        defer {
            if itemRemainingInStage {
                _ = Darwin.unlinkat(stageDirFD, "item", 0)
            }
            Darwin.close(stageDirFD)
            _ = Darwin.unlinkat(parentFD, stageDirName, AT_REMOVEDIR)
        }

        let fd = Darwin.openat(stageDirFD, "item", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw ConfigError.fileOperationFailed("无法在独占暂存目录创建 \(label)：\(Self.posixErrorMessage())")
        }
        itemRemainingInStage = true
        var closed = false
        defer {
            if !closed { Darwin.close(fd) }
        }

        guard Darwin.fchmod(fd, 0o600) == 0 else {
            throw ConfigError.fileOperationFailed("设置 \(label) 权限失败：\(Self.posixErrorMessage())")
        }
        try writeAllBytes(data, to: fd, label: label)
        if mode != 0o600 {
            guard Darwin.fchmod(fd, mode) == 0 else {
                throw ConfigError.fileOperationFailed("设置 \(label) 最终权限失败：\(Self.posixErrorMessage())")
            }
        }
        _ = Darwin.fsync(fd)
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            throw ConfigError.fileOperationFailed("无法记录 \(label) 发布快照：\(Self.posixErrorMessage())")
        }
        let stagedSnapshot = FileSnapshot(exists: true, info: LStatInfo(stat: st), data: data)
        Darwin.close(fd)
        closed = true

        if invokeHook, let beforeAtomicCommit {
            try beforeAtomicCommit(targetURL)
        }

        let targetName = targetURL.lastPathComponent
        if Darwin.linkat(stageDirFD, "item", parentFD, targetName, 0) == 0 {
            return stagedSnapshot
        }
        let linkErr = errno
        if linkErr == EEXIST {
            throw ConfigError.conflictingKeyFiles("目标路径已存在同名文件 \(label)，已停止且未覆盖。")
        }
        if linkErr == ENOTSUP || linkErr == EXDEV || linkErr == EPERM {
            if Darwin.renameatx_np(stageDirFD, "item", parentFD, targetName, UInt32(RENAME_EXCL)) == 0 {
                itemRemainingInStage = false
                return stagedSnapshot
            }
            let renameErr = errno
            if renameErr == EEXIST {
                throw ConfigError.conflictingKeyFiles("目标路径已存在同名文件 \(label)，已停止且未覆盖。")
            }
            throw ConfigError.fileOperationFailed("原子发布 \(label) 失败：\(Self.posixErrorMessage(renameErr))")
        }
        throw ConfigError.fileOperationFailed("原子发布 \(label) 失败：\(Self.posixErrorMessage(linkErr))")
    }

    /// 隔离-核验-删除：先做无破坏预检，再原子移入独占 `0700` 隔离目录，在隔离目录内核验 `(dev, ino, size, mtime, data)` 完全一致后再删除。
    /// 若隔离后发现不匹配或非普通文件，使用 `RENAME_EXCL` 无覆盖恢复回原路径；若原路径已出现新文件，保留隔离项并报错，绝不误删同名替换文件。
    func removeFileMatchingSnapshot(
        _ url: URL,
        expectedSnapshot: FileSnapshot,
        label: String,
        invokeHook: Bool
    ) throws {
        guard expectedSnapshot.exists, let expectedInfo = expectedSnapshot.info else { return }
        if invokeHook, let beforeAtomicCommit {
            try beforeAtomicCommit(url)
        }

        let dirFD = try openVerifiedParentDirectoryFD(for: url, label: label)
        defer { Darwin.close(dirFD) }

        let fileName = url.lastPathComponent
        var preSt = stat()
        if Darwin.fstatat(dirFD, fileName, &preSt, AT_SYMLINK_NOFOLLOW) != 0 {
            let err = errno
            if err == ENOENT { return }
            throw ConfigError.fileOperationFailed("无法检查待删文件 \(label)：\(Self.posixErrorMessage(err))")
        }
        let preInfo = LStatInfo(stat: preSt)
        if preInfo.isSymlink || !preInfo.isRegularFile || preInfo.uid != Darwin.geteuid() {
            throw ConfigError.conflictingKeyFiles("文件 \(label) 已被替换为符号链接、非常规文件或属主变化，已保留未删除。")
        }
        guard preInfo.dev == expectedInfo.dev,
              preInfo.ino == expectedInfo.ino,
              preInfo.size == expectedInfo.size,
              preInfo.mtimeSec == expectedInfo.mtimeSec,
              preInfo.mtimeNsec == expectedInfo.mtimeNsec else {
            throw ConfigError.conflictingKeyFiles("文件 \(label) 在校验后被修改或替换，已保留未删除。")
        }

        // 测试钩子：模拟预检通过后、进入隔离删除前瞬间被替换为同名文件。
        if invokeHook, let afterVerifyBeforeDelete {
            try afterVerifyBeforeDelete(url)
        }

        try quarantineVerifyAndUnlink(
            inParentFD: dirFD,
            parentDir: url.deletingLastPathComponent(),
            fileName: fileName,
            label: label,
            verify: { qDirFD in
                let isolated = try captureSnapshot(inDirectoryFD: qDirFD, fileName: "item", label: label)
                guard isolated.exists, Self.snapshotsMatch(expectedSnapshot, isolated) else {
                    throw ConfigError.conflictingKeyFiles("文件 \(label) 在隔离核验时与预期快照不匹配，已保留未删除。")
                }
            }
        )
    }

    /// 同样通过「隔离-核验-删除」清理普通自有文件（如状态文件与专用 known_hosts），绝不直接按名称 `unlink`。
    func removeRegularFileIfPresent(_ url: URL, label: String? = nil) throws {
        let effectiveLabel = label ?? url.lastPathComponent
        guard try validateRegularFileIfPresent(url, label: effectiveLabel) != nil else { return }

        let dirFD = try openVerifiedParentDirectoryFD(for: url, label: effectiveLabel)
        defer { Darwin.close(dirFD) }

        let fileName = url.lastPathComponent
        try quarantineVerifyAndUnlink(
            inParentFD: dirFD,
            parentDir: url.deletingLastPathComponent(),
            fileName: fileName,
            label: effectiveLabel,
            verify: { qDirFD in
                var isoSt = stat()
                guard Darwin.fstatat(qDirFD, "item", &isoSt, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw ConfigError.fileOperationFailed("无法核验已隔离的 \(effectiveLabel)：\(Self.posixErrorMessage())")
                }
                let isoInfo = LStatInfo(stat: isoSt)
                if isoInfo.isSymlink {
                    throw ConfigError.unsafeFileSystemTarget("\(effectiveLabel) 是符号链接。")
                }
                guard isoInfo.isRegularFile else {
                    throw ConfigError.unsafeFileSystemTarget("\(effectiveLabel) 不是普通文件。")
                }
                guard isoInfo.uid == Darwin.geteuid() else {
                    throw ConfigError.unsafeFileSystemTarget("\(effectiveLabel) 不属于当前用户。")
                }
            }
        )
    }

    /// 原子移入独占 `0700` 隔离目录 -> 在隔离目录内执行 `verify(qDirFD)` -> 通过才删除；失败则 `RENAME_EXCL` 无覆盖恢复。
    private func quarantineVerifyAndUnlink(
        inParentFD dirFD: Int32,
        parentDir: URL,
        fileName: String,
        label: String,
        verify: (Int32) throws -> Void
    ) throws {
        let qDirName = ".mimi-quarantine-\(UUID().uuidString)"
        guard Darwin.mkdirat(dirFD, qDirName, 0o700) == 0 else {
            throw ConfigError.fileOperationFailed("无法创建独占隔离目录删除 \(label)：\(Self.posixErrorMessage())")
        }
        let qDirFD = Darwin.openat(dirFD, qDirName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard qDirFD >= 0 else {
            _ = Darwin.unlinkat(dirFD, qDirName, AT_REMOVEDIR)
            throw ConfigError.fileOperationFailed("无法打开隔离目录删除 \(label)：\(Self.posixErrorMessage())")
        }
        _ = Darwin.fchmod(qDirFD, 0o700)

        var keepQuarantineDir = false
        defer {
            Darwin.close(qDirFD)
            if !keepQuarantineDir {
                _ = Darwin.unlinkat(dirFD, qDirName, AT_REMOVEDIR)
            }
        }

        if Darwin.renameatx_np(dirFD, fileName, qDirFD, "item", UInt32(RENAME_EXCL)) != 0 {
            let err = errno
            if err == ENOENT { return }
            throw ConfigError.fileOperationFailed("隔离待删文件 \(label) 失败：\(Self.posixErrorMessage(err))")
        }

        do {
            try verify(qDirFD)
        } catch {
            // 核验未通过：原子无覆盖恢复回原路径；若原路径已被新文件占用，保留在隔离目录内绝不覆盖或删除。
            if Darwin.renameatx_np(qDirFD, "item", dirFD, fileName, UInt32(RENAME_EXCL)) != 0 {
                let restoreErr = errno
                keepQuarantineDir = true
                let preservedPath = parentDir
                    .appendingPathComponent(qDirName, isDirectory: true)
                    .appendingPathComponent("item", isDirectory: false)
                    .path
                let detail = "文件 \(label) 隔离核验不匹配且恢复原路径冲突（\(Self.posixErrorMessage(restoreErr))），为避免覆盖已将其完整保留于 \(preservedPath)。"
                if case ConfigError.conflictingKeyFiles = error {
                    throw ConfigError.conflictingKeyFiles(detail)
                }
                throw ConfigError.fileOperationFailed(detail)
            }
            throw error
        }

        guard Darwin.unlinkat(qDirFD, "item", 0) == 0 else {
            let err = errno
            if err == ENOENT { return }
            keepQuarantineDir = true
            throw ConfigError.fileOperationFailed("删除已核验的隔离文件 \(label) 失败：\(Self.posixErrorMessage(err))")
        }
    }

    @discardableResult
    func writeExclusiveTempFile(_ data: Data, to url: URL, mode: mode_t) throws -> FileSnapshot {
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
            var st = stat()
            guard Darwin.fstat(fd, &st) == 0 else {
                throw ConfigError.fileOperationFailed("读取临时文件快照失败：\(Self.posixErrorMessage())")
            }
            let snapshot = FileSnapshot(exists: true, info: LStatInfo(stat: st), data: data)
            Darwin.close(fd)
            closed = true
            return snapshot
        } catch {
            if !closed {
                Darwin.close(fd)
                closed = true
            }
            _ = Darwin.unlink(url.path)
            throw error
        }
    }

    @discardableResult
    func writeFileAtomically(
        _ data: Data,
        to targetURL: URL,
        mode: mode_t,
        expectedSnapshot: FileSnapshot?,
        label: String,
        invokeHook: Bool = true
    ) throws -> FileSnapshot {
        let tempURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).mimi-\(UUID().uuidString).tmp")
        let writtenSnapshot = try writeExclusiveTempFile(data, to: tempURL, mode: mode)
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
            let current = try captureSnapshot(of: targetURL, label: label)
            try verifySnapshotUnchanged(expectedSnapshot, current: current, label: label)
        }

        guard Darwin.rename(tempURL.path, targetURL.path) == 0 else {
            throw ConfigError.fileOperationFailed("原子替换 \(label) 失败：\(Self.posixErrorMessage())")
        }
        committed = true
        return writtenSnapshot
    }

    func loadManagedState() throws -> ManagedState? {
        guard let data = try readRegularFileDataIfPresent(stateFileURL, label: stateFileURL.lastPathComponent) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ManagedState.self, from: data)
        } catch {
            throw ConfigError.fileOperationFailed("读取 Mimi SSH 状态文件失败：\(error.localizedDescription)")
        }
    }

    func saveManagedState(_ state: ManagedState, invokeHook: Bool = false) throws {
        try ensureStateDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw ConfigError.fileOperationFailed("序列化 Mimi SSH 状态失败：\(error.localizedDescription)")
        }
        _ = try writeFileAtomically(
            data,
            to: stateFileURL,
            mode: 0o600,
            expectedSnapshot: nil,
            label: stateFileURL.lastPathComponent,
            invokeHook: invokeHook
        )
    }

    func readPublicKeyBody() -> String? {
        guard let data = try? readRegularFileDataIfPresent(publicKeyURL, label: "\(Self.keyFileName).pub"),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Self.extractPublicKeyBody(from: trimmed)
    }

    func decodeUTF8(_ data: Data, label: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError.fileOperationFailed("\(label) 不是有效的 UTF-8 文本。")
        }
        return text
    }

    func readAllBytes(from fd: Int32, label: String, maxBytes: Int = 8 * 1024 * 1024) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if data.count + count > maxBytes {
                    throw ConfigError.fileOperationFailed("\(label) 体积超过安全读取上限。")
                }
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

    func writeAllBytes(_ data: Data, to fd: Int32, label: String) throws {
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

    static func posixErrorMessage(_ code: Int32 = errno) -> String {
        String(cString: Darwin.strerror(code))
    }

    // MARK: - Faithful Frozen Evaluation Snapshot (Strict Include Freezing)

    struct MaterializedSSHConfig: Sendable {
        let tempDirectory: URL
        let configFileURL: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    /// 冻结当前 `~/.ssh/config`（缺失视为空）与系统 `ssh_config`（含相对 `Include` 解析基准），用于只读探测和验连绑定同一份快照。
    func materializeCurrentSSHConfigForEvaluation(includeSystemConfig: Bool = true) throws -> MaterializedSSHConfig {
        let userText: String
        if let data = try readRegularFileDataIfPresent(sshConfigURL, label: "~/.ssh/config") {
            userText = try decodeUTF8(data, label: "~/.ssh/config")
        } else {
            userText = ""
        }
        return try materializeEvaluationSSHConfig(userConfigText: userText, includeSystemConfig: includeSystemConfig)
    }

    /// 在独占 `0700` 临时目录中生成自包含的 SSH 评估快照：
    /// - 忠实冻结用户与系统配置及其所有 OpenSSH 可读取的 `Include`（含符号链接指向的普通文件与系统目录相对 `Include`）；
    /// - 对任何无法忠实冻结的 `Include`（含 `%` 动态占位符、`${VAR}` 环境变量、`~otheruser`、不可读、非 UTF-8、循环引用或超深嵌套）明确报错，绝不静默丢弃。
    func materializeEvaluationSSHConfig(
        userConfigText: String,
        includeSystemConfig: Bool
    ) throws -> MaterializedSSHConfig {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(".mimi-ssh-eval-\(UUID().uuidString)", isDirectory: true)
        guard Darwin.mkdir(tempDir.path, 0o700) == 0 else {
            throw ConfigError.fileOperationFailed("无法创建 SSH 评估快照目录：\(Self.posixErrorMessage())")
        }
        let dirFD = Darwin.open(tempDir.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard dirFD >= 0 else {
            _ = Darwin.rmdir(tempDir.path)
            throw ConfigError.fileOperationFailed("无法校验 SSH 评估快照目录：\(Self.posixErrorMessage())")
        }
        _ = Darwin.fchmod(dirFD, 0o700)
        Darwin.close(dirFD)

        do {
            var counter = 0
            var activeStack: Set<String> = []
            var materializedUserText = try rewriteSSHConfigIncludes(
                text: userConfigText,
                baseDirectory: sshDirectory,
                tempDirectory: tempDir,
                counter: &counter,
                depth: 0,
                activeStack: &activeStack
            )

            if includeSystemConfig,
               let sysPath = systemSSHConfigPath,
               !sysPath.isEmpty {
                let sysURL = URL(fileURLWithPath: sysPath)
                if let sysData = try readEvaluationRegularFileIfPresent(at: sysURL) {
                    guard let sysText = String(data: sysData, encoding: .utf8) else {
                        throw ConfigError.effectiveConfigConflict("系统 SSH 配置 \(sysPath) 不是有效的 UTF-8 文本，无法忠实冻结。")
                    }
                    let sysBaseDir = sysURL.deletingLastPathComponent()
                    let sysCanonical = sysURL.resolvingSymlinksInPath().standardizedFileURL.path
                    var sysStack: Set<String> = [sysCanonical]
                    let materializedSysText = try rewriteSSHConfigIncludes(
                        text: sysText,
                        baseDirectory: sysBaseDir,
                        tempDirectory: tempDir,
                        counter: &counter,
                        depth: 1,
                        activeStack: &sysStack
                    )
                    counter += 1
                    let sysSnapshotURL = tempDir.appendingPathComponent("system-\(counter).conf")
                    try writeExclusiveTempFile(Data(materializedSysText.utf8), to: sysSnapshotURL, mode: 0o600)
                    if !materializedUserText.isEmpty && materializedUserText.utf8.last != 0x0A {
                        materializedUserText.append("\n")
                    }
                    materializedUserText.append("Host *\nInclude \"\(sysSnapshotURL.path)\"\n")
                }
            }

            let rootConfigURL = tempDir.appendingPathComponent("root.conf")
            try writeExclusiveTempFile(Data(materializedUserText.utf8), to: rootConfigURL, mode: 0o600)
            return MaterializedSSHConfig(tempDirectory: tempDir, configFileURL: rootConfigURL)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    private func rewriteSSHConfigIncludes(
        text: String,
        baseDirectory: URL,
        tempDirectory: URL,
        counter: inout Int,
        depth: Int,
        activeStack: inout Set<String>
    ) throws -> String {
        guard depth <= 16 else {
            throw ConfigError.effectiveConfigConflict("SSH 配置 Include 嵌套层级超过 16 层，无法忠实冻结。")
        }
        var output = ""
        for slice in Self.rawLineSlices(in: text) {
            let rawLine = Self.utf8Substring(text, range: slice.contentRange)
            let tokens = Self.tokenizeSSHConfigLine(rawLine)
            if let keyword = tokens.first?.lowercased(), keyword == "include" {
                guard tokens.count >= 2 else {
                    throw ConfigError.effectiveConfigConflict("SSH 配置包含缺少路径参数的 Include 指令，无法忠实冻结。")
                }
                guard !Self.hasUnclosedQuote(inSSHConfigLine: rawLine) else {
                    throw ConfigError.effectiveConfigConflict("SSH 配置 Include 指令引号未闭合，无法忠实冻结。")
                }
                var rewrittenPaths: [String] = []
                for pattern in tokens.dropFirst() {
                    let matchedPaths = try Self.resolveGlobPathsStrict(
                        pattern: pattern,
                        baseDirectory: baseDirectory,
                        homeDirectory: homeDirectory
                    )
                    for matchedPath in matchedPaths {
                        var st = stat()
                        guard Darwin.fstatat(AT_FDCWD, matchedPath, &st, 0) == 0 else {
                            throw ConfigError.effectiveConfigConflict("无法读取 SSH Include 目标 \(matchedPath)：\(Self.posixErrorMessage())")
                        }
                        if (st.st_mode & S_IFMT) == S_IFDIR {
                            // OpenSSH 在展开通配符 Include（如 Include ssh_config.d/*）时会跳过子目录。
                            continue
                        }
                        guard (st.st_mode & S_IFMT) == S_IFREG else {
                            throw ConfigError.effectiveConfigConflict("SSH Include 目标 \(matchedPath) 不是普通文件，无法忠实冻结。")
                        }
                        let matchedURL = URL(fileURLWithPath: matchedPath)
                        let canonical = matchedURL.resolvingSymlinksInPath().standardizedFileURL.path
                        guard !activeStack.contains(canonical) else {
                            throw ConfigError.effectiveConfigConflict("检测到循环 SSH Include（\(matchedPath)），无法忠实冻结。")
                        }
                        let childData = try readEvaluationRegularFileRequired(at: matchedURL)
                        guard let childText = String(data: childData, encoding: .utf8) else {
                            throw ConfigError.effectiveConfigConflict("SSH Include 文件 \(matchedPath) 不是有效的 UTF-8 文本，无法忠实冻结。")
                        }
                        activeStack.insert(canonical)
                        defer { activeStack.remove(canonical) }
                        let childRewritten = try rewriteSSHConfigIncludes(
                            text: childText,
                            baseDirectory: baseDirectory,
                            tempDirectory: tempDirectory,
                            counter: &counter,
                            depth: depth + 1,
                            activeStack: &activeStack
                        )
                        counter += 1
                        let childURL = tempDirectory.appendingPathComponent("inc-\(counter).conf")
                        try writeExclusiveTempFile(Data(childRewritten.utf8), to: childURL, mode: 0o600)
                        rewrittenPaths.append("\"\(childURL.path)\"")
                    }
                }
                if rewrittenPaths.isEmpty {
                    output.append("# Include (no matches)\n")
                } else {
                    output.append("Include \(rewrittenPaths.joined(separator: " "))\n")
                }
            } else {
                output.append(rawLine)
                output.append("\n")
            }
        }
        return output
    }

    /// 只读评估读取：严格匹配 OpenSSH 读取行为（允许跟随符号链接读取普通文件，支持用户与系统属主，但拒绝非常规文件与不可读目标，绝不静默丢弃）。
    func readEvaluationRegularFileIfPresent(at url: URL) throws -> Data? {
        var st = stat()
        if Darwin.fstatat(AT_FDCWD, url.path, &st, 0) != 0 {
            let err = errno
            if err == ENOENT {
                // 若路径本身是悬空符号链接，lstat 会成功，不应误判为缺失。
                var lst = stat()
                if Darwin.lstat(url.path, &lst) == 0 {
                    throw ConfigError.effectiveConfigConflict("SSH 评估配置 \(url.path) 为悬空符号链接，无法忠实读取。")
                }
                return nil
            }
            throw ConfigError.effectiveConfigConflict("无法读取 SSH 配置 \(url.path)：\(Self.posixErrorMessage(err))")
        }
        return try readEvaluationRegularFileRequired(at: url)
    }

    func readEvaluationRegularFileRequired(at url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            throw ConfigError.effectiveConfigConflict("无法打开 SSH Include 文件 \(url.path)：\(Self.posixErrorMessage())")
        }
        defer { Darwin.close(fd) }
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            throw ConfigError.effectiveConfigConflict("无法检查 SSH Include 文件 \(url.path)：\(Self.posixErrorMessage())")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw ConfigError.effectiveConfigConflict("SSH Include 文件 \(url.path) 不是普通文件，无法忠实冻结。")
        }
        do {
            return try readAllBytes(from: fd, label: url.lastPathComponent, maxBytes: 4 * 1024 * 1024)
        } catch {
            throw ConfigError.effectiveConfigConflict("读取 SSH Include 文件 \(url.path) 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Concurrency Serialization (In-process + Cross-process Advisory Lock)

    func withSerializedLock<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
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
