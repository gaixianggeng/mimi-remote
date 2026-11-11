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

    /// #993：浮动侧栏底部「设备 / 我的」后方和间隙不能透出会话行。同一底栏分别叠在满屏的行
    /// 和空列表上，入口所在那一段（渐隐以下到面板底边）的像素必须一致：只要有一行透出来就会不同。
    /// 原来底栏只是 overlay 在列表上，未选中的「设备」没有底色，两枚胶囊之间和右侧都会露出行文字。
    func testFloatingFooterHidesRowsBehindDestinationBar() async throws {
        let outerInset = WorkbenchSidebarSurfaceMetrics.outerInset
        let size = CGSize(width: WorkbenchSidebarSurfaceMetrics.overlayWidth + outerInset * 2, height: 420)
        let overRows = try await renderInWindow(size: size, scrollsToBottom: false) { tokens in
            self.floatingSidebar(tokens: tokens) { self.sidebarList }
        }
        let overEmptyList = try await renderInWindow(size: size, scrollsToBottom: false) { tokens in
            self.floatingSidebar(tokens: tokens) {
                List {}
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
            }
        }
        // 入口胶囊高 44pt，上下内距 4 + 10；只取渐隐以下这一段，渐隐本来就允许行半透出来。
        let barBandHeight: CGFloat = 54
        let band = CGRect(
            x: outerInset,
            y: size.height - outerInset - barBandHeight,
            width: WorkbenchSidebarSurfaceMetrics.overlayWidth,
            height: barBandHeight
        )
        let differingPixels = try differingPixelCount(overRows, overEmptyList, in: band)
        XCTAssertEqual(differingPixels, 0, "底栏入口那一段不应因为后方有行而改变")
    }

    private func floatingSidebar<ListContent: View>(
        tokens: ThemeTokens,
        @ViewBuilder list: () -> ListContent
    ) -> some View {
        let list = list()
        return WorkbenchSidebarContainer(tokens: tokens, usesFloatingSurface: true) {
            WorkbenchSidebarContentLayout(usesFloatingSurface: true) {
                list
            } footer: {
                WorkbenchSidebarFooter(
                    tokens: tokens,
                    usesFloatingSurface: true,
                    isDevicesSelected: true,
                    onOpenDevices: {},
                    onOpenSettings: {},
                    onNewSession: {}
                )
            }
        } floatingHeader: {
            WorkbenchFloatingSidebarHeader(tokens: tokens, onCollapse: {}) {
                Text("当前电脑")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        } toolbarHeader: {
            EmptyView()
        }
    }

    /// 两张图都按同一 RGBA 布局重绘后逐像素比较；单通道差超过 8 才算不同，吸收合成时的舍入。
    private func differingPixelCount(_ lhs: UIImage, _ rhs: UIImage, in rect: CGRect) throws -> Int {
        let left = try rgbaPixels(of: lhs, in: rect)
        let right = try rgbaPixels(of: rhs, in: rect)
        XCTAssertEqual(left.count, right.count)
        var count = 0
        for index in stride(from: 0, to: min(left.count, right.count), by: 4) {
            let differs = (0..<4).contains { channel in
                abs(Int(left[index + channel]) - Int(right[index + channel])) > 8
            }
            if differs { count += 1 }
        }
        return count
    }

    private func rgbaPixels(of image: UIImage, in rect: CGRect) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let scale = image.scale
        let cropRect = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        let cropped = try XCTUnwrap(cgImage.cropping(to: cropRect))
        let width = cropped.width
        let height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        return pixels
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
        scrollsToBottom: Bool = true,
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
        if scrollsToBottom {
            let scrollView = try XCTUnwrap(firstScrollView(in: host.view), "侧栏 List 应落在真实 UIScrollView 上")
            let bottomOffset = scrollView.contentSize.height
                + scrollView.adjustedContentInset.bottom
                - scrollView.bounds.height
            XCTAssertGreaterThan(bottomOffset, 80, "样例列表必须比视口高出至少两行，否则滚到底等于没滚")
            scrollView.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
            // 等滚动几何回调写回渐隐强度、overlay 重新排版这几轮更新落定。
            try await settleLayout(of: host.view)
        }
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
