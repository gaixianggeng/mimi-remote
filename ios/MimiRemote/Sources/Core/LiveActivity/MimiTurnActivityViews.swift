import SwiftUI

/// Live Activity 的锁屏与灵动岛视图（#830）。只依赖 SwiftUI，同时编译进 App 与 Widget 扩展：
/// Widget 扩展把它们装进 ActivityConfiguration，App 侧只用于渲染检查，不直接展示。
enum MimiTurnActivityStyle {
    /// 运行中沿用车载状态 Widget 的品牌紫；其余状态用系统语义色，深浅色都清楚。
    static func tint(_ status: MimiTurnActivityStatus) -> Color {
        switch status {
        case .running: return Color(red: 0.45, green: 0.24, blue: 0.88)
        case .needsYou: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }

    static func symbol(_ status: MimiTurnActivityStatus) -> String {
        switch status {
        case .running: return "arrow.triangle.2.circlepath"
        case .needsYou: return "hand.raised.fill"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }
}

struct MimiTurnActivityStatusBadge: View {
    let status: MimiTurnActivityStatus
    var diameter: CGFloat = 36

    var body: some View {
        let tint = MimiTurnActivityStyle.tint(status)
        ZStack {
            Circle().fill(tint.opacity(0.2))
            Image(systemName: MimiTurnActivityStyle.symbol(status))
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// 已用时长。系统按秒刷新，不需要任何推送；宽度固定，避免计时撑开整行。
struct MimiTurnActivityTimer: View {
    let startDate: Date
    var maxWidth: CGFloat = 76

    var body: some View {
        Text(timerInterval: startDate...Date.distantFuture, countsDown: false, showsHours: true)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .frame(maxWidth: maxWidth, alignment: .trailing)
    }
}

/// 锁屏卡片与系统通知同一套读法（#857）：左侧 App 图标，标题一行（右侧次要色计时，
/// 位置同通知的时间戳），下面一行状态。状态色只留在小圆点上，文字用次要色，
/// 与通知正文同一档；背景由 Widget 设成半透明，和通知的磨砂底一致。
struct MimiTurnActivityLockScreenView: View {
    let presentation: MimiTurnActivityPresentation
    let appIcon: Image
    let isStale: Bool
    let staleText: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            appIcon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .privacySensitive(presentation.hasSessionTitle)
                    Spacer(minLength: 4)
                    if presentation.showsTimer {
                        MimiTurnActivityTimer(startDate: presentation.startDate, maxWidth: 64)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                MimiTurnActivityLockScreenStatusLine(presentation: presentation)
                if isStale {
                    Text(staleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// 锁屏卡片第二行：「● 运行中 · 项目」。多会话时换成汇总；项目名只在缓存命中时出现。
struct MimiTurnActivityLockScreenStatusLine: View {
    let presentation: MimiTurnActivityPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(MimiTurnActivityStyle.tint(presentation.status))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(presentation.summaryText ?? presentation.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle = presentation.subtitle {
                Text(verbatim: "· " + subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 单会话显示状态词；多会话只显示「进行中 2 · 待你处理 1」，焦点状态已由图标表达，
/// 不再重复一遍状态词，窄宽度下也放得下。颜色跟随焦点会话的状态。
struct MimiTurnActivityStatusLine: View {
    let presentation: MimiTurnActivityPresentation

    var body: some View {
        Text(presentation.summaryText ?? presentation.statusText)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(MimiTurnActivityStyle.tint(presentation.status))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .accessibilityLabel(
                [presentation.statusText, presentation.summaryText].compactMap { $0 }.joined(separator: ", ")
            )
    }
}

// MARK: - 灵动岛

struct MimiTurnActivityCompactLeadingView: View {
    let presentation: MimiTurnActivityPresentation

    var body: some View {
        Image(systemName: MimiTurnActivityStyle.symbol(presentation.status))
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(MimiTurnActivityStyle.tint(presentation.status))
            .accessibilityLabel(presentation.statusText)
    }
}

/// 紧凑态右侧：多会话显示总数，单会话进行中显示计时，终态什么都不显示（左侧图标已表达）。
struct MimiTurnActivityCompactTrailingView: View {
    let presentation: MimiTurnActivityPresentation
    let activeCount: Int

    var body: some View {
        if presentation.summaryText != nil {
            Text(String(min(activeCount, 99)))
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(MimiTurnActivityStyle.tint(presentation.status))
        } else if presentation.showsTimer {
            MimiTurnActivityTimer(startDate: presentation.startDate, maxWidth: 52)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MimiTurnActivityStyle.tint(presentation.status))
        }
    }
}

struct MimiTurnActivityMinimalView: View {
    let presentation: MimiTurnActivityPresentation

    var body: some View {
        MimiTurnActivityCompactLeadingView(presentation: presentation)
    }
}

struct MimiTurnActivityExpandedLeadingView: View {
    let presentation: MimiTurnActivityPresentation

    var body: some View {
        MimiTurnActivityStatusBadge(status: presentation.status, diameter: 34)
            .padding(.leading, 4)
    }
}

struct MimiTurnActivityExpandedTrailingView: View {
    let presentation: MimiTurnActivityPresentation

    var body: some View {
        if presentation.showsTimer {
            MimiTurnActivityTimer(startDate: presentation.startDate)
                .font(.title3.weight(.semibold))
                .padding(.trailing, 4)
        }
    }
}

struct MimiTurnActivityExpandedCenterView: View {
    let presentation: MimiTurnActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(presentation.title)
                .font(.headline)
                .lineLimit(1)
                .privacySensitive(presentation.hasSessionTitle)
            if let subtitle = presentation.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MimiTurnActivityExpandedBottomView: View {
    let presentation: MimiTurnActivityPresentation
    let isStale: Bool
    let staleText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MimiTurnActivityStatusLine(presentation: presentation)
            if isStale {
                Text(staleText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
