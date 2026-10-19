import XCTest
@testable import MimiRemote

/// #805：同一会话在 iPad 跑完一轮后又在电脑端开始新一轮，本地「已完成」标记把之后的 running
/// 快照全部压回 completed，iPad 一直显示已完成，发送被当成空闲会话反复失败。
/// 本地完成只能挡住落后的快照；带来新回合或更晚更新时间的快照必须让位。
@MainActor
final class LocalCompletionSupersededTests: XCTestCase {
    private let completedAt = Date(timeIntervalSince1970: 1_780_500_000)

    func testCodexResumeSnapshotWithNewTurnRestoresRunningAfterLocalCompletion() async {
        let fixture = makeCompletedFixture(suffix: "codex-new-turn", source: "codex")

        // 电脑端 Codex Desktop 在共享运行时里开始新一轮，thread/resume 带回新的进行中回合。
        fixture.store.upsert(fixture.snapshot(status: .running, activeTurnID: "turn-mac", updatedAt: completedAt))

        let session = fixture.store.sessionsByID[fixture.sessionID]
        XCTAssertEqual(session?.status, SessionStatus.running.rawValue)
        XCTAssertEqual(session?.activeTurnID, "turn-mac")
        XCTAssertEqual(session?.isRunning, true)
    }

    func testCodexListSnapshotUpdatedAfterLocalCompletionRestoresRunning() async {
        let fixture = makeCompletedFixture(suffix: "codex-list", source: "codex")

        // Codex 的 thread/list 不带 turns，只能靠更新时间判断这是完成之后的新状态。
        fixture.store.mergeSessionPage([
            fixture.snapshot(status: .running, activeTurnID: nil, updatedAt: completedAt.addingTimeInterval(30))
        ])

        XCTAssertEqual(fixture.store.sessionsByID[fixture.sessionID]?.status, SessionStatus.running.rawValue)
    }

    func testCodexLaggingRunningSnapshotsStayCompletedAfterLocalCompletion() async {
        let fixture = makeCompletedFixture(suffix: "codex-lagging", source: "codex")
        let lagging = [
            // 已经看到结束的回合不会重新开始，即使快照时间更晚。
            fixture.snapshot(status: .running, activeTurnID: "turn-ipad", updatedAt: completedAt.addingTimeInterval(30)),
            fixture.snapshot(status: .running, activeTurnID: nil, updatedAt: completedAt),
            fixture.snapshot(status: .running, activeTurnID: nil, updatedAt: completedAt.addingTimeInterval(-10)),
            // 早于完成时间的快照即使带着别的回合 ID 也只能是更早的状态。
            fixture.snapshot(status: .running, activeTurnID: "turn-older", updatedAt: completedAt.addingTimeInterval(-10))
        ]

        for snapshot in lagging {
            fixture.store.mergeSessionPage([snapshot])
            let session = fixture.store.sessionsByID[fixture.sessionID]
            XCTAssertEqual(session?.status, SessionStatus.completed.rawValue, "落后快照 \(String(describing: snapshot.activeTurnID)) 不能拉回运行态")
            XCTAssertNil(session?.activeTurnID)
        }
    }

    func testClaudeListSnapshotUpdatedAfterLocalCompletionRestoresRunning() async {
        let fixture = makeCompletedFixture(suffix: "claude-list", source: "claude")

        fixture.store.mergeSessionPage([
            fixture.snapshot(status: .running, activeTurnID: nil, updatedAt: completedAt)
        ])
        XCTAssertEqual(
            fixture.store.sessionsByID[fixture.sessionID]?.status,
            SessionStatus.completed.rawValue,
            "Claude 列表的 updatedAt 是最后一条对话时间；没有前进就是同一次完成"
        )

        // 终端里的 Claude 接着这个会话开始新一轮：最后一条对话时间前移。
        fixture.store.mergeSessionPage([
            fixture.snapshot(status: .running, activeTurnID: nil, updatedAt: completedAt.addingTimeInterval(20))
        ])
        XCTAssertEqual(fixture.store.sessionsByID[fixture.sessionID]?.status, SessionStatus.running.rawValue)
    }

    func testClaudeReadSnapshotWithNewTurnRestoresRunningAfterLocalCompletion() async {
        let fixture = makeCompletedFixture(suffix: "claude-read", source: "claude")

        fixture.store.upsert(fixture.snapshot(status: .running, activeTurnID: "turn-terminal", updatedAt: completedAt))

        XCTAssertEqual(fixture.store.sessionsByID[fixture.sessionID]?.status, SessionStatus.running.rawValue)
        XCTAssertEqual(fixture.store.sessionsByID[fixture.sessionID]?.activeTurnID, "turn-terminal")
    }

