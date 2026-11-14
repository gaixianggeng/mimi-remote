namespace MimiRemote.AgentHost;

/// <summary>
/// 宿主对外暴露的退出码。计划任务依赖这些值决定是否重试，
/// 所以除自定义码外，一律透传 agentd 自己的退出码。
/// </summary>
internal static class ExitCodes
{
    internal const int Usage = 64;
    internal const int MissingAgent = 69;
    internal const int LaunchFailed = 70;
}
