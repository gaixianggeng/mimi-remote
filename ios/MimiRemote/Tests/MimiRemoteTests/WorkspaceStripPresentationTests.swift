import SwiftUI
import UIKit
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
                "Antigravity",
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

    /// #501：宽屏会话详情返回时工作区根视图会重建，必须回到进入前浏览的工作区。
    func testRebuiltWorkspaceRootRestoresRememberedSourceInsteadOfFirstWorkspace() {
        var state = WorkspaceBrowseSelectionState()
        let projectIDs = ["workspace-first", "workspace-second", "workspace-third"]

        state.record("workspace-second")
        // 返回后的新根视图没有局部选择；活动会话所属工作区也不能抢走浏览来源。
        XCTAssertEqual(
            WorkspaceBrowseSelectionState.resolvedWorkspaceID(
                current: nil,
                retainedCurrent: nil,
                remembered: state.workspaceID,
                activeProjectID: "workspace-third",
                projectIDs: projectIDs
            ),
            "workspace-second"
        )

        // 连续进入、返回不同工作区时，每次恢复最近一次的来源。
        state.record("workspace-third")
        XCTAssertEqual(
            WorkspaceBrowseSelectionState.resolvedWorkspaceID(
                current: nil,
                retainedCurrent: nil,
                remembered: state.workspaceID,
                activeProjectID: nil,
                projectIDs: projectIDs
            ),
            "workspace-third"
        )
    }

    func testWorkspaceBrowseSelectionSurvivesTransientEmptyCatalogAndResetsForHostChange() {
        var state = WorkspaceBrowseSelectionState()
        state.record("workspace-second")

        // 重连或加载期间目录为空，根视图会把局部选择清成 nil；记住的来源不能被覆盖。
        state.record(nil)
        XCTAssertEqual(state.workspaceID, "workspace-second")
        XCTAssertNil(
            WorkspaceBrowseSelectionState.resolvedWorkspaceID(
                current: nil,
                retainedCurrent: nil,
                remembered: state.workspaceID,
                activeProjectID: nil,
                projectIDs: []
            )
        )
        XCTAssertEqual(
            WorkspaceBrowseSelectionState.resolvedWorkspaceID(
                current: nil,
                retainedCurrent: nil,
                remembered: state.workspaceID,
                activeProjectID: nil,
                projectIDs: ["workspace-first", "workspace-second"]
            ),
            "workspace-second"
        )

        state.reset()
        XCTAssertNil(state.workspaceID)
    }

    func testWorkspaceSelectionResolutionKeepsCurrentAndFallsBackInOrder() {
        let projectIDs = ["workspace-first", "workspace-second", "workspace-third"]
        func resolve(
            current: String? = nil,
            retainedCurrent: String? = nil,
            remembered: String? = nil,
            activeProjectID: String? = nil
        ) -> String? {
            WorkspaceBrowseSelectionState.resolvedWorkspaceID(
                current: current,
                retainedCurrent: retainedCurrent,
                remembered: remembered,
                activeProjectID: activeProjectID,
                projectIDs: projectIDs
            )
        }

        // 目录刷新后当前选择仍在：保持不动。
        XCTAssertEqual(resolve(current: "workspace-third", remembered: "workspace-second"), "workspace-third")
        // 当前工作区身份被替换：跟随替换后的同一工作区。
        XCTAssertEqual(
            resolve(current: "workspace-old", retainedCurrent: "workspace-third", remembered: "workspace-second"),
            "workspace-third"
        )
        // 记住的来源已被移除：沿用原有的活动工作区与第一项回落。
        XCTAssertEqual(resolve(remembered: "workspace-removed", activeProjectID: "workspace-second"), "workspace-second")
        XCTAssertEqual(resolve(remembered: "workspace-removed"), "workspace-first")
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

    func testInlineRuntimeThresholdFollowsSharedContentPadding() {
        let contentPadding: CGFloat = 40
        let threshold = WorkspaceStripLayout.inlineRuntimePickerMinimumWidth + contentPadding * 2

        XCTAssertEqual(
            WorkspaceStripLayout.minimumContentWidth(viewportWidth: threshold, contentPadding: contentPadding),
            WorkspaceStripLayout.inlineRuntimePickerMinimumWidth
        )
        XCTAssertFalse(WorkspaceStripLayout.usesInlineRuntimePicker(
            viewportWidth: threshold - 1,
            showsHostSwitcherInStrip: false,
            hasBottomTabBar: false,
            contentPadding: contentPadding
        ))
        XCTAssertTrue(WorkspaceStripLayout.usesInlineRuntimePicker(
            viewportWidth: threshold,
            showsHostSwitcherInStrip: false,
            hasBottomTabBar: false,
            contentPadding: contentPadding
        ))
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

    func testEnabledRuntimesParsingPreservesOrderAndGuardsLastEnabled() {
        XCTAssertEqual(
            WorkspaceSessionRuntimeChoice.enabledRuntimes(from: nil),
            [.codex, .claude, .agy, .deepseek]
        )
        XCTAssertEqual(
            WorkspaceSessionRuntimeChoice.enabledRuntimes(from: ""),
            [.codex, .claude, .agy, .deepseek]
        )
        XCTAssertEqual(
            WorkspaceSessionRuntimeChoice.enabledRuntimes(from: "deepseek,codex"),
            [.codex, .deepseek]
        )

        // 关闭 Codex 后，「优先使用」自动回落到首个已开启的 Claude。
        let disabledCodex = WorkspaceSessionRuntimeChoice.updatingEnabledState(
            for: .codex,
            isEnabled: false,
            enabledRawValue: "codex,claude",
            preferredRawValue: "codex"
        )
        XCTAssertEqual(disabledCodex.enabledRawValue, "claude")
        XCTAssertEqual(disabledCodex.preferredRawValue, "claude")

        // 只剩最后一个开启的模型时，禁止继续关闭。
        let guardLast = WorkspaceSessionRuntimeChoice.updatingEnabledState(
            for: .claude,
            isEnabled: false,
            enabledRawValue: disabledCodex.enabledRawValue,
            preferredRawValue: disabledCodex.preferredRawValue
        )
        XCTAssertEqual(guardLast.enabledRawValue, "claude")
        XCTAssertEqual(guardLast.preferredRawValue, "claude")
    }

    func testWorkspaceRuntimeCreationChoicesExcludeKnownUnavailableChannels() {
        let enabledOnlyClaude: Set<WorkspaceSessionRuntimeChoice> = [.claude]
        XCTAssertTrue(
            WorkspaceSessionRuntimeChoice.available(
                runtimeProviders: ["codex"],
                enabledRuntimes: enabledOnlyClaude
            ).isEmpty
        )

        // 创建入口没有可用项时，工作区仍能展示用户偏好的通道，并保持新建按钮不可用。
        let state = WorkspaceRuntimeSelectionState()
        let displayedRuntime = state.resolvedRuntime(
            preferredRuntime: .claude,
            availableRuntimeProviders: ["codex"],
            enabledRuntimes: enabledOnlyClaude
        )
        XCTAssertEqual(displayedRuntime, .claude)
        XCTAssertFalse(displayedRuntime.isAvailable(in: ["codex"], enabledRuntimes: enabledOnlyClaude))
    }

    func testWorkspaceRuntimeFilteringHonorsEnabledRuntimes() {
        let enabledOnlyCodexAndClaude: Set<WorkspaceSessionRuntimeChoice> = [.codex, .claude]

        XCTAssertEqual(
            WorkspaceSessionRuntimeChoice.available(
                runtimeProviders: ["codex", "claude", "deepseek"],
                enabledRuntimes: enabledOnlyCodexAndClaude
            ),
            [.codex, .claude]
        )

        // 当用户只开启了 Claude 且主机尚未上报通道时，兜底项应为首个已开启模型 Claude，且其可用性为 true。
        let enabledOnlyClaude: Set<WorkspaceSessionRuntimeChoice> = [.claude]
        XCTAssertEqual(
            WorkspaceSessionRuntimeChoice.available(
                runtimeProviders: [],
                enabledRuntimes: enabledOnlyClaude
            ),
            [.claude]
        )
        XCTAssertTrue(
            WorkspaceSessionRuntimeChoice.claude.isAvailable(
                in: [],
                enabledRuntimes: enabledOnlyClaude
            )
        )
        XCTAssertFalse(
            WorkspaceSessionRuntimeChoice.codex.isAvailable(
                in: [],
                enabledRuntimes: enabledOnlyClaude
            )
        )

        let state = WorkspaceRuntimeSelectionState(manualRuntime: .deepseek)
        XCTAssertEqual(
            state.resolvedRuntime(
                preferredRuntime: .deepseek,
                availableRuntimeProviders: ["codex", "claude", "deepseek"],
                enabledRuntimes: enabledOnlyCodexAndClaude
            ),
            .codex
        )
    }

    // MARK: - #1107 打开文件夹手动路径草稿保留回归测试

    @MainActor
    func testOpenWorkspaceSheetModelPreservesTypedPathAcrossDirectoryBrowseAndSessionStoreRefreshes() async throws {
        let rootResponse = DirectoryListResponse(
            path: "/Users/me",
            parentPath: "/Users",
            entries: [
                DirectoryEntry(name: "projects", path: "/Users/me/projects", isDir: true, canOpen: true, canBrowse: true),
                DirectoryEntry(name: "finance", path: "/Users/me/finance", isDir: true, canOpen: true, canBrowse: true),
            ],
            truncated: false
        )
        let childResponse = DirectoryListResponse(
            path: "/Users/me/projects",
            parentPath: "/Users/me",
            entries: [
                DirectoryEntry(name: "alpha", path: "/Users/me/projects/alpha", isDir: true, canOpen: true, canBrowse: true),
            ],
            truncated: false
        )
        let (appStore, sessionStore, client) = makeOpenWorkspaceTestStores(
            directoryListResults: [
                "": .success(rootResponse),
                "/Users/me": .success(rootResponse),
                "/Users/me/projects": .success(childResponse),
            ]
        )
        _ = appStore

        let model = OpenWorkspaceSheetModel()
        model.attach(sessionStore: sessionStore, onOpened: { _ in }, dismiss: {})

        await model.startInitialBrowseIfNeeded()
        await model.startInitialBrowseIfNeeded()
        XCTAssertEqual(client.requestedDirectoryPaths, [""])
        XCTAssertEqual(model.browsePath, "/Users/me")
        XCTAssertEqual(model.browseRootPath, "/Users/me")

        model.isManualPathExpanded = true
        model.updateManualPath("/Users/me/finance")
        model.handleManualPathFocusChange(true)
        XCTAssertEqual(model.path, "/Users/me/finance")
        XCTAssertTrue(model.canOpenTypedPath)
        XCTAssertEqual(model.presentationDetent, .large)

        // 模拟后台轮询、目录同步、会话变更与子目录跳转，未提交的手填路径草稿必须全程保留。
        try await sessionStore.refreshWorkspaceCatalog()
        await sessionStore.refreshSelectedProjectSessions(showLoading: false)
        sessionStore.sessions.append(
            AgentSession(
                id: "polled-session",
                projectID: "proj-0",
                project: "project-0",
                dir: "/Users/me/code/project-0",
                title: "Polled Session",
                status: SessionStatus.completed.rawValue,
                source: "codex",
                runtimeProvider: "codex",
                resumeID: "polled-session",
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        sessionStore.objectWillChange.send()
        await model.browse(to: "/Users/me/projects")
        await model.startInitialBrowseIfNeeded()

        XCTAssertEqual(model.path, "/Users/me/finance")
        XCTAssertTrue(model.isManualPathExpanded)
        XCTAssertTrue(model.canOpenTypedPath)
        XCTAssertEqual(model.browsePath, "/Users/me/projects")
        XCTAssertEqual(client.requestedDirectoryPaths, ["", "/Users/me/projects"])
    }

    @MainActor
    func testOpenWorkspaceSheetRenderedManualPathSurvivesPasteAndSessionStorePolling() async throws {
        let previousPasteboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previousPasteboard }

        let rootResponse = DirectoryListResponse(
            path: "/Users/me",
            parentPath: "/Users",
            entries: (0..<12).map { index in
                DirectoryEntry(
                    name: "folder-\(index)",
                    path: "/Users/me/folder-\(index)",
                    isDir: true,
                    canOpen: true,
                    canBrowse: true
                )
            },
            truncated: false
        )
        let childResponse = DirectoryListResponse(
            path: "/Users/me/folder-0",
            parentPath: "/Users/me",
            entries: [
                DirectoryEntry(name: "sub", path: "/Users/me/folder-0/sub", isDir: true, canOpen: true, canBrowse: true),
            ],
            truncated: false
        )
        let (appStore, sessionStore, client) = makeOpenWorkspaceTestStores(
            directoryListResults: [
                "": .success(rootResponse),
                "/Users/me": .success(rootResponse),
                "/Users/me/folder-0": .success(childResponse),
            ]
        )
        let themeStore = ThemeStore(defaults: UserDefaults(suiteName: "OpenWorkspaceSheetTest.\(UUID().uuidString)")!)

        final class SheetPresenterState: ObservableObject {
            @Published var presentation: OpenWorkspaceSheetPresentation?
        }

        struct ParentObservingHost: View {
            @EnvironmentObject var sessionStore: SessionStore
            @ObservedObject var presenter: SheetPresenterState

            var body: some View {
                VStack {
                    Text("sessions:\(sessionStore.sessions.count)")
                }
                .sheet(item: $presenter.presentation) { presentation in
                    OpenWorkspaceSheet(model: presentation.model)
                }
            }
        }

        let presenter = SheetPresenterState()
        let presentation = OpenWorkspaceSheetPresentation()
        presenter.presentation = presentation

        let rootView = ParentObservingHost(presenter: presenter)
            .environmentObject(appStore)
            .environmentObject(sessionStore)
            .environmentObject(themeStore)
            .environment(\.horizontalSizeClass, .compact)

        let window = makePhoneTestWindow(rootView: rootView)
        defer { tearDownTestWindow(window) }

        try? await Task.sleep(for: .milliseconds(350))
        presentation.model.isManualPathExpanded = true
        try? await Task.sleep(for: .milliseconds(300))

        guard let presentedRoot = window.rootViewController?.presentedViewController?.view else {
            XCTFail("OpenWorkspaceSheet 应当已呈现")
            return
        }

        // 滚到底部确保内联手动路径输入框已完成挂载并进入视口。
        if let collectionView = allDescendantViews(in: presentedRoot).compactMap({ $0 as? UIScrollView }).first {
            let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
            collectionView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
            collectionView.layoutIfNeeded()
        }
        try? await Task.sleep(for: .milliseconds(250))

        let textField = try XCTUnwrap(
            allDescendantViews(in: presentedRoot)
                .compactMap { $0 as? OpenWorkspaceManualPathTextField.ManualPathUITextField }
                .first { $0.accessibilityIdentifier == "workspace.open.manualPath" },
            "展开手动输入路径后应当挂载稳定输入框"
        )

        textField.becomeFirstResponder()
        try? await Task.sleep(for: .milliseconds(150))
        UIPasteboard.general.string = "/Users/me/finance"
        textField.paste(nil)
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(presentation.model.path, "/Users/me/finance")
        XCTAssertEqual(textField.text, "/Users/me/finance")
        XCTAssertTrue(presentation.model.canOpenTypedPath)

        // 连续触发父层观察到的 SessionStore 轮询更新与目录刷新，验证输入框内容不被清空。
        for tick in 0..<3 {
            sessionStore.sessions.append(
                AgentSession(
                    id: "tick-\(tick)",
                    projectID: "proj-0",
                    project: "project-0",
                    dir: "/Users/me/code/project-0",
                    title: "Tick \(tick)",
                    status: SessionStatus.completed.rawValue,
                    source: "codex",
                    runtimeProvider: "codex",
                    resumeID: "tick-\(tick)",
                    createdAt: Date(),
                    updatedAt: Date()
                )
            )
            sessionStore.objectWillChange.send()
            try await sessionStore.refreshWorkspaceCatalog()
            try? await Task.sleep(for: .milliseconds(120))
        }
        await presentation.model.browse(to: "/Users/me/folder-0")
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(presentation.model.path, "/Users/me/finance")
        XCTAssertEqual(textField.text, "/Users/me/finance")
        XCTAssertTrue(presentation.model.isManualPathExpanded)
        XCTAssertTrue(presentation.model.canOpenTypedPath)
        XCTAssertEqual(client.requestedDirectoryPaths, ["", "/Users/me/folder-0"])
    }

    @MainActor
    func testOpenWorkspaceManualPathTextFieldUpdateGuardPreservesActiveText() {
        var boundText = ""
        let field = OpenWorkspaceManualPathTextField(
            placeholder: "/Users/me/finance",
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            fontSize: 13,
            textColor: .label,
            placeholderColor: .secondaryLabel,
            onFocusChange: { _ in },
            onSubmit: {}
        )
        let coordinator = field.makeCoordinator()
        let uiTextField = OpenWorkspaceManualPathTextField.ManualPathUITextField()
        uiTextField.text = ""
        coordinator.lastSyncedText = ""

        // 模拟用户粘贴后，Coordinator 立刻同步到 Binding 并记录 lastSyncedText。
        uiTextField.text = "/Users/me/finance"
        coordinator.syncFromTextField(uiTextField)
        XCTAssertEqual(boundText, "/Users/me/finance")
        XCTAssertEqual(coordinator.lastSyncedText, "/Users/me/finance")

        // 视图因外部刷新重绘但 boundText 与 lastSyncedText 一致时，不应覆写 UITextField。
        let unchangedBinding = OpenWorkspaceManualPathTextField(
            placeholder: "/Users/me/finance",
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            fontSize: 13,
            textColor: .label,
            placeholderColor: .secondaryLabel,
            onFocusChange: { _ in },
            onSubmit: {}
        )
        coordinator.parent = unchangedBinding
        XCTAssertEqual(uiTextField.text, "/Users/me/finance")

        // 显式外部清空（与 lastSyncedText 不同）时应当同步到输入框。
        boundText = ""
        coordinator.lastSyncedText = "/Users/me/finance"
        let clearedField = OpenWorkspaceManualPathTextField(
            placeholder: "/Users/me/finance",
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            fontSize: 13,
            textColor: .label,
            placeholderColor: .secondaryLabel,
            onFocusChange: { _ in },
            onSubmit: {}
        )
        coordinator.parent = clearedField
        if uiTextField.markedTextRange == nil && coordinator.lastSyncedText != boundText {
            uiTextField.text = boundText
            coordinator.lastSyncedText = boundText
        }
        XCTAssertEqual(uiTextField.text, "")
        XCTAssertEqual(coordinator.lastSyncedText, "")
    }

    // MARK: - #1108 iPhone 工作区 Tab 底部边距与安全区避让回归测试

    func testWorkspaceBottomContentMarginPolicyAcrossCompactAndWideLayouts() {
        // iPhone 13 底部 Tab 栏（34pt home indicator -> 118pt clearance），无浮起 FAB。
        XCTAssertEqual(
            WorkspaceBottomContentMarginPolicy.resolvedMargin(
                explicitMargin: 118,
                hasCompactTabBar: true,
                hasBottomTabBar: true,
                environmentClearance: 118,
                includesFloatingActionButtonAllowance: true
            ),
            118
        )
        XCTAssertEqual(
            WorkspaceBottomContentMarginPolicy.resolvedMargin(
                explicitMargin: 118,
                hasCompactTabBar: true,
                hasBottomTabBar: true,
                environmentClearance: 118,
                includesFloatingActionButtonAllowance: false
            ),
            118
        )

        // iPhone SE 底部 Tab 栏（0pt home indicator -> 104pt clearance）。
        XCTAssertEqual(
            WorkspaceBottomContentMarginPolicy.resolvedMargin(
                explicitMargin: 104,
                hasCompactTabBar: true,
                hasBottomTabBar: true,
                environmentClearance: 104,
                includesFloatingActionButtonAllowance: true
            ),
            104
        )
        XCTAssertEqual(
            WorkspaceBottomContentMarginPolicy.resolvedMargin(
                explicitMargin: 104,
                hasCompactTabBar: true,
                hasBottomTabBar: true,
                environmentClearance: 104,
                includesFloatingActionButtonAllowance: false
            ),
            104
        )

        // 未显式传入但处于底部 Tab 栏时回落到环境 clearance。
        XCTAssertEqual(
            WorkspaceBottomContentMarginPolicy.resolvedMargin(
                explicitMargin: nil,
                hasCompactTabBar: true,
                hasBottomTabBar: true,
                environmentClearance: 118,
                includesFloatingActionButtonAllowance: false
            ),
            118
        )

        // iPadOS 26 顶部 Tab 栏：不预留底部 Tab 高度，候选列表仅保留常规 24pt，详情页仅追加 FAB 让位高度。
        XCTAssertEqual(
            WorkspaceBottomContentMarginPolicy.resolvedMargin(
                explicitMargin: WorkbenchPageLayout.regularPadding,
                hasCompactTabBar: true,
                hasBottomTabBar: false,
                environmentClearance: WorkbenchPageLayout.regularPadding,
                includesFloatingActionButtonAllowance: false
            ),
            WorkbenchPageLayout.regularPadding
        )
        XCTAssertEqual(
            WorkspaceBottomContentMarginPolicy.resolvedMargin(
                explicitMargin: WorkbenchPageLayout.regularPadding,
                hasCompactTabBar: true,
                hasBottomTabBar: false,
                environmentClearance: WorkbenchPageLayout.regularPadding,
                includesFloatingActionButtonAllowance: true
            ),
            WorkbenchPageLayout.regularPadding + WorkspaceSessionFabMetrics.contentBottomAllowance
        )

        // 宽屏无 Tab 栏布局：不因默认环境 clearance 制造大块空白。
        XCTAssertEqual(
            WorkspaceBottomContentMarginPolicy.resolvedMargin(
                explicitMargin: nil,
                hasCompactTabBar: false,
                hasBottomTabBar: false,
                environmentClearance: 118,
                includesFloatingActionButtonAllowance: false
            ),
            WorkbenchPageLayout.regularPadding
        )
        XCTAssertEqual(
            WorkspaceBottomContentMarginPolicy.resolvedMargin(
                explicitMargin: nil,
                hasCompactTabBar: false,
                hasBottomTabBar: false,
                environmentClearance: 118,
                includesFloatingActionButtonAllowance: true
            ),
            WorkbenchPageLayout.regularPadding + WorkspaceSessionFabMetrics.contentBottomAllowance
        )
    }

    @MainActor
    func testCompactPhoneWorkspacesTabClearsBottomTabBarForBothSessionsAndSuggestions() async throws {
        // 分别测工作区详情页（25 条会话）与候选项目列表（20 个项目）在底部 Tab 栏下的实际滚动底部留白。
        let detailWithTabMargin = try await measureWorkspaceBottomScrollExtent(
            openedWorkspaces: true,
            bottomContentMargin: 118,
            hasBottomTabBar: true
        )
        let detailWithRegularMargin = try await measureWorkspaceBottomScrollExtent(
            openedWorkspaces: true,
            bottomContentMargin: WorkbenchPageLayout.regularPadding,
            hasBottomTabBar: true
        )
        XCTAssertGreaterThan(detailWithTabMargin.tabBarMinY, 700)
        XCTAssertGreaterThanOrEqual(
            detailWithTabMargin.totalBottomScrollExtent - detailWithRegularMargin.totalBottomScrollExtent,
            80,
            "工作区详情页必须把 bottomContentMargin (118pt) 真正作用到垂直滚动容器底部"
        )
        XCTAssertGreaterThanOrEqual(
            detailWithTabMargin.adjustedBottomInset,
            detailWithTabMargin.tabBarHeight,
            "工作区详情页垂直滚动容器的底部安全区/边距不得小于系统 Tab 栏高度"
        )

        let suggestionsWithTabMargin = try await measureWorkspaceBottomScrollExtent(
            openedWorkspaces: false,
            bottomContentMargin: 118,
            hasBottomTabBar: true
        )
        let suggestionsWithRegularMargin = try await measureWorkspaceBottomScrollExtent(
            openedWorkspaces: false,
            bottomContentMargin: WorkbenchPageLayout.regularPadding,
            hasBottomTabBar: true
        )
        XCTAssertGreaterThan(suggestionsWithTabMargin.tabBarMinY, 700)
        XCTAssertGreaterThanOrEqual(
            suggestionsWithTabMargin.totalBottomScrollExtent - suggestionsWithRegularMargin.totalBottomScrollExtent,
            80,
            "工作区候选项目列表必须把 bottomContentMargin (118pt) 作用到 ScrollView 底部，避免最后几行被 Tab 栏遮挡"
        )
        XCTAssertGreaterThanOrEqual(
            suggestionsWithTabMargin.adjustedBottomInset,
            suggestionsWithTabMargin.tabBarHeight,
            "工作区候选项目列表的底部安全区/边距不得小于系统 Tab 栏高度"
        )
    }

    // MARK: - Test Helpers

    private struct MeasuredScrollBottomExtent {
        let tabBarMinY: CGFloat
        let tabBarHeight: CGFloat
        let adjustedBottomInset: CGFloat
        let totalBottomScrollExtent: CGFloat
    }

    @MainActor
    private func measureWorkspaceBottomScrollExtent(
        openedWorkspaces: Bool,
        bottomContentMargin: CGFloat,
        hasBottomTabBar: Bool
    ) async throws -> MeasuredScrollBottomExtent {
        let (appStore, sessionStore, _) = makeOpenWorkspaceTestStores(
            projectCount: openedWorkspaces ? 3 : 20,
            sessionCount: openedWorkspaces ? 25 : 0,
            openedWorkspaces: openedWorkspaces
        )
        try await sessionStore.refreshWorkspaceCatalog()
        await sessionStore.refreshAppServerModelOptions()

        let suite = "WorkspaceTabInsetTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let themeStore = ThemeStore(defaults: defaults)
        let appearanceStore = WorkspaceAppearanceStore(defaults: defaults)

        let rootView = TabView {
            NavigationStack {
                WorkspaceRootView(
                    selectedSessionRuntime: .constant(.codex),
                    onStartSession: { _, _ in },
                    onOpenSession: { _ in },
                    manageConnections: nil,
                    embedsNavigationStack: false,
                    appearanceStore: appearanceStore,
                    initialWorkspaceID: openedWorkspaces ? "proj-0" : nil,
                    bottomContentMargin: bottomContentMargin
                )
            }
            .tabItem { Label("工作区", systemImage: "folder") }
        }
        .environmentObject(appStore)
        .environmentObject(sessionStore)
        .environmentObject(themeStore)
        .environmentObject(appearanceStore)
        .environment(\.workbenchBottomChromeClearance, bottomContentMargin)
        .environment(\.workbenchHasCompactTabBar, true)
        .environment(\.workbenchHasBottomTabBar, hasBottomTabBar)
        .environment(\.horizontalSizeClass, .compact)

        let window = makePhoneTestWindow(rootView: rootView)
        defer { tearDownTestWindow(window) }

        try? await Task.sleep(for: .milliseconds(450))
        window.rootViewController?.view.layoutIfNeeded()

        let allViews = allDescendantViews(in: window)
        let tabBar = try XCTUnwrap(
            allViews.compactMap { $0 as? UITabBar }.first { !$0.isHidden && $0.alpha > 0.01 },
            "紧凑布局下应当渲染底部 UITabBar"
        )
        let tabBarFrame = tabBar.convert(tabBar.bounds, to: window)

        let verticalScrollView = try XCTUnwrap(
            allViews
                .compactMap { $0 as? UIScrollView }
                .filter { !$0.isHidden && $0.alpha > 0.01 && $0.bounds.height > 200 && $0.contentSize.height > $0.bounds.height }
                .max(by: { $0.contentSize.height < $1.contentSize.height }),
            "应当找到工作区页的主垂直滚动容器"
        )

        return MeasuredScrollBottomExtent(
            tabBarMinY: tabBarFrame.minY,
            tabBarHeight: tabBarFrame.height,
            adjustedBottomInset: verticalScrollView.adjustedContentInset.bottom,
            totalBottomScrollExtent: verticalScrollView.contentSize.height + verticalScrollView.adjustedContentInset.bottom
        )
    }

    @MainActor
    private func makeOpenWorkspaceTestStores(
        projectCount: Int = 2,
        sessionCount: Int = 2,
        openedWorkspaces: Bool = true,
        directoryListResults: [String: Result<DirectoryListResponse, Error>] = [:]
    ) -> (AppStore, SessionStore, MockSessionStoreClient) {
        let suite = "WorkspaceStripPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: TestKeychainOperations()))
        appStore.endpoint = "http://demo-mac.local:8787"
        appStore.token = "test-token"

        let projects = (0..<projectCount).map { index in
            AgentProject(id: "proj-\(index)", name: "project-\(index)", path: "/Users/me/code/project-\(index)")
        }
        let now = Date()
        let sessions = (0..<sessionCount).map { index in
            AgentSession(
                id: "sess-\(index)",
                projectID: projects[0].id,
                project: projects[0].name,
                dir: projects[0].path,
                title: "Session Row \(index)",
                status: SessionStatus.completed.rawValue,
                source: "codex",
                runtimeProvider: "codex",
                resumeID: "sess-\(index)",
                createdAt: now.addingTimeInterval(TimeInterval(-index * 120)),
                updatedAt: now.addingTimeInterval(TimeInterval(-index * 60))
            )
        }
        var projectSessions: [String: [AgentSession]] = [:]
        var workspaceSessions: [String: [AgentSession]] = [:]
        var workspacePages: [String: SessionsPage] = [:]
        for (index, project) in projects.enumerated() {
            let list = index == 0 ? sessions : []
            projectSessions[project.id] = list
            workspaceSessions[project.id] = list
            workspacePages[project.id] = SessionsPage(
                sessions: list,
                nextCursor: nil,
                hasMore: index == 0 && sessionCount >= 20
            )
        }
        let workspaces = openedWorkspaces
            ? projects.enumerated().map { index, project in
                AgentWorkspace(project: project, lastOpenedAt: now.addingTimeInterval(TimeInterval(-(index + 1) * 60)))
            }
            : []
        let recentStore = makeRecentWorkspaceStore(workspaces: workspaces, endpoint: appStore.endpoint)
        let client = MockSessionStoreClient(
            projects: projects,
            sessions: [],
            projectSessions: projectSessions,
            workspaceSessions: workspaceSessions,
            workspacePages: workspacePages,
            directoryListResults: directoryListResults,
            runtimeChannelAvailability: ["codex": true, "claude": true]
        )
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: recentStore,
            clientFactory: { client }
        )
        sessionStore.reloadRecentWorkspaces()
        sessionStore.projects = projects
        sessionStore.sessions = sessions
        sessionStore.availableRuntimeProviders = ["codex", "claude"]
        return (appStore, sessionStore, client)
    }

    @MainActor
    private func makePhoneTestWindow<Content: View>(rootView: Content) -> UIWindow {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: rootView)
        host.traitOverrides.userInterfaceIdiom = UIUserInterfaceIdiom.phone
        host.traitOverrides.horizontalSizeClass = UIUserInterfaceSizeClass.compact
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = bounds
        } else {
            window = UIWindow(frame: bounds)
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = bounds
        host.view.layoutIfNeeded()
        return window
    }

    @MainActor
    private func tearDownTestWindow(_ window: UIWindow) {
        window.rootViewController?.dismiss(animated: false)
        window.rootViewController = nil
        window.isHidden = true
    }

    @MainActor
    private func allDescendantViews(in root: UIView) -> [UIView] {
        var result: [UIView] = [root]
        for subview in root.subviews {
            result.append(contentsOf: allDescendantViews(in: subview))
        }
        return result
    }
}
