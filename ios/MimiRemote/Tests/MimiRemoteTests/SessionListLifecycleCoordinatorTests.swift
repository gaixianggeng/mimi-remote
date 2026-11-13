import XCTest
@testable import MimiRemote

@MainActor
final class SessionListLifecycleCoordinatorTests: XCTestCase {
    func testLifecyclePhaseUsesExplicitStatusesAndForegroundEvidence() {
        let cases: [(String, SessionForegroundActivity?, SessionLifecyclePhase)] = [
            (SessionStatus.running.rawValue, nil, .waiting),
            (SessionStatus.waitingForApproval.rawValue, nil, .waiting),
            (SessionStatus.waitingForInput.rawValue, nil, .waiting),
            (SessionStatus.completed.rawValue, .receivingAssistant, .completion),
            (SessionStatus.closed.rawValue, nil, .completion),
            (SessionStatus.failed.rawValue, .receivingAssistant, .failure),
            (SessionStatus.history.rawValue, nil, .completion),
            (SessionStatus.idle.rawValue, nil, .completion),
            (SessionStatus.history.rawValue, .waitingForAssistant, .waiting),
            (SessionStatus.idle.rawValue, .receivingAssistant, .waiting),
            (SessionStatus.history.rawValue, .refreshing, .neutral),
            (SessionStatus.unknown.rawValue, nil, .neutral),
            ("draft", nil, .neutral),
            ("future_status", .waitingForAssistant, .waiting),
            ("future_status", .refreshing, .neutral),
        ]

        for (status, activity, expected) in cases {
            let observation = SessionLifecycleObservation(
                session: makeSession(id: "\(status)-\(String(describing: activity))", status: status),
                foregroundActivity: activity
            )
            XCTAssertEqual(observation.phase, expected, "status=\(status), activity=\(String(describing: activity))")
        }
    }

    func testInitialTerminalSessionsOnlyEstablishBaseline() {
        var tracker = SessionLifecycleFeedbackTracker()

        XCTAssertNil(tracker.observe([
            observation("completed", .completion),
            observation("failed", .failure),
        ]))
        XCTAssertNil(tracker.observe([
            observation("completed", .completion),
            observation("failed", .failure),
        ]))
    }

    func testWaitingSessionCompletesOnceAndTerminalCorrectionDoesNotRepeat() {
        var tracker = SessionLifecycleFeedbackTracker()

        XCTAssertNil(tracker.observe([observation("session", .waiting)]))
        XCTAssertEqual(
            tracker.observe([observation("session", .completion)])?.pattern,
            MimiHapticPattern.notificationSuccess
        )
        XCTAssertNil(tracker.observe([observation("session", .completion)]))
        XCTAssertNil(tracker.observe([observation("session", .failure)]))
    }

    func testTransitionResultExposesOnlyArmedCompletedSessionIDs() {
        var tracker = SessionLifecycleFeedbackTracker()

        XCTAssertTrue(
            tracker.observeTransitions([
                observation("armed", .waiting),
                observation("history", .completion),
            ]).completedSessionIDs.isEmpty
        )

        let result = tracker.observeTransitions([
            observation("armed", .completion),
            observation("history", .completion),
        ])

        XCTAssertEqual(result.completedSessionIDs, ["armed"])
        XCTAssertEqual(result.feedback?.pattern, MimiHapticPattern.notificationSuccess)
        XCTAssertTrue(result.failedSessionIDs.isEmpty)
    }

    func testFailedSessionCanRearmAndCompleteAfterRecovery() {
        var tracker = SessionLifecycleFeedbackTracker()

        XCTAssertNil(tracker.observe([observation("session", .waiting)]))
        XCTAssertEqual(
            tracker.observe([observation("session", .failure)])?.pattern,
            MimiHapticPattern.notificationError
        )
        XCTAssertNil(tracker.observe([observation("session", .waiting)]))
        XCTAssertEqual(
            tracker.observe([observation("session", .completion)])?.pattern,
            MimiHapticPattern.notificationSuccess
        )
    }

