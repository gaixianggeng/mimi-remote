import SwiftUI

// 工作台壳层的类型擦除边界集中在这里。与 ComposerErasedControls.swift 一样，
// 这是对真机主线程栈溢出的边界修复，不用于普通组件的类型兼容。
//
// 真机主线程栈只有约 1 MB（模拟器 8 MB）。iPad mini 实测（#865）：
// - 构建 `some View` 的函数，栈帧大致是「中间值个数 × 值大小」，Release 也几乎不缩小；
// - 壳层 GeometryReader 的内容把三种布局放在同一个 `_ConditionalContent` 里，
//   存储按最大分支分配（浮动侧栏约 11 KB），竖屏紧凑布局也要为它付栈；
// - 宽屏打开会话时，GeometryReader 闭包 → 布局分支 → detail → sessionDetail → toolbar
//   都嵌套在同一条调用链上，擦除前峰值 754 KB，擦除后 229 KB。
// 每个布局分支和会话详情各自进入一个不可内联的栈帧，父层只保留 AnyView。
// 新增布局或给这些分支加大块内容时，`WorkbenchShellMetadataBudgetTests` 会在类型变大或变深时失败。
extension UnifiedWorkbenchShell {
    // MARK: 布局分支

    @inline(never)
    func compactLayoutBox(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        bottomSafeAreaInset: CGFloat
    ) -> AnyView {
        AnyView(compactLayout(layout: layout, tokens: tokens, bottomSafeAreaInset: bottomSafeAreaInset))
    }

    @inline(never)
    func floatingLayoutBox(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        bottomSafeAreaInset: CGFloat
    ) -> AnyView {
        AnyView(floatingLayout(layout: layout, tokens: tokens, bottomSafeAreaInset: bottomSafeAreaInset))
    }

    @inline(never)
    func splitLayoutBox(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        bottomSafeAreaInset: CGFloat
    ) -> AnyView {
        AnyView(splitLayout(layout: layout, tokens: tokens, bottomSafeAreaInset: bottomSafeAreaInset))
    }

    // MARK: 会话详情
    // 宽屏 detail 列与紧凑导航的 push 目标共用这一个边界；会话详情自带整套顶栏 toolbar，
    // 不擦除时 detail 和 compactDestination 的值都约 8 KB。

    @inline(never)
    func sessionDetailBox(
        destinationSessionID: SessionID? = nil,
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        shouldHideTabBar: Bool = false
    ) -> AnyView {
        AnyView(
            sessionDetail(
                destinationSessionID: destinationSessionID,
                layout: layout,
                tokens: tokens,
                shouldHideTabBar: shouldHideTabBar
            )
        )
    }
}
