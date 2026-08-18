import SwiftUI

/// 工作区顶部胶囊的尺寸与宽屏信息密度策略。
/// 单独放在布局组件中，避免根页面同时承担视觉策略与会话编排职责。
enum WorkspaceStripLayout {
    static let horizontalPadding: CGFloat = 24
    /// 44pt 同时是 Apple 的最小命中尺寸和整条控件带的高度：选中项展开成带名称的胶囊，
    /// 其余收缩成头像圆，因此一行就能放下全部工作区，不再需要 138pt 的卡片。
    static let chipHeight: CGFloat = 44
    static let chipSpacing: CGFloat = 8
    /// 胶囊行 + 上下呼吸；工作区身份和状态改由下方状态行承担。
    /// 顶部只收紧上下留白，保留 44pt 胶囊命中区。
    static let stripHeight: CGFloat = 56
    /// 头像在展开与收缩两种形态下保持同一光学尺寸，切换时只有胶囊在变宽。
    static let chipIconSize: CGFloat = 28
    /// 胶囊行、状态行与详情内容共用同一个最大宽度，宽屏下三者左右边界一致。
    static let maxContentWidth: CGFloat = 920
    /// 非选中项在宽屏下最多露出 64pt 名称。它只增加信息密度，不参与选中态材质高亮。
    static let restingNameWidth: CGFloat = 64

    static func minimumContentWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - horizontalPadding * 2)
    }

    /// 使用胶囊滚动区的真实宽度，而不是设备宽度。浮动侧栏会持续改变详情区宽度，
    /// 因此这里同时受宽屏阈值和项目数量预算约束：空间不足时仍退回纯头像。
    static func restingNameDisclosure(
        viewportWidth: CGFloat,
        projectCount: Int
    ) -> CGFloat {
        guard viewportWidth > 0, projectCount > 1 else { return 0 }

        let widthProgress = min(max((viewportWidth - 760) / 240, 0), 1)
        let collapsedWidth = CGFloat(projectCount) * chipHeight
            + CGFloat(projectCount - 1) * chipSpacing
        let selectedNameAllowance: CGFloat = 112
        let remainingWidth = max(
            0,
            viewportWidth - collapsedWidth - selectedNameAllowance
        )
        let restingBudget = CGFloat(projectCount - 1) * restingNameWidth
        let budgetProgress = min(max(remainingWidth / restingBudget, 0), 1)
        return min(widthProgress, budgetProgress)
    }
}

/// 把分页 ScrollView 的像素偏移转换成项目索引空间。顶部胶囊只消费这个连续值，
/// 因而 25% 的横滑就是 25% 的收缩/展开，不需要等 selection 在中点切换。
enum WorkspacePagerTransition {
    nonisolated static func pagePosition(
        contentOffsetX: CGFloat,
        leadingInset: CGFloat,
        viewportWidth: CGFloat,
        pageCount: Int
    ) -> CGFloat? {
        guard viewportWidth > 0, pageCount > 0 else { return nil }
        let rawPosition = (contentOffsetX + leadingInset) / viewportWidth
        guard rawPosition.isFinite else { return nil }
        return min(max(rawPosition, 0), CGFloat(pageCount - 1))
    }

    nonisolated static func selectionProgress(
        projectIndex: Int,
        pagePosition: CGFloat
    ) -> CGFloat {
        min(max(1 - abs(CGFloat(projectIndex) - pagePosition), 0), 1)
    }
}

/// 高频滚动几何只发布给胶囊自身，避免横滑每一帧都重算完整的工作区会话列表。
@MainActor
final class WorkspacePagerTransitionState: ObservableObject {
    @Published private(set) var pagePosition: CGFloat?

    func update(pagePosition: CGFloat?) {
        if let current = self.pagePosition, let pagePosition,
           abs(current - pagePosition) < 0.0001 {
            return
        }
        guard self.pagePosition != pagePosition else { return }
        // 几何值已经是系统滚动的呈现帧；禁止再套动画，否则胶囊会落后于手指。
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.pagePosition = pagePosition
        }
    }
}
