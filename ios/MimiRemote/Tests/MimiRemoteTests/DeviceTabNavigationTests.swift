import SwiftUI
import XCTest
@testable import MimiRemote

final class DeviceTabNavigationTests: XCTestCase {
    func testDevicesTabPreservesSessionRouteAndBothCompactPaths() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )
        _ = state.reduce(
            .compactPathChanged(tab: .sessions, path: [.session("sessions-session")]),
            usesCompactNavigation: true,
            selectedSessionID: "workspace-session"
        )
        _ = state.reduce(
            .compactPathChanged(tab: .workspaces, path: [.session("workspace-session")]),
            usesCompactNavigation: true,
            selectedSessionID: "workspace-session"
        )

        let sessionsPath = state.compactSessionPath
        let workspacePath = state.compactWorkspacePath
        let route = state.route
        let effect = state.reduce(
            .compactTabChanged(.devices),
            usesCompactNavigation: true,
            selectedSessionID: "workspace-session"
        )

        XCTAssertNil(effect)
        XCTAssertEqual(state.compactSelectedTab, .devices)
        XCTAssertEqual(state.selection, .devices)
        XCTAssertEqual(state.route, route)
        XCTAssertEqual(state.compactSessionPath, sessionsPath)
        XCTAssertEqual(state.compactWorkspacePath, workspacePath)
    }

    func testBackgroundSelectionCommitsDoNotLeaveDevicesTab() {
        for usesCompactNavigation in [true, false] {
            assertDevicesSurvivesCommit(
                reason: .identityReplacement(previousID: "original-session"),
                sessionID: "replacement-session",
                expectedRoute: .session(id: "replacement-session", source: .workspaces),
                usesCompactNavigation: usesCompactNavigation
            )
            assertDevicesSurvivesCommit(
                reason: .restoration,
                sessionID: "original-session",
                expectedRoute: .session(id: "original-session", source: .workspaces),
                usesCompactNavigation: usesCompactNavigation
            )
            assertDevicesSurvivesCommit(
                reason: .invalidation,
                sessionID: nil,
                expectedRoute: .workspaces,
                usesCompactNavigation: usesCompactNavigation
            )
        }
    }

    func testNotificationExplicitlyLeavesDevicesAndOpensSession() {
        for usesCompactNavigation in [true, false] {
            var state = devicesState(usesCompactNavigation: usesCompactNavigation)

            _ = state.reduce(
                .selectionCommitted(commit(
                    sessionID: "notification-session",
                    reason: .notification
                )),
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: "notification-session"
            )

            XCTAssertEqual(
                state.route,
                .session(id: "notification-session", source: .sessions)
            )
            XCTAssertEqual(state.selection, .session("notification-session"))
            if usesCompactNavigation {
                XCTAssertEqual(state.compactSelectedTab, .sessions)
                XCTAssertEqual(state.compactSessionPath, [.session("notification-session")])
            }
        }
    }

    func testVisibleSessionExcludesDevicesTab() {
        var state = WorkbenchNavigationState(
            route: .session(id: "preserved-session", source: .sessions)
        )
        _ = state.reduce(
            .compactTabChanged(.devices),
            usesCompactNavigation: true,
            selectedSessionID: "preserved-session"
        )

        XCTAssertNil(state.visibleSessionID(usesCompactNavigation: true))
        XCTAssertEqual(state.route.detailSessionID, "preserved-session")
    }

    func testDevicesSelectionSurvivesWideAndCompactSynchronization() {
        var state = devicesState(usesCompactNavigation: false)

        _ = state.reduce(
            .synchronize(.session(id: "restored-session", source: .sessions)),
            usesCompactNavigation: true,
            selectedSessionID: "restored-session"
        )
        XCTAssertEqual(state.selection, .devices)
        XCTAssertEqual(state.compactSelectedTab, .devices)

        _ = state.reduce(
            .synchronize(.session(id: "restored-session", source: .sessions)),
            usesCompactNavigation: false,
            selectedSessionID: "restored-session"
        )
        XCTAssertEqual(state.selection, .devices)
        XCTAssertEqual(state.route.detailSessionID, "restored-session")
    }

    func testWorkbenchLayoutUsesRequestedDeviceBoundaries() {
        let cases: [(width: CGFloat, height: CGFloat, isPad: Bool, isPhone: Bool, compact: Bool)] = [
            (390, 844, false, true, true),
            (1_024, 600, false, true, true),
            (1_032, 1_376, true, false, false),
            (1_024, 1_366, true, false, false),
            (834, 1_194, true, false, true),
            (744, 1_133, true, false, true),
            (1_133, 744, true, false, false),
            (1_366, 1_024, true, false, false),
            (859, 600, true, false, true),
            (860, 600, true, false, false),
            (860, 860, true, false, false),
        ]

        for item in cases {
            let layout = WorkbenchLayout(
                containerWidth: item.width,
                horizontalSizeClass: .regular,
                isPad: item.isPad,
                isPhone: item.isPhone
            )
            XCTAssertEqual(
                layout.usesCompactNavigation,
                item.compact,
                "\(item.width)x\(item.height), isPad=\(item.isPad), isPhone=\(item.isPhone)"
            )
        }
    }

    private func assertDevicesSurvivesCommit(
        reason: SessionSelectionCommit.Reason,
        sessionID: SessionID?,
        expectedRoute: WorkbenchRestorationRoute,
        usesCompactNavigation: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var state = devicesState(usesCompactNavigation: usesCompactNavigation)

        _ = state.reduce(
            .selectionCommitted(commit(sessionID: sessionID, reason: reason)),
            usesCompactNavigation: usesCompactNavigation,
            selectedSessionID: sessionID
        )

        XCTAssertEqual(state.selection, .devices, file: file, line: line)
        XCTAssertEqual(state.route, expectedRoute, file: file, line: line)
        if usesCompactNavigation {
            XCTAssertEqual(state.compactSelectedTab, .devices, file: file, line: line)
        }
    }

    private func devicesState(usesCompactNavigation: Bool) -> WorkbenchNavigationState {
        var state = WorkbenchNavigationState(
            route: .session(id: "original-session", source: .workspaces)
        )
        _ = state.reduce(
            .open(.devices, source: nil),
            usesCompactNavigation: usesCompactNavigation,
            selectedSessionID: "original-session"
        )
        return state
    }

    private func commit(
        sessionID: SessionID?,
        reason: SessionSelectionCommit.Reason
    ) -> SessionSelectionCommit {
        SessionSelectionCommit(
            sequence: 1,
            projectID: "project",
            sessionID: sessionID,
            reason: reason
        )
    }
}
