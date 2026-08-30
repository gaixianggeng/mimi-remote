import Foundation

struct HistoryItemEnrichmentWork {
    let continuation: HistoryTurnItemsContinuation
    let historyPageOrdinal: Int
    let retryCount: Int

    var pageKey: HistoryItemEnrichmentPageKey {
        HistoryItemEnrichmentPageKey(
            turnID: continuation.turnID,
            cursor: continuation.cursor
        )
    }
}

struct HistoryItemEnrichmentBufferedPage {
    let historyPageOrdinal: Int
    let turnIndex: Int
    let itemOffset: Int
    let messages: [CodexHistoryMessage]
}

struct HistoryItemEnrichmentPageKey: Hashable {
    let turnID: TurnID
    let cursor: String?
}

struct HistoryItemEnrichmentState {
    let token: UUID
    let hostScope: HostScope
    var pending: [HistoryItemEnrichmentWork]
    var queuedPageKeys: Set<HistoryItemEnrichmentPageKey>
    var seenPageKeys: Set<HistoryItemEnrichmentPageKey> = []
    var oldestHistoryPageOrdinal: Int
    var loadedItemIDsByTurnID: [TurnID: Set<AgentItemID>] = [:]
    var bufferedPages: [HistoryItemEnrichmentBufferedPage] = []
    var bufferedAuthoritativeItems: [TurnID: Set<AgentItemID>] = [:]
    var didPublish = false
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
        if var state = historyItemEnrichmentBySessionID[sessionID],
           state.hostScope == appStore.activeHostScope {
            let historyPageOrdinal = state.oldestHistoryPageOrdinal - 1
            let work = Self.historyItemEnrichmentWork(
                page: page,
                historyPageOrdinal: historyPageOrdinal
            )
            let uniqueWork = work.filter {
                !state.seenPageKeys.contains($0.pageKey)
                    && state.queuedPageKeys.insert($0.pageKey).inserted
            }
            guard !uniqueWork.isEmpty else {
                return
            }
            state.oldestHistoryPageOrdinal = historyPageOrdinal
            state.pending.append(contentsOf: uniqueWork)
            historyItemEnrichmentBySessionID[sessionID] = state
            return
        }

