import Foundation

// Codex 在 turn/start 响应之后、turn/started 之前收到 turn/interrupt 会拒绝：回
// `no active turn to interrupt`，或上一轮刚停下时回 `expected active turn id … but found …`，
// 回合随后照常执行（#808）。这段窗口里的失败不能当成目标已结束：等 turn/started 到达后重发；
// 只有确认回合已经结束，才交给 gh-509 的收敛。

enum CodexAppServerTurnStartedSignal: Equatable {
    case started
    case terminal
    case timedOut
    case abandoned
}

struct CodexAppServerTurnStartedWaiter {
    let sessionID: SessionID
    let turnID: TurnID
    let continuation: CheckedContinuation<CodexAppServerTurnStartedSignal, Never>
    let timeoutTask: Task<Void, Never>
}

/// 停止请求没有被上游接受，且无法确认回合已经结束。不能归为 staleTarget：
/// App 必须保持运行态和停止按钮，让用户看到停止没有生效。
enum CodexAppServerTurnInterruptError: LocalizedError, Equatable {
    case notAcceptedBeforeTurnStarted(SessionID)

    var errorDescription: String? {
        L10n.text("ui.stop_did_not_take_effect_turn_not_started")
    }
}

extension CodexAppServerSessionRuntime {
    /// 发送 turn/interrupt。返回 false 表示等待期间回合已自行结束，不必再中断。
    func sendTurnInterruptAwaitingTurnStart(
        _ spec: CodexAppServerRequestSpec,
        sessionID: SessionID,
        turnID: TurnID
    ) async throws -> Bool {
        // 失败回包与 turn/started 分属两条 pump，回到 actor 时通知可能已经落地；
        // 必须在发送前判断窗口，不能等失败后再看。
        let sentBeforeTurnStarted = isAwaitingTurnStartedSignal(sessionID: sessionID, turnID: turnID)
        do {
            _ = try await sendRecoveringFromStaleInitialization(spec)
            return true
        } catch {
            guard sentBeforeTurnStarted, Self.isTurnNotYetActiveError(error, turnID: turnID) else {
                throw error
            }
        }
        let signal = await waitForTurnStartedSignal(sessionID: sessionID, turnID: turnID)
        switch signal {
        case .terminal:
            // 上游的真实终态已经收敛本地状态，不能再合成 interrupted。
            return false
        case .abandoned:
            throw CodexAppServerTurnInterruptError.notAcceptedBeforeTurnStarted(sessionID)
        case .started, .timedOut:
            break
        }
        do {
            _ = try await sendRecoveringFromStaleInitialization(spec)
            return true
        } catch {
            guard ControlCommandFailure.classify(error).isStaleTarget else { throw error }
            if hasObservedTerminal(sessionID: sessionID, turnID: turnID) {
                // 重发途中回合已以真实终态结束，不能再叠一条合成的 interrupted。
                return false
            }
            if signal == .started {
                // 上游确认开始过，现在又说没有进行中的回合：它已经结束，沿用 gh-509 的收敛。
                throw error
            }
            // 等满时限仍没看到 turn/started：既不能确认回合结束，也不能确认已停下。
            // 交给权威 turns 快照对账，同时如实报告停止没有生效。
            scheduleTurnInterruptRecovery(sessionID: sessionID, turnID: turnID)
            throw CodexAppServerTurnInterruptError.notAcceptedBeforeTurnStarted(sessionID)
        }
    }

    /// 窗口内上游还没把这一轮当成进行中的回合：没有进行中的回合，或者上一轮刚停下、
    /// 仍占着 active turn（实测回 `expected active turn id <本轮> but found <上一轮>`）。
    nonisolated static func isTurnNotYetActiveError(_ error: Error, turnID: TurnID) -> Bool {
        if ControlCommandFailure.classify(error).isStaleTarget {
            return true
        }
        guard case CodexAppServerConnectionError.appServer(let appError) = error else {
            return false
        }
        let message = appError.message.lowercased()
        return message.contains("expected active turn") && message.contains(turnID.lowercased())
    }

    /// 本端发起、已拿到 ACK，但还没看到 turn/started 或终态的回合。
    func isAwaitingTurnStartedSignal(sessionID: SessionID, turnID: TurnID) -> Bool {
        turnsStartedByThisRuntime.contains(turnID)
            && lastStartedTurnIDBySessionID[sessionID] != turnID
            && !hasObservedTerminal(sessionID: sessionID, turnID: turnID)
    }

    func hasObservedTerminal(sessionID: SessionID, turnID: TurnID) -> Bool {
        terminalTurnTombstonesByKey[terminalTurnTombstoneKey(sessionID: sessionID, turnID: turnID)] != nil
    }

    func waitForTurnStartedSignal(
        sessionID: SessionID,
        turnID: TurnID
    ) async -> CodexAppServerTurnStartedSignal {
        if lastStartedTurnIDBySessionID[sessionID] == turnID {
            return .started
        }
        if hasObservedTerminal(sessionID: sessionID, turnID: turnID) {
            return .terminal
        }
        let token = UUID()
        let timeout = turnStartedSignalTimeoutNanoseconds
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.resolveTurnStartedWaiter(token, signal: .timedOut)
                }
                turnStartedWaitersByToken[token] = CodexAppServerTurnStartedWaiter(
                    sessionID: sessionID,
                    turnID: turnID,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resolveTurnStartedWaiter(token, signal: .abandoned)
            }
        }
    }

    /// 在 handle(notification) 入口调用：记录 turn/started，并唤醒等待中的停止请求。
    func recordTurnStartedSignal(from notification: CodexAppServerNotification) {
        let params = notification.params?.objectValue ?? [:]
        guard let threadID = params["threadId"]?.stringValue else { return }
        let turnID = completedTurnID(from: params)
        let signal: CodexAppServerTurnStartedSignal
        switch notification.method {
        case "turn/started":
            guard let turnID else { return }
            lastStartedTurnIDBySessionID[threadID] = turnID
            signal = .started
        case "turn/completed":
            // 无 ID 的完成无法确认是哪一轮；继续等，交给超时后的权威对账。
            guard turnID != nil else { return }
            signal = .terminal
        case "thread/closed":
            signal = .terminal
        default:
            return
        }
        let matching = turnStartedWaitersByToken.filter { _, waiter in
            waiter.sessionID == threadID && (turnID == nil || waiter.turnID == turnID)
        }
        for token in matching.keys {
            resolveTurnStartedWaiter(token, signal: signal)
        }
    }

    func resolveTurnStartedWaiter(_ token: UUID, signal: CodexAppServerTurnStartedSignal) {
        guard let waiter = turnStartedWaitersByToken.removeValue(forKey: token) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: signal)
    }

    func cancelAllTurnStartedWaiters() {
        for token in Array(turnStartedWaitersByToken.keys) {
            resolveTurnStartedWaiter(token, signal: .abandoned)
        }
    }
}
