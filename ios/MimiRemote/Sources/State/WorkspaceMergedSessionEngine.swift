import Foundation

/// K 路合并工作区视图的投影结果（供 `WorkspaceDetailView` 直接消费）。
struct WorkspaceMergedProjection: Equatable {
    let visibleSessions: [AgentSession]
    let totalLoadedListableCount: Int
    let strictCommittedCount: Int
    let completeness: WorkspaceMergedCompleteness
    let canLoadMore: Bool
    let hasInitialContent: Bool
    let partialNotice: WorkspaceMergedPartialNotice?
}

/// 纯值、确定性的 K 路跨运行时会话归并状态机（Phase 4，闭合 P1-2a / P1-2b / P1-3d / C1 / C3 / C6 / C8）。
///
/// 核心不变量：
/// 1. 每条会话按 `CanonicalSessionKey(hostScope, runtimeProvider, sessionID)` 唯一标识，同 ID 跨运行时绝不碰撞；
/// 2. 排序与水位线只消费原始服务端排序证据 `RawSortEvidence`（按 `epochMs DESC → runtimeTieRank ASC → streamOrdinal ASC`），
///    隔离本地 `recencyFloor`；
/// 3. P1-2a / P1-2b：计数前先合并 Store 已知与晚页补标的子会话归属（复用 `AgentSession.isSubagentThread`），
///    晚页把已提交展示前缀中的会话补标为子会话时立刻向前缀传播并撤回 `.complete`，自动触发补页；
/// 4. P1-3d：Controlled Global 缺 `pageDisposition` 仅入预览、不推进水位、不判倒挂、不判可信耗尽；
/// 5. 黏性降级：除纯网关 `git_ownership_pending` 同页重试外，任一页降级即 `everDegradedInChain = true`，
///    降级/未验健康流只进预览、不推进水位线。
struct WorkspaceMergedSessionEngine: Equatable {
    enum StreamStatus: Equatable, Sendable {
        case idle
        case loading
        case ready
        case exhausted
        /// 主机侧未启用/未安装的运行时（正常配置差异，不触发错误或降级告警横幅）。
        case hostDisabled
        case unavailable(String?)
        case failed(String)

        var isUnavailableOrFailed: Bool {
            switch self {
            case .unavailable, .failed:
                return true
            default:
                return false
            }
        }

        var isHostDisabled: Bool {
            self == .hostDisabled
        }
    }

    struct RawEntry: Equatable {
        let canonicalKey: CanonicalSessionKey
        var session: AgentSession
        let sortEvidence: RawSortEvidence
        var ownership: SubagentOwnershipEvidence
        let streamOrdinal: Int
    }

    struct StreamState: Equatable {
        let runtime: WorkspaceSessionRuntimeChoice
        var status: StreamStatus = .idle
        var rawEntries: [RawEntry] = []
        var nextCursor: String?
        var hasMore: Bool = true
        var integrity: RuntimeSessionListIntegrity = .trusted
        var everDegradedInChain: Bool = false
        var verifiedTailBoundMs: Int64?
        var orderViolated: Bool = false
        var hasLoadedAnyPage: Bool = false
        var nextStreamOrdinal: Int = 0
        var rpcCount: Int = 0

        var isHealthyForStrictPrefix: Bool {
            integrity == .trusted && !everDegradedInChain && !orderViolated
        }

        var canFetchMore: Bool {
            switch status {
            case .idle:
                return true
            case .ready:
                return hasMore
            case .loading, .exhausted, .hostDisabled, .unavailable, .failed:
                return false
            }
        }
    }

    let hostScope: HostScope
    let enabledRuntimes: [WorkspaceSessionRuntimeChoice]
    private(set) var streams: [WorkspaceSessionRuntimeChoice: StreamState]
    /// 跨页已知子会话归属传播表（按复合键单调累积，实现 P1-2a / P1-2b）。
    private(set) var knownOwnershipByKey: [CanonicalSessionKey: SubagentOwnershipEvidence] = [:]

