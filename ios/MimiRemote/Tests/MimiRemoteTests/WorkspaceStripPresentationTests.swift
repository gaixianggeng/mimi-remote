import XCTest
@testable import MimiRemote

final class WorkspaceStripPresentationTests: XCTestCase {
    func testWorkspaceRuntimeSelectionResetsForHostChange() {
        var state = WorkspaceRuntimeSelectionState(selectedRuntime: .claude)

        state.resetForHostChange()

        XCTAssertEqual(state.selectedRuntime, .codex)
    }

    func testBottomTabBarMappingUsesDeviceSizeClassAndSystemGeneration() {
        XCTAssertTrue(
            WorkbenchPageLayout.hasBottomTabBar(
                isPhone: true,
                isHorizontallyCompact: false,
                isIOS26OrLater: false
            )
        )
        XCTAssertFalse(
            WorkbenchPageLayout.hasBottomTabBar(
                isPhone: false,
                isHorizontallyCompact: false,
                isIOS26OrLater: false
            )
        )
        XCTAssertTrue(
            WorkbenchPageLayout.hasBottomTabBar(
                isPhone: false,
                isHorizontallyCompact: true,
                isIOS26OrLater: false
            )
        )
        XCTAssertFalse(
            WorkbenchPageLayout.hasBottomTabBar(
                isPhone: false,
                isHorizontallyCompact: false,
                isIOS26OrLater: true
            )
        )
        XCTAssertFalse(
            WorkbenchPageLayout.hasBottomTabBar(
                isPhone: false,
                isHorizontallyCompact: true,
                isIOS26OrLater: true
            )
        )
        XCTAssertTrue(
            WorkbenchPageLayout.hasBottomTabBar(
                isPhone: true,
                isHorizontallyCompact: true,
                isIOS26OrLater: true
            )
        )
    }

    func testCompactNavigationReturnCommitsRootRouteAndPathTogether() {
        var state = WorkbenchNavigationState(
            route: .session(id: "session-1", source: .workspaces)
        )

        _ = state.reduce(
            .compactPathChanged(tab: .workspaces, path: []),
            usesCompactNavigation: true,
            selectedSessionID: "session-1"
        )

        XCTAssertEqual(state.route, .workspaces)
        XCTAssertEqual(state.selection, .workspaces)
        XCTAssertEqual(state.compactWorkspacePath, [])
    }

    func testBottomTabBarKeepsIndependentNavigationStacksForRootToolbarOwnership() {
        XCTAssertTrue(
            WorkbenchPageLayout.usesIndependentCompactNavigationStacks(
                hasBottomTabBar: true
            )
        )
        XCTAssertFalse(
            WorkbenchPageLayout.usesIndependentCompactNavigationStacks(
                hasBottomTabBar: false
            )
        )
    }

    func testBottomTabBarAlwaysKeepsRuntimeMenuAndInlineNewSessionEntry() {
        XCTAssertFalse(
            WorkspaceStripLayout.usesInlineRuntimePicker(
                viewportWidth: 1_200,
                showsHostSwitcherInStrip: true,
                hasBottomTabBar: true
            )
        )
    }

    func testInlineRuntimeThresholdUsesContentWidthAfterHorizontalPadding() {
        let thresholdViewportWidth = WorkspaceStripLayout.inlineRuntimePickerMinimumWidth
            + WorkspaceStripLayout.horizontalPadding * 2

        XCTAssertFalse(
            WorkspaceStripLayout.usesInlineRuntimePicker(
                viewportWidth: thresholdViewportWidth - 1,
                showsHostSwitcherInStrip: false,
                hasBottomTabBar: false
            )
        )
        XCTAssertTrue(
            WorkspaceStripLayout.usesInlineRuntimePicker(
                viewportWidth: thresholdViewportWidth,
                showsHostSwitcherInStrip: false,
                hasBottomTabBar: false
            )
        )
    }

    func testInlineRuntimeThresholdReservesDeviceEntryBudget() {
        let deviceEntryBudget = WorkbenchChromeIconMetrics.minimumHitTarget
            + WorkspaceStripLayout.chipSpacing
        let thresholdViewportWidth = WorkspaceStripLayout.inlineRuntimePickerMinimumWidth
            + deviceEntryBudget
            + WorkspaceStripLayout.horizontalPadding * 2

        XCTAssertFalse(
            WorkspaceStripLayout.usesInlineRuntimePicker(
                viewportWidth: thresholdViewportWidth - 1,
                showsHostSwitcherInStrip: true,
                hasBottomTabBar: false
            )
        )
        XCTAssertTrue(
            WorkspaceStripLayout.usesInlineRuntimePicker(
                viewportWidth: thresholdViewportWidth,
                showsHostSwitcherInStrip: true,
                hasBottomTabBar: false
            )
        )
    }

    func testWorkspaceSelectionHapticOnlyFollowsUserSelectionChanges() {
        XCTAssertFalse(
            WorkspaceSelectionHapticPolicy.shouldFire(
                previousID: nil,
                selectedID: "project-a",
                isExplicitSelection: false,
                isUserPaging: false,
                isSuppressed: false
            )
        )
        XCTAssertTrue(
            WorkspaceSelectionHapticPolicy.shouldFire(
                previousID: "project-a",
                selectedID: "project-b",
                isExplicitSelection: true,
                isUserPaging: false,
                isSuppressed: false
            )
        )
        XCTAssertTrue(
            WorkspaceSelectionHapticPolicy.shouldFire(
                previousID: "project-a",
                selectedID: "project-b",
                isExplicitSelection: false,
                isUserPaging: true,
                isSuppressed: false
            )
        )
        XCTAssertFalse(
            WorkspaceSelectionHapticPolicy.shouldFire(
                previousID: "project-a",
                selectedID: "project-b",
                isExplicitSelection: false,
                isUserPaging: true,
                isSuppressed: true
            )
        )
        XCTAssertFalse(
            WorkspaceSelectionHapticPolicy.shouldFire(
                previousID: "project-a",
                selectedID: "project-a",
                isExplicitSelection: true,
                isUserPaging: true,
                isSuppressed: false
            )
        )
    }
}
