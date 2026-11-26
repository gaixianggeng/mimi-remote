using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MimiRemote.Core;

public enum MaintenancePurpose
{
    ConfirmWorkspace,
    LanFirewall,
}

public enum MaintenanceFailureKind
{
    None,
    UnsignedBuild,
    ElevatedSession,
    ReceiptMissing,
    IdentityMismatch,
    ReparsePointRejected,
    MaintenanceImageMissing,
    DigestMismatch,
    AuthenticodeFailed,
    OldHostUnsupported,
    UacCancelled,
    LaunchFailed,
    StatusStillUnconfirmed,
    LanStillDisabled,
    StatusReadFailed,
}

public sealed record MaintenanceRunResult
{
    public bool Succeeded { get; init; }
    public bool BrokerVerified { get; init; }
    public MaintenanceFailureKind FailureKind { get; init; }
    public bool FallbackToDownload { get; init; }
    public string? DownloadUrl { get; init; }
    public required string Message { get; init; }
    public HostStatus? PostRunStatus { get; init; }
    public OnboardingPreflightReport? PostRunPreflight { get; init; }
    public PairingTicketReceipt? PostRunPairingTicket { get; init; }
    public bool WorkspaceConfirmed { get; init; }
    public bool LanEnabled { get; init; }
    public bool LanPolicyOk { get; init; }

    public static MaintenanceRunResult Success(
        HostStatus status,
        string message,
        OnboardingPreflightReport? preflight = null,
        PairingTicketReceipt? pairingTicket = null) => new()
    {
        Succeeded = true,
        BrokerVerified = true,
        FailureKind = MaintenanceFailureKind.None,
        Message = message,
        PostRunStatus = status,
        PostRunPreflight = preflight,
        PostRunPairingTicket = pairingTicket,
        WorkspaceConfirmed = status.WorkspaceConfirmed == true,
        LanEnabled = IsLanEnabled(status),
        LanPolicyOk = IsLanPolicyOk(status),
    };

    public static MaintenanceRunResult Failure(
        MaintenanceFailureKind kind,
        HostStatus? status = null,
        OnboardingPreflightReport? preflight = null,
        bool brokerVerified = false)
    {
        var (fallback, message) = DescribeFailure(kind);
        return new MaintenanceRunResult
        {
            Succeeded = false,
            BrokerVerified = brokerVerified,
            FailureKind = kind,
            FallbackToDownload = fallback,
            DownloadUrl = fallback ? WindowsMaintenanceClient.OfficialDownloadUrl : null,
            Message = message,
            PostRunStatus = status,
            PostRunPreflight = preflight,
            WorkspaceConfirmed = status?.WorkspaceConfirmed == true,
            LanEnabled = status is not null && IsLanEnabled(status),
            LanPolicyOk = status is not null && IsLanPolicyOk(status),
        };
    }

    public static bool IsIdentityRejection(MaintenanceFailureKind kind) => kind is
        MaintenanceFailureKind.UnsignedBuild
        or MaintenanceFailureKind.ElevatedSession
        or MaintenanceFailureKind.ReceiptMissing
        or MaintenanceFailureKind.IdentityMismatch
        or MaintenanceFailureKind.ReparsePointRejected
        or MaintenanceFailureKind.MaintenanceImageMissing
        or MaintenanceFailureKind.DigestMismatch
        or MaintenanceFailureKind.AuthenticodeFailed;

    internal static bool IsLanEnabled(HostStatus status) =>
        status.ModuleStatus?.LanEnabled == true || status.NetworkStatus?.AllowLan == true;

    internal static bool IsLanPolicyOk(HostStatus status) =>
        status.NetworkStatus is
        {
            PolicyChecked: true,
            PolicyOk: true,
            FirewallValid: true,
            PolicyInspectionError: false,
            UnsafeRuleCount: 0,
        };

