import XCTest
@testable import MimiRemote

final class WorkspaceStripPresentationTests: XCTestCase {
    func testWorkspaceRuntimeSelectionResetsForHostChange() {
        var state = WorkspaceRuntimeSelectionState(manualRuntime: .codex)

        state.reset()

        XCTAssertEqual(
            state.resolvedRuntime(preferredRuntime: .claude, claudeChannelAvailable: true),
            .claude
        )
    }

    func testWorkspaceRuntimePreferenceDefaultsAndStoredChoices() {
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.stored(nil), .codex)
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.stored("unknown"), .codex)
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.stored("codex"), .codex)
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.stored("claude"), .claude)

        let state = WorkspaceRuntimeSelectionState()
        for preferredRuntime in WorkspaceSessionRuntimeChoice.allCases {
            XCTAssertEqual(
                state.resolvedRuntime(preferredRuntime: preferredRuntime, claudeChannelAvailable: true),
                preferredRuntime
            )
        }
    }

    func testWorkspaceRuntimePreferenceRecoversAfterCapabilityArrives() {
        let state = WorkspaceRuntimeSelectionState()

        XCTAssertEqual(
            state.resolvedRuntime(preferredRuntime: .claude, claudeChannelAvailable: false),
            .codex
        )
        XCTAssertEqual(
            state.resolvedRuntime(preferredRuntime: .claude, claudeChannelAvailable: true),
            .claude,
            "启动或切换电脑时能力晚到，仍应恢复 Claude 偏好"
        )
    }

    func testWorkspaceManualChoiceSurvivesCapabilityRefreshUntilPreferenceChanges() {
        var state = WorkspaceRuntimeSelectionState(manualRuntime: .codex)

        for isAvailable in [false, true, false, true] {
            XCTAssertEqual(
                state.resolvedRuntime(preferredRuntime: .claude, claudeChannelAvailable: isAvailable),
                .codex,
                "能力刷新不能覆盖用户手动切换"
            )
        }

        state.reset()
        XCTAssertEqual(
            state.resolvedRuntime(preferredRuntime: .claude, claudeChannelAvailable: true),
            .claude
        )
    }

    func testWorkspaceManualClaudeChoiceFallsBackWithoutLosingSelection() {
        let state = WorkspaceRuntimeSelectionState(manualRuntime: .claude)

        XCTAssertEqual(
            state.resolvedRuntime(preferredRuntime: .codex, claudeChannelAvailable: false),
            .codex
        )
        XCTAssertEqual(
            state.resolvedRuntime(preferredRuntime: .codex, claudeChannelAvailable: true),
            .claude
        )
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
