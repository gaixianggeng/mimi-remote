import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class ConversationScrollStabilityTests: XCTestCase {
    func testPresentationChangePreservesReadingPositionEvenWhenPreviouslyFollowingTail() async throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        let marker = rig.addMarker(id: rig.messages[0].id)
        XCTAssertEqual(rig.controller.mode, .followingTail)
        rig.publish(changes: [.presentation, .historyReplacement])
        marker.frame.origin.y += 240
        rig.report(offset: 1_200, height: 2_600)
        await drain()
        XCTAssertEqual(rig.controller.mode, .readingHistory)
        XCTAssertEqual(rig.scrollView.contentOffset.y, 1_440, accuracy: 0.5)
        XCTAssertTrue(rig.commands.allSatisfy { $0.target != .tail })
    }

    func testFileRevealTargetsActivityAndStopsTailFollowing() async throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        rig.controller.revealItem("activity:file-change")
        await drain()
        XCTAssertEqual(rig.commands.map(\.target), [.anchorItem("activity:file-change")])
        XCTAssertEqual(rig.controller.mode, .readingHistory)
        rig.publish(changes: .live)
        rig.report(offset: 900, height: 2_400)
        await drain()
        XCTAssertTrue(rig.commands.allSatisfy { $0.target != .tail })
    }

    func testProjectionCapturesOldViewportOnlyWhenPublishingAChangedSnapshot() throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        rig.controller.beginLoadingEarlierHistory()
        rig.addMarker()
        var captures = 0
        ConversationTimelineViewport.testingSelectionObserver = { _, _ in captures += 1 }
        defer { ConversationTimelineViewport.testingSelectionObserver = nil }
        XCTAssertFalse(rig.controller.prepare(rig.snapshot))
        XCTAssertEqual(captures, 0)
        let cache = ConversationTimelineItemCache()
        let first = cache.snapshot(from: rig.messages, scope: rig.scope)
        let frozen = cache.snapshot(
            from: rig.messages + [ConversationMessage(role: .assistant, content: "next")],
            suspendingUpdates: true, scope: rig.scope
        )
        XCTAssertEqual(frozen.revision, first.revision)
        XCTAssertEqual(captures, 0, "冻结列表不能捕获下一版布局")
        rig.publish(changes: .historyEnrichment)
        XCTAssertEqual(captures, 1)
    }

    func testFrozenProjectionCannotLeakAcrossSessionOrProfile() {
        let cache = ConversationTimelineItemCache()
        let old = ConversationMessage(role: .user, content: "old")
        let next = ConversationMessage(role: .assistant, content: "next")
        _ = cache.snapshot(from: [old], scope: ScopedSessionID(profileID: "a", sessionID: "one"))
        let changed = cache.snapshot(
            from: [next], suspendingUpdates: true,
            scope: ScopedSessionID(profileID: "b", sessionID: "two")
        )
        XCTAssertEqual(changed.rows.count, 1)
        XCTAssertEqual(changed.tail?.messageID, next.id)
        XCTAssertEqual(changed.scope?.profileID, "b")
    }

    func testPrunedSummaryFallsBackToSurvivingVisibleMessage() throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        let summary = rig.addMarker(y: 1_280)
        let surviving = rig.addMarker(y: 1_360)
        let anchor = try XCTUnwrap(rig.controller.viewport.captureVisibleAnchor())
        XCTAssertEqual(anchor.candidates.count, 2)
        summary.removeFromSuperview()
        surviving.frame.origin.y += 60
        rig.scrollView.contentSize.height += 60
        XCTAssertEqual(try XCTUnwrap(rig.controller.viewport.correctedOffset(for: anchor)), 1_260)
    }

    func testCorrectionSamplesLiveOffsetAndFrameTogether() throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        rig.scrollView.contentOffset.y = 400
        let marker = rig.addMarker(y: 500)
        let anchor = try XCTUnwrap(rig.controller.viewport.captureVisibleAnchor())
        // List 已自行补偿 60pt，SwiftUI 尚未报告新 offset/frame。只读同一 UIKit 时刻。
        marker.frame.origin.y += 60
        rig.scrollView.contentOffset.y += 60
        XCTAssertEqual(try XCTUnwrap(rig.controller.viewport.correctedOffset(for: anchor)), 460)
    }

    func testPrependingHistoryKeepsPositionWhenVisibleCellsAreRecycled() async throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        rig.controller.beginLoadingEarlierHistory()
        rig.report(offset: 0)
        let marker = rig.addMarker(y: 100, id: rig.messages[0].id)
        rig.publish(changes: .historyPrepend)
        // 顶部插入整页后，List 可能先回收所有旧可见 cell，再按新 offset 实例化它们。
        marker.removeFromSuperview()
        rig.report(offset: 0, height: 5_000)
        await drain()
        XCTAssertEqual(rig.commands.map(\.target), [.anchorItem(rig.snapshot.rowIDs[0])])
        // 模拟 scrollTo 重新实例化旧消息。之后只按它的实际 frame 纠正位置。
        _ = rig.addMarker(y: 3_100, id: rig.messages[0].id)
        await drain()
        XCTAssertEqual(rig.scrollView.contentOffset.y, 3_000, accuracy: 0.5)
        XCTAssertTrue(rig.commands.allSatisfy { $0.target != .tail })

        // 同一布局的 offset 回写不能把用户下一次上滑拉回去。
        rig.controller.phaseChanged(.tracking)
        rig.report(offset: 2_800, height: 5_000)
        rig.controller.phaseChanged(.idle)
        let commandCount = rig.commands.count
        rig.report(offset: 2_800, height: 5_000)
        await drain()
        XCTAssertEqual(rig.scrollView.contentOffset.y, 2_800)
        XCTAssertEqual(rig.commands.count, commandCount)
    }

    func testReusedNativeMarkerCannotStandInForAnOldMessage() throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        let marker = rig.addMarker()
        let anchor = try XCTUnwrap(rig.controller.viewport.captureVisibleAnchor())
        rig.controller.viewport.bindAnchorView([UUID()], marker)
        XCTAssertNil(rig.controller.viewport.correctedOffset(for: anchor))
    }

    func testHiddenNativeCellCannotStandInForAnOldMessage() throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        let marker = rig.addMarker()
        let anchor = try XCTUnwrap(rig.controller.viewport.captureVisibleAnchor())
        let hiddenCell = UIView(frame: marker.frame)
        rig.scrollView.addSubview(hiddenCell)
        hiddenCell.addSubview(marker)
        hiddenCell.isHidden = true
        XCTAssertTrue(marker.isDescendant(of: rig.scrollView))
        XCTAssertNil(rig.controller.viewport.correctedOffset(for: anchor))
    }

    func testRebindingSharedMarkerKeepsMessagesAlreadyMovedToAnotherView() throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        let shared = rig.addMarker()
        let retainedID = UUID()
        rig.controller.viewport.bindAnchorView([rig.markerID, retainedID], shared)
        rig.controller.recordAnchorFrame([rig.markerID, retainedID], shared.convert(shared.bounds, to: nil))
        let anchor = try XCTUnwrap(rig.controller.viewport.captureVisibleAnchor())
        let inner = rig.addMarker(y: 1_360)
        rig.scrollView.contentSize.height += 60
        rig.controller.viewport.bindAnchorView([rig.markerID], inner)
        // 旧外层随后复用，只能撤销仍归它所有的 UUID，不能抹掉已迁入内层的绑定。
        rig.controller.viewport.bindAnchorView([retainedID], shared)
        XCTAssertEqual(try XCTUnwrap(rig.controller.viewport.correctedOffset(for: anchor)), 1_260)
    }

    func testPreservationExpiresWithoutFurtherScrollWrites() async throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        rig.controller.beginLoadingEarlierHistory()
        let marker = rig.addMarker()
        rig.publish(changes: .historyEnrichment)
        await drain()
        rig.commands.removeAll()
        try await Task.sleep(for: .milliseconds(350))
        marker.frame.origin.y += 60
        rig.controller.recordAnchorFrame([rig.markerID], marker.convert(marker.bounds, to: nil))
        await drain()
        XCTAssertTrue(rig.commands.isEmpty, "过期事务不得因随后布局再次写入")
    }

    func testInteractionDiscardsOldAnchorEvenAfterReturningToIdle() async throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        rig.controller.beginLoadingEarlierHistory()
        let marker = rig.addMarker()
        rig.publish(changes: .historyEnrichment)
        marker.frame.origin.y += 60
        rig.controller.phaseChanged(.tracking)
        rig.report(offset: 600)
        rig.controller.phaseChanged(.decelerating)
        await drain()
        XCTAssertTrue(rig.commands.isEmpty)
        rig.controller.phaseChanged(.idle)
        rig.controller.recordAnchorFrame([rig.markerID], marker.convert(marker.bounds, to: nil))
        await drain()
        XCTAssertTrue(rig.commands.isEmpty, "手势后的阅读位置不能被旧事务拉回")
        XCTAssertEqual(rig.controller.mode, .readingHistory)
    }

    func testInitialPresentationRequiresActualTailButNotCompletedHistoryLoading() {
        let rig = ScrollRig(connect: false)
        XCTAssertFalse(rig.controller.isReadable)
        rig.controller.tailVisibilityChanged(true, epoch: rig.controller.epoch)
        XCTAssertFalse(rig.controller.isReadable, "尚未执行首次定位不能揭开正文")
        rig.connect()
        rig.report(offset: 1_100)
        // writer 模拟 scrollTo 到实际尾部，并反馈执行结果。
        XCTAssertTrue(rig.controller.isReadable)
        XCTAssertEqual(rig.controller.mode, .followingTail)
        rig.publish(changes: .historyEnrichment)
        XCTAssertTrue(rig.controller.isReadable, "后续历史补齐不重新遮罩")
    }

    func testTailLayoutCorrectionUsesCurrentSizeAndDoesNotWriteDuringInteraction() {
        let rig = ScrollRig()
        rig.report(offset: 1_200, height: 2_400)
        XCTAssertEqual(rig.scrollView.contentOffset.y, 1_600)
        XCTAssertEqual(rig.commands.count, 1)
        rig.controller.phaseChanged(.tracking)
        rig.report(offset: 1_100, height: 2_800)
        XCTAssertEqual(rig.commands.count, 1)
        XCTAssertEqual(rig.scrollView.contentOffset.y, 1_100, "不能修正用户手势中的位置")
    }

    func testRepeatedNativeOffsetFeedbackDoesNotCreateNewTailCommands() {
        let rig = ScrollRig()
        let marker = rig.addMarker()
        rig.report(offset: 1_200, height: 2_600)
        XCTAssertEqual(rig.commands.count, 1)
        // 复现日志中的系统回写：同一尺寸下反复把偏移减去 40pt。
        for _ in 0..<200 {
            rig.report(offset: 1_760, height: 2_600)
            rig.controller.anchorViewDidLayout([rig.markerID], view: marker, epoch: rig.controller.epoch)
            rig.report(offset: 1_800, height: 2_600)
        }
        XCTAssertEqual(rig.commands.count, 1, "offset 是执行结果，不得变成新滚动输入")
    }

    func testOldScopeCallbacksCannotWriteIntoReplacementList() async {
        let rig = ScrollRig()
        let oldEpoch = rig.controller.epoch
        rig.publish(changes: .live)
        rig.scope = ScopedSessionID(profileID: "profile", sessionID: "replacement")
        rig.publish(changes: .historyReplacement)
        rig.commands.removeAll()
        rig.controller.geometryChanged(rig.metrics(offset: 300, height: 3_000), epoch: oldEpoch)
        rig.controller.tailVisibilityChanged(true, epoch: oldEpoch)
        rig.controller.phaseChanged(.tracking, epoch: oldEpoch)
        rig.controller.connect(epoch: oldEpoch) { _ in XCTFail("旧 executor 不得重新接线") }
        await drain()
        XCTAssertTrue(rig.commands.isEmpty)
        XCTAssertFalse(rig.controller.isInteracting)
        XCTAssertFalse(rig.controller.isReadable)
        XCTAssertEqual(rig.controller.scope, rig.scope)
    }

    func testInitialCommandDoesNotRequireNativeTailCellToExist() async {
        let controller = ConversationTimelineScrollController()
        let snapshot = ConversationTimelineItemCache().snapshot(
            from: [ConversationMessage(role: .assistant, content: "first")],
            scope: ScopedSessionID(profileID: "profile", sessionID: "first")
        )
        controller.prepare(snapshot)
        var commands: [ConversationTimelineScrollCommand] = []
        controller.connect(epoch: controller.epoch) { commands.append($0) }
        controller.geometryChanged(
            ConversationTimelineScrollMetrics(
                isNearBottom: false, contentOffsetY: 0, contentHeight: 2_000,
                minimumOffsetY: 0, maximumOffsetY: 1_200
            ), epoch: controller.epoch
        )
        await drain()
        XCTAssertNil(controller.viewport.scrollView)
        XCTAssertEqual(commands.map(\.target), [.tail])
    }

    func testEmptyListCallbacksCannotAffectFirstContentList() {
        let controller = ConversationTimelineScrollController()
        let cache = ConversationTimelineItemCache()
        let scope = ScopedSessionID(profileID: "", sessionID: "cold-session")
        controller.prepare(cache.snapshot(from: [], scope: scope))
        let emptyEpoch = controller.epoch
        controller.prepare(cache.snapshot(from: [ConversationMessage(role: .assistant, content: "first")], scope: scope))
        XCTAssertGreaterThan(controller.epoch, emptyEpoch)
        controller.phaseChanged(.tracking, epoch: emptyEpoch)
        controller.connect(epoch: emptyEpoch) { _ in XCTFail("空 List 不能为正文执行滚动") }
        controller.tailVisibilityChanged(true, epoch: emptyEpoch)
        XCTAssertFalse(controller.isInteracting)
        XCTAssertFalse(controller.isReadable)
    }

    func testFirstContentEndsInteractionOwnedByEmptyListAndBecomesReadable() async {
        let rig = ScrollRig(connect: false, startsEmpty: true)
        let emptyEpoch = rig.controller.epoch
        rig.controller.phaseChanged(.tracking, epoch: emptyEpoch)
        XCTAssertTrue(rig.controller.isInteracting)

        rig.messages = [ConversationMessage(role: .assistant, content: "首批历史")]
        rig.publish(changes: .historyReplacement)
        XCTAssertGreaterThan(rig.controller.epoch, emptyEpoch)
        XCTAssertFalse(rig.controller.isInteracting, "新 List 不得继承已经失效的手势")
        rig.controller.phaseChanged(.idle, epoch: emptyEpoch)
        rig.controller.bind(scrollView: rig.scrollView, epoch: rig.controller.epoch)
        rig.connect()
        rig.report(offset: 0)
        rig.controller.tailVisibilityChanged(true, epoch: rig.controller.epoch)
        await drain()

        XCTAssertTrue(rig.controller.isReadable)
        XCTAssertEqual(rig.scrollView.contentOffset.y, 1_200, accuracy: 4)
        let cache = ConversationTimelineItemCache()
        _ = cache.snapshot(from: rig.messages, scope: rig.scope)
        let next = cache.snapshot(
            from: rig.messages + [ConversationMessage(role: .assistant, content: "后续补齐")],
            suspendingUpdates: rig.controller.isInteracting, scope: rig.scope
        )
        XCTAssertEqual(next.rows.count, 2, "首屏之后的投影不能继续冻结")
    }

    func testSubmissionBeforeInitialHandoffStillRequiresAndCompletesReadableTail() async {
        for includesAssistantUpdate in [false, true] {
            let rig = ScrollRig(connect: false)
            rig.messages.append(ConversationMessage(clientMessageID: "submission", role: .user, content: "继续"))
            if includesAssistantUpdate {
                rig.messages.append(ConversationMessage(role: .assistant, content: "已开始回复"))
            }
            rig.publish(changes: [.localSubmission, .live])
            XCTAssertFalse(rig.controller.isReadable, "发送意图不能提前揭开未定位的正文")
            rig.connect()
            rig.report(offset: 0)
            XCTAssertFalse(rig.controller.isReadable, "还需要尾部哨兵确认")
            rig.controller.tailVisibilityChanged(true, epoch: rig.controller.epoch)
            await drain()
            XCTAssertTrue(rig.controller.isReadable, "本地发送不能跳过可读性交接入口")
            XCTAssertEqual(rig.controller.mode, .followingTail)
            XCTAssertEqual(rig.scrollView.contentOffset.y, 1_200, accuracy: 4)
        }
    }

    func testReturnToTailBeforeInitialHandoffDoesNotStrandTheCover() async {
        let rig = ScrollRig(connect: false)
        rig.controller.returnToTail()
        XCTAssertFalse(rig.controller.isReadable)
        rig.connect()
        rig.report(offset: 0)
        rig.controller.tailVisibilityChanged(true, epoch: rig.controller.epoch)
        await drain()
        XCTAssertTrue(rig.controller.isReadable)
        XCTAssertEqual(rig.scrollView.contentOffset.y, 1_200, accuracy: 4)
    }

    func testReturnToTailDuringDecelerationRunsOnceAfterIdleWithoutOtherUpdates() async {
        let rig = ScrollRig()
        XCTAssertTrue(rig.controller.isReadable)
        rig.controller.phaseChanged(.tracking)
        rig.report(offset: 600)
        rig.controller.phaseChanged(.decelerating)
        rig.controller.returnToTail()
        await drain()
        XCTAssertTrue(rig.commands.isEmpty, "显式请求也不能在当前手势内抢写位置")
        XCTAssertEqual(rig.controller.mode, .readingHistory, "请求尚未执行时不能提前隐藏按钮")
        rig.report(offset: 500)
        rig.controller.phaseChanged(.idle)
        await drain()
        XCTAssertEqual(rig.commands.map(\.target), [.tail])
        XCTAssertEqual(rig.scrollView.contentOffset.y, 1_200, accuracy: 4)
        XCTAssertEqual(rig.controller.mode, .followingTail)
        rig.controller.phaseChanged(.idle)
        await drain()
        XCTAssertEqual(rig.commands.count, 1)
    }

    func testNewGestureCancelsReturnToTailQueuedDuringDeceleration() async {
        for startsBeforeIdle in [false, true] {
            let rig = ScrollRig()
            rig.controller.phaseChanged(.tracking)
            rig.report(offset: 600)
            rig.controller.phaseChanged(.decelerating)
            rig.controller.returnToTail()
            if !startsBeforeIdle { rig.controller.phaseChanged(.idle) }
            // 新手势既可能中断旧惯性，也可能抢在 idle 后的合并任务之前到来。
            rig.controller.phaseChanged(.tracking)
            rig.report(offset: 450)
            rig.controller.phaseChanged(.idle)
            await drain()
            XCTAssertTrue(rig.commands.isEmpty)
            XCTAssertEqual(rig.controller.mode, .readingHistory)
            XCTAssertEqual(rig.scrollView.contentOffset.y, 450, accuracy: 0.5)
        }
    }

    func testThawedMetadataSnapshotDoesNotDiscardExplicitReturnToTail() async {
        let rig = ScrollRig()
        rig.controller.phaseChanged(.tracking)
        rig.report(offset: 600)
        rig.controller.phaseChanged(.decelerating)
        rig.controller.returnToTail()
        rig.controller.phaseChanged(.idle)
        // 隐藏输出等来源更新只提高 revision，不改变 rows 或总高度。
        rig.publish(changes: .live)
        await drain()
        XCTAssertEqual(rig.commands.map(\.target), [.tail])
        XCTAssertEqual(rig.scrollView.contentOffset.y, 1_200, accuracy: 4)
    }

    func testInitialPresentationCompletesWhenCommandDoesNotChangeGeometry() async {
        let rig = ScrollRig(connect: false)
        rig.report(offset: 1_200)
        rig.controller.tailVisibilityChanged(true, epoch: rig.controller.epoch)
        XCTAssertFalse(rig.controller.isReadable)
        rig.controller.connect(epoch: rig.controller.epoch) { _ in }
        await drain()
        XCTAssertTrue(rig.controller.isReadable, "无变化的 scrollTo 不会再报告 geometry，仍须交接首屏")
    }

    func testExpansionKeepsItsItemTargetThroughoutLayoutAnimation() async {
        let rig = ScrollRig()
        let input = rig.controller.expansionChanged("activity-batch", isExpanded: true)
        await drain()
        for height in stride(from: 2_100, through: 2_500, by: 100) {
            rig.report(offset: 1_200, height: CGFloat(height))
        }
        XCTAssertFalse(rig.commands.isEmpty)
        XCTAssertTrue(rig.commands.allSatisfy { $0.target == .item("activity-batch") })
        rig.controller.expansionCompleted(input)
        let count = rig.commands.count
        await drain()
        XCTAssertEqual(rig.commands.count, count)
    }

    func testHistoryExpansionAnchorSurvivesUntilAnimationCompletion() async throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        rig.scrollView.contentOffset.y = 600
        rig.controller.beginLoadingEarlierHistory()
        let marker = rig.addMarker(y: 700)
        let input = rig.controller.expansionChanged("activity-batch", isExpanded: true)
        await drain()
        try await Task.sleep(for: .milliseconds(350))
        marker.frame.origin.y += 60
        rig.controller.recordAnchorFrame([UUID()], CGRect(x: 0, y: 500, width: 10, height: 10))
        await drain()
        XCTAssertEqual(rig.scrollView.contentOffset.y, 660)
        rig.controller.expansionCompleted(input)
        let count = rig.commands.count
        marker.frame.origin.y += 60
        rig.controller.recordAnchorFrame([UUID()], CGRect(x: 0, y: 500, width: 10, height: 10))
        await drain()
        XCTAssertEqual(rig.commands.count, count, "动画完成后结束锚点，不持续持有旧阅读位置")
    }

    func testNonAnimatedExpansionPreservesNextLayoutAndThenExpires() async throws {
        let rig = ScrollRig()
        let window = try mount(rig.scrollView)
        defer { window.isHidden = true }
        rig.scrollView.contentOffset.y = 600
        rig.controller.beginLoadingEarlierHistory()
        let marker = rig.addMarker(y: 700)
        rig.controller.expansionChanged("activity-batch", isExpanded: true, isAnimated: false)
        marker.frame.origin.y += 60
        await drain()
        XCTAssertEqual(rig.scrollView.contentOffset.y, 660)
        try await Task.sleep(for: .milliseconds(350))
        let count = rig.commands.count
        marker.frame.origin.y += 60
        rig.controller.recordAnchorFrame([UUID()], CGRect(x: 0, y: 500, width: 10, height: 10))
        await drain()
        XCTAssertEqual(rig.commands.count, count)
    }

    func testDiagnosticsAreOptInBoundedAndLazy() {
        let trace = ConversationScrollDiagnostics()
        var evaluated = false
        func detail() -> String { evaluated = true; return "count=1" }
        trace.record("disabled", detail())
        XCTAssertFalse(evaluated)
        trace.start()
        for _ in 0..<(ConversationScrollDiagnostics.capacity + 10) { trace.record("test", "count=1") }
        trace.stop()
        let exported = trace.export()
        XCTAssertEqual(exported.split(separator: "\n").count, ConversationScrollDiagnostics.capacity + 1)
        XCTAssertTrue(exported.contains("stop"))
        trace.record("after_stop")
        XCTAssertEqual(trace.export(), exported)
    }

    private func drain() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func mount(_ scrollView: UIScrollView) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.addSubview(scrollView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }
}

