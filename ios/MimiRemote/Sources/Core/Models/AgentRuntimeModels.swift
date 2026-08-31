import Foundation

// 用量、审批、事件和连接状态模型从会话/消息展示模型中拆出。
struct UsageSummary: Codable, Hashable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let costUSD: Decimal?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case costUSD = "cost_usd"
    }

    var compactText: String? {
        if let costUSD {
            let value = NSDecimalNumber(decimal: costUSD).doubleValue
            return String(format: "$%.4f", value)
        }
        if let totalTokens {
            return "\(totalTokens) tok"
        }
        if let outputTokens {
            return "\(outputTokens) out"
        }
        return nil
    }
}

/// ChatGPT 账号维度的 Token 活动。它与单个 thread 的 UsageSummary 不同：
/// 数据由 app-server 直接返回，不能用移动端在线期间收到的 turn 通知自行累加。
struct AccountTokenUsageDailyBucket: Hashable, Identifiable {
    let startDate: String
    let tokens: Int64

    var id: String { startDate }
}

struct AccountTokenUsageSummary: Hashable {
    let lifetimeTokens: Int64?
}

struct AccountTokenUsageSnapshot: Hashable {
    let summary: AccountTokenUsageSummary
    /// nil 表示当前账号/版本没有返回日粒度历史；空数组表示接口可用但当前没有活动。
    let dailyUsageBuckets: [AccountTokenUsageDailyBucket]?
}

/// 一次账号用量请求的结果。客户端层过去用 `AccountTokenUsageSnapshot?` 表达，
/// 于是「这台主机没有该能力」和「请求失败了」都塌成 nil，上层永远无法区分。
enum AccountTokenUsageFetch: Equatable {
    case snapshot(AccountTokenUsageSnapshot)
    /// 这条链路本来就不提供账号用量（非 Codex runtime、方法不在 allowlist）。
    case unsupported
    /// 请求发出去了但失败或无法解析。是否回退到旧数据由展示层决定，不在这里静默兜底。
    case failed
}

/// Token 活动的状态机。原先由 `isRefreshingAccountTokenUsage` 和
/// `isAccountTokenUsageUnavailable` 两个 Bool 表达，既区分不出「主机不返回日粒度历史」
/// 「账号还没有活动」和「这次请求失败」，也说不清手上的网格是不是旧数据。
enum AccountTokenActivityState: Equatable {
    /// 还没有发起过请求。
    case idle
    /// 首次加载，手上没有任何可显示的历史。
    case loading
    case loaded(buckets: [AccountTokenUsageDailyBucket], asOf: Date)
    /// 接口可用，但该账号当前没有活动记录。
    case empty(asOf: Date)
    /// 当前账号或 app-server 版本不提供日粒度历史。
    case unsupported
    /// 请求失败。`previous` 是上一次成功的结果，展示层据此决定画旧网格还是纯错误态。
    case failed(previous: Previous?)

    struct Previous: Equatable {
        let buckets: [AccountTokenUsageDailyBucket]
        let asOf: Date
    }

    /// 按服务端语义归一：nil 代表不提供历史，空数组代表提供但当前没有活动。
    static func resolved(
        buckets: [AccountTokenUsageDailyBucket]?,
        asOf: Date
    ) -> AccountTokenActivityState {
        guard let buckets else { return .unsupported }
        return buckets.isEmpty ? .empty(asOf: asOf) : .loaded(buckets: buckets, asOf: asOf)
    }

    /// 可以画成点格图的数据；失败时回落到上一次成功的结果。
    var displayBuckets: [AccountTokenUsageDailyBucket]? {
        switch self {
        case .loaded(let buckets, _):
            return buckets
        case .empty:
            return []
        case .failed(let previous):
            return previous?.buckets
        case .idle, .loading, .unsupported:
            return nil
        }
    }

    /// 最近一次成功的结果，用于失败时保留旧网格并标注时间。
    var lastSuccessful: Previous? {
        switch self {
        case .loaded(let buckets, let asOf):
            return Previous(buckets: buckets, asOf: asOf)
        case .empty(let asOf):
            return Previous(buckets: [], asOf: asOf)
        case .failed(let previous):
            return previous
        case .idle, .loading, .unsupported:
            return nil
        }
    }

    /// 网格画的是上一次成功的数据，而不是这一次的结果。
    var isShowingStaleData: Bool {
        guard case .failed(let previous) = self else { return false }
        return previous != nil
    }
}

