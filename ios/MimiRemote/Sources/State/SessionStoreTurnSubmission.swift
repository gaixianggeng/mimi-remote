import Foundation

/// 用户点击提交时的不可变目标。selectionLease 只决定异步完成后能否更新前台，
/// session/project 则持续作为本次已接受发送的目标，避免返回列表后被当前选择改写。
struct TurnSubmissionContext {
    let hostScope: HostScope
    let selectionLease: SessionSelectionLease
    let projectID: String?
    let session: AgentSession?
}

enum PendingGuidanceDispatchState: Equatable {
    case waitingForSocket
    case awaitingAcknowledgement
}

/// guided 消息不进入持久队列；这里只保留切页后从建连到 ACK 的短生命周期状态。
struct PendingGuidanceSubmission {
    let hostScope: HostScope
    let payload: CodexAppServerTurnPayload
    let clientMessageID: ClientMessageID
    let expectedTurnID: TurnID
    var state: PendingGuidanceDispatchState
}

extension SessionStore {
    func clearSessionCreationLoading() {
        // 创建请求可以后台完成，但切换选择后不能继续禁用新会话的输入框。
        guard let lease = sessionCreationLoadingLease else { return }
        sessionCreationLoadingLease = nil
        if appStore.activeHostScope == lease.hostScope {
            isLoading = false
        }
    }

    func captureTurnSubmissionContext() -> TurnSubmissionContext {
        TurnSubmissionContext(
            hostScope: appStore.activeHostScope,
            selectionLease: currentSelectionLease(),
            projectID: selectedSession?.projectID ?? selectedProjectID,
            session: selectedSession
        )
    }

    func isSubmissionHostCurrent(_ context: TurnSubmissionContext) -> Bool {
        appStore.activeHostScope == context.hostScope
    }

    func runtimeProviderForTurn(session: AgentSession?) -> String? {
        guard let session else {
            return nil
        }
        if session.source == "local", session.runtimeProvider == nil {
            return nil
        }
        return Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
    }

    @discardableResult
    func stagePendingGuidance(
        _ payload: CodexAppServerTurnPayload,
        sessionID: SessionID,
        clientMessageID: ClientMessageID,
        expectedTurnID: TurnID,
        hostScope: HostScope
    ) -> Bool {
        pendingGuidanceBySessionID[sessionID, default: []].append(PendingGuidanceSubmission(
            hostScope: hostScope,
            payload: payload,
            clientMessageID: clientMessageID,
            expectedTurnID: expectedTurnID,
            state: .waitingForSocket
        ))
        ensureQueuedSessionMonitoring(sessionID: sessionID)
        if let socket = socketForQueuedDispatch(sessionID: sessionID) {
            dispatchPendingGuidance(sessionID: sessionID, socket: socket)
        }
        guard queuedSessionSockets[sessionID] != nil else {
            failPendingGuidance(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                message: L10n.text("ui.websocket_is_reconnecting_please_try_again_later")
            )
            return false
        }
        return true
    }

    func trackSubmittedGuidance(
        _ payload: CodexAppServerTurnPayload,
        sessionID: SessionID,
        clientMessageID: ClientMessageID,
        expectedTurnID: TurnID,
        hostScope: HostScope
    ) {
        pendingGuidanceBySessionID[sessionID, default: []].append(PendingGuidanceSubmission(
            hostScope: hostScope,
            payload: payload,
            clientMessageID: clientMessageID,
            expectedTurnID: expectedTurnID,
            state: .awaitingAcknowledgement
        ))
    }

    func hasPendingGuidance(
        clientMessageID: ClientMessageID,
        sessionID: SessionID,
        hostScope: HostScope
    ) -> Bool {
        guard appStore.activeHostScope == hostScope else { return false }
        return pendingGuidanceBySessionID[sessionID]?.contains {
            $0.clientMessageID == clientMessageID && $0.hostScope == hostScope
        } == true
    }

