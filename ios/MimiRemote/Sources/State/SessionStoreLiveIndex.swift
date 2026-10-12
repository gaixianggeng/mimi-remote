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
        updateSession(incoming.id) { item in
            let previous = item
            item.status = incoming.status
            item.activeTurnID = incoming.activeTurnID
            item.canAcceptDirectInput = incoming.canAcceptDirectInput
            item.claudeOwner = incoming.claudeOwner
            if let updatedAt = incoming.updatedAt, updatedAt > (item.updatedAt ?? .distantPast) {
                item.updatedAt = updatedAt
            }
            didChange = item != previous
        }
        guard didChange else {
            return
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