// 展示模型与 runtime 模型共享同一空白归一化规则，保持 module-internal。
extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RateLimitSummary: Codable, Hashable {
    let remainingRequests: Int?
    let remainingTokens: Int?
    let resetAt: Date?
    let limitID: String?
    let limitName: String?
    let planType: String?
    let reachedType: String?
    let primaryUsedPercent: Double?
    let secondaryUsedPercent: Double?
    let primaryResetsAt: Int64?
    let secondaryResetsAt: Int64?
    let primaryWindowDurationMins: Int?
    let secondaryWindowDurationMins: Int?
    let hasCredits: Bool?
    let creditsUnlimited: Bool?
    let creditBalance: String?
    let availability: String?
    let unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case remainingRequests = "remaining_requests"
        case remainingTokens = "remaining_tokens"
        case resetAt = "reset_at"
        case limitID = "limit_id"
        case limitName = "limit_name"
        case planType = "plan_type"
        case reachedType = "reached_type"
        case primaryUsedPercent = "primary_used_percent"
        case secondaryUsedPercent = "secondary_used_percent"
        case primaryResetsAt = "primary_resets_at"
        case secondaryResetsAt = "secondary_resets_at"
        case primaryWindowDurationMins = "primary_window_duration_mins"
        case secondaryWindowDurationMins = "secondary_window_duration_mins"
        case hasCredits = "has_credits"
        case creditsUnlimited = "credits_unlimited"
        case creditBalance = "credit_balance"
        case availability
        case unavailableReason = "unavailable_reason"
    }

    init(
        remainingRequests: Int? = nil,
        remainingTokens: Int? = nil,
        resetAt: Date? = nil,
        limitID: String? = nil,
        limitName: String? = nil,
        planType: String? = nil,
        reachedType: String? = nil,
        primaryUsedPercent: Double? = nil,
        secondaryUsedPercent: Double? = nil,
        primaryResetsAt: Int64? = nil,
        secondaryResetsAt: Int64? = nil,
        primaryWindowDurationMins: Int? = nil,
        secondaryWindowDurationMins: Int? = nil,
        hasCredits: Bool? = nil,
        creditsUnlimited: Bool? = nil,
        creditBalance: String? = nil,
        availability: String? = nil,
        unavailableReason: String? = nil
    ) {
        self.remainingRequests = remainingRequests
        self.remainingTokens = remainingTokens
        self.resetAt = resetAt
        self.limitID = limitID
        self.limitName = limitName
        self.planType = planType
        self.reachedType = reachedType
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.primaryResetsAt = primaryResetsAt
        self.secondaryResetsAt = secondaryResetsAt
        self.primaryWindowDurationMins = primaryWindowDurationMins
        self.secondaryWindowDurationMins = secondaryWindowDurationMins
        self.hasCredits = hasCredits
        self.creditsUnlimited = creditsUnlimited
        self.creditBalance = creditBalance
        self.availability = availability
        self.unavailableReason = unavailableReason
    }

    var compactText: String? {
        if isExhausted {
            return L10n.text("ui.quota_has_been_exhausted")
        }
        if let percentText = usedPercentText {
            return L10n.format("ui.used_value", percentText)
        }
        if let remainingRequests {
            return L10n.plural("ui.times_remaining_count", count: remainingRequests)
        }
        if let remainingTokens {
            return L10n.format("ui.remaining_value_tok", remainingTokens)
        }
        return nil
    }

    var isExhausted: Bool {
        if reachedType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if let primaryUsedPercent, primaryUsedPercent >= 100 {
            return true
        }
        if let secondaryUsedPercent, secondaryUsedPercent >= 100 {
            return true
        }
        if remainingRequests == 0 {
            return true
        }
        return false
    }

    var resetDate: Date? {
        if dominantUsageIsSecondary,
           let secondaryResetsAt {
            return Self.dateFromRateLimitEpoch(secondaryResetsAt)
        }
        if let primaryResetsAt {
            return Self.dateFromRateLimitEpoch(primaryResetsAt)
        }
        if let secondaryResetsAt {
            return Self.dateFromRateLimitEpoch(secondaryResetsAt)
        }
        return resetAt
    }

    var displayName: String {
        let name = limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return name
        }
        let id = limitID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, !id.isEmpty {
            return id
        }
        return "Codex"
    }

    var usedPercentValue: Double? {
        // Codex app-server 同时返回 primary/secondary 时，界面展示更接近耗尽的那一档。
        [primaryUsedPercent, secondaryUsedPercent].compactMap { $0 }.max()
    }

    private var dominantUsageIsSecondary: Bool {
        guard let secondaryUsedPercent else {
            return false
        }
        guard let primaryUsedPercent else {
            return true
        }
        return secondaryUsedPercent > primaryUsedPercent
    }

    var progressFraction: Double? {
        guard let usedPercentValue else {
            return nil
        }
        return min(max(usedPercentValue / 100, 0), 1)
    }

    var usedPercentText: String? {
        guard let percent = usedPercentValue else {
            return nil
        }
        let bounded = max(0, percent)
        if bounded.rounded() == bounded {
            return "\(Int(bounded))%"
        }
        return String(format: "%.1f%%", bounded)
    }

    static func dateFromRateLimitEpoch(_ value: Int64) -> Date? {
        guard value > 0 else {
            return nil
        }
        let seconds = value > 10_000_000_000 ? Double(value) / 1_000 : Double(value)
        return Date(timeIntervalSince1970: seconds)
    }
}

struct CodexUsageDisplaySummary: Equatable {
    static let nearLimitThreshold = 0.85

    let title: String
    let primaryText: String
    let secondaryText: String
    let progress: Double?
    let resetDate: Date?
    let isNearLimit: Bool
    let isExhausted: Bool

    /// 只在 Composer 的非阻断状态条中使用，明确告诉用户这是接近阈值而非失败。
    var nearLimitTitle: String {
        L10n.format("ui.value_usage_near_limit", title, primaryText)
    }

