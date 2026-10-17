import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testLongHistoryFirstPresentationAndCachedReopenForBothProviders() async throws {
        for runtime in ["codex", "claude"] {
            try await assertLongHistoryFirstPresentationAndCachedReopen(runtime: runtime)
        }
    }

    func testLongProseHistoryFirstPresentationAndCachedReopenForBothProviders() async throws {
        for runtime in ["codex", "claude"] {
            try await assertLongHistoryFirstPresentationAndCachedReopen(runtime: runtime, includesCode: false)
        }
    }

    private func assertLongHistoryFirstPresentationAndCachedReopen(runtime: String, includesCode: Bool = true) async throws {
        let project = makeProject(id: "loading-\(runtime)")
        var session = makeSession(id: "loading-\(runtime)", projectID: project.id,
                                  title: "长历史", status: "history", source: runtime, runtimeProvider: runtime)
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [session]))
        let appStore = makeIsolatedAppStore()
        let conversationStore = ConversationStore()
        conversationStore.activate(profileID: appStore.activeHostScope.profileID)
        let store = SessionStore(appStore: appStore, conversationStore: conversationStore,
                                 logStore: LogStore(), clientFactory: { client })
        store.projects = [project]
        store.sessions = [session]
        var unit = "## \(runtime) 的分析\n\n完整说明、**重点**与[链接](https://example.com)。\n\n- 核对数据\n- 保留结果\n\n```swift\nlet value = \"长回答 🌿\"\n```\n\n"
        if !includesCode {
            unit = "## \(runtime) 的分析\n\n完整说明、**重点**与[链接](https://example.com)。\n\n这里给出完整结论与后续步骤，保留长段落和列表的阅读排版。\n\n- 核对数据\n- 保留结果\n\n"
        }
        let messages: [CodexHistoryMessage] = (0..<20).map { index in
            let answer = String(repeating: unit, count: index == 19 ? 320 : 8) + "结束标记-\(index)"
            return CodexHistoryMessage(
                id: "\(runtime)-message-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: index.isMultiple(of: 2) ? "问题 \(index)" : answer,
                createdAt: Date(timeIntervalSince1970: Double(index)),
                turnID: "turn-\(index / 2)", itemID: "item-\(index)", timelineOrdinal: Int64(index * 100),
                turnLifecycle: .completed
            )
        }
        let continuation = HistoryTurnItemsContinuation(
            turnID: "turn-9", turn: ["id": .string("turn-9"), "status": .string("completed")],
            turnIndex: 9, itemOffset: 0, cursor: nil, pageLimit: 50,
            threadIsActive: false, isLatestTurn: true, hasVisibleUserMessageBefore: true
        )
        let themeSuiteName = "LongHistoryLoadingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: themeSuiteName))
        let host = UIHostingController(rootView: ConversationView()
            .environmentObject(store).environmentObject(conversationStore)
            .environmentObject(ThemeStore(defaults: defaults)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 820)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            store.returnToSessionList()
            defaults.removePersistentDomain(forName: themeSuiteName)
        }
        let select = Task { await store.selectSession(session) }
        await client.waitForHistoryRequestCount(1)
        host.view.layoutIfNeeded()
        let responseAt = ProcessInfo.processInfo.systemUptime
        client.resolveHistoryRequest(at: 0, with: HistoryMessagesPage(
            messages: messages, itemContinuations: [continuation]
        ))
        _ = await select.value
        let mergedAt = ProcessInfo.processInfo.systemUptime
        await client.waitForHistoryItemRequestCount(1)
        let initialScrollView = try await waitForConversationTimelineAtBottom(in: host.view, timeout: 12)
        let readableAt = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view), "大回答不能一直被定位遮罩盖住")
        XCTAssertLessThanOrEqual(distanceFromBottom(initialScrollView), 4)
        XCTAssertEqual(conversationStore.messages(for: session.id).last?.content, messages.last?.content)
        XCTAssertNotNil(store.historyItemEnrichmentBySessionID[session.id], "首屏可读不依赖补齐请求结束")
        print("History screen fixture: provider=\(runtime), code=\(includesCode), bytes=\(messages.reduce(0) { $0 + $1.content.utf8.count }), response-to-merge=\(mergedAt - responseAt)s, merge-to-readable=\(readableAt - mergedAt)s")

        // 把补齐请求保持为未完成，直接检查已有正文是否会重新被遮住。
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(16))
            host.view.layoutIfNeeded()
            XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view))
        }
        client.resolveHistoryItemRequest(at: 0, with: HistoryTurnItemsPage(
            messages: Array(messages.suffix(2)), itemIDs: ["item-18", "item-19"], continuation: nil
        ))
        for _ in 0..<100 where store.historyItemEnrichmentBySessionID[session.id] != nil { await Task.yield() }
        store.returnToSessionList()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        // 元数据变更强制后台对账，验收重入是否仍能立即使用已有正文。
        session.updatedAt = try XCTUnwrap(session.updatedAt).addingTimeInterval(1)
        store.sessions = [session]
        store.historyFirstPageCacheByKey.removeAll()
        let reopenAt = ProcessInfo.processInfo.systemUptime
        _ = await store.selectSession(session)
        await client.waitForHistoryRequestCount(2)
        let reopenedScrollView = try await waitForConversationTimelineAtBottom(in: host.view, timeout: 12)
        let reopenedReadableAt = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view))
        XCTAssertFalse(store.isShowingHistoryLoading(sessionID: session.id), "后台对账不能重新显示加载状态")
        XCTAssertLessThanOrEqual(distanceFromBottom(reopenedScrollView), 4)
        XCTAssertEqual(conversationStore.messages(for: session.id).last?.content, messages.last?.content)
        print("History cached reopen fixture: provider=\(runtime), code=\(includesCode), reopen-to-readable=\(reopenedReadableAt - reopenAt)s, network-still-pending=true")
        client.resolveHistoryRequest(at: 1, with: HistoryMessagesPage(messages: messages))
        for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(16))
            host.view.layoutIfNeeded()
            XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view), "同正文后台对账不能闪回遮罩")
            XCTAssertLessThanOrEqual(distanceFromBottom(reopenedScrollView), 4)
        }
    }

    func testInitialTimelineRemainsReadableWhileItemEnrichmentIsPending() async throws {
        ConversationScrollDiagnostics.shared.start()
        defer { ConversationScrollDiagnostics.shared.stop() }
        let sessionID = "initial-presentation"
        let appStore = makeIsolatedAppStore()
        let client = OrderedHistoryPageClient(projects: [], page: SessionsPage(sessions: []))
        let conversationStore = ConversationStore()
        conversationStore.activate(profileID: appStore.activeHostScope.profileID)
        let sessionStore = SessionStore(
            appStore: appStore, conversationStore: conversationStore, logStore: LogStore(),
            clientFactory: { client }
        )
        sessionStore.selectedSessionID = sessionID
        func messages(_ range: Range<Int>) -> [CodexHistoryMessage] {
            range.map { index in
                CodexHistoryMessage(
                    id: "initial-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                    content: String(repeating: "第 \(index) 条历史内容。\n", count: 1 + index % 8),
                    createdAt: Date(timeIntervalSince1970: Double(index)),
                    turnID: "initial-turn", itemID: "initial-item-\(index)", timelineOrdinal: Int64(index)
                )
            }
        }
        conversationStore.setHistory(messages(0..<14), sessionID: sessionID)
        sessionStore.historyLoadedQualityBySessionID[sessionID] = .enriching
        let continuation = HistoryTurnItemsContinuation(
            turnID: "initial-turn", turn: ["id": .string("initial-turn"), "status": .string("completed")],
            turnIndex: 0, itemOffset: 0, cursor: nil, pageLimit: 50,
            threadIsActive: false, isLatestTurn: true, hasVisibleUserMessageBefore: false
        )
        sessionStore.appendHistoryItemEnrichment(
            page: HistoryMessagesPage(messages: [], itemContinuations: [continuation]), sessionID: sessionID
        )
        let themeSuiteName = "InitialPresentationTests.\(UUID().uuidString)"
        let themeDefaults = try XCTUnwrap(UserDefaults(suiteName: themeSuiteName))
        let host = UIHostingController(rootView: ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(ThemeStore(defaults: themeDefaults)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 820)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            themeDefaults.removePersistentDomain(forName: themeSuiteName)
        }
        host.view.frame = window.bounds
        let initialScrollView = try await waitForConversationTimelineAtBottom(in: host.view, timeout: 8)
        XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view), "已有首屏不能被未完成的网络请求遮住")
        XCTAssertLessThanOrEqual(distanceFromBottom(initialScrollView), 4)
        var visibleTailDistances: [CGFloat] = []
        for _ in 0..<20 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view))
            visibleTailDistances.append(distanceFromBottom(initialScrollView))
        }
        assertNoRepeatedProgrammaticScrollWrite(
            ConversationScrollDiagnostics.shared.export(),
            context: "首屏布局不能反复写回同一结果"
        )
        let initialWritesAtQuietStart = programmaticScrollWrites(
            in: ConversationScrollDiagnostics.shared.export()
        ).count
        for _ in 0..<8 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            visibleTailDistances.append(distanceFromBottom(initialScrollView))
        }
        XCTAssertEqual(
            programmaticScrollWrites(in: ConversationScrollDiagnostics.shared.export()).count,
            initialWritesAtQuietStart,
            "首屏外部输入停止后必须至少连续 100ms 零程序写"
        )

        for pageIndex in 0..<3 {
            await client.waitForHistoryItemRequestCount(pageIndex + 1)
            // 网络迟迟未返回时也必须能阅读已有正文，不要求返回列表再进入。
            for _ in 0..<8 {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(16))
                XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view))
            }
            // 每批网络输入使用独立诊断代次，避免把两批合法的相同目标误判为反馈环。
            ConversationScrollDiagnostics.shared.start()
            let requested = client.requestedItemContinuations[pageIndex]
            let pageMessages = messages((pageIndex * 50)..<((pageIndex + 1) * 50))
            client.resolveHistoryItemRequest(at: pageIndex, with: HistoryTurnItemsPage(
                messages: pageMessages,
                itemIDs: Set(pageMessages.compactMap(\.itemID)),
                continuation: pageIndex < 2
                    ? requested.continuing(cursor: "page-\(pageIndex + 1)", loadedItemCount: 50, hasVisibleUserMessage: true)
                    : nil
            ))
            // 覆盖现有 250ms 原生布局事务，并要求外部输入停止后自行进入静默。
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(16))
                host.view.layoutIfNeeded()
                if let scrollView = conversationTimelineScrollView(in: host.view),
                   !conversationTimelineIsStabilizing(in: host.view) {
                    visibleTailDistances.append(distanceFromBottom(scrollView))
                }
            }
            assertNoRepeatedProgrammaticScrollWrite(
                ConversationScrollDiagnostics.shared.export(),
                context: "第 \(pageIndex + 1) 批补齐不能反复写回同一布局结果"
            )
            let writesAtQuietStart = programmaticScrollWrites(
                in: ConversationScrollDiagnostics.shared.export()
            ).count
            for _ in 0..<8 {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(16))
                XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view))
                if let scrollView = conversationTimelineScrollView(in: host.view) {
                    visibleTailDistances.append(distanceFromBottom(scrollView))
                }
            }
            XCTAssertEqual(
                programmaticScrollWrites(in: ConversationScrollDiagnostics.shared.export()).count,
                writesAtQuietStart,
                "外部输入停止后必须至少连续 100ms 零程序写"
            )
        }
        for _ in 0..<100 where sessionStore.historyItemEnrichmentBySessionID[sessionID] != nil {
            await Task.yield()
        }
        let scrollView = try await waitForConversationTimelineAtBottom(in: host.view, timeout: 8)
        XCTAssertEqual(sessionStore.historyLoadedQualityBySessionID[sessionID], .full)
        XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view), "投影尾行改变后，首次定位任务必须自行重新开始")
        XCTAssertLessThanOrEqual(distanceFromBottom(scrollView), 4)
        XCTAssertLessThanOrEqual(
            visibleTailDistances.max() ?? .infinity, 4,
            "首轮分批补齐的可读画面必须持续贴底\n\(ConversationScrollDiagnostics.shared.export())"
        )
        // 已交接的画面不能因下一轮后台刷新再次被遮住。
        sessionStore.historyLoadedQualityBySessionID[sessionID] = .enriching
        for _ in 0..<8 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view))
        }

        // 切换到另一会话后，即使补齐未结束也要显示已有内容。
        let degradedSessionID = "initial-presentation-degraded"
        conversationStore.setHistory(messages(0..<20), sessionID: degradedSessionID)
        sessionStore.historyLoadedQualityBySessionID[degradedSessionID] = .enriching
        sessionStore.selectedSessionID = degradedSessionID
        _ = try await waitForConversationTimelineAtBottom(in: host.view, timeout: 8)
        for _ in 0..<8 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view))
        }
        sessionStore.historyLoadedQualityBySessionID[degradedSessionID] = .summary
        let degradedScrollView = try await waitForConversationTimelineAtBottom(in: host.view, timeout: 8)
        XCTAssertFalse(conversationTimelineIsStabilizing(in: host.view))
        XCTAssertLessThanOrEqual(distanceFromBottom(degradedScrollView), 4)

        // 打开仍在输出的会话时，不能因每个正文版本都取消定位而一直显示加载态。
        let streamingSessionID = "initial-presentation-streaming"
        sessionStore.selectedSessionID = streamingSessionID
        var becameReadableDuringStreaming = false
        for index in 0..<40 {
            conversationStore.setHistory([CodexHistoryMessage(
                id: "streaming-tail", role: "assistant", content: "持续输出 \(index)",
                createdAt: Date(timeIntervalSince1970: 1), turnID: "streaming-turn", itemID: "streaming-item"
            )], sessionID: streamingSessionID)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            if !conversationTimelineIsStabilizing(in: host.view) {
                becameReadableDuringStreaming = true
            }
        }
        XCTAssertTrue(becameReadableDuringStreaming, "不能等流式回复结束才显示首屏")
    }

    func testImagePresentationWaitsForScrollingAndReentryUsesCachedHeight() async throws {
        DataURLImageDecoder.removeAllCachedImagesForTesting()
        let appStore = makeIsolatedAppStore()
        let sessionStore = SessionStore(appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore())
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 400)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        }
        let data = try XCTUnwrap(image.pngData())
        let source = ConversationImageSource.markdown("data:image/png;base64,\(data.base64EncodedString())")
        let state = ScrollMediaTestState()
        let host = UIHostingController(rootView: ScrollMediaTestView(state: state, source: source, sessionStore: sessionStore))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(3)
        while DataURLImageDecoder.cachedImage(cacheKey: source.id, profileID: sessionStore.mediaProfileScope, maxPixelSize: 1_600) == nil,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertNotNil(DataURLImageDecoder.cachedImage(cacheKey: source.id, profileID: sessionStore.mediaProfileScope, maxPixelSize: 1_600))
        for _ in 0..<4 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertEqual(state.height, 120, accuracy: 1, "解码结束不能改变手势中的行高")
        XCTAssertEqual(state.layoutChanges, 0)

        state.scrolling = false
        for _ in 0..<12 where state.height < 280 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertEqual(state.height, 288, accuracy: 1)
        XCTAssertEqual(state.layoutChanges, 1, "只在真正改变高度前请求保位")

        let reentry = ScrollMediaTestState()
        let secondHost = UIHostingController(rootView: ScrollMediaTestView(state: reentry, source: source, sessionStore: sessionStore))
        window.rootViewController = secondHost
        for _ in 0..<4 {
            secondHost.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertEqual(reentry.height, 288, accuracy: 1, "缓存图片重新出现时不能退回加载占位")
        XCTAssertEqual(reentry.layoutChanges, 0)
    }

    func testHistoryAnchorIgnoresDisappearedFrameStillInsideViewport() throws {
        let viewport = ConversationTimelineViewport()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        viewport.bind(scrollView)
        let disappearedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let visibleID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        viewport.updateAnchorFrame([disappearedID], CGRect(x: 0, y: 40, width: 300, height: 40))
        viewport.updateAnchorFrame([visibleID], CGRect(x: 0, y: 100, width: 300, height: 40))
        viewport.updateAnchorFrame([disappearedID], .null)

        let anchor = try XCTUnwrap(viewport.captureVisibleAnchor())
        XCTAssertEqual(anchor.candidates.first?.id, visibleID)
    }

    func testHistoryAnchorSelectionIsStableWhenCollapsedMessagesShareFrame() throws {
        let viewport = ConversationTimelineViewport()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        viewport.bind(scrollView)
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let sharedFrame = CGRect(x: 0, y: 80, width: 300, height: 60)
        // 故意让正文首项 UUID 较大；应按正文顺序，而不是 UUID 排序。
        viewport.updateAnchorFrame([laterID, earlierID], sharedFrame)

        let first = try XCTUnwrap(viewport.captureVisibleAnchor())
        XCTAssertEqual(first.candidates.first?.id, laterID)
        viewport.releaseAnchor()
        let second = try XCTUnwrap(viewport.captureVisibleAnchor())
        XCTAssertEqual(second.candidates.first?.id, laterID)
    }

    func testHistoryAnchorCanCaptureWithoutGeometryCallback() throws {
        let viewport = ConversationTimelineViewport()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        viewport.bind(scrollView)
        let visibleID = UUID()
        viewport.updateAnchorFrame([visibleID], CGRect(x: 0, y: 80, width: 300, height: 40))

        let anchor = try XCTUnwrap(viewport.captureVisibleAnchor())
        XCTAssertEqual(anchor.candidates.first?.id, visibleID)
    }

    func testHistoricalPrependKeepsCurrentViewportPosition() async throws {
        let sessionID = "history-viewport-prepend"
        let appStore = makeIsolatedAppStore()
        let project = makeProject(id: "history-viewport-project")
        let session = makeSession(
            id: sessionID,
            projectID: project.id,
            title: "历史视口",
            status: "history",
            source: "codex",
            resumeID: sessionID
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [session])
        )
        let conversationStore = ConversationStore()
        conversationStore.activate(profileID: appStore.activeHostScope.profileID)
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        await sessionStore.refreshAll(autoAttach: false)
        let selectTask = Task { await sessionStore.selectSession(session) }
        await client.waitForHistoryRequestCount(1)
        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: historyViewportMessages(range: 20..<68),
                previousCursor: "history-viewport-older",
                hasMoreBefore: true
            )
        )
        let didSelect = await selectTask.value
        XCTAssertTrue(didSelect)

        let themeSuiteName = "HistoryViewportTests.\(UUID().uuidString)"
        let themeDefaults = try XCTUnwrap(UserDefaults(suiteName: themeSuiteName))
        let themeStore = ThemeStore(defaults: themeDefaults)
        let view = ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
        let host = UIHostingController(rootView: view)
        let markerViews = NSMapTable<NSUUID, UIView>.strongToWeakObjects()
        var selectedAnchor: (id: UUID, frame: CGRect)?
        ConversationTimelineViewport.testingViewObserver = { messageID, view in
            markerViews.setObject(view, forKey: messageID as NSUUID)
        }
        ConversationTimelineViewport.testingSelectionObserver = { messageID, frame in
            selectedAnchor = (messageID, frame)
        }
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 820)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            ConversationTimelineViewport.testingViewObserver = nil
            ConversationTimelineViewport.testingSelectionObserver = nil
            window.isHidden = true
            themeDefaults.removePersistentDomain(forName: themeSuiteName)
        }

        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let scrollView = try await waitForConversationTimelineAtBottom(in: host.view, timeout: 8)
        let minimumOffsetY = -scrollView.adjustedContentInset.top
        let maximumOffsetY = max(
            minimumOffsetY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        let historicalOffsetY = minimumOffsetY + (maximumOffsetY - minimumOffsetY) * 0.45
        // 生产路径由拖动手势解除尾部跟随锁。测试直接操作 UIScrollView 时也要发送
        // 对应 delegate 生命周期，否则 SwiftUI 会把这次位移当成仍需贴尾的布局变化。
        scrollView.delegate?.scrollViewWillBeginDragging?(scrollView)
        await Task.yield()
        scrollView.setContentOffset(CGPoint(x: 0, y: historicalOffsetY), animated: false)
        scrollView.delegate?.scrollViewDidScroll?(scrollView)
        scrollView.delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: false)
        for _ in 0..<12 {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 16_000_000)
        }

        let baselineContentHeight = scrollView.contentSize.height
        XCTAssertGreaterThan(distanceFromBottom(scrollView), 200)
        XCTAssertNil(selectedAnchor, "普通滚动结束不得创建持续修正的阅读锚点")

        let loadTask = Task {
            await sessionStore.loadEarlierHistoryForSelectedSession()
        }
        await client.waitForHistoryRequestCount(2)
        for _ in 0..<4 {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        XCTAssertNil(selectedAnchor, "网络等待期间不应提前持有可能过期的锚点")
        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(
                messages: historyViewportMessages(range: 0..<20),
                hasMoreBefore: false
            )
        )
        await loadTask.value
        for _ in 0..<12 where selectedAnchor == nil {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        let anchor = try XCTUnwrap(selectedAnchor, "发布历史投影前必须选中一条真实可见消息")
        let anchorID = anchor.id
        let baselineAnchorMinY = anchor.frame.minY

        let deadline = Date().addingTimeInterval(3)
        var latestContentHeight = baselineContentHeight
        repeat {
            host.view.layoutIfNeeded()
            latestContentHeight = scrollView.contentSize.height
            if latestContentHeight > baselineContentHeight + 100 {
                break
            }
            try await Task.sleep(nanoseconds: 16_000_000)
        } while Date() < deadline
        XCTAssertGreaterThan(latestContentHeight, baselineContentHeight + 100)

        // 等 List 提交新快照和单次语义锚点校正，不主动改变滚动位置。
        for _ in 0..<12 {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        let currentAnchorView = try XCTUnwrap(
            markerViews.object(forKey: anchorID as NSUUID),
            "prepend 后原始消息 UUID 对应的锚点必须仍存在"
        )
        XCTAssertTrue(currentAnchorView.isDescendant(of: scrollView))
        let currentAnchorMinY = currentAnchorView.convert(currentAnchorView.bounds, to: nil).minY
        XCTAssertEqual(
            currentAnchorMinY,
            baselineAnchorMinY,
            accuracy: 6,
            "prepend 后同一条原始消息在屏幕上的 minY 必须保持不变"
        )
    }

    private func historyViewportMessages(range: Range<Int>) -> [CodexHistoryMessage] {
        range.map { index in
            CodexHistoryMessage(
                id: "history-viewport-\(index)",
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "第 \(index) 条历史消息，用于验证分页插入后阅读位置保持不变。",
                createdAt: Date(timeIntervalSince1970: Double(index + 1)),
                turnID: "history-viewport-turn-\(index)",
                itemID: "history-viewport-item-\(index)",
                timelineOrdinal: Int64(index)
            )
        }
    }

    private func assertNoRepeatedProgrammaticScrollWrite(
        _ trace: String,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var occurrenceByWrite: [String: Int] = [:]
        for entry in programmaticScrollWrites(in: trace) {
            guard let eventRange = entry.range(of: " scroll_") else { continue }
            // 时间戳不是写入身份。保留事件及纯数值 detail，使现有诊断也能抓到
            // UIKit 把同一布局反复改回旧 offset 后，协调器重复写回同一目标的反馈环。
            let fingerprint = String(entry[eventRange.upperBound...])
            occurrenceByWrite[fingerprint, default: 0] += 1
        }
        let repeated = occurrenceByWrite.filter { $0.value > 1 }
        XCTAssertTrue(
            repeated.isEmpty,
            "\(context)：\(repeated)\n\(trace)",
            file: file,
            line: line
        )
    }

    private func programmaticScrollWrites(in trace: String) -> [String] {
        trace.split(separator: "\n").compactMap { entry in
            guard entry.contains(" scroll_"), entry.contains(" from="), entry.contains(" to=") else {
                return nil
            }
            return String(entry)
        }
    }

}

@MainActor
private final class ScrollMediaTestState: ObservableObject {
    @Published var scrolling = true
    var height: CGFloat = 0
    var layoutChanges = 0
}

private struct ScrollMediaTestView: View {
    @ObservedObject var state: ScrollMediaTestState
    let source: ConversationImageSource
    let sessionStore: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            ConversationImagePreview(
                source: source, title: nil,
                style: .make(role: .assistant, colorScheme: .light),
                showsCaption: false, contentSizedMaxWidth: 300
            )
            .environmentObject(sessionStore)
            .environment(\.conversationTimelineIsScrolling, state.scrolling)
            .environment(\.conversationMediaLayoutWillChange, { state.layoutChanges += 1 })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.height = $0 }
            Spacer(minLength: 0)
        }
        .frame(width: 300)
    }
}
