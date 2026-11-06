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