@MainActor
private final class ScrollRig {
    let controller = ConversationTimelineScrollController()
    let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    var scope = ScopedSessionID(profileID: "profile", sessionID: "session")
    var messages = [ConversationMessage(role: .assistant, content: "first")]
    let markerID = UUID()
    var commands: [ConversationTimelineScrollCommand] = []
    private var revision = 0
    private(set) var snapshot = ConversationTimelineSnapshot.empty

    init(connect shouldConnect: Bool = true, startsEmpty: Bool = false) {
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentSize = CGSize(width: 400, height: 2_000)
        scrollView.contentOffset.y = 1_200
        if startsEmpty { messages = [] }
        publish(changes: .historyReplacement)
        controller.bind(scrollView: scrollView, epoch: controller.epoch)
        if shouldConnect {
            connect()
            report(offset: 1_200)
            controller.tailVisibilityChanged(true, epoch: controller.epoch)
            commands.removeAll()
        }
    }

    func publish(changes: ConversationTimelineChangeReasons) {
        revision += 1
        let rows = ConversationTimelineItemBuilder.items(from: messages)
        snapshot = ConversationTimelineSnapshot(
            scope: scope, rows: rows, rowIDs: rows.map(\.id), tail: nil,
            changes: changes, revision: revision
        )
        controller.prepare(snapshot)
        controller.snapshotWasPublished()
    }

