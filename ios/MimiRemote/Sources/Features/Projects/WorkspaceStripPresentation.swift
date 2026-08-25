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
    /// 行末「添加工作区」虚线胶囊的可见尺寸。刻意比 `chipHeight` 小一圈：
    /// 它是次级动作，不该和承载工作区身份的项目胶囊等重。命中区仍由外层撑满 44pt。
    static let addChipVisualSize: CGFloat = 34
    /// Runtime 筛选器并入胶囊行所需的宽度，单位是扣掉两侧 `horizontalPadding`
    /// 和设备入口预算后的实际内容宽。
    ///
    /// 预算：筛选器 ~158 + 分隔 ~9 + 添加胶囊 52 + 选中胶囊 ~95 + 至少一屏可滑的胶囊余量 ~150。
    /// 结果：iPad mini 竖屏（744 屏宽 / 696 容器）与更宽的 iPad 进入合并态；
    /// iPhone 竖屏（393 / 345）、iPad 1/2 与 1/3 分屏落在阈值以下，退回列表上方独立一行。
    static let inlineRuntimePickerMinimumWidth: CGFloat = 640

    static func minimumContentWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - horizontalPadding * 2)
    }

    /// 统一决定 Runtime 是否进入胶囊行，避免 Runtime 布局和行内新建入口分别判断。
    /// `viewportWidth` 是应用了内边距的外层容器宽，不是设备屏宽。
    static func usesInlineRuntimePicker(
        viewportWidth: CGFloat,
        showsHostSwitcherInStrip: Bool,
        hasBottomTabBar: Bool
    ) -> Bool {
        // 底部 Tab 栏时新建按钮必须留在筛选行，横屏 iPhone 也不能切到 inline 布局。
        guard !hasBottomTabBar else { return false }

        let hostSwitcherBudget = showsHostSwitcherInStrip
            ? WorkbenchChromeIconMetrics.minimumHitTarget + chipSpacing
            : 0
        let availableContentWidth = minimumContentWidth(viewportWidth: viewportWidth)
        return availableContentWidth - hostSwitcherBudget >= inlineRuntimePickerMinimumWidth
    }

    /// 使用胶囊滚动区的真实宽度，而不是设备宽度。浮动侧栏会持续改变详情区宽度，
    /// 因此这里同时受宽屏阈值和项目数量预算约束：空间不足时仍退回纯头像。
    static func restingNameDisclosure(
        viewportWidth: CGFloat,
        projectCount: Int
    ) -> CGFloat {
        guard viewportWidth > 0, projectCount > 1 else { return 0 }

        let widthProgress = min(max((viewportWidth - 760) / 240, 0), 1)
        // 行末的「添加工作区」虚线胶囊和项目胶囊同宽同间距，一起占用滚动区预算。
        let collapsedWidth = CGFloat(projectCount + 1) * chipHeight
            + CGFloat(projectCount) * chipSpacing
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

/// 触觉只跟随用户确实完成的项目选中变化；恢复状态和重复选择保持安静。
enum WorkspaceSelectionHapticPolicy {
    static func shouldFire(
        previousID: String?,
        selectedID: String?,
        isExplicitSelection: Bool,
        isUserPaging: Bool,
        isSuppressed: Bool
    ) -> Bool {
        guard let previousID, let selectedID, previousID != selectedID, !isSuppressed else {
            return false
        }
        return isExplicitSelection || isUserPaging
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
