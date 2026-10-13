import XCTest
import Combine
@testable import MimiRemote

@MainActor
final class LogStoreTests: XCTestCase {
    func testLogStoreKeepsOnlyBoundedBuffer() async {
        let store = LogStore()
        let sessionID = "sess_test"
        let oversized = String(repeating: "x", count: 140_000)

        store.append(oversized, sessionID: sessionID)
        let didFlush = await waitUntil { !store.log(for: sessionID).isEmpty }
        XCTAssertTrue(didFlush)

        XCTAssertLessThanOrEqual(store.log(for: sessionID).count, 120_000)
    }

    func testVisibleLogKeepsTailWindowAfterFlush() async {
        let store = LogStore()
        let sessionID = "sess_tail"
        let oversized = "drop-prefix-" + String(repeating: "x", count: 90_000) + "tail-suffix"

        store.append(oversized, sessionID: sessionID)
        let didFlush = await waitUntil { store.log(for: sessionID).hasSuffix("tail-suffix") }
        XCTAssertTrue(didFlush)

        let log = store.log(for: sessionID)
        XCTAssertLessThanOrEqual(log.count, 80_000)
        XCTAssertTrue(log.hasSuffix("tail-suffix"))
        XCTAssertFalse(log.contains("drop-prefix-"))
    }

    func testPendingFlushQueueKeepsLatestTailWhenBacklogged() async {
        let store = LogStore()
        let sessionID = "sess_pending_tail"
        let prefix = "drop-pending-prefix-" + String(repeating: "x", count: 120_000)
        let suffix = "pending-tail-suffix"

        store.append(prefix, sessionID: sessionID)
        for index in 0..<30 {
            store.append("chunk-\(index)-" + String(repeating: "y", count: 2_000), sessionID: sessionID)
        }
        store.append(suffix, sessionID: sessionID)
        let didFlush = await waitUntil { store.log(for: sessionID).hasSuffix(suffix) }
        XCTAssertTrue(didFlush)

        let log = store.log(for: sessionID)
        XCTAssertLessThanOrEqual(log.count, 80_000)
        XCTAssertTrue(log.hasSuffix(suffix))
        XCTAssertFalse(log.contains("drop-pending-prefix-"))
    }

    func testPendingFlushQueueTrimsManySmallChunksWithoutDroppingTail() async {
        let store = LogStore()
        let sessionID = "sess_many_pending_chunks"

        for index in 0..<1_800 {
            store.append("old-\(index)-" + String(repeating: "x", count: 96), sessionID: sessionID)
        }
        let suffix = "many-small-chunks-tail"
        store.append(suffix, sessionID: sessionID)
        let didFlush = await waitUntil { store.log(for: sessionID).hasSuffix(suffix) }
        XCTAssertTrue(didFlush)

        let log = store.log(for: sessionID)
        XCTAssertLessThanOrEqual(log.count, 80_000)
        XCTAssertTrue(log.hasSuffix(suffix))
        XCTAssertFalse(log.contains("old-0-"))
    }

    func testLogStoreMaintainsIndependentSessionBuffers() async {
        let store = LogStore()

        store.append("session-a", sessionID: "sess_a")
        store.append("session-b", sessionID: "sess_b")
        let didFlush = await waitUntil {
            store.log(for: "sess_a") == "session-a" && store.log(for: "sess_b") == "session-b"
        }
        XCTAssertTrue(didFlush)

        XCTAssertEqual(store.log(for: "sess_a"), "session-a")
        XCTAssertEqual(store.log(for: "sess_b"), "session-b")
    }

    func testLogStoreScopesSameSessionAndPendingFlushByProfile() async {
        let store = LogStore()
        let sessionID = "shared_session"

        store.activate(profileID: "mac-a")
        store.append("A only", sessionID: sessionID, seq: 7)
        store.activate(profileID: "mac-b")
        store.append("B only", sessionID: sessionID, seq: 7)

        let didFlushB = await waitUntil { store.log(for: sessionID) == "B only" }
        XCTAssertTrue(didFlushB)
        XCTAssertEqual(store.lastSeq(for: sessionID), 7)

        store.activate(profileID: "mac-a")
        let didFlushA = await waitUntil { store.log(for: sessionID) == "A only" }
        XCTAssertTrue(didFlushA)
        XCTAssertEqual(store.lastSeq(for: sessionID), 7)

        store.activate(profileID: "mac-b")
        XCTAssertEqual(store.log(for: sessionID), "B only")
    }