    static func make(rateLimit: RateLimitSummary?, now: Date = Date()) -> CodexUsageDisplaySummary? {
        guard let rateLimit else {
            return nil
        }
        guard let primaryText = rateLimit.compactText else {
            return nil
        }

        let progress = rateLimit.progressFraction
        let resetDate = rateLimit.resetDate
        let secondaryText: String
        if let resetDate {
            secondaryText = L10n.format("ui.expected_value_reset", resetText(resetDate, now: now))
        } else {
            secondaryText = L10n.text("ui.no_reset_time_yet")
        }

        return CodexUsageDisplaySummary(
            title: L10n.format("ui.value_dosage", rateLimit.displayName),
            primaryText: primaryText,
            secondaryText: secondaryText,
            progress: progress,
            resetDate: resetDate,
            isNearLimit: (progress ?? 0) >= nearLimitThreshold,
            isExhausted: rateLimit.isExhausted
        )
    }

    private static func resetText(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDate(date, inSameDayAs: now) ? "Hm" : "MdHm"
        )
        return formatter.string(from: date)
    }
}

enum CodexUsageWindowKind: String, CaseIterable, Equatable, Identifiable {
    case primary
    case secondary

    var id: String { rawValue }
}

struct CodexUsageWindowDisplay: Equatable, Identifiable {
    static let nearLimitThreshold = 0.85

    let kind: CodexUsageWindowKind
    let durationMinutes: Int?
    let label: String
    let title: String
    let usedPercentText: String?
    let progress: Double?
    let resetDate: Date?
    let resetText: String
    let isNearLimit: Bool
    let isExhausted: Bool
    let providerName: String

    var id: String { kind.id }

    var isDayScaleWindow: Bool {
        guard let durationMinutes else {
            return false
        }
        return durationMinutes >= 24 * 60
    }

    var systemImage: String {
        isDayScaleWindow ? "calendar" : "clock"
    }

    var accessibilityName: String {
        guard let durationMinutes, durationMinutes > 0 else {
            return L10n.format("ui.value_account_window", providerName)
        }
        if durationMinutes % (24 * 60) == 0 {
            return L10n.format(
                "ui.value_usage_window",
                providerName,
                L10n.plural("ui.days_count", count: durationMinutes / (24 * 60))
            )
        }
        if durationMinutes % 60 == 0 {
            return L10n.format(
                "ui.value_usage_window",
                providerName,
                L10n.plural("ui.hours_count", count: durationMinutes / 60)
            )
        }
        return L10n.format(
            "ui.value_usage_window",
            providerName,
            L10n.plural("ui.minutes_count", count: durationMinutes)
        )
    }

    var primaryText: String {
        guard let usedPercentText else {
            return L10n.text("ui.waiting_for_refresh")
        }
        return L10n.format("ui.used_value", usedPercentText)
    }

    /// 账号接口返回的是“已用比例”，左上角圆环表达的是“剩余比例”，统一在展示模型中换算，
    /// 避免不同页面各自计算后出现语义相反或越界的问题。
    var remainingProgress: Double? {
        progress.map { min(max(1 - $0, 0), 1) }
    }

    var remainingPercentText: String? {
        guard let remainingProgress else {
            return nil
        }
        let percent = remainingProgress * 100
        if abs(percent.rounded() - percent) < 0.0001 {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }

    var remainingText: String {
        guard let remainingPercentText else {
            return L10n.text("ui.waiting_for_refresh")
        }
        return L10n.format("ui.value_remaining", remainingPercentText)
    }
}

// primary/secondary 只是 app-server 的窗口槽位，并不保证永远对应 5h/7d。
// 展示层必须以服务端返回的 windowDurationMins 为准，避免产品调整额度策略后误标窗口。
struct CodexUsageWindowsDisplay: Equatable {
    let displayName: String
    let creditText: String
    let windows: [CodexUsageWindowDisplay]
    let hasLiveData: Bool

    var windowSummaryText: String {
        guard !windows.isEmpty else {
            return L10n.text("ui.account_usage_has_not_been_obtained_yet")
        }
        return L10n.format("ui.value_account_window", windows.map(\.label).joined(separator: L10n.text("ui.and")))
    }

