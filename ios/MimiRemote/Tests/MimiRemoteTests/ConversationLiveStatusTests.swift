import XCTest
@testable import MimiRemote

final class ConversationLiveStatusTests: XCTestCase {
    // MARK: - 本轮输出 token 计数

    /// Codex 的 total 按整个会话累计：本轮只累加每次响应的 last，
    /// 限额刷新重发的同一份用量（total 不变）不能重复计入。
    func testCodexThreadCumulativeUsageCountsOnlyThisTurn() {
        var counter = TurnOutputTokenCounter.applying(sample(total: 900, last: 300), turnID: "turn-1", to: nil)
        counter = TurnOutputTokenCounter.started(turnID: "turn-2", previous: counter)
        counter = TurnOutputTokenCounter.applying(sample(total: 900, last: 300), turnID: "turn-2", to: counter)
        XCTAssertNil(counter.displayOutputTokens(activeTurnID: "turn-2"), "新一轮开头重发的上一轮用量不算本轮产出")

        counter = TurnOutputTokenCounter.applying(sample(total: 1_300, last: 400), turnID: "turn-2", to: counter)
        counter = TurnOutputTokenCounter.applying(sample(total: 1_300, last: 400), turnID: "turn-2", to: counter)
        counter = TurnOutputTokenCounter.applying(sample(total: 2_000, last: 700), turnID: "turn-2", to: counter)
        XCTAssertEqual(counter.displayOutputTokens(activeTurnID: "turn-2"), 1_100)
    }

    /// Claude bridge 的 total 每轮从零累计，turn 完成时再发一次同样的 total。
    func testClaudeTurnCumulativeUsageResetsEachTurn() {
        var counter = TurnOutputTokenCounter.started(turnID: "turn-1", previous: nil)
        counter = TurnOutputTokenCounter.applying(sample(total: 1_200, last: 1_200), turnID: "turn-1", to: counter)
        counter = TurnOutputTokenCounter.applying(sample(total: 1_200, last: 1_200), turnID: "turn-1", to: counter)
        XCTAssertEqual(counter.displayOutputTokens(activeTurnID: "turn-1"), 1_200)

        counter = TurnOutputTokenCounter.started(turnID: "turn-2", previous: counter)
        counter = TurnOutputTokenCounter.applying(sample(total: 500, last: 500), turnID: "turn-2", to: counter)
        counter = TurnOutputTokenCounter.applying(sample(total: 800, last: 300), turnID: "turn-2", to: counter)
        XCTAssertEqual(counter.displayOutputTokens(activeTurnID: "turn-2"), 800)
    }

    func testReplayedTurnStartAndLateSamplesDoNotCorruptCount() {
        var counter = TurnOutputTokenCounter.started(turnID: "turn-2", previous: nil)
        counter = TurnOutputTokenCounter.applying(sample(total: 400, last: 400), turnID: "turn-2", to: counter)
        counter = TurnOutputTokenCounter.started(turnID: "turn-2", previous: counter)
        XCTAssertEqual(counter.displayOutputTokens(activeTurnID: "turn-2"), 400, "重放同一 turn 的 started 不能清零")

        counter = TurnOutputTokenCounter.applying(sample(total: 99, last: 99), turnID: "turn-1", to: counter)
        XCTAssertEqual(counter.displayOutputTokens(activeTurnID: "turn-2"), 400, "迟到的上一轮用量不计入本轮")
        counter = TurnOutputTokenCounter.applying(sample(total: 400, last: 400), turnID: "turn-2", to: counter)
        XCTAssertEqual(counter.displayOutputTokens(activeTurnID: "turn-2"), 400, "旧轮事件之后重放当前用量不能再次计数")
        counter = TurnOutputTokenCounter.applying(sample(total: 700, last: 300), turnID: "turn-2", to: counter)
        XCTAssertEqual(counter.displayOutputTokens(activeTurnID: "turn-2"), 700)
    }

