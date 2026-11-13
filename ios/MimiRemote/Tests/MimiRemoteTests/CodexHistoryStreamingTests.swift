import XCTest
@testable import MimiRemote

@MainActor
final class CodexHistoryStreamingTests: XCTestCase {
    private let sessionID = "thread-history-stream"
    private let turnID = "turn-history-stream"
    private let itemID = "assistant-history-stream"

    func testRunningHistoryThenDeltaContinuesInFullSummaryAndItemPages() async throws {
        for mode in ["full", "summary", "items"] {
            let store = ConversationStore()
            let history = try await projectHistory("Hel", mode: mode)
            store.setHistory(history, sessionID: sessionID)
            let original = try XCTUnwrap(store.messages(for: sessionID).first)
            XCTAssertEqual(original.sendStatus, .sending)
            try applyDelta("lo", to: store)
            let message = try XCTUnwrap(store.messages(for: sessionID).first)
            XCTAssertEqual(message.id, original.id)
            XCTAssertEqual(message.content, "Hello", mode)
            XCTAssertEqual(message.sendStatus, .sending)
            XCTAssertEqual(store.messages(for: sessionID).count, 1)
        }
    }

    func testRunningHistoryPreservesWhitespaceBeforeNextDelta() async throws {
        for phase in ["commentary", "final_answer"] {
            let store = ConversationStore()
            store.setHistory(try await projectHistory("Hello \n", phase: phase), sessionID: sessionID)
            try applyDelta("world", to: store, phase: phase)
            XCTAssertEqual(store.messages(for: sessionID).first?.content, "Hello \nworld")
        }
    }

    func testUnsequencedRunningHistoryPreservesAlreadyReceivedLiveText() async throws {
        let cases = [
            ("Hello", "Hel"),
            ("Hel", "Hello"),
            ("ha", "ha"),
            ("hahaha", "haha"),
            ("好👋\n继续", "你好👋\n")
        ]
        for (live, history) in cases {
            let store = ConversationStore()
            try applyDelta(live, to: store)
            let id = try XCTUnwrap(store.messages(for: sessionID).first?.id)
            store.setHistory(try await projectHistory(history), sessionID: sessionID)
            // 上游未提供与 delta 同源的快照序号，不能按相同正文猜测重放边界。
            // 先保留已经接收的 live 文本；完整正文由终态 Item 权威收敛。
            XCTAssertEqual(store.messages(for: sessionID).map(\.content), [live])
            XCTAssertEqual(store.messages(for: sessionID).first?.id, id)
            try applyDelta("!", to: store)
            XCTAssertEqual(store.messages(for: sessionID).map(\.content), [live + "!"])
            store.setHistory(try await projectHistory("Final complete text", status: "completed"), sessionID: sessionID)
            XCTAssertEqual(store.messages(for: sessionID).map(\.content), ["Final complete text"])
        }
    }

    func testPendingDeltaAndRepeatedHistoryDoNotDuplicateOrTruncate() async throws {
        let store = ConversationStore()
        store.setHistory(try await projectHistory("Hel"), sessionID: sessionID)
        try applyDelta("lo", to: store, flush: false)
        // setHistory 必须先吸收尚未发布的 80ms delta，再合并重叠快照。
        store.setHistory(try await projectHistory("Hello"), sessionID: sessionID)
        store.setHistory(try await projectHistory("Hel"), sessionID: sessionID)
        try applyDelta(" world", to: store)
        store.setHistory(try await projectHistory("Hello world"), sessionID: sessionID)
        XCTAssertEqual(store.messages(for: sessionID).map(\.content), ["Hello world"])
        XCTAssertFalse(store.hasPendingAssistantDeltasForTesting)
    }

    func testOrdinaryDeltasRetainRepeatedWords() async throws {
        let store = ConversationStore()
        store.setHistory(try await projectHistory("ha"), sessionID: sessionID)
        try applyDelta("ha", to: store)
        try applyDelta("ha", to: store)
        XCTAssertEqual(store.messages(for: sessionID).first?.content, "hahaha")
    }

    func testCompletedHistoryRejectsLateDeltaEvenWhenThreadIsActive() async throws {
        for itemStatus in [nil, "completed"] as [String?] {
            let store = ConversationStore()
            let history = try await projectHistory(
                "Hello", status: itemStatus == nil ? "completed" : "inProgress", itemStatus: itemStatus
            )
            store.setHistory(history, sessionID: sessionID)
            XCTAssertEqual(store.messages(for: sessionID).first?.sendStatus, .confirmed)
            try applyDelta(" stale", to: store)
            XCTAssertEqual(store.messages(for: sessionID).map(\.content), ["Hello"])
        }
    }

