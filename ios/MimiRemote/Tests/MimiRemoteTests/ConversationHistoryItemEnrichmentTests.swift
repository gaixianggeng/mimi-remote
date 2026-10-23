import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testLatestCompletedTurnKeepsSummaryAtTailUntilAllItemsArrive() async {
        let completionMarkers: [[String: CodexAppServerJSONValue]] = [
            ["status": .string("completed")],
            ["status": .object(["type": .string("failed")])],
            ["status": .string("failure")],
            ["status": .string("systemerror")],
            ["status": .string("system_error")],
            ["status": .object(["status": .string("interrupted")])],
            ["status": .string("cancelled")],
            ["status": .string("canceled")],
            ["status": .string("aborted")],
            ["completedAt": .int(200)],
            ["completed_at": .string("1970-01-01T00:03:20Z")],
            ["finishedAt": .double(200)],
            ["updatedAt": .int(200)]
        ]
        for completion in completionMarkers {
            for fails in [false, true] {
                let sessionID = "latest-turn-publication-\(fails)"
                let client = OrderedHistoryPageClient(projects: [], page: SessionsPage(sessions: []))
                let conversationStore = ConversationStore()
                let store = SessionStore(
                    appStore: makeIsolatedAppStore(), conversationStore: conversationStore,
                    logStore: LogStore(), clientFactory: { client }
                )
                store.selectedSessionID = sessionID
                let first = HistoryTurnItemsContinuation(
                    turnID: "latest", turn: ["id": .string("latest")].merging(completion) { _, new in new },
                    turnIndex: 0, itemOffset: 0, cursor: nil, pageLimit: 50,
                    threadIsActive: false, isLatestTurn: true, hasVisibleUserMessageBefore: false
                )
                store.applyHistoryFirstPage(HistoryMessagesPage(
                    messages: [CodexHistoryMessage(
                        id: "summary", role: "assistant", content: "最终报告",
                        createdAt: Date(timeIntervalSince1970: 200), turnID: "latest", itemID: "summary"
                    )],
                    itemContinuations: [first]
                ), sessionID: sessionID)
                let summaryID = conversationStore.messages(for: sessionID).last?.id
                await client.waitForHistoryItemRequestCount(1)
                let second = first.continuing(cursor: "tail", loadedItemCount: 1, hasVisibleUserMessage: false)
                client.resolveHistoryItemRequest(at: 0, with: HistoryTurnItemsPage(
                    messages: [CodexHistoryMessage(
                        id: "image", role: "assistant", content: "过程图片",
                        createdAt: Date(timeIntervalSince1970: 400), turnID: "latest", itemID: "image", timelineOrdinal: 207
                    )], itemIDs: ["image"], continuation: second
                ))
                await client.waitForHistoryItemRequestCount(2)
                XCTAssertEqual(conversationStore.messages(for: sessionID).map(\.content), ["最终报告"])
                if fails {
                    client.resolveHistoryItemRequest(at: 1, result: .failure(URLError(.networkConnectionLost)))
                } else {
                    client.resolveHistoryItemRequest(at: 1, with: HistoryTurnItemsPage(
                        messages: [CodexHistoryMessage(
                            id: "final", role: "assistant", content: "最终报告",
                            createdAt: Date(timeIntervalSince1970: 200), turnID: "latest", itemID: "final", timelineOrdinal: 236
                        )], itemIDs: ["final"], continuation: nil
                    ))
                }
                await waitForHistoryItemEnrichmentToFinish(in: store, sessionID: sessionID)
                XCTAssertEqual(conversationStore.messages(for: sessionID).last?.id, summaryID)
                XCTAssertEqual(conversationStore.messages(for: sessionID).map(\.content), fails ? ["最终报告"] : ["过程图片", "最终报告"])
                XCTAssertEqual(store.historyLoadedQualityBySessionID[sessionID], fails ? .summary : .full)
            }
        }
    }

    func testActiveLatestTurnStillPublishesPartialItems() async {
        let sessionID = "active-turn-publication"
        let client = OrderedHistoryPageClient(projects: [], page: SessionsPage(sessions: []))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: conversationStore,
            logStore: LogStore(), clientFactory: { client }
        )
        store.selectedSessionID = sessionID
        let first = HistoryTurnItemsContinuation(
            turnID: "active", turn: [
                "id": .string("active"), "status": .string("inProgress"), "updatedAt": .int(200)
            ],
            turnIndex: 0, itemOffset: 0, cursor: nil, pageLimit: 50,
            threadIsActive: true, isLatestTurn: true, hasVisibleUserMessageBefore: false
        )
        store.appendHistoryItemEnrichment(
            page: HistoryMessagesPage(messages: [], itemContinuations: [first]), sessionID: sessionID
        )
        await client.waitForHistoryItemRequestCount(1)
        let second = first.continuing(cursor: "next", loadedItemCount: 1, hasVisibleUserMessage: false)
        client.resolveHistoryItemRequest(at: 0, with: HistoryTurnItemsPage(
            messages: [CodexHistoryMessage(
                role: "assistant", content: "进行中内容", createdAt: Date(timeIntervalSince1970: 100),
                turnID: "active", itemID: "live", timelineOrdinal: 0
            )], itemIDs: ["live"], continuation: second
        ))
        await client.waitForHistoryItemRequestCount(2)
        XCTAssertEqual(conversationStore.messages(for: sessionID).map(\.content), ["进行中内容"])
        client.resolveHistoryItemRequest(at: 1, with: HistoryTurnItemsPage(messages: [], itemIDs: [], continuation: nil))
        await waitForHistoryItemEnrichmentToFinish(in: store, sessionID: sessionID)
    }

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
        store.selectedSessionID = sessionID
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
        await waitForHistoryItemEnrichmentToFinish(in: store, sessionID: sessionID)

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
        store.selectedSessionID = sessionID
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
        await waitForHistoryItemEnrichmentToFinish(in: store, sessionID: sessionID)

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
        let source = conversationStore.timelineSource(for: sessionID)
        XCTAssertEqual(source.revision, 3)
        XCTAssertEqual(source.versions.historyEnrichment, source.revision)
        XCTAssertEqual(
            ConversationTimelineItemCache().snapshot(from: source).changes,
            .historyEnrichment
        )
        XCTAssertEqual(store.historyLoadedQualityBySessionID[sessionID], .full)
    }

    func testDeferredLatestTurnPagesDoNotShrinkPublicationBatches() async {
        let client = OrderedHistoryPageClient(projects: [], page: SessionsPage(sessions: []))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: conversationStore,
            logStore: LogStore(), clientFactory: { client }
        )
        let sessionID = "history-deferred-publication-batch"
        store.selectedSessionID = sessionID
        let continuations = (0..<2).map { index in
            HistoryTurnItemsContinuation(
                turnID: "turn-\(index)", turn: ["id": .string("turn-\(index)"), "status": .string("completed")],
                turnIndex: index, itemOffset: 0, cursor: nil, pageLimit: 50,
                threadIsActive: false, isLatestTurn: index == 1, hasVisibleUserMessageBefore: false
            )
        }
        store.appendHistoryItemEnrichment(
            page: HistoryMessagesPage(messages: [], itemContinuations: continuations), sessionID: sessionID
        )
        // 两个 Turn 各六页轮转。最新 Turn 持续暂存时，旧 Turn 仍首批立即、之后每四页发布。
        for index in 0..<12 {
            await client.waitForHistoryItemRequestCount(index + 1)
            let requested = client.requestedItemContinuations[index]
            let itemID = "\(requested.turnID)-\(requested.itemOffset)"
            let next = requested.itemOffset < 5
                ? requested.continuing(cursor: "page-\(requested.itemOffset + 1)", loadedItemCount: 1, hasVisibleUserMessage: false)
                : nil
            client.resolveHistoryItemRequest(at: index, with: HistoryTurnItemsPage(
                messages: [CodexHistoryMessage(
                    id: itemID, role: "assistant", content: itemID, createdAt: Date(timeIntervalSince1970: 1),
                    turnID: requested.turnID, itemID: itemID, timelineOrdinal: Int64(requested.itemOffset)
                )], itemIDs: [itemID], continuation: next
            ))
        }
        await waitForHistoryItemEnrichmentToFinish(in: store, sessionID: sessionID)
        XCTAssertEqual(client.requestedItemContinuations.map(\.turnID), Array(repeating: ["turn-1", "turn-0"], count: 6).flatMap { $0 })
        XCTAssertEqual(conversationStore.messages(for: sessionID).count, 12)
        XCTAssertEqual(conversationStore.historyMergeInvocationCountForTesting, 4)
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
        store.selectedSessionID = sessionID
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
        conversationStore.setHistory([
            CodexHistoryMessage(
                role: "assistant", content: "末条摘要", createdAt: Date(timeIntervalSince1970: 100),
                turnID: "turn-cycle", itemID: "summary"
            )
        ], sessionID: sessionID)
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
        await waitForHistoryItemEnrichmentToFinish(in: store, sessionID: sessionID)

        XCTAssertEqual(client.requestedItemContinuations.count, 2)
        XCTAssertEqual(conversationStore.messages(for: sessionID).map(\.content), ["末条摘要"])
        XCTAssertEqual(store.historyLoadedQualityBySessionID[sessionID], .summary)
    }

    func testConnectionClearInvalidatesHistoryItemEnrichmentAndLateResponse() async {
        let client = OrderedHistoryPageClient(projects: [], page: SessionsPage(sessions: []))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        let sessionID = "history-item-host-invalidation"
        store.selectedSessionID = sessionID
        store.historyLoadedQualityBySessionID[sessionID] = .enriching
        let continuation = HistoryTurnItemsContinuation(
            turnID: "turn-host-invalidation",
            turn: [
                "id": .string("turn-host-invalidation"),
                "status": .string("completed")
            ],
            turnIndex: 0,
            itemOffset: 0,
            cursor: nil,
            pageLimit: 50,
            threadIsActive: false,
            isLatestTurn: true,
            hasVisibleUserMessageBefore: false
        )
        store.appendHistoryItemEnrichment(
            page: HistoryMessagesPage(messages: [], itemContinuations: [continuation]),
            sessionID: sessionID
        )

        await client.waitForHistoryItemRequestCount(1)
        store.clearConnectionData()

        XCTAssertNil(store.historyItemEnrichmentBySessionID[sessionID])
        XCTAssertNil(store.historyLoadedQualityBySessionID[sessionID])
        client.resolveHistoryItemRequest(
            at: 0,
            with: HistoryTurnItemsPage(
                messages: [CodexHistoryMessage(
                    id: "history:late-host-item",
                    role: "assistant",
                    content: "旧主机迟到内容",
                    createdAt: Date(timeIntervalSince1970: 1),
                    turnID: "turn-host-invalidation",
                    itemID: "late-host-item"
                )],
                itemIDs: ["late-host-item"],
                continuation: nil
            )
        )
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertTrue(conversationStore.messages(for: sessionID).isEmpty)
        XCTAssertEqual(client.requestedItemContinuations.count, 1)
    }

    func testReturningToSessionListPausesAndResumesHistoryItemEnrichment() async {
        let project = makeProject(id: "proj_cancel_history_item_enrichment")
        let session = makeSession(
            id: "cancel_history_item_enrichment",
            projectID: project.id,
            title: "取消分页补齐",
            status: "history",
            source: "codex"
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [session])
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]
        store.selectedSessionID = session.id
        store.historyLoadedSignatureBySessionID[session.id] = HistoryLoadSignature(session: session)
        store.historyLoadedQualityBySessionID[session.id] = .enriching
        let turn: [String: CodexAppServerJSONValue] = [
            "id": .string("turn-cancel"),
            "status": .string("completed")
        ]
        let firstContinuation = HistoryTurnItemsContinuation(
            turnID: "turn-cancel",
            turn: turn,
            turnIndex: 0,
            itemOffset: 0,
            cursor: nil,
            pageLimit: 50,
            threadIsActive: false,
            isLatestTurn: true,
            hasVisibleUserMessageBefore: false
        )
        store.applyHistoryFirstPage(
            HistoryMessagesPage(
                messages: [CodexHistoryMessage(
                    id: "history:summary",
                    role: "assistant",
                    content: "首屏文案",
                    createdAt: Date(timeIntervalSince1970: 1),
                    turnID: "turn-cancel",
                    itemID: "summary"
                )],
                itemContinuations: [firstContinuation]
            ),
            sessionID: session.id
        )

        await client.waitForHistoryItemRequestCount(1)
        let secondContinuation = firstContinuation.continuing(
            cursor: "page-2",
            loadedItemCount: 1,
            hasVisibleUserMessage: false
        )
        client.resolveHistoryItemRequest(
            at: 0,
            with: HistoryTurnItemsPage(
                messages: [CodexHistoryMessage(
                    id: "history:page-1",
                    role: "assistant",
                    content: "第一页内容",
                    createdAt: Date(timeIntervalSince1970: 2),
                    turnID: "turn-cancel",
                    itemID: "page-1"
                )],
                itemIDs: ["page-1"],
                continuation: secondContinuation
            )
        )
        await client.waitForHistoryItemRequestCount(2)
        let thirdContinuation = secondContinuation.continuing(
            cursor: "page-3",
            loadedItemCount: 1,
            hasVisibleUserMessage: false
        )
        client.resolveHistoryItemRequest(
            at: 1,
            with: HistoryTurnItemsPage(
                messages: [CodexHistoryMessage(
                    id: "history:page-2",
                    role: "assistant",
                    content: "第二页内容",
                    createdAt: Date(timeIntervalSince1970: 3),
                    turnID: "turn-cancel",
                    itemID: "page-2"
                )],
                itemIDs: ["page-2"],
                continuation: thirdContinuation
            )
        )
        await client.waitForHistoryItemRequestCount(3)
        store.returnToSessionList()

        XCTAssertNotNil(store.historyItemEnrichmentBySessionID[session.id])
        XCTAssertNil(store.historyItemEnrichmentBySessionID[session.id]?.task)
        XCTAssertEqual(
            store.historyItemEnrichmentBySessionID[session.id]?.bufferedPages.flatMap(\.messages).map(\.content),
            ["第一页内容", "第二页内容"]
        )
        XCTAssertEqual(store.historyLoadedQualityBySessionID[session.id], .enriching)
        XCTAssertNil(store.selectedSessionID)

        client.resolveHistoryItemRequest(
            at: 2,
            with: HistoryTurnItemsPage(
                messages: [CodexHistoryMessage(
                    id: "history:late",
                    role: "assistant",
                    content: "迟到内容",
                    createdAt: Date(timeIntervalSince1970: 4),
                    turnID: "turn-cancel",
                    itemID: "late"
                )],
                itemIDs: ["late"],
                continuation: nil
            )
        )
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(
            conversationStore.messages(for: session.id).map(\.content),
            ["首屏文案"]
        )
        XCTAssertEqual(client.requestedItemContinuations.count, 3)

        store.selectedSessionID = session.id
        let didReuseHistory = await store.loadHistoryIfNeeded(for: session)
        XCTAssertTrue(didReuseHistory)
        await client.waitForHistoryItemRequestCount(4)
        XCTAssertEqual(client.requestedItemContinuations.map(\.cursor), [nil, "page-2", "page-3", "page-3"])
        client.resolveHistoryItemRequest(
            at: 3,
            with: HistoryTurnItemsPage(
                messages: [CodexHistoryMessage(
                    id: "history:page-3",
                    role: "assistant",
                    content: "第三页内容",
                    createdAt: Date(timeIntervalSince1970: 5),
                    turnID: "turn-cancel",
                    itemID: "page-3"
                )],
                itemIDs: ["page-3"],
                continuation: nil
            )
        )
        await waitForHistoryItemEnrichmentToFinish(in: store, sessionID: session.id)

        XCTAssertEqual(client.requestedMessageCursors.count, 0)
        XCTAssertEqual(
            conversationStore.messages(for: session.id).map(\.content),
            ["首屏文案", "第一页内容", "第二页内容", "第三页内容"]
        )
        XCTAssertEqual(store.historyLoadedQualityBySessionID[session.id], .full)
    }

    func testHistoryFirstPageFinishingAfterLeavingDefersItemEnrichmentUntilReopen() async {
        let project = makeProject(id: "proj_deferred_history_item_enrichment")
        let session = makeSession(
            id: "deferred_history_item_enrichment",
            projectID: project.id,
            title: "迟到首屏",
            status: "history",
            source: "codex"
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [session])
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]
        store.selectedSessionID = session.id
        let continuation = HistoryTurnItemsContinuation(
            turnID: "turn-deferred",
            turn: [
                "id": .string("turn-deferred"),
                "status": .string("completed")
            ],
            turnIndex: 0,
            itemOffset: 0,
            cursor: nil,
            pageLimit: 50,
            threadIsActive: false,
            isLatestTurn: true,
            hasVisibleUserMessageBefore: false
        )

        let loadTask = Task { await store.loadHistory(for: session) }
        await client.waitForHistoryRequestCount(1)
        store.returnToSessionList()
        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [CodexHistoryMessage(
                    id: "history:summary",
                    role: "assistant",
                    content: "迟到首屏文案",
                    createdAt: Date(timeIntervalSince1970: 1),
                    turnID: "turn-deferred",
                    itemID: "summary"
                )],
                itemContinuations: [continuation]
            )
        )
        let didLoadFirstPage = await loadTask.value
        XCTAssertTrue(didLoadFirstPage)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertNil(store.selectedSessionID)
        XCTAssertEqual(client.requestedItemContinuations.count, 0)
        XCTAssertNotNil(store.historyItemEnrichmentBySessionID[session.id])
        XCTAssertNil(store.historyItemEnrichmentBySessionID[session.id]?.task)
        XCTAssertEqual(store.historyLoadedQualityBySessionID[session.id], .enriching)

        store.selectedSessionID = session.id
        let didReuseHistory = await store.loadHistoryIfNeeded(for: session)
        XCTAssertTrue(didReuseHistory)
        await client.waitForHistoryItemRequestCount(1)
        XCTAssertEqual(client.requestedMessageCursors.count, 1)
        client.resolveHistoryItemRequest(
            at: 0,
            with: HistoryTurnItemsPage(
                messages: [CodexHistoryMessage(
                    id: "history:item",
                    role: "assistant",
                    content: "补齐内容",
                    createdAt: Date(timeIntervalSince1970: 2),
                    turnID: "turn-deferred",
                    itemID: "item"
                )],
                itemIDs: ["item"],
                continuation: nil
            )
        )
        await waitForHistoryItemEnrichmentToFinish(in: store, sessionID: session.id)

        XCTAssertEqual(conversationStore.messages(for: session.id).map(\.content), ["迟到首屏文案", "补齐内容"])
        XCTAssertEqual(store.historyLoadedQualityBySessionID[session.id], .full)
    }

    func testChangedHistorySignatureInvalidatesPausedItemEnrichment() async {
        let project = makeProject(id: "proj_changed_history_signature")
        let session = makeSession(
            id: "changed_history_signature",
            projectID: project.id,
            title: "旧快照",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let changedSession = makeSession(
            id: session.id,
            projectID: project.id,
            title: "新快照",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [changedSession])
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]
        store.selectedSessionID = session.id
        store.historyLoadedSignatureBySessionID[session.id] = HistoryLoadSignature(session: session)
        store.historyLoadedQualityBySessionID[session.id] = .enriching
        let continuation = HistoryTurnItemsContinuation(
            turnID: "turn-signature",
            turn: [
                "id": .string("turn-signature"),
                "status": .string("completed")
            ],
            turnIndex: 0,
            itemOffset: 0,
            cursor: nil,
            pageLimit: 50,
            threadIsActive: false,
            isLatestTurn: true,
            hasVisibleUserMessageBefore: false
        )
        store.applyHistoryFirstPage(
            HistoryMessagesPage(
                messages: [CodexHistoryMessage(
                    id: "history:old-summary",
                    role: "assistant",
                    content: "旧快照文案",
                    createdAt: Date(timeIntervalSince1970: 1),
                    turnID: "turn-signature",
                    itemID: "old-summary"
                )],
                itemContinuations: [continuation]
            ),
            sessionID: session.id
        )

        await client.waitForHistoryItemRequestCount(1)
        store.returnToSessionList()
        store.selectedSessionID = session.id
        let reloadTask = Task { await store.loadHistoryIfNeeded(for: changedSession) }
        await client.waitForHistoryRequestCount(1)

        XCTAssertEqual(client.requestedItemContinuations.count, 1)
        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [CodexHistoryMessage(
                    id: "history:new-item",
                    role: "assistant",
                    content: "新快照文案",
                    createdAt: Date(timeIntervalSince1970: 2),
                    turnID: "turn-signature",
                    itemID: "new-item"
                )],
                authoritativeCompletedTurnItems: ["turn-signature": ["new-item"]]
            )
        )
        let didReload = await reloadTask.value

        XCTAssertTrue(didReload)
        XCTAssertNil(store.historyItemEnrichmentBySessionID[session.id])
        XCTAssertEqual(
            store.historyLoadedSignatureBySessionID[session.id],
            HistoryLoadSignature(session: changedSession)
        )
        XCTAssertEqual(store.historyLoadedQualityBySessionID[session.id], .full)

        client.resolveHistoryItemRequest(
            at: 0,
            with: HistoryTurnItemsPage(
                messages: [CodexHistoryMessage(
                    id: "history:late-old-item",
                    role: "assistant",
                    content: "迟到旧内容",
                    createdAt: Date(timeIntervalSince1970: 3),
                    turnID: "turn-signature",
                    itemID: "late-old-item"
                )],
                itemIDs: ["late-old-item"],
                continuation: nil
            )
        )
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(conversationStore.messages(for: session.id).map(\.content), ["旧快照文案", "新快照文案"])
        XCTAssertEqual(client.requestedItemContinuations.count, 1)
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

/// 等历史 Item 补齐跑完。按条件轮询并设上限，不按 yield 次数计：托管 macOS runner 跑全量时
/// 100 次 `Task.yield()` 不够合并完（#741 在 CI 实测只合并到一部分页）。条件满足即返回。
@MainActor
func waitForHistoryItemEnrichmentToFinish(
    in store: SessionStore,
    sessionID: String,
    timeout: Duration = .seconds(5)
) async {
    let deadline = ContinuousClock.now + timeout
    while store.historyItemEnrichmentBySessionID[sessionID] != nil, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
