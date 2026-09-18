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

    /// 可见墨迹占画布的比例，用于让三个标记看起来一样大。
    ///
    /// OpenAI 官方 monoblossom 自带品牌规范要求的 clear space：721 画布里墨迹只有 67.2%
    /// （按 1442px 渲染实测 969/1442）。Claude 和 DeepSeek 的 SVG 都是满幅画布，比例记 1。
    /// 等 frame 渲染时 OpenAI 会明显小一圈，所以这里补偿的是留白，不是标记本身。
    var inkRatio: CGFloat {
        switch self {
        case .openAI:
            return 969.0 / 1442.0
        case .claude:
            return 1
        case .deepSeek:
            // 官方 viewBox 就是 63.12×46.40 的紧致包围盒，没有留白要补偿。
            // 标记本身宽大于高，缩放进方形占位时按宽度对齐，保持原生比例不拉伸。
            return 1
        }
    }
}

/// 按可见墨迹对齐的品牌标记。外层固定布局盒保证行内间距和对齐与普通图标一致，
/// 内层按墨迹占比放大，三个品牌因此读起来同样大；溢出的部分只是画布留白，
/// 既不可见也不会盖住相邻内容。资源是矢量，放大不损失清晰度。
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
