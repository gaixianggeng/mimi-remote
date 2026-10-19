import XCTest
@testable import MimiRemote

/// 紧凑布局下每个 Tab 只保留路由当前指向的详情栈。程序化跳转把用户带离某个 Tab 后，
/// 再点回来必须是列表，不能恢复一个早已离开的旧会话（#787）。
final class WorkbenchCompactTabStackTests: XCTestCase {
    func testNotificationFromWorkspaceDetailLeavesWorkspaceTabOnList() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )

        state.reduce(
            .selectionCommitted(SessionSelectionCommit(
                sequence: 1,
                projectID: "project",
                sessionID: "notification-session",
                reason: .notification
            )),
            usesCompactNavigation: true,
            selectedSessionID: "notification-session"
        )

        XCTAssertEqual(state.compactSelectedTab, .sessions)
        XCTAssertEqual(state.compactSessionPath, [.session("notification-session")])
        XCTAssertTrue(state.compactWorkspacePath.isEmpty, "通知把用户带到会话 Tab 后，工作区 Tab 不能留着旧详情")

        state.reduce(
            .compactPathChanged(tab: .sessions, path: []),
            usesCompactNavigation: true,
            selectedSessionID: "notification-session"
        )
        assertTappingWorkspacesShowsList(&state, selectedSessionID: nil)
    }

    func testRotationThroughSidebarSessionLeavesWorkspaceTabOnList() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )

        // 横屏后从侧栏打开另一个会话，宽屏不会改写紧凑栈。
        state.reduce(
            .open(.session("sidebar-session"), source: .sessions),
            usesCompactNavigation: false,
            selectedSessionID: "workspace-session"
        )
        XCTAssertTrue(state.compactWorkspacePath.isEmpty)

        // 转回竖屏时由 Shell 重放路由。
        state.reduce(
            .synchronize(.session(id: "sidebar-session", source: .sessions)),
            usesCompactNavigation: true,
            selectedSessionID: "sidebar-session"
        )
        XCTAssertEqual(state.compactSelectedTab, .sessions)
        XCTAssertEqual(state.compactSessionPath, [.session("sidebar-session")])
        XCTAssertTrue(state.compactWorkspacePath.isEmpty)

        state.reduce(
            .compactPathChanged(tab: .sessions, path: []),
            usesCompactNavigation: true,
            selectedSessionID: "sidebar-session"
        )
        assertTappingWorkspacesShowsList(&state, selectedSessionID: nil)
    }

    func testWideSessionsRootClearsHiddenWorkspaceStack() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )

        state.reduce(
            .open(.sessions, source: nil),
            usesCompactNavigation: false,
            selectedSessionID: "workspace-session"
        )
        XCTAssertTrue(state.compactWorkspacePath.isEmpty)

        state.reduce(
            .synchronize(.sessions),
            usesCompactNavigation: true,
            selectedSessionID: nil
        )
        assertTappingWorkspacesShowsList(&state, selectedSessionID: nil)
    }

    func testRotationWhileOnMeDoesNotRestoreOldWorkspaceDetail() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )
        state.reduce(
            .open(.session("sidebar-session"), source: .sessions),
            usesCompactNavigation: false,
            selectedSessionID: "workspace-session"
        )
        state.reduce(.open(.me, source: nil), usesCompactNavigation: false, selectedSessionID: "sidebar-session")

        // 停在“我的”时转回竖屏，Shell 只切 Tab，不重放会话路由。
        state.reduce(.compactTabChanged(.me), usesCompactNavigation: true, selectedSessionID: "sidebar-session")

        assertTappingWorkspacesShowsList(&state, selectedSessionID: "sidebar-session")
    }

    func testLeavingDetailThroughMeThenOtherTabDropsDetail() {
        let cases: [(WorkbenchRootPage, CompactWorkbenchTab, CompactWorkbenchTab)] = [
            (.workspaces, .sessions, .workspaces),
            (.sessions, .workspaces, .sessions),
        ]
        for (source, otherTab, detailTab) in cases {
            var state = WorkbenchNavigationState(route: .session(id: "detail-session", source: source))
            state.reduce(.compactTabChanged(.me), usesCompactNavigation: true, selectedSessionID: "detail-session")
            state.reduce(.compactTabChanged(otherTab), usesCompactNavigation: true, selectedSessionID: "detail-session")

            let effect = state.reduce(
                .compactTabChanged(detailTab),
                usesCompactNavigation: true,
                selectedSessionID: nil
            )

            XCTAssertEqual(effect, .returnToSessionList, "source=\(source)")
            XCTAssertEqual(state.selection, detailTab.destination, "source=\(source)")
            XCTAssertTrue(state.compactSessionPath.isEmpty, "source=\(source)")
            XCTAssertTrue(state.compactWorkspacePath.isEmpty, "source=\(source)")
        }
    }

    func testReturningFromMeRestoresTheDetailItWasOpenedFrom() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )
        state.reduce(
            .open(.subagent(parentID: "workspace-session", childID: "child"), source: .workspaces),
            usesCompactNavigation: true,
            selectedSessionID: "workspace-session"
        )
        let path = state.compactWorkspacePath

        state.reduce(.compactTabChanged(.me), usesCompactNavigation: true, selectedSessionID: "workspace-session")
        let effect = state.reduce(
            .compactTabChanged(.workspaces),
            usesCompactNavigation: true,
            selectedSessionID: "workspace-session"
        )

        XCTAssertNil(effect)
        XCTAssertEqual(state.compactWorkspacePath, path)
        XCTAssertEqual(path.count, 2, "子 Agent 页属于父会话，不能被当作残留栈清掉")
    }

    private func assertTappingWorkspacesShowsList(
        _ state: inout WorkbenchNavigationState,
        selectedSessionID: SessionID?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let effect = state.reduce(
            .compactTabChanged(.workspaces),
            usesCompactNavigation: true,
            selectedSessionID: selectedSessionID
        )

        XCTAssertEqual(effect, .returnToSessionList, file: file, line: line)
        XCTAssertEqual(state.compactSelectedTab, .workspaces, file: file, line: line)
        XCTAssertEqual(state.selection, .workspaces, file: file, line: line)
        XCTAssertEqual(state.route, .workspaces, file: file, line: line)
        XCTAssertTrue(state.compactWorkspacePath.isEmpty, file: file, line: line)
    }
}
