import SwiftUI

/// 输入框跨尺寸布局的唯一档位（#835，规则见 `docs/composer-layout-rules.md`）。
///
/// 档位只由输入卡的实际宽度决定，不看设备类型和 size class：iPhone、iPad 分屏、
/// 台前调度小窗，同宽同样。设备类型只保留给相机、收起输入框这类硬件相关能力。
enum ComposerLayoutTier: Int, Comparable, CaseIterable {
    /// 所有 iPhone 竖屏、iPad 1/3 分屏与侧拉：无上下文行，权限进「选项」，Skill 进「+」。
    case narrow
    /// iPhone 横屏、大 iPad 1/2 分屏：有上下文行，工具栏纯图标，模型带名称。
    case medium
    /// iPad 全屏、iPad mini 竖屏与 2/3 分屏：投递方式带文字、模型显示完整名称。
    case wide

    static let mediumMinimumWidth: CGFloat = 480
    static let wideMinimumWidth: CGFloat = 700
    /// 跨档需要越过阈值这么多才生效，拖动分屏线或台前调度窗口时不会来回跳。
    static let hysteresis: CGFloat = 16

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 只按宽度、不带迟滞的档位。
    static func tier(forWidth width: CGFloat) -> Self {
        if width >= wideMinimumWidth {
            return .wide
        }
        return width >= mediumMinimumWidth ? .medium : .narrow
    }

    /// 带迟滞的宽度档位：相对上一次的档位，升档要多出 16pt，降档要再少 16pt。
    static func baseTier(width: CGFloat, previous: Self?) -> Self {
        let raw = tier(forWidth: width)
        guard let previous, raw != previous else {
            return raw
        }
        let shifted = raw > previous
            ? tier(forWidth: width - hysteresis)
            : tier(forWidth: width + hysteresis)
        return shifted == previous ? previous : shifted
    }

    /// 最终档位：辅助功能大字号（AX1 及以上）时降一档，宽按中、中按窄处理。
    /// 宽度未知时（预览或未接入布局的宿主），compact 视作窄档，其余视作宽档。
    static func resolve(
        width: CGFloat?,
        previousBase: Self?,
        dynamicTypeSize: DynamicTypeSize,
        fallsBackToNarrow: Bool
    ) -> Self {
        let base = width.map { baseTier(width: $0, previous: previousBase) }
            ?? (fallsBackToNarrow ? .narrow : .wide)
        return dynamicTypeSize.isAccessibilitySize ? base.lowered : base
    }

    var lowered: Self {
        Self(rawValue: rawValue - 1) ?? .narrow
    }
}

extension ConversationLayout {
    /// 窄档模型名最多 88pt，宽度不足 340 时只留图标；中、宽档始终显示名称。
    static let narrowComposerModelTitleMinimumWidth: CGFloat = 340
    /// 窄档上下文圆环需要的最小宽度；更窄时收进「选项」。
    static let narrowComposerContextRingMinimumWidth: CGFloat = 350

    static func composerShowsModelTitle(tier: ComposerLayoutTier, availableWidth: CGFloat?) -> Bool {
        guard tier == .narrow else {
            return true
        }
        guard let availableWidth else {
            return false
        }
        return availableWidth >= narrowComposerModelTitleMinimumWidth
    }

    /// 运行中的投递方式：宽档图标加文字、中档只留图标，窄档收进「选项」。
    static func composerShowsInlineDeliveryControl(tier: ComposerLayoutTier, canChooseDelivery: Bool) -> Bool {
        canChooseDelivery && tier != .narrow
    }

    static func composerShowsContextRing(tier: ComposerLayoutTier, availableWidth: CGFloat?) -> Bool {
        guard tier == .narrow else {
            return true
        }
        return (availableWidth ?? 0) >= narrowComposerContextRingMinimumWidth
    }

    /// 中档工具栏除模型名以外的固定宽度（#841 评审）：卡片左右内边距 12×2、「+」44、
    /// 模型按钮图标与内边距 47、加号与模型间距 6、首尾分组间距 10×3、上下文圆环 44 + 2、
    /// 选项 44 + 6 + 语音 44、发送 44。运行中平铺投递方式再加 44 + 6。
    static let mediumComposerFixedToolbarWidth: CGFloat = 24 + 44 + 47 + 6 + 30 + 46 + 94 + 44
    static let mediumComposerInlineDeliveryWidth: CGFloat = 50

    /// 模型名的最大宽度：窄档按宽度分级；中档按剩余宽度算，上限 160、下限 48；宽档 220。
    static func composerModelTitleMaxWidth(
        tier: ComposerLayoutTier,
        availableWidth: CGFloat?,
        showsInlineDelivery: Bool = false
    ) -> CGFloat {
        switch tier {
        case .narrow:
            return compactComposerModelTitleMaxWidth(availableWidth: availableWidth)
        case .medium:
            guard let availableWidth else { return 120 }
            let fixed = mediumComposerFixedToolbarWidth + (showsInlineDelivery ? mediumComposerInlineDeliveryWidth : 0)
            return min(160, max(48, (availableWidth - fixed).rounded(.down)))
        case .wide:
            return 220
        }
    }
}
