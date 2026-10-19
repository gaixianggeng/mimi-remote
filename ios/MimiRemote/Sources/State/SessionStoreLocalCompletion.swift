import Foundation

/// 本机观察到一次完成时留下的凭据（#805）。
///
/// 列表刷新、thread/read 等快照可能落后于实时 turn/completed，本地完成标记负责挡住这些陈旧的
/// running 快照。但同一会话随后在电脑端（共享运行时的 Codex Desktop、终端里的 Claude）开始的
/// 新一轮也以 running 快照到达；只记会话 ID 时它同样被压回 completed，发送被当成空闲会话反复失败。
/// 因此另记已结束回合的 turn ID 与完成时的服务端 updatedAt，快照带来之后的状态时标记让位。
struct SessionLocalCompletionMark: Equatable {
    var completedTurnIDs: Set<TurnID> = []
    /// 完成时已知的服务端 updatedAt 高水位。只取服务端快照里的时间，不混入本机时钟。
    var updatedAt: Date?

    mutating func record(completedTurnIDs turnIDs: [TurnID?], updatedAt: Date?) {
        for turnID in turnIDs.compactMap(Self.normalizedTurnID) {
            completedTurnIDs.insert(turnID)
        }
        if let updatedAt, updatedAt > (self.updatedAt ?? .distantPast) {
            self.updatedAt = updatedAt
        }
    }

    /// running 快照是否晚于这次完成。
    ///
    /// Codex 的 thread/list 不带 turns，Claude 列表行只有最后一条对话时间，所以两类证据都要认：
    /// 更晚的 updatedAt，或时间不早于完成、且不是已结束回合的进行中 turn。
    func isSuperseded(by incoming: AgentSession) -> Bool {
        let incomingTurnID = Self.normalizedTurnID(incoming.activeTurnID)
        if let incomingTurnID, completedTurnIDs.contains(incomingTurnID) {
            // 已经看到结束的回合不会重新开始；同一 turn 的 running 快照只能是落后的。
            return false
        }
        if let incomingUpdatedAt = incoming.updatedAt, let updatedAt {
            if incomingUpdatedAt > updatedAt {
                return true
            }
            if incomingUpdatedAt < updatedAt {
                return false
            }
        }
        // 时间相同或无法比较时，只有已知完成回合之外的进行中 turn 才算新一轮的证据。
        return incomingTurnID != nil && !completedTurnIDs.isEmpty
    }

    private static func normalizedTurnID(_ value: TurnID?) -> TurnID? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }
}

extension SessionStore {
    /// `completedTurnIDs` 传刚结束的回合；调用时 Store 里通常还留着它的 activeTurnID。
    func markSessionLocallyCompleted(
        _ sessionID: SessionID,
        completedTurnIDs: [TurnID?],
        updatedAt: Date?
    ) {
        locallyCompletedSessionIDs.insert(sessionID)
        locallyCompletedSessionMarks[sessionID, default: SessionLocalCompletionMark()]
            .record(completedTurnIDs: completedTurnIDs, updatedAt: updatedAt)
    }

    func clearLocalCompletionMark(_ sessionID: SessionID) {
        locallyCompletedSessionIDs.remove(sessionID)
        locallyCompletedSessionMarks.removeValue(forKey: sessionID)
    }

    /// turn/completed 归并出的 `.clear` 带着刚结束的 turn ID。
    static func clearedTurnID(in output: EventReducerOutput, sessionID: SessionID) -> TurnID? {
        for mutation in output.activeTurnMutations {
            if case .clear(let id, let turnID) = mutation, id == sessionID, let turnID {
                return turnID
            }
        }
        return nil
    }

    func sessionPreservingLocalCompletedStatus(_ incoming: AgentSession) -> AgentSession {
        var next = incoming
        if next.status == SessionStatus.completed.rawValue {
            // 运行时随 turn/completed 发出的终态快照：Store 里此时仍是刚结束那一轮的 activeTurnID，
            // updatedAt 取的是回合完成时间。
            markSessionLocallyCompleted(
                next.id,
                completedTurnIDs: [sessionsByID[next.id]?.activeTurnID, next.activeTurnID],
                updatedAt: next.updatedAt
            )
            return next
        }
        guard Self.isRunningStatus(next.status),
              locallyCompletedSessionIDs.contains(next.id)
        else {
            return next
        }
        if locallyCompletedSessionMarks[next.id]?.isSuperseded(by: next) == true {
            // 电脑端已经开始新一轮：快照比本地完成更新，如实显示进行中，发送随之进入排队。
            clearLocalCompletionMark(next.id)
            return next
        }
        // 列表刷新可能落后于实时 turn/completed；这时不要让旧 running 快照把 UI 拉回运行态。
        next.status = SessionStatus.completed.rawValue
        next.activeTurnID = nil
        next.pendingApproval = nil
        next.pendingUserInput = nil
        return next
    }
}
