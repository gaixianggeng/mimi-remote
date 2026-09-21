import SwiftUI

/// 工作区顶部胶囊的尺寸与宽屏信息密度策略。
/// 单独放在布局组件中，避免根页面同时承担视觉策略与会话编排职责。
enum WorkspaceStripLayout {
    /// 胶囊行的兜底页面内边距。
    ///
    /// 真实使用的内边距由 `WorkspaceRootView.stripContentPadding` 按当前页面算出：
    /// 页面内边距（紧凑 Tab 栏时更窄）加上会话行自身的横向内边距。胶囊行与下方列表
    /// 必须共用同一条内容列，否则宽屏下第一个胶囊比列表的状态圈更靠左。
    /// 这个常量只在没有列表上下文的计算里兜底。
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
    /// 未选中胶囊开始显示名称所需的最小滚动区宽度。
    ///
    /// 这个数是**实测**出来的，不是推导的。胶囊滚动区的真实宽度（容器收窄到
    /// `maxContentWidth` 之后，再扣掉行内 Runtime 筛选器和分隔线）：
    ///
    /// | 场景 | 滚动区宽 |
    /// | --- | --- |
    /// | iPad 13 寸横屏 + 侧栏展开（容器 920） | 689.5pt |
    /// | iPad mini 竖屏（容器 744） | 505.5pt |
    /// | iPhone 竖屏（容器 393，筛选器不并入） | 345pt |
    ///
    /// 阈值取在横屏与竖屏之间：横屏给出完整名称，竖屏干脆退回纯头像。
    /// 这里曾经用 `(viewportWidth - 760) / 240` 做连续映射，那个 760...1000 的窗口
    /// 是按"胶囊行占满整列宽"标定的；容器收窄到 920 之后它永远不满足，
    /// 名称会彻底消失——这正是本常量必须实测、不能沿用的原因。
    ///
    /// 改动胶囊行的宽度策略、`maxContentWidth`、Runtime 筛选器尺寸或行内控件组成后，
    /// 必须重新实测这三个数并更新本表，否则名称要么永远不显示，要么在窄屏被截断。
    static let nameDisclosureMinimumWidth: CGFloat = 640

    static func minimumContentWidth(
        viewportWidth: CGFloat,
        contentPadding: CGFloat = WorkspaceStripLayout.horizontalPadding
    ) -> CGFloat {
        max(0, viewportWidth - contentPadding * 2)
    }

    /// 统一决定 Runtime 是否进入胶囊行，避免 Runtime 布局和行内新建入口分别判断。
    /// `viewportWidth` 是应用了内边距的外层容器宽，不是设备屏宽。
    /// `contentPadding` 是这一行实际使用的左右内边距——它和下方会话列表的内容列
    /// 由同一个表达式给出（见 `WorkspaceRootView.stripContentPadding`），必须传进来，
    /// 否则这里的可用宽度会比真实值偏大，阈值判断跟着失真。
    static func usesInlineRuntimePicker(
        viewportWidth: CGFloat,
        showsHostSwitcherInStrip: Bool,
        hasBottomTabBar: Bool,
        contentPadding: CGFloat = WorkspaceStripLayout.horizontalPadding
    ) -> Bool {
        // 底部 Tab 栏时新建按钮必须留在筛选行，横屏 iPhone 也不能切到 inline 布局。
        guard !hasBottomTabBar else { return false }

        let hostSwitcherBudget = showsHostSwitcherInStrip
            ? WorkbenchChromeIconMetrics.minimumHitTarget + chipSpacing
            : 0
        let availableContentWidth = minimumContentWidth(
            viewportWidth: viewportWidth,
            contentPadding: contentPadding
        )
        return availableContentWidth - hostSwitcherBudget >= inlineRuntimePickerMinimumWidth
    }

    /// 使用胶囊滚动区的真实宽度，而不是设备宽度。浮动侧栏会持续改变详情区宽度，
    /// 因此这里同时受宽屏阈值和项目数量预算约束：空间不足时仍退回纯头像。
    ///
    /// 返回值是**二值**的：要么 1（给足 `restingNameWidth`），要么 0（完全不给）。
    ///
    /// 这里曾经返回 0...1 的连续披露进度，并按它插值名称宽度。连续插值在中间态
    /// 只会给名称留出一两个字符的宽度，于是胶囊上出现孤零零的字母残片——
    /// 用户读到的不是「空间不够」，是「这个控件坏了」。一个字符的工作区名没有任何
    /// 辨识价值，不如干净地退回纯头像。
    static func restingNameDisclosure(
        viewportWidth: CGFloat,
        projectCount: Int
    ) -> CGFloat {
        guard viewportWidth > 0, projectCount > 1 else { return 0 }

        // 行末的「添加工作区」虚线胶囊和项目胶囊同宽同间距，一起占用滚动区预算。
        let collapsedWidth = CGFloat(projectCount + 1) * chipHeight
            + CGFloat(projectCount) * chipSpacing
        let selectedNameAllowance: CGFloat = 112
        let remainingWidth = max(
            0,
            viewportWidth - collapsedWidth - selectedNameAllowance
        )
        let restingBudget = CGFloat(projectCount - 1) * restingNameWidth

        // 两个条件必须同时满足：滚动区本身够宽，并且扣掉固定占用后，
        // 每个未选中胶囊都拿得到完整的一份名称宽度。任一不满足就退回纯头像。
        guard viewportWidth >= nameDisclosureMinimumWidth,
              remainingWidth >= restingBudget else {
            return 0
        }
        return 1
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
