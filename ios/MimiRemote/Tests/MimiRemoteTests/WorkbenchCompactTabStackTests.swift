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
