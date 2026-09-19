import SwiftUI

/// 时间线尾部的“进行中”状态行：动画星芒 + `时长 · N tokens · 当前阶段…`。
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
            // 文字每秒刷新一次；星芒自己的动画时钟独立运行，互不牵连。
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                let isWarning = status.isWarning(at: context.date)
                HStack(alignment: .center, spacing: 8) {
                    ConversationLiveStatusGlyph(
                        tint: isWarning ? tokens.warning : tokens.accent,
                        animates: status.animates && !reduceMotion
                    )
                    .frame(width: 16, height: 18)

                    Text(status.text(at: context.date, includesTokens: false))
                        .font(themeStore.uiFont(.footnote, weight: .medium))
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

/// 呼吸的星芒：8 根圆头射线，长度沿圆周错相起伏，整体缓慢旋转。
///
/// 动画进度只由当前时间决定，List 复用行视图时不会叠加出多个动画源；
/// 减弱动态效果或断线时停在一帧长短相间的静态星芒上。
struct ConversationLiveStatusGlyph: View {
    let tint: Color
    let animates: Bool

    static let rayCount = 8
    static let pulsePeriod: TimeInterval = 1.4
    static let rotationPeriod: TimeInterval = 9

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { graphics, size in
                Self.draw(in: &graphics, size: size, time: time, animates: animates, tint: tint)
            }
        }
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
        let lineWidth = max(1.1, side * 0.1)
        let outerRadius = side / 2 - lineWidth / 2
        let innerRadius = side * 0.06
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rotation = rotationAngle(time: time, animates: animates)
        var path = Path()
        for index in 0..<rayCount {
            let angle = rotation + Double(index) * 2 * .pi / Double(rayCount)
            let length = innerRadius + (outerRadius - innerRadius) * rayLengthFraction(index: index, time: time, animates: animates)
            let direction = CGVector(dx: cos(angle), dy: sin(angle))
            path.move(to: CGPoint(x: center.x + direction.dx * innerRadius, y: center.y + direction.dy * innerRadius))
            path.addLine(to: CGPoint(x: center.x + direction.dx * length, y: center.y + direction.dy * length))
        }
        graphics.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    /// 第 index 根射线的长度比例，范围 0.35...1。
    static func rayLengthFraction(index: Int, time: TimeInterval, animates: Bool) -> Double {
        guard animates else {
            return index.isMultiple(of: 2) ? 1 : 0.58
        }
        let phase = time / pulsePeriod * 2 * .pi - Double(index) * 2 * .pi / Double(rayCount)
        return 0.35 + 0.65 * (0.5 + 0.5 * sin(phase))
    }

    static func rotationAngle(time: TimeInterval, animates: Bool) -> Double {
        guard animates else {
            return -.pi / 2
        }
        let progress = time.truncatingRemainder(dividingBy: rotationPeriod) / rotationPeriod
        return -.pi / 2 + progress * 2 * .pi
    }
}
