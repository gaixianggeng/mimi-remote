import XCTest
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

private actor UsageRefreshGate {
    private var requestedProviders: [String] = []
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var claudeContinuation: CheckedContinuation<RateLimitSummary?, Never>?

    func response(for provider: String) async -> RateLimitSummary? {
        requestedProviders.append(provider)
        requestWaiters.removeValue(forKey: provider)?.forEach { $0.resume() }
        if provider == "claude" {
            return await withCheckedContinuation { continuation in
                claudeContinuation = continuation
            }
        }
        return RateLimitSummary(limitID: provider, primaryUsedPercent: 20)
    }

    func waitForRequest(provider: String) async {
        if requestedProviders.contains(provider) {
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters[provider, default: []].append(continuation)
        }
    }

    func requestCount(provider: String) -> Int {
        requestedProviders.filter { $0 == provider }.count
    }

    func finishClaude() {
        claudeContinuation?.resume(
            returning: RateLimitSummary(limitID: "claude", limitName: "Claude", primaryUsedPercent: 30)
        )
        claudeContinuation = nil
    }
}

@MainActor
extension ConversationDataFlowTests {
    func testSessionInspectorSectionsCollapseDetailsLogsAndDiagnostics() {
        let descriptors = SessionInspectorSectionDescriptor.all

        XCTAssertEqual(
            descriptors.map(\.title),
            [L10n.text("ui.overview"), L10n.text("ui.change"), L10n.text("ui.activities")]
        )
        XCTAssertEqual(descriptors.map(\.id), ["overview", "changes", "activity"])
        XCTAssertEqual(descriptors.count, 3)
    }

