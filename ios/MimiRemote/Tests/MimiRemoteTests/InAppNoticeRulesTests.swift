import UIKit
import XCTest
@testable import MimiRemote

/// #738：同一件事只用一种形式表达，一次性提示不压导航栏和会话页状态卡片。
@MainActor
final class InAppNoticeRulesTests: XCTestCase {
    // MARK: - 同一事件只出一种提示

    func testAutomaticSummaryFallbackShowsOnlyTheHistoryCard() async {
        let project = makeProject(id: "proj_notice_auto_summary")
        let history = makeSession(
            id: "codex_notice_auto_summary",
            projectID: project.id,
            title: "大历史自动降级",
            status: "history",
            source: "codex",
            resumeID: "large"
        )
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)
        client.failHistoryRequest(at: 0, with: historyPolicyError(reason: "history_response_too_large"))
        await client.waitForHistoryRequestCount(2)
        client.resolveHistoryRequest(at: 1, with: summaryPage(content: "自动缩略历史"))
        await selectTask.value

        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryLoaded)
        XCTAssertEqual(store.statusMessage, L10n.text("ui.thumbnail_history_automatically_loaded"))
        XCTAssertNil(store.operationFeedback, "卡片已经说明当前显示缩略历史，不能再弹一条同义轻提示")
    }

    func testSummaryChoiceUsesCardAndFullReloadConfirmsWithToast() async {
        let project = makeProject(id: "proj_notice_summary_choice")
        let history = makeSession(
            id: "codex_notice_summary_choice",
            projectID: project.id,
            title: "大历史",
            status: "history",
            source: "codex",
            resumeID: "large"
        )
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)
        let summaryTask = Task { await store.loadSummaryHistoryForSelectedSession() }
        await client.waitForHistoryRequestCount(2)
        client.resolveHistoryRequest(at: 1, with: summaryPage(content: "缩略历史"))
        await summaryTask.value
        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(messages: [assistantMessage(id: "rollout:late", content: "迟到完整历史")])
        )
        await selectTask.value

        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryLoaded)
        XCTAssertNotEqual(
            store.operationFeedback?.message,
            L10n.text("ui.thumbnail_history_loaded"),
            "手动切到缩略版后由卡片说明，不再弹「已加载缩略历史」"
        )

        // 点卡片里的「加载完整内容」：卡片消失，结果只剩一次性提示来确认。
        let fullTask = Task { await store.loadFullHistoryForSelectedSession() }
        await client.waitForHistoryRequestCount(3)
        client.resolveHistoryRequest(
            at: 2,
            with: HistoryMessagesPage(messages: [assistantMessage(id: "rollout:full", content: "完整历史")])
        )
        await fullTask.value

        XCTAssertNil(store.selectedHistorySavingsNotice)
        XCTAssertEqual(store.operationFeedback?.message, L10n.text("ui.full_history_loaded"))
    }

    // MARK: - 位置

    func testToastTopPaddingClearsBoundaryOrFallsBackToHostTop() {
        XCTAssertEqual(InAppNoticePlacement.toastTopPadding(boundary: nil, hostMinY: 59), 8)
        // iPhone：宿主从状态栏下沿 59pt 开始，导航栏下沿在 103pt。
        XCTAssertEqual(InAppNoticePlacement.toastTopPadding(boundary: 103, hostMinY: 59), 52)
        // 界线在宿主之上（例如没有导航栏的页面）时不能出现负边距。
        XCTAssertEqual(InAppNoticePlacement.toastTopPadding(boundary: 20, hostMinY: 59), 8)
    }

    func testNavigationBarProbeCountsOnlyVisibleBarsAtTheTop() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        // 没有挂到 scene 的 UIWindow 默认隐藏；隐藏的窗口里什么都看不见，探测会如实返回 nil。
        window.isHidden = false
        let container = UIView(frame: window.bounds)
        window.addSubview(container)

        let pageBar = UINavigationBar(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        container.addSubview(pageBar)
        // 隐藏的导航栏与 sheet 里不贴顶的导航栏都不算。
        let hiddenBar = UINavigationBar(frame: CGRect(x: 0, y: 0, width: 390, height: 120))
        hiddenBar.isHidden = true
        container.addSubview(hiddenBar)
        let sheetBar = UINavigationBar(frame: CGRect(x: 0, y: 200, width: 390, height: 44))
        container.addSubview(sheetBar)

        XCTAssertEqual(InAppNoticePlacement.topNavigationBarsBottom(in: window), 44)

        // iPad 分栏：侧栏和详情列各有一条贴顶导航栏，取更低的下沿。
        let detailBar = UINavigationBar(frame: CGRect(x: 320, y: 0, width: 500, height: 50))
        container.addSubview(detailBar)
        XCTAssertEqual(InAppNoticePlacement.topNavigationBarsBottom(in: window), 50)

        container.isHidden = true
        XCTAssertNil(InAppNoticePlacement.topNavigationBarsBottom(in: window))
    }

    func testProtectedRegionsRaiseTheBoundaryUntilWithdrawn() {
        let placement = InAppNoticePlacement()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        // 没有挂到 scene 的 UIWindow 默认隐藏；隐藏的窗口里什么都看不见，探测会如实返回 nil。
        window.isHidden = false
        window.addSubview(UINavigationBar(frame: CGRect(x: 0, y: 0, width: 390, height: 44)))
        placement.window = window
        XCTAssertEqual(placement.topBoundary(), 44)

        let historyCard = UUID()
        let errorBanner = UUID()
        placement.reportProtectedRegion(historyCard, bottom: 130)
        placement.reportProtectedRegion(errorBanner, bottom: 190)
        XCTAssertEqual(placement.topBoundary(), 190)

        placement.reportProtectedRegion(errorBanner, bottom: nil)
        XCTAssertEqual(placement.topBoundary(), 130)
        placement.reportProtectedRegion(historyCard, bottom: nil)
        XCTAssertEqual(placement.topBoundary(), 44)
    }

    // MARK: - Helpers

    private func summaryPage(content: String) -> HistoryMessagesPage {
        HistoryMessagesPage(
            messages: [assistantMessage(id: "rollout:summary", content: content)],
            loadMode: .economy,
            notice: "当前显示缩略历史。"
        )
    }

    private func assistantMessage(id: String, content: String) -> CodexHistoryMessage {
        CodexHistoryMessage(id: id, role: "assistant", content: content, createdAt: Date(timeIntervalSince1970: 20))
    }
}
