using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

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
        var installed = FindInstallDirectory();
        var defaultInstall = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Mimi Remote");
        string[] candidates =
        [
            Path.Combine(installed ?? defaultInstall, "agentd.exe"),
            Path.Combine(defaultInstall, "agentd.exe"),
            Path.Combine(AppContext.BaseDirectory, "agentd.exe"),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "agentd.exe")),
        ];
        return candidates.FirstOrDefault(File.Exists)
            ?? throw new FileNotFoundException("未找到 agentd.exe。请先安装 Mimi Remote 电脑端，然后重新打开此窗口。");
    }

    private static string? FindInstallDirectory()
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }
        // Use the installed CLI for service operations so PID and firewall path checks match the scheduled task.
        const string uninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{7D413E71-19C5-4F02-8AFC-437E1B8019FD}_is1";
        using var key = Registry.CurrentUser.OpenSubKey(uninstallKey);
        var path = key?.GetValue("InstallLocation") as string;
        return Path.IsPathFullyQualified(path ?? "") ? path : null;
    }

    public static string[] PreflightArguments(OnboardingPreflightOptions options)
    {
        var args = new List<string> { "preflight", "--json", "--stage", options.Stage };
        if (!string.IsNullOrWhiteSpace(options.ConfigPath))
        {
            args.Add("--config");
            args.Add(options.ConfigPath);
        }
        if (!string.IsNullOrWhiteSpace(options.ScanRoot))
        {
            args.Add("--scan-root");
            args.Add(options.ScanRoot);
        }
        if (!string.IsNullOrWhiteSpace(options.BrowseRoot))
        {
            args.Add("--browse-root");
            args.Add(options.BrowseRoot);
        }
        if (options.ProgressJson)
        {
            args.Add("--progress-json");
        }
        foreach (var (id, value) in options.RuntimePaths)
        {
            args.Add("--runtime-path");
            args.Add($"{id}={value}");
        }
        foreach (var (id, value) in options.Assistants)
        {
            args.Add("--assistant");
            args.Add($"{id}={value}");
        }
        return [.. args];
    }

    public static string[] SetupArguments(string scanRoot, OnboardingSetupOptions? options = null)
    {
        var opts = options ?? new OnboardingSetupOptions();
        var browseRoot = string.IsNullOrWhiteSpace(opts.BrowseRoot) ? scanRoot : opts.BrowseRoot;
        var args = new List<string> { "setup", "--json" };
        if (opts.NoPair)
        {
            args.Add("--no-pair");
        }
        else
        {
            args.Add("--qr-only");
        }
        args.Add("--scan-root");
        args.Add(scanRoot);
        args.Add("--browse-root");
        args.Add(browseRoot);
        foreach (var (id, value) in opts.RuntimePaths)
        {
            args.Add("--runtime-path");
            args.Add($"{id}={value}");
        }
        foreach (var (id, value) in opts.Assistants)
        {
            args.Add("--assistant");
            args.Add($"{id}={value}");
        }
        return [.. args];
    }

    public static string[] UpArguments(int waitSeconds = 60) =>
        ["up", "--no-pair", "--json", "--wait", string.Create(CultureInfo.InvariantCulture, $"{waitSeconds}s")];

    public static string[] PairArguments(string network) =>
        string.Equals(network, "tailcat", StringComparison.Ordinal)
            ? ["tailcat", "pair", "--qr-only", "--json"]
            : ["pair", "--network", network, "--qr-only", "--json"];

    public async Task<OnboardingPreflightReport> PreflightAsync(
        OnboardingPreflightOptions options,
        Action<OnboardingCheck>? onProgress = null,
        string platform = "windows",
        CancellationToken cancellationToken = default)
    {
        var arguments = PreflightArguments(options);
        Action<string>? stderrLine = null;
        if (options.ProgressJson && onProgress is not null)
        {
            stderrLine = line =>
            {
                if (OnboardingCopyCatalog.TryDecodeCheck(line, out var check, out _))
                {
                    onProgress(check);
                }
            };
        }
        var stdout = await RunCoreAsync(
            arguments,
            allowFailure: false,
            input: null,
            onStderrLine: stderrLine,
            platform: platform,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!OnboardingCopyCatalog.TryDecodeAndValidateReport(
            stdout,
            platform,
            nativeOverlay: false,
            verifiedCapability: null,
            out var report,
            out var error))
        {
            throw new InvalidDataException($"无法解析预检报告：{error}");
        }
        return report;
    }

    public async Task<SetupReceipt> SetupAsync(
        string scanRoot,
        OnboardingSetupOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var stdout = await RunAsync(SetupArguments(scanRoot, options), cancellationToken).ConfigureAwait(false);
        if (!OnboardingCopyCatalog.TryDecodeSetupReceipt(stdout, out var receipt, out var error))
        {
            throw new InvalidDataException($"无法解析首次设置结果：{error}");
        }
        return receipt;
    }

    public async Task<UpReadinessReceipt> UpAsync(int waitSeconds = 60, CancellationToken cancellationToken = default)
    {
        var stdout = await RunAsync(UpArguments(waitSeconds), cancellationToken).ConfigureAwait(false);
        if (!OnboardingCopyCatalog.TryDecodeUpReadinessReceipt(stdout, out var receipt, out var error))
        {
            throw new InvalidDataException($"后台服务尚未确认就绪：{error}");
        }
        return receipt;
    }

    public async Task<PairingTicketReceipt> PairAsync(string network, CancellationToken cancellationToken = default)
    {
        var stdout = await RunAsync(PairArguments(network), cancellationToken).ConfigureAwait(false);
        if (!OnboardingCopyCatalog.TryDecodePairingTicketReceipt(stdout, requireNetwork: false, out var receipt, out var error))
        {
            throw new InvalidDataException($"无法解析配对票据：{error}");
        }
        return receipt;
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
        RunCoreAsync(arguments, allowFailure, null, null, "windows", cancellationToken);

    public Task<string> RunWithInputAsync(string[] arguments, string input, CancellationToken cancellationToken = default) =>
        RunCoreAsync(arguments, false, input, null, "windows", cancellationToken);

    private async Task<string> RunCoreAsync(
        string[] arguments,
        bool allowFailure,
        string? input,
        Action<string>? onStderrLine,
        string platform,
        CancellationToken cancellationToken)
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
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        using var process = new Process { StartInfo = start };
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(OnboardingTimeouts.ForArguments(arguments));
        process.Start();
        // Drain both pipes concurrently, retaining at most 1 MiB per stream.
        var stdout = ReadBoundedAsync(process.StandardOutput, null, timeout.Token);
        var stderr = ReadBoundedAsync(process.StandardError, onStderrLine, timeout.Token);
        try
        {
            if (input is not null)
            {
                await process.StandardInput.WriteAsync(input.AsMemory(), timeout.Token).ConfigureAwait(false);
            }
            process.StandardInput.Close();
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            var output = await stdout.ConfigureAwait(false);
            var error = await stderr.ConfigureAwait(false);
            if (process.ExitCode != 0 && !allowFailure)
            {
                var stage = ResolveStage(arguments);
                var context = new OnboardingValidationContext
                {
                    Surface = "cli",
                    Platform = platform,
                    Stage = stage,
                    Configured = true,
                };
                if (OnboardingCopyCatalog.ResolveCliError(output, error, context) is { } resolved)
                {
                    throw new OnboardingCliException(resolved);
                }
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(error)
                    ? $"电脑服务未能完成操作（退出码 {process.ExitCode}）。请运行诊断。" : error.Trim());
            }
            return string.IsNullOrWhiteSpace(output) ? error : output;
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
            try
            {
                await Task.WhenAll(stdout, stderr).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
            if (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            throw new TimeoutException("电脑服务响应超时。请刷新状态，确认操作是否已经生效。");
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
    }

    private static async Task<string> ReadBoundedAsync(
        StreamReader reader,
        Action<string>? onLine,
        CancellationToken token)
    {
        const int limit = 1_048_576;
        var text = new StringBuilder();
        var lineBuffer = onLine is not null ? new StringBuilder() : null;
        var buffer = new char[4096];
        var total = 0;
        int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false)) != 0)
        {
            total += count;
            var retained = Math.Min(count, limit - text.Length);
            if (retained > 0)
            {
                text.Append(buffer, 0, retained);
            }
            if (onLine is not null && lineBuffer is not null && total <= limit)
            {
                for (var i = 0; i < count; i++)
                {
                    var ch = buffer[i];
                    if (ch == '\n')
                    {
                        if (lineBuffer.Length > 0 && lineBuffer[^1] == '\r')
                        {
                            lineBuffer.Length--;
                        }
                        onLine(lineBuffer.ToString());
                        lineBuffer.Clear();
                    }
                    else
                    {
                        lineBuffer.Append(ch);
                    }
                }
            }
        }
        if (onLine is not null && lineBuffer is not null && lineBuffer.Length > 0 && total <= limit)
        {
            if (lineBuffer[^1] == '\r')
            {
                lineBuffer.Length--;
            }
            onLine(lineBuffer.ToString());
        }
        return text.ToString();
    }

    private static string ResolveStage(string[] arguments)
    {
        if (arguments.Length > 0
            && (string.Equals(arguments[0], "setup", StringComparison.Ordinal)
                || string.Equals(arguments[0], "preflight", StringComparison.Ordinal)))
        {
            return "setup";
        }
        return "pair";
    }
}
