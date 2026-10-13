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
        default:
            break
        }
    }
}
