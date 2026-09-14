import Foundation

/// 时间线尾部“进行中”状态行的展示模型：`时长 · N tokens · 当前阶段…`。
///
/// 只保存与时间无关的输入；时长、无事件时长和警示态都在渲染时按当前时间计算，
/// 这样行视图可以用每秒一次的 TimelineView 刷新文字，而不必让整条时间线重算。
struct ConversationLiveStatus: Equatable {
    enum Phase: Equatable {
        case thinking
        case planning
        case exploring
        case runningCommand
        case editingFiles
        case callingTools
        case replying
        case waitingForApproval
        case waitingForInput

        var title: String {
            switch self {
            case .thinking:
                return L10n.text("ui.live_status_thinking")
            case .planning:
                return L10n.text("ui.live_status_planning")
            case .exploring:
                return L10n.text("ui.live_status_exploring")
            case .runningCommand:
                return L10n.text("ui.live_status_running_command")
            case .editingFiles:
                return L10n.text("ui.live_status_editing_files")
            case .callingTools:
                return L10n.text("ui.live_status_calling_tools")
            case .replying:
                return L10n.text("ui.live_status_replying")
            case .waitingForApproval:
                return L10n.text("ui.live_status_waiting_for_approval")
            case .waitingForInput:
                return L10n.text("ui.live_status_waiting_for_input")
            }
        }
    }

    enum Connection: Equatable {
        case connected
        case reconnecting
        case disconnected
    }

    let phase: Phase
    let startedAt: Date?
    let lastActivityAt: Date?
    let outputTokens: Int?
    let connection: Connection

    /// 连接正常但超过该时长没有任何 runtime 事件时转为警示态，与导航栏副标题同一阈值。
    static let staleThreshold = RuntimeActivityDisplay.staleThreshold

    static func make(
        session: AgentSession?,
        messages: [ConversationMessage],
        foregroundActivity: SessionForegroundActivity?,
        runtimeActivity: RuntimeActivitySnapshot?,
        tokenCounter: TurnOutputTokenCounter?,
        webSocketStatus: WebSocketStatus
    ) -> ConversationLiveStatus? {
        guard let session, session.isRunning else {
            return nil
        }
        let phase = phase(session: session, messages: messages, foregroundActivity: foregroundActivity)
        return ConversationLiveStatus(
            phase: phase,
            startedAt: startedAt(
                runtimeActivity: runtimeActivity,
                observedTurnStart: tokenCounter?.observedTurnStart == true
                    && tokenCounter?.turnID == session.activeTurnID,
                activeTurnID: session.activeTurnID,
                messages: messages
            ),
            lastActivityAt: runtimeActivity?.lastActivityAt,
            outputTokens: tokenCounter?.displayOutputTokens(activeTurnID: session.activeTurnID),
            connection: connection(for: webSocketStatus)
        )
    }

    static func phase(
        session: AgentSession,
        messages: [ConversationMessage],
        foregroundActivity: SessionForegroundActivity?
    ) -> Phase {
        if session.pendingApproval != nil || session.status == SessionStatus.waitingForApproval.rawValue {
            return .waitingForApproval
        }
        if session.pendingUserInput != nil || session.status == SessionStatus.waitingForInput.rawValue {
            return .waitingForInput
        }
        if foregroundActivity == .receivingAssistant {
            return .replying
        }
        // 只看本轮：从尾部回溯到最近一条用户消息为止，取最新一条仍在进行的过程项。
        for message in messages.reversed() {
            if message.role == .user {
                break
            }
            if message.role == .assistant, message.kind == .message, message.sendStatus == .sending {
                return .replying
            }
            guard let payload = message.activityPayload, payload.isInProgress,
                  let phase = phase(for: payload) else {
                continue
            }
            return phase
        }
        return .thinking
    }

    private static func phase(for payload: ConversationActivityPayload) -> Phase? {
        switch payload.category {
        case .thinking:
            return .thinking
        case .plan:
            return .planning
        case .runCommand:
            return payload.commandPresentationKind == .exploration ? .exploring : .runningCommand
        case .editFile:
            return .editingFiles
        case .toolCall:
            return .callingTools
        case .error:
            return nil
        }
    }

    /// 看到了本轮 `turn/started` 时直接用它的时间。冷启动时运行时快照只能用会话更新时间兜底，
    /// 此时若本轮用户消息更早，就用它更接近真实开始；上一轮或自主 turn 的用户消息不参与。
    private static func startedAt(
        runtimeActivity: RuntimeActivitySnapshot?,
        observedTurnStart: Bool,
        activeTurnID: TurnID?,
        messages: [ConversationMessage]
    ) -> Date? {
        if observedTurnStart, let turnStartedAt = runtimeActivity?.turnStartedAt {
            return turnStartedAt
        }
        let turnUserMessageAt = messages.last(where: { $0.role == .user })
            .flatMap { message -> Date? in
                guard !message.isTimestampFallback,
                      message.turnID == nil || activeTurnID == nil || message.turnID == activeTurnID else {
                    return nil
                }
                return message.createdAt
            }
        switch (runtimeActivity?.turnStartedAt, turnUserMessageAt) {
        case let (snapshot?, message?):
            return min(snapshot, message)
        case let (snapshot?, nil):
            return snapshot
        case let (nil, message?):
            return message
        case (nil, nil):
            return nil
        }
    }

    private static func connection(for status: WebSocketStatus) -> Connection {
        switch status {
        case .connected:
            return .connected
        case .connecting:
            return .reconnecting
        case .disconnected, .failed, .terminated:
            return .disconnected
        }
    }

    func idleDuration(at now: Date) -> TimeInterval? {
        lastActivityAt.map { max(0, now.timeIntervalSince($0)) }
    }

    func isWarning(at now: Date) -> Bool {
        connection != .connected || isStale(at: now)
    }

    /// 等审批、等输入时是在等用户，长时间没有事件是正常的，不算停滞。
    func isStale(at now: Date) -> Bool {
        switch phase {
        case .waitingForApproval, .waitingForInput:
            return false
        default:
            return (idleDuration(at: now) ?? 0) > Self.staleThreshold
        }
    }

    /// 断线时无法确认仍在运行，动画停下；其余情况（包括长时间无事件）继续转动。
    var animates: Bool {
        connection == .connected
    }

    func text(at now: Date) -> String {
        var parts: [String] = []
        if let startedAt {
            parts.append(ConversationWorkGroup.durationText(max(0, now.timeIntervalSince(startedAt))))
        }
        if let outputTokens {
            parts.append(L10n.format("ui.live_status_tokens_value", Self.compactTokenCount(outputTokens)))
        }
        switch connection {
        case .connected:
            parts.append(phase.title)
            if isStale(at: now), let idle = idleDuration(at: now) {
                parts.append(L10n.format(
                    "ui.live_status_no_new_events_value",
                    ConversationWorkGroup.durationText(idle)
                ))
            }
        case .reconnecting:
            parts.append(L10n.text("ui.live_status_reconnecting"))
        case .disconnected:
            parts.append(L10n.text("ui.live_status_disconnected"))
        }
        return parts.joined(separator: " · ")
    }

    static func compactTokenCount(_ count: Int) -> String {
        func scaled(_ value: Double, suffix: String) -> String {
            let rounded = (value * 10).rounded(.down) / 10
            let text = rounded.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(rounded))
                : String(format: "%.1f", rounded)
            return text + suffix
        }
        if count >= 1_000_000 {
            return scaled(Double(count) / 1_000_000, suffix: "M")
        }
        if count >= 1_000 {
            return scaled(Double(count) / 1_000, suffix: "k")
        }
        return String(max(0, count))
    }
}
