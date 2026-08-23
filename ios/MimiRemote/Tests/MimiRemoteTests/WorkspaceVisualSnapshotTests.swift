import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class WorkspaceVisualSnapshotTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try SnapshotTestEnvironment.requireFixedSimulator()
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "工作区视觉基线在固定 M5 iPad 上使用 iPad 画布录制。"
        )
    }

    func testNotionStyleWorkspaceOnIPadMiniPortrait() async throws {
        try await renderWorkspaceSnapshot(
            width: 744,
            height: 1_133,
            // iPadOS 26 的紧凑 TabView 把 Tab 栏渲染在顶部，右下角空着。
            hasBottomTabBar: false,
            testName: "testNotionStyleWorkspaceOnIPadMiniPortrait"
        )
    }

    /// 窄屏形态与宽屏是两套头部：Runtime 降级成菜单、分段标题让位、筛选器不并入胶囊行。
    /// 画布固定在 iPhone 宽度即可覆盖，宿主仍是同一台 M5 iPad，基线不随运行设备漂移。
    func testCompactWorkspaceRuntimeMenuOnPhoneWidth() async throws {
        try await renderWorkspaceSnapshot(
            width: 393,
            height: 852,
            // iPhone 的 Tab 栏浮在底部，新建按钮因此回到筛选行右端而不是浮起。
            // 这个值平时由 UnifiedWorkbenchShell 注入；快照直接渲染根视图，必须显式给，
            // 否则录出来的是浮起态，测试名和它实际覆盖的形态对不上。
            hasBottomTabBar: true,
            testName: "testCompactWorkspaceRuntimeMenuOnPhoneWidth"
        )
    }

    private func renderWorkspaceSnapshot(
        width: CGFloat,
        height: CGFloat,
        hasBottomTabBar: Bool,
        testName: String
    ) async throws {
        let previousLanguage = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.preferenceKey)
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
            }
        }

        let appDefaultsSuite = "WorkspaceVisualSnapshotTests.App.\(UUID().uuidString)"
        let appDefaults = UserDefaults(suiteName: appDefaultsSuite)!
        appDefaults.removePersistentDomain(forName: appDefaultsSuite)
        let appStore = AppStore(
            defaults: appDefaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        appStore.endpoint = "http://demo-mac.local:8787"

        let projects = [
            AgentProject(
                id: "codex-ipad-agent",
                name: "codex-ipad-agent",
                path: "/Users/gaixiaotongxue/code/codex-ipad-agent"
            ),
            AgentProject(
                id: "design-system",
                name: "design-system",
                path: "/Users/gaixiaotongxue/code/design-system"
            ),
            AgentProject(
                id: "app-server-lab",
                name: "app-server-lab",
                path: "/Users/gaixiaotongxue/code/app-server-lab"
            )
        ]
        let referenceDate = Date(timeIntervalSince1970: 1_785_105_600)
        let sessions = [
            AgentSession(
                id: "workspace-running",
                projectID: projects[0].id,
                project: projects[0].name,
                dir: projects[0].path,
                title: "优化 iPad mini 工作区布局",
                status: SessionStatus.running.rawValue,
                source: "codex",
                runtimeProvider: "codex",
                resumeID: "workspace-running",
                createdAt: referenceDate.addingTimeInterval(-3_600),
                updatedAt: referenceDate.addingTimeInterval(-90),
                preview: "调整项目卡片、Emoji 和 Git 摘要层级。",
                activeTurnID: "turn-workspace-running",
                context: SessionContextSnapshot(
                    git: SessionContextGitInfo(branch: "feature/workspace-recent-session-layout")
                )
            ),
            AgentSession(
                id: "workspace-history",
                projectID: projects[0].id,
                project: projects[0].name,
                dir: projects[0].path,
                title: "确认 Claude Code 运行时状态",
                status: SessionStatus.completed.rawValue,
                source: "codex",
                runtimeProvider: "codex",
                resumeID: "workspace-history",
                createdAt: referenceDate.addingTimeInterval(-7_200),
                updatedAt: referenceDate.addingTimeInterval(-3_000),
                preview: "运行时与会话列表继续保持独立。",
                context: SessionContextSnapshot(
                    git: SessionContextGitInfo(branch: "main")
                )
            ),
            AgentSession(
                id: "workspace-review",
                projectID: projects[0].id,
                project: projects[0].name,
                dir: projects[0].path,
                title: "检查轻量 Git 摘要协议",
                status: SessionStatus.completed.rawValue,
                source: "codex",
                runtimeProvider: "codex",
                resumeID: "workspace-review",
                createdAt: referenceDate.addingTimeInterval(-10_800),
                updatedAt: referenceDate.addingTimeInterval(-6_000),
                preview: "卡片请求不再下载完整 diff。",
                context: SessionContextSnapshot(
                    git: SessionContextGitInfo(branch: "codex/git-summary-protocol")
                )
            ),
            AgentSession(
                id: "workspace-stale-history",
                projectID: projects[0].id,
                project: projects[0].name,
                dir: projects[0].path,
                title: "整理工作区历史会话",
                status: SessionStatus.completed.rawValue,
                source: "codex",
                runtimeProvider: "codex",
                resumeID: "workspace-stale-history",
                createdAt: referenceDate.addingTimeInterval(-50_400),
                updatedAt: referenceDate.addingTimeInterval(-46_800),
                preview: "十二小时前的会话进入下一张整体卡片。",
                context: SessionContextSnapshot(
                    git: SessionContextGitInfo(branch: "codex/workspace-history-grouping")
                )
            )
        ]
        let workspaces = projects.enumerated().map { index, project in
            AgentWorkspace(
                project: project,
                lastOpenedAt: Date().addingTimeInterval(TimeInterval(-(index + 1) * 1_800))
            )
        }
        let recentStore = makeRecentWorkspaceStore(workspaces: workspaces, endpoint: appStore.endpoint)
        let client = MockSessionStoreClient(
            projects: projects,
            sessions: sessions,
            projectSessions: [projects[0].id: sessions],
            workspaceSessions: [projects[0].id: sessions],
            runtimeChannelAvailability: ["claude": true]
        )
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: recentStore,
            clientFactory: { client }
        )
        sessionStore.reloadRecentWorkspaces()
        sessionStore.sessions = sessions
        sessionStore.workspaceGitSummaryByPath = [
            projects[0].path: gitSummary(
                project: projects[0],
                branch: "main",
                upstream: "origin/main",
                changedFiles: 3
            ),
            projects[1].path: gitSummary(
                project: projects[1],
                branch: "release/1.0",
                upstream: "origin/release/1.0"
            ),
            projects[2].path: gitSummary(
                project: projects[2],
                branch: "feature/gateway",
                upstream: "origin/feature/gateway",
                behind: 2
            )
        ]

        // 视觉基线必须从完整的确定性状态同步渲染，不能靠固定延时等待 View.task；
        // 否则可能把项目切换条和会话列表处于不同刷新阶段的中间态录进基线。
        try await sessionStore.refreshWorkspaceCatalog()
        await sessionStore.refreshAppServerModelOptions()
        XCTAssertEqual(sessionStore.sidebarProjects.map(\.id), projects.map(\.id))
        XCTAssertEqual(sessionStore.sessions(forProjectID: projects[0].id).count, sessions.count)

        let appearanceDefaultsSuite = "WorkspaceVisualSnapshotTests.Appearance.\(UUID().uuidString)"
        let appearanceDefaults = UserDefaults(suiteName: appearanceDefaultsSuite)!
        appearanceDefaults.removePersistentDomain(forName: appearanceDefaultsSuite)
        let appearanceStore = WorkspaceAppearanceStore(defaults: appearanceDefaults)
        // 默认角色会混入安装身份；快照显式固定，避免隔离 AppStore 后生成的新身份让视觉基线抖动。
        let appearanceProfileID = appStore.activeHostScope.profileID
        appearanceStore.setCustomCharacterID("sun-wukong", profileID: appearanceProfileID, projectID: projects[0].id)
        appearanceStore.setCustomCharacterID("zhu-bajie", profileID: appearanceProfileID, projectID: projects[1].id)
        appearanceStore.setCustomCharacterID("white-bone-demon", profileID: appearanceProfileID, projectID: projects[2].id)

        let themeDefaultsSuite = "WorkspaceVisualSnapshotTests.Theme.\(UUID().uuidString)"
        let themeDefaults = UserDefaults(suiteName: themeDefaultsSuite)!
        themeDefaults.removePersistentDomain(forName: themeDefaultsSuite)
        let themeStore = ThemeStore(defaults: themeDefaults)
        themeStore.applyDeviceDefaultFontScale(
            isPad: width >= 700,
            screenSize: CGSize(width: width, height: height)
        )

        let view = WorkspaceRootView(
            onStartSession: { _, _ in },
            onOpenSession: { _ in },
            appearanceStore: appearanceStore,
            initialWorkspaceID: projects[0].id,
            // 固定“当前时间”后，相对分组和右侧时刻不会随测试运行日期漂移。
            currentDate: { referenceDate }
        )
        .environmentObject(appStore)
        .environmentObject(sessionStore)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .environment(\.workbenchHasCompactTabBar, true)
        .environment(\.workbenchHasBottomTabBar, hasBottomTabBar)
        .frame(width: width, height: height)

        if let failure = verifySnapshot(
            of: view,
            as: .image(
                drawHierarchyInKeyWindow: true,
                precision: 0.98,
                layout: .fixed(width: width, height: height)
            ),
            snapshotDirectory: referenceSnapshotDirectory,
            testName: testName
        ) {
            XCTFail(failure)
        }
    }

    private var referenceSnapshotDirectory: String? {
        #if targetEnvironment(simulator)
        // 模拟器保留源码目录路径，方便本地重新录制基线。
        nil
        #else
        // 真机不能访问 Mac 源码目录；Xcode 会把基线平铺复制进测试 Bundle。
        Bundle(for: Self.self).bundlePath
        #endif
    }

    private func gitSummary(
        project: AgentProject,
        branch: String,
        upstream: String,
        changedFiles: Int = 0,
        behind: Int = 0
    ) -> GitStatusResponse {
        GitStatusResponse(
            path: project.path,
            isRepository: true,
            branch: branch,
            head: "abc123",
            ahead: 0,
            behind: behind,
            upstream: upstream,
            statusText: nil,
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: nil,
            files: (0..<changedFiles).map { index in
                GitFileStatus(
                    path: "Sources/File\(index + 1).swift",
                    code: " M",
                    staged: false,
                    unstaged: true,
                    untracked: false
                )
            },
            truncated: false,
            truncatedNote: nil
        )
    }
}
