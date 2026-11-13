import XCTest
@testable import MimiRemote

final class CodexAppServerBufferedReplayTests: XCTestCase {
    private let sessionID = "thread-buffered-replay"

    func testStateOnlyReplayCollapsesCompletedTurnsToLatestTerminalBoundary() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude"
        )
        await seedThread(in: runtime)

        await emitCompletedTurn("turn-old-1", text: "第一轮完成", into: runtime)
        await emitCompletedTurn("turn-old-2", text: "第二轮完成", into: runtime)

        let events = await runtime.bufferedEvents(
            sessionID: sessionID,
            replayPolicy: .stateOnly
        )

        XCTAssertEqual(turnIDs(for: .started, in: events), [])
        XCTAssertEqual(turnIDs(for: .completed, in: events), ["turn-old-2"])
        XCTAssertEqual(completedAssistantTexts(in: events), ["第一轮完成", "第二轮完成"])
    }

    func testStateOnlyReplayKeepsCurrentActiveTurnWithoutReplayingOldCompletion() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude"
        )
        await seedThread(in: runtime)

        await emitCompletedTurn("turn-old", text: "旧回合完成", into: runtime)
        await runtime.handle(turnStarted("turn-live"))
        await runtime.handle(assistantDelta("旧回合增量", turnID: "turn-old"))
        await runtime.handle(assistantDelta("当前回合增量", turnID: "turn-live"))
        await runtime.handle(commandOutputDelta("旧回合日志", turnID: "turn-old"))
        await runtime.handle(commandOutputDelta("当前回合日志", turnID: "turn-live"))
        await runtime.handle(commandStarted("old-command", turnID: "turn-old"))
        await runtime.handle(commandStarted("live-command", turnID: "turn-live"))
        await runtime.handle(commandCompleted("old-completed-command", turnID: "turn-old"))
        await runtime.handle(fileChangeUpdated("old.swift", turnID: "turn-old"))
        await runtime.handle(fileChangeUpdated("live.swift", turnID: "turn-live"))

        let events = await runtime.bufferedEvents(
            sessionID: sessionID,
            replayPolicy: .stateOnly
        )

        XCTAssertEqual(turnIDs(for: .started, in: events), ["turn-live"])
        XCTAssertEqual(turnIDs(for: .completed, in: events), [])
        XCTAssertEqual(completedAssistantTexts(in: events), ["旧回合完成"])
        XCTAssertEqual(assistantDeltas(in: events), [])
        XCTAssertEqual(logDeltas(in: events), [])
        XCTAssertEqual(inProgressItemIDs(in: events), [])
        XCTAssertEqual(completedProcessItemIDs(in: events), ["old-completed-command"])
        XCTAssertEqual(fileChangePaths(in: events), [])
    }

    func testDeferredReplayDeliversActiveDeltaAndContinuesStreamingAfterGateOpens() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude"
        )
        await seedThread(in: runtime)
        await emitCompletedTurn("turn-old", text: "旧回合完成", into: runtime)
        await runtime.handle(turnStarted("turn-live"))
        await runtime.handle(assistantDelta("历史已覆盖", turnID: "turn-live"))
        let attachment = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID)

        await runtime.handle(assistantDelta("旧回合增量", turnID: "turn-old"))
        await runtime.handle(assistantDelta("门内正文", turnID: "turn-live", replaySequence: 51))
        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
        await runtime.handle(assistantDelta("门外正文", turnID: "turn-live"))
        await runtime.finishAttachedEventStreams(sessionID: sessionID)

        var replay: [AgentEvent] = []
        for await event in attachment.events { replay.append(event) }
        XCTAssertEqual(assistantDeltas(in: replay).joined(), "门内正文门外正文")
        XCTAssertTrue(replay.compactMap(assistantDeltaMetadata).allSatisfy {
            $0.replayBoundarySequence == nil
        })
    }

    func testDeferredReplayDeliversOnlyPostAttachActiveProcessPayloads() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude"
        )
        await seedThread(in: runtime)
        await emitCompletedTurn("turn-old", text: "旧回合完成", into: runtime)
        await runtime.handle(turnStarted("turn-live"))
        await runtime.handle(commandOutputDelta("门前日志", turnID: "turn-live"))
        await runtime.handle(commandStarted("before-command", turnID: "turn-live"))
        await runtime.handle(fileChangeUpdated("before.swift", turnID: "turn-live"))
        let attachment = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID)

        await runtime.handle(commandOutputDelta("旧回合门内日志", turnID: "turn-old"))
        await runtime.handle(commandOutputDelta("当前门内日志", turnID: "turn-live", replaySequence: 52))
        await runtime.handle(commandStarted("old-gate-command", turnID: "turn-old"))
        await runtime.handle(commandStarted("live-gate-command", turnID: "turn-live", replaySequence: 53))
        await runtime.handle(fileChangeUpdated("old-gate.swift", turnID: "turn-old"))
        await runtime.handle(fileChangeUpdated("live-gate.swift", turnID: "turn-live", replaySequence: 54))
        await runtime.handle(commandStarted("live-finished-command", turnID: "turn-live", replaySequence: 55))
        await runtime.handle(commandCompleted("live-finished-command", turnID: "turn-live", replaySequence: 56))
        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
        await runtime.handle(commandOutputDelta("当前门外日志", turnID: "turn-live"))
        await runtime.handle(commandStarted("live-after-command", turnID: "turn-live"))
        await runtime.handle(fileChangeUpdated("live-after.swift", turnID: "turn-live"))
        await runtime.finishAttachedEventStreams(sessionID: sessionID)

        var replay: [AgentEvent] = []
        for await event in attachment.events { replay.append(event) }
        XCTAssertEqual(logDeltas(in: replay), ["当前门内日志", "当前门外日志"])
        XCTAssertEqual(inProgressItemIDs(in: replay), [
            "live-gate-command",
            "live-finished-command",
            "live-after-command",
        ])
        XCTAssertEqual(processItemProgressStates(
            in: replay,
            itemID: "live-finished-command"
        ), [true, false])
        XCTAssertEqual(fileChangePaths(in: replay), ["live-gate.swift", "live-after.swift"])
        XCTAssertTrue(replay.compactMap(incrementalProcessMetadata).allSatisfy {
            $0.replayBoundarySequence == nil
        })
        let sessionIndex = replay.firstIndex { event in
            if case .session = event { return true }
            return false
        }
        XCTAssertNotNil(sessionIndex)
        XCTAssertTrue(incrementalContextIndices(in: replay).allSatisfy { index in
            guard let sessionIndex else { return false }
            return index > sessionIndex
        })
    }

    func testFullReplayPreservesLiveLifecycleSequence() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude"
        )

        await emitCompletedTurn("turn-live", text: "实时完成", into: runtime)

        let events = await runtime.bufferedEvents(
            sessionID: sessionID,
            replayPolicy: .all
        )

        XCTAssertEqual(turnIDs(for: .started, in: events), ["turn-live"])
        XCTAssertEqual(turnIDs(for: .completed, in: events), ["turn-live"])
    }

    func testSecondDeferredSubscriberCanConsumeBacklogBeforeCancelledFirstSubscriberDetaches() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude"
        )
        await seedThread(in: runtime)

        await emitCompletedTurn("turn-before-attach", text: "attach 前", into: runtime)
        let first = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID)
        await emitCompletedTurn("turn-during-connect", text: "connect 中", into: runtime)
        let replacement = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID)

        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: replacement.token)
        var iterator = replacement.events.makeAsyncIterator()
        let firstEvent = await iterator.next()
        let secondEvent = await iterator.next()

        XCTAssertEqual(completedAssistantTexts(in: [firstEvent, secondEvent].compactMap { $0 }), [
            "attach 前",
            "connect 中",
        ])
        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: first.token)
        var firstIterator = first.events.makeAsyncIterator()
        let firstSubscriberEvent = await firstIterator.next()
        let firstSubscriberSecondEvent = await firstIterator.next()
        XCTAssertEqual(
            completedAssistantTexts(in: [firstSubscriberEvent, firstSubscriberSecondEvent].compactMap { $0 }),
            ["attach 前", "connect 中"]
        )
        first.events.cancel()
        replacement.events.cancel()
    }

    func testDeferredReplayDoesNotDelayExistingFullSubscriber() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude"
        )
        await seedThread(in: runtime)
        _ = await runtime.bufferedEvents(sessionID: sessionID, replayPolicy: .all)
        let live = await runtime.attachEvents(sessionID: sessionID, replayPolicy: .all)
        let deferred = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID)
        await runtime.handle(turnStarted("turn-live"))

        var liveIterator = live.makeAsyncIterator()
        let firstLiveEvent = await liveIterator.next()
        let secondLiveEvent = await liveIterator.next()
        let thirdLiveEvent = await liveIterator.next()
        XCTAssertEqual(
            turnIDs(
                for: .started,
                in: [firstLiveEvent, secondLiveEvent, thirdLiveEvent].compactMap { $0 }
            ),
            ["turn-live"]
        )

        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: deferred.token)
        var deferredIterator = deferred.events.makeAsyncIterator()
        guard let deferredEvent = await deferredIterator.next() else {
            return XCTFail("stateOnly 门打开后应收到窗口内状态")
        }
        XCTAssertEqual(turnIDs(for: .started, in: [deferredEvent]), ["turn-live"])
        live.cancel()
        deferred.events.cancel()
    }

    func testDeferredReplayKeepsCurrentApprovalAndDropsResolvedRequest() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude"
        )
        await seedThread(in: runtime)
        await runtime.handle(turnStarted("turn-pending"))
        let attachment = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID)

        await runtime.handle(approvalRequest(
            requestID: "rpc-resolved",
            itemID: "approval-resolved"
        ))
        await runtime.handle(CodexAppServerNotification(
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string("turn-pending"),
                "requestId": .string("rpc-resolved"),
            ])
        ))
        await runtime.handle(approvalRequest(
            requestID: "rpc-pending",
            itemID: "approval-pending"
        ))
        await runtime.handle(userInputRequest(requestID: "input-pending"))

        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
        await runtime.finishAttachedEventStreams(sessionID: sessionID)
        var replay: [AgentEvent] = []
        for await event in attachment.events { replay.append(event) }

        let approvalIDs = replay.compactMap { event -> String? in
            guard case .approvalRequest(let request, _) = event else { return nil }
            return request.id
        }
        XCTAssertEqual(approvalIDs, ["approval-pending"])
        let inputIDs = replay.compactMap { event -> String? in
            guard case .userInputRequest(let request, _) = event else { return nil }
            return request.id
        }
        XCTAssertEqual(inputIDs, ["input-pending"])
        XCTAssertFalse(replay.contains {
            if case .approvalResolved = $0 { return true }
            return false
        })
    }

    func testStateOnlyReplayMovesLatestBoundaryAfterAllContent() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude"
        )
        await seedThread(in: runtime)
        await runtime.handle(turnStarted("turn-boundary"))
        await runtime.handle(CodexAppServerNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string("turn-boundary"),
                "item": .object([
                    "id": .string("message-boundary"),
                    "type": .string("agentMessage"),
                    "text": .string("游标前内容"),
                ]),
            ]),
            replaySequence: 41
        ))
        await runtime.handle(CodexAppServerNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(sessionID),
                "turn": .object([
                    "id": .string("turn-boundary"),
                    "status": .string("completed"),
                ]),
            ]),
            replaySequence: 42
        ))

        let replay = await runtime.bufferedEvents(sessionID: sessionID, replayPolicy: .stateOnly)
        let boundaries = replay.enumerated().compactMap { index, event -> (Int, UInt64)? in
            guard let sequence = replayBoundarySequence(for: event) else { return nil }
            return (index, sequence)
        }
        XCTAssertEqual(boundaries.map(\.1), [42])
        XCTAssertEqual(boundaries.first?.0, replay.indices.last)
        XCTAssertEqual(completedAssistantTexts(in: replay), ["游标前内容"])
    }

    func testRunningSessionWithoutActiveTurnDoesNotRestoreOldStart() {
        var held = makeSession(
            id: sessionID,
            projectID: "buffered-replay",
            title: "外部持有会话",
            status: SessionStatus.running.rawValue,
            source: "claude",
            runtimeProvider: "claude",
            resumeID: sessionID
        )
        held.activeTurnID = nil
        let replay = CodexAppServerBufferedEventReplay.stateOnly(
            [.turnStarted(AgentEventMetadata(
                seq: nil,
                sessionID: sessionID,
                turnID: "old-turn",
                itemID: nil,
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            ))],
            currentSession: held,
            pendingInteractionIDs: []
        )

        XCTAssertTrue(turnIDs(for: .started, in: replay).isEmpty)
    }

    func testUnidentifiedClaudeCompletionDefersBoundaryUntilGateOpens() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude"
        )
        await seedThread(in: runtime)
        _ = await runtime.bufferedEvents(sessionID: sessionID, replayPolicy: .all)
        let attachment = await runtime.attachEventsDeferringStateReplay(sessionID: sessionID)

        await runtime.handle(CodexAppServerNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(sessionID),
                "turn": .object(["status": .string("completed")]),
            ]),
            replaySequence: 77
        ))
        await runtime.completeDeferredStateReplay(sessionID: sessionID, token: attachment.token)
        await runtime.finishAttachedEventStreams(sessionID: sessionID)
        var replay: [AgentEvent] = []
        for await event in attachment.events { replay.append(event) }

        let boundaries = replay.enumerated().compactMap { index, event -> (Int, UInt64)? in
            guard let sequence = replayBoundarySequence(for: event) else { return nil }
            return (index, sequence)
        }
        XCTAssertEqual(boundaries.map(\.1), [77])
        XCTAssertEqual(boundaries.first?.0, replay.indices.last)
    }

    private func emitCompletedTurn(
        _ turnID: TurnID,
        text: String,
        into runtime: CodexAppServerSessionRuntime
    ) async {
        await runtime.handle(turnStarted(turnID))
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
        await runtime.handle(CodexAppServerNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(sessionID),
                "turn": .object([
                    "id": .string(turnID),
                    "status": .string("completed"),
                ]),
            ])
        ))
    }

    private func seedThread(in runtime: CodexAppServerSessionRuntime) async {
        await runtime.handle(CodexAppServerNotification(
            method: "thread/started",
            params: .object(["thread": .object([
                "id": .string(sessionID),
                "cwd": .string("/tmp/buffered-replay"),
                "name": .string("Buffered replay"),
                "status": .object(["type": .string("idle")]),
                "modelProvider": .string("anthropic"),
                "source": .string("appServer"),
            ])])
        ))
    }

    private func approvalRequest(
        requestID: String,
        itemID: String
    ) -> CodexAppServerServerRequest {
        CodexAppServerServerRequest(
            id: .string(requestID),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string("turn-pending"),
                "itemId": .string(itemID),
                "command": .string("echo test"),
                "reason": .string("验证恢复窗口"),
            ])
        )
    }

    private func userInputRequest(requestID: String) -> CodexAppServerServerRequest {
        CodexAppServerServerRequest(
            id: .string(requestID),
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string("turn-pending"),
                "serverName": .string("fixture"),
                "mode": .string("form"),
                "message": .string("请选择"),
                "requestedSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "answer": .object(["type": .string("string")]),
                    ]),
                ]),
            ])
        )
    }

    private func replayBoundarySequence(for event: AgentEvent) -> UInt64? {
        switch event {
        case .messageCompleted(_, let metadata),
             .turnCompleted(let metadata),
             .sessionStatus(_, let metadata):
            return metadata.replayBoundarySequence
        default:
            return nil
        }
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

    private func assistantDelta(
        _ text: String,
        turnID: TurnID,
        replaySequence: UInt64? = nil
    ) -> CodexAppServerNotification {
        CodexAppServerNotification(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string(turnID),
                "itemId": .string("message-\(turnID)"),
                "delta": .string(text),
            ]),
            replaySequence: replaySequence
        )
    }

    private func commandOutputDelta(
        _ text: String,
        turnID: TurnID,
        replaySequence: UInt64? = nil
    ) -> CodexAppServerNotification {
        CodexAppServerNotification(
            method: "item/commandExecution/outputDelta",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string(turnID),
                "itemId": .string("command-\(turnID)"),
                "delta": .string(text),
                "stream": .string("stdout"),
            ]),
            replaySequence: replaySequence
        )
    }

    private func commandStarted(
        _ itemID: AgentItemID,
        turnID: TurnID,
        replaySequence: UInt64? = nil
    ) -> CodexAppServerNotification {
        CodexAppServerNotification(
            method: "item/started",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("commandExecution"),
                    "command": .string("echo \(itemID)"),
                    "cwd": .string("/tmp/buffered-replay"),
                ]),
            ]),
            replaySequence: replaySequence
        )
    }

    private func commandCompleted(
        _ itemID: AgentItemID,
        turnID: TurnID,
        replaySequence: UInt64? = nil
    ) -> CodexAppServerNotification {
        CodexAppServerNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("commandExecution"),
                    "command": .string("echo \(itemID)"),
                    "cwd": .string("/tmp/buffered-replay"),
                    "status": .string("completed"),
                    "aggregatedOutput": .string("done"),
                    "exitCode": .int(0),
                ]),
            ]),
            replaySequence: replaySequence
        )
    }

    private func fileChangeUpdated(
        _ path: String,
        turnID: TurnID,
        replaySequence: UInt64? = nil
    ) -> CodexAppServerNotification {
        CodexAppServerNotification(
            method: "item/fileChange/patchUpdated",
            params: .object([
                "threadId": .string(sessionID),
                "turnId": .string(turnID),
                "itemId": .string("file-\(path)"),
                "fileChange": .object([
                    "path": .string(path),
                    "status": .string("inProgress"),
                ]),
            ]),
            replaySequence: replaySequence
        )
    }

    private enum LifecycleEvent {
        case started
        case completed
    }

    private func turnIDs(for lifecycle: LifecycleEvent, in events: [AgentEvent]) -> [TurnID] {
        events.compactMap { event in
            switch (lifecycle, event) {
            case (.started, .turnStarted(let metadata)),
                 (.completed, .turnCompleted(let metadata)):
                return metadata.turnID
            default:
                return nil
            }
        }
    }

    private func completedAssistantTexts(in events: [AgentEvent]) -> [String] {
        events.compactMap { event in
            guard case .messageCompleted(let message, _) = event else { return nil }
            return message.content
        }
    }

    private func assistantDeltas(in events: [AgentEvent]) -> [String] {
        events.compactMap { event in
            guard case .assistantDelta(let delta, _) = event else { return nil }
            return delta.text
        }
    }

    private func assistantDeltaMetadata(_ event: AgentEvent) -> AgentEventMetadata? {
        guard case .assistantDelta(_, let metadata) = event else { return nil }
        return metadata
    }

    private func logDeltas(in events: [AgentEvent]) -> [String] {
        events.compactMap { event in
            guard case .logDelta(let delta, _) = event else { return nil }
            return delta.text
        }
    }

    private func inProgressItemIDs(in events: [AgentEvent]) -> [AgentItemID] {
        events.compactMap { event in
            guard case .processItemCompleted(let message, _, _) = event,
                  message.activityPayload?.isInProgress == true,
                  let itemID = message.itemID else {
                return nil
            }
            return itemID
        }
    }

    private func completedProcessItemIDs(in events: [AgentEvent]) -> [AgentItemID] {
        events.compactMap { event in
            guard case .processItemCompleted(let message, _, _) = event,
                  message.activityPayload?.isInProgress != true,
                  let itemID = message.itemID else {
                return nil
            }
            return itemID
        }
    }

    private func processItemProgressStates(
        in events: [AgentEvent],
        itemID: AgentItemID
    ) -> [Bool] {
        events.compactMap { event in
            guard case .processItemCompleted(let message, _, _) = event,
                  message.itemID == itemID else {
                return nil
            }
            return message.activityPayload?.isInProgress == true
        }
    }

    private func fileChangePaths(in events: [AgentEvent]) -> [String] {
        events.compactMap { event in
            guard case .sessionContext(let context, _) = event else { return nil }
            return context.tasks.first(where: { $0.kind == "file_change" })?.subtitle
        }
    }

    private func incrementalContextIndices(in events: [AgentEvent]) -> [Int] {
        events.enumerated().compactMap { index, event in
            switch event {
            case .sessionContext:
                return index
            case .processItemCompleted(let message, _, _)
                where message.activityPayload?.isInProgress == true:
                return index
            default:
                return nil
            }
        }
    }

    private func incrementalProcessMetadata(_ event: AgentEvent) -> AgentEventMetadata? {
        switch event {
        case .logDelta(_, let metadata):
            return metadata
        case .sessionContext(_, let metadata):
            return metadata
        case .processItemCompleted(let message, _, let metadata)
            where message.activityPayload?.isInProgress == true:
            return metadata
        default:
            return nil
        }
    }
}
