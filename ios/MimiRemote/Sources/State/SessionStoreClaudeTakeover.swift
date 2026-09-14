import Foundation

/// 某台主机的 Claude channel 是否声明 thread/takeover。按主机缓存，切换主机后自然失效。
struct ClaudeTakeoverSupport: Equatable {
    let scope: HostScope
    let supported: Bool
}

// #451：Claude 会话被 Mac 上的终端 / Claude 桌面持有时，从这台设备硬接管：bridge 结束
// Mac 侧进程后同 id 续聊。这里只负责发起请求、放开输入和走既有 takenOver 控制态。
extension SessionStore {
    /// 冲突卡会整块替换输入框。Claude 被 Mac 持有时，持有方说明和接管入口都在输入框托盘里，
    /// 冲突卡的分叉对只读会话又不可用，所以持有态优先保留输入框。
    var selectedSessionShowsWriterConflictCard: Bool {
        selectedSessionHasActiveWriterConflict && selectedOwnershipNotice == nil
    }

    func refreshClaudeTakeoverSupportIfNeeded(sessionID: SessionID) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return
        }
        await refreshClaudeTakeoverSupportIfNeeded(for: session)
    }

    /// 探测一次当前主机是否支持接管。老 agentd / 旧 bridge 不声明该方法时按钮不出现。
    /// 只缓存明确的探测结果；请求本身失败（弱网、配置未就绪）不能被当成"不支持"钉死，
    /// 下一次提示条出现时会再探。
    func refreshClaudeTakeoverSupportIfNeeded(for session: AgentSession) async {
        guard claudeTakeoverSupport?.scope != appStore.activeHostScope else {
            return
        }
        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            return
        }
        do {
            let supported = try await lease.client.sessionSupportsThreadTakeover(sessionID: session.id)
            try requireCurrentProjectsGitHost(lease)
            claudeTakeoverSupport = ClaudeTakeoverSupport(scope: lease.scope, supported: supported)
        } catch {
            return
        }
    }

    /// bridge 明确拒绝过（不可重试）的持有方不再提供按钮：holder_respawned 时宿主会一直
    /// 重启新进程，反复接管就是一个由用户点击驱动的杀进程循环。持有方换成别的 pid
    /// （用户在 Mac 上关掉后重新打开）时自然解除。
    func claudeTakeoverIsBlocked(for session: AgentSession) -> Bool {
        guard let blocked = claudeTakeoverBlockedHolderPIDs[session.id], !blocked.isEmpty else {
            return false
        }
        guard let pid = session.claudeOwner?.pid else {
            // 持有方身份未知时保守禁用，宁可让用户去 Mac 上处理。
            return true
        }
        return blocked.contains(pid)
    }

    @discardableResult
    func takeOverHeldClaudeSession(sessionID: SessionID) async -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return false
        }
        return await takeOverHeldClaudeSession(session)
    }

    /// 结束 Mac 上持有该会话的 claude 进程，然后在这里继续。成功后先在本地放开输入，
    /// 再走既有 takenOver 控制态并重连；随后的 thread/resume 会带回权威状态。
    @discardableResult
    func takeOverHeldClaudeSession(_ session: AgentSession) async -> Bool {
        guard session.claudeOwner != nil, session.canAcceptDirectInput == false else {
            // 持有方已经自己退出：普通接管即可，不必再让 bridge 去找进程。
            takeOverSession(session)
            return true
        }
        guard claudeTakeoverInFlightSessionID == nil, !claudeTakeoverIsBlocked(for: session) else {
            return false
        }
        claudeTakeoverInFlightSessionID = session.id
        defer { claudeTakeoverInFlightSessionID = nil }

        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            setStatusMessage(L10n.format("ui.take_over_failed_value", error.localizedDescription))
            return false
        }
        do {
            let result = try await lease.client.takeOverThread(threadID: session.id)
            try requireCurrentProjectsGitHost(lease)
            claudeTakeoverBlockedHolderPIDs[session.id] = nil
            updateSession(session.id) { current in
                current.canAcceptDirectInput = result.canAcceptDirectInput ?? true
                current.claudeOwner = nil
            }
            setSessionControlState(.takenOver, sessionID: session.id)
            if session.id == selectedSessionID,
               let refreshed = sessions.first(where: { $0.id == session.id }) {
                // 被持有的会话在这里不是 running 态，必须显式允许非运行会话建立订阅。
                connectWebSocket(refreshed, replayBufferedEvents: false, allowNonRunning: true)
            }
            setStatusMessage(L10n.text("ui.taken_over_to_ipad"))
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard (try? requireCurrentProjectsGitHost(lease)) != nil else {
                return false
            }
            if let failure = CodexAppServerThreadTakeoverResult.failure(from: error), !failure.retryable {
                recordClaudeTakeoverRefusal(session: session, failure: failure)
            }
            setStatusMessage(claudeTakeoverFailureMessage(error))
            return false
        }
    }

    private func recordClaudeTakeoverRefusal(session: AgentSession, failure: CodexAppServerThreadTakeoverFailure) {
        var blocked = claudeTakeoverBlockedHolderPIDs[session.id] ?? []
        // 同时记住提示条上现在显示的持有方和 bridge 指认的那个：holder_respawned 时后者是
        // 新认领者，刷新前提示条还显示旧 pid，两个都不能再点。
        if let pid = session.claudeOwner?.pid {
            blocked.insert(pid)
        }
        if let pid = failure.holderPID {
            blocked.insert(pid)
        }
        if blocked.isEmpty {
            // 双方都没给 pid：只能按会话整体禁用，直到持有方换成一个可辨认的新 pid。
            blocked.insert(-1)
        }
        claudeTakeoverBlockedHolderPIDs[session.id] = blocked
    }

    /// bridge 的结构化失败原因映射成可操作的提示；其余错误保留原文。
    func claudeTakeoverFailureMessage(_ error: Error) -> String {
        if let failure = CodexAppServerThreadTakeoverResult.failure(from: error) {
            switch failure.reason {
            case "holder_respawned":
                return L10n.text("ui.take_over_claude_failed_respawned")
            case "takeover_timeout":
                return L10n.text("ui.take_over_claude_failed_timeout")
            case "holder_unverified":
                return L10n.text("ui.take_over_claude_failed_unverified")
            case "signal_failed":
                // 多个持有方时 bridge 按顺序发信号，前面的可能已经被中断；不能说"未做任何改动"。
                return L10n.text("ui.take_over_claude_failed_signal")
            default:
                break
            }
        }
        return L10n.format("ui.take_over_failed_value", error.localizedDescription)
    }
}
