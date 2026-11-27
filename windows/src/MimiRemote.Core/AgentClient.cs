using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace MimiRemote.Core;

/// <summary>All commands go directly to agentd; no shell or terminal is involved.</summary>
public sealed class AgentClient(string executable, MaintenanceRejectionLatch? rejectionLatch = null) : IAgentCommand
{
    public static JsonSerializerOptions JsonOptions { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
    };

    public static string FindExecutable()
    {
        var candidateDir = ResolveCandidateInstallDirectory(
            FindInstallDirectory(),
            DefaultInstallDirectory(),
            AppContext.BaseDirectory,
            File.Exists,
            fallbackWhenMissing: false);
        return candidateDir is not null
            ? Path.Combine(candidateDir, WindowsMaintenanceClient.BrokerRole)
            : throw new FileNotFoundException("未找到 agentd.exe。请先安装 Mimi Remote 电脑端，然后重新打开此窗口。");
    }

    /// <summary>
    /// Discovers the active Windows installation directory using the same
    /// candidate sources as ordinary WinUI operations. The returned directory
    /// is strictly an untrusted candidate and must pass full receipt,
    /// publisher, version, reparse-point, and pinned-image checks before
    /// executing maintenance.
    /// </summary>
    public static string? FindCandidateInstallDirectory() =>
        ResolveCandidateInstallDirectory(
            FindInstallDirectory(),
            DefaultInstallDirectory(),
            AppContext.BaseDirectory,
            File.Exists,
            fallbackWhenMissing: true);

    internal static string DefaultInstallDirectory() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Mimi Remote");

    internal static string? ResolveCandidateInstallDirectory(
        string? registryInstallLocation,
        string defaultInstallDirectory,
        string appBaseDirectory,
        Func<string, bool> fileExists,
        bool fallbackWhenMissing = true)
    {
        ArgumentNullException.ThrowIfNull(fileExists);
        var normalizedRegistry = NormalizeLocalCandidateDirectory(registryInstallLocation);
        var normalizedDefault = NormalizeLocalCandidateDirectory(defaultInstallDirectory);
        var normalizedBase = NormalizeLocalCandidateDirectory(appBaseDirectory);
        var normalizedParent = NormalizeLocalCandidateDirectory(GetParentDirectory(appBaseDirectory));
        string?[] candidateDirs =
        [
            normalizedRegistry,
            normalizedDefault,
            normalizedBase,
            normalizedParent,
        ];
        foreach (var dir in candidateDirs)
        {
            if (dir is not null && fileExists(Path.Combine(dir, WindowsMaintenanceClient.BrokerRole)))
            {
                return dir;
            }
        }
        return fallbackWhenMissing ? normalizedRegistry ?? normalizedDefault : null;
    }

    private static string? GetParentDirectory(string? directory)
    {
        if (string.IsNullOrWhiteSpace(directory))
        {
            return null;
        }
        var trimmed = directory.Trim().TrimEnd('\\', '/');
        if (string.IsNullOrEmpty(trimmed))
        {
            return null;
        }
        try
        {
            return Path.GetFullPath(Path.Combine(trimmed, ".."));
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }
    }

