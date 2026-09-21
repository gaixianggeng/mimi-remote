import SwiftUI

/// 首次连接一台电脑时的过渡界面。
///
/// 冷启动和切换电脑都要先建隧道、再等 agentd 网关的上游就绪，这个窗口内的失败是过程
/// 而不是结论。整屏只保留**一处**"正在进行"的表达：居中的水波纹。顶栏设备入口在这
/// 段时间不再叠第二枚转圈（`HostSwitcherMenu(suppressesProgressBadge:)`），否则同一件
/// 事被说两遍，用户读到的是"两个地方都在转"，而不是"正在连接这台电脑"。
///
/// 这里也不再画内容骨架。骨架预告的是版面，可一旦它和一枚转圈、一枚顶栏徽标同时出现，
/// 整屏就散成三处闪动；连接过渡真正要回答的只有一句话——现在在连哪台电脑。
struct ConnectionWarmUpView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 标题。默认写成"正在连接 <电脑名>"，调用方可替换成本页面更贴切的说法。
    var headline: String?
    /// 说明文案。默认解释"通道正在建立"，调用方可替换成本页面更贴切的说明。
    var message: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 22) {
            ConnectionWarmUpBeacon(
                tokens: tokens,
                animates: !reduceMotion,
                // 辅助功能字号下文字已经很高，水纹跟着收一档，整块仍能完整落在一屏里。
                diameter: dynamicTypeSize.isAccessibilitySize ? 124 : 160
            )

            VStack(spacing: 7) {
                Text(resolvedHeadline)
                    .font(themeStore.uiFont(.title3, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)

                if !resolvedMessage.isEmpty {
                    Text(resolvedMessage)
                        .font(themeStore.uiFont(.subheadline))
                        .foregroundStyle(tokens.secondaryText)
                        .lineSpacing(2)
                }
            }
            .multilineTextAlignment(.center)
            // 说明文字不铺满整屏宽：居中的一段话超过这个宽度就会读成正文段落。
            .frame(maxWidth: 320)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(resolvedHeadline)
        .accessibilityValue(resolvedMessage)
        .accessibilityIdentifier("connection.warmUp")
    }

    /// 连接目标写在标题里。用户同时配对多台电脑时，"正在连接" 本身并不足以说明发生了什么。
    private var resolvedHeadline: String {
        if let headline, !headline.isEmpty {
            return headline
        }
        guard let displayName = appStore.activeConnectionProfile?.displayName,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.text("ui.connecting_to_your_mac")
        }
        return L10n.format("ui.connecting_to_value", displayName)
    }

    private var resolvedMessage: String {
        message ?? L10n.text("ui.a_secure_channel_is_being_established_content_appears")
    }
}

/// 连接中的水波纹：一圈圈圆环按固定节拍从落点推出去，越远越大、越淡、越细。
///
/// 三条都照着真实水纹来：外推先快后缓（匀速会读成一根环形进度条）、波峰随扩散变薄、
/// 走到最外沿前彻底散掉，所以每一轮回到起点时不会闪。
///
/// 进度只由当前时间决定（与会话行的运行环、实时状态星芒同一套做法）。视图被复用或重建
/// 都不会重新起拍，也不会叠加出多个动画源。
struct ConnectionWarmUpBeacon: View {
    let tokens: ThemeTokens
    let animates: Bool
    /// 最外沿直径。画布就是这么大，涟漪不会被裁掉。
    var diameter: CGFloat = 160

    /// 同时在路上的圈数。节拍 = cycleDuration / rippleCount，这里正好是 0.75 秒一圈。
    static let rippleCount = 4
    /// 一圈涟漪从落点走到最外沿所需的时间。
    static let cycleDuration: TimeInterval = 3
    /// 刚落下时的直径占比。真从 0 开始会有一两帧糊成一个点。
    static let birthScale: CGFloat = 0.12
    static let peakOpacity = 0.5
    static let restingOpacity = 0.32
    /// 波峰厚度：落点最厚，扩散开来变薄。
    static let maxLineWidth: CGFloat = 2.6
    static let minLineWidth: CGFloat = 0.9

    struct Ripple: Equatable {
        var scale: CGFloat
        var opacity: Double
        var lineWidth: CGFloat
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animates)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            ZStack {
                ForEach(0..<Self.rippleCount, id: \.self) { index in
                    let ripple = Self.ripple(index: index, time: time, animates: animates)
                    // 用 frame 而不是 scaleEffect 定半径：缩放会连描边一起放大，
                    // 波峰就没法自己变薄了。
                    Circle()
                        .strokeBorder(
                            tokens.primaryAction.opacity(ripple.opacity),
                            lineWidth: ripple.lineWidth
                        )
                        .frame(
                            width: diameter * ripple.scale,
                            height: diameter * ripple.scale
                        )
                }
            }
            .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    /// 第 index 圈涟漪当前的半径占比、不透明度与波峰厚度。
    static func ripple(index: Int, time: TimeInterval, animates: Bool) -> Ripple {
        guard animates else {
            // Reduce Motion：停在一组静止的同心圆。形状仍然读作"波纹正在散开"，
            // 但没有任何位移——减弱动态效果要的是这个，而不是把状态说没了。
            let progress = Double(index + 1) / Double(rippleCount + 1)
            return Ripple(
                scale: scale(atProgress: progress),
                opacity: restingOpacity * (1 - progress),
                lineWidth: lineWidth(atProgress: progress)
            )
        }

        let progress = (time / cycleDuration + Double(index) / Double(rippleCount))
            .truncatingRemainder(dividingBy: 1)
        // 外推越走越慢。匀速扩张会读成一根环形进度条，而真实的水纹是先快后缓的。
        let eased = 1 - pow(1 - progress, 2.2)
        // 落点处的一小段先淡入，新的一圈才不会凭空弹出来。
        let fadeIn = min(1, progress / 0.1)
        return Ripple(
            scale: scale(atProgress: eased),
            opacity: peakOpacity * fadeIn * (1 - eased),
            lineWidth: lineWidth(atProgress: eased)
        )
    }

    static func scale(atProgress progress: Double) -> CGFloat {
        birthScale + (1 - birthScale) * CGFloat(clamped(progress))
    }

    static func lineWidth(atProgress progress: Double) -> CGFloat {
        maxLineWidth - (maxLineWidth - minLineWidth) * CGFloat(clamped(progress))
    }

    private static func clamped(_ progress: Double) -> Double {
        min(1, max(0, progress))
    }
}
