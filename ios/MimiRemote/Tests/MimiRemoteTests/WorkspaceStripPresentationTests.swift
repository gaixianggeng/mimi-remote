import XCTest
@testable import MimiRemote

final class WorkspaceStripPresentationTests: XCTestCase {
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

    func testSessionAndSubagentDetailsOnlyHideBottomTabBar() {
        XCTAssertTrue(
            WorkbenchPageLayout.shouldHideSessionDetailTabBar(hasBottomTabBar: true)
        )
        XCTAssertFalse(
            WorkbenchPageLayout.shouldHideSessionDetailTabBar(hasBottomTabBar: false)
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
}
