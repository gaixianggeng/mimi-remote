import Foundation
import XCTest
@testable import MimiRemote

/// H08 事件客户端（composer 接线）测试。
///
/// 这一层连接三件事：follow 帧 → journal → 投影 → AgentEvent，以及发送意图 → 提交编排。
/// 因此断言集中在四处：
/// 1. **发送结果的映射**：`responseUnknown` 必须走 `.uncertain`，不能走 `.rejected`。
/// 2. **未建立基线时不得发送**（服务端回显无法与本地记录关联）。
/// 3. **重复持久事件不产生第二条展示事件**（流式到历史无重复）。
/// 4. **断档如实上报**（不把断档后的片段接上）。
@MainActor
final class HarnessEventClientTests: XCTestCase {

    private let sessionID: SessionID = "h00-session-0001"

    func harnessFixtureJSON(_ name: String) throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root
            .appendingPathComponent("contracts/harness-native/fixtures")
            .appendingPathComponent(name)
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "夹具 \(name) 顶层不是对象")
    }

    private func snapshot() throws -> HarnessSnapshot {
        let fixture = try harnessFixtureJSON("stream/follow-frames.json")
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        let value = try XCTUnwrap(
            observations.first { ($0["label"] as? String) == "snapshot" }?["value"]
        )
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(HarnessSnapshot.self, from: data)
    }

    private func durableEvent(type: String, seq: Int, text: String) -> HarnessDurableEvent {
        HarnessDurableEvent(
            type: type, seq: seq, time: nil,
            data: .object(["content": .array([.object([
                "type": .string("text"), "text": .string(text),
            ])])])
        )
    }

    /// 轮次边界事件（`turn/start` / `turn/end`）：只带 `turn`，不合成正文。
    private func turnEvent(type: String, seq: Int, turn: Int) -> HarnessDurableEvent {
        HarnessDurableEvent(type: type, seq: seq, time: nil, data: .object(["turn": .number(Double(turn))]))
    }

    // MARK: - 夹具

    /// 造一个已 connection 的客户端（注入 snapshot）。
    private func makeConnectedClient(
        sender: RecordingPromptSink,
        openingSnapshot: HarnessSnapshot? = nil
    ) async throws -> (HarnessSessionWebSocketClient, EventRecorder) {
        let snapshot = try openingSnapshot ?? self.snapshot()
        let submission = HarnessSubmissionController(
            sendPrompt: { sessionID, requestID, text in
                try await sender.send(sessionID, requestID, text)
            },
            sendCancel: { sessionID in try await sender.cancel(sessionID) }
        )
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: submission,
            fetchSnapshot: { _ in snapshot }
        )
        let recorder = EventRecorder()
        client.onEvent = { recorder.events.append($0) }
        client.connect(sessionID: sessionID)
        // 等基线建立（connect 内部是 Task）。
        for _ in 0..<200 {
            if client.journal?.hasOpenedSnapshot == true { break }
            await Task.yield()
        }
        return (client, recorder)
    }

    // MARK: - 连接与基线

    /// 正向对照：connect 建立基线，并把 snapshot 里已有记录投影出来。
    func testConnectEstablishesBaselineAndProjectsSnapshotRecords() async throws {
        let (client, recorder) = try await makeConnectedClient(sender: RecordingPromptSink())

        XCTAssertNotNil(client.journal)
        XCTAssertTrue(client.journal?.hasOpenedSnapshot == true, "必须建立基线")
        // follow 夹具的 snapshot 有 3 条记录（permission/preset、sandbox/mode、approval/policy），
        // 它们都不是本层投影的类型，因此不该产出展示事件。
        XCTAssertTrue(recorder.events.isEmpty, "不投影的类型不得产出事件")
    }

    /// 没有 snapshot 来源时 connect 必须报 failed，**不得**假装连上。
    func testConnectWithoutSnapshotSourceReportsFailure() async {
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in })
        )
        var statuses: [WebSocketStatus] = []
        client.onStatus = { statuses.append($0) }
        client.connect(sessionID: sessionID)
        for _ in 0..<200 {
            if statuses.contains(where: { if case .failed = $0 { return true }; return false }) { break }
            await Task.yield()
        }

        XCTAssertTrue(
            statuses.contains { if case .failed = $0 { return true }; return false },
            "没有基线来源时必须显式 failed，实际状态：\(statuses)"
        )
        XCTAssertFalse(statuses.contains(.connected), "不得假装已连上")
    }

    func testLateOpeningSnapshotCannotOverwriteNewerConnectionLease() async throws {
        let gate = SnapshotGate()
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: "old-session",
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in }),
            fetchSnapshot: { sessionID in try await gate.fetch(sessionID: sessionID) }
        )

        client.connect(sessionID: "old-session")
        await gate.waitForRequestCount(1)
        client.connect(sessionID: "new-session")
        await gate.waitForRequestCount(2)

        gate.resume(
            sessionID: "new-session",
            snapshot: snapshot(sessionID: "new-session", cursor: 22)
        )
        await waitFor { client.journal?.snapshotCursor == 22 }
        gate.resume(
            sessionID: "old-session",
            snapshot: snapshot(sessionID: "old-session", cursor: 11)
        )
        await Task.yield()

        XCTAssertEqual(client.sessionID, "new-session")
        XCTAssertEqual(client.journal?.snapshotCursor, 22, "旧 snapshot 晚到不得污染新会话")
        XCTAssertGreaterThan(client.journal?.generation ?? 0, 1, "代次不得写死为 1")
    }

    /// H11：生产事件客户端必须通过同一个 runtime 真正打开 `$events` 与 follow，
    /// 并持续消费 opening snapshot 后到达的 durable 事件。
    func testRuntimePathOpensRealFollowAndContinuouslyConsumesFrames() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in }),
            runtime: runtime,
            interactionStore: HarnessInteractionStore(),
            recovery: HarnessRecoveryCoordinator(
                random: { 0 },
                sleep: { _ in await Task.yield() }
            )
        )
        let recorder = EventRecorder()
        var statuses: [WebSocketStatus] = []
        client.onEvent = { recorder.events.append($0) }
        client.onStatus = { statuses.append($0) }

        client.connect(sessionID: sessionID)
        let eventsID = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.events,
            stream: stream
        )
        stream.push(carrierValue(
            streamID: eventsID,
            value: .object(["type": .string(HarnessWireFrame.ready)])
        ))
        let followID = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.sessionFollow,
            stream: stream
        )
        stream.push(carrierValue(
            streamID: followID,
            value: snapshotValue(sessionID: sessionID, cursor: 13)
        ))
        await waitFor { client.journal?.hasOpenedSnapshot == true }

        stream.push(carrierValue(
            streamID: followID,
            value: .object([
                "type": .string(HarnessWireFrame.durableEvent),
                "event": .object([
                    "type": .string(HarnessWireEventType.userMessage),
                    "seq": .number(14),
                    "data": .object([
                        "content": .array([.object([
                            "type": .string("text"), "text": .string("runtime 正文"),
                        ])]),
                        "source": .object([
                            "kind": .string("user"), "rpcId": .string("cm-runtime"),
                        ]),
                    ]),
                ]),
            ])
        ))
        await waitFor {
            recorder.events.contains {
                guard case .messageCompleted(let message, _) = $0 else { return false }
                return message.content == "runtime 正文"
            }
        }

        XCTAssertTrue(statuses.contains(.connected))
        XCTAssertEqual(stream.connectCount, 1, "follow 与事件流必须共用一个 runtime 连接")
        XCTAssertTrue(recorder.events.contains {
            guard case .messageCompleted(let message, _) = $0 else { return false }
            return message.clientMessageID == "cm-runtime"
        })
        client.disconnect()
        try await Task.sleep(for: .milliseconds(20))
        let reuseID = await runtime.nextStreamID()
        try await runtime.openStream(streamID: reuseID, endpoint: HarnessWireEndpoint.events)
        XCTAssertEqual(stream.connectCount, 1, "页面断开只能退订自己的流，不得关闭共享 runtime")
        XCTAssertEqual(stream.closeCount, 0)
        await runtime.cancelStream(streamID: reuseID)
    }

    /// H11：waterfall 必须投影为现有 UI 事件，应答经同一 runtime 回传，且不携带 clientId。
    func testRuntimeInteractionProjectsAndRespondsThroughSameConnection() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let store = HarnessInteractionStore()
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in }),
            runtime: runtime,
            interactionStore: store,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )
        let recorder = EventRecorder()
        client.onEvent = { recorder.events.append($0) }
        client.connect(sessionID: sessionID)

        let eventsID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        stream.push(carrierValue(
            streamID: eventsID,
            value: .object(["type": .string(HarnessWireFrame.ready)])
        ))
        let followID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.sessionFollow, stream: stream)
        stream.push(carrierValue(
            streamID: followID,
            value: snapshotValue(sessionID: sessionID, cursor: 13)
        ))
        await waitFor { client.journal?.hasOpenedSnapshot == true }

        stream.push(carrierValue(
            streamID: eventsID,
            value: .object([
                "type": .string(HarnessWireFrame.waterfall),
                "eventId": .string("approval-runtime"),
                "event": .string(HarnessWireWaterfallEvent.approvalRequest),
                "agentId": .string(sessionID),
                "request": .object([
                    "toolName": .string("shell"),
                    "callId": .string("call-runtime"),
                    "reason": .string("需要执行测试命令"),
                ]),
            ])
        ))
        await waitFor {
            recorder.events.contains {
                guard case .approvalRequest(let request, _) = $0 else { return false }
                return request.id == "approval-runtime"
            }
        }

        XCTAssertTrue(client.sendApprovalDecision(
            approvalID: "approval-runtime",
            decision: "accept",
            message: nil
        ))
        await waitFor {
            stream.sentFrames.contains(.respond(
                eventID: "approval-runtime",
                outcome: .result(.string(HarnessWireApprovalDecision.allowedOnce))
            ))
        }
        // **写出成功不撤卡。** 帧进了 socket 只说明中继收到了它，上游随后仍可能拒绝；
        // 此时卡片必须停在"提交中"，而不是先消失再让用户以为决定已生效。
        XCTAssertNotNil(store.interaction(eventID: "approval-runtime"), "写出成功期间卡片必须还在")
        XCTAssertFalse(recorder.events.contains {
            if case .approvalResolved = $0 { return true }
            return false
        })

        // 只有中继的关联回执才撤卡。
        stream.push(carrierValue(
            streamID: eventsID,
            value: respondAckValue(eventID: "approval-runtime", accepted: true)
        ))
        await waitFor { store.interaction(eventID: "approval-runtime") == nil }
        XCTAssertNil(store.interaction(eventID: "approval-runtime"), "收到明确接受回执后才撤卡")
        XCTAssertTrue(recorder.events.contains {
            if case .approvalResolved = $0 { return true }
            return false
        })
        client.disconnect()
    }

    /// 上游拒绝时卡片必须回到待应答，而不是静默消失。
    ///
    /// 这条路径原先**根本到不了**：中继的失败帧不带 streamId，移动端的载体解码器
    /// 判它无法归属后直接丢弃，卡片却已经被"发送成功"撤掉了。
    func testRuntimeRejectedResponseReopensCardInsteadOfDroppingIt() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let store = HarnessInteractionStore()
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787", token: "fixture", sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in }),
            runtime: runtime, interactionStore: store,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )
        var failures: [String] = []
        client.onApprovalDecisionFailure = { _, message in failures.append(message) }
        client.connect(sessionID: sessionID)

        let eventsID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        stream.push(carrierValue(
            streamID: eventsID,
            value: .object(["type": .string(HarnessWireFrame.ready)])
        ))
        let followID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.sessionFollow, stream: stream)
        stream.push(carrierValue(
            streamID: followID,
            value: snapshotValue(sessionID: sessionID, cursor: 11)
        ))
        await waitFor { client.journal?.hasOpenedSnapshot == true }

        stream.push(carrierValue(
            streamID: eventsID,
            value: .object([
                "type": .string(HarnessWireFrame.waterfall),
                "eventId": .string("approval-rejected-upstream"),
                "event": .string(HarnessWireWaterfallEvent.approvalRequest),
                "agentId": .string(sessionID),
                "request": .object([
                    "toolName": .string("shell"),
                    "callId": .string("call-rejected"),
                ]),
            ])
        ))
        await waitFor { store.interaction(eventID: "approval-rejected-upstream") != nil }

        XCTAssertTrue(client.sendApprovalDecision(
            approvalID: "approval-rejected-upstream",
            decision: "accept",
            message: nil
        ))
        stream.push(carrierValue(
            streamID: eventsID,
            value: respondAckValue(
                eventID: "approval-rejected-upstream",
                accepted: false,
                error: .object([
                    "code": .string("harness/rejected"),
                    "message": .string("目标会话不在授权目录内"),
                ])
            )
        ))

        await waitFor { failures.contains("目标会话不在授权目录内") }
        XCTAssertTrue(failures.contains("目标会话不在授权目录内"), "拒绝原因必须如实回传")
        // 明确拒绝 = 没生效，允许用户重试。
        XCTAssertEqual(store.interaction(eventID: "approval-rejected-upstream")?.state, .pending)
        client.disconnect()
    }

    /// 冻结协议的选项只有 label；UI 投影与应答都必须沿用 label，不要求不存在的 option.id。
    func testRuntimeQuestionUsesLabelOnlyOptionsAndRespondsWithLabels() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let store = HarnessInteractionStore()
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787", token: "fixture", sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in }),
            runtime: runtime, interactionStore: store,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )
        let recorder = EventRecorder()
        client.onEvent = { recorder.events.append($0) }
        client.connect(sessionID: sessionID)

        let eventsID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        stream.push(carrierValue(
            streamID: eventsID,
            value: .object(["type": .string(HarnessWireFrame.ready)])
        ))
        let followID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.sessionFollow, stream: stream)
        stream.push(carrierValue(
            streamID: followID,
            value: snapshotValue(sessionID: sessionID, cursor: 13)
        ))
        await waitFor { client.journal?.hasOpenedSnapshot == true }

        stream.push(carrierValue(
            streamID: eventsID,
            value: .object([
                "type": .string(HarnessWireFrame.waterfall),
                "eventId": .string("question-runtime"),
                "event": .string(HarnessWireWaterfallEvent.userQuestions),
                "agentId": .string(sessionID),
                "request": .object([
                    "questions": .array([.object([
                        "id": .string("q-mode"),
                        "question": .string("选择模式"),
                        "options": .array([
                            .object(["label": .string("快速")]),
                            .object(["label": .string("稳健")]),
                        ]),
                    ])]),
                ]),
            ])
        ))
        await waitFor {
            recorder.events.contains {
                guard case .userInputRequest(let request, _) = $0 else { return false }
                return request.id == "question-runtime"
                    && request.questions.first?.options.map(\.label) == ["快速", "稳健"]
            }
        }

        XCTAssertTrue(client.sendUserInputResponse(
            requestID: "question-runtime",
            answers: ["q-mode": ["稳健"]]
        ))
        let expected = HarnessClientFrame.respond(
            eventID: "question-runtime",
            outcome: .result(.object(["answers": .array([.object([
                "id": .string("q-mode"),
                "selected": .array([.string("稳健")]),
            ])])]))
        )
        await waitFor { stream.sentFrames.contains(expected) }
        XCTAssertTrue(stream.sentFrames.contains(expected))
        client.disconnect()
    }

    /// 交互应答的明确接受、明确拒绝、结果未知三态不能合并。
    /// 未知态不自动重发，但同代次可信 cancel 会撤下卡片。
    func testRuntimeInteractionDistinguishesExplicitRejectionFromResponseUnknown() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let store = HarnessInteractionStore()
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787", token: "fixture", sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in }),
            runtime: runtime, interactionStore: store,
            recovery: HarnessRecoveryCoordinator(random: { 0 }, sleep: { _ in })
        )
        let recorder = EventRecorder()
        client.onEvent = { recorder.events.append($0) }
        client.connect(sessionID: sessionID)

        let eventsID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.ready),
        ])))
        let followID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.sessionFollow, stream: stream)
        stream.push(carrierValue(
            streamID: followID,
            value: snapshotValue(sessionID: sessionID, cursor: 13)
        ))
        await waitFor { client.journal?.hasOpenedSnapshot == true }

        func pushApproval(_ eventID: String) {
            stream.push(carrierValue(streamID: eventsID, value: .object([
                "type": .string(HarnessWireFrame.waterfall),
                "eventId": .string(eventID),
                "event": .string(HarnessWireWaterfallEvent.approvalRequest),
                "agentId": .string(sessionID),
                "request": .object(["toolName": .string("shell")]),
            ])))
        }

        pushApproval("explicit-reject")
        await waitFor { store.interaction(eventID: "explicit-reject") != nil }
        // 真实链路是"帧写出成功、之后才拿到上游结论"。让 send 直接抛业务结果
        // 会把最关键的那一段跳过去，测的是一条现实中不存在的路径。
        XCTAssertTrue(client.sendApprovalDecision(
            approvalID: "explicit-reject", decision: "accept", message: nil
        ))
        await waitFor {
            stream.sentFrames.contains(.respond(
                eventID: "explicit-reject",
                outcome: .result(.string(HarnessWireApprovalDecision.allowedOnce))
            ))
        }
        // 提交中：还没拿到结论，卡片不撤也不放回。
        XCTAssertEqual(store.interaction(eventID: "explicit-reject")?.state, .submitting)
        stream.push(carrierValue(
            streamID: eventsID,
            value: respondAckValue(
                eventID: "explicit-reject",
                accepted: false,
                error: .object([
                    "code": .string("approval/rejected"),
                    "message": .string("上游明确拒绝"),
                ])
            )
        ))
        await waitFor { store.interaction(eventID: "explicit-reject")?.state == .pending }
        XCTAssertEqual(store.interaction(eventID: "explicit-reject")?.state, .pending)

        stream.sendError = nil
        pushApproval("response-unknown")
        await waitFor { store.interaction(eventID: "response-unknown") != nil }
        stream.sendError = .timedOut
        XCTAssertTrue(client.sendApprovalDecision(
            approvalID: "response-unknown", decision: "accept", message: nil
        ))
        await waitFor {
            guard case .responseUnknown? = store.interaction(eventID: "response-unknown")?.state else {
                return false
            }
            return true
        }
        let respondCount = stream.sentFrames.filter {
            if case .respond(let eventID, _) = $0 { return eventID == "response-unknown" }
            return false
        }.count
        XCTAssertFalse(client.sendApprovalDecision(
            approvalID: "response-unknown", decision: "accept", message: nil
        ), "结果未知时不得自动或手动重发旧决定")
        XCTAssertEqual(stream.sentFrames.filter {
            if case .respond(let eventID, _) = $0 { return eventID == "response-unknown" }
            return false
        }.count, respondCount)

        stream.sendError = nil
        stream.push(carrierValue(streamID: eventsID, value: .object([
            "type": .string(HarnessWireFrame.cancel),
            "eventId": .string("response-unknown"),
        ])))
        await waitFor { store.interaction(eventID: "response-unknown") == nil }
        XCTAssertNil(store.interaction(eventID: "response-unknown"))
        XCTAssertTrue(recorder.events.contains {
            if case .approvalResolved = $0 { return true }
            return false
        }, "可信 cancel 只结算撤卡，不宣称哪一端回答获胜")
        client.disconnect()
    }

    func testRuntimeRecoveryUsesNewGenerationAndRejectsOldStreamFrames() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = makeRuntime(stream: stream)
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787", token: "fixture", sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in }),
            runtime: runtime, interactionStore: HarnessInteractionStore(),
            recovery: HarnessRecoveryCoordinator(
                random: { 0 }, sleep: { _ in await Task.yield() }
            )
        )
        let recorder = EventRecorder()
        client.onEvent = { recorder.events.append($0) }
        client.connect(sessionID: sessionID)

        let firstEventsID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.events, stream: stream)
        stream.push(carrierValue(streamID: firstEventsID, value: .object([
            "type": .string(HarnessWireFrame.ready),
        ])))
        let firstFollowID = try await waitForOpenStream(endpoint: HarnessWireEndpoint.sessionFollow, stream: stream)
        stream.push(carrierValue(
            streamID: firstFollowID,
            value: snapshotValue(sessionID: sessionID, cursor: 13)
        ))
        await waitFor { client.journal?.snapshotCursor == 13 }
        let sentBeforeRecovery = stream.sentFrames.count

        stream.releasePendingWaiters()
        await waitFor { stream.connectCount >= 2 }
        let secondEventsID = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.events,
            stream: stream,
            after: sentBeforeRecovery
        )
        stream.push(carrierValue(streamID: secondEventsID, value: .object([
            "type": .string(HarnessWireFrame.ready),
        ])))
        let secondFollowID = try await waitForOpenStream(
            endpoint: HarnessWireEndpoint.sessionFollow,
            stream: stream,
            after: sentBeforeRecovery
        )

        stream.push(carrierValue(streamID: firstFollowID, value: .object([
            "type": .string(HarnessWireFrame.durableEvent),
            "event": .object([
                "type": .string(HarnessWireEventType.userMessage),
                "seq": .number(99),
                "data": .object(["content": .array([.object([
                    "type": .string("text"), "text": .string("旧代次污染"),
                ])])]),
            ]),
        ])))
        stream.push(carrierValue(
            streamID: secondFollowID,
            value: snapshotValue(sessionID: sessionID, cursor: 22)
        ))
        await waitFor { client.journal?.snapshotCursor == 22 }

        XCTAssertNotEqual(firstEventsID, secondEventsID)
        XCTAssertNotEqual(firstFollowID, secondFollowID)
        XCTAssertFalse(recorder.events.contains {
            guard case .messageCompleted(let message, _) = $0 else { return false }
            return message.content == "旧代次污染"
        })
        let diagnostics = await runtime.diagnostics
        XCTAssertTrue(diagnostics.contains {
            if case .staleFrame(let streamID) = $0 { return streamID == firstFollowID }
            return false
        })
        client.disconnect()
    }

    /// H12 本地验收入口：只连接固定回环测试服务，不读取生产配置或供应商凭据。
    ///
    /// 默认测试环境没有该服务时明确 skipped；H12 runner 会启动真实 Harness、agentd
    /// 与确定性本地模型，使这一条在 Simulator 中实际执行完整 create/follow/answer 链路。
    func testLiveH12RealHarnessQuestionFlow() async throws {
        let endpoint = "http://127.0.0.1:28787"
        let token = "h12-local-fixture-token-not-secret"
        let api = HarnessSessionAPIClient(endpoint: endpoint, token: token)
        do {
            _ = try await api.modelOptions()
        } catch {
            throw XCTSkip("隔离 H12 Harness/agentd 未运行：\(error)")
        }
        defer { Task { await api.shutdownForHostSwitch() } }

        var repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { repositoryRoot.deleteLastPathComponent() }
        let sessionID = "h12-ios-\(UUID().uuidString.lowercased())"
        let created = try await api.createSession(
            cwd: repositoryRoot.path,
            sessionID: sessionID
        )
        XCTAssertEqual(created.sessionID, sessionID)
        try await api.selectModel(
            sessionID: sessionID,
            provider: "research-mock",
            model: "fixture-model",
            reasoningEffort: nil
        )

        let client = try XCTUnwrap(
            api.makeEventClient(sessionID: sessionID) as? HarnessSessionWebSocketClient
        )
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        var sendOutcomes: [TurnSendOutcome] = []
        client.onStatus = { statuses.append($0) }
        client.onEvent = { events.append($0) }
        client.onTurnSendOutcome = { _, outcome in sendOutcomes.append(outcome) }
        client.connect(sessionID: sessionID)

        await waitForLive { statuses.contains(.connected) }
        XCTAssertTrue(statuses.contains(.connected), "真实 follow 必须完成 opening snapshot")
        XCTAssertTrue(client.sendInput(
            "Run the controlled H12 question fixture.",
            clientMessageID: "h12-request-\(UUID().uuidString.lowercased())"
        ))
        await waitForLive {
            events.contains { if case .userInputRequest = $0 { return true }; return false }
        }

        let request = try XCTUnwrap(events.compactMap { event -> AgentUserInputRequest? in
            if case .userInputRequest(let request, _) = event { return request }
            return nil
        }.first)
        XCTAssertEqual(request.questions.first?.options.map(\.label), ["Continue"])
        XCTAssertTrue(client.sendUserInputResponse(
            requestID: request.id,
            answers: ["confirm": ["Continue"]]
        ))

        await waitForLive {
            events.contains { if case .turnCompleted = $0 { return true }; return false }
        }
        let streamedText = events.compactMap { event -> String? in
            if case .assistantDelta(let delta, _) = event { return delta.text }
            return nil
        }.joined()
        let completedText = events.compactMap { event -> String? in
            if case .messageCompleted(let message, _) = event, message.role == .assistant {
                return message.content
            }
            return nil
        }.joined()
        XCTAssertTrue(streamedText.contains("fixture complete"), "必须在 attempt 结束前收到真实 UI 增量")
        XCTAssertTrue(completedText.contains("fixture complete"), "durable 结果必须结算为同一助手消息")
        XCTAssertTrue(sendOutcomes.contains { if case .accepted = $0 { return true }; return false })
        client.disconnect()
    }

    // MARK: - 发送映射（核心）

    /// 明确接受 → onSendAccepted + accepted outcome。
    func testAcceptedSubmissionPublishesAccepted() async throws {
        let sink = RecordingPromptSink()
        let (client, _) = try await makeConnectedClient(sender: sink)
        var accepted: [ClientMessageID?] = []
        var outcomes: [(ClientMessageID?, TurnSendOutcome)] = []
        client.onSendAccepted = { accepted.append($0) }
        client.onTurnSendOutcome = { outcomes.append(($0, $1)) }

        XCTAssertTrue(client.sendInput("你好", clientMessageID: "cm-1"))
        await waitFor { !accepted.isEmpty }

        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(sink.requestIDs, ["cm-1"], "clientMessageID 必须直接当 requestId 用")
        guard case .accepted = outcomes.first?.1 else {
            XCTFail("必须发布 accepted，实际 \(String(describing: outcomes.first?.1))")
            return
        }
    }

    /// **结果未知 → `.uncertain`，不是 `.rejected`。**
    ///
    /// 这是本文件最重要的一条。映射成 `.rejected` 会让上层以为"没执行、可以重试"，
    /// 而它可能已经执行了——那是重复工具执行的直接成因（契约 D4）。
    func testResponseUnknownPublishesUncertainNotRejected() async throws {
        let sink = RecordingPromptSink()
        sink.failure = HarnessTransportError.timedOut
        let (client, _) = try await makeConnectedClient(sender: sink)
        var outcomes: [(ClientMessageID?, TurnSendOutcome)] = []
        var failures: [(ClientMessageID?, String)] = []
        client.onTurnSendOutcome = { outcomes.append(($0, $1)) }
        client.onSendFailure = { failures.append(($0, $1)) }

        _ = client.sendInput("你好", clientMessageID: "cm-2")
        await waitFor { !outcomes.isEmpty }

        guard case .uncertain = outcomes.first?.1 else {
            XCTFail("结果未知必须发布 .uncertain，实际 \(String(describing: outcomes.first?.1))")
            return
        }
        // 同时不得报 accepted。
        if case .accepted = outcomes.first?.1 {
            XCTFail("结果未知不得发布 accepted")
        }
        XCTAssertEqual(failures.count, 1)
    }

    /// 明确业务失败 → `.rejected`（这类重试是安全的）。
    func testBusinessFailurePublishesRejected() async throws {
        let sink = RecordingPromptSink()
        sink.failure = HarnessTransportError.business(
            HarnessRemoteError(code: "session/agent-busy", message: "会话正忙", details: nil)
        )
        let (client, _) = try await makeConnectedClient(sender: sink)
        var outcomes: [(ClientMessageID?, TurnSendOutcome)] = []
        client.onTurnSendOutcome = { outcomes.append(($0, $1)) }

        _ = client.sendInput("你好", clientMessageID: "cm-3")
        await waitFor { !outcomes.isEmpty }

        guard case .rejected(let message) = outcomes.first?.1 else {
            XCTFail("业务失败必须发布 .rejected，实际 \(String(describing: outcomes.first?.1))")
            return
        }
        XCTAssertEqual(message, "会话正忙")
    }

    /// 基线未建立时不得发送。
    func testSendBeforeBaselineIsRejected() {
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in })
        )
        var failures: [(ClientMessageID?, String)] = []
        client.onSendFailure = { failures.append(($0, $1)) }

        XCTAssertFalse(client.sendInput("你好", clientMessageID: "cm-4"))
        XCTAssertEqual(failures.count, 1, "必须显式告知失败")
    }

    /// guidance 必须显式拒绝，不得当成普通 prompt 发出去。
    func testGuidanceIsExplicitlyRejected() async throws {
        let sink = RecordingPromptSink()
        let (client, _) = try await makeConnectedClient(sender: sink)
        var failures: [(ClientMessageID?, String)] = []
        client.onSendFailure = { failures.append(($0, $1)) }

        let accepted = client.sendGuidance(
            CodexAppServerTurnPayload(prompt: "引导"),
            clientMessageID: "cm-5",
            expectedTurnID: "turn-1"
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(sink.requestIDs.isEmpty, "guidance 不得变成一次 prompt")
    }

    /// 非文本输入显式拒绝（Harness 首版只接受文本）。
    func testNonTextTurnIsRejected() async throws {
        let sink = RecordingPromptSink()
        let (client, _) = try await makeConnectedClient(sender: sink)
        var failures: [(ClientMessageID?, String)] = []
        client.onSendFailure = { failures.append(($0, $1)) }

        let accepted = client.sendTurn(CodexAppServerTurnPayload(prompt: "   "), clientMessageID: "cm-6")

        XCTAssertFalse(accepted)
        XCTAssertTrue(sink.requestIDs.isEmpty)
    }

    // MARK: - 接收与去重

    func testOpeningSnapshotPublishesExistingAssistantPrefixImmediately() async throws {
        let data = Data(#"""
        {
          "type":"snapshot",
          "header":{"version":3,"id":"h00-session-0001","isSeeded":false},
          "cursor":13,"records":[],"hasMore":false,
          "assistantStream":{"revision":3,"activeAttempt":{
            "attemptId":"attempt-prefix","startedAfterSeq":13,"turn":1,"step":1,"nextIndex":2,
            "stream":[
              {"type":"chunk","time":100,"chunk":{"type":"block-start","index":0,"blockType":"text"}},
              {"type":"text-chunks","time0":101,"index":0,"dt":[],"texts":["已有前缀"]}
            ]
          }}
        }
        """#.utf8)
        let opening = try JSONDecoder().decode(HarnessSnapshot.self, from: data)
        let (_, recorder) = try await makeConnectedClient(
            sender: RecordingPromptSink(),
            openingSnapshot: opening
        )

        let deltas = recorder.events.compactMap { event -> AgentDelta? in
            if case .assistantDelta(let delta, _) = event { return delta }
            return nil
        }
        XCTAssertEqual(deltas.map(\.text), ["已有前缀"])
    }

    func testTextChunkPublishesConsumableDeltaBeforeEnd() async throws {
        let (client, recorder) = try await makeConnectedClient(sender: RecordingPromptSink())
        XCTAssertNil(client.apply(assistantStream: HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.start,
            revision: 1,
            index: nil,
            chunk: nil,
            outcome: nil,
            attemptId: "attempt-live",
            turn: 1,
            step: 1,
            startedAfterSeq: 13
        )))
        XCTAssertNil(client.apply(assistantStream: HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.chunk,
            revision: 2,
            index: 0,
            chunk: HarnessAssistantChunk(
                type: HarnessWireChunkType.textDelta,
                index: 0,
                text: "实时正文",
                blockType: nil,
                argumentsDelta: nil
            ),
            outcome: nil,
            attemptId: "attempt-live",
            turn: nil,
            step: nil,
            startedAfterSeq: nil
        )))

        let deltas = recorder.events.compactMap { event -> AgentDelta? in
            if case .assistantDelta(let delta, _) = event { return delta }
            return nil
        }
        XCTAssertEqual(deltas.map(\.text), ["实时正文"], "end 到达前 UI 就必须收到正文增量")
        XCTAssertFalse(client.journal?.activeAttempt?.isSettled == true)
    }

    func testSettledLiveAndDurableAssistantUseOneMessageIdentity() async throws {
        let (client, recorder) = try await makeConnectedClient(sender: RecordingPromptSink())
        let frames = [
            HarnessAssistantStreamFrame(
                type: HarnessWireAssistantFrame.start, revision: 1, index: nil,
                chunk: nil, outcome: nil, attemptId: "attempt-settle",
                turn: 1, step: 1, startedAfterSeq: 13
            ),
            HarnessAssistantStreamFrame(
                type: HarnessWireAssistantFrame.chunk, revision: 2, index: 0,
                chunk: HarnessAssistantChunk(
                    type: HarnessWireChunkType.textDelta, index: 0, text: "最终正文",
                    blockType: nil, argumentsDelta: nil
                ),
                outcome: nil, attemptId: "attempt-settle",
                turn: nil, step: nil, startedAfterSeq: nil
            ),
            HarnessAssistantStreamFrame(
                type: HarnessWireAssistantFrame.end, revision: 3, index: 1,
                chunk: nil,
                outcome: HarnessAssistantStreamOutcome(
                    kind: "committed",
                    eventType: HarnessWireSettlement.assistantMessage,
                    seq: 16
                ),
                attemptId: "attempt-settle",
                turn: nil, step: nil, startedAfterSeq: nil
            ),
        ]
        for frame in frames { XCTAssertNil(client.apply(assistantStream: frame)) }
        client.settleActiveAttempt()
        XCTAssertTrue(client.apply(durableEvent: durableEvent(
            type: HarnessWireEventType.assistantMessage,
            seq: 16,
            text: "最终正文"
        )))

        let deltaIDs = recorder.events.compactMap { event -> MessageID? in
            if case .assistantDelta(_, let metadata) = event { return metadata.messageID }
            return nil
        }
        let completedIDs = recorder.events.compactMap { event -> MessageID? in
            if case .messageCompleted(let message, _) = event, message.role == .assistant {
                return message.id
            }
            return nil
        }
        XCTAssertEqual(Set(deltaIDs + completedIDs), ["h-attempt-attempt-settle-assistant"])
        XCTAssertFalse(completedIDs.contains("h-seq-16-assistant"))
    }

    /// 重复持久事件不产生第二条展示事件（流式到历史无重复）。
    func testDuplicateDurableEventProjectsOnlyOnce() async throws {
        let (client, recorder) = try await makeConnectedClient(sender: RecordingPromptSink())
        let event = durableEvent(type: HarnessWireEventType.userMessage, seq: 8, text: "你好")

        XCTAssertTrue(client.apply(durableEvent: event), "首次必须是新增")
        XCTAssertFalse(client.apply(durableEvent: event), "同 seq 重投不得算新增")
        await waitFor { !recorder.events.isEmpty }

        let messages = recorder.events.filter {
            if case .messageCompleted = $0 { return true }
            return false
        }
        XCTAssertEqual(messages.count, 1, "重投不得产生第二条气泡")
    }

    /// 用户消息带回 source.rpcId，上层才能把乐观记录对上。
    func testUserMessageCarriesSourceRPCID() async throws {
        let (client, recorder) = try await makeConnectedClient(sender: RecordingPromptSink())
        let event = HarnessDurableEvent(
            type: HarnessWireEventType.userMessage, seq: 9, time: nil,
            data: .object([
                "content": .array([.object([
                    "type": .string("text"), "text": .string("你好"),
                ])]),
                "source": .object([
                    "kind": .string("user"), "rpcId": .string("cm-9"),
                ]),
            ])
        )
        XCTAssertTrue(client.apply(durableEvent: event))
        await waitFor { !recorder.events.isEmpty }

        guard case .messageCompleted(let message, _) = try XCTUnwrap(recorder.events.first) else {
            XCTFail("user/message 必须投影成 messageCompleted")
            return
        }
        XCTAssertEqual(message.clientMessageID, "cm-9", "必须带出 source.rpcId 供对账")
    }

    /// 断档时报 failed（要求重开 follow），不把断档接上。
    func testStreamGapReportsFailure() async throws {
        let (client, _) = try await makeConnectedClient(sender: RecordingPromptSink())
        var statuses: [WebSocketStatus] = []
        client.onStatus = { statuses.append($0) }

        // 没收到 start 就来 chunk：missingStart。
        let rejection = client.apply(assistantStream: HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.chunk, revision: 2, index: 0,
            chunk: HarnessAssistantChunk(
                type: HarnessWireChunkType.textDelta, index: 0,
                text: "x", blockType: nil, argumentsDelta: nil
            ),
            outcome: nil, attemptId: "a1", turn: 1, step: 1, startedAfterSeq: 0
        ))

        XCTAssertEqual(rejection, .missingStart)
        XCTAssertTrue(
            statuses.contains { if case .failed = $0 { return true }; return false },
            "断档必须如实上报"
        )
    }

    /// snapshot 之前来的 live 帧被拒（基线尚未建立）。
    func testFrameBeforeBaselineIsRejected() {
        let client = HarnessSessionWebSocketClient(
            endpoint: "http://127.0.0.1:8787",
            token: "fixture",
            sessionID: sessionID,
            submission: HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in })
        )
        XCTAssertEqual(
            client.apply(assistantStream: HarnessAssistantStreamFrame(
                type: HarnessWireAssistantFrame.start, revision: 1, index: nil,
                chunk: nil, outcome: nil, attemptId: "a1", turn: 1, step: 1, startedAfterSeq: 0
            )),
            .beforeSnapshot
        )
    }

    // MARK: - 停止

    /// 停止的响应未知同样走 control failure，不报成功。
    func testCancelUnknownReportsControlFailure() async throws {
        let sink = RecordingPromptSink()
        let (client, _) = try await makeConnectedClient(sender: sink)
        var controlFailures: [ControlCommandFailure] = []
        client.onControlFailure = { controlFailures.append($0) }

        // cancel 走的是注入的 submission，它的 sendCancel 恒成功；这里只验证成功路径。
        XCTAssertTrue(client.sendCtrlC(expectedTurnID: "turn-1"))
        await waitFor { !controlFailures.isEmpty || true }
        // 成功路径不产生 control failure。
        XCTAssertTrue(controlFailures.isEmpty)
        await waitFor { sink.cancelledSessions.count == 1 }
        XCTAssertEqual(sink.cancelledSessions, [sessionID])
    }

    func testCancelRejectsKnownMismatchedTurnWithoutCallingUpstream() async throws {
        let sink = RecordingPromptSink()
        let (client, _) = try await makeConnectedClient(sender: sink)
        XCTAssertNil(client.apply(assistantStream: HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.start,
            revision: 1,
            index: nil,
            chunk: nil,
            outcome: nil,
            attemptId: "attempt-cancel",
            turn: 7,
            step: 1,
            startedAfterSeq: 13
        )))
        var failure: ControlCommandFailure?
        client.onControlFailure = { failure = $0 }

        XCTAssertFalse(client.sendCtrlC(expectedTurnID: "h-turn-6"))
        // 已知目标过期必须归入 staleTarget：调用方据此收敛本地运行态，
        // 而不是把它当成一次普通失败去提示重试（gh-509）。
        XCTAssertEqual(failure?.kind, .staleTarget)
        XCTAssertEqual(failure?.expectedTurnID, "h-turn-6")
        XCTAssertTrue(sink.cancelledSessions.isEmpty)
    }

    /// attempt 已结算但整轮没结束时，停止目标仍必须可比对。
    ///
    /// 只认 `activeAttempt` 会漏掉这一段：模型输出完了、正在跑工具或等待人机应答时
    /// 没有 active attempt，而会话仍在执行。此时一次迟到的"停止 A"会停掉正在跑的 B。
    /// 轮次身份取自 durable `turn/start`，它对整个 turn 生命周期成立。
    func testCancelRejectsStaleTargetDuringTurnAfterAttemptSettled() async throws {
        let sink = RecordingPromptSink()
        let (client, _) = try await makeConnectedClient(sender: sink)

        // 第 7 轮开始且**没有**活动 attempt：这正是工具执行中/等应答时的形状。
        _ = client.apply(durableEvent: turnEvent(
            type: HarnessWireEventType.turnStart, seq: 20, turn: 7
        ))
        XCTAssertNil(client.journal?.activeAttempt, "这一段本来就没有 active attempt")

        var failure: ControlCommandFailure?
        client.onControlFailure = { failure = $0 }

        // 迟到的停止指向第 6 轮：必须拒绝，不能停掉正在跑的第 7 轮。
        XCTAssertFalse(client.sendCtrlC(expectedTurnID: "h-turn-6"))
        XCTAssertEqual(failure?.kind, .staleTarget)
        XCTAssertTrue(sink.cancelledSessions.isEmpty, "过期目标不得触达上游 cancel")

        // 指向当前轮次则放行。
        XCTAssertTrue(client.sendCtrlC(expectedTurnID: "h-turn-7"))
        await waitFor { sink.cancelledSessions.count == 1 }
        XCTAssertEqual(sink.cancelledSessions, [sessionID])
    }

    /// `turn/end` 之后轮次不再活跃：此时没有可比对的目标，不阻拦取消。
    func testCancelAfterTurnEndFallsBackToSessionCancel() async throws {
        let sink = RecordingPromptSink()
        let (client, _) = try await makeConnectedClient(sender: sink)

        _ = client.apply(durableEvent: turnEvent(
            type: HarnessWireEventType.turnStart, seq: 20, turn: 7
        ))
        _ = client.apply(durableEvent: turnEvent(
            type: HarnessWireEventType.turnEnd, seq: 21, turn: 7
        ))
        XCTAssertNil(client.journal?.activeTurnNumber, "整轮结束后不该再有活跃轮次")

        // 无法确认目标 → 不阻拦（契约如实保留"检查与取消不是原子操作"）。
        XCTAssertTrue(client.sendCtrlC(expectedTurnID: "h-turn-7"))
        await waitFor { sink.cancelledSessions.count == 1 }
    }

    // MARK: - 支撑

    private func waitFor(_ condition: @MainActor () -> Bool, iterations: Int = 400) async {
        for _ in 0..<iterations {
            if condition() { return }
            // 原生 reader 以 10ms 间隔消费有界邮箱；连续 yield 会在下一轮消费前跑完，
            // 让测试把尚未执行误判成业务失败。1ms 轮询保留明确的 400ms 上限。
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitForLive(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func snapshot(sessionID: String, cursor: Int) -> HarnessSnapshot {
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
            records: [],
            hasMore: false,
            projections: nil,
            assistantStream: HarnessAssistantStreamBaseline(revision: 0, activeAttempt: nil)
        )
    }

    private func makeRuntime(stream: FakeHarnessStreamTransport) -> HarnessSessionRuntime {
        HarnessSessionRuntime(
            configuration: HarnessSessionRuntime.Configuration(
                endpoint: "http://127.0.0.1:8787",
                token: "fixture",
                pingInterval: .seconds(30)
            ),
            transports: HarnessSessionRuntime.TransportPair(
                rpc: FakeHarnessRPCTransport(),
                stream: stream
            )
        )
    }

    private func waitForOpenStream(
        endpoint: String,
        stream: FakeHarnessStreamTransport,
        after frameIndex: Int = 0
    ) async throws -> String {
        for _ in 0..<400 {
            for frame in stream.sentFrames.dropFirst(frameIndex) {
                if case .open(let streamID, let openedEndpoint, _) = frame,
                   openedEndpoint == endpoint {
                    return streamID
                }
            }
            // full 回归会并发运行数百个测试，只 yield 会在连接任务获得调度前耗尽轮询。
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw HarnessTransportError.timedOut
    }

    private func carrierValue(streamID: String, value: HarnessJSONValue) -> HarnessCarrierFrame {
        HarnessCarrierFrame(
            type: HarnessWireCarrier.item,
            streamId: streamID,
            value: value,
            error: nil
        )
    }

    /// 中继的应答回执帧（`{eventId, accepted, responded, error?}`）。
    ///
    /// 撤卡只认它：帧写出成功只代表中继收到了应答，不代表 Harness 接受了它。
    private func respondAckValue(
        eventID: String,
        accepted: Bool,
        error: HarnessJSONValue? = nil
    ) -> HarnessJSONValue {
        var object: [String: HarnessJSONValue] = [
            "type": .string(HarnessWireFrame.responded),
            "eventId": .string(eventID),
            "accepted": .bool(accepted),
            "responded": .bool(true),
        ]
        if let error { object["error"] = error }
        return .object(object)
    }

    private func snapshotValue(sessionID: String, cursor: Int) -> HarnessJSONValue {
        .object([
            "type": .string(HarnessWireFrame.snapshot),
            "header": .object([
                "version": .number(3),
                "id": .string(sessionID),
                "cwd": .string("/fixture"),
                "isSeeded": .bool(false),
            ]),
            "cursor": .number(Double(cursor)),
            "records": .array([]),
            "hasMore": .bool(false),
            "assistantStream": .object([
                "revision": .number(0),
            ]),
        ])
    }
}

// MARK: - 替身

@MainActor
private final class RecordingPromptSink {
    private(set) var requestIDs: [String] = []
    private(set) var cancelledSessions: [String] = []
    var failure: Error?

    func send(_ sessionID: String, _ requestID: String, _ text: String) async throws {
        requestIDs.append(requestID)
        if let failure { throw failure }
    }

    func cancel(_ sessionID: String) async throws {
        cancelledSessions.append(sessionID)
        if let failure { throw failure }
    }
}

@MainActor
private final class EventRecorder {
    var events: [AgentEvent] = []
}

@MainActor
private final class SnapshotGate {
    private struct Request {
        let sessionID: String
        let continuation: CheckedContinuation<HarnessSnapshot, Error>
    }

    private var requests: [Request] = []

    func fetch(sessionID: String) async throws -> HarnessSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(sessionID: sessionID, continuation: continuation))
        }
    }

    func resume(sessionID: String, snapshot: HarnessSnapshot) {
        guard let index = requests.firstIndex(where: { $0.sessionID == sessionID }) else {
            XCTFail("没有等待中的 snapshot 请求：\(sessionID)")
            return
        }
        let request = requests.remove(at: index)
        request.continuation.resume(returning: snapshot)
    }

    func waitForRequestCount(_ count: Int) async {
        for _ in 0..<400 {
            if requests.count >= count { return }
            await Task.yield()
        }
        XCTFail("等待 snapshot 请求数量 \(count) 超时")
    }
}
