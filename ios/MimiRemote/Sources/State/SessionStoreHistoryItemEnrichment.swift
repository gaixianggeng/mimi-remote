import Foundation

struct HistoryItemEnrichmentWork {
    let continuation: HistoryTurnItemsContinuation
    let retryCount: Int
}

struct HistoryItemEnrichmentState {
    let token: UUID
    let hostScope: HostScope
    var pending: [HistoryItemEnrichmentWork]
    var loadedItemIDsByTurnID: [TurnID: Set<AgentItemID>] = [:]
    var didFail = false
    var task: Task<Void, Never>?
}

@MainActor
extension SessionStore {
    func replaceHistoryItemEnrichment(page: HistoryMessagesPage, sessionID: SessionID) {
        cancelHistoryItemEnrichment(sessionID: sessionID, markIncomplete: false)
        appendHistoryItemEnrichment(page: page, sessionID: sessionID)
    }

    func appendHistoryItemEnrichment(page: HistoryMessagesPage, sessionID: SessionID) {
        guard page.loadMode == .full, !page.itemContinuations.isEmpty else {
            return
        }
        let work = page.itemContinuations.sorted { $0.turnIndex > $1.turnIndex }.map {
            HistoryItemEnrichmentWork(continuation: $0, retryCount: 0)
        }
        if var state = historyItemEnrichmentBySessionID[sessionID],
           state.hostScope == appStore.activeHostScope {
            state.pending.append(contentsOf: work)
            historyItemEnrichmentBySessionID[sessionID] = state
            return
        }

        let token = UUID()
        historyItemEnrichmentBySessionID[sessionID] = HistoryItemEnrichmentState(
            token: token,
            hostScope: appStore.activeHostScope,
            pending: work,
            task: nil
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runHistoryItemEnrichment(sessionID: sessionID, token: token)
        }
        historyItemEnrichmentBySessionID[sessionID]?.task = task
    }

    func cancelHistoryItemEnrichment(sessionID: SessionID, markIncomplete: Bool) {
        guard let state = historyItemEnrichmentBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        state.task?.cancel()
        if markIncomplete {
            historyLoadedQualityBySessionID[sessionID] = .summary
        }
    }

    func cancelAllHistoryItemEnrichment() {
        historyItemEnrichmentBySessionID.values.forEach { $0.task?.cancel() }
        historyItemEnrichmentBySessionID = [:]
    }

    private func runHistoryItemEnrichment(sessionID: SessionID, token: UUID) async {
        let client: SessionStoreAPIClient
        do {
            client = try clientFactory()
        } catch {
            finishHistoryItemEnrichment(sessionID: sessionID, token: token, failed: true)
            return
        }

        while !Task.isCancelled {
            guard let work = dequeueHistoryItemEnrichment(sessionID: sessionID, token: token) else {
                finishHistoryItemEnrichment(sessionID: sessionID, token: token, failed: false)
                return
            }
            do {
                let page = try await client.historyTurnItemsPage(
                    sessionID: sessionID,
                    continuation: work.continuation
                )
                guard isCurrentHistoryItemEnrichment(sessionID: sessionID, token: token) else {
                    return
                }
                applyHistoryItemPage(
                    page,
                    work: work,
                    sessionID: sessionID,
                    token: token
                )
            } catch is CancellationError {
                return
            } catch {
                guard await retryHistoryItemEnrichmentIfPossible(
                    work: work,
                    error: error,
                    sessionID: sessionID,
                    token: token
                ) else {
                    markHistoryItemEnrichmentFailed(sessionID: sessionID, token: token)
                    continue
                }
            }
        }
    }

    private func dequeueHistoryItemEnrichment(
        sessionID: SessionID,
        token: UUID
    ) -> HistoryItemEnrichmentWork? {
        guard var state = historyItemEnrichmentBySessionID[sessionID],
              state.token == token,
              state.hostScope == appStore.activeHostScope,
              !state.pending.isEmpty else {
            return nil
        }
        let work = state.pending.removeFirst()
        historyItemEnrichmentBySessionID[sessionID] = state
        return work
    }

