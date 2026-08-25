import Foundation

// 排队 Turn 的调度、连接监控、发送结果归并与持久化对账集中在同一协调边界。
extension SessionStore {
    func dispatchNextQueuedRunningTurnIfIdle(sessionID: SessionID) {
        guard let session = sessionsByID[sessionID],
              !queuedTurnAwaitingStartSessionIDs.contains(sessionID),
              session.activeTurnID == nil,
              let queue = queuedRunningTurnsBySessionID[sessionID],
              let next = queue.first,
              next.dispatchState == .waiting,
              next.waitsForAcceptedTurnStart != true,
              next.expectedTurnID == nil
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
        guard canControlSession(session) else {
            setStatusMessage(L10n.text("ui.message_to_be_sent_is_waiting_please_take"))
            return
        }
        guard let socket = socketForQueuedDispatch(sessionID: sessionID) else {
            ensureQueuedSessionMonitoring(sessionID: sessionID)
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
        guard socket.sendTurn(item.payload, clientMessageID: item.clientMessageID) else {
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
                || queuedTurnAwaitingStartSessionIDs.contains(sessionID),
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
                guard isCurrentConnection ||
                        self.canReconcileTurnOutcomeFromRetiredSocket(
                            sessionID: sessionID,
                            outcome: outcome,
                            hostScope: eventLease.hostScope
                        ) else {
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
              !queuedTurnAwaitingStartSessionIDs.contains(sessionID) else { return }
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
            $0.dispatchState == .dispatching
        }) == true else {
            return
        }
        // 尚未收到 accepted 的 dispatching 项在连接退役后结果不确定，不能继续保留
        // awaiting-start 门闩；已经 accepted 且已离队的项则由重连继续等待 started。
        queuedTurnAwaitingStartSessionIDs.remove(sessionID)
        queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
        _ = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[sessionID] else { return }
            for index in queue.indices where queue[index].dispatchState == .dispatching {
                queue[index].dispatchState = .needsConfirmation
                queue[index].lastError = message
            }
            queuedRunningTurnsBySessionID[sessionID] = queue
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
            case .awaitingStart(let turnID):
                let blockedCompletionID = queuedTurnBlockedCompletionIDBySessionID[sessionID]
                for index in queue.indices where queue[index].dispatchState == .waiting {
                    // ACK 带 turnID 仍不等于已观察到 started。门闩和精确 ID 必须一起
                    // 持久化，避免 ACK 后崩溃时重启把 expectedTurnID 当成陈旧状态清掉。
                    queue[index].waitsForAcceptedTurnStart = true
                    queue[index].blockedCompletionID = blockedCompletionID
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
            let hasPersistedAcceptedStartBarrier = currentQueue.contains {
                $0.dispatchState == .waiting && $0.waitsForAcceptedTurnStart == true
            }
            let hasOrphanPermissionBoundary = pendingPermissionTurnBoundariesBySessionID[sessionID]?
                .contains(where: { !queuedClientMessageIDs.contains($0.clientMessageID) }) == true
            if (!ambiguousIDs.isEmpty
                    || hasOrphanPermissionBoundary
                    || hasPersistedAcceptedStartBarrier),
               let page = try? await client.messagesPage(
                    sessionID: sessionID,
                    before: nil,
                    limit: 60,
                    loadMode: .full
               ) {
                let deliveredIDs = Set(page.messages.compactMap(\.clientMessageID)).intersection(ambiguousIDs)
                let startedTurnIDs = Set(page.messages.compactMap { message -> TurnID? in
                    guard let turnID = message.turnID?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !turnID.isEmpty else { return nil }
                    return turnID
                })
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
                reconcilePendingPermissionTurnBoundaries(
                    sessionID: sessionID,
                    historyMessages: page.messages
                )
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
}
