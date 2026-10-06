import SwiftUI

/// 全 App 统一的"内容还没到"图形：一枚淡色粗圆环当轨道，上面一段实心弧绕圈转。
///
/// 只用在整页或整块面板等内容的位置：连接过渡、会话列表 / 工作区首屏、Git 面板、
/// 目录浏览、图片占位。按钮、行尾、徽标和胶囊里的小转圈仍用系统 `ProgressView`——
/// 那些位置要贴着文字基线，粗环缩到十几点只会糊成一个点。
///
/// 弧的位置与长度只由当前时间决定（与会话行的运行环、实时状态星芒同一套做法），
/// 视图被复用或重建都不会重新起拍，也不会叠加出多个动画源。
struct LoadingOrbit: View {
    enum Size {
        /// 整页：连接过渡、会话 / 工作区 / 时间线首屏。
        case large
        /// 面板：侧栏、检查器、图片占位这类窄区域。
        case regular

        var diameter: CGFloat {
            switch self {
            case .large: 72
            case .regular: 36
            }
        }
    }

    struct Arc: Equatable {
        /// 弧起点在整圈中的位置：0 为正上方，顺时针增加，取值 [0, 1)。
        var start: Double
        /// 弧长占整圈的比例（不含两端圆头）。
        var length: Double
    }

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var size: Size = .large

    /// 内孔直径占比。环身约占直径的 29%，按用户给的甜甜圈参考取值：
    /// 比之前 1–3pt 的细水纹饱满得多，缩到面板尺寸也仍然读作一枚圆环。
    static let holeRatio: CGFloat = 0.42
    /// 轨道只是"跑道"，压得足够淡，视线才会落在那段弧上。
    static let trackOpacity = 0.16
    /// 弧转一整圈的时间。
    static let revolutionDuration: TimeInterval = 1.15
    /// 弧长一伸一缩的周期。与转速错开，弧不会每圈都在同一位置变长，读起来不机械。
    static let breathDuration: TimeInterval = 2.3
    static let minArcLength = 0.07
    static let maxArcLength = 0.33
    /// Reduce Motion 下停住的弧：从正上方顺时针四分之一圈。
    /// 形状仍读作"正在加载"，但没有任何转动——减弱动态效果要的是这个，而不是把状态说没了。
    static let restingArc = Arc(start: 0, length: 0.25)

    var body: some View {
        let tint = themeStore.tokens(for: colorScheme).primaryAction
        let diameter = size.diameter
        let lineWidth = Self.lineWidth(diameter: diameter)
        let animates = !reduceMotion

        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animates)) { context in
            let arc = Self.arc(time: context.date.timeIntervalSinceReferenceDate, animates: animates)

            ZStack {
                Circle()
                    .strokeBorder(tint.opacity(Self.trackOpacity), lineWidth: lineWidth)
                // 先内缩半个线宽再描边，弧与轨道正好重合；trim 从 0 起、靠旋转定位，
                // 起点跨过 12 点时不会被 trim 截成两段。
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: arc.length)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(arc.start * 360 - 90))
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    static func lineWidth(diameter: CGFloat) -> CGFloat {
        diameter * (1 - holeRatio) / 2
    }

    /// 某一时刻弧的起点与长度。
    static func arc(time: TimeInterval, animates: Bool) -> Arc {
        guard animates else { return restingArc }
        let start = (time / revolutionDuration).truncatingRemainder(dividingBy: 1)
        let breath = 0.5 + 0.5 * sin(2 * .pi * time / breathDuration)
        return Arc(
            start: start < 0 ? start + 1 : start,
            length: minArcLength + (maxArcLength - minArcLength) * breath
        )
    }
}

/// 整页或面板的加载态：`LoadingOrbit` 加一到两行说明。
struct LoadingStateView: View {
    enum Placement {
        /// 铺满容器并纵向延伸到屏幕上下边缘，**圆环中心**落在这块区域正中；
        /// 说明挂在圆环下方，不参与居中。
        case centered
        /// 跟随所在位置排版（列表行、滚动内容），圆环与说明上下排列。
        case inline
    }

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var title: String?
    var message: String?
    var size: LoadingOrbit.Size = .large
    var placement: Placement = .centered

    var body: some View {
        switch placement {
        case .centered:
            VStack(spacing: captionSpacing) {
                // 上方垫一份看不见的同尺寸说明，与下方真实说明对称：
                // 被居中的是圆环本身，而不是"圆环 + 文字"整块（#624）。
                captions.hidden()
                LoadingOrbit(size: size)
                captions
            }
            .modifier(LoadingStateAccessibility(title: title, message: message))
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 纵向越过顶栏与 Tab 栏的安全区，按整屏高度居中：会话页有顶栏、工作区页没有，
            // 只按安全区居中两页会差出一条顶栏的高度，切 Tab 时圆环上下跳。
            // 只忽略容器安全区，弹出键盘时仍在键盘之上居中。
            .ignoresSafeArea(.container, edges: .vertical)
            // 铺满容器只为了定位，不挡住底下的胶囊行、搜索框和浮动按钮。
            .allowsHitTesting(false)
        case .inline:
            VStack(spacing: captionSpacing) {
                LoadingOrbit(size: size)
                captions
            }
            .modifier(LoadingStateAccessibility(title: title, message: message))
            .frame(maxWidth: .infinity)
        }
    }

    private var captionSpacing: CGFloat {
        switch size {
        case .large: 20
        case .regular: 12
        }
    }

    @ViewBuilder
    private var captions: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 }
        let resolvedMessage = message.flatMap { $0.isEmpty ? nil : $0 }

        if resolvedTitle != nil || resolvedMessage != nil {
            VStack(spacing: 7) {
                if let resolvedTitle {
                    Text(resolvedTitle)
                        .font(themeStore.uiFont(.title3, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                }
                if let resolvedMessage {
                    Text(resolvedMessage)
                        .font(themeStore.uiFont(size == .large ? .subheadline : .footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .lineSpacing(2)
                }
            }
            .multilineTextAlignment(.center)
            // 说明文字不铺满整屏宽：居中的一段话超过这个宽度就会读成正文段落。
            .frame(maxWidth: 320)
        }
    }
}

/// 圆环本身不发声，整块读成一句"在加载什么"。
private struct LoadingStateAccessibility: ViewModifier {
    let title: String?
    let message: String?

    func body(content: Content) -> some View {
        let label = [title, message].compactMap { $0 }.first { !$0.isEmpty }
            ?? L10n.text("ui.loading")
        let value = title?.isEmpty == false ? (message ?? "") : ""
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}
