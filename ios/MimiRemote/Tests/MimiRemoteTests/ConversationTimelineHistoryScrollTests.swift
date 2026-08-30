import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
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
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 820)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
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
        scrollView.setContentOffset(CGPoint(x: 0, y: historicalOffsetY), animated: false)
        for _ in 0..<12 {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 16_000_000)
        }

        let baselineContentHeight = scrollView.contentSize.height
        let baselineOffsetY = scrollView.contentOffset.y
        XCTAssertGreaterThan(distanceFromBottom(scrollView), 200)

        let loadTask = Task {
            await sessionStore.loadEarlierHistoryForSelectedSession()
        }
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
        let expectedOffsetY = baselineOffsetY + (scrollView.contentSize.height - baselineContentHeight)
        XCTAssertEqual(
            scrollView.contentOffset.y,
            expectedOffsetY,
            accuracy: 6,
            "prepend 后 content height 与 offset 应同步增长，原可见内容不能跳到更早位置"
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
