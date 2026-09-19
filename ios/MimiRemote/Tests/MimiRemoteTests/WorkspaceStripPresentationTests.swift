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

    func testRestingNameDisclosureIsBinaryNotInterpolated() {
        // 曾经的连续披露会在中间态给出「够放一两个字符」的宽度，把工作区名截成
        // 单字母残片。这里锁死二值：任何输入只能得到 0 或 1。
        let inputs: [CGFloat] = [
            0, 200, 345, 505.5, 639.9, 640, 689.5, 872, 1_200, 2_000,
        ]
        for width in inputs {
            for count in [0, 1, 2, 3, 5, 9] {
                let disclosure = WorkspaceStripLayout.restingNameDisclosure(
                    viewportWidth: width,
                    projectCount: count
                )
                XCTAssertTrue(
                    disclosure == 0 || disclosure == 1,
                    "视口 \(width) / 项目 \(count) 得到非二值披露 \(disclosure)"
                )
            }
        }
    }

    func testRestingNameDisclosureFollowsMeasuredDeviceWidths() {
        // 三个宽度都是实测值：13 寸横屏 + 侧栏展开（容器收窄到 920）、
        // iPad mini 竖屏、iPhone 竖屏。横屏给完整名称，窄屏干净地退回纯头像。
        XCTAssertEqual(
            WorkspaceStripLayout.restingNameDisclosure(viewportWidth: 689.5, projectCount: 3),
            1
        )
        XCTAssertEqual(
            WorkspaceStripLayout.restingNameDisclosure(viewportWidth: 505.5, projectCount: 3),
            0
        )
        XCTAssertEqual(
            WorkspaceStripLayout.restingNameDisclosure(viewportWidth: 345, projectCount: 3),
            0
        )
    }

    func testRestingNameDisclosureRequiresFullBudgetForEveryRestingChip() {
        // 宽度过了阈值还不够：项目多到放不下全部名称时，宁可整体退回纯头像，
        // 也不要只给前几个胶囊名称、后面的被挤掉。
        XCTAssertEqual(
            WorkspaceStripLayout.restingNameDisclosure(viewportWidth: 1_400, projectCount: 20),
            0
        )
        XCTAssertEqual(
            WorkspaceStripLayout.restingNameDisclosure(viewportWidth: 1_400, projectCount: 6),
            1
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