    init(
        hostScope: HostScope,
        enabledRuntimes: [WorkspaceSessionRuntimeChoice]
    ) {
        self.hostScope = hostScope
        let ordered = WorkspaceSessionRuntimeChoice.allCases.filter { enabledRuntimes.contains($0) }
        self.enabledRuntimes = ordered.isEmpty ? WorkspaceSessionRuntimeChoice.allCases : ordered
        var initialStreams: [WorkspaceSessionRuntimeChoice: StreamState] = [:]
        for runtime in self.enabledRuntimes {
            initialStreams[runtime] = StreamState(runtime: runtime)
        }
        self.streams = initialStreams
    }

    mutating func markLoading(_ runtime: WorkspaceSessionRuntimeChoice) {
        guard var stream = streams[runtime] else { return }
        stream.status = .loading
        streams[runtime] = stream
    }

    mutating func markUnavailable(_ runtime: WorkspaceSessionRuntimeChoice, reason: String? = nil) {
        guard var stream = streams[runtime] else { return }
        stream.status = .unavailable(reason)
        stream.hasMore = false
        streams[runtime] = stream
    }

    mutating func markFailed(_ runtime: WorkspaceSessionRuntimeChoice, message: String) {
        guard var stream = streams[runtime] else { return }
        stream.status = .failed(message)
        streams[runtime] = stream
    }

    mutating func resetStreamToIdle(_ runtime: WorkspaceSessionRuntimeChoice) {
        guard streams[runtime] != nil else { return }
        streams[runtime] = StreamState(runtime: runtime)
    }

    mutating func resetForRefresh(availableRuntimeProviders: Set<String>) {
        knownOwnershipByKey.removeAll()
        for runtime in enabledRuntimes {
            var state = StreamState(runtime: runtime)
            if !availableRuntimeProviders.isEmpty,
               !availableRuntimeProviders.contains(runtime.runtimeProvider) {
                state.status = .hostDisabled
                state.hasMore = false
            }
            streams[runtime] = state
        }
    }

