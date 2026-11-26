import Darwin
import Foundation

extension CodexLocalSSHConfigurator {
    // MARK: - Safe POSIX File Operations, Tri-State Probing & Locking

    struct LStatInfo: Equatable {
        let mode: mode_t
        let uid: uid_t
        let gid: gid_t
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
            gid: gid_t = Darwin.getegid(),
            dev: dev_t,
            ino: ino_t,
            size: off_t,
            mtimeSec: Int,
            mtimeNsec: Int
        ) {
            self.mode = mode
            self.uid = uid
            self.gid = gid
            self.dev = dev
            self.ino = ino
            self.size = size
            self.mtimeSec = mtimeSec
            self.mtimeNsec = mtimeNsec
        }

        init(stat st: stat) {
            self.mode = st.st_mode
            self.uid = st.st_uid
            self.gid = st.st_gid
            self.dev = st.st_dev
            self.ino = st.st_ino
            self.size = st.st_size
            self.mtimeSec = st.st_mtimespec.tv_sec
            self.mtimeNsec = st.st_mtimespec.tv_nsec
        }
    }

    /// 单条扩展属性（按原始字节保存属性名，避免 Swift `String` Unicode 规范等价把 NFC/NFD 等不同字节属性名合并）。
    struct RawExtendedAttribute: Equatable, Hashable {
        let rawName: Data
        let value: Data

        var displayName: String {
            String(decoding: rawName, as: UTF8.self)
        }

        func withCStringName<R>(_ body: (UnsafePointer<CChar>) throws -> R) rethrows -> R {
            var bytes: [CChar] = []
            bytes.reserveCapacity(rawName.count + 1)
            for byte in rawName {
                bytes.append(CChar(bitPattern: byte))
            }
            bytes.append(0)
            return try bytes.withUnsafeBufferPointer { buf in
                try body(buf.baseAddress!)
            }
        }
    }

    /// 文件的扩展访问元数据（ACL 与按原始字节排序的扩展属性列表），用于替换已有 SSH 文件时完整保留访问控制或拒绝降级替换。
    struct FileAccessMetadata: Equatable {
        let aclExternalData: Data?
        let xattrs: [RawExtendedAttribute]

        static let empty = FileAccessMetadata(aclExternalData: nil, xattrs: [])
    }

    /// 明确区分「确实缺失（仅 ENOENT）」与「存在」；任何其他 errno（如 EACCES、ENOTDIR、ELOOP）必须显式抛错，绝不静默降级为缺失。
    enum PathProbe: Equatable {
        case missing
        case present(LStatInfo)
    }

    struct FileSnapshot: Equatable {
        let exists: Bool
        let info: LStatInfo?
        let metadata: FileAccessMetadata
        let data: Data

        var mode: mode_t? { info?.permissions }

        init(
            exists: Bool,
            info: LStatInfo?,
            metadata: FileAccessMetadata = .empty,
            data: Data
        ) {
            self.exists = exists
            self.info = info
            self.metadata = metadata
            self.data = data
        }

        static let missing = FileSnapshot(exists: false, info: nil, metadata: .empty, data: Data())
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
                throw ConfigError.unsafeFileSystemTarget("\(label) 是符号链接，Mimi 不会自动修改。请先手工调整为当前用户的普通目录后再试。")
            }
            guard info.isDirectory else {
                throw ConfigError.unsafeFileSystemTarget("\(label) 不是普通目录，Mimi 不会自动修改。请先手工检查该路径后再试。")
            }
            guard info.uid == Darwin.geteuid() else {
                throw ConfigError.unsafeFileSystemTarget("\(label) 不属于当前用户，Mimi 不会自动修改属主。请先在终端手工核对并修复属主（如执行：sudo chown \"$USER\" \(label)）后再试。")
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
                throw ConfigError.unsafeFileSystemTarget("\(label) 是符号链接，Mimi 不会自动修改。请先手工调整为普通文件后再试。")
            }
            guard info.isRegularFile else {
                throw ConfigError.unsafeFileSystemTarget("\(label) 不是普通文件，Mimi 不会自动修改。请先手工检查该路径后再试。")
            }
            guard info.uid == Darwin.geteuid() else {
                throw ConfigError.unsafeFileSystemTarget("\(label) 不属于当前用户，Mimi 不会自动修改属主。请先在终端手工核对并修复属主（如执行：sudo chown \"$USER\" \(label)）后再试。")
            }
            return info
        }
    }

    func validateStateDirectoryAndStateFile() throws {
        let stateDir = stateFileURL.deletingLastPathComponent()
        try validateDirectoryIfPresent(stateDir, label: stateDir.lastPathComponent)
        try validateRegularFileIfPresent(stateFileURL, label: stateFileURL.lastPathComponent)
    }

    func validateMimiDirectoryAndFiles() throws {
        try validateDirectoryIfPresent(mimiSSHDirectory, label: "~/.ssh/mimi")
        try validateRegularFileIfPresent(mimiConfigURL, label: "~/.ssh/mimi/config")
        try validateRegularFileIfPresent(privateKeyURL, label: "~/.ssh/mimi/\(Self.keyFileName)")
        try validateRegularFileIfPresent(publicKeyURL, label: "~/.ssh/mimi/\(Self.keyFileName).pub")
        try validateRegularFileIfPresent(knownHostsURL, label: "~/.ssh/mimi/\(Self.knownHostsFileName)")
    }

    func ensureNotGroupOrWorldWritable(_ info: LStatInfo, label: String, reason: String) throws {
        guard (info.permissions & 0o022) == 0 else {
            throw ConfigError.unsafeFileSystemTarget(
                "\(label) 权限不安全（组或其他用户可写，当前权限 \(String(format: "%04o", info.permissions))），Mimi 不会自动修改权限：\(reason)"
            )
        }
    }

    func ensureSSHDirectory() throws -> Bool {
        if let info = try validateDirectoryIfPresent(sshDirectory, label: "~/.ssh") {
            try ensureNotGroupOrWorldWritable(
                info,
                label: "~/.ssh",
                reason: "请先手工核对目录内容并在终端执行 chmod 700 ~/.ssh 后重试。"
            )
            return false
        }
        return try createSecureDirectory(at: sshDirectory, withIntermediateDirectories: false)
    }

    func ensureMimiSSHDirectory() throws -> Bool {
        if let info = try validateDirectoryIfPresent(mimiSSHDirectory, label: "~/.ssh/mimi") {
            try ensureNotGroupOrWorldWritable(
                info,
                label: "~/.ssh/mimi",
                reason: "请先手工核对目录内容并在终端执行 chmod 700 ~/.ssh/mimi 后重试。"
            )
            return false
        }
        return try createSecureDirectory(at: mimiSSHDirectory, withIntermediateDirectories: false)
    }

    func ensureStateDirectory() throws {
        let dir = stateFileURL.deletingLastPathComponent()
        if let info = try validateDirectoryIfPresent(dir, label: dir.lastPathComponent) {
            try tightenExistingDirectoryIfNeeded(dir, currentMode: info.permissions)
            return
        }
        _ = try createSecureDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func createSecureDirectory(at url: URL, withIntermediateDirectories: Bool) throws -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: withIntermediateDirectories,
                attributes: [.posixPermissions: 0o700]
            )
            // 确保不受宽 umask 影响，且仅对刚新建的目录设置 0700。
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
            if fd >= 0 {
                defer { Darwin.close(fd) }
                _ = Darwin.fchmod(fd, 0o700)
            }
            return true
        } catch {
            throw ConfigError.fileOperationFailed(error.localizedDescription)
        }
    }

    /// 仅在目录已空且经校验为当前用户普通目录时移除，绝不递归删除任何未知文件。
    func removeDirectoryIfEmpty(_ url: URL, label: String) {
        guard (try? validateDirectoryIfPresent(url, label: label)) != nil else { return }
        _ = Darwin.rmdir(url.path)
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

    /// 对已存在且已通过安全校验的用户文件保持其原有权限位（含特殊位）不变；仅新建文件采用默认权限。
    static func preservedSafeFileMode(existing: mode_t?, defaultMode: mode_t) -> mode_t {
        guard let existing else { return defaultMode }
        return existing & 0o7777
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
        let metadata = try captureFileAccessMetadata(fromFD: fd, label: label)
        return FileSnapshot(exists: true, info: LStatInfo(stat: st), metadata: metadata, data: data)
    }

    func captureFileAccessMetadata(fromFD fd: Int32, label: String) throws -> FileAccessMetadata {
        let aclData = try captureExtendedACL(fromFD: fd, label: label)
        let xattrs = try captureExtendedAttributes(fromFD: fd, label: label)
        return FileAccessMetadata(aclExternalData: aclData, xattrs: xattrs)
    }

    private func captureExtendedACL(fromFD fd: Int32, label: String) throws -> Data? {
        errno = 0
        guard let acl = Darwin.acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            let err = errno
            if err == ENOENT || err == ENOTSUP || err == 0 {
                return nil
            }
            throw ConfigError.fileOperationFailed("无法读取 \(label) 的 ACL 访问控制列表：\(Self.posixErrorMessage(err))")
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }

        let size = Darwin.acl_size(acl)
        guard size >= 0 else {
            throw ConfigError.fileOperationFailed("无法计算 \(label) 的 ACL 大小：\(Self.posixErrorMessage())")
        }
        if size == 0 {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let copied = Darwin.acl_copy_ext_native(&buffer, acl, size)
        guard copied >= 0 else {
            throw ConfigError.fileOperationFailed("无法序列化 \(label) 的 ACL：\(Self.posixErrorMessage())")
        }
        return Data(buffer.prefix(copied))
    }

    private func captureExtendedAttributes(fromFD fd: Int32, label: String) throws -> [RawExtendedAttribute] {
        var listSize = Darwin.flistxattr(fd, nil, 0, 0)
        if listSize < 0 {
            let err = errno
            if err == ENOTSUP {
                return []
            }
            throw ConfigError.fileOperationFailed("无法列举 \(label) 的扩展属性：\(Self.posixErrorMessage(err))")
        }
        if listSize == 0 {
            return []
        }
        var nameBuffer = [CChar](repeating: 0, count: listSize)
        var actualSize = Darwin.flistxattr(fd, &nameBuffer, nameBuffer.count, 0)
        if actualSize < 0 && errno == ERANGE {
            listSize = Darwin.flistxattr(fd, nil, 0, 0)
            guard listSize >= 0 else {
                throw ConfigError.fileOperationFailed("无法重新列举 \(label) 的扩展属性：\(Self.posixErrorMessage())")
            }
            if listSize == 0 { return [] }
            nameBuffer = [CChar](repeating: 0, count: listSize)
            actualSize = Darwin.flistxattr(fd, &nameBuffer, nameBuffer.count, 0)
        }
        guard actualSize >= 0 else {
            throw ConfigError.fileOperationFailed("读取 \(label) 扩展属性列表失败：\(Self.posixErrorMessage())")
        }

        var rawNames: [Data] = []
        var offset = 0
        while offset < actualSize {
            var end = offset
            while end < actualSize && nameBuffer[end] != 0 {
                end += 1
            }
            if end > offset {
                let bytes = nameBuffer[offset..<end].map { UInt8(bitPattern: $0) }
                rawNames.append(Data(bytes))
            }
            offset = end + 1
        }
        rawNames.sort { $0.lexicographicallyPrecedes($1) }

        var result: [RawExtendedAttribute] = []
        result.reserveCapacity(rawNames.count)
        for rawName in rawNames {
            let entry = RawExtendedAttribute(rawName: rawName, value: Data())
            let valSize = entry.withCStringName { cName in
                Darwin.fgetxattr(fd, cName, nil, 0, 0, 0)
            }
            if valSize < 0 {
                throw ConfigError.fileOperationFailed("无法读取 \(label) 的扩展属性 \(entry.displayName)：\(Self.posixErrorMessage())")
            }
            if valSize == 0 {
                result.append(entry)
                continue
            }
            var valBuf = [UInt8](repeating: 0, count: valSize)
            let readLen = entry.withCStringName { cName in
                Darwin.fgetxattr(fd, cName, &valBuf, valBuf.count, 0, 0)
            }
            guard readLen >= 0 else {
                throw ConfigError.fileOperationFailed("读取 \(label) 的扩展属性 \(entry.displayName) 失败：\(Self.posixErrorMessage())")
            }
            result.append(RawExtendedAttribute(rawName: rawName, value: Data(valBuf.prefix(readLen))))
        }
        return result
    }

    private func applyAndVerifyPreservedAccessMetadata(
        toFD fd: Int32,
        targetMode: mode_t,
        existingInfo: LStatInfo,
        existingMetadata: FileAccessMetadata,
        label: String
    ) throws -> (LStatInfo, FileAccessMetadata) {
        if let injectedError = injectMetadataPreservationError?(label) {
            throw ConfigError.fileOperationFailed("无法保留 \(label) 的访问元数据（\(injectedError)），已拒绝替换。")
        }

        var currentSt = stat()
        guard Darwin.fstat(fd, &currentSt) == 0 else {
            throw ConfigError.fileOperationFailed("无法检查暂存文件 \(label) 状态：\(Self.posixErrorMessage())")
        }

        // 1. 保留原属组（gid）
        if currentSt.st_gid != existingInfo.gid {
            guard Darwin.fchown(fd, uid_t(bitPattern: -1), existingInfo.gid) == 0 else {
                throw ConfigError.fileOperationFailed(
                    "无法保留 \(label) 的原属组（gid=\(existingInfo.gid)）：\(Self.posixErrorMessage())，已拒绝替换。"
                )
            }
        }

        // 2. 按原始字节名保留全部扩展属性（xattrs，含 NFC/NFD 等字节级唯一名称），并清除意外继承的额外属性
        let desiredRawNames = Set(existingMetadata.xattrs.map(\.rawName))
        let currentXattrs = try captureExtendedAttributes(fromFD: fd, label: label)
        for existingAttr in currentXattrs where !desiredRawNames.contains(existingAttr.rawName) {
            let status = existingAttr.withCStringName { cName in
                Darwin.fremovexattr(fd, cName, 0)
            }
            guard status == 0 else {
                throw ConfigError.fileOperationFailed(
                    "无法清理暂存文件 \(label) 继承的扩展属性（\(existingAttr.displayName)）：\(Self.posixErrorMessage())，已拒绝替换。"
                )
            }
        }
        for attr in existingMetadata.xattrs {
            let status: Int32 = attr.withCStringName { cName in
                attr.value.withUnsafeBytes { raw in
                    Darwin.fsetxattr(fd, cName, raw.baseAddress, raw.count, 0, 0)
                }
            }
            guard status == 0 else {
                throw ConfigError.fileOperationFailed(
                    "无法保留 \(label) 的扩展属性（\(attr.displayName)）：\(Self.posixErrorMessage())，已拒绝替换。"
                )
            }
        }

        // 3. 设置并核验 POSIX 权限位（在 fchown 之后设置，避免 fchown 清除特殊权限位）
        guard Darwin.fchmod(fd, targetMode) == 0 else {
            throw ConfigError.fileOperationFailed(
                "无法保留 \(label) 的 POSIX 权限（\(String(format: "%04o", targetMode))）：\(Self.posixErrorMessage())，已拒绝替换。"
            )
        }

        // 4. 保留原 ACL（或清理暂存目录意外继承的 ACL）
        if let aclData = existingMetadata.aclExternalData {
            guard let restoredACL = aclData.withUnsafeBytes({ raw -> acl_t? in
                guard let base = raw.baseAddress else { return nil }
                return Darwin.acl_copy_int_native(base)
            }) else {
                throw ConfigError.fileOperationFailed("无法重建 \(label) 的 ACL 访问控制列表，已拒绝替换。")
            }
            defer { Darwin.acl_free(UnsafeMutableRawPointer(restoredACL)) }
            guard Darwin.acl_set_fd_np(fd, restoredACL, ACL_TYPE_EXTENDED) == 0 else {
                throw ConfigError.fileOperationFailed(
                    "无法保留 \(label) 的 ACL 访问控制列表：\(Self.posixErrorMessage())，已拒绝替换。"
                )
            }
        } else if try captureExtendedACL(fromFD: fd, label: label) != nil {
            guard let emptyACL = Darwin.acl_init(0) else {
                throw ConfigError.fileOperationFailed("无法清除暂存文件 \(label) 继承的 ACL，已拒绝替换。")
            }
            defer { Darwin.acl_free(UnsafeMutableRawPointer(emptyACL)) }
            guard Darwin.acl_set_fd_np(fd, emptyACL, ACL_TYPE_EXTENDED) == 0 else {
                throw ConfigError.fileOperationFailed(
                    "无法清除暂存文件 \(label) 继承的 ACL：\(Self.posixErrorMessage())，已拒绝替换。"
                )
            }
        }

        // 5. 回读核验 mode、gid、xattrs 与 ACL 全部一致，任何偏差一律拒绝替换
        guard Darwin.fstat(fd, &currentSt) == 0 else {
            throw ConfigError.fileOperationFailed("无法回读核验暂存文件 \(label) 状态：\(Self.posixErrorMessage())")
        }
        let verifiedInfo = LStatInfo(stat: currentSt)
        guard verifiedInfo.permissions == targetMode else {
            throw ConfigError.fileOperationFailed(
                "回读核验 \(label) 的 POSIX 权限不一致（实际 \(String(format: "%04o", verifiedInfo.permissions))，预期 \(String(format: "%04o", targetMode))），已拒绝替换。"
            )
        }
        guard verifiedInfo.gid == existingInfo.gid else {
            throw ConfigError.fileOperationFailed(
                "回读核验 \(label) 的文件属组不一致（实际 gid=\(verifiedInfo.gid)，预期 gid=\(existingInfo.gid)），已拒绝替换。"
            )
        }
        let verifiedMetadata = try captureFileAccessMetadata(fromFD: fd, label: label)
        guard verifiedMetadata.xattrs == existingMetadata.xattrs else {
            throw ConfigError.fileOperationFailed("回读核验 \(label) 的扩展属性不一致，已拒绝替换。")
        }
        guard verifiedMetadata.aclExternalData == existingMetadata.aclExternalData else {
            throw ConfigError.fileOperationFailed("回读核验 \(label) 的 ACL 访问控制列表不一致，已拒绝替换。")
        }
        return (verifiedInfo, verifiedMetadata)
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
            expected.info?.gid == current.info?.gid &&
            expected.info?.permissions == current.info?.permissions &&
            expected.info?.size == current.info?.size &&
            expected.info?.mtimeSec == current.info?.mtimeSec &&
            expected.info?.mtimeNsec == current.info?.mtimeNsec &&
            expected.metadata == current.metadata &&
            expected.data == current.data
    }

    static func statMatchesSnapshot(_ st: stat, _ snapshot: FileSnapshot) -> Bool {
        guard snapshot.exists, let info = snapshot.info else { return false }
        return st.st_dev == info.dev &&
            st.st_ino == info.ino &&
            (st.st_mode & 0o7777) == info.permissions &&
            st.st_size == info.size &&
            st.st_mtimespec.tv_sec == info.mtimeSec &&
            st.st_mtimespec.tv_nsec == info.mtimeNsec
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

    // MARK: - Stage-Then-Exclusive-Publish, Atomic RENAME_SWAP CAS & Quarantine-Then-Verify-Then-Delete

    func openVerifiedParentDirectoryFD(for url: URL, label: String) throws -> Int32 {
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

    /// 以禁止覆盖且不写额外副本的方式将独占暂存目录中经 inode 核验的密钥文件原子移动到最终路径（优先 `RENAME_EXCL`，不支持时回退同文件系统 `linkat` + `unlinkat`）。
    /// 私钥只在 `~/.ssh/mimi/` 中生成一次，绝不复制到临时目录或其他副本；遇已有同名文件报错且绝不覆盖。
    func publishStagedKeyFile(
        inStagingDirectory stageDirName: String,
        expectedDirectoryIdentity: FileIdentity,
        fileName: String,
        expectedFileIdentity: FileIdentity,
        stagedSnapshot: FileSnapshot,
        to targetURL: URL,
        label: String
    ) throws -> FileSnapshot {
        if let beforeAtomicCommit {
            try beforeAtomicCommit(targetURL)
        }
        let parentFD = try openVerifiedParentDirectoryFD(for: targetURL, label: label)
        defer { Darwin.close(parentFD) }

        let stageFD = Darwin.openat(parentFD, stageDirName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard stageFD >= 0 else {
            throw ConfigError.fileOperationFailed("无法打开密钥暂存目录发布 \(label)：\(Self.posixErrorMessage())")
        }
        defer { Darwin.close(stageFD) }

        var stageSt = stat()
        guard Darwin.fstat(stageFD, &stageSt) == 0,
              (stageSt.st_mode & S_IFMT) == S_IFDIR,
              stageSt.st_uid == Darwin.geteuid(),
              expectedDirectoryIdentity.matches(stageSt) else {
            throw ConfigError.conflictingKeyFiles("密钥暂存目录在发布 \(label) 前被替换，已中止。")
        }

        var stagedSt = stat()
        guard Darwin.fstatat(stageFD, fileName, &stagedSt, AT_SYMLINK_NOFOLLOW) == 0,
              (stagedSt.st_mode & S_IFMT) == S_IFREG,
              stagedSt.st_uid == Darwin.geteuid(),
              expectedFileIdentity.matches(stagedSt) else {
            throw ConfigError.conflictingKeyFiles("暂存文件 \(label) 在发布前被修改或替换，已中止。")
        }

        if let afterVerifyBeforeCommit {
            try afterVerifyBeforeCommit(targetURL)
        }

        let targetName = targetURL.lastPathComponent
        if Darwin.renameatx_np(stageFD, fileName, parentFD, targetName, UInt32(RENAME_EXCL)) == 0 {
            return stagedSnapshot
        }
        let err = errno
        if err == EEXIST {
            throw ConfigError.conflictingKeyFiles("发布期间出现同名文件 \(label)，已停止且未覆盖。")
        }
        if err == ENOTSUP || err == EPERM {
            if Darwin.linkat(stageFD, fileName, parentFD, targetName, 0) == 0 {
                _ = Darwin.unlinkat(stageFD, fileName, 0)
                return stagedSnapshot
            }
            let linkErr = errno
            if linkErr == EEXIST {
                throw ConfigError.conflictingKeyFiles("发布期间出现同名文件 \(label)，已停止且未覆盖。")
            }
            throw ConfigError.fileOperationFailed("发布 \(label) 失败：\(Self.posixErrorMessage(linkErr))")
        }
        throw ConfigError.fileOperationFailed("发布 \(label) 失败：\(Self.posixErrorMessage(err))")
    }

    /// 先在目标父目录内创建独占 `0700` 暂存目录写盘并从已落盘描述符记录快照，再原子无覆盖发布到目标路径（`linkat` / `RENAME_EXCL`）。
    /// 写入/改权/同步失败绝不会在目标路径创建半成品，也绝不会按目标路径执行 `unlink`。
    func publishExclusiveNewFile(
        _ data: Data,
        to targetURL: URL,
        mode: mode_t,
        label: String,
        invokeHook: Bool = true,
        reportExistAsConcurrentModification: Bool = false
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

        let stagedSnapshot = try writeStagedItem(data, inDirectoryFD: stageDirFD, fileName: "item", mode: mode, label: label)
        itemRemainingInStage = true

        if invokeHook, let beforeAtomicCommit {
            try beforeAtomicCommit(targetURL)
        }

        let targetName = targetURL.lastPathComponent
        var preSt = stat()
        if Darwin.fstatat(parentFD, targetName, &preSt, AT_SYMLINK_NOFOLLOW) == 0 {
            if reportExistAsConcurrentModification {
                throw ConfigError.concurrentModification("\(label) 在写入前已被其他进程创建，已中止且未覆盖。")
            }
            throw ConfigError.conflictingKeyFiles("目标路径已存在同名文件 \(label)，已停止且未覆盖。")
        } else if errno != ENOENT {
            throw ConfigError.fileOperationFailed("无法检查 \(label)：\(Self.posixErrorMessage())")
        }

        if invokeHook, let afterVerifyBeforeCommit {
            try afterVerifyBeforeCommit(targetURL)
        }

        if Darwin.linkat(stageDirFD, "item", parentFD, targetName, 0) == 0 {
            return stagedSnapshot
        }
        let linkErr = errno
        if linkErr == EEXIST {
            if reportExistAsConcurrentModification {
                throw ConfigError.concurrentModification("\(label) 在原子发布瞬间被其他进程创建，已中止且未覆盖。")
            }
            throw ConfigError.conflictingKeyFiles("目标路径已存在同名文件 \(label)，已停止且未覆盖。")
        }
        if linkErr == ENOTSUP || linkErr == EXDEV || linkErr == EPERM {
            if Darwin.renameatx_np(stageDirFD, "item", parentFD, targetName, UInt32(RENAME_EXCL)) == 0 {
                itemRemainingInStage = false
                return stagedSnapshot
            }
            let renameErr = errno
            if renameErr == EEXIST {
                if reportExistAsConcurrentModification {
                    throw ConfigError.concurrentModification("\(label) 在原子发布瞬间被其他进程创建，已中止且未覆盖。")
                }
                throw ConfigError.conflictingKeyFiles("目标路径已存在同名文件 \(label)，已停止且未覆盖。")
            }
            throw ConfigError.fileOperationFailed("原子发布 \(label) 失败：\(Self.posixErrorMessage(renameErr))")
        }
        throw ConfigError.fileOperationFailed("原子发布 \(label) 失败：\(Self.posixErrorMessage(linkErr))")
    }

    private func writeStagedItem(
        _ data: Data,
        inDirectoryFD dirFD: Int32,
        fileName: String,
        mode: mode_t,
        preserveFrom existingSnapshot: FileSnapshot? = nil,
        label: String
    ) throws -> FileSnapshot {
        let fd = Darwin.openat(dirFD, fileName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw ConfigError.fileOperationFailed("无法在独占暂存目录创建 \(label)：\(Self.posixErrorMessage())")
        }
        var closed = false
        var succeeded = false
        defer {
            if !closed { Darwin.close(fd) }
            if !succeeded {
                _ = Darwin.unlinkat(dirFD, fileName, 0)
            }
        }
        guard Darwin.fchmod(fd, 0o600) == 0 else {
            throw ConfigError.fileOperationFailed("设置 \(label) 权限失败：\(Self.posixErrorMessage())")
        }
        try writeAllBytes(data, to: fd, label: label)

        let stagedInfo: LStatInfo
        let stagedMetadata: FileAccessMetadata
        if let existingSnapshot, existingSnapshot.exists, let existingInfo = existingSnapshot.info {
            let applied = try applyAndVerifyPreservedAccessMetadata(
                toFD: fd,
                targetMode: mode,
                existingInfo: existingInfo,
                existingMetadata: existingSnapshot.metadata,
                label: label
            )
            _ = Darwin.fsync(fd)
            var st = stat()
            guard Darwin.fstat(fd, &st) == 0 else {
                throw ConfigError.fileOperationFailed("无法记录 \(label) 发布快照：\(Self.posixErrorMessage())")
            }
            stagedInfo = LStatInfo(stat: st)
            stagedMetadata = applied.1
        } else {
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
            stagedInfo = LStatInfo(stat: st)
            stagedMetadata = (try? captureFileAccessMetadata(fromFD: fd, label: label)) ?? .empty
        }

        let stagedSnapshot = FileSnapshot(exists: true, info: stagedInfo, metadata: stagedMetadata, data: data)
        Darwin.close(fd)
        closed = true
        succeeded = true
        return stagedSnapshot
    }

    /// 隔离-入账-核验-删除：先做无破坏预检，创建独占 `0700` 隔离目录并先持久化隔离账本（如提供），
    /// 再原子移入隔离目录并在隔离目录内核验 `(dev, ino, gid, mode, acl, xattrs, size, mtime, data)` 完全一致后才删除。
    /// 若崩溃或 `unlink` 失败导致文件滞留隔离目录，重试删除时会先按账本核验并回收隔离文件，绝不提前清除归属记录。
    func removeFileMatchingSnapshot(
        _ url: URL,
        expectedSnapshot: FileSnapshot,
        label: String,
        invokeHook: Bool,
        journalQuarantine: ((QuarantinedFileArtifact) throws -> Void)? = nil,
        clearQuarantine: ((QuarantinedFileArtifact) throws -> Void)? = nil
    ) throws {
        guard expectedSnapshot.exists, let expectedInfo = expectedSnapshot.info else { return }
        if invokeHook, let beforeAtomicCommit {
            try beforeAtomicCommit(url)
        }

        let dirFD = try openVerifiedParentDirectoryFD(for: url, label: label)
        defer { Darwin.close(dirFD) }

        let parentDir = url.deletingLastPathComponent()
        let parentScope = Self.quarantineParentScope(forParentDirectory: parentDir, mimiDir: mimiSSHDirectory, sshDir: sshDirectory)
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

        let fileIdentity = FileIdentity(dev: expectedInfo.dev, ino: expectedInfo.ino)
        let fileVersion = FileVersionFingerprint.from(data: expectedSnapshot.data)
        var recordedArtifact: QuarantinedFileArtifact?

        try quarantineVerifyAndUnlink(
            inParentFD: dirFD,
            parentDir: parentDir,
            fileName: fileName,
            label: label,
            invokeHook: invokeHook,
            beforeMoveJournal: { qDirName, qDirIdentity in
                guard let journalQuarantine, let parentScope else { return }
                let artifact = QuarantinedFileArtifact(
                    parentScope: parentScope,
                    originalFileName: fileName,
                    quarantineDirectoryName: qDirName,
                    quarantineDirectoryIdentity: qDirIdentity,
                    fileIdentity: fileIdentity,
                    fileVersion: fileVersion
                )
                try journalQuarantine(artifact)
                recordedArtifact = artifact
            },
            afterUnlinkOrRestoreClear: {
                if let artifact = recordedArtifact {
                    try? clearQuarantine?(artifact)
                    recordedArtifact = nil
                }
            },
            verify: { qDirFD in
                let isolated = try captureSnapshot(inDirectoryFD: qDirFD, fileName: "item", label: label)
                guard isolated.exists, Self.snapshotsMatch(expectedSnapshot, isolated) else {
                    throw ConfigError.conflictingKeyFiles("文件 \(label) 在隔离核验时与预期快照不匹配，已保留未删除。")
                }
            }
        )
    }

    static func quarantineParentScope(forParentDirectory parentDir: URL, mimiDir: URL, sshDir: URL) -> String? {
        let stdParent = parentDir.standardizedFileURL.path
        if stdParent == mimiDir.standardizedFileURL.path {
            return "mimi"
        }
        if stdParent == sshDir.standardizedFileURL.path {
            return "ssh"
        }
        return nil
    }

    /// 恢复因崩溃或 `unlink` 失败滞留在 `.mimi-quarantine-*` 中的受管文件：
    /// 逐级校验隔离目录名、属主、隔离目录 `(dev, ino)`、目录内仅含 `item`、文件 `(dev, ino)` 与 SHA256+size 指纹，
    /// 全部一致才删除并回收空隔离目录；任何不匹配一律拒绝删除并保守保留。
    func recoverQuarantinedFileArtifact(_ artifact: QuarantinedFileArtifact) throws -> Bool {
        guard Self.isValidQuarantineDirectoryName(artifact.quarantineDirectoryName) else {
            throw ConfigError.fileOperationFailed("隔离文件记录的目录名非法（\(artifact.quarantineDirectoryName)），已保守保留。")
        }
        let parentDir: URL
        let parentLabel: String
        switch artifact.parentScope {
        case "mimi":
            parentDir = mimiSSHDirectory
            parentLabel = "~/.ssh/mimi"
        case "ssh":
            parentDir = sshDirectory
            parentLabel = "~/.ssh"
        default:
            throw ConfigError.fileOperationFailed("隔离文件记录的父目录域未知（\(artifact.parentScope)），已保守保留。")
        }

        switch try probePath(parentDir, label: parentLabel) {
        case .missing:
            return true
        case .present:
            if let info = try validateDirectoryIfPresent(parentDir, label: parentLabel) {
                try ensureNotGroupOrWorldWritable(
                    info,
                    label: parentLabel,
                    reason: "请先手工修复目录权限后再重试移除。"
                )
            }
        }

        let parentFD = Darwin.open(parentDir.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard parentFD >= 0 else {
            if errno == ENOENT { return true }
            throw ConfigError.fileOperationFailed("无法打开 \(parentLabel) 恢复隔离文件：\(Self.posixErrorMessage())")
        }
        defer { Darwin.close(parentFD) }

        let currentUID = Darwin.geteuid()
        var parentSt = stat()
        guard Darwin.fstat(parentFD, &parentSt) == 0,
              (parentSt.st_mode & S_IFMT) == S_IFDIR,
              parentSt.st_uid == currentUID else {
            throw ConfigError.unsafeFileSystemTarget(parentLabel)
        }

        let qDirFD = Darwin.openat(parentFD, artifact.quarantineDirectoryName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        if qDirFD < 0 {
            let err = errno
            if err == ENOENT {
                return true
            }
            throw ConfigError.fileOperationFailed(
                "无法打开已登记的隔离目录 \(artifact.quarantineDirectoryName)：\(Self.posixErrorMessage(err))"
            )
        }
        var qDirClosed = false
        defer {
            if !qDirClosed { Darwin.close(qDirFD) }
        }

        var qDirSt = stat()
        guard Darwin.fstat(qDirFD, &qDirSt) == 0,
              (qDirSt.st_mode & S_IFMT) == S_IFDIR,
              qDirSt.st_uid == currentUID,
              artifact.quarantineDirectoryIdentity.matches(qDirSt) else {
            throw ConfigError.conflictingKeyFiles(
                "隔离目录 \(artifact.quarantineDirectoryName) 的属主或 inode 与记录不一致，已保守保留未删除。"
            )
        }

        // 检查隔离目录内不允许存在除 item 外的未知条目。
        let dupFD = Darwin.dup(qDirFD)
        guard dupFD >= 0, let dirStream = Darwin.fdopendir(dupFD) else {
            if dupFD >= 0 { Darwin.close(dupFD) }
            throw ConfigError.fileOperationFailed("无法扫描隔离目录 \(artifact.quarantineDirectoryName)：\(Self.posixErrorMessage())")
        }
        var extraEntries: [String] = []
        while let entryPtr = Darwin.readdir(dirStream) {
            let name = withUnsafePointer(to: &entryPtr.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." || name == "item" { continue }
            extraEntries.append(name)
        }
        Darwin.closedir(dirStream)
        guard extraEntries.isEmpty else {
            throw ConfigError.conflictingKeyFiles(
                "隔离目录 \(artifact.quarantineDirectoryName) 包含未知条目（\(extraEntries.joined(separator: "、"))），已保守保留未删除。"
            )
        }

        let itemSnap = try captureSnapshot(inDirectoryFD: qDirFD, fileName: "item", label: artifact.originalFileName)
        if itemSnap.exists {
            guard let info = itemSnap.info,
                  info.isRegularFile,
                  info.uid == currentUID,
                  Int64(info.dev) == artifact.fileIdentity.dev,
                  UInt64(info.ino) == artifact.fileIdentity.ino,
                  artifact.fileVersion.matches(data: itemSnap.data) else {
                throw ConfigError.conflictingKeyFiles(
                    "隔离目录 \(artifact.quarantineDirectoryName) 中的 \(artifact.originalFileName) 与已记录的 inode 或内容指纹不匹配，已保守保留未删除。"
                )
            }
            guard Darwin.unlinkat(qDirFD, "item", 0) == 0 || errno == ENOENT else {
                throw ConfigError.fileOperationFailed(
                    "恢复删除隔离文件 \(artifact.originalFileName)（\(artifact.quarantineDirectoryName)）失败：\(Self.posixErrorMessage())"
                )
            }
        }

        Darwin.close(qDirFD)
        qDirClosed = true
        guard Darwin.unlinkat(parentFD, artifact.quarantineDirectoryName, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw ConfigError.fileOperationFailed(
                "移除已清空的隔离目录 \(artifact.quarantineDirectoryName) 失败：\(Self.posixErrorMessage())"
            )
        }
        return true
    }

    /// 通过「隔离-核验-删除」清理内部受锁状态文件，绝不直接按名称 `unlink`。
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
            invokeHook: false,
            beforeMoveJournal: nil,
            afterUnlinkOrRestoreClear: nil,
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

    /// 原子移入独占 `0700` 隔离目录 -> 移动前先通过 `beforeMoveJournal` 落盘登记隔离目录名与 `(dev, ino)` ->
    /// 在隔离目录内执行 `verify(qDirFD)` -> 通过才删除并清理账本；失败则 `RENAME_EXCL` 无覆盖恢复。
    private func quarantineVerifyAndUnlink(
        inParentFD dirFD: Int32,
        parentDir: URL,
        fileName: String,
        label: String,
        invokeHook: Bool,
        beforeMoveJournal: ((_ qDirName: String, _ qDirIdentity: FileIdentity) throws -> Void)?,
        afterUnlinkOrRestoreClear: (() -> Void)?,
        verify: (Int32) throws -> Void
    ) throws {
        let qDirName = "\(Self.keyQuarantineDirectoryPrefix)\(UUID().uuidString)"
        guard Darwin.mkdirat(dirFD, qDirName, 0o700) == 0 else {
            throw ConfigError.fileOperationFailed("无法创建独占隔离目录删除 \(label)：\(Self.posixErrorMessage())")
        }
        let qDirFD = Darwin.openat(dirFD, qDirName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard qDirFD >= 0 else {
            _ = Darwin.unlinkat(dirFD, qDirName, AT_REMOVEDIR)
            throw ConfigError.fileOperationFailed("无法打开隔离目录删除 \(label)：\(Self.posixErrorMessage())")
        }
        _ = Darwin.fchmod(qDirFD, 0o700)
        var qDirSt = stat()
        guard Darwin.fstat(qDirFD, &qDirSt) == 0,
              (qDirSt.st_mode & S_IFMT) == S_IFDIR,
              qDirSt.st_uid == Darwin.geteuid() else {
            Darwin.close(qDirFD)
            _ = Darwin.unlinkat(dirFD, qDirName, AT_REMOVEDIR)
            throw ConfigError.unsafeFileSystemTarget("隔离目录状态异常：\(qDirName)")
        }
        let qDirIdentity = FileIdentity(dev: qDirSt.st_dev, ino: qDirSt.st_ino)

        var keepQuarantineDir = false
        defer {
            Darwin.close(qDirFD)
            if !keepQuarantineDir {
                _ = Darwin.unlinkat(dirFD, qDirName, AT_REMOVEDIR)
            }
        }

        // 先持久化隔离记录，再原子移入隔离目录；若入账失败则终止于移动之前，不产生未登记的滞留隔离文件。
        if let beforeMoveJournal {
            try beforeMoveJournal(qDirName, qDirIdentity)
        }

        if Darwin.renameatx_np(dirFD, fileName, qDirFD, "item", UInt32(RENAME_EXCL)) != 0 {
            let err = errno
            afterUnlinkOrRestoreClear?()
            if err == ENOENT { return }
            throw ConfigError.fileOperationFailed("隔离待删文件 \(label) 失败：\(Self.posixErrorMessage(err))")
        }

        // 移入隔离目录后立即标记保留目录，直到确认删除或成功恢复原路径，确保测试钩子模拟中断/崩溃时保留隔离现场。
        keepQuarantineDir = true
        if invokeHook, let afterFileQuarantineMove {
            let qDirURL = parentDir.appendingPathComponent(qDirName, isDirectory: true)
            try afterFileQuarantineMove(qDirURL)
        }

        do {
            try verify(qDirFD)
        } catch {
            // 核验未通过：原子无覆盖恢复回原路径；若原路径已被新文件占用，保留在隔离目录内绝不覆盖或删除，
            // 且绝不清除隔离账本，避免后续重试因原路径缺失而误报删除成功并丢弃归属记录。
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
            keepQuarantineDir = false
            afterUnlinkOrRestoreClear?()
            throw error
        }

        if invokeHook, let simulateUnlinkFailure, simulateUnlinkFailure(label) {
            keepQuarantineDir = true
            throw ConfigError.fileOperationFailed("删除已核验的隔离文件 \(label) 失败：模拟 unlink 失败。")
        }

        guard Darwin.unlinkat(qDirFD, "item", 0) == 0 else {
            let err = errno
            if err == ENOENT {
                keepQuarantineDir = false
                afterUnlinkOrRestoreClear?()
                return
            }
            keepQuarantineDir = true
            throw ConfigError.fileOperationFailed("删除已核验的隔离文件 \(label) 失败：\(Self.posixErrorMessage(err))")
        }
        keepQuarantineDir = false
        afterUnlinkOrRestoreClear?()
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
            let metadata = (try? captureFileAccessMetadata(fromFD: fd, label: url.lastPathComponent)) ?? .empty
            let snapshot = FileSnapshot(exists: true, info: LStatInfo(stat: st), metadata: metadata, data: data)
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

    /// 无覆盖窗口的原子替换：
    /// - 原本缺失的目标（`expectedSnapshot.exists == false`）：走无覆盖 `publishExclusiveNewFile`（`linkat`/`RENAME_EXCL`），并发创建报 `concurrentModification` 绝不覆盖。
    /// - 已有文件（`expectedSnapshot.exists == true`）：在独占 `0700` 暂存目录写盘，写前校验快照，随后用 `RENAME_SWAP` 原子交换并保全实际换下的 inode；
    ///   在暂存目录内核验换下的 inode 与 `expectedSnapshot` 完全一致才删除，若发生比对后并发换档，原子无覆盖恢复外部版本并报 `concurrentModification`。
    /// - 内部受锁状态文件（`expectedSnapshot == nil`）：独占临时文件后原子 `rename`。
    @discardableResult
    func writeFileAtomically(
        _ data: Data,
        to targetURL: URL,
        mode: mode_t,
        expectedSnapshot: FileSnapshot?,
        label: String,
        invokeHook: Bool = true
    ) throws -> FileSnapshot {
        if let expectedSnapshot {
            if !expectedSnapshot.exists {
                return try publishExclusiveNewFile(
                    data,
                    to: targetURL,
                    mode: mode,
                    label: label,
                    invokeHook: invokeHook,
                    reportExistAsConcurrentModification: true
                )
            }
            return try replaceExistingFileWithSwapCAS(
                data,
                to: targetURL,
                mode: mode,
                expectedSnapshot: expectedSnapshot,
                label: label,
                invokeHook: invokeHook
            )
        }

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
        try validateRegularFileIfPresent(targetURL, label: label)
        if invokeHook, let afterVerifyBeforeCommit {
            try afterVerifyBeforeCommit(targetURL)
        }

        guard Darwin.rename(tempURL.path, targetURL.path) == 0 else {
            throw ConfigError.fileOperationFailed("原子替换 \(label) 失败：\(Self.posixErrorMessage())")
        }
        committed = true
        return writtenSnapshot
    }

    private func replaceExistingFileWithSwapCAS(
        _ data: Data,
        to targetURL: URL,
        mode: mode_t,
        expectedSnapshot: FileSnapshot,
        label: String,
        invokeHook: Bool
    ) throws -> FileSnapshot {
        let parentFD = try openVerifiedParentDirectoryFD(for: targetURL, label: label)
        defer { Darwin.close(parentFD) }
        let parentDir = targetURL.deletingLastPathComponent()
        let targetName = targetURL.lastPathComponent

        let stageDirName = ".mimi-cas-\(UUID().uuidString)"
        guard Darwin.mkdirat(parentFD, stageDirName, 0o700) == 0 else {
            throw ConfigError.fileOperationFailed("无法创建原子交换暂存目录更新 \(label)：\(Self.posixErrorMessage())")
        }
        let stageDirFD = Darwin.openat(parentFD, stageDirName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard stageDirFD >= 0 else {
            _ = Darwin.unlinkat(parentFD, stageDirName, AT_REMOVEDIR)
            throw ConfigError.fileOperationFailed("无法打开原子交换暂存目录更新 \(label)：\(Self.posixErrorMessage())")
        }
        _ = Darwin.fchmod(stageDirFD, 0o700)

        var keepStageDir = false
        var itemPresentInStage = false
        defer {
            if itemPresentInStage && !keepStageDir {
                _ = Darwin.unlinkat(stageDirFD, "item", 0)
            }
            Darwin.close(stageDirFD)
            if !keepStageDir {
                _ = Darwin.unlinkat(parentFD, stageDirName, AT_REMOVEDIR)
            }
        }

        let writtenSnapshot = try writeStagedItem(
            data,
            inDirectoryFD: stageDirFD,
            fileName: "item",
            mode: mode,
            preserveFrom: expectedSnapshot,
            label: label
        )
        itemPresentInStage = true

        if invokeHook, let beforeAtomicCommit {
            try beforeAtomicCommit(targetURL)
        }

        // 写前基于父目录描述符重验目标文件类型、属主与完整快照。
        let preSwapSnapshot = try captureSnapshot(inDirectoryFD: parentFD, fileName: targetName, label: label)
        try verifySnapshotUnchanged(expectedSnapshot, current: preSwapSnapshot, label: label)

        // 确定性测试钩子：模拟在最终快照核验通过之后、原子交换之前瞬间发生外部换档/写入。
        if invokeHook, let afterVerifyBeforeCommit {
            try afterVerifyBeforeCommit(targetURL)
        }

        // 原子交换：一次系统调用将目标换为新版本，同时把实际被换下的真实目录项保全在独占 0700 stageDirFD/item 中。
        if Darwin.renameatx_np(stageDirFD, "item", parentFD, targetName, UInt32(RENAME_SWAP)) != 0 {
            let err = errno
            if err == ENOENT {
                throw ConfigError.concurrentModification("\(label) 在原子替换瞬间已被外部删除。")
            }
            throw ConfigError.fileOperationFailed("原子交换 \(label) 失败：\(Self.posixErrorMessage(err))")
        }

        // 在独占暂存目录内核验实际被换下的文件是否与预期快照完全一致。
        var displacedMatches = false
        var dispSt = stat()
        if Darwin.fstatat(stageDirFD, "item", &dispSt, AT_SYMLINK_NOFOLLOW) == 0 {
            let dispInfo = LStatInfo(stat: dispSt)
            if !dispInfo.isSymlink, dispInfo.isRegularFile, dispInfo.uid == Darwin.geteuid(),
               let displacedSnapshot = try? captureSnapshot(inDirectoryFD: stageDirFD, fileName: "item", label: label),
               Self.snapshotsMatch(expectedSnapshot, displacedSnapshot) {
                displacedMatches = true
            }
        }

        if displacedMatches {
            // 实际被换下的文件与预期快照完全一致，可以安全销毁旧版本。
            _ = Darwin.unlinkat(stageDirFD, "item", 0)
            itemPresentInStage = false
            return writtenSnapshot
        }

        // 检测到比对之后发生了外部保存或替换：绝不销毁外部版本，无覆盖恢复回原路径！
        var curTargetSt = stat()
        if Darwin.fstatat(parentFD, targetName, &curTargetSt, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT,
               Darwin.renameatx_np(stageDirFD, "item", parentFD, targetName, UInt32(RENAME_EXCL)) == 0 {
                itemPresentInStage = false
                throw ConfigError.concurrentModification("\(label) 在最终校验后被外部修改，已无损恢复外部版本。")
            }
            keepStageDir = true
            let preservedPath = parentDir.appendingPathComponent(stageDirName).appendingPathComponent("item").path
            throw ConfigError.concurrentModification("\(label) 在最终校验后被外部修改，已将外部版本完整保留于 \(preservedPath)。")
        }

        if Self.statMatchesSnapshot(curTargetSt, writtenSnapshot) {
            if Darwin.renameatx_np(stageDirFD, "item", parentFD, targetName, UInt32(RENAME_SWAP)) == 0 {
                // 确认换回暂存目录的确实是我们刚写的版本；若期间又被第三者换走则完整保留暂存目录绝不删除。
                var backSt = stat()
                if Darwin.fstatat(stageDirFD, "item", &backSt, AT_SYMLINK_NOFOLLOW) == 0,
                   Self.statMatchesSnapshot(backSt, writtenSnapshot) {
                    _ = Darwin.unlinkat(stageDirFD, "item", 0)
                    itemPresentInStage = false
                    throw ConfigError.concurrentModification("\(label) 在最终校验后被外部修改，已无损恢复外部版本。")
                }
                keepStageDir = true
                let preservedPath = parentDir.appendingPathComponent(stageDirName).appendingPathComponent("item").path
                throw ConfigError.concurrentModification("\(label) 在最终校验后发生并发写入，已将冲突版本完整保留于 \(preservedPath)。")
            }
        }

        keepStageDir = true
        let preservedPath = parentDir.appendingPathComponent(stageDirName).appendingPathComponent("item").path
        throw ConfigError.concurrentModification("\(label) 在最终校验后被外部修改且目标已再次更新，已将原外部版本完整保留于 \(preservedPath)。")
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

    /// 冻结当前 `~/.ssh/config`（缺失视为空；只读评估允许可信的普通符号链接，仍严格校验属主与权限）与系统 `ssh_config`，用于只读探测和验连绑定同一份快照。
    func materializeCurrentSSHConfigForEvaluation(includeSystemConfig: Bool = true) throws -> MaterializedSSHConfig {
        let userText: String
        if let data = try readEvaluationRegularFileIfPresent(at: sshConfigURL, label: "~/.ssh/config") {
            userText = try decodeUTF8(data, label: "~/.ssh/config")
        } else {
            userText = ""
        }
        return try materializeEvaluationSSHConfig(userConfigText: userText, includeSystemConfig: includeSystemConfig)
    }

    /// 在独占 `0700` 临时目录中生成自包含的 SSH 评估快照：
    /// - 忠实冻结用户与系统配置及其所有 OpenSSH 可读取的 `Include`（含路径中段引号、转义空格、符号链接普通文件与系统目录相对 `Include`）；
    /// - 支持在 Preflight 阶段通过 `virtualFileOverrides` 注入尚未落盘的候选 `~/.ssh/mimi/config`；
    /// - 对任何无法忠实冻结的 `Include`（含 `%` 动态占位符、`${VAR}` 环境变量、`~otheruser`、未闭合引号、悬空转义、不可读、非 UTF-8、循环引用或超深嵌套）明确报错，绝不静默丢弃。
    func materializeEvaluationSSHConfig(
        userConfigText: String,
        includeSystemConfig: Bool,
        virtualFileOverrides: [String: String] = [:]
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

        var normalizedOverrides: [String: String] = [:]
        for (path, content) in virtualFileOverrides {
            normalizedOverrides[URL(fileURLWithPath: path).standardizedFileURL.path] = content
        }

        do {
            var counter = 0
            var activeStack: Set<String> = []
            var seenIgnoreUnknownPatterns: [[String]] = []
            var materializedUserText = try rewriteSSHConfigIncludes(
                text: userConfigText,
                baseDirectory: sshDirectory,
                tempDirectory: tempDir,
                virtualFileOverrides: normalizedOverrides,
                counter: &counter,
                depth: 0,
                activeStack: &activeStack,
                seenIgnoreUnknownPatterns: &seenIgnoreUnknownPatterns
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
                        virtualFileOverrides: normalizedOverrides,
                        counter: &counter,
                        depth: 1,
                        activeStack: &sysStack,
                        seenIgnoreUnknownPatterns: &seenIgnoreUnknownPatterns
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
        virtualFileOverrides: [String: String],
        counter: inout Int,
        depth: Int,
        activeStack: inout Set<String>,
        seenIgnoreUnknownPatterns: inout [[String]]
    ) throws -> String {
        guard depth <= 16 else {
            throw ConfigError.effectiveConfigConflict("SSH 配置 Include 嵌套层级超过 16 层，无法忠实冻结。")
        }
        let virtualPathSet = Set(virtualFileOverrides.keys)
        var output = ""
        for slice in Self.rawLineSlices(in: text) {
            let rawLine = Self.utf8Substring(text, range: slice.contentRange)
            let parsedLine = Self.parseSSHConfigLineStrict(rawLine)
            if parsedLine.hasSyntaxError {
                throw ConfigError.effectiveConfigConflict(
                    "SSH 配置包含非法控制字符、未闭合引号或语法不明确的指令，拒绝冻结并停止只读评估。"
                )
            }
            let tokens = parsedLine.tokens
            guard let firstToken = tokens.first else {
                output.append(rawLine)
                output.append("\n")
                continue
            }
            let keyword = firstToken.lowercased()
            if !Self.recognizedSSHConfigKeywords.contains(keyword) {
                if seenIgnoreUnknownPatterns.contains(where: { Self.matchesIgnoreUnknown(keyword: keyword, patterns: $0) }) {
                    // 原样保留未知指令交由真实 `/usr/bin/ssh -G` 按 OpenSSH `Host`/`Match` 作用域与通配符规则裁决，绝不私自注释。
                    output.append(rawLine)
                    output.append("\n")
                    continue
                }
                throw ConfigError.effectiveConfigConflict(
                    "SSH 配置包含无法识别的指令（\(firstToken)），拒绝冻结并停止只读评估。"
                )
            }
            if keyword == "match" {
                if let matchError = Self.validateMatchCriteria(Array(tokens.dropFirst())) {
                    throw ConfigError.effectiveConfigConflict(matchError)
                }
                output.append(rawLine)
                output.append("\n")
            } else if keyword == "ignoreunknown" {
                guard let parsedPatterns = Self.parseIgnoreUnknownPatterns(from: tokens) else {
                    throw ConfigError.effectiveConfigConflict("SSH 配置 IgnoreUnknown 指令语法无效，拒绝冻结并停止只读评估。")
                }
                seenIgnoreUnknownPatterns.append(parsedPatterns)
                output.append(rawLine)
                output.append("\n")
            } else if keyword == "include" {
                guard tokens.count >= 2 else {
                    throw ConfigError.effectiveConfigConflict("SSH 配置包含缺少路径参数的 Include 指令，无法忠实冻结。")
                }
                var rewrittenPaths: [String] = []
                for pattern in tokens.dropFirst() {
                    let matchedPaths = try Self.resolveGlobPathsStrict(
                        pattern: pattern,
                        baseDirectory: baseDirectory,
                        homeDirectory: homeDirectory,
                        virtualFilePaths: virtualPathSet
                    )
                    for matchedPath in matchedPaths {
                        let standardizedMatched = URL(fileURLWithPath: matchedPath).standardizedFileURL.path
                        let childText: String
                        let canonical: String

                        if let overrideText = virtualFileOverrides[standardizedMatched] {
                            childText = overrideText
                            canonical = standardizedMatched
                        } else {
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
                            canonical = matchedURL.resolvingSymlinksInPath().standardizedFileURL.path
                            let childData = try readEvaluationRegularFileRequired(at: matchedURL)
                            guard let decoded = String(data: childData, encoding: .utf8) else {
                                throw ConfigError.effectiveConfigConflict("SSH Include 文件 \(matchedPath) 不是有效的 UTF-8 文本，无法忠实冻结。")
                            }
                            childText = decoded
                        }

                        guard !activeStack.contains(canonical) else {
                            throw ConfigError.effectiveConfigConflict("检测到循环 SSH Include（\(matchedPath)），无法忠实冻结。")
                        }
                        activeStack.insert(canonical)
                        defer { activeStack.remove(canonical) }
                        let childRewritten = try rewriteSSHConfigIncludes(
                            text: childText,
                            baseDirectory: baseDirectory,
                            tempDirectory: tempDirectory,
                            virtualFileOverrides: virtualFileOverrides,
                            counter: &counter,
                            depth: depth + 1,
                            activeStack: &activeStack,
                            seenIgnoreUnknownPatterns: &seenIgnoreUnknownPatterns
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

    /// 校验只读评估目录安全性：必须为当前用户或 root 拥有的普通目录，且不得为非粘滞位的组/全局可写目录。
    private func validateEvaluationParentDirectory(at dirURL: URL, label: String) throws {
        var dirSt = stat()
        guard Darwin.fstatat(AT_FDCWD, dirURL.path, &dirSt, 0) == 0 else {
            throw ConfigError.unsafeFileSystemTarget("无法检查 \(label) 所在目录（\(dirURL.path)）：\(Self.posixErrorMessage())")
        }
        guard (dirSt.st_mode & S_IFMT) == S_IFDIR else {
            throw ConfigError.unsafeFileSystemTarget("\(label) 所在路径不是目录（\(dirURL.path)）。")
        }
        let currentUID = Darwin.geteuid()
        guard dirSt.st_uid == currentUID || dirSt.st_uid == 0 else {
            throw ConfigError.unsafeFileSystemTarget("\(label) 所在目录属主不受信任（\(dirURL.path)）。")
        }
        let mode = dirSt.st_mode & 0o7777
        let isRootStickyDir = dirSt.st_uid == 0 && (mode & S_ISVTX) != 0
        guard (mode & 0o022) == 0 || isRootStickyDir else {
            throw ConfigError.unsafeFileSystemTarget(
                "\(label) 所在目录权限不安全（组或其他用户可写，当前权限 \(String(format: "%04o", mode))）：\(dirURL.path)"
            )
        }
    }

    /// 沿符号链接链逐跳核验每一跳链接本身的属主与所在目录安全性（允许当前用户或 root 拥有的可信符号链接，阻断他人的链接劫持与循环链接）。
    private func validateEvaluationSymlinkChain(at url: URL, label: String) throws {
        let currentUID = Darwin.geteuid()
        var currentURL = url
        var hops = 0
        while true {
            try validateEvaluationParentDirectory(at: currentURL.deletingLastPathComponent(), label: label)
            var lst = stat()
            guard Darwin.lstat(currentURL.path, &lst) == 0 else {
                let err = errno
                if err == ENOENT {
                    throw ConfigError.effectiveConfigConflict("SSH 评估配置 \(label) 为悬空符号链接，无法忠实读取。")
                }
                throw ConfigError.unsafeFileSystemTarget("无法检查 SSH 评估配置 \(label)：\(Self.posixErrorMessage(err))")
            }
            guard (lst.st_mode & S_IFMT) == S_IFLNK else {
                return
            }
            guard lst.st_uid == currentUID || lst.st_uid == 0 else {
                throw ConfigError.unsafeFileSystemTarget("SSH 评估配置 \(label) 的符号链接属主不受信任。")
            }
            hops += 1
            guard hops <= 16 else {
                throw ConfigError.effectiveConfigConflict("SSH 评估配置 \(label) 符号链接层级过深或存在循环。")
            }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let len = Darwin.readlink(currentURL.path, &buffer, buffer.count - 1)
            guard len > 0 else {
                throw ConfigError.unsafeFileSystemTarget("无法解析 SSH 评估配置 \(label) 的符号链接：\(Self.posixErrorMessage())")
            }
            let target = String(cString: buffer)
            if target.hasPrefix("/") {
                currentURL = URL(fileURLWithPath: target)
            } else {
                currentURL = currentURL.deletingLastPathComponent().appendingPathComponent(target)
            }
        }
    }

    /// 只读评估读取：严格匹配 OpenSSH 权限与属主边界（允许可信普通符号链接目标，要求当前用户或 root 属主且禁止组/全局可写，拒绝非常规文件与不可读目标，绝不复制到 0600 快照绕过 OpenSSH 校验）。
    func readEvaluationRegularFileIfPresent(at url: URL, label: String? = nil) throws -> Data? {
        let effectiveLabel = label ?? url.path
        var lst = stat()
        if Darwin.lstat(url.path, &lst) != 0 {
            let err = errno
            if err == ENOENT {
                return nil
            }
            throw ConfigError.unsafeFileSystemTarget("无法检查 SSH 配置 \(effectiveLabel)：\(Self.posixErrorMessage(err))")
        }
        return try readEvaluationRegularFileRequired(at: url, label: effectiveLabel)
    }

    func readEvaluationRegularFileRequired(at url: URL, label: String? = nil) throws -> Data {
        let effectiveLabel = label ?? url.path
        try validateEvaluationSymlinkChain(at: url, label: effectiveLabel)

        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            throw ConfigError.effectiveConfigConflict("无法打开 SSH 配置文件 \(effectiveLabel)：\(Self.posixErrorMessage())")
        }
        defer { Darwin.close(fd) }
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            throw ConfigError.effectiveConfigConflict("无法检查 SSH 配置文件 \(effectiveLabel)：\(Self.posixErrorMessage())")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw ConfigError.unsafeFileSystemTarget("SSH 配置文件 \(effectiveLabel) 不是普通文件，无法忠实冻结。")
        }
        let currentUID = Darwin.geteuid()
        guard st.st_uid == currentUID || st.st_uid == 0 else {
            throw ConfigError.unsafeFileSystemTarget("SSH 配置文件 \(effectiveLabel) 属主不受信任（uid=\(st.st_uid)），已拒绝评估。")
        }
        let mode = st.st_mode & 0o7777
        guard (mode & 0o022) == 0 else {
            throw ConfigError.unsafeFileSystemTarget(
                "SSH 配置文件 \(effectiveLabel) 权限不安全（组或其他用户可写，当前权限 \(String(format: "%04o", mode))），已拒绝评估。"
            )
        }
        // 同时核验最终解析后目标所在目录，防止通过软链指向组/全局可写目录内的文件。
        let resolvedParent = url.resolvingSymlinksInPath().deletingLastPathComponent()
        try validateEvaluationParentDirectory(at: resolvedParent, label: effectiveLabel)

        do {
            return try readAllBytes(from: fd, label: url.lastPathComponent, maxBytes: 4 * 1024 * 1024)
        } catch {
            throw ConfigError.effectiveConfigConflict("读取 SSH 配置文件 \(effectiveLabel) 失败：\(error.localizedDescription)")
        }
    }
}
