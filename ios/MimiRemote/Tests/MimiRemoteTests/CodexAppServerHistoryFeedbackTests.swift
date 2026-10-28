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

    func testOpeningActiveTurnKeepsToolOutputProcessAndFileProgress() async throws {
        let fixture = makeFixture()
        defer { fixture.store.disconnectWebSocket() }
        let recorder = FeedbackRecorder(store: fixture.store, sessionID: sessionID)
        let runtime = makeRuntime()
        let turnID = "live-tools"

        await seedThread(in: runtime)
        await runtime.handle(turnStarted(turnID))
        let attachment = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID)
        // 工具只在恢复窗口内发一次 started；打开门后也必须出现运行中卡和文件进度。
        await emitCommand(turnID, status: "inProgress", into: runtime)
        await emitToolOutput(turnID, text: "窗口日志\n", into: runtime)
        await runtime.handle(CodexAppServerNotification(
            method: "turn/diff/updated",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string(turnID),
                "itemId": .string("file-window"),
                "path": .string("Sources/Window.swift"),
                "status": .string("modified"),
            ])
        ))
        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
        await runtime.finishAttachedEventStreams(sessionID: sessionID)
        for await event in attachment.events {
            await fixture.store.applyRuntimeEvent(event, lease: fixture.lease, sendsNotification: false)
            recorder.observeCurrentState()
        }

        let command = try XCTUnwrap(fixture.conversationStore.messages(for: sessionID).first {
            $0.itemID == "command-\(turnID)"
        })
        XCTAssertEqual(command.kind, .commandSummary)
        XCTAssertEqual(command.activityPayload?.status, "inProgress")
        XCTAssertTrue(fixture.store.contextStore.context(for: sessionID)?.tasks.contains {
            $0.kind == "file_change" && $0.subtitle == "Sources/Window.swift"
        } == true)
        XCTAssertEqual(fixture.store.selectedSession?.activeTurnID, turnID)
        XCTAssertTrue(recorder.feedback.isEmpty)

        await emitToolOutput(turnID, text: "后续日志\n", into: runtime)
        await applyBufferedEvents(from: runtime, policy: .all, fixture: fixture, recorder: recorder)
        for _ in 0..<300 where !fixture.logStore.log(for: sessionID).contains("后续日志") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(fixture.logStore.log(for: sessionID), "窗口日志\n后续日志\n")

        await emitCommand(turnID, status: "completed", output: "窗口日志\n后续日志\n", into: runtime)
        await runtime.handle(turnCompleted(turnID))
        await applyBufferedEvents(from: runtime, policy: .all, fixture: fixture, recorder: recorder)
        XCTAssertEqual(fixture.logStore.log(for: sessionID), "窗口日志\n后续日志\n")
        XCTAssertEqual(recorder.feedback, [.completion])
    }

    func testToolCompletedDuringRecoveryDoesNotReturnToRunning() async throws {
        let fixture = makeFixture()
        defer { fixture.store.disconnectWebSocket() }
        let recorder = FeedbackRecorder(store: fixture.store, sessionID: sessionID)
        let runtime = makeRuntime()
        let turnID = "live-completed-tool"

        await seedThread(in: runtime)
        await runtime.handle(turnStarted(turnID))
        let attachment = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID)
        await emitCommand(turnID, status: "inProgress", into: runtime)
        await emitCommand(turnID, status: "completed", output: "工具已结束", into: runtime)
        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
        await runtime.finishAttachedEventStreams(sessionID: sessionID)
        for await event in attachment.events {
            await fixture.store.applyRuntimeEvent(event, lease: fixture.lease, sendsNotification: false)
            recorder.observeCurrentState()
        }

        let command = try XCTUnwrap(fixture.conversationStore.messages(for: sessionID).first {
            $0.itemID == "command-\(turnID)"
        })
        XCTAssertEqual(command.activityPayload?.status, "completed")
        XCTAssertTrue(fixture.store.contextStore.context(for: sessionID)?.tasks.contains {
            $0.kind == "command" && $0.status == "completed"
        } == true)
        XCTAssertEqual(fixture.store.selectedSession?.status, "running", "工具结束不等于整个回合结束")
        XCTAssertTrue(recorder.feedback.isEmpty)
    }

    func testHistoryReadThenAttachKeepsWindowTextWithoutRepeatingSnapshotPrefix() async throws {
        for prefix in ["", "已有"] {
            let fixture = makeFixture()
            defer { fixture.store.disconnectWebSocket() }
            let turnID = "history-attach-text"
            let (runtime, page, _) = try await readActiveHistorySnapshot(turnID: turnID, prefix: prefix)
            fixture.store.applyHistoryFirstPage(page, sessionID: sessionID)

            // The real history RPC has completed. These deltas cannot be in its snapshot.
            await emitDelta(turnID, text: "窗口内", into: runtime)
            let attachment = await runtime.attachEventsDeferringStateReplay(
                sessionID: sessionID,
                historyReplayBoundary: fixture.store.historyReplayBoundaryBySessionID[sessionID]
            )
            await emitDelta(turnID, text: "门内", into: runtime)
            await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
            await runtime.finishAttachedEventStreams(sessionID: sessionID)
            var replayedText = ""
            for await event in attachment.events {
                if case .assistantDelta(let delta, _) = event { replayedText += delta.text }
                await fixture.store.applyRuntimeEvent(event, lease: fixture.lease, sendsNotification: false)
            }
            XCTAssertEqual(replayedText, "窗口内门内", "历史前缀不能重放，读取后的增量不能丢失")
            await emitDelta(turnID, text: "后续", into: runtime)
            await applyBufferedEvents(from: runtime, policy: .all, fixture: fixture,
                                      recorder: FeedbackRecorder(store: fixture.store, sessionID: sessionID))
            fixture.conversationStore.resetLiveTranscript(sessionID: sessionID)
            // 与 #903 的活动历史投影组合后，已有前缀和两个交接窗口的增量应保留在同一气泡。
            XCTAssertEqual(fixture.conversationStore.messages(for: sessionID).map(\.content),
                           [prefix + "窗口内门内后续"])
        }
    }

    func testHistoryReadThenAttachKeepsWindowToolAndOutput() async throws {
        let fixture = makeFixture()
        defer { fixture.store.disconnectWebSocket() }
        let turnID = "history-attach-tool"
        let (runtime, page, _) = try await readActiveHistorySnapshot(turnID: turnID, prefix: "")
        fixture.store.applyHistoryFirstPage(page, sessionID: sessionID)
        await emitCommand(turnID, status: "inProgress", into: runtime)
        await emitToolOutput(turnID, text: "窗口日志\n", into: runtime)
        let attachment = await runtime.attachEventsDeferringStateReplay(
            sessionID: sessionID,
            historyReplayBoundary: fixture.store.historyReplayBoundaryBySessionID[sessionID]
        )
        await emitToolOutput(turnID, text: "门内日志\n", into: runtime)
        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
        await runtime.finishAttachedEventStreams(sessionID: sessionID)
        for await event in attachment.events {
            await fixture.store.applyRuntimeEvent(event, lease: fixture.lease, sendsNotification: false)
        }
        for _ in 0..<300 where !fixture.logStore.log(for: sessionID).contains("门内日志") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(fixture.logStore.log(for: sessionID), "窗口日志\n门内日志\n")
        XCTAssertTrue(fixture.conversationStore.messages(for: sessionID).contains {
            $0.itemID == "command-\(turnID)" && $0.activityPayload?.isInProgress == true
        })
    }

    func testMainConnectionForwardsOnlyAdoptedHistoryBoundary() async throws {
        let socket = MockWebSocketClient()
        let fixture = makeFixture(socket: socket)
        defer { fixture.store.disconnectWebSocket() }
        let (_, page, _) = try await readActiveHistorySnapshot(turnID: "history-store-wiring", prefix: "")
        let session = try XCTUnwrap(fixture.store.selectedSession)
        fixture.store.applyHistoryFirstPage(page, sessionID: sessionID)
        fixture.store.connectWebSocket(session, replayBufferedEvents: false, allowNonRunning: true)
        XCTAssertEqual(socket.connectedSessionIDs, [sessionID])
        XCTAssertEqual(socket.historyReplayBoundariesByConnect, [page.replayBoundary])
        XCTAssertEqual(socket.replayBufferedEventsByConnect, [false])
        fixture.store.disconnectWebSocket()
        fixture.store.applyHistoryFirstPage(HistoryMessagesPage(messages: [], snapshotSeq: 42), sessionID: sessionID)
        fixture.store.historySnapshotSeqBySessionID[sessionID] = 42
        fixture.store.connectWebSocket(session, replayBufferedEvents: false, allowNonRunning: true)
        XCTAssertEqual(socket.historyReplayBoundariesByConnect, [page.replayBoundary, nil])
        XCTAssertEqual(socket.afterSequencesByConnect, [nil, 42])
    }

    func testUnadoptedReadDoesNotReplaceEachSubscribersHistoryBoundary() async throws {
        for newestFirst in [false, true] {
            let turnID = "history-two-readers"
            let (runtime, pageA, transport) = try await readActiveHistorySnapshot(turnID: turnID, prefix: "")
            let fixture = makeFixture()
            defer { fixture.store.disconnectWebSocket() }
            fixture.store.applyHistoryFirstPage(pageA, sessionID: sessionID)
            await emitDelta(turnID, text: "A", into: runtime)
            let requestCount = await transport.sentMessages().count
            let readB = Task { try await runtime.messagesPage(sessionID: sessionID, before: nil, limit: 120) }
            let requestB = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list", after: requestCount)
            transportResponse(transport, id: requestB.id,
                              result: #"{"data":[{"id":"\#(turnID)","status":"inProgress","itemsView":"full","items":[{"id":"message-\#(turnID)","type":"agentMessage","text":"A"}]}],"nextCursor":null}"#)
            let pageB = try await readB.value
            XCTAssertEqual(fixture.store.historyReplayBoundaryBySessionID[sessionID], pageA.replayBoundary)
            await emitDelta(turnID, text: "B", into: runtime)
            let first = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID, historyReplayBoundary: pageA.replayBoundary)
            let second = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID, historyReplayBoundary: pageB.replayBoundary)
            await emitDelta(turnID, text: "C", into: runtime)
            for token in newestFirst ? [second.token, first.token] : [first.token, second.token] {
                await runtime.completeDeferredStateReplay(sessionID: sessionID, token: token)
            }
            await runtime.finishAttachedEventStreams(sessionID: sessionID)
            let firstText = await collectAssistantText(first.events)
            let secondText = await collectAssistantText(second.events)
            XCTAssertEqual(firstText, "ABC")
            XCTAssertEqual(secondText, "BC")
            fixture.store.applyHistoryFirstPage(HistoryMessagesPage(messages: []), sessionID: sessionID)
            XCTAssertNil(fixture.store.historyReplayBoundaryBySessionID[sessionID])
        }
    }

    func testHistoryBoundarySurvivesConsumedBufferAndResolvedApproval() async throws {
        let turnID = "history-buffer-reset"
        let (runtime, page, _) = try await readActiveHistorySnapshot(turnID: turnID, prefix: "")
        _ = await runtime.bufferedEvents(sessionID: sessionID, replayPolicy: .all)
        await runtime.handle(CodexAppServerServerRequest(
            id: .string("window-approval"), method: "item/commandExecution/requestApproval",
            params: .object(["threadId": .string(sessionID), "turnId": .string(turnID),
                             "itemId": .string("window-command"), "command": .string("echo test")])
        ))
        let attachment = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID, historyReplayBoundary: page.replayBoundary)
        await emitDelta(turnID, text: "仍应保留", into: runtime)
        await runtime.handle(CodexAppServerNotification(method: "serverRequest/resolved", params: .object([
            "threadId": .string(sessionID), "turnId": .string(turnID), "requestId": .string("window-approval")
        ])))
        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
        await runtime.finishAttachedEventStreams(sessionID: sessionID)
        let text = await collectAssistantText(attachment.events)
        XCTAssertEqual(text, "仍应保留")
    }

    func testUnrelatedHistoryBoundaryUsesOriginalAttachBoundary() async throws {
        let turnID = "history-invalid-boundary"
        let (runtime, page, _) = try await readActiveHistorySnapshot(turnID: turnID, prefix: "")
        let boundary = try XCTUnwrap(page.replayBoundary)
        let invalid = [
            HistoryReplayBoundary(runtimeID: UUID(), sessionID: sessionID, generation: boundary.generation),
            HistoryReplayBoundary(runtimeID: boundary.runtimeID, sessionID: "other-thread", generation: boundary.generation),
            HistoryReplayBoundary(runtimeID: boundary.runtimeID, sessionID: sessionID, generation: Int.max)
        ]
        for checkpoint in invalid {
            await emitDelta(turnID, text: "已有", into: runtime)
            let attachment = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID, historyReplayBoundary: checkpoint)
            await emitDelta(turnID, text: "新增", into: runtime)
            await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
            await runtime.finishAttachedEventStreams(sessionID: sessionID)
            let text = await collectAssistantText(attachment.events)
            XCTAssertEqual(text, "新增")
        }
    }

    private func collectAssistantText(_ events: CodexAppServerEventStream) async -> String {
        var text = ""
        for await event in events {
            if case .assistantDelta(let delta, _) = event { text += delta.text }
        }
        return text
    }

    private func readActiveHistorySnapshot(
        turnID: String,
        prefix: String
    ) async throws -> (CodexAppServerSessionRuntime, HistoryMessagesPage, FakeCodexAppServerTransport) {
        let transport = FakeCodexAppServerTransport()
        let project = AgentProject(id: "history-feedback", name: "History", path: "/tmp/history-feedback")
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project,
                                          allowedMethods: ["initialize", "initialized", "thread/turns/list"],
                                          channels: [makeClaudeChannelMetadata()])
            }
        )
        await seedThread(in: runtime)
        await runtime.handle(turnStarted(turnID))
        if !prefix.isEmpty { await emitDelta(turnID, text: prefix, into: runtime) }
        let read = Task { try await runtime.messagesPage(sessionID: sessionID, before: nil, limit: 120) }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let request = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        let items = prefix.isEmpty ? "[]" : #"[{"id":"message-\#(turnID)","type":"agentMessage","text":"\#(prefix)"}]"#
        transportResponse(transport, id: request.id,
                          result: #"{"data":[{"id":"\#(turnID)","status":"inProgress","itemsView":"full","items":\#(items)}],"nextCursor":null}"#)
        return (runtime, try await read.value, transport)
    }

    private struct Fixture {
        let store: SessionStore
        let conversationStore: ConversationStore
        let logStore: LogStore
        let lease: HostSessionLease
    }

    private func makeFixture(socket: MockWebSocketClient? = nil) -> Fixture {
        let appStore = makeIsolatedAppStore()
        if socket != nil { appStore.token = "test-token" }
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) },
            webSocketFactory: { socket ?? MockWebSocketClient() }
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
            logStore: logStore,
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

    private func emitCommand(
        _ turnID: TurnID,
        status: String,
        output: String = "",
        into runtime: CodexAppServerSessionRuntime
    ) async {
        await runtime.handle(CodexAppServerNotification(
            method: status == "inProgress" ? "item/started" : "item/completed",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string("command-\(turnID)"),
                    "type": .string("commandExecution"),
                    "command": .string("swift --version"),
                    "status": .string(status),
                    "aggregatedOutput": .string(output),
                ]),
            ])
        ))
    }

    private func emitToolOutput(
        _ turnID: TurnID,
        text: String,
        into runtime: CodexAppServerSessionRuntime
    ) async {
        await runtime.handle(CodexAppServerNotification(
            method: "item/commandExecution/outputDelta",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string(turnID),
                "itemId": .string("command-\(turnID)"),
                "delta": .string(text),
                "stream": .string("stdout"),
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
