import Foundation

// WebSocket 生命周期、事件投影与通知保持在同一 MainActor 隔离域。
extension SessionStore {
    func prepareRelatedSession(
        _ relation: SessionContextSubagent,
        parentSessionID: SessionID
    ) async -> AgentSession? {
        let hostScope = appStore.activeHostScope
        guard !relation.id.isEmpty else { return nil }

        // gateway 重启后连接级 receiver 授权会丢失。先刷新父历史，现代
        // thread/turns/list 与旧版 thread/read 都会重新登记 receiverThreadIds。
        if let parent = sessionsByID[parentSessionID] {
            _ = await loadHistory(for: parent, quiet: true, force: true)
        }
        guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return nil }

        do {
            let response = try await clientFactory().session(
                id: relation.id,
                afterSeq: replayWatermark(for: relation.id)
            )
            guard appStore.activeHostScope == hostScope else { return nil }
            var child = response.session
            if let parent = sessionsByID[parentSessionID],
               projectsByID[child.projectID] == nil,
               sidebarProjectsByID[child.projectID] == nil {
                child = session(child, in: workspaceForSession(parent))
            }
            child.parentThreadID = child.parentThreadID ?? relation.parentThreadID ?? parentSessionID
            child.appServerSessionID = child.appServerSessionID ?? relation.sessionID
            child.agentNickname = child.agentNickname ?? relation.nickname
            child.agentRole = child.agentRole ?? relation.role
            // 父事件与 child read 任一来源明确只读时都取更严格值；两边都明确
            // 可写才允许普通会话控制链路重新开放写入，未知则 fail-closed。
            child.canAcceptDirectInput = child.canAcceptDirectInput == true
                && relation.canAcceptDirectInput == true
            upsert(child)
            _ = await loadHistory(for: child, quiet: true, force: true)
            guard appStore.activeHostScope == hostScope else { return nil }
            let current = sessionsByID[child.id] ?? child
            observeRelatedSession(current)
            return current
        } catch {
            guard appStore.activeHostScope == hostScope else { return nil }
            setErrorMessage(error.localizedDescription)
            return nil
        }
    }

    func observeRelatedSession(_ session: AgentSession) {
        guard !session.isLocalDraft,
              !isAppInBackground,
              !isNetworkUnavailable,
              connectionTermination == nil,
              !appStore.requiresRePairing
        else {
            return
        }
        if relatedSessionSocketID == session.id, relatedSessionSocket != nil {
            return
        }
        stopRelatedSessionObservation()
        relatedSessionSocketGeneration &+= 1
        let generation = relatedSessionSocketGeneration
        let lease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: session.id)
        let socket = sessionWebSocketFactory?(session) ?? webSocketFactory()
        socket.onStatus = { [weak self] status in
            guard case .terminated(let reason) = status else { return }
            Task { @MainActor in
                guard let self,
                      self.relatedSessionSocketGeneration == generation,
                      self.relatedSessionSocketID == session.id else { return }
                if reason == .credentialsInvalid {
                    self.terminateConnection(reason)
                }
            }
        }
        socket.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self,
                      self.relatedSessionSocketGeneration == generation,
                      self.relatedSessionSocketID == session.id else { return }
                await self.applyRuntimeEvent(event, lease: lease)
            }
        }
        // 次级阅读区绝不发送 turn/control；失败回调只需保持 no-op。
        socket.onSendAccepted = { _ in }
        socket.onSendFailure = { _, _ in }
        socket.onTurnSendOutcome = { _, _ in }
        socket.onApprovalDecisionFailure = { _, _ in }
        socket.onUserInputResponseFailure = { _, _ in }
        socket.onControlFailure = { _ in }
        relatedSessionSocket = socket
        relatedSessionSocketID = session.id
        socket.connect(sessionID: session.id, replayBufferedEvents: false)
    }

    func stopRelatedSessionObservation(sessionID: SessionID? = nil) {
        if let sessionID, relatedSessionSocketID != sessionID {
            return
        }
        relatedSessionSocketGeneration &+= 1
        relatedSessionSocketID = nil
        let socket = relatedSessionSocket
        relatedSessionSocket = nil
        socket?.disconnect()
    }

    func connectWebSocket(
        _ session: AgentSession,
        isReconnectAttempt: Bool = false,
        replayBufferedEvents: Bool = true,
        allowNonRunning: Bool = false
    ) {
        // 本地草稿尚无远端 thread id，任何 history/resume/WebSocket 请求都会把 local: id
        // 误送给 app-server。首条消息创建真实 thread 后再按正常路径连接。
        guard !session.isLocalDraft else {
            disconnectWebSocket()
            return
        }
        guard connectionTermination == nil, !appStore.requiresRePairing else {
            setWebSocketStatus(.terminated(.credentialsInvalid))
            return
        }
        guard !isAppInBackground else {
            // 后台前已启动的 refresh/bootstrap 可能稍后才走到 attach；不能让它在退役连接后
            // 又创建新 socket，否则系统挂起时仍会留下第二条幽灵连接。
            appLifecycleSuspendedSessionID = session.id
            setWebSocketStatus(.disconnected)
            return
        }
        guard !isNetworkUnavailable else {
            networkSuspendedSessionID = session.id
            setWebSocketStatus(.disconnected)
            setStatusMessage(L10n.text("ui.the_network_is_unavailable_and_will_automatically_reconnect_682354fa"))
            return
        }
        guard let credentialFingerprint = appStore.authenticatedCredentialFingerprint else {
            setWebSocketStatus(.disconnected)
            return
        }
        // allowNonRunning：非运行会话的订阅同样有价值——thread/resume 会带回权威状态
        // 纠正被误降级的会话，后续 turn 事件也能实时推进来。
        guard session.isRunning || allowNonRunning else {
            return
        }
        if !isReconnectAttempt {
            cancelWebSocketReconnect(resetAttempts: true)
        }
        if connectedSessionID == session.id,
           connectedHostScope == appStore.activeHostScope,
           case .connected = webSocketStatus {
            return
        }
        disconnectWebSocket(cancelReconnect: !isReconnectAttempt)

        let hostScope = appStore.activeHostScope
        let eventLease = HostSessionLease(hostScope: hostScope, sessionID: session.id)
        webSocketConnectionGeneration += 1
        let connectionGeneration = webSocketConnectionGeneration
        let socket = sessionWebSocketFactory?(session) ?? webSocketFactory()
        socket.onStatus = { [weak self] status in
            Task { @MainActor in
                guard self?.isCurrentWebSocketConnection(
                    sessionID: session.id,
                    generation: connectionGeneration,
                    hostScope: hostScope
                ) == true else {
                    return
                }
                switch status {
                case .failed, .disconnected, .terminated:
                    await self?.flushRuntimeEvents(lease: eventLease)
                default:
                    break
                }
                self?.applyWebSocketStatus(status, sessionID: session.id)
            }
        }
        let terminalStreamStore = terminalStreamStore
        socket.onEvent = { [weak self, terminalStreamStore] event in
            guard let self,
                  self.isCurrentWebSocketConnection(
                      sessionID: session.id,
                      generation: connectionGeneration,
                      hostScope: hostScope
                  ) else {
                return
            }
            if let metadata = self.metadata(for: event) {
                self.recordEventWatermark(metadata, fallbackSessionID: session.id)
            }
            let shouldFlushImmediately = terminalStreamStore.append(event, lease: eventLease)
            self.scheduleRuntimeEventFlush(lease: eventLease, immediately: shouldFlushImmediately)
        }
        socket.onSendAccepted = { [weak self] clientMessageID in
            Task { @MainActor in
                guard let clientMessageID else {
                    return
                }
                guard self?.isCurrentWebSocketConnection(
                    sessionID: session.id,
                    generation: connectionGeneration,
                    hostScope: hostScope
                ) == true else {
                    return
                }
                if self?.handleQueuedSendAccepted(
                    clientMessageID: clientMessageID,
                    sessionID: session.id
                ) == true {
                    return
                }
                self?.conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .sent)
                self?.conversationStore.compactTurnPayloadAfterSendAccepted(clientMessageID: clientMessageID, sessionID: session.id)
            }
        }
        socket.onSendFailure = { [weak self] clientMessageID, message in
            Task { @MainActor in
                guard self?.isCurrentWebSocketConnection(
                    sessionID: session.id,
                    generation: connectionGeneration,
                    hostScope: hostScope
                ) == true else {
                    return
                }
                if let clientMessageID {
                    if self?.handleQueuedSendFailure(
                        clientMessageID: clientMessageID,
                        sessionID: session.id,
                        message: message
                    ) == true {
                        return
                    }
                    guard self?.conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed) == true else {
                        return
                    }
                }
                self?.clearForegroundActivity(sessionID: session.id)
                self?.setErrorMessage(L10n.format("ui.sending_failed_value", message))
            }
        }
        socket.onTurnSendOutcome = { [weak self] clientMessageID, outcome in
            Task { @MainActor in
                guard let self else {
                    return
                }
                let isCurrentConnection = self.isCurrentWebSocketConnection(
                    sessionID: session.id,
                    generation: connectionGeneration,
                    hostScope: hostScope
                )
                // 旧连接的 ACK 只能在当前连接仍有效时对账；Host 已切换或普通旧回调全部丢弃。
                guard isCurrentConnection else {
                    return
                }
                self.handleTurnSendOutcome(
                    clientMessageID: clientMessageID,
                    sessionID: session.id,
                    outcome: outcome
                )
            }
        }
        socket.onApprovalDecisionFailure = { [weak self] approvalID, message in
            Task { @MainActor in
                guard self?.isCurrentWebSocketConnection(
                    sessionID: session.id,
                    generation: connectionGeneration,
                    hostScope: hostScope
                ) == true else {
                    return
                }
                self?.clearPendingApprovalDecision(sessionID: session.id, approvalID: approvalID)
                self?.setErrorMessage(L10n.format("ui.approval_sending_failed_value", message))
            }
        }
        socket.onUserInputResponseFailure = { [weak self] requestID, message in
            Task { @MainActor in
                guard self?.isCurrentWebSocketConnection(
                    sessionID: session.id,
                    generation: connectionGeneration,
                    hostScope: hostScope
                ) == true else {
                    return
                }
                let request = self?.clearPendingUserInputResponse(sessionID: session.id, requestID: requestID)
                if let request {
                    self?.restoreUserInputRequestAfterFailure(request, sessionID: session.id)
                }
                self?.setErrorMessage(L10n.format("ui.failed_to_send_supplementary_information_value", message))
            }
        }
        socket.onControlFailure = { [weak self] message in
            Task { @MainActor in
                guard self?.isCurrentWebSocketConnection(
                    sessionID: session.id,
                    generation: connectionGeneration,
                    hostScope: hostScope
                ) == true else {
                    return
                }
                if self?.statusMessage == L10n.text("ui.stopping_current_reply") {
                    self?.setStatusMessage(nil)
                }
                self?.setErrorMessage(L10n.format("ui.failed_to_send_control_command_value", message))
            }
        }
        webSocket = socket
        connectedSessionID = session.id
        connectedHostScope = hostScope
        connectedCredentialFingerprint = credentialFingerprint
        conversationStore.resetLiveTranscript(sessionID: session.id)
        syncRuntimeActivity(with: session)
        runtimeEventFlushTasks[eventLease]?.cancel()
        runtimeEventFlushTasks[eventLease] = nil
        socket.connect(sessionID: session.id, replayBufferedEvents: replayBufferedEvents)
    }

    func replayWatermark(for sessionID: SessionID) -> EventSequence? {
        // WS/REST 的 last_seen_seq 取四处最大值：结构化事件、历史快照、对话投影和日志，
        // 避免某一侧 store 清理或重置后造成事件重放/漏拉。
        [
            lastSeenEventSeqBySessionID[sessionID],
            historySnapshotSeqBySessionID[sessionID],
            conversationStore.lastSeenSeq(for: sessionID),
            logStore.lastSeq(for: sessionID)
        ]
        .compactMap { $0 }
        .max()
    }

    func readyWebSocket(
        for session: AgentSession,
        allowNonRunning: Bool = false
    ) -> (any SessionWebSocketClient)? {
        // 凭据失效是确定性终态，即使设备同时离线，也必须优先引导用户重新配对。
        if let termination = connectionTermination {
            setErrorMessage(termination.message)
            return nil
        }
        if appStore.requiresRePairing {
            setErrorMessage(ConnectionTerminationStatus.credentialsInvalid.message)
            return nil
        }
        guard !isNetworkUnavailable else {
            setErrorMessage(L10n.text("ui.the_network_is_unavailable_and_will_automatically_reconnect"))
            return nil
        }
        let shouldReconnect: Bool
        switch webSocketStatus {
        case .failed, .disconnected:
            shouldReconnect = true
        case .connecting, .connected, .terminated:
            shouldReconnect = false
        }
        if connectedSessionID != session.id ||
            connectedHostScope != appStore.activeHostScope ||
            webSocket == nil ||
            shouldReconnect {
            connectWebSocket(session, allowNonRunning: allowNonRunning)
        }
        guard let webSocket,
              connectedSessionID == session.id,
              connectedHostScope == appStore.activeHostScope else {
            setErrorMessage(L10n.text("ui.websocket_is_reconnecting_please_try_again_later"))
            return nil
        }
        guard webSocketStatus == .connected else {
            if case .terminated(let reason) = webSocketStatus {
                setErrorMessage(reason.message)
            } else {
                setErrorMessage(L10n.text("ui.websocket_is_connecting_please_wait_and_send_again"))
            }
            return nil
        }
        return webSocket
    }

    func applyWebSocketStatus(_ status: WebSocketStatus, sessionID: String) {
        switch status {
        case .connected:
            guard !isNetworkUnavailable else {
                suspendWebSocketForNetworkLoss(sessionID: sessionID)
                return
            }
            cancelWebSocketReconnect(resetAttempts: false)
            webSocketReconnectAttemptBySessionID.removeValue(forKey: sessionID)
            setWebSocketStatus(.connected)
            setErrorMessage(nil)
            dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID)
        case .failed(let message):
            if isNetworkUnavailable {
                suspendWebSocketForNetworkLoss(sessionID: sessionID)
                setStatusMessage(L10n.text("ui.the_network_is_unavailable_and_will_automatically_reconnect_682354fa"))
                return
            }
            let policyRejected = Self.isDeterministicGatewayPolicyFailure(message)
            let activeWriterConflict = Self.isCodexActiveWriterConflict(message)
            // 另一套 app-server 已持有 writer 时，同参数重连只会重复失败。停止重连并给出
            // Desktop session sync 指引，避免把结构性冲突伪装成短暂网络波动。
            let canReconnect = shouldAutoReconnectWebSocket(sessionID: sessionID)
                && !policyRejected
                && !activeWriterConflict
            if connectedSessionID == sessionID {
                connectedSessionID = nil
                connectedHostScope = nil
                connectedCredentialFingerprint = nil
                webSocket = nil
            }
            markDispatchingQueuedTurnsNeedsConfirmation(
                sessionID: sessionID,
                message: L10n.text("ui.the_connection_has_been_interrupted_sending_results_requires")
            )
            conversationStore.markSendingUserMessagesFailed(sessionID: sessionID)
            clearPendingApprovalDecisions(sessionID: sessionID)
            clearPendingUserInputResponses(sessionID: sessionID)
            clearForegroundActivity(sessionID: sessionID)
            if canReconnect {
                scheduleWebSocketReconnect(sessionID: sessionID, reason: message)
            } else {
                setWebSocketStatus(.failed(message))
                if activeWriterConflict {
                    setErrorMessage(L10n.text("ui.codex_active_writer_conflict"))
                } else {
                    setErrorMessage(policyRejected ? L10n.format("ui.the_connection_was_rejected_by_server_policy_and", message) : message)
                }
            }
        case .terminated(let reason):
            if reason == .credentialsInvalid,
               !appStore.isCurrentCredentialFingerprint(connectedCredentialFingerprint) {
                // 旧 Runtime/空 Token 的迟到拒绝不是当前凭据结论；按普通断线交给现有恢复链路。
                if connectedSessionID == sessionID {
                    connectedSessionID = nil
                    connectedHostScope = nil
                    connectedCredentialFingerprint = nil
                    webSocket = nil
                }
                setWebSocketStatus(.disconnected)
                scheduleWebSocketReconnect(
                    sessionID: sessionID,
                    reason: L10n.text("ui.the_connection_has_been_lost")
                )
                return
            }
            terminateConnection(reason)
        case .disconnected:
            if isNetworkUnavailable {
                suspendWebSocketForNetworkLoss(sessionID: sessionID)
                setStatusMessage(L10n.text("ui.the_network_is_unavailable_and_will_automatically_reconnect_682354fa"))
                return
            }
            let canReconnect = shouldAutoReconnectWebSocket(sessionID: sessionID)
            if connectedSessionID == sessionID {
                connectedSessionID = nil
                connectedHostScope = nil
                connectedCredentialFingerprint = nil
                webSocket = nil
            }
            markDispatchingQueuedTurnsNeedsConfirmation(
                sessionID: sessionID,
                message: L10n.text("ui.the_connection_has_been_interrupted_sending_results_requires")
            )
            conversationStore.markSendingUserMessagesFailed(sessionID: sessionID)
            clearPendingApprovalDecisions(sessionID: sessionID)
            clearForegroundActivity(sessionID: sessionID)
            if canReconnect {
                scheduleWebSocketReconnect(sessionID: sessionID, reason: L10n.text("ui.the_connection_has_been_lost"))
            } else {
                setWebSocketStatus(.disconnected)
            }
        case .connecting:
            setWebSocketStatus(.connecting)
        }
    }

    /// 只识别 app-server 已知的单 writer 拒绝；其他 -32600（例如 no rollout found、
    /// 参数不兼容）仍沿原有错误与恢复路径处理，不能被这个 UX 映射吞掉。
    nonisolated static func isCodexActiveWriterConflict(_ message: String) -> Bool {
        guard message.contains("-32600") else {
            return false
        }
        let lowerMessage = message.lowercased()
        return lowerMessage.contains("already has an active writer")
            || lowerMessage.contains("external_thread_active")
            || (lowerMessage.contains("thread is active") && lowerMessage.contains("codex desktop"))
    }

    @discardableResult
    func terminateConnectionIfCredentialsInvalid(_ error: Error) -> Bool {
        guard appStore.acceptsCredentialInvalidation(error) else {
            return false
        }
        terminateConnection(.credentialsInvalid)
        return true
    }

    func terminateConnection(_ reason: ConnectionTerminationStatus) {
        // 认证失败是确定性终止态：保留 projects、sessions、选择和本地消息，只退役无法再使用的
        // 网络连接并取消重试。新凭据提交成功后 commitPreparedConnection 会显式解除该状态。
        connectionTermination = reason
        cancelRemoteSessionSearchRequestsPreservingResults()
        appStore.markCredentialsInvalid()
        appLifecycleSuspendedSessionID = nil
        networkSuspendedSessionID = nil
        networkRecoveryTask?.cancel()
        networkRecoveryTask = nil
        cancelWebSocketReconnect(resetAttempts: true)
        webSocketConnectionGeneration += 1
        if let connectedSessionID {
            markDispatchingQueuedTurnsNeedsConfirmation(
                sessionID: connectedSessionID,
                message: L10n.text("ui.the_connection_credentials_have_expired_confirmation_is_required")
            )
        }
        stopAllQueuedSessionMonitoring()
        let socket = webSocket
        webSocket = nil
        connectedSessionID = nil
        connectedHostScope = nil
        connectedCredentialFingerprint = nil
        runtimeEventFlushTasks.values.forEach { $0.cancel() }
        runtimeEventFlushTasks.removeAll(keepingCapacity: false)
        terminalStreamStore.removeAll(profileID: appStore.activeHostScope.profileID)
        socket?.disconnect()
        setWebSocketStatus(.terminated(reason))
        setErrorMessage(reason.message)
        setStatusMessage(reason.message)
    }

    func disconnectWebSocket(cancelReconnect: Bool = true) {
        if cancelReconnect {
            cancelWebSocketReconnect(resetAttempts: true)
        }
        var leasesToFlush = Set(runtimeEventFlushTasks.keys)
        if let connectedSessionID, let connectedHostScope {
            leasesToFlush.insert(HostSessionLease(
                hostScope: connectedHostScope,
                sessionID: connectedSessionID
            ))
        }
        for lease in leasesToFlush {
            runtimeEventFlushTasks[lease]?.cancel()
            runtimeEventFlushTasks[lease] = nil
            if lease.hostScope == appStore.activeHostScope {
                Task { [weak self] in
                    // 同一 HostScope 内手动切会话时保留最后一个合并窗口；跨主机/代次时明确丢弃。
                    await self?.flushRuntimeEvents(lease: lease)
                }
            } else {
                terminalStreamStore.removeAll(lease: lease)
            }
        }
        webSocketConnectionGeneration += 1
        let previousSessionID = connectedSessionID
        let socket = webSocket
        webSocket = nil
        connectedSessionID = nil
        connectedHostScope = nil
        connectedCredentialFingerprint = nil
        socket?.disconnect()
        if let previousSessionID {
            markDispatchingQueuedTurnsNeedsConfirmation(
                sessionID: previousSessionID,
                message: L10n.text("ui.the_connection_has_been_interrupted_sending_results_requires")
            )
            conversationStore.markSendingUserMessagesFailed(sessionID: previousSessionID)
        }
        pendingApprovalDecisionIDsBySessionID.removeAll()
        pendingUserInputResponseIDsBySessionID.removeAll()
        pendingUserInputRequestsBySessionID.removeAll()
        setWebSocketStatus(.disconnected)
    }

    func isCurrentWebSocketConnection(
        sessionID: SessionID,
        generation: Int,
        hostScope: HostScope? = nil
    ) -> Bool {
        connectedSessionID == sessionID &&
            webSocketConnectionGeneration == generation &&
            (hostScope == nil || connectedHostScope == hostScope) &&
            (hostScope == nil || appStore.activeHostScope == hostScope)
    }

    func shouldAutoReconnectWebSocket(sessionID: SessionID) -> Bool {
        // 状态可能刚被瞬时 idle 误读降级，但 gateway 连接本身仍可重连。
        guard connectionTermination == nil,
              !appStore.requiresRePairing,
              !isNetworkUnavailable,
              connectedSessionID == sessionID,
              connectedHostScope == appStore.activeHostScope,
              selectedSessionID == sessionID,
              sessionsByID[sessionID] != nil,
              appStore.isConfigured else {
            return false
        }
        return true
    }

    func scheduleWebSocketReconnect(sessionID: SessionID, reason: String) {
        // 终态不能被迟到的断线回调覆盖成普通失败，否则 UI 会丢失重新配对入口。
        if let termination = connectionTermination {
            setWebSocketStatus(.terminated(termination))
            setErrorMessage(termination.message)
            return
        }
        if appStore.requiresRePairing {
            let termination = ConnectionTerminationStatus.credentialsInvalid
            setWebSocketStatus(.terminated(termination))
            setErrorMessage(termination.message)
            return
        }
        guard selectedSessionID == sessionID,
              sessionsByID[sessionID] != nil else {
            setWebSocketStatus(.failed(reason))
            setErrorMessage(reason)
            return
        }
        guard !isNetworkUnavailable else {
            suspendWebSocketForNetworkLoss(sessionID: sessionID)
            setStatusMessage(L10n.text("ui.the_network_is_unavailable_and_will_automatically_reconnect_682354fa"))
            return
        }

        let attempt = webSocketReconnectAttemptBySessionID[sessionID, default: 0] + 1
        webSocketReconnectTask?.cancel()
        webSocketReconnectGeneration &+= 1
        let reconnectGeneration = webSocketReconnectGeneration
        webSocketReconnectAttemptBySessionID[sessionID] = attempt
        let delay = webSocketReconnectDelayNanoseconds(attempt)
        setWebSocketStatus(.connecting)
        setErrorMessage(L10n.format("ui.websocket_disconnected_and_reconnecting_automatically_value", reason))
        setStatusMessage(L10n.format("ui.websocket_value_th_reconnection", attempt))
        let reconnectSleep = webSocketReconnectSleep

        // 重连任务只服务当前选中的会话；切项目/停止/返回列表都会取消它。
        webSocketReconnectTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await reconnectSleep(delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run { [weak self] in
                guard self?.webSocketReconnectGeneration == reconnectGeneration else { return }
                self?.webSocketReconnectTask = nil
            }
            await self?.runScheduledWebSocketReconnect(
                sessionID: sessionID,
                attempt: attempt,
                reconnectGeneration: reconnectGeneration
            )
        }
    }

    func cancelWebSocketReconnect(resetAttempts: Bool) {
        webSocketReconnectTask?.cancel()
        webSocketReconnectTask = nil
        // attempt 在 reset 后可能复用同一个整数；单调租约确保已经越过 sleep 的旧任务
        // 也无法在切会话/连通后继续执行 preflight。
        webSocketReconnectGeneration &+= 1
        if resetAttempts {
            webSocketReconnectAttemptBySessionID.removeAll()
        }
    }

    func runScheduledWebSocketReconnect(
        sessionID: SessionID,
        attempt: Int,
        reconnectGeneration: UInt64
    ) async {
        guard connectionTermination == nil,
              !appStore.requiresRePairing,
              !isNetworkUnavailable,
              !Task.isCancelled,
              webSocketReconnectGeneration == reconnectGeneration,
              selectedSessionID == sessionID,
              webSocketReconnectAttemptBySessionID[sessionID] == attempt,
              let latestSession = sessionsByID[sessionID] else {
            return
        }
        guard selectedSessionID == sessionID else {
            return
        }
        let refreshedSession = await refreshSessionSnapshotBeforeReconnect(
            sessionID: sessionID,
            reconnectGeneration: reconnectGeneration
        ) ?? latestSession
        guard connectionTermination == nil,
              !appStore.requiresRePairing,
              !isNetworkUnavailable,
              !Task.isCancelled,
              webSocketReconnectGeneration == reconnectGeneration,
              selectedSessionID == sessionID,
              webSocketReconnectAttemptBySessionID[sessionID] == attempt,
              sessionsByID[sessionID] != nil else {
            return
        }
        // 快照可能在上游刚恢复时把运行中的 turn 误读成 idle；不能据此一次性放弃重连。
        // 连接会在发送前由 gateway 按当前状态重新建立写入路径。
        connectWebSocket(refreshedSession, isReconnectAttempt: true, allowNonRunning: true)
    }

    func refreshSessionSnapshotBeforeReconnect(
        sessionID: SessionID,
        reconnectGeneration: UInt64
    ) async -> AgentSession? {
        guard !Task.isCancelled,
              webSocketReconnectGeneration == reconnectGeneration,
              let current = sessionsByID[sessionID] else {
            return nil
        }
        do {
            let client = try clientFactory()
            // 以 preflight 开始时刻判断短缓存，不能等 thread/read 返回后再算；弱网下 read
            // 自身可能跨过 4 秒 TTL，导致明明刚加载成功的首屏仍被重复下载。
            let hadRecentAppliedFullAtPreflightStart = hasRecentFullHistoryFirstPage(sessionID: sessionID)
            let response = try await client.session(id: sessionID, afterSeq: replayWatermark(for: sessionID))
            guard !Task.isCancelled,
                  webSocketReconnectGeneration == reconnectGeneration,
                  selectedSessionID == sessionID else {
                return nil
            }
            let refreshed = self.session(response.session, in: workspaceForSession(current))
            upsert(refreshed)
            if let recentOutput = response.recentOutput, !recentOutput.isEmpty {
                // 重连前只补诊断日志；结构化消息由 history 和 app-server event 补齐。
                logStore.append(recentOutput, sessionID: sessionID, seq: response.lastSeq)
            }
            // 重连前先刷新一次消息页，用 cursor/id/revision 合并可能错过的结构化消息。
            guard !Task.isCancelled,
                  webSocketReconnectGeneration == reconnectGeneration else {
                return nil
            }
            // 首屏刚完成后，底层事件订阅若短暂结束，会在约 1 秒内进入 reconnect。
            // thread/read 更新 metadata signature 后普通 loadHistory 会绕过短缓存，造成同一
            // 10-turn 大页立刻再传一次。缓存窗内依赖 replay/resume；真正较长断线仍补拉历史。
            if !hadRecentAppliedFullAtPreflightStart || !hasLoadedFullHistorySnapshot(sessionID: sessionID) {
                await loadHistory(for: refreshed)
            }
            return refreshed
        } catch {
            guard !Task.isCancelled,
                  webSocketReconnectGeneration == reconnectGeneration,
                  selectedSessionID == sessionID else {
                return nil
            }
            if terminateConnectionIfCredentialsInvalid(error) {
                return nil
            }
            setStatusMessage(L10n.format("ui.snapshot_refresh_failed_before_reconnection_value", error.localizedDescription))
            return current
        }
    }

    func scheduleRuntimeEventFlush(lease: HostSessionLease, immediately: Bool = false) {
        // 一个 session 同时只保留一个消费任务。即使 80ms 窗口内越过批量阈值，
        // 也不为后续每个事件反复取消并新建 Task；最长只多等待当前合并窗口。
        guard runtimeEventFlushTasks[lease] == nil else {
            return
        }
        let delay = immediately ? 0 : runtimeEventFlushDelayNanoseconds
        runtimeEventFlushTasks[lease] = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            await self?.flushRuntimeEvents(lease: lease)
        }
    }

    func flushRuntimeEvents(lease: HostSessionLease) async {
        runtimeEventFlushTasks[lease]?.cancel()
        runtimeEventFlushTasks[lease] = nil
        let events = terminalStreamStore.drain(lease: lease)
        guard !events.isEmpty, appStore.activeHostScope == lease.hostScope else {
            return
        }
        for event in events {
            guard appStore.activeHostScope == lease.hostScope else { return }
            await applyRuntimeEvent(event, lease: lease)
        }
    }

    func applyRuntimeEvent(_ event: AgentEvent, lease: HostSessionLease) async {
        guard appStore.activeHostScope == lease.hostScope else { return }
        let sessionID = lease.sessionID
        let replayAckSocket = replayBoundarySocket(for: event, fallbackSessionID: sessionID)
        defer {
            replayAckSocket?.acknowledgeAppliedEvent(event)
        }
        if let metadata = metadata(for: event) {
            recordEventWatermark(metadata, fallbackSessionID: sessionID)
        }
        if case .turnCompleted(let metadata) = event,
           shouldIgnoreStaleTurnCompletion(metadata, fallbackSessionID: sessionID) {
            // 历史回放可能晚于新 turn 到达。旧完成事件既不能把新 turn 标成 completed，
            // 也不能清掉或放行绑定到另一 turn 的本地队列。
            return
        }
        recordRuntimeActivity(for: event, fallbackSessionID: sessionID)
        if case .permissionProfileUpdated(let profile, let metadata) = event {
            let id = metadata.sessionID ?? sessionID
            if let profile {
                activePermissionProfileBySessionID[id] = profile
            } else {
                activePermissionProfileBySessionID.removeValue(forKey: id)
            }
        }
        let runtimeNotification = runtimeNotification(for: event, fallbackSessionID: sessionID)
        let output = await eventReducer.reduce(
            event,
            fallbackSessionID: sessionID,
            outputIdleClearDelay: foregroundOutputIdleClearDelay
        )
        guard appStore.activeHostScope == lease.hostScope else { return }
        applyEventReducerOutput(output)
        if case .turnStarted(let metadata) = event {
            let id = metadata.sessionID ?? sessionID
            _ = satisfyPendingPermissionTurnBoundary(
                sessionID: id,
                clientMessageID: metadata.clientMessageID
            )
            if let turnID = metadata.turnID {
                queuedTurnAwaitingStartSessionIDs.remove(id)
                queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: id)
                queuedTurnStartedIDBySessionID[id] = turnID
                // 第一条已派发时，后续队列项统一改为等待这个新 turn；不能继续绑定旧完成事件。
                _ = mutateAndPersistQueuedTurns {
                    guard var queue = queuedRunningTurnsBySessionID[id] else { return }
                    for index in queue.indices where queue[index].dispatchState == .waiting {
                        queue[index].expectedTurnID = turnID
                        queue[index].waitsForAcceptedTurnStart = nil
                        queue[index].blockedCompletionID = nil
                    }
                    queuedRunningTurnsBySessionID[id] = queue
                }
                stopQueuedSessionMonitoringIfIdle(sessionID: id)
            }
        }
        if case .turnCompleted(let metadata) = event {
            let id = metadata.sessionID ?? sessionID
            if id == selectedSessionID,
               statusMessage == L10n.text("ui.stopping_current_reply") {
                setStatusMessage(nil)
            }
            if let projectID = sessionsByID[id]?.projectID {
                scheduleSessionListReconciliation(
                    projectID: projectID,
                    hostScope: lease.hostScope
                )
            }
            scheduleGitRefreshAfterTurnCompletion(
                sessionID: id,
                hostScope: lease.hostScope
            )
            if let completedTurnID = metadata.turnID {
                let hasPersistedAcceptedTurnBarrier = queuedRunningTurnsBySessionID[id]?.contains(where: {
                    $0.dispatchState == .waiting
                        && $0.waitsForAcceptedTurnStart == true
                        && $0.blockedCompletionID == completedTurnID
                }) == true
                let isRepeatedCompletionWhileAwaitingStart = hasPersistedAcceptedTurnBarrier
                    || (queuedTurnAwaitingStartSessionIDs.contains(id)
                        && queuedTurnBlockedCompletionIDBySessionID[id] == completedTurnID)
                if !isRepeatedCompletionWhileAwaitingStart {
                    let completedBeforeObservedStart = queuedTurnAwaitingStartSessionIDs.remove(id) != nil
                    queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: id)
                    // 只解除明确绑定到本次完成 turn 的等待项。dispatching / needsConfirmation
                    // 绝不能被完成事件自动重放，否则断线窗口会制造重复消息。
                    _ = mutateAndPersistQueuedTurns {
                        guard var queue = queuedRunningTurnsBySessionID[id] else { return }
                        if completedBeforeObservedStart {
                            for index in queue.indices where queue[index].dispatchState == .waiting {
                                queue[index].expectedTurnID = completedTurnID
                            }
                        }
                        for index in queue.indices
                        where queue[index].dispatchState == .waiting
                            && queue[index].waitsForAcceptedTurnStart == true {
                            queue[index].waitsForAcceptedTurnStart = nil
                            queue[index].blockedCompletionID = nil
                            queue[index].expectedTurnID = completedTurnID
                        }
                        for index in queue.indices
                        where queue[index].dispatchState == .waiting
                            && queue[index].expectedTurnID == completedTurnID {
                            queue[index].expectedTurnID = nil
                        }
                        queuedRunningTurnsBySessionID[id] = queue
                    }
                    queuedTurnStartedIDBySessionID.removeValue(forKey: id)
                    if queuedRunningTurnsBySessionID[id]?.first?.dispatchState == .waiting,
                       queuedRunningTurnsBySessionID[id]?.first?.waitsForAcceptedTurnStart != true,
                       queuedRunningTurnsBySessionID[id]?.first?.expectedTurnID == nil {
                        queuedTurnBlockedCompletionIDBySessionID[id] = completedTurnID
                    }
                    dispatchNextQueuedRunningTurnIfIdle(sessionID: id)
                    stopQueuedSessionMonitoringIfIdle(sessionID: id)
                }
            }
            scheduleDeferredFullHistoryReloadAfterTurnCompletion(sessionID: id)
        }
        guard appStore.activeHostScope == lease.hostScope else { return }
        await scheduleRuntimeNotificationIfNeeded(
            runtimeNotification,
            hostScope: lease.hostScope
        )
    }

    func replayBoundarySocket(
        for event: AgentEvent,
        fallbackSessionID: SessionID
    ) -> (any SessionWebSocketClient)? {
        guard metadata(for: event)?.replayBoundarySequence != nil else { return nil }
        let sessionID = metadata(for: event)?.sessionID ?? fallbackSessionID
        if connectedSessionID == sessionID, let webSocket {
            return webSocket
        }
        return queuedSessionSockets[sessionID]
    }

    func shouldIgnoreStaleTurnCompletion(
        _ metadata: AgentEventMetadata,
        fallbackSessionID: SessionID
    ) -> Bool {
        guard let completedTurnID = metadata.turnID else {
            return false
        }
        let sessionID = metadata.sessionID ?? fallbackSessionID
        if let activeTurnID = sessionsByID[sessionID]?.activeTurnID,
           activeTurnID != completedTurnID {
            return true
        }
        return false
    }

    func scheduleSessionListReconciliation(
        projectID: String,
        hostScope: HostScope? = nil
    ) {
        let capturedHostScope = hostScope ?? appStore.activeHostScope
        sessionListReconciliationTasksByProjectID[projectID]?.cancel()
        sessionListReconciliationTasksByProjectID[projectID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.sessionListReconciliationDelayNanoseconds)
            } catch {
                return
            }
            guard self.appStore.activeHostScope == capturedHostScope else {
                return
            }
            await self.refreshSessions(
                forProjectID: projectID,
                showLoading: false,
                clearErrorOnSuccess: false,
                updateStatusMessage: false,
                reportErrorOnFailure: false,
                reuseRecent: false,
                activatesProject: false
            )
            guard self.appStore.activeHostScope == capturedHostScope else {
                return
            }
            self.sessionListReconciliationTasksByProjectID.removeValue(forKey: projectID)
        }
    }

    func scheduleRuntimeNotificationIfNeeded(
        _ notification: SessionRuntimeNotification?,
        hostScope: HostScope
    ) async {
        guard appStore.activeHostScope == hostScope else {
            return
        }
        guard let notification else {
            return
        }
        guard notification.kind == .approval || runtimeCompletionNotificationsEnabled else {
            return
        }
        let profileID = hostScope.profileID
        let deliveryKey = "\(profileID.utf8.count):\(profileID):\(notification.id)"
        guard !deliveredRuntimeNotificationIDs.contains(deliveryKey) else {
            return
        }
        deliveredRuntimeNotificationIDs.insert(deliveryKey)
        do {
            // 运行态通知不持久化：它只是实时提示，不应该在会话列表状态里留下“待处理任务”的假象。
            guard let session = sessionsByID[notification.sessionID] else {
                setStatusMessage(L10n.text("ui.notification_scheduling_failed_the_corresponding_session_cannot_be"))
                return
            }
            let route = SessionNotificationRoute.current(
                profileID: profileID,
                projectID: session.projectID,
                sessionID: session.id
            )
            try await sessionReminderScheduler.notify(notification, route: route)
        } catch {
            guard appStore.activeHostScope == hostScope else {
                return
            }
            setStatusMessage(L10n.format("ui.notification_scheduling_failed_value", error.localizedDescription))
        }
    }

    func applyEventReducerOutput(_ output: EventReducerOutput) {
        if isPublishingEventReducerSessions {
            deferredEventReducerOutputs.append(output)
            return
        }
        let ownsSessionMutationBatch = beginEventReducerSessionMutationBatch()
        for session in output.upsertSessions {
            upsert(session)
        }
        for (id, status) in output.statusUpdates {
            updateSession(id) { item in
                item.status = status
            }
            if status == SessionStatus.completed.rawValue {
                locallyCompletedSessionIDs.insert(id)
            } else if Self.isRunningStatus(status) {
                locallyCompletedSessionIDs.remove(id)
            }
            if !Self.isRunningStatus(status) {
                clearRuntimeActivity(sessionID: id)
            }
            contextStore.updateStatus(sessionID: id, status: status)
        }
        for mutation in output.activeTurnMutations {
            applyActiveTurnMutation(mutation)
        }
        for (id, approval) in output.pendingApprovalUpdates {
            if approval == nil {
                clearPendingApprovalDecisions(sessionID: id)
            }
            updateSession(id) { item in
                item.pendingApproval = approval
            }
        }
        for (id, userInput) in output.pendingUserInputUpdates {
            if userInput == nil {
                clearPendingUserInputResponses(sessionID: id)
            }
            updateSession(id) { item in
                item.pendingUserInput = userInput
            }
        }
        for (context, fallbackSessionID) in output.contextUpdates {
            contextStore.upsert(context, fallbackSessionID: fallbackSessionID)
        }
        for (id, goal) in output.goalUpdates {
            if let goal {
                applyThreadGoal(goal, fallbackSessionID: id)
            } else {
                clearThreadGoal(sessionID: id)
            }
        }
        for id in output.pendingApprovalTaskClears {
            contextStore.clearPendingApprovalTasks(sessionID: id)
        }
        for (id, activity, delay) in output.foregroundUpdates {
            setForegroundActivity(activity, sessionID: id, autoClearAfter: delay)
        }
        for id in output.foregroundClears {
            clearForegroundActivity(sessionID: id)
        }
        for append in output.logAppends {
            logStore.append(append.text, sessionID: append.sessionID, seq: append.seq)
        }
        for mutation in output.messageMutations {
            applyMessageMutation(mutation)
        }
        // message mutation 可能通过 assistant preview 再次更新 session；必须等这里
        // 完成后才提交，确保整个 reducer output 只发布一次且前序 mutation 彼此可见。
        if ownsSessionMutationBatch {
            commitEventReducerSessionMutationBatch()
        }
        if let statusMessage = output.statusMessage {
            setStatusMessage(statusMessage)
        }
        if let errorMessage = output.errorMessage {
            setErrorMessage(errorMessage)
        }
        if output.disconnectWebSocket {
            disconnectWebSocket()
        }
    }

    private func beginEventReducerSessionMutationBatch() -> Bool {
        // @Published 的同步订阅者可能在副作用阶段重入 applyEventReducerOutput。
        // 内层输出复用同一 working copy，但只有最外层拥有提交权，避免提前发布并清空外层批次。
        guard eventReducerSessionMutationBatch == nil else {
            return false
        }
        eventReducerSessionMutationBatch = EventReducerSessionMutationBatch(
            sessions: sessions
        )
        return true
    }

    private func commitEventReducerSessionMutationBatch() {
        guard let batch = eventReducerSessionMutationBatch else {
            return
        }
        // 先退出 batch，再赋值 canonical sessions，保证 didSet 走正常的唯一重建路径。
        eventReducerSessionMutationBatch = nil
        guard batch.sessions != sessions else {
            // 中间 mutation 最终抵消时保持 no-op：不发布，也不触发昂贵索引重建。
            return
        }
        isPublishingEventReducerSessions = true
        sessions = batch.sessions
        isPublishingEventReducerSessions = false
        // 订阅 sessions/didSet 派生状态时到达的 output 必须紧跟本次 canonical 提交，
        // 再继续当前 output 的 status/error/disconnect 副作用，保持同步观察顺序。
        drainDeferredEventReducerOutputs()
    }

    private func drainDeferredEventReducerOutputs() {
        guard !isDrainingDeferredEventReducerOutputs else {
            return
        }
        isDrainingDeferredEventReducerOutputs = true
        defer { isDrainingDeferredEventReducerOutputs = false }

        // 每轮整体取出，避免 removeFirst 的 O(n) 搬移；处理过程中再次排队的 output
        // 会在下一轮继续按到达顺序执行。
        while !deferredEventReducerOutputs.isEmpty {
            let outputs = deferredEventReducerOutputs
            deferredEventReducerOutputs.removeAll(keepingCapacity: true)
            for output in outputs {
                applyEventReducerOutput(output)
            }
        }
    }

    func applyActiveTurnMutation(_ mutation: EventReducerActiveTurnMutation) {
        switch mutation {
        case .set(let sessionID, let turnID):
            updateSession(sessionID) { item in
                guard item.isRunning else {
                    return
                }
                item.activeTurnID = turnID
            }
        case .clear(let sessionID, let completedTurnID):
            updateSession(sessionID) { item in
                // 完成事件可能延迟到达；带 turn id 时只清理对应的活跃回合，避免误伤随后开始的新回合。
                guard completedTurnID == nil || item.activeTurnID == nil || item.activeTurnID == completedTurnID else {
                    return
                }
                item.activeTurnID = nil
            }
        }
    }

    func applyMessageMutation(_ mutation: EventReducerMessageMutation) {
        switch mutation {
        case .turnLifecycle(let lifecycle, let metadata, let fallbackSessionID):
            conversationStore.updateTurnLifecycle(
                lifecycle,
                metadata: metadata,
                fallbackSessionID: fallbackSessionID
            )
        case .assistantDelta(let delta, let metadata, let fallbackSessionID):
            conversationStore.applyAssistantDelta(delta, metadata: metadata, fallbackSessionID: fallbackSessionID)
        case .completed(let message, let metadata, let fallbackSessionID):
            conversationStore.completeMessage(message, metadata: metadata, fallbackSessionID: fallbackSessionID)
            if message.role == .assistant {
                setSessionListProjection(
                    sessionID: metadata.sessionID ?? message.sessionID,
                    preview: message.content,
                    source: .localAssistant,
                    clientMessageID: nil
                )
            }
        case .system(let text, let sessionID, let kind, let metadata):
            conversationStore.appendSystem(text, sessionID: sessionID, kind: kind, metadata: metadata)
        case .resolveLatestPendingApproval(let sessionID):
            conversationStore.resolveLatestPendingApproval(sessionID: sessionID)
        case .resolveLatestPendingUserInput(let sessionID, let skipped):
            conversationStore.resolveLatestPendingUserInput(sessionID: sessionID, skipped: skipped)
        case .markCurrentAssistantCompleted(let metadata, let fallbackSessionID):
            conversationStore.markCurrentAssistantCompleted(metadata: metadata, fallbackSessionID: fallbackSessionID)
        }
    }

    func metadata(for event: AgentEvent) -> AgentEventMetadata? {
        switch event {
        case .session:
            return nil
        case .sessionRow(_, let metadata),
             .sessionStatus(_, let metadata),
             .sessionContext(_, let metadata),
             .permissionProfileUpdated(_, let metadata),
             .goalUpdated(_, let metadata),
             .goalCleared(let metadata),
             .turnStarted(let metadata),
             .assistantDelta(_, let metadata),
             .messageCompleted(_, let metadata),
             .processItemCompleted(_, _, let metadata),
             .logDelta(_, let metadata),
             .diffUpdated(_, let metadata),
             .approvalRequest(_, let metadata),
             .approvalResolved(let metadata),
             .userInputRequest(_, let metadata),
             .userInputResolved(let metadata, _),
             .turnCompleted(let metadata),
             .warning(_, let metadata),
             .error(_, let metadata):
            return metadata
        case .unknown:
            return nil
        }
    }

    func runtimeNotification(for event: AgentEvent, fallbackSessionID: SessionID) -> SessionRuntimeNotification? {
        switch event {
        case .approvalRequest(let request, let metadata):
            let sessionID = metadata.sessionID ?? fallbackSessionID
            return SessionRuntimeNotification(
                id: "approval:\(sessionID):\(request.id)",
                sessionID: sessionID,
                title: L10n.text("ui.waiting_for_approval"),
                body: L10n.format("ui.labeled_value", sessionDisplayTitle(sessionID: sessionID), request.title),
                kind: .approval
            )
        case .userInputRequest(let request, let metadata):
            let sessionID = metadata.sessionID ?? request.threadID
            return SessionRuntimeNotification(
                id: "user-input:\(sessionID):\(request.id)",
                sessionID: sessionID,
                title: L10n.text("ui.waiting_for_additional_information"),
                body: L10n.format("ui.labeled_value", sessionDisplayTitle(sessionID: sessionID), request.title),
                kind: .approval
            )
        case .turnCompleted(let metadata):
            let sessionID = metadata.sessionID ?? fallbackSessionID
            // 还有下一轮待发送时，这只是队列中的中间完成点，不应通知用户“会话已完成”。
            guard queuedRunningTurnsBySessionID[sessionID]?.isEmpty != false else {
                return nil
            }
            let token = metadata.turnID ?? metadata.messageID ?? metadata.seq.map(String.init) ?? "latest"
            let notification: (prefix: String, titleKey: String, kind: SessionRuntimeNotification.Kind)
            switch metadata.turnLifecycle {
            case .failed:
                notification = ("failed", "ui.session_failed", .failed)
            case .interrupted:
                notification = ("stopped", "ui.session_stopped", .completed)
            default:
                notification = ("completed", "ui.session_completed", .completed)
            }
            return SessionRuntimeNotification(
                id: "\(notification.prefix):\(sessionID):\(token)",
                sessionID: sessionID,
                title: L10n.text(notification.titleKey),
                body: sessionDisplayTitle(sessionID: sessionID),
                kind: notification.kind
            )
        case .sessionStatus(let status, let metadata) where status == "failed":
            let sessionID = metadata.sessionID ?? fallbackSessionID
            let token = metadata.turnID ?? metadata.seq.map(String.init) ?? "latest"
            return SessionRuntimeNotification(
                id: "failed:\(sessionID):\(token)",
                sessionID: sessionID,
                title: L10n.text("ui.session_failed"),
                body: sessionDisplayTitle(sessionID: sessionID),
                kind: .failed
            )
        case .error(let payload, let metadata):
            let sessionID = metadata.sessionID ?? fallbackSessionID
            let isClaudeAuthenticationFailure = ClaudeAuthenticationRecovery.matches(payload)
            return SessionRuntimeNotification(
                id: "failed:\(sessionID):\(payload.message)",
                sessionID: sessionID,
                title: isClaudeAuthenticationFailure
                    ? ClaudeAuthenticationRecovery.title
                    : L10n.text("ui.session_error"),
                body: isClaudeAuthenticationFailure
                    ? ClaudeAuthenticationRecovery.recoveryMessage
                    : payload.message,
                kind: .failed
            )
        default:
            return nil
        }
    }

    func sessionDisplayTitle(sessionID: SessionID) -> String {
        if let title = sessionsByID[sessionID]?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return L10n.text("ui.current_session")
    }

    func recordEventWatermark(_ metadata: AgentEventMetadata, fallbackSessionID: SessionID) {
        guard let seq = metadata.seq else {
            return
        }
        let sessionID = metadata.sessionID ?? fallbackSessionID
        if let last = lastSeenEventSeqBySessionID[sessionID], seq <= last {
            return
        }
        lastSeenEventSeqBySessionID[sessionID] = seq
    }

    func recordHistorySnapshotSeq(_ seq: EventSequence?, sessionID: SessionID) {
        guard let seq else {
            return
        }
        if let last = historySnapshotSeqBySessionID[sessionID], seq <= last {
            return
        }
        historySnapshotSeqBySessionID[sessionID] = seq
    }

    func recordRuntimeActivity(for event: AgentEvent, fallbackSessionID: SessionID) {
        let now = Date()
        switch event {
        case .turnStarted(let metadata):
            let sessionID = metadata.sessionID ?? fallbackSessionID
            recordRuntimeActivity(sessionID: sessionID, turnStartedAt: metadata.createdAt ?? now, activityAt: now)
        case .assistantDelta(_, let metadata),
             .messageCompleted(_, let metadata),
             .processItemCompleted(_, _, let metadata),
             .logDelta(_, let metadata),
             .diffUpdated(_, let metadata),
             .approvalRequest(_, let metadata),
             .approvalResolved(let metadata),
             .userInputRequest(_, let metadata),
             .userInputResolved(let metadata, _),
             .warning(_, let metadata):
            recordRuntimeActivity(sessionID: metadata.sessionID ?? fallbackSessionID, activityAt: now)
        case .turnCompleted(let metadata):
            clearRuntimeActivity(sessionID: metadata.sessionID ?? fallbackSessionID)
        case .sessionStatus(let status, let metadata):
            guard let sessionID = metadata.sessionID else {
                return
            }
            if Self.isRunningStatus(status), runtimeActivityBySessionID[sessionID] != nil {
                recordRuntimeActivity(sessionID: sessionID, activityAt: now)
            } else if !Self.isRunningStatus(status) {
                clearRuntimeActivity(sessionID: sessionID)
            }
        case .error(_, let metadata):
            clearRuntimeActivity(sessionID: metadata.sessionID ?? fallbackSessionID)
        case .session(let session):
            syncRuntimeActivity(with: session)
        case .sessionRow(let row, _):
            syncRuntimeActivity(with: AgentSession(row: row))
        case .sessionContext, .permissionProfileUpdated, .goalUpdated, .goalCleared, .unknown:
            return
        }
    }

    func recordRuntimeActivity(
        sessionID: SessionID,
        turnStartedAt: Date? = nil,
        activityAt: Date
    ) {
        let existing = runtimeActivityBySessionID[sessionID]
        let resolvedStart = turnStartedAt ?? existing?.turnStartedAt ?? activityAt
        let next = RuntimeActivitySnapshot(turnStartedAt: resolvedStart, lastActivityAt: activityAt)
        if let existing, existing.turnStartedAt == resolvedStart {
            let elapsed = activityAt.timeIntervalSince(existing.lastActivityAt)
            // 流式事件可能几十毫秒一次。活动时间只用于“仍在运行”的视觉提示，
            // 合并短间隔更新可避免 Debug/-Onone 下反复刷新整棵 SessionStore 观察树。
            if elapsed >= 0, elapsed < 1 {
                return
            }
        }
        guard existing != next else {
            return
        }
        runtimeActivityBySessionID[sessionID] = next
    }

    func syncRuntimeActivity(with session: AgentSession) {
        guard session.isRunning else {
            clearRuntimeActivity(sessionID: session.id)
            return
        }
        guard session.activeTurnID != nil, runtimeActivityBySessionID[session.id] == nil else {
            return
        }
        let activityAt = session.updatedAt ?? Date()
        // 列表/快照只告诉我们“有活跃 turn”，不保证携带 turn 开始时间；
        // 这里用最近更新时间兜底，让用户至少能看到当前连接是否持续有事件。
        recordRuntimeActivity(sessionID: session.id, turnStartedAt: activityAt, activityAt: activityAt)
    }

    func clearRuntimeActivity(sessionID: SessionID) {
        guard runtimeActivityBySessionID[sessionID] != nil else {
            return
        }
        runtimeActivityBySessionID.removeValue(forKey: sessionID)
    }

    static func isRunningStatus(_ status: String?) -> Bool {
        switch status {
        case .some(SessionStatus.running.rawValue),
             .some(SessionStatus.waitingForApproval.rawValue),
             .some(SessionStatus.waitingForInput.rawValue):
            return true
        default:
            return false
        }
    }

    func isNoOpHistorySelection(_ session: AgentSession) -> Bool {
        // 历史会话的稳态是"已订阅事件 + 已加载缓存"；重复点选同一会话时不再重建连接、
        // 也不重复静默刷新（订阅本身会把新内容推进来）。
        selectedSessionID == session.id
            && selectedProjectID == session.projectID
            && !session.isRunning
            && conversationStore.hasLoadedHistory(sessionID: session.id)
            && errorMessage == nil
            && connectedSessionID == session.id
            && webSocket != nil
            && webSocketStatus == .connected
    }

    func setProjectsIfChanged(_ value: [AgentProject]) {
        guard projects != value else {
            return
        }
        projects = value
    }

    func setRecentWorkspacesIfChanged(_ value: [AgentWorkspace]) {
        guard recentWorkspaces != value else {
            return
        }
        recentWorkspaces = value
    }

    func setManagedWorktreesIfChanged(_ value: [WorktreeListItem]) {
        guard managedWorktrees != value else {
            return
        }
        managedWorktrees = value
    }

    func setSidebarProjectsIfChanged(_ value: [AgentProject]) {
        guard sidebarProjects != value else {
            return
        }
        sidebarProjects = value

        var byID: [String: AgentProject] = [:]
        byID.reserveCapacity(value.count)
        for project in value {
            byID[project.id] = project
        }
        sidebarProjectsByID = byID
        if let sessionWorkspaceIDs {
            setSessionWorkspaceIDs(sessionWorkspaceIDs)
        }
    }

    func reloadRecentWorkspaces() {
        applyRecentWorkspaceReconciliation(
            recentWorkspaceStore.loadReconciled(
                profileID: appStore.notificationRoutingProfileID,
                legacyEndpoint: appStore.endpoint,
                profiles: appStore.connectionProfiles
            )
        )
        reloadSessionListPreferences()
        reloadHistoryReadStates()
        reloadSessionControlStates()
        reloadSessionReminders()
    }

    /// 最近工作区合并后，所有仍在内存中的 workspace ID 引用必须在同一个 MainActor
    /// 事务里一起迁移。否则卡片虽然去重，当前选择、已加载会话或头像仍会留在旧 ID。
    func applyRecentWorkspaceReconciliation(
        _ reconciliation: RecentWorkspaceReconciliation
    ) {
        let replacements = reconciliation.replacedWorkspaceIDs
        let previousSessionWorkspaceIDs = sessionWorkspaceIDs.map {
            remappedWorkspaceIDs($0, replacements: replacements)
        }
        let previousSelectedProjectID = selectedProjectID.map {
            replacements[$0] ?? $0
        }
        let migratedExpandedProjectIDs = remappedWorkspaceIDs(
            expandedProjectIDs,
            replacements: replacements
        )
        let migratedShowingAllProjectIDs = remappedWorkspaceIDs(
            showingAllSessionProjectIDs,
            replacements: replacements
        )
        let migratedVisibleLimits = remappedWorkspaceValues(
            sessionVisibleLimitByProjectID,
            replacements: replacements
        )

        for (oldID, newID) in replacements.sorted(by: { $0.key < $1.key }) {
            let chainedOldIDs = workspaceIdentityReplacementByOldID.compactMap {
                existingOldID,
                existingNewID in
                existingNewID == oldID ? existingOldID : nil
            }
            for chainedOldID in chainedOldIDs {
                workspaceIdentityReplacementByOldID[chainedOldID] = newID
            }
            workspaceIdentityReplacementByOldID[oldID] = newID
            workspaceAppearanceStore.migrateProjectIdentity(
                profileID: appStore.notificationRoutingProfileID,
                from: oldID,
                to: newID
            )
        }

        setRecentWorkspacesIfChanged(reconciliation.workspaces)
        guard !replacements.isEmpty else {
            return
        }

        setSelectedProjectID(previousSelectedProjectID)
        setExpandedProjectIDs(migratedExpandedProjectIDs)
        setShowingAllSessionProjectIDs(migratedShowingAllProjectIDs)
        sessionVisibleLimitByProjectID = migratedVisibleLimits.filter {
            migratedShowingAllProjectIDs.contains($0.key)
        }
        setSessionWorkspaceIDs(previousSessionWorkspaceIDs)

        unavailableWorkspaceIDs = remappedWorkspaceIDs(
            unavailableWorkspaceIDs,
            replacements: replacements
        )
        sessionPageCursorByProjectID = remappedWorkspaceValues(
            sessionPageCursorByProjectID,
            replacements: replacements
        )
        sessionHasMoreByProjectID = remappedWorkspaceValues(
            sessionHasMoreByProjectID,
            replacements: replacements
        )
        sessionProjectsWithAdditionalPages = remappedWorkspaceIDs(
            sessionProjectsWithAdditionalPages,
            replacements: replacements
        )

        // 旧 identity 下正在进行的列表请求不能改名后继续回写；取消并丢弃即可，
        // 随后的显式 open/refresh 会针对保留 ID 建立新请求。
        for oldID in replacements.keys {
            sessionPageRequestTokenByProjectID.removeValue(forKey: oldID)
            sessionPageLoadingTokenByProjectID.removeValue(forKey: oldID)
            sessionFirstPageLoadingConsistencyByProjectID.removeValue(forKey: oldID)
            sessionFirstPageWaiterCountByProjectID.removeValue(forKey: oldID)
            sessionListReconciliationTasksByProjectID.removeValue(forKey: oldID)?.cancel()
        }
        let obsoleteFirstPageRequestKeys = sessionListFirstPageInFlightByKey.keys.filter {
            replacements[$0.workspaceID] != nil
        }
        for key in obsoleteFirstPageRequestKeys {
            sessionListFirstPageInFlightByKey[key]?.task.cancel()
            sessionListFirstPageInFlightByKey.removeValue(forKey: key)
        }
        sessionListFirstPageCacheByKey = sessionListFirstPageCacheByKey.filter {
            replacements[$0.key.workspaceID] == nil
        }
        let retainedWorkspaceCompletions = workspaceSessionFirstPageCompletionByKey.filter {
            replacements[$0.key.workspaceID] == nil
        }
        if retainedWorkspaceCompletions != workspaceSessionFirstPageCompletionByKey {
            workspaceSessionFirstPageCompletionByKey = retainedWorkspaceCompletions
        }

        let workspacesByID = Dictionary(
            uniqueKeysWithValues: reconciliation.workspaces.map { ($0.id, $0) }
        )
        let migratedSessions = sessions.map { item in
            guard let newID = replacements[item.projectID],
                  let workspace = workspacesByID[newID] else {
                return item
            }
            return session(item, in: workspace)
        }
        if migratedSessions != sessions {
            sessions = migratedSessions
        }

        let migratedRemoteSessions = remoteSessionSearchResults.map { item in
            guard let newID = replacements[item.projectID],
                  let workspace = workspacesByID[newID] else {
                return item
            }
            return session(item, in: workspace)
        }
        if migratedRemoteSessions != remoteSessionSearchResults {
            remoteSessionSearchResults = migratedRemoteSessions
        }

        missingRunningSessionStateByID = missingRunningSessionStateByID.mapValues { state in
            MissingRunningSessionState(
                projectID: replacements[state.projectID] ?? state.projectID,
                consecutiveRefreshMisses: state.consecutiveRefreshMisses
            )
        }
    }

    func retainedWorkspaceID(for workspaceID: String) -> String {
        workspaceIdentityReplacementByOldID[workspaceID] ?? workspaceID
    }

    func reloadSessionListPreferences() {
        let preferences = sessionListPreferenceStore.load(
            profileID: appStore.notificationRoutingProfileID,
            legacyEndpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
        // 冷启动升级时 recent workspace 会先完成去重，筛选偏好随后才读取。
        // 在校验有效 ID 前先迁移，否则旧 ID 会被误判为已删除并静默丢失。
        let migratedSessionWorkspaceIDs = preferences.sessionWorkspaceIDs.map { workspaceIDs in
            Set(workspaceIDs.map(retainedWorkspaceID))
        }
        let loadedSessionWorkspaceIDs = normalizedSessionWorkspaceIDs(migratedSessionWorkspaceIDs)
        guard pinnedSessionIDs != preferences.pinnedSessionIDs
            || archivedSessionIDs != preferences.archivedSessionIDs
            || sessionWorkspaceIDs != loadedSessionWorkspaceIDs
        else {
            return
        }
        pinnedSessionIDs = preferences.pinnedSessionIDs
        archivedSessionIDs = preferences.archivedSessionIDs
        sessionWorkspaceIDs = loadedSessionWorkspaceIDs
        if loadedSessionWorkspaceIDs != preferences.sessionWorkspaceIDs {
            saveSessionListPreferences()
        }
        rebuildSessionIndexes()
    }

    func saveSessionListPreferences() {
        let profileID = appStore.notificationRoutingProfileID
        var preferences = SessionListPreferences(
            pinnedSessionIDs: pinnedSessionIDs,
            archivedSessionIDs: archivedSessionIDs,
            sessionWorkspaceIDs: sessionWorkspaceIDs
        )
        // 远端归档在内存中先乐观展示，但磁盘只能保存服务端已确认状态。
        // 这里逐个还原当前 Profile 的 pending 快照，避免其他偏好保存把乐观值泄漏到重启状态。
        for (key, mutation) in sessionArchiveMutationsByKey where key.profileID == profileID {
            if mutation.before.isPinned {
                preferences.pinnedSessionIDs.insert(key.sessionID)
            } else {
                preferences.pinnedSessionIDs.remove(key.sessionID)
            }
            if mutation.before.isArchived {
                preferences.archivedSessionIDs.insert(key.sessionID)
            } else {
                preferences.archivedSessionIDs.remove(key.sessionID)
            }
        }
        sessionListPreferenceStore.save(
            preferences,
            profileID: profileID
        )
    }

    func reloadHistoryReadStates() {
        let loaded = sessionHistoryReadStateStore.load(
            profileID: appStore.notificationRoutingProfileID,
            legacyEndpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
        if historyReadStateBySessionID != loaded {
            historyReadStateBySessionID = loaded
        }
        synchronizeHistoryReadStates()
    }

    /// 把会话快照归并到本机已读水位。初次见到的旧历史直接建立已读基线，避免升级后
    /// 所有旧会话一起亮点；只有观察到运行结束或稳定完成版本变化时才产生未读。
    func synchronizeHistoryReadStates() {
        var next = historyReadStateBySessionID
        var didChange = false
        // 同一份 sessions 快照里的完成共享观察时间，避免循环顺序制造虚假的先后关系。
        lazy var snapshotCompletionObservedAt = sessionListNow()

        for session in sessions where !session.isLocalDraft {
            var state = next[session.id] ?? SessionHistoryReadState()
            let previousState = state

            if session.isRunning {
                state.observedRunning = true
                // 新一轮运行开始后，上一轮“刚完成”立即失效；终态快照不完整时也不能让旧时间重新泄漏。
                state.completionObservedAt = nil
                if let activeTurnID = normalizedCompletionTurnID(session.activeTurnID) {
                    state.pendingTurnID = activeTurnID
                }
            } else {
                let completedAfterObservedRunning = state.observedRunning
                let version = SessionCompletionVersion(
                    session: session,
                    completedTurnID: completedAfterObservedRunning ? state.pendingTurnID : nil
                )
                guard version.hasStableSignal else {
                    continue
                }

                if let latest = state.latestCompletion {
                    if latest.representsSameCompletion(as: version) {
                        let wasRead = state.readCompletion?.representsSameCompletion(as: latest) == true
                        let wasManuallyUnread = state.manualUnreadCompletion?
                            .representsSameCompletion(as: latest) == true
                        let merged = latest.merging(version)
                        state.latestCompletion = merged
                        if wasManuallyUnread {
                            state.manualUnreadCompletion = merged
                            state.readCompletion = nil
                        } else if selectedSessionID == session.id || wasRead {
                            state.readCompletion = merged
                        }
                        if completedAfterObservedRunning {
                            // running → terminal 本身就是可靠完成事件；即使轻量快照尚未推进版本字段，
                            // 也只在这次转换上记录一次，不让后续普通轮询刷新时间。
                            state.completionObservedAt = snapshotCompletionObservedAt
                        }
                    } else {
                        state.latestCompletion = version
                        state.manualUnreadCompletion = nil
                        // 冷启动或离线期间只能确认“版本不同”，无法确认它刚刚完成；
                        // 没观察到运行态就明确清空，避免把旧结果放进刚完成。
                        state.completionObservedAt = completedAfterObservedRunning
                            ? snapshotCompletionObservedAt
                            : nil
                        if selectedSessionID == session.id {
                            state.readCompletion = version
                        }
                    }
                } else {
                    state.latestCompletion = version
                    state.manualUnreadCompletion = nil
                    // 旧历史首次进入索引时视为已读；从已观察运行态进入终态才是新结果。
                    state.completionObservedAt = completedAfterObservedRunning
                        ? snapshotCompletionObservedAt
                        : nil
                    if !completedAfterObservedRunning || selectedSessionID == session.id {
                        state.readCompletion = version
                    }
                }
                state.observedRunning = false
                state.pendingTurnID = nil
            }

            if state != previousState {
                next[session.id] = state
                didChange = true
            }
        }

        if didChange {
            historyReadStateBySessionID = next
            sessionHistoryReadStateStore.save(
                next,
                profileID: appStore.notificationRoutingProfileID
            )
        }
        publishUnreadHistorySessionIDs(from: next)
        publishHistoryCompletionObservedAtBySessionID(from: next)
    }

    func isHistorySessionUnread(_ session: AgentSession) -> Bool {
        !session.isRunning
            && !session.isLocalDraft
            && unreadHistorySessionIDs.contains(session.id)
    }

    func canChangeHistoryReadState(_ session: AgentSession) -> Bool {
        !session.isRunning
            && !session.isLocalDraft
            && historyReadStateBySessionID[session.id]?.latestCompletion != nil
    }

    func markHistorySessionRead(_ sessionID: SessionID) {
        guard let session = sessionsByID[sessionID],
              !session.isRunning,
              !session.isLocalDraft else {
            return
        }
        synchronizeHistoryReadStates()
        guard var state = historyReadStateBySessionID[sessionID],
              let latest = state.latestCompletion,
              state.readCompletion?.representsSameCompletion(as: latest) != true else {
            return
        }
        state.readCompletion = latest
        state.manualUnreadCompletion = nil
        historyReadStateBySessionID[sessionID] = state
        sessionHistoryReadStateStore.save(
            historyReadStateBySessionID,
            profileID: appStore.notificationRoutingProfileID
        )
        publishUnreadHistorySessionIDs(from: historyReadStateBySessionID)
    }

    /// “标为未读”回退的是持久化 completion 已读水位，而不是直接修改派生 Set。
    /// 因此后续刷新、重启和同一完成版本的重复快照都会保持未读语义。
    func markHistorySessionUnread(_ sessionID: SessionID) {
        guard let session = sessionsByID[sessionID],
              !session.isRunning,
              !session.isLocalDraft else {
            return
        }
        synchronizeHistoryReadStates()
        guard var state = historyReadStateBySessionID[sessionID],
              state.latestCompletion != nil,
              state.readCompletion != nil else {
            return
        }
        state.readCompletion = nil
        state.manualUnreadCompletion = state.latestCompletion
        historyReadStateBySessionID[sessionID] = state
        sessionHistoryReadStateStore.save(
            historyReadStateBySessionID,
            profileID: appStore.notificationRoutingProfileID
        )
        publishUnreadHistorySessionIDs(from: historyReadStateBySessionID)
    }

    private func publishUnreadHistorySessionIDs(
        from states: [SessionID: SessionHistoryReadState]
    ) {
        let visibleUnreadIDs = Set(sessions.lazy.compactMap { session -> SessionID? in
            guard !session.isRunning,
                  !session.isLocalDraft,
                  states[session.id]?.isUnread == true else {
                return nil
            }
            return session.id
        })
        setUnreadHistorySessionIDs(visibleUnreadIDs)
    }

    private func publishHistoryCompletionObservedAtBySessionID(
        from states: [SessionID: SessionHistoryReadState]
    ) {
        var visibleCompletionDates: [SessionID: Date] = [:]
        visibleCompletionDates.reserveCapacity(sessions.count)
        for session in sessions {
            guard !session.isRunning,
                  !session.isLocalDraft,
                  let observedAt = states[session.id]?.completionObservedAt else {
                continue
            }
            // 数据合并层理论上已按 ID 去重；这里仍使用下标覆盖，避免异常重复快照触发字典构造崩溃。
            visibleCompletionDates[session.id] = observedAt
        }
        setHistoryCompletionObservedAtBySessionID(visibleCompletionDates)
    }

    private func normalizedCompletionTurnID(_ value: TurnID?) -> TurnID? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    func setSessionWorkspaceIDs(_ value: Set<String>?) {
        let normalized = normalizedSessionWorkspaceIDs(value)
        guard sessionWorkspaceIDs != normalized else {
            return
        }
        sessionWorkspaceIDs = normalized
        saveSessionListPreferences()
        rebuildProjectSessionListSnapshots()
        reconcileSelectedProjectAfterSessionWorkspaceChange()
    }

    func normalizedSessionWorkspaceIDs(_ value: Set<String>?) -> Set<String>? {
        let validProjectIDs = Set(sidebarProjects.map(\.id))
        guard let value else {
            return nil
        }
        // SessionStore 初始化时 recent workspaces 尚未加载；此时不能把持久化筛选当作
        // 无效 ID 清空。等工作区索引就绪后再做交集和“全选 = nil”归一化。
        guard !validProjectIDs.isEmpty else {
            return value.isEmpty ? nil : value
        }
        let selectedIDs = value.intersection(validProjectIDs)
        // 全选和默认显示全部是同一个语义，归一成 nil，避免 UI 出现多余的“恢复全部显示”按钮。
        return selectedIDs == validProjectIDs ? nil : selectedIDs
    }

    func reconcileSelectedProjectAfterSessionWorkspaceChange() {
        guard let selectedProjectID,
              !isWorkspaceShownInSessions(selectedProjectID),
              selectedSessionID == nil
        else {
            return
        }
        setSelectedProjectID(sessionSidebarProjects.first?.id)
        setSelectedSessionID(nil)
        disconnectWebSocket()
    }

    func reloadSessionControlStates() {
        let states = sessionControlStateStore.load(
            profileID: appStore.notificationRoutingProfileID,
            legacyEndpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
        guard sessionControlStateByID != states else {
            return
        }
        sessionControlStateByID = states
    }

    func saveSessionControlStates() {
        sessionControlStateStore.save(
            sessionControlStateByID,
            profileID: appStore.notificationRoutingProfileID
        )
    }

    func setSessionControlState(_ state: SessionControlState, sessionID: SessionID) {
        guard sessionControlStateByID[sessionID] != state else {
            return
        }
        sessionControlStateByID[sessionID] = state
        saveSessionControlStates()
    }

    func reloadSessionReminders() {
        let loaded = sessionReminderStore.load(
            profileID: appStore.notificationRoutingProfileID,
            legacyEndpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
        let now = sessionReminderNow()
        var reminders: [SessionID: SessionReminder] = [:]
        reminders.reserveCapacity(loaded.count)
        var expiredSessionIDs: [SessionID] = []
        for (sessionID, reminder) in loaded {
            if reminder.isDue(now: now) {
                expiredSessionIDs.append(sessionID)
            } else {
                reminders[sessionID] = reminder
            }
        }
        if reminders != loaded {
            // 提醒触发后只需在加载/回前台时收敛持久化状态；不为精确秒级 UI 增加后台 timer。
            sessionReminderStore.save(
                reminders,
                profileID: appStore.notificationRoutingProfileID
            )
            for sessionID in expiredSessionIDs {
                sessionReminderScheduler.cancel(
                    sessionID: sessionID,
                    profileID: appStore.notificationRoutingProfileID
                )
            }
        }
        guard sessionRemindersByID != reminders else {
            return
        }
        sessionRemindersByID = reminders
    }

    func saveSessionReminders() {
        sessionReminderStore.save(
            sessionRemindersByID,
            profileID: appStore.notificationRoutingProfileID
        )
    }

    func clearSessionReminders(forProjectID projectID: String) {
        let sessionIDs = sessions
            .filter { $0.projectID == projectID }
            .map(\.id)
        guard !sessionIDs.isEmpty else {
            return
        }
        for sessionID in sessionIDs {
            sessionRemindersByID.removeValue(forKey: sessionID)
            sessionReminderScheduler.cancel(
                sessionID: sessionID,
                profileID: appStore.notificationRoutingProfileID
            )
        }
        saveSessionReminders()
    }

    @discardableResult
    func rememberWorkspace(
        _ workspace: AgentWorkspace,
        equivalentPaths: [String] = [],
        prefersIncomingIdentity: Bool = true
    ) -> AgentWorkspace {
        let reconciliation = recentWorkspaceStore.upsertReconciled(
            workspace,
            profileID: appStore.notificationRoutingProfileID,
            equivalentPaths: equivalentPaths,
            prefersIncomingIdentity: prefersIncomingIdentity
        )
        applyRecentWorkspaceReconciliation(reconciliation)

        let matchingPaths = Set(
            ([workspace.path] + equivalentPaths)
                .map(WorkspacePathIdentity.normalizedPath)
        )
        return reconciliation.workspaces.first {
            $0.id == workspace.id
                || matchingPaths.contains(WorkspacePathIdentity.normalizedPath($0.path))
        } ?? workspace
    }

    func upsertManagedWorktree(_ item: WorktreeListItem) {
        var next = managedWorktrees.filter { $0.id != item.id }
        next.insert(item, at: 0)
        setManagedWorktreesIfChanged(next)
    }

    func normalizedWorktreeCleanupPath(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func forgetManagedWorktreeAfterDeletion(_ workspace: AgentWorkspace) {
        forgetWorkspaceAfterWorktreeDeletion(workspace)
        gitStatusByPath.removeValue(forKey: workspace.path)
        gitStatusErrorByPath.removeValue(forKey: workspace.path)
        workspaceGitSummaryByPath.removeValue(forKey: workspace.path)
        workspaceGitSummaryUpdatedAtByPath.removeValue(forKey: workspace.path)
        refreshingWorkspaceGitSummaryPaths.remove(workspace.path)
        gitActionErrorByPath.removeValue(forKey: workspace.path)
        commandActionsByPath.removeValue(forKey: workspace.path)
        commandActionErrorByPath.removeValue(forKey: workspace.path)
        commandActionResultByPath.removeValue(forKey: workspace.path)
        commandActionHistoryByPath.removeValue(forKey: workspace.path)
        queuedCommandActionRuns.removeAll { $0.path == workspace.path }
        queuedCommandActionIDsByPath.removeValue(forKey: workspace.path)
        worktreeBranchesByPath.removeValue(forKey: workspace.path)
        worktreeBranchErrorByPath.removeValue(forKey: workspace.path)
        pullRequestURLByPath.removeValue(forKey: workspace.path)
        pullRequestStatusByPath.removeValue(forKey: workspace.path)
        pullRequestStatusErrorByPath.removeValue(forKey: workspace.path)
    }

    func forgetWorkspaceAfterWorktreeDeletion(_ workspace: AgentWorkspace) {
        let project = workspace.project
        let next = recentWorkspaceStore.forget(
            id: project.id,
            profileID: appStore.notificationRoutingProfileID
        )
        setRecentWorkspacesIfChanged(next)
        removeExpandedProjectID(project.id)
        removeShowingAllSessionProjectID(project.id)
        sessionPageCursorByProjectID.removeValue(forKey: project.id)
        sessionHasMoreByProjectID.removeValue(forKey: project.id)
        sessionProjectsWithAdditionalPages.remove(project.id)
        sessionPageRequestTokenByProjectID.removeValue(forKey: project.id)
        sessionPageLoadingTokenByProjectID.removeValue(forKey: project.id)
        sessionFirstPageLoadingConsistencyByProjectID.removeValue(forKey: project.id)
        sessionFirstPageWaiterCountByProjectID.removeValue(forKey: project.id)
        let retainedWorkspaceCompletions = workspaceSessionFirstPageCompletionByKey.filter {
            $0.key.workspaceID != project.id
        }
        if retainedWorkspaceCompletions != workspaceSessionFirstPageCompletionByKey {
            workspaceSessionFirstPageCompletionByKey = retainedWorkspaceCompletions
        }
        clearSessionReminders(forProjectID: project.id)
        sessions = sessions.filter { $0.projectID != project.id }
        clearWorkspaceUnavailable(project.id)
        if selectedProjectID == project.id {
            _ = commitSelection(
                projectID: nil,
                sessionID: nil,
                reason: .invalidation
            )
            disconnectWebSocket()
        }
    }

    func ensureWorkspace(for project: AgentProject) -> AgentWorkspace {
        if let workspace = workspacesByID[project.id] {
            return workspace
        }
        let workspace = AgentWorkspace(project: project)
        return rememberWorkspace(workspace, prefersIncomingIdentity: false)
    }

    func ensureWorkspaceForKnownProjectID(_ projectID: String) -> AgentWorkspace? {
        if let workspace = workspacesByID[projectID] {
            return workspace
        }
        if let project = sidebarProjectsByID[projectID] ?? projectsByID[projectID] {
            return ensureWorkspace(for: project)
        }
        return nil
    }

    enum WorkspaceAvailability {
        case available
        case unavailable(String)
        case indeterminate
    }

    // 会话加载失败时，用 resolve 复核这个工作区到底是“真没了”还是“暂时连不上”：
    // - resolve 成功 → 路径仍在 allowlist 内，原失败多半是网关冷启动等瞬时问题。
    // - resolve 返回 4xx → agentd 明确判定路径不可用（被删 / 掉出 allowlist）。
    // - resolve 抛传输层错误（连不上 agentd） → 无法判定，按瞬时处理，不冤枉标记。
    func evaluateWorkspaceAvailability(_ workspace: AgentWorkspace) async -> WorkspaceAvailability {
        do {
            let client = try clientFactory()
            _ = try await client.resolveWorkspace(path: workspace.path)
            return .available
        } catch let error as AgentAPIError {
            if case let .server(status, _) = error, (400..<500).contains(status) {
                return .unavailable(L10n.format("ui.value_is_no_longer_allowed_or_has_been", workspace.name))
            }
            return .indeterminate
        } catch {
            return .indeterminate
        }
    }

    func handleWorkspaceLoadFailure(
        workspace: AgentWorkspace,
        error: Error,
        reportForeground: Bool = true
    ) async {
        // 页面生命周期、凭据后台挂起和旧 host waiter 的取消都不是工作区故障；
        // 这里必须先静默收口，不能二次 resolve 后把 Swift.CancellationError 写入全局错误。
        guard !isCancellationError(error) else {
            return
        }
        if terminateConnectionIfCredentialsInvalid(error) {
            return
        }
        if let policyFailure = sessionListPolicyFailure(from: error) {
            registerSessionListCooldown(policyFailure, for: workspace)
            let message = L10n.plural(
                "ui.session_list_retry_seconds_count",
                count: policyFailure.retryAfterSeconds
            )
            guard reportForeground else { return }
            if sessions(forProjectID: workspace.id).isEmpty {
                // 首屏还没有可展示数据时保留一个友好错误标记，让 bootstrap 按 cooldown 继续自愈。
                setStatusMessage(message)
                setErrorMessage(message)
            } else {
                // 已有列表时继续展示旧数据，同时给出准确等待时间；不能让旧缓存看起来像已刷新成功。
                setStatusMessage(message)
                setErrorMessage(nil)
            }
            return
        }
        switch await evaluateWorkspaceAvailability(workspace) {
        case .unavailable(let message):
            markWorkspaceUnavailable(workspace.id)
            // 明确的不可用态：清掉全局错误，bootstrap 的退避重试不再死磕一个已失效的目录。
            if reportForeground {
                setErrorMessage(nil)
                setStatusMessage(message)
            }
        case .available, .indeterminate:
            clearWorkspaceUnavailable(workspace.id)
            if reportForeground {
                setErrorMessage(error.localizedDescription)
            }
        }
    }

    func markWorkspaceUnavailable(_ id: String) {
        guard !unavailableWorkspaceIDs.contains(id) else {
            return
        }
        unavailableWorkspaceIDs.insert(id)
    }

    func clearWorkspaceUnavailable(_ id: String) {
        guard unavailableWorkspaceIDs.contains(id) else {
            return
        }
        unavailableWorkspaceIDs.remove(id)
    }

    func sessionForExplicitSelection(_ item: AgentSession) -> AgentSession {
        if let workspace = workspaceForSession(item) {
            let aligned = session(item, in: workspace)
            upsert(aligned)
            return aligned
        }
        if let project = sidebarProjectsByID[item.projectID] ?? projectsByID[item.projectID] {
            let workspace = ensureWorkspace(for: project)
            let aligned = session(item, in: workspace)
            upsert(aligned)
            return aligned
        }
        let aligned = alignSessionToKnownWorkspace(item)
        upsert(aligned)
        return aligned
    }

    func setExpandedProjectIDs(_ value: Set<String>) {
        guard expandedProjectIDs != value else {
            return
        }
        expandedProjectIDs = value
        rebuildProjectSessionListSnapshots()
    }

    func insertExpandedProjectID(_ value: String) {
        guard !expandedProjectIDs.contains(value) else {
            return
        }
        expandedProjectIDs.insert(value)
        rebuildProjectSessionListSnapshot(forProjectID: value)
    }

    func removeExpandedProjectID(_ value: String) {
        guard expandedProjectIDs.contains(value) else {
            return
        }
        expandedProjectIDs.remove(value)
        rebuildProjectSessionListSnapshot(forProjectID: value)
    }

    func revealProjectInSidebar(_ projectID: String) {
        // 选中历史会话、恢复前台或 create 成功后，只展开所属项目这一支。
        // snapshot 按项目增量重建，避免右侧高频会话内容变化时牵动整个侧栏列表。
        insertExpandedProjectID(projectID)
    }

    func setShowingAllSessionProjectIDs(_ value: Set<String>) {
        guard showingAllSessionProjectIDs != value else {
            return
        }
        showingAllSessionProjectIDs = value
        sessionVisibleLimitByProjectID = sessionVisibleLimitByProjectID.filter { value.contains($0.key) }
        rebuildProjectSessionListSnapshots()
    }

    func insertShowingAllSessionProjectID(_ value: String) {
        setSessionVisibleLimit(Self.sessionPreviewLimit + Self.sessionExpansionStep, forProjectID: value)
    }

    func removeShowingAllSessionProjectID(_ value: String) {
        setSessionVisibleLimit(nil, forProjectID: value)
    }

    func sessionVisibleLimit(forProjectID projectID: String) -> Int {
        max(Self.sessionPreviewLimit, sessionVisibleLimitByProjectID[projectID] ?? Self.sessionPreviewLimit)
    }

    func setSessionVisibleLimit(_ limit: Int?, forProjectID projectID: String) {
        let normalized = limit.map { max(Self.sessionPreviewLimit, $0) }
        let current = sessionVisibleLimitByProjectID[projectID]
        let next = normalized.flatMap { $0 > Self.sessionPreviewLimit ? $0 : nil }
        guard current != next else {
            return
        }
        if let next {
            sessionVisibleLimitByProjectID[projectID] = next
            showingAllSessionProjectIDs.insert(projectID)
        } else {
            sessionVisibleLimitByProjectID.removeValue(forKey: projectID)
            showingAllSessionProjectIDs.remove(projectID)
        }
        rebuildProjectSessionListSnapshot(forProjectID: projectID)
    }

    func currentSelectionLease() -> SessionSelectionLease {
        SessionSelectionLease(
            hostScope: appStore.activeHostScope,
            generation: selectionGeneration,
            projectID: selectedProjectID,
            sessionID: selectedSessionID
        )
    }

    func isSelectionLeaseCurrent(_ lease: SessionSelectionLease) -> Bool {
        lease == currentSelectionLease()
    }

    /// 为“点击通知后加载”“创建 Worktree 后打开”等延迟导航预留一次意图。
    /// 后续任何用户选择都会推进代次，使旧请求完成时无法再提交导航。
    @discardableResult
    func reserveSelectionIntent() -> SessionSelectionLease {
        selectionGeneration &+= 1
        return currentSelectionLease()
    }

    @discardableResult
    func commitSelection(
        projectID: String?,
        sessionID: SessionID?,
        reason: SessionSelectionCommit.Reason,
        ifCurrent lease: SessionSelectionLease? = nil
    ) -> SessionSelectionLease? {
        if let lease, !isSelectionLeaseCurrent(lease) {
            return nil
        }

        selectionGeneration &+= 1
        if selectedProjectID != projectID {
            selectedProjectID = projectID
        }
        if selectedSessionID != sessionID {
            selectedSessionID = sessionID
        }
        let committedLease = currentSelectionLease()
        lastSelectionCommit = SessionSelectionCommit(
            sequence: committedLease.generation,
            projectID: projectID,
            sessionID: sessionID,
            reason: reason
        )
        return committedLease
    }

    /// optimistic/resume ID 只能替换自己持有的当前选择。数据迁移不依赖该结果，
    /// 因而用户已经切走时仍可完成后台归档，但不会抢回页面或 WebSocket。
    @discardableResult
    func replaceSelectionIfCurrent(
        from previousID: SessionID,
        to session: AgentSession,
        lease: SessionSelectionLease
    ) -> SessionSelectionLease? {
        guard isSelectionLeaseCurrent(lease),
              selectedSessionID == previousID else {
            return nil
        }
        guard previousID != session.id else {
            return lease
        }
        return commitSelection(
            projectID: session.projectID,
            sessionID: session.id,
            reason: .identityReplacement(previousID: previousID),
            ifCurrent: lease
        )
    }

    func setSelectedProjectID(_ value: String?) {
        guard selectedProjectID != value else {
            return
        }
        selectionGeneration &+= 1
        selectedProjectID = value
    }

    func setSelectedSessionID(_ value: SessionID?) {
        guard selectedSessionID != value else {
            return
        }
        selectionGeneration &+= 1
        selectedSessionID = value
    }

    func setStatusMessage(_ value: String?) {
        guard statusMessage != value else {
            return
        }
        statusMessage = value
    }

    func setErrorMessage(_ value: String?) {
        // active writer 既可能在连接阶段返回，也可能在已连接后的
        // thread/resume / turn/start 发送回调中返回。统一在用户错误出口映射，
        // 避免不同传输路径泄漏原始 -32600 协议错误。
        let userFacingValue: String?
        if let value, Self.isCodexActiveWriterConflict(value) {
            userFacingValue = L10n.text("ui.codex_active_writer_conflict")
        } else {
            userFacingValue = value
        }
        guard errorMessage != userFacingValue else {
            return
        }
        errorMessage = userFacingValue
    }

    func setHistoryLoadProgress(sessionID: SessionID, title: String, fraction: Double) {
        let bounded = min(max(fraction, 0), 1)
        let next = HistoryLoadProgress(sessionID: sessionID, title: title, fraction: bounded)
        guard historyLoadProgressBySessionID[sessionID] != next else {
            return
        }
        historyLoadProgressBySessionID[sessionID] = next
    }

    func clearHistoryLoadProgress(sessionID: SessionID) {
        historyLoadProgressBySessionID.removeValue(forKey: sessionID)
    }

    func setWebSocketStatus(_ value: WebSocketStatus) {
        guard webSocketStatus != value else {
            return
        }
        webSocketStatus = value
    }

    func clearConnectionData() {
        invalidateCarStatusHostObservation()
        controlledGlobalDiscoveryUnavailable = false
        controlledGlobalSessionIDs = []
        stopRelatedSessionObservation()
        networkRecoveryTask?.cancel()
        networkRecoveryTask = nil
        networkSuspendedSessionID = nil
        appLifecycleSuspendedSessionID = nil
        sessionSearchTask?.cancel()
        sessionSearchTask = nil
        sessionSearchGeneration &+= 1
        resetRemoteSessionSearchState()
        // 搜索词属于当前 Mac 的浏览上下文；切换 endpoint 后直接清空，避免新 Mac 展示旧查询却未发首屏请求。
        // didSet 会再次同步失效代次，但空查询只 reset，不会启动异步搜索。
        if !sessionSearchQuery.isEmpty {
            sessionSearchQuery = ""
        }
        // endpoint 切换后 session/project ID 可能重复；旧 Mac 的草稿不能恢复到新连接。
        clearFileUploadsForConnectionChange()
        composerDraftCache.removeAll()
        composerModelSelectionCache.removeAll()
        composerPermissionSelectionCache.removeAll()
        composerSendModeCache.removeAll()
        stopAllQueuedSessionMonitoring()
        queuedRunningTurnsBySessionID.removeAll()
        pendingPermissionTurnBoundariesBySessionID.removeAll()
        permissionTurnRetryRequirementsByClientMessageID.removeAll()
        latestSatisfiedPermissionTurnBoundary = nil
        queuedTurnStartedIDBySessionID.removeAll()
        queuedTurnAwaitingStartSessionIDs.removeAll()
        queuedTurnBlockedCompletionIDBySessionID.removeAll()
        queuedGuidanceDispatchClientMessageIDs.removeAll()
        _ = commitSelection(
            projectID: nil,
            sessionID: nil,
            reason: .invalidation
        )
        setProjectsIfChanged([])
        setRecentWorkspacesIfChanged([])
        workspaceIdentityReplacementByOldID = [:]
        setSidebarProjectsIfChanged([])
        sessionWorkspaceIDs = nil
        // 归档 HTTP 请求没有服务端 generation，连接切换也不能证明旧请求已取消。
        // 保留按 Profile+Session 的 pending，阻止回切同一 Profile 后发出乱序的第二次写入。
        pinnedSessionIDs = []
        archivedSessionIDs = []
        sessionVisibleLimitByProjectID = [:]
        worktreeBranchesByPath = [:]
        worktreeBranchErrorByPath = [:]
        managedWorktrees = []
        worktreeErrorMessage = nil
        isCreatingWorktree = false
        duplicatingSessionIDs = []
        isRefreshingWorktreeBranches = false
        isRefreshingWorktrees = false
        isDeletingWorktree = false
        isPruningWorktrees = false
        gitStatusByPath = [:]
        gitStatusErrorByPath = [:]
        workspaceGitSummaryByPath = [:]
        workspaceGitSummaryUpdatedAtByPath = [:]
        refreshingWorkspaceGitSummaryPaths = []
        gitRefreshTasksByPath.values.forEach { $0.cancel() }
        gitRefreshTasksByPath = [:]
        gitRefreshRevisionByPath = [:]
        isRefreshingGitStatus = false
        gitActionErrorByPath = [:]
        commandActionsByPath = [:]
        commandActionErrorByPath = [:]
        commandActionResultByPath = [:]
        commandActionHistoryByPath = [:]
        queuedCommandActionRuns = []
        queuedCommandActionIDsByPath = [:]
        runningCommandActionPath = nil
        runningCommandActionID = nil
        isRefreshingCommandActions = false
        isRunningGitAction = false
        isCommittingGitChanges = false
        isPushingGitBranch = false
        isQuickPublishingGitChanges = false
        gitQuickPublishResultByPath = [:]
        gitTestFlightStatusByPath = [:]
        gitTestFlightErrorByPath = [:]
        isRefreshingGitTestFlightStatus = false
        isStartingGitTestFlightRelease = false
        pullRequestURLByPath = [:]
        pullRequestStatusByPath = [:]
        pullRequestStatusErrorByPath = [:]
        isCreatingPullRequest = false
        isRefreshingPullRequestStatus = false
        unavailableWorkspaceIDs = []
        sessions = []
        setExpandedProjectIDs([])
        setShowingAllSessionProjectIDs([])
        sessionPageCursorByProjectID = [:]
        sessionHasMoreByProjectID = [:]
        sessionProjectsWithAdditionalPages = []
        sessionPageRequestTokenByProjectID = [:]
        sessionPageLoadingTokenByProjectID = [:]
        sessionFirstPageLoadingConsistencyByProjectID = [:]
        sessionFirstPageWaiterCountByProjectID = [:]
        sessionListFirstPageInFlightByKey.values.forEach { $0.task.cancel() }
        sessionListFirstPageInFlightByKey = [:]
        sessionListFirstPageCacheByKey = [:]
        if !workspaceSessionFirstPageCompletionByKey.isEmpty {
            workspaceSessionFirstPageCompletionByKey = [:]
        }
        sessionListCooldownUntilByBudgetKey = [:]
        sessionLibraryIndexRefreshJob?.task.cancel()
        sessionLibraryIndexRefreshJob = nil
        lastSessionLibraryIndexRefreshAt = nil
        sessionListReconciliationTasksByProjectID.values.forEach { $0.cancel() }
        sessionListReconciliationTasksByProjectID = [:]
        missingRunningSessionReconciliationTasksByID.values.forEach { $0.cancel() }
        missingRunningSessionReconciliationTasksByID = [:]
        missingRunningSessionStateByID = [:]
        historyPreviousCursorBySessionID = [:]
        historyHasMoreBeforeBySessionID = [:]
        historySnapshotSeqBySessionID = [:]
        historyPageRequestTokenBySessionID = [:]
        historyFirstPageInFlightByKey.values.forEach { $0.task.cancel() }
        historyFirstPageInFlightByKey = [:]
        historyFirstPageCacheByKey = [:]
        historyLoadJobsBySessionID.values.forEach { $0.task.cancel() }
        historyLoadJobsBySessionID = [:]
        historyLoadJobTokenBySessionID = [:]
        historyLoadedSignatureBySessionID = [:]
        historyLoadedQualityBySessionID = [:]
        deferredFullHistorySessionIDs = []
        freshEmptyHistorySignatureBySessionID = [:]
        initialHistoryLoadingSessionIDs = []
        historyLoadProgressBySessionID = [:]
        historySavingsNoticesBySessionID = [:]
        loadingEarlierHistorySessionIDs = []
        lastSeenEventSeqBySessionID = [:]
        listProjectionBySessionID = [:]
        recentActivityProjectionBySessionID = [:]
        pendingApprovalDecisionIDsBySessionID = [:]
        pendingUserInputResponseIDsBySessionID = [:]
        pendingUserInputRequestsBySessionID = [:]
        pendingUserInputFormStateCache.resetForSessionChange()
        deliveredRuntimeNotificationIDs = []
        threadGoalErrorMessage = nil
        isUpdatingThreadGoal = false
        appServerModelOptions = []
        appServerModelOptionsLastRefresh = nil
        appServerPermissionProfiles = []
        activePermissionProfileBySessionID = [:]
        permissionProfilesCWD = nil
        permissionProfilesRefreshGeneration += 1
        permissionProfilesRefreshRequestedCWD = nil
        isRefreshingPermissionProfiles = false
        isClaudeRuntimeChannelAvailable = false
        accountRateLimitsByRuntime = [:]
        accountTokenUsage = nil
        accountTokenActivity = .idle
        isRefreshingAccountTokenActivity = false
        accountTokenUsageRefreshHostScope = nil
        refreshingUsageRuntimeProviders = []
        isRefreshingAppServerModels = false
        capabilityList = nil
        capabilityErrorMessage = nil
        isRefreshingCapabilities = false
        reloadSessionListPreferences()
        reloadHistoryReadStates()
        reloadSessionControlStates()
        reloadSessionReminders()
        foregroundActivityBySessionID = [:]
        runtimeActivityBySessionID = [:]
        locallyCompletedSessionIDs = []
        locallyCompletedGoalThreadIDs = []
        runtimeEventFlushTasks.values.forEach { $0.cancel() }
        runtimeEventFlushTasks = [:]
        foregroundActivityClearTasks.values.forEach { $0.cancel() }
        foregroundActivityClearTasks = [:]
        rebuildProjectSessionListSnapshots()
    }

    func upsert(_ session: AgentSession) {
        let session = sessionPreparedForStorage(alignSessionToKnownWorkspace(session))
        syncRuntimeActivity(with: session)
        contextStore.upsert(from: session)
        if let batch = eventReducerSessionMutationBatch {
            if let index = sessionIndexByID[session.id] {
                guard batch.replace(at: index, with: session) else {
                    return
                }
                sessionsByID[session.id] = session
            } else {
                batch.insert(session)
                sessionsByID[session.id] = session
                // 插入头部会改变所有后续位置；这是批内唯一需要 O(n) 的 lookup 更新，
                // 与既有 upsert 的数组语义保持一致。
                sessionIndexByID = Dictionary(
                    uniqueKeysWithValues: batch.sessions.enumerated().map { ($0.element.id, $0.offset) }
                )
            }
            return
        }
        if let index = sessionIndexByID[session.id] {
            guard sessions[index] != session else {
                return
            }
            var next = sessions
            next[index] = session
            // 单次赋值让 @Published 只通知一次，也让派生索引只重建一次。
            sessions = next
            return
        }
        sessions = [session] + sessions
    }

    func ingestSessionContexts(_ items: [AgentSession]) {
        for session in items {
            contextStore.upsert(from: session)
        }
    }

    func ingestHistoryContext(_ context: SessionContextSnapshot?, fallbackSessionID: SessionID) {
        guard let context else {
            return
        }
        contextStore.upsert(context, fallbackSessionID: fallbackSessionID)
    }

    func updateSession(_ id: String, mutate: (inout AgentSession) -> Void) {
        if let batch = eventReducerSessionMutationBatch {
            guard let index = sessionIndexByID[id], batch.sessions.indices.contains(index) else {
                return
            }
            let oldValue = batch.sessions[index]
            var next = oldValue
            mutate(&next)
            guard next != oldValue else {
                return
            }
            batch.sessions[index] = next
            sessionsByID[id] = next
            return
        }
        guard let index = sessionIndexByID[id] else {
            return
        }
        var next = sessions
        let oldValue = next[index]
        mutate(&next[index])
        guard next[index] != oldValue else {
            return
        }
        sessions = next
    }

    func applyThreadGoal(
        _ goal: ThreadGoal,
        fallbackSessionID: SessionID? = nil,
        respectsLocalCompletion: Bool = true
    ) {
        let sessionID = fallbackSessionID ?? goal.threadID
        let goal = normalizedThreadGoalForApply(goal, sessionID: sessionID, respectsLocalCompletion: respectsLocalCompletion)
        updateSession(sessionID) { item in
            item.goal = goal
        }
        if sessionID != goal.threadID {
            updateSession(goal.threadID) { item in
                item.goal = goal
            }
        }
        contextStore.upsert(
            SessionContextSnapshot(
                sessionID: sessionID,
                threadID: goal.threadID,
                goal: goal,
                updatedAt: Date()
            ),
            fallbackSessionID: sessionID
        )
    }

    func clearThreadGoal(sessionID: SessionID) {
        locallyCompletedGoalThreadIDs.remove(sessionID)
        updateSession(sessionID) { item in
            if let goal = item.goal {
                clearLocalCompletedGoalMark(goal, sessionID: sessionID)
            }
            item.goal = nil
        }
        contextStore.clearGoal(sessionID: sessionID)
    }

    func sessionPreservingLocalCompletedStatus(_ incoming: AgentSession) -> AgentSession {
        var next = incoming
        if next.status == SessionStatus.completed.rawValue {
            locallyCompletedSessionIDs.insert(next.id)
            return next
        }
        guard Self.isRunningStatus(next.status),
              locallyCompletedSessionIDs.contains(next.id)
        else {
            return next
        }
        // 列表刷新可能落后于实时 turn/completed；这时不要让旧 running 快照把 UI 拉回运行态。
        next.status = SessionStatus.completed.rawValue
        next.activeTurnID = nil
        next.pendingApproval = nil
        next.pendingUserInput = nil
        return next
    }

    func sessionPreservingLocalCompletedGoal(_ incoming: AgentSession) -> AgentSession {
        guard let goal = incoming.goal else {
            return incoming
        }
        var next = incoming
        next.goal = normalizedThreadGoalForApply(goal, sessionID: incoming.id, respectsLocalCompletion: true)
        return next
    }

    func normalizedThreadGoalForApply(
        _ goal: ThreadGoal,
        sessionID: SessionID,
        respectsLocalCompletion: Bool
    ) -> ThreadGoal {
        if respectsLocalCompletion,
           goal.status == .active,
           hasLocalCompletedGoalMark(goal, sessionID: sessionID) {
            return completedGoal(from: goal)
        }
        if goal.status == .complete {
            markLocalCompletedGoal(goal, sessionID: sessionID)
        } else if respectsLocalCompletion, goal.status != .active {
            clearLocalCompletedGoalMark(goal, sessionID: sessionID)
        } else if !respectsLocalCompletion {
            clearLocalCompletedGoalMark(goal, sessionID: sessionID)
        }
        return goal
    }

    func completedGoal(from goal: ThreadGoal) -> ThreadGoal {
        ThreadGoal(
            threadID: goal.threadID,
            objective: goal.objective,
            status: .complete,
            tokenBudget: goal.tokenBudget,
            tokensUsed: goal.tokensUsed,
            timeUsedSeconds: goal.timeUsedSeconds,
            createdAt: goal.createdAt,
            updatedAt: Date()
        )
    }

    func markLocalCompletedGoal(_ goal: ThreadGoal, sessionID: SessionID) {
        locallyCompletedGoalThreadIDs.formUnion(goalIdentityCandidates(goal, sessionID: sessionID))
    }

    func clearLocalCompletedGoalMark(_ goal: ThreadGoal, sessionID: SessionID) {
        locallyCompletedGoalThreadIDs.subtract(goalIdentityCandidates(goal, sessionID: sessionID))
    }

    func hasLocalCompletedGoalMark(_ goal: ThreadGoal, sessionID: SessionID) -> Bool {
        !locallyCompletedGoalThreadIDs.isDisjoint(with: goalIdentityCandidates(goal, sessionID: sessionID))
    }

    func goalIdentityCandidates(_ goal: ThreadGoal, sessionID: SessionID) -> Set<SessionID> {
        var candidates: Set<SessionID> = []
        for value in [sessionID, goal.threadID, sessionsByID[sessionID]?.resumeID, contextStore.context(for: sessionID)?.threadID] {
            if let identity = Self.nonEmptyThreadIdentity(value) {
                candidates.insert(identity)
            }
        }
        return candidates
    }

    func markApprovalDecisionPending(_ approvalID: String, sessionID: SessionID) {
        var ids = pendingApprovalDecisionIDsBySessionID[sessionID] ?? []
        ids.insert(approvalID)
        pendingApprovalDecisionIDsBySessionID[sessionID] = ids
    }

    func clearPendingApprovalDecision(sessionID: SessionID, approvalID: String) {
        guard var ids = pendingApprovalDecisionIDsBySessionID[sessionID] else {
            return
        }
        ids.remove(approvalID)
        if ids.isEmpty {
            pendingApprovalDecisionIDsBySessionID.removeValue(forKey: sessionID)
        } else {
            pendingApprovalDecisionIDsBySessionID[sessionID] = ids
        }
    }

    func clearPendingApprovalDecisions(sessionID: SessionID) {
        pendingApprovalDecisionIDsBySessionID.removeValue(forKey: sessionID)
    }

    func isApprovalDecisionPending(_ approval: ApprovalSummary, sessionID: SessionID) -> Bool {
        pendingApprovalDecisionIDsBySessionID[sessionID]?.contains(approval.id) == true
    }

    func markUserInputResponsePending(_ request: AgentUserInputRequest, sessionID: SessionID) {
        var ids = pendingUserInputResponseIDsBySessionID[sessionID] ?? []
        ids.insert(request.id)
        pendingUserInputResponseIDsBySessionID[sessionID] = ids
        var requests = pendingUserInputRequestsBySessionID[sessionID] ?? [:]
        requests[request.id] = request
        pendingUserInputRequestsBySessionID[sessionID] = requests
    }

    @discardableResult
    func clearPendingUserInputResponse(sessionID: SessionID, requestID: String) -> AgentUserInputRequest? {
        let request = pendingUserInputRequestsBySessionID[sessionID]?[requestID]
        pendingUserInputRequestsBySessionID[sessionID]?[requestID] = nil
        if pendingUserInputRequestsBySessionID[sessionID]?.isEmpty == true {
            pendingUserInputRequestsBySessionID.removeValue(forKey: sessionID)
        }
        guard var ids = pendingUserInputResponseIDsBySessionID[sessionID] else {
            return request
        }
        ids.remove(requestID)
        if ids.isEmpty {
            pendingUserInputResponseIDsBySessionID.removeValue(forKey: sessionID)
        } else {
            pendingUserInputResponseIDsBySessionID[sessionID] = ids
        }
        return request
    }

    func clearPendingUserInputResponses(sessionID: SessionID) {
        pendingUserInputResponseIDsBySessionID.removeValue(forKey: sessionID)
        pendingUserInputRequestsBySessionID.removeValue(forKey: sessionID)
    }

    func isUserInputResponsePending(_ request: AgentUserInputRequest, sessionID: SessionID) -> Bool {
        pendingUserInputResponseIDsBySessionID[sessionID]?.contains(request.id) == true
    }

    func acceptUserInputResponseLocally(_ request: AgentUserInputRequest, sessionID: SessionID) {
        updateSession(sessionID) { item in
            if let currentInput = item.pendingUserInput, currentInput.id != request.id {
                return
            }
            // 服务端确认事件可能要等一会；本地先把阻塞点收起，避免用户看到一个置灰的旧表单。
            item.status = "running"
            item.pendingUserInput = nil
        }
        contextStore.upsert(
            SessionContextSnapshot(sessionID: sessionID, status: SessionContextStatus(type: "active"), updatedAt: Date()),
            fallbackSessionID: sessionID
        )
        conversationStore.resolveLatestPendingUserInput(sessionID: sessionID, skipped: false)
    }

    func restoreUserInputRequestAfterFailure(_ request: AgentUserInputRequest, sessionID: SessionID) {
        updateSession(sessionID) { item in
            item.status = "waiting_for_input"
            item.pendingUserInput = request
        }
        contextStore.upsert(
            SessionContextSnapshot(
                sessionID: sessionID,
                status: SessionContextStatus(type: "active", activeFlags: ["waitingOnUserInput"]),
                tasks: [SessionContextTask(id: request.id, kind: "user_input", title: request.title, subtitle: nil, status: "waiting")],
                updatedAt: Date()
            ),
            fallbackSessionID: sessionID
        )
        conversationStore.restorePendingUserInput(request, sessionID: sessionID)
    }

    static func normalizedSession(_ session: AgentSession) -> AgentSession {
        var next = session
        if next.status != "waiting_for_approval" {
            next.pendingApproval = nil
        }
        if next.status != "waiting_for_input" {
            next.pendingUserInput = nil
        }
        return next
    }

    func sessionPreservingActiveApproval(_ incoming: AgentSession) -> AgentSession {
        sessionPreservingActiveApproval(incoming, existing: sessionsByID[incoming.id])
    }

    func sessionPreservingActiveApproval(_ incoming: AgentSession, existing: AgentSession?) -> AgentSession {
        var next = Self.normalizedSession(incoming)
        if shouldPreserveConnectedRunningSessionAgainstHistorySnapshot(incoming: next, existing: existing) {
            next.status = existing?.status ?? next.status
            next.activeTurnID = existing?.activeTurnID ?? next.activeTurnID
            next.pendingApproval = existing?.pendingApproval ?? next.pendingApproval
            next.pendingUserInput = existing?.pendingUserInput ?? next.pendingUserInput
        }
        if let userInput = next.pendingUserInput,
           isUserInputResponsePending(userInput, sessionID: next.id) {
            // 列表刷新可能读到补充信息提交前的旧快照；已在本地提交中的 request 不应重新顶回可见表单。
            next.status = "running"
            next.pendingUserInput = nil
        }
        // goal 是 thread 级元数据；列表刷新或上下文回填时必须按当前 thread 身份校验，
        // 否则同项目内切换对话会短暂显示另一个 thread 的目标状态。
        next.goal = Self.matchingThreadGoal(
            for: next,
            existingGoal: existing?.goal,
            context: contextStore.context(for: next.id)
        )
        if next.pendingApproval == nil,
           let existingApproval = existing?.pendingApproval,
           Self.canPreservePendingApproval(whileStatusIs: next.status) {
            // 列表/历史刷新拿到的 session 可能只是通用 running 快照；本地已有明确 approval_request 时，
            // 以实时事件为准保留审批入口，直到 approval_resolved/turn_completed/error 显式清理。
            next.status = "waiting_for_approval"
            next.pendingApproval = existingApproval
            return next
        }
        if next.pendingUserInput == nil,
           let existingInput = existing?.pendingUserInput,
           !isUserInputResponsePending(existingInput, sessionID: next.id),
           Self.canPreservePendingApproval(whileStatusIs: next.status) {
            next.status = "waiting_for_input"
            next.pendingUserInput = existingInput
        }
        return next
    }

    func shouldPreserveConnectedRunningSessionAgainstHistorySnapshot(incoming: AgentSession, existing: AgentSession?) -> Bool {
        guard incoming.status == SessionStatus.history.rawValue,
              let existing,
              existing.isRunning,
              incoming.id == selectedSessionID,
              connectedSessionID == incoming.id,
              webSocket != nil
        else {
            return false
        }
        switch webSocketStatus {
        case .connecting, .connected:
            // 长任务运行中，thread/list 偶尔会返回滞后的 idle/notLoaded 快照。
            // 当前 iPad 仍有活动实时连接时，以本地运行态为准，避免下一次发送误走历史 resume。
            return true
        case .disconnected, .failed, .terminated:
            return false
        }
    }

    static func matchingThreadGoal(
        for session: AgentSession,
        existingGoal: ThreadGoal? = nil,
        context: SessionContextSnapshot?
    ) -> ThreadGoal? {
        if let goal = session.goal, threadGoal(goal, belongsTo: session, context: context) {
            return goal
        }
        if let goal = existingGoal, threadGoal(goal, belongsTo: session, context: context) {
            return goal
        }
        if let goal = context?.goal, threadGoal(goal, belongsTo: session, context: context) {
            return goal
        }
        return nil
    }

    static func threadGoal(
        _ goal: ThreadGoal,
        belongsTo session: AgentSession,
        context: SessionContextSnapshot?
    ) -> Bool {
        guard let goalThreadID = nonEmptyThreadIdentity(goal.threadID) else {
            return false
        }
        return threadIdentityCandidates(for: session, context: context).contains(goalThreadID)
    }

    static func threadIdentityCandidates(
        for session: AgentSession,
        context: SessionContextSnapshot?
    ) -> Set<SessionID> {
        var candidates: Set<SessionID> = []
        for value in [session.id, session.resumeID, context?.threadID] {
            if let identity = nonEmptyThreadIdentity(value) {
                candidates.insert(identity)
            }
        }
        return candidates
    }

    static func nonEmptyThreadIdentity(_ value: String?) -> SessionID? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    static func canPreservePendingApproval(whileStatusIs status: String) -> Bool {
        switch status {
        case "running", "waiting_for_approval", "waiting_for_input":
            return true
        default:
            return false
        }
    }

    func setForegroundActivity(
        _ activity: SessionForegroundActivity,
        sessionID: SessionID,
        autoClearAfter delay: UInt64? = nil
    ) {
        // 流式输出时每个 app-server 分片都会调到这里。@Published 字典即使赋同值也会触发
        // objectWillChange，进而让整张边栏 List 反复重绘、抢占主线程，导致点击发涩。
        // 因此仅在活动真正变化时才写回；计时器仍每次重置（它不是 @Published）。
        if foregroundActivityBySessionID[sessionID] != activity {
            foregroundActivityBySessionID[sessionID] = activity
        }
        foregroundActivityClearTasks[sessionID]?.cancel()
        guard let delay else {
            foregroundActivityClearTasks[sessionID] = nil
            return
        }
        // 部分 app-server 流式事件可能缺少完成事件，用空闲超时兜底，避免输出结束后仍一直显示正在回复。
        foregroundActivityClearTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard self?.foregroundActivityBySessionID[sessionID] == activity else {
                    return
                }
                self?.clearForegroundActivity(sessionID: sessionID)
            }
        }
    }

    func clearForegroundActivity(sessionID: SessionID) {
        foregroundActivityClearTasks[sessionID]?.cancel()
        foregroundActivityClearTasks.removeValue(forKey: sessionID)
        if foregroundActivityBySessionID[sessionID] != nil {
            foregroundActivityBySessionID.removeValue(forKey: sessionID)
        }
    }
}

private func remappedWorkspaceIDs(
    _ ids: Set<String>,
    replacements: [String: String]
) -> Set<String> {
    Set(ids.map { replacements[$0] ?? $0 })
}

/// 目标 ID 已有状态时保留目标值；只有目标为空才承接旧 ID 的值。
private func remappedWorkspaceValues<Value>(
    _ values: [String: Value],
    replacements: [String: String]
) -> [String: Value] {
    var remapped = values.filter { replacements[$0.key] == nil }
    for (oldID, newID) in replacements.sorted(by: { $0.key < $1.key }) {
        if remapped[newID] == nil, let value = values[oldID] {
            remapped[newID] = value
        }
    }
    return remapped
}