    public static (bool FallbackToDownload, string Message) DescribeFailure(MaintenanceFailureKind kind)
    {
        const string downloadUrl = WindowsMaintenanceClient.OfficialDownloadUrl;
        static (bool, string) Download(string prefix) =>
            (true, prefix + "请前往桌面端正式下载页获取已签名的安装包：" + downloadUrl);

        return kind switch
        {
            MaintenanceFailureKind.UnsignedBuild =>
                Download("当前为未签名或开发构建，无法调用受信维护入口。"),
            MaintenanceFailureKind.ElevatedSession =>
                (false, "请以当前普通桌面用户身份运行桌面端后再启动维护向导，不要以管理员身份启动。"),
            MaintenanceFailureKind.ReceiptMissing =>
                Download("安装目录缺少已签名的维护身份凭据（maintenance-identity.p7m），无法安全启动维护向导。"),
            MaintenanceFailureKind.IdentityMismatch =>
                Download("无法验证此版本的维护身份凭据（发布者、证书链、版本或角色不匹配），已拒绝启动。"),
            MaintenanceFailureKind.ReparsePointRejected =>
                Download("检测到安装路径或程序文件存在不安全的符号链接或重解析点，已拒绝启动维护向导。"),
            MaintenanceFailureKind.MaintenanceImageMissing =>
                Download("安装目录缺少维护程序（Mimi-Remote-Maintenance.exe）或核心代理（agentd.exe）。"),
            MaintenanceFailureKind.DigestMismatch =>
                Download("核心代理或维护程序的文件摘要与签名凭据不一致，已拒绝启动。"),
            MaintenanceFailureKind.AuthenticodeFailed =>
                Download("核心代理或维护程序未通过 Windows Authenticode 发布者签名校验，已拒绝启动。"),
            MaintenanceFailureKind.OldHostUnsupported =>
                Download("当前已安装的桌面端版本较旧，不支持受信维护入口。"),
            MaintenanceFailureKind.UacCancelled =>
                Download("管理员授权已取消，专用网络防火墙规则未修改（同一局域网保持关闭）。如需重新配置，可重试或"),
            MaintenanceFailureKind.LaunchFailed =>
                Download("维护向导未能正常完成。"),
            MaintenanceFailureKind.StatusStillUnconfirmed =>
                (false, "维护向导已退出，但代码目录仍处于待确认状态。请重新确认代码目录或刷新状态检查。"),
            MaintenanceFailureKind.LanStillDisabled =>
                (false, "维护向导已退出，但同一局域网仍未开启或专用网络防火墙策略未生效。请确认当前为专用网络后重试。"),
            MaintenanceFailureKind.StatusReadFailed =>
                (false, "维护向导已退出，但暂时无法读取最新服务状态。请点击“刷新”确认结果。"),
            _ =>
                Download("无法安全调用维护入口。"),
        };
    }
}

public sealed class MaintenanceFailureException : InvalidOperationException
{
    public MaintenanceFailureKind FailureKind { get; }

    public MaintenanceFailureException()
        : base(MaintenanceRunResult.DescribeFailure(MaintenanceFailureKind.IdentityMismatch).Message)
    {
        FailureKind = MaintenanceFailureKind.IdentityMismatch;
    }

    public MaintenanceFailureException(string message)
        : base(message)
    {
        FailureKind = MaintenanceFailureKind.IdentityMismatch;
    }

    public MaintenanceFailureException(string message, Exception innerException)
        : base(message, innerException)
    {
        FailureKind = MaintenanceFailureKind.IdentityMismatch;
    }

    public MaintenanceFailureException(MaintenanceFailureKind kind)
        : base(MaintenanceRunResult.DescribeFailure(kind).Message)
    {
        FailureKind = kind;
    }

    public MaintenanceFailureException(MaintenanceFailureKind kind, Exception innerException)
        : base(MaintenanceRunResult.DescribeFailure(kind).Message, innerException)
    {
        FailureKind = kind;
    }
}

public sealed record PinnedBrokerImage(
    string FullPath,
    string NativeImagePath,
    uint VolumeSerialNumber,
    uint FileIndexHigh,
    uint FileIndexLow);

public sealed record MaintenanceBrokerProcessResult(string StdOut, string StdErr, int ExitCode);

public interface IPinnedMaintenanceDirectory
{
    byte[] ReadReceipt(string fileName, int maxBytes);
    PinnedBrokerImage VerifyPinnedImage(string fileName, ReadOnlySpan<byte> expectedDigest, ReadOnlySpan<byte> expectedPublisher);
}

public interface IWindowsMaintenancePlatform
{
    bool IsElevated();
    Task WithPinnedInstallAsync(string installDirectory, Func<IPinnedMaintenanceDirectory, Task> action, CancellationToken cancellationToken);
    byte[] VerifyCmsReceipt(byte[] rawReceipt, ReadOnlySpan<byte> expectedPublisher);
    Task<MaintenanceBrokerProcessResult> RunBrokerAsync(PinnedBrokerImage pinnedBroker, string[] arguments, CancellationToken cancellationToken);
}

