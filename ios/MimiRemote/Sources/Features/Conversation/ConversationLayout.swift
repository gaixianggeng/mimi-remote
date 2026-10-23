import SwiftUI

struct ConversationLayout: Equatable {
    let horizontalInset: CGFloat
    let composerHorizontalInset: CGFloat
    let messageSideSpacer: CGFloat
    let composerAvailableWidth: CGFloat
    let composerMaxWidth: CGFloat
    let composerTopPadding: CGFloat
    let composerBottomPadding: CGFloat
    let userBubbleMaxWidth: CGFloat
    let assistantBubbleMaxWidth: CGFloat
    let systemMaxWidth: CGFloat
    let runtimeCardMaxWidth: CGFloat
    let emptyStateMaxWidth: CGFloat

    var messageRowInsets: EdgeInsets {
        EdgeInsets(top: 10, leading: horizontalInset, bottom: 10, trailing: horizontalInset)
    }

    /// 展开后的过程步骤连成一张紧凑列表：不叠加消息级间距，行距由步骤行自身决定。
    var processStepRowInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset)
    }

    /// 紧凑指标 = 输入框档位不是宽档（#835）。只看宽度，不再看 size class；
    /// 宽度未知时 compact size class 视作窄档。
    static func usesCompactComposerMetrics(
        availableWidth: CGFloat?,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        ComposerLayoutTier.resolve(
            width: availableWidth,
            previousBase: nil,
            dynamicTypeSize: .large,
            fallsBackToNarrow: horizontalSizeClass == .compact
        ) != .wide
    }

    static func compactComposerShowsFastModeIndicator(
        usesCompactMetrics: Bool,
        isFastModeSelected: Bool
    ) -> Bool {
        isFastModeSelected && !usesCompactMetrics
    }

    static func compactComposerModelTitleMaxWidth(availableWidth: CGFloat?) -> CGFloat {
        guard let availableWidth else { return 36 }
        if availableWidth < 300 { return 36 }
        if availableWidth < 340 { return 48 }
        if availableWidth < 360 { return 64 }
        // 标准 iPhone 宽度优先展示「5.6 Sol High」短标签；固定上限继续约束
        // 服务端可能返回的冗长标题，避免模型控件挤压语音和发送主行动。
        return 88
    }

    init(
        containerWidth: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass?,
        safeAreaInsets: EdgeInsets = EdgeInsets()
    ) {
        // NavigationSplitView 的 detail 在 iPad 横屏下可能仍收到整窗宽度提案，侧栏宽度则体现在
        // leading safe area 中。所有会话轨道必须按真实可见宽度计算，否则 composer 会伸到屏幕外。
        let visibleContainerWidth = max(
            0,
            containerWidth - safeAreaInsets.leading - safeAreaInsets.trailing
        )
        let isCompactWidth = horizontalSizeClass == .compact || visibleContainerWidth < 560
        let isWideCompact = horizontalSizeClass == .compact && visibleContainerWidth >= 600
        let isVeryCompactWidth = visibleContainerWidth < 360
        let isTightPadWidth = visibleContainerWidth < 820

        // 与会话库 20pt 的卡片轨道接近，同时给 320/344pt 极窄屏保留必要内容宽度。
        horizontalInset = isCompactWidth ? (isVeryCompactWidth ? 12 : 16) : (isTightPadWidth ? 16 : 24)
        // iPhone 的 Composer 是底部功能层，不应被正文轨道的页边距继续收窄。
        // 只放宽输入卡，不改变消息行长和左右身份感。
        composerHorizontalInset = isCompactWidth ? (isVeryCompactWidth ? 6 : 8) : horizontalInset
        messageSideSpacer = isCompactWidth ? 12 : (isTightPadWidth ? 24 : 56)
        composerAvailableWidth = max(240, visibleContainerWidth - composerHorizontalInset * 2)
        // iPhone 横屏仍然是 compact size class，但不应该把输入卡拉满整条长边。
        // 居中的宽度上限同时缩短正文行长，并给系统返回手势留出清晰的边缘空间。
        composerMaxWidth = isWideCompact
            ? min(680, composerAvailableWidth)
            : (isCompactWidth ? .infinity : min(940, max(360, composerAvailableWidth)))
        composerTopPadding = isCompactWidth ? 10 : 12
        // safeAreaInset 已经负责系统手势区；这里只保留卡片与安全区之间的轻量呼吸感，
        // 避免两层底距叠加后让输入卡看起来悬得过高。
        composerBottomPadding = isCompactWidth ? 0 : 8

        // 气泡宽度按实际容器收缩，保留左右身份感，同时避免 iPhone/mini 竖屏横向溢出。
        let rowAvailableWidth = max(240, visibleContainerWidth - horizontalInset * 2 - messageSideSpacer)
        userBubbleMaxWidth = min(isCompactWidth ? 420 : 560, rowAvailableWidth)
        let assistantWidthCap: CGFloat = isWideCompact ? 660 : (isCompactWidth ? 520 : (isTightPadWidth ? 700 : 760))
        assistantBubbleMaxWidth = min(assistantWidthCap, rowAvailableWidth)
        systemMaxWidth = min(520, max(240, visibleContainerWidth - horizontalInset * 2))
        runtimeCardMaxWidth = min(560, max(260, visibleContainerWidth - horizontalInset * 2))
        emptyStateMaxWidth = min(420, max(260, visibleContainerWidth - horizontalInset * 2))
    }
}
