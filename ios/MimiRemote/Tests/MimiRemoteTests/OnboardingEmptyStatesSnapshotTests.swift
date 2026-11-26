import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// 无主机真实空态的多尺寸、浅深色与辅助功能字号（AX2/AX3）视觉快照与可点击热区基线。
///
/// 固定在 `iPad Pro 13-inch (M5)` 上渲染 `390×844`、`744×1133`、`1133×744` 三种画布，
/// 同时校验在无主机空态渲染期间不发起任何后台网络请求，且交互按钮命中区不小于 44×44 pt。
@MainActor
final class OnboardingEmptyStatesSnapshotTests: SimplifiedChineseSnapshotTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try SnapshotTestEnvironment.requireFixedSimulator()
    }

    func testSessionListNoHostEmptyStatePhoneCompactLightAndDark() {
        assertSessionListEmptyState(
            width: 390,
            height: 844,
            horizontalSizeClass: .compact,
            colorScheme: .light,
            dynamicTypeSize: .large,
            usesCompactNavigation: true,
            hasBottomTabBar: true,
            named: "sessions-390x844-compact-light"
        )
        assertSessionListEmptyState(
            width: 390,
            height: 844,
            horizontalSizeClass: .compact,
            colorScheme: .dark,
            dynamicTypeSize: .large,
            usesCompactNavigation: true,
            hasBottomTabBar: true,
            named: "sessions-390x844-compact-dark"
        )
    }

    func testSessionListNoHostEmptyStatePhoneCompactAX2AndAX3() {
        assertSessionListEmptyState(
            width: 390,
            height: 844,
            horizontalSizeClass: .compact,
            colorScheme: .light,
            dynamicTypeSize: .accessibility2,
            usesCompactNavigation: true,
            hasBottomTabBar: true,
            named: "sessions-390x844-compact-ax2"
        )
        assertSessionListEmptyState(
            width: 390,
            height: 844,
            horizontalSizeClass: .compact,
            colorScheme: .dark,
            dynamicTypeSize: .accessibility3,
            usesCompactNavigation: true,
            hasBottomTabBar: true,
            named: "sessions-390x844-compact-ax3"
        )
    }

    func testWorkspaceNoHostEmptyStatePhoneCompactAndTabletPortrait() {
        assertWorkspaceEmptyState(
            width: 390,
            height: 844,
            horizontalSizeClass: .compact,
            colorScheme: .light,
            dynamicTypeSize: .large,
            hasBottomTabBar: true,
            named: "workspace-390x844-compact-light"
        )
        assertWorkspaceEmptyState(
            width: 390,
            height: 844,
            horizontalSizeClass: .compact,
            colorScheme: .dark,
            dynamicTypeSize: .accessibility2,
            hasBottomTabBar: true,
            named: "workspace-390x844-compact-dark-ax2"
        )
        assertWorkspaceEmptyState(
            width: 744,
            height: 1_133,
            horizontalSizeClass: .compact,
            colorScheme: .light,
            dynamicTypeSize: .accessibility3,
            hasBottomTabBar: false,
            named: "workspace-744x1133-compact-light-ax3"
        )
    }

    func testSessionListNoHostEmptyStateTabletPortraitLightAndDark() {
        assertSessionListEmptyState(
            width: 744,
            height: 1_133,
            horizontalSizeClass: .compact,
            colorScheme: .light,
            dynamicTypeSize: .large,
            usesCompactNavigation: true,
            hasBottomTabBar: false,
            named: "sessions-744x1133-compact-light"
        )
        assertSessionListEmptyState(
            width: 744,
            height: 1_133,
            horizontalSizeClass: .regular,
            colorScheme: .dark,
            dynamicTypeSize: .accessibility2,
            usesCompactNavigation: false,
            hasBottomTabBar: false,
            named: "sessions-744x1133-regular-dark-ax2"
        )
    }

    func testRegularWorkbenchEmptyStateLandscapeLightDarkAndAX3() {
        assertRegularSplitEmptyState(
            width: 1_133,
            height: 744,
            colorScheme: .light,
            dynamicTypeSize: .large,
            named: "workbench-1133x744-regular-light"
        )
        assertRegularSplitEmptyState(
            width: 1_133,
            height: 744,
            colorScheme: .dark,
            dynamicTypeSize: .large,
            named: "workbench-1133x744-regular-dark"
        )
        assertRegularSplitEmptyState(
            width: 1_133,
            height: 744,
            colorScheme: .light,
            dynamicTypeSize: .accessibility3,
            named: "workbench-1133x744-regular-light-ax3"
        )
    }

    /// 实测无主机空态交互按钮在不同画布与动态字号下的真实 UIKit 边界，保证命中区均 ≥ 44×44 pt。
    func testUnpairedHostEmptyStateInteractiveTargetsMeetMinimum44ptAcrossSizesAndDynamicTypes() throws {
        let cases: [(UnpairedHostEmptyStateContext, CGSize, DynamicTypeSize)] = [
            (.sessions, CGSize(width: 390, height: 844), .large),
            (.sessions, CGSize(width: 390, height: 844), .accessibility3),
            (.workspaces, CGSize(width: 744, height: 1_133), .accessibility2),
            (.sidebar, CGSize(width: 300, height: 744), .large),
            (.sidebar, CGSize(width: 300, height: 744), .accessibility3),
        ]

        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)

        for (context, size, dynamicType) in cases {
            let fixture = makeNoHostFixture()
            var connectTapCount = 0
            let view = UnpairedHostEmptyStateView(
                context: context,
                onConnectComputer: {
                    connectTapCount += 1
                }
            )
            .defaultAppStorage(fixture.defaults)
            .environmentObject(fixture.themeStore)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, dynamicType)
            .frame(width: size.width, height: size.height)

            let host = UIHostingController(rootView: view)
            host.overrideUserInterfaceStyle = .light
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
            }
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))

            let targetID = context.connectActionAccessibilityIdentifier
            let matchedElement = findAccessibilityElement(identifier: targetID, in: host.view)
            let buttonFrame = try XCTUnwrap(
                accessibilityFrame(of: matchedElement, in: window),
                "应渲染可交互按钮 \(targetID) (\(size), \(dynamicType))"
            )
            XCTAssertGreaterThanOrEqual(
                buttonFrame.width,
                44,
                "\(targetID) 宽度不应小于 44pt (\(size), \(dynamicType))"
            )
            XCTAssertGreaterThanOrEqual(
                buttonFrame.height,
                44,
                "\(targetID) 高度不应小于 44pt (\(size), \(dynamicType))"
            )
            XCTAssertTrue(
                matchedElement?.accessibilityActivate() == true,
                "\(targetID) 应可响应激活操作 (\(size), \(dynamicType))"
            )
            XCTAssertEqual(connectTapCount, 1)
            XCTAssertEqual(fixture.client.requestCount, 0)
        }
    }

    private func assertSessionListEmptyState(
        width: CGFloat,
        height: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass,
        colorScheme: ColorScheme,
        dynamicTypeSize: DynamicTypeSize,
        usesCompactNavigation: Bool,
        hasBottomTabBar: Bool,
        named name: String,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        let fixture = makeNoHostFixture()
        let view = NavigationStack {
            SessionListView(
                onConnectComputer: {},
                prefersTableDensity: horizontalSizeClass == .regular,
                usesCompactNavigation: usesCompactNavigation,
                bottomContentMargin: hasBottomTabBar ? 96 : 16
            )
        }
        .defaultAppStorage(fixture.defaults)
        .environmentObject(fixture.appStore)
        .environmentObject(fixture.sessionStore)
        .environmentObject(fixture.themeStore)
        .environment(\.horizontalSizeClass, horizontalSizeClass)
        .environment(\.workbenchHasBottomTabBar, hasBottomTabBar)
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .transaction { $0.disablesAnimations = true }
        .frame(width: width, height: height)

        assertSnapshotView(
            view,
            width: width,
            height: height,
            horizontalSizeClass: horizontalSizeClass,
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            named: name,
            file: file,
            testName: testName,
            line: line
        )
        XCTAssertEqual(
            fixture.client.requestCount,
            0,
            "会话页无主机空态不应发出任何后台请求",
            file: file,
            line: line
        )
    }

    private func assertWorkspaceEmptyState(
        width: CGFloat,
        height: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass,
        colorScheme: ColorScheme,
        dynamicTypeSize: DynamicTypeSize,
        hasBottomTabBar: Bool,
        named name: String,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        let fixture = makeNoHostFixture()
        let view = WorkspaceRootView(
            selectedSessionRuntime: .constant(.codex),
            onStartSession: { _, _ in },
            onConnectComputer: {},
            embedsNavigationStack: false,
            bottomContentMargin: hasBottomTabBar ? 96 : 16
        )
        .defaultAppStorage(fixture.defaults)
        .environmentObject(fixture.appStore)
        .environmentObject(fixture.sessionStore)
        .environmentObject(fixture.themeStore)
        .environment(\.horizontalSizeClass, horizontalSizeClass)
        .environment(\.workbenchHasBottomTabBar, hasBottomTabBar)
        .environment(\.workbenchHasCompactTabBar, horizontalSizeClass == .compact)
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .transaction { $0.disablesAnimations = true }
        .frame(width: width, height: height)

        assertSnapshotView(
            view,
            width: width,
            height: height,
            horizontalSizeClass: horizontalSizeClass,
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            named: name,
            file: file,
            testName: testName,
            line: line
        )
        XCTAssertEqual(
            fixture.client.requestCount,
            0,
            "工作区页无主机空态不应发出任何后台请求",
            file: file,
            line: line
        )
    }

    private func assertRegularSplitEmptyState(
        width: CGFloat,
        height: CGFloat,
        colorScheme: ColorScheme,
        dynamicTypeSize: DynamicTypeSize,
        named name: String,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        let fixture = makeNoHostFixture()
        let view = HStack(spacing: 0) {
            ProjectSidebarView(
                showsSessions: true,
                onConnectComputer: {}
            )
            .frame(width: 312)

            SessionListView(
                onConnectComputer: {},
                prefersTableDensity: true,
                usesCompactNavigation: false,
                bottomContentMargin: 16
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .defaultAppStorage(fixture.defaults)
        .environmentObject(fixture.appStore)
        .environmentObject(fixture.sessionStore)
        .environmentObject(fixture.themeStore)
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.workbenchHasBottomTabBar, false)
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .transaction { $0.disablesAnimations = true }
        .frame(width: width, height: height)

        assertSnapshotView(
            view,
            width: width,
            height: height,
            horizontalSizeClass: .regular,
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            named: name,
            file: file,
            testName: testName,
            line: line
        )
        XCTAssertEqual(
            fixture.client.requestCount,
            0,
            "宽屏分栏无主机空态不应发出任何后台请求",
            file: file,
            line: line
        )
    }

    private func assertSnapshotView<V: View>(
        _ view: V,
        width: CGFloat,
        height: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass,
        colorScheme: ColorScheme,
        dynamicTypeSize: DynamicTypeSize,
        named name: String,
        file: StaticString,
        testName: String,
        line: UInt
    ) {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light),
            UITraitCollection(horizontalSizeClass: horizontalSizeClass == .compact ? .compact : .regular),
            UITraitCollection(preferredContentSizeCategory: uiContentSizeCategory(for: dynamicTypeSize)),
        ])

        if let failure = verifySnapshot(
            of: view,
            as: .wait(
                for: 0.25,
                on: .image(
                    drawHierarchyInKeyWindow: true,
                    precision: 0.98,
                    layout: .fixed(width: width, height: height),
                    traits: traits
                )
            ),
            named: name,
            snapshotDirectory: referenceSnapshotDirectory,
            file: file,
            testName: testName,
            line: line
        ) {
            XCTFail(failure, file: file, line: line)
        }
    }

    private func uiContentSizeCategory(for dynamicTypeSize: DynamicTypeSize) -> UIContentSizeCategory {
        switch dynamicTypeSize {
        case .accessibility2:
            return .accessibilityLarge
        case .accessibility3:
            return .accessibilityExtraLarge
        default:
            return .large
        }
    }

    private func makeNoHostFixture() -> OnboardingEmptyStateSnapshotFixture {
        let suiteName = "OnboardingEmptyStatesSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false
        )
        let client = SnapshotCountingNoHostClient()
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: RecentWorkspaceStore(defaults: defaults),
            clientFactory: { client }
        )
        let themeStore = ThemeStore(defaults: defaults)
        return OnboardingEmptyStateSnapshotFixture(
            defaults: defaults,
            appStore: appStore,
            sessionStore: sessionStore,
            themeStore: themeStore,
            client: client
        )
    }

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

    private func accessibilityIdentifier(of object: NSObject) -> String? {
        if let identification = object as? UIAccessibilityIdentification,
           let identifier = identification.accessibilityIdentifier,
           !identifier.isEmpty {
            return identifier
        }
        let selector = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        guard object.responds(to: selector),
              let rawValue = object.perform(selector)?.takeUnretainedValue() as? String,
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private func accessibilityFrame(of object: NSObject?, in window: UIWindow) -> CGRect? {
        guard let object else { return nil }
        if let view = object as? UIView {
            return view.convert(view.bounds, to: window)
        }
        let frame = object.accessibilityFrame
        return frame.isEmpty ? nil : frame
    }

    private var referenceSnapshotDirectory: String? {
        #if targetEnvironment(simulator)
        nil
        #else
        Bundle(for: Self.self).bundlePath
        #endif
    }
}

