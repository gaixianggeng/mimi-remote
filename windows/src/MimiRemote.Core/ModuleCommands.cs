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
            "codex" or "claude" => ["runtime", $"--{module}=" + (enabled ? "enabled" : "disabled"), "--json"],
            "tailscale" or "lan" => ["network", $"--{module}-enabled={enabled.ToString().ToLowerInvariant()}", "--json"],
            _ => throw new ArgumentException("未知模块。", nameof(module)),
        };
        var restore = module is "codex" or "claude" ? $"--restore-{module}" : "--restore-state";
        return await ApplyAsync(arguments, [arguments[0], restore], status => status.ModuleStatus is { } applied && module switch
        {
            "codex" => applied.CodexEnabled == enabled,
            "claude" => applied.ClaudeEnabled == enabled,
            "lan" => applied.LanEnabled == enabled,
            _ => applied.TailscaleEnabled == enabled,
        }, token).ConfigureAwait(false);
    }

    public Task<HostStatus> SetWorkspaceAsync(string root, CancellationToken token = default) =>
        ApplyAsync(["workspace", "--root", Path.GetFullPath(root), "--json"], ["workspace", "--restore-state"], _ => true, token);

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
        catch (Exception error) when (error is InvalidOperationException or IOException or TimeoutException or OperationCanceledException
            or JsonException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        {
            // User cancellation does not cancel the bounded recovery operation.
            using var recovery = new CancellationTokenSource(TimeSpan.FromSeconds(90));
            try
            {
                await agent.RunAsync([.. restore, result, "--json"], recovery.Token).ConfigureAwait(false);
                await agent.RunAsync(["restart", "--wait", "60s", "--no-pair"], recovery.Token).ConfigureAwait(false);
            }
            catch (Exception failure) when (failure is InvalidOperationException or IOException or TimeoutException or OperationCanceledException
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