    func testCountIsHiddenWithoutObservedTurnStartOrForAnotherTurn() {
        let joinedMidTurn = TurnOutputTokenCounter.applying(sample(total: 5_000, last: 200), turnID: "turn-9", to: nil)
        XCTAssertNil(joinedMidTurn.displayOutputTokens(activeTurnID: "turn-9"), "中途进入时累加值偏小，不展示")

        var counter = TurnOutputTokenCounter.started(turnID: "turn-1", previous: nil)
        counter = TurnOutputTokenCounter.applying(sample(total: 100, last: 100), turnID: "turn-1", to: counter)
        XCTAssertNil(counter.displayOutputTokens(activeTurnID: "turn-2"))
    }

    func testLegacyUsageWithoutLastFallsBackToTotalDelta() {
        var counter = TurnOutputTokenCounter.started(turnID: "turn-1", previous: nil)
        counter = TurnOutputTokenCounter.applying(sample(total: 100, last: nil), turnID: "turn-1", to: counter)
        counter = TurnOutputTokenCounter.applying(sample(total: 50, last: nil), turnID: "turn-old", to: counter)
        counter = TurnOutputTokenCounter.applying(sample(total: 350, last: nil), turnID: "turn-1", to: counter)
        XCTAssertEqual(counter.displayOutputTokens(activeTurnID: "turn-1"), 250)
    }

