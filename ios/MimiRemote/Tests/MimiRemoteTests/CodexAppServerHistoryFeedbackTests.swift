import Combine
import XCTest
@testable import MimiRemote

@MainActor
final class CodexAppServerHistoryFeedbackTests: XCTestCase {
    private let sessionID = "thread-history-feedback"

    func testOpeningCompletedHistoryStaysSilentAndNextLiveTurnCompletesOnce() async throws {
        let fixture = makeFixture()
        defer { fixture.store.disconnectWebSocket() }
        let recorder = FeedbackRecorder(store: fixture.store, sessionID: sessionID)
        let runtime = makeRuntime()

        await seedThread(in: runtime)
        await emitCompletedTurn("old-1", text: "第一轮历史回复", into: runtime)
        let attachment = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID)
        // 第二轮在页面已订阅、连接尚未恢复完成时才到达，覆盖恢复窗口的另一半。
        await emitCompletedTurn("old-2", text: "第二轮历史回复", into: runtime)
        await emitMessage("old-1", text: "第一轮历史回复（迟到快照）", into: runtime)
        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
        await runtime.finishAttachedEventStreams(sessionID: sessionID)

        for await event in attachment.events {
            await fixture.store.applyRuntimeEvent(event, lease: fixture.lease, sendsNotification: false)
            recorder.observeCurrentState()
        }

        XCTAssertFalse(recorder.phases.contains(.waiting), "已结束历史不能短暂恢复为运行或等待")
        XCTAssertTrue(recorder.feedback.isEmpty, "历史回合不能重新武装并触发完成反馈")
        XCTAssertNil(fixture.store.selectedSession?.activeTurnID)
        XCTAssertNil(fixture.store.selectedForegroundActivity)
        let historyTexts = fixture.conversationStore.messages(for: sessionID).map(\.content)
        XCTAssertTrue(historyTexts.contains("第一轮历史回复（迟到快照）"))
        XCTAssertTrue(historyTexts.contains("第二轮历史回复"))

        await runtime.handle(turnStarted("live-next"))
        await applyBufferedEvents(from: runtime, policy: .all, fixture: fixture, recorder: recorder)
        XCTAssertEqual(fixture.store.selectedSession?.status, "running")
        XCTAssertEqual(fixture.store.selectedSession?.activeTurnID, "live-next")

        await emitMessage("live-next", text: "新的实时回复", into: runtime)
        await runtime.handle(turnCompleted("live-next"))
        await applyBufferedEvents(from: runtime, policy: .all, fixture: fixture, recorder: recorder)
        XCTAssertEqual(recorder.feedback, [.completion])

