import Foundation

struct SessionHierarchyChild: Identifiable, Equatable {
    let relation: SessionContextSubagent
    let session: AgentSession

    var id: String { relation.id }
}

/// 只投影已经发现的直接子会话；不读取历史，也不把普通 fork 或相同目录当成父子关系。
enum SessionHierarchyPresentation {
    static func children(
        of parent: AgentSession,
        sessions: [AgentSession],
        context: SessionContextSnapshot?
    ) -> [SessionHierarchyChild] {
        let parentIDs = identifiers(for: parent)
        let provider = runtimeProvider(for: parent)
        // 原生 Harness 还没有子会话详情所需的 session(snapshot)；先保留其现有列表，
        // 避免暴露点击后必然失败的入口。Codex / Claude 复用既有子会话读取链路。
        guard provider != AppServerRuntimeBundle.nativeRuntimeProvider else { return [] }
        let candidates = sessions.filter {
            runtimeProvider(for: $0) == provider && $0.id != parent.id
        }
        var seen: Set<SessionID> = []
        var result: [SessionHierarchyChild] = []

        func append(_ relation: SessionContextSubagent, known: AgentSession?) {
            guard let id = nonEmpty(relation.id), id == relation.id,
                  !parentIDs.contains(id),
                  seen.insert(known?.id ?? id).inserted else { return }
            var relation = relation
            relation.parentThreadID = relation.parentThreadID ?? parent.resumeID ?? parent.id
            relation.sessionID = relation.sessionID ?? known?.appServerSessionID
            relation.nickname = nonEmpty(relation.nickname) ?? known?.agentNickname
            relation.role = nonEmpty(relation.role) ?? known?.agentRole
            // 展示关系不提升权限；详情仍需 parent/child 双方明确允许才能写入。
            if known?.canAcceptDirectInput == false || relation.canAcceptDirectInput == false {
                relation.canAcceptDirectInput = false
            } else {
                relation.canAcceptDirectInput = relation.canAcceptDirectInput ?? known?.canAcceptDirectInput
            }
            let title = known.map(SessionListPresentation.titleDisplayText)
                .flatMap(nonEmpty) ?? nonEmpty(relation.nickname) ?? nonEmpty(relation.role)
                ?? L10n.text("ui.sub_agent")
            let status = normalizedStatus(relation.status ?? known?.status)
            let display = AgentSession(
                id: known?.id ?? id,
                projectID: parent.projectID,
                project: parent.project,
                dir: known?.dir ?? parent.dir,
                title: title,
                status: status,
                source: parent.source,
                runtimeProvider: parent.runtimeProvider,
                resumeID: known?.resumeID ?? id,
                createdAt: known?.createdAt,
                updatedAt: known?.updatedAt,
                parentThreadID: relation.parentThreadID,
                isSubagent: true,
                canAcceptDirectInput: relation.canAcceptDirectInput
            )
            result.append(SessionHierarchyChild(relation: relation, session: display))
        }

        // 上下文中的 receiver 列表可早于 child 的列表索引到达，先保留其稳定顺序。
        for relation in (context ?? parent.context)?.subagents ?? [] {
            if let declaredParent = nonEmpty(relation.parentThreadID),
               !parentIDs.contains(declaredParent) { continue }
            let known = candidates.first { identifiers(for: $0).contains(relation.id) }
            if let declaredParent = known.flatMap({ nonEmpty($0.parentThreadID ?? $0.context?.parentThreadID) }),
               !parentIDs.contains(declaredParent) { continue }
            append(relation, known: known)
        }
        // 目录索引可能先发现 child；缺失父上下文时也应能显示，不能要求先打开父会话。
        for child in candidates {
            guard let parentID = nonEmpty(child.parentThreadID ?? child.context?.parentThreadID),
                  parentIDs.contains(parentID) else { continue }
            append(SessionContextSubagent(
                id: child.resumeID ?? child.id,
                parentThreadID: parentID,
                sessionID: child.appServerSessionID,
                nickname: child.agentNickname,
                role: child.agentRole,
                status: child.status,
                canAcceptDirectInput: child.canAcceptDirectInput
            ), known: child)
        }
        return result
    }

    private static func identifiers(for session: AgentSession) -> Set<String> {
        Set([session.id, session.resumeID, session.context?.threadID].compactMap(nonEmpty))
    }

    private static func runtimeProvider(for session: AgentSession) -> String {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func normalizedStatus(_ status: String?) -> String {
        switch status?.lowercased() {
        case "active", "running", "inprogress", "in_progress", "started": return "running"
        case "complete", "completed", "success", "succeeded": return "completed"
        case "systemerror", "errored", "error", "failed": return "failed"
        case "waiting", "waiting_for_input": return "waiting_for_input"
        case "waiting_for_approval": return "waiting_for_approval"
        default: return "history"
        }
    }
}
