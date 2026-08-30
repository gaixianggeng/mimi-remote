import Foundation

/// 将 app-server 的权威快照与已经展示的实时 Item 合并成一条稳定时间线。
///
/// 核心约束是“首次出现决定槽位，后续事件原位更新”。时间只在两个完全没有顺序关系的
/// 独立片段之间充当插入提示，绝不能重新排列已经建立的 Turn/Item 顺序。
struct ConversationTimelineReducer {
    enum SnapshotOrdering {
        case authoritative
        case incrementalFragments
    }

    struct RebaseResult {
        let messages: [ConversationMessage]
        let stableIDAliases: [MessageID: UUID]
        let ambiguousAliasCount: Int
        let hadOrderingCycle: Bool
    }

    private struct Node {
        var message: ConversationMessage
        let currentIndex: Int?
        let snapshotIndex: Int?
    }

    func rebase(
        snapshot rawSnapshot: [ConversationMessage],
        current: [ConversationMessage],
        replacingHistoryProjectionIDs: Set<UUID>? = nil,
        authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>] = [:],
        snapshotOrdering: SnapshotOrdering = .authoritative
    ) -> RebaseResult {
        let snapshot = deduplicatedSnapshot(rawSnapshot)
        var matchedCurrentBySnapshotIndex: [Int: Int] = [:]
        var consumedCurrentIndices = Set<Int>()
        var ambiguousAliasCount = 0

        var currentIndicesByUUID: [UUID: Int] = [:]
        var currentIndicesByPrimaryKey: [String: [Int]] = [:]
        var currentIndicesBySemanticKey: [String: [Int]] = [:]
        for index in current.indices {
            // 极端情况下旧缓存可能已有重复 UUID；保留首次出现槽位，不能在重建时间线时崩溃。
            currentIndicesByUUID[current[index].id] = currentIndicesByUUID[current[index].id] ?? index
            if let key = primaryKey(for: current[index]) {
                currentIndicesByPrimaryKey[key, default: []].append(index)
            }
            if let key = semanticAliasKey(for: current[index]) {
                currentIndicesBySemanticKey[key, default: []].append(index)
            }
        }

        // 先使用 UUID/协议稳定键匹配；legacy thread/read 的 item-N 最后再走受限语义别名。
        for snapshotIndex in snapshot.indices {
            let item = snapshot[snapshotIndex]
            let candidates: [Int]
            if let currentIndex = currentIndicesByUUID[item.id] {
                candidates = [currentIndex]
            } else if let key = primaryKey(for: item) {
                candidates = currentIndicesByPrimaryKey[key] ?? []
            } else {
                candidates = []
            }
            if let match = candidates.first(where: { !consumedCurrentIndices.contains($0) }) {
                matchedCurrentBySnapshotIndex[snapshotIndex] = match
                consumedCurrentIndices.insert(match)
            }
        }

        var unmatchedSnapshotIndicesBySemanticKey: [String: [Int]] = [:]
        for snapshotIndex in snapshot.indices where matchedCurrentBySnapshotIndex[snapshotIndex] == nil {
            if let key = semanticAliasKey(for: snapshot[snapshotIndex]) {
                unmatchedSnapshotIndicesBySemanticKey[key, default: []].append(snapshotIndex)
            }
        }
        for (key, snapshotIndices) in unmatchedSnapshotIndicesBySemanticKey {
            let currentCandidates = (currentIndicesBySemanticKey[key] ?? []).filter { !consumedCurrentIndices.contains($0) }
            guard snapshotIndices.count == 1, currentCandidates.count == 1,
                  let snapshotIndex = snapshotIndices.first,
                  let currentIndex = currentCandidates.first else {
                if !snapshotIndices.isEmpty, !currentCandidates.isEmpty {
                    ambiguousAliasCount += 1
                }
                continue
            }
            matchedCurrentBySnapshotIndex[snapshotIndex] = currentIndex
            consumedCurrentIndices.insert(currentIndex)
        }

        // 老 Claude bridge 或 bridge 重启后的 JSONL 历史可能不给 client_message_id。
        // 未确认回显沿用旧兼容逻辑；已确认消息只允许带本地 client ID 的 user 气泡
        // 与唯一、近时间、且缺 client ID 的历史合并，避免误吞用户刻意发送的重复内容。
        for snapshotIndex in snapshot.indices where matchedCurrentBySnapshotIndex[snapshotIndex] == nil {
            let history = snapshot[snapshotIndex]
            let candidates = current.indices.filter { index in
                guard !consumedCurrentIndices.contains(index) else { return false }
                let local = current[index]
                let isUnconfirmedLocalEcho = local.sendStatus != .confirmed
                let isConfirmedLegacyClaudeEcho = local.sendStatus == .confirmed
                    && local.role == .user
                    && local.clientMessageID != nil
                    && history.clientMessageID == nil
                return (isUnconfirmedLocalEcho || isConfirmedLegacyClaudeEcho)
                    && local.role == history.role
                    && local.content == history.content
                    && abs(local.createdAt.timeIntervalSince(history.createdAt)) <= 10 * 60
            }
            guard candidates.count == 1, let currentIndex = candidates.first else {
                continue
            }
            matchedCurrentBySnapshotIndex[snapshotIndex] = currentIndex
            consumedCurrentIndices.insert(currentIndex)
        }

        let snapshotIndexByCurrentIndex = Dictionary(uniqueKeysWithValues: matchedCurrentBySnapshotIndex.map { ($0.value, $0.key) })
        var nodes: [Node] = []
        var nodeIndexByCurrentIndex: [Int: Int] = [:]
        var nodeIndexBySnapshotIndex: [Int: Int] = [:]
        var stableIDAliases: [MessageID: UUID] = [:]

        for currentIndex in current.indices {
            let existing = current[currentIndex]
            if let snapshotIndex = snapshotIndexByCurrentIndex[currentIndex] {
                let authoritative = mergedMessage(snapshot: snapshot[snapshotIndex], existing: existing)
                let nodeIndex = nodes.count
                nodes.append(Node(message: authoritative, currentIndex: currentIndex, snapshotIndex: snapshotIndex))
                nodeIndexByCurrentIndex[currentIndex] = nodeIndex
                nodeIndexBySnapshotIndex[snapshotIndex] = nodeIndex
                if let stableID = existing.stableID {
                    stableIDAliases[stableID] = authoritative.id
                }
                if let stableID = authoritative.stableID {
                    stableIDAliases[stableID] = authoritative.id
                }
                continue
            }
            if replacingHistoryProjectionIDs?.contains(existing.id) == true {
                continue
            }
            if shouldPruneProjectedProcess(existing, authoritativeCompletedTurnItems: authoritativeCompletedTurnItems) {
                continue
            }
            let nodeIndex = nodes.count
            nodes.append(Node(message: existing, currentIndex: currentIndex, snapshotIndex: nil))
            nodeIndexByCurrentIndex[currentIndex] = nodeIndex
        }

        for snapshotIndex in snapshot.indices where nodeIndexBySnapshotIndex[snapshotIndex] == nil {
            let nodeIndex = nodes.count
            let message = snapshot[snapshotIndex]
            nodes.append(Node(message: message, currentIndex: nil, snapshotIndex: snapshotIndex))
            nodeIndexBySnapshotIndex[snapshotIndex] = nodeIndex
            if let stableID = message.stableID {
                stableIDAliases[stableID] = message.id
            }
        }

        guard nodes.count > 1 else {
            return RebaseResult(
                messages: nodes.map(\.message),
                stableIDAliases: stableIDAliases,
                ambiguousAliasCount: ambiguousAliasCount,
                hadOrderingCycle: false
            )
        }

        var outgoing = Array(repeating: Set<Int>(), count: nodes.count)
        var indegree = Array(repeating: 0, count: nodes.count)
        func addEdge(_ from: Int, _ to: Int) {
            guard from != to, outgoing[from].insert(to).inserted else { return }
            indegree[to] += 1
        }

        let keptCurrentNodeIndices = current.indices.compactMap { nodeIndexByCurrentIndex[$0] }
        for pair in zip(keptCurrentNodeIndices, keptCurrentNodeIndices.dropFirst()) {
            let left = nodes[pair.0]
            let right = nodes[pair.1]
            // 两端都来自 snapshot 时由服务端顺序裁决；只保留含本地专属 Item 的首次出现约束。
            if (left.snapshotIndex == nil || right.snapshotIndex == nil),
               !currentAdjacencyConflictsWithInjectedUser(left: left, right: right) {
                addEdge(pair.0, pair.1)
            }
        }
        let snapshotNodeIndices = snapshot.indices.compactMap { nodeIndexBySnapshotIndex[$0] }
        for pair in zip(snapshotNodeIndices, snapshotNodeIndices.dropFirst()) {
            if snapshotOrdering == .authoritative
                || nodes[pair.0].message.turnID == nodes[pair.1].message.turnID {
                addEdge(pair.0, pair.1)
            }
        }

        if snapshotOrdering == .incrementalFragments {
            var canonicalNodeIndicesByTurn: [TurnID: [Int]] = [:]
            for nodeIndex in nodes.indices {
                guard let turnID = nodes[nodeIndex].message.turnID,
                      nodes[nodeIndex].message.timelineOrdinal != nil else {
                    continue
                }
                canonicalNodeIndicesByTurn[turnID, default: []].append(nodeIndex)
            }
            for nodeIndices in canonicalNodeIndicesByTurn.values {
                let ordered = nodeIndices.sorted { leftIndex, rightIndex in
                    let leftOrdinal = nodes[leftIndex].message.timelineOrdinal ?? .max
                    let rightOrdinal = nodes[rightIndex].message.timelineOrdinal ?? .max
                    return leftOrdinal == rightOrdinal
                        ? leftIndex < rightIndex
                        : leftOrdinal < rightOrdinal
                }
                for pair in zip(ordered, ordered.dropFirst()) {
                    // 同一 Turn 的完整 Item 序号是权威顺序。用图约束表达，避免把同 Turn
                    // 序号与跨 Turn 时间混进一个非传递的 sort 比较器。
                    addEdge(pair.0, pair.1)
                }
            }
        }

        var ready = nodes.indices.filter { indegree[$0] == 0 }
        var orderedNodeIndices: [Int] = []
        orderedNodeIndices.reserveCapacity(nodes.count)
        while !ready.isEmpty {
            ready.sort {
                isNode(
                    nodes[$0],
                    orderedBefore: nodes[$1],
                    snapshotOrdering: snapshotOrdering
                )
            }
            let nodeIndex = ready.removeFirst()
            orderedNodeIndices.append(nodeIndex)
            for next in outgoing[nodeIndex] {
                indegree[next] -= 1
                if indegree[next] == 0 {
                    ready.append(next)
                }
            }
        }

        let hadOrderingCycle = orderedNodeIndices.count != nodes.count
        if hadOrderingCycle {
            // 快照顺序与本地首次槽位发生冲突时，时间排序无法解决语义矛盾，反而会再次制造跳动。
            // 明确保留全部已展示 Item 的相对顺序，只把快照新增 Item 锚到相邻服务端 Item 附近。
            orderedNodeIndices = currentFirstFallbackOrder(
                nodes: nodes,
                currentNodeIndices: keptCurrentNodeIndices,
                snapshotNodeIndices: snapshotNodeIndices
            )
        }

        return RebaseResult(
            messages: orderedNodeIndices.map { nodes[$0].message },
            stableIDAliases: stableIDAliases,
            ambiguousAliasCount: ambiguousAliasCount,
            hadOrderingCycle: hadOrderingCycle
        )
    }

    private func currentAdjacencyConflictsWithInjectedUser(left: Node, right: Node) -> Bool {
        guard left.snapshotIndex == nil,
              right.snapshotIndex != nil,
              right.message.role == .user,
              right.message.userDelivery == .injected,
              !left.message.isTimestampFallback,
              !right.message.isTimestampFallback else {
            return false
        }
        // 省流/部分历史可能已经确认中途 steer 用户消息，却暂时缺少其后的实时回复。
        // 如果旧列表把这些回复留在用户消息前面，继续保留首次槽位会形成
        // “Agent 先回答、用户后提问”。只在双方时间都可靠时放弃这条旧相邻约束，
        // 随后的拓扑排序即可按真实发送时间把用户消息插回正确位置。
        return right.message.createdAt < left.message.createdAt
    }

    private func deduplicatedSnapshot(_ snapshot: [ConversationMessage]) -> [ConversationMessage] {
        var seenUUIDs = Set<UUID>()
        var seenPrimaryKeys = Set<String>()
        return snapshot.filter { message in
            guard seenUUIDs.insert(message.id).inserted else { return false }
            guard let key = primaryKey(for: message) else { return true }
            return seenPrimaryKeys.insert(key).inserted
        }
    }

    private func mergedMessage(snapshot: ConversationMessage, existing: ConversationMessage) -> ConversationMessage {
        let shouldUseExistingTime = snapshot.isTimestampFallback && !existing.isTimestampFallback
        let snapshotIsOlder = isSnapshotOlder(snapshot, than: existing)
        return ConversationMessage(
            id: existing.id,
            stableID: snapshot.stableID ?? existing.stableID,
            clientMessageID: snapshot.clientMessageID ?? existing.clientMessageID,
            turnID: snapshot.turnID ?? existing.turnID,
            itemID: snapshot.itemID ?? existing.itemID,
            role: snapshotIsOlder ? existing.role : snapshot.role,
            kind: snapshotIsOlder ? existing.kind : snapshot.kind,
            content: snapshotIsOlder ? existing.content : snapshot.content,
            createdAt: (snapshotIsOlder || shouldUseExistingTime) ? existing.createdAt : snapshot.createdAt,
            updatedAt: latest(snapshot.updatedAt, existing.updatedAt),
            sendStatus: snapshotIsOlder
                ? existing.sendStatus
                : mostAdvancedSendStatus(snapshot.sendStatus, existing.sendStatus),
            revision: latestRevision(snapshot.revision, existing.revision),
            turnPayload: snapshotIsOlder ? (existing.turnPayload ?? snapshot.turnPayload) : (snapshot.turnPayload ?? existing.turnPayload),
            activityPayload: snapshotIsOlder ? (existing.activityPayload ?? snapshot.activityPayload) : (snapshot.activityPayload ?? existing.activityPayload),
            timelineOrdinal: snapshotIsOlder ? (existing.timelineOrdinal ?? snapshot.timelineOrdinal) : (snapshot.timelineOrdinal ?? existing.timelineOrdinal),
            turnLifecycle: mostAdvancedLifecycle(snapshot.turnLifecycle, existing.turnLifecycle),
            userDelivery: snapshotIsOlder ? (existing.userDelivery ?? snapshot.userDelivery) : (snapshot.userDelivery ?? existing.userDelivery),
            isTimestampFallback: shouldUseExistingTime ? false : snapshot.isTimestampFallback
        )
    }

    private func isSnapshotOlder(_ snapshot: ConversationMessage, than existing: ConversationMessage) -> Bool {
        // 同一个 Item 一旦由实时事件进入终态，历史读取不能用较晚的 snapshotReadAt
        // 把它重新写回 running。部分 activity 没有 turnLifecycle，因此同时检查 payload 状态。
        let existingIsTerminal = existing.turnLifecycle?.isTerminal == true
            || isTerminalActivity(existing.activityPayload)
        let snapshotIsTerminal = snapshot.turnLifecycle?.isTerminal == true
            || isTerminalActivity(snapshot.activityPayload)
        if existingIsTerminal, !snapshotIsTerminal {
            return true
        }
        if existing.revision != nil, snapshot.revision == nil {
            return true
        }
        if let snapshotRevision = snapshot.revision, let existingRevision = existing.revision {
            return snapshotRevision < existingRevision
        }
        if existing.sendStatus == .confirmed, snapshot.sendStatus != .confirmed {
            return true
        }
        if let snapshotUpdatedAt = snapshot.updatedAt, let existingUpdatedAt = existing.updatedAt {
            return snapshotUpdatedAt < existingUpdatedAt
        }
        return false
    }

    private func isTerminalActivity(_ payload: ConversationActivityPayload?) -> Bool {
        guard let payload else { return false }
        if payload.isFailure || payload.isInterrupted {
            return true
        }
        switch payload.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "succeeded", "success":
            return true
        default:
            return false
        }
    }

    private func mostAdvancedSendStatus(
        _ snapshot: MessageSendStatus,
        _ existing: MessageSendStatus
    ) -> MessageSendStatus {
        func rank(_ status: MessageSendStatus) -> Int {
            switch status {
            case .local: return 0
            case .sending: return 1
            case .failed: return 2
            case .sent: return 3
            case .confirmed: return 4
            }
        }
        return rank(snapshot) >= rank(existing) ? snapshot : existing
    }

    private func mostAdvancedLifecycle(
        _ snapshot: ConversationTurnLifecycle?,
        _ existing: ConversationTurnLifecycle?
    ) -> ConversationTurnLifecycle? {
        // 终态的具体原因属于实时事件事实。历史 enrichment 的冻结 Turn shell
        // 不能把 failed/interrupted 改写成 completed，也不能重新打开 Turn。
        if existing?.isTerminal == true { return existing }
        if snapshot?.isTerminal == true { return snapshot }
        return snapshot ?? existing
    }

    private func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.some(let left), .some(let right)):
            return max(left, right)
        case (.some(let value), .none), (.none, .some(let value)):
            return value
        case (.none, .none):
            return nil
        }
    }

    private func latestRevision(_ lhs: ModelRevision?, _ rhs: ModelRevision?) -> ModelRevision? {
        switch (lhs, rhs) {
        case (.some(let left), .some(let right)):
            return max(left, right)
        case (.some(let value), .none), (.none, .some(let value)):
            return value
        case (.none, .none):
            return nil
        }
    }

    private func primaryKey(for message: ConversationMessage) -> String? {
        if let clientMessageID = message.clientMessageID {
            return "client:\(clientMessageID)"
        }
        if let itemID = message.itemID, !itemID.isEmpty {
            return "item:\(message.turnID ?? ""):\(itemID)"
        }
        if let stableID = message.stableID {
            return "stable:\(stableID)"
        }
        return nil
    }

    private func semanticAliasKey(for message: ConversationMessage) -> String? {
        guard let turnID = message.turnID, !turnID.isEmpty else { return nil }
        let semanticKind: String
        if message.role == .assistant {
            semanticKind = "assistant:\(message.kind.rawValue)"
        } else if message.role == .system {
            switch message.kind {
            case .reasoningSummary, .plan, .commandSummary, .fileChangeSummary:
                semanticKind = "system:\(message.kind.rawValue)"
            case .message, .commentary, .approval, .userInput, .error:
                return nil
            }
        } else {
            return nil
        }
        let normalized = AssistantTextNormalizer.normalizedAssistantTextForDedup(message.content)
        guard !normalized.isEmpty else { return nil }
        return "\(turnID):\(semanticKind):\(normalized)"
    }

    private func shouldPruneProjectedProcess(
        _ message: ConversationMessage,
        authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>]
    ) -> Bool {
        guard message.timelineOrdinal != nil,
              let turnID = message.turnID,
              let itemID = message.itemID,
              let authoritativeItemIDs = authoritativeCompletedTurnItems[turnID],
              !authoritativeItemIDs.contains(itemID) else {
            return false
        }
        return message.kind == .commandSummary || message.kind == .fileChangeSummary
    }

    private func isNode(
        _ lhs: Node,
        orderedBefore rhs: Node,
        snapshotOrdering: SnapshotOrdering
    ) -> Bool {
        if lhs.message.createdAt != rhs.message.createdAt {
            return lhs.message.createdAt < rhs.message.createdAt
        }
        if let leftOrdinal = lhs.message.timelineOrdinal,
           let rightOrdinal = rhs.message.timelineOrdinal,
           leftOrdinal != rightOrdinal,
           snapshotOrdering == .incrementalFragments
            || lhs.message.turnID == rhs.message.turnID {
            // enrichment 的不同批次可能共用 Turn 时间；协议序号可在不建立
            // 跨 Turn snapshot adjacency 的前提下提供稳定插入位置。
            return leftOrdinal < rightOrdinal
        }
        switch (lhs.snapshotIndex, rhs.snapshotIndex) {
        case (.some(let left), .some(let right)) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return (lhs.currentIndex ?? .max) < (rhs.currentIndex ?? .max)
        }
    }

    private func currentFirstFallbackOrder(
        nodes: [Node],
        currentNodeIndices: [Int],
        snapshotNodeIndices: [Int]
    ) -> [Int] {
        var result = currentNodeIndices
        var emitted = Set(currentNodeIndices)
        for (offset, nodeIndex) in snapshotNodeIndices.enumerated() where !emitted.contains(nodeIndex) {
            let previousSnapshotNode = snapshotNodeIndices[..<offset].last(where: emitted.contains)
            let nextSnapshotNode = snapshotNodeIndices[(offset + 1)...].first(where: emitted.contains)
            if let previousSnapshotNode,
               let anchor = result.firstIndex(of: previousSnapshotNode) {
                result.insert(nodeIndex, at: result.index(after: anchor))
            } else if let nextSnapshotNode,
                      let anchor = result.firstIndex(of: nextSnapshotNode) {
                result.insert(nodeIndex, at: anchor)
            } else {
                result.append(nodeIndex)
            }
            emitted.insert(nodeIndex)
        }
        return result
    }
}
