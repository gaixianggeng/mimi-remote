import XCTest
@testable import MimiRemote

/// opening snapshot 只补历史页之后的缺口，同时仍用完整快照恢复与对账状态。
@MainActor
final class HarnessSnapshotReplayTests: XCTestCase {
    private let sessionID: SessionID = "h00-replay-session"

    func testReplayDisabledProjectsOnlyRecordsAfterCoveredSequenceButReconcilesAll() async throws {
        let oldUser = messageEvent(type: HarnessWireEventType.userMessage, seq: 10, text: "旧用户消息")
        let oldAssistant = messageEvent(
            type: HarnessWireEventType.assistantMessage,
            seq: 11,
            text: "旧助手消息"
        )
        let oldTurnStart = turnEvent(type: HarnessWireEventType.turnStart, seq: 12, turn: 3)
        let oldTurnEnd = turnEvent(type: HarnessWireEventType.turnEnd, seq: 13, turn: 3)
        let gapUser = messageEvent(type: HarnessWireEventType.userMessage, seq: 21, text: "缺口消息")
        let opening = snapshot(
            cursor: 21,
            events: [gapUser, oldTurnEnd, oldAssistant, oldTurnStart, oldUser]
        )
        var reconciledSequences: [Int] = []
        var reportedSequences: [Int] = []
        var events: [AgentEvent] = []
        let client = makeClient(
            snapshot: opening,
            coveredSequence: { _ in 20 },
            reportCoveredSequence: { _, seq in reportedSequences.append(seq) },
            reconcile: { _, event in
                if let seq = event.seq { reconciledSequences.append(seq) }
                return HarnessDurableReconciliation()
            }
        )
        client.onEvent = { events.append($0) }

        client.connect(sessionID: sessionID, replayBufferedEvents: false)
        await waitFor { client.journal?.hasOpenedSnapshot == true }

        XCTAssertEqual(Set(reconciledSequences), [10, 11, 12, 13, 21], "过滤展示不能跳过状态对账")
        XCTAssertEqual(messageContents(in: events), ["缺口消息"])
        XCTAssertTrue(turnStartedIDs(in: events).isEmpty)
        XCTAssertTrue(turnCompletedIDs(in: events).isEmpty, "旧 turn/end 不得重演完成副作用")
        XCTAssertEqual(sessionStatuses(in: events), ["completed"], "明确结束的旧轮次只恢复当前状态")
        XCTAssertTrue(reportedSequences.isEmpty, "只送到 onEvent 不能冒充 Store 已应用")

        for event in events { client.acknowledgeAppliedEvent(event) }
        XCTAssertEqual(reportedSequences, [21], "只有 Store 确认应用后才能推进覆盖位置")
    }

    func testReplayDisabledWithoutKnownCoverageReplaysOpeningRecords() async throws {
        let opening = snapshot(
            cursor: 30,
            events: [
                messageEvent(type: HarnessWireEventType.userMessage, seq: 30, text: "快照末尾"),
                messageEvent(type: HarnessWireEventType.assistantMessage, seq: 29, text: "快照历史"),
            ]
        )
        var reconciledSequences: [Int] = []
        var reportedSequences: [Int] = []
        var events: [AgentEvent] = []
        let client = makeClient(
            snapshot: opening,
            coveredSequence: { _ in nil },
            reportCoveredSequence: { _, seq in reportedSequences.append(seq) },
            reconcile: { _, event in
                if let seq = event.seq { reconciledSequences.append(seq) }
                return HarnessDurableReconciliation()
            }
        )
        client.onEvent = { events.append($0) }

        client.connect(sessionID: sessionID, replayBufferedEvents: false)
        await waitFor { client.journal?.hasOpenedSnapshot == true }

        XCTAssertEqual(Set(reconciledSequences), [29, 30])
        XCTAssertEqual(
            messageContents(in: events),
            ["快照历史", "快照末尾"],
            "没有已应用序列证据时必须 fail-open，不能用 snapshot.cursor 猜测 UI 已读"
        )
        XCTAssertTrue(reportedSequences.isEmpty)

        for event in events { client.acknowledgeAppliedEvent(event) }
        XCTAssertEqual(reportedSequences, [29, 30])
    }

