import Foundation

/// 一条会话的原生 journal：持久记录 + 活动 attempt。
///
/// 这里**只维护数据**，不投影成 UI 展示类型（那是 H08 的职责），也不碰 `ConversationStore`。
///
/// ## 为什么以 seq 为键
///
/// 契约 D3 要求"durable 记录以 (host, runtime, session, native seq) 去重"。把 seq 当主键
/// 不只是去重手段，它让**到达顺序不再影响结果**：无论历史页先到、直播帧先到，还是两者交错，
/// 同一 seq 的记录都落到同一个位置。H06 卡片要求"同一 fixture 在四种顺序下得到一致 durable
/// 结果"，靠的就是这条性质，而不是靠在每条路径上分别做补偿。
///
/// 反面做法（也能跑通简单场景，但会在重连与重试上出错）：把记录按到达顺序 append，
/// 再用 (turn, step) 去重。重试可以发生在同一步，(turn, step) 会把两次不同的 attempt
/// 合并成一条——契约明确禁止。
///
/// ## 活动 attempt 与结算
///
/// `assistantStream` 是**进程内**流（契约 §2.7），不是持久日志。它用 `attemptId` /
/// `revision` / `index` 管理；结算靠 `end.outcome`，它带 `eventType` 与 `seq`。
///
/// 关键事实（实测，见 `stream/assistant-stream.json`）：
/// - `outcome.kind` **恒为** `committed`，**用户取消也是 committed**
///   （`run.aborted-by-user` 的 end 帧）。所以**不能**用 kind 判断"有完整正文"，
///   只能看 `eventType`：正常结算 `assistant/message`，被取消 `assistant/attempt`。
/// - `revision` 连续递增（start 为 1），跳号即断档，必须重开 follow。
/// - 重连后 revision **从 1 重新开始**，并带 `activeAttempt` 基线
///   （`recovery/recovery-semantics.json` 的 `reconnectBaseline`）。
struct HarnessSessionJournal: Equatable {

    /// 本 journal 所属代次。切 host / 重连都会换一个。
    ///
    /// 代次只增不减：旧代次的 snapshot 不能回滚新代次已经建立的记录。
    private(set) var generation: UInt64

    /// durable 记录，主键是原生 seq。
    private var recordsBySeq: [Int: HarnessDurableEvent]

    /// 仍活动的 attempt（尚未结算）。
    private(set) var activeAttempt: HarnessJournalAttempt?

    /// 最近一次检测到的 revision 断档。非 nil 表示必须重开 follow，不能把断档静默接上。
    private(set) var revisionGap: HarnessJournalRevisionGap?

    /// 当前**整轮**的活跃 turn 号（不限于 assistant attempt）。
    ///
    /// 与 `activeAttempt` 的区别是承重的：assistant attempt 只覆盖"模型正在产出"这一小段，
    /// 而一个 turn 在 attempt 结束后仍可能继续（跑工具、等人机应答、等下一步输出）。
    /// 停止目标校验必须看整轮，否则工具运行中、两个 attempt 之间会没有可比对的目标，
    /// 一次迟到的"停止 A"就会停掉之后开始的 B。
    ///
    /// 由 `turn/start` 置位、`turn/end` 清除——两者都是 durable 记录，因此它对
    /// "还没收到 assistant-stream 基线"和"attempt 已结算"两种情况都成立。
    private(set) var activeTurnNumber: Int?

    /// 是否已经收到过 opening snapshot。没收到就不该接受 live 帧——
    /// 那些帧属于一个我们还没建立基线的流。
    private(set) var hasOpenedSnapshot = false

    /// 本次 snapshot 的切点，也是 `session/page` 唯一合法的 `throughSeq`。
    ///
    /// 契约 §5.5：它属于**这一代** snapshot，不能混用上一代游标；传 0 只会读到 seq 0。
    private(set) var snapshotCursor: Int?

    init(generation: UInt64 = 0) {
        self.generation = generation
        self.recordsBySeq = [:]
    }

