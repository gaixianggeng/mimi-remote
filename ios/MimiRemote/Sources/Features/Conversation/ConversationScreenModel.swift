import Foundation

struct ConversationScreenModel: Equatable {
    let sessionID: SessionID?
    let title: String
    let subtitle: String
    let foregroundActivity: SessionForegroundActivity?
    let runtimeActivitySnapshot: RuntimeActivitySnapshot?
    let historySavingsNotice: HistorySavingsNotice?
    let quotaNotice: CodexQuotaNotice?
    let webSocketStatus: WebSocketStatus
    let statusDisplay: AgentSessionDisplayStatus?
    let errorMessage: String?
    /// `errorMessage` 的用户文案；顶部横幅只展示这一份，原始描述进详情（#508）。
    let errorPresentation: UserFacingError?

    init(
        selectedSession: AgentSession?,
        selectedProject: AgentProject?,
        foregroundActivity: SessionForegroundActivity?,
        runtimeActivitySnapshot: RuntimeActivitySnapshot?,
        historySavingsNotice: HistorySavingsNotice?,
        quotaNotice: CodexQuotaNotice?,
        webSocketStatus: WebSocketStatus,
        errorMessage: String?,
        errorPresentation: UserFacingError? = nil
    ) {
        self.sessionID = selectedSession?.id
        self.title = selectedSession?.title ?? selectedProject?.name ?? L10n.text("ui.session")
        self.subtitle = selectedSession?.dir ?? selectedProject?.path ?? ""
        self.foregroundActivity = foregroundActivity
        self.runtimeActivitySnapshot = runtimeActivitySnapshot
        self.historySavingsNotice = historySavingsNotice
        self.quotaNotice = quotaNotice
        self.webSocketStatus = webSocketStatus
        self.statusDisplay = Self.visibleStatusDisplay(for: selectedSession, foregroundActivity: foregroundActivity)
        let trimmedError = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let coveredByQuotaNotice = quotaNotice != nil && trimmedError.map(CodexQuotaNotice.isQuotaError) == true
        // 历史加载失败的状态条已经写明原因并带重试，不再并排显示同一次失败的错误条（#718）。
        let coveredByHistoryNotice = trimmedError != nil
            && historySavingsNotice?.coveredErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedError
        self.errorMessage = coveredByQuotaNotice || coveredByHistoryNotice ? nil : errorMessage
        // 额度判断仍看原始描述；被额度横幅接管时，翻译后的文案也一起隐藏。
        if let visibleError = self.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !visibleError.isEmpty {
            self.errorPresentation = errorPresentation ?? UserFacingError(rawMessage: visibleError)
        } else {
            self.errorPresentation = nil
        }
    }

    private static func visibleStatusDisplay(
        for session: AgentSession?,
        foregroundActivity: SessionForegroundActivity?
    ) -> AgentSessionDisplayStatus? {
        guard let session else {
            return nil
        }
        guard session.isRunning ||
            foregroundActivity != nil ||
            session.pendingApproval != nil ||
            session.status == SessionStatus.failed.rawValue ||
            session.status == SessionStatus.waitingForInput.rawValue ||
            session.status == SessionStatus.waitingForApproval.rawValue
        else {
            return nil
        }
        return session.displayStatus(foregroundActivity: foregroundActivity)
    }
}
