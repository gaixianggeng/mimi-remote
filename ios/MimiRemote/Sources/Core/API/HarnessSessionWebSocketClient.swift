import Foundation

/// H01 骨架：原生 Harness 事件客户端接缝。
///
/// 面向既有 `SessionWebSocketClient` 协议，所以 `MultiRuntimeSessionWebSocketClient`
/// 不必再要求所有实现都是 `CodexAppServerSessionWebSocketClient`。Codex guidance 的
/// 结果回调保活路径由包装器按具体类型保留，不因为改成协议类型而丢掉所有权。
///
/// 这一层只做显式拒绝：连接即报 failed，所有发送返回 false 并回传失败文案。
/// 绝不返回「看起来成功」的假结果——那会让上层以为原生通道已经可用。
final class HarnessSessionWebSocketClient: SessionWebSocketClient {
    let endpoint: String
    let token: String
    let sessionID: SessionID

    var turnDeliveryMode: TurnDeliveryMode { .direct }
    var onEvent: (@MainActor (AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendAccepted: ((ClientMessageID?) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?
    var onTurnSendOutcome: ((ClientMessageID?, TurnSendOutcome) -> Void)?
    var onApprovalDecisionFailure: ((String, String) -> Void)?
    var onUserInputResponseFailure: ((String, String, Bool) -> Void)?
    var onControlFailure: ((String) -> Void)?

    init(endpoint: String, token: String, sessionID: SessionID) {
        self.endpoint = endpoint
        self.token = token
        self.sessionID = sessionID
    }

    func connect(sessionID: SessionID) {
        connect(sessionID: sessionID, replayBufferedEvents: true)
    }

    func connect(sessionID: SessionID, replayBufferedEvents: Bool) {
        onStatus?(.failed(HarnessNativeUnavailableError.notImplemented(
            operation: "session/follow"
        ).localizedDescription))
    }

    func disconnect() {}

    @discardableResult
    func sendInput(_ text: String, clientMessageID: ClientMessageID?) -> Bool {
        reject(clientMessageID, operation: "session/prompt")
    }

    @discardableResult
    func sendTurn(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) -> Bool {
        reject(clientMessageID, operation: "session/prompt")
    }

    /// Harness 不支持 guidance：必须显式拒绝，**不得**把它当成普通 prompt 发出去。
    @discardableResult
    func sendGuidance(
        _ payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID?,
        expectedTurnID: TurnID
    ) -> Bool {
        reject(clientMessageID, operation: "guidance")
    }

    @discardableResult
    func sendCtrlC(expectedTurnID: TurnID) -> Bool {
        reject(nil, operation: "session/cancel")
    }

    @discardableResult
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        onApprovalDecisionFailure?(approvalID, HarnessNativeUnavailableError.notImplemented(
            operation: "$events/result"
        ).localizedDescription)
        return false
    }

    @discardableResult
    func sendUserInputResponse(requestID: String, answers: [String: [String]]) -> Bool {
        onUserInputResponseFailure?(requestID, HarnessNativeUnavailableError.notImplemented(
            operation: "$events/result"
        ).localizedDescription, false)
        return false
    }

    func acknowledgeAppliedEvent(_ event: AgentEvent) {}

    @discardableResult
    private func reject(_ clientMessageID: ClientMessageID?, operation: String) -> Bool {
        onSendFailure?(clientMessageID, HarnessNativeUnavailableError.notImplemented(
            operation: operation
        ).localizedDescription)
        return false
    }
}
