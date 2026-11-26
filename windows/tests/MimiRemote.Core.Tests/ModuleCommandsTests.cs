using System.Text.Json;
using MimiRemote.Core;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class ModuleCommandsTests
{
    [Fact]
    public async Task 运行态不匹配时恢复原事务并重新启动()
    {
        const string transaction = "{\"restart_required\":true,\"previous\":{\"enabled\":false},\"applied\":{\"enabled\":true}}";
        var agent = new FakeAgent((arguments, _) => arguments[0] switch
        {
            "status" => "{\"service_ok\":true,\"module_status\":{\"codex_enabled\":false}}",
            "runtime" when arguments.Length == 3 => transaction,
            _ => "{}",
        });
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => new ModuleCommands(agent).SetAsync("codex", true));
        Assert.Contains("已恢复", error.Message);
        Assert.Equal(5, agent.Calls.Count);
        Assert.Equal(["runtime", "--restore-codex", transaction, "--json"], agent.Calls[3]);
        Assert.Equal("restart", agent.Calls[4][0]);
    }

    [Fact]
    public async Task 服务确认模块生效后才返回成功()
    {
        var agent = new FakeAgent((arguments, _) => arguments[0] == "status"
            ? "{\"service_ok\":true,\"module_status\":{\"lan_enabled\":true}}"
            : "{\"restart_required\":true}");
        Assert.True((await new ModuleCommands(agent).SetAsync("lan", true)).ModuleStatus!.LanEnabled);
        Assert.Equal(["network", "--lan-enabled=true", "--json"], agent.Calls[0]);
        Assert.Equal(3, agent.Calls.Count);
    }

    [Fact]
    public async Task 恢复被并发修改拒绝时明确报告未恢复()
    {
        var agent = new FakeAgent((arguments, _) =>
        {
            if (arguments.Contains("--restore-claude")) { throw new InvalidOperationException("newer preference"); }
            return arguments[0] == "status" ? "{\"service_ok\":false}" : "{\"restart_required\":true}";
        });
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => new ModuleCommands(agent).SetAsync("claude", false));
        Assert.Contains("自动恢复也未完成", error.Message);
    }

    [Fact]
    public void 额度缺失不会显示为全部剩余()
    {
        var limits = JsonSerializer.Deserialize<RuntimeRateLimits>("{\"primary\":{\"used_percent\":124,\"window_duration_mins\":300},\"secondary\":{}}", AgentClient.JsonOptions)!;
        Assert.Equal(0, limits.Primary!.RemainingPercent);
        Assert.Null(limits.Secondary!.RemainingPercent);
    }

    [Fact]
    public async Task Agy独立启用与状态不匹配时执行专属回滚()
    {
        var okAgent = new FakeAgent((arguments, _) => arguments[0] == "status"
            ? "{\"service_ok\":true,\"module_status\":{\"claude_enabled\":false,\"agy_enabled\":true}}"
            : "{\"restart_required\":true}");
        var status = await new ModuleCommands(okAgent).SetAsync("agy", true);
        Assert.True(status.ModuleStatus!.AgyEnabled);
        Assert.False(status.ModuleStatus.ClaudeEnabled);
        Assert.Equal(["runtime", "--agy=enabled", "--json"], okAgent.Calls[0]);

        const string tx = "{\"restart_required\":true,\"previous\":{\"enabled\":false},\"applied\":{\"enabled\":true}}";
        var mismatchAgent = new FakeAgent((arguments, _) => arguments[0] switch
        {
            "status" => "{\"service_ok\":true,\"module_status\":{\"claude_enabled\":true,\"agy_enabled\":false}}",
            "runtime" when arguments.Length == 3 => tx,
            _ => "{}",
        });
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => new ModuleCommands(mismatchAgent).SetAsync("agy", true));
        Assert.Contains("已恢复", error.Message, StringComparison.Ordinal);
        Assert.Equal(["runtime", "--restore-agy", tx, "--json"], mismatchAgent.Calls[3]);
    }

    [Fact]
    public async Task 运行时路径固定与自动恢复遵循BE3参数契约()
    {
        var agent = new FakeAgent((_, _) => "{\"changed\":true,\"restart_required\":true}");
        var absPath = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "fake-agy.exe"));
        var restartNeeded = await new ModuleCommands(agent).SetRuntimePathAsync("agy", absPath);
        Assert.True(restartNeeded);
        Assert.Equal(["runtime", "--runtime-path", $"agy={absPath}", "--json"], agent.Calls[0]);

        await new ModuleCommands(agent).SetRuntimePathAsync("codex", "auto");
        Assert.Equal(["runtime", "--runtime-path", "codex=auto", "--json"], agent.Calls[1]);

        await Assert.ThrowsAsync<ArgumentException>(() => new ModuleCommands(agent).SetRuntimePathAsync("codex", "relative/codex.exe"));
        await Assert.ThrowsAsync<ArgumentException>(() => new ModuleCommands(agent).SetRuntimePathAsync("unknown", "auto"));
    }

    [Fact]
    public async Task 工作区更新按最小权限传递扫描和浏览目录()
    {
        var scan = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "mimi-scan"));
        var wider = Path.GetFullPath(Path.GetTempPath());
        var agent = new FakeAgent((arguments, _) => arguments[0] == "status"
            ? "{\"service_ok\":true}"
            : "{\"restart_required\":false}");

        await new ModuleCommands(agent).SetWorkspaceAsync(scan);
        Assert.Equal(["workspace", "--scan-root", scan, "--browse-root", scan, "--json"], agent.Calls[0]);

        await new ModuleCommands(agent).SetWorkspaceAsync(scan, null);
        Assert.Equal(["workspace", "--scan-root", scan, "--json"], agent.Calls[2]);

        await new ModuleCommands(agent).SetWorkspaceAsync(scan, wider);
        Assert.Equal(["workspace", "--scan-root", scan, "--browse-root", wider, "--json"], agent.Calls[4]);
    }

    private sealed class FakeAgent(Func<string[], string?, string> respond) : IAgentCommand
    {
        public List<string[]> Calls { get; } = [];
        public Task<string> RunAsync(string[] arguments, CancellationToken cancellationToken = default)
        {
            Calls.Add(arguments);
            return Task.FromResult(respond(arguments, null));
        }
        public Task<string> RunWithInputAsync(string[] arguments, string input, CancellationToken cancellationToken = default)
        {
            Calls.Add(arguments);
            return Task.FromResult(respond(arguments, input));
        }
    }
}
