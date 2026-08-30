import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testHistoryItemEnrichmentBatchesTimelinePublicationAndDeduplicatesPages() async {
        let client = OrderedHistoryPageClient(
            projects: [],
            page: SessionsPage(sessions: [])
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        let sessionID = "history-item-publication-batch"
        let continuations = (0..<6).map { index in
            HistoryTurnItemsContinuation(
                turnID: "turn-\(index)",
                turn: [
                    "id": .string("turn-\(index)"),
                    "status": .string("completed")
                ],
                turnIndex: index,
                itemOffset: 0,
                cursor: nil,
                pageLimit: 50,
                threadIsActive: false,
                isLatestTurn: index == 5,
                hasVisibleUserMessageBefore: false
            )
        }
        let page = HistoryMessagesPage(messages: [], itemContinuations: continuations)

        store.historyLoadedQualityBySessionID[sessionID] = .enriching
        store.appendHistoryItemEnrichment(page: page, sessionID: sessionID)
        // 同一批 continuation 在前一批仍运行时再次到达，不得重复进入请求队列。
        store.appendHistoryItemEnrichment(page: page, sessionID: sessionID)

        let expectedRequestCount = continuations.count + 1
        for requestIndex in 0..<expectedRequestCount {
            await client.waitForHistoryItemRequestCount(requestIndex + 1)
            let requested = client.requestedItemContinuations[requestIndex]
            let itemID = "item-\(requested.turnID)-\(requested.itemOffset)"
            let continuation = requested.turnID == "turn-5" && requested.cursor == nil
                ? requested.continuing(
                    cursor: "turn-5-next",
                    loadedItemCount: 1,
                    hasVisibleUserMessage: false
                )
                : nil
            client.resolveHistoryItemRequest(
                at: requestIndex,
                with: HistoryTurnItemsPage(
                    messages: [CodexHistoryMessage(
                        id: "history:\(itemID)",
                        role: "assistant",
                        content: "内容 \(requested.turnID)-\(requested.itemOffset)",
                        createdAt: Date(timeIntervalSince1970: 1),
                        turnID: requested.turnID,
                        itemID: itemID,
                        timelineOrdinal: Int64(requested.turnIndex) * 1_000_000
                            + Int64(requested.itemOffset)
                    )],
                    itemIDs: [itemID],
                    continuation: continuation
                )
            )
        }
        for _ in 0..<100 where store.historyItemEnrichmentBySessionID[sessionID] != nil {
            await Task.yield()
        }

        XCTAssertEqual(client.requestedItemContinuations.count, expectedRequestCount)
        let messages = conversationStore.messages(for: sessionID)
        XCTAssertEqual(messages.count, expectedRequestCount)
        XCTAssertEqual(
            messages.compactMap(\.turnID),
            ["turn-0", "turn-1", "turn-2", "turn-3", "turn-4", "turn-5", "turn-5"]
        )
        XCTAssertEqual(
            messages.filter { $0.turnID == "turn-5" }.compactMap(\.timelineOrdinal),
            [5_000_000, 5_000_001]
        )
        XCTAssertEqual(conversationStore.historyMergeInvocationCountForTesting, 3)
        XCTAssertEqual(
            conversationStore.historyTimelineMutation(for: sessionID)?.generation,
            3
        )
        XCTAssertEqual(store.historyLoadedQualityBySessionID[sessionID], .full)
    }
}
