import XCTest
@testable import MimiRemote

final class WorkspaceStripPresentationTests: XCTestCase {
    func testWorkspaceRuntimeSelectionResetsForHostChange() {
        var state = WorkspaceRuntimeSelectionState(manualRuntime: .codex)

        state.reset()

        XCTAssertEqual(
            state.resolvedRuntime(
                preferredRuntime: .claude,
                availableRuntimeProviders: ["codex", "claude"]
            ),
            .claude
        )
    }

    func testWorkspaceRuntimePreferenceDefaultsAndStoredChoices() {
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.stored(nil), .codex)
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.stored("unknown"), .codex)
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.stored("codex"), .codex)
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.stored("claude"), .claude)
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.stored("deepseek"), .deepseek)
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.deepseek.rawValue, "deepseek")

        let state = WorkspaceRuntimeSelectionState()
        for preferredRuntime in WorkspaceSessionRuntimeChoice.allCases {
            XCTAssertEqual(
                state.resolvedRuntime(
                    preferredRuntime: preferredRuntime,
                    availableRuntimeProviders: Set(WorkspaceSessionRuntimeChoice.allCases.map(\.runtimeProvider))
                ),
                preferredRuntime
            )
        }
    }

    func testWorkspaceRuntimeSettingsTitlesCoverAllChoices() {
        XCTAssertEqual(
            WorkspaceSessionRuntimeChoice.allCases.map(\.choiceTitle),
            [
                L10n.text("ui.runtime_default"),
                L10n.text("ui.runtime_optional"),
                "DeepSeek"
            ]
        )
    }

    func testWorkspaceRuntimePreferenceRecoversAfterCapabilityArrives() {
        let state = WorkspaceRuntimeSelectionState()

        XCTAssertEqual(
            state.resolvedRuntime(
                preferredRuntime: .claude,
                availableRuntimeProviders: ["codex"]
            ),
            .codex
        )
        XCTAssertEqual(
            state.resolvedRuntime(
                preferredRuntime: .claude,
                availableRuntimeProviders: ["codex", "claude"]
            ),
            .claude,
            "启动或切换电脑时能力晚到，仍应恢复 Claude 偏好"
        )
    }

    /// 首选 Runtime 不可用时必须回落到**实际可用**的那个。
    ///
    /// main 上这条断言的是"codex 被关掉时退到 claude"。合并后 codex 同样参与探测
    /// （不再写死为恒可用），所以这条语义得以保留——只开了 claude 的主机上，
    /// 把用不了的 codex 顶上来是错的。
    func testWorkspaceRuntimePreferenceFallsBackToClaudeWhenCodexIsUnavailable() {
        let state = WorkspaceRuntimeSelectionState()

        XCTAssertEqual(
            state.resolvedRuntime(
                preferredRuntime: .codex,
                availableRuntimeProviders: ["claude"]
            ),
            .claude
        )
        XCTAssertEqual(
            WorkspaceSessionRuntimeChoice.available(runtimeProviders: ["claude"]),
            [.claude]
        )
    }

    /// 主机一个通道都没上报时，codex 作为兜底项仍然可选，选择器不会空。
    ///
    /// 这是"能力尚未到达"的正常态（首屏早于探测完成），不能让用户看到空列表
    /// 或未选中态。
    func testCodexRemainsFallbackWhenNoChannelIsReported() {
        let state = WorkspaceRuntimeSelectionState()

        XCTAssertEqual(
            state.resolvedRuntime(
                preferredRuntime: .claude,
                availableRuntimeProviders: []
            ),
            .codex
        )
        XCTAssertEqual(
            WorkspaceSessionRuntimeChoice.available(runtimeProviders: []),
            [.codex]
        )
    }

    func testWorkspaceManualChoiceSurvivesCapabilityRefreshUntilPreferenceChanges() {
        var state = WorkspaceRuntimeSelectionState(manualRuntime: .codex)

        for isAvailable in [false, true, false, true] {
            XCTAssertEqual(
                state.resolvedRuntime(
                    preferredRuntime: .claude,
                    availableRuntimeProviders: isAvailable ? ["codex", "claude"] : ["codex"]
                ),
                .codex,
                "能力刷新不能覆盖用户手动切换"
            )
        }

        state.reset()
        XCTAssertEqual(
            state.resolvedRuntime(
                preferredRuntime: .claude,
                availableRuntimeProviders: ["codex", "claude"]
            ),
            .claude
        )
    }

    func testWorkspaceManualClaudeChoiceFallsBackWithoutLosingSelection() {
        let state = WorkspaceRuntimeSelectionState(manualRuntime: .claude)

        XCTAssertEqual(
            state.resolvedRuntime(
                preferredRuntime: .codex,
                availableRuntimeProviders: ["codex"]
            ),
            .codex
        )
        XCTAssertEqual(
            state.resolvedRuntime(
                preferredRuntime: .codex,
                availableRuntimeProviders: ["codex", "claude"]
            ),
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