    func testCodexActiveTurnConflictAfterLocalCompletionQueuesNextMessage() async throws {
        try await assertActiveTurnConflictQueuesNextMessage(source: "codex")
    }

    func testClaudeActiveTurnConflictAfterLocalCompletionQueuesNextMessage() async throws {
        try await assertActiveTurnConflictQueuesNextMessage(source: "claude")
    }

    func testCodexConflictOlderThanObservedCompletionKeepsSessionCompleted() async throws {
        try await assertStaleConflictKeepsObservedCompletion(source: "codex")
    }

    func testClaudeConflictOlderThanObservedCompletionKeepsSessionCompleted() async throws {
        try await assertStaleConflictKeepsObservedCompletion(source: "claude")
    }

    // MARK: - Helpers

    /// resume 等待期间电脑端那一轮已经结束，且 turn/completed 先于冲突结果落地：冲突快照比本地完成旧，
    /// 不能把已结束的回合恢复成进行中，否则后续消息会一直排在不存在的回合后面。
    private func assertStaleConflictKeepsObservedCompletion(source: String) async throws {
        let fixture = await makeConflictFixture(suffix: "stale-\(source)", source: source)
        let store = fixture.store
        let client = fixture.client
        let sessionID = fixture.session.id

        let firstSend = Task { await store.sendPrompt("第一条") }
        await client.waitForCreateRequestCount(1)
        applyRuntimeCompletion(of: fixture.session, turnID: "turn-mac", completedAt: completedAt.addingTimeInterval(90), in: store)
        var staleConflict = fixture.session
        staleConflict.status = SessionStatus.running.rawValue
        staleConflict.activeTurnID = "turn-mac"
        staleConflict.updatedAt = completedAt.addingTimeInterval(60)
        client.resolveCreate(with: .failure(
            CodexAppServerSessionRuntimeError.activeTurnConflict(session: staleConflict, activeTurnID: "turn-mac")
        ))
        let firstDelivered = await firstSend.value

        XCTAssertFalse(firstDelivered)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue, "turn-mac 的完成已经落地，冲突快照是旧的")
        XCTAssertNil(store.selectedSession?.activeTurnID)
        XCTAssertEqual(
            fixture.conversationStore.messages(for: sessionID).first { $0.content == "第一条" }?.sendStatus,
            .failed
        )
        XCTAssertEqual(store.statusMessage, L10n.text("ui.the_reply_just_finished_this_message_was_not_sent_please_retry"))

        let secondSend = Task { await store.sendPrompt("第二条") }
        for _ in 0..<200 {
            if store.queuedRunningTurnsBySessionID[sessionID]?.isEmpty == false || client.createPayloads.count >= 2 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if client.createPayloads.count >= 2 {
            client.resolveCreate(with: .failure(MockError.unimplemented), at: 1)
        }
        _ = await secondSend.value

        XCTAssertEqual(client.createPayloads.count, 2, "回合已结束，第二条应直接 resume 发送")
        XCTAssertTrue(store.queuedRunningTurnsBySessionID[sessionID]?.isEmpty ?? true, "不能排在已结束的回合后面")
    }

    private struct ConflictFixture {
        let store: SessionStore
        let client: DelayedCreateSessionClient
        let conversationStore: ConversationStore
        let session: AgentSession
    }

