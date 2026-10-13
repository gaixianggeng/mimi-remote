import Foundation

/// `statusMessage` 的可见呈现：一条不打扰、会自动收起的操作反馈。
///
/// `statusMessage` 原本只是一段字符串，约 30 处写入口（转向、审批、goal、Git、提醒等）
/// 几乎没有地方展示，操作结果对用户是静默的（#508）。所有写入都经过 `setStatusMessage`，
/// 在那里统一生成这份反馈，由 Shell 顶部的浮层统一展示；失败反馈额外携带技术详情和重试入口。
struct OperationFeedback: Identifiable, Equatable {
    enum Kind: Equatable {
        case info
        case failure
    }

    struct Retry {
        let title: String
        let action: @MainActor () async -> Void
    }

    let id: UUID
    let kind: Kind
    let message: String
    let technicalDetail: String?
    let retry: Retry?

    init(
        id: UUID = UUID(),
        kind: Kind,
        message: String,
        technicalDetail: String? = nil,
        retry: Retry? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.technicalDetail = technicalDetail
        self.retry = retry
    }

    static func == (lhs: OperationFeedback, rhs: OperationFeedback) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.message == rhs.message
            && lhs.technicalDetail == rhs.technicalDetail
            && (lhs.retry == nil) == (rhs.retry == nil)
    }
}

/// 状态写入是否需要浮层提示。后台自愈、计数刷新这类「环境状态」已有横幅或页面本身表达，
/// 再弹提示只会打扰；它们仍然写入 `statusMessage`，只是不弹出。
enum StatusFeedbackPresentation: Equatable {
    case toast
    case silent
}

extension SessionStore {
    /// 由 `setStatusMessage` 调用：为新的状态文案生成可见反馈，或在状态被撤销时收起对应提示。
    func publishStatusFeedback(_ value: String?, presentation: StatusFeedbackPresentation) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            // 「正在停止当前回复」这类进行中提示完成后会被清空，浮层也要一起收起；
            // 失败提示保留到超时或用户关闭，不能被后续的清空静默吞掉。
            if operationFeedback?.kind == .info {
                operationFeedback = nil
            }
            return
        }
        guard presentation == .toast else {
            return
        }
        // 写入口拿到的可能是拼了原始错误的字符串，展示前统一过一遍翻译。
        let presented = UserFacingError(rawMessage: trimmed)
        if let current = operationFeedback,
           current.kind == .info,
           current.message == presented.message {
            // 同一条提示仍在显示，不重复弹出、不重置计时。
            return
        }
        operationFeedback = OperationFeedback(
            kind: .info,
            message: presented.message,
            technicalDetail: presented.technicalDetail
        )
    }

    /// 报告一次用户操作失败：状态文案改为用户能看懂的说明，并弹出带详情（和可选重试）的失败提示。
    ///
    /// 返回生成的反馈，调用方（例如重命名弹窗）可以就地展示，并据此收起重复的浮层。
    @discardableResult
    func reportOperationFailure(
        _ failure: UserFacingError,
        retry: OperationFeedback.Retry? = nil,
        presentation: StatusFeedbackPresentation = .toast
    ) -> OperationFeedback {
        let feedback = OperationFeedback(
            kind: .failure,
            message: failure.message,
            technicalDetail: failure.technicalDetail,
            retry: retry
        )
        if presentation == .toast {
            operationFeedback = feedback
        }
        if statusMessage != failure.message {
            statusMessage = failure.message
        }
        return feedback
    }

    /// `reportOperationFailure` 的便捷入口：把底层错误翻译成用户文案，再套上动作前缀。
    ///
    /// `format` 只负责前缀（如「重命名失败：%@」），原始错误描述会进入技术详情。
    @discardableResult
    func reportOperationFailure(
        _ error: Error,
        retry: OperationFeedback.Retry? = nil,
        presentation: StatusFeedbackPresentation = .toast,
        format: (String) -> String
    ) -> OperationFeedback {
        let failure = UserFacingError(error)
        return reportOperationFailure(
            failure.withMessage(format(failure.message)),
            retry: retry,
            presentation: presentation
        )
    }

    /// 写入共享错误通道的同时保留结构化分类。`errorMessage` 继续保存原始描述，
    /// writer 冲突、额度识别等逻辑仍依赖它；界面只读 `errorPresentation`。
    func setErrorMessage(
        for error: Error,
        origin: SessionErrorOrigin = .userAction,
        sessionID: SessionID? = nil,
        format: (String) -> String = { $0 }
    ) {
        let failure = UserFacingError(error)
        setErrorMessage(
            format(error.localizedDescription),
            origin: origin,
            sessionID: sessionID,
            presentation: failure.withMessage(format(failure.message))
        )
    }

    /// 由 `setErrorMessage` 调用，计算与 `errorMessage` 配套的用户文案。
    func resolvedErrorPresentation(
        for value: String?,
        isActiveWriterConflict: Bool,
        explicit: UserFacingError?
    ) -> UserFacingError? {
        guard let value else {
            return nil
        }
        if isActiveWriterConflict {
            return .described(value)
        }
        return explicit ?? UserFacingError(rawMessage: value)
    }

    /// 给只能展示一行文字的页面（空态、表单）使用的错误文案：优先翻译后的结论。
    var userFacingErrorMessage: String? {
        errorPresentation?.message ?? errorMessage
    }

    func dismissOperationFeedback(id: OperationFeedback.ID? = nil) {
        guard let current = operationFeedback else {
            return
        }
        if let id, current.id != id {
            return
        }
        operationFeedback = nil
    }

    func retryOperationFeedback(_ feedback: OperationFeedback) async {
        guard let retry = feedback.retry else {
            return
        }
        dismissOperationFeedback(id: feedback.id)
        await retry.action()
    }

    /// 错误横幅上的「重新连接」：沿用页面已有的刷新入口，会重新拉取当前会话并恢复连接。
    func retryAfterErrorPresentation() async {
        dismissErrorMessage()
        await refreshCurrentContext()
    }
}
