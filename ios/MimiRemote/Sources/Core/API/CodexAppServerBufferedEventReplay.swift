import Foundation

/// 历史页已经先读取权威快照；这里只保留恢复窗口中的完成内容与当前状态，避免旧回合
/// 逐条发布 running/completed。生产调用在 connect 成功后必有 currentSession；缺失时不猜状态。
enum CodexAppServerBufferedEventReplay {
    static func stateOnly(
        _ events: [AgentEvent],
        currentSession: AgentSession?,
        pendingInteractionIDs: Set<String>
    ) -> [AgentEvent] {
        let replayBoundary = latestReplayBoundary(in: events)
        var replay = retainedPayloadEvents(events, currentSession: currentSession)

        guard let currentSession else {
            // 没有权威快照时不从旧控制事件推断生命周期，也不提交 replay cursor。
            replay.append(contentsOf: pendingEvents(
                events,
                pendingInteractionIDs: pendingInteractionIDs
            ))
            return replay
        }

        if currentSession.isRunning {
            if let event = latestActiveStart(in: events, session: currentSession) {
                replay.append(removingReplayBoundary(from: event))
            }
        } else if let event = latestTerminalEvent(in: events, session: currentSession) {
            replay.append(removingReplayBoundary(from: event))
        }

        // Runtime 快照是生命周期唯一事实来源。旧 session/status/context 不能覆盖它。
        replay.append(.session(currentSession))
        replay.append(contentsOf: pendingEvents(
            events,
            pendingInteractionIDs: pendingInteractionIDs
        ))

        if let replayBoundary {
            // 游标只在内容、最终会话和 pending 卡片全部落地后提交。
            replay.append(.sessionStatus(
                currentSession.status,
                AgentEventMetadata(
                    seq: replayBoundary.metadata.seq,
                    sessionID: currentSession.id,
                    turnID: nil,
                    itemID: nil,
                    messageID: nil,
                    clientMessageID: nil,
                    revision: replayBoundary.metadata.revision,
                    createdAt: replayBoundary.metadata.createdAt,
                    replayBoundarySequence: replayBoundary.sequence,
                    replayCursorEpoch: replayBoundary.metadata.replayCursorEpoch
                )
            ))
        }
        return replay
    }

    private static func retainedPayloadEvents(
        _ events: [AgentEvent],
        currentSession: AgentSession?
    ) -> [AgentEvent] {
        events.compactMap { event in
            switch event {
            case .session, .sessionRow, .sessionStatus, .sessionContext,
                 .turnStarted, .turnCompleted, .error,
                 .approvalRequest, .approvalResolved,
                 .userInputRequest, .userInputResolved:
                return nil
            case .messageCompleted(let message, let metadata):
                return .messageCompleted(
                    message,
                    contentMetadata(metadata, currentSession: currentSession)
                )
            case .processItemCompleted(let message, let context, let metadata):
                return .processItemCompleted(
                    message,
                    context,
                    contentMetadata(metadata, currentSession: currentSession)
                )
            case .assistantDelta(let delta, let metadata):
                // thread/read 已覆盖旧回合正文；恢复门内只补当前活动回合的新分片，
                // 否则 connect 期间产生的回复会被 stateOnly 永久丢弃。
                guard currentSession?.isRunning == true,
                      let activeTurnID = currentSession?.activeTurnID,
                      metadata.turnID == activeTurnID else {
                    return nil
                }
                return .assistantDelta(
                    delta,
                    contentMetadata(metadata, currentSession: currentSession)
                )
            default:
                return event
            }
        }
    }

    private static func latestActiveStart(
        in events: [AgentEvent],
        session: AgentSession
    ) -> AgentEvent? {
        guard let activeTurnID = session.activeTurnID else { return nil }
        return events.reversed().first { event in
            guard case .turnStarted(let metadata) = event else { return false }
            return metadata.turnID == activeTurnID
        }
    }

    private static func latestTerminalEvent(
        in events: [AgentEvent],
        session: AgentSession
    ) -> AgentEvent? {
        events.reversed().first { event in
            switch event {
            case .turnCompleted(let metadata):
                if session.status == SessionStatus.failed.rawValue {
                    return metadata.turnLifecycle == .failed
                }
                return session.status == SessionStatus.completed.rawValue
                    && metadata.turnLifecycle != .failed
            case .error:
                return session.status == SessionStatus.failed.rawValue
            default:
                return false
            }
        }
    }

