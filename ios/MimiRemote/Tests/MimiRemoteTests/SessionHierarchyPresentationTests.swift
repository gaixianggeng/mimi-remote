import XCTest
@testable import MimiRemote

final class SessionHierarchyPresentationTests: XCTestCase {
    func testKnownChildAppearsWithoutOpeningParentHistory() {
        let parent = session("parent")
        let child = session("child", parent: "parent", status: "running")
        let rows = children(parent, [parent, child])
        XCTAssertEqual(rows.map(\.id), ["child"])
        XCTAssertEqual(rows.first?.session.status, "running")
        XCTAssertEqual(rows.first?.relation.parentThreadID, "parent")
    }

    func testLiveRelationAppearsBeforeChildIndexArrives() {
        let parent = session("parent")
        let context = SessionContextSnapshot(subagents: [
            SessionContextSubagent(id: "child", nickname: "检查布局", status: "inProgress")
        ])
        let row = children(parent, [parent], context).first
        XCTAssertEqual(row?.session.title, "检查布局")
        XCTAssertEqual(row?.session.status, "running")
        XCTAssertNil(row?.relation.canAcceptDirectInput)
        XCTAssertEqual(row?.session.allowsDirectInput, false)
    }

    func testKnownIdentityDeduplicatesContextAliasesAndDirectory() {
        let parent = session("parent")
        var child = session("codex_child", parent: "parent", resumeID: "child")
        child.title = "**检查布局**\n第二行"
        let context = SessionContextSnapshot(subagents: [
            SessionContextSubagent(id: "child", nickname: "worker", status: "completed"),
            SessionContextSubagent(id: "codex_child")
        ])
        let rows = children(parent, [parent, child], context)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.session.id, child.id)
        XCTAssertEqual(rows.first?.session.title, "检查布局 第二行")
        XCTAssertEqual(rows.first?.session.status, "completed")
    }

    func testParentThreadAliasFindsChild() {
        let parent = session("codex_parent", resumeID: "parent-thread")
        let child = session("child", parent: "parent-thread")
        XCTAssertEqual(children(parent, [parent, child]).map(\.id), ["child"])
    }

    func testMissingParentAndSourceOnlySubagentAreNotGuessedFromDirectory() {
        let parent = session("parent")
        var sourceOnly = session("source-only")
        sourceOnly.isSubagent = true
        let orphan = session("orphan", parent: "absent")
        XCTAssertTrue(children(parent, [parent, sourceOnly, orphan]).isEmpty)
    }

    func testOrdinaryForkStaysOutsideChildList() {
        let parent = session("parent")
        let fork = session("fork", context: SessionContextSnapshot(sources: [
            SessionContextSource(id: "fork", kind: "fork", label: "parent")
        ]))
        XCTAssertTrue(children(parent, [parent, fork]).isEmpty)
        XCTAssertFalse(fork.isSubagentThread)
        XCTAssertTrue(fork.allowsDirectInput)
    }

    func testWrongParentAndSelfReferencesAreExcluded() {
        let parent = session("parent")
        let child = session("wrong-parent", parent: "other")
        let context = SessionContextSnapshot(subagents: [
            SessionContextSubagent(id: "parent"),
            SessionContextSubagent(id: "wrong-parent"),
            SessionContextSubagent(id: "different", parentThreadID: "other"),
            SessionContextSubagent(id: " padded "),
            SessionContextSubagent(id: "")
        ])
        XCTAssertTrue(children(parent, [parent, child], context).isEmpty)
    }

    func testProvidersDoNotShareChildrenEvenWhenParentIDsMatch() {
        let parent = session("parent")
        let claude = session("claude-child", parent: "parent", provider: "claude")
        XCTAssertTrue(children(parent, [parent, claude]).isEmpty)
        let claudeParent = session("parent", provider: "claude")
        XCTAssertEqual(children(claudeParent, [claudeParent, claude]).map(\.id), ["claude-child"])
        let unknownProvider = session("unknown-child", parent: "parent", provider: "custom-runtime")
        XCTAssertTrue(children(parent, [parent, unknownProvider]).isEmpty)
        let nativeParent = session("parent", provider: AppServerRuntimeBundle.nativeRuntimeProvider)
        let nativeChild = session("native-child", parent: "parent", provider: AppServerRuntimeBundle.nativeRuntimeProvider)
        XCTAssertTrue(children(nativeParent, [nativeParent, nativeChild]).isEmpty,
                      "原生通道尚无子会话快照入口，不应显示无法打开的行")
    }

    func testContextAndDirectoryUpdatesDoNotDuplicateOrReorderChildren() {
        let parent = session("parent")
        var a = session("a", parent: "parent", status: "running")
        let b = session("b", parent: "parent")
        let context = SessionContextSnapshot(subagents: [SessionContextSubagent(id: "b")])
        XCTAssertEqual(children(parent, [parent, a, b], context).map(\.id), ["b", "a"])
        a.status = "completed"
        XCTAssertEqual(children(parent, [parent, a, b], context).last?.session.status, "completed")
    }

    func testDisplayMergeNeverOverridesExplicitReadOnlyCapability() {
        let parent = session("parent")
        var child = session("child", parent: "parent")
        child.canAcceptDirectInput = false
        let context = SessionContextSnapshot(subagents: [
            SessionContextSubagent(id: "child", canAcceptDirectInput: true)
        ])
        XCTAssertEqual(children(parent, [parent, child], context).first?.relation.canAcceptDirectInput, false)
        XCTAssertEqual(child.canAcceptDirectInput, false)
    }

    func testWaitingAndFailureStatesRemainVisible() {
        let parent = session("parent")
        let context = SessionContextSnapshot(subagents: [
            SessionContextSubagent(id: "approval", status: "waiting_for_approval"),
            SessionContextSubagent(id: "failed", status: "systemError")
        ])
        let rows = children(parent, [parent], context)
        XCTAssertEqual(rows.map(\.session.status), ["waiting_for_approval", "failed"])
        XCTAssertEqual(rows.map { $0.session.displayStatus(foregroundActivity: nil).tone }, [.warning, .danger])
    }

    private func children(
        _ parent: AgentSession,
        _ sessions: [AgentSession],
        _ context: SessionContextSnapshot? = nil
    ) -> [SessionHierarchyChild] {
        SessionHierarchyPresentation.children(of: parent, sessions: sessions, context: context)
    }

    private func session(
        _ id: String,
        parent: String? = nil,
        resumeID: String? = nil,
        status: String = "history",
        provider: String = "codex",
        context: SessionContextSnapshot? = nil
    ) -> AgentSession {
        AgentSession(
            id: id, projectID: "demo", project: "Demo", dir: "/tmp/demo",
            title: id, status: status, source: provider, runtimeProvider: provider,
            resumeID: resumeID ?? id, createdAt: nil, updatedAt: nil,
            parentThreadID: parent, context: context
        )
    }
}