    func testNeutralPhasePreservesArmingButRefreshingHistoryDoesNotArm() {
        var tracker = SessionLifecycleFeedbackTracker()

        XCTAssertNil(tracker.observe([observation("armed", .waiting)]))
        XCTAssertNil(tracker.observe([observation("armed", .neutral)]))
        XCTAssertEqual(
            tracker.observe([observation("armed", .completion)])?.pattern,
            MimiHapticPattern.notificationSuccess
        )

        XCTAssertNil(tracker.observe([observation("refresh", .neutral)]))
        XCTAssertNil(tracker.observe([observation("refresh", .completion)]))
    }

    func testBatchFailureWinsWhileEveryTerminalSessionIsDisarmed() {
        var tracker = SessionLifecycleFeedbackTracker()
        let waiting = [observation("complete", .waiting), observation("fail", .waiting)]
        XCTAssertNil(tracker.observe(waiting))

        XCTAssertEqual(
            tracker.observe([
                observation("complete", .completion),
                observation("fail", .failure),
            ])?.pattern,
            MimiHapticPattern.notificationError
        )
        XCTAssertNil(tracker.observe([
            observation("complete", .completion),
            observation("fail", .failure),
        ]))
    }

    /// #905：电脑上的 Claude 进程跑完一轮，列表实时把行改回完成；侧栏高亮照常，手机不震动。
    func testComputerHeldTurnCompletionHighlightsWithoutHaptic() {
        var tracker = SessionLifecycleFeedbackTracker()
        let idle = heldSession(id: "held", status: SessionStatus.history.rawValue, ownerStatus: "idle")
        let busy = heldSession(id: "held", status: SessionStatus.running.rawValue, ownerStatus: "busy")

        XCTAssertNil(tracker.observe([SessionLifecycleObservation(session: idle, foregroundActivity: nil)]))
        XCTAssertNil(tracker.observe([SessionLifecycleObservation(session: busy, foregroundActivity: nil)]))

        let result = tracker.observeTransitions([
            SessionLifecycleObservation(session: idle, foregroundActivity: nil),
        ])
        XCTAssertEqual(result.completedSessionIDs, ["held"])
        XCTAssertNil(result.feedback)
    }

    func testComputerHeldTurnStillHapticsWhenUserIsViewingThatSession() {
        var tracker = SessionLifecycleFeedbackTracker()
        let idle = heldSession(id: "held", status: SessionStatus.history.rawValue, ownerStatus: "idle")
        let busy = heldSession(id: "held", status: SessionStatus.running.rawValue, ownerStatus: "busy")

        XCTAssertNil(tracker.observe([SessionLifecycleObservation(session: idle, foregroundActivity: nil)]))
        // 电脑端开始执行时用户还在列表，结束前才点进详情：以终态这一刻是否在看为准。
        XCTAssertNil(tracker.observe([SessionLifecycleObservation(session: busy, foregroundActivity: nil)]))
        XCTAssertEqual(
            tracker.observe([
                SessionLifecycleObservation(session: idle, foregroundActivity: nil, isVisible: true),
            ])?.pattern,
            MimiHapticPattern.notificationSuccess
        )
    }

    func testComputerHeldTurnStaysSilentWhenUserLeavesBeforeItEnds() {
        var tracker = SessionLifecycleFeedbackTracker()

        XCTAssertNil(tracker.observe([observation("held", .completion, isHeldOnComputer: true)]))
        XCTAssertNil(tracker.observe([observation("held", .waiting, isHeldOnComputer: true, isVisible: true)]))
        let result = tracker.observeTransitions([observation("held", .completion, isHeldOnComputer: true)])

        XCTAssertEqual(result.completedSessionIDs, ["held"])
        XCTAssertNil(result.feedback)
    }

    /// `claude -p` 这类持有方会与终态同时退出：武装时见过电脑端持有，就按电脑端的一轮处理。
    func testComputerArmStaysSilentWhenHolderExitsWithTerminalState() {
        var tracker = SessionLifecycleFeedbackTracker()

        XCTAssertNil(tracker.observe([observation("held", .completion)]))
        XCTAssertNil(tracker.observe([observation("held", .waiting, isHeldOnComputer: true)]))
        XCTAssertNil(tracker.observe([observation("held", .waiting)]))
        let result = tracker.observeTransitions([observation("held", .completion)])

        XCTAssertEqual(result.completedSessionIDs, ["held"])
        XCTAssertNil(result.feedback)
    }

