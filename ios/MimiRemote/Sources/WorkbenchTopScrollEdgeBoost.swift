import SwiftUI

/// 顶部加深层的强度曲线：把"正文钻进导航控制层后方多少"换算成 0…1 的强度。
///
/// 纯函数，不带可用性标注，便于直接做单元测试。
enum WorkbenchTopScrollEdgeBoostRamp {
    /// 从正文刚碰到控制层下沿到加深层满强度的滚动距离。太短会在起滚瞬间闪出一条亮边，
    /// 太长则正文已经明显压在标题上却还没被压住。
    static let rampDistance: CGFloat = 24

    /// 强度量化档位。`onScrollGeometryChange` 只在值变化时回调，量化后整条 ramp 最多
    /// 触发 8 次，越过 ramp 之后强度恒为 1、滚动全程不再产生状态更新。不量化就会每帧
    /// 写一次 @State，长会话时间线要为一层顶部材质付出整屏重估。
    static let intensitySteps: Double = 8

    /// `underlap` = `contentOffset.y + contentInsets.top`，为正表示正文已经进入控制层后方；
    /// 贴顶或列表不足一屏时为 0。用 smoothstep 淡入，起点斜率为 0，不会线性起跳。
    static func intensity(forUnderlap underlap: CGFloat) -> Double {
        let clamped: CGFloat = min(rampDistance, max(0, underlap))
        let progress: Double = Double(clamped / rampDistance)
        let eased: Double = progress * progress * (3.0 - 2.0 * progress)
        return (eased * intensitySteps).rounded() / intensitySteps
    }
}

/// 强度和几何一起走一次回调，避免两者分两拍到达、闪出一帧错位的带子。
private struct WorkbenchTopScrollEdgeSample: Equatable {
    var intensity: Double = 0
    /// 状态栏 + 导航控制层。取自滚动几何的 `contentInsets.top`，也就是列表真正让出的那段。
    var topInset: CGFloat = 0
}

/// 系统 `.soft` scroll edge 之上的加深层。
///
/// 系统边缘提供的正是要的整片玻璃质感，但强度固定且偏弱：正文滚到标题后方时仍能逐字辨读，
/// 和标题、返回与更多按钮叠字。强度不可调，而且**一旦给 navigationBar 设了可见的
/// `toolbarBackground`，系统就不再做这层渐进模糊**，只会铺一块平底板——结果是「挡住了但
/// 后面还看得清」，比原本更差。
///
/// 所以底板保持隐藏，改在滚动内容之上再叠一层 `.ultraThinMaterial`：它是二次采样，真正加深
/// 模糊而不是把内容压淡；用 smoothstep mask 收边，下沿精确落到全透明，不会出现横贯全宽的
/// 硬边或明度断层。
///
/// 强度随正文上滚淡入，静止贴顶时为 0：那时这一层盖住的是一整块纯色画布，玻璃对纯色不产生
/// 任何虚化，只会把顶部这一条提亮，没有可读性收益。
@available(iOS 26.0, *)
private struct WorkbenchTopScrollEdgeBoost: View {
    /// 0 = 完全不绘制，1 = 满强度。
    let intensity: Double
    let topInset: CGFloat

    /// 导航控制层以下继续渐隐的距离。太短会把收边挤成一条可见的线，太长会连正常正文一起压掉
    /// ——实机上 56pt 已经把标题下方一整行正文洗白，读起来像被挡住。
    private let fadeTail: CGFloat = 24

    /// 满强度时 mask 的最大 alpha。浅色下这层自带提亮，满档会把标题区刷成一块白板；
    /// 留两成让系统 soft edge 的玻璃透出来，正文仍糊到不可辨读。
    private static let peakAlpha: Double = 0.5

    /// 收边采样点数。9 个点足以让 smoothstep 在收边距离内看不出分段。
    private static let falloffSampleCount: Int = 9

    /// 收边曲线。等距线性渐变在"满强度结束、斜坡开始"那一点存在斜率突变，人眼会把这种
    /// 一阶不连续读成一条横线（Mach band）。这里用 smoothstep `t²(3−2t)` 采样：两端斜率
    /// 都为 0，整条收边不存在任何可定位的边界。
    ///
    /// 每一步都写死类型并用普通循环展开：交给类型推导去解 `stops:` 里的 map + 混合字面量
    /// 算术，Swift 类型检查器会在较慢的机器上超时。
    ///
    /// 上滚淡入的强度也乘在这条 alpha 上，而不是给 Material 加 `.opacity`：两者相乘只是把
    /// 同一条曲线整体压低，不引入第二次合成。
    private static func falloffStops(holdStop: CGFloat, intensity: Double) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = []
        stops.reserveCapacity(falloffSampleCount)
        let lastIndex: CGFloat = CGFloat(falloffSampleCount - 1)
        for index in 0..<falloffSampleCount {
            let progress: CGFloat = CGFloat(index) / lastIndex
            let eased: CGFloat = progress * progress * (3.0 - 2.0 * progress)
            let falloff: Double = Double(1.0 - eased)
            let alpha: Double = falloff * intensity * peakAlpha
            let location: CGFloat = holdStop + (1.0 - holdStop) * progress
            stops.append(Gradient.Stop(color: Color.black.opacity(alpha), location: location))
        }
        return stops
    }

    var body: some View {
        // 强度为 0 时整层不进入视图树，不为一层看不见的材质付出合成开销。
        // 几何还没测到时同样不画，避免用 0 inset 画出一条位置错误的短带。
        if intensity > 0, topInset > 0 {
            boostLayer
        }
    }

    private var boostLayer: some View {
        let height: CGFloat = max(topInset + fadeTail, 1)
        // 导航控制层范围内保持满强度，只在其下沿之后开始收边。
        let holdStop: CGFloat = min(0.9, max(0.05, (topInset - 4) / height))
        return Rectangle()
            // 这里是全 App 唯一不走 `WorkbenchMaterial.surface` 的地方，而且是有意的：
            // 它不是一块表面，是叠在系统 soft scroll edge 之上的**第二次采样**。
            .fill(.ultraThinMaterial)
            .mask(
                LinearGradient(
                    stops: Self.falloffStops(holdStop: holdStop, intensity: intensity),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 把滚动几何接到顶部加深层上。
///
/// 状态刻意留在这个 ViewModifier 内部而不是上抬到会话时间线：`content` 是已经构建好的
/// 不透明视图，强度变化只会重估这一层 overlay，不会让 List 的 body 跟着失效。
@available(iOS 26.0, *)
struct WorkbenchTopScrollEdgeBoostModifier: ViewModifier {
    @State private var sample = WorkbenchTopScrollEdgeSample()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: WorkbenchTopScrollEdgeSample.self) { geometry in
                let underlap: CGFloat = geometry.contentOffset.y + geometry.contentInsets.top
                return WorkbenchTopScrollEdgeSample(
                    intensity: WorkbenchTopScrollEdgeBoostRamp.intensity(forUnderlap: underlap),
                    // 取整到 pt：旋转与导航栏高度变化才需要重画，亚像素抖动不必更新状态。
                    topInset: geometry.contentInsets.top.rounded()
                )
            } action: { _, newSample in
                sample = newSample
            }
            .overlay(alignment: .top) {
                WorkbenchTopScrollEdgeBoost(
                    intensity: sample.intensity,
                    topInset: sample.topInset
                )
            }
    }
}