    /// 吸收单路分页结果，完成 P1-2a 已知归属合并、P1-2b 晚页回溯补标、P1-3d 推进判定与水位更新。
    mutating func ingestPage(
        runtime: WorkspaceSessionRuntimeChoice,
        page: SessionsPage,
        knownOwnership: [CanonicalSessionKey: SubagentOwnershipEvidence] = [:],
        isControlledGlobal: Bool = false,
        isRefresh: Bool = false
    ) {
        guard var stream = streams[runtime] else { return }
        if isRefresh {
            stream = StreamState(runtime: runtime)
        }
        stream.rpcCount += 1

        // 1) 合并外部 Store 已知子会话归属。
        for (key, evidence) in knownOwnership where evidence.isSubagent {
            knownOwnershipByKey[key] = evidence.merged(with: knownOwnershipByKey[key])
        }

        // 2) 解析页推进语义与健康度（P1-3d）。
        let disposition = SessionListMeta.resolvedDisposition(
            from: page.listMeta,
            isControlledGlobal: isControlledGlobal
        )
        let pageIntegrity = SessionListMeta.resolvedIntegrity(
            from: page.listMeta,
            runtimeProvider: runtime.runtimeProvider,
            isControlledGlobal: isControlledGlobal
        )

        let isPureGitRetry: Bool
        if case let .samePageRetry(reason) = disposition {
            isPureGitRetry = (reason == "git_ownership_pending")
        } else {
            isPureGitRetry = false
        }

        // 仅显式降级或未确认的 Controlled Global 推进语义记为黏性降级；
        // 旧版服务端缺少 listMeta（.unverifiedHealth）仍限制严格水位，但不误报成“返回了部分结果”。
        let isExplicitDegradation: Bool
        switch pageIntegrity {
        case .degraded, .unverifiedGlobalDisposition:
            isExplicitDegradation = true
        case .trusted, .unverifiedHealth:
            isExplicitDegradation = false
        }
        if isExplicitDegradation && !isPureGitRetry {
            stream.everDegradedInChain = true
        }
        stream.integrity = pageIntegrity

        // 3) 先把本页每条的原始归属写入全局传播表，再对本流既有条执行晚页回溯补标（P1-2b）。
        let existingKeysBeforePage = Set(stream.rawEntries.map(\.canonicalKey))
        var incomingEntries: [RawEntry] = []
        incomingEntries.reserveCapacity(page.sessions.count)
        var pageMinTrustedMs: Int64?
        var pageMaxTrustedMs: Int64?

        for session in page.sessions {
            let key = CanonicalSessionKey(
                hostScope: hostScope,
                runtimeProvider: runtime.runtimeProvider,
                sessionID: session.id
            )
            let wireOwnership = SubagentOwnershipEvidence(session: session)
            let mergedOwnership = wireOwnership.merged(with: knownOwnershipByKey[key])
            if mergedOwnership.isSubagent {
                knownOwnershipByKey[key] = mergedOwnership
            }
            let evidence = page.rawSortEvidenceBySessionID[session.id]
                ?? RawSortEvidence.fromSession(session)

            // 仅本页新发现的非重复会话参与跨页水位推进与倒挂检测，
            // 避免翻页边界重叠或晚页重发旧会话补标子会话归属时误判倒挂。
            if !existingKeysBeforePage.contains(key), let ms = evidence.epochMsValue {
                if let currentMin = pageMinTrustedMs {
                    pageMinTrustedMs = min(currentMin, ms)
                } else {
                    pageMinTrustedMs = ms
                }
                if let currentMax = pageMaxTrustedMs {
                    pageMaxTrustedMs = max(currentMax, ms)
                } else {
                    pageMaxTrustedMs = ms
                }
            }

            let entry = RawEntry(
                canonicalKey: key,
                session: session,
                sortEvidence: evidence,
                ownership: mergedOwnership,
                streamOrdinal: stream.nextStreamOrdinal
            )
            stream.nextStreamOrdinal += 1
            incomingEntries.append(entry)
        }

        // P1-2b：向既有已提交条目回溯传播本页发现的子会话归属（20 → 19 触发自动补页）。
        for idx in stream.rawEntries.indices {
            let key = stream.rawEntries[idx].canonicalKey
            if let propagated = knownOwnershipByKey[key], propagated.isSubagent {
                stream.rawEntries[idx].ownership = stream.rawEntries[idx].ownership.merged(with: propagated)
            }
        }

        // 同流按复合键去重合并：保留原排序证据与较早 streamOrdinal，更新 session 字段与单调归属。
        var indexByKey: [CanonicalSessionKey: Int] = [:]
        indexByKey.reserveCapacity(stream.rawEntries.count)
        for (idx, existing) in stream.rawEntries.enumerated() {
            indexByKey[existing.canonicalKey] = idx
        }
        for incoming in incomingEntries {
            if let existingIdx = indexByKey[incoming.canonicalKey] {
                var updated = stream.rawEntries[existingIdx]
                updated.session = incoming.session
                updated.ownership = updated.ownership.merged(with: incoming.ownership)
                stream.rawEntries[existingIdx] = updated
            } else {
                indexByKey[incoming.canonicalKey] = stream.rawEntries.count
                stream.rawEntries.append(incoming)
            }
        }

        // 4) 按推进语义更新水位线、倒挂检测与耗尽状态（P1-3d）。
        stream.hasLoadedAnyPage = true
        stream.nextCursor = page.nextCursor

        switch disposition {
        case .advance:
            if pageIntegrity.isTrusted && !stream.everDegradedInChain {
                // 仅信任且未降级的推进页可检测跨页倒挂并推进水位线。
                if let prevTail = stream.verifiedTailBoundMs,
                   let incomingMax = pageMaxTrustedMs,
                   incomingMax > prevTail {
                    stream.orderViolated = true
                } else if let incomingMin = pageMinTrustedMs {
                    if let prevTail = stream.verifiedTailBoundMs {
                        stream.verifiedTailBoundMs = min(prevTail, incomingMin)
                    } else {
                        stream.verifiedTailBoundMs = incomingMin
                    }
                }
            }
            stream.hasMore = page.hasMore && page.nextCursor != nil
            stream.status = stream.hasMore ? .ready : .exhausted

        case .samePageRetry:
            // 同页重试：保留预览、水位不变、不判倒挂、不判耗尽，保留重试游标。
            stream.hasMore = page.nextCursor != nil
            stream.status = stream.hasMore ? .ready : .exhausted

        case .unverifiedGlobalDisposition:
            // P1-3d 五项不变量：保留预览、水位不变、不判倒挂、不判可信耗尽、禁撤权。
            stream.hasMore = page.hasMore && page.nextCursor != nil
            stream.status = .ready
        }

        streams[runtime] = stream

        // 也向其他流做跨流归属传播（仅同复合键不会误跨运行时）。
        for otherRuntime in enabledRuntimes where otherRuntime != runtime {
            guard var otherStream = streams[otherRuntime] else { continue }
            var mutated = false
            for idx in otherStream.rawEntries.indices {
                let key = otherStream.rawEntries[idx].canonicalKey
                if let propagated = knownOwnershipByKey[key], propagated.isSubagent, !otherStream.rawEntries[idx].ownership.isSubagent {
                    otherStream.rawEntries[idx].ownership = otherStream.rawEntries[idx].ownership.merged(with: propagated)
                    mutated = true
                }
            }
            if mutated {
                streams[otherRuntime] = otherStream
            }
        }
    }