    // MARK: - 读取

    /// 按 seq 升序的全部持久记录。这是"一致 durable 结果"的比较基准。
    var orderedRecords: [HarnessDurableEvent] {
        recordsBySeq.keys.sorted().compactMap { recordsBySeq[$0] }
    }

    var recordCount: Int { recordsBySeq.count }

    func record(atSeq seq: Int) -> HarnessDurableEvent? { recordsBySeq[seq] }

    /// 本代的日志前沿。没有记录时为 nil，而不是 0——0 与"还没有任何记录"是两件事。
    var latestSeq: Int? { recordsBySeq.keys.max() }

    // MARK: - snapshot（opening frame）

    /// 应用 opening snapshot。
    ///
    /// `acceptingGeneration` 由调用方给出（中继连接代次）。只有**不比当前代次旧**的
    /// snapshot 才能改写基线：一个迟到的旧 snapshot 不能把新代次的记录回滚掉。
    ///
    /// 返回是否被接受。被拒绝不是一个错误——它是"这条 snapshot 已经过期"这个正常结论。
    @discardableResult
    mutating func apply(snapshot: HarnessSnapshot, acceptingGeneration: UInt64) -> Bool {
        guard acceptingGeneration >= generation else { return false }
        // 同代次的重复 snapshot 是允许的（上游可能重发），按 seq 覆盖即可——幂等。
        generation = acceptingGeneration

        // snapshot 的 records 是这一代的持久基线。
        if let records = snapshot.records {
            for record in records {
                guard let event = record.event, let seq = event.seq else { continue }
                // 只覆盖同一 seq：不因为收到新 snapshot 就丢掉 snapshot 之后到达的 live 记录，
                // 也不让旧 snapshot 的 seq 覆盖更新的同 seq 内容。
                recordsBySeq[seq] = event
            }
        }
        // 轮次生命周期必须按 seq 顺序重放，不能只看"最后一条 turn 事件"：
        // snapshot 是窗口，中间可能有多轮开始与结束。
        activeTurnNumber = nil
        for seq in recordsBySeq.keys.sorted() {
            guard let event = recordsBySeq[seq] else { continue }
            advanceTurnLifecycle(with: event)
        }

        snapshotCursor = snapshot.cursor
        hasOpenedSnapshot = true
        revisionGap = nil

        // 活动基线。缺它而我们又 opt-in 了 assistantStream 时上游会报错，
        // 因此这里必须消费，不能只读 records。
        //
        // 分两种情况（实测）：
        // - `{"revision":0}` 无 activeAttempt → 本代没有正在进行的输出，活动 attempt 为空。
        //   注意 `assistantStream` 键本身存在只表示"我们 opt-in 了"，不代表有活动 attempt。
        // - `{"revision":1,"activeAttempt":{…}}` → 重连时流从 revision 1 重新开始，
        //   基线就是那第一帧之后的状态：lastRevision 取 baseline.revision（=1），
        //   下一个 chunk 的 revision 应为 2。
        if let baseline = snapshot.assistantStream, let active = baseline.activeAttempt {
            let chunks = active.stream
                .flatMap(\.expandedChunks)
                .enumerated()
                .map { offset, chunk in
                    HarnessAssistantStreamFrame(
                        type: HarnessWireAssistantFrame.chunk,
                        revision: nil,
                        index: offset,
                        chunk: chunk,
                        outcome: nil,
                        attemptId: active.attemptId,
                        turn: nil,
                        step: nil,
                        startedAfterSeq: nil
                    )
                }
            activeAttempt = HarnessJournalAttempt(
                attemptID: active.attemptId,
                turn: active.turn,
                step: active.step,
                startedAfterSeq: active.startedAfterSeq,
                lastRevision: baseline.revision ?? 0,
                nextChunkIndex: active.nextIndex,
                chunks: chunks
            )
        } else {
            // 没有正在进行的输出（或压根没有基线）：清掉上一代的残留——
            // 留着它会把旧 attempt 的片段接到新代次上。
            activeAttempt = nil
        }
        return true
    }

