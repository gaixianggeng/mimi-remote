import Foundation
import SwiftUI

/// 合并浏览工作区会话列表的唯一键（区分主机、工作区路径与已启用运行时集合）。
struct WorkspaceMergedPresentationKey: Hashable {
    let hostScope: HostScope
    let workspaceID: String
    let workspacePath: String
    let enabledRuntimes: [WorkspaceSessionRuntimeChoice]
}

/// 合并浏览首屏任务触发键，供 `WorkspaceRootView` 的 `.task(id:)` 观察。
struct WorkspaceMergedSessionRefreshScope: Equatable {
    let key: WorkspaceMergedPresentationKey?
    let needsInitialLoad: Bool
    var hasNoConfiguredHost: Bool = false
}

/// `@MainActor` 合并工作区会话列表协调器：
/// - 驱动 `WorkspaceMergedSessionEngine` 与 `SessionListRPCBudgetLedger`；
/// - 受控并发（`maxConcurrentRPCs = 2`、单路 `<= 12`、总预算 `<= 16`）拉取已启用运行时首屏与续页；
/// - 复用 `SessionStore.workspaceRuntimeSessionsPage`（保留 Codex canonical single-flight、Claude/Agy WS 与 DeepSeek 原生 HTTP 通道）；
/// - 隔离单路不可用/失败，不让一个坏通道拖垮「全部」列表。
@MainActor
final class WorkspaceMergedSessionCoordinator: ObservableObject {
    private struct Slot {
        var engine: WorkspaceMergedSessionEngine
        var budget: SessionListRPCBudgetLedger
        var visibleLimit: Int
        var isLoading: Bool = false
        var activeInvocationID: UUID?
        var errorMessage: String?
    }

    @Published private var slots: [WorkspaceMergedPresentationKey: Slot] = [:]

    func hasLoadedFirstPage(for key: WorkspaceMergedPresentationKey) -> Bool {
        guard let slot = slots[key] else { return false }
        let active = slot.engine.streams.values.filter { !$0.status.isHostDisabled }
        if active.isEmpty {
            return !slot.engine.streams.isEmpty
        }
        return active.contains { $0.hasLoadedAnyPage || $0.status.isUnavailableOrFailed }
    }

    func loadState(for key: WorkspaceMergedPresentationKey) -> WorkspaceSessionLoadState {
        guard let slot = slots[key] else { return .idle }
        if slot.isLoading {
            return .loading
        }
        let active = slot.engine.streams.values.filter { !$0.status.isHostDisabled }
        if let errorMessage = slot.errorMessage,
           !active.isEmpty,
           active.allSatisfy({ $0.status.isUnavailableOrFailed }) {
            return .failed(errorMessage)
        }
        return hasLoadedFirstPage(for: key) ? .loaded : .idle
    }

    func projection(
        for key: WorkspaceMergedPresentationKey,
        sessionStore: SessionStore
    ) -> WorkspaceMergedProjection {
        let enabledProviders = key.enabledRuntimes.map(\.runtimeProvider)
        let cachedFallback = sessionStore.directoryScopedSessionsUnsorted(
            workspaceID: key.workspaceID,
            runtimeProviders: enabledProviders
        )
        let canonicalByKey = canonicalSessionMap(
            cachedFallback,
            hostScope: key.hostScope
        )
        let slot = slots[key]
        let archivedKeys = archivedCanonicalKeys(
            sessionStore: sessionStore,
            hostScope: key.hostScope,
            engine: slot?.engine,
            canonicalByKey: canonicalByKey
        )
        let createdSessions = newlyCreatedSessions(
            for: key,
            cachedFallback: cachedFallback,
            sessionStore: sessionStore
        )

        if let slot {
            return slot.engine.projection(
                targetVisibleCount: slot.visibleLimit,
                cachedFallbackSessions: cachedFallback,
                canonicalByKey: canonicalByKey,
                archivedKeys: archivedKeys,
                newlyCreatedSessions: createdSessions,
                budgetExhausted: slot.budget.isTotalBudgetExhausted
            )
        }

        let transientEngine = WorkspaceMergedSessionEngine(
            hostScope: key.hostScope,
            enabledRuntimes: key.enabledRuntimes
        )
        return transientEngine.projection(
            targetVisibleCount: SessionStore.initialSessionPageLimit,
            cachedFallbackSessions: cachedFallback,
            canonicalByKey: canonicalByKey,
            archivedKeys: archivedKeys,
            newlyCreatedSessions: createdSessions
        )
    }