    /// 计算下一步最值得推进的流：
    /// 1) 优先未加载首屏的 `.idle` 流；
    /// 2) 其次在所有 `canFetchMore == true` 的流中选择 `verifiedTailBoundMs` 最大（即最可能包含最新会话）的流，
    ///    解决 90/10 偏斜展开并确保已耗尽流（如 DeepSeek）增量为 0；
    /// 3) 当 `onlyHealthyForStrict == true` 时，跳过非严格健康流（如旧版服务端 `.unverifiedHealth` 或降级流），
    ///    避免已满足可见条数时仍反复翻页拉取无法提升严格水位的流并触发网关限流。
    func nextRuntimeToFetch(
        excluding inFlight: Set<WorkspaceSessionRuntimeChoice> = [],
        onlyHealthyForStrict: Bool = false
    ) -> WorkspaceSessionRuntimeChoice? {
        let candidates = enabledRuntimes.filter { runtime in
            guard !inFlight.contains(runtime), let stream = streams[runtime] else { return false }
            guard stream.canFetchMore else { return false }
            if onlyHealthyForStrict && stream.status != .idle {
                return stream.isHealthyForStrictPrefix
            }
            return true
        }
        guard !candidates.isEmpty else { return nil }

        // 1) 未首屏加载的流优先。
        if let firstIdle = candidates.first(where: { streams[$0]?.status == .idle }) {
            return firstIdle
        }

        // 2) 选择水位线最高（最靠前）的未耗尽流；未知水位的流次之，再按 tie rank 稳定打破。
        return candidates.max { lhs, rhs in
            let leftBound = streams[lhs]?.verifiedTailBoundMs ?? Int64.min
            let rightBound = streams[rhs]?.verifiedTailBoundMs ?? Int64.min
            if leftBound != rightBound {
                return leftBound < rightBound
            }
            return CanonicalSessionKey.runtimeTieRank(for: lhs.runtimeProvider)
                > CanonicalSessionKey.runtimeTieRank(for: rhs.runtimeProvider)
        }
    }

