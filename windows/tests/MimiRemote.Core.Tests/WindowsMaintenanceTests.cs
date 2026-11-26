using System.Formats.Asn1;
using System.Globalization;
using System.Numerics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
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
    private static readonly byte[] LeafSerial = [0x01, 0x23, 0x45, 0x67, 0x89, 0x0A, 0xBC, 0xDE];
    private static readonly byte[] NoEkuSerial = [0x02, 0x23, 0x45, 0x67, 0x89, 0x0A, 0xBC, 0xDF];

    [Fact]
    public async Task TrustedModifyVerifiesIdentityPinsLaunchesArgvAndReReadsStatusWhilePinned()
    {
        var fixture = new FakeMaintenancePlatform();
        var client = fixture.CreateClient();

        var result = await client.RunModifyAsync(MaintenancePurpose.ConfirmWorkspace, "setup", null);

        Assert.True(result.Succeeded);
        Assert.True(result.BrokerVerified);
        Assert.Equal(MaintenanceFailureKind.None, result.FailureKind);
        Assert.True(result.WorkspaceConfirmed);
        Assert.True(result.LanEnabled);
        Assert.True(result.LanPolicyOk);
        Assert.NotNull(result.PostRunPreflight);
        Assert.Equal([WindowsMaintenanceClient.MaintenanceRole, WindowsMaintenanceClient.BrokerRole], fixture.PinnedDir.VerifiedOrder);
        Assert.Equal(3, fixture.LaunchedCalls.Count);
        Assert.StartsWith(@"\\?\Volume{", fixture.LaunchedCalls[0].Broker.FullPath, StringComparison.Ordinal);
        Assert.EndsWith(@"\agentd.exe", fixture.LaunchedCalls[0].Broker.FullPath, StringComparison.Ordinal);
        Assert.Equal(["installer-maintenance", "modify"], fixture.LaunchedCalls[0].Args);
        Assert.Equal(["status", "--json", "--runtime", "--network-policy"], fixture.LaunchedCalls[1].Args);
        Assert.Equal(["preflight", "--json", "--stage", "setup"], fixture.LaunchedCalls[2].Args);
        Assert.True(fixture.BrokerRanWhilePinned);
        Assert.True(fixture.StatusReadWhilePinned);
        Assert.True(fixture.PreflightReadWhilePinned);
    }

    [Fact]
    public async Task LanFirewallModifySucceedsWhenPostRunStatusConfirmsLanAndAffirmativePolicy()
    {
        var fixture = new FakeMaintenancePlatform();
        var client = fixture.CreateClient();

        var result = await client.RunModifyAsync(MaintenancePurpose.LanFirewall);

        Assert.True(result.Succeeded);
        Assert.True(result.BrokerVerified);
        Assert.True(result.LanEnabled);
        Assert.True(result.LanPolicyOk);
        Assert.Equal(2, fixture.LaunchedCalls.Count);
        Assert.Equal(["installer-maintenance", "modify"], fixture.LaunchedCalls[0].Args);
        Assert.Equal(["status", "--json", "--runtime", "--network-policy"], fixture.LaunchedCalls[1].Args);
        Assert.True(fixture.StatusReadWhilePinned);
    }

    [Fact]
    public async Task LanFirewallModifyWithPairStageIssuesVerifiedPairingTicketWhilePinned()
    {
        var fixture = new FakeMaintenancePlatform();
        var client = fixture.CreateClient();

        var result = await client.RunModifyAsync(MaintenancePurpose.LanFirewall, "pair", null);

        Assert.True(result.Succeeded);
        Assert.True(result.BrokerVerified);
        Assert.True(result.LanEnabled);
        Assert.True(result.LanPolicyOk);
        Assert.NotNull(result.PostRunPreflight);
        Assert.NotNull(result.PostRunPairingTicket);
        Assert.Equal("lan", result.PostRunPairingTicket.Network);
        Assert.Equal(4, fixture.LaunchedCalls.Count);
        Assert.Equal(["installer-maintenance", "modify"], fixture.LaunchedCalls[0].Args);
        Assert.Equal(["status", "--json", "--runtime", "--network-policy"], fixture.LaunchedCalls[1].Args);
        Assert.Equal(["preflight", "--json", "--stage", "pair"], fixture.LaunchedCalls[2].Args);
        Assert.Equal(["pair", "--network", "lan", "--qr-only", "--json"], fixture.LaunchedCalls[3].Args);
        Assert.True(fixture.PairReadWhilePinned);
    }

    [Theory]
    [InlineData("unsigned_publisher", MaintenanceFailureKind.UnsignedBuild, true, false, false)]
    [InlineData("preview_version", MaintenanceFailureKind.UnsignedBuild, true, false, false)]
    [InlineData("elevated", MaintenanceFailureKind.ElevatedSession, false, false, false)]
    [InlineData("missing_receipt", MaintenanceFailureKind.ReceiptMissing, true, false, false)]
    [InlineData("cms_mismatch", MaintenanceFailureKind.IdentityMismatch, true, false, false)]
    [InlineData("version_replay", MaintenanceFailureKind.IdentityMismatch, true, false, false)]
    [InlineData("role_substitution", MaintenanceFailureKind.IdentityMismatch, true, false, false)]
    [InlineData("reparse_point", MaintenanceFailureKind.ReparsePointRejected, true, false, false)]
    [InlineData("missing_maintenance_exe", MaintenanceFailureKind.MaintenanceImageMissing, true, false, false)]
    [InlineData("digest_mismatch_maintenance", MaintenanceFailureKind.DigestMismatch, true, false, false)]
    [InlineData("digest_mismatch_broker", MaintenanceFailureKind.DigestMismatch, true, false, false)]
    [InlineData("authenticode_failed", MaintenanceFailureKind.AuthenticodeFailed, true, false, false)]
    [InlineData("process_identity_mismatch", MaintenanceFailureKind.IdentityMismatch, true, true, false)]
    [InlineData("uac_cancelled_code", MaintenanceFailureKind.UacCancelled, true, true, true)]
    [InlineData("old_host", MaintenanceFailureKind.OldHostUnsupported, true, true, true)]
    [InlineData("status_unconfirmed", MaintenanceFailureKind.StatusStillUnconfirmed, false, true, true)]
    [InlineData("status_read_failed", MaintenanceFailureKind.StatusReadFailed, false, true, true)]
    public async Task EveryFailurePathReturnsTypedErrorAndFallsBackSafely(
        string scenario,
        MaintenanceFailureKind expectedKind,
        bool expectedDownloadFallback,
        bool expectBrokerAttempt,
        bool expectBrokerVerified)
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
            case "process_identity_mismatch":
                fixture.ModifyException = new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
                break;
            case "uac_cancelled_code":
                fixture.BrokerResult = new MaintenanceBrokerProcessResult(
                    "",
                    "错误：管理员授权已取消，请回到桌面应用检查局域网设置\npair_url=mimiremote://pair?pair_sig=secret-leak",
                    1223);
                fixture.PostRunStatus = new HostStatus
                {
                    Version = "1.2.3",
                    ProcessOk = true,
                    ServiceOk = true,
                    WorkspaceConfirmed = true,
                    ModuleStatus = new ModuleStatus { LanEnabled = false, LanAvailable = true },
                    NetworkStatus = new HostNetworkStatus { Mode = "loopback", AllowLan = false, PolicyChecked = true, PolicyOk = true, FirewallValid = false },
                };
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
                fixture.StatusResult = new MaintenanceBrokerProcessResult("", "status pipe closed", 1);
                break;
        }

        var result = await fixture.CreateClient().RunModifyAsync(MaintenancePurpose.ConfirmWorkspace);

        Assert.False(result.Succeeded);
        Assert.Equal(expectedKind, result.FailureKind);
        Assert.Equal(expectedDownloadFallback, result.FallbackToDownload);
        Assert.Equal(expectBrokerVerified, result.BrokerVerified);
        if (!expectBrokerAttempt)
        {
            Assert.Empty(fixture.LaunchedCalls);
        }
        else
        {
            Assert.NotEmpty(fixture.LaunchedCalls);
            Assert.Equal(["installer-maintenance", "modify"], fixture.LaunchedCalls[0].Args);
        }
        if (scenario == "process_identity_mismatch")
        {
            // Must not run status readback after pre-resume process identity failure.
            Assert.Single(fixture.LaunchedCalls);
        }
        if (scenario == "uac_cancelled_code")
        {
            // Must still reread verified status while pinned after UAC cancellation so partial changes are preserved.
            Assert.Equal(2, fixture.LaunchedCalls.Count);
            Assert.Equal(["status", "--json", "--runtime", "--network-policy"], fixture.LaunchedCalls[1].Args);
            Assert.True(fixture.StatusReadWhilePinned);
            Assert.True(result.WorkspaceConfirmed);
            Assert.False(result.LanEnabled);
        }
        Assert.DoesNotContain("secret-leak", result.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("pair_sig=", result.Message, StringComparison.Ordinal);
        if (expectedDownloadFallback)
        {
            Assert.Equal(OnboardingCopyCatalog.UrlDesktop, result.DownloadUrl);
            Assert.Contains(OnboardingCopyCatalog.UrlDesktop, result.Message, StringComparison.Ordinal);
        }
    }

    [Theory]
    [InlineData("lan_disabled")]
    [InlineData("missing_network_status")]
    [InlineData("unchecked_policy")]
    [InlineData("policy_not_ok")]
    [InlineData("firewall_invalid")]
    [InlineData("inspection_error")]
    [InlineData("unsafe_rules")]
    public async Task LanFirewallModifyRequiresFreshAffirmativePolicyCheck(string scenario)
    {
        var fixture = new FakeMaintenancePlatform
        {
            PostRunStatus = scenario switch
            {
                "lan_disabled" => new HostStatus
                {
                    Version = "1.2.3",
                    ProcessOk = true,
                    ServiceOk = true,
                    WorkspaceConfirmed = true,
                    ModuleStatus = new ModuleStatus { LanEnabled = false, LanAvailable = true },
                    NetworkStatus = new HostNetworkStatus { Mode = "loopback", AllowLan = false, PolicyChecked = true, PolicyOk = true, FirewallValid = true },
                },
                "missing_network_status" => new HostStatus
                {
                    Version = "1.2.3",
                    ProcessOk = true,
                    ServiceOk = true,
                    WorkspaceConfirmed = true,
                    ModuleStatus = new ModuleStatus { LanEnabled = true, LanAvailable = true },
                    NetworkStatus = null,
                },
                "unchecked_policy" => new HostStatus
                {
                    Version = "1.2.3",
                    ProcessOk = true,
                    ServiceOk = true,
                    WorkspaceConfirmed = true,
                    ModuleStatus = new ModuleStatus { LanEnabled = true, LanAvailable = true },
                    NetworkStatus = new HostNetworkStatus { Mode = "lan", AllowLan = true, PolicyChecked = false, PolicyOk = true, FirewallValid = true },
                },
                "policy_not_ok" => new HostStatus
                {
                    Version = "1.2.3",
                    ProcessOk = true,
                    ServiceOk = true,
                    WorkspaceConfirmed = true,
                    ModuleStatus = new ModuleStatus { LanEnabled = true, LanAvailable = true },
                    NetworkStatus = new HostNetworkStatus { Mode = "lan", AllowLan = true, PolicyChecked = true, PolicyOk = false, FirewallValid = true },
                },
                "firewall_invalid" => new HostStatus
                {
                    Version = "1.2.3",
                    ProcessOk = true,
                    ServiceOk = true,
                    WorkspaceConfirmed = true,
                    ModuleStatus = new ModuleStatus { LanEnabled = true, LanAvailable = true },
                    NetworkStatus = new HostNetworkStatus { Mode = "lan", AllowLan = true, PolicyChecked = true, PolicyOk = true, FirewallValid = false },
                },
                "inspection_error" => new HostStatus
                {
                    Version = "1.2.3",
                    ProcessOk = true,
                    ServiceOk = true,
                    WorkspaceConfirmed = true,
                    ModuleStatus = new ModuleStatus { LanEnabled = true, LanAvailable = true },
                    NetworkStatus = new HostNetworkStatus { Mode = "lan", AllowLan = true, PolicyChecked = true, PolicyOk = true, FirewallValid = true, PolicyInspectionError = true },
                },
                _ => new HostStatus
                {
                    Version = "1.2.3",
                    ProcessOk = true,
                    ServiceOk = true,
                    WorkspaceConfirmed = true,
                    ModuleStatus = new ModuleStatus { LanEnabled = true, LanAvailable = true },
                    NetworkStatus = new HostNetworkStatus { Mode = "lan", AllowLan = true, PolicyChecked = true, PolicyOk = true, FirewallValid = true, UnsafeRuleCount = 1 },
                },
            },
        };

        var result = await fixture.CreateClient().RunModifyAsync(MaintenancePurpose.LanFirewall);

        Assert.False(result.Succeeded);
        Assert.Equal(MaintenanceFailureKind.LanStillDisabled, result.FailureKind);
        if (scenario != "lan_disabled")
        {
            Assert.False(result.LanPolicyOk);
        }
    }

    [Fact]
    public void ResolvePreTrustedPublisherSha256RequiresEmbeddedMetadataWithoutSelfSignerFallback()
    {
        var formalBuild = ClientBuild.Parse("1.2.3");
        var previewBuild = ClientBuild.Parse("0.0.0-preview");
        var unpinnedAssembly = new MetadataTestAssembly(null);
        var pinnedAssembly = new MetadataTestAssembly(PublisherHex);

        Assert.Equal("1.2.3", WindowsMaintenanceClient.ResolveExpectedVersion(formalBuild));
        Assert.Null(WindowsMaintenanceClient.ResolveExpectedVersion(previewBuild));
        Assert.Null(WindowsMaintenanceClient.ResolvePreTrustedPublisherSha256(formalBuild, unpinnedAssembly));
        Assert.Null(WindowsMaintenanceClient.ResolvePreTrustedPublisherSha256(previewBuild, pinnedAssembly));
        Assert.Equal(PublisherHex, WindowsMaintenanceClient.ResolvePreTrustedPublisherSha256(formalBuild, pinnedAssembly));
    }

    [Fact]
    public async Task SetupViewModelSkipsUnverifiedRefreshAfterIdentityRejectionAndPreservesMaintenanceNotice()
    {
        var openedUrls = new List<string>();
        var maintenancePurposes = new List<MaintenancePurpose>();
        var confirmed = false;
        var postStatusChangedRefresh = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var context = new ClientContext
        {
            OpenUrl = url => openedUrls.Add(url),
        };
        context.RunInstallerMaintenance = (purpose, _) =>
        {
            maintenancePurposes.Add(purpose);
            if (!confirmed)
            {
                return Task.FromResult(MaintenanceRunResult.Failure(MaintenanceFailureKind.UnsignedBuild));
            }
            var verifiedReport = BuildSetupReport("setup", workspaceConfirmed: true);
            // Simulate a StatusChanged event arriving during maintenance so the
            // page queues a refresh behind WhenIdle.
            context.RaiseStatusChanged();
            return Task.FromResult(MaintenanceRunResult.Success(
                new HostStatus { Version = "1.2.3", ServiceOk = true, WorkspaceConfirmed = true },
                "代码目录已确认，服务状态已刷新。",
                verifiedReport));
        };
        context.Agent.PreflightHandler = (opts, _, _) =>
        {
            if (confirmed)
            {
                postStatusChangedRefresh.TrySetResult();
            }
            return Task.FromResult(BuildSetupReport(opts.Stage, confirmed));
        };

        using var model = new SetupViewModel(context);
        await model.SetActiveAsync(true);
        Assert.Equal(OnboardingGateState.PendingConfirmation, context.GateState);
        Assert.True(model.IsPendingWorkspaceConfirmation);
        var callsBeforeRejection = context.Agent.Calls.Count;

        // Unsigned build failure exposes official download button and executes ZERO refreshes.
        await model.ConfirmWorkspaceViaMaintenanceCommand.ExecuteAsync(null);
        Assert.Equal([MaintenancePurpose.ConfirmWorkspace], maintenancePurposes);
        Assert.Equal(callsBeforeRejection, context.Agent.Calls.Count);
        Assert.True(model.HasMaintenanceDownloadFallback);
        Assert.True(model.Failed);
        Assert.True(model.NoticeOpen);
        Assert.Contains(OnboardingCopyCatalog.UrlDesktop, model.Notice, StringComparison.Ordinal);

        model.OpenMaintenanceDownloadCommand.Execute(null);
        Assert.Equal([OnboardingCopyCatalog.UrlDesktop], openedUrls);

        // Confirmed retry applies verified preflight and preserves the maintenance InfoBar
        // even after the queued StatusChanged refresh completes.
        confirmed = true;
        await model.ConfirmWorkspaceViaMaintenanceCommand.ExecuteAsync(null);
        await postStatusChangedRefresh.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await model.WhenIdle;
        Assert.Equal(OnboardingGateState.Confirmed, context.GateState);
        Assert.False(model.IsPendingWorkspaceConfirmation);
        Assert.False(model.HasMaintenanceDownloadFallback);
        Assert.False(model.Failed);
        Assert.True(model.NoticeOpen);
        Assert.Equal("代码目录已确认，服务状态已刷新。", model.Notice);
    }

    [Fact]
    public async Task SetupViewModelFailsClosedWithoutUnverifiedPreflightWhenVerifiedPreflightIsAbsent()
    {
        var context = new ClientContext();
        var confirmed = false;
        context.Agent.PreflightHandler = (opts, _, _) => Task.FromResult(BuildSetupReport(opts.Stage, confirmed));
        context.RunInstallerMaintenance = (_, _) =>
        {
            confirmed = true;
            return Task.FromResult(MaintenanceRunResult.Success(
                new HostStatus { Version = "1.2.3", ServiceOk = true, WorkspaceConfirmed = true },
                "代码目录已确认，服务状态已刷新。",
                preflight: null));
        };

        using var model = new SetupViewModel(context);
        await model.SetActiveAsync(true);
        var callsBeforeMaintenance = context.Agent.Calls.Count;

        await model.ConfirmWorkspaceViaMaintenanceCommand.ExecuteAsync(null);
        Assert.Equal(callsBeforeMaintenance, context.Agent.Calls.Count);
        Assert.True(model.Failed);
        Assert.True(model.HasMaintenanceDownloadFallback);
        Assert.Contains(OnboardingCopyCatalog.UrlDesktop, model.Notice, StringComparison.Ordinal);
    }

    [Fact]
    public async Task SetupViewModelExposesLocalDownloadRecoveryWhenBrokerIsMissing()
    {
        var openedUrls = new List<string>();
        var context = new ClientContext
        {
            HasAgent = false,
            OpenUrl = url => openedUrls.Add(url),
        };

        using var model = new SetupViewModel(context);
        await model.SetActiveAsync(true);

        Assert.Equal(OnboardingGateState.Unconfigured, context.GateState);
        Assert.False(model.IsPendingWorkspaceConfirmation);
        Assert.True(model.IsMissingBroker);
        Assert.True(model.HasMaintenanceDownloadFallback);
        Assert.True(model.OpenMaintenanceDownloadCommand.CanExecute(null));
        Assert.Empty(context.Agent.Calls);

        model.OpenMaintenanceDownloadCommand.Execute(null);
        Assert.Equal([OnboardingCopyCatalog.UrlDesktop], openedUrls);
    }

    [Fact]
    public void FormatCommandLineQuotesSpacesQuotesAndTrailingBackslashes()
    {
        var cmd = WindowsMaintenanceProcessRunner.FormatCommandLine(
            @"\\?\Volume{11111111-2222-3333-4444-555555555555}\Users\tester\AppData\Local\Programs\Mimi Remote\agentd.exe",
            ["installer-maintenance", "modify", @"a b\", "say \"hi\"", ""]);
        Assert.Equal(
            "\"\\\\?\\Volume{11111111-2222-3333-4444-555555555555}\\Users\\tester\\AppData\\Local\\Programs\\Mimi Remote\\agentd.exe\" installer-maintenance modify \"a b\\\\\" \"say \\\"hi\\\"\" \"\"",
            cmd);
    }

    [Fact]
    [SupportedOSPlatform("windows")]
    public async Task BoundProcessRunnerVerifiesImageIdentityBeforeResumeOnWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var cmdPath = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        PinnedBrokerImage valid;
        using (var handle = File.OpenHandle(cmdPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            valid = WindowsMaintenanceProcessRunner.ReadFileIdentity(handle, cmdPath);
        }

        var ok = await WindowsMaintenanceProcessRunner.RunBoundProcessAsync(
            valid,
            ["/c", "echo", "bound-ok"],
            CancellationToken.None);
        Assert.Equal(0, ok.ExitCode);
        Assert.Contains("bound-ok", ok.StdOut, StringComparison.Ordinal);

        var tempDir = Path.Combine(Path.GetTempPath(), "mimi-maint-bind-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
        try
        {
            var blockedMarker = Path.Combine(tempDir, "must-not-exist.txt");
            var tamperedFileId = valid with { FileIndexLow = valid.FileIndexLow ^ 1u };
            var fileIdEx = await Assert.ThrowsAsync<MaintenanceFailureException>(() =>
                WindowsMaintenanceProcessRunner.RunBoundProcessAsync(
                    tamperedFileId,
                    ["/c", $"echo pwn > \"{blockedMarker}\""],
                    CancellationToken.None));
            Assert.Equal(MaintenanceFailureKind.IdentityMismatch, fileIdEx.FailureKind);
            Assert.False(File.Exists(blockedMarker));

            var tamperedNativePath = valid with { NativeImagePath = @"\Device\HarddiskVolume99\fake\agentd.exe" };
            var pathEx = await Assert.ThrowsAsync<MaintenanceFailureException>(() =>
                WindowsMaintenanceProcessRunner.RunBoundProcessAsync(
                    tamperedNativePath,
                    ["/c", $"echo pwn > \"{blockedMarker}\""],
                    CancellationToken.None));
            Assert.Equal(MaintenanceFailureKind.IdentityMismatch, pathEx.FailureKind);
            Assert.False(File.Exists(blockedMarker));
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
        }
    }

    [Fact]
    [SupportedOSPlatform("windows")]
    public async Task BoundProcessRunnerCancellationTerminatesEntireJobTreeOnWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var powershellPath = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        PinnedBrokerImage valid;
        using (var handle = File.OpenHandle(powershellPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            valid = WindowsMaintenanceProcessRunner.ReadFileIdentity(handle, powershellPath);
        }

        var tempDir = Path.Combine(Path.GetTempPath(), "mimi-maint-job-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
        var descendantHandle = (nint)0;
        try
        {
            var pidFile = Path.Combine(tempDir, "descendant.pid");
            var tmpFile = pidFile + ".tmp";
            var escapedTmp = tmpFile.Replace("'", "''", StringComparison.Ordinal);
            var escapedPid = pidFile.Replace("'", "''", StringComparison.Ordinal);
            var script =
                "$child = Start-Process -FilePath \"$env:SystemRoot\\System32\\ping.exe\" -ArgumentList '-n','60','127.0.0.1' -NoNewWindow -PassThru; "
                + $"[IO.File]::WriteAllText('{escapedTmp}', [string]$child.Id); "
                + $"[IO.File]::Move('{escapedTmp}', '{escapedPid}'); "
                + "$child.WaitForExit()";

            using var cts = new CancellationTokenSource();
            var runTask = WindowsMaintenanceProcessRunner.RunBoundProcessAsync(
                valid,
                ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                cts.Token);

            var descendantPid = 0;
            var deadline = DateTimeOffset.UtcNow.AddSeconds(20);
            while (DateTimeOffset.UtcNow < deadline)
            {
                if (File.Exists(pidFile)
                    && int.TryParse(File.ReadAllText(pidFile).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)
                    && parsed > 0)
                {
                    descendantPid = parsed;
                    break;
                }
                Assert.False(runTask.IsCompleted, "Bound process exited before spawning descendant.");
                await Task.Delay(50);
            }
            Assert.True(descendantPid > 0, "Timed out waiting for descendant PID.");

            // Hold a native handle to the live descendant BEFORE cancelling so
            // Windows cannot recycle the PID and we can assert it exited before return.
            descendantHandle = OpenProcess(ProcessSynchronize | ProcessQueryLimitedInformation | ProcessTerminate, false, (uint)descendantPid);
            Assert.NotEqual((nint)0, descendantHandle);
            Assert.Equal(WaitTimeout, WaitForSingleObject(descendantHandle, 0));

            await cts.CancelAsync();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => runTask);
            Assert.Equal(WaitObject0, WaitForSingleObject(descendantHandle, 0));
        }
        finally
        {
            if (descendantHandle != 0)
            {
                if (WaitForSingleObject(descendantHandle, 0) != WaitObject0)
                {
                    _ = TerminateProcess(descendantHandle, 1);
                }
                _ = CloseHandle(descendantHandle);
            }
            Directory.Delete(tempDir, recursive: true);
        }
    }

    [Fact]
    [SupportedOSPlatform("windows")]
    public async Task BoundProcessRunnerNonDestructiveModifyModeCompletesDespiteCancellationOnWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var cmdPath = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        PinnedBrokerImage valid;
        using (var handle = File.OpenHandle(cmdPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            valid = WindowsMaintenanceProcessRunner.ReadFileIdentity(handle, cmdPath);
        }

        var tempDir = Path.Combine(Path.GetTempPath(), "mimi-maint-modify-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
        try
        {
            var startedMarker = Path.Combine(tempDir, "started.txt");
            var doneMarker = Path.Combine(tempDir, "done.txt");
            using var cts = new CancellationTokenSource();
            var runTask = WindowsMaintenanceProcessRunner.RunBoundProcessAsync(
                valid,
                ["/c", $"echo started > \"{startedMarker}\" && ping -n 2 127.0.0.1 >nul && echo done > \"{doneMarker}\""],
                killOnCancel: false,
                cts.Token);

            var deadline = DateTimeOffset.UtcNow.AddSeconds(10);
            while (!File.Exists(startedMarker) && DateTimeOffset.UtcNow < deadline)
            {
                await Task.Delay(25);
            }
            await cts.CancelAsync();
            var result = await runTask;
            Assert.Equal(0, result.ExitCode);
            Assert.True(File.Exists(doneMarker));
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
        }
    }

    [Fact]
    [SupportedOSPlatform("windows")]
    public async Task NativeCmsVerifierValidatesSignedReceiptAndRejectsTamperingOnWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        using var caRsa = RSA.Create(2048);
        var caRequest = new CertificateRequest("CN=Mimi Maintenance Test Root", caRsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        caRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(certificateAuthority: true, hasPathLengthConstraint: false, pathLengthConstraint: 0, critical: true));
        caRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, critical: true));
        caRequest.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(caRequest.PublicKey, critical: false));
        using var caCert = caRequest.CreateSelfSigned(now.AddHours(-1), now.AddHours(2));

        using var leafRsa = RSA.Create(2048);
        var leafRequest = new CertificateRequest("CN=Mimi Maintenance Test Publisher", leafRsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        leafRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(certificateAuthority: false, hasPathLengthConstraint: false, pathLengthConstraint: 0, critical: true));
        leafRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, critical: true));
        leafRequest.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.3") }, critical: false));
        leafRequest.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(leafRequest.PublicKey, critical: false));
        leafRequest.CertificateExtensions.Add(X509AuthorityKeyIdentifierExtension.CreateFromCertificate(caCert, includeKeyIdentifier: true, includeIssuerAndSerial: false));
        using var leafCert = leafRequest.Create(caCert, now.AddHours(-1), now.AddHours(1), LeafSerial);

        using var noEkuRsa = RSA.Create(2048);
        var noEkuRequest = new CertificateRequest("CN=Mimi Maintenance No CodeSigning EKU", noEkuRsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        noEkuRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(certificateAuthority: false, hasPathLengthConstraint: false, pathLengthConstraint: 0, critical: true));
        noEkuRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, critical: true));
        noEkuRequest.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.1") }, critical: false));
        noEkuRequest.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(noEkuRequest.PublicKey, critical: false));
        noEkuRequest.CertificateExtensions.Add(X509AuthorityKeyIdentifierExtension.CreateFromCertificate(caCert, includeKeyIdentifier: true, includeIssuerAndSerial: false));
        using var noEkuCert = noEkuRequest.Create(caCert, now.AddHours(-1), now.AddHours(1), NoEkuSerial);

        var payload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            schema = WindowsMaintenanceClient.ReceiptSchema,
            version = "1.2.3",
            broker = WindowsMaintenanceClient.BrokerRole,
            broker_sha256 = Convert.ToHexStringLower(BrokerDigest),
            maintenance = WindowsMaintenanceClient.MaintenanceRole,
            maintenance_sha256 = Convert.ToHexStringLower(MaintenanceDigest),
        }));
        var publisherDigest = SHA256.HashData(leafCert.RawData);
        var trustRoots = new X509Certificate2Collection { caCert };

        var validCms = BuildSignedCmsDer(payload, leafRsa, leafCert, LeafSerial, [leafCert, caCert]);

        // Valid signed CMS passes native CryptMsg + signer lookup + signature + chain checks.
        var verified = WindowsMaintenanceCmsVerifier.VerifyCmsReceiptForTesting(validCms, publisherDigest, trustRoots);
        Assert.Equal(payload, verified);

        // Production system trust mode rejects an untrusted test root.
        var untrustedEx = Assert.Throws<MaintenanceFailureException>(() =>
            WindowsMaintenanceCmsVerifier.VerifyCmsReceipt(validCms, publisherDigest));
        Assert.Equal(MaintenanceFailureKind.IdentityMismatch, untrustedEx.FailureKind);

        // Tampered encapsulated payload fails native signature verification.
        var tamperedPayload = (byte[])validCms.Clone();
        var versionOffset = tamperedPayload.AsSpan().IndexOf("1.2.3"u8);
        Assert.True(versionOffset >= 0);
        tamperedPayload[versionOffset] = (byte)'9';
        var payloadEx = Assert.Throws<MaintenanceFailureException>(() =>
            WindowsMaintenanceCmsVerifier.VerifyCmsReceiptForTesting(tamperedPayload, publisherDigest, trustRoots));
        Assert.Equal(MaintenanceFailureKind.IdentityMismatch, payloadEx.FailureKind);

        // Corrupted signature fails native CryptMsgControl verification.
        var corruptSigCms = BuildSignedCmsDer(payload, leafRsa, leafCert, LeafSerial, [leafCert, caCert], corruptSignature: true);
        var sigEx = Assert.Throws<MaintenanceFailureException>(() =>
            WindowsMaintenanceCmsVerifier.VerifyCmsReceiptForTesting(corruptSigCms, publisherDigest, trustRoots));
        Assert.Equal(MaintenanceFailureKind.IdentityMismatch, sigEx.FailureKind);

        // Wrong expected publisher SHA-256 fails closed.
        var wrongPublisher = (byte[])publisherDigest.Clone();
        wrongPublisher[0] ^= 0xFF;
        var pubEx = Assert.Throws<MaintenanceFailureException>(() =>
            WindowsMaintenanceCmsVerifier.VerifyCmsReceiptForTesting(validCms, wrongPublisher, trustRoots));
        Assert.Equal(MaintenanceFailureKind.IdentityMismatch, pubEx.FailureKind);

        // Certificate lacking Code Signing EKU fails chain policy.
        var noEkuCms = BuildSignedCmsDer(payload, noEkuRsa, noEkuCert, NoEkuSerial, [noEkuCert, caCert]);
        var noEkuPublisher = SHA256.HashData(noEkuCert.RawData);
        var ekuEx = Assert.Throws<MaintenanceFailureException>(() =>
            WindowsMaintenanceCmsVerifier.VerifyCmsReceiptForTesting(noEkuCms, noEkuPublisher, trustRoots));
        Assert.Equal(MaintenanceFailureKind.IdentityMismatch, ekuEx.FailureKind);

        // Detached CMS (no encapsulated content) fails closed.
        var detachedCms = BuildSignedCmsDer(payload, leafRsa, leafCert, LeafSerial, [leafCert, caCert], detached: true);
        var detachedEx = Assert.Throws<MaintenanceFailureException>(() =>
            WindowsMaintenanceCmsVerifier.VerifyCmsReceiptForTesting(detachedCms, publisherDigest, trustRoots));
        Assert.Equal(MaintenanceFailureKind.IdentityMismatch, detachedEx.FailureKind);

        // Non-CMS / truncated bytes fail closed.
        var junkEx = Assert.Throws<MaintenanceFailureException>(() =>
            WindowsMaintenanceCmsVerifier.VerifyCmsReceiptForTesting(Encoding.UTF8.GetBytes("CMS:not-asn1"), publisherDigest, trustRoots));
        Assert.Equal(MaintenanceFailureKind.IdentityMismatch, junkEx.FailureKind);

        // Exercise WindowsMaintenanceClient end-to-end with the native Windows CMS verifier.
        var fixture = new FakeMaintenancePlatform
        {
            ExpectedPublisher = Convert.ToHexStringLower(publisherDigest),
            CmsVerifierOverride = (raw, pub) => WindowsMaintenanceCmsVerifier.VerifyCmsReceiptForTesting(raw, pub, trustRoots),
        };
        fixture.PinnedDir.ReceiptRaw = validCms;
        var okResult = await fixture.CreateClient().RunModifyAsync(MaintenancePurpose.ConfirmWorkspace, "setup", null);
        Assert.True(okResult.Succeeded);

        fixture.PinnedDir.ReceiptRaw = tamperedPayload;
        var badResult = await fixture.CreateClient().RunModifyAsync(MaintenancePurpose.ConfirmWorkspace, "setup", null);
        Assert.False(badResult.Succeeded);
        Assert.Equal(MaintenanceFailureKind.IdentityMismatch, badResult.FailureKind);
    }

    private static byte[] BuildSignedCmsDer(
        byte[] payload,
        RSA signingKey,
        X509Certificate2 signerCert,
        byte[] serialBigEndian,
        X509Certificate2[] certificates,
        bool detached = false,
        bool corruptSignature = false)
    {
        var writer = new AsnWriter(AsnEncodingRules.DER);
        var ctx0 = new Asn1Tag(TagClass.ContextSpecific, 0, isConstructed: true);
        using (writer.PushSequence())
        {
            writer.WriteObjectIdentifier("1.2.840.113549.1.7.2");
            using (writer.PushSequence(ctx0))
            {
                using (writer.PushSequence())
                {
                    writer.WriteInteger(1);
                    using (writer.PushSetOf())
                    {
                        WriteAlgorithmIdentifier(writer, "2.16.840.1.101.3.4.2.1");
                    }
                    using (writer.PushSequence())
                    {
                        writer.WriteObjectIdentifier("1.2.840.113549.1.7.1");
                        if (!detached)
                        {
                            using (writer.PushSequence(ctx0))
                            {
                                writer.WriteOctetString(payload);
                            }
                        }
                    }
                    using (writer.PushSetOf(ctx0))
                    {
                        foreach (var cert in certificates)
                        {
                            writer.WriteEncodedValue(cert.RawData);
                        }
                    }
                    using (writer.PushSetOf())
                    {
                        using (writer.PushSequence())
                        {
                            writer.WriteInteger(1);
                            using (writer.PushSequence())
                            {
                                writer.WriteEncodedValue(signerCert.IssuerName.RawData);
                                writer.WriteInteger(new BigInteger(serialBigEndian, isUnsigned: true, isBigEndian: true));
                            }
                            WriteAlgorithmIdentifier(writer, "2.16.840.1.101.3.4.2.1");
                            WriteAlgorithmIdentifier(writer, "1.2.840.113549.1.1.1");
                            var signature = signingKey.SignData(payload, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                            if (corruptSignature)
                            {
                                signature[0] ^= 0xFF;
                            }
                            writer.WriteOctetString(signature);
                        }
                    }
                }
            }
        }
        return writer.Encode();
    }

    private static void WriteAlgorithmIdentifier(AsnWriter writer, string oid)
    {
        using (writer.PushSequence())
        {
            writer.WriteObjectIdentifier(oid);
            writer.WriteNull();
        }
    }

    private const uint ProcessSynchronize = 0x00100000;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint ProcessTerminate = 0x0001;
    private const uint WaitObject0 = 0x00000000;
    private const uint WaitTimeout = 0x00000102;

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern nint OpenProcess(uint desiredAccess, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern uint WaitForSingleObject(nint handle, uint milliseconds);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(nint processHandle, uint exitCode);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint handle);

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
                new OnboardingCheck { Id = "assistant_codex", Group = "assistant", State = "ok", Title = "Codex", Detail = "ok", Blocking = false, Enabled = true, Available = true, HasAvailableKey = true, Candidates = [new OnboardingCandidate { Path = @"C:\Tools\codex.exe", Outcome = "selected" }], HasCandidatesKey = true },
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

    private static string BuildValidPreflightJson(string stage) =>
        JsonSerializer.Serialize(new
        {
            schema = OnboardingSchema.PreflightV1,
            ok = true,
            stage,
            configured = true,
            workspace_confirmed = true,
            config_path = "%APPDATA%\\mimi-remote\\config.json",
            scan_root = @"C:\Users\tester\code",
            browse_root = @"C:\Users\tester\code",
            scan_root_exists = true,
            recommended_next = "network_any",
            recommended_transport = "tailcat",
            checks = new object[]
            {
                new { id = "config_store", group = "workspace", state = "ok", title = "配置文件", detail = "ok", blocking = false },
                new { id = "workspace_root", group = "workspace", state = "ok", title = "代码目录", detail = "ok", blocking = false },
                new { id = "service_daemon", group = "service", state = "ok", title = "后台服务", detail = "ok", blocking = false },
                new { id = "assistant_codex", group = "assistant", state = "ok", title = "Codex", detail = "ok", blocking = false, enabled = true, available = true, candidates = new object[] { new { path = @"C:\Tools\codex.exe", outcome = "selected" } } },
                new { id = "assistant_claude", group = "assistant", state = "optional", title = "Claude Code", detail = "opt", blocking = false, code = "claude_not_found", fix = new { kind = "open_url", url = OnboardingCopyCatalog.UrlClaude }, enabled = false, available = false, candidates = Array.Empty<object>() },
                new { id = "assistant_agy", group = "assistant", state = "optional", title = "Antigravity", detail = "opt", blocking = false, code = "agy_not_found", fix = new { kind = "open_url", url = OnboardingCopyCatalog.UrlAgy }, enabled = false, available = false, candidates = Array.Empty<object>() },
                new { id = "assistant_deepseek", group = "assistant", state = "optional", title = "DeepSeek", detail = "opt", blocking = false, code = "deepseek_not_running", fix = new { kind = "open_url", url = OnboardingCopyCatalog.UrlHarness }, enabled = false, available = false },
                new { id = "assistant_any", group = "assistant", state = "ok", title = "AI 助手", detail = "ok", blocking = false },
                new { id = "network_tailscale", group = "network", state = "optional", title = "Tailscale", detail = "opt", blocking = false, code = "tailscale_not_installed", fix = new { kind = "open_url", url = OnboardingCopyCatalog.UrlTailscale }, enabled = false, available = false },
                new { id = "network_tailcat", group = "network", state = "ok", title = "Tailcat", detail = "ok", blocking = false, enabled = true, available = true },
                new { id = "network_lan", group = "network", state = "ok", title = "同一局域网", detail = "ok", blocking = false, enabled = true, available = true },
                new { id = "network_any", group = "network", state = "ok", title = "手机连接通道", detail = "ok", blocking = false },
                new { id = "permission_local_network", group = "permission", state = "optional", title = "本地网络", detail = "opt", blocking = false, code = "permission_unobserved", fix = new { kind = "skip" } },
            },
        });

    private sealed class MetadataTestAssembly(string? publisherSha256) : Assembly
    {
        public override object[] GetCustomAttributes(Type attributeType, bool inherit)
        {
            if (attributeType == typeof(AssemblyMetadataAttribute) && publisherSha256 is not null)
            {
                return [new AssemblyMetadataAttribute(WindowsMaintenanceClient.PublisherMetadataKey, publisherSha256)];
            }
            return [];
        }

        public override object[] GetCustomAttributes(bool inherit) =>
            publisherSha256 is not null
                ? [new AssemblyMetadataAttribute(WindowsMaintenanceClient.PublisherMetadataKey, publisherSha256)]
                : [];
    }

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

        public PinnedBrokerImage VerifyPinnedImage(string fileName, ReadOnlySpan<byte> expectedDigest, ReadOnlySpan<byte> expectedPublisher)
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
            return new PinnedBrokerImage(
                @"\\?\Volume{11111111-2222-3333-4444-555555555555}\Users\tester\AppData\Local\Programs\Mimi Remote\" + fileName,
                @"\Device\HarddiskVolume3\Users\tester\AppData\Local\Programs\Mimi Remote\" + fileName,
                0x12345678,
                1,
                42);
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
        public Exception? ModifyException { get; set; }
        public Func<byte[], byte[], byte[]>? CmsVerifierOverride { get; set; }
        public FakePinnedDirectory PinnedDir { get; } = new();
        public List<(PinnedBrokerImage Broker, string[] Args)> LaunchedCalls { get; } = [];
        public bool BrokerRanWhilePinned { get; private set; }
        public bool StatusReadWhilePinned { get; private set; }
        public bool PreflightReadWhilePinned { get; private set; }
        public bool PairReadWhilePinned { get; private set; }
        public MaintenanceBrokerProcessResult BrokerResult { get; set; } = new("", "", 0);
        public MaintenanceBrokerProcessResult? StatusResult { get; set; }
        public HostStatus PostRunStatus { get; set; } = new()
        {
            Version = "1.2.3",
            ProcessOk = true,
            ServiceOk = true,
            WorkspaceConfirmed = true,
            ModuleStatus = new ModuleStatus { LanEnabled = true, LanAvailable = true },
            NetworkStatus = new HostNetworkStatus
            {
                Mode = "lan",
                AllowLan = true,
                PolicyChecked = true,
                PolicyOk = true,
                FirewallValid = true,
            },
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
            if (CmsVerifierOverride is not null)
            {
                return CmsVerifierOverride(rawReceipt, expectedPublisher.ToArray());
            }
            var text = Encoding.UTF8.GetString(rawReceipt);
            if (!text.StartsWith("CMS:", StringComparison.Ordinal))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }
            return Encoding.UTF8.GetBytes(text["CMS:".Length..]);
        }

        public Task<MaintenanceBrokerProcessResult> RunBrokerAsync(PinnedBrokerImage pinnedBroker, string[] arguments, CancellationToken cancellationToken)
        {
            LaunchedCalls.Add((pinnedBroker, arguments));
            if (arguments.Length > 0 && string.Equals(arguments[0], "status", StringComparison.Ordinal))
            {
                StatusReadWhilePinned = PinnedDir.Pinned;
                if (StatusResult is { } customStatus)
                {
                    return Task.FromResult(customStatus);
                }
                var json = JsonSerializer.Serialize(PostRunStatus, AgentClient.JsonOptions);
                return Task.FromResult(new MaintenanceBrokerProcessResult(json, "", 0));
            }
            if (arguments.Length > 0 && string.Equals(arguments[0], "preflight", StringComparison.Ordinal))
            {
                PreflightReadWhilePinned = PinnedDir.Pinned;
                var stage = arguments.Length >= 4 ? arguments[3] : "setup";
                return Task.FromResult(new MaintenanceBrokerProcessResult(BuildValidPreflightJson(stage), "", 0));
            }
            if (arguments.Length > 0 && string.Equals(arguments[0], "pair", StringComparison.Ordinal))
            {
                PairReadWhilePinned = PinnedDir.Pinned;
                var ticketJson = JsonSerializer.Serialize(new
                {
                    ok = true,
                    endpoint = "http://192.168.1.20:8787",
                    network = "lan",
                    pair_url = "mimiremote://pair?pair_sig=pinned-lan-ticket",
                    pair_expires_at = DateTimeOffset.UtcNow.AddMinutes(5).ToString("O", CultureInfo.InvariantCulture),
                });
                return Task.FromResult(new MaintenanceBrokerProcessResult(ticketJson, "", 0));
            }
            BrokerRanWhilePinned = PinnedDir.Pinned;
            if (ModifyException is not null)
            {
                throw ModifyException;
            }
            return Task.FromResult(BrokerResult);
        }
    }
}
