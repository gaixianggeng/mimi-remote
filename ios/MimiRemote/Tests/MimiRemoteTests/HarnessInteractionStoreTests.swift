import Foundation
import XCTest
@testable import MimiRemote

/// H09 交互闭环测试。
///
/// 卡片的"必须验收"逐项对应在这里：
/// - 未打开会话先来审批 → `testDeliverDoesNotRequireOpenSession`
/// - 审批先于 follow → `testInteractionArrivesBeforeFollow`
/// - 两端同时点 → `testSecondClaimIsRejectedWhileSubmitting`
/// - 答复已生效但 HTTP 丢失 → `testResponseUnknownKeepsCardAndDoesNotResend`
/// - 失败后重投 → `testRedeliveryUpdatesOriginalCardWithoutDuplicate`
/// - 跨 host 晚到事件 → `testStaleGenerationIsNotAnswerable`
/// - 关闭弹窗未作答 → `testClosingCardIsNotAnAnswer`
///
/// 形状类断言读 `contracts/harness-native/fixtures/*`（与 Go 侧同一份字节）。
/// 注意该夹具是**源码级**（`liveCaptureGap` 明写实跑未触发审批），
/// 因此每条正向都配一条形状不符必须拒绝的负向。
@MainActor
final class HarnessInteractionStoreTests: XCTestCase {

    private let generation: UInt64 = 1

