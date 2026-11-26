using System.Globalization;

namespace MimiRemote.Core;

public sealed record AssistantPresentation(
    string Id,
    string Title,
    bool Enabled,
    bool Supported,
    bool Available,
    string BadgeText,
    string DetailText,
    string QuotaText,
    string? DiagnosticCode);

public static class AssistantRuntimePresentation
{
    public static AssistantPresentation Describe(
        string id,
        string title,
        bool enabled,
        RuntimeEntry? entry,
        OnboardingCheck? preflightCheck = null)
    {
        var checkId = CheckIdForRuntime(id);
        if (string.Equals(preflightCheck?.Code, "runtime_unsupported_platform", StringComparison.Ordinal))
        {
            return new AssistantPresentation(
                id,
                title,
                Enabled: false,
                Supported: false,
                Available: false,
                BadgeText: "当前平台不支持",
                DetailText: OnboardingCopyCatalog.LocalizedMessage("runtime_unsupported_platform", checkId, title),
                QuotaText: "当前平台不适用额度信息。",
                DiagnosticCode: "runtime_unsupported_platform");
        }

        if (!enabled)
        {
            var detected = preflightCheck?.Available == true;
            var badge = detected ? "已检测到（未启用）" : "已关闭";
            var detail = detected
                ? "已检测到可用助手，启用后即可在手机端使用。"
                : preflightCheck is { Code: { Length: > 0 } code }
                    ? OnboardingCopyCatalog.LocalizedMessage(code, checkId, title, preflightCheck.SelectedOrDetectedVersion)
                    : "当前未启用。";
            return new AssistantPresentation(
                id,
                title,
                Enabled: false,
                Supported: true,
                Available: true,
                BadgeText: badge,
                DetailText: detail,
                QuotaText: "启用后可查看额度信息。",
                DiagnosticCode: preflightCheck?.Code);
        }

        if (entry is null)
        {
            return new AssistantPresentation(
                id,
                title,
                Enabled: true,
                Supported: true,
                Available: true,
                BadgeText: "正在检查",
                DetailText: "正在读取助手运行状态。",
                QuotaText: FormatQuota(null, null),
                DiagnosticCode: null);
        }

        if (string.Equals(entry.Reason, "refresh_in_progress", StringComparison.Ordinal))
        {
            return new AssistantPresentation(
                id,
                title,
                Enabled: true,
                Supported: true,
                Available: true,
                BadgeText: "正在检查",
                DetailText: string.Equals(id, "deepseek", StringComparison.Ordinal)
                    ? "正在确认后台服务与 DeepSeek Harness 的连接。"
                    : $"正在检查 {title} 状态…",
                QuotaText: FormatQuota(entry.RateLimits, entry.Reason),
                DiagnosticCode: null);
        }

        var versionSuffix = string.IsNullOrWhiteSpace(entry.Version) ? "" : $"（版本 {entry.Version.Trim()}）";
        switch (entry.State)
        {
            case "ready":
            case "available":
            case "connected":
                return new AssistantPresentation(
                    id,
                    title,
                    Enabled: true,
                    Supported: true,
                    Available: true,
                    BadgeText: string.Equals(id, "deepseek", StringComparison.Ordinal) ? "已连接" : "可用",
                    DetailText: $"{title} 已就绪{versionSuffix}。",
                    QuotaText: FormatQuota(entry.RateLimits, entry.Reason),
                    DiagnosticCode: null);

            case "signed_out":
                {
                    var signedOutCode = id switch
                    {
                        "codex" => "codex_signed_out",
                        "claude" => "claude_signed_out",
                        "agy" => "agy_signed_out",
                        "deepseek" => "deepseek_auth_failed",
                        _ => "runtime_probe_failed",
                    };
                    return new AssistantPresentation(
                        id,
                        title,
                        Enabled: true,
                        Supported: true,
                        Available: true,
                        BadgeText: string.Equals(id, "deepseek", StringComparison.Ordinal) ? "需要更新启动链接" : "需要登录",
                        DetailText: OnboardingCopyCatalog.LocalizedMessage(signedOutCode, checkId, title, entry.Version),
                        QuotaText: FormatQuota(entry.RateLimits, entry.Reason),
                        DiagnosticCode: signedOutCode);
                }

            case "disabled":
                return new AssistantPresentation(
                    id,
                    title,
                    Enabled: true,
                    Supported: true,
                    Available: true,
                    BadgeText: "等待设置生效",
                    DetailText: "配置尚未同步到运行中的服务，请刷新或重新加载服务。",
                    QuotaText: FormatQuota(entry.RateLimits, entry.Reason),
                    DiagnosticCode: null);

            case "unavailable":
                {
                    var (code, detail) = TranslateUnavailableReason(id, checkId, title, entry.Reason, preflightCheck);
                    return new AssistantPresentation(
                        id,
                        title,
                        Enabled: true,
                        Supported: true,
                        Available: true,
                        BadgeText: "暂不可用",
                        DetailText: detail,
                        QuotaText: FormatQuota(entry.RateLimits, entry.Reason),
                        DiagnosticCode: code);
                }

            default:
                return new AssistantPresentation(
                    id,
                    title,
                    Enabled: true,
                    Supported: true,
                    Available: true,
                    BadgeText: "状态未知",
                    DetailText: OnboardingCopyCatalog.LocalizedMessage("runtime_probe_failed", checkId, title),
                    QuotaText: FormatQuota(entry.RateLimits, entry.Reason),
                    DiagnosticCode: "runtime_probe_failed");
        }
    }