    func dispatchPendingGuidance(
        sessionID: SessionID,
        socket: any SessionWebSocketClient
    ) {
        let waitingClientMessageIDs = (pendingGuidanceBySessionID[sessionID] ?? []).compactMap { item in
            item.state == .waitingForSocket ? item.clientMessageID : nil
        }
        for clientMessageID in waitingClientMessageIDs {
            guard let index = pendingGuidanceBySessionID[sessionID]?.firstIndex(where: {
                $0.clientMessageID == clientMessageID
            }) else { continue }
            let item = pendingGuidanceBySessionID[sessionID]![index]
            guard item.hostScope == appStore.activeHostScope else {
                pendingGuidanceBySessionID[sessionID]?.remove(at: index)
                continue
            }
            // 先标记为等待 ACK，防止同步失败回调与 sendGuidance 返回值重复派发。
            pendingGuidanceBySessionID[sessionID]![index].state = .awaitingAcknowledgement
            guard socket.sendGuidance(
                item.payload,
                clientMessageID: item.clientMessageID,
                expectedTurnID: item.expectedTurnID
            ) else {
                failPendingGuidance(
                    clientMessageID: item.clientMessageID,
                    sessionID: sessionID,
                    message: L10n.text("ui.sending_failed_websocket_not_connected")
                )
                continue
            }
            freshEmptyHistorySignatureBySessionID.removeValue(forKey: sessionID)
        }
        if pendingGuidanceBySessionID[sessionID]?.isEmpty == true {
            pendingGuidanceBySessionID.removeValue(forKey: sessionID)
        }
    }

    @discardableResult
    func finishPendingGuidance(
        clientMessageID: ClientMessageID,
        sessionID: SessionID
    ) -> Bool {
        guard let index = pendingGuidanceBySessionID[sessionID]?.firstIndex(where: {
            $0.clientMessageID == clientMessageID
        }) else { return false }
        pendingGuidanceBySessionID[sessionID]?.remove(at: index)
        if pendingGuidanceBySessionID[sessionID]?.isEmpty == true {
            pendingGuidanceBySessionID.removeValue(forKey: sessionID)
        }
        return true
    }

    @discardableResult
    func acceptPendingGuidance(
        clientMessageID: ClientMessageID,
        sessionID: SessionID
    ) -> Bool {
        guard finishPendingGuidance(clientMessageID: clientMessageID, sessionID: sessionID) else {
            return false
        }
        conversationStore.updateSendStatus(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            status: .sent
        )
        conversationStore.compactTurnPayloadAfterSendAccepted(
            clientMessageID: clientMessageID,
            sessionID: sessionID
        )
        stopQueuedSessionMonitoringIfIdle(sessionID: sessionID)
        return true
    }

    @discardableResult
    func failPendingGuidance(
        clientMessageID: ClientMessageID,
        sessionID: SessionID,
        message: String
    ) -> Bool {
        guard finishPendingGuidance(clientMessageID: clientMessageID, sessionID: sessionID) else {
            return false
        }
        conversationStore.updateSendStatus(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            status: .failed
        )
        clearSessionListProjection(sessionID: sessionID, clientMessageID: clientMessageID)
        clearSessionRecentActivityProjection(sessionID: sessionID, clientMessageID: clientMessageID)
        clearForegroundActivity(sessionID: sessionID)
        setErrorMessage(L10n.format("ui.sending_failed_value", message))
        stopQueuedSessionMonitoringIfIdle(sessionID: sessionID)
        return true
    }

    @discardableResult
    func failPendingGuidanceConnection(sessionID: SessionID, message: String) -> Bool {
        let items = pendingGuidanceBySessionID[sessionID] ?? []
        for item in items where item.hostScope == appStore.activeHostScope {
            switch item.state {
            case .waitingForSocket:
                _ = failPendingGuidance(
                    clientMessageID: item.clientMessageID,
                    sessionID: sessionID,
                    message: message
                )
            case .awaitingAcknowledgement:
                guard finishPendingGuidance(
                    clientMessageID: item.clientMessageID,
                    sessionID: sessionID
                ) else { continue }
                conversationStore.updateSendStatus(
                    clientMessageID: item.clientMessageID,
                    sessionID: sessionID,
                    status: .uncertain
                )
                clearForegroundActivity(sessionID: sessionID)
                setErrorMessage(nil)
                setStatusMessage(L10n.text("ui.sending_result_pending_confirmation"))
                stopQueuedSessionMonitoringIfIdle(sessionID: sessionID)
            }
        }
        return !items.isEmpty
    }

    func failAllPendingGuidance() {
        let sessionIDs = Array(pendingGuidanceBySessionID.keys)
        for sessionID in sessionIDs {
            _ = failPendingGuidanceConnection(
                sessionID: sessionID,
                message: L10n.text("ui.sending_failed_websocket_not_connected")
            )
        }
        // Host 已提交切换时只丢弃旧 transient；上面的 HostScope guard 禁止改写新 namespace。
        pendingGuidanceBySessionID.removeAll()
    }
}
