import XCTest
@testable import MimiRemote

/// Claude 桌面版派生会话的列表分组：只认 `spawnedFromThreadID`，父会话不在同一列表时平铺。
final class SessionHierarchyPresentationTests: XCTestCase {
    func testFamilyTakesThePositionOfItsMostRecentMember() {
        // 输入顺序就是列表排序：子会话最近活动，所以整个家族排到它的位置。
        let sessions = [
            session("child-a", spawnedFrom: "root"),
            session("other"),
            session("root"),
            session("child-b", spawnedFrom: "root")
        ]
        let families = SessionHierarchy.families(sessions)
        XCTAssertEqual(families.map(\.root.id), ["root", "other"])
        XCTAssertEqual(families.first?.children.map(\.id), ["child-a", "child-b"])
        XCTAssertEqual(families.first?.leader.id, "child-a")

        let rows = SessionHierarchy.rows(families, collapsedRootIDs: [])
        XCTAssertEqual(rows.map(\.id), ["root", "child-a", "child-b", "other"])
        XCTAssertEqual(rows[0].role, .root(childCount: 2, isExpanded: true))
        XCTAssertEqual(rows[1].role, .child(parent: sessions[2], isLast: false))
        XCTAssertEqual(rows[2].role, .child(parent: sessions[2], isLast: true))
        XCTAssertEqual(rows[3].role, .root(childCount: 0, isExpanded: true))
    }

    func testCollapsedRootHidesItsChildren() {
        let families = SessionHierarchy.families([session("root"), session("child", spawnedFrom: "root")])
        let rows = SessionHierarchy.rows(families, collapsedRootIDs: ["root"])
        XCTAssertEqual(rows.map(\.id), ["root"])
        XCTAssertEqual(rows.first?.role, .root(childCount: 1, isExpanded: false))
    }

    func testChildStaysFlatWhenItsParentIsNotInTheList() {
        let families = SessionHierarchy.families([session("child", spawnedFrom: "elsewhere"), session("other")])
        XCTAssertEqual(families.map(\.root.id), ["child", "other"])
        XCTAssertTrue(families.allSatisfy(\.children.isEmpty))
    }

    func testGrandchildrenAttachToTheTopAncestorWithOneIndent() {
        let families = SessionHierarchy.families([
            session("grandchild", spawnedFrom: "child"),
            session("root"),
            session("child", spawnedFrom: "root")
        ])
        XCTAssertEqual(families.map(\.root.id), ["root"])
        XCTAssertEqual(families.first?.children.map(\.id), ["grandchild", "child"])

        // 中间那层不在列表里时，链断开：孙会话找不到父会话，保持平铺。
        let broken = SessionHierarchy.families([session("grandchild", spawnedFrom: "child"), session("root")])
        XCTAssertEqual(broken.map(\.root.id), ["grandchild", "root"])
    }

    func testCyclesAndSelfReferencesStayFlat() {
        let families = SessionHierarchy.families([
            session("a", spawnedFrom: "b"),
            session("b", spawnedFrom: "a"),
            session("self", spawnedFrom: "self")
        ])
        XCTAssertEqual(families.map(\.root.id), ["a", "b", "self"])
        XCTAssertTrue(families.allSatisfy(\.children.isEmpty))
        XCTAssertNil(session("self", spawnedFrom: "self").spawnedFromThreadID)
    }

    func testParentMatchesByThreadIDAndOnlyWithinTheSameRuntime() {
        // App 内会话 ID 可能与线程 ID 不同；派生来源记录的是线程 ID。
        let root = session("app-root", resumeID: "thread-root")
        let child = session("child", spawnedFrom: "thread-root")
        XCTAssertEqual(SessionHierarchy.families([root, child]).map(\.root.id), ["app-root"])

        let codexRoot = session("thread-root", runtime: "codex")
        XCTAssertEqual(SessionHierarchy.families([codexRoot, child]).map(\.root.id), ["thread-root", "child"])
    }

    func testListsWithoutSpawnedSessionsKeepTheirOrder() {
        let sessions = [session("b"), session("a"), session("c")]
        let families = SessionHierarchy.families(sessions)
        XCTAssertEqual(families.map(\.root.id), ["b", "a", "c"])
        XCTAssertEqual(SessionHierarchy.rows(families, collapsedRootIDs: []).map(\.id), ["b", "a", "c"])
    }

