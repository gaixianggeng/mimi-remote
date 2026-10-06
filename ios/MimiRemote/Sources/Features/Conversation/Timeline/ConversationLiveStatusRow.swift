import SwiftUI

/// 时间线尾部的“进行中”状态行：圆点动画 + `时长 · 当前阶段…`。
struct ConversationLiveStatusRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    static let accessibilityIdentifier = "conversation.timeline.live-status"

    let status: ConversationLiveStatus
    let layout: ConversationLayout

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        HStack(spacing: 0) {
            // 文字每秒刷新一次；圆点自己的动画时钟独立运行，互不牵连。
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                let isWarning = status.isWarning(at: context.date)
                HStack(alignment: .center, spacing: 8) {
                    ConversationLiveStatusGlyph(
                        tint: isWarning ? tokens.warning : tokens.accent,
                        animates: status.animates && !reduceMotion
                    )
                    .frame(width: 16, height: 18)

                    Text(status.text(at: context.date, includesTokens: false))
                        .font(themeStore.uiFont(size: 14, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isWarning ? tokens.warning : tokens.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.identity)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status.text(at: context.date, includesTokens: false))
            }
            .frame(minHeight: 32, alignment: .leading)
            .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)

            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}

/// 四点变阵与三点旋转交替播放；同一组圆点插值变形，避免切换视图或重做布局。
struct ConversationLiveStatusGlyph: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    let tint: Color
    let animates: Bool

    static let dotCount = 4
    static let formationDuration: TimeInterval = 6.4
    static let transitionDuration: TimeInterval = 0.8
    static let loopDuration = 2 * (formationDuration + transitionDuration)

    /// 坐标相对图标中心，半径相对短边；每帧只有 4 个小值类型，不创建粒子数组。
    struct Dot: Equatable {
        let x: Double
        let y: Double
        let radius: Double
    }

    var body: some View {
        let runsClock = animates && isVisible && scenePhase == .active
        // 高频更新只发生在这个叶子视图；离屏、后台或静止态不保留运行中的动画时钟。
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !runsClock)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { graphics, size in
                Self.draw(in: &graphics, size: size, time: time, animates: runsClock, tint: tint)
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .onDisappear { isVisible = false }
        .accessibilityHidden(true)
    }

    static func draw(
        in graphics: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        animates: Bool,
        tint: Color
    ) {
        let side = min(size.width, size.height)
        guard side > 0 else {
            return
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var path = Path()
        for index in 0..<dotCount {
            let dot = dot(index: index, time: time, animates: animates)
            let radius = CGFloat(dot.radius) * side
            guard radius > 0 else { continue }
            path.addEllipse(in: CGRect(
                x: center.x + CGFloat(dot.x) * side - radius,
                y: center.y + CGFloat(dot.y) * side - radius,
                width: 2 * radius,
                height: 2 * radius
            ))
        }
        graphics.fill(path, with: .color(tint))
    }

    static func dot(index: Int, time: TimeInterval, animates: Bool) -> Dot {
        let square = Dot(
            x: index == 0 || index == 3 ? -0.24 : 0.24,
            y: index < 2 ? -0.24 : 0.24,
            radius: 0.085
        )
        guard animates else { return square }

        // 不累加帧进度，也不向 Store 写入：复用行或恢复前台不会叠加计时器。
        let time = time.truncatingRemainder(dividingBy: loopDuration)
        let phase = time / 2.4 * 2 * .pi
        let compression = pow((1 - cos(phase)) / 2, 3)
        let diagonal = (Double(index) - 1.5) * 0.20
        let angle = 0.14 * sin(phase)
        let x = square.x + (diagonal - square.x) * compression
        let y = square.y + (diagonal - square.y) * compression
        let matrix = Dot(
            x: x * cos(angle) - y * sin(angle),
            y: x * sin(angle) + y * cos(angle),
            radius: square.radius
        )

        let blend: Double
        if time < formationDuration {
            return matrix
        } else if time < formationDuration + transitionDuration {
            blend = smoothStep((time - formationDuration) / transitionDuration)
        } else if time < loopDuration - transitionDuration {
            blend = 1
        } else {
            blend = 1 - smoothStep((time - loopDuration + transitionDuration) / transitionDuration)
        }

        let orbitAngle = phase + Double(index) * 2 * .pi / 3 - .pi / 2
        // 第四点缩至中心并消失；保留同一绘制槽位，回到四点时沿原路径长出。
        let orbit = index == 3 ? Dot(x: 0, y: 0, radius: 0) : Dot(
            x: 0.26 * cos(orbitAngle),
            y: 0.26 * sin(orbitAngle),
            radius: 0.03 + 0.06 * (1 + sin(orbitAngle)) / 2
        )
        return Dot(
            x: matrix.x + (orbit.x - matrix.x) * blend,
            y: matrix.y + (orbit.y - matrix.y) * blend,
            radius: matrix.radius + (orbit.radius - matrix.radius) * blend
        )
    }

    private static func smoothStep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }
}