    func connect() {
        controller.connect(epoch: controller.epoch) { [weak self] command in
            guard let self else { return }
            commands.append(command)
            switch command.target {
            case .tail: scrollView.contentOffset.y = scrollView.contentSize.height - scrollView.bounds.height
            case let .offset(offset): scrollView.contentOffset.y = offset
            case .item, .anchorItem: break
            }
            controller.geometryChanged(
                metrics(offset: scrollView.contentOffset.y, height: scrollView.contentSize.height),
                epoch: controller.epoch
            )
        }
    }

    func report(offset: CGFloat, height: CGFloat = 2_000) {
        scrollView.contentSize.height = height
        scrollView.contentOffset.y = offset
        controller.geometryChanged(metrics(offset: offset, height: height), epoch: controller.epoch)
    }

    func metrics(offset: CGFloat, height: CGFloat) -> ConversationTimelineScrollMetrics {
        ConversationTimelineScrollMetrics(
            isNearBottom: height - 800 - offset <= 120,
            contentOffsetY: offset, contentHeight: height, minimumOffsetY: 0, maximumOffsetY: height - 800
        )
    }

    @discardableResult
    func addMarker(y: CGFloat = 1_300, id explicitID: UUID? = nil) -> UIView {
        let marker = UIView(frame: CGRect(x: 0, y: y, width: 300, height: 40))
        scrollView.addSubview(marker)
        let id = explicitID ?? (y == 1_300 ? markerID : UUID())
        controller.viewport.bindAnchorView([id], marker)
        controller.recordAnchorFrame([id], marker.convert(marker.bounds, to: nil))
        return marker
    }
}
