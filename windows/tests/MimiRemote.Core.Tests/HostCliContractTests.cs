using System.Text.Json;
using MimiRemote.Core;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class HostCliContractTests
{
    [Fact]
    public void 中转选择遵循共享确认与校验契约()
    {
        using var document = JsonDocument.Parse(ReadFixture("relay-cases.json"));
        foreach (var test in document.RootElement.EnumerateArray())
        {
            var choice = test.GetProperty("choice").GetString()!;
            var url = test.GetProperty("url").GetString()!;
            var current = test.GetProperty("current").Deserialize<TailcatStatus>(AgentClient.JsonOptions)!;
            Assert.Equal(test.GetProperty("needs_confirmation").GetBoolean(), RelayPolicy.NeedsConfirmation(choice, url, current));
            if (test.GetProperty("valid").GetBoolean())
            {
                Assert.Equal(["tailcat", "relay", "set", "--choice", choice, "--derp-map-url", url, "--json"], RelayPolicy.Arguments(choice, url));
            }
            else
            {
                Assert.Throws<ArgumentException>(() => RelayPolicy.Arguments(choice, url));
            }
        }
    }

    [Fact]
    public void 状态保留服务端版本并容忍未来字段()
    {
        var status = JsonSerializer.Deserialize<HostStatus>(ReadFixture("status-ready.json"), AgentClient.JsonOptions)!;
        Assert.True(status.ServiceOk);
        Assert.Equal("fixture-server", status.ServerVersion);
        Assert.Equal(3, status.Projects);
        Assert.Equal("codex", Assert.Single(status.RuntimeStatus!.Runtimes).Id);
    }

    private static string ReadFixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", name));
}
