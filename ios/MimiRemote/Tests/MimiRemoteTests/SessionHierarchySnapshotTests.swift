import SnapshotTesting
import SwiftUI
import XCTest
@testable import MimiRemote

@MainActor
final class SessionHierarchySnapshotTests: SimplifiedChineseSnapshotTestCase {
    func testExpandedHierarchyOnPhoneWidth() throws {
        try snapshot(width: 393, expanded: true)
    }

    func testCollapsedHierarchyInDarkSidebar() throws {
        try snapshot(width: 320, expanded: false, colorScheme: .dark)
    }

    func testAccessibilityHierarchyWrapsChildTitles() throws {
        try snapshot(width: 393, expanded: true, dynamicTypeSize: .accessibility2)
    }

    private func snapshot(
        width: CGFloat,
        expanded: Bool,
        colorScheme: ColorScheme = .light,
        dynamicTypeSize: DynamicTypeSize = .large,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) throws {
        let suiteName = "SessionHierarchySnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let theme = ThemeStore(defaults: defaults)
        let tokens = theme.tokens(for: colorScheme)
        let parent = AgentSession(
            id: "parent", projectID: "demo", project: "Demo", dir: "/tmp/demo",
            title: "检查 App 体验", status: "history", source: "codex", resumeID: "parent",
            createdAt: nil, updatedAt: nil
        )
        let context = SessionContextSnapshot(subagents: [
            SessionContextSubagent(id: "layout", nickname: "检查 iPad 布局与横竖屏切换", status: "completed"),
            SessionContextSubagent(id: "review", nickname: "复核会话状态和消息顺序", status: "waiting_for_input"),
            SessionContextSubagent(id: "tests", nickname: "补充列表与导航回归测试", status: "failed")
        ])
        let view = VStack(spacing: 8) {
            SessionHierarchyGroup(
                isExpanded: .constant(expanded),
                parent: parent,
                children: SessionHierarchyPresentation.children(of: parent, sessions: [parent], context: context),
                unreadIDs: ["layout"],
                onOpenChild: { _ in }
            ) {
                Text(parent.title)
                    .font(theme.uiFont(.subheadline))
                    .foregroundStyle(tokens.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.leading, 12)
            }
            Text("整理下一版发布计划")
                .font(theme.uiFont(.subheadline))
                .foregroundStyle(tokens.listTitleText)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: width, height: dynamicTypeSize.isAccessibilitySize ? 620 : 280)
        .background(tokens.sidebarBackground)
        .environmentObject(theme)
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.99, layout: .sizeThatFits),
            file: file, testName: testName, line: line
        )
    }
}
