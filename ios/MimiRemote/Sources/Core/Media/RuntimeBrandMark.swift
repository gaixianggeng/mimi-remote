import SwiftUI

/// Runtime 的品牌标记。资源一律保持权利人发布的原件，不裁切、不改绘、不改色；
/// 三个标记的画布留白不同，差异只在显示侧按实测比例抹平。
enum RuntimeBrandMark: Equatable {
    case openAI
    case claude
    case deepSeek

    var assetName: String {
        switch self {
        case .openAI:
            return "OpenAIMonoblossom"
        case .claude:
            return "Claude"
        case .deepSeek:
            // 深度求索官方矢量标记（api-docs.deepseek.com/img/favicon.svg 原件）。
            // 单条 path、自带品牌色 #4D6BFE，无底板，无外部引用。
            return "DeepSeek"
        }
    }

    /// 方形占位的放大系数：图标按 `size / inkRatio` 的占位渲染，用于让三个标记读起来一样大。
    ///
    /// OpenAI 官方 monoblossom 自带品牌规范要求的 clear space：721 画布里墨迹只有 67.2%
    /// （按 1442px 渲染实测 969/1442），不放大就会明显小一圈。这里补偿的是画布留白，
    /// 放大后墨迹正好占满 `size`。
    ///
    /// Claude 的 SVG 满幅 24×24，墨迹已经占满 `size`，不补偿。
    ///
    /// DeepSeek 的 viewBox 63.12×46.40 同样是墨迹紧致包围盒，没有留白可补偿；但它是横长形，
    /// 按宽度顶格放进方形占位后高度只剩 73.5%，与满幅方形标记并排时矮一截。
    /// 所以这里改按**高度**对齐，让墨迹高度等于 `size`，理由见下方 case。
    ///
    /// 同一个横长标记有三种可选口径，取哪个是产品观感决定，不是对错：
    /// 线性（只补留白，宽度对齐、高度 73.5%）、面积（墨迹面积等量、高度 85.7%）、
    /// 高度（高度等高、面积多 36%）。这里取高度：一行标记里眼睛比的是纵向高度。
    var inkRatio: CGFloat {
        switch self {
        case .openAI:
            return 969.0 / 1442.0
        case .claude:
            return 1
        case .deepSeek:
            // 官方 viewBox 就是墨迹紧致包围盒（两轴实测 100% 占满），没有留白要补偿。
            // 宽高比 63.1196/46.4033 ≈ 1.360，塞进方形占位时按宽度顶格、保持原生比例不拉伸，
            // 于是高度只到 1/1.360 ≈ 73.5%，和满幅方形标记并排时矮一截。
            // 按高度对齐：inkRatio = 46.4033/63.1196 ≈ 0.735，占位放大 1.360 倍，
            // 墨迹变成约 1.360×size 宽、1.000×size 高——高度与 Claude 的满幅方形等高，
            // 且纵向不再溢出布局盒；代价是横向每侧超出 `size` 布局盒约 18%（20pt 占位下 3.6pt），
            // 面积比满幅方形标记大 36%，因此比同排略重。
            return 46.4033 / 63.1196
        }
    }
}

/// 按可见墨迹对齐的品牌标记。外层固定布局盒保证行内间距和对齐与普通图标一致，
/// 内层按墨迹占比放大，三个品牌因此读起来同样大。OpenAI 溢出的只是画布留白，
/// 既不可见也不会影响相邻内容；DeepSeek 按高度对齐后墨迹在横向会明显超出布局盒
/// （每侧约 18%），吃掉一部分相邻间距——最紧的一处是会话行徽标（10pt 占位 + 3pt 间距），
/// 仍留约 1.2pt，且各处都没有 `.clipped()`，不裁切也不会盖住相邻文字。
/// 资源是矢量，放大不裁切、不损失清晰度。
struct RuntimeBrandMarkIcon: View {
    let mark: RuntimeBrandMark
    let size: CGFloat

    var body: some View {
        let inkSize = size / mark.inkRatio

        Image(mark.assetName)
            .resizable()
            // 标记带各自的品牌配色（Claude 的橙、OpenAI 的黑白双版、DeepSeek 的蓝），
            // 模板着色会把它们抹平成同一个色块。
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: inkSize, height: inkSize)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