    func refresh(
        project: AgentProject,
        key: WorkspaceMergedPresentationKey,
        sessionStore: SessionStore,
        restartFromFirst: Bool = false
    ) async {
        pruneStaleEnabledRuntimeSlots(keeping: key)
        let invocationID = UUID()
        var previousStreams = slots[key]?.engine.streams ?? [:]
        for (runtime, var stream) in previousStreams where stream.status == .loading {
            stream.status = stream.hasLoadedAnyPage ? (stream.hasMore ? .ready : .exhausted) : .idle
            previousStreams[runtime] = stream
        }
        var slot = slots[key] ?? Slot(
            engine: WorkspaceMergedSessionEngine(
                hostScope: key.hostScope,
                enabledRuntimes: key.enabledRuntimes
            ),
            budget: SessionListRPCBudgetLedger(),
            visibleLimit: SessionStore.initialSessionPageLimit
        )
        slot.engine.normalizeLoadingStreams()
        slot.budget = SessionListRPCBudgetLedger()
        slot.isLoading = true
        slot.activeInvocationID = invocationID
        slot.errorMessage = nil
        slots[key] = slot

        // 仅在主机尚无可用通道或某通道此前发生真实故障时重探可用性；
        // 不在每次下拉刷新时重探主机主动关闭的通道（避免制造多余 503 与延迟）。
        if restartFromFirst {
            let shouldRecheckAll = sessionStore.availableRuntimeProviders.isEmpty
            let runtimesToProbe = key.enabledRuntimes.filter { runtime in
                if shouldRecheckAll { return true }
                return previousStreams[runtime]?.status.isUnavailableOrFailed == true
            }
            for runtime in runtimesToProbe {
                guard !Task.isCancelled else { break }
                _ = await sessionStore.retryRuntimeAvailability(runtime.runtimeProvider)
            }
        }
        guard var currentSlot = slots[key], currentSlot.activeInvocationID == invocationID else { return }
        currentSlot.engine.resetForRefresh(availableRuntimeProviders: sessionStore.availableRuntimeProviders)
        currentSlot.budget = SessionListRPCBudgetLedger()
        currentSlot.visibleLimit = SessionStore.initialSessionPageLimit
        slots[key] = currentSlot

        await pumpPages(
            project: project,
            key: key,
            invocationID: invocationID,
            sessionStore: sessionStore,
            restartFromFirst: restartFromFirst,
            previousStreamsForFallback: previousStreams
        )

        guard var finalSlot = slots[key], finalSlot.activeInvocationID == invocationID else { return }
        finalSlot.engine.normalizeLoadingStreams()
        // 若刷新在部分流仍在加载前被取消（例如 SwiftUI .refreshable 提前收起），恢复旧快照避免退化成空白。
        for (runtime, prevStream) in previousStreams where prevStream.hasLoadedAnyPage {
            if let current = finalSlot.engine.streams[runtime],
               !current.hasLoadedAnyPage,
               !current.status.isHostDisabled,
               !current.status.isUnavailableOrFailed {
                finalSlot.engine.restoreStream(runtime, from: prevStream)
            }
        }
        finalSlot.isLoading = false
        slots[key] = finalSlot
    }

    /// 响应冷启动/切主机后 `sessionStore.availableRuntimeProviders` 的异步探测扩展：
    /// 仅把当前为 `.hostDisabled` 但已变为可用的运行时恢复为 `.idle` 并补拉首屏，不清空已加载的流。
    func reconcileAvailableRuntimeProviders(
        project: AgentProject,
        key: WorkspaceMergedPresentationKey,
        sessionStore: SessionStore
    ) async {
        pruneStaleEnabledRuntimeSlots(keeping: key)
        guard var slot = slots[key] else { return }
        let outcome = slot.engine.reconcileAvailableRuntimeProviders(
            sessionStore.availableRuntimeProviders
        )
        guard outcome.didMutate else { return }
        guard outcome.didReviveAnyStream else {
            slots[key] = slot
            return
        }

        slot.engine.normalizeLoadingStreams()
        let invocationID = UUID()
        slot.activeInvocationID = invocationID
        slot.budget = SessionListRPCBudgetLedger()
        slots[key] = slot

        await pumpPages(
            project: project,
            key: key,
            invocationID: invocationID,
            sessionStore: sessionStore,
            restartFromFirst: false
        )

        guard var finalSlot = slots[key], finalSlot.activeInvocationID == invocationID else { return }
        finalSlot.engine.normalizeLoadingStreams()
        finalSlot.isLoading = false
        slots[key] = finalSlot
    }