        await runtime.handle(turnCompleted("live-next"))
        await applyBufferedEvents(from: runtime, policy: .all, fixture: fixture, recorder: recorder)
        XCTAssertEqual(recorder.feedback, [.completion], "重复完成通知不能再次触发反馈")
        XCTAssertNil(fixture.store.selectedSession?.activeTurnID)
    }

    func testOpeningCurrentTurnKeepsItActiveDespiteLateHistoricalContent() async throws {
        let fixture = makeFixture()
        defer { fixture.store.disconnectWebSocket() }
        let recorder = FeedbackRecorder(store: fixture.store, sessionID: sessionID)
        let runtime = makeRuntime()

        await seedThread(in: runtime)
        await emitCompletedTurn("old", text: "旧回复", into: runtime)
        await runtime.handle(turnStarted("live-current"))
        await emitMessage("old", text: "旧回复（迟到快照）", into: runtime)
        await applyBufferedEvents(from: runtime, policy: .stateOnly, fixture: fixture, recorder: recorder)

        XCTAssertEqual(fixture.store.selectedSession?.status, "running")
        XCTAssertEqual(fixture.store.selectedSession?.activeTurnID, "live-current")
        XCTAssertTrue(recorder.feedback.isEmpty, "旧回合完成不能结束当前回合")
        XCTAssertTrue(fixture.conversationStore.messages(for: sessionID).contains {
            $0.content == "旧回复（迟到快照）"
        })

        await emitMessage("live-current", text: "当前回复", into: runtime)
        await runtime.handle(turnCompleted("live-current"))
        await applyBufferedEvents(from: runtime, policy: .all, fixture: fixture, recorder: recorder)
        XCTAssertEqual(recorder.feedback, [.completion])
        XCTAssertEqual(fixture.store.selectedSession?.status, "completed")
        XCTAssertNil(fixture.store.selectedSession?.activeTurnID)
    }

    func testOpeningActiveTurnKeepsWindowTextAndContinuesStreaming() async throws {
        let fixture = makeFixture()
        defer { fixture.store.disconnectWebSocket() }
        let recorder = FeedbackRecorder(store: fixture.store, sessionID: sessionID)
        let runtime = makeRuntime()

        await seedThread(in: runtime)
        await runtime.handle(turnStarted("live-streaming"))
        let attachment = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID)
        // 这段正文产生于历史首屏之后，恢复结束时不能把它当作已读历史丢弃。
        await emitDelta("live-streaming", text: "窗口内", into: runtime)
        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
        await runtime.finishAttachedEventStreams(sessionID: sessionID)
        for await event in attachment.events {
            await fixture.store.applyRuntimeEvent(event, lease: fixture.lease, sendsNotification: false)
            recorder.observeCurrentState()
        }

        XCTAssertEqual(fixture.conversationStore.messages(for: sessionID).map(\.content), ["窗口内"])
        XCTAssertEqual(fixture.store.selectedSession?.activeTurnID, "live-streaming")
        XCTAssertTrue(recorder.feedback.isEmpty)

        await emitDelta("live-streaming", text: "后续", into: runtime)
        await applyBufferedEvents(from: runtime, policy: .all, fixture: fixture, recorder: recorder)
        fixture.conversationStore.resetLiveTranscript(sessionID: sessionID)
        XCTAssertEqual(fixture.conversationStore.messages(for: sessionID).map(\.content), ["窗口内后续"])
        XCTAssertEqual(fixture.store.selectedSession?.status, "running")
        XCTAssertTrue(recorder.feedback.isEmpty)

        await emitMessage("live-streaming", text: "窗口内后续", into: runtime)
        await runtime.handle(turnCompleted("live-streaming"))
        await applyBufferedEvents(from: runtime, policy: .all, fixture: fixture, recorder: recorder)
        XCTAssertEqual(fixture.conversationStore.messages(for: sessionID).map(\.content), ["窗口内后续"])
        XCTAssertEqual(recorder.feedback, [.completion])
    }

    private struct Fixture {
        let store: SessionStore
        let conversationStore: ConversationStore
        let lease: HostSessionLease
    }

    private func makeFixture() -> Fixture {
        let appStore = makeIsolatedAppStore()
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        store.sessions = [makeSession(
            id: sessionID,
            projectID: "history-feedback",
            title: "历史反馈回归",
            status: "completed",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: sessionID
        )]
        store.selectedSessionID = sessionID
        return Fixture(
            store: store,
            conversationStore: conversationStore,
            lease: HostSessionLease(hostScope: appStore.activeHostScope, sessionID: sessionID)
        )
    }

    private func makeRuntime() -> CodexAppServerSessionRuntime {
        CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude"
        )
    }

    private func seedThread(in runtime: CodexAppServerSessionRuntime) async {
        await runtime.handle(CodexAppServerNotification(
            method: "thread/started",
            params: .object(["thread": .object([
                "id": .string(sessionID),
                "cwd": .string("/tmp/history-feedback"),
                "name": .string("历史反馈回归"),
                "status": .object(["type": .string("idle")]),
                "modelProvider": .string("anthropic"),
                "source": .string("appServer"),
            ])])
        ))
    }

    private func emitCompletedTurn(
        _ turnID: TurnID,
        text: String,
        into runtime: CodexAppServerSessionRuntime
    ) async {
        await runtime.handle(turnStarted(turnID))
        await emitMessage(turnID, text: text, into: runtime)
        await runtime.handle(turnCompleted(turnID))
    }

    private func emitMessage(
        _ turnID: TurnID,
        text: String,
        into runtime: CodexAppServerSessionRuntime
    ) async {
        await runtime.handle(CodexAppServerNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string("message-\(turnID)"),
                    "type": .string("agentMessage"),
                    "text": .string(text),
                ]),
            ])
        ))
    }

    private func emitDelta(
        _ turnID: TurnID,
        text: String,
        into runtime: CodexAppServerSessionRuntime
    ) async {
        await runtime.handle(CodexAppServerNotification(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string(turnID),
                "itemId": .string("message-\(turnID)"),
                "delta": .string(text),
            ])
        ))
    }

    private func turnStarted(_ turnID: TurnID) -> CodexAppServerNotification {
        CodexAppServerNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(sessionID),
                "turn": .object(["id": .string(turnID)]),
            ])
        )
    }

    private func turnCompleted(_ turnID: TurnID) -> CodexAppServerNotification {
        CodexAppServerNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(sessionID),
                "turn": .object(["id": .string(turnID), "status": .string("completed")]),
            ])
        )
    }

    private func applyBufferedEvents(
        from runtime: CodexAppServerSessionRuntime,
        policy: CodexAppServerBufferedEventReplayPolicy,
        fixture: Fixture,
        recorder: FeedbackRecorder
    ) async {
        let events = await runtime.bufferedEvents(sessionID: sessionID, replayPolicy: policy)
        for event in events {
            await fixture.store.applyRuntimeEvent(event, lease: fixture.lease, sendsNotification: false)
            recorder.observeCurrentState()
        }
    }

    @MainActor
    private final class FeedbackRecorder {
        private let store: SessionStore
        private let sessionID: SessionID
        private var tracker = SessionLifecycleFeedbackTracker()
        private var subscription: AnyCancellable?
        private(set) var phases: [SessionLifecyclePhase] = []
        private(set) var feedback: [MimiHapticEvent] = []

        init(store: SessionStore, sessionID: SessionID) {
            self.store = store
            self.sessionID = sessionID
            observeCurrentState()
            subscription = store.$sessions.sink { [weak self] sessions in
                // @Published 在 willSet 发布；读取回调值才能捕获每一个真实提交的中间状态。
                guard let self, let session = sessions.first(where: { $0.id == sessionID }) else { return }
                self.observe(session)
            }
        }

        func observeCurrentState() {
            guard let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
            observe(session)
        }

        private func observe(_ session: AgentSession) {
            let observation = SessionLifecycleObservation(
                session: session,
                foregroundActivity: store.foregroundActivity(for: sessionID)
            )
            phases.append(observation.phase)
            if let event = tracker.observe([observation]) {
                feedback.append(event)
            }
        }
    }
}
