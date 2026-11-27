import Foundation

// 线程目标（thread/goal/*）：按通道声明的能力判断入口，并读写选中会话的目标（#791）。
extension SessionStore {
    func supportsThreadGoals(runtimeProvider: String?) -> Bool {
        RuntimeFeatureSupport.supportsGoals(for: runtimeProvider ?? "codex", declaredBy: threadGoalRuntimeProviders)
    }

    func supportsPreserveThreadPermissions(runtimeProvider: String?) -> Bool {
        RuntimeFeatureSupport.supportsPreserveThreadPermissions(
            for: runtimeProvider ?? "codex",
            declaredBy: preserveThreadPermissionRuntimeProviders
        )
    }

    func supportsTurnSteer(runtimeProvider: String?) -> Bool {
        RuntimeFeatureSupport.supportsTurnSteer(for: runtimeProvider ?? "codex", declaredBy: turnSteerRuntimeProviders)
    }

    /// 探测各 Runtime 通道的可用性与目标/权限继承/引导能力声明（#791 / #1172 / #1177）。
    func refreshRuntimeChannelCapabilities(
        using client: any SessionStoreAPIClient,
        hostScope: HostScope
    ) async -> Bool {
        var available: Set<String> = []
        var unprobed: Set<String> = []
        var goals: Set<String> = []
        var unprobedGoals: Set<String> = []
        var preservePerm: Set<String> = []
        var unprobedPreservePerm: Set<String> = []
        var steer: Set<String> = []
        var unprobedSteer: Set<String> = []
        for provider in RuntimeFeatureSupport.runtimeProviders {
            guard !Task.isCancelled, appStore.activeHostScope == hostScope else { return false }
            do {
                if try await client.runtimeChannelAvailable(runtimeProvider: provider) {
                    guard !Task.isCancelled, appStore.activeHostScope == hostScope else { return false }
                    available.insert(provider)
                    do {
                        if try await client.runtimeSupportsThreadGoals(runtimeProvider: provider) { goals.insert(provider) }
                    } catch { unprobedGoals.insert(provider) }
                    do {
                        if try await client.runtimeSupportsPreserveThreadPermissions(runtimeProvider: provider) {
                            preservePerm.insert(provider)
                        }
                    } catch { unprobedPreservePerm.insert(provider) }
                    do {
                        if try await client.runtimeSupportsTurnSteer(runtimeProvider: provider) { steer.insert(provider) }
                    } catch { unprobedSteer.insert(provider) }
                }
            } catch {
                unprobed.insert(provider)
            }
        }
        guard !Task.isCancelled, appStore.activeHostScope == hostScope else { return false }
        available.formUnion(availableRuntimeProviders.intersection(unprobed))
        goals.formUnion(threadGoalRuntimeProviders.intersection(unprobed.union(unprobedGoals)))
        preservePerm.formUnion(preserveThreadPermissionRuntimeProviders.intersection(unprobed.union(unprobedPreservePerm)))
        steer.formUnion(turnSteerRuntimeProviders.intersection(unprobed.union(unprobedSteer)))
        let diagnostics = await client.runtimeChannelDiagnostics()
        guard !Task.isCancelled, appStore.activeHostScope == hostScope else { return false }
        availableRuntimeProviders = available
        runtimeChannelDiagnosticsByProvider = diagnostics
        threadGoalRuntimeProviders = goals
        preserveThreadPermissionRuntimeProviders = preservePerm
        turnSteerRuntimeProviders = steer
        return true
    }

    func refreshSingleRuntimeCapabilities(
        provider: String,
        hostScope: HostScope
    ) async {
        if (try? await clientFactory().runtimeSupportsThreadGoals(runtimeProvider: provider)) == true,
           appStore.activeHostScope == hostScope {
            threadGoalRuntimeProviders.insert(provider)
        }
        if let supportsPreserve = try? await clientFactory().runtimeSupportsPreserveThreadPermissions(runtimeProvider: provider),
           appStore.activeHostScope == hostScope {
            if supportsPreserve { preserveThreadPermissionRuntimeProviders.insert(provider) } else { preserveThreadPermissionRuntimeProviders.remove(provider) }
        }
        if let supportsSteer = try? await clientFactory().runtimeSupportsTurnSteer(runtimeProvider: provider),
           appStore.activeHostScope == hostScope {
            if supportsSteer { turnSteerRuntimeProviders.insert(provider) } else { turnSteerRuntimeProviders.remove(provider) }
        }
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
