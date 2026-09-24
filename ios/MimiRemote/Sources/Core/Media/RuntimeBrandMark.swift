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
    /// DeepSeek 的 viewBox 63.12×46.40 是横长的紧致包围盒。按高度对齐会让可见宽度
    /// 超出占位约 36%，在菜单中显得偏大；按面积对齐可让三个标记的视觉重量更接近。
    var inkRatio: CGFloat {
        switch self {
        case .openAI:
            return 969.0 / 1442.0
        case .claude:
            return 1
        case .deepSeek:
            // 按面积对齐后，20pt 占位中的可见尺寸约为 23.3×17.1pt；
            // 比原来的 27.2×20pt 更轻，同时保留品牌标记的原始宽高比。
            return (46.4033 / 63.1196).squareRoot()
        }
    }
}

/// 按可见墨迹对齐的品牌标记。外层固定布局盒保证行内间距和对齐与普通图标一致，
/// 内层按墨迹占比放大。OpenAI 溢出的只是画布留白，不影响相邻内容；
/// DeepSeek 的可见宽度会超出布局盒约 17%，但各处都没有裁切。
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
