import Foundation

enum QueuedTurnAcceptedDisposition {
    case awaitingStart(turnID: TurnID?)
    case guidance
    case terminal(turnID: TurnID?)
    case superseded(
        turnID: TurnID?,
        activeTurnID: TurnID
    )
    case threadClosed(turnID: TurnID?)
}

// Codex Desktop 与 Mimi 的 app-server 是两个独立进程，runtime status 不能跨进程复用。
// 这里消费 agentd 从 rollout 提炼出的只读活动层；所有消息仍走现有历史读取，不建立控制连接。
extension SessionStore {
    func isLocallyStartedExternalActivity(_ activity: ExternalSessionActivity) -> Bool {
        guard let turnID = activity.turnID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !turnID.isEmpty else {
            return false
        }
        return locallyStartedTurnIDBySessionID[activity.threadID] == turnID
    }

    /// 记录由当前 iPad 明确启动成功的 turn，并撤销轮询先于 ACK 时造成的误判。
    ///
    /// 这里只接受精确的 session + turnID 证据。持久化控制状态、运行状态或 thread originator
    /// 都不足以证明当前 turn 的所有权，不能用于清除真实的 Mac 只读边界。
    @discardableResult
    func recordLocallyStartedTurn(
        sessionID: SessionID,
        turnID rawTurnID: TurnID,
        restoreSelectedConnection: Bool = true
    ) -> Bool {
        let turnID = rawTurnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !turnID.isEmpty else {
            return false
        }
        locallyStartedTurnIDBySessionID[sessionID] = turnID

        let externalTurnID = externalActivityBySessionID[sessionID]?.turnID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTurnID = sessionsByID[sessionID]?.activeTurnID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesMisclassifiedTurn = externalTurnID == turnID ||
            (externalReadOnlySessionIDs.contains(sessionID) && sessionTurnID == turnID)
        guard matchesMisclassifiedTurn else {
            return false
        }

        externalActivityBySessionID.removeValue(forKey: sessionID)
        externalReadOnlySessionIDs.remove(sessionID)
        updateSession(sessionID) { session in
            session.status = SessionStatus.running.rawValue
            session.activeTurnID = turnID
        }

        if restoreSelectedConnection,
           selectedSessionID == sessionID,
           let session = sessionsByID[sessionID] {
            // external snapshot 已退役旧 socket；精确 ACK 到达后恢复本轮事件流。
            // 历史内容已在断线前或 create/resume 流程中对账，这里只回放状态边界。
            connectWebSocket(session, replayBufferedEvents: false)
        }
        return true
    }

    func canReconcileAcceptedTurnFromRetiredSocket(
        sessionID: SessionID,
        outcome: TurnSendOutcome,
        hostScope: HostScope
    ) -> Bool {
        guard appStore.activeHostScope == hostScope,
              sessionsByID[sessionID] != nil,
              let acceptedTurnID = acceptedTurnID(from: outcome) else {
            return false
        }
        let normalizedTurnID = acceptedTurnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTurnID.isEmpty else {
            return false
        }
        let externalTurnID = externalActivityBySessionID[sessionID]?.turnID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTurnID = sessionsByID[sessionID]?.activeTurnID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return externalTurnID == normalizedTurnID ||
            (externalReadOnlySessionIDs.contains(sessionID) && sessionTurnID == normalizedTurnID)
    }

    func acceptedTurnID(from outcome: TurnSendOutcome) -> TurnID? {
        switch outcome {
        case .accepted(let turnID),
             .acceptedTerminal(let turnID),
             .acceptedThreadClosed(let turnID):
            return turnID
        case .acceptedSuperseded(let turnID, _):
            return turnID
        case .guidanceAccepted,
             .activeTurnConflict,
             .rejected,
             .uncertain:
            return nil
        }
    }