    static func make(
        rateLimit: RateLimitSummary?,
        now: Date = Date(),
        fallbackDisplayName: String = "Codex"
    ) -> CodexUsageWindowsDisplay {
        let providerName = rateLimit?.displayName ?? fallbackDisplayName
        let windows = CodexUsageWindowKind.allCases.compactMap { kind in
            window(kind: kind, rateLimit: rateLimit, now: now, providerName: providerName)
        }
        .sorted { lhs, rhs in
            let lhsDuration = lhs.durationMinutes ?? Int.max
            let rhsDuration = rhs.durationMinutes ?? Int.max
            if lhsDuration == rhsDuration {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhsDuration < rhsDuration
        }
        return CodexUsageWindowsDisplay(
            displayName: providerName,
            creditText: creditText(rateLimit, fallbackDisplayName: providerName),
            windows: windows,
            hasLiveData: windows.contains { $0.progress != nil || $0.resetDate != nil }
        )
    }

    private static func window(
        kind: CodexUsageWindowKind,
        rateLimit: RateLimitSummary?,
        now: Date,
        providerName: String
    ) -> CodexUsageWindowDisplay? {
        let percent: Double?
        let resetEpoch: Int64?
        let durationMinutes: Int?
        switch kind {
        case .primary:
            percent = rateLimit?.primaryUsedPercent
            resetEpoch = rateLimit?.primaryResetsAt
            durationMinutes = rateLimit?.primaryWindowDurationMins
        case .secondary:
            percent = rateLimit?.secondaryUsedPercent
            resetEpoch = rateLimit?.secondaryResetsAt
            durationMinutes = rateLimit?.secondaryWindowDurationMins
        }

        // 只渲染服务端实际返回的窗口。nil rateLimit 时由外层空态承接，不伪造 5h/7d 占位行。
        guard percent != nil || resetEpoch != nil || durationMinutes != nil else {
            return nil
        }

        let progress = percent.map { min(max($0 / 100, 0), 1) }
        let resetDate = resetEpoch.flatMap(RateLimitSummary.dateFromRateLimitEpoch)
        let boundedPercent = percent.map { max(0, $0) }
        let reachedType = rateLimit?.reachedType?.lowercased() ?? ""
        let reachedThisWindow: Bool
        switch kind {
        case .primary:
            reachedThisWindow = reachedType.contains("primary")
        case .secondary:
            reachedThisWindow = reachedType.contains("secondary")
        }
        let isExhausted = reachedThisWindow || (boundedPercent ?? 0) >= 100

        return CodexUsageWindowDisplay(
            kind: kind,
            durationMinutes: durationMinutes,
            label: durationLabel(durationMinutes),
            title: durationTitle(durationMinutes),
            usedPercentText: boundedPercent.map(percentText),
            progress: progress,
            resetDate: resetDate,
            resetText: resetText(resetDate, now: now),
            isNearLimit: (progress ?? 0) >= CodexUsageWindowDisplay.nearLimitThreshold,
            isExhausted: isExhausted,
            providerName: providerName
        )
    }

    private static func durationLabel(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else {
            return L10n.text("ui.window")
        }
        if minutes % (24 * 60) == 0 {
            return "\(minutes / (24 * 60))d"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    private static func durationTitle(_ minutes: Int?) -> String {
        switch minutes {
        case 300:
            return L10n.text("ui.short_window")
        case 10_080:
            return L10n.text("ui.weekly_window")
        default:
            return L10n.text("ui.account_window_title")
        }
    }

    private static func percentText(_ percent: Double) -> String {
        if percent.rounded() == percent {
            return "\(Int(percent))%"
        }
        return String(format: "%.1f%%", percent)
    }

    private static func resetText(_ date: Date?, now: Date) -> String {
        guard let date else {
            return L10n.text("ui.no_reset_time_yet")
        }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDate(date, inSameDayAs: now) ? "Hm" : "MdHm"
        )
        return L10n.format("ui.value_reset", formatter.string(from: date))
    }

    private static func creditText(_ rateLimit: RateLimitSummary?, fallbackDisplayName: String) -> String {
        guard let rateLimit else {
            return L10n.format("ui.waiting_for_value_to_return_account_usage", fallbackDisplayName)
        }
        switch rateLimit.availability?.lowercased() {
        case "unavailable":
            if rateLimit.unavailableReason == "headless_statusline_unavailable" {
                return L10n.text("ui.headless_no_quota_percentage_yet")
            }
            return L10n.text("ui.account_quota_data_is_temporarily_unavailable")
        case "partial":
            return L10n.text("ui.show_only_observed_current_limiting_windows")
        default:
            break
        }
        if rateLimit.creditsUnlimited == true {
            return L10n.text("ui.credits_unlimited")
        }
        if let balance = rateLimit.creditBalance?.trimmingCharacters(in: .whitespacesAndNewlines),
           !balance.isEmpty {
            return L10n.format("ui.credits_balance_value", balance)
        }
        if rateLimit.hasCredits == false {
            return L10n.text("ui.credits_not_enabled")
        }
        if let plan = rateLimit.planType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty {
            return L10n.format("ui.plan_value", plan)
        }
        return L10n.text("ui.no_balance_information_yet")
    }
}

struct CodexQuotaNotice: Equatable {
    let title: String
    let message: String
    let resetDate: Date?
    let blocksSending: Bool
    let canDismiss: Bool

    static func make(rateLimit: RateLimitSummary?, errorMessage: String?, now: Date = Date()) -> CodexQuotaNotice? {
        if let rateLimit, rateLimit.isExhausted {
            let resetDate = rateLimit.resetDate
            // rate limit 快照可能在窗口重置后仍停留在 100%。重置时间已经过去时，
            // 不再用陈旧快照阻止发送；下一次账号用量刷新会覆盖它。
            if let resetDate, resetDate <= now {
                return nil
            }
            let resetText = resetDate.map { Self.resetText($0, now: now) }
            let suffix = resetText.map { L10n.format("ui.expected_value_recovery_you_can_also_click_increase", $0) }
                ?? L10n.text("ui.you_can_click_increase_quota_or_reset_usage")
            return CodexQuotaNotice(
                title: L10n.format("ui.value_message_quota_has_been_exhausted", rateLimit.displayName),
                message: L10n.format("ui.value_the_current_quota_is_not_available_value", rateLimit.displayName, suffix),
                resetDate: resetDate,
                blocksSending: true,
                canDismiss: false
            )
        }

        guard let error = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              isQuotaError(error)
        else {
            return nil
        }
        return CodexQuotaNotice(
            // error-only fallback 没有可靠的 runtime 元数据，使用中性标题，
            // 避免 Claude 会话错误显示成 Codex 额度耗尽。
            title: L10n.text("ui.quota_has_been_exhausted"),
            message: L10n.text("ui.this_sending_was_blocked_by_codex_quota_limit"),
            resetDate: nil,
            blocksSending: true,
            canDismiss: true
        )
    }

    static func isQuotaError(_ message: String) -> Bool {
        let lower = message.lowercased()
        if isUnrelatedBudgetWarning(lower) {
            return false
        }
        // 只有明确表达“额度/用量已经耗尽”的错误才升级成阻塞横幅。
        // 普通 HTTP 429 或 rate limit 也可能是瞬时限流，仍保留原始错误供用户重试，
        // 但不能据此宣告账号消息额度已经用尽。
        return [
            "hit your usage limit",
            "reached your usage limit",
            "usage limit reached",
            "usage limit exceeded",
            "usage limit has been reached",
            "message limit reached",
            "message limit exceeded",
            "message limit has been exhausted",
            "messages limit has been exhausted",
            "limit has been exhausted",
            "exceeded your current quota",
            "quota exceeded",
            "quota exhausted",
            "quota has been exhausted",
            // 服务端旧版错误不随 iOS UI 语言切换。这里只做分类，绝不把这些原文直接显示给用户。
            "额度已用尽",
            "额度耗尽",
            "消息额度不足",
            "用量已达上限",
            "使用量已达上限"
        ].contains { lower.contains($0) }
    }

    /// 宽松识别所有额度或限流相关错误，只用于触发账号状态刷新和清理旧错误，
    /// 不直接决定是否禁用发送。
    static func isRateLimitError(_ message: String) -> Bool {
        let lower = message.lowercased()
        if isUnrelatedBudgetWarning(lower) {
            return false
        }
        return isQuotaError(message) || [
            "rate limit",
            "ratelimit",
            "quota",
            "429",
            // 同上：兼容远端中文错误的稳定识别，不作为本地化产品文案。
            "额度",
            "限额",
            "速率限制",
            "用量受限"
        ].contains { lower.contains($0) }
    }

    private static func isUnrelatedBudgetWarning(_ lowercasedMessage: String) -> Bool {
        lowercasedMessage.contains("skill descriptions")
            || lowercasedMessage.contains("skills context budget")
    }

    private static func resetText(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDate(date, inSameDayAs: now) ? "Hm" : "MdHm"
        )
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded()))
        let absolute = formatter.string(from: date)
        if seconds < 60 {
            return L10n.format(
                "ui.value_approximately_value",
                absolute,
                L10n.plural("ui.seconds_count", count: seconds)
            )
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return L10n.format(
                "ui.value_approximately_value",
                absolute,
                L10n.plural("ui.minutes_count", count: minutes)
            )
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return L10n.format(
                "ui.value_approximately_value",
                absolute,
                L10n.plural("ui.hours_count", count: hours)
            )
        }
        return L10n.format(
            "ui.value_approximately_value_value",
            absolute,
            L10n.plural("ui.hours_count", count: hours),
            L10n.plural("ui.minutes_count", count: remainingMinutes)
        )
    }
}

