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
    public MaintenanceFailureKind FailureKind { get; init; }
    public bool FallbackToDownload { get; init; }
    public string? DownloadUrl { get; init; }
    public required string Message { get; init; }
    public HostStatus? PostRunStatus { get; init; }
    public bool WorkspaceConfirmed { get; init; }
    public bool LanEnabled { get; init; }
    public bool LanPolicyOk { get; init; }

    public static MaintenanceRunResult Success(HostStatus status, string message) => new()
    {
        Succeeded = true,
        FailureKind = MaintenanceFailureKind.None,
        Message = message,
        PostRunStatus = status,
        WorkspaceConfirmed = status.WorkspaceConfirmed == true,
        LanEnabled = IsLanEnabled(status),
        LanPolicyOk = IsLanPolicyOk(status),
    };

    public static MaintenanceRunResult Failure(MaintenanceFailureKind kind, HostStatus? status = null)
    {
        var (fallback, message) = DescribeFailure(kind);
        return new MaintenanceRunResult
        {
            Succeeded = false,
            FailureKind = kind,
            FallbackToDownload = fallback,
            DownloadUrl = fallback ? WindowsMaintenanceClient.OfficialDownloadUrl : null,
            Message = message,
            PostRunStatus = status,
            WorkspaceConfirmed = status?.WorkspaceConfirmed == true,
            LanEnabled = status is not null && IsLanEnabled(status),
            LanPolicyOk = status is not null && IsLanPolicyOk(status),
        };
    }

    internal static bool IsLanEnabled(HostStatus status) =>
        status.ModuleStatus?.LanEnabled == true || status.NetworkStatus?.AllowLan == true;

    internal static bool IsLanPolicyOk(HostStatus status) =>
        status.NetworkStatus is null || !status.NetworkStatus.PolicyChecked || status.NetworkStatus.PolicyOk;

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

public sealed record MaintenanceBrokerProcessResult(string StdOut, string StdErr, int ExitCode);

public interface IPinnedMaintenanceDirectory
{
    byte[] ReadReceipt(string fileName, int maxBytes);
    string VerifyPinnedImage(string fileName, ReadOnlySpan<byte> expectedDigest, ReadOnlySpan<byte> expectedPublisher);
}

public interface IWindowsMaintenancePlatform
{
    bool IsElevated();
    Task WithPinnedInstallAsync(string installDirectory, Func<IPinnedMaintenanceDirectory, Task> action, CancellationToken cancellationToken);
    byte[] VerifyCmsReceipt(byte[] rawReceipt, ReadOnlySpan<byte> expectedPublisher);
    Task<MaintenanceBrokerProcessResult> RunBrokerAsync(string pinnedBrokerPath, string[] arguments, CancellationToken cancellationToken);
    Task<HostStatus> ReadStatusAsync(CancellationToken cancellationToken);
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

    private static readonly string[] ModifyArguments = ["installer-maintenance", "modify"];

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

    public async Task<MaintenanceRunResult> RunModifyAsync(MaintenancePurpose purpose, CancellationToken cancellationToken = default)
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
                var pinnedBrokerPath = pinned.VerifyPinnedImage(BrokerRole, receipt.BrokerDigest, expectedPublisher);
                var argv = (string[])ModifyArguments.Clone();
                var result = await platform.RunBrokerAsync(pinnedBrokerPath, argv, cancellationToken).ConfigureAwait(false);
                if (result.ExitCode != 0)
                {
                    throw new MaintenanceFailureException(ClassifyBrokerFailure(result.StdOut, result.StdErr, result.ExitCode));
                }
            }, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (MaintenanceFailureException error)
        {
            return MaintenanceRunResult.Failure(error.FailureKind);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException
            or InvalidOperationException or System.ComponentModel.Win32Exception or CryptographicException)
        {
            return MaintenanceRunResult.Failure(MaintenanceFailureKind.LaunchFailed);
        }

        HostStatus status;
        try
        {
            status = await platform.ReadStatusAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException
            or InvalidOperationException or TimeoutException or System.ComponentModel.Win32Exception or JsonException)
        {
            return MaintenanceRunResult.Failure(MaintenanceFailureKind.StatusReadFailed);
        }

        if (purpose == MaintenancePurpose.ConfirmWorkspace)
        {
            return status.WorkspaceConfirmed == true
                ? MaintenanceRunResult.Success(status, "代码目录已确认，服务状态已刷新。")
                : MaintenanceRunResult.Failure(MaintenanceFailureKind.StatusStillUnconfirmed, status);
        }

        var lanReady = MaintenanceRunResult.IsLanEnabled(status) && MaintenanceRunResult.IsLanPolicyOk(status);
        return lanReady
            ? MaintenanceRunResult.Success(status, "专用网络防火墙与局域网访问已生效。")
            : MaintenanceRunResult.Failure(MaintenanceFailureKind.LanStillDisabled, status);
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
