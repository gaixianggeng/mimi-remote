import Foundation

/// 交互应答的构造与校验。
///
/// ## 为什么一切 fail closed
///
/// `$events/result` 的帧形状是**源码级**（`rpc/events-result.json` 的 `liveCaptureGap`
/// 明写本次实跑没有触发审批）。Gate A 对此的决定是：按源码形状实现，但
/// **任何依赖它的代码都必须有"形状不符即拒绝"的路径，不得静默降级**。
///
/// 所以这里的每一处校验都遵守两条：
/// 1. 取值域逐字取自冻结夹具，不按名字猜、不自行扩充。
/// 2. 认不出就拒绝并给出可诊断原因——不构造一个"看起来像"的应答。
///
/// ## 不伪造能力
///
/// 契约 D5：只展示上游支持的回答。不得生成"永久允许""整个会话允许"而实际发送
/// 一次性结果——那会让用户以为授权范围更大。因此这里只接受上游真实提供的取值，
/// 且不把"关闭弹窗"当成一种应答。
enum HarnessInteractionAnswer {

    // MARK: - 审批

    /// 审批的合法取值域，逐字取自 `events-result.json` 的 `approvalValueDomain`。
    ///
    /// 注意 `cancelled` 与 `unavailable` 也在域内：它们是上游会接受的结论
    /// （用户取消、条件不可满足），不是客户端可以自行发明的。
    static let approvalValueDomain: Set<String> = [
        "allowed-once", "rejected", "cancelled", "unavailable",
    ]

    /// 本端**主动**向用户提供的审批结论。
    ///
    /// 只给两个：允许一次、拒绝。`cancelled` 是"用户关掉了卡片"这类交互结果，
    /// `unavailable` 是"条件无法满足"——两者都不是用户在这个按钮组里做的决定，
    /// 而是系统状态。把它们做成按钮会让用户以为自己在做授权决定。
    /// 它们仍在 `approvalValueDomain` 里，因为**上游可能返回**它们（我们要能解析）。
    static let userSelectableApprovalValues: [String] = ["allowed-once", "rejected"]

    /// 构造一次审批应答。
    static func approvalOutcome(decision: String) throws -> HarnessOutcome {
        let value = decision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard approvalValueDomain.contains(value) else {
            throw HarnessInteractionAnswerError.unsupportedDecision(value)
        }
        return .result(.string(value))
    }

    // MARK: - 选择题

    /// 构造一次选择题应答。
    ///
    /// 形状取自冻结夹具：`{"answers":[{"id":<questionId>,"selected":[<optionId>...]}]}`。
    ///
    /// 三条克制：
    /// - 只接受**真实存在**的 question id 与 option id（用请求里带的问题单校验），
    ///   不凭调用方自报。发一个上游不认识的 option id 等于伪造了一个选项。
    /// - 未选择任何项的问题**不进入 answers**：发一个空 selected 会被上游当成
    ///   "用户选了空"，与"用户没回答这一题"是两件事。
    /// - 不构造自由输入：Harness 首版的问题只带 options，没有自由文本字段。
    static func questionsOutcome(
        answers: [String: [String]],
        questions: [HarnessQuestion]
    ) throws -> HarnessOutcome {
        guard !questions.isEmpty else {
            throw HarnessInteractionAnswerError.noQuestionsInRequest
        }
        // 请求里真实存在的问题与选项，作为校验依据。
        var allowedOptions: [String: Set<String>] = [:]
        for question in questions {
            guard let id = question.id?.trimmedNonEmpty else {
                throw HarnessInteractionAnswerError.questionMissingID
            }
            var options: Set<String> = []
            for option in question.options ?? [] {
                guard let optionID = option.id?.trimmedNonEmpty else {
                    throw HarnessInteractionAnswerError.optionMissingID(questionID: id)
                }
                options.insert(optionID)
            }
            allowedOptions[id] = options
        }

        var encoded: [HarnessJSONValue] = []
        for (questionID, selected) in answers.sorted(by: { $0.key < $1.key }) {
            guard let allowed = allowedOptions[questionID] else {
                // 问题 id 不在本次请求里：拒绝而不是发一个上游不认识的 id。
                throw HarnessInteractionAnswerError.unknownQuestionID(questionID)
            }
            let picked = selected.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !picked.isEmpty else { continue }
            for optionID in picked where !allowed.contains(optionID) {
                throw HarnessInteractionAnswerError.unknownOptionID(
                    questionID: questionID, optionID: optionID
                )
            }
            encoded.append(.object([
                "id": .string(questionID),
                "selected": .array(picked.map { .string($0) }),
            ]))
        }

        guard !encoded.isEmpty else {
            // 一道题都没答：这不是一次有效应答。发空 answers 会被上游当成"用户什么都没选"。
            throw HarnessInteractionAnswerError.emptyAnswers
        }
        return .result(.object(["answers": .array(encoded)]))
    }

    // MARK: - 上游形状校验

    /// 校验一条 waterfall 请求是否可被本端应答。
    ///
    /// 返回 nil 表示可应答；否则给出拒绝原因。调用方据此**不投递**这张卡——
    /// 投递一张答不了的卡比不投递更糟：用户会对着它做决定，而那个决定无法回传。
    static func validate(waterfall: HarnessWaterfallRequest) -> HarnessInteractionAnswerError? {
        guard let event = waterfall.event, HarnessWireWaterfallEvent.isSupported(event) else {
            return .unsupportedWaterfallEvent(waterfall.event)
        }
        guard let eventID = waterfall.eventId?.trimmedNonEmpty else {
            return .missingEventID
        }
        _ = eventID
        guard let request = waterfall.request else {
            return .missingRequestPayload
        }
        if event == HarnessWireWaterfallEvent.userQuestions {
            guard let questions = request.questions, !questions.isEmpty else {
                // 没有问题的追问无法构造合法应答。
                return .noQuestionsInRequest
            }
        }
        return nil
    }
}

/// 应答构造失败的原因。每一种都必须显式拒绝，不降级成"随便发一个"。
enum HarnessInteractionAnswerError: Error, Equatable {
    case unsupportedDecision(String)
    case unsupportedWaterfallEvent(String?)
    case missingEventID
    case missingRequestPayload
    case noQuestionsInRequest
    case questionMissingID
    case optionMissingID(questionID: String)
    case unknownQuestionID(String)
    case unknownOptionID(questionID: String, optionID: String)
    case emptyAnswers

    var localizedMessage: String {
        switch self {
        case .unsupportedDecision(let value):
            return "不支持的回答：\(value)"
        case .unsupportedWaterfallEvent(let event):
            return "无法应答的交互类型：\(event ?? "未知")"
        case .missingEventID:
            return "交互缺少 eventId，无法回传"
        case .missingRequestPayload:
            return "交互缺少请求内容"
        case .noQuestionsInRequest:
            return "追问没有携带任何问题"
        case .questionMissingID:
            return "问题缺少 id"
        case .optionMissingID(let questionID):
            return "问题 \(questionID) 的选项缺少 id"
        case .unknownQuestionID(let id):
            return "问题 \(id) 不在本次请求中"
        case .unknownOptionID(let questionID, let optionID):
            return "选项 \(optionID) 不属于问题 \(questionID)"
        case .emptyAnswers:
            return "没有选择任何回答"
        }
    }
}
