import Foundation

struct SessionIndexStore {
    /// `runtimeProvider` 非空时只替换该 Runtime 的旧成员：工作区首屏按 Runtime 分别请求，
    /// Codex 首屏不能把同工作区的 Claude 会话当成已消失删掉（#721），反之亦然。
    static func replacingSessions(
        _ current: [AgentSession],
        with fresh: [AgentSession],
        projectID: String?,
        runtimeProvider: String? = nil
    ) -> [AgentSession] {
        let scopedFresh: [AgentSession]
        if let projectID {
            scopedFresh = fresh.filter { $0.projectID == projectID }
        } else {
            scopedFresh = fresh
        }

        var freshIDs: Set<SessionID> = []
        freshIDs.reserveCapacity(scopedFresh.count)
        for session in scopedFresh {
            freshIDs.insert(session.id)
        }

        let kept = current.filter { session in
            if freshIDs.contains(session.id) {
                return false
            }
            guard let projectID else {
                return false
            }
            guard session.projectID == projectID else {
                return true
            }
            return !isSession(session, inRuntime: runtimeProvider)
        }
        return scopedFresh + kept
    }

    /// 首屏按 Runtime 分别请求；替换与缺失计数都只能作用于本页 Runtime 的会话。nil 表示不限 Runtime。
    static func isSession(_ session: AgentSession, inRuntime runtimeProvider: String?) -> Bool {
        guard let runtimeProvider else { return true }
        return CodexAppServerSessionRuntime.normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
            == CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
    }

    static func sortedSessions(_ items: [AgentSession]) -> [AgentSession] {
        items.sorted { lhs, rhs in
            let left = orderingDate(for: lhs)
            let right = orderingDate(for: rhs)
            if left == right {
                // Codex 的 recency_at cursor 仍以 id 打破同秒并列；全端保持同一个稳定全序。
                return lhs.id > rhs.id
            }
            return left > right
        }
    }

    static func orderingDate(for session: AgentSession) -> Date {
        session.recencyAt ?? session.updatedAt ?? session.createdAt ?? .distantPast
    }
}