    func testPhoneTurnAfterComputerTurnHapticsAgain() {
        var tracker = SessionLifecycleFeedbackTracker()

        XCTAssertNil(tracker.observe([observation("session", .completion)]))
        XCTAssertNil(tracker.observe([observation("session", .waiting, isHeldOnComputer: true)]))
        XCTAssertNil(tracker.observe([observation("session", .completion, isHeldOnComputer: true)]))

        // 接管后手机自己发起的一轮不再带持有方，照常反馈一次。
        XCTAssertNil(tracker.observe([observation("session", .waiting)]))
        XCTAssertEqual(
            tracker.observe([observation("session", .completion)])?.pattern,
            MimiHapticPattern.notificationSuccess
        )
    }

    func testSilentComputerFailureDoesNotMaskPhoneCompletionInSameBatch() {
        var tracker = SessionLifecycleFeedbackTracker()
        XCTAssertNil(tracker.observe([
            observation("held", .waiting, isHeldOnComputer: true),
            observation("phone", .waiting),
        ]))

        let result = tracker.observeTransitions([
            observation("held", .failure, isHeldOnComputer: true),
            observation("phone", .completion),
        ])

        XCTAssertEqual(result.failedSessionIDs, ["held"])
        XCTAssertEqual(result.completedSessionIDs, ["phone"])
        XCTAssertEqual(result.feedback?.pattern, MimiHapticPattern.notificationSuccess)
    }

    func testComputerHeldArmOnFirstObservationStaysSilent() {
        let coordinator = SessionListLifecycleCoordinator()
        _ = coordinator.observe(input(
            membership: .empty,
            observations: [observation("held", .waiting, isHeldOnComputer: true)]
        ))

        XCTAssertNil(coordinator.observe(input(
            membership: .empty,
            observations: [observation("held", .completion, isHeldOnComputer: true)]
        )))
    }

    func testScrollingKeepsSectionMembershipUntilIdle() {
        let coordinator = SessionListLifecycleCoordinator()
        let initial = membership(active: ["active"], history: ["history"])
        _ = coordinator.observe(input(membership: initial))

        coordinator.setUserScrolling(true, latestMembership: initial)
        let regrouped = membership(active: [], history: ["active", "history"])
        _ = coordinator.observe(input(membership: regrouped))

        XCTAssertEqual(coordinator.membership, initial)
        XCTAssertEqual(coordinator.pendingMembership, regrouped)

        coordinator.setUserScrolling(false, latestMembership: regrouped)
        XCTAssertEqual(coordinator.membership, regrouped)
        XCTAssertNil(coordinator.pendingMembership)
    }

    func testScrollingRemovesMissingIDsAndDelaysNewIDsUsingOnlyLatestPendingSnapshot() {
        let coordinator = SessionListLifecycleCoordinator()
        let initial = membership(active: ["a", "b"], history: ["c"])
        _ = coordinator.observe(input(membership: initial))
        coordinator.setUserScrolling(true, latestMembership: initial)

        let firstUpdate = membership(active: ["a", "new-1"], history: ["c"])
        _ = coordinator.observe(input(membership: firstUpdate))
        XCTAssertEqual(coordinator.membership, membership(active: ["a"], history: ["c"]))

        let latestUpdate = membership(active: ["new-2"], history: ["a", "c"])
        _ = coordinator.observe(input(membership: latestUpdate))
        XCTAssertEqual(coordinator.membership, membership(active: ["a"], history: ["c"]))
        XCTAssertEqual(coordinator.pendingMembership, latestUpdate)

        coordinator.setUserScrolling(false, latestMembership: latestUpdate)
        XCTAssertEqual(coordinator.membership, latestUpdate)
    }

    func testFilterContextChangeCommitsImmediatelyWhileScrolling() {
        let coordinator = SessionListLifecycleCoordinator()
        let initial = membership(active: ["a"], history: ["b"])
        _ = coordinator.observe(input(membership: initial))
        coordinator.setUserScrolling(true, latestMembership: initial)

        let filtered = membership(active: [], history: ["b"])
        _ = coordinator.observe(input(membership: filtered, statusFilterID: "history"))

        XCTAssertEqual(coordinator.membership, filtered)
        XCTAssertNil(coordinator.pendingMembership)
    }

