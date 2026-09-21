import Foundation
import XCTest
@testable import MimiRemote

/// H06 原生历史 journal 与活动基线恢复。
///
/// 三条纪律：
/// 1. **夹具共用**：形状断言读 `contracts/harness-native/fixtures/*`，与 Go 侧同一份字节。
/// 2. **顺序无关性是核心断言**：卡片的"必须验收"要求同一 fixture 在「从头直播」「中途打开」
///    「离线后恢复」「先分页再收增量」四种顺序下得到**一致 durable 结果**。这里逐条对照，
///    而不是只验一种顺序能跑通。
/// 3. **每条拒绝配正向对照**：只有负向用例的套件可能整体是空断言。
@MainActor
final class HarnessSessionJournalTests: XCTestCase {

    // MARK: - 夹具

    func harnessFixtureJSON(_ name: String) throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root
            .appendingPathComponent("contracts/harness-native/fixtures")
            .appendingPathComponent(name)
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "夹具 \(name) 顶层不是对象")
    }

    /// 取 follow 夹具的 snapshot 观测，解成 `HarnessSnapshot`。
    func snapshotFixture() throws -> HarnessSnapshot {
        let fixture = try harnessFixtureJSON("stream/follow-frames.json")
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        let snapshot = try XCTUnwrap(
            observations.first { ($0["label"] as? String) == "snapshot" }?["value"]
        )
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        return try JSONDecoder().decode(HarnessSnapshot.self, from: data)
    }

    /// 取 durable-events 夹具里的全部事件，解成 durable event 列表。
    func durableEventsFixture() throws -> [HarnessDurableEvent] {
        let fixture = try harnessFixtureJSON("stream/durable-events.json")
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        let events = try XCTUnwrap(
            observations.first { ($0["label"] as? String) == "events" }?["value"] as? [Any]
        )
        let data = try JSONSerialization.data(withJSONObject: events)
        return try JSONDecoder().decode([HarnessDurableEvent].self, from: data)
    }

    /// 取 assistant-stream 夹具里某个 run 的帧序列。
    func assistantStreamFrames(_ label: String) throws -> [HarnessAssistantStreamFrame] {
        let fixture = try harnessFixtureJSON("stream/assistant-stream.json")
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        let run = try XCTUnwrap(observations.first { ($0["label"] as? String) == label })
        let frames = try XCTUnwrap(run["frames"] as? [Any])
        let data = try JSONSerialization.data(withJSONObject: frames)
        return try JSONDecoder().decode([HarnessAssistantStreamFrame].self, from: data)
    }

    // MARK: - 1. 夹具形状

    /// 正向对照：真实 snapshot 必须解出会话身份与切点。
    func testSnapshotFixtureDecodesIdentityAndCursor() throws {
        let snapshot = try snapshotFixture()
        XCTAssertEqual(snapshot.type, "snapshot")
        XCTAssertEqual(snapshot.header?.id, "h00-id-0001")
        XCTAssertEqual(snapshot.header?.cwd, "/h00/workspace")
        // cursor 是本次订阅的闭区间切点，也是 session/page 唯一合法的 throughSeq。
        XCTAssertEqual(snapshot.cursor, 2)
        XCTAssertEqual(snapshot.records?.count, 3)
    }

    func testActiveAttemptDecodesNonemptyCompactStreamAndContinuesAtNextIndex() throws {
        let data = Data(#"""
        {
          "type":"snapshot",
          "header":{"version":3,"id":"h00-session-0001","isSeeded":false},
          "cursor":13,"records":[],"hasMore":false,
          "assistantStream":{"revision":4,"activeAttempt":{
            "attemptId":"attempt-live","startedAfterSeq":13,"turn":1,"step":1,"nextIndex":3,
            "stream":[
              {"type":"chunk","time":100,"chunk":{"type":"block-start","index":0,"blockType":"text"}},
              {"type":"text-chunks","time0":101,"index":0,"dt":[1],"texts":["已有","前缀"]}
            ]
          }}
        }
        """#.utf8)
        let snapshot = try JSONDecoder().decode(HarnessSnapshot.self, from: data)
        var journal = HarnessSessionJournal(generation: 7)

        XCTAssertTrue(journal.apply(snapshot: snapshot, acceptingGeneration: 7))
        let attempt = try XCTUnwrap(journal.activeAttempt)
        XCTAssertEqual(HarnessPresentationProjector.assistantText(from: attempt), "已有前缀")
        XCTAssertEqual(attempt.nextChunkIndex, 3)

        let continuation = HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.chunk,
            revision: 5,
            index: 3,
            chunk: HarnessAssistantChunk(
                type: HarnessWireChunkType.textDelta,
                index: 0,
                text: "续接",
                blockType: nil,
                argumentsDelta: nil
            ),
            outcome: nil,
            attemptId: "attempt-live",
            turn: nil,
            step: nil,
            startedAfterSeq: nil
        )
        XCTAssertNil(journal.apply(assistantStream: continuation))
        XCTAssertEqual(
            HarnessPresentationProjector.assistantText(from: try XCTUnwrap(journal.activeAttempt)),
            "已有前缀续接"
        )
    }

    func testActiveAttemptRejectsStringStreamInsteadOfTreatingItAsEmpty() {
        let data = Data(#"""
        {
          "type":"snapshot",
          "header":{"version":3,"id":"h00-session-0001","isSeeded":false},
          "cursor":13,"records":[],"hasMore":false,
          "assistantStream":{"revision":1,"activeAttempt":{
            "attemptId":"attempt-live","startedAfterSeq":13,"turn":1,"step":1,"nextIndex":0,
            "stream":"not-an-array"
          }}
        }
        """#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(HarnessSnapshot.self, from: data))
    }

    func testLiveChunkIndexGapIsRejectedInsteadOfDroppingPrefix() throws {
        var journal = HarnessSessionJournal(generation: 1)
        XCTAssertTrue(journal.apply(snapshot: try snapshotFixture(), acceptingGeneration: 1))
        let start = HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.start,
            revision: 1,
            index: nil,
            chunk: nil,
            outcome: nil,
            attemptId: "attempt-gap",
            turn: 1,
            step: 1,
            startedAfterSeq: 2
        )
        XCTAssertNil(journal.apply(assistantStream: start))
        let skippedPrefix = HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.chunk,
            revision: 2,
            index: 1,
            chunk: HarnessAssistantChunk(
                type: HarnessWireChunkType.textDelta,
                index: 0,
                text: "缺了 index 0",
                blockType: nil,
                argumentsDelta: nil
            ),
            outcome: nil,
            attemptId: "attempt-gap",
            turn: nil,
            step: nil,
            startedAfterSeq: nil
        )

        XCTAssertEqual(
            journal.apply(assistantStream: skippedPrefix),
            .chunkIndexGap(expected: 0, actual: 1)
        )
        XCTAssertTrue(journal.activeAttempt?.chunks.isEmpty == true)
    }

    /// 正向对照：snapshot 里的 records 按 seq 进入 journal。
    func testSnapshotRecordsLandInJournalBySeq() throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        XCTAssertTrue(journal.apply(snapshot: snapshot, acceptingGeneration: 1))

        XCTAssertEqual(journal.snapshotCursor, 2, "throughSeq 必须取自本次 snapshot")
        XCTAssertEqual(journal.orderedRecords.map(\.seq), [0, 1, 2])
        XCTAssertEqual(journal.latestSeq, 2)
        XCTAssertTrue(journal.hasOpenedSnapshot)
    }

    // MARK: - 2. 四种顺序 → 一致 durable 结果（卡片核心验收）

    /// 同一份 fixture，四种到达顺序必须得到**一致的 durable 结果**。
    ///
    /// 这是 H06 卡片的中心要求。做成一个测试内的四路对照而不是四个独立测试：
    /// 只有放在一起比较，才能证明"顺序无关"而不是"每种顺序各自能跑"。
    ///
    /// **比较口径说明**：断言落在"seq → (type, data)"上，而不是整个 struct。
    /// 原因是两份夹具对同一 seq 给了不同的 `time`（snapshot 是采集真值
    /// 1789755457906，durable-events 里是占位 0），而 seq 是主键、后到者覆盖——
    /// 因此"同一 seq 的 time 取决于谁后到"是**正确行为**，拿它做顺序无关性断言
    /// 会把正确实现判成错的。真正必须顺序无关的是：有哪些 seq、每个 seq 是什么事件。
    func testDurableResultIsIdenticalAcrossFourArrivalOrders() throws {
        let snapshot = try snapshotFixture()
        let live = try durableEventsFixture()
        // 分页带来的"更早历史"：用 snapshot 自己的 records 当一页更早历史。
        let earlierPage = snapshot.records ?? []

        // 顺序 A：从头直播 —— snapshot 之后按序收 live。
        var a = HarnessSessionJournal(generation: 1)
        a.apply(snapshot: snapshot, acceptingGeneration: 1)
        for event in live { a.apply(durableEvent: event) }

        // 顺序 B：中途打开 —— 先收到一部分 live，再收到 snapshot，再收剩余。
        var b = HarnessSessionJournal(generation: 1)
        let split = live.count / 2
        for event in live[..<split] { b.apply(durableEvent: event) }
        b.apply(snapshot: snapshot, acceptingGeneration: 1)
        for event in live[split...] { b.apply(durableEvent: event) }

        // 顺序 C：离线后恢复 —— 只有 snapshot（无 live），历史由分页补齐。
        var c = HarnessSessionJournal(generation: 1)
        c.apply(snapshot: snapshot, acceptingGeneration: 1)
        c.prependHistoryPage(records: earlierPage)

        // 顺序 D：先分页再收增量 —— snapshot → 分页 → live。
        var d = HarnessSessionJournal(generation: 1)
        d.apply(snapshot: snapshot, acceptingGeneration: 1)
        d.prependHistoryPage(records: earlierPage)
        for event in live { d.apply(durableEvent: event) }

        // A、B、D 三条路径含完整 live，必须完全一致。
        XCTAssertEqual(seqAndType(a), seqAndType(b), "中途打开与从头直播必须一致")
        XCTAssertEqual(seqAndType(a), seqAndType(d), "先分页再收增量与从头直播必须一致")

        // 四条路径的 seq 都必须升序且无重复——这是"无重复/缺失"的可观测形式。
        for (name, journal) in [("A", a), ("B", b), ("C", c), ("D", d)] {
            let seqs = journal.orderedRecords.compactMap(\.seq)
            XCTAssertEqual(seqs, seqs.sorted(), "顺序 \(name) 的记录必须按 seq 升序")
            XCTAssertEqual(Set(seqs).count, seqs.count, "顺序 \(name) 不得有重复 seq")
        }

        // 每条路径都不得缺失 live 覆盖的 seq（A/B/D 尤其）。
        let liveSeqs = Set(live.compactMap(\.seq))
        for (name, journal) in [("A", a), ("B", b), ("D", d)] {
            let got = Set(journal.orderedRecords.compactMap(\.seq))
            XCTAssertTrue(liveSeqs.isSubset(of: got), "顺序 \(name) 缺失 live seq：\(liveSeqs.subtracting(got))")
        }
    }

    /// 顺序无关性比较口径：seq → 事件类型。
    ///
    /// 用命名结构而不是元组：`XCTAssertEqual` 要求 `Equatable`，元组不满足。
    private struct SeqIdentity: Equatable {
        let seq: Int
        let type: String?
    }

    private func seqAndType(_ journal: HarnessSessionJournal) -> [SeqIdentity] {
        journal.orderedRecords.compactMap { event in
            event.seq.map { SeqIdentity(seq: $0, type: event.type) }
        }
    }

    /// 重复投递同 seq 不新增记录（重连重投是正常现象）。
    func testRedeliveredEventDoesNotDuplicate() throws {
        let snapshot = try snapshotFixture()
        let live = try durableEventsFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)
        for event in live { journal.apply(durableEvent: event) }

        let before = journal.recordCount
        for event in live { journal.apply(durableEvent: event) }

        XCTAssertEqual(journal.recordCount, before, "重投不得新增记录")
    }

    // MARK: - 3. 代次

    /// 旧 snapshot 不得回滚新代次。
    func testStaleSnapshotCannotRollBackNewGeneration() throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 5)
        let afterNew = journal.recordCount

        // 旧代次的 snapshot 迟到。
        let accepted = journal.apply(snapshot: snapshot, acceptingGeneration: 2)

        XCTAssertFalse(accepted, "比当前代次旧的 snapshot 必须被拒绝")
        XCTAssertEqual(journal.generation, 5, "代次不得被倒退")
        XCTAssertEqual(journal.recordCount, afterNew)
    }

    /// 进入新代次清掉活动 attempt，但保留 durable 历史。
    func testNewGenerationClearsActiveAttemptButKeepsHistory() throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)
        let frames = try assistantStreamFrames("run.text.completed")
        for frame in frames { journal.apply(assistantStream: frame) }
        XCTAssertNotNil(journal.activeAttempt)
        let historyCount = journal.recordCount

        journal.beginGeneration(2)

        XCTAssertNil(journal.activeAttempt, "新代次不得沿用旧 attempt")
        XCTAssertEqual(journal.recordCount, historyCount, "durable 历史不该因重连消失")
        XCTAssertFalse(journal.hasOpenedSnapshot, "新代次必须重新等 snapshot")
    }

    // MARK: - 4. 活动 attempt 与结算

    /// 正向对照：真实文本回合的完整帧序列必须被接受，并结算到正确 seq。
    func testTextRunSettlesToAssistantMessage() throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)

        let frames = try assistantStreamFrames("run.text.completed")
        for frame in frames {
            XCTAssertNil(journal.apply(assistantStream: frame), "真实帧序列不得被拒绝")
        }

        let attempt = try XCTUnwrap(journal.activeAttempt)
        XCTAssertEqual(attempt.attemptID, "h00-attempt-0001")
        XCTAssertTrue(attempt.isSettled)
        XCTAssertEqual(attempt.settledSeq, 16, "结算必须绑定 outcome.seq")
        // revision 从 1 连续到 9（实测）。
        XCTAssertEqual(attempt.lastRevision, 9)
        XCTAssertTrue(attempt.producedAssistantMessage)
    }

    /// **用户取消也是 `kind:committed`**，只能靠 eventType 区分。
    ///
    /// 这条是契约里最容易写错的地方：拿 kind 判断会把被取消的输出当成完整正文。
    func testAbortedRunIsCommittedButNotAssistantMessage() throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)

        for frame in try assistantStreamFrames("run.aborted-by-user") {
            XCTAssertNil(journal.apply(assistantStream: frame))
        }

        let attempt = try XCTUnwrap(journal.activeAttempt)
        XCTAssertTrue(attempt.isSettled)
        // kind 仍是 committed —— 这正是陷阱本身。
        XCTAssertEqual(attempt.outcome?.kind, "committed")
        XCTAssertEqual(attempt.outcome?.eventType, HarnessWireSettlement.assistantAttempt)
        XCTAssertFalse(
            attempt.producedAssistantMessage,
            "被取消的输出不得被当成完整正文"
        )
    }

    /// 工具调用回合正常结算为 assistant/message。
    func testToolCallRunSettlesToAssistantMessage() throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)
        for frame in try assistantStreamFrames("run.tool-call") {
            XCTAssertNil(journal.apply(assistantStream: frame))
        }
        let attempt = try XCTUnwrap(journal.activeAttempt)
        XCTAssertEqual(attempt.outcome?.eventType, HarnessWireSettlement.assistantMessage)
        XCTAssertTrue(attempt.producedAssistantMessage)
    }

    // MARK: - 5. 拒绝路径（每条都配正向对照）

    /// 没有 start 就来 chunk：必须拒绝，且**不伪造** attemptId。
    ///
    /// 前置事实（实测 `follow-frames.json`）：真实 snapshot 带
    /// `assistantStream: {"revision": 0}` 但**没有** `activeAttempt`，表示本代没有正在
    /// 进行的输出。所以 snapshot 之后 activeAttempt 为空，直接来 chunk 就是无 start。
    func testChunkBeforeStartIsRejected() throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)
        XCTAssertNil(journal.activeAttempt, "无 activeAttempt 的基线不得凭空造出一个 attempt")

        let frames = try assistantStreamFrames("run.text.completed")
        let chunk = try XCTUnwrap(frames.first { $0.type == HarnessWireAssistantFrame.chunk })

        let rejection = journal.apply(assistantStream: chunk)
        XCTAssertEqual(rejection, .missingStart)
        XCTAssertNil(journal.activeAttempt, "被拒后不得留下一个编造的 attempt")
    }

    /// 正向对照：snapshot 带 `activeAttempt` 时，活动 attempt 必须被消费。
    ///
    /// 这是"中途打开"能恢复正在进行的输出的前提——契约 D3 要求消费基线，
    /// 不允许只读 records。
    func testSnapshotWithActiveAttemptConsumesBaseline() throws {
        let baseline = HarnessAssistantStreamBaseline(
            revision: 1,
            activeAttempt: HarnessActiveAttempt(
                attemptId: "h00-attempt-0001",
                startedAfterSeq: 13,
                turn: 1,
                step: 1,
                nextIndex: 0,
                stream: []
            )
        )
        let snapshot = HarnessSnapshot(
            type: "snapshot",
            header: HarnessSnapshotHeader(
                version: 3, id: "h00-id-0001", createdAt: nil,
                cwd: "/h00/workspace", isSeeded: false, agentPreset: nil
            ),
            cursor: 2,
            records: [],
            hasMore: false,
            projections: nil,
            assistantStream: baseline
        )
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)

        let attempt = try XCTUnwrap(journal.activeAttempt)
        XCTAssertEqual(attempt.attemptID, "h00-attempt-0001")
        XCTAssertEqual(attempt.turn, 1)
        XCTAssertEqual(attempt.step, 1)
        // 基线 revision 为 1，下一个 chunk 应从 2 开始（连续）。
        XCTAssertEqual(attempt.lastRevision, 1)
        XCTAssertFalse(attempt.isSettled, "恢复出来的活动 attempt 尚未结算")
    }

    /// revision 跳号 = 断档：必须拒绝并记录，不能把断档接上。
    func testRevisionGapIsRejected() throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)

        let frames = try assistantStreamFrames("run.text.completed")
        // 依次喂到 revision 3，然后跳过一个 revision。
        for frame in frames.prefix(3) {
            XCTAssertNil(journal.apply(assistantStream: frame))
        }
        let gapFrame = try XCTUnwrap(
            frames.first { $0.type == HarnessWireAssistantFrame.chunk && $0.revision == 5 }
        )

        let rejection = journal.apply(assistantStream: gapFrame)
        guard case .revisionGap(let gap) = rejection else {
            XCTFail("revision 跳号必须被识别为断档，实际是 \(String(describing: rejection))")
            return
        }
        XCTAssertEqual(gap.expected, 4)
        XCTAssertEqual(gap.actual, 5)
        XCTAssertNotNil(journal.revisionGap, "断档必须留在 journal 上供调用方决策")
    }

    /// attemptId 不符：拒绝。
    func testAttemptMismatchIsRejected() throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)

        let frames = try assistantStreamFrames("run.text.completed")
        for frame in frames.prefix(3) { journal.apply(assistantStream: frame) }

        let foreign = HarnessAssistantStreamFrame(
            type: HarnessWireAssistantFrame.chunk,
            revision: 4,
            index: 3,
            chunk: nil,
            outcome: nil,
            attemptId: "h00-attempt-9999",
            turn: nil,
            step: nil,
            startedAfterSeq: nil
        )
        guard case .attemptMismatch(let expected, let actual)? = journal.apply(assistantStream: foreign) else {
            XCTFail("attemptId 不符必须被拒绝")
            return
        }
        XCTAssertEqual(expected, "h00-attempt-0001")
        XCTAssertEqual(actual, "h00-attempt-9999")
    }

    /// snapshot 之前来的 live 帧：拒绝（基线尚未建立）。
    func testLiveFrameBeforeSnapshotIsRejected() throws {
        var journal = HarnessSessionJournal(generation: 1)
        let frames = try assistantStreamFrames("run.text.completed")
        XCTAssertEqual(journal.apply(assistantStream: frames[0]), .beforeSnapshot)
    }

    // MARK: - 6. 分页终止

    /// 分页遇无进展必须停止（不能无限循环）。
    func testPaginationStopsWhenPageBringsNothingNew() async throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)
        let existing = snapshot.records ?? []

        // 上游反复返回同一页：hasMore 永远为真，但内容不变。
        let loader = HarnessHistoryLoader(pageSize: 10, maxPages: 5) { _ in
            HarnessHistoryLoader.HarnessHistoryPage(
                records: existing,
                hasMore: true,
                nextBeforeSeq: 0
            )
        }
        let outcome = try await loader.loadEarlierHistory(sessionID: "h00-session-0001", into: &journal)

        XCTAssertEqual(outcome, .noProgress(pages: 1), "无进展必须立即停止，不能空转到上限")
    }

    /// 上游说还有更多却不给游标：停止并如实报告，**不编造**位置。
    func testPaginationStopsWhenUpstreamOmitsCursor() async throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)

        let loader = HarnessHistoryLoader(pageSize: 10, maxPages: 5) { _ in
            HarnessHistoryLoader.HarnessHistoryPage(
                records: [HarnessSnapshotRecord(type: "event", event: HarnessDurableEvent(
                    type: "turn/start", seq: 100, time: nil, data: nil
                ))],
                hasMore: true,
                nextBeforeSeq: nil
            )
        }
        let outcome = try await loader.loadEarlierHistory(sessionID: "h00-session-0001", into: &journal)
        XCTAssertEqual(outcome, .missingCursor(pages: 1))
    }

    /// 正常读到末尾。
    func testPaginationReachesEnd() async throws {
        let snapshot = try snapshotFixture()
        var journal = HarnessSessionJournal(generation: 1)
        journal.apply(snapshot: snapshot, acceptingGeneration: 1)

        let loader = HarnessHistoryLoader(pageSize: 10, maxPages: 20) { request in
            // 断言 throughSeq 确实取自 snapshot 的 cursor。
            XCTAssertEqual(request.throughSeq, 2, "throughSeq 必须是本次 snapshot 的 cursor")
            return HarnessHistoryLoader.HarnessHistoryPage(
                records: [HarnessSnapshotRecord(type: "event", event: HarnessDurableEvent(
                    type: "turn/start", seq: -1, time: nil, data: nil
                ))],
                hasMore: false,
                nextBeforeSeq: nil
            )
        }
        let outcome = try await loader.loadEarlierHistory(sessionID: "h00-session-0001", into: &journal)
        XCTAssertEqual(outcome, .reachedEnd(pages: 1))
        XCTAssertNotNil(journal.record(atSeq: -1), "更早的历史必须 prepend 进来")
    }

    /// 没有 snapshot 就没有合法 throughSeq：必须抛错而不是猜一个。
    func testHistoryLoadWithoutSnapshotCursorThrows() async throws {
        var journal = HarnessSessionJournal(generation: 1)
        let loader = HarnessHistoryLoader { _ in
            XCTFail("没有合法 throughSeq 时不得发起请求")
            return HarnessHistoryLoader.HarnessHistoryPage(records: [], hasMore: false, nextBeforeSeq: nil)
        }

        do {
            _ = try await loader.loadEarlierHistory(sessionID: "h00-session-0001", into: &journal)
            XCTFail("缺少 snapshot.cursor 时必须显式失败")
        } catch let error as HarnessTransportError {
            guard case .malformedResponse = error else {
                XCTFail("期望 malformedResponse，实际 \(error)")
                return
            }
        }
    }
}

// MARK: - #499 历史分页（session/page）

/// 原生历史读取的入口契约：throughSeq 来源、游标口径、投影身份。
@MainActor
final class HarnessHistoryPageTests: XCTestCase {

    private let sessionID = "h00-session-0001"

    /// 读冻结契约里的夹具字节。与解码器共用同一份来源，避免"测试自己造的形状"。
    /// 上溯层级与既有 `harnessFixtureJSON` 一致（先去掉文件名，再退四级到仓库根）。
    func harnessFixtureJSON(_ name: String) throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root
            .appendingPathComponent("contracts/harness-native/fixtures")
            .appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 夹具里的 `session/page` 结果必须能解出记录。
    ///
    /// 用的是冻结契约的同一份字节：解码器与上游形状漂移会让历史静默变空。
    func testFixtureSessionPageDecodes() throws {
        let fixture = try harnessFixtureJSON("rpc/session-page.json")
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        let result = try XCTUnwrap(
            observations.first { ($0["label"] as? String) == "result" }?["value"]
        )
        let data = try JSONSerialization.data(withJSONObject: result)
        let value = try JSONDecoder().decode(HarnessJSONValue.self, from: data)

        let page = try HarnessHistoryPageDecoding.page(from: value)

        XCTAssertFalse(page.records.isEmpty, "夹具里有真实回合记录")
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.records.first?.seq, 0, "seq 是持久日志主键，从 0 起")
    }

    /// 缺 `hasMore` / `records` 必须显式失败，不能当成空页。
    func testMalformedPageFailsInsteadOfLookingEmpty() {
        XCTAssertThrowsError(try HarnessHistoryPageDecoding.page(from: .object(["records": .array([])])))
        XCTAssertThrowsError(try HarnessHistoryPageDecoding.page(from: .object(["hasMore": .bool(true)])))
    }

    /// `records` 不是数组时必须失败，**不能**退化成空页。
    ///
    /// 旧写法 `rawRecords.arrayValue?.compactMap { ... } ?? []` 会在容器类型错误时
    /// 得到空数组；调用方再因为"没有下一页游标"而停止分页——协议错误被伪装成
    /// "历史已经读完"，用户看不到任何异常。
    func testRecordsOfWrongContainerTypeIsNotAnEmptyPage() {
        for bad in [
            HarnessJSONValue.object([:]),
            .string("nope"),
            .number(3),
            .bool(false),
        ] {
            XCTAssertThrowsError(
                try HarnessHistoryPageDecoding.page(
                    from: .object(["hasMore": .bool(false), "records": bad])
                ),
                "records 不是数组时必须失败，实际静默接受：\(bad)"
            )
        }
    }

    /// 记录缺 `event` 或 `seq` 时必须失败，不能静默丢那一条。
    ///
    /// 丢掉正文用户看不到，而分页游标却仍按剩余记录推进——历史中间会凭空少一段。
    func testRecordMissingEventOrSeqFails() {
        // 缺 event
        XCTAssertThrowsError(try HarnessHistoryPageDecoding.page(from: .object([
            "hasMore": .bool(false),
            "records": .array([.object(["type": .string("event")])]),
        ])))

        // 有 event 但缺 seq：没有分页位置，也没有稳定身份。
        XCTAssertThrowsError(try HarnessHistoryPageDecoding.page(from: .object([
            "hasMore": .bool(false),
            "records": .array([.object([
                "type": .string("event"),
                "event": .object([
                    "type": .string(HarnessWireEventType.userMessage),
                    "data": .object([:]),
                ]),
            ])]),
        ])))
    }

    /// 合法的一页仍然正常解出（正向对照，避免上面的严格化把正常路径也拒了）。
    func testWellFormedPageStillDecodes() throws {
        let page = try HarnessHistoryPageDecoding.page(from: .object([
            "hasMore": .bool(true),
            "records": .array([.object([
                "type": .string("event"),
                "event": .object([
                    "type": .string(HarnessWireEventType.userMessage),
                    "seq": .number(7),
                    "data": .object([:]),
                ]),
            ])]),
        ]))
        XCTAssertEqual(page.records.map(\.seq), [7])
        XCTAssertTrue(page.hasMore)
    }

    /// 游标与 seq 的桥接是双向一致的，且拒绝外来游标。
    ///
    /// Store 说的是不透明字符串游标，原生说的是整数 seq。混用会让分页读到错误的
    /// 区间——而且不会报错，只会静默给出错的页。
    func testCursorRoundTripsAndRejectsForeignCursors() throws {
        let cursor = HarnessHistoryPageDecoding.cursor(before: 42)
        XCTAssertEqual(try HarnessHistoryPageDecoding.seq(fromCursor: cursor), 42)
        XCTAssertNil(try HarnessHistoryPageDecoding.seq(fromCursor: nil))
        XCTAssertNil(try HarnessHistoryPageDecoding.seq(fromCursor: "   "))

        // 别的 runtime 的游标不得被当成同一个空间。
        XCTAssertThrowsError(try HarnessHistoryPageDecoding.seq(fromCursor: "codex-cursor-1"))
        XCTAssertThrowsError(try HarnessHistoryPageDecoding.seq(fromCursor: "hseq:not-a-number"))
    }

    /// 投影只保留可展示记录，且身份以原生 seq 为准。
    ///
    /// seq 是持久日志主键：历史页与直播算出同一个 id，才不会出现第二个气泡。
    func testProjectionKeepsDisplayableRecordsAndUsesSeqIdentity() {
        let records = [
            durable(type: "permission/preset", seq: 0, data: ["preset": .string("workspace-write")]),
            durable(type: HarnessWireEventType.userMessage, seq: 1, data: [
                "content": .array([.object(["type": .string("text"), "text": .string("你好")])]),
                "source": .object(["kind": .string("user"), "rpcId": .string("req-1")]),
            ]),
            durable(type: HarnessWireEventType.assistantMessage, seq: 2, data: [
                "message": .object(["content": .array([
                    .object(["type": .string("text"), "text": .string("回复")]),
                ])]),
            ]),
            durable(type: "step/start", seq: 3, data: ["turn": .number(1)]),
        ]

        let messages = HarnessHistoryProjection.messages(from: records, sessionID: sessionID)

        XCTAssertEqual(messages.map(\.content), ["你好", "回复"], "只投影可展示记录")
        XCTAssertEqual(messages.map(\.id), ["h-seq-1-user", "h-seq-2-assistant"])
        XCTAssertEqual(messages.first?.clientMessageID, "req-1")
    }

    /// 注入上下文（source.kind != user）不得伪装成用户发言。
    func testInjectedContextIsNotProjectedAsUserMessage() {
        let records = [
            durable(type: HarnessWireEventType.userMessage, seq: 5, data: [
                "content": .array([.object([
                    "type": .string("text"), "text": .string("skill catalog"),
                ])]),
                "source": .object(["kind": .string("plugin")]),
            ]),
        ]

        let messages = HarnessHistoryProjection.messages(from: records, sessionID: sessionID)

        XCTAssertTrue(messages.isEmpty, "注入上下文不是用户说的话")
    }

    private func durable(
        type: String,
        seq: Int,
        data: [String: HarnessJSONValue]
    ) -> HarnessDurableEvent {
        HarnessDurableEvent(type: type, seq: seq, time: 1_789_755_158_627, data: .object(data))
    }
}
