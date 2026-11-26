using System.Text.Json;
using CommunityToolkit.Mvvm.Input;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public sealed record ReadOnlyDoctorItem(string Title, string StatusBadge, string Message, string FixHint, bool HasFixHint);

public sealed class DiagnosticsViewModel : ClientPageViewModel
{
    private readonly Dictionary<string, OnboardingResolvedDiagnostic> preflightDiagnostics = new(StringComparer.Ordinal);
    private OnboardingPreflightReport? lastReport;
    private IReadOnlyList<OnboardingWizardRow> preflightRows = [];
    private IReadOnlyList<ReadOnlyDoctorItem> doctorItems = [];
    private OnboardingResolvedDiagnostic? recoveryDiagnostic;
    private string output = "";

    public IReadOnlyList<OnboardingWizardRow> PreflightRows { get => preflightRows; private set => SetProperty(ref preflightRows, value); }
    public IReadOnlyList<ReadOnlyDoctorItem> DoctorItems { get => doctorItems; private set => SetProperty(ref doctorItems, value); }
    public bool HasDoctorItems => DoctorItems.Count > 0;
    public OnboardingResolvedDiagnostic? RecoveryDiagnostic
    {
        get => recoveryDiagnostic;
        private set
        {
            if (SetProperty(ref recoveryDiagnostic, value))
            {
                OnPropertyChanged(nameof(HasRecoveryDiagnostic));
                OnPropertyChanged(nameof(RecoverySummary));
            }
        }
    }

    public bool HasRecoveryDiagnostic => RecoveryDiagnostic is not null;

    public string RecoverySummary
    {
        get
        {
            if (RecoveryDiagnostic is not { } diag)
            {
                return "";
            }
            var lines = new List<string> { diag.Message };
            if (!string.IsNullOrWhiteSpace(diag.ConfigPath))
            {
                lines.Add($"保留的配置文件：{diag.ConfigPath}");
            }
            if (!string.IsNullOrWhiteSpace(diag.RecoveryPath))
            {
                lines.Add($"已知恢复位置：{diag.RecoveryPath}");
            }
            lines.Add("原配置与配对身份已保留，客户端不会自动轮换配对 Token。");
            return string.Join("\n", lines);
        }
    }

    public string Output { get => output; private set => SetProperty(ref output, value); }
    public IAsyncRelayCommand DoctorCommand { get; }
    public IAsyncRelayCommand LogsCommand { get; }
    public IAsyncRelayCommand<string> FixCheckCommand { get; }

    public DiagnosticsViewModel(ClientContext context) : base(context)
    {
        DoctorCommand = new AsyncRelayCommand(() => RunAsync(RunReadOnlyDoctorAsync));
        LogsCommand = new AsyncRelayCommand(() => RunAsync(ReadSanitizedLogsAsync));
        FixCheckCommand = new AsyncRelayCommand<string>(id => RunAsync(() => DispatchPreflightFixAsync(id)));
    }

    protected override async Task RefreshAsync(bool force)
    {
        if (Context.Preview || !Context.HasAgent)
        {
            return;
        }
        var stage = Context.GateState == OnboardingGateState.Confirmed ? "pair" : "setup";
        try
        {
            var report = await Context.Agent.PreflightAsync(
                new OnboardingPreflightOptions
                {
                    Stage = stage,
                    ProgressJson = false,
                    VerifiedConfigured = Context.GateState == OnboardingGateState.Confirmed,
                    VerifiedCapability = Context.VerifiedCapability,
                },
                onProgress: null,
                platform: "windows",
                cancellationToken: Lifetime.Token);
            ApplyPreflightReport(report);
            Context.UpdateGateFromPreflight(report, null);
        }
        catch (OnboardingCliException error)
        {
            lastReport = null;
            preflightDiagnostics.Clear();
            PreflightRows = [];
            var diag = error.Diagnostic;
            RecoveryDiagnostic = diag is { AllowedFix: { Kind: "open_settings", Target: "host_recovery" } } ? diag : null;
            Context.UpdateGateFromPreflight(null, diag);
            Report(diag?.Message ?? OnboardingCopyCatalog.SafeFallbackCopy, error: true);
        }
    }

