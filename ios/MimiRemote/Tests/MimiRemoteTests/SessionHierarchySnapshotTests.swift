import SnapshotTesting
import SwiftUI
import XCTest
@testable import MimiRemote

/// 派生会话用真实的会话行渲染：子行缩进、连接线停在图标前，父行尾部是展开按钮。
@MainActor
final class SessionHierarchySnapshotTests: SimplifiedChineseSnapshotTestCase {
    func testExpandedHierarchyOnPhoneWidth() throws {
        try snapshot(width: 393, collapsed: false)
    }

    func testCollapsedHierarchyInDarkMode() throws {
        try snapshot(width: 393, collapsed: true, colorScheme: .dark)
    }

    func testAccessibilityHierarchyKeepsConnectorWithRowHeight() throws {
        try snapshot(width: 393, collapsed: false, dynamicTypeSize: .accessibility2)
    }

    private func snapshot(
        width: CGFloat,
        collapsed: Bool,
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
        let expansion = SessionHierarchyExpansionStore()
        if collapsed { expansion.toggle("root") }
        let density = SessionIndexRowDensity.compact
        let sessions = [
            session("root", title: "测试用例覆盖检查", status: "history"),
            session("child-ci", title: "#741 全量 iOS XCTest 跑绿与 selector 归属", status: "running", spawnedFrom: "root"),
            session("child-ui", title: "修复 #755 iPad 旋转空白闪现", status: "history", spawnedFrom: "root"),
            session("other", title: "产品宣传视频策划", status: "history")
        ]

        let view = VStack(spacing: 0) {
            SessionHierarchyForEach(sessions: sessions, expansion: expansion) { row, _ in
                SessionIndexRow(
                    session: row.session,
                    foregroundActivity: nil,
                    isSelected: false,
                    isPinned: false,
                    isArchived: false,
                    reminder: nil,
                    isObserving: false,
                    isUnread: row.session.id == "child-ui",
                    density: density,
                    leadingSlot: .runtimeIcon
                )
                .sessionHierarchyRow(
                    row,
                    expansion: expansion,
                    guideX: density.horizontalPadding + density.stateGutterWidth / 2,
                    contentInset: density.horizontalPadding + SessionIndexRowDensity.runtimeIconInset
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .frame(width: width, height: dynamicTypeSize.isAccessibilitySize ? 560 : 240)
        .background(tokens.background)
        .environmentObject(theme)
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.99, layout: .sizeThatFits),
            file: file, testName: testName, line: line
        )
    }

    private func session(_ id: SessionID, title: String, status: String, spawnedFrom: String? = nil) -> AgentSession {
        AgentSession(
            id: id,
            projectID: "demo",
            project: "Demo",
            dir: "/tmp/demo",
            title: title,
            status: status,
            source: "claude",
            runtimeProvider: "claude",
            resumeID: id,
            createdAt: Date(timeIntervalSince1970: 1_792_200_000),
            updatedAt: Date(timeIntervalSince1970: 1_792_200_000),
            activeTurnID: status == "running" ? "\(id)-turn" : nil,
            spawnedFromThreadID: spawnedFrom
        )
    }
}