    func reconciledAcceptedDisposition(
        sessionID: SessionID,
        disposition: QueuedTurnAcceptedDisposition,
        ignoringActiveTurnID: TurnID? = nil
    ) -> QueuedTurnAcceptedDisposition {
        let reportedActiveTurnID = sessionsByID[sessionID]?.activeTurnID
        // guidance fallback 的前提是 Runtime 已在 RPC 前确认旧 expected turn 不存在。
        // 只忽略这一个精确 ID；期间若出现其它 active turn，仍按 superseded 保护。
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
        case .awaitingStart(let turnID):
            if let turnID, isTerminal(turnID) {
                return .terminal(turnID: turnID)
            }
            if let currentActiveTurnID,
               currentActiveTurnID != turnID {
                return .superseded(
                    turnID: turnID,
                    activeTurnID: currentActiveTurnID
                )
            }
            return disposition
        case .terminal(let turnID):
            if let currentActiveTurnID,
               currentActiveTurnID != turnID {
                return .superseded(
                    turnID: turnID,
                    activeTurnID: currentActiveTurnID
                )
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
                // completed(B) 可能先于 superseded(A,B) 落到 MainActor；lifecycle 是
                // 不会随 activeTurnID 清空而丢失的终态证据，禁止再次复活 B。
                return .terminal(turnID: effectiveActiveTurnID)
            }
            return .superseded(
                turnID: turnID,
                activeTurnID: effectiveActiveTurnID
            )
        case .threadClosed(let turnID):
            if let currentActiveTurnID,
               currentActiveTurnID != turnID {
                return .superseded(
                    turnID: turnID,
                    activeTurnID: currentActiveTurnID
                )
            }
            return disposition
        case .guidance:
            return disposition
        }
    }

    func externalActivityPollingDelayNanoseconds() -> UInt64 {
        if let selectedSessionID,
           externalActivityBySessionID[selectedSessionID] != nil {
            return externalActivitySelectedPollingDelayNanoseconds
        }
        return externalActivityDefaultPollingDelayNanoseconds
    }

    func pollExternalActivitiesWhileVisible() async {
        while !Task.isCancelled {
            if connectionTermination != nil || appStore.requiresRePairing {
                return
            }
#if DEBUG
            if isDebugWorkbenchUISeedActive {
                return
            }
#endif
            if !isAppInBackground,
               !isNetworkUnavailable,
               appStore.isConfigured {
                if isConversationTimelineInteractionActive {
                    deferredExternalActivityVisiblePoll = true
                } else {
                    _ = await refreshExternalActivities(deferWhileTimelineScrolling: true)
                }
                if externalActivityCapabilityUnavailable {
                    // 旧 agentd 没有该 capability 时结束本次前台轮询，不制造 404/配置请求噪音。
                    return
                }
            }
            let delay = externalActivityPollingDelayNanoseconds()
            await externalActivitySleep(delay)
        }
    }

    @discardableResult
    func refreshExternalActivities(
        client fixedClient: (any SessionStoreAPIClient)? = nil,
        deferWhileTimelineScrolling: Bool = false
    ) async -> Bool {
        if deferWhileTimelineScrolling, isConversationTimelineInteractionActive {
            deferredExternalActivityVisiblePoll = true
            return false
        }
        guard !isRefreshingExternalActivity,
              !isAppInBackground,
              !isNetworkUnavailable,
              appStore.isConfigured,
              connectionTermination == nil,
              !appStore.requiresRePairing else {
            return false
        }
        isRefreshingExternalActivity = true
        defer { isRefreshingExternalActivity = false }

        let hostScope = appStore.activeHostScope
        let client: any SessionStoreAPIClient
        do {
            client = try fixedClient ?? clientFactory()
        } catch {
            return false
        }

        do {
            guard let response = try await client.externalActivities() else {
                guard appStore.activeHostScope == hostScope else { return false }
                // 同一主机降级到旧 agentd 时不能把上次缓存的 Mac 活动态永久留在“进行中”。
                // 按空快照完成最后一次只读收尾，再停止本次前台轮询。
                await applyExternalActivitySnapshot(
                    [],
                    client: client,
                    hostScope: hostScope,
                    deferWhileTimelineScrolling: deferWhileTimelineScrolling
                )
                guard appStore.activeHostScope == hostScope else { return false }
                externalActivityCapabilityUnavailable = true
                return false
            }
            guard appStore.activeHostScope == hostScope else {
                return false
            }
            externalActivityCapabilityUnavailable = false
            await applyExternalActivitySnapshot(
                response.activities,
                client: client,
                hostScope: hostScope,
                deferWhileTimelineScrolling: deferWhileTimelineScrolling
            )
            return appStore.activeHostScope == hostScope
        } catch {
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else {
                return false
            }
            _ = terminateConnectionIfCredentialsInvalid(error)
            // 短暂读取失败不清空上次活动态，否则列表会在“进行中/历史”之间来回抖动。
            return false
        }
    }

    func applyExternalActivitySnapshot(
        _ activities: [ExternalSessionActivity],
        client: any SessionStoreAPIClient,
        hostScope: HostScope,
        deferWhileTimelineScrolling: Bool = false
    ) async {
        var nextByID: [SessionID: ExternalSessionActivity] = [:]
        for activity in activities where activity.state.lowercased() == "running" {
            guard workspacesByID[activity.projectID] != nil || projectsByID[activity.projectID] != nil else {
                continue
            }
            // Desktop 创建的历史 thread 会永久保留 originator。若当前 rollout turn 与
            // iPad 的 turn/start ACK 精确一致，它只是本轮的磁盘镜像，不是 Mac 接管。
            guard !isLocallyStartedExternalActivity(activity) else {
                continue
            }
            nextByID[activity.threadID] = activity
        }

        let previousByID = externalActivityBySessionID
        let activeIDs = Set(nextByID.keys)
        // 上一次 terminal 最终刷新若因退后台被取消，externalActivityBySessionID 已经清空，
        // 但只读 tombstone 会保留。把它重新纳入 removedIDs，下一次前台轮询即可续跑并清理。
        let removedIDs = Set(previousByID.keys)
            .union(externalReadOnlySessionIDs)
            .subtracting(activeIDs)
        externalReadOnlySessionIDs.formUnion(activeIDs)
        externalReadOnlySessionIDs.formUnion(removedIDs)
        if externalActivityBySessionID != nextByID {
            externalActivityBySessionID = nextByID
        }

        // 控制权边界不能为了帧率延迟：一旦看到 Mac writer，立刻停止队列并退役前台 socket。
        // 只有会触发全量索引/SwiftUI 投影的 sessions 展示更新延后到滚动结束。
        for sessionID in activeIDs {
            stopQueuedSessionMonitoring(sessionID: sessionID)
        }
        if let selectedSessionID,
           activeIDs.contains(selectedSessionID),
           connectedSessionID == selectedSessionID {
            disconnectWebSocket()
        }
        if deferWhileTimelineScrolling, isConversationTimelineInteractionActive {
            deferredExternalActivityVisiblePoll = true
            return
        }
        if deferWhileTimelineScrolling {
            deferredExternalActivityVisiblePoll = false
        }

        let selectedActivityNeedsHistoryRefresh: Bool
        if let selectedSessionID,
           let activity = nextByID[selectedSessionID] {
            let selectedSession = sessionsByID[selectedSessionID]
            selectedActivityNeedsHistoryRefresh = previousByID[selectedSessionID]?.revision != activity.revision
                || selectedSession?.activeTurnID != activity.turnID
                || selectedSession?.status != SessionStatus.running.rawValue
        } else {
            selectedActivityNeedsHistoryRefresh = false
        }

        var nextSessions = sessions
        func updateBatchedSession(
            _ sessionID: SessionID,
            mutate: (inout AgentSession) -> Void
        ) {
            guard let index = sessionIndexByID[sessionID], nextSessions.indices.contains(index) else {
                return
            }
            let previous = nextSessions[index]
            var updated = previous
            mutate(&updated)
            guard updated != previous else {
                return
            }
            nextSessions[index] = updated
        }

        for (sessionID, activity) in nextByID {
            updateBatchedSession(sessionID) { session in
                session.status = SessionStatus.running.rawValue
                session.activeTurnID = activity.turnID
                session.pendingApproval = nil
                session.pendingUserInput = nil
                session.updatedAt = max(session.updatedAt ?? .distantPast, activity.lastActivityAt)
                session.recencyAt = max(session.recencyAt ?? .distantPast, activity.lastActivityAt)
            }
        }
        // 先本地降级，确保 terminal/过期快照一到就从“进行中”移回“历史”；
        // 随后的权威列表与最终历史读取负责补齐标题、消息和最新时间。
        for sessionID in removedIDs {
            updateBatchedSession(sessionID) { session in
                session.status = SessionStatus.history.rawValue
                session.activeTurnID = nil
                session.pendingApproval = nil
                session.pendingUserInput = nil
            }
            clearForegroundActivity(sessionID: sessionID)
            clearRuntimeActivity(sessionID: sessionID)
        }

        // 一个 snapshot 可能同时更新多条会话；先在本地数组合并，最后只发布一次，避免
        // SwiftUI 长列表随每条活动反复重算并造成主线程停顿。相同结果则完全不发布。
        if nextSessions != sessions {
            sessions = nextSessions
        }

        let newOrMissingProjectIDs = Set(nextByID.values.compactMap { activity in
            if previousByID[activity.threadID] == nil || sessionsByID[activity.threadID] == nil {
                return activity.projectID
            }
            return nil
        })
        for projectID in newOrMissingProjectIDs {
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return }
            await refreshExternalActivityProject(
                projectID: projectID,
                client: client,
                hostScope: hostScope,
                deferWhileTimelineScrolling: deferWhileTimelineScrolling
            )
            if deferWhileTimelineScrolling, isConversationTimelineInteractionActive {
                deferredExternalActivityVisiblePoll = true
                return
            }
        }

        if let selectedSessionID,
           nextByID[selectedSessionID] != nil,
           selectedActivityNeedsHistoryRefresh,
           let session = sessionsByID[selectedSessionID] {
            _ = await loadHistory(
                for: session,
                quiet: true,
                loadMode: .full,
                force: true
            )
            if deferWhileTimelineScrolling, isConversationTimelineInteractionActive {
                deferredExternalActivityVisiblePoll = true
                return
            }
        }

        // terminal/过期必须做最后一次强制历史补拉。只读集合在所有 await 完成前保留，
        // 即使磁盘里遗留 `.takenOver`，这段时间也不能触发 resume 或发送。
        for sessionID in removedIDs {
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return }
            if deferWhileTimelineScrolling, isConversationTimelineInteractionActive {
                deferredExternalActivityVisiblePoll = true
                return
            }
            if selectedSessionID == sessionID, let session = sessionsByID[sessionID] {
                _ = await loadHistory(
                    for: session,
                    quiet: true,
                    loadMode: .full,
                    force: true
                )
                if deferWhileTimelineScrolling, isConversationTimelineInteractionActive {
                    deferredExternalActivityVisiblePoll = true
                    return
                }
            }
            let projectID = previousByID[sessionID]?.projectID ?? sessionsByID[sessionID]?.projectID
            if let projectID {
                await refreshExternalActivityProject(
                    projectID: projectID,
                    client: client,
                    hostScope: hostScope,
                    deferWhileTimelineScrolling: deferWhileTimelineScrolling
                )
                if deferWhileTimelineScrolling, isConversationTimelineInteractionActive {
                    deferredExternalActivityVisiblePoll = true
                    return
                }
            }
        }
        guard appStore.activeHostScope == hostScope else { return }
        externalReadOnlySessionIDs.subtract(removedIDs)
        if deferWhileTimelineScrolling {
            deferredExternalActivityVisiblePoll = false
        }
    }

    func refreshExternalActivityProject(
        projectID: String,
        client: any SessionStoreAPIClient,
        hostScope: HostScope,
        deferWhileTimelineScrolling: Bool = false
    ) async {
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            return
        }
        do {
            // 外部活动补拉也必须加入首屏 single-flight；否则它与工作区前台刷新重叠时，
            // 会并发启动两条 cursor 链并触发 gateway 的并发保护。
            let result = try await sessionListFirstPage(
                workspace: workspace,
                limit: Self.initialSessionPageLimit,
                reuseRecent: false,
                consistency: .authoritative,
                source: .externalActivity,
                client: client,
                hostScope: hostScope
            )
            let page = result.page
            guard appStore.activeHostScope == hostScope,
                  !Task.isCancelled,
                  isCurrentWorkspaceIdentity(workspace, hostScope: hostScope),
                  authoritativeWorkspaceSessionFirstPageContinuationCursor(
                    workspace: workspace,
                    hostScope: hostScope
                  ) == result.requestedCursor else {
                return
            }
            if deferWhileTimelineScrolling, isConversationTimelineInteractionActive {
                // 外层 snapshot 可能在 idle 开始，嵌套 thread/list 返回时已经进入滚动。
                deferredExternalActivityVisiblePoll = true
                return
            }
            mergeSessionPage(sessions(page.sessions, in: workspace))
            updateWorkspaceSessionFirstPageState(
                workspace: workspace,
                page: page,
                consistency: .authoritative,
                requestedCursor: result.requestedCursor
            )
            recordWorkspaceSessionFirstPageCompletion(
                workspace: workspace,
                page: page,
                consistency: .authoritative
            )
            clearWorkspaceUnavailable(projectID)
        } catch {
            // 活动 API 已给出可靠运行态；列表补拉失败时保留已有行，下一次轮询继续重试未知线程。
        }
    }

    func handleTurnSendOutcome(
        clientMessageID: ClientMessageID?,
        sessionID: SessionID,
        outcome: TurnSendOutcome
    ) {
        let recoveredExternalMisclassification: Bool
        if let turnID = acceptedTurnID(from: outcome) {
            // terminal / superseded 也可能在 ACK 回到 MainActor 前被外部活动轮询误判。
            // 所有带精确 turnID 的 accepted outcome 都必须先撤销只读 tombstone。
            let shouldRestoreSelectedConnection: Bool
            switch outcome {
            case .accepted, .acceptedSuperseded:
                shouldRestoreSelectedConnection = true
            case .guidanceAccepted,
                 .acceptedTerminal, .acceptedThreadClosed,
                 .activeTurnConflict, .rejected, .uncertain:
                // 已终态或已关闭时不先复活旧连接；若仍有队列，finishAccepted 会按需建链。
                shouldRestoreSelectedConnection = false
            }
            recoveredExternalMisclassification = recordLocallyStartedTurn(
                sessionID: sessionID,
                turnID: turnID,
                restoreSelectedConnection: shouldRestoreSelectedConnection
            )
        } else {
            recoveredExternalMisclassification = false
        }
        if let clientMessageID,
           let turnID = acceptedTurnID(from: outcome) {
            conversationStore.bindTurnID(
                turnID,
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
            // 非队列消息同样需要 compare-and-apply，防止 outcome 排队到 MainActor
            // 期间覆盖已经到达的更新 turn。
            switch disposition {
            case .terminal(let turnID):
                let terminalStatus = turnID.flatMap {
                    conversationStore.turnLifecycle(sessionID: sessionID, turnID: $0)
                } == .failed ? SessionStatus.failed : .completed
                updateSession(sessionID) { session in
                    guard session.activeTurnID == nil
                            || session.activeTurnID == turnID else {
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
                    guard session.activeTurnID == nil
                            || session.activeTurnID == turnID else {
                        return
                    }
                    session.status = "closed"
                    session.activeTurnID = nil
                }
            case .awaitingStart, .guidance:
                break
            }
        }

        switch outcome {
        case .accepted(let turnID):
            finishAccepted(.awaitingStart(turnID: turnID))
            if recoveredExternalMisclassification,
               selectedSessionID != sessionID,
               queuedRunningTurnsBySessionID[sessionID]?.isEmpty == false {
                // external snapshot 会停止后台队列 socket。ACK 对账成功且仍有后续项时，
                // 重新建立监听，让 FIFO 能在当前 turn 完成后继续派发。
                ensureQueuedSessionMonitoring(sessionID: sessionID)
            }
        case .acceptedTerminal(let turnID):
            finishAccepted(.terminal(turnID: turnID))
        case .acceptedSuperseded(let turnID, let activeTurnID):
            finishAccepted(.superseded(
                turnID: turnID,
                activeTurnID: activeTurnID
            ))
            if recoveredExternalMisclassification,
               selectedSessionID != sessionID,
               queuedRunningTurnsBySessionID[sessionID]?.isEmpty == false {
                // external snapshot 已停止后台队列 socket；当前权威 turn 完成前必须恢复监听。
                ensureQueuedSessionMonitoring(sessionID: sessionID)
            }
        case .acceptedThreadClosed(let turnID):
            finishAccepted(.threadClosed(turnID: turnID))
        case .guidanceAccepted:
            finishAccepted(.guidance)
        case .activeTurnConflict(let activeTurnID, let message):
            // 这是“新消息未被接受”，不是原会话失败。恢复权威 active turn，
            // 并保留已有审批/补充问题；排队项回到等待态，待原 turn 完成后再发。
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