struct ApprovalSummary: Codable, Hashable {
    let id: String
    let title: String
    // 审批摘要会随 session/history 缓存落盘。字段保持可选，保证旧版本缓存和服务端快照
    // 缺少详情时仍能正常解码；UI 再据此决定是否允许批准。
    let body: String?
    let kind: String
    let risk: String?
    let count: Int?
    // Claude 只有在明确给出 localSettings addRules 建议时，客户端才展示“始终允许”。
    // 规则仅用于确认展示，真正回传的 PermissionUpdate 由 bridge 按 request id 保存并校验。
    let availableDecisions: [String]?
    let persistentPermissionRules: [String]?

    init(
        id: String,
        title: String,
        body: String? = nil,
        kind: String,
        risk: String? = nil,
        count: Int?,
        availableDecisions: [String]? = nil,
        persistentPermissionRules: [String]? = nil
    ) {
        let normalizedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedRisk = risk?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.id = id
        self.title = title
        self.body = normalizedBody.isEmpty ? nil : normalizedBody
        self.kind = kind
        self.risk = normalizedRisk.isEmpty ? nil : normalizedRisk
        self.count = count
        self.availableDecisions = availableDecisions
        self.persistentPermissionRules = persistentPermissionRules
    }

    var hasDecisionContext: Bool {
        if body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        guard kind == "command" else {
            return false
        }
        let command = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 旧事件只带 title。含参数、路径或命令分隔符的标题仍能明确表达动作；
        // “运行命令”这类泛化标题则必须等服务端补齐 body 后才能批准。
        return command.contains(" ") || command.contains("/") || command.contains("：") || command.contains(":")
    }