    func harnessFixtureJSON(_ name: String) throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root
            .appendingPathComponent("contracts/harness-native/fixtures")
            .appendingPathComponent(name)
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "夹具 \(name) 顶层不是对象")
    }

    private func approvalPayload() -> HarnessWaterfallPayload {
        HarnessWaterfallPayload(toolName: "write", callId: "call-a", reason: nil, questions: nil)
    }

    private func questionPayload() -> HarnessWaterfallPayload {
        HarnessWaterfallPayload(
            toolName: nil, callId: nil, reason: nil,
            questions: [
                HarnessQuestion(id: "q1", question: "选哪个？", options: [
                    HarnessQuestionOption(label: "A"),
                    HarnessQuestionOption(label: "B"),
                ]),
            ]
        )
    }

    // MARK: - 独立于页面

    /// 未打开会话也能登记审批（契约 D5：不要求用户先打开对应会话页面）。
    func testDeliverDoesNotRequireOpenSession() {
        let store = HarnessInteractionStore()
        let added = store.deliver(
            eventID: "evt-1", sessionID: "s-never-opened",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        XCTAssertTrue(added)
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertEqual(store.interaction(eventID: "evt-1")?.sessionID, "s-never-opened")
    }

    /// 审批可以先于 follow 到达（$events 是宿主级通道，与会话订阅无关）。
    func testInteractionArrivesBeforeFollow() {
        let store = HarnessInteractionStore()
        // 这里刻意不建立任何 follow/journal，直接登记。
        XCTAssertTrue(store.deliver(
            eventID: "evt-early", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        ))
        XCTAssertEqual(store.interaction(eventID: "evt-early")?.state, .pending)
    }

    /// 页面释放不得移除 pending。
    ///
    /// 用"登记后再读"来验证没有隐式清理路径：本类型**没有**任何页面生命周期入口，
    /// 这正是设计意图——页面不是 pending 的所有者。
    func testNoPageScopedRemovalExists() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-keep", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        // 唯一会移除的是显式操作（resolve / cancel / forgetSession / 代次失效）。
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertEqual(store.pendingInteractions.map(\.eventID), ["evt-keep"])
    }

    // MARK: - 应答所有权

    /// 正向：待应答 + 代次匹配 → 可认领。
    func testClaimAcceptedForPendingInteraction() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        guard case .accepted(let interaction) = store.claim(eventID: "evt-1", generation: generation) else {
            XCTFail("待应答的交互必须可认领")
            return
        }
        XCTAssertEqual(interaction.eventID, "evt-1")
        XCTAssertEqual(store.interaction(eventID: "evt-1")?.state, .submitting)
    }

    /// 两端同时点：第二次认领必须被拒，且**不改动**状态。
    func testSecondClaimIsRejectedWhileSubmitting() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        _ = store.claim(eventID: "evt-1", generation: generation)

        XCTAssertEqual(store.claim(eventID: "evt-1", generation: generation), .alreadySubmitting)
        XCTAssertEqual(store.interaction(eventID: "evt-1")?.state, .submitting)
    }

    /// 跨 host 晚到事件：旧代次的卡片不可应答。
    func testStaleGenerationIsNotAnswerable() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-old", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: 1
        )
        XCTAssertEqual(store.claim(eventID: "evt-old", generation: 2), .staleGeneration)
    }

    /// 重连：旧代次的待处理项被清掉，且**不记终态**（上游会重投）。
    func testDropStaleGenerationRemovesOldButAllowsRedelivery() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-old", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: 1
        )
        store.dropStaleGeneration(2)
        XCTAssertEqual(store.pendingCount, 0)

        // 上游在新代次上重投同一个 eventId：必须能被登记（没被记成终态）。
        XCTAssertTrue(store.deliver(
            eventID: "evt-old", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: 2
        ), "重投必须能重新登记")
    }

    /// 未投递给本连接的 eventId 不可认领。
    func testUnknownEventIsNotClaimable() {
        let store = HarnessInteractionStore()
        XCTAssertEqual(store.claim(eventID: "never-seen", generation: generation), .unknown)
    }

    // MARK: - 结果未知（核心）

    /// **答复已生效但 HTTP 丢失：保留卡片、不自动重发。**
    ///
    /// 这是本任务最需要防住的后果：自动重发会让一次审批被应用两次。
    func testResponseUnknownKeepsCardAndDoesNotResend() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        _ = store.claim(eventID: "evt-1", generation: generation)
        store.markResponseUnknown(eventID: "evt-1", detail: "timedOut")

        // 卡片仍在，且状态是 responseUnknown。
        guard case .responseUnknown(let detail)? = store.interaction(eventID: "evt-1")?.state else {
            XCTFail("结果未知必须保留卡片并标记状态")
            return
        }
        XCTAssertEqual(detail, "timedOut")

        // 关键：不能再认领一次（那就是重发）。
        XCTAssertEqual(
            store.claim(eventID: "evt-1", generation: generation), .alreadySubmitting,
            "结果未知时不得再次应答——重发可能让审批被应用两次"
        )
    }

    /// 明确失败后可以重试（那是"没生效"的确定结论）。
    func testExplicitFailureAllowsRetry() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        _ = store.claim(eventID: "evt-1", generation: generation)
        store.releaseAfterExplicitFailure(eventID: "evt-1")

        XCTAssertEqual(store.interaction(eventID: "evt-1")?.state, .pending)
        guard case .accepted = store.claim(eventID: "evt-1", generation: generation) else {
            XCTFail("明确失败后必须能重试")
            return
        }
    }

    /// 结果未知收到同代次 cancel 后必须撤卡，但不宣称哪一端的决定获胜。
    func testResponseUnknownSettlesOnTrustedExternalCancel() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        _ = store.claim(eventID: "evt-1", generation: generation)
        store.markResponseUnknown(eventID: "evt-1", detail: "unknown")

        XCTAssertTrue(store.cancelExternally(eventID: "evt-1", generation: generation))
        XCTAssertNil(store.interaction(eventID: "evt-1"), "cancel 后不得保留可操作卡片")
        XCTAssertEqual(store.claim(eventID: "evt-1", generation: generation), .settled)

        // 新代次若上游重新投递，只恢复成待应答；不能自动重发旧决定。
        XCTAssertTrue(store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation + 1
        ))
        XCTAssertEqual(store.interaction(eventID: "evt-1")?.state, .pending)
    }

    // MARK: - 撤卡与重投

    /// 另一端先应答 → 撤卡；且同一 eventId 不再复活。
    func testExternalCancelRemovesAndPreventsRevival() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        XCTAssertTrue(
            store.cancelExternally(eventID: "evt-1", generation: generation),
            "本连接展示过的卡片必须通知撤下"
        )
        XCTAssertNil(store.interaction(eventID: "evt-1"))

        // 迟到的 waterfall 不得复活它。
        XCTAssertFalse(store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        ), "已撤下的 eventId 不得复活")
    }

    /// cancel 先于 waterfall：撤卡不通知 UI，但仍阻止后续复活。
    func testCancelBeforeDeliveryStillBlocksRevival() {
        let store = HarnessInteractionStore()
        XCTAssertFalse(
            store.cancelExternally(eventID: "evt-late", generation: generation),
            "没展示过就不该通知 UI"
        )
        XCTAssertFalse(store.deliver(
            eventID: "evt-late", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        ))
    }

    func testStaleCancelCannotRemoveNewGenerationRedelivery() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-new", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation + 1
        )

        XCTAssertFalse(store.cancelExternally(eventID: "evt-new", generation: generation))
        XCTAssertEqual(store.interaction(eventID: "evt-new")?.generation, generation + 1)
        XCTAssertEqual(store.interaction(eventID: "evt-new")?.state, .pending)
    }

    /// **失败后重投更新原卡片，不新增副本。**
    func testRedeliveryUpdatesOriginalCardWithoutDuplicate() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        let added = store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: HarnessWaterfallPayload(toolName: "write", callId: "call-b", reason: nil, questions: nil),
            generation: generation
        )

        XCTAssertFalse(added, "同 eventId 重投不得算新增")
        XCTAssertEqual(store.pendingCount, 1, "不得产生第二张卡")
        XCTAssertEqual(store.interaction(eventID: "evt-1")?.request.callId, "call-b", "内容必须更新")
    }

    /// 重投不得把正在应答的卡片回退成待应答（会让用户重复决定）。
    func testRedeliveryDoesNotResetSubmittingState() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        _ = store.claim(eventID: "evt-1", generation: generation)

        store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        XCTAssertEqual(store.interaction(eventID: "evt-1")?.state, .submitting, "应答中不得被重投回退")
    }

    // MARK: - 撤权

    /// 撤权丢弃该会话的待处理项，但**不记终态**（重新授权后应能重投）。
    func testForgetSessionAllowsRedeliveryAfterReauthorization() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-1", sessionID: "s-a",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        store.deliver(
            eventID: "evt-2", sessionID: "s-b",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        store.forgetSession("s-a")

        XCTAssertEqual(store.pendingCount, 1, "只丢该会话的")
        XCTAssertNil(store.interaction(eventID: "evt-1"))
        XCTAssertNotNil(store.interaction(eventID: "evt-2"))
        // 重新授权后重投同一 eventId 必须能登记。
        XCTAssertTrue(store.deliver(
            eventID: "evt-1", sessionID: "s-a",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        ))
    }

    // MARK: - 关闭弹窗不是应答

    /// 关闭弹窗/离开页面**不是**一种应答：卡片必须仍是待应答。
    ///
    /// 契约 D5：不把关闭弹窗等同于答复。因此本类型没有"关闭即 resolved"的入口——
    /// 这条测试断言那个入口不存在（调用 forgetSession 之外的任何读操作都不改状态）。
    func testClosingCardIsNotAnAnswer() {
        let store = HarnessInteractionStore()
        store.deliver(
            eventID: "evt-1", sessionID: "s1",
            event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), generation: generation
        )
        // 读一遍（UI 关闭卡片时会读状态），状态不得改变。
        _ = store.pendingInteractions
        _ = store.interaction(eventID: "evt-1")
        XCTAssertEqual(store.interaction(eventID: "evt-1")?.state, .pending, "关闭弹窗不是应答")
    }

    // MARK: - 应答形状（源码级夹具 → fail closed）

    /// 正向对照：审批的两个可选用值都能构造出正确答案。
    func testApprovalOutcomeForSelectableValues() throws {
        for value in HarnessInteractionAnswer.userSelectableApprovalValues {
            let outcome = try HarnessInteractionAnswer.approvalOutcome(decision: value)
            XCTAssertEqual(outcome, .result(.string(value)))
        }
        // 明确不提供的两个：它们不是用户在按钮组里做的决定。
        XCTAssertFalse(HarnessInteractionAnswer.userSelectableApprovalValues.contains("cancelled"))
        XCTAssertFalse(HarnessInteractionAnswer.userSelectableApprovalValues.contains("unavailable"))
    }

    /// 负向：取值域之外的审批结论必须拒绝（不构造"看起来像"的应答）。
    func testApprovalOutcomeRejectsUnknownDecision() {
        for value in ["always-allow", "allow-session", "", "ALLOWED-ONCE"] {
            XCTAssertThrowsError(try HarnessInteractionAnswer.approvalOutcome(decision: value)) { error in
                XCTAssertEqual(error as? HarnessInteractionAnswerError, .unsupportedDecision(value))
            }
        }
    }

    /// 正向对照：冻结 0.1.5-rc.2 的选项只有 label，应答也回传 label。
    func testQuestionsOutcomeMatchesFrozenShape() throws {
        let questions = questionPayload().questions ?? []
        let outcome = try HarnessInteractionAnswer.questionsOutcome(
            answers: ["q1": ["A"]], questions: questions
        )
        XCTAssertEqual(
            outcome,
            .result(.object(["answers": .array([
                .object(["id": .string("q1"), "selected": .array([.string("A")])]),
            ])]))
        )
    }

    func testQuestionsDecodeRealLabelOnlyOptionShape() throws {
        let data = Data(#"{"questions":[{"id":"q1","question":"Pick one","options":[{"label":"A"},{"label":"B","description":"detail"}]}]}"#.utf8)
        let payload = try JSONDecoder().decode(HarnessWaterfallPayload.self, from: data)
        let questions = try XCTUnwrap(payload.questions)

        let outcome = try HarnessInteractionAnswer.questionsOutcome(
            answers: ["q1": ["B"]], questions: questions
        )

        XCTAssertEqual(
            outcome,
            .result(.object(["answers": .array([
                .object(["id": .string("q1"), "selected": .array([.string("B")])]),
            ])]))
        )
    }

    func testQuestionsOutcomePreservesLabelIdentityWithoutTrimming() throws {
        let data = Data(#"{"questions":[{"id":"q1","question":"Pick one","options":[{"label":" A "}]}]}"#.utf8)
        let payload = try JSONDecoder().decode(HarnessWaterfallPayload.self, from: data)
        let questions = try XCTUnwrap(payload.questions)

        let outcome = try HarnessInteractionAnswer.questionsOutcome(
            answers: ["q1": [" A "]], questions: questions
        )

        XCTAssertEqual(
            outcome,
            .result(.object(["answers": .array([
                .object(["id": .string("q1"), "selected": .array([.string(" A ")])]),
            ])]))
        )
    }

    /// 负向：请求中不存在的 label 必须拒绝（不能把任意文本伪装成选项）。
    func testQuestionsOutcomeRejectsUnknownOption() {
        let questions = questionPayload().questions ?? []
        XCTAssertThrowsError(try HarnessInteractionAnswer.questionsOutcome(
            answers: ["q1": ["forged-label"]], questions: questions
        )) { error in
            XCTAssertEqual(
                error as? HarnessInteractionAnswerError,
                .unknownOptionLabel(questionID: "q1", optionLabel: "forged-label")
            )
        }
    }

    /// 负向：伪造的 question id 必须拒绝。
    func testQuestionsOutcomeRejectsUnknownQuestion() {
        let questions = questionPayload().questions ?? []
        XCTAssertThrowsError(try HarnessInteractionAnswer.questionsOutcome(
            answers: ["q-forged": ["A"]], questions: questions
        )) { error in
            XCTAssertEqual(error as? HarnessInteractionAnswerError, .unknownQuestionID("q-forged"))
        }
    }

    /// 负向：一个都没选必须拒绝（空 answers 会被当成"用户什么都没选"，与"没回答"不同）。
    func testQuestionsOutcomeRejectsEmptyAnswers() {
        let questions = questionPayload().questions ?? []
        XCTAssertThrowsError(try HarnessInteractionAnswer.questionsOutcome(
            answers: [:], questions: questions
        )) { error in
            XCTAssertEqual(error as? HarnessInteractionAnswerError, .emptyAnswers)
        }
    }

    /// 负向：未选择的问题不进 answers（那与"选了空"是两件事）。
    func testUnansweredQuestionIsOmittedNotSentEmpty() throws {
        let payload = HarnessWaterfallPayload(
            toolName: nil, callId: nil, reason: nil,
            questions: [
                HarnessQuestion(id: "q1", question: "一", options: [
                    HarnessQuestionOption(label: "A"),
                ]),
                HarnessQuestion(id: "q2", question: "二", options: [
                    HarnessQuestionOption(label: "B"),
                ]),
            ]
        )
        let outcome = try HarnessInteractionAnswer.questionsOutcome(
            answers: ["q1": ["A"], "q2": []], questions: payload.questions ?? []
        )
        guard case .result(let value) = outcome,
              let answers = value["answers"]?.arrayValue else {
            XCTFail("必须产出 answers 数组")
            return
        }
        XCTAssertEqual(answers.count, 1, "未回答的问题不得进入 answers")
        XCTAssertEqual(answers[0]["id"]?.stringValue, "q1")
    }

    /// 负向：追问没有问题时拒绝（无法构造合法应答）。
    func testQuestionsOutcomeRequiresQuestions() {
        XCTAssertThrowsError(try HarnessInteractionAnswer.questionsOutcome(
            answers: ["q1": ["opt-a"]], questions: []
        )) { error in
            XCTAssertEqual(error as? HarnessInteractionAnswerError, .noQuestionsInRequest)
        }
    }

    /// 负向：认不出的交互类型不得当普通请求处理（投递一张答不了的卡更糟）。
    func testValidateRejectsUnsupportedEvent() {
        let waterfall = HarnessWaterfallRequest(
            type: "waterfall", eventId: "evt-1", event: "some/unknown-event",
            request: approvalPayload(), agentId: "s1"
        )
        XCTAssertEqual(
            HarnessInteractionAnswer.validate(waterfall: waterfall),
            .unsupportedWaterfallEvent("some/unknown-event")
        )
    }

    /// 负向：缺 eventId 的交互拒绝（没有它就无法回传，也无法去重）。
    func testValidateRejectsMissingEventID() {
        let waterfall = HarnessWaterfallRequest(
            type: "waterfall", eventId: nil, event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), agentId: "s1"
        )
        XCTAssertEqual(HarnessInteractionAnswer.validate(waterfall: waterfall), .missingEventID)
    }

    /// 负向：旧 sessionId/threadId 不能替缺失的 agentId 提供会话归属。
    func testValidateRejectsLegacySessionHintsWithoutAgentID() throws {
        let legacyShape: [String: Any] = [
            "type": "waterfall",
            "eventId": "evt-1",
            "event": HarnessWireWaterfallEvent.approvalRequest,
            "request": ["toolName": "write", "callId": "call-a"],
            "sessionId": "legacy-session",
            "threadId": "legacy-thread",
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyShape)
        let waterfall = try JSONDecoder().decode(HarnessWaterfallRequest.self, from: data)

        XCTAssertEqual(HarnessInteractionAnswer.validate(waterfall: waterfall), .missingAgentID)
    }

    /// 正向对照：非空 agentId 的合法审批请求必须通过校验。
    func testValidateAcceptsWellFormedApproval() {
        let waterfall = HarnessWaterfallRequest(
            type: "waterfall", eventId: "evt-1", event: HarnessWireWaterfallEvent.approvalRequest,
            request: approvalPayload(), agentId: "s1"
        )
        XCTAssertNil(HarnessInteractionAnswer.validate(waterfall: waterfall))
    }
}
