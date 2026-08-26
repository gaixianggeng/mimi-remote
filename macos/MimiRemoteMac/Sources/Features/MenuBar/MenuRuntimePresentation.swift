import Foundation

enum MenuSharedDaemonSeverity: String, Equatable, Sendable {
    case normal
    case migrationPending
    case needsCheck
    case resourceDegraded
    case resourceCritical
    case unknown
}

struct MenuSharedDaemonPresentation: Equatable, Sendable {
    let title: String
    let statusText: String
    let detailText: String
    let severity: MenuSharedDaemonSeverity

    var accessibilityText: String {
        "\(title)：\(statusText)。\(detailText)"
    }
}

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
    static func sharedDaemonPresentation(
        for daemon: AgentRuntimeSharedDaemonStatus?,
        at now: Date = Date()
    ) -> MenuSharedDaemonPresentation {
        guard let daemon else {
            return MenuSharedDaemonPresentation(
                title: "共享服务",
                statusText: "状态未知",
                detailText: "PID 未知 · 运行时长未知",
                severity: .unknown
            )
        }

        let severity: MenuSharedDaemonSeverity
        if daemon.listenerPID <= 0 || daemon.openFileDescriptors < 0 || daemon.directChildProcesses < 0 {
            severity = .unknown
        } else {
            severity = sharedDaemonSeverity(
                ownerState: daemon.ownerState,
                resourceState: daemon.resourceState
            )
        }
        var detail = "\(pidText(for: daemon)) · \(listenerUptimeText(for: daemon, at: now))"
        if severity == .resourceDegraded || severity == .resourceCritical {
            detail += " · \(fileDescriptorDetail(for: daemon))"
        }

        return MenuSharedDaemonPresentation(
            title: "共享服务",
            statusText: sharedDaemonStatusText(for: severity),
            detailText: detail,
            severity: severity
        )
    }

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

    private static func sharedDaemonSeverity(
        ownerState: String,
        resourceState: String
    ) -> MenuSharedDaemonSeverity {
        let owner = ownerState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resource = resourceState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch owner {
        case "stable":
            switch resource {
            case "healthy", "unknown": return .normal
            case "degraded": return .resourceDegraded
            case "critical": return .resourceCritical
            default: return .unknown
            }
        case "migration_pending":
            return .migrationPending
        case "external", "owner_claimed_unverified", "unmanaged_listener", "listener_mismatch", "owner_unavailable":
            return .needsCheck
        default:
            return .unknown
        }
    }

    private static func sharedDaemonStatusText(
        for severity: MenuSharedDaemonSeverity
    ) -> String {
        switch severity {
        case .normal: return "运行正常"
        case .migrationPending: return "等待迁移"
        case .needsCheck: return "需要检查"
        case .resourceDegraded: return "资源偏高"
        case .resourceCritical: return "资源紧张"
        case .unknown: return "状态未知"
        }
    }

    private static func pidText(for daemon: AgentRuntimeSharedDaemonStatus) -> String {
        daemon.listenerPID > 0 ? "PID \(daemon.listenerPID)" : "PID 未知"
    }

    private static func listenerUptimeText(
        for daemon: AgentRuntimeSharedDaemonStatus,
        at now: Date
    ) -> String {
        guard let startedAt = daemon.listenerStartedDate,
              startedAt <= now.addingTimeInterval(60)
        else {
            return "运行时长未知"
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

    private static func fileDescriptorDetail(
        for daemon: AgentRuntimeSharedDaemonStatus
    ) -> String {
        if let usage = daemon.fdUsagePercent, usage.isFinite, usage >= 0 {
            let rounded = usage.rounded()
            let value = abs(rounded - usage) < 0.0001
                ? "\(Int(rounded))%"
                : String(format: "%.1f%%", usage)
            return "FD 使用率 \(value)"
        }
        return daemon.openFileDescriptors > 0
            ? "FD \(daemon.openFileDescriptors)"
            : "FD 数量未知"
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
