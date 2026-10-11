import SnapshotTesting
import SwiftUI
import XCTest
@testable import MimiRemote

/// 新配对的设备一个工作区都没打开时，空态直接列出电脑上的候选项目（#554）。
/// 会话、工作区两个 Tab 保持平铺写法，基线锁定行高、分隔线起点和深浅色。
@MainActor
final class WorkspaceSuggestionsSnapshotTests: SimplifiedChineseSnapshotTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try SnapshotTestEnvironment.requireFixedSimulator()
    }

    func testSuggestionsOnCompactWidth() {
        assertSuggestions(colorScheme: .light, named: "compact-light")
    }

    func testSuggestionsOnCompactWidthInDarkAppearance() {
        assertSuggestions(colorScheme: .dark, named: "compact-dark")
    }

    private func assertSuggestions(
        colorScheme: ColorScheme,
        named name: String,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        let suiteName = "WorkspaceSuggestionsSnapshotTests.Theme.\(UUID().uuidString)"
        let themeDefaults = UserDefaults(suiteName: suiteName)!
        themeDefaults.removePersistentDomain(forName: suiteName)
        let themeStore = ThemeStore(defaults: themeDefaults)
        let projects = [
            AgentProject(id: "mimi-remote", name: "mimi-remote", path: "/Users/demo/code/mimi-remote"),
            AgentProject(id: "blog", name: "blog", path: "/Users/demo/code/blog"),
            AgentProject(id: "finance-tools", name: "finance-tools", path: "/Users/demo/code/finance-tools"),
        ]
        let width: CGFloat = 393
        let height: CGFloat = 640

        let view = ScrollView {
            WorkspaceSuggestionsView(
                projects: projects,
                onOpen: { _ in .cancelled },
                onBrowseOther: {}
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(themeStore.tokens(for: colorScheme).workbenchCanvasBackground)
        .environmentObject(themeStore)
        .environment(\.colorScheme, colorScheme)
        .frame(width: width, height: height)

        if let failure = verifySnapshot(
            of: view,
            as: .wait(
                for: 0.3,
                on: .image(
                    drawHierarchyInKeyWindow: true,
                    precision: 0.98,
                    layout: .fixed(width: width, height: height)
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

    private var referenceSnapshotDirectory: String? {
        #if targetEnvironment(simulator)
        nil
        #else
        Bundle(for: Self.self).bundlePath
        #endif
    }
}
