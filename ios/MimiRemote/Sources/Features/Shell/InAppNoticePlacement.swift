import Observation
import SwiftUI
import UIKit

/// App 内一次性提示（操作反馈、前台回复提醒）的顶部界线（#738）。
///
/// 提示挂在工作台最外层，自己看不到当前页面的导航栏。原先只避开状态栏，结果正好压在
/// 标题、返回和顶栏按钮上；在会话页还会盖住顶部带操作按钮的状态卡片。这里给出提示顶边
/// 不能越过的那条线，取下面两者中更低的一条：
/// - 窗口里贴着顶部的导航栏下沿（iPhone push、iPad 侧栏和详情列都算）；
/// - 页面登记的常驻区域下沿，例如会话页的缩略历史、额度、错误卡片。
@MainActor
@Observable
final class InAppNoticePlacement {
    private(set) var protectedRegionBottoms: [UUID: CGFloat] = [:]
    @ObservationIgnored weak var window: UIWindow?

    /// 登记或撤销（`bottom == nil`）一块常驻区域的下沿，使用全局坐标。
    func reportProtectedRegion(_ id: UUID, bottom: CGFloat?) {
        guard protectedRegionBottoms[id] != bottom else { return }
        protectedRegionBottoms[id] = bottom
    }

    var protectedRegionBottom: CGFloat? {
        protectedRegionBottoms.values.max()
    }

    /// 提示顶边在全局坐标下不能高于的界线。没有导航栏、也没有登记区域时返回 nil。
    func topBoundary() -> CGFloat? {
        let navigationBottom = window.flatMap(Self.topNavigationBarsBottom(in:))
        return [navigationBottom, protectedRegionBottom].compactMap { $0 }.max()
    }

    /// 贴着窗口顶部、当前可见的导航栏中最低的下沿。sheet 里的导航栏不贴顶，不计入；
    /// 隐藏的导航栏也不计入。
    static func topNavigationBarsBottom(in window: UIWindow) -> CGFloat? {
        let topLimit = window.safeAreaInsets.top + 1
        var bottom: CGFloat?
        var pending: [UIView] = [window]
        while let view = pending.popLast() {
            guard !view.isHidden, view.alpha > 0.01 else { continue }
            if let bar = view as? UINavigationBar {
                let frame = bar.convert(bar.bounds, to: window)
                if frame.height > 0, frame.minY <= topLimit {
                    bottom = max(bottom ?? frame.maxY, frame.maxY)
                }
                continue
            }
            pending.append(contentsOf: view.subviews)
        }
        return bottom
    }

    /// 提示卡片相对宿主顶部的上边距。界线在宿主之上或不存在时，退回到宿主顶部（安全区下沿）。
    nonisolated static func toastTopPadding(boundary: CGFloat?, hostMinY: CGFloat) -> CGFloat {
        let spacing: CGFloat = 8
        guard let boundary else { return spacing }
        return max(0, boundary - hostMinY) + spacing
    }
}

private struct InAppNoticePlacementKey: EnvironmentKey {
    static let defaultValue: InAppNoticePlacement? = nil
}

extension EnvironmentValues {
    var inAppNoticePlacement: InAppNoticePlacement? {
        get { self[InAppNoticePlacementKey.self] }
        set { self[InAppNoticePlacementKey.self] = newValue }
    }
}

extension View {
    /// 为工作台里的一次性提示提供顶部界线。挂在所有提示宿主的外层。
    func inAppNoticePlacementScope() -> some View {
        modifier(InAppNoticePlacementScope())
    }

    /// 登记一块一次性提示不能盖住的常驻区域，例如带操作按钮的状态卡片。
    func inAppNoticeProtectedRegion() -> some View {
        modifier(InAppNoticeProtectedRegion())
    }
}

private struct InAppNoticePlacementScope: ViewModifier {
    @State private var placement = InAppNoticePlacement()

    func body(content: Content) -> some View {
        content
            .environment(\.inAppNoticePlacement, placement)
            .background {
                HostWindowReader { [placement] window in
                    placement.window = window
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
    }
}

private struct InAppNoticeProtectedRegion: ViewModifier {
    @Environment(\.inAppNoticePlacement) private var placement
    @State private var id = UUID()
    @State private var lastBottom: CGFloat?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .global).maxY
            } action: { bottom in
                lastBottom = bottom
                placement?.reportProtectedRegion(id, bottom: bottom)
            }
            // 切 Tab 或被 push 盖住时撤销；回来时位置没变不会再触发测量，用上次的值补登记。
            .onAppear {
                if let lastBottom {
                    placement?.reportProtectedRegion(id, bottom: lastBottom)
                }
            }
            .onDisappear {
                placement?.reportProtectedRegion(id, bottom: nil)
            }
    }
}