    private async Task RunReadOnlyDoctorAsync()
    {
        if (Context.Preview)
        {
            throw new InvalidOperationException("界面预览不会运行电脑诊断。");
        }
        // Always read-only: doctor --json NEVER executes repairs or rotates tokens.
        var raw = await Context.Agent.RunAsync(["doctor", "--json"], allowFailure: true, cancellationToken: Lifetime.Token);
        try
        {
            var report = JsonSerializer.Deserialize<DoctorReport>(raw, AgentClient.JsonOptions);
            if (report is not null && report.Checks.Length > 0)
            {
                var items = new List<ReadOnlyDoctorItem>(report.Checks.Length);
                foreach (var check in report.Checks)
                {
                    if (string.Equals(check.Capability, OnboardingSchema.DoctorFixCapability, StringComparison.Ordinal))
                    {
                        Context.SetVerifiedCapability(OnboardingSchema.DoctorFixCapability);
                    }
                    var badge = check.Ok ? "正常" : string.Equals(check.Level, "warn", StringComparison.OrdinalIgnoreCase) ? "提示" : "异常";
                    var fixHint = DiagnosticSanitizer.ScrubLogText(check.Fix);
                    items.Add(new ReadOnlyDoctorItem(
                        DiagnosticSanitizer.LocalizeDoctorCheckName(check.Name),
                        badge,
                        DiagnosticSanitizer.ScrubLogText(check.Message),
                        fixHint,
                        !string.IsNullOrWhiteSpace(fixHint)));
                }
                DoctorItems = items;
                OnPropertyChanged(nameof(HasDoctorItems));
                Output = string.Join("\n", items.Select(i => $"[{i.StatusBadge}] {i.Title}：{i.Message}"));
                Report(report.Ok ? "只读诊断已完成，未发现异常。" : "只读诊断已完成，可按上方预检建议处理。");
                return;
            }
        }
        catch (JsonException)
        {
        }
        DoctorItems = [];
        OnPropertyChanged(nameof(HasDoctorItems));
        Output = DiagnosticSanitizer.ScrubLogText(raw);
    }

    private async Task ReadSanitizedLogsAsync()
    {
        var log = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mimi Remote", "logs", "agentd.log");
        using var stream = new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        stream.Seek(Math.Max(0, stream.Length - 65536), SeekOrigin.Begin);
        using var reader = new StreamReader(stream);
        var raw = await reader.ReadToEndAsync(Lifetime.Token);
        Output = DiagnosticSanitizer.ScrubLogText(raw);
    }

    private void ApplyPreflightReport(OnboardingPreflightReport report)
    {
        lastReport = report;
        preflightDiagnostics.Clear();
        var rows = new List<OnboardingWizardRow>(report.Checks.Count);
        foreach (var check in report.Checks)
        {
            var ctx = new OnboardingValidationContext
            {
                Surface = "check",
                Platform = "windows",
                Stage = report.Stage,
                Configured = report.Configured,
                HasRecommendedTransport = true,
                RecommendedTransport = report.RecommendedTransport,
                VerifiedCapability = Context.VerifiedCapability,
            };
            OnboardingResolvedDiagnostic? diag = null;
            if (OnboardingCopyCatalog.TryValidateCheck(check, ctx, out var resolved, out _))
            {
                preflightDiagnostics[check.Id] = resolved;
                diag = resolved;
            }
            var allowedFix = FilterClickableFix(check, diag);
            rows.Add(new OnboardingWizardRow(
                check,
                diag,
                check.State switch
                {
                    "ok" => "正常",
                    "optional" => "可选",
                    "action_needed" => "需处理",
                    "error" => "异常",
                    _ => "检查中",
                },
                diag is { Trusted: true } ? diag.Message : check.Detail,
                allowedFix is not null ? OnboardingWizardStateMachine.FormatFixLabel(allowedFix) : null,
                allowedFix is not null,
                SecondaryLabel: null,
                HasSecondaryAction: false,
                CanResetPin: false,
                Skipped: false,
                CandidateSummary: ""));
        }
        PreflightRows = rows;
        var configDiag = preflightDiagnostics.GetValueOrDefault("config_store");
        RecoveryDiagnostic = configDiag is { AllowedFix: { Kind: "open_settings", Target: "host_recovery" } }
            ? configDiag
            : null;
    }

