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
    /// 按宽度顶格放进方形占位后高度只剩 73.5%，可见面积比前两者少四分之一，读起来仍然偏小。
    /// 所以这里改按**面积**对齐，让墨迹面积回到前两者的量级，理由见下方 case。
    ///
    /// 三个标记最终都落在同一条不变量上：可见墨迹面积 = `size²`（OpenAI 的墨迹本身近方形，
    /// 补齐 clear space 后线性上也正好是 `size`）。
    var inkRatio: CGFloat {
        switch self {
        case .openAI:
            return 969.0 / 1442.0
        case .claude:
            return 1
        case .deepSeek:
            // 官方 viewBox 就是墨迹紧致包围盒（两轴实测 100% 占满），没有留白要补偿。
            // 宽高比 63.1196/46.4033 ≈ 1.360，塞进方形占位时按宽度顶格、保持原生比例不拉伸，
            // 于是高度只到 1/1.360 ≈ 73.5%，墨迹面积随之只剩满幅方形标记的 73.5%。
            // 按面积对齐需要把占位放大约 1.166 倍，即 inkRatio = √(46.4033/63.1196) ≈ 0.857：
            // 墨迹变成约 1.166×size 宽、0.857×size 高，面积回到 size²，与 Claude 的满幅方形等量。
            // 代价是墨迹在宽度上会超出外层 `size` 布局盒（每侧约 8%），吃掉一点相邻间距。
            return (46.4033 / 63.1196).squareRoot()
        }
    }
}

/// 按可见墨迹对齐的品牌标记。外层固定布局盒保证行内间距和对齐与普通图标一致，
/// 内层按墨迹占比放大，三个品牌因此读起来同样大。OpenAI 溢出的只是画布留白，
/// 既不可见也不会影响相邻内容；DeepSeek 按面积对齐后墨迹会略微超出布局盒（每侧约 8%），
/// 只吃掉一点相邻间距。资源是矢量，放大不裁切、不损失清晰度。
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
