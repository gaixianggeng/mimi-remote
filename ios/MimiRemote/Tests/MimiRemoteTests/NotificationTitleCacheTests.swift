import Foundation
import XCTest
@testable import MimiRemote

final class NotificationTitleCacheTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationTitleCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(NotificationTitleCache.fileName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    // MARK: - 标签算法

    /// 与 internal/pushbridge/tags.go 的向量一致；审批标签正好是消息标签的前缀。
    @MainActor
    func testSessionTagsMatchProviderAlgorithm() {
        XCTAssertEqual(NotificationSessionTag.messageTag(threadID: "thread-1"), "9E61BAD1E6C4DDAF")
        XCTAssertEqual(NotificationSessionTag.approvalTag(threadID: "thread-1"), "9E61")
        XCTAssertEqual(NotificationSessionTag.messageTag(threadID: " thread-1 \n"), "9E61BAD1E6C4DDAF")
        XCTAssertEqual(
            NotificationSessionTag.profileTag(installationID: "installation-1"),
            LockScreenApprovalRouting.profileTag(installationID: "installation-1")
        )
        XCTAssertEqual(
            NotificationSessionTag.messageTag(threadID: "thread-1"),
            LockScreenApprovalRouting.messageSessionTag(threadID: "thread-1")
        )
        let profileTag = NotificationSessionTag.profileTag(installationID: "installation-1")
        XCTAssertEqual(profileTag.count, 16)
        XCTAssertEqual(profileTag, profileTag.lowercased())
        XCTAssertEqual(
            NotificationSessionTag.cacheKey(profileTag: profileTag.uppercased(), sessionTag: "9e61bad1e6c4ddaf"),
            profileTag + ":9E61BAD1E6C4DDAF"
        )
    }

    // MARK: - 读写

    func testRoundTripPreservesEntriesAndProfileCount() throws {
        let entries = [
            key("p1", "thread-1"): entry(title: "重构登录页", project: "mimi-remote"),
            key("p1", "thread-2"): entry(title: "Fix CI", project: "agentd", runtime: "claude", hostName: "Studio"),
        ]
        try NotificationTitleCache.write(entries: entries, profileCount: 2, fileURL: fileURL)

        let loaded = NotificationTitleCache.load(fileURL: fileURL)
        XCTAssertEqual(loaded.entries, entries)
        XCTAssertEqual(loaded.profileCount, 2)
        XCTAssertTrue(loaded.showsHostName)
        XCTAssertEqual(loaded.schemaVersion, NotificationTitleCache.schemaVersion)

        let data = try Data(contentsOf: fileURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("thread-1"), "文件里只能出现摘要键，不能出现 thread id")
    }

    func testMissingCorruptAndFutureSchemaLoadAsEmpty() throws {
        XCTAssertEqual(NotificationTitleCache.load(fileURL: fileURL), .empty)
        XCTAssertEqual(NotificationTitleCache.load(fileURL: nil), .empty)

        try Data("{not json".utf8).write(to: fileURL)
        XCTAssertEqual(NotificationTitleCache.load(fileURL: fileURL), .empty)

        try Data(#"{"schemaVersion":99,"profileCount":1,"entries":{}}"#.utf8).write(to: fileURL)
        XCTAssertEqual(NotificationTitleCache.load(fileURL: fileURL), .empty)
        XCTAssertFalse(NotificationTitleCache.load(fileURL: fileURL).showsHostName)
    }

    func testWriteCapsToMostRecentEntries() throws {
        var entries: [String: NotificationTitleCache.Entry] = [:]
        for index in 0..<(NotificationTitleCache.maxEntries + 25) {
            entries[key("p1", "thread-\(index)")] = entry(
                title: "Session \(index)",
                updatedAt: referenceDate.addingTimeInterval(TimeInterval(index))
            )
        }
        try NotificationTitleCache.write(entries: entries, fileURL: fileURL)

        let loaded = NotificationTitleCache.load(fileURL: fileURL)
        XCTAssertEqual(loaded.entries.count, NotificationTitleCache.maxEntries)
        XCTAssertNil(loaded.entries[key("p1", "thread-0")], "最旧的条目应被淘汰")
        XCTAssertNil(loaded.entries[key("p1", "thread-24")])
        XCTAssertNotNil(loaded.entries[key("p1", "thread-25")], "从第 25 条起是最新的 400 条")
        XCTAssertNotNil(loaded.entries[key("p1", "thread-424")])
    }

    func testWriteReplacesPreviousContentAtomically() throws {
        try NotificationTitleCache.write(entries: [key("p1", "thread-1"): entry(title: "Old")], fileURL: fileURL)
        try NotificationTitleCache.write(entries: [key("p1", "thread-2"): entry(title: "New")], fileURL: fileURL)

        let loaded = NotificationTitleCache.load(fileURL: fileURL)
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.entries[key("p1", "thread-2")]?.title, "New")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, [NotificationTitleCache.fileName], "不能留下临时文件")
    }

    func testClearRemovesFileAndTolerantOfMissingFile() throws {
        try NotificationTitleCache.write(entries: [key("p1", "thread-1"): entry(title: "A")], fileURL: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        NotificationTitleCache.clear(fileURL: fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(NotificationTitleCache.load(fileURL: fileURL), .empty)

        NotificationTitleCache.clear(fileURL: fileURL)
        NotificationTitleCache.clear(fileURL: nil)
    }

    // MARK: - 查找

    func testExactLookupRequiresFullSixteenCharacterTag() {
        let cache = NotificationTitleCache(
            profileCount: 1,
            entries: [key("p1", "thread-1"): entry(title: "重构登录页")]
        )
        let tag = NotificationSessionTag.messageTag(threadID: "thread-1")
        XCTAssertEqual(cache.entry(profileTag: profileTag("p1"), sessionTag: tag)?.title, "重构登录页")
        XCTAssertEqual(
            cache.entry(profileTag: profileTag("p1").uppercased(), sessionTag: tag.lowercased())?.title,
            "重构登录页",
            "大小写差异不应影响命中"
        )
        XCTAssertNil(cache.entry(profileTag: profileTag("p1"), sessionTag: NotificationSessionTag.messageTag(threadID: "thread-9")))
        XCTAssertNil(cache.entry(profileTag: profileTag("p1"), sessionTag: String(tag.prefix(8))), "既不是 16 位也不是 4 位的标签不匹配")
        XCTAssertNil(cache.entry(profileTag: profileTag("p1"), sessionTag: ""))
        XCTAssertNil(cache.entry(profileTag: "", sessionTag: tag))
    }

    func testPrefixLookupRequiresUniqueMatchWithinProfile() {
        let tag1 = NotificationSessionTag.messageTag(threadID: "thread-1")
        // 人为构造一个与 thread-1 共享 4 位前缀的第二个键，模拟审批标签碰撞。
        let colliding = String(tag1.prefix(4)) + String(repeating: "0", count: 12)
        XCTAssertNotEqual(colliding, tag1)

        let unique = NotificationTitleCache(
            profileCount: 1,
            entries: [key("p1", "thread-1"): entry(title: "唯一命中")]
        )
        XCTAssertEqual(
            unique.entry(profileTag: profileTag("p1"), sessionTag: NotificationSessionTag.approvalTag(threadID: "thread-1"))?.title,
            "唯一命中"
        )

        let ambiguous = NotificationTitleCache(
            profileCount: 1,
            entries: [
                key("p1", "thread-1"): entry(title: "A"),
                NotificationSessionTag.cacheKey(profileTag: profileTag("p1"), sessionTag: colliding): entry(title: "B"),
            ]
        )
        XCTAssertNil(
            ambiguous.entry(profileTag: profileTag("p1"), sessionTag: String(tag1.prefix(4))),
            "同一档案下多条命中时必须放弃改写，不能猜"
        )
        XCTAssertEqual(ambiguous.entry(profileTag: profileTag("p1"), sessionTag: tag1)?.title, "A", "16 位仍能精确命中")
    }

    func testLookupIsScopedToProfile() {
        let cache = NotificationTitleCache(
            profileCount: 2,
            entries: [
                key("p1", "thread-1"): entry(title: "Mac A"),
                key("p2", "thread-1"): entry(title: "Mac B"),
            ]
        )
        let tag = NotificationSessionTag.messageTag(threadID: "thread-1")
        XCTAssertEqual(cache.entry(profileTag: profileTag("p1"), sessionTag: tag)?.title, "Mac A")
        XCTAssertEqual(cache.entry(profileTag: profileTag("p2"), sessionTag: tag)?.title, "Mac B")
        XCTAssertNil(cache.entry(profileTag: profileTag("p3"), sessionTag: tag))
        // 前缀匹配同样按档案隔离：p1 与 p2 各自只有一条，不算歧义。
        let short = String(tag.prefix(4))
        XCTAssertEqual(cache.entry(profileTag: profileTag("p1"), sessionTag: short)?.title, "Mac A")
        XCTAssertEqual(cache.entry(profileTag: profileTag("p2"), sessionTag: short)?.title, "Mac B")
    }

    func testEntrySanitizesFreeText() {
        let entry = NotificationTitleCache.Entry(
            title: "  第一行\n第二行\r\n  ",
            project: String(repeating: "p", count: 200),
            runtime: " Claude ",
            hostName: "Studio\nMac",
            updatedAt: referenceDate
        )
        XCTAssertEqual(entry.title, "第一行 第二行")
        XCTAssertEqual(entry.project.count, NotificationTitleCache.Entry.projectLimit)
        XCTAssertEqual(entry.runtime, "claude")
        XCTAssertEqual(entry.hostName, "Studio Mac")
    }

    // MARK: - App 侧写入

    func testWriterEntriesSkipDraftsAndUntitledAndKeyBothIdentifiers() {
        let sessions = [
            makeSession(id: "thread-1", title: "重构登录页", resumeID: "resume-1"),
            makeSession(id: "thread-2", title: "   ", resumeID: nil),
            makeSession(id: "draft-1", title: "草稿", resumeID: nil, source: "local", status: "draft"),
            makeSession(id: "thread-3", title: "Claude 任务", resumeID: "thread-3", runtimeProvider: "claude"),
        ]
        let tag = profileTag("p1")
        let entries = NotificationTitleCacheWriter.entries(sessions: sessions, profileTag: tag, hostName: "Studio")

        XCTAssertEqual(entries.count, 3, "thread-1 按 id 与 resumeID 各登记一次，thread-3 的 resumeID 与 id 相同只登记一次")
        XCTAssertEqual(entries[key("p1", "thread-1")]?.title, "重构登录页")
        XCTAssertEqual(entries[key("p1", "resume-1")]?.title, "重构登录页")
        XCTAssertEqual(entries[key("p1", "thread-1")]?.runtime, "codex")
        XCTAssertEqual(entries[key("p1", "thread-1")]?.hostName, "Studio")
        XCTAssertEqual(entries[key("p1", "thread-1")]?.project, "Mimi Demo")
        XCTAssertEqual(entries[key("p1", "thread-3")]?.runtime, "claude")
        XCTAssertNil(entries[key("p1", "thread-2")])
        XCTAssertNil(entries[key("p1", "draft-1")])
        for value in entries.values {
            XCTAssertFalse(value.project.contains("/private/"), "缓存里不能出现工作目录路径")
        }
    }

    func testWriterMergeReplacesOwnProfileAndKeepsOthers() {
        let existing = [
            key("p1", "thread-old"): entry(title: "旧会话"),
            key("p2", "thread-x"): entry(title: "另一台 Mac"),
        ]
        let fresh = [key("p1", "thread-new"): entry(title: "新会话")]
        let merged = NotificationTitleCacheWriter.merge(existing: existing, fresh: fresh, profileTag: profileTag("p1"))
        XCTAssertNil(merged[key("p1", "thread-old")], "当前档案的旧条目整体替换")
        XCTAssertEqual(merged[key("p1", "thread-new")]?.title, "新会话")
        XCTAssertEqual(merged[key("p2", "thread-x")]?.title, "另一台 Mac", "其它档案的条目保留")
    }

    @MainActor
    func testWriterWritesWhenEnabledAndClearsWhenDisabledOrUnpaired() throws {
        let writer = NotificationTitleCacheWriter(fileURL: fileURL, debounceInterval: 0)
        let profiles = [
            ConnectionProfile(id: "profile-1", displayName: "Studio", endpoint: "http://100.64.0.1:8787", lastSuccessfulAt: nil, installationID: "installation-1"),
            ConnectionProfile(id: "profile-2", displayName: "Laptop", endpoint: "http://100.64.0.2:8787", lastSuccessfulAt: nil, installationID: "installation-2"),
        ]
        let sessions = [makeSession(id: "thread-1", title: "重构登录页", resumeID: nil)]

        writer.synchronize(sessions: sessions, profiles: profiles, activeProfileID: "profile-1", isEnabled: true)
        writer.waitForPendingWrites()
        var loaded = NotificationTitleCache.load(fileURL: fileURL)
        let expectedTag = NotificationSessionTag.profileTag(installationID: "installation-1")
        XCTAssertEqual(
            loaded.entry(profileTag: expectedTag, sessionTag: NotificationSessionTag.messageTag(threadID: "thread-1"))?.title,
            "重构登录页"
        )
        XCTAssertEqual(loaded.profileCount, 2)

        // 未配对档案（无 installationID）没有可命中的推送：清空。
        let unpaired = [ConnectionProfile(id: "profile-3", displayName: "New", endpoint: "http://100.64.0.3:8787", lastSuccessfulAt: nil)]
        writer.synchronize(sessions: sessions, profiles: unpaired, activeProfileID: "profile-3", isEnabled: true)
        writer.waitForPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        writer.synchronize(sessions: sessions, profiles: profiles, activeProfileID: "profile-1", isEnabled: true)
        writer.waitForPendingWrites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        writer.synchronize(sessions: sessions, profiles: profiles, activeProfileID: "profile-1", isEnabled: false)
        writer.waitForPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "关闭锁屏提醒后不留标题副本")
        loaded = NotificationTitleCache.load(fileURL: fileURL)
        XCTAssertEqual(loaded, .empty)
    }

    // MARK: - Helpers

    private func profileTag(_ installationID: String) -> String {
        NotificationSessionTag.profileTag(installationID: installationID)
    }

    private func key(_ installationID: String, _ threadID: String) -> String {
        NotificationSessionTag.cacheKey(
            profileTag: profileTag(installationID),
            sessionTag: NotificationSessionTag.messageTag(threadID: threadID)
        )
    }

    private func entry(
        title: String,
        project: String = "mimi-remote",
        runtime: String = "codex",
        hostName: String = "Studio",
        updatedAt: Date? = nil
    ) -> NotificationTitleCache.Entry {
        NotificationTitleCache.Entry(
            title: title,
            project: project,
            runtime: runtime,
            hostName: hostName,
            updatedAt: updatedAt ?? referenceDate
        )
    }

    private func makeSession(
        id: String,
        title: String,
        resumeID: String?,
        source: String = "codex",
        status: String = "completed",
        runtimeProvider: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            projectID: "project-a",
            project: "Mimi Demo",
            dir: "/private/path-that-must-not-be-shared",
            title: title,
            status: status,
            source: source,
            runtimeProvider: runtimeProvider,
            resumeID: resumeID,
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
    }

    // MARK: - 切换 Mac 时的一致性

    func testCoherenceTreatsInitialProfileAsConsistent() {
        var coherence = NotificationTitleCacheCoherence()
        let sessionsGeneration = coherence.sessionsDidPublish()
        let required = coherence.profileDidPublish("mac-a")
        XCTAssertTrue(NotificationTitleCacheCoherence.isCoherent(
            sessionsGeneration: sessionsGeneration,
            requiredGeneration: required
        ))
    }

    func testCoherenceRejectsPreviousHostSessionsAfterProfileSwitch() {
        var coherence = NotificationTitleCacheCoherence()
        _ = coherence.profileDidPublish("mac-a")
        let staleSessions = coherence.sessionsDidPublish()
        let required = coherence.profileDidPublish("mac-b")
        // 新档案已发布、会话仍是上一台 Mac 的：不能写进缓存。
        XCTAssertFalse(NotificationTitleCacheCoherence.isCoherent(
            sessionsGeneration: staleSessions,
            requiredGeneration: required
        ))
        let clearedSessions = coherence.sessionsDidPublish()
        XCTAssertTrue(NotificationTitleCacheCoherence.isCoherent(
            sessionsGeneration: clearedSessions,
            requiredGeneration: required
        ))
        // 同一档案重复发布不会再次要求新会话。
        XCTAssertEqual(coherence.profileDidPublish("mac-b"), required)
    }

    func testMergeWithEmptyFreshKeepsExistingTitles() {
        let entry = NotificationTitleCache.Entry(
            title: "修复通知",
            project: "mimi",
            runtime: "codex",
            hostName: "Mac",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let existing = ["aaaaaaaaaaaaaaaa:0123456789ABCDEF": entry]
        let merged = NotificationTitleCacheWriter.merge(
            existing: existing,
            fresh: [:],
            profileTag: "aaaaaaaaaaaaaaaa"
        )
        XCTAssertEqual(merged, existing)
    }
}