    private static func pendingEvents(
        _ events: [AgentEvent],
        pendingInteractionIDs: Set<String>
    ) -> [AgentEvent] {
        var latestByID: [String: (index: Int, event: AgentEvent)] = [:]
        for (index, event) in events.enumerated() {
            let interactionID: String?
            switch event {
            case .approvalRequest(let request, _):
                interactionID = "approval:\(request.id)"
            case .userInputRequest(let request, _):
                interactionID = "user-input:\(request.id)"
            default:
                interactionID = nil
            }
            if let interactionID, pendingInteractionIDs.contains(interactionID) {
                latestByID[interactionID] = (index, event)
            }
        }
        return latestByID.values.sorted { $0.index < $1.index }.map(\.event)
    }

    private struct ReplayBoundary {
        let sequence: UInt64
        let metadata: AgentEventMetadata
    }

    private static func latestReplayBoundary(in events: [AgentEvent]) -> ReplayBoundary? {
        events.compactMap { event -> ReplayBoundary? in
            guard let metadata = metadata(for: event),
                  let sequence = metadata.replayBoundarySequence else {
                return nil
            }
            return ReplayBoundary(sequence: sequence, metadata: metadata)
        }.max { $0.sequence < $1.sequence }
    }

    private static func metadata(for event: AgentEvent) -> AgentEventMetadata? {
        switch event {
        case .session, .unknown:
            return nil
        case .sessionRow(_, let metadata),
             .sessionStatus(_, let metadata),
             .sessionContext(_, let metadata),
             .permissionProfileUpdated(_, let metadata),
             .collaborationModeUpdated(_, let metadata),
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
        }
    }

    private static func removingReplayBoundary(from event: AgentEvent) -> AgentEvent {
        switch event {
        case .turnStarted(let metadata):
            return .turnStarted(metadataWithoutReplayBoundary(metadata, turnID: metadata.turnID))
        case .turnCompleted(let metadata):
            return .turnCompleted(metadataWithoutReplayBoundary(metadata, turnID: metadata.turnID))
        case .error(let error, let metadata):
            return .error(error, metadataWithoutReplayBoundary(metadata, turnID: metadata.turnID))
        default:
            return event
        }
    }

    private static func contentMetadata(
        _ metadata: AgentEventMetadata,
        currentSession: AgentSession?
    ) -> AgentEventMetadata {
        let keepsActiveTurn = currentSession?.isRunning == true
            && currentSession?.activeTurnID != nil
            && currentSession?.activeTurnID == metadata.turnID
        return metadataWithoutReplayBoundary(
            metadata,
            turnID: keepsActiveTurn ? metadata.turnID : nil
        )
    }

    private static func metadataWithoutReplayBoundary(
        _ metadata: AgentEventMetadata,
        turnID: TurnID?
    ) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: metadata.seq,
            sessionID: metadata.sessionID,
            turnID: turnID,
            itemID: metadata.itemID,
            messageID: metadata.messageID,
            clientMessageID: metadata.clientMessageID,
            revision: metadata.revision,
            createdAt: metadata.createdAt,
            turnLifecycle: metadata.turnLifecycle,
            turnError: metadata.turnError,
            replayBoundarySequence: nil,
            replayCursorEpoch: nil
        )
    }
}

extension CodexAppServerSessionRuntime {
    func backfillActiveTurnFromLiveNotification(
        method: String,
        params: [String: CodexAppServerJSONValue]
    ) {
        guard method != "turn/completed",
              // thread/* 不能证明 turn 活跃；已确认终止的 turn item 只是迟到历史。
              !method.hasPrefix("thread/"),
              let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              !turnID.isEmpty,
              !hasObservedTerminal(sessionID: threadID, turnID: turnID),
              let context = contextsBySessionID[threadID],
              context.activeTurnID != turnID || context.session.status != "running" else {
            return
        }
        _ = withUpdatedSession(threadID) { item in
            // 真正错过 turn/started 的 live 通知仍可补齐发送层所需的 activeTurnID。
            item.status = "running"
            item.activeTurnID = turnID
        }
    }
}