    var canPersistPermission: Bool {
        let supportsDecision = availableDecisions?.contains { decision in
            decision.caseInsensitiveCompare("acceptWithPermissionUpdate") == .orderedSame
        } == true
        return supportsDecision && persistentPermissionRules?.isEmpty == false
    }

    var canAcceptMCPToolForSession: Bool {
        kind == CodexMCPToolApprovalProtocol.kind && supportsDecision("acceptForSession")
    }

    var canAlwaysAllowMCPTool: Bool {
        kind == CodexMCPToolApprovalProtocol.kind && supportsDecision("acceptAlways")
    }

    private func supportsDecision(_ expected: String) -> Bool {
        availableDecisions?.contains {
            $0.caseInsensitiveCompare(expected) == .orderedSame
        } == true
    }
}

struct AgentUserInputRequest: Identifiable, Codable, Hashable {
    let id: String
    let threadID: SessionID
    let turnID: TurnID?
    let itemID: AgentItemID
    let questions: [AgentUserInputQuestion]

    var title: String {
        if let first = questions.first {
            let header = first.header.trimmingCharacters(in: .whitespacesAndNewlines)
            if !header.isEmpty {
                return header
            }
            let question = first.question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty {
                return question
            }
        }
        return L10n.text("ui.supplementary_input")
    }
}

struct AgentUserInputQuestion: Identifiable, Codable, Hashable {
    let id: String
    let header: String
    let question: String
    let isOther: Bool
    let isSecret: Bool
    let options: [AgentUserInputOption]
    let multiSelect: Bool?

    init(
        id: String,
        header: String,
        question: String,
        isOther: Bool,
        isSecret: Bool,
        options: [AgentUserInputOption],
        multiSelect: Bool? = nil
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.isOther = isOther
        self.isSecret = isSecret
        self.options = options
        self.multiSelect = multiSelect
    }

    var allowsMultipleSelection: Bool { multiSelect == true }
}

struct AgentUserInputOption: Identifiable, Codable, Hashable {
    let label: String
    let description: String?

    var id: String { label }
}

enum SessionDataFlow {
    typealias SessionRow = DataFlowSessionRow
}

struct DataFlowSessionRow: Identifiable, Codable, Hashable {
    let id: SessionID
    let projectID: String
    let projectName: String?
    let projectPath: String?
    let title: String
    let status: SessionStatus
    let source: String
    let runtimeProvider: String?
    let resumeID: String?
    let createdAt: Date?
    let updatedAt: Date?
    let recencyAt: Date?
    let preview: String?
    let activeTurnID: TurnID?
    let lastSeq: EventSequence?
    let revision: ModelRevision
    let usage: UsageSummary?
    let rateLimit: RateLimitSummary?
    let pendingApproval: ApprovalSummary?
    let context: SessionContextSnapshot?

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case projectName = "project_name"
        case projectPath = "project_path"
        case title
        case status
        case source
        case runtimeProvider = "runtime_provider"
        case resumeID = "resume_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case recencyAt = "recency_at"
        case preview
        case activeTurnID = "active_turn_id"
        case lastSeq = "last_seq"
        case revision
        case usage
        case rateLimit = "rate_limit"
        case pendingApproval = "pending_approval"
        case context
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(SessionID.self, forKey: .id)
        self.projectID = try container.decode(String.self, forKey: .projectID)
        self.projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        self.projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? L10n.text("ui.unnamed_session")
        self.status = try container.decodeIfPresent(SessionStatus.self, forKey: .status) ?? .unknown
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? "codex"
        self.runtimeProvider = try container.decodeIfPresent(String.self, forKey: .runtimeProvider)
        self.resumeID = try container.decodeIfPresent(String.self, forKey: .resumeID)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.recencyAt = try container.decodeIfPresent(Date.self, forKey: .recencyAt)
        self.preview = try container.decodeIfPresent(String.self, forKey: .preview)
        self.activeTurnID = try container.decodeIfPresent(TurnID.self, forKey: .activeTurnID)
        self.lastSeq = try container.decodeIfPresent(EventSequence.self, forKey: .lastSeq)
        self.revision = try container.decodeIfPresent(ModelRevision.self, forKey: .revision) ?? 0
        self.usage = try container.decodeIfPresent(UsageSummary.self, forKey: .usage)
        self.rateLimit = try container.decodeIfPresent(RateLimitSummary.self, forKey: .rateLimit)
        self.pendingApproval = try container.decodeIfPresent(ApprovalSummary.self, forKey: .pendingApproval)
        self.context = try container.decodeIfPresent(SessionContextSnapshot.self, forKey: .context)
    }
}