    func testHistoryPagingStatePrunesWhenSessionLeavesList() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [history]),
            historyPages: [
                history.id: HistoryMessagesPage(
                    messages: [
                        CodexHistoryMessage(id: "rollout:200", role: "assistant", content: "较新的回答", createdAt: Date(timeIntervalSince1970: 20))
                    ],
                    previousCursor: "older_cursor",
                    hasMoreBefore: true
                )
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))

        store.returnToSessionList()
        client.page = SessionsPage(sessions: [])
        await store.refreshSelectedProjectSessions()

        XCTAssertFalse(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testEmptyHistoryRefreshPreservesEarlierCursorUntilLoadEarlierReturnsEmpty() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let newer = [
            CodexHistoryMessage(id: "rollout:200", role: "user", content: "较新的问题", createdAt: Date(timeIntervalSince1970: 20))
        ]
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [history]),
            historyPages: [
                history.id: HistoryMessagesPage(messages: newer, previousCursor: "older_cursor", hasMoreBefore: true)
            ],
            historyCursorPages: [
                "older_cursor": HistoryMessagesPage(messages: [], hasMoreBefore: false)
            ]
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))

        client.historyPages[history.id] = HistoryMessagesPage(messages: [], hasMoreBefore: false)
        await store.refreshCurrentContext()

        // 首屏刷新偶发空页时，不能把已有 older cursor 清掉，否则用户无法继续加载更早历史。
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["较新的问题"])

        await store.loadEarlierHistoryForSelectedSession()

        XCTAssertFalse(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertEqual(client.requestedMessageCursors, [nil, nil, "older_cursor"])
    }

    func testManualRefreshReusesInFlightFullHistoryRequest() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        let refreshTask = Task { await store.refreshCurrentContext() }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full])

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:200", role: "assistant", content: "新历史", createdAt: Date(timeIntervalSince1970: 20))
                ],
                previousCursor: "fresh_cursor",
                hasMoreBefore: true
            )
        )
        await refreshTask.value
        await selectTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["新历史"])
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full])
    }

    func testRefreshCurrentContextKeepsRunningRecentOutputInLogOnly() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: "│ • 从 Mac 回来的回复\n", lastSeq: 12)
            ],
            messagesResult: []
        )
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: logStore,
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.selectedSessionID = running.id
        await store.refreshCurrentContext()
        try await Task.sleep(nanoseconds: 1_100_000_000)

        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertTrue(logStore.log(for: running.id).contains("从 Mac 回来的回复"))
        XCTAssertTrue(conversationStore.messages(for: running.id).isEmpty)
    }

    func testStructuredAssistantMessageCreatesBubble() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_structured_assistant_live", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)

        let assistant = try AgentAPIClient.decoder.decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "rollout:200",
              "session_id": "\(running.id)",
              "role": "assistant",
              "kind": "message",
              "content": "结构化助手回复",
              "created_at": "2026-06-02T10:00:00Z",
              "revision": 1,
              "send_status": "confirmed"
            }
            """.utf8)
        )
        sockets[0].emitEvent(.messageCompleted(
            assistant,
            AgentEventMetadata(seq: 2, sessionID: running.id, turnID: nil, itemID: nil, messageID: "rollout:200", clientMessageID: nil, revision: 1, createdAt: nil)
        ))
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let messages = conversationStore.messages(for: running.id)
        XCTAssertTrue(logStore.log(for: running.id).isEmpty)
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.content == "结构化助手回复" })
    }

    func testRefreshCurrentContextRequestsRunningDetailAfterLocalLogSeq() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: nil, lastSeq: 12)
            ],
            messagesResult: []
        )
        let appStore = makeIsolatedAppStore()
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        conversationStore.activate(profileID: appStore.activeHostScope.profileID)
        logStore.activate(profileID: appStore.activeHostScope.profileID)
        logStore.append("本地已有输出", sessionID: running.id, seq: 12)
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.selectedSessionID = running.id
        await store.refreshCurrentContext()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertEqual(client.requestedSessionAfterSeqs, [12])
        XCTAssertTrue(conversationStore.messages(for: running.id).isEmpty)
    }

    func testWebSocketMessageLimitAllowsLargeAppServerFrames() throws {
        let task = URLSession.shared.webSocketTask(with: try XCTUnwrap(URL(string: "ws://127.0.0.1:9/ws")))
        defer {
            task.cancel(with: .goingAway, reason: nil)
        }

        WebSocketMessageLimits.apply(to: task)

        XCTAssertEqual(task.maximumMessageSize, WebSocketMessageLimits.maximumInboundMessageBytes)
        XCTAssertGreaterThanOrEqual(WebSocketMessageLimits.maximumInboundMessageBytes, 64 * 1024 * 1024)
    }

    func testTerminalStreamStoreBatchesRuntimeEventsBySession() async {
        let store = TerminalStreamStore(maxBatchSize: 2)
        let lease = HostSessionLease(
            hostScope: HostScope(profileID: "mac-a", installationID: "install-a", generation: 1),
            sessionID: "sess_batch"
        )
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: "sess_batch",
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )

        let firstShouldFlush = store.append(.turnStarted(metadata), lease: lease)
        let secondShouldFlush = store.append(
            .assistantDelta(AgentDelta(text: "hi", role: .assistant, kind: .message), metadata),
            lease: lease
        )

        XCTAssertFalse(firstShouldFlush)
        XCTAssertTrue(secondShouldFlush)
        let drained = store.drain(lease: lease)
        let drainedAgain = store.drain(lease: lease)
        XCTAssertEqual(drained.count, 2)
        XCTAssertTrue(drainedAgain.isEmpty)
    }

    func testTerminalStreamStoreCompactsContiguousAssistantDeltasWithoutCrossingBoundaries() {
        let store = TerminalStreamStore(maxBatchSize: 64)
        let lease = HostSessionLease(
            hostScope: HostScope(profileID: "mac-a", installationID: "install-a", generation: 1),
            sessionID: "sess_compact"
        )
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: "sess_compact",
            turnID: "turn_compact",
            itemID: "item_compact",
            messageID: "message_compact",
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )

        _ = store.append(
            .assistantDelta(AgentDelta(text: "你", role: .assistant, kind: .message), metadata),
            lease: lease
        )
        _ = store.append(
            .assistantDelta(AgentDelta(text: "好", role: .assistant, kind: .message), metadata),
            lease: lease
        )

        let compacted = store.drain(lease: lease)
        XCTAssertEqual(compacted.count, 1)
        guard case .assistantDelta(let delta, _) = compacted.first else {
            return XCTFail("连续正文增量应合并为一个事件")
        }
        XCTAssertEqual(delta.text, "你好")

        _ = store.append(
            .assistantDelta(AgentDelta(text: "A", role: .assistant, kind: .message), metadata),
            lease: lease
        )
        _ = store.append(.turnStarted(metadata), lease: lease)
        _ = store.append(
            .assistantDelta(AgentDelta(text: "B", role: .assistant, kind: .message), metadata),
            lease: lease
        )
        XCTAssertEqual(store.drain(lease: lease).count, 3, "控制事件边界不能被合并穿透")
    }

    func testTerminalStreamStoreSeparatesSameSessionAcrossHostScopes() {
        let store = TerminalStreamStore(maxBatchSize: 64)
        let macALease = HostSessionLease(
            hostScope: HostScope(profileID: "mac-a", installationID: "install-a", generation: 1),
            sessionID: "same-session"
        )
        let macBLease = HostSessionLease(
            hostScope: HostScope(profileID: "mac-b", installationID: "install-b", generation: 2),
            sessionID: "same-session"
        )
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: "same-session",
            turnID: "same-turn",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )

        _ = store.append(
            .assistantDelta(AgentDelta(text: "A", role: .assistant, kind: .message), metadata),
            lease: macALease
        )
        _ = store.append(
            .assistantDelta(AgentDelta(text: "B", role: .assistant, kind: .message), metadata),
            lease: macBLease
        )

        XCTAssertEqual(store.drain(lease: macALease).count, 1)
        XCTAssertEqual(store.drain(lease: macBLease).count, 1)
    }

    func testTerminalStreamStoreMerges1000AssistantChunksAtDrain() {
        let store = TerminalStreamStore(maxBatchSize: 2)
        let lease = HostSessionLease(
            hostScope: HostScope(profileID: "mac-a", installationID: "install-a", generation: 1),
            sessionID: "sess_1000_chunks"
        )
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: lease.sessionID,
            turnID: "turn_1000_chunks",
            itemID: "item_1000_chunks",
            messageID: "message_1000_chunks",
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )
        let chunks = (0..<1_000).map { "chunk-\($0)|" }

        for chunk in chunks {
            XCTAssertFalse(
                store.append(
                    .assistantDelta(AgentDelta(text: chunk, role: .assistant, kind: .message), metadata),
                    lease: lease
                ),
                "同一逻辑事件的 chunk 不应提前触发 maxBatchSize"
            )
        }

        let drained = store.drain(lease: lease)
        XCTAssertEqual(drained.count, 1)
        guard case .assistantDelta(let delta, let returnedMetadata) = drained.first else {
            return XCTFail("1000 个 assistant chunk 应在 drain 时合并为一个事件")
        }
        XCTAssertEqual(delta.text, chunks.joined())
        XCTAssertEqual(delta.role, .assistant)
        XCTAssertEqual(delta.kind, .message)
        XCTAssertEqual(returnedMetadata, metadata)
    }

    func testTerminalStreamStoreKeepsAssistantAndLogBoundaries() {
        let store = TerminalStreamStore(maxBatchSize: 64)
        let lease = HostSessionLease(
            hostScope: HostScope(profileID: "mac-a", installationID: "install-a", generation: 1),
            sessionID: "sess_boundaries"
        )
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: lease.sessionID,
            turnID: "turn_boundaries",
            itemID: "item_boundaries",
            messageID: "message_boundaries",
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )

        _ = store.append(
            .assistantDelta(AgentDelta(text: "message-1", role: .assistant, kind: .message), metadata),
            lease: lease
        )
        _ = store.append(
            .assistantDelta(AgentDelta(text: "commentary", role: .assistant, kind: .commentary), metadata),
            lease: lease
        )
        _ = store.append(
            .assistantDelta(AgentDelta(text: "message-2", role: .assistant, kind: .message), metadata),
            lease: lease
        )
        _ = store.append(.turnStarted(metadata), lease: lease)
        _ = store.append(.logDelta(LogDelta(text: "stdout-1", stream: "stdout"), metadata), lease: lease)
        _ = store.append(.logDelta(LogDelta(text: "stdout-2", stream: "stdout"), metadata), lease: lease)
        _ = store.append(.logDelta(LogDelta(text: "stderr", stream: "stderr"), metadata), lease: lease)
        _ = store.append(.logDelta(LogDelta(text: "stdout-after", stream: "stdout"), metadata), lease: lease)

        let drained = store.drain(lease: lease)
        XCTAssertEqual(drained.count, 7, "role/kind、控制事件和 log stream 都是合并边界")
        guard drained.count == 7 else { return }
        guard case .assistantDelta(let message1, _) = drained[0],
              case .assistantDelta(let commentary, _) = drained[1],
              case .assistantDelta(let message2, _) = drained[2],
              case .turnStarted = drained[3],
              case .logDelta(let stdout, _) = drained[4],
              case .logDelta(let stderr, _) = drained[5],
              case .logDelta(let stdoutAfter, _) = drained[6]
        else {
            return XCTFail("事件顺序或类型不应被跨边界合并")
        }
        XCTAssertEqual(message1.text, "message-1")
        XCTAssertEqual(message1.kind, .message)
        XCTAssertEqual(commentary.text, "commentary")
        XCTAssertEqual(commentary.kind, .commentary)
        XCTAssertEqual(message2.text, "message-2")
        XCTAssertEqual(stdout.text, "stdout-1stdout-2")
        XCTAssertEqual(stdout.stream, "stdout")
        XCTAssertEqual(stderr.text, "stderr")
        XCTAssertEqual(stderr.stream, "stderr")
        XCTAssertEqual(stdoutAfter.text, "stdout-after")
        XCTAssertEqual(stdoutAfter.stream, "stdout")
    }

    func testTerminalStreamStoreMaxBatchCountsLogicalEvents() {
        let store = TerminalStreamStore(maxBatchSize: 2)
        let lease = HostSessionLease(
            hostScope: HostScope(profileID: "mac-a", installationID: "install-a", generation: 1),
            sessionID: "sess_logical_batch"
        )
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: lease.sessionID,
            turnID: "turn_logical_batch",
            itemID: "item_logical_batch",
            messageID: "message_logical_batch",
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )

        XCTAssertFalse(
            store.append(
                .assistantDelta(AgentDelta(text: "A", role: .assistant, kind: .message), metadata),
                lease: lease
            )
        )
        XCTAssertFalse(
            store.append(
                .assistantDelta(AgentDelta(text: "B", role: .assistant, kind: .message), metadata),
                lease: lease
            ),
            "两个 raw chunk 仍只算一个逻辑事件"
        )
        XCTAssertTrue(store.append(.turnStarted(metadata), lease: lease))
        XCTAssertTrue(
            store.append(
                .assistantDelta(AgentDelta(text: "C", role: .assistant, kind: .message), metadata),
                lease: lease
            )
        )

        let drained = store.drain(lease: lease)
        XCTAssertEqual(drained.count, 3)
        guard case .assistantDelta(let firstDelta, _) = drained[0],
              case .turnStarted = drained[1],
              case .assistantDelta(let secondDelta, _) = drained[2]
        else {
            return XCTFail("logical batch 应保留文本 run 与控制事件顺序")
        }
        XCTAssertEqual(firstDelta.text, "AB")
        XCTAssertEqual(secondDelta.text, "C")
    }

    func testTerminalStreamStoreReplacesOnlyContiguousPlanSnapshots() {
        let store = TerminalStreamStore(maxBatchSize: 64)
        let lease = HostSessionLease(
            hostScope: HostScope(profileID: "mac-a", installationID: "install-a", generation: 1),
            sessionID: "sess_completed_snapshots"
        )
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: lease.sessionID,
            turnID: "turn_completed_snapshots",
            itemID: "item_completed_snapshots",
            messageID: "message_completed_snapshots",
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )
        let otherItemMetadata = AgentEventMetadata(
            seq: 4,
            sessionID: lease.sessionID,
            turnID: metadata.turnID,
            itemID: "other-item",
            messageID: metadata.messageID,
            clientMessageID: nil,
            revision: 4,
            createdAt: nil
        )

        _ = store.append(
            .messageCompleted(
                AgentMessage(
                    id: "plan-old",
                    sessionID: lease.sessionID,
                    turnID: metadata.turnID,
                    itemID: metadata.itemID,
                    role: .system,
                    kind: .plan,
                    content: "旧计划",
                    revision: 1
                ),
                metadata
            ),
            lease: lease
        )
        _ = store.append(
            .messageCompleted(
                AgentMessage(
                    id: "plan-latest",
                    sessionID: lease.sessionID,
                    turnID: metadata.turnID,
                    itemID: metadata.itemID,
                    role: .system,
                    kind: .plan,
                    content: "最新完整计划",
                    revision: 2
                ),
                metadata
            ),
            lease: lease
        )
        _ = store.append(
            .messageCompleted(
                AgentMessage(
                    id: "regular-1",
                    sessionID: lease.sessionID,
                    turnID: metadata.turnID,
                    itemID: metadata.itemID,
                    role: .system,
                    kind: .message,
                    content: "普通消息一",
                    revision: 3
                ),
                metadata
            ),
            lease: lease
        )
        _ = store.append(
            .messageCompleted(
                AgentMessage(
                    id: "regular-2",
                    sessionID: lease.sessionID,
                    turnID: metadata.turnID,
                    itemID: metadata.itemID,
                    role: .system,
                    kind: .message,
                    content: "普通消息二",
                    revision: 4
                ),
                metadata
            ),
            lease: lease
        )
        _ = store.append(
            .messageCompleted(
                AgentMessage(
                    id: "plan-other-item",
                    sessionID: lease.sessionID,
                    turnID: metadata.turnID,
                    itemID: otherItemMetadata.itemID,
                    role: .system,
                    kind: .plan,
                    content: "另一 item 计划",
                    revision: 5
                ),
                otherItemMetadata
            ),
            lease: lease
        )

        let drained = store.drain(lease: lease)
        XCTAssertEqual(drained.count, 4)
        guard case .messageCompleted(let latestPlan, _) = drained[0],
              case .messageCompleted(let regularOne, _) = drained[1],
              case .messageCompleted(let regularTwo, _) = drained[2],
              case .messageCompleted(let otherItemPlan, _) = drained[3]
        else {
            return XCTFail("completed snapshot 的边界或顺序错误")
        }
        XCTAssertEqual(latestPlan.content, "最新完整计划")
        XCTAssertEqual(latestPlan.id, "plan-latest")
        XCTAssertEqual(regularOne.content, "普通消息一")
        XCTAssertEqual(regularTwo.content, "普通消息二")
        XCTAssertEqual(otherItemPlan.content, "另一 item 计划")
    }

    func testDisconnectFlushesBufferedRuntimeEventsBeforeSwitchingSession() async throws {
        let project = makeProject(id: "proj_ws_disconnect_flush")
        let running = makeSession(id: "sess_ws_disconnect_flush", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let history = makeSession(id: "sess_ws_disconnect_history", projectID: project.id, title: "历史", status: "history", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running, history], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let assistant = try AgentAPIClient.decoder.decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "rollout:disconnect-flush",
              "session_id": "\(running.id)",
              "role": "assistant",
              "kind": "message",
              "content": "断开前最后一条回复",
              "created_at": "2026-06-02T10:00:00Z",
              "revision": 1,
              "send_status": "confirmed"
            }
            """.utf8)
        )
        sockets[0].emitEvent(.messageCompleted(
            assistant,
            AgentEventMetadata(seq: 7, sessionID: running.id, turnID: "turn-flush", itemID: "item-flush", messageID: assistant.id, clientMessageID: nil, revision: 1, createdAt: nil)
        ))

        await store.selectSession(history)

        let messages = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.role == .assistant && $0.content == "断开前最后一条回复" }
        }
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.content == "断开前最后一条回复" })
        XCTAssertEqual(sockets[0].disconnectCallCount, 1)
    }

    func testWebSocketFailureAutoReconnectsWithLatestReplayWatermark() async throws {
        let project = makeProject(id: "proj_ws_reconnect")
        let running = makeSession(id: "sess_ws_reconnect", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let logStore = LogStore()
        logStore.append("旧输出", sessionID: running.id, seq: 5)
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: logStore,
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets[0].connectedSessionIDs, [running.id])
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        logStore.append("新输出", sessionID: running.id, seq: 7)
        sockets[0].emitStatus(.failed("network dropped"))
        for _ in 0..<50 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(client.requestedSessionAfterSeqs, [7])
        XCTAssertEqual(sockets[1].connectedSessionIDs, [running.id])
        sockets[1].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
    }

    func testClaudeReconnectRefreshesThreadListAuthorizationBeforeResuming() async throws {
        let project = makeProject(id: "proj_claude_restart_reconnect")
        let running = makeSession(
            id: "sess_claude_restart_reconnect",
            projectID: project.id,
            title: "Claude 运行中",
            status: "running",
            source: "claude",
            runtimeProvider: "claude"
        )
        let authorizationFillers = (1...4).map { index in
            makeSession(
                id: "sess_claude_authorization_page_\(index)",
                projectID: project.id,
                title: "Claude 历史 \(index)",
                status: "history",
                source: "claude",
                runtimeProvider: "claude"
            )
        }
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            workspaceSessions: [project.id: [running]],
            workspacePages: [
                project.id: SessionsPage(
                    sessions: [authorizationFillers[0]],
                    nextCursor: "claude_page_2",
                    hasMore: true
                )
            ],
            cursorPages: [
                "claude_page_2": SessionsPage(sessions: [authorizationFillers[1]], nextCursor: "claude_page_3", hasMore: true),
                "claude_page_3": SessionsPage(sessions: [authorizationFillers[2]], nextCursor: "claude_page_4", hasMore: true),
                "claude_page_4": SessionsPage(sessions: [authorizationFillers[3]], nextCursor: "claude_page_5", hasMore: true),
                "claude_page_5": SessionsPage(sessions: [running])
            ],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: nil, lastSeq: nil)
            ],
            messagesResult: []
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let workspaceRequestCountBeforeReconnect = client.requestedWorkspaceIDs.count

        sockets[0].emitStatus(.failed("agentd restarted"))
        for _ in 0..<80 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(
            Array(client.requestedWorkspaceCursors.dropFirst(workspaceRequestCountBeforeReconnect)),
            [nil, "claude_page_2", "claude_page_3", "claude_page_4", "claude_page_5"]
        )
        XCTAssertEqual(
            Array(client.requestedWorkspaceLimits.dropFirst(workspaceRequestCountBeforeReconnect)),
            Array(repeating: 50, count: 5)
        )
        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertEqual(sockets[1].connectedSessionIDs, [running.id])
    }

    func testClaudeReconnectAuthorizationFailsWhenSelectedSessionIsNotListed() async {
        let project = makeProject(id: "proj_claude_missing_authorization")
        let missing = makeSession(
            id: "sess_claude_missing_authorization",
            projectID: project.id,
            title: "Claude 已丢失",
            status: "history",
            source: "claude",
            runtimeProvider: "claude"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            workspacePages: [project.id: SessionsPage(sessions: [])]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.workspacesByID[project.id] = AgentWorkspace(project: project)
        store.selectedSessionID = missing.id

        do {
            try await store.authorizeClaudeSessionBeforeReconnect(
                missing,
                client: client,
                reconnectGeneration: store.webSocketReconnectGeneration
            )
            XCTFail("目标会话未进入授权列表时不应静默成功")
        } catch AgentAPIError.invalidResponse {
            XCTAssertEqual(client.requestedWorkspaceLimits.last, 50)
        } catch {
            XCTFail("应返回 invalidResponse，实际为 \(error)")
        }
    }

    func testWebSocketAutoReconnectDoesNotGiveUpWhileSessionStaysRunning() async throws {
        let project = makeProject(id: "proj_ws_persistent_reconnect")
        let running = makeSession(id: "sess_ws_persistent_reconnect", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        for attempt in 0..<6 {
            sockets[attempt].emitStatus(.failed("network dropped \(attempt)"))
            for _ in 0..<80 where sockets.count < attempt + 2 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(sockets.count, attempt + 2)
            XCTAssertEqual(sockets[attempt + 1].connectedSessionIDs, [running.id])
        }
        if case .failed = store.webSocketStatus {
            XCTFail("前台 running session 不应因重连次数达到上限而停止重连")
        }
    }

    func testStaleWebSocketStatusDoesNotRetireCurrentReconnect() async throws {
        let project = makeProject(id: "proj_ws_stale_status")
        let running = makeSession(id: "sess_ws_stale_status", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitStatus(.failed("network dropped"))
        for _ in 0..<80 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(sockets.count, 2)
        sockets[1].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitStatus(.disconnected)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.webSocketStatus, .connected)

        let sentAfterStaleStatus = await store.sendTurn(CodexAppServerTurnPayload(prompt: "after stale status"))
        XCTAssertTrue(sentAfterStaleStatus)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)
        XCTAssertEqual(sockets[1].sentTurns.count, 1)
    }

    func testConnectedRunningSessionIgnoresStaleHistoryRefreshBeforeNextSend() async throws {
        let project = makeProject(id: "proj_ws_stale_history")
        let running = makeSession(
            id: "sess_ws_stale_history",
            projectID: project.id,
            title: "长任务运行中",
            status: "running",
            source: "codex",
            activeTurnID: "turn-long-running"
        )
        let staleHistory = makeSession(
            id: running.id,
            projectID: project.id,
            title: running.title,
            status: "history",
            source: "codex",
            resumeID: running.id
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        var sockets: [MockWebSocketClient] = []
        let conversationStore = ConversationStore()
        let appStore = makeIsolatedAppStore()
        // 测试必须自行建立认证前置条件，不能依赖其他用例残留在 Keychain 的令牌。
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        let socket = try XCTUnwrap(sockets.first)
        XCTAssertEqual(sockets.count, 1)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        client.page = SessionsPage(sessions: [staleHistory])
        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertEqual(store.selectedSession?.activeTurnID, "turn-long-running")

        let sent = await store.sendTurn(CodexAppServerTurnPayload(prompt: "继续当前长任务"))

        XCTAssertTrue(sent)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertTrue(socket.sentTurns.isEmpty)
        XCTAssertFalse(conversationStore.messages(for: running.id).contains { $0.content == "已继续这个历史会话。" })

        socket.emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn-long-running",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: socket)
        XCTAssertEqual(socket.sentTurns.first?.payload.textPrompt, "继续当前长任务")
    }

    func testWebSocketReconnectKeepsSubscriptionWhenSnapshotIsNoLongerRunning() async throws {
        let project = makeProject(id: "proj_ws_ended_reconnect")
        let running = makeSession(id: "sess_ws_ended_reconnect", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let ended = makeSession(id: running.id, projectID: project.id, title: "已结束", status: "history", source: "codex", resumeID: running.id)
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: ended, recentOutput: nil, lastSeq: nil)
            ],
            messagesResult: []
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitStatus(.failed("turn completed while reconnecting"))

        // 快照显示会话不再运行时不能一次性放弃重连：单次 thread/read 可能是上游刚恢复时的
        // idle 误读。订阅对历史会话同样有效，重连应继续并恢复事件通道。
        for _ in 0..<80 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(store.selectedSession?.status, "history")
        sockets[1].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        XCTAssertNil(store.errorMessage)
    }

    func testWebSocketReconnectRefreshesSnapshotWithLatestEventWatermark() async throws {
        let project = makeProject(id: "proj_ws_snapshot_reconnect")
        let running = makeSession(id: "sess_ws_snapshot", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: nil, lastSeq: 9)
            ],
            historyPages: [
                running.id: HistoryMessagesPage(messages: [
                    CodexHistoryMessage(id: "rollout:9", role: "assistant", content: "重连前补拉消息", createdAt: Date(timeIntervalSince1970: 9))
                ])
            ]
        )
        var sockets: [MockWebSocketClient] = []
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitEvent(.assistantDelta(
            AgentDelta(text: "A", role: .assistant, kind: .message),
            AgentEventMetadata(seq: 9, sessionID: running.id, turnID: "turn_1", itemID: "item_1", messageID: nil, clientMessageID: nil, revision: 1, createdAt: nil)
        ))

        sockets[0].emitStatus(.failed("network dropped"))
        for _ in 0..<50 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertEqual(client.requestedSessionAfterSeqs, [9])
        XCTAssertEqual(sockets[1].connectedSessionIDs, [running.id])
        XCTAssertTrue(conversationStore.messages(for: running.id).contains { $0.content == "重连前补拉消息" })
    }

    func testWebSocketReconnectUsesHistorySnapshotSeqWatermark() async throws {
        let project = makeProject(id: "proj_ws_history_snapshot")
        let running = makeSession(id: "sess_ws_history_snapshot", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: nil, lastSeq: nil)
            ],
            historyPages: [
                running.id: HistoryMessagesPage(messages: [], snapshotSeq: 11)
            ]
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitStatus(.failed("network dropped"))
        for _ in 0..<50 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(client.requestedSessionAfterSeqs, [11])
        XCTAssertEqual(sockets[1].connectedSessionIDs, [running.id])
    }

    func testReturningToSessionListCancelsQueuedWebSocketReconnect() async throws {
        let project = makeProject(id: "proj_ws_cancel")
        let running = makeSession(id: "sess_ws_cancel", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 120_000_000 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitStatus(.failed("network dropped"))
        try await waitForWebSocketStatus(.connecting, store: store)

        store.returnToSessionList()
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(store.webSocketStatus, .disconnected)
    }

    func testRunningSessionAloneDoesNotShowForegroundActivity() async {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.selectedSessionID = running.id

        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testRuntimeActivityTracksTurnEventsAndClearsOnCompletion() async throws {
        let project = makeProject(id: "proj_runtime_activity")
        let running = makeSession(id: "sess_runtime_activity", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        XCTAssertNil(store.selectedRuntimeActivitySnapshot)

        sockets[0].emitEvent(.turnStarted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn-runtime",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))

        let started = try await waitForRuntimeActivity(in: store, sessionID: running.id)
        XCTAssertLessThanOrEqual(started.turnStartedAt, started.lastActivityAt)
        try await waitForSelectedActiveTurnID("turn-runtime", store: store)

        // 运行时活动在 1 秒内合并高频事件，测试需要跨过该窗口再验证时间推进。
        try await Task.sleep(nanoseconds: 1_050_000_000)
        sockets[0].emitEvent(.logDelta(
            LogDelta(text: "still working\n", stream: "stdout"),
            AgentEventMetadata(
                seq: 2,
                sessionID: running.id,
                turnID: "turn-runtime",
                itemID: "cmd-1",
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )
        ))

        let updated = try await waitForRuntimeActivity(in: store, sessionID: running.id) { snapshot in
            snapshot.lastActivityAt > started.lastActivityAt
        }
        XCTAssertEqual(updated.turnStartedAt, started.turnStartedAt)

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 3,
            sessionID: running.id,
            turnID: "turn-runtime",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))

        try await waitForRuntimeActivityCleared(in: store, sessionID: running.id)
        try await waitForSelectedActiveTurnID(nil, store: store)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)
        XCTAssertFalse(store.activeSessions.contains { $0.id == running.id })
        XCTAssertTrue(store.recentHistorySessions.contains { $0.id == running.id })
    }

    func testSendingPromptCreatesWaitingForegroundActivity() async throws {
        let project = makeProject(id: "proj_1")
        let created = makeSession(id: "sess_created", projectID: project.id, title: "新会话", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created)
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendPrompt("帮我检查项目")

        XCTAssertTrue(accepted)
        XCTAssertEqual(store.selectedForegroundActivity, .waitingForAssistant)
    }

    func testCreatingSessionForwardsStructuredPayloadAndOptions() async throws {
        let project = makeProject(id: "proj_rich_create")
        let created = makeSession(id: "sess_rich_create", projectID: project.id, title: "Rich Create", status: "running", source: "codex")
        let client = DelayedCreateSessionClient(projects: [project], sessions: [])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        var options = CodexAppServerTurnOptions.default
        options.model = "gpt-5-codex"
        options.serviceTier = "priority"
        options.approvalPolicy = .onRequest
        let payload = CodexAppServerTurnPayload(input: [
            .text("分析截图"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .skill(name: "review", path: project.path)
        ], options: options)

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let sendTask = Task { await store.sendTurn(payload) }
        await client.waitForCreateRequestCount(1)

        let sent = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(sent.prompt, payload.previewText)
        XCTAssertEqual(sent.input, payload.input)
        XCTAssertEqual(sent.turnOptions.model, "gpt-5-codex")
        XCTAssertEqual(sent.turnOptions.serviceTier, "priority")
        XCTAssertEqual(sent.turnOptions.approvalPolicy, .onRequest)

        client.resolveCreate(with: .success(try makeCreateSessionResponse(session: created)))
        let accepted = await sendTask.value
        XCTAssertTrue(accepted)
        let message = try XCTUnwrap(conversationStore.messages(for: created.id).first)
        XCTAssertTrue(payloadContainsInlineImage(message.turnPayload))
        XCTAssertTrue(payloadContainsSkill(message.turnPayload, name: "review"))
        XCTAssertEqual(message.turnPayload?.options, options)
    }

    func testStartGoalTurnOnRunningSessionSetsGoalThenSendsPayload() async throws {
        let project = makeProject(id: "proj_goal_running")
        let running = makeSession(id: "sess_goal_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let payload = CodexAppServerTurnPayload(prompt: "修复 iPad 目标入口")
        let accepted = await store.startGoalTurn(payload: payload, objective: "  修复 iPad 目标入口  ")

        XCTAssertTrue(accepted)
        try await waitForSentTurnCount(1, socket: socket)
        XCTAssertEqual(client.requestedThreadGoalSets, [
            RequestedThreadGoalSet(
                threadID: running.id,
                objective: "修复 iPad 目标入口",
                status: .active,
                tokenBudget: nil
            )
        ])
        XCTAssertEqual(socket.sentTurns.count, 1)
        XCTAssertEqual(socket.sentTurns.first?.payload.textPrompt, "修复 iPad 目标入口")
    }

    func testQueuedGoalRemainsActiveAfterItsTurnCompletes() async throws {
        let project = makeProject(id: "proj_goal_queued")
        let running = makeSession(
            id: "sess_goal_queued",
            projectID: project.id,
            title: "目标排队",
            status: "running",
            source: "codex",
            activeTurnID: "turn_before_goal"
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let accepted = await store.startGoalTurn(
            payload: CodexAppServerTurnPayload(prompt: "执行排队目标"),
            objective: "执行排队目标"
        )
        XCTAssertTrue(accepted)
        XCTAssertTrue(socket.sentTurns.isEmpty)
        XCTAssertNil(store.selectedThreadGoal, "排队目标在前一 turn 完成前不能提前改写 thread goal")

        socket.emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_before_goal",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: socket)
        try await waitForSelectedThreadGoalStatus(.active, store: store)
        XCTAssertEqual(store.selectedThreadGoal?.status, .active)
        socket.onSendAccepted?(try XCTUnwrap(socket.sentTurns.first).clientMessageID)
        try await Task.sleep(nanoseconds: 60_000_000)

        socket.emitEvent(.turnStarted(AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: "turn_goal",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID("turn_goal", store: store)
        socket.emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 3,
            sessionID: running.id,
            turnID: "turn_goal",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedSessionStatus(SessionStatus.completed.rawValue, store: store)
        XCTAssertEqual(
            store.selectedThreadGoal?.status,
            .active,
            "turn/completed 只能结束当前轮次，不能代替明确的 goal 状态更新"
        )
    }

    func testTurnCompletionKeepsActiveGoalUntilExplicitCompletionAndIgnoresStaleRefresh() async throws {
        let project = makeProject(id: "proj_goal_complete")
        let goal = ThreadGoal(
            threadID: "thread_goal_complete",
            objective: "修复完成后仍显示运行中",
            status: .active,
            tokenBudget: 80_000,
            tokensUsed: 12_000,
            timeUsedSeconds: 420
        )
        let running = AgentSession(
            id: "sess_goal_complete",
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "目标会话",
            status: "running",
            source: "codex",
            resumeID: goal.threadID,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            activeTurnID: "turn-goal-complete",
            goal: goal
        )
        let reactivatedGoal = ThreadGoal(
            threadID: goal.threadID,
            objective: goal.objective,
            status: .active,
            tokenBudget: goal.tokenBudget,
            tokensUsed: goal.tokensUsed,
            timeUsedSeconds: goal.timeUsedSeconds
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            threadGoalSetResults: [
                running.id: .success(reactivatedGoal)
            ]
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn-goal-complete",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))

        try await waitForSelectedSessionStatus(SessionStatus.completed.rawValue, store: store)
        try await waitForSelectedActiveTurnID(nil, store: store)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)
        XCTAssertNil(store.selectedSession?.activeTurnID)
        XCTAssertEqual(
            store.selectedThreadGoal?.status,
            .active,
            "目标生命周期必须由 goal 事件或用户操作驱动，不能从普通 turn 完成推断"
        )

        let completedGoal = ThreadGoal(
            threadID: goal.threadID,
            objective: goal.objective,
            status: .complete,
            tokenBudget: goal.tokenBudget,
            tokensUsed: goal.tokensUsed,
            timeUsedSeconds: goal.timeUsedSeconds
        )
        sockets[0].emitEvent(.goalUpdated(completedGoal, AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedThreadGoalStatus(.complete, store: store)

        sockets[0].emitEvent(.goalUpdated(goal, AgentEventMetadata(
            seq: 3,
            sessionID: running.id,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        sockets[0].emitEvent(.session(running))

        try await waitForSelectedThreadGoalStatus(.complete, store: store)

        await store.updateSelectedThreadGoalStatus(.active)

        try await waitForSelectedThreadGoalStatus(.active, store: store)
        XCTAssertEqual(client.requestedThreadGoalSets.last, RequestedThreadGoalSet(
            threadID: running.id,
            objective: nil,
            status: .active,
            tokenBudget: nil
        ))
    }

    func testSelectedThreadGoalStaysScopedToSelectedThread() async throws {
        let project = makeProject(id: "proj_goal_scope")
        let goal = ThreadGoal(
            threadID: "thread-with-goal",
            objective: "只属于对话一的目标",
            status: .active,
            tokenBudget: 50_000
        )
        let goalSession = AgentSession(
            id: "codex_thread_with_goal",
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "对话一",
            status: "closed",
            source: "codex",
            resumeID: goal.threadID,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            goal: goal
        )
        let staleContext = SessionContextSnapshot(
            sessionID: "thread-without-goal",
            threadID: "thread-without-goal",
            goal: goal,
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        let plainSession = AgentSession(
            id: "thread-without-goal",
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "对话二",
            status: "closed",
            source: "codex",
            resumeID: "thread-without-goal",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 3),
            context: staleContext
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [goalSession, plainSession], messagesResult: [])
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)

        await store.selectSession(goalSession)
        XCTAssertEqual(store.selectedThreadGoal?.threadID, goal.threadID)
        XCTAssertEqual(store.selectedThreadGoal?.objective, "只属于对话一的目标")

        await store.selectSession(plainSession)
        XCTAssertNil(store.selectedThreadGoal)
        XCTAssertNil(store.selectedSession?.goal)
    }

    func testStartGoalTurnForNewSessionCarriesInitialGoalObjective() async throws {
        let project = makeProject(id: "proj_goal_create")
        let created = makeSession(id: "sess_goal_create", projectID: project.id, title: "目标任务", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptions: [
                CodexAppServerModelOption(id: "gpt-goal-default", title: "Goal Default", provider: "openai", isDefault: true)
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let payload = CodexAppServerTurnPayload(prompt: "实现 iPad 目标任务")
        let accepted = await store.startGoalTurn(payload: payload, objective: "  实现 iPad 目标任务  ")

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.prompt, "实现 iPad 目标任务")
        XCTAssertEqual(createPayload.initialGoalObjective, "实现 iPad 目标任务")
        XCTAssertEqual(createPayload.input, payload.input)
        XCTAssertEqual(createPayload.turnOptions.model, "gpt-goal-default")
        XCTAssertEqual(createPayload.turnOptions.collaborationMode, .default)
        XCTAssertEqual(store.selectedSessionID, created.id)
    }

    func testRefreshAppServerModelOptionsCachesDynamicList() async throws {
        let options = [
            CodexAppServerModelOption(id: "gpt-5.1-codex", title: "GPT-5.1 Codex", provider: "openai", isDefault: true),
            CodexAppServerModelOption(id: "gpt-5-codex", title: "GPT-5 Codex", provider: "openai")
        ]
        let client = MockSessionStoreClient(projects: [], sessions: [], modelOptions: options)
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAppServerModelOptions(force: true)

        XCTAssertEqual(store.appServerModelOptions.map(\.model), ["gpt-5.1-codex", "gpt-5-codex"])
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testClaudeUsageChannelUsesConfigAvailabilityWhenModelListFails() async {
        let claudeRateLimit = RateLimitSummary(
            limitID: "claude",
            limitName: "Claude",
            availability: "unavailable",
            unavailableReason: "headless_statusline_unavailable"
        )
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            modelOptionsError: MockError.unimplemented,
            runtimeChannelAvailability: ["claude": true],
            rateLimitsByRuntime: ["claude": claudeRateLimit]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAppServerModelOptions(force: true)
        await store.refreshClaudeUsage()

        XCTAssertTrue(store.isClaudeRuntimeChannelAvailable)
        XCTAssertTrue(store.hasClaudeRuntimeChannel)
        XCTAssertTrue(store.appServerModelOptions.isEmpty)
        XCTAssertEqual(client.requestedRateLimitProviders, ["claude"])
        XCTAssertEqual(store.accountClaudeUsageWindowsDisplay.displayName, "Claude")
        XCTAssertEqual(
            store.accountClaudeUsageWindowsDisplay.creditText,
            L10n.text("ui.headless_no_quota_percentage_yet")
        )
        XCTAssertEqual(store.accountCodexUsageWindowsDisplay.displayName, "Codex")
        XCTAssertFalse(store.accountCodexUsageWindowsDisplay.hasLiveData)
    }

    func testClaudeUsageRefreshIsProviderScopedAndCoalescesDuplicateTaps() async {
        let gate = UsageRefreshGate()
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            rateLimitHandler: { provider in
                await gate.response(for: provider)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let claudeRefresh = Task { await store.refreshClaudeUsage() }
        await gate.waitForRequest(provider: "claude")
        XCTAssertTrue(store.isRefreshingUsage(runtimeProvider: "claude"))
        XCTAssertFalse(store.isRefreshingUsage(runtimeProvider: "codex"))

        let duplicateClaudeRefresh = Task { await store.refreshClaudeUsage() }
        let codexRefresh = Task { await store.refreshCodexUsage() }
        await codexRefresh.value
        await duplicateClaudeRefresh.value

        let claudeRequestCount = await gate.requestCount(provider: "claude")
        let codexRequestCount = await gate.requestCount(provider: "codex")
        XCTAssertEqual(claudeRequestCount, 1)
        XCTAssertEqual(codexRequestCount, 1)
        XCTAssertTrue(store.isRefreshingUsage(runtimeProvider: "claude"))
        XCTAssertFalse(store.isRefreshingUsage(runtimeProvider: "codex"))

        await gate.finishClaude()
        await claudeRefresh.value
        XCTAssertFalse(store.isRefreshingUsage(runtimeProvider: "claude"))
        XCTAssertEqual(store.accountRateLimitsByRuntime["claude"]?.primaryUsedPercent, 30)
    }

    func testSettingsAccountOverviewDoesNotWaitForSlowClaudeUsageBeforeTokenActivity() async {
        let gate = UsageRefreshGate()
        let tokenActivityStarted = expectation(description: "Token activity request started")
        let buckets = [AccountTokenUsageDailyBucket(startDate: "2026-08-18", tokens: 42)]
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            runtimeChannelAvailability: ["claude": true],
            rateLimitHandler: { provider in
                await gate.response(for: provider)
            },
            accountTokenUsageHandler: {
                tokenActivityStarted.fulfill()
                return AccountTokenUsageSnapshot(
                    summary: AccountTokenUsageSummary(lifetimeTokens: 42),
                    dailyUsageBuckets: buckets
                )
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let refresh = Task { await store.refreshSettingsAccountOverview() }
        await gate.waitForRequest(provider: "claude")
        await fulfillment(of: [tokenActivityStarted], timeout: 1)

        XCTAssertTrue(store.isRefreshingUsage(runtimeProvider: "claude"))
        XCTAssertEqual(store.accountTokenActivity.displayBuckets, buckets)

        await gate.finishClaude()
        await refresh.value
        XCTAssertFalse(store.isRefreshingUsage(runtimeProvider: "claude"))
    }

    func testClaudeAuthenticationWarmupFailureStaysSilent() async {
        let project = makeProject(id: "proj_claude_warm_silent")
        let session = makeSession(
            id: "sess_claude_warm_silent",
            projectID: project.id,
            title: "Claude 预热失败",
            status: "history",
            source: "claude",
            runtimeProvider: "claude"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            messagesResult: [],
            rateLimitHandler: { _ in throw MockError.unimplemented }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.warmSelectedClaudeAuthentication()

        XCTAssertEqual(client.requestedRateLimitProviders, ["claude"])
        XCTAssertNil(store.errorMessage, "后台预热失败不得污染当前会话错误横幅")
        XCTAssertEqual(store.selectedSession?.status, "history")
    }

    func testClaudeTurnCanSendWhileAuthenticationWarmupIsInFlight() async throws {
        let project = makeProject(id: "proj_claude_warm_send")
        let history = makeSession(
            id: "sess_claude_warm_send",
            projectID: project.id,
            title: "Claude 预热并发送",
            status: "closed",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "thread-claude-warm-send"
        )
        let resumed = makeSession(
            id: "sess_claude_warm_send_resumed",
            projectID: project.id,
            title: "Claude 预热并发送",
            status: "running",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "thread-claude-warm-send"
        )
        let gate = UsageRefreshGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: resumed),
            messagesResult: [],
            modelOptions: [
                CodexAppServerModelOption(
                    id: "sonnet",
                    title: "Claude Sonnet 5",
                    provider: "anthropic",
                    runtimeProvider: "claude",
                    isDefault: true
                )
            ],
            rateLimitHandler: { provider in
                await gate.response(for: provider)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        let warmup = Task { await store.warmSelectedClaudeAuthentication() }
        await gate.waitForRequest(provider: "claude")
        XCTAssertTrue(store.isRefreshingUsage(runtimeProvider: "claude"))

        let sent = await store.sendTurn(CodexAppServerTurnPayload(prompt: "预热期间继续发送"))
        XCTAssertTrue(sent)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.resumeID, "thread-claude-warm-send")
        XCTAssertEqual(createPayload.prompt, "预热期间继续发送")
        XCTAssertEqual(createPayload.turnOptions.runtimeProvider, "claude")

        await gate.finishClaude()
        await warmup.value
        XCTAssertFalse(store.isRefreshingUsage(runtimeProvider: "claude"))
    }

    func testHealthyUsageRefreshClearsStaleQuotaError() async {
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            rateLimitsByRuntime: ["codex": RateLimitSummary(primaryUsedPercent: 42)]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.setErrorMessage("Your Codex message limit has been exhausted.")
        XCTAssertNotNil(store.selectedQuotaNotice)

        await store.refreshSelectedUsage()

        XCTAssertEqual(client.requestedRateLimitProviders, ["codex"])
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.selectedQuotaNotice)
    }

    func testNewSessionResolvesMissingModelFromAppServerDefaultBeforeCreate() async throws {
        let project = makeProject(id: "proj_resolve_model_create")
        let created = makeSession(id: "sess_resolve_model_create", projectID: project.id, title: "模型解析", status: "running", source: "codex")
        let options = [
            CodexAppServerModelOption(id: "gpt-dynamic-default", title: "Dynamic Default", provider: "openai", isDefault: true),
            CodexAppServerModelOption(id: "gpt-other", title: "Other", provider: "openai")
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptions: options
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "检查默认模型"))

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        // app-server turn/start 必填 model；iPad 发送前必须用 model/list 的默认项补齐，而不是省略。
        XCTAssertEqual(createPayload.turnOptions.model, "gpt-dynamic-default")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "openai")
        XCTAssertNil(createPayload.turnOptions.runtimeProvider)
        XCTAssertEqual(createPayload.turnOptions.collaborationMode, .default)
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testDefaultModelResolutionCarriesRuntimeProviderBeforeCreate() async throws {
        let project = makeProject(id: "proj_default_runtime_create")
        let created = makeSession(id: "sess_default_runtime_create", projectID: project.id, title: "默认 Claude 模型", status: "running", source: "claude", runtimeProvider: "claude")
        let options = [
            CodexAppServerModelOption(id: "claude-sonnet", title: "Claude Sonnet", provider: "anthropic", runtimeProvider: "claude", isDefault: true)
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptions: options
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "检查 Claude 默认模型"))

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.turnOptions.runtimeProvider, "claude")
        XCTAssertEqual(createPayload.turnOptions.model, "claude-sonnet")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "anthropic")
        XCTAssertEqual(createPayload.turnOptions.sandboxMode, .workspaceWrite)
        XCTAssertEqual(createPayload.turnOptions.networkAccess, false)
    }

    func testUnknownExplicitModelIsValidatedAndFallsBackBeforeCreate() async throws {
        let project = makeProject(id: "proj_explicit_model_create")
        let created = makeSession(id: "sess_explicit_model_create", projectID: project.id, title: "显式模型", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptions: [
                CodexAppServerModelOption(id: "gpt-should-not-load", title: "Should Not Load", provider: "openai", isDefault: true)
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        var options = CodexAppServerTurnOptions.default
        options.model = "gpt-user-selected"
        options.modelProvider = "custom-provider"
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "使用显式模型", options: options))

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.turnOptions.model, "gpt-should-not-load")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "openai")
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testCodexHistorySessionIgnoresStaleClaudeModelSelectionBeforeResume() async throws {
        let project = makeProject(id: "proj_codex_history_runtime_lock")
        let history = makeSession(
            id: "sess_codex_history_runtime_lock",
            projectID: project.id,
            title: "Codex 历史会话",
            status: "closed",
            source: "codex",
            resumeID: "thread-codex-history-runtime-lock"
        )
        let resumed = makeSession(
            id: "sess_codex_history_runtime_lock_resumed",
            projectID: project.id,
            title: "Codex 历史会话",
            status: "running",
            source: "codex",
            resumeID: "thread-codex-history-runtime-lock"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: resumed),
            messagesResult: [],
            modelOptions: [
                CodexAppServerModelOption(id: "gpt-codex-default", title: "Codex Default", provider: "openai", runtimeProvider: "codex", isDefault: true),
                CodexAppServerModelOption(id: "sonnet", title: "Claude Sonnet 5", provider: "anthropic", runtimeProvider: "claude", isDefault: true)
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        var options = CodexAppServerTurnOptions.default
        options.runtimeProvider = "claude"
        options.model = "opus"
        options.modelProvider = "anthropic"
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "继续 Codex 历史会话", options: options))

        XCTAssertTrue(accepted)
        let createPayload: CreateSessionRequest = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.resumeID, "thread-codex-history-runtime-lock")
        XCTAssertNil(createPayload.turnOptions.runtimeProvider)
        XCTAssertEqual(createPayload.turnOptions.model, "gpt-codex-default")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "openai")
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testClaudeHistorySessionIgnoresStaleCodexModelSelectionBeforeResume() async throws {
        let project = makeProject(id: "proj_claude_history_runtime_lock")
        let history = makeSession(
            id: "sess_claude_history_runtime_lock",
            projectID: project.id,
            title: "Claude 历史会话",
            status: "closed",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "thread-claude-history-runtime-lock"
        )
        let resumed = makeSession(
            id: "sess_claude_history_runtime_lock_resumed",
            projectID: project.id,
            title: "Claude 历史会话",
            status: "running",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "thread-claude-history-runtime-lock"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: resumed),
            messagesResult: [],
            modelOptions: [
                CodexAppServerModelOption(id: "gpt-codex-default", title: "Codex Default", provider: "openai", runtimeProvider: "codex", isDefault: true),
                CodexAppServerModelOption(id: "sonnet", title: "Claude Sonnet 5", provider: "anthropic", runtimeProvider: "claude", isDefault: true)
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        var options = CodexAppServerTurnOptions.default
        options.runtimeProvider = nil
        options.model = "gpt-codex-default"
        options.modelProvider = "openai"
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "继续 Claude 历史会话", options: options))

        XCTAssertTrue(accepted)
        let createPayload: CreateSessionRequest = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.resumeID, "thread-claude-history-runtime-lock")
        XCTAssertEqual(createPayload.turnOptions.runtimeProvider, "claude")
        XCTAssertEqual(createPayload.turnOptions.model, "sonnet")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "anthropic")
        XCTAssertEqual(createPayload.turnOptions.sandboxMode, .workspaceWrite)
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testExplicitClaudeModelClampsDangerFullAccessBeforeCreate() async throws {
        let project = makeProject(id: "proj_explicit_claude_clamp")
        let created = makeSession(id: "sess_explicit_claude_clamp", projectID: project.id, title: "Claude Clamp", status: "running", source: "claude", runtimeProvider: "claude")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptions: [
                CodexAppServerModelOption(
                    id: "sonnet",
                    title: "Claude Sonnet",
                    provider: "anthropic",
                    runtimeProvider: "claude",
                    isDefault: true
                )
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        var options = CodexAppServerTurnOptions.default
        options.runtimeProvider = "claude"
        options.model = "SONNET"
        options.modelProvider = "anthropic"
        options.sandboxMode = .dangerFullAccess
        options.networkAccess = true
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "使用 Claude", options: options))

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.turnOptions.runtimeProvider, "claude")
        XCTAssertEqual(createPayload.turnOptions.model, "sonnet")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "anthropic")
        XCTAssertEqual(createPayload.turnOptions.sandboxMode, .workspaceWrite)
        XCTAssertEqual(createPayload.turnOptions.networkAccess, false)
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testDeveloperModelPolicyKeepsUnlistedModelBeforeCreate() async throws {
        let project = makeProject(id: "proj_unlisted_developer_model")
        let created = makeSession(
            id: "sess_unlisted_developer_model",
            projectID: project.id,
            title: "Developer Model",
            status: "running",
            source: "claude",
            runtimeProvider: "claude"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created)
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        var options = CodexAppServerTurnOptions.default
        options.runtimeProvider = "claude"
        options.model = "private-model-alias"
        options.modelProvider = "anthropic"
        options.modelSelectionPolicy = .allowUnlisted
        let accepted = await store.sendTurn(
            CodexAppServerTurnPayload(prompt: "使用开发者自定义模型", options: options)
        )

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.turnOptions.model, "private-model-alias")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "anthropic")
        XCTAssertEqual(createPayload.turnOptions.modelSelectionPolicy, .allowUnlisted)
        XCTAssertEqual(client.modelOptionsCallCount, 0)
    }

    func testModelListFailureFallsBackToBuiltInModelBeforeCreate() async throws {
        let project = makeProject(id: "proj_model_fallback_create")
        let created = makeSession(id: "sess_model_fallback_create", projectID: project.id, title: "模型兜底", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptionsError: MockError.timeout
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "模型列表失败也要能发"))

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.turnOptions.model, "gpt-5.6-sol")
        XCTAssertNil(createPayload.turnOptions.modelProvider)
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testEmptyPayloadDoesNotRefreshModelOptions() async throws {
        let project = makeProject(id: "proj_empty_payload_model")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            modelOptions: [
                CodexAppServerModelOption(id: "gpt-unused", title: "Unused", provider: "openai", isDefault: true)
            ]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "   "))

        XCTAssertFalse(accepted)
        XCTAssertEqual(client.modelOptionsCallCount, 0)
        XCTAssertTrue(client.createPayloads.isEmpty)
    }

    func testRunningQueuedTurnResolvesMissingModelButGuidedFollowUpDoesNot() async throws {
        let project = makeProject(id: "proj_running_resolve_model")
        let running = makeSession(
            id: "sess_running_resolve_model",
            projectID: project.id,
            title: "运行中模型解析",
            status: "running",
            source: "codex",
            activeTurnID: "turn_active_model"
        )
        let options = [
            CodexAppServerModelOption(id: "gpt-running-default", title: "Running Default", provider: "openai", isDefault: true)
        ]
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [], modelOptions: options)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "排队新任务"))
        let guided = await store.sendTurn(CodexAppServerTurnPayload(prompt: "继续当前回复"), runningDelivery: .guided)

        XCTAssertTrue(queued)
        XCTAssertTrue(guided)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)
        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_active_model",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: sockets[0])
        let queuedPayload = try XCTUnwrap(sockets[0].sentTurns.first?.payload)
        XCTAssertEqual(queuedPayload.options.model, "gpt-running-default")
        XCTAssertEqual(queuedPayload.options.modelProvider, "openai")
        let guidedPayload = try XCTUnwrap(sockets[0].sentGuidance.first?.payload)
        // guided follow-up 走 turn/steer，不启动新 turn/start，因此不补 model、不携带 collaborationMode 参数。
        XCTAssertNil(guidedPayload.options.model)
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testNewSessionPromptLocalEchoConfirmsWithoutDuplicateWhenCreateReturns() async throws {
        let project = makeProject(id: "proj_local_echo")
        let created = makeSession(id: "sess_created_echo", projectID: project.id, title: "新会话", status: "running", source: "codex")
        let client = DelayedCreateSessionClient(projects: [project], sessions: [])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let sendTask = Task { await store.sendPrompt("帮我检查项目") }
        await client.waitForCreateRequestCount(1)

        let optimisticSessionID = try XCTUnwrap(store.selectedSessionID)
        let optimisticSession = try XCTUnwrap(store.selectedSession)
        XCTAssertTrue(optimisticSessionID.hasPrefix("local:"))
        XCTAssertEqual(store.controlState(for: optimisticSession), .ipadOwned)
        XCTAssertTrue(store.canControlSession(optimisticSession))
        XCTAssertFalse(store.isSelectedSessionObserving)
        XCTAssertNil(store.selectedSessionControlNotice)
        XCTAssertEqual(conversationStore.messages(for: optimisticSessionID).map(\.content), ["帮我检查项目"])
        XCTAssertEqual(conversationStore.messages(for: optimisticSessionID).first?.sendStatus, .sending)

        let clientMessageID = try XCTUnwrap(client.createPayloads.first?.clientMessageID)
        let firstMessageJSON = """
        "first_message": {
          "id": "client:\(clientMessageID)",
          "session_id": "\(created.id)",
          "client_message_id": "\(clientMessageID)",
          "role": "user",
          "kind": "message",
          "content": "帮我检查项目",
          "revision": 1,
          "send_status": "confirmed"
        }
        """
        client.resolveCreate(with: .success(try makeCreateSessionResponse(session: created, firstMessageJSON: firstMessageJSON)))

        let sendSucceeded = await sendTask.value
        XCTAssertTrue(sendSucceeded)
        XCTAssertEqual(store.selectedSessionID, created.id)
        XCTAssertEqual(store.controlState(for: try XCTUnwrap(store.selectedSession)), .ipadOwned)
        XCTAssertFalse(store.isSelectedSessionObserving)
        XCTAssertNil(store.selectedSessionControlNotice)
        XCTAssertEqual(
            store.lastSelectionCommit?.reason,
            .identityReplacement(previousID: optimisticSessionID)
        )
        XCTAssertFalse(store.sessions.contains { $0.id == optimisticSessionID })
        XCTAssertTrue(conversationStore.messages(for: optimisticSessionID).isEmpty)
        let messages = conversationStore.messages(for: created.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.clientMessageID, clientMessageID)
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(messages.first?.stableID, "client:\(clientMessageID)")
    }

    func testDelayedCreateMigratesOptimisticDataWithoutReclaimingSelectionOrSocket() async throws {
        let project = makeProject(id: "proj_delayed_create_selection")
        let second = makeSession(
            id: "thread_user_selected_b",
            projectID: project.id,
            title: "B",
            status: "history",
            source: "codex"
        )
        let created = makeSession(
            id: "thread_delayed_created_a",
            projectID: project.id,
            title: "A",
            status: "running",
            source: "codex"
        )
        let client = DelayedCreateSessionClient(projects: [project], sessions: [second])
        let conversationStore = ConversationStore()
        let socket = MockWebSocketClient()
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { socket }
        )
        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(second)

        let createTask = Task {
            await store.createSession(
                projectID: project.id,
                prompt: "创建 A",
                resume: nil,
                clientMessageID: "client-delayed-a"
            )
        }
        await client.waitForCreateRequestCount(1)
        let optimisticID = try XCTUnwrap(store.selectedSessionID)
        XCTAssertTrue(optimisticID.hasPrefix("local:"))

        await store.selectSession(second)
        client.resolveCreate(with: .success(try makeCreateSessionResponse(session: created)))
        let didCreate = await createTask.value
        XCTAssertTrue(didCreate)

        XCTAssertEqual(store.selectedSessionID, second.id)
        XCTAssertEqual(store.connectedSessionID, second.id)
        XCTAssertEqual(socket.connectedSessionIDs.last, second.id)
        XCTAssertTrue(store.sessions.contains { $0.id == created.id })
        XCTAssertFalse(store.sessions.contains { $0.id == optimisticID })
        XCTAssertTrue(conversationStore.messages(for: optimisticID).isEmpty)
        XCTAssertEqual(conversationStore.messages(for: created.id).map(\.content), ["创建 A"])
    }

    func testDelayedHistoryResumeCompletesWithoutReclaimingLaterSelection() async throws {
        let project = makeProject(id: "proj_delayed_resume_selection")
        let history = makeSession(
            id: "thread_resume_source_a",
            projectID: project.id,
            title: "历史 A",
            status: "history",
            source: "codex",
            resumeID: "resume-source-a"
        )
        let second = makeSession(
            id: "thread_resume_selected_b",
            projectID: project.id,
            title: "用户 B",
            status: "history",
            source: "codex"
        )
        let resumed = makeSession(
            id: "thread_resumed_real_a",
            projectID: project.id,
            title: "继续 A",
            status: "running",
            source: "codex"
        )
        let client = DelayedCreateSessionClient(projects: [project], sessions: [history, second])
        let conversationStore = ConversationStore()
        let socket = MockWebSocketClient()
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { socket }
        )
        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)

        let resumeTask = Task {
            await store.createSession(
                projectID: project.id,
                prompt: "继续处理 A",
                resume: history,
                clientMessageID: "client-resume-a"
            )
        }
        await client.waitForCreateRequestCount(1)
        XCTAssertEqual(store.selectedSessionID, history.id)

        await store.selectSession(second)
        client.resolveCreate(with: .success(try makeCreateSessionResponse(session: resumed)))
        let didResume = await resumeTask.value

        XCTAssertTrue(didResume)
        XCTAssertEqual(store.selectedSessionID, second.id)
        XCTAssertEqual(store.connectedSessionID, second.id)
        XCTAssertEqual(socket.connectedSessionIDs.last, second.id)
        XCTAssertTrue(store.sessions.contains { $0.id == resumed.id })
        XCTAssertEqual(conversationStore.messages(for: resumed.id).map(\.content), ["继续处理 A"])
    }

    func testNewSessionPromptFailureKeepsFailedLocalEcho() async throws {
        let project = makeProject(id: "proj_local_echo_fail")
        let client = DelayedCreateSessionClient(projects: [project], sessions: [])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let sendTask = Task { await store.sendPrompt("失败也要留在时间线") }
        await client.waitForCreateRequestCount(1)

        let optimisticSessionID = try XCTUnwrap(store.selectedSessionID)
        XCTAssertEqual(conversationStore.messages(for: optimisticSessionID).first?.sendStatus, .sending)

        client.resolveCreate(with: .failure(MockError.unimplemented))

        let sendSucceeded = await sendTask.value
        XCTAssertFalse(sendSucceeded)
        XCTAssertEqual(store.selectedSessionID, optimisticSessionID)
        XCTAssertEqual(store.selectedSession?.status, "failed")
        XCTAssertEqual(conversationStore.messages(for: optimisticSessionID).first?.content, "失败也要留在时间线")
        XCTAssertEqual(conversationStore.messages(for: optimisticSessionID).first?.sendStatus, .failed)
    }

    func testActiveTurnConflictKeepsSessionAndPendingInputAlive() async throws {
        let project = makeProject(id: "proj_active_conflict")
        let history = makeSession(
            id: "sess_active_conflict",
            projectID: project.id,
            title: "旧任务",
            status: "history",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "sess_active_conflict"
        )
        let pendingInput = AgentUserInputRequest(
            id: "input-live",
            threadID: history.id,
            turnID: "turn-live",
            itemID: "item-live",
            questions: [
                AgentUserInputQuestion(
                    id: "scope",
                    header: "范围",
                    question: "继续前先确认？",
                    isOther: true,
                    isSecret: false,
                    options: []
                )
            ]
        )
        var authoritative = history
        authoritative.status = "running"
        authoritative.activeTurnID = "turn-live"
        authoritative.pendingUserInput = nil

        let client = DelayedCreateSessionClient(projects: [project], sessions: [history])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        // 模拟列表状态已经陈旧为 history，但实时事件留下的补充问题仍在本地。
        // 这种不一致正是 active_turn 冲突恢复不能覆盖的现场状态。
        store.updateSession(history.id) { item in
            item.status = "history"
            item.pendingUserInput = pendingInput
        }
        let sendTask = Task { await store.sendPrompt("这条不能覆盖旧任务") }
        await client.waitForCreateRequestCount(1)
        client.resolveCreate(with: .failure(
            CodexAppServerSessionRuntimeError.activeTurnConflict(
                session: authoritative,
                activeTurnID: "turn-live"
            )
        ))

        let didSend = await sendTask.value
        XCTAssertFalse(didSend)
        XCTAssertEqual(store.selectedSession?.activeTurnID, "turn-live")
        XCTAssertEqual(store.selectedSession?.status, "waiting_for_input")
        XCTAssertEqual(store.selectedSession?.pendingUserInput, pendingInput)
        XCTAssertEqual(
            conversationStore.messages(for: history.id).first { $0.content == "这条不能覆盖旧任务" }?.sendStatus,
            .failed
        )
        XCTAssertEqual(sockets.last?.connectedSessionIDs.last, history.id)
        XCTAssertNil(store.errorMessage)
    }

    func testNewSessionRichPayloadFailureKeepsInlineImageForRetry() async throws {
        let project = makeProject(id: "proj_rich_echo_fail")
        let client = DelayedCreateSessionClient(projects: [project], sessions: [])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        let payload = CodexAppServerTurnPayload(input: [
            .text("失败后重试图片"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .mention(name: "README", path: project.path)
        ])

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let sendTask = Task { await store.sendTurn(payload) }
        await client.waitForCreateRequestCount(1)

        client.resolveCreate(with: .failure(MockError.unimplemented), at: 0)
        let sendSucceeded = await sendTask.value

        XCTAssertFalse(sendSucceeded)
        let optimisticSessionID = try XCTUnwrap(store.selectedSessionID)
        let failedMessage = try XCTUnwrap(conversationStore.messages(for: optimisticSessionID).first)
        XCTAssertEqual(failedMessage.sendStatus, .failed)
        XCTAssertTrue(payloadContainsInlineImage(failedMessage.turnPayload))
        XCTAssertEqual(failedMessage.turnPayload?.input, payload.input)
        XCTAssertEqual(failedMessage.turnPayload?.options.model, "gpt-5.6-sol")

        let retryTask = Task { await store.retryFailedUserMessage(failedMessage) }
        await client.waitForCreateRequestCount(2)
        XCTAssertEqual(client.createPayloads[1].input, payload.input)
        XCTAssertEqual(client.createPayloads[1].turnOptions.model, "gpt-5.6-sol")
        XCTAssertTrue(client.createPayloads[1].input.contains { item in
            if case .image(let url, _) = item {
                return url == "data:image/png;base64,AA=="
            }
            return false
        })
        client.resolveCreate(with: .failure(MockError.unimplemented), at: 1)
        let retrySucceeded = await retryTask.value
        XCTAssertFalse(retrySucceeded)
    }

    func testFailedRunningMessageRetryReusesClientMessageID() async throws {
        let project = makeProject(id: "proj_retry")
        let running = makeSession(
            id: "sess_retry",
            projectID: project.id,
            title: "运行中",
            status: "running",
            source: "codex",
            activeTurnID: "turn-existing"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        conversationStore.appendLocalUser("请重试", sessionID: running.id, clientMessageID: "client-retry", sendStatus: .failed)
        let failedMessage = try XCTUnwrap(conversationStore.messages(for: running.id).first {
            $0.clientMessageID == "client-retry"
        })

        let retried = await store.retryFailedUserMessage(failedMessage)

        XCTAssertTrue(retried)
        XCTAssertTrue(sockets[0].sentInputs.isEmpty)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)
        XCTAssertEqual(store.selectedQueuedTurns.first?.clientMessageID, "client-retry")
        XCTAssertEqual(store.selectedQueuedTurns.first?.expectedTurnID, "turn-existing")
        let messages = conversationStore.messages(for: running.id)
        let retriedMessages = messages.filter { $0.clientMessageID == "client-retry" }
        XCTAssertEqual(retriedMessages.count, 1)
        XCTAssertEqual(retriedMessages.first?.sendStatus, .local)

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn-existing",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSentTurnCount(1, socket: sockets[0])
        XCTAssertEqual(sockets[0].sentTurns.first?.payload.textPrompt, "请重试")
        XCTAssertEqual(sockets[0].sentTurns.first?.clientMessageID, "client-retry")
        XCTAssertEqual(
            conversationStore.messages(for: running.id).first { $0.clientMessageID == "client-retry" }?.sendStatus,
            .sending
        )
        sockets[0].onSendAccepted?("client-retry")
        let acceptedMessages = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.clientMessageID == "client-retry" && $0.sendStatus == .sent }
        }
        XCTAssertEqual(acceptedMessages.first { $0.clientMessageID == "client-retry" }?.sendStatus, .sent)
    }

    func testClaudeAuthenticationRecoveryRetriesOriginalRequestOnlyAfterExplicitAction() async throws {
        let project = makeProject(id: "proj_claude_auth_retry")
        let failed = makeSession(
            id: "claude_auth_failed",
            projectID: project.id,
            title: "Claude 登录失效",
            status: "failed",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "claude_auth_failed"
        )
        let client = DelayedCreateSessionClient(projects: [project], sessions: [failed])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        let originalPayload = CodexAppServerTurnPayload(prompt: "继续完成原来的任务")

        await store.refreshAll(autoAttach: false)
        await store.selectSession(failed)
        conversationStore.appendLocalUser(
            originalPayload.previewText,
            sessionID: failed.id,
            clientMessageID: "original-client-message",
            sendStatus: .sent,
            turnPayload: originalPayload
        )
        XCTAssertTrue(conversationStore.bindTurnID(
            "failed-turn",
            clientMessageID: "original-client-message",
            sessionID: failed.id
        ))
        conversationStore.appendLocalUser(
            "认证错误到达前发送的另一条请求",
            sessionID: failed.id,
            clientMessageID: "newer-client-message",
            sendStatus: .sent,
            turnPayload: CodexAppServerTurnPayload(prompt: "认证错误到达前发送的另一条请求")
        )
        XCTAssertTrue(conversationStore.bindTurnID(
            "newer-turn",
            clientMessageID: "newer-client-message",
            sessionID: failed.id
        ))
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: failed.id,
            turnID: "failed-turn",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        conversationStore.completeMessage(
            AgentMessage(
                id: "runtime-error:failed-turn",
                sessionID: failed.id,
                turnID: "failed-turn",
                role: .system,
                kind: .error,
                content: ClaudeAuthenticationRecovery.recoveryMessage,
                activityPayload: ClaudeAuthenticationRecovery.activityPayload
            ),
            metadata: metadata,
            fallbackSessionID: failed.id
        )
        let failure = try XCTUnwrap(conversationStore.messages(for: failed.id).first {
            $0.activityPayload?.isClaudeAuthenticationRecovery == true
        })

        XCTAssertTrue(client.createPayloads.isEmpty, "认证错误不能自动重复用户请求")
        let retryTask = Task { await store.retryClaudeAuthenticationFailure(failure) }
        await client.waitForCreateRequestCount(1)

        XCTAssertEqual(client.createPayloads[0].input, originalPayload.input)
        XCTAssertEqual(client.createPayloads[0].turnOptions.runtimeProvider, "claude")
        client.resolveCreate(with: .failure(MockError.unimplemented))
        let didRetry = await retryTask.value
        XCTAssertFalse(didRetry)

        let unmatchedFailure = ConversationMessage(
            turnID: "unmatched-turn",
            role: .system,
            kind: .error,
            content: ClaudeAuthenticationRecovery.recoveryMessage,
            activityPayload: ClaudeAuthenticationRecovery.activityPayload
        )
        let didRetryUnmatchedFailure = await store.retryClaudeAuthenticationFailure(unmatchedFailure)
        XCTAssertFalse(didRetryUnmatchedFailure)
        XCTAssertEqual(client.createPayloads.count, 1, "没有精确 turn 绑定时不得猜测并重发最近请求")
    }

    func testFailedRunningMessageRetryDoesNotResumeWhenWebSocketIsConnecting() async throws {
        let project = makeProject(id: "proj_retry_connecting_guard")
        let running = makeSession(id: "sess_retry_connecting_guard", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        try await waitForWebSocketStatus(.connecting, store: store)
        conversationStore.appendLocalUser("重试不要新建会话", sessionID: running.id, clientMessageID: "client-retry-connecting", sendStatus: .failed)
        let failedMessage = try XCTUnwrap(conversationStore.messages(for: running.id).first {
            $0.clientMessageID == "client-retry-connecting"
        })

        let retried = await store.retryFailedUserMessage(failedMessage)

        XCTAssertFalse(retried)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)
        XCTAssertTrue(client.createPayloads.isEmpty)
        XCTAssertEqual(conversationStore.messages(for: running.id).first?.sendStatus, .failed)
    }

    func testRetryFailedUserMessagePreservesStructuredTurnPayload() async throws {
        let project = makeProject(id: "proj_retry_payload")
        let running = makeSession(id: "sess_retry_payload", projectID: project.id, title: "Retry Payload", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let payload = CodexAppServerTurnPayload(input: [
            .text("看下这张图"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .mention(name: "README", path: project.path)
        ])
        conversationStore.appendLocalUser(
            payload.previewText,
            sessionID: running.id,
            clientMessageID: "client-rich-retry",
            sendStatus: .failed,
            turnPayload: payload
        )

        let retried = await store.retryFailedUserMessage(try XCTUnwrap(conversationStore.messages(for: running.id).first))

        XCTAssertTrue(retried)
        let sent = try XCTUnwrap(sockets[0].sentTurns.first)
        XCTAssertEqual(sent.clientMessageID, "client-rich-retry")
        XCTAssertEqual(sent.payload.input, payload.input)
        XCTAssertEqual(sent.payload.options.model, "gpt-5.6-sol")
    }

    func testRunningSendKeepsInlineImagePayloadAfterAcceptedForPreview() async throws {
        let project = makeProject(id: "proj_keep_payload")
        let running = makeSession(id: "sess_keep_payload", projectID: project.id, title: "Keep Payload", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let payload = CodexAppServerTurnPayload(input: [
            .text("看下这张图"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .image(url: "https://example.test/diagram.png", detail: .low),
            .mention(name: "README", path: project.path)
        ])
        let sent = await store.sendTurn(payload)

        XCTAssertTrue(sent)
        XCTAssertEqual(sockets[0].sentTurns.count, 1)
        let localEcho = try XCTUnwrap(conversationStore.messages(for: running.id).first { $0.clientMessageID != nil })
        let clientMessageID = try XCTUnwrap(localEcho.clientMessageID)
        XCTAssertTrue(payloadContainsInlineImage(localEcho.turnPayload))
        XCTAssertEqual(localEcho.turnPayload?.input, payload.input)
        XCTAssertEqual(localEcho.turnPayload?.options.model, "gpt-5.6-sol")

        sockets[0].onSendAccepted?(clientMessageID)
        let acceptedMessages = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            guard let message = messages.first(where: { $0.clientMessageID == clientMessageID }) else {
                return false
            }
            return message.sendStatus == .sent
        }
        let accepted = try XCTUnwrap(acceptedMessages.first { $0.clientMessageID == clientMessageID })
        XCTAssertTrue(payloadContainsInlineImage(accepted.turnPayload))
        XCTAssertTrue(payloadContainsImageURL(accepted.turnPayload, url: "https://example.test/diagram.png"))
        XCTAssertTrue(payloadContainsMention(accepted.turnPayload, name: "README"))
        XCTAssertEqual(accepted.turnPayload?.textPrompt, "看下这张图")
    }

    func testRunningTurnLifecycleKeepsEchoAndFinalAssistantStable() async throws {
        let project = makeProject(id: "proj_turn_lifecycle")
        let running = makeSession(id: "sess_turn_lifecycle", projectID: project.id, title: "Lifecycle", status: "running", source: "codex")
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: {
                MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
            },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let sent = await store.sendTurn(CodexAppServerTurnPayload(prompt: "从输入框提交"))
        XCTAssertTrue(sent)
        let localEcho = try XCTUnwrap(conversationStore.messages(for: running.id).first { $0.role == .user })
        let clientMessageID = try XCTUnwrap(localEcho.clientMessageID)
        XCTAssertEqual(localEcho.sendStatus, .sending)
        XCTAssertEqual(sockets[0].sentTurns.first?.clientMessageID, clientMessageID)

        sockets[0].onSendAccepted?(clientMessageID)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.clientMessageID == clientMessageID && $0.sendStatus == .sent }
        }

        sockets[0].emitEvent(.turnStarted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn-lifecycle",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID("turn-lifecycle", store: store)

        sockets[0].emitEvent(.messageCompleted(
            AgentMessage(
                id: "client:\(clientMessageID)",
                sessionID: running.id,
                clientMessageID: clientMessageID,
                turnID: "turn-lifecycle",
                itemID: "user-lifecycle",
                role: .user,
                content: "从输入框提交",
                revision: 2,
                sendStatus: .confirmed
            ),
            AgentEventMetadata(
                seq: 2,
                sessionID: running.id,
                turnID: "turn-lifecycle",
                itemID: "user-lifecycle",
                messageID: "client:\(clientMessageID)",
                clientMessageID: clientMessageID,
                revision: 2,
                createdAt: nil
            )
        ))
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.filter { $0.clientMessageID == clientMessageID }.count == 1 &&
                messages.contains { $0.clientMessageID == clientMessageID && $0.sendStatus == .confirmed }
        }

        // 已确认的用户 echo 不能被后到 accepted/failure callback 降级。
        sockets[0].onSendAccepted?(clientMessageID)
        sockets[0].onSendFailure?(clientMessageID, "late failure")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            conversationStore.messages(for: running.id).first { $0.clientMessageID == clientMessageID }?.sendStatus,
            .confirmed
        )

        let assistantMetadata = AgentEventMetadata(
            seq: 3,
            sessionID: running.id,
            turnID: "turn-lifecycle",
            itemID: "assistant-lifecycle",
            messageID: "assistant-final",
            clientMessageID: nil,
            revision: 7,
            createdAt: nil
        )
        sockets[0].emitEvent(.assistantDelta(
            AgentDelta(text: "阶段性片段", role: .assistant, kind: .message),
            assistantMetadata
        ))
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.stableID == "assistant-final" && $0.content == "阶段性片段" && $0.sendStatus == .sending }
        }

        sockets[0].emitEvent(.messageCompleted(
            AgentMessage(
                id: "assistant-final",
                sessionID: running.id,
                turnID: "turn-lifecycle",
                itemID: "assistant-lifecycle",
                role: .assistant,
                content: "最终完整回答",
                revision: 7,
                sendStatus: .confirmed
            ),
            AgentEventMetadata(
                seq: 4,
                sessionID: running.id,
                turnID: "turn-lifecycle",
                itemID: "assistant-lifecycle",
                messageID: "assistant-final",
                clientMessageID: nil,
                revision: 7,
                createdAt: nil
            )
        ))
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.filter { $0.stableID == "assistant-final" }.count == 1 &&
                messages.contains { $0.stableID == "assistant-final" && $0.content == "最终完整回答" && $0.sendStatus == .confirmed }
        }

        sockets[0].emitEvent(.assistantDelta(
            AgentDelta(text: "迟到增量", role: .assistant, kind: .message),
            AgentEventMetadata(
                seq: 5,
                sessionID: running.id,
                turnID: "turn-lifecycle",
                itemID: "assistant-lifecycle",
                messageID: "assistant-final",
                clientMessageID: nil,
                revision: 8,
                createdAt: nil
            )
        ))
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertEqual(
            conversationStore.messages(for: running.id).first { $0.stableID == "assistant-final" }?.content,
            "最终完整回答"
        )
        XCTAssertEqual(
            conversationStore.messages(for: running.id).first { $0.stableID == "assistant-final" }?.sendStatus,
            .confirmed
        )

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 6,
            sessionID: running.id,
            turnID: "turn-lifecycle",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID(nil, store: store)
        XCTAssertNil(store.selectedForegroundActivity)
    }

}
