using System.Globalization;
using MimiRemote.App;
using MimiRemote.App.ViewModels;
using MimiRemote.Core;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class OnboardingViewModelTests
{
    [Fact]
    public void 四状态门禁统一约束全部八项导航与托盘和配对深链()
    {
        var unconfigured = BuildWindowsReport(stage: "setup", configured: false, workspaceConfirmed: false);
        var pending = BuildWindowsReport(stage: "setup", configured: true, workspaceConfirmed: false);
        var confirmed = BuildWindowsReport(stage: "pair", configured: true, workspaceConfirmed: true, serviceOk: true, tailscaleReady: true);
        var recovery = BuildWindowsReport(stage: "setup", configured: true, workspaceConfirmed: false, configCode: "config_invalid");

        Assert.Equal(OnboardingGateState.Unconfigured, OnboardingNavigationGate.Evaluate(unconfigured));
        Assert.Equal(OnboardingGateState.PendingConfirmation, OnboardingNavigationGate.Evaluate(pending));
        Assert.Equal(OnboardingGateState.Confirmed, OnboardingNavigationGate.Evaluate(confirmed));
        Assert.Equal(OnboardingGateState.RecoveryLocked, OnboardingNavigationGate.Evaluate(recovery));
        Assert.Equal(OnboardingGateState.Confirmed, OnboardingNavigationGate.Evaluate(null, null, preview: true));

        Assert.Equal(8, OnboardingNavigationGate.AllRoutes.Count);

        OnboardingGateState[] lockedStates =
        [
            OnboardingGateState.Unconfigured,
            OnboardingGateState.PendingConfirmation,
            OnboardingGateState.RecoveryLocked,
        ];
        string[] blockedRoutes =
        [
            OnboardingNavigationGate.RouteSessions,
            OnboardingNavigationGate.RouteOverview,
            OnboardingNavigationGate.RoutePair,
            OnboardingNavigationGate.RouteConnection,
            OnboardingNavigationGate.RouteAssistants,
        ];
        foreach (var locked in lockedStates)
        {
            Assert.False(OnboardingNavigationGate.IsSettingsEditable(locked));
            Assert.Equal(OnboardingNavigationGate.RouteSetup, OnboardingNavigationGate.HomeRoute(locked));
            Assert.Equal(OnboardingNavigationGate.RouteSetup, OnboardingNavigationGate.ResolveActivationRoute(locked, pairRequested: false));
            Assert.Equal(OnboardingNavigationGate.RouteSetup, OnboardingNavigationGate.ResolveActivationRoute(locked, pairRequested: true));

            Assert.True(OnboardingNavigationGate.IsRouteAllowed(locked, OnboardingNavigationGate.RouteSetup));
            Assert.True(OnboardingNavigationGate.IsRouteAllowed(locked, OnboardingNavigationGate.RouteDiagnostics));
            Assert.True(OnboardingNavigationGate.IsRouteAllowed(locked, OnboardingNavigationGate.RouteSettings));

            foreach (var blockedRoute in blockedRoutes)
            {
                Assert.False(OnboardingNavigationGate.IsRouteAllowed(locked, blockedRoute));
                Assert.Equal(OnboardingNavigationGate.RouteSetup, OnboardingNavigationGate.ResolveRoute(locked, blockedRoute));
            }
        }

        Assert.True(OnboardingNavigationGate.IsSettingsEditable(OnboardingGateState.Confirmed));
        Assert.Equal(OnboardingNavigationGate.RouteSessions, OnboardingNavigationGate.HomeRoute(OnboardingGateState.Confirmed));
        Assert.Equal(OnboardingNavigationGate.RoutePair, OnboardingNavigationGate.ResolveActivationRoute(OnboardingGateState.Confirmed, pairRequested: true));
        foreach (var route in OnboardingNavigationGate.AllRoutes)
        {
            Assert.True(OnboardingNavigationGate.IsRouteAllowed(OnboardingGateState.Confirmed, route));
            Assert.Equal(route, OnboardingNavigationGate.ResolveRoute(OnboardingGateState.Confirmed, route));
        }
    }

    [Fact]
    public async Task 向导首次保存最小权限目录且启动失败可重试不重放保存()
    {
        var scanDir = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "mimi-ui4-fresh"));
        var backend = new FakeWizardBackend
        {
            ExistingDirs = { scanDir },
        };
        var setupReport = BuildWindowsReport(stage: "setup", configured: false, workspaceConfirmed: false, scanRoot: scanDir, browseRoot: scanDir, codexReady: false);
        var pairFailedService = BuildWindowsReport(stage: "pair", configured: true, workspaceConfirmed: true, scanRoot: scanDir, browseRoot: scanDir, serviceOk: false);
        var pairReadyService = BuildWindowsReport(stage: "pair", configured: true, workspaceConfirmed: true, scanRoot: scanDir, browseRoot: scanDir, serviceOk: true, tailscaleReady: true);

        var upAttempts = 0;
        backend.OnPreflight = (opts, _, _) => Task.FromResult(
            string.Equals(opts.Stage, "setup", StringComparison.Ordinal)
                ? setupReport
                : upAttempts >= 2 ? pairReadyService : pairFailedService);
        backend.OnUp = (_, _) =>
        {
            upAttempts++;
            if (upAttempts == 1)
            {
                throw new TimeoutException("start timeout");
            }
            return Task.FromResult(new UpReadinessReceipt { Ok = true, ServiceOk = true, Version = "1.0.0" });
        };

        using var sm = new OnboardingWizardStateMachine(backend);
        await sm.StartAsync();

        // Zero assistants and zero external networks still allow proceeding to Step 2.
        Assert.Equal(OnboardingWizardStep.EnvironmentCheck, sm.CurrentStep);
        Assert.True(sm.CanProceedFromEnvironmentCheck);
        Assert.Equal(OnboardingGateState.Unconfigured, sm.GateState);

        await sm.ProceedToWorkspaceStepAsync();
        Assert.Equal(OnboardingWizardStep.WorkspaceSelection, sm.CurrentStep);
        Assert.Equal(scanDir, sm.EffectiveBrowseRoot);

        // Save once; first UpAsync fails -> stays on Step 3 in Failed phase, no workspace call.
        await sm.SaveWorkspaceAndContinueAsync();
        Assert.Equal(OnboardingWizardStep.ServiceAndPermissions, sm.CurrentStep);
        Assert.Equal(OnboardingServicePhase.Failed, sm.ServicePhase);
        Assert.Single(backend.SetupCalls);
        Assert.Equal(scanDir, backend.SetupCalls[0].Options.BrowseRoot);
        Assert.True(backend.SetupCalls[0].Options.NoPair);
        Assert.Empty(backend.WorkspaceCalls);
        Assert.Equal(1, upAttempts);

        // Retry service start -> ONLY calls UpAsync, NEVER replays setup!
        await sm.EnsureServiceReadyAsync();
        Assert.Equal(OnboardingServicePhase.Ready, sm.ServicePhase);
        Assert.Equal(OnboardingGateState.Confirmed, sm.GateState);
        Assert.Single(backend.SetupCalls);
        Assert.Equal(2, upAttempts);
    }

    [Fact]
    public async Task 待确认状态更新目录调用Workspace而非重放Setup且已有独立浏览目录得以保留()
    {
        var oldScan = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "mimi-ui4-old-scan"));
        var newScan = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "mimi-ui4-new-scan"));
        var widerBrowse = Path.GetFullPath(Path.GetTempPath());
        var backend = new FakeWizardBackend
        {
            ExistingDirs = { oldScan, newScan },
        };
        backend.OnPreflight = (opts, _, _) => Task.FromResult(
            string.Equals(opts.Stage, "setup", StringComparison.Ordinal)
                ? BuildWindowsReport(stage: "setup", configured: true, workspaceConfirmed: false, scanRoot: opts.ScanRoot ?? oldScan, browseRoot: widerBrowse)
                : BuildWindowsReport(stage: "pair", configured: true, workspaceConfirmed: true, scanRoot: newScan, browseRoot: widerBrowse, serviceOk: true, tailscaleReady: true));

        using var sm = new OnboardingWizardStateMachine(backend);
        await sm.StartAsync();
        Assert.Equal(OnboardingGateState.PendingConfirmation, sm.GateState);
        Assert.Equal(widerBrowse, sm.EffectiveBrowseRoot);

        await sm.ProceedToWorkspaceStepAsync();
        await sm.SelectWorkspaceRootAsync(newScan);
        await sm.SaveWorkspaceAndContinueAsync();

        // Must call UpdateWorkspaceAsync with null browseRoot (to preserve widerBrowse) and NEVER SetupNoPairAsync.
        Assert.Empty(backend.SetupCalls);
        var wsCall = Assert.Single(backend.WorkspaceCalls);
        Assert.Equal(newScan, wsCall.ScanRoot);
        Assert.Null(wsCall.BrowseRoot);
        Assert.Equal(1, backend.UpCallCount);
        Assert.Equal(OnboardingGateState.Confirmed, sm.GateState);
    }

    [Fact]
    public async Task 流式预检取消后丢弃迟到更新且未配置阶段助手草稿不写配置()
    {
        var scanDir = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "mimi-ui4-stream"));
        var backend = new FakeWizardBackend { ExistingDirs = { scanDir } };
        var slowGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var callIndex = 0;

        backend.OnPreflight = async (opts, onProgress, ct) =>
        {
            var current = ++callIndex;
            if (current == 1)
            {
                onProgress?.Invoke(new OnboardingCheck
                {
                    Id = "assistant_codex",
                    Group = "assistant",
                    State = "checking",
                    Title = "Codex 助手",
                    Detail = "正在检查 Codex。",
                    Blocking = false,
                    Enabled = false,
                    Available = null,
                    Candidates = [],
                });
                await slowGate.Task.WaitAsync(ct);
            }
            return BuildWindowsReport(stage: "setup", configured: false, workspaceConfirmed: false, scanRoot: scanDir, browseRoot: scanDir, codexReady: false, codexDisabledAvailable: true);
        };

        using var sm = new OnboardingWizardStateMachine(backend);
        var first = sm.RunPreflightAsync("setup");
        sm.CancelPreflight();
        slowGate.TrySetResult();
        await first;

        await sm.RunPreflightAsync("setup");
        Assert.False(sm.IsConfigured);

        // Clicking enable_codex when !configured mutates in-memory draft ONLY, never calls EnableAssistantAsync!
        await sm.PerformCheckPrimaryActionAsync("assistant_codex");
        Assert.Empty(backend.EnabledAssistants);
        Assert.Contains(("codex", "enabled"), sm.DraftAssistantsSnapshot);

        // Pinning and resetting runtime path before save stays in memory draft.
        var fakeBin = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "codex.exe"));
        await sm.SelectRuntimePathAsync("codex", fakeBin);
        Assert.Empty(backend.RuntimePathCalls);
        Assert.Contains(("codex", fakeBin), sm.DraftRuntimePathsSnapshot);

        await sm.ResetRuntimePathToAutoAsync("codex");
        Assert.Contains(("codex", "auto"), sm.DraftRuntimePathsSnapshot);
    }

    [Fact]
    public async Task 配对会话按D2排序选中零写入且私密链接随倒计时与切通道清空()
    {
        var now = new DateTimeOffset(2026, 11, 26, 12, 0, 0, TimeSpan.Zero);
        var backend = new FakePairingBackend(() => now);
        var report = BuildWindowsReport(
            stage: "pair",
            configured: true,
            workspaceConfirmed: true,
            serviceOk: true,
            tailscaleReady: false,
            tailscaleDisabledAvailable: true,
            tailcatReady: true,
            lanPublicBlocked: true);
        backend.Report = report;

        using var controller = new PairingSessionController(backend);
        controller.SetActive(true);
        await controller.RefreshAsync();

        // D2 order always fixed: tailscale -> tailcat -> lan.
        Assert.Equal(["tailscale", "tailcat", "lan"], controller.Transports.Select(t => t.Id).ToArray());
        // Recommended transport auto-selected with ZERO mutating writes.
        Assert.Equal("tailscale", controller.SelectedTransport);
        Assert.Empty(backend.EnabledTransports);
        Assert.False(controller.CanGenerate);
        Assert.True(controller.CanEnableSelectedTransport);

        // Selecting tailcat does not write; since tailcat is ready, we can generate a ticket.
        controller.SelectTransport("tailcat");
        Assert.Empty(backend.EnabledTransports);
        Assert.True(controller.CanGenerate);

        const string realPairUrl = "mimiremote://pair?host=test&pair_sig=real-secret-ticket";
        backend.NextTicket = new PairingTicketReceipt
        {
            Ok = true,
            Endpoint = "http://127.0.0.1:8787",
            PairUrl = realPairUrl,
            PairExpiresAt = now.AddMinutes(3).ToString("O", CultureInfo.InvariantCulture),
            Network = "tailcat",
        };

        await controller.GenerateAsync();
        Assert.True(controller.HasActiveTicket);
        Assert.True(controller.CanCopyLink);
        Assert.Contains("03:00", controller.CountdownText, StringComparison.Ordinal);

        await controller.RefreshAsync();
        Assert.True(controller.HasActiveTicket);

        // Copy copies the REAL pair_url, never Endpoint.
        Assert.True(controller.CopyPairingLink());
        Assert.Equal(realPairUrl, backend.LastCopiedText);

        // Advance time past expiry -> countdown clears private pair_url and disables copy!
        now = now.AddMinutes(3).AddSeconds(1);
        controller.TickCountdown();
        Assert.False(controller.HasActiveTicket);
        Assert.False(controller.CanCopyLink);
        Assert.False(controller.CopyPairingLink());

        // Generate again, then switch transport -> immediately clears ticket & disables copy.
        now = new DateTimeOffset(2026, 11, 26, 12, 0, 0, TimeSpan.Zero);
        await controller.GenerateAsync();
        Assert.True(controller.CanCopyLink);
        controller.SelectTransport("lan");
        Assert.False(controller.HasActiveTicket);
        Assert.False(controller.CanCopyLink);

        // On public network LAN, clicking Enable opens windows_network_profile and keeps LAN disabled.
        await controller.EnableSelectedTransportAsync();
        Assert.Empty(backend.EnabledTransports);
        Assert.Equal(["windows_network_profile"], backend.OpenedSettings);

        // In-place enable for Tailscale succeeds without leaving PairingPage.
        controller.SelectTransport("tailscale");
        backend.OnEnableTransport = t =>
        {
            backend.Report = BuildWindowsReport(
                stage: "pair",
                configured: true,
                workspaceConfirmed: true,
                serviceOk: true,
                tailscaleReady: true,
                tailcatReady: true);
            return Task.CompletedTask;
        };
        backend.NextTicket = null;
        await controller.EnableSelectedTransportAsync();
        Assert.Equal(["tailscale"], backend.EnabledTransports);
        Assert.True(controller.HasActiveTicket);
    }

    [Fact]
    public async Task 局域网防火墙提权取消保持LAN关闭且不影响其他通道()
    {
        var now = new DateTimeOffset(2026, 11, 26, 12, 0, 0, TimeSpan.Zero);
        var backend = new FakePairingBackend(() => now)
        {
            LanMaintenanceResult = false,
            Report = BuildWindowsReport(
                stage: "pair",
                configured: true,
                workspaceConfirmed: true,
                serviceOk: true,
                tailcatReady: true,
                lanFirewallBlocked: true),
        };

        using var controller = new PairingSessionController(backend);
        controller.SetActive(true);
        await controller.RefreshAsync();

        controller.SelectTransport("lan");
        Assert.True(controller.CanEnableSelectedTransport);
        await controller.EnableSelectedTransportAsync();

        Assert.Equal(1, backend.LanMaintenanceCalls);
        Assert.Empty(backend.EnabledTransports);
        Assert.Contains("同一局域网保持关闭", controller.Note, StringComparison.Ordinal);

        // Other ready transport (tailcat) remains fully usable.
        controller.SelectTransport("tailcat");
        Assert.True(controller.CanGenerate);
    }

    [Fact]
    public async Task 助手页独立呈现Claude与Agy相反状态并正确翻译状态与陈旧配额()
    {
        var context = new ClientContext
        {
            Status = new HostStatus
            {
                ServiceOk = true,
                ModuleStatus = new ModuleStatus { CodexEnabled = true, ClaudeEnabled = true, AgyEnabled = false },
                RuntimeStatus = new RuntimeStatus
                {
                    Runtimes =
                    [
                        new RuntimeEntry
                        {
                            Id = "codex",
                            Title = "Codex",
                            Enabled = true,
                            State = "ready",
                            Version = "0.150.0",
                            Reason = "quota_refresh_in_progress",
                            RateLimits = new RuntimeRateLimits { Availability = "unavailable" },
                        },
                        new RuntimeEntry
                        {
                            Id = "claude",
                            Title = "Claude",
                            Enabled = true,
                            State = "unavailable",
                            Reason = "refresh_in_progress",
                        },
                        new RuntimeEntry
                        {
                            Id = "agy",
                            Title = "Antigravity",
                            Enabled = false,
                            State = "signed_out",
                        },
                        new RuntimeEntry
                        {
                            Id = "deepseek",
                            Title = "DeepSeek",
                            Enabled = true,
                            State = "unavailable",
                            Reason = "account_unavailable",
                        },
                    ],
                },
            },
        };
        var preflight = BuildWindowsReport(stage: "pair", configured: true, workspaceConfirmed: true, serviceOk: true, agyUnsupported: true);
        context.Agent.PreflightHandler = (_, _, _) => Task.FromResult(preflight);

        using var vm = new AssistantsViewModel(context);
        await vm.RefreshCommand.ExecuteAsync(null);

        // Stale quota MUST NOT mark ready Codex unavailable.
        Assert.Equal("可用", vm.Codex.Badge);
        Assert.Contains("不影响", vm.Codex.QuotaText, StringComparison.Ordinal);

        // Legacy unavailable + refresh_in_progress translates cleanly to "正在检查".
        Assert.Equal("正在检查", vm.Claude.Badge);
        Assert.DoesNotContain("refresh_in_progress", vm.Claude.Detail, StringComparison.Ordinal);

        // Agy independently reports runtime_unsupported_platform and disables toggle without affecting Claude!
        Assert.False(vm.Agy.Supported);
        Assert.False(vm.Agy.CanToggle);
        Assert.Equal("当前平台不支持", vm.Agy.Badge);
        Assert.True(vm.Claude.Supported);

        // Unknown login/account failure maps to runtime_probe_failed, NOT signed_out.
        var unknownLogin = AssistantRuntimePresentation.Describe(
            "codex",
            "Codex",
            enabled: true,
            new RuntimeEntry { Id = "codex", Enabled = true, State = "unavailable", Reason = "account_unavailable" });
        Assert.Equal("runtime_probe_failed", unknownLogin.DiagnosticCode);
        Assert.Equal("暂不可用", unknownLogin.BadgeText);

        // Positive signed_out maps cleanly to *_signed_out.
        var positiveSignedOut = AssistantRuntimePresentation.Describe(
            "agy",
            "Antigravity",
            enabled: true,
            new RuntimeEntry { Id = "agy", Enabled = true, State = "signed_out", Version = "1.5.0" });
        Assert.Equal("agy_signed_out", positiveSignedOut.DiagnosticCode);
        Assert.Equal("需要登录", positiveSignedOut.BadgeText);
    }

    [Fact]
    public async Task 诊断页Doctor仅只读且权限修复仅限BE3验证宿主与零Token轮换()
    {
        var context = new ClientContext();
        var unsafePermsReport = BuildWindowsReport(
            stage: "setup",
            configured: true,
            workspaceConfirmed: true,
            configCode: "config_permissions_unsafe");
        context.Agent.PreflightHandler = (_, _, _) => Task.FromResult(unsafePermsReport);
        context.Agent.RunHandler = (args, _) => Task.FromResult(args[0] switch
        {
            "doctor" when args.Contains("--json", StringComparer.Ordinal) && !args.Contains("--fix", StringComparer.Ordinal) =>
                """{"ok":false,"version":"1.0.0","checks":[{"name":"config_permissions","ok":false,"level":"error","message":"权限过宽","fix":"修复权限","capability":"identity_preserving_doctor_fix"}]}""",
            "doctor" when args.Contains("--fix", StringComparer.Ordinal) => """{"ok":true}""",
            _ => "{}",
        });

        using var vm = new DiagnosticsViewModel(context);
        await vm.RefreshCommand.ExecuteAsync(null);

        // Before BE-3 capability is verified, doctor_fix MUST NOT be clickable.
        var configRowBefore = Assert.Single(vm.PreflightRows, r => string.Equals(r.Check.Id, "config_store", StringComparison.Ordinal));
        Assert.False(configRowBefore.HasPrimaryAction);
        await vm.FixCheckCommand.ExecuteAsync("config_store");
        Assert.DoesNotContain(context.Agent.Calls, c => c.Contains("--fix", StringComparer.Ordinal));

        // Running read-only doctor --json populates Chinese read-only items and detects capability.
        await vm.DoctorCommand.ExecuteAsync(null);
        Assert.True(vm.HasDoctorItems);
        Assert.Equal("配置文件权限", vm.DoctorItems[0].Title);
        Assert.Equal(OnboardingSchema.DoctorFixCapability, context.VerifiedCapability);

        // Refreshing preflight now enables safe identity-preserving doctor_fix ONLY for config_permissions_unsafe.
        await vm.RefreshCommand.ExecuteAsync(null);
        var configRowAfter = Assert.Single(vm.PreflightRows, r => string.Equals(r.Check.Id, "config_store", StringComparison.Ordinal));
        Assert.True(configRowAfter.HasPrimaryAction);

        await vm.FixCheckCommand.ExecuteAsync("config_store");
        Assert.Contains(context.Agent.Calls, c => c.Length == 3 && c[0] == "doctor" && c[1] == "--fix" && c[2] == "--json");

        context.Agent.RunHandler = (_, _) => Task.FromResult(
            """{"ok":false,"checks":[{"name":"private-doctor-name","message":"private-doctor-message","fix":"private-harness-link"}]}""");
        await vm.DoctorCommand.ExecuteAsync(null);
        Assert.DoesNotContain("private-", vm.Output, StringComparison.Ordinal);
        Assert.Equal("其他诊断项", Assert.Single(vm.DoctorItems).Title);

        // Recovery paths are shown read-only and log scrubber strips secrets.
        var scrubbed = DiagnosticSanitizer.ScrubLogText("Authorization: Bearer topsecret123 mimiremote://pair?pair_sig=abc eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig1234567890");
        Assert.DoesNotContain("topsecret123", scrubbed, StringComparison.Ordinal);
        Assert.DoesNotContain("pair_sig=abc", scrubbed, StringComparison.Ordinal);
        Assert.DoesNotContain("eyJhbGci", scrubbed, StringComparison.Ordinal);
        var structured = DiagnosticSanitizer.ScrubLogText("""{"grant":"private-grant","path":"private-path","socket":"wss://example.invalid/private"}""");
        Assert.DoesNotContain("private", structured, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConfirmedFolderSelectionCommitsTheDraftAndReloadsTheRunningServiceOnce()
    {
        var oldRoot = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "previous-workspace"));
        var nextRoot = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "selected-workspace"));
        var backend = new FakeWizardBackend { ExistingDirs = { oldRoot, nextRoot } };
        backend.OnPreflight = (options, _, _) =>
        {
            var root = options.ScanRoot ?? backend.WorkspaceCalls.LastOrDefault().ScanRoot ?? oldRoot;
            return Task.FromResult(BuildWindowsReport(options.Stage, true, true, scanRoot: root, serviceOk: true));
        };
        using var wizard = new OnboardingWizardStateMachine(backend);
        await wizard.StartAsync();
        await wizard.ProceedToWorkspaceStepAsync();
        await wizard.SelectWorkspaceRootAsync(nextRoot);
        Assert.Equal(nextRoot, wizard.Report!.ScanRoot);
        Assert.Empty(backend.WorkspaceCalls);
        await wizard.SaveWorkspaceAndContinueAsync();

        var call = Assert.Single(backend.WorkspaceCalls);
        Assert.Equal(nextRoot, call.ScanRoot);
        Assert.Equal(nextRoot, call.BrowseRoot);
        Assert.Equal(1, backend.RestartCalls);
        Assert.Equal(0, backend.UpCallCount);
        Assert.Empty(backend.SetupCalls);
    }

    [Fact]
    public async Task FailedPreflightRevokesConfirmedNavigationAndCannotWriteOrStart()
    {
        var context = new ClientContext();
        var root = Path.GetFullPath(Path.GetTempPath());
        context.Agent.PreflightHandler = (_, _, _) => Task.FromResult(BuildWindowsReport("setup", true, true, root));
        using var vm = new SetupViewModel(context);
        await vm.RefreshCommand.ExecuteAsync(null);
        Assert.Equal(OnboardingGateState.Confirmed, context.GateState);

        context.Agent.PreflightHandler = (_, _, _) => throw new OnboardingCliException(new OnboardingResolvedDiagnostic
        {
            Step = "config_store",
            Code = "config_invalid",
            Message = "需要恢复配置。",
        });
        await vm.RefreshCommand.ExecuteAsync(null);
        Assert.Equal(OnboardingGateState.RecoveryLocked, context.GateState);
        Assert.Null(vm.Wizard.Report);
        await vm.FinishCommand.ExecuteAsync(null);
        await vm.RetryServiceCommand.ExecuteAsync(null);
        Assert.All(context.Agent.Calls, call => Assert.Equal("preflight", call[0]));
    }

    [Fact]
    public async Task RowActionAwaitsTheNativeRuntimePicker()
    {
        var root = Path.GetFullPath(Path.GetTempPath());
        var binary = Path.Combine(root, "fixture.exe");
        var context = new ClientContext { PickFile = () => Task.FromResult<string?>(binary) };
        var report = BuildWindowsReport("setup", false, false, root, codexReady: false);
        var checks = report.Checks.Select(row => row.Id != "assistant_codex" ? row : row with
        {
            State = "error",
            Code = "runtime_path_invalid",
            Fix = OnboardingFix.ChoosePath("codex_bin"),
        }).ToArray();
        context.Agent.PreflightHandler = (_, _, _) => Task.FromResult(report with { Checks = checks });
        using var vm = new SetupViewModel(context);
        await vm.RefreshCommand.ExecuteAsync(null);
        await vm.RowPrimaryActionCommand.ExecuteAsync("assistant_codex");
        Assert.Contains(("codex", binary), vm.Wizard.DraftRuntimePathsSnapshot);
    }

    [Fact]
    public async Task PairingDiscardsMismatchedAndLateReceipts()
    {
        var backend = new FakePairingBackend(() => DateTimeOffset.UnixEpoch)
        {
            Report = BuildWindowsReport("pair", true, true, serviceOk: true, tailscaleReady: true),
        };
        using var session = new PairingSessionController(backend);
        session.SetActive(true);
        await session.RefreshAsync();
        var receipt = new PairingTicketReceipt
        {
            PairUrl = "mimiremote://pair?pair_sig=fixture",
            PairExpiresAt = "2030-01-01T00:00:00Z",
            Endpoint = "http://localhost",
            Network = "lan",
        };
        backend.NextTicket = receipt;
        await session.GenerateAsync();
        Assert.False(session.CopyPairingLink());

        var pending = new TaskCompletionSource<PairingTicketReceipt>(TaskCreationOptions.RunContinuationsAsynchronously);
        backend.PendingTicket = pending.Task;
        var issue = session.GenerateAsync();
        session.SetActive(false);
        pending.SetResult(receipt with { Network = "tailscale" });
        await issue;
        Assert.False(session.HasActiveTicket);
        Assert.Null(backend.LastCopiedText);
    }

    [Fact]
    public async Task AsynchronousBackendResultsNotifyOnTheCallingScheduler()
    {
        var schedulers = new ConcurrentExclusiveSchedulerPair();
        var scheduler = schedulers.ExclusiveScheduler;
        await Task.Factory.StartNew(async () =>
        {
            var observed = new List<TaskScheduler>();
            var backend = new FakeWizardBackend();
            backend.OnPreflight = async (options, _, _) =>
            {
                await Task.Yield();
                return BuildWindowsReport(options.Stage, true, true);
            };
            using var wizard = new OnboardingWizardStateMachine(backend);
            wizard.GateEvaluated += (_, _) => observed.Add(TaskScheduler.Current);
            await wizard.StartAsync();

            var pending = new TaskCompletionSource<PairingTicketReceipt>(TaskCreationOptions.RunContinuationsAsynchronously);
            var pairing = new FakePairingBackend(() => DateTimeOffset.UnixEpoch)
            {
                Report = BuildWindowsReport("pair", true, true, serviceOk: true, tailscaleReady: true),
                PendingTicket = pending.Task,
            };
            using var session = new PairingSessionController(pairing);
            session.SetActive(true);
            await session.RefreshAsync();
            session.TicketChanged += (_, url) =>
            {
                if (url is not null)
                {
                    observed.Add(TaskScheduler.Current);
                }
            };
            var issuance = session.GenerateAsync();
            pending.SetResult(new PairingTicketReceipt
            {
                Endpoint = "http://localhost",
                PairExpiresAt = "2030-01-01T00:00:00Z",
                PairUrl = "mimiremote://pair?pair_sig=fixture",
                Network = "tailscale",
            });
            await issuance;
            Assert.Equal(2, observed.Count);
            Assert.All(observed, actual => Assert.Same(scheduler, actual));
        }, CancellationToken.None, TaskCreationOptions.None, scheduler).Unwrap();
        schedulers.Complete();
        await schedulers.Completion;
    }

    private static OnboardingPreflightReport BuildWindowsReport(
        string stage,
        bool configured,
        bool workspaceConfirmed,
        string scanRoot = @"C:\fixture\workspace",
        string? browseRoot = null,
        bool serviceOk = false,
        bool codexReady = true,
        bool codexDisabledAvailable = false,
        bool agyUnsupported = false,
        bool tailscaleReady = false,
        bool tailscaleDisabledAvailable = false,
        bool tailcatReady = false,
        bool lanPublicBlocked = false,
        bool lanFirewallBlocked = false,
        string? configCode = null)
    {
        var effectiveBrowse = browseRoot ?? scanRoot;
        var isPair = string.Equals(stage, "pair", StringComparison.Ordinal);

        OnboardingCheck configCheck;
        if (string.Equals(configCode, "config_invalid", StringComparison.Ordinal))
        {
            configCheck = new OnboardingCheck
            {
                Id = "config_store",
                Group = "workspace",
                State = "error",
                Title = "配置文件",
                Detail = "配置无法安全读取。",
                Blocking = true,
                Code = "config_invalid",
                Fix = OnboardingFix.OpenSettings("host_recovery"),
                ConfigPath = "…/config.json",
                RecoveryPath = "…/recovery.json",
                HasCodeKey = true,
                HasFixKey = true,
                HasConfigPathKey = true,
                HasRecoveryPathKey = true,
            };
        }
        else if (string.Equals(configCode, "config_permissions_unsafe", StringComparison.Ordinal))
        {
            configCheck = new OnboardingCheck
            {
                Id = "config_store",
                Group = "workspace",
                State = "error",
                Title = "配置文件",
                Detail = "配置文件权限过宽。",
                Blocking = true,
                Code = "config_permissions_unsafe",
                Fix = configured ? OnboardingFix.RunFix("doctor_fix") : OnboardingFix.RunFix("save_setup"),
                HasCodeKey = true,
                HasFixKey = true,
            };
        }
        else if (!configured)
        {
            configCheck = new OnboardingCheck
            {
                Id = "config_store",
                Group = "workspace",
                State = "action_needed",
                Title = "配置文件",
                Detail = "请先选择代码目录并保存配置。",
                Blocking = isPair,
                Code = "config_missing",
                Fix = OnboardingFix.RunFix("save_setup"),
                HasCodeKey = true,
                HasFixKey = true,
            };
        }
        else
        {
            configCheck = new OnboardingCheck
            {
                Id = "config_store",
                Group = "workspace",
                State = "ok",
                Title = "配置文件",
                Detail = "配置文件可安全读写。",
                Blocking = false,
            };
        }

        var workspaceCheck = configured && !workspaceConfirmed
            ? new OnboardingCheck
            {
                Id = "workspace_root",
                Group = "workspace",
                State = "action_needed",
                Title = "代码目录",
                Detail = "请先确认代码目录。",
                Blocking = isPair,
                Code = "workspace_confirmation_required",
                Fix = OnboardingFix.ChoosePath("workspace_root"),
                HasCodeKey = true,
                HasFixKey = true,
            }
            : new OnboardingCheck
            {
                Id = "workspace_root",
                Group = "workspace",
                State = "ok",
                Title = "代码目录",
                Detail = "所选目录可读取。",
                Blocking = false,
            };

        var serviceCheck = serviceOk
            ? new OnboardingCheck
            {
                Id = "service_daemon",
                Group = "service",
                State = "ok",
                Title = "后台服务",
                Detail = "后台服务已通过就绪检查。",
                Blocking = false,
            }
            : new OnboardingCheck
            {
                Id = "service_daemon",
                Group = "service",
                State = "action_needed",
                Title = "后台服务",
                Detail = "后台服务尚未运行。",
                Blocking = isPair,
                Code = "service_not_running",
                Fix = configured ? OnboardingFix.RunFix("restart_service") : OnboardingFix.RunFix("save_setup"),
                HasCodeKey = true,
                HasFixKey = true,
            };

        var codexCheck = codexReady
            ? new OnboardingCheck
            {
                Id = "assistant_codex",
                Group = "assistant",
                State = "ok",
                Title = "Codex 助手",
                Detail = "Codex 已就绪。",
                Blocking = false,
                Enabled = true,
                Available = true,
                HasAvailableKey = true,
                HasCandidatesKey = true,
                Candidates = [new OnboardingCandidate { Path = @"C:\fixture\bin\codex.exe", Outcome = "selected", Version = "0.150.0" }],
            }
            : codexDisabledAvailable
                ? new OnboardingCheck
                {
                    Id = "assistant_codex",
                    Group = "assistant",
                    State = "optional",
                    Title = "Codex 助手",
                    Detail = "已检测到可用助手。",
                    Blocking = false,
                    Enabled = false,
                    Available = true,
                    Code = "assistant_disabled",
                    Fix = OnboardingFix.RunFix("enable_codex"),
                    HasAvailableKey = true,
                    HasCandidatesKey = true,
                    HasCodeKey = true,
                    HasFixKey = true,
                    Candidates = [new OnboardingCandidate { Path = @"C:\fixture\bin\codex.exe", Outcome = "selected", Version = "0.150.0" }],
                }
                : new OnboardingCheck
                {
                    Id = "assistant_codex",
                    Group = "assistant",
                    State = "optional",
                    Title = "Codex 助手",
                    Detail = "未找到 Codex。",
                    Blocking = false,
                    Enabled = false,
                    Available = false,
                    Code = "codex_not_found",
                    Fix = OnboardingFix.OpenUrl(OnboardingCopyCatalog.UrlCodex),
                    HasAvailableKey = true,
                    HasCandidatesKey = true,
                    HasCodeKey = true,
                    HasFixKey = true,
                    Candidates = [],
                };

        var claudeCheck = new OnboardingCheck
        {
            Id = "assistant_claude",
            Group = "assistant",
            State = "optional",
            Title = "Claude Code 助手",
            Detail = "未找到 Claude Code。",
            Blocking = false,
            Enabled = false,
            Available = false,
            Code = "claude_not_found",
            Fix = OnboardingFix.OpenUrl(OnboardingCopyCatalog.UrlClaude),
            HasAvailableKey = true,
            HasCandidatesKey = true,
            HasCodeKey = true,
            HasFixKey = true,
            Candidates = [],
        };

        var agyCheck = agyUnsupported
            ? new OnboardingCheck
            {
                Id = "assistant_agy",
                Group = "assistant",
                State = "optional",
                Title = "Antigravity 助手",
                Detail = "当前平台尚不支持此助手。",
                Blocking = false,
                Enabled = false,
                Available = false,
                Code = "runtime_unsupported_platform",
                Fix = OnboardingFix.Skip,
                HasAvailableKey = true,
                HasCandidatesKey = true,
                HasCodeKey = true,
                HasFixKey = true,
                Candidates = [],
            }
            : new OnboardingCheck
            {
                Id = "assistant_agy",
                Group = "assistant",
                State = "optional",
                Title = "Antigravity 助手",
                Detail = "未找到 Antigravity。",
                Blocking = false,
                Enabled = false,
                Available = false,
                Code = "agy_not_found",
                Fix = OnboardingFix.OpenUrl(OnboardingCopyCatalog.UrlAgy),
                HasAvailableKey = true,
                HasCandidatesKey = true,
                HasCodeKey = true,
                HasFixKey = true,
                Candidates = [],
            };

        var deepseekCheck = new OnboardingCheck
        {
            Id = "assistant_deepseek",
            Group = "assistant",
            State = "optional",
            Title = "DeepSeek 助手",
            Detail = "未检测到 DeepSeek Harness。",
            Blocking = false,
            Enabled = false,
            Available = false,
            Code = "deepseek_not_running",
            Fix = OnboardingFix.OpenUrl(OnboardingCopyCatalog.UrlHarness),
            HasAvailableKey = true,
            HasCodeKey = true,
            HasFixKey = true,
        };

        var anyAssistant = codexReady;
        var assistantAnyCheck = anyAssistant
            ? new OnboardingCheck
            {
                Id = "assistant_any",
                Group = "assistant",
                State = "ok",
                Title = "可用助手",
                Detail = "至少有一个已启用的助手可用。",
                Blocking = false,
            }
            : new OnboardingCheck
            {
                Id = "assistant_any",
                Group = "assistant",
                State = "action_needed",
                Title = "可用助手",
                Detail = "请启用至少一个可用助手。",
                Blocking = isPair,
                Code = "no_enabled_assistant",
                Fix = OnboardingFix.OpenUrl(OnboardingCopyCatalog.UrlGuide),
                HasCodeKey = true,
                HasFixKey = true,
            };

        var tsCheck = tailscaleReady
            ? new OnboardingCheck
            {
                Id = "network_tailscale",
                Group = "network",
                State = "ok",
                Title = "Tailscale 连接",
                Detail = "Tailscale 已连接。",
                Blocking = false,
                Enabled = true,
                Available = true,
                HasAvailableKey = true,
            }
            : tailscaleDisabledAvailable
                ? new OnboardingCheck
                {
                    Id = "network_tailscale",
                    Group = "network",
                    State = "optional",
                    Title = "Tailscale 连接",
                    Detail = "Tailscale 已连接，可在配对设置中启用。",
                    Blocking = false,
                    Enabled = false,
                    Available = true,
                    Code = "tailscale_disabled",
                    Fix = configured
                        ? (isPair ? OnboardingFix.RunFix("enable_tailscale") : OnboardingFix.OpenSettings("connections"))
                        : OnboardingFix.RunFix("save_setup"),
                    HasAvailableKey = true,
                    HasCodeKey = true,
                    HasFixKey = true,
                }
                : new OnboardingCheck
                {
                    Id = "network_tailscale",
                    Group = "network",
                    State = "optional",
                    Title = "Tailscale 连接",
                    Detail = "Tailscale 尚未连接。",
                    Blocking = false,
                    Enabled = false,
                    Available = false,
                    Code = "tailscale_not_connected",
                    Fix = OnboardingFix.Retry,
                    HasAvailableKey = true,
                    HasCodeKey = true,
                    HasFixKey = true,
                };

        var tcCheck = tailcatReady
            ? new OnboardingCheck
            {
                Id = "network_tailcat",
                Group = "network",
                State = "ok",
                Title = "内置连接",
                Detail = "内置连接可用。",
                Blocking = false,
                Enabled = true,
                Available = true,
                HasAvailableKey = true,
            }
            : new OnboardingCheck
            {
                Id = "network_tailcat",
                Group = "network",
                State = "optional",
                Title = "内置连接",
                Detail = "内置连接可用，可在配对设置中启用。",
                Blocking = false,
                Enabled = false,
                Available = true,
                Code = "tailcat_disabled",
                Fix = configured
                    ? (isPair ? OnboardingFix.RunFix("enable_tailcat") : OnboardingFix.OpenSettings("connections"))
                    : OnboardingFix.RunFix("save_setup"),
                HasAvailableKey = true,
                HasCodeKey = true,
                HasFixKey = true,
            };

        var lanCheck = lanPublicBlocked
            ? new OnboardingCheck
            {
                Id = "network_lan",
                Group = "network",
                State = "action_needed",
                Title = "同一局域网",
                Detail = "当前网络未确认为专用网络。",
                Blocking = false,
                Enabled = false,
                Available = false,
                Code = "lan_public_network_blocked",
                Fix = OnboardingFix.OpenSettings("windows_network_profile"),
                HasAvailableKey = true,
                HasCodeKey = true,
                HasFixKey = true,
            }
            : lanFirewallBlocked
                ? new OnboardingCheck
                {
                    Id = "network_lan",
                    Group = "network",
                    State = "action_needed",
                    Title = "同一局域网",
                    Detail = "防火墙规则未允许专用网络连接。",
                    Blocking = false,
                    Enabled = false,
                    Available = false,
                    Code = "lan_firewall_blocked",
                    Fix = OnboardingFix.OpenSettings("windows_firewall"),
                    HasAvailableKey = true,
                    HasCodeKey = true,
                    HasFixKey = true,
                }
                : new OnboardingCheck
                {
                    Id = "network_lan",
                    Group = "network",
                    State = "optional",
                    Title = "同一局域网",
                    Detail = "未检测到可信局域网。",
                    Blocking = false,
                    Enabled = false,
                    Available = false,
                    Code = "lan_unavailable",
                    Fix = OnboardingFix.Retry,
                    HasAvailableKey = true,
                    HasCodeKey = true,
                    HasFixKey = true,
                };

        var anyNetwork = tailscaleReady || tailcatReady;
        string? recommendedTransport = (tailscaleReady || tailscaleDisabledAvailable)
            ? "tailscale"
            : "tailcat";

        var networkAnyCheck = anyNetwork
            ? new OnboardingCheck
            {
                Id = "network_any",
                Group = "network",
                State = "ok",
                Title = "手机连接方式",
                Detail = "至少有一种已启用的连接方式可用。",
                Blocking = false,
            }
            : new OnboardingCheck
            {
                Id = "network_any",
                Group = "network",
                State = "action_needed",
                Title = "手机连接方式",
                Detail = "请选择要用于配对的连接方式。",
                Blocking = isPair,
                Code = "network_selection_required",
                Fix = !configured
                    ? OnboardingFix.RunFix("save_setup")
                    : !isPair
                        ? OnboardingFix.OpenSettings("connections")
                        : OnboardingFix.RunFix($"enable_{recommendedTransport}"),
                HasCodeKey = true,
                HasFixKey = true,
            };

        var permLan = new OnboardingCheck
        {
            Id = "permission_local_network",
            Group = "permission",
            State = "optional",
            Title = "本地网络",
            Detail = "尚未获得此权限的状态。",
            Blocking = false,
            Code = "permission_unobserved",
            Fix = OnboardingFix.Skip,
            HasCodeKey = true,
            HasFixKey = true,
        };

        OnboardingCheck[] checks =
        [
            configCheck,
            workspaceCheck,
            serviceCheck,
            codexCheck,
            claudeCheck,
            agyCheck,
            deepseekCheck,
            assistantAnyCheck,
            tsCheck,
            tcCheck,
            lanCheck,
            networkAnyCheck,
            permLan,
        ];
        var firstBlocker = checks.FirstOrDefault(c => c.Blocking)?.Id;
        return new OnboardingPreflightReport
        {
            Schema = OnboardingSchema.PreflightV1,
            Ok = firstBlocker is null,
            Stage = stage,
            Configured = configured,
            WorkspaceConfirmed = workspaceConfirmed,
            ConfigPath = @"C:\fixture\config\config.json",
            ScanRoot = scanRoot,
            BrowseRoot = effectiveBrowse,
            ScanRootExists = true,
            RecommendedNext = firstBlocker ?? (!configured && !isPair ? "config_store" : "network_any"),
            RecommendedTransport = recommendedTransport,
            Checks = checks,
        };
    }

    private sealed class FakeWizardBackend : IOnboardingWizardBackend
    {
        public HashSet<string> ExistingDirs { get; } = new(StringComparer.OrdinalIgnoreCase);
        public List<(string ScanRoot, OnboardingSetupOptions Options)> SetupCalls { get; } = [];
        public List<(string ScanRoot, string? BrowseRoot)> WorkspaceCalls { get; } = [];
        public List<string> EnabledAssistants { get; } = [];
        public List<(string Id, string Value)> RuntimePathCalls { get; } = [];
        public int UpCallCount { get; private set; }

        public Func<OnboardingPreflightOptions, Action<OnboardingCheck>?, CancellationToken, Task<OnboardingPreflightReport>>? OnPreflight { get; set; }
        public Func<int, CancellationToken, Task<UpReadinessReceipt>>? OnUp { get; set; }

        public Task<OnboardingPreflightReport> PreflightAsync(
            OnboardingPreflightOptions options,
            Action<OnboardingCheck>? onProgress,
            CancellationToken cancellationToken) =>
            OnPreflight!(options, onProgress, cancellationToken);

        public Task<SetupReceipt> SetupNoPairAsync(string scanRoot, OnboardingSetupOptions options, CancellationToken cancellationToken)
        {
            SetupCalls.Add((scanRoot, options));
            return Task.FromResult(new SetupReceipt
            {
                Ok = true,
                Configured = true,
                Created = true,
                ConfigPath = @"C:\fixture\config\config.json",
                ScanRoot = scanRoot,
                BrowseRoot = options.BrowseRoot ?? scanRoot,
            });
        }

        public Task<UpReadinessReceipt> UpAsync(int waitSeconds, CancellationToken cancellationToken)
        {
            UpCallCount++;
            return OnUp is not null
                ? OnUp(waitSeconds, cancellationToken)
                : Task.FromResult(new UpReadinessReceipt { Ok = true, ServiceOk = true, Version = "1.0.0" });
        }

        public Task<PairingTicketReceipt> PairAsync(string network, CancellationToken cancellationToken) =>
            Task.FromResult(new PairingTicketReceipt
            {
                Ok = true,
                Endpoint = "http://127.0.0.1:8787",
                PairUrl = "mimiremote://pair?pair_sig=test",
                PairExpiresAt = DateTimeOffset.UtcNow.AddMinutes(5).ToString("O", CultureInfo.InvariantCulture),
                Network = network,
            });

        public Task SetRuntimePathAsync(string runtimeId, string value, CancellationToken cancellationToken)
        {
            RuntimePathCalls.Add((runtimeId, value));
            return Task.CompletedTask;
        }

        public Task<bool> UpdateWorkspaceAsync(string scanRoot, string? browseRoot, CancellationToken cancellationToken)
        {
            WorkspaceCalls.Add((scanRoot, browseRoot));
            return Task.FromResult(true);
        }

        public Task EnableAssistantAsync(string runtimeId, CancellationToken cancellationToken)
        {
            EnabledAssistants.Add(runtimeId);
            return Task.CompletedTask;
        }

        public Task EnableTransportAsync(string transport, CancellationToken cancellationToken) => Task.CompletedTask;
        public int RestartCalls { get; private set; }
        public Task<UpReadinessReceipt> RestartServiceAsync(CancellationToken cancellationToken)
        {
            RestartCalls++;
            return Task.FromResult(new UpReadinessReceipt { Ok = true, ServiceOk = true, Version = "1.0.0" });
        }
        public Task<bool> RunLanFirewallMaintenanceAsync(CancellationToken cancellationToken) => Task.FromResult(false);
        public bool DirectoryExists(string path) => ExistingDirs.Contains(path);
        public void CreateDirectory(string path) => ExistingDirs.Add(path);
        public void OpenUrl(string url) { }
        public void OpenSettings(string target) { }
        public bool CopyToClipboard(string text) => true;
        public DateTimeOffset Now() => DateTimeOffset.UtcNow;
    }

    private sealed class FakePairingBackend(Func<DateTimeOffset> clock) : IPairingSessionBackend
    {
        public OnboardingPreflightReport Report { get; set; } = null!;
        public PairingTicketReceipt? NextTicket { get; set; }
        public Task<PairingTicketReceipt>? PendingTicket { get; set; }
        public List<string> EnabledTransports { get; } = [];
        public List<string> OpenedSettings { get; } = [];
        public string? LastCopiedText { get; private set; }
        public int LanMaintenanceCalls { get; private set; }
        public bool LanMaintenanceResult { get; set; }
        public Func<string, Task>? OnEnableTransport { get; set; }

        public Task<OnboardingPreflightReport> PreflightPairAsync(CancellationToken cancellationToken) =>
            Task.FromResult(Report);

        public Task<PairingTicketReceipt> PairAsync(string network, CancellationToken cancellationToken) =>
            PendingTicket ?? Task.FromResult(NextTicket ?? new PairingTicketReceipt
            {
                Ok = true,
                Endpoint = "http://127.0.0.1:8787",
                PairUrl = "mimiremote://pair?pair_sig=default",
                PairExpiresAt = clock().AddMinutes(5).ToString("O", CultureInfo.InvariantCulture),
                Network = network,
            });

        public Task EnableTransportAsync(string transport, CancellationToken cancellationToken)
        {
            EnabledTransports.Add(transport);
            return OnEnableTransport is not null ? OnEnableTransport(transport) : Task.CompletedTask;
        }

        public Task<bool> RunLanFirewallMaintenanceAsync(CancellationToken cancellationToken)
        {
            LanMaintenanceCalls++;
            return Task.FromResult(LanMaintenanceResult);
        }

        public Task<TailcatStatus> ReadTailcatStatusAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new TailcatStatus { Enabled = true, Running = true });

        public Task SetTailcatRelayAsync(string[] arguments, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task<bool> ConfirmAsync(string title, string message) => Task.FromResult(true);
        public void OpenSettings(string target) => OpenedSettings.Add(target);
        public void OpenUrl(string url) { }
        public bool CopyToClipboard(string text)
        {
            LastCopiedText = text;
            return true;
        }

        public DateTimeOffset Now() => clock();
    }
}
