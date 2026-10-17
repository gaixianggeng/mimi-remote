import XCTest
@testable import MimiRemote

/// #755：跨 860pt 换树不能落在系统尺寸过渡里，换树前要交接输入框的焦点与面板。
@MainActor
final class WorkbenchLayoutModeCommitTests: XCTestCase {
    private var scheduled: [@MainActor () -> Void] = []

    private func makeGate() -> WorkbenchLayoutModeCommitGate {
        WorkbenchLayoutModeCommitGate { [unowned self] action in
            scheduled.append(action)
        }
    }

    private func runScheduled() {
        let actions = scheduled
        scheduled.removeAll()
        actions.forEach { $0() }
    }

    func testCommitWaitsForNextTurnWithoutSizeTransition() {
        let gate = makeGate()
        var commits = 0

        gate.request { commits += 1 }
        XCTAssertEqual(commits, 0, "尺寸变化的那一轮只重排旧树，不能同步换树")

        runScheduled()
        XCTAssertEqual(commits, 1)
    }

    func testCommitWaitsUntilSizeTransitionEnds() {
        let gate = makeGate()
        var commits = 0

        let endTransition = gate.sizeTransitionWillBegin()
        gate.request { commits += 1 }
        runScheduled()
        XCTAssertEqual(commits, 0, "过渡仍在进行时换树，新会话页会被收尾布局再动画一次")

        endTransition()
        XCTAssertEqual(commits, 1)
    }

    func testOnlyLatestRequestCommitsWhenCrossingBackAndForth() {
        let gate = makeGate()
        var committed: [Bool] = []

        gate.request { committed.append(true) }
        gate.request { committed.append(false) }
        runScheduled()

        XCTAssertEqual(committed, [false])
    }

    func testOverlappingTransitionsCommitAfterTheLastOneEnds() {
        let gate = makeGate()
        var commits = 0

        let endFirst = gate.sizeTransitionWillBegin()
        let endSecond = gate.sizeTransitionWillBegin()
        gate.request { commits += 1 }
        runScheduled()

        endFirst()
        endFirst()
        XCTAssertEqual(commits, 0, "重复的结束回调不能提前放行")

        endSecond()
        XCTAssertEqual(commits, 1)
    }

    func testTransitionEndWithoutRequestDoesNothing() {
        let gate = makeGate()
        var commits = 0

        gate.sizeTransitionWillBegin()()
        gate.request { commits += 1 }
        runScheduled()

        XCTAssertEqual(commits, 1)
    }

    func testHandoffRestoresFocusAndPanelForSameScopeOnce() {
        let handoff = ComposerLayoutHandoff()
        let scope = ComposerDraftScopeKey.session("session-a")
        let snapshot = ComposerLayoutHandoff.Snapshot(scope: scope, isEditing: true, panel: .model)
        handoff.register(UUID()) { snapshot }

        handoff.capture()

        XCTAssertEqual(handoff.consume(scope: scope), snapshot)
        XCTAssertNil(handoff.consume(scope: scope), "同一次换树只恢复一次")
    }

    func testHandoffIgnoresOtherScopeAndClearsRecord() {
        let handoff = ComposerLayoutHandoff()
        handoff.register(UUID()) {
            ComposerLayoutHandoff.Snapshot(
                scope: .session("session-a"),
                isEditing: true,
                panel: nil
            )
        }

        handoff.capture()

        XCTAssertNil(handoff.consume(scope: .session("session-b")))
        XCTAssertNil(handoff.consume(scope: .session("session-a")), "之后切回原会话不能再弹出键盘")
    }

    func testHandoffSkipsIdleComposerAndExpiredRecord() {
        let handoff = ComposerLayoutHandoff()
        let scope = ComposerDraftScopeKey.session("session-a")
        var snapshot = ComposerLayoutHandoff.Snapshot(scope: scope, isEditing: false, panel: nil)
        handoff.register(UUID()) { snapshot }

        handoff.capture()
        XCTAssertNil(handoff.consume(scope: scope), "没有焦点也没有面板时无需交接")

        snapshot = ComposerLayoutHandoff.Snapshot(scope: scope, isEditing: false, panel: .addContent)
        let capturedAt = Date()
        handoff.capture(now: capturedAt)
        XCTAssertNil(
            handoff.consume(
                scope: scope,
                now: capturedAt.addingTimeInterval(ComposerLayoutHandoff.restoreWindow + 1)
            )
        )
    }

    func testHandoffPicksEditingComposerAmongRegistered() {
        let handoff = ComposerLayoutHandoff()
        let editing = ComposerLayoutHandoff.Snapshot(
            scope: .session("session-a"),
            isEditing: true,
            panel: nil
        )
        let sheetComposer = UUID()
        handoff.register(UUID()) { editing }
        handoff.register(sheetComposer) {
            ComposerLayoutHandoff.Snapshot(scope: .newSession(projectID: "p"), isEditing: false, panel: nil)
        }

        handoff.capture()
        XCTAssertEqual(handoff.consume(scope: editing.scope), editing)

        // sheet 里的输入框离开后，会话输入框的登记仍在。
        handoff.unregister(sheetComposer)
        handoff.capture()
        XCTAssertEqual(handoff.consume(scope: editing.scope), editing)
    }
}
