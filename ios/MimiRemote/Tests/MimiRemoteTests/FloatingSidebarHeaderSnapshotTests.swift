import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// #754：iPad 浮动侧栏滚到底后，分组标题和行不能钻到顶部「当前电脑」后方叠字。
///
/// 列表在窗口里排版后直接把底层 UIScrollView 滚到底，正是缺陷现场：顶部入口原来以透明
/// `safeAreaInset` 挂在 List 上，列表内容会滚进它后方。`defaultScrollAnchor(.bottom)` 在这种
/// 离线窗口里不生效，上沿渐隐又依赖真实滚动几何回调，所以按用户滚动的方式改 contentOffset。
@MainActor
final class FloatingSidebarHeaderSnapshotTests: SimplifiedChineseSnapshotTestCase {
    private struct SidebarSection {
        let title: String
        let rows: [String]
    }

    private static let sections = [
        SidebarSection(title: "待你处理 1", rows: ["等待确认部署方案"]),
        SidebarSection(title: "进行中 2", rows: ["检查连接恢复测试", "Luna 多轮验收"]),
        SidebarSection(
            title: "最近 8",
            rows: [
                "整理开源发布说明", "完善示例项目文档", "这两个应该是一个问题", "排查 MIM82 Claude",
                "查看待办 Issue 状态", "参考 Seedex 网站", "确认 MIM-99 是否完成", "复盘上周发布"
            ]
        )
    ]

    func testScrolledToBottomKeepsRowsClearOfFloatingHeader() async throws {
        let size = CGSize(
            width: WorkbenchSidebarSurfaceMetrics.overlayWidth
                + WorkbenchSidebarSurfaceMetrics.outerInset * 2,
            height: 420
        )
        let image = try await renderInWindow(size: size) { tokens in
            WorkbenchSidebarContainer(tokens: tokens, usesFloatingSurface: true) {
                self.sidebarList
            } floatingHeader: {
                WorkbenchFloatingSidebarHeader(tokens: tokens, onCollapse: {}) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前电脑")
                            .font(.subheadline.weight(.semibold))
                        Text("连接状态")
                            .font(.caption2)
                            .foregroundStyle(tokens.secondaryText)
                    }
                    .frame(minHeight: 44)
                }
            } toolbarHeader: {
                EmptyView()
            }
        }
        assertSnapshot(of: image, as: .image(precision: 0.98))
    }

    private var sidebarList: some View {
        List {
            Section {
                Label("会话", systemImage: "bubble.left")
                Label("工作区", systemImage: "square.grid.2x2")
            }
            ForEach(Self.sections, id: \.title) { section in
                Section {
                    ForEach(section.rows, id: \.self) { title in
                        Text(title).lineLimit(1)
                    }
                } header: {
                    Text(section.title)
                        .pageSectionHeaderStyle()
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 40)
    }

    private func renderInWindow<Content: View>(
        size: CGSize,
        @ViewBuilder content: (ThemeTokens) -> Content
    ) async throws -> UIImage {
        let suiteName = "FloatingSidebarHeaderSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .light
        let tokens = themeStore.tokens(for: .light)

        let host = UIHostingController(
            rootView: content(tokens)
                .environmentObject(themeStore)
                .environment(\.colorScheme, .light)
                .environment(\.horizontalSizeClass, .regular)
                .background(tokens.workbenchCanvasBackground)
        )
        host.overrideUserInterfaceStyle = .light
        host.safeAreaRegions = []
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = window.bounds
        try await settleLayout(of: host.view)
        let scrollView = try XCTUnwrap(firstScrollView(in: host.view), "侧栏 List 应落在真实 UIScrollView 上")
        let bottomOffset = scrollView.contentSize.height
            + scrollView.adjustedContentInset.bottom
            - scrollView.bounds.height
        XCTAssertGreaterThan(bottomOffset, 80, "样例列表必须比视口高出至少两行，否则滚到底等于没滚")
        scrollView.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
        // 等滚动几何回调写回渐隐强度、overlay 重新排版这几轮更新落定。
        try await settleLayout(of: host.view)
        return UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }

    private func settleLayout(of view: UIView) async throws {
        for _ in 0..<20 {
            view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }
}
