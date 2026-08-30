import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testHistoryAnchorIgnoresDisappearedFrameStillInsideViewport() throws {
        let coordinator = ConversationHistoryScrollCoordinator()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        coordinator.bind(scrollView: scrollView)
        let disappearedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let visibleID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        coordinator.updateAnchorFrame([disappearedID], CGRect(x: 0, y: 40, width: 300, height: 40))
        coordinator.updateAnchorFrame([visibleID], CGRect(x: 0, y: 100, width: 300, height: 40))
        coordinator.updateAnchorFrame([disappearedID], .null)

        _ = try XCTUnwrap(coordinator.beginPreservingVisible(sessionID: "session"))
        XCTAssertEqual(coordinator.activeAnchorMessageID, visibleID)
    }

    func testHistoryAnchorSelectionIsStableWhenCollapsedMessagesShareFrame() throws {
        let coordinator = ConversationHistoryScrollCoordinator()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        coordinator.bind(scrollView: scrollView)
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let sharedFrame = CGRect(x: 0, y: 80, width: 300, height: 60)
        coordinator.updateAnchorFrame([laterID, earlierID], sharedFrame)

        _ = try XCTUnwrap(coordinator.beginPreservingVisible(sessionID: "session"))
        XCTAssertEqual(coordinator.activeAnchorMessageID, earlierID)
        coordinator.cancelPreservation()
        _ = try XCTUnwrap(coordinator.beginPreservingVisible(sessionID: "session"))
        XCTAssertEqual(coordinator.activeAnchorMessageID, earlierID)
    }

    func testHistoryAnchorCanBeginBeforeFirstScrollMetricsCallback() throws {
        let coordinator = ConversationHistoryScrollCoordinator()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        coordinator.bind(scrollView: scrollView)
        let visibleID = UUID()
        coordinator.updateAnchorFrame([visibleID], CGRect(x: 0, y: 80, width: 300, height: 40))

        XCTAssertNotNil(coordinator.beginPreservingVisible(sessionID: "session"))
        XCTAssertEqual(coordinator.activeAnchorMessageID, visibleID)
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
        var measuredFrames: [UUID: CGRect] = [:]
        var selectedAnchor: (id: UUID, frame: CGRect)?
        ConversationHistoryScrollCoordinator.testingFrameObserver = { messageID, frame in
            measuredFrames[messageID] = frame
        }
        ConversationHistoryScrollCoordinator.testingSelectionObserver = { messageID, frame in
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
            ConversationHistoryScrollCoordinator.testingFrameObserver = nil
            ConversationHistoryScrollCoordinator.testingSelectionObserver = nil
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

        let loadTask = Task {
            await sessionStore.loadEarlierHistoryForSelectedSession()
        }
        for _ in 0..<12 where selectedAnchor == nil {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        let anchor = try XCTUnwrap(selectedAnchor, "加载历史前必须选中一条真实可见消息")
        let anchorID = anchor.id
        let baselineAnchorMinY = anchor.frame.minY
        await client.waitForHistoryRequestCount(2)
        for _ in 0..<4 {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(
                messages: historyViewportMessages(range: 0..<20),
                hasMoreBefore: false
            )
        )
        await loadTask.value

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
        let currentAnchorFrame = try XCTUnwrap(
            measuredFrames[anchorID],
            "prepend 后原始消息 UUID 对应的锚点必须仍存在"
        )
        let currentAnchorMinY = currentAnchorFrame.minY
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

}