    func testLogStoreUsesOneGlobalLRUBudgetAcrossProfiles() async {
        let store = LogStore()

        store.activate(profileID: "mac-a")
        for index in 0..<LogStore.retainedSessionLimit {
            store.append("A \(index)", sessionID: "sess_\(index)")
        }

        store.activate(profileID: "mac-b")
        store.append("B", sessionID: "sess_b")
        let didFlushB = await waitUntil { store.log(for: "sess_b") == "B" }
        XCTAssertTrue(didFlushB)

        store.activate(profileID: "mac-a")
        XCTAssertEqual(store.log(for: "sess_0"), "", "B 新增日志必须参与同一全局 16-session LRU")
        let didFlushA = await waitUntil { store.log(for: "sess_1") == "A 1" }
        XCTAssertTrue(didFlushA)
    }

    func testLogStoreStripsAnsiTerminalSequences() async {
        let store = LogStore()
        let sessionID = "sess_ansi"

        store.append("\u{001B}[?1049h\u{001B}[32mhello\u{001B}[0m", sessionID: sessionID)
        let didFlush = await waitUntil { store.log(for: sessionID) == "hello" }
        XCTAssertTrue(didFlush)

        let log = store.log(for: sessionID)
        XCTAssertEqual(log, "hello")
        XCTAssertFalse(log.contains("1049"))
    }

    func testAnsiOnlyChunkDoesNotPublishUnchangedLogState() async {
        let store = LogStore()
        let sessionID = "sess_ansi_noop"
        var publishCount = 0
        var cancellables: Set<AnyCancellable> = []

        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        store.append("hello", sessionID: sessionID)
        let didFlush = await waitUntil { store.log(for: sessionID) == "hello" }
        XCTAssertTrue(didFlush)
        let publishCountAfterVisibleText = publishCount

        store.append("\u{001B}[?1049h\u{001B}[?25l\u{001B}[0m", sessionID: sessionID)
        try? await Task.sleep(nanoseconds: 220_000_000)

        // 纯控制序列被清洗成空字符串时，日志内容和渲染行都没变化，不应触发 SwiftUI 刷新。
        XCTAssertEqual(store.log(for: sessionID), "hello")
        XCTAssertEqual(store.lines(for: sessionID).map(\.text), ["hello"])
        XCTAssertEqual(publishCount, publishCountAfterVisibleText)
    }

    func testLogStoreIgnoresReplayedSequencedChunks() async {
        let store = LogStore()
        let sessionID = "sess_seq"

        store.append("one", sessionID: sessionID, seq: 10)
        store.append("-duplicate", sessionID: sessionID, seq: 10)
        store.append("-old", sessionID: sessionID, seq: 9)
        store.append("-two", sessionID: sessionID, seq: 11)
        let didFlush = await waitUntil { store.log(for: sessionID) == "one-two" }
        XCTAssertTrue(didFlush)

        // 重连 bounded replay 可能带回已处理过的日志块；相同或更旧 seq 不应再次进入渲染队列。
        XCTAssertEqual(store.log(for: sessionID), "one-two")
        XCTAssertEqual(store.lastSeq(for: sessionID), 11)
    }

    func testResetClearsLogSequenceWatermark() async {
        let store = LogStore()
        let sessionID = "sess_seq_reset"

        store.append("before", sessionID: sessionID, seq: 7)
        let didFlushBeforeReset = await waitUntil { store.log(for: sessionID) == "before" }
        XCTAssertTrue(didFlushBeforeReset)
        store.reset(sessionID: sessionID)
        store.append("after", sessionID: sessionID, seq: 7)
        let didFlushAfterReset = await waitUntil { store.log(for: sessionID) == "after" }
        XCTAssertTrue(didFlushAfterReset)

        XCTAssertEqual(store.log(for: sessionID), "after")
        XCTAssertEqual(store.lastSeq(for: sessionID), 7)
    }

