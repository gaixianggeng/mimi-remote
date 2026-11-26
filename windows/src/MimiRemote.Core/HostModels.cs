using System.Globalization;

namespace MimiRemote.Core;

public sealed record HostStatus
{
    public string Version { get; init; } = "";
    public string ServerVersion { get; init; } = "";
    public string Endpoint { get; init; } = "";
    public int Projects { get; init; }
    public bool ProcessOk { get; init; }
    public bool ServiceOk { get; init; }
    public bool DoctorOk { get; init; }
    public bool? WorkspaceConfirmed { get; init; }
    public string ProcessError { get; init; } = "";
    public string ServiceError { get; init; } = "";
    public RuntimeStatus? RuntimeStatus { get; init; }
    public HostNetworkStatus? NetworkStatus { get; init; }
    public ModuleStatus? ModuleStatus { get; init; }
    public string Title => ServiceOk ? "电脑已就绪" : ProcessOk ? "服务需要处理" : "服务已停止";
}

public sealed record HostNetworkStatus
{
    public string Mode { get; init; } = "";
    public bool AllowLan { get; init; }
    public bool PolicyChecked { get; init; }
    public bool PolicyOk { get; init; }
    public bool FirewallValid { get; init; }
    public string InterfaceAlias { get; init; } = "";
    public string NetworkCategory { get; init; } = "";
    public int UnsafeRuleCount { get; init; }
    public bool PolicyInspectionError { get; init; }
}

public sealed record RuntimeStatus
{
    public RuntimeEntry[] Runtimes { get; init; } = [];
}
public sealed record RuntimeEntry
{
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    public bool Enabled { get; init; }
    public string State { get; init; } = "";
    public string Version { get; init; } = "";
    public string Reason { get; init; } = "";
    public RuntimeRateLimits? RateLimits { get; init; }
}
public sealed record TailcatStatus
{
    public bool Enabled { get; init; }
    public bool Running { get; init; }
    public string Mode { get; init; } = "";
    public string DerpMapUrl { get; init; } = "";
    public int PairedDeviceCount { get; init; }
    public string Error { get; init; } = "";
    public string Choice => Mode == "managed" ? "mimi" : string.IsNullOrEmpty(DerpMapUrl) ? "default" : "custom";
}
public sealed record PairingInfo
{
    public bool? Ok { get; init; }
    public string? PairUrl { get; init; }
    public string PairExpiresAt { get; init; } = "";
    public string Endpoint { get; init; } = "";
    public string? Network { get; init; }
    public string? TailscaleDnsName { get; init; }
    public string? TailscaleDeviceName { get; init; }
    public string[] Warnings { get; init; } = [];
    public bool HasTicket => !string.IsNullOrWhiteSpace(PairUrl);
}
public static class RelayPolicy
{
    public static bool NeedsConfirmation(string choice, string url, TailcatStatus current) =>
        current.Enabled && choice != "mimi" && (current.Mode == "managed" || url != current.DerpMapUrl);

    public static string[] Arguments(string choice, string url)
    {
        if (choice is not ("default" or "custom" or "mimi"))
        {
            throw new ArgumentException("请选择默认、自建或 Mimi 中转。", nameof(choice));
        }
        if (choice == "custom" && (url.Length > 2048 ||
            !Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
            string.IsNullOrEmpty(uri.Host) || !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Fragment)))
        {
            throw new ArgumentException("请输入完整的 DERP Map HTTPS 地址，不含账号或片段。", nameof(url));
        }
        return ["tailcat", "relay", "set", "--choice", choice, "--derp-map-url",
            choice == "custom" ? url : "", "--json"];
    }
}

public sealed record DoctorReport
{
    public bool Ok { get; init; }
    public string Version { get; init; } = "";
    public string Listen { get; init; } = "";
    public DoctorCheck[] Checks { get; init; } = [];
}

public sealed record DoctorCheck
{
    public string Name { get; init; } = "";
    public bool Ok { get; init; }
    public string Level { get; init; } = "";
    public string Message { get; init; } = "";
    public string Fix { get; init; } = "";
    public string Capability { get; init; } = "";
    public string State { get; init; } = "";
    public string Reason { get; init; } = "";
}

public static class DiagnosticSanitizer
{
    private static readonly Dictionary<string, string> DoctorCheckTitles = new(StringComparer.Ordinal)
    {
        ["token"] = "本地访问凭据",
        ["config"] = "配置文件",
        ["config_permissions"] = "配置文件权限",
        ["workspace"] = "代码目录",
        ["projects"] = "项目发现",
        ["codex"] = "Codex 运行时",
        ["claude"] = "Claude Code 运行时",
        ["agy"] = "Antigravity 运行时",
        ["deepseek"] = "DeepSeek Harness",
        ["tailscale"] = "Tailscale 网络",
        ["tailcat"] = "内置连接（Tailcat）",
        ["lan"] = "同一局域网",
        ["port"] = "服务监听端口",
        ["service"] = "后台服务",
        ["file-access-preflight"] = "目录访问权限",
        ["deepseek-harness"] = "DeepSeek Harness",
        ["claude-bridge"] = "Claude Code 适配器",
        ["agy-adapter"] = "Antigravity 适配器",
        ["app-server"] = "Codex 服务",
        ["codex-app-server"] = "Codex 服务连接",
        ["app-server-token-file"] = "服务凭据文件",
        ["runtime"] = "运行时配置",
        ["file_access"] = "目录访问权限",
    };

    public static string LocalizeDoctorCheckName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return "环境检查";
        }
        var trimmed = name.Trim();
        return DoctorCheckTitles.TryGetValue(trimmed, out var title) ? title : "其他诊断项";
    }

    public static string ScrubLogText(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return "";
        }
        // Only reconstruct known log metadata. Arbitrary subprocess prose can contain unmarked credentials.
        var lines = raw.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        var times = new List<DateTime>();
        foreach (var line in lines)
        {
            if (line.Length >= 19 && DateTime.TryParseExact(line.AsSpan(0, 19), "yyyy/MM/dd HH:mm:ss",
                CultureInfo.InvariantCulture, DateTimeStyles.None, out var timestamp))
            {
                times.Add(timestamp);
            }
        }
        return times.Count == 0
            ? string.Create(CultureInfo.InvariantCulture, $"读取到 {lines.Length} 行，本机日志正文已隐藏。")
            : string.Create(CultureInfo.InvariantCulture, $"读取到 {lines.Length} 行，记录时间 {times[0]:yyyy-MM-dd HH:mm:ss} 至 {times[^1]:yyyy-MM-dd HH:mm:ss}。本机日志正文已隐藏。");
    }
}
