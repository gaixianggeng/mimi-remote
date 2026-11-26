import Darwin
import Foundation

extension CodexLocalSSHConfigurator {
    // MARK: - Safe POSIX File Operations & Locking

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
    }

    struct FileSnapshot: Equatable {
        let exists: Bool
        let info: LStatInfo?
        let data: Data

        var mode: mode_t? { info?.permissions }

        static let missing = FileSnapshot(exists: false, info: nil, data: Data())
    }

    func lstatInfo(for url: URL) -> LStatInfo? {
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

    func validateDirectoryIfPresent(_ url: URL, label: String) throws {
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

    func validateRegularFileIfPresent(_ url: URL, label: String) throws {
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

    func validateStateDirectoryAndFile() throws {
        let stateDir = stateFileURL.deletingLastPathComponent()
        try validateDirectoryIfPresent(stateDir, label: stateDir.lastPathComponent)
        try validateRegularFileIfPresent(stateFileURL, label: stateFileURL.lastPathComponent)
        try validateRegularFileIfPresent(knownHostsURL, label: knownHostsURL.lastPathComponent)
    }

    func ensureKnownHostsFile(rollback: inout RollbackRecord) throws {
        try ensureStateDirectory()
        try validateRegularFileIfPresent(knownHostsURL, label: knownHostsURL.lastPathComponent)
        let snapshot = try captureSnapshot(of: knownHostsURL)
        if snapshot.exists {
            rollback.originalKnownHostsData = snapshot.data
            rollback.originalKnownHostsMode = snapshot.mode
            try tightenExistingFileIfNeeded(knownHostsURL, currentMode: snapshot.mode, maxMode: 0o600)
            return
        }
        _ = try publishExclusiveNewFile(Data(), to: knownHostsURL, mode: 0o600, label: knownHostsURL.lastPathComponent, invokeHook: false)
        rollback.createdKnownHostsFile = true
    }

    func ensureSSHDirectory() throws -> Bool {
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

    func ensureStateDirectory() throws {
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

    func captureSnapshot(of url: URL) throws -> FileSnapshot {
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

    func verifySnapshotUnchanged(_ expected: FileSnapshot, current: FileSnapshot, label: String) throws {
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

    @discardableResult
    func createExclusiveBackup(of originalData: Data) throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8)
        let backupURL = sshDirectory.appendingPathComponent("config.before-mimi.\(timestamp)-\(suffix).bak")
        try writeExclusiveTempFile(originalData, to: backupURL, mode: 0o600)
        return backupURL
    }

    /// 以禁止覆盖方式将已校验的临时密钥文件发布到最终路径（优先使用原子 `link`，遇已有同名文件报错绝不覆盖）。
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
            return try captureSnapshot(of: targetURL)
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

    /// 以 `O_CREAT | O_EXCL | O_NOFOLLOW` 独占创建新文件，禁止覆盖任何已有文件或链接，并返回发布后的文件快照。
    func publishExclusiveNewFile(
        _ data: Data,
        to targetURL: URL,
        mode: mode_t,
        label: String,
        invokeHook: Bool = true
    ) throws -> FileSnapshot {
        if invokeHook, let beforeAtomicCommit {
            try beforeAtomicCommit(targetURL)
        }
        let fd = Darwin.open(targetURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            let err = errno
            if err == EEXIST {
                throw ConfigError.conflictingKeyFiles("目标路径已存在同名文件 \(label)，已停止且未覆盖。")
            }
            throw ConfigError.fileOperationFailed("无法独占创建 \(label)：\(Self.posixErrorMessage(err))")
        }
        var closed = false
        defer {
            if !closed { Darwin.close(fd) }
        }
        do {
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
            Darwin.close(fd)
            closed = true
        } catch {
            if !closed {
                Darwin.close(fd)
                closed = true
            }
            _ = Darwin.unlink(targetURL.path)
            throw error
        }
        return try captureSnapshot(of: targetURL)
    }

    /// 删除前在父目录描述符上复核已验证的文件快照（dev/ino/size/mtime/data 完全一致），防止 TOCTOU 误删被替换文件。
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
        let parentDir = url.deletingLastPathComponent()
        let dirFD = Darwin.open(parentDir.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard dirFD >= 0 else {
            throw ConfigError.fileOperationFailed("无法打开目录检查 \(label)：\(Self.posixErrorMessage())")
        }
        defer { Darwin.close(dirFD) }

        let current = try captureSnapshot(of: url)
        guard current.exists else { return }
        guard let currentInfo = current.info,
              currentInfo.dev == expectedInfo.dev,
              currentInfo.ino == expectedInfo.ino,
              currentInfo.size == expectedInfo.size,
              currentInfo.mtimeSec == expectedInfo.mtimeSec,
              currentInfo.mtimeNsec == expectedInfo.mtimeNsec,
              current.data == expectedSnapshot.data else {
            throw ConfigError.conflictingKeyFiles("密钥文件 \(label) 在校验后被修改或替换，已保留未删除。")
        }

        guard Darwin.unlinkat(dirFD, url.lastPathComponent, 0) == 0 else {
            let err = errno
            if err == ENOENT { return }
            throw ConfigError.fileOperationFailed("删除 \(label) 失败：\(Self.posixErrorMessage(err))")
        }
    }

    func writeExclusiveTempFile(_ data: Data, to url: URL, mode: mode_t) throws {
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

    func writeFileAtomically(
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

    func removeRegularFileIfPresent(_ url: URL) throws {
        guard lstatInfo(for: url) != nil else { return }
        try validateRegularFileIfPresent(url, label: url.lastPathComponent)
        guard Darwin.unlink(url.path) == 0 else {
            let err = errno
            if err == ENOENT { return }
            throw ConfigError.fileOperationFailed("删除 \(url.lastPathComponent) 失败：\(Self.posixErrorMessage(err))")
        }
    }

    func loadManagedState() throws -> ManagedState? {
        guard let data = try readRegularFileDataIfPresent(stateFileURL) else { return nil }
        do {
            return try JSONDecoder().decode(ManagedState.self, from: data)
        } catch {
            throw ConfigError.fileOperationFailed("读取 Mimi SSH 状态文件失败：\(error.localizedDescription)")
        }
    }

    func saveManagedState(_ state: ManagedState) throws {
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

    func readPublicKeyBody() -> String? {
        guard let data = try? readRegularFileDataIfPresent(publicKeyURL),
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

    func readAllBytes(from fd: Int32, label: String) throws -> Data {
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
