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

    init(
        selectedSession: AgentSession?,
        selectedProject: AgentProject?,
        foregroundActivity: SessionForegroundActivity?,
        runtimeActivitySnapshot: RuntimeActivitySnapshot?,
        historySavingsNotice: HistorySavingsNotice?,
        quotaNotice: CodexQuotaNotice?,
        webSocketStatus: WebSocketStatus,
        errorMessage: String?
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
        self.errorMessage = quotaNotice != nil && trimmedError.map(CodexQuotaNotice.isQuotaError) == true ? nil : errorMessage
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