    func loadMore(
        project: AgentProject,
        key: WorkspaceMergedPresentationKey,
        sessionStore: SessionStore
    ) async {
        guard var slot = slots[key] else {
            await refresh(project: project, key: key, sessionStore: sessionStore, restartFromFirst: false)
            return
        }
        pruneStaleEnabledRuntimeSlots(keeping: key)
        slot.engine.normalizeLoadingStreams()
        let invocationID = UUID()
        let previousLimit = slot.visibleLimit
        let targetLimit = WorkspaceSessionPresentation.nextVisibleLimit(
            current: previousLimit,
            pageSize: SessionStore.expandedSessionPageLimit
        )
        slot.visibleLimit = targetLimit
        slot.activeInvocationID = invocationID
        slot.budget = SessionListRPCBudgetLedger()
        slots[key] = slot

        await pumpPages(
            project: project,
            key: key,
            invocationID: invocationID,
            sessionStore: sessionStore,
            restartFromFirst: false
        )

        guard var updated = slots[key], updated.activeInvocationID == invocationID else { return }
        updated.engine.normalizeLoadingStreams()
        updated.isLoading = false
        let enabledProviders = key.enabledRuntimes.map(\.runtimeProvider)
        let cachedFallback = sessionStore.directoryScopedSessionsUnsorted(
            workspaceID: key.workspaceID,
            runtimeProviders: enabledProviders
        )
        let canonicalByKey = canonicalSessionMap(cachedFallback, hostScope: key.hostScope)
        let archivedKeys = archivedCanonicalKeys(
            sessionStore: sessionStore,
            hostScope: key.hostScope,
            engine: updated.engine,
            canonicalByKey: canonicalByKey
        )
        let createdSessions = newlyCreatedSessions(
            for: key,
            cachedFallback: cachedFallback,
            sessionStore: sessionStore
        )
        let proj = updated.engine.projection(
            targetVisibleCount: updated.visibleLimit,
            cachedFallbackSessions: cachedFallback,
            canonicalByKey: canonicalByKey,
            archivedKeys: archivedKeys,
            newlyCreatedSessions: createdSessions,
            budgetExhausted: updated.budget.isTotalBudgetExhausted
        )
        updated.visibleLimit = WorkspaceSessionPresentation.committedVisibleLimit(
            current: previousLimit,
            target: targetLimit,
            loadedCount: proj.totalLoadedListableCount
        )
        slots[key] = updated
    }

    func retryUnavailable(
        runtime: WorkspaceSessionRuntimeChoice,
        project: AgentProject,
        key: WorkspaceMergedPresentationKey,
        sessionStore: SessionStore
    ) async -> Bool {
        let recovered = await sessionStore.retryRuntimeAvailability(runtime.runtimeProvider)
        guard recovered, var slot = slots[key] else {
            return recovered
        }
        pruneStaleEnabledRuntimeSlots(keeping: key)
        // 仅将该恢复的运行时重新置为待加载并拉取首屏，不打断已加载的其他运行时。
        slot.engine.normalizeLoadingStreams()
        slot.engine.resetStreamToIdle(runtime)
        let invocationID = UUID()
        slot.activeInvocationID = invocationID
        slot.budget = SessionListRPCBudgetLedger()
        slots[key] = slot

        await pumpPages(
            project: project,
            key: key,
            invocationID: invocationID,
            sessionStore: sessionStore,
            restartFromFirst: false
        )

        guard var finalSlot = slots[key], finalSlot.activeInvocationID == invocationID else {
            return true
        }
        finalSlot.engine.normalizeLoadingStreams()
        finalSlot.isLoading = false
        slots[key] = finalSlot
        return true
    }

    func removeWorkspace(workspaceID: String) {
        slots = slots.filter { $0.key.workspaceID != workspaceID }
    }

    func resetAll() {
        slots.removeAll()
    }

    // MARK: - Private

    private func pruneStaleEnabledRuntimeSlots(keeping key: WorkspaceMergedPresentationKey) {
        let hasStale = slots.keys.contains { existingKey in
            existingKey != key
                && existingKey.hostScope == key.hostScope
                && existingKey.workspaceID == key.workspaceID
                && existingKey.workspacePath == key.workspacePath
        }
        guard hasStale else { return }
        slots = slots.filter { existingKey, _ in
            existingKey == key
                || existingKey.hostScope != key.hostScope
                || existingKey.workspaceID != key.workspaceID
                || existingKey.workspacePath != key.workspacePath
        }
    }

