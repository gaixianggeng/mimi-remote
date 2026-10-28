import CryptoKit
import Foundation

struct MediaPreviewPayload: Sendable {
    let name: String
    let contentBase64: String

    init(response: FileReadResponse) {
        name = response.name
        contentBase64 = response.contentBase64
    }
}

/// 串行处理文件预览的 Base64 解码与临时文件写入。
///
/// SessionStore 运行在 MainActor；把同步文件工作收口到独立 actor 后，大文件预览不会占用 UI
/// 执行器。串行执行也能限制同时解码多份大 Base64 时的瞬时内存峰值。
actor MediaWorker {
    static let shared = MediaWorker()

    private let previewRootDirectory: URL
    private let now: @Sendable () -> Date
    private let launchedAt: Date
    private var sweptPreviousRunPreviews = false

#if DEBUG
    private var lastPreviewWorkWasOnMainThread = false
#endif

    init(
        previewRootDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimiRemotePreviews", isDirectory: true),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.previewRootDirectory = previewRootDirectory
        self.now = now
        launchedAt = now()
    }

    func previewURL(
        from payload: MediaPreviewPayload,
        profileID: String
    ) throws -> URL {
        try Task.checkCancellation()

#if DEBUG
        lastPreviewWorkWasOnMainThread = Thread.isMainThread
#endif

        guard let data = Data(base64Encoded: payload.contentBase64) else {
            throw FilePreviewStoreError.invalidPayload
        }
        try Task.checkCancellation()
        sweepPreviousRunPreviewsIfNeeded()

        // 每个 Profile 使用独立临时目录，后续删除设备档案时可以定向清理；
        // 目录名只保存不可逆摘要，不把 endpoint 或其他连接信息写入文件系统。
        let directory = previewRootDirectory.appendingPathComponent(
            Self.profileDirectoryComponent(profileID),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Task.checkCancellation()

        // 文件名按内容摘要区分：同一份内容反复预览复用同一个副本，不再每次多写一份（#918）。
        // 副本可能同时被多个图片视图或 QuickLook 引用，本次运行内不按请求删除。
        let filename = Self.safePreviewFilename(payload.name)
        let url = directory.appendingPathComponent(
            "\(Self.contentDigest(data))-\(filename)",
            isDirectory: false
        )
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size == data.count {
            try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
            return url
        }

        do {
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
            try Task.checkCancellation()
            return url
        } catch is CancellationError {
            // 取消发生在原子写入完成之后时也移除无消费者的文件，避免反复切换主机留下垃圾。
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
    }

    /// 删除连接档案时清掉它的全部预览副本。
    func discardPreviews(profileID: String) {
        let directory = previewRootDirectory.appendingPathComponent(
            Self.profileDirectoryComponent(profileID),
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: directory)
    }

    /// 本次运行第一次预览时清掉上一次运行（含异常退出）留下的副本：它们不可能还被本进程的界面
    /// 引用。本次运行写入或复用过的副本修改时间都不早于启动时刻，留到下次启动再清，
    /// 避免删掉仍挂在图片视图里、之后会交给 QuickLook 的文件（#918）。
    private func sweepPreviousRunPreviewsIfNeeded() {
        guard !sweptPreviousRunPreviews else { return }
        sweptPreviousRunPreviews = true
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: previewRootDirectory,
            includingPropertiesForKeys: keys
        ) else {
            return
        }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < launchedAt
            else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

#if DEBUG
    func lastPreviewWorkRanOnMainThreadForTesting() -> Bool {
        lastPreviewWorkWasOnMainThread
    }
#endif

    nonisolated static func safePreviewFilename(_ rawName: String) -> String {
        let fallback = "preview"
        let lastComponent = (rawName as NSString)
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lastComponent.isEmpty else {
            return fallback
        }
        let blocked = CharacterSet(charactersIn: "/\\:\u{0}")
        let cleaned = lastComponent
            .components(separatedBy: blocked)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private nonisolated static func contentDigest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func profileDirectoryComponent(_ profileID: String) -> String {
        let normalized = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized.isEmpty ? "legacy" : normalized
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
