import SwiftUI

struct TokenActivityDay: Identifiable, Equatable {
    let date: Date
    let tokens: Int64
    let intensity: Int
    let isFuture: Bool

    var id: Date { date }
}

struct TokenActivityWeek: Identifiable, Equatable {
    let startDate: Date
    let days: [TokenActivityDay]

    var id: Date { startDate }
}

struct TokenActivityMonthLabel: Identifiable, Equatable {
    let weekIndex: Int
    let date: Date

    var id: Int { weekIndex }
}

enum TokenActivityGridMetrics {
    static let spacing: CGFloat = 3
    static let minimumCellSize: CGFloat = 4
    /// 月份标签占的高度。
    static let monthLabelBand: CGFloat = 19
    /// 窄屏（点格图占满整宽）的默认高度。加载中、暂无数据和失败态的占位必须用同一个值，
    /// 否则状态切换时整张卡片会跳。
    static let totalHeight: CGFloat = 86

    /// 点格尺寸过去写死上限 7pt，于是网格高度恒为 86，宽屏左右分栏时右侧比左侧矮一大截、
    /// 下方空出一块。改成由调用方给出高度预算反推格子上限：给多少高度就长多大。
    static func maximumCellSize(forHeight height: CGFloat = totalHeight) -> CGFloat {
        let usable = height - monthLabelBand - spacing * 6
        guard usable.isFinite, usable > 0 else { return minimumCellSize }
        return max(usable / 7, minimumCellSize)
    }

    /// 点格保持可读尺寸，把可用宽度换成最近周数；窄屏减少历史范围而不是横向滚动。
    static func weekCount(
        availableWidth: CGFloat,
        isAccessibilitySize: Bool,
        maximumWeekCount: Int = 53,
        height: CGFloat = totalHeight
    ) -> Int {
        // GeometryReader 在布局探测阶段可能给出 0、负数或非有限宽度；此时不生成点阵，避免最小周数反向撑大父容器。
        guard maximumWeekCount > 0,
              availableWidth.isFinite,
              availableWidth >= minimumCellSize else { return 0 }
        // 只有高度预算超过默认值（宽屏把格子拉高）时才按高度放大格子，否则维持原有的偏好尺寸。
        // 直接用高度反推会把默认高度下的偏好尺寸从 6 抬到 7，同样宽度少排一周。
        let basePreferredCellSize: CGFloat = isAccessibilitySize ? 7 : 6
        let preferredCellSize = height > totalHeight
            ? maximumCellSize(forHeight: height)
            : basePreferredCellSize
        let rawCount = Int(
            floor((max(availableWidth, 0) + spacing) / (preferredCellSize + spacing))
        )
        let minimumWeekCount = min(6, maximumWeekCount)
        let maximumFittingCount = Int(
            floor((availableWidth + spacing) / (minimumCellSize + spacing))
        )
        // 正常卡片至少展示六周；极窄探测宽度则按实际可容纳数量降级，保证点格与间距总宽度不越界。
        return min(
            maximumWeekCount,
            maximumFittingCount,
            max(rawCount, minimumWeekCount)
        )
    }

    static func cellSize(
        availableWidth: CGFloat,
        weekCount: Int,
        height: CGFloat = totalHeight
    ) -> CGFloat {
        guard weekCount > 0, availableWidth.isFinite else { return 0 }
        let width = max(availableWidth, 0)
        let spacingWidth = spacing * CGFloat(weekCount - 1)
        guard width > spacingWidth else { return 0 }
        let fittedSize = (width - spacingWidth) / CGFloat(weekCount)
        return min(max(fittedSize, minimumCellSize), maximumCellSize(forHeight: height))
    }
}

enum TokenActivityCalendar {
    static func weeks(
        buckets: [AccountTokenUsageDailyBucket],
        endingAt: Date = Date(),
        weekCount: Int = 53
    ) -> [TokenActivityWeek] {
        guard weekCount > 0 else { return [] }
        let calendar = utcCalendar
        let endDay = calendar.startOfDay(for: endingAt)
        let weekday = calendar.component(.weekday, from: endDay)
        let daysSinceMonday = (weekday - calendar.firstWeekday + 7) % 7
        let currentWeekStart = calendar.date(
            byAdding: .day,
            value: -daysSinceMonday,
            to: endDay
        ) ?? endDay
        let firstWeekStart = calendar.date(
            byAdding: .weekOfYear,
            value: -(weekCount - 1),
            to: currentWeekStart
        ) ?? currentWeekStart

        var tokensByDate: [Date: Int64] = [:]
        for bucket in buckets {
            guard let date = date(from: bucket.startDate, calendar: calendar),
                  date >= firstWeekStart,
                  date <= endDay
            else {
                continue
            }
            let current = tokensByDate[date, default: 0]
            let incoming = max(bucket.tokens, 0)
            let (sum, overflowed) = current.addingReportingOverflow(incoming)
            // 服务端可能返回同一天的多个桶；累计时饱和到 Int64.max，
            // 避免异常大数让“我的”页面在渲染点格图时崩溃。
            tokensByDate[date] = overflowed ? .max : sum
        }
        let maximum = tokensByDate.values.max() ?? 0

        return (0..<weekCount).map { weekOffset in
            let weekStart = calendar.date(
                byAdding: .weekOfYear,
                value: weekOffset,
                to: firstWeekStart
            ) ?? firstWeekStart
            let days = (0..<7).map { dayOffset in
                let date = calendar.date(
                    byAdding: .day,
                    value: dayOffset,
                    to: weekStart
                ) ?? weekStart
                let tokens = tokensByDate[date] ?? 0
                return TokenActivityDay(
                    date: date,
                    tokens: tokens,
                    intensity: intensity(tokens: tokens, maximum: maximum),
                    isFuture: date > endDay
                )
            }
            return TokenActivityWeek(startDate: weekStart, days: days)
        }
    }