    private func pumpPages(
        project: AgentProject,
        key: WorkspaceMergedPresentationKey,
        invocationID: UUID,
        sessionStore: SessionStore,
        restartFromFirst: Bool,
        previousStreamsForFallback: [WorkspaceSessionRuntimeChoice: WorkspaceMergedSessionEngine.StreamState] = [:]
    ) async {
        // 同一 pump 内遭遇 -32080 限流或单路取消的运行时立即记入阻塞集合，避免在 while 波次中紧循环刷爆配额。
        var blockedRuntimesInPump: Set<WorkspaceSessionRuntimeChoice> = []

        // 以有限波次调度并发请求（每波最多同时跑 budget.maxConcurrentRPCs == 2 路），
        // 每收到一批响应即归并、传播子会话归属并重新评估是否已填满目标展示窗口。
        while !Task.isCancelled {
            guard sessionStore.appStore.activeHostScope == key.hostScope,
                  var slot = slots[key],
                  slot.activeInvocationID == invocationID else {
                return
            }

            let enabledProviders = key.enabledRuntimes.map(\.runtimeProvider)
            let cached = sessionStore.directoryScopedSessionsUnsorted(
                workspaceID: key.workspaceID,
                runtimeProviders: enabledProviders
            )
            let canonicalByKey = canonicalSessionMap(cached, hostScope: key.hostScope)
            let archivedKeys = archivedCanonicalKeys(
                sessionStore: sessionStore,
                hostScope: key.hostScope,
                engine: slot.engine,
                canonicalByKey: canonicalByKey
            )

            let currentProjection = slot.engine.projection(
                targetVisibleCount: slot.visibleLimit,
                cachedFallbackSessions: cached,
                canonicalByKey: canonicalByKey,
                archivedKeys: archivedKeys
            )
            guard slot.engine.needsMorePages(
                targetVisibleCount: slot.visibleLimit,
                projection: currentProjection,
                excluding: blockedRuntimesInPump
            ) else {
                return
            }

            let anyIdle = slot.engine.enabledRuntimes.contains {
                !blockedRuntimesInPump.contains($0) && slot.engine.streams[$0]?.status == .idle
            }
            let onlyHealthyForStrict = !anyIdle && currentProjection.totalLoadedListableCount >= slot.visibleLimit

            // 收集本波可并发拉取的运行时（受 SessionListRPCBudgetLedger 原子并发与总预算硬限制）。
            var wave: [(runtime: WorkspaceSessionRuntimeChoice, cursor: String?, excluding: Set<SessionID>, isFirstPage: Bool)] = []
            var planned = blockedRuntimesInPump
            while let nextRuntime = slot.engine.nextRuntimeToFetch(
                excluding: planned,
                onlyHealthyForStrict: onlyHealthyForStrict
            ) {
                let reserveOutcome = slot.budget.reserve(runtimeProvider: nextRuntime.runtimeProvider)
                switch reserveOutcome {
                case .reserved:
                    planned.insert(nextRuntime)
                    let stream = slot.engine.streams[nextRuntime]
                    let isFirst = stream?.hasLoadedAnyPage != true
                    let cursor = isFirst ? nil : stream?.nextCursor
                    let excluding: Set<SessionID> = isFirst
                        ? []
                        : Set((stream?.rawEntries ?? []).map { $0.canonicalKey.sessionID })
                    slot.engine.markLoading(nextRuntime)
                    wave.append((nextRuntime, cursor, excluding, isFirst))
                case .concurrencyLimitReached:
                    break
                case .perRuntimeLimitReached:
                    planned.insert(nextRuntime)
                    continue
                case .totalBudgetExhausted:
                    break
                }
                if reserveOutcome == .concurrencyLimitReached || reserveOutcome == .totalBudgetExhausted {
                    break
                }
            }
            slots[key] = slot
            guard !wave.isEmpty else { return }

            let budget = slot.budget
            let results: [(WorkspaceSessionRuntimeChoice, Bool, Result<SessionsPage, Error>)] = await withTaskGroup(
                of: (WorkspaceSessionRuntimeChoice, Bool, Result<SessionsPage, Error>).self
            ) { group in
                for taskSpec in wave {
                    group.addTask { @MainActor in
                        var hasActiveReservation = true
                        defer {
                            if hasActiveReservation {
                                budget.finish(runtimeProvider: taskSpec.runtime.runtimeProvider)
                            }
                        }
                        let pageLimit = taskSpec.isFirstPage
                            ? SessionStore.initialSessionPageLimit
                            : SessionStore.expandedSessionPageLimit
                        do {
                            let page = try await sessionStore.workspaceRuntimeSessionsPage(
                                projectID: project.id,
                                runtimeProvider: taskSpec.runtime.runtimeProvider,
                                cursor: taskSpec.cursor,
                                limit: pageLimit,
                                excludingListableSessionIDs: taskSpec.excluding,
                                restartFromFirst: restartFromFirst && taskSpec.isFirstPage,
                                fillsPresentationWindow: false,
                                preservesWireOrder: true
                            )
                            return (taskSpec.runtime, taskSpec.isFirstPage, .success(page))
                        } catch {
                            // 若遇到网关瞬态 -32080（同请求仍在执行 / 极短窗口），先释放并发槽并退避等待，
                            // 醒来后重新校验 hostScope / invocationID 并向预算账本申请配额后再重试一次。
                            if let policyFailure = sessionStore.sessionListPolicyFailure(from: error),
                               policyFailure.retryAfterNanoseconds <= 2_000_000_000,
                               !Task.isCancelled {
                                budget.finish(runtimeProvider: taskSpec.runtime.runtimeProvider)
                                hasActiveReservation = false
                                try? await Task.sleep(nanoseconds: policyFailure.retryAfterNanoseconds)
                                guard !Task.isCancelled,
                                      sessionStore.appStore.activeHostScope == key.hostScope,
                                      self.slots[key]?.activeInvocationID == invocationID else {
                                    return (taskSpec.runtime, taskSpec.isFirstPage, .failure(CancellationError()))
                                }
                                guard budget.reserve(runtimeProvider: taskSpec.runtime.runtimeProvider) == .reserved else {
                                    return (taskSpec.runtime, taskSpec.isFirstPage, .failure(error))
                                }
                                hasActiveReservation = true
                                do {
                                    let retried = try await sessionStore.workspaceRuntimeSessionsPage(
                                        projectID: project.id,
                                        runtimeProvider: taskSpec.runtime.runtimeProvider,
                                        cursor: taskSpec.cursor,
                                        limit: pageLimit,
                                        excludingListableSessionIDs: taskSpec.excluding,
                                        restartFromFirst: restartFromFirst && taskSpec.isFirstPage,
                                        fillsPresentationWindow: false,
                                        preservesWireOrder: true
                                    )
                                    return (taskSpec.runtime, taskSpec.isFirstPage, .success(retried))
                                } catch {
                                    return (taskSpec.runtime, taskSpec.isFirstPage, .failure(error))
                                }
                            }
                            return (taskSpec.runtime, taskSpec.isFirstPage, .failure(error))
                        }
                    }
                }
                var collected: [(WorkspaceSessionRuntimeChoice, Bool, Result<SessionsPage, Error>)] = []
                for await item in group {
                    collected.append(item)
                }
                return collected
            }

            guard sessionStore.appStore.activeHostScope == key.hostScope,
                  var updatedSlot = slots[key],
                  updatedSlot.activeInvocationID == invocationID else {
                return
            }
            if Task.isCancelled {
                updatedSlot.engine.normalizeLoadingStreams()
                slots[key] = updatedSlot
                return
            }

            let knownOwnership = sessionStore.knownSubagentOwnershipByCanonicalKey(hostScope: key.hostScope)
            for (runtime, isFirstPage, result) in results {
                switch result {
                case let .success(page):
                    updatedSlot.engine.ingestPage(
                        runtime: runtime,
                        page: page,
                        knownOwnership: knownOwnership,
                        isControlledGlobal: false,
                        isRefresh: isFirstPage
                    )
                case let .failure(error):
                    if isCancellationError(error) {
                        blockedRuntimesInPump.insert(runtime)
                        if let previous = previousStreamsForFallback[runtime], previous.hasLoadedAnyPage {
                            updatedSlot.engine.restoreStream(runtime, from: previous)
                        } else if let existing = updatedSlot.engine.streams[runtime], existing.hasLoadedAnyPage {
                            var preserved = existing
                            preserved.status = preserved.hasMore ? .ready : .exhausted
                            updatedSlot.engine.restoreStream(runtime, from: preserved)
                        } else {
                            updatedSlot.engine.resetStreamToIdle(runtime)
                        }
                    } else if sessionStore.sessionListPolicyFailure(from: error) != nil {
                        blockedRuntimesInPump.insert(runtime)
                        // 短时间连续下拉触发网关 -32080 限流时，若该通道已有已加载列表则保留旧数据，
                        // 不把正常限流渲染成“运行时不可用/返回了部分结果”的误报横幅，并在本次 pump 停止继续请求。
                        if let previous = previousStreamsForFallback[runtime], previous.hasLoadedAnyPage {
                            updatedSlot.engine.restoreStream(runtime, from: previous)
                        } else if let existing = updatedSlot.engine.streams[runtime], existing.hasLoadedAnyPage {
                            var preserved = existing
                            preserved.status = preserved.hasMore ? .ready : .exhausted
                            updatedSlot.engine.restoreStream(runtime, from: preserved)
                        } else {
                            updatedSlot.engine.markFailed(runtime, message: UserFacingError(error).message)
                            updatedSlot.errorMessage = UserFacingError(error).message
                        }
                    } else if isRuntimeUnavailableError(error) {
                        updatedSlot.engine.markUnavailable(runtime, reason: UserFacingError(error).message)
                        updatedSlot.errorMessage = UserFacingError(error).message
                    } else {
                        updatedSlot.engine.markFailed(runtime, message: UserFacingError(error).message)
                        updatedSlot.errorMessage = UserFacingError(error).message
                    }
                }
            }
            slots[key] = updatedSlot
        }
    }

