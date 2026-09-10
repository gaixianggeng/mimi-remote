import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testMissingAssistantReplyAppearsAfterFreshRead() async throws {
        let fixture = makeControlledBackfillFixture()
        await fixture.complete("A", seq: 1)
        try await fixture.waitForRequests(1)
        let task = fixture.backfillTask
        fixture.client.resolveHistoryRequest(at: 0, with: fixture.history(["A"]))
        await task?.value
        XCTAssertEqual(fixture.replyTurnIDs, ["A"])
        XCTAssertNil(fixture.store.missingAssistantReplyBackfillJobsBySessionID[fixture.session.id])
    }

    func testMissingAssistantReplyReplacesOlderBypassHistoryRequest() async throws {
        let fixture = makeControlledBackfillFixture()
        let olderRead = Task {
            await fixture.store.loadHistory(for: fixture.session, quiet: true, force: true)
        }
        try await fixture.waitForRequests(1)
        await fixture.complete("A", seq: 1)
        try await fixture.waitForRequests(2)
        let task = fixture.backfillTask
        // 先结束旧请求，必须还有完成事件之后发出的第二次读取。
        fixture.client.resolveHistoryRequest(at: 0, with: fixture.history([]))
        _ = await olderRead.value
        fixture.client.resolveHistoryRequest(at: 1, with: fixture.history(["A"]))
        await task?.value
        XCTAssertEqual(fixture.replyTurnIDs, ["A"])
        XCTAssertEqual(fixture.client.requestedMessageLoadModes, [.full, .full])
    }

    func testMissingAssistantReplySurvivesNextTurnWithReply() async throws {
        let fixture = makeControlledBackfillFixture()
        await fixture.complete("A", seq: 1)
        await fixture.reply("B", seq: 2)
        await fixture.complete("B", seq: 3)
        try await fixture.waitForRequests(1)
        let task = fixture.backfillTask
        fixture.client.resolveHistoryRequest(at: 0, with: fixture.history(["A", "B"]))
        await task?.value
        XCTAssertEqual(fixture.replyTurnIDs.sorted(), ["A", "B"])
        XCTAssertEqual(fixture.client.requestedMessageLimits.count, 1)
    }

    func testMissingAssistantReplyKeepsTurnCompletedDuringRead() async throws {
        let fixture = makeControlledBackfillFixture()
        await fixture.complete("A", seq: 1)
        try await fixture.waitForRequests(1)
        await fixture.complete("B", seq: 2)
        let task = fixture.backfillTask
        fixture.client.resolveHistoryRequest(at: 0, with: fixture.history(["A"]))
        try await fixture.waitForRequests(2)
        fixture.client.resolveHistoryRequest(at: 1, with: fixture.history(["A", "B"]))
        await task?.value
        XCTAssertEqual(fixture.replyTurnIDs.sorted(), ["A", "B"])
        XCTAssertEqual(fixture.client.requestedMessageLimits.count, 2)
    }

    func testMissingAssistantReplyCoalescesDuplicateCompletionsAndRetainsEmptyResult() async throws {
        let fixture = makeControlledBackfillFixture()
        await fixture.complete("A", seq: 1)
        await fixture.complete("A", seq: 2)
        try await fixture.waitForRequests(1)
        await fixture.complete("A", seq: 3)
        let task = fixture.backfillTask
        fixture.client.resolveHistoryRequest(at: 0, with: fixture.history([]))
        await task?.value
        await fixture.complete("A", seq: 4)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(fixture.client.requestedMessageLimits.count, 1)
        XCTAssertTrue(fixture.replyTurnIDs.isEmpty)
        XCTAssertEqual(fixture.store.missingAssistantReplyBackfillJobsBySessionID[fixture.session.id]?.pendingTurnIDs, ["A"])
    }

    func testMissingAssistantReplyFailureCanRecoverWhenSessionReopens() async throws {
        let fixture = makeControlledBackfillFixture()
        await fixture.complete("A", seq: 1)
        try await fixture.waitForRequests(1)
        let first = fixture.backfillTask
        fixture.client.failHistoryRequest(at: 0, with: URLError(.networkConnectionLost))
        await first?.value
        XCTAssertEqual(fixture.store.missingAssistantReplyBackfillJobsBySessionID[fixture.session.id]?.pendingTurnIDs, ["A"])

        _ = fixture.store.commitSelection(projectID: nil, sessionID: nil, reason: .userOpen)
        _ = fixture.store.commitSelection(projectID: fixture.session.projectID, sessionID: fixture.session.id, reason: .userOpen)
        try await fixture.waitForRequests(2)
        let second = fixture.backfillTask
        fixture.client.resolveHistoryRequest(at: 1, with: fixture.history(["A"]))
        await second?.value
        XCTAssertEqual(fixture.replyTurnIDs, ["A"])
    }

    func testMissingAssistantReplyPausesInBackgroundAndResumes() async throws {
        let fixture = makeControlledBackfillFixture()
        await fixture.complete("A", seq: 1)
        fixture.store.suspendForBackground()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(fixture.client.requestedMessageLimits.count, 0)
        await fixture.store.resumeFromForeground()
        try await fixture.waitForRequests(1)
        let task = fixture.backfillTask
        fixture.client.resolveHistoryRequest(at: 0, with: fixture.history(["A"]))
        await task?.value
        XCTAssertEqual(fixture.replyTurnIDs, ["A"])
    }

    func testMissingAssistantReplyLateReadCannotCrossConnectionReset() async throws {
        let fixture = makeControlledBackfillFixture()
        await fixture.complete("A", seq: 1)
        try await fixture.waitForRequests(1)
        let task = fixture.backfillTask
        fixture.store.clearConnectionData()
        fixture.store.sessions = [fixture.session]
        fixture.store.markEmptyHistoryLoaded(for: fixture.session)
        fixture.client.resolveHistoryRequest(at: 0, with: fixture.history(["A"]))
        await task?.value
        XCTAssertTrue(fixture.replyTurnIDs.isEmpty)
        XCTAssertTrue(fixture.store.missingAssistantReplyBackfillJobsBySessionID.isEmpty)
    }

    private func makeControlledBackfillFixture() -> ControlledBackfillFixture {
        let project = makeProject(id: "backfill-project")
        let session = makeSession(id: "backfill-session", projectID: project.id, title: "短回复", status: "running", source: "codex")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [session]), supportsLatestTurnHistoryPage: false)
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            runtimeCompletionNotificationsEnabled: false,
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        store.setProjectsIfChanged([project])
        store.sessions = [session]
        store.markEmptyHistoryLoaded(for: session)
        _ = store.commitSelection(projectID: project.id, sessionID: session.id, reason: .userOpen)
        return ControlledBackfillFixture(store: store, client: client, session: session)
    }
}

