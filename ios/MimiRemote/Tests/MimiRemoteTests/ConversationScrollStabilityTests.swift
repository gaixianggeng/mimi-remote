import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class ConversationScrollStabilityTests: XCTestCase {
    func testProjectionCapturesOldViewportOnlyWhenPublishingAChangedSnapshot() {
        let cache = ConversationTimelineItemCache()
        let first = ConversationMessage(role: .user, content: "first")
        let second = ConversationMessage(role: .assistant, content: "second")
        var captures = 0
        let initial = cache.snapshot(from: [first], willUpdate: { captures += 1 })
        XCTAssertEqual(captures, 0)
        _ = cache.snapshot(from: [first], willUpdate: { captures += 1 })
        let frozen = cache.snapshot(from: [first, second], suspendingUpdates: true, willUpdate: { captures += 1 })
        XCTAssertEqual(captures, 0, "无变化或拖动冻结期间不得建锚")
        XCTAssertEqual(frozen.revision, initial.revision)
        let updated = cache.snapshot(from: [first, second]) {
            XCTAssertEqual(cache.tailItemID, initial.tailItemID, "必须先捕获旧投影，再提交新投影")
            captures += 1
        }
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(updated.revision, initial.revision + 1)
    }

    func testFrozenProjectionCannotLeakAcrossSessionOrProfile() {
        let cache = ConversationTimelineItemCache()
        let old = ConversationMessage(role: .user, content: "old")
        let next = ConversationMessage(role: .assistant, content: "next")
        _ = cache.snapshot(from: [old], scope: ScopedSessionID(profileID: "a", sessionID: "one"))
        var captures = 0
        let changed = cache.snapshot(
            from: [next], suspendingUpdates: true,
            scope: ScopedSessionID(profileID: "b", sessionID: "two"),
            willUpdate: { captures += 1 }
        )
        XCTAssertEqual(changed.items.count, 1)
        XCTAssertEqual(changed.tailItemID, ConversationTimelineItemBuilder.items(from: [next]).last?.id)
        XCTAssertEqual(captures, 0, "不能用旧会话的可见锚点修正新会话")
    }

    func testPrunedSummaryFallsBackToSurvivingVisibleMessage() throws {
        let coordinator = ConversationHistoryScrollCoordinator()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let window = try mount(scrollView)
        defer { window.isHidden = true }
        coordinator.bind(scrollView: scrollView)
        let summaryID = UUID()
        let survivingID = UUID()
        let summary = UIView(frame: CGRect(x: 0, y: 80, width: 300, height: 40))
        let surviving = UIView(frame: CGRect(x: 0, y: 160, width: 300, height: 40))
        scrollView.addSubview(summary)
        scrollView.addSubview(surviving)
        coordinator.bindAnchorView([summaryID], summary)
        coordinator.bindAnchorView([survivingID], surviving)
        coordinator.updateAnchorFrame([summaryID], summary.frame)
        coordinator.updateAnchorFrame([survivingID], surviving.frame)
        coordinator.update(metrics: metrics(offset: 0))
        let baseline = surviving.convert(surviving.bounds, to: nil).minY
        let generation = try XCTUnwrap(coordinator.beginPreservingVisible(sessionID: "session"))
        summary.removeFromSuperview()
        surviving.frame.origin.y += 60
        let correction = try XCTUnwrap(coordinator.correction(expectedGeneration: generation, displayedSessionID: "session"))
        XCTAssertEqual(correction.baselineAnchorMinY, baseline)
        XCTAssertEqual(correction.currentAnchorMinY, baseline + 60)
        XCTAssertNil(coordinator.correction(expectedGeneration: generation, displayedSessionID: "other"))
        coordinator.cancelPreservation()
    }

    func testCorrectionSamplesLiveOffsetAndFrameTogether() throws {
        let coordinator = ConversationHistoryScrollCoordinator()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let window = try mount(scrollView)
        defer { window.isHidden = true }
        scrollView.contentSize = CGSize(width: 400, height: 2_000)
        scrollView.contentOffset.y = 400
        let marker = UIView(frame: CGRect(x: 0, y: 500, width: 300, height: 40))
        scrollView.addSubview(marker)
        let id = UUID()
        coordinator.bind(scrollView: scrollView)
        coordinator.bindAnchorView([id], marker)
        coordinator.updateAnchorFrame([id], CGRect(x: 0, y: 100, width: 300, height: 40))
        coordinator.update(metrics: metrics(offset: 400))
        let generation = try XCTUnwrap(coordinator.beginPreservingVisible(sessionID: "session"))

        // List 已自行补偿 60pt，但 SwiftUI 的 offset/frame 通知仍是旧值。
        marker.frame.origin.y += 60
        scrollView.contentOffset.y += 60
        let correction = try XCTUnwrap(coordinator.correction(expectedGeneration: generation, displayedSessionID: "session"))
        XCTAssertEqual(correction.metrics.contentOffsetY, 460)
        XCTAssertEqual(correction.currentAnchorMinY, correction.baselineAnchorMinY)
        let target = ConversationTimelineView.historyPreservedOffset(
            currentOffsetY: correction.metrics.contentOffsetY,
            currentAnchorMinY: correction.currentAnchorMinY,
            baselineAnchorMinY: correction.baselineAnchorMinY,
            minimumOffsetY: correction.metrics.minimumOffsetY,
            maximumOffsetY: correction.metrics.maximumOffsetY
        )
        XCTAssertEqual(target, 460, "不得重复补偿 List 已完成的位移")
        coordinator.cancelPreservation()
    }

    func testPreservationExpiresWithoutFurtherScrollWrites() async throws {
        let coordinator = ConversationHistoryScrollCoordinator()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        coordinator.bind(scrollView: scrollView)
        coordinator.updateAnchorFrame([UUID()], CGRect(x: 0, y: 80, width: 300, height: 40))
        XCTAssertNotNil(coordinator.beginPreservingVisible(sessionID: "session"))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(coordinator.activeGeneration)
        var writes = 0
        coordinator.scheduleCorrection(displayedSessionID: "session") { _ in writes += 1 }
        await Task.yield()
        XCTAssertEqual(writes, 0)
    }

    func testInteractionDiscardsOldAnchorEvenAfterReturningToIdle() async throws {
        let coordinator = ConversationHistoryScrollCoordinator()
        let anchorID = UUID()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        coordinator.bind(scrollView: scrollView)
        coordinator.updateAnchorFrame([anchorID], CGRect(x: 0, y: 80, width: 300, height: 40))
        coordinator.update(metrics: metrics(offset: 0))
        let generation = try XCTUnwrap(coordinator.beginPreservingVisible(sessionID: "session"))

        var writes = 0
        coordinator.scheduleCorrection(
            expectedGeneration: generation,
            displayedSessionID: "session"
        ) { _ in
            writes += 1
        }
        coordinator.setInteractionActive(true)
        for _ in 0..<3 {
            await Task.yield()
        }

        XCTAssertNil(coordinator.activeGeneration)
        XCTAssertEqual(writes, 0)

        coordinator.setInteractionActive(false)
        coordinator.scheduleCorrection(
            expectedGeneration: generation,
            displayedSessionID: "session"
        ) { _ in
            writes += 1
        }
        for _ in 0..<3 {
            await Task.yield()
        }
        XCTAssertEqual(writes, 0, "手势后的阅读位置不能被旧事务拉回")
    }

    func testInitialPresentationRequiresStableGeometryAtTheActualTail() {
        let tail = metrics(offset: 1_200)
        XCTAssertFalse(ConversationTimelineView.isInitialTailLayoutStable(previous: nil, current: tail))
        XCTAssertFalse(ConversationTimelineView.isInitialTailLayoutStable(previous: metrics(offset: 1_100), current: tail))
        XCTAssertFalse(ConversationTimelineView.isInitialTailLayoutStable(previous: metrics(offset: 1_100), current: metrics(offset: 1_100)))
        XCTAssertTrue(ConversationTimelineView.isInitialTailLayoutStable(previous: tail, current: tail))
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

    private func metrics(offset: CGFloat) -> ConversationTimelineScrollMetrics {
        ConversationTimelineScrollMetrics(isNearBottom: false, contentOffsetY: offset, contentHeight: 2_000, minimumOffsetY: 0, maximumOffsetY: 1_200)
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