    private OnboardingFix? FilterClickableFix(OnboardingCheck check, OnboardingResolvedDiagnostic? diag)
    {
        if (diag is not { Trusted: true, AllowedFix: { } fix })
        {
            return null;
        }
        if (string.Equals(fix.Kind, "run_fix", StringComparison.Ordinal)
            && string.Equals(fix.Action, "doctor_fix", StringComparison.Ordinal))
        {
            // Safe identity-preserving doctor --fix is allowed ONLY for config_permissions_unsafe on verified BE-3+ hosts.
            var allowed = lastReport?.Configured == true
                && string.Equals(check.Id, "config_store", StringComparison.Ordinal)
                && string.Equals(check.Code, "config_permissions_unsafe", StringComparison.Ordinal)
                && string.Equals(Context.VerifiedCapability, OnboardingSchema.DoctorFixCapability, StringComparison.Ordinal);
            return allowed ? fix : null;
        }
        return fix;
    }

    private async Task DispatchPreflightFixAsync(string? checkId)
    {
        if (string.IsNullOrWhiteSpace(checkId) || lastReport is null
            || !preflightDiagnostics.TryGetValue(checkId, out var diag))
        {
            return;
        }
        var check = lastReport.Checks.FirstOrDefault(c => string.Equals(c.Id, checkId, StringComparison.Ordinal));
        if (check is null)
        {
            return;
        }
        var fix = FilterClickableFix(check, diag);
        if (fix is null)
        {
            return;
        }
        switch (fix.Kind)
        {
            case "open_url":
                if (fix.Url is not null && OnboardingCopyCatalog.IsAllowedUrl(fix.Url))
                {
                    Context.OpenUrl(fix.Url);
                }
                break;

            case "open_settings":
                if (fix.Target is null || !OnboardingCopyCatalog.IsAllowedSettingsTarget(fix.Target))
                {
                    break;
                }
                if (string.Equals(fix.Target, "host_recovery", StringComparison.Ordinal))
                {
                    RecoveryDiagnostic = diag;
                    Report(RecoverySummary);
                }
                else
                {
                    Context.OpenSettings(fix.Target);
                }
                break;

            case "choose_path":
                Context.NavigateRoute(OnboardingNavigationGate.RouteSetup);
                break;

            case "retry":
                await RefreshAsync(force: true);
                break;

            case "run_fix":
                await RunPreflightFixActionAsync(fix.Action, check.Code);
                break;
        }
    }

    private async Task RunPreflightFixActionAsync(string? action, string? code)
    {
        if (string.IsNullOrWhiteSpace(action) || lastReport is null
            || !OnboardingCopyCatalog.RunFixSpecs.TryGetValue(action, out var spec))
        {
            return;
        }
        if (spec.RequiresConfig && !lastReport.Configured)
        {
            return;
        }
        switch (action)
        {
            case "save_setup":
                Context.NavigateRoute(OnboardingNavigationGate.RouteSetup);
                return;

            case "doctor_fix":
                if (!string.Equals(code, "config_permissions_unsafe", StringComparison.Ordinal)
                    || !string.Equals(Context.VerifiedCapability, OnboardingSchema.DoctorFixCapability, StringComparison.Ordinal))
                {
                    return;
                }
                await Context.ChangeAsync(() => Context.Agent.RunAsync(["doctor", "--fix", "--json"], Lifetime.Token));
                await RefreshAsync(force: true);
                Report("已安全修复配置文件权限，未更改配对身份。");
                return;

            case "restart_service":
                await Context.ChangeAsync(() => Context.Agent.RunAsync(["restart", "--wait", "60s", "--no-pair", "--json"], Lifetime.Token));
                await RefreshAsync(force: true);
                return;

            case "register_service":
                await Context.ChangeAsync(() => Context.Agent.UpAsync(60, Lifetime.Token));
                await RefreshAsync(force: true);
                return;
        }
    }
}
