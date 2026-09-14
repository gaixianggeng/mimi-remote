import Foundation

/// 用户点击提交时的不可变目标。selectionLease 只决定异步完成后能否更新前台，
/// session/project 则持续作为本次已接受发送的目标，避免返回列表后被当前选择改写。
struct TurnSubmissionContext {
    let hostScope: HostScope
    let selectionLease: SessionSelectionLease
    let projectID: String?
    let session: AgentSession?
}

extension SessionStore {
    func captureTurnSubmissionContext() -> TurnSubmissionContext {
        TurnSubmissionContext(
            hostScope: appStore.activeHostScope,
            selectionLease: currentSelectionLease(),
            projectID: selectedSession?.projectID ?? selectedProjectID,
            session: selectedSession
        )
    }

    func isSubmissionHostCurrent(_ context: TurnSubmissionContext) -> Bool {
        appStore.activeHostScope == context.hostScope
    }

    func runtimeProviderForTurn(session: AgentSession?) -> String? {
        guard let session else {
            return nil
        }
        if session.source == "local", session.runtimeProvider == nil {
            return nil
        }
        return Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
    }
}
