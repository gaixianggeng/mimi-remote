using System.Globalization;

namespace MimiRemote.Core;

public sealed partial class OnboardingWizardStateMachine
{
    private static string FormatStateBadge(string state) => state switch
    {
        "ok" => "已就绪",
        "checking" => "检查中…",
        "optional" => "可选",
        "action_needed" => "需处理",
        "error" => "异常",
        _ => "未知",
    };

    public static string FormatFixLabel(OnboardingFix fix) => fix.Kind switch
    {
        "open_url" => "打开说明",
        "open_settings" => fix.Target switch
        {
            "host_recovery" => "查看恢复说明",
            "windows_firewall" => "检查防火墙规则",
            "windows_network_profile" => "打开网络设置",
            "connections" => "前往连接手机",
            "assistants" => "查看助手设置",
            "date_time" => "打开日期与时间",
            "managed_connection" => "查看托管连接",
            _ => "打开系统设置",
        },
        "choose_path" => string.Equals(fix.Target, "workspace_root", StringComparison.Ordinal)
            ? "选择代码目录…"
            : "手动选择程序…",
        "run_fix" => fix.Action switch
        {
            "save_setup" => "去选择代码目录",
            "enable_codex" => "启用 Codex",
            "enable_claude" => "启用 Claude Code",
            "enable_agy" => "启用 Antigravity",
            "connect_deepseek" => "连接 DeepSeek",
            "enable_tailscale" => "启用 Tailscale",
            "enable_tailcat" => "启用内置连接",
            "enable_lan" => "启用同一局域网",
            "register_service" => "注册并启动服务",
            "restart_service" => "重新加载服务",
            "doctor_fix" => "修复文件权限",
            _ => "执行修复",
        },
        "retry" => "重新检查",
        "skip" => "跳过此项",
        _ => "重新检查",
    };

    private static string FormatCandidates(IReadOnlyList<OnboardingCandidate>? candidates)
    {
        if (candidates is null || candidates.Count == 0)
        {
            return "";
        }
        var lines = new List<string>(candidates.Count);
        foreach (var c in candidates)
        {
            var outcomeText = c.Outcome switch
            {
                "selected" => "已选用",
                "compatible" => "兼容",
                "unsupported" => "版本不支持",
                "unusable" => "不可执行",
                "timeout" => "探测超时",
                "missing" => "不存在",
                _ => c.Outcome,
            };
            var ver = string.IsNullOrWhiteSpace(c.Version) ? "" : $" ({c.Version})";
            lines.Add(string.Create(CultureInfo.InvariantCulture, $"候选 {lines.Count + 1}：{outcomeText}{ver}"));
        }
        return string.Join("\n", lines);
    }

    // Keep the diagnostic strictly aligned with the shared onboarding catalog
    // (lan_firewall_blocked / network_lan only permits open_settings/windows_firewall).
    // Official download fallback stays on LastLanMaintenanceResult and
    // MaintenanceFallbackDownloadUrl.
    private static OnboardingResolvedDiagnostic BuildLanMaintenanceDiagnostic(MaintenanceRunResult result) => new()
    {
        Code = "lan_firewall_blocked",
        Step = "network_lan",
        Message = result.Message,
        AllowedFix = OnboardingFix.OpenSettings("windows_firewall"),
        Trusted = true,
    };
}
