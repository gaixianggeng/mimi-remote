using System.Reflection;
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
    public async Task BoundProcessRunnerCancellationTerminatesEntireJobTreeOnWindows()
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

        var tempDir = Path.Combine(Path.GetTempPath(), "mimi-maint-job-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
        try
        {
            var lateMarker = Path.Combine(tempDir, "late.txt");
            using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(400));
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
                WindowsMaintenanceProcessRunner.RunBoundProcessAsync(
                    valid,
                    ["/c", $"ping -n 30 127.0.0.1 >nul && echo late > \"{lateMarker}\""],
                    cts.Token));
            Assert.False(File.Exists(lateMarker));
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
        }
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
        public FakePinnedDirectory PinnedDir { get; } = new();
        public List<(PinnedBrokerImage Broker, string[] Args)> LaunchedCalls { get; } = [];
        public bool BrokerRanWhilePinned { get; private set; }
        public bool StatusReadWhilePinned { get; private set; }
        public bool PreflightReadWhilePinned { get; private set; }
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
            BrokerRanWhilePinned = PinnedDir.Pinned;
            if (ModifyException is not null)
            {
                throw ModifyException;
            }
            return Task.FromResult(BrokerResult);
        }
    }
}
