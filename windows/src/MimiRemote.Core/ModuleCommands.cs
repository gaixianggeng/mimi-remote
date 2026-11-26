using System.Text.Json;

namespace MimiRemote.Core;

public interface IAgentCommand
{
    Task<string> RunAsync(string[] arguments, CancellationToken cancellationToken = default);
    Task<string> RunWithInputAsync(string[] arguments, string input, CancellationToken cancellationToken = default);
}

public sealed record ModuleStatus
{
    public bool CodexEnabled { get; init; }
    public bool ClaudeEnabled { get; init; }
    public bool AgyEnabled { get; init; }
    public bool TailscaleEnabled { get; init; }
    public bool LanEnabled { get; init; }
    public bool TailscaleAvailable { get; init; }
    public bool LanAvailable { get; init; }
}

public sealed record RuntimeRateLimits
{
    public string? Availability { get; init; }
    public string? UnavailableReason { get; init; }
    public string? PlanType { get; init; }
    public RateLimitWindow? Primary { get; init; }
    public RateLimitWindow? Secondary { get; init; }
    public string? CreditBalance { get; init; }
}

public sealed record RateLimitWindow
{
    public double? UsedPercent { get; init; }
    public long? WindowDurationMins { get; init; }
    public long? ResetsAt { get; init; }
    public double? RemainingPercent => UsedPercent is double used && double.IsFinite(used) ? Math.Clamp(100 - used, 0, 100) : null;
    public string Duration => WindowDurationMins is not > 0 ? "额度窗口" : WindowDurationMins % 60 == 0 ? $"{WindowDurationMins / 60} 小时" : $"{WindowDurationMins} 分钟";
}

/// <summary>CLI-owned mutations, restart/readback and guarded rollback shared by the UI.</summary>
public sealed class ModuleCommands(IAgentCommand agent)
{
    public async Task<HostStatus> SetAsync(string module, bool enabled, CancellationToken token = default)
    {
        string[] arguments = module switch
        {
            "codex" or "claude" or "agy" => ["runtime", $"--{module}=" + (enabled ? "enabled" : "disabled"), "--json"],
            "tailscale" or "lan" => ["network", $"--{module}-enabled={enabled.ToString().ToLowerInvariant()}", "--json"],
            _ => throw new ArgumentException("未知模块。", nameof(module)),
        };
        var restore = module is "codex" or "claude" or "agy" ? $"--restore-{module}" : "--restore-state";
        return await ApplyAsync(arguments, [arguments[0], restore], status => status.ModuleStatus is { } applied && module switch
        {
            "codex" => applied.CodexEnabled == enabled,
            "claude" => applied.ClaudeEnabled == enabled,
            "agy" => applied.AgyEnabled == enabled,
            "lan" => applied.LanEnabled == enabled,
            _ => applied.TailscaleEnabled == enabled,
        }, token).ConfigureAwait(false);
    }

    public async Task<bool> SetRuntimePathAsync(string runtimeId, string value, bool restartIfRequired = false, CancellationToken token = default)
    {
        if (runtimeId is not ("codex" or "claude" or "agy"))
        {
            throw new ArgumentException("未知助手标识。", nameof(runtimeId));
        }
        var trimmed = value?.Trim() ?? "";
        if (!string.Equals(trimmed, "auto", StringComparison.Ordinal) && !Path.IsPathFullyQualified(trimmed))
        {
            throw new ArgumentException("请选择程序的绝对路径，或使用自动检测。", nameof(value));
        }
        var result = await agent.RunAsync(["runtime", "--runtime-path", $"{runtimeId}={trimmed}", "--json"], token).ConfigureAwait(false);
        using var document = JsonDocument.Parse(result);
        var restartRequired = document.RootElement.TryGetProperty("restart_required", out var prop)
            && prop.ValueKind == JsonValueKind.True;
        if (restartRequired && restartIfRequired)
        {
            await agent.RunAsync(["restart", "--wait", "60s", "--no-pair"], token).ConfigureAwait(false);
        }
        return restartRequired;
    }

    public Task<HostStatus> SetWorkspaceAsync(string root, CancellationToken token = default) =>
        SetWorkspaceAsync(root, root, token);