    // MARK: - 持久事件（live durable）

    /// 应用一条 live durable 事件。返回是否新增（false = 同 seq 重复，幂等）。
    ///
    /// 重复投递是正常现象：契约 D3 要求"重连重投同 eventId 更新原记录，不新增副本"。
    @discardableResult
    mutating func apply(durableEvent event: HarnessDurableEvent) -> Bool {
        guard let seq = event.seq else { return false }
        let isNew = recordsBySeq[seq] == nil
        recordsBySeq[seq] = event
        // 轮次生命周期以 seq 为序推进。重复投递同一 seq 的 turn/start|end 幂等，
        // 不会因为重投把已经结束的轮次重新标成活跃。
        if isNew {
            advanceTurnLifecycle(with: event)
        }
        return isNew
    }

    /// 按 durable turn 边界推进当前轮次。
    ///
    /// 只认 `turn/start` 与 `turn/end` 两个类型。认不出的不动状态——
    /// 猜一个轮次号会让停止校验比没有校验更危险。
    private mutating func advanceTurnLifecycle(with event: HarnessDurableEvent) {
        switch event.type {
        case HarnessWireEventType.turnStart:
            if let turn = event.data?["turn"]?.intValue {
                activeTurnNumber = turn
            }
        case HarnessWireEventType.turnEnd:
            // `turn/end` 的 reason 不影响"这一轮已经结束"这个结论：
            // completed / error / aborted 都表示会话不再跑这个轮次。
            activeTurnNumber = nil
        default:
            break
        }
    }

    // MARK: - 活动 attempt（assistant-stream）

    /// 应用一帧 assistant-stream 直播片段。
    ///
    /// 返回失败原因；nil 表示已接受。**调用方遇到失败必须重开 follow**，不能继续往
    /// 一个已经断档的活动流上接片段。
    @discardableResult
    mutating func apply(assistantStream frame: HarnessAssistantStreamFrame) -> HarnessJournalStreamRejection? {
        guard hasOpenedSnapshot else { return .beforeSnapshot }

        switch frame.type {
        case HarnessWireAssistantFrame.start:
            return applyStart(frame)
        case HarnessWireAssistantFrame.chunk:
            return applyChunk(frame)
        case HarnessWireAssistantFrame.end:
            return applyEnd(frame)
        default:
            // 认不出的帧型：不猜语义，也不静默丢弃。
            return .unknownFrameType(frame.type)
        }
    }

    private mutating func applyStart(_ frame: HarnessAssistantStreamFrame) -> HarnessJournalStreamRejection? {
        // 新 attempt 开始：上一个若未结算，说明它被中断了（不是正常结束）。
        if activeAttempt != nil {
            // 允许替换，但记下事实：调用方据此决定是否要提示"上一次输出未完成"。
            activeAttempt?.wasSuperseded = true
        }
        // `start` **自己占一个 revision**（实测为 1，之后第一个 chunk 是 2）。
        // 所以 lastRevision 取 start 的 revision，而不是从 0 起算——否则第一帧 chunk
        // 就会被误判成断档。index 从 0 开始（start 不带 index）。
        activeAttempt = HarnessJournalAttempt(
            frame: frame,
            lastRevision: frame.revision ?? 0,
            nextChunkIndex: 0
        )
        return nil
    }

