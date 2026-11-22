import SwiftUI
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

    // MARK: - 手动刷新当前会话

    func testManualRefreshOfCodexSessionShowsNoTopNotice() async {
        await assertManualRefreshIsQuiet(source: "codex", runtimeProvider: nil)
    }

    func testManualRefreshOfClaudeSessionShowsNoTopNotice() async {
        await assertManualRefreshIsQuiet(source: "claude", runtimeProvider: "claude")
    }

    /// 刷新是用户自己触发的常规操作：加载中不插「正在加载完整历史」「正在切换缩略历史」卡片，
    /// 成功不弹提示；体量超限退回缩略时，只留下表示最终状态的「当前显示缩略历史」卡片。
    private func assertManualRefreshIsQuiet(
        source: String,
        runtimeProvider: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let project = makeProject(id: "proj_notice_refresh_\(source)")
        let session = makeSession(
            id: "\(source)_notice_refresh",
            projectID: project.id,
            title: "刷新当前会话",
            status: "history",
            source: source,
            runtimeProvider: runtimeProvider,
            resumeID: "refresh"
        )
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [session]))
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(session) }
        await client.waitForHistoryRequestCount(1)
        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(messages: [assistantMessage(id: "rollout:open", content: "打开时的历史")])
        )
        await selectTask.value
        store.dismissOperationFeedback(id: store.operationFeedback?.id)

        // 第一次刷新：完整历史直接成功。
        let refreshTask = Task { await store.refreshCurrentContext(origin: .routine) }
        await client.waitForHistoryRequestCount(2)
        XCTAssertEqual(client.requestedMessageLoadModes.last, .full, file: file, line: line)
        XCTAssertNil(store.selectedHistorySavingsNotice, "刷新进行中不应插入「正在加载完整历史」卡片", file: file, line: line)
        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(messages: [assistantMessage(id: "rollout:refresh", content: "刷新后的历史")])
        )
        await refreshTask.value

        XCTAssertNil(store.selectedHistorySavingsNotice, file: file, line: line)
        XCTAssertNil(store.operationFeedback, "刷新成功不弹顶部提示", file: file, line: line)
        XCTAssertEqual(store.statusMessage, L10n.text("ui.the_current_session_has_been_refreshed"), file: file, line: line)

        // 第二次刷新：完整历史超限，自动退回缩略。
        let oversizeTask = Task { await store.refreshCurrentContext(origin: .routine) }
        await client.waitForHistoryRequestCount(3)
        client.failHistoryRequest(at: 2, with: historyPolicyError(reason: "history_response_too_large"))
        await client.waitForHistoryRequestCount(4)
        XCTAssertEqual(client.requestedMessageLoadModes.last, .economy, file: file, line: line)
        XCTAssertNil(store.selectedHistorySavingsNotice, "退回缩略途中不应插入「正在切换缩略历史」卡片", file: file, line: line)
        client.resolveHistoryRequest(at: 3, with: summaryPage(content: "刷新后的缩略历史"))
        await oversizeTask.value

        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryLoaded, file: file, line: line)
        XCTAssertNil(store.operationFeedback, "不再弹「已自动加载缩略历史」", file: file, line: line)
        XCTAssertTrue(store.quietHistoryRefreshSessionIDs.isEmpty, file: file, line: line)

        // 刷新之外的入口不受影响：点卡片里的「加载完整内容」仍显示加载卡片。
        let fullTask = Task { await store.loadFullHistoryForSelectedSession() }
        await client.waitForHistoryRequestCount(5)
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingFull, file: file, line: line)
        client.resolveHistoryRequest(
            at: 4,
            with: HistoryMessagesPage(messages: [assistantMessage(id: "rollout:full", content: "完整历史")])
        )
        await fullTask.value
    }

    func testReconnectFromCodexErrorBannerKeepsProgressFeedback() async {
        await assertReconnectShowsProgress(source: "codex", runtimeProvider: nil)
    }

    func testReconnectFromClaudeErrorBannerKeepsProgressFeedback() async {
        await assertReconnectShowsProgress(source: "claude", runtimeProvider: "claude")
    }

    /// 错误横幅「重新连接」是恢复动作：点完横幅就消失，必须继续看到进行中的卡片和成功结果，
    /// 不能套用常规刷新的静默规则。
    private func assertReconnectShowsProgress(
        source: String,
        runtimeProvider: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let project = makeProject(id: "proj_notice_reconnect_\(source)")
        let session = makeSession(
            id: "\(source)_notice_reconnect",
            projectID: project.id,
            title: "重新连接",
            status: "history",
            source: source,
            runtimeProvider: runtimeProvider,
            resumeID: "reconnect"
        )
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [session]))
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(session) }
        await client.waitForHistoryRequestCount(1)
        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(messages: [assistantMessage(id: "rollout:open", content: "打开时的历史")])
        )
        await selectTask.value
        store.dismissOperationFeedback(id: store.operationFeedback?.id)
        store.setErrorMessage(L10n.text("ui.approval_failed_websocket_not_connected"))
        XCTAssertNotNil(store.errorPresentation, file: file, line: line)

        let reconnectTask = Task { await store.retryAfterErrorPresentation() }
        await client.waitForHistoryRequestCount(2)
        XCTAssertNil(store.errorPresentation, "点「重新连接」后错误横幅收起", file: file, line: line)
        XCTAssertTrue(store.quietHistoryRefreshSessionIDs.isEmpty, file: file, line: line)
        XCTAssertEqual(
            store.selectedHistorySavingsNotice?.kind,
            .loadingFull,
            "横幅收起后要由加载卡片接上进行中的状态",
            file: file,
            line: line
        )
        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(messages: [assistantMessage(id: "rollout:reconnect", content: "重连后的历史")])
        )
        await reconnectTask.value

        XCTAssertNil(store.selectedHistorySavingsNotice, file: file, line: line)
        XCTAssertEqual(
            store.operationFeedback?.message,
            L10n.text("ui.the_current_session_has_been_refreshed"),
            "重连成功仍要告诉用户结果",
            file: file,
            line: line
        )
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

    func testComposerBottomPillPaddingAndSummaryText() {
        let placement = InAppNoticePlacement()
        XCTAssertNil(placement.composerTopBoundary)
        XCTAssertNil(InAppNoticePlacement.toastBottomPadding(composerTopY: nil, hostMaxY: 874))

        let first = UUID()
        let second = UUID()
        placement.reportComposerTopAnchor(first, topY: 710)
        XCTAssertEqual(placement.composerTopBoundary, 710)
        XCTAssertEqual(InAppNoticePlacement.toastBottomPadding(composerTopY: 710, hostMaxY: 874), 174)

        // 同时出现审批卡或更靠上的输入容器时，小药丸取最上沿避免遮挡按钮。
        placement.reportComposerTopAnchor(second, topY: 520)
        XCTAssertEqual(placement.composerTopBoundary, 520)
        XCTAssertEqual(InAppNoticePlacement.toastBottomPadding(composerTopY: 520, hostMaxY: 874), 364)

        placement.reportComposerTopAnchor(second, topY: nil)
        XCTAssertEqual(placement.composerTopBoundary, 710)
        placement.reportComposerTopAnchor(first, topY: nil)
        XCTAssertNil(placement.composerTopBoundary)

        let withSubtitle = InAppToast(id: "t1", style: .success, title: "整理开源发布说明", subtitle: "已完成")
        XCTAssertEqual(InAppToastPill.summaryText(for: withSubtitle), "整理开源发布说明 — 已完成")

        let titleOnly = InAppToast(id: "t2", style: .success, title: "任务已完成", subtitle: nil)
        XCTAssertEqual(InAppToastPill.summaryText(for: titleOnly), "任务已完成")
    }

    func testBottomPillAndAttachmentThumbnailRenderInPhoneWidth() throws {
        let suite = "RefineVisualTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let themeStore = ThemeStore(defaults: defaults)
        let tokens = themeStore.tokens(for: .light)
        let toast = InAppToast(
            id: "bg-complete",
            style: .success,
            title: "检查连接恢复测试",
            subtitle: "已完成",
            tapAction: {}
        )

        // 构造一张纯内存 64×64 测试图片用于缩略图与左上角删除「X」渲染验收。
        let sampleImage = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 10, y: 24, width: 44, height: 28))
        }
        let dataURL = "data:image/png;base64,\(try XCTUnwrap(sampleImage.pngData()).base64EncodedString())"

        let preview = VStack(spacing: 16) {
            Spacer()
            InAppToastPill(toast: toast, onDismiss: {})
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ComposerImageAttachmentThumbnail(
                        id: "refine-sample-1",
                        source: .dataURL(dataURL),
                        accessibilityLabel: "图片附件 1",
                        canPreview: true,
                        onPreview: {},
                        onRemove: {}
                    )
                    ComposerImageAttachmentThumbnail(
                        id: "refine-sample-2",
                        source: .dataURL(dataURL),
                        accessibilityLabel: "图片附件 2",
                        canPreview: true,
                        onPreview: {},
                        onRemove: {}
                    )
                    Spacer()
                }
                Text("请帮我检查这两张截图里的布局间距")
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(tokens.conversationPrimaryText)
                    .padding(.horizontal, 4)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tokens.inputBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.09), lineWidth: 0.75)
            }
        }
        .padding(16)
        .frame(width: 402, height: 340)
        .background(tokens.conversationCanvasBackground)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)

        let bounds = CGRect(x: 0, y: 0, width: 402, height: 340)
        let host = UIHostingController(rootView: preview)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = bounds
        } else {
            window = UIWindow(frame: bounds)
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        host.view.frame = bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.view.layoutIfNeeded()

        XCTAssertGreaterThan(host.sizeThatFits(in: bounds.size).height, 0)
        let rendered = UIGraphicsImageRenderer(bounds: bounds).image { ctx in
            if !window.drawHierarchy(in: bounds, afterScreenUpdates: true) {
                host.view.layer.render(in: ctx.cgContext)
            }
        }
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "refine-pill-and-attachment-thumbnail"
        attachment.lifetime = .keepAlways
        add(attachment)
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
