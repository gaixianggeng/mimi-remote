using Xunit;

namespace MimiRemote.AgentHost.Tests;

/// <summary>
/// 命令行拼装的防回归测试。
///
/// 普通参数按 Windows CRT 的引号和反斜杠规则转义。运行时测试另用真实 Go
/// fakeagentd 验证完整命令行，避免把 argv[0] 的特殊解析规则用于普通参数。
/// </summary>
public class CommandLineBuilderTests
{
    [Fact]
    public void 含空格的路径加引号()
    {
        Assert.Equal(
            "\"C:\\Program Files\\Mimi Remote\\agentd.log\"",
            CommandLineBuilder.Build([@"C:\Program Files\Mimi Remote\agentd.log"]));
    }

    [Fact]
    public void 含空格且结尾反斜杠时加倍()
    {
        Assert.Equal("\"C:\\dir x\\\\\"", CommandLineBuilder.Build(["C:\\dir x\\"]));
    }

    [Fact]
    public void 引号被反斜杠转义()
    {
        Assert.Equal("\"C:\\quote\\\"inside\\x.log\"", CommandLineBuilder.Build(["C:\\quote\"inside\\x.log"]));
    }

    [Fact]
    public void 空参数写成一对引号()
    {
        Assert.Equal("\"\"", CommandLineBuilder.Build([""]));
    }

    [Fact]
    public void 无特殊字符时原样输出()
    {
        Assert.Equal("serve --managed-service", CommandLineBuilder.Build(["serve", "--managed-service"]));
    }

    [Fact]
    public void 中文路径不含空格时原样输出()
    {
        Assert.Equal(@"C:\用户\日志\agentd.log", CommandLineBuilder.Build([@"C:\用户\日志\agentd.log"]));
    }

    [Fact]
    public void 中文路径含空格时加引号()
    {
        Assert.Equal("\"C:\\我的 文档\\agentd.log\"", CommandLineBuilder.Build(["C:\\我的 文档\\agentd.log"]));
    }

    [Fact]
    public void 多个参数用单个空格分隔()
    {
        Assert.Equal(
            "\"C:\\Program Files\\Mimi Remote\\agentd.exe\" serve --managed-service --log-file \"C:\\a b\\c.log\"",
            CommandLineBuilder.Build(
            [
                @"C:\Program Files\Mimi Remote\agentd.exe",
                "serve",
                "--managed-service",
                "--log-file",
                @"C:\a b\c.log",
            ]));
    }
}
