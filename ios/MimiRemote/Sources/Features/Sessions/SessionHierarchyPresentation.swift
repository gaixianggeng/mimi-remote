import Foundation

/// 一个父会话和挂在它下面的派生会话。
struct SessionFamily: Identifiable, Equatable {
    let root: AgentSession
    /// 按列表原有顺序排列；多级派生已摊平到最顶层的祖先下。
    let children: [AgentSession]
    /// 决定家族位置的成员：列表原顺序里最先出现的那一条（父子中最近活动的会话）。
    let leader: AgentSession

    var id: SessionID { root.id }

    var members: [AgentSession] { [root] + children }
}

/// 列表里实际渲染的一行。
struct SessionHierarchyRow: Identifiable, Equatable {
    enum Role: Equatable {
        /// 顶层会话；`childCount` 为 0 时就是普通会话行。
        case root(childCount: Int, isExpanded: Bool)
        case child(parent: AgentSession, isLast: Bool)
    }

    let session: AgentSession
    let role: Role

    var id: SessionID { session.id }

    var isChild: Bool {
        if case .child = role { return true }
        return false
    }
}

/// Claude 桌面版"主会话派生会话"的列表分组。只按会话自带的 `spawnedFromThreadID`
/// 分组，不按标题、目录或普通 fork 猜测关系；没有派生来源的会话保持原样。
enum SessionHierarchy {
    /// 防御异常数据里的环；真实派生链只有几层。
    private static let maxAncestorDepth = 16

    /// 输入顺序就是列表原来的排序（置顶、运行优先、时间等规则都已生效）。
    /// 每个家族放在最先出现的成员的位置，相当于按父子中最近活动的会话排序；
    /// 父会话不在同一份输入里时，子会话保持平铺，不会消失。
    static func families(_ sessions: [AgentSession]) -> [SessionFamily] {
        guard sessions.contains(where: { $0.spawnedFromThreadID != nil }) else {
            return sessions.map { SessionFamily(root: $0, children: [], leader: $0) }
        }
        var byThreadID: [String: AgentSession] = [:]
        for session in sessions {
            for key in threadKeys(session) where byThreadID[key] == nil {
                byThreadID[key] = session
            }
        }

        var rootIDBySessionID: [SessionID: SessionID] = [:]
        for session in sessions {
            rootIDBySessionID[session.id] = rootID(of: session, byThreadID: byThreadID)
        }

        var order: [SessionID] = []
        var leaderByRootID: [SessionID: AgentSession] = [:]
        var childrenByRootID: [SessionID: [AgentSession]] = [:]
        var sessionByID: [SessionID: AgentSession] = [:]
        for session in sessions {
            sessionByID[session.id] = sessionByID[session.id] ?? session
            let rootID = rootIDBySessionID[session.id] ?? session.id
            if leaderByRootID[rootID] == nil {
                leaderByRootID[rootID] = session
                order.append(rootID)
            }
            if rootID != session.id {
                childrenByRootID[rootID, default: []].append(session)
            }
        }
        return order.compactMap { rootID in
            guard let root = sessionByID[rootID], let leader = leaderByRootID[rootID] else { return nil }
            return SessionFamily(root: root, children: childrenByRootID[rootID] ?? [], leader: leader)
        }
    }

    static func rows(_ families: [SessionFamily], collapsedRootIDs: Set<SessionID>) -> [SessionHierarchyRow] {
        var rows: [SessionHierarchyRow] = []
        rows.reserveCapacity(families.reduce(0) { $0 + 1 + $1.children.count })
        for family in families {
            let isExpanded = !collapsedRootIDs.contains(family.root.id)
            rows.append(SessionHierarchyRow(
                session: family.root,
                role: .root(childCount: family.children.count, isExpanded: isExpanded)
            ))
            guard isExpanded else { continue }
            for child in family.children {
                rows.append(SessionHierarchyRow(
                    session: child,
                    role: .child(parent: family.root, isLast: child.id == family.children.last?.id)
                ))
            }
        }
        return rows
    }

