import Foundation

// 列表级实时状态（#683）。运行时只给被页面订阅的会话开邮箱；其余会话的状态推送——终端里的
// Claude 开始 / 结束处理、持有方退出、本 App 在别的页面发起的会话跑完——过去只进缓冲区，
// 列表要等下一次刷新才变。这里把这类推送直接并入 Store 里已有的行：只动状态与归属，
// 不碰标题、摘要和分页成员。
extension SessionStore {
    func installSessionIndexObserver() {
        appStore.sessionIndexObserver = { [weak self] session in
            self?.applyLiveSessionIndexUpdate(session)
        }
    }

    /// 只更新 Store 里已经存在的行；新会话仍由列表刷新带入，避免别的工作区的会话被插到当前列表头部。
    /// 当前有前台连接的会话由事件链路负责，这里不重复写。
    func applyLiveSessionIndexUpdate(_ incoming: AgentSession) {
        guard sessionsByID[incoming.id] != nil, connectedSessionID != incoming.id else {
            return
        }
        var didChange = false
        var clearedApproval = false
        var clearedUserInput = false
        updateSession(incoming.id) { item in
            let previous = item
            item.status = incoming.status
            item.activeTurnID = incoming.activeTurnID
            item.canAcceptDirectInput = incoming.canAcceptDirectInput
            item.claudeOwner = incoming.claudeOwner
            // 待处理的审批 / 补充输入也以快照为准：别的客户端答复后会话转为运行或空闲，
            // 这里不清掉旧请求，列表就会一直把它归在「待你处理」。仍在等待但快照没带载荷
            // （列表快照不含请求正文）时保留已有的可操作请求。
            let waitsForApproval = incoming.status == SessionStatus.waitingForApproval.rawValue
            item.pendingApproval = waitsForApproval ? (incoming.pendingApproval ?? item.pendingApproval) : nil
            let waitsForInput = incoming.status == SessionStatus.waitingForInput.rawValue
            item.pendingUserInput = waitsForInput ? (incoming.pendingUserInput ?? item.pendingUserInput) : nil
            if let updatedAt = incoming.updatedAt, updatedAt > (item.updatedAt ?? .distantPast) {
                item.updatedAt = updatedAt
            }
            clearedApproval = previous.pendingApproval != nil && item.pendingApproval == nil
            clearedUserInput = previous.pendingUserInput != nil && item.pendingUserInput == nil
            didChange = item != previous
        }
        guard didChange else {
            return
        }
        if clearedApproval {
            clearPendingApprovalDecisions(sessionID: incoming.id)
        }
        if clearedUserInput {
            clearPendingUserInputResponses(sessionID: incoming.id)
        }
        if incoming.status == SessionStatus.completed.rawValue {
            locallyCompletedSessionIDs.insert(incoming.id)
        } else if Self.isRunningStatus(incoming.status) {
            locallyCompletedSessionIDs.remove(incoming.id)
        }
        if !Self.isRunningStatus(incoming.status) {
            clearRuntimeActivity(sessionID: incoming.id)
        }
        contextStore.updateStatus(sessionID: incoming.id, status: incoming.status)
        // 运行 → 空闲在这里被观察到，才会按既有规则产生未读与"刚完成"。
        synchronizeHistoryReadStates()
    }
}
