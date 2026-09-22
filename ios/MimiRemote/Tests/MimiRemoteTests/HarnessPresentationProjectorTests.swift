import Foundation
import XCTest
@testable import MimiRemote

/// H08 投影测试。
///
/// 中心要求（卡片"必须验收"）：**流式到历史无重复**。因此比重最大的是
/// "同一份原生数据无论从哪条路径进来，投影出的展示身份都一样"。
///
/// 另外三条克制也各有断言：不伪装成 Codex 形状、注入内容不当用户输入、
/// 认不出的类型显式跳过。
final class HarnessPresentationProjectorTests: XCTestCase {

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

    /// 取 durable-events 夹具的事件（解成 HarnessDurableEvent）。
    private func durableEvents() throws -> [HarnessDurableEvent] {
        let fixture = try harnessFixtureJSON("stream/durable-events.json")
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        let events = try XCTUnwrap(
            observations.first { ($0["label"] as? String) == "events" }?["value"] as? [Any]
        )
        let data = try JSONSerialization.data(withJSONObject: events)
        return try JSONDecoder().decode([HarnessDurableEvent].self, from: data)
    }

    private func assistantStreamFrames(_ label: String) throws -> [HarnessAssistantStreamFrame] {
        let fixture = try harnessFixtureJSON("stream/assistant-stream.json")
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        let run = try XCTUnwrap(observations.first { ($0["label"] as? String) == label })
        let frames = try XCTUnwrap(run["frames"] as? [Any])
        let data = try JSONSerialization.data(withJSONObject: frames)
        return try JSONDecoder().decode([HarnessAssistantStreamFrame].self, from: data)
    }

    // MARK: - 持久事件投影

    /// 真实夹具里的 `user/message` 实际来自 skill-catalog，不能冒充用户输入。
    func testSkillCatalogUserMessageProjectsAsContextNotUser() throws {
        let events = try durableEvents()
        let userEvents = events.filter { $0.type == HarnessWireEventType.userMessage }
        XCTAssertFalse(userEvents.isEmpty, "前置条件：夹具里必须有 user/message")

        let projected = HarnessPresentationProjector.project(durableEvent: userEvents[0], sessionID: sessionID)
        XCTAssertEqual(projected.count, 1)
        guard case .messageCompleted(let message, _) = projected[0] else {
            XCTFail("注入的 user/message 必须保留为 context")
            return
        }
        XCTAssertEqual(message.role, .system)
        XCTAssertEqual(message.kind, .context)
        XCTAssertFalse(message.content.isEmpty, "正文不得为空")
        XCTAssertEqual(message.sessionID, sessionID)
    }