    /// 沿派生链向上，找同一份输入里能找到的最顶层祖先；直接父会话不在输入里时保持平铺。
    private static func rootID(of session: AgentSession, byThreadID: [String: AgentSession]) -> SessionID {
        var current = session
        var visited: Set<SessionID> = [session.id]
        for _ in 0..<maxAncestorDepth {
            guard let parentThreadID = current.spawnedFromThreadID,
                  let parent = byThreadID[parentThreadID],
                  // 派生关系只在同一运行时内成立，不同渠道的同名 ID 不能串起来。
                  runtimeKey(parent) == runtimeKey(session) else {
                break
            }
            // 成环说明数据异常；整条链都按平铺处理，避免同一会话同时出现在两个家族里。
            guard visited.insert(parent.id).inserted else { return session.id }
            current = parent
        }
        return current.id
    }

    private static func threadKeys(_ session: AgentSession) -> [String] {
        [session.resumeID, session.id].compactMap { $0 }
    }

    private static func runtimeKey(_ session: AgentSession) -> String {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
    }
}

/// 分段列表里的一段家族；`key` 是调用方自己的分段标识。
struct SessionFamilySection<Key: Hashable>: Identifiable {
    let key: Key
    let families: [SessionFamily]

    var id: Key { key }
}

/// 按日期分段的历史列表里的一段家族。
struct SessionHistoryFamilyGroup: Identifiable, Equatable {
    let bucket: SessionHistoryDateBucket
    let families: [SessionFamily]

    var id: SessionHistoryDateBucket { bucket }
}

extension SessionHierarchy {
    /// 分段列表（需要处理 / 进行中 / 置顶 / 最近等）先在整份列表上分好家族，再按领头成员所在的段落位。
    /// 先分段再分家族的话，正在运行的子会话会和已完成的父会话拆到两段，父行的收起也管不到它。
    /// 领头成员是按段顺序最先出现的那条，所以家族只会整体前移到更靠前的段；成员全被带走的段直接省略。
    static func sectionedFamilies<Key: Hashable>(
        _ sections: [(key: Key, sessions: [AgentSession])]
    ) -> [SessionFamilySection<Key>] {
        var sectionBySessionID: [SessionID: Key] = [:]
        for section in sections {
            for session in section.sessions where sectionBySessionID[session.id] == nil {
                sectionBySessionID[session.id] = section.key
            }
        }
        var familiesByKey: [Key: [SessionFamily]] = [:]
        for family in families(sections.flatMap(\.sessions)) {
            guard let key = sectionBySessionID[family.leader.id] else { continue }
            familiesByKey[key, default: []].append(family)
        }
        return sections.compactMap { section in
            familiesByKey[section.key].map { SessionFamilySection(key: section.key, families: $0) }
        }
    }

    /// 先在整段历史上分好家族，再按家族里最近活动的成员归入日期段。
    /// 若先分日期再分家族，今天派生的子会话会和昨天的父会话被拆到两段。
    static func historyFamilyGroups(
        _ sessions: [AgentSession],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SessionHistoryFamilyGroup] {
        historyFamilyGroups(families: families(sessions), now: now, calendar: calendar)
    }

    static func historyFamilyGroups(
        families: [SessionFamily],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SessionHistoryFamilyGroup] {
        var familyByLeaderID: [SessionID: SessionFamily] = [:]
        for family in families {
            familyByLeaderID[family.leader.id] = family
        }
        return SessionListPresentation.historyDateGroups(
            sessions: families.map(\.leader),
            now: now,
            calendar: calendar
        ).map { group in
            SessionHistoryFamilyGroup(
                bucket: group.bucket,
                families: group.sessions.compactMap { familyByLeaderID[$0.id] }
            )
        }
    }
}

/// 会话页三类分段的家族视图：进行中、置顶、按日期分段的历史。
struct SessionListFamilyPartition: Equatable {
    let active: [SessionFamily]
    let pinned: [SessionFamily]
    let historyGroups: [SessionHistoryFamilyGroup]

    init(_ partition: SessionListPartition, now: Date, calendar: Calendar) {
        enum Section { case active, pinned, history }
        let sectioned = SessionHierarchy.sectionedFamilies([
            (key: Section.active, sessions: partition.active),
            (key: Section.pinned, sessions: partition.pinned),
            (key: Section.history, sessions: partition.history)
        ])
        func families(_ section: Section) -> [SessionFamily] {
            sectioned.first { $0.key == section }?.families ?? []
        }
        active = families(.active)
        pinned = families(.pinned)
        historyGroups = SessionHierarchy.historyFamilyGroups(families: families(.history), now: now, calendar: calendar)
    }

    /// 屏幕上的家族顺序，供方向键导航使用。
    var orderedFamilies: [SessionFamily] {
        active + pinned + historyGroups.flatMap(\.families)
    }
}
