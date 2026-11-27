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
        let cachedFallback = sessionStore.directoryScopedSessions(
            workspaceID: key.workspaceID,
            runtimeProviders: enabledProviders
        )
        let canonicalByKey = canonicalSessionMap(
            cachedFallback,
            hostScope: key.hostScope
        )
        let archivedKeys = archivedCanonicalKeys(
            sessionStore: sessionStore,
            hostScope: key.hostScope
        )
        let createdSessions = newlyCreatedSessions(
            for: key,
            cachedFallback: cachedFallback,
            sessionStore: sessionStore
        )

        if let slot = slots[key] {
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
        let invocationID = UUID()
        let previousStreams = slots[key]?.engine.streams ?? [:]
        var slot = slots[key] ?? Slot(
            engine: WorkspaceMergedSessionEngine(
                hostScope: key.hostScope,
                enabledRuntimes: key.enabledRuntimes
            ),
            budget: SessionListRPCBudgetLedger(),
            visibleLimit: SessionStore.initialSessionPageLimit
        )
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
        currentSlot.budget.reset()
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

    func loadMore(
        project: AgentProject,
        key: WorkspaceMergedPresentationKey,
        sessionStore: SessionStore
    ) async {
        guard var slot = slots[key] else {
            await refresh(project: project, key: key, sessionStore: sessionStore, restartFromFirst: false)
            return
        }
        let invocationID = UUID()
        let previousLimit = slot.visibleLimit
        let targetLimit = WorkspaceSessionPresentation.nextVisibleLimit(
            current: previousLimit,
            pageSize: SessionStore.expandedSessionPageLimit
        )
        slot.visibleLimit = targetLimit
        slot.activeInvocationID = invocationID
        slot.budget.reset()
        slots[key] = slot

        await pumpPages(
            project: project,
            key: key,
            invocationID: invocationID,
            sessionStore: sessionStore,
            restartFromFirst: false
        )

        guard var updated = slots[key], updated.activeInvocationID == invocationID else { return }
        let proj = projection(for: key, sessionStore: sessionStore)
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
        // 仅将该恢复的运行时重新置为待加载并拉取首屏，不打断已加载的其他运行时。
        var freshEngine = slot.engine
        freshEngine.resetStreamToIdle(runtime)
        slot.engine = freshEngine
        let invocationID = UUID()
        slot.activeInvocationID = invocationID
        slot.budget.reset()
        slots[key] = slot

        await pumpPages(
            project: project,
            key: key,
            invocationID: invocationID,
            sessionStore: sessionStore,
            restartFromFirst: false
        )
        return true
    }

    func removeWorkspace(workspaceID: String) {
        slots = slots.filter { $0.key.workspaceID != workspaceID }
    }

    func resetAll() {
        slots.removeAll()
    }

    // MARK: - Private

    private func pumpPages(
        project: AgentProject,
        key: WorkspaceMergedPresentationKey,
        invocationID: UUID,
        sessionStore: SessionStore,
        restartFromFirst: Bool,
        previousStreamsForFallback: [WorkspaceSessionRuntimeChoice: WorkspaceMergedSessionEngine.StreamState] = [:]
    ) async {
        // 以有限波次调度并发请求（每波最多同时跑 budget.maxConcurrentRPCs == 2 路），
        // 每收到一批响应即归并、传播子会话归属并重新评估是否已填满目标展示窗口。
        while !Task.isCancelled {
            guard sessionStore.appStore.activeHostScope == key.hostScope,
                  var slot = slots[key],
                  slot.activeInvocationID == invocationID else {
                return
            }

            let enabledProviders = key.enabledRuntimes.map(\.runtimeProvider)
            let cached = sessionStore.directoryScopedSessions(
                workspaceID: key.workspaceID,
                runtimeProviders: enabledProviders
            )
            let canonicalByKey = canonicalSessionMap(cached, hostScope: key.hostScope)
            let archivedKeys = archivedCanonicalKeys(sessionStore: sessionStore, hostScope: key.hostScope)

            let currentProjection = slot.engine.projection(
                targetVisibleCount: slot.visibleLimit,
                cachedFallbackSessions: cached,
                canonicalByKey: canonicalByKey,
                archivedKeys: archivedKeys
            )
            guard slot.engine.needsMorePages(
                targetVisibleCount: slot.visibleLimit,
                canonicalByKey: canonicalByKey,
                archivedKeys: archivedKeys
            ) else {
                return
            }

            let anyIdle = slot.engine.enabledRuntimes.contains { slot.engine.streams[$0]?.status == .idle }
            let onlyHealthyForStrict = !anyIdle && currentProjection.totalLoadedListableCount >= slot.visibleLimit

            // 收集本波可并发拉取的运行时（受 SessionListRPCBudgetLedger 原子并发与总预算硬限制）。
            var wave: [(runtime: WorkspaceSessionRuntimeChoice, cursor: String?, excluding: Set<SessionID>, isFirstPage: Bool)] = []
            var planned: Set<WorkspaceSessionRuntimeChoice> = []
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
                        defer { budget.finish(runtimeProvider: taskSpec.runtime.runtimeProvider) }
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
                                restartFromFirst: restartFromFirst && taskSpec.isFirstPage
                            )
                            return (taskSpec.runtime, taskSpec.isFirstPage, .success(page))
                        } catch {
                            // 若遇到网关瞬态 -32080（同请求仍在执行 / 极短窗口），退避等待一次再重试。
                            if let policyFailure = sessionStore.sessionListPolicyFailure(from: error),
                               policyFailure.retryAfterNanoseconds <= 2_000_000_000,
                               !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: policyFailure.retryAfterNanoseconds)
                                if !Task.isCancelled {
                                    do {
                                        let retried = try await sessionStore.workspaceRuntimeSessionsPage(
                                            projectID: project.id,
                                            runtimeProvider: taskSpec.runtime.runtimeProvider,
                                            cursor: taskSpec.cursor,
                                            limit: pageLimit,
                                            excludingListableSessionIDs: taskSpec.excluding,
                                            restartFromFirst: restartFromFirst && taskSpec.isFirstPage
                                        )
                                        return (taskSpec.runtime, taskSpec.isFirstPage, .success(retried))
                                    } catch {
                                        return (taskSpec.runtime, taskSpec.isFirstPage, .failure(error))
                                    }
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

            guard !Task.isCancelled,
                  sessionStore.appStore.activeHostScope == key.hostScope,
                  var updatedSlot = slots[key],
                  updatedSlot.activeInvocationID == invocationID else {
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
                        if let previous = previousStreamsForFallback[runtime], previous.hasLoadedAnyPage {
                            updatedSlot.engine.restoreStream(runtime, from: previous)
                        } else if let existing = updatedSlot.engine.streams[runtime], existing.hasLoadedAnyPage {
                            updatedSlot.engine.markFailed(runtime, message: UserFacingError(error).message)
                        } else {
                            updatedSlot.engine.resetStreamToIdle(runtime)
                        }
                    } else if sessionStore.sessionListPolicyFailure(from: error) != nil {
                        // 短时间连续下拉触发网关 -32080 限流时，若该通道已有已加载列表则保留旧数据，
                        // 不把正常限流渲染成“运行时不可用/返回了部分结果”的误报横幅。
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
        hostScope: HostScope
    ) -> Set<CanonicalSessionKey> {
        var result: Set<CanonicalSessionKey> = []
        for item in sessionStore.sessions where sessionStore.isSessionArchived(item.id) {
            result.insert(CanonicalSessionKey(session: item, hostScope: hostScope))
        }
        return result
    }

    private func newlyCreatedSessions(
        for key: WorkspaceMergedPresentationKey,
        cachedFallback: [AgentSession],
        sessionStore: SessionStore
    ) -> [AgentSession] {
        guard let workspace = sessionStore.workspacesByID[key.workspaceID] else { return [] }
        var createdIDs: Set<SessionID> = []
        for runtime in key.enabledRuntimes {
            let scopeKey = sessionStore.workspaceDirectoryScopeKey(
                for: workspace,
                runtimeProvider: runtime.runtimeProvider
            )
            if let ids = sessionStore.workspaceCreatedSessionIDsByKey[scopeKey] {
                createdIDs.formUnion(ids)
            }
        }
        guard !createdIDs.isEmpty else { return [] }
        return cachedFallback.filter { createdIDs.contains($0.id) }
    }
}
