using System.Text;

namespace MimiRemote.AgentHost;

/// <summary>
/// 宿主没有控制台，失败原因只能落到文件里。每次覆盖写，并且限制在 4 KiB 以内，
/// 避免计划任务按分钟重试时把磁盘写满。这里只写宿主自己的诊断，不接触任何凭据。
/// </summary>
internal static class AgentHostErrorLog
{
    private const int MaxCharacters = 1024;

    internal static void Write(string message)
    {
        try
        {
            var path = AgentHostPaths.ResolveErrorLogPath();
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);

            var line = $"{DateTimeOffset.UtcNow:yyyy-MM-ddTHH:mm:ssZ} {Truncate(message)}{Environment.NewLine}";
            File.WriteAllText(path, line, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }
        catch (IOException)
        {
            // 诊断写入失败不能反过来改变宿主的退出码。
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static string Truncate(string value)
    {
        return value.Length <= MaxCharacters ? value : value[..MaxCharacters];
    }
}
