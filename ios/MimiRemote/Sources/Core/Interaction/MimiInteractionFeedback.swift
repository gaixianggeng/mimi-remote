import SwiftUI
import UIKit

/// Mimi 的交互动效只按用户意图命名，页面不得再复制一组无语义的 spring 参数。
enum MimiMotion: CaseIterable {
    case press
    case stateTransition
    case presentation
    case gestureSettling

    struct Resolution: Equatable {
        let curve: Curve
        let allowsScale: Bool
        let allowsSpatialMotion: Bool

        var animation: Animation {
            curve.animation
        }
    }

    enum Curve: Equatable {
        case easeOut(duration: Double)
        case spring(response: Double, dampingFraction: Double, blendDuration: Double)

        var animation: Animation {
            switch self {
            case .easeOut(let duration):
                return .easeOut(duration: duration)
            case .spring(let response, let dampingFraction, let blendDuration):
                return .spring(
                    response: response,
                    dampingFraction: dampingFraction,
                    blendDuration: blendDuration
                )
            }
        }
    }

    func resolve(reduceMotion: Bool) -> Resolution {
        if reduceMotion {
            // Reduce Motion 仍保留短淡变反馈，但不允许非必要缩放或大范围空间移动。
            switch self {
            case .press:
                return Resolution(
                    curve: .easeOut(duration: 0.08),
                    allowsScale: false,
                    allowsSpatialMotion: false
                )
            case .stateTransition, .gestureSettling:
                return Resolution(
                    curve: .easeOut(duration: 0.12),
                    allowsScale: false,
                    allowsSpatialMotion: false
                )
            case .presentation:
                return Resolution(
                    curve: .easeOut(duration: 0.16),
                    allowsScale: false,
                    allowsSpatialMotion: false
                )
            }
        }

        switch self {
        case .press:
            return Resolution(
                curve: .spring(response: 0.22, dampingFraction: 1, blendDuration: 0),
                allowsScale: true,
                allowsSpatialMotion: false
            )
        case .stateTransition:
            return Resolution(
                curve: .spring(response: 0.34, dampingFraction: 1, blendDuration: 0.08),
                allowsScale: false,
                allowsSpatialMotion: true
            )
        case .presentation:
            return Resolution(
                curve: .spring(response: 0.38, dampingFraction: 0.86, blendDuration: 0),
                allowsScale: false,
                allowsSpatialMotion: true
            )
        case .gestureSettling:
            return Resolution(
                curve: .spring(response: 0.28, dampingFraction: 0.82, blendDuration: 0),
                allowsScale: false,
                allowsSpatialMotion: true
            )
        }
    }

    func animation(reduceMotion: Bool) -> Animation {
        resolve(reduceMotion: reduceMotion).animation
    }

    func animation(reduceMotion: Bool, initialVelocity: CGFloat) -> Animation {
        let resolution = resolve(reduceMotion: reduceMotion)
        guard case .spring(let response, let dampingFraction, _) = resolution.curve,
              response > 0 else {
            return resolution.animation
        }

        // SwiftUI 的 response/dampingFraction 没有速度入口；换算为等价二阶弹簧后，
        // 侧栏可把手指释放速度连续交给 settling，同时仍复用同一语义 token。
        let angularFrequency = 2 * Double.pi / response
        let stiffness = angularFrequency * angularFrequency
        let damping = 2 * dampingFraction * angularFrequency
        return .interpolatingSpring(
            mass: 1,
            stiffness: stiffness,
            damping: damping,
            initialVelocity: Double(initialVelocity)
        )
    }
}

/// 高频触控面的统一即时按压反馈。
///
/// 本样式只拥有 pressed 状态。Focus 继续由 FocusState/系统 focus effect 表达，Hover 继续使用
/// hoverEffect，避免自建状态机与系统输入竞争；视觉优先级固定为 pressed > focused > hovered > resting。
///
/// 注意：本样式只做 scaleEffect + opacity，不画背景，因此它不会给按钮补出任何命中区。
/// Button 的命中区始终取自 label 真正绘制的内容，`.frame(width: 44, height: 44)` 只是布局框——
/// 图标按钮若不额外声明 `.contentShape(...)` 或自带 `.background(...)`，可点面积就只有图标字形那么大。
/// `.plain` / `.borderless` 同理；`.bordered` / `.borderedProminent` 由系统画背景，无需再补。
/// 回归由 `ComposerTouchTargetSourceTests` 兜底。
struct MimiPressButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        let motion = MimiMotion.press.resolve(reduceMotion: reduceMotion)

        configuration.label
            .scaleEffect(configuration.isPressed && motion.allowsScale ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(motion.animation, value: configuration.isPressed)
    }
}

/// Haptic 只描述一次用户可感知的离散节点，不表示 loading、running 等持续状态。
enum MimiHapticEvent: CaseIterable {
    case commit
    case completion
    case failure
    case snap

    var pattern: MimiHapticPattern {
        switch self {
        case .commit:
            return .impactMedium
        case .completion:
            return .notificationSuccess
        case .failure:
            return .notificationError
        case .snap:
            return .selection
        }
    }
}

enum MimiHapticPattern: Hashable {
    case impactMedium
    case notificationSuccess
    case notificationError
    case selection
}

@MainActor
enum MimiHaptics {
    private static let commitGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let completionGenerator = UINotificationFeedbackGenerator()
    private static let failureGenerator = UINotificationFeedbackGenerator()
    private static let snapGenerator = UISelectionFeedbackGenerator()

    static func prepare(_ event: MimiHapticEvent) {
        switch event.pattern {
        case .impactMedium:
            commitGenerator.prepare()
        case .notificationSuccess:
            completionGenerator.prepare()
        case .notificationError:
            failureGenerator.prepare()
        case .selection:
            snapGenerator.prepare()
        }
    }

    static func fire(_ event: MimiHapticEvent) {
        // 一次调用只允许一个 generator 发出一次反馈；事件去重由拥有业务节点的调用方负责。
        switch event.pattern {
        case .impactMedium:
            commitGenerator.impactOccurred()
        case .notificationSuccess:
            completionGenerator.notificationOccurred(.success)
        case .notificationError:
            failureGenerator.notificationOccurred(.error)
        case .selection:
            snapGenerator.selectionChanged()
        }
    }
}