    /// 投影合并列表与完整度五态。
    func projection(
        targetVisibleCount: Int,
        cachedFallbackSessions: [AgentSession] = [],
        canonicalByKey: [CanonicalSessionKey: AgentSession] = [:],
        archivedKeys: Set<CanonicalSessionKey> = [],
        newlyCreatedSessions: [AgentSession] = [],
        budgetExhausted: Bool = false
    ) -> WorkspaceMergedProjection {
        let clampedTarget = max(1, targetVisibleCount)
        let configuredStreams = enabledRuntimes.compactMap { streams[$0] }
        let activeStreams = configuredStreams.filter { !$0.status.isHostDisabled }

        // 若所有已启用运行时在当前主机均未启用/不可用，展示明确的全不可用诊断。
        if activeStreams.isEmpty {
            return WorkspaceMergedProjection(
                visibleSessions: [],
                totalLoadedListableCount: 0,
                strictCommittedCount: 0,
                completeness: .allUnavailable,
                canLoadMore: false,
                hasInitialContent: true,
                partialNotice: WorkspaceMergedPartialNotice(
                    unavailableRuntimes: configuredStreams.map(\.runtime),
                    degradedRuntimes: []
                )
            )
        }

        let anyLoaded = activeStreams.contains(where: \.hasLoadedAnyPage)
        let allUnavailableOrFailed = activeStreams.allSatisfy { $0.status.isUnavailableOrFailed }

        // 尚未收到任何远端页且非全不可用：返回 `.cachedPreview` 瞬时投影本地 Store 缓存。
        if !anyLoaded && !allUnavailableOrFailed {
            let preview = Self.deduplicatedAndSorted(
                cachedFallbackSessions,
                hostScope: hostScope,
                archivedKeys: archivedKeys
            )
            return WorkspaceMergedProjection(
                visibleSessions: Array(preview.prefix(clampedTarget)),
                totalLoadedListableCount: preview.count,
                strictCommittedCount: 0,
                completeness: .cachedPreview,
                canLoadMore: preview.count > clampedTarget,
                hasInitialContent: !preview.isEmpty,
                partialNotice: nil
            )
        }

        if allUnavailableOrFailed {
            let unavailable = activeStreams.map(\.runtime)
            return WorkspaceMergedProjection(
                visibleSessions: [],
                totalLoadedListableCount: 0,
                strictCommittedCount: 0,
                completeness: .allUnavailable,
                canLoadMore: false,
                hasInitialContent: true,
                partialNotice: WorkspaceMergedPartialNotice(
                    unavailableRuntimes: unavailable,
                    degradedRuntimes: []
                )
            )
        }

        // 计算健康推进流的全局水位线：max(未耗尽健康流的 verifiedTailBoundMs)。
        var watermarkMs: Int64?
        var hasUnexhaustedHealthyStream = false
        for stream in activeStreams where stream.isHealthyForStrictPrefix {
            if stream.status == .ready && stream.hasMore {
                hasUnexhaustedHealthyStream = true
                if let tail = stream.verifiedTailBoundMs {
                    if let current = watermarkMs {
                        watermarkMs = max(current, tail)
                    } else {
                        watermarkMs = tail
                    }
                } else {
                    // 存在尚无水位线的健康活跃流：严格前缀暂不能下移到任何历史时间戳。
                    watermarkMs = Int64.max
                }
            } else if stream.status == .idle || stream.status == .loading {
                hasUnexhaustedHealthyStream = true
                watermarkMs = Int64.max
            }
        }

        struct RankedEntry {
            let key: CanonicalSessionKey
            let session: AgentSession
            let sortEvidence: RawSortEvidence
            let runtimeTieRank: Int
            let streamOrdinal: Int
            let isStrict: Bool
        }

        var rankedByKey: [CanonicalSessionKey: RankedEntry] = [:]
        var strictKeys: Set<CanonicalSessionKey> = []

        for stream in activeStreams {
            for raw in stream.rawEntries {
                // 过滤归档与已识别的子会话（复用 isSubagentThread 合并归属，P1-2a/2b）。
                guard !archivedKeys.contains(raw.canonicalKey) else { continue }
                let canonical = canonicalByKey[raw.canonicalKey]
                let mergedOwnership = raw.ownership
                    .merged(with: knownOwnershipByKey[raw.canonicalKey])
                    .merged(with: canonical.map(SubagentOwnershipEvidence.init(session:)))
                guard !mergedOwnership.isSubagent else { continue }

                let liveSession = canonical ?? raw.session
                let eligibleStrict: Bool
                if stream.isHealthyForStrictPrefix, let ms = raw.sortEvidence.epochMsValue {
                    if !hasUnexhaustedHealthyStream {
                        eligibleStrict = true
                    } else if let wm = watermarkMs, wm != Int64.max {
                        eligibleStrict = ms >= wm
                    } else {
                        eligibleStrict = false
                    }
                } else {
                    eligibleStrict = false
                }

                let candidate = RankedEntry(
                    key: raw.canonicalKey,
                    session: liveSession,
                    sortEvidence: raw.sortEvidence,
                    runtimeTieRank: raw.canonicalKey.runtimeTieRank,
                    streamOrdinal: raw.streamOrdinal,
                    isStrict: eligibleStrict
                )
                rankedByKey[raw.canonicalKey] = candidate
                if eligibleStrict {
                    strictKeys.insert(raw.canonicalKey)
                }
            }
        }

        // 补入本设备新创建的会话（不因旧首屏未包含而消失）。
        for created in newlyCreatedSessions {
            let key = CanonicalSessionKey(session: created, hostScope: hostScope)
            guard !archivedKeys.contains(key),
                  rankedByKey[key] == nil,
                  !SubagentOwnershipEvidence(session: created).isSubagent else {
                continue
            }
            let evidence = RawSortEvidence.fromSession(created)
            rankedByKey[key] = RankedEntry(
                key: key,
                session: canonicalByKey[key] ?? created,
                sortEvidence: evidence,
                runtimeTieRank: key.runtimeTieRank,
                streamOrdinal: -1,
                isStrict: true
            )
            strictKeys.insert(key)
        }

        let sortedAll = rankedByKey.values.sorted { lhs, rhs in
            Self.compareEntries(
                leftEvidence: lhs.sortEvidence,
                leftRank: lhs.runtimeTieRank,
                leftOrdinal: lhs.streamOrdinal,
                leftID: lhs.key.sessionID,
                rightEvidence: rhs.sortEvidence,
                rightRank: rhs.runtimeTieRank,
                rightOrdinal: rhs.streamOrdinal,
                rightID: rhs.key.sessionID
            )
        }

        let strictListableCount = sortedAll.filter(\.isStrict).count

        let unavailableRuntimes = activeStreams
            .filter { $0.status.isUnavailableOrFailed }
            .map(\.runtime)
        let degradedRuntimes = activeStreams
            .filter {
                !$0.status.isUnavailableOrFailed
                    && $0.hasLoadedAnyPage
                    && ($0.everDegradedInChain || $0.orderViolated)
            }
            .map(\.runtime)
        let unverifiedStreamsPresent = activeStreams.contains {
            !$0.status.isUnavailableOrFailed && $0.hasLoadedAnyPage && !$0.isHealthyForStrictPrefix
        }
        let partialNotice: WorkspaceMergedPartialNotice? = (unavailableRuntimes.isEmpty && degradedRuntimes.isEmpty)
            ? nil
            : WorkspaceMergedPartialNotice(
                unavailableRuntimes: unavailableRuntimes,
                degradedRuntimes: degradedRuntimes
            )

        let anyCanFetchMore = activeStreams.contains(where: \.canFetchMore)
        let allExhaustedAndTrusted = activeStreams.allSatisfy {
            $0.status == .exhausted && $0.isHealthyForStrictPrefix
        }
        let hasPartialFactor = !unavailableRuntimes.isEmpty
            || !degradedRuntimes.isEmpty
            || unverifiedStreamsPresent
            || budgetExhausted

        let completeness: WorkspaceMergedCompleteness
        if allExhaustedAndTrusted {
            completeness = .completeExhausted
        } else if !hasPartialFactor && strictListableCount >= clampedTarget {
            completeness = .complete
        } else if hasPartialFactor || anyCanFetchMore {
            completeness = .partial
        } else {
            completeness = .completeExhausted
        }

        let visibleSessions = Array(sortedAll.prefix(clampedTarget).map(\.session))
        let canLoadMore = sortedAll.count > clampedTarget || anyCanFetchMore

        return WorkspaceMergedProjection(
            visibleSessions: visibleSessions,
            totalLoadedListableCount: sortedAll.count,
            strictCommittedCount: strictListableCount,
            completeness: completeness,
            canLoadMore: canLoadMore,
            hasInitialContent: anyLoaded || !visibleSessions.isEmpty,
            partialNotice: partialNotice
        )
    }