    private func applyHistoryItemPage(
        _ page: HistoryTurnItemsPage,
        work: HistoryItemEnrichmentWork,
        sessionID: SessionID,
        token: UUID
    ) {
        guard var state = historyItemEnrichmentBySessionID[sessionID], state.token == token else {
            return
        }
        let turnID = work.continuation.turnID
        state.loadedItemIDsByTurnID[turnID, default: []].formUnion(page.itemIDs)
        var authoritativeItems: [TurnID: Set<AgentItemID>] = [:]
        if let continuation = page.continuation {
            // 每个 Turn 先补一页，再轮转到下一个 Turn。这样最新页面中的媒体引用会尽快出现，
            // 同时不会让一个极端大 Turn 独占整条 SSH 链路。
            state.pending.append(HistoryItemEnrichmentWork(continuation: continuation, retryCount: 0))
        } else if Self.isCompletedHistoryTurn(work.continuation.turn) {
            authoritativeItems[turnID] = state.loadedItemIDsByTurnID.removeValue(forKey: turnID) ?? []
        } else {
            state.loadedItemIDsByTurnID.removeValue(forKey: turnID)
        }
        historyItemEnrichmentBySessionID[sessionID] = state
        conversationStore.setHistory(
            page.messages,
            sessionID: sessionID,
            authoritativeCompletedTurnItems: authoritativeItems
        )
    }

    private func retryHistoryItemEnrichmentIfPossible(
        work: HistoryItemEnrichmentWork,
        error: Error,
        sessionID: SessionID,
        token: UUID
    ) async -> Bool {
        guard work.retryCount < 3,
              let failure = historyPolicyFailure(from: error) else {
            return false
        }
        var continuation = work.continuation
        if failure.reason == "history_response_too_large", continuation.pageLimit > 1 {
            continuation = continuation.withPageLimit(Self.nextHistoryItemPageLimit(below: continuation.pageLimit))
        } else if failure.reason == "history_budget_limited" {
            let delay = failure.retryAfterNanoseconds ?? historyPolicyRetryFallbackNanoseconds
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else {
                return false
            }
        } else {
            return false
        }
        guard var state = historyItemEnrichmentBySessionID[sessionID], state.token == token else {
            return false
        }
        state.pending.insert(
            HistoryItemEnrichmentWork(continuation: continuation, retryCount: work.retryCount + 1),
            at: 0
        )
        historyItemEnrichmentBySessionID[sessionID] = state
        return true
    }

    private func markHistoryItemEnrichmentFailed(sessionID: SessionID, token: UUID) {
        guard var state = historyItemEnrichmentBySessionID[sessionID], state.token == token else {
            return
        }
        state.didFail = true
        historyItemEnrichmentBySessionID[sessionID] = state
    }

    private func finishHistoryItemEnrichment(sessionID: SessionID, token: UUID, failed: Bool) {
        guard let state = historyItemEnrichmentBySessionID[sessionID], state.token == token else {
            return
        }
        historyItemEnrichmentBySessionID.removeValue(forKey: sessionID)
        guard failed || state.didFail else {
            historyLoadedQualityBySessionID[sessionID] = .full
            return
        }
        historyLoadedQualityBySessionID[sessionID] = .summary
        setHistoryLoadNotice(
            sessionID: sessionID,
            kind: .summaryLoaded,
            message: CodexAppServerSessionRuntime.economyHistoryNotice
        )
    }

    private func isCurrentHistoryItemEnrichment(sessionID: SessionID, token: UUID) -> Bool {
        guard let state = historyItemEnrichmentBySessionID[sessionID] else {
            return false
        }
        return state.token == token && state.hostScope == appStore.activeHostScope
    }

    private static func nextHistoryItemPageLimit(below current: Int) -> Int {
        if current > 20 { return 20 }
        if current > 10 { return 10 }
        return 1
    }

    private static func isCompletedHistoryTurn(_ turn: [String: CodexAppServerJSONValue]) -> Bool {
        let raw = turn["status"]?.stringValue
            ?? turn["status"]?.objectValue?["type"]?.stringValue
            ?? turn["status"]?.objectValue?["status"]?.stringValue
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "succeeded", "success":
            return true
        default:
            return false
        }
    }
}