    func testHumanUserSourceProjectsAsUser() throws {
        let event = HarnessDurableEvent(
            type: HarnessWireEventType.userMessage,
            seq: 11,
            time: nil,
            data: .object([
                "content": .array([.object([
                    "type": .string("text"), "text": .string("真实用户输入"),
                ])]),
                "source": .object([
                    "kind": .string("user"), "rpcId": .string("cm-human"),
                ]),
            ])
        )

        guard case .messageCompleted(let message, _) = try XCTUnwrap(
            HarnessPresentationProjector.project(durableEvent: event, sessionID: sessionID).first
        ) else {
            XCTFail("human user/message 必须投影成用户消息")
            return
        }
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.clientMessageID, "cm-human")
    }

    func testPluginUserMessageProjectsAsContextNotUser() throws {
        let event = HarnessDurableEvent(
            type: HarnessWireEventType.userMessage,
            seq: 12,
            time: nil,
            data: .object([
                "content": .array([.object([
                    "type": .string("text"), "text": .string("插件注入"),
                ])]),
                "source": .object([
                    "kind": .string("plugin"), "plugin": .string("fixture-plugin"),
                ]),
            ])
        )

        guard case .messageCompleted(let message, _) = try XCTUnwrap(
            HarnessPresentationProjector.project(durableEvent: event, sessionID: sessionID).first
        ) else {
            XCTFail("plugin user/message 必须保留为 context")
            return
        }
        XCTAssertEqual(message.role, .system)
        XCTAssertEqual(message.kind, .context)
    }

    /// 正向对照：assistant/message 投影成助手消息。
    func testAssistantMessageProjectsAsAssistant() throws {
        let events = try durableEvents()
        let assistantEvents = events.filter { $0.type == HarnessWireEventType.assistantMessage }
        XCTAssertFalse(assistantEvents.isEmpty, "前置条件：夹具里必须有 assistant/message")

        let projected = HarnessPresentationProjector.project(
            durableEvent: assistantEvents[0], sessionID: sessionID
        )
        guard case .messageCompleted(let message, _) = try XCTUnwrap(projected.first) else {
            XCTFail("assistant/message 必须投影成 messageCompleted")
            return
        }
        XCTAssertEqual(message.role, .assistant)
    }

    /// **注入上下文不得长得像用户输入。**
    ///
    /// system/message 是 Harness 注入的（工作区指令、运行时快照等）。
    /// 把它按 .user 投影，用户会在时间线上看到"自己说过"的话。
    func testSystemMessageIsContextNotUser() throws {
        let event = HarnessDurableEvent(
            type: HarnessWireEventType.systemMessage,
            seq: 7,
            time: nil,
            data: .object(["content": .array([.object([
                "type": .string("text"), "text": .string("注入的工作区指令"),
            ])])])
        )
        let projected = HarnessPresentationProjector.project(durableEvent: event, sessionID: sessionID)

        guard case .messageCompleted(let message, _) = try XCTUnwrap(projected.first) else {
            XCTFail("system/message 必须投影成 messageCompleted（kind=context）")
            return
        }
        XCTAssertEqual(message.role, .system)
        XCTAssertEqual(message.kind, .context)
    }

    /// 轮次边界投影成 turnStarted / turnCompleted。
    func testTurnBoundariesProject() throws {
        let start = HarnessDurableEvent(type: HarnessWireEventType.turnStart, seq: 5, time: nil, data: nil)
        let end = HarnessDurableEvent(type: HarnessWireEventType.turnEnd, seq: 18, time: nil, data: nil)

        guard case .turnStarted = try XCTUnwrap(
            HarnessPresentationProjector.project(durableEvent: start, sessionID: sessionID).first
        ) else {
            XCTFail("turn/start 必须投影成 turnStarted")
            return
        }
        guard case .turnCompleted = try XCTUnwrap(
            HarnessPresentationProjector.project(durableEvent: end, sessionID: sessionID).first
        ) else {
            XCTFail("turn/end 必须投影成 turnCompleted")
            return
        }
    }

    /// **认不出的类型显式跳过**：不猜、不产出假事件、也不崩。
    ///
    /// 用夹具里真实存在但本层不投影的类型（session/title、request/context 等）。
    func testUnknownOrUnprojectedTypesYieldNoEvents() throws {
        for type in ["session/title", "request/context", "session/end-seed", "完全没听说过的类型"] {
            let event = HarnessDurableEvent(
                type: type, seq: 1, time: nil,
                data: .object(["content": .array([.object([
                    "type": .string("text"), "text": .string("x"),
                ])])])
            )
            let projected = HarnessPresentationProjector.project(durableEvent: event, sessionID: sessionID)
            XCTAssertTrue(projected.isEmpty, "\(type) 不该产出展示事件")
        }
    }

    /// 步骤边界不产出展示事件（避免时间线噪声）。
    func testStepBoundariesAreNotShown() {
        for type in [HarnessWireEventType.stepStart, HarnessWireEventType.stepEnd] {
            let event = HarnessDurableEvent(type: type, seq: 6, time: nil, data: nil)
            XCTAssertTrue(
                HarnessPresentationProjector.project(durableEvent: event, sessionID: sessionID).isEmpty,
                "\(type) 不该单独展示"
            )
        }
    }

    /// 空正文不产出消息（避免空白气泡）。
    func testEmptyTextYieldsNoMessage() {
        let event = HarnessDurableEvent(
            type: HarnessWireEventType.userMessage, seq: 1, time: nil,
            data: .object(["content": .array([])])
        )
        XCTAssertTrue(
            HarnessPresentationProjector.project(durableEvent: event, sessionID: sessionID).isEmpty
        )
    }

    // MARK: - 活动 attempt 投影

    /// 正向对照：正常文本回合结算后投影出助手正文。
    func testCompletedTextRunProjectsAssistantText() throws {
        let attempt = try makeSettledAttempt("run.text.completed")

        let projected = HarnessPresentationProjector.project(attempt: attempt, sessionID: sessionID)

        let messages = projected.compactMap { event -> AgentMessage? in
            if case .messageCompleted(let m, _) = event { return m }
            return nil
        }
        XCTAssertEqual(messages.count, 1, "正常结算必须恰好产生一条助手消息")
        XCTAssertFalse(messages[0].content.isEmpty)
        XCTAssertEqual(messages[0].role, .assistant)
    }

    /// **被取消的 attempt 不得投影成助手消息。**
    ///
    /// 它的 outcome 也是 `kind:committed`，但 eventType 是 assistant/attempt——
    /// 没有完整正文。投影成消息会让用户看到半截内容被标成"完成"。
    func testAbortedRunDoesNotProjectAsMessage() throws {
        let attempt = try makeSettledAttempt("run.aborted-by-user")

        let projected = HarnessPresentationProjector.project(attempt: attempt, sessionID: sessionID)

        let messages = projected.compactMap { event -> AgentMessage? in
            if case .messageCompleted(let m, _) = event { return m }
            return nil
        }
        XCTAssertTrue(messages.isEmpty, "被取消的输出不得投影成助手消息")
    }

    /// **被取消但有部分正文的 attempt：仍然不得投影成助手消息。**
    ///
    /// 这条是上一条的必要加强。`run.aborted-by-user` 夹具的 attempt **没有 chunk**，
    /// 所以"被取消不投影"目前同时被两层挡住：`producedAssistantMessage` 与"空正文不投影"。
    /// 只测那个夹具的话，去掉 `producedAssistantMessage` 检查仍然全绿——
    /// 变异验证正是这样暴露出原测试没有真正钉住这条规则。
    ///
    /// 现实场景确实会踩：用户流到一半取消，attempt 已经累积了部分正文。
    /// 那时若只靠"空正文"拦截，半截内容就会被当成一条完整助手消息展示出来。
    func testAbortedRunWithPartialTextStillDoesNotProject() throws {
        var attempt = HarnessJournalAttempt(
            attemptID: "h00-attempt-0001", turn: 1, step: 1, startedAfterSeq: 13,
            lastRevision: 3, nextChunkIndex: 1
        )
        // 累积了真实正文，但 outcome 是 assistant/attempt（被取消）。
        attempt.chunks = [
            HarnessAssistantStreamFrame(
                type: HarnessWireAssistantFrame.chunk, revision: 2, index: 0,
                chunk: HarnessAssistantChunk(
                    type: HarnessWireChunkType.textDelta, index: 0,
                    text: "半截正文", blockType: nil, argumentsDelta: nil
                ),
                outcome: nil, attemptId: "h00-attempt-0001", turn: 1, step: 1, startedAfterSeq: 13
            )
        ]
        attempt.outcome = HarnessAssistantStreamOutcome(
            kind: "committed", eventType: HarnessWireSettlement.assistantAttempt, seq: 16
        )
        attempt.settledSeq = 16
        attempt.isSettled = true

        // 前置条件：正文确实非空（否则这条测的又只是"空正文不投影"）。
        XCTAssertFalse(
            HarnessPresentationProjector.assistantText(from: attempt).isEmpty,
            "前置条件：被取消的 attempt 必须带部分正文"
        )

        let projected = HarnessPresentationProjector.project(attempt: attempt, sessionID: sessionID)
        let messages = projected.compactMap { event -> AgentMessage? in
            if case .messageCompleted(let m, _) = event { return m }
            return nil
        }
        XCTAssertTrue(
            messages.isEmpty,
            "被取消的输出即使有部分正文也不得投影成助手消息（会被当成已完成的半截内容）"
        )
    }

    /// **流式到历史无重复**：同一 attempt 只投影出同一个消息 id。
    ///
    /// 身份由原生 attemptId 派生，因此"直播时算出的 id"与"历史回读时算出的 id"
    /// 必须相同。不同就会产生第二条气泡——这正是卡片要求防住的。
    func testSameAttemptYieldsStableMessageIdentity() throws {
        let first = try makeSettledAttempt("run.text.completed")
        let second = try makeSettledAttempt("run.text.completed")

        let id1 = try XCTUnwrap(projectedMessageID(from: first))
        let id2 = try XCTUnwrap(projectedMessageID(from: second))

        XCTAssertEqual(id1, id2, "同一 attempt 的展示身份必须稳定")
        XCTAssertTrue(id1.contains("h00-attempt-0001"), "身份必须派生自原生 attemptId：\(id1)")
    }

    /// 未结算的 attempt 不投影（避免把进行中的内容当成已完成）。
    func testUnsettledAttemptProjectsNothing() throws {
        var attempt = HarnessJournalAttempt(
            frame: try XCTUnwrap(assistantStreamFrames("run.text.completed").first),
            lastRevision: 1, nextChunkIndex: 0
        )
        attempt.chunks = try assistantStreamFrames("run.text.completed")
        XCTAssertFalse(attempt.isSettled, "前置条件：尚未收到 end 帧")

        XCTAssertTrue(
            HarnessPresentationProjector.project(attempt: attempt, sessionID: sessionID).isEmpty
        )
    }

    /// 被取代的 attempt 投影出一条 warning（如实告知输出可能不完整）。
    func testSupersededAttemptProjectsWarning() throws {
        var attempt = try makeSettledAttempt("run.text.completed")
        attempt.wasSuperseded = true

        let projected = HarnessPresentationProjector.project(attempt: attempt, sessionID: sessionID)
        let warnings = projected.filter {
            if case .warning = $0 { return true }
            return false
        }
        XCTAssertEqual(warnings.count, 1, "被取代必须如实告知")
    }

    // MARK: - 支撑

    private func makeSettledAttempt(_ label: String) throws -> HarnessJournalAttempt {
        var attempt = HarnessJournalAttempt(
            attemptID: nil, turn: nil, step: nil, startedAfterSeq: nil,
            lastRevision: 0, nextChunkIndex: 0
        )
        let frames = try assistantStreamFrames(label)
        // 用 journal 走一遍真实路径，保证 attempt 的构造与生产一致。
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(
            snapshot: HarnessSnapshot(
                type: "snapshot",
                header: HarnessSnapshotHeader(
                    version: 3, id: "h00-id-0001", createdAt: nil,
                    cwd: "/h00/workspace", isSeeded: false, agentPreset: nil
                ),
                cursor: 2, records: [], hasMore: false, projections: nil,
                assistantStream: nil
            ),
            acceptingGeneration: 1
        )
        for frame in frames {
            _ = journal.apply(assistantStream: frame)
        }
        attempt = try XCTUnwrap(journal.activeAttempt)
        return attempt
    }

    private func projectedMessageID(from attempt: HarnessJournalAttempt) -> String? {
        let projected = HarnessPresentationProjector.project(attempt: attempt, sessionID: sessionID)
        for event in projected {
            if case .messageCompleted(let m, _) = event { return m.id }
        }
        return nil
    }
}