    public Task<HostStatus> SetWorkspaceAsync(string scanRoot, string? browseRoot, CancellationToken token = default) =>
        ApplyAsync(WorkspaceArguments(scanRoot, browseRoot, primaryOnly: false), ["workspace", "--restore-state"], _ => true, token);

    public Task<HostStatus> SetBrowseRootAsync(string browseRoot, bool preserveAdditionalRoots, CancellationToken token = default)
    {
        var path = FullBrowseRoot(browseRoot);
        string[] arguments = preserveAdditionalRoots
            ? ["workspace", "--primary", "--browse-root", path, "--json"]
            : ["workspace", "--set-browse-root", path, "--json"];
        return ApplyAsync(arguments, ["workspace", "--restore-state"], _ => true, token);
    }

    private static string FullBrowseRoot(string browseRoot) =>
        Path.IsPathFullyQualified(browseRoot)
            ? Path.GetFullPath(browseRoot)
            : throw new ArgumentException("请选择完整的浏览目录路径。", nameof(browseRoot));

    private static string[] WorkspaceArguments(string scanRoot, string? browseRoot, bool primaryOnly)
    {
        if (!Path.IsPathFullyQualified(scanRoot))
        {
            throw new ArgumentException("请选择完整的代码目录路径。", nameof(scanRoot));
        }
        var arguments = new List<string> { "workspace" };
        if (primaryOnly)
        {
            arguments.Add("--primary");
        }
        arguments.Add("--scan-root");
        arguments.Add(Path.GetFullPath(scanRoot));
        if (!string.IsNullOrWhiteSpace(browseRoot))
        {
            arguments.Add("--browse-root");
            arguments.Add(FullBrowseRoot(browseRoot));
        }
        arguments.Add("--json");
        return [.. arguments];
    }

    public async Task<bool> UpdateWorkspaceConfigAsync(string scanRoot, string? browseRoot, CancellationToken token = default)
    {
        var result = await agent.RunAsync(WorkspaceArguments(scanRoot, browseRoot, primaryOnly: true), token).ConfigureAwait(false);
        try
        {
            using var document = JsonDocument.Parse(result);
            if (document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("restart_required", out var prop)
                && prop.ValueKind is JsonValueKind.True or JsonValueKind.False)
            {
                return prop.GetBoolean();
            }
        }
        catch (JsonException error)
        {
            throw new InvalidDataException("无法确认代码目录更新结果。", error);
        }
        throw new InvalidDataException("目录更新结果缺少有效的重启标记。");
    }

    private async Task<HostStatus> ApplyAsync(string[] arguments, string[] restore, Func<HostStatus, bool> verify, CancellationToken token)
    {
        var result = await agent.RunAsync(arguments, token).ConfigureAwait(false);
        using var document = JsonDocument.Parse(result);
        try
        {
            if (document.RootElement.GetProperty("restart_required").GetBoolean())
            {
                await agent.RunAsync(["restart", "--wait", "60s", "--no-pair"], token).ConfigureAwait(false);
            }
            var status = await ReadStatusAsync(token).ConfigureAwait(false);
            if (!status.ServiceOk || !verify(status)) { throw new InvalidOperationException("服务尚未应用新的设置。"); }
            return status;
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException or IOException or TimeoutException or OperationCanceledException
            or JsonException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        {
            // User cancellation does not cancel the bounded recovery operation.
            using var recovery = new CancellationTokenSource(TimeSpan.FromSeconds(90));
            try
            {
                await agent.RunAsync([.. restore, result, "--json"], recovery.Token).ConfigureAwait(false);
                await agent.RunAsync(["restart", "--wait", "60s", "--no-pair"], recovery.Token).ConfigureAwait(false);
            }
            catch (Exception failure) when (failure is InvalidOperationException or InvalidDataException or IOException or TimeoutException or OperationCanceledException
                or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
            {
                throw new InvalidOperationException("新设置未生效，自动恢复也未完成。请刷新并运行诊断，勿重复切换。", failure);
            }
            throw new InvalidOperationException("新设置未生效，已恢复先前配置。请刷新后重试。", error);
        }
    }

    public async Task<HostStatus> ReadStatusAsync(CancellationToken token = default) =>
        JsonSerializer.Deserialize<HostStatus>(await agent.RunAsync(["status", "--json", "--runtime"], token).ConfigureAwait(false), AgentClient.JsonOptions)
        ?? throw new InvalidDataException("服务返回空状态。");
}
