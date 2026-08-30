import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testInitialHistoryItemEnrichmentDeduplicatesRepeatedContinuation() async {
        let client = OrderedHistoryPageClient(projects: [], page: SessionsPage(sessions: []))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        let sessionID = "history-item-initial-duplicate"
        let continuation = HistoryTurnItemsContinuation(
            turnID: "turn-duplicate",
            turn: ["id": .string("turn-duplicate"), "status": .string("completed")],
            turnIndex: 0,
            itemOffset: 0,
            cursor: nil,
            pageLimit: 50,
            threadIsActive: false,
            isLatestTurn: true,
            hasVisibleUserMessageBefore: false
        )

        store.historyLoadedQualityBySessionID[sessionID] = .enriching
        store.appendHistoryItemEnrichment(
            page: HistoryMessagesPage(
                messages: [],
                itemContinuations: [continuation, continuation]
            ),
            sessionID: sessionID
        )

        await client.waitForHistoryItemRequestCount(1)
        client.resolveHistoryItemRequest(at: 0, with: HistoryTurnItemsPage(
            messages: [CodexHistoryMessage(
                role: "assistant",
                content: "唯一内容",
                createdAt: Date(timeIntervalSince1970: 1),
                turnID: continuation.turnID,
                itemID: "item-only",
                timelineOrdinal: 0
            )],
            itemIDs: ["item-only"],
            continuation: nil
        ))
        for _ in 0..<100 where store.historyItemEnrichmentBySessionID[sessionID] != nil {
            await Task.yield()
        }

        XCTAssertEqual(client.requestedItemContinuations.count, 1)
        XCTAssertEqual(conversationStore.messages(for: sessionID).map(\.content), ["唯一内容"])
        XCTAssertEqual(store.historyLoadedQualityBySessionID[sessionID], .full)
    }

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

    func testHistoryItemEnrichmentStopsCursorCycleWithoutAuthoritativePrune() async {
        let client = OrderedHistoryPageClient(projects: [], page: SessionsPage(sessions: []))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        let sessionID = "history-item-cursor-cycle"
        let initial = HistoryTurnItemsContinuation(
            turnID: "turn-cycle",
            turn: ["id": .string("turn-cycle"), "status": .string("completed")],
            turnIndex: 0,
            itemOffset: 0,
            cursor: nil,
            pageLimit: 50,
            threadIsActive: false,
            isLatestTurn: true,
            hasVisibleUserMessageBefore: false
        )
        store.historyLoadedQualityBySessionID[sessionID] = .enriching
        store.appendHistoryItemEnrichment(
            page: HistoryMessagesPage(messages: [], itemContinuations: [initial]),
            sessionID: sessionID
        )

        await client.waitForHistoryItemRequestCount(1)
        let second = initial.continuing(cursor: "B", loadedItemCount: 1, hasVisibleUserMessage: false)
        client.resolveHistoryItemRequest(at: 0, with: HistoryTurnItemsPage(
            messages: [CodexHistoryMessage(
                role: "assistant",
                content: "A",
                createdAt: Date(timeIntervalSince1970: 1),
                turnID: "turn-cycle",
                itemID: "A",
                timelineOrdinal: 0
            )],
            itemIDs: ["A"],
            continuation: second
        ))
        await client.waitForHistoryItemRequestCount(2)
        client.resolveHistoryItemRequest(at: 1, with: HistoryTurnItemsPage(
            messages: [CodexHistoryMessage(
                role: "assistant",
                content: "B",
                createdAt: Date(timeIntervalSince1970: 2),
                turnID: "turn-cycle",
                itemID: "B",
                timelineOrdinal: 1
            )],
            itemIDs: ["B"],
            continuation: initial
        ))
        for _ in 0..<100 where store.historyItemEnrichmentBySessionID[sessionID] != nil {
            await Task.yield()
        }

        XCTAssertEqual(client.requestedItemContinuations.count, 2)
        XCTAssertEqual(conversationStore.messages(for: sessionID).map(\.content), ["A", "B"])
        XCTAssertEqual(store.historyLoadedQualityBySessionID[sessionID], .summary)
    }

    func testHistoryItemPageValidationRejectsMalformedEnvelopeFields() throws {
        let validItem: CodexAppServerJSONValue = .object([
            "turnId": .string("turn-1"),
            "item": .object(["id": .string("item-1")])
        ])
        let valid = try CodexAppServerSessionRuntime.validatedHistoryItemPage(
            ["data": .array([validItem]), "nextCursor": .null],
            turnID: "turn-1"
        )
        XCTAssertEqual(valid.items.first?["id"]?.stringValue, "item-1")
        XCTAssertNil(valid.nextCursor)

        let malformedPages: [[String: CodexAppServerJSONValue]] = [
            ["nextCursor": .null],
            ["data": .object([:]), "nextCursor": .null],
            ["data": .array([.string("bad")]), "nextCursor": .null],
            ["data": .array([.object(["item": .object(["id": .string("item-1")])])]), "nextCursor": .null],
            ["data": .array([.object(["turnId": .string("turn-1")])]), "nextCursor": .null],
            ["data": .array([.object(["turnId": .string("turn-1"), "item": .object([:])])]), "nextCursor": .null],
            ["data": .array([])],
            ["data": .array([]), "nextCursor": .string("  ")],
            ["data": .array([]), "nextCursor": .int(7)]
        ]
        for page in malformedPages {
            XCTAssertThrowsError(
                try CodexAppServerSessionRuntime.validatedHistoryItemPage(page, turnID: "turn-1")
            ) { error in
                guard case AgentAPIError.invalidResponse = error else {
                    return XCTFail("Expected invalidResponse, got \(error)")
                }
            }
        }
    }

    func testHistoryTurnsPageValidationRequiresDataTurnIDAndExplicitCursor() {
        let malformedPages: [[String: CodexAppServerJSONValue]] = [
            ["nextCursor": .null],
            ["data": .array([.string("bad")]), "nextCursor": .null],
            ["data": .array([.object([:])]), "nextCursor": .null],
            ["data": .array([.object(["id": .string("  ")])]), "nextCursor": .null],
            ["data": .array([])],
            ["data": .array([]), "nextCursor": .bool(false)]
        ]
        for page in malformedPages {
            XCTAssertThrowsError(try CodexAppServerSessionRuntime.validatedHistoryTurnsPage(page))
        }
    }

    func testHistoryTurnPaginationStopsCrossPageCursorCycle() {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { OrderedHistoryPageClient(projects: [], page: SessionsPage(sessions: [])) }
        )
        let sessionID = "history-turn-cursor-cycle"

        store.updateHistoryPageState(
            sessionID: sessionID,
            page: HistoryMessagesPage(messages: [], previousCursor: "turns-A", hasMoreBefore: true),
            preserveExistingCursorOnEmptyPage: true
        )
        store.updateHistoryPageState(
            sessionID: sessionID,
            page: HistoryMessagesPage(messages: [], previousCursor: "turns-B", hasMoreBefore: true),
            requestedCursor: "turns-A",
            preserveExistingCursorOnEmptyPage: false
        )
        XCTAssertEqual(store.historyPreviousCursorBySessionID[sessionID], "turns-B")
        XCTAssertTrue(store.historyHasMoreBeforeBySessionID[sessionID] == true)

        store.updateHistoryPageState(
            sessionID: sessionID,
            page: HistoryMessagesPage(messages: [], previousCursor: "turns-A", hasMoreBefore: true),
            requestedCursor: "turns-B",
            preserveExistingCursorOnEmptyPage: false
        )

        XCTAssertNil(store.historyPreviousCursorBySessionID[sessionID])
        XCTAssertFalse(store.historyHasMoreBeforeBySessionID[sessionID] == true)
    }
}