    func testHistoryGroupsPlaceTheFamilyByItsMostRecentMember() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12)))
        let yesterday = now.addingTimeInterval(-26 * 3_600)
        // 今天派生的子会话不能和昨天的父会话被拆到两段。
        let groups = SessionHierarchy.historyFamilyGroups(
            [
                session("child", spawnedFrom: "root", recencyAt: now.addingTimeInterval(-600)),
                session("root", recencyAt: yesterday),
                session("old", recencyAt: yesterday)
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(groups.map(\.bucket), [.today, .yesterday])
        XCTAssertEqual(groups.first?.families.map(\.root.id), ["root"])
        XCTAssertEqual(groups.first?.families.first?.children.map(\.id), ["child"])
        XCTAssertEqual(groups.last?.families.map(\.root.id), ["old"])
    }

    func testActiveChildPullsItsFamilyIntoTheEarlierSection() {
        // 子会话在跑、父会话已完成：整个家族随领头的子会话进入「进行中」，父行的收起也能管到它。
        let sections = SessionHierarchy.sectionedFamilies([
            (key: "active", sessions: [session("child", spawnedFrom: "root")]),
            (key: "history", sessions: [session("root"), session("other")])
        ])
        XCTAssertEqual(sections.map(\.key), ["active", "history"])
        XCTAssertEqual(sections[0].families.map(\.root.id), ["root"])
        XCTAssertEqual(sections[0].families.first?.children.map(\.id), ["child"])
        XCTAssertEqual(sections[1].families.map(\.root.id), ["other"])

        // 成员全被带走的段不再出现，避免留下空标题。
        let emptied = SessionHierarchy.sectionedFamilies([
            (key: "active", sessions: [session("child", spawnedFrom: "root")]),
            (key: "history", sessions: [session("root")])
        ])
        XCTAssertEqual(emptied.map(\.key), ["active"])
    }

    func testSessionListPartitionKeepsFamiliesTogetherAcrossLifecycleSections() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12)))
        let partition = SessionListFamilyPartition(
            SessionListPartition(
                active: [session("child", spawnedFrom: "root")],
                pinned: [],
                history: [session("root", recencyAt: now), session("other", recencyAt: now)]
            ),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(partition.active.map(\.root.id), ["root"])
        XCTAssertEqual(partition.active.first?.children.map(\.id), ["child"])
        XCTAssertEqual(partition.historyGroups.flatMap(\.families).map(\.root.id), ["other"])
        XCTAssertEqual(partition.orderedFamilies.map(\.root.id), ["root", "other"])
    }

    func testThreadListFieldProjectsIntoTheSession() async throws {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let project = AgentProject(id: "repo", name: "Repo", path: "/tmp/repo")
        let thread: [String: CodexAppServerJSONValue] = [
            "id": .string("child-thread"),
            "sessionId": .string("child-thread"),
            "cwd": .string(project.path),
            "name": .string("派生会话"),
            "status": .object(["type": .string("idle")]),
            "canAcceptDirectInput": .bool(true),
            "spawnedFromThreadId": .string("root-thread"),
            "mimiRemote": .object([
                "projectId": .string(project.id),
                "projectName": .string(project.name),
                "projectPath": .string(project.path),
                "readOnly": .bool(false)
            ])
        ]
        let session = try await runtime.agentSession(from: thread, projects: [project], fallbackProject: nil)
        XCTAssertEqual(session.spawnedFromThreadID, "root-thread")
        // 派生会话是完整会话：不是子 Agent，也不因此变成只读。
        XCTAssertFalse(session.isSubagentThread)
        XCTAssertTrue(session.allowsDirectInput)
    }

    @MainActor
    func testPartialSnapshotsKeepTheKnownSpawnSource() {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { DelayedCreateSessionClient(projects: [], sessions: []) }
        )
        let known = session("child", spawnedFrom: "root")
        let partial = session("child")
        XCTAssertEqual(store.sessionPreservingSubagentOwnership(partial, withKnown: known).spawnedFromThreadID, "root")

        let workspace = AgentWorkspace(
            id: "demo", name: "Demo", path: "/tmp/demo",
            rootProjectID: "demo", rootProjectName: "Demo", rootProjectPath: "/tmp/demo", lastOpenedAt: Date()
        )
        XCTAssertEqual(store.session(known, in: workspace).spawnedFromThreadID, "root", "工作区投影不得丢掉派生来源")
    }

    private func session(
        _ id: SessionID,
        spawnedFrom: String? = nil,
        resumeID: String? = nil,
        runtime: String = "claude",
        recencyAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            projectID: "demo",
            project: "Demo",
            dir: "/tmp/demo",
            title: id,
            status: "history",
            source: runtime,
            runtimeProvider: runtime,
            resumeID: resumeID ?? id,
            createdAt: nil,
            updatedAt: recencyAt,
            recencyAt: recencyAt,
            spawnedFromThreadID: spawnedFrom
        )
    }
}
