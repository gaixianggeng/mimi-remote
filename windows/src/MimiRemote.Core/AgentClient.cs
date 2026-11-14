using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace MimiRemote.Core;

/// <summary>All commands go directly to agentd; no shell or terminal is involved.</summary>
public sealed class AgentClient(string executable) : IAgentCommand
{
    public static JsonSerializerOptions JsonOptions { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
    };

    public static string FindExecutable()
    {
        string[] candidates =
        [
            Path.Combine(AppContext.BaseDirectory, "agentd.exe"),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "agentd.exe")),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs", "Mimi Remote", "agentd.exe"),
        ];
        return candidates.FirstOrDefault(File.Exists)
            ?? throw new FileNotFoundException("未找到 agentd.exe。请先安装 Mimi Remote 电脑端，然后重新打开此窗口。");
    }

    public async Task<T> ReadAsync<T>(string[] arguments, CancellationToken cancellationToken = default)
    {
        var result = await RunAsync(arguments, cancellationToken).ConfigureAwait(false);
        return JsonSerializer.Deserialize<T>(result, JsonOptions)
            ?? throw new InvalidDataException("电脑服务返回了空数据，请刷新重试。");
    }

    public Task<string> RunAsync(string[] arguments, CancellationToken cancellationToken = default) =>
        RunAsync(arguments, false, cancellationToken);

    public Task<string> RunAsync(string[] arguments, bool allowFailure, CancellationToken cancellationToken = default) =>
        RunCoreAsync(arguments, allowFailure, null, cancellationToken);

    public Task<string> RunWithInputAsync(string[] arguments, string input, CancellationToken cancellationToken = default) =>
        RunCoreAsync(arguments, false, input, cancellationToken);

    private async Task<string> RunCoreAsync(string[] arguments, bool allowFailure, string? input, CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        foreach (var argument in arguments) { start.ArgumentList.Add(argument); }
        using var process = new Process { StartInfo = start };
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(90));
        process.Start();
        // Drain both pipes concurrently, retaining at most 1 MiB per stream.
        var stdout = ReadBoundedAsync(process.StandardOutput, timeout.Token);
        var stderr = ReadBoundedAsync(process.StandardError, timeout.Token);
        try
        {
            if (input is not null) { await process.StandardInput.WriteAsync(input.AsMemory(), timeout.Token).ConfigureAwait(false); }
            process.StandardInput.Close();
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            var output = await stdout.ConfigureAwait(false);
            var error = await stderr.ConfigureAwait(false);
            if (process.ExitCode != 0 && !allowFailure)
            {
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(error)
                    ? $"电脑服务未能完成操作（退出码 {process.ExitCode}）。请运行诊断。" : error.Trim());
            }
            return string.IsNullOrWhiteSpace(output) ? error : output;
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) { process.Kill(entireProcessTree: true); }
            try { await Task.WhenAll(stdout, stderr).ConfigureAwait(false); }
            catch (OperationCanceledException) { }
            if (cancellationToken.IsCancellationRequested) { throw; }
            throw new TimeoutException("电脑服务响应超时。请刷新状态，确认操作是否已经生效。");
        }
        finally
        {
            if (!process.HasExited) { process.Kill(entireProcessTree: true); }
        }
    }

    private static async Task<string> ReadBoundedAsync(StreamReader reader, CancellationToken token)
    {
        const int limit = 1_048_576;
        var text = new StringBuilder();
        var buffer = new char[4096];
        int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false)) != 0)
        {
            var retained = Math.Min(count, limit - text.Length);
            if (retained > 0) { text.Append(buffer, 0, retained); }
        }
        return text.ToString();
    }
}