    private mutating func applyChunk(_ frame: HarnessAssistantStreamFrame) -> HarnessJournalStreamRejection? {
        guard var attempt = activeAttempt else {
            // 没收到 start 就先来 chunk。**不猜** attemptId，也不新建一个假 attempt。
            return .missingStart
        }
        // 同一 attemptId 才能接上；换 id 说明这是另一条流。
        if let frameAttempt = frame.attemptId, frameAttempt != attempt.attemptID {
            return .attemptMismatch(expected: attempt.attemptID, actual: frameAttempt)
        }
        // 已消费的 index 是重投，不再次推进 revision 或追加正文。
        if let index = frame.index, index < attempt.nextChunkIndex { return nil }
        // revision 必须连续（expected = previous + 1）。跳号即断档。
        if let revision = frame.revision, revision != attempt.lastRevision + 1 {
            let gap = HarnessJournalRevisionGap(
                attemptID: attempt.attemptID,
                expected: attempt.lastRevision + 1,
                actual: revision
            )
            revisionGap = gap
            return .revisionGap(gap)
        }
        // index 必须稠密递增；跳号意味着丢失了正文前缀，不能静默接续。
        if let index = frame.index {
            guard index == attempt.nextChunkIndex else {
                return .chunkIndexGap(expected: attempt.nextChunkIndex, actual: index)
            }
            attempt.nextChunkIndex = index + 1
        }
        if let revision = frame.revision { attempt.lastRevision = revision }
        attempt.chunks.append(frame)
        activeAttempt = attempt
        return nil
    }

    private mutating func applyEnd(_ frame: HarnessAssistantStreamFrame) -> HarnessJournalStreamRejection? {
        guard var attempt = activeAttempt else { return .missingStart }
        if let frameAttempt = frame.attemptId, frameAttempt != attempt.attemptID {
            return .attemptMismatch(expected: attempt.attemptID, actual: frameAttempt)
        }
        if let revision = frame.revision, revision != attempt.lastRevision + 1 {
            let gap = HarnessJournalRevisionGap(
                attemptID: attempt.attemptID,
                expected: attempt.lastRevision + 1,
                actual: revision
            )
            revisionGap = gap
            return .revisionGap(gap)
        }
        attempt.lastRevision = frame.revision ?? attempt.lastRevision
        attempt.outcome = frame.outcome
        // 结算绑定：`outcome.seq` 指向持久日志里的那条记录。
        // `kind` 不可用（取消也是 committed），只能用 eventType 区分：
        //   assistant/message  → 正常文本结算
        //   assistant/attempt  → 用户取消，不产生 assistant/message
        attempt.settledSeq = frame.outcome?.seq
        attempt.isSettled = true
        activeAttempt = attempt
        return nil
    }

    /// 收下一个已结算的 attempt（UI 已消费它，或它已被 durable 记录取代）。
    mutating func retireSettledAttempt() {
        guard activeAttempt?.isSettled == true else { return }
        activeAttempt = nil
    }

    // MARK: - 历史分页（prepend）

    /// 把一页**更早**的历史记录并入。
    ///
    /// 语义是 prepend：历史页只带来比现有记录更早的 seq。它**不得**覆盖已有的更新记录，
    /// 也不得把 live 追加进来的内容替换回旧快照——那正是"旧 snapshot 回滚新代次"的另一种形态。
    ///
    /// 返回是否发生了实际推进（用于"分页遇无进展必须停止"）。
    @discardableResult
    mutating func prependHistoryPage(records: [HarnessSnapshotRecord]) -> Bool {
        var progressed = false
        for record in records {
            guard let event = record.event, let seq = event.seq else { continue }
            if recordsBySeq[seq] == nil {
                recordsBySeq[seq] = event
                progressed = true
            }
        }
        return progressed
    }

    // MARK: - 代次

    /// 进入新代次。清掉活动 attempt 与 gap——它们属于上一代。
    ///
    /// **不清 durable 记录**：持久历史是可重建的事实，重连不该让用户看到历史消失。
    /// 契约 D1 把 history 归为"可重建的 UI 投影"，但重建成本高于保留，且 seq 主键
    /// 让跨代保留不会产生重复。
    mutating func beginGeneration(_ newGeneration: UInt64) {
        guard newGeneration > generation else { return }
        generation = newGeneration
        activeAttempt = nil
        revisionGap = nil
        hasOpenedSnapshot = false
        snapshotCursor = nil
        // 轮次身份属于上一代：新代次尚未拿到 snapshot，此时**无法确认**活跃轮次。
        // 留着一个旧轮次号会让停止校验误判成"目标匹配"。
        activeTurnNumber = nil
    }
}