        let token = UUID()
        let work = Self.historyItemEnrichmentWork(page: page, historyPageOrdinal: 0)
        historyItemEnrichmentBySessionID[sessionID] = HistoryItemEnrichmentState(
            token: token,
            hostScope: appStore.activeHostScope,
            pending: work,
            queuedPageKeys: Set(work.map(\.pageKey)),
            oldestHistoryPageOrdinal: 0,
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
                    markHistoryItemEnrichmentFailed(work: work, sessionID: sessionID, token: token)
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
        state.queuedPageKeys.remove(work.pageKey)
        guard state.seenPageKeys.insert(work.pageKey).inserted else {
            state.didFail = true
            historyItemEnrichmentBySessionID[sessionID] = state
            return
        }
        let turnID = work.continuation.turnID
        state.loadedItemIDsByTurnID[turnID, default: []].formUnion(page.itemIDs)
        if let continuation = page.continuation {
            // 每个 Turn 先补一页，再轮转到下一个 Turn。这样最新页面中的媒体引用会尽快出现，
            // 同时不会让一个极端大 Turn 独占整条 SSH 链路。
            let nextWork = HistoryItemEnrichmentWork(
                continuation: continuation,
                historyPageOrdinal: work.historyPageOrdinal,
                retryCount: 0
            )
            if state.seenPageKeys.contains(nextWork.pageKey) {
                // A→B→A 等 cursor 环路不是分页完成。保留已经加载的内容，但不能把
                // 不完整 Item 集合当作权威快照去删除当前时间线中的消息。
                state.didFail = true
                state.loadedItemIDsByTurnID.removeValue(forKey: turnID)
            } else if state.queuedPageKeys.insert(nextWork.pageKey).inserted {
                state.pending.append(nextWork)
            }
        } else if Self.isCompletedHistoryTurn(work.continuation.turn) {
            state.bufferedAuthoritativeItems[turnID] = state.loadedItemIDsByTurnID.removeValue(forKey: turnID) ?? []
        } else {
            state.loadedItemIDsByTurnID.removeValue(forKey: turnID)
        }
        state.bufferedPages.append(HistoryItemEnrichmentBufferedPage(
            historyPageOrdinal: work.historyPageOrdinal,
            turnIndex: work.continuation.turnIndex,
            itemOffset: work.continuation.itemOffset,
            messages: page.messages
        ))
        let shouldPublish = !state.didPublish
            || state.bufferedPages.count >= Self.historyItemPagesPerPublish
            || state.pending.isEmpty
        let publication = shouldPublish ? takeHistoryItemPublication(from: &state) : nil
        historyItemEnrichmentBySessionID[sessionID] = state
        publishHistoryItemPublication(publication, sessionID: sessionID)
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
            HistoryItemEnrichmentWork(
                continuation: continuation,
                historyPageOrdinal: work.historyPageOrdinal,
                retryCount: work.retryCount + 1
            ),
            at: 0
        )
        historyItemEnrichmentBySessionID[sessionID] = state
        return true
    }

    private func markHistoryItemEnrichmentFailed(
        work: HistoryItemEnrichmentWork,
        sessionID: SessionID,
        token: UUID
    ) {
        guard var state = historyItemEnrichmentBySessionID[sessionID], state.token == token else {
            return
        }
        state.queuedPageKeys.remove(work.pageKey)
        state.didFail = true
        historyItemEnrichmentBySessionID[sessionID] = state
    }

    private func finishHistoryItemEnrichment(sessionID: SessionID, token: UUID, failed: Bool) {
        guard var state = historyItemEnrichmentBySessionID[sessionID], state.token == token else {
            return
        }
        let publication = takeHistoryItemPublication(from: &state)
        historyItemEnrichmentBySessionID.removeValue(forKey: sessionID)
        publishHistoryItemPublication(publication, sessionID: sessionID)
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

    private static let historyItemPagesPerPublish = 4

    private static func historyItemEnrichmentWork(
        page: HistoryMessagesPage,
        historyPageOrdinal: Int
    ) -> [HistoryItemEnrichmentWork] {
        var seenPageKeys = Set<HistoryItemEnrichmentPageKey>()
        return page.itemContinuations.sorted { $0.turnIndex > $1.turnIndex }.compactMap {
            let work = HistoryItemEnrichmentWork(
                continuation: $0,
                historyPageOrdinal: historyPageOrdinal,
                retryCount: 0
            )
            return seenPageKeys.insert(work.pageKey).inserted ? work : nil
        }
    }

    private typealias HistoryItemPublication = (
        messages: [CodexHistoryMessage],
        authoritativeItems: [TurnID: Set<AgentItemID>]
    )

    private func takeHistoryItemPublication(
        from state: inout HistoryItemEnrichmentState
    ) -> HistoryItemPublication? {
        guard !state.bufferedPages.isEmpty || !state.bufferedAuthoritativeItems.isEmpty else {
            return nil
        }
        // 只发布本批新增页。重放旧页会用冻结的历史快照覆盖已经到达的实时内容，
        // 同时让累计工作量退化为 O(P²)。Reducer 的增量模式只在同一 Turn 内建立顺序。
        let orderedPages = state.bufferedPages.sorted { lhs, rhs in
            if lhs.historyPageOrdinal != rhs.historyPageOrdinal {
                return lhs.historyPageOrdinal < rhs.historyPageOrdinal
            }
            if lhs.turnIndex != rhs.turnIndex {
                return lhs.turnIndex < rhs.turnIndex
            }
            return lhs.itemOffset < rhs.itemOffset
        }
        let publication = (
            messages: orderedPages.flatMap(\.messages),
            authoritativeItems: state.bufferedAuthoritativeItems
        )
        state.bufferedPages = []
        state.bufferedAuthoritativeItems = [:]
        state.didPublish = true
        return publication
    }

    private func publishHistoryItemPublication(
        _ publication: HistoryItemPublication?,
        sessionID: SessionID
    ) {
        guard let publication else {
            return
        }
        // summary 文案已经首屏显示。Item 页只把首个媒体批次立即交给 UI，后续每四页
        // 合并一次，避免每个 SSH 响应都触发整条时间线重投影和 List diff。
        conversationStore.setHistory(
            publication.messages,
            sessionID: sessionID,
            authoritativeCompletedTurnItems: publication.authoritativeItems,
            timelineMutationKind: .enrichment
        )
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
