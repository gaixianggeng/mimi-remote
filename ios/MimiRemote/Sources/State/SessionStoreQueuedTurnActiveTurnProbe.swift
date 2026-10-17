import Foundation

struct QueuedTurnActiveTurnProbe {
    let token: UUID
    let task: Task<Void, Never>
}

enum QueuedTurnActiveTurnProbeResult {
    /// 权威页给出了最新 Turn 的事实。
    case latest(HistoryTurnState, snapshotSeq: EventSequence?)
    /// 运行时读不了 Turn 页，或服务端没有任何 Turn：没有可插入的进行中回合。
    case inconclusive
    /// 状态已变化、请求持续失败或任务被取消：保持等待，由下一次派发触发重新确认。
    case abandoned
}

// #751：会话仍在运行、本地却没有 activeTurnID 时，排队项不能按空闲派发。Codex 0.163 对进行中
// 回合收到的 turn/start 不会排到下一回合，而是插进当前回合，原任务的回复随之丢失。派发前先读
// 最新 Turn 的权威页：仍在进行就补回 turn 继续等待；已终态就复用 turn/completed 收敛并推进 FIFO。
// 读不到任何 Turn 事实时保留原先按空闲派发的行为，避免过期的运行态把队列永久卡住。
extension SessionStore {
    func probeActiveTurnBeforeQueuedDispatch(sessionID: SessionID) {
        guard queuedTurnActiveTurnProbesBySessionID[sessionID] == nil else {
            return
        }
        let hostScope = appStore.activeHostScope
        let retryDelays = turnCompletionReconciliationDelaysNanoseconds
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.probeLatestTurn(
                sessionID: sessionID,
                hostScope: hostScope,
                retryDelays: retryDelays
            )
            guard self.finishQueuedTurnActiveTurnProbe(sessionID: sessionID, token: token),
                  !Task.isCancelled,
                  self.needsQueuedTurnActiveTurnProbe(sessionID: sessionID, hostScope: hostScope)
            else {
                return
            }
            await self.applyQueuedTurnActiveTurnProbe(result, sessionID: sessionID, hostScope: hostScope)
        }
        queuedTurnActiveTurnProbesBySessionID[sessionID] = QueuedTurnActiveTurnProbe(token: token, task: task)
    }

    func needsQueuedTurnActiveTurnProbe(sessionID: SessionID, hostScope: HostScope) -> Bool {
        guard appStore.activeHostScope == hostScope,
              connectionTermination == nil,
              appStore.isConfigured,
              !isAppInBackground,
              let session = sessionsByID[sessionID],
              session.isRunning,
              session.activeTurnID == nil,
              queuedRunningTurnsBySessionID[sessionID]?.first?.dispatchState == .waiting
        else {
            return false
        }
        return true
    }

    @discardableResult
    func finishQueuedTurnActiveTurnProbe(sessionID: SessionID, token: UUID) -> Bool {
        guard queuedTurnActiveTurnProbesBySessionID[sessionID]?.token == token else {
            return false
        }
        queuedTurnActiveTurnProbesBySessionID.removeValue(forKey: sessionID)
        return true
    }

    private func probeLatestTurn(
        sessionID: SessionID,
        hostScope: HostScope,
        retryDelays: [UInt64]
    ) async -> QueuedTurnActiveTurnProbeResult {
        for delay in [0] + retryDelays {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return .abandoned
                }
            }
            guard needsQueuedTurnActiveTurnProbe(sessionID: sessionID, hostScope: hostScope) else {
                return .abandoned
            }
            do {
                // 只认原始 Turn 事实（与完成对账一致）：新轮次可能尚未产生任何 Item。
                guard let page = try await clientFactory().latestTurnHistoryPage(sessionID: sessionID),
                      let latest = page.turnStates.last
                else {
                    return .inconclusive
                }
                return .latest(latest, snapshotSeq: page.snapshotSeq)
            } catch is CancellationError {
                return .abandoned
            } catch CodexAppServerSessionRuntimeError.paginatedHistoryUnavailable(_) {
                return .inconclusive
            } catch {
                // 短暂的历史请求冲突或弱网失败不改变本地状态；有限退避后再试。
                continue
            }
        }
        return .abandoned
    }

    private func applyQueuedTurnActiveTurnProbe(
        _ result: QueuedTurnActiveTurnProbeResult,
        sessionID: SessionID,
        hostScope: HostScope
    ) async {
        switch result {
        case .abandoned:
            return
        case .inconclusive:
            dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID, allowsRunningWithoutActiveTurn: true)
        case .latest(let latest, let snapshotSeq) where latest.lifecycle.isTerminal:
            // 最新 Turn 已终态，只是 turn/completed 没有送到：复用完成路径收敛状态并推进 FIFO。
            await applyRuntimeEvent(
                .turnCompleted(AgentEventMetadata(
                    seq: snapshotSeq,
                    sessionID: sessionID,
                    turnID: latest.id,
                    itemID: nil,
                    messageID: nil,
                    clientMessageID: nil,
                    revision: nil,
                    createdAt: nil,
                    turnLifecycle: latest.lifecycle
                )),
                lease: HostSessionLease(hostScope: hostScope, sessionID: sessionID),
                sendsNotification: false
            )
        case .latest(let latest, _):
            // 仍在进行：补回 turn，排队项与入队时就看到 activeTurnID 一样等待它的 turn/completed。
            updateSession(sessionID) { item in
                item.activeTurnID = latest.id
            }
            _ = mutateAndPersistQueuedTurns {
                guard var queue = queuedRunningTurnsBySessionID[sessionID] else { return }
                for index in queue.indices
                where queue[index].dispatchState == .waiting && queue[index].expectedTurnID == nil {
                    queue[index].expectedTurnID = latest.id
                }
                queuedRunningTurnsBySessionID[sessionID] = queue
            }
        }
    }
}
