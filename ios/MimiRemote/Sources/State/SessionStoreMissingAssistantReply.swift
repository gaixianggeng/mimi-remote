import Foundation

struct MissingAssistantReplyBackfillJob {
    let id = UUID()
    let lease: SessionSelectionLease
    var pendingTurnIDs: Set<TurnID>
    var attemptedTurnIDs: Set<TurnID> = []
    var task: Task<Void, Never>?
}

extension SessionStore {
    static let missingAssistantReplyBackfillDelayNanoseconds: UInt64 = 400_000_000

    func scheduleMissingAssistantReplyBackfillIfNeeded(
        turnMetadata metadata: AgentEventMetadata,
        fallbackSessionID: SessionID,
        hostScope: HostScope
    ) {
        let sessionID = metadata.sessionID ?? fallbackSessionID
        guard let turnID = metadata.turnID,
              (metadata.turnLifecycle ?? .completed) == .completed,
              appStore.activeHostScope == hostScope,
              selectedSessionID == sessionID,
              let session = sessionsByID[sessionID],
              !session.isLocalDraft,
              !isProtocolReadOnlySession(session),
              !hasAssistantReply(sessionID: sessionID, turnID: turnID)
        else { return }

        let lease = currentSelectionLease()
        var job = missingAssistantReplyBackfillJobsBySessionID[sessionID]
        if job?.lease != lease {
            job?.task?.cancel()
            // 同一主机切回会话时保留旧缺口；不能把另一主机的同名 turn 带过来。
            let pending = job?.lease.hostScope == hostScope ? job?.pendingTurnIDs ?? [] : []
            job = MissingAssistantReplyBackfillJob(lease: lease, pendingTurnIDs: pending)
        }
        guard var job else { return }
        job.pendingTurnIDs.insert(turnID)
        missingAssistantReplyBackfillJobsBySessionID[sessionID] = job
        startMissingAssistantReplyBackfill(sessionID: sessionID)
    }

    private func startMissingAssistantReplyBackfill(sessionID: SessionID) {
        guard !isAppInBackground,
              var job = missingAssistantReplyBackfillJobsBySessionID[sessionID],
              isSelectionLeaseCurrent(job.lease),
              job.task == nil,
              !job.pendingTurnIDs.subtracting(job.attemptedTurnIDs).isEmpty
        else { return }

        let jobID = job.id
        job.task = Task { @MainActor [weak self] in
            await self?.performMissingAssistantReplyBackfill(sessionID: sessionID, jobID: jobID)
        }
        missingAssistantReplyBackfillJobsBySessionID[sessionID] = job
    }

    private func performMissingAssistantReplyBackfill(sessionID: SessionID, jobID: UUID) async {
        defer {
            if missingAssistantReplyBackfillJobsBySessionID[sessionID]?.id == jobID {
                missingAssistantReplyBackfillJobsBySessionID[sessionID]?.task = nil
            }
        }
        while !Task.isCancelled {
            guard var job = missingAssistantReplyBackfillJobsBySessionID[sessionID],
                  job.id == jobID,
                  !isAppInBackground,
                  isSelectionLeaseCurrent(job.lease)
            else { return }

            // 只有正文实际合并后才清掉缺口。失败或空页仍保留记录，但同一完成事件
            // 在本次前台/选择周期内只触发一次读取，不能变成无限重试。
            job.pendingTurnIDs = job.pendingTurnIDs.filter {
                !hasAssistantReply(sessionID: sessionID, turnID: $0)
            }
            job.attemptedTurnIDs.formIntersection(job.pendingTurnIDs)
            if job.pendingTurnIDs.isEmpty {
                missingAssistantReplyBackfillJobsBySessionID[sessionID] = nil
                return
            }
            missingAssistantReplyBackfillJobsBySessionID[sessionID] = job
            guard !job.pendingTurnIDs.subtracting(job.attemptedTurnIDs).isEmpty else { return }

            do {
                try await Task.sleep(nanoseconds: Self.missingAssistantReplyBackfillDelayNanoseconds)
                try Task.checkCancellation()
            } catch { return }
            guard var current = missingAssistantReplyBackfillJobsBySessionID[sessionID],
                  current.id == jobID,
                  !isAppInBackground,
                  isSelectionLeaseCurrent(current.lease),
                  let session = sessionsByID[sessionID]
            else { return }
            let missing = current.pendingTurnIDs.filter {
                !hasAssistantReply(sessionID: sessionID, turnID: $0)
            }
            let unread = missing.subtracting(current.attemptedTurnIDs)
            guard !unread.isEmpty else { continue }
            current.attemptedTurnIDs.formUnion(unread)
            missingAssistantReplyBackfillJobsBySessionID[sessionID] = current

            // 即使旧 full 请求本身已 bypass，也可能取的是完成前的快照。此原因要求
            // 新建请求，旧响应沿现有 token 门禁失效。读取期间出现的新 turn 留到下一批。
            _ = await loadHistory(for: session, quiet: true, force: true, reason: .missingAssistantReply)
        }
    }

    func resumeMissingAssistantReplyBackfillIfNeeded() {
        guard let sessionID = selectedSessionID,
              let job = missingAssistantReplyBackfillJobsBySessionID[sessionID],
              job.lease.hostScope == appStore.activeHostScope
        else { return }
        job.task?.cancel()
        missingAssistantReplyBackfillJobsBySessionID[sessionID] = MissingAssistantReplyBackfillJob(
            lease: currentSelectionLease(),
            pendingTurnIDs: job.pendingTurnIDs
        )
        startMissingAssistantReplyBackfill(sessionID: sessionID)
    }

    func pauseMissingAssistantReplyBackfills() {
        for sessionID in missingAssistantReplyBackfillJobsBySessionID.keys {
            missingAssistantReplyBackfillJobsBySessionID[sessionID]?.task?.cancel()
            missingAssistantReplyBackfillJobsBySessionID[sessionID]?.task = nil
        }
    }

    func cancelMissingAssistantReplyBackfill(sessionID: SessionID) {
        missingAssistantReplyBackfillJobsBySessionID.removeValue(forKey: sessionID)?.task?.cancel()
    }

    func cancelAllMissingAssistantReplyBackfills() {
        pauseMissingAssistantReplyBackfills()
        missingAssistantReplyBackfillJobsBySessionID.removeAll()
    }

    func hasAssistantReply(sessionID: SessionID, turnID: TurnID) -> Bool {
        conversationStore.messages(for: sessionID).contains {
            $0.role == .assistant && $0.kind == .message && $0.turnID == turnID
        }
    }
}
