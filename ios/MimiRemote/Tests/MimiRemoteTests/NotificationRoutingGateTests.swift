import XCTest
@testable import MimiRemote

/// 通知闸门与前台恢复标记的纯逻辑回归。
///
/// 这里覆盖的是 #417 F1 的根因：恢复失败曾经让闸门永远关闭，通知永远留在收件箱。
final class NotificationRoutingGateTests: XCTestCase {
    func testGateOpensAfterFailedCredentialRestore() {
        var tracker = ForegroundResumeTracker()
        let generation = tracker.begin()
        XCTAssertTrue(tracker.isInFlight)
        XCTAssertTrue(tracker.finish(generation: generation, outcome: .credentialsUnavailable))

        XCTAssertFalse(tracker.isInFlight, "失败也必须清掉进行中标记")
        XCTAssertTrue(
            NotificationRoutingGate.isReady(
                bootstrapped: true,
                sceneActive: true,
                foregroundResumeInFlight: tracker.isInFlight
            ),
            "凭据恢复失败后闸门仍要打开，由路由自己提示并保留通知"
        )
        XCTAssertEqual(tracker.lastOutcome, .credentialsUnavailable)
        XCTAssertTrue(tracker.lastOutcome?.blocksNotificationRouting == true)
    }

    func testGateOpensAfterFailedTailcatRecovery() {
        var tracker = ForegroundResumeTracker()
        let generation = tracker.begin()
        tracker.finish(generation: generation, outcome: .tailcatUnavailable)

        let gate = NotificationRoutingGate(
            bootstrapped: true,
            sceneActive: true,
            foregroundResumeInFlight: tracker.isInFlight
        )
        XCTAssertTrue(gate.isReady)
        XCTAssertNil(gate.closedReason)
        XCTAssertEqual(tracker.lastOutcome, .tailcatUnavailable)
        XCTAssertTrue(tracker.lastOutcome?.blocksNotificationRouting == true)
    }

    func testGateStaysClosedWhileResumeInFlight() {
        var tracker = ForegroundResumeTracker()
        _ = tracker.begin()

        let gate = NotificationRoutingGate(
            bootstrapped: true,
            sceneActive: true,
            foregroundResumeInFlight: tracker.isInFlight
        )
        XCTAssertFalse(gate.isReady)
        XCTAssertEqual(gate.closedReason, .resumeInFlight)
        XCTAssertEqual(gate.closedReason?.rawValue, "resume_in_flight")
    }

    func testClosedReasonFollowsLifecyclePriority() {
        XCTAssertEqual(
            NotificationRoutingGate(bootstrapped: false, sceneActive: false, foregroundResumeInFlight: true).closedReason,
            .bootstrapping
        )
        XCTAssertEqual(
            NotificationRoutingGate(bootstrapped: true, sceneActive: false, foregroundResumeInFlight: true).closedReason,
            .inactive
        )
        XCTAssertEqual(
            NotificationRoutingGate(bootstrapped: true, sceneActive: true, foregroundResumeInFlight: true).closedReason,
            .resumeInFlight
        )
        XCTAssertFalse(NotificationRoutingGate.isReady(bootstrapped: true, sceneActive: false, foregroundResumeInFlight: false))
        XCTAssertFalse(NotificationRoutingGate.isReady(bootstrapped: false, sceneActive: true, foregroundResumeInFlight: false))
    }

    /// 场景快速抖动：旧任务被取消后 defer 晚于新任务的 begin 才执行，不能把新任务的标记清掉。
    func testStaleGenerationCannotClearNewerInFlightMarker() {
        var tracker = ForegroundResumeTracker()
        let stale = tracker.begin()
        let current = tracker.begin()
        XCTAssertNotEqual(stale, current)

        XCTAssertFalse(tracker.finish(generation: stale, outcome: .cancelled))
        XCTAssertTrue(tracker.isInFlight, "旧任务的 defer 不能打开闸门")
        XCTAssertNil(tracker.lastOutcome, "旧任务的结果不能覆盖记录")
        XCTAssertFalse(
            NotificationRoutingGate.isReady(
                bootstrapped: true,
                sceneActive: true,
                foregroundResumeInFlight: tracker.isInFlight
            )
        )

        XCTAssertTrue(tracker.finish(generation: current, outcome: .completed))
        XCTAssertFalse(tracker.isInFlight)
        XCTAssertEqual(tracker.lastOutcome, .completed)
        XCTAssertFalse(tracker.finish(generation: current, outcome: .failed("twice")), "同一代次不能结束两次")
        XCTAssertEqual(tracker.lastOutcome, .completed)
    }

    func testOnlyRealFailuresBlockNotificationRouting() {
        XCTAssertFalse(ForegroundResumeOutcome.completed.blocksNotificationRouting)
        XCTAssertFalse(ForegroundResumeOutcome.cancelled.blocksNotificationRouting, "取消意味着更新的恢复在接管，不是失败")
        XCTAssertTrue(ForegroundResumeOutcome.credentialsUnavailable.blocksNotificationRouting)
        XCTAssertTrue(ForegroundResumeOutcome.tailcatUnavailable.blocksNotificationRouting)
        XCTAssertTrue(ForegroundResumeOutcome.failed("URLError").blocksNotificationRouting)
        XCTAssertEqual(ForegroundResumeOutcome.credentialsUnavailable.diagnosticReason, "credentials_unavailable")
        XCTAssertEqual(ForegroundResumeOutcome.tailcatUnavailable.diagnosticReason, "tailcat_unavailable")
    }

    func testResumeFailureIsScopedToTheProfileItHappenedOn() {
        var tracker = ForegroundResumeTracker()
        let generation = tracker.begin()
        XCTAssertTrue(tracker.finish(generation: generation, outcome: .credentialsUnavailable, profileID: "mac-a"))
        XCTAssertEqual(tracker.outcome(forActiveProfileID: "mac-a"), .credentialsUnavailable)
        // 用户切到另一台 Mac 后，旧失败不能再拦截新 Mac 的通知。
        XCTAssertNil(tracker.outcome(forActiveProfileID: "mac-b"))
        XCTAssertNil(tracker.outcome(forActiveProfileID: nil))
    }
}
