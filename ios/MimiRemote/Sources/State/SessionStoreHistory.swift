import Foundation

// 会话创建、历史预算、分页投影与搜索索引集中管理，保留原有缓存和限流语义。
extension SessionStore {
    @discardableResult
    func createSession(
        projectID: String,
        prompt: String,
        resume: AgentSession?,
        clientMessageID: ClientMessageID? = nil,
        runtimeProvider: String? = nil
    ) async -> Bool {
        var payload = CodexAppServerTurnPayload(prompt: prompt)
        if let runtimeProvider, !runtimeProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload.options.runtimeProvider = runtimeProvider
        }
        return await createSession(projectID: projectID, payload: payload, resume: resume, clientMessageID: clientMessageID)
    }

    @discardableResult
    func createSession(
        projectID: String,
        payload: CodexAppServerTurnPayload,
        resume: AgentSession?,
        clientMessageID: ClientMessageID? = nil,
        permissionSelection: ComposerPermissionSelectionSnapshot? = nil,
        initialGoalObjective: String? = nil,
        replacingLocalDraft localDraft: AgentSession? = nil,
        ifCurrent expectedSelectionLease: SessionSelectionLease? = nil
    ) async -> Bool {
        let createIntent = expectedSelectionLease ?? reserveSelectionIntent()
        // 空会话只执行 thread/start，没有 turn/start；提前拉 model/list 既不会影响线程创建，
        // 还会在远程链路上平白增加一次串行往返。只有真正要发送首轮输入时才解析模型。
        let payload = payload.isEmpty ? payload : await payloadResolvingRequiredModel(payload)
        if !payload.isEmpty, let notice = selectedQuotaNotice, notice.blocksSending {
            if isSelectionLeaseCurrent(createIntent) {
                setErrorMessage(notice.message)
            }
            return false
        }
        var projectID = projectID
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            if isSelectionLeaseCurrent(createIntent) {
                setErrorMessage(L10n.text("ui.the_workspace_has_expired_please_reopen_it"))
            }
            return false
        }
        projectID = workspace.id
        if resume == nil, payload.isEmpty {
            return createLocalDraftSession(
                projectID: projectID,
                runtimeProvider: payload.options.runtimeProvider,
                ifCurrent: createIntent
            )
        }
        let requestedLocalDraft = localDraft
        let localDraft = requestedLocalDraft.flatMap { draft -> AgentSession? in
            guard draft.isLocalDraft,
                  draft.projectID == projectID,
                  isSelectionLeaseCurrent(createIntent),
                  sessionsByID[draft.id]?.isLocalDraft == true else {
                return nil
            }
            return draft
        }
        if requestedLocalDraft != nil, localDraft == nil {
            return false
        }
        isLoading = true
        defer { isLoading = false }
        let prompt = payload.previewText
        let optimisticSessionID = localDraft?.id ?? optimisticSessionID(
            projectID: projectID,
            resume: resume,
            clientMessageID: clientMessageID,
            prompt: prompt
        )
        var registeredPermissionBoundaryClientMessageID: ClientMessageID?
        if permissionSelection?.requiresNewTurn == true,
           let permissionSelection,
           let clientMessageID,
           let optimisticSessionID {
            guard mutateAndPersistQueuedTurns({
                pendingPermissionTurnBoundariesBySessionID[optimisticSessionID, default: []].append(
                    PendingPermissionTurnBoundary(
                        sessionID: optimisticSessionID,
                        clientMessageID: clientMessageID,
                        permissionSelection: permissionSelection
                    )
                )
            }) else {
                return false
            }
            registeredPermissionBoundaryClientMessageID = clientMessageID
        }
        defer {
            if let registeredPermissionBoundaryClientMessageID {
                _ = mutateAndPersistQueuedTurns {
                    guard let location = pendingPermissionTurnBoundaryLocation(
                        clientMessageID: registeredPermissionBoundaryClientMessageID
                    ) else {
                        return
                    }
                    _ = removePendingPermissionTurnBoundary(
                        sessionID: location.sessionID,
                        clientMessageID: registeredPermissionBoundaryClientMessageID
                    )
                }
            }
        }
        var optimisticSelectionLease: SessionSelectionLease?
        if let optimisticSessionID {
            // 本地草稿或带首轮输入的新会话先发布运行态占位；服务端确认后再用
            // client_message_id 合并本地气泡并迁移到真实 session_id。
            if resume == nil {
                upsert(makeOptimisticSession(
                    id: optimisticSessionID,
                    projectID: projectID,
                    prompt: prompt,
                    runtimeProvider: payload.options.runtimeProvider
                ))
            }
            optimisticSelectionLease = commitSelection(
                projectID: projectID,
                sessionID: optimisticSessionID,
                reason: .userOpen,
                ifCurrent: createIntent
            )
            insertExpandedProjectID(projectID)
            if let clientMessageID {
                conversationStore.appendLocalUser(prompt, sessionID: optimisticSessionID, clientMessageID: clientMessageID, sendStatus: .sending, turnPayload: payload)
                setSessionListProjection(sessionID: optimisticSessionID, preview: prompt, source: .localUser, clientMessageID: clientMessageID)
                setForegroundActivity(.waitingForAssistant, sessionID: optimisticSessionID)
            } else if resume == nil {
                // 新建空会话同样属于用户最近操作；没有消息投影时单独建立排序保护。
                setSessionRecentActivityProjection(sessionID: optimisticSessionID, clientMessageID: nil)
            }
        }

        do {
            let client = try clientFactory()
            let response = try await client.createSession(CreateSessionRequest(
                projectID: projectID,
                projectPath: workspace.path,
                projectName: workspace.name,
                rootProjectID: workspace.rootProjectID,
                prompt: prompt,
                input: payload.input,
                turnOptions: payload.options,
                initialGoalObjective: initialGoalObjective,
                resumeID: resume?.resumeID ?? "",
                clientMessageID: clientMessageID
            ))
            let responseSession = self.session(response.session, in: workspace)
            let queuesInitialInput = response.requiresQueuedInitialInput == true
            if let clientMessageID {
                migratePendingPermissionTurnBoundary(
                    clientMessageID: clientMessageID,
                    to: responseSession.id
                )
            }

            if let optimisticSessionID,
               optimisticSessionID != responseSession.id {
                // 新建会话会从 local:<project>:<client_message_id> 切换到后端 session_id，
                // 这里迁移前台活动和本地气泡，保持列表/对话 store 解耦。
                if let clientMessageID {
                    conversationStore.moveLocalEcho(clientMessageID: clientMessageID, from: optimisticSessionID, to: responseSession.id)
                    moveSessionListProjection(from: optimisticSessionID, to: responseSession.id, clientMessageID: clientMessageID)
                    migrateForegroundActivity(from: optimisticSessionID, to: responseSession.id)
                    migrateRuntimeActivity(from: optimisticSessionID, to: responseSession.id)
                } else {
                    moveSessionRecentActivityProjection(
                        from: optimisticSessionID,
                        to: responseSession.id,
                        clientMessageID: nil
                    )
                }
                if resume == nil {
                    // 先让真实 ID 入库，再删临时 ID。否则 sessions 的 didSet 裁剪会把刚迁移到
                    // 真实 ID 的预览/最近活动投影当成孤儿清掉，造成新会话瞬间回跳或消失。
                    upsert(responseSession)
                    removeSession(optimisticSessionID)
                    conversationStore.reset(sessionID: optimisticSessionID)
                    logStore.reset(sessionID: optimisticSessionID)
                }
            }
            upsert(responseSession)
            setSessionControlState(resume == nil ? .ipadOwned : .takenOver, sessionID: responseSession.id)
            insertExpandedProjectID(responseSession.projectID)

            if queuesInitialInput, let clientMessageID {
                let intent: QueuedTurnIntent = payload.options.collaborationMode == .plan
                    ? .plan
                    : .standard
                let item = QueuedTurnEntry(
                    sessionID: responseSession.id,
                    projectID: responseSession.projectID,
                    payload: payload,
                    clientMessageID: clientMessageID,
                    intent: intent,
                    expectedTurnID: responseSession.activeTurnID,
                    requiresFreshTurn: permissionSelection?.requiresNewTurn == true ? true : nil
                )
                guard mutateAndPersistQueuedTurns({
                    if queuedRunningTurnsBySessionID[responseSession.id]?.contains(where: {
                        $0.clientMessageID == clientMessageID
                    }) != true {
                        queuedRunningTurnsBySessionID[responseSession.id, default: []].append(item)
                    }
                }) else {
                    throw AgentAPIError.invalidResponse
                }
            }

            let responseSelectionLease: SessionSelectionLease?
            if let optimisticSessionID, let optimisticSelectionLease {
                if optimisticSessionID == responseSession.id {
                    responseSelectionLease = isSelectionLeaseCurrent(optimisticSelectionLease)
                        ? optimisticSelectionLease
                        : nil
                } else {
                    responseSelectionLease = replaceSelectionIfCurrent(
                        from: optimisticSessionID,
                        to: responseSession,
                        lease: optimisticSelectionLease
                    )
                }
            } else {
                responseSelectionLease = commitSelection(
                    projectID: responseSession.projectID,
                    sessionID: responseSession.id,
                    reason: .userOpen,
                    ifCurrent: createIntent
                )
            }

            // 历史 resume 必须先补齐上下文，再追加本次用户输入，避免“发完历史没了”。
            // 新线程的首轮内容由本地回显和 buffered event replay 承接；turn/start 刚 ACK 时 rollout
            // 可能尚未可读，此时同步请求完整历史只会制造 no-rollout/超时竞态。
            let didLoadInitialHistory: Bool
            if responseSelectionLease == nil {
                // 用户已经切走：保留服务端创建结果和本地投影，历史在再次打开时按需补拉。
                didLoadInitialHistory = false
            } else if hasLoadedFullHistorySnapshot(sessionID: responseSession.id) {
                // 用户刚从历史列表进入时可复用已有快照，避免同一会话立刻再打一次 full。
                didLoadInitialHistory = true
            } else if resume != nil {
                didLoadInitialHistory = await loadHistoryIfNeeded(for: responseSession)
            } else if payload.isEmpty {
                // 新建空 thread 在首个 turn 前没有 rollout。把当前空快照标成已加载，前台恢复时
                // 就不会误打 thread/turns/list 并把 no-rollout 错报成“大历史加载失败”；首个 turn
                // 会改变 updatedAt/revision/lastSeq，届时签名自然失效并允许正常补拉。
                markEmptyHistoryLoaded(for: responseSession)
                didLoadInitialHistory = true
            } else {
                // 非空新线程不能标成“已加载空历史”，否则重新进入时可能跳过真正的历史补拉。
                // 保持未加载状态，当前首轮直接连接事件流，后续刷新或重新进入再做权威对账。
                didLoadInitialHistory = false
            }
            if !prompt.isEmpty, !queuesInitialInput {
                if let clientMessageID {
                    conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: responseSession.id, status: .sent)
                    conversationStore.compactTurnPayloadAfterSendAccepted(clientMessageID: clientMessageID, sessionID: responseSession.id)
                } else {
                    conversationStore.appendLocalUser(
                        prompt,
                        sessionID: responseSession.id,
                        clientMessageID: nil,
                        sendStatus: .sent,
                        turnPayload: payload.retainedAfterAcceptedSend()
                    )
                }
                setForegroundActivity(.waitingForAssistant, sessionID: responseSession.id)
            } else if prompt.isEmpty {
                conversationStore.appendSystem(L10n.text("ui.an_interactive_session_has_been_started"), sessionID: responseSession.id)
            }
            if let firstMessage = response.firstMessage {
                conversationStore.completeMessage(firstMessage, metadata: .empty, fallbackSessionID: responseSession.id)
                if firstMessage.role == .assistant {
                    setSessionListProjection(sessionID: responseSession.id, preview: firstMessage.content, source: .localAssistant, clientMessageID: nil)
                    clearForegroundActivity(sessionID: responseSession.id)
                }
            }
            // 历史已成为 canonical 快照后，WS 只需要补连接状态；否则 buffered content replay
            // 会把同一 turn 的过程卡再次 append 到时间线。历史加载失败时仍保留 replay，避免漏消息。
            if let responseSelectionLease,
               isSelectionLeaseCurrent(responseSelectionLease) {
                let shouldReplayBufferedEvents = resume == nil || !didLoadInitialHistory
                connectWebSocket(responseSession, replayBufferedEvents: shouldReplayBufferedEvents)
                // 恢复反馈属于页面生命周期状态，不是服务端 transcript 内容，避免它参与历史排序。
                setStatusMessage(resume == nil ? L10n.text("ui.session_started") : L10n.text("ui.this_historical_conversation_has_been_continued"))
                setErrorMessage(nil)
            }
            if queuesInitialInput {
                // thread/start 等待期间即使用户切换了会话，首条输入也已持久化，
                // 必须用独立会话监听继续 queue/add，不能依赖当前 selection。
                ensureQueuedSessionMonitoring(sessionID: responseSession.id)
                dispatchNextQueuedRunningTurnIfIdle(sessionID: responseSession.id)
            }
            registeredPermissionBoundaryClientMessageID = nil
            return true
        } catch {
            if case CodexAppServerSessionRuntimeError.activeTurnConflict(
                let authoritativeSession,
                let activeTurnID
            ) = error,
               resume != nil {
                // resume 快照已经证明旧 turn 仍在运行。这里只回滚本次未送达的新消息，
                // 不能把复用原 ID 的真实会话写成 failed，也不能清掉原审批/补充问题。
                var recoveredSession = authoritativeSession
                recoveredSession.status = "running"
                recoveredSession.activeTurnID = activeTurnID
                recoveredSession = sessionPreservingActiveApproval(recoveredSession)
                upsert(recoveredSession)
                if let optimisticSessionID, let clientMessageID {
                    conversationStore.updateSendStatus(
                        clientMessageID: clientMessageID,
                        sessionID: optimisticSessionID,
                        status: .failed
                    )
                    clearSessionListProjection(
                        sessionID: optimisticSessionID,
                        clientMessageID: clientMessageID
                    )
                    clearSessionRecentActivityProjection(
                        sessionID: optimisticSessionID,
                        clientMessageID: clientMessageID
                    )
                }
                if let optimisticSelectionLease,
                   isSelectionLeaseCurrent(optimisticSelectionLease) {
                    connectWebSocket(recoveredSession, replayBufferedEvents: true)
                    setStatusMessage(error.localizedDescription)
                    setErrorMessage(nil)
                }
                return false
            }
            if let optimisticSessionID {
                if let clientMessageID {
                    conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: optimisticSessionID, status: .failed)
                    clearSessionListProjection(sessionID: optimisticSessionID, clientMessageID: clientMessageID)
                }
                clearSessionRecentActivityProjection(sessionID: optimisticSessionID, clientMessageID: clientMessageID)
                if let localDraft {
                    // 首发失败不销毁草稿，也不能把它改成普通 failed 会话；用户修正配置或
                    // 网络恢复后应能直接重试，且重试仍然是 thread/start 而不是 thread/resume。
                    upsert(localDraft)
                    setSessionRecentActivityProjection(sessionID: localDraft.id, clientMessageID: nil)
                } else {
                    updateSession(optimisticSessionID) { item in
                        item.status = "failed"
                    }
                }
                clearForegroundActivity(sessionID: optimisticSessionID)
            }
            if let optimisticSelectionLease,
               isSelectionLeaseCurrent(optimisticSelectionLease) {
                // 保留协议原始错误进入统一出口。若先翻译成提示文案，writer 冲突标记会丢失，
                // Composer 仍会错误地保持可发送状态。
                setErrorMessage(error.localizedDescription)
            }
            return false
        }
    }

    func markEmptyHistoryLoaded(for session: AgentSession) {
        conversationStore.replaceHistorySnapshot([], sessionID: session.id)
        historyLoadedSignatureBySessionID[session.id] = HistoryLoadSignature(session: session)
        historyLoadedQualityBySessionID[session.id] = .full
        freshEmptyHistorySignatureBySessionID[session.id] = HistoryLoadSignature(session: session)
        historySavingsNoticesBySessionID.removeValue(forKey: session.id)
    }

    @discardableResult
    func loadHistoryIfNeeded(for session: AgentSession) async -> Bool {
        // 本地草稿没有服务端 thread，更没有 rollout；所有历史读取都必须短路。
        if session.isLocalDraft {
            return true
        }
        if canReuseFreshEmptyHistory(for: session) {
            return true
        }
        guard !canReuseLoadedHistory(for: session, loadMode: .full) else {
            return true
        }
        return await loadHistory(for: session)
    }

    func canReuseFreshEmptyHistory(for session: AgentSession) -> Bool {
        guard let baseline = freshEmptyHistorySignatureBySessionID[session.id] else {
            return false
        }
        // thread/start 与 thread/list 的 updatedAt 来源并不稳定，不能用它判断首个 turn 是否存在。
        // 本地首发会主动清除此标记；远端状态若已出现 turn/seq/revision，也立即恢复正常历史补拉。
        let isStillFresh = baseline.revision == session.revision
            && baseline.lastSeq == session.lastSeq
            && session.activeTurnID == nil
        if !isStillFresh {
            freshEmptyHistorySignatureBySessionID.removeValue(forKey: session.id)
        }
        return isStillFresh
    }

    // quiet 模式用于切回已加载会话时的后台补拉：默认界面继续展示缓存，不出进度条，
    // 失败也不打扰用户（下一次轮询/手动刷新仍会兜底）。选中会话可用 showsProgress
    // 只打开轻量进度反馈，不改变 quiet 的失败和 notice 语义。
    @discardableResult
    func loadHistory(
        for session: AgentSession,
        quiet: Bool = false,
        showsProgress: Bool? = nil,
        loadMode: HistoryMessagesPage.LoadMode = .full,
        force: Bool = false,
        reason: HistoryLoadReason = .automatic,
        successStatusMessage: String? = nil,
        allowPolicyRetry: Bool = true,
        recoveryGeneration: UInt64? = nil,
        fullTurnPageLimit: Int? = nil,
        noticeMessageOverride: String? = nil
    ) async -> Bool {
        if session.isLocalDraft {
            return true
        }
        // quiet 只控制失败、状态和 savings notice 是否打扰用户；选中的已缓存会话仍可
        // 显示轻量历史补拉进度，避免消息区只有本地 user 气泡而看不出 assistant 仍在补齐。
        let shouldShowProgress = showsProgress ?? !quiet
        // 普通自动/权威打开只需要 progress；savings 横幅应只在用户明确选择
        // full/summary，或策略层已经确认需要降级/重试时出现。否则每次短暂的
        // 首屏请求都会先暴露“正在加载完整历史”的决策卡片，再在成功时立即消失。
        let shouldShowSavingsNotice = !quiet
            && (noticeMessageOverride != nil || reason == .summaryChoice || reason == .manualFull)
        if !force, canReuseLoadedHistory(for: session, loadMode: loadMode) {
            return true
        }

        if let existing = historyLoadJobsBySessionID[session.id] {
            let belongsToOlderRecovery = recoveryGeneration.map {
                existing.recoveryGeneration != $0
            } ?? false
            if belongsToOlderRecovery {
                // 先比较恢复代次，再比较 full/economy。旧代 full 降级出的 economy
                // job 也不能让新代 full 恢复直接返回成功。
                cancelHistoryLoadJob(existing, sessionID: session.id)
            } else if existing.loadMode == loadMode {
                if reason == .writerRetry {
                    // writer 重试必须读取点击时刻之后的权威历史。即使已有任务也不能加入，
                    // 否则 Desktop 刚产生的消息可能不在旧请求的快照里。
                    cancelHistoryLoadJob(existing, sessionID: session.id)
                } else if force,
                   existing.cachePolicy != .bypass,
                   recoveryGeneration != nil || reason == .authoritativeReopen {
                    // 只有回前台/网络恢复需要读取“此刻”的权威历史：加入一个更早启动的
                    // reuseRecent job 可能拿到自主 turn 完成前的快照，因此直接换代。显式重新
                    // 打开仍在等待的终态会话也遵守同一规则，不能复用离开前的局部快照。
                    // 用户手动刷新没有恢复代次，应复用并提升已有 quiet job；否则会制造
                    // 重复请求，且旧 waiter 可能吞掉本该呈现给用户的失败反馈。
                    cancelHistoryLoadJob(existing, sessionID: session.id)
                } else {
                    // 已有同模式加载时直接等待同一个 job，避免切换/刷新制造重复大包请求。
                    // 前台刷新加入 quiet job 后必须提升共享 job 的反馈级别；否则 quiet waiter
                    // 若先恢复，会先移除 job 并吞掉失败提示，手动刷新只能静默返回 false。
                    if shouldShowProgress {
                        promoteHistoryLoadJobForVisibleProgress(existing, sessionID: session.id)
                    }
                    if !quiet {
                        promoteHistoryLoadJobForForegroundReporting(
                            existing,
                            sessionID: session.id,
                            successStatusMessage: successStatusMessage,
                            showSavingsNotice: shouldShowSavingsNotice
                        )
                        if shouldShowProgress {
                            setHistoryLoadProgress(
                                sessionID: session.id,
                                title: loadMode == .full ? L10n.text("ui.request_full_history") : L10n.text("ui.request_thumbnail_history"),
                                fraction: 0.32
                            )
                        }
                        let didLoad = await awaitHistoryLoadJob(
                            existing,
                            session: session,
                            quiet: false,
                            successStatusMessage: successStatusMessage
                        )
                        if shouldShowProgress {
                            clearHistoryLoadProgress(
                                sessionID: session.id,
                                ifCurrentHistoryLoadJobToken: existing.token
                            )
                        }
                        return didLoad
                    }
                    if shouldShowProgress {
                        setHistoryLoadProgress(
                            sessionID: session.id,
                            title: loadMode == .full ? L10n.text("ui.request_full_history") : L10n.text("ui.request_thumbnail_history"),
                            fraction: 0.32
                        )
                    }
                    let didLoad = await awaitHistoryLoadJob(
                        existing,
                        session: session,
                        quiet: quiet,
                        successStatusMessage: successStatusMessage
                    )
                    if shouldShowProgress {
                        clearHistoryLoadProgress(
                            sessionID: session.id,
                            ifCurrentHistoryLoadJobToken: existing.token
                        )
                    }
                    return didLoad
                }
            } else {
                switch reason {
                case .authoritativeReopen, .summaryChoice, .manualFull, .writerRetry:
                    cancelHistoryLoadJob(existing, sessionID: session.id)
                case .automatic:
                    return true
                }
            }
        }

        let signature = HistoryLoadSignature(session: session)
        let jobToken = beginHistoryLoadJob(sessionID: session.id)
        // 自适应缩页时 full 直接按目标 turn 数请求（runtime 对 ≤ ladder 顶端的 limit 视为精确 turn 数）。
        let limit: Int
        if loadMode == .full, let fullTurnPageLimit {
            limit = fullTurnPageLimit
        } else {
            limit = loadMode == .full ? fullHistoryPageLimit : economyHistoryPageLimit
        }
        let hasNewerSessionSnapshot = historyLoadedSignatureBySessionID[session.id].map { $0 != signature } == true
        let cachePolicy: HistoryFirstPageCachePolicy = force || hasNewerSessionSnapshot ? .bypass : .reuseRecent
        let task = Task { [self] in
            try await historyFirstPage(
                sessionID: session.id,
                limit: limit,
                loadMode: loadMode,
                cachePolicy: cachePolicy
            )
        }
        let job = HistoryLoadJob(
            token: jobToken,
            sessionSignature: signature,
            loadMode: loadMode,
            cachePolicy: cachePolicy,
            recoveryGeneration: recoveryGeneration,
            allowPolicyRetry: allowPolicyRetry,
            fullTurnPageLimit: loadMode == .full ? fullTurnPageLimit : nil,
            task: task,
            showsProgress: shouldShowProgress,
            requiresForegroundReporting: !quiet,
            foregroundSuccessStatusMessage: quiet ? nil : successStatusMessage,
            foregroundSelectionLease: quiet ? nil : currentSelectionLease()
        )
        historyLoadJobsBySessionID[session.id] = job
        if shouldShowSavingsNotice {
            setHistoryLoadNotice(
                sessionID: session.id,
                kind: loadMode == .full ? .loadingFull : .loadingSummary,
                // 自适应缩页/降级重试会先给出带量级的提示；没有 override 时保持既有默认文案，
                // 避免这里的重设把 failHistoryLoadJob 刚写入的结构化原因覆盖成泛化文案。
                message: noticeMessageOverride ?? (loadMode == .economy ? deferredFullHistoryNotice(sessionID: session.id) : nil)
            )
        }

        if shouldShowProgress {
            setHistoryLoadProgress(sessionID: session.id, title: loadMode == .full ? L10n.text("ui.ready_to_load_full_history") : L10n.text("ui.prepare_to_load_abbreviated_history"), fraction: 0.08)
        }
        defer {
            if shouldShowProgress {
                clearHistoryLoadProgress(
                    sessionID: session.id,
                    ifCurrentHistoryLoadJobToken: jobToken
                )
            }
        }

        if shouldShowProgress {
            setHistoryLoadProgress(sessionID: session.id, title: loadMode == .full ? L10n.text("ui.request_full_history") : L10n.text("ui.request_thumbnail_history"), fraction: 0.32)
        }
        return await awaitHistoryLoadJob(job, session: session, quiet: quiet, successStatusMessage: successStatusMessage)
    }

    func promoteHistoryLoadJobForForegroundReporting(
        _ job: HistoryLoadJob,
        sessionID: SessionID,
        successStatusMessage: String?,
        showSavingsNotice: Bool
    ) {
        guard var current = historyLoadJobsBySessionID[sessionID], current.token == job.token else {
            return
        }
        current.requiresForegroundReporting = true
        current.foregroundSelectionLease = currentSelectionLease()
        if let successStatusMessage {
            current.foregroundSuccessStatusMessage = successStatusMessage
        }
        historyLoadJobsBySessionID[sessionID] = current
        if showSavingsNotice {
            setHistoryLoadNotice(
                sessionID: sessionID,
                kind: current.loadMode == .full ? .loadingFull : .loadingSummary,
                message: current.loadMode == .economy ? deferredFullHistoryNotice(sessionID: sessionID) : nil
            )
        }
    }

    func promoteHistoryLoadJobForVisibleProgress(_ job: HistoryLoadJob, sessionID: SessionID) {
        guard var current = historyLoadJobsBySessionID[sessionID], current.token == job.token else {
            return
        }
        // quiet 后台 job 被当前会话的可见 waiter 加入后，后续缩页/summary 替代任务
        // 也必须继承这项能力，不能只靠外层 defer 清理旧 token 的进度。
        current.showsProgress = true
        historyLoadJobsBySessionID[sessionID] = current
    }

    func scheduleQuietHistoryRefresh(for session: AgentSession, showsProgress: Bool = false) {
        Task { [weak self] in
            guard let self, self.selectedSessionID == session.id else {
                return
            }
            await self.loadHistory(for: session, quiet: true, showsProgress: showsProgress)
        }
    }

    func canReuseLoadedHistory(for session: AgentSession, loadMode: HistoryMessagesPage.LoadMode) -> Bool {
        guard conversationStore.hasLoadedHistory(sessionID: session.id),
              let loadedSignature = historyLoadedSignatureBySessionID[session.id],
              loadedSignature == HistoryLoadSignature(session: session),
              let loadedQuality = historyLoadedQualityBySessionID[session.id]
        else {
            return false
        }
        // 正在逐页补齐的首屏已经启动同一份 full 请求，不能因尚未完成而重复拉取 Turn 页。
        return loadMode == .economy || loadedQuality != .summary
    }

    func hasLoadedFullHistorySnapshot(sessionID: SessionID) -> Bool {
        conversationStore.hasLoadedHistory(sessionID: sessionID)
            && historyLoadedQualityBySessionID[sessionID] == .full
    }

    /// 重连预检只需要判断“刚刚是否已经拿到过同会话的完整首屏”。这里故意忽略
    /// thread/read 刷新的 metadata signature：resume 后的短暂断流会更新 session 元数据，
    /// 但在 4 秒缓存窗内立刻绕过缓存重拉同一大页只会放大弱网开销。超过短窗后仍按
    /// 正常恢复链路补拉，真正断线期间的消息也会由事件回放与后续历史对账兜底。
    func hasRecentFullHistoryFirstPage(sessionID: SessionID, now: Date = Date()) -> Bool {
        guard hasLoadedFullHistorySnapshot(sessionID: sessionID) else { return false }
        return historyFirstPageCacheByKey.contains { key, entry in
            key.profileID == appStore.activeHostScope.profileID
                && key.sessionID == sessionID
                && key.loadMode == .full
                && now.timeIntervalSince(entry.loadedAt) < historyFirstPageCacheTTL
        }
    }

    func awaitHistoryLoadJob(
        _ job: HistoryLoadJob,
        session: AgentSession,
        quiet: Bool,
        successStatusMessage: String?
    ) async -> Bool {
        do {
            let result = try await job.task.value
            return finishHistoryLoadJob(
                job,
                result: result,
                sessionID: session.id,
                quiet: quiet,
                successStatusMessage: successStatusMessage
            )
        } catch {
            return await failHistoryLoadJob(job, session: session, error: error, quiet: quiet)
        }
    }

    func finishHistoryLoadJob(
        _ job: HistoryLoadJob,
        result: HistoryFirstPageResult,
        sessionID: SessionID,
        quiet: Bool,
        successStatusMessage: String?
    ) -> Bool {
        guard let current = historyLoadJobsBySessionID[sessionID], current.token == job.token else {
            // 当前 job 已被用户选择 summary 或新的刷新取代；旧结果可以完成，但不能覆盖界面。
            return historyLoadedSignatureBySessionID[sessionID] == job.sessionSignature
        }
        let hasCurrentForegroundOwner = current.foregroundSelectionLease
            .map(isSelectionLeaseCurrent) ?? false
        let effectiveQuiet = !current.requiresForegroundReporting || !hasCurrentForegroundOwner
        let effectiveSuccessStatusMessage = current.foregroundSuccessStatusMessage ?? successStatusMessage
        historyLoadJobsBySessionID.removeValue(forKey: sessionID)
        guard isCurrentHistoryPageRequest(sessionID: sessionID, token: result.token) else {
            return false
        }
        if !effectiveQuiet {
            setHistoryLoadProgress(sessionID: sessionID, title: L10n.text("ui.parse_historical_messages"), fraction: 0.74)
        }
        applyHistoryFirstPage(result.page, sessionID: sessionID)
        if !effectiveQuiet {
            setHistoryLoadProgress(sessionID: sessionID, title: L10n.text("ui.update_interface"), fraction: 0.94)
        }
        updateHistoryPageState(sessionID: sessionID, page: result.page, preserveExistingCursorOnEmptyPage: true)
        historyLoadedSignatureBySessionID[sessionID] = job.sessionSignature
        if job.loadMode == .economy {
            historyLoadedQualityBySessionID[sessionID] = .summary
        } else if result.page.itemContinuations.isEmpty {
            historyLoadedQualityBySessionID[sessionID] = .full
        } else {
            historyLoadedQualityBySessionID[sessionID] = .enriching
        }
        if job.loadMode == .full {
            deferredFullHistorySessionIDs.remove(sessionID)
            historySavingsNoticesBySessionID.removeValue(forKey: sessionID)
        } else if !effectiveQuiet {
            setHistoryLoadNotice(
                sessionID: sessionID,
                kind: .summaryLoaded,
                message: deferredFullHistoryNotice(sessionID: sessionID)
            )
        }
        if job.loadMode == .economy {
            // Turn 可能在 summary 请求尚未返回时就完成；等当前 job 落盘后再补拉 full，
            // 避免不同模式的并发请求互相抢占并丢失恢复机会。
            scheduleDeferredFullHistoryReloadAfterTurnCompletion(sessionID: sessionID)
        }
        if let effectiveSuccessStatusMessage {
            setStatusMessage(effectiveSuccessStatusMessage)
        }
        return true
    }

    func failHistoryLoadJob(
        _ job: HistoryLoadJob,
        session: AgentSession,
        error: Error,
        quiet: Bool
    ) async -> Bool {
        let sessionID = session.id
        guard let current = historyLoadJobsBySessionID[sessionID], current.token == job.token else {
            return false
        }
        let hasCurrentForegroundOwner = current.foregroundSelectionLease
            .map(isSelectionLeaseCurrent) ?? false
        let effectiveQuiet = !current.requiresForegroundReporting || !hasCurrentForegroundOwner
        historyLoadJobsBySessionID.removeValue(forKey: sessionID)
        if error is CancellationError {
            return false
        }
        if let failure = error as? HistoryFirstPageFetchFailure,
           !isCurrentHistoryPageRequest(sessionID: sessionID, token: failure.token) {
            return false
        }
        if let policyFailure = historyPolicyFailure(from: error) {
            switch job.loadMode {
            case .full:
                // 低波及自适应缩页：仅当实际可分页的 thread/turns/list full
                // 被 gateway 按体量阻断时才逐级缩页。老 agentd 回退到 thread/read 后
                // limit 不会改变线上请求，不能误做 10→5→2→1 的重复全量读取。
                // 从当前 full 页向下（10→5→2→1）重试完整历史，尽量多呈现真实完整内容；
                // 缺少结构化线索或已缩到最小仍超限时，才回退缩略历史。
                if policyFailure.reason == "history_response_too_large",
                   policyFailure.method == "thread/turns/list",
                   policyFailure.itemsView == "full",
                   policyFailure.responseBytes != nil,
                   let nextTurnPageLimit = nextFullTurnPageLimit(
                       below: job.fullTurnPageLimit ?? fullHistoryTurnPageLadder.first ?? 10
                   ) {
                    let retryMessage = fullHistoryLadderRetryNotice(policyFailure)
                    if !effectiveQuiet {
                        setHistoryLoadNotice(sessionID: sessionID, kind: .loadingFull, message: retryMessage)
                        setStatusMessage(retryMessage)
                    }
                    return await loadHistory(
                        for: session,
                        quiet: effectiveQuiet,
                        showsProgress: current.showsProgress,
                        loadMode: .full,
                        force: true,
                        reason: .automatic,
                        successStatusMessage: effectiveQuiet ? nil : L10n.text("ui.request_full_history"),
                        recoveryGeneration: job.recoveryGeneration,
                        fullTurnPageLimit: nextTurnPageLimit,
                        noticeMessageOverride: effectiveQuiet ? nil : retryMessage
                    )
                }
                if policyFailure.reason == "history_response_too_large", session.isRunning {
                    deferredFullHistorySessionIDs.insert(sessionID)
                }
                let message = fullHistoryOversizeNotice(policyFailure, sessionID: sessionID)
                if !effectiveQuiet {
                    setHistoryLoadNotice(sessionID: sessionID, kind: .loadingSummary, message: message)
                    setStatusMessage(message)
                }
                return await loadHistory(
                    for: session,
                    quiet: effectiveQuiet,
                    showsProgress: current.showsProgress,
                    loadMode: .economy,
                    force: true,
                    reason: .automatic,
                    successStatusMessage: effectiveQuiet ? nil : L10n.text("ui.thumbnail_history_automatically_loaded"),
                    recoveryGeneration: job.recoveryGeneration,
                    noticeMessageOverride: effectiveQuiet ? nil : message
                )
            case .economy where policyFailure.reason == "history_response_too_large":
                break
            case .economy where job.allowPolicyRetry:
                let delay = policyFailure.retryAfterNanoseconds ?? historyPolicyRetryFallbackNanoseconds
                let seconds = policyFailure.retryAfterSeconds ?? Int((delay + 999_999_999) / 1_000_000_000)
                let message = L10n.plural("ui.compact_history_retry_seconds_count", count: seconds)
                if !effectiveQuiet {
                    setHistoryLoadNotice(sessionID: sessionID, kind: .loadingSummary, message: message)
                    setStatusMessage(message)
                }
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else {
                    return false
                }
                if let selectedSessionID, selectedSessionID != sessionID {
                    return false
                }
                return await loadHistory(
                    for: session,
                    quiet: effectiveQuiet,
                    showsProgress: current.showsProgress,
                    loadMode: .economy,
                    force: true,
                    reason: .automatic,
                    successStatusMessage: effectiveQuiet ? nil : L10n.text("ui.thumbnail_history_loaded"),
                    allowPolicyRetry: false,
                    recoveryGeneration: job.recoveryGeneration
                )
            default:
                break
            }
        }
        if job.loadMode == .full {
            if !effectiveQuiet {
                setHistoryLoadNotice(sessionID: sessionID, kind: .fullFailed)
                setStatusMessage(L10n.format("ui.full_history_loading_failed_value", error.localizedDescription))
            }
        } else {
            // 终态失败必须离开“正在加载”横幅，否则重连触发的静默刷新会让界面永远停在加载中。
            if !effectiveQuiet {
                setHistoryLoadNotice(sessionID: sessionID, kind: .summaryFailed)
                setErrorMessage(L10n.format("ui.thumbnail_history_loading_failed_value", error.localizedDescription))
            }
        }
        return false
    }

    // gateway 策略拒绝（-32080）对同样的请求参数是确定性失败：自动重连只会带着相同参数再次被拒，
    // 结果是错误横幅无限刷新。历史预算类拒绝（限流/响应过大/pending 过多）是时间窗资源，恢复后
    // 可以成功，这些仍保留重连与 history 重试路径。
    nonisolated static func isDeterministicGatewayPolicyFailure(_ message: String) -> Bool {
        guard message.contains("-32080") else {
            return false
        }
        let lowerMessage = message.lowercased()
        if lowerMessage.contains("thread/turns/list")
            || lowerMessage.contains("thread/read")
            || lowerMessage.contains("history response")
            || lowerMessage.contains("limit/itemsview")
            || message.contains("相同历史或列表请求仍在执行") {
            return false
        }
        return !(message.contains("历史响应")
            || message.contains("临时限流")
            || message.contains("响应过大")
            || message.contains("内容过大")
            || message.contains("请求过多"))
    }

    func sessionListPolicyFailure(from error: Error) -> SessionListPolicyFailure? {
        let appServerError: CodexAppServerError?
        if case CodexAppServerConnectionError.appServer(let error) = error {
            appServerError = error
        } else {
            appServerError = nil
        }
        let data = appServerError?.data?.objectValue
        let method = data?["method"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let reason = data?["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let message = error.localizedDescription.lowercased()
        let isStructuredListPolicy = appServerError?.code == -32080
            && method == "thread/list"
            && (reason == "history_budget_limited" || reason == "history_request_in_flight")
        let isLegacyListPolicy = message.contains("-32080")
            && message.contains("thread/list")
            && (message.contains("临时限流") || message.contains("相同历史或列表请求"))
        guard isStructuredListPolicy || isLegacyListPolicy else { return nil }

        let fallbackNanoseconds: UInt64 = reason == "history_request_in_flight"
            ? 1_000_000_000
            : 15_000_000_000
        let requestedNanoseconds: UInt64
        if let retryAfterMs = data?["retryAfterMs"]?.intValue, retryAfterMs > 0 {
            requestedNanoseconds = UInt64(retryAfterMs) * 1_000_000
        } else if let retryAfterSeconds = data?["retryAfterSeconds"]?.intValue, retryAfterSeconds > 0 {
            requestedNanoseconds = UInt64(retryAfterSeconds) * 1_000_000_000
        } else {
            requestedNanoseconds = fallbackNanoseconds
        }
        // 防止异常上游把客户端挂起太久；正常 gateway 窗口目前是 1~15 秒。
        let boundedNanoseconds = min(max(requestedNanoseconds, 1_000_000), 60_000_000_000)
        let seconds = max(1, Int((boundedNanoseconds + 999_999_999) / 1_000_000_000))
        return SessionListPolicyFailure(
            retryAfterNanoseconds: boundedNanoseconds,
            retryAfterSeconds: seconds
        )
    }

    func historyPolicyFailure(from error: Error) -> HistoryPolicyFailure? {
        let underlying = (error as? HistoryFirstPageFetchFailure)?.underlying ?? error
        let message = underlying.localizedDescription
        let lowerMessage = message.lowercased()
        let appServerError: CodexAppServerError?
        if case CodexAppServerConnectionError.appServer(let error) = underlying {
            appServerError = error
        } else {
            appServerError = nil
        }

        let data = appServerError?.data?.objectValue
        let reason = data?["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isHistoryReason = reason?.hasPrefix("history_") == true
        let isLegacyHistoryPolicyMessage =
            lowerMessage.contains("-32080")
            && (
                lowerMessage.contains("thread/turns/list")
                || lowerMessage.contains("thread/read")
                || lowerMessage.contains("history response")
                || lowerMessage.contains("limit/itemsview")
                || message.contains("历史响应")
                || message.contains("临时限流")
                || message.contains("响应过大")
                || message.contains("内容过大")
            )
        let isGatewayHistoryPolicy = appServerError?.code == -32080 && (isHistoryReason || isLegacyHistoryPolicyMessage)
        guard isGatewayHistoryPolicy || isLegacyHistoryPolicyMessage else {
            return nil
        }

        let retryAfterMs = data?["retryAfterMs"]?.intValue
        let retryAfterSeconds = data?["retryAfterSeconds"]?.intValue
            ?? Self.retryAfterSeconds(fromHistoryPolicyMessage: message)
        let retryAfterNanoseconds: UInt64?
        if let retryAfterMs, retryAfterMs > 0 {
            retryAfterNanoseconds = boundedHistoryPolicyRetryNanoseconds(UInt64(retryAfterMs) * 1_000_000)
        } else if let retryAfterSeconds, retryAfterSeconds > 0 {
            retryAfterNanoseconds = boundedHistoryPolicyRetryNanoseconds(UInt64(retryAfterSeconds) * 1_000_000_000)
        } else {
            retryAfterNanoseconds = nil
        }
        // gateway 在 history_response_too_large 时已带上被阻断的完整体量与 cap；
        // 保留下来供界面展示结构化量级，而不是只显示泛化的“过程输出较大”。
        let responseBytes = data?["responseBytes"]?.intValue
        let maxResponseBytes = data?["maxResponseBytes"]?.intValue
        let method = data?["method"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let itemsView = data?["itemsView"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return HistoryPolicyFailure(
            reason: reason,
            method: (method?.isEmpty == false) ? method : nil,
            retryAfterNanoseconds: retryAfterNanoseconds,
            retryAfterSeconds: retryAfterSeconds,
            responseBytes: (responseBytes.map { $0 > 0 } == true) ? responseBytes : nil,
            maxResponseBytes: (maxResponseBytes.map { $0 > 0 } == true) ? maxResponseBytes : nil,
            itemsView: (itemsView?.isEmpty == false) ? itemsView : nil
        )
    }

    func boundedHistoryPolicyRetryNanoseconds(_ nanoseconds: UInt64) -> UInt64 {
        min(max(nanoseconds, 1_000_000), historyPolicyRetryMaxNanoseconds)
    }

    nonisolated static func retryAfterSeconds(fromHistoryPolicyMessage message: String) -> Int? {
        let patterns = [
            #""retryAfterSeconds"\s*:\s*(\d+)"#,
            #""retry_after_seconds"\s*:\s*(\d+)"#,
            #"请\s*(\d+)\s*秒后重试"#
        ]
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            guard let match = regex.firstMatch(in: message, range: range),
                  let secondsRange = Range(match.range(at: 1), in: message),
                  let seconds = Int(message[secondsRange]) else {
                continue
            }
            return seconds
        }
        return nil
    }

    /// 缩略提示里展示的历史体量。二进制步进、locale 无关（String(format:) 不本地化小数点），
    /// 让 UI 文案与回归断言都稳定，例如 9,786,022 → “9.3 MB”、5,242,880 → “5.0 MB”。
    nonisolated static func historyByteDescription(_ bytes: Int) -> String {
        let value = max(0, bytes)
        if value >= 1 << 20 {
            return String(format: "%.1f MB", Double(value) / Double(1 << 20))
        }
        if value >= 1 << 10 {
            return String(format: "%.0f KB", Double(value) / Double(1 << 10))
        }
        return "\(value) B"
    }

    /// full 首屏被 gateway cap 阻断时的缩略提示：优先展示结构化量级（完整体量 vs 上限），
    /// 运行中与非运行中给出不同去向说明；缺量级时回退到既有泛化文案。
    func fullHistoryOversizeNotice(_ failure: HistoryPolicyFailure, sessionID: SessionID) -> String {
        let deferred = deferredFullHistoryNotice(sessionID: sessionID)
        guard failure.reason == "history_response_too_large",
              let responseBytes = failure.responseBytes,
              let maxResponseBytes = failure.maxResponseBytes else {
            return deferred ?? L10n.text("ui.the_full_history_content_is_large_and_the")
        }
        let full = Self.historyByteDescription(responseBytes)
        let cap = Self.historyByteDescription(maxResponseBytes)
        // deferred 非空 ⇔ 运行中且触发 too_large：完整历史会在 Turn 完成后自动恢复。
        if deferred != nil {
            return L10n.format("ui.full_history_exceeds_limit_running_value", full, cap)
        }
        return L10n.format("ui.full_history_exceeds_limit_value", full, cap)
    }

    /// 自适应缩页重试阶段的提示：仍在尝试加载完整历史，只是换更小的 turn 页，
    /// 与最终回退缩略（fullHistoryOversizeNotice）区分开。
    func fullHistoryLadderRetryNotice(_ failure: HistoryPolicyFailure) -> String {
        guard let responseBytes = failure.responseBytes,
              let maxResponseBytes = failure.maxResponseBytes else {
            return L10n.text("ui.the_full_history_content_is_large_and_the")
        }
        return L10n.format(
            "ui.full_history_exceeds_limit_retrying_value",
            Self.historyByteDescription(responseBytes),
            Self.historyByteDescription(maxResponseBytes)
        )
    }

    /// full 自适应缩页的下一级 turn 页大小：取 ladder 中严格小于当前值的最大项；
    /// 已到最小（1）则返回 nil，交由调用方回退缩略历史。不会重复相同参数。
    func nextFullTurnPageLimit(below current: Int) -> Int? {
        fullHistoryTurnPageLadder.first(where: { $0 < current })
    }

    func cancelHistoryLoadJob(_ job: HistoryLoadJob, sessionID: SessionID) {
        if historyLoadJobsBySessionID[sessionID]?.token == job.token {
            // best-effort 取消旧 job；即使底层请求已发出，token 校验也会阻止迟到结果覆盖当前视图。
            job.task.cancel()
            historyLoadJobsBySessionID.removeValue(forKey: sessionID)
            // 新 job 可能继续保持 quiet；先清掉旧代可见进度，由替代 job
            // 按自己的 showsProgress 选择是否重新写入。
            clearHistoryLoadProgress(sessionID: sessionID)
        }
    }

    func clearHistoryLoadProgress(
        sessionID: SessionID,
        ifCurrentHistoryLoadJobToken token: Int
    ) {
        // 旧 job 被权威重开/恢复任务取代后可能才结束 await；只允许当前代清进度，
        // 避免旧 waiter 把新 job 刚写入的加载反馈误删。
        guard historyLoadJobTokenBySessionID[sessionID] == token else {
            return
        }
        clearHistoryLoadProgress(sessionID: sessionID)
    }

    func setHistoryLoadNotice(sessionID: SessionID, kind: HistorySavingsNotice.Kind, message customMessage: String? = nil) {
        let defaultMessage: String
        switch kind {
        case .loadingFull:
            defaultMessage = L10n.text("ui.loading_the_complete_history_you_may_need_to")
        case .fullFailed:
            defaultMessage = L10n.text("ui.the_complete_history_failed_to_load_the_content")
        case .loadingSummary:
            defaultMessage = L10n.text("ui.loading_thumbnail_history")
        case .summaryLoaded:
            defaultMessage = L10n.text("ui.currently_showing_abbreviated_history")
        case .summaryFailed:
            defaultMessage = L10n.text("ui.the_thumbnail_history_loading_failed_possibly_due_to")
        }
        let message = customMessage ?? defaultMessage
        historySavingsNoticesBySessionID[sessionID] = HistorySavingsNotice(sessionID: sessionID, kind: kind, message: message)
    }

    func deferredFullHistoryNotice(sessionID: SessionID) -> String? {
        guard deferredFullHistorySessionIDs.contains(sessionID) else {
            return nil
        }
        return L10n.text("ui.the_full_history_will_be_restored_after_the_current_turn")
    }

    /// full 响应只在 Turn 运行期间因过程项临时膨胀时才进入该路径。完成事件已经先把
    /// session 更新为 completed；这里异步补拉，避免历史网络请求阻塞事件队列和完成通知。
    func scheduleDeferredFullHistoryReloadAfterTurnCompletion(sessionID: SessionID) {
        guard deferredFullHistorySessionIDs.contains(sessionID),
              selectedSessionID == sessionID,
              queuedRunningTurnsBySessionID[sessionID]?.isEmpty != false,
              historyLoadJobsBySessionID[sessionID] == nil,
              let session = sessionsByID[sessionID],
              !session.isRunning
        else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await Task.yield()
            guard self.deferredFullHistorySessionIDs.contains(sessionID),
                  self.selectedSessionID == sessionID,
                  self.queuedRunningTurnsBySessionID[sessionID]?.isEmpty != false,
                  self.historyLoadJobsBySessionID[sessionID] == nil,
                  let latestSession = self.sessionsByID[sessionID],
                  !latestSession.isRunning
            else {
                return
            }
            // 发起 canonical full 前移除标记；若完成后的 full 仍然过大，应回到普通缩略提示，
            // 不能继续声称会在“当前 Turn 完成后”恢复。
            self.deferredFullHistorySessionIDs.remove(sessionID)
            let didLoad = await self.loadHistory(
                for: latestSession,
                quiet: true,
                loadMode: .full,
                force: true,
                reason: .automatic
            )
            if !didLoad,
               self.historyLoadedQualityBySessionID[sessionID] == .summary {
                self.setHistoryLoadNotice(sessionID: sessionID, kind: .summaryLoaded)
            }
        }
    }

    @discardableResult
    func refreshSelectedSessionContent(
        _ session: AgentSession,
        successStatusMessage: String? = L10n.text("ui.the_current_session_has_been_refreshed"),
        reason: HistoryLoadReason = .manualFull
    ) async -> Bool {
        isRefreshingSelectedSession = true
        defer { isRefreshingSelectedSession = false }

        let didLoad = await loadHistory(
            for: session,
            quiet: false,
            loadMode: .full,
            force: true,
            reason: reason,
            successStatusMessage: successStatusMessage
        )
        if didLoad {
            if !session.isRunning {
                clearForegroundActivity(sessionID: session.id)
                clearRuntimeActivity(sessionID: session.id)
            }
            // 手动刷新当前会话只等待历史页接口；列表/运行态校准放到后台，
            // 避免 thread/list 之类的慢接口把“刷新历史”按钮继续卡住。
            scheduleSessionStateReconciliationAfterHistoryRefresh(session)
            setErrorMessage(nil)
        }
        return didLoad
    }

    func historyFirstPage(
        sessionID: SessionID,
        limit: Int,
        loadMode: HistoryMessagesPage.LoadMode,
        cachePolicy: HistoryFirstPageCachePolicy
    ) async throws -> HistoryFirstPageResult {
        let key = HistoryFirstPageRequestKey(
            profileID: appStore.activeHostScope.profileID,
            sessionID: sessionID,
            limit: limit,
            loadMode: loadMode
        )
        if cachePolicy == .reuseRecent,
           let cached = historyFirstPageCacheByKey[key],
           Date().timeIntervalSince(cached.loadedAt) < historyFirstPageCacheTTL {
            return HistoryFirstPageResult(page: cached.page, token: cached.token)
        }
        if cachePolicy == .reuseRecent,
           let inFlight = historyFirstPageInFlightByKey[key] {
            do {
                return HistoryFirstPageResult(page: try await inFlight.task.value, token: inFlight.token)
            } catch {
                throw HistoryFirstPageFetchFailure(underlying: error, token: inFlight.token)
            }
        }

        let token = beginHistoryPageRequest(sessionID: sessionID)
        let client = try clientFactory()
        let task = Task {
            try await client.messagesPage(
                sessionID: sessionID,
                before: nil,
                limit: limit,
                loadMode: loadMode
            )
        }
        historyFirstPageInFlightByKey[key] = HistoryFirstPageInFlight(token: token, task: task)
        do {
            let page = try await task.value
            if historyFirstPageInFlightByKey[key]?.token == token {
                historyFirstPageInFlightByKey.removeValue(forKey: key)
                historyFirstPageCacheByKey[key] = HistoryFirstPageCacheEntry(page: page, loadedAt: Date(), token: token)
            }
            return HistoryFirstPageResult(page: page, token: token)
        } catch {
            if historyFirstPageInFlightByKey[key]?.token == token {
                historyFirstPageInFlightByKey.removeValue(forKey: key)
            }
            throw HistoryFirstPageFetchFailure(underlying: error, token: token)
        }
    }

    func applyHistoryFirstPage(_ page: HistoryMessagesPage, sessionID: SessionID) {
        ingestHistoryContext(page.context, fallbackSessionID: sessionID)
        conversationStore.replaceHistorySnapshot(
            page.messages,
            sessionID: sessionID,
            authoritativeCompletedTurnItems: page.authoritativeCompletedTurnItems
        )
        reconcilePendingPermissionTurnBoundaries(
            sessionID: sessionID,
            historyMessages: page.messages
        )
        replaceHistoryItemEnrichment(page: page, sessionID: sessionID)
        updateHistorySavingsNotice(sessionID: sessionID, page: page)
    }

    func updateHistorySavingsNotice(sessionID: SessionID, page: HistoryMessagesPage) {
        guard page.loadMode == .economy,
              let notice = page.notice?.trimmingCharacters(in: .whitespacesAndNewlines),
              !notice.isEmpty
        else {
            historySavingsNoticesBySessionID.removeValue(forKey: sessionID)
            return
        }
        historySavingsNoticesBySessionID[sessionID] = HistorySavingsNotice(
            sessionID: sessionID,
            kind: .summaryLoaded,
            message: deferredFullHistoryNotice(sessionID: sessionID) ?? notice
        )
    }

    func scheduleSessionStateReconciliationAfterHistoryRefresh(_ session: AgentSession) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.reconcileSessionStateAfterHistoryRefresh(session)
        }
    }

    func reconcileSessionStateAfterHistoryRefresh(_ session: AgentSession) async {
        if session.isRunning {
            do {
                let client = try clientFactory()
                let response = try await client.session(id: session.id, afterSeq: logStore.lastSeq(for: session.id))
                let refreshed = self.session(response.session, in: workspaceForSession(session))
                upsert(refreshed)
                if !refreshed.isRunning {
                    clearForegroundActivity(sessionID: session.id)
                    clearRuntimeActivity(sessionID: session.id)
                }
                if let recentOutput = response.recentOutput, !recentOutput.isEmpty {
                    // recent_output 只作为诊断日志展示；对话内容以 app-server 结构化 history/event 为准。
                    logStore.append(recentOutput, sessionID: session.id, seq: response.lastSeq)
                }
            } catch {
                // 运行态快照读取失败时，后台静默用列表刷新重新同步 app-server 线程状态。
                await refreshSessionListQuietlyIfStillSelected(projectID: session.projectID)
            }
        } else {
            await refreshSessionListQuietlyIfStillSelected(projectID: session.projectID)
        }
    }

    func refreshSessionListQuietlyIfStillSelected(projectID: String) async {
        guard selectedProjectID == projectID else {
            return
        }
        await refreshSessions(
            forProjectID: projectID,
            showLoading: false,
            clearErrorOnSuccess: false,
            updateStatusMessage: false,
            reportErrorOnFailure: false
        )
    }

    func refreshSessions(
        forProjectID projectID: String,
        showLoading: Bool = true,
        clearErrorOnSuccess: Bool = true,
        updateStatusMessage: Bool = true,
        reportErrorOnFailure: Bool = true,
        reuseRecent: Bool? = nil,
        consistency: SessionListConsistency = .fastIndexed,
        activatesProject: Bool = true,
        foregroundLease: SessionSelectionLease? = nil
    ) async {
        let canReportForeground: () -> Bool = {
            foregroundLease.map(self.isSelectionLeaseCurrent) ?? true
        }
        var projectID = projectID
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            if canReportForeground() {
                setErrorMessage(L10n.text("ui.the_workspace_has_expired_please_reopen_it"))
            }
            return
        }
        projectID = workspace.id
        if activatesProject, selectedProjectID != projectID {
            setSelectedProjectID(projectID)
        }
        if showLoading {
            isLoading = true
        }
        defer {
            if showLoading {
                isLoading = false
            }
        }
        var requestToken: Int?
        let hostRequestStartedAt = sessionListNow()
        do {
            requestToken = beginSessionFirstPageRequest(
                projectID: projectID,
                consistency: consistency
            )
            defer { finishSessionFirstPageRequest(projectID: projectID, token: requestToken ?? 0) }
            let result = try await sessionListFirstPage(
                workspace: workspace,
                limit: Self.initialSessionPageLimit,
                reuseRecent: reuseRecent ?? !showLoading,
                consistency: consistency,
                source: .selectedProject
            )
            let page = result.page
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            guard !activatesProject || selectedProjectID == projectID else {
                return
            }
            // refreshSessions 是可见页面的周期 Host API；成功即续期在线证据，
            // 即使会话 payload 未变化，也允许 Widget 在 TTL 中点做有界 heartbeat。
            recordCarStatusHostObservation(at: sessionListNow())
            // 只替换当前项目的会话，避免一次项目点击误删其他项目已经加载好的列表。
            applyWorkspaceSessionFirstPage(
                workspace: workspace,
                page: page,
                consistency: consistency,
                requestedCursor: result.requestedCursor
            )
            if updateStatusMessage, canReportForeground() {
                setStatusMessage(L10n.plural("ui.sessions_loaded_count", count: filteredSessions.count))
            }
            // 手动刷新/切换工作区成功时可以清掉旧错误；发送后的后台刷新不能抢掉刚产生的发送失败提示。
            if clearErrorOnSuccess, canReportForeground() {
                setErrorMessage(nil)
            }
        } catch {
            if let requestToken, !isCurrentSessionPageRequest(projectID: projectID, token: requestToken) {
                return
            }
            if !isCancellationError(error) {
                if Self.carStatusHostDidRespond(to: error) {
                    recordCarStatusHostObservation(at: sessionListNow())
                } else {
                    // 只让当前请求淘汰不晚于自身的旧证据，避免并发迟到失败覆盖新成功。
                    invalidateCarStatusHostObservation(ifNotNewerThan: hostRequestStartedAt)
                }
            }
            if reportErrorOnFailure, selectedProjectID == projectID {
                await handleWorkspaceLoadFailure(
                    workspace: workspace,
                    error: error,
                    reportForeground: canReportForeground()
                )
            }
        }
    }

    func sessionLibraryPage(
        workspace: AgentWorkspace,
        consistency: SessionListConsistency = .fastIndexed,
        client: (any SessionStoreAPIClient)? = nil,
        hostScope: HostScope? = nil
    ) async -> (workspace: AgentWorkspace, page: SessionsPage?, requestedCursor: String?) {
        let hostRequestStartedAt = sessionListNow()
        do {
            let result = try await sessionListFirstPage(
                workspace: workspace,
                limit: Self.initialSessionPageLimit,
                reuseRecent: consistency == .fastIndexed,
                consistency: consistency,
                source: .libraryIndex,
                client: client,
                hostScope: hostScope
            )
            recordCarStatusHostObservation(at: sessionListNow())
            return (workspace, result.page, result.requestedCursor)
        } catch {
            if !isCancellationError(error) {
                if Self.carStatusHostDidRespond(to: error) {
                    recordCarStatusHostObservation(at: sessionListNow())
                } else {
                    invalidateCarStatusHostObservation(ifNotNewerThan: hostRequestStartedAt)
                }
            }
            // 某个最近工作区失效不能阻断整个会话库；该项目仍可在工作区页单独重试。
            return (workspace, nil, nil)
        }
    }

    func mergeSessionLibraryPages(
        _ results: [(workspace: AgentWorkspace, page: SessionsPage?, requestedCursor: String?)],
        generation: Int,
        consistency: SessionListConsistency = .fastIndexed
    ) {
        guard generation == appStore.connectionGeneration else { return }
        for result in results {
            guard let page = result.page,
                  isCurrentWorkspaceIdentity(result.workspace) else { continue }
            if consistency == .authoritative,
               authoritativeWorkspaceSessionFirstPageContinuationCursor(workspace: result.workspace)
                != result.requestedCursor {
                continue
            }
            let pageSessions = sessions(page.sessions, in: result.workspace)
            if consistency == .fastIndexed {
                mergeFastIndexedSessionPagePreservingAuthoritativeFields(
                    pageSessions,
                    workspace: result.workspace
                )
            } else {
                // 新一轮权威刷新必须能修正旧权威数据；只有弱一致性页需要降级保护。
                mergeSessionPage(pageSessions)
            }
            updateWorkspaceSessionFirstPageState(
                workspace: result.workspace,
                page: page,
                consistency: consistency,
                requestedCursor: result.requestedCursor
            )
            recordWorkspaceSessionFirstPageCompletion(
                workspace: result.workspace,
                page: page,
                consistency: consistency
            )
            clearWorkspaceUnavailable(result.workspace.id)
        }
    }

    func workspaceSessionFirstPageKey(
        for workspace: AgentWorkspace,
        hostScope: HostScope? = nil
    ) -> WorkspaceSessionFirstPageKey {
        WorkspaceSessionFirstPageKey(
            hostScope: hostScope ?? appStore.activeHostScope,
            workspaceID: workspace.id,
            workspacePath: standardizedSessionListPath(workspace.path)
        )
    }

    /// 任何跨 await 的工作区列表结果在提交前都要重新确认身份。
    /// 用户可能已经移除该工作区，或同一 ID 已迁移到另一路径；旧响应不能复活会话或完成态。
    func isCurrentWorkspaceIdentity(
        _ workspace: AgentWorkspace,
        hostScope expectedHostScope: HostScope? = nil
    ) -> Bool {
        if let expectedHostScope, appStore.activeHostScope != expectedHostScope {
            return false
        }
        guard let currentWorkspace = workspacesByID[workspace.id] else {
            return false
        }
        return standardizedSessionListPath(currentWorkspace.path)
            == standardizedSessionListPath(workspace.path)
    }

    func workspaceSessionFirstPageConsistency(projectID: String) -> SessionListConsistency? {
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            return nil
        }
        guard let completion = workspaceSessionFirstPageCompletionByKey[
            workspaceSessionFirstPageKey(for: workspace)
        ], completion.isPresentationWindowComplete else {
            return nil
        }
        return completion.consistency
    }

    func needsAuthoritativeWorkspaceSessionFirstPage(projectID: String) -> Bool {
        workspaceSessionFirstPageConsistency(projectID: projectID) != .authoritative
    }

    func authoritativeWorkspaceSessionFirstPageContinuationCursor(
        workspace: AgentWorkspace,
        hostScope: HostScope? = nil
    ) -> String? {
        let completion = workspaceSessionFirstPageCompletionByKey[
            workspaceSessionFirstPageKey(for: workspace, hostScope: hostScope)
        ]
        guard completion?.consistency == .authoritative,
              completion?.isPresentationWindowComplete == false else {
            return nil
        }
        return completion?.continuationCursor
    }

    func authoritativeWorkspaceSessionFirstPageProgress(
        workspace: AgentWorkspace,
        hostScope: HostScope? = nil
    ) -> WorkspaceSessionFirstPageCompletion? {
        let completion = workspaceSessionFirstPageCompletionByKey[
            workspaceSessionFirstPageKey(for: workspace, hostScope: hostScope)
        ]
        guard completion?.consistency == .authoritative,
              completion?.isPresentationWindowComplete == false,
              completion?.continuationCursor != nil else {
            return nil
        }
        return completion
    }

    func recordWorkspaceSessionFirstPageCompletion(
        workspace: AgentWorkspace,
        page: SessionsPage,
        consistency: SessionListConsistency
    ) {
        guard isCurrentWorkspaceIdentity(workspace) else { return }
        let hostScope = appStore.activeHostScope
        let key = workspaceSessionFirstPageKey(for: workspace, hostScope: hostScope)
        if let existingCompletion = workspaceSessionFirstPageCompletionByKey[key],
           existingCompletion.consistency == .authoritative,
           consistency == .fastIndexed {
            invalidateAuthoritativeWorkspaceSessionPresentationCompletionIfNeeded(
                workspace: workspace
            )
            return
        }
        let presentationWindowComplete = isWorkspaceSessionPresentationWindowComplete(
            workspace: workspace,
            page: page,
            limit: Self.initialSessionPageLimit
        )
        let continuationCursor = consistency == .authoritative && !presentationWindowComplete
            ? page.nextCursor
            : nil
        var seenSessionIDs = Set<SessionID>()
        let scannedSessionIDs = page.sessions.compactMap { session in
            seenSessionIDs.insert(session.id).inserted ? session.id : nil
        }
        let existingCompletion = workspaceSessionFirstPageCompletionByKey[key]
        let completion: WorkspaceSessionFirstPageCompletion
        if let existingCompletion,
           existingCompletion.consistency == consistency,
           existingCompletion.isPresentationWindowComplete == presentationWindowComplete,
           existingCompletion.continuationCursor == continuationCursor,
           existingCompletion.scannedSessionIDs == scannedSessionIDs {
            // completedAt 表示首次进入当前语义状态的时刻；相同结果不重写时间戳，
            // 也避免 @Published 在重复轮询时制造无意义的整页刷新。
            completion = existingCompletion
        } else {
            completion = WorkspaceSessionFirstPageCompletion(
                consistency: consistency,
                isPresentationWindowComplete: presentationWindowComplete,
                continuationCursor: continuationCursor,
                scannedSessionIDs: scannedSessionIDs,
                // cursor 推进仍属于同一个“欠填”语义状态，保留首次进入时间；
                // 但 completion 本身必须发布，让下一批和诊断观察到新的安全 continuation。
                completedAt: existingCompletion?.consistency == consistency
                    && existingCompletion?.isPresentationWindowComplete == presentationWindowComplete
                    ? existingCompletion?.completedAt ?? sessionListNow()
                    : sessionListNow()
            )
        }
        // 旧 generation 的结论永远不能再次命中；一次性构造并比较新字典，避免 filter 和
        // 下标写入分别发布，且相同 completion 不应触发 WorkspaceRoot 的观察更新。
        var nextCompletions = workspaceSessionFirstPageCompletionByKey.filter {
            $0.key.hostScope == hostScope
        }
        nextCompletions[key] = completion
        if nextCompletions != workspaceSessionFirstPageCompletionByKey {
            workspaceSessionFirstPageCompletionByKey = nextCompletions
        }
    }

    /// 弱一致性数据可以补认 child ownership，使已经完成的 20 条权威根会话窗口重新欠填。
    /// 只有仍有安全 continuation 时才失效；真正耗尽的短列表已经是完整展示结果，不应循环重拉。
    func invalidateAuthoritativeWorkspaceSessionPresentationCompletionIfNeeded(
        workspace: AgentWorkspace
    ) {
        guard isCurrentWorkspaceIdentity(workspace) else { return }
        let key = workspaceSessionFirstPageKey(for: workspace)
        guard let existingCompletion = workspaceSessionFirstPageCompletionByKey[key],
              existingCompletion.consistency == .authoritative,
              existingCompletion.isPresentationWindowComplete,
              sessionHasMoreByProjectID[workspace.id] == true,
              sessions(forProjectID: workspace.id).count < Self.initialSessionPageLimit
        else {
            return
        }
        workspaceSessionFirstPageCompletionByKey[key] = WorkspaceSessionFirstPageCompletion(
            consistency: .authoritative,
            isPresentationWindowComplete: false,
            continuationCursor: sessionPageCursorByProjectID[workspace.id],
            // late-child 只改变 sticky ownership；沿用原权威链实际扫描过的 ID，
            // 续跑时会从 sessionsByID 读取最新身份并把被补认的 child 从 root 计数中减掉。
            scannedSessionIDs: existingCompletion.scannedSessionIDs,
            completedAt: sessionListNow()
        )
    }

    func shouldProtectAuthoritativeWorkspaceSessionFirstPage(
        workspace: AgentWorkspace,
        incomingConsistency: SessionListConsistency
    ) -> Bool {
        incomingConsistency == .fastIndexed
            && workspaceSessionFirstPageCompletionByKey[
                workspaceSessionFirstPageKey(for: workspace)
            ]?.consistency == .authoritative
    }

    func updateWorkspaceSessionFirstPageState(
        workspace: AgentWorkspace,
        page: SessionsPage,
        consistency: SessionListConsistency,
        requestedCursor: String? = nil
    ) {
        guard isCurrentWorkspaceIdentity(workspace) else { return }
        guard !shouldProtectAuthoritativeWorkspaceSessionFirstPage(
            workspace: workspace,
            incomingConsistency: consistency
        ) else {
            // 弱一致性页可以补行和更新运行态，但不能重置权威首屏留下的 cursor 或已展开窗口。
            rebuildProjectSessionListSnapshot(forProjectID: workspace.id)
            return
        }
        let pageStateRequestedCursor: String?
        if let requestedCursor,
           !sessionProjectsWithAdditionalPages.contains(workspace.id)
            || sessionPageCursorByProjectID[workspace.id] == requestedCursor {
            // 未展开窗口可直接推进；已展开窗口只有在 authoritative continuation
            // 与当前 deep cursor 是同一条链时才推进，避免较浅 head-fill cursor 覆盖用户深层位置。
            pageStateRequestedCursor = requestedCursor
        } else {
            pageStateRequestedCursor = nil
        }
        updateSessionPageState(
            projectID: workspace.id,
            page: page,
            requestedCursor: pageStateRequestedCursor
        )
    }

    func isWorkspaceSessionPresentationWindowComplete(
        workspace: AgentWorkspace,
        page: SessionsPage,
        limit: Int
    ) -> Bool {
        guard page.hasMore else { return true }
        var listableIDs = Set<SessionID>()
        for rawSession in page.sessions {
            let session = sessionPreparedForStorage(self.session(rawSession, in: workspace))
            if isListableSession(session) {
                listableIDs.insert(session.id)
            }
        }
        return listableIDs.count >= max(1, limit)
    }

    @discardableResult
    func applyWorkspaceSessionFirstPage(
        workspace: AgentWorkspace,
        page: SessionsPage,
        consistency: SessionListConsistency,
        requestedCursor: String? = nil,
        preserveAllLoaded: Bool = false
    ) -> Bool {
        guard isCurrentWorkspaceIdentity(workspace) else { return false }
        if consistency == .authoritative,
           authoritativeWorkspaceSessionFirstPageContinuationCursor(workspace: workspace)
            != requestedCursor {
            // 同 cursor waiter 的旧结果允许首个提交者推进；其余 waiter 若观察到进度已改变，
            // 必须丢弃，不能把 completion 或 opaque cursor 倒回上一批。
            return false
        }
        let pageSessions = sessions(page.sessions, in: workspace)
        let presentationWindowComplete = isWorkspaceSessionPresentationWindowComplete(
            workspace: workspace,
            page: page,
            limit: Self.initialSessionPageLimit
        )
        if shouldProtectAuthoritativeWorkspaceSessionFirstPage(
            workspace: workspace,
            incomingConsistency: consistency
        ) {
            // authoritative 一旦完成，后续 State DB 稀疏页只能补新 ID 和单调线程身份；
            // 同 ID 的 title/status 等普通字段不能被迟到弱页覆盖。
            mergeFastIndexedSessionPagePreservingAuthoritativeFields(
                pageSessions,
                workspace: workspace
            )
        } else if !presentationWindowComplete {
            // 展示窗口欠填时保留旧可见行，只补充已扫描 canonical 数据；新 cursor 仍可继续推进。
            // fast waiter 可能共享到这张 authoritative 部分页，也必须沿用 merge-only，不能再次删旧根会话。
            mergeSessionPage(pageSessions)
        } else {
            replaceSessionsIfChanged(
                with: pageSessionsPreservingLoadedWindow(
                    pageSessions,
                    projectID: workspace.id,
                    preserveAllLoaded: preserveAllLoaded
                ),
                projectID: workspace.id
            )
        }
        updateWorkspaceSessionFirstPageState(
            workspace: workspace,
            page: page,
            consistency: consistency,
            requestedCursor: requestedCursor
        )
        recordWorkspaceSessionFirstPageCompletion(
            workspace: workspace,
            page: page,
            consistency: consistency
        )
        clearWorkspaceUnavailable(workspace.id)
        return true
    }

    func sessionListFirstPage(
        workspace: AgentWorkspace,
        limit: Int,
        reuseRecent: Bool,
        consistency: SessionListConsistency = .fastIndexed,
        source: SessionListRequestSource,
        client fixedClient: (any SessionStoreAPIClient)? = nil,
        hostScope expectedHostScope: HostScope? = nil
    ) async throws -> SessionListFirstPageResult {
        let requestStartedAt = sessionListNow()
        let hostScope = expectedHostScope ?? appStore.activeHostScope
        guard isCurrentWorkspaceIdentity(workspace, hostScope: hostScope) else {
            throw CancellationError()
        }
        let authoritativeProgress = consistency == .authoritative
            ? authoritativeWorkspaceSessionFirstPageProgress(
                workspace: workspace,
                hostScope: hostScope
            )
            : nil
        let requestedCursor = authoritativeProgress?.continuationCursor
        let key = SessionListFirstPageRequestKey(
            profileID: hostScope.profileID,
            connectionGeneration: Int(truncatingIfNeeded: hostScope.generation),
            workspaceID: workspace.id,
            workspacePath: workspace.path,
            limit: limit,
            consistency: consistency,
            cursor: requestedCursor
        )
        while true {
            // 手动刷新可以绕过短缓存，但同一时刻仍必须等待已存在的共享请求。
            if let inFlight = sessionListFirstPageInFlightByKey[key] {
                let page = try await inFlight.task.value
                SessionListDiagnostics.completed(
                    source: source,
                    consistency: consistency,
                    delivery: .sharedInFlight,
                    count: page.sessions.count,
                    duration: sessionListNow().timeIntervalSince(requestStartedAt)
                )
                return SessionListFirstPageResult(page: page, requestedCursor: key.cursor)
            }

            let matchesCurrentWorkspace: (SessionListFirstPageRequestKey) -> Bool = { candidate in
                candidate.profileID == key.profileID
                    && candidate.connectionGeneration == key.connectionGeneration
                    && candidate.workspaceID == key.workspaceID
                    && candidate.workspacePath == key.workspacePath
            }

            if consistency == .authoritative,
               let weakerInFlight = sessionListFirstPageInFlightByKey.first(where: { entry in
                   matchesCurrentWorkspace(entry.key)
                       && entry.key.consistency == .fastIndexed
               }) {
                // 冷启动的 fastIndexed 可能早于前台精确首屏。不能把弱结果冒充 authoritative，
                // 也不能并发再打一个 thread/list；先排空弱请求，再回到循环重新加入/创建精确 single-flight。
                // waiter 只按请求身份退休已经完成的旧 entry；即使旧 owner 稍后恢复，也不能误删同 key 的新请求。
                // 弱请求失败或取消时，只要当前 host/task 仍有效，前台 authoritative 仍必须继续真正请求一次。
                _ = try? await weakerInFlight.value.task.value
                retireSessionListFirstPageInFlight(
                    key: weakerInFlight.key,
                    id: weakerInFlight.value.id
                )
                guard isCurrentWorkspaceIdentity(workspace, hostScope: hostScope),
                      !Task.isCancelled else {
                    throw CancellationError()
                }
                continue
            }

            if consistency == .fastIndexed,
               let authoritativeContinuationInFlight = sessionListFirstPageInFlightByKey.first(where: { entry in
                   matchesCurrentWorkspace(entry.key)
                       && entry.key.consistency == .authoritative
                       && entry.key.cursor != key.cursor
               }) {
                // continuation page 不能冒充 fastIndexed 的 nil 首屏，但 gateway 同一工作区
                // 仍只允许一条 thread/list cursor 链：先排空权威续跑，再单独发弱首屏。
                _ = try? await authoritativeContinuationInFlight.value.task.value
                retireSessionListFirstPageInFlight(
                    key: authoritativeContinuationInFlight.key,
                    id: authoritativeContinuationInFlight.value.id
                )
                guard isCurrentWorkspaceIdentity(workspace, hostScope: hostScope),
                      !Task.isCancelled else {
                    throw CancellationError()
                }
                continue
            }

            // 会话库只需要 8 条时，可以复用同工作区正在执行的 20 条请求；反向复用会缩短主列表，不能做。
            // 后台快速刷新也可以等待更强的权威请求；权威刷新不能复用快速索引结果，否则会重新引入漏会话问题。
            if let largerInFlight = sessionListFirstPageInFlightByKey.first(where: { entry in
                matchesCurrentWorkspace(entry.key)
                    && entry.key.cursor == key.cursor
                    && (
                        entry.key.consistency == key.consistency
                            || (key.consistency == .fastIndexed && entry.key.consistency == .authoritative)
                    )
                    && entry.key.limit >= key.limit
            })?.value {
                let page = try await largerInFlight.task.value
                SessionListDiagnostics.completed(
                    source: source,
                    consistency: consistency,
                    delivery: .largerInFlight,
                    count: page.sessions.count,
                    duration: sessionListNow().timeIntervalSince(requestStartedAt)
                )
                return SessionListFirstPageResult(page: page, requestedCursor: key.cursor)
            }
            break
        }
        let now = sessionListNow()
        if reuseRecent,
           key.cursor == nil,
           let cached = sessionListFirstPageCacheByKey[key]
                ?? cachedSessionListEntry(workspace: workspace, minimumLimit: limit),
           now.timeIntervalSince(cached.loadedAt) < sessionListFirstPageCacheTTL {
            SessionListDiagnostics.completed(
                source: source,
                consistency: consistency,
                delivery: .cache,
                count: cached.page.sessions.count,
                duration: sessionListNow().timeIntervalSince(requestStartedAt)
            )
            return SessionListFirstPageResult(page: cached.page, requestedCursor: key.cursor)
        }

        if let cooldownDelay = sessionListCooldownDelayNanoseconds(for: workspace) {
            // 只有弱一致性后台轮询可以复用旧页。authoritative 必须等待窗口后真的请求；
            // 否则 fastIndexed 稀疏缓存会被调用方误记成“精确首屏已完成”。
            if consistency == .fastIndexed,
               let stale = cachedSessionListPage(workspace: workspace, minimumLimit: limit) {
                SessionListDiagnostics.completed(
                    source: source,
                    consistency: consistency,
                    delivery: .staleCache,
                    count: stale.sessions.count,
                    duration: sessionListNow().timeIntervalSince(requestStartedAt)
                )
                return SessionListFirstPageResult(page: stale, requestedCursor: key.cursor)
            }
            // 冷启动或精确刷新等待窗口并继续请求，保证首屏最终自动恢复。
            await sessionListSleep(cooldownDelay)
            guard isCurrentWorkspaceIdentity(workspace, hostScope: hostScope),
                  !Task.isCancelled else {
                throw CancellationError()
            }
        }

        let client = try fixedClient ?? clientFactory()
        // 续跑只带上当前权威链真正扫描过的 ID，不能把旧缓存或已经“显示更多”的旧页
        // 冒充权威种子；从 sessionsByID 重建可吸收迟到的 sticky child ownership。
        let presentationSeedSessions = authoritativeProgress?.scannedSessionIDs.compactMap {
            sessionsByID[$0]
        } ?? []
        let requestID = UUID()
        let task = Task {
            try await sessionListPageFillingPresentationWindow(
                client: client,
                workspace: workspace,
                runtimeProvider: "codex",
                cursor: requestedCursor,
                limit: limit,
                consistency: consistency,
                source: source,
                expectedHostScope: hostScope,
                initialSessions: presentationSeedSessions,
                fillsPresentationWindow: consistency == .authoritative
            )
        }
        sessionListFirstPageInFlightByKey[key] = SessionListFirstPageInFlight(
            id: requestID,
            task: task
        )
        do {
            let page = try await task.value
            retireSessionListFirstPageInFlight(key: key, id: requestID)
            guard isCurrentWorkspaceIdentity(workspace, hostScope: hostScope),
                  !Task.isCancelled else {
                throw CancellationError()
            }
            if key.cursor == nil,
               consistency != .authoritative
                || isWorkspaceSessionPresentationWindowComplete(
                    workspace: workspace,
                    page: page,
                    limit: limit
                ) {
                sessionListFirstPageCacheByKey[key] = SessionListFirstPageCacheEntry(
                    page: page,
                    loadedAt: sessionListNow()
                )
            }
            clearSessionListCooldown(for: workspace)
            SessionListDiagnostics.completed(
                source: source,
                consistency: consistency,
                delivery: .network,
                count: page.sessions.count,
                duration: sessionListNow().timeIntervalSince(requestStartedAt)
            )
            return SessionListFirstPageResult(page: page, requestedCursor: key.cursor)
        } catch {
            retireSessionListFirstPageInFlight(key: key, id: requestID)
            if let policyFailure = sessionListPolicyFailure(from: error) {
                registerSessionListCooldown(policyFailure, for: workspace)
            }
            throw error
        }
    }

    /// transport 的 limit 约束 raw rows；子 Agent 过滤仍可能让展示层不足一页。
    /// 精确首屏与“显示更多”必须沿 opaque cursor 补齐顶层会话，child 仍随 raw rows 进入 canonical Store。
    func sessionListPageFillingPresentationWindow(
        client: any SessionStoreAPIClient,
        workspace: AgentWorkspace,
        runtimeProvider: String,
        cursor initialCursor: String?,
        limit: Int,
        consistency: SessionListConsistency,
        source: SessionListRequestSource,
        expectedHostScope: HostScope,
        initialSessions: [AgentSession] = [],
        excludingListableSessionIDs: Set<SessionID> = [],
        fillsPresentationWindow: Bool = true,
        isRequestCurrent: (() -> Bool)? = nil
    ) async throws -> SessionsPage {
        let targetCount = max(1, limit)
        var requestedCursor = initialCursor
        var seenCursors = Set<String>()
        if let initialCursor {
            seenCursors.insert(initialCursor)
        }
        var collectedIndexBySessionID: [SessionID: Int] = [:]
        var listableSessionIDs = Set<SessionID>()
        var collectedSessions: [AgentSession] = []
        for rawSession in initialSessions {
            let session = sessionPreparedForStorage(self.session(rawSession, in: workspace))
            guard collectedIndexBySessionID[session.id] == nil else { continue }
            collectedIndexBySessionID[session.id] = collectedSessions.count
            collectedSessions.append(session)
            if isListableSession(session),
               !excludingListableSessionIDs.contains(session.id) {
                listableSessionIDs.insert(session.id)
            }
        }
        var pagesScanned = 0
        var lastPage = SessionsPage(sessions: [])

        while true {
            try Task.checkCancellation()
            guard isCurrentWorkspaceIdentity(workspace, hostScope: expectedHostScope) else {
                throw CancellationError()
            }
            guard isRequestCurrent?() != false else {
                throw CancellationError()
            }

            let remainingListable = max(1, targetCount - listableSessionIDs.count)
            let rawPageLimit = sessionPresentationFillRawPageLimit(
                remainingListable: remainingListable,
                observedRawCount: collectedSessions.count,
                observedListableCount: listableSessionIDs.count,
                fillsPresentationWindow: fillsPresentationWindow,
                allowsAdaptiveOversampling: consistency == .authoritative
            )
            let page = try await client.sessionsPage(
                workspace: workspace,
                runtimeProvider: runtimeProvider,
                cursor: requestedCursor,
                limit: rawPageLimit,
                consistency: consistency
            )
            try Task.checkCancellation()
            guard isCurrentWorkspaceIdentity(workspace, hostScope: expectedHostScope),
                  isRequestCurrent?() != false else {
                throw CancellationError()
            }
            pagesScanned += 1
            lastPage = page

            for rawSession in page.sessions {
                // 稀疏列表可能暂时丢 parent/source；先恢复 Store 已知的 sticky ownership，
                // 否则 child 会被误计成 root 并让 authoritative completion 提前成立。
                let session = sessionPreparedForStorage(self.session(rawSession, in: workspace))
                if let index = collectedIndexBySessionID[session.id] {
                    // later-wins 更新普通字段，但 child ownership 必须跨页单调保留。
                    let merged = sessionPreservingSubagentOwnership(
                        session,
                        withKnown: collectedSessions[index]
                    )
                    collectedSessions[index] = merged
                    if isListableSession(merged),
                       !excludingListableSessionIDs.contains(merged.id) {
                        listableSessionIDs.insert(merged.id)
                    } else {
                        listableSessionIDs.remove(merged.id)
                    }
                    continue
                }
                collectedIndexBySessionID[session.id] = collectedSessions.count
                collectedSessions.append(session)
                if isListableSession(session),
                   !excludingListableSessionIDs.contains(session.id) {
                    listableSessionIDs.insert(session.id)
                }
            }

            guard !page.hasMore || page.nextCursor != nil else {
                // has_more 没有 opaque continuation 无法安全推进，不能伪装成 exhausted。
                throw AgentAPIError.invalidResponse
            }
            guard fillsPresentationWindow,
                  listableSessionIDs.count < targetCount,
                  page.hasMore,
                  let nextCursor = page.nextCursor
            else {
                break
            }
            // cursor 不前进时不能把 transport 完成误记成 presentation 完成，也不能形成请求风暴。
            guard nextCursor != requestedCursor,
                  seenCursors.insert(nextCursor).inserted
            else {
                throw AgentAPIError.invalidResponse
            }
            guard pagesScanned < Self.maximumSessionPresentationFillPageCount else { break }
            requestedCursor = nextCursor
        }

        let hasMore = lastPage.hasMore && lastPage.nextCursor != nil
        SessionListDiagnostics.presentationWindowCompleted(
            source: source,
            consistency: consistency,
            rawCount: collectedSessions.count,
            listableCount: listableSessionIDs.count,
            pagesScanned: pagesScanned,
            hasMore: hasMore
        )
        return SessionsPage(
            sessions: collectedSessions,
            nextCursor: hasMore ? lastPage.nextCursor : nil,
            hasMore: hasMore
        )
    }

    /// 首次网络请求和 fastIndexed 路径保持调用方给定的小页；只有 authoritative 已经观察到
    /// child 稀释且仍欠填时，才按累计密度估算下一批 raw rows。额外取回的 root 留在 canonical Store
    /// 作为本地预取缓冲，工作区 View 仍用独立可见窗口原子展示 20 条。
    func sessionPresentationFillRawPageLimit(
        remainingListable: Int,
        observedRawCount: Int,
        observedListableCount: Int,
        fillsPresentationWindow: Bool,
        allowsAdaptiveOversampling: Bool
    ) -> Int {
        let remainingListable = max(1, remainingListable)
        guard fillsPresentationWindow,
              allowsAdaptiveOversampling,
              observedRawCount > 0 else {
            return min(remainingListable, Self.maximumSessionPresentationFillRawPageLimit)
        }

        // observedListableCount=0 时用 1 作为保守密度分母，结果会自然封顶 50，
        // 不因 child-only 页除零，也不会把非法的 60 发送给 Gateway。
        let estimatedRawCount = Int(ceil(
            Double(remainingListable) * Double(max(1, observedRawCount))
                / Double(max(1, observedListableCount))
        ))
        let estimateWithSafety = Int(ceil(
            Double(estimatedRawCount) * Double(Self.sessionPresentationFillEstimateSafetyNumerator)
                / Double(Self.sessionPresentationFillEstimateSafetyDenominator)
        ))
        return min(
            Self.maximumSessionPresentationFillRawPageLimit,
            max(Self.minimumSessionPresentationFillPageLimit, estimateWithSafety)
        )
    }

    /// owner 与 waiter 都只能退休自己观察到的那一代请求，避免旧 continuation 删除同 key 的新 in-flight。
    func retireSessionListFirstPageInFlight(
        key: SessionListFirstPageRequestKey,
        id: UUID
    ) {
        guard sessionListFirstPageInFlightByKey[key]?.id == id else { return }
        sessionListFirstPageInFlightByKey.removeValue(forKey: key)
    }

    func cachedSessionListPage(workspace: AgentWorkspace, minimumLimit: Int) -> SessionsPage? {
        cachedSessionListEntry(workspace: workspace, minimumLimit: minimumLimit)?.page
    }

    func cachedSessionListEntry(
        workspace: AgentWorkspace,
        minimumLimit: Int
    ) -> SessionListFirstPageCacheEntry? {
        sessionListFirstPageCacheByKey
            .filter { entry in
                entry.key.profileID == appStore.activeHostScope.profileID
                    && entry.key.connectionGeneration == appStore.connectionGeneration
                    && entry.key.workspaceID == workspace.id
                    && entry.key.workspacePath == workspace.path
                    && entry.key.cursor == nil
                    && entry.key.limit >= minimumLimit
            }
            .max { $0.value.loadedAt < $1.value.loadedAt }?
            .value
    }

    func sessionListBudgetKey(for workspace: AgentWorkspace) -> SessionListBudgetKey {
        let workspacePath = standardizedSessionListPath(workspace.path)
        let rootPath = workspace.rootProjectPath.map(standardizedSessionListPath)
        let cwd: String
        if let rootPath, remoteHostPath(workspacePath, isWithin: rootPath) {
            cwd = rootPath
        } else {
            cwd = workspacePath
        }
        return SessionListBudgetKey(
            profileID: appStore.activeHostScope.profileID,
            connectionGeneration: appStore.connectionGeneration,
            cwd: cwd
        )
    }

    func standardizedSessionListPath(_ rawPath: String) -> String {
        // 这是远端宿主路径。只清理传输层空白，避免把 `C:\...` 改写成 iOS 本机路径。
        rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sessionListCooldownDelayNanoseconds(for workspace: AgentWorkspace) -> UInt64? {
        let key = sessionListBudgetKey(for: workspace)
        guard let until = sessionListCooldownUntilByBudgetKey[key] else { return nil }
        let remaining = until.timeIntervalSince(sessionListNow())
        guard remaining > 0 else {
            sessionListCooldownUntilByBudgetKey.removeValue(forKey: key)
            return nil
        }
        return UInt64(ceil(remaining * 1_000_000_000))
    }

    func registerSessionListCooldown(_ failure: SessionListPolicyFailure, for workspace: AgentWorkspace) {
        let key = sessionListBudgetKey(for: workspace)
        let until = sessionListNow().addingTimeInterval(Double(failure.retryAfterNanoseconds) / 1_000_000_000)
        if let current = sessionListCooldownUntilByBudgetKey[key], current >= until {
            return
        }
        sessionListCooldownUntilByBudgetKey[key] = until
    }

    func clearSessionListCooldown(for workspace: AgentWorkspace) {
        sessionListCooldownUntilByBudgetKey.removeValue(forKey: sessionListBudgetKey(for: workspace))
    }

    func prepareSelectedSessionAfterRefresh(
        _ session: AgentSession,
        autoAttach: Bool,
        selectionLease: SessionSelectionLease
    ) async {
        guard isSelectionLeaseCurrent(selectionLease) else { return }
        if session.isLocalDraft {
            // 会话列表轮询可以保留选中的本地草稿，但绝不能为它读历史或建立订阅。
            disconnectWebSocket()
            return
        }
        await loadHistoryIfNeeded(for: session)
        guard isSelectionLeaseCurrent(selectionLease) else { return }
        if session.isRunning {
            if autoAttach && (canControlSession(session) || isProtocolReadOnlySession(session)) {
                // 前台恢复会反复走到这里；已加载会话的 loadHistoryIfNeeded 是 no-op，此时若做
                // 完整回放，backlog 里的旧卡会被追加到已合并的时间线后面。状态级回放已经
                // 覆盖 completed 内容，足够补齐离开期间的输出。
                connectWebSocket(session, replayBufferedEvents: false)
            } else if !canControlSession(session) {
                disconnectWebSocket()
            }
        } else if autoAttach {
            // 非运行会话回前台仍恢复页面连接。连接只读取持久化历史；发送时再由 gateway
            // 按当前 owner 建立写入路径，期间完成的输出由静默补拉兜底。
            connectWebSocket(session, replayBufferedEvents: false, allowNonRunning: true)
            scheduleQuietHistoryRefresh(for: session)
        } else if connectedSessionID != nil {
            disconnectWebSocket()
        }
    }

    func beginRecoveryHistoryGeneration() -> UInt64 {
        recoveryHistoryGeneration &+= 1
        return recoveryHistoryGeneration
    }

    /// App 回前台或网络恢复时，不能复用“签名没变化”的旧快照。Claude 自主 turn 可能在
    /// detached 期间完成，而 thread/list 的 revision 尚未及时更新；每个恢复代次必须绕过缓存
    /// 拉一次完整历史。成功后只需状态回放，失败时由调用方保留 full replay 兜底。
    func reconcileHistoryForRecovery(
        sessionID: SessionID,
        generation: UInt64
    ) async -> Bool {
        if reconciledRecoveryGenerationBySessionID[sessionID] == generation {
            // 必须返回本代请求结果，不能用旧 full snapshot 冒充本次成功。
            return recoveryHistorySucceededBySessionID[sessionID] == true
        }
        guard generation == recoveryHistoryGeneration,
              let session = sessionsByID[sessionID] else {
            return false
        }
        if session.isLocalDraft {
            reconciledRecoveryGenerationBySessionID[sessionID] = generation
            recoveryHistorySucceededBySessionID[sessionID] = true
            return true
        }
        let didLoad = await loadHistory(
            for: session,
            quiet: true,
            loadMode: .full,
            force: true,
            reason: .automatic,
            recoveryGeneration: generation
        )
        guard generation == recoveryHistoryGeneration else {
            return false
        }
        // full 因大小策略自动降级为 economy 时 loadHistory 仍会返回 true，但 summary
        // 不能证明 detached 期间的 assistant/process 内容已经完整对账，必须保留全量 replay。
        let didLoadFullHistory = didLoad && historyLoadedQualityBySessionID[sessionID] == .full
        reconciledRecoveryGenerationBySessionID[sessionID] = generation
        recoveryHistorySucceededBySessionID[sessionID] = didLoadFullHistory
        if didLoadFullHistory, let refreshed = sessionsByID[sessionID] {
            // 历史内容和 thread 状态是两个权威面；随后再校准一次状态，清除陈旧 running。
            await reconcileSessionStateAfterHistoryRefresh(refreshed)
        }
        return didLoadFullHistory
    }

    static func replacingSessions(_ current: [AgentSession], with fresh: [AgentSession], projectID: String?) -> [AgentSession] {
        SessionIndexStore.replacingSessions(current, with: fresh, projectID: projectID)
    }

    func replaceSessionsIfChanged(with fresh: [AgentSession], projectID: String?) {
        let nextFresh = fresh.map(sessionPreparedForStorage)
        let next = Self.replacingSessions(sessions, with: nextFresh, projectID: projectID)
        ingestSessionContexts(next)
        guard next != sessions else {
            return
        }
        sessions = next
    }

    func pageSessionsPreservingSelection(_ fresh: [AgentSession], projectID: String) -> [AgentSession] {
        var result = fresh
        var knownIDs = Set(fresh.map(\.id))

        if let selectedSessionID,
           let selected = sessionsByID[selectedSessionID],
           selected.projectID == projectID,
           !knownIDs.contains(selected.id),
           shouldRetainSessionMissingFromFreshPage(selected) {
            knownIDs.insert(selected.id)
            result.append(selected)
        }

        if let carSelection = selectedCarStatusSession,
           let selected = sessionsByID[carSelection.sessionID],
           selected.projectID == projectID,
           !knownIDs.contains(selected.id),
           shouldRetainSessionMissingFromFreshPage(selected) {
            result.append(selected)
        }

        // 分页首屏只取最近会话；用户正在查看或明确设为状态 Widget 的旧会话必须保留，
        // 否则前台刷新/清空远端搜索会让后续状态同步失去 canonical 数据源。
        return result
    }

    func pageSessionsPreservingLoadedWindow(
        _ fresh: [AgentSession],
        projectID: String,
        preserveAllLoaded: Bool = false
    ) -> [AgentSession] {
        acknowledgeRecentActivityProjections(in: fresh)
        let freshIDs = Set(fresh.map(\.id))
        recordRunningSessionsMissingFromFreshPage(freshIDs: freshIDs, projectID: projectID)
        var result = pageSessionsPreservingSelection(fresh, projectID: projectID)
        var knownIDs = Set(result.map(\.id))
        // 生命周期合并必须读取 canonical sessions；`sessions(forProjectID:)` 是顶层展示投影，
        // 已按 MIM-24 排除 child，不能用来决定 canonical 数据是否保留。
        let canonicalProjectSessions = canonicalSessions(forProjectID: projectID)
        let projectedSessions = canonicalProjectSessions.filter { session in
            guard recentActivityProjectionBySessionID[session.id] != nil,
                  shouldRetainSessionMissingFromFreshPage(session),
                  !knownIDs.contains(session.id) else {
                return false
            }
            knownIDs.insert(session.id)
            return true
        }
        // 新建/发送后的列表请求可能命中旧缓存或旧的 single-flight 响应；服务端列表确认前不能删掉本地最近项。
        result.append(contentsOf: projectedSessions)
        let knownRunningSessions = canonicalProjectSessions.filter { session in
            guard session.isRunning,
                  shouldRetainSessionMissingFromFreshPage(session),
                  !knownIDs.contains(session.id) else {
                return false
            }
            knownIDs.insert(session.id)
            return true
        }
        // thread/list 的索引可能短暂落后于实时事件：先短暂保留，连续缺失后用
        // thread/read 校准。读取也失败时最多保留 3 个刷新周期，不能形成永久幽灵运行态。
        result.append(contentsOf: knownRunningSessions)

        let knownChildSessions = canonicalProjectSessions.filter { session in
            guard session.isSubagentThread,
                  shouldRetainSessionMissingFromFreshPage(session),
                  !knownIDs.contains(session.id) else {
                return false
            }
            knownIDs.insert(session.id)
            return true
        }
        // workspace thread/list 可能不返回已通过父上下文进入的 child。顶层展示继续隐藏它，
        // 但刷新不能删除父子导航、历史与次级观察仍依赖的 canonical 记录。
        result.append(contentsOf: knownChildSessions)

        let controlledGlobalSessions = canonicalProjectSessions.filter { session in
            guard controlledGlobalSessionIDs.contains(session.id),
                  shouldRetainSessionMissingFromFreshPage(session),
                  !knownIDs.contains(session.id) else {
                return false
            }
            knownIDs.insert(session.id)
            return true
        }
        // 工作区 thread/list 只查询精确 cwd，不会返回同仓外部 Worktree。只保留本 Host
        // 已由 agentd 全局裁剪授权的 ID；下一次完整全局遍历会负责清除已消失项。
        result.append(contentsOf: controlledGlobalSessions)

        guard preserveAllLoaded
                || sessionProjectsWithAdditionalPages.contains(projectID)
                || isShowingAllSessions(projectID: projectID) else {
            return result
        }

        let olderLoadedSessions = canonicalProjectSessions.filter { session in
            guard shouldRetainSessionMissingFromFreshPage(session),
                  !knownIDs.contains(session.id) else {
                return false
            }
            knownIDs.insert(session.id)
            return true
        }
        guard !olderLoadedSessions.isEmpty else {
            return result
        }
        // 用户已经展开/翻页看到的旧会话属于本地分页窗口；后台首屏刷新只更新最新状态，
        // 不能把这些旧页踢掉，否则列表会在轮询后从“图二”回跳到“图一”。
        result.append(contentsOf: olderLoadedSessions)
        return result
    }

    func recordRunningSessionsMissingFromFreshPage(freshIDs: Set<SessionID>, projectID: String) {
        let runningSessions = canonicalSessions(forProjectID: projectID).filter(\.isRunning)
        let runningIDs = Set(runningSessions.map(\.id))

        // 当前页重新出现、或实时事件已把它改成终态时，连续缺失计数立即失效。
        let resolvedSessionIDs: [SessionID] = missingRunningSessionStateByID.compactMap { element in
            let (sessionID, state) = element
            guard state.projectID == projectID,
                  freshIDs.contains(sessionID) || !runningIDs.contains(sessionID) else {
                return nil
            }
            return sessionID
        }
        for sessionID in resolvedSessionIDs {
            missingRunningSessionStateByID.removeValue(forKey: sessionID)
        }

        for session in runningSessions where !freshIDs.contains(session.id) {
            let previous = missingRunningSessionStateByID[session.id]?.consecutiveRefreshMisses ?? 0
            let nextMisses = previous + 1
            missingRunningSessionStateByID[session.id] = MissingRunningSessionState(
                projectID: projectID,
                consecutiveRefreshMisses: nextMisses
            )
            if nextMisses >= Self.missingRunningSessionReadThreshold,
               nextMisses <= Self.maximumUnverifiedRunningSessionMisses {
                scheduleMissingRunningSessionReconciliation(session)
            }
        }
    }

    func canonicalSessions(forProjectID projectID: String) -> [AgentSession] {
        sessions.filter { $0.projectID == projectID }
    }

    func shouldRetainSessionMissingFromFreshPage(_ session: AgentSession) -> Bool {
        guard session.isRunning,
              let state = missingRunningSessionStateByID[session.id] else {
            return true
        }
        return state.consecutiveRefreshMisses <= Self.maximumUnverifiedRunningSessionMisses
            || missingRunningSessionReconciliationTasksByID[session.id] != nil
    }

    func scheduleMissingRunningSessionReconciliation(_ session: AgentSession) {
        guard missingRunningSessionReconciliationTasksByID[session.id] == nil else {
            return
        }
        let sessionID = session.id
        missingRunningSessionReconciliationTasksByID[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.missingRunningSessionReconciliationTasksByID.removeValue(forKey: sessionID)
            }
            do {
                let response = try await self.clientFactory().session(
                    id: sessionID,
                    afterSeq: self.logStore.lastSeq(for: sessionID)
                )
                try Task.checkCancellation()
                let refreshed = self.session(response.session, in: self.workspaceForSession(session))
                // thread/read 是这里的权威状态：无论仍在运行还是已经完成，都从新的事实重新计数。
                self.missingRunningSessionStateByID.removeValue(forKey: sessionID)
                self.upsert(refreshed)
                if !refreshed.isRunning {
                    self.clearForegroundActivity(sessionID: sessionID)
                    self.clearRuntimeActivity(sessionID: sessionID)
                }
            } catch is CancellationError {
                return
            } catch {
                // 读取失败不猜测终态；后续刷新还会再校准一次，但未验证状态最多只保留 3 个周期。
                return
            }
        }
    }

    func sessions(_ items: [AgentSession], in workspace: AgentWorkspace) -> [AgentSession] {
        items.map { session($0, in: workspace) }
    }

    func session(_ item: AgentSession, in workspace: AgentWorkspace?) -> AgentSession {
        guard let workspace else {
            return alignSessionToKnownWorkspace(item)
        }
        return AgentSession(
            id: item.id,
            projectID: workspace.id,
            project: workspace.name,
            dir: item.dir.isEmpty ? workspace.path : item.dir,
            title: item.title,
            status: item.status,
            source: item.source,
            runtimeProvider: item.runtimeProvider,
            resumeID: item.resumeID,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            recencyAt: item.recencyAt,
            preview: item.preview,
            activeTurnID: item.activeTurnID,
            lastSeq: item.lastSeq,
            revision: item.revision,
            usage: item.usage,
            rateLimit: item.rateLimit,
            pendingApproval: item.pendingApproval,
            pendingUserInput: item.pendingUserInput,
            goal: item.goal,
            appServerSessionID: item.appServerSessionID,
            parentThreadID: item.parentThreadID,
            isSubagent: item.isSubagent,
            agentNickname: item.agentNickname,
            agentRole: item.agentRole,
            canAcceptDirectInput: item.canAcceptDirectInput,
            context: item.context
        )
    }

    func alignSessionToKnownWorkspace(_ item: AgentSession) -> AgentSession {
        if let existing = sessionsByID[item.id],
           let workspace = workspacesByID[existing.projectID] {
            return session(item, in: workspace)
        }
        if let workspace = workspaceForPath(item.dir) {
            return session(item, in: workspace)
        }
        return item
    }

    func workspaceForSession(_ session: AgentSession) -> AgentWorkspace? {
        workspacesByID[session.projectID] ?? workspaceForPath(session.dir)
    }

    func workspaceForPath(_ rawPath: String) -> AgentWorkspace? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }
        return recentWorkspaces
            .filter { workspace in
                let workspacePath = workspace.path.trimmingCharacters(in: .whitespacesAndNewlines)
                return remoteHostPath(path, isWithin: workspacePath)
            }
            .max { lhs, rhs in
                remoteHostPathDepth(lhs.path) < remoteHostPathDepth(rhs.path)
            }
    }

    func remoteHostPath(_ path: String, isWithin root: String) -> Bool {
        guard !path.isEmpty, !root.isEmpty else {
            return false
        }
        guard path == root else {
            let separator: Character = root.contains("\\") ? "\\" : "/"
            let prefix = root.last == separator ? root : root + String(separator)
            return path.hasPrefix(prefix)
        }
        return true
    }

    func remoteHostPathDepth(_ path: String) -> Int {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).count
    }

    func mergeSessionPage(_ pageSessions: [AgentSession]) {
        guard !pageSessions.isEmpty else {
            return
        }
        let pageSessions = pageSessions.map(sessionPreparedForStorage)
        ingestSessionContexts(pageSessions)
        var next = sessions
        var indexByID = sessionIndexByID
        for session in pageSessions {
            if let index = indexByID[session.id], next.indices.contains(index) {
                next[index] = session
            } else {
                indexByID[session.id] = next.count
                next.append(session)
            }
        }
        guard next != sessions else {
            return
        }
        sessions = next
    }

    /// fastIndexed 可能晚于 authoritative 返回，或在翻页边界重复同一 ID。
    /// 已有权威行保留普通字段，只单调吸收线程身份；新 ID 仍按正常路径完整加入。
    func mergeFastIndexedSessionPagePreservingAuthoritativeFields(
        _ pageSessions: [AgentSession],
        workspace: AgentWorkspace
    ) {
        guard shouldProtectAuthoritativeWorkspaceSessionFirstPage(
            workspace: workspace,
            incomingConsistency: .fastIndexed
        ) else {
            mergeSessionPage(pageSessions)
            return
        }
        let qualitySafeSessions = pageSessions.map { incoming in
            guard let existing = sessionsByID[incoming.id] else {
                return incoming
            }
            return sessionPreservingSubagentOwnership(existing, withKnown: incoming)
        }
        mergeSessionPage(qualitySafeSessions)
    }

    func updateSessionPageState(
        projectID: String,
        page: SessionsPage,
        requestedCursor: String?
    ) {
        if requestedCursor == nil,
           sessionProjectsWithAdditionalPages.contains(projectID),
           sessionHasMoreByProjectID[projectID] != nil {
            // 用户已经把工作区翻到更深窗口后，轮询/网络恢复/手动刷新只负责合并最新首屏。
            // 若用首屏 cursor 覆盖深层 continuation，下一次“显示更多”会重复第二页；
            // exhausted 也必须保留，否则已消失的入口会被错误恢复。
            rebuildProjectSessionListSnapshot(forProjectID: projectID)
            return
        }
        if let cursor = page.nextCursor, page.hasMore {
            sessionPageCursorByProjectID[projectID] = cursor
            sessionHasMoreByProjectID[projectID] = true
        } else {
            sessionPageCursorByProjectID.removeValue(forKey: projectID)
            sessionHasMoreByProjectID[projectID] = false
        }
        rebuildProjectSessionListSnapshot(forProjectID: projectID)
    }

    func updateHistoryPageState(
        sessionID: SessionID,
        page: HistoryMessagesPage,
        preserveExistingCursorOnEmptyPage: Bool
    ) {
        recordHistorySnapshotSeq(page.snapshotSeq, sessionID: sessionID)
        if let cursor = page.previousCursor, page.hasMoreBefore {
            historyPreviousCursorBySessionID[sessionID] = cursor
            historyHasMoreBeforeBySessionID[sessionID] = true
        } else if preserveExistingCursorOnEmptyPage,
                  page.messages.isEmpty,
                  historyPreviousCursorBySessionID[sessionID] != nil {
            // resume/刷新首屏偶发空页时不要丢掉已有 older cursor。用户主动点“加载更早”
            // 的请求仍会传 false，让后端空页可以明确关闭分页入口。
            historyHasMoreBeforeBySessionID[sessionID] = true
        } else {
            historyPreviousCursorBySessionID.removeValue(forKey: sessionID)
            historyHasMoreBeforeBySessionID[sessionID] = false
        }
    }

    func setSessionListProjection(
        sessionID: SessionID,
        preview rawPreview: String,
        source: SessionListProjection.Source,
        clientMessageID: ClientMessageID?
    ) {
        let preview = rawPreview
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !preview.isEmpty else {
            return
        }

        let existingProjection = listProjectionBySessionID[sessionID]
        let existingSession = sessionsByID[sessionID]
        let projection = SessionListProjection(
            preview: preview,
            updatedAt: Date(),
            baseRemoteUpdatedAt: existingProjection?.baseRemoteUpdatedAt ?? existingSession?.updatedAt,
            basePreview: existingProjection?.basePreview ?? existingSession?.preview,
            source: source,
            clientMessageID: clientMessageID
        )
        listProjectionBySessionID[sessionID] = projection
        updateSession(sessionID) { item in
            item.preview = projection.preview
            item.updatedAt = projection.updatedAt
        }
        if source == .localUser {
            setSessionRecentActivityProjection(sessionID: sessionID, clientMessageID: clientMessageID)
        }
    }

    func clearSessionListProjection(sessionID: SessionID, clientMessageID: ClientMessageID?) {
        guard let projection = listProjectionBySessionID[sessionID] else {
            return
        }
        if let clientMessageID,
           let projectionClientID = projection.clientMessageID,
           projectionClientID != clientMessageID {
            return
        }
        listProjectionBySessionID.removeValue(forKey: sessionID)
        updateSession(sessionID) { item in
            item.preview = projection.basePreview
            item.updatedAt = projection.baseRemoteUpdatedAt ?? item.updatedAt
        }
    }

    func moveSessionListProjection(from sourceSessionID: SessionID, to targetSessionID: SessionID, clientMessageID: ClientMessageID?) {
        guard sourceSessionID != targetSessionID,
              let projection = listProjectionBySessionID[sourceSessionID]
        else {
            return
        }
        if let clientMessageID,
           let projectionClientID = projection.clientMessageID,
           projectionClientID != clientMessageID {
            return
        }
        listProjectionBySessionID.removeValue(forKey: sourceSessionID)
        let existing = sessionsByID[targetSessionID]
        listProjectionBySessionID[targetSessionID] = SessionListProjection(
            preview: projection.preview,
            updatedAt: projection.updatedAt,
            baseRemoteUpdatedAt: existing?.updatedAt,
            basePreview: existing?.preview,
            source: projection.source,
            clientMessageID: projection.clientMessageID
        )
        moveSessionRecentActivityProjection(
            from: sourceSessionID,
            to: targetSessionID,
            clientMessageID: clientMessageID
        )
    }

    func optimisticSessionID(
        projectID: String,
        resume: AgentSession?,
        clientMessageID: ClientMessageID?,
        prompt: String
    ) -> SessionID? {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let clientMessageID else {
            return nil
        }
        if let resume {
            return resume.id
        }
        return "local:\(projectID):\(clientMessageID)"
    }

    @discardableResult
    func createLocalDraftSession(
        projectID: String,
        runtimeProvider: String?,
        ifCurrent selectionIntent: SessionSelectionLease
    ) -> Bool {
        guard isSelectionLeaseCurrent(selectionIntent) else {
            return false
        }
        // 单窗口只保留一个尚未发送的草稿。切换工作区或再次点击新建时直接丢弃旧草稿，
        // 避免侧栏积累永远无法从服务端恢复的 local:* 项。
        discardLocalDraftSessions()
        let draft = makeLocalDraftSession(
            id: "local:\(projectID):\(UUID().uuidString)",
            projectID: projectID,
            runtimeProvider: runtimeProvider
        )
        upsert(draft)
        setSessionRecentActivityProjection(sessionID: draft.id, clientMessageID: nil)
        guard commitSelection(
            projectID: projectID,
            sessionID: draft.id,
            reason: .userOpen,
            ifCurrent: selectionIntent
        ) != nil else {
            discardLocalDraft(draft)
            return false
        }
        insertExpandedProjectID(projectID)
        disconnectWebSocket()
        setStatusMessage(L10n.text("ui.session_started"))
        setErrorMessage(nil)
        return true
    }

    func makeLocalDraftSession(id: SessionID, projectID: String, runtimeProvider: String?) -> AgentSession {
        let project = sidebarProjectsByID[projectID] ?? projectsByID[projectID]
        return AgentSession(
            id: id,
            projectID: projectID,
            project: project?.name ?? projectID,
            dir: project?.path ?? "",
            title: L10n.text("ui.new_session"),
            status: "draft",
            source: Self.optimisticSessionSource,
            runtimeProvider: runtimeProvider,
            resumeID: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func makeOptimisticSession(id: SessionID, projectID: String, prompt: String, runtimeProvider: String?) -> AgentSession {
        let project = sidebarProjectsByID[projectID] ?? projectsByID[projectID]
        let title = Self.promptTitle(prompt)
        return AgentSession(
            id: id,
            projectID: projectID,
            project: project?.name ?? projectID,
            dir: project?.path ?? "",
            title: title,
            status: "running",
            source: Self.optimisticSessionSource,
            runtimeProvider: runtimeProvider,
            resumeID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            preview: prompt
        )
    }

    func discardLocalDraftSessions(except retainedSessionID: SessionID? = nil) {
        let drafts = sessions.filter { $0.isLocalDraft && $0.id != retainedSessionID }
        for draft in drafts {
            discardLocalDraft(draft)
        }
    }

    func discardLocalDraft(_ draft: AgentSession) {
        guard draft.isLocalDraft else {
            return
        }
        conversationStore.reset(sessionID: draft.id)
        logStore.reset(sessionID: draft.id)
        removeSession(draft.id)
    }

    func removeSession(_ id: SessionID) {
        guard let index = sessionIndexByID[id] else {
            return
        }
        var next = sessions
        next.remove(at: index)
        sessions = next
        listProjectionBySessionID.removeValue(forKey: id)
        recentActivityProjectionBySessionID.removeValue(forKey: id)
        clearRuntimeActivity(sessionID: id)
    }

    func migrateForegroundActivity(from sourceSessionID: SessionID, to targetSessionID: SessionID) {
        guard sourceSessionID != targetSessionID,
              let activity = foregroundActivityBySessionID[sourceSessionID] else {
            return
        }
        foregroundActivityBySessionID.removeValue(forKey: sourceSessionID)
        foregroundActivityBySessionID[targetSessionID] = activity
        foregroundActivityClearTasks[targetSessionID]?.cancel()
        foregroundActivityClearTasks[targetSessionID] = foregroundActivityClearTasks.removeValue(forKey: sourceSessionID)
    }

    func migrateRuntimeActivity(from sourceSessionID: SessionID, to targetSessionID: SessionID) {
        guard sourceSessionID != targetSessionID,
              let activity = runtimeActivityBySessionID[sourceSessionID] else {
            return
        }
        runtimeActivityBySessionID.removeValue(forKey: sourceSessionID)
        runtimeActivityBySessionID[targetSessionID] = activity
    }

    // 会话列表请求是按 project 并发的：用户快速切项目、刷新、展开加载更多时，
    // 旧响应可能晚于新响应返回。每次请求递增 token，落库前只接受当前 token。
    func beginSessionPageRequest(projectID: String) -> Int {
        // 普通分页会取代正在等待的首屏提交权；旧 waiter 的 defer 看到新 token 后只做 no-op。
        sessionFirstPageLoadingConsistencyByProjectID.removeValue(forKey: projectID)
        sessionFirstPageWaiterCountByProjectID.removeValue(forKey: projectID)
        let token = (sessionPageRequestTokenByProjectID[projectID] ?? 0) + 1
        sessionPageRequestTokenByProjectID[projectID] = token
        sessionPageLoadingTokenByProjectID[projectID] = token
        rebuildProjectSessionListSnapshot(forProjectID: projectID)
        return token
    }

    /// 相同首屏请求共享提交 token；fastIndexed 在前时，后到的 authoritative 只提升一致性、不换 token。
    /// 网络 single-flight 负责串行升级 RPC；这里保证任一 waiter 都不会仅因启动顺序失去提交权。
    func beginSessionFirstPageRequest(
        projectID: String,
        consistency: SessionListConsistency
    ) -> Int {
        if let token = sessionPageLoadingTokenByProjectID[projectID],
           let activeConsistency = sessionFirstPageLoadingConsistencyByProjectID[projectID] {
            // 提交权只允许从 fastIndexed 单调提升为 authoritative。提升时沿用 token，
            // 让先开始的弱请求可以结束，但不能因后来的精确 waiter 把两边结果都判成过期。
            if activeConsistency == .fastIndexed, consistency == .authoritative {
                sessionFirstPageLoadingConsistencyByProjectID[projectID] = .authoritative
            }
            sessionFirstPageWaiterCountByProjectID[projectID, default: 0] += 1
            return token
        }
        let token = beginSessionPageRequest(projectID: projectID)
        sessionFirstPageLoadingConsistencyByProjectID[projectID] = consistency
        sessionFirstPageWaiterCountByProjectID[projectID] = 1
        return token
    }

    func finishSessionPageRequest(projectID: String, token: Int) {
        guard sessionPageLoadingTokenByProjectID[projectID] == token else {
            return
        }
        sessionPageLoadingTokenByProjectID.removeValue(forKey: projectID)
        rebuildProjectSessionListSnapshot(forProjectID: projectID)
    }

    func finishSessionFirstPageRequest(projectID: String, token: Int) {
        guard sessionPageLoadingTokenByProjectID[projectID] == token else {
            return
        }
        let waiterCount = sessionFirstPageWaiterCountByProjectID[projectID] ?? 1
        guard waiterCount <= 1 else {
            sessionFirstPageWaiterCountByProjectID[projectID] = waiterCount - 1
            return
        }
        sessionFirstPageLoadingConsistencyByProjectID.removeValue(forKey: projectID)
        sessionFirstPageWaiterCountByProjectID.removeValue(forKey: projectID)
        finishSessionPageRequest(projectID: projectID, token: token)
    }

    func isCurrentSessionPageRequest(projectID: String, token: Int) -> Bool {
        sessionPageRequestTokenByProjectID[projectID] == token
    }

    func beginHistoryLoadJob(sessionID: SessionID) -> Int {
        let token = (historyLoadJobTokenBySessionID[sessionID] ?? 0) + 1
        historyLoadJobTokenBySessionID[sessionID] = token
        return token
    }

    // 历史首屏也会并发触发：点选历史、前台恢复、手动刷新都可能同时请求 before=nil。
    // 只接受最新 token，避免旧 rollout 快照晚到后覆盖较新的消息投影和分页 cursor。
    func beginHistoryPageRequest(sessionID: SessionID) -> Int {
        let token = (historyPageRequestTokenBySessionID[sessionID] ?? 0) + 1
        historyPageRequestTokenBySessionID[sessionID] = token
        return token
    }

    func isCurrentHistoryPageRequest(sessionID: SessionID, token: Int) -> Bool {
        historyPageRequestTokenBySessionID[sessionID] == token
    }

    func rebuildProjectIndex() {
        var byID: [String: AgentProject] = [:]
        byID.reserveCapacity(projects.count)
        for project in projects {
            byID[project.id] = project
        }
        projectsByID = byID
    }

    func rebuildWorkspaceIndex() {
        var byID: [String: AgentWorkspace] = [:]
        byID.reserveCapacity(recentWorkspaces.count)
        for workspace in recentWorkspaces {
            byID[workspace.id] = workspace
        }
        workspacesByID = byID
        setSidebarProjectsIfChanged(recentWorkspaces.map(\.project))
    }

    func rebuildSessionIndexes() {
        var byID: [SessionID: AgentSession] = [:]
        var indexByID: [SessionID: Int] = [:]
        byID.reserveCapacity(sessions.count)
        indexByID.reserveCapacity(sessions.count)
        for (index, session) in sessions.enumerated() {
            byID[session.id] = session
            indexByID[session.id] = index
        }
        sessionsByID = byID
        sessionIndexByID = indexByID
        synchronizeHistoryReadStates()
        pruneSessionScopedState(validSessionIDs: Set(byID.keys))

        // 和 Codex/Litter 的 snapshot 思路一致：Store 在数据变更时生成排序/分组投影，
        // SwiftUI 列表渲染时只读取缓存，避免每个项目行反复 filter + sort。
        let listableSessions = sessions.filter(isListableSession)
        let sorted = sortedSessionsForList(listableSessions)
        // Codex 与 Claude 的分页结果可能分批写入；全局和工作区列表都必须重新按同一活动时间排序。
        // recencyAt 已隔离 Agent 后台输出噪声，因此不再因任一运行态冻结整张列表。
        sortedAllSessions = sorted

        var grouped: [String: [AgentSession]] = [:]
        grouped.reserveCapacity(sidebarProjects.count)
        for session in sorted {
            grouped[session.projectID, default: []].append(session)
        }
        sortedSessionsByProjectID = grouped

        var previews: [String: [AgentSession]] = [:]
        var hiddenCounts: [String: Int] = [:]
        previews.reserveCapacity(grouped.count)
        hiddenCounts.reserveCapacity(grouped.count)
        for (projectID, projectSessions) in grouped {
            let visibleSessions = sessionsIncludingDerivedReadOnlySupplements(
                base: Self.lifecycleVisibleSessions(
                    projectSessions,
                    limit: Self.sessionPreviewLimit
                ),
                candidates: projectSessions
            )
            let hiddenCount = max(0, projectSessions.count - visibleSessions.count)
            hiddenCounts[projectID] = hiddenCount
            // 侧栏每次 body 计算都会读取可见会话。像 Litter 的派生模型一样提前保存预览窗口，
            // 避免多个项目行在刷新时重复构造 prefix 数组。
            previews[projectID] = visibleSessions
        }
        previewSessionsByProjectID = previews
        hiddenSessionCountByProjectID = hiddenCounts
        rebuildProjectSessionListSnapshots()
    }

    func makeProjectSessionListSnapshot(forProjectID projectID: String) -> ProjectSessionListSnapshot {
        let baseSessions = sortedSessionsByProjectID[projectID] ?? []
        if isSessionSearchActive {
            let matchingSessions = sessionsMatchingSearch(sessionsIncludingRemoteSearch(baseSessions, projectID: projectID))
            return ProjectSessionListSnapshot(
                projectID: projectID,
                isExpanded: true,
                isShowingAll: true,
                visibleSessions: matchingSessions,
                allSessionCount: matchingSessions.count,
                hiddenCount: 0,
                canLoadMore: false,
                isLoadingMore: false,
                hasCollapsedPreview: false
            )
        }

        let allSessions = baseSessions
        let visibleLimit = sessionVisibleLimit(forProjectID: projectID)
        let visibleSessions = sessionsIncludingDerivedReadOnlySupplements(
            base: Self.lifecycleVisibleSessions(allSessions, limit: visibleLimit),
            candidates: allSessions
        )
        let isShowingAll = visibleLimit > Self.sessionPreviewLimit

        return ProjectSessionListSnapshot(
            projectID: projectID,
            isExpanded: expandedProjectIDs.contains(projectID),
            isShowingAll: isShowingAll,
            visibleSessions: visibleSessions,
            allSessionCount: allSessions.count,
            hiddenCount: max(0, allSessions.count - visibleSessions.count),
            canLoadMore: canLoadMoreSessions(projectID: projectID),
            isLoadingMore: sessionPageLoadingTokenByProjectID[projectID] != nil,
            hasCollapsedPreview: allSessions.count > Self.sessionPreviewLimit
        )
    }

    /// 项目折叠时仍要完整保留运行态；历史会话只负责填满剩余预览位。
    /// 这样即使排序被冻结、运行任务不在前三条，也不会被“显示更多”折叠掉。
    static func lifecycleVisibleSessions(
        _ sessions: [AgentSession],
        limit: Int
    ) -> [AgentSession] {
        let normalizedLimit = max(0, limit)
        guard sessions.count > normalizedLimit else {
            return sessions
        }
        let active = sessions.filter(\.isRunning)
        guard !active.isEmpty else {
            return Array(sessions.prefix(normalizedLimit))
        }
        let historyLimit = max(0, normalizedLimit - active.count)
        return active + Array(sessions.lazy.filter { !$0.isRunning }.prefix(historyLimit))
    }

    /// 项目预览和根侧栏共用同一个有界补充规则。完整保留原窗口及其顺序，再追加最多
    /// 3 条派生只读历史；项目窗口特意把运行会话放在最前，不能用全量时间排序破坏它。
    /// candidates 已使用稳定 recencyAt 排序，因此补充行不会读取 Agent 持续推进的
    /// updatedAt 让 MIM-57 的列表再次跳动。
    func sessionsIncludingDerivedReadOnlySupplements(
        base: [AgentSession],
        candidates: [AgentSession]
    ) -> [AgentSession] {
        var visibleByID: [SessionID: AgentSession] = [:]
        visibleByID.reserveCapacity(base.count + Self.derivedReadOnlyHistorySupplementLimit)
        for session in base {
            visibleByID[session.id] = session
        }

        let supplements = candidates.lazy
            .filter {
                !$0.isRunning
                    && !$0.isLocalDraft
                    && self.isControlledGlobalDerivedReadOnlySession($0)
            }
            .prefix(Self.derivedReadOnlyHistorySupplementLimit)
        var result = base
        result.reserveCapacity(base.count + Self.derivedReadOnlyHistorySupplementLimit)
        for session in supplements where visibleByID[session.id] == nil {
            visibleByID[session.id] = session
            result.append(session)
        }
        return result
    }

    func rebuildProjectSessionListSnapshot(forProjectID projectID: String) {
        let snapshot = makeProjectSessionListSnapshot(forProjectID: projectID)
        sessionListSnapshotsByProjectID[projectID] = snapshot
    }

    func rebuildProjectSessionListSnapshots() {
        var projectIDs: Set<String> = []
        projectIDs.reserveCapacity(sidebarProjects.count + sortedSessionsByProjectID.count)
        for project in sidebarProjects {
            projectIDs.insert(project.id)
        }
        projectIDs.formUnion(sortedSessionsByProjectID.keys)
        projectIDs.formUnion(expandedProjectIDs)
        projectIDs.formUnion(showingAllSessionProjectIDs)
        projectIDs.formUnion(sessionHasMoreByProjectID.keys)
        projectIDs.formUnion(sessionPageLoadingTokenByProjectID.keys)

        var snapshots: [String: ProjectSessionListSnapshot] = [:]
        snapshots.reserveCapacity(projectIDs.count)
        for projectID in projectIDs {
            snapshots[projectID] = makeProjectSessionListSnapshot(forProjectID: projectID)
        }
        sessionListSnapshotsByProjectID = snapshots
    }

    var normalizedSessionSearchQuery: String {
        Self.normalizedSearchText(sessionSearchQuery)
    }

    func scheduleRemoteSessionSearch() {
        sessionSearchTask?.cancel()
        sessionSearchTask = nil
        sessionSearchGeneration &+= 1
        let generation = sessionSearchGeneration
        let connectionGeneration = appStore.connectionGeneration
        let searchTerm = sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // 每个关键词只保留自身的远端投影，避免连续搜索让基础会话库永久膨胀；用户点开后
        // selectSession 会通过既有 upsert 路径正式加入 sessions，因此不会破坏选择状态。
        resetRemoteSessionSearchState()

        // 空查询只恢复本地已加载列表，不发请求，也不删除之前搜索补入的会话缓存。
        guard !searchTerm.isEmpty,
              !isNetworkUnavailable,
              connectionTermination == nil
        else {
            return
        }

        isSearchingRemoteSessionResults = true
        sessionSearchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // 旧查询的 defer 不能清掉新查询从防抖阶段开始展示的 loading。
                if self.sessionSearchGeneration == generation {
                    self.sessionSearchTask = nil
                    self.isSearchingRemoteSessionResults = false
                }
            }
            do {
                if self.sessionSearchDebounceNanoseconds > 0 {
                    try await self.sessionSearchSleep(self.sessionSearchDebounceNanoseconds)
                }
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.sessionSearchGeneration == generation,
                  self.appStore.connectionGeneration == connectionGeneration,
                  !self.isNetworkUnavailable,
                  self.connectionTermination == nil
            else {
                return
            }

            do {
                let client = try self.clientFactory()
                let page = try await client.searchSessions(query: searchTerm, cursor: nil, limit: 50)
                // 部分 transport 在取消后仍可能交付已完成响应；generation 是最终防线，禁止旧查询污染新结果。
                guard !Task.isCancelled,
                      self.sessionSearchGeneration == generation,
                      self.appStore.connectionGeneration == connectionGeneration,
                      self.sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == searchTerm,
                      !self.isNetworkUnavailable,
                      self.connectionTermination == nil
                else {
                    return
                }
                self.applyRemoteSessionSearchPage(page, replacing: true, requestedCursor: nil)
            } catch {
                // 搜索属于列表增强：旧服务 method unavailable、弱网或临时鉴权失败都只回退本地过滤，
                // 不能把普通搜索失败升级成全局连接/鉴权终态。
            }
        }
    }

    func resetRemoteSessionSearchState() {
        sessionSearchLoadMoreTask?.cancel()
        sessionSearchLoadMoreTask = nil
        sessionSearchLoadingCursor = nil
        remoteSessionSearchSnippetByID = [:]
        remoteSessionSearchResults = []
        sessionSearchNextCursor = nil
        sessionSearchHasMore = false
        isSearchingRemoteSessionResults = false
        isLoadingMoreSessionSearchResults = false
    }

    func cancelRemoteSessionSearchRequestsPreservingResults() {
        sessionSearchTask?.cancel()
        sessionSearchTask = nil
        sessionSearchLoadMoreTask?.cancel()
        sessionSearchLoadMoreTask = nil
        sessionSearchGeneration &+= 1
        sessionSearchLoadingCursor = nil
        isSearchingRemoteSessionResults = false
        isLoadingMoreSessionSearchResults = false
    }

    func applyRemoteSessionSearchPage(
        _ page: ThreadSearchPage,
        replacing: Bool,
        requestedCursor: String?
    ) {
        var sessionsByID: [SessionID: AgentSession] = [:]
        var snippetsByID: [SessionID: String] = replacing ? [:] : remoteSessionSearchSnippetByID
        if !replacing {
            for session in remoteSessionSearchResults {
                sessionsByID[session.id] = session
            }
        }

        for result in page.results {
            let alignedSession = alignSessionToKnownWorkspace(result.session)
            sessionsByID[alignedSession.id] = alignedSession
            let snippet = result.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.isEmpty {
                snippetsByID.removeValue(forKey: alignedSession.id)
            } else {
                // 后续页若重复返回同一 thread，以新 snippet 为准；canonical sessions 始终不参与写入。
                snippetsByID[alignedSession.id] = snippet
            }
        }

        remoteSessionSearchSnippetByID = snippetsByID
        remoteSessionSearchResults = Self.sortedSessions(Array(sessionsByID.values))

        let nextCursor = page.nextCursor.flatMap { cursor in
            cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cursor
        }
        let canContinue = nextCursor != nil && nextCursor != requestedCursor
        sessionSearchNextCursor = canContinue ? nextCursor : nil
        sessionSearchHasMore = canContinue
    }

    func sessionsIncludingRemoteSearch(
        _ base: [AgentSession],
        projectID: String? = nil
    ) -> [AgentSession] {
        guard isSessionSearchActive, !remoteSessionSearchResults.isEmpty else {
            return base
        }
        let remote = remoteSessionSearchResults.filter { session in
            // 远端搜索结果不会经过 canonical sessions 的列表索引；必须在合并投影时
            // 再走一次统一谓词，避免 child Thread 通过搜索重新出现在顶层列表。
            isListableSession(session)
                && (projectID == nil || session.projectID == projectID)
        }
        guard !remote.isEmpty else {
            return base
        }
        // 同一 ID 保留基础会话的权威状态/preview；snippet 单独展示，不能因一次搜索覆盖 canonical session。
        var combined = base
        let baseIDs = Set(base.map(\.id))
        combined.append(contentsOf: remote.filter { !baseIDs.contains($0.id) })
        return Self.sortedSessions(combined)
    }

    func sessionsMatchingSearch(_ items: [AgentSession]) -> [AgentSession] {
        let query = normalizedSessionSearchQuery
        guard !query.isEmpty else {
            return items
        }
        // 搜索只作用于已加载会话投影，不改原始 sessions；这样清空搜索后能恢复分页、冻结顺序和选择状态。
        let remoteResultIDs = Set(remoteSessionSearchResults.map(\.id))
        // Codex 可能按 token/FTS 命中，snippet 不保证包含完整连续查询；远端结果应视为已经命中，
        // 这里只对普通本地会话继续做 literal contains 过滤。
        return items.filter { remoteResultIDs.contains($0.id) || sessionMatchesSearch($0, query: query) }
    }

    func sessionMatchesSearch(_ session: AgentSession, query: String) -> Bool {
        [
            session.title,
            session.preview,
            session.project,
            session.dir,
            session.displayStatusText,
            session.id,
            session.resumeID
        ].contains { value in
            Self.normalizedSearchText(value ?? "").contains(query)
        }
    }

    func isListableSession(_ session: AgentSession) -> Bool {
        // canonical sessions 仍保留 child，供父子导航、历史和实时观察使用；
        // 只有顶层 presentation 排除 child，避免同一父会话的派生 Thread 被平铺成重复会话。
        !session.isSubagentThread
            && (!archivedSessionIDs.contains(session.id) || session.id == selectedSessionID || session.isRunning)
    }

    /// 只用于根侧栏的有界展示优先级，不参与授权、父子关系或输入权限判断。
    /// `<codex_delegation>` 是 Codex Desktop 独立派生 Thread 的兼容提示；必须同时满足
    /// agentd 受控全局授权、Codex runtime 与协议只读，不能单凭用户可伪造的 preview 提权。
    func isControlledGlobalDerivedReadOnlySession(_ session: AgentSession) -> Bool {
        guard !session.isSubagentThread,
              controlledGlobalSessionIDs.contains(session.id),
              Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == "codex",
              !session.allowsDirectInput else {
            return false
        }

        let preview = session.preview?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return preview.hasPrefix("<codex_delegation>")
    }

    func projectMatchesSearch(_ project: AgentProject) -> Bool {
        let query = normalizedSessionSearchQuery
        guard !query.isEmpty else {
            return true
        }
        return [
            project.name,
            project.path,
            project.id
        ].contains { value in
            Self.normalizedSearchText(value).contains(query)
        }
    }

    static func normalizedSearchText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    func pruneSessionScopedState(validSessionIDs: Set<SessionID>) {
        // 会话分页只保留当前已知列表和被选中保留的 session；旧 session 的 cursor/token/activity
        // 继续留在字典里没有业务价值，长时间浏览大量历史时还会慢慢堆内存。
        historyPreviousCursorBySessionID = historyPreviousCursorBySessionID.filter { validSessionIDs.contains($0.key) }
        historyHasMoreBeforeBySessionID = historyHasMoreBeforeBySessionID.filter { validSessionIDs.contains($0.key) }
        historySnapshotSeqBySessionID = historySnapshotSeqBySessionID.filter { validSessionIDs.contains($0.key) }
        historyPageRequestTokenBySessionID = historyPageRequestTokenBySessionID.filter { validSessionIDs.contains($0.key) }
        historyLoadProgressBySessionID = historyLoadProgressBySessionID.filter { validSessionIDs.contains($0.key) }
        let staleHistoryLoadJobIDs = historyLoadJobsBySessionID.keys.filter { !validSessionIDs.contains($0) }
        for sessionID in staleHistoryLoadJobIDs {
            historyLoadJobsBySessionID[sessionID]?.task.cancel()
            historyLoadJobsBySessionID.removeValue(forKey: sessionID)
        }
        historyLoadJobTokenBySessionID = historyLoadJobTokenBySessionID.filter { validSessionIDs.contains($0.key) }
        historyLoadedSignatureBySessionID = historyLoadedSignatureBySessionID.filter { validSessionIDs.contains($0.key) }
        historyLoadedQualityBySessionID = historyLoadedQualityBySessionID.filter { validSessionIDs.contains($0.key) }
        let staleItemEnrichmentIDs = historyItemEnrichmentBySessionID.keys.filter { !validSessionIDs.contains($0) }
        for sessionID in staleItemEnrichmentIDs {
            cancelHistoryItemEnrichment(sessionID: sessionID, markIncomplete: false)
        }
        deferredFullHistorySessionIDs.formIntersection(validSessionIDs)
        let staleHistoryFirstPageKeys = historyFirstPageInFlightByKey.keys.filter { !validSessionIDs.contains($0.sessionID) }
        for key in staleHistoryFirstPageKeys {
            historyFirstPageInFlightByKey[key]?.task.cancel()
            historyFirstPageInFlightByKey.removeValue(forKey: key)
        }
        historyFirstPageCacheByKey = historyFirstPageCacheByKey.filter { validSessionIDs.contains($0.key.sessionID) }
        historySavingsNoticesBySessionID = historySavingsNoticesBySessionID.filter { validSessionIDs.contains($0.key) }
        listProjectionBySessionID = listProjectionBySessionID.filter { validSessionIDs.contains($0.key) }
        recentActivityProjectionBySessionID = recentActivityProjectionBySessionID.filter { validSessionIDs.contains($0.key) }
        initialHistoryLoadingSessionIDs.formIntersection(validSessionIDs)
        missingRunningSessionStateByID = missingRunningSessionStateByID.filter { sessionID, _ in
            validSessionIDs.contains(sessionID) || missingRunningSessionReconciliationTasksByID[sessionID] != nil
        }

        let loadingEarlierSessionIDs = loadingEarlierHistorySessionIDs.intersection(validSessionIDs)
        if loadingEarlierSessionIDs != loadingEarlierHistorySessionIDs {
            loadingEarlierHistorySessionIDs = loadingEarlierSessionIDs
        }

        let staleActivitySessionIDs = Set(foregroundActivityBySessionID.keys).subtracting(validSessionIDs)
        for sessionID in staleActivitySessionIDs {
            foregroundActivityClearTasks[sessionID]?.cancel()
            foregroundActivityClearTasks.removeValue(forKey: sessionID)
        }
        lastSeenEventSeqBySessionID = lastSeenEventSeqBySessionID.filter { validSessionIDs.contains($0.key) }
        let foregroundActivities = foregroundActivityBySessionID.filter { validSessionIDs.contains($0.key) }
        if foregroundActivities != foregroundActivityBySessionID {
            foregroundActivityBySessionID = foregroundActivities
        }
        let runtimeActivities = runtimeActivityBySessionID.filter { validSessionIDs.contains($0.key) }
        if runtimeActivities != runtimeActivityBySessionID {
            runtimeActivityBySessionID = runtimeActivities
        }
    }

    static func sortedSessions(_ items: [AgentSession]) -> [AgentSession] {
        SessionIndexStore.sortedSessions(items)
    }

    func sortedSessionsForList(_ items: [AgentSession]) -> [AgentSession] {
        let sorted = Self.sortedSessions(items)
        let indexByID = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.id, $0.offset) })
        return sorted.sorted { lhs, rhs in
            let leftPinned = pinnedSessionIDs.contains(lhs.id)
            let rightPinned = pinnedSessionIDs.contains(rhs.id)
            if leftPinned != rightPinned {
                return leftPinned
            }
            return (indexByID[lhs.id] ?? 0) < (indexByID[rhs.id] ?? 0)
        }
    }

    static func projectIDs(_ items: [AgentProject]) -> Set<String> {
        var ids: Set<String> = []
        ids.reserveCapacity(items.count)
        for item in items {
            ids.insert(item.id)
        }
        return ids
    }

}
