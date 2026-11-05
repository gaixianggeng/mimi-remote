using Xunit;

namespace MimiRemote.AgentHost.Tests;

/// <summary>
/// 命令行拼装的防回归测试。
///
/// 目标程序是 Go 写的 agentd。Go 在 Windows 上的 <c>os.Args</c> 使用 CR 运行库规则：
/// <c>\"</c> 表示字面引号，引号内结尾的反斜杠要成对。注意这**不等于**
/// <c>CommandLineToArgvW</c> 的实际行为——实测该 API 不把反斜杠当转义符，
/// 用它做基准会得到错误结论。下列期望值已用真实 Go 程序逐一验证：
///
/// | 拼出的命令行                     | Go 收到的参数            |
/// | -------------------------------- | ------------------------ |
/// | "C:\Program Files\a.log"         | C:\Program Files\a.log   |
/// | "C:\dir x\\"                     | C:\dir x\                |
/// | "C:\quote\"inside\x.log"         | C:\quote"inside\x.log    |
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
