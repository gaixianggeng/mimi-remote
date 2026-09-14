import Foundation

/// 页面可用阶段由发送、历史任务和当前会话订阅共同决定；未建立页面订阅不等于网络断开。
enum ConversationReadiness: Equatable {
    case sending
    case loadingHistory
    case connecting
    case live
    case observing
    case reconnecting
    case disconnected
    case failed
    case unavailable(ConnectionTerminationStatus)

    var isWarning: Bool {
        switch self {
        case .reconnecting, .disconnected, .failed, .unavailable:
            return true
        case .sending, .loadingHistory, .connecting, .live, .observing:
            return false
        }
    }

    var animates: Bool {
        switch self {
        case .sending, .loadingHistory, .connecting, .live:
            return true
        case .observing, .reconnecting, .disconnected, .failed, .unavailable:
            return false
        }
    }

    var title: String? {
        switch self {
        case .sending: return L10n.text("ui.sending")
        case .loadingHistory: return L10n.text("ui.live_status_restoring_history")
        case .connecting: return L10n.text("ui.connecting")
        case .live: return nil
        case .observing: return L10n.text("ui.read_only")
        case .reconnecting: return L10n.text("ui.live_status_reconnecting")
        case .disconnected: return L10n.text("ui.live_status_disconnected")
        case .failed: return L10n.text("ui.connection_failed")
        case .unavailable(let reason): return reason.title
        }
    }
}

extension SessionStore {
    func isLoadingEarlierHistory(sessionID: SessionID?) -> Bool {
        guard let sessionID else {
            return false
        }
        return loadingEarlierHistorySessionIDs.contains(sessionID)
    }

    func historyLoadProgress(sessionID: SessionID?) -> HistoryLoadProgress? {
        guard let sessionID else {
            return nil
        }
        return historyLoadProgressBySessionID[sessionID]
    }

    func conversationReadiness(for session: AgentSession) -> ConversationReadiness {
        // 确定的故障优先，不能被仍挂起的创建/历史请求伪装成正常加载。
        if let connectionTermination { return .unavailable(connectionTermination) }
        if appStore.requiresRePairing { return .unavailable(.credentialsInvalid) }
        if isNetworkUnavailable { return .disconnected }

        let ownsSocket = connectedSessionID == session.id && connectedHostScope == appStore.activeHostScope
        let ownsStatus = webSocketStatusLease == HostSessionLease(hostScope: appStore.activeHostScope, sessionID: session.id)
        if ownsStatus {
            switch webSocketStatus {
            case .failed: return .failed
            case .terminated(let reason): return .unavailable(reason)
            default: break
            }
        }
        if ownsStatus, webSocketReconnectAttemptBySessionID[session.id] != nil { return .reconnecting }
        if let lease = sessionCreationLoadingLease,
           lease.sessionID == session.id, isSelectionLeaseCurrent(lease) {
            return .sending
        }
        // 缓存先可读，首次历史补齐期间尚未订阅；加载更早的历史不改变实时运行状态。
        if historyLoadJobsBySessionID[session.id] != nil,
           !ownsSocket || webSocketStatus != .connected {
            return .loadingHistory
        }
        guard ownsStatus else {
            // 只读会话和侧边阅读区没有前台可写订阅，不能套用另一会话的 Socket 状态。
            return selectedSessionID == session.id && canControlSession(session) ? .connecting : .observing
        }
        switch webSocketStatus {
        case .connected: return .live
        case .connecting: return webSocketReconnectTask == nil ? .connecting : .reconnecting
        case .disconnected: return .disconnected
        case .failed: return .failed
        case .terminated(let reason): return .unavailable(reason)
        }
    }
}