    private static string? NormalizeLocalCandidateDirectory(string? rawPath)
    {
        if (string.IsNullOrWhiteSpace(rawPath))
        {
            return null;
        }
        var trimmed = rawPath.Trim().TrimEnd('\\', '/');
        if (string.IsNullOrEmpty(trimmed))
        {
            return null;
        }
        // Reject UNC/network paths (\\server\share) before probing the filesystem.
        if (trimmed.StartsWith(@"\\?\Volume{", StringComparison.OrdinalIgnoreCase))
        {
            return trimmed.IndexOf('\\', 4) > 0 ? trimmed : null;
        }
        if (trimmed.Length >= 3
            && char.IsAsciiLetter(trimmed[0])
            && trimmed[1] == ':'
            && (trimmed[2] == '\\' || trimmed[2] == '/'))
        {
            return trimmed;
        }
        return null;
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
        return NormalizeLocalCandidateDirectory(path);
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
        if (!string.Equals(options.Stage, "setup", StringComparison.Ordinal)
            && !string.Equals(options.Stage, "pair", StringComparison.Ordinal))
        {
            throw new ArgumentException($"Unsupported preflight stage '{options.Stage}'.", nameof(options));
        }
        var verifiedConfigured = options.VerifiedConfigured ?? false;
        var progressContext = new OnboardingValidationContext
        {
            Surface = "check",
            Platform = platform,
            Stage = options.Stage,
            Configured = verifiedConfigured,
            VerifiedCapability = options.VerifiedCapability,
        };
        var accumulator = new OnboardingProgressAccumulator(1, progressContext);
        using var registration = cancellationToken.Register(() => accumulator.Cancel(1));
        var arguments = PreflightArguments(options);
        Action<string>? stderrLine = null;
        if (options.ProgressJson)
        {
            stderrLine = line =>
            {
                if (accumulator.TryApplyLine(1, line, out var validated))
                {
                    onProgress?.Invoke(validated);
                }
            };
        }
        var stdout = await RunCoreAsync(
            arguments,
            allowFailure: false,
            input: null,
            onStderrLine: stderrLine,
            platform: platform,
            verifiedConfigured: verifiedConfigured,
            verifiedCapability: options.VerifiedCapability,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var report = DecodePreflightReport(stdout, platform, options);
        if (!accumulator.Complete(1, report))
        {
            cancellationToken.ThrowIfCancellationRequested();
        }
        return report;
    }

    internal static OnboardingPreflightReport DecodePreflightReport(string json, string platform, OnboardingPreflightOptions options)
    {
        if (OnboardingCopyCatalog.TryDecodeAndValidateReport(json, platform, options.Stage, false, options.VerifiedCapability, out var report, out _))
        {
            return report;
        }
        // Recognize this specific report as a reason to lock navigation. Never return its unverified repair action.
        if (platform == "windows" && options.VerifiedCapability is null
            && OnboardingCopyCatalog.TryDecodeAndValidateReport(json, platform, options.Stage, false, OnboardingSchema.DoctorFixCapability, out var restricted, out _)
            && restricted.Checks.Any(row => row.Id == "config_store" && row.Code == "config_permissions_unsafe"))
        {
            throw new OnboardingCliException(new OnboardingResolvedDiagnostic
            {
                Code = "config_permissions_unsafe",
                Step = "config_store",
                Message = OnboardingCopyCatalog.LocalizedMessage("config_permissions_unsafe", "config_store"),
                Trusted = false,
            });
        }
        throw new InvalidDataException("无法解析预检报告。请重新检查。");
    }

    public async Task<SetupReceipt> SetupAsync(
        string scanRoot,
        OnboardingSetupOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var stdout = await RunCoreAsync(
            SetupArguments(scanRoot, options),
            allowFailure: false,
            input: null,
            onStderrLine: null,
            platform: "windows",
            verifiedConfigured: options?.VerifiedConfigured,
            verifiedCapability: null,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!OnboardingCopyCatalog.TryDecodeSetupReceipt(stdout, out var receipt, out _))
        {
            throw new InvalidDataException("无法解析首次设置结果。请检查电脑端状态。");
        }
        return receipt;
    }

    public async Task<UpReadinessReceipt> UpAsync(int waitSeconds = 60, CancellationToken cancellationToken = default)
    {
        var stdout = await RunAsync(UpArguments(waitSeconds), cancellationToken).ConfigureAwait(false);
        if (!OnboardingCopyCatalog.TryDecodeUpReadinessReceipt(stdout, out var receipt, out _))
        {
            throw new InvalidDataException("后台服务尚未确认就绪。请刷新后重试。");
        }
        return receipt;
    }

    public async Task<PairingTicketReceipt> PairAsync(string network, CancellationToken cancellationToken = default)
    {
        var stdout = await RunAsync(PairArguments(network), cancellationToken).ConfigureAwait(false);
        if (!OnboardingCopyCatalog.TryDecodePairingTicketReceipt(stdout, requireNetwork: false, out var receipt, out _))
        {
            throw new InvalidDataException("无法解析配对票据。请重新生成。");
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
        RunCoreAsync(arguments, allowFailure, null, null, "windows", null, null, cancellationToken);

    public Task<string> RunWithInputAsync(string[] arguments, string input, CancellationToken cancellationToken = default) =>
        RunCoreAsync(arguments, false, input, null, "windows", null, null, cancellationToken);

    private async Task<string> RunCoreAsync(
        string[] arguments,
        bool allowFailure,
        string? input,
        Action<string>? onStderrLine,
        string platform,
        bool? verifiedConfigured,
        string? verifiedCapability,
        CancellationToken cancellationToken)
    {
        rejectionLatch?.ThrowIfRejected();
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
            var (output, truncated) = await stdout.ConfigureAwait(false);
            var (error, _) = await stderr.ConfigureAwait(false);
            rejectionLatch?.ThrowIfRejected();
            if (truncated)
            {
                throw new InvalidDataException("电脑服务返回的数据过长，请重新检查。");
            }
            if (process.ExitCode != 0 && !allowFailure)
            {
                var stage = ResolveStage(arguments);
                var context = new OnboardingValidationContext
                {
                    Surface = "cli",
                    Platform = platform,
                    Stage = stage,
                    Configured = verifiedConfigured ?? false,
                    VerifiedCapability = verifiedCapability,
                };
                if (OnboardingCopyCatalog.ResolveCliError(output, error, context, arguments) is { } resolved)
                {
                    throw new OnboardingCliException(resolved);
                }
                throw new OnboardingCliException(
                    OnboardingCopyCatalog.UnknownCommandFallback(process.ExitCode, error));
            }
            if (allowFailure && process.ExitCode != 0 && string.IsNullOrWhiteSpace(output))
            {
                return OnboardingCopyCatalog.UnknownCommandFailureMessage(process.ExitCode);
            }
            return output;
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

    private static async Task<(string Text, bool Truncated)> ReadBoundedAsync(
        StreamReader reader,
        Action<string>? onLine,
        CancellationToken token)
    {
        const int limit = 1_048_576;
        var text = new StringBuilder();
        var lineBuffer = onLine is not null ? new StringBuilder() : null;
        var buffer = new char[4096];
        var truncated = false;
        var oversizedLine = false;
        int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false)) != 0)
        {
            var retained = Math.Min(count, limit - text.Length);
            truncated |= retained < count;
            if (retained > 0)
            {
                text.Append(buffer, 0, retained);
            }
            if (onLine is not null && lineBuffer is not null)
            {
                for (var i = 0; i < count; i++)
                {
                    var ch = buffer[i];
                    if (ch == '\n')
                    {
                        if (!oversizedLine)
                        {
                            onLine(lineBuffer.ToString().TrimEnd('\r'));
                        }
                        lineBuffer.Clear();
                        oversizedLine = false;
                    }
                    else if (lineBuffer.Length < limit && !oversizedLine)
                    {
                        lineBuffer.Append(ch);
                    }
                    else
                    {
                        oversizedLine = true;
                    }
                }
            }
        }
        if (onLine is not null && lineBuffer is not null && lineBuffer.Length > 0 && !oversizedLine)
        {
            onLine(lineBuffer.ToString().TrimEnd('\r'));
        }
        return (text.ToString(), truncated);
    }

    public static string ResolveStage(IReadOnlyList<string> arguments)
    {
        if (arguments.Count == 0)
        {
            return "setup";
        }
        if (string.Equals(arguments[0], "setup", StringComparison.Ordinal))
        {
            return "setup";
        }
        if (string.Equals(arguments[0], "preflight", StringComparison.Ordinal))
        {
            for (var i = 1; i < arguments.Count; i++)
            {
                var arg = arguments[i];
                if (string.Equals(arg, "--stage", StringComparison.Ordinal) && i + 1 < arguments.Count)
                {
                    return string.Equals(arguments[i + 1], "pair", StringComparison.Ordinal) ? "pair" : "setup";
                }
                if (arg.StartsWith("--stage=", StringComparison.Ordinal))
                {
                    var raw = arg["--stage=".Length..];
                    return string.Equals(raw, "pair", StringComparison.Ordinal) ? "pair" : "setup";
                }
            }
            return "setup";
        }
        return "pair";
    }
}
