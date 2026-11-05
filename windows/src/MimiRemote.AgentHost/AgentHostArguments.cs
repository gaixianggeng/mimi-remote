namespace MimiRemote.AgentHost;

/// <summary>
/// 宿主只接受一个参数：<c>--log-file &lt;路径&gt;</c>。计划任务是宿主唯一的调用方，
/// 多出来的参数一律视为配置错误，而不是猜测意图后继续启动服务。
/// </summary>
internal sealed record AgentHostArguments(string LogFile)
{
    private const string LogFileOption = "--log-file";

    internal static bool TryParse(string[] args, out AgentHostArguments? parsed, out string error)
    {
        ArgumentNullException.ThrowIfNull(args);

        parsed = null;
        error = string.Empty;

        if (args.Length == 0)
        {
            error = $"缺少参数 {LogFileOption} <路径>";
            return false;
        }

        string? logFile = null;

        for (var index = 0; index < args.Length; index++)
        {
            var argument = args[index];

            if (logFile is not null)
            {
                error = "只接受一个参数，收到多余的值：" + argument;
                return false;
            }

            if (string.Equals(argument, LogFileOption, StringComparison.Ordinal))
            {
                if (index + 1 >= args.Length)
                {
                    error = $"{LogFileOption} 缺少路径";
                    return false;
                }

                logFile = args[index + 1];
                index++;
                continue;
            }

            if (argument.StartsWith(LogFileOption + "=", StringComparison.Ordinal))
            {
                logFile = argument[(LogFileOption.Length + 1)..];
                continue;
            }

            error = "未知参数：" + argument;
            return false;
        }

        if (string.IsNullOrWhiteSpace(logFile))
        {
            error = $"{LogFileOption} 的路径为空";
            return false;
        }

        parsed = new AgentHostArguments(logFile.Trim());
        return true;
    }
}
