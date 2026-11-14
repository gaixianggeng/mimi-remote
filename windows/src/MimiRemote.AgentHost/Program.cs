namespace MimiRemote.AgentHost;

/// <summary>
/// 无窗口宿主：计划任务通过它启动 agentd。宿主自己不创建窗口、不写标准输出，
/// 只负责三件事——把 agentd 放进 kill-on-close 的 Job Object、用
/// <c>CREATE_NO_WINDOW</c> 拉起它、把它的退出码原样交回计划任务。
/// </summary>
internal static class Program
{
    private static int Main(string[] args)
    {
        if (!AgentHostArguments.TryParse(args, out var options, out var error))
        {
            AgentHostErrorLog.Write(error);
            return ExitCodes.Usage;
        }

        var agentPath = AgentHostPaths.ResolveAgentPath();
        if (!File.Exists(agentPath))
        {
            AgentHostErrorLog.Write($"找不到 agentd：{agentPath}");
            return ExitCodes.MissingAgent;
        }

        using var job = JobObject.TryCreate(out error);
        if (job is null)
        {
            AgentHostErrorLog.Write(error);
            return ExitCodes.LaunchFailed;
        }

        var commandLine = CommandLineBuilder.Build(
        [
            agentPath,
            "serve",
            "--managed-service",
            "--log-file",
            options!.LogFile,
        ]);

        using var process = SuspendedProcess.TryStart(agentPath, commandLine, out error);
        if (process is null)
        {
            AgentHostErrorLog.Write(error);
            return ExitCodes.LaunchFailed;
        }

        if (!job.TryAssign(process.ProcessHandle, out error))
        {
            process.Terminate();
            AgentHostErrorLog.Write(error);
            return ExitCodes.LaunchFailed;
        }

        if (!process.TryResume(out error))
        {
            process.Terminate();
            AgentHostErrorLog.Write(error);
            return ExitCodes.LaunchFailed;
        }

        if (!process.TryWaitForExit(out var exitCode, out error))
        {
            AgentHostErrorLog.Write(error);
            return ExitCodes.LaunchFailed;
        }

        return unchecked((int)exitCode);
    }
}