    /// 恢复单个流的既有快照（用于手动刷新遇瞬态限流/取消时保留已有结果，不闪出误报失败态）。
    mutating func restoreStream(_ runtime: WorkspaceSessionRuntimeChoice, from snapshot: StreamState) {
        streams[runtime] = snapshot
    }

    /// 判断是否仍需向远端补页以填满严格前缀（覆盖首屏、展开与 P1-2b 晚页补标回撤 `20 → 19 → 20`）。
    func needsMorePages(
        targetVisibleCount: Int,
        canonicalByKey: [CanonicalSessionKey: AgentSession] = [:],
        archivedKeys: Set<CanonicalSessionKey> = []
    ) -> Bool {
        let proj = projection(
            targetVisibleCount: targetVisibleCount,
            canonicalByKey: canonicalByKey,
            archivedKeys: archivedKeys
        )
        let anyUnloaded = enabledRuntimes.contains { streams[$0]?.status == .idle }
        if anyUnloaded {
            return true
        }
        if proj.completeness == .complete || proj.completeness == .completeExhausted {
            return false
        }
        if proj.totalLoadedListableCount < targetVisibleCount {
            return nextRuntimeToFetch() != nil
        }
        if proj.strictCommittedCount < targetVisibleCount {
            // 可见条数已满时，只继续推进严格健康流；非严格健康流（如旧版服务端未带 listMeta）
            // 无法提升严格前缀计数，绝不能反复翻页触发网关限流。
            return nextRuntimeToFetch(onlyHealthyForStrict: true) != nil
        }
        return false
    }

