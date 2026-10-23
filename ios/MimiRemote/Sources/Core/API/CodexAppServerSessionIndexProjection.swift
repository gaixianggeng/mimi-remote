import Foundation

// 列表级实时状态（#683）：没有页面订阅（没有邮箱）的会话，事件只进缓冲区，等被选中时回放。
// 列表不能等到那时——终端里的 Claude 开始 / 结束处理、本 App 在别的页面发起的会话跑完，都要
// 立刻反映到行上。这里把会改变列表状态的事件折算成会话快照交给 sessionIndexObserver。
extension CodexAppServerSessionRuntime {
    func sessionID(from event: AgentEvent) -> SessionID? {
        switch event {
        case .session(let session):
            return session.id
        case .sessionRow(let row, _):
            return row.id
        case .sessionStatus(_, let metadata),
             .sessionContext(_, let metadata),
             .permissionProfileUpdated(_, let metadata),
             .collaborationModeUpdated(_, let metadata),
             .goalCleared(let metadata),
             .promptSuggestion(_, let metadata),
             .turnStarted(let metadata),
             .assistantDelta(_, let metadata),
             .messageCompleted(_, let metadata),
             .processItemCompleted(_, _, let metadata),
             .logDelta(_, let metadata),
             .diffUpdated(_, let metadata),
             .approvalRequest(_, let metadata),
             .approvalResolved(let metadata),
             .userInputRequest(_, let metadata),
             .userInputResolved(let metadata, _),
             .turnCompleted(let metadata),
             .warning(_, let metadata):
            return metadata.sessionID
        case .goalUpdated(let goal, let metadata):
            return metadata.sessionID ?? goal.threadID
        case .error(_, let metadata):
            return metadata.sessionID
        case .unknown:
            return nil
        }
    }

    func notifySessionIndex(for event: AgentEvent, sessionID: SessionID) {
        guard let observer = sessionIndexObserver else {
            return
        }
        switch event {
        case .session(let session):
            observer(session)
        default:
            break
        }
    }
}
