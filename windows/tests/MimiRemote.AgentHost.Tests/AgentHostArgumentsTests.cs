using Xunit;

namespace MimiRemote.AgentHost.Tests;

public class AgentHostArgumentsTests
{
    [Fact]
    public void 解析空格分隔的日志路径()
    {
        var parsed = AgentHostArguments.TryParse(["--log-file", @"C:\logs\agentd.log"], out var options, out var error);

        Assert.True(parsed, error);
        Assert.Equal(@"C:\logs\agentd.log", options!.LogFile);
    }

    [Fact]
    public void 解析等号形式的日志路径()
    {
        var parsed = AgentHostArguments.TryParse([@"--log-file=C:\logs\agentd.log"], out var options, out var error);

        Assert.True(parsed, error);
        Assert.Equal(@"C:\logs\agentd.log", options!.LogFile);
    }

    [Fact]
    public void 允许路径里带空格()
    {
        var parsed = AgentHostArguments.TryParse(
            ["--log-file", @"C:\Program Files\Mimi Remote\agentd.log"],
            out var options,
            out var error);

        Assert.True(parsed, error);
        Assert.Equal(@"C:\Program Files\Mimi Remote\agentd.log", options!.LogFile);
    }

    [Fact]
    public void 去掉路径两端空白()
    {
        var parsed = AgentHostArguments.TryParse(["--log-file", "  C:\\a.log  "], out var options, out var error);

        Assert.True(parsed, error);
        Assert.Equal(@"C:\a.log", options!.LogFile);
    }

    [Fact]
    public void 拒绝空参数()
    {
        AssertRejected();
    }

    [Fact]
    public void 拒绝缺少路径的日志参数()
    {
        AssertRejected("--log-file");
    }

    [Fact]
    public void 拒绝空路径()
    {
        AssertRejected("--log-file", "");
    }

    [Fact]
    public void 拒绝空白路径()
    {
        AssertRejected("--log-file", "   ");
    }

    [Fact]
    public void 拒绝未知参数()
    {
        AssertRejected("--serve");
    }

    [Fact]
    public void 拒绝多余的值()
    {
        AssertRejected("--log-file", @"C:\a.log", "extra");
    }

    private static void AssertRejected(params string[] args)
    {
        Assert.False(AgentHostArguments.TryParse(args, out var options, out var error));
        Assert.Null(options);
        Assert.NotEmpty(error);
    }
}