    /// 跨路严格全序：epochMs DESC → runtimeTieRank ASC → streamOrdinal ASC → sessionID DESC。
    static func compareEntries(
        leftEvidence: RawSortEvidence,
        leftRank: Int,
        leftOrdinal: Int,
        leftID: SessionID,
        rightEvidence: RawSortEvidence,
        rightRank: Int,
        rightOrdinal: Int,
        rightID: SessionID
    ) -> Bool {
        switch (leftEvidence.epochMsValue, rightEvidence.epochMsValue) {
        case let (l?, r?):
            if l != r { return l > r }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        if leftOrdinal != rightOrdinal {
            return leftOrdinal < rightOrdinal
        }
        return leftID > rightID
    }

    private static func deduplicatedAndSorted(
        _ sessions: [AgentSession],
        hostScope: HostScope,
        archivedKeys: Set<CanonicalSessionKey>
    ) -> [AgentSession] {
        var seen: Set<CanonicalSessionKey> = []
        var unique: [AgentSession] = []
        for item in sessions {
            let key = CanonicalSessionKey(session: item, hostScope: hostScope)
            guard !archivedKeys.contains(key),
                  !SubagentOwnershipEvidence(session: item).isSubagent,
                  seen.insert(key).inserted else {
                continue
            }
            unique.append(item)
        }
        return unique.sorted { lhs, rhs in
            let lKey = CanonicalSessionKey(session: lhs, hostScope: hostScope)
            let rKey = CanonicalSessionKey(session: rhs, hostScope: hostScope)
            return compareEntries(
                leftEvidence: RawSortEvidence.fromSession(lhs),
                leftRank: lKey.runtimeTieRank,
                leftOrdinal: 0,
                leftID: lhs.id,
                rightEvidence: RawSortEvidence.fromSession(rhs),
                rightRank: rKey.runtimeTieRank,
                rightOrdinal: 0,
                rightID: rhs.id
            )
        }
    }
}
