import Foundation

/// 用户点卡片时捕获的不可变目标。selectionLease 绑定主机、项目和会话，connectionGeneration
/// 绑定当前前台 Socket；identity 再绑定具体 turn/item，避免页面切换或重连后误发动作。
struct ConversationTurnHintActionTarget {
    let submissionContext: TurnSubmissionContext
    let connectionGeneration: Int
    let identity: ConversationTurnHintIdentity
    let sessionID: SessionID

    var hostScope: HostScope { submissionContext.hostScope }
    var selectionLease: SessionSelectionLease { submissionContext.selectionLease }

    init?(
        submissionContext: TurnSubmissionContext,
        connectionGeneration: Int,
        message: ConversationMessage
    ) {
        guard let session = submissionContext.session,
              let identity = ConversationTurnHintIdentity(message: message) else {
            return nil
        }
        self.submissionContext = submissionContext
        self.connectionGeneration = connectionGeneration
        self.identity = identity
        sessionID = session.id
    }

    func isCurrent(
        hostScope currentHostScope: HostScope,
        selectionLease currentSelectionLease: SessionSelectionLease,
        connectionGeneration currentConnectionGeneration: Int,
        session: AgentSession?,
        messages: [ConversationMessage]
    ) -> Bool {
        guard hostScope == currentHostScope,
              selectionLease == currentSelectionLease,
              connectionGeneration == currentConnectionGeneration,
              let session,
              session.id == sessionID,
              session.allowsDirectInput,
              !session.isRunning else {
            return false
        }
        return ConversationTurnHintActionPolicy.isLatestActionableHint(identity, in: messages)
    }
}

@MainActor
extension SessionStore {
    /// 同步捕获点击目标；调用方必须在创建异步 Task 之前调用。
    func captureTurnHintActionTarget(for message: ConversationMessage) -> ConversationTurnHintActionTarget? {
        guard message.activityPayload?.turnHint?.kind == .nextStep else { return nil }
        let context = captureTurnSubmissionContext()
        guard let target = ConversationTurnHintActionTarget(
            submissionContext: context,
            connectionGeneration: webSocketConnectionGeneration,
            message: message
        ), isTurnHintActionTargetCurrent(target) else {
            return nil
        }
        return target
    }

    func isTurnHintActionTargetCurrent(_ target: ConversationTurnHintActionTarget) -> Bool {
        let session = sessionsByID[target.sessionID]
        guard session.map({ !isProtocolReadOnlySession($0) }) == true else { return false }
        return target.isCurrent(
            hostScope: appStore.activeHostScope,
            selectionLease: currentSelectionLease(),
            connectionGeneration: webSocketConnectionGeneration,
            session: session,
            messages: conversationStore.messages(for: target.sessionID)
        )
    }

    /// 显式卡片按钮只把建议文本作为新 turn 发回原会话，不解释或执行其中的工作区、PR 等参数。
    @discardableResult
    func sendTurnHintAction(
        _ action: ConversationTurnHint.Action,
        target: ConversationTurnHintActionTarget
    ) async -> Bool {
        let message = action.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, isTurnHintActionTargetCurrent(target) else { return false }

        // 模型目录读取可能跨 await。读取后再次验证完整租约和卡片身份，过期动作不进入发送路径。
        let payload = await payloadResolvingRequiredModel(
            CodexAppServerTurnPayload(prompt: message),
            submissionContext: target.submissionContext
        )
        guard !Task.isCancelled, isTurnHintActionTargetCurrent(target) else { return false }

        let currentContext = captureTurnSubmissionContext()
        guard currentContext.selectionLease == target.selectionLease,
              currentContext.hostScope == target.hostScope,
              currentContext.session?.id == target.sessionID else {
            return false
        }
        // payload 已解析，且上面的 idle 校验保证这里不会把动作当作进行中 turn 的 guidance。
        return await sendTurn(
            payload,
            runningDelivery: .guided,
            submissionContext: currentContext
        )
    }
}
