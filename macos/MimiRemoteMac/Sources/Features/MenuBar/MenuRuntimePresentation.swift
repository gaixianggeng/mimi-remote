import Foundation

enum MenuRuntimeUsageTintRole: Equatable {
    case codexLong
    case claudeLong
    case claudeShort
}

struct MenuRuntimeUsageItem: Equatable, Identifiable {
    let id: String
    let runtimeID: String
    let providerName: String
    let window: AgentRuntimeRateLimitWindow
    let isExhausted: Bool
    let tintRole: MenuRuntimeUsageTintRole
}

struct MenuRuntimeUsageSlot: Equatable, Identifiable {
    let id: String
    let providerName: String
    let fallbackWindowLabel: String
    let tintRole: MenuRuntimeUsageTintRole
    let item: MenuRuntimeUsageItem?

    var windowLabel: String {
        item?.window.durationLabel ?? fallbackWindowLabel
    }
}

enum MenuRuntimePresentation {
    static func versionText(for runtime: AgentRuntimeStatus?) -> String? {
        guard let runtime,
              let version = runtime.version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty
        else {
            return nil
        }
        switch runtime.id {
        case "codex":
            return "Codex CLI \(version)"
        case "claude":
            return "Claude Bridge \(version)"
        default:
            return "运行时 \(version)"
        }
    }

    /// Codex 是主运行时；它不可用时菜单里原来只有「暂不可用」和「额度未知」，
    /// 用户看不出是没装 Codex 还是别的问题（#554）。这里给出下一步。
    static func codexUnavailableGuidance(for runtime: AgentRuntimeStatus?) -> String? {
        guard let runtime, runtime.id == "codex", runtime.enabled,
              runtime.state == .unavailable, runtime.reason != "refresh_in_progress"
        else {
            return nil
        }
        return "没有检测到可用的 Codex。还没装的话，请先在这台 Mac 上安装并登录 Codex（命令行版或 ChatGPT 桌面版），装好后点「刷新状态」；仍不可用就运行诊断。"
    }

    static func detailText(
        for runtime: AgentRuntimeStatus?,
        missingDetail: String
    ) -> String {
        guard let runtime else {
            return missingDetail
        }
        if runtime.reason == "refresh_in_progress" {
            return "正在后台获取连接与额度状态…"
        }
        // 认证类型与状态必须同时匹配，避免把其他已连接账户误显示成 API Key。
        let isConfiguredAPIKey = runtime.authMode == "api_key"
            && (runtime.state == .available || runtime.state == .connected)
        if isConfiguredAPIKey {
            return "API Key 已配置（按量计费），将在首次请求时验证有效性。"
        }
        if runtime.reason == "bedrock_credentials_configured_unverified" {
            return "Bedrock 凭据来源已配置，将在首次请求时验证有效性。"
        }
        if runtime.reason == "account_configured_unverified" {
            return "账户已配置，但尚未验证凭据是否有效。"
        }
        switch runtime.state {
        case .disabled:
            return "可在设置中启用 Claude 实验通道。"
        case .signedOut:
            return "请在这台 Mac 上完成登录。"
        case .unavailable:
            return "运行时暂不可用，请刷新或运行诊断。"
        case .connected, .available:
            return "尚未获取到额度数据。"
        }
    }