    private func isRuntimeUnavailableError(_ error: Error) -> Bool {
        if case CodexAppServerSessionRuntimeError.gatewayUnavailable = error {
            return true
        }
        return error is HarnessNativeUnavailableError
    }

    private func canonicalSessionMap(
        _ sessions: [AgentSession],
        hostScope: HostScope
    ) -> [CanonicalSessionKey: AgentSession] {
        var map: [CanonicalSessionKey: AgentSession] = [:]
        map.reserveCapacity(sessions.count)
        for item in sessions {
            map[CanonicalSessionKey(session: item, hostScope: hostScope)] = item
        }
        return map
    }

    private func archivedCanonicalKeys(
        sessionStore: SessionStore,
        hostScope: HostScope,
        engine: WorkspaceMergedSessionEngine? = nil,
        canonicalByKey: [CanonicalSessionKey: AgentSession] = [:]
    ) -> Set<CanonicalSessionKey> {
        let archivedIDs = sessionStore.archivedSessionIDs
        guard !archivedIDs.isEmpty else { return [] }
        let selectedID = sessionStore.selectedSessionID
        var result: Set<CanonicalSessionKey> = []
        for item in sessionStore.sessions {
            guard archivedIDs.contains(item.id),
                  item.id != selectedID,
                  !item.isRunning else {
                continue
            }
            result.insert(CanonicalSessionKey(session: item, hostScope: hostScope))
        }
        if let engine {
            for stream in engine.streams.values {
                for raw in stream.rawEntries {
                    guard archivedIDs.contains(raw.canonicalKey.sessionID) else { continue }
                    let liveSession = canonicalByKey[raw.canonicalKey] ?? raw.session
                    guard liveSession.id != selectedID, !liveSession.isRunning else { continue }
                    result.insert(raw.canonicalKey)
                }
            }
        }
        return result
    }

    private func newlyCreatedSessions(
        for key: WorkspaceMergedPresentationKey,
        cachedFallback: [AgentSession],
        sessionStore: SessionStore
    ) -> [AgentSession] {
        guard let workspace = sessionStore.workspacesByID[key.workspaceID] else { return [] }
        var createdKeys: Set<CanonicalSessionKey> = []
        for runtime in key.enabledRuntimes {
            let scopeKey = sessionStore.workspaceDirectoryScopeKey(
                for: workspace,
                runtimeProvider: runtime.runtimeProvider
            )
            if let ids = sessionStore.workspaceCreatedSessionIDsByKey[scopeKey] {
                for id in ids {
                    createdKeys.insert(
                        CanonicalSessionKey(
                            hostScope: key.hostScope,
                            runtimeProvider: runtime.runtimeProvider,
                            sessionID: id
                        )
                    )
                }
            }
        }
        guard !createdKeys.isEmpty else { return [] }
        return cachedFallback.filter {
            createdKeys.contains(CanonicalSessionKey(session: $0, hostScope: key.hostScope))
        }
    }
}
