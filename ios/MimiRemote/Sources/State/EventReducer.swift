import Foundation

struct EventReducerOutput {
    var upsertSessions: [AgentSession] = []
    var statusUpdates: [(SessionID, String)] = []
    var pendingApprovalUpdates: [(SessionID, ApprovalSummary?)] = []
    var pendingUserInputUpdates: [(SessionID, AgentUserInputRequest?)] = []
    var goalUpdates: [(SessionID, ThreadGoal?)] = []
    var pendingApprovalTaskClears: [SessionID] = []
    var contextUpdates: [(SessionContextSnapshot, SessionID?)] = []
    var foregroundUpdates: [(SessionID, SessionForegroundActivity, UInt64?)] = []
    var foregroundClears: [SessionID] = []
    var activeTurnMutations: [EventReducerActiveTurnMutation] = []
    var messageMutations: [EventReducerMessageMutation] = []
    var logAppends: [EventReducerLogAppend] = []
    var statusMessage: String?
    var errorMessage: String?
    var disconnectWebSocket = false
}

enum EventReducerActiveTurnMutation {
    case set(SessionID, TurnID)
    case clear(SessionID, TurnID?)
}

enum EventReducerMessageMutation {
    case turnLifecycle(ConversationTurnLifecycle, AgentEventMetadata, SessionID)
    case assistantDelta(AgentDelta, AgentEventMetadata, SessionID)
    case completed(AgentMessage, AgentEventMetadata, SessionID)
    case system(String, SessionID, MessageKind, AgentEventMetadata?)
    case resolveLatestPendingApproval(SessionID)
    case resolveLatestPendingUserInput(SessionID, skipped: Bool)
    case markCurrentAssistantCompleted(AgentEventMetadata, SessionID)
}

struct EventReducerLogAppend {
    let text: String
    let sessionID: SessionID
    let seq: EventSequence?
}