@MainActor
private struct OnboardingEmptyStateSnapshotFixture {
    let defaults: UserDefaults
    let appStore: AppStore
    let sessionStore: SessionStore
    let themeStore: ThemeStore
    let client: SnapshotCountingNoHostClient
}

private final class SnapshotCountingNoHostClient: SessionStoreAPIClient {
    private let lock = NSLock()
    private var requestCountStorage = 0

    var requestCount: Int {
        lock.withLock { requestCountStorage }
    }

    private func recordRequest() {
        lock.withLock { requestCountStorage += 1 }
    }

    func projects() async throws -> [AgentProject] {
        recordRequest()
        return []
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        recordRequest()
        return []
    }

    func modelOptions(runtimeProvider: String) async throws -> [CodexAppServerModelOption] {
        recordRequest()
        return []
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        recordRequest()
        return []
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        recordRequest()
        return SessionsPage(sessions: [])
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        recordRequest()
        return SessionsPage(sessions: [])
    }

    func sessionsPage(
        projectID: String?,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        recordRequest()
        return SessionsPage(sessions: [])
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        recordRequest()
        return SessionsPage(sessions: [])
    }

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage {
        recordRequest()
        return SessionsPage(sessions: [])
    }

    func controlledGlobalSessionsPage(runtimeProvider: String, cursor: String?, limit: Int?) async throws -> SessionsPage {
        recordRequest()
        return SessionsPage(sessions: [])
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        recordRequest()
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        recordRequest()
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        recordRequest()
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        recordRequest()
        return []
    }
}
