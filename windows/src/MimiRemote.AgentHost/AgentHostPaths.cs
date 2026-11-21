namespace MimiRemote.AgentHost;

/// <summary>
/// 路径规则与 agentd 的 <c>windowsManagedRuntimePath</c> 保持一致：
/// 优先读 <c>LOCALAPPDATA</c>，缺失时才回退到系统查询到的用户本地目录。
/// </summary>
internal static class AgentHostPaths
{
    private const string ProductDirectoryName = "Mimi Remote";
    private const string AgentFileName = "agentd.exe";
    private const string ErrorLogFileName = "agent-host.last-error.log";

    internal static string ResolveAgentPath()
    {
        return Path.Combine(AppContext.BaseDirectory, AgentFileName);
    }

    internal static string ResolveErrorLogPath()
    {
        var localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        }

        return Path.Combine(localAppData, ProductDirectoryName, ErrorLogFileName);
    }
}
