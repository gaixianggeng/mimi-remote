import Foundation

// 线程目标（thread/goal/*）：按通道声明的能力判断入口，并读写选中会话的目标（#791）。
extension SessionStore {
    func supportsThreadGoals(runtimeProvider: String?) -> Bool {
        RuntimeFeatureSupport.supportsGoals(for: runtimeProvider ?? "codex", declaredBy: threadGoalRuntimeProviders)
    }

    func refreshSelectedThreadGoal() async {
        guard let sessionID = selectedSessionID else {
            return
        }
        isUpdatingThreadGoal = true
        threadGoalErrorMessage = nil
        defer { isUpdatingThreadGoal = false }
        do {
            let goal = try await clientFactory().threadGoal(threadID: sessionID)
            if let goal {
                applyThreadGoal(goal, fallbackSessionID: sessionID)
            } else {
                clearThreadGoal(sessionID: sessionID)
            }
        } catch {
            threadGoalErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func setThreadGoal(
        threadID: SessionID,
        objective: String?,
        status: ThreadGoalStatus?,
        tokenBudget: Int64?,
        expectedHostScope: HostScope? = nil
    ) async -> Bool {
        let hostScope = expectedHostScope ?? appStore.activeHostScope
        guard appStore.activeHostScope == hostScope else { return false }
        if let session = sessionsByID[threadID],
           isProtocolReadOnlySession(session) {
            threadGoalErrorMessage = L10n.text("ui.read_only")
            return false
        }
        let normalizedObjective = objective?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedObjective, normalizedObjective.isEmpty {
            threadGoalErrorMessage = L10n.text("ui.target_content_cannot_be_empty")
            return false
        }
        if let tokenBudget, tokenBudget <= 0 {
            threadGoalErrorMessage = L10n.text("ui.token_budget_must_be_greater_than_0")
            return false
        }
        isUpdatingThreadGoal = true
        threadGoalErrorMessage = nil
        defer {
            if appStore.activeHostScope == hostScope { isUpdatingThreadGoal = false }
        }
        do {
            let goal = try await clientFactory().setThreadGoal(
                threadID: threadID,
                objective: normalizedObjective,
                status: status,
                tokenBudget: tokenBudget
            )
            guard appStore.activeHostScope == hostScope else { return false }
            if let status, status != .complete {
                clearLocalCompletedGoalMark(goal, sessionID: threadID)
            }
            applyThreadGoal(goal, fallbackSessionID: threadID, respectsLocalCompletion: false)
            setStatusMessage(L10n.text("ui.goal_updated"))
            return true
        } catch {
            guard appStore.activeHostScope == hostScope else { return false }
            threadGoalErrorMessage = error.localizedDescription
            setErrorMessage(for: error)
            return false
        }
    }

    func updateSelectedThreadGoalStatus(_ status: ThreadGoalStatus) async {
        guard let sessionID = selectedSessionID else {
            return
        }
        _ = await setThreadGoal(threadID: sessionID, objective: nil, status: status, tokenBudget: nil)
    }

    func clearSelectedThreadGoal() async {
        guard let sessionID = selectedSessionID else {
            return
        }
        if let session = sessionsByID[sessionID],
           isProtocolReadOnlySession(session) {
            threadGoalErrorMessage = L10n.text("ui.read_only")
            return
        }
        isUpdatingThreadGoal = true
        threadGoalErrorMessage = nil
        defer { isUpdatingThreadGoal = false }
        do {
            try await clientFactory().clearThreadGoal(threadID: sessionID)
            clearThreadGoal(sessionID: sessionID)
            setStatusMessage(L10n.text("ui.target_cleared"))
        } catch {
            threadGoalErrorMessage = error.localizedDescription
            setErrorMessage(for: error)
        }
    }
}