    static func date(from dayKey: String, calendar: Calendar = utcCalendar) -> Date? {
        let components = dayKey.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else {
            return nil
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            return nil
        }
        return date
    }

    /// 截短历史窗口后首周仍要有月份锚点；后续标签至少相隔四周，且给末端文字留出空间。
    static func monthLabels(
        for weeks: [TokenActivityWeek],
        minimumWeekSpacing: Int = 4,
        minimumTrailingWeeks: Int = 3
    ) -> [TokenActivityMonthLabel] {
        guard !weeks.isEmpty else { return [] }
        let minimumWeekSpacing = max(minimumWeekSpacing, 1)
        let minimumTrailingWeeks = max(minimumTrailingWeeks, 1)
        var labels: [TokenActivityMonthLabel] = []
        var lastLabelIndex = -minimumWeekSpacing

        for (index, week) in weeks.enumerated() {
            let date: Date?
            if index == 0 {
                date = week.days.first?.date
            } else {
                date = week.days.first {
                    utcCalendar.component(.day, from: $0.date) == 1
                }?.date
            }

            guard let date,
                  index - lastLabelIndex >= minimumWeekSpacing,
                  index == 0 || weeks.count - index >= minimumTrailingWeeks
            else {
                continue
            }
            labels.append(TokenActivityMonthLabel(weekIndex: index, date: date))
            lastLabelIndex = index
        }
        return labels
    }

    private static func intensity(tokens: Int64, maximum: Int64) -> Int {
        guard tokens > 0, maximum > 0 else { return 0 }
        // 平方根尺度既能压住偶发超大日，又不会像 log 尺度那样把常用日期全部挤到最深一档。
        let normalized = sqrt(Double(tokens) / Double(maximum))
        switch normalized {
        case ..<0.20: return 1
        case ..<0.45: return 2
        case ..<0.70: return 3
        default: return 4
        }
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}

struct TokenActivityDotGrid: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var themeStore: ThemeStore

    let buckets: [AccountTokenUsageDailyBucket]
    /// 点格图必须使用这次结果对应的服务端快照时间，否则跨天后同一份快照会漂移。
    let endingAt: Date
    /// 宽屏左右分栏时右侧要和左侧配额面板等高，格子随之放大。
    var height: CGFloat = TokenActivityGridMetrics.totalHeight

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let activeDayCount = TokenActivityCalendar.weeks(
            buckets: buckets,
            endingAt: endingAt
        )
            .flatMap(\.days)
            .filter { !$0.isFuture && $0.tokens > 0 }
            .count

        GeometryReader { proxy in
            let weekCount = TokenActivityGridMetrics.weekCount(
                availableWidth: proxy.size.width,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                height: height
            )
            let weeks = TokenActivityCalendar.weeks(
                buckets: buckets,
                endingAt: endingAt,
                weekCount: weekCount
            )
            let monthLabels = TokenActivityCalendar.monthLabels(for: weeks)
            let spacing = TokenActivityGridMetrics.spacing
            let cellSize = TokenActivityGridMetrics.cellSize(
                availableWidth: proxy.size.width,
                weekCount: weekCount,
                height: height
            )
            let contentWidth = cellSize * CGFloat(weekCount)
                + spacing * CGFloat(max(weekCount - 1, 0))
            let gridHeight = cellSize * 7 + spacing * 6

            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(weeks) { week in
                        VStack(spacing: spacing) {
                            ForEach(week.days) { day in
                                RoundedRectangle(
                                    cornerRadius: min(2.2, cellSize * 0.3),
                                    style: .continuous
                                )
                                .fill(fill(for: day, tokens: tokens))
                                .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
                .offset(y: TokenActivityGridMetrics.monthLabelBand)

                ForEach(monthLabels) { label in
                    Text(monthText(label.date))
                        .font(themeStore.uiFont(size: 9, weight: .medium))
                        .foregroundStyle(tokens.tertiaryText)
                        .fixedSize()
                        .offset(x: CGFloat(label.weekIndex) * (cellSize + spacing))
                }
            }
            .frame(width: contentWidth, height: gridHeight + TokenActivityGridMetrics.monthLabelBand, alignment: .topLeading)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.token_activity"))
        .accessibilityValue(
            L10n.format(
                "ui.token_activity_accessibility_value",
                activeDayCount
            )
        )
        .accessibilityIdentifier("settings.tokenActivity.grid")
    }

    private func fill(for day: TokenActivityDay, tokens: ThemeTokens) -> Color {
        guard !day.isFuture else { return .clear }
        let contrastBoost = colorSchemeContrast == .increased ? 0.12 : 0
        switch day.intensity {
        case 1: return tokens.accent.opacity(0.24 + contrastBoost)
        case 2: return tokens.accent.opacity(0.42 + contrastBoost)
        case 3: return tokens.accent.opacity(0.64 + contrastBoost)
        case 4: return tokens.accent.opacity(0.92)
        default: return tokens.secondaryText.opacity(0.09 + contrastBoost)
        }
    }

    private func monthText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = TokenActivityCalendar.utcCalendar
        formatter.timeZone = TokenActivityCalendar.utcCalendar.timeZone
        formatter.locale = AppLanguage.stored().locale
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date)
    }
}
