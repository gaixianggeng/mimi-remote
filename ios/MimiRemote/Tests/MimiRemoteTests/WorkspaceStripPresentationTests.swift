import XCTest
@testable import MimiRemote

final class WorkspaceStripPresentationTests: XCTestCase {
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
}