// MARK: - 活动 attempt

/// 一条活动（或刚结算）的 assistant attempt。
///
/// 身份是 `attemptId`，**不是** `(turn, step)`——重试可以发生在同一步，
/// 用 (turn, step) 认领会把两次不同的输出合并成一条（契约 D3 明令禁止）。
struct HarnessJournalAttempt: Equatable {
    let attemptID: String?
    let turn: Int?
    let step: Int?
    let startedAfterSeq: Int?
    var lastRevision: Int
    var nextChunkIndex: Int
    var chunks: [HarnessAssistantStreamFrame] = []
    var outcome: HarnessAssistantStreamOutcome?
    /// 结算指向的持久记录 seq。这是与 durable 记录的**唯一**合法关联方式。
    var settledSeq: Int?
    var isSettled = false
    /// 未结算就被下一条 attempt 取代：说明输出被中断。
    var wasSuperseded = false

    /// 由 snapshot 的活动基线构造（重连/中途打开）。
    init(
        attemptID: String?,
        turn: Int?,
        step: Int?,
        startedAfterSeq: Int?,
        lastRevision: Int,
        nextChunkIndex: Int,
        chunks: [HarnessAssistantStreamFrame] = []
    ) {
        self.attemptID = attemptID
        self.turn = turn
        self.step = step
        self.startedAfterSeq = startedAfterSeq
        self.lastRevision = lastRevision
        self.nextChunkIndex = nextChunkIndex
        self.chunks = chunks
    }

    init(frame: HarnessAssistantStreamFrame, lastRevision: Int, nextChunkIndex: Int) {
        self.attemptID = frame.attemptId
        self.turn = frame.turn
        self.step = frame.step
        self.startedAfterSeq = frame.startedAfterSeq
        self.lastRevision = lastRevision
        self.nextChunkIndex = nextChunkIndex
    }

    /// 是否产生了完整正文。
    ///
    /// **不能用 `outcome.kind == "committed"` 判断**：用户取消也是 committed
    /// （实测 `run.aborted-by-user`）。只有 `eventType == "assistant/message"` 才说明
    /// 上一条是正常结算的助手消息；`assistant/attempt` 表示被取消。
    var producedAssistantMessage: Bool {
        guard isSettled else { return false }
        return outcome?.eventType == HarnessWireSettlement.assistantMessage
    }
}

// MARK: - 拒绝原因

/// 直播片段被拒绝的原因。每一种都要求调用方**重开 follow**，不接受静默接续。
enum HarnessJournalStreamRejection: Equatable {
    /// 还没收到 opening snapshot 就来了 live 帧：基线尚未建立。
    case beforeSnapshot
    /// 没收到 start 就来了 chunk 或 end。
    case missingStart
    /// attemptId 与当前活动 attempt 不符。
    case attemptMismatch(expected: String?, actual: String)
    /// revision 跳号：断档。必须重开 follow，不能把断档接上。
    case revisionGap(HarnessJournalRevisionGap)
    /// chunk index 跳号：输出前缀丢失，必须重开 follow。
    case chunkIndexGap(expected: Int, actual: Int)
    /// 认不出的帧型。
    case unknownFrameType(String?)

    var diagnosticSummary: String {
        switch self {
        case .beforeSnapshot: return "before-snapshot"
        case .missingStart: return "missing-start"
        case .attemptMismatch(let expected, let actual):
            return "attempt-mismatch:expected=\(expected ?? "nil"):actual=\(actual)"
        case .revisionGap(let gap):
            return "revision-gap:expected=\(gap.expected):actual=\(gap.actual)"
        case .chunkIndexGap(let expected, let actual):
            return "chunk-index-gap:expected=\(expected):actual=\(actual)"
        case .unknownFrameType(let type): return "unknown-frame-type:\(type ?? "nil")"
        }
    }
}

struct HarnessJournalRevisionGap: Equatable {
    let attemptID: String?
    let expected: Int
    let actual: Int
}