    public static string FormatQuota(RuntimeRateLimits? limits, string? runtimeReason)
    {
        if (string.Equals(runtimeReason, "quota_refresh_in_progress", StringComparison.Ordinal))
        {
            return "正在刷新额度信息，不影响正常使用。";
        }
        if (limits is null || string.Equals(limits.Availability, "unavailable", StringComparison.OrdinalIgnoreCase))
        {
            return "当前暂未提供额度信息，不影响助手使用。";
        }
        var lines = new List<string>();
        if (!string.IsNullOrWhiteSpace(limits.PlanType))
        {
            lines.Add(limits.PlanType.Trim());
        }
        RateLimitWindow?[] windows = [limits.Primary, limits.Secondary];
        foreach (var window in windows)
        {
            if (window?.RemainingPercent is double remaining)
            {
                var resetSuffix = window.ResetsAt is > 0 and < 253402300800
                    ? string.Create(
                        CultureInfo.InvariantCulture,
                        $" · {DateTimeOffset.FromUnixTimeSeconds(window.ResetsAt.Value).ToLocalTime():MM-dd HH:mm} 重置")
                    : "";
                lines.Add(string.Create(CultureInfo.InvariantCulture, $"{window.Duration}：剩余 {remaining:0.#}%{resetSuffix}"));
            }
        }
        if (!string.IsNullOrWhiteSpace(limits.CreditBalance))
        {
            lines.Add(limits.CreditBalance.Trim());
        }
        return lines.Count > 0 ? string.Join("\n", lines) : "当前暂未提供额度信息，不影响助手使用。";
    }

    public static string CheckIdForRuntime(string runtimeId) => runtimeId switch
    {
        "codex" => "assistant_codex",
        "claude" => "assistant_claude",
        "agy" => "assistant_agy",
        "deepseek" => "assistant_deepseek",
        _ => "assistant_any",
    };

    private static (string Code, string Detail) TranslateUnavailableReason(
        string id,
        string checkId,
        string title,
        string? reason,
        OnboardingCheck? preflightCheck)
    {
        if (preflightCheck is { Code: { Length: > 0 } preflightCode }
            && !preflightCode.EndsWith("_signed_out", StringComparison.Ordinal))
        {
            return (preflightCode, OnboardingCopyCatalog.LocalizedMessage(
                preflightCode,
                checkId,
                title,
                preflightCheck.SelectedOrDetectedVersion));
        }
        return (id, reason) switch
        {
            ("codex", "upstream_unavailable" or "shared_local_session_unavailable") =>
                ("codex_upstream_unavailable", OnboardingCopyCatalog.LocalizedMessage("codex_upstream_unavailable", checkId, title)),
            ("claude", "bridge_unavailable") =>
                ("claude_bridge_missing", OnboardingCopyCatalog.LocalizedMessage("claude_bridge_missing", checkId, title)),
            ("agy", "adapter_unavailable") =>
                ("agy_adapter_missing", OnboardingCopyCatalog.LocalizedMessage("agy_adapter_missing", checkId, title)),
            ("deepseek", "harness_unavailable") =>
                ("deepseek_not_running", OnboardingCopyCatalog.LocalizedMessage("deepseek_not_running", checkId, title)),
            ("deepseek", "credentials_unavailable") =>
                ("deepseek_auth_failed", OnboardingCopyCatalog.LocalizedMessage("deepseek_auth_failed", checkId, title)),
            ("deepseek", "models_unavailable") =>
                ("deepseek_no_models", OnboardingCopyCatalog.LocalizedMessage("deepseek_no_models", checkId, title)),
            // Login/account unknown must never be reported as signed_out; map to runtime_probe_failed.
            _ => ("runtime_probe_failed", OnboardingCopyCatalog.LocalizedMessage("runtime_probe_failed", checkId, title)),
        };
    }
}