struct MessagePage: Codable, Hashable {
    let sessionID: SessionID
    let messages: [AgentMessage]
    let nextCursor: String?
    let previousCursor: String?
    let hasMoreBefore: Bool
    let hasMoreAfter: Bool
    let snapshotSeq: EventSequence?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case messages
        case nextCursor = "next_cursor"
        case previousCursor = "previous_cursor"
        case hasMoreBefore = "has_more_before"
        case hasMoreAfter = "has_more_after"
        case snapshotSeq = "snapshot_seq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        self.messages = try container.decodeIfPresent([AgentMessage].self, forKey: .messages) ?? []
        self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        self.previousCursor = try container.decodeIfPresent(String.self, forKey: .previousCursor)
        self.hasMoreBefore = try container.decodeIfPresent(Bool.self, forKey: .hasMoreBefore) ?? false
        self.hasMoreAfter = try container.decodeIfPresent(Bool.self, forKey: .hasMoreAfter) ?? false
        self.snapshotSeq = try container.decodeIfPresent(EventSequence.self, forKey: .snapshotSeq)
    }
}

struct AgentMessage: Identifiable, Codable, Hashable {
    let id: MessageID
    let sessionID: SessionID
    let clientMessageID: ClientMessageID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    let role: MessageRole
    let kind: MessageKind
    var content: String
    var summary: String?
    var activityPayload: ConversationActivityPayload?
    var createdAt: Date?
    var updatedAt: Date?
    var seq: EventSequence?
    var revision: ModelRevision
    var sendStatus: MessageSendStatus
    var isTimestampFallback: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case clientMessageID = "client_message_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case role
        case kind
        case content
        case summary
        case activityPayload = "activity_payload"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case seq
        case revision
        case sendStatus = "send_status"
        case isTimestampFallback = "is_timestamp_fallback"
    }

    init(
        id: MessageID,
        sessionID: SessionID,
        clientMessageID: ClientMessageID? = nil,
        turnID: TurnID? = nil,
        itemID: AgentItemID? = nil,
        role: MessageRole,
        kind: MessageKind = .message,
        content: String,
        summary: String? = nil,
        activityPayload: ConversationActivityPayload? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        seq: EventSequence? = nil,
        revision: ModelRevision = 0,
        sendStatus: MessageSendStatus = .confirmed,
        isTimestampFallback: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.clientMessageID = clientMessageID
        self.turnID = turnID
        self.itemID = itemID
        self.role = role
        self.kind = kind
        self.content = content
        self.summary = summary
        self.activityPayload = activityPayload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.seq = seq
        self.revision = revision
        self.sendStatus = sendStatus
        self.isTimestampFallback = isTimestampFallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(MessageID.self, forKey: .id)
        self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        self.clientMessageID = try container.decodeIfPresent(ClientMessageID.self, forKey: .clientMessageID)
        self.turnID = try container.decodeIfPresent(TurnID.self, forKey: .turnID)
        self.itemID = try container.decodeIfPresent(AgentItemID.self, forKey: .itemID)
        self.role = try container.decode(MessageRole.self, forKey: .role)
        self.kind = try container.decodeIfPresent(MessageKind.self, forKey: .kind) ?? .message
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.activityPayload = try container.decodeIfPresent(ConversationActivityPayload.self, forKey: .activityPayload)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.seq = try container.decodeIfPresent(EventSequence.self, forKey: .seq)
        self.revision = try container.decodeIfPresent(ModelRevision.self, forKey: .revision) ?? 0
        self.sendStatus = try container.decodeIfPresent(MessageSendStatus.self, forKey: .sendStatus) ?? .confirmed
        self.isTimestampFallback = try container.decodeIfPresent(Bool.self, forKey: .isTimestampFallback) ?? false
    }
}

struct ComposerDraft: Identifiable, Codable, Hashable {
    let id: String
    let projectID: String?
    let sessionID: SessionID?
    var text: String
    var isExpanded: Bool
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        projectID: String?,
        sessionID: SessionID?,
        text: String = "",
        isExpanded: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.sessionID = sessionID
        self.text = text
        self.isExpanded = isExpanded
        self.updatedAt = updatedAt
    }
}

struct AgentEventMetadata: Codable, Hashable {
    let seq: EventSequence?
    let sessionID: SessionID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    let messageID: MessageID?
    let clientMessageID: ClientMessageID?
    let revision: ModelRevision?
    let createdAt: Date?
    let turnLifecycle: ConversationTurnLifecycle?
    /// Claude gateway 的可恢复序号。它只在完整 turn/thread 边界上存在，
    /// 且必须等 MainActor 已把事件写入 Conversation/Session 状态后才能提交。
    let replayBoundarySequence: UInt64?
    /// App 进程内的 bridge sequence epoch。reset 后旧连接的迟到确认必须被拒绝，
    /// 否则会把刚清零的 cursor 又推进到上一代高水位。
    let replayCursorEpoch: UInt64?

    enum CodingKeys: String, CodingKey {
        case seq
        case sessionID = "session_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case messageID = "message_id"
        case clientMessageID = "client_message_id"
        case revision
        case createdAt = "created_at"
        case turnLifecycle = "turn_lifecycle"
        case replayBoundarySequence = "replay_boundary_sequence"
        case replayCursorEpoch = "replay_cursor_epoch"
    }

