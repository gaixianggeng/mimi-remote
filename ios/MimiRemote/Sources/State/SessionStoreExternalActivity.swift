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
        externalActivityHistoryRevisionBySessionID.removeValue(forKey: sessionID)
        externalActivityHistoryAttemptBySessionID.removeValue(forKey: sessionID)
        externalActivityHistoryFallbackBySessionID.removeValue(forKey: sessionID)
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

    func canReconcileTurnOutcomeFromRetiredSocket(
        sessionID: SessionID,
        outcome: TurnSendOutcome,
        hostScope: HostScope
    ) -> Bool {
        guard appStore.activeHostScope == hostScope,
              sessionsByID[sessionID] != nil else {
            return false
        }
        if case .retryableExternalThreadActive = outcome {
            let hasDispatchingQueueItem = queuedRunningTurnsBySessionID[sessionID]?.contains(where: {
                $0.dispatchState == .dispatching
            }) == true
            let hasPendingLocalMessage = conversationStore.messages(for: sessionID).contains(where: {
                $0.role == .user && $0.sendStatus == .sending && $0.clientMessageID != nil
            })
            return hasDispatchingQueueItem || hasPendingLocalMessage
        }
        guard let acceptedTurnID = acceptedTurnID(from: outcome) else {
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
             .retryableExternalThreadActive,
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
                _ = await refreshExternalActivities()
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
        client fixedClient: (any SessionStoreAPIClient)? = nil
    ) async -> Bool {
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
                    hostScope: hostScope
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
                hostScope: hostScope
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

    func scheduleExternalActivityRetryRefresh(
        sessionID: SessionID,
        retryAfterMilliseconds: Int
    ) {
        let hostScope = appStore.activeHostScope
        let boundedMilliseconds = min(max(retryAfterMilliseconds, 0), 60_000)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if boundedMilliseconds > 0 {
                await self.externalActivitySleep(UInt64(boundedMilliseconds) * 1_000_000)
            }
            guard self.appStore.activeHostScope == hostScope,
                  self.queuedRunningTurnsBySessionID[sessionID]?.isEmpty == false else {
                return
            }
            let refreshed = await self.refreshExternalActivities()
            guard refreshed,
                  self.externalActivityBySessionID[sessionID] == nil,
                  !self.externalReadOnlySessionIDs.contains(sessionID) else {
                return
            }
            self.ensureQueuedSessionMonitoring(sessionID: sessionID)
            self.dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID)
        }
    }

    /// Desktop turn 在 iOS 下一次活动轮询前启动时，gateway 会明确返回
    /// accepted=false/retryable=true。请求尚未进入上游，因此可以把原 payload 原样
    /// 放回持久队列；不能按普通 rejected 删除，否则 Desktop 完成后只能让用户手工重发。
    @discardableResult
    func preserveTurnBlockedByExternalActivity(
        clientMessageID: ClientMessageID,
        sessionID: SessionID,
        message: String
    ) -> Bool {
        queuedGuidanceDispatchClientMessageIDs.remove(clientMessageID)
        queuedTurnAwaitingStartSessionIDs.remove(sessionID)
        queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)

        if let location = queuedTurnLocation(clientMessageID: clientMessageID),
           location.sessionID == sessionID,
           let item = queuedRunningTurnsBySessionID[sessionID]?[location.index] {
            guard mutateAndPersistQueuedTurns({
                guard var queue = queuedRunningTurnsBySessionID[sessionID],
                      queue.indices.contains(location.index) else { return }
                queue[location.index].dispatchState = .waiting
                queue[location.index].expectedTurnID = nil
                queue[location.index].lastError = message
                queuedRunningTurnsBySessionID[sessionID] = queue
            }) else {
                return false
            }
            conversationStore.appendLocalUser(
                item.previewText,
                sessionID: sessionID,
                clientMessageID: clientMessageID,
                sendStatus: .local,
                turnPayload: item.payload,
                userDelivery: .queued
            )
        } else {
            guard let session = sessionsByID[sessionID],
                  let localMessage = conversationStore.messages(for: sessionID).first(where: {
                      $0.role == .user && $0.clientMessageID == clientMessageID
                  }),
                  let payload = localMessage.turnPayload,
                  (queuedRunningTurnsBySessionID[sessionID]?.count ?? 0) < Self.queuedTurnLimitPerSession else {
                return false
            }
            let intent: QueuedTurnIntent = payload.options.collaborationMode == .plan ? .plan : .standard
            let item = QueuedTurnEntry(
                sessionID: sessionID,
                projectID: session.projectID,
                payload: payload,
                clientMessageID: clientMessageID,
                intent: intent,
                lastError: message
            )
            guard mutateAndPersistQueuedTurns({
                queuedRunningTurnsBySessionID[sessionID, default: []].append(item)
            }) else {
                return false
            }
            conversationStore.appendLocalUser(
                item.previewText,
                sessionID: sessionID,
                clientMessageID: clientMessageID,
                sendStatus: .local,
                turnPayload: item.payload,
                userDelivery: .queued
            )
        }

        clearForegroundActivity(sessionID: sessionID)
        setStatusMessage(L10n.text("ui.saved_to_this_machine_and_will_be_sent"))
        return true
    }

    func applyExternalActivitySnapshot(
        _ activities: [ExternalSessionActivity],
        client: any SessionStoreAPIClient,
        hostScope: HostScope
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
        for sessionID in removedIDs {
            externalActivityHistoryRevisionBySessionID.removeValue(forKey: sessionID)
            externalActivityHistoryAttemptBySessionID.removeValue(forKey: sessionID)
            externalActivityHistoryFallbackBySessionID.removeValue(forKey: sessionID)
        }
        for (sessionID, activity) in nextByID {
            guard let previousActivity = previousByID[sessionID],
                  normalizedExternalActivityTurnID(previousActivity.turnID)
                    != normalizedExternalActivityTurnID(activity.turnID) else {
                continue
            }
            // fallback 只对当前 turn 有效。新 turn 必须恢复 full，并重新建立覆盖水位。
            externalActivityHistoryRevisionBySessionID.removeValue(forKey: sessionID)
            externalActivityHistoryAttemptBySessionID.removeValue(forKey: sessionID)
            externalActivityHistoryFallbackBySessionID.removeValue(forKey: sessionID)
        }
        externalReadOnlySessionIDs.formUnion(activeIDs)
        externalReadOnlySessionIDs.formUnion(removedIDs)
        externalActivityBySessionID = nextByID

        for (sessionID, activity) in nextByID {
            stopQueuedSessionMonitoring(sessionID: sessionID)
            updateSession(sessionID) { session in
                session.status = SessionStatus.running.rawValue
                session.activeTurnID = activity.turnID
                session.pendingApproval = nil
                session.pendingUserInput = nil
                session.updatedAt = max(session.updatedAt ?? .distantPast, activity.lastActivityAt)
                session.recencyAt = max(session.recencyAt ?? .distantPast, activity.lastActivityAt)
            }
        }
        if let selectedSessionID, activeIDs.contains(selectedSessionID) {
            disconnectWebSocket()
        }

        // 先本地降级，确保 terminal 快照一到就从“进行中”移回“历史”；
        // 随后的权威列表与最终历史读取负责补齐标题、消息和最新时间。
        for sessionID in removedIDs {
            updateSession(sessionID) { session in
                session.status = SessionStatus.history.rawValue
                session.activeTurnID = nil
                session.pendingApproval = nil
                session.pendingUserInput = nil
            }
            clearForegroundActivity(sessionID: sessionID)
            clearRuntimeActivity(sessionID: sessionID)
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
                hostScope: hostScope
            )
        }

        if let selectedSessionID,
           let activity = nextByID[selectedSessionID] {
            let attempt = externalActivityHistoryAttempt(activity)
            let fallback = externalActivityHistoryFallbackBySessionID[selectedSessionID]
            let skipsCurrentTurn = fallback?.turnID == attempt.turnID && fallback?.mode == .skip
            if externalActivityHistoryRevisionBySessionID[selectedSessionID] != activity.revision,
               !skipsCurrentTurn,
               externalActivityHistoryAttemptBySessionID[selectedSessionID] != attempt {
                _ = await refreshSelectedExternalActivityHistory(
                    sessionID: selectedSessionID,
                    revision: activity.revision,
                    client: client,
                    hostScope: hostScope
                )
            }
        }

        // terminal 必须做最后一次强制历史补拉。只读集合在所有 await 完成前保留，
        // 即使磁盘里遗留 `.takenOver`，这段时间也不能触发 resume 或发送。
        for sessionID in removedIDs {
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return }
            if selectedSessionID == sessionID, let session = sessionsByID[sessionID] {
                _ = await loadHistory(
                    for: session,
                    quiet: true,
                    loadMode: .full,
                    force: true
                )
            }
            let projectID = previousByID[sessionID]?.projectID ?? sessionsByID[sessionID]?.projectID
            if let projectID {
                await refreshExternalActivityProject(
                    projectID: projectID,
                    client: client,
                    hostScope: hostScope
                )
            }
        }
        guard appStore.activeHostScope == hostScope else { return }
        externalReadOnlySessionIDs.subtract(removedIDs)
        for sessionID in removedIDs where queuedRunningTurnsBySessionID[sessionID]?.isEmpty == false {
            // 外部 turn 已明确结束后恢复持久队列；连接建立回调会在 socket ready 时
            // 再调用 dispatch，因此这里不会因尚未连上而丢失派发机会。
            ensureQueuedSessionMonitoring(sessionID: sessionID)
            dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID)
        }
    }

    /// 外部运行中的 turn 会让 rollout revision 高频变化。已加载完整首屏后只补最新一个 turn，
    /// 再增量合并到现有时间线；否则 5 秒轮询会反复下载同一份 10-turn 大页。
    /// 首次加载和 terminal 最终对账仍走完整历史，分页边界与结束态语义保持不变。
    func refreshSelectedExternalActivityHistory(
        sessionID: SessionID,
        revision: String,
        client: any SessionStoreAPIClient,
        hostScope: HostScope
    ) async -> Bool {
        guard appStore.activeHostScope == hostScope,
              selectedSessionID == sessionID,
              externalActivityBySessionID[sessionID]?.revision == revision,
              let initialSession = sessionsByID[sessionID] else {
            return false
        }

        // 首屏任务与轮询撞在一起时先加入已有 single-flight。请求开始时记录的 activity
        // revision 会在成功落盘后推进覆盖水位；若它更旧，再继续做一次轻量 latest-turn 对账。
        if let existingHistoryJob = historyLoadJobsBySessionID[sessionID] {
            _ = await awaitHistoryLoadJob(
                existingHistoryJob,
                session: initialSession,
                quiet: true,
                successStatusMessage: nil
            )
            guard appStore.activeHostScope == hostScope,
                  selectedSessionID == sessionID,
                  externalActivityBySessionID[sessionID]?.revision == revision else {
                return false
            }
            if externalActivityHistoryRevisionBySessionID[sessionID] == revision {
                return true
            }
        }

        if let fallback = matchingExternalActivityHistoryFallback(sessionID: sessionID) {
            return await refreshExternalActivityFallbackHistory(
                sessionID: sessionID,
                revision: revision,
                fallback: fallback,
                hostScope: hostScope
            )
        }

        guard hasLoadedFullHistorySnapshot(sessionID: sessionID) else {
            guard let session = sessionsByID[sessionID] else { return false }
            let didLoad = await loadHistory(
                for: session,
                quiet: true,
                loadMode: .full,
                force: true
            )
            if didLoad, let activity = externalActivityBySessionID[sessionID] {
                let attempt = externalActivityHistoryAttempt(activity)
                if attempt.turnID == nil {
                    // 缺少 turnID 时只能按 revision 去重，不能写成 turn 级 `.skip`；
                    // 否则后续 revision 变化也会被永久挡住，运行中的新输出将停止更新。
                    recordExternalActivityHistoryAttempt(
                        sessionID: sessionID,
                        attempt: attempt,
                        hostScope: hostScope
                    )
                } else if historyLoadedQualityBySessionID[sessionID] != .full {
                    recordExternalActivityHistoryFallback(
                        sessionID: sessionID,
                        attempt: attempt,
                        mode: .economy,
                        hostScope: hostScope
                    )
                    recordExternalActivityHistoryAttempt(
                        sessionID: sessionID,
                        attempt: attempt,
                        hostScope: hostScope
                    )
                }
            }
            return externalActivityHistoryRevisionBySessionID[sessionID] == revision
        }

        guard let expectedTurnID = externalActivityBySessionID[sessionID]?.turnID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !expectedTurnID.isEmpty else {
            // 缺少 turn 身份时不能安全增量合并。完整刷新成功后只抑制同一 revision；
            // 新 revision 仍需重新对账，避免把整个未知 turn 永久冻结。
            guard let session = sessionsByID[sessionID] else { return false }
            let didLoad = await loadHistory(
                for: session,
                quiet: true,
                loadMode: .full,
                force: true
            )
            if didLoad {
                recordExternalActivityHistoryAttempt(
                    sessionID: sessionID,
                    attempt: ExternalActivityHistoryAttempt(revision: revision, turnID: nil),
                    hostScope: hostScope
                )
            }
            return externalActivityHistoryRevisionBySessionID[sessionID] == revision
        }

        do {
            let historyLoadToken = historyLoadJobTokenBySessionID[sessionID]
            let historyPageToken = historyPageRequestTokenBySessionID[sessionID]
            let page = try await client.latestTurnHistoryPage(sessionID: sessionID)
            guard appStore.activeHostScope == hostScope,
                  selectedSessionID == sessionID,
                  let currentActivity = externalActivityBySessionID[sessionID],
                  currentActivity.revision == revision,
                  currentActivity.turnID?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedTurnID,
                  historyLoadJobTokenBySessionID[sessionID] == historyLoadToken,
                  historyPageRequestTokenBySessionID[sessionID] == historyPageToken,
                  historyLoadJobsBySessionID[sessionID] == nil else {
                return false
            }
            guard let page else {
                // 旧 app-server 的 thread/read 不支持“一个完整 turn”的边界，沿用原有完整刷新。
                guard let session = sessionsByID[sessionID] else { return false }
                let didLoad = await loadHistory(
                    for: session,
                    quiet: true,
                    loadMode: .full,
                    force: true
                )
                let attempt = ExternalActivityHistoryAttempt(revision: revision, turnID: expectedTurnID)
                let existingFallback = matchingExternalActivityHistoryFallback(sessionID: sessionID)
                if didLoad || existingFallback?.mode == .skip {
                    // 旧协议的 limit=1 只是“一条 message”，不能继续按 revision 反复整页读取。
                    // 同一 turn 后续写入跳过；但 full 超限后 economy 只是瞬时失败时，
                    // 必须保留 .economy，让下一轮只重试缩略页，不能误升级为永久跳过。
                    recordExternalActivityHistoryFallback(
                        sessionID: sessionID,
                        attempt: attempt,
                        mode: .skip,
                        hostScope: hostScope
                    )
                }
                return externalActivityHistoryRevisionBySessionID[sessionID] == revision
            }
            guard !page.messages.isEmpty,
                  page.messages.contains(where: { $0.turnID == expectedTurnID }) else {
                // rollout revision 可能先于 turns/list 可见；不推进水位，下次轮询继续对账。
                return false
            }
            ingestHistoryContext(page.context, fallbackSessionID: sessionID)
            conversationStore.setHistory(
                page.messages,
                sessionID: sessionID,
                authoritativeCompletedTurnItems: page.authoritativeCompletedTurnItems
            )
            // latest-turn 补丁不能覆盖完整首屏保存的 older cursor，否则“加载更早”会从
            // 最新一条重新翻页。snapshot seq 仍需推进，供后续事件回放去重。
            recordHistorySnapshotSeq(page.snapshotSeq, sessionID: sessionID)
            if let currentSession = sessionsByID[sessionID] {
                historyLoadedSignatureBySessionID[sessionID] = HistoryLoadSignature(session: currentSession)
            }
            historyLoadedQualityBySessionID[sessionID] = .full
            freshEmptyHistorySignatureBySessionID.removeValue(forKey: sessionID)
            externalActivityHistoryRevisionBySessionID[sessionID] = revision
            return true
        } catch {
            _ = terminateConnectionIfCredentialsInvalid(error)
            if historyPolicyFailure(from: error)?.reason == "history_response_too_large" {
                // 单个最新 turn 已确定超过 gateway cap。同一 turn 后续 revision 改走 economy，
                // economy 瞬时失败也只重试 economy；新 turn 才恢复 full。
                let attempt = ExternalActivityHistoryAttempt(revision: revision, turnID: expectedTurnID)
                recordExternalActivityHistoryFallback(
                    sessionID: sessionID,
                    attempt: attempt,
                    mode: .economy,
                    hostScope: hostScope
                )
                if let fallback = matchingExternalActivityHistoryFallback(sessionID: sessionID) {
                    return await refreshExternalActivityFallbackHistory(
                        sessionID: sessionID,
                        revision: revision,
                        fallback: fallback,
                        hostScope: hostScope
                    )
                }
            }
            // 普通超时、空页和错 turn 不记录 attempt，同 revision 会在下次轮询重试。
            return false
        }
    }

    func normalizedExternalActivityTurnID(_ turnID: TurnID?) -> TurnID? {
        guard let value = turnID?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    func externalActivityHistoryAttempt(_ activity: ExternalSessionActivity) -> ExternalActivityHistoryAttempt {
        ExternalActivityHistoryAttempt(
            revision: activity.revision,
            turnID: normalizedExternalActivityTurnID(activity.turnID)
        )
    }

    func matchingExternalActivityHistoryFallback(sessionID: SessionID) -> ExternalActivityHistoryFallback? {
        guard let activity = externalActivityBySessionID[sessionID],
              let fallback = externalActivityHistoryFallbackBySessionID[sessionID],
              fallback.turnID == normalizedExternalActivityTurnID(activity.turnID) else {
            return nil
        }
        return fallback
    }

    func recordExternalActivityHistoryAttempt(
        sessionID: SessionID,
        attempt: ExternalActivityHistoryAttempt,
        hostScope: HostScope
    ) {
        guard appStore.activeHostScope == hostScope,
              selectedSessionID == sessionID,
              let activity = externalActivityBySessionID[sessionID],
              externalActivityHistoryAttempt(activity) == attempt else {
            return
        }
        externalActivityHistoryAttemptBySessionID[sessionID] = attempt
    }

    func recordExternalActivityHistoryFallback(
        sessionID: SessionID,
        attempt: ExternalActivityHistoryAttempt,
        mode: ExternalActivityHistoryFallbackMode,
        hostScope: HostScope? = nil
    ) {
        guard hostScope.map({ appStore.activeHostScope == $0 }) ?? true,
              selectedSessionID == sessionID,
              let activity = externalActivityBySessionID[sessionID],
              externalActivityHistoryAttempt(activity) == attempt else {
            return
        }
        externalActivityHistoryFallbackBySessionID[sessionID] = ExternalActivityHistoryFallback(
            turnID: attempt.turnID,
            mode: mode
        )
        if mode == .skip {
            externalActivityHistoryAttemptBySessionID.removeValue(forKey: sessionID)
        }
    }

    func refreshExternalActivityFallbackHistory(
        sessionID: SessionID,
        revision: String,
        fallback: ExternalActivityHistoryFallback,
        hostScope: HostScope
    ) async -> Bool {
        guard appStore.activeHostScope == hostScope,
              selectedSessionID == sessionID,
              let activity = externalActivityBySessionID[sessionID],
              activity.revision == revision,
              fallback.turnID == normalizedExternalActivityTurnID(activity.turnID),
              externalActivityHistoryFallbackBySessionID[sessionID] == fallback else {
            return false
        }
        guard fallback.mode == .economy, let session = sessionsByID[sessionID] else {
            return false
        }
        let didLoad = await loadHistory(
            for: session,
            quiet: true,
            loadMode: .economy,
            force: true
        )
        if didLoad {
            let attempt = externalActivityHistoryAttempt(activity)
            // economy fallback 可跨 revision 复用，但成功结果只覆盖当前 revision。
            // 对 nil turn 写 `.skip` 会把后续所有 revision 永久冻结。
            recordExternalActivityHistoryAttempt(
                sessionID: sessionID,
                attempt: attempt,
                hostScope: hostScope
            )
        }
        return didLoad
    }

    func refreshExternalActivityProject(
        projectID: String,
        client: any SessionStoreAPIClient,
        hostScope: HostScope
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
                 .activeTurnConflict, .retryableExternalThreadActive,
                 .rejected, .uncertain:
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
        case .retryableExternalThreadActive(let message, let retryAfterMilliseconds):
            guard preserveTurnBlockedByExternalActivity(
                clientMessageID: clientMessageID,
                sessionID: sessionID,
                message: message
            ) else {
                conversationStore.updateSendStatus(
                    clientMessageID: clientMessageID,
                    sessionID: sessionID,
                    status: .failed
                )
                clearForegroundActivity(sessionID: sessionID)
                setErrorMessage(L10n.format("ui.sending_failed_value", message))
                return
            }
            scheduleExternalActivityRetryRefresh(
                sessionID: sessionID,
                retryAfterMilliseconds: retryAfterMilliseconds
            )
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