    func testResetCancelsPendingFlushForSession() async {
        let store = LogStore()
        let sessionID = "sess_reset"

        // reset 必须取消尚未 flush 的批量写入，避免切换会话后旧日志回灌到新视图。
        store.append("should be dropped", sessionID: sessionID)
        store.reset(sessionID: sessionID)
        try? await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(store.log(for: sessionID), "")
    }

    func testLogStoreTrimsLeastRecentlyUsedSessionCaches() async {
        let store = LogStore()
        let retainedLimit = LogStore.retainedSessionLimit

        for index in 0..<retainedLimit {
            store.append("log \(index)", sessionID: "sess_\(index)")
        }
        store.retainSessionCache(sessionID: "sess_0")
        store.append("new log", sessionID: "sess_new")
        let didFlush = await waitUntil { store.log(for: "sess_new") == "new log" }
        XCTAssertTrue(didFlush)

        // 日志缓存按最近使用会话保留，避免多会话长期运行后 buffers/renderedLines 无上限增长。
        XCTAssertEqual(store.log(for: "sess_0"), "log 0")
        XCTAssertEqual(store.log(for: "sess_1"), "")
        XCTAssertEqual(store.log(for: "sess_new"), "new log")
    }

    func testInputPathDoesNotTouchLogStore() async {
        let store = LogStore()
        let sessionID = "sess_test"

        // 输入框由 ComposerView 本地 @State 维护；没有任何按键路径会调用 LogStore。
        XCTAssertEqual(store.log(for: sessionID), "")
    }

    func testSessionLogExportUsesCleanedCurrentCacheWindowAndSafeHeader() async throws {
        let store = LogStore()
        let session = makeSession(id: "sess_export", title: "导出会话")
        let rawLog = "cache-prefix\n"
            + String(repeating: "x", count: 90_000)
            + "\nvisible-original \u{001B}[31mcache-tail\u{001B}[0m"

        store.append(rawLog, sessionID: session.id)
        let didFlush = await waitUntil {
            store.cachedLogForExport(for: session.id).hasSuffix("visible-original cache-tail")
        }
        XCTAssertTrue(didFlush)

        let cachedLog = store.cachedLogForExport(for: session.id)
        XCTAssertTrue(cachedLog.contains("cache-prefix"))
        XCTAssertFalse(store.log(for: session.id).contains("cache-prefix"))
        XCTAssertFalse(cachedLog.contains("\u{001B}"))

        let generatedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-14T01:02:03Z"))
        let payload = try XCTUnwrap(SessionLogExportBuilder.makePayload(
            session: session,
            cachedLog: cachedLog,
            generatedAt: generatedAt,
            appVersion: "1.0 (31)",
            macDisplayName: "工作室 Mac"
        ))
        let sections = payload.content.components(separatedBy: "\n\n")
        XCTAssertEqual(sections.first?.components(separatedBy: "\n"), [
            "生成时间：2026-07-14T01:02:03Z",
            "App 版本：1.0 (31)",
            "会话 ID：sess_export",
            "会话标题：导出会话",
            "当前电脑：工作室 Mac"
        ])
        XCTAssertEqual(Array(sections.dropFirst()).joined(separator: "\n\n"), cachedLog)
        XCTAssertFalse(payload.content.contains("super-secret-token"))
        XCTAssertFalse(payload.content.contains("http://100.64.0.1:8080"))
        XCTAssertFalse(payload.content.localizedCaseInsensitiveContains("keychain"))
    }

