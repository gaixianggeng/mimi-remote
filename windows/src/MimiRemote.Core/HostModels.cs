using System.Text.Json.Serialization;

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
    public string ProcessError { get; init; } = "";
    public string ServiceError { get; init; } = "";
    public RuntimeStatus? RuntimeStatus { get; init; }
    public ModuleStatus? ModuleStatus { get; init; }
    public string Title => ServiceOk ? "电脑已就绪" : ProcessOk ? "服务需要处理" : "服务已停止";
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
    public string PairUrl { get; init; } = "";
    public string PairExpiresAt { get; init; } = "";
    public string Endpoint { get; init; } = "";
    public string[] Warnings { get; init; } = [];
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
