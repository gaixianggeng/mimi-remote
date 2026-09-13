import Foundation

/// 某台主机的 Claude channel 是否声明 thread/takeover。按主机缓存，切换主机后自然失效。
struct ClaudeTakeoverSupport: Equatable {
    let scope: HostScope
    let supported: Bool
}

// #451：Claude 会话被 Mac 上的终端 / Claude 桌面持有时，从这台设备硬接管：bridge 结束
// Mac 侧进程后同 id 续聊。这里只负责发起请求、放开输入和走既有 takenOver 控制态。
extension SessionStore {
    func refreshClaudeTakeoverSupportIfNeeded(sessionID: SessionID) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return
        }
        await refreshClaudeTakeoverSupportIfNeeded(for: session)
    }

    /// 探测一次当前主机是否支持接管。老 agentd / 旧 bridge 不声明该方法时按钮不出现。
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
        let supported = (try? await lease.client.sessionSupportsThreadTakeover(sessionID: session.id)) ?? false
        guard (try? requireCurrentProjectsGitHost(lease)) != nil else {
            return
        }
        claudeTakeoverSupport = ClaudeTakeoverSupport(scope: lease.scope, supported: supported)
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
        guard claudeTakeoverInFlightSessionID == nil else {
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
            setStatusMessage(claudeTakeoverFailureMessage(error))
            return false
        }
    }

    /// bridge 的结构化失败原因映射成可操作的提示；其余错误保留原文。
    func claudeTakeoverFailureMessage(_ error: Error) -> String {
        if let failure = CodexAppServerThreadTakeoverResult.failure(from: error) {
            switch failure.reason {
            case "holder_respawned":
                return L10n.text("ui.take_over_claude_failed_respawned")
            case "takeover_timeout":
                return L10n.text("ui.take_over_claude_failed_timeout")
            case "holder_unverified", "signal_failed":
                return L10n.text("ui.take_over_claude_failed_unverified")
            default:
                break
            }
        }
        return L10n.format("ui.take_over_failed_value", error.localizedDescription)
    }
}
