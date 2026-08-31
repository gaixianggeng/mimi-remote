import Foundation

enum QueuedTurnAcceptedDisposition {
    case serverQueued(submissionID: String)
    case awaitingStart(turnID: TurnID?)
    case guidance
    case terminal(turnID: TurnID?)
    case superseded(turnID: TurnID?, activeTurnID: TurnID)
    case threadClosed(turnID: TurnID?)
}

// 排队 Turn 的调度、连接监控、发送结果归并与持久化对账集中在同一协调边界。
extension SessionStore {
    func scheduleTurnCompletionReconciliationIfNeeded(
        message: AgentMessage,
        metadata: AgentEventMetadata,
        hostScope: HostScope
    ) {
        let sessionID = metadata.sessionID ?? message.sessionID
        guard message.role == .assistant,
              message.kind == .message,
              let turnID = metadata.turnID ?? message.turnID
        else {
            return
        }
        startTurnCompletionReconciliation(
            sessionID: sessionID,
            expectedTurnID: turnID,
            hostScope: hostScope
        )
    }

    func resumeTurnCompletionReconciliationIfNeeded(
        sessionID: SessionID,
        hostScope: HostScope
    ) {
        guard let turnID = sessionsByID[sessionID]?.activeTurnID,
              conversationStore.messages(for: sessionID).contains(where: {
                  $0.role == .assistant
                      && $0.kind == .message
                      && $0.turnID == turnID
                      && $0.sendStatus == .confirmed
              })
        else {
            return
        }
        startTurnCompletionReconciliation(
            sessionID: sessionID,
            expectedTurnID: turnID,
            hostScope: hostScope
        )
    }

    private func startTurnCompletionReconciliation(
        sessionID: SessionID,
        expectedTurnID turnID: TurnID,
        hostScope: HostScope
    ) {
        guard let session = sessionsByID[sessionID],
              session.activeTurnID == turnID,
              turnCompletionReconciliationJobsBySessionID[session.id] == nil,
              !turnCompletionReconciliationDelaysNanoseconds.isEmpty
        else {
            return
        }

        let delays = turnCompletionReconciliationDelaysNanoseconds
        turnCompletionReconciliationGeneration &+= 1
        let generation = turnCompletionReconciliationGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                    try Task.checkCancellation()
                } catch {
                    break
                }
                guard self.shouldReconcileTurnCompletion(
                    sessionID: sessionID,
                    expectedTurnID: turnID,
                    hostScope: hostScope
                ) else {
                    break
                }

