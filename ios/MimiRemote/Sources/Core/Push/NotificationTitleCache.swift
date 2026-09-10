import Foundation

/// App 与通知扩展之间共享的「短标签 → 会话标题」缓存。
///
/// 隐私边界：推送 Provider 只发枚举与摘要，永远拿不到标题、项目名或主机名。
/// 这些文案只在设备上由 App 写进 App Group 容器，再由通知扩展在展示前读出来
/// 改写通知。文件里只存摘要键加标题 / 项目 / 主机 / 运行时，绝不存 thread id、
/// prompt 或工作目录路径。
///
/// 这个文件同时编译进通知扩展，只允许依赖 Foundation。
struct NotificationTitleCache: Codable, Equatable {
    static let schemaVersion = 1
    static let appGroupID = "group.com.gaixianggeng.mimi"
    static let fileName = "notification-titles-v1.json"
    /// 超过上限按 `updatedAt` 淘汰最旧的；锁屏只关心最近活跃的会话。
    static let maxEntries = 400

    struct Entry: Codable, Equatable {
        static let titleLimit = 120
        static let projectLimit = 64
        static let hostNameLimit = 48

        let title: String
        let project: String
        /// "codex" / "claude"。扩展改写时以推送里的 runtime 为准，这里仅作兜底。
        let runtime: String
        /// 连接档案的显示名，只在用户有多个档案时进入副标题。
        let hostName: String
        let updatedAt: Date

        init(title: String, project: String, runtime: String, hostName: String, updatedAt: Date) {
            self.title = Self.sanitized(title, limit: Self.titleLimit)
            self.project = Self.sanitized(project, limit: Self.projectLimit)
            self.runtime = Self.sanitized(runtime, limit: 16).lowercased()
            self.hostName = Self.sanitized(hostName, limit: Self.hostNameLimit)
            self.updatedAt = updatedAt
        }

        /// 通知只有一行标题；换行与首尾空白进了系统 UI 只会显示成空洞。
        private static func sanitized(_ value: String, limit: Int) -> String {
            let flattened = value
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(flattened.prefix(limit))
        }
    }

    let schemaVersion: Int
    /// 用户保存的连接档案数。多于一个时扩展才把主机名放进副标题。
    let profileCount: Int
    /// 键为 `NotificationSessionTag.cacheKey`（16 位会话标签）。
    let entries: [String: Entry]

    static let empty = NotificationTitleCache(profileCount: 0, entries: [:])

    init(profileCount: Int, entries: [String: Entry]) {
        self.schemaVersion = Self.schemaVersion
        self.profileCount = max(0, profileCount)
        self.entries = entries
    }

    var showsHostName: Bool { profileCount > 1 }

    /// App Group 容器里的缓存路径。容器不可用（例如 entitlement 缺失）时为 nil，
    /// 所有读写都静默降级，通知回退到 Provider 的通用文案。
    static var defaultFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - 读取

    /// 缺文件、损坏或未来版本一律当作空缓存；扩展只有几秒预算，不做任何修复。
    static func load(fileURL: URL? = defaultFileURL) -> NotificationTitleCache {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return .empty }
        return decode(data) ?? .empty
    }

    static func decode(_ data: Data) -> NotificationTitleCache? {
        try? makeDecoder().decode(NotificationTitleCache.self, from: data)
    }

    /// 16 位标签精确匹配；4 位审批标签只在同一档案下恰好命中一条时才返回，
    /// 有歧义宁可保留通用文案，也不能把别的会话标题贴到这条审批上。
    func entry(profileTag: String, sessionTag: String) -> Entry? {
        let normalizedTag = sessionTag.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedProfile = profileTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedProfile.isEmpty else { return nil }
        switch normalizedTag.count {
        case 16:
            return entries[NotificationSessionTag.cacheKey(profileTag: normalizedProfile, sessionTag: normalizedTag)]
        case 4:
            let prefix = NotificationSessionTag.cacheKey(profileTag: normalizedProfile, sessionTag: normalizedTag)
            var match: Entry?
            for (key, value) in entries where key.hasPrefix(prefix) {
                if match != nil { return nil }
                match = value
            }
            return match
        default:
            return nil
        }
    }

    // MARK: - 写入

    /// 先写临时文件再原子替换：扩展可能在任意时刻读取，绝不能看到写了一半的 JSON。
    /// 条目超过 `maxEntries` 时只保留 `updatedAt` 最新的一批。
    static func write(
        entries: [String: Entry],
        profileCount: Int = 1,
        fileURL: URL? = defaultFileURL
    ) throws {
        guard let fileURL else { return }
        let cache = NotificationTitleCache(profileCount: profileCount, entries: capped(entries))
        let data = try makeEncoder().encode(cache)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS) && !targetEnvironment(macCatalyst)
        // 推送常在锁屏时到达；文件保护必须允许首次解锁后的读取，否则扩展打不开缓存。
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: fileURL, options: options)
    }

    static func clear(fileURL: URL? = defaultFileURL) {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func capped(_ entries: [String: Entry], limit: Int = maxEntries) -> [String: Entry] {
        guard entries.count > limit else { return entries }
        // 时间相同时按键排序，保证淘汰结果可复现。
        let kept = entries.sorted { lhs, rhs in
            if lhs.value.updatedAt != rhs.value.updatedAt {
                return lhs.value.updatedAt > rhs.value.updatedAt
            }
            return lhs.key < rhs.key
        }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profileCount
        case entries
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported notification title cache schema"
            )
        }
        self.init(
            profileCount: try values.decodeIfPresent(Int.self, forKey: .profileCount) ?? 0,
            entries: try values.decode([String: Entry].self, forKey: .entries)
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