    func testProjectorCarriesNumericTokenUsage() {
        var projector = CodexAppServerEventProjector()
        let usage = CodexAppServerNotification(method: "thread/tokenUsage/updated", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"),
            "tokenUsage": .object([
                "total": .object(["inputTokens": .int(100), "outputTokens": .int(50), "totalTokens": .int(150)]),
                "last": .object(["inputTokens": .int(60), "outputTokens": .int(20), "totalTokens": .int(80)])
            ])
        ]))
        guard case .sessionContext(let context, let metadata) = projector.project(usage) else {
            return XCTFail("expected token context")
        }
        XCTAssertEqual(metadata.turnID, "turn-1")
        XCTAssertEqual(context.tokenUsage?.total.outputTokens, 50)
        XCTAssertEqual(context.tokenUsage?.last?.outputTokens, 20)
    }

    // MARK: - 阶段与文案

    func testNoStatusWhenSessionIsNotRunning() {
        XCTAssertNil(makeStatus(session: session(status: "idle"), messages: []))
    }

    func testPhaseFollowsLatestInProgressActivityOfCurrentTurn() {
        let messages = [
            message(role: .user, content: "修一下"),
            activity(.runCommand, status: "completed"),
            activity(.editFile, status: "inProgress"),
            activity(.runCommand, status: "completed")
        ]
        XCTAssertEqual(makeStatus(messages: messages)?.phase, .editingFiles)

        let exploring = [
            message(role: .user, content: "看看"),
            activity(.runCommand, status: "inProgress", commandKind: .exploration)
        ]
        XCTAssertEqual(makeStatus(messages: exploring)?.phase, .exploring)
    }

    func testPhaseIgnoresPreviousTurnsAndDefaultsToThinking() {
        let messages = [
            activity(.toolCall, status: "inProgress"),
            message(role: .user, content: "下一轮")
        ]
        XCTAssertEqual(makeStatus(messages: messages)?.phase, .thinking)
    }

    func testUserWaitingStatesAndReplyingTakePriority() {
        let busy = [message(role: .user, content: "x"), activity(.runCommand, status: "inProgress")]
        XCTAssertEqual(makeStatus(session: session(status: "waiting_for_approval"), messages: busy)?.phase, .waitingForApproval)
        XCTAssertEqual(makeStatus(session: session(status: "waiting_for_input"), messages: busy)?.phase, .waitingForInput)
        XCTAssertEqual(makeStatus(messages: busy, foregroundActivity: .receivingAssistant)?.phase, .replying)
    }

    func testTextJoinsDurationTokensAndPhase() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(315)
        var counter = TurnOutputTokenCounter.started(turnID: "turn-1", previous: nil)
        counter = TurnOutputTokenCounter.applying(sample(total: 3_150, last: 3_150), turnID: "turn-1", to: counter)
        let status = try XCTUnwrap(makeStatus(
            messages: [message(role: .user, content: "x"), activity(.toolCall, status: "inProgress")],
            runtimeActivity: RuntimeActivitySnapshot(turnStartedAt: start, lastActivityAt: now),
            tokenCounter: counter
        ))
        XCTAssertEqual(
            status.text(at: now),
            ["5m 15s", L10n.format("ui.live_status_tokens_value", "3.1k"), L10n.text("ui.live_status_calling_tools")]
                .joined(separator: " · ")
        )
        XCTAssertFalse(status.isWarning(at: now))
    }

    func testStaleAndDisconnectedStatesWarn() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = RuntimeActivitySnapshot(turnStartedAt: start, lastActivityAt: start)
        let stale = try XCTUnwrap(makeStatus(messages: [], runtimeActivity: snapshot))
        let later = start.addingTimeInterval(125)
        XCTAssertTrue(stale.isWarning(at: later))
        XCTAssertTrue(stale.text(at: later).hasSuffix(L10n.format("ui.live_status_no_new_events_value", "2m 5s")))
        XCTAssertTrue(stale.animates)

        let waiting = try XCTUnwrap(makeStatus(session: session(status: "waiting_for_approval"), messages: [], runtimeActivity: snapshot))
        XCTAssertFalse(waiting.isWarning(at: later), "等用户审批时长时间无事件是正常的")

        let offline = try XCTUnwrap(makeStatus(messages: [], runtimeActivity: snapshot, readiness: .reconnecting))
        XCTAssertTrue(offline.isWarning(at: start))
        XCTAssertFalse(offline.animates)
        XCTAssertTrue(offline.text(at: start).hasSuffix(L10n.text("ui.live_status_reconnecting")))
    }

    func testPreparationStagesDoNotReuseOldTurnStatisticsOrWarn() throws {
        let old = Date(timeIntervalSince1970: 1)
        let now = old.addingTimeInterval(600)
        for readiness in [ConversationReadiness.sending, .loadingHistory, .connecting] {
            let status = try XCTUnwrap(makeStatus(
                session: session(status: readiness == .sending ? "history" : "running"),
                messages: [],
                runtimeActivity: RuntimeActivitySnapshot(turnStartedAt: old, lastActivityAt: old),
                readiness: readiness
            ))
            XCTAssertEqual(status.text(at: now), readiness.title)
            XCTAssertFalse(status.isWarning(at: now))
            XCTAssertTrue(status.animates)
        }
        for readiness in [ConversationReadiness.disconnected, .failed, .unavailable(.credentialsInvalid)] {
            let status = try XCTUnwrap(makeStatus(messages: [], readiness: readiness))
            XCTAssertEqual(status.text(at: now), readiness.title)
            XCTAssertTrue(status.isWarning(at: now))
            XCTAssertFalse(status.animates)
        }
        let observing = try XCTUnwrap(makeStatus(messages: [], readiness: .observing))
        XCTAssertFalse(observing.isWarning(at: now))
        XCTAssertFalse(observing.animates)
    }

    func testColdOpenPrefersEarlierUserMessageOfCurrentTurn() throws {
        let userSentAt = Date(timeIntervalSince1970: 500)
        let fallbackSnapshot = RuntimeActivitySnapshot(
            turnStartedAt: Date(timeIntervalSince1970: 800),
            lastActivityAt: Date(timeIntervalSince1970: 800)
        )
        let status = try XCTUnwrap(makeStatus(
            messages: [message(role: .user, content: "x", createdAt: userSentAt)],
            runtimeActivity: fallbackSnapshot
        ))
        XCTAssertEqual(status.startedAt, userSentAt)

        let previousTurn = try XCTUnwrap(makeStatus(
            messages: [message(role: .user, content: "x", turnID: "turn-0", createdAt: userSentAt)],
            runtimeActivity: fallbackSnapshot
        ))
        XCTAssertEqual(previousTurn.startedAt, fallbackSnapshot.turnStartedAt, "上一轮的用户消息不能当作本轮开始")
    }

    func testCompactTokenCount() {
        XCTAssertEqual(ConversationLiveStatus.compactTokenCount(999), "999")
        XCTAssertEqual(ConversationLiveStatus.compactTokenCount(1_000), "1k")
        XCTAssertEqual(ConversationLiveStatus.compactTokenCount(3_150), "3.1k")
        XCTAssertEqual(ConversationLiveStatus.compactTokenCount(2_400_000), "2.4M")
    }

    func testGlyphHoldsStaticFrameWhenNotAnimating() {
        let first = ConversationLiveStatusGlyph.rayLengthFraction(index: 0, time: 10, animates: false)
        let later = ConversationLiveStatusGlyph.rayLengthFraction(index: 0, time: 12.3, animates: false)
        XCTAssertEqual(first, later)
        XCTAssertEqual(
            ConversationLiveStatusGlyph.rotationAngle(time: 3, animates: false),
            ConversationLiveStatusGlyph.rotationAngle(time: 7, animates: false)
        )
        let animated = (0..<ConversationLiveStatusGlyph.rayCount).map {
            ConversationLiveStatusGlyph.rayLengthFraction(index: $0, time: 10, animates: true)
        }
        XCTAssertTrue(animated.allSatisfy { (0.35...1).contains($0) })
    }

    // MARK: - Fixtures

    private func sample(total: Int, last: Int?) -> AppServerTokenUsageSample {
        AppServerTokenUsageSample(
            total: .init(inputTokens: nil, outputTokens: total, totalTokens: nil),
            last: last.map { .init(inputTokens: nil, outputTokens: $0, totalTokens: nil) }
        )
    }

    private func session(status: String = "running", activeTurnID: TurnID? = "turn-1") -> AgentSession {
        AgentSession(
            id: "thread-1",
            projectID: "project-1",
            project: "Project",
            dir: "/workspace",
            title: "Live",
            status: status,
            source: "codex",
            resumeID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            activeTurnID: activeTurnID
        )
    }

    private func message(
        role: ConversationMessage.Role,
        content: String,
        turnID: TurnID? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 100)
    ) -> ConversationMessage {
        ConversationMessage(turnID: turnID, role: role, content: content, createdAt: createdAt)
    }

    private func activity(
        _ category: ConversationActivityCategory,
        status: String,
        commandKind: ConversationCommandPresentationKind? = nil
    ) -> ConversationMessage {
        ConversationMessage(
            turnID: "turn-1",
            role: .system,
            kind: category == .editFile ? .fileChangeSummary : .commandSummary,
            content: "",
            activityPayload: ConversationActivityPayload(
                category: category,
                displayTitle: "activity",
                status: status,
                commandPresentationKind: commandKind
            )
        )
    }

    private func makeStatus(
        session: AgentSession? = nil,
        messages: [ConversationMessage],
        foregroundActivity: SessionForegroundActivity? = nil,
        runtimeActivity: RuntimeActivitySnapshot? = nil,
        tokenCounter: TurnOutputTokenCounter? = nil,
        readiness: ConversationReadiness = .live
    ) -> ConversationLiveStatus? {
        ConversationLiveStatus.make(
            session: session ?? self.session(),
            messages: messages,
            foregroundActivity: foregroundActivity,
            runtimeActivity: runtimeActivity,
            tokenCounter: tokenCounter,
            readiness: readiness
        )
    }
}
