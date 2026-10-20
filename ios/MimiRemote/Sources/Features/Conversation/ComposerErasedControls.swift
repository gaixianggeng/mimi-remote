import SwiftUI

// 输入框的类型擦除边界集中在这里，是对真机泛型元数据栈溢出的边界修复，
// 不用于普通组件的类型兼容。
//
// 真机主线程栈只有约 1 MB，模拟器是 8 MB，所以下面两项只会在真机上溢出（#852、#869）：
// - 构建 `some View` 的函数，栈帧大致是修饰链上每个中间值大小之和，Release 也几乎不缩小。
//   `ComposerView.body` 原先一条链挂了四十多个修饰符，每个中间值都包着整块输入区，
//   iPad mini 实测 body 单帧 Debug 412 KB、Release 405 KB，约是 `ComposerView.Body` 值大小的 35 倍。
//   分段擦除后，打开会话时输入框路径的栈峰值从 593 KB 降到 205 KB；
// - 组合类型的嵌套层数：解析泛型元数据时逐层递归，每层约 3 KB。
// 每个复杂控件、输入卡和 body 修饰链的每一段都单独进入一个不可内联的栈帧，返回后父层只保留小型 AnyView。
// 新增控件或修饰符也先在这里擦除，`ComposerMetadataBudgetTests` 会在组合类型变深或变大时失败。
extension ComposerView {
    // MARK: body 修饰链
    // 各段依次把上一段的 AnyView 包进自己的修饰符；body 只在最后一段上挂生命周期修饰符。

    @inline(never)
    func presentedContentBox(tokens: ThemeTokens) -> AnyView {
        AnyView(composerPresentedContent(tokens: tokens))
    }

    @inline(never)
    func composerPresentationsBox(_ content: AnyView) -> AnyView {
        AnyView(composerPresentations(content))
    }

    @inline(never)
    func composerScopeObserversBox(_ content: AnyView) -> AnyView {
        AnyView(composerScopeObservers(content))
    }

    @inline(never)
    func composerDraftObserversBox(_ content: AnyView) -> AnyView {
        AnyView(composerDraftObservers(content))
    }

    // MARK: 输入卡

    @inline(never)
    func phoneComposerCardBox(tokens: ThemeTokens) -> AnyView {
        AnyView(phoneComposerCard(tokens: tokens))
    }

    @inline(never)
    func collapsedIPadComposerCardBox(tokens: ThemeTokens) -> AnyView {
        AnyView(collapsedIPadComposerCard(tokens: tokens))
    }

    @inline(never)
    func composerCardBox(tokens: ThemeTokens) -> AnyView {
        AnyView(composerCard(tokens: tokens))
    }

    // MARK: 工具栏
    // 宽档与紧凑档两条分支都在 `primaryComposerToolbar` 的组合类型里，
    // 所以两边都只经下面的方法放控件。

    @inline(never)
    func compactLeadingControlsBox(showsModelTitle: Bool) -> AnyView {
        // iPhone 运行态把投递方式收进设置菜单，避免第六个控件挤破 320–390pt 工具栏。
        // iPad 保留原有平铺入口。
        let deliveryControl = compactToolbarShowsInlineDeliveryControl
            ? deliveryControlBox()
            : nil
        return AnyView(
            CompactComposerLeadingControlsShell(
                addControl: addContentControlBox(),
                modelControl: modelControlBox(showsTitle: showsModelTitle),
                deliveryControl: deliveryControl
            )
        )
    }

    @inline(never)
    func compactToolControlsBox() -> AnyView {
        return AnyView(
            HStack(spacing: 2) {
                contextWindowControlBox()
                CompactComposerToolControlsShell(
                    optionsControl: optionsControlBox(),
                    microphoneControl: microphoneControlBox()
                )
            }
        )
    }

    @inline(never)
    func addContentControlBox() -> AnyView {
        AnyView(addContentButton)
    }

    @inline(never)
    func modelControlBox(showsTitle: Bool) -> AnyView {
        guard composerTurnSettingsPolicy.allowsTurnSettingsEditing else {
            return AnyView(unavailableModelControl)
        }
        return AnyView(modelPickerControl(showsTitle: showsTitle, usesCompactTitle: usesNarrowComposerLayout))
    }

    @inline(never)
    func deliveryControlBox() -> AnyView {
        AnyView(followUpDeliveryMenu)
    }

    @inline(never)
    func optionsControlBox() -> AnyView {
        AnyView(composerOptionsMenu)
    }

    @inline(never)
    func microphoneControlBox() -> AnyView {
        AnyView(voiceMicControl)
    }

    @inline(never)
    func submitControlBox() -> AnyView {
        AnyView(sendButton(showLabels: false))
    }

    // MARK: 上下文剩余

    @inline(never)
    func contextWindowControlBox() -> AnyView {
        AnyView(contextWindowRingControl)
    }

    @inline(never)
    func contextWindowNoticeBox() -> AnyView {
        AnyView(contextWindowNotice)
    }

    @inline(never)
    func contextWindowOptionsMenuFallbackBox() -> AnyView {
        AnyView(contextWindowOptionsMenuFallback)
    }
}