    /// 本机跑完一轮的会话已被选中，等待用户再发一条（发送会走 resume）。
    private func makeConflictFixture(suffix: String, source: String) async -> ConflictFixture {
        let project = makeProject(id: "proj-local-completion-conflict-\(suffix)")
        let sessionID = "sess-local-completion-conflict-\(suffix)"
        let completed = makeSession(
            id: sessionID,
            projectID: project.id,
            title: "电脑端接着跑",
            status: SessionStatus.completed.rawValue,
            source: source,
            runtimeProvider: source,
            resumeID: sessionID,
            updatedAt: completedAt
        )
        let client = DelayedCreateSessionClient(projects: [project], sessions: [completed])
        let conversationStore = ConversationStore()
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(completed)
        await store.selectSession(completed)
        observeLocalCompletion(of: completed, turnID: "turn-ipad", in: store)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)
        return ConflictFixture(store: store, client: client, conversationStore: conversationStore, session: completed)
    }

    private func assertActiveTurnConflictQueuesNextMessage(source: String) async throws {
        let fixture = await makeConflictFixture(suffix: source, source: source)
        let store = fixture.store
        let client = fixture.client
        let conversationStore = fixture.conversationStore
        let completed = fixture.session
        let sessionID = completed.id

        var authoritative = completed
        authoritative.status = SessionStatus.running.rawValue
        authoritative.activeTurnID = "turn-mac"
        authoritative.updatedAt = completedAt.addingTimeInterval(60)

        let firstSend = Task { await store.sendPrompt("第一条") }
        await client.waitForCreateRequestCount(1)
        client.resolveCreate(with: .failure(
            CodexAppServerSessionRuntimeError.activeTurnConflict(session: authoritative, activeTurnID: "turn-mac")
        ))
        let firstDelivered = await firstSend.value

        XCTAssertFalse(firstDelivered)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.running.rawValue, "resume 已证明电脑端的回合仍在运行")
        XCTAssertEqual(store.selectedSession?.activeTurnID, "turn-mac")
        XCTAssertEqual(
            conversationStore.messages(for: sessionID).first { $0.content == "第一条" }?.sendStatus,
            .failed
        )
        XCTAssertEqual(store.statusMessage, L10n.text("ui.a_reply_is_still_in_progress_this_message_was_not_sent"))

        let secondSend = Task { await store.sendPrompt("第二条") }
        for _ in 0..<200 {
            if store.queuedRunningTurnsBySessionID[sessionID]?.isEmpty == false || client.createPayloads.count >= 2 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if client.createPayloads.count >= 2 {
            // 修复前第二条仍按空闲会话走 resume；放行挂起的请求，避免测试卡住。
            client.resolveCreate(with: .failure(MockError.unimplemented), at: 1)
        }
        let secondQueued = await secondSend.value

        XCTAssertTrue(secondQueued)
        XCTAssertEqual(client.createPayloads.count, 1, "第二条不能再按空闲会话发起 resume")
        XCTAssertEqual(store.queuedRunningTurnsBySessionID[sessionID]?.count, 1)
        XCTAssertEqual(store.queuedRunningTurnsBySessionID[sessionID]?.first?.expectedTurnID, "turn-mac")
        XCTAssertEqual(store.statusMessage, L10n.text("ui.saved_to_this_machine_and_will_be_sent"))
    }

    private struct CompletedFixture {
        let store: SessionStore
        let base: AgentSession

        var sessionID: SessionID { base.id }

        func snapshot(status: SessionStatus, activeTurnID: TurnID?, updatedAt: Date) -> AgentSession {
            var snapshot = base
            snapshot.status = status.rawValue
            snapshot.activeTurnID = activeTurnID
            snapshot.updatedAt = updatedAt
            return snapshot
        }
    }

    /// 会话在本机跑完一轮：Store 里先是进行中的 `turn-ipad`，随后收到运行时的终态快照与 turn/completed。
    private func makeCompletedFixture(suffix: String, source: String) -> CompletedFixture {
        let project = makeProject(id: "proj-local-completion-\(suffix)")
        let running = makeSession(
            id: "sess-local-completion-\(suffix)",
            projectID: project.id,
            title: "本机跑完一轮",
            status: SessionStatus.running.rawValue,
            source: source,
            runtimeProvider: source,
            resumeID: "sess-local-completion-\(suffix)",
            activeTurnID: "turn-ipad",
            updatedAt: completedAt.addingTimeInterval(-40)
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running]) }
        )
        store.sessions = [running]
        observeLocalCompletion(of: running, turnID: "turn-ipad", in: store)
        XCTAssertEqual(store.sessionsByID[running.id]?.status, SessionStatus.completed.rawValue)
        XCTAssertNil(store.sessionsByID[running.id]?.activeTurnID)
        return CompletedFixture(store: store, base: running)
    }

    /// Store 里先是进行中的 `turnID`，随后收到它的完成。
    private func observeLocalCompletion(of session: AgentSession, turnID: TurnID, in store: SessionStore) {
        store.updateSession(session.id) { item in
            item.status = SessionStatus.running.rawValue
            item.activeTurnID = turnID
        }
        applyRuntimeCompletion(of: session, turnID: turnID, completedAt: completedAt, in: store)
    }

    /// 与运行时投影 turn/completed 的顺序一致：先发终态 session 快照（updatedAt 取回合完成时间），
    /// 再发 turn/completed 事件。
    private func applyRuntimeCompletion(
        of session: AgentSession,
        turnID: TurnID,
        completedAt: Date,
        in store: SessionStore
    ) {
        var completed = session
        completed.status = SessionStatus.completed.rawValue
        completed.activeTurnID = nil
        completed.updatedAt = completedAt
        var output = EventReducerOutput()
        output.upsertSessions.append(completed)
        store.applyEventReducerOutput(output)

        var completion = EventReducerOutput()
        completion.statusUpdates.append((session.id, SessionStatus.completed.rawValue))
        completion.activeTurnMutations.append(.clear(session.id, turnID))
        store.applyEventReducerOutput(completion)
    }
}