    func testProfileChangeResetsFeedbackBaseline() {
        let coordinator = SessionListLifecycleCoordinator()
        _ = coordinator.observe(input(
            membership: .empty,
            observations: [observation("session", .waiting)],
            profileID: "profile-a"
        ))

        let feedback = coordinator.observe(input(
            membership: .empty,
            observations: [observation("session", .completion)],
            profileID: "profile-b"
        ))
        XCTAssertNil(feedback)
    }

    func testWorkspaceChangeResetsFeedbackBaselineForSameSessionID() {
        let coordinator = SessionListLifecycleCoordinator()
        _ = coordinator.observe(input(
            membership: .empty,
            observations: [observation("session", .waiting)],
            workspaceID: "workspace-a"
        ))

        let feedback = coordinator.observe(input(
            membership: .empty,
            observations: [observation("session", .completion)],
            workspaceID: "workspace-b"
        ))
        XCTAssertNil(feedback)
    }

    func testSearchChangeCommitsImmediatelyAndClearsPendingSnapshot() {
        let coordinator = SessionListLifecycleCoordinator()
        let initial = membership(active: ["a"], history: ["b"])
        _ = coordinator.observe(input(membership: initial))
        coordinator.setUserScrolling(true, latestMembership: initial)

        let pending = membership(active: [], history: ["a", "b"])
        _ = coordinator.observe(input(membership: pending))
        XCTAssertEqual(coordinator.pendingMembership, pending)

        let searchResult = membership(active: [], history: ["b"])
        _ = coordinator.observe(input(membership: searchResult, searchQuery: "target"))
        XCTAssertEqual(coordinator.membership, searchResult)
        XCTAssertNil(coordinator.pendingMembership)
    }

    func testRecreatedCoordinatorDoesNotReplayTerminalHaptic() {
        let firstCoordinator = SessionListLifecycleCoordinator()
        _ = firstCoordinator.observe(input(
            membership: .empty,
            observations: [observation("session", .waiting)]
        ))
        XCTAssertEqual(
            firstCoordinator.observe(input(
                membership: .empty,
                observations: [observation("session", .completion)]
            ))?.pattern,
            MimiHapticPattern.notificationSuccess
        )

        let recreatedCoordinator = SessionListLifecycleCoordinator()
        XCTAssertNil(recreatedCoordinator.observe(input(
            membership: .empty,
            observations: [observation("session", .completion)]
        )))
    }

    private func observation(
        _ id: SessionID,
        _ phase: SessionLifecyclePhase,
        isHeldOnComputer: Bool = false,
        isVisible: Bool = false
    ) -> SessionLifecycleObservation {
        SessionLifecycleObservation(id: id, phase: phase, isHeldOnComputer: isHeldOnComputer, isVisible: isVisible)
    }

    private func membership(active: [SessionID], history: [SessionID]) -> SessionListMembership {
        SessionListMembership(activeIDs: active, historyIDs: history)
    }

    private func input(
        membership: SessionListMembership,
        observations: [SessionLifecycleObservation] = [],
        profileID: String = "profile-a",
        workspaceID: String = "all",
        statusFilterID: String = "all",
        searchQuery: String = ""
    ) -> SessionListLifecycleInput {
        SessionListLifecycleInput(
            membership: membership,
            feedbackObservations: observations,
            context: SessionListLifecycleContext(
                profileID: profileID,
                workspaceID: workspaceID,
                statusFilterID: statusFilterID,
                searchQuery: searchQuery
            )
        )
    }

    /// 与 applyLiveSessionIndexUpdate 合并持有方快照后的行一致：不可直接输入，并带持有方摘要。
    private func heldSession(id: SessionID, status: String, ownerStatus: String?) -> AgentSession {
        var session = makeSession(id: id, status: status)
        session.canAcceptDirectInput = false
        session.claudeOwner = ClaudeSessionOwner(
            entrypoint: "claude-desktop",
            kind: "interactive",
            status: ownerStatus,
            pid: 4242
        )
        return session
    }

    private func makeSession(id: SessionID, status: String) -> AgentSession {
        AgentSession(
            id: id,
            projectID: "project",
            project: "Project",
            dir: "/tmp/project",
            title: id,
            status: status,
            source: "codex",
            resumeID: id,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }
}