    init(
        seq: EventSequence?,
        sessionID: SessionID?,
        turnID: TurnID?,
        itemID: AgentItemID?,
        messageID: MessageID?,
        clientMessageID: ClientMessageID?,
        revision: ModelRevision?,
        createdAt: Date?,
        turnLifecycle: ConversationTurnLifecycle? = nil,
        replayBoundarySequence: UInt64? = nil,
        replayCursorEpoch: UInt64? = nil
    ) {
        self.seq = seq
        self.sessionID = sessionID
        self.turnID = turnID
        self.itemID = itemID
        self.messageID = messageID
        self.clientMessageID = clientMessageID
        self.revision = revision
        self.createdAt = createdAt
        self.turnLifecycle = turnLifecycle
        self.replayBoundarySequence = replayBoundarySequence
        self.replayCursorEpoch = replayCursorEpoch
    }

    func withTurnLifecycle(_ lifecycle: ConversationTurnLifecycle) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: seq,
            sessionID: sessionID,
            turnID: turnID,
            itemID: itemID,
            messageID: messageID,
            clientMessageID: clientMessageID,
            revision: revision,
            createdAt: createdAt,
            turnLifecycle: lifecycle,
            replayBoundarySequence: replayBoundarySequence,
            replayCursorEpoch: replayCursorEpoch
        )
    }

    func withReplayBoundarySequence(_ sequence: UInt64?, epoch: UInt64?) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: seq,
            sessionID: sessionID,
            turnID: turnID,
            itemID: itemID,
            messageID: messageID,
            clientMessageID: clientMessageID,
            revision: revision,
            createdAt: createdAt,
            turnLifecycle: turnLifecycle,
            replayBoundarySequence: sequence,
            replayCursorEpoch: epoch
        )
    }
}

struct AgentDelta: Codable, Hashable {
    let text: String
    let role: MessageRole?
    let kind: MessageKind?
}

struct LogDelta: Codable, Hashable {
    let text: String
    let stream: String?
}

struct FileChangeSummary: Codable, Hashable {
    let path: String
    let status: String
    let additions: Int?
    let deletions: Int?
}

struct AgentApprovalRequest: Codable, Hashable {
    let id: String
    let title: String
    let body: String?
    let kind: String
    let risk: String?
    let availableDecisions: [String]?
    let persistentPermissionRules: [String]?

    init(
        id: String,
        title: String,
        body: String?,
        kind: String,
        risk: String?,
        availableDecisions: [String]? = nil,
        persistentPermissionRules: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.risk = risk
        self.availableDecisions = availableDecisions
        self.persistentPermissionRules = persistentPermissionRules
    }
}

struct AgentErrorPayload: Codable, Hashable {
    let message: String
    let code: String?
    let retryable: Bool?
}

enum ClaudeAuthenticationRecovery {
    static let errorCode = "claude_authentication_required"
    // 这是可直接粘贴到 Mac 终端执行的 CLI 命令；`/login` 只是在
    // Claude Code 交互会话内部使用的 slash command，不能作为终端命令复制。
    static let loginCommand = "claude auth login"

    static func matches(_ payload: AgentErrorPayload) -> Bool {
        if payload.code?.caseInsensitiveCompare(errorCode) == .orderedSame {
            return true
        }
        // 兼容尚未升级 bridge 的宿主，只识别 Claude Code 这条足够具体的旧英文错误，
        // 避免把 Codex 或某个 MCP 工具的普通 authentication failure 错标成 Claude 登录过期。
        let normalized = payload.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("oauth session expired")
            && normalized.contains("could not be refreshed")
    }

    static var title: String {
        L10n.text("ui.claude_code_login_expired")
    }

    static var recoveryMessage: String {
        L10n.text("ui.claude_code_login_expired_recovery")
    }

    static var activityPayload: ConversationActivityPayload {
        ConversationActivityPayload(
            category: .error,
            displayTitle: title,
            subtitle: recoveryMessage,
            status: errorCode
        )
    }
}

extension ConversationActivityPayload {
    var isClaudeAuthenticationRecovery: Bool {
        category == .error && status?.caseInsensitiveCompare(ClaudeAuthenticationRecovery.errorCode) == .orderedSame
    }
}

enum ConnectionTerminationStatus: Equatable {
    case credentialsInvalid

    var title: String {
        switch self {
        case .credentialsInvalid:
            return L10n.text("ui.need_to_re_pair")
        }
    }

    var message: String {
        switch self {
        case .credentialsInvalid:
            return L10n.text("ui.the_access_code_has_expired_and_automatic_retries")
        }
    }
}

enum ConnectionStatus: Equatable {
    case idle
    case testing
    case connected(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return L10n.text("ui.not_connected")
        case .testing:
            return L10n.text("ui.connecting_699ade16")
        case .connected:
            return L10n.text("ui.mac_assistant_connected")
        case .failed:
            return L10n.text("ui.connection_failed")
        }
    }
}

enum WebSocketStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
    case terminated(ConnectionTerminationStatus)

    var title: String {
        switch self {
        case .disconnected:
            return L10n.text("ui.terminal_not_connected")
        case .connecting:
            return L10n.text("ui.connecting_699ade16")
        case .connected:
            return L10n.text("ui.live_connection")
        case .failed:
            return L10n.text("ui.connection_failed")
        case .terminated(let reason):
            return reason.title
        }
    }
}