@MainActor
private struct ControlledBackfillFixture {
    let store: SessionStore
    let client: OrderedHistoryPageClient
    let session: AgentSession

    var backfillTask: Task<Void, Never>? {
        store.missingAssistantReplyBackfillJobsBySessionID[session.id]?.task
    }

    var replyTurnIDs: [String] {
        store.conversationStore.messages(for: session.id)
            .filter { $0.role == .assistant && $0.kind == .message }
            .compactMap(\.turnID)
    }

    func complete(_ turnID: String, seq: EventSequence) async {
        await store.applyRuntimeEvent(
            .turnCompleted(metadata(turnID, seq: seq).withTurnLifecycle(.completed)),
            lease: HostSessionLease(hostScope: store.appStore.activeHostScope, sessionID: session.id)
        )
    }

    func reply(_ turnID: String, seq: EventSequence) async {
        let message = AgentMessage(id: "reply-\(turnID)", sessionID: session.id, turnID: turnID, itemID: "item-\(turnID)", role: .assistant, kind: .message, content: "回复 \(turnID)")
        await store.applyRuntimeEvent(.messageCompleted(message, metadata(turnID, seq: seq)),
            lease: HostSessionLease(hostScope: store.appStore.activeHostScope, sessionID: session.id))
    }

    func history(_ turnIDs: [String]) -> HistoryMessagesPage {
        HistoryMessagesPage(messages: turnIDs.map { turnID in
            CodexHistoryMessage(id: "reply-\(turnID)", role: "assistant", content: "回复 \(turnID)", createdAt: Date(timeIntervalSince1970: 10), turnID: turnID, itemID: "item-\(turnID)", turnLifecycle: .completed)
        })
    }

    private func metadata(_ turnID: String, seq: EventSequence) -> AgentEventMetadata {
        AgentEventMetadata(seq: seq, sessionID: session.id, turnID: turnID, itemID: "item-\(turnID)", messageID: "reply-\(turnID)", clientMessageID: nil, revision: Int(seq), createdAt: nil)
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<200 {
            if client.requestedMessageLimits.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("缺失正文补读未发出第 \(count) 次请求")
        throw URLError(.timedOut)
    }
}