    func testLatestHistoryPageSequenceLetsFollowPublishOnlyPageToSnapshotGap() async throws {
        let rpc = FakeHarnessRPCTransport()
        let stream = FakeHarnessStreamTransport()
        let pageRecord = messageRecordValue(
            type: HarnessWireEventType.assistantMessage,
            seq: 20,
            text: "历史页末尾"
        )
        rpc.handler = { request in
            guard request.method == HarnessWireMethod.sessionPage else {
                return .failure(.rejected(status: 400, message: "unexpected method"))
            }
            return .success(.object([
                "hasMore": .bool(false),
                "records": .array([pageRecord]),
            ]))
        }
        let api = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            rpc: rpc,
            stream: stream
        )
        let page = try await loadLatestPage(api: api, stream: stream, snapshotCursor: 20)
        XCTAssertEqual(page.snapshotSeq, 20, "页面覆盖位置必须来自实际 page records，而不是 follow cursor")

        let client = try XCTUnwrap(
            api.makeEventClient(sessionID: sessionID) as? HarnessSessionWebSocketClient
        )
        var events: [AgentEvent] = []
        client.onEvent = { events.append($0) }
        let frameIndex = stream.sentFrames.count
        client.connect(
            sessionID: sessionID,
            replayBufferedEvents: false,
            afterSequence: page.snapshotSeq
        )
        let followID = try await waitForOpenStream(stream: stream, after: frameIndex)
        stream.push(carrierValue(
            streamID: followID,
            value: snapshotValue(cursor: 22, records: [
                messageRecordValue(type: HarnessWireEventType.assistantMessage, seq: 22, text: "缺口二"),
                messageRecordValue(type: HarnessWireEventType.userMessage, seq: 19, text: "旧消息"),
                messageRecordValue(type: HarnessWireEventType.userMessage, seq: 21, text: "缺口一"),
            ])
        ))
        await waitFor { client.journal?.snapshotCursor == 22 }

