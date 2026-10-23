import Foundation

struct NativePromptSuggestionTurn: Equatable {
    let lease: HostSessionLease
    let runtimeProvider: String
    let turnID: TurnID
}

/// 只为当前页面实际看到开始和成功完成的同一轮保留一次机会。
/// 输入、切换、断线会丢弃整个状态，历史完成事件不能重新激活已忽略的建议。
struct NativePromptSuggestionState: Equatable {
    private(set) var turn: NativePromptSuggestionTurn?
    private(set) var completed = false
    private(set) var consumed = false
    private(set) var suggestion: AgentPromptSuggestion?

    mutating func start(_ turn: NativePromptSuggestionTurn) {
        guard self.turn != turn else { return }
        self = Self()
        self.turn = turn
    }

    mutating func finish(_ turn: NativePromptSuggestionTurn, succeeded: Bool) {
        guard self.turn == turn, !completed else { return }
        completed = true
        consumed = !succeeded
    }

    mutating func receive(_ suggestion: AgentPromptSuggestion, for turn: NativePromptSuggestionTurn) {
        guard self.turn == turn, completed, !consumed else { return }
        self.suggestion = suggestion
        consumed = true
    }

    mutating func dismiss() {
        suggestion = nil
        consumed = true
    }
}

extension SessionStore {
    func invalidateNativePromptSuggestion() {
        guard nativePromptSuggestionState.turn != nil else { return }
        nativePromptSuggestionState = NativePromptSuggestionState()
    }

    var currentNativePromptSuggestion: AgentPromptSuggestion? {
        guard let turn = nativePromptSuggestionState.turn,
              turn.lease.hostScope == appStore.activeHostScope,
              turn.lease.sessionID == selectedSessionID,
              turn.runtimeProvider == "claude",
              CodexAppServerSessionRuntime.normalizedRuntimeProvider(selectedSession?.runtimeProvider) == "claude",
              nativePromptSuggestionState.suggestion?.connectionGeneration == webSocketConnectionGeneration,
              webSocketStatus == .connected, selectedSession?.isRunning != true else { return nil }
        return nativePromptSuggestionState.suggestion
    }

    func observeNativePromptSuggestion(_ event: AgentEvent, lease: HostSessionLease) {
        switch event {
        case .turnStarted, .turnCompleted, .promptSuggestion, .error:
            break
        default:
            return
        }
        guard lease.hostScope == appStore.activeHostScope,
              lease.sessionID == selectedSessionID,
              webSocketStatus == .connected,
              CodexAppServerSessionRuntime.normalizedRuntimeProvider(selectedSession?.runtimeProvider) == "claude",
              let metadata = metadata(for: event), metadata.sessionID == lease.sessionID else { return }
        let draft = composerDraft(for: .session(lease.sessionID))
        guard draft.text.isEmpty, draft.attachments.isEmpty else {
            invalidateNativePromptSuggestion()
            return
        }
        if case .error = event {
            invalidateNativePromptSuggestion()
            return
        }
        guard let turnID = metadata.turnID, !turnID.isEmpty else { return }
        let turn = NativePromptSuggestionTurn(lease: lease, runtimeProvider: "claude", turnID: turnID)
        switch event {
        case .turnStarted:
            nativePromptSuggestionState.start(turn)
        case .turnCompleted:
            nativePromptSuggestionState.finish(turn, succeeded: metadata.turnLifecycle == .completed)
        case .promptSuggestion(let suggestion, _):
            guard suggestion.connectionGeneration == webSocketConnectionGeneration else { return }
            nativePromptSuggestionState.receive(suggestion, for: turn)
        default:
            break
        }
    }

    /// 接受动作只消费建议；实际输入框也要检查自身尚未回写的文本，之后由用户手动发送。
    func takeNativePromptSuggestion(
        id: String,
        scope: ComposerDraftScopeKey,
        draft: ComposerDraftSnapshot
    ) -> AgentPromptSuggestion? {
        guard scope == .session(selectedSessionID ?? ""),
              draft.text.isEmpty, draft.attachments.isEmpty,
              composerDraft(for: scope).text.isEmpty, composerDraft(for: scope).attachments.isEmpty,
              !fileUploadStore.hasBlockingJob(for: scope),
              let suggestion = currentNativePromptSuggestion, suggestion.id == id else { return nil }
        nativePromptSuggestionState.dismiss()
        return suggestion
    }
}

extension ComposerState {
    @discardableResult
    mutating func insertNativePromptSuggestion(_ suggestion: AgentPromptSuggestion) -> Bool {
        // 空白也属于用户输入；不能用忽略空白的 isEmpty 来覆盖它。
        guard draft.isEmpty, attachments.isEmpty else { return false }
        draft = suggestion.text
        return true
    }
}
