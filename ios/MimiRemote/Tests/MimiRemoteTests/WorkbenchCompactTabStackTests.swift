import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// 紧凑布局下每个 Tab 只保留路由当前指向的详情栈。程序化跳转把用户带离某个 Tab 后，
/// 再点回来必须是列表，不能恢复一个早已离开的旧会话（#787）。
final class WorkbenchCompactTabStackTests: XCTestCase {
    func testNotificationFromWorkspaceDetailLeavesWorkspaceTabOnList() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )

        state.reduce(
            .selectionCommitted(SessionSelectionCommit(
                sequence: 1,
                projectID: "project",
                sessionID: "notification-session",
                reason: .notification
            )),
            usesCompactNavigation: true,
            selectedSessionID: "notification-session"
        )

        XCTAssertEqual(state.compactSelectedTab, .sessions)
        XCTAssertEqual(state.compactSessionPath, [.session("notification-session")])
        XCTAssertTrue(state.compactWorkspacePath.isEmpty, "通知把用户带到会话 Tab 后，工作区 Tab 不能留着旧详情")

        state.reduce(
            .compactPathChanged(tab: .sessions, path: []),
            usesCompactNavigation: true,
            selectedSessionID: "notification-session"
        )
        assertTappingWorkspacesShowsList(&state, selectedSessionID: nil)
    }

    func testRotationThroughSidebarSessionLeavesWorkspaceTabOnList() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )

        // 横屏后从侧栏打开另一个会话。
        state.reduce(
            .open(.session("sidebar-session"), source: .sessions),
            usesCompactNavigation: false,
            selectedSessionID: "workspace-session"
        )
        XCTAssertTrue(state.compactWorkspacePath.isEmpty)

        // 转回竖屏时由 Shell 重放路由。
        state.reduce(
            .synchronize(.session(id: "sidebar-session", source: .sessions)),
            usesCompactNavigation: true,
            selectedSessionID: "sidebar-session"
        )
        XCTAssertEqual(state.compactSelectedTab, .sessions)
        XCTAssertEqual(state.compactSessionPath, [.session("sidebar-session")])
        XCTAssertTrue(state.compactWorkspacePath.isEmpty)

        state.reduce(
            .compactPathChanged(tab: .sessions, path: []),
            usesCompactNavigation: true,
            selectedSessionID: "sidebar-session"
        )
        assertTappingWorkspacesShowsList(&state, selectedSessionID: nil)
    }

    func testWideSessionsRootClearsHiddenWorkspaceStack() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )

        state.reduce(
            .open(.sessions, source: nil),
            usesCompactNavigation: false,
            selectedSessionID: "workspace-session"
        )
        XCTAssertTrue(state.compactWorkspacePath.isEmpty)

        state.reduce(
            .synchronize(.sessions),
            usesCompactNavigation: true,
            selectedSessionID: nil
        )
        assertTappingWorkspacesShowsList(&state, selectedSessionID: nil)
    }

    func testRotationWhileOnMeDoesNotRestoreOldWorkspaceDetail() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )
        state.reduce(
            .open(.session("sidebar-session"), source: .sessions),
            usesCompactNavigation: false,
            selectedSessionID: "workspace-session"
        )
        state.reduce(.open(.me, source: nil), usesCompactNavigation: false, selectedSessionID: "sidebar-session")

        // 停在“我的”时转回竖屏，Shell 只切 Tab，不重放会话路由。
        state.reduce(.compactTabChanged(.me), usesCompactNavigation: true, selectedSessionID: "sidebar-session")

        assertTappingWorkspacesShowsList(&state, selectedSessionID: "sidebar-session")
    }

    func testRotationWhileOnMeReturnsToWideDetailOnItsTab() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )
        state.reduce(
            .open(.session("sidebar-session"), source: .sessions),
            usesCompactNavigation: false,
            selectedSessionID: "workspace-session"
        )
        state.reduce(.open(.me, source: nil), usesCompactNavigation: false, selectedSessionID: "sidebar-session")
        state.reduce(.compactTabChanged(.me), usesCompactNavigation: true, selectedSessionID: "sidebar-session")

        let effect = state.reduce(
            .compactTabChanged(.sessions),
            usesCompactNavigation: true,
            selectedSessionID: "sidebar-session"
        )

        XCTAssertNil(effect)
        XCTAssertEqual(state.selection, .session("sidebar-session"))
        XCTAssertEqual(state.compactSessionPath, [.session("sidebar-session")])
        XCTAssertTrue(state.compactWorkspacePath.isEmpty)
    }

    func testIdentityReplacementInWideMeKeepsReplacementForCompactTab() {
        var state = WorkbenchNavigationState(
            route: .session(id: "local:new-session", source: .workspaces)
        )
        state.reduce(.open(.me, source: nil), usesCompactNavigation: false, selectedSessionID: "local:new-session")
        state.reduce(
            .selectionCommitted(SessionSelectionCommit(
                sequence: 1,
                projectID: "project",
                sessionID: "real-session",
                reason: .identityReplacement(previousID: "local:new-session")
            )),
            usesCompactNavigation: false,
            selectedSessionID: "real-session"
        )
        XCTAssertEqual(state.selection, .me)
        XCTAssertEqual(state.compactWorkspacePath, [.session("real-session")])

        state.reduce(.compactTabChanged(.me), usesCompactNavigation: true, selectedSessionID: "real-session")
        let effect = state.reduce(
            .compactTabChanged(.workspaces),
            usesCompactNavigation: true,
            selectedSessionID: "real-session"
        )

        XCTAssertNil(effect)
        XCTAssertEqual(state.selection, .session("real-session"))
        XCTAssertEqual(state.route, .session(id: "real-session", source: .workspaces))
        XCTAssertEqual(state.compactWorkspacePath, [.session("real-session")])
    }

    func testLeavingDetailThroughMeThenOtherTabDropsDetail() {
        let cases: [(WorkbenchRootPage, CompactWorkbenchTab, CompactWorkbenchTab)] = [
            (.workspaces, .sessions, .workspaces),
            (.sessions, .workspaces, .sessions),
        ]
        for (source, otherTab, detailTab) in cases {
            var state = WorkbenchNavigationState(route: .session(id: "detail-session", source: source))
            state.reduce(.compactTabChanged(.me), usesCompactNavigation: true, selectedSessionID: "detail-session")
            state.reduce(.compactTabChanged(otherTab), usesCompactNavigation: true, selectedSessionID: "detail-session")

            let effect = state.reduce(
                .compactTabChanged(detailTab),
                usesCompactNavigation: true,
                selectedSessionID: nil
            )

            XCTAssertEqual(effect, .returnToSessionList, "source=\(source)")
            XCTAssertEqual(state.selection, detailTab.destination, "source=\(source)")
            XCTAssertTrue(state.compactSessionPath.isEmpty, "source=\(source)")
            XCTAssertTrue(state.compactWorkspacePath.isEmpty, "source=\(source)")
        }
    }

    func testReturningFromMeRestoresTheDetailItWasOpenedFrom() {
        var state = WorkbenchNavigationState(
            route: .session(id: "workspace-session", source: .workspaces)
        )
        state.reduce(
            .open(.subagent(parentID: "workspace-session", childID: "child"), source: .workspaces),
            usesCompactNavigation: true,
            selectedSessionID: "workspace-session"
        )
        let path = state.compactWorkspacePath

        state.reduce(.compactTabChanged(.me), usesCompactNavigation: true, selectedSessionID: "workspace-session")
        let effect = state.reduce(
            .compactTabChanged(.workspaces),
            usesCompactNavigation: true,
            selectedSessionID: "workspace-session"
        )

        XCTAssertNil(effect)
        XCTAssertEqual(state.compactWorkspacePath, path)
        XCTAssertEqual(path.count, 2, "子 Agent 页属于父会话，不能被当作残留栈清掉")
    }

    func testPhoneTabKeepsOneDetailWithoutTreatingItAsVisible() {
        var state = WorkbenchNavigationState(route: .session(id: "first", source: .sessions))

        XCTAssertNil(state.reduce(.compactTabChanged(.workspaces), usesCompactNavigation: true,
                                  selectedSessionID: "first", usesPhoneIntegratedBottomChrome: true))
        XCTAssertEqual(state.selection, .workspaces)
        XCTAssertEqual(state.compactSessionPath, [.session("first")])
        XCTAssertNil(state.visibleSessionID(usesCompactNavigation: true))

        XCTAssertNil(state.reduce(.compactTabChanged(.sessions), usesCompactNavigation: true,
                                  selectedSessionID: "first", usesPhoneIntegratedBottomChrome: true))
        XCTAssertEqual(state.visibleSessionID(usesCompactNavigation: true), "first")

        XCTAssertEqual(state.reduce(.open(.session("second"), source: .workspaces), usesCompactNavigation: true,
                                    selectedSessionID: "first", usesPhoneIntegratedBottomChrome: true),
                       .selectSession("second"))
        XCTAssertTrue(state.compactSessionPath.isEmpty)
        XCTAssertEqual(state.compactWorkspacePath, [.session("second")])
    }

    func testPhoneBackgroundSelectionAndInvalidationDoNotTakeOverTheTab() {
        var state = WorkbenchNavigationState(route: .session(id: "first", source: .sessions))
        state.reduce(.compactTabChanged(.workspaces), usesCompactNavigation: true,
                     selectedSessionID: nil, usesPhoneIntegratedBottomChrome: true)

        state.reduce(.selectionCommitted(SessionSelectionCommit(
            sequence: 1, projectID: "project", sessionID: "first", reason: .userOpen
        )), usesCompactNavigation: true, selectedSessionID: "first", usesPhoneIntegratedBottomChrome: true)
        XCTAssertEqual(state.compactSelectedTab, .workspaces)
        XCTAssertEqual(state.compactSessionPath, [.session("first")])
        XCTAssertNil(state.visibleSessionID(usesCompactNavigation: true))

        state.reduce(.selectionCommitted(SessionSelectionCommit(
            sequence: 2, projectID: "project", sessionID: nil, reason: .invalidation
        )), usesCompactNavigation: true, selectedSessionID: nil, usesPhoneIntegratedBottomChrome: true)
        XCTAssertEqual(state.compactSelectedTab, .workspaces)
        XCTAssertEqual(state.route, .workspaces)
        XCTAssertTrue(state.compactSessionPath.isEmpty)
    }

    func testPhoneNavigationInvariantsPreventConcurrentDetailsAcrossTabs() {
        var state = WorkbenchNavigationState(route: .session(id: "first", source: .sessions))
        assertSingleActiveDetailInvariant(state)
        XCTAssertTrue(state.isSessionDetailActiveOnScreen(sessionID: "first", usesCompactNavigation: true))

        // 依次切去工作区、设备、我的，后台保留单一会话栈，但对外可见会话始终为空。
        for tab: CompactWorkbenchTab in [.workspaces, .devices, .me] {
            let effect = state.reduce(
                .compactTabChanged(tab),
                usesCompactNavigation: true,
                selectedSessionID: "first",
                usesPhoneIntegratedBottomChrome: true
            )
            XCTAssertNil(effect)
            XCTAssertEqual(state.compactSelectedTab, tab)
            XCTAssertEqual(state.compactSessionPath, [.session("first")])
            XCTAssertTrue(state.compactWorkspacePath.isEmpty)
            XCTAssertNil(state.visibleSessionID(usesCompactNavigation: true))
            XCTAssertFalse(state.isSessionDetailActiveOnScreen(sessionID: "first", usesCompactNavigation: true))
            assertSingleActiveDetailInvariant(state)
        }

        // 切回会话 Tab 恢复原详情。
        XCTAssertNil(state.reduce(
            .compactTabChanged(.sessions),
            usesCompactNavigation: true,
            selectedSessionID: "first",
            usesPhoneIntegratedBottomChrome: true
        ))
        XCTAssertEqual(state.visibleSessionID(usesCompactNavigation: true), "first")
        XCTAssertTrue(state.isSessionDetailActiveOnScreen(sessionID: "first", usesCompactNavigation: true))

        // 切去工作区并打开第二个会话：留在工作区栈，同时原子清空会话栈。
        state.reduce(.compactTabChanged(.workspaces), usesCompactNavigation: true,
                     selectedSessionID: "first", usesPhoneIntegratedBottomChrome: true)
        let openEffect = state.reduce(
            .open(.session("second"), source: .workspaces),
            usesCompactNavigation: true,
            selectedSessionID: "first",
            usesPhoneIntegratedBottomChrome: true
        )
        XCTAssertEqual(openEffect, .selectSession("second"))
        XCTAssertEqual(state.compactSelectedTab, .workspaces)
        XCTAssertTrue(state.compactSessionPath.isEmpty)
        XCTAssertEqual(state.compactWorkspacePath, [.session("second")])
        XCTAssertEqual(state.visibleSessionID(usesCompactNavigation: true), "second")
        XCTAssertFalse(state.isSessionDetailActiveOnScreen(sessionID: "first", usesCompactNavigation: true))
        XCTAssertTrue(state.isSessionDetailActiveOnScreen(sessionID: "second", usesCompactNavigation: true))
        assertSingleActiveDetailInvariant(state)

        // 再切回会话 Tab 必须是列表，不能短暂显示旧详情或工作区的会话。
        XCTAssertNil(state.reduce(
            .compactTabChanged(.sessions),
            usesCompactNavigation: true,
            selectedSessionID: "second",
            usesPhoneIntegratedBottomChrome: true
        ))
        XCTAssertEqual(state.compactSelectedTab, .sessions)
        XCTAssertEqual(state.selection, .sessions)
        XCTAssertTrue(state.compactSessionPath.isEmpty)
        XCTAssertEqual(state.compactWorkspacePath, [.session("second")])
        XCTAssertNil(state.visibleSessionID(usesCompactNavigation: true))
        XCTAssertFalse(state.isSessionDetailActiveOnScreen(sessionID: "second", usesCompactNavigation: true))
        assertSingleActiveDetailInvariant(state)
    }

    func testPhoneNotificationAndDeepLinkAlwaysOpenInSessionsTabAndReplaceStack() {
        // 1. 从工作区详情收到通知/深链：统一切到会话 Tab 并清空工作区栈。
        var fromWorkspace = WorkbenchNavigationState(route: .session(id: "workspace-session", source: .workspaces))
        fromWorkspace.reduce(
            .selectionCommitted(SessionSelectionCommit(
                sequence: 1, projectID: "project", sessionID: "notif-session", reason: .notification
            )),
            usesCompactNavigation: true,
            selectedSessionID: "notif-session",
            usesPhoneIntegratedBottomChrome: true
        )
        XCTAssertEqual(fromWorkspace.compactSelectedTab, .sessions)
        XCTAssertEqual(fromWorkspace.compactSessionPath, [.session("notif-session")])
        XCTAssertTrue(fromWorkspace.compactWorkspacePath.isEmpty)
        XCTAssertEqual(fromWorkspace.visibleSessionID(usesCompactNavigation: true), "notif-session")
        assertSingleActiveDetailInvariant(fromWorkspace)

        // 2. 从子 Agent 只读页收到通知/深链：替换整个会话栈，不能留下父会话与新会话叠栈。
        var fromSubagent = WorkbenchNavigationState(route: .session(id: "parent-session", source: .sessions))
        fromSubagent.reduce(
            .open(.subagent(parentID: "parent-session", childID: "child-session"), source: .sessions),
            usesCompactNavigation: true,
            selectedSessionID: "parent-session",
            usesPhoneIntegratedBottomChrome: true
        )
        fromSubagent.reduce(
            .selectionCommitted(SessionSelectionCommit(
                sequence: 2, projectID: "project", sessionID: "deep-link-session", reason: .notification
            )),
            usesCompactNavigation: true,
            selectedSessionID: "deep-link-session",
            usesPhoneIntegratedBottomChrome: true
        )
        XCTAssertEqual(fromSubagent.compactSelectedTab, .sessions)
        XCTAssertEqual(fromSubagent.compactSessionPath, [.session("deep-link-session")])
        XCTAssertTrue(fromSubagent.compactWorkspacePath.isEmpty)
        assertSingleActiveDetailInvariant(fromSubagent)

        // 3. 从设备/我的 Tab 收到通知/深链：切到会话 Tab。
        var fromDevices = WorkbenchNavigationState(route: .session(id: "old-session", source: .sessions))
        fromDevices.reduce(
            .compactTabChanged(.devices),
            usesCompactNavigation: true,
            selectedSessionID: "old-session",
            usesPhoneIntegratedBottomChrome: true
        )
        fromDevices.reduce(
            .selectionCommitted(SessionSelectionCommit(
                sequence: 3, projectID: "project", sessionID: "notif-session-2", reason: .notification
            )),
            usesCompactNavigation: true,
            selectedSessionID: "notif-session-2",
            usesPhoneIntegratedBottomChrome: true
        )
        XCTAssertEqual(fromDevices.compactSelectedTab, .sessions)
        XCTAssertEqual(fromDevices.compactSessionPath, [.session("notif-session-2")])
        XCTAssertEqual(fromDevices.visibleSessionID(usesCompactNavigation: true), "notif-session-2")
        assertSingleActiveDetailInvariant(fromDevices)
    }

    func testPhoneRelaunchRestoresLastSelectedTabWhilePreservingSessionStack() {
        for savedTab: CompactWorkbenchTab in [.workspaces, .devices, .me] {
            var state = WorkbenchNavigationState()
            state.reduce(
                .synchronize(.session(id: "first", source: .sessions), preferredCompactTab: savedTab),
                usesCompactNavigation: true,
                selectedSessionID: "first",
                usesPhoneIntegratedBottomChrome: true
            )
            XCTAssertEqual(state.compactSelectedTab, savedTab)
            XCTAssertEqual(state.selection, savedTab.destination)
            XCTAssertEqual(state.compactSessionPath, [.session("first")])
            XCTAssertTrue(state.compactWorkspacePath.isEmpty)
            XCTAssertNil(state.visibleSessionID(usesCompactNavigation: true))
            assertSingleActiveDetailInvariant(state)

            // 切回会话 Tab 仍能恢复原来的会话详情。
            XCTAssertNil(state.reduce(
                .compactTabChanged(.sessions),
                usesCompactNavigation: true,
                selectedSessionID: "first",
                usesPhoneIntegratedBottomChrome: true
            ))
            XCTAssertEqual(state.visibleSessionID(usesCompactNavigation: true), "first")
        }

        // 根页重启到上次停留的 Tab。
        var rootState = WorkbenchNavigationState()
        rootState.reduce(
            .synchronize(.sessions, preferredCompactTab: .workspaces),
            usesCompactNavigation: true,
            selectedSessionID: nil,
            usesPhoneIntegratedBottomChrome: true
        )
        XCTAssertEqual(rootState.compactSelectedTab, .workspaces)
        XCTAssertEqual(rootState.route, .workspaces)
        XCTAssertTrue(rootState.compactSessionPath.isEmpty)
        XCTAssertTrue(rootState.compactWorkspacePath.isEmpty)
    }

    func testPhoneRetappingActiveTabReturnsToList() {
        var sessionState = WorkbenchNavigationState(route: .session(id: "first", source: .sessions))
        let sessionEffect = sessionState.reduce(
            .compactTabChanged(.sessions),
            usesCompactNavigation: true,
            selectedSessionID: "first",
            usesPhoneIntegratedBottomChrome: true
        )
        XCTAssertEqual(sessionEffect, .returnToSessionList)
        XCTAssertEqual(sessionState.route, .sessions)
        XCTAssertEqual(sessionState.selection, .sessions)
        XCTAssertTrue(sessionState.compactSessionPath.isEmpty)

        var workspaceState = WorkbenchNavigationState(route: .session(id: "second", source: .workspaces))
        let workspaceEffect = workspaceState.reduce(
            .compactTabChanged(.workspaces),
            usesCompactNavigation: true,
            selectedSessionID: "second",
            usesPhoneIntegratedBottomChrome: true
        )
        XCTAssertEqual(workspaceEffect, .returnToSessionList)
        XCTAssertEqual(workspaceState.route, .workspaces)
        XCTAssertEqual(workspaceState.selection, .workspaces)
        XCTAssertTrue(workspaceState.compactWorkspacePath.isEmpty)
    }

    func testNarrowIPadNeverEnablesPhoneIntegratedBottomChrome() {
        let phone = WorkbenchLayout(
            containerWidth: 393,
            horizontalSizeClass: .compact,
            isPad: false,
            isPhone: true
        )
        XCTAssertTrue(phone.usesCompactNavigation)
        XCTAssertTrue(phone.usesPhoneIntegratedBottomChrome)

        let narrowCompactIPad = WorkbenchLayout(
            containerWidth: 375,
            horizontalSizeClass: .compact,
            isPad: true,
            isPhone: false
        )
        XCTAssertTrue(narrowCompactIPad.usesCompactNavigation)
        XCTAssertFalse(narrowCompactIPad.usesPhoneIntegratedBottomChrome)

        let miniPortraitRegularIPad = WorkbenchLayout(
            containerWidth: 744,
            horizontalSizeClass: .regular,
            isPad: true,
            isPhone: false
        )
        XCTAssertTrue(miniPortraitRegularIPad.usesCompactNavigation)
        XCTAssertFalse(miniPortraitRegularIPad.usesPhoneIntegratedBottomChrome)

        let wideIPad = WorkbenchLayout(
            containerWidth: 1032,
            horizontalSizeClass: .regular,
            isPad: true,
            isPhone: false
        )
        XCTAssertFalse(wideIPad.usesCompactNavigation)
        XCTAssertFalse(wideIPad.usesPhoneIntegratedBottomChrome)
    }

    @MainActor
    func testReadOnlySubagentDestinationHidesBottomTabBarOnPhone() throws {
        let defaultsSuite = "ReadOnlySubagentTabBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        let conversationStore = ConversationStore()
        let sessionStore = SessionStore(
            appStore: AppStore(
                defaults: defaults,
                tokenStore: TokenStore(keychain: TestKeychainOperations())
            ),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        let now = Date(timeIntervalSince1970: 1_782_879_660)
        let childID = "test-subagent-review"
        let parentID = "test-parent-session"
        let childSession = AgentSession(
            id: childID,
            projectID: "test-project",
            project: "mimi-remote",
            dir: "/Users/demo/code/mimi-remote",
            title: "审查目标",
            status: SessionStatus.completed.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: childID,
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now,
            parentThreadID: parentID,
            isSubagent: true,
            canAcceptDirectInput: false
        )
        sessionStore.sessionsByID[childID] = childSession
        conversationStore.replaceHistorySnapshot([
            CodexHistoryMessage(
                id: "\(childID)-msg-1",
                role: "assistant",
                content: "已完成文档核对：安装命令可执行，架构与当前 runtime 选择逻辑一致。",
                createdAt: now,
                turnID: "\(childID)-turn",
                itemID: "\(childID)-item",
                timelineOrdinal: 1
            )
        ], sessionID: childID)
        let relation = SessionContextSubagent(
            id: childID,
            parentThreadID: parentID,
            nickname: "审查目标",
            status: SessionStatus.completed.rawValue,
            canAcceptDirectInput: false
        )
        let themeStore = ThemeStore(defaults: defaults)
        let rootView = ReadOnlySubagentTabBarHost(
            relation: relation,
            parentID: parentID,
            childID: childID
        )
        .environmentObject(sessionStore)
        .environmentObject(conversationStore)
        .environmentObject(themeStore)
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.colorScheme, .light)
        .defaultAppStorage(defaults)

        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: rootView)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = bounds
        } else {
            window = UIWindow(frame: bounds)
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        host.view.frame = bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.view.layoutIfNeeded()

        XCTAssertGreaterThan(host.sizeThatFits(in: bounds.size).height, 0)
        func findTabBars(in view: UIView) -> [UITabBar] {
            var bars: [UITabBar] = []
            if let tabBar = view as? UITabBar {
                bars.append(tabBar)
            }
            for subview in view.subviews {
                bars.append(contentsOf: findTabBars(in: subview))
            }
            return bars
        }
        let visibleTabBars = findTabBars(in: host.view).filter { !$0.isHidden && $0.alpha > 0.01 }
        XCTAssertTrue(visibleTabBars.isEmpty, "只读子 Agent 页必须隐藏底部 Tab 栏")

        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { context in
            if !window.drawHierarchy(in: bounds, afterScreenUpdates: true) {
                host.view.layer.render(in: context.cgContext)
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "iphone-subagent-readonly"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPhoneSessionNavigationTitleShowsWorkspaceIconOnlyOnPhoneWithProject() {
        let phoneLayout = WorkbenchLayout(
            containerWidth: 402,
            horizontalSizeClass: .compact,
            isPad: false,
            isPhone: true
        )
        let compactPadLayout = WorkbenchLayout(
            containerWidth: 402,
            horizontalSizeClass: .compact,
            isPad: true,
            isPhone: false
        )
        let widePadLayout = WorkbenchLayout(
            containerWidth: 1032,
            horizontalSizeClass: .regular,
            isPad: true,
            isPhone: false
        )

        XCTAssertTrue(
            SessionNavigationTitlePresentation.showsWorkspaceIcon(
                layout: phoneLayout,
                projectID: "proj_mimi"
            )
        )
        XCTAssertFalse(
            SessionNavigationTitlePresentation.showsWorkspaceIcon(
                layout: phoneLayout,
                projectID: "   "
            )
        )
        XCTAssertFalse(
            SessionNavigationTitlePresentation.showsWorkspaceIcon(
                layout: phoneLayout,
                projectID: nil
            )
        )
        XCTAssertFalse(
            SessionNavigationTitlePresentation.showsWorkspaceIcon(
                layout: compactPadLayout,
                projectID: "proj_mimi"
            ),
            "窄窗 iPad 顶栏保持原有纯文字排版"
        )
        XCTAssertFalse(
            SessionNavigationTitlePresentation.showsWorkspaceIcon(
                layout: widePadLayout,
                projectID: "proj_mimi"
            ),
            "宽屏 iPad 顶栏保持原有纯文字排版"
        )
    }

    func testPhoneFloatingCapsuleMetricsEnablementAndBounds() {
        let phoneLayout = WorkbenchLayout(
            containerWidth: 402,
            horizontalSizeClass: .compact,
            isPad: false,
            isPhone: true
        )
        let compactPadLayout = WorkbenchLayout(
            containerWidth: 375,
            horizontalSizeClass: .compact,
            isPad: true,
            isPhone: false
        )
        let miniPortraitPadLayout = WorkbenchLayout(
            containerWidth: 744,
            horizontalSizeClass: .regular,
            isPad: true,
            isPhone: false
        )
        let widePadLayout = WorkbenchLayout(
            containerWidth: 1032,
            horizontalSizeClass: .regular,
            isPad: true,
            isPhone: false
        )

        XCTAssertTrue(PhoneSessionFloatingCapsuleMetrics.isEnabled(layout: phoneLayout))
        XCTAssertFalse(PhoneSessionFloatingCapsuleMetrics.isEnabled(layout: compactPadLayout), "窄窗 iPad 不启用悬浮玻璃顶栏")
        XCTAssertFalse(PhoneSessionFloatingCapsuleMetrics.isEnabled(layout: miniPortraitPadLayout), "竖屏 iPad mini 不启用悬浮玻璃顶栏")
        XCTAssertFalse(PhoneSessionFloatingCapsuleMetrics.isEnabled(layout: widePadLayout), "宽屏 iPad 不启用悬浮玻璃顶栏")

        // 三件等高（44pt），中间胶囊与左右按钮最小间距 8pt，最大宽度按 min(304, 可用宽度) 兜底。
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.itemHeight, 44)
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.buttonSize, 44)
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.horizontalScreenMargin, 16)
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.interItemSpacing, 8)
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.maximumWidth, 304)

        // 可用宽度 = containerWidth - 2 * (16 + 44 + 8) = containerWidth - 136
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.availableCenterWidth(containerWidth: 402), 266)
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.resolvedMaxWidth(containerWidth: 402), 266)
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.resolvedMaxWidth(containerWidth: 375), 239)
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.resolvedMaxWidth(containerWidth: 440), 304)
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.resolvedMaxWidth(containerWidth: 520), 304)
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.resolvedMaxWidth(containerWidth: 320), 184)
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.cornerRadius(forHeight: 44), 22)
        XCTAssertEqual(PhoneSessionFloatingCapsuleMetrics.cornerRadius(forHeight: 56), 28)
    }

    @MainActor
    func testPhoneFloatingCapsuleHeaderThreePieceLayoutAlignmentAndTruncation() throws {
        let defaultsSuite = "PhoneFloatingCapsuleHeaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
        let themeStore = ThemeStore(defaults: defaults)
        let tokens = themeStore.tokens(for: .light)

        func measureHeader(
            title: String,
            subtitle: String,
            containerWidth: CGFloat
        ) -> PhoneSessionFloatingHeaderLayoutSnapshot {
            var measured = PhoneSessionFloatingHeaderLayoutSnapshot()
            let data = SessionNavigationTitleDisplayData(
                title: title,
                subtitle: subtitle,
                showsStatus: false,
                subtitleColor: tokens.tertiaryText,
                subtitleFont: themeStore.uiFont(.caption2, weight: .medium),
                accessibilityValue: subtitle,
                workspaceIcon: .emoji("🐱")
            )
            let header = PhoneSessionFloatingCapsuleHeader(
                data: data,
                tokens: tokens,
                availableWidth: containerWidth,
                isMenuDisabled: false,
                onBack: {},
                onMeasuredLayout: { snapshot in
                    measured = snapshot
                },
                moreMenuContent: {
                    Button("Refresh") {}
                }
            )
            .environment(\.colorScheme, .light)

            let bounds = CGRect(x: 0, y: 0, width: containerWidth, height: 120)
            let host = UIHostingController(rootView: header)
            let window: UIWindow
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window = UIWindow(windowScene: scene)
                window.frame = bounds
            } else {
                window = UIWindow(frame: bounds)
            }
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.rootViewController = nil
                window.isHidden = true
            }
            host.view.frame = bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.view.layoutIfNeeded()
            return measured
        }

        func assertThreePieceInvariants(
            _ snapshot: PhoneSessionFloatingHeaderLayoutSnapshot,
            expectedContainerWidth: CGFloat,
            context: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertTrue(snapshot.isComplete, "\(context)：应测量到三件完整布局几何", file: file, line: line)
            XCTAssertEqual(snapshot.containerWidth, expectedContainerWidth, accuracy: 1.0, context, file: file, line: line)

            // 1. 左返回按钮：44×44 圆形，紧贴屏幕左边距（16pt）。
            XCTAssertEqual(
                snapshot.backButtonFrame.minX,
                PhoneSessionFloatingCapsuleMetrics.horizontalScreenMargin,
                accuracy: 1.0,
                "\(context)：左返回按钮必须贴屏幕左边距",
                file: file,
                line: line
            )
            XCTAssertEqual(
                snapshot.backButtonFrame.width,
                PhoneSessionFloatingCapsuleMetrics.buttonSize,
                accuracy: 0.5,
                context,
                file: file,
                line: line
            )
            XCTAssertEqual(
                snapshot.backButtonFrame.height,
                PhoneSessionFloatingCapsuleMetrics.buttonSize,
                accuracy: 0.5,
                context,
                file: file,
                line: line
            )

            // 2. 右更多按钮：44×44 圆形，紧贴屏幕右边距（16pt）。
            XCTAssertEqual(
                expectedContainerWidth - snapshot.moreButtonFrame.maxX,
                PhoneSessionFloatingCapsuleMetrics.horizontalScreenMargin,
                accuracy: 1.0,
                "\(context)：右菜单按钮必须贴屏幕右边距",
                file: file,
                line: line
            )
            XCTAssertEqual(
                snapshot.moreButtonFrame.width,
                PhoneSessionFloatingCapsuleMetrics.buttonSize,
                accuracy: 0.5,
                context,
                file: file,
                line: line
            )
            XCTAssertEqual(
                snapshot.moreButtonFrame.height,
                PhoneSessionFloatingCapsuleMetrics.buttonSize,
                accuracy: 0.5,
                context,
                file: file,
                line: line
            )

            // 3. 中间胶囊水平居中且不超过当前容器允许的最大宽度。
            let resolvedMax = PhoneSessionFloatingCapsuleMetrics.resolvedMaxWidth(
                containerWidth: expectedContainerWidth
            )
            XCTAssertLessThanOrEqual(
                snapshot.centerCapsuleFrame.width,
                resolvedMax + 0.5,
                "\(context)：中间胶囊宽度不得超过 \(resolvedMax)pt",
                file: file,
                line: line
            )
            XCTAssertEqual(
                snapshot.centerCapsuleFrame.midX,
                expectedContainerWidth / 2,
                accuracy: 1.0,
                "\(context)：中间胶囊必须水平居中",
                file: file,
                line: line
            )

            // 4. 三者不重叠且与左右按钮之间至少保留 8pt 间距。
            XCTAssertFalse(
                snapshot.backButtonFrame.intersects(snapshot.centerCapsuleFrame),
                "\(context)：左按钮与中间胶囊不能重叠",
                file: file,
                line: line
            )
            XCTAssertFalse(
                snapshot.centerCapsuleFrame.intersects(snapshot.moreButtonFrame),
                "\(context)：中间胶囊与右按钮不能重叠",
                file: file,
                line: line
            )
            XCTAssertGreaterThanOrEqual(
                snapshot.centerCapsuleFrame.minX - snapshot.backButtonFrame.maxX,
                PhoneSessionFloatingCapsuleMetrics.interItemSpacing - 0.5,
                "\(context)：左按钮与中间胶囊间距必须 >= 8pt",
                file: file,
                line: line
            )
            XCTAssertGreaterThanOrEqual(
                snapshot.moreButtonFrame.minX - snapshot.centerCapsuleFrame.maxX,
                PhoneSessionFloatingCapsuleMetrics.interItemSpacing - 0.5,
                "\(context)：中间胶囊与右按钮间距必须 >= 8pt",
                file: file,
                line: line
            )

            // 5. 三者高度一致且垂直居中对齐。
            XCTAssertEqual(
                snapshot.centerCapsuleFrame.height,
                snapshot.backButtonFrame.height,
                accuracy: 1.0,
                "\(context)：中间胶囊应与左右圆形按钮高度一致",
                file: file,
                line: line
            )
            XCTAssertEqual(
                snapshot.backButtonFrame.midY,
                snapshot.centerCapsuleFrame.midY,
                accuracy: 1.0,
                "\(context)：左按钮与中间胶囊应垂直居中对齐",
                file: file,
                line: line
            )
            XCTAssertEqual(
                snapshot.moreButtonFrame.midY,
                snapshot.centerCapsuleFrame.midY,
                accuracy: 1.0,
                "\(context)：右按钮与中间胶囊应垂直居中对齐",
                file: file,
                line: line
            )
        }

        let shortSnapshot = measureHeader(
            title: "dr eggbot v2",
            subtitle: "mimi-remote",
            containerWidth: 402
        )
        assertThreePieceInvariants(shortSnapshot, expectedContainerWidth: 402, context: "402pt 短标题")
        XCTAssertLessThan(
            shortSnapshot.centerCapsuleFrame.width,
            PhoneSessionFloatingCapsuleMetrics.resolvedMaxWidth(containerWidth: 402) - 20,
            "短标题胶囊应紧贴内容宽度，不撑满整个可用槽位"
        )

        let longSnapshot = measureHeader(
            title: "这是一个非常非常长的会话标题用来验证悬浮胶囊顶栏在内容过长时会单行尾部截断而绝不撑破容器边界",
            subtitle: "very-long-workspace-repository-name-with-deep-nested-subpath",
            containerWidth: 402
        )
        assertThreePieceInvariants(longSnapshot, expectedContainerWidth: 402, context: "402pt 超长标题")
        XCTAssertLessThanOrEqual(
            abs(longSnapshot.centerCapsuleFrame.height - shortSnapshot.centerCapsuleFrame.height),
            1.0,
            "超长标题必须保持单行截断，不能折行撑高中间胶囊"
        )

        let wideLongSnapshot = measureHeader(
            title: "这是一个非常非常长的会话标题用来验证宽屏容器下中间胶囊严格封顶在 304pt 上限",
            subtitle: "mimi-remote",
            containerWidth: 520
        )
        assertThreePieceInvariants(wideLongSnapshot, expectedContainerWidth: 520, context: "520pt 超长标题")
        XCTAssertLessThanOrEqual(
            wideLongSnapshot.centerCapsuleFrame.width,
            PhoneSessionFloatingCapsuleMetrics.maximumWidth + 0.5,
            "宽容器下中间胶囊宽度应严格封顶在 304pt"
        )

        let narrowLongSnapshot = measureHeader(
            title: "这是一个非常非常长的会话标题用来验证极窄屏下三件绝不重叠且保持 8pt 间距",
            subtitle: "mimi-remote",
            containerWidth: 320
        )
        assertThreePieceInvariants(narrowLongSnapshot, expectedContainerWidth: 320, context: "320pt 超长标题")
    }

    @MainActor
    func testNavigationInteractivePopEnablerSurvivesHiddenNavBarFirstEntryAndTabRestore() throws {
        final class HostModel: ObservableObject {
            @Published var selectedTab: Int = 0
            @Published var path: [String] = []
        }

        struct TabNavigationHost: View {
            @ObservedObject var model: HostModel

            var body: some View {
                TabView(selection: $model.selectedTab) {
                    NavigationStack(path: $model.path) {
                        Color.clear
                            .navigationDestination(for: String.self) { id in
                                Color.clear
                                    .navigationTitle(id)
                                    .navigationBarTitleDisplayMode(.inline)
                                    .toolbar(.hidden, for: .navigationBar)
                                    .background {
                                        NavigationInteractivePopEnabler()
                                            .frame(width: 0, height: 0)
                                    }
                            }
                    }
                    .tabItem { Text("Sessions") }
                    .tag(0)

                    NavigationStack {
                        Color.clear
                    }
                    .tabItem { Text("Workspaces") }
                    .tag(1)
                }
            }
        }

        func findNavigationControllers(in vc: UIViewController) -> [UINavigationController] {
            var result: [UINavigationController] = []
            if let nav = vc as? UINavigationController {
                result.append(nav)
            }
            for child in vc.children {
                result.append(contentsOf: findNavigationControllers(in: child))
            }
            return result
        }

        func pump(_ seconds: TimeInterval = 0.25) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        let model = HostModel()
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: TabNavigationHost(model: model))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = bounds
        } else {
            window = UIWindow(frame: bounds)
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        host.view.frame = bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        pump(0.35)

        // 1. 首次进入详情：隐藏原生导航栏后仍必须接管左缘及 iOS 26+ 内容区交互式返回手势。
        model.path = ["session-1"]
        pump(0.45)

        let nav = try XCTUnwrap(
            findNavigationControllers(in: host).first(where: { $0.viewControllers.count == 2 }),
            "应找到已 push 详情页的 UINavigationController"
        )
        XCTAssertTrue(nav.isNavigationBarHidden, "详情页应隐藏原生导航栏")
        let edgeGesture = try XCTUnwrap(nav.interactivePopGestureRecognizer)
        XCTAssertTrue(edgeGesture.isEnabled, "首次进详情后左缘返回手势必须保持启用")
        let edgeDelegate = try XCTUnwrap(edgeGesture.delegate as? NavigationInteractivePopEnabler.Controller)
        XCTAssertTrue(
            edgeDelegate.gestureRecognizerShouldBegin(edgeGesture),
            "首次进详情后左缘返回手势应允许开始"
        )
        let listPan = UIScrollView().panGestureRecognizer
        XCTAssertTrue(
            edgeDelegate.gestureRecognizer(edgeGesture, shouldBeRequiredToFailBy: listPan),
            "左缘返回手势必须优先于列表滚动手势"
        )
        if #available(iOS 26.0, *) {
            let contentGesture = try XCTUnwrap(nav.interactiveContentPopGestureRecognizer)
            XCTAssertTrue(contentGesture.isEnabled, "iOS 26+ 首次进详情后内容区右滑返回手势必须保持启用")
            XCTAssertTrue(
                contentGesture.delegate === edgeDelegate,
                "iOS 26+ 隐藏导航栏时内容区返回手势同样必须由 NavigationInteractivePopEnabler 接管"
            )
        }

        // 2. 跨 Tab 切走再切回：恢复详情后两条手势仍必须保持接管与启用。
        model.selectedTab = 1
        pump(0.35)
        model.selectedTab = 0
        pump(0.45)

        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertTrue(edgeGesture.isEnabled, "跨 Tab 恢复后左缘返回手势必须保持启用")
        XCTAssertTrue(
            edgeGesture.delegate is NavigationInteractivePopEnabler.Controller,
            "跨 Tab 恢复后左缘返回手势代理必须保持接管"
        )
        if #available(iOS 26.0, *) {
            let contentGesture = try XCTUnwrap(nav.interactiveContentPopGestureRecognizer)
            XCTAssertTrue(contentGesture.isEnabled, "跨 Tab 恢复后内容区右滑返回手势必须保持启用")
            XCTAssertTrue(
                contentGesture.delegate is NavigationInteractivePopEnabler.Controller,
                "跨 Tab 恢复后内容区右滑返回手势代理必须保持接管"
            )
        }

        // 3. 返回列表根页后应恢复系统原代理，避免根页卡死。
        model.path = []
        pump(0.45)

        XCTAssertEqual(nav.viewControllers.count, 1)
        XCTAssertFalse(
            edgeGesture.delegate is NavigationInteractivePopEnabler.Controller,
            "回到根页后应释放自定义手势代理"
        )
        if #available(iOS 26.0, *),
           let contentGesture = nav.interactiveContentPopGestureRecognizer {
            XCTAssertFalse(
                contentGesture.delegate is NavigationInteractivePopEnabler.Controller,
                "回到根页后应释放内容区自定义手势代理"
            )
        }
    }

    @MainActor
    func testNavigationInteractivePopDirectionAndGestureArbitrationRules() {
        // LTR / RTL 方向判断、初始零位移放行与纵向滚动隔离。
        XCTAssertTrue(
            NavigationInteractivePopEnabler.Controller.shouldBeginInteractivePop(
                translation: .zero,
                isRTL: false,
                isEdgeGesture: false
            ),
            "触发初期零位移必须放行，与 UIKit 原生 interactiveTransition 行为一致"
        )
        XCTAssertTrue(
            NavigationInteractivePopEnabler.Controller.shouldBeginInteractivePop(
                translation: CGPoint(x: 24, y: 2),
                isRTL: false,
                isEdgeGesture: false
            )
        )
        XCTAssertFalse(
            NavigationInteractivePopEnabler.Controller.shouldBeginInteractivePop(
                translation: CGPoint(x: 4, y: 30),
                isRTL: false,
                isEdgeGesture: false
            ),
            "内容区纵向滚动不得触发右滑返回"
        )
        XCTAssertFalse(
            NavigationInteractivePopEnabler.Controller.shouldBeginInteractivePop(
                translation: CGPoint(x: -24, y: 0),
                isRTL: false,
                isEdgeGesture: false
            )
        )
        XCTAssertTrue(
            NavigationInteractivePopEnabler.Controller.shouldBeginInteractivePop(
                translation: CGPoint(x: -24, y: 2),
                isRTL: true,
                isEdgeGesture: false
            ),
            "RTL 布局应镜像接受向左滑动返回"
        )

        // 内容区手势避开滑块、编辑中输入框及选区中的文本视图，但不拦截普通只读消息文本。
        let container = UIView()
        let slider = UISlider()
        let readOnlyTextView = UITextView()
        readOnlyTextView.isEditable = false
        readOnlyTextView.isSelectable = false
        let selectingTextView = UITextView()
        selectingTextView.isEditable = false
        selectingTextView.isSelectable = true
        let editableTextView = UITextView()
        editableTextView.isEditable = true
        for child in [slider, readOnlyTextView, selectingTextView, editableTextView] {
            container.addSubview(child)
        }
        XCTAssertFalse(NavigationInteractivePopEnabler.Controller.shouldContentPopReceiveTouch(on: slider, boundedBy: container))
        XCTAssertFalse(NavigationInteractivePopEnabler.Controller.shouldContentPopReceiveTouch(on: editableTextView, boundedBy: container))
        XCTAssertFalse(NavigationInteractivePopEnabler.Controller.shouldContentPopReceiveTouch(on: selectingTextView, boundedBy: container))
        XCTAssertTrue(NavigationInteractivePopEnabler.Controller.shouldContentPopReceiveTouch(on: readOnlyTextView, boundedBy: container))

        // 横向可滚动容器（如宽代码块/表格）未到前缘时让步，已到前缘或仅纵向滚动时不拦截返回。
        let verticalScroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        verticalScroll.contentSize = CGSize(width: 360, height: 1400)
        XCTAssertFalse(NavigationInteractivePopEnabler.Controller.shouldYieldToHorizontalScrollView(verticalScroll, isRTL: false))

        let horizontalScroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 200))
        horizontalScroll.contentSize = CGSize(width: 800, height: 200)
        horizontalScroll.contentOffset = .zero
        XCTAssertFalse(NavigationInteractivePopEnabler.Controller.shouldYieldToHorizontalScrollView(horizontalScroll, isRTL: false))
        horizontalScroll.contentOffset = CGPoint(x: 48, y: 0)
        XCTAssertTrue(NavigationInteractivePopEnabler.Controller.shouldYieldToHorizontalScrollView(horizontalScroll, isRTL: false))
    }

    func testPhoneFloatingHeaderAccessibilityValueUsesNonStaleStatusSummary() {
        let runningTitle = L10n.text("ui.running")

        let connected = UnifiedWorkbenchShell.stableSessionTitleAccessibilityValue(
            statusTitle: runningTitle,
            webSocketStatus: .connected,
            hasRuntimeActivity: true
        )
        XCTAssertEqual(connected, runningTitle, "无秒级定时器的悬浮标题胶囊在连接正常时只播报稳定状态，不嵌入会过期的秒数")
        XCTAssertFalse(connected.contains("00:"), "稳定无障碍摘要不得包含冻结的时钟读数")

        let reconnecting = UnifiedWorkbenchShell.stableSessionTitleAccessibilityValue(
            statusTitle: runningTitle,
            webSocketStatus: .connecting,
            hasRuntimeActivity: true
        )
        XCTAssertEqual(reconnecting, "\(runningTitle) · \(L10n.text("ui.live_status_reconnecting"))")

        let disconnected = UnifiedWorkbenchShell.stableSessionTitleAccessibilityValue(
            statusTitle: runningTitle,
            webSocketStatus: .disconnected,
            hasRuntimeActivity: true
        )
        XCTAssertEqual(disconnected, "\(runningTitle) · \(L10n.text("ui.live_status_disconnected"))")

        let noRuntime = UnifiedWorkbenchShell.stableSessionTitleAccessibilityValue(
            statusTitle: L10n.text("ui.pending_approval"),
            webSocketStatus: .disconnected,
            hasRuntimeActivity: false
        )
        XCTAssertEqual(noRuntime, L10n.text("ui.pending_approval"))
    }

    private func assertSingleActiveDetailInvariant(
        _ state: WorkbenchNavigationState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hasSessionDetail = !state.compactSessionPath.isEmpty
        let hasWorkspaceDetail = !state.compactWorkspacePath.isEmpty
        XCTAssertFalse(
            hasSessionDetail && hasWorkspaceDetail,
            "同一时刻会话 Tab 与工作区 Tab 不能同时持有会话详情栈",
            file: file,
            line: line
        )
        for path in [state.compactSessionPath, state.compactWorkspacePath] where !path.isEmpty {
            XCTAssertLessThanOrEqual(path.count, 2, file: file, line: line)
            if case .session(let parentID) = path[0] {
                if path.count == 2 {
                    if case .subagent(let subagentParentID, _) = path[1] {
                        XCTAssertEqual(subagentParentID, parentID, file: file, line: line)
                    } else {
                        XCTFail("详情栈第二层只能是同一父会话的子 Agent", file: file, line: line)
                    }
                }
            } else {
                XCTFail("详情栈第一层必须是会话详情", file: file, line: line)
            }
        }
    }

    private func assertTappingWorkspacesShowsList(
        _ state: inout WorkbenchNavigationState,
        selectedSessionID: SessionID?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let effect = state.reduce(
            .compactTabChanged(.workspaces),
            usesCompactNavigation: true,
            selectedSessionID: selectedSessionID
        )

        XCTAssertEqual(effect, .returnToSessionList, file: file, line: line)
        XCTAssertEqual(state.compactSelectedTab, .workspaces, file: file, line: line)
        XCTAssertEqual(state.selection, .workspaces, file: file, line: line)
        XCTAssertEqual(state.route, .workspaces, file: file, line: line)
        XCTAssertTrue(state.compactWorkspacePath.isEmpty, file: file, line: line)
    }
}

private struct ReadOnlySubagentTabBarHost: View {
    let relation: SessionContextSubagent
    let parentID: SessionID
    let childID: SessionID

    var body: some View {
        NavigationStack {
            RelatedSessionConversationView(
                relation: relation,
                parentSessionID: parentID,
                showsCloseButton: false,
                shouldHideTabBar: true,
                onClose: {}
            )
        }
    }
}
