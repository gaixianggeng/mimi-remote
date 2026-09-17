import Foundation

/// 某台主机的 Claude channel 是否声明 thread/takeover。按主机缓存，切换主机后自然失效。
struct ClaudeTakeoverSupport: Equatable {
    let scope: HostScope
    let supported: Bool
}

/// 失败原因和禁用条件一起保留，返回会话后仍能解释为什么不能接管。
struct ClaudeTakeoverFailureNotice {
    let scope: HostScope
    let holderPIDs: Set<Int>
    let message: String
    let blocksRetry: Bool
    let waitsForIdle: Bool
}

// #451：Claude 会话被 Mac 上的终端 / Claude 桌面持有时，等当前轮完成后从这台设备接管：bridge 结束
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
        claudeTakeoverFailure(for: session)?.blocksRetry == true
    }

    func claudeTakeoverFailure(for session: AgentSession) -> ClaudeTakeoverFailureNotice? {
        guard let failure = claudeTakeoverFailures[session.id],
              failure.scope == appStore.activeHostScope else {
            return nil
        }
        if failure.waitsForIdle, session.claudeOwner?.status == "idle" { return nil }
        if let pid = session.claudeOwner?.pid, !failure.holderPIDs.contains(pid) {
            return nil
        }
        return failure
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
        guard session.claudeOwner?.status == "idle",
              claudeTakeoverInFlightSessionID == nil, !claudeTakeoverIsBlocked(for: session) else {
            return false
        }
        claudeTakeoverInFlightSessionID = session.id
        defer { claudeTakeoverInFlightSessionID = nil }

        let scope = appStore.activeHostScope
        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            recordClaudeTakeoverFailure(error, session: session, scope: scope)
            return false
        }
        do {
            // 旧主机只支持强制中断式接管，不能让过期确认框或直接调用绕过能力门禁。
            guard try await lease.client.sessionSupportsThreadTakeover(sessionID: session.id) else {
                try requireCurrentProjectsGitHost(lease)
                recordClaudeTakeoverFailure(AgentAPIError.invalidResponse, session: session, scope: lease.scope,
                                           message: L10n.text("ui.take_over_claude_upgrade_required"))
                return false
            }
            try requireCurrentProjectsGitHost(lease)
            let result = try await lease.client.takeOverThread(threadID: session.id)
            try requireCurrentProjectsGitHost(lease)
            claudeTakeoverFailures[session.id] = nil
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
            recordClaudeTakeoverFailure(error, session: session, scope: lease.scope)
            return false
        }
    }

    private func recordClaudeTakeoverFailure(_ error: Error, session: AgentSession, scope: HostScope, message: String? = nil) {
        let failure = CodexAppServerThreadTakeoverResult.failure(from: error)
        let message = message ?? claudeTakeoverFailureMessage(error)
        var holderPIDs: Set<Int> = []
        if let pid = session.claudeOwner?.pid { holderPIDs.insert(pid) }
        if let pid = failure?.holderPID { holderPIDs.insert(pid) }
        let waitsForIdle = failure?.reason == "holder_busy" || failure?.reason == "holder_state_unknown"
        if waitsForIdle, let owner = session.claudeOwner {
            // 服务端拒绝说明客户端的 idle 已过期；等待后续权威刷新重新报告 idle。
            updateSession(session.id) { current in
                current.claudeOwner = ClaudeSessionOwner(
                    entrypoint: owner.entrypoint, kind: owner.kind,
                    status: failure?.reason == "holder_busy" ? "busy" : nil,
                    pid: failure?.holderPID ?? owner.pid
                )
            }
        }
        // 同时绑定请求时和服务端返回的持有方，避免自动重启后再次发起杀进程。
        claudeTakeoverFailures[session.id] = ClaudeTakeoverFailureNotice(
            scope: scope, holderPIDs: holderPIDs, message: message,
            blocksRetry: failure?.retryable == false, waitsForIdle: waitsForIdle
        )
        setStatusMessage(message)
    }

    /// bridge 的结构化失败原因映射成可操作的提示；其余错误保留原文。
    func claudeTakeoverFailureMessage(_ error: Error) -> String {
        if let failure = CodexAppServerThreadTakeoverResult.failure(from: error) {
            switch failure.reason {
            case "holder_busy":
                return L10n.text("ui.take_over_claude_wait_until_idle")
            case "holder_state_unknown":
                return L10n.text("ui.take_over_claude_state_unknown")
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
