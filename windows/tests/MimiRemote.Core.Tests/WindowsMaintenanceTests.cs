using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MimiRemote.App;
using MimiRemote.App.ViewModels;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class WindowsMaintenanceTests
{
    private static readonly string PublisherHex = new('a', 64);
    private static readonly byte[] BrokerBytes = Encoding.UTF8.GetBytes("signed-agentd-image");
    private static readonly byte[] MaintenanceBytes = Encoding.UTF8.GetBytes("signed-maintenance-image");
    private static readonly byte[] BrokerDigest = SHA256.HashData(BrokerBytes);
    private static readonly byte[] MaintenanceDigest = SHA256.HashData(MaintenanceBytes);

    [Fact]
    public async Task TrustedModifyVerifiesIdentityPinsLaunchesArgvAndReReadsWorkspaceAndLanStatus()
    {
        var fixture = new FakeMaintenancePlatform();
        var client = fixture.CreateClient();

        var result = await client.RunModifyAsync(MaintenancePurpose.ConfirmWorkspace);

        Assert.True(result.Succeeded);
        Assert.Equal(MaintenanceFailureKind.None, result.FailureKind);
        Assert.True(result.WorkspaceConfirmed);
        Assert.True(result.LanEnabled);
        Assert.True(result.LanPolicyOk);
        Assert.Equal([WindowsMaintenanceClient.MaintenanceRole, WindowsMaintenanceClient.BrokerRole], fixture.PinnedDir.VerifiedOrder);
        Assert.Single(fixture.LaunchedCalls);
        Assert.StartsWith(@"\\?\Volume{", fixture.LaunchedCalls[0].Path, StringComparison.Ordinal);
        Assert.EndsWith(@"\agentd.exe", fixture.LaunchedCalls[0].Path, StringComparison.Ordinal);
        Assert.Equal(["installer-maintenance", "modify"], fixture.LaunchedCalls[0].Args);
        Assert.True(fixture.BrokerRanWhilePinned);
        Assert.False(fixture.StatusReadWhilePinned);
    }

    [Fact]
    public async Task LanFirewallModifySucceedsWhenPostRunStatusConfirmsLanAndPolicy()
    {
        var fixture = new FakeMaintenancePlatform();
        var client = fixture.CreateClient();

        var result = await client.RunModifyAsync(MaintenancePurpose.LanFirewall);

        Assert.True(result.Succeeded);
        Assert.True(result.LanEnabled);
        Assert.True(result.LanPolicyOk);
        Assert.Single(fixture.LaunchedCalls);
    }

    [Theory]
    [InlineData("unsigned_publisher", MaintenanceFailureKind.UnsignedBuild, true, false)]
    [InlineData("preview_version", MaintenanceFailureKind.UnsignedBuild, true, false)]
    [InlineData("elevated", MaintenanceFailureKind.ElevatedSession, false, false)]
    [InlineData("missing_receipt", MaintenanceFailureKind.ReceiptMissing, true, false)]
    [InlineData("cms_mismatch", MaintenanceFailureKind.IdentityMismatch, true, false)]
    [InlineData("version_replay", MaintenanceFailureKind.IdentityMismatch, true, false)]
    [InlineData("role_substitution", MaintenanceFailureKind.IdentityMismatch, true, false)]
    [InlineData("reparse_point", MaintenanceFailureKind.ReparsePointRejected, true, false)]
    [InlineData("missing_maintenance_exe", MaintenanceFailureKind.MaintenanceImageMissing, true, false)]
    [InlineData("digest_mismatch_maintenance", MaintenanceFailureKind.DigestMismatch, true, false)]
    [InlineData("digest_mismatch_broker", MaintenanceFailureKind.DigestMismatch, true, false)]
    [InlineData("authenticode_failed", MaintenanceFailureKind.AuthenticodeFailed, true, false)]
    [InlineData("uac_cancelled_code", MaintenanceFailureKind.UacCancelled, true, true)]
    [InlineData("uac_cancelled_json", MaintenanceFailureKind.UacCancelled, true, true)]
    [InlineData("old_host", MaintenanceFailureKind.OldHostUnsupported, true, true)]
    [InlineData("status_unconfirmed", MaintenanceFailureKind.StatusStillUnconfirmed, false, true)]
    [InlineData("status_read_failed", MaintenanceFailureKind.StatusReadFailed, false, true)]
    public async Task EveryFailurePathReturnsTypedErrorAndFallsBackSafely(
        string scenario,
        MaintenanceFailureKind expectedKind,
        bool expectedDownloadFallback,
        bool expectBrokerLaunch)
    {
        var fixture = new FakeMaintenancePlatform();
        switch (scenario)
        {
            case "unsigned_publisher":
                fixture.ExpectedPublisher = null;
                break;
            case "preview_version":
                fixture.ExpectedVersion = "0.0.0-preview";
                break;
            case "elevated":
                fixture.Elevated = true;
                break;
            case "missing_receipt":
                fixture.PinnedDir.ReceiptException = new MaintenanceFailureException(MaintenanceFailureKind.ReceiptMissing);
                break;
            case "cms_mismatch":
                fixture.CmsException = new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
                break;
            case "version_replay":
                fixture.ExpectedVersion = "2.0.0";
                break;
            case "role_substitution":
                fixture.PinnedDir.ReceiptRaw = Encoding.UTF8.GetBytes(
                    "CMS:" + JsonSerializer.Serialize(new
                    {
                        schema = WindowsMaintenanceClient.ReceiptSchema,
                        version = "1.2.3",
                        broker = "unins000.exe",
                        broker_sha256 = Convert.ToHexStringLower(BrokerDigest),
                        maintenance = WindowsMaintenanceClient.MaintenanceRole,
                        maintenance_sha256 = Convert.ToHexStringLower(MaintenanceDigest),
                    }));
                break;
            case "reparse_point":
                fixture.PinException = new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
                break;
            case "missing_maintenance_exe":
                fixture.PinnedDir.ImageExceptions[WindowsMaintenanceClient.MaintenanceRole] =
                    new MaintenanceFailureException(MaintenanceFailureKind.MaintenanceImageMissing);
                break;
            case "digest_mismatch_maintenance":
                fixture.PinnedDir.ImageDigests[WindowsMaintenanceClient.MaintenanceRole] = new byte[32];
                break;
            case "digest_mismatch_broker":
                fixture.PinnedDir.ImageDigests[WindowsMaintenanceClient.BrokerRole] = new byte[32];
                break;
            case "authenticode_failed":
                fixture.PinnedDir.ImageExceptions[WindowsMaintenanceClient.BrokerRole] =
                    new MaintenanceFailureException(MaintenanceFailureKind.AuthenticodeFailed);
                break;
            case "uac_cancelled_code":
                fixture.BrokerResult = new MaintenanceBrokerProcessResult("", "pair_url=mimiremote://pair?pair_sig=secret-leak", 1223);
                break;
            case "uac_cancelled_json":
                fixture.BrokerResult = new MaintenanceBrokerProcessResult(
                    """{"ok":false,"error":{"code":"lan_firewall_blocked","step":"network_lan","message":"管理员授权已取消"}}""",
                    "pair_sig=secret-leak",
                    1);
                break;
            case "old_host":
                fixture.BrokerResult = new MaintenanceBrokerProcessResult("", """错误：未知命令 "installer-maintenance"，可用命令：status""", 1);
                break;
            case "status_unconfirmed":
                fixture.PostRunStatus = new HostStatus
                {
                    Version = "1.2.3",
                    ProcessOk = true,
                    ServiceOk = true,
                    WorkspaceConfirmed = false,
                };
                break;
            case "status_read_failed":
                fixture.StatusException = new IOException("status stream closed");
                break;
        }

        var result = await fixture.CreateClient().RunModifyAsync(MaintenancePurpose.ConfirmWorkspace);

        Assert.False(result.Succeeded);
        Assert.Equal(expectedKind, result.FailureKind);
        Assert.Equal(expectedDownloadFallback, result.FallbackToDownload);
        Assert.Equal(expectBrokerLaunch ? 1 : 0, fixture.LaunchedCalls.Count);
        Assert.DoesNotContain("secret-leak", result.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("pair_sig=", result.Message, StringComparison.Ordinal);
        if (expectedDownloadFallback)
        {
            Assert.Equal(OnboardingCopyCatalog.UrlDesktop, result.DownloadUrl);
            Assert.Contains(OnboardingCopyCatalog.UrlDesktop, result.Message, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task LanFirewallModifyFailsWhenPostRunStatusKeepsLanDisabled()
    {
        var fixture = new FakeMaintenancePlatform
        {
            PostRunStatus = new HostStatus
            {
                Version = "1.2.3",
                ProcessOk = true,
                ServiceOk = true,
                WorkspaceConfirmed = true,
                ModuleStatus = new ModuleStatus { LanEnabled = false, LanAvailable = true },
                NetworkStatus = new HostNetworkStatus { Mode = "loopback", AllowLan = false, PolicyChecked = true, PolicyOk = true },
            },
        };

        var result = await fixture.CreateClient().RunModifyAsync(MaintenancePurpose.LanFirewall);

        Assert.False(result.Succeeded);
        Assert.Equal(MaintenanceFailureKind.LanStillDisabled, result.FailureKind);
        Assert.False(result.LanEnabled);
    }

    [Fact]
    public async Task SetupViewModelConfirmWorkspaceViaMaintenanceUpdatesStateAndExposesDownloadFallback()
    {
        var openedUrls = new List<string>();
        var maintenancePurposes = new List<MaintenancePurpose>();
        var confirmed = false;

        var context = new ClientContext
        {
            OpenUrl = url => openedUrls.Add(url),
            RunInstallerMaintenance = (purpose, _) =>
            {
                maintenancePurposes.Add(purpose);
                if (!confirmed)
                {
                    return Task.FromResult(MaintenanceRunResult.Failure(MaintenanceFailureKind.UnsignedBuild));
                }
                return Task.FromResult(MaintenanceRunResult.Success(
                    new HostStatus { Version = "1.2.3", ServiceOk = true, WorkspaceConfirmed = true },
                    "代码目录已确认，服务状态已刷新。"));
            },
        };
        context.Agent.PreflightHandler = (opts, _, _) => Task.FromResult(BuildSetupReport(opts.Stage, confirmed));

        using var model = new SetupViewModel(context);
        await model.SetActiveAsync(true);
        Assert.Equal(OnboardingGateState.PendingConfirmation, context.GateState);
        Assert.True(model.IsPendingWorkspaceConfirmation);

        // Unsigned build failure exposes official download button.
        await model.ConfirmWorkspaceViaMaintenanceCommand.ExecuteAsync(null);
        Assert.Equal([MaintenancePurpose.ConfirmWorkspace], maintenancePurposes);
        Assert.True(model.HasMaintenanceDownloadFallback);
        Assert.True(model.Failed);
        Assert.Contains(OnboardingCopyCatalog.UrlDesktop, model.Notice, StringComparison.Ordinal);

        model.OpenMaintenanceDownloadCommand.Execute(null);
        Assert.Equal([OnboardingCopyCatalog.UrlDesktop], openedUrls);

        // Confirmed retry clears fallback and unlocks gate.
        confirmed = true;
        await model.ConfirmWorkspaceViaMaintenanceCommand.ExecuteAsync(null);
        Assert.Equal(OnboardingGateState.Confirmed, context.GateState);
        Assert.False(model.IsPendingWorkspaceConfirmation);
        Assert.False(model.HasMaintenanceDownloadFallback);
        Assert.False(model.Failed);
    }

    private static OnboardingPreflightReport BuildSetupReport(string stage, bool workspaceConfirmed) =>
        new()
        {
            Schema = OnboardingSchema.PreflightV1,
            Ok = workspaceConfirmed,
            Stage = stage,
            Configured = true,
            WorkspaceConfirmed = workspaceConfirmed,
            ConfigPath = "%APPDATA%\\mimi-remote\\config.json",
            ScanRoot = @"C:\Users\tester\code",
            BrowseRoot = @"C:\Users\tester\code",
            ScanRootExists = true,
            RecommendedNext = workspaceConfirmed ? "network_any" : "workspace_root",
            RecommendedTransport = "tailcat",
            Checks =
            [
                new OnboardingCheck { Id = "config_store", Group = "workspace", State = "ok", Title = "配置文件", Detail = "ok", Blocking = false },
                workspaceConfirmed
                    ? new OnboardingCheck { Id = "workspace_root", Group = "workspace", State = "ok", Title = "代码目录", Detail = "ok", Blocking = false }
                    : new OnboardingCheck
                    {
                        Id = "workspace_root",
                        Group = "workspace",
                        State = "action_needed",
                        Title = "代码目录",
                        Detail = "pending",
                        Blocking = string.Equals(stage, "pair", StringComparison.Ordinal),
                        Code = "workspace_confirmation_required",
                        Fix = OnboardingFix.ChoosePath("workspace_root"),
                        HasCodeKey = true,
                        HasFixKey = true,
                    },
                new OnboardingCheck { Id = "service_daemon", Group = "service", State = "ok", Title = "后台服务", Detail = "ok", Blocking = false },
                new OnboardingCheck { Id = "assistant_codex", Group = "assistant", State = "ok", Title = "Codex", Detail = "ok", Blocking = false, Enabled = true, Available = true, HasAvailableKey = true, Candidates = [], HasCandidatesKey = true },
                new OnboardingCheck { Id = "assistant_claude", Group = "assistant", State = "optional", Title = "Claude Code", Detail = "opt", Blocking = false, Code = "claude_not_found", Fix = OnboardingFix.OpenUrl(OnboardingCopyCatalog.UrlClaude), HasCodeKey = true, HasFixKey = true, Enabled = false, Available = false, HasAvailableKey = true, Candidates = [], HasCandidatesKey = true },
                new OnboardingCheck { Id = "assistant_agy", Group = "assistant", State = "optional", Title = "Antigravity", Detail = "opt", Blocking = false, Code = "agy_not_found", Fix = OnboardingFix.OpenUrl(OnboardingCopyCatalog.UrlAgy), HasCodeKey = true, HasFixKey = true, Enabled = false, Available = false, HasAvailableKey = true, Candidates = [], HasCandidatesKey = true },
                new OnboardingCheck { Id = "assistant_deepseek", Group = "assistant", State = "optional", Title = "DeepSeek", Detail = "opt", Blocking = false, Code = "deepseek_not_running", Fix = OnboardingFix.OpenUrl(OnboardingCopyCatalog.UrlHarness), HasCodeKey = true, HasFixKey = true, Enabled = false, Available = false, HasAvailableKey = true },
                new OnboardingCheck { Id = "assistant_any", Group = "assistant", State = "ok", Title = "AI 助手", Detail = "ok", Blocking = false },
                new OnboardingCheck { Id = "network_tailscale", Group = "network", State = "optional", Title = "Tailscale", Detail = "opt", Blocking = false, Code = "tailscale_not_installed", Fix = OnboardingFix.OpenUrl(OnboardingCopyCatalog.UrlTailscale), HasCodeKey = true, HasFixKey = true, Enabled = false, Available = false, HasAvailableKey = true },
                new OnboardingCheck { Id = "network_tailcat", Group = "network", State = "ok", Title = "Tailcat", Detail = "ok", Blocking = false, Enabled = true, Available = true, HasAvailableKey = true },
                new OnboardingCheck { Id = "network_lan", Group = "network", State = "action_needed", Title = "同一局域网", Detail = "fw", Blocking = false, Code = "lan_firewall_blocked", Fix = OnboardingFix.OpenSettings("windows_firewall"), HasCodeKey = true, HasFixKey = true, Enabled = false, Available = true, HasAvailableKey = true },
                new OnboardingCheck { Id = "network_any", Group = "network", State = "ok", Title = "手机连接通道", Detail = "ok", Blocking = false },
                new OnboardingCheck { Id = "permission_local_network", Group = "permission", State = "ok", Title = "本地网络", Detail = "ok", Blocking = false },
            ],
        };

    private sealed class FakePinnedDirectory : IPinnedMaintenanceDirectory
    {
        public bool Pinned { get; set; }
        public byte[] ReceiptRaw { get; set; } = Encoding.UTF8.GetBytes(
            "CMS:" + JsonSerializer.Serialize(new
            {
                schema = WindowsMaintenanceClient.ReceiptSchema,
                version = "1.2.3",
                broker = WindowsMaintenanceClient.BrokerRole,
                broker_sha256 = Convert.ToHexStringLower(BrokerDigest),
                maintenance = WindowsMaintenanceClient.MaintenanceRole,
                maintenance_sha256 = Convert.ToHexStringLower(MaintenanceDigest),
            }));
        public Exception? ReceiptException { get; set; }
        public Dictionary<string, Exception> ImageExceptions { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, byte[]> ImageDigests { get; } = new(StringComparer.Ordinal)
        {
            [WindowsMaintenanceClient.BrokerRole] = BrokerDigest,
            [WindowsMaintenanceClient.MaintenanceRole] = MaintenanceDigest,
        };
        public List<string> VerifiedOrder { get; } = [];

        public byte[] ReadReceipt(string fileName, int maxBytes)
        {
            if (!Pinned)
            {
                throw new InvalidOperationException("install directory is not pinned");
            }
            if (ReceiptException is not null)
            {
                throw ReceiptException;
            }
            return ReceiptRaw;
        }

        public string VerifyPinnedImage(string fileName, ReadOnlySpan<byte> expectedDigest, ReadOnlySpan<byte> expectedPublisher)
        {
            if (!Pinned)
            {
                throw new InvalidOperationException("install directory is not pinned");
            }
            VerifiedOrder.Add(fileName);
            if (ImageExceptions.TryGetValue(fileName, out var ex))
            {
                throw ex;
            }
            if (ImageDigests.TryGetValue(fileName, out var actual) && !CryptographicOperations.FixedTimeEquals(actual, expectedDigest))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.DigestMismatch);
            }
            return @"\\?\Volume{11111111-2222-3333-4444-555555555555}\Users\tester\AppData\Local\Programs\Mimi Remote\" + fileName;
        }
    }

    private sealed class FakeMaintenancePlatform : IWindowsMaintenancePlatform
    {
        public string? InstallDirectory { get; set; } = @"C:\Users\tester\AppData\Local\Programs\Mimi Remote";
        public string? ExpectedVersion { get; set; } = "1.2.3";
        public string? ExpectedPublisher { get; set; } = PublisherHex;
        public bool Elevated { get; set; }
        public Exception? PinException { get; set; }
        public Exception? CmsException { get; set; }
        public Exception? StatusException { get; set; }
        public FakePinnedDirectory PinnedDir { get; } = new();
        public List<(string Path, string[] Args)> LaunchedCalls { get; } = [];
        public bool BrokerRanWhilePinned { get; private set; }
        public bool StatusReadWhilePinned { get; private set; }
        public MaintenanceBrokerProcessResult BrokerResult { get; set; } = new("", "", 0);
        public HostStatus PostRunStatus { get; set; } = new()
        {
            Version = "1.2.3",
            ProcessOk = true,
            ServiceOk = true,
            WorkspaceConfirmed = true,
            ModuleStatus = new ModuleStatus { LanEnabled = true, LanAvailable = true },
            NetworkStatus = new HostNetworkStatus { Mode = "lan", AllowLan = true, PolicyChecked = true, PolicyOk = true },
        };

        public WindowsMaintenanceClient CreateClient() => new(
            () => InstallDirectory,
            () => ExpectedVersion,
            () => ExpectedPublisher,
            this);

        public bool IsElevated() => Elevated;

        public async Task WithPinnedInstallAsync(string installDirectory, Func<IPinnedMaintenanceDirectory, Task> action, CancellationToken cancellationToken)
        {
            if (PinException is not null)
            {
                throw PinException;
            }
            PinnedDir.Pinned = true;
            try
            {
                await action(PinnedDir).ConfigureAwait(false);
            }
            finally
            {
                PinnedDir.Pinned = false;
            }
        }

        public byte[] VerifyCmsReceipt(byte[] rawReceipt, ReadOnlySpan<byte> expectedPublisher)
        {
            if (CmsException is not null)
            {
                throw CmsException;
            }
            var text = Encoding.UTF8.GetString(rawReceipt);
            if (!text.StartsWith("CMS:", StringComparison.Ordinal))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }
            return Encoding.UTF8.GetBytes(text["CMS:".Length..]);
        }

        public Task<MaintenanceBrokerProcessResult> RunBrokerAsync(string pinnedBrokerPath, string[] arguments, CancellationToken cancellationToken)
        {
            BrokerRanWhilePinned = PinnedDir.Pinned;
            LaunchedCalls.Add((pinnedBrokerPath, arguments));
            return Task.FromResult(BrokerResult);
        }

        public Task<HostStatus> ReadStatusAsync(CancellationToken cancellationToken)
        {
            StatusReadWhilePinned = PinnedDir.Pinned;
            if (StatusException is not null)
            {
                throw StatusException;
            }
            return Task.FromResult(PostRunStatus);
        }
    }
}