                do {
                    guard let page = try await self.clientFactory().latestTurnHistoryPage(
                        sessionID: sessionID
                    ) else {
                        break
                    }
                    try Task.checkCancellation()
                    guard self.shouldReconcileTurnCompletion(
                        sessionID: sessionID,
                        expectedTurnID: turnID,
                        hostScope: hostScope
                    ) else {
                        break
                    }
                    guard let lifecycle = self.terminalLifecycle(
                        in: page,
                        matching: turnID
                    ) else {
                        continue
                    }
                    guard self.finishTurnCompletionReconciliation(
                        sessionID: sessionID,
                        generation: generation
                    ) else {
                        break
                    }

                    // item/completed 只说明一个回复 Item 已结束。只有最新完整 Turn 的权威页
                    // 明确确认同一 activeTurnID 终态后，才复用既有 turn/completed 收敛路径。
                    await self.applyRuntimeEvent(
                        .turnCompleted(AgentEventMetadata(
                            seq: page.snapshotSeq,
                            sessionID: sessionID,
                            turnID: turnID,
                            itemID: nil,
                            messageID: nil,
                            clientMessageID: nil,
                            revision: nil,
                            createdAt: nil,
                            turnLifecycle: lifecycle
                        )),
                        lease: HostSessionLease(hostScope: hostScope, sessionID: sessionID)
                    )
                    return
                } catch is CancellationError {
                    break
                } catch CodexAppServerSessionRuntimeError.paginatedHistoryUnavailable(_) {
                    break
                } catch {
                    // 短暂的历史请求冲突或弱网失败不改变本地状态；有限退避后再试。
                    continue
                }
            }
            _ = self.finishTurnCompletionReconciliation(
                sessionID: sessionID,
                generation: generation
            )
        }
        turnCompletionReconciliationJobsBySessionID[sessionID] = TurnCompletionReconciliationJob(
            generation: generation,
            expectedTurnID: turnID,
            task: task
        )
    }

    func shouldReconcileTurnCompletion(
        sessionID: SessionID,
        expectedTurnID: TurnID,
        hostScope: HostScope
    ) -> Bool {
        guard appStore.activeHostScope == hostScope,
              connectionTermination == nil,
              appStore.isConfigured,
              !isAppInBackground,
              let session = sessionsByID[sessionID]
        else {
            return false
        }
        return session.activeTurnID == expectedTurnID
    }

    func terminalLifecycle(
        in page: HistoryMessagesPage,
        matching turnID: TurnID
    ) -> ConversationTurnLifecycle? {
        let lifecycles = page.messages.lazy
            .filter { $0.turnID == turnID }
            .compactMap(\.turnLifecycle)
            .filter(\.isTerminal)
        if lifecycles.contains(.failed) {
            return .failed
        }
        if lifecycles.contains(.interrupted) {
            return .interrupted
        }
        return lifecycles.contains(.completed) ? .completed : nil
    }

    func cancelTurnCompletionReconciliation(sessionID: SessionID) {
        turnCompletionReconciliationJobsBySessionID.removeValue(forKey: sessionID)?.task.cancel()
    }

    func cancelAllTurnCompletionReconciliations() {
        turnCompletionReconciliationJobsBySessionID.values.forEach { $0.task.cancel() }
        turnCompletionReconciliationJobsBySessionID.removeAll()
    }

    @discardableResult
    func finishTurnCompletionReconciliation(sessionID: SessionID, generation: UInt64) -> Bool {
        guard turnCompletionReconciliationJobsBySessionID[sessionID]?.generation == generation else {
            return false
        }
        turnCompletionReconciliationJobsBySessionID.removeValue(forKey: sessionID)
        return true
    }

    func dispatchNextQueuedRunningTurnIfIdle(sessionID: SessionID) {
        guard let session = sessionsByID[sessionID],
              !queuedTurnAwaitingStartSessionIDs.contains(sessionID),
              queuedServerSubmissionAwaitingOutcomeBySessionID[sessionID] == nil,
              let queue = queuedRunningTurnsBySessionID[sessionID],
              let next = queue.first,
              next.dispatchState == .waiting,
              next.waitsForAcceptedTurnStart != true
        else {
            return
        }
        if let pendingBoundary = pendingPermissionTurnBoundary(for: sessionID),
           pendingBoundary.clientMessageID != next.clientMessageID,
           !queue.contains(where: { $0.clientMessageID == pendingBoundary.clientMessageID }) {
            // 边界项仍在队列后方时，先发送排在它前面的普通项。只有 ACK 后边界项已离队、
            // 仍等待精确 started 的 orphan boundary 才能阻止后续消息越过。
            return
        }
        guard let socket = socketForQueuedDispatch(sessionID: sessionID) else {
            ensureQueuedSessionMonitoring(sessionID: sessionID)
            return
        }
        let usesServerQueue = socket.turnDeliveryMode == .sharedServerQueue
            && next.intent.canGuideCurrentTurn
            && !queuedGuidanceDispatchClientMessageIDs.contains(next.clientMessageID)
        // shared queue 由 App Server 绑定当前 turn；expectedTurnID 只是直连 steer 的本地旧约束。
        guard usesServerQueue || next.expectedTurnID == nil else { return }
        guard usesServerQueue || session.activeTurnID == nil else { return }
        guard usesServerQueue || canControlSession(session) else {
            setStatusMessage(L10n.text("ui.message_to_be_sent_is_waiting_please_take"))
            return
        }

        guard mutateAndPersistQueuedTurns({
            guard var queue = queuedRunningTurnsBySessionID[sessionID], !queue.isEmpty else { return }
            queue[0].dispatchState = .dispatching
            queue[0].lastAttemptAt = Date()
            queue[0].lastError = nil
            queuedRunningTurnsBySessionID[sessionID] = queue
        }) else {
            return
        }

        if case .goal(let objective, let tokenBudget) = next.intent {
            Task { @MainActor [weak self, socket] in
                guard let self else { return }
                guard await self.setThreadGoal(
                    threadID: sessionID,
                    objective: objective,
                    status: .active,
                    tokenBudget: tokenBudget
                ) else {
                    self.markQueuedTurnWaitingAfterDefiniteFailure(
                        clientMessageID: next.clientMessageID,
                        message: L10n.text("ui.target_setup_failed_and_has_not_been_sent")
                    )
                    return
                }
                self.performQueuedTurnSend(next, session: session, socket: socket)
            }
        } else {
            performQueuedTurnSend(next, session: session, socket: socket)
        }
    }

    func performQueuedTurnSend(
        _ item: QueuedTurnEntry,
        session: AgentSession,
        socket: any SessionWebSocketClient
    ) {
        guard queuedTurnLocation(clientMessageID: item.clientMessageID) != nil else { return }
        setForegroundActivity(.waitingForAssistant, sessionID: session.id)

        queuedTurnAwaitingStartSessionIDs.insert(session.id)
        if socket.turnDeliveryMode == .sharedServerQueue {
            queuedServerSubmissionAwaitingOutcomeBySessionID[session.id] = item.clientMessageID
        }
        guard socket.sendTurn(item.payload, clientMessageID: item.clientMessageID) else {
            if queuedServerSubmissionAwaitingOutcomeBySessionID[session.id] == item.clientMessageID {
                queuedServerSubmissionAwaitingOutcomeBySessionID.removeValue(forKey: session.id)
            }
            queuedTurnAwaitingStartSessionIDs.remove(session.id)
            markQueuedTurnWaitingAfterDefiniteFailure(
                clientMessageID: item.clientMessageID,
                message: L10n.text("ui.the_connection_is_not_ready_yet_the_message")
            )
            clearForegroundActivity(sessionID: session.id)
            return
        }

        // 只有传输层接受 turn/start 后才进入 timeline；纯本地等待项只在输入框上方的队列托盘展示。
        conversationStore.appendLocalUser(
            item.previewText,
            sessionID: session.id,
            clientMessageID: item.clientMessageID,
            sendStatus: .sending,
            turnPayload: item.payload,
            userDelivery: .queued
        )
        setSessionListProjection(
            sessionID: session.id,
            preview: item.previewText,
            source: .localUser,
            clientMessageID: item.clientMessageID
        )

        // dispatching + awaitingStart 已能阻止重复派发。只有 accepted 回调或 turn/started
        // 才能证明上游接收，派发窗口内不再乐观伪造 running。
        freshEmptyHistorySignatureBySessionID.removeValue(forKey: session.id)
        setStatusMessage(L10n.text("ui.the_queued_message_has_been_sent_waiting_for"))
    }

    func markQueuedTurnWaitingAfterDefiniteFailure(
        clientMessageID: ClientMessageID,
        message: String
    ) {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID) else { return }
        _ = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[location.sessionID],
                  queue.indices.contains(location.index) else { return }
            queue[location.index].dispatchState = .waiting
            queue[location.index].lastError = message
            queuedRunningTurnsBySessionID[location.sessionID] = queue
        }
        setStatusMessage(message)
    }

    func hasQueuedGoalTurn(sessionID: SessionID) -> Bool {
        queuedRunningTurnsBySessionID[sessionID]?.contains(where: { $0.intent.startsGoal }) == true
    }

    func cancelQueuedRunningTurns(sessionID: SessionID, markMessagesFailed: Bool) {
        let queued = queuedRunningTurnsBySessionID[sessionID] ?? []
        queuedGuidanceDispatchClientMessageIDs.subtract(queued.map(\.clientMessageID))
        if let clientMessageID = queuedServerSubmissionAwaitingOutcomeBySessionID.removeValue(
            forKey: sessionID
        ) {
            queuedServerSubmissionStartedBeforeOutcomeClientMessageIDs.remove(clientMessageID)
        }
        _ = mutateAndPersistQueuedTurns {
            setQueuedTurns([], sessionID: sessionID)
            let waitingIDs = Set(queued.lazy.filter { $0.dispatchState == .waiting }.map(\.clientMessageID))
            if var boundaries = pendingPermissionTurnBoundariesBySessionID[sessionID] {
                for boundary in boundaries where waitingIDs.contains(boundary.clientMessageID) {
                    if markMessagesFailed {
                        permissionTurnRetryRequirementsByClientMessageID[boundary.clientMessageID] = boundary
                    }
                }
                // 尚未派发的边界随队列一起取消；已派发或结果不确定的边界仍必须等精确 started。
                boundaries.removeAll { waitingIDs.contains($0.clientMessageID) }
                if boundaries.isEmpty {
                    pendingPermissionTurnBoundariesBySessionID.removeValue(forKey: sessionID)
                } else {
                    pendingPermissionTurnBoundariesBySessionID[sessionID] = boundaries
                }
            }
        }
        stopQueuedSessionMonitoringIfIdle(sessionID: sessionID)
        queuedTurnAwaitingStartSessionIDs.remove(sessionID)
        queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
        guard markMessagesFailed else {
            return
        }
        for item in queued {
            conversationStore.updateSendStatus(
                clientMessageID: item.clientMessageID,
                sessionID: sessionID,
                status: .failed
            )
        }
    }

    func socketForQueuedDispatch(sessionID: SessionID) -> (any SessionWebSocketClient)? {
        if selectedSessionID == sessionID,
           connectedSessionID == sessionID,
           case .connected = webSocketStatus {
            return webSocket
        }
        guard queuedSessionReadyIDs.contains(sessionID) else {
            return nil
        }
        return queuedSessionSockets[sessionID]
    }

    func ensureQueuedSessionMonitoring(sessionID: SessionID) {
        guard queuedRunningTurnsBySessionID[sessionID]?.isEmpty == false
                || queuedTurnAwaitingStartSessionIDs.contains(sessionID)
                || queuedServerSubmissionAwaitingOutcomeBySessionID[sessionID] != nil,
              connectionTermination == nil,
              !appStore.requiresRePairing,
              appStore.isConfigured,
              !isAppInBackground,
              !isNetworkUnavailable,
              let session = sessionsByID[sessionID]
        else {
            return
        }

        if selectedSessionID == sessionID {
            if queuedSessionSockets[sessionID] != nil {
                stopQueuedSessionMonitoring(sessionID: sessionID)
            }
            if connectedSessionID != sessionID || webSocket == nil {
                connectWebSocket(session, replayBufferedEvents: true, allowNonRunning: true)
            }
            return
        }
        guard queuedSessionSockets[sessionID] == nil else {
            return
        }
        guard let credentialFingerprint = appStore.authenticatedCredentialFingerprint else {
            return
        }

        let generation = (queuedSessionSocketGenerationByID[sessionID] ?? 0) + 1
        queuedSessionSocketGenerationByID[sessionID] = generation
        let eventLease = HostSessionLease(
            hostScope: appStore.activeHostScope,
            sessionID: sessionID
        )
        let socket = sessionWebSocketFactory?(session) ?? webSocketFactory()
        socket.onStatus = { [weak self] status in
            Task { @MainActor in
                guard self?.isCurrentQueuedSessionSocket(sessionID: sessionID, generation: generation) == true else {
                    return
                }
                switch status {
                case .connected:
                    self?.queuedSessionReadyIDs.insert(sessionID)
                    self?.dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID)
                case .failed(let message):
                    self?.queuedSessionReadyIDs.remove(sessionID)
                    self?.setStatusMessage(L10n.format("ui.failed_to_connect_to_queue_to_be_sent", message))
                    self?.scheduleQueuedSessionReconnect(sessionID: sessionID, generation: generation)
                case .terminated(let reason):
                    guard let self else { return }
                    self.queuedSessionReadyIDs.remove(sessionID)
                    let socketFingerprint = self.queuedSessionCredentialFingerprintByID[sessionID]
                    if reason == .credentialsInvalid,
                       !self.appStore.isCurrentCredentialFingerprint(socketFingerprint) {
                        self.scheduleQueuedSessionReconnect(sessionID: sessionID, generation: generation)
                        return
                    }
                    self.terminateConnection(reason)
                case .disconnected:
                    self?.queuedSessionReadyIDs.remove(sessionID)
                    self?.scheduleQueuedSessionReconnect(sessionID: sessionID, generation: generation)
                case .connecting:
                    break
                }
            }
        }
        socket.onEvent = { [weak self] event in
            Task { @MainActor in
                guard self?.isCurrentQueuedSessionSocket(sessionID: sessionID, generation: generation) == true else {
                    return
                }
                await self?.applyRuntimeEvent(event, lease: eventLease)
            }
        }
        socket.onSendAccepted = { [weak self] clientMessageID in
            Task { @MainActor in
                guard self?.isCurrentQueuedSessionSocket(sessionID: sessionID, generation: generation) == true,
                      let clientMessageID else { return }
                _ = self?.handleQueuedSendAccepted(clientMessageID: clientMessageID, sessionID: sessionID)
            }
        }
        socket.onSendFailure = { [weak self] clientMessageID, message in
            Task { @MainActor in
                guard self?.isCurrentQueuedSessionSocket(sessionID: sessionID, generation: generation) == true,
                      let clientMessageID else { return }
                _ = self?.handleQueuedSendFailure(
                    clientMessageID: clientMessageID,
                    sessionID: sessionID,
                    message: message
                )
            }
        }
        socket.onTurnSendOutcome = { [weak self] clientMessageID, outcome in
            Task { @MainActor in
                guard let self else {
                    return
                }
                let isCurrentConnection = self.isCurrentQueuedSessionSocket(
                    sessionID: sessionID,
                    generation: generation
                )
                guard isCurrentConnection else {
                    return
                }
                self.handleTurnSendOutcome(
                    clientMessageID: clientMessageID,
                    sessionID: sessionID,
                    outcome: outcome
                )
            }
        }
        socket.onApprovalDecisionFailure = { _, _ in }
        socket.onUserInputResponseFailure = { _, _ in }
        socket.onControlFailure = { _ in }
        queuedSessionSockets[sessionID] = socket
        queuedSessionCredentialFingerprintByID[sessionID] = credentialFingerprint
        socket.connect(sessionID: sessionID, replayBufferedEvents: true)
    }

    func ensureAllQueuedSessionMonitoring() {
        let sessionIDs = Set(queuedRunningTurnsBySessionID.keys)
            .union(queuedTurnAwaitingStartSessionIDs)
            .union(queuedServerSubmissionAwaitingOutcomeBySessionID.keys)
        for sessionID in sessionIDs {
            ensureQueuedSessionMonitoring(sessionID: sessionID)
        }
    }

    func isCurrentQueuedSessionSocket(sessionID: SessionID, generation: Int) -> Bool {
        queuedSessionSockets[sessionID] != nil
            && queuedSessionSocketGenerationByID[sessionID] == generation
    }

    func stopQueuedSessionMonitoringIfIdle(sessionID: SessionID) {
        guard queuedRunningTurnsBySessionID[sessionID]?.isEmpty != false,
              !queuedTurnAwaitingStartSessionIDs.contains(sessionID),
              queuedServerSubmissionAwaitingOutcomeBySessionID[sessionID] == nil else { return }
        guard queuedSessionSockets[sessionID] != nil || queuedSessionReconnectTasks[sessionID] != nil else {
            return
        }
        stopQueuedSessionMonitoring(sessionID: sessionID)
    }

    func stopQueuedSessionMonitoring(sessionID: SessionID) {
        markDispatchingQueuedTurnsNeedsConfirmation(
            sessionID: sessionID,
            message: L10n.text("ui.the_connection_has_been_interrupted_sending_results_requires")
        )
        queuedSessionSocketGenerationByID[sessionID, default: 0] += 1
        queuedSessionReconnectTasks.removeValue(forKey: sessionID)?.cancel()
        queuedSessionReadyIDs.remove(sessionID)
        queuedSessionCredentialFingerprintByID.removeValue(forKey: sessionID)
        let socket = queuedSessionSockets.removeValue(forKey: sessionID)
        socket?.disconnect()
    }

    func scheduleQueuedSessionReconnect(sessionID: SessionID, generation: Int) {
        guard isCurrentQueuedSessionSocket(sessionID: sessionID, generation: generation),
              queuedRunningTurnsBySessionID[sessionID]?.isEmpty == false
                || queuedTurnAwaitingStartSessionIDs.contains(sessionID) else { return }
        markDispatchingQueuedTurnsNeedsConfirmation(
            sessionID: sessionID,
            message: L10n.text("ui.the_connection_has_been_interrupted_sending_results_requires")
        )
        let socket = queuedSessionSockets.removeValue(forKey: sessionID)
        queuedSessionCredentialFingerprintByID.removeValue(forKey: sessionID)
        queuedSessionSocketGenerationByID[sessionID, default: generation] += 1
        socket?.onStatus = nil
        socket?.disconnect()
        queuedSessionReconnectTasks[sessionID]?.cancel()
        queuedSessionReconnectTasks[sessionID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.queuedSessionReconnectTasks.removeValue(forKey: sessionID)
            self.ensureQueuedSessionMonitoring(sessionID: sessionID)
        }
    }

    func stopAllQueuedSessionMonitoring() {
        let sessionIDs = Set(queuedSessionSockets.keys).union(queuedSessionReconnectTasks.keys)
        for sessionID in sessionIDs {
            stopQueuedSessionMonitoring(sessionID: sessionID)
        }
    }

    func markDispatchingQueuedTurnsNeedsConfirmation(
        sessionID: SessionID,
        message: String
    ) {
        guard queuedRunningTurnsBySessionID[sessionID]?.contains(where: {
            $0.dispatchState == .dispatching && $0.serverSubmissionID == nil
        }) == true else {
            return
        }
        // 尚未收到 accepted 的 dispatching 项在连接退役后结果不确定，不能继续保留
        // awaiting-start 门闩；已经 accepted 且已离队的项则由重连继续等待 started。
        queuedTurnAwaitingStartSessionIDs.remove(sessionID)
        queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
        _ = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[sessionID] else { return }
            for index in queue.indices
            where queue[index].dispatchState == .dispatching
                && queue[index].serverSubmissionID == nil {
                queue[index].dispatchState = .needsConfirmation
                queue[index].lastError = message
            }
            queuedRunningTurnsBySessionID[sessionID] = queue
        }
    }

    func reconciledAcceptedDisposition(
        sessionID: SessionID,
        disposition: QueuedTurnAcceptedDisposition,
        ignoringActiveTurnID: TurnID? = nil
    ) -> QueuedTurnAcceptedDisposition {
        let reportedActiveTurnID = sessionsByID[sessionID]?.activeTurnID
        // guidance fallback 只忽略 RPC 前确认已经失效的精确 turn ID。
        let currentActiveTurnID = reportedActiveTurnID == ignoringActiveTurnID
            ? nil
            : reportedActiveTurnID
        func isTerminal(_ turnID: TurnID) -> Bool {
            conversationStore.turnLifecycle(
                sessionID: sessionID,
                turnID: turnID
            )?.isTerminal == true
        }

        switch disposition {
        case .serverQueued:
            return disposition
        case .awaitingStart(let turnID):
            if let turnID, isTerminal(turnID) {
                return .terminal(turnID: turnID)
            }
            if let currentActiveTurnID,
               currentActiveTurnID != turnID {
                return .superseded(turnID: turnID, activeTurnID: currentActiveTurnID)
            }
            return disposition
        case .terminal(let turnID):
            if let currentActiveTurnID,
               currentActiveTurnID != turnID {
                return .superseded(turnID: turnID, activeTurnID: currentActiveTurnID)
            }
            return disposition
        case .superseded(let turnID, let reportedActiveTurnID):
            let effectiveActiveTurnID: TurnID
            if let currentActiveTurnID,
               currentActiveTurnID != turnID,
               currentActiveTurnID != reportedActiveTurnID {
                effectiveActiveTurnID = currentActiveTurnID
            } else {
                effectiveActiveTurnID = reportedActiveTurnID
            }
            if isTerminal(effectiveActiveTurnID) {
                // 终态事件可能先于 superseded ACK 到达，不能再次复活已完成的 turn。
                return .terminal(turnID: effectiveActiveTurnID)
            }
            return .superseded(turnID: turnID, activeTurnID: effectiveActiveTurnID)
        case .threadClosed(let turnID):
            if let currentActiveTurnID,
               currentActiveTurnID != turnID {
                return .superseded(turnID: turnID, activeTurnID: currentActiveTurnID)
            }
            return disposition
        case .guidance:
            return disposition
        }
    }

    @discardableResult
    func handleQueuedSendAccepted(
        clientMessageID: ClientMessageID,
        sessionID: SessionID,
        disposition explicitDisposition: QueuedTurnAcceptedDisposition? = nil
    ) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              location.sessionID == sessionID,
              let item = queuedRunningTurnsBySessionID[sessionID]?[location.index],
              item.dispatchState == .dispatching || item.dispatchState == .needsConfirmation
        else {
            return false
        }
        if queuedServerSubmissionAwaitingOutcomeBySessionID[sessionID] == clientMessageID {
            queuedServerSubmissionAwaitingOutcomeBySessionID.removeValue(forKey: sessionID)
        }
        let wasGuidance = queuedGuidanceDispatchClientMessageIDs.remove(clientMessageID) != nil
        let ignoredStaleActiveTurnID: TurnID?
        if wasGuidance,
           case .awaitingStart = explicitDisposition {
            ignoredStaleActiveTurnID = item.expectedTurnID
        } else {
            ignoredStaleActiveTurnID = nil
        }
        let disposition = reconciledAcceptedDisposition(
            sessionID: sessionID,
            disposition: explicitDisposition
                ?? (wasGuidance
                    ? .guidance
                    : .awaitingStart(turnID: nil)),
            ignoringActiveTurnID: ignoredStaleActiveTurnID
        )

        guard mutateAndPersistQueuedTurns({
            guard var queue = queuedRunningTurnsBySessionID[sessionID],
                  queue.indices.contains(location.index) else { return }
            queue.remove(at: location.index)
            switch disposition {
            case .serverQueued:
                break
            case .awaitingStart(let turnID):
                let blockedCompletionID = queuedTurnBlockedCompletionIDBySessionID[sessionID]
                for index in queue.indices where queue[index].dispatchState == .waiting {
                    // guidance 已由 Runtime 降级为新的 turn/start 时，ACK 中的精确 ID
                    // 就是本地权威状态；普通发送仍要等待 started 事件解除门闩。
                    queue[index].waitsForAcceptedTurnStart = wasGuidance ? nil : true
                    queue[index].blockedCompletionID = wasGuidance ? nil : blockedCompletionID
                    queue[index].expectedTurnID = turnID
                }
            case .superseded(_, let activeTurnID):
                for index in queue.indices where queue[index].dispatchState == .waiting {
                    queue[index].waitsForAcceptedTurnStart = nil
                    queue[index].blockedCompletionID = nil
                    queue[index].expectedTurnID = activeTurnID
                }
            case .terminal:
                for index in queue.indices where queue[index].dispatchState == .waiting {
                    queue[index].waitsForAcceptedTurnStart = nil
                    queue[index].blockedCompletionID = nil
                    queue[index].expectedTurnID = nil
                }
            case .threadClosed:
                for index in queue.indices where queue[index].dispatchState == .waiting {
                    queue[index].waitsForAcceptedTurnStart = nil
                    queue[index].blockedCompletionID = nil
                    queue[index].expectedTurnID = nil
                }
            case .guidance:
                break
            }
            setQueuedTurns(queue, sessionID: sessionID)
        }) else {
            return true
        }
        switch disposition {
        case .serverQueued:
            break
        case .awaitingStart(let turnID):
            if wasGuidance, let turnID {
                // stale guidance 在 RPC 前确认 active turn 缺失后会降级为新的 turn/start。
                // 只有这一条显式 accepted 路径可以把 ACK 中的新 turn 设为本地权威状态；
                // terminal / superseded 已在上面的 disposition 对账中被改写，不会复活旧 turn。
                updateSession(sessionID) { session in
                    session.status = SessionStatus.running.rawValue
                    session.activeTurnID = turnID
                }
            }
        case .guidance:
            break
        case .terminal(let turnID):
            queuedTurnAwaitingStartSessionIDs.remove(sessionID)
            queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
            let terminalStatus = turnID.flatMap {
                conversationStore.turnLifecycle(sessionID: sessionID, turnID: $0)
            } == .failed ? SessionStatus.failed : .completed
            updateSession(sessionID) { session in
                guard session.activeTurnID == nil
                        || session.activeTurnID == turnID else {
                    return
                }
                // external activity 误判可能已把已完成会话重写为 running；ACK 必须恢复终态。
                session.status = terminalStatus.rawValue
                session.activeTurnID = nil
            }
        case .superseded(let turnID, let activeTurnID):
            queuedTurnAwaitingStartSessionIDs.remove(sessionID)
            queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
            updateSession(sessionID) { session in
                guard session.activeTurnID == nil
                        || session.activeTurnID == turnID
                        || session.activeTurnID == activeTurnID else {
                    return
                }
                session.status = SessionStatus.running.rawValue
                session.activeTurnID = activeTurnID
            }
        case .threadClosed(let turnID):
            queuedTurnAwaitingStartSessionIDs.remove(sessionID)
            queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
            updateSession(sessionID) { session in
                guard session.activeTurnID == nil
                        || session.activeTurnID == turnID else {
                    return
                }
                session.status = "closed"
                session.activeTurnID = nil
            }
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
        if case .terminal = disposition {
            // 终态早于 ACK 时，对应 completion 已经过去；持久化移除首项后立即推进 FIFO。
            dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID)
        }
        return true
    }

    @discardableResult
    func handleServerQueueReceiptAccepted(
        clientMessageID: ClientMessageID,
        sessionID: SessionID,
        submissionID: String,
        startedTurnID: TurnID? = nil
    ) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              location.sessionID == sessionID,
              let item = queuedRunningTurnsBySessionID[sessionID]?[location.index],
              item.dispatchState == .dispatching || item.dispatchState == .needsConfirmation else {
            return false
        }
        if queuedServerSubmissionAwaitingOutcomeBySessionID[sessionID] == clientMessageID {
            queuedServerSubmissionAwaitingOutcomeBySessionID.removeValue(forKey: sessionID)
        }
        let alreadyStartedTurnID = item.serverStartedTurnID ?? startedTurnID
        if alreadyStartedTurnID != nil {
            // queue/items reconciliation 返回的精确 started 证据强于 queue/add ACK。
            // 直接用一次持久化事务完成该项，避免先标记 sent、后续移除失败。
            return finishServerQueuedTurnStart(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                turnID: alreadyStartedTurnID
            )
        }
        guard mutateAndPersistQueuedTurns({
            guard var queue = queuedRunningTurnsBySessionID[sessionID],
                  queue.indices.contains(location.index),
                  queue[location.index].clientMessageID == clientMessageID else { return }
            queue[location.index].dispatchState = .dispatching
            queue[location.index].serverSubmissionID = submissionID
            queue[location.index].serverStartedTurnID = alreadyStartedTurnID
            queue[location.index].lastError = nil
            queuedRunningTurnsBySessionID[sessionID] = queue
        }) else {
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
        return true
    }

    @discardableResult
    func handleServerQueueTurnStarted(
        clientMessageID: ClientMessageID,
        sessionID: SessionID,
        turnID: TurnID?
    ) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              location.sessionID == sessionID,
              let item = queuedRunningTurnsBySessionID[sessionID]?[location.index],
              item.dispatchState == .dispatching || item.dispatchState == .needsConfirmation else {
            return false
        }
        // 调用方只在 userMessage 携带精确 client ID 时进入这里。该证据足以确认
        // App Server 已接收并启动，不依赖可能已经丢失的 queue/add ACK。
        return finishServerQueuedTurnStart(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            turnID: turnID
        )
    }

    @discardableResult
    func finishServerQueuedTurnStart(
        clientMessageID: ClientMessageID,
        sessionID: SessionID,
        turnID: TurnID?
    ) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              location.sessionID == sessionID else { return false }
        let awaitsSubmissionOutcome = queuedServerSubmissionAwaitingOutcomeBySessionID[sessionID]
            == clientMessageID
        guard mutateAndPersistQueuedTurns({
            guard var queue = queuedRunningTurnsBySessionID[sessionID],
                  queue.indices.contains(location.index),
                  queue[location.index].clientMessageID == clientMessageID else { return }
            queue.remove(at: location.index)
            setQueuedTurns(queue, sessionID: sessionID)
        }) else {
            return false
        }
        let markedSent = conversationStore.updateSendStatus(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            status: .sent
        )
        if !markedSent {
            // 结果不确定时 UI 会先标记 failed。精确 started 已证明服务端接收，
            // 先进入允许重试的 sending，再收敛到 sent；confirmed 仍保持终态不回退。
            if conversationStore.updateSendStatus(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                status: .sending
            ) {
                conversationStore.updateSendStatus(
                    clientMessageID: clientMessageID,
                    sessionID: sessionID,
                    status: .sent
                )
            }
        }
        conversationStore.compactTurnPayloadAfterSendAccepted(
            clientMessageID: clientMessageID,
            sessionID: sessionID
        )
        if let turnID {
            conversationStore.bindTurnID(
                turnID,
                clientMessageID: clientMessageID,
                sessionID: sessionID
            )
        }
        if awaitsSubmissionOutcome {
            // started 是已接收的强证据，但 queue/add Task 仍可能持有 Runtime 单提交保护。
            // 保留 session 门闩，等同一 client ID 的 outcome 回调后再推进 FIFO。
            queuedServerSubmissionStartedBeforeOutcomeClientMessageIDs.insert(clientMessageID)
            return true
        }
        queuedTurnAwaitingStartSessionIDs.remove(sessionID)
        queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
        dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID)
        stopQueuedSessionMonitoringIfIdle(sessionID: sessionID)
        return true
    }

    func serverQueueDeliveryActive(sessionID: SessionID) -> Bool {
        if connectedSessionID == sessionID {
            return webSocket?.turnDeliveryMode == .sharedServerQueue
        }
        return queuedSessionSockets[sessionID]?.turnDeliveryMode == .sharedServerQueue
    }

    @discardableResult
    func handleQueuedSendFailure(
        clientMessageID: ClientMessageID,
        sessionID: SessionID,
        message: String
    ) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              location.sessionID == sessionID,
              queuedRunningTurnsBySessionID[sessionID]?[location.index].dispatchState == .dispatching
        else {
            return false
        }
        if queuedServerSubmissionAwaitingOutcomeBySessionID[sessionID] == clientMessageID {
            queuedServerSubmissionAwaitingOutcomeBySessionID.removeValue(forKey: sessionID)
        }
        queuedGuidanceDispatchClientMessageIDs.remove(clientMessageID)
        _ = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[sessionID],
                  queue.indices.contains(location.index) else { return }
            queue[location.index].dispatchState = .needsConfirmation
            queue[location.index].lastError = L10n.format("ui.uncertain_sending_result_value", message)
            queuedRunningTurnsBySessionID[sessionID] = queue
        }
        conversationStore.updateSendStatus(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            status: .failed
        )
        clearForegroundActivity(sessionID: sessionID)
        queuedTurnAwaitingStartSessionIDs.remove(sessionID)
        queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
        setErrorMessage(L10n.format("ui.the_result_of_the_message_to_be_sent", message))
        return true
    }

    @discardableResult
    func handleQueuedActiveTurnConflict(
        clientMessageID: ClientMessageID,
        sessionID: SessionID,
        activeTurnID: TurnID
    ) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              location.sessionID == sessionID,
              let item = queuedRunningTurnsBySessionID[sessionID]?[location.index],
              item.dispatchState == .dispatching else {
            return false
        }
        if queuedServerSubmissionAwaitingOutcomeBySessionID[sessionID] == clientMessageID {
            queuedServerSubmissionAwaitingOutcomeBySessionID.removeValue(forKey: sessionID)
        }
        // guidance fallback 已发现权威的新 active turn；清掉旧 steer 标记，
        // 后续等待项再派发时必须完全按普通 turn/start 处理。
        queuedGuidanceDispatchClientMessageIDs.remove(clientMessageID)
        queuedTurnAwaitingStartSessionIDs.remove(sessionID)
        queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
        guard mutateAndPersistQueuedTurns({
            guard var queue = queuedRunningTurnsBySessionID[sessionID],
                  queue.indices.contains(location.index) else { return }
            queue[location.index].dispatchState = .waiting
            queue[location.index].expectedTurnID = activeTurnID
            queue[location.index].lastError = nil
            queuedRunningTurnsBySessionID[sessionID] = queue
        }) else {
            return true
        }
        conversationStore.appendLocalUser(
            item.previewText,
            sessionID: sessionID,
            clientMessageID: clientMessageID,
            sendStatus: .local,
            turnPayload: item.payload,
            userDelivery: .queued
        )
        ensureQueuedSessionMonitoring(sessionID: sessionID)
        return true
    }

    @discardableResult
    func handleQueuedSendRejected(
        clientMessageID: ClientMessageID,
        sessionID: SessionID,
        message: String
    ) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              location.sessionID == sessionID,
              queuedRunningTurnsBySessionID[sessionID]?[location.index].dispatchState == .dispatching else {
            return false
        }
        if queuedServerSubmissionAwaitingOutcomeBySessionID[sessionID] == clientMessageID {
            queuedServerSubmissionAwaitingOutcomeBySessionID.removeValue(forKey: sessionID)
        }
        queuedTurnAwaitingStartSessionIDs.remove(sessionID)
        queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
        _ = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[sessionID],
                  queue.indices.contains(location.index) else { return }
            let removed = queue.remove(at: location.index)
            if let boundary = removePendingPermissionTurnBoundary(
                sessionID: sessionID,
                clientMessageID: removed.clientMessageID
            ) {
                permissionTurnRetryRequirementsByClientMessageID[removed.clientMessageID] = boundary
                for index in queue.indices where queue[index].waitsForAcceptedTurnStart == true {
                    queue[index].waitsForAcceptedTurnStart = nil
                    queue[index].blockedCompletionID = nil
                    queue[index].expectedTurnID = sessionsByID[sessionID]?.activeTurnID
                }
            }
            setQueuedTurns(queue, sessionID: sessionID)
        }
        conversationStore.updateSendStatus(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            status: .failed
        )
        clearForegroundActivity(sessionID: sessionID)
        clearSessionListProjection(sessionID: sessionID, clientMessageID: clientMessageID)
        setErrorMessage(L10n.format("ui.sending_failed_value", message))
        stopQueuedSessionMonitoringIfIdle(sessionID: sessionID)
        return true
    }

    func reconcilePersistedQueuedTurns() async {
        guard !queuedRunningTurnsBySessionID.isEmpty,
              connectionTermination == nil,
              !appStore.requiresRePairing,
              !isNetworkUnavailable
        else {
            return
        }
        let client: any SessionStoreAPIClient
        do {
            client = try clientFactory()
        } catch {
            return
        }

        // 每个有待发项的 thread 只做一次有界快照/历史核对。这里宁可要求用户确认重试，
        // 也不在 client_message_id 是否已落库不明确时盲目重放。
        for sessionID in Array(queuedRunningTurnsBySessionID.keys) {
            var authoritativeSession = sessionsByID[sessionID]
            if authoritativeSession == nil {
                do {
                    let response = try await client.session(id: sessionID, afterSeq: replayWatermark(for: sessionID))
                    let aligned = session(response.session, in: nil)
                    upsert(aligned)
                    authoritativeSession = aligned
                } catch {
                    continue
                }
            }

            let currentQueue = queuedRunningTurnsBySessionID[sessionID] ?? []
            let queuedClientMessageIDs = Set(currentQueue.map(\.clientMessageID))
            let ambiguousIDs = Set(
                currentQueue
                    .filter { $0.dispatchState == .needsConfirmation }
                    .map(\.clientMessageID)
            )
            let confirmedServerQueueIDs = Set(
                currentQueue
                    .filter { $0.dispatchState == .dispatching && $0.serverSubmissionID != nil }
                    .map(\.clientMessageID)
            )
            let reconcilableIDs = ambiguousIDs.union(confirmedServerQueueIDs)
            let hasPersistedAcceptedStartBarrier = currentQueue.contains {
                $0.dispatchState == .waiting && $0.waitsForAcceptedTurnStart == true
            }
            let hasOrphanPermissionBoundary = pendingPermissionTurnBoundariesBySessionID[sessionID]?
                .contains(where: { !queuedClientMessageIDs.contains($0.clientMessageID) }) == true
            if !reconcilableIDs.isEmpty
                || hasOrphanPermissionBoundary
                || hasPersistedAcceptedStartBarrier {
                var deliveredIDs = Set<ClientMessageID>()
                var startedTurnIDs = Set<TurnID>()
                var before: String?
                var seenCursors = Set<String>()
                while true {
                    guard let page = try? await client.messagesPage(
                        sessionID: sessionID,
                        before: before,
                        limit: 60,
                        loadMode: .full
                    ) else { break }
                    deliveredIDs.formUnion(
                        Set(page.messages.compactMap(\.clientMessageID)).intersection(reconcilableIDs)
                    )
                    startedTurnIDs.formUnion(page.messages.compactMap { message -> TurnID? in
                        guard let turnID = message.turnID?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                              !turnID.isEmpty else { return nil }
                        return turnID
                    })
                    reconcilePendingPermissionTurnBoundaries(
                        sessionID: sessionID,
                        historyMessages: page.messages
                    )

                    // Durable receipt 可能早于最近一页。必须找到全部目标或读到 EOF，
                    // 但仍只读不重发 queue/add。重复 cursor 直接停止，避免协议异常死循环。
                    guard !reconcilableIDs.isEmpty,
                          !reconcilableIDs.isSubset(of: deliveredIDs),
                          page.hasMoreBefore,
                          let cursor = page.previousCursor?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                          !cursor.isEmpty,
                          seenCursors.insert(cursor).inserted else { break }
                    before = cursor
                }
                if !deliveredIDs.isEmpty || !startedTurnIDs.isEmpty {
                    _ = mutateAndPersistQueuedTurns {
                        guard var queue = queuedRunningTurnsBySessionID[sessionID] else { return }
                        queue.removeAll { deliveredIDs.contains($0.clientMessageID) }
                        for index in queue.indices
                        where queue[index].dispatchState == .waiting
                            && queue[index].waitsForAcceptedTurnStart == true
                            && queue[index].expectedTurnID.map(startedTurnIDs.contains) == true {
                            queue[index].waitsForAcceptedTurnStart = nil
                            queue[index].blockedCompletionID = nil
                        }
                        setQueuedTurns(queue, sessionID: sessionID)
                    }
                }
            }

            guard let authoritativeSession,
                  queuedRunningTurnsBySessionID[sessionID]?.first?.dispatchState == .waiting else {
                ensureQueuedSessionMonitoring(sessionID: sessionID)
                continue
            }
            _ = mutateAndPersistQueuedTurns {
                guard var queue = queuedRunningTurnsBySessionID[sessionID] else { return }
                for index in queue.indices where queue[index].dispatchState == .waiting {
                    if let activeTurnID = authoritativeSession.activeTurnID {
                        // 权威快照已确认上一条真正开始，持久化门闩可以转成具体 turn 等待。
                        queue[index].expectedTurnID = activeTurnID
                        queue[index].waitsForAcceptedTurnStart = nil
                        queue[index].blockedCompletionID = nil
                    } else if queue[index].waitsForAcceptedTurnStart != true {
                        // 普通等待项在权威快照 idle 时可恢复派发；accepted-but-not-started
                        // 门闩仍等待事件回放，避免瞬时 idle 把下一条注入尚未显现的 turn。
                        queue[index].expectedTurnID = nil
                    }
                }
                queuedRunningTurnsBySessionID[sessionID] = queue
            }
            ensureQueuedSessionMonitoring(sessionID: sessionID)
            dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID)
        }
    }

    func handleTurnSendOutcome(
        clientMessageID: ClientMessageID?,
        sessionID: SessionID,
        outcome: TurnSendOutcome
    ) {
        let resolvedServerSubmissionClientMessageID: ClientMessageID?
        if let clientMessageID,
           queuedServerSubmissionAwaitingOutcomeBySessionID[sessionID] == clientMessageID {
            queuedServerSubmissionAwaitingOutcomeBySessionID.removeValue(forKey: sessionID)
            resolvedServerSubmissionClientMessageID = clientMessageID
        } else {
            resolvedServerSubmissionClientMessageID = nil
        }
        if let resolvedServerSubmissionClientMessageID,
           queuedServerSubmissionStartedBeforeOutcomeClientMessageIDs.remove(
               resolvedServerSubmissionClientMessageID
           ) != nil {
            // 精确 started 已确认服务端接收。迟到 outcome 只释放 RPC 门闩，
            // 即使它报告 uncertain/rejected，也不能把更强的 started 证据降级为失败。
            if case .serverQueued(_, let startedTurnID) = outcome,
               let startedTurnID {
                conversationStore.bindTurnID(
                    startedTurnID,
                    clientMessageID: resolvedServerSubmissionClientMessageID,
                    sessionID: sessionID
                )
            }
            queuedTurnAwaitingStartSessionIDs.remove(sessionID)
            queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
            dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID)
            stopQueuedSessionMonitoringIfIdle(sessionID: sessionID)
            return
        }
        let acceptedTurnID: TurnID?
        switch outcome {
        case .accepted(let turnID),
             .acceptedTerminal(let turnID),
             .acceptedThreadClosed(let turnID):
            acceptedTurnID = turnID
        case .acceptedSuperseded(let turnID, _):
            acceptedTurnID = turnID
        case .serverQueued,
             .guidanceAccepted,
             .activeTurnConflict,
             .rejected,
             .uncertain:
            acceptedTurnID = nil
        }

        if let clientMessageID, let acceptedTurnID {
            conversationStore.bindTurnID(
                acceptedTurnID,
                clientMessageID: clientMessageID,
                sessionID: sessionID
            )
        }
        guard let clientMessageID else { return }

        func finishAccepted(_ disposition: QueuedTurnAcceptedDisposition) {
            if handleQueuedSendAccepted(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                disposition: disposition
            ) {
                return
            }
            let disposition = reconciledAcceptedDisposition(
                sessionID: sessionID,
                disposition: disposition
            )
            conversationStore.updateSendStatus(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                status: .sent
            )
            conversationStore.compactTurnPayloadAfterSendAccepted(
                clientMessageID: clientMessageID,
                sessionID: sessionID
            )
            // 非队列消息也必须 compare-and-apply，避免覆盖已经到达的更新 turn。
            switch disposition {
            case .terminal(let turnID):
                let terminalStatus = turnID.flatMap {
                    conversationStore.turnLifecycle(sessionID: sessionID, turnID: $0)
                } == .failed ? SessionStatus.failed : .completed
                updateSession(sessionID) { session in
                    guard session.activeTurnID == nil || session.activeTurnID == turnID else {
                        return
                    }
                    session.status = terminalStatus.rawValue
                    session.activeTurnID = nil
                }
            case .superseded(let turnID, let activeTurnID):
                updateSession(sessionID) { session in
                    guard session.activeTurnID == nil
                            || session.activeTurnID == turnID
                            || session.activeTurnID == activeTurnID else {
                        return
                    }
                    session.status = SessionStatus.running.rawValue
                    session.activeTurnID = activeTurnID
                }
            case .threadClosed(let turnID):
                updateSession(sessionID) { session in
                    guard session.activeTurnID == nil || session.activeTurnID == turnID else {
                        return
                    }
                    session.status = "closed"
                    session.activeTurnID = nil
                }
            case .awaitingStart, .guidance, .serverQueued:
                break
            }
        }

        switch outcome {
        case .serverQueued(let submissionID, let startedTurnID):
            _ = handleServerQueueReceiptAccepted(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                submissionID: submissionID,
                startedTurnID: startedTurnID
            )
            // queue/add ACK 只有在 receipt 持久化成功后才能推进发送状态。
            // 持久化失败时保留 sending，不能用内存态冒充可恢复确认。
        case .accepted(let turnID):
            finishAccepted(.awaitingStart(turnID: turnID))
        case .acceptedTerminal(let turnID):
            finishAccepted(.terminal(turnID: turnID))
        case .acceptedSuperseded(let turnID, let activeTurnID):
            finishAccepted(.superseded(turnID: turnID, activeTurnID: activeTurnID))
        case .acceptedThreadClosed(let turnID):
            finishAccepted(.threadClosed(turnID: turnID))
        case .guidanceAccepted:
            finishAccepted(.guidance)
        case .activeTurnConflict(let activeTurnID, let message):
            // 新消息未被接受。保留权威 active turn，并让排队项等待原 turn 完成。
            updateSession(sessionID) { item in
                item.activeTurnID = activeTurnID
                if item.pendingUserInput != nil {
                    item.status = "waiting_for_input"
                } else if item.pendingApproval != nil {
                    item.status = "waiting_for_approval"
                } else {
                    item.status = "running"
                }
            }
            if handleQueuedActiveTurnConflict(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                activeTurnID: activeTurnID
            ) {
                setStatusMessage(L10n.text("ui.saved_to_this_machine_and_will_be_sent"))
                return
            }
            preservePermissionTurnRetryRequirementAfterRejection(
                sessionID: sessionID,
                clientMessageID: clientMessageID
            )
            conversationStore.updateSendStatus(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                status: .failed
            )
            setStatusMessage(message)
        case .rejected(let message):
            if handleQueuedSendRejected(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                message: message
            ) {
                return
            }
            preservePermissionTurnRetryRequirementAfterRejection(
                sessionID: sessionID,
                clientMessageID: clientMessageID
            )
            conversationStore.updateSendStatus(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                status: .failed
            )
            clearForegroundActivity(sessionID: sessionID)
            setErrorMessage(L10n.format("ui.sending_failed_value", message))
        case .uncertain(let message):
            if handleQueuedSendFailure(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                message: message
            ) {
                return
            }
            conversationStore.updateSendStatus(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                status: .failed
            )
            clearForegroundActivity(sessionID: sessionID)
            setErrorMessage(L10n.format("ui.the_result_of_the_message_to_be_sent", message))
        }
    }
}