    func testSessionLogExportFilenameBoundsUnsafeMultibyteTitle() throws {
        let title = String(repeating: "😀", count: 200) + "/../../坏文件\\名:?%*|\"<>\n"
        let session = makeSession(id: "sess_filename", title: title)
        let generatedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-14T01:02:03Z"))

        let filename = SessionLogExportBuilder.safeFilename(session: session, generatedAt: generatedAt)

        XCTAssertTrue(filename.hasSuffix("-20260714-010203.log"))
        XCTAssertLessThanOrEqual(filename.count, SessionLogExportBuilder.maximumFilenameLength)
        XCTAssertLessThanOrEqual(filename.utf8.count, SessionLogExportBuilder.maximumFilenameUTF8Bytes)
        XCTAssertNil(filename.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:?%*|\"<>\n")))
        XCTAssertFalse(filename.contains(".."))
    }

    func testSessionLogExportRejectsMissingSessionOrEmptyCache() {
        let session = makeSession(id: "sess_empty", title: "空日志")
        let generatedAt = Date(timeIntervalSince1970: 0)

        XCTAssertNil(SessionLogExportBuilder.makePayload(
            session: nil,
            cachedLog: "log",
            generatedAt: generatedAt,
            appVersion: "1.0",
            macDisplayName: "Mac"
        ))
        XCTAssertNil(SessionLogExportBuilder.makePayload(
            session: session,
            cachedLog: " \n\t ",
            generatedAt: generatedAt,
            appVersion: "1.0",
            macDisplayName: "Mac"
        ))
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        intervalNanoseconds: UInt64 = 20_000_000,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return condition()
    }

    private func makeSession(id: String, title: String) -> AgentSession {
        AgentSession(
            id: id,
            projectID: "project_export",
            project: "Export Project",
            dir: "/tmp/export-project",
            title: title,
            status: "idle",
            source: "app-server",
            resumeID: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    func testLogFormatterKeepsAbsoluteLineIDsAfterTailLimit() {
        let log = (0..<365).map { "line \($0)" }.joined(separator: "\n")

        let lines = LogPanelFormatter().renderedLines(from: log, startLineID: 100)

        XCTAssertEqual(lines.count, 360)
        XCTAssertEqual(lines.first?.id, 105)
        XCTAssertEqual(lines.first?.text, "line 5")
        XCTAssertEqual(lines.last?.id, 464)
        XCTAssertEqual(lines.last?.text, "line 364")
    }

    func testLogFormatterCollapsesInlineRepeatedSentences() {
        // 日志重绘在同一行里把整句重画两遍，旧逻辑会原样展示重复内容。
        let log = "● 他说：\"那你得放松。\" 他说：\"那你得放松。\"\n"

        let lines = LogPanelFormatter().renderedLines(from: log)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "他说：\"那你得放松。\"")
    }

    func testLogFormatterDedupsAdjacentRedrawWithPromptChrome() {
        // 相邻两行只差尾部输入框占位符（"… ›Implement {feature} …"），应被视为同一行。
        let log = [
            "● 数据库管理员去看病。",
            "● 数据库管理员去看病。 ›Implement {feature} gpt-5.5 xhigh fast · ~/code",
        ].joined(separator: "\n")

        let lines = LogPanelFormatter().renderedLines(from: log)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "数据库管理员去看病。")
    }

    func testLogFormatterDoesNotTruncatePlainOutputWithPromptLikeChars() {
        // 普通日志里的 "›" / ">Implement" / "•" 不是 prompt 残片，不应被清洗截断。
        let log = [
            "build a › b done",
            "note: > Implement later",
            "data: • item one",
        ].joined(separator: "\n")

        let lines = LogPanelFormatter().renderedLines(from: log)

        XCTAssertEqual(
            lines.map(\.text),
            ["build a › b done", "note: > Implement later", "data: • item one"]
        )
    }

    func testLogFormatterKeepsDistinctOutputLinesSharingPromptPrefix() {
        // 两行只是恰好都含 "›"，内容不同，不能因为 prompt 截断后 key 相同被误合并。
        let log = ["Step › one", "Step › two"].joined(separator: "\n")

        let lines = LogPanelFormatter().renderedLines(from: log)

        XCTAssertEqual(lines.map(\.text), ["Step › one", "Step › two"])
    }
}