    static func uptimeText(
        for runtime: AgentRuntimeStatus?,
        at now: Date = Date()
    ) -> String? {
        guard let startedAt = runtime?.startedDate,
              startedAt <= now.addingTimeInterval(60)
        else {
            return nil
        }
        let totalMinutes = max(0, Int(now.timeIntervalSince(startedAt) / 60))
        if totalMinutes == 0 {
            return "已运行不足 1 分钟"
        }

        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0
                ? "已运行 \(days)天 \(hours)小时"
                : "已运行 \(days)天"
        }
        if hours > 0 {
            return minutes > 0
                ? "已运行 \(hours)小时 \(minutes)分钟"
                : "已运行 \(hours)小时"
        }
        return "已运行 \(minutes)分钟"
    }

    /// 与设置页保持相同的三环语义：Codex 长窗口、Claude 长窗口、Claude 短窗口。
    /// primary/secondary 的槽位并不稳定，因此始终按服务端返回的真实窗口时长选择。
    static func usageItems(
        codex: AgentRuntimeStatus?,
        claude: AgentRuntimeStatus?
    ) -> [MenuRuntimeUsageItem] {
        var result: [MenuRuntimeUsageItem] = []
        if let codex, let candidate = longWindow(in: codex) {
            result.append(
                usageItem(
                    runtime: codex,
                    candidate: candidate,
                    tintRole: .codexLong
                )
            )
        }
        if let claude, let longCandidate = longWindow(in: claude) {
            result.append(
                usageItem(
                    runtime: claude,
                    candidate: longCandidate,
                    tintRole: .claudeLong
                )
            )
            if let shortCandidate = shortWindow(in: claude, excluding: longCandidate.slot) {
                result.append(
                    usageItem(
                        runtime: claude,
                        candidate: shortCandidate,
                        tintRole: .claudeShort
                    )
                )
            }
        }
        return Array(result.prefix(3))
    }

    /// 三个槽位固定对应三层圆环，额度暂不可用时也保留对应信息行。
    /// 这样后台刷新只更新数值，不会让卡片高度和左右对齐发生跳变。
    static func usageSlots(
        codex: AgentRuntimeStatus?,
        claude: AgentRuntimeStatus?
    ) -> [MenuRuntimeUsageSlot] {
        guard codex != nil || claude != nil else { return [] }
        let items = usageItems(codex: codex, claude: claude)

        var slots = [
            MenuRuntimeUsageSlot(
                id: "codex:long",
                providerName: "Codex",
                fallbackWindowLabel: "长周期",
                tintRole: .codexLong,
                item: items.first { $0.tintRole == .codexLong }
            ),
        ]
        if claude?.enabled == true {
            slots.append(
                MenuRuntimeUsageSlot(
                    id: "claude:long",
                    providerName: "Claude",
                    fallbackWindowLabel: "长周期",
                    tintRole: .claudeLong,
                    item: items.first { $0.tintRole == .claudeLong }
                )
            )
            slots.append(
                MenuRuntimeUsageSlot(
                    id: "claude:short",
                    providerName: "Claude",
                    fallbackWindowLabel: "短周期",
                    tintRole: .claudeShort,
                    item: items.first { $0.tintRole == .claudeShort }
                )
            )
        }
        return slots
    }

    private struct UsageCandidate {
        let slot: String
        let window: AgentRuntimeRateLimitWindow
    }

    private static func longWindow(in runtime: AgentRuntimeStatus) -> UsageCandidate? {
        candidates(in: runtime).max {
            ($0.window.windowDurationMins ?? -1) < ($1.window.windowDurationMins ?? -1)
        }
    }

    private static func shortWindow(
        in runtime: AgentRuntimeStatus,
        excluding slot: String
    ) -> UsageCandidate? {
        candidates(in: runtime)
            .filter { $0.slot != slot }
            .min {
                ($0.window.windowDurationMins ?? Int64.max)
                    < ($1.window.windowDurationMins ?? Int64.max)
            }
    }

    private static func candidates(in runtime: AgentRuntimeStatus) -> [UsageCandidate] {
        guard let limits = runtime.rateLimits else { return [] }
        return [
            limits.primary.map { UsageCandidate(slot: "primary", window: $0) },
            limits.secondary.map { UsageCandidate(slot: "secondary", window: $0) },
        ]
        .compactMap { $0 }
        .filter {
            $0.window.usedPercent != nil
                || $0.window.windowDurationMins != nil
                || $0.window.resetsAt != nil
        }
    }

    private static func usageItem(
        runtime: AgentRuntimeStatus,
        candidate: UsageCandidate,
        tintRole: MenuRuntimeUsageTintRole
    ) -> MenuRuntimeUsageItem {
        let reached = runtime.rateLimits?.reachedType?.lowercased() ?? ""
        let providerName: String
        switch runtime.id.lowercased() {
        case "codex": providerName = "Codex"
        case "claude": providerName = "Claude"
        default: providerName = runtime.title
        }
        return MenuRuntimeUsageItem(
            id: "\(runtime.id):\(candidate.slot)",
            runtimeID: runtime.id,
            providerName: providerName,
            window: candidate.window,
            isExhausted: candidate.window.isExhausted || reached.contains(candidate.slot),
            tintRole: tintRole
        )
    }
}