public sealed class WindowsMaintenanceClient(
    Func<string?> resolveInstallDirectory,
    Func<string?> resolveExpectedVersion,
    Func<string?> resolveExpectedPublisherSha256,
    IWindowsMaintenancePlatform platform)
{
    public const string ReceiptFileName = "maintenance-identity.p7m";
    public const int ReceiptMaxBytes = 131_072;
    public const string ReceiptSchema = "mimi.windows.maintenance/v1";
    public const string BrokerRole = "agentd.exe";
    public const string MaintenanceRole = "Mimi-Remote-Maintenance.exe";
    public const string OfficialDownloadUrl = OnboardingCopyCatalog.UrlDesktop;
    public const string PublisherMetadataKey = "MimiReleasePublisherSha256";

    private static readonly string[] ModifyArguments = ["installer-maintenance", "modify"];
    private static readonly string[] StatusArguments = ["status", "--json", "--runtime", "--network-policy"];
    private static readonly TimeSpan StatusReadTimeout = TimeSpan.FromSeconds(45);

    public static bool IsModifyCommand(IReadOnlyList<string> arguments) =>
        arguments.Count == ModifyArguments.Length
        && string.Equals(arguments[0], ModifyArguments[0], StringComparison.Ordinal)
        && string.Equals(arguments[1], ModifyArguments[1], StringComparison.Ordinal);

    public static string? ResolveExpectedVersion(ClientBuild build)
    {
        ArgumentNullException.ThrowIfNull(build);
        return build.Release is not null ? build.Display : null;
    }

    public static string? ResolvePreTrustedPublisherSha256(ClientBuild build, Assembly assembly)
    {
        ArgumentNullException.ThrowIfNull(build);
        ArgumentNullException.ThrowIfNull(assembly);
        if (build.Release is null)
        {
            return null;
        }
        var pinned = assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(attr => string.Equals(attr.Key, PublisherMetadataKey, StringComparison.Ordinal))
            ?.Value;
        return string.IsNullOrWhiteSpace(pinned) ? null : pinned.Trim();
    }

    private sealed record ReceiptPayload
    {
        [JsonPropertyName("schema")]
        public string? Schema { get; init; }

        [JsonPropertyName("version")]
        public string? Version { get; init; }

        [JsonPropertyName("broker")]
        public string? Broker { get; init; }

        [JsonPropertyName("broker_sha256")]
        public string? BrokerSha256 { get; init; }

        [JsonPropertyName("maintenance")]
        public string? Maintenance { get; init; }

        [JsonPropertyName("maintenance_sha256")]
        public string? MaintenanceSha256 { get; init; }
    }

    internal sealed record ValidatedReceipt(string Version, byte[] BrokerDigest, byte[] MaintenanceDigest);

    public static bool TryParseTrustedReleaseIdentity(
        string? version,
        string? publisherSha256,
        out string expectedVersion,
        out byte[] publisherDigest)
    {
        expectedVersion = "";
        publisherDigest = [];
        var trimmedVersion = version?.Trim() ?? "";
        if (string.IsNullOrEmpty(trimmedVersion)
            || string.Equals(trimmedVersion, "dev", StringComparison.OrdinalIgnoreCase)
            || trimmedVersion.StartsWith("devel", StringComparison.OrdinalIgnoreCase)
            || trimmedVersion.Contains('-', StringComparison.Ordinal))
        {
            return false;
        }
        if (!TryDecodeSha256Hex(publisherSha256?.Trim(), out var decodedPublisher))
        {
            return false;
        }
        expectedVersion = trimmedVersion;
        publisherDigest = decodedPublisher;
        return true;
    }

    internal static bool TryValidateReceiptJson(byte[] utf8Json, string expectedVersion, out ValidatedReceipt? receipt)
    {
        receipt = null;
        if (utf8Json.Length == 0 || utf8Json.Length > ReceiptMaxBytes)
        {
            return false;
        }
        try
        {
            var parsed = JsonSerializer.Deserialize<ReceiptPayload>(utf8Json);
            if (parsed is null
                || !string.Equals(parsed.Schema, ReceiptSchema, StringComparison.Ordinal)
                || !string.Equals(parsed.Version, expectedVersion, StringComparison.Ordinal)
                || !string.Equals(parsed.Broker, BrokerRole, StringComparison.Ordinal)
                || !string.Equals(parsed.Maintenance, MaintenanceRole, StringComparison.Ordinal))
            {
                return false;
            }
            if (!TryDecodeSha256Hex(parsed.BrokerSha256, out var brokerDigest)
                || !TryDecodeSha256Hex(parsed.MaintenanceSha256, out var maintenanceDigest))
            {
                return false;
            }
            receipt = new ValidatedReceipt(expectedVersion, brokerDigest, maintenanceDigest);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    internal static bool TryDecodeSha256Hex(string? hex, out byte[] bytes)
    {
        bytes = [];
        if (string.IsNullOrEmpty(hex) || hex.Length != SHA256.HashSizeInBytes * 2)
        {
            return false;
        }
        try
        {
            var decoded = Convert.FromHexString(hex);
            if (decoded.Length != SHA256.HashSizeInBytes)
            {
                return false;
            }
            bytes = decoded;
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    public Task<MaintenanceRunResult> RunModifyAsync(MaintenancePurpose purpose, CancellationToken cancellationToken = default) =>
        RunModifyAsync(purpose, preflightStage: null, verifiedCapability: null, cancellationToken);

    public async Task<MaintenanceRunResult> RunModifyAsync(
        MaintenancePurpose purpose,
        string? preflightStage,
        string? verifiedCapability,
        CancellationToken cancellationToken = default)
    {
        if (!TryParseTrustedReleaseIdentity(
            resolveExpectedVersion(),
            resolveExpectedPublisherSha256(),
            out var expectedVersion,
            out var expectedPublisher))
        {
            return MaintenanceRunResult.Failure(MaintenanceFailureKind.UnsignedBuild);
        }

        try
        {
            if (platform.IsElevated())
            {
                return MaintenanceRunResult.Failure(MaintenanceFailureKind.ElevatedSession);
            }
        }
        catch (Exception error) when (error is InvalidOperationException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            return MaintenanceRunResult.Failure(MaintenanceFailureKind.ElevatedSession);
        }

        var installDir = resolveInstallDirectory()?.Trim();
        if (string.IsNullOrEmpty(installDir))
        {
            return MaintenanceRunResult.Failure(MaintenanceFailureKind.ReparsePointRejected);
        }

        var brokerVerified = false;
        var modifyFailure = MaintenanceFailureKind.None;
        HostStatus? postRunStatus = null;
        OnboardingPreflightReport? postRunPreflight = null;
        PairingTicketReceipt? postRunPairingTicket = null;

        try
        {
            await platform.WithPinnedInstallAsync(installDir, async pinned =>
            {
                var rawReceipt = pinned.ReadReceipt(ReceiptFileName, ReceiptMaxBytes);
                if (rawReceipt.Length == 0 || rawReceipt.Length > ReceiptMaxBytes)
                {
                    throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
                }
                var verifiedContent = platform.VerifyCmsReceipt(rawReceipt, expectedPublisher);
                if (!TryValidateReceiptJson(verifiedContent, expectedVersion, out var receipt) || receipt is null)
                {
                    throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
                }
                _ = pinned.VerifyPinnedImage(MaintenanceRole, receipt.MaintenanceDigest, expectedPublisher);
                var pinnedBroker = pinned.VerifyPinnedImage(BrokerRole, receipt.BrokerDigest, expectedPublisher);
                var argv = (string[])ModifyArguments.Clone();
                var result = await platform.RunBrokerAsync(pinnedBroker, argv, cancellationToken).ConfigureAwait(false);

                brokerVerified = true;
                if (result.ExitCode != 0)
                {
                    modifyFailure = ClassifyBrokerFailure(result.StdOut, result.StdErr, result.ExitCode);
                }
                if (modifyFailure == MaintenanceFailureKind.OldHostUnsupported)
                {
                    return;
                }

                // Re-read status, optional preflight, and (for successful LAN
                // maintenance) the follow-up pairing ticket through the SAME
                // verified pinned broker while directory and binary pins remain
                // active. Also re-read after any launched wizard exits nonzero
                // (such as UAC cancellation) so partial changes are reflected.
                postRunStatus = await ReadVerifiedStatusAsync(pinnedBroker, modifyFailure == MaintenanceFailureKind.None, cancellationToken).ConfigureAwait(false);
                if (preflightStage is "setup" or "pair" && !cancellationToken.IsCancellationRequested)
                {
                    postRunPreflight = await TryReadVerifiedPreflightAsync(pinnedBroker, preflightStage, verifiedCapability, cancellationToken).ConfigureAwait(false);
                }
                if (modifyFailure == MaintenanceFailureKind.None
                    && purpose == MaintenancePurpose.LanFirewall
                    && postRunStatus is not null
                    && MaintenanceRunResult.IsLanEnabled(postRunStatus)
                    && MaintenanceRunResult.IsLanPolicyOk(postRunStatus)
                    && IsPreflightLanReady(postRunPreflight)
                    && !cancellationToken.IsCancellationRequested)
                {
                    postRunPairingTicket = await TryReadVerifiedLanPairingTicketAsync(pinnedBroker, cancellationToken).ConfigureAwait(false);
                }
            }, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (MaintenanceFailureException error)
        {
            var verified = brokerVerified && !MaintenanceRunResult.IsIdentityRejection(error.FailureKind);
            return MaintenanceRunResult.Failure(
                error.FailureKind,
                verified ? postRunStatus : null,
                verified ? postRunPreflight : null,
                verified);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException
            or InvalidOperationException or System.ComponentModel.Win32Exception or CryptographicException or JsonException or TimeoutException)
        {
            return MaintenanceRunResult.Failure(
                brokerVerified ? MaintenanceFailureKind.StatusReadFailed : MaintenanceFailureKind.LaunchFailed,
                brokerVerified ? postRunStatus : null,
                brokerVerified ? postRunPreflight : null,
                brokerVerified);
        }

        if (modifyFailure != MaintenanceFailureKind.None)
        {
            return MaintenanceRunResult.Failure(modifyFailure, postRunStatus, postRunPreflight, brokerVerified: true);
        }

        if (postRunStatus is null)
        {
            return MaintenanceRunResult.Failure(MaintenanceFailureKind.StatusReadFailed, preflight: postRunPreflight, brokerVerified: true);
        }

        if (purpose == MaintenancePurpose.ConfirmWorkspace)
        {
            return postRunStatus.WorkspaceConfirmed == true
                ? MaintenanceRunResult.Success(postRunStatus, "代码目录已确认，服务状态已刷新。", postRunPreflight)
                : MaintenanceRunResult.Failure(MaintenanceFailureKind.StatusStillUnconfirmed, postRunStatus, postRunPreflight, brokerVerified: true);
        }

        var lanReady = MaintenanceRunResult.IsLanEnabled(postRunStatus) && MaintenanceRunResult.IsLanPolicyOk(postRunStatus);
        return lanReady
            ? MaintenanceRunResult.Success(postRunStatus, "专用网络防火墙与局域网访问已生效。", postRunPreflight, postRunPairingTicket)
            : MaintenanceRunResult.Failure(MaintenanceFailureKind.LanStillDisabled, postRunStatus, postRunPreflight, brokerVerified: true);
    }

    private async Task<HostStatus?> ReadVerifiedStatusAsync(
        PinnedBrokerImage pinnedBroker,
        bool required,
        CancellationToken cancellationToken)
    {
        using var statusCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        statusCts.CancelAfter(StatusReadTimeout);
        try
        {
            var statusResult = await platform.RunBrokerAsync(pinnedBroker, (string[])StatusArguments.Clone(), statusCts.Token).ConfigureAwait(false);
            if (statusResult.ExitCode != 0 || string.IsNullOrWhiteSpace(statusResult.StdOut))
            {
                if (required)
                {
                    throw new MaintenanceFailureException(MaintenanceFailureKind.StatusReadFailed);
                }
                return null;
            }
            var parsed = JsonSerializer.Deserialize<HostStatus>(statusResult.StdOut, AgentClient.JsonOptions);
            if (parsed is null || string.IsNullOrWhiteSpace(parsed.Version))
            {
                if (required)
                {
                    throw new MaintenanceFailureException(MaintenanceFailureKind.StatusReadFailed);
                }
                return null;
            }
            return parsed;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (MaintenanceFailureException error) when (MaintenanceRunResult.IsIdentityRejection(error.FailureKind))
        {
            throw;
        }
        catch (Exception error) when (error is OperationCanceledException or MaintenanceFailureException or IOException
            or UnauthorizedAccessException or InvalidDataException or InvalidOperationException or TimeoutException
            or System.ComponentModel.Win32Exception or JsonException)
        {
            if (required)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.StatusReadFailed, error);
            }
            return null;
        }
    }

    private async Task<OnboardingPreflightReport?> TryReadVerifiedPreflightAsync(
        PinnedBrokerImage pinnedBroker,
        string stage,
        string? verifiedCapability,
        CancellationToken cancellationToken)
    {
        using var preflightCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        preflightCts.CancelAfter(OnboardingTimeouts.Preflight);
        try
        {
            var result = await platform.RunBrokerAsync(
                pinnedBroker,
                ["preflight", "--json", "--stage", stage],
                preflightCts.Token).ConfigureAwait(false);
            if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.StdOut))
            {
                return null;
            }
            return OnboardingCopyCatalog.TryDecodeAndValidateReport(
                result.StdOut,
                "windows",
                stage,
                nativeOverlay: false,
                verifiedCapability: verifiedCapability,
                out var report,
                out _)
                ? report
                : null;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (MaintenanceFailureException error) when (MaintenanceRunResult.IsIdentityRejection(error.FailureKind))
        {
            throw;
        }
        catch (Exception error) when (error is OperationCanceledException or MaintenanceFailureException or IOException
            or UnauthorizedAccessException or InvalidDataException or InvalidOperationException or TimeoutException
            or System.ComponentModel.Win32Exception or JsonException)
        {
            return null;
        }
    }

    private static bool IsPreflightLanReady(OnboardingPreflightReport? report) =>
        report is { Stage: "pair", Configured: true, WorkspaceConfirmed: true }
        && report.Checks.Any(c =>
            string.Equals(c.Id, "network_lan", StringComparison.Ordinal)
            && string.Equals(c.State, "ok", StringComparison.Ordinal)
            && c.Enabled == true
            && c.Available == true);

    private async Task<PairingTicketReceipt?> TryReadVerifiedLanPairingTicketAsync(
        PinnedBrokerImage pinnedBroker,
        CancellationToken cancellationToken)
    {
        using var pairCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        pairCts.CancelAfter(OnboardingTimeouts.Pair);
        try
        {
            var result = await platform.RunBrokerAsync(
                pinnedBroker,
                AgentClient.PairArguments("lan"),
                pairCts.Token).ConfigureAwait(false);
            if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.StdOut))
            {
                return null;
            }
            return OnboardingCopyCatalog.TryDecodePairingTicketReceipt(
                result.StdOut,
                requireNetwork: false,
                out var receipt,
                out _)
                ? receipt
                : null;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (MaintenanceFailureException error) when (MaintenanceRunResult.IsIdentityRejection(error.FailureKind))
        {
            throw;
        }
        catch (Exception error) when (error is OperationCanceledException or MaintenanceFailureException or IOException
            or UnauthorizedAccessException or InvalidDataException or InvalidOperationException or TimeoutException
            or System.ComponentModel.Win32Exception or JsonException)
        {
            return null;
        }
    }

    public static MaintenanceFailureKind ClassifyBrokerFailure(string stdout, string stderr, int exitCode)
    {
        if (exitCode == 1223)
        {
            return MaintenanceFailureKind.UacCancelled;
        }
        var combined = stdout + "\n" + stderr;
        if (combined.Contains("installer-maintenance", StringComparison.OrdinalIgnoreCase)
            && (combined.Contains("未知命令", StringComparison.Ordinal)
                || combined.Contains("unknown command", StringComparison.OrdinalIgnoreCase)))
        {
            return MaintenanceFailureKind.OldHostUnsupported;
        }
        if (combined.Contains("lan_firewall_blocked", StringComparison.OrdinalIgnoreCase)
            || combined.Contains("管理员授权已取消", StringComparison.Ordinal)
            || combined.Contains("error_cancelled", StringComparison.OrdinalIgnoreCase))
        {
            return MaintenanceFailureKind.UacCancelled;
        }
        if (combined.Contains("无法验证此版本的维护程序", StringComparison.Ordinal))
        {
            return MaintenanceFailureKind.IdentityMismatch;
        }
        if (combined.Contains("普通桌面会话", StringComparison.Ordinal))
        {
            return MaintenanceFailureKind.ElevatedSession;
        }
        return MaintenanceFailureKind.LaunchFailed;
    }
}
