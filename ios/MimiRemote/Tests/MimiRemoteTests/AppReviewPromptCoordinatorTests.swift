import Combine
import XCTest
@testable import MimiRemote

/// 评分邀请（#842）：评分请求换成计数闭包，测试里不会真正弹出系统评分框。
@MainActor
final class AppReviewPromptCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var currentDate = Date(timeIntervalSince1970: 1_790_000_000)
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private var requestCount = 0
    private var isTyping = false

    override func setUp() {
        super.setUp()
        suiteName = "AppReviewPromptCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        requestCount = 0
        isTyping = false
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeCoordinator(version: String = "1.0") -> AppReviewPromptCoordinator {
        let coordinator = AppReviewPromptCoordinator(
            defaults: defaults,
            appVersion: version,
            calendar: calendar,
            now: { [unowned self] in self.currentDate }
        )
        coordinator.requestReview = { [unowned self] in self.requestCount += 1 }
        coordinator.isUserTyping = { [unowned self] in self.isTyping }
        return coordinator
    }

    private func advanceDays(_ days: Int) {
        currentDate = currentDate.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// 用户在 App 里发出一个回合，随后它以给定终态结束。
    private func completeSubmittedTurn(
        _ coordinator: AppReviewPromptCoordinator,
        sessionID: SessionID = "thread-a",
        lifecycle: ConversationTurnLifecycle = .completed,
        isSessionVisible: Bool = true
    ) {
        coordinator.recordTurnSubmitted(sessionID: sessionID)
        coordinator.recordTurnFinished(
            sessionID: sessionID,
            turnID: nil,
            lifecycle: lifecycle,
            isSessionVisible: isSessionVisible
        )
    }

    private func completeApprovedTurn(
        _ coordinator: AppReviewPromptCoordinator,
        sessionID: SessionID = "thread-a",
        turnID: String = "turn-1",
        lifecycle: ConversationTurnLifecycle = .completed,
        isSessionVisible: Bool = true
    ) {
        coordinator.recordApprovalAccepted(sessionID: sessionID, turnID: turnID)
        coordinator.recordTurnFinished(
            sessionID: sessionID,
            turnID: turnID,
            lifecycle: lifecycle,
            isSessionVisible: isSessionVisible
        )
    }

    // MARK: - 触发

    func testApprovedTurnCompletingNormallyRequestsReviewOncePerVersion() {
        let coordinator = makeCoordinator()

        completeApprovedTurn(coordinator)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(coordinator.state.requestedVersion, "1.0")

        advanceDays(1)
        completeApprovedTurn(coordinator, turnID: "turn-2")
        for _ in 0..<10 {
            advanceDays(1)
            completeSubmittedTurn(coordinator)
        }
        XCTAssertEqual(requestCount, 1, "同一版本只请求一次")
    }

    func testTurnsAcrossThreeDaysRequestReviewWhenThresholdIsReached() {
        let coordinator = makeCoordinator()

        completeSubmittedTurn(coordinator)
        completeSubmittedTurn(coordinator)
        advanceDays(1)
        completeSubmittedTurn(coordinator)
        completeSubmittedTurn(coordinator)
        XCTAssertEqual(requestCount, 0, "两天还不够")

        advanceDays(1)
        completeSubmittedTurn(coordinator)
        XCTAssertEqual(requestCount, 1, "第三天第 5 个回合达标")
        XCTAssertEqual(coordinator.state.completedTurnCount, 0, "请求后清零，下个版本重新累计")
        XCTAssertTrue(coordinator.state.completedTurnDays.isEmpty)
    }

    func testUsageCountersPersistAcrossLaunches() {
        completeSubmittedTurn(makeCoordinator())
        completeSubmittedTurn(makeCoordinator())
        advanceDays(1)
        completeSubmittedTurn(makeCoordinator())
        completeSubmittedTurn(makeCoordinator())
        advanceDays(1)
        XCTAssertEqual(requestCount, 0)

        completeSubmittedTurn(makeCoordinator())
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(makeCoordinator().state.requestedVersion, "1.0")
    }

    func testNewAppVersionCanRequestAgain() {
        completeApprovedTurn(makeCoordinator(version: "1.0"))
        advanceDays(1)
        completeApprovedTurn(makeCoordinator(version: "1.0"))
        XCTAssertEqual(requestCount, 1)

        completeApprovedTurn(makeCoordinator(version: "1.1"))
        XCTAssertEqual(requestCount, 2)
    }

    func testNewSessionMovedFromOptimisticIDStillCounts() {
        let coordinator = makeCoordinator()
        coordinator.recordTurnSubmitted(sessionID: "local-draft")
        coordinator.moveSubmittedSession(from: "local-draft", to: "thread-real")
        coordinator.recordTurnFinished(
            sessionID: "thread-real",
            turnID: "turn-1",
            lifecycle: .completed,
            isSessionVisible: true
        )

        XCTAssertEqual(coordinator.state.completedTurnCount, 1)
    }

    func testMissedMomentDoesNotConsumeVersionAndNextMomentRequests() {
        let coordinator = makeCoordinator()
        isTyping = true
        completeApprovedTurn(coordinator)
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(coordinator.state.requestedVersion)

        isTyping = false
        completeApprovedTurn(coordinator, turnID: "turn-2")
        XCTAssertEqual(requestCount, 1)
    }

    // MARK: - 不触发

    func testTurnsOnFewerThanThreeDaysNeverRequest() {
        let coordinator = makeCoordinator()
        for _ in 0..<10 {
            completeSubmittedTurn(coordinator)
        }
        advanceDays(1)
        for _ in 0..<10 {
            completeSubmittedTurn(coordinator)
        }

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(coordinator.state.completedTurnDays.count, 2)
    }

    func testFewerThanFiveTurnsAcrossThreeDaysDoesNotRequest() {
        let coordinator = makeCoordinator()
        completeSubmittedTurn(coordinator)
        advanceDays(1)
        completeSubmittedTurn(coordinator)
        advanceDays(1)
        completeSubmittedTurn(coordinator)
        advanceDays(1)
        completeSubmittedTurn(coordinator)

        XCTAssertEqual(requestCount, 0)
    }

    func testPairingDayBlocksRequestUntilNextDay() {
        let coordinator = makeCoordinator()
        coordinator.recordPairingCompleted()
        completeApprovedTurn(coordinator)
        XCTAssertEqual(requestCount, 0, "首次配对当天不邀请")

        advanceDays(1)
        completeApprovedTurn(coordinator, turnID: "turn-2")
        XCTAssertEqual(requestCount, 1)
    }

    func testConnectionFailureBlocksRequestForTheRestOfTheDay() {
        let coordinator = makeCoordinator()
        coordinator.recordSetback()
        completeApprovedTurn(coordinator)
        XCTAssertEqual(requestCount, 0)

        advanceDays(1)
        completeApprovedTurn(coordinator, turnID: "turn-2")
        XCTAssertEqual(requestCount, 1)
    }

    func testFailedOrInterruptedTurnNeverRequestsAndBlocksTheDay() {
        let coordinator = makeCoordinator()
        completeApprovedTurn(coordinator, turnID: "turn-failed", lifecycle: .failed)
        XCTAssertEqual(requestCount, 0)
        completeApprovedTurn(coordinator, turnID: "turn-ok")
        XCTAssertEqual(requestCount, 0, "回合失败的当天不邀请")

        advanceDays(1)
        completeApprovedTurn(coordinator, turnID: "turn-interrupted", lifecycle: .interrupted)
        completeApprovedTurn(coordinator, turnID: "turn-ok-2")
        XCTAssertEqual(requestCount, 0, "回合中断的当天不邀请")
        XCTAssertEqual(coordinator.state.completedTurnCount, 2, "失败和中断不计入")
    }

    func testTypingBlocksRequest() {
        let coordinator = makeCoordinator()
        isTyping = true
        completeApprovedTurn(coordinator)

        XCTAssertEqual(requestCount, 0)
    }

    func testHiddenSessionCountsUsageButDoesNotRequest() {
        let coordinator = makeCoordinator()
        completeApprovedTurn(coordinator, isSessionVisible: false)

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(coordinator.state.completedTurnCount, 1)
        XCTAssertNil(coordinator.state.requestedVersion)
    }

    func testTurnsNotStartedOrApprovedInAppAreIgnored() {
        let coordinator = makeCoordinator()
        for day in 0..<5 {
            if day > 0 { advanceDays(1) }
            coordinator.recordTurnFinished(
                sessionID: "thread-from-computer",
                turnID: "turn-\(day)",
                lifecycle: .completed,
                isSessionVisible: true
            )
        }

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(coordinator.state.completedTurnCount, 0)
    }

    func testDiscardedSubmissionDoesNotCountTheNextCompletion() {
        let coordinator = makeCoordinator()
        coordinator.recordTurnSubmitted(sessionID: "thread-a")
        coordinator.discardTurnSubmitted(sessionID: "thread-a")
        coordinator.recordTurnFinished(
            sessionID: "thread-a",
            turnID: "turn-from-computer",
            lifecycle: .completed,
            isSessionVisible: true
        )

        XCTAssertEqual(coordinator.state.completedTurnCount, 0)
    }

    func testApprovalForAnotherTurnDoesNotCountAsApprovedCompletion() {
        let coordinator = makeCoordinator()
        coordinator.recordApprovalAccepted(sessionID: "thread-a", turnID: "turn-1")
        coordinator.recordTurnFinished(
            sessionID: "thread-a",
            turnID: "turn-other",
            lifecycle: .completed,
            isSessionVisible: true
        )

        XCTAssertEqual(requestCount, 0)
    }

    func testNoRequestBeforeReviewActionIsInstalled() {
        let coordinator = makeCoordinator()
        coordinator.requestReview = nil
        completeApprovedTurn(coordinator)
        XCTAssertNil(coordinator.state.requestedVersion, "界面还没装入评分动作时不消耗本版本机会")

        coordinator.requestReview = { [unowned self] in self.requestCount += 1 }
        completeApprovedTurn(coordinator, turnID: "turn-2")
        XCTAssertEqual(requestCount, 1)
    }

    func testObservedConnectionFailureBlocksRequest() {
        let coordinator = makeCoordinator()
        let failures = PassthroughSubject<Bool, Never>()
        coordinator.observeConnectionFailures(failures)

        failures.send(false)
        XCTAssertNil(coordinator.state.lastSetbackDay)
        failures.send(true)
        XCTAssertNotNil(coordinator.state.lastSetbackDay)

        completeApprovedTurn(coordinator)
        XCTAssertEqual(requestCount, 0)
    }

    // MARK: - SessionStore 接入

    func testSessionStoreRuntimeCompletionDrivesReviewRequest() async {
        let threadID = "thr_review_prompt"
        let project = makeProject(id: "proj_review_prompt")
        let running = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Review Prompt",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn-approved"
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running]) }
        )
        store.sessions = [running]
        store.selectedSessionID = threadID
        store.turnCompletionReconciliationDelaysNanoseconds = []
        let coordinator = makeCoordinator()
        store.appReviewPrompt = coordinator
        let lease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: threadID)

        store.noteAppReviewApprovalAccepted(session: running)
        await store.applyRuntimeEvent(
            .turnCompleted(AgentEventMetadata(
                seq: 10, sessionID: threadID, turnID: "turn-approved",
                itemID: nil, messageID: nil, clientMessageID: nil, revision: nil, createdAt: nil,
                turnLifecycle: .completed
            )),
            lease: lease,
            sendsNotification: false
        )

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(coordinator.state.completedTurnCount, 0, "请求后清零")
    }

    func testSessionStoreFailedCompletionAndComposerDraftBlockReview() async {
        let threadID = "thr_review_blocked"
        let project = makeProject(id: "proj_review_blocked")
        let running = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Review Blocked",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn-failed"
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running]) }
        )
        store.sessions = [running]
        store.selectedSessionID = threadID
        store.turnCompletionReconciliationDelaysNanoseconds = []
        let coordinator = makeCoordinator()
        store.appReviewPrompt = coordinator
        let lease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: threadID)

        store.setSessionListProjection(
            sessionID: threadID, preview: "修一下测试", source: .localUser, clientMessageID: "client-1"
        )
        store.noteAppReviewApprovalAccepted(session: running)
        await store.applyRuntimeEvent(
            .turnCompleted(AgentEventMetadata(
                seq: 10, sessionID: threadID, turnID: "turn-failed",
                itemID: nil, messageID: nil, clientMessageID: nil, revision: nil, createdAt: nil,
                turnLifecycle: .failed
            )),
            lease: lease,
            sendsNotification: false
        )
        XCTAssertEqual(requestCount, 0)
        XCTAssertNotNil(coordinator.state.lastSetbackDay)
        XCTAssertEqual(coordinator.state.completedTurnCount, 0)

        XCTAssertFalse(store.hasAppReviewBlockingComposerDraft)
        store.saveComposerDraft(
            ComposerDraftSnapshot(text: "下一条", attachments: [], voiceDraftNeedsReview: false),
            for: .session(threadID)
        )
        XCTAssertTrue(store.hasAppReviewBlockingComposerDraft, "当前会话有未发送草稿视为正在输入")
    }
    func testSessionStoreCountsOnlyDispatchedSubmissions() async {
        let threadID = "thr_review_dispatch"
        let project = makeProject(id: "proj_review_dispatch")
        let running = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Review Dispatch",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: "turn-running"
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running]) }
        )
        store.sessions = [running]
        store.selectedSessionID = threadID
        store.turnCompletionReconciliationDelaysNanoseconds = []
        let coordinator = makeCoordinator()
        store.appReviewPrompt = coordinator
        let lease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: threadID)
        func complete(_ turnID: String, seq: EventSequence) async {
            await store.applyRuntimeEvent(
                .turnCompleted(AgentEventMetadata(
                    seq: seq, sessionID: threadID, turnID: turnID,
                    itemID: nil, messageID: nil, clientMessageID: nil, revision: nil, createdAt: nil,
                    turnLifecycle: .completed
                )),
                lease: lease,
                sendsNotification: false
            )
        }

        // 重试的消息排在运行中的回合后面：完成的是原来那一轮，不算 App 发起。
        store.setSessionListProjection(
            sessionID: threadID, preview: "重试", source: .localUser, clientMessageID: "client-queued",
            isDispatching: false
        )
        await complete("turn-running", seq: 10)
        XCTAssertEqual(coordinator.state.completedTurnCount, 0)

        // 发送失败回滚后，下一次完成同样不算。
        store.setSessionListProjection(
            sessionID: threadID, preview: "发不出去", source: .localUser, clientMessageID: "client-failed"
        )
        store.clearSessionListProjection(sessionID: threadID, clientMessageID: "client-failed")
        await complete("turn-from-computer", seq: 11)
        XCTAssertEqual(coordinator.state.completedTurnCount, 0)

        // 真正派发的消息照常计数。
        store.setSessionListProjection(
            sessionID: threadID, preview: "发出去了", source: .localUser, clientMessageID: "client-sent"
        )
        await complete("turn-sent", seq: 12)
        XCTAssertEqual(coordinator.state.completedTurnCount, 1)
    }
}
