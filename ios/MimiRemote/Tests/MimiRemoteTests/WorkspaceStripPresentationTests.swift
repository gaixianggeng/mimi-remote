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
        model.attach(sessionStore: sessionStore)

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
    func testOpenWorkspaceSheetReleasesModelAfterDismissal() async throws {
        let rootResponse = DirectoryListResponse(
            path: "/Users/me",
            parentPath: "/Users",
            entries: [
                DirectoryEntry(name: "finance", path: "/Users/me/finance", isDir: true, canOpen: true, canBrowse: true),
            ],
            truncated: false
        )
        let openedWorkspace = AgentWorkspace(
            project: AgentProject(id: "proj-finance", name: "finance", path: "/Users/me/finance"),
            lastOpenedAt: Date()
        )
        let (appStore, sessionStore, _) = makeOpenWorkspaceTestStores(
            directoryListResults: [
                "": .success(rootResponse),
                "/Users/me": .success(rootResponse),
            ],
            resolveResults: [
                "/Users/me/finance": .success(openedWorkspace),
            ]
        )
        let themeStore = ThemeStore(defaults: UserDefaults(suiteName: "OpenWorkspaceSheetReleaseTest.\(UUID().uuidString)")!)

        final class ClosureCaptureProbe {}

        final class ReleaseRecorder {
            var createdModels: [WeakOpenWorkspaceSheetModel] = []
            var callbackProbes: [WeakClosureCaptureProbe] = []
            var openedWorkspaceIDs: [String] = []
        }

        struct WeakOpenWorkspaceSheetModel {
            weak var value: OpenWorkspaceSheetModel?
        }

        struct WeakClosureCaptureProbe {
            weak var value: ClosureCaptureProbe?
        }

        // 使用与 WorkspaceRootView 相同的 OpenWorkspaceSheetPresenter + 实例方法回调接线，
        // 同时用 ClosureCaptureProbe 显式验证 OpenWorkspaceSheetModel 不会保存逃逸的 onOpened 闭包。
        struct PresenterReleaseHost: View {
            @EnvironmentObject var sessionStore: SessionStore
            @StateObject private var openWorkspacePresenter = OpenWorkspaceSheetPresenter()
            @State private var selectedWorkspaceID: String?
            let recorder: ReleaseRecorder

            var body: some View {
                VStack {
                    Text("sessions:\(sessionStore.sessions.count)")
                    Text("selected:\(selectedWorkspaceID ?? "none")")
                    Button("Present Open Workspace") {
                        presentOpenWorkspaceSheet()
                    }
                    .accessibilityIdentifier("test.openWorkspace.present")
                }
                .sheet(item: $openWorkspacePresenter.presentation) { presentation in
                    let probe = ClosureCaptureProbe()
                    recorder.callbackProbes.append(WeakClosureCaptureProbe(value: probe))
                    return OpenWorkspaceSheet(model: presentation.model) { workspaceID in
                        _ = probe
                        selectWorkspace(id: workspaceID)
                    }
                }
            }

            private func presentOpenWorkspaceSheet() {
                let model = OpenWorkspaceSheetModel()
                recorder.createdModels.append(WeakOpenWorkspaceSheetModel(value: model))
                openWorkspacePresenter.present(model: model)
            }

            private func selectWorkspace(id: String) {
                selectedWorkspaceID = id
                recorder.openedWorkspaceIDs.append(id)
            }
        }

        _ = await waitUntil(timeout: .seconds(3)) {
            OpenWorkspaceSheetModel.liveInstanceCountForTesting == 0
        }
        let baselineLiveModelCount = OpenWorkspaceSheetModel.liveInstanceCountForTesting
        let recorder = ReleaseRecorder()
        let rootView = PresenterReleaseHost(recorder: recorder)
            .environmentObject(appStore)
            .environmentObject(sessionStore)
            .environmentObject(themeStore)
            .environment(\.horizontalSizeClass, .compact)

        let testWindow = makePhoneTestWindow(rootView: rootView)
        defer { testWindow.tearDown() }
        let window = testWindow.window

        let presentButtonReady = await waitUntil(timeout: .seconds(3)) {
            self.findAccessibilityElement(
                identifier: "test.openWorkspace.present",
                in: window
            ) != nil
        }
        XCTAssertTrue(presentButtonReady, "测试宿主呈现按钮应当可用")

        // 1. 打开 Sheet、触发 SessionStore 刷新并展开手动路径；在外部暂时强持有 model 的情况下点击取消，
        //    先证明关闭后 onOpened 闭包已释放（model 未持有 onOpened），再释放外部强引用验证 model 回收。
        XCTAssertTrue(
            activateAccessibilityElement(identifier: "test.openWorkspace.present", in: window),
            "首次应当能触发测试宿主弹出 Sheet"
        )

        let firstPresented = await waitUntil(timeout: .seconds(3)) {
            recorder.createdModels.count == 1
                && !recorder.callbackProbes.isEmpty
                && window.rootViewController?.presentedViewController?.view != nil
                && recorder.createdModels.first?.value?.browsePath == "/Users/me"
        }
        XCTAssertTrue(firstPresented, "首次 OpenWorkspaceSheet 应当完成呈现并加载根目录")

        let firstRecord = try XCTUnwrap(recorder.createdModels.first, "首次呈现后应当记录已创建的 model")
        var temporarilyRetainedFirstModel: OpenWorkspaceSheetModel? = firstRecord.value
        XCTAssertNotNil(temporarilyRetainedFirstModel)
        temporarilyRetainedFirstModel?.isManualPathExpanded = true
        temporarilyRetainedFirstModel?.updateManualPath("/Users/me/finance")
        sessionStore.objectWillChange.send()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(
            activateAccessibilityElement(
                identifier: "workspace.open.cancel",
                in: window.rootViewController?.presentedViewController?.view
            ),
            "取消按钮应当可触发关闭"
        )

        let firstCallbackReleased = await waitUntil(timeout: .seconds(4)) {
            window.rootViewController?.presentedViewController == nil
                && recorder.callbackProbes.allSatisfy { $0.value == nil }
        }
        XCTAssertTrue(
            firstCallbackReleased,
            "关闭 Sheet 后即使模型本身仍存活，onOpened 闭包捕获对象也必须释放（证明模型未持有 onOpened）"
        )
        XCTAssertNotNil(temporarilyRetainedFirstModel)

        temporarilyRetainedFirstModel = nil
        let firstModelReleased = await waitUntil(timeout: .seconds(4)) {
            recorder.createdModels.first?.value == nil
                && OpenWorkspaceSheetModel.liveInstanceCountForTesting == baselineLiveModelCount
        }
        XCTAssertTrue(firstModelReleased, "点击取消关闭 Sheet 后，OpenWorkspaceSheetModel 必须被释放")
        XCTAssertNil(recorder.createdModels.first?.value)
        XCTAssertEqual(OpenWorkspaceSheetModel.liveInstanceCountForTesting, baselineLiveModelCount)

        // 2. 再次打开新 Sheet，通过界面提交成功打开路径：视图应回调 presenter、自动关闭并释放第二个 model。
        XCTAssertTrue(
            activateAccessibilityElement(identifier: "test.openWorkspace.present", in: window),
            "二次应当能触发测试宿主弹出 Sheet"
        )

        let secondPresented = await waitUntil(timeout: .seconds(3)) {
            recorder.createdModels.count == 2
                && window.rootViewController?.presentedViewController?.view != nil
                && recorder.createdModels.dropFirst().first?.value?.browsePath == "/Users/me"
        }
        XCTAssertTrue(secondPresented, "再次打开的 OpenWorkspaceSheet 应当完成呈现")
        do {
            let secondModel = try XCTUnwrap(
                recorder.createdModels.dropFirst().first?.value,
                "再次打开后应当记录第二个 model"
            )
            XCTAssertEqual(secondModel.path, "", "重新打开的 Sheet 应当拥有干净的空路径草稿")
            secondModel.isManualPathExpanded = true
            secondModel.updateManualPath("/Users/me/finance")
        }
        let submitReady = await waitUntil(timeout: .seconds(3)) {
            self.scrollPresentedSheetToBottom(in: window)
            guard let submit = self.findAccessibilityElement(
                identifier: "workspace.open.manualPath.submit",
                in: window.rootViewController?.presentedViewController?.view
            ) else {
                return false
            }
            return !submit.accessibilityTraits.contains(.notEnabled)
        }
        XCTAssertTrue(submitReady, "输入有效路径后提交按钮应当可用")

        XCTAssertTrue(
            activateAccessibilityElement(
                identifier: "workspace.open.manualPath.submit",
                in: window.rootViewController?.presentedViewController?.view
            ),
            "激活提交按钮应触发打开路径流程"
        )

        let secondReleased = await waitUntil(timeout: .seconds(4)) {
            recorder.openedWorkspaceIDs == ["proj-finance"]
                && window.rootViewController?.presentedViewController == nil
                && recorder.createdModels.dropFirst().first?.value == nil
                && recorder.callbackProbes.allSatisfy { $0.value == nil }
                && OpenWorkspaceSheetModel.liveInstanceCountForTesting == baselineLiveModelCount
        }
        XCTAssertEqual(recorder.openedWorkspaceIDs, ["proj-finance"])
        XCTAssertNil(window.rootViewController?.presentedViewController)
        XCTAssertTrue(secondReleased, "成功打开工作区后视图应自动关闭 Sheet 并释放 OpenWorkspaceSheetModel")
        XCTAssertNil(recorder.createdModels.dropFirst().first?.value)
        XCTAssertEqual(OpenWorkspaceSheetModel.liveInstanceCountForTesting, baselineLiveModelCount)
    }

    @MainActor
    func testWorkspaceRootViewReleasesOpenWorkspaceSheetModelsAcrossSubmitAndCancellations() async throws {
        let previousClipboardItems = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousClipboardItems }

        let rootResponse = DirectoryListResponse(
            path: "/Users/me",
            parentPath: "/Users",
            entries: [
                DirectoryEntry(name: "finance", path: "/Users/me/finance", isDir: true, canOpen: true, canBrowse: true),
            ],
            truncated: false
        )
        let openedWorkspace = AgentWorkspace(
            project: AgentProject(id: "proj-finance", name: "finance", path: "/Users/me/finance"),
            lastOpenedAt: Date()
        )
        let (appStore, sessionStore, _) = makeOpenWorkspaceTestStores(
            projectCount: 2,
            sessionCount: 2,
            openedWorkspaces: true,
            directoryListResults: [
                "": .success(rootResponse),
                "/Users/me": .success(rootResponse),
            ],
            resolveResults: [
                "/Users/me/finance": .success(openedWorkspace),
            ]
        )
        try await sessionStore.refreshWorkspaceCatalog()
        await sessionStore.refreshAppServerModelOptions()

        let suite = "WorkspaceRootOpenSheetReleaseTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let themeStore = ThemeStore(defaults: defaults)
        let appearanceStore = WorkspaceAppearanceStore(defaults: defaults)

        var selectedWorkspaceChanges: [String?] = []
        var catalogRefreshFinished = false
        let openWorkspacePresenter = OpenWorkspaceSheetPresenter()
        _ = await waitUntil(timeout: .seconds(3)) {
            OpenWorkspaceSheetModel.liveInstanceCountForTesting == 0
        }
        let baselineLiveModelCount = OpenWorkspaceSheetModel.liveInstanceCountForTesting

        let workspaceRoot = WorkspaceRootView(
            selectedSessionRuntime: .constant(.codex),
            onStartSession: { _, _ in },
            onOpenSession: { _ in },
            manageConnections: nil,
            embedsNavigationStack: true,
            appearanceStore: appearanceStore,
            openWorkspacePresenter: openWorkspacePresenter,
            initialWorkspaceID: "proj-0",
            bottomContentMargin: 118,
            onWorkspaceSelectionChange: { selectedWorkspaceID in
                selectedWorkspaceChanges.append(selectedWorkspaceID)
            },
            onCatalogRefreshEvent: { _, isFinished in
                if isFinished {
                    catalogRefreshFinished = true
                }
            }
        )
        let hostedRoot = workspaceRoot
            .environmentObject(appStore)
            .environmentObject(sessionStore)
            .environmentObject(themeStore)
            .environmentObject(appearanceStore)
            .environment(\.workbenchBottomChromeClearance, 118)
            .environment(\.workbenchHasCompactTabBar, true)
            .environment(\.workbenchHasBottomTabBar, true)
            .environment(\.horizontalSizeClass, .compact)

        let testWindow = makePhoneTestWindow(rootView: hostedRoot)
        defer { testWindow.tearDown() }
        let window = testWindow.window

        let workspaceStripReady = await waitUntil(timeout: .seconds(4)) {
            testWindow.enforcePhoneBoundsAndLayout()
            guard catalogRefreshFinished, sessionStore.sidebarProjects.count == 2 else {
                return false
            }
            let scrollViews = self.allDescendantViews(in: window).compactMap { $0 as? UIScrollView }
            let hasStripScroll = scrollViews.contains { !$0.isHidden && $0.bounds.height > 40 && $0.bounds.height <= 120 }
            let hasPagerOrDetailScroll = scrollViews.contains { !$0.isHidden && $0.bounds.height > 200 }
            return hasStripScroll && hasPagerOrDetailScroll
        }
        XCTAssertTrue(workspaceStripReady, "生产 WorkspaceRootView 应当完成目录刷新并渲染工作区胶囊条")
        XCTAssertNil(openWorkspacePresenter.presentation)
        XCTAssertEqual(OpenWorkspaceSheetModel.liveInstanceCountForTesting, baselineLiveModelCount)

        let presentSheetFromWorkspaceRoot: () -> Bool = {
            if let openDirectoryButton = self.findAccessibilityElement(
                identifier: "workspace.toolbar.openDirectory",
                in: window
            ) {
                return openDirectoryButton.accessibilityActivate()
            }
            // 无外部 AX 客户端（未加载 SwiftUI.axbundle）时，SwiftUI.HostingScrollView 的
            // accessibilityElements 为空；直接调用与 addWorkspaceChip 同源的 presenter.present()
            // 触发生产 WorkspaceRootView 的 .sheet(item:) 呈现链路。
            openWorkspacePresenter.present()
            return openWorkspacePresenter.presentation != nil
        }

        // 1. 走生产 WorkspaceRootView 打开 Sheet、提交有效路径并确认工作区切换与模型释放。
        XCTAssertTrue(
            presentSheetFromWorkspaceRoot(),
            "应能通过生产工作区入口弹出 OpenWorkspaceSheet"
        )

        let firstSheetReady = await waitUntil(timeout: .seconds(4)) {
            guard let presentedView = window.rootViewController?.presentedViewController?.view else {
                return false
            }
            let toggle = self.findAccessibilityElement(
                identifier: "workspace.open.manualPath.toggle",
                in: presentedView
            )
            let currentOpen = self.findAccessibilityElement(
                identifier: "workspace.open.current",
                in: presentedView
            )
            let browseReady = currentOpen.map { !$0.accessibilityTraits.contains(.notEnabled) } ?? false
            return toggle != nil
                && browseReady
                && OpenWorkspaceSheetModel.liveInstanceCountForTesting > baselineLiveModelCount
        }
        XCTAssertTrue(firstSheetReady, "生产 WorkspaceRootView 弹出的 Sheet 应当完成初始目录加载")

        // 模拟 Sheet 打开期间 SessionStore 轮询触发父层重绘。
        sessionStore.objectWillChange.send()
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(
            activateAccessibilityElement(
                identifier: "workspace.open.manualPath.toggle",
                in: window.rootViewController?.presentedViewController?.view
            ),
            "应能展开手动输入路径区"
        )

        let textFieldReady = await waitUntil(timeout: .seconds(3)) {
            self.scrollPresentedSheetToBottom(in: window)
            return self.findLiveManualPathTextField(in: window) != nil
        }
        XCTAssertTrue(textFieldReady, "展开后应当挂载手动路径输入框")

        let pasted = await pasteIntoLiveManualPathTextField("/Users/me/finance", in: window)
        XCTAssertTrue(pasted, "应当能向手动路径输入框粘贴路径")

        let submitReady = await waitUntil(timeout: .seconds(3)) {
            self.scrollPresentedSheetToBottom(in: window)
            guard let submit = self.findAccessibilityElement(
                identifier: "workspace.open.manualPath.submit",
                in: window.rootViewController?.presentedViewController?.view
            ) else {
                return false
            }
            return !submit.accessibilityTraits.contains(.notEnabled)
        }
        XCTAssertTrue(submitReady, "粘贴有效路径后提交按钮应当可用")

        XCTAssertTrue(
            activateAccessibilityElement(
                identifier: "workspace.open.manualPath.submit",
                in: window.rootViewController?.presentedViewController?.view
            ),
            "激活提交按钮应触发打开目录"
        )

        let submittedAndReleased = await waitUntil(timeout: .seconds(4)) {
            selectedWorkspaceChanges.contains("proj-finance")
                && window.rootViewController?.presentedViewController == nil
                && openWorkspacePresenter.presentation == nil
                && OpenWorkspaceSheetModel.liveInstanceCountForTesting == baselineLiveModelCount
        }
        XCTAssertTrue(selectedWorkspaceChanges.contains("proj-finance"), "提交成功后生产 WorkspaceRootView 应切换到新工作区")
        XCTAssertNil(window.rootViewController?.presentedViewController)
        XCTAssertNil(openWorkspacePresenter.presentation)
        XCTAssertTrue(
            submittedAndReleased,
            "成功提交关闭 Sheet 后，生产 WorkspaceRootView 不应滞留任何 OpenWorkspaceSheetModel（当前 \(OpenWorkspaceSheetModel.liveInstanceCountForTesting)，基线 \(baselineLiveModelCount)）"
        )
        XCTAssertEqual(OpenWorkspaceSheetModel.liveInstanceCountForTesting, baselineLiveModelCount)

        // 2. 连续三次打开并取消 Sheet，确认活对象数每次都回到基线而非 1->2->3->4 递增。
        for attempt in 1...3 {
            XCTAssertTrue(
                presentSheetFromWorkspaceRoot(),
                "第 \(attempt) 次应能打开 Sheet"
            )

            let presented = await waitUntil(timeout: .seconds(4)) {
                guard let presentedView = window.rootViewController?.presentedViewController?.view else {
                    return false
                }
                let cancel = self.findAccessibilityElement(
                    identifier: "workspace.open.cancel",
                    in: presentedView
                )
                let currentOpen = self.findAccessibilityElement(
                    identifier: "workspace.open.current",
                    in: presentedView
                )
                let browseReady = currentOpen.map { !$0.accessibilityTraits.contains(.notEnabled) } ?? false
                return cancel != nil
                    && browseReady
                    && OpenWorkspaceSheetModel.liveInstanceCountForTesting > baselineLiveModelCount
            }
            XCTAssertTrue(presented, "第 \(attempt) 次打开的 Sheet 应当完成呈现")

            // 在 Sheet 打开期间触发父层刷新，取消后不再触发任何额外刷新，验证不会滞留最后一次 model。
            sessionStore.objectWillChange.send()
            try? await Task.sleep(for: .milliseconds(100))

            XCTAssertTrue(
                activateAccessibilityElement(
                    identifier: "workspace.open.cancel",
                    in: window.rootViewController?.presentedViewController?.view
                ),
                "第 \(attempt) 次应能通过取消关闭 Sheet"
            )

            let cancelledAndReleased = await waitUntil(timeout: .seconds(4)) {
                window.rootViewController?.presentedViewController == nil
                    && openWorkspacePresenter.presentation == nil
                    && OpenWorkspaceSheetModel.liveInstanceCountForTesting == baselineLiveModelCount
            }
            XCTAssertNil(window.rootViewController?.presentedViewController, "第 \(attempt) 次取消后 Sheet 应当关闭")
            XCTAssertNil(openWorkspacePresenter.presentation, "第 \(attempt) 次取消后 presenter 不应滞留 presentation")
            XCTAssertTrue(
                cancelledAndReleased,
                "第 \(attempt) 次取消关闭 Sheet 后，OpenWorkspaceSheetModel 活对象数必须回到基线（当前 \(OpenWorkspaceSheetModel.liveInstanceCountForTesting)，基线 \(baselineLiveModelCount)）"
            )
            XCTAssertEqual(OpenWorkspaceSheetModel.liveInstanceCountForTesting, baselineLiveModelCount)
        }
    }

    @MainActor
    func testOpenWorkspaceSheetRenderedManualPathSurvivesPasteAndSessionStorePolling() async throws {
        let previousClipboardItems = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousClipboardItems }

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
        let openedWorkspace = AgentWorkspace(
            project: AgentProject(id: "proj-finance", name: "finance", path: "/Users/me/finance"),
            lastOpenedAt: Date()
        )
        let (appStore, sessionStore, client) = makeOpenWorkspaceTestStores(
            directoryListResults: [
                "": .success(rootResponse),
                "/Users/me": .success(rootResponse),
                "/Users/me/folder-0": .success(childResponse),
            ],
            resolveResults: [
                "/Users/me/finance": .success(openedWorkspace),
            ]
        )
        let themeStore = ThemeStore(defaults: UserDefaults(suiteName: "OpenWorkspaceSheetTest.\(UUID().uuidString)")!)

        final class SheetPresenterState: ObservableObject {
            @Published var presentation: OpenWorkspaceSheetPresentation?
            var openedWorkspaceIDs: [String] = []
        }

        struct ParentObservingHost: View {
            @EnvironmentObject var sessionStore: SessionStore
            @ObservedObject var presenter: SheetPresenterState

            var body: some View {
                VStack {
                    Text("sessions:\(sessionStore.sessions.count)")
                }
                .sheet(item: $presenter.presentation) { presentation in
                    OpenWorkspaceSheet(model: presentation.model) { workspaceID in
                        presenter.openedWorkspaceIDs.append(workspaceID)
                    }
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

        let testWindow = makePhoneTestWindow(rootView: rootView)
        defer { testWindow.tearDown() }
        let window = testWindow.window

        let sheetPresented = await waitUntil(timeout: .seconds(3)) {
            window.rootViewController?.presentedViewController?.view != nil
                && presentation.model.browsePath == "/Users/me"
        }
        XCTAssertTrue(sheetPresented, "OpenWorkspaceSheet 应当已呈现")

        presentation.model.isManualPathExpanded = true
        let initialFieldMounted = await waitUntil(timeout: .seconds(3)) {
            self.scrollPresentedSheetToBottom(in: window)
            return self.findLiveManualPathTextField(in: window) != nil
        }
        XCTAssertTrue(initialFieldMounted, "展开手动输入路径后应当挂载稳定输入框")

        let initialTextField = try XCTUnwrap(
            findLiveManualPathTextField(in: window),
            "展开手动输入路径后应当挂载稳定输入框"
        )
        if let submitBeforePaste = findAccessibilityElement(
            identifier: "workspace.open.manualPath.submit",
            in: window.rootViewController?.presentedViewController?.view
        ) {
            XCTAssertTrue(
                submitBeforePaste.accessibilityTraits.contains(.notEnabled),
                "粘贴路径前手动提交按钮应当禁用"
            )
        }

        initialTextField.becomeFirstResponder()
        try? await Task.sleep(for: .milliseconds(150))
        UIPasteboard.general.string = "/Users/me/finance"
        initialTextField.paste(nil)
        let pasteSynced = await waitUntil(timeout: .seconds(2)) {
            presentation.model.path == "/Users/me/finance"
                && initialTextField.text == "/Users/me/finance"
        }
        XCTAssertTrue(pasteSynced, "粘贴后模型与输入框都应立即同步路径")
        XCTAssertEqual(presentation.model.path, "/Users/me/finance")
        XCTAssertEqual(initialTextField.text, "/Users/me/finance")
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

        // 从当前呈现窗口重新定位正在显示的输入框，而不是读取可能已脱离窗口的旧实例。
        let fieldPresentAfterBrowse = await waitUntil(timeout: .seconds(3)) {
            self.scrollPresentedSheetToBottom(in: window)
            return self.findLiveManualPathTextField(in: window) != nil
        }
        XCTAssertTrue(fieldPresentAfterBrowse, "目录切换后当前窗口中仍应呈现手动路径输入框")
        let liveFieldAfterBrowse = try XCTUnwrap(findLiveManualPathTextField(in: window))
        XCTAssertTrue(liveFieldAfterBrowse.window === window)
        XCTAssertFalse(liveFieldAfterBrowse.isHidden)
        XCTAssertGreaterThan(liveFieldAfterBrowse.alpha, 0.01)
        XCTAssertGreaterThan(liveFieldAfterBrowse.bounds.height, 0)
        XCTAssertEqual(liveFieldAfterBrowse.text, "/Users/me/finance")

        // 触发一次真实的折叠卸载再展开重建，确保替换后的新 UITextField 仍可见地显示已粘贴路径且提交按钮可点。
        presentation.model.isManualPathExpanded = false
        let fieldUnmounted = await waitUntil(timeout: .seconds(3)) {
            self.findLiveManualPathTextField(in: window) == nil && initialTextField.window == nil
        }
        XCTAssertTrue(fieldUnmounted, "折叠手动路径区后原 UITextField 应当从窗口卸载")

        presentation.model.isManualPathExpanded = true
        let remountedReady = await waitUntil(timeout: .seconds(3)) {
            self.scrollPresentedSheetToBottom(in: window)
            guard let field = self.findLiveManualPathTextField(in: window) else {
                return false
            }
            return field !== initialTextField && field.bounds.height > 0
        }
        XCTAssertTrue(remountedReady, "重新展开后应当挂载新的可见 UITextField 实例")

        let remountedTextField = try XCTUnwrap(
            findLiveManualPathTextField(in: window),
            "重新展开后应当能从当前窗口重新找到手动路径输入框"
        )
        XCTAssertTrue(remountedTextField !== initialTextField, "重建后的输入框必须是新的 UITextField 实例")
        XCTAssertTrue(remountedTextField.window === window)
        XCTAssertFalse(remountedTextField.isHidden)
        XCTAssertGreaterThan(remountedTextField.alpha, 0.01)
        XCTAssertGreaterThan(remountedTextField.bounds.height, 0)
        XCTAssertEqual(remountedTextField.text, "/Users/me/finance")

        let submitReady = await waitUntil(timeout: .seconds(3)) {
            self.scrollPresentedSheetToBottom(in: window)
            guard let submit = self.findAccessibilityElement(
                identifier: "workspace.open.manualPath.submit",
                in: window.rootViewController?.presentedViewController?.view
            ) else {
                return false
            }
            return !submit.accessibilityTraits.contains(.notEnabled)
                && !submit.accessibilityFrame.isEmpty
        }
        XCTAssertTrue(submitReady, "重新展开后应当能从当前窗口找到可用的手动路径提交按钮")
        let submitButton = try XCTUnwrap(
            findAccessibilityElement(
                identifier: "workspace.open.manualPath.submit",
                in: window.rootViewController?.presentedViewController?.view
            ),
            "重新展开后应当能从当前窗口找到手动路径提交按钮"
        )
        XCTAssertTrue(submitButton.accessibilityTraits.contains(.button))
        XCTAssertFalse(
            submitButton.accessibilityTraits.contains(.notEnabled),
            "替换后的输入框已有有效粘贴路径，提交按钮必须处于可点状态"
        )
        XCTAssertFalse(submitButton.accessibilityFrame.isEmpty)

        XCTAssertEqual(presentation.model.path, "/Users/me/finance")
        XCTAssertTrue(presentation.model.isManualPathExpanded)
        XCTAssertTrue(presentation.model.canOpenTypedPath)
        XCTAssertEqual(client.requestedDirectoryPaths, ["", "/Users/me/folder-0"])

        XCTAssertTrue(submitButton.accessibilityActivate(), "可点提交按钮应能直接提交已粘贴路径")
        let openedFromSubmit = await waitUntil(timeout: .seconds(3)) {
            presenter.openedWorkspaceIDs == ["proj-finance"]
        }
        XCTAssertTrue(openedFromSubmit, "激活提交按钮后应打开粘贴的工作区路径")
    }

    @MainActor
    func testOpenWorkspaceManualPathTextFieldUpdateGuardPreservesActiveText() async throws {
        let previousClipboardItems = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousClipboardItems }

        final class ManualPathFieldHostState: ObservableObject {
            @Published var text = ""
            @Published var placeholder = "/Users/me/finance"
            @Published var isMounted = true
            @Published var remountID = UUID()
        }

        struct ManualPathFieldHostView: View {
            @ObservedObject var state: ManualPathFieldHostState

            var body: some View {
                VStack {
                    if state.isMounted {
                        OpenWorkspaceManualPathTextField(
                            placeholder: state.placeholder,
                            text: $state.text,
                            fontSize: 13,
                            textColor: .label,
                            placeholderColor: .secondaryLabel,
                            onFocusChange: { _ in },
                            onSubmit: {}
                        )
                        .id(state.remountID)
                        .frame(height: 44)
                    }
                }
                .padding()
            }
        }

        let state = ManualPathFieldHostState()
        let testWindow = makePhoneTestWindow(rootView: ManualPathFieldHostView(state: state))
        defer { testWindow.tearDown() }
        let window = testWindow.window

        let mounted = await waitUntil(timeout: .seconds(2)) {
            self.findLiveManualPathTextField(in: window, searchRoot: window) != nil
        }
        XCTAssertTrue(mounted, "托管的 OpenWorkspaceManualPathTextField 应当完成挂载")

        let textField = try XCTUnwrap(findLiveManualPathTextField(in: window, searchRoot: window))
        textField.becomeFirstResponder()
        try? await Task.sleep(for: .milliseconds(100))

        // 1. 真实粘贴走生产 Coordinator，立即同步到 SwiftUI Binding。
        UIPasteboard.general.string = "/Users/me/finance"
        textField.paste(nil)
        let pasted = await waitUntil(timeout: .seconds(2)) {
            state.text == "/Users/me/finance" && textField.text == "/Users/me/finance"
        }
        XCTAssertTrue(pasted)
        XCTAssertEqual(state.text, "/Users/me/finance")
        XCTAssertEqual(textField.text, "/Users/me/finance")

        // 2. 模拟 UIKit 局部编辑尚未回传时外部触发无关重绘（binding 仍等于 lastSyncedText）：
        // 生产 updateUIView 必须实际执行（以 placeholder 更新为证），且不得把输入框回写成旧值。
        textField.text = "/Users/me/finance/in-progress"
        state.placeholder = "redraw-guard-check"
        let guardRedrawApplied = await waitUntil(timeout: .seconds(2)) {
            textField.attributedPlaceholder?.string == "redraw-guard-check"
        }
        XCTAssertTrue(guardRedrawApplied, "SwiftUI 应调用生产 updateUIView 刷新占位符")
        XCTAssertEqual(
            textField.text,
            "/Users/me/finance/in-progress",
            "binding 未偏离 lastSyncedText 时，生产 updateUIView 不应覆盖当前编辑中的文本"
        )

        // 3. IME 组合态（markedTextRange != nil）下，即使外部修改 binding，生产 updateUIView 也不得打断组合输入。
        textField.text = "/Users/me/"
        textField.sendActions(for: .editingChanged)
        _ = await waitUntil(timeout: .seconds(2)) { state.text == "/Users/me/" }
        textField.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertNotNil(textField.markedTextRange, "输入框应处于 IME 组合态")

        state.text = "/Users/me/external-during-ime"
        state.placeholder = "redraw-ime-guard"
        let imeRedrawApplied = await waitUntil(timeout: .seconds(2)) {
            textField.attributedPlaceholder?.string == "redraw-ime-guard"
        }
        XCTAssertTrue(imeRedrawApplied, "IME 组合态期间生产 updateUIView 应当已执行")
        XCTAssertNotNil(textField.markedTextRange)
        XCTAssertNotEqual(
            textField.text,
            "/Users/me/external-during-ime",
            "存在 markedTextRange 时，生产 updateUIView 不得覆写输入框文本"
        )

        textField.unmarkText()
        let unmarked = await waitUntil(timeout: .seconds(2)) { textField.markedTextRange == nil }
        XCTAssertTrue(unmarked)

        // 4. 外部通过 binding 改写和清空文本时，生产 updateUIView 必须同步 UIKit 文本并更新 lastSyncedText。
        state.text = "/Users/me/finance"
        state.placeholder = "redraw-external-set"
        let externalSetApplied = await waitUntil(timeout: .seconds(2)) {
            textField.attributedPlaceholder?.string == "redraw-external-set"
                && textField.text == "/Users/me/finance"
        }
        XCTAssertTrue(externalSetApplied, "外部更新 binding 时生产 updateUIView 应写回 UITextField")

        state.text = ""
        state.placeholder = "redraw-external-clear"
        let externalClearApplied = await waitUntil(timeout: .seconds(2)) {
            textField.attributedPlaceholder?.string == "redraw-external-clear"
                && textField.text == ""
        }
        XCTAssertTrue(externalClearApplied, "外部清空 binding 时生产 updateUIView 应清空 UITextField")
        XCTAssertEqual(textField.text, "")

        // 清空后重新粘贴同一个路径：若生产 updateUIView 漏更新 lastSyncedText，此处会静默丢弃粘贴。
        UIPasteboard.general.string = "/Users/me/finance"
        textField.paste(nil)
        let repasted = await waitUntil(timeout: .seconds(2)) {
            state.text == "/Users/me/finance" && textField.text == "/Users/me/finance"
        }
        XCTAssertTrue(repasted, "外部清空后再次粘贴同一路径必须仍能写回 binding")

        // 5. 触发真实卸载并重建后，新建的 UITextField 必须从生产 makeUIView 恢复当前 binding 文本。
        //    先让旧输入框退出第一响应者并卸载，避免 iOS 27 在仅修改 .id 且输入框仍聚焦时延迟移除旧视图。
        textField.resignFirstResponder()
        state.isMounted = false
        let unmounted = await waitUntil(timeout: .seconds(2)) {
            self.findLiveManualPathTextField(in: window, searchRoot: window) == nil
                && textField.window == nil
        }
        XCTAssertTrue(unmounted, "卸载后原 UITextField 应当从窗口移除")

        state.remountID = UUID()
        state.isMounted = true
        let remounted = await waitUntil(timeout: .seconds(2)) {
            guard let live = self.findLiveManualPathTextField(in: window, searchRoot: window) else {
                return false
            }
            return live !== textField && live.bounds.height > 0
        }
        XCTAssertTrue(remounted, "修改视图 id 并重新挂载后应挂载新的 UITextField 实例")
        let replacementField = try XCTUnwrap(findLiveManualPathTextField(in: window, searchRoot: window))
        XCTAssertTrue(replacementField !== textField)
        XCTAssertEqual(replacementField.text, "/Users/me/finance")
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

        var catalogRefreshFinished = false
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
                    bottomContentMargin: bottomContentMargin,
                    onCatalogRefreshEvent: { _, isFinished in
                        if isFinished {
                            catalogRefreshFinished = true
                        }
                    }
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

        let testWindow = makePhoneTestWindow(rootView: rootView)
        defer { testWindow.tearDown() }
        let window = testWindow.window

        // 等待 WorkspaceRootView 的 .task 目录刷新（期间候选页会短暂显示无 UIScrollView 的加载态）
        // 与首帧布局完成，再测量 Tab 栏与主垂直滚动容器，避免固定延时在高负载下竞态。
        let layoutReady = await waitUntil(timeout: .seconds(4)) {
            testWindow.enforcePhoneBoundsAndLayout()
            guard catalogRefreshFinished else { return false }
            let views = self.allDescendantViews(in: window)
            let hasTabBar = views.contains {
                guard let tabBar = $0 as? UITabBar else { return false }
                return !tabBar.isHidden && tabBar.alpha > 0.01 && tabBar.bounds.height > 0
            }
            let hasVerticalScrollView = views.contains {
                guard let scrollView = $0 as? UIScrollView else { return false }
                return !scrollView.isHidden
                    && scrollView.alpha > 0.01
                    && scrollView.bounds.height > 200
                    && scrollView.contentSize.height > scrollView.bounds.height
            }
            return hasTabBar && hasVerticalScrollView
        }
        XCTAssertTrue(layoutReady, "工作区页应当完成目录刷新并渲染底部 Tab 栏与主垂直滚动容器")
        try? await Task.sleep(for: .milliseconds(50))
        testWindow.enforcePhoneBoundsAndLayout()

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
        directoryListResults: [String: Result<DirectoryListResponse, Error>] = [:],
        resolveResults: [String: Result<AgentWorkspace, Error>] = [:]
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
        let sessions = (0..<sessionCount).map { (index: Int) -> AgentSession in
            let project = projects[0]
            let sessionID = "sess-\(index)"
            let createdAt = now.addingTimeInterval(-TimeInterval(index) * 120)
            let updatedAt = now.addingTimeInterval(-TimeInterval(index) * 60)
            return AgentSession(
                id: sessionID,
                projectID: project.id,
                project: project.name,
                dir: project.path,
                title: "Session Row \(index)",
                status: SessionStatus.completed.rawValue,
                source: "codex",
                runtimeProvider: "codex",
                resumeID: sessionID,
                createdAt: createdAt,
                updatedAt: updatedAt
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
            resolveResults: resolveResults,
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

    private struct PhoneTestWindow {
        static let phoneBounds = CGRect(x: 0, y: 0, width: 390, height: 844)

        let window: UIWindow
        let host: UIViewController
        weak var previousKeyWindow: UIWindow?

        @MainActor
        func enforcePhoneBoundsAndLayout() {
            if window.frame != Self.phoneBounds {
                window.frame = Self.phoneBounds
            }
            if host.view.frame != Self.phoneBounds {
                host.view.frame = Self.phoneBounds
            }
            window.setNeedsLayout()
            window.layoutIfNeeded()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }

        @MainActor
        func tearDown() {
            window.endEditing(true)
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
    }

    @MainActor
    private func makePhoneTestWindow<Content: View>(rootView: Content) -> PhoneTestWindow {
        let bounds = PhoneTestWindow.phoneBounds
        // 单测宿主没有外部辅助技术客户端，显式开启 accessibilityEnabled 让 SwiftUI 生成无障碍元素。
        let host = UIHostingController(
            rootView: rootView.environment(\.accessibilityEnabled, true)
        )
        host.traitOverrides.userInterfaceIdiom = UIUserInterfaceIdiom.phone
        host.traitOverrides.horizontalSizeClass = UIUserInterfaceSizeClass.compact
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = bounds
        } else {
            window = UIWindow(frame: bounds)
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        let handle = PhoneTestWindow(window: window, host: host, previousKeyWindow: previousKeyWindow)
        handle.enforcePhoneBoundsAndLayout()
        return handle
    }

    @MainActor
    private func allDescendantViews(in root: UIView) -> [UIView] {
        var result: [UIView] = [root]
        for subview in root.subviews {
            result.append(contentsOf: allDescendantViews(in: subview))
        }
        return result
    }

    @MainActor
    private func scrollPresentedSheetToBottom(in window: UIWindow) {
        guard let presentedRoot = window.rootViewController?.presentedViewController?.view else {
            return
        }
        presentedRoot.layoutIfNeeded()
        if let collectionView = allDescendantViews(in: presentedRoot)
            .compactMap({ $0 as? UIScrollView })
            .first(where: { $0.bounds.height > 200 }) {
            let maxY = max(
                0,
                collectionView.contentSize.height
                    - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom
            )
            collectionView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
            collectionView.layoutIfNeeded()
        }
    }

    @MainActor
    private func findLiveManualPathTextField(
        in window: UIWindow,
        searchRoot: UIView? = nil
    ) -> OpenWorkspaceManualPathTextField.ManualPathUITextField? {
        guard let root = searchRoot ?? window.rootViewController?.presentedViewController?.view else {
            return nil
        }
        root.layoutIfNeeded()
        return allDescendantViews(in: root)
            .compactMap { $0 as? OpenWorkspaceManualPathTextField.ManualPathUITextField }
            .first {
                $0.accessibilityIdentifier == "workspace.open.manualPath"
                    && $0.window === window
            }
    }

    @MainActor
    private func accessibilityIdentifier(of object: NSObject) -> String? {
        if let identifiable = object as? UIAccessibilityIdentification,
           let identifier = identifiable.accessibilityIdentifier {
            return identifier
        }
        let selector = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        guard object.responds(to: selector),
              let rawValue = object.perform(selector)?.takeUnretainedValue() as? String else {
            return nil
        }
        return rawValue
    }

    @MainActor
    private func activateAccessibilityElement(identifier: String, in root: UIView?) -> Bool {
        autoreleasepool {
            guard let element = findAccessibilityElement(identifier: identifier, in: root) else {
                return false
            }
            return element.accessibilityActivate()
        }
    }

    @MainActor
    private func pasteIntoLiveManualPathTextField(_ path: String, in window: UIWindow) async -> Bool {
        let focused: Bool = autoreleasepool {
            guard let textField = findLiveManualPathTextField(in: window) else {
                return false
            }
            textField.becomeFirstResponder()
            return true
        }
        guard focused else { return false }
        try? await Task.sleep(for: .milliseconds(100))
        return autoreleasepool {
            guard let textField = findLiveManualPathTextField(in: window) else {
                return false
            }
            UIPasteboard.general.string = path
            textField.paste(nil)
            return true
        }
    }

    @MainActor
    private func findAccessibilityElement(identifier: String, in root: UIView?) -> NSObject? {
        guard let root else { return nil }
        var visited = Set<ObjectIdentifier>()

        func search(_ object: NSObject) -> NSObject? {
            let objectID = ObjectIdentifier(object)
            guard visited.insert(objectID).inserted else { return nil }

            if accessibilityIdentifier(of: object) == identifier {
                return object
            }

            if let elements = object.accessibilityElements {
                for element in elements {
                    if let child = element as? NSObject, let match = search(child) {
                        return match
                    }
                }
            }

            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let match = search(child) {
                        return match
                    }
                }
            }

            if let view = object as? UIView {
                for subview in view.subviews {
                    if let match = search(subview) {
                        return match
                    }
                }
            }

            return nil
        }

        return search(root)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(25),
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return condition()
    }
}