    func testCompletedHistorySettlesStreamingItemWithoutLiveCompletionMutation() async throws {
        let store = ConversationStore()
        try applyDelta("Hel", to: store)
        let liveVersion = store.timelineSource(for: sessionID).versions.live
        store.setHistory(try await projectHistory("Hello", status: "completed"), sessionID: sessionID)
        let message = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(message.content, "Hello")
        XCTAssertEqual(message.sendStatus, .confirmed)
        XCTAssertEqual(message.turnLifecycle, .completed)
        // 读取历史只更新历史来源；不能伪造实时完成事件再触发完成反馈。
        XCTAssertEqual(store.timelineSource(for: sessionID).versions.live, liveVersion)
        try applyDelta(" old", to: store)
        XCTAssertEqual(store.messages(for: sessionID).first?.content, "Hello")
    }

    func testCompletedLiveItemRejectsLateRunningSnapshotAndDelta() async throws {
        let store = ConversationStore()
        try applyDelta("Hel", to: store)
        var projector = CodexAppServerEventProjector()
        let notification = try notification("item/completed", extra: [
            "item": ["id": itemID, "type": "agentMessage", "text": "Hello", "phase": "final_answer"]
        ])
        guard case .messageCompleted(let message, let metadata) = projector.project(notification) else {
            return XCTFail("Expected completed message")
        }
        store.completeMessage(message, metadata: metadata, fallbackSessionID: sessionID)
        store.setHistory(try await projectHistory("Hel"), sessionID: sessionID)
        try applyDelta(" old", to: store)
        XCTAssertEqual(store.messages(for: sessionID).map(\.content), ["Hello"])
        XCTAssertEqual(store.messages(for: sessionID).first?.sendStatus, .confirmed)
    }

    private func projectHistory(
        _ text: String,
        mode: String = "full",
        phase: String = "final_answer",
        status: String = "inProgress",
        itemStatus: String? = nil
    ) async throws -> [CodexHistoryMessage] {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        var item: [String: Any] = ["id": itemID, "type": "agentMessage", "text": text, "phase": phase]
        item["status"] = itemStatus
        let turn: [String: Any] = ["id": turnID, "status": status, "startedAt": 100, "items": [item]]
        let turnJSON = try object(turn)
        if mode == "items" {
            return await runtime.historyMessages(
                fromItems: [try object(item)],
                continuation: HistoryTurnItemsContinuation(
                    turnID: turnID, turn: turnJSON, turnIndex: 0, itemOffset: 0,
                    cursor: nil, pageLimit: 20, threadIsActive: true,
                    isLatestTurn: true, hasVisibleUserMessageBefore: false
                ),
                sessionID: sessionID,
                snapshotReadAt: Date(timeIntervalSince1970: 200)
            )
        }
        return await runtime.historyMessages(
            fromTurns: [turnJSON], sessionID: sessionID, threadIsActive: true,
            timelineOrdinalsAreCanonical: mode != "summary", snapshotReadAt: Date(timeIntervalSince1970: 200)
        )
    }

    private func applyDelta(
        _ text: String,
        to store: ConversationStore,
        phase: String = "final_answer",
        flush: Bool = true
    ) throws {
        var projector = CodexAppServerEventProjector()
        _ = projector.project(try notification("item/started", extra: [
            "item": ["id": itemID, "type": "agentMessage", "text": "", "phase": phase]
        ]))
        guard case .assistantDelta(let delta, let metadata) = projector.project(
            try notification("item/agentMessage/delta", extra: ["delta": text])
        ) else { return XCTFail("Expected assistant delta") }
        store.applyAssistantDelta(delta, metadata: metadata, fallbackSessionID: sessionID)
        if flush { store.resetLiveTranscript(sessionID: sessionID) }
    }

    private func notification(_ method: String, extra: [String: Any]) throws -> CodexAppServerNotification {
        var params: [String: Any] = ["threadId": sessionID, "turnId": turnID, "itemId": itemID]
        params.merge(extra) { _, incoming in incoming }
        return try JSONDecoder().decode(
            CodexAppServerNotification.self,
            from: JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        )
    }

    private func object(_ value: [String: Any]) throws -> [String: CodexAppServerJSONValue] {
        try JSONDecoder().decode([String: CodexAppServerJSONValue].self, from: JSONSerialization.data(withJSONObject: value))
    }
}