actor EventReducer {
    private var reportedUnsupportedEventTypes: Set<String> = []

    func reduce(
        _ event: AgentEvent,
        fallbackSessionID: SessionID,
        outputIdleClearDelay: UInt64
    ) -> EventReducerOutput {
        var output = EventReducerOutput()

        switch event {
        case .session(let session):
            output.upsertSessions.append(session)
            if let goal = session.goal {
                output.goalUpdates.append((session.id, goal))
            }
            if let context = session.context {
                output.contextUpdates.append((context, session.id))
            }
        case .sessionRow(let row, _):
            let session = AgentSession(row: row)
            output.upsertSessions.append(session)
            if let goal = session.goal {
                output.goalUpdates.append((session.id, goal))
            }
            if let context = row.context {
                output.contextUpdates.append((context, row.id))
            }
        case .sessionStatus(let status, let metadata):
            guard let id = metadata.sessionID, let status else {
                return output
            }
            output.statusUpdates.append((id, status))
            if shouldClearPendingApproval(for: status) {
                output.pendingApprovalUpdates.append((id, nil))
                output.pendingApprovalTaskClears.append(id)
                output.messageMutations.append(.resolveLatestPendingApproval(id))
            }
            if shouldClearPendingUserInput(for: status) {
                output.pendingUserInputUpdates.append((id, nil))
                output.messageMutations.append(.resolveLatestPendingUserInput(id, skipped: false))
            }
            if !isRunningStatus(status) {
                output.activeTurnMutations.append(.clear(id, nil))
            }
            output.contextUpdates.append((
                SessionContextSnapshot(sessionID: id, status: SessionContextStatus(type: contextStatusType(from: status)), updatedAt: Date()),
                id
            ))
            if status != "running" {
                output.foregroundClears.append(id)
            }
        case .sessionContext(let context, let metadata):
            output.contextUpdates.append((context, metadata.sessionID))
            if let goal = context.goal, let id = context.sessionID ?? metadata.sessionID ?? context.threadID {
                output.goalUpdates.append((id, goal))
            }
        case .permissionProfileUpdated:
            // SessionStoreConnection 在进入通用 reducer 前更新权限状态；这里不生成会话时间线事件。
            break
        case .goalUpdated(let goal, let metadata):
            let id = metadata.sessionID ?? goal.threadID
            output.goalUpdates.append((id, goal))
            output.contextUpdates.append((
                SessionContextSnapshot(sessionID: id, threadID: goal.threadID, goal: goal, updatedAt: Date()),
                id
            ))
        case .goalCleared(let metadata):
            guard let id = metadata.sessionID else {
                return output
            }
            output.goalUpdates.append((id, nil))
        case .turnStarted(let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            output.statusUpdates.append((id, "running"))
            if let turnID = metadata.turnID {
                output.activeTurnMutations.append(.set(id, turnID))
            }
            output.contextUpdates.append((
                SessionContextSnapshot(sessionID: id, status: SessionContextStatus(type: "active"), updatedAt: Date()),
                id
            ))
            output.foregroundUpdates.append((id, .waitingForAssistant, nil))
            output.messageMutations.append(.turnLifecycle(.inProgress, metadata, fallbackSessionID))
        case .assistantDelta(let delta, let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            setActiveTurnIfPresent(metadata, fallbackSessionID: fallbackSessionID, output: &output)
            output.foregroundUpdates.append((id, .receivingAssistant, outputIdleClearDelay))
            output.messageMutations.append(.assistantDelta(delta, metadata, fallbackSessionID))
        case .messageCompleted(let message, let metadata):
            setActiveTurnIfPresent(metadata, fallbackSessionID: fallbackSessionID, output: &output)
            output.messageMutations.append(.completed(message, metadata, fallbackSessionID))
            if message.role == .assistant {
                output.foregroundClears.append(metadata.sessionID ?? message.sessionID)
            }
        case .processItemCompleted(let message, let context, let metadata):
            setActiveTurnIfPresent(metadata, fallbackSessionID: fallbackSessionID, output: &output)
            output.messageMutations.append(.completed(message, metadata, fallbackSessionID))
            if let context {
                output.contextUpdates.append((context, metadata.sessionID))
            }
        case .logDelta(let delta, let metadata):
            setActiveTurnIfPresent(metadata, fallbackSessionID: fallbackSessionID, output: &output)
            output.logAppends.append(EventReducerLogAppend(
                text: delta.text,
                sessionID: metadata.sessionID ?? fallbackSessionID,
                seq: metadata.seq
            ))
        case .diffUpdated(let change, let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            setActiveTurnIfPresent(metadata, fallbackSessionID: fallbackSessionID, output: &output)
            output.contextUpdates.append((
                SessionContextSnapshot(
                    tasks: [SessionContextTask(id: change.path, kind: "file_change", title: L10n.text("ui.file_changes"), subtitle: change.path, status: change.status)],
                    updatedAt: Date()
                ),
                id
            ))
            output.messageMutations.append(.system(
                L10n.format("ui.file_changes_value_value", change.path, change.status),
                id,
                .fileChangeSummary,
                metadata
            ))
        case .approvalRequest(let request, let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            setActiveTurnIfPresent(metadata, fallbackSessionID: fallbackSessionID, output: &output)
            output.statusUpdates.append((id, "waiting_for_approval"))
            // 输入框上方的审批卡读取 session.pendingApproval；审批事件不能只写入时间线记录。
            output.pendingApprovalUpdates.append((
                id,
                ApprovalSummary(
                    id: request.id,
                    title: request.title,
                    body: request.body,
                    kind: request.kind,
                    risk: request.risk,
                    count: nil,
                    availableDecisions: request.availableDecisions,
                    persistentPermissionRules: request.persistentPermissionRules
                )
            ))
            output.contextUpdates.append((
                SessionContextSnapshot(
                    sessionID: id,
                    status: SessionContextStatus(type: "active", activeFlags: ["waitingOnApproval"]),
                    tasks: [SessionContextTask(id: request.id, kind: request.kind, title: request.title, subtitle: request.risk, status: "waiting")],
                    updatedAt: Date()
                ),
                id
            ))
            let risk = request.risk.map { L10n.format("ui.risk_value", $0) } ?? ""
            output.messageMutations.append(.system(L10n.format("ui.awaiting_approval_value_value", request.title, risk), id, .approval, metadata))
        case .approvalResolved(let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            setActiveTurnIfPresent(metadata, fallbackSessionID: fallbackSessionID, output: &output)
            // app-server 会在 JSON-RPC server request 被处理后发 serverRequest/resolved；
            // 这里只收起 pending 卡片，并把本地等待态恢复为运行态，避免历史审批残留挡住输入框。
            output.pendingApprovalUpdates.append((id, nil))
            output.statusUpdates.append((id, "running"))
            output.contextUpdates.append((
                SessionContextSnapshot(sessionID: id, status: SessionContextStatus(type: "active"), updatedAt: Date()),
                id
            ))
            output.pendingApprovalTaskClears.append(id)
            output.messageMutations.append(.resolveLatestPendingApproval(id))
        case .userInputRequest(let request, let metadata):
            let id = metadata.sessionID ?? request.threadID
            setActiveTurnIfPresent(metadata, fallbackSessionID: fallbackSessionID, output: &output)
            output.statusUpdates.append((id, "waiting_for_input"))
            // request_user_input 是 turn 内部的补充信息阻塞点；写入 session 后输入框上方渲染补充信息卡。
            output.pendingUserInputUpdates.append((id, request))
            output.contextUpdates.append((
                SessionContextSnapshot(
                    sessionID: id,
                    status: SessionContextStatus(type: "active", activeFlags: ["waitingOnUserInput"]),
                    tasks: [SessionContextTask(id: request.id, kind: "user_input", title: request.title, subtitle: nil, status: "waiting")],
                    updatedAt: Date()
                ),
                id
            ))
            output.messageMutations.append(.system(L10n.format("ui.waiting_for_additional_information_named", request.title), id, .userInput, metadata))
        case .userInputResolved(let metadata, let skipped):
            let id = metadata.sessionID ?? fallbackSessionID
            setActiveTurnIfPresent(metadata, fallbackSessionID: fallbackSessionID, output: &output)
            output.pendingUserInputUpdates.append((id, nil))
            output.statusUpdates.append((id, "running"))
            output.contextUpdates.append((
                SessionContextSnapshot(sessionID: id, status: SessionContextStatus(type: "active"), updatedAt: Date()),
                id
            ))
            output.messageMutations.append(.resolveLatestPendingUserInput(id, skipped: skipped))
        case .turnCompleted(let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            let lifecycle = metadata.turnLifecycle ?? .completed
            let sessionStatus = lifecycle == .failed ? SessionStatus.failed : .completed
            output.statusUpdates.append((id, sessionStatus.rawValue))
            output.pendingApprovalUpdates.append((id, nil))
            output.pendingUserInputUpdates.append((id, nil))
            output.contextUpdates.append((
                SessionContextSnapshot(sessionID: id, status: SessionContextStatus(type: sessionStatus.rawValue), updatedAt: Date()),
                id
            ))
            output.pendingApprovalTaskClears.append(id)
            output.messageMutations.append(.resolveLatestPendingApproval(id))
            output.messageMutations.append(.resolveLatestPendingUserInput(id, skipped: false))
            output.messageMutations.append(.turnLifecycle(lifecycle, metadata, fallbackSessionID))
            output.messageMutations.append(.markCurrentAssistantCompleted(metadata, fallbackSessionID))
            output.activeTurnMutations.append(.clear(id, metadata.turnID))
            output.foregroundClears.append(id)
        case .warning(let payload, let metadata):
            output.logAppends.append(EventReducerLogAppend(
                text: "\n[agentd] warning: \(payload.message)\n",
                sessionID: fallbackSessionID,
                seq: nil
            ))
            output.messageMutations.append(.system(payload.message, fallbackSessionID, .warning, metadata))
        case .error(let payload, let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            let isClaudeAuthenticationFailure = ClaudeAuthenticationRecovery.matches(payload)
            // 多 runtime 下错误必须按通知携带的 thread 归属，不能回退到当前选中的其他会话。
            output.statusUpdates.append((id, SessionStatus.failed.rawValue))
            output.foregroundClears.append(id)
            output.activeTurnMutations.append(.clear(id, metadata.turnID))
            output.pendingApprovalUpdates.append((id, nil))
            output.pendingUserInputUpdates.append((id, nil))
            output.pendingApprovalTaskClears.append(id)
            output.contextUpdates.append((
                SessionContextSnapshot(
                    sessionID: id,
                    status: SessionContextStatus(type: "systemError"),
                    updatedAt: Date()
                ),
                id
            ))
            output.errorMessage = isClaudeAuthenticationFailure
                ? ClaudeAuthenticationRecovery.title
                : payload.message
            output.logAppends.append(EventReducerLogAppend(
                text: "\n[agentd] \(payload.message)\n",
                sessionID: id,
                seq: nil
            ))
            if isClaudeAuthenticationFailure {
                let stableID = metadata.messageID
                    ?? metadata.itemID
                    ?? metadata.turnID.map { "runtime-error:\($0)" }
                    ?? metadata.seq.map { "runtime-error:\($0)" }
                    ?? "runtime-error:\(UUID().uuidString)"
                output.messageMutations.append(.completed(
                    AgentMessage(
                        id: stableID,
                        sessionID: id,
                        turnID: metadata.turnID,
                        itemID: metadata.itemID,
                        role: .system,
                        kind: .error,
                        content: ClaudeAuthenticationRecovery.recoveryMessage,
                        summary: ClaudeAuthenticationRecovery.title,
                        activityPayload: ClaudeAuthenticationRecovery.activityPayload,
                        createdAt: metadata.createdAt,
                        updatedAt: metadata.createdAt,
                        seq: metadata.seq,
                        revision: metadata.revision ?? 0
                    ),
                    metadata,
                    fallbackSessionID
                ))
            } else {
                output.messageMutations.append(.system(L10n.format("ui.run_error_value", payload.message), id, .error, metadata))
            }
            output.messageMutations.append(.resolveLatestPendingApproval(id))
            output.messageMutations.append(.resolveLatestPendingUserInput(id, skipped: false))
            output.messageMutations.append(.turnLifecycle(.failed, metadata, fallbackSessionID))
        case .unknown(let type):
            let eventType = type.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !eventType.isEmpty,
                  reportedUnsupportedEventTypes.insert(eventType).inserted
            else {
                break
            }
            // 新版 runtime 可能先增加事件再升级客户端。诊断区每种类型只提示一次，
            // 避免高频心跳/进度事件把用户真正关心的输出淹没。
            output.logAppends.append(EventReducerLogAppend(
                text: L10n.format("ui.agentd_ignored_unsupported_event_value", eventType),
                sessionID: fallbackSessionID,
                seq: nil
            ))
        }

        return output
    }

    private func setActiveTurnIfPresent(
        _ metadata: AgentEventMetadata,
        fallbackSessionID: SessionID,
        output: inout EventReducerOutput
    ) {
        guard let turnID = metadata.turnID, !turnID.isEmpty else {
            return
        }
        output.activeTurnMutations.append(.set(metadata.sessionID ?? fallbackSessionID, turnID))
    }

    private func contextStatusType(from status: String) -> String {
        switch status {
        case "running", "waiting_for_approval", "waiting_for_input":
            return "active"
        case "failed":
            return "systemError"
        case "history":
            return "notLoaded"
        default:
            return status
        }
    }

    private func shouldClearPendingApproval(for status: String) -> Bool {
        switch status {
        case "running", "waiting_for_approval", "waiting_for_input":
            // 实时事件可能乱序：approval_request 后又到一条泛化 running 状态时，不能把审批入口抹掉。
            return false
        default:
            return true
        }
    }

    private func shouldClearPendingUserInput(for status: String) -> Bool {
        switch status {
        case "running", "waiting_for_approval", "waiting_for_input":
            // 和审批一致：泛化 running/active 事件不能抹掉仍在等待的补充信息卡。
            return false
        default:
            return true
        }
    }

    private func isRunningStatus(_ status: String) -> Bool {
        switch status {
        case "running", "waiting_for_approval", "waiting_for_input":
            return true
        default:
            return false
        }
    }
}
