#if DEBUG
using MimiRemote.Core;

namespace MimiRemote.App;

internal static class PreviewData
{
    public static HostStatus Host => new()
    {
        Version = "0.0.0-preview",
        Projects = 4,
        ServiceOk = true,
        ProcessOk = true,
        ModuleStatus = new ModuleStatus { CodexEnabled = true, ClaudeEnabled = true, TailscaleEnabled = true, LanEnabled = true },
        RuntimeStatus = new RuntimeStatus
        {
            Runtimes = [
            new RuntimeEntry { Id = "codex", Title = "Codex", Enabled = true, State = "ready" },
            new RuntimeEntry { Id = "claude", Title = "Claude", Enabled = true, State = "ready" }]
        }
    };
}
internal sealed class PreviewSessionSource : IDesktopSessionSource
{
    public Task<SessionCatalog> CatalogAsync(CancellationToken token) => Task.FromResult(new SessionCatalog(
        ["codex", "claude", "deepseek"], [new("mimi-remote", @"C:\Preview\mimi-remote"), new("desktop-client", @"C:\Preview\desktop-client")]));
    public Task<DesktopSessionPage> ListAsync(string runtime, string? cwd, int pageBudget, CancellationToken token)
    {
        var now = DateTimeOffset.Now;
        var title = runtime switch { "codex" => "优化工作区会话加载", "claude" => "检查 Windows 安装流程", _ => "整理接口错误提示" };
        var project = runtime == "claude" ? "desktop-client" : "mimi-remote";
        var directory = @"C:\Preview\" + project;
        var entries = new[] {
            new DesktopSession(runtime, "preview-1", title, project, directory, now.AddMinutes(-2),
                runtime == "codex" ? SessionActivity.Running : runtime == "claude" ? SessionActivity.WaitingForApproval : SessionActivity.Idle),
            new DesktopSession(runtime, "preview-2", "补充服务诊断说明", project, directory, now.AddDays(-1),
                runtime == "claude" ? SessionActivity.Failed : SessionActivity.Idle),
        };
        return Task.FromResult(new DesktopSessionPage(entries.Where(row => cwd is null || row.Cwd == cwd).ToArray(), false));
    }
}
#endif