        XCTAssertEqual(messageContents(in: events), ["缺口一", "缺口二"])
        for event in events { client.acknowledgeAppliedEvent(event) }
        client.disconnect()
        await api.shutdownForHostSwitch()
    }

    func testUnappliedHistoryPageDoesNotAdvanceAPICoverage() async throws {
        let rpc = FakeHarnessRPCTransport()
        let stream = FakeHarnessStreamTransport()
        let pageRecord = messageRecordValue(
            type: HarnessWireEventType.assistantMessage,
            seq: 20,
            text: "尚未应用的历史页"
        )
        rpc.handler = { request in
            guard request.method == HarnessWireMethod.sessionPage else {
                return .failure(.rejected(status: 400, message: "unexpected method"))
            }
            return .success(.object([
                "hasMore": .bool(false),
                "records": .array([pageRecord]),
            ]))
        }
        let api = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            rpc: rpc,
            stream: stream
        )
        let page = try await loadLatestPage(api: api, stream: stream, snapshotCursor: 20)
        XCTAssertEqual(page.snapshotSeq, 20)

        let client = try XCTUnwrap(
            api.makeEventClient(sessionID: sessionID) as? HarnessSessionWebSocketClient
        )
        var events: [AgentEvent] = []
        client.onEvent = { events.append($0) }
        let frameIndex = stream.sentFrames.count
        // 模拟历史页尚未写入 Store：不传 afterSequence。API 也不能因“读取成功”猜测已应用。
        client.connect(sessionID: sessionID, replayBufferedEvents: false)
        let followID = try await waitForOpenStream(stream: stream, after: frameIndex)
        stream.push(carrierValue(
            streamID: followID,
            value: snapshotValue(cursor: 20, records: [pageRecord])
        ))
        await waitFor { client.journal?.snapshotCursor == 20 }

        XCTAssertEqual(messageContents(in: events), ["尚未应用的历史页"])
        client.disconnect()
        await api.shutdownForHostSwitch()
    }

    func testReplayDisabledRestoresActiveTurnWithoutReplayingCoveredContent() async throws {
        let opening = snapshot(
            cursor: 20,
            events: [
                messageEvent(type: HarnessWireEventType.userMessage, seq: 10, text: "旧正文"),
                turnEvent(type: HarnessWireEventType.turnStart, seq: 19, turn: 7),
            ]
        )
        var events: [AgentEvent] = []
        let client = makeClient(
            snapshot: opening,
            coveredSequence: { _ in 20 },
            reportCoveredSequence: { _, _ in },
            reconcile: { _, _ in HarnessDurableReconciliation() }
        )
        client.onEvent = { events.append($0) }

        client.connect(sessionID: sessionID, replayBufferedEvents: false)
        await waitFor { client.journal?.hasOpenedSnapshot == true }

        XCTAssertEqual(client.journal?.activeTurnNumber, 7)
        XCTAssertEqual(client.currentKnownTurnID(), "h-turn-7")
        XCTAssertTrue(messageContents(in: events).isEmpty)
        XCTAssertEqual(turnStartedIDs(in: events), ["h-turn-7"], "活动轮次只恢复一次状态事件")
    }

    func testReplayDisabledRestoresActiveAttemptPrefix() async throws {
        let activeAttempt = HarnessActiveAttempt(
            attemptId: "attempt-replay",
            startedAfterSeq: 20,
            turn: 8,
            step: 1,
            nextIndex: 1,
            stream: [.text(time0: 1, index: 0, dt: [], texts: ["进行中的前缀"])]
        )
        let opening = snapshot(
            cursor: 20,
            events: [turnEvent(type: HarnessWireEventType.turnStart, seq: 19, turn: 8)],
            assistantStream: HarnessAssistantStreamBaseline(
                revision: 1,
                activeAttempt: activeAttempt
            )
        )
        var events: [AgentEvent] = []
        let client = makeClient(
            snapshot: opening,
            coveredSequence: { _ in 20 },
            reportCoveredSequence: { _, _ in },
            reconcile: { _, _ in HarnessDurableReconciliation() }
        )
        client.onEvent = { events.append($0) }

        client.connect(sessionID: sessionID, replayBufferedEvents: false)
        await waitFor { client.journal?.activeAttempt?.attemptID == "attempt-replay" }

        XCTAssertEqual(client.currentKnownTurnID(), "h-turn-8")
        XCTAssertEqual(assistantDeltas(in: events), ["进行中的前缀"])
        XCTAssertEqual(turnStartedIDs(in: events), ["h-turn-8"])
    }

    func testAcknowledgedGapAndLiveEventsDoNotReplayOnReconnectOrCachedClientReopen() async throws {
        let rpc = FakeHarnessRPCTransport()
        let stream = FakeHarnessStreamTransport()
        let pageRecord = messageRecordValue(
            type: HarnessWireEventType.assistantMessage,
            seq: 20,
            text: "历史页末尾"
        )
        rpc.handler = { request in
            guard request.method == HarnessWireMethod.sessionPage else {
                return .failure(.rejected(status: 400, message: "unexpected method"))
            }
            return .success(.object([
                "hasMore": .bool(false),
                "records": .array([pageRecord]),
            ]))
        }
        let api = HarnessSessionAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            rpc: rpc,
            stream: stream
        )
        let page = try await loadLatestPage(api: api, stream: stream, snapshotCursor: 20)
        let client = try XCTUnwrap(
            api.makeEventClient(sessionID: sessionID) as? HarnessSessionWebSocketClient
        )
        var events: [AgentEvent] = []
        client.onEvent = { events.append($0) }

        let firstFrameIndex = stream.sentFrames.count
        client.connect(
            sessionID: sessionID,
            replayBufferedEvents: false,
            afterSequence: page.snapshotSeq
        )
        let firstFollow = try await waitForOpenStream(stream: stream, after: firstFrameIndex)
        let gapRecord = messageRecordValue(
            type: HarnessWireEventType.userMessage,
            seq: 21,
            text: "只发布一次的缺口"
        )
        stream.push(carrierValue(
            streamID: firstFollow,
            value: snapshotValue(cursor: 21, records: [gapRecord])
        ))
        await waitFor { messageContents(in: events).count == 1 }
        client.acknowledgeAppliedEvent(events[0])

        let liveRecord = messageRecordValue(
            type: HarnessWireEventType.assistantMessage,
            seq: 22,
            text: "只发布一次的直播"
        )
        stream.push(carrierValue(
            streamID: firstFollow,
            value: durableValue(record: liveRecord)
        ))
        await waitFor { messageContents(in: events).count == 2 }
        client.acknowledgeAppliedEvent(events[1])

        let reconnectFrameIndex = stream.sentFrames.count
        stream.push(HarnessCarrierFrame(
            type: HarnessWireCarrier.end,
            streamId: firstFollow,
            value: nil,
            error: nil
        ))
        let reconnectedFollow = try await waitForOpenStream(
            stream: stream,
            after: reconnectFrameIndex
        )
        stream.push(carrierValue(
            streamID: reconnectedFollow,
            value: snapshotValue(cursor: 22, records: [gapRecord, liveRecord])
        ))
        await waitFor { client.journal?.snapshotCursor == 22 }
        XCTAssertEqual(messageContents(in: events).count, 2, "自动重连不得重演已确认事件")

        client.disconnect()
        let reopenedFrameIndex = stream.sentFrames.count
        let reopened = try XCTUnwrap(
            api.makeEventClient(sessionID: sessionID) as? HarnessSessionWebSocketClient
        )
        reopened.onEvent = { events.append($0) }
        reopened.connect(
            sessionID: sessionID,
            replayBufferedEvents: false,
            afterSequence: page.snapshotSeq
        )
        let reopenedFollow = try await waitForOpenStream(
            stream: stream,
            after: reopenedFrameIndex
        )
        stream.push(carrierValue(
            streamID: reopenedFollow,
            value: snapshotValue(cursor: 22, records: [gapRecord, liveRecord])
        ))
        await waitFor { reopened.journal?.snapshotCursor == 22 }

        XCTAssertEqual(messageContents(in: events).count, 2, "同 API 缓存重开不得重演旧副作用")
        reopened.disconnect()
        await api.shutdownForHostSwitch()
    }

    func testOldClientAcknowledgementCannotConfirmNewClientEventWithSameSequence() async throws {
        let opening = snapshot(
            cursor: 21,
            events: [messageEvent(
                type: HarnessWireEventType.userMessage,
                seq: 21,
                text: "相同序列的新事件"
            )]
        )
        var coveredSequence: Int? = 20
        var reports: [Int] = []
        let report: @MainActor (SessionID, Int) -> Void = { _, seq in
            reports.append(seq)
            coveredSequence = max(coveredSequence ?? seq, seq)
        }
        let first = makeClient(
            snapshot: opening,
            coveredSequence: { _ in coveredSequence },
            reportCoveredSequence: report,
            reconcile: { _, _ in HarnessDurableReconciliation() }
        )
        var firstEvents: [AgentEvent] = []
        first.onEvent = { firstEvents.append($0) }
        first.connect(sessionID: sessionID, replayBufferedEvents: false)
        await waitFor { firstEvents.count == 1 }
        XCTAssertTrue(reports.isEmpty, "未确认的旧客户端事件不得推进前沿")

        let second = makeClient(
            snapshot: opening,
            coveredSequence: { _ in coveredSequence },
            reportCoveredSequence: report,
            reconcile: { _, _ in HarnessDurableReconciliation() }
        )
        var secondEvents: [AgentEvent] = []
        second.onEvent = { secondEvents.append($0) }
        second.connect(sessionID: sessionID, replayBufferedEvents: false)
        await waitFor { secondEvents.count == 1 }

        // Store 的旧 mailbox 可能在新客户端建立后才完成；全局 epoch 必须拒绝这次迟到确认。
        second.acknowledgeAppliedEvent(firstEvents[0])
        XCTAssertTrue(reports.isEmpty)
        second.acknowledgeAppliedEvent(secondEvents[0])
        XCTAssertEqual(reports, [21])
        first.disconnect()
        second.disconnect()
    }

    func testPendingAssistantDurableBlocksCoverageUntilSettlementPublishesIt() async throws {
        var reports: [Int] = []
        var events: [AgentEvent] = []
        let client = makeClient(
            snapshot: snapshot(cursor: 20, events: []),
            coveredSequence: { _ in 20 },
            reportCoveredSequence: { _, seq in reports.append(seq) },
            reconcile: { _, _ in HarnessDurableReconciliation() }
        )
        client.onEvent = { events.append($0) }
        client.connect(sessionID: sessionID, replayBufferedEvents: false)
        await waitFor { client.journal?.hasOpenedSnapshot == true }

        XCTAssertNil(client.apply(assistantStream: HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.start,
            revision: 1,
            index: nil,
            chunk: nil,
            outcome: nil,
            attemptId: "attempt-barrier",
            turn: 9,
            step: 1,
            startedAfterSeq: 20
        )))
        XCTAssertNil(client.apply(assistantStream: HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.chunk,
            revision: 2,
            index: 0,
            chunk: HarnessAssistantChunk(
                type: HarnessWireChunkType.textDelta,
                index: 0,
                text: "等待结算",
                blockType: nil,
                argumentsDelta: nil
            ),
            outcome: nil,
            attemptId: "attempt-barrier",
            turn: nil,
            step: nil,
            startedAfterSeq: nil
        )))
        XCTAssertTrue(client.apply(durableEvent: messageEvent(
            type: HarnessWireEventType.assistantMessage,
            seq: 21,
            text: "等待结算"
        )))
        XCTAssertTrue(client.apply(durableEvent: messageEvent(
            type: HarnessWireEventType.userMessage,
            seq: 22,
            text: "更晚的事件"
        )))
        let later = try XCTUnwrap(events.first { replayBoundary(of: $0) == 22 })
        client.acknowledgeAppliedEvent(later)
        XCTAssertTrue(reports.isEmpty, "不能越过等待 end 的 assistant durable 推进覆盖位置")

        XCTAssertNil(client.apply(assistantStream: HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.end,
            revision: 3,
            index: 1,
            chunk: nil,
            outcome: HarnessAssistantStreamOutcome(
                kind: "committed",
                eventType: HarnessWireSettlement.assistantMessage,
                seq: 21
            ),
            attemptId: "attempt-barrier",
            turn: nil,
            step: nil,
            startedAfterSeq: nil
        )))
        client.settleActiveAttempt()
        let settled = try XCTUnwrap(events.first { replayBoundary(of: $0) == 21 })
        client.acknowledgeAppliedEvent(settled)

        XCTAssertEqual(reports, [22], "较早 pending 发布并确认后才可一次推进到已确认前沿")
    }

    func testOpeningAssistantDurableWaitsForActiveAttemptSettlement() async throws {
        let attempt = HarnessActiveAttempt(
            attemptId: "attempt-opening-pending",
            startedAfterSeq: 20,
            turn: 10,
            step: 1,
            nextIndex: 1,
            stream: [.text(time0: 1, index: 0, dt: [], texts: ["同一条回复"])]
        )
        let opening = snapshot(
            cursor: 21,
            events: [messageEvent(
                type: HarnessWireEventType.assistantMessage,
                seq: 21,
                text: "同一条回复"
            )],
            assistantStream: HarnessAssistantStreamBaseline(revision: 1, activeAttempt: attempt)
        )
        var reports: [Int] = []
        var events: [AgentEvent] = []
        let client = makeClient(
            snapshot: opening,
            coveredSequence: { _ in 20 },
            reportCoveredSequence: { _, seq in reports.append(seq) },
            reconcile: { _, _ in HarnessDurableReconciliation() }
        )
        client.onEvent = { events.append($0) }
        client.connect(sessionID: sessionID, replayBufferedEvents: false)
        await waitFor { client.journal?.activeAttempt?.attemptID == "attempt-opening-pending" }

        let prefixID = try XCTUnwrap(events.compactMap { event -> MessageID? in
            guard case .assistantDelta(_, let metadata) = event else { return nil }
            return metadata.messageID
        }.first)
        XCTAssertEqual(prefixID, "h-attempt-attempt-opening-pending-assistant")
        XCTAssertFalse(events.contains { replayBoundary(of: $0) == 21 })
        XCTAssertTrue(reports.isEmpty)

        XCTAssertNil(client.apply(assistantStream: HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.end,
            revision: 2,
            index: 1,
            chunk: nil,
            outcome: HarnessAssistantStreamOutcome(
                kind: "committed",
                eventType: HarnessWireSettlement.assistantMessage,
                seq: 21
            ),
            attemptId: "attempt-opening-pending",
            turn: nil,
            step: nil,
            startedAfterSeq: nil
        )))
        client.settleActiveAttempt()

        let applied = try XCTUnwrap(events.first { replayBoundary(of: $0) == 21 })
        guard case .messageCompleted(let message, _) = applied else {
            return XCTFail("结算后必须发布等待中的 durable assistant")
        }
        XCTAssertEqual(message.id, prefixID, "durable 必须复用已经展示的 attempt 身份")
        client.acknowledgeAppliedEvent(applied)
        XCTAssertEqual(reports, [21])
    }

    private func makeClient(
        snapshot: HarnessSnapshot,
        coveredSequence: @escaping @MainActor (SessionID) -> Int?,
        reportCoveredSequence: @escaping @MainActor (SessionID, Int) -> Void,
        reconcile: @escaping @MainActor (
            SessionID,
            HarnessDurableEvent
        ) -> HarnessDurableReconciliation,
        settleAssistantIdentity: @escaping @MainActor (
            SessionID,
            Int,
            MessageID
        ) -> MessageID = { _, _, attemptMessageID in attemptMessageID }
    ) -> HarnessSessionWebSocketClient {
        HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: HarnessSubmissionController(
                sendPrompt: { _, _, _ in },
                sendCancel: { _ in }
            ),
            fetchSnapshot: { _ in snapshot },
            reconcileDurableEvent: reconcile,
            settleAssistantIdentity: settleAssistantIdentity,
            coveredDurableSequence: coveredSequence,
            reportCoveredDurableSequence: reportCoveredSequence
        )
    }

    private func snapshot(
        cursor: Int,
        events: [HarnessDurableEvent],
        assistantStream: HarnessAssistantStreamBaseline = HarnessAssistantStreamBaseline(
            revision: 0,
            activeAttempt: nil
        )
    ) -> HarnessSnapshot {
        HarnessSnapshot(
            type: HarnessWireFrame.snapshot,
            header: HarnessSnapshotHeader(
                version: 3,
                id: sessionID,
                createdAt: nil,
                cwd: "/fixture",
                isSeeded: false,
                agentPreset: nil
            ),
            cursor: cursor,
            records: events.map { HarnessSnapshotRecord(type: "event", event: $0) },
            hasMore: false,
            projections: nil,
            assistantStream: assistantStream
        )
    }

    private func turnEvent(type: String, seq: Int, turn: Int) -> HarnessDurableEvent {
        HarnessDurableEvent(
            type: type,
            seq: seq,
            time: nil,
            data: .object(["turn": .number(Double(turn))])
        )
    }

    private func messageEvent(type: String, seq: Int, text: String) -> HarnessDurableEvent {
        let message: HarnessJSONValue = .object([
            "id": .string("message-\(seq)"),
            "role": .string(type == HarnessWireEventType.userMessage ? "user" : "assistant"),
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(text),
            ])]),
        ])
        var data: [String: HarnessJSONValue] = ["message": message]
        if type == HarnessWireEventType.userMessage {
            data["content"] = message["content"]
            data["source"] = .object(["kind": .string("user")])
        }
        return HarnessDurableEvent(type: type, seq: seq, time: nil, data: .object(data))
    }

    private func messageContents(in events: [AgentEvent]) -> [String] {
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

    private func turnStartedIDs(in events: [AgentEvent]) -> [TurnID] {
        events.compactMap { event in
            guard case .turnStarted(let metadata) = event else { return nil }
            return metadata.turnID
        }
    }

    private func turnCompletedIDs(in events: [AgentEvent]) -> [TurnID] {
        events.compactMap { event in
            guard case .turnCompleted(let metadata) = event else { return nil }
            return metadata.turnID
        }
    }

    private func sessionStatuses(in events: [AgentEvent]) -> [String] {
        events.compactMap { event in
            guard case .sessionStatus(let status, _) = event else { return nil }
            return status
        }
    }

    private func replayBoundary(of event: AgentEvent) -> UInt64? {
        switch event {
        case .turnStarted(let metadata), .turnCompleted(let metadata),
             .messageCompleted(_, let metadata), .processItemCompleted(_, _, let metadata):
            return metadata.replayBoundarySequence
        default:
            return nil
        }
    }

    private func loadLatestPage(
        api: HarnessSessionAPIClient,
        stream: FakeHarnessStreamTransport,
        snapshotCursor: Int
    ) async throws -> HistoryMessagesPage {
        let frameIndex = stream.sentFrames.count
        let task = Task {
            try await api.messagesPage(
                sessionID: sessionID,
                before: nil,
                limit: 20,
                loadMode: .full
            )
        }
        let followID = try await waitForOpenStream(stream: stream, after: frameIndex)
        stream.push(carrierValue(
            streamID: followID,
            value: snapshotValue(cursor: snapshotCursor, records: [])
        ))
        return try await task.value
    }

    private func waitForOpenStream(
        stream: FakeHarnessStreamTransport,
        after frameIndex: Int
    ) async throws -> String {
        for _ in 0..<400 {
            for frame in stream.sentFrames.dropFirst(frameIndex) {
                if case .open(let streamID, let endpoint, _) = frame,
                   endpoint == HarnessWireEndpoint.sessionFollow {
                    return streamID
                }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw HarnessTransportError.timedOut
    }

    private func carrierValue(
        streamID: String,
        value: HarnessJSONValue
    ) -> HarnessCarrierFrame {
        HarnessCarrierFrame(
            type: HarnessWireCarrier.item,
            streamId: streamID,
            value: value,
            error: nil
        )
    }

    private func snapshotValue(
        cursor: Int,
        records: [HarnessJSONValue]
    ) -> HarnessJSONValue {
        .object([
            "type": .string(HarnessWireFrame.snapshot),
            "header": .object([
                "version": .number(3),
                "id": .string(sessionID),
                "cwd": .string("/fixture"),
                "isSeeded": .bool(false),
            ]),
            "cursor": .number(Double(cursor)),
            "records": .array(records),
            "hasMore": .bool(false),
            "assistantStream": .object(["revision": .number(0)]),
        ])
    }

    private func messageRecordValue(
        type: String,
        seq: Int,
        text: String
    ) -> HarnessJSONValue {
        let content: HarnessJSONValue = .array([.object([
            "type": .string("text"),
            "text": .string(text),
        ])])
        var data: [String: HarnessJSONValue] = [
            "message": .object([
                "id": .string("message-\(seq)"),
                "role": .string(type == HarnessWireEventType.userMessage ? "user" : "assistant"),
                "content": content,
            ]),
        ]
        if type == HarnessWireEventType.userMessage {
            data["content"] = content
            data["source"] = .object(["kind": .string("user")])
        }
        return .object([
            "type": .string("event"),
            "event": .object([
                "type": .string(type),
                "seq": .number(Double(seq)),
                "data": .object(data),
            ]),
        ])
    }

    private func durableValue(record: HarnessJSONValue) -> HarnessJSONValue {
        .object([
            "type": .string(HarnessWireFrame.durableEvent),
            "event": record["event"] ?? .object([:]),
        ])
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("等待 Harness opening snapshot 超时")
    }
}
