import Foundation

// 列表级实时状态（#683）：没有页面订阅（没有邮箱）的会话，事件只进缓冲区，等被选中时回放。
// 列表不能等到那时——终端里的 Claude 开始 / 结束处理、本 App 在别的页面发起的会话跑完，都要
// 立刻反映到行上。这里把会改变列表状态的事件折算成会话快照交给 sessionIndexObserver。
extension CodexAppServerSessionRuntime {
    func notifySessionIndex(for event: AgentEvent, sessionID: SessionID) {
        guard let observer = sessionIndexObserver else {
            return
        }
        switch event {
        case .session(let session):
            observer(session)
        case .turnCompleted(let metadata):
            // turn/completed 投影出的会话快照有意保留 running（终态由随后的 .turnCompleted 交给 Store
            // 的事件归并）。列表观察者只接快照，这里按 Store 同一规则补一份终态快照，否则行会停在运行中。
            if let snapshot = terminalIndexSnapshot(for: metadata, sessionID: sessionID) {
                observer(snapshot)
            }
        default:
            break
        }
    }

    /// 与 EventReducer 对 .turnCompleted 的归并一致：失败记 failed，其余（完成、中断）记 completed；
    /// 清掉进行中 turn 与待处理请求。缓存里已经是另一轮新 turn 时不覆盖。
    func terminalIndexSnapshot(for metadata: AgentEventMetadata, sessionID: SessionID) -> AgentSession? {
        let id = metadata.sessionID ?? sessionID
        guard var session = contextsBySessionID[id]?.session else {
            return nil
        }
        if let activeTurnID = session.activeTurnID,
           let completedTurnID = metadata.turnID,
           activeTurnID != completedTurnID {
            return nil
        }
        let lifecycle = metadata.turnLifecycle ?? .completed
        session.status = lifecycle == .failed ? SessionStatus.failed.rawValue : SessionStatus.completed.rawValue
        session.activeTurnID = nil
        session.pendingApproval = nil
        session.pendingUserInput = nil
        let completedAt = metadata.createdAt ?? Date()
        if completedAt > (session.updatedAt ?? .distantPast) {
            session.updatedAt = completedAt
        }
        return session
    }
}
